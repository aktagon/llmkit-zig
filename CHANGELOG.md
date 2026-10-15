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

### Added

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

### Known limitations

These are not supported yet:

- **AWS Bedrock cannot send.** Requests are not signed, so Bedrock rejects
  them.
- **Raw responses.** The `raw` field on responses is always null; there is no
  way to request it.
- **Telemetry export.** The client does not send OpenTelemetry spans.
- **Streaming with `protocol(.responses)`** returns empty text: Responses
  stream events are not read yet.

- **Video generation is submit-only.** `video().submit` returns the provider's
  job id, but there is no poll/wait runtime, so a caller must poll the provider
  themselves.

Also not yet implemented: Google's `ResourceCaching` pre-hop (explicit
`cache_control` caching works), the live `/models` catalogue send (the
compiled-in catalogue and request assembly work), and polling asynchronous
transcription jobs.
