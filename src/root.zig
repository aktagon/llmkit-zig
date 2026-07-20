//! llmkit — the Zig client for llmkit. One typed API across many LLM providers.
//!
//! Phase 0 vertical slice: the JSON waist, the OpenAI-shape request builder,
//! and the public client + Text builder. HTTP send, the remaining wire shapes,
//! and the media/async capabilities arrive in later phases.

const std = @import("std");

pub const json = @import("json.zig");
pub const providers = @import("providers/generated/providers.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const http = @import("http.zig");
pub const stream = @import("stream.zig");
pub const agent = @import("agent.zig");
pub const client = @import("client.zig");

pub const Client = client.Client;
pub const Text = client.Text;
pub const Agent = agent.Agent;
pub const Tool = agent.Tool;
pub const ProviderName = providers.ProviderName;
pub const Protocol = client.Protocol;
pub const SafetySetting = client.SafetySetting;





