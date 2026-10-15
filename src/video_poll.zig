//! Video poll/wait (ADR-034 / ADR-062) — the async half of video generation, a
//! mirror of `wait_video` / `parse_video_poll` in rust/src/video.rs and
//! `VideoHandle.Wait` / `parseVideoPoll` in go/video.go, run on the shared
//! `job.zig` engine.
//!
//! The other SDKs run a hand-written loop; Zig expresses the same steps as the
//! four Job-engine seams, so `VideoHandle` gets the same `poll` (one round-trip)
//! / `wait` (loop over `poll`) pair as `BatchHandle` and `TranscriptionHandle`:
//!   - `poll`: three transport arms chosen from config — SigV4 hosts (Bedrock)
//!     GET with the ARN as one path segment; Vertex Veo POSTs
//!     `{operationName}` to the model-templated `fetchPredictOperation`; every
//!     other provider GETs the `{id}`-templated poll endpoint. PixVerse also
//!     needs a fresh `Ai-trace-id` header on the poll.
//!   - `classify`: per `wire_shape`, because video status is not one string at
//!     one path — PixVerse reports integer codes, Veo/Vertex an LRO `done` flag.
//!     An unknown wire shape is an error, never a silent Running.
//!   - `result`: the per-shape video reference, the MiniMax file-retrieve hop
//!     (`file_endpoint` set), and the `DeliveryDownload` byte fetch (Veo). A
//!     finished job with no usable output (Veo with no uri, Vertex with no
//!     bytes, Bedrock with no S3 uri) is an error, not an empty success.
//!
//! A failed job is a `JobStatus{.failed}` whose `cause.message` carries the
//! provider's message where it gives one. Bedrock caveat: the poll is not
//! SigV4-signed, the same limitation as every other Zig Bedrock send.

const std = @import("std");
const http = @import("http.zig");
const send = @import("send.zig");
const json = @import("json.zig");
const job = @import("job.zig");
const providers = @import("providers/generated/providers.zig");
const request_defs = @import("providers/generated/request_defs.zig");
const video_gen = @import("providers/generated/video_gen.zig");
const structs = @import("providers/generated/structs.zig");

pub const VideoResponse = structs.VideoResponse;
pub const VideoData = structs.VideoData;

/// Default poll cadence for `VideoHandle.wait`. Mirrors Go `videoPollInterval`
/// (5s) and `videoPollTimeout` (10 min).
const poll_interval_ms: u64 = 5000;
const poll_timeout_ms: u64 = 600000;

/// A submitted video job. `value` is the cross-SDK `VideoHandle` value (id,
/// provider, raw, model) — the part a caller persists to resume (ADR-014);
/// `ctx` supplies the base URL override, the `io` for `wait`'s sleep and the
/// PixVerse trace id, and the transport seam.
pub const VideoHandle = struct {
    value: structs.VideoHandle,
    ctx: http.Ctx,
    api_key: []const u8 = "",

    /// One poll round-trip (ADR-063 Poll): poll, classify, and on success
    /// resolve the finished video (file hop and download included).
    pub fn poll(self: VideoHandle, arena: std.mem.Allocator) !job.JobStatus(VideoResponse) {
        return job.pollOnce(VideoAdapter, .{ .handle = self }, arena);
    }

    /// Block until the job reaches a terminal state (ADR-063 Wait — a thin loop
    /// over `poll`). Gives up at the deadline with `error.PollTimeout`; a
    /// provider failure is a `JobStatus{.failed}`, not that error.
    pub fn wait(self: VideoHandle, arena: std.mem.Allocator) !job.JobStatus(VideoResponse) {
        return job.wait(VideoAdapter, .{ .handle = self }, self.ctx.io, arena);
    }
};

