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
//!     stream path facts. The response-wire `stream-{openai,google,anthropic}`
//!     goldens assert this projection. Both SSE forms are read: data-only
//!     (OpenAI-compat fleet + Google) and event-typed (`uses_event_types`,
//!     Anthropic), where the `event:` name selects which facts a frame feeds.
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
const telemetry = @import("telemetry.zig");
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
/// Response. `on_chunk`, when non-null, receives each text delta in order.
///
/// One loop serves both SSE forms; every choice comes from the generated
/// `StreamDef` and the provider's `stream_finish_reason_path`, never from the
/// provider name. Each `data:` line is parsed as JSON (the `done_signal`
/// sentinel, e.g. `[DONE]`, ends the stream first).
///   - Data-only (`uses_event_types == false`): every frame may carry the delta
///     text, the finish reason and the usage counts.
///   - Event-typed (`uses_event_types == true`): the preceding `event:` line
///     names the frame. Only `content_event` frames feed text, only
///     `usage_event` frames feed usage, and `done_event` ends the stream. Frames
///     of any other type (Anthropic `ping`, `content_block_start`) are skipped.
///     A `content_event` frame without `delta_text_path` (Anthropic
///     `thinking_delta`, `signature_delta`) adds no text.
/// The finish locator (ADR-013) is `event:json.path` or a bare `json.path`; an
/// event prefix restricts it to frames of that event. The Google
/// `FINISH_REASON_UNSPECIFIED` sentinel is filtered. A usage dimension no frame
/// reports stays null (ADR-081). Strings are arena-backed. Mirrors Rust
/// `prompt_stream`.
pub fn parseSseBuffer(
    arena: std.mem.Allocator,
    provider: providers.ProviderName,
    sse: []const u8,
    on_chunk: ?ChunkCallback,
) !response.Response {
    const sd = stream_defs.streamConfig(provider) orelse return error.UnsupportedWireShape;
    const finish = splitFinishPath(providers.spec(provider).stream_finish_reason_path);

    var content: std.ArrayList(u8) = .empty;
    var finish_reason: []const u8 = "";
    var usage_input: ?i64 = null;
    var usage_output: ?i64 = null;
    var event: []const u8 = "";

    var it = std.mem.splitScalar(u8, sse, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "event:")) {
            event = std.mem.trim(u8, line["event:".len..], " ");
            continue;
        }
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line["data:".len..], " ");
        if (payload.len == 0) continue;
        if (std.mem.eql(u8, payload, sd.done_signal)) break;

        // Leaky parse into the arena: every value is arena-backed, so a delta
        // string can be appended and a finish string referenced without a
        // per-line free (the whole arena is reclaimed at the end).
        const parsed = std.json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch null;
        const frame_event = event;
        event = "";

        if (parsed) |value| {
            if (finish.path.len > 0 and (finish.event.len == 0 or std.mem.eql(u8, finish.event, frame_event))) {
                if (json.getPath(value, finish.path)) |v| if (v == .string) {
                    if (v.string.len > 0 and !std.mem.eql(u8, v.string, "FINISH_REASON_UNSPECIFIED"))
                        finish_reason = v.string;
                };
            }
        }

        if (sd.uses_event_types and sd.done_event.len > 0 and std.mem.eql(u8, frame_event, sd.done_event)) break;

        const value = parsed orelse continue;
        const feeds_text = !sd.uses_event_types or std.mem.eql(u8, frame_event, sd.content_event);
        const feeds_usage = !sd.uses_event_types or std.mem.eql(u8, frame_event, sd.usage_event);

        if (feeds_text) {
            if (json.getPath(value, sd.delta_text_path)) |v| if (v == .string) {
                try content.appendSlice(arena, v.string);
                if (on_chunk) |cb| if (v.string.len > 0) cb(v.string);
            };
        }
        if (feeds_usage) {
            if (intAt(value, sd.usage_input_path)) |n| usage_input = n;
            if (intAt(value, sd.usage_output_path)) |n| usage_output = n;
        }
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

/// An ADR-013 stream-finish locator split into its optional event name and
/// its JSON path: `event:path` -> (event, path); a bare `path` -> ("", path).
const FinishPath = struct { event: []const u8, path: []const u8 };

fn splitFinishPath(p: []const u8) FinishPath {
    if (std.mem.indexOfScalar(u8, p, ':')) |i| return .{ .event = p[0..i], .path = p[i + 1 ..] };
    return .{ .event = "", .path = p };
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
    const args = send.Args{
        .provider = cfg.provider,
        .ctx = ctx,
        .api_key = api_key,
        .endpoint = endpoint,
        .extra_headers = try request.buildRequestHeaders(arena, cfg),
        .op = .llm_request,
        .model = model,
        .post = .by_caller,
    };
    const raw = try send.postRaw(transport, arena, args, try json.stringify(arena, body), "application/json");
    const resp = parseSseBuffer(arena, cfg.provider, raw, on_chunk) catch |err| {
        send.firePostDecodeError(args);
        return err;
    };
    // The post event carries the streamed usage frame (Go parity).
    send.firePostUsage(args, resp.usage.input, resp.usage.output);
    return resp;
}














































































































