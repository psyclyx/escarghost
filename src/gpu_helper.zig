const std = @import("std");
const renderer_mod = @import("renderer.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const glyph_misses = @import("glyph_misses.zig");
const shared_dmabuf = @import("shared_dmabuf.zig");
const perf = @import("perf.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/socket.h");
    @cInclude("gbm.h");
    @cInclude("drm/drm_fourcc.h");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
});

pub const RequestTag = enum(u8) {
    render = 1,
    configure = 2,
    quit = 3,
};

pub const ResponseTag = enum(u8) {
    ready = 1,
    frame = 2,
    failed = 3,
    atlas_missing = 4,
};

pub const Request = extern struct {
    tag: RequestTag,
    buffer_index: u8 = 0,
    reserved: [2]u8 = [_]u8{0} ** 2,
    serial: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    font_size: f32 = 0,
    cell_width: f32 = 0,
    cell_height: f32 = 0,
};

pub const Response = extern struct {
    tag: ResponseTag,
    buffer_index: u8 = 0,
    reserved: [2]u8 = [_]u8{0} ** 2,
    serial: u32 = 0,
};

pub const ReadyPacket = struct {
    message: shared_dmabuf.ReadyMessage,
    fds: [shared_dmabuf.MaxBuffers]c_int = [_]c_int{-1} ** shared_dmabuf.MaxBuffers,
};

pub const AtlasMissing = struct {
    serial: u32 = 0,
    misses: glyph_misses.Set = .{},
};

const AtlasMissingPacket = extern struct {
    tag: ResponseTag,
    count: u8 = 0,
    reserved: [2]u8 = [_]u8{0} ** 2,
    serial: u32 = 0,
    codepoints: [glyph_misses.MaxCodepoints]u32 = [_]u32{0} ** glyph_misses.MaxCodepoints,

    fn fromSet(serial: u32, misses: *const glyph_misses.Set) AtlasMissingPacket {
        var packet: AtlasMissingPacket = .{
            .tag = .atlas_missing,
            .count = misses.count,
            .serial = serial,
        };
        @memcpy(packet.codepoints[0..misses.count], misses.codepoints[0..misses.count]);
        return packet;
    }

    fn toMissing(self: *const AtlasMissingPacket) AtlasMissing {
        var misses: glyph_misses.Set = .{};
        misses.count = @intCast(@min(self.count, glyph_misses.MaxCodepoints));
        @memcpy(misses.codepoints[0..misses.count], self.codepoints[0..misses.count]);
        return .{
            .serial = self.serial,
            .misses = misses,
        };
    }
};

pub const ReceivedResponse = union(enum) {
    ready: ReadyPacket,
    simple: Response,
    atlas_missing: AtlasMissing,
};

fn sendAllocatorReadyPacket(fd: c_int, allocator: *const DmabufAllocator) !void {
    var ready = ReadyPacket{
        .message = .{
            .tag = @intFromEnum(ResponseTag.ready),
            .buffer_count = @intCast(allocator.count),
        },
    };
    for (0..allocator.count) |i| {
        ready.message.buffers[i] = allocator.targets[i].desc;
        ready.fds[i] = allocator.targets[i].export_fd;
    }
    try sendReadyPacket(fd, ready);
}

fn closeAllocatorExportFds(allocator: *DmabufAllocator) void {
    for (0..allocator.count) |i| {
        if (allocator.targets[i].export_fd >= 0) {
            _ = c.close(allocator.targets[i].export_fd);
            allocator.targets[i].export_fd = -1;
        }
    }
}

fn rendererDebugOptions() render_env.RendererDebug {
    if (c.getenv("MOLLUSK_LOG")) |value|
        return render_env.parseRendererDebug(std.mem.sliceTo(value, 0));
    return .{};
}

fn rendererDebugEnabled() bool {
    return rendererDebugOptions().renderers;
}

