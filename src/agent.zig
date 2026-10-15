//! Agent builder + tool definitions (Phase 3 slice 3).
//!
//! The `Agent` builder carries a provider, an optional model/system, and a
//! bounded set of tool definitions. Its `buildBody` produces the ChatCompletion
//! request body (via the shared `request.buildChatBody`) with the tool
//! definitions attached per the effective chat wire shape — the OUTBOUND surface
//! the request-wire `tooldef-{openai,anthropic,google,bedrock}` goldens assert.
//!
//! Tool-def serialization is dispatched on the effective chat wire shape, NOT a
//! provider-name switch, and inserts each tool's JSON-Schema string VERBATIM
//! (the strict-transform walk fires only on the structured-output path, never on
//! tool params — mirrors Rust `apply_tool_defs` / Go `applyToolDefs`, confirmed
//! against the goldens). Only the Google shape reads the generated
//! `params_wire_field` fact (`parametersJsonSchema`); the other three carry the
//! params under a shape-fixed key.
//!
//! The `chat` terminal runs the auto-execution tool loop: send, read the tool
//! calls the reply asked for, run each tool, append the assistant and tool
//! turns to the history, and re-send — until a reply calls no tool or
//! `maxToolIterations` is reached. Each captured assistant turn is replayed
//! verbatim on the next request (ADR-085), through the same history builder
//! `Text.history` uses. Mirrors Rust `agent.rs` `run_tool_loop`.

const std = @import("std");
const json = @import("json.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const http = @import("http.zig");
const send = @import("send.zig");
const provider_turn = @import("provider_turn.zig");
const providers = @import("providers/generated/providers.zig");
const request_defs = @import("providers/generated/request_defs.zig");
const structs = @import("providers/generated/structs.zig");
const messages = @import("messages.zig");
const middleware = @import("middleware.zig");
const caching_mod = @import("caching.zig");

pub const Message = structs.Message;
pub const ToolCall = structs.ToolCall;

/// A tool the agent can offer. `schema` is a JSON-Schema STRING inserted VERBATIM
/// into the per-provider tool definition. `run` executes the tool in the
/// auto-execution loop: it receives the call's arguments as JSON text and
/// returns the result text, allocated in `arena`. A tool without `run`, or one
/// whose `run` fails, answers the model with an `error: ...` result rather than
/// failing the loop (Rust parity).
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
    run: ?RunFn = null,

    pub const RunFn = *const fn (arena: std.mem.Allocator, args_json: []const u8) anyerror![]const u8;
};

/// Fixed capacity for `Agent.addTool` — chain methods take no allocator
/// (ADR-069 ZIG-005), so tools live in a bounded array (like `Text`'s media
/// Parts). 16 is generous over any realistic tool set.
const max_tools = 16;

