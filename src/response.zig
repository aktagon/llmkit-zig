//! Handwritten ChatCompletion response CODEC (ADR-065 Track B, Phase 2 slice I;
//! the inverse leg added by ADR-076).
//!
//! The INBOUND mirror of `request.zig`: given a provider's chat REPLY body
//! (already parsed into the `json.Value` waist), project it to the normalized
//! `{text, finish_reason, usage}` every SDK agrees on, plus the error envelope
//! (`Decoded.err`). Every field is
//! pulled through a GENERATED per-provider JSON path fact — there is no
//! switch-on-provider-name here, exactly as `rust/src/response.rs` mirrors: the
//! content path (`response.zig`), the usage input/output paths (`response.zig`),
//! the cache write/read paths (`caching.zig`), and the reasoning/finish/error
//! paths (the `ProviderSpec` in `providers.zig`) are all data. An empty path
//! means "this provider does not report that dimension", and the field is then
//! NULL, not zero (ADR-081): a provider reporting `cached_tokens: 0` and a
//! provider that never mentions caching are different claims, and a zero cannot
//! carry both. This module used to call that zero "honest"; it was the one
//! value guaranteed to be indistinguishable from a real measurement.
//!
//! Cost follows ADR-027: value at the provider's `usageCostPath`, multiplied by
//! its `usageCostScale` (xAI reports ticks; scale 1e-10 → USD). Providers that
//! do not report cost carry an empty path → cost null. An unreported cost is
//! not a free request (AVAIL-007).
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
///
/// GENERATED from the `TokenDimension` instances and re-exported here so
/// the hand-written surface keeps one name for it. It used to be redeclared in
/// this file, which meant two structs named `Usage` in one package — and the
///
/// produced was dead while a hand-written copy did the work.
pub const Usage = @import("providers/generated/usage_gen.zig").Usage;

/// A provider error envelope, when the reply carries one at the declared
/// `error_message_path`. Null on a successful reply.
pub const ApiError = struct {
    message: []const u8,
    type: []const u8 = "",
};

/// The normalized chat reply. `usage` MUST keep this name — the naming lint
/// keys on it. `raw` is always null until the `.raw()` opt-in lands (BUG-073).
/// `provider_turn` is populated by the SEND seam, not by `decodeResponse`: the
/// codec is Value-typed (ADR-069 ZIG-002) and a parsed tree has no memory of the
/// source text, so the bytes are sliced where they still exist (ADR-085).
pub const Response = @import("providers/generated/structs.zig").Response;

/// What the codec reads from one reply body: the canonical `Response` plus the
/// provider error envelope. `err` is non-null only when the body carries a
/// message at the provider's `error_message_path` (a successful reply leaves it
/// null). The envelope lives here, not on `Response`, because the cross-SDK
/// `Response` has no error field.
pub const Decoded = struct {
    response: Response,
    err: ?ApiError,
};

/// Read the assistant's text out of a parsed provider body.
///
/// Two readers, selected by the WIRE SHAPE, never by provider name:
///
///   - block-array families declare a responseTextConfig and are read by
///     DISCRIMINATOR, because array position is not stable — Opus 5 and
///     Sonnet 5 think by default, so content[0] is a thinking block (BUG-053);
///   - scalar families declare none, and null SELECTS the fixed-path reader.
///
/// An empty result is a real answer, not a failure: every tool-use turn carries
/// no text block at all. finish_reason is what says why.
fn extractResponseText(
    arena: std.mem.Allocator,
    raw: json.Value,
    provider: providers.ProviderName,
    chat_wire_shape: []const u8,
) ![]const u8 {
    const cfg = response_paths.responseTextConfig(chat_wire_shape) orelse
        return stringAt(raw, response_paths.responseTextPath(provider));
    const blocks = try json.matchingBlocks(arena, raw, cfg.blocks_path, cfg.marker_path, cfg.marker_value);
    if (blocks.len == 0) return "";
    return stringAt(blocks[0], cfg.value_path);
}

