//! Opt-in, OTEL GenAI-aligned telemetry (ADR-054 / ADR-059) — the OTLP surface.
//!
//! Mirrors the Rust reference (`rust/src/telemetry.rs` + the `set_event_error`
//! seam in `rust/src/middleware.rs`). Three parts:
//!   - `buildOtlpTraces` — the PURE, deterministic OTLP/HTTP proto3-JSON payload
//!     builder. Given the call's primitives plus injectable span identity +
//!     timing, it returns the exact JSON the exporter POSTs. The shared parity
//!     fixtures call it with fixed inputs so every SDK is asserted value-
//!
//!   - `Event` + `setEventError` — the middleware event and the ADR-071 erasure
//!     seam. `error.type` is read verbatim from `Event.err_type`, stamped
//!     structurally from the typed error the one place it still exists, never
//!     re-parsed from a message string.
//!   - `Telemetry` + `Client.addTelemetry` — the export hook on the middleware
//!     seam. Every post-phase event becomes one OTLP span, handed synchronously
//!     to the caller's `export` callback (ADR-059). `HttpExport` is the
//!     batteries callback: a fail-open OTLP/HTTP POST over the `http.Transport`
//!     seam.
//!
//! The OTEL GenAI binding facts (semconv version, attribute keys, the
//!
//! `providers/generated/telemetry_gen.zig`; this handwritten layer only carries
//! runtime behaviour.

const std = @import("std");
const json = @import("json.zig");
const http = @import("http.zig");
const middleware = @import("middleware.zig");
const send = @import("send.zig");
const gen = @import("providers/generated/telemetry_gen.zig");
const middleware_gen = @import("providers/generated/middleware_gen.zig");

pub const MiddlewareOp = middleware_gen.MiddlewareOp;
pub const MiddlewarePhase = middleware_gen.MiddlewarePhase;

/// Token accounting an `Event` carries into the span (the OTEL usage
/// attributes). Mirrors the input/output the Rust `middleware::Usage` feeds the
/// telemetry builder; other dimensions are not exported today. Null means the
/// provider did not report the dimension (AVAIL-006): a reported zero is still
/// exported.
pub const Usage = struct {
    input: ?i64 = null,
    output: ?i64 = null,
};

/// The middleware observation event telemetry renders. `usage` is null until the
/// post phase carries token accounting; `err_type` is the ADR-071 structural
/// error kind (empty on success), stamped by `setEventError` and read verbatim
/// by the OTLP builder.
pub const Event = struct {
    op: MiddlewareOp,
    phase: MiddlewarePhase,
    provider: []const u8 = "",
    model: []const u8 = "",
    /// The tool name. Set only when op is `tool_call`. Not an OTEL attribute.
    tool: []const u8 = "",
    /// The tool's arguments as JSON text. Set only when op is `tool_call` and
    /// phase is pre. Read-only: Go lets a middleware rewrite them, but a Zig
    /// hook receives a const event. Not an OTEL attribute.
    args: []const u8 = "",
    /// The tool's result. Set only when op is `tool_call` and phase is post.
    /// Not an OTEL attribute.
    result: []const u8 = "",
    usage: ?Usage = null,
    err: ?[]const u8 = null,
    err_type: []const u8 = "",
};

/// A typed error handed to the erasure seam. Zig's SDK errors are error-set
/// members (no payload), so this small tagged union is the one place the kind
/// still travels structurally — mirroring the Rust `Error` variants
/// `set_event_error` classifies. Api/Validation get their own OTEL `error.type`;
/// every other kind erases to the stable catch-all `"error"`.
pub const CallError = union(enum) {
    api: struct { provider: []const u8, status_code: u16, message: []const u8 },
    validation: struct { field: []const u8, message: []const u8 },
    transport: []const u8,
    decoding: []const u8,
    unsupported: []const u8,
    middleware_veto: []const u8,
    timeout: void,
};

