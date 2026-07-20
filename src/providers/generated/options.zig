// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;

/// A generation parameter the SDK knows how to place on the wire.
pub const OptionKey = enum {
    frequency_penalty,
    max_tokens,
    presence_penalty,
    reasoning_effort,
    seed,
    stop_sequences,
    temperature,
    thinking_budget,
    top_k,
    top_p,
};

/// The default wire key + value type for one option.
pub const OptionDef = struct {
    key: OptionKey,
    value_type: []const u8,
    default_json_key: []const u8,
};

/// One provider's supported option -> wire-key binding.
pub const SupportedOptionDef = struct {
    key: OptionKey,
    json_key: []const u8,
};

/// A provider-level option override (ADR-024): a different wire key,
/// an allowed-value whitelist, and/or extra JSON merged at option or
/// request-root level.
pub const OptionOverrideDef = struct {
    key: OptionKey,
    json_key: []const u8,
    allowed_values: []const []const u8,
    extra_fields_json: []const u8,
    root_extra_fields_json: []const u8,
};

/// A per-model option-key override (ADR-024); precedence lives in the resolver.
pub const ModelOptionOverrideDef = struct {
    matcher_kind: []const u8, // "id" | "pattern"
    matcher_value: []const u8,
    key: OptionKey,
    json_key: []const u8,
};

pub const all_options = [_]OptionDef{
    .{
        .key = .frequency_penalty,
        .value_type = "float64",
        .default_json_key = "frequency_penalty",
    },
    .{
        .key = .max_tokens,
        .value_type = "int",
        .default_json_key = "max_tokens",
    },
    .{
        .key = .presence_penalty,
        .value_type = "float64",
        .default_json_key = "presence_penalty",
    },
    .{
        .key = .reasoning_effort,
        .value_type = "string",
        .default_json_key = "reasoning_effort",
    },
    .{
        .key = .seed,
        .value_type = "int64",
        .default_json_key = "seed",
    },
    .{
        .key = .stop_sequences,
        .value_type = "[]string",
        .default_json_key = "stop_sequences",
    },
    .{
        .key = .temperature,
        .value_type = "float64",
        .default_json_key = "temperature",
    },
    .{
        .key = .thinking_budget,
        .value_type = "int",
        .default_json_key = "thinking_budget",
    },
    .{
        .key = .top_k,
        .value_type = "int",
        .default_json_key = "top_k",
    },
    .{
        .key = .top_p,
        .value_type = "float64",
        .default_json_key = "top_p",
    },
};

pub fn supportedOptions(provider: ProviderName) []const SupportedOptionDef {
    return switch (provider) {
        .ai21 => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .anthropic => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .reasoning_effort, .json_key = "output_config.effort" },
            .{ .key = .stop_sequences, .json_key = "stop_sequences" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .thinking_budget, .json_key = "thinking.budget_tokens" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .assemblyai => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
        },
        .azure => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .bedrock => &.{
            .{ .key = .max_tokens, .json_key = "maxTokens" },
            .{ .key = .stop_sequences, .json_key = "stopSequences" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .cerebras => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .cohere => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .deepseek => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .doubao => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .ernie => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .fireworks => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .google => &.{
            .{ .key = .max_tokens, .json_key = "max_output_tokens" },
            .{ .key = .reasoning_effort, .json_key = "thinkingConfig.thinkingLevel" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop_sequences" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .thinking_budget, .json_key = "thinkingConfig.thinkingBudget" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .grok => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .groq => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .inworld => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
        },
        .jan => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .llamacpp => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .lmstudio => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .minimax => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .mistral => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .moonshot => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .ollama => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .openai => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .reasoning_effort, .json_key = "reasoning_effort" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .openrouter => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .perplexity => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .pixverse => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
        },
        .qwen => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .recraft => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
        },
        .sambanova => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .together => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .vertex => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
        },
        .vidu => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
        },
        .vllm => &.{
            .{ .key = .frequency_penalty, .json_key = "frequency_penalty" },
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .presence_penalty, .json_key = "presence_penalty" },
            .{ .key = .seed, .json_key = "seed" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_k, .json_key = "top_k" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .workersai => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .yi => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
        .zhipu => &.{
            .{ .key = .max_tokens, .json_key = "max_tokens" },
            .{ .key = .stop_sequences, .json_key = "stop" },
            .{ .key = .temperature, .json_key = "temperature" },
            .{ .key = .top_p, .json_key = "top_p" },
        },
    };
}

