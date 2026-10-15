//! Speech generation (text-to-speech, ADR-069 Slice 2) — a mirror of
//! rust/src/speech.rs and go/speech.go, minus the HTTP send.
//!
//! Two pure seams the wire goldens assert:
//!   - `Speech.buildSpeechBody` produces the request body per the provider's
//!     generated `wire_shape` fact (SpeechInworld -> the flat `{text, voiceId,
//!     modelId, audioConfig, deliveryMode}` body; SpeechOpenAI -> the flat
//!     `{model, input, voice, response_format}` body) — never a provider-name
//!     switch. Slice 2 sends fixed shape defaults (Inworld LINEAR16/22050 ->
//!     WAV + BALANCED delivery; OpenAI response_format mp3); format/voice-rate
//!     selection is a later slice (ADR-049 OQ-5 / ADR-051).
//!   - `parseSpeechResponse` projects a provider REPLY to a single `AudioData`,
//!     dispatched on the generated `audio_response_encoding` fact
//!     (base64Envelope -> decode the `audioContent` field, Inworld; rawBody ->
//!     the whole body IS the audio bytes, OpenAI). Usage is NOT REPORTED:
//!     Inworld's `processedCharactersCount` is deliberately dropped (ADR-049
//!     OQ-3 — the two TTS providers disagree on a characters axis, so it is not
//!     mapped to a token dimension).
//!
//! Both are backed by a caller-supplied allocator (pass an arena for a whole
//! build/parse and free it in one shot). Runtime concerns (pre-flight
//! validation, HTTP send, middleware) are later slices; this file is the
//! wire-shaped core.

const std = @import("std");
const http = @import("http.zig");
const send = @import("send.zig");
const json = @import("json.zig");
const middleware = @import("middleware.zig");
const providers = @import("providers/generated/providers.zig");
const speech_gen = @import("providers/generated/speech_gen.zig");
const response = @import("response.zig");
const structs = @import("providers/generated/structs.zig");

pub const ProviderName = providers.ProviderName;

/// One decoded audio payload: the provider's output MIME plus RAW bytes (already
/// base64-decoded from the wire for the envelope shape).
pub const AudioData = structs.AudioData;

/// The normalized text-to-speech reply: a single synthesized clip (one
/// synthesis, one clip — ADR-049 OQ-4), the shared token carrier (unreported
/// for speech), and an optional finish reason.
pub const SpeechResponse = structs.SpeechResponse;

pub const BuildError = error{UnsupportedSpeechProvider} || std.mem.Allocator.Error;
pub const ParseError = error{ UnsupportedSpeechProvider, InvalidSpeechResponse } || std.mem.Allocator.Error;

