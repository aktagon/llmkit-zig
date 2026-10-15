//! The table-driven option-placement primitives shared by every chat wire
//! shape's `applyOptions` (request.zig). These are the ChatConfig-INDEPENDENT
//! lower half: given a resolved `(provider, model, key, value)`, place the value
//! at its per-provider (ADR-024 per-model) wire key and fold in the option's
//! static sibling/root extras (ADR-029 THK-003). They read the generated option
//! table only — never a hand-switch on provider/model name — so they live in a
//! standalone module with no dependency on the request builder (which keeps the
//! ChatConfig-aware orchestration in `applyOptions`).

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const options = @import("providers/generated/options.zig");

/// Resolves `key`'s wire path for `provider`/`model` under the effective chat
/// wire shape `shape`. A wire-shape key (BUG-075) outranks everything: the
/// Responses shape names MaxTokens `max_output_tokens` for every model. Next, a
/// per-model override (ADR-024, longest matching pattern-prefix wins, an exact
/// `id` match wins outright) takes precedence over the provider's default
/// `supportedOptions` binding. Returns `null` when the provider does not
/// support `key` at all — the caller must silently drop the option rather than
/// send an unsupported key.
pub fn resolveOptionKey(provider: providers.ProviderName, model: []const u8, shape: []const u8, key: options.OptionKey) ?[]const u8 {
    for (options.wireShapeOptionOverrides(shape)) |ov| {
        if (ov.key == key) return ov.json_key;
    }
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

/// Inserts `value` at `key`'s resolved wire path on `opts_target` (a no-op
/// when the provider does not support `key`), then folds in the option's
/// static sibling fields (`extra_fields_json`, merged into the leaf's parent
/// object on `opts_target`) and root-level fields (`root_extra_fields_json`,
/// accumulated into `root_extras` for the caller to merge at the true body
/// root — ADR-029 THK-003). For a wrapped shape `opts_target` is the wrapper,
/// so sibling extras stay inside it while root extras still escape to the root.
pub fn maybeInsert(
    arena: std.mem.Allocator,
    opts_target: *json.Value,
    root_extras: *json.Value,
    provider: providers.ProviderName,
    model: []const u8,
    shape: []const u8,
    key: options.OptionKey,
    value: json.Value,
) !void {
    const json_key = resolveOptionKey(provider, model, shape, key) orelse return;
    try json.setPath(arena, opts_target, json_key, value);

    for (options.optionOverrides(provider)) |ov| {
        if (ov.key != key) continue;
        if (ov.extra_fields_json.len > 0) {
            if (std.json.parseFromSliceLeaky(json.Value, arena, ov.extra_fields_json, .{})) |extras| {
                try mergeIntoParent(arena, opts_target, json_key, extras);
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















































