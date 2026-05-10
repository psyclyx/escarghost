//! SHM rendering: project-owned solid-color blitter for backgrounds and
//! decorations, plus snail's CPU rasterizer (driven through the unified
//! Scene/ResourceSet/PreparedResources/DrawList pipeline) for text.

const std = @import("std");
const snail = @import("snail");
const glyph_misses = @import("glyph_misses.zig");
const render_snapshot = @import("render_snapshot.zig");
const render_common = @import("render_common.zig");
const color = @import("color.zig");
const Rgb = color.Rgb;

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

const wl = @cImport(@cInclude("wayland-client.h"));

const baseline_factor: f32 = 0.8;
const RESOURCE_ENTRY_CAP: usize = 4;

inline fn argbPixel(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
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

        const fd = c.memfd_create("mollusk-shm", @as(c_uint, 0));
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
    blobs: std.ArrayList(snail.TextBlob) = .empty,

    prepared: ?snail.PreparedResources = null,
    prepared_atlas_identity: u64 = 0,

    builder_atlas_identity: u64 = 0,

    draw_buf: std.ArrayList(u32) = .empty,
    seg_buf: std.ArrayList(snail.DrawSegment) = .empty,
    overrides: [render_snapshot.MaxRows + 4]snail.Override = undefined,
    resource_entries: [RESOURCE_ENTRY_CAP]snail.ResourceSet.Entry = undefined,
    run_buf: [2048]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) !SnapshotRenderer {
        // Buffer is reinit'd per frame with the SHM map.
        var cpu = snail.CpuRenderer.init(@ptrFromInt(@alignOf(u8)), 1, 1, 4);
        cpu.setSubpixelOrder(.none); // greyscale AA

        var scene = snail.Scene.init(allocator);
        errdefer scene.deinit();

        // Builder needs an atlas to bind to; defer real init to the first frame.
        const builder = snail.TextBlobBuilder.init(allocator, undefined);

        return .{
            .allocator = allocator,
            .cpu = cpu,
            .scene = scene,
            .builder = builder,
        };
    }

    pub fn deinit(self: *SnapshotRenderer) void {
        for (self.blobs.items) |*b| b.deinit();
        self.blobs.deinit(self.allocator);
        self.draw_buf.deinit(self.allocator);
        self.seg_buf.deinit(self.allocator);
        if (self.builder_atlas_identity != 0) self.builder.deinit();
        self.scene.deinit();
        if (self.prepared) |*p| p.deinit();
    }

    fn ensureBuilderForAtlas(self: *SnapshotRenderer, atlas: *const snail.TextAtlas) void {
        const id = atlas.snapshotIdentity();
        if (id == self.builder_atlas_identity) return;
        if (self.builder_atlas_identity != 0) self.builder.deinit();
        self.builder = snail.TextBlobBuilder.init(self.allocator, atlas);
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
        self.prepared = try self.cpu.uploadResourcesBlocking(self.allocator, &rs);
        self.prepared_atlas_identity = atlas_identity;
        return &self.prepared.?;
    }

    fn releaseBlobs(self: *SnapshotRenderer) void {
        for (self.blobs.items) |*b| b.deinit();
        self.blobs.clearRetainingCapacity();
    }

    fn stashBlob(self: *SnapshotRenderer, blob: snail.TextBlob) ?*const snail.TextBlob {
        self.blobs.ensureUnusedCapacity(self.allocator, 1) catch {
            var b = blob;
            b.deinit();
            return null;
        };
        self.blobs.appendAssumeCapacity(blob);
        return &self.blobs.items[self.blobs.items.len - 1];
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
        atlas: *const snail.TextAtlas,
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

        // Atlas snapshot may have advanced since the last frame.
        self.invalidatePreparedIfStale(atlas.snapshotIdentity());
        self.ensureBuilderForAtlas(atlas);

        self.scene.reset();
        self.releaseBlobs();

        const rows = @min(header.rows, render_snapshot.MaxRows);
        const cols = @min(header.cols, render_snapshot.MaxCols);
        const baseline = cell_height * baseline_factor;

        var override_index: usize = 0;
        var cursor_cell: ?render_common.CursorCell = null;
        var cell_index: usize = 0;

        var row_idx: u16 = 0;
        while (row_idx < rows) : (row_idx += 1) {
            const cell_y = @as(f32, @floatFromInt(row_idx)) * cell_height;
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

            try self.appendRow(
                snapshot,
                &cell_index,
                cols,
                cell_y,
                baseline,
                cell_width,
                cell_height,
                font_size,
                map_ptr,
                width,
                height,
                stride,
                &override_index,
                &misses,
            );
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
                            baseline,
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

    fn appendRow(
        self: *SnapshotRenderer,
        snapshot: *const render_snapshot.SharedSnapshot,
        cell_index: *usize,
        cols: u16,
        cell_y: f32,
        baseline: f32,
        cell_width: f32,
        cell_height: f32,
        font_size: f32,
        map_ptr: *anyopaque,
        width: u32,
        height: u32,
        stride: u32,
        override_index: *usize,
        misses: *glyph_misses.Set,
    ) !void {
        const default_fg = snapshot.header.default_fg;
        const default_bg = snapshot.header.default_bg;

        self.builder.reset();

        var bg_span_start: u16 = 0;
        var bg_span_color: ?Rgb = null;
        var bg_span_len: u16 = 0;

        var run_start: u16 = 0;
        var run_fg: ?Rgb = null;
        var run_len: usize = 0;

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
                        fillRectArgb(
                            map_ptr,
                            width,
                            height,
                            stride,
                            @intFromFloat(@as(f32, @floatFromInt(bg_span_start)) * cell_width),
                            @intFromFloat(cell_y),
                            @intFromFloat(@as(f32, @floatFromInt(bg_span_len)) * cell_width),
                            @intFromFloat(cell_height),
                            argbPixel(sc.r, sc.g, sc.b, 255),
                        );
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

            const has_renderable_text = flags.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000;
            const fg_matches = if (run_fg) |rf| rf.r == fg.r and rf.g == fg.g and rf.b == fg.b else false;

            if (!has_renderable_text or !fg_matches or flags.underline or flags.strikethrough) {
                if (run_len > 0) {
                    const result = try self.builder.addText(
                        .{},
                        self.run_buf[0..run_len],
                        @as(f32, @floatFromInt(run_start)) * cell_width,
                        cell_y + baseline,
                        font_size,
                        run_fg.?.toFloat4(1.0),
                    );
                    if (result.missing) misses.addRun(self.run_buf[0..run_len]);
                    run_len = 0;
                    run_fg = null;
                }
            }

            if (has_renderable_text) {
                if (run_fg == null) {
                    run_start = col_idx;
                    run_fg = fg;
                    run_len = 0;
                }
                const encoded = std.unicode.utf8Encode(@intCast(cell.codepoint), self.run_buf[run_len..]) catch 0;
                if (encoded > 0) run_len += encoded;
            }

            if (flags.underline) {
                fillRectArgb(
                    map_ptr,
                    width,
                    height,
                    stride,
                    @intFromFloat(@as(f32, @floatFromInt(col_idx)) * cell_width),
                    @intFromFloat(cell_y + cell_height - 1),
                    @intFromFloat(cell_width),
                    1,
                    argbPixel(fg.r, fg.g, fg.b, 255),
                );
            }
            if (flags.strikethrough) {
                fillRectArgb(
                    map_ptr,
                    width,
                    height,
                    stride,
                    @intFromFloat(@as(f32, @floatFromInt(col_idx)) * cell_width),
                    @intFromFloat(cell_y + cell_height * 0.45),
                    @intFromFloat(cell_width),
                    1,
                    argbPixel(fg.r, fg.g, fg.b, 255),
                );
            }
        }

        if (run_len > 0) {
            const result = try self.builder.addText(
                .{},
                self.run_buf[0..run_len],
                @as(f32, @floatFromInt(run_start)) * cell_width,
                cell_y + baseline,
                font_size,
                run_fg.?.toFloat4(1.0),
            );
            if (result.missing) misses.addRun(self.run_buf[0..run_len]);
        }

        if (bg_span_len > 0) {
            if (bg_span_color) |sc| {
                fillRectArgb(
                    map_ptr,
                    width,
                    height,
                    stride,
                    @intFromFloat(@as(f32, @floatFromInt(bg_span_start)) * cell_width),
                    @intFromFloat(cell_y),
                    @intFromFloat(@as(f32, @floatFromInt(bg_span_len)) * cell_width),
                    @intFromFloat(cell_height),
                    argbPixel(sc.r, sc.g, sc.b, 255),
                );
            }
        }

        if (self.builder.glyphCount() == 0) return;
        const blob = try self.builder.finish();
        const blob_ptr = self.stashBlob(blob) orelse return;

        if (override_index.* >= self.overrides.len) return;
        self.overrides[override_index.*] = .{
            .transform = .identity,
            .tint = .{ 1, 1, 1, 1 },
        };
        const slot = self.overrides[override_index.* .. override_index.* + 1];
        override_index.* += 1;
        try self.scene.addText(.{ .blob = blob_ptr, .instances = slot });
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
        const result = try self.builder.addText(
            .{},
            tmp[0..n],
            cx,
            cy + baseline,
            font_size,
            cell.bg.toFloat4(1.0),
        );
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
                .subpixel_order = .none,
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
