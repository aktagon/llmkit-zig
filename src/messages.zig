//! Multi-turn message history: the internal message sum, the per-shape history
//! transforms, ADR-085 turn replay, and tool-call extraction.
//!
//! The public `Message` (generated `structs.zig`) is a flat product that can
//! encode an illegal combination — content AND tool calls AND a tool result on
//! one turn. `Msg` cannot: it is exactly one of text, calls, result, or a
//! replayed provider turn. `toInternal` is the single place a public history is
//! checked and converted, so the transforms below switch exhaustively and the
//! compiler, not a runtime guard, rejects an unhandled variant. Mirrors Rust
//! `transforms.rs` `Msg` / `to_internal` and Swift `Transforms.Msg`.
//!
//! Every transform dispatches on the EFFECTIVE chat wire shape and the
//! generated tool-call config (`args_format`, `result_role`), never on a
//! provider name.
//!
//! Ownership: everything built here — the `Msg` slice, the heap-allocated
//! `fallback` behind a `turn`, the JSON values — lives in the `arena` the
//! request path already threads through `buildChatBody`. Zig has no ambient
//! allocator, so the arena is the owner: it outlives the body build and is
//! freed by the caller in one shot with the request.

const std = @import("std");
const json = @import("json.zig");
const structs = @import("providers/generated/structs.zig");
const providers = @import("providers/generated/providers.zig");
const request_defs = @import("providers/generated/request_defs.zig");
const provider_turn = @import("provider_turn.zig");

pub const Message = structs.Message;
pub const ToolCall = structs.ToolCall;
pub const ToolResult = structs.ToolResult;

pub const Error = error{InvalidMessage} || std.mem.Allocator.Error;

/// The internal message sum: exactly one of a text turn, an assistant turn that
/// called tools, a tool turn carrying one result, or an assistant turn the
/// provider serialized itself (ADR-085). A `turn` carries the projection it
/// replaces, so `resolveTurns` can fall back to reconstruction when the payload
/// cannot be replayed under the request's wire shape.
pub const Msg = union(enum) {
    text: Text,
    calls: []const ToolCall,
    result: ToolResult,
    turn: Turn,

    pub const Text = struct { role: []const u8, text: []const u8 };

    /// `fallback` points into the request arena (see the module note).
    pub const Turn = struct { shape: []const u8, wire: []const u8, fallback: *const Msg };
};

/// Convert a public history into the internal sum. A message carrying more than
/// one of {content, tool calls, tool result} is rejected with
/// `error.InvalidMessage` rather than mis-serialized downstream (Rust PIPE-008).
/// `provider_turn` is not a fourth carrier: it is the same turn in the
/// provider's own bytes, so it wraps the projection instead of competing with it.
pub fn toInternal(arena: std.mem.Allocator, messages: []const Message) Error![]Msg {
    const out = try arena.alloc(Msg, messages.len);
    for (messages, out) |m, *slot| {
        const carriers = @as(u8, @intFromBool(m.tool_result != null)) +
            @intFromBool(m.tool_calls.len > 0) +
            @intFromBool(m.content.len > 0);
        if (carriers > 1) return error.InvalidMessage;

        const projected: Msg = if (m.tool_result) |r|
            .{ .result = r }
        else if (m.tool_calls.len > 0)
            .{ .calls = m.tool_calls }
        else
            .{ .text = .{ .role = m.role, .text = m.content } };

        slot.* = if (m.provider_turn) |t| blk: {
            const fallback = try arena.create(Msg);
            fallback.* = projected;
            break :blk .{ .turn = .{ .shape = t.wire_shape, .wire = t.wire, .fallback = fallback } };
        } else projected;
    }
    return out;
}

/// Unwrap every `turn` that cannot be replayed under `shape` to its projection.
/// Two conditions keep a payload: it was captured under this same shape, AND
/// the shape declares a turn position. A payload claiming an unanchored shape
/// (Bedrock) can only come from caller-supplied or loaded data, and no
/// transform has a place to splice it (ADR-085 RSN-006). Dropping is the safe
/// direction: every probed provider accepts a request without the payload, and
/// a payload replayed into the wrong shape is a 400.
pub fn resolveTurns(msgs: []Msg, spec: providers.ProviderSpec, shape: []const u8) void {
    for (msgs) |*m| switch (m.*) {
        .turn => |t| {
            if (!std.mem.eql(u8, t.shape, shape) or provider_turn.assistantTurnPath(spec, t.shape).len == 0)
                m.* = t.fallback.*;
        },
        else => {},
    };
}

