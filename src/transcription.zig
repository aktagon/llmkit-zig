//! Transcription (speech-to-text, ADR-048 / ADR-051 Slice 3) — a mirror of
//! rust/src/builders/transcription.rs and go/transcription.go, minus the HTTP
//! send and the async poll/job adapter.
//!
//! Two request encodings, dispatched on the provider's generated
//! `request_encoding` fact (never a provider-name switch):
//!   - `json` (AssemblyAI, ASYNC submit) — `Transcription.buildSubmitBody`
//!     produces the flat `{audio_url}` submit body. The upload hop (bytes ->
//!     upload_url) and the poll/wait lifecycle are the async runtime, which
//!     needs an HTTP send terminal Zig does not yet have; they are a later
//!     slice, so this file builds only the outbound submit bytes.
//!   - `multipart` (OpenAI, SYNC transcribe) — `Transcription.buildMultipartBody`
//!     produces the FIRST multipart/form-data request body in the Zig SDK: a
//!     REAL encoded body (fixed field order model / response_format / file) plus
//!     the boundary it used, so the request-wire driver can decode it back to
//!     the canonical descriptor the cross-SDK comparator asserts (ADR-051 OQ-3).
//!
//! One response seam the OpenAI sync golden asserts:
//!   - `parseTranscriptionResponse` projects a provider REPLY to
//!     `{text, segments}`, dispatched on the generated `wire_shape` fact.
//!     TranscriptionOpenAI (verbose_json) is implemented; its segment offsets
//!     are SECONDS (float) -> integer milliseconds (x1000, rounded, OAA-006).
//!     Usage is NOT REPORTED (OAA-007 — OpenAI reports no token usage for STT).
//!
//! Everything here is backed by a caller-supplied allocator (pass an arena for a
//! whole build/parse and free it in one shot). Runtime concerns (pre-flight
//! validation beyond the encoding split, HTTP send, the AssemblyAI poll adapter)
//! are later slices; this file is the wire-shaped core.

const std = @import("std");
const http = @import("http.zig");
const send = @import("send.zig");
const json = @import("json.zig");
const middleware = @import("middleware.zig");
const providers = @import("providers/generated/providers.zig");
const transcription_gen = @import("providers/generated/transcription_gen.zig");
const response = @import("response.zig");

pub const ProviderName = providers.ProviderName;

/// One timed span of transcript (ADR-048). Slice-3 segments carry text plus
/// millisecond offsets and an optional diarized speaker label (empty for the
/// OpenAI sync shape). Declared here — as `image.zig` declares its own
/// `ImageData` — rather than consumed from the generated `structs.zig`, which
/// is not yet wired into the module graph. Mirrors Rust/Go `TranscriptSegment`.
pub const TranscriptSegment = struct {
    text: []const u8,
    /// Segment start offset in milliseconds.
    start: i64 = 0,
    /// Segment end offset in milliseconds.
    end: i64 = 0,
    /// Diarized speaker label when the provider reports one; empty otherwise.
    speaker: []const u8 = "",
};

/// The normalized speech-to-text reply: the full transcript text, the timed
/// segments, the shared token carrier (unreported for STT), and an optional
/// finish reason. The container is TEXT-shaped, not a media `*Data` container —
/// the structural divergence from video/speech (ADR-048). Mirror of Rust/Go
/// `TranscriptionResponse`.
pub const TranscriptionResponse = struct {
    text: []const u8,
    segments: []const TranscriptSegment,
    usage: response.Usage = .{},
    finish_reason: ?[]const u8 = null,
};

/// A real encoded multipart/form-data body plus the boundary it used. The driver
/// decodes `body` against `boundary` back to the canonical descriptor
/// (ADR-051 OQ-3) — the runtime really builds the bytes, the driver really
/// parses them; neither fakes the other.
pub const Multipart = struct {
    boundary: []const u8,
    body: []const u8,
};

pub const BuildError = error{
    UnsupportedTranscriptionProvider,
    WrongEncoding,
    ModelRequired,
} || std.mem.Allocator.Error;

pub const ParseError = error{
    UnsupportedTranscriptionProvider,
    UnsupportedTranscriptionWireShape,
} || std.mem.Allocator.Error;

/// A fixed, deterministic multipart boundary. Zig needs no randomness here (the
/// decoder reads whatever boundary the encoder used); a constant keeps the
/// encoded body reproducible. The value is long + prefixed so it cannot collide
/// with the ASCII placeholder audio bytes the fixture feeds.
const boundary_str = "----llmkitZigFormBoundary7MA4YWxkTrZu0gW";

