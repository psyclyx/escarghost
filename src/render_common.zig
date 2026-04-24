const color = @import("color.zig");
const Rgb = color.Rgb;

pub const ResolvedCellColors = struct {
    fg: Rgb,
    bg: ?Rgb,
};

pub const CursorCell = struct {
    has_text: bool,
    codepoint: u32,
    glyph_id: u16,
    bg: Rgb,
};

pub fn isRenderableCodepoint(codepoint: u32) bool {
    return codepoint > 0x20 and codepoint < 0x110000;
}

pub fn resolveCellColors(
    default_fg: Rgb,
    default_bg: Rgb,
    fg_override: ?Rgb,
    bg_override: ?Rgb,
    inverse: bool,
    faint: bool,
) ResolvedCellColors {
    var fg = fg_override orelse default_fg;
    var bg = bg_override;
    if (inverse) {
        const tmp = fg;
        fg = bg orelse default_bg;
        bg = tmp;
    }
    if (faint) {
        fg = .{
            .r = @intFromFloat(@as(f32, @floatFromInt(fg.r)) * 0.5),
            .g = @intFromFloat(@as(f32, @floatFromInt(fg.g)) * 0.5),
            .b = @intFromFloat(@as(f32, @floatFromInt(fg.b)) * 0.5),
        };
    }
    return .{ .fg = fg, .bg = bg };
}

pub fn captureCursorCell(default_bg: Rgb, codepoint: u32, glyph_id: u16, has_text: bool, colors: ResolvedCellColors) CursorCell {
    return .{
        .has_text = has_text,
        .codepoint = codepoint,
        .glyph_id = glyph_id,
        .bg = colors.bg orelse default_bg,
    };
}
