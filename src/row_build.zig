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
const selection_mod = @import("selection.zig");
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

/// FNV-1a over the row's cells. Stable per cell-content; the cache key.
pub fn hashSnapshotRow(snapshot: *const render_snapshot.SharedSnapshot, start_index: usize, cols: u16) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const m: u64 = 0x100000001b3;
    var i: usize = 0;
    while (i < cols and start_index + i < snapshot.header.cell_count) : (i += 1) {
        const cell = snapshot.cells[start_index + i];
        const bytes = std.mem.asBytes(&cell);
        for (bytes) |b| h = (h ^ b) *% m;
    }
    return h;
}

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

/// One cached row's drawables. Y coordinates are row-local; the caller
/// translates by row_y at submit. The blob is heap-allocated so the cache's
/// underlying hashmap can rehash mid-frame without invalidating the
/// `*const TextBlob` pointers that already live in the per-frame Scene.
pub const Row = struct {
    blob: *snail.TextBlob,
    rects: []ColoredRect,
    content_hash: u64,
    atlas_identity: u64,
    had_misses: bool,
    last_used_frame: u64,
    byte_size: usize,
};

/// Per-row TextBlob+rect cache shared between backends. One instance per
/// renderer (no cross-thread sharing); each renderer's lock-free atlas
/// snapshot identity is held alongside the content hash on each entry.
///
/// Atlas-snapshot bumps trigger `rebindAll`, not a wipe. Metrics changes
/// (font size, DPI) invalidate the entire cache because each cached blob
/// bakes `placement.em` into its per-instance `Transform2D`.
pub const RowCache = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, Row),
    cache_bytes: usize = 0,
    cache_budget: usize,
    frame_counter: u64 = 0,

    pub const RebindStats = struct { rebound: usize, evicted: usize };

    pub fn init(allocator: std.mem.Allocator, budget_bytes: usize) RowCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(u64, Row).init(allocator),
            .cache_budget = budget_bytes,
        };
    }

    pub fn deinit(self: *RowCache) void {
        self.clear();
        self.map.deinit();
    }

    pub fn clear(self: *RowCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |row| destroyRow(self.allocator, row);
        self.map.clearRetainingCapacity();
        self.cache_bytes = 0;
    }

    /// Begin a new frame; entries inherit this counter on `get` / `store` so
    /// LRU eviction can find genuinely-old rows.
    pub fn beginFrame(self: *RowCache) void {
        self.frame_counter += 1;
    }

    /// Look up a row by content hash. Returns null on miss. On hit, marks
    /// the row as used this frame so it survives the LRU sweep.
    pub fn get(self: *RowCache, key: u64) ?*Row {
        const row = self.map.getPtr(key) orelse return null;
        row.last_used_frame = self.frame_counter;
        return row;
    }

    /// Take ownership of a freshly-built blob+rects under `key`. Returns
    /// the inserted entry, or null if the underlying allocation fails (in
    /// which case `blob` and `rects` are deinit/freed before return so the
    /// caller never has to clean up after a failed store).
    pub fn store(
        self: *RowCache,
        key: u64,
        blob: snail.TextBlob,
        rects: []ColoredRect,
        atlas_identity: u64,
        had_misses: bool,
    ) ?*Row {
        if (self.map.fetchRemove(key)) |kv| {
            var stale = kv.value;
            self.cache_bytes -= stale.byte_size;
            destroyRow(self.allocator, &stale);
        }

        const byte_size = rects.len * @sizeOf(ColoredRect) + blob.glyphCount() * 24;
        const blob_slot = self.allocator.create(snail.TextBlob) catch {
            var b = blob;
            b.deinit();
            self.allocator.free(rects);
            return null;
        };
        blob_slot.* = blob;
        self.map.put(key, .{
            .blob = blob_slot,
            .rects = rects,
            .content_hash = key,
            .atlas_identity = atlas_identity,
            .had_misses = had_misses,
            .last_used_frame = self.frame_counter,
            .byte_size = byte_size,
        }) catch {
            blob_slot.deinit();
            self.allocator.destroy(blob_slot);
            self.allocator.free(rects);
            return null;
        };
        self.cache_bytes += byte_size;

        var guard: usize = 0;
        while (self.cache_bytes > self.cache_budget and guard < 32) : (guard += 1) {
            self.evictLru();
        }
        return self.map.getPtr(key);
    }

    pub fn evict(self: *RowCache, key: u64) void {
        if (self.map.fetchRemove(key)) |kv| {
            var row = kv.value;
            self.cache_bytes -= row.byte_size;
            destroyRow(self.allocator, &row);
        }
    }

    fn evictLru(self: *RowCache) void {
        var oldest_key: ?u64 = null;
        var oldest_frame: u64 = std.math.maxInt(u64);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_used_frame < oldest_frame) {
                oldest_frame = entry.value_ptr.last_used_frame;
                oldest_key = entry.key_ptr.*;
            }
        }
        if (oldest_key) |k| self.evict(k);
    }

    /// Walk the cache after an atlas-snapshot bump. Entries with
    /// `had_misses == true` are evicted (their blob's glyph list omits the
    /// missing GIDs and `rebound` would silently succeed with absent
    /// glyphs); clean entries are rebound to the new atlas.
    pub fn rebindAll(
        self: *RowCache,
        new_atlas: *const snail.TextAtlas,
        new_identity: u64,
    ) RebindStats {
        return self.rebindAllInto(new_atlas, new_identity, null);
    }

    /// Like `rebindAll`, but also write each evicted entry's content hash
    /// into `evicted_out` (up to its capacity). Lets callers correlate
    /// which specific rows' painted pixels are now stale, rather than
    /// invalidating their entire downstream cache.
    pub fn rebindAllInto(
        self: *RowCache,
        new_atlas: *const snail.TextAtlas,
        new_identity: u64,
        evicted_out: ?[]u64,
    ) RebindStats {
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.map.iterator();
        var rebound: usize = 0;
        while (it.next()) |entry| {
            const row = entry.value_ptr;
            if (row.had_misses) {
                stale.append(self.allocator, entry.key_ptr.*) catch {};
                continue;
            }
            const new_blob = row.blob.rebound(self.allocator, new_atlas) catch {
                stale.append(self.allocator, entry.key_ptr.*) catch {};
                continue;
            };
            row.blob.deinit();
            row.blob.* = new_blob;
            row.atlas_identity = new_identity;
            rebound += 1;
        }
        if (evicted_out) |out| {
            const n = @min(out.len, stale.items.len);
            @memcpy(out[0..n], stale.items[0..n]);
        }
        for (stale.items) |k| self.evict(k);
        return .{ .rebound = rebound, .evicted = stale.items.len };
    }
};

