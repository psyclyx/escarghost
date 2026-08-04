//! GPU renderer thread — Vulkan backend.
//!
//! Lifecycle:
//!   Phase 1 — Vulkan context init (no deps, starts at T+0)
//!   Phase 2 — configure(width, height, metrics, font, atlas_ref)
//!             → allocate dmabufs via Vulkan external memory, signal ready
//!   Phase 3 — render loop: snapshot → Vulkan draw → signal frame
//!
//! The threaded startup is preserved: the CPU worker thread spawns
//! before this thread starts (NVIDIA pthread_create hook avoidance),
//! and the atlas thread bootstraps concurrently.

const std = @import("std");
const snail = @import("snail");
const raster = @import("snail-raster");
const gpu_pipeline = @import("gpu_pipeline.zig");
const atlas_ref_mod = @import("atlas_ref.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const glyph_misses = @import("glyph_misses.zig");
const gpu_buffer = @import("gpu_buffer.zig");
const terminal_mod = @import("../terminal.zig");
const row_build = @import("row_build.zig");
const perf = @import("../perf.zig");
const log = @import("../log.zig");
const vk = @import("vk/root.zig");
const memtrack = @import("vk/memtrack.zig");

const c = @cImport({
    // glibc's _FORTIFY_SOURCE inline wrappers (bits/fcntl2.h's variadic
    // open/openat checks) don't survive Zig 0.16's translate-c under
    // ReleaseSafe. Disable fortify for this import — must come before any
    // header pulls in <features.h>, which latches __USE_FORTIFY_LEVEL.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("pthread.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/eventfd.h");
});

fn monotonicNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

// Diagnostic counters (referenced by diagnostics.zig). Currently stubs —
// the Vulkan renderer doesn't populate these yet.
pub var snapshotPhaseAccumNs: u64 = 0;
pub var snapshotPhaseCount: u64 = 0;
pub var captureCellsAccumNs: u64 = 0;

// Per-frame render phase timers (worker thread). Split the ~85ms flood
// frame into shape / prep / upload / emit / render(submitAndWait) so we
// can see what the async-pipelining rework must actually attack.
pub var phaseBuildNs: u64 = 0;
pub var phasePrepNs: u64 = 0;
pub var phaseUploadNs: u64 = 0;
pub var phaseEmitNs: u64 = 0;
pub var phaseRenderNs: u64 = 0;
/// GPU-side execution time (timestamp queries) — the on-GPU portion of
/// `phaseRenderNs`; the difference is submit/wait/driver overhead.
pub var phaseGpuNs: u64 = 0;
pub var phaseFrameCount: u64 = 0;
pub var workerWaitAccumNs: u64 = 0;
pub var workerWaitCount: u64 = 0;
pub var bufferStarvationAccumNs: u64 = 0;
pub var bufferStarvationCount: u64 = 0;

fn readRssKb(io: std.Io) u64 {
    var buf: [256]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(io, "/proc/self/statm", .{}) catch return 0;
    defer file.close(io);
    const n = file.readStreaming(io, &.{&buf}) catch return 0;
    if (n == 0) return 0;
    var it = std.mem.tokenizeAny(u8, buf[0..n], " \n");
    _ = it.next() orelse return 0;
    const resident_pages = std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch return 0;
    return resident_pages * 4;
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
    /// Frame responses only: nonzero when the frame was built with glyph
    /// misses (cells skipped pending async prep).
    had_misses: u8 = 0,
    serial: u32 = 0,
    /// Explicit-sync only: the timeline point the render was signalled at. Main
    /// sets this as the surface acquire+release point before committing. Zero on
    /// the synchronous path.
    acquire_point: u64 = 0,
    /// Decoupled present: nonzero when the resident atlas generation this frame
    /// drew from is behind the latest published one — i.e. an async upload is
    /// (or should be) advancing residency, so main should re-render to show it.
    /// This is what keeps drawing "additional frames until complete" without a
    /// terminal-state or atlas-generation change to trigger it.
    residency_behind: u8 = 0,
    /// Freshest-complete present (R3): nonzero when the worker HELD this frame —
    /// kept the last complete frame on screen rather than present an incomplete
    /// one — so main must not commit; it just retries until the frame completes
    /// or the staleness deadline forces it.
    held: u8 = 0,
};

const RequestTag = enum { configure, render, quit };

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
    descent: f32 = 0,
    serial: u32 = 0,
};

pub const MaxBuffers = gpu_buffer.MaxBuffers;
const SnapshotSlotCount = 2;

