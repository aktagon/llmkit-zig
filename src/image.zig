//! Image generation capability (ADR-069 Slice 1) — a mirror of rust/src/image.rs
//! and go/image.go, minus the HTTP send.
//!
//! Two pure seams the wire goldens assert:
//!   - `Image.buildImageBody` produces the JSON request body per the shape of
//!     the request variant the parts select (ADR-096): InlineParts -> Google
//!     generateContent `contents`/`parts`; JSONGenerationsOpenAI -> the OpenAI
//!     flat generations body; JSONInlineRefs -> the xAI Grok body with
//!     data-URL reference images; JSONGenerations -> Recraft's flat body. Never
//!     a provider-name switch. The image INPUT is RAW bytes; the builder
//!     base64-encodes it. The MultipartForm variant is the OpenAI edit request:
//!     `Image.buildEditMultipart` encodes it as multipart/form-data (BUG-097).
//!   - `parseImageResponse` projects a provider REPLY to the normalized
//!     `{images, usage, finish_reason}` dispatched on the generated
//!     `response_shape` fact (GoogleParts / DataArrayB64Json, BUG-024) — again config, never a name switch.
//!
//! Both are backed by a caller-supplied allocator (pass an arena for a whole
//! build/parse and free it in one shot). Runtime concerns (validation, HTTP
//! send, middleware) are later slices; this file is the wire-shaped core.

const std = @import("std");

/// A parsed signal string as an optional canonical field: an empty extraction
/// means the provider sent no value, which is absence, not the empty string.
/// Zig coerces `[]const u8` into `?[]const u8` silently, so a bare "" would
/// store a REPORTED empty string with no compiler complaint.
fn optString(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}
const http = @import("http.zig");
const send = @import("send.zig");
const multipart = @import("multipart.zig");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const image_gen = @import("providers/generated/image_gen.zig");
const request_variant = @import("request_variant.zig");
const response = @import("response.zig");
const structs = @import("providers/generated/structs.zig");
const request = @import("request.zig");
const middleware = @import("middleware.zig");

pub const ProviderName = providers.ProviderName;

/// One image input Part carrying RAW bytes (the builder base64-encodes them per
/// provider). Image generation only takes image Parts, so — unlike the text
/// path's `MediaPart` — there is no file variant here.
pub const ImageInput = struct {
    mime: []const u8,
    bytes: []const u8,
};

/// One input Part, in caller order: a reference image or a text Part. Google
/// sends them interleaved as given; the other shapes join the text Parts into
/// the prompt and send the images by themselves (Rust `Part`).
pub const ImagePart = union(enum) {
    image: ImageInput,
    text: []const u8,
};

/// Google safety setting `{category, threshold}` (the text path's type).
pub const SafetySetting = request.SafetySetting;

/// One decoded output image. `bytes` is RAW (already base64-decoded from the
/// wire); `mime_type` is the provider's echoed media type (defaulting to
/// image/png when absent).
pub const ImageData = structs.ImageData;

/// The normalized image-generation reply. `images` is caller order; `text`
/// carries any revised-prompt / text parts a provider returns; `usage` reuses
/// the shared token carrier.
pub const ImageResponse = structs.ImageResponse;

/// `EditIsMultipart`: the selected variant is the MultipartForm request, whose
/// body is multipart, not JSON; `buildEditMultipart` builds it. Returned rather
/// than a JSON body that would drop the images (BUG-097). `NoRequestVariant`:
/// the config has no request for the inputs the parts carry (ADR-096).
pub const BuildError = error{ UnsupportedImageProvider, EditIsMultipart } || request_variant.Error || std.mem.Allocator.Error;

/// A real encoded multipart/form-data body plus the boundary it used, as in
/// `transcription.Multipart`.
pub const Multipart = struct {
    boundary: []const u8,
    body: []const u8,
};

/// A fixed, deterministic multipart boundary, chosen as in `transcription.zig`.
const edit_boundary = "----llmkitZigImageEditBoundary7MA4YWxkTrZu0gW";
pub const ParseError = error{UnsupportedImageProvider} || std.mem.Allocator.Error;
/// Pre-flight rejections. Zig error sets carry no payload, so each names the
/// KIND where the other SDKs return `ValidationError{Field, Message}`
/// (ADR-076 §3); all four correspond to field "model" or "parts".
/// `MaskUnsupported`, `SafetyFilterUnsupported` and `SafetySettingsUnsupported`
/// name a knob the selected request shape has no field for (Rust rejects these
/// with `ValidationError{field: "mask" | "safety_filter" | "safety_settings"}`).
pub const ValidationError = error{
    UnknownImageModel,
    ImageInputUnsupported,
    TooManyImageParts,
    MaskUnsupported,
    SafetyFilterUnsupported,
    SafetySettingsUnsupported,
} || request_variant.Error;

