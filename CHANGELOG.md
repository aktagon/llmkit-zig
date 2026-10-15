# Changelog

All notable changes to the llmkit Zig SDK are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First release.

### Changed

- **BREAKING — `Response.content` is now `Response.text`.** Every response type
  is now the same public struct the other SDKs return, with the same field
  names. A batch handle keeps its id at `handle.value.id`.

- **BREAKING — image input limits are per model, and the provider-level count is gone.**
  `ImageGenDef.max_input_count` is removed. It mixed two kinds of number: wire limits, and
  provider maxima (Google 14, OpenAI and Grok 16) that no source confirmed.
  When a provider raised its limit, image generation rejected calls the
  provider would accept. Each image model now carries `ImageModelDef.supports_image_input`,
  added as the last field. Image generation rejects image parts when it is
  false (OpenRouter and Recraft models), and rejects more than
  `ImageModelDef.max_input_images` when that is not 0 (Vertex Imagen: 1). Every
  other model sends all image parts and lets the provider decide.
  Migration: read `ImageModelDef.supports_image_input` and `ImageModelDef.max_input_images`
  on the model instead of the provider-level count.

- **BREAKING — an unreported usage dimension or finish signal is now absent, not zero.**
  The six `Usage` dimensions (input, output, cache read, cache write, reasoning,
  cost) and the finish reason / finish message on every response container are
  now `?i64` / `?f64` / `?[]const u8`. Previously a provider that reported no
  cached tokens and one that never mentioned caching both produced `0`, and an
  unreported cost read as a free request.

  Migration: `resp.usage.input` is now `?i64`; unwrap with `if (…) |v|` rather than treating a missing count as `0`.

  Aggregation across agent turns is **absorbing** — a total is reported only when
  every turn reported that dimension, so a partial sum is never presented as a
  total. Telemetry now exports a usage attribute when the value is *reported*,
  zero included, instead of when it is greater than zero.

### Removed

- **Vertex image generation removed.** Google shut down the Imagen endpoints.
  Image generation on Vertex now fails with `error.UnsupportedImageProvider`
  before any request is sent. Vertex music and video are unchanged, and the
  Vertex default model is now `lyria-002`.

### Added

- **Streaming with `protocol(.responses)`.** The stream terminal reads OpenAI
  Responses stream events: text deltas, then the finish reason and token usage
  from `response.completed`. The request carries no `stream_options`, which the
  Responses API rejects.
- **AWS Bedrock sends.** Every Bedrock request (text, agent, and video submit)
  is signed with AWS Signature Version 4. `Client.awsCredentials` takes the
  secret access key, the optional session token, and the region; the access
  key ID is the terminal's key. A Bedrock send without them fails with
  `error.MissingAwsCredentials`.
- **Telemetry export.** `Client.addTelemetry(&tel)` emits one OpenTelemetry
  span per operation and hands the OTLP bytes to `tel.export`. `HttpExport` is
  the ready-made callback that POSTs to `<endpoint>/v1/traces`. Export is
  synchronous and fail-open: a collector error never fails the call.
- **Live model catalogue.** `models().provider(p).list(arena, key)` reads the
  provider's `/models` endpoint and follows pagination; `provider(p).get`
  fetches one model. Results carry the known capabilities, and `raw()` keeps
  the provider's record. A key without the models scope returns
  `error.Scope`.
- The middleware post event for a chat request (prompt, stream, and each agent
  round) now carries the reply's token usage.
- **Video jobs can be polled.** `video().submit` returns a `VideoHandle`.
  `handle.poll` makes one request and returns the job state; `handle.wait`
  polls every 5 seconds until the job succeeds or fails, and gives up with
  `error.PollTimeout` after 10 minutes. On success the result holds the
  finished video: bytes for Google Veo and Vertex Veo, a URL for the other
  providers, and the S3 URI for Bedrock.
- **Asynchronous transcription jobs.** `transcription().submit` takes a public
  URL or audio bytes, which it uploads first, and returns a
  `TranscriptionHandle`. `handle.poll` makes one request and returns the job
  state; `handle.wait` polls until the job succeeds or fails, and gives up with
  `error.PollTimeout` after 10 minutes. A provider failure is a `.failed` state
  whose `cause.message` carries the provider's message.
- **Conversation history.** `Text.history(messages)` sends earlier turns before
  the prompt. An assistant `Message` that carries the `provider_turn` from an
  earlier response is sent back exactly as the provider returned it, so
  reasoning and provider metadata survive the round-trip.
