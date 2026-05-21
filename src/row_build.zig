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
    allocator: std.mem.Allocator,
    metrics: Metrics,
    row_y: f32,
    misses: *glyph_misses.Set,
) !bool {
    if (row.isEmpty()) return false;
    var shaped = try atlas.shapeText(allocator, .{}, row.text[0..row.text_len]);
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

    if (try flushRow(&row, builder, atlas, allocator, metrics, row_y, misses)) had_misses = true;

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
/// translates by row_y at submit. The Row, its blob, and its rect slice
/// are all heap-allocated so the hashmap can rehash mid-frame without
/// invalidating the `*Row` / `*const TextBlob` pointers that the caller
/// (or the per-frame Scene) is already holding. The `lru_*` links form
/// an intrusive doubly-linked list owned by the enclosing RowCache; do
/// not touch them outside cache code.
pub const Row = struct {
    blob: *snail.TextBlob,
    rects: []ColoredRect,
    content_hash: u64,
    atlas_identity: u64,
    had_misses: bool,
    byte_size: usize,
    lru_prev: ?*Row = null,
    lru_next: ?*Row = null,
};

/// Per-row TextBlob+rect cache shared between backends. One instance per
/// renderer (no cross-thread sharing); each renderer's lock-free atlas
/// snapshot identity is held alongside the content hash on each entry.
///
/// Atlas-snapshot bumps don't trigger a sweep. Cached blobs stay on
/// whatever identity they were shaped against; the next `getCurrent`
/// call rebinds (or evicts) them lazily. Callers track live atlas
/// snapshots via `entriesForIdentity` so each snapshot's lease can be
/// released the moment the cache stops referencing it. Metrics changes
/// (font size, DPI) invalidate the entire cache because each cached
/// blob bakes `placement.em` into its per-instance `Transform2D`.
///
/// LRU order is tracked via an intrusive doubly-linked list across the
/// `Row` allocations themselves: `lru_head` is the next eviction
/// candidate, `lru_tail` the most-recently-used. Touching a row on
/// lookup or storing a new one moves it to the tail in O(1); evicting
/// pops the head in O(1).
pub const RowCache = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, *Row),
    cache_bytes: usize = 0,
    cache_budget: usize,
    /// Count of cached rows whose blob is bound to each atlas snapshot
    /// identity. Caller reads this via `entriesForIdentity` to decide
    /// when each snapshot's lease can be safely released.
    entries_by_identity: std.AutoHashMap(u64, usize),
    /// Content hashes whose entry was evicted this frame because the
    /// snapshot they reference is no longer rebindable (had_misses, or
    /// rebound failed). Callers drain this after `buildSnapshot` to
    /// zero matching slots in each TargetState — otherwise the
    /// freshly-shaped replacement row would be skipped by the dirty
    /// check (content_hash unchanged) and the dmabuf would keep
    /// showing stale glyphs.
    invalidations: std.ArrayList(u64),
    /// Oldest entry; next eviction candidate. Null when cache is empty.
    lru_head: ?*Row = null,
    /// Most-recently-used entry; new stores append here. Null when
    /// cache is empty.
    lru_tail: ?*Row = null,

    pub fn init(allocator: std.mem.Allocator, budget_bytes: usize) RowCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(u64, *Row).init(allocator),
            .cache_budget = budget_bytes,
            .entries_by_identity = std.AutoHashMap(u64, usize).init(allocator),
            .invalidations = .empty,
        };
    }

    pub fn deinit(self: *RowCache) void {
        self.clear();
        self.map.deinit();
        self.entries_by_identity.deinit();
        self.invalidations.deinit(self.allocator);
    }

    pub fn clear(self: *RowCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |row_pp| destroyRow(self.allocator, row_pp.*);
        self.map.clearRetainingCapacity();
        self.entries_by_identity.clearRetainingCapacity();
        self.invalidations.clearRetainingCapacity();
        self.cache_bytes = 0;
        self.lru_head = null;
        self.lru_tail = null;
    }

    /// Number of cached rows currently bound to `identity`. The caller
    /// holds a lease on each identity with a non-zero count; once a
    /// count drops to zero the lease can be released because no blob
    /// dereferences that snapshot anymore.
    pub fn entriesForIdentity(self: *const RowCache, identity: u64) usize {
        return self.entries_by_identity.get(identity) orelse 0;
    }

    /// Content hashes that lost their cache entry this frame due to
    /// stale-atlas state. Drained in one go by the caller — the slice
    /// stays valid until `clearInvalidations` or another cache mutation
    /// that grows the list.
    pub fn drainInvalidations(self: *RowCache) []const u64 {
        return self.invalidations.items;
    }

    pub fn clearInvalidations(self: *RowCache) void {
        self.invalidations.clearRetainingCapacity();
    }

    /// Look up a row by content hash, transparently migrating its blob
    /// onto the current atlas snapshot if it was shaped against an older
    /// one. Returns null on outright miss, on a stale `had_misses` entry
    /// (always re-shape so a freshly-extended atlas can fill the gaps),
    /// or on rebind failure. Both eviction paths queue `key` into
    /// `invalidations` so the caller can clear any downstream paint
    /// state keyed by the same content hash before the replacement row
    /// gets painted.
    ///
    /// `current_atlas` must outlive the call: the rebind path
    /// dereferences both the new and the row's old atlas pointers.
    pub fn getCurrent(
        self: *RowCache,
        key: u64,
        current_atlas: *const snail.TextAtlas,
        current_identity: u64,
    ) ?*Row {
        const row = self.map.get(key) orelse return null;
        if (row.had_misses) {
            self.queueInvalidation(key);
            self.evictRow(row);
            return null;
        }
        if (row.atlas_identity == current_identity) {
            self.touchLru(row);
            return row;
        }
        const new_blob = row.blob.rebound(self.allocator, current_atlas) catch {
            self.queueInvalidation(key);
            self.evictRow(row);
            return null;
        };
        const old_identity = row.atlas_identity;
        row.blob.deinit();
        row.blob.* = new_blob;
        row.atlas_identity = current_identity;
        self.decrementIdentity(old_identity);
        self.incrementIdentity(current_identity) catch {
            self.queueInvalidation(key);
            self.evictRow(row);
            return null;
        };
        self.touchLru(row);
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
        if (self.map.get(key)) |stale| self.evictRow(stale);

        const byte_size = rects.len * @sizeOf(ColoredRect) + blob.glyphCount() * 24;
        const blob_slot = self.allocator.create(snail.TextBlob) catch {
            var b = blob;
            b.deinit();
            self.allocator.free(rects);
            return null;
        };
        blob_slot.* = blob;
        const row = self.allocator.create(Row) catch {
            blob_slot.deinit();
            self.allocator.destroy(blob_slot);
            self.allocator.free(rects);
            return null;
        };
        row.* = .{
            .blob = blob_slot,
            .rects = rects,
            .content_hash = key,
            .atlas_identity = atlas_identity,
            .had_misses = had_misses,
            .byte_size = byte_size,
        };
        self.map.put(key, row) catch {
            destroyRow(self.allocator, row);
            return null;
        };
        self.cache_bytes += byte_size;
        self.appendLru(row);
        self.incrementIdentity(atlas_identity) catch {
            // Roll back the put so we don't keep a Row whose identity
            // bookkeeping is wrong. `evictRow` undoes everything we
            // just did (map, lru, cache_bytes) except identity
            // counting, which we never bumped — that's intentional.
            _ = self.map.remove(key);
            self.unlinkLru(row);
            self.cache_bytes -= byte_size;
            destroyRow(self.allocator, row);
            return null;
        };

        var guard: usize = 0;
        while (self.cache_bytes > self.cache_budget and guard < 32) : (guard += 1) {
            self.evictLru();
        }
        return row;
    }

    pub fn evict(self: *RowCache, key: u64) void {
        const row = self.map.get(key) orelse return;
        self.evictRow(row);
    }

    /// Drop `row` from the cache. Caller must hold a valid pointer;
    /// `getCurrent` and `evict` are the usual entry points.
    fn evictRow(self: *RowCache, row: *Row) void {
        _ = self.map.remove(row.content_hash);
        self.cache_bytes -= row.byte_size;
        self.decrementIdentity(row.atlas_identity);
        self.unlinkLru(row);
        destroyRow(self.allocator, row);
    }

    fn queueInvalidation(self: *RowCache, key: u64) void {
        self.invalidations.append(self.allocator, key) catch {};
    }

    fn incrementIdentity(self: *RowCache, identity: u64) !void {
        const gop = try self.entries_by_identity.getOrPut(identity);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    fn decrementIdentity(self: *RowCache, identity: u64) void {
        const count = self.entries_by_identity.getPtr(identity) orelse return;
        if (count.* > 0) count.* -= 1;
        if (count.* == 0) _ = self.entries_by_identity.remove(identity);
    }

    fn evictLru(self: *RowCache) void {
        const oldest = self.lru_head orelse return;
        self.evictRow(oldest);
    }

    /// Append `row` at the tail (most-recently-used end). Assumes the
    /// row is not currently in the list (its links are null, e.g.
    /// fresh from `store`).
    fn appendLru(self: *RowCache, row: *Row) void {
        row.lru_prev = self.lru_tail;
        row.lru_next = null;
        if (self.lru_tail) |t| t.lru_next = row;
        self.lru_tail = row;
        if (self.lru_head == null) self.lru_head = row;
    }

    /// Detach `row` from the list. Safe whether or not the row is the
    /// head/tail; the links are zeroed so `appendLru` can re-insert.
    fn unlinkLru(self: *RowCache, row: *Row) void {
        if (row.lru_prev) |p| p.lru_next = row.lru_next else self.lru_head = row.lru_next;
        if (row.lru_next) |n| n.lru_prev = row.lru_prev else self.lru_tail = row.lru_prev;
        row.lru_prev = null;
        row.lru_next = null;
    }

    /// Move `row` to the most-recently-used end. No-op when already
    /// there, which is the steady-state case for a hot row hit twice
    /// without any intervening stores.
    fn touchLru(self: *RowCache, row: *Row) void {
        if (row == self.lru_tail) return;
        self.unlinkLru(row);
        self.appendLru(row);
    }
};

fn destroyRow(allocator: std.mem.Allocator, row: *Row) void {
    row.blob.deinit();
    allocator.destroy(row.blob);
    allocator.free(row.rects);
    allocator.destroy(row);
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
    /// Optional right-edge scrollbar overlay. Renderers paint a thin
    /// band on top of everything else when present.
    scrollbar: ?render_snapshot.ScrollbarOverlay,
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

        var entry: ?*Row = cache.getCurrent(content_hash, atlas, atlas_identity);
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
        .scrollbar = snapshot.scrollbar,
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