/// Fixed capacity for input Parts, image and text together (edit /
/// compositional generation). Image chain methods take no allocator (ADR-069
/// ZIG-005), so Parts live in a bounded array like `Text`'s media Parts.
const max_image_parts = 8;

/// The public Image builder. Immutable value type: each chain method returns a
/// fresh copy, so a forked chain never mutates its parent (the `Text`/`Agent`
/// discipline). Only the terminal (`buildImageBody`) takes an allocator.
pub const Image = struct {
    provider: providers.ProviderName,
    ctx: http.Ctx,
    model_: ?[]const u8 = null,
    aspect_ratio_: ?[]const u8 = null,
    image_size_: ?[]const u8 = null,
    include_text_: bool = false,
    quality_: ?[]const u8 = null,
    output_format_: ?[]const u8 = null,
    background_: ?[]const u8 = null,
    count_: ?i64 = null,
    parts_: [max_image_parts]ImagePart = undefined,
    part_count_: usize = 0,
    image_count_: usize = 0,
    /// Set when `image` or `text` is called with `parts_` full; the terminal
    /// rejects it.
    parts_overflow_: bool = false,
    mask_: ?ImageInput = null,
    safety_filter_: ?[]const u8 = null,
    safety_settings_: []const SafetySetting = &.{},
    raw_: bool = false,

    /// The image model id (ADR-021 bare-noun replacer). Carried in the body for
    /// the OpenAI/Recraft flat shapes; omitted for Google (model is in the URL).
    pub fn model(self: Image, m: []const u8) Image {
        var s = self;
        s.model_ = m;
        return s;
    }

    /// Requested aspect ratio (e.g. "16:9"). Google `generationConfig.imageConfig`.
    pub fn aspectRatio(self: Image, ratio: []const u8) Image {
        var s = self;
        s.aspect_ratio_ = ratio;
        return s;
    }

    /// Requested image size (Google "2K"/"1K"; OpenAI/Recraft "1024x1024").
    pub fn imageSize(self: Image, size: []const u8) Image {
        var s = self;
        s.image_size_ = size;
        return s;
    }

    /// Request TEXT alongside IMAGE in the Google `responseModalities` (WithText).
    pub fn includeText(self: Image, on: bool) Image {
        var s = self;
        s.include_text_ = on;
        return s;
    }

    /// OpenAI gpt-image-* quality enum (low|medium|high|auto).
    pub fn quality(self: Image, q: []const u8) Image {
        var s = self;
        s.quality_ = q;
        return s;
    }

    /// OpenAI gpt-image-* output MIME format (png|webp|jpeg).
    pub fn outputFormat(self: Image, fmt: []const u8) Image {
        var s = self;
        s.output_format_ = fmt;
        return s;
    }

    /// OpenAI gpt-image-* background treatment (transparent|opaque|auto).
    pub fn background(self: Image, bg: []const u8) Image {
        var s = self;
        s.background_ = bg;
        return s;
    }

    /// Number of images to generate; wire field `n` (OpenAI + Recraft).
    pub fn count(self: Image, n: i64) Image {
        var s = self;
        s.count_ = n;
        return s;
    }

    /// Append a reference-image input Part (edit / compositional generation).
    /// `mime` is the IANA media type; `bytes` is RAW (the builder base64-encodes
    /// it). Parts precede the prompt text in caller order (ADR-021 `Add*`-class
    /// appender; kept as `image` for call-site uniformity with `Text.image`).
    /// A part past `max_image_parts` is not stored; `generate` then returns
    /// `error.TooManyImageParts`.
    pub fn image(self: Image, mime: []const u8, bytes: []const u8) Image {
        var s = self.appendPart(.{ .image = .{ .mime = mime, .bytes = bytes } });
        if (!s.parts_overflow_) s.image_count_ += 1;
        return s;
    }

    /// Append a text input Part (ADR-021 appender). Text Parts precede the
    /// terminal's prompt, in caller order: Google sends each as its own
    /// `{text}` part, and the other shapes newline-join them with the prompt.
    /// Mirrors Rust `text(s)`.
    pub fn text(self: Image, s_: []const u8) Image {
        return self.appendPart(.{ .text = s_ });
    }

    fn appendPart(self: Image, part: ImagePart) Image {
        var s = self;
        if (s.part_count_ == max_image_parts) {
            s.parts_overflow_ = true;
            return s;
        }
        s.parts_[s.part_count_] = part;
        s.part_count_ += 1;
        return s;
    }

    /// Inpainting mask: transparent pixels mark the region to edit. `bytes` is
    /// RAW. Sent only by the OpenAI edit request (multipart, with at least one
    /// reference image); `generate` rejects it for any other request shape.
    /// Mirrors Rust `mask(mime, data)`.
    pub fn mask(self: Image, mime: []const u8, bytes: []const u8) Image {
        var s = self;
        s.mask_ = .{ .mime = mime, .bytes = bytes };
        return s;
    }

    /// Deprecated: no provider accepts this since 2026-10-15 (Vertex Imagen
    /// shut down, BUG-101), so `generate` always rejects it; removed at the
    /// next major. Mirrors Rust `safety_filter`.
    pub fn safetyFilter(self: Image, threshold: []const u8) Image {
        var s = self;
        s.safety_filter_ = threshold;
        return s;
    }

    /// Google per-category safety thresholds: a top-level `safetySettings`
    /// array, as on the text path. Only the Google shape has the field;
    /// `generate` rejects it elsewhere. `settings` is caller-owned and must
    /// outlive the terminal. Mirrors Rust `safety_settings`.
    pub fn safetySettings(self: Image, settings: []const SafetySetting) Image {
        var s = self;
        s.safety_settings_ = settings;
        return s;
    }

    /// Attach an observation + veto hook to this builder only (ADR-020); see
    /// `Text.addMiddleware`.
    pub fn addMiddleware(self: Image, m: middleware.Middleware) Image {
        var s = self;
        s.ctx = s.ctx.withMiddleware(m);
        return s;
    }

    /// Opt in to `ImageResponse.raw` (ADR-014): `generate` sets it to the
    /// parsed provider reply body. Null without this call.
    pub fn raw(self: Image) Image {
        var s = self;
        s.raw_ = true;
        return s;
    }

    /// The config's request variant for the image parts this builder holds
    /// (ADR-096). Text Parts do not select a variant.
    fn variant(self: Image, cfg: image_gen.ImageGenDef) request_variant.Error!image_gen.RequestVariant {
        return request_variant.select(cfg.variants, &.{request_variant.partsCarry(self.image_count_, image_gen.with_reference_images)});
    }

    /// The prompt the flat shapes send: the text Parts and then `prompt`,
    /// newline-joined, skipping empty ones (Rust `join_text_parts`). Without
    /// text Parts it is `prompt`, unchanged.
    fn promptText(self: *const Image, arena: std.mem.Allocator, prompt: []const u8) ![]const u8 {
        var texts: std.ArrayList([]const u8) = .empty;
        for (self.parts_[0..self.part_count_]) |p| switch (p) {
            .text => |t| if (t.len > 0) try texts.append(arena, t),
            .image => {},
        };
        if (texts.items.len == 0) return prompt;
        if (prompt.len > 0) try texts.append(arena, prompt);
        return std.mem.join(arena, "\n", texts.items);
    }

    /// Build the image-generation request body as a dynamic JSON Value backed by
    /// `arena`, dispatched on the shape of the request variant the parts select
    /// (ADR-096). `prompt` is the trailing text Part; any reference-image Parts
    /// precede it.
    pub fn buildImageBody(self: Image, arena: std.mem.Allocator, prompt: []const u8) BuildError!json.Value {
        const cfg = image_gen.imageGenConfig(self.provider) orelse
            return error.UnsupportedImageProvider;
        const shape = (try self.variant(cfg)).shape;
        const parts = self.parts_[0..self.part_count_];
        const eq = std.mem.eql;

        if (eq(u8, shape, image_gen.inline_parts))
            return buildGoogleImageBody(arena, self, parts, prompt);
        if (eq(u8, shape, image_gen.multipart_form))
            return error.EditIsMultipart;
        const text_prompt = try self.promptText(arena, prompt);
        if (eq(u8, shape, image_gen.json_generations_openai))
            return buildOpenAIGenBody(arena, self, text_prompt);
        if (eq(u8, shape, image_gen.json_inline_refs))
            return buildXAIBody(arena, self, parts, text_prompt);
        if (eq(u8, shape, image_gen.json_generations))
            return buildRecraftGenBody(arena, self, text_prompt);
        if (eq(u8, shape, image_gen.json_generations_input_refs))
            return buildInputRefsBody(arena, self, parts, text_prompt);
        return error.UnsupportedImageProvider;
    }

    /// Build the OpenAI edit request (the MultipartForm variant) as a
    /// multipart/form-data body for that variant's endpoint. Text fields
    /// come first in a fixed order (model, prompt, size, quality, output_format,
    /// background, n), then one `image[]` file part per reference image in
    /// caller order, named `image-<i><ext>`, then the `mask` file when set.
    /// Mirrors Go `buildOpenAIEditMultipart` / Rust `build_openai_edit_form`.
    /// Rejects a call whose parts select any other request shape.
    pub fn buildEditMultipart(self: Image, arena: std.mem.Allocator, prompt: []const u8) BuildError!Multipart {
        const cfg = image_gen.imageGenConfig(self.provider) orelse
            return error.UnsupportedImageProvider;
        if (!std.mem.eql(u8, (try self.variant(cfg)).shape, image_gen.multipart_form))
            return error.UnsupportedImageProvider;

        var w: multipart.Writer = .{ .boundary = edit_boundary };
        if (self.model_) |m| try w.field(arena, "model", m);
        try w.field(arena, "prompt", try self.promptText(arena, prompt));
        if (self.image_size_) |z| try w.field(arena, "size", z);
        if (self.quality_) |q| try w.field(arena, "quality", q);
        if (self.output_format_) |f| try w.field(arena, "output_format", f);
        if (self.background_) |bg| try w.field(arena, "background", bg);
        if (self.count_) |n| try w.field(arena, "n", try std.fmt.allocPrint(arena, "{d}", .{n}));

        var i: usize = 0;
        for (self.parts_[0..self.part_count_]) |part| {
            const p = switch (part) {
                .image => |img| img,
                .text => continue,
            };
            const mime = if (p.mime.len == 0) "image/png" else p.mime;
            const filename = try std.fmt.allocPrint(arena, "image-{d}{s}", .{ i, extFromMime(mime) });
            try w.file(arena, "image[]", filename, mime, p.bytes);
            i += 1;
        }
        if (self.mask_) |m| {
            const mime = if (m.mime.len == 0) "image/png" else m.mime;
            try w.file(arena, "mask", try std.fmt.allocPrint(arena, "mask{s}", .{extFromMime(mime)}), mime, m.bytes);
        }
        return .{ .boundary = edit_boundary, .body = try w.finish(arena) };
    }

    /// Generate images and return the decoded payload. Mirrors Go
    /// `GenerateImage` / Rust `generate_image`: build the body, POST it, project
    /// the reply — the send seam does URL, headers, middleware and the non-2xx
    /// check, so this terminal is only the composition.
    ///
    /// The parts select the request variant (ADR-096). The MultipartForm
    /// variant (OpenAI with reference images) posts a multipart body; every
    /// other variant posts a JSON body. The URL is the variant's endpoint, or
    /// the provider's main endpoint template when the variant names none.
    pub fn generate(
        self: Image,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !ImageResponse {
        return send.withTransport(&self.ctx, @TypeOf(self).generateWith, self, .{ arena, api_key, prompt });
    }

    /// `generate` over an injected transport (the seam tests mock).
    pub fn generateWith(
        self: Image,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !ImageResponse {
        const cfg = image_gen.imageGenConfig(self.provider) orelse
            return error.UnsupportedImageProvider;
        try self.checkImageParts(try self.resolveModel(cfg));
        const v = try self.variant(cfg);
        try self.checkKnobs(v.shape);
        const endpoint = try imageEndpoint(arena, self.provider, v, self.model_ orelse "");

        if (std.mem.eql(u8, v.shape, image_gen.multipart_form)) {
            const mp = try self.buildEditMultipart(arena, prompt);
            const reply = try send.postRaw(transport, arena, .{
                .provider = self.provider,
                .ctx = &self.ctx,
                .api_key = api_key,
                .endpoint = endpoint,
                .op = .image_generation,
                .model = self.model_ orelse "",
            }, mp.body, try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{mp.boundary}));
            const parsed = std.json.parseFromSliceLeaky(json.Value, arena, reply, .{}) catch
                return error.ApiError;
            return self.withRaw(try parseImageResponse(arena, self.provider, parsed), parsed);
        }

        const body = try self.buildImageBody(arena, prompt);

        const reply_value = try send.postJson(transport, arena, .{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = endpoint,
            .op = .image_generation,
            .model = self.model_ orelse "",
        }, body);

        return self.withRaw(try parseImageResponse(arena, self.provider, reply_value), reply_value);
    }

    /// Set `raw` to the parsed reply when the caller opted in (ADR-014).
    fn withRaw(self: Image, resp: ImageResponse, body: json.Value) ImageResponse {
        var out = resp;
        if (self.raw_) out.raw = body;
        return out;
    }

    /// Reject a mask or safety knob the selected request shape has no field
    /// for, instead of dropping it from the wire (Rust `generate_image`).
    fn checkKnobs(self: Image, shape: []const u8) ValidationError!void {
        const eq = std.mem.eql;
        if (self.mask_ != null and !eq(u8, shape, image_gen.multipart_form))
            return error.MaskUnsupported;
        if (self.safety_filter_ != null) return error.SafetyFilterUnsupported;
        if (self.safety_settings_.len > 0 and !eq(u8, shape, image_gen.inline_parts))
            return error.SafetySettingsUnsupported;
    }

    /// The catalogue entry for the configured model. An unknown model is
    /// rejected, as in the other SDKs (Go `findImageModel`).
    fn resolveModel(self: Image, cfg: image_gen.ImageGenDef) ValidationError!image_gen.ImageModelDef {
        const want = self.model_ orelse return error.UnknownImageModel;
        for (cfg.models) |m|
            if (std.mem.eql(u8, m.model_id, want)) return m;
        return error.UnknownImageModel;
    }

    /// BUG-096: both limits are llmkit wire facts per model. A model that takes
    /// no image input rejects any image part; `max_input_images` 0 means no
    /// llmkit limit, and the provider decides volume. Zig alone also rejects
    /// parts past the builder's fixed `max_image_parts` capacity.
    fn checkImageParts(self: Image, m: image_gen.ImageModelDef) ValidationError!void {
        if (self.image_count_ > 0 and !m.supports_image_input)
            return error.ImageInputUnsupported;
        if (self.parts_overflow_) return error.TooManyImageParts;
        if (m.max_input_images > 0 and self.image_count_ > @as(usize, @intCast(m.max_input_images)))
            return error.TooManyImageParts;
    }
};

/// The multipart filename extension for an image media type. Mirror of Go
/// `extFromMime`.
fn extFromMime(mime: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, mime, "image/png")) return ".png";
    if (eq(u8, mime, "image/jpeg") or eq(u8, mime, "image/jpg")) return ".jpg";
    if (eq(u8, mime, "image/webp")) return ".webp";
    return ".bin";
}

