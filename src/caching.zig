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
//!   - ResourceCaching (Google): a `cachedContents` network pre-hop — deferred
//!     (needs a send before the main request; no wire fixture gates it, and the
//!     text-path wire suite asserts the request body only).
//! Mirrors Rust `apply_caching` / Go `applyCaching`.

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const caching_defs = @import("providers/generated/caching.zig");
const request_defs = @import("providers/generated/request_defs.zig");

/// Apply prompt caching to a built chat `body` in place, dispatching on the
/// provider's generated `CachingMode`. A no-op for providers without a caching
/// config, for AutomaticCaching, and (for now) for ResourceCaching.
pub fn applyCaching(arena: std.mem.Allocator, body: *json.Value, provider: providers.ProviderName) !void {
    const cfg = caching_defs.cachingConfig(provider) orelse return;
    switch (cfg.mode) {
        .explicit_caching => try applyExplicit(arena, body, provider, cfg.control_type),
        .automatic_caching => {},
        .resource_caching => {}, // Google network pre-hop — deferred (not wire-gated).
    }
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



