fn gpuDebug(timer: perf.Timer, comptime fmt: []const u8, args: anytype) void {
    if (!rendererDebugEnabled()) return;
    std.debug.print("mollusk[gpu-renderer:{}] {d:.1}ms: " ++ fmt ++ "\n", .{ c.getpid(), timer.elapsedMs() } ++ args);
}

fn cmsgAlign(len: usize) usize {
    const alignment = @sizeOf(usize);
    const remainder = len % alignment;
    return if (remainder == 0) len else len + alignment - remainder;
}

const control_payload_bytes = @sizeOf(c_int) * shared_dmabuf.MaxBuffers;
const control_storage_bytes = cmsgAlign(@sizeOf(c.struct_cmsghdr)) + cmsgAlign(control_payload_bytes);
const drm_format_mod_invalid: u64 = (1 << 56) - 1;

const OffscreenEgl = struct {
    display: c.EGLDisplay = c.EGL_NO_DISPLAY,
    context: c.EGLContext = c.EGL_NO_CONTEXT,
    surface: c.EGLSurface = c.EGL_NO_SURFACE,
    config: c.EGLConfig = null,
    create_image: ?*const fn (c.EGLDisplay, c.EGLContext, c.EGLenum, c.EGLClientBuffer, ?[*]const c.EGLint) callconv(.c) c.EGLImage = null,
    destroy_image: ?*const fn (c.EGLDisplay, c.EGLImage) callconv(.c) c.EGLBoolean = null,
    image_target_texture: ?*const fn (c.GLenum, c.GLeglImageOES) callconv(.c) void = null,
    pub fn init() !OffscreenEgl {
        const timer = perf.Timer.now();
        var self: OffscreenEgl = .{};
        gpuDebug(timer, "egl init start", .{});

        const get_platform_display = @as(
            ?*const fn (c.EGLenum, ?*anyopaque, ?[*]const c.EGLAttrib) callconv(.c) c.EGLDisplay,
            @ptrCast(c.eglGetProcAddress("eglGetPlatformDisplay")),
        ) orelse return error.SurfacelessUnsupported;
        self.display = get_platform_display(c.EGL_PLATFORM_SURFACELESS_MESA, null, null);
        if (self.display == c.EGL_NO_DISPLAY) return error.EglDisplayFailed;
        errdefer self.deinit();

        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(self.display, &major, &minor) == c.EGL_FALSE)
            return error.EglInitFailed;
        gpuDebug(timer, "egl initialized {}.{}", .{ major, minor });
        if (c.eglQueryString(self.display, c.EGL_VENDOR)) |vendor|
            gpuDebug(timer, "egl vendor {s}", .{std.mem.sliceTo(vendor, 0)});
        _ = c.eglBindAPI(c.EGL_OPENGL_API);

        const attrs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_PBUFFER_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
            c.EGL_NONE,
        };

        var num: c.EGLint = 0;
        if (c.eglChooseConfig(self.display, &attrs, &self.config, 1, &num) == c.EGL_FALSE or num == 0)
            return error.EglConfigFailed;
        gpuDebug(timer, "egl config chosen", .{});

        const gl44 = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION,       4,
            c.EGL_CONTEXT_MINOR_VERSION,       4,
            c.EGL_CONTEXT_OPENGL_PROFILE_MASK, c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            c.EGL_NONE,
        };
        const gl33 = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION,       3,
            c.EGL_CONTEXT_MINOR_VERSION,       3,
            c.EGL_CONTEXT_OPENGL_PROFILE_MASK, c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            c.EGL_NONE,
        };

        self.context = c.eglCreateContext(self.display, self.config, c.EGL_NO_CONTEXT, &gl44);
        if (self.context == c.EGL_NO_CONTEXT) {
            self.context = c.eglCreateContext(self.display, self.config, c.EGL_NO_CONTEXT, &gl33);
        }
        if (self.context == c.EGL_NO_CONTEXT) return error.EglContextFailed;
        gpuDebug(timer, "egl context created", .{});

        const pbuffer_attrs = [_]c.EGLint{
            c.EGL_WIDTH,  1,
            c.EGL_HEIGHT, 1,
            c.EGL_NONE,
        };
        self.surface = c.eglCreatePbufferSurface(self.display, self.config, &pbuffer_attrs);
        if (self.surface == c.EGL_NO_SURFACE) return error.EglSurfaceFailed;
        gpuDebug(timer, "pbuffer created", .{});

        if (c.eglMakeCurrent(self.display, self.surface, self.surface, self.context) == c.EGL_FALSE)
            return error.EglMakeCurrentFailed;
        gpuDebug(timer, "egl current", .{});

        self.create_image = @ptrCast(c.eglGetProcAddress("eglCreateImageKHR"));
        self.destroy_image = @ptrCast(c.eglGetProcAddress("eglDestroyImageKHR"));
        self.image_target_texture = @ptrCast(c.eglGetProcAddress("glEGLImageTargetTexture2DOES"));
        if (self.create_image == null or self.destroy_image == null or self.image_target_texture == null)
            return error.EglImageUnsupported;

        _ = c.eglSwapInterval(self.display, 0);
        return self;
    }

    pub fn deinit(self: *OffscreenEgl) void {
        if (self.display != c.EGL_NO_DISPLAY) {
            _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
            if (self.surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(self.display, self.surface);
            if (self.context != c.EGL_NO_CONTEXT) _ = c.eglDestroyContext(self.display, self.context);
            _ = c.eglTerminate(self.display);
        }
    }
};

