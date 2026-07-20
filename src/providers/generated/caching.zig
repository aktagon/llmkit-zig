// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;

pub const CachingMode = enum {
    automatic_caching,
    explicit_caching,
    resource_caching,
};

pub const ResourceLifecycleDef = struct {
    create_endpoint: []const u8,
    response_id_path: []const u8,
    reference_field: []const u8,
    polling_endpoint: []const u8,
    polling_status_path: []const u8,
    polling_done_value: []const u8,
    polling_error_values: []const []const u8,
    result_endpoint: []const u8,
    result_response_path: []const u8,
    result_file_id_path: []const u8,
    file_content_endpoint: []const u8,
};

pub const CachingDef = struct {
    mode: CachingMode,
    control_type: []const u8,
    write_tokens_path: []const u8,
    read_tokens_path: []const u8,
    default_ttl: []const u8,
    lifecycle: ?ResourceLifecycleDef,
};

pub fn cachingConfig(provider: ProviderName) ?CachingDef {
    return switch (provider) {
        .anthropic => .{
            .mode = .explicit_caching,
            .control_type = "ephemeral",
            .write_tokens_path = "usage.cache_creation_input_tokens",
            .read_tokens_path = "usage.cache_read_input_tokens",
            .default_ttl = "300",
            .lifecycle = null,
        },
        .google => .{
            .mode = .resource_caching,
            .control_type = "",
            .write_tokens_path = "",
            .read_tokens_path = "usageMetadata.cachedContentTokenCount",
            .default_ttl = "3600",
            .lifecycle =
                .{
                    .create_endpoint = "/v1beta/cachedContents",
                    .response_id_path = "name",
                    .reference_field = "cachedContent",
                    .polling_endpoint = "",
                    .polling_status_path = "",
                    .polling_done_value = "",
                    .polling_error_values = &.{},
                    .result_endpoint = "",
                    .result_response_path = "",
                    .result_file_id_path = "",
                    .file_content_endpoint = "",
                },
        },
        .openai => .{
            .mode = .automatic_caching,
            .control_type = "",
            .write_tokens_path = "",
            .read_tokens_path = "usage.prompt_tokens_details.cached_tokens",
            .default_ttl = "",
            .lifecycle = null,
        },
        else => null,
    };
}

pub const CacheUsagePaths = struct {
    write: []const u8,
    read: []const u8,
};

pub fn cacheUsagePaths(provider: ProviderName) CacheUsagePaths {
    if (cachingConfig(provider)) |config| {
        return .{ .write = config.write_tokens_path, .read = config.read_tokens_path };
    }
    return .{ .write = "", .read = "" };
}
