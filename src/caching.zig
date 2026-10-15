//! Prompt caching applied by construction (ADR-026), Phase 3 slice 5.
//!
//! One seam — `applyCaching` — invoked at the end of `request.buildChatBody`
//! (gated on `ChatConfig.caching`), so EVERY send path that builds a chat body
//! (text / agent / batch) gets caching by construction from a single site (the
//! BUG-004 drift class the request-wire caching goldens lock). Dispatches on the
//! generated `CachingMode`, never a provider name:
//!   - ExplicitCaching (Anthropic): inject `cache_control:{type:<control_type>}`
//!     onto the system block. For `TopLevelField` placement the `system` STRING
//!     is rewritten into a `[{type:"text", text, cache_control}]` array (the
//!     caching-{text,agent,batch}-anthropic goldens).
//!   - AutomaticCaching (OpenAI): no-op (the provider caches server-side).
//!   - ResourceCaching (Google): a `cachedContents` network pre-hop. It needs a
//!     send, so it cannot live in the pure `buildChatBody`; every terminal that
//!     sends a chat body calls `applyResourceCaching` on it before the send
//!     (the caching-create-google golden locks the create body).
//! Mirrors Rust `apply_caching` / Go `applyCaching`.

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const caching_defs = @import("providers/generated/caching.zig");
const request_defs = @import("providers/generated/request_defs.zig");
const http = @import("http.zig");
const send = @import("send.zig");

/// Apply prompt caching to a built chat `body` in place, dispatching on the
/// provider's generated `CachingMode`. A no-op for providers without a caching
/// config, for AutomaticCaching, and (for now) for ResourceCaching.
pub fn applyCaching(arena: std.mem.Allocator, body: *json.Value, provider: providers.ProviderName) !void {
    const cfg = caching_defs.cachingConfig(provider) orelse return;
    switch (cfg.mode) {
        .explicit_caching => try applyExplicit(arena, body, provider, cfg.control_type),
        .automatic_caching => {},
        .resource_caching => {}, // a network pre-hop: see applyResourceCaching.
    }
}

/// ResourceCaching: create a provider-side cache holding the system prompt and
/// point `body` at it. POSTs `{model, ttl, contents, systemInstruction}` to the
/// lifecycle's create endpoint, reads the resource id at `response_id_path`,
/// sets it at `reference_field`, and drops `system_instruction` from `body`.
/// A no-op for any other caching mode and for a body with no system prompt.
/// `model` is the effective model id. Mirrors Rust `apply_resource_caching`.
pub fn applyResourceCaching(
    transport: http.Transport,
    arena: std.mem.Allocator,
    ctx: *const http.Ctx,
    provider: providers.ProviderName,
    api_key: []const u8,
    model: []const u8,
    body: *json.Value,
) !void {
    const cfg = caching_defs.cachingConfig(provider) orelse return;
    if (cfg.mode != .resource_caching) return;
    const lc = cfg.lifecycle orelse return error.UnsupportedWireShape;
    const system_instruction = body.object.get("system_instruction") orelse return;

    var part = json.object();
    try json.set(arena, &part, "text", .{ .string = "cache" });
    var parts = json.array(arena);
    try parts.array.append(part);
    var turn = json.object();
    try json.set(arena, &turn, "role", .{ .string = "user" });
    try json.set(arena, &turn, "parts", parts);
    var contents = json.array(arena);
    try contents.array.append(turn);

    var create = json.object();
    try json.set(arena, &create, "model", .{ .string = try std.fmt.allocPrint(arena, "models/{s}", .{model}) });
    try json.set(arena, &create, "ttl", .{ .string = try std.fmt.allocPrint(arena, "{s}s", .{cfg.default_ttl}) });
    try json.set(arena, &create, "contents", contents);
    try json.set(arena, &create, "systemInstruction", system_instruction);

    const reply = try send.postJson(transport, arena, .{
        .provider = provider,
        .ctx = ctx,
        .api_key = api_key,
        .endpoint = lc.create_endpoint,
        .op = .cache_create,
        .model = model,
    }, create);

    const id = json.getPath(reply, lc.response_id_path) orelse return error.ApiError;
    if (id != .string or id.string.len == 0) return error.ApiError;
    try json.set(arena, body, lc.reference_field, .{ .string = id.string });
    _ = body.object.orderedRemove("system_instruction");
}

/// ExplicitCaching: annotate the system block with `cache_control`. Placement is
/// the generated `system_placement` fact.
fn applyExplicit(arena: std.mem.Allocator, body: *json.Value, provider: providers.ProviderName, control_type: []const u8) !void {
    switch (request_defs.systemPlacement(provider)) {
        .top_level_field => {
            // Anthropic: the system prompt is a top-level `system` STRING; wrap
            // it into a one-element array of a text block carrying cache_control.
            const sys = body.object.get("system") orelse return;
            if (sys != .string) return;

            var cc = json.object();
            try json.set(arena, &cc, "type", .{ .string = control_type });

            var blk = json.object();
            try json.set(arena, &blk, "type", .{ .string = "text" });
            try json.set(arena, &blk, "text", .{ .string = sys.string });
            try json.set(arena, &blk, "cache_control", cc);

            var arr = json.array(arena);
            try arr.array.append(blk);
            try json.set(arena, body, "system", arr);
        },
        // No provider currently pairs ExplicitCaching with an in-array or sibling
        // system placement, so these have no wire fixture; left as no-ops until a
        // provider needs them (honest gap, not a silent drop).
        .message_in_array, .sibling_object => {},
    }
}





























































