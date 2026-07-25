const std = @import("std");
const wayland_mod = @import("wayland.zig");
const gpu_pipeline = @import("render/gpu_pipeline.zig");
const cpu_pipeline = @import("render/cpu_pipeline.zig");
const gpu_worker = @import("render/gpu_worker.zig");
const row_build_mod = @import("render/row_build.zig");
const snail = @import("snail");
const log = @import("log.zig");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("time.h");
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
pub fn premainAgeNs(io: std.Io) ?u64 {
    var stat_buf: [4096]u8 = undefined;
    const stat_file = std.Io.Dir.cwd().openFile(io, "/proc/self/stat", .{}) catch return null;
    const stat_n = stat_file.readStreaming(io, &.{&stat_buf}) catch return null;
    stat_file.close(io);
    if (stat_n == 0) return null;
    const stat_str = stat_buf[0..stat_n];

    const close_paren = std.mem.lastIndexOfScalar(u8, stat_str, ')') orelse return null;
    var it = std.mem.tokenizeAny(u8, stat_str[close_paren + 1 ..], " \t\n");
    var i: usize = 0;
    while (i < 19) : (i += 1) {
        if (it.next() == null) return null;
    }
    const starttime_jiffies_str = it.next() orelse return null;
    const starttime_jiffies = std.fmt.parseInt(u64, starttime_jiffies_str, 10) catch return null;

    var uptime_buf: [128]u8 = undefined;
    const uptime_file = std.Io.Dir.cwd().openFile(io, "/proc/uptime", .{}) catch return null;
    const uptime_n = uptime_file.readStreaming(io, &.{&uptime_buf}) catch return null;
    uptime_file.close(io);
    if (uptime_n == 0) return null;
    const uptime_str = uptime_buf[0..uptime_n];
    const space = std.mem.indexOfScalar(u8, uptime_str, ' ') orelse uptime_str.len;
    const uptime_secs = std.fmt.parseFloat(f64, uptime_str[0..space]) catch return null;

    const clk_tck: f64 = @floatFromInt(c.sysconf(c._SC_CLK_TCK));
    if (clk_tck <= 0) return null;
    const starttime_secs = @as(f64, @floatFromInt(starttime_jiffies)) / clk_tck;
    const age_secs = uptime_secs - starttime_secs;
    if (age_secs < 0) return null;
    return @intFromFloat(age_secs * @as(f64, std.time.ns_per_s));
}