const DmabufTarget = struct {
    desc: shared_dmabuf.BufferDesc = .{},
    bo: ?*c.struct_gbm_bo = null,
    import_fd: c_int = -1,
    export_fd: c_int = -1,
    image: c.EGLImage = c.EGL_NO_IMAGE,
    texture: c.GLuint = 0,
    framebuffer: c.GLuint = 0,

    const AllocationCandidate = struct {
        format: u32,
        usage: u32,
        name: []const u8,
    };

    fn init(egl: *const OffscreenEgl, gbm: *c.struct_gbm_device, width: u32, height: u32) !DmabufTarget {
        var self: DmabufTarget = .{};
        errdefer self.deinit(egl);

        const candidates = [_]AllocationCandidate{
            .{
                .format = c.DRM_FORMAT_ABGR8888,
                .usage = c.GBM_BO_USE_RENDERING | c.GBM_BO_USE_LINEAR,
                .name = "ABGR8888 render|linear",
            },
            .{
                .format = c.DRM_FORMAT_ABGR8888,
                .usage = c.GBM_BO_USE_RENDERING,
                .name = "ABGR8888 render",
            },
            .{
                .format = c.DRM_FORMAT_XBGR8888,
                .usage = c.GBM_BO_USE_RENDERING | c.GBM_BO_USE_LINEAR,
                .name = "XBGR8888 render|linear",
            },
            .{
                .format = c.DRM_FORMAT_XBGR8888,
                .usage = c.GBM_BO_USE_RENDERING,
                .name = "XBGR8888 render",
            },
            .{
                .format = c.DRM_FORMAT_ARGB8888,
                .usage = c.GBM_BO_USE_RENDERING | c.GBM_BO_USE_LINEAR,
                .name = "ARGB8888 render|linear",
            },
            .{
                .format = c.DRM_FORMAT_ARGB8888,
                .usage = c.GBM_BO_USE_RENDERING,
                .name = "ARGB8888 render",
            },
            .{
                .format = c.DRM_FORMAT_XRGB8888,
                .usage = c.GBM_BO_USE_RENDERING | c.GBM_BO_USE_LINEAR,
                .name = "XRGB8888 render|linear",
            },
            .{
                .format = c.DRM_FORMAT_XRGB8888,
                .usage = c.GBM_BO_USE_RENDERING,
                .name = "XRGB8888 render",
            },
        };

        var chosen_format: u32 = 0;
        for (candidates) |candidate| {
            const supported = c.gbm_device_is_format_supported(gbm, candidate.format, candidate.usage) != 0;
            if (rendererDebugEnabled()) {
                std.debug.print(
                    "mollusk[gpu-renderer:{}] trying dmabuf candidate {s} supported={}\n",
                    .{ c.getpid(), candidate.name, supported },
                );
            }
            self.bo = c.gbm_bo_create(gbm, width, height, candidate.format, candidate.usage);
            if (self.bo != null) {
                chosen_format = candidate.format;
                if (rendererDebugEnabled()) {
                    std.debug.print(
                        "mollusk[gpu-renderer:{}] selected dmabuf candidate {s}\n",
                        .{ c.getpid(), candidate.name },
                    );
                }
                break;
            }
        }
        if (self.bo == null) return error.GbmCreateFailed;

        const modifier = c.gbm_bo_get_modifier(self.bo);
        self.desc = .{
            .width = width,
            .height = height,
            .stride = c.gbm_bo_get_stride(self.bo),
            .offset = 0,
            .format = chosen_format,
            .modifier_hi = @truncate(modifier >> 32),
            .modifier_lo = @truncate(modifier),
        };

        self.export_fd = c.gbm_bo_get_fd(self.bo);
        if (self.export_fd < 0) return error.GbmExportFailed;
        self.import_fd = c.gbm_bo_get_fd(self.bo);
        if (self.import_fd < 0) return error.GbmImportDupFailed;

        const use_modifiers = modifier != drm_format_mod_invalid;
        const attrs_with_modifiers = [_]c.EGLint{
            c.EGL_WIDTH,                          @intCast(width),
            c.EGL_HEIGHT,                         @intCast(height),
            c.EGL_LINUX_DRM_FOURCC_EXT,           @intCast(self.desc.format),
            c.EGL_DMA_BUF_PLANE0_FD_EXT,          self.import_fd,
            c.EGL_DMA_BUF_PLANE0_OFFSET_EXT,      @intCast(self.desc.offset),
            c.EGL_DMA_BUF_PLANE0_PITCH_EXT,       @intCast(self.desc.stride),
            c.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, @intCast(self.desc.modifier_lo),
            c.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, @intCast(self.desc.modifier_hi),
            c.EGL_NONE,
        };
        const attrs_without_modifiers = [_]c.EGLint{
            c.EGL_WIDTH,                     @intCast(width),
            c.EGL_HEIGHT,                    @intCast(height),
            c.EGL_LINUX_DRM_FOURCC_EXT,      @intCast(self.desc.format),
            c.EGL_DMA_BUF_PLANE0_FD_EXT,     self.import_fd,
            c.EGL_DMA_BUF_PLANE0_OFFSET_EXT, @intCast(self.desc.offset),
            c.EGL_DMA_BUF_PLANE0_PITCH_EXT,  @intCast(self.desc.stride),
            c.EGL_NONE,
        };
        const attrs: []const c.EGLint = if (use_modifiers)
            attrs_with_modifiers[0..]
        else
            attrs_without_modifiers[0..];
        self.image = egl.create_image.?(
            egl.display,
            c.EGL_NO_CONTEXT,
            c.EGL_LINUX_DMA_BUF_EXT,
            null,
            attrs.ptr,
        );
        if (self.image == c.EGL_NO_IMAGE) return error.EglImageCreateFailed;

        c.glGenTextures(1, &self.texture);
        c.glBindTexture(c.GL_TEXTURE_2D, self.texture);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        egl.image_target_texture.?(c.GL_TEXTURE_2D, @ptrCast(self.image));

        c.glGenFramebuffers(1, &self.framebuffer);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.texture, 0);
        if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE)
            return error.FramebufferIncomplete;

        return self;
    }

    fn deinit(self: *DmabufTarget, egl: *const OffscreenEgl) void {
        if (self.framebuffer != 0) c.glDeleteFramebuffers(1, &self.framebuffer);
        if (self.texture != 0) c.glDeleteTextures(1, &self.texture);
        if (self.image != c.EGL_NO_IMAGE and egl.destroy_image != null)
            _ = egl.destroy_image.?(egl.display, self.image);
        if (self.import_fd >= 0) _ = c.close(self.import_fd);
        if (self.export_fd >= 0) _ = c.close(self.export_fd);
        if (self.bo) |bo| c.gbm_bo_destroy(bo);
    }
};

