// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;
pub const ResourceLifecycleDef = @import("caching.zig").ResourceLifecycleDef;

pub const BatchInputMode = enum {
    inline_requests,
    file_reference_input,
};

pub const BatchDef = struct {
    input_mode: BatchInputMode,
    input_field: []const u8,
    file_purpose: []const u8,
    request_wrapper: []const u8,
    completion_window: []const u8,
    endpoint_path: []const u8,
    item_body_field: []const u8,
    result_body_path: []const u8,
    lifecycle: ?ResourceLifecycleDef,
};

pub fn batchConfig(provider: ProviderName) ?BatchDef {
    return switch (provider) {
        .anthropic => .{
            .input_mode = .inline_requests,
            .input_field = "",
            .file_purpose = "",
            .request_wrapper = "requests",
            .completion_window = "",
            .endpoint_path = "",
            .item_body_field = "params",
            .result_body_path = "result.message",
            .lifecycle =
                .{
                    .create_endpoint = "/v1/messages/batches",
                    .response_id_path = "id",
                    .reference_field = "",
                    .polling_endpoint = "",
                    .polling_status_path = "processing_status",
                    .polling_done_value = "ended",
                    .polling_error_values = &.{},
                    .result_endpoint = "/v1/messages/batches/{id}/results",
                    .result_response_path = "",
                    .result_file_id_path = "",
                    .file_content_endpoint = "",
                },
        },
        .google => .{
            .input_mode = .inline_requests,
            .input_field = "",
            .file_purpose = "",
            .request_wrapper = "requests",
            .completion_window = "",
            .endpoint_path = "",
            .item_body_field = "",
            .result_body_path = "",
            .lifecycle = null,
        },
        .openai => .{
            .input_mode = .file_reference_input,
            .input_field = "input_file_id",
            .file_purpose = "batch",
            .request_wrapper = "",
            .completion_window = "24h",
            .endpoint_path = "/v1/chat/completions",
            .item_body_field = "",
            .result_body_path = "response.body",
            .lifecycle =
                .{
                    .create_endpoint = "/v1/batches",
                    .response_id_path = "id",
                    .reference_field = "",
                    .polling_endpoint = "",
                    .polling_status_path = "status",
                    .polling_done_value = "completed",
                    .polling_error_values = &.{ "failed", "expired", "cancelled" },
                    .result_endpoint = "",
                    .result_response_path = "",
                    .result_file_id_path = "output_file_id",
                    .file_content_endpoint = "/v1/files/{id}/content",
                },
        },
        else => null,
    };
}
