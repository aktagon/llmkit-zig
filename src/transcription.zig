//! Transcription (speech-to-text, ADR-048 / ADR-051 Slice 3) — a mirror of
//! rust/src/builders/transcription.rs and go/transcription.go, minus the
//! bytes-upload hop.
//!
//! Two request encodings, dispatched on the provider's generated
//! `request_encoding` fact (never a provider-name switch):
//!   - `json` (AssemblyAI, ASYNC submit) — `Transcription.submit` POSTs the flat
//!     `{audio_url}` body and returns a `TranscriptionHandle`; its `poll` /
//!     `wait` run on the shared `job.zig` engine (ADR-062) through
//!     `TranscriptionAdapter`. The lifecycle-wire `transcription-{succeeded,
//!     failed}` goldens assert the normalized JobStatus. The bytes-upload hop
//!     (bytes -> upload_url) is not implemented: submit takes a public URL.
//!   - `multipart` (OpenAI, SYNC transcribe) — `Transcription.buildMultipartBody`
//!     produces a REAL encoded multipart/form-data body (fixed field order model /
//!     response_format / file) plus the boundary it used, so the request-wire
//!     driver can decode it back to the canonical descriptor the cross-SDK
//!     comparator asserts (ADR-051 OQ-3).
//!
//! `parseTranscriptionResponse` projects a provider REPLY to `{text, segments}`,
//! dispatched on the generated `wire_shape` fact:
//!   - TranscriptionOpenAI (verbose_json): segment offsets are SECONDS (float) ->
//!     integer milliseconds (x1000, rounded, OAA-006).
//!   - TranscriptionAssemblyAI (a completed poll body): `text` + `words[]` with
//!     integer-millisecond offsets and an optional diarized speaker.
//! Usage is NOT REPORTED for either (OAA-007 / ADR-048 OQ-2).
//!
//! Everything here is backed by a caller-supplied allocator (pass an arena for a
//! whole build/parse/poll and free it in one shot).

const std = @import("std");
const http = @import("http.zig");
const send = @import("send.zig");
const multipart = @import("multipart.zig");
const json = @import("json.zig");
const middleware = @import("middleware.zig");
const providers = @import("providers/generated/providers.zig");
const transcription_gen = @import("providers/generated/transcription_gen.zig");
const response = @import("response.zig");
const structs = @import("providers/generated/structs.zig");

/// The audio an async `submit` transcribes. Mirrors the Go/Rust audio Part.
pub const Audio = union(enum) {
    /// A publicly fetchable audio URL.
    url: []const u8,
    /// Raw audio bytes. `submit` uploads them to the provider's upload
    /// endpoint first and submits the URL it returns (STT-005).
    bytes: []const u8,
};

/// The non-empty string at `path`, or null.
fn stringField(v: json.Value, path: []const u8) ?[]const u8 {
    const f = json.getPath(v, path) orelse return null;
    if (f != .string or f.string.len == 0) return null;
    return f.string;
}
const job = @import("job.zig");

pub const ProviderName = providers.ProviderName;

/// One timed span of transcript (ADR-048): text plus millisecond offsets and an
/// optional diarized speaker label (empty for the OpenAI sync shape).
pub const TranscriptSegment = structs.TranscriptSegment;