const DmabufAllocator = struct {
    render_fd: c_int = -1,
    gbm: ?*c.struct_gbm_device = null,
    targets: [shared_dmabuf.MaxBuffers]DmabufTarget = [_]DmabufTarget{.{}} ** shared_dmabuf.MaxBuffers,
    count: usize = 0,

    fn init(egl: *const OffscreenEgl, width: u32, height: u32, buffer_count: usize) !DmabufAllocator {
        var self: DmabufAllocator = .{};
        errdefer self.deinit(egl);

        self.render_fd = try openRenderNodeForEgl(egl);
        self.gbm = c.gbm_create_device(self.render_fd) orelse return error.GbmDeviceFailed;

        const clamped_count = @min(buffer_count, shared_dmabuf.MaxBuffers);
        for (0..clamped_count) |i| {
            self.targets[i] = try DmabufTarget.init(egl, self.gbm.?, width, height);
            self.count += 1;
        }
        return self;
    }

    fn deinit(self: *DmabufAllocator, egl: *const OffscreenEgl) void {
        for (self.targets[0..self.count]) |*target| target.deinit(egl);
        if (self.gbm) |gbm| c.gbm_device_destroy(gbm);
        if (self.render_fd >= 0) _ = c.close(self.render_fd);
    }
};

pub fn run(
    control_fd: c_int,
    renderer: *renderer_mod.Renderer,
    snapshot: *const render_snapshot.SharedSnapshot,
    buffer_count: usize,
) noreturn {
    const timer = perf.Timer.now();
    gpuDebug(timer, "process start control_fd={} buffers={}", .{ control_fd, buffer_count });
    sanitizeChildProcess(control_fd);
    gpuDebug(timer, "child sanitized", .{});

    var egl = OffscreenEgl.init() catch {
        gpuDebug(timer, "egl init failed", .{});
        writeSimpleResponse(control_fd, .{ .tag = .failed });
        c._exit(1);
    };
    defer egl.deinit();
    gpuDebug(timer, "offscreen egl ready", .{});

    const runtime_flags = render_env.parseRuntimeFlags(if (c.getenv("MOLLUSK_FLAGS")) |value| std.mem.sliceTo(value, 0) else null);
    renderer.setDebugLogs(rendererDebugOptions());
    renderer.setDebugResetAtlas(runtime_flags.reset_atlas_each_frame);
    renderer.initGpu() catch {
        gpuDebug(timer, "renderer gpu init failed", .{});
        writeSimpleResponse(control_fd, .{ .tag = .failed });
        c._exit(1);
    };
    renderer.ensureDrawBuffers() catch {
        gpuDebug(timer, "renderer buffer init failed", .{});
        writeSimpleResponse(control_fd, .{ .tag = .failed });
        c._exit(1);
    };
    renderer.framebuffer_srgb = false;
    c.glDisable(c.GL_FRAMEBUFFER_SRGB);
    gpuDebug(timer, "renderer gpu initialized", .{});

    var allocator: ?DmabufAllocator = null;
    defer if (allocator) |*existing| existing.deinit(&egl);
    var current_width: u32 = 0;
    var current_height: u32 = 0;

    while (true) {
        const req = readMessage(control_fd, Request) catch {
            c._exit(0);
        } orelse c._exit(0);

        switch (req.tag) {
            .quit => c._exit(0),
            .configure => {
                const reconfigure_timer = perf.Timer.now();
                gpuDebug(timer, "configure request {}x{} font={d:.1} cell={d:.1}x{d:.1}", .{
                    req.width,
                    req.height,
                    req.font_size,
                    req.cell_width,
                    req.cell_height,
                });

                const next_allocator = DmabufAllocator.init(&egl, req.width, req.height, buffer_count) catch |err| {
                    gpuDebug(timer, "dmabuf reconfigure failed: {}", .{err});
                    writeSimpleResponse(control_fd, .{ .tag = .failed });
                    c._exit(1);
                };

                if (allocator) |*existing| existing.deinit(&egl);
                allocator = next_allocator;
                current_width = req.width;
                current_height = req.height;
                renderer.reconfigure(req.width, req.height, req.font_size, req.cell_width, req.cell_height);

                sendAllocatorReadyPacket(control_fd, &allocator.?) catch {
                    c._exit(1);
                };
                closeAllocatorExportFds(&allocator.?);
                gpuDebug(timer, "reconfigure ready sent in {d:.1}ms", .{reconfigure_timer.elapsedMs()});
            },
            .render => {
                if (allocator == null) continue;
                const active_allocator = &allocator.?;
                if (req.buffer_index >= active_allocator.count) continue;
                const render_timer = perf.Timer.now();
                gpuDebug(timer, "render request buffer={} cells={}", .{
                    req.buffer_index,
                    snapshot.header.cell_count,
                });

                const target = &active_allocator.targets[req.buffer_index];
                c.glBindFramebuffer(c.GL_FRAMEBUFFER, target.framebuffer);
                c.glViewport(0, 0, @intCast(current_width), @intCast(current_height));
                var misses: glyph_misses.Set = .{};
                renderer.drawSnapshot(snapshot, &misses) catch continue;
                if (!misses.isEmpty()) {
                    if (rendererDebugOptions().atlas or rendererDebugEnabled()) {
                        std.debug.print("mollusk[gpu-renderer:{}] atlas missing count={} serial={}\n", .{
                            c.getpid(),
                            misses.count,
                            req.serial,
                        });
                    }
                    writeAtlasMissingResponse(control_fd, req.serial, &misses);
                    continue;
                }
                c.glFlush();

                gpuDebug(timer, "render complete buffer={} in {d:.1}ms", .{
                    req.buffer_index,
                    render_timer.elapsedMs(),
                });
                writeSimpleResponse(control_fd, .{
                    .tag = .frame,
                    .buffer_index = req.buffer_index,
                    .serial = req.serial,
                });
            },
        }
    }
}

