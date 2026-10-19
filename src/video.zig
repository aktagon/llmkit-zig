//! Video generation (text-to-video, ADR-034 Slice 4) — a mirror of the
//! submit side of rust/src/video.rs and go/video.go. The poll/wait half is
//! `video_poll.zig` (`VideoHandle`).
//!
//! One pure seam the request-wire goldens assert:
//!   - `Video.buildSubmitBody` produces the SUBMIT request body per the
//!     provider's generated `wire_shape` fact — never a provider-name switch.
//!     The twelve video providers collapse to five submit-body shapes:
//!       * shared `{model, prompt}` (VideoGrok, VideoZhipu, VideoTogether,
//!         VideoMinimax, VideoVidu, VideoOpenRouter). An image-to-video seed frame (BUG-010,
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
const image_gen = @import("providers/generated/image_gen.zig");
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

/// Pre-send rejections for a last frame and reference images (BUG-089). Zig
/// errors carry no payload; the other SDKs raise a validation error with the
/// field and message named here, checked in this order:
///   - `LastFrameUnsupported`: field "last_frame", "<model> does not accept a last frame".
///   - `ReferenceImagesUnsupported`: field "reference_images", "<model> does not accept reference images".
///   - `TooManyReferenceImages`: field "reference_images", "at most 3 reference images, got N".
///   - `ReferenceImagesWithFrame`: field "reference_images", "cannot be combined with a first or last frame".
///   - `LastFrameWithoutFirstFrame`: field "last_frame", "requires a first frame".
pub const FrameError = error{
    LastFrameUnsupported,
    ReferenceImagesUnsupported,
    TooManyReferenceImages,
    ReferenceImagesWithFrame,
    LastFrameWithoutFirstFrame,
};

/// Pre-send rejections for duration, aspect ratio and resolution
/// (HANDOFF-097), checked in this order (Go's `validateVideoOptions`). The
/// other SDKs raise a validation error with the field and message named here:
///   - `DurationNotSent` / `AspectRatioNotSent` / `ResolutionNotSent`: a set
///     option on a wire shape other than VideoOpenRouter, the first of
///     duration, aspect_ratio, resolution; "<provider> video does not send <field>".
///   - `DurationNotPositive`: field "duration", "must be positive".
///   - `DurationTooLong`: field "duration", "<model> takes at most <max> seconds, got <n>".
///   - `ResolutionUnsupported`: field "resolution", "<model> does not support resolution <r>".
///   - `AspectRatioUnsupported`: field "aspect_ratio", "<model> does not support aspect ratio <r>".
pub const OptionError = error{
    DurationNotSent,
    AspectRatioNotSent,
    ResolutionNotSent,
    DurationNotPositive,
    DurationTooLong,
    ResolutionUnsupported,
    AspectRatioUnsupported,
};

