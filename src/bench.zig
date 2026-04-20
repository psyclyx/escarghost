const std = @import("std");
const terminal_mod = @import("terminal.zig");
const config_mod = @import("config.zig");
const perf = @import("perf.zig");

/// Headless frame-time benchmark. Measures the CPU cost of:
/// - ghostty_terminal_vt_write (VT parsing)
/// - ghostty_render_state_update
/// - Cell iteration + vertex batch building (no actual GL draw)
///
/// This isolates the CPU-side work from GPU/driver overhead.
pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var cfg = try config_mod.load(allocator);
    defer cfg.deinit(allocator);

    const cols: u16 = 200;
    const rows: u16 = 60;

    var term: terminal_mod.Terminal = undefined;
    try term.init(cols, rows, 10000, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // Fill the screen with colored text (simulates a busy terminal)
    var fill_buf: [16384]u8 = undefined;
    var pos: usize = 0;
    for (0..rows) |row| {
        // Alternate colors per row
        const color_seq = if (row % 2 == 0) "\x1b[32m" else "\x1b[33m";
        @memcpy(fill_buf[pos..][0..color_seq.len], color_seq);
        pos += color_seq.len;
        for (0..cols) |col| {
            fill_buf[pos] = @intCast(0x21 + (col + row) % 94); // printable ASCII
            pos += 1;
        }
        fill_buf[pos] = '\r';
        pos += 1;
        fill_buf[pos] = '\n';
        pos += 1;
    }
    // Reset color
    const reset = "\x1b[0m";
    @memcpy(fill_buf[pos..][0..reset.len], reset);
    pos += reset.len;

    term.feedData(fill_buf[0..pos]);

    // Warm up
    for (0..10) |_| {
        try term.updateRenderState();
        term.resetDirty();
        // Re-dirty by feeding a no-op sequence
        term.feedData("\x1b[H"); // cursor home
    }

    // Benchmark: update + iterate
    const iterations = 1000;

    // Bench 1: render state update
    {
        const t = perf.Timer.now();
        for (0..iterations) |_| {
            try term.updateRenderState();
            term.resetDirty();
            term.feedData("\x1b[H");
        }
        const total_us = t.elapsedUs();
        std.debug.print("render_state_update: {d:.1}µs/iter ({} iters)\n", .{ total_us / iterations, iterations });
    }

    // Bench 2: full cell iteration (what the renderer does minus GL)
    {
        try term.updateRenderState();
        const t = perf.Timer.now();
        for (0..iterations) |_| {
            term.beginRowIteration();
            var text_cells: usize = 0;
            while (term.nextRow()) {
                term.beginCellIteration();
                while (term.nextCell()) {
                    const cell = term.getCellInfo();
                    if (cell.has_text and cell.codepoint > 0x20) {
                        text_cells += 1;
                    }
                }
            }
            // prevent optimization
            if (text_cells == 0) unreachable;
        }
        const total_us = t.elapsedUs();
        const cells_per_frame = @as(usize, cols) * rows;
        std.debug.print("cell_iteration: {d:.1}µs/frame, {d:.0}ns/cell ({} cells, {} iters)\n", .{
            total_us / iterations,
            (total_us * 1000.0) / @as(f64, @floatFromInt(iterations * cells_per_frame)),
            cells_per_frame,
            iterations,
        });
    }

    // Bench 3: VT throughput
    {
        // Generate 1MB of mixed content
        const chunk_size = 1024 * 1024;
        const chunk = try allocator.alloc(u8, chunk_size);
        defer allocator.free(chunk);
        for (0..chunk_size) |i| {
            chunk[i] = @intCast(0x20 + (i % 95));
        }

        const vt_iters = 100;
        const t = perf.Timer.now();
        for (0..vt_iters) |_| {
            term.feedData(chunk);
        }
        const total_us = t.elapsedUs();
        const total_mb = @as(f64, @floatFromInt(chunk_size * vt_iters)) / (1024.0 * 1024.0);
        const mbps = total_mb / (total_us / 1_000_000.0);
        std.debug.print("vt_throughput: {d:.0} MB/s ({d:.1}MB in {d:.1}ms)\n", .{ mbps, total_mb, total_us / 1000.0 });
    }

    std.debug.print("bench: done\n", .{});
}
