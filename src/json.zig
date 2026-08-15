//! The JSON waist (ADR-069 ZIG-002).
//!
//! Every SDK builds request bodies as a dynamic, dotted-path map and reads
//! responses the same way. Zig's `std.json.Value` IS that dynamic tagged union,
//! and its object member is a `std.array_hash_map.String` — insertion-ordered
//! by construction — so the standard library gives us deterministic wire-golden
//! key ordering for free (no hand-rolled ordered-pair type, unlike Swift's
//! JSONBuilder). This module is the thin helper surface over that value: build
//! objects/arrays, set at dotted paths, merge root keys, read by dotted path,
//! and compare two values for equality (the wire-golden acceptance check).
//!
//! Values built here are backed by a caller-supplied allocator — pass an arena
//! for a whole request build and free it in one shot.

const std = @import("std");

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
pub const Array = std.json.Array;

/// Parse JSON text into a dynamic Value. The returned `Parsed` owns the arena
/// its strings live in; the caller must `deinit()` it.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, gpa, text, .{});
}

/// Serialize a Value to compact JSON. `std.json` preserves object insertion
/// order and keeps `.integer`/`.float` distinct with no exponent form — the
/// determinism the wire goldens need (ADR-069 ZIG-002).
pub fn stringify(gpa: std.mem.Allocator, v: Value) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, v, .{});
}

/// A fresh empty object Value. `std.json.ObjectMap` is unmanaged, so mutations
/// (`set`/`setPath`/`mergeRoot`) take the allocator; construction does not.
pub fn object() Value {
    return .{ .object = .empty };
}

/// A fresh empty array Value backed by `gpa`. `std.json.Array` is a managed
/// list, so it holds `gpa` and `append` needs no allocator.
pub fn array(gpa: std.mem.Allocator) Value {
    return .{ .array = Array.init(gpa) };
}

/// Set (or replace) `key` on an object Value. `obj` must be `.object`.
pub fn set(gpa: std.mem.Allocator, obj: *Value, key: []const u8, v: Value) !void {
    try obj.object.put(gpa, key, v);
}

/// Set `value` at a dotted `path` (e.g. `thinking.budget_tokens`), auto-
/// vivifying intermediate objects — the `setNestedField` behavior every SDK
/// shares. Keys are duped into `arena` so a path built from a temporary buffer
/// stays valid for the map's lifetime.
pub fn setPath(arena: std.mem.Allocator, root: *Value, path: []const u8, value: Value) !void {
    var it = std.mem.splitScalar(u8, path, '.');
    var cur = root;
    while (it.next()) |seg| {
        const key = try arena.dupe(u8, seg);
        if (it.peek() == null) {
            try cur.object.put(arena, key, value);
        } else {
            const gop = try cur.object.getOrPut(arena, key);
            if (!gop.found_existing or std.meta.activeTag(gop.value_ptr.*) != .object) {
                gop.value_ptr.* = object();
            }
            cur = gop.value_ptr;
        }
    }
}

