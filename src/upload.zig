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
const middleware = @import("middleware.zig");

pub const ProviderName = providers.ProviderName;

/// `UploadSourceMissing` / `UploadSourceConflict`: set exactly one of `bytes`
/// and `path`. `UploadFilenameRequired`: `bytes` needs a `filename`. Rust
/// reports these as `ValidationError{field: "Upload"}`.
pub const UploadError = error{
    UnsupportedUploadProvider,
    MissingFileId,
    UploadSourceMissing,
    UploadSourceConflict,
    UploadFilenameRequired,
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
/// Set the content with exactly one of `bytes` or `path`. Chain methods only
/// record; `run` reads a `path` through the client's `io` into the arena.
pub const Upload = struct {
    provider: ProviderName,
    ctx: http.Ctx,
    filename_: ?[]const u8 = null,
    mime_type_: []const u8 = "application/octet-stream",
    bytes_: ?[]const u8 = null,
    path_: ?[]const u8 = null,

    /// The bytes to upload. Caller-owned; must outlive the terminal. Requires
    /// `filename`. ADR-021 bare-noun replacer; mirrors Rust `bytes(data)`.
    pub fn bytes(self: Upload, data: []const u8) Upload {
        var s = self;
        s.bytes_ = data;
        return s;
    }

    /// A file to upload, read at `run` relative to the current directory. The
    /// filename defaults to its base name. Mirrors Rust `path(p)`.
    pub fn path(self: Upload, p: []const u8) Upload {
        var s = self;
        s.path_ = p;
        return s;
    }

    /// The filename reported to the provider (some providers infer the format
    /// from its extension). ADR-021 bare-noun replacer.
    pub fn filename(self: Upload, name: []const u8) Upload {
        var s = self;
        s.filename_ = name;
        return s;
    }

    /// The IANA media type of the content (default
    /// `application/octet-stream`). ADR-021 bare-noun replacer; mirrors Rust
    /// `mime_type(m)`.
    pub fn mimeType(self: Upload, mime_type: []const u8) Upload {
        var s = self;
        s.mime_type_ = mime_type;
        return s;
    }

    /// Attach an observation + veto hook to this builder only (ADR-020); see
    /// `Text.addMiddleware`.
    pub fn addMiddleware(self: Upload, m: middleware.Middleware) Upload {
        var s = self;
        s.ctx = s.ctx.withMiddleware(m);
        return s;
    }

    /// Upload the content and return the provider file reference. Named `run`
    /// because the builder already says what is happening (`client.upload()
    /// .path("q3.pdf").run(...)`) — the same terminal name Rust, Swift and
    /// Java use for this capability.
    pub fn run(self: Upload, arena: std.mem.Allocator, api_key: []const u8) !File {
        return send.withTransport(&self.ctx, @TypeOf(self).runWith, self, .{ arena, api_key });
    }

    /// `run` over an injected transport (the seam tests mock).
    pub fn runWith(
        self: Upload,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
    ) !File {
        const cfg = request_defs.fileUploadConfig(self.provider) orelse
            return error.UnsupportedUploadProvider;

        const src = try self.content(arena);
        const body = try encodeMultipart(arena, cfg, src.filename, self.mime_type_, src.bytes);

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

    const Content = struct { filename: []const u8, bytes: []const u8 };

    /// The bytes and filename to send: the `bytes` as given, or the `path` read
    /// into `arena` with its base name as the default filename. The rules
    /// match Rust `upload_run`.
    fn content(self: Upload, arena: std.mem.Allocator) !Content {
        const has_bytes = self.bytes_ != null and self.bytes_.?.len > 0;
        const has_path = self.path_ != null and self.path_.?.len > 0;
        if (!has_bytes and !has_path) return error.UploadSourceMissing;
        if (has_bytes and has_path) return error.UploadSourceConflict;
        if (has_bytes) {
            const name = self.filename_ orelse return error.UploadFilenameRequired;
            if (name.len == 0) return error.UploadFilenameRequired;
            return .{ .filename = name, .bytes = self.bytes_.? };
        }
        const p = self.path_.?;
        const data = try std.Io.Dir.cwd().readFileAlloc(self.ctx.io, p, arena, .unlimited);
        const name = if (self.filename_) |n| (if (n.len > 0) n else std.fs.path.basename(p)) else std.fs.path.basename(p);
        return .{ .filename = name, .bytes = data };
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

















































































































































