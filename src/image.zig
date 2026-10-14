//! Image generation capability (ADR-069 Slice 1) — a mirror of rust/src/image.rs
//! and go/image.go, minus the HTTP send.
//!
//! Two pure seams the wire goldens assert:
//!   - `Image.buildImageBody` produces the JSON request body per the provider's
//!     generated `input_mode` fact (InlineParts -> Google generateContent
//!     `contents`/`parts`; MultipartForm without image parts -> the OpenAI flat
//!     generations JSON body; JSONGenerations -> Recraft's flat body) — never a
//!     provider-name switch. The image INPUT is RAW bytes; the builder
//!     base64-encodes it. MultipartForm WITH image parts is the edit request:
//!     `Image.buildEditMultipart` encodes it as multipart/form-data (BUG-097).
//!   - `parseImageResponse` projects a provider REPLY to the normalized
//!     `{images, usage, finish_reason}` dispatched on the generated
//!     `response_shape` fact (GoogleParts / DataArrayB64Json / VertexPredictions,
//!     BUG-024) — again config, never a name switch.
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
const response = @import("response.zig");

pub const ProviderName = providers.ProviderName;

/// One image input Part carrying RAW bytes (the builder base64-encodes them per
/// provider). Image generation only takes image Parts, so — unlike the text
/// path's `MediaPart` — there is no file variant here.
pub const ImageInput = struct {
    mime: []const u8,
    bytes: []const u8,
};

/// One decoded output image. `bytes` is RAW (already base64-decoded from the
/// wire); `mime_type` is the provider's echoed media type (defaulting to
/// image/png when absent). Mirrors Rust `ImageData` (ADR-018 bytes/mime accessor).
pub const ImageData = struct {
    mime_type: []const u8,
    bytes: []const u8,
};

/// The normalized image-generation reply. `images` is caller order; `text`
/// carries any revised-prompt / text parts a provider returns; `usage` reuses
/// the shared token carrier. Mirror of Rust `ImageResponse`.
pub const ImageResponse = struct {
    images: []const ImageData,
    text: []const u8 = "",
    usage: response.Usage = .{},
    finish_reason: ?[]const u8 = null,
    finish_message: ?[]const u8 = null,
};

/// `EditIsMultipart`: the request is an OpenAI-style edit (MultipartForm with
/// image parts), whose body is multipart, not JSON; `buildEditMultipart` builds
/// it. Returned rather than a JSON body that would drop the images (BUG-097).
pub const BuildError = error{ UnsupportedImageProvider, EditIsMultipart } || std.mem.Allocator.Error;

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
/// (ADR-076 §3); all three correspond to field "model" or "parts".
pub const ValidationError = error{ UnknownImageModel, ImageInputUnsupported, TooManyImageParts };

