const snail = @import("snail");
const terminal_mod = @import("terminal.zig");
const render_common = @import("render_common.zig");
const color = @import("color.zig");
const Rgb = color.Rgb;

pub const MaxCols: u16 = 400;
pub const MaxRows: u16 = 200;
pub const MaxCells: usize = @as(usize, MaxCols) * MaxRows;

pub const CursorStyle = enum(u8) {
    bar,
    block,
    underline,
    block_hollow,
};

pub const CellFlags = packed struct(u8) {
    has_text: bool = false,
    has_fg: bool = false,
    has_bg: bool = false,
    inverse: bool = false,
    faint: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    reserved: bool = false,
};

pub const Cell = struct {
    codepoint: u32 = 0,
    glyph_id: u16 = 0,
    fg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    bg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    flags: u8 = 0,
};

pub const Header = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cell_count: u32 = 0,
    default_fg: Rgb = .{ .r = 255, .g = 255, .b = 255 },
    default_bg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    cursor_color: Rgb = .{ .r = 255, .g = 255, .b = 255 },
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_style: CursorStyle = .block,
    cursor_visible: u8 = 0,
    cursor_in_viewport: u8 = 0,
    cursor_has_color: u8 = 0,
    reserved: u8 = 0,
};

pub const SharedSnapshot = struct {
    header: Header = .{},
    cells: [MaxCells]Cell = [_]Cell{.{}} ** MaxCells,
};

pub fn capture(snapshot: *SharedSnapshot, term: *terminal_mod.Terminal, atlas: *const snail.TextAtlas) !void {
    try term.updateRenderState();

    const colors = term.getColors();
    const cursor = term.getCursor();
    const primary = atlas.primaryFaceIndex() catch 0;

    snapshot.header.default_fg = colors.foreground;
    snapshot.header.default_bg = colors.background;
    snapshot.header.cursor_color = colors.cursor orelse colors.foreground;
    snapshot.header.cursor_x = cursor.x;
    snapshot.header.cursor_y = cursor.y;
    snapshot.header.cursor_style = switch (cursor.style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    snapshot.header.cursor_visible = @intFromBool(cursor.visible);
    snapshot.header.cursor_in_viewport = @intFromBool(cursor.in_viewport);
    snapshot.header.cursor_has_color = @intFromBool(colors.cursor != null);

    term.beginRowIteration();

    var row_count: u16 = 0;
    var max_cols: u16 = 0;
    var cell_index: usize = 0;

    while (row_count < MaxRows and term.nextRow()) : (row_count += 1) {
        term.beginCellIteration();

        var row_cols: u16 = 0;
        while (row_cols < MaxCols and term.nextCell()) : (row_cols += 1) {
            if (cell_index >= MaxCells) break;

            const info = term.getCellInfo();
            const flags: CellFlags = .{
                .has_text = info.has_text,
                .has_fg = info.fg != null,
                .has_bg = info.bg != null,
                .inverse = info.style.inverse != false,
                .faint = info.style.faint != false,
                .underline = info.style.underline != 0,
                .strikethrough = info.style.strikethrough != false,
            };

            const glyph_id: u16 = blk: {
                if (!info.has_text) break :blk 0;
                if (!render_common.isRenderableCodepoint(info.codepoint)) break :blk 0;
                const cp: u21 = @intCast(info.codepoint);
                if (atlas.glyphIndex(primary, cp) catch null) |gid| break :blk gid;
                break :blk 0;
            };

            snapshot.cells[cell_index] = .{
                .codepoint = info.codepoint,
                .glyph_id = glyph_id,
                .fg = info.fg orelse colors.foreground,
                .bg = info.bg orelse colors.background,
                .flags = @bitCast(flags),
            };
            cell_index += 1;
        }

        if (row_cols > max_cols) max_cols = row_cols;
    }

    snapshot.header.cols = max_cols;
    snapshot.header.rows = row_count;
    snapshot.header.cell_count = @intCast(cell_index);
}
