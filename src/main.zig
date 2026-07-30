const std = @import("std");
const config_mod = @import("config.zig");
const wayland_mod = @import("wayland.zig");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");
const gpu_pipeline = @import("render/gpu_pipeline.zig");
const headless = @import("render/headless.zig");
const cpu_pipeline = @import("render/cpu_pipeline.zig");
const render_env = @import("render/render_env.zig");
const atlas_worker = @import("render/atlas_worker.zig");
const cpu_renderer_worker = @import("render/cpu_worker.zig");
const gpu_worker = @import("render/gpu_worker.zig");
const clipboard_mod = @import("clipboard.zig");
const diagnostics = @import("diagnostics.zig");
const app_state = @import("app_state.zig");
const render_loop = @import("render_loop.zig");
const input = @import("input.zig");
const log = @import("log.zig");
const cli = @import("cli.zig");
const bell_mod = @import("bell.zig");
const pty_reader = @import("pty_reader.zig");
const term_events = @import("term_events.zig");

const c = @cImport({
    // Disable glibc fortify: its inline _chk wrappers (bits/poll2.h,
    // bits/fcntl2.h, …) don't survive Zig 0.16 translate-c under ReleaseSafe.
    // Must precede any header that pulls in <features.h> (which latches
    // __USE_FORTIFY_LEVEL).
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("poll.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

/// Liberal truthy parse for boolean-shaped env vars. Empty/absent
/// reads as false; "0"/"false"/"no"/"off" (any case) read as false;
/// anything else reads as true.
fn parseBool(v: ?[]const u8) bool {
    const s = v orelse return false;
    if (s.len == 0) return false;
    var buf: [16]u8 = undefined;
    if (s.len > buf.len) return true;
    for (s, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const lower = buf[0..s.len];
    if (std.mem.eql(u8, lower, "0")) return false;
    if (std.mem.eql(u8, lower, "false")) return false;
    if (std.mem.eql(u8, lower, "no")) return false;
    if (std.mem.eql(u8, lower, "off")) return false;
    return true;
}

const monotonicNowNs = diagnostics.monotonicNowNs;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    log.init(io);
    var state: app_state.AppState = .{};
    state.io = io;
    state.diag.markStart(io);
    const allocator = std.heap.smp_allocator;
    _ = init.gpa;

    // ── Parse CLI ──
    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    {
        var it = std.process.Args.Iterator.init(init.minimal.args);
        while (it.next()) |arg| try argv_list.append(allocator, arg);
    }
    const cli_args = cli.parse(argv_list.items) catch |err| {
        var stdout_buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
        var stderr_buf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
        switch (err) {
            error.HelpRequested => {
                cli.printUsage(&stdout.interface) catch {};
                stdout.interface.flush() catch {};
                c._exit(0);
            },
            error.VersionRequested => {
                stdout.interface.writeAll(cli.version_string ++ "\n") catch {};
                stdout.interface.flush() catch {};
                c._exit(0);
            },
            error.BadArgs => {
                stderr.interface.writeAll("scrgo: invalid arguments\n") catch {};
                cli.printUsage(&stderr.interface) catch {};
                stderr.interface.flush() catch {};
                c._exit(2);
            },
        }
    };
    if (cli_args.generate_completion) |shell| {
        var stdout_buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
        cli.writeCompletion(&stdout.interface, shell) catch {};
        stdout.interface.flush() catch {};
        c._exit(0);
    }
    cli.applyVerbosity(cli_args.verbosity);

    // Mesa hints — don't override if already set (0 = no overwrite)
    _ = c.setenv("MESA_NO_ERROR", "1", 0); // skip GL error checking
    _ = c.setenv("MESA_DISK_CACHE_SINGLE_FILE", "1", 0); // faster shader cache reads

    // Auto-detect mesa driver via sysfs (no libdrm dependency).
    {
        var driver_buf: [256]u8 = undefined;
        const driver_file = std.Io.Dir.cwd().openFile(io, "/sys/class/drm/renderD128/device/driver/module/drivers", .{}) catch null;
        if (driver_file) |f| {
            defer f.close(io);
            const n = f.readStreaming(io, &.{&driver_buf}) catch 0;
            if (n > 0) {
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

    // Build the exec argv from the -e program + everything after `--`.
    var exec_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exec_argv.deinit(allocator);
    if (cli_args.exec_program) |prog| {
        try exec_argv.append(allocator, prog);
        for (cli_args.exec_args) |a| try exec_argv.append(allocator, a);
    }

    // ── Phase 0: config + spawn GPU thread ──
    var cfg = try config_mod.load(allocator, io, cli_args.config_path);
    defer cfg.deinit(allocator);

    // Headless offscreen screenshot mode (no Wayland): render one frame of
    // SCRGO_SCREENSHOT_TEXT to the PPM at SCRGO_SCREENSHOT and exit. Used to
    // verify the render pipeline end-to-end without a display.
    if (getenv("SCRGO_SCREENSHOT")) |shot_path| {
        const text = getenv("SCRGO_SCREENSHOT_TEXT") orelse
            "scrgo headless  ABCabc 0123  ┌─┬─┐ ▚▞ █▓▒░\n" ++
                "日本語 中文 한국어  ﾊﾛｰ  αβγ Привет  😀🎉🌙\n";
        const w: u32 = if (getenv("SCRGO_SCREENSHOT_W")) |s| std.fmt.parseInt(u32, s, 10) catch 1000 else 1000;
        const h: u32 = if (getenv("SCRGO_SCREENSHOT_H")) |s| std.fmt.parseInt(u32, s, 10) catch 600 else 600;
        headless.screenshot(allocator, io, &cfg, .{ .text = text, .out_path = shot_path, .width = w, .height = h }) catch |err| {
            log.err(.main, "headless screenshot failed", .{ .err = err });
            return err;
        };
        return;
    }

    state.debug.warn_slow_budget_ms = render_env.parseWarnSlowMs(getenv("SCRGO_WARN_SLOW_MS"));
    state.diag.trace_commits = render_env.parseTraceCommits(getenv("SCRGO_TRACE"));
    // Background memory poller (SCRGO_TRACE=commits). Mirrors what the
    // bench's poller thread sees from outside the process.
    const mem_thread = state.diag.startMemPollThread();
    defer state.diag.stopMemPollThread(mem_thread);
    const runtime_flags = render_env.parseRuntimeFlags(getenv("SCRGO_FLAGS"));
    const requested_render_path: render_env.RequestedRenderPath = if (cli_args.renderer) |r| switch (r) {
        .auto => .auto,
        .cpu => .cpu,
        .gpu => .gpu,
    } else render_env.parseRequestedRenderPath(getenv("SCRGO_RENDERER"));
    log.info(.main, "startup", .{
        .reset_atlas = runtime_flags.reset_atlas_each_frame,
        .renderer = requested_render_path,
        .trace_commits = state.diag.trace_commits,
    });

    const gpu_allowed = requested_render_path != .cpu;
    if (!gpu_allowed) {
        log.info(.gpu, "disabled", .{ .reason = "SCRGO_RENDERER=cpu" });
    }

    // ── Spawn the worker threads: CPU + atlas first, GPU struct + spawn last ──
    //
    // The CPU worker renders every frame until the GPU's Vulkan context comes
    // up (~200 ms in), so it is squarely on the critical path to first paint.
    // Spawn it — and the atlas bootstrap it depends on — before ANY other
    // main-thread setup, so nothing head-of-line blocks it. In particular the
    // GPU worker's struct is large (embeds the per-slot snapshot buffers) and
    // its allocation/init used to sit ahead of this spawn, delaying it by
    // several ms for no reason. The GPU comes last on two counts: its struct
    // init is off the critical path, and starting the worker loads the Vulkan
    // driver, whose NVIDIA pthread_create hook makes every later spawn cost
    // ~6 ms — so no spawn may follow it.

    // CPU worker — the initial (and fallback) render path. Parks in
    // cond_wait until start() assigns it work.
    const cpu = try allocator.create(cpu_renderer_worker.Frontend);
    defer allocator.destroy(cpu);
    cpu.* = .{};
    defer cpu.stop();
    cpu.spawnThread(io) catch |e| {
        log.err(.cpu, "thread spawn failed", .{ .err = e });
    };
    log.info(.cpu, "thread spawned", .{});

    // Atlas worker — font+atlas bootstrap on its own thread. On the path to
    // first paint (the CPU renderer needs the atlas), so spawn it here too,
    // before the GPU driver loads.
    var atlas_thread: atlas_worker.AtlasWorker = .{};
    try atlas_thread.startWithBootstrap(io, .{
        .allocator = allocator,
        .font_path_cfg = cfg.font_path,
        .fallback_fonts = cfg.fallback_fonts,
        .font_size = cfg.font_size,
    });
    defer atlas_thread.stop();

    // GPU worker — allocate + init its large struct now that the critical-path
    // threads are already running, then start it LAST (see above). Its Vulkan
    // context init (tens of ms) still overlaps Wayland connect + PTY fork.
    const gpu = try allocator.create(gpu_worker.GpuWorker);
    defer allocator.destroy(gpu);
    gpu.* = .{};
    state.render.gpu_restart = app_state.GpuRestartBackoff.init(
        cfg.gpu_restart_initial_delay_ms,
        cfg.gpu_restart_max_delay_ms,
        cfg.gpu_restart_jitter_percent,
    );
    if (gpu_allowed) {
        gpu.start(io) catch |e| {
            log.err(.gpu, "thread start failed", .{ .err = e });
            state.render.gpu_restart.scheduleRetry();
        };
        log.info(.gpu, "thread started", .{});
    }

    // ── Phase 1: Wayland connect + 1px background ──
    var wl: wayland_mod.Wayland = undefined;
    try wl.init(800, 600, "scrgo");
    defer wl.deinit();
    defer gpu.stop(); // must run before wl.deinit() to destroy wayland buffers first

    if (wl.commitSolidBackground(cfg.background.r, cfg.background.g, cfg.background.b, 255)) {
        state.diag.recordCommit('b');
        log.info(.frame, "bg committed", .{ .path = "solid" });
    } else if (wl.shm) |shm| {
        var bg_frame = cpu_pipeline.ShmFrame.create(@ptrCast(shm), wl.width, wl.height);
        if (bg_frame.map_ptr != null) {
            bg_frame.fillBackground(cfg.background);
            bg_frame.commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
            state.diag.recordCommit('b');
            log.info(.frame, "bg committed", .{ .path = "shm" });
            bg_frame.destroy();
        }
    }

    if (requested_render_path == .gpu and wl.linux_dmabuf == null) {
        log.warn(.gpu, "linux-dmabuf unavailable, falling back to cpu", .{});
    }

    // ── Phase 2: wait for primary-font cell metrics (overlapped with the
    //    Wayland connect above). The atlas worker parses the primary font,
    //    computes metrics, and signals here — the rest of its bootstrap
    //    (fallbacks, Faces/HarfBuzz, pool, Powerline, prep) runs on in
    //    parallel with the PTY fork + terminal init below. ──
    const metrics_resp = (try atlas_thread.readResponse()) orelse {
        log.err(.atlas, "bootstrap response pipe closed before metrics_ready", .{});
        return error.BootstrapFailed;
    };
    if (metrics_resp.tag == .failed) {
        log.err(.atlas, "font bootstrap failed; cannot start without a usable font", .{
            .err = atlas_thread.bootstrap_err,
            .config_font = cfg.font_path,
        });
        if (atlas_thread.bootstrap_err) |err| return err;
        return error.BootstrapFailed;
    }
    // Metrics were computed on the atlas thread (no font work on main); the
    // metrics_ready pipe read orders that write before this read.
    const cell_metrics = atlas_thread.cell_metrics.?;
    state.metrics.font_size = cell_metrics.em;
    state.metrics.cell_width = cell_metrics.cell_width;
    state.metrics.cell_height = cell_metrics.cell_height;
    state.metrics.baseline_offset = cell_metrics.baseline_offset;
    state.metrics.descent = cell_metrics.descent;

    const grid = gpu_pipeline.computeGridSize(state.metrics.cell_width, state.metrics.cell_height, wl.width, wl.height);
    state.metrics.viewport_w = wl.width;
    state.metrics.viewport_h = wl.height;
    log.info(.main, "metrics", .{
        .cw = log.fmt("{d:.2}", .{cell_metrics.cell_width}),
        .ch = log.fmt("{d:.2}", .{cell_metrics.cell_height}),
        .base = log.fmt("{d:.2}", .{cell_metrics.baseline_offset}),
        .cols = grid.cols,
        .rows = grid.rows,
    });

    // ── Phase 3: fork PTY (while atlas init continues in background) ──
    var pty = if (exec_argv.items.len > 0)
        try pty_mod.Pty.spawnCommand(io, exec_argv.items, grid.cols, grid.rows)
    else
        try pty_mod.Pty.spawn(io, cfg.shell, grid.cols, grid.rows);
    defer pty.close();

    log.info(.pty, "forked", .{ .cols = grid.cols, .rows = grid.rows });

    var term: terminal_mod.Terminal = undefined;
    try term.init(io, grid.cols, grid.rows, cfg.max_scrollback, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // Bell handler — installed before any PTY data can flow.
    var bell = try bell_mod.Manager.init(allocator, io, cfg.bell);
    defer bell.deinit();
    bell_mod.g_manager = &bell;
    defer bell_mod.g_manager = null;
    term.on_bell = bell_mod.callback;
    state.refs.bell = &bell;

    // ── Phase 4: wait for the full atlas bootstrap, start renderers ──
    // By now the PTY fork + terminal init above have overlapped the atlas's
    // fallback/Faces/pool/Powerline/prep work.
    const atlas_resp = (try atlas_thread.readResponse()) orelse return error.BootstrapFailed;
    if (atlas_resp.tag == .failed) {
        if (atlas_thread.bootstrap_err) |err| return err;
        return error.BootstrapFailed;
    }
    defer allocator.free(atlas_thread.bootstrap_font_path);
    const atlas_ref_ptr = atlas_thread.atlas_ref;
    atlas_ref_ptr.custom_glyphs = cfg.custom_glyphs;
    state.refs.atlas_ref = atlas_ref_ptr;
    log.info(.atlas, "ready", .{});

    if (wl.shm) |shm| {
        cpu.start(io, @ptrCast(shm), atlas_ref_ptr, wl.width, wl.height) catch |e| {
            log.err(.cpu, "start failed", .{ .err = e });
        };
    }
    log.info(.cpu, "started", .{});

    // Explicit sync (opt-in via SCRGO_EXPLICIT_SYNC): the GPU worker sets up
    // DRM syncobj timelines during configure when this is set + the device is
    // capable; main imports them into the compositor once the worker reports
    // them ready. Gated on the compositor advertising the manager.
    gpu.want_explicit_sync = parseBool(getenv("SCRGO_EXPLICIT_SYNC")) and wl.syncobj_manager != null;

    if (gpu.active and gpu.context_ready) {
        gpu.setSharedState(atlas_ref_ptr);
        gpu.requestConfigure(wl.width, wl.height, state.metrics.font_size, state.metrics.cell_width, state.metrics.cell_height, state.metrics.baseline_offset, state.metrics.descent) catch |e| {
            log.err(.gpu, "initial configure failed", .{ .err = e });
            gpu.stop();
            state.render.gpu_restart.scheduleRetry();
        };
        log.info(.gpu, "configured", .{});
    } else if (gpu.active) {
        gpu.setSharedState(atlas_ref_ptr);
    }

    term.pty_fd = pty.master_fd;

    state.refs.term = &term;
    state.refs.pty = &pty;
    state.refs.wayland = &wl;

    // Bring up the clipboard manager now that the seat-bound
    // data/primary devices exist. Use a stable address (declared on
    // main's stack) so the listeners' raw data pointer survives
    // every event for the program's lifetime.
    var clipboard = clipboard_mod.Manager.init(
        allocator,
        io,
        @ptrCast(wl.display),
        if (wl.data_device) |d| @ptrCast(d) else null,
        if (wl.primary_selection_device) |d| @ptrCast(d) else null,
        if (wl.data_device_manager) |m| @ptrCast(m) else null,
        if (wl.primary_selection_manager) |m| @ptrCast(m) else null,
    );
    defer clipboard.deinit();
    clipboard.bindListeners();
    state.refs.clipboard = &clipboard;
    state.metrics.scroll_lines = cfg.scroll_lines;
    state.metrics.base_font_size = cfg.font_size;
    state.input.touch_cfg = .{
        .momentum = cfg.touch_momentum,
        .long_press_ms = cfg.touch_long_press_ms,
        .drift_px = cfg.touch_drift_px,
    };
    wl.touch_simulate = parseBool(getenv("SCRGO_TOUCH_SIMULATE"));
    state.render.needs_redraw = false;
    state.render.gpu_snapshot_dirty = false;
    state.render.gpu_reconfigure_requested = false;
    state.render.render_serial = 0;
    // Start atlas-generation tracking from the bootstrap's final value —
    // the rect/Powerline bakes advanced it from 0, and counting those as
    // a catch-up would render (and commit) an empty pre-content frame
    // whose 20 ms cold render + vsync gate then serialize ahead of the
    // first real content frame.
    state.render.last_atlas_gen = atlas_ref_ptr.loadGeneration();

    // ── Phase 5: early PTY drain + event loop ──
    state.refs.gpu = gpu;
    state.refs.cpu = cpu;
    state.refs.atlas_thread = &atlas_thread;
    state.render.active_render_path = .cpu;

    // input.bind must happen after every state.refs.* is populated and
    // before the first wayland.dispatchPending, otherwise a callback can
    // fire against a half-built state.
    input.bind(&state);
    wl.on_key = input.onKey;
    wl.on_mouse = input.onMouse;
    wl.on_touch = input.onTouch;
    wl.on_resize = input.onResize;
    wl.on_focus = input.onFocus;
    wl.on_text_commit = input.onTextCommit;

    // ── Event loop (frontend Wayland + PTY reader/gpu/cpu/atlas threads) ──
    //
    // PTY ingestion runs on a dedicated reader thread (pty_reader.zig):
    // it feeds the terminal under the terminal lock and rings the event
    // queue's doorbell. Main never reads the PTY — it wakes on the
    // doorbell, marks a redraw, and drains typed events (EOF, title,
    // future OSC callbacks).
    var events_queue = try term_events.Queue.init();
    defer events_queue.deinit();
    term.events = &events_queue;

    var reader: pty_reader.Reader = .{};
    try reader.start(&pty, &term, &events_queue);
    // Runs before the pty/term defers above (LIFO): the reader must be
    // joined while the terminal and master fd are still alive.
    defer reader.stop();

    var child_exited = false;
    // Drain phase: after the child exits we keep looping just long enough
    // to commit a final frame containing its last output. Without this a
    // command like `-e echo hi` can exit before any paint reaches the
    // compositor — including from the bench harness, which would then
    // never observe first_content_paint.
    var draining = false;
    var drain_deadline_ns: u64 = 0;
    const drain_timeout_ns: u64 = 250 * std.time.ns_per_ms;

    // True once the compositor-side explicit-sync surface + timelines are up.
    // Set in the gpu `.ready` handler; gates per-frame set_acquire/release_point.
    var explicit_sync_active = false;

    log.info(.main, "loop entry", .{});

    main_loop: while (!wl.closed) {
        if (state.diag.trace_commits and child_exited and state.diag.t_child_exited_ns == 0) {
            state.diag.t_child_exited_ns = monotonicNowNs() - state.diag.commit_trace_start_ns;
        }
        if (child_exited and !draining) {
            draining = true;
            drain_deadline_ns = monotonicNowNs() + drain_timeout_ns;
            log.info(.main, "child exited, draining final frame", .{});
        }

        if (draining) {
            // Exit as soon as a frame containing the final PTY output has
            // been committed (or no PTY output was ever produced). The
            // reader thread owns residual-byte delivery, so nothing can
            // be concluded before it reports EOF — child-exit detection
            // (waitpid) can win the race against the final bytes, and
            // "no output ever" is only knowable once the master is
            // drained. The deadline below backstops a child that exits
            // while something else keeps the pty slave open.
            const ingested = reader.sawEof() and !reader.dataDirty() and !state.render.needs_redraw;
            const painted = state.lifecycle.first_content_painted or !state.lifecycle.first_pty_data_seen;
            const renderers_idle = !gpu.render_in_flight and !cpu.render_in_flight;
            if (ingested and painted and renderers_idle) break;
            if (monotonicNowNs() >= drain_deadline_ns) {
                log.warn(.main, "drain timed out", .{});
                break;
            }
        }

        if (!gpu.active and state.render.target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null and state.render.gpu_restart.due()) {
            gpu.start(io) catch |err| {
                log.err(.gpu, "restart failed", .{ .err = err });
                state.render.gpu_restart.scheduleRetry();
                continue;
            };
            gpu.setSharedState(atlas_ref_ptr);
            log.info(.gpu, "restarting", .{});
            state.render.gpu_restart.deadline_ns = null;
        }

        while (!wl.prepareRead()) {
            wl.dispatchPending() catch {
                log.err(.wayland, "dispatchPending failed before poll, exiting", .{});
                break :main_loop;
            };
        }

        if (state.render.gpu_reconfigure_requested) {
            state.render.gpu_reconfigure_requested = false;
            if (gpu.active and gpu.context_ready) {
                gpu.requestConfigure(state.metrics.viewport_w, state.metrics.viewport_h, state.metrics.font_size, state.metrics.cell_width, state.metrics.cell_height, state.metrics.baseline_offset, state.metrics.descent) catch |err| {
                    log.err(.gpu, "reconfigure failed", .{ .err = err });
                    render_loop.noteGpuUnavailable(&state);
                    continue;
                };
            } else if (state.render.target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null) {
                state.render.gpu_restart.scheduleImmediate();
            }
        }

        render_loop.maybeScheduleScrollbarHide(&state);
        render_loop.tickBell(&state);
        render_loop.tickFirstPaintHold(&state);
        input.tickTouch();
        input.tickFling();
        render_loop.pollAtlasUpdate(&state);
        render_loop.maybeQueueGpuFrame(&state);
        render_loop.renderActivePath(&state);
        wl.flush();

        // Key repeat timeout — wake up in time for next repeat event
        const repeat_timeout: c_int = if (wl.pumpRepeat()) |ms| @intCast(ms) else -1;
        const restart_timeout = if (!gpu.active and state.render.target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null)
            state.render.gpu_restart.timeoutMs()
        else
            null;
        const scroll_timeout = render_loop.scrollbarTimeoutMs(&state);
        const bell_timeout = bell.visualTimeoutMs();
        const touch_timeout = input.touchTimeoutMs();
        const first_paint_timeout = render_loop.firstPaintHoldTimeoutMs(&state);
        // While draining after child exit, wake at least every 10 ms so
        // the drain deadline is enforced even with no fd activity (the
        // reader thread is gone once it reports EOF).
        const drain_timeout: ?c_int = if (draining) 10 else null;
        const poll_timeout = render_loop.combineTimeout(
            render_loop.combineTimeout(
                render_loop.combineTimeout(
                    render_loop.combineTimeout(
                        render_loop.combineTimeout(repeat_timeout, restart_timeout),
                        scroll_timeout,
                    ),
                    bell_timeout,
                ),
                touch_timeout,
            ),
            render_loop.combineTimeout(
                first_paint_timeout orelse -1,
                drain_timeout,
            ),
        );

        // The atlas update eventfd wakes us when the prep thread publishes
        // newly-prepped glyphs, so a partial frame gets re-rendered without
        // polling; it stays quiet (no wake, no burn) when the atlas is warm.
        const atlas_update_fd = atlas_ref_ptr.updateFd();
        var pollfds = [_]c.struct_pollfd{
            .{ .fd = wl.displayFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = events_queue.wakeFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (gpu.active) gpu.responseFd() else -1, .events = if (gpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (cpu.active) cpu.responseFd() else -1, .events = if (cpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (atlas_thread.active) atlas_thread.responseFd() else -1, .events = if (atlas_thread.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = atlas_update_fd, .events = c.POLLIN, .revents = 0 },
        };

        const poll_t0 = if (state.diag.trace_commits) monotonicNowNs() else 0;
        const poll_rc = c.poll(&pollfds, pollfds.len, poll_timeout);
        if (state.diag.trace_commits) {
            state.diag.phase_poll_ns += monotonicNowNs() - poll_t0;
            state.diag.phase_poll_calls += 1;
        }
        if (poll_rc < 0) {
            wl.cancelRead();
            log.err(.main, "poll failed, exiting", .{});
            break;
        }

        // Atlas advanced (prep published new glyphs): drain the eventfd and let
        // pollAtlasUpdate below mark a redraw so partial frames fill in.
        if (pollfds[5].revents & c.POLLIN != 0) atlas_ref_ptr.drainUpdate();

        if (pollfds[0].revents & c.POLLIN != 0) {
            wl.readEvents() catch {
                wl.cancelRead();
                log.err(.wayland, "readEvents failed, exiting", .{});
                break;
            };
        } else {
            wl.cancelRead();
        }
        wl.dispatchPending() catch {
            log.err(.wayland, "dispatchPending failed, exiting", .{});
            break :main_loop;
        };

        if (pollfds[2].fd >= 0 and pollfds[2].revents & c.POLLIN != 0) {
            const resp_opt = gpu.readResponse() catch null;
            if (resp_opt) |resp| {
                switch (resp.tag) {
                    .context_ready => {
                        log.info(.gpu, "context ready", .{});
                        if (gpu.atlas_ref == null) {
                            gpu.setSharedState(atlas_ref_ptr);
                        }
                        gpu.requestConfigure(state.metrics.viewport_w, state.metrics.viewport_h, state.metrics.font_size, state.metrics.cell_width, state.metrics.cell_height, state.metrics.baseline_offset, state.metrics.descent) catch |e| {
                            log.err(.gpu, "configure after context_ready failed", .{ .err = e });
                            render_loop.noteGpuUnavailable(&state);
                            continue;
                        };
                    },
                    .ready => {
                        if (wl.linux_dmabuf) |linux_dmabuf| {
                            gpu.installBuffers(@ptrCast(linux_dmabuf)) catch |e| {
                                log.err(.gpu, "dmabuf import failed", .{ .err = e });
                                render_loop.noteGpuUnavailable(&state);
                                continue;
                            };
                            state.render.gpu_snapshot_dirty = true;
                            state.render.gpu_restart.clear();
                            log.info(.gpu, "ready", .{});

                            // Bring up the compositor side of explicit sync once
                            // the worker has exported its timeline fds. libwayland
                            // dups the fds on import, so we close ours after.
                            if (!explicit_sync_active and gpu.explicit_sync_ready and wl.syncobj_manager != null) {
                                if (wl.setupExplicitSync(gpu.es_acquire_fd, gpu.es_release_fd)) {
                                    explicit_sync_active = true;
                                    log.info(.gpu, "explicit sync active", .{});
                                } else {
                                    log.warn(.gpu, "explicit-sync wl setup failed; sync present", .{});
                                }
                                if (gpu.es_acquire_fd >= 0) {
                                    _ = std.c.close(gpu.es_acquire_fd);
                                    gpu.es_acquire_fd = -1;
                                }
                                if (gpu.es_release_fd >= 0) {
                                    _ = std.c.close(gpu.es_release_fd);
                                    gpu.es_release_fd = -1;
                                }
                            }
                        } else {
                            render_loop.noteGpuUnavailable(&state);
                        }
                    },
                    .frame => {
                        if (state.render.target_render_path != .gpu) {
                            // Target switched away from gpu; drop this frame.
                            state.diag.recordCommit('d');
                        } else {
                            log.setFrame(.frame, resp.serial);
                            log.debug(.gpu, "frame ready", .{ .buffer = resp.buffer_index });
                            if (resp.buffer_index < gpu.frontend_buffer_count) {
                                if (render_loop.shouldHoldFirstPaint(&state, resp.had_misses != 0)) {
                                    // Withhold the miss-y first frame — the bg
                                    // surface on screen is already correct, so
                                    // we wait for the atlas to catch up (or
                                    // the hold deadline) and commit a complete
                                    // frame instead. Buffer stays free (never
                                    // committed → never busy).
                                    state.diag.recordCommit('h');
                                    log.debug(.gpu, "frame held for first paint", .{ .buffer = resp.buffer_index });
                                } else {
                                    // Commit immediately. If the compositor
                                    // still has the prior frame pending,
                                    // this commit replaces it in the
                                    // compositor's pending state — the
                                    // prior render is discarded, but
                                    // there's no latency penalty for the
                                    // newer content.
                                    // Explicit sync: set the acquire/release
                                    // timeline points on the surface before the
                                    // commit picks them up atomically.
                                    if (explicit_sync_active) wl.setSyncPoints(resp.acquire_point);
                                    gpu.buffers[resp.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                                    state.diag.recordCommit('g');
                                    state.diag.recordCommitSerial('g', resp.serial, state.render.render_serial, state.render.gpu_snapshot_dirty or state.render.needs_redraw);
                                    if (!wl.frame_pending) wl.requestFrame();
                                    state.render.committed_had_misses = resp.had_misses != 0;
                                    state.render.committed_miss_serial = resp.serial;
                                    if (state.render.active_render_path != .gpu) {
                                        log.info(.frame, "path switch", .{ .from = "cpu", .to = "gpu" });
                                        state.render.active_render_path = .gpu;
                                    }
                                    if (!gpu.first_frame_presented) {
                                        log.info(.gpu, "first paint", .{});
                                        gpu.first_frame_presented = true;
                                    }
                                    render_loop.markFirstContentPaint(&state, resp.serial);
                                }
                            }
                            // Only clear the dirty bit if the snapshot we
                            // committed reflects the latest state. If PTY
                            // produced more data while the renderer was
                            // working, we keep dirty=true and queue
                            // another render on the next loop iteration.
                            if (resp.serial == state.render.render_serial) {
                                state.render.needs_redraw = false;
                                term.lock();
                                term.resetDirty();
                                term.unlock();
                            }
                        }
                    },
                    .retry => {
                        // Glyph miss — atlas extension requested, retry on next frame
                        state.render.gpu_snapshot_dirty = true;
                    },
                    .failed => {
                        log.err(.gpu, "render failed", .{});
                        render_loop.noteGpuUnavailable(&state);
                    },
                }
            } else {
                render_loop.noteGpuUnavailable(&state);
            }
        }

        if (pollfds[3].fd >= 0 and pollfds[3].revents & c.POLLIN != 0) {
            const resp_opt = cpu.readResponse() catch null;
            if (resp_opt) |resp| {
                switch (resp.tag) {
                    .frame => {
                        const buffer_ok = resp.buffer_index < cpu.buffer_count;
                        const path_ok = state.render.active_render_path == .cpu;
                        const size_ok = cpu.width == wl.width and cpu.height == wl.height;
                        if (buffer_ok and path_ok and size_ok and
                            render_loop.shouldHoldFirstPaint(&state, resp.had_misses != 0))
                        {
                            // Withhold the miss-y first frame; the bg surface
                            // on screen is already correct. Re-render comes
                            // from the atlas eventfd or the hold deadline.
                            state.diag.recordCommit('h');
                            log.debug(.cpu, "frame held for first paint", .{ .buffer = resp.buffer_index });
                        } else if (buffer_ok and path_ok and size_ok) {
                            cpu.buffers[resp.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                            state.diag.recordCommit('c');
                            state.diag.recordCommitSerial('c', resp.serial, state.render.render_serial, state.render.gpu_snapshot_dirty or state.render.needs_redraw);
                            if (!wl.frame_pending) wl.requestFrame();
                            state.render.committed_had_misses = resp.had_misses != 0;
                            state.render.committed_miss_serial = resp.serial;
                            log.setFrame(.frame, resp.serial);
                            log.debug(.cpu, "frame committed", .{ .buffer = resp.buffer_index });
                            render_loop.markFirstContentPaint(&state, resp.serial);
                        } else {
                            const reason: []const u8 = if (!buffer_ok)
                                "bad_buffer_index"
                            else if (!path_ok)
                                "active_path_is_gpu"
                            else
                                "size_mismatch";
                            log.warn(.cpu, "frame dropped", .{
                                .buffer = resp.buffer_index,
                                .reason = reason,
                            });
                        }
                        // Only clear dirty if no new PTY data arrived
                        // while the renderer was working.
                        if (resp.serial == state.render.render_serial and !state.render.needs_redraw) {
                            term.lock();
                            term.resetDirty();
                            term.unlock();
                        }
                    },
                    .failed => {
                        state.render.needs_redraw = true;
                    },
                }
            }
        }

        if (pollfds[4].fd >= 0 and pollfds[4].revents & c.POLLIN != 0) {
            const resp_opt = atlas_thread.readResponse() catch null;
            if (resp_opt) |resp| {
                switch (resp.tag) {
                    .failed => log.err(.atlas, "bootstrap failed", .{}),
                    .metrics_ready, .bootstrap_ready => {},
                }
            }
        }

        if (pollfds[1].revents & c.POLLIN != 0) {
            // The reader thread rang the doorbell: PTY data was fed
            // and/or typed events are queued. One redraw per wake,
            // however many chunks the reader fed meanwhile.
            events_queue.drainWake();
            if (reader.takeDataDirty()) {
                render_loop.notePtyData(&state);
            }
            while (events_queue.pop()) |ev| switch (ev) {
                .pty_eof => {
                    if (!child_exited) {
                        log.info(.pty, "eof, exiting", .{});
                        child_exited = true;
                    }
                },
                .title_changed => {
                    // Main-thread side of the OSC title callback. Re-read
                    // under the terminal lock (coalesces bursts); wire to
                    // xdg_toplevel_set_title when title support lands.
                    term.lock();
                    defer term.unlock();
                    log.debug(.main, "title changed", .{ .title = term.getTitle() });
                },
            };
        }

        if (!child_exited) {
            if (pty.checkChild()) |status| {
                log.info(.pty, "child exited, exiting", .{ .status = status });
                child_exited = true;
                if (state.diag.trace_commits and state.diag.t_child_exited_ns == 0) {
                    state.diag.t_child_exited_ns = monotonicNowNs() - state.diag.commit_trace_start_ns;
                }
            }
        }

        render_loop.pollAtlasUpdate(&state);
        render_loop.maybeQueueGpuFrame(&state);
        render_loop.renderActivePath(&state);
    }

    if (state.diag.trace_commits) {
        state.diag.t_main_loop_exit_ns = monotonicNowNs() - state.diag.commit_trace_start_ns;
        // PTY ingestion phases now accumulate on the reader thread; fold
        // them into the diag report before dumping.
        state.diag.phase_pty_read_ns = reader.read_ns.load(.acquire);
        state.diag.phase_feed_data_ns = reader.feed_ns.load(.acquire);
        state.diag.phase_bytes_read = reader.bytes_read.load(.acquire);
        state.diag.phase_feed_calls = reader.read_calls.load(.acquire);
        const first_pty = reader.first_data_ns.load(.acquire);
        if (state.diag.t_first_pty_ns == 0 and first_pty > state.diag.commit_trace_start_ns) {
            state.diag.t_first_pty_ns = first_pty - state.diag.commit_trace_start_ns;
        }
    }
    log.info(.main, "loop exit", .{});
    state.diag.dumpExitReport(io, .{
        .wl_closed = wl.closed,
        .child_exited = child_exited,
        .render_serial = state.render.render_serial,
        .pipeline_dirty = state.render.gpu_snapshot_dirty or state.render.needs_redraw,
    });

    // Skip the defer chain (cpu/atlas/gpu thread joins, wl_display_disconnect,
    // buffer/surface destroys, allocator frees). Wayland is designed so the
    // compositor treats socket close identically to a clean disconnect — it
    // tears down our resources either way. Threads and memory are reaped by
    // the kernel. Saves ~2 ms of teardown on the critical path.
    c._exit(0);
}