pub const GpuWorker = struct {
    thread: ?std.Thread = null,
    mutex: c.pthread_mutex_t = undefined,
    request_event_fd: c_int = -1,
    response_fds: [2]c_int = [_]c_int{-1} ** 2,
    io: std.Io = undefined,

    atlas_ref: ?*atlas_ref_mod.AtlasRef = null,
    request_pending: bool = false,
    request: Request = .{ .tag = .quit },
    stop_requested: bool = false,

    // Heap-allocated off to the side (see start()), NOT embedded by value.
    // Each slot's ~5 MB cell buffer would otherwise bloat the struct so that
    // `self.* = .{}` first-touches thousands of fresh pages (~3 ms of minor
    // faults) on the main thread before we can paint. As a separate
    // uninitialized allocation the pages fault in lazily during capture.
    snapshots: *[SnapshotSlotCount]render_snapshot.SharedSnapshot = undefined,
    snapshot_busy: [SnapshotSlotCount]bool = [_]bool{false} ** SnapshotSlotCount,

    buffer_descs: [MaxBuffers]gpu_buffer.BufferDesc = [_]gpu_buffer.BufferDesc{.{}} ** MaxBuffers,
    buffer_export_fds: [MaxBuffers]c_int = [_]c_int{-1} ** MaxBuffers,
    buffer_count: u8 = 0,

    buffers: [MaxBuffers]gpu_buffer.FrontendBuffer = undefined,
    frontend_buffer_count: usize = 0,

    active: bool = false,
    context_ready: bool = false,
    ready: bool = false,
    render_in_flight: bool = false,
    first_frame_presented: bool = false,

    // ── Explicit sync (opt-in, SCRGO_EXPLICIT_SYNC) ──
    /// Set by main before start(); the worker enables explicit sync only if
    /// this AND the device capability (ctx.explicit_sync) are both true.
    want_explicit_sync: bool = false,
    /// Set true by the worker once the DRM syncobj timelines are live and the
    /// fds below are exported. Main imports them into the compositor.
    explicit_sync_ready: bool = false,
    /// syncobj timeline fds (same process → raw fd ints cross the thread).
    /// Main imports these via import_timeline and closes them.
    es_acquire_fd: c_int = -1,
    es_release_fd: c_int = -1,

    pub fn responseFd(self: *const GpuWorker) c_int {
        return self.response_fds[0];
    }

    fn signalWorker(self: *GpuWorker) void {
        var v: u64 = 1;
        const file: std.Io.File = .{ .handle = self.request_event_fd, .flags = .{ .nonblocking = false } };
        file.writeStreamingAll(self.io, std.mem.asBytes(&v)) catch {};
    }

    pub fn start(self: *GpuWorker, io: std.Io) !void {
        if (self.active) return;
        self.* = .{};
        self.io = io;
        // Uninitialized on purpose — capture() fills each slot before it's
        // rendered, so the pages fault in lazily off the critical path.
        self.snapshots = std.heap.smp_allocator.create(
            [SnapshotSlotCount]render_snapshot.SharedSnapshot,
        ) catch return error.OutOfMemory;
        errdefer std.heap.smp_allocator.destroy(self.snapshots);
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        self.request_event_fd = c.eventfd(0, c.EFD_CLOEXEC);
        if (self.request_event_fd < 0) return error.EventfdFailed;
        errdefer {
            _ = std.c.close(self.request_event_fd);
            self.request_event_fd = -1;
        }

        const pipe_fds = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return error.PipeFailed;
        self.response_fds = pipe_fds;
        errdefer {
            const f0: std.Io.File = .{ .handle = self.response_fds[0], .flags = .{ .nonblocking = false } };
            f0.close(io);
            const f1: std.Io.File = .{ .handle = self.response_fds[1], .flags = .{ .nonblocking = false } };
            f1.close(io);
            self.response_fds = [_]c_int{-1} ** 2;
        }

        self.active = true;
        self.thread = try std.Thread.spawn(.{}, GpuWorker.workerMain, .{self});
    }

    pub fn setSharedState(self: *GpuWorker, atlas_ref: *atlas_ref_mod.AtlasRef) void {
        self.atlas_ref = atlas_ref;
    }

    pub fn requestConfigure(self: *GpuWorker, w: u32, h: u32, font_size: f32, cell_width: f32, cell_height: f32, baseline_offset: f32, descent: f32) !void {
        if (!self.active or !self.context_ready) return error.NotReady;
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
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
            .descent = descent,
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

        var atlas_lease = atlas_ref.acquire();
        defer atlas_lease.release();
        try render_snapshot.capture(&self.snapshots[snapshot_slot], term, atlas_lease.get(), selection, scrollbar, bell);
        self.snapshot_busy[snapshot_slot] = true;

        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.request = .{
            .tag = .render,
            .buffer_index = buffer_index,
            .snapshot_slot = snapshot_slot,
            .serial = serial,
        };
        self.request_pending = true;
        self.render_in_flight = true;
        self.signalWorker();
    }

    pub fn readResponse(self: *GpuWorker) !?Response {
        var response: Response = undefined;
        const file: std.Io.File = .{ .handle = self.response_fds[0], .flags = .{ .nonblocking = false } };
        const n = file.readStreaming(self.io, &.{std.mem.asBytes(&response)}) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return error.ReadFailed,
        };
        if (n < @sizeOf(Response)) return error.ShortRead;

        switch (response.tag) {
            .context_ready => self.context_ready = true,
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
            .failed => {
                self.render_in_flight = false;
            },
            .retry => {
                self.render_in_flight = false;
            },
        }
        return response;
    }

    pub fn installBuffers(self: *GpuWorker, dmabuf: *anyopaque) !void {
        for (0..self.buffer_count) |i| {
            const fd = try dupFd(self.buffer_export_fds[i]);
            self.buffers[i] = try gpu_buffer.FrontendBuffer.create(
                @ptrCast(dmabuf),
                fd,
                self.buffer_descs[i],
            );
            // Attach the wl_buffer.release listener so `released` flips back
            // to true when the compositor is done scanning out — without it,
            // freeBufferIndex() starves after MaxBuffers commits and rendering
            // freezes. Safe here: &self.buffers[i] is a stable address.
            self.buffers[i].attachListener();
        }
        self.frontend_buffer_count = self.buffer_count;
    }

    pub fn destroyFrontendBuffers(self: *GpuWorker) void {
        for (0..self.frontend_buffer_count) |i| {
            self.buffers[i].destroy();
        }
        self.frontend_buffer_count = 0;
    }

    pub fn stop(self: *GpuWorker) void {
        if (!self.active) return;
        // If the EGL/Vulkan context failed to init, the worker may be
        // stuck inside init. detach + _exit to avoid joining a hung thread.
        if (!self.context_ready) {
            if (self.thread) |thread| thread.detach();
            self.thread = null;
            self.active = false;
            c._exit(0);
        }
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.destroyFrontendBuffers();
        for (&self.buffer_export_fds) |*fd| {
            if (fd.* >= 0) {
                _ = std.c.close(fd.*);
                fd.* = -1;
            }
        }
        if (self.response_fds[0] >= 0) {
            const f: std.Io.File = .{ .handle = self.response_fds[0], .flags = .{ .nonblocking = false } };
            f.close(self.io);
        }
        if (self.response_fds[1] >= 0) {
            const f: std.Io.File = .{ .handle = self.response_fds[1], .flags = .{ .nonblocking = false } };
            f.close(self.io);
        }
        self.response_fds = [_]c_int{-1} ** 2;
        if (self.request_event_fd >= 0) {
            _ = std.c.close(self.request_event_fd);
            self.request_event_fd = -1;
        }
        _ = c.pthread_mutex_destroy(&self.mutex);
        std.heap.smp_allocator.destroy(self.snapshots);
        self.active = false;
        self.context_ready = false;
        self.ready = false;
    }

    fn workerMain(self: *GpuWorker) void {
        // Phase 1: Vulkan context init
        var ctx: vk.Context = vk.Context.init(std.heap.smp_allocator) catch |e| {
            log.err(.gpu, "vulkan context init failed", .{ .err = e });
            writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
            return;
        };
        defer ctx.deinit();
        log.info(.gpu, "vulkan context ready", .{});
        writeResponse(self.response_fds[1], self.io, .{ .tag = .context_ready });

        // Phase 2+3: configure + render loop
        var dmabuf_targets: [MaxBuffers]vk.DmabufTarget = undefined;
        var dmabuf_count: usize = 0;
        var renderer: ?vk.Renderer = null;
        defer if (renderer) |*r| r.deinit();
        var device_atlas: ?vk.DeviceAtlas = null;
        defer if (device_atlas) |*da| da.deinit();
        // Heap-allocated: GpuPipeline embeds several-MB scratch arrays that
        // must not live on the worker thread stack.
        var pipeline: ?*gpu_pipeline.GpuPipeline = null;
        defer if (pipeline) |p| {
            p.deinit();
            std.heap.smp_allocator.destroy(p);
        };

        // Atlas GPU upload is cached by snapshot generation; the binding is
        // reissued only when the atlas owner publishes a new snapshot.
        var atlas_binding: ?snail.render.records.Binding = null;
        var frame_slot: u32 = 0;

        // Explicit sync: one command buffer per dmabuf target (async submit
        // needs the cmd to outlive the GPU work), a release point per target,
        // and a monotonic frame point. `explicit_sync` stays null unless both
        // the env flag and the device capability are set.
        var explicit_sync: ?vk.ExplicitSync = null;
        defer if (explicit_sync) |*es| es.deinit();
        var es_cmds: [MaxBuffers]vk.VkCommandBuffer = [_]vk.VkCommandBuffer{null} ** MaxBuffers;
        defer for (es_cmds) |cmd| {
            if (cmd != null) ctx.freeCommandBuffer(cmd);
        };
        // Per-buffer fence signaled by each async render submit — our-side
        // completion signal, used to wait on exactly the outstanding frames
        // before freeing dmabuf targets (resize/teardown) instead of draining
        // the whole device. Created signaled so unused slots don't block.
        var es_fences: [MaxBuffers]vk.VkFence = [_]vk.VkFence{null} ** MaxBuffers;
        defer for (es_fences) |f| {
            if (f != null) ctx.destroyFence(f);
        };
        var release_points: [MaxBuffers]u64 = [_]u64{0} ** MaxBuffers;
        var frame_point: u64 = 0;

        // Freshest-complete present (R3): present the newest all-resident serial;
        // hold an incomplete one (keep the last complete frame on screen, retry
        // as residency fills) until this staleness deadline, then present it with
        // gaps. `SCRGO_HOLD_DEADLINE_MS=0` disables holding (present newest
        // always — the pre-R3 behaviour).
        const hold_deadline_ns: u64 = blk: {
            var ms: u64 = 33; // ~2 frames at 60 Hz
            if (std.c.getenv("SCRGO_HOLD_DEADLINE_MS")) |env| {
                if (std.fmt.parseInt(u64, std.mem.sliceTo(env, 0), 10) catch null) |v| ms = v;
            }
            break :blk ms * std.time.ns_per_ms;
        };
        // Nonzero once we've presented at least one frame (so the first frame is
        // never held — nothing complete is on screen yet), and the monotonic time
        // the current incomplete streak began (reset on every present) — the
        // deadline is measured from there.
        var last_present_ns: u64 = 0;
        var incomplete_since_ns: u64 = 0;

        // Decoupled atlas upload (async present path). The render draws from the
        // RESIDENT generation — whatever is fully uploaded — while a newer
        // generation uploads on its own async submit, so present cost is
        // draw-only and never gated by upload size (see /tmp/glyphstorm.txt).
        // `resident_lease` + `atlas_binding` are the resident pair; at most one
        // upload is in flight (the planner allows a single PendingUpload) and it
        // advances the pair when its fence signals.
        var resident_lease: ?atlas_ref_mod.AtlasRef.Lease = null;
        defer if (resident_lease) |*l| l.release();
        var upload_cmd: vk.VkCommandBuffer = null;
        defer if (upload_cmd != null) ctx.freeCommandBuffer(upload_cmd);
        var upload_fence: vk.VkFence = null;
        defer if (upload_fence != null) ctx.destroyFence(upload_fence);
        var upload_pending: ?vk.DeviceAtlas.PendingUpload = null;
        var upload_lease: ?atlas_ref_mod.AtlasRef.Lease = null;
        defer if (upload_lease) |*l| l.release();
        var upload_in_flight = false;

        var worker_wait_accum_ns: u64 = 0;
        var worker_wait_count: u64 = 0;
        var diag_frame_counter: u64 = 0;

        while (true) {
            const need_wait = blk: {
                _ = c.pthread_mutex_lock(&self.mutex);
                defer _ = c.pthread_mutex_unlock(&self.mutex);
                break :blk !self.request_pending and !self.stop_requested;
            };
            if (need_wait) {
                const wait_t0 = monotonicNs();
                var v: u64 = 0;
                const evfile: std.Io.File = .{ .handle = self.request_event_fd, .flags = .{ .nonblocking = false } };
                _ = evfile.readStreaming(self.io, &.{std.mem.asBytes(&v)}) catch {};
                worker_wait_accum_ns += monotonicNs() - wait_t0;
                worker_wait_count += 1;
            }
            _ = c.pthread_mutex_lock(&self.mutex);
            if (self.stop_requested) {
                _ = c.pthread_mutex_unlock(&self.mutex);
                // Cleanup dmabuf targets. Wait for the outstanding async frames
                // and any in-flight atlas upload first (see the configure
                // handler) — precise fences, not a device drain.
                if (explicit_sync != null) ctx.waitFences(es_fences[0..dmabuf_count], std.time.ns_per_s);
                if (upload_in_flight) ctx.waitFences(&.{upload_fence}, std.time.ns_per_s);
                for (0..dmabuf_count) |i| dmabuf_targets[i].destroy(&ctx);
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
                .quit => {
                    // Wait for outstanding async frames + any in-flight upload
                    // before teardown (see configure handler below).
                    if (explicit_sync != null) ctx.waitFences(es_fences[0..dmabuf_count], std.time.ns_per_s);
                    if (upload_in_flight) ctx.waitFences(&.{upload_fence}, std.time.ns_per_s);
                    for (0..dmabuf_count) |i| dmabuf_targets[i].destroy(&ctx);
                    return;
                },
                .configure => {
                    // Free the old dmabuf targets, then reallocate at the new
                    // size. In the async explicit-sync path renderToTarget
                    // submits without draining the queue (submitSignal), so a
                    // prior frame's command buffer may still be reading these
                    // VkImages on the GPU. Destroying them here would free the
                    // backing memory mid-flight → GPU MMU fault (NVRM Xid 31,
                    // FAULT_PDE) and a lost device that wedges the whole session.
                    // Wait on the outstanding frames' fences first — precise
                    // per-buffer waits, not a device drain, and only the
                    // in-flight ones block (unused fences are signaled).
                    if (explicit_sync != null) ctx.waitFences(es_fences[0..dmabuf_count], std.time.ns_per_s);
                    for (0..dmabuf_count) |i| dmabuf_targets[i].destroy(&ctx);
                    dmabuf_count = 0;

                    for (0..MaxBuffers) |i| {
                        dmabuf_targets[i] = vk.DmabufTarget.create(
                            &ctx,
                            request.width,
                            request.height,
                        ) catch |e| {
                            log.err(.gpu, "dmabuf allocation failed", .{ .buffer = i, .err = e });
                            writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                            break;
                        };
                        dmabuf_count += 1;
                        self.buffer_descs[i] = dmabuf_targets[i].desc;
                        self.buffer_export_fds[i] = dmabuf_targets[i].fd;
                    }
                    self.buffer_count = @intCast(dmabuf_count);

                    if (dmabuf_count == 0) {
                        writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                        continue;
                    }

                    // Create renderer + device atlas (needs the shared page pool
                    // for snail 0.15's flat-buffer sizing).
                    if (device_atlas == null) {
                        const ar = self.atlas_ref orelse {
                            log.err(.gpu, "configure before atlas ref set", .{});
                            writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                            continue;
                        };
                        device_atlas = vk.DeviceAtlas.init(&ctx, std.heap.smp_allocator, ar.pool, .{}) catch |e| {
                            log.err(.gpu, "device atlas init failed", .{ .err = e });
                            writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                            continue;
                        };
                    }

                    // Size the vertex ring to this window's grid: one frame can
                    // emit up to ~8 instances per cell, so a fixed 1 MB ring
                    // dropped whole frames ("VertexBufferFull") once a dense
                    // screen (e.g. tmatrix) outgrew ~14.5k instances. Derive
                    // the grid from the surface + cell metrics and grow to fit.
                    const grid_cols: usize = if (request.cell_width > 0)
                        @intFromFloat(@as(f32, @floatFromInt(request.width)) / request.cell_width)
                    else
                        0;
                    const grid_rows: usize = if (request.cell_height > 0)
                        @intFromFloat(@as(f32, @floatFromInt(request.height)) / request.cell_height)
                    else
                        0;
                    const slot_bytes = vk.Renderer.slotBytesForGrid(grid_cols, grid_rows);

                    if (renderer == null) {
                        renderer = vk.Renderer.init(
                            &ctx,
                            device_atlas.?.descriptorSetLayout(),
                            slot_bytes,
                            2, // double-buffered
                        ) catch |e| {
                            log.err(.gpu, "renderer init failed", .{ .err = e });
                            writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                            continue;
                        };
                        // Persist the freshly-compiled pipeline so subsequent
                        // launches seed from it instead of recompiling.
                        ctx.savePipelineCache(std.heap.smp_allocator);
                    } else {
                        renderer.?.ensureSlotCapacity(&ctx, slot_bytes) catch |e| {
                            log.err(.gpu, "vertex ring resize failed", .{ .err = e });
                            writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                            continue;
                        };
                    }

                    // Row-build / emit pipeline (needs the shared atlas ref).
                    if (self.atlas_ref) |atlas_ref| {
                        if (pipeline == null) {
                            const p = std.heap.smp_allocator.create(gpu_pipeline.GpuPipeline) catch |e| {
                                log.err(.gpu, "pipeline alloc failed", .{ .err = e });
                                writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                                continue;
                            };
                            gpu_pipeline.GpuPipeline.init(p, std.heap.smp_allocator, atlas_ref) catch |e| {
                                std.heap.smp_allocator.destroy(p);
                                log.err(.gpu, "pipeline init failed", .{ .err = e });
                                writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                                continue;
                            };
                            pipeline = p;
                        }
                        pipeline.?.configure(
                            request.width,
                            request.height,
                            request.font_size,
                            request.cell_width,
                            request.cell_height,
                            request.baseline_offset,
                            request.descent,
                        );
                    } else {
                        log.err(.gpu, "configure before atlas ref set", .{});
                        writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                        continue;
                    }

                    // Bring up explicit sync once (opt-in + device capable).
                    // Export the timeline fds for main to import; alloc one
                    // command buffer per dmabuf target for the async submits.
                    if (explicit_sync == null and self.want_explicit_sync and ctx.explicit_sync) {
                        if (vk.ExplicitSync.init(&ctx)) |es_val| {
                            explicit_sync = es_val;
                            const es = &explicit_sync.?;
                            const afd = es.acquireFd() catch -1;
                            const rfd = es.releaseFd() catch -1;
                            var ok = afd >= 0 and rfd >= 0;
                            for (0..dmabuf_count) |i| {
                                es_cmds[i] = ctx.allocCommandBuffer() catch blk: {
                                    ok = false;
                                    break :blk null;
                                };
                                es_fences[i] = ctx.createSignaledFence() catch blk: {
                                    ok = false;
                                    break :blk null;
                                };
                            }
                            // One dedicated command buffer + fence for the async
                            // atlas upload that advances residency off the
                            // present critical path.
                            upload_cmd = ctx.allocCommandBuffer() catch blk: {
                                ok = false;
                                break :blk null;
                            };
                            upload_fence = ctx.createSignaledFence() catch blk: {
                                ok = false;
                                break :blk null;
                            };
                            if (ok) {
                                self.es_acquire_fd = afd;
                                self.es_release_fd = rfd;
                                self.explicit_sync_ready = true;
                                log.info(.gpu, "explicit sync ready", .{});
                            } else {
                                if (afd >= 0) _ = std.c.close(afd);
                                if (rfd >= 0) _ = std.c.close(rfd);
                                explicit_sync.?.deinit();
                                explicit_sync = null;
                                log.warn(.gpu, "explicit sync setup failed; using sync path", .{});
                            }
                        } else |e| {
                            log.warn(.gpu, "explicit sync init failed; using sync path", .{ .err = e });
                        }
                    }

                    log.info(.gpu, "configured", .{
                        .width = request.width,
                        .height = request.height,
                        .buffers = dmabuf_count,
                        .explicit_sync = explicit_sync != null,
                    });
                    writeResponse(self.response_fds[1], self.io, .{ .tag = .ready });
                },
                .render => {
                    const buffer_index = request.buffer_index;
                    const snapshot_slot = request.snapshot_slot;
                    const fail = Response{
                        .tag = .failed,
                        .buffer_index = buffer_index,
                        .snapshot_slot = snapshot_slot,
                        .serial = request.serial,
                    };

                    if (renderer == null or device_atlas == null or pipeline == null or self.atlas_ref == null) {
                        writeResponse(self.response_fds[1], self.io, fail);
                        continue;
                    }
                    if (buffer_index >= dmabuf_count or snapshot_slot >= SnapshotSlotCount) {
                        writeResponse(self.response_fds[1], self.io, fail);
                        continue;
                    }
                    // GPU present requires explicit sync. Main only selects the
                    // GPU path when the compositor advertises wp_linux_drm_syncobj
                    // (else it stays on the CPU/SHM path), so this is defensive.
                    const es = if (explicit_sync) |*e| e else {
                        writeResponse(self.response_fds[1], self.io, fail);
                        continue;
                    };

                    const atlas_ref = self.atlas_ref.?;
                    // Re-read faces each frame: auto-fallback (in extend) can
                    // swap the shared `Faces` when a miss run needs a new font.
                    const faces = atlas_ref.faces orelse {
                        writeResponse(self.response_fds[1], self.io, fail);
                        continue;
                    };

                    // Decoupled present: reap a completed async atlas upload and
                    // advance the resident generation to it. The render below
                    // draws from whatever is resident, never gated by upload.
                    var atlas_uploaded = false;
                    if (upload_in_flight and ctx.fenceReady(upload_fence)) {
                        if (device_atlas.?.commitUpload(&upload_pending.?)) |new_binding| {
                            if (atlas_binding) |b| device_atlas.?.releaseBinding(b);
                            atlas_binding = new_binding;
                            if (resident_lease) |*l| l.release();
                            resident_lease = upload_lease;
                            atlas_uploaded = true;
                        } else |e| {
                            log.err(.gpu, "atlas commit failed", .{ .err = e });
                            if (upload_lease) |*l| l.release();
                        }
                        upload_lease = null;
                        device_atlas.?.freeStaging(&upload_pending.?);
                        upload_pending = null;
                        upload_in_flight = false;
                    }

                    // Render from the resident generation — whatever is fully
                    // uploaded — bootstrapped synchronously on the very first
                    // frame. Newer generations upload asynchronously (kick below,
                    // reaped above); the render never waits on an upload.
                    if (resident_lease == null) {
                        var boot = atlas_ref.acquire();
                        if (device_atlas.?.upload(boot.get())) |b| {
                            if (atlas_binding) |old| device_atlas.?.releaseBinding(old);
                            atlas_binding = b;
                            resident_lease = boot;
                            atlas_uploaded = true;
                        } else |e| {
                            log.err(.gpu, "atlas bootstrap upload failed", .{ .err = e });
                            boot.release();
                        }
                    }
                    if (resident_lease == null) {
                        writeResponse(self.response_fds[1], self.io, fail);
                        continue;
                    }
                    const cur_atlas = resident_lease.?.get();

                    log.setFrame(.gpu, request.serial);
                    var render_ok = true;
                    var phase_t = perf.Timer.now();
                    const had_misses = pipeline.?.buildShapes(cur_atlas, faces, &self.snapshots[snapshot_slot]) catch |e| blk: {
                        log.err(.gpu, "build failed", .{ .err = e });
                        render_ok = false;
                        break :blk false;
                    };
                    const build_ns = phase_t.elapsedNs();
                    phaseBuildNs += build_ns;
                    // Hand newly-seen glyphs to the async prep thread and move on
                    // — the frame never blocks on prep. Glyphs not yet resident
                    // are skipped per-glyph by emit and appear on a later frame
                    // once prep publishes and the async upload makes them
                    // resident. `faces` is re-read next frame so an auto-fallback
                    // face added during prep takes effect a frame later.
                    phase_t = perf.Timer.now();
                    if (render_ok and had_misses) atlas_ref.requestPrep(pipeline.?.misses.text());
                    phasePrepNs += phase_t.elapsedNs();

                    // Advance residency: kick the next async upload if a newer
                    // generation exists and none is in flight. Runs before the
                    // present/hold decision so a HELD frame still advances toward
                    // completeness. Its delta copies target disjoint new pages
                    // and same-queue order keeps it safe against this frame's
                    // render below; reaped at the top of a later frame.
                    if (!upload_in_flight and resident_lease != null) {
                        var latest = atlas_ref.acquire();
                        var adopted = false;
                        defer if (!adopted) latest.release();
                        if (latest.generation() > resident_lease.?.generation()) kick: {
                            ctx.beginOneTime(upload_cmd) catch break :kick;
                            var p = device_atlas.?.recordUpload(latest.get(), upload_cmd) catch |e| {
                                log.err(.gpu, "atlas record upload failed", .{ .err = e });
                                ctx.endCmd(upload_cmd) catch {};
                                break :kick;
                            };
                            ctx.endCmd(upload_cmd) catch {
                                device_atlas.?.abortUpload(&p);
                                device_atlas.?.freeStaging(&p);
                                break :kick;
                            };
                            ctx.resetFence(upload_fence);
                            ctx.submitFenced(upload_cmd, upload_fence) catch |e| {
                                log.err(.gpu, "atlas upload submit failed", .{ .err = e });
                                device_atlas.?.abortUpload(&p);
                                device_atlas.?.freeStaging(&p);
                                break :kick;
                            };
                            upload_pending = p;
                            upload_lease = latest;
                            upload_in_flight = true;
                            adopted = true;
                        }
                    }

                    // Residency lags the latest atlas when this frame drew from an
                    // older resident generation — the kick above (or a prior one
                    // in flight) advances it, so main should re-render.
                    const residency_behind = resident_lease != null and
                        resident_lease.?.generation() < atlas_ref.loadGeneration();

                    // R3 present policy: present the newest all-resident serial.
                    // If this frame is incomplete and we presented recently, HOLD
                    // — keep the last complete frame on screen and retry as
                    // residency fills — until the staleness deadline, then present
                    // with gaps. A held frame skips render+present, so no buffer
                    // is consumed and no release point is left dangling.
                    if (render_ok and had_misses and hold_deadline_ns != 0 and last_present_ns != 0) {
                        const now = monotonicNs();
                        if (incomplete_since_ns == 0) incomplete_since_ns = now;
                        if ((now -% incomplete_since_ns) < hold_deadline_ns) {
                            writeResponse(self.response_fds[1], self.io, .{
                                .tag = .frame,
                                .buffer_index = buffer_index,
                                .snapshot_slot = snapshot_slot,
                                .had_misses = 1,
                                .serial = request.serial,
                                .residency_behind = @intFromBool(residency_behind),
                                .held = 1,
                            });
                            continue;
                        }
                        // Deadline exceeded — present with gaps (fall through).
                    }

                    // Upload is off the render critical path now (async, above),
                    // so the render frame's own upload time is zero.
                    const upload_ns: u64 = 0;
                    phaseUploadNs += upload_ns;
                    phase_t = perf.Timer.now();
                    if (render_ok) {
                        pipeline.?.emitBuilt(cur_atlas, atlas_binding.?, &self.snapshots[snapshot_slot]) catch |e| {
                            log.err(.gpu, "emit failed", .{ .err = e });
                            render_ok = false;
                        };
                    }
                    const emit_ns = phase_t.elapsedNs();
                    phaseEmitNs += emit_ns;
                    if (!render_ok) {
                        writeResponse(self.response_fds[1], self.io, fail);
                        continue;
                    }

                    // sRGB attachment: the clear color is specified in linear
                    // light; the hardware encodes it to sRGB on store.
                    const clear_color = self.snapshots[snapshot_slot].header.default_bg.toLinearFloat4(1.0);

                    phase_t = perf.Timer.now();
                    var acquire_point: u64 = 0;
                    var gpu_ns: u64 = 0;
                    {
                        // Wait for the compositor to release this buffer's prior
                        // frame (implies that render + its cmd buffer are done),
                        // render async signalling render_done, then place that
                        // completion on the acquire timeline for the compositor.
                        es.waitRelease(release_points[buffer_index], std.time.ns_per_s);
                        // The release wait implies the prior render into this
                        // buffer completed, so its fence is signaled — safe to
                        // reset for this frame's submission.
                        ctx.resetFence(es_fences[buffer_index]);
                        frame_point += 1;
                        gpu_ns = vk.renderToTarget(
                            &renderer.?,
                            &ctx,
                            &dmabuf_targets[buffer_index],
                            device_atlas.?.descriptorSet(),
                            frame_slot,
                            clear_color,
                            device_atlas.?.atlasPageTexels(),
                            pipeline.?.emittedInstances(),
                            pipeline.?.emittedBatches(),
                            .{ .cmd = es_cmds[buffer_index], .signal_sem = es.render_done, .fence = es_fences[buffer_index] },
                        ) catch |e| {
                            log.err(.gpu, "render submit failed", .{ .err = e });
                            writeResponse(self.response_fds[1], self.io, fail);
                            continue;
                        };
                        es.signalAcquire(frame_point) catch |e| {
                            log.err(.gpu, "acquire signal failed", .{ .err = e });
                            writeResponse(self.response_fds[1], self.io, fail);
                            continue;
                        };
                        release_points[buffer_index] = frame_point;
                        acquire_point = frame_point;
                    }
                    const render_ns = phase_t.elapsedNs();
                    phaseRenderNs += render_ns;
                    phaseGpuNs += gpu_ns;
                    phaseFrameCount += 1;
                    frame_slot +%= 1;
                    last_present_ns = monotonicNs();
                    incomplete_since_ns = 0; // presented — next incomplete streak restarts the deadline

                    writeResponse(self.response_fds[1], self.io, .{
                        .tag = .frame,
                        .buffer_index = buffer_index,
                        .snapshot_slot = snapshot_slot,
                        .had_misses = @intFromBool(had_misses),
                        .serial = request.serial,
                        .acquire_point = acquire_point,
                        .residency_behind = @intFromBool(residency_behind),
                        .held = 0,
                    });

                    // Per-frame phase split (mirrors the CPU worker's "frame
                    // complete"). `render` is CPU wall time around the
                    // synchronous Vulkan submit; `gpu` is the actual on-GPU
                    // execution from timestamp queries (0 = unsupported);
                    // `upload` is ~0 unless the atlas generation changed.
                    const ms = std.time.ns_per_ms;
                    log.debug(.gpu, "frame complete", .{
                        .buffer = buffer_index,
                        .build_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(build_ns)) / ms}),
                        .upload_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(upload_ns)) / ms}),
                        .emit_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(emit_ns)) / ms}),
                        .render_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(render_ns)) / ms}),
                        .gpu_ms = log.fmt("{d:.2}", .{@as(f64, @floatFromInt(gpu_ns)) / ms}),
                        .total_ms = log.fmt("{d:.1}", .{@as(f64, @floatFromInt(build_ns + upload_ns + emit_ns + render_ns)) / ms}),
                        .atlas_uploaded = atlas_uploaded,
                        .misses = had_misses,
                    });

                    diag_frame_counter += 1;
                    if (diag_frame_counter % 60 == 0) {
                        log.info(.diag, "rss sample", .{
                            .frame = diag_frame_counter,
                            .rss_kib = readRssKb(self.io),
                            .staging_out = memtrack.staging.outstanding(),
                            .staging_mib = memtrack.staging.liveMib(),
                            .host_buf_mib = memtrack.host_buffer.liveMib(),
                            .cmd_out = memtrack.cmd_bufs.outstanding(),
                        });
                    }
                },
            }
        }
    }
};

fn writeResponse(fd: c_int, io: std.Io, response: Response) void {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.writeStreamingAll(io, std.mem.asBytes(&response)) catch {};
}

fn dupFd(fd: c_int) !c_int {
    if (fd < 0) return error.NoFd;
    const new_fd = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (new_fd < 0) return error.DupFailed;
    return @intCast(new_fd);
}
