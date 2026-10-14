//! Multimodal input Part serialization (ADR-060 / Slice E).
//!
//! The atom is a `Part` (text | image | file); the ChatCompletion text path
//! carries the media Parts (image/file) that precede the trailing prompt-text
//! Part in the user turn, in caller order. Each of the four chat wire shapes
//! serializes those Parts differently (OpenAI `image_url`/`file`, Anthropic
//! `image`/`document`, Google `inline_data`, Bedrock Converse `image`); this
//! module holds those per-provider content builders so `request.zig` stays the
//! shape-dispatch seam without growing past the file-size budget. The builders
//! take the raw media slice + prompt (never the whole config) so this module
//! has no dependency back on `request.zig`. Mirrors Rust
//! `build_flat_content_parts` / `build_google_parts` /
//! `build_bedrock_content_parts` and Go's `splitTextAndImages`.

const std = @import("std");
const json = @import("json.zig");

/// A non-text input Part on the ChatCompletion text path. `image` holds RAW
/// bytes — the builders base64-encode them per provider; `file` holds an
/// uploaded file id.
pub const MediaPart = union(enum) {
    image: Image,
    file: []const u8,

    pub const Image = struct {
        mime: []const u8,
        bytes: []const u8,
    };
};

/// The `ChatOpenAI` user-turn content. With no media Parts it is a bare prompt
/// string (byte-identical to the pre-ADR-060 shape). With media it is an ARRAY
/// of typed content blocks — each file Part as `{type:"file",file:{file_id}}`,
/// each image Part as `{type:"image_url",image_url:{url:<data URI>,detail:
/// "auto"}}` — followed by the trailing `{type:"text",text}` block. Mirrors
/// Rust `build_flat_content_parts` (non-Anthropic arm).
pub fn openAIUserContent(arena: std.mem.Allocator, media: []const MediaPart, prompt: []const u8) !json.Value {
    if (media.len == 0) return .{ .string = prompt };

    var arr = json.array(arena);
    for (media) |part| switch (part) {
        .file => |id| {
            var blk = json.object();
            try json.set(arena, &blk, "type", .{ .string = "file" });
            var f = json.object();
            try json.set(arena, &f, "file_id", .{ .string = id });
            try json.set(arena, &blk, "file", f);
            try arr.array.append(blk);
        },
        .image => |img| {
            const uri = try dataUri(arena, img);
            var blk = json.object();
            try json.set(arena, &blk, "type", .{ .string = "image_url" });
            var iu = json.object();
            try json.set(arena, &iu, "url", .{ .string = uri });
            try json.set(arena, &iu, "detail", .{ .string = "auto" });
            try json.set(arena, &blk, "image_url", iu);
            try arr.array.append(blk);
        },
    };
    try arr.array.append(try textBlock(arena, prompt));
    return arr;
}

/// The `ChatAnthropic` user-turn content. Bare prompt string with no media;
/// otherwise an ARRAY of typed blocks — each file Part as `{type:"document",
/// source:{type:"file",file_id}}`, each image Part as `{type:"image",source:
/// {type:"base64",media_type,data}}` — then the trailing `{type:"text",text}`
/// block. Mirrors Rust `build_flat_content_parts` (Anthropic arm).
pub fn anthropicUserContent(arena: std.mem.Allocator, media: []const MediaPart, prompt: []const u8) !json.Value {
    if (media.len == 0) return .{ .string = prompt };

    var arr = json.array(arena);
    for (media) |part| switch (part) {
        .file => |id| {
            var blk = json.object();
            try json.set(arena, &blk, "type", .{ .string = "document" });
            var src = json.object();
            try json.set(arena, &src, "type", .{ .string = "file" });
            try json.set(arena, &src, "file_id", .{ .string = id });
            try json.set(arena, &blk, "source", src);
            try arr.array.append(blk);
        },
        .image => |img| {
            const b64 = try base64Encode(arena, img.bytes);
            var blk = json.object();
            try json.set(arena, &blk, "type", .{ .string = "image" });
            var src = json.object();
            try json.set(arena, &src, "type", .{ .string = "base64" });
            try json.set(arena, &src, "media_type", .{ .string = img.mime });
            try json.set(arena, &src, "data", .{ .string = b64 });
            try json.set(arena, &blk, "source", src);
            try arr.array.append(blk);
        },
    };
    try arr.array.append(try textBlock(arena, prompt));
    return arr;
}

