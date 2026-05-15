//! SHM rendering: project-owned solid-color blitter for backgrounds and
//! decorations, plus snail's CPU rasterizer (driven through the unified
//! Scene/ResourceSet/PreparedResources/DrawList pipeline) for text.

const std = @import("std");
const snail = @import("snail");
const atlas_ref_mod = @import("atlas_ref.zig");
const glyph_misses = @import("glyph_misses.zig");
const render_snapshot = @import("render_snapshot.zig");
const render_config = @import("render_config.zig");
const render_common = @import("render_common.zig");
const row_build = @import("row_build.zig");
const color = @import("color.zig");
const Rgb = color.Rgb;

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

const wl = @cImport(@cInclude("wayland-client.h"));

const baseline_factor: f32 = row_build.baseline_factor;
const RESOURCE_ENTRY_CAP: usize = 4;

inline fn argbPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

/// snail-style float color (sRGB, 0..1) → ARGB8888 with full alpha.
/// Rounds rather than truncating so a u8→f32→u8 round-trip is exact.
inline fn colorToArgb(rgba: [4]f32) u32 {
    const r: u8 = @intFromFloat(@round(@max(0.0, @min(255.0, rgba[0] * 255.0))));
    const g: u8 = @intFromFloat(@round(@max(0.0, @min(255.0, rgba[1] * 255.0))));
    const b: u8 = @intFromFloat(@round(@max(0.0, @min(255.0, rgba[2] * 255.0))));
    return argbPixel(r, g, b, 255);
}

/// Memset the entire buffer to a single ARGB8 pixel.
fn clearBuffer(map_ptr: *anyopaque, width: u32, height: u32, stride: u32, pixel: u32) void {
    const base: [*]u8 = @ptrCast(map_ptr);
    if (stride == width * 4) {
        const total: usize = @as(usize, width) * height;
        const pixels: [*]u32 = @ptrCast(@alignCast(base));
        @memset(pixels[0..total], pixel);
        return;
    }
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row: [*]u32 = @ptrCast(@alignCast(base + @as(usize, y) * stride));
        @memset(row[0..width], pixel);
    }
}

/// Clipped axis-aligned solid-color rect into ARGB8 pixels.
fn fillRectArgb(
    map_ptr: *anyopaque,
    width: u32,
    height: u32,
    stride: u32,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    pixel: u32,
) void {
    if (w == 0 or h == 0) return;
    const x0 = @max(x, 0);
    const y0 = @max(y, 0);
    const x1 = @min(x + @as(i32, @intCast(w)), @as(i32, @intCast(width)));
    const y1 = @min(y + @as(i32, @intCast(h)), @as(i32, @intCast(height)));
    if (x1 <= x0 or y1 <= y0) return;
    const span: usize = @intCast(x1 - x0);
    const base: [*]u8 = @ptrCast(map_ptr);
    var py: i32 = y0;
    while (py < y1) : (py += 1) {
        const row_off: usize = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(x0)) * 4;
        const row: [*]u32 = @ptrCast(@alignCast(base + row_off));
        @memset(row[0..span], pixel);
    }
}

/// Wayland SHM buffer + project-owned blitter, used by the bootstrap splash
/// path before EGL is ready.
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
            wl.WL_SHM_FORMAT_ARGB8888,
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
        clearBuffer(map, self.width, self.height, self.stride, argbPixel(bg.r, bg.g, bg.b, 255));
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