pub const Agent = struct {
    provider: providers.ProviderName,
    ctx: http.Ctx,
    model_: ?[]const u8 = null,
    system_: ?[]const u8 = null,
    caching_: bool = false,
    tools_: [max_tools]Tool = undefined,
    tool_count_: usize = 0,
    history_: []const Message = &.{},
    max_tool_iterations_: usize = 10,

    pub fn model(self: Agent, m: []const u8) Agent {
        var s = self;
        s.model_ = m;
        return s;
    }

    pub fn system(self: Agent, sys: []const u8) Agent {
        var s = self;
        s.system_ = sys;
        return s;
    }

    /// Enable prompt caching on the agent send path (ADR-026). Applied by
    /// construction in `buildBody`; the caching-agent-anthropic golden asserts
    /// the cache_control-annotated system block.
    pub fn caching(self: Agent) Agent {
        var s = self;
        s.caching_ = true;
        return s;
    }

    /// Append a tool definition (ADR-021 `Add*` appender).
    pub fn addTool(self: Agent, tool: Tool) Agent {
        var s = self;
        std.debug.assert(s.tool_count_ < max_tools);
        s.tools_[s.tool_count_] = tool;
        s.tool_count_ += 1;
        return s;
    }

    /// Seed the conversation history (ADR-020). `chat` appends its prompt as a
    /// user turn after it. `msgs` is caller-owned and must outlive `chat`.
    pub fn history(self: Agent, msgs: []const Message) Agent {
        var s = self;
        s.history_ = msgs;
        return s;
    }

    /// Cap the number of model round-trips one `chat` makes (default 10). A
    /// loop still asking for tools after `n` rounds fails with
    /// `error.MaxToolIterations`.
    pub fn maxToolIterations(self: Agent, n: usize) Agent {
        var s = self;
        s.max_tool_iterations_ = n;
        return s;
    }

    fn chatConfig(self: *const Agent, prompt: []const u8) request.ChatConfig {
        return .{
            .provider = self.provider,
            .model = self.model_,
            .system = self.system_,
            .prompt = prompt,
            .caching = self.caching_,
        };
    }

    /// Build the agent request body: the chat body + the tool definitions +
    /// (when caching is enabled) cache_control by construction. The request-wire
    /// tooldef / caching-agent goldens assert these bytes.
    pub fn buildBody(self: Agent, arena: std.mem.Allocator, prompt: []const u8) !json.Value {
        // Caching (self.caching_) is threaded through chatConfig -> buildChatBody,
        // so it is applied by construction before the tool defs are attached.
        var body = try request.buildChatBody(arena, self.chatConfig(prompt));
        if (self.tool_count_ > 0)
            try applyToolDefs(arena, &body, self.provider, self.tools_[0..self.tool_count_]);
        return body;
    }

    /// Run the tool loop and return the final reply. Its `usage` sums every
    /// round; a dimension any round left unreported stays unreported (ADR-081).
    pub fn chat(
        self: Agent,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !response.Response {
        return send.withTransport(&self.ctx, @TypeOf(self).chatWith, self, .{ arena, api_key, prompt });
    }

    /// `chat` over an injected transport (the seam tests mock). Everything the
    /// loop builds — the growing history, the bodies, the tool results — lives
    /// in `arena`.
    pub fn chatWith(
        self: Agent,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !response.Response {
        const spec = providers.spec(self.provider);
        // The agent exposes no protocol opt-in, so the effective shape is the
        // provider's default — the same fact `applyToolDefs` dispatches on.
        const shape = spec.chat_wire_shape;
        const model_id = try request.effectiveModel(spec, self.model_);

        var turns: std.ArrayList(Message) = .empty;
        try turns.appendSlice(arena, self.history_);
        if (prompt.len > 0) try turns.append(arena, .{
            .role = "user",
            .content = prompt,
            .tool_calls = &.{},
            .tool_result = null,
            .provider_turn = null,
        });

        var total: ?response.Usage = null;
        var round: usize = 0;
        while (round < self.max_tool_iterations_) : (round += 1) {
            var cfg = self.chatConfig("");
            cfg.history = turns.items;
            var body = try request.buildChatBody(arena, cfg);
            if (self.tool_count_ > 0)
                try applyToolDefs(arena, &body, self.provider, self.tools_[0..self.tool_count_]);
            // Each round's body carries the system prompt, so each round
            // creates its cache, as in Go/Rust.
            if (self.caching_) try caching_mod.applyResourceCaching(transport, arena, &self.ctx, self.provider, api_key, model_id, &body);

            const reply = try send.postJsonWithText(transport, arena, .{
                .provider = self.provider,
                .ctx = &self.ctx,
                .api_key = api_key,
                .endpoint = try request.chatEndpoint(arena, cfg),
                .op = .llm_request,
                .model = model_id,
            }, body);
            var resp = (try response.decodeResponse(arena, self.provider, shape, reply.value)).response;
            // ADR-085: capture the turn from the reply BYTES (see client.zig);
            // the next round replays it.
            resp.provider_turn = try provider_turn.capture(arena, reply.text, self.provider, shape);
            total = if (total) |t| addUsage(t, resp.usage) else resp.usage;

            const calls = try messages.extractToolCalls(arena, reply.value, self.provider, shape);
            if (calls.len == 0) {
                resp.usage = total.?;
                return resp;
            }
            try turns.append(arena, .{
                .role = "assistant",
                .content = "",
                .tool_calls = calls,
                .tool_result = null,
                .provider_turn = resp.provider_turn,
            });
            for (calls) |call| {
                const result = try self.runTool(arena, call, model_id);
                try turns.append(arena, .{
                    .role = "tool",
                    .content = "",
                    .tool_calls = &.{},
                    .tool_result = .{ .tool_use_id = call.id, .content = result },
                    .provider_turn = null,
                });
            }
        }
        return error.MaxToolIterations;
    }

    /// Run one tool call between `tool_call` middleware events. A pre-phase
    /// veto stops the loop with `error.MiddlewareVeto`.
    fn runTool(self: *const Agent, arena: std.mem.Allocator, call: ToolCall, model_id: []const u8) ![]const u8 {
        const mws = self.ctx.middlewares();
        const args = try json.stringify(arena, call.input orelse json.object());
        const base = middleware.Event{
            .op = .tool_call,
            .phase = .pre,
            .provider = @tagName(self.provider),
            .model = model_id,
            .tool = call.name,
            .args = args,
        };
        var veto_reason: []const u8 = "";
        try middleware.firePre(mws, base, &veto_reason);

        const result = if (self.findTool(call.name)) |tool| blk: {
            const run = tool.run orelse break :blk try std.fmt.allocPrint(arena, "error: tool \"{s}\" has no run function", .{call.name});
            break :blk run(arena, args) catch |err| try std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)});
        } else try std.fmt.allocPrint(arena, "error: unknown tool \"{s}\"", .{call.name});

        var post = base;
        post.args = "";
        post.result = result;
        middleware.firePost(mws, post);
        return result;
    }

    fn findTool(self: *const Agent, name: []const u8) ?Tool {
        for (self.tools_[0..self.tool_count_]) |t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }
};

