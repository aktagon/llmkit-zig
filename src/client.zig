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
const http = @import("http.zig");
const stream_mod = @import("stream.zig");
const agent_mod = @import("agent.zig");
const batch_mod = @import("batch.zig");
const image_mod = @import("image.zig");
const speech_mod = @import("speech.zig");
const transcription_mod = @import("transcription.zig");
const video_mod = @import("video.zig");

pub const ProviderName = providers.ProviderName;

/// Chat-protocol selector (ADR-055), re-exported from `request.zig`.
pub const Protocol = request.Protocol;

/// Google safety setting `{category, threshold}`, re-exported from `request.zig`.
pub const SafetySetting = request.SafetySetting;

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

    /// Enter the Agent (tool-using ChatCompletion) builder.
    pub fn agent(self: Client) agent_mod.Agent {
        return .{ .provider = self.provider };
    }

    /// Enter the ImageGeneration builder (single-turn: text-to-image + edit).
    pub fn image(self: Client) image_mod.Image {
        return .{ .provider = self.provider };
    }

    /// Enter the SpeechGeneration builder (single-turn text-to-speech).
    pub fn speech(self: Client) speech_mod.Speech {
        return .{ .provider = self.provider };
    }

    /// Enter the Transcription builder (single-turn speech-to-text). JSON
    /// (AssemblyAI async submit) vs multipart (OpenAI sync) is picked by the
    /// terminal per the provider's generated `request_encoding` fact.
    pub fn transcription(self: Client) transcription_mod.Transcription {
        return .{ .provider = self.provider };
    }

    /// Enter the VideoGeneration builder (single-turn text-to-video, with an
    /// optional image-to-video seed frame). The async poll/wait runtime is a
    /// later slice; the builder's terminal produces the submit body.
    pub fn video(self: Client) video_mod.Video {
        return .{ .provider = self.provider };
    }
};

