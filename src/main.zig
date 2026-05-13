const std = @import("std");
const config_mod = @import("config.zig");
const wayland_mod = @import("wayland.zig");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");
const renderer_mod = @import("renderer.zig");
const shm_render = @import("shm_render.zig");
const render_env = @import("render_env.zig");
const atlas_ref_mod = @import("atlas_ref.zig");
const atlas_owner = @import("atlas_owner.zig");
const cpu_renderer_worker = @import("cpu_worker.zig");
const gpu_renderer = @import("gpu_renderer.zig");
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

// Shared state for callbacks
var g_term: *terminal_mod.Terminal = undefined;
var g_pty: *pty_mod.Pty = undefined;
var g_atlas_ref: *atlas_ref_mod.AtlasRef = undefined;
var g_font_size: f32 = 14.0;
var g_cell_width: f32 = 0;
var g_cell_height: f32 = 0;
var g_viewport_w: u32 = 0;
var g_viewport_h: u32 = 0;

var g_scroll_lines: u32 = 3;
var g_needs_redraw: bool = false;
var g_gpu_snapshot_dirty: bool = false;
var g_gpu_reconfigure_requested: bool = false;
var g_render_serial: u32 = 0;

// Drain-phase tracking. After the PTY child exits we keep looping until a
// frame containing its final output has been committed; these two flags
// tell us when that has happened so we can exit instead of waiting on the
// 250 ms watchdog.
var g_first_pty_data_seen: bool = false;
var g_first_content_painted: bool = false;

// Commit timing trace. Enabled via `SCRGO_LOG=commits`. Records the
// monotonic millis (relative to startup_timer) of every surface commit
// plus the render path used; dumped at exit so we can see how commits
// cluster across a run.
const CommitTrace = struct {
    t_ms: f32,
    path: u8, // 'g' = gpu, 'c' = cpu, 'b' = bootstrap bg
};
var g_commit_trace: [4096]CommitTrace = undefined;
var g_commit_trace_len: usize = 0;
var g_commit_trace_start_ns: u64 = 0;

fn recordCommit(path_tag: u8) void {
    if (!g_renderer_debug.commits) return;
    if (g_commit_trace_len >= g_commit_trace.len) return;
    const now = monotonicNowNs();
    const dt: f32 = @floatFromInt(now - g_commit_trace_start_ns);
    g_commit_trace[g_commit_trace_len] = .{
        .t_ms = dt / @as(f32, std.time.ns_per_ms),
        .path = path_tag,
    };
    g_commit_trace_len += 1;
}

// Phase timing accumulators. Populated when SCRGO_LOG=commits.
var g_phase_pty_read_ns: u64 = 0;
var g_phase_feed_data_ns: u64 = 0;
var g_phase_snapshot_ns: u64 = 0;
var g_phase_bytes_read: u64 = 0;
var g_phase_snapshots: u64 = 0;
var g_phase_feed_calls: u64 = 0;
var g_phase_poll_ns: u64 = 0;
var g_phase_poll_calls: u64 = 0;

fn markFirstContentPaint() void {
    if (g_first_content_painted or !g_first_pty_data_seen) return;
    g_first_content_painted = true;
}

// Debug state (set in main, used by debug key handlers)
var g_gpu: *gpu_renderer.Frontend = undefined;
var g_cpu: *cpu_renderer_worker.Frontend = undefined;
var g_active_render_path: *RenderPath = undefined;
var g_gpu_restart: *GpuRestartBackoff = undefined;
var g_atlas_thread: *atlas_owner.Frontend = undefined;
var g_target_render_path: RenderPath = .gpu;

const RenderPath = enum {
    cpu,
    gpu,
};

var g_renderer_debug: render_env.RendererDebug = .{};

fn rendererDebugOptions() render_env.RendererDebug {
    if (getenv("SCRGO_LOG")) |value|
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
    g_gpu_snapshot_dirty = true;
}

