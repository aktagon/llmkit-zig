//! Request-variant selection (ADR-096) — a mirror of go/request_variant.go.
//!
//! An image or video config carries one wire request per carried-input set.
//! The request picks the variant whose carried inputs equal its own, in any
//! order: TextOnly, the capability's image input (WithReferenceImages for
//! image, WithSeedFrame for video), or a first-and-last-frame pair.

const std = @import("std");
const image_gen = @import("providers/generated/image_gen.zig");

pub const RequestVariant = image_gen.RequestVariant;

/// The config has no variant for the inputs the request carries. Zig errors
/// carry no payload; the other SDKs return `ValidationError{Field: "parts",
/// Message: "<provider> has no <Carries joined by +> request"}`.
pub const Error = error{NoRequestVariant};

/// The config's variant whose carried inputs equal `carries`, in any order.
pub fn select(variants: []const RequestVariant, carries: []const []const u8) Error!RequestVariant {
    for (variants) |v| {
        if (sameCarriedInputs(v.carries, carries)) return v;
    }
    return error.NoRequestVariant;
}

/// The carried input of a request with `image_count` image parts:
/// `image_input` when it holds at least one, else TextOnly.
pub fn partsCarry(image_count: usize, image_input: []const u8) []const u8 {
    return if (image_count > 0) image_input else image_gen.text_only;
}

fn sameCarriedInputs(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| {
        var found = false;
        for (b) |y| {
            if (std.mem.eql(u8, x, y)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}
