/// Add two usages dimension by dimension. A dimension either side left
/// unreported stays unreported: a sum that silently skipped a round would read
/// as a measurement (ADR-081). Mirrors Rust `accumulate_usage`.
fn addUsage(a: response.Usage, b: response.Usage) response.Usage {
    var out: response.Usage = .{};
    inline for (std.meta.fields(response.Usage)) |f| {
        const x = @field(a, f.name);
        const y = @field(b, f.name);
        @field(out, f.name) = if (x != null and y != null) x.? + y.? else null;
    }
    return out;
}

/// Attach the tool definitions to `body`, dispatching on the effective chat wire
/// shape. The schema string is parsed once and inserted VERBATIM (no strict
/// transform). Mirrors Rust `apply_tool_defs`.
fn applyToolDefs(arena: std.mem.Allocator, body: *json.Value, provider: providers.ProviderName, tools: []const Tool) !void {
    const shape = providers.spec(provider).chat_wire_shape;

    if (std.mem.eql(u8, shape, "ChatOpenAI") or std.mem.eql(u8, shape, "ChatResponsesOpenAI")) {
        try applyOpenAITools(arena, body, tools);
    } else if (std.mem.eql(u8, shape, "ChatAnthropic")) {
        try applyAnthropicTools(arena, body, tools);
    } else if (std.mem.eql(u8, shape, "ChatGoogle")) {
        try applyGoogleTools(arena, body, provider, tools);
    } else if (std.mem.eql(u8, shape, "ChatBedrock")) {
        try applyBedrockTools(arena, body, tools);
    } else {
        return error.UnsupportedWireShape;
    }
}

/// Parse a tool's JSON-Schema string into an arena-backed Value (inserted
/// verbatim into the tool def).
fn schemaValue(arena: std.mem.Allocator, schema: []const u8) !json.Value {
    return std.json.parseFromSliceLeaky(json.Value, arena, schema, .{});
}

/// OpenAI: `tools:[{type:"function", function:{name, description, parameters}}]`.
fn applyOpenAITools(arena: std.mem.Allocator, body: *json.Value, tools: []const Tool) !void {
    var arr = json.array(arena);
    for (tools) |t| {
        var fnc = json.object();
        try json.set(arena, &fnc, "name", .{ .string = t.name });
        try json.set(arena, &fnc, "description", .{ .string = t.description });
        try json.set(arena, &fnc, "parameters", try schemaValue(arena, t.schema));

        var entry = json.object();
        try json.set(arena, &entry, "type", .{ .string = "function" });
        try json.set(arena, &entry, "function", fnc);
        try arr.array.append(entry);
    }
    try json.set(arena, body, "tools", arr);
}

/// Anthropic: flat `tools:[{name, description, input_schema}]`.
fn applyAnthropicTools(arena: std.mem.Allocator, body: *json.Value, tools: []const Tool) !void {
    var arr = json.array(arena);
    for (tools) |t| {
        var entry = json.object();
        try json.set(arena, &entry, "name", .{ .string = t.name });
        try json.set(arena, &entry, "description", .{ .string = t.description });
        try json.set(arena, &entry, "input_schema", try schemaValue(arena, t.schema));
        try arr.array.append(entry);
    }
    try json.set(arena, body, "tools", arr);
}

