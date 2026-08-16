//! SHM rendering: snail-raster CPU rasterizer. Background fill, decoration
//! rects, cursor rects, and text all flow through the unified
//! shape/place/emit/raster pipeline.

const std = @import("std");
const snail = @import("snail");
const raster = @import("snail-raster");
const atlas_ref_mod = @import("atlas_ref.zig");
const glyph_cache = @import("glyph_cache.zig");
const glyph_misses = @import("glyph_misses.zig");
const render_snapshot = @import("render_snapshot.zig");
const render_env = @import("render_env.zig");
const render_common = @import("render_common.zig");
const row_build = @import("row_build.zig");
const color = @import("color");
const perf = @import("../perf.zig");
const log = @import("../log.zig");
const Rgb = color.Rgb;

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

const wl = @cImport(@cInclude("wayland-client.h"));

/// Pack RGBA bytes into a u32 matching `WL_SHM_FORMAT_ABGR8888` on a
/// little-endian host (byte order in memory: R, G, B, A).
inline fn abgrPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
}

/// Wayland SHM buffer + a minimal solid-color fill, used by the bootstrap
/// splash before Vulkan is ready.
pub const ShmFrame = struct {
    map_ptr: ?*anyopaque,
    width: u32,
    height: u32,
    wl_pool: ?*wl.wl_shm_pool,
    wl_buffer: ?*wl.wl_buffer,
    shm_fd: c_int = -1,

    pub fn create(shm: *anyopaque, width: u32, height: u32) ShmFrame {
        const stride = width * 4;
        const size = stride * height;

        const fd = c.memfd_create("scrgo-shm", c.MFD_CLOEXEC);
        if (fd < 0) return .{
            .map_ptr = null,
            .width = width,
            .height = height,
            .wl_pool = null,
            .wl_buffer = null,
        };

        if (c.ftruncate(fd, @intCast(size)) < 0) {
            _ = std.c.close(fd);
            return .{
                .map_ptr = null,
                .width = width,
                .height = height,
                .wl_pool = null,
                .wl_buffer = null,
            };
        }

        const map = c.mmap(null, @intCast(size), c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (map == c.MAP_FAILED) {
            _ = std.c.close(fd);
            return .{
                .map_ptr = null,
                .width = width,
                .height = height,
                .wl_pool = null,
                .wl_buffer = null,
            };
        }

        const pool = wl.wl_shm_create_pool(@ptrCast(shm), fd, @intCast(size));
        const buffer = wl.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(stride), wl.WL_SHM_FORMAT_ABGR8888);

        return .{
            .map_ptr = map,
            .width = width,
            .height = height,
            .wl_pool = pool,
            .wl_buffer = buffer,
            .shm_fd = fd,
        };
    }

    pub fn fillBackground(self: *ShmFrame, bg: Rgb) void {
        if (self.map_ptr == null) return;
        const ptr: [*]align(4) u32 = @ptrCast(@alignCast(self.map_ptr.?));
        const pixel = abgrPixel(bg.r, bg.g, bg.b, 255);
        const count = self.width * self.height;
        @memset(ptr[0..count], pixel);
    }

    pub fn commit(self: *ShmFrame, surface: *anyopaque, display: *anyopaque) void {
        if (self.wl_buffer == null) return;
        wl.wl_surface_attach(@ptrCast(surface), self.wl_buffer, 0, 0);
        wl.wl_surface_damage_buffer(@ptrCast(surface), 0, 0, @intCast(self.width), @intCast(self.height));
        wl.wl_surface_commit(@ptrCast(surface));
        _ = wl.wl_display_flush(@ptrCast(display));
    }

    pub fn destroy(self: *ShmFrame) void {
        if (self.wl_buffer) |b| wl.wl_buffer_destroy(b);
        if (self.wl_pool) |p| wl.wl_shm_pool_destroy(p);
        if (self.map_ptr) |m| _ = c.munmap(m, @intCast(self.width * self.height * 4));
        if (self.shm_fd >= 0) _ = std.c.close(self.shm_fd);
        self.wl_buffer = null;
        self.wl_pool = null;
        self.map_ptr = null;
        self.shm_fd = -1;
    }
};