/// Erase a typed error onto a post-phase `Event`: keep the human message on
/// `err`, and stamp the structural kind on `err_type` (the value the OTLP
/// builder reads verbatim, ADR-071). Classification is a switch on the typed
/// variant — never a re-parse of the `Display`/message string.
pub fn setEventError(ev: *Event, err: CallError) void {
    switch (err) {
        .api => |a| {
            ev.err = a.message;
            ev.err_type = "api_error";
        },
        .validation => |v| {
            ev.err = v.message;
            ev.err_type = "validation_error";
        },
        .transport => |m| {
            ev.err = m;
            ev.err_type = "error";
        },
        .decoding => |m| {
            ev.err = m;
            ev.err_type = "error";
        },
        .unsupported => |m| {
            ev.err = m;
            ev.err_type = "error";
        },
        .middleware_veto => |m| {
            ev.err = m;
            ev.err_type = "error";
        },
        .timeout => {
            ev.err = "operation timed out";
            ev.err_type = "error";
        },
    }
}

/// The export callback: receives the finished OTLP/HTTP proto3-JSON bytes for
/// one span, called synchronously on the post phase. The same type-erased
/// `{ptr, fn}` pair as `Middleware`, because a Zig function pointer cannot
/// capture state. The bytes are valid only for the duration of the call.
pub const Export = struct {
    ptr: *anyopaque,
    call_fn: *const fn (ptr: *anyopaque, payload: []const u8) void,

    pub fn call(self: Export, payload: []const u8) void {
        self.call_fn(self.ptr, payload);
    }
};

/// Opt-in observability config (ADR-059). Attach it with
/// `Client.addTelemetry`: every operation the client performs then emits one
/// OTEL GenAI-aligned span, handed to `export`. `export` is a required field,
/// so an enabled-but-no-sink config cannot be built (TEL-017). Use
/// `HttpExport` for the batteries POST, or supply your own callback to bridge
/// into an existing OTEL stack. `capture_content` gates tier-2 payloads
/// (default `false` for privacy); the event carries no payload yet, so this
/// reserves the semantics.
pub const Telemetry = struct {
    @"export": Export,
    capture_content: bool = false,
    /// The client allocator and `Io` the hook builds each span with (span
    /// identity needs `Io.random`, timing needs the clock). Set by
    /// `Client.addTelemetry`; callers leave it null.
    bound: ?Binding = null,

    pub const Binding = struct { gpa: std.mem.Allocator, io: std.Io };

    /// The middleware hook `Client.addTelemetry` attaches. Borrows `self`, so
    /// the `Telemetry` must outlive every client that holds it.
    pub fn hook(self: *Telemetry) middleware.Middleware {
        return .{ .ptr = self, .call_fn = onEvent };
    }

    /// Post phase only: build the OTLP span and call `export`. Fail-open: a
    /// span that cannot be built (out of memory) is dropped, and the callback
    /// returns nothing, so telemetry never fails or vetoes the call.
    fn onEvent(ptr: *anyopaque, ev: *const Event) ?[]const u8 {
        const self: *Telemetry = @ptrCast(@alignCast(ptr));
        if (ev.phase != .post) return null;
        const b = self.bound orelse return null;
        var arena_state = std.heap.ArenaAllocator.init(b.gpa);
        defer arena_state.deinit();
        const payload = buildTelemetryPayload(arena_state.allocator(), b.io, ev) catch return null;
        self.@"export".call(payload);
        return null;
    }
};

/// Production wrapper: fresh span identity + the wall clock around the pure
/// event-level builder. Start and end are both "now", as in Go and Rust: the
/// post event does not carry the call's start time.
fn buildTelemetryPayload(arena: std.mem.Allocator, io: std.Io, ev: *const Event) ![]const u8 {
    const now = std.Io.Clock.real.now(io).nanoseconds;
    const now_text = try std.fmt.allocPrint(arena, "{d}", .{now});
    var trace_bytes: [16]u8 = undefined;
    var span_bytes: [8]u8 = undefined;
    io.random(&trace_bytes);
    io.random(&span_bytes);
    const trace_hex = std.fmt.bytesToHex(trace_bytes, .lower);
    const span_hex = std.fmt.bytesToHex(span_bytes, .lower);
    return buildTelemetryPayloadAt(arena, ev, &trace_hex, &span_hex, now_text, now_text);
}

