//! Input-latency comparison bench. Runs as a wayland client inside a
//! nested compositor (sway nested in the host session — same model as
//! bench-startup.nix). For each terminal in a fixed list, spawns it
//! with `-e cat` (so injected keystrokes round-trip via the kernel
//! line discipline), waits for its toplevel, injects N keys, and times
//! each injection-to-pixel-change.
//!
//! Reports mean / median / p99 / max latency per terminal across N
//! samples. The latency floor is one compositor vblank (~16.7ms on
//! 60Hz output), so anything close to that = "as fast as we can
//! observe end-to-end through screencopy."

const std = @import("std");
const perf = @import("perf.zig");
const h = @import("wlr_harness.zig");
const posix = h.posix;

const Spec = struct {
    label: []const u8,
    app_id: []const u8,
    env_var: []const u8, // name of the env var that supplies the bin path
    args_after_bin: []const []const u8, // tokens that go between <bin> and <cat>
};

// Per-terminal command shape. The bin path comes from an env var
// (e.g. SCRGO_BIN, FOOT_BIN…) so the nix wrapper can pin the exact
// build. cat_path is read from BENCH_CAT.
//
// wezterm: `--always-new-process` keeps us out of the mux daemon
// (otherwise `wezterm start` may reuse an existing GUI process and
// our `pid` no longer owns the window). `start --class bench-wezterm`
// sets the wayland app_id so we have a stable string to wait on
// regardless of nixpkgs' default app_id.
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

fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const idx_f = p * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(idx_f));
    const hi: usize = @intFromFloat(@ceil(idx_f));
    if (lo == hi) return sorted[lo];
    const t = idx_f - @as(f64, @floatFromInt(lo));
    return sorted[lo] * (1 - t) + sorted[hi] * t;
}

const Stats = struct {
    mean: f64,
    median: f64,
    p99: f64,
    max: f64,
    min: f64,
    n: usize,
    dropped: usize,
};

fn summarize(buf: []f64, dropped: usize) Stats {
    if (buf.len == 0) return .{ .mean = 0, .median = 0, .p99 = 0, .max = 0, .min = 0, .n = 0, .dropped = dropped };
    std.mem.sort(f64, buf, {}, comptime std.sort.asc(f64));
    var sum: f64 = 0;
    for (buf) |v| sum += v;
    return .{
        .mean = sum / @as(f64, @floatFromInt(buf.len)),
        .median = percentile(buf, 0.5),
        .p99 = percentile(buf, 0.99),
        .max = buf[buf.len - 1],
        .min = buf[0],
        .n = buf.len,
        .dropped = dropped,
    };
}

fn buildArgv(buf: [][]const u8, bin: []const u8, mid: []const []const u8, cat: []const u8) []const []const u8 {
    var n: usize = 0;
    buf[n] = bin;
    n += 1;
    for (mid) |m| {
        buf[n] = m;
        n += 1;
    }
    buf[n] = cat;
    n += 1;
    return buf[0..n];
}

