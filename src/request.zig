//! Request-body construction — the pure part of the pipeline the wire goldens
//! assert. It takes a typed config and produces a dynamic JSON `Value`; it does
//! no I/O and needs no `Io` (ADR-069: the `Io` parameter is a runtime-shape
//! concern, not a wire-shape one). Phase 0 covers the `ChatOpenAI` wire shape
//! (system-in-messages, flat options) — the shape the workersai golden
//! exercises. Later phases add the Anthropic / Google / Bedrock shapes and the
//! generated option table.

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers.zig");

pub const ChatConfig = struct {
    provider: providers.ProviderName,
    model: ?[]const u8 = null,
    system: ?[]const u8 = null,
    prompt: []const u8,
    max_tokens: ?i64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
};

pub const BuildError = error{UnsupportedWireShape} || std.mem.Allocator.Error;

/// Build the ChatCompletion request body as a dynamic JSON Value backed by
/// `arena`. Phase 0: the `ChatOpenAI` shape only.
pub fn buildChatBody(arena: std.mem.Allocator, cfg: ChatConfig) BuildError!json.Value {
    const spec = providers.spec(cfg.provider);
    if (!std.mem.eql(u8, spec.chat_wire_shape, "ChatOpenAI")) {
        return error.UnsupportedWireShape;
    }

    var body = json.object();

    if (cfg.model) |m| try json.set(arena, &body, "model", .{ .string = m });

    var messages = json.array(arena);
    // System-in-messages placement: a leading {role:"system", content:...}.
    if (cfg.system) |sys| {
        var sm = json.object();
        try json.set(arena, &sm, "role", .{ .string = "system" });
        try json.set(arena, &sm, "content", .{ .string = sys });
        try messages.array.append(sm);
    }
    // The single user text message. The OpenAI shape sends a bare string for a
    // lone text part (media parts switch it to a parts array in a later phase).
    var um = json.object();
    try json.set(arena, &um, "role", .{ .string = "user" });
    try json.set(arena, &um, "content", .{ .string = cfg.prompt });
    try messages.array.append(um);
    try json.set(arena, &body, "messages", messages);

    // Flat options (the OpenAI wire keys; phase 1 reads these from the
    // generated per-provider option table).
    if (cfg.max_tokens) |n| try json.set(arena, &body, "max_tokens", .{ .integer = n });
    if (cfg.temperature) |t| try json.set(arena, &body, "temperature", .{ .float = t });
    if (cfg.top_p) |p| try json.set(arena, &body, "top_p", .{ .float = p });

    return body;
}
