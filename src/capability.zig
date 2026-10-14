//! Capability — the hand-written cross-SDK capability enum (ADR-019 / ADR-030).
//!
//! The counterpart of Rust `types::Capability`, Go `Capability`, and
//! Swift `Capability`. It is hand-written (not generated) so it lives at the
//! src root; the generated catalogue/struct modules import it via
//! `@import("../../capability.zig")`. The tag name IS the slug (snake_case,
//! matching every SDK's `as_str`), so `slug()` == `@tagName` — no generated
//! bridge is needed, the same identity trick `ProviderName` uses.
//!
//!
//! `_ZIG_CAPABILITY_VARIANT` map: the generated `catalogue.zig` emits
//! `[]const Capability` literals whose tags must all exist here.

const std = @import("std");
const providers = @import("providers/generated/providers.zig");
const batch_defs = @import("providers/generated/batch.zig");
const caching_defs = @import("providers/generated/caching.zig");
const image_defs = @import("providers/generated/image_gen.zig");
const request_defs = @import("providers/generated/request_defs.zig");

pub const Capability = enum {
    chat_completion,
    image_generation,
    tool_calling,
    file_upload,
    batching,
    caching,
    reasoning,
    catalogue,

    ///
    /// other SDK's `as_str`. The tag name already IS the slug.
    pub fn slug(self: Capability) []const u8 {
        return @tagName(self);
    }
};

/// True iff an explicit request for `cap` will not hard-fail pre-flight on
/// `provider` (ADR-030, `Client.supports`). Each gated arm dispatches the SAME
/// generated `*Config` lookup its strict validation path uses (CAP-002), so the
/// answer cannot drift from the behaviour it predicts; ungated capabilities
/// return true. Says nothing about per-MODEL rejections — those are
/// `ModelInfo.capabilities` in the catalogue. Sync, no I/O, infallible.
pub fn providerSupports(provider: providers.ProviderName, cap: Capability) bool {
    return switch (cap) {
        .caching => caching_defs.cachingConfig(provider) != null,
        .batching => batch_defs.batchConfig(provider) != null,
        .file_upload => request_defs.fileUploadConfig(provider) != null,
        .image_generation => image_defs.imageGenConfig(provider) != null,
        else => true,
    };
}





