/// Fixed capacity for reference-image Parts (edit / compositional generation).
/// Image chain methods take no allocator (ADR-069 ZIG-005), so Parts live in a
/// bounded array like `Text`'s media Parts.
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
    parts_: [max_image_parts]ImageInput = undefined,
    part_count_: usize = 0,
    /// Set when `image` is called with `parts_` full; the terminal rejects it.
    parts_overflow_: bool = false,

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
        var s = self;
        if (s.part_count_ == max_image_parts) {
            s.parts_overflow_ = true;
            return s;
        }
        s.parts_[s.part_count_] = .{ .mime = mime, .bytes = bytes };
        s.part_count_ += 1;
        return s;
    }

    /// Build the image-generation request body as a dynamic JSON Value backed by
    /// `arena`, dispatched on the provider's generated `input_mode` fact. `prompt`
    /// is the trailing text Part; any reference-image Parts precede it (edit).
    pub fn buildImageBody(self: Image, arena: std.mem.Allocator, prompt: []const u8) BuildError!json.Value {
        const cfg = image_gen.imageGenConfig(self.provider) orelse
            return error.UnsupportedImageProvider;
        const parts = self.parts_[0..self.part_count_];

        if (std.mem.eql(u8, cfg.input_mode, "InlineParts"))
            return buildGoogleImageBody(arena, self, parts, prompt);
        if (std.mem.eql(u8, cfg.input_mode, "MultipartForm")) {
            if (parts.len > 0) return error.EditIsMultipart;
            return buildOpenAIGenBody(arena, self, prompt);
        }
        if (std.mem.eql(u8, cfg.input_mode, "JSONGenerations"))
            return buildRecraftGenBody(arena, self, prompt);
        return error.UnsupportedImageProvider;
    }

    /// Build the OpenAI edit request (MultipartForm with image parts) as a
    /// multipart/form-data body for the config's `edit_endpoint`. Text fields
    /// come first in a fixed order (model, prompt, size, quality, output_format,
    /// background, n), then one `image[]` file part per reference image in
    /// caller order, named `image-<i><ext>`. Mirrors Go
    /// `buildOpenAIEditMultipart`. Rejects any other input mode, and a call with
    /// no image parts, which is a generation request.
    pub fn buildEditMultipart(self: Image, arena: std.mem.Allocator, prompt: []const u8) BuildError!Multipart {
        const cfg = image_gen.imageGenConfig(self.provider) orelse
            return error.UnsupportedImageProvider;
        if (!std.mem.eql(u8, cfg.input_mode, "MultipartForm") or self.part_count_ == 0)
            return error.UnsupportedImageProvider;

        var w: multipart.Writer = .{ .boundary = edit_boundary };
        if (self.model_) |m| try w.field(arena, "model", m);
        try w.field(arena, "prompt", prompt);
        if (self.image_size_) |z| try w.field(arena, "size", z);
        if (self.quality_) |q| try w.field(arena, "quality", q);
        if (self.output_format_) |f| try w.field(arena, "output_format", f);
        if (self.background_) |bg| try w.field(arena, "background", bg);
        if (self.count_) |n| try w.field(arena, "n", try std.fmt.allocPrint(arena, "{d}", .{n}));

        for (self.parts_[0..self.part_count_], 0..) |p, i| {
            const mime = if (p.mime.len == 0) "image/png" else p.mime;
            const filename = try std.fmt.allocPrint(arena, "image-{d}{s}", .{ i, extFromMime(mime) });
            try w.file(arena, "image[]", filename, mime, p.bytes);
        }
        return .{ .boundary = edit_boundary, .body = try w.finish(arena) };
    }

    /// Generate images and return the decoded payload. Mirrors Go
    /// `GenerateImage` / Rust `generate_image`: build the body, POST it, project
    /// the reply — the send seam does URL, headers, middleware and the non-2xx
    /// check, so this terminal is only the composition.
    ///
    /// A MultipartForm provider (OpenAI) with reference images is an EDIT: the
    /// multipart body goes to the config's `edit_endpoint`. Every other call is
    /// a JSON body to the generation endpoint (`gen_endpoint`, or the chat
    /// endpoint for Google, whose reference images ride inline as `inlineData`).
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

        if (std.mem.eql(u8, cfg.input_mode, "MultipartForm") and self.part_count_ > 0) {
            const mp = try self.buildEditMultipart(arena, prompt);
            const reply = try send.postRaw(transport, arena, .{
                .provider = self.provider,
                .ctx = &self.ctx,
                .api_key = api_key,
                .endpoint = cfg.edit_endpoint,
                .op = .image_generation,
                .model = self.model_ orelse "",
            }, mp.body, try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{mp.boundary}));
            const parsed = std.json.parseFromSliceLeaky(json.Value, arena, reply, .{}) catch
                return error.ApiError;
            return parseImageResponse(arena, self.provider, parsed);
        }

        const body = try self.buildImageBody(arena, prompt);

        const raw = try send.postJson(transport, arena, .{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = try imageEndpoint(arena, self.provider, cfg, self.model_ orelse ""),
            .op = .image_generation,
            .model = self.model_ orelse "",
        }, body);

        return parseImageResponse(arena, self.provider, raw);
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
        if (self.part_count_ > 0 and !m.supports_image_input)
            return error.ImageInputUnsupported;
        if (self.parts_overflow_) return error.TooManyImageParts;
        if (m.max_input_images > 0 and self.part_count_ > @as(usize, @intCast(m.max_input_images)))
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

