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
//!   - `parseBatchResults` (INBOUND): a completed batch's result sources (JSONL,
//!     one line per request) -> one `Response` per request at the index its
//!     `custom_id` names (BUG-072), classified by the provider's success signal
//!     and sized by the status body's request count (HANDOFF-078); a failed
//!     line keeps its slot as a failed Response, never throws (a throwing
//!     parser would destroy a completed, possibly hours-long batch — HANDOFF-036
//!     A1). The response-wire `batch-results-{anthropic,openai}` goldens assert
//!     the projection.
//!   - `BatchHandle.poll` (LIFECYCLE): the Job engine's batch adapter — poll the
//!     batch status, classify (done/error from the generated lifecycle facts),
//!     and on success fetch every result source (Anthropic results endpoint;
//!     OpenAI output file then error file, ids read from the status body). The
//!     lifecycle-wire `batch-{succeeded,failed}` goldens assert the normalized
//!     JobStatus.
//! All three read the generated `BatchDef` / `ResourceLifecycleDef`, never a
//! provider name. Mirrors `rust/src/batch.rs` / `go/batch.go`.

const std = @import("std");
const json = @import("json.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const http = @import("http.zig");
const send = @import("send.zig");
const job = @import("job.zig");
const providers = @import("providers/generated/providers.zig");
const batch_defs = @import("providers/generated/batch.zig");
const structs = @import("providers/generated/structs.zig");

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
        try json.set(arena, &item, "custom_id", .{ .string = try std.fmt.allocPrint(arena, batch_defs.batch_request_id_prefix ++ "{d}", .{i}) });
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

/// Parse a completed batch's result sources (JSONL files, in the order the
/// lifecycle declares them) into one `Response` per submitted request, at that
/// request's index (BUG-072, HANDOFF-078).
///
/// Providers return result lines in any order, so a line is placed by the
/// request id at `result_key_path`: `batch_request_id_prefix` + N goes to slot
/// N. A line succeeded when the value at `result_status_path` is one of
/// `result_success_values` (or the provider declares no status path) and its
/// body at `result_body_path` is an object that decodes. A failed line keeps
/// its slot with empty content, `finish_reason` from the first
/// `result_reason_paths` entry that resolves (`batch_slot_error` when none
/// does) and `finish_message` from the first `result_message_paths` entry.
///
/// `count` (the status body's request count) fixes the number of slots; a line
/// whose N is out of range then follows the slots. Without a count the slots
/// run to the highest N. When one slot is claimed twice, a success replaces a
/// failure, a failure never replaces a success, and a same-class duplicate
/// follows the slots. Lines whose id is not a request id this SDK assigned
/// follow the slots in source order. An empty slot reads `batch_slot_missing`.
/// A line that is not JSON is skipped. Never throws on a bad line: a completed
/// batch's partial results are still valuable.
pub fn parseBatchResults(
    arena: std.mem.Allocator,
    provider: providers.ProviderName,
    sources: []const []const u8,
    count: ?usize,
) ![]Response {
    const bd = batch_defs.batchConfig(provider) orelse return error.UnsupportedWireShape;

    var slots: std.ArrayList(?BatchSlot) = .empty;
    if (count) |n| try slots.appendNTimes(arena, null, n);
    var unkeyed: std.ArrayList(Response) = .empty;

    for (sources) |source| {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch continue;
            const slot = try parseBatchResultLine(arena, provider, bd, parsed);

            var index: ?usize = if (bd.result_key_path.len > 0) batchRequestIndex(json.getPath(parsed, bd.result_key_path)) else null;
            if (index != null and count != null and index.? >= count.?) index = null;
            const i = index orelse {
                try unkeyed.append(arena, slot.resp);
                continue;
            };
            while (slots.items.len <= i) try slots.append(arena, null);

            if (slots.items[i]) |existing| {
                if (slot.succeeded and !existing.succeeded) {
                    slots.items[i] = slot;
                } else if (existing.succeeded and !slot.succeeded) {
                    // The request succeeded; a failed duplicate adds nothing.
                } else {
                    try unkeyed.append(arena, slot.resp);
                }
            } else slots.items[i] = slot;
        }
    }

    var out = try std.ArrayList(Response).initCapacity(arena, slots.items.len + unkeyed.items.len);
    for (slots.items) |slot| {
        out.appendAssumeCapacity(if (slot) |s| s.resp else .{ .text = "", .finish_reason = batch_defs.batch_slot_missing, .finish_message = null, .usage = .{}, .raw = null, .provider_turn = null });
    }
    out.appendSliceAssumeCapacity(unkeyed.items);
    return out.toOwnedSlice(arena);
}

