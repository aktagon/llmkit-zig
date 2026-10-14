# llmkit (Zig)

One Zig API for Anthropic, OpenAI, Google, and 30+ other providers, including local models through Ollama and vLLM. Switch providers without rewriting your request.

Built on the Zig standard library: HTTP, JSON and TLS come from `std`, and the package has no dependencies. Requires Zig 0.16.0.

Also available for Go, TypeScript, Python, Rust, Swift, and Java.

## Install

Fetch a release into your `build.zig.zon`:

```sh
zig fetch --save https://github.com/aktagon/llmkit-zig/archive/refs/tags/v1.0.0.tar.gz
```

Then import the module in `build.zig`:

```zig
const llmkit = b.dependency("llmkit", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("llmkit", llmkit.module("llmkit"));
```

## Quick Start

```zig
const std = @import("std");
const llmkit = @import("llmkit");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const key = init.environ_map.get("ANTHROPIC_API_KEY") orelse return error.MissingKey;
    const client = llmkit.Client.init(init.gpa, init.io, .anthropic);

    const resp = try client.text()
        .system("Be concise.")
        .temperature(0.3)
        .prompt(arena, key, "Why is the sky blue?");

    std.debug.print("{s}\n", .{resp.text});
    // Optional: null means the provider reported no count, not a count of 0.
    if (resp.usage.input) |n| std.debug.print("{d} input tokens\n", .{n});
}
```

One pattern across every capability: `client.<capability>().<chain>.<terminal>(arena, key, ...)`.

Chain methods take no allocator and return a new builder by value, so one configured builder can be reused. Each terminal takes an `std.mem.Allocator`, and everything it returns lives in that allocator. Pass an arena and free the whole call at once.

## Providers

Pick a provider by its `ProviderName`:

```zig
const anthropic = llmkit.Client.init(gpa, io, .anthropic);
const openai = llmkit.Client.init(gpa, io, .openai);
const google = llmkit.Client.init(gpa, io, .google);
const ollama = llmkit.Client.init(gpa, io, .ollama);
_ = .{ anthropic, openai, google, ollama };
```