pub fn readProcStatus(io: std.Io, key: []const u8) u64 {
    const file = std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{}) catch return 0;
    defer file.close(io);
    var buf: [16384]u8 = undefined;
    const n = file.readStreaming(io, &.{&buf}) catch return 0;
    if (n == 0) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
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
    /// Opt-in commit/phase tracing. Gates the per-commit trace buffer,
    /// phase counters, mem-poll thread, and the exit-time summary. Set
    /// via `SCRGO_TRACE=commits`. Independent from `SCRGO_LOG` (which
    /// controls scope-based log filtering in log.zig).
    trace_commits: bool = false,

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
    io: std.Io = undefined,

    // Stale-frame stats. Per-commit we log whether the snapshot we just
    // committed was already behind the latest markRenderDirty serial; at
    // exit we log whether the *final* committed frame was caught up.
    last_commit_serial: u32 = 0,
    last_commit_latest_at_commit: u32 = 0,
    last_commit_ns: u64 = 0,
    total_stale_commits: u64 = 0,
    total_throttled_skips: u64 = 0,

    /// Stamp start-of-process timestamps. Call once near the top of main.
    pub fn markStart(self: *Diagnostics, io: std.Io) void {
        self.io = io;
        self.commit_trace_start_ns = monotonicNowNs();
        if (premainAgeNs(io)) |age| self.t_premain_ns = age;
    }

    pub fn elapsedMs(self: *const Diagnostics) f64 {
        return @as(f64, @floatFromInt(monotonicNowNs() - self.commit_trace_start_ns)) / @as(f64, std.time.ns_per_ms);
    }

    pub fn recordCommit(self: *Diagnostics, path_tag: u8) void {
        if (!self.trace_commits) return;
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
        if (!self.trace_commits) return;
        const stale = committed_serial != latest_serial;
        if (stale) self.total_stale_commits += 1;
        self.last_commit_serial = committed_serial;
        self.last_commit_latest_at_commit = latest_serial;
        self.last_commit_ns = monotonicNowNs();
        const scope: log.Scope = switch (path) {
            'g' => .gpu,
            'c' => .cpu,
            else => .frame,
        };
        log.setFrame(.frame, latest_serial);
        if (stale) {
            log.warn(scope, "commit stale", .{
                .committed = committed_serial,
                .latest = latest_serial,
                .gap = latest_serial - committed_serial,
                .dirty = dirty,
            });
        } else {
            log.info(scope, "commit caught-up", .{
                .committed = committed_serial,
                .latest = latest_serial,
            });
        }
    }

    pub fn startMemPollThread(self: *Diagnostics) ?std.Thread {
        if (!self.trace_commits) return null;
        return std.Thread.spawn(.{}, memPollLoop, .{self}) catch null;
    }

    pub fn stopMemPollThread(self: *Diagnostics, t: ?std.Thread) void {
        self.mem_poll_stop.store(true, .release);
        if (t) |th| th.join();
    }

    pub fn dumpExitReport(self: *Diagnostics, io: std.Io, ctx: ExitContext) void {
        const ms_f: f64 = @floatFromInt(@as(u64, std.time.ns_per_ms));

        // Stale-last-frame diagnostic. If the final committed frame's
        // serial is behind the latest dirty-serial, the user's last
        // visible frame doesn't reflect the last PTY data we received.
        if (self.trace_commits and self.last_commit_serial != 0) {
            const Verdict = enum { caught_up, stale };
            const verdict: Verdict = if (self.last_commit_serial == ctx.render_serial and !ctx.pipeline_dirty)
                .caught_up
            else
                .stale;
            log.info(.diag, "final commit", .{
                .committed = self.last_commit_serial,
                .latest = ctx.render_serial,
                .dirty = ctx.pipeline_dirty,
                .verdict = verdict,
                .stale_commits = self.total_stale_commits,
                .throttle_skips = self.total_throttled_skips,
            });
            log.info(.diag, "wayland summary", .{
                .request_frame = wayland_mod.Wayland.request_frame_count,
                .skipped = wayland_mod.Wayland.request_frame_skipped,
                .commits = wayland_mod.Wayland.request_frame_commit_count,
                .frame_done = wayland_mod.Wayland.frame_done_count,
                .max_dt_ms = log.fmt("{d:.1}", .{
                    @as(f64, @floatFromInt(wayland_mod.Wayland.last_frame_done_dt_max_ns)) / ms_f,
                }),
            });
        }

        gpu_pipeline.frame_stats.dump("frame");

        if (self.trace_commits) {
            log.info(.diag, "phases", .{
                .poll_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(self.phase_poll_ns)) / ms_f}),
                .poll_calls = self.phase_poll_calls,
                .pty_read_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(self.phase_pty_read_ns)) / ms_f}),
                .feed_data_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(self.phase_feed_data_ns)) / ms_f}),
                .prepare_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(gpu_worker.snapshotPhaseAccumNs)) / ms_f}),
                .worker_cells_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(gpu_worker.captureCellsAccumNs)) / ms_f}),
                .bytes = self.phase_bytes_read,
                .feed_calls = self.phase_feed_calls,
                .snapshots = gpu_worker.snapshotPhaseCount,
            });
            log.info(.diag, "gpu sched", .{
                .worker_wait_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(gpu_worker.workerWaitAccumNs)) / ms_f}),
                .worker_wait_count = gpu_worker.workerWaitCount,
                .buf_starvation_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(gpu_worker.bufferStarvationAccumNs)) / ms_f}),
                .buf_starvation_count = gpu_worker.bufferStarvationCount,
            });
            log.info(.diag, "memory", .{
                .peak_rss_mib = self.peak_vmrss_kib / 1024,
                .peak_anon_mib = self.peak_rss_anon_kib / 1024,
                .final_rss_mib = readProcStatus(io, "VmRSS:") / 1024,
                .final_anon_mib = readProcStatus(io, "RssAnon:") / 1024,
            });
            if (cpu_pipeline.phase_frame_count > 0) {
                log.info(.diag, "gpu pipeline", .{
                    .frames = cpu_pipeline.phase_frame_count,
                    .row_build_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_row_build_ns)) / ms_f}),
                    .picture_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_picture_ns)) / ms_f}),
                    .upload_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_upload_ns)) / ms_f}),
                    .drawlist_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_drawlist_ns)) / ms_f}),
                    .draw_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_draw_ns)) / ms_f}),
                });
            }
            if (cpu_pipeline.phase_frame_count > 0) {
                log.info(.diag, "cpu pipeline", .{
                    .frames = cpu_pipeline.phase_frame_count,
                    .row_build_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_row_build_ns)) / ms_f}),
                    .picture_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_picture_ns)) / ms_f}),
                    .upload_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_upload_ns)) / ms_f}),
                    .drawlist_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_drawlist_ns)) / ms_f}),
                    .draw_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cpu_pipeline.phase_draw_ns)) / ms_f}),
                });
            }
            if (row_build_mod.phase_hint_runs > 0) {
                log.info(.diag, "tt hinter", .{
                    .runs = row_build_mod.phase_hint_runs,
                    .hinted = row_build_mod.phase_hint_glyphs_hinted,
                    .fallback = row_build_mod.phase_hint_glyphs_fallback,
                    .prepare_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(row_build_mod.phase_hint_prepare_ns)) / ms_f}),
                    .append_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(row_build_mod.phase_hint_append_ns)) / ms_f}),
                });
                const r = row_build_mod.phase_hint_reject_counts;
                var any: u64 = 0;
                for (r) |v| any +%= v;
                if (any > 0) {
                    // TODO: snail 0.13 TrueTypeHintRejectReason mapping
                    log.info(.diag, "tt hinter rejects", .{
                        .invalid_face = r[0],
                        .no_tt_program = r[1],
                        .synthetic_embolden = r[2],
                        .color_glyph = r[3],
                        .grid_fit_disabled = r[4],
                        .missing_base_glyph = r[5],
                        .topology_changed = r[6],
                        .bands_not_reusable = r[7],
                        .empty_hinted_outline = r[8],
                        .exec_failed = r[9],
                    });
                }
            }
        }

        if (self.trace_commits and self.commit_trace_len > 0) {
            log.info(.diag, "commit trace", .{ .commits = self.commit_trace_len });
            const Path = enum { gpu, cpu, bg, dis, unknown };
            var prev_ms: f32 = 0;
            for (self.commit_trace[0..self.commit_trace_len], 0..) |entry, i| {
                const path: Path = switch (entry.path) {
                    'g' => .gpu,
                    'c' => .cpu,
                    'b' => .bg,
                    'd' => .dis,
                    else => .unknown,
                };
                log.cont("", .{
                    .row = i,
                    .path = path,
                    .t_ms = log.fmt("{d:.2}", .{entry.t_ms}),
                    .delta_ms = log.fmt("{d:.2}", .{entry.t_ms - prev_ms}),
                });
                prev_ms = entry.t_ms;
            }
        }

        const Reason = enum { compositor_close, child_exit, other };
        const reason: Reason = if (ctx.wl_closed) .compositor_close else if (ctx.child_exited) .child_exit else .other;
        log.info(.main, "exiting", .{ .reason = reason });

        if (self.trace_commits) {
            self.t_before_exit_ns = monotonicNowNs() - self.commit_trace_start_ns;
            const last_commit_ms: f32 = if (self.commit_trace_len > 0)
                self.commit_trace[self.commit_trace_len - 1].t_ms
            else
                0;
            log.info(.diag, "timeline", .{
                .pre_main_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(self.t_premain_ns)) / ms_f}),
                .first_pty_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(self.t_first_pty_ns)) / ms_f}),
                .last_commit_ms = log.fmt("{d:.2}", .{last_commit_ms}),
                .child_exited_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(self.t_child_exited_ns)) / ms_f}),
                .main_loop_exit_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(self.t_main_loop_exit_ns)) / ms_f}),
                .before_exit_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(self.t_before_exit_ns)) / ms_f}),
            });
        }
    }
};

fn memPollLoop(self: *Diagnostics) void {
    while (!self.mem_poll_stop.load(.acquire)) {
        const rss = readProcStatus(self.io, "VmRSS:");
        const anon = readProcStatus(self.io, "RssAnon:");
        if (rss > self.peak_vmrss_kib) self.peak_vmrss_kib = rss;
        if (anon > self.peak_rss_anon_kib) self.peak_rss_anon_kib = anon;
        var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 5 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
}
