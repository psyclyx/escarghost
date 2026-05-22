//! Shared row-building primitives used by both the GPU (renderer.zig) and
//! CPU (cpu_pipeline.zig) paths. Iterates a row's cells, accumulates same-fg
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
const color = @import("color");
const selection_mod = @import("../selection.zig");
const atlas_ref_mod = @import("atlas_ref.zig");
const perf = @import("../perf.zig");
const Rgb = color.Rgb;

/// Sub-phase counters for `buildSnapshot`. Single writer (the GPU
/// worker thread, sole caller of buildSnapshot); diagnostic-only readers
/// are benign. `phase_row_rebuild_ns` is the total per-row work across
/// the frame; `phase_row_shape_ns` and `phase_row_finish_ns` further
/// split that into the HB shape walk and the blob finalize + rect dupe.
/// `phase_row_count` is the number of rows built in the frame.
pub var phase_row_rebuild_ns: u64 = 0;
pub var phase_row_shape_ns: u64 = 0;
pub var phase_row_finish_ns: u64 = 0;
pub var phase_row_count: u64 = 0;

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

/// Accumulates an entire row's renderable text in one HB-shapeable
/// buffer along with the per-byte mapping back to the source cell
/// column. After the cell walk completes, `flushRow` calls HB once to
/// shape the lot — ligatures still form because shaping spans the full
/// row — and then emits builder.append calls per same-fg sub-range of
/// the resulting glyph stream. Cells whose text isn't renderable (or
/// blank) contribute nothing; the per-cell x grid (`placement.baseline.x
/// = first_cell_col * cell_width`) anchors each sub-range absolutely so
/// the blanks just stay blank — they're not part of the shape.
const RowAccumulator = struct {
    /// UTF-8 buffer of renderable text from the row, in column order.
    /// Cap matches MAX_RECTS_PER_ROW's intent: well over the worst-case
    /// 167 cols × 4 bytes.
    text: [2048]u8 = undefined,
    text_len: usize = 0,
    /// Per-byte index into `text`, the source column that contributed
    /// it. Used after shaping to map glyph.source_start back to its
    /// originating cell so we can pick up that cell's fg color.
    byte_to_col: [2048]u16 = undefined,
    /// Per-column fg. Sparse — only columns with renderable text get
    /// written, but downstream lookups index by column so the array is
    /// sized to MaxCols.
    col_fg: [render_snapshot.MaxCols]Rgb = undefined,

    fn reset(self: *RowAccumulator) void {
        self.text_len = 0;
    }

    fn isEmpty(self: *const RowAccumulator) bool {
        return self.text_len == 0;
    }

    fn appendCell(self: *RowAccumulator, codepoint: u32, col: u16, fg: Rgb) void {
        if (self.text_len + 4 > self.text.len) return;
        if (col >= self.col_fg.len) return;
        const n = std.unicode.utf8Encode(@intCast(codepoint), self.text[self.text_len..]) catch 0;
        if (n == 0) return;
        self.col_fg[col] = fg;
        for (0..n) |i| self.byte_to_col[self.text_len + i] = col;
        self.text_len += n;
    }
};

fn rgbEq(a: Rgb, b: Rgb) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

/// Shape the whole row in one HB call, then walk the shaped glyphs
/// and emit `builder.append` ranges grouped by fg color. The fg color
/// for each glyph comes from the cell its `source_start` byte falls in
/// — that's why the accumulator tracks a byte→column index.
///
/// `placement.baseline.x` for each sub-range is anchored to the first
/// glyph's cell column on the absolute grid, so cells with no
/// renderable text (which contributed nothing to the shape) leave gaps
/// in exactly the right places. Cell width matches the font's natural
/// advance, so ligatures across cells still span the correct number of
/// columns.
fn flushRow(
    row: *RowAccumulator,
    builder: *snail.TextBlobBuilder,
    atlas: *const snail.TextAtlas,
    atlas_ref: *atlas_ref_mod.AtlasRef,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    row_y: f32,
    misses: *glyph_misses.Set,
) !bool {
    if (row.isEmpty()) return false;
    var shaped = try atlas_ref.shape(atlas, allocator, .{}, row.text[0..row.text_len]);
    defer shaped.deinit();
    if (shaped.glyphs.len == 0) {
        row.reset();
        return false;
    }

    const baseline_y = row_y + metrics.baseline();
    var had_misses = false;
    var group_start: usize = 0;
    var group_col: u16 = colForGlyph(row, &shaped.glyphs[0]);
    var group_fg: Rgb = row.col_fg[group_col];

    var i: usize = 1;
    while (i <= shaped.glyphs.len) : (i += 1) {
        const at_end = i == shaped.glyphs.len;
        const next_fg = if (at_end) group_fg else row.col_fg[colForGlyph(row, &shaped.glyphs[i])];
        if (at_end or !rgbEq(next_fg, group_fg)) {
            const result = try builder.append(.{
                .shaped = &shaped,
                .glyphs = .{ .start = group_start, .count = i - group_start },
                .placement = .{
                    .baseline = .{
                        .x = @as(f32, @floatFromInt(group_col)) * metrics.cell_width,
                        .y = baseline_y,
                    },
                    .em = metrics.font_size,
                },
                .fill = .{ .solid = group_fg.toFloat4(1.0) },
            });
            if (result.missing) had_misses = true;
            if (!at_end) {
                group_start = i;
                group_col = colForGlyph(row, &shaped.glyphs[i]);
                group_fg = next_fg;
            }
        }
    }

    // If any sub-range had a missing glyph, the atlas thread needs to
    // see the entire row's text so it can extend coverage for whatever
    // codepoint produced the .notdef. Sub-range granularity is wasted
    // here — the miss set is deduped anyway.
    if (had_misses) misses.addRun(row.text[0..row.text_len]);
    row.reset();
    return had_misses;
}