/// Map a canonical role through the provider's generated role mappings (Google
/// `assistant` -> `model`, ...). An unmapped role passes through unchanged.
fn mapRole(spec: providers.ProviderSpec, role: []const u8) []const u8 {
    for (spec.role_mappings) |rm| {
        if (std.mem.eql(u8, rm.from, role)) return rm.to;
    }
    return role;
}

fn argsFormatIsMap(provider: providers.ProviderName) bool {
    const tc = request_defs.toolCallConfig(provider) orelse return false;
    return std.mem.eql(u8, tc.args_format, "map");
}

/// A tool call's input as a JSON value: `{}` when absent, so providers that
/// reject a literal null input get an empty object.
fn inputValue(call: ToolCall) json.Value {
    return call.input orelse json.object();
}

fn inputJsonString(arena: std.mem.Allocator, call: ToolCall) ![]const u8 {
    return json.stringify(arena, inputValue(call));
}

// === Flat envelopes: ChatOpenAI `messages`, ChatResponsesOpenAI `input`,
// ChatAnthropic `messages`, ChatBedrock `messages` ===

/// Append every history turn to a flat message array (the caller has already
/// placed any system message). A replayable `turn` is spliced; everything else
/// is reconstructed from its projection. Mirrors Rust `build_flat_message_array`.
pub fn appendFlatHistory(
    arena: std.mem.Allocator,
    out: *json.Value,
    msgs: []const Msg,
    provider: providers.ProviderName,
    shape: []const u8,
) !void {
    for (msgs) |m| {
        if (m == .turn and try appendReplayedTurn(arena, out, m.turn, provider, shape)) continue;
        try appendProjected(arena, out, m, provider, shape);
    }
}

/// Splice a captured assistant turn into a flat array, in the container its
/// wire family expects. Returns false when the payload cannot be placed, so the
/// caller reconstructs instead. The three families disagree on what
/// `assistant_turn_path` points at:
///
///   - `ChatOpenAI`          `choices[0].message` -> one message object
///   - `ChatAnthropic`       `content`            -> the block ARRAY; the role
///     wrapper is llmkit's, the blocks are the provider's
///   - `ChatResponsesOpenAI` `output`             -> an item LIST that spreads
///     across N `input[]` entries (ADR-085 OQ-1)
///
/// Bedrock never replays: it declares no turn position (ADR-085 OQ-5).
fn appendReplayedTurn(
    arena: std.mem.Allocator,
    out: *json.Value,
    turn: Msg.Turn,
    provider: providers.ProviderName,
    shape: []const u8,
) !bool {
    if (std.mem.eql(u8, shape, "ChatBedrock")) return false;
    const payload = std.json.parseFromSliceLeaky(json.Value, arena, turn.wire, .{}) catch return false;
    if (std.mem.eql(u8, turn.shape, "ChatAnthropic")) {
        var wrapped = json.object();
        try json.set(arena, &wrapped, "role", .{ .string = mapRole(providers.spec(provider), "assistant") });
        try json.set(arena, &wrapped, "content", payload);
        try out.array.append(wrapped);
        return true;
    }
    if (std.mem.eql(u8, turn.shape, "ChatResponsesOpenAI")) {
        if (payload != .array) return false;
        try out.array.appendSlice(payload.array.items);
        return true;
    }
    try out.array.append(payload);
    return true;
}