/// `extractResponseText`'s inverse, driven by the SAME config so the two cannot
/// drift apart.
///
/// The marker is WRITTEN, not just tested. Emitting only the value path would
/// produce {"content":[{"text":"pong"}]} — a body with no type discriminator,
/// which the reader above then finds no matching block in. That is the ADR-076
/// fixed point breaking, and it is why textMarkerValue is documented as a
/// write instruction rather than a read predicate.
fn encodeResponseText(
    arena: std.mem.Allocator,
    raw: *json.Value,
    provider: providers.ProviderName,
    chat_wire_shape: []const u8,
    text: []const u8,
) !void {
    const cfg = response_paths.responseTextConfig(chat_wire_shape) orelse {
        try json.setWirePath(arena, raw, response_paths.responseTextPath(provider), .{ .string = text });
        return;
    };
    const block = try std.fmt.allocPrint(arena, "{s}[0]", .{cfg.blocks_path});
    if (cfg.marker_value.len > 0) {
        const marker = try std.fmt.allocPrint(arena, "{s}.{s}", .{ block, cfg.marker_path });
        try json.setWirePath(arena, raw, marker, .{ .string = cfg.marker_value });
    }
    const value = try std.fmt.allocPrint(arena, "{s}.{s}", .{ block, cfg.value_path });
    try json.setWirePath(arena, raw, value, .{ .string = text });
}