/// Fixed capacity for `Text.image`/`Text.file` media Parts. Text chain methods
/// take no allocator (ADR-069 ZIG-005), so media Parts live in a bounded array
/// like `Client.addHeader`. 8 is generous over any single-turn multimodal use.
const max_media_parts = 8;

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
    schema_: ?[]const u8 = null,
    protocol_: request.Protocol = .chat,
    safety_settings_: []const request.SafetySetting = &.{},
    caching_: bool = false,
    media_: [max_media_parts]request.MediaPart = undefined,
    media_count_: usize = 0,

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

    /// Structured JSON-schema output (BUG-007). `json_schema` is a JSON Schema
    /// STRING; the request builder parses it, applies the per-provider strict
    /// (OpenAI/Anthropic) or strip (Google) transform, and places it per the
    /// provider's generated structured-output def — never a provider-name
    /// switch. Mirrors Go/Rust `.Schema(...)`.
    pub fn schema(self: Text, json_schema: []const u8) Text {
        var s = self;
        s.schema_ = json_schema;
        return s;
    }

    /// Select a non-default chat protocol (ADR-055). `.responses` POSTs the
    /// OpenAI Responses `{input}` envelope to `/v1/responses` instead of the
    /// default Chat Completions `{messages}` envelope; `.chat` (the default)
    /// keeps the provider's default protocol. Mirrors Go/Rust `Protocol(...)`.
    pub fn protocol(self: Text, p: Protocol) Text {
        var s = self;
        s.protocol_ = p;
        return s;
    }

    /// Google safety settings (ADR-024): a top-level `safetySettings` array of
    /// `{category, threshold}` pairs, emitted only on the Google wire shape.
    /// `settings` is a caller-owned slice (chain methods take no allocator).
    /// Mirrors Go `SafetySettings([]SafetySetting)`.
    pub fn safetySettings(self: Text, settings: []const SafetySetting) Text {
        var s = self;
        s.safety_settings_ = settings;
        return s;
    }

    /// Enable prompt caching on this send path (ADR-026). Applied by
    /// construction in `buildChatBody`; the caching-text-anthropic golden
    /// asserts the cache_control-annotated system block. Mirrors Go/Rust
    /// `.Caching()`.
    pub fn caching(self: Text) Text {
        var s = self;
        s.caching_ = true;
        return s;
    }

    /// Append an inline image input Part (ADR-060). `mime` is the IANA media
    /// type (e.g. "image/png"); `bytes` is RAW (not base64) — the request
    /// builder encodes it per provider. Media Parts precede the prompt text in
    /// the user turn, in call order. Mirrors Rust/Go `image(mime, bytes)`.
    pub fn image(self: Text, mime: []const u8, bytes: []const u8) Text {
        var s = self;
        std.debug.assert(s.media_count_ < max_media_parts);
        s.media_[s.media_count_] = .{ .image = .{ .mime = mime, .bytes = bytes } };
        s.media_count_ += 1;
        return s;
    }

    /// Append an uploaded-file input Part by id (ADR-060 / BUG-014). Emits an
    /// Anthropic `document` or an OpenAI-style `file` block, selected by wire
    /// shape (never provider name). Mirrors Rust/Go `file(id)`.
    pub fn file(self: Text, file_id: []const u8) Text {
        var s = self;
        std.debug.assert(s.media_count_ < max_media_parts);
        s.media_[s.media_count_] = .{ .file = file_id };
        s.media_count_ += 1;
        return s;
    }

    /// The typed request config this builder describes. Constructed inline at
    /// each terminal (not returned from a helper): `media` slices into `self`'s
    /// inline `media_` array, so it is only valid while THIS `self` is alive —
    /// returning it from a helper would dangle the slice into that helper's
    /// dead `self` copy. Both terminals below therefore build it in-place, where
    /// `self` outlives the inner call that reads it.
    inline fn chatConfig(self: *const Text, prompt: []const u8) request.ChatConfig {
        return .{
            .provider = self.provider,
            .model = self.model_,
            .system = self.system_,
            .prompt = prompt,
            .media = self.media_[0..self.media_count_],
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
            .schema = self.schema_,
            .protocol = self.protocol_,
            .safety_settings = self.safety_settings_,
            .caching = self.caching_,
        };
    }

    /// Build the request body for this configuration. Returns a Value backed by
    /// `arena`. Phase 0/1 do no HTTP send.
    pub fn buildBody(self: Text, arena: std.mem.Allocator, prompt: []const u8) request.BuildError!json.Value {
        return request.buildChatBody(arena, self.chatConfig(prompt));
    }

    /// Build the contract-bearing request headers for this configuration
    /// (Slice F): the provider's required header plus, when a file Part is
    /// referenced, the file-reference `anthropic-beta` (BUG-017). Returns an
    /// arena-backed slice. Pure — no HTTP send, no auth header (needs the key).
    pub fn buildHeaders(self: Text, arena: std.mem.Allocator, prompt: []const u8) ![]request.Header {
        return request.buildRequestHeaders(arena, self.chatConfig(prompt));
    }

    /// Build the BATCH CREATE request body for this configuration (ADR-064 —
    /// batch is a Text execution mode). Each prompt reuses this builder's config
    /// (model/system/media/options) as one `{custom_id:"req-N", params:<body>}`
    /// item; a file-referencing item's `anthropic-beta` value is returned in
    /// `beta_headers` for the CREATE request (BUG-017). Pure — the request-wire
    /// batch goldens assert the payload + the composed header.
    pub fn buildBatchBody(self: Text, arena: std.mem.Allocator, prompts: []const []const u8) !batch_mod.BatchBuildResult {
        return batch_mod.buildBatchBody(arena, self.provider, self.chatConfig(""), prompts);
    }

    /// Build the STREAMING request body for this configuration (Phase 3 slice 2):
    /// the chat body + the stream flag +, when the provider opts in (BUG-028),
    /// `stream_options:{include_usage:true}`. Pure — the request-wire golden
    /// asserts these bytes.
    pub fn buildStreamBody(self: Text, arena: std.mem.Allocator, prompt: []const u8) request.BuildError!json.Value {
        return stream_mod.buildStreamBody(arena, self.chatConfig(prompt));
    }

    /// Stream a ChatCompletion over the injected transport (ADR-013). Sends the
    /// stream request, delivers each text delta to `on_chunk` (may be null), and
    /// returns the accumulated Response. Production passes an `HttpTransport`;
    /// tests inject a `MockTransport`. Mirrors Rust `stream` / Go `promptStream`.
    pub fn streamWith(
        self: Text,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
        on_chunk: ?stream_mod.ChunkCallback,
    ) !@import("response.zig").Response {
        return stream_mod.streamWith(transport, arena, self.chatConfig(prompt), api_key, on_chunk);
    }
};

















