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
const providers = @import("providers.zig");
const request = @import("request.zig");

pub const ProviderName = providers.ProviderName;

pub const Client = struct {
    provider: providers.ProviderName,
    base_url: ?[]const u8 = null,

    pub fn init(provider: providers.ProviderName) Client {
        return .{ .provider = provider };
    }

    /// Override the provider base URL (e.g. an OpenAI-compat gateway).
    pub fn baseURL(self: Client, url: []const u8) Client {
        var c = self;
        c.base_url = url;
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

    /// Build the request body for this configuration. Returns a Value backed by
    /// `arena`. Phase 0 does no HTTP send.
    pub fn buildBody(self: Text, arena: std.mem.Allocator, prompt: []const u8) request.BuildError!json.Value {
        return request.buildChatBody(arena, .{
            .provider = self.provider,
            .model = self.model_,
            .system = self.system_,
            .prompt = prompt,
            .max_tokens = self.max_tokens_,
            .temperature = self.temperature_,
            .top_p = self.top_p_,
        });
    }
};

















