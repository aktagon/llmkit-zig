//! Middleware — the observation + veto seam (HANDOFF-046 slice 1 step 3).
//!
//! A middleware is called PRE each operation (where returning a reason vetoes
//! the call before any bytes leave the process) and POST (observation only, the
//! return value ignored). This mirrors Rust `middleware.rs` `fire_pre` /
//! `fire_post` and the `MiddlewareVeto` it raises.
//!
//! The fire sites could not exist before Phase 6: an op is only observable at a
//! point where the runtime actually performs it, and until the public send
//! terminals landed, Zig performed almost none of them. That is why
//! `rule_middleware_op_unfired` exempted zig wholesale, and why the exemption is
//! removed in the same slice that adds the terminals.
//!
//! `Middleware` is the same type-erased `{ptr, fn}` pair `http.Transport` uses:
//! Zig has no closures that capture by value into a plain function pointer, so
//! a stateful middleware (a counter, a span exporter) needs its own `ptr`.

const std = @import("std");
const telemetry = @import("telemetry.zig");

pub const Event = telemetry.Event;
pub const MiddlewareOp = telemetry.MiddlewareOp;
pub const MiddlewarePhase = telemetry.MiddlewarePhase;
pub const CallError = telemetry.CallError;
pub const setEventError = telemetry.setEventError;

/// Raised by `firePre` when a middleware vetoes the operation. Zig error values
/// carry no payload, so the veto REASON is delivered to the caller through the
/// out-pointer `firePre` takes rather than riding on the error itself.
pub const VetoError = error{MiddlewareVeto};

/// One middleware hook. `call` returns null to allow, or a reason string to veto
/// (the reason is only honoured in the pre phase). The pointer is borrowed — it
/// must outlive every client that holds it.
pub const Middleware = struct {
    ptr: *anyopaque,
    call_fn: *const fn (ptr: *anyopaque, ev: *const Event) ?[]const u8,

    pub fn call(self: Middleware, ev: *const Event) ?[]const u8 {
        return self.call_fn(self.ptr, ev);
    }
};

/// Fixed capacity for `Client.addMiddleware`. Client chain methods take no
/// allocator (ADR-069 ZIG-005), so hooks live in a bounded array — the same
/// reason `http.Ctx` bounds its custom headers, and the same copy-safety
/// requirement: a slice into the originating Client would dangle across a
/// builder fork.
pub const max_middleware = 8;

/// Fire the PRE phase. The first middleware to return a reason vetoes the call:
/// `out_reason` receives it and `error.MiddlewareVeto` is returned, so no
/// request is ever sent. Later hooks are not consulted (first veto wins,
/// matching Rust).
pub fn firePre(mws: []const Middleware, base: Event, out_reason: *[]const u8) VetoError!void {
    if (mws.len == 0) return;
    var ev = base;
    ev.phase = .pre;
    for (mws) |m| {
        if (m.call(&ev)) |reason| {
            out_reason.* = reason;
            return error.MiddlewareVeto;
        }
    }
}

/// Fire the POST phase. Observation only — a returned reason is ignored,
/// because the operation has already happened and there is nothing to veto.
pub fn firePost(mws: []const Middleware, base: Event) void {
    if (mws.len == 0) return;
    var ev = base;
    ev.phase = .post;
    for (mws) |m| _ = m.call(&ev);
}

// === Tests ===

/// A recording middleware: captures every event it sees, and optionally vetoes
/// the pre phase for one named op.
const Recorder = struct {
    seen: std.ArrayList(Event) = .empty,
    gpa: std.mem.Allocator,
    veto_op: ?MiddlewareOp = null,

    fn callImpl(ptr: *anyopaque, ev: *const Event) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.seen.append(self.gpa, ev.*) catch {};
        if (self.veto_op) |op|
            if (op == ev.op and ev.phase == .pre) return "recorder veto";
        return null;
    }

    fn middleware(self: *Recorder) Middleware {
        return .{ .ptr = self, .call_fn = callImpl };
    }
};
























































