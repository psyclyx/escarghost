const std = @import("std");
const terminal_mod = @import("terminal.zig");
const color = @import("color.zig");
const Rgb = color.Rgb;

const ft = @cImport(@cInclude("ft2build.h"));
// freetype includes are nested
const ft2 = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

const wl = @cImport({
    @cInclude("wayland-client.h");
});

pub const ShmFrame = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    stride: u32,
    buffer: ?*wl.wl_buffer,
    pool: ?*wl.wl_shm_pool,
    map_ptr: ?*anyopaque,
    map_size: usize,
    fd: c_int,

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
            pool, 0, @intCast(w), @intCast(h), @intCast(stride), wl.WL_SHM_FORMAT_ARGB8888,
        ) orelse {
            wl.wl_shm_pool_destroy(pool);
            _ = c.munmap(map, size);
            _ = c.close(fd);
            return null;
        };

        return .{
            .pixels = @ptrCast(@alignCast(map)),
            .width = w,
            .height = h,
            .stride = stride,
            .buffer = buffer,
            .pool = pool,
            .map_ptr = map,
            .map_size = size,
            .fd = fd,
        };
    }

    pub fn destroy(self: *ShmFrame) void {
        if (self.buffer) |b| wl.wl_buffer_destroy(b);
        if (self.pool) |p| wl.wl_shm_pool_destroy(p);
        if (self.map_ptr) |m| _ = c.munmap(m, self.map_size);
        if (self.fd >= 0) _ = c.close(self.fd);
    }

    pub fn fill(self: *ShmFrame, bg: Rgb) void {
        const pixel: u32 = 0xFF000000 | (@as(u32, bg.r) << 16) | (@as(u32, bg.g) << 8) | bg.b;
        const count = @as(usize, self.width) * self.height;
        for (0..count) |i| self.pixels[i] = pixel;
    }

    pub fn putPixel(self: *ShmFrame, x: u32, y: u32, r: u8, g: u8, b: u8, a: u8) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * self.width + x;

        if (a == 255) {
            self.pixels[idx] = 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
        } else if (a > 0) {
            // Alpha blend
            const dst = self.pixels[idx];
            const da = @as(u32, a);
            const ia = 255 - da;
            const dr = ((dst >> 16) & 0xFF) * ia / 255 + @as(u32, r) * da / 255;
            const dg = ((dst >> 8) & 0xFF) * ia / 255 + @as(u32, g) * da / 255;
            const db = (dst & 0xFF) * ia / 255 + @as(u32, b) * da / 255;
            self.pixels[idx] = 0xFF000000 | (dr << 16) | (dg << 8) | db;
        }
    }

    /// Render terminal content into the SHM buffer using freetype.
    pub fn renderTerminal(
        self: *ShmFrame,
        term: *terminal_mod.Terminal,
        font_data: []const u8,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
        default_fg: Rgb,
        default_bg: Rgb,
    ) void {
        // Init freetype
        var library: ft2.FT_Library = null;
        if (ft2.FT_Init_FreeType(&library) != 0) return;
        defer _ = ft2.FT_Done_FreeType(library);

        var face: ft2.FT_Face = null;
        if (ft2.FT_New_Memory_Face(library, font_data.ptr, @intCast(font_data.len), 0, &face) != 0) return;
        defer _ = ft2.FT_Done_Face(face);

        _ = ft2.FT_Set_Pixel_Sizes(face, 0, @intFromFloat(font_size));

        // Fill background
        self.fill(default_bg);

        // Iterate terminal cells
        term.updateRenderState() catch return;

        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            term.beginCellIteration();
            var col_idx: u16 = 0;
            while (term.nextCell()) : (col_idx += 1) {
                const cell = term.getCellInfo();
                if (!cell.has_text or cell.codepoint <= 0x20 or cell.codepoint >= 0x110000) continue;

                var fg = cell.fg orelse default_fg;
                if (cell.style.inverse != false) {
                    fg = cell.bg orelse default_bg;
                }

                // Load and render glyph
                const glyph_index = ft2.FT_Get_Char_Index(face, cell.codepoint);
                if (glyph_index == 0) continue;

                if (ft2.FT_Load_Glyph(face, glyph_index, ft2.FT_LOAD_RENDER) != 0) continue;

                const glyph = face.*.glyph;
                const bitmap = glyph.*.bitmap;
                if (bitmap.buffer == null) continue;

                // Position: cell top-left + glyph bearing
                const cell_x = @as(i32, col_idx) * @as(i32, @intFromFloat(cell_width));
                const cell_y = @as(i32, row_idx) * @as(i32, @intFromFloat(cell_height));
                const baseline_y = cell_y + @as(i32, @intFromFloat(cell_height * 0.8));
                const gx = cell_x + glyph.*.bitmap_left;
                const gy = baseline_y - glyph.*.bitmap_top;

                // Blit glyph bitmap
                for (0..bitmap.rows) |by| {
                    for (0..bitmap.width) |bx| {
                        const alpha = bitmap.buffer[by * @as(usize, @intCast(bitmap.pitch)) + bx];
                        if (alpha == 0) continue;
                        const px = gx + @as(i32, @intCast(bx));
                        const py = gy + @as(i32, @intCast(by));
                        if (px >= 0 and py >= 0) {
                            self.putPixel(@intCast(px), @intCast(py), fg.r, fg.g, fg.b, alpha);
                        }
                    }
                }
            }
        }

        term.resetDirty();
    }

    pub fn commit(self: *ShmFrame, surface_opaque: *anyopaque, display_opaque: *anyopaque) void {
        const surface: *wl.wl_surface = @ptrCast(surface_opaque);
        const display: *wl.wl_display = @ptrCast(display_opaque);
        wl.wl_surface_attach(surface, self.buffer, 0, 0);
        wl.wl_surface_damage_buffer(surface, 0, 0, @intCast(self.width), @intCast(self.height));
        wl.wl_surface_commit(surface);
        _ = wl.wl_display_flush(display);
    }
};
