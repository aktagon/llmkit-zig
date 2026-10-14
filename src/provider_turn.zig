//! Verbatim assistant-turn capture (ADR-085).
//!
//! llmkit keeps a canonical projection of every turn — role, content, tool calls
//! — and rebuilds the next request's assistant turn from it. That projection is
//! lossy in three ways (ADR-085 §1): it has nowhere to put reasoning, it drops
//! assistant prose that accompanies a tool call, and it has no slot for per-part
//! provider metadata. The fix is not a richer projection but a second
//! representation alongside it: keep the provider's own bytes for the turn and
//! send those back unchanged.
//!
//! Nothing here parses the payload. The only structure this file reads is the
//! path down to the turn — everything at and below it is carried as the provider
//! wrote it.
//!
//! **Scope in Zig: capture only.** The Zig SDK has no multi-turn message-history
//! body builder yet — `request.flatMessages` emits one user turn, and the agent's
//! auto-execution tool LOOP is deferred with it (see the scope note at the top of
//! `agent.zig`, HANDOFF-043). Replay is a splice into a history array that does
//! not exist here, so the second leg lands with that builder. Capture is wired
//! now, on the send seams, because `Response.provider_turn` is what lets a caller
//! running their own loop thread the turn forward (ADR-085 § 6) — and because a
//!
//!
//! Zig-specific note. `decodeResponse` takes a parsed `json.Value`, not bytes:
//! the pure wire seam is Value-typed at both ends and the send seam does the
//! stringify/parse (ADR-069 ZIG-002). A parsed tree has no memory of the source
//! text, so capture cannot happen inside that codec without changing its
//! signature — it happens at the send seam, which still holds the reply bytes,
//! and slices them.

const std = @import("std");
const providers = @import("providers/generated/providers.zig");

/// One assistant turn exactly as the provider serialized it, captured at
/// `assistantTurnPath` (ADR-085). It sits BESIDE the canonical projection,
/// not instead of it. `wire` is verbatim JSON TEXT rather than a parsed value so
/// it survives at rest byte-for-byte; `wire_shape` is the `ChatWireShape`
/// that produced it, spelled exactly as the SDK constant, because a payload is
/// only ever replayed under the shape that produced it (RSN-006).
pub const ProviderTurn = @import("providers/generated/structs.zig").ProviderTurn;

/// One dot-notation path segment: a field name plus an array index, or `null`
/// when the segment carries none.
pub const Segment = struct { field: []const u8, index: ?usize };

/// Split one dot-notation path segment: `"choices[0]"` -> `("choices", 0)`;
/// `"message"` -> `("message", null)`.
///
///
/// single parser here, so capture cannot drift from the path facts it reads. A
/// malformed segment yields the whole segment as a field name and no index, which
/// resolves to "no such field" one step later — never a silently widened match to
/// the whole array, which is what a negative index would read back as.
pub fn splitPathSegment(part: []const u8) Segment {
    const bracket = std.mem.indexOfScalar(u8, part, '[') orelse return .{ .field = part, .index = null };
    if (part.len == 0 or part[part.len - 1] != ']') return .{ .field = part, .index = null };
    const inner = part[bracket + 1 .. part.len - 1];
    if (inner.len == 0) return .{ .field = part, .index = null };
    for (inner) |c| {
        // Digits only: "+1", "-1" and " 1" would otherwise parse or read back as
        // a negative index.
        if (c < '0' or c > '9') return .{ .field = part, .index = null };
    }
    const index = std.fmt.parseInt(usize, inner, 10) catch return .{ .field = part, .index = null };
    return .{ .field = part[0..bracket], .index = index };
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and isWhitespace(text[i])) i += 1;
    return i;
}

/// The index just past the JSON string starting at `start`, or null.
fn skipString(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '"') return null;
    var i = start + 1;
    while (i < text.len) {
        if (text[i] == '\\') {
            i += 2;
            continue;
        }
        if (text[i] == '"') return i + 1;
        i += 1;
    }
    return null;
}