const VideoAdapter = struct {
    handle: VideoHandle,

    pub const Out = VideoResponse;

    fn vgConfig(self: VideoAdapter) !video_gen.VideoGenDef {
        return video_gen.videoGenConfig(self.handle.value.provider) orelse error.UnsupportedVideoProvider;
    }

    /// The video API base: a client override wins, else the provider's distinct
    /// video host, else the chat host. Mirrors Rust `video_base_url`.
    fn base(self: VideoAdapter, vg: video_gen.VideoGenDef) []const u8 {
        if (self.handle.ctx.base_url) |b| return b;
        if (vg.video_base_url.len > 0) return vg.video_base_url;
        return providers.spec(self.handle.value.provider).base_url;
    }

    pub fn config(self: VideoAdapter, arena: std.mem.Allocator) !job.LifecycleConfig {
        _ = arena;
        _ = try self.vgConfig();
        // Classification is the `classify` seam below, so the status facts stay
        // empty; only the cadence comes from here.
        return .{
            .status_path = "",
            .done_values = &.{},
            .error_values = &.{},
            .poll_interval_ms = poll_interval_ms,
            .poll_timeout_ms = poll_timeout_ms,
            .noun = "video",
        };
    }

    pub fn poll(self: VideoAdapter, arena: std.mem.Allocator) !job.PollBody {
        const vg = try self.vgConfig();
        const p = self.handle.value.provider;
        const id = self.handle.value.id;

        var method: http.Method = .GET;
        var body: []const u8 = "";
        var content_type: ?[]const u8 = null;
        const endpoint = if (request_defs.authScheme(p) == .sig_v4)
            // The ARN's '/' must not split into extra path segments; ':' stays
            // literal (Bedrock's canonicalization accepts it). Mirrors Rust
            // `path_escape_arn`.
            try replaceAll(arena, vg.poll_endpoint, "{id}", try replaceAll(arena, id, "/", "%2F"))
        else if (std.mem.eql(u8, vg.wire_shape, "VideoVertexVeo")) blk: {
            // The only POST-poll shape: the model is in the path, the operation
            // name in the body.
            method = .POST;
            var obj = json.object();
            try json.set(arena, &obj, "operationName", .{ .string = id });
            body = try json.stringify(arena, obj);
            content_type = "application/json";
            break :blk try replaceAll(arena, vg.poll_endpoint, "{model}", self.handle.value.model);
        } else try replaceAll(arena, vg.poll_endpoint, "{id}", id);

        var extra: std.ArrayList(http.Header) = .empty;
        if (std.mem.eql(u8, vg.wire_shape, "VideoPixVerse"))
            try extra.append(arena, .{ .name = "Ai-trace-id", .value = try traceId(arena, self.handle.ctx.io) });

        const resp = try self.roundTrip(arena, .{
            .method = method,
            .url = try http.buildUrl(arena, p, self.base(vg), endpoint, self.handle.api_key),
            .headers = try self.headers(arena, extra.items, content_type),
            .body = body,
        });
        return .{ .value = try parseBody(arena, resp.body) };
    }

    pub fn classify(self: VideoAdapter, arena: std.mem.Allocator, pb: job.PollBody) !job.Verdict {
        const vg = try self.vgConfig();
        return classifyVideo(arena, vg.wire_shape, pb.value);
    }

    pub fn result(self: VideoAdapter, arena: std.mem.Allocator, pb: job.PollBody) !Out {
        const vg = try self.vgConfig();
        var resp = if (vg.file_endpoint.len > 0)
            try self.resolveFile(arena, vg, pb.value)
        else
            try videoResult(arena, vg, pb.value);

        // Veo, Vertex Veo and Bedrock must carry their output when done: an
        // empty success would hand the caller nothing to fetch. Mirrors the
        // Rust done-but-empty guards (the other shapes return an empty list).
        if (requiresOutput(vg.wire_shape) and
            (resp.videos.len == 0 or (resp.videos[0].url.len == 0 and resp.videos[0].bytes.len == 0)))
            return error.VideoMissingOutput;

        // Delivery dispatch (VID-005): download-delivery providers return a
        // fetch URI; GET it into bytes and clear the url (source XOR).
        if (std.mem.eql(u8, vg.output_delivery, "DeliveryDownload"))
            resp = try self.download(arena, resp);
        return resp;
    }

    /// The MiniMax two-hop: the terminal poll carries a `file_id`, and the file
    /// endpoint holds the download URL. Mirrors Rust `resolve_video_file`.
    fn resolveFile(self: VideoAdapter, arena: std.mem.Allocator, vg: video_gen.VideoGenDef, poll_body: json.Value) !VideoResponse {
        const file_id = switch (json.getPath(poll_body, "file_id") orelse return error.VideoMissingOutput) {
            .string => |s| s,
            .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
            .number_string => |s| s,
            else => return error.VideoMissingOutput,
        };
        if (file_id.len == 0) return error.VideoMissingOutput;

        const p = self.handle.value.provider;
        const endpoint = try replaceAll(arena, vg.file_endpoint, "{file_id}", file_id);
        const resp = try self.roundTrip(arena, .{
            .method = .GET,
            .url = try http.buildUrl(arena, p, self.base(vg), endpoint, self.handle.api_key),
            .headers = try self.headers(arena, &.{}, null),
        });
        const file_body = try parseBody(arena, resp.body);
        return urlResponse(arena, vg, stringAt(file_body, "file.download_url"), 0);
    }

    /// Fetch each video URL into bytes (query-param auth carried when the
    /// provider uses it). Mirrors Rust `download_video_bytes`.
    fn download(self: VideoAdapter, arena: std.mem.Allocator, resp: VideoResponse) !VideoResponse {
        const p = self.handle.value.provider;
        const videos = try arena.dupe(VideoData, resp.videos);
        for (videos) |*v| {
            if (v.url.len == 0) continue;
            const got = try self.roundTrip(arena, .{
                .method = .GET,
                .url = try http.buildUrl(arena, p, v.url, "", self.handle.api_key),
                .headers = try self.headers(arena, &.{}, null),
            });
            v.bytes = got.body;
            v.url = "";
        }
        var out = resp;
        out.videos = videos;
        return out;
    }

    /// Auth plus client headers. No middleware: polling reads state (BUG-036
    /// fires on submit only).
    fn headers(self: VideoAdapter, arena: std.mem.Allocator, extra: []const http.Header, content_type: ?[]const u8) ![]http.Header {
        return http.composeHeaders(arena, self.handle.value.provider, self.handle.api_key, extra, content_type, self.handle.ctx.customHeaders());
    }

    fn roundTrip(self: VideoAdapter, arena: std.mem.Allocator, req: http.Request) !http.Response {
        return send.withTransport(&self.handle.ctx, roundTripWith, self, .{ arena, req });
    }

    fn roundTripWith(self: VideoAdapter, transport: http.Transport, arena: std.mem.Allocator, req: http.Request) !http.Response {
        _ = self;
        const resp = try transport.send(arena, req);
        if (resp.status < 200 or resp.status >= 300) return error.ApiError;
        return resp;
    }
};

