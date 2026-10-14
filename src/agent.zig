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
//! Scope note (Phase 3): the fixture-gated surface is the tool DEFINITIONS in
//! the outbound request. A single-round `chat` terminal (send the tool-def
//! request, parse the reply) is provided over the injected transport; the
//! multi-turn auto-execution tool LOOP (extract tool calls -> run -> re-send
//! with a tool-result history) needs a multi-turn message-history body builder
//! and is not gated by any wire fixture — deferred to a later phase alongside
//! the remaining capabilities (HANDOFF-043). `Tool.run` is carried now so the
//! loop can land without a Tool-shape change.

const std = @import("std");
const json = @import("json.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const http = @import("http.zig");
const send = @import("send.zig");
const provider_turn = @import("provider_turn.zig");
const providers = @import("providers/generated/providers.zig");
const request_defs = @import("providers/generated/request_defs.zig");

/// A tool the agent can offer. `schema` is a JSON-Schema STRING inserted VERBATIM
/// into the per-provider tool definition. `run`, when set, executes the tool
/// for the (future) auto-execution loop; the wire-tested tool-def surface needs
/// only name/description/schema.
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

    /// Send the tool-def request and return the parsed reply — ONE round.
    ///
    /// The multi-turn auto-execution loop (run the model's chosen tool, feed the
    /// result back, repeat until it stops asking) is NOT implemented. It is not
    /// blocked on the send path, which now exists: it needs multi-turn MESSAGE
    /// support in `request.ChatConfig`, which today carries a single `prompt`.
    /// Adding a message array means changing `buildChatBody` — the function
    /// whose exact bytes seven SDKs assert against shared goldens — so it is its
    /// own slice, not a rider on this one. `Tool.run` is carried on the builder
    /// and ready for that loop; until then a caller drives tool execution
    /// themselves from the reply.
    pub fn chat(
        self: Agent,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !response.Response {
        return send.withTransport(&self.ctx, @TypeOf(self).chatWith, self, .{ arena, api_key, prompt });
    }

    /// `chat` over an injected transport (the seam tests mock).
    pub fn chatWith(
        self: Agent,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        prompt: []const u8,
    ) !response.Response {
        const body = try self.buildBody(arena, prompt);
        const reply = try send.postJsonWithText(transport, arena, .{
            .provider = self.provider,
            .ctx = &self.ctx,
            .api_key = api_key,
            .endpoint = providers.spec(self.provider).endpoint,
            .op = .llm_request,
            .model = self.model_ orelse "",
        }, body);
        // The agent exposes no protocol opt-in, so the effective shape is the
        // provider's default — the same fact `applyToolDefs` dispatches on.
        const shape = providers.spec(self.provider).chat_wire_shape;
        var resp = (try response.decodeResponse(arena, self.provider, shape, reply.value)).response;
        // ADR-085: capture the turn from the reply BYTES (see client.zig). The
        // single-round terminal returns it so a caller running their own loop can
        // thread it forward; the auto-execution loop that would REPLAY it lands
        // with the multi-turn history builder (provider_turn.zig scope note).
        resp.provider_turn = try provider_turn.capture(arena, reply.text, self.provider, shape);
        return resp;
    }
};

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




















