/// Build one attribute object `{"key": key, "value": {"stringValue": val}}`.
fn stringAttr(arena: std.mem.Allocator, key: []const u8, val: []const u8) !json.Value {
    var value = json.object();
    try json.set(arena, &value, "stringValue", .{ .string = val });
    var a = json.object();
    try json.set(arena, &a, "key", .{ .string = key });
    try json.set(arena, &a, "value", value);
    return a;
}

/// Build one attribute object `{"key": key, "value": {"intValue": "<n>"}}`.
/// OTLP/JSON renders int64 fields as STRINGS (spec), so the count is formatted
/// to decimal text.
fn intAttr(arena: std.mem.Allocator, key: []const u8, n: i64) !json.Value {
    const s = try std.fmt.allocPrint(arena, "{d}", .{n});
    var value = json.object();
    try json.set(arena, &value, "intValue", .{ .string = s });
    var a = json.object();
    try json.set(arena, &a, "key", .{ .string = key });
    try json.set(arena, &a, "value", value);
    return a;
}

/// The PURE, deterministic OTLP-payload builder (OTLP/HTTP, proto3-JSON). Given
/// the call's primitives plus injectable span identity + timing, returns the
/// exact JSON the exporter POSTs. Mirrors Rust `build_otlp_traces`.
///
/// Encoding notes (OTLP/JSON spec): int64 fields (times, token counts) render as
/// STRINGS; `traceId`/`spanId` are hex; each attribute `value` object carries
/// exactly one of `stringValue` XOR `intValue`; usage attributes are present
/// only when reported, zero included (AVAIL-006); `error.type` + the span `status` (`code: 2`) are present
/// only on error.
pub fn buildOtlpTraces(
    arena: std.mem.Allocator,
    op_name: []const u8,
    provider: []const u8,
    model: []const u8,
    input_tokens: ?i64,
    output_tokens: ?i64,
    error_type: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
    start_ns: []const u8,
    end_ns: []const u8,
) ![]const u8 {
    var attributes = json.array(arena);
    try attributes.array.append(try stringAttr(arena, gen.otel_attr_op, op_name));
    try attributes.array.append(try stringAttr(arena, gen.otel_attr_provider, provider));
    try attributes.array.append(try stringAttr(arena, gen.otel_attr_model, model));
    if (input_tokens) |n|
        try attributes.array.append(try intAttr(arena, gen.otel_usage_input, n));
    if (output_tokens) |n|
        try attributes.array.append(try intAttr(arena, gen.otel_usage_output, n));
    if (error_type.len > 0)
        try attributes.array.append(try stringAttr(arena, gen.otel_attr_err_type, error_type));

    var span = json.object();
    try json.set(arena, &span, "traceId", .{ .string = trace_id });
    try json.set(arena, &span, "spanId", .{ .string = span_id });
    try json.set(arena, &span, "name", .{ .string = try std.fmt.allocPrint(arena, "{s} {s}", .{ op_name, model }) });
    try json.set(arena, &span, "kind", .{ .integer = 3 });
    try json.set(arena, &span, "startTimeUnixNano", .{ .string = start_ns });
    try json.set(arena, &span, "endTimeUnixNano", .{ .string = end_ns });
    try json.set(arena, &span, "attributes", attributes);
    if (error_type.len > 0) {
        var status = json.object();
        try json.set(arena, &status, "code", .{ .integer = 2 });
        try json.set(arena, &span, "status", status);
    }

    var spans = json.array(arena);
    try spans.array.append(span);

    var scope = json.object();
    try json.set(arena, &scope, "name", .{ .string = "llmkit" });
    try json.set(arena, &scope, "version", .{ .string = gen.semconv_version });

    var scope_span = json.object();
    try json.set(arena, &scope_span, "scope", scope);
    try json.set(arena, &scope_span, "spans", spans);
    var scope_spans = json.array(arena);
    try scope_spans.array.append(scope_span);

    var resource_attrs = json.array(arena);
    try resource_attrs.array.append(try stringAttr(arena, "service.name", "llmkit"));
    var resource = json.object();
    try json.set(arena, &resource, "attributes", resource_attrs);

    var resource_span = json.object();
    try json.set(arena, &resource_span, "resource", resource);
    try json.set(arena, &resource_span, "scopeSpans", scope_spans);
    var resource_spans = json.array(arena);
    try resource_spans.array.append(resource_span);

    var root = json.object();
    try json.set(arena, &root, "resourceSpans", resource_spans);

    return json.stringify(arena, root);
}