fn destroyRow(allocator: std.mem.Allocator, row: *Row) void {
    row.blob.deinit();
    allocator.destroy(row.blob);
    allocator.free(row.rects);
}

/// Per-frame stash of heap-allocated `TextBlob`s that the scene records
/// pointers to. Freed in bulk at end of frame; both backends own one.
pub const EphemeralBlobs = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(*snail.TextBlob) = .empty,

    pub fn init(allocator: std.mem.Allocator) EphemeralBlobs {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EphemeralBlobs) void {
        self.releaseAll();
        self.items.deinit(self.allocator);
    }

    pub fn releaseAll(self: *EphemeralBlobs) void {
        for (self.items.items) |b| {
            b.deinit();
            self.allocator.destroy(b);
        }
        self.items.clearRetainingCapacity();
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
};

/// Output of `buildSnapshot`: the per-row draw list (cached blob + row_y)
/// and an optional cursor overlay. Backends iterate this to emit the four
/// passes (clear → bg/decoration rects → cursor rect → text scene).
///
/// Carries `blob` and `rects` directly rather than `*Row`: `cache.store`
/// can rehash the underlying `std.AutoHashMap` mid-build and invalidate
/// previously-returned `*Row` pointers, but the heap-allocated `blob` and
/// `rects` themselves are stable across rehash.
pub const RowDraw = struct {
    blob: *snail.TextBlob,
    rects: []ColoredRect,
    row_y: f32,
    content_hash: u64,
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
    /// Stable identity of the selection for dirty tracking. Two
    /// selections that produce the same painted band hash to the same
    /// value. Zero = no selection.
    selection_id: u64,
};

