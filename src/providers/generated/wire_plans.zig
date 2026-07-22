// Code generated — DO NOT EDIT.


// Body plans (ADR-073 T1 config-data interpreter — VIDEO PROVING CUT).
//
// Emitted as DATA: each plan is an ordered list of field bindings a
// handwritten interpreter (slice 3) walks to build a video submit body. No
// runtime reads these tables yet. The vocabulary is CLOSED (INT-001): five
// sources (Model | Prompt | Option | Const | MediaRef), two transforms
// (None | DataUri).

pub const FieldBinding = struct {
    path: []const u8,
    source: []const u8,
    option_key: []const u8,
    const_json: []const u8,
    default_json: []const u8,
    transform: []const u8,
    omit_if_empty: bool,
};

/// A named, reusable request-body plan; several wire shapes may share one.
pub const BodyPlan = struct {
    label: []const u8,
    bindings: []const FieldBinding,
};

pub const plan_video_bedrock = BodyPlan{
    .label = "video-bedrock",
    .bindings = &.{
        .{ .path = "modelId", .source = "Model", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
        .{ .path = "modelInput.taskType", .source = "Const", .option_key = "", .const_json = "\"TEXT_VIDEO\"", .default_json = "", .transform = "None", .omit_if_empty = false },
        .{ .path = "modelInput.textToVideoParams.text", .source = "Prompt", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
        .{ .path = "outputDataConfig.s3OutputDataConfig.s3Uri", .source = "Option", .option_key = "output_uri", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
    },
};

pub const plan_video_grok = BodyPlan{
    .label = "video-grok",
    .bindings = &.{
        .{ .path = "model", .source = "Model", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
        .{ .path = "prompt", .source = "Prompt", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
        .{ .path = "image.url", .source = "MediaRef", .option_key = "", .const_json = "", .default_json = "", .transform = "DataUri", .omit_if_empty = true },
    },
};

pub const plan_video_model_prompt = BodyPlan{
    .label = "video-model-prompt",
    .bindings = &.{
        .{ .path = "model", .source = "Model", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
        .{ .path = "prompt", .source = "Prompt", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
    },
};

pub const plan_video_pix_verse = BodyPlan{
    .label = "video-pixverse",
    .bindings = &.{
        .{ .path = "model", .source = "Model", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
        .{ .path = "prompt", .source = "Prompt", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
        .{ .path = "duration", .source = "Option", .option_key = "duration", .const_json = "", .default_json = "5", .transform = "None", .omit_if_empty = false },
        .{ .path = "quality", .source = "Option", .option_key = "quality", .const_json = "", .default_json = "\"540p\"", .transform = "None", .omit_if_empty = false },
        .{ .path = "aspect_ratio", .source = "Option", .option_key = "aspect_ratio", .const_json = "", .default_json = "\"16:9\"", .transform = "None", .omit_if_empty = false },
    },
};

pub const plan_video_qwen = BodyPlan{
    .label = "video-qwen",
    .bindings = &.{
        .{ .path = "input.prompt", .source = "Prompt", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
        .{ .path = "model", .source = "Model", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
    },
};

pub const plan_video_veo_instances = BodyPlan{
    .label = "video-veo-instances",
    .bindings = &.{
        .{ .path = "instances[0].prompt", .source = "Prompt", .option_key = "", .const_json = "", .default_json = "", .transform = "None", .omit_if_empty = false },
    },
};

pub const VideoBodyPlanEntry = struct {
    shape: []const u8,
    plan: BodyPlan,
};

// Maps a video wire shape to its body plan (ADR-073).
pub const video_body_plans = [_]VideoBodyPlanEntry{
    .{ .shape = "VideoBedrock", .plan = plan_video_bedrock },
    .{ .shape = "VideoGrok", .plan = plan_video_grok },
    .{ .shape = "VideoMinimax", .plan = plan_video_model_prompt },
    .{ .shape = "VideoPixVerse", .plan = plan_video_pix_verse },
    .{ .shape = "VideoQwen", .plan = plan_video_qwen },
    .{ .shape = "VideoTogether", .plan = plan_video_model_prompt },
    .{ .shape = "VideoVeo", .plan = plan_video_veo_instances },
    .{ .shape = "VideoVertexVeo", .plan = plan_video_veo_instances },
    .{ .shape = "VideoVidu", .plan = plan_video_model_prompt },
    .{ .shape = "VideoZhipu", .plan = plan_video_model_prompt },
};
