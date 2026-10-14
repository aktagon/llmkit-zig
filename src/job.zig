//! The shared async-job poll engine (ADR-062 / ADR-063), Phase 3 slice 4.
//!
//! A monotonic `Running -> (Succeeded | Failed)` state machine behind adapter
//! seams, mirroring `rust/src/job.rs` / `go/job.go`. An adapter supplies four
//! things — its output type (`Out`), a `LifecycleConfig` (`config`), a single
//! poll round-trip (`poll` -> a decoded `PollBody`), and a result fetch
//! (`result`, which may do a second network hop) — and the engine turns a poll
//! into a normalized `JobStatus`:
//!   - `poll` (the ADR-063 primitive) = one round-trip: poll -> classify ->
//!     (fetch result iff Succeeded).
//!   - `wait` = the convenience loop over `poll` until terminal, with a typed
//!     deadline sentinel (`error.PollTimeout`) — a provider Failed is NOT that
//!     sentinel.
//! Classification precedence is done > error > running; an unmodeled status
//! degrades to Running (never a false terminal). The engine is provider-agnostic:
//! the batch adapter (batch.zig) is its first user; video / transcription join in
//! later phases.
//!
//! Zig has no trait objects, so the adapter is a COMPTIME duck-typed value
//! (`comptime Adapter: type` + an `adapter: Adapter`) — the idiomatic zero-cost
//! interface, checked at compile time, no vtable.

const std = @import("std");
const json = @import("json.zig");

/// The three terminal-or-not states. `@tagName` is the lowercase wire string
/// (`running`/`succeeded`/`failed`) the lifecycle-wire golden asserts.
pub const JobState = enum { running, succeeded, failed };

/// One terminal failure — a single cause, not a taxonomy. `timed_out` is set
/// only by the `wait` deadline backstop (the typed sentinel path), never by a
/// provider-reported failure.
pub const JobFailure = struct {
    status: []const u8,
    message: []const u8 = "",
    timed_out: bool = false,
};

/// The normalized poll outcome for a job whose success payload is `T`. `result`
/// is non-null only when Succeeded; `cause` non-null only when Failed.
pub fn JobStatus(comptime T: type) type {
    return struct {
        state: JobState,
        result: ?T = null,
        cause: ?JobFailure = null,
        raw_status: []const u8,
    };
}

/// The config seam: the status path + the done/error status-value sets that
/// classify a poll, plus the poll cadence. All from the provider's generated
/// lifecycle facts (never a provider-name switch).
pub const LifecycleConfig = struct {
    status_path: []const u8,
    done_values: []const []const u8,
    error_values: []const []const u8,
    poll_interval_ms: u64 = 2000,
    poll_timeout_ms: u64 = 600000,
    noun: []const u8 = "job",
};

pub const Classification = enum { running, succeeded, failed };

/// The typed deadline sentinel (POLL-008): distinguishable from a provider
/// failure so a caller can separate "the job failed" from "we stopped waiting".
pub const PollError = error{PollTimeout};

/// The once-decoded poll response — keeps the bare JSON `Value` off adapter
/// signatures (a poll body is read for a status string and, on success, a
/// result id).
pub const PollBody = struct {
    value: json.Value,

    /// The status string at `path` (empty path or non-string -> "").
    pub fn status(self: PollBody, path: []const u8) []const u8 {
        if (path.len == 0) return "";
        const v = json.getPath(self.value, path) orelse return "";
        return switch (v) {
            .string => |s| s,
            else => "",
        };
    }
};

/// The default classifier: done > error > running. An empty or unmodeled status
/// is Running — never a false terminal (a job we do not yet understand is still
/// in flight, mirroring Rust `classify_by_config`).
pub fn classifyByConfig(cfg: LifecycleConfig, status: []const u8) Classification {
    if (status.len == 0) return .running;
    for (cfg.done_values) |d| if (d.len > 0 and std.mem.eql(u8, d, status)) return .succeeded;
    for (cfg.error_values) |e| if (e.len > 0 and std.mem.eql(u8, e, status)) return .failed;
    return .running;
}

/// The ADR-063 `Poll` primitive: one round-trip. Poll the job, classify the
/// status, and — only when Succeeded — fetch the result (a possible second hop).
/// Returns the normalized `JobStatus`. `Adapter` must expose `pub const Out`,
/// `config(arena) LifecycleConfig` (arena-backed so its status-value slices
/// outlive the call), `poll(arena) !PollBody`, and `result(arena, PollBody) !Out`.
pub fn pollOnce(comptime Adapter: type, adapter: Adapter, arena: std.mem.Allocator) !JobStatus(Adapter.Out) {
    const cfg = try adapter.config(arena);
    const pb = try adapter.poll(arena);
    const raw = try arena.dupe(u8, pb.status(cfg.status_path));

    return switch (classifyByConfig(cfg, raw)) {
        .succeeded => .{ .state = .succeeded, .result = try adapter.result(arena, pb), .raw_status = raw },
        .failed => .{ .state = .failed, .cause = .{ .status = raw }, .raw_status = raw },
        .running => .{ .state = .running, .raw_status = raw },
    };
}

/// The `Wait` convenience: loop `pollOnce` until terminal, sleeping the config's
/// interval between polls, and giving up at the deadline with `error.PollTimeout`
/// (the typed sentinel — a provider Failed returns a `JobStatus{.failed}`, NOT
/// this error). `io` supplies the sleep. Mirrors Rust `poll_job` / Go `pollJob`.
pub fn wait(comptime Adapter: type, adapter: Adapter, io: std.Io, arena: std.mem.Allocator) !JobStatus(Adapter.Out) {
    const cfg = try adapter.config(arena);
    var elapsed_ms: u64 = 0;
    while (true) {
        const st = try pollOnce(Adapter, adapter, arena);
        if (st.state != .running) return st;
        if (elapsed_ms >= cfg.poll_timeout_ms) return error.PollTimeout;
        try io.sleep(.fromMilliseconds(@intCast(cfg.poll_interval_ms)), .awake);
        elapsed_ms += cfg.poll_interval_ms;
    }
}