/// One placed result line and whether it carried a successful response.
const BatchSlot = struct { resp: Response, succeeded: bool };

/// One result line -> its slot: the decoded chat body when the line carries
/// the provider's success signal and a decodable body, otherwise a failed
/// Response carrying the provider's reason and message.
fn parseBatchResultLine(arena: std.mem.Allocator, provider: providers.ProviderName, bd: batch_defs.BatchDef, line: json.Value) !BatchSlot {
    if (try succeededLine(arena, bd, line)) {
        const body = if (bd.result_body_path.len > 0) json.getPath(line, bd.result_body_path) else line;
        if (body) |b| if (b == .object) {
            // Batch is Chat-Completions-only (ADR-055 declares no batch Responses
            // protocol), so the wire shape is explicitly empty, never derived.
            if (response.decodeResponse(arena, provider, "", b)) |d| return .{ .resp = d.response, .succeeded = true } else |_| {}
        };
    }

    const reason = try firstPath(arena, line, bd.result_reason_paths);
    const message = try firstPath(arena, line, bd.result_message_paths);
    return .{ .resp = .{
        .text = "",
        .finish_reason = reason orelse batch_defs.batch_slot_error,
        .finish_message = message,
        .usage = .{},
        .raw = null,
        .provider_turn = null,
    }, .succeeded = false };
}

/// The body of a result line that carries the provider's success signal, or
/// null for a failed line. The symmetry suite round-trips exactly these bodies,
/// so it classifies lines by the same rule as the parser.
pub fn succeededBody(arena: std.mem.Allocator, provider: providers.ProviderName, line: json.Value) !?json.Value {
    const bd = batch_defs.batchConfig(provider) orelse return error.UnsupportedWireShape;
    if (!try succeededLine(arena, bd, line)) return null;
    if (bd.result_body_path.len == 0) return line;
    return json.getPath(line, bd.result_body_path);
}

/// Whether `line` carries the provider's success signal: no status path is
/// declared, or the value there (a number rendered as decimal) is one of
/// `result_success_values`.
fn succeededLine(arena: std.mem.Allocator, bd: batch_defs.BatchDef, line: json.Value) !bool {
    if (bd.result_status_path.len == 0) return true;
    const status = try scalarAtPath(arena, line, bd.result_status_path) orelse return false;
    for (bd.result_success_values) |v| if (std.mem.eql(u8, v, status)) return true;
    return false;
}

/// The first of `paths` that resolves to a non-empty scalar, rendered as a
/// string (arena-owned), or null when none does.
fn firstPath(arena: std.mem.Allocator, root: json.Value, paths: []const []const u8) !?[]const u8 {
    for (paths) |path| if (try scalarAtPath(arena, root, path)) |v| return v;
    return null;
}

/// The non-empty scalar at `path` rendered as a string (JSON number 200 ->
/// "200"), or null when the path does not resolve to one.
fn scalarAtPath(arena: std.mem.Allocator, root: json.Value, path: []const u8) !?[]const u8 {
    const v = json.getPath(root, path) orelse return null;
    const s: []const u8 = switch (v) {
        .string => |x| x,
        .number_string => |x| x,
        .integer => |x| try std.fmt.allocPrint(arena, "{d}", .{x}),
        .float => |x| try std.fmt.allocPrint(arena, "{d}", .{x}),
        .bool => |x| if (x) "true" else "false",
        else => return null,
    };
    if (s.len == 0) return null;
    return try arena.dupe(u8, s);
}