/// The normalized speech-to-text reply: the full transcript text, the timed
/// segments, and the shared token carrier (unreported for STT). The container
/// is TEXT-shaped, not a media `*Data` container — the structural divergence
/// from video/speech (ADR-048).
pub const TranscriptionResponse = structs.TranscriptionResponse;

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

    /// Attach an observation + veto hook to this builder only (ADR-020); see
    /// `Text.addMiddleware`.
    pub fn addMiddleware(self: Transcription, m: middleware.Middleware) Transcription {
        var s = self;
        s.ctx = s.ctx.withMiddleware(m);
        return s;
    }

    /// Build the ASYNC submit body (`json` encoding, AssemblyAI) — the flat
    /// `{audio_url}` the async submit terminal would POST. `audio_url` is a
    /// public audio URL, or the URL the upload hop returned for `Audio.bytes`.
    /// Rejects a non-JSON provider (the wrong terminal for it). Mirrors the
    /// `submit`-side body of Rust `submit_transcription`.
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
        return send.withTransport(&self.ctx, @TypeOf(self).transcribeWith, self, .{ arena, api_key, mime, bytes });
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
    /// and return a `TranscriptionHandle` whose id is read from the config's
    /// declared `submit_handle_field`. `audio` is a public URL, or raw bytes
    /// that are first uploaded to the provider's upload endpoint (STT-005).
    /// Poll the handle with `poll`, or block with `wait`. Mirrors Go/Rust
    /// `Transcription.Submit`.
    pub fn submit(
        self: Transcription,
        arena: std.mem.Allocator,
        api_key: []const u8,
        audio: Audio,
    ) !TranscriptionHandle {
        return send.withTransport(&self.ctx, @TypeOf(self).submitWith, self, .{ arena, api_key, audio });
    }

    /// `submit` over an injected transport (the seam tests mock).
    ///
    /// Middleware: ONE `transcription` event spans the outbound hops, the
    /// upload (for `Audio.bytes`) and the submit (BUG-036), as in Go and Rust:
    /// a pre-phase veto stops the upload. Polling a submitted job reads state
    /// and does not fire.
    pub fn submitWith(
        self: Transcription,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        audio: Audio,
    ) !TranscriptionHandle {
        const cfg = transcription_gen.transcriptionConfig(self.provider) orelse
            return error.UnsupportedTranscriptionProvider;
        // Pre-flight, from config, before any middleware fires: the wrong
        // terminal for a multipart provider, and bytes for a URL-only one.
        if (!std.mem.eql(u8, cfg.request_encoding, "json")) return error.WrongEncoding;
        if (audio == .bytes and cfg.upload_endpoint.len == 0) return error.AudioBytesUnsupported;

        const args = send.Args{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = cfg.submit_endpoint,
            .op = .transcription,
            .model = self.model_ orelse "",
        };
        try send.firePre(args);
        const id = self.uploadAndSubmit(transport, arena, api_key, cfg, audio) catch |err| {
            send.firePostOutcome(args, switch (err) {
                error.Timeout => .{ .transport = "timeout" },
                error.ApiError => .{ .api = .{
                    .provider = @tagName(self.provider),
                    .status_code = 0,
                    .message = "provider returned a non-2xx status",
                } },
                else => .{ .decoding = "could not read the provider reply" },
            });
            return err;
        };
        send.firePostOutcome(args, null);
        return .{
            .value = .{ .id = id, .provider = self.provider },
            .ctx = self.ctx,
            .api_key = api_key,
        };
    }

    /// The outbound hops of `submitWith`, unobserved: the upload (bytes only)
    /// that yields `upload_url`, then the `{audio_url}` submit. Returns the job id.
    fn uploadAndSubmit(
        self: Transcription,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        cfg: transcription_gen.TranscriptionDef,
        audio: Audio,
    ) ![]const u8 {
        const audio_url = switch (audio) {
            .url => |u| u,
            .bytes => |data| blk: {
                const up = try self.post(transport, arena, api_key, cfg.upload_endpoint, data, "application/octet-stream");
                break :blk stringField(up, "upload_url") orelse return error.MissingUploadUrl;
            },
        };
        const body = try json.stringify(arena, try self.buildSubmitBody(arena, audio_url));
        const reply = try self.post(transport, arena, api_key, cfg.submit_endpoint, body, "application/json");
        const id = stringField(reply, cfg.submit_handle_field) orelse return error.MissingTranscriptionHandle;
        return arena.dupe(u8, id);
    }

    /// POST one hop without middleware and parse the JSON reply.
    fn post(
        self: Transcription,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        endpoint: []const u8,
        body: []const u8,
        content_type: []const u8,
    ) !json.Value {
        const resp = try send.sendUnobserved(transport, arena, .{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = endpoint,
            .method = .POST,
            .body = body,
            .content_type = content_type,
        });
        if (resp.status < 200 or resp.status >= 300) return error.ApiError;
        return std.json.parseFromSliceLeaky(json.Value, arena, resp.body, .{}) catch error.InvalidTranscriptionResponse;
    }
};

