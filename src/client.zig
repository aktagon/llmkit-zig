//! The public client + Text builder (ADR-069 ZIG-005).
//!
//! Builders are immutable value types: each chain method returns a fresh copy
//! (`var s = self; …; return s;`), so a forked chain never mutates its parent.
//! Chain methods take neither `io` nor an allocator; only the terminals do the
//! I/O and thus take `io` + a `gpa`. Phase 0 stops at `buildBody` — the
//! HTTP-sending terminal (`prompt`) arrives with the HTTP module in a later
//! phase; the wire suite asserts the body `buildBody` produces.

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const request = @import("request.zig");

pub const ProviderName = providers.ProviderName;

/// One caller-supplied header name/value pair (ADR-052 `addHeader` parity).
const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

/// Fixed capacity for `Client.addHeader` — Client chain methods take no
/// allocator (ADR-069 ZIG-005), so custom headers live in a bounded array
/// rather than a heap-allocated list. 16 is generous headroom over every
/// other SDK's real-world usage; raise it if a caller ever needs more.
const max_custom_headers = 16;

pub const Client = struct {
    provider: providers.ProviderName,
    base_url: ?[]const u8 = null,
    custom_headers: [max_custom_headers]HeaderPair = undefined,
    custom_header_count: usize = 0,

    pub fn init(provider: providers.ProviderName) Client {
        return .{ .provider = provider };
    }

    /// Override the provider base URL (e.g. an OpenAI-compat gateway).
    pub fn baseURL(self: Client, url: []const u8) Client {
        var c = self;
        c.base_url = url;
        return c;
    }

    /// Add a custom header sent with every request (ADR-052 parity with the
    /// other five SDKs' `AddHeader`/`addHeader`/`add_header`). Wiring onto
    /// the actual HTTP send arrives with the HTTP module in a later phase;
    /// today this only records the pair on the (still-immutable) builder.
    pub fn addHeader(self: Client, name: []const u8, value: []const u8) Client {
        var c = self;
        std.debug.assert(c.custom_header_count < max_custom_headers);
        c.custom_headers[c.custom_header_count] = .{ .name = name, .value = value };
        c.custom_header_count += 1;
        return c;
    }

    /// Enter the ChatCompletion (text) builder.
    pub fn text(self: Client) Text {
        return .{ .provider = self.provider };
    }
};

pub const Text = struct {
    provider: providers.ProviderName,
    model_: ?[]const u8 = null,
    system_: ?[]const u8 = null,
    max_tokens_: ?i64 = null,
    temperature_: ?f64 = null,
    top_p_: ?f64 = null,
    frequency_penalty_: ?f64 = null,
    presence_penalty_: ?f64 = null,
    reasoning_effort_: ?[]const u8 = null,
    seed_: ?i64 = null,
    stop_sequences_: ?[]const []const u8 = null,
    thinking_budget_: ?i64 = null,
    top_k_: ?i64 = null,

    pub fn model(self: Text, m: []const u8) Text {
        var s = self;
        s.model_ = m;
        return s;
    }

    pub fn system(self: Text, sys: []const u8) Text {
        var s = self;
        s.system_ = sys;
        return s;
    }

    pub fn maxTokens(self: Text, n: i64) Text {
        var s = self;
        s.max_tokens_ = n;
        return s;
    }

    pub fn temperature(self: Text, t: f64) Text {
        var s = self;
        s.temperature_ = t;
        return s;
    }

    pub fn topP(self: Text, p: f64) Text {
        var s = self;
        s.top_p_ = p;
        return s;
    }

    /// ADR-024 option. Phase 1: recorded on the builder only — per-provider
    /// wire emission arrives with the generated option table in Phase 2
    /// (ChatCompletion parity, `docs/handoffs/041-...`).
    pub fn frequencyPenalty(self: Text, v: f64) Text {
        var s = self;
        s.frequency_penalty_ = v;
        return s;
    }

    /// ADR-024 option. Phase 1: recorded on the builder only (see
    /// `frequencyPenalty`).
    pub fn presencePenalty(self: Text, v: f64) Text {
        var s = self;
        s.presence_penalty_ = v;
        return s;
    }

    /// ADR-024 option. Phase 1: recorded on the builder only (see
    /// `frequencyPenalty`).
    pub fn reasoningEffort(self: Text, v: []const u8) Text {
        var s = self;
        s.reasoning_effort_ = v;
        return s;
    }

    /// ADR-024 option. Phase 1: recorded on the builder only (see
    /// `frequencyPenalty`).
    pub fn seed(self: Text, v: i64) Text {
        var s = self;
        s.seed_ = v;
        return s;
    }

    /// ADR-024 option. Phase 1: recorded on the builder only (see
    /// `frequencyPenalty`).
    pub fn stopSequences(self: Text, v: []const []const u8) Text {
        var s = self;
        s.stop_sequences_ = v;
        return s;
    }

    /// ADR-024 option. Phase 1: recorded on the builder only (see
    /// `frequencyPenalty`).
    pub fn thinkingBudget(self: Text, v: i64) Text {
        var s = self;
        s.thinking_budget_ = v;
        return s;
    }

    /// ADR-024 option. Phase 1: recorded on the builder only (see
    /// `frequencyPenalty`).
    pub fn topK(self: Text, v: i64) Text {
        var s = self;
        s.top_k_ = v;
        return s;
    }

    /// Build the request body for this configuration. Returns a Value backed by
    /// `arena`. Phase 0/1 do no HTTP send.
    pub fn buildBody(self: Text, arena: std.mem.Allocator, prompt: []const u8) request.BuildError!json.Value {
        return request.buildChatBody(arena, .{
            .provider = self.provider,
            .model = self.model_,
            .system = self.system_,
            .prompt = prompt,
            .max_tokens = self.max_tokens_,
            .temperature = self.temperature_,
            .top_p = self.top_p_,
            .top_k = self.top_k_,
            .frequency_penalty = self.frequency_penalty_,
            .presence_penalty = self.presence_penalty_,
            .reasoning_effort = self.reasoning_effort_,
            .seed = self.seed_,
            .stop_sequences = self.stop_sequences_,
            .thinking_budget = self.thinking_budget_,
        });
    }
};

















