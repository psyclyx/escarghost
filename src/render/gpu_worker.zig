//! GPU renderer thread.
//!
//! Lifecycle:
//!   Phase 1 — EGL + snail.Renderer init (no deps, starts at T+0)
//!   Phase 2 — configure(width, height, metrics, font, atlas_ref)
//!             → allocate dmabufs, upload atlas, signal ready
//!   Phase 3 — render loop: snapshot → FBO → signal frame

const std = @import("std");
const snail = @import("snail");
const gpu_pipeline = @import("gpu_pipeline.zig");
const atlas_ref_mod = @import("atlas_ref.zig");
const atlas_worker = @import("atlas_worker.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const glyph_misses = @import("glyph_misses.zig");
const gpu_buffer = @import("gpu_buffer.zig");
const terminal_mod = @import("../terminal.zig");
const row_build = @import("row_build.zig");
const drm_sync = @import("drm_sync.zig");
const perf = @import("../perf.zig");
const log = @import("../log.zig");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("sys/eventfd.h");
    @cInclude("gbm.h");
    @cInclude("drm/drm_fourcc.h");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GLES3/gl3.h");
    @cInclude("GLES3/gl3ext.h");
    // GL_OES_EGL_image (`GLeglImageOES`, `glEGLImageTargetTexture2DOES`) is
    // declared in the GLES2 extension header; the GLES3 ext header doesn't
    // re-export it.
    @cInclude("GLES2/gl2ext.h");
});

fn parseTraceFromEnv() bool {
    if (c.getenv("SCRGO_TRACE")) |value|
        return render_env.parseTraceCommits(std.mem.sliceTo(value, 0));
    return false;
}

pub const MaxBuffers = gpu_buffer.MaxBuffers;
const SnapshotSlotCount = 2;

/// Cumulative time spent in `render_snapshot.prepare` on the main thread
/// (updateRenderState only). Dumped at exit (SCRGO_LOG=commits).
pub var snapshotPhaseAccumNs: u64 = 0;
pub var snapshotPhaseCount: u64 = 0;

/// Cumulative time spent in `render_snapshot.captureCells` on the worker
/// thread. Off the main thread's critical path; tracked so we can see
/// how much wall time we saved by offloading.
pub var captureCellsAccumNs: u64 = 0;
pub var captureCellsCount: u64 = 0;

/// Cumulative time the worker spent blocked on the request eventfd
/// between render requests. If this is high relative to wall time
/// while the workload was actively producing frames, something is
/// keeping main from queueing renders (typically buffer-release
/// latency from the compositor — `freeBufferIndex` returns null
/// until the prior buffer is released).
pub var workerWaitAccumNs: u64 = 0;
pub var workerWaitCount: u64 = 0;
/// Cumulative time spent with `g_gpu_snapshot_dirty == true` but
/// unable to queue because `freeBufferIndex` returned null. Set by
/// the main thread (gated on SCRGO_LOG=commits to avoid the clock
/// read in hot paths when diagnostics are off).
pub var bufferStarvationAccumNs: u64 = 0;
pub var bufferStarvationCount: u64 = 0;

