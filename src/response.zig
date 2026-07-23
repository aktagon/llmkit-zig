//! Handwritten ChatCompletion response CODEC (ADR-065 Track B, Phase 2 slice I;
//! the inverse leg added by ADR-076).
//!
//! The INBOUND mirror of `request.zig`: given a provider's chat REPLY body
//! (already parsed into the `json.Value` waist), project it to the normalized
//! `{content, finish_reason, usage, err}` every SDK agrees on. Every field is
//! pulled through a GENERATED per-provider JSON path fact — there is no
//! switch-on-provider-name here, exactly as `rust/src/response.rs` mirrors: the
//! content path (`response.zig`), the usage input/output paths (`response.zig`),
//! the cache write/read paths (`caching.zig`), and the reasoning/finish/error
//! paths (the `ProviderSpec` in `providers.zig`) are all data. An empty path
//! means "this provider does not report that dimension" and the field defaults
//! to 0 / "" / null — the honest zero, never a fabricated value.
//!
//! Cost follows ADR-027: value at the provider's `usageCostPath`, multiplied by
//! its `usageCostScale` (xAI reports ticks; scale 1e-10 → USD). Providers that
//! do not report cost carry an empty path → cost 0.0.
//!
//! Strings are duped into the caller's arena, so a `Response` outlives the
//! parsed body it was read from.
//!
//! ADR-076 adds the inverse, `encodeResponse`, over the SAME path facts — the
//! reader with `json.getPath` replaced by `json.setWirePath`. The pair is
//! keyless, IO-free and pure, and `decodeResponse` is the single spelling of the
//! reader (the former `parseChatResponse` is gone, not kept beside it).

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const response_paths = @import("providers/generated/response.zig");
const caching = @import("providers/generated/caching.zig");

const ProviderName = providers.ProviderName;

/// Token accounting, one field per `TokenDimension`. The carrier field on
/// `Response` is named `usage` (load-bearing for the cross-SDK naming lint).
pub const Usage = struct {
    input: i64 = 0,
    output: i64 = 0,
    cache_read: i64 = 0,
    cache_write: i64 = 0,
    reasoning: i64 = 0,
    cost: f64 = 0,
};

/// A provider error envelope, when the reply carries one at the declared
/// `error_message_path`. Null on a successful reply.
pub const ApiError = struct {
    message: []const u8,
    type: []const u8 = "",
};

/// The normalized chat reply. `err` is non-null only when the body carries a
/// message at the provider's `error_message_path` (a successful reply leaves it
/// null). `usage` MUST keep this name — the naming lint keys on it.
pub const Response = struct {
    content: []const u8,
    finish_reason: []const u8,
    finish_message: []const u8 = "",
    err: ?ApiError = null,
    usage: Usage,
};

