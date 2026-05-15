//! Memory scenario. Spawn terminal with `sh -c "cat $PAYLOAD; sleep 0.3"`,
//! sample peak memory while the child is alive, wait for it to exit,
//! report the aggregate.
//!
//! We track three numbers per run:
//!
//!   peak_rss   - ru_maxrss from wait4 (KiB). Includes shared library
//!                pages, so GPU terminals (alacritty/kitty/wezterm/scrgo)
//!                all sit ~150 MB just from libEGL/libGL.
//!   peak_anon  - max RssAnon seen via /proc/<pid>/status (KiB). This is
//!                the heap/stack/dmabuf contribution — much more useful
//!                for "how much does this terminal actually allocate".
//!   peak_vram  - max VRAM seen via /proc/<pid>/fdinfo/*'s
//!                drm-memory-vram-resident counters (KiB). Supported by
//!                mesa drivers (amdgpu/intel/radv). NVIDIA's proprietary
//!                driver doesn't expose this; we report 0 in that case.

const std = @import("std");
const h = @import("wlr_harness.zig");
const posix = h.posix;
const stats_mod = @import("bench_stats.zig");
const spec_mod = @import("bench_spec.zig");

const c = @cImport({
    @cInclude("sys/resource.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("dirent.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
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
    peak_rss_kib: f64,
    peak_anon_kib: f64,
    peak_vram_kib: f64,
};

pub const Aggregate = struct {
    n: usize = 0,
    rss: stats_mod.Stats = .{},
    anon: stats_mod.Stats = .{},
    vram: stats_mod.Stats = .{},
};

const Poller = struct {
    pid: posix.pid_t,
    stop: std.atomic.Value(bool),
    peak_anon_kib: std.atomic.Value(u64),
    peak_vram_kib: std.atomic.Value(u64),

    fn pollLoop(self: *Poller) void {
        while (!self.stop.load(.acquire)) {
            // Per-iteration delay (~5 ms). We don't care about high
            // precision — we just need to catch the peak window.
            sleepMs(5);
            samplePid(self.pid, &self.peak_anon_kib, &self.peak_vram_kib);
        }
    }
};

fn samplePid(pid: posix.pid_t, peak_anon: *std.atomic.Value(u64), peak_vram: *std.atomic.Value(u64)) void {
    // /proc/<pid>/status: parse RssAnon line.
    var path_buf: [64]u8 = undefined;
    const status_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/status", .{pid}) catch return;
    if (readKey(status_path, "RssAnon:")) |kib| {
        bumpMax(peak_anon, kib);
    }

    // /proc/<pid>/fdinfo/*: sum drm-memory-vram across all DRM fds.
    var fdinfo_path_buf: [128]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&fdinfo_path_buf, "/proc/{d}/fdinfo", .{pid}) catch return;
    var vram_total: u64 = 0;
    const dir = c.opendir(dir_path.ptr);
    if (dir == null) return;
    defer _ = c.closedir(dir);
    while (true) {
        const ent = c.readdir(dir);
        if (ent == null) break;
        const name_z: [*:0]const u8 = @ptrCast(&ent.*.d_name);
        const name = std.mem.span(name_z);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var entry_path_buf: [256]u8 = undefined;
        const entry_path = std.fmt.bufPrintZ(&entry_path_buf, "/proc/{d}/fdinfo/{s}", .{ pid, name }) catch continue;
        scanVramFields(entry_path, &vram_total);
    }
    if (vram_total > 0) bumpMax(peak_vram, vram_total);
}

fn bumpMax(slot: *std.atomic.Value(u64), v: u64) void {
    var cur = slot.load(.acquire);
    while (v > cur) {
        const swapped = slot.cmpxchgWeak(cur, v, .acq_rel, .acquire) orelse return;
        cur = swapped;
    }
}

fn readWhole(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const fd = c.open(path.ptr, c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fd, buf.ptr + total, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return buf[0..total];
}

/// Read a sysfs-style line `<key>\s+<num>\s+kB` from `/proc/<pid>/...`.
/// Returns the number in KiB, or null if the file or key wasn't found.
fn readKey(path: [:0]const u8, key: []const u8) ?u64 {
    var buf: [8192]u8 = undefined;
    const data = readWhole(path, &buf) orelse return null;
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

/// Walk an fdinfo file looking for `drm-memory-vram*` or similar
/// per-DRM-fd memory accounting lines and accumulate their KiB values.
fn scanVramFields(path: [:0]const u8, total: *u64) void {
    var buf: [16384]u8 = undefined;
    const data = readWhole(path, &buf) orelse return;
    var line_it = std.mem.tokenizeScalar(u8, data, '\n');
    while (line_it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        if (std.mem.indexOf(u8, key, "drm-") == null) continue;
        if (std.mem.indexOf(u8, key, "vram") == null) continue;
        // We want resident (currently held) not total (lifetime
        // allocation), to match what RSS measures.
        if (std.mem.indexOf(u8, key, "resident") == null) continue;
        const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");
        var tok = std.mem.tokenizeAny(u8, rest, " \t");
        const num = tok.next() orelse continue;
        const v = std.fmt.parseInt(u64, num, 10) catch continue;
        total.* += v;
    }
}

fn runOnce(spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !Sample {
    var argv_buf: [16][]const u8 = undefined;
    const extras = [_][]const u8{ opts.sh_bin, "-c", opts.script };
    const argv = spec_mod.buildArgv(&argv_buf, bin, spec, &extras);

    const pid = try h.spawnArgv(argv);

    var poller: Poller = .{
        .pid = pid,
        .stop = .init(false),
        .peak_anon_kib = .init(0),
        .peak_vram_kib = .init(0),
    };
    const thread = std.Thread.spawn(.{}, Poller.pollLoop, .{&poller}) catch null;

    var status: c_int = 0;
    var ru: c.struct_rusage = std.mem.zeroes(c.struct_rusage);
    const rc = c.wait4(@intCast(pid), &status, 0, &ru);

    poller.stop.store(true, .release);
    if (thread) |t| t.join();

    if (rc < 0) return error.Wait4Failed;
    // ru_maxrss is in KiB on Linux; surfaced via the anonymous union
    // glibc wraps it in.
    return .{
        .peak_rss_kib = @floatFromInt(ru.unnamed_0.ru_maxrss),
        .peak_anon_kib = @floatFromInt(poller.peak_anon_kib.load(.acquire)),
        .peak_vram_kib = @floatFromInt(poller.peak_vram_kib.load(.acquire)),
    };
}

pub fn measureTerminal(spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !Aggregate {
    var rss_buf: std.ArrayList(f64) = .empty;
    defer rss_buf.deinit(std.heap.smp_allocator);
    var anon_buf: std.ArrayList(f64) = .empty;
    defer anon_buf.deinit(std.heap.smp_allocator);
    var vram_buf: std.ArrayList(f64) = .empty;
    defer vram_buf.deinit(std.heap.smp_allocator);
    var dropped: usize = 0;
    var r: u32 = 0;
    while (r < opts.runs) : (r += 1) {
        const s = runOnce(spec, bin, opts) catch {
            dropped += 1;
            continue;
        };
        try rss_buf.append(std.heap.smp_allocator, s.peak_rss_kib);
        try anon_buf.append(std.heap.smp_allocator, s.peak_anon_kib);
        try vram_buf.append(std.heap.smp_allocator, s.peak_vram_kib);
    }
    return .{
        .n = rss_buf.items.len,
        .rss = stats_mod.summarize(rss_buf.items, dropped),
        .anon = stats_mod.summarize(anon_buf.items, dropped),
        .vram = stats_mod.summarize(vram_buf.items, dropped),
    };
}