/// The selected variant's endpoint, with `{model}` substituted.
///
/// The variant names an image-specific path when the provider has one (OpenAI
/// `/v1/images/generations` and `/v1/images/edits`, Recraft, xAI). It is EMPTY
/// for Google, whose image requests use the provider's main endpoint template,
/// which is where the model id lives for that shape
/// (`/v1beta/models/{model}:generateContent`). Reading the
/// fallback from the provider spec keeps this config-driven: no arm of this
/// function knows a provider by name.
fn imageEndpoint(
    arena: std.mem.Allocator,
    provider: ProviderName,
    v: image_gen.RequestVariant,
    model_id: []const u8,
) ![]const u8 {
    const template = if (v.endpoint.len > 0)
        v.endpoint
    else
        providers.spec(provider).endpoint;
    return http.substituteModel(arena, template, model_id);
}

/// The Google `generateContent` image body: `contents:[{parts:[...]}]` (no
/// `role`, unlike the chat shape), each reference image as `{inlineData:
/// {mimeType, data}}` (camelCase, base64 data), then the trailing `{text}` part;
/// `generationConfig` carries `responseModalities` and — when set — an
/// `imageConfig` with `aspectRatio`/`imageSize`. Text Parts go out as `{text}`
/// parts in caller order among the images; the prompt follows them (omitted
/// when empty and text Parts exist). `safetySettings` sits at the body root.
/// Mirrors Rust `build_image_body`.
fn buildGoogleImageBody(arena: std.mem.Allocator, img: Image, parts: []const ImagePart, prompt: []const u8) BuildError!json.Value {
    var wire = json.array(arena);
    var has_text = false;
    for (parts) |part| switch (part) {
        .image => |p| {
            var blk = json.object();
            var inl = json.object();
            try json.set(arena, &inl, "mimeType", .{ .string = p.mime });
            try json.set(arena, &inl, "data", .{ .string = try base64Encode(arena, p.bytes) });
            try json.set(arena, &blk, "inlineData", inl);
            try wire.array.append(blk);
        },
        .text => |t| {
            has_text = true;
            var txt = json.object();
            try json.set(arena, &txt, "text", .{ .string = t });
            try wire.array.append(txt);
        },
    };
    if (prompt.len > 0 or !has_text) {
        var txt = json.object();
        try json.set(arena, &txt, "text", .{ .string = prompt });
        try wire.array.append(txt);
    }

    var turn = json.object();
    try json.set(arena, &turn, "parts", wire);
    var contents = json.array(arena);
    try contents.array.append(turn);

    var gen = json.object();
    var modalities = json.array(arena);
    if (img.include_text_) try modalities.array.append(.{ .string = "TEXT" });
    try modalities.array.append(.{ .string = "IMAGE" });
    try json.set(arena, &gen, "responseModalities", modalities);

    var image_config = json.object();
    if (img.aspect_ratio_) |r| try json.set(arena, &image_config, "aspectRatio", .{ .string = r });
    if (img.image_size_) |z| try json.set(arena, &image_config, "imageSize", .{ .string = z });
    if (image_config.object.count() > 0)
        try json.set(arena, &gen, "imageConfig", image_config);

    var body = json.object();
    try json.set(arena, &body, "contents", contents);
    try json.set(arena, &body, "generationConfig", gen);
    if (img.safety_settings_.len > 0) {
        var ss = json.array(arena);
        for (img.safety_settings_) |setting| {
            var entry = json.object();
            try json.set(arena, &entry, "category", .{ .string = setting.category });
            try json.set(arena, &entry, "threshold", .{ .string = setting.threshold });
            try ss.array.append(entry);
        }
        try json.set(arena, &body, "safetySettings", ss);
    }
    return body;
}

