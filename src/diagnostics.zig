const std = @import("std");
const render_env = @import("render_env.zig");
const wayland_mod = @import("wayland.zig");
const renderer_mod = @import("renderer.zig");
const shm_render = @import("shm_render.zig");
const gpu_renderer = @import("gpu_renderer.zig");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("time.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

pub fn monotonicNowNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

/// Measure the time between fork()/exec() and our `main()` getting
/// control — i.e. ld.so + library `.init_array` + libc init + Zig's
/// `_start`. Reads /proc/self/stat field 22 (process start time in
/// jiffies since boot) and /proc/uptime (current uptime in seconds);
/// returns the delta in ns, or null if anything failed.
pub fn premainAgeNs() ?u64 {
    var stat_buf: [4096]u8 = undefined;
    const stat_fd = c.open("/proc/self/stat", c.O_RDONLY);
    if (stat_fd < 0) return null;
    const stat_n = c.read(stat_fd, &stat_buf, stat_buf.len - 1);
    _ = c.close(stat_fd);
    if (stat_n <= 0) return null;
    stat_buf[@intCast(stat_n)] = 0;
    const stat_str = stat_buf[0..@intCast(stat_n)];

    const close_paren = std.mem.lastIndexOfScalar(u8, stat_str, ')') orelse return null;
    var it = std.mem.tokenizeAny(u8, stat_str[close_paren + 1 ..], " \t\n");
    var i: usize = 0;
    while (i < 19) : (i += 1) {
        if (it.next() == null) return null;
    }
    const starttime_jiffies_str = it.next() orelse return null;
    const starttime_jiffies = std.fmt.parseInt(u64, starttime_jiffies_str, 10) catch return null;

    var uptime_buf: [128]u8 = undefined;
    const uptime_fd = c.open("/proc/uptime", c.O_RDONLY);
    if (uptime_fd < 0) return null;
    const uptime_n = c.read(uptime_fd, &uptime_buf, uptime_buf.len - 1);
    _ = c.close(uptime_fd);
    if (uptime_n <= 0) return null;
    uptime_buf[@intCast(uptime_n)] = 0;
    const uptime_str = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&uptime_buf)), 0);
    const space = std.mem.indexOfScalar(u8, uptime_str, ' ') orelse uptime_str.len;
    const uptime_secs = std.fmt.parseFloat(f64, uptime_str[0..space]) catch return null;

    const clk_tck: f64 = @floatFromInt(c.sysconf(c._SC_CLK_TCK));
    if (clk_tck <= 0) return null;
    const starttime_secs = @as(f64, @floatFromInt(starttime_jiffies)) / clk_tck;
    const age_secs = uptime_secs - starttime_secs;
    if (age_secs < 0) return null;
    return @intFromFloat(age_secs * @as(f64, std.time.ns_per_s));
}

pub fn readProcStatus(key: []const u8) u64 {
    const fd = c.open("/proc/self/status", c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var buf: [16384]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var tok = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        const val_s = tok.next() orelse return 0;
        return std.fmt.parseInt(u64, val_s, 10) catch 0;
    }
    return 0;
}

/// Commit timing trace. Enabled via `SCRGO_LOG=commits`. Records the
/// monotonic millis (relative to startup_timer) of every surface commit
/// plus the render path used; dumped at exit so we can see how commits
/// cluster across a run.
pub const CommitTrace = struct {
    t_ms: f32,
    path: u8, // 'g' = gpu, 'c' = cpu, 'b' = bootstrap bg, 'd' = discarded
};

pub const ExitContext = struct {
    wl_closed: bool,
    child_exited: bool,
    render_serial: u32,
    /// gpu_snapshot_dirty or needs_redraw at exit.
    pipeline_dirty: bool,
};

