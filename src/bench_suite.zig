//! Terminal-comparison bench suite. Spawns one nested compositor,
//! sets up shared terminal configs (font, size), then runs the
//! selected scenarios against the selected terminals — all in one
//! process so we don't re-pay compositor + config setup per bench.
//!
//! Compositor lifecycle, BENCH_CAT/SCRGO_BIN/FOOT_BIN/... env vars,
//! and the payload file are supplied by the nix wrapper.

const std = @import("std");
const h = @import("wlr_harness.zig");
const posix = h.posix;

const spec_mod = @import("bench_spec.zig");
const stats_mod = @import("bench_stats.zig");
const startup_mod = @import("bench_startup.zig");
const stream_mod = @import("bench_stream.zig");
const latency_mod = @import("bench_input_latency.zig");
const memory_mod = @import("bench_memory.zig");
const screenshot_mod = @import("bench_screenshot.zig");

fn envOrNull(name: [*:0]const u8) ?[]const u8 {
    const p = posix.getenv(name) orelse return null;
    return std.mem.span(p);
}

fn requireEnv(name: [*:0]const u8) []const u8 {
    return envOrNull(name) orelse {
        std.debug.print("bench: env var ${s} not set\n", .{name});
        std.process.exit(2);
    };
}

const Scenario = enum { startup, stream, @"input-latency", memory, screenshots };

const all_scenarios = [_]Scenario{ .startup, .stream, .@"input-latency", .memory, .screenshots };

const Args = struct {
    scenarios: []const Scenario = &all_scenarios,
    terminals: []const spec_mod.TerminalSpec = &spec_mod.all,
    stream_runs: u32 = 3,
    startup_runs: u32 = 20,
    startup_warmup: u32 = 5,
    memory_runs: u32 = 5,
    latency_samples: u32 = 30,
    stream_deadline_ms: f64 = 30_000,
    screenshots_out: []const u8 = "/tmp",
};

fn parseScenarios(allocator: std.mem.Allocator, csv: []const u8) ![]const Scenario {
    var list: std.ArrayList(Scenario) = .empty;
    var it = std.mem.tokenizeScalar(u8, csv, ',');
    while (it.next()) |tok| {
        const s = std.meta.stringToEnum(Scenario, tok) orelse {
            std.debug.print("bench: unknown scenario '{s}' (have: startup, stream, input-latency, memory)\n", .{tok});
            std.process.exit(2);
        };
        try list.append(allocator, s);
    }
    return list.toOwnedSlice(allocator);
}

fn parseTerminals(allocator: std.mem.Allocator, csv: []const u8) ![]const spec_mod.TerminalSpec {
    var list: std.ArrayList(spec_mod.TerminalSpec) = .empty;
    var it = std.mem.tokenizeScalar(u8, csv, ',');
    while (it.next()) |tok| {
        const s = spec_mod.findByLabel(tok) orelse {
            std.debug.print("bench: unknown terminal '{s}'\n", .{tok});
            std.process.exit(2);
        };
        try list.append(allocator, s);
    }
    return list.toOwnedSlice(allocator);
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Args {
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.startsWith(u8, a, "--scenarios=")) {
            args.scenarios = try parseScenarios(allocator, a[12..]);
        } else if (std.mem.startsWith(u8, a, "--terminals=")) {
            args.terminals = try parseTerminals(allocator, a[12..]);
        } else if (std.mem.startsWith(u8, a, "--stream-runs=")) {
            args.stream_runs = try std.fmt.parseInt(u32, a[14..], 10);
        } else if (std.mem.startsWith(u8, a, "--startup-runs=")) {
            args.startup_runs = try std.fmt.parseInt(u32, a[15..], 10);
        } else if (std.mem.startsWith(u8, a, "--startup-warmup=")) {
            args.startup_warmup = try std.fmt.parseInt(u32, a[17..], 10);
        } else if (std.mem.startsWith(u8, a, "--memory-runs=")) {
            args.memory_runs = try std.fmt.parseInt(u32, a[14..], 10);
        } else if (std.mem.startsWith(u8, a, "--latency-samples=")) {
            args.latency_samples = try std.fmt.parseInt(u32, a[18..], 10);
        } else if (std.mem.startsWith(u8, a, "--stream-deadline-ms=")) {
            args.stream_deadline_ms = try std.fmt.parseFloat(f64, a[21..]);
        } else if (std.mem.startsWith(u8, a, "--screenshots-out=")) {
            args.screenshots_out = a[18..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\Usage: scrgo-bench-suite [options]
                \\
                \\  --scenarios=a,b,c        which scenarios to run (default: all)
                \\                           known: startup, stream, input-latency, memory
                \\  --terminals=x,y          which terminals to compare (default: all)
                \\  --stream-runs=N          runs per terminal for stream (default: 3)
                \\  --stream-deadline-ms=N   per-run timeout for stream (default: 30000)
                \\  --startup-runs=N         measured runs for startup (default: 20)
                \\  --startup-warmup=N       unmeasured warmup runs for startup (default: 5)
                \\  --memory-runs=N          runs per terminal for memory (default: 5)
                \\  --latency-samples=N      keys per terminal for input-latency (default: 30)
                \\  --screenshots-out=DIR    where to dump bench-<label>.ppm (default: /tmp)
                \\
                \\Env vars (supplied by the nix wrapper):
                \\  WAYLAND_DISPLAY   nested compositor socket
                \\  BENCH_CAT         absolute path to coreutils cat
                \\  BENCH_SH          absolute path to /bin/sh-equivalent
                \\  BENCH_ECHO        absolute path to coreutils echo
                \\  BENCH_PAYLOAD     absolute path to the 9 MB stream payload
                \\  SCRGO_BIN, FOOT_BIN, ALACRITTY_BIN, KITTY_BIN, WEZTERM_BIN
                \\
            , .{});
            std.process.exit(0);
        } else {
            std.debug.print("bench: unknown arg '{s}' (try --help)\n", .{a});
            std.process.exit(2);
        }
    }
    return args;
}