/// Merge every top-level key of `extra` (an object) into `root` (an object),
/// overwriting on collision — the `extra_fields_json` root-merge every SDK
/// applies. Non-object `extra` is a no-op.
pub fn mergeRoot(arena: std.mem.Allocator, root: *Value, extra: Value) !void {
    if (std.meta.activeTag(extra) != .object) return;
    var it = extra.object.iterator();
    while (it.next()) |entry| {
        try root.object.put(arena, try arena.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
    }
}

/// Read the value at a dotted `path`, with array indices — e.g.
/// `choices[0].finish_reason`. Returns null if any segment is missing or a
/// segment type does not match. This is the response-side reader.
pub fn getPath(root: Value, path: []const u8) ?Value {
    var cur = root;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |raw_seg| {
        const bracket = std.mem.indexOfScalar(u8, raw_seg, '[');
        const name = if (bracket) |b| raw_seg[0..b] else raw_seg;
        if (name.len > 0) {
            if (std.meta.activeTag(cur) != .object) return null;
            cur = cur.object.get(name) orelse return null;
        }
        if (bracket) |b| {
            var rest = raw_seg[b..];
            while (rest.len > 0 and rest[0] == '[') {
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
                const idx = std.fmt.parseInt(usize, rest[1..close], 10) catch return null;
                if (std.meta.activeTag(cur) != .array) return null;
                if (idx >= cur.array.items.len) return null;
                cur = cur.array.items[idx];
                rest = rest[close + 1 ..];
            }
        }
    }
    return cur;
}

/// Elements of the array at `blocks_path` that the marker identifies, in wire
/// order. The single primitive behind every "which blocks in this response are
/// of kind X" question — text extraction and tool-call extraction both run
/// through it, so the two cannot come to disagree about what an array element
/// is.
///
/// Marker semantics are exactly the generated config contract:
///
///   marker_path empty                    homogeneous array; every element matches
///   marker_path set, marker_value empty  matches if the key is PRESENT
///   both set                             matches if the key EQUALS the value
///
/// Presence rather than equality is not a shortcut: a Bedrock ContentBlock and
/// a Gemini Part are UNIONS whose text member carries no type key at all, so an
/// equality test there would match nothing.
///
/// Navigation reuses `getPath`, so there is no second path grammar here. The
/// returned slice borrows from `root`; the caller owns nothing.
pub fn matchingBlocks(
    arena: std.mem.Allocator,
    root: Value,
    blocks_path: []const u8,
    marker_path: []const u8,
    marker_value: []const u8,
) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    const arr = getPath(root, blocks_path) orelse return out.toOwnedSlice(arena);
    if (std.meta.activeTag(arr) != .array) return out.toOwnedSlice(arena);

    for (arr.array.items) |elem| {
        if (std.meta.activeTag(elem) != .object) continue;
        if (marker_path.len > 0) {
            const marker = elem.object.get(marker_path) orelse continue;
            if (marker_value.len > 0) {
                if (std.meta.activeTag(marker) != .string) continue;
                if (!std.mem.eql(u8, marker.string, marker_value)) continue;
            }
        }
        try out.append(arena, elem);
    }
    return out.toOwnedSlice(arena);
}

/// Place `value` at a dotted `path` WITH array indices — the navigate-or-create
/// inverse of `getPath`, walking the identical generated path strings (ADR-076
/// SYM-005). Intermediate objects and array elements are created as it
/// descends, and ANY segment may be indexed, not just the first: Google's
/// response text path is `candidates[0].content.parts[0].text`, two array levels
/// created in a single descent.
///
/// The wider sibling of `setPath`, which auto-vivifies objects only: the request
/// side never indexes, the response side must. A malformed segment (which the
/// generated tables cannot produce) stops the descent without writing, exactly
/// as `getPath` returns null for one.
///
/// An empty path (the provider declares no location for this field) or an empty
/// value is a no-op: there is nothing to write, and materializing a zero would
/// invent a field the provider never sent.
pub fn setWirePath(arena: std.mem.Allocator, root: *Value, path: []const u8, value: Value) !void {
    if (path.len == 0 or isEmptyWireValue(value)) return;
    var cur = root;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |raw_seg| {
        const bracket = std.mem.indexOfScalar(u8, raw_seg, '[');
        const name = if (bracket) |b| raw_seg[0..b] else raw_seg;
        if (name.len > 0) cur = try member(arena, cur, name);
        if (bracket) |b| {
            var rest = raw_seg[b..];
            while (rest.len > 0 and rest[0] == '[') {
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return;
                const idx = std.fmt.parseInt(usize, rest[1..close], 10) catch return;
                cur = try element(arena, cur, idx);
                rest = rest[close + 1 ..];
            }
        }
    }
    cur.* = value;
}