/// Default poll cadence for `TranscriptionHandle.wait`: AssemblyAI jobs run from
/// seconds to minutes. Mirrors Go `transcriptionPollInterval` (3s) and
/// `transcriptionPollTimeout` (10 min).
const poll_interval_ms: u64 = 3000;
const poll_timeout_ms: u64 = 600000;

/// A submitted asynchronous transcription job (ADR-048), polled on the shared
/// Job engine (ADR-062). `value` is the cross-SDK `TranscriptionHandle` value
/// (id, provider) — the part a caller persists to resume (ADR-014); `ctx`
/// supplies the base URL override, the `io` for `wait`'s sleep, and the
/// transport seam. A caller resuming by id passes its client's `ctx`.
pub const TranscriptionHandle = struct {
    value: structs.TranscriptionHandle,
    ctx: http.Ctx,
    api_key: []const u8 = "",

    /// One poll round-trip (ADR-063 Poll): GET the transcript, classify its
    /// status from the generated done/error facts, and decode the transcript on
    /// success. A provider `error` status is a `JobStatus{.failed}` whose
    /// `cause.message` carries the provider's message.
    pub fn poll(self: TranscriptionHandle, arena: std.mem.Allocator) !job.JobStatus(TranscriptionResponse) {
        return job.pollOnce(TranscriptionAdapter, .{ .handle = self }, arena);
    }

    /// Block until the job reaches a terminal state (ADR-063 Wait — a thin loop
    /// over `poll`). Gives up at the deadline with `error.PollTimeout`; a
    /// provider failure is a `JobStatus{.failed}`, not that error.
    pub fn wait(self: TranscriptionHandle, arena: std.mem.Allocator) !job.JobStatus(TranscriptionResponse) {
        return job.wait(TranscriptionAdapter, .{ .handle = self }, self.ctx.io, arena);
    }
};

/// The Job-engine adapter for an async transcription (the four seams). The
/// status-to-terminal mapping is config (`status_path` / `done_status` /
/// `error_status`, STT-005); only the result decode is wire-shape-keyed, and it
/// needs no second hop. Mirrors Go/Rust `transcriptionAdapter`.
const TranscriptionAdapter = struct {
    handle: TranscriptionHandle,

    pub const Out = TranscriptionResponse;

    fn tcConfig(self: TranscriptionAdapter) !transcription_gen.TranscriptionDef {
        const cfg = transcription_gen.transcriptionConfig(self.handle.value.provider) orelse
            return error.UnsupportedTranscriptionProvider;
        if (!std.mem.eql(u8, cfg.interaction, "async")) return error.WrongEncoding;
        return cfg;
    }

    pub fn config(self: TranscriptionAdapter, arena: std.mem.Allocator) !job.LifecycleConfig {
        const cfg = try self.tcConfig();
        // Arena-backed single-element slices: a `&.{...}` literal would dangle.
        const done = try arena.alloc([]const u8, 1);
        done[0] = cfg.done_status;
        const err_values = try arena.alloc([]const u8, 1);
        err_values[0] = cfg.error_status;
        return .{
            .status_path = cfg.status_path,
            .done_values = done,
            .error_values = err_values,
            .error_message_path = providers.spec(self.handle.value.provider).error_message_path,
            .poll_interval_ms = poll_interval_ms,
            .poll_timeout_ms = poll_timeout_ms,
            .noun = "transcription",
        };
    }

    pub fn poll(self: TranscriptionAdapter, arena: std.mem.Allocator) !job.PollBody {
        const cfg = try self.tcConfig();
        const endpoint = try replaceId(arena, cfg.poll_endpoint, self.handle.value.id);
        const resp = try send.withTransport(&self.handle.ctx, getWith, self, .{ arena, endpoint });
        if (resp.status < 200 or resp.status >= 300) return error.ApiError;
        return .{ .value = std.json.parseFromSliceLeaky(json.Value, arena, resp.body, .{}) catch
            return error.InvalidTranscriptionResponse };
    }

    pub fn result(self: TranscriptionAdapter, arena: std.mem.Allocator, pb: job.PollBody) !Out {
        return parseTranscriptionResponse(arena, self.handle.value.provider, pb.value);
    }

    fn getWith(self: TranscriptionAdapter, transport: http.Transport, arena: std.mem.Allocator, endpoint: []const u8) !http.Response {
        // No middleware: polling reads state (BUG-036 fires on submit only).
        return send.sendUnobserved(transport, arena, .{
            .provider = self.handle.value.provider,
            .ctx = &self.handle.ctx,
            .api_key = self.handle.api_key,
            .endpoint = endpoint,
        });
    }
};