fn requiresOutput(shape: []const u8) bool {
    const eq = std.mem.eql;
    return eq(u8, shape, "VideoVeo") or eq(u8, shape, "VideoVertexVeo") or eq(u8, shape, "VideoBedrock");
}

fn parseBody(arena: std.mem.Allocator, body: []const u8) !json.Value {
    return std.json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch error.InvalidVideoResponse;
}

/// Classify one poll body per wire shape. Mirrors Rust `parse_video_poll`'s
/// status arms; the terminal sets are the providers' documented values.
fn classifyVideo(arena: std.mem.Allocator, shape: []const u8, raw: json.Value) !job.Verdict {
    const eq = std.mem.eql;
    if (eq(u8, shape, "VideoQwen"))
        return byString(stringAt(raw, "output.task_status"), &.{"SUCCEEDED"}, &.{ "FAILED", "CANCELED" }, "");
    if (eq(u8, shape, "VideoTogether"))
        return byString(stringAt(raw, "status"), &.{"completed"}, &.{ "failed", "cancelled" }, "");
    if (eq(u8, shape, "VideoZhipu"))
        return byString(stringAt(raw, "task_status"), &.{"SUCCESS"}, &.{"FAIL"}, "");
    if (eq(u8, shape, "VideoMinimax"))
        return byString(stringAt(raw, "status"), &.{"Success"}, &.{"Fail"}, "");
    if (eq(u8, shape, "VideoVidu"))
        return byString(stringAt(raw, "state"), &.{"success"}, &.{"failed"}, firstNonEmpty(stringAt(raw, "err_code"), stringAt(raw, "message")));
    if (eq(u8, shape, "VideoBedrock"))
        return byString(stringAt(raw, "status"), &.{"Completed"}, &.{"Failed"}, stringAt(raw, "failureMessage"));
    if (eq(u8, shape, "VideoGrok"))
        return byString(stringAt(raw, "status"), &.{"done"}, &.{ "failed", "expired" }, stringAt(raw, "error.message"));
    if (eq(u8, shape, "VideoPixVerse")) {
        // Integer codes under Resp: 1 success, 7/8 failed, 5 generating.
        const code: ?i64 = if (json.getPath(raw, "Resp.status")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;
        const text = if (code) |c| try std.fmt.allocPrint(arena, "{d}", .{c}) else "";
        const state: job.Classification = if (code) |c| switch (c) {
            1 => .succeeded,
            7, 8 => .failed,
            else => .running,
        } else .running;
        return .{ .state = state, .raw_status = text };
    }
    if (eq(u8, shape, "VideoVeo") or eq(u8, shape, "VideoVertexVeo")) {
        // Long-running operation: `done` is the status. A done op with an
        // error object failed; the raw status is the flag as text.
        const done = if (json.getPath(raw, "done")) |v| v == .bool and v.bool else false;
        if (!done) return .{ .state = .running, .raw_status = "false" };
        if (json.getPath(raw, "error")) |e| if (e == .object)
            return .{ .state = .failed, .raw_status = "true", .message = stringAt(raw, "error.message") };
        return .{ .state = .succeeded, .raw_status = "true" };
    }
    return error.UnsupportedVideoWireShape;
}

/// Classify a string status: done set > error set > running.
fn byString(status: []const u8, done: []const []const u8, errors: []const []const u8, message: []const u8) job.Verdict {
    for (done) |d| if (std.mem.eql(u8, d, status)) return .{ .state = .succeeded, .raw_status = status };
    for (errors) |e| if (std.mem.eql(u8, e, status)) return .{ .state = .failed, .raw_status = status, .message = message };
    return .{ .state = .running, .raw_status = status };
}

/// The finished video reference per wire shape (single-hop providers). Mirrors
/// the Rust `video_result_from_*` family.
fn videoResult(arena: std.mem.Allocator, vg: video_gen.VideoGenDef, raw: json.Value) !VideoResponse {
    const eq = std.mem.eql;
    const shape = vg.wire_shape;
    if (eq(u8, shape, "VideoGrok")) {
        const duration: i64 = if (json.getPath(raw, "video.duration")) |v| switch (v) {
            .integer => |i| i,
            else => 0,
        } else 0;
        return urlResponse(arena, vg, stringAt(raw, "video.url"), duration);
    }
    if (eq(u8, shape, "VideoZhipu")) return urlResponse(arena, vg, stringAt(raw, "video_result[0].url"), 0);
    if (eq(u8, shape, "VideoVidu")) return urlResponse(arena, vg, stringAt(raw, "creations[0].url"), 0);
    if (eq(u8, shape, "VideoPixVerse")) return urlResponse(arena, vg, stringAt(raw, "Resp.url"), 0);
    if (eq(u8, shape, "VideoTogether")) return urlResponse(arena, vg, stringAt(raw, "outputs.video_url"), 0);
    if (eq(u8, shape, "VideoQwen")) return urlResponse(arena, vg, stringAt(raw, "output.video_url"), 0);
    if (eq(u8, shape, "VideoBedrock")) return urlResponse(arena, vg, stringAt(raw, "outputDataConfig.s3OutputDataConfig.s3Uri"), 0);
    if (eq(u8, shape, "VideoVeo"))
        return urlResponse(arena, vg, stringAt(raw, "response.generateVideoResponse.generatedSamples[0].video.uri"), 0);
    if (eq(u8, shape, "VideoVertexVeo")) {
        // Inline base64 bytes: download delivery with no fetch hop.
        const b64 = stringAt(raw, "response.videos[0].bytesBase64Encoded");
        if (b64.len == 0) return emptyResponse();
        const dec = std.base64.standard.Decoder;
        const bytes = try arena.alloc(u8, dec.calcSizeForSlice(b64) catch return error.InvalidVideoResponse);
        dec.decode(bytes, b64) catch return error.InvalidVideoResponse;
        const mime = firstNonEmpty(stringAt(raw, "response.videos[0].mimeType"), fallbackMime(vg));
        const videos = try arena.alloc(VideoData, 1);
        videos[0] = .{ .mime_type = mime, .url = "", .bytes = bytes, .duration_seconds = 0 };
        return withVideos(videos);
    }
    return error.UnsupportedVideoWireShape;
}

fn urlResponse(arena: std.mem.Allocator, vg: video_gen.VideoGenDef, url: []const u8, duration: i64) !VideoResponse {
    if (url.len == 0) return emptyResponse();
    const videos = try arena.alloc(VideoData, 1);
    videos[0] = .{ .mime_type = fallbackMime(vg), .url = url, .bytes = "", .duration_seconds = duration };
    return withVideos(videos);
}

fn withVideos(videos: []const VideoData) VideoResponse {
    var r = emptyResponse();
    r.videos = videos;
    return r;
}

fn emptyResponse() VideoResponse {
    return .{ .videos = &.{}, .usage = .{}, .finish_reason = null, .finish_message = null, .raw = null };
}

/// The first model's output MIME, used when the provider echoes none.
fn fallbackMime(vg: video_gen.VideoGenDef) []const u8 {
    return if (vg.models.len > 0) vg.models[0].output_mime else "video/mp4";
}

/// The string at `path`, or "" when absent or not a string.
fn stringAt(v: json.Value, path: []const u8) []const u8 {
    const got = json.getPath(v, path) orelse return "";
    return switch (got) {
        .string => |s| s,
        else => "",
    };
}

fn firstNonEmpty(a: []const u8, b: []const u8) []const u8 {
    return if (a.len > 0) a else b;
}

/// Replace every `needle` in `haystack` with `replacement`.
fn replaceAll(arena: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    const size = std.mem.replacementSize(u8, haystack, needle, replacement);
    const out = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, haystack, needle, replacement, out);
    return out;
}

/// A UUID-v4-shaped trace id (PixVerse's per-request `Ai-trace-id`, an
/// anti-cache key), from `io`'s random source.
fn traceId(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = std.fmt.bytesToHex(b, .lower);
    return std.fmt.allocPrint(arena, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] });
}
