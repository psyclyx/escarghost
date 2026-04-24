const std = @import("std");
const config_mod = @import("config.zig");
const wayland_mod = @import("wayland.zig");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");
const renderer_mod = @import("renderer.zig");
const shm_render = @import("shm_render.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const glyph_misses = @import("glyph_misses.zig");
const shared_dmabuf = @import("shared_dmabuf.zig");
const atlas_owner = @import("atlas_owner.zig");
const cpu_renderer_worker = @import("cpu_worker.zig");
const gpu_renderer_proc = @import("gpu_helper.zig");
const perf = @import("perf.zig");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("poll.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/wait.h");
    @cInclude("pthread.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const ghostty_c = @cImport(@cInclude("ghostty/vt.h"));
const xkb_syms = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

fn monotonicNowNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn setCloseOnExec(fd: c_int) void {
    if (fd < 0) return;
    const flags = c.fcntl(fd, c.F_GETFD);
    if (flags < 0) return;
    _ = c.fcntl(fd, c.F_SETFD, flags | c.FD_CLOEXEC);
}

/// mmap a font file — zero copy, stays mapped for process lifetime.
fn mmapFont(path: []const u8) ![]const u8 {
    const path_z = std.heap.smp_allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer std.heap.smp_allocator.free(path_z);

    const fd = c.open(path_z.ptr, c.O_RDONLY);
    if (fd < 0) return error.FileNotFound;

    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) < 0) {
        _ = c.close(fd);
        return error.StatFailed;
    }
    const size: usize = @intCast(st.st_size);

    const map = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    _ = c.close(fd); // fd can be closed after mmap
    if (map == c.MAP_FAILED) return error.MmapFailed;

    const ptr: [*]const u8 = @ptrCast(map);
    return ptr[0..size];
}

const fc = @cImport(@cInclude("fontconfig/fontconfig.h"));

/// Find a monospace font via fontconfig C API (no subprocess).
fn findFontPath(allocator: std.mem.Allocator, config_path: []const u8) ![]const u8 {
    if (config_path.len > 0) return try allocator.dupe(u8, config_path);

    const pattern = fc.FcNameParse("monospace") orelse return error.NoFontFound;
    defer fc.FcPatternDestroy(pattern);

    _ = fc.FcConfigSubstitute(null, pattern, fc.FcMatchPattern);
    fc.FcDefaultSubstitute(pattern);

    var result: fc.FcResult = undefined;
    const match = fc.FcFontMatch(null, pattern, &result) orelse return error.NoFontFound;
    defer fc.FcPatternDestroy(match);

    var file_ptr: [*c]u8 = undefined;
    if (fc.FcPatternGetString(match, fc.FC_FILE, 0, &file_ptr) != fc.FcResultMatch)
        return error.NoFontFound;

    return try allocator.dupe(u8, std.mem.sliceTo(file_ptr, 0));
}

/// Font discovery + parse + atlas build (all CPU, no GL).
fn prepRenderer(renderer: *renderer_mod.Renderer, font_path_out: *[]const u8, cfg_font_path: []const u8, font_size: f32) !void {
    const allocator = std.heap.smp_allocator;
    const timer = perf.Timer.now();
    const path = try findFontPath(allocator, cfg_font_path);
    if (debugStartupEnabled()) {
        std.debug.print("mollusk: prep font path ({d:.1}ms)\n", .{timer.elapsedMs()});
    }
    errdefer allocator.free(path);
    const data = try mmapFont(path);
    if (debugStartupEnabled()) {
        std.debug.print("mollusk: prep font mmap ({d:.1}ms)\n", .{timer.elapsedMs()});
    }
    try renderer.initCpu(allocator, data, font_size);
    if (debugStartupEnabled()) {
        std.debug.print("mollusk: prep renderer cpu init ({d:.1}ms)\n", .{timer.elapsedMs()});
    }
    font_path_out.* = path;
}

// Shared state for callbacks
var g_term: *terminal_mod.Terminal = undefined;
var g_pty: *pty_mod.Pty = undefined;
var g_renderer: *renderer_mod.Renderer = undefined;
var g_renderer_mutex: c.pthread_mutex_t = undefined;

var g_scroll_lines: u32 = 3;
var g_needs_redraw: bool = false;
var g_gpu_renderer_snapshot_dirty: bool = false;
var g_gpu_renderer_reconfigure_requested: bool = false;
var g_render_serial: u32 = 0;

const GpuRendererBufferCount = shared_dmabuf.MaxBuffers;
const RenderPath = enum {
    cpu,
    gpu,
};

var g_renderer_debug: render_env.RendererDebug = .{};

fn rendererDebugOptions() render_env.RendererDebug {
    if (getenv("MOLLUSK_LOG")) |value|
        return render_env.parseRendererDebug(value);
    return .{};
}

fn debugStartupEnabled() bool {
    return g_renderer_debug.startup;
}

fn debugRenderersEnabled() bool {
    return g_renderer_debug.renderers;
}

fn debugFramesEnabled() bool {
    return g_renderer_debug.frames;
}

fn debugPtyEnabled() bool {
    return g_renderer_debug.pty;
}

fn markRenderDirty() void {
    g_render_serial +%= 1;
    if (g_render_serial == 0) g_render_serial = 1;
    g_needs_redraw = true;
    g_gpu_renderer_snapshot_dirty = true;
}

fn lockRenderer() void {
    _ = c.pthread_mutex_lock(&g_renderer_mutex);
}

fn unlockRenderer() void {
    _ = c.pthread_mutex_unlock(&g_renderer_mutex);
}

const RendererMetrics = struct {
    width: u32,
    height: u32,
    font_size: f32,
    cell_width: f32,
    cell_height: f32,
};

fn copyRendererMetrics(renderer: *renderer_mod.Renderer) RendererMetrics {
    lockRenderer();
    defer unlockRenderer();
    return .{
        .width = @intFromFloat(renderer.viewport_w),
        .height = @intFromFloat(renderer.viewport_h),
        .font_size = renderer.font_size,
        .cell_width = renderer.cell_width,
        .cell_height = renderer.cell_height,
    };
}

