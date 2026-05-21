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

/// Translucent overlay color for the text selection band. Both render
/// paths use this so the highlight looks identical regardless of which
/// renderer is active. Picks a fixed neutral blue (#4f8cff) on dark
/// backgrounds and a darker version on light backgrounds so the
/// highlight stays visible without obscuring the underlying glyph.
pub fn selectionFillColor(default_bg: Rgb) [4]f32 {
    const luminance = (@as(u32, default_bg.r) * 30 + @as(u32, default_bg.g) * 59 + @as(u32, default_bg.b) * 11) / 100;
    if (luminance < 128) {
        // Dark bg → light cool-blue tint.
        return .{ 79.0 / 255.0, 140.0 / 255.0, 255.0 / 255.0, 0.45 };
    } else {
        // Light bg → deeper blue so glyphs remain legible.
        return .{ 31.0 / 255.0, 87.0 / 255.0, 184.0 / 255.0, 0.40 };
    }
}
