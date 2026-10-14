//! Music generation (ADR-033 / ADR-037) — HANDOFF-046 slice 1.
//!
//! Single-turn: a prompt plus OPTIONAL lyrics in, one or more audio clips out.
//! Three seams, the same shape every other capability uses:
//!   - `buildMusicBody` (OUTBOUND) — dispatched on the provider's generated
//!     `wire_shape` fact, never a provider name. Three shapes:
//!       * `MusicPredict` (Vertex Lyria) — `{instances:[{prompt}], parameters:
//!         {sampleCount}}`. Lyrics FOLD INTO the prompt text: ADR-037 relaxed
//!         the lyrics gate from a hard pre-flight reject to advisory, so a model
//!         without `supports_lyrics` still sends, it just gets prompt-shaped
//!         input.
//!       * `MusicMinimax` — `{model, prompt, output_format:"hex",
//!         audio_setting:{...}}` with `lyrics` as its own field when present.
//!       * default (Gemini `generateContent`, Lyria 3) — `{contents:[{parts}],
//!         generationConfig:{responseModalities:["AUDIO"]}}`, lyrics and prompt
//!         both serialising as `{text}` parts in caller order.
//!   - `parseMusicResponse` (INBOUND) — decodes the audio per shape
//!     (`predictions[].audioContent` base64 / `data.audio` HEX /
//!     `candidates[].content.parts[].inlineData.data` base64).
//!   - `generate` (the TERMINAL) — compose the two around one send.
//!
//! ADR-037 hard-rejects only the unserializable: an unknown model. A Zig music
//! request has no image part to reject. Everything else is advisory.
//!
//! NOT YET FIXTURED. No SDK drives a music request-wire golden (HANDOFF-046
//! slice 4 mints the first), so unlike every other Zig capability these bytes
//! are held by unit tests against the Rust reference (`rust/src/music.rs`)
//! rather than by a seven-SDK byte comparison. Treat the shapes as
//! reference-anchored, not parity-proven, until slice 4 lands.

const std = @import("std");
const json = @import("json.zig");
const http = @import("http.zig");
const send = @import("send.zig");
const response = @import("response.zig");
const structs = @import("providers/generated/structs.zig");
const providers = @import("providers/generated/providers.zig");
const music_gen = @import("providers/generated/music_gen.zig");

pub const ProviderName = providers.ProviderName;

/// Wire-shape discriminators (mirror the generated string constants, exactly as
/// Rust's `SHAPE_PREDICT`/`SHAPE_MINIMAX` do).
const shape_predict = "MusicPredict";
const shape_minimax = "MusicMinimax";

/// One decoded audio clip: the provider's output MIME plus RAW bytes. The same
/// type as the speech path's `AudioData` — ADR-037 reuses the container rather
/// than inventing a music-specific one.
pub const AudioData = structs.AudioData;

/// The normalized music reply: the generated clips, the shared token carrier
/// (unreported for music — no provider reports one), and an optional finish
/// reason (Vertex reports `raiFilteredReason` when a clip was filtered).
pub const MusicResponse = structs.MusicResponse;

pub const BuildError = error{
    UnsupportedMusicProvider,
    UnknownMusicModel,
} || std.mem.Allocator.Error;

pub const ParseError = error{UnsupportedMusicProvider} || std.mem.Allocator.Error;

/// Fixed capacity for `Music.lyrics` — chain methods take no allocator
/// (ADR-069 ZIG-005), matching `Text`'s bounded media array.
const max_lyrics_parts = 4;

