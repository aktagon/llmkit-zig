//! The one send seam every public terminal routes through (HANDOFF-046 slice 1).
//!
//! Each capability's terminal is `buildBody -> send -> parse*Response`. This
//! module is the middle third, and it exists so the parts that are IDENTICAL
//! across capabilities live once: URL assembly (base-URL override + the
//! QueryParamKey splice), header composition (auth + contract + content-type +
//! custom), the middleware pre/post fire pair, and the non-2xx check.
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

/// A non-2xx reply, or a body that is not the media type the caller expected.
/// `ApiError` carries no detail because Zig errors have no payload; the parsed
/// provider envelope (message/type) travels on the capability's own response
/// struct, which is where the other SDKs put it too.
pub const SendError = error{
    ApiError,
    MiddlewareVeto,
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
};

/// POST a JSON body and decode the JSON reply.
pub fn postJson(
    transport: http.Transport,
    arena: std.mem.Allocator,
    args: Args,
    body: json.Value,
) !json.Value {
    const raw = try postRaw(transport, arena, args, try json.stringify(arena, body), "application/json");
    return std.json.parseFromSliceLeaky(json.Value, arena, raw, .{}) catch error.ApiError;
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
    const mws = args.ctx.middlewares();
    const base = middleware.Event{
        .op = args.op,
        .phase = .pre,
        .provider = @tagName(args.provider),
        .model = args.model,
    };

    // Pre-phase veto happens BEFORE the URL is assembled, so a vetoed call
    // never even materializes a key-bearing URL in memory.
    var veto_reason: []const u8 = "";
    middleware.firePre(mws, base, &veto_reason) catch return error.MiddlewareVeto;

    const url = try http.buildUrl(arena, args.provider, args.ctx.base_url, args.endpoint, args.api_key);
    const headers = try http.composeHeaders(
        arena,
        args.provider,
        args.api_key,
        args.extra_headers,
        content_type,
        args.ctx.customHeaders(),
    );

    const resp = transport.send(arena, .{
        .method = method,
        .url = url,
        .headers = headers,
        .body = body,
    }) catch {
        var ev = base;
        middleware.setEventError(&ev, .{ .transport = "transport error" });
        middleware.firePost(mws, ev);
        return error.ApiError;
    };

    if (resp.status < 200 or resp.status >= 300) {
        var ev = base;
        middleware.setEventError(&ev, .{ .api = .{
            .provider = @tagName(args.provider),
            .status_code = resp.status,
            // The provider's own message travels on the capability's response
            // struct; the event carries the stable kind, never the URL.
            .message = "provider returned a non-2xx status",
        } });
        middleware.firePost(mws, ev);
        return error.ApiError;
    }

    middleware.firePost(mws, base);
    return resp.body;
}

// === Tests ===

const testing = std.testing;

fn testCtx(gpa: std.mem.Allocator) http.Ctx {
    return .{ .gpa = gpa, .io = testing.io };
}




























































































