fn payloadSize(path: []const u8) u64 {
    const path_z = std.heap.smp_allocator.dupeZ(u8, path) catch return 0;
    defer std.heap.smp_allocator.free(path_z);
    const fd = posix.open(path_z.ptr, posix.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = posix.close(fd);
    var st: posix.struct_stat = undefined;
    if (posix.fstat(fd, &st) < 0) return 0;
    return @intCast(st.st_size);
}

fn binFor(spec: spec_mod.TerminalSpec) ?[]const u8 {
    var buf: [64:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{spec.env_var}) catch return null;
    return envOrNull(z.ptr);
}

fn printHeader(comptime title: []const u8, comptime cols: []const u8) void {
    std.debug.print("\n=== {s} ===\n", .{title});
    std.debug.print("{s}\n", .{cols});
    std.debug.print("{s}\n", .{"-" ** 78});
}

fn runStartup(args: Args) !void {
    const echo_bin = requireEnv("BENCH_ECHO");
    const opts: startup_mod.Options = .{
        .runs = args.startup_runs,
        .warmup = args.startup_warmup,
        .echo_bin = echo_bin,
    };
    printHeader(
        "startup (spawn → echo READY → exit)",
        "terminal     n   mean    median  min     max     dropped",
    );
    for (args.terminals) |spec| {
        const bin = binFor(spec) orelse {
            std.debug.print("{s:<10} skipped (${s} not set)\n", .{ spec.label, spec.env_var });
            continue;
        };
        const s = startup_mod.measureTerminal(spec, bin, opts) catch |err| {
            std.debug.print("{s:<10} error: {}\n", .{ spec.label, err });
            continue;
        };
        std.debug.print(
            "{s:<10}  {d:>3}  {d:>5.1}ms {d:>5.1}ms {d:>5.1}ms {d:>5.1}ms  {d:>3}\n",
            .{ spec.label, s.n, s.mean, s.median, s.min, s.max, s.dropped },
        );
    }
}

fn runStream(harness: *h.Harness, args: Args) !void {
    const cat = requireEnv("BENCH_CAT");
    const payload = requireEnv("BENCH_PAYLOAD");
    const size = payloadSize(payload);
    const opts: stream_mod.Options = .{
        .runs = args.stream_runs,
        .deadline_ms = args.stream_deadline_ms,
        .cat = cat,
        .payload = payload,
        .payload_size = size,
    };
    printHeader(
        "stream-under-load (9 MB cat)",
        "terminal     runs wall_mean wall_max distinct fps     MB/s",
    );
    for (args.terminals) |spec| {
        const bin = binFor(spec) orelse {
            std.debug.print("{s:<10} skipped (${s} not set)\n", .{ spec.label, spec.env_var });
            continue;
        };
        const a = stream_mod.measureTerminal(harness, spec, bin, opts);
        if (a.ok_runs == 0) {
            std.debug.print("{s:<10}  no successful runs\n", .{spec.label});
            continue;
        }
        std.debug.print(
            "{s:<10}  {d:>3}   {d:>7.1}ms {d:>6.1}ms {d:>7.0} {d:>5.1}fps {d:>5.1}MB/s\n",
            .{ spec.label, a.ok_runs, a.wall_mean, a.wall_max, a.distinct_mean, a.fps, a.mb_per_s },
        );
    }
}

fn runLatency(harness: *h.Harness, args: Args) !void {
    const cat = requireEnv("BENCH_CAT");
    const opts: latency_mod.Options = .{
        .samples = args.latency_samples,
        .cat = cat,
    };
    printHeader(
        "input-latency (key → pixel-change)",
        "terminal      n  mean    median  p99     max     min     dropped",
    );
    for (args.terminals) |spec| {
        const bin = binFor(spec) orelse {
            std.debug.print("{s:<10} skipped (${s} not set)\n", .{ spec.label, spec.env_var });
            continue;
        };
        const s = latency_mod.measureTerminal(harness, spec, bin, opts) catch |err| {
            std.debug.print("{s:<10} error: {}\n", .{ spec.label, err });
            continue;
        };
        std.debug.print(
            "{s:<10}  {d:>3}  {d:>5.1}ms {d:>5.1}ms {d:>5.1}ms {d:>5.1}ms {d:>5.1}ms  {d:>3}\n",
            .{ spec.label, s.n, s.mean, s.median, s.p99, s.max, s.min, s.dropped },
        );
    }
}

fn runMemory(args: Args) !void {
    const sh = requireEnv("BENCH_SH");
    const cat = requireEnv("BENCH_CAT");
    const payload = requireEnv("BENCH_PAYLOAD");
    // Hold the terminal alive ~1s after `cat` finishes so the poller
    // thread catches the post-load peak (some terminals don't reach
    // peak RSS until they finish ingesting and idle for a moment).
    var script_buf: [4096]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, "{s} {s}; sleep 1.0", .{ cat, payload });
    const opts: memory_mod.Options = .{
        .runs = args.memory_runs,
        .sh_bin = sh,
        .script = script,
    };
    printHeader(
        "memory (peak after ~9 MB scrollback; KiB)",
        "terminal      n   rss_med  rss_max  anon_med anon_max vram_med vram_max",
    );
    for (args.terminals) |spec| {
        const bin = binFor(spec) orelse {
            std.debug.print("{s:<10} skipped (${s} not set)\n", .{ spec.label, spec.env_var });
            continue;
        };
        const a = memory_mod.measureTerminal(spec, bin, opts) catch |err| {
            std.debug.print("{s:<10} error: {}\n", .{ spec.label, err });
            continue;
        };
        std.debug.print(
            "{s:<10}  {d:>3}  {d:>7.0} {d:>7.0}  {d:>7.0} {d:>7.0}  {d:>7.0} {d:>7.0}\n",
            .{ spec.label, a.n, a.rss.median, a.rss.max, a.anon.median, a.anon.max, a.vram.median, a.vram.max },
        );
    }
}

