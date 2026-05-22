const std = @import("std");
const config_mod = @import("config.zig");
const wayland_mod = @import("wayland.zig");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");
const gpu_pipeline = @import("render/gpu_pipeline.zig");
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

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

const monotonicNowNs = diagnostics.monotonicNowNs;

pub fn main(init: std.process.Init) !void {
    log.init();
    var state: app_state.AppState = .{};
    state.diag.markStart();
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
        var stdout = cli.fdWriter(1);
        var stderr = cli.fdWriter(2);
        switch (err) {
            error.HelpRequested => {
                cli.printUsage(&stdout.writer) catch {};
                c._exit(0);
            },
            error.VersionRequested => {
                stdout.writer.writeAll(cli.version_string ++ "\n") catch {};
                c._exit(0);
            },
            error.BadArgs => {
                stderr.writer.writeAll("scrgo: invalid arguments\n") catch {};
                cli.printUsage(&stderr.writer) catch {};
                c._exit(2);
            },
        }
    };
    if (cli_args.generate_completion) |shell| {
        var stdout = cli.fdWriter(1);
        cli.writeCompletion(&stdout.writer, shell) catch {};
        c._exit(0);
    }
    cli.applyVerbosity(cli_args.verbosity);

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

    // Build the exec argv from the -e program + everything after `--`.
    var exec_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exec_argv.deinit(allocator);
    if (cli_args.exec_program) |prog| {
        try exec_argv.append(allocator, prog);
        for (cli_args.exec_args) |a| try exec_argv.append(allocator, a);
    }

    // ── Phase 0: config + spawn GPU thread ──
    var cfg = try config_mod.load(allocator, cli_args.config_path);
    defer cfg.deinit(allocator);
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

    var gpu: gpu_worker.GpuWorker = .{};
    state.render.gpu_restart = app_state.GpuRestartBackoff.init(
        cfg.gpu_restart_initial_delay_ms,
        cfg.gpu_restart_max_delay_ms,
        cfg.gpu_restart_jitter_percent,
    );

    // Spawn the CPU worker thread BEFORE anything pulls in NVIDIA EGL —
    // NVIDIA hooks pthread_create on load and every subsequent spawn costs
    // ~6 ms. The thread parks in cond_wait until start() assigns it work.
    var cpu: cpu_renderer_worker.Frontend = .{};
    defer cpu.stop();
    cpu.spawnThread() catch |e| {
        log.err(.cpu, "thread spawn failed", .{ .err = e });
    };
    log.info(.cpu, "thread spawned", .{});

    // Start GPU thread early — it begins EGL init immediately, no deps needed
    if (gpu_allowed) {
        gpu.start() catch |e| {
            log.err(.gpu, "thread start failed", .{ .err = e });
            state.render.gpu_restart.scheduleRetry();
        };
        log.info(.gpu, "thread started", .{});
    }

    // Start atlas thread with font+atlas bootstrap — overlaps with Wayland init
    var atlas_thread: atlas_worker.AtlasWorker = .{};
    try atlas_thread.startWithBootstrap(.{
        .allocator = allocator,
        .font_path_cfg = cfg.font_path,
        .fallback_fonts = cfg.fallback_fonts,
        .font_size = cfg.font_size,
    });
    defer atlas_thread.stop();

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
        if (bg_frame) |*frame| {
            frame.fillBackground(cfg.background);
            frame.commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
            state.diag.recordCommit('b');
            log.info(.frame, "bg committed", .{ .path = "shm" });
            frame.destroy();
        }
    }

    if (requested_render_path == .gpu and wl.linux_dmabuf == null) {
        log.warn(.gpu, "linux-dmabuf unavailable, falling back to cpu", .{});
    }

    // ── Phase 2: wait for font (overlapped with Wayland init) ──
    const font_resp = (try atlas_thread.readResponse()) orelse return error.BootstrapFailed;
    if (font_resp.tag == .failed) {
        if (atlas_thread.bootstrap_err) |err| return err;
        return error.BootstrapFailed;
    }
    defer allocator.free(atlas_thread.bootstrap_font_path);
    const atlas_ref_ptr = atlas_thread.atlas_ref;
    state.refs.atlas_ref = atlas_ref_ptr;
    log.info(.atlas, "font ready", .{});

    var bootstrap_atlas_lease = atlas_ref_ptr.acquire();
    defer bootstrap_atlas_lease.release();
    const cell_metrics = try gpu_pipeline.computeCellMetrics(bootstrap_atlas_lease.get(), cfg.font_size);
    state.metrics.font_size = cfg.font_size;
    state.metrics.cell_width = cell_metrics.cell_width;
    state.metrics.cell_height = cell_metrics.cell_height;

    const grid = gpu_pipeline.computeGridSize(state.metrics.cell_width, state.metrics.cell_height, wl.width, wl.height);
    state.metrics.viewport_w = wl.width;
    state.metrics.viewport_h = wl.height;

    // ── Phase 3: fork PTY (while atlas init continues in background) ──
    var pty = if (exec_argv.items.len > 0)
        try pty_mod.Pty.spawnCommand(exec_argv.items, grid.cols, grid.rows)
    else
        try pty_mod.Pty.spawn(cfg.shell, grid.cols, grid.rows);
    defer pty.close();

    log.info(.pty, "forked", .{ .cols = grid.cols, .rows = grid.rows });

    var term: terminal_mod.Terminal = undefined;
    try term.init(grid.cols, grid.rows, cfg.max_scrollback, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // Bell handler — installed before any PTY data can flow.
    var bell = try bell_mod.Manager.init(allocator, cfg.bell);
    defer bell.deinit();
    bell_mod.g_manager = &bell;
    defer bell_mod.g_manager = null;
    term.on_bell = bell_mod.callback;
    state.refs.bell = &bell;

    // ── Phase 4: wait for atlas (ASCII rasterization), start renderers ──
    const atlas_resp = (try atlas_thread.readResponse()) orelse return error.BootstrapFailed;
    if (atlas_resp.tag == .failed) {
        if (atlas_thread.bootstrap_err) |err| return err;
        return error.BootstrapFailed;
    }
    log.info(.atlas, "ready", .{});

    if (wl.shm) |shm| {
        cpu.start(@ptrCast(shm), atlas_ref_ptr, &atlas_thread, wl.width, wl.height) catch |e| {
            log.err(.cpu, "start failed", .{ .err = e });
        };
    }
    log.info(.cpu, "started", .{});

    if (gpu.active and gpu.context_ready) {
        gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
        gpu.requestConfigure(wl.width, wl.height, state.metrics.font_size, state.metrics.cell_width, state.metrics.cell_height) catch |e| {
            log.err(.gpu, "initial configure failed", .{ .err = e });
            gpu.stop();
            state.render.gpu_restart.scheduleRetry();
        };
        log.info(.gpu, "configured", .{});
    } else if (gpu.active) {
        gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
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
    state.render.needs_redraw = false;
    state.render.gpu_snapshot_dirty = false;
    state.render.gpu_reconfigure_requested = false;
    state.render.render_serial = 0;

    // ── Phase 5: early PTY drain + event loop ──
    state.refs.gpu = &gpu;
    state.refs.cpu = &cpu;
    state.refs.atlas_thread = &atlas_thread;
    state.render.active_render_path = .cpu;

    // input.bind must happen after every state.refs.* is populated and
    // before the first wayland.dispatchPending, otherwise a callback can
    // fire against a half-built state.
    input.bind(&state);
    wl.on_key = input.onKey;
    wl.on_mouse = input.onMouse;
    wl.on_resize = input.onResize;
    wl.on_focus = input.onFocus;

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

    log.info(.main, "loop entry", .{});

    main_loop: while (!wl.closed) {
        if (state.diag.trace_commits and child_exited and state.diag.t_child_exited_ns == 0) {
            state.diag.t_child_exited_ns = monotonicNowNs() - state.diag.commit_trace_start_ns;
        }
        if (child_exited and !draining) {
            // Slurp any bytes still buffered on the master before the kernel
            // closes the slave side.
            while (true) {
                const n = pty.read(&pty_buf) catch break;
                if (n == 0) break;
                term.feedData(pty_buf[0..n]);
                state.lifecycle.first_pty_data_seen = true;
                render_loop.markRenderDirty(&state);
            }
            draining = true;
            drain_deadline_ns = monotonicNowNs() + drain_timeout_ns;
            log.info(.main, "child exited, draining final frame", .{});
        }

        if (draining) {
            // Exit as soon as a frame containing the final PTY output has
            // been committed (or no PTY output was ever produced). We
            // don't wait for the GPU renderer to overtake CPU — the user
            // has already seen the content.
            const painted = state.lifecycle.first_content_painted or !state.lifecycle.first_pty_data_seen;
            const renderers_idle = !gpu.render_in_flight and !cpu.render_in_flight;
            if (painted and renderers_idle) break;
            if (monotonicNowNs() >= drain_deadline_ns) {
                log.warn(.main, "drain timed out", .{});
                break;
            }
        }

        if (!gpu.active and state.render.target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null and state.render.gpu_restart.due()) {
            gpu.start() catch |err| {
                log.err(.gpu, "restart failed", .{ .err = err });
                state.render.gpu_restart.scheduleRetry();
                continue;
            };
            gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
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
                gpu.requestConfigure(state.metrics.viewport_w, state.metrics.viewport_h, state.metrics.font_size, state.metrics.cell_width, state.metrics.cell_height) catch |err| {
                    log.err(.gpu, "reconfigure failed", .{ .err = err });
                    render_loop.noteGpuUnavailable(&state);
                    continue;
                };
            } else if (state.render.target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null) {
                state.render.gpu_restart.scheduleImmediate();
            }
        }

        render_loop.maybeScheduleScrollbarHide(&state);
        render_loop.maybeScheduleBellHide(&state);
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
        const poll_timeout = render_loop.combineTimeout(
            render_loop.combineTimeout(render_loop.combineTimeout(repeat_timeout, restart_timeout), scroll_timeout),
            bell_timeout,
        );

        var pollfds = [_]c.struct_pollfd{
            .{ .fd = wl.displayFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = pty.master_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (gpu.active) gpu.responseFd() else -1, .events = if (gpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (cpu.active) cpu.responseFd() else -1, .events = if (cpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (atlas_thread.active) atlas_thread.responseFd() else -1, .events = if (atlas_thread.active) c.POLLIN else 0, .revents = 0 },
        };

        const poll_t0 = if (state.diag.trace_commits) monotonicNowNs() else 0;
        const poll_rc = c.poll(&pollfds, 5, poll_timeout);
        if (state.diag.trace_commits) {
            state.diag.phase_poll_ns += monotonicNowNs() - poll_t0;
            state.diag.phase_poll_calls += 1;
        }
        if (poll_rc < 0) {
            wl.cancelRead();
            log.err(.main, "poll failed, exiting", .{});
            break;
        }

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
                            gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
                        }
                        gpu.requestConfigure(state.metrics.viewport_w, state.metrics.viewport_h, state.metrics.font_size, state.metrics.cell_width, state.metrics.cell_height) catch |e| {
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
                            log.info(.gpu, "frame ready", .{ .buffer = resp.buffer_index });
                            if (resp.buffer_index < gpu.frontend_buffer_count) {
                                // Commit immediately. If the compositor
                                // still has the prior frame pending,
                                // this commit replaces it in the
                                // compositor's pending state — the
                                // prior render is discarded, but
                                // there's no latency penalty for the
                                // newer content.
                                gpu.buffers[resp.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                                state.diag.recordCommit('g');
                                state.diag.recordCommitSerial('g', resp.serial, state.render.render_serial, state.render.gpu_snapshot_dirty or state.render.needs_redraw);
                                if (!wl.frame_pending) wl.requestFrame();
                                if (state.render.active_render_path != .gpu) {
                                    log.info(.frame, "path switch", .{ .from = "cpu", .to = "gpu" });
                                    state.render.active_render_path = .gpu;
                                }
                                if (!gpu.first_frame_presented) {
                                    log.info(.gpu, "first paint", .{});
                                    gpu.first_frame_presented = true;
                                }
                                render_loop.markFirstContentPaint(&state);
                            }
                            // Only clear the dirty bit if the snapshot we
                            // committed reflects the latest state. If PTY
                            // produced more data while the renderer was
                            // working, we keep dirty=true and queue
                            // another render on the next loop iteration.
                            if (resp.serial == state.render.render_serial) {
                                state.render.needs_redraw = false;
                                term.resetDirty();
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
                        if (buffer_ok and path_ok and size_ok) {
                            cpu.buffers[resp.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                            state.diag.recordCommit('c');
                            state.diag.recordCommitSerial('c', resp.serial, state.render.render_serial, state.render.gpu_snapshot_dirty or state.render.needs_redraw);
                            if (!wl.frame_pending) wl.requestFrame();
                            log.setFrame(.frame, resp.serial);
                            log.info(.cpu, "frame committed", .{ .buffer = resp.buffer_index });
                            render_loop.markFirstContentPaint(&state);
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
                            term.resetDirty();
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
                    .updated => {
                        log.info(.atlas, "applied", .{
                            .codepoints = resp.requested_count,
                            .added_pages = resp.added_pages,
                        });
                        render_loop.markRenderDirty(&state);
                    },
                    .failed => {
                        log.err(.atlas, "update failed", .{ .codepoints = resp.requested_count });
                    },
                    .font_ready, .bootstrap_ready => {},
                }
            }
        }

        // After zoom/resize, draw before reading PTY so the reflowed
        // content is presented before the shell's SIGWINCH response
        // can clear the prompt line.
        render_loop.maybeQueueGpuFrame(&state);
        render_loop.renderActivePath(&state);

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
                const read_t0 = if (state.diag.trace_commits) monotonicNowNs() else 0;
                const n = pty.read(&pty_buf) catch |e| switch (e) {
                    error.WouldBlock => break,
                    else => {
                        log.err(.pty, "read failed, exiting", .{ .err = e });
                        child_exited = true;
                        break;
                    },
                };
                if (n == 0) {
                    log.info(.pty, "eof, exiting", .{});
                    child_exited = true;
                    break;
                }
                log.info(.pty, "read", .{ .bytes = n });
                if (state.diag.trace_commits) {
                    state.diag.phase_pty_read_ns += monotonicNowNs() - read_t0;
                    state.diag.phase_bytes_read += @intCast(n);
                }
                const feed_t0 = if (state.diag.trace_commits) monotonicNowNs() else 0;
                term.feedData(pty_buf[0..n]);
                if (state.diag.trace_commits) {
                    state.diag.phase_feed_data_ns += monotonicNowNs() - feed_t0;
                    state.diag.phase_feed_calls += 1;
                }
                if (state.diag.trace_commits and state.diag.t_first_pty_ns == 0) {
                    state.diag.t_first_pty_ns = monotonicNowNs() - state.diag.commit_trace_start_ns;
                }
                state.lifecycle.first_pty_data_seen = true;
                render_loop.markRenderDirty(&state);
                if (monotonicNowNs() - read_start_ns >= read_budget_ns) break;
            }
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

        render_loop.maybeQueueGpuFrame(&state);
        render_loop.renderActivePath(&state);

        render_loop.maybeQueueGpuFrame(&state);
    }

    if (state.diag.trace_commits) {
        state.diag.t_main_loop_exit_ns = monotonicNowNs() - state.diag.commit_trace_start_ns;
    }
    log.info(.main, "loop exit", .{});
    state.diag.dumpExitReport(.{
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
