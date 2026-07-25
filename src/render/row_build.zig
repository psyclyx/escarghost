//! Shared row-building primitives used by both the GPU (Vulkan) and
//! CPU (snail-raster) render paths. Iterates a row's cells, accumulates
//! same-fg text into HarfBuzz-shaped runs via snail 0.13's shape/place
//! pipeline, coalesces background spans, and emits underline / strike
//! decoration rects.
//!
//! In snail 0.13, the flow is:
//!   cells → snail.shape → snail.recordUnhintedRun → snail.placeCellRunAlloc
//!   → snail.Shape[] → (caller) snail.emit.emit → Instance[] + DrawBatch[]
//!
//! Background/decoration rects are produced as ColoredRect values; the
//! caller turns them into snail.Path shapes or rasterizer rects.

const std = @import("std");
const snail = @import("snail");
const render_snapshot = @import("render_snapshot.zig");
const render_common = @import("render_common.zig");
const render_env = @import("render_env.zig");
const glyph_misses = @import("glyph_misses.zig");
const color = @import("color");
const selection_mod = @import("../selection.zig");
const atlas_ref_mod = @import("atlas_ref.zig");
const perf = @import("../perf.zig");
const log = @import("../log.zig");
const Rgb = color.Rgb;

// ── Phase counters (diagnostic) ──

pub var phase_row_rebuild_ns: u64 = 0;
pub var phase_row_shape_ns: u64 = 0;
pub var phase_row_finish_ns: u64 = 0;
pub var phase_row_count: u64 = 0;

// Hint diagnostic stubs (referenced by diagnostics.zig). The snail 0.13
// pipeline doesn't populate these yet.
pub var phase_hint_prepare_ns: u64 = 0;
pub var phase_hint_append_ns: u64 = 0;
pub var phase_hint_runs: u64 = 0;
pub var phase_hint_glyphs_hinted: u64 = 0;
pub var phase_hint_glyphs_fallback: u64 = 0;
pub const reject_reason_count: usize = 10;
pub var phase_hint_reject_counts: [reject_reason_count]u64 = .{0} ** reject_reason_count;

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
    baseline_offset: f32,

    pub fn baseline(self: Metrics) f32 {
        return self.baseline_offset;
    }
};

pub const BuildResult = struct {
    rect_count: usize,
    had_misses: bool,
};

/// Accumulates an entire row's renderable text in one HB-shapeable
/// buffer along with per-cell source ranges for snail 0.13's Cell API.
const RowAccumulator = struct {
    text: [render_snapshot.MaxCols * 4]u8 = undefined,
    text_len: usize = 0,
    byte_to_col: [render_snapshot.MaxCols * 4]u16 = undefined,
    col_fg: [render_snapshot.MaxCols]Rgb = undefined,
    /// snail.Cell entries — source ranges + column numbers + colors.
    cells: [render_snapshot.MaxCols]snail.Cell = undefined,
    cell_count: usize = 0,

    fn reset(self: *RowAccumulator) void {
        self.text_len = 0;
        self.cell_count = 0;
    }

    fn isEmpty(self: *const RowAccumulator) bool {
        return self.text_len == 0;
    }

    fn appendCell(self: *RowAccumulator, codepoint: u32, col: u16, fg: Rgb) void {
        if (self.text_len + 4 > self.text.len) return;
        if (col >= self.col_fg.len) return;
        if (self.cell_count >= self.cells.len) return;
        const start = self.text_len;
        const n = std.unicode.utf8Encode(@intCast(codepoint), self.text[self.text_len..]) catch 0;
        if (n == 0) return;
        self.col_fg[col] = fg;
        for (0..n) |i| self.byte_to_col[self.text_len + i] = col;
        self.text_len += n;
        // Build a snail.Cell for this character.
        self.cells[self.cell_count] = .{
            .source = .{ .start = @intCast(start), .end = @intCast(self.text_len) },
            .column = col,
            .color = fg.toLinearFloat4(1.0),
        };
        self.cell_count += 1;
    }
};

fn rgbEq(a: Rgb, b: Rgb) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