const GpuRestartBackoff = struct {
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
    ) GpuRestartBackoff {
        return .{
            .initial_delay_ms = initial_delay_ms,
            .max_delay_ms = @max(initial_delay_ms, max_delay_ms),
            .jitter_percent = jitter_percent,
            .prng = std.Random.DefaultPrng.init(monotonicNowNs()),
        };
    }

    fn clear(self: *GpuRestartBackoff) void {
        self.deadline_ns = null;
        self.attempts = 0;
    }

    fn scheduleImmediate(self: *GpuRestartBackoff) void {
        self.deadline_ns = monotonicNowNs();
    }

    fn scheduleRetry(self: *GpuRestartBackoff) void {
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

    fn due(self: *const GpuRestartBackoff) bool {
        const deadline_ns = self.deadline_ns orelse return false;
        return monotonicNowNs() >= deadline_ns;
    }

    fn timeoutMs(self: *const GpuRestartBackoff) ?c_int {
        const deadline_ns = self.deadline_ns orelse return null;
        const now_ns = monotonicNowNs();
        if (deadline_ns <= now_ns) return 0;
        const delta_ns = deadline_ns - now_ns;
        const delta_ms = @max(@as(u64, 1), delta_ns / std.time.ns_per_ms);
        return @intCast(@min(delta_ms, @as(u64, std.math.maxInt(c_int))));
    }
};

fn debugKillActiveRenderer() void {
    if (g_active_render_path.* == .gpu and g_gpu.active) {
        noteGpuUnavailable(g_gpu, g_active_render_path, g_gpu_restart);
        std.debug.print("scrgo: debug: killed gpu renderer\n", .{});
    } else if (g_cpu.active) {
        g_cpu.stop();
        std.debug.print("scrgo: debug: killed cpu renderer\n", .{});
    }
}

fn debugSwapRenderer() void {
    if (g_target_render_path == .gpu) {
        g_target_render_path = .cpu;
        g_active_render_path.* = .cpu;
        g_needs_redraw = true;
        std.debug.print("scrgo: debug: target renderer -> cpu\n", .{});
    } else {
        g_target_render_path = .gpu;
        g_gpu_snapshot_dirty = true;
        std.debug.print("scrgo: debug: target renderer -> gpu\n", .{});
    }
}

fn debugClearAtlas() void {
    // Re-publish the current atlas with a fresh ASCII population. Since
    // ensureText returns null when nothing's missing, we force a snapshot
    // change by allocating a fresh TextAtlas init from scratch using the
    // current atlas's font config bytes.
    _ = std.heap.smp_allocator;
    markRenderDirty();
    std.debug.print("scrgo: debug: atlas clear (no-op in 0.4.x)\n", .{});
}

