//! Video generation (text-to-video, ADR-034 Slice 4) — a mirror of the
//! submit side of rust/src/video.rs and go/video.go. The poll/wait half is
//! `video_poll.zig` (`VideoHandle`).
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
//!         header is non-deterministic and OMITTED from the request-wire golden;
//!         `submit` adds it, the body builder does not.
//!       * `{instances:[{prompt}]}` with NO model — the model is in the submit
//!         PATH, not the body (VideoVeo / Google, VideoVertexVeo / Vertex).
//!       * Bedrock Nova Reel `{modelId, modelInput:{taskType, textToVideoParams:
//!         {text}}, outputDataConfig:{s3OutputDataConfig:{s3Uri}}}` — the model
//!         is in the body (modelId) and the caller S3 output URI is required.
//!         This is the submit BODY only: SigV4 signing is a separate concern
//!         (the sigv4-wire suite), not done here.
//!
//! `Video.submit` POSTs that body and returns a `VideoHandle`; the handle's
//! `poll` / `wait` live in `video_poll.zig`, on the shared Job engine.

const std = @import("std");
const http = @import("http.zig");
const send = @import("send.zig");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const video_gen = @import("providers/generated/video_gen.zig");
const request_variant = @import("request_variant.zig");
const middleware = @import("middleware.zig");
const video_poll = @import("video_poll.zig");

/// The submitted job (ADR-014 value + the poll/wait runtime in `video_poll.zig`).
pub const VideoHandle = video_poll.VideoHandle;

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

