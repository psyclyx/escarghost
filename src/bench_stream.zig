//! Stream-under-load bench. Per terminal: spawn it with
//! `<bin> [args] cat <payload>`, then capture frames continuously
//! while the terminal consumes the payload. Report wall time + how
//! many distinct frames the compositor presented + throughput.
//!
//! "Distinct frames" here = unique content hashes among the frames
//! we captured. Screencopy round-trips at ~16.7ms on 60Hz, so the
//! observation rate is capped at 60Hz; a terminal committing faster
//! will appear to commit at 60 fps. A terminal *slower* than 60 fps
//! will be measured accurately (we'll see repeated hashes).

const std = @import("std");
const perf = @import("perf.zig");
const h = @import("wlr_harness.zig");
const posix = h.posix;

const Spec = struct {
    label: []const u8,
    app_id: []const u8,
    env_var: []const u8,
    args_after_bin: []const []const u8,
};

const specs = [_]Spec{
    .{ .label = "scrgo", .app_id = "scrgo", .env_var = "SCRGO_BIN", .args_after_bin = &.{"-e"} },
    .{ .label = "foot", .app_id = "foot", .env_var = "FOOT_BIN", .args_after_bin = &.{} },
    .{ .label = "alacritty", .app_id = "Alacritty", .env_var = "ALACRITTY_BIN", .args_after_bin = &.{"-e"} },
    .{ .label = "kitty", .app_id = "kitty", .env_var = "KITTY_BIN", .args_after_bin = &.{"-e"} },
    .{
        .label = "wezterm",
        .app_id = "bench-wezterm",
        .env_var = "WEZTERM_BIN",
        .args_after_bin = &.{ "start", "--always-new-process", "--class", "bench-wezterm", "--" },
    },
};

fn envOrNull(name: [*:0]const u8) ?[]const u8 {
    const p = posix.getenv(name) orelse return null;
    return std.mem.span(p);
}

/// Quick non-cryptographic hash. Strides a prime through the buffer
/// so we touch a representative sample without paying the cost of
/// hashing every byte. Good enough to detect content changes between
/// successive captures of a ~2-4 MB frame.
fn quickHash(buf: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    var i: usize = 0;
    while (i < buf.len) : (i += 257) {
        hash ^= buf[i];
        hash = std.math.rotl(u64, hash, 7) *% 0x100000001b3;
    }
    return hash;
}

fn buildArgv(buf: [][]const u8, bin: []const u8, mid: []const []const u8, cat: []const u8, payload: []const u8) []const []const u8 {
    var n: usize = 0;
    buf[n] = bin;
    n += 1;
    for (mid) |m| {
        buf[n] = m;
        n += 1;
    }
    buf[n] = cat;
    n += 1;
    buf[n] = payload;
    n += 1;
    return buf[0..n];
}

const RunStats = struct {
    wall_ms: f64,
    distinct_frames: u32,
    total_captures: u32,
    exited_cleanly: bool,
};

fn runOnce(harness: *h.Harness, spec: Spec, bin: []const u8, cat: []const u8, payload: []const u8, run_deadline_ms: f64) !RunStats {
    var argv_buf: [10][]const u8 = undefined;
    const argv = buildArgv(&argv_buf, bin, spec.args_after_bin, cat, payload);

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
    // Inline waitpid(WNOHANG) check between captures.
    while (t_spawn.elapsedMs() < run_deadline_ms) {
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
    // Deadline hit — kill child, mark not-cleanly-exited.
    h.killChild(pid);
    return .{
        .wall_ms = t_spawn.elapsedMs(),
        .distinct_frames = distinct,
        .total_captures = total,
        .exited_cleanly = false,
    };
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();

    var runs_per_terminal: u32 = 3;
    var run_deadline_ms: f64 = 30000;
    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--runs=")) {
            runs_per_terminal = std.fmt.parseInt(u32, arg[7..], 10) catch runs_per_terminal;
        } else if (std.mem.startsWith(u8, arg, "--deadline-ms=")) {
            run_deadline_ms = std.fmt.parseFloat(f64, arg[14..]) catch run_deadline_ms;
        }
    }

    const cat = envOrNull("BENCH_CAT") orelse {
        std.debug.print("BENCH_CAT not set\n", .{});
        std.process.exit(2);
    };
    const payload = envOrNull("BENCH_PAYLOAD") orelse {
        std.debug.print("BENCH_PAYLOAD not set\n", .{});
        std.process.exit(2);
    };

    // Stat the payload so we can report throughput.
    const payload_size: u64 = blk: {
        const path_z = std.heap.smp_allocator.dupeZ(u8, payload) catch break :blk 0;
        defer std.heap.smp_allocator.free(path_z);
        const fd = posix.open(path_z.ptr, posix.O_RDONLY);
        if (fd < 0) break :blk 0;
        defer _ = posix.close(fd);
        var st: posix.struct_stat = undefined;
        if (posix.fstat(fd, &st) < 0) break :blk 0;
        break :blk @intCast(st.st_size);
    };

    var harness: h.Harness = .{ .display = undefined, .registry = undefined };
    try harness.init();
    defer harness.deinit();

    std.debug.print(
        "=== stream-under-load bench (payload={} bytes, runs={}, deadline={d:.0}ms) ===\n",
        .{ payload_size, runs_per_terminal, run_deadline_ms },
    );
    std.debug.print("{s:<10} {s:>5} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9}\n", .{
        "terminal", "runs", "wall_mean", "wall_max", "distinct", "fps", "MB/s",
    });
    std.debug.print("{s}\n", .{"-" ** 70});

    for (specs) |spec| {
        var var_buf: [64:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&var_buf, "{s}", .{spec.env_var}) catch continue;
        const bin = envOrNull(z.ptr) orelse {
            std.debug.print("{s:<10} skipped (${s} not set)\n", .{ spec.label, spec.env_var });
            continue;
        };

        var ok_runs: u32 = 0;
        var wall_sum: f64 = 0;
        var wall_max: f64 = 0;
        var distinct_sum: u64 = 0;
        var distinct_max: u32 = 0;
        var r: u32 = 0;
        while (r < runs_per_terminal) : (r += 1) {
            const rs = runOnce(&harness, spec, bin, cat, payload, run_deadline_ms) catch |err| {
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
            distinct_max = @max(distinct_max, rs.distinct_frames);
        }

        if (ok_runs == 0) {
            std.debug.print("{s:<10} {d:>5} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9}\n", .{
                spec.label, ok_runs, "-", "-", "-", "-", "-",
            });
            continue;
        }
        const wall_mean = wall_sum / @as(f64, @floatFromInt(ok_runs));
        const distinct_mean = @as(f64, @floatFromInt(distinct_sum)) / @as(f64, @floatFromInt(ok_runs));
        const fps = distinct_mean * 1000.0 / wall_mean;
        const mb_per_s = (@as(f64, @floatFromInt(payload_size)) / (1024.0 * 1024.0)) * 1000.0 / wall_mean;
        std.debug.print("{s:<10} {d:>5} {d:>8.1}ms {d:>8.1}ms {d:>9.0} {d:>8.1}fps {d:>7.1}MB/s\n", .{
            spec.label, ok_runs, wall_mean, wall_max, distinct_mean, fps, mb_per_s,
        });
    }
}
