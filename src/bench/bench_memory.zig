//! Memory scenario. Spawn terminal with `sh -c "cat $PAYLOAD; sleep 0.3"`,
//! sample peak memory while the child is alive, wait for it to exit,
//! report the aggregate.
//!
//! We track two numbers per run:
//!
//!   peak_rss   - ru_maxrss from wait4 (KiB). Includes shared library
//!                pages, so GPU terminals (alacritty/kitty/wezterm/scrgo)
//!                all sit ~150 MB just from libEGL/libGL.
//!   peak_anon  - max RssAnon seen via /proc/<pid>/status (KiB). This is
//!                the heap/stack/dmabuf contribution — much more useful
//!                for "how much does this terminal actually allocate".

const std = @import("std");
const h = @import("wlr_harness");
const posix = h.posix;
const stats_mod = @import("bench_stats.zig");
const spec_mod = @import("bench_spec.zig");

const c = @cImport({
    @cInclude("sys/resource.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
});

fn sleepMs(ms: u64) void {
    var ts: c.struct_timespec = .{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = c.nanosleep(&ts, &ts);
}

pub const Options = struct {
    runs: u32 = 5,
    sh_bin: []const u8,
    script: []const u8, // e.g. "cat /tmp/bench-payload.txt; sleep 0.3"
};

pub const Sample = struct {
    /// Final (post-workload) RSS — the steady-state footprint after the
    /// terminal has ingested the payload and idled for `sleep_settle`.
    /// This is the number that actually matters for "how much memory
    /// does this terminal hold while sitting open with this scrollback."
    rss_kib: f64,
    /// Final (post-workload) anonymous RSS.
    anon_kib: f64,
    /// Peak RSS during the whole run (kernel-tracked via rusage). Includes
    /// the GPU driver's transient context-init footprint on NVIDIA. Useful
    /// for catching regressions, but not representative of steady-state.
    peak_rss_kib: f64,
    /// Peak anon RSS during the whole run.
    peak_anon_kib: f64,
};

pub const Aggregate = struct {
    n: usize = 0,
    rss: stats_mod.Stats = .{},
    anon: stats_mod.Stats = .{},
    peak_rss: stats_mod.Stats = .{},
    peak_anon: stats_mod.Stats = .{},
};

const Poller = struct {
    pid: posix.pid_t,
    stop: std.atomic.Value(bool),
    peak_anon_kib: std.atomic.Value(u64),
    /// Most recent samples, updated every poll. After the workload runs
    /// to completion and the process is about to exit, the bench reads
    /// these as the steady-state values.
    last_anon_kib: std.atomic.Value(u64),
    last_rss_kib: std.atomic.Value(u64),
    io: std.Io = undefined,

    fn pollLoop(self: *Poller) void {
        while (!self.stop.load(.acquire)) {
            // Per-iteration delay (~5 ms). We don't care about high
            // precision — we just need to catch the peak window.
            sleepMs(5);
            samplePid(self.io, self.pid, &self.peak_anon_kib, &self.last_anon_kib, &self.last_rss_kib);
        }
    }
};

fn samplePid(
    io: std.Io,
    pid: posix.pid_t,
    peak_anon: *std.atomic.Value(u64),
    last_anon: *std.atomic.Value(u64),
    last_rss: *std.atomic.Value(u64),
) void {
    var path_buf: [64]u8 = undefined;
    const status_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/status", .{pid}) catch return;
    if (readKey(io, status_path, "RssAnon:")) |kib| {
        bumpMax(peak_anon, kib);
        last_anon.store(kib, .release);
    }
    if (readKey(io, status_path, "VmRSS:")) |kib| {
        last_rss.store(kib, .release);
    }
}

fn bumpMax(slot: *std.atomic.Value(u64), v: u64) void {
    var cur = slot.load(.acquire);
    while (v > cur) {
        const swapped = slot.cmpxchgWeak(cur, v, .acq_rel, .acquire) orelse return;
        cur = swapped;
    }
}

fn readWhole(io: std.Io, path: [:0]const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.cwd.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(io, &.{buf[total..]}) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

/// Read a sysfs-style line `<key>\s+<num>\s+kB` from `/proc/<pid>/...`.
/// Returns the number in KiB, or null if the file or key wasn't found.
fn readKey(io: std.Io, path: [:0]const u8, key: []const u8) ?u64 {
    var buf: [8192]u8 = undefined;
    const data = readWhole(io, path, &buf) orelse return null;
    var line_it = std.mem.tokenizeScalar(u8, data, '\n');
    while (line_it.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trim(u8, line[key.len..], " \t");
        var tok = std.mem.tokenizeAny(u8, rest, " \t");
        const num = tok.next() orelse return null;
        return std.fmt.parseInt(u64, num, 10) catch null;
    }
    return null;
}

fn runOnce(io: std.Io, spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !Sample {
    var argv_buf: [16][]const u8 = undefined;
    const extras = [_][]const u8{ opts.sh_bin, "-c", opts.script };
    const argv = spec_mod.buildArgv(&argv_buf, bin, spec, &extras);

    const pid = try h.spawnArgv(argv);

    var poller: Poller = .{
        .pid = pid,
        .stop = .init(false),
        .peak_anon_kib = .init(0),
        .last_anon_kib = .init(0),
        .last_rss_kib = .init(0),
        .io = io,
    };
    const thread = std.Thread.spawn(.{}, Poller.pollLoop, .{&poller}) catch null;

    var status: c_int = 0;
    var ru: c.struct_rusage = std.mem.zeroes(c.struct_rusage);
    const rc = c.wait4(@intCast(pid), &status, 0, &ru);

    poller.stop.store(true, .release);
    if (thread) |t| t.join();

    if (rc < 0) return error.Wait4Failed;
    // The "final" values come from the poller's most recent sample
    // before process exit — the steady-state footprint we actually
    // care about. ru_maxrss (kernel-tracked lifetime peak) goes into
    // peak_rss_kib for the diagnostic peak column.
    return .{
        .rss_kib = @floatFromInt(poller.last_rss_kib.load(.acquire)),
        .anon_kib = @floatFromInt(poller.last_anon_kib.load(.acquire)),
        .peak_rss_kib = @floatFromInt(ru.unnamed_0.ru_maxrss),
        .peak_anon_kib = @floatFromInt(poller.peak_anon_kib.load(.acquire)),
    };
}

pub fn measureTerminal(io: std.Io, spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !Aggregate {
    const alloc = std.heap.smp_allocator;
    var rss_buf: std.ArrayList(f64) = .empty;
    defer rss_buf.deinit(alloc);
    var anon_buf: std.ArrayList(f64) = .empty;
    defer anon_buf.deinit(alloc);
    var peak_rss_buf: std.ArrayList(f64) = .empty;
    defer peak_rss_buf.deinit(alloc);
    var peak_anon_buf: std.ArrayList(f64) = .empty;
    defer peak_anon_buf.deinit(alloc);
    var dropped: usize = 0;
    var r: u32 = 0;
    while (r < opts.runs) : (r += 1) {
        const s = runOnce(io, spec, bin, opts) catch {
            dropped += 1;
            continue;
        };
        try rss_buf.append(alloc, s.rss_kib);
        try anon_buf.append(alloc, s.anon_kib);
        try peak_rss_buf.append(alloc, s.peak_rss_kib);
        try peak_anon_buf.append(alloc, s.peak_anon_kib);
    }
    return .{
        .n = rss_buf.items.len,
        .rss = stats_mod.summarize(rss_buf.items, dropped),
        .anon = stats_mod.summarize(anon_buf.items, dropped),
        .peak_rss = stats_mod.summarize(peak_rss_buf.items, dropped),
        .peak_anon = stats_mod.summarize(peak_anon_buf.items, dropped),
    };
}