/// Read a string at a dotted path; empty path or a non-string value yields "".
fn stringAt(raw: json.Value, path: []const u8) []const u8 {
    if (path.len == 0) return "";
    const v = json.getPath(raw, path) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Read an integer at a dotted path, or null when the provider declares no path
/// for this field or the response did not carry it (ADR-081).
pub fn optInt(raw: json.Value, path: []const u8) ?i64 {
    if (path.len == 0) return null;
    const v = json.getPath(raw, path) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// `optInt` for the fractional provider-reported USD cost (ADR-027).
fn optFloat(raw: json.Value, path: []const u8) ?f64 {
    if (path.len == 0) return null;
    const v = json.getPath(raw, path) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// A parsed signal string as an optional canonical field, duped into the
/// caller's arena. An empty extraction means the provider declared no path or
/// sent no value, which is absence, not the empty string — and `arena.dupe` of
/// "" would coerce into the optional as a REPORTED empty string, the wrong side
/// of the very distinction ADR-081 draws, with no compiler complaint.
fn dupOptString(arena: std.mem.Allocator, value: []const u8) !?[]const u8 {
    return if (value.len == 0) null else try arena.dupe(u8, value);
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
/// Fill in an unspecified wire shape with the provider's DEFAULT chat protocol.
///
/// Callers that decode a body they know is Chat Completions — batch result
/// lines, chiefly — pass "" to mean "not the Responses envelope". Harmless
/// while the shape only chose between the Responses arm and the provider's
/// declared paths; NOT harmless once it also selects the TEXT READER, because
/// "" resolved to no config, which is the positional reader BUG-053 removed.
/// Batched Anthropic replies with a leading thinking block decoded to "" long
/// after the send path was fixed.
///
/// Resolving here keeps N=1. ADR-055 requires every provider's default protocol
/// to be a Chat Completions family, so this can never resolve INTO the
/// Responses arm.
fn resolveChatWireShape(provider: ProviderName, chat_wire_shape: []const u8) []const u8 {
    if (chat_wire_shape.len > 0) return chat_wire_shape;
    return providers.spec(provider).chat_wire_shape;
}

pub fn decodeResponse(
    arena: std.mem.Allocator,
    provider: ProviderName,
    chat_wire_shape_raw: []const u8,
    raw: json.Value,
) !Decoded {
    const chat_wire_shape = resolveChatWireShape(provider, chat_wire_shape_raw);
    if (std.mem.eql(u8, chat_wire_shape, "ChatResponsesOpenAI")) {
        return .{ .response = try parseResponsesEnvelope(arena, raw), .err = null };
    }

    const ps = providers.spec(provider);
    const usage_paths = response_paths.usagePaths(provider);
    const cache = caching.cacheUsagePaths(provider);

    return .{
        .err = try detectError(arena, raw, ps),
        .response = .{
            .text = try arena.dupe(u8, try extractResponseText(arena, raw, provider, chat_wire_shape)),
            .finish_reason = try dupOptString(arena, stringAt(raw, ps.finish_reason_path)),
            .finish_message = try dupOptString(arena, stringAt(raw, ps.finish_message_path)),
            .raw = null,
            .provider_turn = null,
            .usage = .{
                .input = optInt(raw, usage_paths.input),
                .output = optInt(raw, usage_paths.output),
                .cache_write = optInt(raw, cache.write),
                .cache_read = optInt(raw, cache.read),
                .reasoning = optInt(raw, ps.reasoning_tokens_path),
                // Scaling PRESERVES absence: an unreported cost stays unreported
                // rather than becoming `0.0 * scale` (AVAIL-007).
                .cost = if (optFloat(raw, response_paths.usageCostPath(provider))) |c|
                    c * response_paths.usageCostScale(provider)
                else
                    null,
            },
        },
    };
}

/// `decodeResponse`'s inverse: render a `Decoded` reply back onto the wire
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
    chat_wire_shape_raw: []const u8,
    decoded: Decoded,
) EncodeError!json.Value {
    const resp = decoded.response;
    const chat_wire_shape = resolveChatWireShape(provider, chat_wire_shape_raw);
    try guardOneWayFields(provider, resp);
    if (std.mem.eql(u8, chat_wire_shape, "ChatResponsesOpenAI")) {
        return encodeResponsesEnvelope(arena, resp);
    }

    const ps = providers.spec(provider);
    const usage_paths = response_paths.usagePaths(provider);
    const cache = caching.cacheUsagePaths(provider);

    var raw = json.object();
    try encodeResponseText(arena, &raw, provider, chat_wire_shape, resp.text);
    try json.setWirePath(arena, &raw, usage_paths.input, json.wireInt(resp.usage.input));
    try json.setWirePath(arena, &raw, usage_paths.output, json.wireInt(resp.usage.output));
    try json.setWirePath(arena, &raw, cache.write, json.wireInt(resp.usage.cache_write));
    try json.setWirePath(arena, &raw, cache.read, json.wireInt(resp.usage.cache_read));
    const scale = response_paths.usageCostScale(provider);
    if (scale != 0) {
        // An unreported cost has no wire location to fill.
        const cost = if (resp.usage.cost) |c| c / scale else null;
        try json.setWirePath(arena, &raw, response_paths.usageCostPath(provider), json.wireFloat(cost));
    }
    try json.setWirePath(arena, &raw, ps.reasoning_tokens_path, json.wireInt(resp.usage.reasoning));
    try json.setWirePath(arena, &raw, ps.finish_reason_path, json.wireString(resp.finish_reason));
    try json.setWirePath(arena, &raw, ps.finish_message_path, json.wireString(resp.finish_message));
    // The error envelope is part of what `decodeResponse` reads (`Decoded.err`),
    // so its two paths are written back like any other — the mirror of
    // `detectError`.
    if (decoded.err) |e| {
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
    // Non-empty, not merely present: the guard exists to refuse FABRICATION,
    // and neither an unreported field nor a reported empty one would write
    // anything (see `isEmptyWireValue`). Only a value that would reach the wire
    // lies.
    if (provider == .vertex and (resp.finish_reason orelse @as([]const u8, "")).len > 0) {
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
        .text = try arena.dupe(u8, extractResponsesText(raw)),
        .finish_reason = try dupOptString(arena, stringAt(raw, "status")),
        .finish_message = null,
        .raw = null,
        .provider_turn = null,
        // The Responses envelope carries no cache-write or cost field at all.
        // That is not a zero: it is the provider never making the claim.
        .usage = .{
            .input = optInt(raw, "usage.input_tokens"),
            .output = optInt(raw, "usage.output_tokens"),
            .cache_read = optInt(raw, "usage.input_tokens_details.cached_tokens"),
            .reasoning = optInt(raw, "usage.output_tokens_details.reasoning_tokens"),
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
    if (resp.text.len > 0) {
        var block = json.object();
        try json.set(arena, &block, "type", .{ .string = "output_text" });
        try json.set(arena, &block, "text", .{ .string = resp.text });
        var content = json.array(arena);
        try content.array.append(block);

        var item = json.object();
        try json.set(arena, &item, "type", .{ .string = "message" });
        try json.set(arena, &item, "content", content);
        var output = json.array(arena);
        try output.array.append(item);
        try json.set(arena, &raw, "output", output);
    }
    try json.setWirePath(arena, &raw, "usage.input_tokens", json.wireInt(resp.usage.input));
    try json.setWirePath(arena, &raw, "usage.output_tokens", json.wireInt(resp.usage.output));
    try json.setWirePath(arena, &raw, "usage.input_tokens_details.cached_tokens", json.wireInt(resp.usage.cache_read));
    try json.setWirePath(arena, &raw, "usage.output_tokens_details.reasoning_tokens", json.wireInt(resp.usage.reasoning));
    try json.setWirePath(arena, &raw, "status", json.wireString(resp.finish_reason));
    return raw;
}





































