/// The OpenAI gpt-image-* generations body (flat JSON): `{model, prompt, size?,
/// quality?, output_format?, background?, n?}`. gpt-image-* always returns
/// base64 via `data[i].b64_json` and rejects `response_format`, so it is never
/// set. Mirrors Rust `build_openai_gen_body`.
fn buildOpenAIGenBody(arena: std.mem.Allocator, img: Image, prompt: []const u8) BuildError!json.Value {
    var body = json.object();
    if (img.model_) |m| try json.set(arena, &body, "model", .{ .string = m });
    try json.set(arena, &body, "prompt", .{ .string = prompt });
    if (img.image_size_) |z| try json.set(arena, &body, "size", .{ .string = z });
    if (img.quality_) |q| try json.set(arena, &body, "quality", .{ .string = q });
    if (img.output_format_) |f| try json.set(arena, &body, "output_format", .{ .string = f });
    if (img.background_) |bg| try json.set(arena, &body, "background", .{ .string = bg });
    if (img.count_) |n| try json.set(arena, &body, "n", .{ .integer = n });
    return body;
}

/// The xAI Grok body for `/v1/images/generations` (text only) and
/// `/v1/images/edits` (with reference images): `{model, prompt,
/// response_format: "b64_json", aspect_ratio?, resolution?, n?}`. Image size
/// maps to `resolution` (xAI's name). `response_format` is forced because xAI
/// defaults to URL delivery. One image part -> `image: {url: "data:..."}`;
/// several -> `images: [{url: "data:..."}, ...]` in caller order; none -> no
/// image field. Mirrors Go `buildXAIBody`.
fn buildXAIBody(arena: std.mem.Allocator, img: Image, parts: []const ImagePart, prompt: []const u8) BuildError!json.Value {
    var body = json.object();
    if (img.model_) |m| try json.set(arena, &body, "model", .{ .string = m });
    try json.set(arena, &body, "prompt", .{ .string = prompt });
    try json.set(arena, &body, "response_format", .{ .string = "b64_json" });
    if (img.aspect_ratio_) |r| try json.set(arena, &body, "aspect_ratio", .{ .string = r });
    if (img.image_size_) |z| try json.set(arena, &body, "resolution", .{ .string = z });
    if (img.count_) |n| try json.set(arena, &body, "n", .{ .integer = n });

    var refs = json.array(arena);
    for (parts) |part| {
        const p = switch (part) {
            .image => |x| x,
            .text => continue,
        };
        const mime = if (p.mime.len == 0) "image/png" else p.mime;
        const url = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ mime, try base64Encode(arena, p.bytes) });
        var ref = json.object();
        try json.set(arena, &ref, "url", .{ .string = url });
        try refs.array.append(ref);
    }
    switch (refs.array.items.len) {
        0 => {},
        1 => try json.set(arena, &body, "image", refs.array.items[0]),
        else => try json.set(arena, &body, "images", refs),
    }
    return body;
}

