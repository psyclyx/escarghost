//! Memory scenario. Spawn terminal with `sh -c "cat $PAYLOAD; sleep 0.3"`,
//! wait for it to exit, capture the child's maximum resident set size
//! via wait4()/getrusage. Reports median/min/max across N runs.
//!
//! Note: ru_maxrss is the child *process tree's* peak; for terminals
//! that fork helpers (kitty, wezterm) it's the parent's RSS, which is
//! what the user perceives as "the terminal's memory footprint" anyway.

const std = @import("std");
const h = @import("wlr_harness.zig");
const posix = h.posix;
const stats_mod = @import("bench_stats.zig");
const spec_mod = @import("bench_spec.zig");

const c = @cImport({
    @cInclude("sys/resource.h");
    @cInclude("sys/wait.h");
});

pub const Options = struct {
    runs: u32 = 5,
    sh_bin: []const u8,
    script: []const u8, // e.g. "cat /tmp/bench-payload.txt; sleep 0.3"
};

fn runOnce(spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !f64 {
    var argv_buf: [16][]const u8 = undefined;
    const extras = [_][]const u8{ opts.sh_bin, "-c", opts.script };
    const argv = spec_mod.buildArgv(&argv_buf, bin, spec, &extras);

    const pid = try h.spawnArgv(argv);
    var status: c_int = 0;
    var ru: c.struct_rusage = std.mem.zeroes(c.struct_rusage);
    const rc = c.wait4(@intCast(pid), &status, 0, &ru);
    if (rc < 0) return error.Wait4Failed;
    // ru_maxrss is in KiB on Linux. glibc wraps it in an anonymous
    // union so Zig's cimport surfaces it as `unnamed_0.ru_maxrss`.
    return @floatFromInt(ru.unnamed_0.ru_maxrss);
}

pub fn measureTerminal(spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !stats_mod.Stats {
    var buf: std.ArrayList(f64) = .empty;
    defer buf.deinit(std.heap.smp_allocator);
    var dropped: usize = 0;
    var r: u32 = 0;
    while (r < opts.runs) : (r += 1) {
        const rss = runOnce(spec, bin, opts) catch {
            dropped += 1;
            continue;
        };
        try buf.append(std.heap.smp_allocator, rss);
    }
    return stats_mod.summarize(buf.items, dropped);
}
