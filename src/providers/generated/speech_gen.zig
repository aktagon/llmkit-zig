// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;

pub const SpeechModelDef = struct {
    model_id: []const u8,
    label: []const u8,
    output_mime: []const u8,
    /// ADR-037 advisory fact (queryable, never gated); 0 when unverified.
    sample_rate_hz: i64,
};

pub const SpeechGenDef = struct {
    wire_shape: []const u8,
    /// audio_response_encoding: "base64Envelope" | "rawBody" (ADR-051).
    audio_response_encoding: []const u8,
    gen_endpoint: []const u8,
    voices: []const []const u8,
    models: []const SpeechModelDef,
};

pub fn speechGenConfig(provider: ProviderName) ?SpeechGenDef {
    return switch (provider) {
        .inworld => .{
            .wire_shape = "SpeechInworld",
            .audio_response_encoding = "base64Envelope",
            .gen_endpoint = "/tts/v1/voice",
            .voices = &.{ "Alex", "Ashley", "Dennis" },
            .models = &.{
                .{
                    .model_id = "inworld-tts-1.5-max",
                    .label = "Inworld TTS 1.5 Max",
                    .output_mime = "audio/wav",
                    .sample_rate_hz = 0,
                },
                .{
                    .model_id = "inworld-tts-1.5-mini",
                    .label = "Inworld TTS 1.5 Mini",
                    .output_mime = "audio/wav",
                    .sample_rate_hz = 0,
                },
                .{
                    .model_id = "inworld-tts-2",
                    .label = "Inworld TTS 2",
                    .output_mime = "audio/wav",
                    .sample_rate_hz = 0,
                },
            },
        },
        .openai => .{
            .wire_shape = "SpeechOpenAI",
            .audio_response_encoding = "rawBody",
            .gen_endpoint = "/v1/audio/speech",
            .voices = &.{ "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer" },
            .models = &.{
                .{
                    .model_id = "gpt-4o-mini-tts",
                    .label = "GPT-4o mini TTS",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                },
                .{
                    .model_id = "tts-1",
                    .label = "TTS 1",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                },
                .{
                    .model_id = "tts-1-hd",
                    .label = "TTS 1 HD",
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                },
            },
        },
        else => null,
    };
}
