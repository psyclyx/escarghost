//! Shared row-building primitives used by both the GPU (renderer.zig) and
//! CPU (shm_render.zig) paths. Iterates a row's cells, accumulates same-fg
//! text into HarfBuzz-shaped runs, coalesces background spans, and emits
//! underline / strikethrough decoration rects.
//!
//! Coordinates are produced relative to a caller-supplied `row_y` offset:
//! pass `0` for a row-local cache entry, or the row's absolute Y to bake
//! it in. Backends decide.

const std = @import("std");
const snail = @import("snail");
const render_snapshot = @import("render_snapshot.zig");
const render_common = @import("render_common.zig");
const glyph_misses = @import("glyph_misses.zig");
const color = @import("color.zig");
const Rgb = color.Rgb;

pub const baseline_factor: f32 = 0.8;
pub const MAX_RECTS_PER_ROW: usize = @as(usize, render_snapshot.MaxCols) * 3;

pub const ColoredRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
};

pub const Metrics = struct {
    cell_width: f32,
    cell_height: f32,
    font_size: f32,

    pub fn baseline(self: Metrics) f32 {
        return self.cell_height * baseline_factor;
    }
};

pub const BuildResult = struct {
    rect_count: usize,
    had_misses: bool,
};

/// Accumulates a same-color text run so HB can shape it as a unit
/// (ligatures form across cells inside the run, but never across a
/// color change or a decorated cell).
const RunAccumulator = struct {
    text: [2048]u8 = undefined,
    text_len: usize = 0,
    start_col: u16 = 0,
    fg: ?Rgb = null,

    fn reset(self: *RunAccumulator) void {
        self.text_len = 0;
        self.fg = null;
    }

    fn isEmpty(self: *const RunAccumulator) bool {
        return self.text_len == 0;
    }

    fn appendCell(self: *RunAccumulator, codepoint: u32, col: u16, fg: Rgb) void {
        if (self.fg == null) {
            self.start_col = col;
            self.fg = fg;
        }
        if (self.text_len + 4 > self.text.len) return;
        const n = std.unicode.utf8Encode(@intCast(codepoint), self.text[self.text_len..]) catch 0;
        if (n == 0) return;
        self.text_len += n;
    }

    fn fgMatches(self: *const RunAccumulator, fg: Rgb) bool {
        const cur = self.fg orelse return false;
        return cur.r == fg.r and cur.g == fg.g and cur.b == fg.b;
    }
};

/// Shape the run via HB so ligatures form, then let HB's natural glyph
/// advances do placement. Cell width matches the font's natural advance,
/// so a well-behaved monospace font's ligatures span exactly the right
/// number of cells.
fn flushRun(
    run: *RunAccumulator,
    builder: *snail.TextBlobBuilder,
    atlas: *const snail.TextAtlas,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    row_y: f32,
    misses: *glyph_misses.Set,
) !bool {
    if (run.isEmpty()) return false;
    const fg = run.fg.?;
    const opts_x = @as(f32, @floatFromInt(run.start_col)) * metrics.cell_width;
    var shaped = try atlas.shapeText(allocator, .{}, run.text[0..run.text_len]);
    defer shaped.deinit();
    const result = try builder.append(.{
        .shaped = &shaped,
        .placement = .{
            .baseline = .{ .x = opts_x, .y = row_y + metrics.baseline() },
            .em = metrics.font_size,
        },
        .fill = .{ .solid = fg.toFloat4(1.0) },
    });
    const had_misses = result.missing;
    if (had_misses) misses.addRun(run.text[0..run.text_len]);
    run.reset();
    return had_misses;
}