/// The Recraft generations body (flat JSON): `{model, prompt, response_format:
/// "b64_json", size?, n?}`. `response_format` is forced to `b64_json` because
/// Recraft defaults to URL delivery — forcing it keeps the response shape uniform
/// (data[].b64_json). Vector/SVG output is selected by the model id, not a body
/// flag. Mirrors Rust `build_recraft_gen_body`.
fn buildRecraftGenBody(arena: std.mem.Allocator, img: Image, prompt: []const u8) BuildError!json.Value {
    var body = json.object();
    if (img.model_) |m| try json.set(arena, &body, "model", .{ .string = m });
    try json.set(arena, &body, "prompt", .{ .string = prompt });
    try json.set(arena, &body, "response_format", .{ .string = "b64_json" });
    if (img.image_size_) |z| try json.set(arena, &body, "size", .{ .string = z });
    if (img.count_) |n| try json.set(arena, &body, "n", .{ .integer = n });
    return body;
}

/// The Recraft generations body plus `input_references`: each image part, in
/// caller order, as an OpenRouter ContentPartImage `{type:"image_url",
/// image_url:{url}}` with the bytes as a base64 data URL (live probe
/// 2026-10-18). Mirrors Go `dispatchImageHTTP` for JSONGenerationsInputRefs.
fn buildInputRefsBody(arena: std.mem.Allocator, img: Image, parts: []const ImagePart, prompt: []const u8) BuildError!json.Value {
    var body = try buildRecraftGenBody(arena, img, prompt);
    var refs = json.array(arena);
    for (parts) |part| {
        const p = switch (part) {
            .image => |x| x,
            .text => continue,
        };
        const mime = if (p.mime.len == 0) "image/png" else p.mime;
        const url = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ mime, try base64Encode(arena, p.bytes) });
        var image_url = json.object();
        try json.set(arena, &image_url, "url", .{ .string = url });
        var ref = json.object();
        try json.set(arena, &ref, "type", .{ .string = "image_url" });
        try json.set(arena, &ref, "image_url", image_url);
        try refs.array.append(ref);
    }
    try json.set(arena, &body, "input_references", refs);
    return body;
}

