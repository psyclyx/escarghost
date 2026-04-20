//! OSMesa software GL backend for first-frame rendering.
//! Renders via llvmpipe directly into a memory buffer (zero-copy to wl_shm).
//! No interaction with NVIDIA/system GL — completely self-contained.

const std = @import("std");

const c = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/osmesa.h");
    @cInclude("GL/gl.h");
});

const wl = @cImport(@cInclude("wayland-client.h"));

const shm_c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

pub const OsMesaContext = struct {
    ctx: c.OSMesaContext,
    buffer: [*]u32,
    width: u32,
    height: u32,
    shm_fd: c_int,
    map_ptr: ?*anyopaque,
    map_size: usize,
    wl_pool: ?*wl.wl_shm_pool,
    wl_buffer: ?*wl.wl_buffer,

    /// Create an OSMesa context rendering directly into a Wayland SHM buffer.
    /// After init, GL is current — snail.Renderer.init() can be called immediately.
    pub fn init(shm: *anyopaque, width: u32, height: u32) !OsMesaContext {
        const stride = width * 4;
        const size: usize = @as(usize, stride) * height;

        // Create shared memory
        const fd = shm_c.memfd_create("mollusk-osmesa", @as(c_uint, 0));
        if (fd < 0) return error.MemfdFailed;
        errdefer _ = shm_c.close(fd);

        if (shm_c.ftruncate(fd, @intCast(size)) < 0) return error.TruncateFailed;

        const map = shm_c.mmap(null, size, shm_c.PROT_READ | shm_c.PROT_WRITE, shm_c.MAP_SHARED, fd, 0);
        if (map == shm_c.MAP_FAILED) return error.MmapFailed;
        errdefer _ = shm_c.munmap(map, size);

        // Create Wayland buffer from the SHM
        const shm_typed: *wl.wl_shm = @ptrCast(shm);
        const pool = wl.wl_shm_create_pool(shm_typed, fd, @intCast(size)) orelse return error.PoolFailed;
        errdefer wl.wl_shm_pool_destroy(pool);

        const buffer = wl.wl_shm_pool_create_buffer(
            pool, 0, @intCast(width), @intCast(height), @intCast(stride),
            wl.WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.BufferFailed;

        // Create OSMesa context (GL 3.3 core)
        const attribs = [_]c_int{
            c.OSMESA_FORMAT,          c.OSMESA_BGRA,
            c.OSMESA_PROFILE,         c.OSMESA_CORE_PROFILE,
            c.OSMESA_CONTEXT_MAJOR_VERSION, 3,
            c.OSMESA_CONTEXT_MINOR_VERSION, 3,
            0,
        };
        const ctx = c.OSMesaCreateContextAttribs(&attribs, null);
        if (ctx == null) return error.ContextFailed;
        errdefer c.OSMesaDestroyContext(ctx);

        // Make current — renders directly into the SHM buffer
        if (c.OSMesaMakeCurrent(ctx, @ptrCast(map), c.GL_UNSIGNED_BYTE, @intCast(width), @intCast(height)) == 0)
            return error.MakeCurrentFailed;

        return .{
            .ctx = ctx,
            .buffer = @ptrCast(@alignCast(map)),
            .width = width,
            .height = height,
            .shm_fd = fd,
            .map_ptr = map,
            .map_size = size,
            .wl_pool = pool,
            .wl_buffer = buffer,
        };
    }

    /// Commit the current frame to a Wayland surface.
    pub fn commit(self: *OsMesaContext, surface: *anyopaque, display: *anyopaque) void {
        const surf: *wl.wl_surface = @ptrCast(surface);
        const dpy: *wl.wl_display = @ptrCast(display);
        // Ensure GL is flushed
        c.glFinish();
        wl.wl_surface_attach(surf, self.wl_buffer, 0, 0);
        wl.wl_surface_damage_buffer(surf, 0, 0, @intCast(self.width), @intCast(self.height));
        wl.wl_surface_commit(surf);
        _ = wl.wl_display_flush(dpy);
    }

    /// Release GL context. Call before switching to hardware EGL.
    pub fn deinit(self: *OsMesaContext) void {
        c.OSMesaMakeCurrent(null, null, 0, 0, 0);
        c.OSMesaDestroyContext(self.ctx);
        if (self.wl_buffer) |b| wl.wl_buffer_destroy(b);
        if (self.wl_pool) |p| wl.wl_shm_pool_destroy(p);
        if (self.map_ptr) |m| _ = shm_c.munmap(m, self.map_size);
        _ = shm_c.close(self.shm_fd);
    }
};
