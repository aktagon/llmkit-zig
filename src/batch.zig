//! Batch execution mode (ADR-064) + its Job adapter (Phase 3 slice 4).
//!
//! Batch is a ChatCompletion execution mode: each request re-serializes the chat
//! body, wrapped in the provider's batch envelope. Three seams:
//!   - `buildBatchBody` (OUTBOUND): the inline-requests CREATE envelope
//!     `{<request_wrapper>: [{custom_id:"req-N", <item_body_field>: <chat body>}]}`
//!     (the Anthropic `params` key is load-bearing), plus the anthropic-beta
//!     values composed across items — so a file-referencing batch item carries
//!     the files-api beta on the CREATE request (BUG-017 / the batch-modality
//!     witness). The request-wire `batch-multimodal-anthropic` golden (+ its
//!     `.headers.json`) asserts these.
//!   - `parseBatchResults` (INBOUND): a completed batch's results file (one JSONL
//!     line per request) -> the successful `Response` subset, reading each line's
//!     body at the generated `result_body_path` (Anthropic `result.message`,
//!     OpenAI `response.body`) and SKIPPING errored/malformed lines (a throwing
//!     parser would destroy a completed, possibly hours-long batch — HANDOFF-036
//!     A1). The response-wire `batch-results-anthropic` golden asserts the
//!     projection.
//!   - `BatchHandle.poll` (LIFECYCLE): the Job engine's batch adapter — poll the
//!     batch status, classify (done/error from the generated lifecycle facts),
//!     and on success fetch the results (OpenAI two-hop via `output_file_id` ->
//!     file content; Anthropic direct results endpoint). The lifecycle-wire
//!     `batch-{succeeded,failed}` goldens assert the normalized JobStatus.
//! All three read the generated `BatchDef` / `ResourceLifecycleDef`, never a
//! provider name. Mirrors `rust/src/batch.rs` / `go/batch.go`.

const std = @import("std");
const json = @import("json.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const http = @import("http.zig");
const job = @import("job.zig");
const providers = @import("providers/generated/providers.zig");
const batch_defs = @import("providers/generated/batch.zig");

const Response = response.Response;

/// The CREATE envelope payload + the anthropic-beta values composed across the
/// batch items (empty when no item references a file). The caller composes the
/// betas into an `anthropic-beta` header on the CREATE request.
pub const BatchBuildResult = struct {
    payload: json.Value,
    beta_headers: []const []const u8,
};

/// Build the inline-requests batch CREATE body from a config template + one
/// prompt per item. Each item reuses `template` (model/system/media/options),
/// varying only the prompt, and is wrapped `{custom_id:"req-N",
/// <item_body_field>: <chat body>}`. Any item that references an uploaded file
/// contributes its `anthropic-beta` value to `beta_headers` (deduped). Only the
/// inline-requests mode is implemented (Anthropic); the file-reference-input
/// mode (OpenAI's JSONL upload) is a later phase.
pub fn buildBatchBody(
    arena: std.mem.Allocator,
    provider: providers.ProviderName,
    template: request.ChatConfig,
    prompts: []const []const u8,
) !BatchBuildResult {
    const bd = batch_defs.batchConfig(provider) orelse return error.UnsupportedWireShape;
    if (bd.input_mode != .inline_requests) return error.UnsupportedWireShape;

    var items = json.array(arena);
    var betas: std.ArrayList([]const u8) = .empty;

    for (prompts, 0..) |prompt, i| {
        var cfg = template;
        cfg.prompt = prompt;

        const item_body = try request.buildChatBody(arena, cfg);

        // Compose any file-reference beta the item body needs (BUG-017): the
        // header seam returns `anthropic-beta` when the item references a file.
        const item_headers = try request.buildRequestHeaders(arena, cfg);
        for (item_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "anthropic-beta"))
                try addUnique(arena, &betas, h.value);
        }

        var item = json.object();
        try json.set(arena, &item, "custom_id", .{ .string = try std.fmt.allocPrint(arena, "req-{d}", .{i}) });
        const field = if (bd.item_body_field.len > 0) bd.item_body_field else "params";
        try json.set(arena, &item, field, item_body);
        try items.array.append(item);
    }

    var payload = json.object();
    const wrapper = if (bd.request_wrapper.len > 0) bd.request_wrapper else "requests";
    try json.set(arena, &payload, wrapper, items);

    return .{ .payload = payload, .beta_headers = try betas.toOwnedSlice(arena) };
}

/// Append `value` to `list` if not already present (dedup by value).
fn addUnique(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |v| if (std.mem.eql(u8, v, value)) return;
    try list.append(arena, value);
}