/// Project a parsed provider image REPLY into the normalized `ImageResponse`,
/// dispatched on the provider's generated `response_shape` fact (BUG-024) —
/// never a provider-name switch. Usage is read through the config's dotted
/// `usage_*_path` facts (empty path -> unreported, not zero). Mirrors the
/// `match img_cfg.response_shape` block in Rust `generate_image`.
pub fn parseImageResponse(arena: std.mem.Allocator, provider: ProviderName, raw: json.Value) ParseError!ImageResponse {
    const cfg = image_gen.imageGenConfig(provider) orelse
        return error.UnsupportedImageProvider;

    if (std.mem.eql(u8, cfg.response_shape, "DataArrayB64Json"))
        return parseDataArrayB64Json(arena, raw, cfg.usage_input_path, cfg.usage_output_path, cfg.usage_reasoning_path);
    return parseGoogleParts(arena, raw, cfg.usage_input_path, cfg.usage_output_path, cfg.usage_reasoning_path);
}

/// Decode the `data[].b64_json` shape (OpenAI / xAI / Recraft). SVG bytes
/// (Recraft vector models) are sniffed to image/svg+xml; raster bytes never
/// start with '<', so the sniff is a no-op for them. Usage from the dotted paths.
fn parseDataArrayB64Json(arena: std.mem.Allocator, raw: json.Value, input_path: []const u8, output_path: []const u8, reasoning_path: []const u8) ParseError!ImageResponse {
    var images: std.ArrayList(ImageData) = .empty;
    var revised: std.ArrayList([]const u8) = .empty;
    if (json.getPath(raw, "data")) |data| {
        if (std.meta.activeTag(data) == .array) {
            for (data.array.items) |entry| {
                if (getString(entry, "b64_json")) |b64| {
                    if (b64.len > 0) {
                        const decoded = base64Decode(arena, b64) catch continue;
                        var mime: []const u8 = getString(entry, "mime_type") orelse "";
                        if (mime.len == 0) mime = "image/png";
                        if (std.mem.eql(u8, mime, "image/png") and looksLikeSvg(decoded))
                            mime = "image/svg+xml";
                        try images.append(arena, .{ .mime_type = mime, .bytes = decoded });
                    }
                }
                if (getString(entry, "revised_prompt")) |rp| {
                    if (rp.len > 0) try revised.append(arena, rp);
                }
            }
        }
    }
    return .{
        .images = try images.toOwnedSlice(arena),
        .text = try std.mem.join(arena, "\n", revised.items),
        .usage = .{ .input = intAt(raw, input_path), .output = intAt(raw, output_path), .reasoning = response.optInt(raw, reasoning_path) },
        .finish_reason = null,
        .finish_message = null,
        .raw = null,
    };
}

