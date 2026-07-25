//! Wayland clipboard + primary-selection plumbing.
//!
//! Backs the Ctrl+Shift+C / Ctrl+Shift+V keybindings and middle-click
//! paste. Both channels (regular clipboard via wl_data_device_manager,
//! primary via zwp_primary_selection_device_manager_v1) share the same
//! state machine; the two `kind` variants distinguish them.
//!
//! Lifecycle of a copy:
//!   1. main.zig calls setText(.clipboard, text, serial).
//!   2. We create a wl_data_source (or primary source), offer the
//!      common text MIME types, and call set_selection(source, serial).
//!   3. When another client reads from us, .send fires on the source
//!      listener: write our buffer to the fd it hands us and close.
//!   4. .cancelled fires when the compositor replaces our selection;
//!      we destroy the source and drop the buffer.
//!
//! Lifecycle of a paste:
//!   1. The compositor sends data_offer (creates an offer object) plus
//!      one offer.offer event per MIME type the source advertises.
//!   2. Then selection() hands us the offer pointer.
//!   3. main.zig calls getText(.clipboard, allocator, timeout_ms),
//!      which sends `wl_data_offer.receive("text/plain;charset=utf-8",
//!      write_fd)`, closes the write side, flushes, and reads the
//!      read side until EOF or timeout.

const std = @import("std");

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("primary-selection-unstable-v1-client-protocol.h");
});

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("poll.h");
});

pub const Kind = enum { clipboard, primary };

