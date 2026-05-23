const std = @import("std");
const snail = @import("snail");
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

const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GLES3/gl3.h");
    @cInclude("GLES3/gl3ext.h");
});

const MAX_SNAPSHOT_ROWS: usize = render_snapshot.MaxRows;
const MAX_OVERRIDES: usize = MAX_SNAPSHOT_ROWS + 4; // rows + cursor blob

// Stable resource keys. Atlas dedupes across blobs; the picture is rebuilt
// every frame but reuses the same key so snail's resource cache can identify
// the upload as a content change rather than a new resource. Per-blob paint
// keys (derived from blob pointer in textKeysFor) are unique per blob so
// hinted glyphs' paint records survive the manifest's dedupe.
const ATLAS_KEY = snail.ResourceKey.named("scrgo.atlas");
const PICTURE_KEY = snail.ResourceKey.named("scrgo.rects");

/// Resource keys for a blob: shared atlas key + (for hinted/painted blobs) a
/// per-blob paint key derived from the blob pointer. Non-hinted blobs return
/// `.paint = null`, matching the old single-key behaviour.
fn textKeysFor(blob: *const snail.TextBlob) snail.TextResourceKeys {
    return blob.resourceKeys(ATLAS_KEY, snail.ResourceKey.fromId(@intFromPtr(blob)));
}

// 1 atlas + 1 picture + up to (MAX_SNAPSHOT_ROWS + cursor) paint records.
const MANIFEST_CAP: usize = MAX_SNAPSHOT_ROWS + 4;

// Baseline offset factor for the warmup glyph. Synthetic — close enough
// to a typical font's ascent ratio that the warm-up output lands in a
// sane place on the dmabuf before we invalidate and repaint. Real frames
// use the font's snapped ascent (CellMetrics.baseline_offset).
const baseline_warm: f32 = 0.8;

pub const CellMetrics = struct {
    /// Pixel-snapped em. The user's requested font_size rounded to
    /// the device pixel grid so glyph rasterization happens at integer
    /// ppem. Stored back into app state so subsequent zoom steps work
    /// off the snapped value (an unchanged ±1 stays an unchanged ±1).
    em: f32,
    /// Font's natural 'M' advance at the snapped em — *not* pixel-
    /// snapped. A well-behaved monospace font's ligatures (`==`, `=>`,
    /// `fl`, etc.) have advances that are exact N×em multiples of this,
    /// so HB's per-glyph positions land on our cell grid by construction.
    /// Snapping cell_width to whole pixels would drift the cell grid
    /// away from HB's pen and break long uniform-color stretches.
    cell_width: f32,
    /// Line height with @ceil to preserve descender headroom.
    cell_height: f32,
    /// Font's snapped ascent. Glyph baselines land at row_y +
    /// baseline_offset, on whole pixels.
    baseline_offset: f32,
};

/// Compute terminal cell dimensions from the atlas's primary face.
/// In `.grid` / `.tt` modes, snaps `em` and `baseline_offset` to whole
/// pixels via snail's TextCellGrid helper. In `.none` mode, returns
/// the raw unsnapped em with a synthetic `cell_height * 0.8` baseline,
/// matching the pre-cellGrid behaviour for A/B comparison.
pub fn computeCellMetrics(atlas: *const snail.TextAtlas, font_size: f32) !CellMetrics {
    const mode = render_env.loadHintMode();
    if (mode == .none) {
        const cm = try atlas.cellMetrics(.{ .em = font_size });
        const cell_height = @ceil(cm.line_height);
        return .{
            .em = font_size,
            .cell_width = cm.cell_width,
            .cell_height = cell_height,
            .baseline_offset = cell_height * 0.8,
        };
    }
    const grid = try atlas.cellGrid(.{
        .em = font_size,
        .pixel_step = .{ .x = 1.0, .y = 1.0 },
        .snap_rule = .nearest,
    });
    const cm = try atlas.cellMetrics(.{ .em = grid.em });
    return .{
        .em = grid.em,
        .cell_width = cm.cell_width,
        .cell_height = @ceil(cm.line_height),
        .baseline_offset = grid.baseline_offset,
    };
}

