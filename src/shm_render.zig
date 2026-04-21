//! SHM first-frame rendering using snail's CPU rasterizer.
//! Same Bézier curve quality as the GPU path, evaluated per-pixel on CPU.
//! Renders directly into a Wayland SHM buffer (zero-copy).

const std = @import("std");
const snail = @import("snail");
const cpu_renderer = @import("cpu_renderer");
const terminal_mod = @import("terminal.zig");
const color = @import("color.zig");
const Rgb = color.Rgb;

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

const wl = @cImport(@cInclude("wayland-client.h"));

pub const ShmFrame = struct {
    renderer: cpu_renderer.CpuRenderer,
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
            pool, 0, @intCast(w), @intCast(h), @intCast(stride),
            wl.WL_SHM_FORMAT_ARGB8888,
        ) orelse {
            wl.wl_shm_pool_destroy(pool);
            _ = c.munmap(map, size);
            _ = c.close(fd);
            return null;
        };

        return .{
            .renderer = cpu_renderer.CpuRenderer.init(@ptrCast(map), w, h, stride),
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
    ) void {
        self.renderer.clear(default_bg.r, default_bg.g, default_bg.b, 255);

        term.updateRenderState() catch return;

        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            term.beginCellIteration();
            var col_idx: u16 = 0;
            while (term.nextCell()) : (col_idx += 1) {
                const cell = term.getCellInfo();

                var fg = cell.fg orelse default_fg;
                var cell_bg = cell.bg;
                if (cell.style.inverse != false) {
                    const tmp = fg;
                    fg = cell_bg orelse default_bg;
                    cell_bg = tmp;
                }

                // Background
                if (cell_bg) |cbg| {
                    self.renderer.fillRect(
                        @intFromFloat(@as(f32, @floatFromInt(col_idx)) * cell_width),
                        @intFromFloat(@as(f32, @floatFromInt(row_idx)) * cell_height),
                        @intFromFloat(cell_width),
                        @intFromFloat(cell_height),
                        cbg.r, cbg.g, cbg.b, 255,
                    );
                }

                // Text
                if (cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000) {
                    const x = @as(f32, @floatFromInt(col_idx)) * cell_width;
                    const y = @as(f32, @floatFromInt(row_idx)) * cell_height + cell_height * 0.8;
                    self.renderer.drawGlyph(
                        atlas, font, cell.codepoint,
                        x, y, font_size,
                        fg.toFloat4(1.0),
                    );
                }
            }
        }

        term.resetDirty();
    }

    pub fn commit(self: *ShmFrame, surface_opaque: *anyopaque, display_opaque: *anyopaque) void {
        const surface: *wl.wl_surface = @ptrCast(surface_opaque);
        const display: *wl.wl_display = @ptrCast(display_opaque);
        wl.wl_surface_attach(surface, self.wl_buffer, 0, 0);
        wl.wl_surface_damage_buffer(surface, 0, 0, @intCast(self.width), @intCast(self.height));
        wl.wl_surface_commit(surface);
        _ = wl.wl_display_flush(display);
    }
};
