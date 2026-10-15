//! The one send seam every public terminal routes through (HANDOFF-046 slice 1).
//!
//! Each capability's terminal is `buildBody -> send -> parse*Response`. This
//! module is the middle third, and it exists so the parts that are IDENTICAL
//! across capabilities live once: URL assembly (base-URL override + the
//! QueryParamKey splice + the SigV4 region), header composition (auth or SigV4
//! signature + contract + content-type + custom), the middleware pre/post fire
//! pair, and the non-2xx check.
//!
//! That N=1 discipline is the point. The alternative — each terminal assembling
//! its own URL and headers — is exactly the "remember to do X in N places" shape
//! this project root-fixes, and the class that produced the cross-SDK SigV4
//! content-type divergences CR-002 caught in three SDKs at once.
//!
//! VULN-001: for a QueryParamKey provider the assembled URL CONTAINS the API
//! key. It is never placed in an error or a middleware event. Zig helps here by
//! construction — error values carry no payload, so there is no error string for
//! a URL to leak into.

const std = @import("std");
const json = @import("json.zig");
const http = @import("http.zig");
const middleware = @import("middleware.zig");
const providers = @import("providers/generated/providers.zig");
const request_defs = @import("providers/generated/request_defs.zig");
const sigv4 = @import("sigv4.zig");
const HttpTransport = @import("http_transport.zig").HttpTransport;

