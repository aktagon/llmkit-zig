//! llmkit — the Zig client for llmkit. One typed API across many LLM providers.
//!
//! Phase 0 vertical slice: the JSON waist, the OpenAI-shape request builder,
//! and the public client + Text builder. HTTP send, the remaining wire shapes,
//! and the media/async capabilities arrive in later phases.

const std = @import("std");

pub const json = @import("json.zig");
pub const providers = @import("providers/generated/providers.zig");
pub const request = @import("request.zig");
pub const client = @import("client.zig");

pub const Client = client.Client;
pub const Text = client.Text;
pub const ProviderName = providers.ProviderName;