fn colForGlyph(row: *const RowAccumulator, glyph: *const snail.ShapedText.Glyph) u16 {
    const start = @min(glyph.source_start, @as(u32, @intCast(row.text_len -| 1)));
    return row.byte_to_col[start];
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
    atlas_ref: *atlas_ref_mod.AtlasRef,
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
        if (has_renderable_text) {
            row.appendCell(cell.codepoint, col_idx, fg);
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

    if (try flushRow(&row, builder, atlas, atlas_ref, allocator, metrics, row_y, misses)) had_misses = true;

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

/// Per-frame stash for heap-allocated `TextBlob`s + `ColoredRect`
/// slices that the rendered scene references by pointer. Released in
/// bulk at end of frame; both backends own one.
pub const EphemeralBlobs = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(*snail.TextBlob) = .empty,
    rect_slices: std.ArrayList([]ColoredRect) = .empty,

    pub fn init(allocator: std.mem.Allocator) EphemeralBlobs {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EphemeralBlobs) void {
        self.releaseAll();
        self.items.deinit(self.allocator);
        self.rect_slices.deinit(self.allocator);
    }

    pub fn releaseAll(self: *EphemeralBlobs) void {
        for (self.items.items) |b| {
            b.deinit();
            self.allocator.destroy(b);
        }
        self.items.clearRetainingCapacity();
        for (self.rect_slices.items) |r| self.allocator.free(r);
        self.rect_slices.clearRetainingCapacity();
    }

    pub fn stash(self: *EphemeralBlobs, blob: snail.TextBlob) ?*const snail.TextBlob {
        const slot = self.allocator.create(snail.TextBlob) catch {
            var b = blob;
            b.deinit();
            return null;
        };
        slot.* = blob;
        self.items.append(self.allocator, slot) catch {
            slot.deinit();
            self.allocator.destroy(slot);
            return null;
        };
        return slot;
    }

    /// Take ownership of a heap-allocated rect slice. The slice is
    /// freed back to `allocator` at the next `releaseAll`.
    pub fn stashRects(self: *EphemeralBlobs, rects: []ColoredRect) !void {
        try self.rect_slices.append(self.allocator, rects);
    }
};

/// Output of `buildSnapshot`: the per-row draw list (blob + row_y) and
/// an optional cursor overlay. Backends iterate this to emit the four
/// passes (clear → bg/decoration rects → cursor rect → text scene).
pub const RowDraw = struct {
    blob: *const snail.TextBlob,
    rects: []ColoredRect,
    row_y: f32,
};

pub const CursorOverlay = struct {
    cell_x: u16,
    cell_y: u16,
    style: render_snapshot.CursorStyle,
    color: Rgb,
    /// Block-style cursor's inverted glyph, stashed in the per-frame
    /// EphemeralBlobs. Null for non-block styles, empty cells, missing
    /// glyphs, or stash-allocation failure.
    inverted_glyph: ?*const snail.TextBlob = null,
};

/// Per-row span of selected columns, in viewport coordinates. Inclusive
/// of both endpoints. Width-zero spans are skipped at build time. The
/// renderer paints these as translucent overlays under the row's text.
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
    /// Optional right-edge scrollbar overlay. Renderers paint a thin
    /// band on top of everything else when present.
    scrollbar: ?render_snapshot.ScrollbarOverlay,
    /// Visual-bell overlay. Renderers paint a translucent tint over
    /// the finished frame when present.
    bell: ?render_snapshot.BellOverlay,
};

