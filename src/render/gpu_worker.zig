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
    reserved: [1]u8 = [_]u8{0} ** 1,
    serial: u32 = 0,
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

    snapshots: [SnapshotSlotCount]render_snapshot.SharedSnapshot = [_]render_snapshot.SharedSnapshot{.{}} ** SnapshotSlotCount,
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
        var cached_atlas_gen: u64 = 0;
        var frame_slot: u32 = 0;

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
                // Cleanup dmabuf targets
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
                    for (0..dmabuf_count) |i| dmabuf_targets[i].destroy(&ctx);
                    return;
                },
                .configure => {
                    // Allocate dmabuf targets via Vulkan
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

                    // Create renderer + device atlas
                    if (device_atlas == null) {
                        device_atlas = vk.DeviceAtlas.init(&ctx, std.heap.smp_allocator, .{}) catch |e| {
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

                    log.info(.gpu, "configured", .{
                        .width = request.width,
                        .height = request.height,
                        .buffers = dmabuf_count,
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

                    const atlas_ref = self.atlas_ref.?;
                    var lease = atlas_ref.acquire();
                    defer lease.release();
                    // Re-read each frame: auto-fallback (in extend) can swap
                    // the shared `Faces` when a miss run needs a new font, and
                    // it takes effect on the next frame's build.
                    const faces = atlas_ref.faces orelse {
                        writeResponse(self.response_fds[1], self.io, fail);
                        continue;
                    };

                    // Shape the frame, growing the atlas on glyph misses. No
                    // emit happens during the miss→extend cycle (that would
                    // fail per row and spam warnings); we upload + emit once,
                    // below, against the completed atlas.
                    var cur_atlas = lease.get();
                    var extra_lease: ?atlas_ref_mod.AtlasRef.Lease = null;
                    defer if (extra_lease) |*l| l.release();

                    var render_ok = true;
                    var phase_t = perf.Timer.now();
                    const had_misses = pipeline.?.buildShapes(cur_atlas, faces, &self.snapshots[snapshot_slot]) catch |e| blk: {
                        log.err(.gpu, "build failed", .{ .err = e });
                        render_ok = false;
                        break :blk false;
                    };
                    phaseBuildNs += phase_t.elapsedNs();
                    // Prep at most one bounded batch of newly-seen glyphs, then
                    // present against the (possibly extended) atlas. We do NOT
                    // loop-until-prepped or re-shape: a full screen of novel
                    // glyphs would stall the frame ~1s. Glyphs not yet prepped
                    // are skipped per-glyph by emit and fill in on later sampled
                    // frames as the atlas catches up. `faces` is re-read at the
                    // top of the next frame, so an auto-fallback face added by
                    // extend takes effect one frame later. See glyph_misses.MaxBytes.
                    phase_t = perf.Timer.now();
                    if (render_ok and had_misses) {
                        const result = atlas_ref.extend(cur_atlas, pipeline.?.misses.text()) catch null;
                        if (result != null and result.? == .extended) {
                            if (extra_lease) |*l| l.release();
                            extra_lease = atlas_ref.acquire();
                            cur_atlas = extra_lease.?.get();
                        }
                    }
                    phasePrepNs += phase_t.elapsedNs();

                    // Upload the completed atlas (cached by generation), emit.
                    phase_t = perf.Timer.now();
                    if (render_ok) {
                        const cur_gen = atlas_ref.loadGeneration();
                        if (atlas_binding == null or cur_gen != cached_atlas_gen) {
                            if (atlas_binding) |b| device_atlas.?.releaseBinding(b);
                            atlas_binding = device_atlas.?.upload(atlas_ref.pool, cur_atlas) catch |e| blk: {
                                log.err(.gpu, "atlas upload failed", .{ .err = e });
                                render_ok = false;
                                break :blk null;
                            };
                            if (render_ok) cached_atlas_gen = cur_gen;
                        }
                    }
                    phaseUploadNs += phase_t.elapsedNs();
                    phase_t = perf.Timer.now();
                    if (render_ok) {
                        pipeline.?.emitBuilt(cur_atlas, atlas_binding.?, &self.snapshots[snapshot_slot]) catch |e| {
                            log.err(.gpu, "emit failed", .{ .err = e });
                            render_ok = false;
                        };
                    }
                    phaseEmitNs += phase_t.elapsedNs();
                    if (!render_ok) {
                        writeResponse(self.response_fds[1], self.io, fail);
                        continue;
                    }

                    // sRGB attachment: the clear color is specified in linear
                    // light; the hardware encodes it to sRGB on store.
                    const clear_color = self.snapshots[snapshot_slot].header.default_bg.toLinearFloat4(1.0);

                    phase_t = perf.Timer.now();
                    vk.renderToTarget(
                        &renderer.?,
                        &ctx,
                        &dmabuf_targets[buffer_index],
                        device_atlas.?.descriptorSet(),
                        frame_slot,
                        clear_color,
                        pipeline.?.emittedInstances(),
                        pipeline.?.emittedBatches(),
                    ) catch |e| {
                        log.err(.gpu, "render submit failed", .{ .err = e });
                        writeResponse(self.response_fds[1], self.io, fail);
                        continue;
                    };
                    phaseRenderNs += phase_t.elapsedNs();
                    phaseFrameCount += 1;
                    frame_slot +%= 1;

                    writeResponse(self.response_fds[1], self.io, .{
                        .tag = .frame,
                        .buffer_index = buffer_index,
                        .snapshot_slot = snapshot_slot,
                        .serial = request.serial,
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
