//! SHM rendering: snail's CPU rasterizer driven through the unified
//! Scene/ResourceManifest/PreparedResources/DrawList pipeline. Background
//! fill, decoration rects, cursor rects, and text all flow through snail —
//! no local blitter on the hot path.

const std = @import("std");
const snail = @import("snail");
const atlas_ref_mod = @import("atlas_ref.zig");
const glyph_misses = @import("glyph_misses.zig");
const render_snapshot = @import("render_snapshot.zig");
const render_config = @import("render_config.zig");
const render_common = @import("render_common.zig");
const row_build = @import("row_build.zig");
const color = @import("color.zig");
const perf = @import("perf.zig");
const Rgb = color.Rgb;

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

const wl = @cImport(@cInclude("wayland-client.h"));

const baseline_factor: f32 = row_build.baseline_factor;

// Stable resource keys; see renderer.zig for the same convention on the GPU
// side.
const ATLAS_KEY = snail.ResourceKey.named("scrgo.atlas");
const PICTURE_KEY = snail.ResourceKey.named("scrgo.rects");
const TEXT_KEYS: snail.TextResourceKeys = .{ .atlas = ATLAS_KEY };
const MANIFEST_CAP: usize = 2;

/// Pack RGBA bytes into a u32 matching `WL_SHM_FORMAT_ABGR8888` on a
/// little-endian host (byte order in memory: R, G, B, A). Used by the
/// splash blitter below; the per-frame CpuPipeline no longer touches
/// pixels directly.
inline fn abgrPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
}

/// Wayland SHM buffer + a minimal solid-color fill, used by the bootstrap
/// splash before EGL is ready (cf. main.zig). The terminal render path no
/// longer uses this — it goes through `CpuPipeline` below.
pub const ShmFrame = struct {
    map_ptr: ?*anyopaque,
    map_size: usize,
    fd: c_int,
    wl_pool: ?*wl.wl_shm_pool,
    wl_buffer: ?*wl.wl_buffer,
    width: u32,
    height: u32,
    stride: u32,

    pub fn create(shm_opaque: *anyopaque, w: u32, h: u32) ?ShmFrame {
        const shm: *wl.wl_shm = @ptrCast(shm_opaque);
        const stride = w * 4;
        const size: usize = @as(usize, stride) * h;

        const fd = c.memfd_create("scrgo-shm", @as(c_uint, 0));
        if (fd < 0) return null;

        if (c.ftruncate(fd, @intCast(size)) < 0) {
            _ = c.close(fd);
            return null;
        }

        const map = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (map == c.MAP_FAILED) {
            _ = c.close(fd);
            return null;
        }

        const pool = wl.wl_shm_create_pool(shm, fd, @intCast(size)) orelse {
            _ = c.munmap(map, size);
            _ = c.close(fd);
            return null;
        };

        const buffer = wl.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(w),
            @intCast(h),
            @intCast(stride),
            wl.WL_SHM_FORMAT_ABGR8888,
        ) orelse {
            wl.wl_shm_pool_destroy(pool);
            _ = c.munmap(map, size);
            _ = c.close(fd);
            return null;
        };

        return .{
            .map_ptr = map,
            .map_size = size,
            .fd = fd,
            .wl_pool = pool,
            .wl_buffer = buffer,
            .width = w,
            .height = h,
            .stride = stride,
        };
    }

    pub fn fillBackground(self: *ShmFrame, bg: Rgb) void {
        const map = self.map_ptr orelse return;
        const pixel = abgrPixel(bg.r, bg.g, bg.b, 255);
        const base: [*]u8 = @ptrCast(map);
        if (self.stride == self.width * 4) {
            const total: usize = @as(usize, self.width) * self.height;
            const pixels: [*]u32 = @ptrCast(@alignCast(base));
            @memset(pixels[0..total], pixel);
            return;
        }
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const row: [*]u32 = @ptrCast(@alignCast(base + @as(usize, y) * self.stride));
            @memset(row[0..self.width], pixel);
        }
    }

    pub fn destroy(self: *ShmFrame) void {
        if (self.wl_buffer) |b| wl.wl_buffer_destroy(b);
        if (self.wl_pool) |p| wl.wl_shm_pool_destroy(p);
        if (self.map_ptr) |m| _ = c.munmap(m, self.map_size);
        if (self.fd >= 0) _ = c.close(self.fd);
    }

    pub fn commit(self: *ShmFrame, surface_opaque: *anyopaque, display_opaque: *anyopaque) void {
        const surface: *wl.wl_surface = @ptrCast(surface_opaque);
        const display: *wl.wl_display = @ptrCast(display_opaque);
        wl.wl_surface_set_buffer_transform(surface, wl.WL_OUTPUT_TRANSFORM_NORMAL);
        wl.wl_surface_attach(surface, self.wl_buffer, 0, 0);
        wl.wl_surface_damage_buffer(surface, 0, 0, @intCast(self.width), @intCast(self.height));
        wl.wl_surface_commit(surface);
        _ = wl.wl_display_flush(display);
    }
};

