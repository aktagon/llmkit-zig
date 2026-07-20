//! Handwritten ChatCompletion response parser (ADR-065 Track B, Phase 2 slice I).
//!
//! The INBOUND mirror of `request.zig`: given a provider's chat REPLY body
//! (already parsed into the `json.Value` waist), project it to the normalized
//! `{content, finish_reason, usage, err}` every SDK agrees on. Every field is
//! pulled through a GENERATED per-provider JSON path fact — there is no
//! switch-on-provider-name here, exactly as `rust/src/response.rs` mirrors: the
//! content path (`response.zig`), the usage input/output paths (`response.zig`),
//! the cache write/read paths (`caching.zig`), and the reasoning/finish/error
//! paths (the `ProviderSpec` in `providers.zig`) are all data. An empty path
//! means "this provider does not report that dimension" and the field defaults
//! to 0 / "" / null — the honest zero, never a fabricated value.
//!
//! Cost follows ADR-027: value at the provider's `usageCostPath`, multiplied by
//! its `usageCostScale` (xAI reports ticks; scale 1e-10 → USD). Providers that
//! do not report cost carry an empty path → cost 0.0.
//!
//! Strings are duped into the caller's arena, so a `Response` outlives the
//! parsed body it was read from.

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const response_paths = @import("providers/generated/response.zig");
const caching = @import("providers/generated/caching.zig");

const ProviderName = providers.ProviderName;

/// Token accounting, one field per `TokenDimension`. The carrier field on
/// `Response` is named `usage` (load-bearing for the cross-SDK naming lint).
pub const Usage = struct {
    input: i64 = 0,
    output: i64 = 0,
    cache_read: i64 = 0,
    cache_write: i64 = 0,
    reasoning: i64 = 0,
    cost: f64 = 0,
};

/// A provider error envelope, when the reply carries one at the declared
/// `error_message_path`. Null on a successful reply.
pub const ApiError = struct {
    message: []const u8,
    type: []const u8 = "",
};

/// The normalized chat reply. `err` is non-null only when the body carries a
/// message at the provider's `error_message_path` (a successful reply leaves it
/// null). `usage` MUST keep this name — the naming lint keys on it.
pub const Response = struct {
    content: []const u8,
    finish_reason: []const u8,
    finish_message: []const u8 = "",
    err: ?ApiError = null,
    usage: Usage,
};

/// Read a string at a dotted path; empty path or a non-string value yields "".
fn stringAt(raw: json.Value, path: []const u8) []const u8 {
    if (path.len == 0) return "";
    const v = json.getPath(raw, path) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Read an integer at a dotted path; empty path or a missing/non-numeric value
/// yields 0 (the honest zero for an unreported token dimension).
fn intAt(raw: json.Value, path: []const u8) i64 {
    if (path.len == 0) return 0;
    const v = json.getPath(raw, path) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

/// Read a float at a dotted path; empty path or a missing/non-numeric value
/// yields 0.
fn floatAt(raw: json.Value, path: []const u8) f64 {
    if (path.len == 0) return 0;
    const v = json.getPath(raw, path) orelse return 0;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

fn detectError(arena: std.mem.Allocator, raw: json.Value, ps: providers.ProviderSpec) !?ApiError {
    if (ps.error_message_path.len == 0) return null;
    const message = stringAt(raw, ps.error_message_path);
    if (message.len == 0) return null;
    return ApiError{
        .message = try arena.dupe(u8, message),
        .type = try arena.dupe(u8, stringAt(raw, ps.error_type_path)),
    };
}

/// Project a parsed provider chat reply into the normalized `Response`. All
/// field placement is driven by the generated per-provider path facts; nothing
/// here dispatches on the provider name. Mirrors `rust/src/response.rs`.
pub fn parseChatResponse(arena: std.mem.Allocator, provider: ProviderName, raw: json.Value) !Response {
    const ps = providers.spec(provider);
    const usage_paths = response_paths.usagePaths(provider);
    const cache = caching.cacheUsagePaths(provider);

    return .{
        .content = try arena.dupe(u8, stringAt(raw, response_paths.responseTextPath(provider))),
        .finish_reason = try arena.dupe(u8, stringAt(raw, ps.finish_reason_path)),
        .finish_message = try arena.dupe(u8, stringAt(raw, ps.finish_message_path)),
        .err = try detectError(arena, raw, ps),
        .usage = .{
            .input = intAt(raw, usage_paths.input),
            .output = intAt(raw, usage_paths.output),
            .cache_write = intAt(raw, cache.write),
            .cache_read = intAt(raw, cache.read),
            .reasoning = intAt(raw, ps.reasoning_tokens_path),
            .cost = floatAt(raw, response_paths.usageCostPath(provider)) *
                response_paths.usageCostScale(provider),
        },
    };
}





















