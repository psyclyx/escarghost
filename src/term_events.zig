//! Reader-thread → main-thread event channel.
//!
//! Terminal callbacks (bell, title, future OSC handlers) fire on the PTY
//! reader thread, inside `feedData` under the terminal lock. Anything that
//! must run on the main thread — Wayland calls, clipboard, state the main
//! loop owns — is pushed here as a typed event; the main loop polls
//! `wakeFd()` and drains the queue.
//!
//! Adding an OSC callback is a three-line pattern:
//!   1. add a variant to `Event`,
//!   2. push it from the terminal callback (terminal.zig),
//!   3. handle it in main's drain switch.
//!
//! Events must be droppable or coalescable: the queue is bounded and a
//! full queue drops (counted in `dropped`). Prefer re-reading state from
//! the terminal (under its lock) on the main side over carrying payloads —
//! that coalesces bursts for free (see `.title_changed`). Events that must
//! carry large payloads should heap-allocate; the event owns the buffer
//! and the main-side handler frees it.

const std = @import("std");

const c = @cImport({
    @cInclude("sys/eventfd.h");
    @cInclude("unistd.h");
});

pub const Event = union(enum) {
    /// The PTY reader hit EOF/EIO — the child side of the pty closed and
    /// every residual byte has already been fed to the terminal.
    pty_eof,
    /// The terminal title changed (OSC 0/2). No payload: the main-side
    /// handler re-reads `term.getTitle()` under the terminal lock, which
    /// coalesces a burst of title changes into one read of the newest.
    title_changed,
};

/// Bounded SPSC queue: the reader thread (terminal callbacks included)
/// pushes, the main thread pops. `wake()`/`wakeFd()` is a shared eventfd
/// doorbell — also used by the reader's data-fed notification, so main
/// wakes once per burst regardless of how many events accompanied it.
pub const Queue = struct {
    const Cap = 64;

    buf: [Cap]Event = undefined,
    /// Consumer index (main thread owns stores).
    head: std.atomic.Value(u32) = .init(0),
    /// Producer index (reader thread owns stores).
    tail: std.atomic.Value(u32) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),
    wake_fd: c_int = -1,

    pub fn init() !Queue {
        var q: Queue = .{};
        q.wake_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
        if (q.wake_fd < 0) return error.EventfdFailed;
        return q;
    }

    pub fn deinit(self: *Queue) void {
        if (self.wake_fd >= 0) _ = c.close(self.wake_fd);
        self.wake_fd = -1;
    }

    /// Add to the main loop's poll set; readable = events and/or fed PTY
    /// data are pending.
    pub fn wakeFd(self: *const Queue) c_int {
        return self.wake_fd;
    }

    /// Ring the doorbell without enqueuing an event (used by the reader's
    /// "data was fed" path, which coalesces via a flag instead).
    pub fn wake(self: *Queue) void {
        if (self.wake_fd < 0) return;
        const one: u64 = 1;
        _ = c.write(self.wake_fd, &one, @sizeOf(u64));
    }

    /// Clear the doorbell after a poll wake (main thread).
    pub fn drainWake(self: *Queue) void {
        if (self.wake_fd < 0) return;
        var v: u64 = 0;
        _ = c.read(self.wake_fd, &v, @sizeOf(u64));
    }

    /// Producer side — reader thread only. Full queue drops the event.
    pub fn push(self: *Queue, ev: Event) void {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.monotonic);
        if (tail -% head >= Cap) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.buf[tail % Cap] = ev;
        self.tail.store(tail +% 1, .release);
        self.wake();
    }

    /// Consumer side — main thread only.
    pub fn pop(self: *Queue) ?Event {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head == tail) return null;
        const ev = self.buf[head % Cap];
        self.head.store(head +% 1, .release);
        return ev;
    }
};