fn onKey(ev: wayland_mod.KeyEvent) void {
    if (ev.state == .released) return;

    // Scrgo bindings (intercepted before sending to PTY)
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
            // Debug: Ctrl+Shift+F1/F2/F3
            xkb_syms.XKB_KEY_F1 => {
                debugKillActiveRenderer();
                return;
            },
            xkb_syms.XKB_KEY_F2 => {
                debugSwapRenderer();
                return;
            },
            xkb_syms.XKB_KEY_F3 => {
                debugClearAtlas();
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
    g_font_size = @min(g_font_size + 1.0, 72.0);
    applyZoom();
}

fn zoomOut() void {
    g_font_size = @max(g_font_size - 1.0, 6.0);
    applyZoom();
}

fn zoomReset() void {
    g_font_size = g_base_font_size;
    applyZoom();
}

fn applyZoom() void {
    var atlas_lease = g_atlas_ref.acquire();
    defer atlas_lease.release();
    const cm = renderer_mod.computeCellMetrics(atlas_lease.get(), g_font_size) catch return;
    g_cell_width = cm.cell_width;
    g_cell_height = cm.cell_height;

    const grid = renderer_mod.computeGridSize(g_cell_width, g_cell_height, g_viewport_w, g_viewport_h);
    if (grid.cols > 0 and grid.rows > 0) {
        g_term.resize(grid.cols, grid.rows, @intFromFloat(g_cell_width), @intFromFloat(g_cell_height)) catch {};
        g_pty.resize(grid.cols, grid.rows, g_viewport_w, g_viewport_h);
    }

    markRenderDirty();
    g_gpu_reconfigure_requested = true;
}

fn onResize(w: u32, h: u32) void {
    const grid = renderer_mod.computeGridSize(g_cell_width, g_cell_height, w, h);
    if (grid.cols == 0 or grid.rows == 0) return;
    g_viewport_w = w;
    g_viewport_h = h;
    g_term.resize(grid.cols, grid.rows, @intFromFloat(g_cell_width), @intFromFloat(g_cell_height)) catch {};
    g_pty.resize(grid.cols, grid.rows, w, h);
    markRenderDirty();
    g_gpu_reconfigure_requested = true;
}

fn onFocus(focused: bool) void {
    _ = focused;
}

fn maybeQueueGpuRendererFrame(gpu: *gpu_renderer.Frontend, term: *terminal_mod.Terminal) void {
    if (g_target_render_path != .gpu) return;
    if (!gpu.active or !gpu.ready or gpu.render_in_flight or !g_gpu_snapshot_dirty) return;
    gpu.queueRender(term, g_render_serial) catch |err| switch (err) {
        error.NotReady, error.Busy, error.NoFreeBuffer, error.NoFreeSnapshot => return,
        else => return,
    };
    if (debugRenderersEnabled()) {
        std.debug.print("scrgo: queued gpu renderer frame serial={}\n", .{g_render_serial});
    }
    g_gpu_snapshot_dirty = false;
}

fn combineTimeout(a: c_int, b_opt: ?c_int) c_int {
    const b = b_opt orelse return a;
    if (a < 0) return b;
    return @min(a, b);
}

fn renderActivePath(
    active_path: RenderPath,
    gpu: *const gpu_renderer.Frontend,
    cpu: *cpu_renderer_worker.Frontend,
    wl: *wayland_mod.Wayland,
    term: *terminal_mod.Terminal,
) void {
    if (active_path != .cpu or !g_needs_redraw) return;
    if (g_target_render_path == .gpu and gpu.active and gpu.ready) return;
    if (cpu.active) {
        const shm = wl.shm orelse return;
        cpu.ensureBuffers(@ptrCast(shm), wl.width, wl.height) catch |err| switch (err) {
            error.Busy => return,
            else => return,
        };
        cpu.queueRender(term, g_viewport_w, g_viewport_h, g_font_size, g_cell_width, g_cell_height, g_render_serial) catch |err| switch (err) {
            error.Busy, error.NoFreeBuffer, error.NoFreeSnapshot, error.Inactive => return,
            else => return,
        };
        g_needs_redraw = false;
        if (debugFramesEnabled()) {
            std.debug.print("scrgo: queue cpu renderer frame {}x{}\n", .{ wl.width, wl.height });
        }
        return;
    }
    g_needs_redraw = false;
}

fn noteGpuUnavailable(
    gpu: *gpu_renderer.Frontend,
    active_path: *RenderPath,
    restart: *GpuRestartBackoff,
) void {
    gpu.stop();
    if (debugRenderersEnabled()) {
        std.debug.print("scrgo: gpu renderer unavailable, switching to cpu renderer and scheduling restart\n", .{});
    }
    if (active_path.* == .gpu) {
        active_path.* = .cpu;
        g_needs_redraw = true;
    }
    restart.scheduleRetry();
}

pub fn main(init: std.process.Init) !void {
    const startup_timer = perf.Timer.now();
    g_commit_trace_start_ns = monotonicNowNs();
    const allocator = std.heap.smp_allocator;
    _ = init.gpa;

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

    // ── Phase 0: config + spawn GPU thread ──
    var cfg = try config_mod.load(allocator);
    defer cfg.deinit(allocator);
    g_renderer_debug = rendererDebugOptions();
    const runtime_flags = render_env.parseRuntimeFlags(getenv("SCRGO_FLAGS"));
    const requested_render_path = render_env.parseRequestedRenderPath(getenv("SCRGO_RENDERER"));
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: debug flags startup={} renderers={} frames={} atlas={} pty={} reset_atlas={}\n", .{
            g_renderer_debug.startup,
            g_renderer_debug.renderers,
            g_renderer_debug.frames,
            g_renderer_debug.atlas,
            g_renderer_debug.pty,
            runtime_flags.reset_atlas_each_frame,
        });
        std.debug.print("scrgo: requested renderer mode={s}\n", .{@tagName(requested_render_path)});
    }

    const gpu_allowed = requested_render_path != .cpu;
    if (debugStartupEnabled() and !gpu_allowed) {
        std.debug.print("scrgo: gpu renderer disabled by SCRGO_RENDERER=cpu\n", .{});
    }

    var gpu: gpu_renderer.Frontend = .{};
    var gpu_restart = GpuRestartBackoff.init(
        cfg.gpu_restart_initial_delay_ms,
        cfg.gpu_restart_max_delay_ms,
        cfg.gpu_restart_jitter_percent,
    );

    // Spawn the CPU worker thread BEFORE anything pulls in NVIDIA EGL —
    // NVIDIA hooks pthread_create on load and every subsequent spawn costs
    // ~6 ms. The thread parks in cond_wait until start() assigns it work.
    var cpu: cpu_renderer_worker.Frontend = .{};
    defer cpu.stop();
    cpu.spawnThread() catch |err| {
        std.debug.print("scrgo: cpu renderer thread spawn failed: {}\n", .{err});
    };
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: cpu renderer thread spawned ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    // Start GPU thread early — it begins EGL init immediately, no deps needed
    if (gpu_allowed) {
        gpu.start() catch |err| {
            std.debug.print("scrgo: gpu renderer thread start failed: {}\n", .{err});
            gpu_restart.scheduleRetry();
        };
        if (debugStartupEnabled()) {
            std.debug.print("scrgo: gpu renderer thread started ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
        }
    }

    // Start atlas thread with font+atlas bootstrap — overlaps with Wayland init
    var atlas_thread: atlas_owner.Frontend = .{};
    try atlas_thread.startWithBootstrap(.{
        .allocator = allocator,
        .font_path_cfg = cfg.font_path,
        .font_size = cfg.font_size,
    });
    defer atlas_thread.stop();

    // ── Phase 1: Wayland connect + 1px background ──
    var wl: wayland_mod.Wayland = undefined;
    try wl.init(800, 600, "scrgo");
    defer wl.deinit();
    defer gpu.stop(); // must run before wl.deinit() to destroy wayland buffers first

    if (wl.commitSolidBackground(cfg.background.r, cfg.background.g, cfg.background.b, 255)) {
        recordCommit('b');
        if (debugStartupEnabled()) {
            std.debug.print("scrgo: 1px bg ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
        }
    } else if (wl.shm) |shm| {
        var bg_frame = shm_render.ShmFrame.create(@ptrCast(shm), wl.width, wl.height);
        if (bg_frame) |*frame| {
            frame.fillBackground(cfg.background);
            frame.commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
            recordCommit('b');
            if (debugStartupEnabled()) {
                std.debug.print("scrgo: SHM bg ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
            }
            frame.destroy();
        }
    }

    if (requested_render_path == .gpu and wl.linux_dmabuf == null) {
        std.debug.print("scrgo: GPU renderer requested but linux-dmabuf is unavailable; falling back to CPU\n", .{});
    }

    // ── Phase 2: wait for font (overlapped with Wayland init) ──
    const font_resp = (try atlas_thread.readResponse()) orelse return error.BootstrapFailed;
    if (font_resp.tag == .failed) {
        if (atlas_thread.bootstrap_err) |err| return err;
        return error.BootstrapFailed;
    }
    defer allocator.free(atlas_thread.bootstrap_font_path);
    const atlas_ref_ptr = atlas_thread.atlas_ref;
    g_atlas_ref = atlas_ref_ptr;
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: font ready ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    var bootstrap_atlas_lease = atlas_ref_ptr.acquire();
    defer bootstrap_atlas_lease.release();
    const cell_metrics = try renderer_mod.computeCellMetrics(bootstrap_atlas_lease.get(), cfg.font_size);
    g_font_size = cfg.font_size;
    g_cell_width = cell_metrics.cell_width;
    g_cell_height = cell_metrics.cell_height;

    const grid = renderer_mod.computeGridSize(g_cell_width, g_cell_height, wl.width, wl.height);
    g_viewport_w = wl.width;
    g_viewport_h = wl.height;

    // ── Phase 3: fork PTY (while atlas init continues in background) ──
    var pty = if (exec_argv.items.len > 0)
        try pty_mod.Pty.spawnCommand(exec_argv.items, grid.cols, grid.rows)
    else
        try pty_mod.Pty.spawn(cfg.shell, grid.cols, grid.rows);
    defer pty.close();

    if (debugStartupEnabled()) {
        std.debug.print("scrgo: PTY forked, {}x{} ({d:.1}ms)\n", .{ grid.cols, grid.rows, startup_timer.elapsedMs() });
    }

    var term: terminal_mod.Terminal = undefined;
    try term.init(grid.cols, grid.rows, cfg.max_scrollback, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // ── Phase 4: wait for atlas (ASCII rasterization), start renderers ──
    const atlas_resp = (try atlas_thread.readResponse()) orelse return error.BootstrapFailed;
    if (atlas_resp.tag == .failed) {
        if (atlas_thread.bootstrap_err) |err| return err;
        return error.BootstrapFailed;
    }
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: atlas ready ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    if (wl.shm) |shm| {
        cpu.start(@ptrCast(shm), atlas_ref_ptr, &atlas_thread, wl.width, wl.height) catch |err| {
            std.debug.print("scrgo: cpu renderer start failed: {}\n", .{err});
        };
    }
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: cpu started ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    if (gpu.active and gpu.context_ready) {
        gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
        gpu.requestConfigure(wl.width, wl.height, g_font_size, g_cell_width, g_cell_height) catch |err| {
            std.debug.print("scrgo: gpu renderer initial configure failed: {}\n", .{err});
            gpu.stop();
            gpu_restart.scheduleRetry();
        };
        if (debugStartupEnabled()) {
            std.debug.print("scrgo: gpu renderer configured ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
        }
    } else if (gpu.active) {
        gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
    }

    term.pty_fd = pty.master_fd;

    g_term = &term;
    g_pty = &pty;
    wl.on_key = onKey;
    wl.on_mouse = onMouse;
    wl.on_resize = onResize;
    wl.on_focus = onFocus;
    g_scroll_lines = cfg.scroll_lines;
    g_base_font_size = cfg.font_size;
    g_needs_redraw = false;
    g_gpu_snapshot_dirty = false;
    g_gpu_reconfigure_requested = false;
    g_render_serial = 0;

    // ── Phase 5: early PTY drain + event loop ──
    var active_render_path: RenderPath = .cpu;
    g_gpu = &gpu;
    g_cpu = &cpu;
    g_active_render_path = &active_render_path;
    g_gpu_restart = &gpu_restart;
    g_atlas_thread = &atlas_thread;

    // ── Event loop (frontend Wayland + PTY, gpu/cpu renderer threads) ──
    var pty_buf: [65536]u8 = undefined;
    var child_exited = false;
    // Drain phase: after the child exits we keep looping just long enough
    // to commit a final frame containing its last output. Without this a
    // command like `-e echo hi` can exit before any paint reaches the
    // compositor — including from the bench harness, which would then
    // never observe first_content_paint.
    var draining = false;
    var drain_deadline_ns: u64 = 0;
    const drain_timeout_ns: u64 = 250 * std.time.ns_per_ms;

    if (debugStartupEnabled()) {
        std.debug.print("scrgo: main loop entry ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    main_loop: while (!wl.closed) {
        if (child_exited and !draining) {
            // Slurp any bytes still buffered on the master before the kernel
            // closes the slave side.
            while (true) {
                const n = pty.read(&pty_buf) catch break;
                if (n == 0) break;
                term.feedData(pty_buf[0..n]);
                g_first_pty_data_seen = true;
                markRenderDirty();
            }
            draining = true;
            drain_deadline_ns = monotonicNowNs() + drain_timeout_ns;
            if (debugStartupEnabled()) {
                std.debug.print("scrgo: child exited, draining final frame ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
            }
        }

        if (draining) {
            // Exit as soon as a frame containing the final PTY output has
            // been committed (or no PTY output was ever produced). We
            // don't wait for the GPU renderer to overtake CPU — the user
            // has already seen the content.
            const painted = g_first_content_painted or !g_first_pty_data_seen;
            const renderers_idle = !gpu.render_in_flight and !cpu.render_in_flight;
            if (painted and renderers_idle) break;
            if (monotonicNowNs() >= drain_deadline_ns) {
                if (debugStartupEnabled()) {
                    std.debug.print("scrgo: drain timed out ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                }
                break;
            }
        }

        if (!gpu.active and g_target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null and gpu_restart.due()) {
            gpu.start() catch |err| {
                std.debug.print("scrgo: gpu renderer restart failed: {}\n", .{err});
                gpu_restart.scheduleRetry();
                continue;
            };
            gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
            if (debugRenderersEnabled() or debugStartupEnabled()) {
                std.debug.print("scrgo: restarting gpu renderer ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
            }
            gpu_restart.deadline_ns = null;
        }

        while (!wl.prepareRead()) {
            wl.dispatchPending() catch {
                std.debug.print("scrgo: wayland dispatchPending failed before poll, exiting\n", .{});
                break :main_loop;
            };
        }

        if (g_gpu_reconfigure_requested) {
            g_gpu_reconfigure_requested = false;
            if (gpu.active and gpu.context_ready) {
                gpu.requestConfigure(g_viewport_w, g_viewport_h, g_font_size, g_cell_width, g_cell_height) catch |err| {
                    std.debug.print("scrgo: gpu renderer reconfigure failed: {}\n", .{err});
                    noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
                    continue;
                };
            } else if (g_target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null) {
                gpu_restart.scheduleImmediate();
            }
        }

        maybeQueueGpuRendererFrame(&gpu, &term);
        renderActivePath(active_render_path, &gpu, &cpu, &wl, &term);
        wl.flush();

        // Key repeat timeout — wake up in time for next repeat event
        const repeat_timeout: c_int = if (wl.pumpRepeat()) |ms| @intCast(ms) else -1;
        const restart_timeout = if (!gpu.active and g_target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null)
            gpu_restart.timeoutMs()
        else
            null;
        const poll_timeout = combineTimeout(repeat_timeout, restart_timeout);

        var pollfds = [_]c.struct_pollfd{
            .{ .fd = wl.displayFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = pty.master_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (gpu.active) gpu.responseFd() else -1, .events = if (gpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (cpu.active) cpu.responseFd() else -1, .events = if (cpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (atlas_thread.active) atlas_thread.responseFd() else -1, .events = if (atlas_thread.active) c.POLLIN else 0, .revents = 0 },
        };

        const poll_t0 = if (g_renderer_debug.commits) monotonicNowNs() else 0;
        const poll_rc = c.poll(&pollfds, 5, poll_timeout);
        if (g_renderer_debug.commits) {
            g_phase_poll_ns += monotonicNowNs() - poll_t0;
            g_phase_poll_calls += 1;
        }
        if (poll_rc < 0) {
            wl.cancelRead();
            std.debug.print("scrgo: poll failed, exiting\n", .{});
            break;
        }

        if (pollfds[0].revents & c.POLLIN != 0) {
            wl.readEvents() catch {
                wl.cancelRead();
                std.debug.print("scrgo: wayland readEvents failed, exiting\n", .{});
                break;
            };
        } else {
            wl.cancelRead();
        }
        wl.dispatchPending() catch {
            std.debug.print("scrgo: wayland dispatchPending failed, exiting\n", .{});
            break :main_loop;
        };

        if (pollfds[2].fd >= 0 and pollfds[2].revents & c.POLLIN != 0) {
            const resp_opt = gpu.readResponse() catch null;
            if (resp_opt) |resp| {
                switch (resp.tag) {
                    .context_ready => {
                        if (debugRenderersEnabled() or debugStartupEnabled()) {
                            std.debug.print("scrgo: gpu renderer context ready ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                        }
                        if (gpu.atlas_ref == null) {
                            gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
                        }
                        gpu.requestConfigure(g_viewport_w, g_viewport_h, g_font_size, g_cell_width, g_cell_height) catch |err| {
                            std.debug.print("scrgo: gpu renderer configure after context_ready failed: {}\n", .{err});
                            noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
                            continue;
                        };
                    },
                    .ready => {
                        if (wl.linux_dmabuf) |linux_dmabuf| {
                            gpu.installBuffers(@ptrCast(linux_dmabuf)) catch |err| {
                                std.debug.print("scrgo: GPU dmabuf import failed: {}\n", .{err});
                                noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
                                continue;
                            };
                            g_gpu_snapshot_dirty = true;
                            gpu_restart.clear();
                            if (debugRenderersEnabled() or debugStartupEnabled()) {
                                std.debug.print("scrgo: gpu renderer ready ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                            }
                        } else {
                            noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
                        }
                    },
                    .frame => {
                        if (g_target_render_path != .gpu) {
                            // Target switched away from gpu; drop this frame.
                            recordCommit('d');
                        } else {
                            if (debugRenderersEnabled()) {
                                std.debug.print("scrgo: gpu renderer frame ready buffer={} ({d:.1}ms)\n", .{
                                    resp.buffer_index,
                                    startup_timer.elapsedMs(),
                                });
                            }
                            if (resp.buffer_index < gpu.frontend_buffer_count) {
                                gpu.buffers[resp.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                                recordCommit('g');
                                if (!wl.frame_pending) wl.requestFrame();
                                if (active_render_path != .gpu) {
                                    if (debugFramesEnabled()) {
                                        std.debug.print("scrgo: switching render path cpu->gpu\n", .{});
                                    }
                                    active_render_path = .gpu;
                                }
                                if (!gpu.first_frame_presented) {
                                    if (debugFramesEnabled() or debugRenderersEnabled() or debugStartupEnabled()) {
                                        std.debug.print("scrgo: first gpu renderer paint ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                                    }
                                    gpu.first_frame_presented = true;
                                }
                                markFirstContentPaint();
                            }
                            // Only clear the dirty bit if the snapshot we
                            // committed reflects the latest state. If PTY
                            // produced more data while the renderer was
                            // working, we keep dirty=true and queue
                            // another render on the next loop iteration.
                            if (resp.serial == g_render_serial) {
                                g_needs_redraw = false;
                                term.resetDirty();
                            }
                        }
                    },
                    .retry => {
                        // Glyph miss — atlas extension requested, retry on next frame
                        g_gpu_snapshot_dirty = true;
                    },
                    .failed => {
                        std.debug.print("scrgo: gpu renderer failed\n", .{});
                        noteGpuUnavailable(&gpu, &active_render_path, &gpu_restart);
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
                        if (resp.buffer_index < cpu.buffer_count and
                            active_render_path == .cpu and
                            cpu.width == wl.width and cpu.height == wl.height)
                        {
                            cpu.buffers[resp.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                            recordCommit('c');
                            if (!wl.frame_pending) wl.requestFrame();
                            markFirstContentPaint();
                        }
                        // Only clear dirty if no new PTY data arrived
                        // while the renderer was working.
                        if (resp.serial == g_render_serial and !g_needs_redraw) {
                            term.resetDirty();
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
                            std.debug.print("scrgo: atlas owner applied {} codepoints pages+={}\n", .{
                                resp.requested_count,
                                resp.added_pages,
                            });
                        }
                        markRenderDirty();
                    },
                    .failed => {
                        std.debug.print("scrgo: atlas owner update failed for {} codepoints\n", .{resp.requested_count});
                    },
                    .font_ready, .bootstrap_ready => {},
                }
            }
        }

        // After zoom/resize, draw before reading PTY so the reflowed
        // content is presented before the shell's SIGWINCH response
        // can clear the prompt line.
        maybeQueueGpuRendererFrame(&gpu, &term);
        renderActivePath(active_render_path, &gpu, &cpu, &wl, &term);

        if (pollfds[1].revents & c.POLLIN != 0) {
            // Time-bounded drain: read until kernel buffer is empty OR
            // we've burned the budget. Without the budget cap, a long
            // stream (`cat largefile`) would hold the main thread for
            // its full duration and the renderer would only see/commit
            // the final state. With the cap we yield mid-stream so the
            // user sees the output scroll by. 4 ms is roughly a
            // quarter vblank — enough headroom that a slow feedData
            // call (atlas miss, etc.) won't push past one full frame.
            const read_start_ns = monotonicNowNs();
            const read_budget_ns: u64 = 4 * std.time.ns_per_ms;
            while (true) {
                const read_t0 = if (g_renderer_debug.commits) monotonicNowNs() else 0;
                const n = pty.read(&pty_buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => {
                        if (debugStartupEnabled() or debugPtyEnabled()) {
                            std.debug.print("scrgo: PTY read failed: {}, exiting\n", .{err});
                        }
                        child_exited = true;
                        break;
                    },
                };
                if (n == 0) {
                    if (debugStartupEnabled() or debugPtyEnabled()) {
                        std.debug.print("scrgo: PTY EOF/EIO, exiting\n", .{});
                    }
                    child_exited = true;
                    break;
                }
                if (debugPtyEnabled()) {
                    std.debug.print("scrgo: PTY read {} bytes\n", .{n});
                }
                if (g_renderer_debug.commits) {
                    g_phase_pty_read_ns += monotonicNowNs() - read_t0;
                    g_phase_bytes_read += @intCast(n);
                }
                const feed_t0 = if (g_renderer_debug.commits) monotonicNowNs() else 0;
                term.feedData(pty_buf[0..n]);
                if (g_renderer_debug.commits) {
                    g_phase_feed_data_ns += monotonicNowNs() - feed_t0;
                    g_phase_feed_calls += 1;
                }
                g_first_pty_data_seen = true;
                markRenderDirty();
                if (monotonicNowNs() - read_start_ns >= read_budget_ns) break;
            }
        }

        if (!child_exited) {
            if (pty.checkChild()) |status| {
                if (debugStartupEnabled() or debugPtyEnabled()) {
                    std.debug.print("scrgo: PTY child exited status={}, exiting\n", .{status});
                }
                child_exited = true;
            }
        }

        maybeQueueGpuRendererFrame(&gpu, &term);
        renderActivePath(active_render_path, &gpu, &cpu, &wl, &term);

        maybeQueueGpuRendererFrame(&gpu, &term);
    }

    if (debugStartupEnabled()) {
        std.debug.print("scrgo: main loop exit ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }
    renderer_mod.Renderer.frame_stats.log("frame");
    if (g_renderer_debug.commits) {
        const ms = @as(f64, @floatFromInt(@as(u64, std.time.ns_per_ms)));
        std.debug.print(
            "scrgo: phases  poll={d:.1}ms({})  pty_read={d:.1}ms  feed_data={d:.1}ms  prepare={d:.1}ms  worker_cells={d:.1}ms  bytes={}  feed_calls={}  snapshots={}\n",
            .{
                @as(f64, @floatFromInt(g_phase_poll_ns)) / ms,
                g_phase_poll_calls,
                @as(f64, @floatFromInt(g_phase_pty_read_ns)) / ms,
                @as(f64, @floatFromInt(g_phase_feed_data_ns)) / ms,
                @as(f64, @floatFromInt(gpu_renderer.snapshotPhaseAccumNs)) / ms,
                @as(f64, @floatFromInt(gpu_renderer.captureCellsAccumNs)) / ms,
                g_phase_bytes_read,
                g_phase_feed_calls,
                gpu_renderer.snapshotPhaseCount,
            },
        );
    }
    if (g_renderer_debug.commits and g_commit_trace_len > 0) {
        std.debug.print("scrgo: commit trace ({} commits):\n", .{g_commit_trace_len});
        var prev_ms: f32 = 0;
        for (g_commit_trace[0..g_commit_trace_len], 0..) |entry, i| {
            const path_str: []const u8 = switch (entry.path) {
                'g' => "gpu",
                'c' => "cpu",
                'b' => "bg ",
                'd' => "dis",
                else => "?  ",
            };
            std.debug.print("  [{:>3}] {s} t={d:>7.2}ms  +{d:>6.2}ms\n", .{
                i, path_str, entry.t_ms, entry.t_ms - prev_ms,
            });
            prev_ms = entry.t_ms;
        }
    }
    if (g_renderer_debug.anyLogs()) {
        if (wl.closed) {
            std.debug.print("scrgo: compositor requested close, exiting\n", .{});
        } else if (child_exited) {
            std.debug.print("scrgo: child exit path reached, exiting\n", .{});
        }
        std.debug.print("scrgo: exiting\n", .{});
    }

    // Skip the defer chain (cpu/atlas/gpu thread joins, wl_display_disconnect,
    // buffer/surface destroys, allocator frees). Wayland is designed so the
    // compositor treats socket close identically to a clean disconnect — it
    // tears down our resources either way. Threads and memory are reaped by
    // the kernel. Saves ~2 ms of teardown on the critical path.
    c._exit(0);
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