fn measureTerminal(harness: *h.Harness, spec: Spec, bin: []const u8, cat: []const u8, samples: u32) !Stats {
    var argv_buf: [8][]const u8 = undefined;
    const argv = buildArgv(&argv_buf, bin, spec.args_after_bin, cat);

    const pid = try h.spawnArgv(argv);
    defer h.killChild(pid);

    if (!(try harness.waitForAppId(spec.app_id, 5000))) {
        std.debug.print("[{s}] toplevel '{s}' did not appear within 5s\n", .{ spec.label, spec.app_id });
        return .{ .mean = 0, .median = 0, .p99 = 0, .max = 0, .min = 0, .n = 0, .dropped = samples };
    }

    // Let the terminal finish startup + first frame paint. We capture
    // a generous number of frames so the steady-state bg color and
    // the focus/keymap handshake (alacritty in particular sometimes
    // drops keys typed before it's focused) are out of the way.
    var settle_n: u32 = 0;
    while (settle_n < 10) : (settle_n += 1) _ = try harness.captureFrame();
    const settle = try harness.captureFrame();
    const stride = harness.cached_frame.stride;
    const pix_fmt = h.pixelFmtFromShm(harness.cached_frame.format) orelse return error.UnsupportedFmt;
    const bg = h.pixelAt(settle, stride, pix_fmt, 100, 100) orelse return error.ProbeOOB;

    // Warmup: send a few keystrokes that we don't measure, just to
    // burn off any first-input cost (cursor reposition, focus latch,
    // shaper warmup, etc.). Drop their pixels into prev_count so the
    // first measured key sees a clean delta.
    {
        var w: u32 = 0;
        while (w < 3) : (w += 1) {
            try harness.typeKey(h.keyEvdev('x') orelse continue);
            _ = try harness.captureFrame();
            _ = try harness.captureFrame();
        }
    }

    // Top-left probe. Generous height (two cell rows) so terminals
    // with padding (alacritty defaults included) still hit the
    // window, and wide enough to catch the cursor + glyphs as they
    // scroll across columns.
    const probe_x: u32 = 0;
    const probe_y: u32 = 0;
    const probe_w: u32 = 400;
    const probe_h: u32 = 60;
    const non_bg_thresh: i32 = 20;
    const input_deadline_ms: f64 = 500;

    var lat: std.ArrayList(f64) = .empty;
    defer lat.deinit(std.heap.smp_allocator);
    var dropped: usize = 0;
    // Re-sample after warmup; the cell count has moved.
    const post_warmup = try harness.captureFrame();
    var prev_count: u64 = h.nonBgPixels(post_warmup, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);

    // Cycle through 'a'..'z' so each sample writes a fresh non-bg
    // shape (cursor block + new glyph). Wrap around if samples > 26.
    var s: u32 = 0;
    while (s < samples) : (s += 1) {
        const ch: u8 = @intCast(@as(u8, 'a') + @as(u8, @intCast(s % 26)));
        const code = h.keyEvdev(ch) orelse continue;
        try harness.typeKey(code);
        const t_inject = perf.Timer.now();
        var detected: f64 = -1;
        while (t_inject.elapsedMs() < input_deadline_ms) {
            const cap = try harness.captureFrame();
            const cnt = h.nonBgPixels(cap, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
            if (cnt > prev_count + 4) {
                detected = t_inject.elapsedMs();
                prev_count = cnt;
                break;
            }
        }
        if (detected < 0) {
            dropped += 1;
        } else {
            try lat.append(std.heap.smp_allocator, detected);
        }
    }

    // Drain a few dispatch cycles before kill so the foreign_toplevel
    // close event has time to arrive next iteration.
    _ = try harness.dispatchOnce(20);

    return summarize(lat.items, dropped);
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();

    var samples: u32 = 30;
    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--samples=")) {
            samples = std.fmt.parseInt(u32, arg[10..], 10) catch samples;
        }
    }

    const cat = envOrNull("BENCH_CAT") orelse {
        std.debug.print("BENCH_CAT not set\n", .{});
        std.process.exit(2);
    };

    var harness: h.Harness = .{ .display = undefined, .registry = undefined };
    try harness.init();
    defer harness.deinit();

    std.debug.print("=== input-latency bench ({} samples/terminal) ===\n", .{samples});
    std.debug.print("{s:<10} {s:>7} {s:>8} {s:>8} {s:>7} {s:>7} {s:>7} {s:>7}\n", .{
        "terminal", "n", "mean", "median", "p99", "max", "min", "dropped",
    });
    std.debug.print("{s}\n", .{"-" ** 70});

    var any_run = false;
    for (specs) |spec| {
        var var_buf: [64:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&var_buf, "{s}", .{spec.env_var}) catch continue;
        const bin = envOrNull(z.ptr) orelse {
            std.debug.print("{s:<10} skipped (${s} not set)\n", .{ spec.label, spec.env_var });
            continue;
        };
        any_run = true;
        const stats = measureTerminal(&harness, spec, bin, cat, samples) catch |err| {
            std.debug.print("{s:<10} error: {}\n", .{ spec.label, err });
            continue;
        };
        std.debug.print("{s:<10} {d:>7} {d:>7.1}ms {d:>7.1}ms {d:>6.1}ms {d:>6.1}ms {d:>6.1}ms {d:>7}\n", .{
            spec.label, stats.n, stats.mean, stats.median, stats.p99, stats.max, stats.min, stats.dropped,
        });
    }

    if (!any_run) std.process.exit(1);
}