/// The public Speech builder. Immutable value type: each chain method returns a
/// fresh copy, so a forked chain never mutates its parent (the `Text`/`Image`
/// discipline). Only the terminal (`buildSpeechBody`) takes an allocator.
pub const Speech = struct {
    provider: providers.ProviderName,
    ctx: http.Ctx,
    model_: ?[]const u8 = null,
    voice_: ?[]const u8 = null,

    /// The speech-generation model id (ADR-021 bare-noun replacer). Required by
    /// the full runtime; carried in the body for both wire shapes (OpenAI
    /// `model`, Inworld `modelId`).
    pub fn model(self: Speech, m: []const u8) Speech {
        var s = self;
        s.model_ = m;
        return s;
    }

    /// The voice selector (ADR-021 bare-noun replacer; request data, validated
    /// pre-flight against the provider catalogue in the full runtime, SPK-004).
    /// Wire field `voice` (OpenAI) / `voiceId` (Inworld).
    pub fn voice(self: Speech, v: []const u8) Speech {
        var s = self;
        s.voice_ = v;
        return s;
    }

    /// Build the text-to-speech request body as a dynamic JSON Value backed by
    /// `arena`, dispatched on the provider's generated `wire_shape` fact. `text`
    /// is the single utterance to speak (single-turn — no Message/Role wrapper,
    /// SPK-003).
    pub fn buildSpeechBody(self: Speech, arena: std.mem.Allocator, text: []const u8) BuildError!json.Value {
        const cfg = speech_gen.speechGenConfig(self.provider) orelse
            return error.UnsupportedSpeechProvider;

        if (std.mem.eql(u8, cfg.wire_shape, "SpeechOpenAI"))
            return buildOpenAISpeechBody(arena, self, text);
        return buildInworldSpeechBody(arena, self, text);
    }

    /// Synthesize `text` and return the decoded clip. Mirrors Go
    /// `GenerateSpeech` / Rust `generate_speech`.
    pub fn generate(
        self: Speech,
        arena: std.mem.Allocator,
        api_key: []const u8,
        text: []const u8,
    ) !SpeechResponse {
        return send.withTransport(&self.ctx, @TypeOf(self).generateWith, self, .{ arena, api_key, text });
    }

    /// `generate` over an injected transport (the seam tests mock).
    ///
    /// This terminal uses `postRaw`, not `postJson`, even though the REQUEST is
    /// JSON: half the speech providers do not answer in JSON. `parseSpeechResponse`
    /// takes the RAW reply bytes and decides per the generated
    /// `audio_response_encoding` fact whether they are audio (OpenAI `rawBody`)
    /// or a base64 envelope to parse (Inworld). Decoding the reply as JSON here
    /// would fail outright on the `rawBody` shape, so the request is stringified
    /// by hand and the reply is handed on untouched.
    ///
    /// Middleware: the send fires `speech_generation` pre (vetoable) and post
    ///
    /// label — this path used to report `llm_request` for want of a speech
    /// member, misreporting TTS as chat.
    pub fn generateWith(
        self: Speech,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        text: []const u8,
    ) !SpeechResponse {
        const cfg = speech_gen.speechGenConfig(self.provider) orelse
            return error.UnsupportedSpeechProvider;
        const body = try self.buildSpeechBody(arena, text);

        const raw = try send.postRaw(transport, arena, .{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = cfg.gen_endpoint,
            .op = .speech_generation,
            .model = self.model_ orelse "",
        }, try json.stringify(arena, body), "application/json");

        return parseSpeechResponse(arena, self.provider, raw);
    }
};

/// The Inworld `/tts/v1/voice` request body (flat JSON): `{text, voiceId,
/// modelId, audioConfig:{audioEncoding, sampleRateHertz}, deliveryMode}`. Slice
/// 2 fixes audioConfig LINEAR16/22050 (-> WAV) and BALANCED delivery (ADR-049
/// OQ-5). Mirrors Rust `build_inworld_speech_body`.
fn buildInworldSpeechBody(arena: std.mem.Allocator, sp: Speech, text: []const u8) BuildError!json.Value {
    var body = json.object();
    try json.set(arena, &body, "text", .{ .string = text });
    if (sp.voice_) |v| try json.set(arena, &body, "voiceId", .{ .string = v });
    if (sp.model_) |m| try json.set(arena, &body, "modelId", .{ .string = m });

    var audio_config = json.object();
    try json.set(arena, &audio_config, "audioEncoding", .{ .string = "LINEAR16" });
    try json.set(arena, &audio_config, "sampleRateHertz", .{ .integer = 22050 });
    try json.set(arena, &body, "audioConfig", audio_config);

    try json.set(arena, &body, "deliveryMode", .{ .string = "BALANCED" });
    return body;
}

/// The OpenAI `/v1/audio/speech` request body (flat JSON): `{model, input,
/// voice, response_format}`. Slice 2 fixes response_format=mp3 (KISS; the
/// model's output_mime is audio/mpeg to match), so the response body is mp3
/// bytes. Format selection is a later slice. Mirrors Rust
/// `build_openai_speech_body`.
fn buildOpenAISpeechBody(arena: std.mem.Allocator, sp: Speech, text: []const u8) BuildError!json.Value {
    var body = json.object();
    if (sp.model_) |m| try json.set(arena, &body, "model", .{ .string = m });
    try json.set(arena, &body, "input", .{ .string = text });
    if (sp.voice_) |v| try json.set(arena, &body, "voice", .{ .string = v });
    try json.set(arena, &body, "response_format", .{ .string = "mp3" });
    return body;
}