pub var phase_frame_count: u64 = 0;
pub var phase_row_build_ns: u64 = 0;
pub var phase_picture_ns: u64 = 0;
pub var phase_upload_ns: u64 = 0;
pub var phase_drawlist_ns: u64 = 0;
pub var phase_draw_ns: u64 = 0;

const Instance = snail.render.records.Instance;
const DrawBatch = snail.render.records.DrawBatch;
const Binding = snail.render.records.Binding;

const white_tint: [4]f32 = .{ 1, 1, 1, 1 };

pub const CpuPipeline = struct {
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
    /// Scratch for the graceful-skip path: a row's shapes filtered to those
    /// already prepped in the atlas, when emit's all-or-nothing call fails on a
    /// not-yet-prepped glyph. Only touched on a partial row. Mirrors GpuPipeline.
    filtered_shapes: [render_snapshot.MaxCols * 4]snail.Shape = undefined,
    selection_spans: [row_build.MAX_SELECTION_SPANS]row_build.SelectionSpan = undefined,
    row_scratch: row_build.RowScratch = .{},
    eph: row_build.EphemeralBlobs,
    misses: glyph_misses.Set = .{},

    // snail-raster software renderer state.
    device_atlas: raster.DeviceAtlas,
    renderer: ?raster.Renderer = null,
    /// Fans the software raster's tile work across cores (snail-raster's
    /// ThreadPool). Owned; spawned once at init. `pool_ready` is false if the
    /// spawn failed, in which case draw() runs single-threaded.
    thread_pool: raster.ThreadPool = undefined,
    pool_ready: bool = false,
    instances: std.ArrayList(Instance) = .empty,
    batches: std.ArrayList(DrawBatch) = .empty,
    /// Live binding from the last `device_atlas.upload`. Reused across frames
    /// while the atlas snapshot is unchanged — re-uploading flattens the whole
    /// (growing) atlas, which is pure waste when nothing new was prepped.
    cache_binding: ?Binding = null,
    /// `snapshot_id` the `cache_binding` was built from; 0 = none uploaded.
    cache_snapshot_id: u64 = 0,

    // ── Glyph coverage cache (glyph_cache.zig) ──
    // Memoizes each glyph's rasterized coverage so steady frames blit tiles
    // instead of re-evaluating cubic-lowered quads per pixel.
    coverage: glyph_cache.Cache,
    cache_enabled: bool = true,
    /// Scratch surface for rasterizing one glyph into a coverage tile, sized in
    /// `configure` to ~3× the cell (room for bearings / ascenders / descenders).
    tile_buf: []u8 = &.{},
    tile_cov: []u8 = &.{},
    tile_renderer: ?raster.Renderer = null,
    tile_w: u32 = 0,
    tile_h: u32 = 0,
    tile_pen_x: f32 = 0,
    tile_pen_y: f32 = 0,
    tile_instances: [64]Instance = undefined,
    tile_batches: [16]DrawBatch = undefined,
    /// Colour / oversized glyphs deferred to one analytic-raster pass per frame
    /// (the coverage cache handles only monochrome glyphs).
    fallback_shapes: [render_snapshot.MaxCols * 4]snail.Shape = undefined,

    /// Initialize in place. `self` must point at allocated (uninitialized)
    /// storage — CpuPipeline embeds several-MB scratch arrays, so returning
    /// it by value would blow the caller's stack.
    pub fn init(self: *CpuPipeline, allocator: std.mem.Allocator, atlas_ref: *atlas_ref_mod.AtlasRef) !void {
        const device_atlas = try raster.DeviceAtlas.init(allocator, atlas_ref.pool, .{});
        self.* = .{
            .allocator = allocator,
            .atlas_ref = atlas_ref,
            .eph = row_build.EphemeralBlobs.init(allocator),
            .device_atlas = device_atlas,
            // 64 MiB cap: a screenful of distinct glyphs is far less; the cap is
            // a backstop against pathological churn, resetting the whole cache.
            .coverage = glyph_cache.Cache.init(allocator, 64 << 20),
        };
        self.misses.lifo = std.c.getenv("SCRGO_MISS_LIFO") != null;
        // On by default; SCRGO_CPU_GLYPH_CACHE=0 forces the analytic path.
        self.cache_enabled = if (std.c.getenv("SCRGO_CPU_GLYPH_CACHE")) |v|
            !std.mem.eql(u8, std.mem.sliceTo(v, 0), "0")
        else
            true;
        // Fan the full-screen software raster across a couple of cores. The
        // software path is only the pre-GPU fallback, and it competes with the
        // prep workers during a flood, so a small pool wins; override with
        // SCRGO_RASTER_THREADS for tuning. Clamped to the core count.
        // Best-effort: on failure we raster single-threaded.
        const cpu_count = std.Thread.getCpuCount() catch 4;
        var pool_threads: usize = @min(cpu_count, 2);
        if (std.c.getenv("SCRGO_RASTER_THREADS")) |env| {
            if (std.fmt.parseInt(usize, std.mem.sliceTo(env, 0), 10) catch null) |v| {
                if (v > 0) pool_threads = @min(cpu_count, v);
            }
        }
        log.info(.cpu, "raster thread pool", .{ .threads = pool_threads, .cores = cpu_count });
        if (self.thread_pool.init(allocator, .{ .threads = @intCast(pool_threads) })) |_| {
            self.pool_ready = true;
        } else |err| {
            log.warn(.cpu, "raster thread pool init failed; single-threaded", .{ .err = err });
        }
    }

    pub fn deinit(self: *CpuPipeline) void {
        if (self.pool_ready) self.thread_pool.deinit();
        if (self.cache_binding) |b| self.device_atlas.release(b);
        self.device_atlas.deinit();
        self.eph.deinit();
        self.instances.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.coverage.deinit();
        if (self.tile_buf.len > 0) self.allocator.free(self.tile_buf);
        if (self.tile_cov.len > 0) self.allocator.free(self.tile_cov);
    }

    pub fn configure(
        self: *CpuPipeline,
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

        // (Re)size the coverage-tile scratch to this cell. Generous margins hold
        // bearings, ascenders and descenders; a glyph whose ink still exceeds it
        // falls back to the analytic raster. On alloc failure the scratch stays
        // empty and the whole path falls back — never fatal.
        // Wide enough for a double-width (2-cell) CJK glyph plus bearings, but
        // only ~2× tall (glyphs span one cell vertically, plus ascender /
        // descender margin). A glyph whose ink still exceeds it (border touch)
        // falls back to the analytic raster.
        const tw: u32 = @intFromFloat(@ceil(cell_width * 3));
        const th: u32 = @intFromFloat(@ceil(cell_height * 2));
        if (tw != self.tile_w or th != self.tile_h or self.tile_buf.len == 0) {
            if (self.tile_buf.len > 0) self.allocator.free(self.tile_buf);
            if (self.tile_cov.len > 0) self.allocator.free(self.tile_cov);
            self.tile_renderer = null;
            self.coverage.reset();
            self.tile_buf = self.allocator.alloc(u8, tw * th * 4) catch &.{};
            self.tile_cov = self.allocator.alloc(u8, tw * th) catch &.{};
            self.tile_w = tw;
            self.tile_h = th;
        }
        self.tile_pen_x = @round(cell_width);
        self.tile_pen_y = @round(cell_height * 1.4);
    }

    /// Render the snapshot to the SHM buffer pixels (ABGR8888 memory order).
    /// Every fill goes through snail-raster's `fillRect`/`clearRect`, which
    /// blend in linear light and encode sRGB on store — the exact math the
    /// GPU's sRGB attachment does in hardware, so the two paths are pixel-exact.
    pub fn renderToMemory(
        self: *CpuPipeline,
        pixels: [*]u8,
        width: u32,
        height: u32,
        stride: u32,
        snapshot: *const render_snapshot.SharedSnapshot,
        atlas: *const snail.Atlas,
    ) !void {
        self.eph.releaseAll();
        self.misses.clear();
        self.instances.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();

        const buf: []u8 = pixels[0 .. @as(usize, stride) * height];
        const default_bg = snapshot.header.default_bg;
        const default_fg = snapshot.header.default_fg;

        const surface: raster.TargetSurface = .{
            .pixel_width = width,
            .pixel_height = height,
            .encoding = .srgb,
            .format = .rgba8_unorm,
        };

        // Point the software renderer at this frame's SHM buffer.
        if (self.renderer) |*r| {
            try r.reinitBuffer(buf, width, height, stride, .rgba8_unorm);
        } else {
            self.renderer = try raster.Renderer.init(buf, width, height, stride, .rgba8_unorm);
        }
        const r = &self.renderer.?;

        // ── 1. Background clear (sRGB, no blend) ──
        r.clearRect(surface, .full(width, height), default_bg.toFloat4(1.0)) catch {};

        // ── 2. Build the frame; grow the atlas on glyph misses ──
        // The atlas starts empty: when the build reports misses, extend the
        // shared atlas (publishing a new snapshot) and rebuild against it.
        const metrics: row_build.Metrics = .{
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .font_size = self.font_size,
            .baseline_offset = self.baseline_offset,
            .viewport_w = self.viewport_w,
            .viewport_h = self.viewport_h,
        };
        const faces = self.atlas_ref.faces orelse return error.NoFaces;
        const cur_atlas = atlas;

        // Serialize shaping: the CPU and GPU workers share one HarfBuzz
        // buffer via `Faces`, so concurrent shapes corrupt it. Scoped to
        // just the shape.
        self.atlas_ref.setBitmapPpem(@intFromFloat(@round(metrics.font_size)));
        const built = blk: {
            self.atlas_ref.lockShaping();
            defer self.atlas_ref.unlockShaping();
            break :blk try row_build.buildSnapshot(
                snapshot,
                self.allocator,
                metrics,
                cur_atlas,
                self.atlas_ref,
                faces,
                &self.scratch_rects,
                &self.scratch_box_rects,
                &self.rows_out,
                &self.selection_spans,
                &self.eph,
                &self.misses,
                &self.row_scratch,
            );
        };

        // Hand misses to the async prep thread; don't block the frame. The
        // glyphs appear on a later frame once prep publishes an extended atlas.
        if (!self.misses.isEmpty()) self.atlas_ref.requestPrep(self.misses.text());

        // ── 3. Background spans + decoration rects (linear, row-local +row_y) ──
        for (built.rows) |row| {
            for (row.rects) |rect| {
                fillRect(r, surface, rect.x, rect.y + row.row_y, rect.w, rect.h, rect.color);
            }
        }

        // ── 4. Selection highlight (translucent, behind text) ──
        if (built.selection_spans.len > 0) {
            const sel = render_common.selectionFillColor(default_bg);
            for (built.selection_spans) |span| {
                const x = @as(f32, @floatFromInt(span.start_col)) * self.cell_width;
                const w = @as(f32, @floatFromInt(span.end_col - span.start_col + 1)) * self.cell_width;
                const y = @as(f32, @floatFromInt(span.row)) * self.cell_height;
                fillRect(r, surface, x, y, w, self.cell_height, sel);
            }
        }

        // ── 4.5. Box-drawing / block glyphs (over bg, under text) ──
        for (built.rows) |row| {
            for (row.box_rects) |rect| {
                fillRect(r, surface, rect.x, rect.y + row.row_y, rect.w, rect.h, rect.color);
            }
        }

        // ── 5. Text ──
        try self.drawText(surface, buf, width, height, stride, cur_atlas, built.rows);

        // ── 6. Cursor ──
        if (built.cursor) |cursor| self.drawCursor(r, surface, cursor);

        // ── 7. Scrollbar ──
        if (built.scrollbar) |sb| {
            if (sb.alpha > 0) {
                const geo = render_common.scrollbarGeometry(
                    @floatFromInt(width),
                    @floatFromInt(height),
                    sb.thumb_offset,
                    sb.thumb_size,
                );
                const colors = render_common.scrollbarColors(default_fg, sb.alpha);
                fillRect(r, surface, geo.gutter_x, geo.gutter_y, geo.gutter_w, geo.gutter_h, colors.gutter);
                fillRect(r, surface, geo.gutter_x, geo.thumb_y, geo.gutter_w, geo.thumb_h, colors.thumb);
            }
        }

        // ── 8. Visual bell — full-viewport tint ──
        if (built.bell) |bell| {
            if (bell.alpha > 0) {
                const fg = default_fg.toLinearFloat4(1.0);
                fillRect(r, surface, 0, 0, @floatFromInt(width), @floatFromInt(height), .{ fg[0], fg[1], fg[2], 0.15 * bell.alpha });
            }
        }

        // ── 9. Command palette (backdrop + panel + text) ──
        if (built.palette) |pal| {
            for (pal.rects) |rect| fillRect(r, surface, rect.x, rect.y, rect.w, rect.h, rect.color);
            if (pal.shapes.len > 0) {
                // Reuse the text path: wrap the absolutely-positioned shapes as
                // one synthetic row (row_y = 0).
                const prows = [_]row_build.RowDraw{.{ .shapes = pal.shapes, .rects = &.{}, .box_rects = &.{}, .row_y = 0 }};
                try self.drawText(surface, buf, width, height, stride, cur_atlas, &prows);
            }
        }
    }

    /// Flatten the whole `atlas` into a fresh cache binding. Used only on the
    /// first frame or when a delta is impossible; steady state and floods go
    /// through `uploadDelta`.
    fn fullAtlasUpload(self: *CpuPipeline, atlas: *const snail.Atlas, snap_id: u64) !void {
        var bindings: [1]Binding = undefined;
        try self.device_atlas.upload(self.allocator, &[_]*const snail.Atlas{atlas}, &bindings);
        self.cache_binding = bindings[0];
        self.cache_snapshot_id = snap_id;
    }

    /// Keep the software device-atlas binding current for `atlas`: reuse it when
    /// the snapshot is unchanged, `uploadDelta` only the new pages when it
    /// advanced (a flood appends children), or flatten the whole atlas on first
    /// use / an incompatible snapshot.
    fn ensureBinding(self: *CpuPipeline, atlas: *const snail.Atlas) !Binding {
        const snap_id = atlas.snapshotIdentity().snapshot_id;
        if (self.cache_binding) |prev| {
            if (self.cache_snapshot_id != snap_id) {
                if (self.device_atlas.uploadDelta(self.allocator, prev, atlas)) |updated| {
                    self.cache_binding = updated;
                    self.cache_snapshot_id = snap_id;
                } else |_| {
                    self.device_atlas.release(prev);
                    self.cache_binding = null;
                    try self.fullAtlasUpload(atlas, snap_id);
                }
            }
        } else {
            try self.fullAtlasUpload(atlas, snap_id);
        }
        return self.cache_binding.?;
    }

    const Emitted = struct { instances: usize = 0, batches: usize = 0 };

    /// Emit `rows`' glyph shapes (each translated by its `row_y`) into the
    /// instance/batch buffers. emit is all-or-nothing per call, so a row with a
    /// not-yet-prepped glyph is re-emitted filtered to the prepped subset (the
    /// rest fill in on a later frame). Returns the staged lengths.
    fn emitRows(self: *CpuPipeline, atlas: *const snail.Atlas, binding: Binding, rows: []const row_build.RowDraw) !Emitted {
        var total: usize = 0;
        for (rows) |row| total += row.shapes.len;
        const cap = total * 8 + 64; // COLR / hinted shapes expand to several instances
        try self.instances.resize(self.allocator, cap);
        try self.batches.resize(self.allocator, cap);

        var e: Emitted = .{};
        var partial_rows: u32 = 0;
        for (rows) |row| {
            if (row.shapes.len == 0) continue;
            const xform = snail.Transform2D.translate(0, row.row_y);
            _ = snail.emit.emit(self.instances.items, self.batches.items, &e.instances, &e.batches, binding, atlas, row.shapes, xform, white_tint) catch {
                // The failed call staged into the buffer tails but committed
                // nothing, so the cursors are untouched — re-emit the prepped
                // subset. The rest render as gaps until prep publishes.
                partial_rows += 1;
                var n: usize = 0;
                for (row.shapes) |s| {
                    if (atlas.contains(s.key)) {
                        self.filtered_shapes[n] = s;
                        n += 1;
                    }
                }
                if (n > 0) _ = snail.emit.emit(self.instances.items, self.batches.items, &e.instances, &e.batches, binding, atlas, self.filtered_shapes[0..n], xform, white_tint) catch {};
            };
        }
        if (partial_rows > 0) log.warn(.cpu, "rows partially drawn (glyphs not yet prepped)", .{ .rows = partial_rows, .total_rows = rows.len });
        return e;
    }

    /// Rasterize the currently-staged instances over the main surface.
    fn rasterInstances(self: *CpuPipeline, surface: raster.TargetSurface, e: Emitted) void {
        if (e.instances == 0) return;
        const wf: f32 = @floatFromInt(surface.pixel_width);
        const hf: f32 = @floatFromInt(surface.pixel_height);
        const draw_state: raster.DrawState = .{ .surface = surface, .raster = .{}, .mvp = snail.Mat4.ortho(0, wf, hf, 0, -1, 1) };
        raster.draw(
            &self.renderer.?,
            draw_state,
            .{ .instances = self.instances.items[0..e.instances], .batches = self.batches.items[0..e.batches] },
            &[_]*const raster.DeviceAtlas{&self.device_atlas},
            if (self.pool_ready) &self.thread_pool else null,
        ) catch |err| log.warn(.cpu, "raster draw failed", .{ .err = err });
    }

    /// Draw all text. With the coverage cache on, blit each monochrome glyph
    /// from its cached tile and defer colour / oversized glyphs to a single
    /// analytic pass; with it off, everything goes through the analytic path.
    fn drawText(
        self: *CpuPipeline,
        surface: raster.TargetSurface,
        buf: []u8,
        width: u32,
        height: u32,
        stride: u32,
        atlas: *const snail.Atlas,
        rows: []const row_build.RowDraw,
    ) !void {
        var total: usize = 0;
        for (rows) |row| total += row.shapes.len;
        if (total == 0) return;
        const binding = try self.ensureBinding(atlas);

        if (!self.cache_enabled or self.tile_buf.len == 0) {
            self.rasterInstances(surface, try self.emitRows(atlas, binding, rows));
            return;
        }

        // Un-prepped glyphs are skipped (they render as gaps until prep
        // publishes, exactly like the analytic path's filtered re-emit).
        var fb_len: usize = 0;
        var n_blit: u32 = 0;
        var n_miss: u32 = 0;
        for (rows) |row| {
            for (row.shapes) |shape| {
                if (!atlas.contains(shape.key)) continue;
                const qx = glyph_cache.quantize(shape.local_transform.tx);
                const qy = glyph_cache.quantize(shape.local_transform.ty + row.row_y);
                const key: glyph_cache.Key = .{
                    .record = .{ shape.key.namespace, shape.key.a, shape.key.b, shape.key.c },
                    .sub_x = qx.sub,
                    .sub_y = qy.sub,
                };
                const tile = self.coverage.get(key) orelse blk: {
                    n_miss += 1;
                    const t = self.rasterCoverageTile(atlas, binding, shape, key);
                    self.coverage.put(key, t);
                    break :blk t;
                };
                if (tile.fallback) {
                    if (fb_len < self.fallback_shapes.len) {
                        var s = shape;
                        s.local_transform.ty += row.row_y; // bake row_y → one identity-xform emit
                        self.fallback_shapes[fb_len] = s;
                        fb_len += 1;
                    }
                    continue;
                }
                glyph_cache.blit(buf, width, height, stride, tile, qx.int, qy.int, shape.local_color);
                n_blit += 1;
            }
        }
        if (fb_len > 0) {
            const one_row = [_]row_build.RowDraw{.{ .shapes = self.fallback_shapes[0..fb_len], .rects = &.{}, .box_rects = &.{}, .row_y = 0 }};
            self.rasterInstances(surface, try self.emitRows(atlas, binding, &one_row));
        }
        log.debug(.cpu, "glyph cache", .{ .blit = n_blit, .miss = n_miss, .fallback = fb_len });
    }

    /// Rasterize one glyph white into the tile scratch (linear encoding), then
    /// extract its coverage. Returns `fallback` for colour glyphs (COLR ignores
    /// the white tint → non-grayscale output) or ink larger than the scratch.
    /// The glyph is drawn at the key's sub-pixel bucket so the tile matches the
    /// on-screen sub-pixel position (cell origins are integer-snapped, so this
    /// is bucket 0 for the common case and bit-exact with the analytic raster).
    fn rasterCoverageTile(self: *CpuPipeline, atlas: *const snail.Atlas, binding: Binding, shape: snail.Shape, key: glyph_cache.Key) glyph_cache.Tile {
        const tw = self.tile_w;
        const th = self.tile_h;
        const sub = @as(f32, @floatFromInt(glyph_cache.SUBPIXEL));
        const px = self.tile_pen_x + @as(f32, @floatFromInt(key.sub_x)) / sub;
        const py = self.tile_pen_y + @as(f32, @floatFromInt(key.sub_y)) / sub;
        const st = tw * 4;
        @memset(self.tile_buf, 0);
        if (self.tile_renderer) |*tr| {
            tr.reinitBuffer(self.tile_buf, tw, th, st, .rgba8_unorm) catch return .{ .fallback = true };
        } else {
            self.tile_renderer = raster.Renderer.init(self.tile_buf, tw, th, st, .rgba8_unorm) catch return .{ .fallback = true };
        }

        var one = shape;
        one.local_color = white_tint; // coverage, not colour
        const xform = snail.Transform2D.translate(px - shape.local_transform.tx, py - shape.local_transform.ty);
        var il: usize = 0;
        var bl: usize = 0;
        _ = snail.emit.emit(self.tile_instances[0..], self.tile_batches[0..], &il, &bl, binding, atlas, &[_]snail.Shape{one}, xform, white_tint) catch return .{ .fallback = true };
        if (il == 0) return .{}; // no ink (e.g. a space): a cached no-op

        const twf: f32 = @floatFromInt(tw);
        const thf: f32 = @floatFromInt(th);
        const ds: raster.DrawState = .{
            .surface = .{ .pixel_width = tw, .pixel_height = th, .encoding = .linear, .format = .rgba8_unorm },
            .raster = .{},
            .mvp = snail.Mat4.ortho(0, twf, thf, 0, -1, 1),
        };
        raster.draw(&self.tile_renderer.?, ds, .{ .instances = self.tile_instances[0..il], .batches = self.tile_batches[0..bl] }, &[_]*const raster.DeviceAtlas{&self.device_atlas}, null) catch return .{ .fallback = true };

        return self.extractCoverage(px, py);
    }

    /// Scan the tile scratch (linear white-on-transparent) for the glyph's ink
    /// bbox, verify it's monochrome, and copy the coverage (R channel = linear
    /// coverage) into `tile_cov`, positioned relative to the integer pen.
    fn extractCoverage(self: *CpuPipeline, px: f32, py: f32) glyph_cache.Tile {
        const tw = self.tile_w;
        const th = self.tile_h;
        const st = tw * 4;
        var minx: u32 = tw;
        var miny: u32 = th;
        var maxx: u32 = 0;
        var maxy: u32 = 0;
        var is_color = false;
        var y: u32 = 0;
        while (y < th) : (y += 1) {
            var x: u32 = 0;
            while (x < tw) : (x += 1) {
                const o = y * st + x * 4;
                const rr = self.tile_buf[o];
                const gg = self.tile_buf[o + 1];
                const bb = self.tile_buf[o + 2];
                if (rr == 0 and gg == 0 and bb == 0 and self.tile_buf[o + 3] == 0) continue;
                if (rr != gg or gg != bb) is_color = true;
                if (x < minx) minx = x;
                if (x > maxx) maxx = x;
                if (y < miny) miny = y;
                if (y > maxy) maxy = y;
            }
        }
        if (maxx < minx) return .{}; // no ink
        if (is_color) return .{ .fallback = true };
        // Ink touching a border means the scratch clipped the glyph.
        if (minx == 0 or miny == 0 or maxx == tw - 1 or maxy == th - 1) return .{ .fallback = true };

        const w: u16 = @intCast(maxx - minx + 1);
        const h: u16 = @intCast(maxy - miny + 1);
        var i: usize = 0;
        var ry: u32 = miny;
        while (ry <= maxy) : (ry += 1) {
            var rx: u32 = minx;
            while (rx <= maxx) : (rx += 1) {
                self.tile_cov[i] = self.tile_buf[ry * st + rx * 4]; // R = linear coverage
                i += 1;
            }
        }
        return .{
            .w = w,
            .h = h,
            .left = @intCast(@as(i32, @intCast(minx)) - @as(i32, @intFromFloat(@floor(px)))),
            .top = @intCast(@as(i32, @intCast(miny)) - @as(i32, @intFromFloat(@floor(py)))),
            .cov = self.tile_cov[0 .. @as(usize, w) * h],
        };
    }

    fn drawCursor(
        self: *CpuPipeline,
        r: *raster.Renderer,
        surface: raster.TargetSurface,
        cursor: row_build.CursorOverlay,
    ) void {
        const x = @as(f32, @floatFromInt(cursor.cell_x)) * self.cell_width;
        const y = @as(f32, @floatFromInt(cursor.cell_y)) * self.cell_height;
        const cw = self.cell_width;
        const ch = self.cell_height;
        switch (cursor.style) {
            .block => fillRect(r, surface, x, y, cw, ch, cursor.color.toLinearFloat4(0.7)),
            .bar => {
                const ext = render_common.barCursorExtent(y, ch, self.baseline_offset, self.descent);
                fillRect(r, surface, x, ext.y, 2, ext.h, cursor.color.toLinearFloat4(1.0));
            },
            .underline => {
                const ext = render_common.underlineCursorExtent(y, ch, self.baseline_offset, self.descent);
                fillRect(r, surface, x, ext.y, cw, ext.h, cursor.color.toLinearFloat4(1.0));
            },
            .block_hollow => {
                const c1 = cursor.color.toLinearFloat4(1.0);
                fillRect(r, surface, x, y, cw, 1, c1);
                fillRect(r, surface, x, y + ch - 1, cw, 1, c1);
                fillRect(r, surface, x, y, 1, ch, c1);
                fillRect(r, surface, x + cw - 1, y, 1, ch, c1);
            },
        }
    }
};

/// Convert a float pixel rectangle to an integer `PixelRect` (floor origin,
/// ceil extent so nothing is dropped) and source-over it in linear light via
/// snail-raster. `color` is linear straight-alpha.
fn fillRect(r: *raster.Renderer, surface: raster.TargetSurface, fx: f32, fy: f32, fw: f32, fh: f32, col: [4]f32) void {
    if (fw <= 0 or fh <= 0 or col[3] <= 0) return;
    const x0: i32 = @intFromFloat(@floor(fx));
    const y0: i32 = @intFromFloat(@floor(fy));
    const x1: i32 = @intFromFloat(@ceil(fx + fw));
    const y1: i32 = @intFromFloat(@ceil(fy + fh));
    const rect: raster.PixelRect = .{
        .x = x0,
        .y = y0,
        .w = @intCast(@max(0, x1 - x0)),
        .h = @intCast(@max(0, y1 - y0)),
    };
    r.fillRect(surface, rect, col) catch {};
}