/// Reconstruct one canonical message as flat-envelope entries. A list, not one
/// entry, because on `ChatResponsesOpenAI` one assistant turn with N tool calls
/// is N peer `input[]` items (BUG-050).
fn appendProjected(
    arena: std.mem.Allocator,
    out: *json.Value,
    m: Msg,
    provider: providers.ProviderName,
    shape: []const u8,
) !void {
    const spec = providers.spec(provider);
    switch (m) {
        .result => |r| try out.array.append(try toolResultEntry(arena, r, provider, shape)),
        .calls => |calls| try appendToolCallEntries(arena, out, calls, provider, shape),
        .text => |t| {
            var entry = json.object();
            try json.set(arena, &entry, "role", .{ .string = mapRole(spec, t.role) });
            if (std.mem.eql(u8, shape, "ChatBedrock")) {
                try json.set(arena, &entry, "content", try textBlocks(arena, "text", t.text));
            } else {
                try json.set(arena, &entry, "content", .{ .string = t.text });
            }
            try out.array.append(entry);
        },
        // `resolveTurns` already unwrapped anything unplaceable; this arm keeps
        // a payload the splice still refused from failing the request build.
        .turn => |t| try appendProjected(arena, out, t.fallback.*, provider, shape),
    }
}

/// `[{<key>: <text>}]` — a one-element array of text blocks.
fn textBlocks(arena: std.mem.Allocator, key: []const u8, text: []const u8) !json.Value {
    var arr = json.array(arena);
    var part = json.object();
    try json.set(arena, &part, key, .{ .string = text });
    try arr.array.append(part);
    return arr;
}

/// The assistant tool-call turn, per wire shape. Mirrors Rust `tool_call_message`.
fn appendToolCallEntries(
    arena: std.mem.Allocator,
    out: *json.Value,
    calls: []const ToolCall,
    provider: providers.ProviderName,
    shape: []const u8,
) !void {
    const role: json.Value = .{ .string = mapRole(providers.spec(provider), "assistant") };

    if (std.mem.eql(u8, shape, "ChatResponsesOpenAI")) {
        // No assistant envelope: each call is its own top-level item,
        // correlated to its output by call_id. Live-anchored 2026-08-13 (Rust).
        for (calls) |call| {
            var item = json.object();
            try json.set(arena, &item, "type", .{ .string = "function_call" });
            try json.set(arena, &item, "call_id", .{ .string = call.id });
            try json.set(arena, &item, "name", .{ .string = call.name });
            try json.set(arena, &item, "arguments", .{ .string = try inputJsonString(arena, call) });
            try out.array.append(item);
        }
        return;
    }

    var blocks = json.array(arena);
    var entry = json.object();
    try json.set(arena, &entry, "role", role);
    if (std.mem.eql(u8, shape, "ChatBedrock")) {
        for (calls) |call| {
            var tool_use = json.object();
            try json.set(arena, &tool_use, "toolUseId", .{ .string = call.id });
            try json.set(arena, &tool_use, "name", .{ .string = call.name });
            try json.set(arena, &tool_use, "input", inputValue(call));
            var block = json.object();
            try json.set(arena, &block, "toolUse", tool_use);
            try blocks.array.append(block);
        }
        try json.set(arena, &entry, "content", blocks);
    } else if (argsFormatIsMap(provider)) {
        for (calls) |call| {
            var block = json.object();
            try json.set(arena, &block, "type", .{ .string = "tool_use" });
            try json.set(arena, &block, "id", .{ .string = call.id });
            try json.set(arena, &block, "name", .{ .string = call.name });
            try json.set(arena, &block, "input", inputValue(call));
            try blocks.array.append(block);
        }
        try json.set(arena, &entry, "content", blocks);
    } else {
        for (calls) |call| {
            var function = json.object();
            try json.set(arena, &function, "name", .{ .string = call.name });
            try json.set(arena, &function, "arguments", .{ .string = try inputJsonString(arena, call) });
            var block = json.object();
            try json.set(arena, &block, "id", .{ .string = call.id });
            try json.set(arena, &block, "type", .{ .string = "function" });
            try json.set(arena, &block, "function", function);
            try blocks.array.append(block);
        }
        try json.set(arena, &entry, "tool_calls", blocks);
    }
    try out.array.append(entry);
}

