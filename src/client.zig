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
const models_mod = @import("models.zig");
const music_mod = @import("music.zig");
const upload_mod = @import("upload.zig");
const response_mod = @import("response.zig");
const send = @import("send.zig");
const capability = @import("capability.zig");
const middleware = @import("middleware.zig");

pub const ProviderName = providers.ProviderName;

/// Chat-protocol selector (ADR-055), re-exported from `request.zig`.
pub const Protocol = request.Protocol;

/// Google safety setting `{category, threshold}`, re-exported from `request.zig`.
pub const SafetySetting = request.SafetySetting;

pub const Client = struct {
    provider: ProviderName,
    ctx: http.Ctx,

    /// Construct a client. `gpa` and `io` are the TRANSPORT dependencies —
    /// long-lived, so they live on the client (HANDOFF-046 DECISION 1a), while
    /// per-request memory stays an `arena` the caller passes to each terminal.
    /// Zig has no ambient allocator or event loop, so these must be explicit
    /// somewhere; the client is the honest place, and it keeps the terminal
    /// surface (`prompt(arena, api_key, text)`) aligned with the other six SDKs.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, provider: ProviderName) Client {
        return .{ .provider = provider, .ctx = .{ .gpa = gpa, .io = io } };
    }

    /// Override the provider base URL (e.g. an OpenAI-compat gateway).
    pub fn baseURL(self: Client, url: []const u8) Client {
        var c = self;
        c.ctx.base_url = url;
        return c;
    }

    /// Add a custom header sent with every request (ADR-052 parity with the
    /// other six SDKs' `AddHeader`/`addHeader`/`add_header`). Applied by
    /// `http.composeHeaders` at each send terminal, where a name that would
    /// collide with the credential or a contract header is skipped.
    pub fn addHeader(self: Client, name: []const u8, value: []const u8) Client {
        var c = self;
        c.ctx = c.ctx.withHeader(name, value);
        return c;
    }

    /// Attach an observation + veto hook fired around every operation this
    /// client performs (ADR-020). Calls accumulate. The hook's `ptr` is
    /// borrowed, so it must outlive the client.
    pub fn addMiddleware(self: Client, m: middleware.Middleware) Client {
        var c = self;
        c.ctx = c.ctx.withMiddleware(m);
        return c;
    }

    /// Whether this client's provider supports `cap` (ADR-030). Reads the same
    /// generated capability facts the strict validation paths use (CAP-002) —
    /// never a provider-name switch. No I/O.
    pub fn supports(self: Client, cap: capability.Capability) bool {
        return capability.providerSupports(self.provider, cap);
    }

    /// Enter the ChatCompletion (text) builder.
    pub fn text(self: Client) Text {
        return .{ .provider = self.provider, .ctx = self.ctx };
    }

    /// Enter the Agent (tool-using ChatCompletion) builder.
    pub fn agent(self: Client) agent_mod.Agent {
        return .{ .provider = self.provider, .ctx = self.ctx };
    }

    /// Enter the ImageGeneration builder (single-turn: text-to-image + edit).
    pub fn image(self: Client) image_mod.Image {
        return .{ .provider = self.provider, .ctx = self.ctx };
    }

    /// Enter the MusicGeneration builder (single-turn prompt + optional lyrics).
    pub fn music(self: Client) music_mod.Music {
        return .{ .provider = self.provider, .ctx = self.ctx };
    }

    /// Enter the SpeechGeneration builder (single-turn text-to-speech).
    pub fn speech(self: Client) speech_mod.Speech {
        return .{ .provider = self.provider, .ctx = self.ctx };
    }

    /// Enter the Transcription builder (single-turn speech-to-text). JSON
    /// (AssemblyAI async submit) vs multipart (OpenAI sync) is picked by the
    /// terminal per the provider's generated `request_encoding` fact.
    pub fn transcription(self: Client) transcription_mod.Transcription {
        return .{ .provider = self.provider, .ctx = self.ctx };
    }

    /// Enter the VideoGeneration builder (single-turn text-to-video, with an
    /// optional image-to-video seed frame). `submit` returns a `VideoHandle`;
    /// the poll/wait runtime is deferred to ADR-062 slice 2 (see CHANGELOG).
    pub fn video(self: Client) video_mod.Video {
        return .{ .provider = self.provider, .ctx = self.ctx };
    }

    /// Enter the Files API builder (ADR-060). `run` uploads bytes and returns
    /// the provider file id to attach to a later request via `Text.file(id)`.
    pub fn upload(self: Client) upload_mod.Upload {
        return .{ .provider = self.provider, .ctx = self.ctx };
    }

    /// Enter the model-catalogue builder (ADR-019). `list`/`get` walk the
    /// compiled-in catalogue; `provider(p)` scopes to one provider's live
    /// `/models` request-assembly seam. Carries the client's base-URL override.
    pub fn models(self: Client) models_mod.Models {
        return .{ .base_url = self.ctx.base_url };
    }

    /// Enter the providers-namespace builder (ADR-019). `list()` returns the
    /// configured providers that expose a live `/models` endpoint, as
    /// secret-free `ProviderInfo`.
    pub fn providers(self: Client) models_mod.Providers {
        return .{ .provider = self.provider };
    }
};