/// Fixed capacity for `Video.text` Parts, for the same reason.
const max_text_parts = 8;

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
    ctx: http.Ctx,
    model_: ?[]const u8 = null,
    output_uri_: ?[]const u8 = null,
    parts_: [max_image_parts]VideoInput = undefined,
    part_count_: usize = 0,
    text_parts_: [max_text_parts][]const u8 = undefined,
    text_part_count_: usize = 0,
    raw_: bool = false,

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
    pub fn outputURI(self: Video, uri: []const u8) Video {
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

    /// Append a text Part (ADR-021 appender). Text Parts precede the
    /// terminal's prompt; the submit body carries them and the prompt
    /// newline-joined, skipping empty ones. Mirrors Rust `text(s)`.
    pub fn text(self: Video, s_: []const u8) Video {
        var s = self;
        std.debug.assert(s.text_part_count_ < max_text_parts);
        s.text_parts_[s.text_part_count_] = s_;
        s.text_part_count_ += 1;
        return s;
    }

    /// Attach an observation + veto hook to this builder only (ADR-020); see
    /// `Text.addMiddleware`.
    pub fn addMiddleware(self: Video, m: middleware.Middleware) Video {
        var s = self;
        s.ctx = s.ctx.withMiddleware(m);
        return s;
    }

    /// Opt in to `VideoResponse.raw` (ADR-014). `submit` records it on the
    /// returned `VideoHandle.raw`, where the poll runtime reads it, as in Rust.
    pub fn raw(self: Video) Video {
        var s = self;
        s.raw_ = true;
        return s;
    }

    /// The prompt the submit body carries: the text Parts and then `prompt`,
    /// newline-joined, skipping empty ones (Rust `join_prompt_text`). Without
    /// text Parts it is `prompt`, unchanged.
    fn promptText(self: *const Video, arena: std.mem.Allocator, prompt: []const u8) ![]const u8 {
        if (self.text_part_count_ == 0) return prompt;
        var texts: std.ArrayList([]const u8) = .empty;
        for (self.text_parts_[0..self.text_part_count_]) |t| if (t.len > 0) try texts.append(arena, t);
        if (prompt.len > 0) try texts.append(arena, prompt);
        return std.mem.join(arena, "\n", texts.items);
    }

    /// Build the video-generation SUBMIT request body as a dynamic JSON Value
    /// backed by `arena`, dispatched on the provider's generated `wire_shape`
    /// fact. `prompt` is the text-to-video prompt.
    pub fn buildSubmitBody(self: Video, arena: std.mem.Allocator, prompt: []const u8) BuildError!json.Value {
        const cfg = video_gen.videoGenConfig(self.provider) orelse
            return error.UnsupportedVideoProvider;
        const shape = cfg.wire_shape;
        const prompt_text = try self.promptText(arena, prompt);

        if (std.mem.eql(u8, shape, "VideoQwen"))
            return buildQwenBody(arena, self, prompt_text);
        if (std.mem.eql(u8, shape, "VideoPixVerse"))
            return buildPixVerseBody(arena, self, prompt_text);
        if (std.mem.eql(u8, shape, "VideoVeo") or std.mem.eql(u8, shape, "VideoVertexVeo"))
            return buildVeoBody(arena, prompt_text);
        if (std.mem.eql(u8, shape, "VideoBedrock"))
            return buildBedrockBody(arena, self, prompt_text);
        // VideoGrok / VideoZhipu / VideoTogether / VideoMinimax / VideoVidu.
        return buildSharedBody(arena, self, prompt_text);
    }

    /// Submit a video-generation job and return a `VideoHandle`. The submit
    /// hop answers with the provider's job id (read at the config's
    /// `submit_handle_field`); poll the handle with `poll`, or block with
    /// `wait`, to get the finished video. Mirrors Go/Rust `Video.Submit`.
    pub fn submit(
        self: Video,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !VideoHandle {
        return send.withTransport(&self.ctx, @TypeOf(self).submitWith, self, .{ arena, api_key, prompt });
    }

    /// `submit` over an injected transport (the seam tests mock). A Bedrock
    /// submit is SigV4-signed by `send.zig`, like every other Bedrock send.
    pub fn submitWith(
        self: Video,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !VideoHandle {
        const cfg = video_gen.videoGenConfig(self.provider) orelse
            return error.UnsupportedVideoProvider;
        // ADR-096: a seed frame selects the WithReferenceImages submit request;
        // a config with no such variant cannot send it.
        const variant = try request_variant.select(cfg.variants, self.part_count_);
        const body = try self.buildSubmitBody(arena, prompt);

        // Several providers serve video off a DIFFERENT host than chat (MiniMax,
        // DashScope) — the generated `video_base_url` fact. A client-supplied
        // base-URL override still wins, since that is the caller pointing the SDK
        // at a gateway on purpose.
        var ctx = self.ctx;
        if (ctx.base_url == null and cfg.video_base_url.len > 0)
            ctx.base_url = cfg.video_base_url;

        // PixVerse requires a unique per-request Ai-trace-id (an anti-cache
        // key) on submit as well as poll. Mirrors Go/Rust `newVideoTraceID`.
        var extra: std.ArrayList(http.Header) = .empty;
        if (std.mem.eql(u8, cfg.wire_shape, "VideoPixVerse"))
            try extra.append(arena, .{ .name = "Ai-trace-id", .value = try video_poll.traceId(arena, self.ctx.io) });

        const reply = try send.postJson(transport, arena, .{
            .provider = self.provider,
            .ctx = &ctx,
            .api_key = api_key,
            .endpoint = try http.substituteModel(arena, variant.endpoint, self.model_ orelse ""),
            .extra_headers = extra.items,
            .op = .video_generation,
            .model = self.model_ orelse "",
        }, body);

        const id = handleIdAt(arena, reply, cfg.submit_handle_field) orelse return error.MissingVideoHandle;
        return .{
            .value = .{
                .id = try arena.dupe(u8, id),
                .provider = self.provider,
                .raw = self.raw_,
                // Vertex Veo polls a model-templated path, so the handle keeps it.
                .model = self.model_ orelse "",
            },
            .ctx = self.ctx,
            .api_key = api_key,
        };
    }
};

/// Read the submit handle at the config's declared dotted path
/// (`submit_handle_field`: Bedrock `invocationArn`, Veo `name`, DashScope
/// `output.task_id`, PixVerse `Resp.video_id`, …) — never a provider-name
/// switch, and never a hardcoded path.
///
/// A numeric leaf is formatted rather than rejected: PixVerse reports the id as
/// a JSON NUMBER while every other provider reports a string, and normalizing it
/// here is what the other SDKs did when they generalized this lookup. An id that
/// is neither string nor number, or an empty string, yields null so the caller
/// raises rather than handing back an id that cannot be polled.
fn handleIdAt(arena: std.mem.Allocator, raw: json.Value, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    const v = json.getPath(raw, path) orelse return null;
    return switch (v) {
        .string => |s| if (s.len == 0) null else s,
        .integer => |i| std.fmt.allocPrint(arena, "{d}", .{i}) catch null,
        .number_string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

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

/// A `Ctx` for the pure-seam tests below. Those tests exercise body/header
/// construction only, so the transport dependencies are never used — but Zig
/// has no ambient allocator or `Io`, so they must still be named.
fn testCtx() http.Ctx {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io };
}




























































































































































































































































