/// The public Transcription builder. Immutable value type: each chain method
/// returns a fresh copy, so a forked chain never mutates its parent (the
/// `Text`/`Image`/`Speech` discipline). Only the terminals take an allocator.
pub const Transcription = struct {
    provider: providers.ProviderName,
    ctx: http.Ctx,
    model_: ?[]const u8 = null,

    /// The transcription model id (ADR-021 bare-noun replacer). Required by the
    /// SYNC multipart path (OpenAI carries it as the `model` form field); unused
    /// by the ASYNC JSON submit (AssemblyAI selects the model server-side).
    pub fn model(self: Transcription, m: []const u8) Transcription {
        var s = self;
        s.model_ = m;
        return s;
    }

    /// Build the ASYNC submit body (`json` encoding, AssemblyAI) — the flat
    /// `{audio_url}` the async submit terminal would POST. `audio_url` is a
    /// public audio URL (the bytes-upload hop is the async runtime, a later
    /// slice). Rejects a non-JSON provider (the wrong terminal for it). Mirrors
    /// the `submit`-side body of Rust `submit_transcription`.
    pub fn buildSubmitBody(self: Transcription, arena: std.mem.Allocator, audio_url: []const u8) BuildError!json.Value {
        const cfg = transcription_gen.transcriptionConfig(self.provider) orelse
            return error.UnsupportedTranscriptionProvider;
        if (!std.mem.eql(u8, cfg.request_encoding, "json"))
            return error.WrongEncoding;

        var body = json.object();
        try json.set(arena, &body, "audio_url", .{ .string = audio_url });
        return body;
    }

    /// Build the SYNC multipart/form-data body (`multipart` encoding, OpenAI) —
    /// the FIRST non-JSON request body in llmkit. Fixed field order (model,
    /// response_format=verbose_json, file) so every SDK decodes to the same
    /// descriptor; the file part carries `filename="audio.<ext>"` + the audio
    /// `Content-Type` + the raw bytes. `mime` is the audio IANA media type;
    /// `bytes` is the RAW audio. Requires a model. Rejects a non-multipart
    /// provider. Mirrors the multipart Form of Rust `transcribe_sync`.
    pub fn buildMultipartBody(self: Transcription, arena: std.mem.Allocator, mime: []const u8, bytes: []const u8) BuildError!Multipart {
        const cfg = transcription_gen.transcriptionConfig(self.provider) orelse
            return error.UnsupportedTranscriptionProvider;
        if (!std.mem.eql(u8, cfg.request_encoding, "multipart"))
            return error.WrongEncoding;
        const model_id = self.model_ orelse return error.ModelRequired;

        return encodeMultipart(arena, model_id, mime, bytes);
    }

    /// Transcribe audio bytes SYNCHRONOUSLY and return the transcript
    /// (`multipart` encoding, OpenAI). `mime` is the audio IANA media type;
    /// `bytes` is the RAW audio. One round-trip, no polling — the whole reason
    /// ADR-051 promoted `interaction` to a config fact.
    ///
    /// A provider whose generated `request_encoding` is `json` is rejected by
    /// `buildMultipartBody` with `error.WrongEncoding`: it is the wrong terminal
    /// for that provider, and `submit` is the right one. The routing therefore
    /// comes from the config, not from a name check here.
    pub fn transcribe(
        self: Transcription,
        arena: std.mem.Allocator,
        api_key: []const u8,
        mime: []const u8,
        bytes: []const u8,
    ) !TranscriptionResponse {
        var t = http.HttpTransport.fromCtx(&self.ctx);
        return self.transcribeWith(self.ctx.transport orelse t.transport(), arena, api_key, mime, bytes);
    }

    /// `transcribe` over an injected transport (the seam tests mock).
    ///
    /// Middleware: the send fires `transcription` pre (vetoable) and post
    ///
    /// to fire `llm_request` for want of a transcription member, misreporting
    /// STT as chat.
    pub fn transcribeWith(
        self: Transcription,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        mime: []const u8,
        bytes: []const u8,
    ) !TranscriptionResponse {
        const cfg = transcription_gen.transcriptionConfig(self.provider) orelse
            return error.UnsupportedTranscriptionProvider;
        const mp = try self.buildMultipartBody(arena, mime, bytes);

        // The boundary the encoder actually used has to reach the server, or the
        // form is undecodable — hence `postRaw` with a hand-built content-type
        // rather than the JSON default.
        const raw = try send.postRaw(transport, arena, .{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = cfg.submit_endpoint,
            .op = .transcription,
            .model = self.model_ orelse "",
        }, mp.body, try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{mp.boundary}));

        const parsed = std.json.parseFromSliceLeaky(json.Value, arena, raw, .{}) catch
            return error.InvalidTranscriptionResponse;
        return parseTranscriptionResponse(arena, self.provider, parsed);
    }

    /// Submit audio for ASYNCHRONOUS transcription (`json` encoding, AssemblyAI)
    /// and return the PROVIDER TRANSCRIPT ID, read from the config's declared
    /// `submit_handle_field`. `audio_url` is a publicly fetchable audio URL.
    ///
    /// **Submit only.** The poll adapter that would turn this id into a finished
    /// transcript is deferred (HANDOFF-046 slice 2): it needs the transcription
    /// arm of the shared `job.zig` engine plus the AssemblyAI result decode, and
    /// no cross-SDK lifecycle fixture gates that path yet. A handle type with an
    /// unimplemented `poll` would advertise more than the SDK can do, so the bare
    /// id is what is returned. The bytes-upload hop (`upload_endpoint`, for
    /// callers who have audio but no public URL) is deferred with it.
    pub fn submit(
        self: Transcription,
        arena: std.mem.Allocator,
        api_key: []const u8,
        audio_url: []const u8,
    ) ![]const u8 {
        var t = http.HttpTransport.fromCtx(&self.ctx);
        return self.submitWith(self.ctx.transport orelse t.transport(), arena, api_key, audio_url);
    }

    /// `submit` over an injected transport (the seam tests mock).
    ///
    /// Middleware: fires `transcription` around the OUTBOUND submit only
    /// (BUG-036), mirroring `video_generation` / `batch_submit`. Polling a
    /// submitted job reads state and does not fire.
    pub fn submitWith(
        self: Transcription,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        audio_url: []const u8,
    ) ![]const u8 {
        const cfg = transcription_gen.transcriptionConfig(self.provider) orelse
            return error.UnsupportedTranscriptionProvider;
        const body = try self.buildSubmitBody(arena, audio_url);

        const raw = try send.postJson(transport, arena, .{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = cfg.submit_endpoint,
            .op = .transcription,
            .model = self.model_ orelse "",
        }, body);

        const id = json.getPath(raw, cfg.submit_handle_field) orelse
            return error.MissingTranscriptionHandle;
        if (id != .string or id.string.len == 0) return error.MissingTranscriptionHandle;
        return id.string;
    }
};