pub const Diagnostics = struct {
    debug: render_env.RendererDebug = .{},

    // Commit trace
    commit_trace: [4096]CommitTrace = undefined,
    commit_trace_len: usize = 0,

    // Lifecycle milestones (ns since commit_trace_start_ns, except
    // t_premain_ns which is wall-clock from fork to main entry).
    commit_trace_start_ns: u64 = 0,
    t_premain_ns: u64 = 0,
    t_first_pty_ns: u64 = 0,
    t_child_exited_ns: u64 = 0,
    t_main_loop_exit_ns: u64 = 0,
    t_before_exit_ns: u64 = 0,

    // Phase timing accumulators. Populated when debug.commits is on.
    phase_pty_read_ns: u64 = 0,
    phase_feed_data_ns: u64 = 0,
    phase_bytes_read: u64 = 0,
    phase_feed_calls: u64 = 0,
    phase_poll_ns: u64 = 0,
    phase_poll_calls: u64 = 0,

    // Self-sampled memory peaks. Updated by a background thread that
    // polls /proc/self/status at ~5ms intervals while the process is
    // alive, then dumped at exit.
    peak_vmrss_kib: u64 = 0,
    peak_rss_anon_kib: u64 = 0,
    mem_poll_stop: std.atomic.Value(bool) = .init(false),

    // Stale-frame stats. Per-commit we log whether the snapshot we just
    // committed was already behind the latest markRenderDirty serial; at
    // exit we log whether the *final* committed frame was caught up.
    last_commit_serial: u32 = 0,
    last_commit_latest_at_commit: u32 = 0,
    last_commit_ns: u64 = 0,
    total_stale_commits: u64 = 0,
    total_throttled_skips: u64 = 0,

    /// Stamp start-of-process timestamps. Call once near the top of main.
    pub fn markStart(self: *Diagnostics) void {
        self.commit_trace_start_ns = monotonicNowNs();
        if (premainAgeNs()) |age| self.t_premain_ns = age;
    }

    pub fn elapsedMs(self: *const Diagnostics) f64 {
        return @as(f64, @floatFromInt(monotonicNowNs() - self.commit_trace_start_ns)) / @as(f64, std.time.ns_per_ms);
    }

    pub fn recordCommit(self: *Diagnostics, path_tag: u8) void {
        if (!self.debug.commits) return;
        if (self.commit_trace_len >= self.commit_trace.len) return;
        const dt: f32 = @floatFromInt(monotonicNowNs() - self.commit_trace_start_ns);
        self.commit_trace[self.commit_trace_len] = .{
            .t_ms = dt / @as(f32, std.time.ns_per_ms),
            .path = path_tag,
        };
        self.commit_trace_len += 1;
    }

    pub fn recordCommitSerial(
        self: *Diagnostics,
        path: u8,
        committed_serial: u32,
        latest_serial: u32,
        dirty: bool,
    ) void {
        if (!self.debug.frames) return;
        const stale = committed_serial != latest_serial;
        if (stale) self.total_stale_commits += 1;
        self.last_commit_serial = committed_serial;
        self.last_commit_latest_at_commit = latest_serial;
        self.last_commit_ns = monotonicNowNs();
        const tag: []const u8 = switch (path) {
            'g' => "gpu",
            'c' => "cpu",
            else => "?",
        };
        if (stale) {
            std.debug.print("scrgo: {s} commit serial={} latest={} STALE (gap={}, dirty={}) ({d:.1}ms)\n", .{
                tag,
                committed_serial,
                latest_serial,
                latest_serial - committed_serial,
                dirty,
                self.elapsedMs(),
            });
        } else {
            std.debug.print("scrgo: {s} commit serial={} latest={} caught-up ({d:.1}ms)\n", .{
                tag,
                committed_serial,
                latest_serial,
                self.elapsedMs(),
            });
        }
    }

    pub fn startMemPollThread(self: *Diagnostics) ?std.Thread {
        if (!self.debug.commits) return null;
        return std.Thread.spawn(.{}, memPollLoop, .{self}) catch null;
    }

    pub fn stopMemPollThread(self: *Diagnostics, t: ?std.Thread) void {
        self.mem_poll_stop.store(true, .release);
        if (t) |th| th.join();
    }

    pub fn dumpExitReport(self: *Diagnostics, ctx: ExitContext) void {
        const ms_f: f64 = @floatFromInt(@as(u64, std.time.ns_per_ms));

        // Stale-last-frame diagnostic. If the final committed frame's
        // serial is behind the latest dirty-serial, the user's last
        // visible frame doesn't reflect the last PTY data we received.
        if (self.debug.frames and self.last_commit_serial != 0) {
            const verdict: []const u8 = if (self.last_commit_serial == ctx.render_serial and !ctx.pipeline_dirty)
                "caught-up"
            else
                "STALE";
            std.debug.print(
                "scrgo: final commit serial={} latest={} dirty={} → {s}  (stale commits={}, throttle skips={})\n",
                .{
                    self.last_commit_serial,
                    ctx.render_serial,
                    ctx.pipeline_dirty,
                    verdict,
                    self.total_stale_commits,
                    self.total_throttled_skips,
                },
            );
            std.debug.print(
                "scrgo: wayland  requestFrame={} (skipped={}, commits={})  frameDone={}  max_dt={d:.1}ms\n",
                .{
                    wayland_mod.Wayland.request_frame_count,
                    wayland_mod.Wayland.request_frame_skipped,
                    wayland_mod.Wayland.request_frame_commit_count,
                    wayland_mod.Wayland.frame_done_count,
                    @as(f64, @floatFromInt(wayland_mod.Wayland.last_frame_done_dt_max_ns)) / ms_f,
                },
            );
        }

        renderer_mod.Renderer.frame_stats.log("frame");

        if (self.debug.commits) {
            std.debug.print(
                "scrgo: phases  poll={d:.1}ms({})  pty_read={d:.1}ms  feed_data={d:.1}ms  prepare={d:.1}ms  worker_cells={d:.1}ms  bytes={}  feed_calls={}  snapshots={}\n",
                .{
                    @as(f64, @floatFromInt(self.phase_poll_ns)) / ms_f,
                    self.phase_poll_calls,
                    @as(f64, @floatFromInt(self.phase_pty_read_ns)) / ms_f,
                    @as(f64, @floatFromInt(self.phase_feed_data_ns)) / ms_f,
                    @as(f64, @floatFromInt(gpu_renderer.snapshotPhaseAccumNs)) / ms_f,
                    @as(f64, @floatFromInt(gpu_renderer.captureCellsAccumNs)) / ms_f,
                    self.phase_bytes_read,
                    self.phase_feed_calls,
                    gpu_renderer.snapshotPhaseCount,
                },
            );
            std.debug.print(
                "scrgo: gpu sched  worker_wait={d:.1}ms({})  buf_starvation={d:.1}ms({})\n",
                .{
                    @as(f64, @floatFromInt(gpu_renderer.workerWaitAccumNs)) / ms_f,
                    gpu_renderer.workerWaitCount,
                    @as(f64, @floatFromInt(gpu_renderer.bufferStarvationAccumNs)) / ms_f,
                    gpu_renderer.bufferStarvationCount,
                },
            );
            std.debug.print(
                "scrgo: memory  peak_rss={d}MiB  peak_anon={d}MiB  final_rss={d}MiB  final_anon={d}MiB\n",
                .{
                    self.peak_vmrss_kib / 1024,
                    self.peak_rss_anon_kib / 1024,
                    readProcStatus("VmRSS:") / 1024,
                    readProcStatus("RssAnon:") / 1024,
                },
            );
            if (renderer_mod.Renderer.phase_frame_count > 0) {
                std.debug.print(
                    "scrgo: gpu pipeline  frames={}  row_build={d:.1}ms  picture={d:.1}ms  upload={d:.1}ms  drawlist={d:.1}ms  draw={d:.1}ms\n",
                    .{
                        renderer_mod.Renderer.phase_frame_count,
                        @as(f64, @floatFromInt(renderer_mod.Renderer.phase_row_build_ns)) / ms_f,
                        @as(f64, @floatFromInt(renderer_mod.Renderer.phase_picture_ns)) / ms_f,
                        @as(f64, @floatFromInt(renderer_mod.Renderer.phase_upload_ns)) / ms_f,
                        @as(f64, @floatFromInt(renderer_mod.Renderer.phase_drawlist_ns)) / ms_f,
                        @as(f64, @floatFromInt(renderer_mod.Renderer.phase_draw_ns)) / ms_f,
                    },
                );
            }
            if (shm_render.phase_frame_count > 0) {
                std.debug.print(
                    "scrgo: cpu pipeline  frames={}  row_build={d:.1}ms  picture={d:.1}ms  upload={d:.1}ms  drawlist={d:.1}ms  draw={d:.1}ms\n",
                    .{
                        shm_render.phase_frame_count,
                        @as(f64, @floatFromInt(shm_render.phase_row_build_ns)) / ms_f,
                        @as(f64, @floatFromInt(shm_render.phase_picture_ns)) / ms_f,
                        @as(f64, @floatFromInt(shm_render.phase_upload_ns)) / ms_f,
                        @as(f64, @floatFromInt(shm_render.phase_drawlist_ns)) / ms_f,
                        @as(f64, @floatFromInt(shm_render.phase_draw_ns)) / ms_f,
                    },
                );
            }
        }

        if (self.debug.commits and self.commit_trace_len > 0) {
            std.debug.print("scrgo: commit trace ({} commits):\n", .{self.commit_trace_len});
            var prev_ms: f32 = 0;
            for (self.commit_trace[0..self.commit_trace_len], 0..) |entry, i| {
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

        if (self.debug.anyLogs()) {
            if (ctx.wl_closed) {
                std.debug.print("scrgo: compositor requested close, exiting\n", .{});
            } else if (ctx.child_exited) {
                std.debug.print("scrgo: child exit path reached, exiting\n", .{});
            }
            std.debug.print("scrgo: exiting\n", .{});
        }

        if (self.debug.commits) {
            self.t_before_exit_ns = monotonicNowNs() - self.commit_trace_start_ns;
            const last_commit_ms: f32 = if (self.commit_trace_len > 0)
                self.commit_trace[self.commit_trace_len - 1].t_ms
            else
                0;
            std.debug.print(
                "scrgo: timeline  pre_main={d:.1}ms  first_pty={d:.1}ms  last_commit={d:.1}ms  child_exited={d:.1}ms  main_loop_exit={d:.1}ms  before__exit={d:.1}ms\n",
                .{
                    @as(f64, @floatFromInt(self.t_premain_ns)) / ms_f,
                    @as(f64, @floatFromInt(self.t_first_pty_ns)) / ms_f,
                    last_commit_ms,
                    @as(f64, @floatFromInt(self.t_child_exited_ns)) / ms_f,
                    @as(f64, @floatFromInt(self.t_main_loop_exit_ns)) / ms_f,
                    @as(f64, @floatFromInt(self.t_before_exit_ns)) / ms_f,
                },
            );
        }
    }
};

fn memPollLoop(self: *Diagnostics) void {
    while (!self.mem_poll_stop.load(.acquire)) {
        const rss = readProcStatus("VmRSS:");
        const anon = readProcStatus("RssAnon:");
        if (rss > self.peak_vmrss_kib) self.peak_vmrss_kib = rss;
        if (anon > self.peak_rss_anon_kib) self.peak_rss_anon_kib = anon;
        var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 5 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
}