const GpuRendererRestartBackoff = struct {
    initial_delay_ms: u32,
    max_delay_ms: u32,
    jitter_percent: u32,
    deadline_ns: ?u64 = null,
    attempts: u32 = 0,
    prng: std.Random.DefaultPrng,

    fn init(
        initial_delay_ms: u32,
        max_delay_ms: u32,
        jitter_percent: u32,
    ) GpuRendererRestartBackoff {
        return .{
            .initial_delay_ms = initial_delay_ms,
            .max_delay_ms = @max(initial_delay_ms, max_delay_ms),
            .jitter_percent = jitter_percent,
            .prng = std.Random.DefaultPrng.init(monotonicNowNs()),
        };
    }

    fn clear(self: *GpuRendererRestartBackoff) void {
        self.deadline_ns = null;
        self.attempts = 0;
    }

    fn scheduleImmediate(self: *GpuRendererRestartBackoff) void {
        self.deadline_ns = monotonicNowNs();
    }

    fn scheduleRetry(self: *GpuRendererRestartBackoff) void {
        const shift = @min(self.attempts, 31);
        const scaled = (@as(u64, self.initial_delay_ms) << @intCast(shift));
        const capped = @min(scaled, @as(u64, self.max_delay_ms));
        const base_delay_ms: u32 = @intCast(capped);
        const jitter_pct = @min(self.jitter_percent, 1000);
        const jitter_span = @as(u64, base_delay_ms) * jitter_pct / 100;
        const min_delay: u32 = @intCast(base_delay_ms -| @as(u32, @intCast(@min(jitter_span, base_delay_ms))));
        const max_delay: u32 = @intCast(@min(@as(u64, self.max_delay_ms), @as(u64, base_delay_ms) + jitter_span));
        const delay_ms = if (min_delay < max_delay)
            self.prng.random().intRangeAtMost(u32, min_delay, max_delay)
        else
            min_delay;

        self.deadline_ns = monotonicNowNs() + @as(u64, delay_ms) * std.time.ns_per_ms;
        self.attempts +|= 1;
    }

    fn due(self: *const GpuRendererRestartBackoff) bool {
        const deadline_ns = self.deadline_ns orelse return false;
        return monotonicNowNs() >= deadline_ns;
    }

    fn timeoutMs(self: *const GpuRendererRestartBackoff) ?c_int {
        const deadline_ns = self.deadline_ns orelse return null;
        const now_ns = monotonicNowNs();
        if (deadline_ns <= now_ns) return 0;
        const delta_ns = deadline_ns - now_ns;
        const delta_ms = @max(@as(u64, 1), delta_ns / std.time.ns_per_ms);
        return @intCast(@min(delta_ms, @as(u64, std.math.maxInt(c_int))));
    }
};

const GpuRendererFrontend = struct {
    snapshot_fd: c_int = -1,
    snapshot_map: ?*anyopaque = null,
    snapshot: ?*render_snapshot.SharedSnapshot = null,

    control_fd: c_int = -1,
    child_pid: c_int = -1,
    active: bool = false,
    ready: bool = false,
    render_in_flight: bool = false,
    first_frame_presented: bool = false,

    buffers: [GpuRendererBufferCount]shared_dmabuf.FrontendBuffer = undefined,
    buffer_count: usize = 0,

    fn ensureSnapshot(self: *GpuRendererFrontend) !void {
        if (self.snapshot != null) return;

        const size = @sizeOf(render_snapshot.SharedSnapshot);
        const fd = c.memfd_create("mollusk-gpu-snapshot", @as(c_uint, 0));
        if (fd < 0) return error.MemfdCreateFailed;
        errdefer _ = c.close(fd);
        setCloseOnExec(fd);

        if (c.ftruncate(fd, @intCast(size)) < 0) return error.TruncateFailed;

        const map = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (map == c.MAP_FAILED) return error.MmapFailed;

        self.snapshot_fd = fd;
        self.snapshot_map = map;
        self.snapshot = @ptrCast(@alignCast(map));
        self.snapshot.?.* = .{};
    }

    fn stopChild(self: *GpuRendererFrontend) void {
        if (self.child_pid > 0) {
            _ = c.kill(self.child_pid, c.SIGTERM);
            var status: c_int = 0;
            _ = c.waitpid(self.child_pid, &status, 0);
        }
        if (self.control_fd >= 0) _ = c.close(self.control_fd);

        self.control_fd = -1;
        self.child_pid = -1;
        self.active = false;
        self.ready = false;
        self.render_in_flight = false;
        self.first_frame_presented = false;
    }

    fn destroyBuffers(self: *GpuRendererFrontend) void {
        for (self.buffers[0..self.buffer_count]) |*buffer| {
            buffer.destroy();
        }
        self.buffer_count = 0;
    }

    fn start(self: *GpuRendererFrontend, renderer: *renderer_mod.Renderer, pty_fd: c_int) !void {
        try self.ensureSnapshot();

        self.stopChild();

        var pair: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET, 0, &pair) != 0) return error.SocketpairFailed;
        errdefer {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
        }
        setCloseOnExec(pair[0]);
        setCloseOnExec(pair[1]);

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            _ = c.close(pair[0]);
            if (pty_fd >= 0) _ = c.close(pty_fd);
                gpu_renderer_proc.run(
                    pair[1],
                    renderer,
                    self.snapshot.?,
                    GpuRendererBufferCount,
                );
        }

        _ = c.close(pair[1]);
        self.control_fd = pair[0];
        self.child_pid = pid;
        self.active = true;
        self.ready = false;
        self.render_in_flight = false;
        self.first_frame_presented = false;
    }

    fn requestReconfigure(self: *GpuRendererFrontend, renderer: *renderer_mod.Renderer) !void {
        if (!self.active) return error.HelperInactive;
        self.ready = false;
        self.render_in_flight = false;
        try gpu_renderer_proc.writeRequest(self.control_fd, .{
            .tag = .configure,
            .width = @intFromFloat(renderer.viewport_w),
            .height = @intFromFloat(renderer.viewport_h),
            .font_size = renderer.font_size,
            .cell_width = renderer.cell_width,
            .cell_height = renderer.cell_height,
        });
    }

    fn installBuffers(
        self: *GpuRendererFrontend,
        dmabuf_opaque: *anyopaque,
        ready: gpu_renderer_proc.ReadyPacket,
    ) !void {
        self.destroyBuffers();
        errdefer self.destroyBuffers();
        errdefer closeReadyFds(ready);

        const count = @min(@as(usize, ready.message.buffer_count), GpuRendererBufferCount);
        for (0..count) |i| {
            self.buffers[i] = try shared_dmabuf.FrontendBuffer.create(
                dmabuf_opaque,
                ready.fds[i],
                ready.message.buffers[i],
            );
            self.buffers[i].attachListener();
            self.buffer_count += 1;
        }
    }

    fn deinit(self: *GpuRendererFrontend) void {
        self.stopChild();
        self.destroyBuffers();
        if (self.snapshot_map) |map| _ = c.munmap(map, @sizeOf(render_snapshot.SharedSnapshot));
        if (self.snapshot_fd >= 0) _ = c.close(self.snapshot_fd);
    }

    fn freeBufferIndex(self: *GpuRendererFrontend) ?u8 {
        for (0..self.buffer_count) |i| {
            if (self.buffers[i].released) return @intCast(i);
        }
        return null;
    }
};