/// Pure event-level payload builder: renders a post-phase `Event` to the OTLP
/// traces JSON with injected span identity + timing (the telemetry-error golden
/// drives it end-to-end). The operation name comes from the generated
/// `MiddlewareOp` map (falling back to the tag name for ops without a documented
/// semconv value); `error.type` is `ev.err_type` verbatim (ADR-071). Mirrors
/// Rust `build_telemetry_payload_at`.
pub fn buildTelemetryPayloadAt(
    arena: std.mem.Allocator,
    ev: *const Event,
    trace_id: []const u8,
    span_id: []const u8,
    start_ns: []const u8,
    end_ns: []const u8,
) ![]const u8 {
    const op = gen.operationName(ev.op) orelse @tagName(ev.op);
    const input: ?i64 = if (ev.usage) |u| u.input else null;
    const output: ?i64 = if (ev.usage) |u| u.output else null;
    return buildOtlpTraces(
        arena,
        op,
        ev.provider,
        ev.model,
        input,
        output,
        ev.err_type,
        trace_id,
        span_id,
        start_ns,
        end_ns,
    );
}

/// The batteries export callback: POSTs each OTLP payload to `endpoint` +
/// `/v1/traces` with the given headers, fail-open (every transport error and
/// non-2xx reply is swallowed). Mirrors Go `HTTPExport` / Rust `http_export`.
///
/// Low-volume only: the POST is synchronous on the request path, so a slow
/// collector adds up to 5 s of latency to the call. For high volume,
/// supply your own `Export` that enqueues into your OTEL SDK's batch processor.
/// `endpoint` and `headers` are borrowed and must outlive the exporter.
pub const HttpExport = struct {
    /// The send context: allocator, `Io`, the collector timeout (5 s), and an
    /// optional transport override (the test seam).
    ctx: http.Ctx,
    endpoint: []const u8,
    headers: []const http.Header = &.{},

    /// An empty endpoint is a loud construction error (TEL-017): there is no
    /// enabled-but-no-sink state.
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        endpoint: []const u8,
        headers: []const http.Header,
    ) error{TelemetryEndpointRequired}!HttpExport {
        if (endpoint.len == 0) return error.TelemetryEndpointRequired;
        return .{
            .ctx = .{ .gpa = gpa, .io = io, .timeout_ms = 5_000 },
            .endpoint = endpoint,
            .headers = headers,
        };
    }

    /// Return a copy that sends through `t` instead of a production transport.
    pub fn withTransport(self: HttpExport, t: http.Transport) HttpExport {
        var e = self;
        e.ctx = e.ctx.withTransport(t);
        return e;
    }

    /// The `Export` callback for `Telemetry.export`. Borrows `self`.
    pub fn exporter(self: *HttpExport) Export {
        return .{ .ptr = self, .call_fn = exportImpl };
    }

    fn exportImpl(ptr: *anyopaque, payload: []const u8) void {
        const self: *HttpExport = @ptrCast(@alignCast(ptr));
        var arena_state = std.heap.ArenaAllocator.init(self.ctx.gpa);
        defer arena_state.deinit();
        // Fail-open: a transport error never reaches the instrumented call.
        send.withTransport(&self.ctx, post, self, .{ arena_state.allocator(), payload }) catch {};
    }

    fn post(self: *HttpExport, transport: http.Transport, arena: std.mem.Allocator, payload: []const u8) !void {
        const trimmed = std.mem.trimEnd(u8, self.endpoint, "/");
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ trimmed, gen.traces_path });

        var hdrs: std.ArrayList(http.Header) = .empty;
        try hdrs.append(arena, .{ .name = "content-type", .value = "application/json" });
        for (self.headers) |h| try hdrs.append(arena, h);

        _ = try transport.send(arena, .{
            .method = .POST,
            .url = url,
            .headers = hdrs.items,
            .body = payload,
        });
    }
};





























































