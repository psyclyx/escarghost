//! Dedicated PTY reader thread.
//!
//! Blocks on the pty master, feeds every chunk into the terminal (under
//! the terminal lock), and notifies the main loop through the shared
//! `term_events.Queue` doorbell. This fully decouples ingestion from the
//! Wayland/render loop: main never reads the PTY and never runs
//! `feedData`; it just wakes when data landed, marks a redraw, and
//! samples the terminal under the lock when it captures a snapshot
//! (sample-and-present, see render docs).
//!
//! There is deliberately no read budget here — this thread has nothing
//! else to do, and the kernel pty buffer provides backpressure to the
//! child. "Data was fed" is coalesced into `data_dirty` (one redraw per
//! main wake, however many chunks landed); discrete events (EOF, OSC)
//! go through the typed queue.

const std = @import("std");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");
const term_events = @import("term_events.zig");
const diagnostics = @import("diagnostics.zig");
const atlas_ref_mod = @import("render/atlas_ref.zig");
const log = @import("log.zig");

const c = @cImport({
    // Disable glibc fortify: its inline _chk wrappers (bits/poll2.h)
    // don't survive Zig 0.16 translate-c under ReleaseSafe. Must precede
    // any header that pulls in <features.h>.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("poll.h");
    @cInclude("sys/eventfd.h");
    @cInclude("unistd.h");
});

/// Minimum gap between "drained" debug log lines, so a flood produces a
/// periodic summary instead of one line per read.
const LOG_INTERVAL_NS: u64 = 100 * std.time.ns_per_ms;