35 providers, with three chat API shapes that send today: OpenAI-compatible, Anthropic Messages, and Google Generative AI. Dedicated image, video, music, speech, and transcription providers are also supported. AWS Bedrock is not yet supported for sending; see [Not yet supported](#not-yet-supported).

## API

### Text: one-shot prompt

```zig
const resp = try client.text()
    .system("You are helpful")
    .temperature(0.7)
    .maxTokens(200)
    .prompt(arena, key, "What is 2+2?");

std.debug.print("{s}\n", .{resp.text}); // "4"

// Every Usage dimension is optional. null means the provider did not report
// the value, which is NOT the same as reporting zero.
const u = resp.usage;
std.debug.print("in={?d} out={?d} cache_read={?d} cache_write={?d} reasoning={?d} cost={?d}\n", .{
    u.input, u.output, u.cache_read, u.cache_write, u.reasoning, u.cost,
});
if (resp.finish_reason) |reason| std.debug.print("finished: {s}\n", .{reason});
```

`resp.usage.cost` is the provider-reported cost in USD, and null when the provider reports none.

### Stream: callback and final response

The callback receives each text chunk. The terminal returns the full `Response` with token counts.

```zig
const resp = try client.text()
    .system("Be brief")
    .stream(arena, key, "Tell me a joke", printChunk);

std.debug.print("\nUsage: {?d} in / {?d} out\n", .{ resp.usage.input, resp.usage.output });
```

```zig
fn printChunk(chunk: []const u8) void {
    std.debug.print("{s}", .{chunk});
}
```

Streaming works for OpenAI-compatible providers over Chat Completions, and for Google.

### Agent: tool loop

```zig
fn addNumbers(arena: std.mem.Allocator, args_json: []const u8) anyerror![]const u8 {
    const Args = struct { a: f64, b: f64 };
    const args = try std.json.parseFromSliceLeaky(Args, arena, args_json, .{});
    return std.fmt.allocPrint(arena, "{d}", .{args.a + args.b});
}
```

```zig
const add: llmkit.Tool = .{
    .name = "add",
    .description = "Add two numbers",
    .schema =
    \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}
    ,
    .run = addNumbers,
};

const resp = try client.agent()
    .system("You are a calculator.")
    .addTool(add)
    .maxToolIterations(5)
    .chat(arena, key, "What is 2+3?");

std.debug.print("{s}\n", .{resp.text});
```

`chat` sends the prompt, runs each tool the model calls, sends the results back, and repeats until the model answers without a tool call. `maxToolIterations` caps the round-trips (default 10). A loop that is still calling tools at the cap fails with `error.MaxToolIterations`. `resp.usage` sums every round.

A tool that fails, or a call to a tool the agent does not have, is answered with an `error: ...` result so the model can recover. Each tool call fires `tool_call` middleware events, and a middleware can veto the call.

Tool dispatch covers Anthropic `tool_use`, OpenAI `tool_calls`, and Google `functionCall`.

### Conversation history

Pass earlier turns with `history`. The prompt is sent as the next user turn.

```zig
const no_calls: []const llmkit.ToolCall = &.{};
const turns = [_]llmkit.Message{
    .{ .role = "user", .content = "My name is Ada.", .tool_calls = no_calls, .tool_result = null, .provider_turn = null },
    .{ .role = "assistant", .content = "Nice to meet you, Ada.", .tool_calls = no_calls, .tool_result = null, .provider_turn = null },
};

const resp = try client.text().history(&turns).prompt(arena, key, "What is my name?");
std.debug.print("{s}\n", .{resp.text});
```

Every `Response` carries `provider_turn`: the assistant turn exactly as the provider returned it. Put it on the assistant `Message` you add to the history, and the next request sends that turn back unchanged. This keeps reasoning and provider metadata that the `content` and `tool_calls` fields cannot hold.

The agent does not return its history. Each `chat` call starts from the history you pass with `Agent.history`.

### Image input (vision)

```zig
const png_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "photo.png", arena, .unlimited);

const resp = try client.text()
    .image("image/png", png_bytes)
    .prompt(arena, key, "Describe this image.");
std.debug.print("{s}\n", .{resp.text});
```

### Image: text-to-image

```zig
const resp = try client.image()
    .model("gpt-image-1")
    .quality("high")
    .generate(arena, key, "A watercolor fox");

for (resp.images) |img| {
    std.debug.print("{s}, {d} bytes\n", .{ img.mime_type, img.bytes.len });
}
```

Add `.image(mime, bytes)` to send a reference image (an edit) on providers that accept one.

### Music: text-to-music

```zig
const resp = try client.music()
    .addLyrics("[verse]\nRain on the window")
    .generate(arena, key, "A slow piano ballad");

for (resp.audio) |clip| {
    std.debug.print("{s}, {d} bytes\n", .{ clip.mime_type, clip.bytes.len });
}
```

### Video: submit a job

```zig
const operation_id = try client.video()
    .model("veo-3.0-generate-001")
    .submit(arena, key, "A paper boat drifting down a stream");
std.debug.print("submitted: {s}\n", .{operation_id});
```

`submit` returns the provider's job id. Polling a video job is not yet supported; see [Not yet supported](#not-yet-supported).

### Speech: text-to-speech

```zig
const resp = try client.speech()
    .voice("alloy")
    .generate(arena, key, "Hello from Zig.");
std.debug.print("{s}, {d} bytes\n", .{ resp.audio.mime_type, resp.audio.bytes.len });
```

### Transcription: speech-to-text

```zig
const audio = try std.Io.Dir.cwd().readFileAlloc(io, "meeting.mp3", arena, .unlimited);

const resp = try client.transcription()
    .model("whisper-1")
    .transcribe(arena, key, "audio/mpeg", audio);
std.debug.print("{s}\n", .{resp.text});
```

### Upload

```zig
const pdf = try std.Io.Dir.cwd().readFileAlloc(io, "report.pdf", arena, .unlimited);

const file = try client.upload()
    .filename("report.pdf")
    .mime("application/pdf")
    .run(arena, key, pdf);

const resp = try client.text()
    .file(file.id)
    .prompt(arena, key, "Summarize this report.");
std.debug.print("{s}\n", .{resp.text});
```

### Batches

`batch` submits several prompts as one job and returns a handle at once.

```zig
const handle = try client.text()
    .model("claude-haiku-4-5")
    .maxTokens(256)
    .batch(arena, key, &.{ "Summarize Q3 revenue.", "Summarize Q4 revenue." });

const status = try handle.wait(arena);
if (status.result) |results| {
    for (results) |r| std.debug.print("{s}\n", .{r.text});
}
```

`handle.poll(arena)` makes one status request. `handle.wait(arena)` polls until the batch finishes, and fails with `error.PollTimeout` at the deadline. A failed batch returns a status with `state == .failed`, not an error.

The results hold one `Response` per prompt, in prompt order. A request that failed keeps its slot: its `finish_reason` holds the provider's reason, and `finish_message` holds the provider's error message.

Store `handle.value.id` to resume the batch from another process.

### Caching

```zig
const resp = try client.text()
    .system("A long, stable system prompt ...")
    .caching()
    .prompt(arena, key, "First question");
std.debug.print("cache write {?d}, cache read {?d}\n", .{ resp.usage.cache_write, resp.usage.cache_read });
```

`caching()` marks the request for prompt caching where the provider supports it (Anthropic `cache_control`). Creating a cache resource ahead of time (Google `cachedContents`) is not yet supported.

### Model catalogue

The catalogue is compiled in: listing it needs no key and makes no request.

```zig
const all = try client.models().list(arena);
for (all) |m| std.debug.print("{s} ({s})\n", .{ m.id, @tagName(m.provider) });

const chat_models = try client.models().withCapability(.chat_completion).list(arena);
std.debug.print("{d} chat models\n", .{chat_models.len});

if (client.models().get("claude-sonnet-4-6")) |m| {
    std.debug.print("context window: {d}\n", .{m.context_window});
}
```

### Capability query

```zig
if (client.supports(.batching)) {
    std.debug.print("{s} supports batches\n", .{@tagName(client.provider)});
}
```

## Options

The `Text` builder carries these chain methods:

| Method | Sets |
| --- | --- |
| `model(id)` | the model; without it, the provider's default model |
| `system(text)` | the system prompt |
| `maxTokens(n)` | the output token cap |
| `temperature(t)`, `topP(p)`, `topK(k)` | sampling |
| `frequencyPenalty(v)`, `presencePenalty(v)`, `seed(n)`, `stopSequences(list)` | generation controls |
| `reasoningEffort(level)`, `thinkingBudget(tokens)` | reasoning |
| `schema(json_schema)` | structured output |
| `protocol(.responses)` | the OpenAI Responses API instead of Chat Completions |
| `safetySettings(list)` | Google safety settings |
| `text(s)` | an extra text part on the user turn |

## Self-hosted endpoints

```zig
const local = llmkit.Client.init(gpa, io, .ollama).baseURL("http://localhost:11434");
_ = local;
```

## Custom headers

```zig
const tenant = llmkit.Client.init(gpa, io, .openai).addHeader("X-Tenant", "acme");
_ = tenant;
```

## Timeouts

```zig
const patient = llmkit.Client.init(gpa, io, .openai).timeout(120_000);
_ = patient;
```

`timeout` sets how long the client waits for the next bytes from the provider, in milliseconds. The wait restarts with every chunk, so a long stream that keeps sending never times out. 0 disables it; the default is 600 seconds.

## Middleware

A middleware sees every request before it is sent and after it returns. Returning a reason string in the `pre` phase vetoes the call, and the terminal fails with `error.MiddlewareVeto`.

```zig
const Logger = struct {
    fn call(_: *anyopaque, ev: *const llmkit.middleware.Event) ?[]const u8 {
        std.debug.print("{s} {s} {s}\n", .{ @tagName(ev.phase), @tagName(ev.op), ev.model });
        return null;
    }
};
```

```zig
var logger_state: u8 = 0;
const logged = client.addMiddleware(.{ .ptr = &logger_state, .call_fn = Logger.call });
_ = logged;
```

The `ptr` is yours: point it at whatever state the hook needs. It must outlive every client that holds it.

## Not yet supported

- **AWS Bedrock:** requests are not signed, so Bedrock calls cannot be sent.
- **Streaming** for the Anthropic and Bedrock chat shapes, and with `protocol(.responses)`. OpenAI-compatible providers and Google stream over Chat Completions.
- **Video polling:** `Video.submit` returns the job id; fetching the result is not available.
- **Transcription jobs:** `transcribe` works; asynchronous transcription jobs cannot be polled.
- **Cache resources:** creating a Google `cachedContents` resource ahead of time.
- **Raw responses:** the `raw` field on responses is always null.
- **Telemetry export:** the client does not send OpenTelemetry spans.

## Mirror

This repo is a read-only mirror of a private monorepo. File issues here; code patches should target the private source via `christian@aktagon.com`.

## License

MIT
