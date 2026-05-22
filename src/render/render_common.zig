const color = @import("color");
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

/// Scrollbar thumb and gutter geometry. Computed from a snapshot
/// ScrollbarOverlay + viewport dimensions; both renderers consume
/// this to draw a thin band on the right edge.
pub const ScrollbarGeometry = struct {
    /// Right-edge gutter rect: x, y, width, height in pixels.
    gutter_x: f32,
    gutter_y: f32,
    gutter_w: f32,
    gutter_h: f32,
    /// Thumb rect, in pixels. Always contained within the gutter.
    thumb_y: f32,
    thumb_h: f32,
};

pub const SCROLLBAR_PIXEL_WIDTH: f32 = 8.0;
pub const SCROLLBAR_MIN_THUMB_PX: f32 = 24.0;

pub fn scrollbarGeometry(viewport_w: f32, viewport_h: f32, thumb_offset: f32, thumb_size: f32) ScrollbarGeometry {
    const gutter_x = viewport_w - SCROLLBAR_PIXEL_WIDTH;
    const raw_thumb_h = @max(SCROLLBAR_MIN_THUMB_PX, thumb_size * viewport_h);
    const max_thumb_top = viewport_h - raw_thumb_h;
    const thumb_y = @max(0.0, @min(max_thumb_top, thumb_offset * viewport_h));
    return .{
        .gutter_x = gutter_x,
        .gutter_y = 0,
        .gutter_w = SCROLLBAR_PIXEL_WIDTH,
        .gutter_h = viewport_h,
        .thumb_y = thumb_y,
        .thumb_h = raw_thumb_h,
    };
}

/// Scrollbar gutter and thumb fill colors. Gutter is the default fg
/// at low alpha; thumb is fg at higher alpha. Both scale by the
/// snapshot's overlay alpha for fade-in / fade-out.
pub fn scrollbarColors(default_fg: Rgb, alpha: f32) struct { gutter: [4]f32, thumb: [4]f32 } {
    const a = @max(0.0, @min(1.0, alpha));
    const fg = default_fg.toFloat4(1.0);
    return .{
        .gutter = .{ fg[0], fg[1], fg[2], 0.08 * a },
        .thumb = .{ fg[0], fg[1], fg[2], 0.55 * a },
    };
}