/// The public Music builder. Immutable value type: each chain method returns a
/// fresh copy, so a forked chain never mutates its parent.
pub const Music = struct {
    provider: ProviderName,
    ctx: http.Ctx,
    model_: ?[]const u8 = null,
    lyrics_: [max_lyrics_parts][]const u8 = undefined,
    lyrics_count_: usize = 0,

    /// The music-generation model id (ADR-021 bare-noun replacer). Required:
    /// music models are explicit choices and there is no text-model default
    /// that generates audio.
    pub fn model(self: Music, m: []const u8) Music {
        var s = self;
        s.model_ = m;
        return s;
    }

    /// Append a lyrics part (ADR-021 `Add*` appender). Advisory, not gated: a
    /// model without `supports_lyrics` folds them into the prompt instead of
    /// rejecting (ADR-037 relaxed this from a hard pre-flight reject).
    pub fn addLyrics(self: Music, text: []const u8) Music {
        var s = self;
        std.debug.assert(s.lyrics_count_ < max_lyrics_parts);
        s.lyrics_[s.lyrics_count_] = text;
        s.lyrics_count_ += 1;
        return s;
    }

    /// Build the music request body, dispatched on the provider's generated
    /// `wire_shape`. Rejects an unknown model — the one hard pre-flight gate.
    pub fn buildMusicBody(self: Music, arena: std.mem.Allocator, prompt: []const u8) BuildError!json.Value {
        const cfg = music_gen.musicGenConfig(self.provider) orelse
            return error.UnsupportedMusicProvider;
        _ = try self.resolveModel(cfg);

        const lyrics = try std.mem.join(arena, "\n", self.lyrics_[0..self.lyrics_count_]);

        if (std.mem.eql(u8, cfg.wire_shape, shape_predict))
            return buildPredictBody(arena, prompt, lyrics);
        if (std.mem.eql(u8, cfg.wire_shape, shape_minimax))
            return buildMinimaxBody(arena, prompt, lyrics, self.model_ orelse "");
        return buildGeminiBody(arena, prompt, self.lyrics_[0..self.lyrics_count_]);
    }

    /// Generate music and return the decoded clips. Mirrors Go `GenerateMusic` /
    /// Rust `generate_music`.
    pub fn generate(
        self: Music,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !MusicResponse {
        return send.withTransport(&self.ctx, @TypeOf(self).generateWith, self, .{ arena, api_key, prompt });
    }

    /// `generate` over an injected transport (the seam tests mock).
    pub fn generateWith(
        self: Music,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !MusicResponse {
        const cfg = music_gen.musicGenConfig(self.provider) orelse
            return error.UnsupportedMusicProvider;
        const md = try self.resolveModel(cfg);
        const body = try self.buildMusicBody(arena, prompt);

        // MiniMax serves music off a DIFFERENT host than chat — the generated
        // `base_url` fact. A client-supplied base-URL override still wins, since
        // that is the caller pointing the SDK at a gateway on purpose. Same
        // shape as the video path above it.
        var ctx = self.ctx;
        if (ctx.base_url == null and cfg.base_url.len > 0)
            ctx.base_url = cfg.base_url;

        const raw = try send.postJson(transport, arena, .{
            .provider = self.provider,
            .ctx = &ctx,
            .api_key = api_key,
            .endpoint = try musicEndpoint(arena, cfg, self.model_ orelse ""),
            .op = .music_generation,
            .model = self.model_ orelse "",
        }, body);

        return parseMusicResponse(arena, self.provider, md.output_mime, raw);
    }

    /// The catalogue entry for the configured model. Unknown model is the one
    /// hard reject (ADR-037): everything else the runtime can serialize, it
    /// sends.
    fn resolveModel(self: Music, cfg: music_gen.MusicGenDef) BuildError!music_gen.MusicModelDef {
        const want = self.model_ orelse return error.UnknownMusicModel;
        for (cfg.models) |m|
            if (std.mem.eql(u8, m.model_id, want)) return m;
        return error.UnknownMusicModel;
    }
};

/// The generation endpoint: the music-specific `gen_endpoint` when the fact
/// carries one, else the provider's chat endpoint (Gemini reuses
/// generateContent), with `{model}` substituted. Always a RELATIVE path joined
/// to the resolved base: MiniMax used to ship a full absolute URL here, which
/// made it the one call no base-URL override could redirect; its host is now
/// the `base_url` fact applied by the caller above.
fn musicEndpoint(arena: std.mem.Allocator, cfg: music_gen.MusicGenDef, model_id: []const u8) ![]const u8 {
    const template = if (cfg.gen_endpoint.len > 0) cfg.gen_endpoint else "";
    return replaceModel(arena, template, model_id);
}

fn replaceModel(arena: std.mem.Allocator, template: []const u8, model_id: []const u8) ![]const u8 {
    return http.substituteModel(arena, template, model_id);
}

/// Vertex Lyria `:predict`: `{instances:[{prompt}], parameters:{sampleCount:1}}`.
/// Lyrics fold onto the prompt (newline-joined) — this shape has no lyrics field.
fn buildPredictBody(arena: std.mem.Allocator, prompt: []const u8, lyrics: []const u8) !json.Value {
    const merged = if (lyrics.len == 0)
        prompt
    else if (prompt.len == 0)
        lyrics
    else
        try std.fmt.allocPrint(arena, "{s}\n{s}", .{ prompt, lyrics });

    var instance = json.object();
    try json.set(arena, &instance, "prompt", .{ .string = merged });
    var instances = json.array(arena);
    try instances.array.append(instance);

    var parameters = json.object();
    try json.set(arena, &parameters, "sampleCount", .{ .integer = 1 });

    var body = json.object();
    try json.set(arena, &body, "instances", instances);
    try json.set(arena, &body, "parameters", parameters);
    return body;
}

/// MiniMax `/v1/music_generation`: `{model, prompt, output_format:"hex",
/// audio_setting:{...}}` plus `lyrics` when present. `output_format:"hex"`
/// is load-bearing — the parser decodes `data.audio` as hex, not base64.
fn buildMinimaxBody(arena: std.mem.Allocator, prompt: []const u8, lyrics: []const u8, model_id: []const u8) !json.Value {
    var audio_setting = json.object();
    try json.set(arena, &audio_setting, "sample_rate", .{ .integer = 44100 });
    try json.set(arena, &audio_setting, "bitrate", .{ .integer = 128000 });
    try json.set(arena, &audio_setting, "format", .{ .string = "mp3" });

    var body = json.object();
    try json.set(arena, &body, "model", .{ .string = model_id });
    try json.set(arena, &body, "prompt", .{ .string = prompt });
    try json.set(arena, &body, "output_format", .{ .string = "hex" });
    try json.set(arena, &body, "audio_setting", audio_setting);
    if (lyrics.len > 0) try json.set(arena, &body, "lyrics", .{ .string = lyrics });
    return body;
}

/// Gemini `generateContent` (Lyria 3): lyrics and prompt both serialise as
/// `{text}` parts, the lyrics Parts in call order and the terminal's prompt
/// last — the order every Part-taking terminal uses, and the one the
/// music-google golden locks. `responseModalities:["AUDIO"]` asks for audio.
fn buildGeminiBody(arena: std.mem.Allocator, prompt: []const u8, lyrics: []const []const u8) !json.Value {
    var wire = json.array(arena);
    for (lyrics) |l| {
        var p = json.object();
        try json.set(arena, &p, "text", .{ .string = l });
        try wire.array.append(p);
    }
    if (prompt.len > 0) {
        var p = json.object();
        try json.set(arena, &p, "text", .{ .string = prompt });
        try wire.array.append(p);
    }

    var content = json.object();
    try json.set(arena, &content, "parts", wire);
    var contents = json.array(arena);
    try contents.array.append(content);

    var modalities = json.array(arena);
    try modalities.array.append(.{ .string = "AUDIO" });
    var gen_config = json.object();
    try json.set(arena, &gen_config, "responseModalities", modalities);

    var body = json.object();
    try json.set(arena, &body, "contents", contents);
    try json.set(arena, &body, "generationConfig", gen_config);
    return body;
}

/// Project a provider music REPLY into the normalized `MusicResponse`,
/// dispatched on the generated `wire_shape` — never a provider name. Each
/// shape's envelope diverges enough (predictions[] base64 vs data.audio hex vs
/// candidates[] inlineData) that an explicit arm is clearer than a walker.
pub fn parseMusicResponse(
    arena: std.mem.Allocator,
    provider: ProviderName,
    fallback_mime: []const u8,
    raw: json.Value,
) ParseError!MusicResponse {
    const cfg = music_gen.musicGenConfig(provider) orelse return error.UnsupportedMusicProvider;

    if (std.mem.eql(u8, cfg.wire_shape, shape_predict))
        return parsePredictResponse(arena, raw, fallback_mime);
    if (std.mem.eql(u8, cfg.wire_shape, shape_minimax))
        return parseMinimaxResponse(arena, raw, fallback_mime);
    return parseGeminiResponse(arena, raw, fallback_mime);
}

fn parsePredictResponse(arena: std.mem.Allocator, raw: json.Value, fallback_mime: []const u8) !MusicResponse {
    var clips: std.ArrayList(AudioData) = .empty;
    var finish: []const u8 = "";

    if (json.getPath(raw, "predictions")) |preds| if (preds == .array) {
        for (preds.array.items) |entry| {
            if (finish.len == 0) {
                if (json.getPath(entry, "raiFilteredReason")) |r|
                    if (r == .string and r.string.len > 0) {
                        finish = r.string;
                    };
            }
            const b64 = stringAt(entry, "audioContent") orelse
                stringAt(entry, "bytesBase64Encoded") orelse continue;
            const bytes = decodeBase64(arena, b64) catch continue;
            try clips.append(arena, .{
                .mime_type = stringAt(entry, "mimeType") orelse fallback_mime,
                .bytes = bytes,
            });
        }
    };

    return .{ .audio = try clips.toOwnedSlice(arena), .text = "", .usage = .{}, .finish_reason = finish, .finish_message = null, .raw = null };
}

fn parseMinimaxResponse(arena: std.mem.Allocator, raw: json.Value, fallback_mime: []const u8) !MusicResponse {
    var clips: std.ArrayList(AudioData) = .empty;
    // `output_format:"hex"` on the request means `data.audio` is HEX, not base64.
    if (stringAt(raw, "data.audio")) |hex| {
        if (decodeHex(arena, hex)) |bytes| {
            try clips.append(arena, .{ .mime_type = fallback_mime, .bytes = bytes });
        } else |_| {}
    }
    return .{ .audio = try clips.toOwnedSlice(arena), .text = "", .usage = .{}, .finish_reason = null, .finish_message = null, .raw = null };
}

fn parseGeminiResponse(arena: std.mem.Allocator, raw: json.Value, fallback_mime: []const u8) !MusicResponse {
    var clips: std.ArrayList(AudioData) = .empty;
    var finish: []const u8 = "";

    if (json.getPath(raw, "candidates")) |cands| if (cands == .array) {
        for (cands.array.items) |cand| {
            if (finish.len == 0) {
                if (stringAt(cand, "finishReason")) |fr| finish = fr;
            }
            const parts = json.getPath(cand, "content.parts") orelse continue;
            if (parts != .array) continue;
            for (parts.array.items) |part| {
                const b64 = stringAt(part, "inlineData.data") orelse continue;
                const bytes = decodeBase64(arena, b64) catch continue;
                try clips.append(arena, .{
                    .mime_type = stringAt(part, "inlineData.mimeType") orelse fallback_mime,
                    .bytes = bytes,
                });
            }
        }
    };

    return .{ .audio = try clips.toOwnedSlice(arena), .text = "", .usage = .{}, .finish_reason = finish, .finish_message = null, .raw = null };
}

/// A non-empty string at a dotted path, else null (so `orelse` chains read as
/// "first field that actually carries a value").
fn stringAt(value: json.Value, path: []const u8) ?[]const u8 {
    const v = json.getPath(value, path) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

fn decodeBase64(arena: std.mem.Allocator, b64: []const u8) ![]const u8 {
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(b64);
    const out = try arena.alloc(u8, n);
    try dec.decode(out, b64);
    return out;
}

fn decodeHex(arena: std.mem.Allocator, hex: []const u8) ![]const u8 {
    if (hex.len % 2 != 0) return error.InvalidCharacter;
    const out = try arena.alloc(u8, hex.len / 2);
    return std.fmt.hexToBytes(out, hex);
}

// === Tests ===
//
// These stand in for the missing cross-SDK music fixture (HANDOFF-046 slice 4).
// Each expected shape is transcribed from `rust/src/music.rs`, the reference
// implementation — so they catch a Zig-local regression, but they do NOT prove
// seven-SDK agreement the way a wire golden would.

const testing = std.testing;

fn testMusic(gpa: std.mem.Allocator, provider: ProviderName) Music {
    return .{ .provider = provider, .ctx = .{ .gpa = gpa, .io = testing.io } };
}


































































































