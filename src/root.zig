//! llmkit — the Zig client for llmkit. One typed API across many LLM providers.
//!
//! Phase 0 vertical slice: the JSON waist, the OpenAI-shape request builder,
//! and the public client + Text builder. HTTP send, the remaining wire shapes,
//! and the media/async capabilities arrive in later phases.

const std = @import("std");

pub const json = @import("json.zig");
pub const providers = @import("providers/generated/providers.zig");
pub const models_parsers = @import("providers/generated/models_parsers.zig");
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

pub const Client = client.Client;
pub const Text = client.Text;
pub const Agent = agent.Agent;
pub const Tool = agent.Tool;
pub const BatchHandle = batch.BatchHandle;
pub const Image = image.Image;
pub const ImageResponse = image.ImageResponse;
pub const ImageData = image.ImageData;
pub const Speech = speech.Speech;
pub const SpeechResponse = speech.SpeechResponse;
pub const AudioData = speech.AudioData;
pub const Transcription = transcription.Transcription;
pub const TranscriptionResponse = transcription.TranscriptionResponse;
pub const TranscriptSegment = transcription.TranscriptSegment;
pub const Video = video.Video;
pub const Models = models.Models;
pub const ScopedModels = models.ScopedModels;
pub const Providers = models.Providers;
pub const ModelInfo = models.ModelInfo;
pub const ProviderName = providers.ProviderName;
pub const Protocol = client.Protocol;
pub const SafetySetting = client.SafetySetting;