pub fn writeRequest(fd: c_int, request: Request) !void {
    try writeAll(fd, @as([*]const u8, @ptrCast(&request))[0..@sizeOf(Request)]);
}

pub fn readResponse(fd: c_int) !?ReceivedResponse {
    const max_payload_size = comptime @max(
        @max(@sizeOf(shared_dmabuf.ReadyMessage), @sizeOf(Response)),
        @sizeOf(AtlasMissingPacket),
    );
    var payload: [max_payload_size]u8 = undefined;
    var control: [control_storage_bytes]u8 align(@alignOf(usize)) = [_]u8{0} ** control_storage_bytes;
    var iov = c.struct_iovec{
        .iov_base = &payload,
        .iov_len = payload.len,
    };
    var msg: c.struct_msghdr = std.mem.zeroInit(c.struct_msghdr, .{});
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = &control;
    msg.msg_controllen = control.len;

    const rc = c.recvmsg(fd, &msg, 0);
    if (rc == 0) return null;
    if (rc < 0) return error.ReadFailed;

    const tag: ResponseTag = @enumFromInt(payload[0]);
    switch (tag) {
        .ready => {
            if (@as(usize, @intCast(rc)) < @sizeOf(shared_dmabuf.ReadyMessage))
                return error.ShortRead;

            const message: shared_dmabuf.ReadyMessage = @bitCast(payload[0..@sizeOf(shared_dmabuf.ReadyMessage)].*);
            var ready = ReadyPacket{ .message = message };

            const header_len = cmsgAlign(@sizeOf(c.struct_cmsghdr));
            if (msg.msg_controllen >= header_len + @sizeOf(c_int)) {
                const header: *const c.struct_cmsghdr = @ptrCast(@alignCast(&control));
                if (header.cmsg_level == c.SOL_SOCKET and header.cmsg_type == c.SCM_RIGHTS and header.cmsg_len >= header_len) {
                    const fd_count = @min(
                        @as(usize, @intCast((header.cmsg_len - header_len) / @sizeOf(c_int))),
                        shared_dmabuf.MaxBuffers,
                    );
                    const fds: [*]const c_int = @ptrCast(@alignCast(control[header_len..].ptr));
                    for (0..fd_count) |i| ready.fds[i] = fds[i];
                }
            }

            return .{ .ready = ready };
        },
        .frame, .failed => {
            if (@as(usize, @intCast(rc)) < @sizeOf(Response))
                return error.ShortRead;
            const response: Response = @bitCast(payload[0..@sizeOf(Response)].*);
            return .{ .simple = response };
        },
        .atlas_missing => {
            if (@as(usize, @intCast(rc)) < @sizeOf(AtlasMissingPacket))
                return error.ShortRead;
            const packet: AtlasMissingPacket = @bitCast(payload[0..@sizeOf(AtlasMissingPacket)].*);
            return .{ .atlas_missing = packet.toMissing() };
        },
    }
}