/// The tool-result turn, per wire shape. Mirrors Rust `tool_result_message`.
fn toolResultEntry(
    arena: std.mem.Allocator,
    result: ToolResult,
    provider: providers.ProviderName,
    shape: []const u8,
) !json.Value {
    var entry = json.object();
    if (std.mem.eql(u8, shape, "ChatResponsesOpenAI")) {
        // A top-level typed item: Responses rejects the Chat Completions
        // `role: tool` message (live-anchored 2026-08-13, Rust).
        try json.set(arena, &entry, "type", .{ .string = "function_call_output" });
        try json.set(arena, &entry, "call_id", .{ .string = result.tool_use_id });
        try json.set(arena, &entry, "output", .{ .string = result.content });
        return entry;
    }
    if (std.mem.eql(u8, shape, "ChatBedrock")) {
        var tool_result = json.object();
        try json.set(arena, &tool_result, "toolUseId", .{ .string = result.tool_use_id });
        try json.set(arena, &tool_result, "content", try textBlocks(arena, "text", result.content));
        var block = json.object();
        try json.set(arena, &block, "toolResult", tool_result);
        var content = json.array(arena);
        try content.array.append(block);
        try json.set(arena, &entry, "role", .{ .string = "user" });
        try json.set(arena, &entry, "content", content);
        return entry;
    }
    const tc = request_defs.toolCallConfig(provider);
    const user_role_map = if (tc) |c| std.mem.eql(u8, c.result_role, "user") and std.mem.eql(u8, c.args_format, "map") else false;
    if (user_role_map) {
        var block = json.object();
        try json.set(arena, &block, "type", .{ .string = "tool_result" });
        try json.set(arena, &block, "tool_use_id", .{ .string = result.tool_use_id });
        try json.set(arena, &block, "content", .{ .string = result.content });
        var content = json.array(arena);
        try content.array.append(block);
        try json.set(arena, &entry, "role", .{ .string = "user" });
        try json.set(arena, &entry, "content", content);
        return entry;
    }
    try json.set(arena, &entry, "role", .{ .string = "tool" });
    try json.set(arena, &entry, "content", .{ .string = result.content });
    try json.set(arena, &entry, "tool_call_id", .{ .string = result.tool_use_id });
    return entry;
}

// === ChatGoogle `contents` ===

/// Build the Google `contents` array from a history. Google identifies a tool
/// result by the function NAME, but `ToolResult` carries only `tool_use_id`, so
/// the id -> name map is recovered from the call turns, which precede their
/// results in a valid history. A replayed Google turn is `candidates[0].content`
/// verbatim — the same `{role, parts}` object `contents` takes — and still feeds
/// the map from its projection, because a later result is matched against calls
/// made on that turn. Mirrors Rust `transform_google_parts`.
pub fn googleContents(arena: std.mem.Allocator, msgs: []const Msg, provider: providers.ProviderName) !json.Value {
    const spec = providers.spec(provider);
    var contents = json.array(arena);
    var id_to_name: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (msgs) |m| {
        if (m == .turn and std.mem.eql(u8, m.turn.shape, "ChatGoogle")) {
            if (m.turn.fallback.* == .calls) {
                for (m.turn.fallback.calls) |call| try id_to_name.put(arena, call.id, call.name);
            }
            if (std.json.parseFromSliceLeaky(json.Value, arena, m.turn.wire, .{})) |payload| {
                try contents.array.append(payload);
                continue;
            } else |_| {}
        }
        try contents.array.append(try googleProjected(arena, m, spec, &id_to_name));
    }
    return contents;
}

fn googleProjected(
    arena: std.mem.Allocator,
    m: Msg,
    spec: providers.ProviderSpec,
    id_to_name: *std.StringHashMapUnmanaged([]const u8),
) !json.Value {
    var entry = json.object();
    var parts = json.array(arena);
    switch (m) {
        .result => |r| {
            var response = json.object();
            try json.set(arena, &response, "result", .{ .string = r.content });
            var function_response = json.object();
            try json.set(arena, &function_response, "name", .{ .string = id_to_name.get(r.tool_use_id) orelse r.tool_use_id });
            try json.set(arena, &function_response, "response", response);
            var part = json.object();
            try json.set(arena, &part, "functionResponse", function_response);
            try parts.array.append(part);
            try json.set(arena, &entry, "role", .{ .string = "user" });
        },
        .calls => |calls| {
            for (calls) |call| {
                try id_to_name.put(arena, call.id, call.name);
                var function_call = json.object();
                try json.set(arena, &function_call, "name", .{ .string = call.name });
                try json.set(arena, &function_call, "args", inputValue(call));
                var part = json.object();
                try json.set(arena, &part, "functionCall", function_call);
                try parts.array.append(part);
            }
            try json.set(arena, &entry, "role", .{ .string = mapRole(spec, "assistant") });
        },
        .text => |t| {
            var part = json.object();
            try json.set(arena, &part, "text", .{ .string = t.text });
            try parts.array.append(part);
            try json.set(arena, &entry, "role", .{ .string = mapRole(spec, t.role) });
        },
        .turn => |t| return googleProjected(arena, t.fallback.*, spec, id_to_name),
    }
    try json.set(arena, &entry, "parts", parts);
    return entry;
}

