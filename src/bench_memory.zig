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
//!   peak_vram  - max VRAM in KiB. On mesa drivers (amdgpu/intel/radv)
//!                we read /proc/<pid>/fdinfo/*'s drm-memory-vram-resident
//!                counters. NVIDIA's proprietary driver doesn't expose
//!                that field, so we fall back to shelling out to
//!                `nvidia-smi pmon -s m -c 1` and matching by pid. Both
//!                paths feed the same peak so the value reflects whichever
//!                source actually reports.

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
    /// Final (post-workload) RSS — the steady-state footprint after the
    /// terminal has ingested the payload and idled for `sleep_settle`.
    /// This is the number that actually matters for "how much memory
    /// does this terminal hold while sitting open with this scrollback."
    rss_kib: f64,
    /// Final (post-workload) anonymous RSS.
    anon_kib: f64,
    /// Final (post-workload) VRAM.
    vram_kib: f64,
    /// Peak RSS during the whole run (kernel-tracked via rusage). Includes
    /// the GPU driver's transient context-init footprint on NVIDIA. Useful
    /// for catching regressions, but not representative of steady-state.
    peak_rss_kib: f64,
    /// Peak anon RSS during the whole run.
    peak_anon_kib: f64,
    /// Peak VRAM during the whole run.
    peak_vram_kib: f64,
};

pub const Aggregate = struct {
    n: usize = 0,
    rss: stats_mod.Stats = .{},
    anon: stats_mod.Stats = .{},
    vram: stats_mod.Stats = .{},
    peak_rss: stats_mod.Stats = .{},
    peak_anon: stats_mod.Stats = .{},
    peak_vram: stats_mod.Stats = .{},
};

const Poller = struct {
    pid: posix.pid_t,
    stop: std.atomic.Value(bool),
    peak_anon_kib: std.atomic.Value(u64),
    peak_vram_kib: std.atomic.Value(u64),
    /// Most recent samples, updated every poll. After the workload runs
    /// to completion and the process is about to exit, the bench reads
    /// these as the steady-state values.
    last_anon_kib: std.atomic.Value(u64),
    last_rss_kib: std.atomic.Value(u64),
    last_vram_kib: std.atomic.Value(u64),
    nvidia_smi: ?[*:0]const u8,
    tick: u32 = 0,

    fn pollLoop(self: *Poller) void {
        while (!self.stop.load(.acquire)) {
            // Per-iteration delay (~5 ms). We don't care about high
            // precision — we just need to catch the peak window.
            sleepMs(5);
            samplePid(self.pid, &self.peak_anon_kib, &self.peak_vram_kib, &self.last_anon_kib, &self.last_rss_kib, &self.last_vram_kib);
            self.tick +%= 1;
            // nvidia-smi pmon takes ~25 ms to run, so cap it at ~10 Hz
            // (every 20 × 5 ms). The terminal lives ~hundreds of ms so
            // we still catch the peak comfortably.
            if (self.nvidia_smi) |bin| {
                if (self.tick % 20 == 0) sampleNvidia(bin, self.pid, &self.peak_vram_kib, &self.last_vram_kib);
            }
        }
    }
};

