//! Integration test for scrgo: spawn it inside a nested sway, inject
//! keys via zwp_virtual_keyboard, capture frames via zwlr_screencopy,
//! and measure (a) time from spawn to first content paint and (b)
//! per-keystroke injection-to-pixel latency.
//!
//! Shared wlroots client plumbing (registry binding, virtual_keyboard
//! keymap upload, screencopy capture, foreign_toplevel matching) lives
//! in `wlr_harness.zig`.

const std = @import("std");
const perf = @import("perf");
const h = @import("wlr_harness");
const posix = h.posix;

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const scrgo_path_opt = args_iter.next();
    if (scrgo_path_opt == null) {
        std.debug.print("usage: scrgo-integration-test <scrgo-binary>\n", .{});
        std.process.exit(2);
    }
    const scrgo_path = scrgo_path_opt.?;
    const cat_path = blk: {
        const env_cat = posix.getenv("SCRGO_IT_CAT");
        if (env_cat) |p| break :blk std.mem.span(p);
        break :blk "/bin/cat";
    };
    const scrgo_argv = [_][]const u8{ scrgo_path, "-e", cat_path };

    // Pre-spawn baseline: capture once so we know the compositor's
    // "no scrgo surface" probe pixel.
    const t_start = perf.Timer.now();
    var harness: h.Harness = .{ .display = undefined, .registry = undefined };
    try harness.init();
    defer harness.deinit();
    std.debug.print("harness: globals bound ({d:.1}ms)\n", .{t_start.elapsedMs()});

    const pre_cap = try harness.captureFrame();
    const stride = harness.cached_frame.stride;
    const out_w = harness.cached_frame.width;
    const out_h = harness.cached_frame.height;
    const pix_fmt = h.pixelFmtFromShm(harness.cached_frame.format) orelse {
        std.debug.print("FAIL: unsupported shm format 0x{x}\n", .{harness.cached_frame.format});
        std.process.exit(1);
    };
    // Probe scrgo's top-left surface region. (5,5) sits inside any
    // reasonable scrgo window, away from the very edge.
    const probe_px: u32 = 5;
    const probe_py: u32 = 5;
    const initial_px = h.pixelAt(pre_cap, stride, pix_fmt, probe_px, probe_py) orelse {
        std.debug.print("FAIL: probe out of bounds in pre-spawn capture\n", .{});
        std.process.exit(1);
    };
    std.debug.print("harness: pre-spawn frame {}x{} stride={} fmt=0x{x}, ({},{}) = rgb({},{},{}) ({d:.1}ms)\n", .{
        out_w, out_h, stride, harness.cached_frame.format,
        probe_px, probe_py, initial_px[0], initial_px[1], initial_px[2],
        t_start.elapsedMs(),
    });

    const t_spawn = perf.Timer.now();
    const pid = try h.spawnArgv(&scrgo_argv);
    errdefer h.killChild(pid);
    std.debug.print("harness: spawned scrgo pid={} (t_spawn=0)\n", .{pid});

    // ── Startup latency: spawn → first-paint → first-content ──────────

    const probe_x: u32 = 0;
    const probe_y: u32 = 0;
    const probe_w: u32 = 200;
    const probe_h: u32 = 24;
    const non_bg_thresh: i32 = 30;
    const startup_deadline_ms: f64 = 2000;

    var first_paint_ms: ?f64 = null;
    var first_paint_caps: u32 = 0;
    var first_content_ms: ?f64 = null;
    var first_content_caps: u32 = 0;
    var bg: [3]u8 = initial_px;
    var caps: u32 = 0;
    var content_buf: ?[]u8 = null;
    defer if (content_buf) |b| std.heap.smp_allocator.free(b);

    while (first_content_ms == null and t_spawn.elapsedMs() < startup_deadline_ms) {
        const cap = try harness.captureFrame();
        caps += 1;
        const px = h.pixelAt(cap, stride, pix_fmt, probe_px, probe_py) orelse continue;
        const changed = px[0] != initial_px[0] or px[1] != initial_px[1] or px[2] != initial_px[2];
        if (first_paint_ms == null and changed) {
            first_paint_ms = t_spawn.elapsedMs();
            first_paint_caps = caps;
            bg = px;
        }
        if (first_paint_ms != null) {
            const cnt = h.nonBgPixels(cap, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
            if (cnt >= 5) {
                first_content_ms = t_spawn.elapsedMs();
                first_content_caps = caps;
                content_buf = try std.heap.smp_allocator.alloc(u8, cap.len);
                @memcpy(content_buf.?, cap);
            }
        }
    }

    if (first_paint_ms == null) {
        std.debug.print("FAIL: no first-paint within {d:.0}ms\n", .{startup_deadline_ms});
        h.killChild(pid);
        std.process.exit(1);
    }
    if (first_content_ms == null) {
        std.debug.print("FAIL: first paint at {d:.1}ms but no content within {d:.0}ms\n", .{ first_paint_ms.?, startup_deadline_ms });
        h.killChild(pid);
        std.process.exit(1);
    }
    const content_gap_ms = first_content_ms.? - first_paint_ms.?;
    const content_gap_caps = first_content_caps - first_paint_caps;
    std.debug.print(
        "startup:   first_paint = {d:.1}ms ({} captures)  bg = rgb({},{},{})\n" ++
            "startup: first_content = {d:.1}ms ({} captures)  gap from paint: {d:.1}ms / {} captures\n",
        .{ first_paint_ms.?, first_paint_caps, bg[0], bg[1], bg[2], first_content_ms.?, first_content_caps, content_gap_ms, content_gap_caps },
    );

    if (!(try harness.waitForAppId("scrgo", 1000))) {
        std.debug.print("FAIL: scrgo toplevel not announced via foreign_toplevel\n", .{});
        h.killChild(pid);
        std.process.exit(1);
    }

    var any_failure = false;
    if (first_paint_ms.? > 200) {
        std.debug.print("FAIL: first_paint {d:.1}ms exceeds 200ms budget\n", .{first_paint_ms.?});
        any_failure = true;
    }
    if (content_gap_ms > 100) {
        std.debug.print("FAIL: content-after-paint gap {d:.1}ms exceeds 100ms budget\n", .{content_gap_ms});
        any_failure = true;
    }
    if (content_gap_caps > 4) {
        std.debug.print("FAIL: content-after-paint gap {} captures > 4 (expected 1-2)\n", .{content_gap_caps});
        any_failure = true;
    }

    // ── Phase 2: per-key input latency ────────────────────────────────

    var last_count: u64 = h.nonBgPixels(content_buf.?, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
    std.debug.print("input: cell-row non-bg baseline = {}\n", .{last_count});

    const chars = "abc";
    const input_deadline_ms: f64 = 500;
    for (chars) |ch| {
        const code = h.keyEvdev(ch) orelse continue;
        try harness.typeKey(code);
        const t_inject = perf.Timer.now();
        var icaps: u32 = 0;
        var detected: ?f64 = null;
        var new_count: u64 = last_count;
        while (t_inject.elapsedMs() < input_deadline_ms) {
            const cap = try harness.captureFrame();
            icaps += 1;
            const cnt = h.nonBgPixels(cap, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
            if (cnt > last_count + 4) {
                detected = t_inject.elapsedMs();
                new_count = cnt;
                break;
            }
        }
        if (detected == null) {
            std.debug.print("FAIL [{c}]: no cell-row change within {d:.0}ms\n", .{ ch, input_deadline_ms });
            any_failure = true;
            continue;
        }
        if (detected.? > 50) {
            std.debug.print("WARN [{c}]: latency {d:.1}ms ({} captures) — above 50ms\n", .{ ch, detected.?, icaps });
        } else {
            std.debug.print("ok   [{c}]: {d:.1}ms ({} captures, delta +{} non-bg pixels)\n", .{ ch, detected.?, icaps, new_count - last_count });
        }
        last_count = new_count;
    }

    // ── Phase 3: cadenced keys, look for CPU→GPU swap stalls ──────────

    h.killChild(pid);
    const pid2 = try h.spawnArgv(&scrgo_argv);
    defer h.killChild(pid2);

    if (!(try harness.waitForAppId("scrgo", 5000))) {
        std.debug.print("FAIL: scrgo (run 2) toplevel did not appear\n", .{});
        std.process.exit(1);
    }
    _ = try harness.captureFrame();
    const base_cap = try harness.captureFrame();
    var prev_count: u64 = h.nonBgPixels(base_cap, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
    std.debug.print("\nphase-3: cadenced keypresses (covers CPU→GPU swap)\n", .{});
    std.debug.print("phase-3: baseline cell-row non-bg = {}\n", .{prev_count});

    const cadence = "abcdefghiabc";
    var latencies_ms: [cadence.len]f64 = undefined;
    var dropped: usize = 0;
    for (cadence, 0..) |ch, i| {
        const code = h.keyEvdev(ch) orelse {
            latencies_ms[i] = -1;
            dropped += 1;
            continue;
        };
        try harness.typeKey(code);
        const t_inject = perf.Timer.now();
        var detected_ms: f64 = -1;
        while (t_inject.elapsedMs() < input_deadline_ms) {
            const cap = try harness.captureFrame();
            const cnt = h.nonBgPixels(cap, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);
            if (cnt > prev_count + 4) {
                detected_ms = t_inject.elapsedMs();
                prev_count = cnt;
                break;
            }
        }
        latencies_ms[i] = detected_ms;
        if (detected_ms < 0) dropped += 1;
    }

    var sum_ms: f64 = 0;
    var max_ms: f64 = 0;
    var ok_n: usize = 0;
    for (latencies_ms) |ms| {
        if (ms < 0) continue;
        sum_ms += ms;
        max_ms = @max(max_ms, ms);
        ok_n += 1;
    }
    const mean_ms: f64 = if (ok_n > 0) sum_ms / @as(f64, @floatFromInt(ok_n)) else 0;

    std.debug.print("phase-3 latencies (ms):", .{});
    for (latencies_ms) |ms| {
        if (ms < 0) std.debug.print(" -", .{}) else std.debug.print(" {d:.1}", .{ms});
    }
    std.debug.print("  mean={d:.1} max={d:.1}\n", .{ mean_ms, max_ms });

    if (dropped > 0) {
        std.debug.print("FAIL phase-3: {} of {} keys missed within {d:.0}ms\n", .{ dropped, cadence.len, input_deadline_ms });
        any_failure = true;
    }
    if (max_ms > 25 and ok_n >= 4 and max_ms > 2.0 * mean_ms) {
        std.debug.print("FAIL phase-3: max latency {d:.1}ms is >2× mean {d:.1}ms — possible frame stall\n", .{ max_ms, mean_ms });
        any_failure = true;
    }

    if (any_failure) {
        std.debug.print("FAIL: integration test\n", .{});
        std.process.exit(1);
    }
    std.debug.print("PASS: integration test\n", .{});
}