/// Encode the OpenAI transcription multipart body in canonical field order.
fn encodeMultipart(arena: std.mem.Allocator, model_id: []const u8, mime: []const u8, bytes: []const u8) BuildError!Multipart {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(arena);

    try appendTextField(arena, &buf, "model", model_id);
    try appendTextField(arena, &buf, "response_format", "verbose_json");

    // The file part: Content-Disposition with filename + a Content-Type line,
    // then the raw bytes.
    const ext = audioExtForMime(mime);
    const filename = try std.fmt.allocPrint(arena, "audio.{s}", .{ext});
    const content_type = if (mime.len == 0) "application/octet-stream" else mime;

    try buf.appendSlice(arena, "--");
    try buf.appendSlice(arena, boundary_str);
    try buf.appendSlice(arena, "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"");
    try buf.appendSlice(arena, filename);
    try buf.appendSlice(arena, "\"\r\nContent-Type: ");
    try buf.appendSlice(arena, content_type);
    try buf.appendSlice(arena, "\r\n\r\n");
    try buf.appendSlice(arena, bytes);
    try buf.appendSlice(arena, "\r\n");

    // Closing delimiter.
    try buf.appendSlice(arena, "--");
    try buf.appendSlice(arena, boundary_str);
    try buf.appendSlice(arena, "--\r\n");

    return .{ .boundary = boundary_str, .body = try buf.toOwnedSlice(arena) };
}

/// Append one text form field: `--boundary\r\nContent-Disposition: form-data;
/// name="<name>"\r\n\r\n<value>\r\n`.
fn appendTextField(arena: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8, value: []const u8) BuildError!void {
    try buf.appendSlice(arena, "--");
    try buf.appendSlice(arena, boundary_str);
    try buf.appendSlice(arena, "\r\nContent-Disposition: form-data; name=\"");
    try buf.appendSlice(arena, name);
    try buf.appendSlice(arena, "\"\r\n\r\n");
    try buf.appendSlice(arena, value);
    try buf.appendSlice(arena, "\r\n");
}

/// Map an audio IANA media type to the file extension OpenAI uses to detect the
/// format. Mirror of Rust `audio_ext_for_mime` / Go `audioExtForMime`.
fn audioExtForMime(mime: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, mime, "audio/mpeg") or eq(u8, mime, "audio/mp3")) return "mp3";
    if (eq(u8, mime, "audio/wav") or eq(u8, mime, "audio/x-wav")) return "wav";
    if (eq(u8, mime, "audio/mp4") or eq(u8, mime, "audio/m4a") or eq(u8, mime, "audio/x-m4a")) return "m4a";
    if (eq(u8, mime, "audio/webm")) return "webm";
    if (eq(u8, mime, "audio/ogg") or eq(u8, mime, "audio/opus")) return "ogg";
    if (eq(u8, mime, "audio/flac")) return "flac";
    return "bin";
}

