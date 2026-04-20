const std = @import("std");
const terminal_mod = @import("terminal.zig");
const config_mod = @import("config.zig");
const color = @import("color.zig");

/// Headless test that exercises terminal + render state iteration
/// without requiring a GL context. Catches cell-reading bugs,
/// codepoint issues, and render state crashes.
pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var cfg = try config_mod.load(allocator);
    defer cfg.deinit(allocator);

    const cols: u16 = 80;
    const rows: u16 = 24;

    var term: terminal_mod.Terminal = undefined;
    try term.init(cols, rows, 1000, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // Feed some VT data — simulate a shell prompt + colored output
    const test_sequences = [_][]const u8{
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
        // Wide chars and unicode
        "café résumé naïve\r\n",
        // Long line
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+-=\r\n",
    };

    for (test_sequences) |seq| {
        term.feedData(seq);
    }

    // Now iterate the render state exactly like the renderer does
    try term.updateRenderState();

    const colors = term.getColors();
    const cursor = term.getCursor();

    std.debug.print("colors: fg=({},{},{}) bg=({},{},{})\n", .{
        colors.foreground.r, colors.foreground.g, colors.foreground.b,
        colors.background.r, colors.background.g, colors.background.b,
    });
    std.debug.print("cursor: visible={} in_vp={} x={} y={} style={}\n", .{
        cursor.visible, cursor.in_viewport, cursor.x, cursor.y, @intFromEnum(cursor.style),
    });

    // Iterate all rows and cells
    var total_cells: usize = 0;
    var text_cells: usize = 0;
    var bg_cells: usize = 0;
    var inverse_cells: usize = 0;
    var bad_codepoints: usize = 0;

    term.beginRowIteration();
    var row_idx: u16 = 0;
    while (term.nextRow()) : (row_idx += 1) {
        term.beginCellIteration();
        var col_idx: u16 = 0;
        while (term.nextCell()) : (col_idx += 1) {
            total_cells += 1;
            const cell = term.getCellInfo();

            if (cell.has_text and cell.codepoint > 0x20) {
                text_cells += 1;
                if (cell.codepoint >= 0x110000) {
                    bad_codepoints += 1;
                    std.debug.print("BAD CODEPOINT: row={} col={} cp=0x{x}\n", .{ row_idx, col_idx, cell.codepoint });
                }
            }
            if (cell.bg != null) bg_cells += 1;
            if (cell.style.inverse != false) inverse_cells += 1;
        }
    }

    std.debug.print("grid: {} rows iterated, {} total cells\n", .{ row_idx, total_cells });
    std.debug.print("  text_cells={} bg_cells={} inverse_cells={} bad_codepoints={}\n", .{ text_cells, bg_cells, inverse_cells, bad_codepoints });

    if (row_idx != rows) {
        std.debug.print("FAIL: expected {} rows, got {}\n", .{ rows, row_idx });
        std.process.exit(1);
    }
    if (total_cells != @as(usize, cols) * rows) {
        std.debug.print("FAIL: expected {} cells, got {}\n", .{ @as(usize, cols) * rows, total_cells });
        std.process.exit(1);
    }
    if (text_cells == 0) {
        std.debug.print("FAIL: no text cells found\n", .{});
        std.process.exit(1);
    }
    if (bad_codepoints > 0) {
        std.debug.print("FAIL: {} bad codepoints\n", .{bad_codepoints});
        std.process.exit(1);
    }

    // Test cursor style changes don't break iteration
    term.feedData("\x1b[5 q"); // bar cursor
    try term.updateRenderState();
    const cursor2 = term.getCursor();
    std.debug.print("cursor after bar: style={}\n", .{@intFromEnum(cursor2.style)});

    term.feedData("\x1b[1 q"); // block cursor
    try term.updateRenderState();
    const cursor3 = term.getCursor();
    std.debug.print("cursor after block: style={}\n", .{@intFromEnum(cursor3.style)});

    // Re-iterate after cursor change to make sure cells still readable
    term.beginRowIteration();
    var post_text: usize = 0;
    var post_bad: usize = 0;
    while (term.nextRow()) {
        term.beginCellIteration();
        while (term.nextCell()) {
            const cell = term.getCellInfo();
            if (cell.has_text and cell.codepoint > 0x20) {
                post_text += 1;
                if (cell.codepoint >= 0x110000) post_bad += 1;
            }
        }
    }
    std.debug.print("post cursor-change: text_cells={} bad={}\n", .{ post_text, post_bad });
    if (post_text != text_cells) {
        std.debug.print("FAIL: text cells changed after cursor switch ({} vs {})\n", .{ post_text, text_cells });
        std.process.exit(1);
    }

    // Test resize
    term.resize(40, 12, 9, 17) catch {};
    term.feedData("after resize\r\n");
    try term.updateRenderState();
    term.beginRowIteration();
    var resize_rows: u16 = 0;
    while (term.nextRow()) : (resize_rows += 1) {}
    std.debug.print("after resize to 40x12: {} rows\n", .{resize_rows});
    if (resize_rows != 12) {
        std.debug.print("FAIL: expected 12 rows after resize, got {}\n", .{resize_rows});
        std.process.exit(1);
    }

    // Test that styles are actually being read
    {
        var term2: terminal_mod.Terminal = undefined;
        try term2.init(40, 5, 100, cfg.palette, cfg.foreground, cfg.background);
        defer term2.deinit();

        term2.feedData("\x1b[7minverse\x1b[0m \x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m");
        try term2.updateRenderState();

        term2.beginRowIteration();
        _ = term2.nextRow(); // first row
        term2.beginCellIteration();

        // Verify styles by checking specific cells
        var ci: u16 = 0;
        var found_inverse = false;
        var found_bold = false;
        var found_italic = false;
        while (term2.nextCell()) : (ci += 1) {
            if (ci >= 25) break;
            const sc = term2.getCellInfo();
            if (sc.has_text and sc.codepoint > 0x20) {
                if (sc.style.inverse != false) found_inverse = true;
                if (sc.style.bold != false) found_bold = true;
                if (sc.style.italic != false) found_italic = true;
            }
        }
        if (!found_inverse) {
            std.debug.print("FAIL: inverse style not found\n", .{});
            std.process.exit(1);
        }
        if (!found_bold) {
            std.debug.print("FAIL: bold style not found\n", .{});
            std.process.exit(1);
        }
        if (!found_italic) {
            std.debug.print("FAIL: italic style not found\n", .{});
            std.process.exit(1);
        }
        std.debug.print("styles: inverse, bold, italic all detected\n", .{});
    }

    std.debug.print("PASS: all headless tests passed\n", .{});
}
