//! Request-body construction — the pure part of the pipeline the wire goldens
//! assert. It takes a typed config and produces a dynamic JSON `Value`; it does
//! no I/O and needs no `Io` (ADR-069: the `Io` parameter is a runtime-shape
//! concern, not a wire-shape one). Phase 2 (HANDOFF-041) covers the
//! `ChatOpenAI` wire shape (system-in-messages, flat options) driven fully
//! from the generated per-provider option table (`providers/generated/
//! options.zig`) — the same `supportedOptions` / `optionOverrides` /
//! `modelOptionOverrides` resolution every other SDK's `addOptions`/
//! `add_options` performs (ADR-024 per-model overrides, ADR-029 THK-003 root
//! extras). Slice B (HANDOFF-042) adds the `ChatAnthropic` wire shape
//! (top-level `system` string, same table-driven options); Google / Bedrock
//! land in later phases.

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const options = @import("providers/generated/options.zig");

pub const ChatConfig = struct {
    provider: providers.ProviderName,
    model: ?[]const u8 = null,
    system: ?[]const u8 = null,
    prompt: []const u8,
    max_tokens: ?i64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?i64 = null,
    frequency_penalty: ?f64 = null,
    presence_penalty: ?f64 = null,
    reasoning_effort: ?[]const u8 = null,
    seed: ?i64 = null,
    stop_sequences: ?[]const []const u8 = null,
    thinking_budget: ?i64 = null,
};

pub const BuildError = error{UnsupportedWireShape} || std.mem.Allocator.Error;

/// Build the ChatCompletion request body as a dynamic JSON Value backed by
/// `arena`, dispatching on the provider's `chat_wire_shape`. Phase 2 covers
/// `ChatOpenAI` (system-in-messages) and `ChatAnthropic` (top-level `system`
/// string); Google / Bedrock land in a later phase and still reject.
pub fn buildChatBody(arena: std.mem.Allocator, cfg: ChatConfig) BuildError!json.Value {
    const spec = providers.spec(cfg.provider);
    if (std.mem.eql(u8, spec.chat_wire_shape, "ChatOpenAI"))
        return buildOpenAIBody(arena, cfg);
    if (std.mem.eql(u8, spec.chat_wire_shape, "ChatAnthropic"))
        return buildAnthropicBody(arena, cfg);
    return error.UnsupportedWireShape;
}

/// The `ChatOpenAI` wire shape: the system prompt (when present) is a leading
/// `{role:"system", content:...}` message inside `messages`.
fn buildOpenAIBody(arena: std.mem.Allocator, cfg: ChatConfig) BuildError!json.Value {
    var body = json.object();
    if (cfg.model) |m| try json.set(arena, &body, "model", .{ .string = m });

    var messages = json.array(arena);
    if (cfg.system) |sys| {
        var sm = json.object();
        try json.set(arena, &sm, "role", .{ .string = "system" });
        try json.set(arena, &sm, "content", .{ .string = sys });
        try messages.array.append(sm);
    }
    try appendUserMessage(arena, &messages, cfg.prompt);
    try json.set(arena, &body, "messages", messages);

    try applyOptions(arena, &body, cfg);
    return body;
}

/// The `ChatAnthropic` wire shape: the system prompt (when present) is a
/// TOP-LEVEL `"system"` string field on the body — not a message — so
/// `messages` carries only the non-system turns. Options are identical to the
/// OpenAI shape (same table-driven `applyOptions`); Anthropic's wire keys
/// (`stop_sequences`, `top_k`, `thinking.*`, `output_config.effort` + root
/// `thinking:{type:adaptive}`) come from the generated option table.
fn buildAnthropicBody(arena: std.mem.Allocator, cfg: ChatConfig) BuildError!json.Value {
    var body = json.object();
    if (cfg.model) |m| try json.set(arena, &body, "model", .{ .string = m });
    if (cfg.system) |sys| try json.set(arena, &body, "system", .{ .string = sys });

    var messages = json.array(arena);
    try appendUserMessage(arena, &messages, cfg.prompt);
    try json.set(arena, &body, "messages", messages);

    try applyOptions(arena, &body, cfg);
    return body;
}

/// Appends the single user text message. Both shapes send a bare string for a
/// lone text part (media parts switch it to a parts array in a later phase).
fn appendUserMessage(arena: std.mem.Allocator, messages: *json.Value, prompt: []const u8) !void {
    var um = json.object();
    try json.set(arena, &um, "role", .{ .string = "user" });
    try json.set(arena, &um, "content", .{ .string = prompt });
    try messages.array.append(um);
}

/// Places every set generation parameter on `body` at its per-provider
/// (and, per ADR-024, per-model) wire key, reading the resolution entirely
/// from the generated option table — never a hand-switch on provider/model
/// name. Mirrors Go's `addOptions`/`resolveOptionKey` and Rust's
/// `add_options`/`resolve_option_key`.
fn applyOptions(arena: std.mem.Allocator, body: *json.Value, cfg: ChatConfig) !void {
    const model = cfg.model orelse "";
    var root_extras = json.object();

    if (cfg.temperature) |v|
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .temperature, .{ .float = v });
    if (cfg.top_p) |v|
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .top_p, .{ .float = v });
    if (cfg.top_k) |v|
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .top_k, .{ .integer = v });
    if (cfg.max_tokens) |v|
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .max_tokens, .{ .integer = v });
    if (cfg.seed) |v|
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .seed, .{ .integer = v });
    if (cfg.frequency_penalty) |v|
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .frequency_penalty, .{ .float = v });
    if (cfg.presence_penalty) |v|
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .presence_penalty, .{ .float = v });
    if (cfg.thinking_budget) |v|
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .thinking_budget, .{ .integer = v });
    if (cfg.reasoning_effort) |v|
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .reasoning_effort, .{ .string = v });
    if (cfg.stop_sequences) |ss| {
        var arr = json.array(arena);
        for (ss) |s| try arr.array.append(.{ .string = s });
        try maybeInsert(arena, body, &root_extras, cfg.provider, model, .stop_sequences, arr);
    }

    try json.mergeRoot(arena, body, root_extras);
}