/// The index just past the JSON value starting at `start`, or null when the text
/// there is not a value. Objects and arrays are walked by nesting depth, which is
/// why the string scan above has to be exact — a `}` inside a string must not
/// close an object.
fn skipValue(text: []const u8, start: usize) ?usize {
    var i = skipWhitespace(text, start);
    if (i >= text.len) return null;
    if (text[i] == '"') return skipString(text, i);
    if (text[i] == '{' or text[i] == '[') {
        var depth: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '"') {
                i = skipString(text, i) orelse return null;
                continue;
            }
            if (c == '{' or c == '[') {
                depth += 1;
            } else if (c == '}' or c == ']') {
                depth -= 1;
                if (depth == 0) return i + 1;
            }
            i += 1;
        }
        return null;
    }
    // A literal or number: everything up to the next structural character.
    const value_start = i;
    while (i < text.len and text[i] != ',' and text[i] != '}' and text[i] != ']' and !isWhitespace(text[i])) {
        i += 1;
    }
    return if (i > value_start) i else null;
}

const Span = struct { start: usize, end: usize };

/// The half-open span of `field`'s value in the object beginning at `start`.
fn spanOfMember(text: []const u8, start: usize, field: []const u8) ?Span {
    var i = skipWhitespace(text, start);
    if (i >= text.len or text[i] != '{') return null;
    i += 1;
    while (true) {
        i = skipWhitespace(text, i);
        if (i >= text.len or text[i] == '}') return null;
        const key_end = skipString(text, i) orelse return null;
        // The key text includes its quotes; compare against the field name
        //
        const key = text[i + 1 .. key_end - 1];
        i = skipWhitespace(text, key_end);
        if (i >= text.len or text[i] != ':') return null;
        const value_start = skipWhitespace(text, i + 1);
        const value_end = skipValue(text, value_start) orelse return null;
        if (std.mem.eql(u8, key, field)) return .{ .start = value_start, .end = value_end };
        i = skipWhitespace(text, value_end);
        if (i >= text.len or text[i] != ',') return null;
        i += 1;
    }
}

/// The half-open span of element `index` in the array beginning at `start`.
fn spanOfElement(text: []const u8, start: usize, index: usize) ?Span {
    var i = skipWhitespace(text, start);
    if (i >= text.len or text[i] != '[') return null;
    i += 1;
    var position: usize = 0;
    while (true) {
        i = skipWhitespace(text, i);
        if (i >= text.len or text[i] == ']') return null;
        const value_end = skipValue(text, i) orelse return null;
        if (position == index) return .{ .start = i, .end = value_end };
        position += 1;
        i = skipWhitespace(text, value_end);
        if (i >= text.len or text[i] != ',') return null;
        i += 1;
    }
}

/// The VERBATIM JSON text of the value at `path` — a slice INTO `text`, so it
/// borrows the caller's bytes — or null when the path does not resolve.
///
/// The distinction from `json.getPath` is the whole point: that walker descends a
/// parsed tree, so re-serializing its result emits the SDK's rendering of the
/// value rather than the provider's.
pub fn extractRawJsonPath(text: []const u8, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    var start: usize = 0;
    var end: usize = text.len;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        const segment = splitPathSegment(part);
        if (segment.field.len > 0) {
            const span = spanOfMember(text, start, segment.field) orelse return null;
            start = span.start;
            end = span.end;
        }
        if (segment.index) |index| {
            const span = spanOfElement(text, start, index) orelse return null;
            start = span.start;
            end = span.end;
        }
    }
    return text[start..end];
}

/// Where one replayable assistant turn sits in a response body for this provider
/// under this wire shape, or `""` when the shape declares no position.
///
/// An empty result is a DECLARED absence, not a missing lookup: `ChatBedrock`
/// carries `assistantTurnUnanchored` rather than a path, because nobody has
///
/// gate refuses a wire shape that says neither, so `""` here always means
/// "declared unanchored" and never "somebody forgot".
pub fn assistantTurnPath(spec: providers.ProviderSpec, chat_wire_shape: []const u8) []const u8 {
    for (spec.chat_protocols) |protocol| {
        if (std.mem.eql(u8, protocol.wire_shape, chat_wire_shape)) return protocol.assistant_turn_path;
    }
    return "";
}