pub fn optionOverrides(provider: ProviderName) []const OptionOverrideDef {
    return switch (provider) {
        .ai21 => &.{},
        .anthropic => &.{
            .{
                .key = .reasoning_effort,
                .json_key = "output_config.effort",
                .allowed_values = &.{ "low", "medium", "high", "xhigh", "max" },
                .extra_fields_json = "",
                .root_extra_fields_json = "{\"thinking\":{\"type\":\"adaptive\"}}",
            },
            .{
                .key = .thinking_budget,
                .json_key = "thinking.budget_tokens",
                .allowed_values = &.{},
                .extra_fields_json = "{\"type\":\"enabled\"}",
                .root_extra_fields_json = "",
            },
        },
        .assemblyai => &.{},
        .azure => &.{},
        .bedrock => &.{},
        .cerebras => &.{},
        .cohere => &.{},
        .deepseek => &.{},
        .doubao => &.{},
        .ernie => &.{},
        .fireworks => &.{},
        .google => &.{
            .{
                .key = .reasoning_effort,
                .json_key = "thinkingConfig.thinkingLevel",
                .allowed_values = &.{ "low", "high" },
                .extra_fields_json = "",
                .root_extra_fields_json = "",
            },
        },
        .grok => &.{},
        .groq => &.{},
        .inworld => &.{},
        .jan => &.{},
        .llamacpp => &.{},
        .lmstudio => &.{},
        .minimax => &.{},
        .mistral => &.{},
        .moonshot => &.{},
        .ollama => &.{},
        .openai => &.{
            .{
                .key = .reasoning_effort,
                .json_key = "reasoning_effort",
                .allowed_values = &.{ "low", "medium", "high" },
                .extra_fields_json = "",
                .root_extra_fields_json = "",
            },
        },
        .openrouter => &.{},
        .perplexity => &.{},
        .pixverse => &.{},
        .qwen => &.{},
        .recraft => &.{},
        .sambanova => &.{},
        .together => &.{},
        .vertex => &.{},
        .vidu => &.{},
        .vllm => &.{},
        .workersai => &.{},
        .yi => &.{},
        .zhipu => &.{},
    };
}

pub fn modelOptionOverrides(provider: ProviderName) []const ModelOptionOverrideDef {
    return switch (provider) {
        .ai21 => &.{},
        .anthropic => &.{},
        .assemblyai => &.{},
        .azure => &.{},
        .bedrock => &.{},
        .cerebras => &.{},
        .cohere => &.{},
        .deepseek => &.{},
        .doubao => &.{},
        .ernie => &.{},
        .fireworks => &.{},
        .google => &.{},
        .grok => &.{},
        .groq => &.{},
        .inworld => &.{},
        .jan => &.{},
        .llamacpp => &.{},
        .lmstudio => &.{},
        .minimax => &.{},
        .mistral => &.{},
        .moonshot => &.{},
        .ollama => &.{},
        .openai => &.{
            .{
                .matcher_kind = "pattern",
                .matcher_value = "gpt-5*",
                .key = .max_tokens,
                .json_key = "max_completion_tokens",
            },
            .{
                .matcher_kind = "pattern",
                .matcher_value = "o*",
                .key = .max_tokens,
                .json_key = "max_completion_tokens",
            },
        },
        .openrouter => &.{},
        .perplexity => &.{},
        .pixverse => &.{},
        .qwen => &.{},
        .recraft => &.{},
        .sambanova => &.{},
        .together => &.{},
        .vertex => &.{},
        .vidu => &.{},
        .vllm => &.{},
        .workersai => &.{},
        .yi => &.{},
        .zhipu => &.{},
    };
}
