//! HTTP transport seam + auth headers (Phase 3, HANDOFF-042 slice 1).
//!
//! The execution modes (stream / agent / batch / Job-poll) are the first Zig
//! phase to need a real network send, so this module introduces the transport
//! seam every send path routes through. `Transport` is a small type-erased
//! interface (a `*anyopaque` + one `send` function pointer) so the runtime never
//! hard-codes `std.http.Client`: production wires `HttpTransport` (a thin
//! std.http.Client.fetch wrapper), while the lifecycle-wire driver injects
//! `MockTransport` to serve scripted responses in-process — the same "pass the
//! dependency, never reach for a global" discipline 0.16 already applies to
//! `Allocator` and `Io`. Mirrors the injectable `*http.Client` seam Go threads
//! through its `do*` helpers; Rust hard-codes reqwest, so the seam is Zig's own
//! (and Go's) idiom, not a port of Rust's.
//!
//! `buildAuthHeaders` builds the per-request auth + required headers from the
//! generated `authScheme` fact — never a switch on provider name — mirroring
//! Rust `build_auth_headers`. QueryParamKey (Google) and SigV4 (Bedrock) carry
//! no auth HEADER: the key rides the URL / the request is signed instead.

const std = @import("std");
const providers = @import("providers/generated/providers.zig");
const request_defs = @import("providers/generated/request_defs.zig");

pub const Method = enum { GET, POST };

/// One request/response header name/value pair (the same shape `request.zig`
/// uses for its pure header seam).
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// An outbound HTTP request. `body` is empty for a GET; `headers` are the fully
/// composed set (auth + required + content-type + any custom), owned by the
/// caller and valid for the duration of the `send`.
pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

/// An inbound HTTP response. `body` is backed by the arena passed to `send`.
pub const Response = struct {
    status: u16,
    body: []const u8,
};

/// The type-erased transport seam. `send` performs one round-trip and returns
/// the response with its body allocated in `arena`. Production is
/// `HttpTransport`; tests inject `MockTransport`.
pub const Transport = struct {
    ptr: *anyopaque,
    send_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, req: Request) anyerror!Response,

    pub fn send(self: Transport, arena: std.mem.Allocator, req: Request) !Response {
        return self.send_fn(self.ptr, arena, req);
    }
};

/// Production transport backed by `std.http.Client.fetch`. Holds the `Io` and a
/// general-purpose allocator for the client's own buffers; the response body is
/// duped into the per-request `arena` so it outlives the fetch. One-shot per
/// call (no connection reuse) — the send paths are request/response, not
/// long-lived streams, and `keep_alive` is left to the client default.
pub const HttpTransport = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) HttpTransport {
        return .{ .gpa = gpa, .io = io };
    }

    fn sendImpl(ptr: *anyopaque, arena: std.mem.Allocator, req: Request) anyerror!Response {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));

        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();

        // Translate our headers to std.http.Header (same {name,value} shape).
        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(self.gpa);
        for (req.headers) |h|
            try extra.append(self.gpa, .{ .name = h.name, .value = h.value });

        var body_writer: std.Io.Writer.Allocating = .init(arena);
        const result = try client.fetch(.{
            .location = .{ .url = req.url },
            .method = switch (req.method) {
                .GET => .GET,
                .POST => .POST,
            },
            .payload = if (req.body.len > 0) req.body else null,
            .extra_headers = extra.items,
            .response_writer = &body_writer.writer,
        });

        return .{
            .status = @intFromEnum(result.status),
            .body = body_writer.written(),
        };
    }

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .ptr = self, .send_fn = sendImpl };
    }
};

/// An in-memory transport that serves `responses` in order (the lifecycle-wire
/// mock). Each `send` returns the next scripted response and records the request
/// it was asked to make, so a driver can both feed canned bodies and assert what
/// the runtime sent — the two-hop batch poll (status GET, then results GET) is
/// two scripted responses.
pub const MockTransport = struct {
    responses: []const Response,
    index: usize = 0,
    /// Requests captured in call order (borrowed views; valid while the caller's
    /// request memory lives). Optional to inspect.
    captured: std.ArrayList(Request) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, responses: []const Response) MockTransport {
        return .{ .gpa = gpa, .responses = responses };
    }

    pub fn deinit(self: *MockTransport) void {
        self.captured.deinit(self.gpa);
    }

    fn sendImpl(ptr: *anyopaque, arena: std.mem.Allocator, req: Request) anyerror!Response {
        _ = arena;
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        try self.captured.append(self.gpa, req);
        if (self.index >= self.responses.len) return error.MockTransportExhausted;
        const r = self.responses[self.index];
        self.index += 1;
        return r;
    }

    pub fn transport(self: *MockTransport) Transport {
        return .{ .ptr = self, .send_fn = sendImpl };
    }
};

/// Build the auth + required request headers for `provider`, keyed off the
/// generated `authScheme` fact (never a provider-name switch):
///   - BearerToken  -> `<auth_header>: <auth_prefix> <api_key>` (e.g.
///     `Authorization: Bearer sk-…`; a non-standard prefix like Vidu's `Token`
///     is carried by the fact).
///   - HeaderAPIKey -> `<auth_header>: <api_key>` (e.g. Anthropic `x-api-key`).
///   - QueryParamKey / SigV4 -> NO auth header (the key rides the URL, or the
///     request is SigV4-signed) — the caller appends the query param / signs.
/// The provider's `required_header` (e.g. Anthropic `anthropic-version`) is
/// appended after. Returns an arena-backed slice. Mirrors Rust
/// `build_auth_headers`.
pub fn buildAuthHeaders(arena: std.mem.Allocator, provider: providers.ProviderName, api_key: []const u8) ![]Header {
    const spec = providers.spec(provider);
    var list: std.ArrayList(Header) = .empty;

    switch (request_defs.authScheme(provider)) {
        .bearer_token => try list.append(arena, .{
            .name = spec.auth_header,
            .value = try std.fmt.allocPrint(arena, "{s} {s}", .{ spec.auth_prefix, api_key }),
        }),
        .header_api_key => try list.append(arena, .{ .name = spec.auth_header, .value = api_key }),
        .query_param_key, .sig_v4 => {},
    }

    if (spec.required_header.len > 0)
        try list.append(arena, .{ .name = spec.required_header, .value = spec.required_header_value });

    return list.toOwnedSlice(arena);
}


























































