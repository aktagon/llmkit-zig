// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;

pub const SpeechModelDef = struct {
    model_id: []const u8,
    label: []const u8,
    output_mime: []const u8,
    /// ADR-037 advisory fact (queryable, never gated); 0 when unverified.
    sample_rate_hz: i64,
    /// Speakers a multi-speaker request declares; 0 = one voice only (BUG-091).
    max_speakers: i64,
    /// Whether a style (style, styled lines) is sent to this model (BUG-091).
    supports_speech_style: bool,
};

pub const SpeechGenDef = struct {
    wire_shape: []const u8,
    /// audio_response_encoding: "base64Envelope" | "rawBody" | "base64InteractionSteps" | "hexEnvelope" (ADR-051).
    audio_response_encoding: []const u8,
    gen_endpoint: []const u8,
    models: []const SpeechModelDef,
    /// Speech API base when it differs from the chat base; "" = use chat base.
    base_url: []const u8,
};

pub fn speechGenConfig(provider: ProviderName) ?SpeechGenDef {
    return switch (provider) {
        .google => .{
            .wire_shape = "SpeechGemini",
            .audio_response_encoding = "base64InteractionSteps",
            .gen_endpoint = "/v1beta/interactions",
            .models = &.{
                .{
                    .model_id = "gemini-3.8-flash-lite-tts",
                    .label = "Gemini 3.8 Flash-Lite TTS",
                    .output_mime = "audio/wav",
                    .sample_rate_hz = 24000,
                    .max_speakers = 2,
                    .supports_speech_style = true,
                },
                .{
                    .model_id = "gemini-3.8-flash-tts",
                    .label = "Gemini 3.8 Flash TTS",
                    .output_mime = "audio/wav",
                    .sample_rate_hz = 24000,
                    .max_speakers = 2,
                    .supports_speech_style = true,
                },
            },
            .base_url = "",
        },
        .inworld => .{
            .wire_shape = "SpeechInworld",
            .audio_response_encoding = "base64Envelope",
            .gen_endpoint = "/tts/v1/voice",
            .models = &.{
                .{
                    .model_id = "inworld-tts-1.5-max",
                    .label = "Inworld TTS 1.5 Max",
                    .output_mime = "audio/wav",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "inworld-tts-1.5-mini",
                    .label = "Inworld TTS 1.5 Mini",
                    .output_mime = "audio/wav",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "inworld-tts-2",
                    .label = "Inworld TTS 2",
                    .output_mime = "audio/wav",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
            },
            .base_url = "",
        },
        .minimax => .{
            .wire_shape = "SpeechMiniMax",
            .audio_response_encoding = "hexEnvelope",
            .gen_endpoint = "/v1/t2a_v2",
            .models = &.{
                .{
                    .model_id = "speech-2.6-hd",
                    .label = "MiniMax Speech 2.6 HD",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "speech-2.6-turbo",
                    .label = "MiniMax Speech 2.6 Turbo",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "speech-2.8-hd",
                    .label = "MiniMax Speech 2.8 HD",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "speech-2.8-turbo",
                    .label = "MiniMax Speech 2.8 Turbo",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
            },
            .base_url = "https://api.minimax.io",
        },
        .openai => .{
            .wire_shape = "SpeechOpenAI",
            .audio_response_encoding = "rawBody",
            .gen_endpoint = "/v1/audio/speech",
            .models = &.{
                .{
                    .model_id = "gpt-4o-mini-tts",
                    .label = "GPT-4o mini TTS",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = true,
                },
                .{
                    .model_id = "tts-1",
                    .label = "TTS 1",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "tts-1-hd",
                    .label = "TTS 1 HD",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
            },
            .base_url = "",
        },
        .openrouter => .{
            .wire_shape = "SpeechOpenAI",
            .audio_response_encoding = "rawBody",
            .gen_endpoint = "/v1/audio/speech",
            .models = &.{
                .{
                    .model_id = "elevenlabs/eleven-v3",
                    .label = "Eleven v3",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "elevenlabs/eleven-v4",
                    .label = "Eleven v4",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "elevenlabs/eleven-v4-turbo",
                    .label = "Eleven v4 Turbo",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "fish-audio/drama-3",
                    .label = "Fish Audio Drama 3",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "fish-audio/s2.1-pro",
                    .label = "Fish Audio S2.1 Pro",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "google/gemini-3.1-flash-tts-preview",
                    .label = "Gemini 3.1 Flash TTS Preview",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "google/gemini-3.8-flash-lite-tts",
                    .label = "Gemini 3.8 Flash Lite TTS",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "google/gemini-3.8-flash-tts",
                    .label = "Gemini 3.8 Flash TTS",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "hexgrad/kokoro-82m",
                    .label = "Kokoro 82M",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
                .{
                    .model_id = "x-ai/grok-voice-tts-1.0",
                    .label = "Grok Voice TTS 1.0",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .max_speakers = 0,
                    .supports_speech_style = false,
                },
            },
            .base_url = "",
        },
        else => null,
    };
}