/// Parse a completed batch's results file (JSONL, one line per request) into the
/// successful `Response` subset. Each line's chat body is read at the generated
/// `result_body_path`; a line missing it (an errored result) or unparseable is
/// SKIPPED (never throws — a completed batch's partial results are still
/// valuable). No SDK matches by `custom_id`; all assume line order.
pub fn parseBatchResults(arena: std.mem.Allocator, provider: providers.ProviderName, results: []const u8) ![]Response {
    const bd = batch_defs.batchConfig(provider) orelse return error.UnsupportedWireShape;
    const body_path = bd.result_body_path;

    var out: std.ArrayList(Response) = .empty;
    var lines = std.mem.splitScalar(u8, results, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch continue;
        const body = if (body_path.len > 0) (json.getPath(parsed, body_path) orelse continue) else parsed;

        const resp = response.parseChatResponse(arena, provider, body) catch continue;
        try out.append(arena, resp);
    }
    return out.toOwnedSlice(arena);
}

/// A handle to a submitted batch — the Job engine's batch adapter target. Carries
/// the injected transport so the poll/result hops are mockable. `base_url` backs
/// the poll/result URLs (defaults to the provider's base; a client override or a
/// mock URL replaces it).
pub const BatchHandle = struct {
    id: []const u8,
    provider: providers.ProviderName,
    transport: http.Transport,
    api_key: []const u8 = "",
    base_url: ?[]const u8 = null,

    /// One poll round-trip (ADR-063 Poll): status -> classify -> (fetch results
    /// on success). Returns the normalized JobStatus.
    pub fn poll(self: BatchHandle, arena: std.mem.Allocator) !job.JobStatus([]Response) {
        return job.pollOnce(BatchAdapter, .{ .handle = self }, arena);
    }
};

/// The Job-engine adapter for a batch (the four seams). `Out` is the successful
/// `Response` slice.
const BatchAdapter = struct {
    handle: BatchHandle,

    pub const Out = []Response;

    fn lifecycle(self: BatchAdapter) batch_defs.ResourceLifecycleDef {
        return batch_defs.batchConfig(self.handle.provider).?.lifecycle.?;
    }

    fn base(self: BatchAdapter) []const u8 {
        return self.handle.base_url orelse providers.spec(self.handle.provider).base_url;
    }

    pub fn config(self: BatchAdapter, arena: std.mem.Allocator) !job.LifecycleConfig {
        const lc = self.lifecycle();
        // done_values must outlive this call, so allocate the single-element
        // slice in the arena (a `&.{...}` literal would dangle to the stack).
        const done = try arena.alloc([]const u8, 1);
        done[0] = lc.polling_done_value;
        return .{
            .status_path = lc.polling_status_path,
            .done_values = done,
            .error_values = lc.polling_error_values,
            .noun = "batch",
        };
    }

    pub fn poll(self: BatchAdapter, arena: std.mem.Allocator) !job.PollBody {
        const lc = self.lifecycle();
        // Status GET: `<base><create_endpoint>/<id>` (no dedicated polling_endpoint).
        const url = try std.fmt.allocPrint(arena, "{s}{s}/{s}", .{ self.base(), lc.create_endpoint, self.handle.id });
        const resp = try self.get(arena, url);
        return .{ .value = try std.json.parseFromSliceLeaky(json.Value, arena, resp.body, .{}) };
    }

    pub fn result(self: BatchAdapter, arena: std.mem.Allocator, pb: job.PollBody) !Out {
        const lc = self.lifecycle();
        // Two paths: OpenAI reads an output_file_id then GETs the file content;
        // Anthropic GETs the results endpoint directly (both from the facts).
        const url = if (lc.result_file_id_path.len > 0) blk: {
            const fid = pb.status(lc.result_file_id_path);
            break :blk try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base(), try replaceId(arena, lc.file_content_endpoint, fid) });
        } else try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base(), try replaceId(arena, lc.result_endpoint, self.handle.id) });

        const resp = try self.get(arena, url);
        return parseBatchResults(arena, self.handle.provider, resp.body);
    }

    fn get(self: BatchAdapter, arena: std.mem.Allocator, url: []const u8) !http.Response {
        const headers = try http.buildAuthHeaders(arena, self.handle.provider, self.handle.api_key);
        return self.handle.transport.send(arena, .{ .method = .GET, .url = url, .headers = headers });
    }
};

/// Replace the first `{id}` in `template` with `id`.
fn replaceId(arena: std.mem.Allocator, template: []const u8, id: []const u8) ![]const u8 {
    const idx = std.mem.indexOf(u8, template, "{id}") orelse return template;
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ template[0..idx], id, template[idx + "{id}".len ..] });
}























