/// Build one row: walk cells, accumulate text, shape, record, place.
/// Returns the shapes (caller-owned via allocator) and rects.
fn buildRow(
    snapshot: *const render_snapshot.SharedSnapshot,
    cell_index: *usize,
    cols: u16,
    row_y: f32,
    scratch_rects: []ColoredRect,
    atlas: *const snail.Atlas,
    faces: *snail.Faces,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    misses: *glyph_misses.Set,
    shapes_out: []snail.Shape,
) !struct { rect_count: usize, shape_count: usize, had_misses: bool } {
    var rect_count: usize = 0;
    var had_misses = false;

    const default_fg = snapshot.header.default_fg;
    const default_bg = snapshot.header.default_bg;

    var bg_span_start: u16 = 0;
    var bg_span_color: ?Rgb = null;
    var bg_span_len: u16 = 0;

    var row = RowAccumulator{};

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

        // Background span coalescing
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
                            .color = sc.toLinearFloat4(1.0),
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

        const has_renderable_text = flags.has_text and isRenderableCodepoint(cell.codepoint);
        if (has_renderable_text) {
            row.appendCell(cell.codepoint, col_idx, fg);
        }

        if (flags.underline and rect_count < scratch_rects.len) {
            scratch_rects[rect_count] = .{
                .x = @as(f32, @floatFromInt(col_idx)) * metrics.cell_width,
                .y = row_y + metrics.cell_height - 1,
                .w = metrics.cell_width,
                .h = 1,
                .color = fg.toLinearFloat4(1.0),
            };
            rect_count += 1;
        }
        if (flags.strikethrough and rect_count < scratch_rects.len) {
            scratch_rects[rect_count] = .{
                .x = @as(f32, @floatFromInt(col_idx)) * metrics.cell_width,
                .y = row_y + metrics.cell_height * 0.45,
                .w = metrics.cell_width,
                .h = 1,
                .color = fg.toLinearFloat4(1.0),
            };
            rect_count += 1;
        }
    }

    // Shape + record + place
    var shape_count: usize = 0;
    if (!row.isEmpty()) {
        var shaped = snail.shape(allocator, faces, row.text[0..row.text_len], .{}) catch {
            row.reset();
            // Flush trailing bg span
            if (bg_span_len > 0 and bg_span_color != null and rect_count < scratch_rects.len) {
                scratch_rects[rect_count] = .{
                    .x = @as(f32, @floatFromInt(bg_span_start)) * metrics.cell_width,
                    .y = row_y,
                    .w = @as(f32, @floatFromInt(bg_span_len)) * metrics.cell_width,
                    .h = metrics.cell_height,
                    .color = bg_span_color.?.toLinearFloat4(1.0),
                };
                rect_count += 1;
            }
            return .{ .rect_count = rect_count, .shape_count = 0, .had_misses = false };
        };
        defer shaped.deinit();

        if (shaped.glyphs.len > 0) {
            // Detect glyphs not yet present in the (immutable) atlas
            // snapshot. The render path must never mutate the shared atlas
            // — the atlas owner thread extends it — so this is read-only:
            // any absent glyph marks the whole row as a miss and its text
            // is collected below so the caller can request an extension.
            for (shaped.glyphs) |glyph| {
                const font_id = faces.fontIdForFace(glyph.face_index) orelse continue;
                const key = snail.record_key.unhintedGlyph(font_id, @intCast(glyph.glyph_id));
                if (!atlas.contains(key)) {
                    had_misses = true;
                    break;
                }
            }

            // Place cells into shapes
            const baseline_y = row_y + metrics.baseline();
            const placement: snail.CellRunPlacement = .{
                .baseline = .{ .x = 0, .y = baseline_y },
                .cell_width = metrics.cell_width,
                .em = metrics.font_size,
                .snap = .grid,
                .world_to_pixel = .identity,
                .colr = true,
            };

            const expected_count = snail.placedCellRunShapeCount(&shaped, faces, row.cells[0..row.cell_count], placement) catch 0;
            if (expected_count > 0 and expected_count <= shapes_out.len) {
                const placed = snail.placeCellRun(shapes_out[0..expected_count], &shaped, faces, row.cells[0..row.cell_count], placement) catch {
                    row.reset();
                    if (bg_span_len > 0 and bg_span_color != null and rect_count < scratch_rects.len) {
                        scratch_rects[rect_count] = .{
                            .x = @as(f32, @floatFromInt(bg_span_start)) * metrics.cell_width,
                            .y = row_y,
                            .w = @as(f32, @floatFromInt(bg_span_len)) * metrics.cell_width,
                            .h = metrics.cell_height,
                            .color = bg_span_color.?.toLinearFloat4(1.0),
                        };
                        rect_count += 1;
                    }
                    return .{ .rect_count = rect_count, .shape_count = 0, .had_misses = had_misses };
                };
                shape_count = placed.len;
            }

            if (had_misses) misses.addRun(row.text[0..row.text_len]);
        }
        row.reset();
    }

    // Flush trailing bg span
    if (bg_span_len > 0 and bg_span_color != null and rect_count < scratch_rects.len) {
        scratch_rects[rect_count] = .{
            .x = @as(f32, @floatFromInt(bg_span_start)) * metrics.cell_width,
            .y = row_y,
            .w = @as(f32, @floatFromInt(bg_span_len)) * metrics.cell_width,
            .h = metrics.cell_height,
            .color = bg_span_color.?.toLinearFloat4(1.0),
        };
        rect_count += 1;
    }

    return .{ .rect_count = rect_count, .shape_count = shape_count, .had_misses = had_misses };
}