/// Google: `tools:[{functionDeclarations:[{name, description, <params_wire_field>}]}]`,
/// where the params key is the generated `params_wire_field` fact
/// (`parametersJsonSchema`).
fn applyGoogleTools(arena: std.mem.Allocator, body: *json.Value, provider: providers.ProviderName, tools: []const Tool) !void {
    const params_key = if (request_defs.toolCallConfig(provider)) |tc| tc.params_wire_field else "parameters";

    var decls = json.array(arena);
    for (tools) |t| {
        var decl = json.object();
        try json.set(arena, &decl, "name", .{ .string = t.name });
        try json.set(arena, &decl, "description", .{ .string = t.description });
        try json.set(arena, &decl, params_key, try schemaValue(arena, t.schema));
        try decls.array.append(decl);
    }

    var tool_obj = json.object();
    try json.set(arena, &tool_obj, "functionDeclarations", decls);
    var arr = json.array(arena);
    try arr.array.append(tool_obj);
    try json.set(arena, body, "tools", arr);
}

/// Bedrock: `toolConfig:{tools:[{toolSpec:{name, description, inputSchema:{json}}}]}`.
fn applyBedrockTools(arena: std.mem.Allocator, body: *json.Value, tools: []const Tool) !void {
    var arr = json.array(arena);
    for (tools) |t| {
        var input_schema = json.object();
        try json.set(arena, &input_schema, "json", try schemaValue(arena, t.schema));

        var spec = json.object();
        try json.set(arena, &spec, "name", .{ .string = t.name });
        try json.set(arena, &spec, "description", .{ .string = t.description });
        try json.set(arena, &spec, "inputSchema", input_schema);

        var entry = json.object();
        try json.set(arena, &entry, "toolSpec", spec);
        try arr.array.append(entry);
    }

    var tool_config = json.object();
    try json.set(arena, &tool_config, "tools", arr);
    try json.set(arena, body, "toolConfig", tool_config);
}

const wire_tool_schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}";

fn wireTool() Tool {
    return .{ .name = "get_weather", .description = "Get the current weather for a city.", .schema = wire_tool_schema };
}

/// A `Ctx` for the pure-seam tests below. Those tests exercise body/header
/// construction only, so the transport dependencies are never used — but Zig
/// has no ambient allocator or `Io`, so they must still be named.
fn testCtx() http.Ctx {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io };
}





















































// === Tool-loop tests ===

/// Records the tool_call events an agent fires, and can veto them.
const ToolHook = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayList(middleware.Event) = .empty,
    veto: bool = false,

    fn call(ptr: *anyopaque, ev: *const middleware.Event) ?[]const u8 {
        const self: *ToolHook = @ptrCast(@alignCast(ptr));
        if (ev.op != .tool_call) return null;
        self.events.append(self.gpa, ev.*) catch {};
        if (self.veto and ev.phase == .pre) return "vetoed in test";
        return null;
    }

    fn hook(self: *ToolHook) middleware.Middleware {
        return .{ .ptr = self, .call_fn = call };
    }
};

fn weatherRun(arena: std.mem.Allocator, args_json: []const u8) anyerror![]const u8 {
    const args = try std.json.parseFromSliceLeaky(json.Value, arena, args_json, .{});
    return std.fmt.allocPrint(arena, "12C in {s}", .{json.getPath(args, "city").?.string});
}

fn runnableTool() Tool {
    var t = wireTool();
    t.run = weatherRun;
    return t;
}

fn sentBody(arena: std.mem.Allocator, mock: *const http.MockTransport, i: usize) !json.Value {
    return std.json.parseFromSliceLeaky(json.Value, arena, mock.captured.items[i].body, .{});
}

const openai_call_reply =
    \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Oslo\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":4}}
;
const openai_final_reply =
    \\{"choices":[{"message":{"role":"assistant","content":"It is 12C in Oslo."},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":6}}
;

/// Counts the cache_create events an agent fires.
const CacheHook = struct {
    pre: usize = 0,
    post: usize = 0,

    fn call(ptr: *anyopaque, ev: *const middleware.Event) ?[]const u8 {
        const self: *CacheHook = @ptrCast(@alignCast(ptr));
        if (ev.op != .cache_create) return null;
        if (ev.phase == .pre) self.pre += 1 else self.post += 1;
        return null;
    }
};







































































































































