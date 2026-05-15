//! Startup scenario. Spawn `<term> -e echo READY`, time spawn → exit.
//! Replaces the hyperfine wrapper that used to drive this so the bench
//! suite is one binary. Includes a warmup phase so disk caches /
//! fontconfig caches are warm before measuring.

const std = @import("std");
const perf = @import("perf.zig");
const h = @import("wlr_harness.zig");
const posix = h.posix;
const stats_mod = @import("bench_stats.zig");
const spec_mod = @import("bench_spec.zig");

pub const Options = struct {
    runs: u32 = 20,
    warmup: u32 = 5,
    echo_bin: []const u8,
};

fn runOnce(spec: spec_mod.TerminalSpec, bin: []const u8, echo_bin: []const u8) !f64 {
    var argv_buf: [16][]const u8 = undefined;
    const extras = [_][]const u8{ echo_bin, "READY" };
    const argv = spec_mod.buildArgv(&argv_buf, bin, spec, &extras);

    const t = perf.Timer.now();
    const pid = try h.spawnArgv(argv);
    // Block until child exits (no WNOHANG); startup-bench is exactly
    // this round-trip.
    var status: c_int = 0;
    while (true) {
        const rc = posix.waitpid(pid, &status, 0);
        if (rc == pid) break;
        if (rc < 0) return error.WaitpidFailed;
    }
    return t.elapsedMs();
}

pub fn measureTerminal(spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !stats_mod.Stats {
    var w: u32 = 0;
    while (w < opts.warmup) : (w += 1) {
        _ = runOnce(spec, bin, opts.echo_bin) catch {};
    }

    var buf: std.ArrayList(f64) = .empty;
    defer buf.deinit(std.heap.smp_allocator);
    var dropped: usize = 0;
    var r: u32 = 0;
    while (r < opts.runs) : (r += 1) {
        const ms = runOnce(spec, bin, opts.echo_bin) catch {
            dropped += 1;
            continue;
        };
        try buf.append(std.heap.smp_allocator, ms);
    }
    return stats_mod.summarize(buf.items, dropped);
}
