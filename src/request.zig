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
//! (top-level `system` string, same table-driven options); Slice C adds the
//! `ChatGoogle` wire shape (`contents`/`parts`, sibling `system_instruction`,
//! options wrapped in `generationConfig` per `spec.wraps_options_in`). Slice D
//! adds the `ChatBedrock` wire shape (Converse API: `content`/`system` as
//! arrays of `{text}` blocks, no `model` in body, options wrapped in
//! `inferenceConfig`). Slice E (ADR-060) adds multimodal input Parts on the
//! text path: image + file Parts precede the trailing prompt-text Part in the
//! user turn, serialized per provider (OpenAI `image_url`/`file`, Anthropic
//! `image`/`document`, Google `inline_data`, Bedrock Converse `image`) — the
//! bare-text wire shape is preserved byte-for-byte when no media Parts are set.

const std = @import("std");
const json = @import("json.zig");
const parts = @import("parts.zig");
const providers = @import("providers/generated/providers.zig");
const options = @import("providers/generated/options.zig");
const request_defs = @import("providers/generated/request_defs.zig");

/// A non-text input Part on the ChatCompletion text path (ADR-060), re-exported
/// from `parts.zig` where the per-provider serialization lives.
pub const MediaPart = parts.MediaPart;

pub const ChatConfig = struct {
    provider: providers.ProviderName,
    model: ?[]const u8 = null,
    system: ?[]const u8 = null,
    prompt: []const u8,
    /// Media Parts (image/file) that precede the prompt text Part in the user
    /// turn, in caller order (ADR-060). Empty keeps the bare-text wire shape.
    media: []const MediaPart = &.{},
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
/// `ChatOpenAI` (system-in-messages), `ChatAnthropic` (top-level `system`
/// string), `ChatGoogle` (`contents`/`parts`, wrapped options), and
/// `ChatBedrock` (Converse content/system arrays, `inferenceConfig`-wrapped
/// options, no `model` in body); other shapes still reject.
pub fn buildChatBody(arena: std.mem.Allocator, cfg: ChatConfig) BuildError!json.Value {
    const spec = providers.spec(cfg.provider);
    if (std.mem.eql(u8, spec.chat_wire_shape, "ChatOpenAI"))
        return buildOpenAIBody(arena, cfg);
    if (std.mem.eql(u8, spec.chat_wire_shape, "ChatAnthropic"))
        return buildAnthropicBody(arena, cfg);
    if (std.mem.eql(u8, spec.chat_wire_shape, "ChatGoogle"))
        return buildGoogleBody(arena, cfg);
    if (std.mem.eql(u8, spec.chat_wire_shape, "ChatBedrock"))
        return buildBedrockBody(arena, cfg);
    return error.UnsupportedWireShape;
}

/// One HTTP request header name/value pair produced by the pure header seam.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Build the request headers for `cfg` — the pure, I/O-free counterpart to
/// `buildChatBody`. Returns an arena-backed slice of name/value pairs.
///
/// Scope (Slice F): the provider's required header (Anthropic ->
/// `anthropic-version: 2023-06-01`) plus, when the request references an
/// uploaded FILE Part (BUG-017), the file-reference beta header (Anthropic ->
/// `anthropic-beta: files-api-2025-04-14`) selected from the generated
/// `fileUploadConfig` def by the provider's file-upload FACT — never a
/// provider-name switch. The `anthropic-beta` value is composed through
/// `appendBeta`, so the structured-output beta (a later slice) can compose onto
/// the same header comma-separated rather than overwriting it. Mirrors Rust
/// `build_request`'s header assembly (`build_auth_headers` + the file-beta
/// block) minus the auth header, which needs the api key the pure wire path
/// does not carry (the wire golden asserts only `anthropic-beta`).
pub fn buildRequestHeaders(arena: std.mem.Allocator, cfg: ChatConfig) ![]Header {
    const spec = providers.spec(cfg.provider);
    var list: std.ArrayList(Header) = .empty;

    if (spec.required_header.len > 0)
        try list.append(arena, .{ .name = spec.required_header, .value = spec.required_header_value });

    // BUG-017: a text request that references an uploaded file emits a
    // `document`/`file` block the Messages API rejects unless the same
    // file-upload beta the upload path sends rides along. The def is selected by
    // the provider's `fileUploadConfig` fact (wire shape), not a name switch.
    if (hasFilePart(cfg.media)) {
        if (request_defs.fileUploadConfig(cfg.provider)) |upload| {
            if (upload.beta_header.len > 0)
                try appendBeta(arena, &list, upload.beta_header);
        }
    }

    return list.toOwnedSlice(arena);
}

/// True when any media Part is an uploaded-file reference (the BUG-017 trigger).
fn hasFilePart(media: []const MediaPart) bool {
    for (media) |part| switch (part) {
        .file => return true,
        else => {},
    };
    return false;
}

/// Composes `add` into the header list's `anthropic-beta` value — the shared
/// beta-composition seam. Finds an existing `anthropic-beta` header and
/// comma-joins `add` (deduped, skipped when already present), or pushes a fresh
/// one. The structured-output slice will call this same path so the two betas
/// compose into one header instead of overwriting. Mirrors Rust `append_beta`
/// plus the find-or-push in `build_request`.
fn appendBeta(arena: std.mem.Allocator, list: *std.ArrayList(Header), add: []const u8) !void {
    if (add.len == 0) return;
    for (list.items) |*h| {
        if (std.ascii.eqlIgnoreCase(h.name, "anthropic-beta")) {
            h.value = try composeBeta(arena, h.value, add);
            return;
        }
    }
    try list.append(arena, .{ .name = "anthropic-beta", .value = add });
}

/// Comma-joins `add` onto `existing`, deduping an already-present flag (never
/// overwriting) — the pure string half of `appendBeta`.
fn composeBeta(arena: std.mem.Allocator, existing: []const u8, add: []const u8) ![]const u8 {
    if (existing.len == 0) return add;
    var it = std.mem.splitScalar(u8, existing, ',');
    while (it.next()) |flag| {
        if (std.mem.eql(u8, std.mem.trim(u8, flag, " "), add)) return existing;
    }
    return std.fmt.allocPrint(arena, "{s},{s}", .{ existing, add });
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
    var um = json.object();
    try json.set(arena, &um, "role", .{ .string = "user" });
    try json.set(arena, &um, "content", try parts.openAIUserContent(arena, cfg.media, cfg.prompt));
    try messages.array.append(um);
    try json.set(arena, &body, "messages", messages);

    // Options and root extras both land on `body` (no wrapper): opts_target == root.
    try applyOptions(arena, &body, &body, cfg);
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
    var um = json.object();
    try json.set(arena, &um, "role", .{ .string = "user" });
    try json.set(arena, &um, "content", try parts.anthropicUserContent(arena, cfg.media, cfg.prompt));
    try messages.array.append(um);
    try json.set(arena, &body, "messages", messages);

    // Options and root extras both land on `body` (no wrapper): opts_target == root.
    try applyOptions(arena, &body, &body, cfg);
    return body;
}

/// The `ChatGoogle` wire shape: the user turn is a `contents` array of
/// `{role, parts:[{text:...}]}` objects (not a bare `content` string), the
/// system prompt (when present) is a sibling `system_instruction` object with
/// the same `{parts:[{text:...}]}` shape (`SiblingObject` placement), and the
/// generation options are WRAPPED in a `generationConfig` object named by
/// `spec.wraps_options_in` — so `max_output_tokens`, `temperature`, and the
/// dotted `thinkingConfig.thinkingBudget` nest inside the wrapper rather than
/// at the body root. Root extras (ADR-029 THK-003, none in these fixtures)
/// still merge into the true body root, never the wrapper. Wire keys come
/// from the generated option table exactly as the flat shapes do.
fn buildGoogleBody(arena: std.mem.Allocator, cfg: ChatConfig) BuildError!json.Value {
    const spec = providers.spec(cfg.provider);
    var body = json.object();

    var contents = json.array(arena);
    var turn = json.object();
    try json.set(arena, &turn, "role", .{ .string = "user" });
    try json.set(arena, &turn, "parts", try parts.googleParts(arena, cfg.media, cfg.prompt));
    try contents.array.append(turn);
    try json.set(arena, &body, "contents", contents);

    if (cfg.system) |sys| {
        var si = json.object();
        try json.set(arena, &si, "parts", try textParts(arena, sys));
        try json.set(arena, &body, "system_instruction", si);
    }

    // Options go into the wrapper (opts_target = &wrapper); root extras still
    // merge into the true body root (root = &body). Only attach the wrapper
    // when it holds at least one option — mirrors Rust's non-empty guard.
    var wrapper = json.object();
    try applyOptions(arena, &wrapper, &body, cfg);
    if (wrapper.object.count() > 0)
        try json.set(arena, &body, spec.wraps_options_in, wrapper);

    return body;
}

/// The `ChatBedrock` wire shape (AWS Bedrock Converse API): the user turn's
/// `content` is an ARRAY of `{text:...}` blocks (not a bare string like OpenAI,
/// nor `parts` like Google), and the system prompt (when present) is a
/// TOP-LEVEL `system` ARRAY of `{text:...}` blocks — `TopLevelField` placement,
/// but an array of text blocks unlike Anthropic's bare `system` string. The
/// model is carried in the URL, never the body (`spec.model_in_body == false`),
/// so there is no `model` field. Generation options are WRAPPED in the
/// `inferenceConfig` object named by `spec.wraps_options_in` (`maxTokens`,
/// `stopSequences`, `temperature`, `top_p` — wire keys from the generated
/// option table). Root extras (ADR-029 THK-003, none here) still merge into the
/// true body root, never the wrapper.
fn buildBedrockBody(arena: std.mem.Allocator, cfg: ChatConfig) BuildError!json.Value {
    const spec = providers.spec(cfg.provider);
    var body = json.object();

    // System (when present): a top-level `system` array of `{text:...}` blocks
    // (Converse), not Anthropic's bare `system` string.
    if (cfg.system) |sys|
        try json.set(arena, &body, "system", try textParts(arena, sys));

    // User turn: `content` is an ARRAY of `{text:...}` blocks, not a bare string.
    var messages = json.array(arena);
    var turn = json.object();
    try json.set(arena, &turn, "role", .{ .string = "user" });
    try json.set(arena, &turn, "content", try parts.bedrockContent(arena, cfg.media, cfg.prompt));
    try messages.array.append(turn);
    try json.set(arena, &body, "messages", messages);

    // Options nest in the `inferenceConfig` wrapper (opts_target = &wrapper);
    // root extras still merge into the true body root. Attach the wrapper only
    // when it holds at least one option — mirrors the Google shape's guard.
    var wrapper = json.object();
    try applyOptions(arena, &wrapper, &body, cfg);
    if (wrapper.object.count() > 0)
        try json.set(arena, &body, spec.wraps_options_in, wrapper);

    // No `model` field: Bedrock puts the model in the URL (spec.model_in_body).
    return body;
}

/// A `[{"text": <s>}]` array — the shared text-block container for the Google
/// shape (a content turn and a `system_instruction`) and the Bedrock Converse
/// shape (a `content` array and a `system` array).
fn textParts(arena: std.mem.Allocator, text: []const u8) !json.Value {
    var arr = json.array(arena);
    var part = json.object();
    try json.set(arena, &part, "text", .{ .string = text });
    try arr.array.append(part);
    return arr;
}

/// Places every set generation parameter at its per-provider (and, per
/// ADR-024, per-model) wire key, reading the resolution entirely from the
/// generated option table — never a hand-switch on provider/model name.
/// Mirrors Go's `addOptions`/`resolveOptionKey` and Rust's `add_options`/
/// `resolve_option_key`.
///
/// The target is split in two: option wire keys and their sibling
/// `extra_fields_json` are written to `opts_target`, while root-level
/// `root_extra_fields_json` (ADR-029 THK-003) merges into `root`. For the flat
/// shapes (OpenAI/Anthropic) the caller passes the same body as both, so the
/// split is a no-op and the output stays byte-identical. For the wrapped
/// Google shape `opts_target` is the `generationConfig` object while `root`
/// stays the true body — so options nest in the wrapper but root extras do not.
fn applyOptions(arena: std.mem.Allocator, opts_target: *json.Value, root: *json.Value, cfg: ChatConfig) !void {
    const model = cfg.model orelse "";
    var root_extras = json.object();

    if (cfg.temperature) |v|
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .temperature, .{ .float = v });
    if (cfg.top_p) |v|
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .top_p, .{ .float = v });
    if (cfg.top_k) |v|
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .top_k, .{ .integer = v });
    // Effective max_tokens defaults to the provider's `default_max_tokens`
    // (mirrors Rust's `options.max_tokens.unwrap_or(config.default_max_tokens)`):
    // a user who never called `.maxTokens(...)` still emits the provider default,
    // routed through the same table-driven path (ADR-024 remap + wrapper
    // placement apply to the defaulted value). Emit only when > 0.
    const max_tokens = cfg.max_tokens orelse providers.spec(cfg.provider).default_max_tokens;
    if (max_tokens > 0)
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .max_tokens, .{ .integer = max_tokens });
    if (cfg.seed) |v|
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .seed, .{ .integer = v });
    if (cfg.frequency_penalty) |v|
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .frequency_penalty, .{ .float = v });
    if (cfg.presence_penalty) |v|
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .presence_penalty, .{ .float = v });
    if (cfg.thinking_budget) |v|
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .thinking_budget, .{ .integer = v });
    if (cfg.reasoning_effort) |v|
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .reasoning_effort, .{ .string = v });
    if (cfg.stop_sequences) |ss| {
        var arr = json.array(arena);
        for (ss) |s| try arr.array.append(.{ .string = s });
        try maybeInsert(arena, opts_target, &root_extras, cfg.provider, model, .stop_sequences, arr);
    }

    try json.mergeRoot(arena, root, root_extras);
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

/// Inserts `value` at `key`'s resolved wire path on `opts_target` (a no-op
/// when the provider does not support `key`), then folds in the option's
/// static sibling fields (`extra_fields_json`, merged into the leaf's parent
/// object on `opts_target`) and root-level fields (`root_extra_fields_json`,
/// accumulated into `root_extras` for the caller to merge at the true body
/// root — ADR-029 THK-003). For a wrapped shape `opts_target` is the wrapper,
/// so sibling extras stay inside it while root extras still escape to the root.
fn maybeInsert(
    arena: std.mem.Allocator,
    opts_target: *json.Value,
    root_extras: *json.Value,
    provider: providers.ProviderName,
    model: []const u8,
    key: options.OptionKey,
    value: json.Value,
) !void {
    const json_key = resolveOptionKey(provider, model, key) orelse return;
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