// === Tool-call extraction (the agent loop's read side) ===

/// Read the tool calls a reply asked for, per wire shape. Empty when the reply
/// called no tool. Each call's `input` is an object (`{}` when absent).
/// Mirrors Rust `extract_tool_calls`.
pub fn extractToolCalls(
    arena: std.mem.Allocator,
    raw: json.Value,
    provider: providers.ProviderName,
    shape: []const u8,
) ![]ToolCall {
    var out: std.ArrayList(ToolCall) = .empty;
    if (std.mem.eql(u8, shape, "ChatBedrock")) {
        const blocks = json.getPath(raw, "output.message.content") orelse return &.{};
        if (blocks != .array) return &.{};
        for (blocks.array.items) |block| {
            const tool_use = json.getPath(block, "toolUse") orelse continue;
            try out.append(arena, .{
                .id = stringOf(json.getPath(tool_use, "toolUseId")),
                .name = stringOf(json.getPath(tool_use, "name")),
                .input = objectOrEmpty(json.getPath(tool_use, "input")),
            });
        }
    } else if (std.mem.eql(u8, shape, "ChatGoogle")) {
        const parts = json.getPath(raw, "candidates[0].content.parts") orelse return &.{};
        if (parts != .array) return &.{};
        for (parts.array.items) |part| {
            const function_call = json.getPath(part, "functionCall") orelse continue;
            // Google issues no call id; the name stands in for it.
            const name = stringOf(json.getPath(function_call, "name"));
            try out.append(arena, .{ .id = name, .name = name, .input = objectOrEmpty(json.getPath(function_call, "args")) });
        }
    } else if (argsFormatIsMap(provider)) {
        for (try json.matchingBlocks(arena, raw, "content", "type", "tool_use")) |block| {
            try out.append(arena, .{
                .id = stringOf(json.getPath(block, "id")),
                .name = stringOf(json.getPath(block, "name")),
                .input = objectOrEmpty(json.getPath(block, "input")),
            });
        }
    } else {
        const calls = json.getPath(raw, "choices[0].message.tool_calls") orelse return &.{};
        if (calls != .array) return &.{};
        for (calls.array.items) |call| {
            const function = json.getPath(call, "function") orelse continue;
            const name = json.getPath(function, "name") orelse continue;
            if (name != .string) continue;
            const arguments = json.getPath(function, "arguments");
            // `json_string` providers send the arguments as a JSON TEXT; the
            // rest send an object.
            const input: json.Value = if (arguments) |a| switch (a) {
                .string => |s| objectOrEmpty(std.json.parseFromSliceLeaky(json.Value, arena, s, .{}) catch null),
                else => objectOrEmpty(a),
            } else json.object();
            try out.append(arena, .{ .id = stringOf(json.getPath(call, "id")), .name = name.string, .input = input });
        }
    }
    return out.toOwnedSlice(arena);
}

fn stringOf(v: ?json.Value) []const u8 {
    const value = v orelse return "";
    return if (value == .string) value.string else "";
}

fn objectOrEmpty(v: ?json.Value) json.Value {
    const value = v orelse return json.object();
    return if (value == .object) value else json.object();
}

// === Tests ===

const testing = std.testing;

fn userMsg(text: []const u8) Message {
    return .{ .role = "user", .content = text, .tool_calls = &.{}, .tool_result = null, .provider_turn = null };
}






















































































































