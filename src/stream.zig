//! Streaming (ADR-013) — Phase 3 slice 2.
//!
//! Two pure seams plus a terminal:
//!   - `buildStreamBody` (OUTBOUND): the chat body + the stream flag +, when the
//!     provider's `usage_opt_in` fact is set (BUG-028), `stream_options.
//!     include_usage:true`. The request-wire `stream-openai` golden asserts these
//!     bytes. All from the generated `StreamDef`, never a provider-name switch.
//!   - `parseSseBuffer` (INBOUND): a full `text/event-stream` buffer -> the same
//!     normalized `response.Response` the sync chat path yields, accumulating the
//!     text deltas and reading the finish reason + usage from the generated
//!     stream path facts. The response-wire `stream-{openai,google}` goldens
//!     assert this projection. DATA-ONLY shapes (OpenAI-compat fleet + Google);
//!     the event-typed Anthropic stream (`uses_event_types`) is deferred to a
//!     later phase (mirrors the project-wide Anthropic-stream deferral in the
//!     response-wire suite).
//!   - `stream` (the terminal): send the stream request through the injected
//!     `Transport`, feed the response body to `parseSseBuffer` (delivering each
//!     text delta to the caller's callback), and return the accumulated Response.
//!     Production builds an `HttpTransport`; the unit test injects a
//!     `MockTransport`. Mirrors Rust `prompt_stream` / Go `promptStream`.

const std = @import("std");
const json = @import("json.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const http = @import("http.zig");
const send = @import("send.zig");
const caching_mod = @import("caching.zig");
const providers = @import("providers/generated/providers.zig");
const stream_defs = @import("providers/generated/stream.zig");

/// A per-delta text callback (the streaming ergonomic). Stateless — the
/// accumulated Response carries the final text/usage/finish, so a caller that
/// only wants the whole reply passes a no-op.
pub const ChunkCallback = *const fn (chunk: []const u8) void;

/// Build the streaming request body for `cfg`: the chat body from
/// `request.buildChatBody`, plus the stream flag (`stream:true`) and — when the
/// provider opts in (BUG-028) — `stream_options:{include_usage:true}`. The
/// stream flag key + value come from the generated `StreamDef` (`param` /
/// `param_value`); `param_value` "true"/"false" emits a JSON boolean (matching
/// the golden's `"stream": true`), any other value a string.
pub fn buildStreamBody(arena: std.mem.Allocator, cfg: request.ChatConfig) request.BuildError!json.Value {
    var body = try request.buildChatBody(arena, cfg);
    const sd = stream_defs.streamConfig(cfg.provider) orelse return body;

    if (sd.param.len > 0)
        try json.set(arena, &body, sd.param, boolOrString(sd.param_value));

    if (sd.usage_opt_in) {
        var so = json.object();
        try json.set(arena, &so, "include_usage", .{ .bool = true });
        try json.set(arena, &body, "stream_options", so);
    }
    return body;
}

/// "true"/"false" -> a JSON boolean; anything else -> the string verbatim.
fn boolOrString(v: []const u8) json.Value {
    if (std.mem.eql(u8, v, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, v, "false")) return .{ .bool = false };
    return .{ .string = v };
}

/// Parse a full SSE (`text/event-stream`) buffer into the normalized chat
/// Response. `on_chunk`, when non-null, receives each text delta in order. Only
/// the DATA-ONLY assembly is implemented (OpenAI-compat fleet + Google); an
/// `uses_event_types` provider (Anthropic) rejects with `UnsupportedWireShape`.
///
/// Assembly (data-only): each `data:` line is parsed as JSON (skipping the
/// `[DONE]` sentinel); the delta text at `delta_text_path` is appended, the
/// finish reason read from `stream_finish_reason_path` (filtering the Google
/// `FINISH_REASON_UNSPECIFIED` sentinel), and the input/output token counts read
/// from the usage paths — every path from the generated `StreamDef`. Strings are
/// arena-backed. Mirrors Rust `prompt_stream`'s data-only branch.
pub fn parseSseBuffer(
    arena: std.mem.Allocator,
    provider: providers.ProviderName,
    sse: []const u8,
    on_chunk: ?ChunkCallback,
) !response.Response {
    const sd = stream_defs.streamConfig(provider) orelse return error.UnsupportedWireShape;
    if (sd.uses_event_types) return error.UnsupportedWireShape;

    // ADR-013: the finish path is `event_name:json.path`; a data-only provider
    // carries no event prefix (no ':'), so the whole string is the JSON path.
    const finish_path = finishJsonPath(providers.spec(provider).stream_finish_reason_path);

    var content: std.ArrayList(u8) = .empty;
    var finish_reason: []const u8 = "";
    var usage_input: i64 = 0;
    var usage_output: i64 = 0;

    var it = std.mem.splitScalar(u8, sse, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line["data:".len..], " ");
        if (payload.len == 0) continue;
        if (std.mem.eql(u8, payload, sd.done_signal)) break;

        // Leaky parse into the arena: every value is arena-backed, so a delta
        // string can be appended and a finish string referenced without a
        // per-line free (the whole arena is reclaimed at the end).
        const value = std.json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch continue;

        if (json.getPath(value, sd.delta_text_path)) |v| if (v == .string) {
            try content.appendSlice(arena, v.string);
            if (on_chunk) |cb| if (v.string.len > 0) cb(v.string);
        };

        if (finish_path.len > 0) {
            if (json.getPath(value, finish_path)) |v| if (v == .string) {
                if (!std.mem.eql(u8, v.string, "FINISH_REASON_UNSPECIFIED"))
                    finish_reason = v.string;
            };
        }

        if (intAt(value, sd.usage_input_path)) |n| usage_input = n;
        if (intAt(value, sd.usage_output_path)) |n| usage_output = n;
    }

    return .{
        .text = try content.toOwnedSlice(arena),
        .finish_reason = try arena.dupe(u8, finish_reason),
        .finish_message = null,
        .usage = .{ .input = usage_input, .output = usage_output },
        .raw = null,
        .provider_turn = null,
    };
}

