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
const middleware = @import("middleware.zig");
const client_defaults = @import("providers/generated/client_defaults.zig");

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

/// Production transport over `std.http.Client`, with the client's idle timeout
/// (BUG-062). Lives in `http_transport.zig`; re-exported here so every terminal
/// keeps naming `http.HttpTransport`.
pub const HttpTransport = @import("http_transport.zig").HttpTransport;

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
///     request is SigV4-signed) — `send.zig` appends the query param / signs.
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

/// The AWS signing inputs other than the access key ID. The other SDKs read
/// them from the environment variables the provider names
/// (`secret_key_env_var`, `session_token_env_var`, `region_env_var`); Zig has
/// no ambient environment, so the caller reads those variables and passes the
/// values here, the same way it passes `api_key`.
pub const AwsCredentials = struct {
    secret_access_key: []const u8,
    /// Empty when the credentials are not temporary (STS) ones.
    session_token: []const u8 = "",
    region: []const u8,
};

/// Fixed capacity for `Client.addHeader` (ADR-052). Client chain methods take
/// no allocator (ADR-069 ZIG-005), so custom headers live in a bounded array
/// rather than a heap-allocated list. 16 is generous headroom over every other
/// SDK's real-world usage; raise it if a caller ever needs more.
pub const max_custom_headers = 16;

/// Client-scope send context, copied from the `Client` into every builder so a
/// terminal can reach the network without the caller threading a transport
/// (HANDOFF-046 DECISION 1a: the transport lives on the Client).
///
/// Every field is COPY-SAFE by construction — `gpa` and `io` are values, and
/// the custom headers live in a bounded ARRAY, not a slice into the Client.
/// That is load-bearing: builders are immutable value types (each chain method
/// returns a fresh copy), so a slice pointing into the originating `Client`
/// would dangle the moment a forked builder outlived it — the same trap
/// `Text.chatConfig` documents for its inline `media_` array. Read the headers
/// through `customHeaders()` on a `*const Ctx` that outlives the use.
///
/// `HttpTransport` is NOT stored: it is two fields (`gpa`, `io`) and builds a
/// fresh `std.http.Client` per send anyway, so each terminal constructs one on
/// its own stack. Storing it would put a `*anyopaque` self-pointer inside a
/// value type that gets copied — precisely the dangle this struct avoids.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_url: ?[]const u8 = null,
    /// The signing inputs a SigV4 provider (Bedrock) needs beyond the access
    /// key, which is the terminal's `api_key`. Set by `Client.awsCredentials`.
    /// The slices are borrowed and must outlive the client.
    aws: ?AwsCredentials = null,
    /// Test seam: a fixed SigV4 signing time in Unix seconds. Null signs with
    /// the `io` real-time clock. The timestamp is the only non-deterministic
    /// signing input, so fixing it makes the whole signature reproducible.
    signing_time_s: ?i64 = null,
    /// How long a send waits for the next bytes from the provider, in
    /// milliseconds (BUG-062). 0 disables it. Set by `Client.timeout`.
    timeout_ms: u64 = client_defaults.default_timeout_ms,
    custom_headers: [max_custom_headers]Header = undefined,
    custom_header_count: usize = 0,
    middleware: [middleware.max_middleware]middleware.Middleware = undefined,
    middleware_count: usize = 0,
    /// Transport override. When set, the public terminals send through THIS
    /// instead of building an `HttpTransport` from `gpa`/`io`.
    ///
    /// Without it the public terminals (`prompt`, `generate`, `run`, …) are
    /// unreachable from a test: each one constructs a real `std.http.Client`, so
    /// the only network-free path was the `*With` variant — meaning the surface
    /// users actually call was the one nothing could exercise. That is precisely
    /// the gap `coverage.public-symbol-untested` exists to catch. Mirrors Go's
    /// injectable `*http.Client` seam.
    transport: ?Transport = null,

    /// Return a copy that sends through `t` (the test seam; also a hook for a
    /// caller with their own transport).
    pub fn withTransport(self: Ctx, t: Transport) Ctx {
        var c = self;
        c.transport = t;
        return c;
    }

    /// The custom headers as a slice. Borrows from `self`, so the result is
    /// valid only while THIS `Ctx` is alive — call it in-place at the terminal.
    pub fn customHeaders(self: *const Ctx) []const Header {
        return self.custom_headers[0..self.custom_header_count];
    }

    /// The middleware hooks as a slice. Borrows from `self` (see above).
    pub fn middlewares(self: *const Ctx) []const middleware.Middleware {
        return self.middleware[0..self.middleware_count];
    }

    /// Record one middleware hook, returning a fresh copy.
    pub fn withMiddleware(self: Ctx, m: middleware.Middleware) Ctx {
        var c = self;
        std.debug.assert(c.middleware_count < middleware.max_middleware);
        c.middleware[c.middleware_count] = m;
        c.middleware_count += 1;
        return c;
    }

    /// Record one custom header, returning a fresh copy (immutable-builder
    /// discipline). Asserts on overflow rather than silently dropping.
    pub fn withHeader(self: Ctx, name: []const u8, value: []const u8) Ctx {
        var c = self;
        std.debug.assert(c.custom_header_count < max_custom_headers);
        c.custom_headers[c.custom_header_count] = .{ .name = name, .value = value };
        c.custom_header_count += 1;
        return c;
    }
};

