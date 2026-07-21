//! Video generation (text-to-video, ADR-034 Slice 4) — a mirror of the
//! submit-body construction in rust/src/video.rs and go/video.go, minus the
//! async runtime.
//!
//! One pure seam the request-wire goldens assert:
//!   - `Video.buildSubmitBody` produces the SUBMIT request body per the
//!     provider's generated `wire_shape` fact — never a provider-name switch.
//!     The eleven video providers collapse to five submit-body shapes:
//!       * shared `{model, prompt}` (VideoGrok, VideoZhipu, VideoTogether,
//!         VideoMinimax, VideoVidu). An image-to-video seed frame (BUG-010,
//!         grok-imagine-video only) inlines as a `data:<mime>;base64,<b64>`
//!         URL at `image.url`, the same encoding the Grok image-edit path uses.
//!       * nested `{model, input:{prompt}}` (VideoQwen / DashScope).
//!       * five-field `{model, prompt, duration, quality, aspect_ratio}` with
//!         reference-anchored defaults (VideoPixVerse). The dynamic Ai-trace-id
//!         header is non-deterministic and OMITTED from the request-wire golden,
//!         so this builder does not generate it.
//!       * `{instances:[{prompt}]}` with NO model — the model is in the submit
//!         PATH, not the body (VideoVeo / Google, VideoVertexVeo / Vertex).
//!       * Bedrock Nova Reel `{modelId, modelInput:{taskType, textToVideoParams:
//!         {text}}, outputDataConfig:{s3OutputDataConfig:{s3Uri}}}` — the model
//!         is in the body (modelId) and the caller S3 output URI is required.
//!         This is the submit BODY only: SigV4 signing is a separate concern
//!         (the sigv4-wire suite), not done here.
//!
//! The async runtime (VideoHandle, the poll/wait loop, the two-hop file
//! retrieve, delivery download, and any HTTP send) is a later slice — no video
//! response/lifecycle wire fixture gates it and Zig has no HTTP send terminal
//! yet. This file builds only the outbound submit bytes, backed by a
//! caller-supplied allocator (pass an arena; free it in one shot).

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const video_gen = @import("providers/generated/video_gen.zig");

pub const ProviderName = providers.ProviderName;

/// One image input Part carrying RAW bytes (the builder base64-encodes them into
/// the seed-frame data URL). Video generation slice 4 is text-to-video with an
/// optional single image-to-video seed frame; there is no file variant.
pub const VideoInput = struct {
    mime: []const u8,
    bytes: []const u8,
};

pub const BuildError = error{UnsupportedVideoProvider} || std.mem.Allocator.Error;

/// Fixed capacity for image-to-video seed Parts. Video chain methods take no
/// allocator (ADR-069 ZIG-005), so Parts live in a bounded array like `Image`'s.
/// Slice 4 conditions on a single seed frame; the capacity is headroom.
const max_image_parts = 8;

/// PixVerse requires all five submit fields; the generic surface is prompt-only,
/// so duration/quality/aspect_ratio are sent as reference-anchored defaults
/// (valid across the recorded models). Mirrors the Rust/Go PixVerse arm.
const pixverse_duration: i64 = 5;
const pixverse_quality = "540p";
const pixverse_aspect_ratio = "16:9";

/// The public Video builder. Immutable value type: each chain method returns a
/// fresh copy, so a forked chain never mutates its parent (the
/// `Text`/`Image`/`Speech` discipline). Only the terminal (`buildSubmitBody`)
/// takes an allocator.
pub const Video = struct {
    provider: providers.ProviderName,
    model_: ?[]const u8 = null,
    output_uri_: ?[]const u8 = null,
    parts_: [max_image_parts]VideoInput = undefined,
    part_count_: usize = 0,

    /// The video model id (ADR-021 bare-noun replacer). Carried in the body for
    /// the shared/qwen/pixverse shapes (as `model`) and Bedrock (as `modelId`);
    /// OMITTED for Veo/Vertex, which carry the model in the submit PATH.
    pub fn model(self: Video, m: []const u8) Video {
        var s = self;
        s.model_ = m;
        return s;
    }

    /// The caller destination S3 URI for output-uri delivery (Bedrock Nova Reel
    /// writes the mp4 to the caller's own bucket; ADR-021 bare-noun replacer).
    /// Ignored by every other shape.
    pub fn outputUri(self: Video, uri: []const u8) Video {
        var s = self;
        s.output_uri_ = uri;
        return s;
    }

    /// Append an image-to-video seed-frame Part (BUG-010). `mime` is the IANA
    /// media type; `bytes` is RAW (the builder base64-encodes it into the
    /// seed data URL). Accepted only by the shared-shape image-to-video model
    /// (grok-imagine-video); ignored by every other submit shape (ADR-021
    /// `Add*`-class appender, kept as `image` for call-site uniformity).
    pub fn image(self: Video, mime: []const u8, bytes: []const u8) Video {
        var s = self;
        std.debug.assert(s.part_count_ < max_image_parts);
        s.parts_[s.part_count_] = .{ .mime = mime, .bytes = bytes };
        s.part_count_ += 1;
        return s;
    }

    /// Build the video-generation SUBMIT request body as a dynamic JSON Value
    /// backed by `arena`, dispatched on the provider's generated `wire_shape`
    /// fact. `prompt` is the text-to-video prompt.
    pub fn buildSubmitBody(self: Video, arena: std.mem.Allocator, prompt: []const u8) BuildError!json.Value {
        const cfg = video_gen.videoGenConfig(self.provider) orelse
            return error.UnsupportedVideoProvider;
        const shape = cfg.wire_shape;

        if (std.mem.eql(u8, shape, "VideoQwen"))
            return buildQwenBody(arena, self, prompt);
        if (std.mem.eql(u8, shape, "VideoPixVerse"))
            return buildPixVerseBody(arena, self, prompt);
        if (std.mem.eql(u8, shape, "VideoVeo") or std.mem.eql(u8, shape, "VideoVertexVeo"))
            return buildVeoBody(arena, prompt);
        if (std.mem.eql(u8, shape, "VideoBedrock"))
            return buildBedrockBody(arena, self, prompt);
        // VideoGrok / VideoZhipu / VideoTogether / VideoMinimax / VideoVidu.
        return buildSharedBody(arena, self, prompt);
    }
};

