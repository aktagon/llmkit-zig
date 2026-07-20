// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;

pub fn responseTextPath(provider: ProviderName) []const u8 {
    return switch (provider) {
        .ai21 => "choices[0].message.content",
        .anthropic => "content[0].text",
        .assemblyai => "",
        .azure => "choices[0].message.content",
        .bedrock => "output.message.content[0].text",
        .cerebras => "choices[0].message.content",
        .cohere => "choices[0].message.content",
        .deepseek => "choices[0].message.content",
        .doubao => "choices[0].message.content",
        .ernie => "choices[0].message.content",
        .fireworks => "choices[0].message.content",
        .google => "candidates[0].content.parts[0].text",
        .grok => "choices[0].message.content",
        .groq => "choices[0].message.content",
        .inworld => "",
        .jan => "choices[0].message.content",
        .llamacpp => "choices[0].message.content",
        .lmstudio => "choices[0].message.content",
        .minimax => "choices[0].message.content",
        .mistral => "choices[0].message.content",
        .moonshot => "choices[0].message.content",
        .ollama => "choices[0].message.content",
        .openai => "choices[0].message.content",
        .openrouter => "choices[0].message.content",
        .perplexity => "choices[0].message.content",
        .pixverse => "",
        .qwen => "choices[0].message.content",
        .recraft => "",
        .sambanova => "choices[0].message.content",
        .together => "choices[0].message.content",
        .vertex => "",
        .vidu => "",
        .vllm => "choices[0].message.content",
        .workersai => "choices[0].message.content",
        .yi => "choices[0].message.content",
        .zhipu => "choices[0].message.content",
    };
}

pub const UsagePaths = struct {
    input: []const u8,
    output: []const u8,
};

pub fn usagePaths(provider: ProviderName) UsagePaths {
    return switch (provider) {
        .ai21 => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .anthropic => .{ .input = "usage.input_tokens", .output = "usage.output_tokens" },
        .assemblyai => .{ .input = "", .output = "" },
        .azure => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .bedrock => .{ .input = "usage.inputTokens", .output = "usage.outputTokens" },
        .cerebras => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .cohere => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .deepseek => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .doubao => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .ernie => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .fireworks => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .google => .{ .input = "usageMetadata.promptTokenCount", .output = "usageMetadata.candidatesTokenCount" },
        .grok => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .groq => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .inworld => .{ .input = "", .output = "" },
        .jan => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .llamacpp => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .lmstudio => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .minimax => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .mistral => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .moonshot => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .ollama => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .openai => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .openrouter => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .perplexity => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .pixverse => .{ .input = "", .output = "" },
        .qwen => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .recraft => .{ .input = "", .output = "" },
        .sambanova => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .together => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .vertex => .{ .input = "", .output = "" },
        .vidu => .{ .input = "", .output = "" },
        .vllm => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .workersai => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .yi => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
        .zhipu => .{ .input = "usage.prompt_tokens", .output = "usage.completion_tokens" },
    };
}

/// ADR-027: provider-reported cost path; empty when unreported.
pub fn usageCostPath(provider: ProviderName) []const u8 {
    return switch (provider) {
        .ai21 => "",
        .anthropic => "",
        .assemblyai => "",
        .azure => "",
        .bedrock => "",
        .cerebras => "",
        .cohere => "",
        .deepseek => "",
        .doubao => "",
        .ernie => "",
        .fireworks => "",
        .google => "",
        .grok => "usage.cost_in_usd_ticks",
        .groq => "",
        .inworld => "",
        .jan => "",
        .llamacpp => "",
        .lmstudio => "",
        .minimax => "",
        .mistral => "",
        .moonshot => "",
        .ollama => "",
        .openai => "",
        .openrouter => "usage.cost",
        .perplexity => "",
        .pixverse => "",
        .qwen => "",
        .recraft => "",
        .sambanova => "",
        .together => "",
        .vertex => "",
        .vidu => "",
        .vllm => "",
        .workersai => "",
        .yi => "",
        .zhipu => "",
    };
}

/// ADR-027: multiplier converting the reported cost to USD (xAI ticks -> 1e-10).
pub fn usageCostScale(provider: ProviderName) f64 {
    return switch (provider) {
        .grok => 1e-10,
        else => 1.0,
    };
}
