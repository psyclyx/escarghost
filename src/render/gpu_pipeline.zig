//! GPU pipeline: cell metrics, grid sizing, and Vulkan render integration.
//!
//! In snail 0.13, the render flow is:
//!   row_build.buildSnapshot → snail.Shape[]
//!   → snail.emit.emit → Instance[] + DrawBatch[]
//!   → vk.Renderer.render (records Vulkan draw commands)
//!
//! The GpuPipeline struct owns the per-frame scratch buffers and
//! coordinates atlas refresh + snapshot building + emit + draw.

const std = @import("std");
const snail = @import("snail");
const raster = @import("snail-raster");
const atlas_ref_mod = @import("atlas_ref.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const render_common = @import("render_common.zig");
const glyph_misses = @import("glyph_misses.zig");
const row_build = @import("row_build.zig");
const color = @import("color");
const perf = @import("../perf.zig");
const log = @import("../log.zig");
const Rgb = color.Rgb;

pub var snapshot_phase_ns: u64 = 0;
pub var snapshot_phase_count: u64 = 0;
pub var capture_cells_accum_ns: u64 = 0;
pub var worker_wait_accum_ns: u64 = 0;
pub var worker_wait_count: u64 = 0;
pub var buffer_starvation_accum_ns: u64 = 0;
pub var buffer_starvation_count: u64 = 0;

pub const CellMetrics = struct {
    em: f32,
    cell_width: f32,
    cell_height: f32,
    baseline_offset: f32,
    /// Font descent below the baseline, in device pixels (positive). The
    /// baseline sits at `baseline_offset` from the cell top; the glyph text
    /// box therefore ends at `baseline_offset + descent`. Used to size the
    /// bar and underline cursors to the font rather than the full cell.
    descent: f32,
};

/// Compute terminal cell dimensions from the primary font.
pub fn computeCellMetrics(faces: *const snail.Faces, font_size: f32) !CellMetrics {
    const face = faces.faceCount() > 0;
    if (!face) return error.NoFaces;
    const font = faces.fontForFace(0) orelse return error.NoPrimaryFont;

    const units_per_em: f32 = @floatFromInt(font.unitsPerEm());
    const scale = font_size / units_per_em;

    const line = try font.lineMetrics();
    const ascent_f: f32 = @floatFromInt(line.ascent);
    const descent_f: f32 = @floatFromInt(line.descent);
    const line_gap_f: f32 = @floatFromInt(line.line_gap);

    const line_height = (ascent_f - descent_f + line_gap_f) * scale;
    const cell_height = @ceil(line_height);
    const baseline_offset = @floor(ascent_f * scale);
    // `line.descent` is negative (below baseline); flip to a positive device
    // depth. Clamp to whatever room is left under the baseline in the cell.
    const descent = @min(@round(-descent_f * scale), cell_height - baseline_offset);

    // Round the cell width to whole device pixels. snail's placeCellRun snaps
    // glyphs to `@round(world_to_pixel.xx * cell_width)` under `CellSnap.grid`
    // (world_to_pixel is identity here), so every column→pixel conversion we do
    // ourselves — cursor, background spans, decorations, selection — must use
    // the same integer advance or the cursor drifts ahead of the glyphs.
    const glyph_id = font.glyphIndex('M') catch 0;
    const cell_width: f32 = if (glyph_id != 0) blk: {
        const adv = font.advanceWidth(glyph_id) catch 0;
        const adv_f: f32 = @floatFromInt(adv);
        break :blk @round(adv_f * scale);
    } else @round(font_size * 0.6);

    return .{
        .em = font_size,
        .cell_width = cell_width,
        .cell_height = cell_height,
        .baseline_offset = baseline_offset,
        .descent = descent,
    };
}

pub fn computeGridSize(cell_width: f32, cell_height: f32, pixel_w: u32, pixel_h: u32) struct { cols: u16, rows: u16 } {
    // Clamp to the renderer's snapshot capacity. The terminal is sized to what
    // we can actually render, so columns/rows past the cap are never created
    // (and so never silently dropped) — the window just pads on the far edge.
    const cols_f = @max(1.0, @floor(@as(f32, @floatFromInt(pixel_w)) / cell_width));
    const rows_f = @max(1.0, @floor(@as(f32, @floatFromInt(pixel_h)) / cell_height));
    return .{
        .cols = @intFromFloat(@min(cols_f, @as(f32, @floatFromInt(render_snapshot.MaxCols)))),
        .rows = @intFromFloat(@min(rows_f, @as(f32, @floatFromInt(render_snapshot.MaxRows)))),
    };
}

pub const frame_stats = FrameStats{};

pub const FrameStats = struct {
    pub fn dump(self: FrameStats, label: []const u8) void {
        _ = self;
        _ = label;
    }
};

/// GPU renderer state. Owned by the GPU worker thread.
/// Reads the shared atlas via AtlasRef (lock-free).
const Instance = snail.render.records.Instance;
const DrawBatch = snail.render.records.DrawBatch;
const Binding = snail.render.records.Binding;

const white_tint: [4]f32 = .{ 1, 1, 1, 1 };

pub const GpuPipeline = struct {
    allocator: std.mem.Allocator,
    atlas_ref: *atlas_ref_mod.AtlasRef,
    viewport_w: u32 = 0,
    viewport_h: u32 = 0,
    font_size: f32 = 0,
    cell_width: f32 = 0,
    cell_height: f32 = 0,
    baseline_offset: f32 = 0,
    descent: f32 = 0,

    // Scratch buffers for row_build
    scratch_rects: [row_build.MAX_RECTS_PER_ROW]row_build.ColoredRect = undefined,
    scratch_box_rects: [row_build.MAX_BOX_RECTS_PER_ROW]row_build.ColoredRect = undefined,
    rows_out: [render_snapshot.MaxRows]row_build.RowDraw = undefined,
    selection_spans: [row_build.MAX_SELECTION_SPANS]row_build.SelectionSpan = undefined,
    eph: row_build.EphemeralBlobs,
    misses: glyph_misses.Set = .{},

    // Result of the last `buildShapes` — consumed by `emitBuilt`. Its slices
    // point into rows_out / selection_spans / the eph stash, valid until the
    // next `buildShapes` (which releases the stash).
    built: ?row_build.BuiltSnapshot = null,

    // Emit output — refilled each frame; valid slices are
    // instances.items[0..emit_instance_len] / batches.items[0..emit_batch_len].
    instances: std.ArrayList(Instance) = .empty,
    batches: std.ArrayList(DrawBatch) = .empty,
    emit_instance_len: usize = 0,
    emit_batch_len: usize = 0,

    /// Initialize in place. `self` must point at allocated (uninitialized)
    /// storage — GpuPipeline embeds several-MB scratch arrays, so returning
    /// it by value would blow the caller's stack.
    pub fn init(self: *GpuPipeline, allocator: std.mem.Allocator, atlas_ref: *atlas_ref_mod.AtlasRef) !void {
        self.* = .{
            .allocator = allocator,
            .atlas_ref = atlas_ref,
            .eph = row_build.EphemeralBlobs.init(allocator),
        };
    }

    pub fn deinit(self: *GpuPipeline) void {
        self.eph.deinit();
        self.instances.deinit(self.allocator);
        self.batches.deinit(self.allocator);
    }

    pub fn configure(
        self: *GpuPipeline,
        width: u32,
        height: u32,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
        baseline_offset: f32,
        descent: f32,
    ) void {
        self.viewport_w = width;
        self.viewport_h = height;
        self.font_size = font_size;
        self.cell_width = cell_width;
        self.cell_height = cell_height;
        self.baseline_offset = baseline_offset;
        self.descent = descent;
    }

    /// Placed glyph instances built by the last `buildAndEmit` call.
    pub fn emittedInstances(self: *const GpuPipeline) []const Instance {
        return self.instances.items[0..self.emit_instance_len];
    }

    /// Draw batches built by the last `buildAndEmit` call.
    pub fn emittedBatches(self: *const GpuPipeline) []const DrawBatch {
        return self.batches.items[0..self.emit_batch_len];
    }

    /// Shape + place the snapshot against `atlas`, storing the result for a
    /// later `emitBuilt`. Returns true if any glyph is missing from `atlas`
    /// (caller should extend the atlas and rebuild before emitting — emitting
    /// against an incomplete atlas would fail per row). No emit happens here,
    /// so the miss-then-extend cycle produces no spurious emit errors.
    pub fn buildShapes(
        self: *GpuPipeline,
        atlas: *const snail.Atlas,
        faces: *snail.Faces,
        snapshot: *const render_snapshot.SharedSnapshot,
    ) !bool {
        self.eph.releaseAll();
        self.misses.clear();

        const metrics: row_build.Metrics = .{
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .font_size = self.font_size,
            .baseline_offset = self.baseline_offset,
        };

        // Serialize shaping: the CPU and GPU workers share one HarfBuzz
        // buffer via `Faces`, so concurrent shapes corrupt it. Scoped to
        // just the shape — the caller's extend()/emit run outside it.
        self.built = blk: {
            self.atlas_ref.lockShaping();
            defer self.atlas_ref.unlockShaping();
            break :blk try row_build.buildSnapshot(
                snapshot,
                self.allocator,
                metrics,
                atlas,
                self.atlas_ref,
                faces,
                &self.scratch_rects,
                &self.scratch_box_rects,
                &self.rows_out,
                &self.selection_spans,
                &self.eph,
                &self.misses,
            );
        };
        return !self.misses.isEmpty();
    }

    /// Emit the shapes from the last `buildShapes` into the instance/batch
    /// buffers using `binding` — which MUST be the binding returned by the
    /// device-atlas upload of the same `atlas` the shapes were built against.
    pub fn emitBuilt(
        self: *GpuPipeline,
        atlas: *const snail.Atlas,
        binding: Binding,
        snapshot: *const render_snapshot.SharedSnapshot,
    ) !void {
        self.instances.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        self.emit_instance_len = 0;
        self.emit_batch_len = 0;

        const built = self.built orelse return;

        var total_shapes: usize = 0;
        for (built.rows) |row| total_shapes += row.shapes.len;
        var total_rects: usize = 0;
        for (built.rows) |row| total_rects += row.rects.len;
        total_rects += built.selection_spans.len + 8; // cursor(≤4) + scrollbar(2) + bell(1) + slack

        // Generous upper bound: emit may fan a glyph shape into several
        // per-layer instances (COLR / hinted); each rect is one instance.
        const cap = (total_shapes + total_rects) * 8 + 128;
        try self.instances.resize(self.allocator, cap);
        try self.batches.resize(self.allocator, cap);

        const default_bg = snapshot.header.default_bg;
        const default_fg = snapshot.header.default_fg;

        // Emit back-to-front. All fills reference the atlas's unit-rect record;
        // per-rect color/alpha rides in `world_tint` (path fills ignore
        // local_color), so consecutive rects coalesce into a few path batches.
        var il: usize = 0;
        var bl: usize = 0;

        // ── Layer 1: background spans + decoration rects (row-local → +row_y) ──
        for (built.rows) |row| {
            for (row.rects) |rect| {
                self.emitRect(&il, &bl, binding, atlas, rect.x, rect.y + row.row_y, rect.w, rect.h, rect.color);
            }
        }

        // ── Layer 2: selection highlight (translucent, behind text) ──
        if (built.selection_spans.len > 0) {
            const sel = render_common.selectionFillColor(default_bg);
            for (built.selection_spans) |span| {
                const x = @as(f32, @floatFromInt(span.start_col)) * self.cell_width;
                const w = @as(f32, @floatFromInt(span.end_col - span.start_col + 1)) * self.cell_width;
                const y = @as(f32, @floatFromInt(span.row)) * self.cell_height;
                self.emitRect(&il, &bl, binding, atlas, x, y, w, self.cell_height, sel);
            }
        }

        // ── Layer 2.5: box-drawing / block glyphs (over bg, under text) ──
        for (built.rows) |row| {
            for (row.box_rects) |rect| {
                self.emitRect(&il, &bl, binding, atlas, rect.x, rect.y + row.row_y, rect.w, rect.h, rect.color);
            }
        }

        // ── Layer 3: text glyphs ──
        for (built.rows) |row| {
            if (row.shapes.len == 0) continue;
            const xform = snail.Transform2D.translate(0, row.row_y);
            _ = snail.emit.emit(
                self.instances.items,
                self.batches.items,
                &il,
                &bl,
                binding,
                atlas,
                row.shapes,
                xform,
                white_tint,
            ) catch |err| {
                log.warn(.gpu, "emit failed for row", .{ .err = err });
                continue;
            };
        }

        // ── Layer 4: cursor ──
        if (built.cursor) |cursor| self.emitCursor(&il, &bl, binding, atlas, cursor);

        // ── Layer 5: scrollbar ──
        if (built.scrollbar) |sb| {
            if (sb.alpha > 0) {
                const geo = render_common.scrollbarGeometry(
                    @floatFromInt(self.viewport_w),
                    @floatFromInt(self.viewport_h),
                    sb.thumb_offset,
                    sb.thumb_size,
                );
                const colors = render_common.scrollbarColors(default_fg, sb.alpha);
                self.emitRect(&il, &bl, binding, atlas, geo.gutter_x, geo.gutter_y, geo.gutter_w, geo.gutter_h, colors.gutter);
                self.emitRect(&il, &bl, binding, atlas, geo.gutter_x, geo.thumb_y, geo.gutter_w, geo.thumb_h, colors.thumb);
            }
        }

        // ── Layer 6: visual bell — full-viewport tint ──
        if (built.bell) |bell| {
            if (bell.alpha > 0) {
                const fg = default_fg.toLinearFloat4(1.0);
                self.emitRect(&il, &bl, binding, atlas, 0, 0, @floatFromInt(self.viewport_w), @floatFromInt(self.viewport_h), .{ fg[0], fg[1], fg[2], 0.15 * bell.alpha });
            }
        }

        self.emit_instance_len = il;
        self.emit_batch_len = bl;
    }

    /// Emit one solid/translucent rectangle (in pixel space) as an instance of
    /// the atlas's unit-rect record. Color+alpha ride in `world_tint`.
    fn emitRect(
        self: *GpuPipeline,
        il: *usize,
        bl: *usize,
        binding: Binding,
        atlas: *const snail.Atlas,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        tint: [4]f32,
    ) void {
        if (w <= 0 or h <= 0 or tint[3] <= 0) return;
        // Map the unit rect (0,0,1,1) onto (x,y,w,h), then into the record's
        // design frame. Color rides in `local_color` (snail 0.13.1 honors it
        // for path fills), so all rects share one white `world_tint`.
        const outer = snail.Transform2D{ .xx = w, .yy = h, .tx = x, .ty = y };
        const shape = snail.Shape{
            .key = self.atlas_ref.rect_key,
            .local_transform = outer.multiply(self.atlas_ref.rect_xform),
            .local_color = tint,
        };
        _ = snail.emit.emit(
            self.instances.items,
            self.batches.items,
            il,
            bl,
            binding,
            atlas,
            &.{shape},
            .identity,
            white_tint,
        ) catch {};
    }

    fn emitCursor(
        self: *GpuPipeline,
        il: *usize,
        bl: *usize,
        binding: Binding,
        atlas: *const snail.Atlas,
        cursor: row_build.CursorOverlay,
    ) void {
        const x = @as(f32, @floatFromInt(cursor.cell_x)) * self.cell_width;
        const y = @as(f32, @floatFromInt(cursor.cell_y)) * self.cell_height;
        const cw = self.cell_width;
        const ch = self.cell_height;
        switch (cursor.style) {
            .block => self.emitRect(il, bl, binding, atlas, x, y, cw, ch, cursor.color.toLinearFloat4(0.7)),
            .bar => {
                const ext = render_common.barCursorExtent(y, ch, self.baseline_offset, self.descent);
                self.emitRect(il, bl, binding, atlas, x, ext.y, 2, ext.h, cursor.color.toLinearFloat4(1.0));
            },
            .underline => {
                const ext = render_common.underlineCursorExtent(y, ch, self.baseline_offset, self.descent);
                self.emitRect(il, bl, binding, atlas, x, ext.y, cw, ext.h, cursor.color.toLinearFloat4(1.0));
            },
            .block_hollow => {
                const c1 = cursor.color.toLinearFloat4(1.0);
                self.emitRect(il, bl, binding, atlas, x, y, cw, 1, c1);
                self.emitRect(il, bl, binding, atlas, x, y + ch - 1, cw, 1, c1);
                self.emitRect(il, bl, binding, atlas, x, y, 1, ch, c1);
                self.emitRect(il, bl, binding, atlas, x + cw - 1, y, 1, ch, c1);
            },
        }
    }
};
