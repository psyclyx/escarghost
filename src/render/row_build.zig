//! Shared row-building primitives used by both the GPU (Vulkan) and
//! CPU (snail-raster) render paths. Iterates a row's cells, accumulates
//! same-fg text into HarfBuzz-shaped runs via snail 0.13's shape/place
//! pipeline, coalesces background spans, and emits underline / strike
//! decoration rects.
//!
//! In snail 0.13, the flow is:
//!   cells → snail.shape → snail.planRuns/prepare/apply → snail.placeCellRunAlloc
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
const powerline_glyphs = @import("powerline_glyphs.zig");
const box_glyphs = @import("box_glyphs.zig");
const perf = @import("../perf.zig");
const log = @import("../log.zig");
const Rgb = color.Rgb;
const bitmap_glyphs = @import("bitmap_glyphs.zig");
const palette = @import("../palette.zig");

/// Compose a per-cell `placement` (unit/em → screen) with a baked record's
/// design→source transform, mirroring snail's `PreparedPath.placedBy`
/// (`multiply(outer, design_to_source)`). One helper for every baked primitive
/// we instance ourselves — the unit rect, Powerline separators, and color-
/// bitmap glyphs — so the placement math lives in exactly one place and matches
/// snail's contract instead of being re-derived per call site.
pub fn placeBaked(placement: snail.Transform2D, design_to_source: snail.Transform2D) snail.Transform2D {
    return snail.Transform2D.multiply(placement, design_to_source);
}

/// If `shp`'s glyph ink is larger than the cell, shrink it (uniformly, never
/// upscale) so it fits — otherwise oversized fallback/tofu glyphs spill into
/// neighboring cells and read as noise. The shape's `local_transform` is the
/// glyph's em→screen placement (`{ xx = em, yy = -em, … }`); the glyph ink box
/// comes from the font in font units, scaled to em by `unitsPerEm`. We scale
/// about the ink's own center, so a glyph centered in its cell stays centered
/// and simply fits — no positional drift, and glyphs that already fit are
/// untouched (early return). Applied only to fallback/tofu glyphs by the caller.
fn fitGlyphToCell(
    shp: *snail.Shape,
    atlas_ref: *const atlas_ref_mod.AtlasRef,
    metrics: Metrics,
    font_id: u32,
    glyph_id: u16,
) void {
    const font = atlas_ref.fontForId(font_id) orelse return;
    const upem: f32 = @floatFromInt(font.unitsPerEm());
    if (upem <= 0) return;
    const bb = font.bbox(glyph_id) catch return;

    const t = shp.local_transform;
    const em = t.xx; // uniform em scale from placeCellRun
    const ink_w = em * (bb.max.x - bb.min.x) / upem;
    const ink_h = em * (bb.max.y - bb.min.y) / upem;
    if (ink_w <= 0 or ink_h <= 0) return;

    // A 1px slack keeps glyphs that only graze the cell edge from being scaled.
    const tol: f32 = 1.0;
    if (ink_w <= metrics.cell_width + tol and ink_h <= metrics.cell_height + tol) return;

    const s = @min(@min(metrics.cell_width / ink_w, metrics.cell_height / ink_h), 1.0);
    // Ink center in screen space (apply the placement transform to the em-unit
    // bbox midpoint; `t.yy` is negative, flipping y-up font space into the scene).
    const cx = t.tx + t.xx * ((bb.min.x + bb.max.x) * 0.5 / upem);
    const cy = t.ty + t.yy * ((bb.min.y + bb.max.y) * 0.5 / upem);
    const fit = snail.Transform2D{ .xx = s, .xy = 0, .yx = 0, .yy = s, .tx = cx * (1 - s), .ty = cy * (1 - s) };
    shp.local_transform = snail.Transform2D.multiply(fit, t);
}

// ── Phase counters (diagnostic) ──

pub var phase_row_rebuild_ns: u64 = 0;
pub var phase_row_shape_ns: u64 = 0;
pub var phase_row_finish_ns: u64 = 0;
pub var phase_row_count: u64 = 0;
/// Time inside snail.shape + place (HarfBuzz proper) vs the cell walk —
/// splits buildRow so "shaping is slow" claims can be checked against
/// where the time actually goes.
pub var phase_shape_call_ns: u64 = 0;
pub var phase_shape_call_count: u64 = 0;
pub var phase_cell_walk_ns: u64 = 0;

