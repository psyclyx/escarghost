//! Input-latency scenario. Spawn terminal with `cat`, inject keys via
//! virtual_keyboard, time each one's roundtrip to a pixel change in a
//! top-left probe region.

const std = @import("std");
const perf = @import("perf.zig");
const h = @import("wlr_harness.zig");
const stats_mod = @import("bench_stats.zig");
const spec_mod = @import("bench_spec.zig");

pub const Options = struct {
    samples: u32 = 30,
    cat: []const u8,
};

pub fn measureTerminal(harness: *h.Harness, spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !stats_mod.Stats {
    var argv_buf: [16][]const u8 = undefined;
    const extras = [_][]const u8{opts.cat};
    const argv = spec_mod.buildArgv(&argv_buf, bin, spec, &extras);

    const pid = try h.spawnArgv(argv);
    defer h.killChild(pid);

    if (!(try harness.waitForAppId(spec.app_id, 5000))) {
        std.debug.print("[{s}] toplevel '{s}' did not appear within 5s\n", .{ spec.label, spec.app_id });
        return .{ .dropped = opts.samples };
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
    // shaper warmup, etc.).
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
    const post_warmup = try harness.captureFrame();
    var prev_count: u64 = h.nonBgPixels(post_warmup, stride, pix_fmt, probe_x, probe_y, probe_w, probe_h, bg, non_bg_thresh);

    var s: u32 = 0;
    while (s < opts.samples) : (s += 1) {
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

    _ = try harness.dispatchOnce(20);
    return stats_mod.summarize(lat.items, dropped);
}