fn readMessage(fd: c_int, comptime T: type) !?T {
    var value: T = undefined;
    var offset: usize = 0;

    while (offset < @sizeOf(T)) {
        const rc = c.read(fd, @as([*]u8, @ptrCast(&value)) + offset, @sizeOf(T) - offset);
        if (rc == 0) return null;
        if (rc < 0) return error.ReadFailed;
        offset += @intCast(rc);
    }

    return value;
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc <= 0) return error.WriteFailed;
        offset += @intCast(rc);
    }
}

fn writeSimpleResponse(fd: c_int, response: Response) void {
    const bytes = @as([*]const u8, @ptrCast(&response))[0..@sizeOf(Response)];
    _ = sendPacket(fd, bytes, null) catch {};
}

fn writeAtlasMissingResponse(fd: c_int, serial: u32, misses: *const glyph_misses.Set) void {
    const packet = AtlasMissingPacket.fromSet(serial, misses);
    const bytes = @as([*]const u8, @ptrCast(&packet))[0..@sizeOf(AtlasMissingPacket)];
    _ = sendPacket(fd, bytes, null) catch {};
}

fn sendReadyPacket(fd: c_int, ready: ReadyPacket) !void {
    var local_ready = ready;
    const bytes = @as([*]const u8, @ptrCast(&local_ready.message))[0..@sizeOf(shared_dmabuf.ReadyMessage)];
    try sendPacket(fd, bytes, local_ready.fds[0..@min(@as(usize, local_ready.message.buffer_count), shared_dmabuf.MaxBuffers)]);
}