- **The agent runs tools.** `Agent.chat` sends the prompt, runs each tool the
  model calls, returns the results, and repeats until the model answers.
  `maxToolIterations` caps the rounds (default 10), `Agent.history` seeds the
  conversation, usage sums every round, and each tool call fires `tool_call`
  middleware events that can veto it.
- `Text.text(s)` adds a text part to the user turn.
- Every builder has `addMiddleware`, for hooks that fire on that builder's
  calls only. `raw()` on `Text`, `Agent`, `Image`, `Music` and `Video` fills
  the response's `raw` field with the parsed provider reply.
- `Agent` takes the `Text` generation options (`maxTokens` through
  `safetySettings`). `Image` gains `text`, `mask` and `safetySettings`, plus
  a deprecated `safetyFilter` that every provider rejects; `Music` gains `text` and `lyrics`; `Video` gains `text`
  and `outputURI`, and `submit` returns a `VideoHandle`. `Upload` takes its
  content from `bytes(data)` or `path(p)`, with `mimeType(m)`.
- **Google cache resources.** With `caching()` on, a Google request first
  creates a `cachedContents` resource holding the system prompt, then sends the
  request with a reference to it. Each creation fires `cache_create` middleware
  events.
- `batch_slot_missing` and `batch_slot_error`: the finish reasons of a batch
  slot with no result, and of a failed slot the provider gave no reason for.
  Compare against them instead of typing the strings.
- **Public send terminals.** Every capability now has a terminal that performs
  the request, so the SDK is callable: `text().prompt/stream/batch`,
  `agent().chat`, `image().generate`, `music().generate`, `speech().generate`,
  `transcription().transcribe/submit`, `video().submit`, `upload().run`, and
  `Client.supports`. Each is a thin composition over the already-tested request
  builder and response parser, so no request or response bytes changed.
- **`Client.init` now takes an allocator and an `std.Io`.** Zig has no ambient
  allocator or event loop, so the transport dependencies have to be named
  somewhere; the client is where they live. Per-request memory stays an `arena`
  passed to each terminal.
- **Observation + veto middleware.** `Client.addMiddleware` attaches a hook
  fired before and after each operation; returning a reason from the pre phase
  vetoes the call before any bytes leave the process.
- **Files API** (`client.upload()`), previously missing entirely — the SDK could
  reference an uploaded file but not create one.
- **Music generation** (`client.music()`), with the prompt-plus-optional-lyrics
  surface.
- **Keyless media-config accessors** re-exported from the package root
  (`imageGenConfig`, `musicGenConfig`, `speechGenConfig`, `videoGenConfig` and
  their config types), so a caller can build a model menu with no client and no
  key.
- `Client.addHeader` values are now actually sent. They were recorded on the
  builder but had no send path to reach.

### Fixed

- **The package can be imported.** `b.dependency("llmkit", ...).module("llmkit")`
  found no module, because the build registered none by name.
- Google requests put the model in the URL. They were sent to a path with a
  literal `{model}` in it.
- `protocol(.responses)` sends to `/v1/responses`. It sent the Responses body to
  `/v1/chat/completions`.
- A builder without `model(...)` sends the provider's default model. It sent no
  model.
- Google streams use the streaming endpoint.
- Music generation sends lyrics before the prompt, as the providers expect.
- `BatchHandle.wait` compiles. It failed to compile on first use.
- **OpenAI batch failures show the provider's error.** Waiting on an OpenAI
  batch now also reads its error file. A failed request's finish reason is the
  provider's error code (for example `batch_expired`), and its finish message
  is the provider's error message.
- **A batch result succeeds only when the provider says it did.** A result line
  with a failure status and an empty body reads as failed, not as a success
  with empty text.
- **A batch returns one response per prompt, even when the last one has no
  result.** The list length comes from the batch's request count, so a missing
  last request keeps its slot and reads `missing`.
- **Batch results are matched to prompts by request id, not by line order.**
  Providers return batch results in any order, and a failed request used to be
  dropped, so later answers moved up one place. Waiting on a batch now returns
  one response per prompt, at the prompt's index. A failed request keeps its
  slot with empty text, the provider's result status as the finish reason
  (`errored`, `expired`, `canceled`, or `error`) and the provider's error
  message as the finish message. A request with no result reads finish reason
  `missing`. Results for request ids this SDK did not assign follow in file
  order.

- Streaming against a query-authenticated provider (Google) sent no credential:
  the stream path assembled its URL directly instead of splicing the `?key=`
  the provider's auth scheme requires. All send paths now share one URL
  assembly.
- Requests carrying a JSON body now send `Content-Type: application/json`.
- The client base-URL override now applies to every send path, not only the
  catalogue request assembly.
