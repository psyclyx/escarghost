//! Shared wlroots-client helpers for the integration test and the
//! input-latency bench. Anything Wayland-protocol-shaped (registry
//! binding, screencopy capture, virtual_keyboard upload,
//! foreign_toplevel app_id matching) lives here so the two callers
//! can share one source of truth.

const std = @import("std");

pub const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wlr-foreign-toplevel-management-unstable-v1-client-protocol.h");
    @cInclude("wlr-screencopy-unstable-v1-client-protocol.h");
    @cInclude("virtual-keyboard-unstable-v1-client-protocol.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const posix = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("poll.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});

pub fn nowNs() i128 {
    var ts: posix.struct_timespec = undefined;
    if (posix.clock_gettime(posix.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
}

pub fn nowMs() u32 {
    return @intCast(@divTrunc(nowNs(), 1_000_000));
}

// ── Evdev keycodes for ASCII letters ──────────────────────────────────

/// Linux evdev keycode for the given lowercase ASCII letter (or null).
/// virtual_keyboard.key() takes raw evdev codes (xkb keycode minus 8).
pub fn keyEvdev(ch: u8) ?u32 {
    return switch (ch) {
        'a' => 30,
        'b' => 48,
        'c' => 46,
        'd' => 32,
        'e' => 18,
        'f' => 33,
        'g' => 34,
        'h' => 35,
        'i' => 23,
        'j' => 36,
        'k' => 37,
        'l' => 38,
        'm' => 50,
        'n' => 49,
        'o' => 24,
        'p' => 25,
        'q' => 16,
        'r' => 19,
        's' => 31,
        't' => 20,
        'u' => 22,
        'v' => 47,
        'w' => 17,
        'x' => 45,
        'y' => 21,
        'z' => 44,
        else => null,
    };
}

// ── SHM scratch buffer for screencopy frame downloads ─────────────────

pub const ShmFrame = struct {
    fd: c_int = -1,
    size: usize = 0,
    map: ?[*]u8 = null,
    pool: ?*wl.wl_shm_pool = null,
    buffer: ?*wl.wl_buffer = null,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0,

    fn create(shm: *wl.wl_shm, width: u32, height: u32, stride: u32, format: u32) !ShmFrame {
        var self: ShmFrame = .{ .width = width, .height = height, .stride = stride, .format = format };
        self.size = @as(usize, stride) * height;
        self.fd = posix.memfd_create("scrgo-harness-frame", 0);
        if (self.fd < 0) return error.MemfdFailed;
        if (posix.ftruncate(self.fd, @intCast(self.size)) != 0) return error.FtruncateFailed;
        const m = posix.mmap(null, self.size, posix.PROT_READ | posix.PROT_WRITE, posix.MAP_SHARED, self.fd, 0);
        if (m == posix.MAP_FAILED) return error.MmapFailed;
        self.map = @ptrCast(m);
        self.pool = wl.wl_shm_create_pool(shm, self.fd, @intCast(self.size)) orelse return error.PoolFailed;
        self.buffer = wl.wl_shm_pool_create_buffer(self.pool, 0, @intCast(width), @intCast(height), @intCast(stride), format) orelse return error.BufferFailed;
        return self;
    }

    fn destroy(self: *ShmFrame) void {
        if (self.buffer) |b| wl.wl_buffer_destroy(b);
        if (self.pool) |p| wl.wl_shm_pool_destroy(p);
        if (self.map) |m| _ = posix.munmap(m, self.size);
        if (self.fd >= 0) _ = posix.close(self.fd);
        self.* = .{};
    }
};

// ── Pixel format helpers ──────────────────────────────────────────────

pub const PixelFmt = struct {
    bpp: u32,
    r_off: u32,
    g_off: u32,
    b_off: u32,
};

pub fn pixelFmtFromShm(fmt: u32) ?PixelFmt {
    // wl_shm hardcodes 0 = ARGB8888, 1 = XRGB8888. Everything else is a
    // DRM fourcc.
    return switch (fmt) {
        0, 1 => .{ .bpp = 4, .r_off = 2, .g_off = 1, .b_off = 0 }, // XRGB/ARGB8888
        0x34324742 => .{ .bpp = 3, .r_off = 0, .g_off = 1, .b_off = 2 }, // BG24 = DRM_FORMAT_BGR888
        0x34324752 => .{ .bpp = 3, .r_off = 2, .g_off = 1, .b_off = 0 }, // RG24 = DRM_FORMAT_RGB888
        else => null,
    };
}

pub fn pixelAt(frame: []const u8, stride: u32, fmt: PixelFmt, x: u32, y: u32) ?[3]u8 {
    const off = y * stride + x * fmt.bpp;
    if (off + fmt.bpp > frame.len) return null;
    return .{
        frame[off + fmt.r_off],
        frame[off + fmt.g_off],
        frame[off + fmt.b_off],
    };
}

pub fn nonBgPixels(frame: []const u8, stride: u32, fmt: PixelFmt, x: u32, y: u32, w: u32, h: u32, bg: [3]u8, threshold: i32) u64 {
    var hits: u64 = 0;
    var py: u32 = 0;
    while (py < h) : (py += 1) {
        const row_off = (y + py) * stride + x * fmt.bpp;
        const end = row_off + w * fmt.bpp;
        if (end > frame.len) break;
        var px = row_off;
        while (px < end) : (px += fmt.bpp) {
            const r = frame[px + fmt.r_off];
            const g = frame[px + fmt.g_off];
            const b = frame[px + fmt.b_off];
            const d: i32 = @as(i32, @intCast(@abs(@as(i32, r) - @as(i32, bg[0])))) +
                @as(i32, @intCast(@abs(@as(i32, g) - @as(i32, bg[1])))) +
                @as(i32, @intCast(@abs(@as(i32, b) - @as(i32, bg[2]))));
            if (d > threshold) hits += 1;
        }
    }
    return hits;
}

// ── Process spawn helper ──────────────────────────────────────────────

/// Fork+execv the given argv (with argv[0] used as the path). Returns
/// the child pid. Used to launch the terminal under test.
pub fn spawnArgv(argv: []const []const u8) !posix.pid_t {
    if (argv.len == 0) return error.EmptyArgv;
    const pid = posix.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Silence the terminal-under-test. None of the scenarios read
        // its stdio, but the terminals each emit chatter that otherwise
        // garbles the bench report:
        //   - foot: "compositor does not implement xdg-toplevel-icon",
        //           "slave exited with signal 1 (Hangup)"
        //   - scrgo: perf.zig frame-time telemetry on stderr.
        // Done pre-exec so it covers everything the child writes.
        const dn = posix.open("/dev/null", posix.O_RDWR | posix.O_CLOEXEC);
        if (dn >= 0) {
            _ = posix.dup2(dn, 0);
            _ = posix.dup2(dn, 1);
            _ = posix.dup2(dn, 2);
            if (dn > 2) _ = posix.close(dn);
        }

        var argv_buf: [16:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 16;
        var slots: [16][512]u8 = undefined;

        const copy = struct {
            fn into(dst: *[512]u8, src: []const u8) [:0]u8 {
                if (src.len + 1 > dst.len) posix._exit(127);
                @memcpy(dst[0..src.len], src);
                dst[src.len] = 0;
                return dst[0..src.len :0];
            }
        }.into;

        var i: usize = 0;
        for (argv) |a| {
            if (i >= argv_buf.len - 1) posix._exit(127);
            argv_buf[i] = copy(&slots[i], a);
            i += 1;
        }

        var path_buf: [512]u8 = undefined;
        const path_z = copy(&path_buf, argv[0]);
        _ = posix.execv(path_z.ptr, @ptrCast(&argv_buf));
        posix._exit(127);
    }
    return pid;
}

pub fn killChild(pid: posix.pid_t) void {
    _ = posix.kill(pid, posix.SIGTERM);
    var status: c_int = 0;
    _ = posix.waitpid(pid, &status, 0);
}

// ── Harness ───────────────────────────────────────────────────────────

// Foreign-toplevel tracking: every toplevel announced gets stored so
// waitForAppId can scan a list, sidestepping races where the
// compositor announces an app_id before the caller knows to watch for
// it.
const MaxToplevels = 16;
const ToplevelEntry = struct {
    handle: *wl.zwlr_foreign_toplevel_handle_v1,
    app_id_buf: [128]u8 = undefined,
    app_id_len: usize = 0,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    closed: bool = false,
};

pub const Harness = struct {
    display: *wl.wl_display,
    registry: *wl.wl_registry,
    shm: ?*wl.wl_shm = null,
    seat: ?*wl.wl_seat = null,
    output: ?*wl.wl_output = null,
    foreign_manager: ?*wl.zwlr_foreign_toplevel_manager_v1 = null,
    screencopy_manager: ?*wl.zwlr_screencopy_manager_v1 = null,
    vkbd_manager: ?*wl.zwp_virtual_keyboard_manager_v1 = null,

    vkbd: ?*wl.zwp_virtual_keyboard_v1 = null,

    toplevels: [MaxToplevels]ToplevelEntry = undefined,
    toplevels_n: usize = 0,
    matched_toplevel: ?*wl.zwlr_foreign_toplevel_handle_v1 = null,
    match_title_buf: [256]u8 = undefined,
    match_title_len: usize = 0,

    // Per-frame capture state. We allocate one ShmFrame per (width,
    // height, format) tuple and reuse it across captures.
    cached_frame: ShmFrame = .{},
    capture_pending: bool = false,
    capture_failed: bool = false,
    capture_serial: u64 = 0,
    capture_y_invert: bool = false,
    frame_buf_ready: bool = false,

    pub fn init(self: *Harness) !void {
        self.display = wl.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer wl.wl_display_disconnect(self.display);
        self.registry = wl.wl_display_get_registry(self.display) orelse return error.RegistryFailed;
        _ = wl.wl_registry_add_listener(self.registry, &registry_listener, @ptrCast(self));
        _ = wl.wl_display_roundtrip(self.display);

        if (self.foreign_manager == null) return error.NoForeignToplevelManager;
        if (self.screencopy_manager == null) return error.NoScreencopyManager;
        if (self.vkbd_manager == null) return error.NoVirtualKeyboardManager;
        if (self.shm == null) return error.NoShm;
        if (self.seat == null) return error.NoSeat;
        if (self.output == null) return error.NoOutput;

        _ = wl.zwlr_foreign_toplevel_manager_v1_add_listener(
            self.foreign_manager.?,
            &foreign_manager_listener,
            @ptrCast(self),
        );

        try self.setupVirtualKeyboard();

        _ = wl.wl_display_roundtrip(self.display);
    }

    pub fn deinit(self: *Harness) void {
        self.cached_frame.destroy();
        if (self.vkbd) |k| wl.zwp_virtual_keyboard_v1_destroy(k);
        if (self.foreign_manager) |fm| wl.zwlr_foreign_toplevel_manager_v1_stop(fm);
        wl.wl_display_disconnect(self.display);
    }

    fn setupVirtualKeyboard(self: *Harness) !void {
        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
        defer xkb.xkb_context_unref(ctx);

        const rule_names = xkb.xkb_rule_names{
            .rules = "evdev",
            .model = "pc105",
            .layout = "us",
            .variant = "",
            .options = "",
        };
        const km = xkb.xkb_keymap_new_from_names(ctx, &rule_names, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.KeymapFailed;
        defer xkb.xkb_keymap_unref(km);

        const km_str = xkb.xkb_keymap_get_as_string(km, xkb.XKB_KEYMAP_FORMAT_TEXT_V1) orelse return error.KeymapStringFailed;
        defer std.c.free(km_str);
        const km_len = posix.strlen(km_str);

        const fd = posix.memfd_create("scrgo-harness-keymap", 0);
        if (fd < 0) return error.MemfdFailed;
        defer _ = posix.close(fd);
        const total: usize = km_len + 1;
        if (posix.ftruncate(fd, @intCast(total)) != 0) return error.FtruncateFailed;
        const m = posix.mmap(null, total, posix.PROT_READ | posix.PROT_WRITE, posix.MAP_SHARED, fd, 0);
        if (m == posix.MAP_FAILED) return error.MmapFailed;
        defer _ = posix.munmap(m, total);
        @memcpy(@as([*]u8, @ptrCast(m))[0..km_len], @as([*]const u8, @ptrCast(km_str))[0..km_len]);
        @as([*]u8, @ptrCast(m))[km_len] = 0;

        self.vkbd = wl.zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(
            self.vkbd_manager.?,
            self.seat.?,
        ) orelse return error.VkbdCreateFailed;
        wl.zwp_virtual_keyboard_v1_keymap(self.vkbd.?, wl.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, @intCast(total));
        _ = wl.wl_display_flush(self.display);
    }

    pub fn dispatchOnce(self: *Harness, timeout_ms: c_int) !bool {
        const fd = wl.wl_display_get_fd(self.display);
        while (wl.wl_display_prepare_read(self.display) != 0) {
            if (wl.wl_display_dispatch_pending(self.display) < 0) return error.DispatchFailed;
        }
        _ = wl.wl_display_flush(self.display);
        var pfd = posix.struct_pollfd{ .fd = fd, .events = posix.POLLIN, .revents = 0 };
        const rc = posix.poll(&pfd, 1, timeout_ms);
        if (rc < 0) {
            wl.wl_display_cancel_read(self.display);
            return error.PollFailed;
        }
        if (rc == 0) {
            wl.wl_display_cancel_read(self.display);
            return false;
        }
        if (pfd.revents & posix.POLLIN != 0) {
            if (wl.wl_display_read_events(self.display) < 0) return error.DispatchFailed;
        } else {
            wl.wl_display_cancel_read(self.display);
        }
        if (wl.wl_display_dispatch_pending(self.display) < 0) return error.DispatchFailed;
        return true;
    }

    fn findToplevelByAppId(self: *Harness, app_id: []const u8) ?*ToplevelEntry {
        var i: usize = 0;
        while (i < self.toplevels_n) : (i += 1) {
            const e = &self.toplevels[i];
            if (e.closed) continue;
            if (std.mem.eql(u8, e.app_id_buf[0..e.app_id_len], app_id)) return e;
        }
        return null;
    }

    fn findEntryByHandle(self: *Harness, handle: ?*wl.zwlr_foreign_toplevel_handle_v1) ?*ToplevelEntry {
        const h_ptr = handle orelse return null;
        var i: usize = 0;
        while (i < self.toplevels_n) : (i += 1) {
            if (self.toplevels[i].handle == h_ptr) return &self.toplevels[i];
        }
        return null;
    }

    /// Wait until a toplevel with the given app_id has been announced
    /// (or finds one already announced). Caller must keep `app_id`
    /// alive across the call.
    pub fn waitForAppId(self: *Harness, app_id: []const u8, deadline_ms: u32) !bool {
        const start = nowNs();
        const dl = start + @as(i128, deadline_ms) * 1_000_000;
        while (true) {
            if (self.findToplevelByAppId(app_id)) |entry| {
                self.matched_toplevel = entry.handle;
                const n = entry.title_len;
                @memcpy(self.match_title_buf[0..n], entry.title_buf[0..n]);
                self.match_title_len = n;
                return true;
            }
            const left = dl - nowNs();
            if (left <= 0) return false;
            const ms: c_int = @intCast(@max(@as(i128, 1), @divTrunc(left, 1_000_000)));
            _ = try self.dispatchOnce(@min(ms, @as(c_int, 100)));
        }
    }

    /// Pump dispatch until every announced toplevel is marked closed,
    /// or the deadline hits. Use this between scenarios to make sure a
    /// previous run's window has actually gone away before the next
    /// terminal opens — otherwise the screencopy probe can read pixels
    /// from a still-present old surface.
    pub fn waitAllToplevelsClosed(self: *Harness, deadline_ms: u32) !void {
        const start = nowNs();
        const dl = start + @as(i128, deadline_ms) * 1_000_000;
        while (true) {
            var any_open = false;
            var i: usize = 0;
            while (i < self.toplevels_n) : (i += 1) {
                if (!self.toplevels[i].closed) {
                    any_open = true;
                    break;
                }
            }
            if (!any_open) return;
            const left = dl - nowNs();
            if (left <= 0) return;
            const ms: c_int = @intCast(@max(@as(i128, 1), @divTrunc(left, 1_000_000)));
            _ = try self.dispatchOnce(@min(ms, @as(c_int, 50)));
        }
    }

    /// Capture one frame from the configured output into self.cached_frame.
    /// Blocks until ready or fails. Returns the pixel buffer.
    pub fn captureFrame(self: *Harness) ![]const u8 {
        self.capture_pending = true;
        self.capture_failed = false;
        self.frame_buf_ready = false;
        self.capture_serial += 1;
        const frame = wl.zwlr_screencopy_manager_v1_capture_output(
            self.screencopy_manager.?,
            0,
            self.output.?,
        ) orelse return error.CaptureRequestFailed;
        _ = wl.zwlr_screencopy_frame_v1_add_listener(frame, &screencopy_frame_listener, @ptrCast(self));

        const dl = nowNs() + 2_000_000_000;
        while (self.capture_pending) {
            const left = dl - nowNs();
            if (left <= 0) return error.CaptureTimeout;
            const ms: c_int = @intCast(@max(@as(i128, 1), @divTrunc(left, 1_000_000)));
            _ = try self.dispatchOnce(@min(ms, @as(c_int, 100)));
        }
        wl.zwlr_screencopy_frame_v1_destroy(frame);
        if (self.capture_failed) return error.CaptureFailed;
        const map = self.cached_frame.map orelse return error.NoFrameMap;
        if (self.capture_y_invert) {
            // Flip the buffer in place so callers always read (0,0) =
            // top-left of the screen.
            const stride = self.cached_frame.stride;
            const h = self.cached_frame.height;
            var top: u32 = 0;
            var bot: u32 = h - 1;
            var row_buf: [16384]u8 = undefined;
            const row_len: usize = @min(stride, @as(u32, row_buf.len));
            while (top < bot) : ({
                top += 1;
                bot -= 1;
            }) {
                const a_off = top * stride;
                const b_off = bot * stride;
                @memcpy(row_buf[0..row_len], map[a_off .. a_off + row_len]);
                @memcpy(map[a_off .. a_off + row_len], map[b_off .. b_off + row_len]);
                @memcpy(map[b_off .. b_off + row_len], row_buf[0..row_len]);
            }
        }
        return map[0..self.cached_frame.size];
    }

    pub fn typeKey(self: *Harness, keycode: u32) !void {
        if (self.vkbd == null) return error.NoVirtualKeyboard;
        const t = nowMs();
        wl.zwp_virtual_keyboard_v1_key(self.vkbd.?, t, keycode, wl.WL_KEYBOARD_KEY_STATE_PRESSED);
        wl.zwp_virtual_keyboard_v1_key(self.vkbd.?, t, keycode, wl.WL_KEYBOARD_KEY_STATE_RELEASED);
        _ = wl.wl_display_flush(self.display);
    }

    // ── Listeners ──

    const registry_listener = wl.wl_registry_listener{
        .global = registryGlobal,
        .global_remove = registryGlobalRemove,
    };

    fn registryGlobal(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_seat_interface, @min(version, 5)));
        } else if (std.mem.eql(u8, iface, "wl_output")) {
            if (self.output == null) {
                self.output = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_output_interface, @min(version, 3)));
            }
        } else if (std.mem.eql(u8, iface, "zwlr_foreign_toplevel_manager_v1")) {
            self.foreign_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.zwlr_foreign_toplevel_manager_v1_interface, @min(version, 3)));
        } else if (std.mem.eql(u8, iface, "zwlr_screencopy_manager_v1")) {
            self.screencopy_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.zwlr_screencopy_manager_v1_interface, @min(version, 3)));
        } else if (std.mem.eql(u8, iface, "zwp_virtual_keyboard_manager_v1")) {
            self.vkbd_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.zwp_virtual_keyboard_manager_v1_interface, 1));
        }
    }

    fn registryGlobalRemove(_: ?*anyopaque, _: ?*wl.wl_registry, _: u32) callconv(.c) void {}

    const foreign_manager_listener = wl.zwlr_foreign_toplevel_manager_v1_listener{
        .toplevel = foreignToplevel,
        .finished = foreignFinished,
    };

    fn foreignToplevel(data: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_manager_v1, handle: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        const h_ptr = handle orelse return;
        // Prefer reusing a closed slot so we don't run out across the
        // multi-scenario run (5 terminals × N runs adds up fast).
        var slot: ?usize = null;
        var i: usize = 0;
        while (i < self.toplevels_n) : (i += 1) {
            if (self.toplevels[i].closed) {
                slot = i;
                break;
            }
        }
        if (slot == null and self.toplevels_n < self.toplevels.len) {
            slot = self.toplevels_n;
            self.toplevels_n += 1;
        }
        if (slot) |idx| {
            self.toplevels[idx] = .{ .handle = h_ptr };
            _ = wl.zwlr_foreign_toplevel_handle_v1_add_listener(handle, &foreign_toplevel_listener, @ptrCast(self));
        } else {
            std.debug.print("wlr_harness: toplevel array full ({} live), dropping new handle\n", .{self.toplevels_n});
        }
    }

    fn foreignFinished(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_manager_v1) callconv(.c) void {}

    const foreign_toplevel_listener = wl.zwlr_foreign_toplevel_handle_v1_listener{
        .title = handleTitle,
        .app_id = handleAppId,
        .output_enter = handleOutputEnter,
        .output_leave = handleOutputLeave,
        .state = handleState,
        .done = handleDone,
        .closed = handleClosed,
        .parent = handleParent,
    };

    fn handleTitle(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, title: [*c]const u8) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        const entry = self.findEntryByHandle(handle) orelse return;
        const s = std.mem.span(title);
        const n = @min(s.len, entry.title_buf.len);
        @memcpy(entry.title_buf[0..n], s[0..n]);
        entry.title_len = n;
    }

    fn handleAppId(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, app_id: [*c]const u8) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        const entry = self.findEntryByHandle(handle) orelse return;
        const s = std.mem.span(app_id);
        const n = @min(s.len, entry.app_id_buf.len);
        @memcpy(entry.app_id_buf[0..n], s[0..n]);
        entry.app_id_len = n;
        if (posix.getenv("WLR_HARNESS_DEBUG") != null) {
            std.debug.print("wlr_harness: toplevel app_id='{s}'\n", .{s});
        }
    }

    fn handleOutputEnter(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1, _: ?*wl.wl_output) callconv(.c) void {}
    fn handleOutputLeave(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1, _: ?*wl.wl_output) callconv(.c) void {}
    fn handleState(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1, _: ?*wl.wl_array) callconv(.c) void {}
    fn handleDone(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {}
    fn handleClosed(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        if (self.findEntryByHandle(handle)) |entry| {
            entry.closed = true;
            // Per the wlr-foreign-toplevel-management protocol, the
            // handle is semantically dead after `closed` and the client
            // owns destroying it. Doing it here lets the compositor
            // release its side and means a stale handle pointer in the
            // entry can't be confused with a future allocation.
            wl.zwlr_foreign_toplevel_handle_v1_destroy(handle);
        }
    }
    fn handleParent(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1, _: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {}

    // ── Screencopy frame ──

    const screencopy_frame_listener = wl.zwlr_screencopy_frame_v1_listener{
        .buffer = screencopyBuffer,
        .flags = screencopyFlags,
        .ready = screencopyReady,
        .failed = screencopyFailed,
        .damage = screencopyDamage,
        .linux_dmabuf = screencopyLinuxDmabuf,
        .buffer_done = screencopyBufferDone,
    };

    fn screencopyBuffer(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, format: u32, width: u32, height: u32, stride: u32) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        if (self.cached_frame.buffer == null or
            self.cached_frame.width != width or
            self.cached_frame.height != height or
            self.cached_frame.stride != stride or
            self.cached_frame.format != format)
        {
            self.cached_frame.destroy();
            self.cached_frame = ShmFrame.create(self.shm.?, width, height, stride, format) catch {
                self.capture_failed = true;
                return;
            };
        }
        self.frame_buf_ready = true;
    }

    fn screencopyLinuxDmabuf(_: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}

    fn screencopyBufferDone(data: ?*anyopaque, frame: ?*wl.zwlr_screencopy_frame_v1) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        if (!self.frame_buf_ready) {
            self.capture_failed = true;
            self.capture_pending = false;
            return;
        }
        wl.zwlr_screencopy_frame_v1_copy(frame, self.cached_frame.buffer);
    }

    fn screencopyFlags(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, flags: u32) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        self.capture_y_invert = (flags & wl.ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
    }
    fn screencopyDamage(_: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}

    fn screencopyReady(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        self.capture_pending = false;
    }

    fn screencopyFailed(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        self.capture_failed = true;
        self.capture_pending = false;
    }
};
