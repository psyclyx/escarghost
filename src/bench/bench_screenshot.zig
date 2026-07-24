//! Screenshot scenario. Spawn each terminal with a fixed test payload,
//! wait long enough for it to paint, capture one frame, dump it as PPM
//! to <out-dir>/<label>.ppm so the user can flip through them and spot
//! visual differences (font size, padding, color, etc).
//!
//! PPM is dead simple (ASCII header + raw RGB) so no extra deps; view
//! with feh, eog, or convert with `convert *.ppm out.png`.

const std = @import("std");
const h = @import("wlr_harness");
const posix = h.posix;
const spec_mod = @import("bench_spec.zig");

pub const Options = struct {
    sh_bin: []const u8,
    /// Fixed payload echo'd into each terminal so we're comparing
    /// the same content across all of them.
    payload: []const u8 = "the quick brown fox jumps over the lazy dog 0123456789\\nABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz\\n",
    /// How long to let the terminal sit after the echo before
    /// capturing. Gives bigger terminals time to repaint.
    settle_ms: u32 = 500,
    out_dir: []const u8 = "/tmp",
};

pub fn captureOne(io: std.Io, harness: *h.Harness, spec: spec_mod.TerminalSpec, bin: []const u8, opts: Options) !void {
    // We use `printf` rather than `echo -e` because the latter's
    // behavior across shells/builtins varies.
    var script_buf: [4096]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, "printf '{s}'; sleep 5", .{opts.payload});
    var argv_buf: [16][]const u8 = undefined;
    const extras = [_][]const u8{ opts.sh_bin, "-c", script };
    const argv = spec_mod.buildArgv(&argv_buf, bin, spec, &extras);

    const pid = try h.spawnArgv(argv);
    defer {
        h.killChild(pid);
        harness.waitAllToplevelsClosed(1000) catch {};
    }

    if (!(try harness.waitForAppId(spec.app_id, 5000))) return error.NoToplevel;

    // Let the terminal paint a few frames first.
    var i: u32 = 0;
    while (i < 8) : (i += 1) _ = try harness.captureFrame();

    // Sleep through settle_ms while continuing to dispatch wayland.
    const settle_dl_ms = @as(i128, opts.settle_ms);
    const start_ns = h.nowNs();
    while (h.nowNs() - start_ns < settle_dl_ms * 1_000_000) {
        _ = try harness.captureFrame();
    }

    const frame = try harness.captureFrame();
    const stride = harness.cached_frame.stride;
    const width = harness.cached_frame.width;
    const height = harness.cached_frame.height;
    const fmt = h.pixelFmtFromShm(harness.cached_frame.format) orelse return error.UnsupportedFmt;

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/bench-{s}.ppm", .{ opts.out_dir, spec.label });
    try writePpm(io, path, frame, width, height, stride, fmt);
    std.debug.print("{s:<10}  {s}\n", .{ spec.label, path });
}

fn writePpm(io: std.Io, path: [:0]const u8, frame: []const u8, width: u32, height: u32, stride: u32, fmt: h.PixelFmt) !void {
    const file = std.Io.Dir.cwd.createFile(io, path, .{ .read = false, .truncate = true }) catch return error.OpenFailed;
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);

    var hdr_buf: [64]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "P6\n{} {}\n255\n", .{ width, height });
    try writer.interface.writeAll(hdr);

    // Stream rows. PPM expects tightly-packed RGB, no padding; the
    // input has `stride` bytes per row which may include alpha/padding.
    var row_buf: [4096 * 3]u8 = undefined;
    if (width * 3 > row_buf.len) return error.RowTooWide;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const in_off = y * stride + x * fmt.bpp;
            if (in_off + fmt.bpp > frame.len) return error.OOB;
            const out_off = x * 3;
            row_buf[out_off] = frame[in_off + fmt.r_off];
            row_buf[out_off + 1] = frame[in_off + fmt.g_off];
            row_buf[out_off + 2] = frame[in_off + fmt.b_off];
        }
        const row_len: usize = @intCast(width * 3);
        try writer.interface.writeAll(row_buf[0..row_len]);
    }
    try writer.interface.flush();
}
