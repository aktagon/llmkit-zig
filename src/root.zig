//! llmkit — the Zig client for llmkit. One typed API across many LLM providers.
//!
//! Start at `Client.init`; every capability is a builder reached from it.

const std = @import("std");

pub const json = @import("json.zig");
pub const providers = @import("providers/generated/providers.zig");
pub const models_parsers = @import("providers/generated/models_parsers.zig");
const image_gen = @import("providers/generated/image_gen.zig");
const music_gen = @import("providers/generated/music_gen.zig");
const speech_gen = @import("providers/generated/speech_gen.zig");
const video_gen = @import("providers/generated/video_gen.zig");
const batch_config = @import("providers/generated/batch.zig");
const provider_info = @import("providers/generated/provider_info.zig");
const structs = @import("providers/generated/structs.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const http = @import("http.zig");
pub const stream = @import("stream.zig");
pub const agent = @import("agent.zig");
pub const caching = @import("caching.zig");
pub const job = @import("job.zig");
pub const batch = @import("batch.zig");
pub const sigv4 = @import("sigv4.zig");
pub const client = @import("client.zig");
pub const image = @import("image.zig");
pub const speech = @import("speech.zig");
pub const transcription = @import("transcription.zig");
pub const video = @import("video.zig");
pub const models = @import("models.zig");
pub const music = @import("music.zig");
pub const upload = @import("upload.zig");
pub const middleware = @import("middleware.zig");
pub const send = @import("send.zig");
pub const capability = @import("capability.zig");
pub const telemetry = @import("telemetry.zig");

pub const Client = client.Client;
pub const AwsCredentials = http.AwsCredentials;
pub const Text = client.Text;
pub const Agent = agent.Agent;
pub const Tool = agent.Tool;
pub const BatchHandle = batch.BatchHandle;
// Batch slot values (ADR-091): the finish_reason of a batch slot with no result
// line, and of a failed slot the provider gave no reason for.
pub const batch_slot_missing = batch_config.batch_slot_missing;
pub const batch_slot_error = batch_config.batch_slot_error;
pub const Image = image.Image;
pub const ImageResponse = image.ImageResponse;
pub const ImageData = image.ImageData;
pub const Speech = speech.Speech;
pub const SpeechResponse = speech.SpeechResponse;
pub const AudioData = speech.AudioData;
pub const Transcription = transcription.Transcription;
pub const TranscriptionHandle = transcription.TranscriptionHandle;
pub const TranscriptionResponse = transcription.TranscriptionResponse;
pub const TranscriptSegment = transcription.TranscriptSegment;
pub const Video = video.Video;
pub const VideoHandle = video.VideoHandle;
pub const Music = music.Music;
pub const MusicResponse = music.MusicResponse;
pub const Upload = upload.Upload;
pub const File = upload.File;
pub const Capability = capability.Capability;
pub const Middleware = middleware.Middleware;
pub const Models = models.Models;
pub const ScopedModels = models.ScopedModels;
pub const Providers = models.Providers;
pub const ModelInfo = models.ModelInfo;
pub const ProviderName = providers.ProviderName;
pub const Protocol = client.Protocol;
// Cross-SDK value types with no hand-written module home. The ones above that
// have one (ImageData, File, ...) are aliases of these same generated structs.
pub const Response = response.Response;
pub const Message = structs.Message;
pub const ToolCall = structs.ToolCall;
pub const ToolResult = structs.ToolResult;
pub const ProviderTurn = structs.ProviderTurn;
pub const MediaRef = structs.MediaRef;
pub const LiveResult = structs.LiveResult;
pub const ProviderError = structs.ProviderError;
pub const VideoData = structs.VideoData;
pub const VideoResponse = structs.VideoResponse;
pub const SafetySetting = client.SafetySetting;
// === Keyless media-config accessors (ADR-036 public surface) ===
//
// Each `*GenConfig` answers "what can this provider do for this capability?"
// WITHOUT a client, a key, or a network call — so a caller can build a model
// menu at startup. They are re-exported here because Zig is an ALLOWLIST
// boundary target (like the TS barrel): a `pub const` inside a generated module
// is unreachable through `@import("llmkit")` until root.zig names it, so
// existing-in-the-tree is not the same as reachable-by-a-consumer. That gap is
// exactly the BUG-011 class ADR-036 was written to close.
pub const imageGenConfig = image_gen.imageGenConfig;
pub const ImageGenDef = image_gen.ImageGenDef;
pub const ImageModelDef = image_gen.ImageModelDef;
pub const RequestVariant = image_gen.RequestVariant;
pub const musicGenConfig = music_gen.musicGenConfig;
pub const MusicGenDef = music_gen.MusicGenDef;
pub const MusicModelDef = music_gen.MusicModelDef;
pub const speechGenConfig = speech_gen.speechGenConfig;
pub const SpeechGenDef = speech_gen.SpeechGenDef;
pub const SpeechModelDef = speech_gen.SpeechModelDef;
pub const videoGenConfig = video_gen.videoGenConfig;
pub const VideoGenDef = video_gen.VideoGenDef;
pub const VideoModelDef = video_gen.VideoModelDef;
pub const ProviderInfo = provider_info.ProviderInfo;
pub const providerInfo = provider_info.providerInfo;

pub const Telemetry = telemetry.Telemetry;
pub const Event = telemetry.Event;
pub const buildOtlpTraces = telemetry.buildOtlpTraces;
pub const HttpExport = telemetry.HttpExport;
pub const TelemetryExport = telemetry.Export;
pub const setEventError = telemetry.setEventError;