fn runScreenshots(harness: *h.Harness, args: Args) !void {
    const sh = requireEnv("BENCH_SH");
    const opts: screenshot_mod.Options = .{
        .sh_bin = sh,
        .out_dir = args.screenshots_out,
    };
    printHeader(
        "screenshots (one frame after a fixed payload)",
        "terminal     path",
    );
    for (args.terminals) |spec| {
        const bin = binFor(spec) orelse {
            std.debug.print("{s:<10} skipped (${s} not set)\n", .{ spec.label, spec.env_var });
            continue;
        };
        screenshot_mod.captureOne(harness, spec, bin, opts) catch |err| {
            std.debug.print("{s:<10} error: {}\n", .{ spec.label, err });
        };
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    while (args_iter.next()) |a| try argv_list.append(allocator, a);
    const args = try parseArgs(allocator, argv_list.items);

    var harness: h.Harness = .{ .display = undefined, .registry = undefined };
    var harness_inited = false;
    defer if (harness_inited) harness.deinit();

    for (args.scenarios) |scenario| {
        switch (scenario) {
            .startup => try runStartup(args),
            .memory => try runMemory(args),
            .stream, .@"input-latency", .screenshots => {
                if (!harness_inited) {
                    try harness.init();
                    harness_inited = true;
                }
                switch (scenario) {
                    .stream => try runStream(&harness, args),
                    .@"input-latency" => try runLatency(&harness, args),
                    .screenshots => try runScreenshots(&harness, args),
                    else => unreachable,
                }
            },
        }
    }
}
