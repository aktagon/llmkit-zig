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
//!     the whole body IS the audio bytes, OpenAI). Usage stays ALL ZERO:
//!     Inworld's `processedCharactersCount` is deliberately dropped (ADR-049
//!     OQ-3 — the two TTS providers disagree on a characters axis, so it is not
//!     mapped to a token dimension).
//!
//! Both are backed by a caller-supplied allocator (pass an arena for a whole
//! build/parse and free it in one shot). Runtime concerns (pre-flight
//! validation, HTTP send, middleware) are later slices; this file is the
//! wire-shaped core.

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const speech_gen = @import("providers/generated/speech_gen.zig");
const response = @import("response.zig");

pub const ProviderName = providers.ProviderName;

/// One decoded audio payload: the provider's output MIME plus RAW bytes (already
/// base64-decoded from the wire for the envelope shape). Distinct from the text
/// path's media Part so capability-specific return semantics stay typed. Mirrors
/// Rust/Go `AudioData` (ADR-018 bytes/mime accessor). Declared here — as
/// `image.zig` declares its own `ImageData` — rather than consumed from the
/// generated `structs.zig`, which is not yet wired into the module graph.
pub const AudioData = struct {
    mime_type: []const u8,
    bytes: []const u8,
};

/// The normalized text-to-speech reply: a single synthesized clip (one
/// synthesis, one clip — ADR-049 OQ-4), the shared token carrier (stays zero
/// for speech), and an optional finish reason. Mirror of Rust `SpeechResponse`.
pub const SpeechResponse = struct {
    audio: AudioData,
    usage: response.Usage = .{},
    finish_reason: []const u8 = "",
};

pub const BuildError = error{UnsupportedSpeechProvider} || std.mem.Allocator.Error;
pub const ParseError = error{ UnsupportedSpeechProvider, InvalidSpeechResponse } || std.mem.Allocator.Error;

/// The public Speech builder. Immutable value type: each chain method returns a
/// fresh copy, so a forked chain never mutates its parent (the `Text`/`Image`
/// discipline). Only the terminal (`buildSpeechBody`) takes an allocator.
pub const Speech = struct {
    provider: providers.ProviderName,
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
/// stays zero (ADR-049 OQ-3). Mirrors Rust `parse_speech_response`.
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
        return .{ .audio = .{ .mime_type = mime, .bytes = try arena.dupe(u8, body) } };
    }

    // base64Envelope: {"audioContent": "<base64>", "usage": {...}}.
    const parsed = json.parse(arena, body) catch return error.InvalidSpeechResponse;
    defer parsed.deinit();

    const b64 = getString(parsed.value, "audioContent") orelse return error.InvalidSpeechResponse;
    if (b64.len == 0) return error.InvalidSpeechResponse;
    const decoded = base64Decode(arena, b64) catch return error.InvalidSpeechResponse;
    return .{ .audio = .{ .mime_type = mime, .bytes = decoded } };
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






























































