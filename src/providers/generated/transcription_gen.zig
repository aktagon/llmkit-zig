// Code generated — DO NOT EDIT.


const ProviderName = @import("providers.zig").ProviderName;

pub const TranscriptionDef = struct {
    wire_shape: []const u8,
    /// interaction: "sync" | "async"; request_encoding: "json" | "multipart".
    interaction: []const u8,
    request_encoding: []const u8,
    submit_endpoint: []const u8,
    poll_endpoint: []const u8,
    upload_endpoint: []const u8,
    submit_handle_field: []const u8,
    status_path: []const u8,
    done_status: []const u8,
    error_status: []const u8,
};

pub fn transcriptionConfig(provider: ProviderName) ?TranscriptionDef {
    return switch (provider) {
        .assemblyai => .{
            .wire_shape = "TranscriptionAssemblyAI",
            .interaction = "async",
            .request_encoding = "json",
            .submit_endpoint = "/v2/transcript",
            .poll_endpoint = "/v2/transcript/{id}",
            .upload_endpoint = "/v2/upload",
            .submit_handle_field = "id",
            .status_path = "status",
            .done_status = "completed",
            .error_status = "error",
        },
        .openai => .{
            .wire_shape = "TranscriptionOpenAI",
            .interaction = "sync",
            .request_encoding = "multipart",
            .submit_endpoint = "/v1/audio/transcriptions",
            .poll_endpoint = "",
            .upload_endpoint = "",
            .submit_handle_field = "",
            .status_path = "",
            .done_status = "",
            .error_status = "",
        },
        else => null,
    };
}