fn sendPacket(fd: c_int, bytes: []const u8, fds_opt: ?[]const c_int) !void {
    var iov = c.struct_iovec{
        .iov_base = @constCast(bytes.ptr),
        .iov_len = bytes.len,
    };
    var msg: c.struct_msghdr = std.mem.zeroInit(c.struct_msghdr, .{});
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    var control: [control_storage_bytes]u8 align(@alignOf(usize)) = [_]u8{0} ** control_storage_bytes;
    if (fds_opt) |fds| {
        const header_len = cmsgAlign(@sizeOf(c.struct_cmsghdr));
        const payload_len = @sizeOf(c_int) * fds.len;
        const header: *c.struct_cmsghdr = @ptrCast(@alignCast(&control));
        header.cmsg_level = c.SOL_SOCKET;
        header.cmsg_type = c.SCM_RIGHTS;
        header.cmsg_len = header_len + payload_len;

        const dst: [*]u8 = control[header_len..].ptr;
        @memcpy(dst[0..payload_len], std.mem.sliceAsBytes(fds));
        msg.msg_control = &control;
        msg.msg_controllen = header_len + cmsgAlign(payload_len);
    }

    if (c.sendmsg(fd, &msg, 0) < 0) return error.WriteFailed;
}

fn openRenderNodeAt(path_z: [*:0]const u8) !c_int {
    const fd = c.open(path_z, c.O_RDWR | c.O_CLOEXEC);
    if (fd >= 0) return fd;
    return error.OpenRenderNodeFailed;
}

