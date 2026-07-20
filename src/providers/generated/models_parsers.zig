// Code generated — DO NOT EDIT.

const std = @import("std");
const json = @import("../../json.zig");

/// Live-catalogue response parsers (ADR-019). Each function maps one
/// provider wire shape to a typed ParsedModelsPage over the json.zig waist.
///
/// runtime — these parsers populate only wire-provided fields.

///
pub const ParsedModelRecord = struct {
    id: []const u8 = "",
    display_name: []const u8 = "",
    description: []const u8 = "",
    created: i64 = 0,
    context_window: i64 = 0,
    max_output: i64 = 0,
    raw: json.Value = .null,
};

/// One page of parsed records plus the opaque cursor for the next page
/// (empty when the response is the last / only page).
pub const ParsedModelsPage = struct {
    records: []const ParsedModelRecord = &.{},
    next_cursor: []const u8 = "",
};

/// Structured decode error. `provider` names the parser (anthropic /
/// openai-cohort / google); `reason` carries the underlying JSON message.
pub const ModelsParseError = error{InvalidEnvelope};

fn stringAt(v: json.Value, path: []const u8) []const u8 {
    const found = json.getPath(v, path) orelse return "";
    return switch (found) {
        .string => |s| s,
        else => "",
    };
}

fn intAt(v: json.Value, path: []const u8) i64 {
    const found = json.getPath(v, path) orelse return 0;
    return switch (found) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn boolAt(v: json.Value, path: []const u8) bool {
    const found = json.getPath(v, path) orelse return false;
    return switch (found) {
        .bool => |b| b,
        else => false,
    };
}

/// Decode the cursor-paginated Anthropic /v1/models response.
pub fn parseAnthropicModelsResponse(gpa: std.mem.Allocator, envelope: json.Value) !ParsedModelsPage {
    var records: std.ArrayList(ParsedModelRecord) = .empty;
    errdefer records.deinit(gpa);
    const data = json.getPath(envelope, "data") orelse return .{};
    if (std.meta.activeTag(data) != .array) return .{};
    for (data.array.items) |wire| {
        const declared = intAt(wire, "max_output_tokens");
        const max_out = if (declared > 0) declared else intAt(wire, "max_tokens");
        try records.append(gpa, .{
            .id = stringAt(wire, "id"),
            .display_name = stringAt(wire, "display_name"),
            .description = "",
            .created = 0, // best-effort RFC-3339 parse deferred to the runtime phase
            .context_window = intAt(wire, "max_input_tokens"),
            .max_output = max_out,
            .raw = wire,
        });
    }
    var next_cursor: []const u8 = "";
    if (boolAt(envelope, "has_more")) {
        next_cursor = stringAt(envelope, "last_id");
    }
    return .{ .records = try records.toOwnedSlice(gpa), .next_cursor = next_cursor };
}

/// Decode the non-paginated OpenAI-cohort /v1/models response (also xAI,
/// Cerebras, Groq, Together — every provider on the canonical OpenAI shape).
/// Accepts either the OpenAI envelope ({"data": [...]}) or a bare top-level
/// array ([...]); Together returns the latter.
pub fn parseOpenAICohortModelsResponse(gpa: std.mem.Allocator, parsed: json.Value) !ParsedModelsPage {
    var records: std.ArrayList(ParsedModelRecord) = .empty;
    errdefer records.deinit(gpa);
    const data: []const json.Value = switch (parsed) {
        .array => |arr| arr.items,
        .object => blk: {
            const d = json.getPath(parsed, "data") orelse break :blk &.{};
            break :blk if (std.meta.activeTag(d) == .array) d.array.items else &.{};
        },
        else => &.{},
    };
    for (data) |wire| {
        try records.append(gpa, .{
            .id = stringAt(wire, "id"),
            .display_name = "",
            .description = "",
            .created = intAt(wire, "created"),
            .context_window = 0,
            .max_output = 0,
            .raw = wire,
        });
    }
    return .{ .records = try records.toOwnedSlice(gpa), .next_cursor = "" };
}

/// Decode the cursor-paginated Google /v1beta/models response. Strips the
/// `models/` prefix from each id so callers round-trip raw model IDs.
pub fn parseGoogleModelsResponse(gpa: std.mem.Allocator, envelope: json.Value) !ParsedModelsPage {
    var records: std.ArrayList(ParsedModelRecord) = .empty;
    errdefer records.deinit(gpa);
    const data = json.getPath(envelope, "models") orelse return .{};
    if (std.meta.activeTag(data) == .array) {
        const prefix = "models/";
        for (data.array.items) |wire| {
            var id = stringAt(wire, "name");
            if (std.mem.startsWith(u8, id, prefix)) id = id[prefix.len..];
            try records.append(gpa, .{
                .id = id,
                .display_name = stringAt(wire, "displayName"),
                .description = stringAt(wire, "description"),
                .created = 0,
                .context_window = intAt(wire, "inputTokenLimit"),
                .max_output = intAt(wire, "outputTokenLimit"),
                .raw = wire,
            });
        }
    }
    const next_cursor = stringAt(envelope, "nextPageToken");
    return .{ .records = try records.toOwnedSlice(gpa), .next_cursor = next_cursor };
}
