//! The Files API (ADR-060) — HANDOFF-046 slice 1.
//!
//! Upload bytes, get back a provider file id, attach it to a later request with
//! `Text.file(id)`. Everything that varies per provider — the endpoint, the form
//! field name, the extra form fields, the beta header, and the dotted path the
//! id is read from — comes from the generated `FileUploadDef`, never a
//! provider-name switch.
//!
//! Zig was the only SDK without this entry point at Phase 5 (the `upload`
//! MiddlewareOp had to be exempted from `rule_middleware_op_unfired` because
//! nothing could fire it). Swift hit the identical gap at its Phase 4 and closed
//! it the same way (CR-004) — a capability that can REFERENCE files but not
//! CREATE them is a parity gap the byte goldens cannot see, because there are no
//! bytes until someone can send.
//!
//! Filename escaping (HANDOFF-036 A2): Go, Java and Swift all splice
//! `name="…"; filename="…"` unescaped, so a quote or CRLF in a filename corrupts
//! the part header. The shared `multipart.zig` encoder escapes, matching Go's
//! stdlib `escapeQuotes` rather than Go's own hand-rolled multipart writer.

const std = @import("std");
const json = @import("json.zig");
const http = @import("http.zig");
const send = @import("send.zig");
const multipart = @import("multipart.zig");
const providers = @import("providers/generated/providers.zig");
const request_defs = @import("providers/generated/request_defs.zig");

pub const ProviderName = providers.ProviderName;

pub const UploadError = error{
    UnsupportedUploadProvider,
    MissingFileId,
} || std.mem.Allocator.Error;

/// A fixed, deterministic multipart boundary — the same choice (and the same
/// reasoning) as `transcription.zig`: the decoder reads whatever boundary the
/// encoder declares, so randomness buys nothing and costs reproducibility.
const boundary_str = "----llmkitZigUploadBoundary7MA4YWxkTrZu0gW";

/// An uploaded file as the provider reports it. `id` is the value to hand to
/// `Text.file(...)`; the other fields are populated only when the provider's
/// config declares a path for them.
pub const File = @import("providers/generated/structs.zig").File;

/// The public Upload builder. Immutable value type, like every other builder.
pub const Upload = struct {
    provider: ProviderName,
    ctx: http.Ctx,
    filename_: []const u8 = "upload.bin",
    mime_: []const u8 = "application/octet-stream",

    /// The filename reported to the provider (some providers infer the format
    /// from its extension). ADR-021 bare-noun replacer.
    pub fn filename(self: Upload, name: []const u8) Upload {
        var s = self;
        s.filename_ = name;
        return s;
    }

    /// The IANA media type of the bytes. ADR-021 bare-noun replacer.
    pub fn mime(self: Upload, mime_type: []const u8) Upload {
        var s = self;
        s.mime_ = mime_type;
        return s;
    }

    /// Upload `bytes` and return the provider file reference. Named `run`
    /// because the builder already says what is happening (`client.upload()
    /// .filename("q3.pdf").run(...)`) — the same terminal name Rust, Swift and
    /// Java use for this capability.
    pub fn run(self: Upload, arena: std.mem.Allocator, api_key: []const u8, bytes: []const u8) !File {
        return send.withTransport(&self.ctx, @TypeOf(self).runWith, self, .{ arena, api_key, bytes });
    }

    /// `run` over an injected transport (the seam tests mock).
    pub fn runWith(
        self: Upload,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        bytes: []const u8,
    ) !File {
        const cfg = request_defs.fileUploadConfig(self.provider) orelse
            return error.UnsupportedUploadProvider;

        const body = try encodeMultipart(arena, cfg, self.filename_, self.mime_, bytes);

        var extra: std.ArrayList(http.Header) = .empty;
        if (cfg.beta_header.len > 0)
            try extra.append(arena, .{ .name = "anthropic-beta", .value = cfg.beta_header });

        const raw = try send.postRaw(transport, arena, .{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = cfg.endpoint,
            .extra_headers = extra.items,
            .op = .upload,
        }, body, try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{boundary_str}));

        const parsed = std.json.parseFromSliceLeaky(json.Value, arena, raw, .{}) catch
            return error.MissingFileId;

        return .{
            .id = stringAt(parsed, cfg.response_id_path) orelse return error.MissingFileId,
            .uri = stringAt(parsed, cfg.response_uri_path) orelse "",
            .name = stringAt(parsed, cfg.response_name_path) orelse "",
            .mime_type = stringAt(parsed, cfg.response_mime_path) orelse "",
        };
    }
};

/// Encode the upload form: the provider's `extra_fields_json` as text fields
/// first (OpenAI's `purpose`, Anthropic's absence of one), then the file part
/// under the config's `field_name`.
fn encodeMultipart(
    arena: std.mem.Allocator,
    cfg: request_defs.FileUploadDef,
    name: []const u8,
    mime_type: []const u8,
    bytes: []const u8,
) ![]const u8 {
    var w: multipart.Writer = .{ .boundary = boundary_str };

    if (cfg.extra_fields_json.len > 0) {
        if (std.json.parseFromSliceLeaky(json.Value, arena, cfg.extra_fields_json, .{})) |extra| {
            if (extra == .object) {
                var it = extra.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .string) continue;
                    try w.field(arena, entry.key_ptr.*, entry.value_ptr.string);
                }
            }
        } else |_| {}
    }

    const field = if (cfg.field_name.len > 0) cfg.field_name else "file";
    const content_type = if (mime_type.len == 0) "application/octet-stream" else mime_type;
    try w.file(arena, field, name, content_type, bytes);
    return w.finish(arena);
}

fn stringAt(value: json.Value, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    const v = json.getPath(value, path) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

// === Tests ===

const testing = std.testing;

fn testUpload(gpa: std.mem.Allocator, provider: ProviderName) Upload {
    return .{ .provider = provider, .ctx = .{ .gpa = gpa, .io = testing.io } };
}








































































