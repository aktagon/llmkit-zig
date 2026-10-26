// Code generated — DO NOT EDIT.


const std = @import("std");
const ProviderName = @import("providers.zig").ProviderName;
const Capability = @import("../../capability.zig").Capability;

/// Catalogue data (ADR-019). Compiled-in model defs + per-model
/// capability lookup + per-provider live-endpoint config. Walked at
/// runtime by the Models / ScopedModels / Providers builders.

/// CompiledModelDef is the static representation of one compiled-in
/// model. The hand-coded runtime materializes an owned ModelInfo from a
/// CompiledModelDef on demand.
pub const CompiledModelDef = struct {
    id: []const u8,
    provider: ProviderName,
    capabilities: []const Capability,
    display_name: []const u8,
    description: []const u8,
    context_window: i64,
    max_output: i64,
};

pub const compiled_in_models = [_]CompiledModelDef{
    .{
        .id = "claude-haiku-4-5-20251001",
        .provider = .anthropic,
        .capabilities = &.{ .chat_completion, .tool_calling },
        .display_name = "Claude Haiku 4.5",
        .description = "",
        .context_window = 200000,
        .max_output = 64000,
    },
    .{
        .id = "claude-opus-4-5-20251101",
        .provider = .anthropic,
        .capabilities = &.{ .chat_completion, .tool_calling },
        .display_name = "Claude Opus 4.5",
        .description = "",
        .context_window = 200000,
        .max_output = 64000,
    },
    .{
        .id = "claude-opus-4-6",
        .provider = .anthropic,
        .capabilities = &.{ .chat_completion, .tool_calling },
        .display_name = "Claude Opus 4.6",
        .description = "",
        .context_window = 1000000,
        .max_output = 128000,
    },
    .{
        .id = "claude-opus-4-7",
        .provider = .anthropic,
        .capabilities = &.{ .chat_completion, .tool_calling },
        .display_name = "Claude Opus 4.7",
        .description = "",
        .context_window = 1000000,
        .max_output = 128000,
    },
    .{
        .id = "claude-sonnet-4-5-20250929",
        .provider = .anthropic,
        .capabilities = &.{ .chat_completion, .tool_calling },
        .display_name = "Claude Sonnet 4.5",
        .description = "",
        .context_window = 1000000,
        .max_output = 64000,
    },
    .{
        .id = "claude-sonnet-4-6",
        .provider = .anthropic,
        .capabilities = &.{ .chat_completion, .tool_calling },
        .display_name = "Claude Sonnet 4.6",
        .description = "",
        .context_window = 1000000,
        .max_output = 128000,
    },
    .{
        .id = "gemini-2.5-flash",
        .provider = .google,
        .capabilities = &.{ .chat_completion, .reasoning, .tool_calling },
        .display_name = "Gemini 2.5 Flash",
        .description = "Stable version of Gemini 2.5 Flash",
        .context_window = 1048576,
        .max_output = 65536,
    },
    .{
        .id = "gemini-2.5-flash-lite",
        .provider = .google,
        .capabilities = &.{ .chat_completion, .tool_calling },
        .display_name = "Gemini 2.5 Flash-Lite",
        .description = "Stable version of Gemini 2.5 Flash-Lite",
        .context_window = 1048576,
        .max_output = 65536,
    },
    .{
        .id = "gemini-2.5-pro",
        .provider = .google,
        .capabilities = &.{ .chat_completion, .reasoning, .tool_calling },
        .display_name = "Gemini 2.5 Pro",
        .description = "Stable release of Gemini 2.5 Pro",
        .context_window = 1048576,
        .max_output = 65536,
    },
    .{
        .id = "gemini-3-pro-image-preview",
        .provider = .google,
        .capabilities = &.{ .image_generation },
        .display_name = "Nano Banana Pro",
        .description = "Gemini 3 Pro Image Preview",
        .context_window = 131072,
        .max_output = 32768,
    },
    .{
        .id = "gemini-3-pro-preview",
        .provider = .google,
        .capabilities = &.{ .chat_completion, .reasoning, .tool_calling },
        .display_name = "Gemini 3 Pro Preview",
        .description = "Gemini 3 Pro Preview",
        .context_window = 1048576,
        .max_output = 65536,
    },
    .{
        .id = "gemini-nano-banana-2.1",
        .provider = .google,
        .capabilities = &.{ .image_generation },
        .display_name = "Nano Banana 2.1",
        .description = "Gemini Nano Banana 2.1",
        .context_window = 131072,
        .max_output = 32768,
    },
    .{
        .id = "gpt-4o",
        .provider = .openai,
        .capabilities = &.{ .chat_completion, .tool_calling },
        .display_name = "",
        .description = "",
        .context_window = 0,
        .max_output = 0,
    },
    .{
        .id = "gpt-4o-mini",
        .provider = .openai,
        .capabilities = &.{ .chat_completion, .tool_calling },
        .display_name = "",
        .description = "",
        .context_window = 0,
        .max_output = 0,
    },
    .{
        .id = "gpt-5",
        .provider = .openai,
        .capabilities = &.{ .chat_completion, .reasoning, .tool_calling },
        .display_name = "",
        .description = "",
        .context_window = 0,
        .max_output = 0,
    },
    .{
        .id = "gpt-image-1",
        .provider = .openai,
        .capabilities = &.{ .image_generation },
        .display_name = "",
        .description = "",
        .context_window = 0,
        .max_output = 0,
    },
    .{
        .id = "o1",
        .provider = .openai,
        .capabilities = &.{ .chat_completion, .reasoning },
        .display_name = "",
        .description = "",
        .context_window = 0,
        .max_output = 0,
    },
    .{
        .id = "o3",
        .provider = .openai,
        .capabilities = &.{ .chat_completion, .reasoning, .tool_calling },
        .display_name = "",
        .description = "",
        .context_window = 0,
        .max_output = 0,
    },
    .{
        .id = "o4-mini",
        .provider = .openai,
        .capabilities = &.{ .chat_completion, .reasoning, .tool_calling },
        .display_name = "",
        .description = "",
        .context_window = 0,
        .max_output = 0,
    },
};