/// Minimal percent-encoder for the query-key / cursor use case. RFC-3986
/// unreserved characters pass through; everything else is `%XX`. Matches Rust's
/// `urlencode` so the cross-SDK URL bytes agree. Lives here (not in models.zig,
/// where the catalogue path grew it first) because the send terminals need the
/// identical assembly — one home, not a "remember to encode in N places" rule.
pub fn urlencode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const hexdig = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(arena, ch),
            else => {
                try out.append(arena, '%');
                try out.append(arena, hexdig[ch >> 4]);
                try out.append(arena, hexdig[ch & 0x0F]);
            },
        }
    }
    return out.toOwnedSlice(arena);
}

/// Substitute the `{model}` placeholder a generated endpoint template may carry
/// (Google `/v1beta/models/{model}:generateContent`, Vertex
/// `/{model}:predictLongRunning`, Azure's deployment path). A template without
/// the placeholder is returned unchanged, so every caller can pass its endpoint
/// through unconditionally rather than testing for the placeholder first.
///
/// Lives beside `buildUrl` for the same reason `urlencode` does: three
/// capabilities (image, video, music) read a `{model}`-bearing endpoint out of
/// their generated config, and "remember to substitute in N places" is the shape
/// this project root-fixes into N = 1.
pub fn substituteModel(arena: std.mem.Allocator, template: []const u8, model_id: []const u8) ![]const u8 {
    const placeholder = "{model}";
    const idx = std.mem.indexOf(u8, template, placeholder) orelse return template;
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{
        template[0..idx],
        model_id,
        template[idx + placeholder.len ..],
    });
}

/// Substitute the `{region}` placeholder a provider's base URL may carry
/// (Bedrock `https://bedrock-runtime.{region}.amazonaws.com`). A base without
/// the placeholder is returned unchanged.
fn substituteRegion(arena: std.mem.Allocator, base: []const u8, region: []const u8) ![]const u8 {
    const placeholder = "{region}";
    const idx = std.mem.indexOf(u8, base, placeholder) orelse return base;
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ base[0..idx], region, base[idx + placeholder.len ..] });
}

/// Assemble a send URL: the client's base-URL override (else the provider's
/// `base_url`) + `endpoint`, with the QueryParamKey `?key=` spliced in for
/// query-auth providers (Google) — those carry NO auth header, so without this
/// splice the request would go out unauthenticated. Bearer / header-key / SigV4
/// providers carry the key elsewhere and get a bare URL. `region` fills a
/// `{region}` placeholder in the base URL (SigV4 providers); pass "" otherwise.
///
/// VULN-001: the returned URL embeds the API key for query-auth providers.
/// Never put it in an error message or a log line.
pub fn buildUrl(
    arena: std.mem.Allocator,
    provider: providers.ProviderName,
    base_url_override: ?[]const u8,
    endpoint: []const u8,
    api_key: []const u8,
    region: []const u8,
) ![]const u8 {
    const base = try substituteRegion(arena, base_url_override orelse providers.spec(provider).base_url, region);
    const full = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, endpoint });
    if (request_defs.authScheme(provider) != .query_param_key) return full;

    const sep: u8 = if (std.mem.indexOfScalar(u8, full, '?') != null) '&' else '?';
    return std.fmt.allocPrint(arena, "{s}{c}{s}={s}", .{
        full,
        sep,
        providers.spec(provider).auth_query_param,
        try urlencode(arena, api_key),
    });
}

/// Compose the full outbound header set for one send, in the order the wire
/// expects: auth (+ the provider's required header) from `buildAuthHeaders`,
/// then `extra` (the per-request contract headers `request.buildRequestHeaders`
/// produces — betas and the like), then `content_type` when the request carries
/// a body, then the client's custom headers.
///
/// Names already present are skipped case-insensitively, so `extra`'s duplicate
/// copy of the required header does not go out twice and a caller's
/// `addHeader("Authorization", …)` cannot silently shadow the real credential.
/// Mirrors Swift `applyCustomHeaders` (ADR-052 parity).
///
/// Sending `content_type` is not cosmetic: `sigv4.zig` SIGNS `content-type`
/// whenever the request has one, and the sigv4-wire golden locks
/// `content-type;host;x-amz-content-sha256;x-amz-date` — a signed-but-unsent
/// header is the exact live-403 class CR-002 caught in three other SDKs.
pub fn composeHeaders(
    arena: std.mem.Allocator,
    provider: providers.ProviderName,
    api_key: []const u8,
    extra: []const Header,
    content_type: ?[]const u8,
    custom: []const Header,
) ![]Header {
    var list: std.ArrayList(Header) = .empty;
    try list.appendSlice(arena, try buildAuthHeaders(arena, provider, api_key));

    for (extra) |h| try appendUnlessPresent(arena, &list, h);
    if (content_type) |ct|
        try appendUnlessPresent(arena, &list, .{ .name = "content-type", .value = ct });
    for (custom) |h| try appendUnlessPresent(arena, &list, h);

    return list.toOwnedSlice(arena);
}

fn appendUnlessPresent(arena: std.mem.Allocator, list: *std.ArrayList(Header), h: Header) !void {
    for (list.items) |existing|
        if (std.ascii.eqlIgnoreCase(existing.name, h.name)) return;
    try list.append(arena, h);
}
















































































