fn isRenderableCodepoint(cp: u32) bool {
    return cp > 0x20 and cp < 0x110000;
}

// ── Per-frame stash for heap-allocated slices ──

pub const EphemeralBlobs = struct {
    allocator: std.mem.Allocator,
    rect_slices: std.ArrayList([]ColoredRect) = .empty,
    shape_slices: std.ArrayList([]snail.Shape) = .empty,

    pub fn init(allocator: std.mem.Allocator) EphemeralBlobs {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EphemeralBlobs) void {
        self.releaseAll();
        self.rect_slices.deinit(self.allocator);
        self.shape_slices.deinit(self.allocator);
    }

    pub fn releaseAll(self: *EphemeralBlobs) void {
        for (self.rect_slices.items) |r| self.allocator.free(r);
        for (self.shape_slices.items) |s| self.allocator.free(s);
        self.rect_slices.clearRetainingCapacity();
        self.shape_slices.clearRetainingCapacity();
    }

    pub fn stashRects(self: *EphemeralBlobs, rects: []ColoredRect) !void {
        try self.rect_slices.append(self.allocator, rects);
    }

    pub fn stashShapes(self: *EphemeralBlobs, shapes: []snail.Shape) !void {
        try self.shape_slices.append(self.allocator, shapes);
    }
};

// ── Output types ──

pub const RowDraw = struct {
    shapes: []const snail.Shape,
    rects: []ColoredRect,
    row_y: f32,
};

pub const CursorOverlay = struct {
    cell_x: u16,
    cell_y: u16,
    style: render_snapshot.CursorStyle,
    color: Rgb,
};

pub const SelectionSpan = struct {
    row: u16,
    start_col: u16,
    end_col: u16,
};

pub const MAX_SELECTION_SPANS: usize = render_snapshot.MaxRows;

pub const BuiltSnapshot = struct {
    rows: []const RowDraw,
    cursor: ?CursorOverlay,
    selection_spans: []const SelectionSpan,
    scrollbar: ?render_snapshot.ScrollbarOverlay,
    bell: ?render_snapshot.BellOverlay,
};

/// Max shapes per row — generous upper bound for a full row of glyphs.
const MAX_SHAPES_PER_ROW: usize = render_snapshot.MaxCols * 4;

