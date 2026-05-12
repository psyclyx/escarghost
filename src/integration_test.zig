//! Integration test harness. Runs as a wayland client inside a
//! sway-headless compositor, spawns scrgo, injects keystrokes via
//! zwp_virtual_keyboard_v1, captures frames via zwlr_screencopy_v1, and
//! verifies that each injected key produces a non-bg pixel delta inside
//! the expected cell — i.e. the keystroke actually reached pixels.
//!
//! Phase 1: detect scrgo window via wlr_foreign_toplevel.
//! Phase 2: screencopy + virtual_keyboard + per-key pixel verification.
//! Phase 3: longer scenario covering the CPU→GPU renderer swap, with the
//!   assertion that no key's inject→visible latency spikes around the
//!   moment the GPU takes over.
//!

const std = @import("std");
const perf = @import("perf.zig");

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wlr-foreign-toplevel-management-unstable-v1-client-protocol.h");
    @cInclude("wlr-screencopy-unstable-v1-client-protocol.h");
    @cInclude("virtual-keyboard-unstable-v1-client-protocol.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const posix = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/mman.h");
    @cInclude("poll.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});

// Linux evdev keycodes for the chars we type. virtual_keyboard.key()
// takes raw evdev codes (xkb keycode minus 8).
const KEY_A: u32 = 30;
const KEY_B: u32 = 48;
const KEY_C: u32 = 46;
const KEY_D: u32 = 32;
const KEY_E: u32 = 18;
const KEY_F: u32 = 33;
const KEY_G: u32 = 34;
const KEY_H: u32 = 35;
const KEY_I: u32 = 23;

fn nowNs() i128 {
    var ts: posix.struct_timespec = undefined;
    if (posix.clock_gettime(posix.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
}

fn nowMs() u32 {
    return @intCast(@divTrunc(nowNs(), 1_000_000));
}

// ── SHM scratch buffer for screencopy frame downloads ──────────────────

const ShmFrame = struct {
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
        self.fd = posix.memfd_create("scrgo-it-frame", 0);
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

// ── Harness state ──────────────────────────────────────────────────────

const Harness = struct {
    display: *wl.wl_display,
    registry: *wl.wl_registry,
    shm: ?*wl.wl_shm = null,
    seat: ?*wl.wl_seat = null,
    output: ?*wl.wl_output = null,
    foreign_manager: ?*wl.zwlr_foreign_toplevel_manager_v1 = null,
    screencopy_manager: ?*wl.zwlr_screencopy_manager_v1 = null,
    vkbd_manager: ?*wl.zwp_virtual_keyboard_manager_v1 = null,

    scrgo_toplevel: ?*wl.zwlr_foreign_toplevel_handle_v1 = null,
    scrgo_title_buf: [256]u8 = undefined,
    scrgo_title_len: usize = 0,
    found_scrgo: bool = false,

    vkbd: ?*wl.zwp_virtual_keyboard_v1 = null,

    // Per-frame capture state. We allocate one ShmFrame per (width,
    // height, format) tuple and reuse it across captures.
    cached_frame: ShmFrame = .{},
    frame_buf_width: u32 = 0,
    frame_buf_height: u32 = 0,
    frame_buf_stride: u32 = 0,
    frame_buf_format: u32 = 0,
    frame_buf_ready: bool = false,
    capture_pending: bool = false,
    capture_failed: bool = false,
    capture_serial: u64 = 0,
    capture_y_invert: bool = false,

    fn init(self: *Harness) !void {
        self.display = wl.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer wl.wl_display_disconnect(self.display);
        self.registry = wl.wl_display_get_registry(self.display) orelse return error.RegistryFailed;
        _ = wl.wl_registry_add_listener(self.registry, &registry_listener, @ptrCast(self));
        _ = wl.wl_display_roundtrip(self.display);
        // Some globals (zwlr_foreign_toplevel_manager) emit followup events
        // (each existing toplevel) only after we add a listener. Bind +
        // listen + second roundtrip.
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

        // Compile and upload an xkb keymap so virtual_keyboard knows how
        // to interpret our keycodes. We use the default us layout.
        try self.setupVirtualKeyboard();

        _ = wl.wl_display_roundtrip(self.display);
    }

    fn deinit(self: *Harness) void {
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

        const fd = posix.memfd_create("scrgo-it-keymap", 0);
        if (fd < 0) return error.MemfdFailed;
        defer _ = posix.close(fd);
        const total: usize = km_len + 1; // include NUL
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

    fn dispatchOnce(self: *Harness, timeout_ms: c_int) !bool {
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

    fn waitForScrgo(self: *Harness, deadline_ms: u32) !bool {
        const start = nowNs();
        const dl = start + @as(i128, deadline_ms) * 1_000_000;
        while (!self.found_scrgo) {
            const left = dl - nowNs();
            if (left <= 0) return false;
            const ms: c_int = @intCast(@max(@as(i128, 1), @divTrunc(left, 1_000_000)));
            _ = try self.dispatchOnce(@min(ms, @as(c_int, 100)));
        }
        return true;
    }

    /// Capture one frame from the configured output into self.cached_frame.
    /// Blocks until the compositor reports ready (or fails). Returns the
    /// pixel buffer.
    fn captureFrame(self: *Harness) ![]const u8 {
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

    fn typeKey(self: *Harness, keycode: u32) !void {
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
            // First output wins. sway-headless gives us exactly one.
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
        _ = wl.zwlr_foreign_toplevel_handle_v1_add_listener(handle, &foreign_toplevel_listener, @ptrCast(self));
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

    fn handleTitle(data: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1, title: [*c]const u8) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        const s = std.mem.span(title);
        const n = @min(s.len, self.scrgo_title_buf.len);
        @memcpy(self.scrgo_title_buf[0..n], s[0..n]);
        self.scrgo_title_len = n;
    }

    fn handleAppId(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, app_id: [*c]const u8) callconv(.c) void {
        const self: *Harness = @ptrCast(@alignCast(data));
        const s = std.mem.span(app_id);
        if (std.mem.eql(u8, s, "scrgo")) {
            self.scrgo_toplevel = handle;
            self.found_scrgo = true;
        }
    }

    fn handleOutputEnter(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1, _: ?*wl.wl_output) callconv(.c) void {}
    fn handleOutputLeave(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1, _: ?*wl.wl_output) callconv(.c) void {}
    fn handleState(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1, _: ?*wl.wl_array) callconv(.c) void {}
    fn handleDone(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {}
    fn handleClosed(_: ?*anyopaque, _: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {}
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
        // Realloc the cached shm buffer if dimensions or format changed.
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
            self.frame_buf_width = width;
            self.frame_buf_height = height;
            self.frame_buf_stride = stride;
            self.frame_buf_format = format;
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
        // y_invert = 1 means the buffer's row 0 is the BOTTOM of the screen
        // (GL convention). We flip pixel reads to compensate.
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

fn spawnScrgo(scrgo_path: []const u8, child_argv: []const []const u8) !posix.pid_t {
    const pid = posix.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        var argv_buf: [16:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 16;
        var slots: [16][512]u8 = undefined;
        var i: usize = 0;

        const copy = struct {
            fn into(dst: *[512]u8, src: []const u8) [:0]u8 {
                if (src.len + 1 > dst.len) posix._exit(127);
                @memcpy(dst[0..src.len], src);
                dst[src.len] = 0;
                return dst[0..src.len :0];
            }
        }.into;

        argv_buf[i] = copy(&slots[i], scrgo_path);
        i += 1;
        argv_buf[i] = copy(&slots[i], "-e");
        i += 1;
        for (child_argv) |a| {
            if (i >= argv_buf.len - 1) posix._exit(127);
            argv_buf[i] = copy(&slots[i], a);
            i += 1;
        }

        var path_buf: [512]u8 = undefined;
        const path_z = copy(&path_buf, scrgo_path);
        _ = posix.execv(path_z.ptr, @ptrCast(&argv_buf));
        posix._exit(127);
    }
    return pid;
}

/// Pixel layout: how many bytes per pixel and which offset within is each
/// channel. Driven by the screencopy `buffer` event's format. Currently
/// supports XRGB/ARGB8888 (4bpp, B-G-R-X in memory) and BGR/RGB888 (3bpp).
const PixelFmt = struct {
    bpp: u32,
    r_off: u32,
    g_off: u32,
    b_off: u32,
};

fn pixelFmtFromShm(fmt: u32) ?PixelFmt {
    // wl_shm hardcodes 0 = ARGB8888, 1 = XRGB8888. Everything else is a
    // DRM fourcc.
    return switch (fmt) {
        0, 1 => .{ .bpp = 4, .r_off = 2, .g_off = 1, .b_off = 0 }, // XRGB/ARGB8888
        0x34324742 => .{ .bpp = 3, .r_off = 0, .g_off = 1, .b_off = 2 }, // BG24 = DRM_FORMAT_BGR888
        0x34324752 => .{ .bpp = 3, .r_off = 2, .g_off = 1, .b_off = 0 }, // RG24 = DRM_FORMAT_RGB888
        else => null,
    };
}

fn pixelAt(frame: []const u8, stride: u32, fmt: PixelFmt, x: u32, y: u32) ?[3]u8 {
    const off = y * stride + x * fmt.bpp;
    if (off + fmt.bpp > frame.len) return null;
    return .{
        frame[off + fmt.r_off],
        frame[off + fmt.g_off],
        frame[off + fmt.b_off],
    };
}

/// Count pixels in a rectangle whose RGB sum differs from the reference
/// by more than `threshold`. Used to detect that *something* was drawn
/// without caring exactly what.
fn nonBgPixels(frame: []const u8, stride: u32, fmt: PixelFmt, x: u32, y: u32, w: u32, h: u32, bg: [3]u8, threshold: i32) u64 {
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

fn killChild(pid: posix.pid_t) void {
    _ = posix.kill(pid, posix.SIGTERM);
    var status: c_int = 0;
    _ = posix.waitpid(pid, &status, 0);
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const scrgo_path_opt = args_iter.next();
    if (scrgo_path_opt == null) {
        std.debug.print("usage: scrgo-integration-test <scrgo-binary>\n", .{});
        std.process.exit(2);
    }
    const scrgo_path = scrgo_path_opt.?;
    const cat_path = blk: {
        const env_cat = posix.getenv("SCRGO_IT_CAT");
        if (env_cat) |p| break :blk std.mem.span(p);
        break :blk "/bin/cat";
    };
    const child_argv = [_][]const u8{cat_path};

    // Pre-spawn baseline: capture once so we know what the compositor
    // looks like with no scrgo surface mapped. This is the "initial"
    // pixel state at our probe point, which lets us detect scrgo's
    // first paint by watching for that pixel to *change*.
    const t_start = perf.Timer.now();
    var harness: Harness = .{ .display = undefined, .registry = undefined };
    try harness.init();
    defer harness.deinit();
    std.debug.print("harness: globals bound ({d:.1}ms)\n", .{t_start.elapsedMs()});

    const pre_cap = try harness.captureFrame();
    const stride = harness.cached_frame.stride;
    const out_w = harness.cached_frame.width;
    const out_h = harness.cached_frame.height;
    const pix_fmt = pixelFmtFromShm(harness.cached_frame.format) orelse {
        std.debug.print("FAIL: unsupported shm format 0x{x}\n", .{harness.cached_frame.format});
        std.process.exit(1);
    };
    // Probe scrgo's top-left surface region (sway tiles it at output
    // origin with the for_window focus rule). (5,5) sits inside any
    // reasonable scrgo window, away from the very edge.
    const probe_px: u32 = 5;
    const probe_py: u32 = 5;
    const initial_px = pixelAt(pre_cap, stride, pix_fmt, probe_px, probe_py) orelse {
        std.debug.print("FAIL: probe out of bounds in pre-spawn capture\n", .{});
        std.process.exit(1);
    };
    std.debug.print("harness: pre-spawn frame {}x{} stride={} fmt=0x{x}, ({},{}) = rgb({},{},{}) ({d:.1}ms)\n", .{
        out_w, out_h, stride, harness.cached_frame.format,
        probe_px, probe_py, initial_px[0], initial_px[1], initial_px[2],
        t_start.elapsedMs(),
    });

    // Spawn scrgo and start the clock for startup-latency measurements.
    const t_spawn = perf.Timer.now();
    const pid = try spawnScrgo(scrgo_path, &child_argv);
    errdefer killChild(pid);
    std.debug.print("harness: spawned scrgo pid={} (t_spawn=0)\n", .{pid});

    // ── Startup latency: spawn → first-paint → first-content ──────────
    //
    // first-paint = first captured frame where probe pixel differs from
    //   `initial_px`. That's the earliest moment any scrgo commit
    //   (typically the 1px-bg single_pixel_buffer) reached the
    //   compositor's output.
    // first-content = first captured frame where the top-left cell row
    //   has >= 5 non-bg pixels. That's the earliest moment scrgo's
    //   rendered cells (cursor / shell output) actually became visible.
    //
    // Both metrics are reported in (ms since spawn, captures consumed).
    // captures-elapsed is a coarse upper bound on compositor frames,
    // since each captureFrame round-trips through screencopy and may
    // skip a vblank if we're slow.

    const probe_x: u32 = 0;
    const probe_y: u32 = 0;
    const probe_w: u32 = 200;
    const probe_h: u32 = 24;
    const non_bg_thresh: i32 = 30;
    const startup_deadline_ms: f64 = 2000;

    var first_paint_ms: ?f64 = null;
    var first_paint_caps: u32 = 0;
    var first_content_ms: ?f64 = null;
    var first_content_caps: u32 = 0;
    var bg: [3]u8 = initial_px;
    var caps: u32 = 0;
    var content_buf: ?[]u8 = null;
    defer if (content_buf) |b| std.heap.smp_allocator.free(b);

    while (first_content_ms == null and t_spawn.elapsedMs() < startup_deadline_ms) {
        const cap = try harness.captureFrame();
        caps += 1;
        const px = pixelAt(cap, stride, pix_fmt, probe_px, probe_py) orelse continue;
        const changed = px[0] != initial_px[0] or px[1] != initial_px[1] or px[2] != initial_px[2];
        if (first_paint_ms == null and changed) {
            first_paint_ms = t_spawn.elapsedMs();
            first_paint_caps = caps;
            bg = px;
        }
        if (first_paint_ms != null) {
            const cnt = nonBgPixels(cap, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
            if (cnt >= 5) {
                first_content_ms = t_spawn.elapsedMs();
                first_content_caps = caps;
                content_buf = try std.heap.smp_allocator.alloc(u8, cap.len);
                @memcpy(content_buf.?, cap);
            }
        }
    }

    if (first_paint_ms == null) {
        std.debug.print("FAIL: no first-paint within {d:.0}ms (probe pixel never changed)\n", .{startup_deadline_ms});
        killChild(pid);
        std.process.exit(1);
    }
    if (first_content_ms == null) {
        std.debug.print("FAIL: first paint at {d:.1}ms but no content within {d:.0}ms\n", .{ first_paint_ms.?, startup_deadline_ms });
        killChild(pid);
        std.process.exit(1);
    }
    const content_gap_ms = first_content_ms.? - first_paint_ms.?;
    const content_gap_caps = first_content_caps - first_paint_caps;
    std.debug.print(
        "startup:   first_paint = {d:.1}ms ({} captures)  bg = rgb({},{},{})\n" ++
            "startup: first_content = {d:.1}ms ({} captures)  gap from paint: {d:.1}ms / {} captures\n",
        .{ first_paint_ms.?, first_paint_caps, bg[0], bg[1], bg[2], first_content_ms.?, first_content_caps, content_gap_ms, content_gap_caps },
    );

    // Wait for the foreign_toplevel event too — needed for clean teardown
    // later, and a sanity check that the surface we measured is scrgo's.
    if (!(try harness.waitForScrgo(1000))) {
        std.debug.print("FAIL: scrgo toplevel not announced via foreign_toplevel\n", .{});
        killChild(pid);
        std.process.exit(1);
    }

    var any_failure = false;
    // Soft-fail thresholds — generous so we catch egregious regressions
    // without being flaky on slow CI. Tighten as we collect data.
    if (first_paint_ms.? > 200) {
        std.debug.print("FAIL: first_paint {d:.1}ms exceeds 200ms budget\n", .{first_paint_ms.?});
        any_failure = true;
    }
    if (content_gap_ms > 100) {
        std.debug.print("FAIL: content-after-paint gap {d:.1}ms exceeds 100ms budget\n", .{content_gap_ms});
        any_failure = true;
    }
    if (content_gap_caps > 4) {
        std.debug.print("FAIL: content-after-paint gap {} captures > 4 (expected 1-2)\n", .{content_gap_caps});
        any_failure = true;
    }

    // ── Phase 2: per-key input latency ────────────────────────────────
    //
    // For each of 'abc': inject, then poll captures until the cell row
    // shows new non-bg pixels (signal that scrgo rendered the echo and
    // the compositor presented it). Record (ms, captures) per key.

    var last_count: u64 = nonBgPixels(content_buf.?, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
    std.debug.print("input: cell-row non-bg baseline = {}\n", .{last_count});

    const chars = [_]struct { code: u32, label: u8 }{
        .{ .code = KEY_A, .label = 'a' },
        .{ .code = KEY_B, .label = 'b' },
        .{ .code = KEY_C, .label = 'c' },
    };

    const input_deadline_ms: f64 = 500;
    for (chars) |ch| {
        try harness.typeKey(ch.code);
        const t_inject = perf.Timer.now();
        var icaps: u32 = 0;
        var detected: ?f64 = null;
        var new_count: u64 = last_count;
        while (t_inject.elapsedMs() < input_deadline_ms) {
            const cap = try harness.captureFrame();
            icaps += 1;
            const cnt = nonBgPixels(cap, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
            if (cnt > last_count + 4) {
                detected = t_inject.elapsedMs();
                new_count = cnt;
                break;
            }
        }
        if (detected == null) {
            std.debug.print("FAIL [{c}]: no cell-row change within {d:.0}ms\n", .{ ch.label, input_deadline_ms });
            any_failure = true;
            continue;
        }
        if (detected.? > 50) {
            std.debug.print("WARN [{c}]: latency {d:.1}ms ({} captures) — above 50ms\n", .{ ch.label, detected.?, icaps });
        } else {
            std.debug.print("ok   [{c}]: {d:.1}ms ({} captures, delta +{} non-bg pixels)\n", .{ ch.label, detected.?, icaps, new_count - last_count });
        }
        last_count = new_count;
    }

    // Phase 3: cadenced keys covering the CPU→GPU swap window. scrgo's
    // GPU renderer typically takes over within ~50-150 ms after startup.
    // We've already been alive for a while; restart scrgo so we get to
    // observe the swap. To keep this test fast we just inject 12 keys at
    // ~12 ms cadence — enough to bracket the swap — and check the
    // per-key non-bg delta is consistent. A large outlier suggests a key
    // was dropped or rendered an extra frame late.
    killChild(pid);
    harness.found_scrgo = false;
    harness.scrgo_toplevel = null;
    const pid2 = try spawnScrgo(scrgo_path, &child_argv);
    defer killChild(pid2);

    if (!(try harness.waitForScrgo(5000))) {
        std.debug.print("FAIL: scrgo (run 2) toplevel did not appear\n", .{});
        std.process.exit(1);
    }
    // Drain a couple of frames so we have a clean baseline pixel count.
    _ = try harness.captureFrame();
    const base_cap = try harness.captureFrame();
    var prev_count: u64 = nonBgPixels(base_cap, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
    std.debug.print("\nphase-3: cadenced keypresses (covers CPU→GPU swap)\n", .{});
    std.debug.print("phase-3: baseline cell-row non-bg = {}\n", .{prev_count});

    const cadence_keys = [_]u32{
        KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F,
        KEY_G, KEY_H, KEY_I, KEY_A, KEY_B, KEY_C,
    };
    var latencies_ms: [cadence_keys.len]f64 = undefined;
    var dropped: usize = 0;
    for (cadence_keys, 0..) |code, i| {
        try harness.typeKey(code);
        const t_inject = perf.Timer.now();
        var detected_ms: f64 = -1;
        while (t_inject.elapsedMs() < input_deadline_ms) {
            const cap = try harness.captureFrame();
            const cnt = nonBgPixels(cap, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
            if (cnt > prev_count + 4) {
                detected_ms = t_inject.elapsedMs();
                prev_count = cnt;
                break;
            }
        }
        latencies_ms[i] = detected_ms;
        if (detected_ms < 0) dropped += 1;
    }

    // Distribution: mean / max / outliers. An "extra-frame delayed" key
    // shows up as one latency value that's ~2× the median.
    var sum_ms: f64 = 0;
    var max_ms: f64 = 0;
    var ok_n: usize = 0;
    for (latencies_ms) |ms| {
        if (ms < 0) continue;
        sum_ms += ms;
        max_ms = @max(max_ms, ms);
        ok_n += 1;
    }
    const mean_ms: f64 = if (ok_n > 0) sum_ms / @as(f64, @floatFromInt(ok_n)) else 0;

    std.debug.print("phase-3 latencies (ms):", .{});
    for (latencies_ms) |ms| {
        if (ms < 0) std.debug.print(" -", .{}) else std.debug.print(" {d:.1}", .{ms});
    }
    std.debug.print("  mean={d:.1} max={d:.1}\n", .{ mean_ms, max_ms });

    if (dropped > 0) {
        std.debug.print("FAIL phase-3: {} of {} keys missed (no cell change within {d:.0}ms)\n", .{ dropped, cadence_keys.len, input_deadline_ms });
        any_failure = true;
    }
    // Outlier check: any single key >2× the mean (and >25ms absolute,
    // to avoid flagging the noise floor) is a likely extra-frame stall
    // around the CPU→GPU swap.
    if (max_ms > 25 and ok_n >= 4 and max_ms > 2.0 * mean_ms) {
        std.debug.print("FAIL phase-3: max latency {d:.1}ms is >2× mean {d:.1}ms — possible frame stall\n", .{ max_ms, mean_ms });
        any_failure = true;
    }

    if (any_failure) {
        std.debug.print("FAIL: integration test\n", .{});
        std.process.exit(1);
    }
    std.debug.print("PASS: integration test\n", .{});
}