/// Persistent CPU renderer + scene state. One instance per CPU worker thread.
pub const SnapshotRenderer = struct {
    allocator: std.mem.Allocator,

    cpu: snail.CpuRenderer,
    scene: snail.Scene,
    builder: snail.TextBlobBuilder,
    /// Per-frame blobs, heap-allocated so the scene can record stable
    /// `*const TextBlob` pointers across mid-frame growth.
    blobs: std.ArrayList(*snail.TextBlob) = .empty,

    prepared: ?snail.PreparedResources = null,
    prepared_atlas_identity: u64 = 0,

    atlas_lease: ?atlas_ref_mod.AtlasRef.Lease = null,
    builder_atlas_identity: u64 = 0,

    draw_buf: std.ArrayList(u32) = .empty,
    seg_buf: std.ArrayList(snail.DrawSegment) = .empty,
    overrides: [render_snapshot.MaxRows + 4]snail.Override = undefined,
    resource_entries: [RESOURCE_ENTRY_CAP]snail.ResourceSet.Entry = undefined,
    scratch_rects: []row_build.ColoredRect,
    config: render_config.RenderConfig,

    row_cache: row_build.RowCache,
    /// Last metrics applied to the cache. Any change invalidates every
    /// cached blob because `placement.em` is baked per-glyph.
    cached_metrics: ?row_build.Metrics = null,

    pub fn init(allocator: std.mem.Allocator) !SnapshotRenderer {
        const config = render_config.loadFromEnv();
        const subpixel = render_config.effectiveSubpixelOrder(config);

        // Buffer is reinit'd per frame with the SHM map.
        var cpu = snail.CpuRenderer.init(@ptrFromInt(@alignOf(u8)), 1, 1, 4);
        cpu.setSubpixelOrder(subpixel);
        // Default encoding; the per-draw ResolveTarget.encoding in
        // flushDraw is what actually drives output, but match here for
        // consistency.
        cpu.setTargetEncoding(.srgb_pixels_on_linear_framebuffer);

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
            .row_cache = row_build.RowCache.init(allocator, 32 * 1024 * 1024),
        };
    }

    pub fn deinit(self: *SnapshotRenderer) void {
        self.row_cache.deinit();
        for (self.blobs.items) |b| {
            b.deinit();
            self.allocator.destroy(b);
        }
        self.blobs.deinit(self.allocator);
        self.draw_buf.deinit(self.allocator);
        self.seg_buf.deinit(self.allocator);
        if (self.prepared) |*p| p.deinit();
        if (self.builder_atlas_identity != 0) self.builder.deinit();
        if (self.atlas_lease) |*lease| lease.release();
        self.scene.deinit();
        self.allocator.free(self.scratch_rects);
    }

    fn ensureBuilderForAtlas(self: *SnapshotRenderer, atlas_lease: *const atlas_ref_mod.AtlasRef.Lease) void {
        const atlas = atlas_lease.get();
        const id = atlas.snapshotIdentity();
        if (id == self.builder_atlas_identity) return;
        if (self.prepared) |*p| {
            p.deinit();
            self.prepared = null;
            self.prepared_atlas_identity = 0;
        }
        if (self.builder_atlas_identity != 0) self.builder.deinit();
        self.builder = snail.TextBlobBuilder.init(self.allocator, atlas);
        // Migrate cached row blobs onto the new atlas snapshot. Dirty
        // (had_misses) entries get evicted; clean entries are rebound.
        // The old lease must outlive this call: blob.rebound's
        // validateRebindAtlas dereferences the blob's atlas pointer (the
        // old snapshot). First-time install (builder_atlas_identity == 0)
        // has no cache yet, so this is a cheap no-op then.
        _ = self.row_cache.rebindAll(atlas, id);
        if (self.atlas_lease) |*old_lease| old_lease.release();
        self.atlas_lease = atlas_lease.clone();
        self.builder_atlas_identity = id;
    }

    fn invalidatePreparedIfStale(self: *SnapshotRenderer, atlas_identity: u64) void {
        if (self.prepared) |*p| {
            if (self.prepared_atlas_identity == atlas_identity) return;
            p.deinit();
            self.prepared = null;
        }
    }

    fn refreshPrepared(self: *SnapshotRenderer, atlas_identity: u64) !*const snail.PreparedResources {
        if (self.prepared) |*p| {
            if (self.prepared_atlas_identity == atlas_identity) return p;
            p.deinit();
            self.prepared = null;
        }
        var rs = snail.ResourceSet.init(self.resource_entries[0..]);
        try rs.addScene(&self.scene);
        const allocators: snail.UploadAllocators = .{
            .persistent = self.allocator,
            .scratch = self.allocator,
        };
        self.prepared = try self.cpu.uploadResourcesBlocking(allocators, &rs);
        self.prepared_atlas_identity = atlas_identity;
        return &self.prepared.?;
    }

    fn releaseBlobs(self: *SnapshotRenderer) void {
        for (self.blobs.items) |b| {
            b.deinit();
            self.allocator.destroy(b);
        }
        self.blobs.clearRetainingCapacity();
    }

    fn stashBlob(self: *SnapshotRenderer, blob: snail.TextBlob) ?*const snail.TextBlob {
        const slot = self.allocator.create(snail.TextBlob) catch {
            var b = blob;
            b.deinit();
            return null;
        };
        slot.* = blob;
        self.blobs.append(self.allocator, slot) catch {
            slot.deinit();
            self.allocator.destroy(slot);
            return null;
        };
        return slot;
    }

    /// Render a snapshot to a Wayland SHM buffer. Returns any text runs
    /// whose glyphs weren't in the atlas — caller forwards to the atlas
    /// thread for extension.
    pub fn renderToMemory(
        self: *SnapshotRenderer,
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
        const header = snapshot.header;
        const default_fg = header.default_fg;
        const default_bg = header.default_bg;

        // Reinitialize CPU renderer for this frame's buffer geometry.
        self.cpu.reinitBuffer(@ptrCast(map_ptr), width, height, stride);

        // Project-owned background clear.
        clearBuffer(map_ptr, width, height, stride, argbPixel(default_bg.r, default_bg.g, default_bg.b, 255));

        // Atlas snapshot may have advanced since the last frame. Order
        // matters: stale-prepared check first so the rebind inside
        // ensureBuilderForAtlas doesn't see a half-torn-down state.
        self.invalidatePreparedIfStale(atlas_lease.get().snapshotIdentity());
        self.ensureBuilderForAtlas(atlas_lease);

        self.row_cache.beginFrame();
        const metrics: row_build.Metrics = .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .font_size = font_size,
        };
        if (self.cached_metrics) |prev| {
            if (prev.cell_width != metrics.cell_width or
                prev.cell_height != metrics.cell_height or
                prev.font_size != metrics.font_size)
            {
                self.row_cache.clear();
            }
        }
        self.cached_metrics = metrics;

        self.scene.reset();
        self.releaseBlobs();

        const rows = @min(header.rows, render_snapshot.MaxRows);
        const cols = @min(header.cols, render_snapshot.MaxCols);

        var override_index: usize = 0;
        var cursor_cell: ?render_common.CursorCell = null;
        var cell_index: usize = 0;

        var row_idx: u16 = 0;
        while (row_idx < rows) : (row_idx += 1) {
            const row_y = @as(f32, @floatFromInt(row_idx)) * cell_height;
            const row_start_index = cell_index;

            // Capture cursor cell on this row.
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

            const content_hash = row_build.hashSnapshotRow(snapshot, row_start_index, cols);
            const next_index = row_start_index + @min(@as(usize, cols), header.cell_count -| row_start_index);

            if (self.row_cache.get(content_hash)) |row| {
                if (!row.had_misses and row.atlas_identity == self.builder_atlas_identity) {
                    try self.appendCachedRow(row, row_y, map_ptr, width, height, stride, &override_index);
                    cell_index = next_index;
                    continue;
                }
            }

            const built = try self.buildRowToBlob(snapshot, &cell_index, cols, metrics, &misses);
            cell_index = next_index;
            if (self.row_cache.store(content_hash, built.blob, built.rects, self.builder_atlas_identity, built.had_misses)) |row| {
                try self.appendCachedRow(row, row_y, map_ptr, width, height, stride, &override_index);
            }
        }

        // Cursor: solid rect + (block style only) inverted glyph.
        if (header.cursor_visible != 0 and header.cursor_in_viewport != 0) {
            const cx_i = @as(i32, @intCast(@as(u32, header.cursor_x))) * @as(i32, @intFromFloat(cell_width));
            const cy_i = @as(i32, @intCast(@as(u32, header.cursor_y))) * @as(i32, @intFromFloat(cell_height));
            const cw: u32 = @intFromFloat(cell_width);
            const ch: u32 = @intFromFloat(cell_height);
            const cc = if (header.cursor_has_color != 0) header.cursor_color else default_fg;
            const cc_pixel = argbPixel(cc.r, cc.g, cc.b, 255);
            switch (header.cursor_style) {
                .block => fillRectArgb(map_ptr, width, height, stride, cx_i, cy_i, cw, ch, cc_pixel),
                .bar => fillRectArgb(map_ptr, width, height, stride, cx_i, cy_i, 2, ch, cc_pixel),
                .underline => fillRectArgb(map_ptr, width, height, stride, cx_i, cy_i + @as(i32, @intCast(ch -| 2)), cw, 2, cc_pixel),
                .block_hollow => {
                    fillRectArgb(map_ptr, width, height, stride, cx_i, cy_i, cw, 2, cc_pixel);
                    fillRectArgb(map_ptr, width, height, stride, cx_i, cy_i + @as(i32, @intCast(ch -| 2)), cw, 2, cc_pixel);
                    fillRectArgb(map_ptr, width, height, stride, cx_i, cy_i, 2, ch, cc_pixel);
                    fillRectArgb(map_ptr, width, height, stride, cx_i + @as(i32, @intCast(cw -| 2)), cy_i, 2, ch, cc_pixel);
                },
            }

            if (header.cursor_style == .block) {
                if (cursor_cell) |cell| {
                    if (cell.has_text and cell.glyph_id != 0) {
                        try self.appendCursorGlyph(
                            cell,
                            @as(f32, @floatFromInt(header.cursor_x)) * cell_width,
                            @as(f32, @floatFromInt(header.cursor_y)) * cell_height,
                            cell_height * baseline_factor,
                            font_size,
                            &misses,
                        );
                    }
                }
            }
        }

        if (!misses.isEmpty()) {
            self.releaseBlobs();
            return misses;
        }

        try self.flushDraw(width, height);
        self.releaseBlobs();
        return misses;
    }

    /// Build the row at row-local coordinates (Y = 0). Caller takes
    /// ownership of the returned blob+rects and is expected to hand them
    /// to RowCache.store.
    fn buildRowToBlob(
        self: *SnapshotRenderer,
        snapshot: *const render_snapshot.SharedSnapshot,
        cell_index: *usize,
        cols: u16,
        metrics: row_build.Metrics,
        misses: *glyph_misses.Set,
    ) !struct {
        blob: snail.TextBlob,
        rects: []row_build.ColoredRect,
        had_misses: bool,
    } {
        self.builder.reset();
        const built = try row_build.buildRow(
            snapshot,
            cell_index,
            cols,
            0,
            self.scratch_rects,
            &self.builder,
            self.atlas_lease.?.get(),
            self.allocator,
            metrics,
            misses,
        );
        const blob = try self.builder.finish();
        const rects = try self.allocator.dupe(row_build.ColoredRect, self.scratch_rects[0..built.rect_count]);
        return .{ .blob = blob, .rects = rects, .had_misses = built.had_misses };
    }

    /// Submit a cached row: rects via fillRectArgb (row_y added at submit
    /// time so a row-local cache entry serves any Y), and the blob into
    /// the scene via Override.transform = translate(0, row_y).
    fn appendCachedRow(
        self: *SnapshotRenderer,
        row: *row_build.Row,
        row_y: f32,
        map_ptr: *anyopaque,
        width: u32,
        height: u32,
        stride: u32,
        override_index: *usize,
    ) !void {
        for (row.rects) |r| {
            fillRectArgb(
                map_ptr,
                width,
                height,
                stride,
                @intFromFloat(r.x),
                @intFromFloat(r.y + row_y),
                @intFromFloat(r.w),
                @intFromFloat(r.h),
                colorToArgb(r.color),
            );
        }

        if (row.blob.glyphCount() == 0) return;
        if (override_index.* >= self.overrides.len) return;
        self.overrides[override_index.*] = .{
            .transform = snail.Transform2D.translate(0, row_y),
            .tint = .{ 1, 1, 1, 1 },
        };
        const slot = self.overrides[override_index.* .. override_index.* + 1];
        override_index.* += 1;
        try self.scene.addText(.{ .blob = row.blob, .instances = slot });
    }

    fn appendCursorGlyph(
        self: *SnapshotRenderer,
        cell: render_common.CursorCell,
        cx: f32,
        cy: f32,
        baseline: f32,
        font_size: f32,
        misses: *glyph_misses.Set,
    ) !void {
        self.builder.reset();
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cell.codepoint), &tmp) catch return;
        const atlas = self.atlas_lease.?.get();
        var shaped = try atlas.shapeText(self.allocator, .{}, tmp[0..n]);
        defer shaped.deinit();
        const result = try self.builder.append(.{
            .shaped = &shaped,
            .placement = .{ .baseline = .{ .x = cx, .y = cy + baseline }, .em = font_size },
            .fill = .{ .solid = cell.bg.toFloat4(1.0) },
        });
        if (result.missing) {
            misses.addRun(tmp[0..n]);
            return;
        }
        const blob = try self.builder.finish();
        const blob_ptr = self.stashBlob(blob) orelse return;
        try self.scene.addText(.{ .blob = blob_ptr });
    }

    fn flushDraw(self: *SnapshotRenderer, viewport_w: u32, viewport_h: u32) !void {
        const opts = snail.DrawOptions{
            .mvp = snail.Mat4.ortho(0, @floatFromInt(viewport_w), @floatFromInt(viewport_h), 0, -1, 1),
            .target = .{
                .pixel_width = @floatFromInt(viewport_w),
                .pixel_height = @floatFromInt(viewport_h),
                .subpixel_order = render_config.effectiveSubpixelOrder(self.config),
                // CPU "framebuffer" is the linear byte buffer; final
                // stored pixels are sRGB-encoded.
                .encoding = .srgb_pixels_on_linear_framebuffer,
            },
        };

        const prepared = try self.refreshPrepared(self.builder_atlas_identity);

        const buf_words = snail.DrawList.estimate(&self.scene, opts);
        const seg_count = snail.DrawList.estimateSegments(&self.scene, opts);
        try self.draw_buf.resize(self.allocator, buf_words);
        try self.seg_buf.resize(self.allocator, seg_count);
        var draw_list = snail.DrawList.init(self.draw_buf.items, self.seg_buf.items);
        try draw_list.addScene(prepared, &self.scene, opts);
        try self.cpu.draw(prepared, draw_list.slice(), opts);
    }
};
