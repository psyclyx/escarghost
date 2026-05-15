//! Stream-under-load scenario. Spawn terminal with `cat <payload>`,
//! capture frames until the child exits, count distinct content
//! hashes, report wall time + throughput + distinct fps.

const std = @import("std");
const perf = @import("perf.zig");
const h = @import("wlr_harness.zig");
const posix = h.posix;
const spec_mod = @import("bench_spec.zig");

pub const Options = struct {
    runs: u32 = 3,
    deadline_ms: f64 = 30_000,
    cat: []const u8,
    payload: []const u8,
    payload_size: u64,
};

pub const RunStats = struct {
    wall_ms: f64,
    distinct_frames: u32,
    total_captures: u32,
    exited_cleanly: bool,
};

pub const Aggregate = struct {
    ok_runs: u32 = 0,
    wall_mean: f64 = 0,
    wall_max: f64 = 0,
    distinct_mean: f64 = 0,
    fps: f64 = 0,
    mb_per_s: f64 = 0,
};

/// Quick non-cryptographic hash. Strides a prime through the buffer so
/// we touch a representative sample without paying the cost of hashing
/// every byte. Good enough to detect content changes between successive
/// captures of a ~2-4 MB frame.
fn quickHash(buf: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    var i: usize = 0;
    while (i < buf.len) : (i += 257) {
        hash ^= buf[i];
        hash = std.math.rotl(u64, hash, 7) *% 0x100000001b3;
    }
    return hash;
}

pub fn runOnce(harness: *h.Harness, spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !RunStats {
    var argv_buf: [16][]const u8 = undefined;
    const extras = [_][]const u8{ opts.cat, opts.payload };
    const argv = spec_mod.buildArgv(&argv_buf, bin, spec, &extras);

    const t_spawn = perf.Timer.now();
    const pid = try h.spawnArgv(argv);
    errdefer h.killChild(pid);

    if (!(try harness.waitForAppId(spec.app_id, 5000))) {
        h.killChild(pid);
        return error.NoToplevel;
    }

    var last_hash: u64 = 0;
    var distinct: u32 = 0;
    var total: u32 = 0;
    while (t_spawn.elapsedMs() < opts.deadline_ms) {
        const cap = try harness.captureFrame();
        total += 1;
        const hh = quickHash(cap);
        if (hh != last_hash) {
            distinct += 1;
            last_hash = hh;
        }
        var status: c_int = 0;
        const rc = posix.waitpid(pid, &status, posix.WNOHANG);
        if (rc == pid) {
            // Drain a couple more captures so the terminal's final
            // frame (drain phase / equivalent) lands.
            _ = try harness.captureFrame();
            const final = try harness.captureFrame();
            total += 2;
            const fh = quickHash(final);
            if (fh != last_hash) {
                distinct += 1;
                last_hash = fh;
            }
            return .{
                .wall_ms = t_spawn.elapsedMs(),
                .distinct_frames = distinct,
                .total_captures = total,
                .exited_cleanly = true,
            };
        }
    }
    h.killChild(pid);
    return .{
        .wall_ms = t_spawn.elapsedMs(),
        .distinct_frames = distinct,
        .total_captures = total,
        .exited_cleanly = false,
    };
}

pub fn measureTerminal(harness: *h.Harness, spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) Aggregate {
    var ok_runs: u32 = 0;
    var wall_sum: f64 = 0;
    var wall_max: f64 = 0;
    var distinct_sum: u64 = 0;
    var r: u32 = 0;
    while (r < opts.runs) : (r += 1) {
        const rs = runOnce(harness, spec, bin, opts) catch |err| {
            std.debug.print("{s:<10} run {} error: {}\n", .{ spec.label, r, err });
            continue;
        };
        if (!rs.exited_cleanly) {
            std.debug.print("{s:<10} run {} hit deadline at {d:.0}ms\n", .{ spec.label, r, rs.wall_ms });
            continue;
        }
        ok_runs += 1;
        wall_sum += rs.wall_ms;
        wall_max = @max(wall_max, rs.wall_ms);
        distinct_sum += rs.distinct_frames;
    }
    if (ok_runs == 0) return .{};
    const wall_mean = wall_sum / @as(f64, @floatFromInt(ok_runs));
    const distinct_mean = @as(f64, @floatFromInt(distinct_sum)) / @as(f64, @floatFromInt(ok_runs));
    return .{
        .ok_runs = ok_runs,
        .wall_mean = wall_mean,
        .wall_max = wall_max,
        .distinct_mean = distinct_mean,
        .fps = distinct_mean * 1000.0 / wall_mean,
        .mb_per_s = (@as(f64, @floatFromInt(opts.payload_size)) / (1024.0 * 1024.0)) * 1000.0 / wall_mean,
    };
}
