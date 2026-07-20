// Code generated — DO NOT EDIT.


/// The OTEL GenAI binding facts + attribute mappings (ADR-054), generated
///
///
pub const semconv_version = "1.29.0";
pub const traces_path = "/v1/traces";
pub const endpoint_required = true;
pub const capture_content_default = false;

// OTEL GenAI attribute keys (mapsToOtelAttribute).
pub const otel_attr_op = "gen_ai.operation.name"; // Event.op
pub const otel_attr_provider = "gen_ai.system"; // Event.provider
pub const otel_attr_model = "gen_ai.request.model"; // Event.model
pub const otel_attr_err_type = "error.type"; // Event.err_type

// OTEL GenAI usage attribute keys (otelUsageAttribute).
pub const otel_usage_input = "gen_ai.usage.input_tokens";
pub const otel_usage_output = "gen_ai.usage.output_tokens";

/// Maps a `MiddlewareOp` tag to its `gen_ai.operation.name` value; ops
/// without a documented semconv value return null (honest).
pub fn operationName(op: @import("middleware_gen.zig").MiddlewareOp) ?[]const u8 {
    return switch (op) {
        .llm_request => "chat",
        .tool_call => "execute_tool",
        else => null,
    };
}
