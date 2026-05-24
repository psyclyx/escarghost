//! DRM syncobj + EGL native-fence-sync helpers for the
//! `wp_linux_drm_syncobj_v1` explicit-synchronization path.
//!
//! Owns one timeline syncobj per surface; per frame the GPU worker
//! creates an EGL fence on the GL command stream, dups it to a
//! `sync_file` fd, and transfers that signal into the next timeline
//! point. The compositor reads the timeline via the wayland surface
//! extension and waits on the acquire point before reading our
//! dmabuf — replacing the per-frame glClientWaitSync CPU stall with
//! a driver-managed dependency.

const std = @import("std");

pub const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("unistd.h");
});

const egl_c = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});

/// EGL types treated as opaque pointers here so callers from different
/// cImport scopes (e.g. gpu_worker has its own EGL cImport) can pass
/// their own `EGLDisplay`/`EGLSync` without cross-cImport type pain.
pub const Display = ?*anyopaque;
pub const Sync = ?*anyopaque;

const EGL_SYNC_NATIVE_FENCE_ANDROID: c_uint = 0x3144;

/// EGL native fence sync function pointers, resolved lazily via
/// eglGetProcAddress. EGL_ANDROID_native_fence_sync is the standard
/// extension exposed by both Mesa and NVIDIA; it lets us create a
/// sync object on the GL command stream and export it as a Linux
/// `sync_file` fd suitable for `drmSyncobjImportSyncFile`.
pub const EglFenceFns = struct {
    create_sync: ?*const fn (Display, c_uint, [*c]const c_int) callconv(.c) Sync = null,
    destroy_sync: ?*const fn (Display, Sync) callconv(.c) c_uint = null,
    dup_native_fence_fd: ?*const fn (Display, Sync) callconv(.c) c_int = null,

    pub fn load() EglFenceFns {
        return .{
            .create_sync = @ptrCast(egl_c.eglGetProcAddress("eglCreateSyncKHR")),
            .destroy_sync = @ptrCast(egl_c.eglGetProcAddress("eglDestroySyncKHR")),
            .dup_native_fence_fd = @ptrCast(egl_c.eglGetProcAddress("eglDupNativeFenceFDANDROID")),
        };
    }

    pub fn available(self: EglFenceFns) bool {
        return self.create_sync != null and self.destroy_sync != null and self.dup_native_fence_fd != null;
    }
};

/// One timeline syncobj plus a monotonic point counter. `render_fd`
/// is the open DRM render node (typically `/dev/dri/renderD128`),
/// borrowed from the dmabuf allocator. The Timeline does NOT own the
/// fd — it must outlive the Timeline. Per-handle ownership is for
/// the `handle` (drmSyncobj) and `export_fd` (the fd we hand to the
/// compositor via `import_timeline`).
pub const Timeline = struct {
    render_fd: c_int,
    handle: u32 = 0,
    /// Exported fd owned by the compositor after we send it via
    /// `wp_linux_drm_syncobj_manager_v1.import_timeline`. We dup it
    /// for that call and then close our copy. Set to -1 once
    /// transferred so deinit doesn't double-close.
    export_fd: c_int = -1,
    /// Next free timeline point. Monotonically increasing; never 0
    /// (a timeline syncobj at point 0 is always "signaled" so we
    /// start at 1 to avoid the false-positive race).
    next_point: u64 = 1,

    pub fn init(render_fd: c_int) !Timeline {
        var self: Timeline = .{ .render_fd = render_fd };
        // drmSyncobjCreate with flags=0 creates a binary syncobj initially.
        // Timeline operations (transfer / set point) promote it implicitly
        // on first use. We use the timeline transfer API throughout, so
        // there's nothing extra to configure here.
        const rc = c.drmSyncobjCreate(render_fd, 0, &self.handle);
        if (rc != 0) return error.DrmSyncobjCreateFailed;
        errdefer _ = c.drmSyncobjDestroy(render_fd, self.handle);

        var fd: c_int = -1;
        if (c.drmSyncobjHandleToFD(render_fd, self.handle, &fd) != 0) {
            return error.DrmSyncobjHandleToFdFailed;
        }
        self.export_fd = fd;
        return self;
    }

    pub fn deinit(self: *Timeline) void {
        if (self.export_fd >= 0) {
            _ = c.close(self.export_fd);
            self.export_fd = -1;
        }
        if (self.handle != 0) {
            _ = c.drmSyncobjDestroy(self.render_fd, self.handle);
            self.handle = 0;
        }
        self.* = undefined;
    }

    /// Take ownership of the exported fd. Caller is responsible for
    /// closing it (typically after handing it to wayland via
    /// `wp_linux_drm_syncobj_manager_v1.import_timeline`, which dups
    /// it internally; the docs leave fd ownership ambiguous so we
    /// close on our side). Returns -1 if already transferred.
    pub fn takeExportFd(self: *Timeline) c_int {
        const fd = self.export_fd;
        self.export_fd = -1;
        return fd;
    }

    /// Allocate the next acquire/release point pair. Acquire is what
    /// the compositor waits for before reading our buffer; release is
    /// what the compositor signals when it's done. We use point N for
    /// acquire and N for release as well (single-point per frame) —
    /// the compositor signals release independently via its own write
    /// to the timeline, so we use a separate counter for it later if
    /// we ever need to wait on release. For now: acquire only.
    pub fn nextPoint(self: *Timeline) u64 {
        const p = self.next_point;
        self.next_point += 1;
        return p;
    }

    /// Create an EGL fence on the current GL command stream and
    /// transfer its signal into the timeline at `point`. The caller
    /// must hold the GL context current on the calling thread. On
    /// success the timeline point will signal when the GPU finishes
    /// every command queued before `signal` returns.
    pub fn signalFromEgl(
        self: *Timeline,
        egl_display: Display,
        egl_fns: EglFenceFns,
        point: u64,
    ) !void {
        if (!egl_fns.available()) return error.EglFenceSyncUnavailable;

        const sync = egl_fns.create_sync.?(
            egl_display,
            EGL_SYNC_NATIVE_FENCE_ANDROID,
            null,
        );
        if (sync == null) return error.EglCreateSyncFailed;
        defer _ = egl_fns.destroy_sync.?(egl_display, sync);

        const sync_fd = egl_fns.dup_native_fence_fd.?(egl_display, sync);
        if (sync_fd < 0) return error.EglDupNativeFenceFailed;
        defer _ = c.close(sync_fd);

        // Stage in a fresh binary syncobj, then transfer to the
        // timeline at `point`. Direct ImportSyncFile to a timeline
        // syncobj is undefined behaviour; the transfer path is the
        // documented way to drop a sync_file into a specific point.
        var binary_handle: u32 = 0;
        if (c.drmSyncobjCreate(self.render_fd, 0, &binary_handle) != 0) {
            return error.DrmSyncobjCreateFailed;
        }
        defer _ = c.drmSyncobjDestroy(self.render_fd, binary_handle);

        if (c.drmSyncobjImportSyncFile(self.render_fd, binary_handle, sync_fd) != 0) {
            return error.DrmSyncobjImportSyncFileFailed;
        }
        if (c.drmSyncobjTransfer(self.render_fd, self.handle, point, binary_handle, 0, 0) != 0) {
            return error.DrmSyncobjTransferFailed;
        }
    }
};
