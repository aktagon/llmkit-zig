//! Request-variant selection (ADR-096) — a mirror of go/request_variant.go.
//!
//! An image or video config carries one wire request per carried input. The
//! request's parts pick it: the capability's image carried input when it
//! holds at least one image part (WithReferenceImages for image,
//! WithSeedFrame for video), else TextOnly.

const std = @import("std");
const image_gen = @import("providers/generated/image_gen.zig");

pub const RequestVariant = image_gen.RequestVariant;

/// The config has no variant for the inputs the request carries. Zig errors
/// carry no payload; the other SDKs return `ValidationError{Field: "parts",
/// Message: "<provider> has no <Carries> request"}`.
pub const Error = error{NoRequestVariant};

/// The config's variant for a request holding `image_count` image parts;
/// `image_carries` names what those parts are for this capability.
pub fn select(variants: []const RequestVariant, image_count: usize, image_carries: []const u8) Error!RequestVariant {
    const carries = if (image_count > 0) image_carries else image_gen.text_only;
    for (variants) |v| {
        if (std.mem.eql(u8, v.carries, carries)) return v;
    }
    return error.NoRequestVariant;
}