/// Decode the Google `candidates[0].content.parts[].inlineData` shape. Usage
/// from the dotted paths. Mirrors Rust `extract_google_image_parts`.
fn parseGoogleParts(arena: std.mem.Allocator, raw: json.Value, input_path: []const u8, output_path: []const u8, reasoning_path: []const u8) ParseError!ImageResponse {
    var images: std.ArrayList(ImageData) = .empty;
    var text: std.ArrayList([]const u8) = .empty;
    var finish_reason: []const u8 = "";
    var finish_message: []const u8 = "";

    if (json.getPath(raw, "candidates[0]")) |first| {
        finish_reason = getString(first, "finishReason") orelse "";
        finish_message = getString(first, "finishMessage") orelse "";
        if (json.getPath(first, "content.parts")) |parts| {
            if (std.meta.activeTag(parts) == .array) {
                for (parts.array.items) |part| {
                    if (json.getPath(part, "inlineData")) |inline_data| {
                        const data = getString(inline_data, "data") orelse "";
                        const mime = getString(inline_data, "mimeType") orelse "";
                        if (data.len > 0) {
                            const decoded = base64Decode(arena, data) catch continue;
                            try images.append(arena, .{ .mime_type = mime, .bytes = decoded });
                        }
                    }
                    if (getString(part, "text")) |t| {
                        if (t.len > 0) try text.append(arena, t);
                    }
                }
            }
        }
    }
    return .{
        .images = try images.toOwnedSlice(arena),
        .text = try std.mem.join(arena, "", text.items),
        .usage = .{ .input = intAt(raw, input_path), .output = intAt(raw, output_path), .reasoning = response.optInt(raw, reasoning_path) },
        .finish_reason = optString(finish_reason),
        .finish_message = optString(finish_message),
        .raw = null,
    };
}