/// The most asset reference images a Veo request takes (Gemini API and Vertex
/// Veo pages, read 2026-10-15).
pub const max_reference_images = 3;

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
    /// The final frame the video ends on (BUG-089).
    last_frame_: ?VideoInput = null,
    /// Asset reference images, at most 3 (BUG-089).
    reference_images_: []const VideoInput = &.{},
    /// Video length in whole seconds; 0 = unset (HANDOFF-097).
    duration_: i64 = 0,
    /// Output aspect ratio such as "16:9"; "" = unset (HANDOFF-097).
    aspect_ratio_: []const u8 = "",
    /// Output resolution such as "720p"; "" = unset (HANDOFF-097).
    resolution_: []const u8 = "",

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
    /// seed data URL, or the raw base64 Veo first frame, BUG-089). Carried by
    /// grok-imagine-video and the Veo 3.1 models; ignored by every other
    /// submit shape (ADR-021 `Add*`-class appender, kept as `image` for
    /// call-site uniformity).
    pub fn image(self: Video, mime: []const u8, bytes: []const u8) Video {
        var s = self;
        std.debug.assert(s.part_count_ < max_image_parts);
        s.parts_[s.part_count_] = .{ .mime = mime, .bytes = bytes };
        s.part_count_ += 1;
        return s;
    }

    /// The final frame the video ends on (BUG-089; ADR-021 bare-noun
    /// replacer). Send it with a first frame (`image`) on a model that takes
    /// a last frame; otherwise `submit` rejects it before send.
    pub fn lastFrame(self: Video, mime: []const u8, bytes: []const u8) Video {
        var s = self;
        s.last_frame_ = .{ .mime = mime, .bytes = bytes };
        return s;
    }

    /// The asset reference images the video keeps, such as a person,
    /// character or product (BUG-089). At most 3, without `image` or
    /// `lastFrame`. Zig chain methods take no allocator (ADR-069 ZIG-005), so
    /// the images arrive as one slice where the other SDKs append with
    /// `AddReferenceImage`; the caller owns the slice.
    pub fn referenceImages(self: Video, v: []const VideoInput) Video {
        var s = self;
        s.reference_images_ = v;
        return s;
    }

    /// The video length in whole seconds (HANDOFF-097; ADR-021 bare-noun
    /// replacer). Only OpenRouter sends it; other providers reject it before
    /// send, as does a value above the model's maximum.
    pub fn duration(self: Video, seconds: i64) Video {
        var s = self;
        s.duration_ = seconds;
        return s;
    }

    /// The output aspect ratio, such as "16:9" (HANDOFF-097). Only OpenRouter
    /// sends it; a ratio the model does not list is rejected before send.
    pub fn aspectRatio(self: Video, ratio: []const u8) Video {
        var s = self;
        s.aspect_ratio_ = ratio;
        return s;
    }

    /// The output resolution, such as "720p" (HANDOFF-097). Only OpenRouter
    /// sends it; a resolution the model does not list is rejected before send.
    pub fn resolution(self: Video, r: []const u8) Video {
        var s = self;
        s.resolution_ = r;
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
            return buildVeoBody(arena, self, prompt_text);
        if (std.mem.eql(u8, shape, "VideoBedrock"))
            return buildBedrockBody(arena, self, prompt_text);
        if (std.mem.eql(u8, shape, "VideoOpenRouter"))
            return buildOpenRouterBody(arena, self, prompt_text);
        // VideoGrok / VideoZhipu / VideoTogether / VideoMinimax / VideoVidu.
        return buildSharedBody(arena, self, prompt_text);
    }

    /// Reject a last frame or reference images the model or the request cannot
    /// carry, before send (BUG-089). Same rules and order as Go's
    /// `validateVideoFrames`. A model missing from the config takes neither.
    fn validateFrames(self: Video, cfg: video_gen.VideoGenDef) FrameError!void {
        var supports_last = false;
        var supports_refs = false;
        for (cfg.models) |m| {
            if (std.mem.eql(u8, m.model_id, self.model_ orelse "")) {
                supports_last = m.supports_last_frame;
                supports_refs = m.supports_reference_images;
            }
        }
        const refs = self.reference_images_.len;
        const last = self.last_frame_ != null;
        if (last and !supports_last) return error.LastFrameUnsupported;
        if (refs > 0 and !supports_refs) return error.ReferenceImagesUnsupported;
        if (refs > max_reference_images) return error.TooManyReferenceImages;
        // Live 2026-10-15: Veo answers 400 "Unsupported video generation
        // request"; Vertex documents the inputs as exclusive.
        if (refs > 0 and (self.part_count_ > 0 or last)) return error.ReferenceImagesWithFrame;
        if (last and self.part_count_ == 0) return error.LastFrameWithoutFirstFrame;
    }

    /// Reject a duration, aspect ratio or resolution the provider or the
    /// model cannot take, before send (HANDOFF-097). Same rules and order as
    /// Go's `validateVideoOptions`; see `OptionError`. A zero maximum or an
    /// empty list means no known limit.
    fn validateOptions(self: Video, cfg: video_gen.VideoGenDef) OptionError!void {
        if (!std.mem.eql(u8, cfg.wire_shape, "VideoOpenRouter")) {
            if (self.duration_ != 0) return error.DurationNotSent;
            if (self.aspect_ratio_.len > 0) return error.AspectRatioNotSent;
            if (self.resolution_.len > 0) return error.ResolutionNotSent;
            return;
        }
        var max_duration: i64 = 0;
        var resolutions: []const []const u8 = &.{};
        var aspect_ratios: []const []const u8 = &.{};
        for (cfg.models) |m| {
            if (std.mem.eql(u8, m.model_id, self.model_ orelse "")) {
                max_duration = m.max_duration_seconds;
                resolutions = m.resolutions;
                aspect_ratios = m.aspect_ratios;
            }
        }
        if (self.duration_ < 0) return error.DurationNotPositive;
        if (self.duration_ > 0 and max_duration > 0 and self.duration_ > max_duration) return error.DurationTooLong;
        if (self.resolution_.len > 0 and resolutions.len > 0 and !listed(resolutions, self.resolution_))
            return error.ResolutionUnsupported;
        if (self.aspect_ratio_.len > 0 and aspect_ratios.len > 0 and !listed(aspect_ratios, self.aspect_ratio_))
            return error.AspectRatioUnsupported;
    }

    /// The request's carried inputs (ADR-096): reference images, a seed frame
    /// with an optional last frame, or text only.
    fn carries(self: Video) []const []const u8 {
        if (self.reference_images_.len > 0) return &.{image_gen.with_reference_images};
        if (self.part_count_ > 0 and self.last_frame_ != null)
            return &.{ image_gen.with_seed_frame, image_gen.with_last_frame };
        if (self.part_count_ > 0) return &.{image_gen.with_seed_frame};
        return &.{image_gen.text_only};
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
        // ADR-096: a seed frame selects the WithSeedFrame submit request;
        // a config with no such variant cannot send it.
        try self.validateFrames(cfg);
        try self.validateOptions(cfg);
        const variant = try request_variant.select(cfg.variants, self.carries());
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

/// The OpenRouter submit body: `{model, prompt}` plus, for image-to-video
/// (HANDOFF-091), `frame_images` with each frame as an OpenRouter
/// ContentPartImage plus `frame_type`, first_frame then last_frame (live probe
/// 2026-10-18; openrouter.ai/openapi.json). Mirrors Go's VideoShapeOpenRouter arm.
fn buildOpenRouterBody(arena: std.mem.Allocator, vid: Video, prompt: []const u8) BuildError!json.Value {
    var body = json.object();
    if (vid.model_) |m| try json.set(arena, &body, "model", .{ .string = m });
    try json.set(arena, &body, "prompt", .{ .string = prompt });
    if (vid.part_count_ > 0) {
        var frames = json.array(arena);
        try frames.array.append(try openRouterFrame(arena, vid.parts_[0], "first_frame"));
        if (vid.last_frame_) |last| try frames.array.append(try openRouterFrame(arena, last, "last_frame"));
        try json.set(arena, &body, "frame_images", frames);
    }
    // Video options (HANDOFF-097): body-root fields, each sent only when set,
    // so the prompt-only body stays {model, prompt}; `validateOptions` has
    // already checked each against the model.
    if (vid.duration_ > 0) try json.set(arena, &body, "duration", .{ .integer = vid.duration_ });
    if (vid.aspect_ratio_.len > 0) try json.set(arena, &body, "aspect_ratio", .{ .string = vid.aspect_ratio_ });
    if (vid.resolution_.len > 0) try json.set(arena, &body, "resolution", .{ .string = vid.resolution_ });
    return body;
}

/// Whether `want` is one of `items`.
fn listed(items: []const []const u8, want: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, want)) return true;
    return false;
}

