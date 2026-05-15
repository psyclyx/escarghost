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
        for (stale.items) |k| self.evict(k);
        return .{ .rebound = rebound, .evicted = stale.items.len };
    }
};

fn destroyRow(allocator: std.mem.Allocator, row: *Row) void {
    row.blob.deinit();
    allocator.destroy(row.blob);
    allocator.free(row.rects);
}
