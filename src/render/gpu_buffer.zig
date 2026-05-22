const std = @import("std");

const c = @cImport({
    @cInclude("unistd.h");
});

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("linux-dmabuf-unstable-v1-client-protocol.h");
    @cInclude("drm/drm_fourcc.h");
});

pub const BufferDesc = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    offset: u32 = 0,
    format: u32 = wl.DRM_FORMAT_ARGB8888,
    modifier_hi: u32 = 0,
    modifier_lo: u32 = 0,
};

// Triple-buffered: at steady state the compositor holds one buffer for
// scanout, we just attached the second, and the third is free for the
// next render. With only two, the GPU stalls each frame waiting for the
// compositor to release the buffer it's still reading — every render is
// gated to vsync via implicit dma-fence sync, which adds ~10ms per frame
// of fence-wait time.
pub const MaxBuffers = 3;

pub const FrontendBuffer = struct {
    desc: BufferDesc,
    wl_buffer: ?*wl.wl_buffer,
    released: bool = true,

    pub fn create(dmabuf_opaque: *anyopaque, fd: c_int, desc: BufferDesc) !FrontendBuffer {
        const dmabuf: *wl.zwp_linux_dmabuf_v1 = @ptrCast(dmabuf_opaque);
        const params = wl.zwp_linux_dmabuf_v1_create_params(dmabuf) orelse return error.BufferParamsFailed;
        defer wl.zwp_linux_buffer_params_v1_destroy(params);

        wl.zwp_linux_buffer_params_v1_add(
            params,
            fd,
            0,
            @intCast(desc.offset),
            @intCast(desc.stride),
            @intCast(desc.modifier_hi),
            @intCast(desc.modifier_lo),
        );

        const buffer = wl.zwp_linux_buffer_params_v1_create_immed(
            params,
            @intCast(desc.width),
            @intCast(desc.height),
            desc.format,
            0,
        ) orelse return error.WlBufferCreateFailed;
        _ = c.close(fd);

        return .{
            .desc = desc,
            .wl_buffer = buffer,
            .released = true,
        };
    }

    pub fn attachListener(self: *FrontendBuffer) void {
        _ = wl.wl_buffer_add_listener(self.wl_buffer, &buffer_listener, @ptrCast(self));
    }

    pub fn destroy(self: *FrontendBuffer) void {
        if (self.wl_buffer) |buffer| wl.wl_buffer_destroy(buffer);
        self.wl_buffer = null;
        self.released = true;
    }

    pub fn commit(self: *FrontendBuffer, surface_opaque: *anyopaque, display_opaque: *anyopaque) void {
        const surface: *wl.wl_surface = @ptrCast(surface_opaque);
        const display: *wl.wl_display = @ptrCast(display_opaque);

        // GBM/GL writes rows in the opposite orientation for Wayland buffers.
        wl.wl_surface_set_buffer_transform(surface, wl.WL_OUTPUT_TRANSFORM_FLIPPED_180);
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
        const self: *FrontendBuffer = @ptrCast(@alignCast(data));
        self.released = true;
    }
};