pub const MAX_RECTS_PER_ROW: usize = @as(usize, render_snapshot.MaxCols) * 3;

pub const ColoredRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
};

/// Up to 4 rects per box-drawing cell (cross arms / quadrants).
pub const MAX_BOX_RECTS_PER_ROW: usize = @as(usize, render_snapshot.MaxCols) * 4;

/// Rect sink handed to `box_glyphs.emit`. Appends into a caller-provided
/// buffer, applying the glyph's foreground color (with a per-rect alpha for
/// the shade characters). Silently drops rects past the buffer's capacity.
const BoxRectSink = struct {
    buf: []ColoredRect,
    n: *usize,
    color: [4]f32,

    pub fn rect(self: BoxRectSink, x: f32, y: f32, w: f32, h: f32, alpha: f32) void {
        if (w <= 0 or h <= 0 or alpha <= 0) return;
        if (self.n.* >= self.buf.len) return;
        self.buf[self.n.*] = .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .color = .{ self.color[0], self.color[1], self.color[2], self.color[3] * alpha },
        };
        self.n.* += 1;
    }
};

pub const Metrics = struct {
    cell_width: f32,
    cell_height: f32,
    font_size: f32,
    baseline_offset: f32,
    /// Device viewport size, for overlays (e.g. the command palette) that lay
    /// out against the whole surface rather than the cell grid. Zero when the
    /// caller doesn't need overlay layout.
    viewport_w: u32 = 0,
    viewport_h: u32 = 0,

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
///
/// `row` is caller-owned scratch, reset here. It must NOT be a local:
/// it's ~48 KB of `undefined` buffers, and in safety-checked builds every
/// `undefined` local is pattern-filled on entry — declared per row that
/// memset dwarfed all real work (~5 ms/frame of the "build" phase).
fn buildRow(
    snapshot: *const render_snapshot.SharedSnapshot,
    cell_index: *usize,
    cols: u16,
    row_y: f32,
    scratch_rects: []ColoredRect,
    atlas: *const snail.Atlas,
    atlas_ref: *const atlas_ref_mod.AtlasRef,
    faces: *snail.Faces,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    misses: *glyph_misses.Set,
    shapes_out: []snail.Shape,
    box_rects_out: []ColoredRect,
    row: *RowAccumulator,
) !struct { rect_count: usize, shape_count: usize, box_rect_count: usize, had_misses: bool } {
    var rect_count: usize = 0;
    var had_misses = false;
    row.reset();

    // Terminal-drawn glyphs written ahead of the shaped text. `pl_n`
    // Powerline separator shapes occupy shapes_out[0..pl_n]; `box_n`
    // box-drawing/block rects occupy box_rects_out[0..box_n].
    var pl_n: usize = 0;
    var box_n: usize = 0;
    const custom = atlas_ref.custom_glyphs;

    const default_fg = snapshot.header.default_fg;
    const default_bg = snapshot.header.default_bg;

    var bg_span_start: u16 = 0;
    var bg_span_color: ?Rgb = null;
    var bg_span_len: u16 = 0;

    const walk_t0 = perf.Timer.now();
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

        const cp = cell.codepoint;
        const has_renderable_text = flags.has_text and isRenderableCodepoint(cp);
        if (has_renderable_text) {
            const pl_prim = if (custom) atlas_ref.powerline.get(cp) else null;
            if (pl_prim) |prim| {
                // Powerline separator: instance the baked filled record over
                // the exact cell, tinted with the cell fg. Row-local (row_y is
                // added by the emit-time world transform).
                if (pl_n < shapes_out.len) {
                    const col_x = @as(f32, @floatFromInt(col_idx)) * metrics.cell_width;
                    const outer = snail.Transform2D{
                        .xx = metrics.cell_width,
                        .yy = metrics.cell_height,
                        .tx = col_x,
                        .ty = row_y,
                    };
                    shapes_out[pl_n] = .{
                        .key = prim.key,
                        .local_transform = placeBaked(outer, prim.xform),
                        .local_color = fg.toLinearFloat4(1.0),
                    };
                    pl_n += 1;
                }
            } else if (custom and box_glyphs.isHandled(cp)) {
                // Box-drawing / block element: emit device-space rects sized
                // to the cell with pixel-consistent line thickness.
                const col_x = @as(f32, @floatFromInt(col_idx)) * metrics.cell_width;
                const sink = BoxRectSink{ .buf = box_rects_out, .n = &box_n, .color = fg.toLinearFloat4(1.0) };
                box_glyphs.emit(cp, col_x, row_y, metrics.cell_width, metrics.cell_height, sink);
            } else {
                row.appendCell(cp, col_idx, fg);
            }
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

    phase_cell_walk_ns += walk_t0.elapsedNs();

    // Shape + record + place. Text shapes go after any Powerline shapes we
    // already wrote at shapes_out[0..pl_n].
    var shape_count: usize = pl_n;
    const shape_t = perf.Timer.now();
    defer {
        phase_shape_call_ns += shape_t.elapsedNs();
    }
    if (!row.isEmpty()) {
        phase_shape_call_count += 1;
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
            return .{ .rect_count = rect_count, .shape_count = shape_count, .box_rect_count = box_n, .had_misses = false };
        };
        defer shaped.deinit();

        const ppem: u16 = @intFromFloat(@round(metrics.font_size));

        // TrueType hinting for the primary face (font_id 0). A column is hinted
        // only when *every* glyph landing on it is primary, so the residency key
        // and the `placeCellRun` key always agree and every emitted key is baked
        // (the prep thread bakes primary TT + all-fonts unhinted). Fallback/emoji
        // columns stay unhinted. The key ppem = round(em), matching the prep ppem
        // and the placement `em/ppem` scale.
        const tt_on = atlas_ref.ttEffective();
        const ppem_26_6: u32 = @as(u32, ppem) << 6;
        var fallback_cols = std.StaticBitSet(render_snapshot.MaxCols).initEmpty();
        if (tt_on) {
            for (shaped.glyphs) |glyph| {
                if (glyph.font_id == 0) continue;
                if (glyph.source_start >= row.byte_to_col.len) continue;
                const col = row.byte_to_col[glyph.source_start];
                if (col < render_snapshot.MaxCols) fallback_cols.set(col);
            }
        }

        if (shaped.glyphs.len > 0) {
            // Detect glyphs not yet present in the (immutable) atlas
            // snapshot. The render path must never mutate the shared atlas
            // — the atlas owner thread extends it — so this is read-only:
            // any absent glyph marks the whole row as a miss and its text
            // is collected below so the caller can request an extension.
            for (shaped.glyphs) |glyph| {
                const font_id = faces.fontIdForFace(glyph.face_index) orelse continue;
                // Emoji: a known color-bitmap strike is served by its own record
                // (image-painted), not the outline. Residency is checked against
                // *this frame's* atlas snapshot — the same one `emit` draws from —
                // so a strike present in the global table but not yet in the
                // leased snapshot counts as a miss and the freshest-complete loop
                // waits for the snapshot to catch up (matching outline glyphs).
                // First sighting (strike not yet discovered) falls through to the
                // outline check, which triggers the prep pass that discovers and
                // bakes the strike.
                if (atlas_ref.bitmaps.hasStrike(font_id, glyph.glyph_id)) {
                    const bkey = snail.record_key.colorBitmapGlyph(font_id, @intCast(glyph.glyph_id), ppem);
                    if (!atlas.contains(bkey)) {
                        had_misses = true;
                        break;
                    }
                    continue;
                }
                // Match the key `placeCellRun` will emit: primary glyphs on a
                // hinted column resolve the TT record, everything else unhinted.
                const col = if (glyph.source_start < row.byte_to_col.len)
                    row.byte_to_col[glyph.source_start]
                else
                    render_snapshot.MaxCols;
                const use_tt = tt_on and font_id == 0 and
                    col < render_snapshot.MaxCols and !fallback_cols.isSet(col);
                const key = if (use_tt)
                    snail.record_key.ttHintedGlyph(0, @intCast(glyph.glyph_id), ppem_26_6)
                else
                    snail.record_key.unhintedGlyph(font_id, @intCast(glyph.glyph_id));
                if (!atlas.contains(key)) {
                    had_misses = true;
                    break;
                }
            }

            // Per-cell hint mode. `row` is reused scratch and `appendCell` never
            // writes `.mode`, so set it explicitly for every cell each row (both
            // on and off) — otherwise a mode from a previous row could linger.
            for (row.cells[0..row.cell_count]) |*cell| {
                cell.mode = if (tt_on and cell.column < render_snapshot.MaxCols and
                    !fallback_cols.isSet(cell.column))
                    .{ .tt_hint = .{ .ppem_26_6 = ppem_26_6 } }
                else
                    .unhinted;
            }

            // Place cells into shapes
            const baseline_y = row_y + metrics.baseline();
            const placement: snail.CellRunPlacement = .{
                .baseline = .{ .x = 0, .y = baseline_y },
                .cell_width = metrics.cell_width,
                .em = metrics.font_size,
                // Hinted glyphs want their origins on integer pixels; unhinted
                // terminal cells keep the cheaper baseline/advance snap.
                .snap = if (tt_on) .glyph_origins else .grid,
                .world_to_pixel = .identity,
                .colr = true,
            };

            const avail = shapes_out[pl_n..];
            const expected_count = snail.placedCellRunShapeCount(&shaped, faces, row.cells[0..row.cell_count], placement) catch 0;
            if (expected_count > 0 and expected_count <= avail.len) {
                const placed = snail.placeCellRun(avail[0..expected_count], &shaped, faces, row.cells[0..row.cell_count], placement) catch {
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
                    return .{ .rect_count = rect_count, .shape_count = shape_count, .box_rect_count = box_n, .had_misses = had_misses };
                };
                shape_count = pl_n + placed.len;

                // Post-process each placed outline shape. `placeCellRun` may
                // expand COLR glyphs, so a placed shape isn't 1:1 with a source
                // glyph — match by its record key, which carries
                // (font_id, glyph_id) for outline shapes.
                for (placed) |*shp| {
                    if (shp.key.namespace != snail.record_key.ns.unhinted_glyph) continue;
                    const font_id = shp.key.a;
                    const glyph_id: u16 = @intCast(shp.key.b);

                    // 1) Color-bitmap strike: swap onto the image record when it
                    // is resident in *this frame's* snapshot (miss detection above
                    // holds the frame until it is). The bitmap carries its own
                    // color (untinted); its em-bbox rect is placed by folding the
                    // record's design→source into the glyph's em→screen transform,
                    // exactly like an outline glyph occupies the cell. Strike
                    // glyphs never fall through to the outline-fit below. See
                    // [[custom_glyphs]].
                    if (atlas_ref.bitmaps.hasStrike(font_id, glyph_id)) {
                        if (atlas_ref.bitmaps.get(.{ .font_id = font_id, .glyph_id = glyph_id, .ppem = ppem })) |entry| {
                            if (atlas.contains(entry.key)) {
                                shp.key = entry.key;
                                shp.local_color = .{ 1, 1, 1, 1 };
                                shp.local_transform = placeBaked(shp.local_transform, entry.xform);
                            }
                        }
                        continue;
                    }

                    // 2) Fallback / tofu glyphs whose ink overflows the cell
                    // look awful spilling into neighbors. Shrink an oversized one
                    // to fit. Primary-font text (font_id 0, non-`.notdef`) is
                    // left untouched — it's designed for the cell.
                    if (font_id != 0 or glyph_id == 0) {
                        fitGlyphToCell(shp, atlas_ref, metrics, font_id, glyph_id);
                    }
                }
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

    return .{ .rect_count = rect_count, .shape_count = shape_count, .box_rect_count = box_n, .had_misses = had_misses };
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
    /// Terminal-drawn box-drawing / block-element rects, in device space.
    /// Emitted above the background rects but below text (over the cell bg).
    box_rects: []ColoredRect,
    row_y: f32,
};

pub const CursorOverlay = struct {
    cell_x: u16,
    cell_y: u16,
    style: render_snapshot.CursorStyle,
    color: Rgb,
    /// For a block cursor over a glyph: the covered glyph re-placed in the
    /// cell's background color, drawn on top of the (opaque) block so it reads
    /// inverted instead of vanishing. Empty for non-block cursors / empty cells.
    glyph: []const snail.Shape = &.{},
};

pub const SelectionSpan = struct {
    row: u16,
    start_col: u16,
    end_col: u16,
};

pub const MAX_SELECTION_SPANS: usize = render_snapshot.MaxRows;

/// Fully laid-out command palette for a frame: device-space rects (backdrop,
/// panel, selection highlight) and absolutely-positioned text glyphs. Both
/// pipelines render it as the topmost layer. Null when the palette is closed.
pub const BuiltPalette = struct {
    rects: []const ColoredRect,
    shapes: []const snail.Shape,
};

pub const BuiltSnapshot = struct {
    rows: []const RowDraw,
    cursor: ?CursorOverlay,
    selection_spans: []const SelectionSpan,
    scrollbar: ?render_snapshot.ScrollbarOverlay,
    bell: ?render_snapshot.BellOverlay,
    palette: ?BuiltPalette,
};

/// Max shapes per row — generous upper bound for a full row of glyphs.
const MAX_SHAPES_PER_ROW: usize = render_snapshot.MaxCols * 4;

/// Row-scratch owned by the pipeline (~300 KB), passed into
/// `buildSnapshot` each frame. Lives in the (heap-allocated) pipeline
/// struct rather than as a local: safety-checked builds pattern-fill
/// `undefined` locals on every scope entry, so even a hoisted per-call
/// local re-pays a ~300 KB memset per frame. As a field it's filled once
/// at pipeline init.
pub const RowScratch = struct {
    shapes: [MAX_SHAPES_PER_ROW]snail.Shape = undefined,
    acc: RowAccumulator = .{},
};

/// Walk a snapshot row-by-row, shape each row's text, and capture cursor
/// state in one pass.
pub fn buildSnapshot(
    snapshot: *const render_snapshot.SharedSnapshot,
    allocator: std.mem.Allocator,
    metrics: Metrics,
    atlas: *const snail.Atlas,
    atlas_ref: *const atlas_ref_mod.AtlasRef,
    faces: *snail.Faces,
    scratch_rects: []ColoredRect,
    box_rects_scratch: []ColoredRect,
    rows_out: []RowDraw,
    selection_spans_out: []SelectionSpan,
    rect_stash: *EphemeralBlobs,
    misses: *glyph_misses.Set,
    row_scratch: *RowScratch,
) !BuiltSnapshot {
    const header = snapshot.header;
    const default_fg = header.default_fg;
    const default_bg = header.default_bg;
    const rows = @min(header.rows, render_snapshot.MaxRows);
    const cols = @min(header.cols, render_snapshot.MaxCols);

    var cell_index: usize = 0;
    var cursor_cell: ?render_common.CursorCell = null;
    // The cursor cell's own placed glyph(s), recolored to the cell background,
    // captured from the row as it's built. Drawn over the opaque block cursor so
    // the covered glyph reads inverted. Empty for non-block cursors / empty
    // cells. Reuses the exact shapes the row drew — same placement, key, and
    // hinting — rather than re-shaping.
    var cursor_glyph_shapes: []const snail.Shape = &.{};
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

        const built = try buildRow(
            snapshot,
            &cell_index,
            cols,
            0,
            scratch_rects,
            atlas,
            atlas_ref,
            faces,
            allocator,
            metrics,
            misses,
            &row_scratch.shapes,
            box_rects_scratch,
            &row_scratch.acc,
        );
        phase_row_shape_ns += shape_t0.elapsedNs();

        // Copy shapes + rects to heap for stable references
        const shapes = try allocator.dupe(snail.Shape, row_scratch.shapes[0..built.shape_count]);
        try rect_stash.stashShapes(shapes);

        // Block cursor on this row: clone the covered cell's already-placed
        // glyph(s) in the cell background color for the cursor layer to draw
        // over the opaque block (inverted). Row shapes are absolute in x (`tx`)
        // but row-relative in y, so fold this row's `row_y` into `ty` — the
        // cursor layer emits them without the per-row translation.
        if (header.cursor_style == .block and row_idx == header.cursor_y) {
            if (cursor_cell) |cc| if (cc.has_text) {
                const cl = @as(f32, @floatFromInt(header.cursor_x)) * metrics.cell_width;
                const half = metrics.cell_width * 0.5;
                const bg4 = cc.bg.toLinearFloat4(1.0);
                var list: std.ArrayListUnmanaged(snail.Shape) = .empty;
                for (shapes) |shp| {
                    if (shp.local_transform.tx >= cl - half and shp.local_transform.tx < cl + half) {
                        var c = shp;
                        c.local_color = bg4;
                        c.local_transform.ty += row_y;
                        list.append(allocator, c) catch continue;
                    }
                }
                if (list.items.len > 0) {
                    if (list.toOwnedSlice(allocator)) |owned| {
                        if (rect_stash.stashShapes(owned)) |_| {
                            cursor_glyph_shapes = owned;
                        } else |_| allocator.free(owned);
                    } else |_| list.deinit(allocator);
                } else list.deinit(allocator);
            };
        }

        const rects = try allocator.dupe(ColoredRect, scratch_rects[0..built.rect_count]);
        try rect_stash.stashRects(rects);
        const box_rects = try allocator.dupe(ColoredRect, box_rects_scratch[0..built.box_rect_count]);
        try rect_stash.stashRects(box_rects);

        phase_row_finish_ns += perf.Timer.now().elapsedNs();
        phase_row_rebuild_ns += rebuild_t0.elapsedNs();
        phase_row_count += 1;
        cell_index = next_index;

        rows_out[row_count] = .{ .shapes = shapes, .rects = rects, .box_rects = box_rects, .row_y = row_y };
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
            .glyph = cursor_glyph_shapes,
        };
    }

    const spans = resolveSelectionSpans(snapshot, selection_spans_out, rows, cols);

    const built_palette = if (snapshot.palette) |ov|
        buildPalette(ov, metrics, atlas, atlas_ref, faces, allocator, rect_stash, misses) catch null
    else
        null;

    return .{
        .rows = rows_out[0..row_count],
        .cursor = cursor,
        .selection_spans = spans,
        .scrollbar = snapshot.scrollbar,
        .bell = snapshot.bell,
        .palette = built_palette,
    };
}

// ── Command palette layout + shaping ──

/// Palette colors (sRGB 0–255; converted to linear straight-alpha at build).
const palette_colors = struct {
    const backdrop = Rgb{ .r = 0, .g = 0, .b = 0 }; // dim the terminal
    const panel = Rgb{ .r = 24, .g = 26, .b = 33 };
    const selected = Rgb{ .r = 46, .g = 82, .b = 148 };
    const query_fg = Rgb{ .r = 236, .g = 238, .b = 244 };
    const name_fg = Rgb{ .r = 208, .g = 212, .b = 220 };
    const name_sel_fg = Rgb{ .r = 255, .g = 255, .b = 255 };
    const category_fg = Rgb{ .r = 128, .g = 134, .b = 148 };
    const value_fg = Rgb{ .r = 150, .g = 200, .b = 230 }; // current setting value
};

/// Lay out the palette panel + text into device-space rects and shapes. Text is
/// shaped through the same atlas as the terminal; glyphs not yet resident are
/// dropped and their run is fed to `misses` so the prep thread bakes them (they
/// fill in on a later frame, like terminal pop-in). Allocations are stashed in
/// `rect_stash` so they outlive the build and reach emit.
fn buildPalette(
    ov: palette.Overlay,
    metrics: Metrics,
    atlas: *const snail.Atlas,
    atlas_ref: *const atlas_ref_mod.AtlasRef,
    faces: *snail.Faces,
    allocator: std.mem.Allocator,
    rect_stash: *EphemeralBlobs,
    misses: *glyph_misses.Set,
) !?BuiltPalette {
    _ = atlas_ref;
    const vw: f32 = @floatFromInt(metrics.viewport_w);
    const vh: f32 = @floatFromInt(metrics.viewport_h);
    if (vw <= 0 or vh <= 0 or metrics.cell_height <= 0) return null;

    const em = metrics.font_size;
    const line_h = metrics.cell_height;
    const pad = @round(line_h * 0.5);
    const total_lines: f32 = @floatFromInt(1 + ov.row_count); // query + rows

    const box_w = @min(@round(vw * 0.7), 960.0);
    const box_h = total_lines * line_h + pad * 2.0;
    const box_x = @round((vw - box_w) / 2.0);
    const box_y = @round(vh * 0.12);
    const text_x = box_x + pad;
    const text_right = box_x + box_w - pad;

    var rects: std.ArrayListUnmanaged(ColoredRect) = .empty;
    var shapes: std.ArrayListUnmanaged(snail.Shape) = .empty;

    // Backdrop over the whole viewport, then the panel.
    try rects.append(allocator, .{ .x = 0, .y = 0, .w = vw, .h = vh, .color = palette_colors.backdrop.toLinearFloat4(0.55) });
    try rects.append(allocator, .{ .x = box_x, .y = box_y, .w = box_w, .h = box_h, .color = palette_colors.panel.toLinearFloat4(0.98) });

    // baseline for a text line whose cell-top is `top`.
    const baselineFor = struct {
        fn f(top: f32, m: Metrics) f32 {
            return top + m.baseline_offset;
        }
    }.f;

    // Query line.
    const q_top = box_y + pad;
    var qbuf: [palette.MAX_QUERY + 2]u8 = undefined;
    qbuf[0] = '>';
    qbuf[1] = ' ';
    const qtext = ov.queryText();
    @memcpy(qbuf[2 .. 2 + qtext.len], qtext);
    try appendTextRun(&shapes, allocator, atlas, faces, misses, text_x, baselineFor(q_top, metrics), em, qbuf[0 .. 2 + qtext.len], palette_colors.query_fg.toLinearFloat4(1.0), null);

    // Command rows.
    for (ov.rows[0..ov.row_count], 0..) |row, i| {
        const row_top = box_y + pad + line_h * @as(f32, @floatFromInt(i + 1));
        const base = baselineFor(row_top, metrics);
        if (row.selected) {
            try rects.append(allocator, .{
                .x = box_x + @round(pad * 0.5),
                .y = row_top,
                .w = box_w - pad,
                .h = line_h,
                .color = palette_colors.selected.toLinearFloat4(0.95),
            });
        }
        const name_col = if (row.selected) palette_colors.name_sel_fg else palette_colors.name_fg;
        try appendTextRun(&shapes, allocator, atlas, faces, misses, text_x, base, em, row.name, name_col.toLinearFloat4(1.0), null);
        // Right-aligned: the command's current value (accent) when it has one,
        // otherwise its category (dim).
        if (row.value_len > 0) {
            try appendTextRun(&shapes, allocator, atlas, faces, misses, text_right, base, em, row.valueText(), palette_colors.value_fg.toLinearFloat4(1.0), text_right);
        } else {
            try appendTextRun(&shapes, allocator, atlas, faces, misses, text_right, base, em, row.category, palette_colors.category_fg.toLinearFloat4(1.0), text_right);
        }
    }

    const rects_owned = try rects.toOwnedSlice(allocator);
    try rect_stash.stashRects(rects_owned);
    const shapes_owned = try shapes.toOwnedSlice(allocator);
    try rect_stash.stashShapes(shapes_owned);
    return .{ .rects = rects_owned, .shapes = shapes_owned };
}

/// Shape `text` and append its resident glyph shapes at baseline (x, y). When
/// `right_align_x` is non-null, the run's right edge is placed there instead
/// (x is ignored). Missing glyphs are dropped and the run fed to `misses`.
fn appendTextRun(
    shapes: *std.ArrayListUnmanaged(snail.Shape),
    allocator: std.mem.Allocator,
    atlas: *const snail.Atlas,
    faces: *snail.Faces,
    misses: *glyph_misses.Set,
    x: f32,
    y: f32,
    em: f32,
    text: []const u8,
    col: [4]f32,
    right_align_x: ?f32,
) !void {
    if (text.len == 0) return;
    var shaped = snail.shape(allocator, faces, text, .{}) catch return;
    defer shaped.deinit();
    if (shaped.glyphs.len == 0) return;

    const start_x = if (right_align_x) |rx| rx - em * shaped.advanceX() else x;
    const placed = snail.placeRunAlloc(allocator, &shaped, faces, .{
        .baseline = .{ .x = start_x, .y = y },
        .em = em,
        .color = col,
        .snap = .none,
    }) catch return;
    defer allocator.free(placed);

    var had_miss = false;
    for (placed) |shp| {
        if (atlas.contains(shp.key)) {
            try shapes.append(allocator, shp);
        } else {
            had_miss = true;
        }
    }
    if (had_miss) misses.addRun(text);
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