/// The shape a response was produced under. An empty argument means the caller
/// did not route through `.protocol(...)` — the batch path passes `""` because
/// batch is Chat-Completions-only (ADR-055) — so the provider's default shape
/// applies.
fn effectiveChatWireShape(spec: providers.ProviderSpec, chat_wire_shape: []const u8) []const u8 {
    return if (chat_wire_shape.len == 0) spec.chat_wire_shape else chat_wire_shape;
}

/// Lift the assistant turn out of a response body, or return null when this shape
/// declares no turn position or the body carries nothing there. Both strings in
/// the result are duped into `arena`, so the turn outlives the reply buffer.
pub fn capture(
    arena: std.mem.Allocator,
    text: []const u8,
    provider: providers.ProviderName,
    chat_wire_shape: []const u8,
) !?ProviderTurn {
    const spec = providers.spec(provider);
    const shape = effectiveChatWireShape(spec, chat_wire_shape);
    const wire = extractRawJsonPath(text, assistantTurnPath(spec, shape)) orelse return null;
    // A JSON null at the path is the provider declining to send a turn, not a
    // turn whose content is null — Google nulls candidates[0].content on a safety
    // block, and OpenAI-compatible proxies null choices[0].message on a content
    // filter. A bare `null` is four bytes of a perfectly good JSON value, so a
    // length check alone captures it and the next request would append a bare
    // null to the message array, which is a 400.
    const trimmed = std.mem.trim(u8, wire, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) return null;
    return ProviderTurn{
        .wire_shape = try arena.dupe(u8, shape),
        .wire = try arena.dupe(u8, wire),
    };
}

// --- tests ---------------------------------------------------------------
//
// Capture per wire shape, mirroring go/provider_turn_test.go's capture half.
// The bodies are trimmed, but the STRUCTURE is the one RESEARCH-017 measured
// against the live APIs — in particular that Anthropic returns
// [thinking, text, tool_use] on a turn that calls a tool, and that Google
// attaches exactly ONE thoughtSignature per turn, on the first function-call
// part. The replay half has no counterpart here: see the scope note above.

const anthropic_turn_body =
    \\{
    \\  "id": "msg_01",
    \\  "content": [
    \\    {"type": "thinking", "thinking": "The user wants weather.", "signature": "ErUBCkYIBRgCKkB0aGlz"},
    \\    {"type": "text", "text": "Let me look that up for you."},
    \\    {"type": "tool_use", "id": "toolu_01", "name": "get_weather", "input": {"city": "Oslo"}}
    \\  ],
    \\  "stop_reason": "tool_use"
    \\}
;

const google_turn_body =
    \\{
    \\  "candidates": [
    \\    {"content": {"role": "model", "parts": [
    \\      {"functionCall": {"name": "get_weather", "args": {"city": "Oslo"}}, "thoughtSignature": "CvUBAdHtim9z"},
    \\      {"functionCall": {"name": "get_weather", "args": {"city": "Bergen"}}}
    \\    ]}, "finishReason": "STOP"}
    \\  ]
    \\}
;

const openai_turn_body =
    \\{
    \\  "choices": [
    \\    {"message": {"role": "assistant", "content": "Sure, checking now.", "tool_calls": [
    \\      {"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\":\"Oslo\"}"}}
    \\    ]}, "finish_reason": "tool_calls"}
    \\  ]
    \\}
;

const responses_turn_body =
    \\{
    \\  "output": [
    \\    {"type": "reasoning", "id": "rs_1", "encrypted_content": "gAAAAABm-not-real"},
    \\    {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Checking."}]}
    \\  ],
    \\  "status": "completed"
    \\}
;




















































































































































