/// Fixed capacity for `Text.image`/`Text.file` media Parts. Text chain methods
/// take no allocator (ADR-069 ZIG-005), so media Parts live in a bounded array
/// like `Client.addHeader`. 8 is generous over any single-turn multimodal use.
const max_media_parts = 8;

pub const Text = struct {
    provider: providers.ProviderName,
    ctx: http.Ctx,
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
    inline fn chatConfig(self: *const Text, text_prompt: []const u8) request.ChatConfig {
        return .{
            .provider = self.provider,
            .model = self.model_,
            .system = self.system_,
            .prompt = text_prompt,
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
    pub fn buildBody(self: Text, arena: std.mem.Allocator, text_prompt: []const u8) request.BuildError!json.Value {
        return request.buildChatBody(arena, self.chatConfig(text_prompt));
    }

    /// Build the contract-bearing request headers for this configuration
    /// (Slice F): the provider's required header plus, when a file Part is
    /// referenced, the file-reference `anthropic-beta` (BUG-017). Returns an
    /// arena-backed slice. Pure — no HTTP send, no auth header (needs the key).
    pub fn buildHeaders(self: Text, arena: std.mem.Allocator, text_prompt: []const u8) ![]request.Header {
        return request.buildRequestHeaders(arena, self.chatConfig(text_prompt));
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
    pub fn buildStreamBody(self: Text, arena: std.mem.Allocator, text_prompt: []const u8) request.BuildError!json.Value {
        return stream_mod.buildStreamBody(arena, self.chatConfig(text_prompt));
    }

    // === Terminals (HANDOFF-046 slice 1) ===
    //
    // Each terminal is COMPOSITION over the seams above — build the body, send
    // it, parse the reply — never a second implementation of either half. That
    // is what keeps the request/response wire goldens authoritative: they assert
    // `buildBody` and `parse*Response`, so a terminal that reuses both cannot
    // drift from the bytes seven SDKs agree on.
    //
    // Every terminal comes in two forms: the public one, which builds an
    // `HttpTransport` from the client's `gpa`/`io`, and a `*With` variant taking
    // an explicit `http.Transport` so tests inject a `MockTransport` and drive
    // the real terminal without a socket.

    /// Send a ChatCompletion and return the normalized Response. `arena` backs
    /// the request body and everything reachable from the result — free it in
    /// one shot when done. Mirrors Go `Prompt` / Rust `prompt`.
    pub fn prompt(
        self: Text,
        arena: std.mem.Allocator,
        api_key: []const u8,
        text_prompt: []const u8,
    ) !response_mod.Response {
        var t = http.HttpTransport.init(self.ctx.gpa, self.ctx.io);
        return self.promptWith(self.ctx.transport orelse t.transport(), arena, api_key, text_prompt);
    }

    /// `prompt` over an injected transport (the seam tests mock).
    pub fn promptWith(
        self: Text,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        text_prompt: []const u8,
    ) !response_mod.Response {
        const cfg = self.chatConfig(text_prompt);
        const raw = try send.postJson(transport, arena, .{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = providers.spec(self.provider).endpoint,
            .extra_headers = try request.buildRequestHeaders(arena, cfg),
            .op = .llm_request,
            .model = self.model_ orelse "",
        }, try request.buildChatBody(arena, cfg));
        // The EFFECTIVE wire shape — the same one buildChatBody resolved — so a
        // `.protocol(.responses)` reply is decoded with the Responses envelope
        // and not, silently, with the Chat Completions paths (ADR-076 SYM-003).
        const shape = try request.resolveWireShape(providers.spec(self.provider), cfg.protocol);
        return response_mod.decodeResponse(arena, self.provider, shape, raw);
    }

    /// Stream a ChatCompletion, delivering each text delta to `on_chunk` (may be
    /// null) and returning the accumulated Response. Mirrors Go `PromptStream` /
    /// Rust `prompt_stream`.
    pub fn stream(
        self: Text,
        arena: std.mem.Allocator,
        api_key: []const u8,
        text_prompt: []const u8,
        on_chunk: ?stream_mod.ChunkCallback,
    ) !response_mod.Response {
        var t = http.HttpTransport.init(self.ctx.gpa, self.ctx.io);
        return self.streamWith(self.ctx.transport orelse t.transport(), arena, api_key, text_prompt, on_chunk);
    }

    /// `stream` over an injected transport (ADR-013). Production passes an
    /// `HttpTransport`; tests inject a `MockTransport`.
    pub fn streamWith(
        self: Text,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        text_prompt: []const u8,
        on_chunk: ?stream_mod.ChunkCallback,
    ) !response_mod.Response {
        return stream_mod.streamWith(transport, arena, &self.ctx, self.chatConfig(text_prompt), api_key, on_chunk);
    }

    /// Submit a batch of prompts as one job and return the handle immediately
    /// (ADR-064: batch is a Text EXECUTION MODE, parallel to stream — not a
    /// builder of its own). Poll it with `handle.poll`, or block with
    /// `handle.wait`. Mirrors Go/Rust `Text.batch`.
    pub fn batch(
        self: Text,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompts: []const []const u8,
    ) !batch_mod.BatchHandle {
        var t = http.HttpTransport.init(self.ctx.gpa, self.ctx.io);
        return self.batchWith(self.ctx.transport orelse t.transport(), arena, api_key, prompts);
    }

    /// `batch` over an injected transport (the seam the lifecycle-wire driver
    /// already mocks for the poll half).
    pub fn batchWith(
        self: Text,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompts: []const []const u8,
    ) !batch_mod.BatchHandle {
        const built = try batch_mod.buildBatchBody(arena, self.provider, self.chatConfig(""), prompts);
        return batch_mod.submitWith(transport, arena, &self.ctx, self.provider, api_key, built);
    }
};


















// === Public-terminal tests ===
//
// These drive the PUBLIC terminals (`prompt`, `batch`, …), not the `*With`
// variants, by putting a `MockTransport` on the client's `Ctx`. Before that
// override existed the public surface was untestable without a socket — so the
// functions users actually call were the ones nothing exercised.

/// Records every event a client fires, and can veto one op.
const TestHook = struct {
    ops: std.ArrayList(middleware.MiddlewareOp) = .empty,
    gpa: std.mem.Allocator,
    veto: ?middleware.MiddlewareOp = null,

    fn call(ptr: *anyopaque, ev: *const middleware.Event) ?[]const u8 {
        const self: *TestHook = @ptrCast(@alignCast(ptr));
        self.ops.append(self.gpa, ev.op) catch {};
        if (self.veto) |op| if (op == ev.op and ev.phase == .pre) return "vetoed in test";
        return null;
    }

    fn hook(self: *TestHook) middleware.Middleware {
        return .{ .ptr = self, .call_fn = call };
    }
};






















































































