/// Walk a snapshot row-by-row, shape each row's text, and capture cursor
/// state in one pass.
pub fn buildSnapshot(
    snapshot: *const render_snapshot.SharedSnapshot,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    atlas: *const snail.Atlas,
    faces: *snail.Faces,
    scratch_rects: []ColoredRect,
    rows_out: []RowDraw,
    selection_spans_out: []SelectionSpan,
    rect_stash: *EphemeralBlobs,
    misses: *glyph_misses.Set,
) !BuiltSnapshot {
    const header = snapshot.header;
    const default_fg = header.default_fg;
    const default_bg = header.default_bg;
    const rows = @min(header.rows, render_snapshot.MaxRows);
    const cols = @min(header.cols, render_snapshot.MaxCols);

    var cell_index: usize = 0;
    var cursor_cell: ?render_common.CursorCell = null;
    var row_count: usize = 0;

    var row_idx: u16 = 0;
    while (row_idx < rows and row_count < rows_out.len) : (row_idx += 1) {
        const row_y = @as(f32, @floatFromInt(row_idx)) * metrics.cell_height;
        const row_start_index = cell_index;

        // Capture cursor cell
        if (header.cursor_visible != 0 and header.cursor_in_viewport != 0 and row_idx == header.cursor_y) {
            const cursor_col = header.cursor_x;
            if (cursor_col < cols and row_start_index + cursor_col < header.cell_count) {
                const cell = snapshot.cells[row_start_index + cursor_col];
                const flags: render_snapshot.CellFlags = @bitCast(cell.flags);
                const resolved = render_common.resolveCellColors(
                    default_fg,
                    default_bg,
                    if (flags.has_fg) cell.fg else null,
                    if (flags.has_bg) cell.bg else null,
                    flags.inverse,
                    flags.faint,
                );
                cursor_cell = render_common.captureCursorCell(default_bg, cell.codepoint, cell.glyph_id, flags.has_text, resolved);
            }
        }

        const next_index = row_start_index + @min(@as(usize, cols), header.cell_count -| row_start_index);

        const rebuild_t0 = perf.Timer.now();
        const shape_t0 = perf.Timer.now();

        // Scratch shape buffer for this row
        var row_shapes: [MAX_SHAPES_PER_ROW]snail.Shape = undefined;
        const built = try buildRow(
            snapshot,
            &cell_index,
            cols,
            0,
            scratch_rects,
            atlas,
            faces,
            allocator,
            metrics,
            misses,
            &row_shapes,
        );
        phase_row_shape_ns += shape_t0.elapsedNs();

        // Copy shapes + rects to heap for stable references
        const shapes = try allocator.dupe(snail.Shape, row_shapes[0..built.shape_count]);
        try rect_stash.stashShapes(shapes);
        const rects = try allocator.dupe(ColoredRect, scratch_rects[0..built.rect_count]);
        try rect_stash.stashRects(rects);

        phase_row_finish_ns += perf.Timer.now().elapsedNs();
        phase_row_rebuild_ns += rebuild_t0.elapsedNs();
        phase_row_count += 1;
        cell_index = next_index;

        rows_out[row_count] = .{ .shapes = shapes, .rects = rects, .row_y = row_y };
        row_count += 1;
    }

    // Cursor overlay
    var cursor: ?CursorOverlay = null;
    if (header.cursor_visible != 0 and header.cursor_in_viewport != 0) {
        const cursor_color = if (header.cursor_has_color != 0) header.cursor_color else default_fg;
        cursor = .{
            .cell_x = header.cursor_x,
            .cell_y = header.cursor_y,
            .style = header.cursor_style,
            .color = cursor_color,
        };
    }

    const spans = resolveSelectionSpans(snapshot, selection_spans_out, rows, cols);

    return .{
        .rows = rows_out[0..row_count],
        .cursor = cursor,
        .selection_spans = spans,
        .scrollbar = snapshot.scrollbar,
        .bell = snapshot.bell,
    };
}