/// The JSON-path half of `stream_finish_reason_path` (`event:path` -> `path`);
/// a data-only path has no ':' so it is returned whole.
fn finishJsonPath(p: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, p, ':')) |i| return p[i + 1 ..];
    return p;
}

/// Read a non-null integer at a dotted path, or null when absent/non-numeric —
/// so a chunk that carries `usage:null` (every non-final OpenAI chunk) leaves
/// the running total untouched instead of zeroing it.
fn intAt(value: json.Value, path: []const u8) ?i64 {
    if (path.len == 0) return null;
    const v = json.getPath(value, path) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// The streaming terminal over an injected transport (the seam the unit test
/// mocks). Sends the stream request, feeds the response body to `parseSseBuffer`
/// (delivering deltas to `on_chunk`), and returns the accumulated Response. The
/// auth headers are built from the provider's `authScheme` fact. `arena` backs
/// both the request body and the returned Response.
pub fn streamWith(
    transport: http.Transport,
    arena: std.mem.Allocator,
    ctx: *const http.Ctx,
    cfg: request.ChatConfig,
    api_key: []const u8,
    on_chunk: ?ChunkCallback,
) !response.Response {
    var body = try buildStreamBody(arena, cfg);
    const model = try request.effectiveModel(providers.spec(cfg.provider), cfg.model);
    if (cfg.caching) try caching_mod.applyResourceCaching(transport, arena, ctx, cfg.provider, api_key, model, &body);
    // A provider that streams from its own endpoint declares it (Google
    // `:streamGenerateContent?alt=sse`); the rest stream from the chat endpoint.
    const stream_endpoint = if (stream_defs.streamConfig(cfg.provider)) |sd| sd.endpoint else "";
    const endpoint = if (stream_endpoint.len > 0)
        try http.substituteModel(arena, stream_endpoint, model)
    else
        try request.chatEndpoint(arena, cfg);
    const raw = try send.postRaw(
        transport,
        arena,
        .{
            .provider = cfg.provider,
            .ctx = ctx,
            .api_key = api_key,
            .endpoint = endpoint,
            .extra_headers = try request.buildRequestHeaders(arena, cfg),
            .op = .llm_request,
            .model = model,
        },
        try json.stringify(arena, body),
        "application/json",
    );
    return parseSseBuffer(arena, cfg.provider, raw, on_chunk);
}


















































