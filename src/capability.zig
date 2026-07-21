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