/// (ProviderName, model_id) -> []const Capability lookup — consulted by
/// the live-path parsers to enrich ModelInfo records with capability data
///
/// entry for the pair.
pub fn ontologyCapabilities(provider: ProviderName, model_id: []const u8) ?[]const Capability {
    for (compiled_in_models) |m| {
        if (m.provider == provider and std.mem.eql(u8, m.id, model_id)) {
            return m.capabilities;
        }
    }
    return null;
}

/// Per-provider live-catalogue endpoint config (ADR-019). Providers
/// without a live endpoint return null; ScopedModels.list then errors
/// with CatalogueError.not_supported.
pub const CatalogueConfig = struct {
    endpoint: []const u8,
    pagination: []const u8,
    cursor_param: []const u8,
    parser_kind: []const u8,
    spec_url: []const u8,
    spec_format: []const u8,
};

const anthropic_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "CursorByLastID",
    .cursor_param = "after_id",
    .parser_kind = "ParseAnthropicModels",
    .spec_url = "https://github.com/anthropics/anthropic-sdk-typescript/blob/main/api.md",
    .spec_format = "OpenAPI3",
};

const cerebras_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const deepseek_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const fireworks_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const google_catalogue: CatalogueConfig = .{
    .endpoint = "/v1beta/models",
    .pagination = "CursorOpaqueToken",
    .cursor_param = "pageToken",
    .parser_kind = "ParseGoogleModels",
    .spec_url = "https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta",
    .spec_format = "GoogleDiscovery",
};

const grok_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const groq_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const jan_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const llamacpp_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const lmstudio_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const mistral_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "https://raw.githubusercontent.com/mistralai/platform-docs-public/main/openapi.yaml",
    .spec_format = "OpenAPI3",
};

const moonshot_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const ollama_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "https://raw.githubusercontent.com/ollama/ollama/main/docs/openapi.yaml",
    .spec_format = "OpenAPI3",
};

const openai_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "https://github.com/openai/openai-openapi/blob/master/openapi.yaml",
    .spec_format = "OpenAPI3",
};

const openrouter_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "https://openrouter.ai/openapi.json",
    .spec_format = "OpenAPI3",
};

const qwen_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

const together_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "https://raw.githubusercontent.com/togethercomputer/openapi/main/openapi.yaml",
    .spec_format = "OpenAPI3",
};

const vllm_catalogue: CatalogueConfig = .{
    .endpoint = "/v1/models",
    .pagination = "PaginationNone",
    .cursor_param = "",
    .parser_kind = "ParseOpenAICohortModels",
    .spec_url = "",
    .spec_format = "",
};

pub fn catalogueConfig(provider: ProviderName) ?CatalogueConfig {
    return switch (provider) {
        .anthropic => anthropic_catalogue,
        .cerebras => cerebras_catalogue,
        .deepseek => deepseek_catalogue,
        .fireworks => fireworks_catalogue,
        .google => google_catalogue,
        .grok => grok_catalogue,
        .groq => groq_catalogue,
        .jan => jan_catalogue,
        .llamacpp => llamacpp_catalogue,
        .lmstudio => lmstudio_catalogue,
        .mistral => mistral_catalogue,
        .moonshot => moonshot_catalogue,
        .ollama => ollama_catalogue,
        .openai => openai_catalogue,
        .openrouter => openrouter_catalogue,
        .qwen => qwen_catalogue,
        .together => together_catalogue,
        .vllm => vllm_catalogue,
        else => null,
    };
}
