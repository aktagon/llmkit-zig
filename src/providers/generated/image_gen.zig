// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;

/// Carried input: a request variant that carries text only (ADR-096).
pub const text_only = "TextOnly";
/// Carried input: a request variant that carries reference images (ADR-096).
pub const with_reference_images = "WithReferenceImages";
/// Carried input: a video request variant that carries a seed frame (ADR-096).
pub const with_seed_frame = "WithSeedFrame";

// Image request shapes: each names one request body (ADR-096).
pub const inline_parts = "InlineParts";
pub const json_generations_openai = "JSONGenerationsOpenAI";
pub const multipart_form = "MultipartForm";
pub const json_inline_refs = "JSONInlineRefs";
/// Deprecated: no provider accepts this since 2026-10-15 (Vertex Imagen shut down, BUG-101); removed at the next major.
pub const json_predict = "JSONPredict";
pub const json_generations = "JSONGenerations";

/// One wire request of an image or video config, keyed by the inputs it
/// carries (ADR-096). `shape` is empty on a video variant; an empty
/// `endpoint` means the provider's main endpoint template.
pub const RequestVariant = struct {
    carries: []const u8,
    shape: []const u8,
    endpoint: []const u8,
};

pub const ImageModelDef = struct {
    model_id: []const u8,
    label: []const u8,
    aspect_ratios: []const []const u8,
    image_sizes: []const []const u8,
    /// Images llmkit serializes when the wire shape fixes the count
    /// (e.g. Grok's single-seed slot); 0 = no llmkit limit (BUG-011).
    max_input_images: i64,
    /// Whether llmkit sends Image Parts for this model; false means the
    /// runtime rejects them (BUG-096).
    supports_image_input: bool,
};

pub const ImageGenDef = struct {
    output_mode: []const u8,
    /// Response wire family selecting the response parser (BUG-024).
    response_shape: []const u8,
    usage_input_path: []const u8,
    usage_output_path: []const u8,
    usage_reasoning_path: []const u8,
    /// One request per carried input, TextOnly first (ADR-096).
    variants: []const RequestVariant,
    models: []const ImageModelDef,
};

pub fn imageGenConfig(provider: ProviderName) ?ImageGenDef {
    return switch (provider) {
        .google => .{
            .output_mode = "Base64Inline",
            .response_shape = "GoogleParts",
            .usage_input_path = "usageMetadata.promptTokenCount",
            .usage_output_path = "usageMetadata.candidatesTokenCount",
            .usage_reasoning_path = "usageMetadata.thoughtsTokenCount",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "InlineParts", .endpoint = "" },
                .{ .carries = "WithReferenceImages", .shape = "InlineParts", .endpoint = "" },
            },
            .models = &.{
                .{
                    .model_id = "gemini-3-pro-image-preview",
                    .label = "Nano Banana Pro",
                    .aspect_ratios = &.{ "16:9", "1:1", "21:9", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16" },
                    .image_sizes = &.{ "1K", "2K", "4K" },
                    .max_input_images = 0,
                    .supports_image_input = true,
                },
                .{
                    .model_id = "gemini-3.1-flash-image-preview",
                    .label = "Nano Banana 2",
                    .aspect_ratios = &.{ "16:9", "1:1", "1:4", "1:8", "21:9", "2:3", "3:2", "3:4", "4:1", "4:3", "4:5", "5:4", "8:1", "9:16" },
                    .image_sizes = &.{ "1K", "2K", "4K", "512" },
                    .max_input_images = 0,
                    .supports_image_input = true,
                },
            },
        },
        .grok => .{
            .output_mode = "Base64Inline",
            .response_shape = "DataArrayB64Json",
            .usage_input_path = "",
            .usage_output_path = "",
            .usage_reasoning_path = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "JSONInlineRefs", .endpoint = "/v1/images/generations" },
                .{ .carries = "WithReferenceImages", .shape = "JSONInlineRefs", .endpoint = "/v1/images/edits" },
            },
            .models = &.{
                .{
                    .model_id = "grok-imagine-image-quality",
                    .label = "Grok Imagine Quality",
                    .aspect_ratios = &.{ "16:9", "19.5:9", "1:1", "1:2", "20:9", "2:1", "2:3", "3:2", "3:4", "4:3", "9:16", "9:19.5", "9:20", "auto" },
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = true,
                },
            },
        },
        .openai => .{
            .output_mode = "Base64Inline",
            .response_shape = "DataArrayB64Json",
            .usage_input_path = "usage.input_tokens",
            .usage_output_path = "usage.output_tokens",
            .usage_reasoning_path = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "JSONGenerationsOpenAI", .endpoint = "/v1/images/generations" },
                .{ .carries = "WithReferenceImages", .shape = "MultipartForm", .endpoint = "/v1/images/edits" },
            },
            .models = &.{
                .{
                    .model_id = "gpt-image-1",
                    .label = "GPT Image 1",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = true,
                },
                .{
                    .model_id = "gpt-image-1-mini",
                    .label = "GPT Image 1 Mini",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = true,
                },
                .{
                    .model_id = "gpt-image-1.5",
                    .label = "GPT Image 1.5",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = true,
                },
                .{
                    .model_id = "gpt-image-2",
                    .label = "GPT Image 2",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = true,
                },
            },
        },
        .openrouter => .{
            .output_mode = "Base64Inline",
            .response_shape = "DataArrayB64Json",
            .usage_input_path = "usage.prompt_tokens",
            .usage_output_path = "usage.completion_tokens",
            .usage_reasoning_path = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "JSONGenerations", .endpoint = "/v1/images" },
            },
            .models = &.{
                .{
                    .model_id = "google/gemini-2.5-flash-image",
                    .label = "Nano Banana (Gemini 2.5 Flash Image)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = false,
                },
                .{
                    .model_id = "google/gemini-3-pro-image",
                    .label = "Nano Banana Pro (Gemini 3 Pro Image)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = false,
                },
                .{
                    .model_id = "google/gemini-3.1-flash-image",
                    .label = "Nano Banana 2 (Gemini 3.1 Flash Image)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = false,
                },
                .{
                    .model_id = "google/gemini-3.1-flash-lite-image",
                    .label = "Nano Banana 2 Lite (Gemini 3.1 Flash Lite Image)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = false,
                },
                .{
                    .model_id = "openai/gpt-5-image",
                    .label = "GPT-5 Image",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = false,
                },
                .{
                    .model_id = "openai/gpt-5-image-mini",
                    .label = "GPT-5 Image Mini",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = false,
                },
                .{
                    .model_id = "openai/gpt-5.4-image-2",
                    .label = "GPT-5.4 Image 2",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = false,
                },
            },
        },
        .recraft => .{
            .output_mode = "Base64Inline",
            .response_shape = "DataArrayB64Json",
            .usage_input_path = "",
            .usage_output_path = "",
            .usage_reasoning_path = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "JSONGenerations", .endpoint = "/v1/images/generations" },
            },
            .models = &.{
                .{
                    .model_id = "recraftv3",
                    .label = "Recraft V3",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = false,
                },
                .{
                    .model_id = "recraftv3_vector",
                    .label = "Recraft V3 (vector / SVG)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                    .supports_image_input = false,
                },
            },
        },
        else => null,
    };
}