fn resolveSelectionSpans(
    snapshot: *const render_snapshot.SharedSnapshot,
    spans_out: []SelectionSpan,
    rows: u16,
    cols: u16,
) []SelectionSpan {
    const sel = snapshot.selection orelse return spans_out[0..0];
    if (rows == 0 or cols == 0 or spans_out.len == 0) return spans_out[0..0];

    const offset: i64 = snapshot.header.viewport_offset;
    const view_rows: i64 = rows;
    var n: usize = 0;

    switch (sel.mode) {
        .char => {
            const ord = sel.ordered();
            const start_vy = @as(i64, ord.start.row) - offset;
            const end_vy = @as(i64, ord.end.row) - offset;
            if (end_vy < 0 or start_vy >= view_rows) return spans_out[0..0];

            const clip_start_vy = @max(@as(i64, 0), start_vy);
            const clip_end_vy = @min(view_rows - 1, end_vy);
            var row_vy: i64 = clip_start_vy;
            while (row_vy <= clip_end_vy and n < spans_out.len) : (row_vy += 1) {
                const sc: u16 = if (row_vy == start_vy) @min(ord.start.col, cols - 1) else 0;
                const ec: u16 = if (row_vy == end_vy) @min(ord.end.col, cols - 1) else cols - 1;
                if (ec >= sc) {
                    spans_out[n] = .{ .row = @intCast(row_vy), .start_col = sc, .end_col = ec };
                    n += 1;
                }
            }
        },
        .word => {
            const anchor_word = expandSnapshotWord(snapshot, sel.anchor, cols);
            const head_word = expandSnapshotWord(snapshot, sel.head, cols);
            const start_cell: selection_mod.Cell = if (selection_mod.Cell.lessThan(anchor_word.start, head_word.start))
                anchor_word.start
            else
                head_word.start;
            const end_cell: selection_mod.Cell = if (selection_mod.Cell.lessThan(anchor_word.end, head_word.end))
                head_word.end
            else
                anchor_word.end;
            const start_vy = @as(i64, start_cell.row) - offset;
            const end_vy = @as(i64, end_cell.row) - offset;
            if (end_vy < 0 or start_vy >= view_rows) return spans_out[0..0];
            const clip_start_vy = @max(@as(i64, 0), start_vy);
            const clip_end_vy = @min(view_rows - 1, end_vy);
            var row_vy: i64 = clip_start_vy;
            while (row_vy <= clip_end_vy and n < spans_out.len) : (row_vy += 1) {
                const sc: u16 = if (row_vy == start_vy) @min(start_cell.col, cols - 1) else 0;
                const ec: u16 = if (row_vy == end_vy) @min(end_cell.col, cols - 1) else cols - 1;
                spans_out[n] = .{ .row = @intCast(row_vy), .start_col = sc, .end_col = ec };
                n += 1;
            }
        },
        .line => {
            const ord = sel.ordered();
            const start_vy = @as(i64, ord.start.row) - offset;
            const end_vy = @as(i64, ord.end.row) - offset;
            if (end_vy < 0 or start_vy >= view_rows) return spans_out[0..0];
            const clip_start_vy: u16 = @intCast(@max(@as(i64, 0), start_vy));
            const clip_end_vy: u16 = @intCast(@min(view_rows - 1, end_vy));
            var row_vy: u16 = clip_start_vy;
            while (row_vy <= clip_end_vy and n < spans_out.len) : (row_vy += 1) {
                spans_out[n] = .{ .row = row_vy, .start_col = 0, .end_col = cols - 1 };
                n += 1;
            }
        },
    }
    return spans_out[0..n];
}

fn expandSnapshotWord(
    snapshot: *const render_snapshot.SharedSnapshot,
    cell: selection_mod.Cell,
    cols: u16,
) struct { start: selection_mod.Cell, end: selection_mod.Cell } {
    const offset: i64 = snapshot.header.viewport_offset;
    const view_row_i = @as(i64, cell.row) - offset;
    if (view_row_i < 0 or view_row_i >= snapshot.header.rows) {
        return .{
            .start = .{ .row = cell.row, .col = cell.col },
            .end = .{ .row = cell.row, .col = cell.col },
        };
    }
    const view_row: u16 = @intCast(view_row_i);
    var row_codepoints: [render_snapshot.MaxCols]u32 = undefined;
    const row_start: usize = @as(usize, view_row) * @as(usize, cols);
    var col: u16 = 0;
    while (col < cols and row_start + col < snapshot.header.cell_count) : (col += 1) {
        row_codepoints[col] = snapshot.cells[row_start + col].codepoint;
    }
    const w = selection_mod.expandWord(row_codepoints[0..col], cell.col);
    return .{
        .start = .{ .row = cell.row, .col = w.start },
        .end = .{ .row = cell.row, .col = w.end },
    };
}