fn monotonicNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn readRssKb() u64 {
    var buf: [256]u8 = undefined;
    const fd = c.open("/proc/self/statm", c.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    // /proc/self/statm: size resident shared text lib data dt (in pages)
    var it = std.mem.tokenizeAny(u8, buf[0..@intCast(n)], " \n");
    _ = it.next() orelse return 0;
    const resident_pages = std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch return 0;
    return resident_pages * 4; // 4 KiB pages → KiB
}

pub const ResponseTag = enum(u8) {
    context_ready = 1,
    ready = 2,
    frame = 3,
    failed = 4,
    retry = 5,
};

pub const Response = extern struct {
    tag: ResponseTag,
    buffer_index: u8 = 0,
    snapshot_slot: u8 = 0,
    reserved: [1]u8 = [_]u8{0} ** 1,
    serial: u32 = 0,
    /// For `.frame` responses, the DRM syncobj timeline point that
    /// will signal when this frame's GPU work completes. Zero means
    /// "no explicit sync" — the caller falls back to implicit
    /// (driver-internal) fencing as before. Hi/lo split because
    /// wayland's `set_acquire_point` takes 32-bit parts.
    acquire_point_lo: u32 = 0,
    acquire_point_hi: u32 = 0,
    /// A distinct timeline point the compositor signals when it's
    /// done reading the buffer. We don't currently wait on it (we
    /// gate the next render on `frame_done` instead), but the wayland
    /// protocol requires release ≠ acquire.
    release_point_lo: u32 = 0,
    release_point_hi: u32 = 0,
};

const RequestTag = enum {
    configure,
    render,
    quit,
};

const Request = struct {
    tag: RequestTag,
    buffer_index: u8 = 0,
    snapshot_slot: u8 = 0,
    width: u32 = 0,
    height: u32 = 0,
    font_size: f32 = 0,
    cell_width: f32 = 0,
    cell_height: f32 = 0,
    baseline_offset: f32 = 0,
    serial: u32 = 0,
    // Captured snapshot inputs for the worker. The main thread calls
    // `render_snapshot.prepare(term)` before signalling — that's the
    // only step that needs exclusive terminal access. The worker then
    // iterates the render_state via captureCells on its own thread,
    // overlapping snapshot iteration with continued PTY ingest.
    term: ?*terminal_mod.Terminal = null,
    atlas_lease: atlas_ref_mod.AtlasRef.Lease = .{ .ref = undefined, .snapshot = null },
};

// ── Offscreen EGL (surfaceless) ──

const OffscreenEgl = struct {
    display: c.EGLDisplay = c.EGL_NO_DISPLAY,
    context: c.EGLContext = c.EGL_NO_CONTEXT,
    surface: c.EGLSurface = c.EGL_NO_SURFACE,
    config: c.EGLConfig = null,
    create_image: ?*const fn (c.EGLDisplay, c.EGLContext, c.EGLenum, c.EGLClientBuffer, ?[*]const c.EGLint) callconv(.c) c.EGLImage = null,
    destroy_image: ?*const fn (c.EGLDisplay, c.EGLImage) callconv(.c) c.EGLBoolean = null,
    image_target_texture: ?*const fn (c.GLenum, c.GLeglImageOES) callconv(.c) void = null,

    pub fn init() !OffscreenEgl {
        var self: OffscreenEgl = .{};
        log.info(.gpu, "egl init start", .{});

        _ = c.setenv("EGL_PLATFORM", "surfaceless", 0);

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
        log.info(.gpu, "egl initialized", .{
            .version = log.fmt("{}.{}", .{ major, minor }),
        });
        _ = c.eglBindAPI(c.EGL_OPENGL_ES_API);

        const attrs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_PBUFFER_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
            c.EGL_NONE,
        };

        var num: c.EGLint = 0;
        if (c.eglChooseConfig(self.display, &attrs, &self.config, 1, &num) == c.EGL_FALSE or num == 0)
            return error.EglConfigFailed;

        const gles3 = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION, 3,
            c.EGL_CONTEXT_MINOR_VERSION, 0,
            c.EGL_NONE,
        };

        self.context = c.eglCreateContext(self.display, self.config, c.EGL_NO_CONTEXT, &gles3);
        if (self.context == c.EGL_NO_CONTEXT) return error.EglContextFailed;

        const pbuffer_attrs = [_]c.EGLint{ c.EGL_WIDTH, 1, c.EGL_HEIGHT, 1, c.EGL_NONE };
        self.surface = c.eglCreatePbufferSurface(self.display, self.config, &pbuffer_attrs);
        if (self.surface == c.EGL_NO_SURFACE) return error.EglSurfaceFailed;

        if (c.eglMakeCurrent(self.display, self.surface, self.surface, self.context) == c.EGL_FALSE)
            return error.EglMakeCurrentFailed;
        if (log.isScopeEnabled(.gpu)) {
            const vendor = c.glGetString(c.GL_VENDOR);
            const renderer = c.glGetString(c.GL_RENDERER);
            const gl_version = c.glGetString(c.GL_VERSION);
            const glsl_version = c.glGetString(c.GL_SHADING_LANGUAGE_VERSION);
            log.info(.gpu, "egl current", .{
                .vendor = if (vendor) |v| std.mem.sliceTo(v, 0) else "?",
                .renderer = if (renderer) |r| std.mem.sliceTo(r, 0) else "?",
                .version = if (gl_version) |v| std.mem.sliceTo(v, 0) else "?",
                .glsl = if (glsl_version) |v| std.mem.sliceTo(v, 0) else "?",
            });
        }

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

// ── DMA-BUF allocation ──

const drm_format_mod_invalid: u64 = (1 << 56) - 1;

const DmabufTarget = struct {
    desc: gpu_buffer.BufferDesc = .{},
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

        // Prefer non-LINEAR allocations first. GBM_BO_USE_LINEAR forces
        // a linear-tiled buffer, which on NVIDIA destroys texture-cache
        // efficiency when the buffer is sampled by snail's resolve pass
        // (measured ~600× slower than tiled at 1880×2472 with the
        // EXT_disjoint_timer_query path). LINEAR stays as a fallback for
        // compositors that can't import tiled dmabufs.
        const candidates = [_]AllocationCandidate{
            .{ .format = c.DRM_FORMAT_ABGR8888, .usage = c.GBM_BO_USE_RENDERING, .name = "ABGR8888 render" },
            .{ .format = c.DRM_FORMAT_XBGR8888, .usage = c.GBM_BO_USE_RENDERING, .name = "XBGR8888 render" },
            .{ .format = c.DRM_FORMAT_ARGB8888, .usage = c.GBM_BO_USE_RENDERING, .name = "ARGB8888 render" },
            .{ .format = c.DRM_FORMAT_XRGB8888, .usage = c.GBM_BO_USE_RENDERING, .name = "XRGB8888 render" },
            .{ .format = c.DRM_FORMAT_ABGR8888, .usage = c.GBM_BO_USE_RENDERING | c.GBM_BO_USE_LINEAR, .name = "ABGR8888 render|linear" },
            .{ .format = c.DRM_FORMAT_XBGR8888, .usage = c.GBM_BO_USE_RENDERING | c.GBM_BO_USE_LINEAR, .name = "XBGR8888 render|linear" },
            .{ .format = c.DRM_FORMAT_ARGB8888, .usage = c.GBM_BO_USE_RENDERING | c.GBM_BO_USE_LINEAR, .name = "ARGB8888 render|linear" },
            .{ .format = c.DRM_FORMAT_XRGB8888, .usage = c.GBM_BO_USE_RENDERING | c.GBM_BO_USE_LINEAR, .name = "XRGB8888 render|linear" },
        };

        var picked_name: []const u8 = "(none)";
        for (candidates) |candidate| {
            self.bo = c.gbm_bo_create(gbm, width, height, candidate.format, candidate.usage);
            if (self.bo != null) {
                picked_name = candidate.name;
                break;
            }
        }
        if (self.bo == null) return error.GbmCreateFailed;

        const modifier = c.gbm_bo_get_modifier(self.bo);
        log.info(.gpu, "dmabuf alloc", .{
            .candidate = picked_name,
            .modifier = log.fmt("0x{x}", .{modifier}),
            .stride = c.gbm_bo_get_stride(self.bo),
        });
        self.desc = .{
            .width = width,
            .height = height,
            .stride = c.gbm_bo_get_stride(self.bo),
            .offset = 0,
            .format = c.gbm_bo_get_format(self.bo),
            .modifier_hi = @truncate(modifier >> 32),
            .modifier_lo = @truncate(modifier),
        };

        self.export_fd = c.gbm_bo_get_fd(self.bo);
        if (self.export_fd < 0) return error.GbmExportFailed;
        self.import_fd = c.gbm_bo_get_fd(self.bo);
        if (self.import_fd < 0) return error.GbmImportDupFailed;

        const use_modifiers = modifier != drm_format_mod_invalid;
        // mesa rejects EGL_GL_COLORSPACE on EGL_LINUX_DMA_BUF_EXT imports,
        // so the FBO stays linear-format. We compensate by pre-encoding the
        // colors we hand to snail's text shader (see textColor4 in
        // renderer.zig); snail's srgbDecode then yields sRGB-domain output
        // which writes correctly to the non-sRGB FBO.
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
        const egl_attrs: []const c.EGLint = if (use_modifiers)
            attrs_with_modifiers[0..]
        else
            attrs_without_modifiers[0..];
        self.image = egl.create_image.?(egl.display, c.EGL_NO_CONTEXT, c.EGL_LINUX_DMA_BUF_EXT, null, egl_attrs.ptr);
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
    targets: [MaxBuffers]DmabufTarget = [_]DmabufTarget{.{}} ** MaxBuffers,
    count: usize = 0,

    fn init(egl: *const OffscreenEgl, width: u32, height: u32, buffer_count: usize) !DmabufAllocator {
        var self: DmabufAllocator = .{};
        errdefer self.deinit(egl);

        self.render_fd = try openRenderNodeForEgl(egl);
        self.gbm = c.gbm_create_device(self.render_fd) orelse return error.GbmDeviceFailed;

        const clamped_count = @min(buffer_count, MaxBuffers);
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

// ── GpuWorker (main thread side) ──

pub const GpuWorker = struct {
    thread: ?std.Thread = null,
    mutex: c.pthread_mutex_t = undefined,
    /// eventfd the worker blocks on instead of `pthread_cond_wait`.
    /// pthread_cond does extra wait-queue bookkeeping that adds a few
    /// hundred ns of variance on the wakeup path; a bare eventfd is a
    /// direct futex underneath, which gives us tighter latency on
    /// input-driven renders (key→pixel measurement was right at the
    /// edge of one vsync, so jitter in the wakeup matters).
    request_event_fd: c_int = -1,
    response_fds: [2]c_int = [_]c_int{-1} ** 2,

    // Set by main before spawning thread
    atlas_ref: ?*atlas_ref_mod.AtlasRef = null,
    atlas_thread: ?*atlas_worker.AtlasWorker = null,

    // Request state (protected by mutex)
    request_pending: bool = false,
    request: Request = .{ .tag = .quit },
    stop_requested: bool = false,

    // Snapshot slots
    snapshots: [SnapshotSlotCount]render_snapshot.SharedSnapshot = [_]render_snapshot.SharedSnapshot{.{}} ** SnapshotSlotCount,
    snapshot_busy: [SnapshotSlotCount]bool = [_]bool{false} ** SnapshotSlotCount,

    // Buffer descriptors populated by worker, read by main after "ready"
    buffer_descs: [MaxBuffers]gpu_buffer.BufferDesc = [_]gpu_buffer.BufferDesc{.{}} ** MaxBuffers,
    buffer_export_fds: [MaxBuffers]c_int = [_]c_int{-1} ** MaxBuffers,
    buffer_count: u8 = 0,
    /// Per-buffer DRM syncobj timeline fds. The wp_linux_drm_syncobj_v1
    /// protocol explicitly warns against sharing a single timeline
    /// across multiple buffers' release points (signaling a later point
    /// retroactively signals earlier ones, which can fire wl_buffer.release
    /// before the compositor is actually done reading the prior buffer).
    /// One timeline per buffer sidesteps that entirely — each buffer's
    /// acquire AND release points live on its own monotonic counter.
    /// Negative entries = no explicit-sync available for that slot
    /// (typically because EGL native fence sync is missing or the
    /// kill-switch is set); falls back to implicit fencing.
    drm_syncobj_export_fds: [MaxBuffers]c_int = [_]c_int{-1} ** MaxBuffers,

    // GpuWorker-side state
    buffers: [MaxBuffers]gpu_buffer.FrontendBuffer = undefined,
    frontend_buffer_count: usize = 0,

    active: bool = false,
    context_ready: bool = false,
    ready: bool = false,
    render_in_flight: bool = false,
    first_frame_presented: bool = false,

    pub fn responseFd(self: *const GpuWorker) c_int {
        return self.response_fds[0];
    }

    /// Wake the worker. eventfd accumulates writes into a counter and
    /// the worker's blocking read drains it; we never miss a signal
    /// even if we write twice between worker iterations.
    fn signalWorker(self: *GpuWorker) void {
        var v: u64 = 1;
        _ = c.write(self.request_event_fd, &v, @sizeOf(u64));
    }

    /// Start the GPU renderer thread. It immediately begins EGL init (no deps).
    pub fn start(self: *GpuWorker) !void {
        if (self.active) return;
        self.* = .{};
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        self.request_event_fd = c.eventfd(0, c.EFD_CLOEXEC);
        if (self.request_event_fd < 0) return error.EventfdFailed;
        errdefer {
            _ = c.close(self.request_event_fd);
            self.request_event_fd = -1;
        }

        var pipe_fds: [2]c_int = undefined;
        if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        self.response_fds = pipe_fds;
        errdefer {
            _ = c.close(self.response_fds[0]);
            _ = c.close(self.response_fds[1]);
            self.response_fds = [_]c_int{-1} ** 2;
        }

        self.active = true;
        self.thread = try std.Thread.spawn(.{}, GpuWorker.workerMain, .{self});
    }

    /// Provide the atlas ref after it is initialized.
    /// Must be called before requestConfigure.
    pub fn setSharedState(
        self: *GpuWorker,
        atlas_ref: *atlas_ref_mod.AtlasRef,
        atlas_thread: *atlas_worker.AtlasWorker,
    ) void {
        self.atlas_ref = atlas_ref;
        self.atlas_thread = atlas_thread;
    }

    pub fn requestConfigure(self: *GpuWorker, w: u32, h: u32, font_size: f32, cell_width: f32, cell_height: f32, baseline_offset: f32) !void {
        if (!self.active or !self.context_ready) return error.NotReady;
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        // If a render was queued but not yet picked up by the worker, we're
        // about to drop it on the floor. Free its snapshot slot — without
        // this, rapid resizes can leak both slots and queueRender starts
        // returning NoFreeSnapshot forever.
        if (self.request_pending and self.request.tag == .render) {
            const slot = self.request.snapshot_slot;
            if (slot < SnapshotSlotCount) self.snapshot_busy[slot] = false;
        }
        self.request = .{
            .tag = .configure,
            .width = w,
            .height = h,
            .font_size = font_size,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .baseline_offset = baseline_offset,
        };
        self.request_pending = true;
        self.ready = false;
        self.render_in_flight = false;
        self.signalWorker();
    }

    pub fn freeBufferIndex(self: *GpuWorker) ?u8 {
        for (0..self.frontend_buffer_count) |i| {
            if (self.buffers[i].released) return @intCast(i);
        }
        return null;
    }

    fn freeSnapshotSlot(self: *GpuWorker) ?u8 {
        for (0..SnapshotSlotCount) |i| {
            if (!self.snapshot_busy[i]) return @intCast(i);
        }
        return null;
    }

    pub fn queueRender(
        self: *GpuWorker,
        term: *terminal_mod.Terminal,
        serial: u32,
        selection: ?@import("../selection.zig").Snapshot,
        scrollbar: ?render_snapshot.ScrollbarOverlay,
        bell: ?render_snapshot.BellOverlay,
    ) !void {
        if (!self.active or !self.ready) return error.NotReady;
        if (self.render_in_flight or self.request_pending) return error.Busy;
        const atlas_ref = self.atlas_ref orelse return error.NotReady;
        const buffer_index = self.freeBufferIndex() orelse return error.NoFreeBuffer;
        const snapshot_slot = self.freeSnapshotSlot() orelse return error.NoFreeSnapshot;

        // Hand off the snapshot work to the worker. Prepare consumes the
        // terminal's dirty state on the main thread (cheap, ~50 µs); the
        // worker then walks the render_state without touching the terminal
        // again. The acquired lease moves into the request so the atlas
        // outlives iteration; the worker releases it.
        const snap_t0 = monotonicNs();
        try render_snapshot.prepare(&self.snapshots[snapshot_slot], term, selection, scrollbar, bell);
        snapshotPhaseAccumNs += monotonicNs() - snap_t0;
        snapshotPhaseCount += 1;
        self.snapshot_busy[snapshot_slot] = true;

        const atlas_lease = atlas_ref.acquire();

        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.request = .{
            .tag = .render,
            .buffer_index = buffer_index,
            .snapshot_slot = snapshot_slot,
            .serial = serial,
            .term = term,
            .atlas_lease = atlas_lease,
        };
        self.request_pending = true;
        self.render_in_flight = true;
        self.signalWorker();
    }

    pub fn readResponse(self: *GpuWorker) !?Response {
        var response: Response = undefined;
        const rc = c.read(self.response_fds[0], &response, @sizeOf(Response));
        if (rc == 0) return null;
        if (rc < 0) return error.ReadFailed;
        if (@as(usize, @intCast(rc)) < @sizeOf(Response)) return error.ShortRead;

        switch (response.tag) {
            .context_ready => {
                self.context_ready = true;
            },
            .ready => {
                self.ready = true;
                self.render_in_flight = false;
            },
            .frame => {
                if (response.snapshot_slot < SnapshotSlotCount) {
                    self.snapshot_busy[response.snapshot_slot] = false;
                }
                self.render_in_flight = false;
            },
            .failed, .retry => {
                if (response.snapshot_slot < SnapshotSlotCount) {
                    self.snapshot_busy[response.snapshot_slot] = false;
                }
                self.render_in_flight = false;
            },
        }
        return response;
    }

    /// Import dmabuf fds as wayland buffers. Call after receiving "ready" response.
    pub fn installBuffers(self: *GpuWorker, dmabuf_opaque: *anyopaque) !void {
        self.destroyFrontendBuffers();
        const count = @min(@as(usize, self.buffer_count), MaxBuffers);
        for (0..count) |i| {
            self.buffers[i] = try gpu_buffer.FrontendBuffer.create(
                dmabuf_opaque,
                self.buffer_export_fds[i],
                self.buffer_descs[i],
            );
            self.buffer_export_fds[i] = -1; // create() took ownership of the fd
            self.buffers[i].attachListener();
            self.frontend_buffer_count += 1;
        }
    }

    fn destroyFrontendBuffers(self: *GpuWorker) void {
        for (self.buffers[0..self.frontend_buffer_count]) |*buffer| buffer.destroy();
        self.frontend_buffer_count = 0;
    }

    pub fn stop(self: *GpuWorker) void {
        if (!self.active) return;
        var was_ready: bool = undefined;
        {
            _ = c.pthread_mutex_lock(&self.mutex);
            defer _ = c.pthread_mutex_unlock(&self.mutex);
            self.stop_requested = true;
            was_ready = self.context_ready;
            self.signalWorker();
        }
        if (!was_ready) {
            // OffscreenEgl.init() has no cancellation point, so joining
            // would block on the full EGL bringup. Detach and skip libc's
            // exit chain: atexit-run library destructors (libEGL._fini)
            // race with the worker still inside the EGL platform — that
            // races into SIGSEGV in EGL teardown. _exit lets the kernel
            // reap everything at once. No wayland buffers exist yet
            // (those come from configure, post-context_ready), so the
            // compositor sees a clean socket close.
            if (self.thread) |thread| thread.detach();
            self.thread = null;
            self.active = false;
            c._exit(0);
        }
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.destroyFrontendBuffers();
        // Close any unclaimed export fds
        for (&self.buffer_export_fds) |*fd| {
            if (fd.* >= 0) {
                _ = c.close(fd.*);
                fd.* = -1;
            }
        }
        if (self.response_fds[0] >= 0) _ = c.close(self.response_fds[0]);
        if (self.response_fds[1] >= 0) _ = c.close(self.response_fds[1]);
        self.response_fds = [_]c_int{-1} ** 2;
        if (self.request_event_fd >= 0) {
            _ = c.close(self.request_event_fd);
            self.request_event_fd = -1;
        }
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.active = false;
        self.context_ready = false;
        self.ready = false;
        self.render_in_flight = false;
        self.first_frame_presented = false;
    }

    // ── Worker thread ──

    fn workerMain(self: *GpuWorker) void {
        log.info(.gpu, "thread started", .{});

        const warn_slow_budget_ms = render_env.parseWarnSlowMs(
            if (c.getenv("SCRGO_WARN_SLOW_MS")) |v| std.mem.sliceTo(v, 0) else null,
        );
        const sync_extend_cfg = render_env.parseSyncExtend(
            if (c.getenv("SCRGO_SYNC_EXTEND")) |v| std.mem.sliceTo(v, 0) else null,
        );
        // Previous iteration's full frame cost (draw_t0 → end of fence
        // wait), used to predict how much wall time the second draw +
        // fence will need when sizing the sync-extend deadline. Zero
        // until the first frame completes, which gates the sync retry
        // (no data → don't risk it).
        var last_full_frame_ns: u64 = 0;
        var diag_frame_counter: u64 = 0;

        // Phase 1: EGL + snail.Renderer init (no deps needed)
        var egl = OffscreenEgl.init() catch |e| {
            log.err(.gpu, "egl init failed", .{ .err = e });
            writeResponse(self.response_fds[1], .{ .tag = .failed });
            return;
        };
        defer egl.deinit();
        log.info(.gpu, "offscreen egl ready", .{});

        // Signal context ready — main can now send configure
        writeResponse(self.response_fds[1], .{ .tag = .context_ready });

        var allocator_state: ?DmabufAllocator = null;
        defer if (allocator_state) |*existing| existing.deinit(&egl);
        var renderer: ?gpu_pipeline.GpuPipeline = null;
        defer if (renderer) |*r| r.deinit();
        var current_width: u32 = 0;
        var current_height: u32 = 0;

        // Explicit-sync state. One timeline per buffer so a release-point
        // signal on one buffer can never retroactively signal a release
        // on another (see drm_syncobj_v1 protocol note about shared
        // timelines + out-of-order release).
        var drm_timelines: [MaxBuffers]?drm_sync.Timeline = [_]?drm_sync.Timeline{null} ** MaxBuffers;
        defer for (&drm_timelines) |*slot| if (slot.*) |*t| t.deinit();
        const egl_fence_fns = drm_sync.EglFenceFns.load();
        if (!egl_fence_fns.available()) {
            log.warn(.gpu, "egl native fence sync unavailable", .{});
        }

        // Phase 2+3: request loop. We wait on the eventfd outside the
        // mutex — pthread_cond_wait would tangle the wakeup with the
        // mutex's wait queue, adding bookkeeping latency on a code
        // path that fires on every keystroke. The eventfd is a direct
        // futex; the mutex is only held to copy the request struct.
        while (true) {
            // Fast-path: if request already pending we don't need to
            // block on the eventfd. This trims a syscall when main
            // posted a new request while we were processing the prior
            // one.
            const need_wait = blk: {
                _ = c.pthread_mutex_lock(&self.mutex);
                defer _ = c.pthread_mutex_unlock(&self.mutex);
                break :blk !self.request_pending and !self.stop_requested;
            };
            if (need_wait) {
                const wait_t0 = monotonicNs();
                var v: u64 = 0;
                _ = c.read(self.request_event_fd, &v, @sizeOf(u64));
                workerWaitAccumNs += monotonicNs() - wait_t0;
                workerWaitCount += 1;
            }
            _ = c.pthread_mutex_lock(&self.mutex);
            if (self.stop_requested) {
                _ = c.pthread_mutex_unlock(&self.mutex);
                return;
            }
            if (!self.request_pending) {
                _ = c.pthread_mutex_unlock(&self.mutex);
                continue;
            }
            const request = self.request;
            self.request_pending = false;
            _ = c.pthread_mutex_unlock(&self.mutex);

            switch (request.tag) {
                .quit => return,
                .configure => {
                    const reconfigure_timer = perf.Timer.now();
                    log.info(.gpu, "configure", .{
                        .width = request.width,
                        .height = request.height,
                        .font = log.fmt("{d:.1}", .{request.font_size}),
                    });

                    const atlas_ref = self.atlas_ref orelse {
                        log.err(.gpu, "configure failed", .{ .reason = "missing_atlas_ref" });
                        writeResponse(self.response_fds[1], .{ .tag = .failed });
                        continue;
                    };

                    // Allocate dmabufs
                    const next_allocator = DmabufAllocator.init(&egl, request.width, request.height, MaxBuffers) catch |e| {
                        log.err(.gpu, "dmabuf alloc failed", .{ .err = e });
                        writeResponse(self.response_fds[1], .{ .tag = .failed });
                        continue;
                    };
                    if (allocator_state) |*existing| existing.deinit(&egl);
                    allocator_state = next_allocator;
                    current_width = request.width;
                    current_height = request.height;

                    // Init or reconfigure renderer
                    if (renderer) |*r| {
                        r.setMetrics(request.font_size, request.cell_width, request.cell_height, request.baseline_offset);
                        r.setViewport(request.width, request.height);
                    } else {
                        renderer = gpu_pipeline.GpuPipeline.init(
                            std.heap.smp_allocator,
                            atlas_ref,
                            request.font_size,
                            request.cell_width,
                            request.cell_height,
                            request.baseline_offset,
                        ) catch |e| {
                            log.err(.gpu, "renderer init failed", .{ .err = e });
                            writeResponse(self.response_fds[1], .{ .tag = .failed });
                            continue;
                        };
                        renderer.?.setTraceFrames(parseTraceFromEnv());
                        const runtime_flags = render_env.parseRuntimeFlags(
                            if (c.getenv("SCRGO_FLAGS")) |value| std.mem.sliceTo(value, 0) else null,
                        );
                        renderer.?.setDebugResetAtlas(runtime_flags.reset_atlas_each_frame);
                        renderer.?.setViewport(request.width, request.height);
                    }
                    // We just allocated fresh dmabuf textures; their
                    // pixels are undefined. Drop any per-target paint
                    // state the renderer was carrying over from the
                    // prior allocation so the first paint into each
                    // new buffer uses backdrop=.clear instead of
                    // sampling garbage.
                    renderer.?.notifyTargetsReinstalled();

                    // Warm snail's GL pipeline: render a tiny synthetic
                    // scene (one rect + one glyph + .target resolve)
                    // into buffer 0. This compiles every shader program
                    // we'll use at steady state and uploads the atlas to
                    // the GPU, paying the first-use driver costs *before*
                    // we tell the main thread the GPU is ready. Without
                    // this, the first user-visible frames carry a ~10ms
                    // compile spike. We invalidate target state at the
                    // end so the first real frame still paints from
                    // scratch with backdrop=.clear.
                    const active_allocator = &allocator_state.?;
                    if (active_allocator.count > 0) {
                        const warm_t0 = perf.Timer.now();
                        c.glBindFramebuffer(c.GL_FRAMEBUFFER, active_allocator.targets[0].framebuffer);
                        c.glViewport(0, 0, @intCast(current_width), @intCast(current_height));
                        renderer.?.warmPipeline() catch |e| {
                            log.warn(.gpu, "pipeline warmup failed", .{ .err = e });
                        };
                        log.info(.gpu, "pipeline warmup", .{
                            .elapsed_ms = log.fmt("{d:.1}", .{warm_t0.elapsedMs()}),
                        });
                    }

                    // Publish buffer descriptors for main thread
                    self.buffer_count = @intCast(active_allocator.count);
                    for (0..active_allocator.count) |i| {
                        self.buffer_descs[i] = active_allocator.targets[i].desc;
                        self.buffer_export_fds[i] = active_allocator.targets[i].export_fd;
                        active_allocator.targets[i].export_fd = -1; // Transfer ownership to main
                    }

                    // (Re)create one DRM syncobj timeline per buffer now
                    // that we have a render fd. Tear down any prior
                    // timelines — their handles are bound to the prior
                    // render fd which we're about to drop when
                    // allocator_state churns.
                    for (&drm_timelines) |*slot| if (slot.*) |*t| {
                        t.deinit();
                        slot.* = null;
                    };
                    self.drm_syncobj_export_fds = [_]c_int{-1} ** MaxBuffers;
                    if (render_env.explicitSyncEnabled() and egl_fence_fns.available() and active_allocator.render_fd >= 0) {
                        var ready_count: usize = 0;
                        for (0..active_allocator.count) |i| {
                            drm_timelines[i] = drm_sync.Timeline.init(active_allocator.render_fd) catch |e| blk: {
                                log.warn(.gpu, "drm syncobj init failed", .{ .buffer = i, .err = e });
                                break :blk null;
                            };
                            if (drm_timelines[i]) |*t| {
                                self.drm_syncobj_export_fds[i] = t.takeExportFd();
                                ready_count += 1;
                            }
                        }
                        if (ready_count > 0) {
                            log.info(.gpu, "drm syncobj ready", .{ .timelines = ready_count });
                        }
                    } else if (!render_env.explicitSyncEnabled()) {
                        log.info(.gpu, "explicit sync disabled (env)", .{});
                    }

                    log.info(.gpu, "configure ready", .{
                        .elapsed_ms = log.fmt("{d:.1}", .{reconfigure_timer.elapsedMs()}),
                    });
                    writeResponse(self.response_fds[1], .{ .tag = .ready });
                },
                .render => {
                    if (allocator_state == null or renderer == null) continue;
                    const active_allocator = &allocator_state.?;
                    const r = &renderer.?;
                    if (request.buffer_index >= active_allocator.count) continue;
                    if (request.snapshot_slot >= SnapshotSlotCount) continue;
                    log.setFrame(.gpu, request.serial);

                    // Iterate the render_state into the snapshot here on
                    // the worker thread. The main thread already ran
                    // `prepare(term)` (updateRenderState) before signalling,
                    // so this only touches the decoupled render_state.
                    var atlas_lease = request.atlas_lease;
                    defer atlas_lease.release();
                    const cells_t0 = monotonicNs();
                    if (request.term) |term| {
                        render_snapshot.captureCells(
                            &self.snapshots[request.snapshot_slot],
                            term,
                            atlas_lease.get(),
                        ) catch {
                            writeResponse(self.response_fds[1], .{
                                .tag = .failed,
                                .buffer_index = request.buffer_index,
                                .snapshot_slot = request.snapshot_slot,
                                .serial = request.serial,
                            });
                            continue;
                        };
                    }
                    const cells_elapsed_ns = monotonicNs() - cells_t0;
                    captureCellsAccumNs += cells_elapsed_ns;
                    captureCellsCount += 1;

                    const render_timer = perf.Timer.now();
                    const draw_t0 = monotonicNs();

                    // Snapshot the renderer's phase accumulators so the
                    // slow-frame print can show a per-phase breakdown
                    // (row build / picture build / atlas upload /
                    // drawlist build / GL submit) instead of one opaque
                    // "draw" number. Cheap reads; we always take them
                    // so the hot path stays branch-free even when the
                    // warning is disabled.
                    const phase_row_base = gpu_pipeline.GpuPipeline.phase_row_build_ns;
                    const phase_pic_base = gpu_pipeline.GpuPipeline.phase_picture_ns;
                    const phase_upload_base = gpu_pipeline.GpuPipeline.phase_upload_ns;
                    const phase_drawlist_base = gpu_pipeline.GpuPipeline.phase_drawlist_ns;
                    const phase_draw_base = gpu_pipeline.GpuPipeline.phase_draw_ns;
                    const gpu_compute_base = gpu_pipeline.GpuPipeline.phase_gpu_compute_ns;
                    const gpu_compute_samples_base = gpu_pipeline.GpuPipeline.phase_gpu_compute_samples;
                    const row_rebuild_base = row_build.phase_row_rebuild_ns;
                    const row_count_base = row_build.phase_row_count;
                    const row_shape_base = row_build.phase_row_shape_ns;
                    const row_finish_base = row_build.phase_row_finish_ns;
                    const hint_prepare_base = row_build.phase_hint_prepare_ns;
                    const hint_append_base = row_build.phase_hint_append_ns;
                    const hint_runs_base = row_build.phase_hint_runs;
                    const hint_hinted_base = row_build.phase_hint_glyphs_hinted;
                    const hint_fallback_base = row_build.phase_hint_glyphs_fallback;

                    const target = &active_allocator.targets[request.buffer_index];
                    c.glBindFramebuffer(c.GL_FRAMEBUFFER, target.framebuffer);
                    c.glViewport(0, 0, @intCast(current_width), @intCast(current_height));

                    // drawSnapshot paints directly into the dmabuf
                    // FBO bound above. Each dmabuf retains its own
                    // pixels across the swap chain rotation; the
                    // renderer keeps per-buffer paint state keyed by
                    // buffer_index so it can compute the dirty set as
                    // "rows that differ from *this dmabuf's* recorded
                    // era," not from the global most-recent frame.
                    r.setActiveTarget(request.buffer_index);

                    var misses: glyph_misses.Set = .{};
                    r.drawSnapshot(&self.snapshots[request.snapshot_slot], &misses) catch {
                        writeResponse(self.response_fds[1], .{
                            .tag = .failed,
                            .buffer_index = request.buffer_index,
                            .snapshot_slot = request.snapshot_slot,
                            .serial = request.serial,
                        });
                        continue;
                    };

                    if (!misses.isEmpty()) {
                        // Bounded sync retry (controlled by
                        // SCRGO_SYNC_EXTEND): give the atlas thread a
                        // deadline to publish a snapshot covering this
                        // frame's misses, then redraw with the extended
                        // atlas. The redraw paints over the first one
                        // in the same dmabuf FBO — every frame is a
                        // full repaint (see gpu_pipeline.zig:171), so
                        // the second paint cleanly wins. On timeout we
                        // ship the partial frame and rely on the async
                        // requestMany below to dirty the next vsync via
                        // the atlas worker's response pipe.
                        //
                        // The deadline is derived from data, not a
                        // fixed env knob: vsync period - elapsed -
                        // predicted-second-frame - safety. We require
                        // historical frame data (last_full_frame_ns) to
                        // size the prediction, so the first frame after
                        // startup always bails to async.
                        if (self.atlas_thread) |at| sync_retry: {
                            if (!sync_extend_cfg.enabled) break :sync_retry;
                            if (last_full_frame_ns == 0) break :sync_retry;
                            const vsync_ns = perf.vsync_period_ns.load(.acquire);
                            if (vsync_ns == 0) break :sync_retry;
                            const now_ns = monotonicNs();
                            const elapsed_ns = now_ns - draw_t0;
                            const safety_ns: u64 = std.time.ns_per_ms;
                            const reserved = elapsed_ns + last_full_frame_ns + safety_ns;
                            if (reserved >= vsync_ns) break :sync_retry;
                            var budget_ns = vsync_ns - reserved;
                            if (sync_extend_cfg.cap_ms) |cap_ms| {
                                const cap_ns = @as(u64, cap_ms) * std.time.ns_per_ms;
                                budget_ns = @min(budget_ns, cap_ns);
                            }
                            // Don't bother if the headroom is so small
                            // the round-trip + ensureText would chew
                            // most of it.
                            if (budget_ns < 500 * std.time.ns_per_us) break :sync_retry;
                            const deadline_ns = now_ns + budget_ns;
                            switch (at.extendBefore(&misses, deadline_ns)) {
                                .extended => {
                                    misses = .{};
                                    r.drawSnapshot(&self.snapshots[request.snapshot_slot], &misses) catch {
                                        // Original draw is still in the FBO; fall through.
                                        misses = .{};
                                    };
                                },
                                .timed_out, .unavailable => {},
                            }
                        }
                        if (self.atlas_thread) |at| {
                            if (!misses.isEmpty()) at.requestMany(&misses);
                        }
                    }

                    // Two sync paths:
                    //
                    //  Explicit (drm_timeline available + EGL fence
                    //  sync supported): allocate the next timeline
                    //  point, capture an EGL fence on the GL command
                    //  stream, transfer the fence into the timeline.
                    //  We do NOT wait on the CPU — the compositor will
                    //  wait on the timeline point itself before reading
                    //  our buffer. ~zero CPU stall in this path.
                    //
                    //  Implicit (timeline unavailable or signal failed):
                    //  fall back to glFenceSync + glClientWaitSync.
                    //  Required so the .frame response→commit→compositor
                    //  read can't race the GPU writes; without this,
                    //  the compositor would sample partially written
                    //  or stale pixels.
                    var acquire_point: u64 = 0;
                    var release_point: u64 = 0;
                    const gpu_wait_t0 = monotonicNs();
                    if (request.buffer_index < MaxBuffers) {
                        if (drm_timelines[request.buffer_index]) |*t| {
                            const point = t.nextPoint();
                            // Burn the next point as release. The
                            // compositor signals it when done; we don't
                            // currently wait on it (frame_done callback
                            // gates the next render). One timeline per
                            // buffer means this release point can never
                            // accidentally signal an earlier buffer's
                            // release.
                            const release = t.nextPoint();
                            if (t.signalFromEgl(egl.display, egl_fence_fns, point)) {
                                acquire_point = point;
                                release_point = release;
                            } else |signal_err| {
                                log.warn(.gpu, "drm syncobj signal failed; falling back to fence wait", .{
                                    .err = signal_err,
                                });
                            }
                        }
                    }
                    if (acquire_point == 0) {
                        const fence_sync = c.glFenceSync(c.GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
                        if (fence_sync != null) {
                            _ = c.glClientWaitSync(fence_sync, c.GL_SYNC_FLUSH_COMMANDS_BIT, std.math.maxInt(u64));
                            c.glDeleteSync(fence_sync);
                        }
                    }
                    const gpu_wait_elapsed_ns = monotonicNs() - gpu_wait_t0;
                    // Record total wall-time for this iteration so the
                    // next miss-frame's sync-extend budget can predict
                    // how much the redraw + fence wait will cost.
                    last_full_frame_ns = monotonicNs() - draw_t0;

                    log.debug(.gpu, "render complete", .{
                        .buffer = request.buffer_index,
                        .elapsed_ms = log.fmt("{d:.1}", .{render_timer.elapsedMs()}),
                        .acquire_point = acquire_point,
                    });
                    writeResponse(self.response_fds[1], .{
                        .tag = .frame,
                        .buffer_index = request.buffer_index,
                        .snapshot_slot = request.snapshot_slot,
                        .serial = request.serial,
                        .acquire_point_lo = @truncate(acquire_point),
                        .acquire_point_hi = @truncate(acquire_point >> 32),
                        .release_point_lo = @truncate(release_point),
                        .release_point_hi = @truncate(release_point >> 32),
                    });

                    // Periodic state dump: print RSS once per second-ish
                    // so we can correlate row-build creep with resident
                    // memory growth without needing a slow-frame trigger.
                    diag_frame_counter += 1;
                    if (diag_frame_counter % 60 == 0) {
                        log.info(.diag, "rss sample", .{
                            .frame = diag_frame_counter,
                            .rss_kib = readRssKb(),
                        });
                    }

                    if (warn_slow_budget_ms) |budget_ms| {
                        const draw_elapsed_ns = monotonicNs() - draw_t0;
                        const frame_elapsed_ns = cells_elapsed_ns + draw_elapsed_ns;
                        const budget_ns = @as(u64, budget_ms) * std.time.ns_per_ms;
                        if (frame_elapsed_ns > budget_ns) {
                            const ms_f = @as(f64, std.time.ns_per_ms);
                            const phase_row = gpu_pipeline.GpuPipeline.phase_row_build_ns - phase_row_base;
                            const phase_pic = gpu_pipeline.GpuPipeline.phase_picture_ns - phase_pic_base;
                            const phase_upload = gpu_pipeline.GpuPipeline.phase_upload_ns - phase_upload_base;
                            const phase_drawlist = gpu_pipeline.GpuPipeline.phase_drawlist_ns - phase_drawlist_base;
                            const phase_draw = gpu_pipeline.GpuPipeline.phase_draw_ns - phase_draw_base;
                            const gpu_compute = gpu_pipeline.GpuPipeline.phase_gpu_compute_ns - gpu_compute_base;
                            const gpu_compute_samples = gpu_pipeline.GpuPipeline.phase_gpu_compute_samples - gpu_compute_samples_base;
                            const row_rebuild = row_build.phase_row_rebuild_ns - row_rebuild_base;
                            const row_count = row_build.phase_row_count - row_count_base;
                            const row_shape = row_build.phase_row_shape_ns - row_shape_base;
                            const row_finish = row_build.phase_row_finish_ns - row_finish_base;
                            const hint_prepare = row_build.phase_hint_prepare_ns - hint_prepare_base;
                            const hint_append = row_build.phase_hint_append_ns - hint_append_base;
                            const hint_runs = row_build.phase_hint_runs - hint_runs_base;
                            const hint_hinted = row_build.phase_hint_glyphs_hinted - hint_hinted_base;
                            const hint_fallback = row_build.phase_hint_glyphs_fallback - hint_fallback_base;
                            log.warn(.gpu, "slow frame", .{
                                .elapsed_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(frame_elapsed_ns)) / ms_f}),
                                .budget_ms = budget_ms,
                                .cells_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(cells_elapsed_ns)) / ms_f}),
                                .draw_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(draw_elapsed_ns)) / ms_f}),
                                .row_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(phase_row)) / ms_f}),
                                .rebuild_ms = log.fmt("{d:.2}", .{@as(f64, @floatFromInt(row_rebuild)) / ms_f}),
                                .shape_ms = log.fmt("{d:.2}", .{@as(f64, @floatFromInt(row_shape)) / ms_f}),
                                .finish_ms = log.fmt("{d:.2}", .{@as(f64, @floatFromInt(row_finish)) / ms_f}),
                                .hint_prepare_ms = log.fmt("{d:.2}", .{@as(f64, @floatFromInt(hint_prepare)) / ms_f}),
                                .hint_append_ms = log.fmt("{d:.2}", .{@as(f64, @floatFromInt(hint_append)) / ms_f}),
                                .hint_runs = hint_runs,
                                .hint_hinted = hint_hinted,
                                .hint_fallback = hint_fallback,
                                .rows = row_count,
                                .pic_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(phase_pic)) / ms_f}),
                                .upload_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(phase_upload)) / ms_f}),
                                .drawlist_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(phase_drawlist)) / ms_f}),
                                .gl_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(phase_draw)) / ms_f}),
                                .fence_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(gpu_wait_elapsed_ns)) / ms_f}),
                                // GPU-side timestamp-query result lags by ~1
                                // frame; samples=0 means the previous-frame
                                // queries weren't ready or got disjointed.
                                .gpu_compute_ms = log.fmt("{d:.2}", .{@as(f64, @floatFromInt(gpu_compute)) / ms_f}),
                                .gpu_compute_n = gpu_compute_samples,
                            });
                            if (render_env.hint_diag_enabled) {
                                const rj = row_build.phase_hint_reject_counts;
                                log.warn(.gpu, "hint reject histogram (cumulative)", .{
                                    .invalid_face = rj[@intFromEnum(snail.TrueTypeHintRejectReason.invalid_face)],
                                    .no_tt_program = rj[@intFromEnum(snail.TrueTypeHintRejectReason.no_true_type_program)],
                                    .synthetic_embolden = rj[@intFromEnum(snail.TrueTypeHintRejectReason.synthetic_embolden)],
                                    .color_glyph = rj[@intFromEnum(snail.TrueTypeHintRejectReason.color_glyph)],
                                    .grid_fit_disabled = rj[@intFromEnum(snail.TrueTypeHintRejectReason.grid_fit_disabled)],
                                    .missing_base_glyph = rj[@intFromEnum(snail.TrueTypeHintRejectReason.missing_base_glyph)],
                                    .topology_changed = rj[@intFromEnum(snail.TrueTypeHintRejectReason.topology_changed)],
                                    .bands_not_reusable = rj[@intFromEnum(snail.TrueTypeHintRejectReason.bands_not_reusable)],
                                    .empty_hinted_outline = rj[@intFromEnum(snail.TrueTypeHintRejectReason.empty_hinted_outline)],
                                    .exec_failed = rj[@intFromEnum(snail.TrueTypeHintRejectReason.exec_failed)],
                                });
                            }
                        }
                    }
                },
            }
        }
    }
};

fn writeResponse(fd: c_int, response: Response) void {
    _ = c.write(fd, &response, @sizeOf(Response));
}

// ── Render node discovery ──

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
                    const fd = c.open(render_node, c.O_RDWR | c.O_CLOEXEC);
                    if (fd >= 0) return fd;
                }
            }
        }
    }
    return openRenderNode();
}
