//! Headless tests for the Terminal wrapper around libghostty-vt: they
//! exercise the render-state iteration the renderer uses, without
//! requiring a GL context or a Wayland compositor. Run via `zig build
//! test-headless` (or `zig build test`).

const std = @import("std");
const testing = std.testing;
const terminal_mod = @import("terminal.zig");
const config_mod = @import("config.zig");

// Pull in pure-Zig modules whose tests should run alongside the
// terminal-wrapper checks. Anything that doesn't transitively need libghostty
// can hang off here without paying for a separate test target.
comptime {
    _ = @import("selection.zig");
}

const default_sequences = [_][]const u8{
    "Hello, World!\r\n",
    "\x1b[1;32mgreen bold\x1b[0m normal\r\n",
    "\x1b[31mred\x1b[0m \x1b[7minverse\x1b[0m \x1b[2mfaint\x1b[0m\r\n",
    "\x1b[4munderline\x1b[0m \x1b[9mstrike\x1b[0m\r\n",
    "$ some command\r\n",
    "\x1b[?25l", // hide cursor
    "\x1b[?25h", // show cursor
    "\x1b[5 q", // bar cursor
    "\x1b[1 q", // block cursor
    "\x1b[H", // home
    "\x1b[2J", // clear screen
    "After clear\r\n",
    "café résumé naïve\r\n",
    "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+-=\r\n",
};

fn loadConfig(allocator: std.mem.Allocator) !config_mod.Config {
    return try config_mod.load(allocator);
}

const GridStats = struct {
    rows: u16,
    total_cells: usize,
    text_cells: usize,
    bg_cells: usize,
    inverse_cells: usize,
    bad_codepoints: usize,
};

fn iterateGrid(term: *terminal_mod.Terminal) GridStats {
    var stats: GridStats = .{
        .rows = 0,
        .total_cells = 0,
        .text_cells = 0,
        .bg_cells = 0,
        .inverse_cells = 0,
        .bad_codepoints = 0,
    };
    term.beginRowIteration();
    while (term.nextRow()) : (stats.rows += 1) {
        term.beginCellIteration();
        while (term.nextCell()) {
            stats.total_cells += 1;
            const cell = term.getCellInfo();
            if (cell.has_text and cell.codepoint > 0x20) {
                stats.text_cells += 1;
                if (cell.codepoint >= 0x110000) stats.bad_codepoints += 1;
            }
            if (cell.bg != null) stats.bg_cells += 1;
            if (cell.style.inverse != false) stats.inverse_cells += 1;
        }
    }
    return stats;
}

test "render state iteration over a populated 80x24 grid" {
    const allocator = testing.allocator;
    var cfg = try loadConfig(allocator);
    defer cfg.deinit(allocator);

    const cols: u16 = 80;
    const rows: u16 = 24;
    var term: terminal_mod.Terminal = undefined;
    try term.init(cols, rows, 1000, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    for (default_sequences) |seq| term.feedData(seq);
    try term.updateRenderState();

    const stats = iterateGrid(&term);
    try testing.expectEqual(rows, stats.rows);
    try testing.expectEqual(@as(usize, cols) * rows, stats.total_cells);
    try testing.expect(stats.text_cells > 0);
    try testing.expectEqual(@as(usize, 0), stats.bad_codepoints);
}

test "cursor style switch preserves grid contents" {
    const allocator = testing.allocator;
    var cfg = try loadConfig(allocator);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(80, 24, 1000, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    for (default_sequences) |seq| term.feedData(seq);
    try term.updateRenderState();
    const before = iterateGrid(&term);

    term.feedData("\x1b[5 q"); // bar cursor
    try term.updateRenderState();
    term.feedData("\x1b[1 q"); // block cursor
    try term.updateRenderState();

    const after = iterateGrid(&term);
    try testing.expectEqual(before.text_cells, after.text_cells);
    try testing.expectEqual(@as(usize, 0), after.bad_codepoints);
}

test "resize narrows the grid" {
    const allocator = testing.allocator;
    var cfg = try loadConfig(allocator);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(80, 24, 1000, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    term.feedData("seed line\r\n");
    try term.resize(40, 12, 9, 17);
    term.feedData("after resize\r\n");
    try term.updateRenderState();

    const stats = iterateGrid(&term);
    try testing.expectEqual(@as(u16, 12), stats.rows);
}

test "inverse / bold / italic style flags propagate through render state" {
    const allocator = testing.allocator;
    var cfg = try loadConfig(allocator);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(40, 5, 100, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    term.feedData("\x1b[7minverse\x1b[0m \x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m");
    try term.updateRenderState();

    term.beginRowIteration();
    try testing.expect(term.nextRow());
    term.beginCellIteration();

    var found_inverse = false;
    var found_bold = false;
    var found_italic = false;
    var ci: u16 = 0;
    while (term.nextCell()) : (ci += 1) {
        if (ci >= 25) break;
        const sc = term.getCellInfo();
        if (!sc.has_text or sc.codepoint <= 0x20) continue;
        if (sc.style.inverse != false) found_inverse = true;
        if (sc.style.bold != false) found_bold = true;
        if (sc.style.italic != false) found_italic = true;
    }
    try testing.expect(found_inverse);
    try testing.expect(found_bold);
    try testing.expect(found_italic);
}
