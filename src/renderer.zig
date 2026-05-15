const std = @import("std");
const snail = @import("snail");
const atlas_ref_mod = @import("atlas_ref.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const render_config = @import("render_config.zig");
const glyph_misses = @import("glyph_misses.zig");
const row_build = @import("row_build.zig");
const gl_rect = @import("gl_rect.zig");
const color = @import("color.zig");
const perf = @import("perf.zig");
const Rgb = color.Rgb;
const ColoredRect = row_build.ColoredRect;

const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
});

const MAX_RECTS_PER_ROW: usize = row_build.MAX_RECTS_PER_ROW;
const MAX_DRAW_RECTS: usize = 400 * 200 * 3 + 16;
const MAX_SNAPSHOT_ROWS: usize = render_snapshot.MaxRows;
const MAX_OVERRIDES: usize = MAX_SNAPSHOT_ROWS + 4; // rows + cursor blob
const RESOURCE_ENTRY_CAP: usize = 4;

pub const CellMetrics = struct { cell_width: f32, cell_height: f32 };

/// Compute terminal cell dimensions from the atlas's primary face.
/// Cell width is the font's natural 'M' advance — *not* ceiled. A
/// well-behaved monospace font's ligatures (`==`, `=>`, `fl`, etc.) have
/// advances that are exact N×em multiples of this, so HB's natural glyph
/// advances align with our cell grid by construction. Rounding cell_width
/// up would compound a fractional-pixel mismatch over a long row and
/// drift the cursor away from the text.
pub fn computeCellMetrics(atlas: *const snail.TextAtlas, font_size: f32) !CellMetrics {
    const cm = try atlas.cellMetrics(.{ .em = font_size });
    return .{
        .cell_width = cm.cell_width,
        .cell_height = @ceil(cm.line_height),
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
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    atlas_ref: *atlas_ref_mod.AtlasRef,
    atlas_lease: atlas_ref_mod.AtlasRef.Lease,

    gl_renderer: snail.GlRenderer,
    scene: snail.Scene,
    builder: snail.TextBlobBuilder,

    prepared: ?snail.PreparedResources = null,
    prepared_atlas_identity: u64 = 0,
    last_atlas_gen: u64 = 0,
    last_atlas_identity: u64 = 0,

    rect_renderer: gl_rect.GlRectRenderer,

    row_cache: row_build.RowCache,

    draw_rects: []ColoredRect = &.{},
    scratch_rects: []ColoredRect = &.{},
    overrides: [MAX_OVERRIDES]snail.Override = undefined,
    resource_entries: [RESOURCE_ENTRY_CAP]snail.ResourceSet.Entry = undefined,

    draw_buf: std.ArrayList(u32) = .empty,
    seg_buf: std.ArrayList(snail.DrawSegment) = .empty,

    /// Per-frame ephemeral blob storage (cursor inversion). Heap-allocated
    /// so the scene can record stable `*const TextBlob` pointers across
    /// mid-frame growth; bulk-released after each frame.
    ephemeral_blobs: row_build.EphemeralBlobs,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,
    viewport_w: f32,
    viewport_h: f32,
    config: render_config.RenderConfig,

    draw_buffers_ready: bool = false,
    debug_log_renderers: bool = false,
    debug_log_frames: bool = false,
    debug_log_atlas: bool = false,
    debug_reset_atlas_each_frame: bool = false,

    pub var frame_stats: perf.FrameStats = .{};

    pub fn init(
        allocator: std.mem.Allocator,
        atlas_ref: *atlas_ref_mod.AtlasRef,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
    ) !Renderer {
        var gl_renderer = try snail.GlRenderer.init(allocator);
        errdefer gl_renderer.deinit();
        // mesa won't import dmabuf as sRGB-format, so the FBO is linear.
        // ResolveTarget.encoding is now per-draw (see drawOptions()) and
        // replaces the old renderer-global setSrgbFormatTarget +
        // DrawOptions.output_srgb pair.

        var atlas_lease = atlas_ref.acquire();
        errdefer atlas_lease.release();
        const atlas = atlas_lease.get();
        const builder = snail.TextBlobBuilder.init(allocator, atlas);
        var scene = snail.Scene.init(allocator);
        errdefer scene.deinit();

        const rect_renderer = gl_rect.GlRectRenderer.init();

        return .{
            .allocator = allocator,
            .atlas_ref = atlas_ref,
            .atlas_lease = atlas_lease,
            .gl_renderer = gl_renderer,
            .scene = scene,
            .builder = builder,
            .last_atlas_gen = atlas_ref.loadGeneration(),
            .last_atlas_identity = atlas.snapshotIdentity(),
            .rect_renderer = rect_renderer,
            .row_cache = row_build.RowCache.init(allocator, 32 * 1024 * 1024),
            .ephemeral_blobs = row_build.EphemeralBlobs.init(allocator),
            .cell_width = cell_width,
            .cell_height = cell_height,
            .font_size = font_size,
            .viewport_w = 0,
            .viewport_h = 0,
            .config = render_config.loadFromEnv(),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.row_cache.deinit();
        self.ephemeral_blobs.deinit();
        if (self.draw_buffers_ready) {
            self.allocator.free(self.scratch_rects);
            self.allocator.free(self.draw_rects);
        }
        self.draw_buf.deinit(self.allocator);
        self.seg_buf.deinit(self.allocator);
        if (self.prepared) |*p| p.deinit();
        self.builder.deinit();
        self.atlas_lease.release();
        self.scene.deinit();
        self.rect_renderer.deinit();
        self.gl_renderer.deinit();
    }

    fn ensureDrawBuffers(self: *Renderer) !void {
        if (self.draw_buffers_ready) return;
        self.draw_rects = try self.allocator.alloc(ColoredRect, MAX_DRAW_RECTS);
        errdefer self.allocator.free(self.draw_rects);
        self.scratch_rects = try self.allocator.alloc(ColoredRect, MAX_RECTS_PER_ROW);
        self.draw_buffers_ready = true;
    }

    pub fn setDebugResetAtlas(self: *Renderer, enabled: bool) void {
        self.debug_reset_atlas_each_frame = enabled;
    }

    pub fn setDebugLogs(self: *Renderer, options: render_env.RendererDebug) void {
        self.debug_log_renderers = options.renderers;
        self.debug_log_frames = options.frames;
        self.debug_log_atlas = options.atlas;
    }

    /// Resize the drawable. Pure window-resize; cell metrics are unchanged
    /// so the row cache stays hot.
    pub fn setViewport(self: *Renderer, w: u32, h: u32) void {
        self.viewport_w = @floatFromInt(w);
        self.viewport_h = @floatFromInt(h);
    }

    /// Update font metrics. Each cached `TextBlob` bakes `placement.em` into
    /// its per-instance Transform2D, so any metrics change invalidates the
    /// entire row cache. No-op when metrics are unchanged.
    pub fn setMetrics(self: *Renderer, font_size: f32, cell_width: f32, cell_height: f32) void {
        if (self.font_size == font_size and self.cell_width == cell_width and self.cell_height == cell_height) return;
        self.font_size = font_size;
        self.cell_width = cell_width;
        self.cell_height = cell_height;
        self.row_cache.clear();
    }

    /// Color for both gl_rect and snail text input. snail expects sRGB
    /// per its color convention; gl_rect writes it as-is to a linear-
    /// format FBO (no GL_FRAMEBUFFER_SRGB conversion). Both paths land
    /// sRGB bytes in the dmabuf, which is what the compositor wants.
    fn color4(self: *const Renderer, rgb: Rgb, alpha: f32) [4]f32 {
        _ = self;
        return rgb.toFloat4(alpha);
    }

    /// Refresh atlas snapshot. On identity change, rebind cached blobs and
    /// invalidate the prepared resources cache.
    fn refreshAtlas(self: *Renderer) *const snail.TextAtlas {
        var next_lease = self.atlas_ref.acquire();
        const atlas = next_lease.get();
        const identity = atlas.snapshotIdentity();
        if (identity == self.last_atlas_identity) {
            next_lease.release();
            return self.atlas_lease.get();
        }

        self.last_atlas_gen = self.atlas_ref.loadGeneration();
        self.last_atlas_identity = identity;

        if (self.prepared) |*p| {
            p.deinit();
            self.prepared = null;
            self.prepared_atlas_identity = 0;
        }

        // Builder is anchored to the prior snapshot; rebuild it.
        self.builder.deinit();
        self.builder = snail.TextBlobBuilder.init(self.allocator, atlas);

        const stats = self.row_cache.rebindAll(atlas, identity);
        if (self.debug_log_atlas) {
            std.debug.print("scrgo[gpu-renderer]: atlas snapshot {} (rebound={}, evicted={})\n", .{ identity, stats.rebound, stats.evicted });
        }
        self.atlas_lease.release();
        self.atlas_lease = next_lease;
        return atlas;
    }

    fn rowMetrics(self: *const Renderer) row_build.Metrics {
        return .{
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .font_size = self.font_size,
        };
    }

    fn pushRect(self: *Renderer, idx: *usize, x: f32, y: f32, w: f32, h: f32, cc: [4]f32) void {
        if (idx.* >= self.draw_rects.len) return;
        self.draw_rects[idx.*] = .{ .x = x, .y = y, .w = w, .h = h, .color = cc };
        idx.* += 1;
    }

    fn emitCursorRect(self: *Renderer, rect_index: *usize, cursor: row_build.CursorOverlay) void {
        const cx = @as(f32, @floatFromInt(cursor.cell_x)) * self.cell_width;
        const cy = @as(f32, @floatFromInt(cursor.cell_y)) * self.cell_height;
        const cc = self.color4(cursor.color, 1.0);
        switch (cursor.style) {
            .block => self.pushRect(rect_index, cx, cy, self.cell_width, self.cell_height, cc),
            .bar => self.pushRect(rect_index, cx, cy, 2, self.cell_height, cc),
            .underline => self.pushRect(rect_index, cx, cy + self.cell_height - 2, self.cell_width, 2, cc),
            .block_hollow => {
                self.pushRect(rect_index, cx, cy, self.cell_width, 1.5, cc);
                self.pushRect(rect_index, cx, cy + self.cell_height - 1.5, self.cell_width, 1.5, cc);
                self.pushRect(rect_index, cx, cy, 1.5, self.cell_height, cc);
                self.pushRect(rect_index, cx + self.cell_width - 1.5, cy, 1.5, self.cell_height, cc);
            },
        }
    }

    fn drawOptions(self: *const Renderer) snail.DrawOptions {
        const mvp = snail.Mat4.ortho(0, self.viewport_w, self.viewport_h, 0, -1, 1);
        return .{
            .mvp = mvp,
            .target = .{
                .pixel_width = self.viewport_w,
                .pixel_height = self.viewport_h,
                .subpixel_order = render_config.effectiveSubpixelOrder(self.config),
                // FBO storage is linear; consumer (compositor) expects
                // sRGB bytes. snail's shader gamma-encodes before write.
                .encoding = .srgb_pixels_on_linear_framebuffer,
            },
        };
    }

    fn refreshPrepared(self: *Renderer) !*const snail.PreparedResources {
        if (self.prepared) |*p| {
            if (self.prepared_atlas_identity == self.last_atlas_identity) return p;
            p.deinit();
            self.prepared = null;
        }
        var rs = snail.ResourceSet.init(self.resource_entries[0..]);
        try rs.addScene(&self.scene);
        const allocators: snail.UploadAllocators = .{
            .persistent = self.allocator,
            .scratch = self.allocator,
        };
        self.prepared = try self.gl_renderer.uploadResourcesBlocking(allocators, &rs);
        self.prepared_atlas_identity = self.last_atlas_identity;
        return &self.prepared.?;
    }

    fn flushDraw(self: *Renderer, rect_count: usize, default_bg: Rgb) !void {
        const opts = self.drawOptions();
        const bg4 = self.color4(default_bg, 1.0);
        gl.glClearColor(bg4[0], bg4[1], bg4[2], bg4[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        if (rect_count > 0)
            self.rect_renderer.drawRects(self.draw_rects[0..rect_count], opts.mvp);

        const prepared = try self.refreshPrepared();

        const buf_words = snail.DrawList.estimate(&self.scene, opts);
        const seg_count = snail.DrawList.estimateSegments(&self.scene, opts);
        try self.draw_buf.resize(self.allocator, buf_words);
        try self.seg_buf.resize(self.allocator, seg_count);
        var draw_list = snail.DrawList.init(self.draw_buf.items, self.seg_buf.items);
        try draw_list.addScene(prepared, &self.scene, opts);
        try self.gl_renderer.draw(prepared, draw_list.slice(), opts);

        gl.glFlush();
    }

    pub fn drawSnapshot(self: *Renderer, snapshot: *const render_snapshot.SharedSnapshot, misses: *glyph_misses.Set) !void {
        const frame_timer = perf.Timer.now();
        var atlas = self.refreshAtlas();
        try self.ensureDrawBuffers();
        self.scene.reset();

        var rows_buf: [MAX_SNAPSHOT_ROWS]row_build.RowDraw = undefined;
        var built = try row_build.buildSnapshot(
            snapshot,
            self.allocator,
            self.rowMetrics(),
            &self.row_cache,
            &self.builder,
            atlas,
            self.last_atlas_identity,
            self.scratch_rects,
            rows_buf[0..],
            &self.ephemeral_blobs,
            misses,
        );

        // Pass 1 had glyph misses; try a single sync atlas extension.
        // On success: refresh state and re-build. On miss/failure: ship
        // partial — the user sees gaps for the missing glyphs but the
        // rest of the frame paints normally.
        if (!misses.isEmpty()) {
            const result = self.atlas_ref.extend(atlas, misses.text()) catch |err| blk: {
                if (self.debug_log_atlas) std.debug.print("scrgo[gpu-renderer]: atlas extend failed: {}\n", .{err});
                break :blk .missing;
            };
            if (result == .extended) {
                self.scene.reset();
                self.ephemeral_blobs.releaseAll();
                misses.clear();
                atlas = self.refreshAtlas();
                built = try row_build.buildSnapshot(
                    snapshot,
                    self.allocator,
                    self.rowMetrics(),
                    &self.row_cache,
                    &self.builder,
                    atlas,
                    self.last_atlas_identity,
                    self.scratch_rects,
                    rows_buf[0..],
                    &self.ephemeral_blobs,
                    misses,
                );
            } else if (self.debug_log_atlas) {
                std.debug.print("scrgo[gpu-renderer]: atlas extend missing for {} bytes\n", .{misses.text().len});
            }
        }

        var override_index: usize = 0;
        var rect_index: usize = 0;

        // Pass B: bg + decoration rects per row.
        for (built.rows) |row_draw| {
            for (row_draw.row.rects) |r| {
                if (rect_index >= self.draw_rects.len) break;
                self.draw_rects[rect_index] = .{
                    .x = r.x,
                    .y = r.y + row_draw.row_y,
                    .w = r.w,
                    .h = r.h,
                    .color = r.color,
                };
                rect_index += 1;
            }
        }

        // Pass C: cursor rect (one or four for hollow).
        if (built.cursor) |cursor| self.emitCursorRect(&rect_index, cursor);

        // Pass D: text scene. Each row's blob is row-local; translate via
        // Override.transform at submit. Cursor inverted glyph (block style)
        // is appended on top.
        for (built.rows) |row_draw| {
            if (override_index >= self.overrides.len) break;
            self.overrides[override_index] = .{
                .transform = snail.Transform2D.translate(0, row_draw.row_y),
                .tint = .{ 1, 1, 1, 1 },
            };
            const slot = self.overrides[override_index .. override_index + 1];
            override_index += 1;
            try self.scene.addText(.{ .blob = row_draw.row.blob, .instances = slot });
        }
        if (built.cursor) |cursor| {
            if (cursor.inverted_glyph) |blob| try self.scene.addText(.{ .blob = blob });
        }

        // Draw whatever we have, even with misses. The misses set is still
        // forwarded to the atlas thread by the caller for an out-of-band
        // extension, but we never want to drop a frame entirely — better
        // for the user to see partial text than a stale/blank screen.
        try self.flushDraw(rect_index, snapshot.header.default_bg);
        self.ephemeral_blobs.releaseAll();
        frame_stats.record(frame_timer.elapsedUs());
    }
};