pub const Reader = struct {
    thread: ?std.Thread = null,
    pty: *pty_mod.Pty = undefined,
    term: *terminal_mod.Terminal = undefined,
    events: *term_events.Queue = undefined,
    /// Warm covering fonts from raw output as it lands (see
    /// `AtlasRef.requestWarmFallback`). Fired on the same data-arrival edge
    /// that wakes main, so it's naturally coalesced during a flood.
    atlas_ref: *atlas_ref_mod.AtlasRef = undefined,
    stop_fd: c_int = -1,
    stop_requested: std.atomic.Value(bool) = .init(false),

    /// Coalesced "bytes were fed since main last looked" flag. Set after
    /// every fed chunk; main consumes it via `takeDataDirty` and marks
    /// one redraw per wake.
    data_dirty: std.atomic.Value(bool) = .init(false),
    /// Set (after the final feed) when the master returned EOF/EIO — the
    /// child side closed and all residual output is in the terminal.
    saw_eof: std.atomic.Value(bool) = .init(false),

    // Diagnostics, written by the reader thread and read by main at
    // exit (and `first_data_ns` when stamping the trace timeline).
    bytes_read: std.atomic.Value(u64) = .init(0),
    read_calls: std.atomic.Value(u64) = .init(0),
    read_ns: std.atomic.Value(u64) = .init(0),
    feed_ns: std.atomic.Value(u64) = .init(0),
    /// Absolute monotonic ns of the first byte fed; 0 = none yet.
    first_data_ns: std.atomic.Value(u64) = .init(0),

    pub fn start(
        self: *Reader,
        pty: *pty_mod.Pty,
        term: *terminal_mod.Terminal,
        events: *term_events.Queue,
        atlas_ref: *atlas_ref_mod.AtlasRef,
    ) !void {
        if (self.thread != null) return;
        self.pty = pty;
        self.term = term;
        self.events = events;
        self.atlas_ref = atlas_ref;
        self.stop_fd = c.eventfd(0, c.EFD_CLOEXEC);
        if (self.stop_fd < 0) return error.EventfdFailed;
        errdefer {
            _ = c.close(self.stop_fd);
            self.stop_fd = -1;
        }
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        log.info(.pty, "reader thread started", .{});
    }

    /// Signal the reader to exit and join it. Must run before the
    /// terminal or pty are torn down.
    pub fn stop(self: *Reader) void {
        const thread = self.thread orelse return;
        self.stop_requested.store(true, .release);
        if (self.stop_fd >= 0) {
            const one: u64 = 1;
            _ = c.write(self.stop_fd, &one, @sizeOf(u64));
        }
        thread.join();
        self.thread = null;
        if (self.stop_fd >= 0) {
            _ = c.close(self.stop_fd);
            self.stop_fd = -1;
        }
    }

    /// Main-thread side of the coalesced data notification.
    pub fn takeDataDirty(self: *Reader) bool {
        return self.data_dirty.swap(false, .acq_rel);
    }

    /// Peek (without consuming) — used by the drain-phase exit condition
    /// so main doesn't quit with fed-but-unrendered bytes pending.
    pub fn dataDirty(self: *const Reader) bool {
        return self.data_dirty.load(.acquire);
    }

    pub fn sawEof(self: *const Reader) bool {
        return self.saw_eof.load(.acquire);
    }

    fn loop(self: *Reader) void {
        var buf: [65536]u8 = undefined;
        var log_last_ns: u64 = 0;
        var log_bytes: usize = 0;
        var log_reads: usize = 0;

        outer: while (true) {
            var fds = [_]c.struct_pollfd{
                .{ .fd = self.pty.master_fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.stop_fd, .events = c.POLLIN, .revents = 0 },
            };
            const rc = c.poll(&fds, fds.len, -1);
            if (self.stop_requested.load(.acquire)) return;
            if (rc < 0) continue;
            if (fds[1].revents != 0) return;
            if (fds[0].revents == 0) continue;

            // Drain everything currently available. The fd stays
            // O_NONBLOCK (set at spawn), so WouldBlock ends the burst
            // and we fall back into poll.
            while (true) {
                if (self.stop_requested.load(.acquire)) return;
                const read_t0 = diagnostics.monotonicNowNs();
                const n = self.pty.read(&buf) catch |e| switch (e) {
                    error.WouldBlock => break,
                    else => {
                        // EIO is the normal Linux signal that the child
                        // side closed; treat any read failure as EOF.
                        self.finishEof();
                        break :outer;
                    },
                };
                if (n == 0) {
                    self.finishEof();
                    break :outer;
                }
                const feed_t0 = diagnostics.monotonicNowNs();
                self.term.feedData(buf[0..n]);
                const now = diagnostics.monotonicNowNs();

                _ = self.read_ns.fetchAdd(feed_t0 - read_t0, .monotonic);
                _ = self.feed_ns.fetchAdd(now - feed_t0, .monotonic);
                _ = self.bytes_read.fetchAdd(n, .monotonic);
                _ = self.read_calls.fetchAdd(1, .monotonic);
                if (self.first_data_ns.load(.monotonic) == 0) {
                    self.first_data_ns.store(read_t0, .release);
                }

                // Ring the doorbell only on the false→true edge: while
                // main hasn't consumed the flag yet, further chunks are
                // already covered by the pending wake (a flood otherwise
                // wakes main once per 64 KB chunk — thousands of empty
                // poll cycles).
                if (!self.data_dirty.swap(true, .acq_rel)) {
                    self.events.wake();
                    // Warm covering fonts from this chunk in parallel with the
                    // first frame. Coalesced to the wake edge: during a flood
                    // main consumes the flag ~per frame, so we warm ~per frame
                    // rather than per 64 KB read.
                    self.atlas_ref.requestWarmFallback(buf[0..n]);
                }

                log_bytes += n;
                log_reads += 1;
                if (now - log_last_ns >= LOG_INTERVAL_NS) {
                    log.debug(.pty, "drained", .{ .reads = log_reads, .bytes = log_bytes });
                    log_last_ns = now;
                    log_bytes = 0;
                    log_reads = 0;
                }
            }
        }
        log.info(.pty, "reader thread exiting (eof)", .{});
    }

    fn finishEof(self: *Reader) void {
        self.saw_eof.store(true, .release);
        self.events.push(.pty_eof);
    }
};