fn closeReadyFds(ready: gpu_renderer_proc.ReadyPacket) void {
    const count = @min(@as(usize, ready.message.buffer_count), GpuRendererBufferCount);
    for (ready.fds[0..count]) |fd| {
        if (fd >= 0) _ = c.close(fd);
    }
}

fn onKey(ev: wayland_mod.KeyEvent) void {
    if (ev.state == .released) return;

    // Mollusk bindings (intercepted before sending to PTY)
    if (ev.mods.ctrl and ev.mods.shift) {
        switch (ev.keysym) {
            // Zoom: Ctrl+Shift+Plus / Ctrl+Shift+Minus / Ctrl+Shift+0
            xkb_syms.XKB_KEY_plus, xkb_syms.XKB_KEY_equal => {
                zoomIn();
                return;
            },
            xkb_syms.XKB_KEY_minus, xkb_syms.XKB_KEY_underscore => {
                zoomOut();
                return;
            },
            xkb_syms.XKB_KEY_0, xkb_syms.XKB_KEY_parenright => {
                zoomReset();
                return;
            },
            // Scroll: Ctrl+Shift+Up/Down/PageUp/PageDown/Home/End
            xkb_syms.XKB_KEY_Up => {
                g_term.scrollViewport(-1);
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Down => {
                g_term.scrollViewport(1);
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Page_Up => {
                g_term.scrollViewport(-@as(isize, g_scroll_lines * 10));
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Page_Down => {
                g_term.scrollViewport(@as(isize, g_scroll_lines * 10));
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Home => {
                g_term.scrollToTop();
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_End => {
                g_term.scrollToBottom();
                markRenderDirty();
                return;
            },
            else => {},
        }
    }
    // Shift+PageUp/Down for scroll (common terminal convention)
    if (ev.mods.shift and !ev.mods.ctrl) {
        switch (ev.keysym) {
            xkb_syms.XKB_KEY_Page_Up => {
                g_term.scrollViewport(-@as(isize, g_scroll_lines * 10));
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Page_Down => {
                g_term.scrollViewport(@as(isize, g_scroll_lines * 10));
                markRenderDirty();
                return;
            },
            else => {},
        }
    }

    const utf8_len = @min(ev.utf8_len, ev.utf8.len);
    const utf8 = if (utf8_len > 0) ev.utf8[0..utf8_len] else null;

    if (utf8) |text| {
        // Scroll to bottom on typing (common terminal behavior)
        g_term.scrollToBottom();
        markRenderDirty();
        g_pty.write(text) catch {};
        return;
    }

    const gkey = keysymToGhosttyKey(ev.keysym);
    if (gkey != 0) {
        g_term.scrollToBottom();
        markRenderDirty();
        const encoded = g_term.encodeKey(
            gkey,
            ghostty_c.GHOSTTY_KEY_ACTION_PRESS,
            modsToGhostty(ev.mods),
            null,
        );
        if (encoded) |data| {
            g_pty.write(data) catch {};
        }
    }
}

fn onMouse(ev: wayland_mod.MouseEvent) void {
    if (ev.kind == .scroll) {
        const lines: isize = if (ev.scroll_dy > 0) @intCast(g_scroll_lines) else -@as(isize, @intCast(g_scroll_lines));
        g_term.scrollViewport(lines);
        markRenderDirty();
    }
}

var g_base_font_size: f32 = 14.0;

fn zoomIn() void {
    lockRenderer();
    defer unlockRenderer();
    g_renderer.font_size = @min(g_renderer.font_size + 1.0, 72.0);
    applyZoomLocked();
}

fn zoomOut() void {
    lockRenderer();
    defer unlockRenderer();
    g_renderer.font_size = @max(g_renderer.font_size - 1.0, 6.0);
    applyZoomLocked();
}

fn zoomReset() void {
    lockRenderer();
    defer unlockRenderer();
    g_renderer.font_size = g_base_font_size;
    applyZoomLocked();
}

fn applyZoomLocked() void {
    // Recompute cell metrics for new font size
    const units_per_em: f32 = @floatFromInt(g_renderer.font.unitsPerEm());
    const scale = g_renderer.font_size / units_per_em;
    const m_gid = g_renderer.font.glyphIndex('M') catch 0;
    const m_info = g_renderer.atlas.getGlyph(m_gid);
    g_renderer.cell_width = if (m_info) |g| @ceil(@as(f32, @floatFromInt(g.advance_width)) * scale) else @ceil(g_renderer.font_size * 0.6);
    g_renderer.cell_height = @ceil(g_renderer.font_size * 1.2);

    // Resize terminal grid
    const grid = g_renderer.computeGridSize(@intFromFloat(g_renderer.viewport_w), @intFromFloat(g_renderer.viewport_h));
    if (grid.cols > 0 and grid.rows > 0) {
        g_term.resize(grid.cols, grid.rows, @intFromFloat(g_renderer.cell_width), @intFromFloat(g_renderer.cell_height)) catch {};
        g_pty.resize(grid.cols, grid.rows, @intFromFloat(g_renderer.viewport_w), @intFromFloat(g_renderer.viewport_h));
    }

    // Invalidate vertex cache (cell positions changed)
    g_renderer.generation += 1;
    g_renderer.has_prev_frame = false;
    g_renderer.clearCache();
    markRenderDirty();
    g_gpu_renderer_reconfigure_requested = true;
}

fn onResize(w: u32, h: u32) void {
    lockRenderer();
    defer unlockRenderer();
    const grid = g_renderer.computeGridSize(w, h);
    if (grid.cols == 0 or grid.rows == 0) return;
    g_renderer.setViewport(w, h);
    g_term.resize(grid.cols, grid.rows, @intFromFloat(g_renderer.cell_width), @intFromFloat(g_renderer.cell_height)) catch {};
    g_pty.resize(grid.cols, grid.rows, w, h);
    markRenderDirty();
    g_gpu_renderer_reconfigure_requested = true;
}

fn onFocus(focused: bool) void {
    _ = focused;
}

fn renderCpuFrame(
    wl: *wayland_mod.Wayland,
    term: *terminal_mod.Terminal,
    renderer: *renderer_mod.Renderer,
    cfg: *const config_mod.Config,
    atlas_thread: *atlas_owner.Frontend,
) void {
    const shm = wl.shm orelse return;
    renderer.maybeResetAtlasForDebug() catch return;
    var frame_opt = shm_render.ShmFrame.create(@ptrCast(shm), wl.width, wl.height);
    if (frame_opt) |*frame| {
        defer frame.destroy();
        lockRenderer();
        const misses = frame.renderTerminal(
            term,
            &renderer.atlas,
            &renderer.font,
            renderer.font_size,
            renderer.cell_width,
            renderer.cell_height,
            cfg.foreground,
            cfg.background,
        );
        unlockRenderer();
        atlas_thread.requestMany(&misses);
        frame.commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
        if (!wl.frame_pending) wl.requestFrame();
    }
}

fn maybeQueueGpuRendererFrame(gpu: *GpuRendererFrontend, term: *terminal_mod.Terminal, renderer: *renderer_mod.Renderer) void {
    if (!gpu.active or !gpu.ready or gpu.render_in_flight or !g_gpu_renderer_snapshot_dirty) return;
    const buffer_index = gpu.freeBufferIndex() orelse return;

    render_snapshot.capture(gpu.snapshot.?, term, &renderer.font) catch return;
    if (debugRenderersEnabled()) {
        std.debug.print("mollusk: queue gpu renderer frame buffer={} cells={} {}x{}\n", .{
            buffer_index,
            gpu.snapshot.?.header.cell_count,
            gpu.snapshot.?.header.cols,
            gpu.snapshot.?.header.rows,
        });
    }
    gpu_renderer_proc.writeRequest(gpu.control_fd, .{
        .tag = .render,
        .buffer_index = buffer_index,
        .serial = g_render_serial,
    }) catch {
        gpu.stopChild();
        return;
    };

    gpu.render_in_flight = true;
    g_gpu_renderer_snapshot_dirty = false;
}

fn combineTimeout(a: c_int, b_opt: ?c_int) c_int {
    const b = b_opt orelse return a;
    if (a < 0) return b;
    return @min(a, b);
}

fn renderActivePath(
    active_path: RenderPath,
    gpu: *const GpuRendererFrontend,
    cpu: *cpu_renderer_worker.Frontend,
    atlas_thread: *atlas_owner.Frontend,
    wl: *wayland_mod.Wayland,
    term: *terminal_mod.Terminal,
    renderer: *renderer_mod.Renderer,
    cfg: *const config_mod.Config,
) void {
    if (active_path != .cpu or !g_needs_redraw) return;
    if (gpu.active and gpu.ready) return;
    if (cpu.active) {
        const shm = wl.shm orelse return;
        cpu.ensureBuffers(@ptrCast(shm), wl.width, wl.height) catch |err| switch (err) {
            error.Busy => return,
            else => return,
        };
        const metrics = copyRendererMetrics(renderer);
        cpu.queueRender(term, metrics.width, metrics.height, metrics.font_size, metrics.cell_width, metrics.cell_height, g_render_serial) catch |err| switch (err) {
            error.Busy, error.NoFreeBuffer, error.NoFreeSnapshot => return,
            else => return,
        };
        g_needs_redraw = false;
        if (debugFramesEnabled()) {
            std.debug.print("mollusk: queue cpu renderer frame {}x{}\n", .{ wl.width, wl.height });
        }
        return;
    }
    g_needs_redraw = false;
    if (debugFramesEnabled()) {
        std.debug.print("mollusk: rendering cpu renderer frame {}x{}\n", .{ wl.width, wl.height });
    }
    renderCpuFrame(wl, term, renderer, cfg, atlas_thread);
}

fn noteGpuUnavailable(
    gpu: *GpuRendererFrontend,
    active_path: *RenderPath,
    restart: *GpuRendererRestartBackoff,
) void {
    gpu.stopChild();
    if (debugRenderersEnabled()) {
        std.debug.print("mollusk: gpu renderer unavailable, switching to cpu renderer and scheduling restart\n", .{});
    }
    if (active_path.* == .gpu) {
        active_path.* = .cpu;
        g_needs_redraw = true;
    }
    restart.scheduleRetry();
}

fn spawnGpuRenderer(
    gpu: *GpuRendererFrontend,
    renderer: *renderer_mod.Renderer,
    pty_fd: c_int,
    startup_timer: perf.Timer,
    restart: *GpuRendererRestartBackoff,
    label: []const u8,
) void {
    if (debugRenderersEnabled() or debugStartupEnabled()) {
        std.debug.print("mollusk: {s} ({d:.1}ms)\n", .{ label, startup_timer.elapsedMs() });
    }
    gpu.start(renderer, pty_fd) catch |err| {
        std.debug.print("mollusk: gpu renderer spawn failed: {}\n", .{err});
        restart.scheduleRetry();
        return;
    };
    restart.deadline_ns = null;
}

pub fn main(init: std.process.Init) !void {
    const startup_timer = perf.Timer.now();
    const allocator = std.heap.smp_allocator;
    _ = init.gpa;
    _ = c.pthread_mutex_init(&g_renderer_mutex, null);
    defer _ = c.pthread_mutex_destroy(&g_renderer_mutex);

    // Mesa hints — don't override if already set (0 = no overwrite)
    _ = c.setenv("MESA_NO_ERROR", "1", 0); // skip GL error checking
    _ = c.setenv("MESA_DISK_CACHE_SINGLE_FILE", "1", 0); // faster shader cache reads

    // Auto-detect mesa driver via sysfs (no libdrm dependency).
    {
        var driver_buf: [256]u8 = undefined;
        const fp = c.fopen("/sys/class/drm/renderD128/device/driver/module/drivers", "r");
        if (fp) |f| {
            defer _ = c.fclose(f);
            const n = c.fread(&driver_buf, 1, driver_buf.len - 1, f);
            if (n > 0) {
                driver_buf[n] = 0;
                const s = driver_buf[0..n];
                if (std.mem.indexOf(u8, s, "i915") != null or std.mem.indexOf(u8, s, "xe") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "iris", 0)
                else if (std.mem.indexOf(u8, s, "amdgpu") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "radeonsi", 0)
                else if (std.mem.indexOf(u8, s, "nouveau") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "nouveau", 0)
                else if (std.mem.indexOf(u8, s, "nvidia") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "nvidia", 0);
            }
        }
    }

    // Parse -e flag for command execution
    var exec_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exec_argv.deinit(allocator);
    {
        var args_iter = std.process.Args.Iterator.init(init.minimal.args);
        _ = args_iter.next(); // skip argv[0]
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-e")) {
                // Everything after -e is the command
                while (args_iter.next()) |cmd_arg| {
                    try exec_argv.append(allocator, cmd_arg);
                }
                break;
            }
        }
    }

    // ── Phase 1: config (fast, ~1ms) ──
    var cfg = try config_mod.load(allocator);
    defer cfg.deinit(allocator);
    g_renderer_debug = rendererDebugOptions();
    const runtime_flags = render_env.parseRuntimeFlags(getenv("MOLLUSK_FLAGS"));
    const requested_render_path = render_env.parseRequestedRenderPath(getenv("MOLLUSK_RENDERER"));
    if (debugStartupEnabled()) {
        std.debug.print("mollusk: debug flags startup={} renderers={} frames={} atlas={} pty={} reset_atlas={}\n", .{
            g_renderer_debug.startup,
            g_renderer_debug.renderers,
            g_renderer_debug.frames,
            g_renderer_debug.atlas,
            g_renderer_debug.pty,
            runtime_flags.reset_atlas_each_frame,
        });
        std.debug.print("mollusk: requested renderer mode={s}\n", .{@tagName(requested_render_path)});
    }

    // ── Phase 2: Wayland connect + renderer prep ──
    var wl: wayland_mod.Wayland = undefined;
    try wl.init(800, 600, "mollusk");
    defer wl.deinit();

    if (wl.commitSolidBackground(cfg.background.r, cfg.background.g, cfg.background.b, 255)) {
        if (debugStartupEnabled()) {
            std.debug.print("mollusk: 1px bg ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
        }
    } else if (wl.shm) |shm| {
        var bg_frame = shm_render.ShmFrame.create(@ptrCast(shm), wl.width, wl.height);
        if (bg_frame) |*frame| {
            frame.fillBackground(cfg.background);
            frame.commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
            if (debugStartupEnabled()) {
                std.debug.print("mollusk: SHM bg ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
            }
            frame.destroy();
        }
    }

    var renderer: renderer_mod.Renderer = undefined;
    defer renderer.deinit();
    var font_path: []const u8 = "";
    try prepRenderer(&renderer, &font_path, cfg.font_path, cfg.font_size);
    renderer.setDebugLogs(g_renderer_debug);
    renderer.setDebugResetAtlas(runtime_flags.reset_atlas_each_frame);
    defer allocator.free(font_path);

    var gpu: GpuRendererFrontend = .{};
    defer gpu.deinit();
    var gpu_restart = GpuRendererRestartBackoff.init(
        cfg.gpu_restart_initial_delay_ms,
        cfg.gpu_restart_max_delay_ms,
        cfg.gpu_restart_jitter_percent,
    );
    const gpu_allowed = requested_render_path != .cpu;
    if (debugStartupEnabled() and !gpu_allowed) {
        std.debug.print("mollusk: gpu renderer disabled by MOLLUSK_RENDERER=cpu\n", .{});
    }
    if (requested_render_path == .gpu and wl.linux_dmabuf == null) {
        std.debug.print("mollusk: GPU renderer requested but linux-dmabuf is unavailable; falling back to CPU\n", .{});
    }
    if (gpu_allowed and wl.linux_dmabuf != null) {
        spawnGpuRenderer(&gpu, &renderer, -1, startup_timer, &gpu_restart, "spawning gpu renderer");
    }

    // ── Phase 3: fork PTY ──
    const grid = renderer.computeGridSize(wl.width, wl.height);
    renderer.setViewport(wl.width, wl.height);
    if (gpu.active) {
        lockRenderer();
        gpu.requestReconfigure(&renderer) catch |err| {
            unlockRenderer();
            std.debug.print("mollusk: gpu renderer initial configure failed: {}\n", .{err});
            gpu.stopChild();
            gpu_restart.scheduleRetry();
        };
        if (gpu.active) unlockRenderer();
    }

    var term: terminal_mod.Terminal = undefined;
    try term.init(grid.cols, grid.rows, cfg.max_scrollback, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    var pty = if (exec_argv.items.len > 0)
        try pty_mod.Pty.spawnCommand(exec_argv.items, grid.cols, grid.rows)
    else
        try pty_mod.Pty.spawn(cfg.shell, grid.cols, grid.rows);
    defer pty.close();

    term.pty_fd = pty.master_fd;

    g_term = &term;
    g_pty = &pty;
    g_renderer = &renderer;
    wl.on_key = onKey;
    wl.on_mouse = onMouse;
    wl.on_resize = onResize;
    wl.on_focus = onFocus;
    g_scroll_lines = cfg.scroll_lines;
    g_base_font_size = cfg.font_size;
    g_needs_redraw = false;
    g_gpu_renderer_snapshot_dirty = false;
    g_gpu_renderer_reconfigure_requested = false;
    g_render_serial = 0;

    if (debugStartupEnabled()) {
        std.debug.print("mollusk: PTY forked, {}x{} ({d:.1}ms)\n", .{ grid.cols, grid.rows, startup_timer.elapsedMs() });
    }

    // ── Phase 4: renderer startup + SHM first frame + event loop ──
    var cpu: cpu_renderer_worker.Frontend = .{};
    defer cpu.stop();
    var atlas_thread: atlas_owner.Frontend = .{};
    defer atlas_thread.stop();
    var active_render_path: RenderPath = .cpu;
    atlas_thread.start(&renderer, @ptrCast(&g_renderer_mutex)) catch |err| {
        std.debug.print("mollusk: atlas owner start failed: {}\n", .{err});
    };
    if (wl.shm) |shm| {
        cpu.start(@ptrCast(shm), &renderer, @ptrCast(&g_renderer_mutex), &atlas_thread, wl.width, wl.height) catch |err| {
            std.debug.print("mollusk: cpu renderer start failed: {}\n", .{err});
        };
    }

    // Drain early PTY output
    var have_early_output = false;
    var early_bytes: usize = 0;
    var early_buf: [4096]u8 = undefined;
    var early_fds = [_]c.struct_pollfd{.{ .fd = pty.master_fd, .events = c.POLLIN, .revents = 0 }};
    _ = c.poll(&early_fds, 1, 5);
    if (early_fds[0].revents & c.POLLIN != 0) {
        while (true) {
            const n = pty.read(&early_buf) catch break;
            if (n == 0) break;
            term.feedData(early_buf[0..n]);
            early_bytes += n;
            have_early_output = true;
        }
    }
    if (debugStartupEnabled() or debugPtyEnabled()) {
        std.debug.print("mollusk: early PTY output bytes={} have_output={}\n", .{ early_bytes, have_early_output });
    }

    if (have_early_output) {
        markRenderDirty();
        if (cpu.active) {
            renderActivePath(active_render_path, &gpu, &cpu, &atlas_thread, &wl, &term, &renderer, &cfg);
        } else {
            renderCpuFrame(&wl, &term, &renderer, &cfg, &atlas_thread);
            std.debug.print("mollusk: SHM paint ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
        }
    }
    g_gpu_renderer_snapshot_dirty = have_early_output;

    // ── Event loop (frontend Wayland + PTY, gpu renderer process) ──
    var pty_buf: [65536]u8 = undefined;
    var child_exited = false;

    main_loop: while (!wl.closed and !child_exited) {
        if (!gpu.active and gpu_allowed and wl.linux_dmabuf != null and gpu_restart.due()) {
            cpu.stop();
            atlas_thread.stop();
            spawnGpuRenderer(&gpu, &renderer, pty.master_fd, startup_timer, &gpu_restart, "restarting gpu renderer");
            atlas_thread.start(&renderer, @ptrCast(&g_renderer_mutex)) catch |err| {
                std.debug.print("mollusk: atlas owner restart failed: {}\n", .{err});
            };
            if (wl.shm) |shm| {
                cpu.start(@ptrCast(shm), &renderer, @ptrCast(&g_renderer_mutex), &atlas_thread, wl.width, wl.height) catch |err| {
                    std.debug.print("mollusk: cpu renderer restart failed: {}\n", .{err});
                };
            }
        }

        while (!wl.prepareRead()) {
            wl.dispatchPending() catch {
                std.debug.print("mollusk: wayland dispatchPending failed before poll, exiting\n", .{});
                break :main_loop;
            };
        }

        if (g_gpu_renderer_reconfigure_requested) {
            g_gpu_renderer_reconfigure_requested = false;
            if (gpu.active) {
                lockRenderer();
                gpu.requestReconfigure(&renderer) catch |err| {
                    unlockRenderer();
                    std.debug.print("mollusk: gpu renderer reconfigure failed: {}\n", .{err});
                    noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
                    continue;
                };
                unlockRenderer();
            } else if (gpu_allowed and wl.linux_dmabuf != null) {
                gpu_restart.scheduleImmediate();
            }
        }

        maybeQueueGpuRendererFrame(&gpu, &term, &renderer);
        renderActivePath(active_render_path, &gpu, &cpu, &atlas_thread, &wl, &term, &renderer, &cfg);
        wl.flush();

        // Key repeat timeout — wake up in time for next repeat event
        const repeat_timeout: c_int = if (wl.pumpRepeat()) |ms| @intCast(ms) else -1;
        const restart_timeout = if (!gpu.active and gpu_allowed and wl.linux_dmabuf != null)
            gpu_restart.timeoutMs()
        else
            null;
        const poll_timeout = combineTimeout(repeat_timeout, restart_timeout);

        var pollfds = [_]c.struct_pollfd{
            .{ .fd = wl.displayFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = pty.master_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (gpu.active) gpu.control_fd else -1, .events = if (gpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (cpu.active) cpu.responseFd() else -1, .events = if (cpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (atlas_thread.active) atlas_thread.responseFd() else -1, .events = if (atlas_thread.active) c.POLLIN else 0, .revents = 0 },
        };

        const poll_rc = c.poll(&pollfds, 5, poll_timeout);
        if (poll_rc < 0) {
            wl.cancelRead();
            std.debug.print("mollusk: poll failed, exiting\n", .{});
            break;
        }

        if (pollfds[0].revents & c.POLLIN != 0) {
            wl.readEvents() catch {
                wl.cancelRead();
                std.debug.print("mollusk: wayland readEvents failed, exiting\n", .{});
                break;
            };
        } else {
            wl.cancelRead();
        }
        wl.dispatchPending() catch {
            std.debug.print("mollusk: wayland dispatchPending failed, exiting\n", .{});
            break :main_loop;
        };

        if (pollfds[2].fd >= 0 and pollfds[2].revents & c.POLLIN != 0) {
            const resp_opt = gpu_renderer_proc.readResponse(gpu.control_fd) catch null;
            if (resp_opt) |resp| {
                switch (resp) {
                    .ready => |ready| {
                        if (wl.linux_dmabuf) |linux_dmabuf| {
                            gpu.installBuffers(@ptrCast(linux_dmabuf), ready) catch |err| {
                                closeReadyFds(ready);
                                std.debug.print("mollusk: GPU dmabuf import failed: {}\n", .{err});
                                noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
                                continue;
                            };
                            gpu.ready = true;
                            gpu.render_in_flight = false;
                            g_gpu_renderer_snapshot_dirty = true;
                            gpu_restart.clear();
                            if (debugRenderersEnabled() or debugStartupEnabled()) {
                                std.debug.print("mollusk: gpu renderer ready ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                            }
                        } else {
                            closeReadyFds(ready);
                            noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
                        }
                    },
                    .simple => |simple| switch (simple.tag) {
                        .frame => {
                            if (simple.serial != g_render_serial) {
                                gpu.render_in_flight = false;
                            } else {
                                if (debugRenderersEnabled()) {
                                    std.debug.print("mollusk: gpu renderer frame ready buffer={} ({d:.1}ms)\n", .{
                                        simple.buffer_index,
                                        startup_timer.elapsedMs(),
                                    });
                                }
                                if (simple.buffer_index < gpu.buffer_count) {
                                    gpu.buffers[simple.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                                    if (!wl.frame_pending) wl.requestFrame();
                                    if (active_render_path != .gpu) {
                                        if (debugFramesEnabled()) {
                                            std.debug.print("mollusk: switching render path cpu->gpu\n", .{});
                                        }
                                        active_render_path = .gpu;
                                    }
                                    if (!gpu.first_frame_presented) {
                                        if (debugFramesEnabled() or debugRenderersEnabled() or debugStartupEnabled()) {
                                            std.debug.print("mollusk: first gpu renderer paint ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                                        }
                                        gpu.first_frame_presented = true;
                                    }
                                }
                                if (!g_gpu_renderer_snapshot_dirty) {
                                    g_needs_redraw = false;
                                    term.resetDirty();
                                }
                            }
                            gpu.render_in_flight = false;
                        },
                        .failed => {
                            std.debug.print("mollusk: gpu renderer initialization failed\n", .{});
                            noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
                        },
                        .ready => {},
                        .atlas_missing => {},
                    },
                    .atlas_missing => |missing| {
                        atlas_thread.requestMany(&missing.misses);
                        gpu.render_in_flight = false;
                        if (active_render_path == .gpu) {
                            active_render_path = .cpu;
                            g_needs_redraw = true;
                        }
                        gpu.stopChild();
                        gpu_restart.scheduleImmediate();
                    },
                }
            } else {
                noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
            }
        }

        if (pollfds[3].fd >= 0 and pollfds[3].revents & c.POLLIN != 0) {
            const resp_opt = cpu.readResponse() catch null;
            if (resp_opt) |resp| {
                switch (resp.tag) {
                    .frame => {
                        if (resp.serial == g_render_serial) {
                            if (resp.buffer_index < cpu.buffer_count and
                                active_render_path == .cpu and
                                cpu.width == wl.width and cpu.height == wl.height)
                            {
                                cpu.buffers[resp.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                                if (!wl.frame_pending) wl.requestFrame();
                            }
                            if (!g_needs_redraw) {
                                term.resetDirty();
                            }
                        }
                    },
                    .failed => {
                        g_needs_redraw = true;
                    },
                }
            }
        }

        if (pollfds[4].fd >= 0 and pollfds[4].revents & c.POLLIN != 0) {
            const resp_opt = atlas_thread.readResponse() catch null;
            if (resp_opt) |resp| {
                switch (resp.tag) {
                    .updated => {
                        if (debugRenderersEnabled() or g_renderer_debug.atlas) {
                            std.debug.print("mollusk: atlas owner applied {} codepoints pages+={}\n", .{
                                resp.requested_count,
                                resp.added_pages,
                            });
                        }
                        markRenderDirty();
                        if (gpu.active) {
                            if (active_render_path == .gpu) active_render_path = .cpu;
                            gpu.stopChild();
                            gpu_restart.scheduleImmediate();
                        }
                    },
                    .failed => {
                        std.debug.print("mollusk: atlas owner update failed for {} codepoints\n", .{resp.requested_count});
                    },
                }
            }
        }

        // After zoom/resize, draw before reading PTY so the reflowed
        // content is presented before the shell's SIGWINCH response
        // can clear the prompt line.
        maybeQueueGpuRendererFrame(&gpu, &term, &renderer);
        renderActivePath(active_render_path, &gpu, &cpu, &atlas_thread, &wl, &term, &renderer, &cfg);

        if (pollfds[1].revents & c.POLLIN != 0) {
            while (true) {
                const n = pty.read(&pty_buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => {
                        std.debug.print("mollusk: PTY read failed: {}, exiting\n", .{err});
                        child_exited = true;
                        break;
                    },
                };
                if (n == 0) {
                    std.debug.print("mollusk: PTY EOF/EIO, exiting\n", .{});
                    child_exited = true;
                    break;
                }
                if (debugPtyEnabled()) {
                    std.debug.print("mollusk: PTY read {} bytes\n", .{n});
                }
                term.feedData(pty_buf[0..n]);
                markRenderDirty();
            }
        }

        if (pty.checkChild()) |status| {
            std.debug.print("mollusk: PTY child exited status={}, exiting\n", .{status});
            child_exited = true;
        }

        maybeQueueGpuRendererFrame(&gpu, &term, &renderer);
        renderActivePath(active_render_path, &gpu, &cpu, &atlas_thread, &wl, &term, &renderer, &cfg);

        maybeQueueGpuRendererFrame(&gpu, &term, &renderer);
    }

    renderer_mod.Renderer.frame_stats.log("frame");
    if (g_renderer_debug.anyLogs()) {
        if (wl.closed) {
            std.debug.print("mollusk: compositor requested close, exiting\n", .{});
        } else if (child_exited) {
            std.debug.print("mollusk: child exit path reached, exiting\n", .{});
        }
        std.debug.print("mollusk: exiting\n", .{});
    }
}

fn keysymToGhosttyKey(keysym: u32) c_uint {
    const ks: c_int = @intCast(keysym);
    return @intCast(switch (ks) {
        xkb_syms.XKB_KEY_a...xkb_syms.XKB_KEY_z => ghostty_c.GHOSTTY_KEY_A + (ks - xkb_syms.XKB_KEY_a),
        xkb_syms.XKB_KEY_A...xkb_syms.XKB_KEY_Z => ghostty_c.GHOSTTY_KEY_A + (ks - xkb_syms.XKB_KEY_A),
        xkb_syms.XKB_KEY_0...xkb_syms.XKB_KEY_9 => ghostty_c.GHOSTTY_KEY_DIGIT_0 + (ks - xkb_syms.XKB_KEY_0),
        xkb_syms.XKB_KEY_Return => ghostty_c.GHOSTTY_KEY_ENTER,
        xkb_syms.XKB_KEY_KP_Enter => ghostty_c.GHOSTTY_KEY_NUMPAD_ENTER,
        xkb_syms.XKB_KEY_Tab => ghostty_c.GHOSTTY_KEY_TAB,
        xkb_syms.XKB_KEY_ISO_Left_Tab => ghostty_c.GHOSTTY_KEY_TAB,
        xkb_syms.XKB_KEY_BackSpace => ghostty_c.GHOSTTY_KEY_BACKSPACE,
        xkb_syms.XKB_KEY_Escape => ghostty_c.GHOSTTY_KEY_ESCAPE,
        xkb_syms.XKB_KEY_Delete => ghostty_c.GHOSTTY_KEY_DELETE,
        xkb_syms.XKB_KEY_Insert => ghostty_c.GHOSTTY_KEY_INSERT,
        xkb_syms.XKB_KEY_Home => ghostty_c.GHOSTTY_KEY_HOME,
        xkb_syms.XKB_KEY_End => ghostty_c.GHOSTTY_KEY_END,
        xkb_syms.XKB_KEY_Page_Up => ghostty_c.GHOSTTY_KEY_PAGE_UP,
        xkb_syms.XKB_KEY_Page_Down => ghostty_c.GHOSTTY_KEY_PAGE_DOWN,
        xkb_syms.XKB_KEY_Up => ghostty_c.GHOSTTY_KEY_ARROW_UP,
        xkb_syms.XKB_KEY_Down => ghostty_c.GHOSTTY_KEY_ARROW_DOWN,
        xkb_syms.XKB_KEY_Left => ghostty_c.GHOSTTY_KEY_ARROW_LEFT,
        xkb_syms.XKB_KEY_Right => ghostty_c.GHOSTTY_KEY_ARROW_RIGHT,
        xkb_syms.XKB_KEY_space => ghostty_c.GHOSTTY_KEY_SPACE,
        xkb_syms.XKB_KEY_apostrophe => ghostty_c.GHOSTTY_KEY_QUOTE,
        xkb_syms.XKB_KEY_comma => ghostty_c.GHOSTTY_KEY_COMMA,
        xkb_syms.XKB_KEY_minus => ghostty_c.GHOSTTY_KEY_MINUS,
        xkb_syms.XKB_KEY_period => ghostty_c.GHOSTTY_KEY_PERIOD,
        xkb_syms.XKB_KEY_slash => ghostty_c.GHOSTTY_KEY_SLASH,
        xkb_syms.XKB_KEY_semicolon => ghostty_c.GHOSTTY_KEY_SEMICOLON,
        xkb_syms.XKB_KEY_equal => ghostty_c.GHOSTTY_KEY_EQUAL,
        xkb_syms.XKB_KEY_bracketleft => ghostty_c.GHOSTTY_KEY_BRACKET_LEFT,
        xkb_syms.XKB_KEY_bracketright => ghostty_c.GHOSTTY_KEY_BRACKET_RIGHT,
        xkb_syms.XKB_KEY_backslash => ghostty_c.GHOSTTY_KEY_BACKSLASH,
        xkb_syms.XKB_KEY_grave => ghostty_c.GHOSTTY_KEY_BACKQUOTE,
        xkb_syms.XKB_KEY_F1...xkb_syms.XKB_KEY_F12 => ghostty_c.GHOSTTY_KEY_F1 + (ks - xkb_syms.XKB_KEY_F1),
        xkb_syms.XKB_KEY_F13...xkb_syms.XKB_KEY_F25 => ghostty_c.GHOSTTY_KEY_F13 + (ks - xkb_syms.XKB_KEY_F13),
        xkb_syms.XKB_KEY_Shift_L,
        xkb_syms.XKB_KEY_Shift_R,
        xkb_syms.XKB_KEY_Control_L,
        xkb_syms.XKB_KEY_Control_R,
        xkb_syms.XKB_KEY_Alt_L,
        xkb_syms.XKB_KEY_Alt_R,
        xkb_syms.XKB_KEY_Super_L,
        xkb_syms.XKB_KEY_Super_R,
        xkb_syms.XKB_KEY_Caps_Lock,
        xkb_syms.XKB_KEY_Num_Lock,
        => 0,
        else => 0,
    });
}

fn modsToGhostty(mods: wayland_mod.Mods) c_ushort {
    var result: c_ushort = 0;
    if (mods.shift) result |= ghostty_c.GHOSTTY_MODS_SHIFT;
    if (mods.ctrl) result |= ghostty_c.GHOSTTY_MODS_CTRL;
    if (mods.alt) result |= ghostty_c.GHOSTTY_MODS_ALT;
    if (mods.super_) result |= ghostty_c.GHOSTTY_MODS_SUPER;
    return result;
}
