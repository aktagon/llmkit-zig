// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;
pub const ResourceLifecycleDef = @import("caching.zig").ResourceLifecycleDef;

// Batch contract constants shared by every SDK (ADR-091).

/// Prefix + the request index is the id sent with each batch request.
pub const batch_request_id_prefix = "req-";
/// finish_reason of a batch slot whose request has no result line.
pub const batch_slot_missing = "missing";
/// finish_reason of a failed batch slot when the provider gives no reason.
pub const batch_slot_error = "error";

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
    result_key_path: []const u8,
    result_status_path: []const u8,
    result_success_values: []const []const u8,
    result_reason_paths: []const []const u8,
    result_message_paths: []const []const u8,
    request_count_paths: []const []const u8,
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
            .result_key_path = "custom_id",
            .result_status_path = "result.type",
            .result_success_values = &.{ "succeeded" },
            .result_reason_paths = &.{ "result.type" },
            .result_message_paths = &.{ "result.error.error.message" },
            .request_count_paths = &.{ "request_counts.processing", "request_counts.succeeded", "request_counts.errored", "request_counts.canceled", "request_counts.expired" },
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
                    .error_file_id_path = "",
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
            .result_key_path = "",
            .result_status_path = "",
            .result_success_values = &.{},
            .result_reason_paths = &.{},
            .result_message_paths = &.{},
            .request_count_paths = &.{},
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
            .result_key_path = "custom_id",
            .result_status_path = "response.status_code",
            .result_success_values = &.{ "200" },
            .result_reason_paths = &.{ "error.code", "response.body.error.code" },
            .result_message_paths = &.{ "error.message", "response.body.error.message" },
            .request_count_paths = &.{ "request_counts.total" },
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
                    .error_file_id_path = "error_file_id",
                    .file_content_endpoint = "/v1/files/{id}/content",
                },
        },
        else => null,
    };
}