pub fn computeGridSize(cell_width: f32, cell_height: f32, pixel_w: u32, pixel_h: u32) struct { cols: u16, rows: u16 } {
    return .{
        .cols = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_w)) / cell_width))),
        .rows = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_h)) / cell_height))),
    };
}

/// GPU renderer state. Owned exclusively by the GPU renderer thread.
/// Reads the shared atlas (via AtlasRef, lock-free).
pub const GpuPipeline = struct {
    allocator: std.mem.Allocator,
    atlas_ref: *atlas_ref_mod.AtlasRef,
    /// Lease on the current atlas snapshot. Swapped (and the old one
    /// released) in `refreshAtlas` when the atlas thread publishes a
    /// new identity. No blob outlives the frame that built it, so we
    /// never need to retain more than one snapshot.
    atlas_lease: atlas_ref_mod.AtlasRef.Lease,

    gl_renderer: snail.Gles30Renderer,
    scene: snail.Scene,
    builder: snail.TextBlobBuilder,
    /// TrueType hint context bound to the current atlas snapshot. Reset
    /// in refreshAtlas when the snapshot identity changes (which happens
    /// each time the atlas thread publishes new glyphs). Per-glyph hint
    /// computations are cached inside until the next reset.
    hint_ctx: snail.TrueTypeHintContext,

    last_atlas_gen: u64 = 0,
    last_atlas_identity: u64 = 0,

    scratch_rects: []row_build.ColoredRect = &.{},
    overrides: [MAX_OVERRIDES]snail.Override = undefined,
    manifest_entries: [MANIFEST_CAP]snail.ResourceManifest.Entry = undefined,

    draw_buf: std.ArrayList(u32) = .empty,
    seg_buf: std.ArrayList(snail.DrawList.Segment) = .empty,

    /// Per-frame ephemeral blob storage (cursor inversion). Heap-allocated
    /// so the scene can record stable `*const TextBlob` pointers across
    /// mid-frame growth; bulk-released after each frame.
    ephemeral_blobs: row_build.EphemeralBlobs,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,
    baseline_offset: f32,
    viewport_w: f32,
    viewport_h: f32,
    config: render_env.RenderConfig,

    scratch_ready: bool = false,
    /// Enables expensive per-frame GL instrumentation: glFinish to wait
    /// for the draw to complete before reading back, glReadPixels to
    /// sample the FBO, and the scene-sample log line. Driven by
    /// SCRGO_TRACE; off in normal use.
    trace_frames: bool = false,
    debug_reset_atlas_each_frame: bool = false,

    pub var frame_stats: perf.FrameStats = .{};

    /// Per-phase wall-time accumulators (ns). Written by the GPU worker
    /// thread only; main reads them at exit when SCRGO_LOG=commits. Single
    /// writer + single reader, race is benign for diagnostics.
    pub var phase_row_build_ns: u64 = 0;
    pub var phase_picture_ns: u64 = 0;
    pub var phase_upload_ns: u64 = 0;
    pub var phase_drawlist_ns: u64 = 0;
    pub var phase_draw_ns: u64 = 0;
    pub var phase_frame_count: u64 = 0;

    pub fn init(
        allocator: std.mem.Allocator,
        atlas_ref: *atlas_ref_mod.AtlasRef,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
        baseline_offset: f32,
    ) !GpuPipeline {
        var gl_renderer = try snail.Gles30Renderer.init(allocator);
        errdefer gl_renderer.deinit();

        var atlas_lease = atlas_ref.acquire();
        errdefer atlas_lease.release();
        const atlas = atlas_lease.get();
        const initial_identity = atlas.snapshotIdentity();
        const builder = snail.TextBlobBuilder.init(allocator, atlas);
        var scene = snail.Scene.init(allocator);
        errdefer scene.deinit();
        const hint_ctx = snail.TrueTypeHintContext.init(allocator, atlas);

        return .{
            .allocator = allocator,
            .atlas_ref = atlas_ref,
            .atlas_lease = atlas_lease,
            .gl_renderer = gl_renderer,
            .scene = scene,
            .builder = builder,
            .hint_ctx = hint_ctx,
            .last_atlas_gen = atlas_ref.loadGeneration(),
            .last_atlas_identity = initial_identity,
            .ephemeral_blobs = row_build.EphemeralBlobs.init(allocator),
            .cell_width = cell_width,
            .cell_height = cell_height,
            .font_size = font_size,
            .baseline_offset = baseline_offset,
            .viewport_w = 0,
            .viewport_h = 0,
            .config = render_env.loadRenderConfigFromEnv(),
        };
    }

    pub fn deinit(self: *GpuPipeline) void {
        self.ephemeral_blobs.deinit();
        if (self.scratch_ready) self.allocator.free(self.scratch_rects);
        self.draw_buf.deinit(self.allocator);
        self.seg_buf.deinit(self.allocator);
        self.builder.deinit();
        self.hint_ctx.deinit();
        self.atlas_lease.release();
        self.scene.deinit();
        self.gl_renderer.deinit();
    }

    fn currentAtlas(self: *const GpuPipeline) *const snail.TextAtlas {
        return self.atlas_lease.get();
    }

    /// No-op kept for API stability with the gpu_worker worker. We
    /// don't keep per-dmabuf paint state anymore — every frame paints
    /// itself fully into whichever dmabuf the caller bound.
    pub fn setActiveTarget(self: *GpuPipeline, idx: u8) void {
        _ = self;
        _ = idx;
    }

    /// Render a tiny synthetic frame to compile every shader program
    /// snail will use at steady state: text (glyph blob), vector path
    /// (filled rect), and the linear-resolve shaders. Atlas textures +
    /// glyph pages get uploaded here too. Without this, those one-time
    /// costs would land on the first real frames the user sees as
    /// visible jank.
    pub fn warmPipeline(self: *GpuPipeline) !void {
        defer {
            self.scene.reset();
            self.builder.reset();
            self.ephemeral_blobs.releaseAll();
        }

        const atlas = self.currentAtlas();
        self.scene.reset();
        self.builder.reset();

        // Path picture: one tiny rect → compiles vector path shader
        // and exercises the path-picture upload path.
        var picture_builder = snail.PathPictureBuilder.init(self.allocator);
        defer picture_builder.deinit();
        try picture_builder.addFilledRect(
            .{ .x = 0, .y = 0, .w = 2, .h = 2 },
            .{ .paint = .{ .solid = .{ 1, 1, 1, 1 } } },
            .identity,
        );
        var picture = try picture_builder.freeze(.{
            .persistent_allocator = self.allocator,
            .scratch_allocator = self.allocator,
        });
        defer picture.deinit();

        // Text blob: shape & lay out one glyph → compiles text shader
        // and forces the atlas to be uploaded to the GPU. We pick 'a'
        // because atlas_owner's bootstrap populates ASCII.
        var shaped = self.atlas_ref.shape(atlas, self.allocator, .{}, "a") catch null;
        var blob_opt: ?snail.TextBlob = null;
        defer if (blob_opt) |*b| b.deinit();
        if (shaped) |*s| {
            defer s.deinit();
            _ = self.builder.append(.{
                .shaped = s,
                .placement = .{
                    .baseline = .{ .x = 0, .y = self.cell_height * baseline_warm },
                    .em = self.font_size,
                },
                .fill = .{ .solid = .{ 1, 1, 1, 1 } },
            }) catch null;
            blob_opt = self.builder.finish() catch null;
        }

        var manifest = snail.ResourceManifest.init(self.manifest_entries[0..]);
        try manifest.putPathPicture(PICTURE_KEY, &picture);
        try self.scene.addPath(.{ .picture = &picture, .resource_key = PICTURE_KEY });

        if (blob_opt) |*blob| {
            const text_keys = textKeysFor(blob);
            try manifest.putTextBlob(text_keys, blob);
            try self.scene.addText(.{ .blob = blob, .resources = text_keys });
        }

        var prepared = try self.gl_renderer.uploadResourcesBlocking(
            .{ .persistent = self.allocator, .scratch = self.allocator },
            &manifest,
        );
        defer prepared.deinit();

        const buf_words = snail.DrawList.estimate(&self.scene);
        const seg_count = snail.DrawList.estimateSegments(&self.scene);
        try self.draw_buf.resize(self.allocator, buf_words);
        try self.seg_buf.resize(self.allocator, seg_count);
        var draw_list = snail.DrawList.init(self.draw_buf.items, self.seg_buf.items);
        try draw_list.addScene(&prepared, &self.scene);

        const pass: snail.DrawPass = .{
            .state = self.drawState(),
            .resolve = .{ .linear = .{
                .backdrop = .target,
                .region = .{ .pixel_rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 } },
            } },
        };
        try self.gl_renderer.drawPass(&prepared, &draw_list, pass);
        gl.glFinish();
    }

    /// Notify the renderer that the output buffer set has been
    /// (re)allocated. Every dmabuf now backs a *new* texture with
    /// undefined pixel contents, so any "this buffer is seeded"
    /// belief from the prior allocation is stale and must be dropped
    /// — otherwise the next paint reads garbage via `backdrop = .target`.
    /// Call this whenever the GPU side re-imports its dmabufs (initial
    /// install, reconfigure, GPU/context restart, etc.), even if the
    /// viewport dimensions didn't change.
    /// No-op kept for API stability. With every frame fully repainting
    /// every row, there is no per-dmabuf "seeded" state to invalidate
    /// when the GPU side reinstalls its dmabufs.
    pub fn notifyTargetsReinstalled(self: *GpuPipeline) void {
        _ = self;
    }

    fn ensureScratch(self: *GpuPipeline) !void {
        if (self.scratch_ready) return;
        self.scratch_rects = try self.allocator.alloc(row_build.ColoredRect, row_build.MAX_RECTS_PER_ROW);
        self.scratch_ready = true;
    }

    pub fn setDebugResetAtlas(self: *GpuPipeline, enabled: bool) void {
        self.debug_reset_atlas_each_frame = enabled;
    }

    pub fn setTraceFrames(self: *GpuPipeline, enabled: bool) void {
        self.trace_frames = enabled;
    }

    /// Resize the drawable. Pure window-resize; cell metrics are unchanged.
    pub fn setViewport(self: *GpuPipeline, w: u32, h: u32) void {
        if (self.viewport_w == @as(f32, @floatFromInt(w)) and self.viewport_h == @as(f32, @floatFromInt(h))) return;
        self.viewport_w = @floatFromInt(w);
        self.viewport_h = @floatFromInt(h);
    }

    /// Update font metrics. No-op when metrics are unchanged.
    pub fn setMetrics(self: *GpuPipeline, font_size: f32, cell_width: f32, cell_height: f32, baseline_offset: f32) void {
        if (self.font_size == font_size and
            self.cell_width == cell_width and
            self.cell_height == cell_height and
            self.baseline_offset == baseline_offset) return;
        self.font_size = font_size;
        self.cell_width = cell_width;
        self.cell_height = cell_height;
        self.baseline_offset = baseline_offset;
    }

    /// Pick up the latest atlas snapshot. Swaps the retained lease and
    /// rebuilds the builder against the fresh atlas. Safe to call only
    /// at frame boundaries: the previous frame's ephemeral blobs must
    /// have been released before the old lease is dropped here.
    fn refreshAtlas(self: *GpuPipeline) *const snail.TextAtlas {
        var next_lease = self.atlas_ref.acquire();
        const atlas = next_lease.get();
        const identity = atlas.snapshotIdentity();
        if (identity == self.last_atlas_identity) {
            next_lease.release();
            return self.atlas_lease.get();
        }

        self.atlas_lease.release();
        self.atlas_lease = next_lease;
        self.last_atlas_gen = self.atlas_ref.loadGeneration();
        self.last_atlas_identity = identity;

        // Builder is anchored to the prior snapshot; rebuild it.
        self.builder.deinit();
        self.builder = snail.TextBlobBuilder.init(self.allocator, atlas);
        // Hint context's per-glyph cache is keyed by atlas identity; clear it.
        // Timed because the next frame will pay the cost of re-hinting every
        // glyph it touches, and that has to fit inside the sync-extend budget.
        const reset_t0 = perf.Timer.now();
        self.hint_ctx.resetForAtlas(atlas);
        const reset_ns = reset_t0.elapsedNs();

        log.info(.gpu, "atlas snapshot", .{
            .identity = identity,
            .hint_reset_us = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(reset_ns)) / @as(f64, std.time.ns_per_us)}),
        });
        return atlas;
    }

    fn rowMetrics(self: *const GpuPipeline) row_build.Metrics {
        return .{
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .font_size = self.font_size,
            .baseline_offset = self.baseline_offset,
        };
    }

    /// Emit cursor geometry into the per-frame path picture. Cursor edges
    /// snap to integer pixel boundaries by computing both edges in float
    /// (cell_width is fractional) and rounding each separately — never
    /// multiplying `cell_x` by a truncated width.
    fn emitCursor(self: *const GpuPipeline, picture: *snail.PathPictureBuilder, cursor: row_build.CursorOverlay) !void {
        const x0_f = @as(f32, @floatFromInt(cursor.cell_x)) * self.cell_width;
        const y0_f = @as(f32, @floatFromInt(cursor.cell_y)) * self.cell_height;
        const x1_f = @as(f32, @floatFromInt(cursor.cell_x + 1)) * self.cell_width;
        const y1_f = @as(f32, @floatFromInt(cursor.cell_y + 1)) * self.cell_height;
        const x0 = @round(x0_f);
        const y0 = @round(y0_f);
        const x1 = @round(x1_f);
        const y1 = @round(y1_f);
        const cw = @max(1.0, x1 - x0);
        const ch = @max(1.0, y1 - y0);
        const cc = cursor.color.toFloat4(1.0);
        const fill: snail.FillStyle = .{ .paint = .{ .solid = cc } };
        switch (cursor.style) {
            .block => try picture.addFilledRect(.{ .x = x0, .y = y0, .w = cw, .h = ch }, fill, .identity),
            .bar => try picture.addFilledRect(.{ .x = x0, .y = y0, .w = 2.0, .h = ch }, fill, .identity),
            .underline => try picture.addFilledRect(.{ .x = x0, .y = y0 + ch - 2.0, .w = cw, .h = 2.0 }, fill, .identity),
            .block_hollow => try picture.addStrokedRect(
                .{ .x = x0, .y = y0, .w = cw, .h = ch },
                .{ .paint = .{ .solid = cc }, .width = 1.5, .placement = .inside },
                .identity,
            ),
        }
    }

    fn drawState(self: *const GpuPipeline) snail.DrawState {
        return .{
            .mvp = snail.Mat4.ortho(0, self.viewport_w, self.viewport_h, 0, -1, 1),
            .surface = .{
                .pixel_width = self.viewport_w,
                .pixel_height = self.viewport_h,
                // FBO storage is linear-format (mesa rejects sRGB dmabuf
                // imports), consumer expects sRGB bytes. The .linear resolve
                // below tells snail to render into a linear RGBA16F
                // intermediate and encode-pass the result into our linear
                // attachment.
                .encoding = .srgb_pixels_on_linear_attachment,
            },
            .raster = render_env.effectiveRasterOptions(self.config),
        };
    }

    pub fn drawSnapshot(self: *GpuPipeline, snapshot: *const render_snapshot.SharedSnapshot, misses: *glyph_misses.Set) !void {
        const frame_timer = perf.Timer.now();
        const atlas = self.refreshAtlas();
        try self.ensureScratch();
        // Caller has already bound the active target's dmabuf FBO; we
        // render straight into it. Each dmabuf retains its own pixels
        // across the swap chain rotation, so backdrop=.target preserves
        // prior frames painted into the *same* dmabuf and we only have
        // to repaint rows that differ from this buffer's recorded era.
        self.scene.reset();

        var rows_buf: [MAX_SNAPSHOT_ROWS]row_build.RowDraw = undefined;
        var sel_buf: [row_build.MAX_SELECTION_SPANS]row_build.SelectionSpan = undefined;
        const row_build_t0 = perf.Timer.now();
        const built = try row_build.buildSnapshot(
            snapshot,
            self.allocator,
            self.rowMetrics(),
            &self.builder,
            atlas,
            self.atlas_ref,
            self.scratch_rects,
            rows_buf[0..],
            sel_buf[0..],
            &self.ephemeral_blobs,
            misses,
            &self.hint_ctx,
        );
        phase_row_build_ns += row_build_t0.elapsedNs();

        // Misses on the freshly-shaped blob are reported via `misses`
        // upward. The GPU worker (gpu_worker.zig) hands them to the
        // async atlas thread (`atlas_thread.requestMany`) so the next
        // frame's atlas snapshot will include them. We deliberately do
        // NOT extend the atlas synchronously and re-shape this frame:
        // the old path doubled the per-frame row-build cost whenever a
        // new glyph showed up, which on a workload like tmatrix (a
        // steady trickle of fresh codepoints) means every-other frame
        // is twice as expensive and blows the vsync budget. Shipping
        // partial-glyph content for one frame is invisible at 60 Hz
        // when the surrounding cells are turning over anyway.

        try self.flushDraw(built, snapshot.header.default_bg, snapshot.header.default_fg);
        self.ephemeral_blobs.releaseAll();
        frame_stats.record(frame_timer.elapsedUs());
    }

    fn flushDraw(self: *GpuPipeline, built: row_build.BuiltSnapshot, default_bg: Rgb, default_fg: Rgb) !void {
        // Full-frame repaint every frame: paint the background, every
        // row's bg/decoration rects, every row's glyphs, the cursor,
        // any selection bands, and the scrollbar. We rely on snail's
        // `backdrop = .clear` to seed the output to the bg color so we
        // don't have to emit a per-row bg fill.
        const picture_t0 = perf.Timer.now();
        var picture_builder = snail.PathPictureBuilder.init(self.allocator);
        defer picture_builder.deinit();

        for (built.rows) |row_draw| {
            for (row_draw.rects) |r| {
                if (r.w <= 0.0 or r.h <= 0.0) continue;
                try picture_builder.addFilledRect(
                    .{ .x = r.x, .y = r.y + row_draw.row_y, .w = r.w, .h = r.h },
                    .{ .paint = .{ .solid = r.color } },
                    .identity,
                );
            }
        }
        // Selection highlight: covers cell bg, text reads on top of it.
        if (built.selection_spans.len > 0) {
            const sel_color = render_common.selectionFillColor(default_bg);
            for (built.selection_spans) |span| {
                const x0 = @as(f32, @floatFromInt(span.start_col)) * self.cell_width;
                const y0 = @as(f32, @floatFromInt(span.row)) * self.cell_height;
                const w = @as(f32, @floatFromInt(span.end_col - span.start_col + 1)) * self.cell_width;
                try picture_builder.addFilledRect(
                    .{ .x = x0, .y = y0, .w = w, .h = self.cell_height },
                    .{ .paint = .{ .solid = sel_color } },
                    .identity,
                );
            }
        }
        if (built.cursor) |cursor| try self.emitCursor(&picture_builder, cursor);

        // Scrollbar overlay on the right edge. Paint last so it sits
        // on top of everything else. When the scrollbar is visible we
        // emit it on every dirty frame (the dirty set already covers
        // every row whenever the scrollbar state changes).
        if (built.scrollbar) |sb| {
            const geom = render_common.scrollbarGeometry(self.viewport_w, self.viewport_h, sb.thumb_offset, sb.thumb_size);
            const sc = render_common.scrollbarColors(default_fg, sb.alpha);
            try picture_builder.addFilledRect(
                .{ .x = geom.gutter_x, .y = geom.gutter_y, .w = geom.gutter_w, .h = geom.gutter_h },
                .{ .paint = .{ .solid = sc.gutter } },
                .identity,
            );
            try picture_builder.addFilledRect(
                .{ .x = geom.gutter_x, .y = geom.thumb_y, .w = geom.gutter_w, .h = geom.thumb_h },
                .{ .paint = .{ .solid = sc.thumb } },
                .identity,
            );
        }

        // Visual-bell overlay: translucent full-viewport rect tinted by
        // default_fg. Last in paint order so the tint sits over text +
        // scrollbar; alpha fades to 0 across the bell window.
        if (built.bell) |bell| {
            if (bell.alpha > 0) {
                const tint = default_fg.toFloat4(1.0);
                const a = @min(1.0, @max(0.0, bell.alpha)) * 0.25;
                try picture_builder.addFilledRect(
                    .{ .x = 0, .y = 0, .w = self.viewport_w, .h = self.viewport_h },
                    .{ .paint = .{ .solid = .{ tint[0], tint[1], tint[2], a } } },
                    .identity,
                );
            }
        }

        // Picture is optional: a frame that paints only glyphs (no bg
        // rects, no cursor, no scrollbar) leaves the builder empty and
        // `freeze` errors with EmptyPicture. The text-only path still
        // works — backdrop=.clear gives us a clean default-bg canvas.
        var maybe_picture: ?snail.PathPicture = if (picture_builder.shapeCount() > 0) try picture_builder.freeze(.{
            .persistent_allocator = self.allocator,
            .scratch_allocator = self.allocator,
        }) else null;
        defer if (maybe_picture) |*p| p.deinit();
        phase_picture_ns += picture_t0.elapsedNs();

        var manifest = snail.ResourceManifest.init(self.manifest_entries[0..]);
        if (maybe_picture) |*picture| {
            try manifest.putPathPicture(PICTURE_KEY, picture);
            try self.scene.addPath(.{ .picture = picture, .resource_key = PICTURE_KEY });
        }

        var override_index: usize = 0;
        for (built.rows) |row_draw| {
            if (row_draw.blob.glyphCount() == 0) continue;
            if (override_index >= self.overrides.len) break;
            self.overrides[override_index] = .{
                .transform = snail.Transform2D.translate(0, row_draw.row_y),
                .tint = .{ 1, 1, 1, 1 },
            };
            const slot = self.overrides[override_index .. override_index + 1];
            override_index += 1;
            const row_keys = textKeysFor(row_draw.blob);
            try manifest.putTextBlob(row_keys, row_draw.blob);
            try self.scene.addText(.{
                .blob = row_draw.blob,
                .resources = row_keys,
                .instances = slot,
            });
        }
        if (built.cursor) |cursor| {
            if (cursor.inverted_glyph) |blob| {
                const cursor_keys = textKeysFor(blob);
                try manifest.putTextBlob(cursor_keys, blob);
                try self.scene.addText(.{ .blob = blob, .resources = cursor_keys });
            }
        }

        const upload_t0 = perf.Timer.now();
        var prepared = try self.gl_renderer.uploadResourcesBlocking(
            .{ .persistent = self.allocator, .scratch = self.allocator },
            &manifest,
        );
        defer prepared.deinit();
        phase_upload_ns += upload_t0.elapsedNs();

        const drawlist_t0 = perf.Timer.now();
        const buf_words = snail.DrawList.estimate(&self.scene);
        const seg_count = snail.DrawList.estimateSegments(&self.scene);
        try self.draw_buf.resize(self.allocator, buf_words);
        try self.seg_buf.resize(self.allocator, seg_count);
        var draw_list = snail.DrawList.init(self.draw_buf.items, self.seg_buf.items);
        try draw_list.addScene(&prepared, &self.scene);
        phase_drawlist_ns += drawlist_t0.elapsedNs();

        // Every frame paints the entire viewport from scratch into the
        // caller's dmabuf, so backdrop is always .clear (snail seeds
        // the output with the default bg) and the resolve region is
        // always the full target.
        const pass: snail.DrawPass = .{
            .state = self.drawState(),
            .resolve = .{ .linear = .{
                .backdrop = .{ .clear = default_bg.toFloat4(1.0) },
                .region = .full_target,
            } },
        };
        // Per-frame scene stats so we can spot "GPU went blank" cases. Counts
        // include the rect-picture shape count, the number of text blobs
        // added to the scene, and the total glyph count across all blobs.
        // If a frame goes blank but stats are non-zero, the issue is on the
        // GL side (resource-cache or context); if stats drop to zero, the
        // build/snapshot is the suspect.
        var total_glyphs: usize = 0;
        for (built.rows) |row_draw| total_glyphs += row_draw.blob.glyphCount();
        if (built.cursor) |cursor| {
            if (cursor.inverted_glyph) |blob| total_glyphs += blob.glyphCount();
        }
        const scene_shapes: usize = if (maybe_picture) |*p| p.shapeCount() else 0;
        const scene_text_blobs = self.scene.commandCount();

        const draw_t0 = perf.Timer.now();
        try self.gl_renderer.drawPass(&prepared, &draw_list, pass);

        // Block on the GPU pipeline before reading back. glFlush alone is
        // fire-and-forget; for a readback we need the FBO to actually have
        // its contents before glReadPixels samples it. (The cost is paid
        // only when frame logging is on.)
        if (self.trace_frames) gl.glFinish() else gl.glFlush();
        phase_draw_ns += draw_t0.elapsedNs();
        phase_frame_count += 1;

        // Check for GL errors after the draw. Persistent errors after a
        // context loss / driver hiccup explain "screen went blank but our
        // pipeline thinks it's fine".
        var gl_err: gl.GLenum = gl.glGetError();
        var error_count: u32 = 0;
        while (gl_err != gl.GL_NO_ERROR and error_count < 4) {
            error_count += 1;
            log.warn(.gpu, "GL error after drawPass", .{
                .code = log.fmt("0x{x}", .{gl_err}),
                .frame = phase_frame_count,
            });
            gl_err = gl.glGetError();
        }

        if (self.trace_frames) {
            // Sample 5 pixels across the FBO to see what actually landed in
            // it. If the dmabuf is all bg color (or all zero) while scene
            // stats show content, the snail/GL pipeline produced an empty
            // output despite non-empty inputs.
            const w_i: gl.GLint = @intFromFloat(@max(self.viewport_w, 1.0));
            const h_i: gl.GLint = @intFromFloat(@max(self.viewport_h, 1.0));
            const sample_xs = [_]gl.GLint{ @divTrunc(w_i, 5), @divTrunc(w_i * 2, 5), @divTrunc(w_i, 2), @divTrunc(w_i * 3, 5), @divTrunc(w_i * 4, 5) };
            const sample_y: gl.GLint = @divTrunc(h_i, 2);
            var pixels: [5][4]u8 = undefined;
            for (sample_xs, 0..) |x, i| {
                gl.glReadPixels(x, sample_y, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &pixels[i]);
            }
            log.info(.gpu, "scene", .{
                .frame = phase_frame_count,
                .rects = scene_shapes,
                .blobs = scene_text_blobs,
                .glyphs = total_glyphs,
                .rows = built.rows.len,
                .px = log.fmt("[{x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2}]", .{
                    pixels[0][0], pixels[0][1], pixels[0][2],
                    pixels[1][0], pixels[1][1], pixels[1][2],
                    pixels[2][0], pixels[2][1], pixels[2][2],
                    pixels[3][0], pixels[3][1], pixels[3][2],
                    pixels[4][0], pixels[4][1], pixels[4][2],
                }),
            });
        }
    }
};