/// Per-phase wall-time accumulators (ns) for the CPU render path. Written
/// by the CPU worker thread; main reads them at exit. Single-writer +
/// single-reader, race is benign for diagnostics.
pub var phase_row_build_ns: u64 = 0;
pub var phase_picture_ns: u64 = 0;
pub var phase_upload_ns: u64 = 0;
pub var phase_drawlist_ns: u64 = 0;
pub var phase_draw_ns: u64 = 0;
pub var phase_frame_count: u64 = 0;

/// Persistent CPU renderer + scene state. One instance per CPU worker thread.
pub const CpuPipeline = struct {
    allocator: std.mem.Allocator,

    cpu: snail.CpuRenderer,
    scene: snail.Scene,
    builder: snail.TextBlobBuilder,

    /// Cloned lease on the atlas snapshot the builder is currently
    /// bound to. Swapped in `ensureBuilderForAtlas` when the caller
    /// hands us a new identity. `null` until the first frame seeds it.
    /// No blob outlives the frame that built it, so we never need to
    /// retain more than one snapshot.
    atlas_lease: ?atlas_ref_mod.AtlasRef.Lease = null,
    builder_atlas_identity: u64 = 0,

    draw_buf: std.ArrayList(u32) = .empty,
    seg_buf: std.ArrayList(snail.DrawList.Segment) = .empty,
    overrides: [render_snapshot.MaxRows + 4]snail.Override = undefined,
    manifest_entries: [MANIFEST_CAP]snail.ResourceManifest.Entry = undefined,
    scratch_rects: []row_build.ColoredRect,
    config: render_config.RenderConfig,

    /// Per-frame ephemeral blobs (cursor inversion). Bulk-released after
    /// each frame.
    ephemeral_blobs: row_build.EphemeralBlobs,

    pub fn init(allocator: std.mem.Allocator) !CpuPipeline {
        const config = render_config.loadFromEnv();

        // Buffer is reinit'd per frame with the SHM map. Target encoding /
        // subpixel order / resolve strategy are all per-frame state on the
        // DrawPass — no renderer-global setters needed in 0.9.
        const cpu = snail.CpuRenderer.init(@ptrFromInt(@alignOf(u8)), 1, 1, 4);

        var scene = snail.Scene.init(allocator);
        errdefer scene.deinit();

        // Builder needs an atlas to bind to; defer real init to the first frame.
        const builder = snail.TextBlobBuilder.init(allocator, undefined);

        const scratch_rects = try allocator.alloc(row_build.ColoredRect, row_build.MAX_RECTS_PER_ROW);
        errdefer allocator.free(scratch_rects);

        return .{
            .allocator = allocator,
            .cpu = cpu,
            .scene = scene,
            .builder = builder,
            .scratch_rects = scratch_rects,
            .config = config,
            .ephemeral_blobs = row_build.EphemeralBlobs.init(allocator),
        };
    }

    pub fn deinit(self: *CpuPipeline) void {
        self.ephemeral_blobs.deinit();
        self.draw_buf.deinit(self.allocator);
        self.seg_buf.deinit(self.allocator);
        if (self.builder_atlas_identity != 0) self.builder.deinit();
        if (self.atlas_lease) |*lease| lease.release();
        self.scene.deinit();
        self.allocator.free(self.scratch_rects);
    }

    fn ensureBuilderForAtlas(self: *CpuPipeline, atlas_lease: *const atlas_ref_mod.AtlasRef.Lease) void {
        const atlas = atlas_lease.get();
        const id = atlas.snapshotIdentity();
        if (id == self.builder_atlas_identity) return;
        if (self.builder_atlas_identity != 0) self.builder.deinit();
        self.builder = snail.TextBlobBuilder.init(self.allocator, atlas);
        if (self.atlas_lease) |*prev| prev.release();
        self.atlas_lease = atlas_lease.clone();
        self.builder_atlas_identity = id;
    }

    fn currentAtlas(self: *CpuPipeline) *const snail.TextAtlas {
        const lease = if (self.atlas_lease) |*l| l else unreachable;
        return lease.get();
    }

    /// Emit cursor geometry into the per-frame path picture. Same edge-snap
    /// strategy as the GPU path: edges (not widths) round to integer pixels
    /// so adjacent cell rects tile without gaps under fractional cell_width.
    fn emitCursor(
        picture: *snail.PathPictureBuilder,
        cursor: row_build.CursorOverlay,
        cell_width: f32,
        cell_height: f32,
    ) !void {
        const x0_f = @as(f32, @floatFromInt(cursor.cell_x)) * cell_width;
        const y0_f = @as(f32, @floatFromInt(cursor.cell_y)) * cell_height;
        const x1_f = @as(f32, @floatFromInt(cursor.cell_x + 1)) * cell_width;
        const y1_f = @as(f32, @floatFromInt(cursor.cell_y + 1)) * cell_height;
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

    /// Paint the right-edge scrollbar overlay (gutter + thumb). Both
    /// renderers share the geometry helpers in render_common so the
    /// scrollbar looks identical regardless of which path is active.
    fn paintScrollbar(
        picture: *snail.PathPictureBuilder,
        sb: render_snapshot.ScrollbarOverlay,
        viewport_w: f32,
        viewport_h: f32,
        default_fg: Rgb,
    ) !void {
        if (sb.alpha <= 0) return;
        const geom = render_common.scrollbarGeometry(viewport_w, viewport_h, sb.thumb_offset, sb.thumb_size);
        const colors = render_common.scrollbarColors(default_fg, sb.alpha);
        try picture.addFilledRect(
            .{ .x = geom.gutter_x, .y = geom.gutter_y, .w = geom.gutter_w, .h = geom.gutter_h },
            .{ .paint = .{ .solid = colors.gutter } },
            .identity,
        );
        try picture.addFilledRect(
            .{ .x = geom.gutter_x, .y = geom.thumb_y, .w = geom.gutter_w, .h = geom.thumb_h },
            .{ .paint = .{ .solid = colors.thumb } },
            .identity,
        );
    }

    /// Render a snapshot to a Wayland SHM buffer. Returns any text runs
    /// whose glyphs weren't in the atlas — caller forwards to the atlas
    /// thread for extension.
    pub fn renderToMemory(
        self: *CpuPipeline,
        map_ptr: *anyopaque,
        width: u32,
        height: u32,
        stride: u32,
        snapshot: *const render_snapshot.SharedSnapshot,
        atlas_lease: *const atlas_ref_mod.AtlasRef.Lease,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
    ) !glyph_misses.Set {
        var misses: glyph_misses.Set = .{};
        const default_bg = snapshot.header.default_bg;

        // Reinitialize CPU renderer for this frame's buffer geometry.
        self.cpu.reinitBuffer(@ptrCast(map_ptr), width, height, stride);

        self.ensureBuilderForAtlas(atlas_lease);

        const metrics: row_build.Metrics = .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .font_size = font_size,
        };

        self.scene.reset();

        var rows_buf: [render_snapshot.MaxRows]row_build.RowDraw = undefined;
        var sel_buf: [row_build.MAX_SELECTION_SPANS]row_build.SelectionSpan = undefined;
        const row_build_t0 = perf.Timer.now();
        var built = try row_build.buildSnapshot(
            snapshot,
            self.allocator,
            metrics,
            &self.builder,
            self.currentAtlas(),
            atlas_lease.ref,
            self.scratch_rects,
            rows_buf[0..],
            sel_buf[0..],
            &self.ephemeral_blobs,
            &misses,
        );
        phase_row_build_ns += row_build_t0.elapsedNs();

        // Pass 1 had glyph misses; try a single sync atlas extension.
        // On success: republish, refresh local state, re-run the build
        // against the new atlas. On miss/failure: ship partial — buffer
        // shows gaps for the missing glyphs but the rest paints.
        if (!misses.isEmpty()) {
            const baseline_atlas = self.currentAtlas();
            const result = self.extendAtlas(atlas_lease, baseline_atlas, misses.text());
            if (result == .extended) {
                self.scene.reset();
                self.ephemeral_blobs.releaseAll();
                misses.clear();
                const rebuild_t0 = perf.Timer.now();
                built = try row_build.buildSnapshot(
                    snapshot,
                    self.allocator,
                    metrics,
                    &self.builder,
                    self.currentAtlas(),
                    atlas_lease.ref,
                    self.scratch_rects,
                    rows_buf[0..],
                    sel_buf[0..],
                    &self.ephemeral_blobs,
                    &misses,
                );
                phase_row_build_ns += rebuild_t0.elapsedNs();
            }
        }

        try self.flushDraw(built, default_bg, snapshot.header.default_fg, width, height, cell_width, cell_height);
        self.ephemeral_blobs.releaseAll();
        return misses;
    }

    fn extendAtlas(
        self: *CpuPipeline,
        atlas_lease: *const atlas_ref_mod.AtlasRef.Lease,
        baseline: *const snail.TextAtlas,
        miss_text: []const u8,
    ) atlas_ref_mod.AtlasRef.ExtendResult {
        const atlas_ref = atlas_lease.ref;
        const result = atlas_ref.extend(baseline, miss_text) catch return .missing;
        if (result != .extended) return result;
        var new_lease = atlas_ref.acquire();
        defer new_lease.release();
        self.ensureBuilderForAtlas(&new_lease);
        return .extended;
    }

    fn flushDraw(
        self: *CpuPipeline,
        built: row_build.BuiltSnapshot,
        default_bg: Rgb,
        default_fg: Rgb,
        viewport_w: u32,
        viewport_h: u32,
        cell_width: f32,
        cell_height: f32,
    ) !void {
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
        // Selection sits between cell backgrounds and the text run:
        // the highlight covers cell bg but the glyphs draw on top of
        // it. We use the default fg with a fixed alpha so the
        // selection is visible on any theme; the linear-resolve pass
        // blends it against whatever's beneath.
        const sel_color = render_common.selectionFillColor(default_bg);
        for (built.selection_spans) |span| {
            const x0 = @as(f32, @floatFromInt(span.start_col)) * cell_width;
            const y0 = @as(f32, @floatFromInt(span.row)) * cell_height;
            const w = @as(f32, @floatFromInt(span.end_col - span.start_col + 1)) * cell_width;
            try picture_builder.addFilledRect(
                .{ .x = x0, .y = y0, .w = w, .h = cell_height },
                .{ .paint = .{ .solid = sel_color } },
                .identity,
            );
        }
        if (built.cursor) |cursor| try emitCursor(&picture_builder, cursor, cell_width, cell_height);

        // Scrollbar overlay: thin band on the right edge, drawn after
        // text/cursor so it sits on top of everything. Snapshot carries
        // null when the scrollbar should be hidden.
        if (built.scrollbar) |sb| {
            try paintScrollbar(&picture_builder, sb, @floatFromInt(viewport_w), @floatFromInt(viewport_h), default_fg);
        }

        // Glyph-only frames leave the builder empty; `freeze` would
        // error with EmptyPicture. Skip the picture path entirely in
        // that case — `backdrop = .clear` below still seeds the buffer
        // to default_bg and the text scene paints on top.
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
            try manifest.putTextBlob(TEXT_KEYS, row_draw.blob);
            try self.scene.addText(.{
                .blob = row_draw.blob,
                .resources = TEXT_KEYS,
                .instances = slot,
            });
        }
        if (built.cursor) |cursor| {
            if (cursor.inverted_glyph) |blob| {
                try manifest.putTextBlob(TEXT_KEYS, blob);
                try self.scene.addText(.{ .blob = blob, .resources = TEXT_KEYS });
            }
        }

        const upload_t0 = perf.Timer.now();
        var prepared = try self.cpu.uploadResourcesBlocking(
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

        const pass: snail.DrawPass = .{
            .state = .{
                .mvp = snail.Mat4.ortho(0, @floatFromInt(viewport_w), @floatFromInt(viewport_h), 0, -1, 1),
                .surface = .{
                    .pixel_width = @floatFromInt(viewport_w),
                    .pixel_height = @floatFromInt(viewport_h),
                    .encoding = .srgb_pixels_on_linear_attachment,
                },
                .raster = .{ .subpixel_order = render_config.effectiveSubpixelOrder(self.config) },
            },
            .resolve = .{ .linear = .{
                // Snail owns the whole pixel now — seed with the default bg
                // and the rect picture + text run land on top.
                .backdrop = .{ .clear = default_bg.toFloat4(1.0) },
            } },
        };
        const draw_t0 = perf.Timer.now();
        try self.cpu.drawPass(&prepared, &draw_list, pass);
        phase_draw_ns += draw_t0.elapsedNs();
        phase_frame_count += 1;
    }
};
