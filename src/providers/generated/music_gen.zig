// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;

pub const MusicModelDef = struct {
    model_id: []const u8,
    label: []const u8,
    supports_lyrics: bool,
    max_duration_seconds: i64,
    output_mime: []const u8,
    /// ADR-037 advisory facts (queryable, never gated); 0 when unverified.
    sample_rate_hz: i64,
    available_output_formats: []const []const u8,
    /// Whether llmkit sends Image Parts for this model.
    supports_image_input: bool,
};

pub const MusicGenDef = struct {
    wire_shape: []const u8,
    gen_endpoint: []const u8,
    base_url: []const u8,
    models: []const MusicModelDef,
};

pub fn musicGenConfig(provider: ProviderName) ?MusicGenDef {
    return switch (provider) {
        .google => .{
            .wire_shape = "MusicGenerateContent",
            .gen_endpoint = "",
            .base_url = "",
            .models = &.{
                .{
                    .model_id = "lyria-3-clip-preview",
                    .label = "Lyria 3 Clip",
                    .supports_lyrics = true,
                    .max_duration_seconds = 30,
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .available_output_formats = &.{ "audio/mpeg" },
                    .supports_image_input = false,
                },
                .{
                    .model_id = "lyria-3-pro-preview",
                    .label = "Lyria 3 Pro",
                    .supports_lyrics = true,
                    .max_duration_seconds = 120,
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .available_output_formats = &.{ "audio/mpeg" },
                    .supports_image_input = false,
                },
                .{
                    .model_id = "lyria-3.5",
                    .label = "Lyria 3.5",
                    .supports_lyrics = true,
                    .max_duration_seconds = 0,
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 0,
                    .available_output_formats = &.{ "audio/mpeg" },
                    .supports_image_input = false,
                },
            },
        },
        .minimax => .{
            .wire_shape = "MusicMinimax",
            .gen_endpoint = "/v1/music_generation",
            .base_url = "https://api.minimax.io",
            .models = &.{
                .{
                    .model_id = "music-2.6",
                    .label = "MiniMax Music 2.6",
                    .supports_lyrics = true,
                    .max_duration_seconds = 0,
                    .output_mime = "audio/mpeg",
                    .sample_rate_hz = 44100,
                    .available_output_formats = &.{ "audio/mpeg", "audio/wav" },
                    .supports_image_input = false,
                },
            },
        },
        .vertex => .{
            .wire_shape = "MusicPredict",
            .gen_endpoint = "",
            .base_url = "",
            .models = &.{
                .{
                    .model_id = "lyria-002",
                    .label = "Lyria 2",
                    .supports_lyrics = false,
                    .max_duration_seconds = 30,
                    .output_mime = "audio/wav",
                    .sample_rate_hz = 48000,
                    .available_output_formats = &.{ "audio/wav" },
                    .supports_image_input = false,
                },
            },
        },
        else => null,
    };
}