/// Read a string at a dotted path; empty path or a non-string value yields "".
fn stringAt(raw: json.Value, path: []const u8) []const u8 {
    if (path.len == 0) return "";
    const v = json.getPath(raw, path) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Read an integer at a dotted path; empty path or a missing/non-numeric value
/// yields 0 (the honest zero for an unreported token dimension).
fn intAt(raw: json.Value, path: []const u8) i64 {
    if (path.len == 0) return 0;
    const v = json.getPath(raw, path) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

/// Read a float at a dotted path; empty path or a missing/non-numeric value
/// yields 0.
fn floatAt(raw: json.Value, path: []const u8) f64 {
    if (path.len == 0) return 0;
    const v = json.getPath(raw, path) orelse return 0;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

fn detectError(arena: std.mem.Allocator, raw: json.Value, ps: providers.ProviderSpec) !?ApiError {
    if (ps.error_message_path.len == 0) return null;
    const message = stringAt(raw, ps.error_message_path);
    if (message.len == 0) return null;
    return ApiError{
        .message = try arena.dupe(u8, message),
        .type = try arena.dupe(u8, stringAt(raw, ps.error_type_path)),
    };
}

/// The error set `encodeResponse` adds to the allocator's. Zig error sets carry
/// no payload, so — unlike the other six SDKs, whose `ValidationError{Field,
/// Message}` names the offending field — this reports the KIND and not the
/// field (ADR-076 §3, the one honest asymmetry). Narrow by construction, the
/// `request.zig` `BuildError = error{UnsupportedWireShape}` precedent.
pub const EncodeError = error{FieldNotInvertible} || std.mem.Allocator.Error;

/// Project a parsed provider chat reply into the normalized `Response`. All
/// field placement is driven by the generated per-provider path facts; nothing
/// here dispatches on the provider name. Mirrors `rust/src/response.rs`.
///
/// `chat_wire_shape` is the EFFECTIVE wire shape for this request (after
/// `.protocol(...)` resolution, ADR-055): only `ChatResponsesOpenAI` diverges
/// (the `output[]` envelope); every other value uses the provider's declared
/// response paths. It is REQUIRED, not derived — one provider can serve two
/// chat protocols, and inferring it silently mis-parses (ADR-076 SYM-003).
///
/// Keyless, IO-free and pure (SYM-002): no `Client`, no credential, no network,
/// no clock — the subject is the generated `ProviderName`. This is the same
/// function the chat send path calls (SYM-004).
///
/// The body is the parsed `json.Value` waist rather than bytes, matching
/// `request.buildChatBody`'s Value-typed result on the outbound leg: Zig's pure
/// wire seam is Value-typed at both ends and the send seam does the
/// stringify/parse (ADR-069 ZIG-002). `json.parse` / `json.stringify` are public
/// for a caller holding bytes.
pub fn decodeResponse(
    arena: std.mem.Allocator,
    provider: ProviderName,
    chat_wire_shape: []const u8,
    raw: json.Value,
) !Response {
    if (std.mem.eql(u8, chat_wire_shape, "ChatResponsesOpenAI")) {
        return parseResponsesEnvelope(arena, raw);
    }

    const ps = providers.spec(provider);
    const usage_paths = response_paths.usagePaths(provider);
    const cache = caching.cacheUsagePaths(provider);

    return .{
        .content = try arena.dupe(u8, stringAt(raw, response_paths.responseTextPath(provider))),
        .finish_reason = try arena.dupe(u8, stringAt(raw, ps.finish_reason_path)),
        .finish_message = try arena.dupe(u8, stringAt(raw, ps.finish_message_path)),
        .err = try detectError(arena, raw, ps),
        .usage = .{
            .input = intAt(raw, usage_paths.input),
            .output = intAt(raw, usage_paths.output),
            .cache_write = intAt(raw, cache.write),
            .cache_read = intAt(raw, cache.read),
            .reasoning = intAt(raw, ps.reasoning_tokens_path),
            .cost = floatAt(raw, response_paths.usageCostPath(provider)) *
                response_paths.usageCostScale(provider),
        },
    };
}

/// `decodeResponse`'s inverse: render a canonical `Response` back onto the wire
/// for `provider` + `chat_wire_shape`. Every write location comes from the same
/// generated path accessors `decodeResponse` reads — there is no second table,
/// no switch on the provider name and no path literal here (ADR-076 SYM-005).
///
/// Keyless, IO-free and pure, like its mirror. The result is NOT byte-identical
/// to the body a provider would send: a provider body carries fields the
/// canonical `Response` does not model (ADR-014's raw exists for exactly that).
/// The contract is the canonical fixed point,
/// `decode(encode(decode(b))) == decode(b)` (SYM-006).
///
/// The returned Value and every string reachable from it are backed by `arena`,
/// so it outlives the call for as long as the arena does.
pub fn encodeResponse(
    arena: std.mem.Allocator,
    provider: ProviderName,
    chat_wire_shape: []const u8,
    resp: Response,
) EncodeError!json.Value {
    try guardOneWayFields(provider, resp);
    if (std.mem.eql(u8, chat_wire_shape, "ChatResponsesOpenAI")) {
        return encodeResponsesEnvelope(arena, resp);
    }

    const ps = providers.spec(provider);
    const usage_paths = response_paths.usagePaths(provider);
    const cache = caching.cacheUsagePaths(provider);

    var raw = json.object();
    try json.setWirePath(arena, &raw, response_paths.responseTextPath(provider), .{ .string = resp.content });
    try json.setWirePath(arena, &raw, usage_paths.input, .{ .integer = resp.usage.input });
    try json.setWirePath(arena, &raw, usage_paths.output, .{ .integer = resp.usage.output });
    try json.setWirePath(arena, &raw, cache.write, .{ .integer = resp.usage.cache_write });
    try json.setWirePath(arena, &raw, cache.read, .{ .integer = resp.usage.cache_read });
    const scale = response_paths.usageCostScale(provider);
    if (scale != 0) {
        const cost = resp.usage.cost / scale;
        try json.setWirePath(arena, &raw, response_paths.usageCostPath(provider), .{ .float = cost });
    }
    try json.setWirePath(arena, &raw, ps.reasoning_tokens_path, .{ .integer = resp.usage.reasoning });
    try json.setWirePath(arena, &raw, ps.finish_reason_path, .{ .string = resp.finish_reason });
    try json.setWirePath(arena, &raw, ps.finish_message_path, .{ .string = resp.finish_message });
    // The error envelope is part of the canonical projection Zig's `Response`
    // carries (`err`), so its two paths are written back like any other — the
    // mirror of `detectError`.
    if (resp.err) |e| {
        try json.setWirePath(arena, &raw, ps.error_message_path, .{ .string = e.message });
        try json.setWirePath(arena, &raw, ps.error_type_path, .{ .string = e.type });
    }
    return raw;
}

/// Refuses to encode a canonical field whose mapping is `OneWay` for this
/// provider — the result set of CQ-WMAP-011 (ADR-076 SYM-007). Only one member
/// is in Phase 2's scope; the other, `exceptGoogleToolCallID`, covers tool
/// calls, which are out (SYM-008).
///
/// An empty value is not an error: there is nothing to write, so the common
/// path stays usable and only the lying path fails.
fn guardOneWayFields(provider: ProviderName, resp: Response) EncodeError!void {
    if (provider == .vertex and resp.finish_reason.len > 0) {
        // exceptVertexFinishReason, canonical path: response.finish_reason.
        // The comment carries what the error cannot: a Zig error set has no
        // payload, so `field` and `message` — which the other six SDKs pass to
        // ValidationError — live here instead, verbatim from the R-Box's
        // canonicalPath and invertibilityNote. This is also the anchor
        //
        // from; without it the rule would be vacuous for Zig.
        //
        // invertibilityNote: Vertex carries no finish-reason field. Its path
        // reads predictions[0].raiFilteredReason — a safety-filter explanation
        // surfaced AS the finish reason. Extraction is a deliberate fusion, so
        // the reverse leg cannot decide whether a given canonical finish_reason
        // originated as a safety verdict, and writing an ordinary stop signal
        // into that field would fabricate one.
        return error.FieldNotInvertible;
    }
}

/// Extract text + usage from OpenAI's Responses reply (ADR-055). Unlike Chat
/// Completions (`choices[].message.content`), the reply is an `output[]` array
/// whose message item carries `content[]` blocks of type "output_text"; usage is
/// input_tokens/output_tokens with cached + reasoning sub-details. Hand-coded
/// per wire shape, symmetric with the `buildResponsesBody` request arm (ADR-028:
/// behavior held by tests, not by declared response paths).
fn parseResponsesEnvelope(arena: std.mem.Allocator, raw: json.Value) !Response {
    return .{
        .content = try arena.dupe(u8, extractResponsesText(raw)),
        .finish_reason = try arena.dupe(u8, stringAt(raw, "status")),
        .usage = .{
            .input = intAt(raw, "usage.input_tokens"),
            .output = intAt(raw, "usage.output_tokens"),
            .cache_read = intAt(raw, "usage.input_tokens_details.cached_tokens"),
            .reasoning = intAt(raw, "usage.output_tokens_details.reasoning_tokens"),
        },
    };
}

/// Walk the Responses `output[]` array for the first message item and return its
/// first `output_text` block. Iterating (rather than a fixed
/// `output[0].content[0]` path) tolerates a leading reasoning item.
fn extractResponsesText(raw: json.Value) []const u8 {
    const output = json.getPath(raw, "output") orelse return "";
    if (std.meta.activeTag(output) != .array) return "";
    for (output.array.items) |item| {
        if (!isTagged(item, "message")) continue;
        const content = json.getPath(item, "content") orelse continue;
        if (std.meta.activeTag(content) != .array) continue;
        for (content.array.items) |block| {
            if (!isTagged(block, "output_text")) continue;
            const text = json.getPath(block, "text") orelse continue;
            if (std.meta.activeTag(text) == .string) return text.string;
        }
    }
    return "";
}

/// Whether `value` is an object whose "type" discriminant equals `want`.
fn isTagged(value: json.Value, want: []const u8) bool {
    const tag = json.getPath(value, "type") orelse return false;
    return std.meta.activeTag(tag) == .string and std.mem.eql(u8, tag.string, want);
}

/// Mirror of `parseResponsesEnvelope`: rebuild OpenAI's Responses reply — an
/// `output[]` array whose message item carries `content[]` blocks of type
/// "output_text". Hand-coded per wire shape on both legs, symmetric with the
/// reader, for the same reason the reader is.
fn encodeResponsesEnvelope(arena: std.mem.Allocator, resp: Response) EncodeError!json.Value {
    var raw = json.object();
    if (resp.content.len > 0) {
        var block = json.object();
        try json.set(arena, &block, "type", .{ .string = "output_text" });
        try json.set(arena, &block, "text", .{ .string = resp.content });
        var content = json.array(arena);
        try content.array.append(block);

        var item = json.object();
        try json.set(arena, &item, "type", .{ .string = "message" });
        try json.set(arena, &item, "content", content);
        var output = json.array(arena);
        try output.array.append(item);
        try json.set(arena, &raw, "output", output);
    }
    try json.setWirePath(arena, &raw, "usage.input_tokens", .{ .integer = resp.usage.input });
    try json.setWirePath(arena, &raw, "usage.output_tokens", .{ .integer = resp.usage.output });
    try json.setWirePath(arena, &raw, "usage.input_tokens_details.cached_tokens", .{ .integer = resp.usage.cache_read });
    try json.setWirePath(arena, &raw, "usage.output_tokens_details.reasoning_tokens", .{ .integer = resp.usage.reasoning });
    try json.setWirePath(arena, &raw, "status", .{ .string = resp.finish_reason });
    return raw;
}



















