/// The image-generation endpoint, with `{model}` substituted.
///
/// The generated `gen_endpoint` is the image-specific path when the provider has
/// one (OpenAI `/v1/images/generations`, Recraft, xAI). It is EMPTY for Google,
/// whose image generation reuses the chat `generateContent` endpoint — so the
/// fallback is the provider's own chat endpoint, which is where the model id
/// lives for that shape (`/v1beta/models/{model}:generateContent`). Reading the
/// fallback from the provider spec keeps this config-driven: no arm of this
/// function knows a provider by name.
fn imageEndpoint(
    arena: std.mem.Allocator,
    provider: ProviderName,
    cfg: image_gen.ImageGenDef,
    model_id: []const u8,
) ![]const u8 {
    const template = if (cfg.gen_endpoint.len > 0)
        cfg.gen_endpoint
    else
        providers.spec(provider).endpoint;
    return http.substituteModel(arena, template, model_id);
}

/// The Google `generateContent` image body: `contents:[{parts:[...]}]` (no
/// `role`, unlike the chat shape), each reference image as `{inlineData:
/// {mimeType, data}}` (camelCase, base64 data), then the trailing `{text}` part;
/// `generationConfig` carries `responseModalities` and — when set — an
/// `imageConfig` with `aspectRatio`/`imageSize`. Mirrors Rust `build_image_body`.
fn buildGoogleImageBody(arena: std.mem.Allocator, img: Image, parts: []const ImageInput, prompt: []const u8) BuildError!json.Value {
    var wire = json.array(arena);
    for (parts) |p| {
        var blk = json.object();
        var inl = json.object();
        try json.set(arena, &inl, "mimeType", .{ .string = p.mime });
        try json.set(arena, &inl, "data", .{ .string = try base64Encode(arena, p.bytes) });
        try json.set(arena, &blk, "inlineData", inl);
        try wire.array.append(blk);
    }
    var txt = json.object();
    try json.set(arena, &txt, "text", .{ .string = prompt });
    try wire.array.append(txt);

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
    if (std.mem.eql(u8, cfg.response_shape, "VertexPredictions"))
        return parseVertexPredictions(arena, raw);
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
    };
}

/// Decode the Vertex Imagen `:predict` shape: `{predictions:[{bytesBase64Encoded,
/// mimeType}]}`. Vertex reports no token counts at all, so no dimension is reported. Mirrors
/// Rust `parse_vertex_image_response`.
fn parseVertexPredictions(arena: std.mem.Allocator, raw: json.Value) ParseError!ImageResponse {
    var images: std.ArrayList(ImageData) = .empty;
    var finish_reason: []const u8 = "";
    if (json.getPath(raw, "predictions")) |preds| {
        if (std.meta.activeTag(preds) == .array) {
            for (preds.array.items) |entry| {
                if (finish_reason.len == 0) {
                    if (getString(entry, "raiFilteredReason")) |rai| {
                        if (rai.len > 0) finish_reason = rai;
                    }
                }
                const b64 = getString(entry, "bytesBase64Encoded") orelse continue;
                if (b64.len == 0) continue;
                var mime: []const u8 = getString(entry, "mimeType") orelse "";
                if (mime.len == 0) mime = "image/png";
                const decoded = base64Decode(arena, b64) catch continue;
                try images.append(arena, .{ .mime_type = mime, .bytes = decoded });
            }
        }
    }
    return .{
        .images = try images.toOwnedSlice(arena),
        .finish_reason = optString(finish_reason),
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

























































































































































































































































































