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
//!   - `Telemetry` config + `httpExport` — the fail-open OTLP/HTTP exporter over
//!     the `http.Transport` seam (runtime completeness; not golden-gated).
//!
//! The OTEL GenAI binding facts (semconv version, attribute keys, the
//!
//! `providers/generated/telemetry_gen.zig`; this handwritten layer only carries
//! runtime behaviour. Zig has no middleware fire-site wiring yet (send-path
//! coverage is minimal), so the exporter is provided for completeness but is not
//! fired from any send path — the telemetry SURFACE, not the seam.

const std = @import("std");
const json = @import("json.zig");
const http = @import("http.zig");
const gen = @import("providers/generated/telemetry_gen.zig");
const middleware_gen = @import("providers/generated/middleware_gen.zig");

pub const MiddlewareOp = middleware_gen.MiddlewareOp;
pub const MiddlewarePhase = middleware_gen.MiddlewarePhase;

/// Token accounting an `Event` carries into the span (the OTEL usage
/// attributes). Mirrors the input/output the Rust `middleware::Usage` feeds the
/// telemetry builder; other dimensions are not exported today.
pub const Usage = struct {
    input: i64 = 0,
    output: i64 = 0,
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

/// Opt-in observability config (ADR-059). `endpoint` is required (empty is a
/// loud construction error at `httpExport`); `headers` ride each OTLP POST;
/// `capture_content` gates tier-2 payloads (default `false` for privacy — the
/// event carries no payload yet, so this reserves the semantics).
pub const Telemetry = struct {
    endpoint: []const u8,
    headers: []const http.Header = &.{},
    capture_content: bool = false,
};

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
/// only when non-zero; `error.type` + the span `status` (`code: 2`) are present
/// only on error.
pub fn buildOtlpTraces(
    arena: std.mem.Allocator,
    op_name: []const u8,
    provider: []const u8,
    model: []const u8,
    input_tokens: i64,
    output_tokens: i64,
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
    if (input_tokens > 0)
        try attributes.array.append(try intAttr(arena, gen.otel_usage_input, input_tokens));
    if (output_tokens > 0)
        try attributes.array.append(try intAttr(arena, gen.otel_usage_output, output_tokens));
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
    const input: i64 = if (ev.usage) |u| u.input else 0;
    const output: i64 = if (ev.usage) |u| u.output else 0;
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

/// Fail-open OTLP/HTTP exporter over the transport seam: POST `payload` to
/// `tel.endpoint` + `/v1/traces` with the configured headers. An EMPTY endpoint
/// is a loud construction error (`error.TelemetryEndpointRequired`, the honest
/// contract TEL-017); a transport FAILURE is swallowed (fail-open — telemetry
/// never surfaces on the request path). Mirrors Rust `http_export`.
///
/// Not fired from any send path today (Zig has no middleware seam); provided so
/// a caller can drive it directly, or a future middleware wiring can call it.
pub fn httpExport(
    arena: std.mem.Allocator,
    transport: http.Transport,
    tel: Telemetry,
    payload: []const u8,
) !void {
    if (tel.endpoint.len == 0) return error.TelemetryEndpointRequired;

    const trimmed = std.mem.trimEnd(u8, tel.endpoint, "/");
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ trimmed, gen.traces_path });

    var hdrs: std.ArrayList(http.Header) = .empty;
    try hdrs.append(arena, .{ .name = "content-type", .value = "application/json" });
    for (tel.headers) |h| try hdrs.append(arena, h);

    _ = transport.send(arena, .{
        .method = .POST,
        .url = url,
        .headers = hdrs.items,
        .body = payload,
    }) catch return; // fail-open
}



























