/// Build one row of glyphs (into `builder`) and rects (into `scratch_rects`).
///
/// Coordinates are biased by `row_y`: pass 0 for a row-local cache entry,
/// or the row's absolute Y to bake the position into the output. The caller
/// must `builder.reset()` before calling, and may `builder.finish()` after.
///
/// `cell_index` is advanced past the cells consumed (up to `cols`).
pub fn buildRow(
    snapshot: *const render_snapshot.SharedSnapshot,
    cell_index: *usize,
    cols: u16,
    row_y: f32,
    scratch_rects: []ColoredRect,
    builder: *snail.TextBlobBuilder,
    atlas: *const snail.TextAtlas,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    misses: *glyph_misses.Set,
) !BuildResult {
    var rect_count: usize = 0;
    var had_misses = false;

    const default_fg = snapshot.header.default_fg;
    const default_bg = snapshot.header.default_bg;

    var bg_span_start: u16 = 0;
    var bg_span_color: ?Rgb = null;
    var bg_span_len: u16 = 0;

    var run = RunAccumulator{};

    var col_idx: u16 = 0;
    while (col_idx < cols and cell_index.* < snapshot.header.cell_count) : ({
        col_idx += 1;
        cell_index.* += 1;
    }) {
        const cell = snapshot.cells[cell_index.*];
        const flags: render_snapshot.CellFlags = @bitCast(cell.flags);
        const resolved = render_common.resolveCellColors(
            default_fg,
            default_bg,
            if (flags.has_fg) cell.fg else null,
            if (flags.has_bg) cell.bg else null,
            flags.inverse,
            flags.faint,
        );
        const fg = resolved.fg;
        const cell_bg = resolved.bg;

        const bg_matches = if (cell_bg) |cbg|
            if (bg_span_color) |sc| sc.r == cbg.r and sc.g == cbg.g and sc.b == cbg.b else false
        else
            false;
        if (cell_bg != null and bg_matches) {
            bg_span_len += 1;
        } else {
            if (bg_span_len > 0) {
                if (bg_span_color) |sc| {
                    if (rect_count < scratch_rects.len) {
                        scratch_rects[rect_count] = .{
                            .x = @as(f32, @floatFromInt(bg_span_start)) * metrics.cell_width,
                            .y = row_y,
                            .w = @as(f32, @floatFromInt(bg_span_len)) * metrics.cell_width,
                            .h = metrics.cell_height,
                            .color = sc.toFloat4(1.0),
                        };
                        rect_count += 1;
                    }
                }
            }
            if (cell_bg) |cbg| {
                bg_span_start = col_idx;
                bg_span_color = cbg;
                bg_span_len = 1;
            } else {
                bg_span_color = null;
                bg_span_len = 0;
            }
        }

        const has_renderable_text = flags.has_text and snail.isRenderableTextCodepoint(cell.codepoint);
        // Break the run on: non-text cell, fg color change, or any cell with
        // underline/strikethrough (so decorations don't bleed across a
        // ligature glyph that spans cells).
        const break_run = !has_renderable_text or flags.underline or flags.strikethrough or
            (run.fg != null and !run.fgMatches(fg));
        if (break_run and !run.isEmpty()) {
            if (try flushRun(&run, builder, atlas, allocator, metrics, row_y, misses)) had_misses = true;
        }

        if (has_renderable_text) {
            run.appendCell(cell.codepoint, col_idx, fg);
            // Cells with decorations don't ligate with neighbors.
            if (flags.underline or flags.strikethrough) {
                if (try flushRun(&run, builder, atlas, allocator, metrics, row_y, misses)) had_misses = true;
            }
        }

        if (flags.underline and rect_count < scratch_rects.len) {
            scratch_rects[rect_count] = .{
                .x = @as(f32, @floatFromInt(col_idx)) * metrics.cell_width,
                .y = row_y + metrics.cell_height - 1,
                .w = metrics.cell_width,
                .h = 1,
                .color = fg.toFloat4(1.0),
            };
            rect_count += 1;
        }
        if (flags.strikethrough and rect_count < scratch_rects.len) {
            scratch_rects[rect_count] = .{
                .x = @as(f32, @floatFromInt(col_idx)) * metrics.cell_width,
                .y = row_y + metrics.cell_height * 0.45,
                .w = metrics.cell_width,
                .h = 1,
                .color = fg.toFloat4(1.0),
            };
            rect_count += 1;
        }
    }

    if (!run.isEmpty()) {
        if (try flushRun(&run, builder, atlas, allocator, metrics, row_y, misses)) had_misses = true;
    }

    if (bg_span_len > 0) {
        if (bg_span_color) |sc| {
            if (rect_count < scratch_rects.len) {
                scratch_rects[rect_count] = .{
                    .x = @as(f32, @floatFromInt(bg_span_start)) * metrics.cell_width,
                    .y = row_y,
                    .w = @as(f32, @floatFromInt(bg_span_len)) * metrics.cell_width,
                    .h = metrics.cell_height,
                    .color = sc.toFloat4(1.0),
                };
                rect_count += 1;
            }
        }
    }

    return .{ .rect_count = rect_count, .had_misses = had_misses };
}
