//! Production HTTP transport over `std.http.Client`, with the client's idle
//! timeout (BUG-062).
//!
//! The timeout bounds how long a send waits for the NEXT bytes from the
//! provider: the response head, then every gap between body reads. A watchdog
//! on the calling task waits on the exchange; each read that makes progress
//! moves the deadline forward, so a long healthy stream never times out. When
//! the deadline passes with no progress, the watchdog cancels the exchange task
//! (0.16 `Io` cancelation interrupts the blocked socket read) and the send
//! fails with `error.Timeout`.
//!
//! Why not `SO_RCVTIMEO`: 0.16's `Io.Threaded` maps the resulting `EAGAIN`
//! to `errnoBug`, which panics in Debug builds. Why not `Client.fetch`: on a
//! canceled body read it unwraps a null `bodyErr()` and panics, so `exchange`
//! below is `fetch` with that one unwrap made safe and a progress mark per read.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const client_defaults = @import("providers/generated/client_defaults.zig");

/// Production transport. Holds the `Io` and a general-purpose allocator for the
/// client's own buffers; the response body is allocated in the per-request
/// `arena` so it outlives the send. One-shot per call (no connection reuse).
pub const HttpTransport = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Idle timeout in milliseconds; 0 disables it.
    timeout_ms: u64 = client_defaults.default_timeout_ms,

    pub fn init(gpa: std.mem.Allocator, io: Io) HttpTransport {
        return .{ .gpa = gpa, .io = io };
    }

    /// The transport a terminal builds from its client context: the client's
    /// `gpa`/`io` plus its `timeout` value. Every public terminal calls this.
    pub fn fromCtx(ctx: *const http.Ctx) HttpTransport {
        return .{ .gpa = ctx.gpa, .io = ctx.io, .timeout_ms = ctx.timeout_ms };
    }

    pub fn transport(self: *HttpTransport) http.Transport {
        return .{ .ptr = self, .send_fn = sendImpl };
    }

    fn sendImpl(ptr: *anyopaque, arena: std.mem.Allocator, req: http.Request) anyerror!http.Response {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        if (self.timeout_ms == 0) return self.exchange(arena, req, null);

        var watch: Watch = .{ .start = Io.Clock.Timestamp.now(self.io, .awake) };
        var task = self.io.concurrent(exchangeAndSignal, .{ self, arena, req, &watch }) catch |err| switch (err) {
            // An `Io` with no spare concurrency cannot run the watchdog beside
            // the read, so the send goes out without a timeout.
            error.ConcurrencyUnavailable => return self.exchange(arena, req, null),
        };

        const window: Io.Clock.Duration = .{
            .raw = .fromMilliseconds(@intCast(@min(self.timeout_ms, std.math.maxInt(i64)))),
            .clock = .awake,
        };
        while (true) {
            const last = watch.last_ns.load(.acquire);
            const deadline = watch.start
                .addDuration(.{ .raw = .fromNanoseconds(last), .clock = .awake })
                .addDuration(window);
            watch.done.waitTimeout(self.io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => {
                    if (watch.last_ns.load(.acquire) != last) continue; // progress: new deadline
                    if (Io.Clock.Timestamp.now(self.io, .awake).durationTo(deadline).raw.nanoseconds > 0) continue; // early wake
                    // Idle past the window. A reply that completed in the race still wins.
                    return task.cancel(self.io) catch error.Timeout;
                },
                error.Canceled => {
                    if (task.cancel(self.io)) |_| {} else |_| {}
                    return error.Canceled;
                },
            };
            return task.await(self.io);
        }
    }

    fn exchangeAndSignal(self: *HttpTransport, arena: std.mem.Allocator, req: http.Request, watch: *Watch) anyerror!http.Response {
        defer watch.done.set(self.io);
        return self.exchange(arena, req, watch);
    }

    /// One HTTP round-trip: `std.http.Client.fetch`'s steps, marking `watch`
    /// after the request is sent, after the head arrives, and after each body
    /// read.
    fn exchange(self: *HttpTransport, arena: std.mem.Allocator, req: http.Request, watch: ?*Watch) anyerror!http.Response {
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();

        // Translate our headers to std.http.Header (same {name,value} shape).
        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(self.gpa);
        for (req.headers) |h|
            try extra.append(self.gpa, .{ .name = h.name, .value = h.value });

        const has_body = req.body.len > 0;
        var r = try client.request(switch (req.method) {
            .GET => .GET,
            .POST => .POST,
        }, try std.Uri.parse(req.url), .{
            // Same rule as `fetch`: follow redirects only for a repeatable request.
            .redirect_behavior = if (has_body) .unhandled else @enumFromInt(3),
            .extra_headers = extra.items,
        });
        defer r.deinit();

        if (has_body) {
            r.transfer_encoding = .{ .content_length = req.body.len };
            var body = try r.sendBodyUnflushed(&.{});
            try body.writer.writeAll(req.body);
            try body.end();
            try r.connection.?.flush();
        } else {
            try r.sendBodiless();
        }
        if (watch) |w| w.mark(self.io);

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try r.receiveHead(if (has_body) &.{} else &redirect_buffer);
        if (watch) |w| w.mark(self.io);

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        var body_writer: Io.Writer.Allocating = .init(arena);
        while (true) {
            _ = reader.stream(&body_writer.writer, .unlimited) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
                error.WriteFailed => return error.WriteFailed,
            };
            if (watch) |w| w.mark(self.io);
        }

        return .{
            .status = @intFromEnum(response.head.status),
            .body = body_writer.written(),
        };
    }
};

/// Shared between the exchange task and the watchdog: when the exchange last
/// made progress (nanoseconds since `start`), and whether it has finished.
const Watch = struct {
    start: Io.Clock.Timestamp,
    last_ns: std.atomic.Value(i64) = .init(0),
    done: Io.Event = .unset,

    fn mark(w: *Watch, io: Io) void {
        w.last_ns.store(@intCast(w.start.untilNow(io).raw.nanoseconds), .release);
    }
};
