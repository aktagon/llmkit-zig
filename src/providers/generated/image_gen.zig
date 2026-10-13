// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;

pub const ImageModelDef = struct {
    model_id: []const u8,
    label: []const u8,
    aspect_ratios: []const []const u8,
    image_sizes: []const []const u8,
    /// Images llmkit serializes when the wire shape fixes the count
    /// (e.g. Grok's single-seed slot); 0 = no llmkit limit (BUG-011).
    max_input_images: i64,
};

pub const ImageGenDef = struct {
    input_mode: []const u8,
    output_mode: []const u8,
    /// Response wire family selecting the response parser (BUG-024).
    response_shape: []const u8,
    usage_input_path: []const u8,
    usage_output_path: []const u8,
    usage_reasoning_path: []const u8,
    max_input_count: i64,
    gen_endpoint: []const u8,
    edit_endpoint: []const u8,
    models: []const ImageModelDef,
};

pub fn imageGenConfig(provider: ProviderName) ?ImageGenDef {
    return switch (provider) {
        .google => .{
            .input_mode = "InlineParts",
            .output_mode = "Base64Inline",
            .response_shape = "GoogleParts",
            .usage_input_path = "usageMetadata.promptTokenCount",
            .usage_output_path = "usageMetadata.candidatesTokenCount",
            .usage_reasoning_path = "usageMetadata.thoughtsTokenCount",
            .max_input_count = 14,
            .gen_endpoint = "",
            .edit_endpoint = "",
            .models = &.{
                .{
                    .model_id = "gemini-3-pro-image-preview",
                    .label = "Nano Banana Pro",
                    .aspect_ratios = &.{ "16:9", "1:1", "21:9", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16" },
                    .image_sizes = &.{ "1K", "2K", "4K" },
                    .max_input_images = 0,
                },
                .{
                    .model_id = "gemini-3.1-flash-image-preview",
                    .label = "Nano Banana 2",
                    .aspect_ratios = &.{ "16:9", "1:1", "1:4", "1:8", "21:9", "2:3", "3:2", "3:4", "4:1", "4:3", "4:5", "5:4", "8:1", "9:16" },
                    .image_sizes = &.{ "1K", "2K", "4K", "512" },
                    .max_input_images = 0,
                },
            },
        },
        .grok => .{
            .input_mode = "JSONInlineRefs",
            .output_mode = "Base64Inline",
            .response_shape = "DataArrayB64Json",
            .usage_input_path = "",
            .usage_output_path = "",
            .usage_reasoning_path = "",
            .max_input_count = 16,
            .gen_endpoint = "/v1/images/generations",
            .edit_endpoint = "/v1/images/edits",
            .models = &.{
                .{
                    .model_id = "grok-imagine-image-quality",
                    .label = "Grok Imagine Quality",
                    .aspect_ratios = &.{ "16:9", "19.5:9", "1:1", "1:2", "20:9", "2:1", "2:3", "3:2", "3:4", "4:3", "9:16", "9:19.5", "9:20", "auto" },
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
            },
        },
        .openai => .{
            .input_mode = "MultipartForm",
            .output_mode = "Base64Inline",
            .response_shape = "DataArrayB64Json",
            .usage_input_path = "usage.input_tokens",
            .usage_output_path = "usage.output_tokens",
            .usage_reasoning_path = "",
            .max_input_count = 16,
            .gen_endpoint = "/v1/images/generations",
            .edit_endpoint = "/v1/images/edits",
            .models = &.{
                .{
                    .model_id = "gpt-image-1",
                    .label = "GPT Image 1",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "gpt-image-1-mini",
                    .label = "GPT Image 1 Mini",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "gpt-image-1.5",
                    .label = "GPT Image 1.5",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "gpt-image-2",
                    .label = "GPT Image 2",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
            },
        },
        .openrouter => .{
            .input_mode = "JSONGenerations",
            .output_mode = "Base64Inline",
            .response_shape = "DataArrayB64Json",
            .usage_input_path = "usage.prompt_tokens",
            .usage_output_path = "usage.completion_tokens",
            .usage_reasoning_path = "",
            .max_input_count = 0,
            .gen_endpoint = "/v1/images",
            .edit_endpoint = "",
            .models = &.{
                .{
                    .model_id = "google/gemini-2.5-flash-image",
                    .label = "Nano Banana (Gemini 2.5 Flash Image)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "google/gemini-3-pro-image",
                    .label = "Nano Banana Pro (Gemini 3 Pro Image)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "google/gemini-3.1-flash-image",
                    .label = "Nano Banana 2 (Gemini 3.1 Flash Image)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "google/gemini-3.1-flash-lite-image",
                    .label = "Nano Banana 2 Lite (Gemini 3.1 Flash Lite Image)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "openai/gpt-5-image",
                    .label = "GPT-5 Image",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "openai/gpt-5-image-mini",
                    .label = "GPT-5 Image Mini",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "openai/gpt-5.4-image-2",
                    .label = "GPT-5.4 Image 2",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
            },
        },
        .recraft => .{
            .input_mode = "JSONGenerations",
            .output_mode = "Base64Inline",
            .response_shape = "DataArrayB64Json",
            .usage_input_path = "",
            .usage_output_path = "",
            .usage_reasoning_path = "",
            .max_input_count = 0,
            .gen_endpoint = "/v1/images/generations",
            .edit_endpoint = "",
            .models = &.{
                .{
                    .model_id = "recraftv3",
                    .label = "Recraft V3",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "recraftv3_vector",
                    .label = "Recraft V3 (vector / SVG)",
                    .aspect_ratios = &.{},
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
            },
        },
        .vertex => .{
            .input_mode = "JSONPredict",
            .output_mode = "Base64Inline",
            .response_shape = "VertexPredictions",
            .usage_input_path = "",
            .usage_output_path = "",
            .usage_reasoning_path = "",
            .max_input_count = 1,
            .gen_endpoint = "",
            .edit_endpoint = "",
            .models = &.{
                .{
                    .model_id = "imagen-3.0-fast-generate-001",
                    .label = "Imagen 3 Fast",
                    .aspect_ratios = &.{ "16:9", "1:1", "3:4", "4:3", "9:16" },
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "imagen-3.0-generate-002",
                    .label = "Imagen 3",
                    .aspect_ratios = &.{ "16:9", "1:1", "3:4", "4:3", "9:16" },
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "imagen-4.0-generate-preview-06-06",
                    .label = "Imagen 4 Preview",
                    .aspect_ratios = &.{ "16:9", "1:1", "3:4", "4:3", "9:16" },
                    .image_sizes = &.{},
                    .max_input_images = 0,
                },
            },
        },
        else => null,
    };
}
