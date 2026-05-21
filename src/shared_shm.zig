const std = @import("std");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

const wl = @cImport(@cInclude("wayland-client.h"));

pub const BufferDesc = extern struct {
    fd: c_int = -1,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    size: usize = 0,
};

pub const SharedBuffer = struct {
    desc: BufferDesc,
    map_ptr: ?*anyopaque,
    wl_pool: ?*wl.wl_shm_pool,
    wl_buffer: ?*wl.wl_buffer,
    released: bool = true,

    pub fn create(shm_opaque: *anyopaque, width: u32, height: u32) !SharedBuffer {
        const shm: *wl.wl_shm = @ptrCast(shm_opaque);
        const stride = width * 4;
        const size: usize = @as(usize, stride) * height;

        const fd = c.memfd_create("scrgo-cpu-shm", @as(c_uint, 0));
        if (fd < 0) return error.MemfdCreateFailed;
        errdefer _ = c.close(fd);

        if (c.ftruncate(fd, @intCast(size)) < 0) return error.TruncateFailed;

        const map = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (map == c.MAP_FAILED) return error.MmapFailed;
        errdefer _ = c.munmap(map, size);

        const pool = wl.wl_shm_create_pool(shm, fd, @intCast(size)) orelse return error.WlShmPoolFailed;
        errdefer wl.wl_shm_pool_destroy(pool);

        const buffer = wl.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            wl.WL_SHM_FORMAT_ABGR8888,
        ) orelse return error.WlBufferCreateFailed;

        return .{
            .desc = .{
                .fd = fd,
                .width = width,
                .height = height,
                .stride = stride,
                .size = size,
            },
            .map_ptr = map,
            .wl_pool = pool,
            .wl_buffer = buffer,
            .released = true,
        };
    }

    pub fn attachListener(self: *SharedBuffer) void {
        _ = wl.wl_buffer_add_listener(self.wl_buffer, &buffer_listener, @ptrCast(self));
    }

    pub fn destroy(self: *SharedBuffer) void {
        if (self.wl_buffer) |buffer| wl.wl_buffer_destroy(buffer);
        if (self.wl_pool) |pool| wl.wl_shm_pool_destroy(pool);
        if (self.map_ptr) |map_ptr| _ = c.munmap(map_ptr, self.desc.size);
        if (self.desc.fd >= 0) _ = c.close(self.desc.fd);
    }

    pub fn fillBackground(self: *SharedBuffer, r: u8, g: u8, b: u8) void {
        // Buffer is WL_SHM_FORMAT_ABGR8888 (little-endian bytes R, G, B, A)
        // to match snail's RGBA8888 output contract.
        const pixel: u32 = 0xff000000 | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
        const pixels: [*]u32 = @ptrCast(@alignCast(self.map_ptr.?));
        @memset(pixels[0 .. self.desc.width * self.desc.height], pixel);
    }

    pub fn commit(self: *SharedBuffer, surface_opaque: *anyopaque, display_opaque: *anyopaque) void {
        const surface: *wl.wl_surface = @ptrCast(surface_opaque);
        const display: *wl.wl_display = @ptrCast(display_opaque);

        wl.wl_surface_set_buffer_transform(surface, wl.WL_OUTPUT_TRANSFORM_NORMAL);
        wl.wl_surface_attach(surface, self.wl_buffer, 0, 0);
        wl.wl_surface_damage_buffer(surface, 0, 0, @intCast(self.desc.width), @intCast(self.desc.height));
        wl.wl_surface_commit(surface);
        _ = wl.wl_display_flush(display);
        self.released = false;
    }

    const buffer_listener = wl.wl_buffer_listener{
        .release = bufferRelease,
    };

    fn bufferRelease(data: ?*anyopaque, _: ?*wl.wl_buffer) callconv(.c) void {
        const self: *SharedBuffer = @ptrCast(@alignCast(data));
        self.released = true;
    }
};

pub const MappedBuffer = struct {
    desc: BufferDesc,
    map_ptr: ?*anyopaque,

    pub fn map(desc: BufferDesc) !MappedBuffer {
        const mapped = c.mmap(null, desc.size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, desc.fd, 0);
        if (mapped == c.MAP_FAILED) return error.MmapFailed;
        return .{
            .desc = desc,
            .map_ptr = mapped,
        };
    }

    pub fn destroy(self: *MappedBuffer) void {
        if (self.map_ptr) |map_ptr| _ = c.munmap(map_ptr, self.desc.size);
    }

    pub fn bytes(self: *MappedBuffer) []u8 {
        const ptr: [*]u8 = @ptrCast(self.map_ptr.?);
        return ptr[0..self.desc.size];
    }
};