/// The sum of the numbers at `paths` in the batch status body, or null when no
/// path resolves to a number.
fn batchRequestCount(status: json.Value, paths: []const []const u8) ?usize {
    var total: usize = 0;
    var found = false;
    for (paths) |path| {
        const v = json.getPath(status, path) orelse continue;
        const n: i64 = switch (v) {
            .integer => |x| x,
            .float => |x| @intFromFloat(x),
            else => continue,
        };
        if (n < 0) continue;
        total += @intCast(n);
        found = true;
    }
    return if (found) total else null;
}

/// The index N of a request id `batch_request_id_prefix` + N this SDK
/// assigned, or null for any other id (or no id).
fn batchRequestIndex(id: ?json.Value) ?usize {
    const prefix = batch_defs.batch_request_id_prefix;
    const v = id orelse return null;
    if (v != .string or !std.mem.startsWith(u8, v.string, prefix)) return null;
    const digits = v.string[prefix.len..];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

/// A handle to a submitted batch — the Job engine's batch adapter target. It
/// carries the client's `http.Ctx` by value, as the other SDKs' handles carry
/// their client config, and resolves the transport on each poll through
/// `send.withTransport` (BUG-080). It never stores an `http.Transport`: that is
/// a borrowed pointer, and the one `Text.batch` built died with its frame.
/// `ctx.base_url` backs the poll/result URLs (else the provider's base),
/// `ctx.io` supplies the sleep in `wait`, and `ctx.transport` is the test seam.
/// A caller resuming a batch by id (ADR-014) passes its client's `ctx`.
///
/// `value` is the cross-SDK `BatchHandle` value (id, provider, raw) — the part
/// a caller persists to resume. The generated struct cannot carry methods, so
/// this runtime handle embeds it beside the runtime-only `ctx` and `api_key`.
/// `value.raw` is always false until the `.raw()` opt-in lands (BUG-073).
pub const BatchHandle = struct {
    value: structs.BatchHandle,
    ctx: http.Ctx,
    api_key: []const u8 = "",

    /// One poll round-trip (ADR-063 Poll): status -> classify -> (fetch results
    /// on success). Returns the normalized JobStatus.
    pub fn poll(self: BatchHandle, arena: std.mem.Allocator) !job.JobStatus([]Response) {
        return job.pollOnce(BatchAdapter, .{ .handle = self }, arena);
    }

    /// Block until the batch reaches a terminal state (ADR-063 Wait — a thin
    /// loop over `poll`, not a second lifecycle implementation). Gives up at the
    /// configured deadline with the typed `error.PollTimeout` sentinel; a
    /// provider FAILURE is a `JobStatus{.failed}`, not that error.
    ///
    /// On success the result holds one `Response` per prompt, at the prompt's
    /// index. A failed request keeps its slot: empty content, `finish_reason`
    /// set to the provider's reason ("errored", "expired", "batch_expired", ...;
    /// `batch_slot_error` when the provider gives none) and `finish_message`
    /// set to the provider's error message. A request with no result line reads
    /// `batch_slot_missing`. Results whose request id is not one this SDK
    /// assigned (a batch created elsewhere, resumed by id) follow the indexed
    /// ones in source order.
    pub fn wait(self: BatchHandle, arena: std.mem.Allocator) !job.JobStatus([]Response) {
        return job.wait(BatchAdapter, .{ .handle = self }, self.ctx.io, arena);
    }
};

/// Submit a built batch CREATE payload and return the handle. The id is read
/// from the config-declared `response_id_path` — never a provider-name switch.
/// `built.beta_headers` ride along on the CREATE request (BUG-017: a
/// file-referencing item 400s without the file-upload beta).
pub fn submitWith(
    transport: http.Transport,
    arena: std.mem.Allocator,
    ctx: *const http.Ctx,
    provider: providers.ProviderName,
    api_key: []const u8,
    built: BatchBuildResult,
) !BatchHandle {
    const lc = (batch_defs.batchConfig(provider) orelse return error.UnsupportedWireShape).lifecycle orelse
        return error.UnsupportedWireShape;

    var extra: std.ArrayList(http.Header) = .empty;
    if (built.beta_headers.len > 0)
        try extra.append(arena, .{
            .name = "anthropic-beta",
            .value = try std.mem.join(arena, ",", built.beta_headers),
        });

    const raw = try send.postJson(transport, arena, .{
        .provider = provider,
        .ctx = ctx,
        .api_key = api_key,
        .endpoint = lc.create_endpoint,
        .extra_headers = extra.items,
        .op = .batch_submit,
    }, built.payload);

    const id = json.getPath(raw, lc.response_id_path) orelse return error.ApiError;
    if (id != .string) return error.ApiError;

    return .{
        .value = .{ .id = try arena.dupe(u8, id.string), .provider = provider, .raw = false },
        .ctx = ctx.*,
        .api_key = api_key,
    };
}

/// The Job-engine adapter for a batch (the four seams). `Out` is the successful
/// `Response` slice.
const BatchAdapter = struct {
    handle: BatchHandle,

    pub const Out = []Response;

    fn lifecycle(self: BatchAdapter) batch_defs.ResourceLifecycleDef {
        return batch_defs.batchConfig(self.handle.value.provider).?.lifecycle.?;
    }

    fn base(self: BatchAdapter) []const u8 {
        return self.handle.ctx.base_url orelse providers.spec(self.handle.value.provider).base_url;
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
        const url = try std.fmt.allocPrint(arena, "{s}{s}/{s}", .{ self.base(), lc.create_endpoint, self.handle.value.id });
        const resp = try self.get(arena, url);
        return .{ .value = try std.json.parseFromSliceLeaky(json.Value, arena, resp.body, .{}) };
    }

    pub fn result(self: BatchAdapter, arena: std.mem.Allocator, pb: job.PollBody) !Out {
        const lc = self.lifecycle();
        // Every result source the lifecycle declares, in order: the results
        // endpoint (Anthropic), then the output and error files whose ids the
        // status body names (OpenAI). A file whose id is absent is skipped.
        var sources: std.ArrayList([]const u8) = .empty;
        if (lc.result_endpoint.len > 0) {
            const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base(), try replaceId(arena, lc.result_endpoint, self.handle.value.id) });
            try sources.append(arena, (try self.get(arena, url)).body);
        }
        for ([_][]const u8{ lc.result_file_id_path, lc.error_file_id_path }) |id_path| {
            const fid = pb.status(id_path);
            if (fid.len == 0) continue;
            const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base(), try replaceId(arena, lc.file_content_endpoint, fid) });
            try sources.append(arena, (try self.get(arena, url)).body);
        }
        if (sources.items.len == 0) return error.NoBatchResultSource;

        const bd = batch_defs.batchConfig(self.handle.value.provider).?;
        const count = batchRequestCount(pb.value, bd.request_count_paths);
        return parseBatchResults(arena, self.handle.value.provider, sources.items, count);
    }

    fn get(self: BatchAdapter, arena: std.mem.Allocator, url: []const u8) !http.Response {
        return send.withTransport(&self.handle.ctx, getWith, self, .{ arena, url });
    }

    fn getWith(self: BatchAdapter, transport: http.Transport, arena: std.mem.Allocator, url: []const u8) !http.Response {
        const headers = try http.buildAuthHeaders(arena, self.handle.value.provider, self.handle.api_key);
        return transport.send(arena, .{ .method = .GET, .url = url, .headers = headers });
    }
};

/// Replace the first `{id}` in `template` with `id`.
fn replaceId(arena: std.mem.Allocator, template: []const u8, id: []const u8) ![]const u8 {
    const idx = std.mem.indexOf(u8, template, "{id}") orelse return template;
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ template[0..idx], id, template[idx + "{id}".len ..] });
}


























































































































