/// One OpenRouter frame_images item.
fn openRouterFrame(arena: std.mem.Allocator, img: VideoInput, frame_type: []const u8) BuildError!json.Value {
    const mime = if (img.mime.len == 0) "image/png" else img.mime;
    const url = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ mime, try base64Encode(arena, img.bytes) });
    var image_url = json.object();
    try json.set(arena, &image_url, "url", .{ .string = url });
    var frame = json.object();
    try json.set(arena, &frame, "type", .{ .string = "image_url" });
    try json.set(arena, &frame, "image_url", image_url);
    try json.set(arena, &frame, "frame_type", .{ .string = frame_type });
    return frame;
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
/// (:predictLongRunning), not the body. A first frame (BUG-089) rides at
/// `instances[0].image` as `{bytesBase64Encoded, mimeType}` — raw base64, no
/// data: prefix — per the Vertex Veo reference (read 2026-10-15); the Gemini
/// API shape is not yet live-verified. Absent on the text-to-video hot path.
fn buildVeoBody(arena: std.mem.Allocator, vid: Video, prompt: []const u8) BuildError!json.Value {
    var instance = json.object();
    try json.set(arena, &instance, "prompt", .{ .string = prompt });
    if (vid.part_count_ > 0) {
        const seed = vid.parts_[0];
        var img = json.object();
        try json.set(arena, &img, "bytesBase64Encoded", .{ .string = try base64Encode(arena, seed.bytes) });
        try json.set(arena, &img, "mimeType", .{ .string = if (seed.mime.len == 0) "image/png" else seed.mime });
        try json.set(arena, &instance, "image", img);
    }
    // Last frame and asset reference images (BUG-089): same
    // {bytesBase64Encoded, mimeType} wrapper. Reference images force an
    // 8-second video, sent as the NUMBER 8 on both APIs (live 2026-10-15: the
    // Gemini API rejects the string "8" its docs show).
    if (vid.last_frame_) |last| try json.set(arena, &instance, "lastFrame", try veoImage(arena, last));
    var parameters: ?json.Value = null;
    if (vid.reference_images_.len > 0) {
        var refs = json.array(arena);
        for (vid.reference_images_) |ref| {
            var item = json.object();
            try json.set(arena, &item, "image", try veoImage(arena, ref));
            try json.set(arena, &item, "referenceType", .{ .string = "asset" });
            try refs.array.append(item);
        }
        try json.set(arena, &instance, "referenceImages", refs);
        var p = json.object();
        try json.set(arena, &p, "durationSeconds", .{ .integer = 8 });
        parameters = p;
    }

    var instances = json.array(arena);
    try instances.array.append(instance);

    var body = json.object();
    try json.set(arena, &body, "instances", instances);
    if (parameters) |p| try json.set(arena, &body, "parameters", p);
    return body;
}

/// A Veo image object: raw base64 bytes and the MIME type (default image/png).
fn veoImage(arena: std.mem.Allocator, img: VideoInput) BuildError!json.Value {
    var out = json.object();
    try json.set(arena, &out, "bytesBase64Encoded", .{ .string = try base64Encode(arena, img.bytes) });
    try json.set(arena, &out, "mimeType", .{ .string = if (img.mime.len == 0) "image/png" else img.mime });
    return out;
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
























































































































































































































































































































































