/// MIME types we advertise on copy and try on paste, in preference
/// order. Most apps support either "text/plain;charset=utf-8" or
/// "UTF8_STRING"; some legacy ones only support "text/plain".
const MIME_TYPES = [_][:0]const u8{
    "text/plain;charset=utf-8",
    "UTF8_STRING",
    "text/plain",
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io = undefined,
    data_device: ?*wl.wl_data_device,
    primary_device: ?*wl.zwp_primary_selection_device_v1,
    data_device_manager: ?*wl.wl_data_device_manager,
    primary_selection_manager: ?*wl.zwp_primary_selection_device_manager_v1,
    display: *wl.wl_display,

    /// Live source for outgoing copies. We own the buffer; .send
    /// writes it; .cancelled destroys both.
    clipboard_source: ?*wl.wl_data_source = null,
    clipboard_text: ?[]u8 = null,
    primary_source: ?*wl.zwp_primary_selection_source_v1 = null,
    primary_text: ?[]u8 = null,

    /// Most-recent offer from the compositor for each kind. The
    /// data_device listener wires offers into here; getText() reads
    /// from whichever is current.
    clipboard_offer: ?*wl.wl_data_offer = null,
    primary_offer: ?*wl.zwp_primary_selection_offer_v1 = null,

    /// `display`, `data_device`, etc. arrive as opaque pointers from
    /// the caller's @cImport view — Zig sees those as different types
    /// than ours even when both translation units include the same
    /// header. We re-cast on entry and use our own typed views from
    /// here on.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        display: ?*anyopaque,
        data_device: ?*anyopaque,
        primary_device: ?*anyopaque,
        data_device_manager: ?*anyopaque,
        primary_selection_manager: ?*anyopaque,
    ) Manager {
        // Listeners attach in `bindListeners` after the Manager is at
        // its permanent address (Wayland holds a raw data ptr).
        return .{
            .allocator = allocator,
            .io = io,
            .display = @ptrCast(display.?),
            .data_device = if (data_device) |p| @ptrCast(p) else null,
            .primary_device = if (primary_device) |p| @ptrCast(p) else null,
            .data_device_manager = if (data_device_manager) |p| @ptrCast(p) else null,
            .primary_selection_manager = if (primary_selection_manager) |p| @ptrCast(p) else null,
        };
    }

    pub fn deinit(self: *Manager) void {
        self.clearClipboardSource();
        self.clearPrimarySource();
        self.clearClipboardOffer();
        self.clearPrimaryOffer();
    }

    /// Re-attach the listeners after the Manager is moved or stored.
    /// Wayland listeners hold a raw `data` pointer; if the Manager
    /// gets moved between the init call and the first event, the
    /// pointer goes stale. Call this once the Manager is at its
    /// permanent address.
    pub fn bindListeners(self: *Manager) void {
        if (self.data_device) |dd| {
            _ = wl.wl_data_device_add_listener(dd, &data_device_listener, @ptrCast(self));
        }
        if (self.primary_device) |pd| {
            _ = wl.zwp_primary_selection_device_v1_add_listener(pd, &primary_device_listener, @ptrCast(self));
        }
    }

    /// Claim the given selection with `text`. Takes ownership of
    /// `text` (a freshly-allocated buffer the caller will not free).
    /// `serial` must come from a recent input event.
    pub fn setText(self: *Manager, kind: Kind, text: []u8, serial: u32) !void {
        switch (kind) {
            .clipboard => {
                const mgr = self.data_device_manager orelse return error.ClipboardUnavailable;
                const dd = self.data_device orelse return error.ClipboardUnavailable;
                self.clearClipboardSource();
                const source = wl.wl_data_device_manager_create_data_source(mgr) orelse return error.SourceCreateFailed;
                for (MIME_TYPES) |m| wl.wl_data_source_offer(source, m.ptr);
                _ = wl.wl_data_source_add_listener(source, &clipboard_source_listener, @ptrCast(self));
                wl.wl_data_device_set_selection(dd, source, serial);
                self.clipboard_source = source;
                self.clipboard_text = text;
            },
            .primary => {
                const mgr = self.primary_selection_manager orelse return error.ClipboardUnavailable;
                const pd = self.primary_device orelse return error.ClipboardUnavailable;
                self.clearPrimarySource();
                const source = wl.zwp_primary_selection_device_manager_v1_create_source(mgr) orelse return error.SourceCreateFailed;
                for (MIME_TYPES) |m| wl.zwp_primary_selection_source_v1_offer(source, m.ptr);
                _ = wl.zwp_primary_selection_source_v1_add_listener(source, &primary_source_listener, @ptrCast(self));
                wl.zwp_primary_selection_device_v1_set_selection(pd, source, serial);
                self.primary_source = source;
                self.primary_text = text;
            },
        }
    }

    /// Synchronously read the current selection. Returns null when
    /// no offer is present or the read times out. The returned slice
    /// is owned by `allocator`.
    pub fn getText(self: *Manager, kind: Kind, allocator: std.mem.Allocator, timeout_ms: u32) !?[]u8 {
        // Self-paste short-circuit: when we own the source, the
        // compositor echoes our own offer back, but calling
        // wl_data_offer_receive on it would deadlock — the source's
        // .send event fires via the wayland socket and writes to the
        // pipe, but we're blocked in read() and never dispatch the
        // event. Just return a copy of our local buffer instead.
        switch (kind) {
            .clipboard => if (self.clipboard_source != null) {
                const t = self.clipboard_text orelse return null;
                if (t.len == 0) return null;
                return try allocator.dupe(u8, t);
            },
            .primary => if (self.primary_source != null) {
                const t = self.primary_text orelse return null;
                if (t.len == 0) return null;
                return try allocator.dupe(u8, t);
            },
        }

        const fds = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return error.PipeFailed;
        const read_fd = fds[0];
        const write_fd = fds[1];

        // Set non-blocking on the read side so a slow
        // source can't lock us up forever.
        const flags = c.fcntl(read_fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(read_fd, c.F_SETFL, flags | c.O_NONBLOCK);

        const mime: [:0]const u8 = MIME_TYPES[0];

        switch (kind) {
            .clipboard => {
                const offer = self.clipboard_offer orelse {
                    _ = std.c.close(read_fd);
                    _ = std.c.close(write_fd);
                    return null;
                };
                wl.wl_data_offer_receive(offer, mime.ptr, write_fd);
            },
            .primary => {
                const offer = self.primary_offer orelse {
                    _ = std.c.close(read_fd);
                    _ = std.c.close(write_fd);
                    return null;
                };
                wl.zwp_primary_selection_offer_v1_receive(offer, mime.ptr, write_fd);
            },
        }

        // Close our copy of the write side — the source app already
        // received a duplicate via the Wayland socket. Once it
        // closes its end too, read_fd hits EOF.
        _ = std.c.close(write_fd);
        _ = wl.wl_display_flush(self.display);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        var deadline_remaining = timeout_ms;
        var chunk: [4096]u8 = undefined;
        while (true) {
            var pfd = c.struct_pollfd{ .fd = read_fd, .events = c.POLLIN, .revents = 0 };
            const rc = c.poll(&pfd, 1, @intCast(deadline_remaining));
            if (rc <= 0) break; // timeout or error
            if (pfd.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0 and pfd.revents & c.POLLIN == 0) break;
            const rfile = std.Io.File{ .handle = read_fd, .flags = .{ .nonblocking = true } };
            const n = rfile.readStreaming(self.io, &.{&chunk}) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.EndOfStream => break,
                else => break,
            };
            if (n == 0) break;
            try out.appendSlice(allocator, chunk[0..n]);
            // Short subsequent polls — the source usually delivers
            // everything in a single burst.
            deadline_remaining = 20;
        }
        _ = std.c.close(read_fd);

        if (out.items.len == 0) return null;
        return try out.toOwnedSlice(allocator);
    }

    fn clearClipboardSource(self: *Manager) void {
        if (self.clipboard_source) |s| {
            wl.wl_data_source_destroy(s);
            self.clipboard_source = null;
        }
        if (self.clipboard_text) |t| {
            self.allocator.free(t);
            self.clipboard_text = null;
        }
    }
    fn clearPrimarySource(self: *Manager) void {
        if (self.primary_source) |s| {
            wl.zwp_primary_selection_source_v1_destroy(s);
            self.primary_source = null;
        }
        if (self.primary_text) |t| {
            self.allocator.free(t);
            self.primary_text = null;
        }
    }
    fn clearClipboardOffer(self: *Manager) void {
        if (self.clipboard_offer) |o| {
            wl.wl_data_offer_destroy(o);
            self.clipboard_offer = null;
        }
    }
    fn clearPrimaryOffer(self: *Manager) void {
        if (self.primary_offer) |o| {
            wl.zwp_primary_selection_offer_v1_destroy(o);
            self.primary_offer = null;
        }
    }

    // ── wl_data_source listener ─────────────────────────────────────

    const clipboard_source_listener = wl.wl_data_source_listener{
        .target = clipboardSourceTarget,
        .send = clipboardSourceSend,
        .cancelled = clipboardSourceCancelled,
        .dnd_drop_performed = clipboardSourceDndDropPerformed,
        .dnd_finished = clipboardSourceDndFinished,
        .action = clipboardSourceAction,
    };

    fn clipboardSourceTarget(_: ?*anyopaque, _: ?*wl.wl_data_source, _: [*c]const u8) callconv(.c) void {}

    fn clipboardSourceSend(data: ?*anyopaque, _: ?*wl.wl_data_source, _: [*c]const u8, fd: i32) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data));
        writeAllAndClose(fd, self.io, self.clipboard_text);
    }

    fn clipboardSourceCancelled(data: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data));
        self.clearClipboardSource();
    }

    fn clipboardSourceDndDropPerformed(_: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {}
    fn clipboardSourceDndFinished(_: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {}
    fn clipboardSourceAction(_: ?*anyopaque, _: ?*wl.wl_data_source, _: u32) callconv(.c) void {}

    // ── zwp_primary_selection_source_v1 listener ───────────────────

    const primary_source_listener = wl.zwp_primary_selection_source_v1_listener{
        .send = primarySourceSend,
        .cancelled = primarySourceCancelled,
    };

    fn primarySourceSend(data: ?*anyopaque, _: ?*wl.zwp_primary_selection_source_v1, _: [*c]const u8, fd: i32) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data));
        writeAllAndClose(fd, self.io, self.primary_text);
    }
    fn primarySourceCancelled(data: ?*anyopaque, _: ?*wl.zwp_primary_selection_source_v1) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data));
        self.clearPrimarySource();
    }

    // ── wl_data_device listener (incoming offers) ───────────────────

    const data_device_listener = wl.wl_data_device_listener{
        .data_offer = dataDeviceOffer,
        .enter = dataDeviceEnter,
        .leave = dataDeviceLeave,
        .motion = dataDeviceMotion,
        .drop = dataDeviceDrop,
        .selection = dataDeviceSelection,
    };

    fn dataDeviceOffer(_: ?*anyopaque, _: ?*wl.wl_data_device, offer: ?*wl.wl_data_offer) callconv(.c) void {
        // Attach our offer listener so we collect the mime list — we
        // don't actually need the list for paste (we just try our
        // preferred mime and let the source ignore it), but binding
        // the listener keeps the protocol happy.
        if (offer) |o| {
            _ = wl.wl_data_offer_add_listener(o, &clipboard_offer_listener, null);
        }
    }
    fn dataDeviceEnter(_: ?*anyopaque, _: ?*wl.wl_data_device, _: u32, _: ?*wl.wl_surface, _: i32, _: i32, _: ?*wl.wl_data_offer) callconv(.c) void {}
    fn dataDeviceLeave(_: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {}
    fn dataDeviceMotion(_: ?*anyopaque, _: ?*wl.wl_data_device, _: u32, _: i32, _: i32) callconv(.c) void {}
    fn dataDeviceDrop(_: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {}
    fn dataDeviceSelection(data: ?*anyopaque, _: ?*wl.wl_data_device, offer: ?*wl.wl_data_offer) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data));
        self.clearClipboardOffer();
        self.clipboard_offer = offer;
    }

    const clipboard_offer_listener = wl.wl_data_offer_listener{
        .offer = clipboardOfferOffer,
        .source_actions = clipboardOfferSourceActions,
        .action = clipboardOfferAction,
    };
    fn clipboardOfferOffer(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: [*c]const u8) callconv(.c) void {}
    fn clipboardOfferSourceActions(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}
    fn clipboardOfferAction(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}

    // ── zwp_primary_selection_device_v1 listener ────────────────────

    const primary_device_listener = wl.zwp_primary_selection_device_v1_listener{
        .data_offer = primaryDeviceOffer,
        .selection = primaryDeviceSelection,
    };
    fn primaryDeviceOffer(_: ?*anyopaque, _: ?*wl.zwp_primary_selection_device_v1, offer: ?*wl.zwp_primary_selection_offer_v1) callconv(.c) void {
        if (offer) |o| {
            _ = wl.zwp_primary_selection_offer_v1_add_listener(o, &primary_offer_listener, null);
        }
    }
    fn primaryDeviceSelection(data: ?*anyopaque, _: ?*wl.zwp_primary_selection_device_v1, offer: ?*wl.zwp_primary_selection_offer_v1) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data));
        self.clearPrimaryOffer();
        self.primary_offer = offer;
    }
    const primary_offer_listener = wl.zwp_primary_selection_offer_v1_listener{
        .offer = primaryOfferOffer,
    };
    fn primaryOfferOffer(_: ?*anyopaque, _: ?*wl.zwp_primary_selection_offer_v1, _: [*c]const u8) callconv(.c) void {}
};

/// Block-writing helper used by both source listeners. The fd is
/// always closed (even on partial-write failure), matching what
/// other Wayland clients do — clients ignore EPIPE here because the
/// destination may have closed early.
fn writeAllAndClose(fd: c_int, io: std.Io, data: ?[]const u8) void {
    defer _ = std.c.close(fd);
    const bytes = data orelse return;
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.writeStreamingAll(io, bytes) catch {};
}
