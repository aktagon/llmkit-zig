//! AWS SigV4 request signing (Bedrock), Phase 3 slice 6.
//!
//! Hand-rolled canonical-request + signing over `std.crypto` (HMAC-SHA256 +
//! SHA-256), mirroring `rust/src/sigv4.rs` / `go/sigv4.go`. `signAt` takes the
//! signing clock as an explicit `amz_date` — the injected-clock seam the
//! sigv4-wire golden asserts against (the timestamp is the only non-deterministic
//! input; production passes the real clock, the wire driver a frozen one).
//!
//! One deliberate deviation from the SigV4 spec, shared across all SDKs
//!
//! PATH signed AS-IS (no double-encoding of `:`/`%2F`), which AWS's verifier
//! accepts and is live-verified against Bedrock Converse. So the path is taken
//! verbatim from the URL — never re-encoded.
//!
//! `signAt` returns the three signing artifacts (`canonical_request`,
//! `string_to_sign`, `authorization`); production discards the first two, the
//! wire driver asserts all three.

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Signature = struct {
    canonical_request: []const u8,
    string_to_sign: []const u8,
    authorization: []const u8,
    /// Lowercase hex SHA-256 of the body. It is a SIGNED header
    /// (`x-amz-content-sha256`), so the send path must put this exact value on
    /// the wire.
    payload_hash: []const u8,
};

pub const SignInput = struct {
    method: []const u8,
    url: []const u8,
    body: []const u8 = "",
    content_type: []const u8 = "",
    access_key: []const u8,
    secret_key: []const u8,
    session_token: []const u8 = "",
    region: []const u8,
    service: []const u8,
    /// The signing timestamp as `YYYYMMDDTHHMMSSZ` (the injected clock). The date
    /// stamp (`YYYYMMDD`) is its first 8 bytes.
    amz_date: []const u8,
};

const Header = struct { name: []const u8, value: []const u8 };

/// Sign `in` and return the canonical request, string-to-sign, and Authorization
/// header. All strings are arena-backed.
pub fn signAt(arena: std.mem.Allocator, in: SignInput) !Signature {
    const date_stamp = in.amz_date[0..8];
    const host = urlHost(in.url);
    const path = urlPath(in.url);
    const query = urlQuery(in.url);

    const payload_hash = try sha256Hex(arena, in.body);

    // The signed header set (sorted lowercase): content-type (when present),
    // host, x-amz-content-sha256, x-amz-date, x-amz-security-token (when a
    // session token is present). Built in already-sorted order.
    var headers: std.ArrayList(Header) = .empty;
    if (in.content_type.len > 0)
        try headers.append(arena, .{ .name = "content-type", .value = in.content_type });
    try headers.append(arena, .{ .name = "host", .value = host });
    try headers.append(arena, .{ .name = "x-amz-content-sha256", .value = payload_hash });
    try headers.append(arena, .{ .name = "x-amz-date", .value = in.amz_date });
    if (in.session_token.len > 0)
        try headers.append(arena, .{ .name = "x-amz-security-token", .value = in.session_token });
    std.mem.sort(Header, headers.items, {}, headerLessThan);

    var canonical_headers: std.ArrayList(u8) = .empty;
    var signed_headers: std.ArrayList(u8) = .empty;
    for (headers.items, 0..) |h, i| {
        try canonical_headers.print(arena, "{s}:{s}\n", .{ h.name, h.value });
        if (i != 0) try signed_headers.append(arena, ';');
        try signed_headers.appendSlice(arena, h.name);
    }
    const signed = try signed_headers.toOwnedSlice(arena);

    const canonical_request = try std.fmt.allocPrint(arena, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        in.method,
        path,
        query,
        canonical_headers.items,
        signed,
        payload_hash,
    });

    const scope = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/aws4_request", .{ date_stamp, in.region, in.service });
    const cr_hash = try sha256Hex(arena, canonical_request);
    const string_to_sign = try std.fmt.allocPrint(arena, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ in.amz_date, scope, cr_hash });

    const signing_key = deriveSigningKey(in.secret_key, date_stamp, in.region, in.service);
    var sig_raw: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&sig_raw, string_to_sign, &signing_key);
    const signature = try hexLower(arena, &sig_raw);

    const authorization = try std.fmt.allocPrint(
        arena,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ in.access_key, scope, signed, signature },
    );

    return .{
        .canonical_request = canonical_request,
        .string_to_sign = string_to_sign,
        .authorization = authorization,
        .payload_hash = payload_hash,
    };
}

/// Format Unix seconds as the SigV4 `YYYYMMDDTHHMMSSZ` timestamp (UTC) into
/// `buf`. Times before the epoch clamp to it; no real clock reports one.
pub fn amzDate(buf: *[16]u8, unix_s: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(unix_s, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u8, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}








fn headerLessThan(_: void, a: Header, b: Header) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The SigV4 signing-key HMAC chain: AWS4{secret} -> date -> region -> service
/// -> aws4_request.
fn deriveSigningKey(secret: []const u8, date_stamp: []const u8, region: []const u8, service: []const u8) [HmacSha256.mac_length]u8 {
    var prefixed: [4 + 128]u8 = undefined;
    const initial = std.fmt.bufPrint(&prefixed, "AWS4{s}", .{secret}) catch unreachable;

    var k_date: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&k_date, date_stamp, initial);
    var k_region: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&k_region, region, &k_date);
    var k_service: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&k_service, service, &k_region);
    var k_signing: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&k_signing, "aws4_request", &k_service);
    return k_signing;
}

/// Lowercase hex of the SHA-256 of `data`.
fn sha256Hex(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return hexLower(arena, &digest);
}

/// Lowercase hex encoding of `bytes` into the arena.
fn hexLower(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

/// The host of `https://host/path?query` — the segment between `://` and the
/// next `/` (or `?`, or end).
fn urlHost(url: []const u8) []const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const end = std.mem.indexOfAny(u8, after_scheme, "/?") orelse after_scheme.len;
    return after_scheme[0..end];
}

/// The path of the URL, taken VERBATIM (escaped wire path signed as-is — the
/// documented SigV4 deviation). Empty path defaults to "/".
fn urlPath(url: []const u8) []const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return "/";
    const rest = after_scheme[slash..];
    const end = std.mem.indexOfScalar(u8, rest, '?') orelse rest.len;
    return rest[0..end];
}

/// The query string of the URL (without `?`), or "" when absent.
fn urlQuery(url: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return "";
    return url[q + 1 ..];
}