/// Project a provider speech REPLY into the normalized `SpeechResponse`,
/// dispatched on the provider's generated `audio_response_encoding` fact
/// (ADR-051 OAA-002) — never a provider-name switch. `body` is the raw response
/// bytes: "rawBody" (OpenAI) takes them verbatim as the audio; "base64Envelope"
/// (Inworld) parses a JSON envelope and base64-decodes the `audioContent` field.
/// A 2xx body that does not parse to audio is a decoding error (HANDOFF-036 A5),
/// never a silent empty clip. `mimeType` is the provider's output MIME; Usage
/// is left unreported (ADR-049 OQ-3). Mirrors Rust `parse_speech_response`.
pub fn parseSpeechResponse(arena: std.mem.Allocator, provider: ProviderName, body: []const u8) ParseError!SpeechResponse {
    const cfg = speech_gen.speechGenConfig(provider) orelse
        return error.UnsupportedSpeechProvider;
    // The seam has no request context, so it derives the output MIME from the
    // provider's speech config. Every model of a provider shares one output MIME
    // (Inworld audio/wav, OpenAI audio/mpeg), so the first model's is the
    // provider-wide fallback — the value the full runtime threads from the
    // requested model.
    const mime: []const u8 = if (cfg.models.len > 0) cfg.models[0].output_mime else "";

    if (std.mem.eql(u8, cfg.audio_response_encoding, "rawBody")) {
        return .{ .audio = .{ .mime_type = mime, .bytes = try arena.dupe(u8, body) }, .usage = .{}, .finish_reason = null };
    }

    // base64Envelope: {"audioContent": "<base64>", "usage": {...}}.
    const parsed = json.parse(arena, body) catch return error.InvalidSpeechResponse;
    defer parsed.deinit();

    const b64 = getString(parsed.value, "audioContent") orelse return error.InvalidSpeechResponse;
    if (b64.len == 0) return error.InvalidSpeechResponse;
    const decoded = base64Decode(arena, b64) catch return error.InvalidSpeechResponse;
    return .{ .audio = .{ .mime_type = mime, .bytes = decoded }, .usage = .{}, .finish_reason = null };
}

/// Read a string field off an object Value; null when absent or not a string.
fn getString(v: json.Value, key: []const u8) ?[]const u8 {
    if (std.meta.activeTag(v) != .object) return null;
    const got = v.object.get(key) orelse return null;
    return switch (got) {
        .string => |s| s,
        else => null,
    };
}

/// Standard-alphabet, padded base64 decode of `b64` into `arena`.
fn base64Decode(arena: std.mem.Allocator, b64: []const u8) ![]const u8 {
    const dec = std.base64.standard.Decoder;
    const buf = try arena.alloc(u8, try dec.calcSizeForSlice(b64));
    try dec.decode(buf, b64);
    return buf;
}

/// A `Ctx` for the pure-seam tests below. Those tests exercise body/header
/// construction only, so the transport dependencies are never used — but Zig
/// has no ambient allocator or `Io`, so they must still be named.
fn testCtx() http.Ctx {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io };
}























































































































/// A middleware that records every (op, phase) it is called with. Zig has no
/// capturing closures, so the recorder's state rides on `ptr` — the same
/// type-erasure `http.Transport` uses.
const Recorder = struct {
    seen: [8]struct { op: middleware.MiddlewareOp, phase: middleware.MiddlewarePhase } = undefined,
    count: usize = 0,

    fn call(ptr: *anyopaque, ev: *const middleware.Event) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.seen[self.count] = .{ .op = ev.op, .phase = ev.phase };
        self.count += 1;
        return null;
    }

    fn hook(self: *Recorder) middleware.Middleware {
        return .{ .ptr = self, .call_fn = Recorder.call };
    }
};




















