/// Resolves `key`'s wire path for `provider`/`model`: a per-model override
/// (ADR-024, longest matching pattern-prefix wins, an exact `id` match wins
/// outright) takes precedence over the provider's default `supportedOptions`
/// binding. Returns `null` when the provider does not support `key` at all —
/// the caller must silently drop the option rather than send an unsupported
/// key.
fn resolveOptionKey(provider: providers.ProviderName, model: []const u8, key: options.OptionKey) ?[]const u8 {
    var best_key: ?[]const u8 = null;
    var best_len: isize = -1;
    for (options.modelOptionOverrides(provider)) |ov| {
        if (ov.key != key) continue;
        if (std.mem.eql(u8, ov.matcher_kind, "id")) {
            if (std.mem.eql(u8, ov.matcher_value, model)) return ov.json_key;
        } else {
            const prefix = if (std.mem.endsWith(u8, ov.matcher_value, "*"))
                ov.matcher_value[0 .. ov.matcher_value.len - 1]
            else
                ov.matcher_value;
            const prefix_len: isize = @intCast(prefix.len);
            if (std.mem.startsWith(u8, model, prefix) and prefix_len > best_len) {
                best_key = ov.json_key;
                best_len = prefix_len;
            }
        }
    }
    if (best_len >= 0) return best_key;
    for (options.supportedOptions(provider)) |opt| {
        if (opt.key == key) return opt.json_key;
    }
    return null;
}

/// Inserts `value` at `key`'s resolved wire path (a no-op when the provider
/// does not support `key`), then folds in the option's static sibling fields
/// (`extra_fields_json`, merged into the leaf's parent object) and root-level
/// fields (`root_extra_fields_json`, accumulated into `root_extras` for the
/// caller to merge at the true body root — ADR-029 THK-003).
fn maybeInsert(
    arena: std.mem.Allocator,
    body: *json.Value,
    root_extras: *json.Value,
    provider: providers.ProviderName,
    model: []const u8,
    key: options.OptionKey,
    value: json.Value,
) !void {
    const json_key = resolveOptionKey(provider, model, key) orelse return;
    try json.setPath(arena, body, json_key, value);

    for (options.optionOverrides(provider)) |ov| {
        if (ov.key != key) continue;
        if (ov.extra_fields_json.len > 0) {
            if (std.json.parseFromSliceLeaky(json.Value, arena, ov.extra_fields_json, .{})) |extras| {
                try mergeIntoParent(arena, body, json_key, extras);
            } else |_| {}
        }
        if (ov.root_extra_fields_json.len > 0) {
            if (std.json.parseFromSliceLeaky(json.Value, arena, ov.root_extra_fields_json, .{})) |extras| {
                try deepMerge(arena, root_extras, extras);
            } else |_| {}
        }
    }
}

/// Merges every top-level key of `extras` into the object CONTAINING the leaf
/// of dotted `path` — e.g. for `"thinking.budget_tokens"` the merge lands in
/// `body["thinking"]`; for a top-level path, directly in `body`.
fn mergeIntoParent(arena: std.mem.Allocator, body: *json.Value, path: []const u8, extras: json.Value) !void {
    if (std.meta.activeTag(extras) != .object) return;

    var parent = body;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (it.peek() == null) break; // stop before the leaf segment
        const key = try arena.dupe(u8, seg);
        const gop = try parent.object.getOrPut(arena, key);
        if (!gop.found_existing or std.meta.activeTag(gop.value_ptr.*) != .object) {
            gop.value_ptr.* = json.object();
        }
        parent = gop.value_ptr;
    }

    var eit = extras.object.iterator();
    while (eit.next()) |entry| {
        try parent.object.put(arena, try arena.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
    }
}

/// Deep-merges `src` into `dst`: when both sides hold an object at the same
/// key the objects merge recursively, otherwise `src` overwrites. Used for
/// `root_extra_fields_json` so e.g. `{"thinking":{"type":"adaptive"}}`
/// composes with an already-present `thinking` object instead of replacing it.
fn deepMerge(arena: std.mem.Allocator, dst: *json.Value, src: json.Value) !void {
    if (std.meta.activeTag(src) != .object) return;
    var it = src.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (std.meta.activeTag(val) == .object) {
            const gop = try dst.object.getOrPut(arena, try arena.dupe(u8, key));
            if (!gop.found_existing or std.meta.activeTag(gop.value_ptr.*) != .object) {
                gop.value_ptr.* = json.object();
            }
            try deepMerge(arena, gop.value_ptr, val);
        } else {
            try dst.object.put(arena, try arena.dupe(u8, key), val);
        }
    }
}