/// Replace the first `{id}` in `template` with `id`.
fn replaceId(arena: std.mem.Allocator, template: []const u8, id: []const u8) ![]const u8 {
    const idx = std.mem.indexOf(u8, template, "{id}") orelse return template;
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ template[0..idx], id, template[idx + "{id}".len ..] });
}

/// Encode the OpenAI transcription multipart body in canonical field order:
/// model, response_format, then the file part.
fn encodeMultipart(arena: std.mem.Allocator, model_id: []const u8, mime: []const u8, bytes: []const u8) BuildError!Multipart {
    var w: multipart.Writer = .{ .boundary = boundary_str };
    try w.field(arena, "model", model_id);
    try w.field(arena, "response_format", "verbose_json");

    const filename = try std.fmt.allocPrint(arena, "audio.{s}", .{audioExtForMime(mime)});
    const content_type = if (mime.len == 0) "application/octet-stream" else mime;
    try w.file(arena, "file", filename, content_type, bytes);

    return .{ .boundary = boundary_str, .body = try w.finish(arena) };
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
/// response: the OpenAI SYNC reply, or a completed AssemblyAI poll body. Result
/// strings are duped into `arena`, so the response outlives the parsed body.
/// Mirrors Rust `transcription_result`.
pub fn parseTranscriptionResponse(arena: std.mem.Allocator, provider: ProviderName, raw: json.Value) ParseError!TranscriptionResponse {
    const cfg = transcription_gen.transcriptionConfig(provider) orelse
        return error.UnsupportedTranscriptionProvider;

    if (std.mem.eql(u8, cfg.wire_shape, "TranscriptionOpenAI"))
        return parseOpenAITranscription(arena, raw);
    if (std.mem.eql(u8, cfg.wire_shape, "TranscriptionAssemblyAI"))
        return parseAssemblyAITranscription(arena, raw);
    return error.UnsupportedTranscriptionWireShape;
}

/// Decode a completed AssemblyAI transcript: top-level `text` plus `words[]` of
/// `{text, start, end, speaker?}` with INTEGER millisecond offsets (no
/// conversion). Speaker is present only on diarized transcripts. Mirrors Rust
/// `transcription_result_from_assemblyai`.
fn parseAssemblyAITranscription(arena: std.mem.Allocator, raw: json.Value) ParseError!TranscriptionResponse {
    const text = try arena.dupe(u8, getString(raw, "text") orelse "");

    var segments: std.ArrayList(TranscriptSegment) = .empty;
    errdefer segments.deinit(arena);

    if (objGet(raw, "words")) |words| {
        if (std.meta.activeTag(words) == .array) {
            for (words.array.items) |w| {
                if (std.meta.activeTag(w) != .object) continue;
                try segments.append(arena, .{
                    .text = try arena.dupe(u8, getString(w, "text") orelse ""),
                    .start = intField(w, "start"),
                    .end = intField(w, "end"),
                    .speaker = try arena.dupe(u8, getString(w, "speaker") orelse ""),
                });
            }
        }
    }

    return .{
        .text = text,
        .segments = try segments.toOwnedSlice(arena),
        .usage = .{},
    };
}

/// Read an integer field off an object Value; 0 when absent or not an integer.
fn intField(v: json.Value, key: []const u8) i64 {
    const got = objGet(v, key) orelse return 0;
    return switch (got) {
        .integer => |i| i,
        else => 0,
    };
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
        .usage = .{},
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













































































































/// An AssemblyAI handle on a mock transport (base URL left at the provider's).
fn testHandle(gpa: std.mem.Allocator, transport: http.Transport) TranscriptionHandle {
    return .{
        .value = .{ .id = "9ea6f2c1-4d3b-4a17-8f0e-2c5b7d1e9a44", .provider = .assemblyai },
        .ctx = (http.Ctx{ .gpa = gpa, .io = std.testing.io }).withTransport(transport),
        .api_key = "aai-key",
    };
}










































































































































