/// The `ChatGoogle` user-turn `parts`: each image Part as `{inline_data:
/// {mime_type,data}}` (base64 data, no `type` key), then the trailing bare
/// `{text}` part. With no media this reduces to `[{text}]`. Mirrors Rust
/// `build_google_parts` (image arm; the google file `file_data` arm has no
/// fixture in this slice).
pub fn googleParts(arena: std.mem.Allocator, media: []const MediaPart, prompt: []const u8) !json.Value {
    var parts = json.array(arena);
    for (media) |part| switch (part) {
        .image => |img| {
            const b64 = try base64Encode(arena, img.bytes);
            var blk = json.object();
            var inl = json.object();
            try json.set(arena, &inl, "mime_type", .{ .string = img.mime });
            try json.set(arena, &inl, "data", .{ .string = b64 });
            try json.set(arena, &blk, "inline_data", inl);
            try parts.array.append(blk);
        },
        .file => {},
    };
    var txt = json.object();
    try json.set(arena, &txt, "text", .{ .string = prompt });
    try parts.array.append(txt);
    return parts;
}

/// The `ChatBedrock` (Converse) user-turn `content`: each image Part as an
/// `{image:{format,source:{bytes}}}` block where `format` is the MIME subtype
/// (`image/png` -> `"png"`) and `bytes` is base64, then the trailing bare
/// `{text}` block. With no media this reduces to `[{text}]`. Mirrors Rust
/// `build_bedrock_content_parts`.
pub fn bedrockContent(arena: std.mem.Allocator, media: []const MediaPart, prompt: []const u8) !json.Value {
    var content = json.array(arena);
    for (media) |part| switch (part) {
        .image => |img| {
            const b64 = try base64Encode(arena, img.bytes);
            var blk = json.object();
            var im = json.object();
            try json.set(arena, &im, "format", .{ .string = mimeSubtype(img.mime) });
            var src = json.object();
            try json.set(arena, &src, "bytes", .{ .string = b64 });
            try json.set(arena, &im, "source", src);
            try json.set(arena, &blk, "image", im);
            try content.array.append(blk);
        },
        .file => {},
    };
    var txt = json.object();
    try json.set(arena, &txt, "text", .{ .string = prompt });
    try content.array.append(txt);
    return content;
}

/// A `{"type":"text","text":<s>}` OpenAI/Anthropic content block.
fn textBlock(arena: std.mem.Allocator, text: []const u8) !json.Value {
    var blk = json.object();
    try json.set(arena, &blk, "type", .{ .string = "text" });
    try json.set(arena, &blk, "text", .{ .string = text });
    return blk;
}

/// Builds the OpenAI `data:<mime>;base64,<b64>` URI for an image Part.
fn dataUri(arena: std.mem.Allocator, img: MediaPart.Image) ![]const u8 {
    const b64 = try base64Encode(arena, img.bytes);
    return std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ img.mime, b64 });
}

/// Standard-alphabet, padded base64 of `bytes` into `arena` — the encoding the
/// wire goldens' `data` / `bytes` / data-URI slots carry.
fn base64Encode(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try arena.alloc(u8, enc.calcSize(bytes.len));
    return enc.encode(buf, bytes);
}

/// The MIME subtype after the last `/` (`image/png` -> `png`) — the Bedrock
/// Converse `format` token.
fn mimeSubtype(mime: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, mime, '/')) |i| return mime[i + 1 ..];
    return mime;
}

// "PNG" base64-encodes to "UE5H"; "JPG" to "SlBH".
const test_media = [_]MediaPart{
    .{ .file = "file-abc123" },
    .{ .image = .{ .mime = "image/png", .bytes = "PNG" } },
};





















