/// Walk a snapshot row-by-row, hit the row cache, and capture cursor
/// state in one pass. Backends own the four submit passes (see
/// docs/row-render-design.md for the contract); this layer owns
/// iteration, caching, and the per-frame inverted-glyph build.
///
/// `selection_spans_out` receives any selection rectangles produced
/// from `snapshot.selection`. Cap is `MAX_SELECTION_SPANS`.
pub fn buildSnapshot(
    snapshot: *const render_snapshot.SharedSnapshot,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    cache: *RowCache,
    builder: *snail.TextBlobBuilder,
    atlas: *const snail.TextAtlas,
    atlas_identity: u64,
    scratch_rects: []ColoredRect,
    rows_out: []RowDraw,
    selection_spans_out: []SelectionSpan,
    blob_stash: *EphemeralBlobs,
    misses: *glyph_misses.Set,
) !BuiltSnapshot {
    cache.beginFrame();

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

        const content_hash = hashSnapshotRow(snapshot, row_start_index, cols);
        const next_index = row_start_index + @min(@as(usize, cols), header.cell_count -| row_start_index);

        var entry: ?*Row = null;
        if (cache.get(content_hash)) |row| {
            if (!row.had_misses and row.atlas_identity == atlas_identity) {
                entry = row;
            }
        }
        if (entry == null) {
            builder.reset();
            const built = try buildRow(
                snapshot,
                &cell_index,
                cols,
                0,
                scratch_rects,
                builder,
                atlas,
                allocator,
                metrics,
                misses,
            );
            const blob = try builder.finish();
            const rects = try allocator.dupe(ColoredRect, scratch_rects[0..built.rect_count]);
            entry = cache.store(content_hash, blob, rects, atlas_identity, built.had_misses);
        }
        cell_index = next_index;

        if (entry) |row| {
            // Snapshot the stable heap pointers now. The `*Row` itself
            // lives in `cache.map` and gets invalidated on rehash; the
            // blob and rects allocations are independent and outlive any
            // hashmap reshuffle.
            rows_out[row_count] = .{ .blob = row.blob, .rects = row.rects, .row_y = row_y, .content_hash = content_hash };
            row_count += 1;
        }
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
        .selection_id = packSelectionId(snapshot.selection, spans),
    };
}