/// Walk a snapshot row-by-row, shape each row's text, and capture cursor
/// state in one pass. Backends own the four submit passes (see
/// docs/row-render-design.md for the contract); this layer owns
/// iteration and the per-frame inverted-glyph build.
///
/// `selection_spans_out` receives any selection rectangles produced
/// from `snapshot.selection`. Cap is `MAX_SELECTION_SPANS`.
pub fn buildSnapshot(
    snapshot: *const render_snapshot.SharedSnapshot,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    builder: *snail.TextBlobBuilder,
    atlas: *const snail.TextAtlas,
    atlas_ref: *atlas_ref_mod.AtlasRef,
    scratch_rects: []ColoredRect,
    rows_out: []RowDraw,
    selection_spans_out: []SelectionSpan,
    blob_stash: *EphemeralBlobs,
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

        // Shape every row every frame. A prior content-hash-keyed cache
        // was removed: on workloads where every row's content changes
        // per frame (e.g. tmatrix) the hit rate was 0% and the lookup +
        // store path was pure overhead; on stable text the per-frame
        // shape work is the known tradeoff.
        const rebuild_t0 = perf.Timer.now();
        builder.reset();
        const shape_t0 = perf.Timer.now();
        const built = try buildRow(
            snapshot,
            &cell_index,
            cols,
            0,
            scratch_rects,
            builder,
            atlas,
            atlas_ref,
            allocator,
            metrics,
            misses,
        );
        phase_row_shape_ns += shape_t0.elapsedNs();
        const finish_t0 = perf.Timer.now();
        const blob = try builder.finish();
        const blob_ptr = blob_stash.stash(blob) orelse return error.OutOfMemory;
        const rects = try allocator.dupe(ColoredRect, scratch_rects[0..built.rect_count]);
        try blob_stash.stashRects(rects);
        phase_row_finish_ns += finish_t0.elapsedNs();
        phase_row_rebuild_ns += rebuild_t0.elapsedNs();
        phase_row_count += 1;
        cell_index = next_index;

        rows_out[row_count] = .{ .blob = blob_ptr, .rects = rects, .row_y = row_y };
        row_count += 1;
    }

    var cursor: ?CursorOverlay = null;
    if (header.cursor_visible != 0 and header.cursor_in_viewport != 0) {
        const cursor_color = if (header.cursor_has_color != 0) header.cursor_color else default_fg;
        var overlay: CursorOverlay = .{
            .cell_x = header.cursor_x,
            .cell_y = header.cursor_y,
            .style = header.cursor_style,
            .color = cursor_color,
        };
        if (header.cursor_style == .block) {
            if (cursor_cell) |cell| {
                if (cell.has_text and cell.glyph_id != 0) {
                    overlay.inverted_glyph = buildInvertedGlyph(
                        atlas,
                        atlas_ref,
                        allocator,
                        metrics,
                        cell,
                        header.cursor_x,
                        header.cursor_y,
                        blob_stash,
                        misses,
                    ) catch null;
                }
            }
        }
        cursor = overlay;
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

/// Translate the snapshot's anchor/head + mode into the per-row column
/// ranges the renderer paints. Selection cells store *absolute screen y*;
/// this helper subtracts the snapshot's viewport_offset to recover
/// viewport rows and clips off-screen portions of the band.
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
            // Convert screen-y to viewport row; entire band may be
            // off-screen above or below — in which case n stays 0.
            const start_vy = @as(i64, ord.start.row) - offset;
            const end_vy = @as(i64, ord.end.row) - offset;
            if (end_vy < 0 or start_vy >= view_rows) return spans_out[0..0];

            const clip_start_vy = @max(@as(i64, 0), start_vy);
            const clip_end_vy = @min(view_rows - 1, end_vy);
            var row_vy: i64 = clip_start_vy;
            while (row_vy <= clip_end_vy and n < spans_out.len) : (row_vy += 1) {
                // start_col only applies on the *real* first row of
                // the selection; if we clipped that off, the visible
                // first row begins at col 0.
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

/// Expand `cell` (in screen coords) to a word range using the
/// snapshot's row codepoints. Returns the cell unchanged when the
/// row is outside the captured viewport — word expansion needs the
/// row content, which the snapshot only has for visible rows.
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

fn buildInvertedGlyph(
    atlas: *const snail.TextAtlas,
    atlas_ref: *atlas_ref_mod.AtlasRef,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    cell: render_common.CursorCell,
    cursor_x: u16,
    cursor_y: u16,
    blob_stash: *EphemeralBlobs,
    misses: *glyph_misses.Set,
) !?*const snail.TextBlob {
    var inv_builder = snail.TextBlobBuilder.init(allocator, atlas);
    defer inv_builder.deinit();
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(cell.codepoint), &tmp) catch return null;
    var shaped = try atlas_ref.shape(atlas, allocator, .{}, tmp[0..n]);
    defer shaped.deinit();
    const cx = @as(f32, @floatFromInt(cursor_x)) * metrics.cell_width;
    const cy = @as(f32, @floatFromInt(cursor_y)) * metrics.cell_height;
    const result = try inv_builder.append(.{
        .shaped = &shaped,
        .placement = .{
            .baseline = .{ .x = cx, .y = cy + metrics.baseline() },
            .em = metrics.font_size,
        },
        .fill = .{ .solid = cell.bg.toFloat4(1.0) },
    });
    if (result.missing) {
        misses.addRun(tmp[0..n]);
        return null;
    }
    const blob = try inv_builder.finish();
    return blob_stash.stash(blob);
}