fn ReturnOf(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

/// Run `func(self, transport, args...)` with the transport this call should
/// use: the context's override when set, else a production `HttpTransport`
/// built from the context (BUG-080).
///
/// `http.Transport` borrows the value it points at, so the `HttpTransport`
/// lives in THIS frame and dies when the call returns. That is why it is built
/// here and nowhere else: a terminal cannot keep it, and a value that outlives
/// the call (a `BatchHandle`) stores the `http.Ctx` and comes back here on each
/// use. A source test in this file fails if `HttpTransport.transport()` is
/// called anywhere else outside the test mocks.
pub fn withTransport(ctx: *const http.Ctx, comptime func: anytype, self: anytype, args: anytype) ReturnOf(func) {
    var t = HttpTransport.fromCtx(ctx);
    return @call(.auto, func, .{ self, ctx.transport orelse t.transport() } ++ args);
}

/// A non-2xx reply, or a body that is not the media type the caller expected.
/// `Timeout` is the client's idle timeout expiring (BUG-062); every other
/// transport failure is `ApiError`. `ApiError` carries no detail because Zig errors have no payload; the parsed
/// provider envelope (message/type) travels on the capability's own response
/// struct, which is where the other SDKs put it too.
/// `MissingAwsCredentials` is a SigV4 provider (Bedrock) sent from a client
/// without `Client.awsCredentials`; no request is made.
pub const SendError = error{
    ApiError,
    MiddlewareVeto,
    MissingAwsCredentials,
    Timeout,
} || std.mem.Allocator.Error;

/// One send. `endpoint` is joined to the client's base-URL override (else the
/// provider's base); `extra_headers` are the per-request contract headers the
/// capability's own header builder produced (betas and the like).
pub const Args = struct {
    provider: providers.ProviderName,
    /// Borrowed for the duration of the call — see `http.Ctx` on why this is a
    /// pointer to a live value rather than a stored copy.
    ctx: *const http.Ctx,
    api_key: []const u8,
    endpoint: []const u8,
    extra_headers: []const http.Header = &.{},
    /// The middleware op this send performs, fired pre (vetoable) and post.
    op: middleware.MiddlewareOp,
    /// Stamped onto the middleware event so a hook can see which model was
    /// asked for. Empty when the capability has no model in play.
    model: []const u8 = "",
    /// Who fires the SUCCESS post event. A chat send sets `.by_caller` and
    /// fires it with `firePostUsage` after decoding, so the event carries the
    /// reply's token usage, as in Go and Rust (telemetry exports it). Failure
    /// posts (transport error, non-2xx) always fire here.
    post: enum { on_reply, by_caller } = .on_reply,
};

/// The pre-phase event this send fires: op, provider, and model.
fn baseEvent(args: Args) middleware.Event {
    return .{
        .op = args.op,
        .phase = .pre,
        .provider = @tagName(args.provider),
        .model = args.model,
    };
}

/// Fire the success post for a `.by_caller` send, carrying the decoded reply's
/// usage. `input`/`output` are null when the provider did not report them.
pub fn firePostUsage(args: Args, input: ?i64, output: ?i64) void {
    var ev = baseEvent(args);
    ev.usage = .{ .input = input, .output = output };
    middleware.firePost(args.ctx.middlewares(), ev);
}

/// Fire the post for a `.by_caller` send whose 2xx reply could not be decoded.
pub fn firePostDecodeError(args: Args) void {
    var ev = baseEvent(args);
    middleware.setEventError(&ev, .{ .decoding = "could not decode the provider reply" });
    middleware.firePost(args.ctx.middlewares(), ev);
}

/// POST a JSON body and decode the JSON reply.
pub fn postJson(
    transport: http.Transport,
    arena: std.mem.Allocator,
    args: Args,
    body: json.Value,
) !json.Value {
    return (try postJsonWithText(transport, arena, args, body)).value;
}

/// A JSON reply as BOTH the source bytes and the parsed tree.
pub const Reply = struct { text: []const u8, value: json.Value };

/// POST a JSON body and return the reply bytes alongside the parsed tree.
///
/// The chat paths need both: ADR-085 captures the assistant turn from the
/// ORIGINAL text — a tree re-serialized through `json.stringify` is the SDK's
/// rendering, not the provider's — while every other field is read off the tree.
pub fn postJsonWithText(
    transport: http.Transport,
    arena: std.mem.Allocator,
    args: Args,
    body: json.Value,
) !Reply {
    const raw = try postRaw(transport, arena, args, try json.stringify(arena, body), "application/json");
    const value = std.json.parseFromSliceLeaky(json.Value, arena, raw, .{}) catch {
        if (args.post == .by_caller) firePostDecodeError(args);
        return error.ApiError;
    };
    return .{ .text = raw, .value = value };
}

/// POST a pre-encoded body and return the RAW reply bytes. Used by the
/// capabilities whose reply is not JSON (speech returns audio bytes) and by the
/// multipart paths (upload, OpenAI transcription), which encode their own body
/// and supply their own `content_type`.
pub fn postRaw(
    transport: http.Transport,
    arena: std.mem.Allocator,
    args: Args,
    body: []const u8,
    content_type: []const u8,
) ![]const u8 {
    return roundTrip(transport, arena, args, .POST, body, content_type);
}

/// GET and return the RAW reply bytes (the poll and results hops).
pub fn getRaw(
    transport: http.Transport,
    arena: std.mem.Allocator,
    args: Args,
) ![]const u8 {
    // No body, therefore no content-type: sending one on a bodyless GET is the
    // divergence CR-002 fixed in Python, and signing one you do not send is the
    // live-403 it fixed in Swift and Java.
    return roundTrip(transport, arena, args, .GET, "", null);
}

/// GET and decode a JSON reply.
pub fn getJson(
    transport: http.Transport,
    arena: std.mem.Allocator,
    args: Args,
) !json.Value {
    const raw = try getRaw(transport, arena, args);
    return std.json.parseFromSliceLeaky(json.Value, arena, raw, .{}) catch error.ApiError;
}

fn roundTrip(
    transport: http.Transport,
    arena: std.mem.Allocator,
    args: Args,
    method: http.Method,
    body: []const u8,
    content_type: ?[]const u8,
) ![]const u8 {
    // A SigV4 provider cannot send without its signing inputs. Checked first,
    // so a misconfigured client fails without firing middleware or sending.
    const sig_v4 = request_defs.authScheme(args.provider) == .sig_v4;
    const aws: ?http.AwsCredentials = if (sig_v4) (args.ctx.aws orelse return error.MissingAwsCredentials) else null;

    const mws = args.ctx.middlewares();
    const base = baseEvent(args);

    // Pre-phase veto happens BEFORE the URL is assembled, so a vetoed call
    // never even materializes a key-bearing URL in memory.
    var veto_reason: []const u8 = "";
    middleware.firePre(mws, base, &veto_reason) catch return error.MiddlewareVeto;

    const url = try http.buildUrl(arena, args.provider, args.ctx.base_url, args.endpoint, args.api_key, if (aws) |a| a.region else "");
    // The signature headers go first, so `composeHeaders` skips any contract
    // or custom header of the same name: a signed value is never altered, and
    // the remaining unsigned headers ride alongside (ADR-052, as in Go/Rust).
    const extra = if (aws) |a| blk: {
        const signed = try signedHeaders(arena, args, a, method, url, body, content_type);
        const all = try arena.alloc(http.Header, signed.len + args.extra_headers.len);
        @memcpy(all[0..signed.len], signed);
        @memcpy(all[signed.len..], args.extra_headers);
        break :blk all;
    } else args.extra_headers;
    const headers = try http.composeHeaders(
        arena,
        args.provider,
        args.api_key,
        extra,
        content_type,
        args.ctx.customHeaders(),
    );

    const resp = transport.send(arena, .{
        .method = method,
        .url = url,
        .headers = headers,
        .body = body,
    }) catch |err| {
        const timed_out = err == error.Timeout;
        var ev = base;
        middleware.setEventError(&ev, .{ .transport = if (timed_out) "timeout" else "transport error" });
        middleware.firePost(mws, ev);
        return if (timed_out) error.Timeout else error.ApiError;
    };

    if (resp.status < 200 or resp.status >= 300) {
        var ev = base;
        middleware.setEventError(&ev, .{
            .api = .{
                .provider = @tagName(args.provider),
                .status_code = resp.status,
                // The provider's own message travels on the capability's response
                // struct; the event carries the stable kind, never the URL.
                .message = "provider returned a non-2xx status",
            },
        });
        middleware.firePost(mws, ev);
        return error.ApiError;
    }

    if (args.post == .on_reply) middleware.firePost(mws, base);
    return resp.body;
}

/// Sign one request with AWS SigV4 and return the headers the signature covers
/// that the transport does not add itself: `Authorization`, `x-amz-date`,
/// `x-amz-content-sha256`, and `x-amz-security-token` when a session token is
/// set. `host` is signed too, but `std.http` writes it from the same URL.
/// `content-type` is signed when present and is added by `composeHeaders` with
/// the same value. The access key ID is the terminal's `api_key`; the region
/// and service come from the client and the provider's `service_name` fact.
fn signedHeaders(
    arena: std.mem.Allocator,
    args: Args,
    aws: http.AwsCredentials,
    method: http.Method,
    url: []const u8,
    body: []const u8,
    content_type: ?[]const u8,
) ![]const http.Header {
    const now_s = args.ctx.signing_time_s orelse std.Io.Clock.real.now(args.ctx.io).toSeconds();
    const amz_date = try arena.create([16]u8);
    const sig = try sigv4.signAt(arena, .{
        .method = @tagName(method),
        .url = url,
        .body = body,
        .content_type = content_type orelse "",
        .access_key = args.api_key,
        .secret_key = aws.secret_access_key,
        .session_token = aws.session_token,
        .region = aws.region,
        .service = providers.spec(args.provider).service_name,
        .amz_date = sigv4.amzDate(amz_date, now_s),
    });

    var list: std.ArrayList(http.Header) = .empty;
    try list.append(arena, .{ .name = "Authorization", .value = sig.authorization });
    try list.append(arena, .{ .name = "x-amz-date", .value = amz_date });
    try list.append(arena, .{ .name = "x-amz-content-sha256", .value = sig.payload_hash });
    if (aws.session_token.len > 0)
        try list.append(arena, .{ .name = "x-amz-security-token", .value = aws.session_token });
    return list.toOwnedSlice(arena);
}

// === Tests ===

const testing = std.testing;

fn testCtx(gpa: std.mem.Allocator) http.Ctx {
    return .{ .gpa = gpa, .io = testing.io };
}





























































































































/// The value of the header named `name` (case-insensitive), or null.
fn headerValue(headers: []const http.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

// The AWS docs example credentials and frozen clock every SDK's sigv4-wire
//
const sigv4_access_key = "AKIDEXAMPLE";
const sigv4_secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"; // AWS docs example creds #gitleaks:allow
const sigv4_frozen_clock_s: i64 = 1784332800; // 2026-07-18T00:00:00Z








































































