/// Translate the snapshot's anchor/head + mode into the per-row column
/// ranges the renderer paints. Char mode walks the band between the
/// ordered endpoints; word mode expands each endpoint to a word
/// boundary using the row's codepoints; line mode covers full rows.
/// Returns a slice of `spans_out` populated up to its capacity.
fn resolveSelectionSpans(
    snapshot: *const render_snapshot.SharedSnapshot,
    spans_out: []SelectionSpan,
    rows: u16,
    cols: u16,
) []SelectionSpan {
    const sel = snapshot.selection orelse return spans_out[0..0];
    if (rows == 0 or cols == 0 or spans_out.len == 0) return spans_out[0..0];

    var n: usize = 0;
    switch (sel.mode) {
        .char => {
            const ord = sel.ordered();
            const start = clampCell(ord.start, rows, cols);
            const end = clampCell(ord.end, rows, cols);
            var row: u16 = start.row;
            while (row <= end.row and n < spans_out.len) : (row += 1) {
                const start_col: u16 = if (row == start.row) start.col else 0;
                const end_col: u16 = if (row == end.row) end.col else cols - 1;
                if (end_col >= start_col) {
                    spans_out[n] = .{ .row = row, .start_col = start_col, .end_col = end_col };
                    n += 1;
                }
            }
        },
        .word => {
            // Expand anchor / head independently to their word
            // boundaries, then build the band using the expanded
            // endpoints. This matches what xterm / kitty do: a
            // double-click selects one word, a double-click-drag
            // grows the selection word-by-word.
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
            const start = clampCell(start_cell, rows, cols);
            const end = clampCell(end_cell, rows, cols);
            var row: u16 = start.row;
            while (row <= end.row and n < spans_out.len) : (row += 1) {
                const start_col: u16 = if (row == start.row) start.col else 0;
                const end_col: u16 = if (row == end.row) end.col else cols - 1;
                spans_out[n] = .{ .row = row, .start_col = start_col, .end_col = end_col };
                n += 1;
            }
        },
        .line => {
            const ord = sel.ordered();
            const start_row: u16 = @min(ord.start.row, rows - 1);
            const end_row: u16 = @min(ord.end.row, rows - 1);
            var row: u16 = start_row;
            while (row <= end_row and n < spans_out.len) : (row += 1) {
                spans_out[n] = .{ .row = row, .start_col = 0, .end_col = cols - 1 };
                n += 1;
            }
        },
    }
    return spans_out[0..n];
}

fn clampCell(cell: selection_mod.Cell, rows: u16, cols: u16) selection_mod.Cell {
    return .{
        .row = @min(cell.row, rows - 1),
        .col = @min(cell.col, cols - 1),
    };
}

/// Expand `cell` to a word range using the snapshot's row codepoints.
/// Falls back to a single-cell range when the row is out of bounds.
fn expandSnapshotWord(
    snapshot: *const render_snapshot.SharedSnapshot,
    cell: selection_mod.Cell,
    cols: u16,
) struct { start: selection_mod.Cell, end: selection_mod.Cell } {
    const row = cell.row;
    if (row >= snapshot.header.rows) {
        return .{
            .start = .{ .row = row, .col = cell.col },
            .end = .{ .row = row, .col = cell.col },
        };
    }
    var row_codepoints: [render_snapshot.MaxCols]u32 = undefined;
    const row_start: usize = @as(usize, row) * @as(usize, cols);
    var col: u16 = 0;
    while (col < cols and row_start + col < snapshot.header.cell_count) : (col += 1) {
        row_codepoints[col] = snapshot.cells[row_start + col].codepoint;
    }
    const w = selection_mod.expandWord(row_codepoints[0..col], cell.col);
    return .{
        .start = .{ .row = row, .col = w.start },
        .end = .{ .row = row, .col = w.end },
    };
}

/// Pack the resolved selection into a u64 for fast equality checks.
/// Renderers use this to detect "the highlight band hasn't moved" so
/// they can skip repainting selection-covered rows. Hashes the span
/// list so spans of different rows / extents always differ.
fn packSelectionId(snapshot: ?selection_mod.Snapshot, spans: []const SelectionSpan) u64 {
    if (snapshot == null or spans.len == 0) return 0;
    var h: u64 = 0xcbf29ce484222325;
    const m: u64 = 0x100000001b3;
    h = (h ^ @intFromEnum(snapshot.?.mode)) *% m;
    for (spans) |s| {
        h = (h ^ @as(u64, s.row)) *% m;
        h = (h ^ @as(u64, s.start_col)) *% m;
        h = (h ^ @as(u64, s.end_col)) *% m;
    }
    // Reserve 0 for "no selection".
    return if (h == 0) 1 else h;
}

fn buildInvertedGlyph(
    atlas: *const snail.TextAtlas,
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
    var shaped = try atlas.shapeText(allocator, .{}, tmp[0..n]);
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