/// Read a string field off an object Value; null when absent or not a string.
fn getString(v: json.Value, key: []const u8) ?[]const u8 {
    if (std.meta.activeTag(v) != .object) return null;
    const got = v.object.get(key) orelse return null;
    return switch (got) {
        .string => |s| s,
        else => null,
    };
}

/// Read an integer at a dotted path; empty path or a missing/non-numeric value
/// yields null — an unreported dimension is absent, not zero (ADR-081).
fn intAt(raw: json.Value, path: []const u8) i64 {
    if (path.len == 0) return 0;
    const v = json.getPath(raw, path) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

/// Report whether the decoded bytes are an SVG document (XML prolog or a leading
/// `<svg`). Labels Recraft vector output image/svg+xml when the provider echoes
/// no mime type. Raster bytes never start with '<', so this is a no-op for them.
fn looksLikeSvg(data: []const u8) bool {
    const s = std.mem.trimStart(u8, data, " \t\r\n");
    return std.mem.startsWith(u8, s, "<?xml") or std.mem.startsWith(u8, s, "<svg");
}

/// Standard-alphabet, padded base64 encode of `bytes` into `arena`.
fn base64Encode(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try arena.alloc(u8, enc.calcSize(bytes.len));
    return enc.encode(buf, bytes);
}

/// Standard-alphabet, padded base64 decode of `b64` into `arena`.
fn base64Decode(arena: std.mem.Allocator, b64: []const u8) ![]const u8 {
    const dec = std.base64.standard.Decoder;
    const buf = try arena.alloc(u8, try dec.calcSizeForSlice(b64));
    try dec.decode(buf, b64);
    return buf;
}

/// A `Ctx` for the pure-seam tests below. Those tests exercise body/header
/// construction only, so the transport dependencies are never used — but Zig
/// has no ambient allocator or `Io`, so they must still be named.
fn testCtx() http.Ctx {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io };
}







































































































































































































































































































































































































// === HANDOFF-086: text Parts, mask, safety knobs, raw, builder middleware ===

fn testImage(gpa: std.mem.Allocator, provider: ProviderName) Image {
    return .{ .provider = provider, .ctx = .{ .gpa = gpa, .io = std.testing.io } };
}







































































































/// Counts every middleware event it sees.
const TestCounter = struct {
    calls: usize = 0,

    fn call(ptr: *anyopaque, _: *const middleware.Event) ?[]const u8 {
        const self: *TestCounter = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return null;
    }

    fn hook(self: *TestCounter) middleware.Middleware {
        return .{ .ptr = self, .call_fn = call };
    }
};
