//! Structured-output (JSON-schema) request-body construction (Phase 2 Slice G,
//! BUG-007). Factored out of `request.zig` to keep that file under 500 lines.
//!
//! A schema is supplied as a JSON STRING. This module parses it into the
//! dynamic JSON waist, applies the per-provider normalization transform, and
//! places it into an already-built request body — all driven by the generated
//! `StructuredOutputDef` (`providers/generated/request_defs.zig`), never a
//! provider-name switch. Two transforms exist:
//!
//!   * EnforceStrict (OpenAI/Anthropic wire shapes): recursively add
//!     `additionalProperties:false` to every `type:"object"` node and, when the
//!     node has no `required`, auto-populate it with ALL property keys in
//!     insertion order; recurse into every property value and into array
//!     `items`.
//!   * RemoveAdditionalProps (Google): recursively REMOVE `additionalProperties`
//!     and do NOT add `required`; recurse the same way.
//!
//! Placement is selected by the def's `schema_placement`:
//!
//!   * SiblingOfFormat (Google): the format field carries the literal format
//!     type (`generationConfig.responseMimeType: "application/json"`) and the
//!     schema is an independent sibling at `schema_path`
//!     (`generationConfig.responseSchema`), reusing the existing wrapper object.
//!   * WrappedInFormat (OpenAI/Anthropic): a `{type, ...}` format object at
//!     `format_field`. A dotted `schema_path` (`json_schema.schema`) nests the
//!     schema in a named, strict inner object; a flat `schema_path` (`schema`)
//!     drops it directly beside `type`.
//!
//! The beta header a schema may require (Anthropic
//! `structured-outputs-2025-11-13`) is NOT applied here — headers are the
//! separate pure seam in `request.zig` (`buildRequestHeaders`). This module
//! shapes the body only.
//!
//! Mirrors Go `addStructuredOutput` (`go/llmkit.go`) and Rust
//! `add_structured_output` (`rust/src/request.rs`) exactly.

const std = @import("std");
const json = @import("json.zig");
const providers = @import("providers/generated/providers.zig");
const request_defs = @import("providers/generated/request_defs.zig");

/// Parse `schema_str`, apply the provider's structured-output transform, and
/// place the result into `body`. A no-op when the provider declares no
/// structured-output def or the schema is not valid JSON (mirrors Go/Rust,
/// which silently return in both cases).
pub fn apply(
    arena: std.mem.Allocator,
    body: *json.Value,
    provider: providers.ProviderName,
    schema_str: []const u8,
) std.mem.Allocator.Error!void {
    const def = request_defs.structuredOutput(provider) orelse return;

    var schema = std.json.parseFromSliceLeaky(json.Value, arena, schema_str, .{}) catch return;

    if (def.enforce_strict) try enforceStrict(arena, &schema);
    if (def.remove_additional_props) removeAdditionalProps(&schema);

    // SiblingOfFormat (Google): the format field holds the literal format type
    // and the schema is an independent sibling — both dotted paths land in the
    // existing options wrapper (`generationConfig`) via setPath.
    if (std.mem.eql(u8, def.schema_placement, "SiblingOfFormat")) {
        try json.setPath(arena, body, def.format_field, .{ .string = def.format_type });
        try json.setPath(arena, body, def.schema_path, schema);
        return;
    }

    // WrappedInFormat (OpenAI/Anthropic): build the `{type, ...}` format object,
    // then place it at `format_field`.
    var format_obj = json.object();
    try json.set(arena, &format_obj, "type", .{ .string = def.format_type });

    if (std.mem.indexOfScalar(u8, def.schema_path, '.')) |dot| {
        // Nested (`json_schema.schema`): the schema wraps in a named, strict
        // inner object under the first path segment.
        const outer = def.schema_path[0..dot];
        const inner_key = def.schema_path[dot + 1 ..];
        var inner = json.object();
        try json.set(arena, &inner, "name", .{ .string = "response" });
        try json.set(arena, &inner, inner_key, schema);
        try json.set(arena, &inner, "strict", .{ .bool = def.enforce_strict });
        try json.set(arena, &format_obj, outer, inner);
    } else {
        // Flat (`schema`): the schema sits directly beside `type`.
        try json.set(arena, &format_obj, def.schema_path, schema);
    }

    try json.setPath(arena, body, def.format_field, format_obj);
}

/// EnforceStrict: recursively add `additionalProperties:false` to every
/// `type:"object"` node, auto-populate an absent `required` with all property
/// keys (insertion order), and recurse into property values and array `items`.
/// Mirrors Go `setAdditionalPropertiesFalse` / Rust
/// `set_additional_properties_false`.
///
/// Pointer discipline: all mutations to THIS node's object (adding
/// `additionalProperties` / `required`) happen before any child pointer is
/// taken for recursion, because a `put` that grows the object's backing arrays
/// invalidates a previously-held `getPtr` result.
fn enforceStrict(arena: std.mem.Allocator, node: *json.Value) std.mem.Allocator.Error!void {
    if (std.meta.activeTag(node.*) != .object) return;

    var is_object_type = false;
    if (node.object.get("type")) |t| {
        if (std.meta.activeTag(t) == .string and std.mem.eql(u8, t.string, "object"))
            is_object_type = true;
    }

    if (is_object_type) {
        try node.object.put(arena, "additionalProperties", .{ .bool = false });

        if (node.object.get("required") == null) {
            if (node.object.getPtr("properties")) |props| {
                if (std.meta.activeTag(props.*) == .object) {
                    var req = json.array(arena);
                    var kit = props.object.iterator();
                    while (kit.next()) |entry| try req.array.append(.{ .string = entry.key_ptr.* });
                    try node.object.put(arena, "required", req);
                }
            }
        }
    }

    // Recurse — child pointers are fetched AFTER every this-level `put`, so they
    // are valid. Mutating a child's own object never resizes this node's arrays.
    if (node.object.getPtr("properties")) |props| {
        if (std.meta.activeTag(props.*) == .object) {
            var vit = props.object.iterator();
            while (vit.next()) |entry| try enforceStrict(arena, entry.value_ptr);
        }
    }
    if (node.object.getPtr("items")) |items| {
        try enforceStrict(arena, items);
    }
}

/// RemoveAdditionalProps (Google): recursively remove `additionalProperties`
/// from every object node, recursing into property values and array `items`.
/// Does NOT add `required`. Mirrors Go `removeAdditionalProperties` / Rust
/// `remove_additional_properties`.
fn removeAdditionalProps(node: *json.Value) void {
    if (std.meta.activeTag(node.*) != .object) return;
    _ = node.object.orderedRemove("additionalProperties");
    if (node.object.getPtr("properties")) |props| {
        if (std.meta.activeTag(props.*) == .object) {
            var vit = props.object.iterator();
            while (vit.next()) |entry| removeAdditionalProps(entry.value_ptr);
        }
    }
    if (node.object.getPtr("items")) |items| {
        removeAdditionalProps(items);
    }
}

const test_schema =
    \\{"type":"object","properties":{"city":{"type":"string"},"forecast":{"type":"array","items":{"type":"object","properties":{"day":{"type":"string"}}}}}}
;



















































