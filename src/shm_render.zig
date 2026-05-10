//! SHM first-frame rendering using snail's CPU rasterizer.
//! Same Bézier curve quality as the GPU path, evaluated per-pixel on CPU.
//! Renders directly into a Wayland SHM buffer (zero-copy).

const std = @import("std");
const snail = @import("snail");
const glyph_misses = @import("glyph_misses.zig");
const terminal_mod = @import("terminal.zig");
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

pub const ShmFrame = struct {
    renderer: snail.CpuRenderer,
    map_ptr: ?*anyopaque,
    map_size: usize,
    fd: c_int,
    wl_pool: ?*wl.wl_shm_pool,
    wl_buffer: ?*wl.wl_buffer,
    width: u32,
    height: u32,

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
            .renderer = snail.CpuRenderer.init(@ptrCast(map), w, h, stride),
            .map_ptr = map,
            .map_size = size,
            .fd = fd,
            .wl_pool = pool,
            .wl_buffer = buffer,
            .width = w,
            .height = h,
        };
    }

    pub fn fillBackground(self: *ShmFrame, bg: Rgb) void {
        const pixel: u32 = 0xff000000 | (@as(u32, bg.r) << 16) | (@as(u32, bg.g) << 8) | bg.b;
        const pixels: [*]u32 = @ptrCast(@alignCast(self.map_ptr.?));
        const count = (self.width * self.height);
        @memset(pixels[0..count], pixel);
    }

    pub fn destroy(self: *ShmFrame) void {
        if (self.wl_buffer) |b| wl.wl_buffer_destroy(b);
        if (self.wl_pool) |p| wl.wl_shm_pool_destroy(p);
        if (self.map_ptr) |m| _ = c.munmap(m, self.map_size);
        if (self.fd >= 0) _ = c.close(self.fd);
    }

    /// Render terminal content using snail's CPU rasterizer.
    /// Same Bézier quality as GPU — just slower per-pixel.
    pub fn renderTerminal(
        self: *ShmFrame,
        term: *terminal_mod.Terminal,
        atlas: *const snail.Atlas,
        font: *const snail.Font,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
        default_fg: Rgb,
        default_bg: Rgb,
    ) glyph_misses.Set {
        var misses: glyph_misses.Set = .{};
        term.updateRenderState() catch return .{};
        const colors = term.getColors();
        const cursor = term.getCursor();
        const effective_default_fg = colors.foreground;
        const effective_default_bg = colors.background;
        _ = default_fg;
        _ = default_bg;

        self.renderer.clear(effective_default_bg.r, effective_default_bg.g, effective_default_bg.b, 255);

        var cursor_cell: ?render_common.CursorCell = null;
        var run_buf: [2048]u8 = undefined;

        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            const cell_y = @as(f32, @floatFromInt(row_idx)) * cell_height;
            var run_start: u16 = 0;
            var run_fg: ?Rgb = null;
            var run_len: usize = 0;

            term.beginCellIteration();
            var col_idx: u16 = 0;
            while (term.nextCell()) : (col_idx += 1) {
                const cell = term.getCellInfo();
                const resolved = render_common.resolveCellColors(
                    effective_default_fg,
                    effective_default_bg,
                    cell.fg,
                    cell.bg,
                    cell.style.inverse != false,
                    cell.style.faint != false,
                );
                const fg = resolved.fg;
                const cell_bg = resolved.bg;

                if (cursor.visible and cursor.in_viewport and row_idx == cursor.y and col_idx == cursor.x) {
                    const glyph_id: u16 = if (cell.has_text and render_common.isRenderableCodepoint(cell.codepoint))
                        (font.glyphIndex(cell.codepoint) catch 0)
                    else
                        0;
                    cursor_cell = render_common.captureCursorCell(effective_default_bg, cell.codepoint, glyph_id, cell.has_text, resolved);
                }

                // Background
                if (cell_bg) |cbg| {
                    self.renderer.fillRect(
                        @intFromFloat(@as(f32, @floatFromInt(col_idx)) * cell_width),
                        @intFromFloat(cell_y),
                        @intFromFloat(cell_width),
                        @intFromFloat(cell_height),
                        cbg.r, cbg.g, cbg.b, 255,
                    );
                }

                // Text run coalescing (shaped via drawText, matching GPU path)
                const has_renderable_text = cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000;
                const fg_matches = if (run_fg) |rf| rf.r == fg.r and rf.g == fg.g and rf.b == fg.b else false;

                if (!has_renderable_text or !fg_matches or cell.style.underline != 0 or cell.style.strikethrough != false) {
                    if (run_len > 0) {
                        _ = self.renderer.drawText(atlas, font, run_buf[0..run_len],
                            @as(f32, @floatFromInt(run_start)) * cell_width,
                            cell_y + cell_height * 0.8,
                            font_size, run_fg.?.toLinearFloat4(1.0));
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
                    const glyph_id = font.glyphIndex(cell.codepoint) catch 0;
                    if (glyph_id != 0 and atlas.getGlyph(glyph_id) == null) {
                        misses.addCodepoint(cell.codepoint);
                    }
                    const encoded = std.unicode.utf8Encode(@intCast(cell.codepoint), run_buf[run_len..]) catch 0;
                    if (encoded > 0) {
                        run_len += encoded;
                    }
                }

                if (cell.style.underline != 0) {
                    self.renderer.fillRect(
                        @intFromFloat(@as(f32, @floatFromInt(col_idx)) * cell_width),
                        @intFromFloat(cell_y + cell_height - 1),
                        @intFromFloat(cell_width), 1,
                        fg.r, fg.g, fg.b, 255,
                    );
                }
                if (cell.style.strikethrough != false) {
                    self.renderer.fillRect(
                        @intFromFloat(@as(f32, @floatFromInt(col_idx)) * cell_width),
                        @intFromFloat(cell_y + cell_height * 0.45),
                        @intFromFloat(cell_width), 1,
                        fg.r, fg.g, fg.b, 255,
                    );
                }
            }

            // Flush final text run
            if (run_len > 0) {
                _ = self.renderer.drawText(atlas, font, run_buf[0..run_len],
                    @as(f32, @floatFromInt(run_start)) * cell_width,
                    cell_y + cell_height * 0.8,
                    font_size, run_fg.?.toLinearFloat4(1.0));
            }
        }

        if (cursor.visible and cursor.in_viewport) {
            const cx: i32 = @intFromFloat(@as(f32, @floatFromInt(cursor.x)) * cell_width);
            const cy: i32 = @intFromFloat(@as(f32, @floatFromInt(cursor.y)) * cell_height);
            const cc = colors.cursor orelse colors.foreground;
            const cursor_w: u32 = @intFromFloat(cell_width);
            const cursor_h: u32 = @intFromFloat(cell_height);
            switch (cursor.style) {
                .block => self.renderer.fillRect(cx, cy, cursor_w, cursor_h, cc.r, cc.g, cc.b, 255),
                .bar => self.renderer.fillRect(cx, cy, 2, cursor_h, cc.r, cc.g, cc.b, 255),
                .underline => self.renderer.fillRect(cx, cy + @as(i32, @intCast(cursor_h -| 2)), cursor_w, 2, cc.r, cc.g, cc.b, 255),
                .block_hollow => {
                    self.renderer.fillRect(cx, cy, cursor_w, 2, cc.r, cc.g, cc.b, 255);
                    self.renderer.fillRect(cx, cy + @as(i32, @intCast(cursor_h -| 2)), cursor_w, 2, cc.r, cc.g, cc.b, 255);
                    self.renderer.fillRect(cx, cy, 2, cursor_h, cc.r, cc.g, cc.b, 255);
                    self.renderer.fillRect(cx + @as(i32, @intCast(cursor_w -| 2)), cy, 2, cursor_h, cc.r, cc.g, cc.b, 255);
                },
            }

            if (cursor.style == .block) {
                if (cursor_cell) |cell| {
                    if (cell.has_text and cell.glyph_id != 0) {
                        if (atlas.getGlyph(cell.glyph_id) == null) {
                            misses.addCodepoint(cell.codepoint);
                        }
                        self.renderer.drawGlyph(
                            atlas, font, cell.codepoint,
                            @as(f32, @floatFromInt(cursor.x)) * cell_width,
                            @as(f32, @floatFromInt(cursor.y)) * cell_height + cell_height * 0.8,
                            font_size, cell.bg.toLinearFloat4(1.0),
                        );
                    }
                }
            }
        }

        term.resetDirty();
        return misses;
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

fn renderSnapshotWithCpuRenderer(
    renderer: *snail.CpuRenderer,
    snapshot: *const render_snapshot.SharedSnapshot,
    atlas: *const snail.Atlas,
    font: *const snail.Font,
    font_size: f32,
    cell_width: f32,
    cell_height: f32,
) glyph_misses.Set {
    var misses: glyph_misses.Set = .{};
    const header = snapshot.header;
    const default_fg = header.default_fg;
    const default_bg = header.default_bg;
    const cursor_color = if (header.cursor_has_color != 0) header.cursor_color else null;

    renderer.clear(default_bg.r, default_bg.g, default_bg.b, 255);

    var cursor_cell: ?render_common.CursorCell = null;
    const rows = @min(header.rows, render_snapshot.MaxRows);
    const cols = @min(header.cols, render_snapshot.MaxCols);
    var run_buf: [2048]u8 = undefined;

    var cell_index: usize = 0;
    var row_idx: u16 = 0;
    while (row_idx < rows) : (row_idx += 1) {
        const cell_y = @as(f32, @floatFromInt(row_idx)) * cell_height;
        var run_start: u16 = 0;
        var run_fg: ?Rgb = null;
        var run_len: usize = 0;

        var col_idx: u16 = 0;
        while (col_idx < cols and cell_index < header.cell_count) : ({
            col_idx += 1;
            cell_index += 1;
        }) {
            const cell = snapshot.cells[cell_index];
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

            if (header.cursor_visible != 0 and header.cursor_in_viewport != 0 and
                row_idx == header.cursor_y and col_idx == header.cursor_x)
            {
                cursor_cell = render_common.captureCursorCell(default_bg, cell.codepoint, cell.glyph_id, flags.has_text, resolved);
            }

            // Background
            if (cell_bg) |cbg| {
                renderer.fillRect(
                    @intFromFloat(@as(f32, @floatFromInt(col_idx)) * cell_width),
                    @intFromFloat(cell_y),
                    @intFromFloat(cell_width),
                    @intFromFloat(cell_height),
                    cbg.r, cbg.g, cbg.b, 255,
                );
            }

            // Text run coalescing (shaped via drawText, matching GPU path)
            const has_renderable_text = flags.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000;
            const fg_matches = if (run_fg) |rf| rf.r == fg.r and rf.g == fg.g and rf.b == fg.b else false;

            if (!has_renderable_text or !fg_matches or flags.underline or flags.strikethrough) {
                if (run_len > 0) {
                    _ = renderer.drawText(atlas, font, run_buf[0..run_len],
                        @as(f32, @floatFromInt(run_start)) * cell_width,
                        cell_y + cell_height * 0.8,
                        font_size, run_fg.?.toLinearFloat4(1.0));
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
                if (cell.glyph_id != 0 and atlas.getGlyph(cell.glyph_id) == null) {
                    misses.addCodepoint(cell.codepoint);
                }
                const encoded = std.unicode.utf8Encode(@intCast(cell.codepoint), run_buf[run_len..]) catch 0;
                if (encoded > 0) {
                    run_len += encoded;
                }
            }

            if (flags.underline) {
                renderer.fillRect(
                    @intFromFloat(@as(f32, @floatFromInt(col_idx)) * cell_width),
                    @intFromFloat(cell_y + cell_height - 1),
                    @intFromFloat(cell_width), 1,
                    fg.r, fg.g, fg.b, 255,
                );
            }
            if (flags.strikethrough) {
                renderer.fillRect(
                    @intFromFloat(@as(f32, @floatFromInt(col_idx)) * cell_width),
                    @intFromFloat(cell_y + cell_height * 0.45),
                    @intFromFloat(cell_width), 1,
                    fg.r, fg.g, fg.b, 255,
                );
            }
        }

        // Flush final text run
        if (run_len > 0) {
            _ = renderer.drawText(atlas, font, run_buf[0..run_len],
                @as(f32, @floatFromInt(run_start)) * cell_width,
                cell_y + cell_height * 0.8,
                font_size, run_fg.?.toLinearFloat4(1.0));
        }
    }

    if (header.cursor_visible != 0 and header.cursor_in_viewport != 0) {
        const cx: i32 = @intFromFloat(@as(f32, @floatFromInt(header.cursor_x)) * cell_width);
        const cy: i32 = @intFromFloat(@as(f32, @floatFromInt(header.cursor_y)) * cell_height);
        const cc = cursor_color orelse default_fg;
        const cursor_w: u32 = @intFromFloat(cell_width);
        const cursor_h: u32 = @intFromFloat(cell_height);
        switch (header.cursor_style) {
            .block => renderer.fillRect(cx, cy, cursor_w, cursor_h, cc.r, cc.g, cc.b, 255),
            .bar => renderer.fillRect(cx, cy, 2, cursor_h, cc.r, cc.g, cc.b, 255),
            .underline => renderer.fillRect(cx, cy + @as(i32, @intCast(cursor_h -| 2)), cursor_w, 2, cc.r, cc.g, cc.b, 255),
            .block_hollow => {
                renderer.fillRect(cx, cy, cursor_w, 2, cc.r, cc.g, cc.b, 255);
                renderer.fillRect(cx, cy + @as(i32, @intCast(cursor_h -| 2)), cursor_w, 2, cc.r, cc.g, cc.b, 255);
                renderer.fillRect(cx, cy, 2, cursor_h, cc.r, cc.g, cc.b, 255);
                renderer.fillRect(cx + @as(i32, @intCast(cursor_w -| 2)), cy, 2, cursor_h, cc.r, cc.g, cc.b, 255);
            },
        }

        if (header.cursor_style == .block) {
            if (cursor_cell) |cell| {
                if (cell.has_text and cell.glyph_id != 0) {
                    if (atlas.getGlyph(cell.glyph_id) == null) {
                        misses.addCodepoint(cell.codepoint);
                    }
                    renderer.drawGlyph(
                        atlas, font, cell.codepoint,
                        @as(f32, @floatFromInt(header.cursor_x)) * cell_width,
                        @as(f32, @floatFromInt(header.cursor_y)) * cell_height + cell_height * 0.8,
                        font_size, cell.bg.toLinearFloat4(1.0),
                    );
                }
            }
        }
    }
    return misses;
}

pub fn renderSnapshotToMemory(
    map_ptr: *anyopaque,
    width: u32,
    height: u32,
    stride: u32,
    snapshot: *const render_snapshot.SharedSnapshot,
    atlas: *const snail.Atlas,
    font: *const snail.Font,
    font_size: f32,
    cell_width: f32,
    cell_height: f32,
) glyph_misses.Set {
    var renderer = snail.CpuRenderer.init(@ptrCast(map_ptr), width, height, stride);
    return renderSnapshotWithCpuRenderer(&renderer, snapshot, atlas, font, font_size, cell_width, cell_height);
}
