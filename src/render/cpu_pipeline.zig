//! SHM rendering: snail-raster CPU rasterizer. Background fill, decoration
//! rects, cursor rects, and text all flow through the unified
//! shape/place/emit/raster pipeline.

const std = @import("std");
const snail = @import("snail");
const raster = @import("snail-raster");
const atlas_ref_mod = @import("atlas_ref.zig");
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
    selection_spans: [row_build.MAX_SELECTION_SPANS]row_build.SelectionSpan = undefined,
    eph: row_build.EphemeralBlobs,
    misses: glyph_misses.Set = .{},

    // snail-raster software renderer state.
    device_atlas: raster.DeviceAtlas,
    renderer: ?raster.Renderer = null,
    instances: std.ArrayList(Instance) = .empty,
    batches: std.ArrayList(DrawBatch) = .empty,
    /// Live binding from the last `device_atlas.upload`, released and
    /// re-issued each frame.
    cache_binding: ?Binding = null,

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
        };
    }

    pub fn deinit(self: *CpuPipeline) void {
        if (self.cache_binding) |b| self.device_atlas.release(b);
        self.device_atlas.deinit();
        self.eph.deinit();
        self.instances.deinit(self.allocator);
        self.batches.deinit(self.allocator);
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
        };
        const faces = self.atlas_ref.faces orelse return error.NoFaces;

        var cur_atlas = atlas;
        var extra_lease: ?atlas_ref_mod.AtlasRef.Lease = null;
        defer if (extra_lease) |*l| l.release();

        // Serialize shaping: the CPU and GPU workers share one HarfBuzz
        // buffer via `Faces`, so concurrent shapes corrupt it. Scoped to
        // just the shape — rasterization below and extend() (which locks
        // internally) run outside it.
        var built = blk: {
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
            );
        };

        var extend_attempts: u32 = 0;
        while (!self.misses.isEmpty() and extend_attempts < 4) : (extend_attempts += 1) {
            const result = self.atlas_ref.extend(cur_atlas, faces, self.misses.text()) catch break;
            if (result == .missing) break;
            if (extra_lease) |*l| l.release();
            extra_lease = self.atlas_ref.acquire();
            cur_atlas = extra_lease.?.get();
            self.eph.releaseAll();
            self.misses.clear();
            built = blk: {
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
                );
            };
        }

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
        try self.drawText(surface, cur_atlas, built.rows);

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
    }

    /// Emit every row's placed glyph shapes and rasterize them over the buffer.
    fn drawText(
        self: *CpuPipeline,
        surface: raster.TargetSurface,
        atlas: *const snail.Atlas,
        rows: []const row_build.RowDraw,
    ) !void {
        var total_shapes: usize = 0;
        for (rows) |row| total_shapes += row.shapes.len;
        if (total_shapes == 0) return;

        // Refresh the software atlas cache for the current atlas snapshot.
        // The prepared pages are cache-owned copies, so the binding stays
        // valid across the frame regardless of atlas republication.
        if (self.cache_binding) |b| {
            self.device_atlas.release(b);
            self.cache_binding = null;
        }
        var bindings: [1]Binding = undefined;
        try self.device_atlas.upload(self.allocator, &[_]*const snail.Atlas{atlas}, &bindings);
        self.cache_binding = bindings[0];
        const binding = bindings[0];

        // Generous upper bound: emit may expand a shape into several
        // per-layer instances (COLR / hinted).
        const cap = total_shapes * 8 + 64;
        try self.instances.resize(self.allocator, cap);
        try self.batches.resize(self.allocator, cap);

        var instance_len: usize = 0;
        var batch_len: usize = 0;
        for (rows) |row| {
            if (row.shapes.len == 0) continue;
            const xform = snail.Transform2D.translate(0, row.row_y);
            _ = snail.emit.emit(
                self.instances.items,
                self.batches.items,
                &instance_len,
                &batch_len,
                binding,
                atlas,
                row.shapes,
                xform,
                white_tint,
            ) catch |err| {
                log.warn(.cpu, "emit failed for row", .{ .err = err });
                continue;
            };
        }
        if (instance_len == 0) return;

        const wf: f32 = @floatFromInt(surface.pixel_width);
        const hf: f32 = @floatFromInt(surface.pixel_height);
        const draw_state: raster.DrawState = .{
            .surface = surface,
            .raster = .{},
            .mvp = snail.Mat4.ortho(0, wf, hf, 0, -1, 1),
        };

        raster.draw(
            &self.renderer.?,
            draw_state,
            .{ .instances = self.instances.items[0..instance_len], .batches = self.batches.items[0..batch_len] },
            &[_]*const raster.DeviceAtlas{&self.device_atlas},
            null,
        ) catch |err| {
            log.warn(.cpu, "raster draw failed", .{ .err = err });
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