fn openRenderNode() !c_int {
    var path_buf: [32]u8 = undefined;
    var node: u32 = 128;
    while (node < 192) : (node += 1) {
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/dri/renderD{}", .{node}) catch continue;
        const fd = c.open(path.ptr, c.O_RDWR | c.O_CLOEXEC);
        if (fd >= 0) return fd;
    }
    return error.NoRenderNode;
}

fn openRenderNodeForEgl(egl: *const OffscreenEgl) !c_int {
    const query_display_attrib = @as(
        ?*const fn (c.EGLDisplay, c.EGLint, *c.EGLAttrib) callconv(.c) c.EGLBoolean,
        @ptrCast(c.eglGetProcAddress("eglQueryDisplayAttribEXT")),
    );
    const query_device_string = @as(
        ?*const fn (c.EGLDeviceEXT, c.EGLint) callconv(.c) [*c]const u8,
        @ptrCast(c.eglGetProcAddress("eglQueryDeviceStringEXT")),
    );

    if (query_display_attrib) |query_attrib| {
        if (query_device_string) |query_string| {
            var device_attr: c.EGLAttrib = 0;
            if (query_attrib(egl.display, c.EGL_DEVICE_EXT, &device_attr) != c.EGL_FALSE and device_attr != 0) {
                const device: c.EGLDeviceEXT = @ptrFromInt(@as(usize, @intCast(device_attr)));
                const render_node = query_string(device, c.EGL_DRM_RENDER_NODE_FILE_EXT);
                if (render_node != null) {
                    if (rendererDebugEnabled()) {
                        std.debug.print("mollusk[gpu-renderer:{}] render node from EGL: {s}\n", .{ c.getpid(), std.mem.sliceTo(render_node, 0) });
                    }
                    if (openRenderNodeAt(render_node)) |fd| return fd else |_| {}
                }
            }
        }
    }

    if (rendererDebugEnabled()) {
        std.debug.print("mollusk[gpu-renderer:{}] render node fallback scan\n", .{c.getpid()});
    }
    return openRenderNode();
}

fn sanitizeChildProcess(control_fd: c_int) void {
    _ = c.unsetenv("WAYLAND_DISPLAY");
    _ = c.unsetenv("WAYLAND_SOCKET");
    _ = c.unsetenv("DISPLAY");
    _ = c.setenv("EGL_PLATFORM", "surfaceless", 1);
    if (rendererDebugEnabled()) {
        _ = c.setenv("__NV_GBM_TRACE_ENABLED", "1", 1);
    }

    var lim: c.struct_rlimit = undefined;
    if (c.getrlimit(c.RLIMIT_NOFILE, &lim) != 0) return;

    const max_fd: c_int = @intCast(@min(lim.rlim_cur, 4096));
    var fd: c_int = 3;
    while (fd < max_fd) : (fd += 1) {
        if (fd == control_fd) continue;
        _ = c.close(fd);
    }
}