/// The slot at `parent[name]`, coercing `parent` to an object and creating the
/// member when absent — the create half of `getPath`'s `object.get(name)`.
fn member(arena: std.mem.Allocator, parent: *Value, name: []const u8) !*Value {
    if (std.meta.activeTag(parent.*) != .object) parent.* = object();
    const gop = try parent.object.getOrPut(arena, try arena.dupe(u8, name));
    if (!gop.found_existing) gop.value_ptr.* = .null;
    return gop.value_ptr;
}

/// The slot at `parent[idx]`, coercing `parent` to an array and padding it with
/// nulls up to `idx` — the create half of `getPath`'s bounds check.
fn element(arena: std.mem.Allocator, parent: *Value, idx: usize) !*Value {
    if (std.meta.activeTag(parent.*) != .array) parent.* = array(arena);
    while (parent.array.items.len <= idx) try parent.array.append(.null);
    return &parent.array.items[idx];
}

/// Whether `value` is the zero of its canonical type. Empty values are skipped
/// rather than written, so the encoder never claims a provider reported zero
/// tokens when the canonical `Response` simply had none.
/// Whether `value` carries nothing to write. `.null` is the caller saying the
/// field was never reported, so there is no location to fill.
///
/// A numeric zero is NOT empty (ADR-081). It used to be: the encoder dropped
/// every zero, so a body that explicitly said `cached_tokens: 0` round-tripped
/// to one that omitted the field — the reader then had to guess, and guessed
/// zero, which happened to look right. Now absence arrives as `.null` and a
/// reported zero arrives as `.{ .integer = 0 }`, so the encoder can tell them
/// apart instead of inferring one from the other.
fn isEmptyWireValue(value: Value) bool {
    return switch (value) {
        .string, .number_string => |s| s.len == 0,
        .null => true,
        else => false,
    };
}

/// An unreported canonical field becomes `.null`, which `setWirePath` skips; a
/// reported value — zero included — becomes a real JSON value and is written.
pub fn wireInt(value: ?i64) Value {
    return if (value) |v| .{ .integer = v } else .null;
}

/// `wireInt` for the fractional provider-reported USD cost.
pub fn wireFloat(value: ?f64) Value {
    return if (value) |v| .{ .float = v } else .null;
}

/// `wireInt` for the optional canonical signal strings.
pub fn wireString(value: ?[]const u8) Value {
    return if (value) |v| .{ .string = v } else .null;
}

/// Deep, numeric-aware value equality — the wire-golden acceptance check. Two
/// numbers compare by value across the `.integer`/`.float`/`.number_string`
/// representations (so a golden's `1.0` equals a built `1`); objects compare
/// key-set + values regardless of key order (JSON objects are semantically
/// unordered); arrays compare element-wise in order.
pub fn equal(a: Value, b: Value) bool {
    if (numericValue(a)) |na| {
        return if (numericValue(b)) |nb| na == nb else false;
    }
    return switch (a) {
        .null => std.meta.activeTag(b) == .null,
        .bool => |x| std.meta.activeTag(b) == .bool and b.bool == x,
        .string => |x| std.meta.activeTag(b) == .string and std.mem.eql(u8, x, b.string),
        .array => |xs| blk: {
            if (std.meta.activeTag(b) != .array) break :blk false;
            if (xs.items.len != b.array.items.len) break :blk false;
            for (xs.items, b.array.items) |ea, eb| {
                if (!equal(ea, eb)) break :blk false;
            }
            break :blk true;
        },
        .object => |xo| blk: {
            if (std.meta.activeTag(b) != .object) break :blk false;
            if (xo.count() != b.object.count()) break :blk false;
            var it = xo.iterator();
            while (it.next()) |entry| {
                const bv = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!equal(entry.value_ptr.*, bv)) break :blk false;
            }
            break :blk true;
        },
        // Number tags are handled above by numericValue; unreachable in practice.
        .integer, .float, .number_string => false,
    };
}

fn numericValue(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}































































































