/// Project a provider transcription REPLY into the normalized
/// `TranscriptionResponse`, dispatched on the provider's generated `wire_shape`
/// fact (STT-005) — never a provider-name switch. `raw` is the parsed JSON
/// response. Slice 3 implements the OpenAI SYNC shape (TranscriptionOpenAI);
/// the AssemblyAI poll-result decode belongs to the async runtime (a later
/// slice) and is reported as an unsupported wire shape here. Result strings are
/// duped into `arena`, so the response outlives the parsed body. Mirrors Rust
/// `transcription_result_from_openai`.
pub fn parseTranscriptionResponse(arena: std.mem.Allocator, provider: ProviderName, raw: json.Value) ParseError!TranscriptionResponse {
    const cfg = transcription_gen.transcriptionConfig(provider) orelse
        return error.UnsupportedTranscriptionProvider;

    if (std.mem.eql(u8, cfg.wire_shape, "TranscriptionOpenAI"))
        return parseOpenAITranscription(arena, raw);
    return error.UnsupportedTranscriptionWireShape;
}

/// Decode the OpenAI verbose_json transcript: top-level `text` plus a
/// `segments[]` array of `{text, start, end}` (seconds -> ms). Models without a
/// `segments[]` array yield an empty segment slice, not an error. Speaker is
/// always empty (OpenAI does not diarize). Usage is unreported (OAA-007) — not a count of zero.
fn parseOpenAITranscription(arena: std.mem.Allocator, raw: json.Value) ParseError!TranscriptionResponse {
    const text = try arena.dupe(u8, getString(raw, "text") orelse "");

    var segments: std.ArrayList(TranscriptSegment) = .empty;
    errdefer segments.deinit(arena);

    if (objGet(raw, "segments")) |segs| {
        if (std.meta.activeTag(segs) == .array) {
            for (segs.array.items) |seg| {
                if (std.meta.activeTag(seg) != .object) continue;
                try segments.append(arena, .{
                    .text = try arena.dupe(u8, getString(seg, "text") orelse ""),
                    .start = secondsToMillis(floatField(seg, "start")),
                    .end = secondsToMillis(floatField(seg, "end")),
                    .speaker = "",
                });
            }
        }
    }

    return .{
        .text = text,
        .segments = try segments.toOwnedSlice(arena),
    };
}

/// Convert a seconds offset (verbose_json float) to integer milliseconds,
/// rounded (OAA-006).
fn secondsToMillis(seconds: f64) i64 {
    return @intFromFloat(std.math.round(seconds * 1000.0));
}

/// Read a string field off an object Value; null when absent or not a string.
fn getString(v: json.Value, key: []const u8) ?[]const u8 {
    const got = objGet(v, key) orelse return null;
    return switch (got) {
        .string => |s| s,
        else => null,
    };
}

/// Read a numeric field off an object Value as f64; 0 when absent or non-numeric.
fn floatField(v: json.Value, key: []const u8) f64 {
    const got = objGet(v, key) orelse return 0;
    return switch (got) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

/// Read a member off an object Value; null when `v` is not an object or the key
/// is absent.
fn objGet(v: json.Value, key: []const u8) ?json.Value {
    if (std.meta.activeTag(v) != .object) return null;
    return v.object.get(key);
}

/// A `Ctx` for the pure-seam tests below. Those tests exercise body/header
/// construction only, so the transport dependencies are never used — but Zig
/// has no ambient allocator or `Io`, so they must still be named.
fn testCtx() http.Ctx {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io };
}










































































































































































/// A middleware that records every (op, phase) it is called with. Zig has no
/// capturing closures, so the recorder's state rides on `ptr` — the same
/// type-erasure `http.Transport` uses.
const Recorder = struct {
    seen: [8]struct { op: middleware.MiddlewareOp, phase: middleware.MiddlewarePhase } = undefined,
    count: usize = 0,

    fn call(ptr: *anyopaque, ev: *const middleware.Event) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.seen[self.count] = .{ .op = ev.op, .phase = ev.phase };
        self.count += 1;
        return null;
    }

    fn hook(self: *Recorder) middleware.Middleware {
        return .{ .ptr = self, .call_fn = Recorder.call };
    }
};























































































