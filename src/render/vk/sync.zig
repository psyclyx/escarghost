//! Wayland explicit sync via DRM timeline syncobjs.
//!
//! Bridges a Vulkan render-completion semaphore to a DRM syncobj timeline so
//! the compositor waits on our GPU render (the *acquire* point) instead of us
//! blocking on `submitAndWait`, and signals a *release* point we wait on before
//! reusing a buffer. Two timelines: `acquire` (we signal, compositor waits) and
//! `release` (compositor signals, we wait). A per-frame monotonic point value
//! sequences both.
//!
//! Bridge mechanism (portable, NVIDIA-friendly): the render submit signals a
//! binary VkSemaphore; we export its pending signal as a `SYNC_FD` sync_file,
//! import that into a scratch binary syncobj, and `TRANSFER` it onto the
//! acquire timeline at the frame's point. The release point is CPU-waited via
//! `drmSyncobjTimelineWait` before a buffer is reused.

const std = @import("std");
const log = @import("../../log.zig");
const Context = @import("context.zig").Context;
const vk = @import("vulkan.zig").vk;

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("xf86drm.h");
    @cInclude("drm.h");
});

pub const ExplicitSync = struct {
    ctx: *const Context,
    drm_fd: c_int = -1,
    acquire: u32 = 0, // timeline syncobj handle (we signal)
    release: u32 = 0, // timeline syncobj handle (compositor signals)
    scratch: u32 = 0, // binary syncobj: staging for SYNC_FD → timeline transfer
    render_done: vk.VkSemaphore = null, // binary, SYNC_FD-exportable

    pub fn init(ctx: *const Context) !ExplicitSync {
        const fd = c.open("/dev/dri/renderD128", c.O_RDWR | c.O_CLOEXEC);
        if (fd < 0) return error.DrmOpenFailed;
        errdefer _ = c.close(fd);

        var acquire: u32 = 0;
        var release: u32 = 0;
        var scratch: u32 = 0;
        if (c.drmSyncobjCreate(fd, 0, &acquire) != 0) return error.SyncobjCreateFailed;
        errdefer _ = c.drmSyncobjDestroy(fd, acquire);
        if (c.drmSyncobjCreate(fd, 0, &release) != 0) return error.SyncobjCreateFailed;
        errdefer _ = c.drmSyncobjDestroy(fd, release);
        if (c.drmSyncobjCreate(fd, 0, &scratch) != 0) return error.SyncobjCreateFailed;
        errdefer _ = c.drmSyncobjDestroy(fd, scratch);

        // Binary semaphore each render submit signals; exported as SYNC_FD.
        const export_info = vk.VkExportSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
            .handleTypes = vk.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
        };
        const sem_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &export_info,
        };
        var sem: vk.VkSemaphore = null;
        if (vk.vkCreateSemaphore(ctx.device, &sem_info, null, &sem) != vk.VK_SUCCESS) return error.SemaphoreCreateFailed;

        return .{ .ctx = ctx, .drm_fd = fd, .acquire = acquire, .release = release, .scratch = scratch, .render_done = sem };
    }

    pub fn deinit(self: *ExplicitSync) void {
        if (self.render_done != null) vk.vkDestroySemaphore(self.ctx.device, self.render_done, null);
        if (self.drm_fd >= 0) {
            _ = c.drmSyncobjDestroy(self.drm_fd, self.scratch);
            _ = c.drmSyncobjDestroy(self.drm_fd, self.release);
            _ = c.drmSyncobjDestroy(self.drm_fd, self.acquire);
            _ = c.close(self.drm_fd);
        }
    }

    /// Export the acquire/release timeline as a syncobj fd to hand to
    /// `wp_linux_drm_syncobj_manager_v1.import_timeline`. Caller closes it.
    pub fn acquireFd(self: *const ExplicitSync) !c_int {
        return handleToFd(self.drm_fd, self.acquire);
    }
    pub fn releaseFd(self: *const ExplicitSync) !c_int {
        return handleToFd(self.drm_fd, self.release);
    }

    /// Place `render_done`'s pending signal on the acquire timeline at `point`.
    /// Call right after the render submit that signals `render_done`; exporting
    /// resets the semaphore to unsignaled, so it's reusable next frame.
    pub fn signalAcquire(self: *ExplicitSync, point: u64) !void {
        var sync_fd: c_int = -1;
        const gi = vk.VkSemaphoreGetFdInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
            .semaphore = self.render_done,
            .handleType = vk.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
        };
        if (vk.vkGetSemaphoreFdKHR(self.ctx.device, &gi, &sync_fd) != vk.VK_SUCCESS) return error.SemaphoreExportFailed;
        if (sync_fd < 0) return error.SemaphoreExportFailed; // -1 → already signaled/empty
        defer _ = c.close(sync_fd);
        if (c.drmSyncobjImportSyncFile(self.drm_fd, self.scratch, sync_fd) != 0) return error.ImportSyncFileFailed;
        if (c.drmSyncobjTransfer(self.drm_fd, self.acquire, point, self.scratch, 0, 0) != 0) return error.SyncobjTransferFailed;
    }

    /// CPU-wait until the compositor signals the release timeline at `point`.
    /// `point == 0` (a never-committed buffer) returns immediately. On timeout
    /// it logs and returns (accept a possible stale read over a hard hang).
    pub fn waitRelease(self: *ExplicitSync, point: u64, timeout_ns: i64) void {
        if (point == 0) return;
        var handle = self.release;
        var pt = point;
        const r = c.drmSyncobjTimelineWait(
            self.drm_fd,
            &handle,
            &pt,
            1,
            absTimeout(timeout_ns),
            c.DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT,
            null,
        );
        if (r != 0) log.warn(.gpu, "release wait failed", .{ .point = point, .rc = r });
    }
};

fn handleToFd(drm_fd: c_int, handle: u32) !c_int {
    var fd: c_int = -1;
    if (c.drmSyncobjHandleToFD(drm_fd, handle, &fd) != 0) return error.HandleToFdFailed;
    return fd;
}

/// Absolute CLOCK_MONOTONIC deadline `timeout_ns` from now, in ns —
/// `drmSyncobjTimelineWait`'s expected form.
fn absTimeout(timeout_ns: i64) i64 {
    var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.tv_nsec)) + timeout_ns;
}