fn samplePid(
    pid: posix.pid_t,
    peak_anon: *std.atomic.Value(u64),
    peak_vram: *std.atomic.Value(u64),
    last_anon: *std.atomic.Value(u64),
    last_rss: *std.atomic.Value(u64),
    last_vram: *std.atomic.Value(u64),
) void {
    // /proc/<pid>/status: parse RssAnon + VmRSS lines.
    var path_buf: [64]u8 = undefined;
    const status_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/status", .{pid}) catch return;
    if (readKey(status_path, "RssAnon:")) |kib| {
        bumpMax(peak_anon, kib);
        last_anon.store(kib, .release);
    }
    if (readKey(status_path, "VmRSS:")) |kib| {
        last_rss.store(kib, .release);
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
    last_vram.store(vram_total, .release);
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

/// Probe a few well-known absolute paths for nvidia-smi. The bench
/// wrapper uses writeShellApplication which strips PATH down to its
/// runtimeInputs, so we can't rely on PATH-search here. nvidia-smi
/// must be the host's driver-matched binary anyway (the user-space
/// tool talks an ABI that's pinned to the loaded kernel module), so
/// pulling it via Nix would risk a version mismatch.
fn findNvidiaSmi() ?[*:0]const u8 {
    const candidates = [_][*:0]const u8{
        "/run/current-system/sw/bin/nvidia-smi", // NixOS
        "/usr/bin/nvidia-smi", // most other distros
        "/usr/local/bin/nvidia-smi",
    };
    for (candidates) |p| {
        if (c.access(p, c.X_OK) == 0) return p;
    }
    return null;
}

/// fork+exec `nvidia-smi pmon -s m -c 1`, slurp stdout, find our pid's
/// FB column, bump the peak. Output looks like:
///
///   # gpu         pid   type     fb   ccpm    command
///   # Idx           #    C/G     MB     MB    name
///       0     626250     G    275      0    river
///
/// We use fork+exec rather than posix_spawn just to keep the dep
/// surface identical to spawnArgv. The poller runs on its own thread,
/// so the brief fork stall doesn't block the 5 ms anon-RSS cadence on
/// the main thread.
fn sampleNvidia(bin: [*:0]const u8, target_pid: posix.pid_t, peak_vram: *std.atomic.Value(u64), last_vram: *std.atomic.Value(u64)) void {
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return;
    const child = posix.fork();
    if (child < 0) {
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        return;
    }
    if (child == 0) {
        _ = c.close(pipefd[0]);
        _ = c.dup2(pipefd[1], 1);
        _ = c.dup2(pipefd[1], 2); // also redirect stderr, otherwise driver warnings garble parsing
        _ = c.close(pipefd[1]);
        const argv = [_:null]?[*:0]const u8{ bin, "pmon", "-s", "m", "-c", "1" };
        _ = posix.execv(bin, @ptrCast(&argv));
        posix._exit(127);
    }
    _ = c.close(pipefd[1]);

    var buf: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(pipefd[0], buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = c.close(pipefd[0]);
    var status: c_int = 0;
    _ = posix.waitpid(child, &status, 0);
    if (total == 0) return;

    var line_it = std.mem.tokenizeScalar(u8, buf[0..total], '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        // Columns (with -s m): gpu pid type fb ccpm command
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        _ = tok.next() orelse continue; // gpu
        const pid_s = tok.next() orelse continue;
        const pid_v = std.fmt.parseInt(posix.pid_t, pid_s, 10) catch continue;
        if (pid_v != target_pid) continue;
        _ = tok.next() orelse continue; // type (C/G)
        const fb_s = tok.next() orelse continue;
        // nvidia-smi reports "-" for processes it can't account memory
        // to (e.g. just-spawned processes mid-context-create).
        if (std.mem.eql(u8, fb_s, "-")) return;
        const fb_mib = std.fmt.parseInt(u64, fb_s, 10) catch return;
        const fb_kib = fb_mib * 1024;
        bumpMax(peak_vram, fb_kib);
        last_vram.store(fb_kib, .release);
        return;
    }
}

fn runOnce(spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options, nvidia_smi: ?[*:0]const u8) !Sample {
    var argv_buf: [16][]const u8 = undefined;
    const extras = [_][]const u8{ opts.sh_bin, "-c", opts.script };
    const argv = spec_mod.buildArgv(&argv_buf, bin, spec, &extras);

    const pid = try h.spawnArgv(argv);

    var poller: Poller = .{
        .pid = pid,
        .stop = .init(false),
        .peak_anon_kib = .init(0),
        .peak_vram_kib = .init(0),
        .last_anon_kib = .init(0),
        .last_rss_kib = .init(0),
        .last_vram_kib = .init(0),
        .nvidia_smi = nvidia_smi,
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
        .vram_kib = @floatFromInt(poller.last_vram_kib.load(.acquire)),
        .peak_rss_kib = @floatFromInt(ru.unnamed_0.ru_maxrss),
        .peak_anon_kib = @floatFromInt(poller.peak_anon_kib.load(.acquire)),
        .peak_vram_kib = @floatFromInt(poller.peak_vram_kib.load(.acquire)),
    };
}

pub fn measureTerminal(spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !Aggregate {
    const alloc = std.heap.smp_allocator;
    var rss_buf: std.ArrayList(f64) = .empty;
    defer rss_buf.deinit(alloc);
    var anon_buf: std.ArrayList(f64) = .empty;
    defer anon_buf.deinit(alloc);
    var vram_buf: std.ArrayList(f64) = .empty;
    defer vram_buf.deinit(alloc);
    var peak_rss_buf: std.ArrayList(f64) = .empty;
    defer peak_rss_buf.deinit(alloc);
    var peak_anon_buf: std.ArrayList(f64) = .empty;
    defer peak_anon_buf.deinit(alloc);
    var peak_vram_buf: std.ArrayList(f64) = .empty;
    defer peak_vram_buf.deinit(alloc);
    var dropped: usize = 0;
    const nvidia_smi = findNvidiaSmi();
    var r: u32 = 0;
    while (r < opts.runs) : (r += 1) {
        const s = runOnce(spec, bin, opts, nvidia_smi) catch {
            dropped += 1;
            continue;
        };
        try rss_buf.append(alloc, s.rss_kib);
        try anon_buf.append(alloc, s.anon_kib);
        try vram_buf.append(alloc, s.vram_kib);
        try peak_rss_buf.append(alloc, s.peak_rss_kib);
        try peak_anon_buf.append(alloc, s.peak_anon_kib);
        try peak_vram_buf.append(alloc, s.peak_vram_kib);
    }
    return .{
        .n = rss_buf.items.len,
        .rss = stats_mod.summarize(rss_buf.items, dropped),
        .anon = stats_mod.summarize(anon_buf.items, dropped),
        .vram = stats_mod.summarize(vram_buf.items, dropped),
        .peak_rss = stats_mod.summarize(peak_rss_buf.items, dropped),
        .peak_anon = stats_mod.summarize(peak_anon_buf.items, dropped),
        .peak_vram = stats_mod.summarize(peak_vram_buf.items, dropped),
    };
}
