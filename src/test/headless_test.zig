//! Headless tests for the Terminal wrapper around libghostty-vt: they
//! exercise the render-state iteration the renderer uses, without
//! requiring a GL context or a Wayland compositor. Run via `zig build
//! test-headless` (or `zig build test`).

const std = @import("std");
const testing = std.testing;
const terminal_mod = @import("terminal_mod");
const config_mod = @import("config_mod");

// Pull in pure-Zig modules whose tests should run alongside the
// terminal-wrapper checks. Anything that doesn't transitively need libghostty
// can hang off here without paying for a separate test target.
comptime {
    _ = @import("selection_mod");
}

/// Build a thread-safe `Io` instance for tests. The caller must keep
/// `t` alive for as long as `io` is used.
fn testIo(t: *std.Io.Threaded) std.Io {
    t.* = std.Io.Threaded.init(testing.allocator, .{});
    return t.io();
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

fn loadConfig(allocator: std.mem.Allocator, io: std.Io) !config_mod.Config {
    return try config_mod.load(allocator, io, null);
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
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    const cols: u16 = 80;
    const rows: u16 = 24;
    var term: terminal_mod.Terminal = undefined;
    try term.init(io, cols, rows, 1000, cfg.palette, cfg.foreground, cfg.background);
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
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(io, 80, 24, 1000, cfg.palette, cfg.foreground, cfg.background);
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
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(io, 80, 24, 1000, cfg.palette, cfg.foreground, cfg.background);
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
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(io, 40, 5, 100, cfg.palette, cfg.foreground, cfg.background);
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

// ── clipboard / scrollbar / encodePaste ──────────────────────────────

test "encodePaste round-trips ascii unchanged when bracketed-paste is off" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(io, 40, 5, 100, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    try testing.expect(!term.isBracketedPaste());
    const out = (try term.encodePaste(allocator, "hello world")) orelse return error.NoOutput;
    defer allocator.free(out);
    try testing.expectEqualSlices(u8, "hello world", out);
}

test "encodePaste wraps bracketed paste markers when 2004h is set" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(io, 40, 5, 100, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    term.feedData("\x1b[?2004h");
    try term.updateRenderState();
    try testing.expect(term.isBracketedPaste());

    const out = (try term.encodePaste(allocator, "ab")) orelse return error.NoOutput;
    defer allocator.free(out);
    // The encoded buffer must contain the bracketed-paste start
    // (\e[200~) before "ab" and the end (\e[201~) after.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[200~") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[201~") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ab") != null);
}

test "scrollbar getter reports total/offset/len once content overflows" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    const cols: u16 = 40;
    const rows: u16 = 5;
    var term: terminal_mod.Terminal = undefined;
    try term.init(io, cols, rows, 200, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // Empty terminal: total == len, no scrollback to show.
    const sb0 = term.scrollbar();
    try testing.expectEqual(@as(u64, rows), sb0.len);
    try testing.expectEqual(@as(u64, rows), sb0.total);

    // Feed a bunch of lines so scrollback grows past the viewport.
    var i: usize = 0;
    while (i < 50) : (i += 1) term.feedData("line\r\n");
    try term.updateRenderState();
    const sb1 = term.scrollbar();
    try testing.expectEqual(@as(u64, rows), sb1.len);
    try testing.expect(sb1.total > sb1.len);
    // At bottom, offset = total - len.
    try testing.expectEqual(sb1.total - sb1.len, sb1.offset);
}

test "fillRowFromScreen reads rows that have scrolled into scrollback" {
    // Regression guard for selection extraction across scrollback:
    // feed 50 unique lines into a 5-row terminal, then verify that
    // the rows now sitting in scrollback are still reachable via the
    // grid_ref walker (the visible viewport only shows the last 5).
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    const cols: u16 = 40;
    const rows: u16 = 5;
    var term: terminal_mod.Terminal = undefined;
    try term.init(io, cols, rows, 5000, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var line: [16]u8 = undefined;
        const written = try std.fmt.bufPrint(&line, "line {d:0>3}\r\n", .{i});
        term.feedData(written);
    }
    try term.updateRenderState();

    // Pick a row deep in scrollback. With 50 fed lines × scroll, the
    // first line ("line 000") sits near the top of the scrollback.
    var buf: [40]u32 = undefined;
    const n = term.fillRowFromScreen(0, &buf);
    try testing.expect(n > 0);

    // Re-encode the prefix to ASCII to compare against expected.
    var ascii: [40]u8 = undefined;
    var ascii_len: usize = 0;
    var col: usize = 0;
    while (col < n and ascii_len < ascii.len) : (col += 1) {
        const cp = buf[col];
        if (cp < 0x80) {
            ascii[ascii_len] = @intCast(cp);
            ascii_len += 1;
        }
    }
    var trim_end = ascii_len;
    while (trim_end > 0 and ascii[trim_end - 1] == ' ') trim_end -= 1;
    try testing.expectEqualStrings("line 000", ascii[0..trim_end]);
}

test "max_scrollback config in lines actually yields ~that many lines" {
    // Regression: ghostty's `max_scrollback` field is bytes, not lines
    // (its C header docstring lies). terminal.init now converts the
    // line budget to bytes via BYTES_PER_SCROLLBACK_LINE; pre-fix,
    // requesting 5000 lines gave us the 2-page floor (~430 rows).
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    const cols: u16 = 40;
    const rows: u16 = 5;
    const requested_lines: usize = 5000;
    var term: terminal_mod.Terminal = undefined;
    try term.init(io, cols, rows, requested_lines, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // Feed more lines than we ask the floor would give us. The post-
    // fix line budget should comfortably exceed 1000 rows of
    // scrollback; pre-fix this would cap at ~430.
    var i: usize = 0;
    while (i < 2000) : (i += 1) term.feedData("line\r\n");
    try term.updateRenderState();

    const sb = term.scrollbar();
    try testing.expect(sb.total > 1000);
}

test "colCount / rowCount mirror the configured grid" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try loadConfig(allocator, io);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(io, 80, 24, 100, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    try testing.expectEqual(@as(u16, 80), term.colCount());
    try testing.expectEqual(@as(u16, 24), term.rowCount());

    try term.resize(50, 10, 9, 17);
    try testing.expectEqual(@as(u16, 50), term.colCount());
    try testing.expectEqual(@as(u16, 10), term.rowCount());
}
