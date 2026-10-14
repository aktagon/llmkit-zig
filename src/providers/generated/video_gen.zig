// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;
const RequestVariant = @import("image_gen.zig").RequestVariant;

pub const VideoModelDef = struct {
    model_id: []const u8,
    label: []const u8,
    supports_image_to_video: bool,
    max_duration_seconds: i64,
    output_mime: []const u8,
    resolutions: []const []const u8,
    /// 0 = no llmkit limit, the provider decides volume (BUG-011).
    max_input_images: i64,
};

pub const VideoGenDef = struct {
    wire_shape: []const u8,
    /// One of download | url | output-uri.
    output_delivery: []const u8,
    /// Video API base when it differs from the chat base; "" = use chat base.
    video_base_url: []const u8,
    /// Submit requests per carried input, TextOnly first; each endpoint is
    /// relative to the resolved video base (ADR-096).
    variants: []const RequestVariant,
    /// Poll template with an {id} placeholder.
    poll_endpoint: []const u8,
    /// File-retrieve template with {file_id} for two-hop providers; "" = single-hop.
    file_endpoint: []const u8,
    submit_handle_field: []const u8,
    requires_output_uri: bool,
    models: []const VideoModelDef,
};

pub fn videoGenConfig(provider: ProviderName) ?VideoGenDef {
    return switch (provider) {
        .bedrock => .{
            .wire_shape = "VideoBedrock",
            .output_delivery = "DeliveryOutputURI",
            .video_base_url = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/async-invoke" },
            },
            .poll_endpoint = "/async-invoke/{id}",
            .file_endpoint = "",
            .submit_handle_field = "invocationArn",
            .requires_output_uri = true,
            .models = &.{
                .{
                    .model_id = "amazon.nova-reel-v1:0",
                    .label = "Nova Reel",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 6,
                    .output_mime = "video/mp4",
                    .resolutions = &.{ "720p" },
                    .max_input_images = 0,
                },
            },
        },
        .google => .{
            .wire_shape = "VideoVeo",
            .output_delivery = "DeliveryDownload",
            .video_base_url = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/v1beta/models/{model}:predictLongRunning" },
            },
            .poll_endpoint = "/v1beta/{id}",
            .file_endpoint = "",
            .submit_handle_field = "name",
            .requires_output_uri = false,
            .models = &.{
                .{
                    .model_id = "veo-3.1-generate-preview",
                    .label = "Veo 3.1",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 8,
                    .output_mime = "video/mp4",
                    .resolutions = &.{ "1080p", "720p" },
                    .max_input_images = 0,
                },
            },
        },
        .grok => .{
            .wire_shape = "VideoGrok",
            .output_delivery = "DeliveryURL",
            .video_base_url = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/v1/videos/generations" },
                .{ .carries = "WithReferenceImages", .shape = "", .endpoint = "/v1/videos/generations" },
            },
            .poll_endpoint = "/v1/videos/{id}",
            .file_endpoint = "",
            .submit_handle_field = "request_id",
            .requires_output_uri = false,
            .models = &.{
                .{
                    .model_id = "grok-imagine-video",
                    .label = "Grok Imagine Video",
                    .supports_image_to_video = true,
                    .max_duration_seconds = 15,
                    .output_mime = "video/mp4",
                    .resolutions = &.{ "480p", "720p" },
                    .max_input_images = 1,
                },
            },
        },
        .minimax => .{
            .wire_shape = "VideoMinimax",
            .output_delivery = "DeliveryURL",
            .video_base_url = "https://api.minimax.io",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/v1/video_generation" },
            },
            .poll_endpoint = "/v1/query/video_generation?task_id={id}",
            .file_endpoint = "/v1/files/retrieve?file_id={file_id}",
            .submit_handle_field = "task_id",
            .requires_output_uri = false,
            .models = &.{
                .{
                    .model_id = "MiniMax-Hailuo-2.3",
                    .label = "MiniMax Hailuo 2.3",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 6,
                    .output_mime = "video/mp4",
                    .resolutions = &.{ "1080p", "768p" },
                    .max_input_images = 0,
                },
            },
        },
        .pixverse => .{
            .wire_shape = "VideoPixVerse",
            .output_delivery = "DeliveryURL",
            .video_base_url = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/openapi/v2/video/text/generate" },
            },
            .poll_endpoint = "/openapi/v2/video/result/{id}",
            .file_endpoint = "",
            .submit_handle_field = "Resp.video_id",
            .requires_output_uri = false,
            .models = &.{
                .{
                    .model_id = "v4.5",
                    .label = "PixVerse v4.5",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 8,
                    .output_mime = "video/mp4",
                    .resolutions = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "v5",
                    .label = "PixVerse v5",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 8,
                    .output_mime = "video/mp4",
                    .resolutions = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "v6",
                    .label = "PixVerse v6",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 15,
                    .output_mime = "video/mp4",
                    .resolutions = &.{},
                    .max_input_images = 0,
                },
            },
        },
        .qwen => .{
            .wire_shape = "VideoQwen",
            .output_delivery = "DeliveryURL",
            .video_base_url = "https://dashscope-intl.aliyuncs.com",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/api/v1/services/aigc/video-generation/video-synthesis" },
            },
            .poll_endpoint = "/api/v1/tasks/{id}",
            .file_endpoint = "",
            .submit_handle_field = "output.task_id",
            .requires_output_uri = false,
            .models = &.{
                .{
                    .model_id = "wan2.2-t2v-plus",
                    .label = "Wan 2.2 T2V Plus",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 5,
                    .output_mime = "video/mp4",
                    .resolutions = &.{ "720p" },
                    .max_input_images = 0,
                },
            },
        },
        .together => .{
            .wire_shape = "VideoTogether",
            .output_delivery = "DeliveryURL",
            .video_base_url = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/v2/videos" },
            },
            .poll_endpoint = "/v2/videos/{id}",
            .file_endpoint = "",
            .submit_handle_field = "id",
            .requires_output_uri = false,
            .models = &.{
                .{
                    .model_id = "minimax/video-01-director",
                    .label = "MiniMax Video 01 Director (Together)",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 6,
                    .output_mime = "video/mp4",
                    .resolutions = &.{ "720p" },
                    .max_input_images = 0,
                },
            },
        },
        .vertex => .{
            .wire_shape = "VideoVertexVeo",
            .output_delivery = "DeliveryDownload",
            .video_base_url = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/{model}:predictLongRunning" },
            },
            .poll_endpoint = "/{model}:fetchPredictOperation",
            .file_endpoint = "",
            .submit_handle_field = "name",
            .requires_output_uri = false,
            .models = &.{
                .{
                    .model_id = "veo-3.1-generate-preview",
                    .label = "Veo 3.1",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 8,
                    .output_mime = "video/mp4",
                    .resolutions = &.{ "1080p", "720p" },
                    .max_input_images = 0,
                },
            },
        },
        .vidu => .{
            .wire_shape = "VideoVidu",
            .output_delivery = "DeliveryURL",
            .video_base_url = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/ent/v2/text2video" },
            },
            .poll_endpoint = "/ent/v2/tasks/{id}/creations",
            .file_endpoint = "",
            .submit_handle_field = "task_id",
            .requires_output_uri = false,
            .models = &.{
                .{
                    .model_id = "viduq1",
                    .label = "Vidu Q1",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 16,
                    .output_mime = "video/mp4",
                    .resolutions = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "viduq2",
                    .label = "Vidu Q2",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 16,
                    .output_mime = "video/mp4",
                    .resolutions = &.{},
                    .max_input_images = 0,
                },
                .{
                    .model_id = "viduq3-pro",
                    .label = "Vidu Q3 Pro",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 16,
                    .output_mime = "video/mp4",
                    .resolutions = &.{},
                    .max_input_images = 0,
                },
            },
        },
        .zhipu => .{
            .wire_shape = "VideoZhipu",
            .output_delivery = "DeliveryURL",
            .video_base_url = "",
            .variants = &.{
                .{ .carries = "TextOnly", .shape = "", .endpoint = "/v4/videos/generations" },
            },
            .poll_endpoint = "/v4/async-result/{id}",
            .file_endpoint = "",
            .submit_handle_field = "id",
            .requires_output_uri = false,
            .models = &.{
                .{
                    .model_id = "cogvideox-3",
                    .label = "CogVideoX-3",
                    .supports_image_to_video = false,
                    .max_duration_seconds = 10,
                    .output_mime = "video/mp4",
                    .resolutions = &.{ "1080p", "4k", "720p" },
                    .max_input_images = 0,
                },
            },
        },
        else => null,
    };
}
