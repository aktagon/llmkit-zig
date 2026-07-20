//! PHASE 0 STUB — a minimal, hand-written provider table for the vertical
//! slice (OpenAI-shape chat). This is deliberately NOT a generated file (no
//! `DO NOT EDIT` header) so it makes no false claim of generator provenance.
//! Phase 1 replaces it with `src/providers/generated/providers.zig`, emitted by
//!
//! `ProviderName` enum and the complete `ProviderSpec` wire table.

const std = @import("std");

/// The set of providers the SDK can talk to (phase 0: the two needed for the
/// OpenAI-shape vertical slice). The tag name is the provider slug.
pub const ProviderName = enum {
    openai,
    workersai,

    pub fn slug(self: ProviderName) []const u8 {
        return @tagName(self);
    }
};

/// How the library talks to a provider — the internal wire/transform spec.
/// Phase 0 carries only the fields the chat-body build needs; phase 1's
/// generated spec carries the full 35-field table (auth, usage paths, error
/// paths, SigV4 env vars, ...).
pub const ProviderSpec = struct {
    name: ProviderName,
    base_url: []const u8,
    endpoint: []const u8,
    /// "MessageInArray" | "TopLevelField" | ... — where the system prompt goes.
    system_placement: []const u8,
    /// "ChatOpenAI" | "ChatAnthropic" | ... — the request wire shape.
    chat_wire_shape: []const u8,
};

pub fn spec(name: ProviderName) ProviderSpec {
    return switch (name) {
        .openai => .{
            .name = .openai,
            .base_url = "https://api.openai.com",
            .endpoint = "/v1/chat/completions",
            .system_placement = "MessageInArray",
            .chat_wire_shape = "ChatOpenAI",
        },
        .workersai => .{
            .name = .workersai,
            .base_url = "https://api.cloudflare.com",
            .endpoint = "/v1/chat/completions",
            .system_placement = "MessageInArray",
            .chat_wire_shape = "ChatOpenAI",
        },
    };
}