/// The shared `{model, prompt}` submit body (Grok, Zhipu, Together, MiniMax,
/// Vidu). An image-to-video seed frame inlines as a `data:<mime>;base64,<b64>`
/// URL at `image.url` (BUG-010), absent on the text-to-video hot path. Mirrors
/// the shared arm of Rust `dispatch_video_submit` + `video_seed_image_url`.
fn buildSharedBody(arena: std.mem.Allocator, vid: Video, prompt: []const u8) BuildError!json.Value {
    var body = json.object();
    if (vid.model_) |m| try json.set(arena, &body, "model", .{ .string = m });
    try json.set(arena, &body, "prompt", .{ .string = prompt });

    if (vid.part_count_ > 0) {
        const seed = vid.parts_[0];
        const mime = if (seed.mime.len == 0) "image/png" else seed.mime;
        const b64 = try base64Encode(arena, seed.bytes);
        const data_url = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ mime, b64 });
        var img = json.object();
        try json.set(arena, &img, "url", .{ .string = data_url });
        try json.set(arena, &body, "image", img);
    }
    return body;
}

/// The DashScope (Qwen) submit body: the prompt nests under an `input` object —
/// `{model, input:{prompt}}`. The load-bearing `X-DashScope-Async: enable`
/// header is a send-time concern (the async runtime), not part of the body.
fn buildQwenBody(arena: std.mem.Allocator, vid: Video, prompt: []const u8) BuildError!json.Value {
    var input = json.object();
    try json.set(arena, &input, "prompt", .{ .string = prompt });

    var body = json.object();
    if (vid.model_) |m| try json.set(arena, &body, "model", .{ .string = m });
    try json.set(arena, &body, "input", input);
    return body;
}

/// The PixVerse submit body: all five fields — `{model, prompt, duration,
/// quality, aspect_ratio}` — with the reference-anchored defaults for the
/// prompt-only generic surface.
fn buildPixVerseBody(arena: std.mem.Allocator, vid: Video, prompt: []const u8) BuildError!json.Value {
    var body = json.object();
    if (vid.model_) |m| try json.set(arena, &body, "model", .{ .string = m });
    try json.set(arena, &body, "prompt", .{ .string = prompt });
    try json.set(arena, &body, "duration", .{ .integer = pixverse_duration });
    try json.set(arena, &body, "quality", .{ .string = pixverse_quality });
    try json.set(arena, &body, "aspect_ratio", .{ .string = pixverse_aspect_ratio });
    return body;
}

/// The Veo submit body (Google Veo + Vertex Veo): the prompt nests under
/// `instances[]` and there is NO model field — the model is in the submit PATH
/// (:predictLongRunning), not the body.
fn buildVeoBody(arena: std.mem.Allocator, prompt: []const u8) BuildError!json.Value {
    var instance = json.object();
    try json.set(arena, &instance, "prompt", .{ .string = prompt });

    var instances = json.array(arena);
    try instances.array.append(instance);

    var body = json.object();
    try json.set(arena, &body, "instances", instances);
    return body;
}

/// The Bedrock Nova Reel submit body: the model is carried in the body
/// (`modelId`, unlike the Converse chat path), the prompt nests under
/// `modelInput.textToVideoParams.text`, and the caller S3 URI lands under
/// `outputDataConfig.s3OutputDataConfig.s3Uri`. SigV4 signing of the request is
/// a separate concern (not done here — submit BODY only).
fn buildBedrockBody(arena: std.mem.Allocator, vid: Video, prompt: []const u8) BuildError!json.Value {
    var t2v = json.object();
    try json.set(arena, &t2v, "text", .{ .string = prompt });

    var model_input = json.object();
    try json.set(arena, &model_input, "taskType", .{ .string = "TEXT_VIDEO" });
    try json.set(arena, &model_input, "textToVideoParams", t2v);

    var s3 = json.object();
    try json.set(arena, &s3, "s3Uri", .{ .string = vid.output_uri_ orelse "" });
    var output_config = json.object();
    try json.set(arena, &output_config, "s3OutputDataConfig", s3);

    var body = json.object();
    if (vid.model_) |m| try json.set(arena, &body, "modelId", .{ .string = m });
    try json.set(arena, &body, "modelInput", model_input);
    try json.set(arena, &body, "outputDataConfig", output_config);
    return body;
}

/// Standard-alphabet, padded base64 encode of `bytes` into `arena`.
fn base64Encode(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try arena.alloc(u8, enc.calcSize(bytes.len));
    return enc.encode(buf, bytes);
}

const test_prompt = "A drone shot sweeping over snow-capped alpine peaks at sunrise";


































































































