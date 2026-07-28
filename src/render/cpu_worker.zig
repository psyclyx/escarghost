const std = @import("std");
const snail = @import("snail");
const atlas_ref_mod = @import("atlas_ref.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const cpu_buffer = @import("cpu_buffer.zig");
const cpu_pipeline = @import("cpu_pipeline.zig");
const perf = @import("../perf.zig");
const log = @import("../log.zig");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("stdlib.h");
});

pub const BufferCount = 2;
const SnapshotSlotCount = 2;

pub const ResponseTag = enum(u8) {
    frame = 1,
    failed = 2,
};

pub const Response = extern struct {
    tag: ResponseTag,
    buffer_index: u8 = 0,
    snapshot_slot: u8 = 0,
    reserved: [1]u8 = [_]u8{0} ** 1,
    serial: u32 = 0,
};

const RequestTag = enum {
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
    descent: f32 = 0,
    serial: u32 = 0,
};

pub const Frontend = struct {
    atlas_ref: *atlas_ref_mod.AtlasRef = undefined,
    response_fds: [2]c_int = [_]c_int{-1} ** 2,
    thread: ?std.Thread = null,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    request_pending: bool = false,
    request: Request = .{ .tag = .quit },
    render_in_flight: bool = false,
    stop_requested: bool = false,
    active: bool = false,
    io: std.Io = undefined,
    // Heap-allocated off to the side (see spawnThread), NOT embedded by value.
    // Each slot's ~5 MB cell buffer would otherwise bloat the Frontend struct
    // so that `self.* = .{}` on the main thread first-touches thousands of
    // fresh pages (~3 ms of minor faults) before we can even paint. As a
    // separate uninitialized allocation the pages fault in lazily during
    // capture, on the render path, only for cells actually written.
    snapshots: *[SnapshotSlotCount]render_snapshot.SharedSnapshot = undefined,
    snapshot_busy: [SnapshotSlotCount]bool = [_]bool{false} ** SnapshotSlotCount,
    buffers: [BufferCount]cpu_buffer.SharedBuffer = undefined,
    buffer_count: usize = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn responseFd(self: *const Frontend) c_int {
        return self.response_fds[0];
    }

    // Spawn the worker thread eagerly, before the GPU worker is started —
    // the GPU driver hooks pthread_create when it loads, making every later
    // spawn cost ~6 ms. The thread parks in cond_wait until start() assigns
    // it real work.
    pub fn spawnThread(self: *Frontend, io: std.Io) !void {
        if (self.thread != null) return;
        self.io = io;
        // Uninitialized on purpose — capture() writes each slot before it's
        // rendered, so the pages fault in lazily on the render path rather
        // than all at once on the startup critical path.
        self.snapshots = std.heap.smp_allocator.create(
            [SnapshotSlotCount]render_snapshot.SharedSnapshot,
        ) catch return error.OutOfMemory;
        errdefer std.heap.smp_allocator.destroy(self.snapshots);
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);

        const pipe_fds = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return error.PipeFailed;
        self.response_fds = pipe_fds;
        errdefer {
            const f0: std.Io.File = .{ .handle = self.response_fds[0], .flags = .{ .nonblocking = false } };
            f0.close(io);
            const f1: std.Io.File = .{ .handle = self.response_fds[1], .flags = .{ .nonblocking = false } };
            f1.close(io);
            self.response_fds = [_]c_int{-1} ** 2;
        }
        self.thread = try std.Thread.spawn(.{}, Frontend.workerMain, .{self});
        log.info(.cpu, "spawned", .{});
    }

    pub fn start(
        self: *Frontend,
        io: std.Io,
        shm_opaque: *anyopaque,
        atlas_ref: *atlas_ref_mod.AtlasRef,
        width: u32,
        height: u32,
    ) !void {
        if (self.active) return;
        try self.spawnThread(io);
        self.atlas_ref = atlas_ref;
        try self.ensureBuffers(shm_opaque, width, height);
        self.active = true;
        log.info(.cpu, "started", .{ .width = width, .height = height });
    }

    pub fn stop(self: *Frontend) void {
        if (!self.active) return;
        {
            _ = c.pthread_mutex_lock(&self.mutex);
            defer _ = c.pthread_mutex_unlock(&self.mutex);
            self.stop_requested = true;
            _ = c.pthread_cond_signal(&self.cond);
        }
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.response_fds[0] >= 0) {
            const f: std.Io.File = .{ .handle = self.response_fds[0], .flags = .{ .nonblocking = false } };
            f.close(self.io);
        }
        if (self.response_fds[1] >= 0) {
            const f: std.Io.File = .{ .handle = self.response_fds[1], .flags = .{ .nonblocking = false } };
            f.close(self.io);
        }
        self.response_fds = [_]c_int{-1} ** 2;
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.destroyBuffers();
        self.active = false;
        self.request_pending = false;
        self.render_in_flight = false;
        self.stop_requested = false;
        self.snapshot_busy = [_]bool{false} ** SnapshotSlotCount;
        std.heap.smp_allocator.destroy(self.snapshots);
        log.info(.cpu, "stopped", .{});
    }

    pub fn ensureBuffers(self: *Frontend, shm_opaque: *anyopaque, width: u32, height: u32) !void {
        if (self.buffer_count > 0 and self.width == width and self.height == height) return;
        if (self.render_in_flight or self.request_pending) return error.Busy;
        self.destroyBuffers();
        errdefer self.destroyBuffers();
        for (0..BufferCount) |i| {
            self.buffers[i] = try cpu_buffer.SharedBuffer.create(shm_opaque, width, height);
            self.buffers[i].attachListener();
            self.buffer_count += 1;
        }
        self.width = width;
        self.height = height;
        log.info(.cpu, "buffers ready", .{
            .width = width,
            .height = height,
            .count = self.buffer_count,
        });
    }

    pub fn freeBufferIndex(self: *Frontend) ?u8 {
        for (0..self.buffer_count) |i| {
            if (self.buffers[i].released) return @intCast(i);
        }
        return null;
    }

    fn freeSnapshotSlot(self: *Frontend) ?u8 {
        for (0..SnapshotSlotCount) |i| {
            if (!self.snapshot_busy[i]) return @intCast(i);
        }
        return null;
    }

    pub fn queueRender(
        self: *Frontend,
        term: anytype,
        width: u32,
        height: u32,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
        baseline_offset: f32,
        descent: f32,
        serial: u32,
        selection: ?@import("../selection.zig").Snapshot,
        scrollbar: ?render_snapshot.ScrollbarOverlay,
        bell: ?render_snapshot.BellOverlay,
    ) !void {
        if (!self.active) return error.Inactive;
        if (self.render_in_flight or self.request_pending) return error.Busy;
        const buffer_index = self.freeBufferIndex() orelse return error.NoFreeBuffer;
        const snapshot_slot = self.freeSnapshotSlot() orelse return error.NoFreeSnapshot;

        var atlas_lease = self.atlas_ref.acquire();
        defer atlas_lease.release();
        try render_snapshot.capture(&self.snapshots[snapshot_slot], term, atlas_lease.get(), selection, scrollbar, bell);
        self.snapshot_busy[snapshot_slot] = true;

        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.request = .{
            .tag = .render,
            .buffer_index = buffer_index,
            .snapshot_slot = snapshot_slot,
            .width = width,
            .height = height,
            .font_size = font_size,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .baseline_offset = baseline_offset,
            .descent = descent,
            .serial = serial,
        };
        self.request_pending = true;
        self.render_in_flight = true;
        _ = c.pthread_cond_signal(&self.cond);
        log.setFrame(.cpu, serial);
        log.debug(.cpu, "queue frame", .{
            .buffer = buffer_index,
            .snapshot = snapshot_slot,
            .width = width,
            .height = height,
        });
    }

    pub fn readResponse(self: *Frontend) !?Response {
        var response: Response = undefined;
        const file = std.Io.File{ .handle = self.response_fds[0], .flags = .{ .nonblocking = false } };
        const n = file.readStreaming(self.io, &.{std.mem.asBytes(&response)}) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return error.ReadFailed,
        };
        if (n < @sizeOf(Response)) return error.ShortRead;

        if (response.snapshot_slot < SnapshotSlotCount) {
            self.snapshot_busy[response.snapshot_slot] = false;
        }
        self.render_in_flight = false;
        return response;
    }

    fn destroyBuffers(self: *Frontend) void {
        for (self.buffers[0..self.buffer_count]) |*buffer| buffer.destroy();
        self.buffer_count = 0;
        self.width = 0;
        self.height = 0;
    }

    fn workerMain(self: *Frontend) void {
        log.info(.cpu, "thread running", .{});
        // The pipeline is created lazily on the first render request: the
        // worker thread is spawned early (before NVIDIA EGL hooks pthread),
        // which is before `start()` assigns `atlas_ref`. It also embeds
        // several-MB scratch arrays, so it lives on the heap, not the stack.
        var ctx: ?*cpu_pipeline.CpuPipeline = null;
        defer if (ctx) |cp| {
            cp.deinit();
            std.heap.smp_allocator.destroy(cp);
        };

        const warn_slow_budget_ms = render_env.parseWarnSlowMs(
            if (c.getenv("SCRGO_WARN_SLOW_MS")) |v| std.mem.sliceTo(v, 0) else null,
        );

        while (true) {
            _ = c.pthread_mutex_lock(&self.mutex);
            while (!self.request_pending and !self.stop_requested) {
                _ = c.pthread_cond_wait(&self.cond, &self.mutex);
            }
            if (self.stop_requested) {
                _ = c.pthread_mutex_unlock(&self.mutex);
                return;
            }
            const request = self.request;
            self.request_pending = false;
            _ = c.pthread_mutex_unlock(&self.mutex);

            switch (request.tag) {
                .quit => return,
                .render => {
                    const timer = perf.Timer.now();
                    const buffer_index = request.buffer_index;
                    const snapshot_slot = request.snapshot_slot;
                    log.setFrame(.cpu, request.serial);
                    if (buffer_index >= self.buffer_count or snapshot_slot >= SnapshotSlotCount) {
                        log.warn(.cpu, "reject frame", .{
                            .buffer = buffer_index,
                            .snapshot = snapshot_slot,
                        });
                        writeResponse(self.response_fds[1], self.io, .{
                            .tag = .failed,
                            .buffer_index = buffer_index,
                            .snapshot_slot = snapshot_slot,
                            .serial = request.serial,
                        });
                        continue;
                    }

                    const buffer = &self.buffers[buffer_index];
                    const map_ptr = buffer.map_ptr orelse {
                        log.warn(.cpu, "missing shm map", .{ .buffer = buffer_index });
                        writeResponse(self.response_fds[1], self.io, .{
                            .tag = .failed,
                            .buffer_index = buffer_index,
                            .snapshot_slot = snapshot_slot,
                            .serial = request.serial,
                        });
                        continue;
                    };

                    var atlas_lease = self.atlas_ref.acquire();
                    defer atlas_lease.release();

                    // Lazily build the pipeline now that atlas_ref is set.
                    const pipeline = ctx orelse blk: {
                        const p = std.heap.smp_allocator.create(cpu_pipeline.CpuPipeline) catch |e| {
                            log.err(.cpu, "alloc failed", .{ .err = e });
                            writeResponse(self.response_fds[1], self.io, .{
                                .tag = .failed,
                                .buffer_index = buffer_index,
                                .snapshot_slot = snapshot_slot,
                                .serial = request.serial,
                            });
                            continue;
                        };
                        cpu_pipeline.CpuPipeline.init(p, std.heap.smp_allocator, self.atlas_ref) catch |e| {
                            std.heap.smp_allocator.destroy(p);
                            log.err(.cpu, "init failed", .{ .err = e });
                            writeResponse(self.response_fds[1], self.io, .{
                                .tag = .failed,
                                .buffer_index = buffer_index,
                                .snapshot_slot = snapshot_slot,
                                .serial = request.serial,
                            });
                            continue;
                        };
                        ctx = p;
                        break :blk p;
                    };

                    pipeline.configure(
                        request.width,
                        request.height,
                        request.font_size,
                        request.cell_width,
                        request.cell_height,
                        request.baseline_offset,
                        request.descent,
                    );
                    pipeline.renderToMemory(
                        @ptrCast(map_ptr),
                        buffer.desc.width,
                        buffer.desc.height,
                        buffer.desc.stride,
                        &self.snapshots[snapshot_slot],
                        atlas_lease.get(),
                    ) catch |e| {
                        log.err(.cpu, "render failed", .{ .buffer = buffer_index, .err = e });
                        writeResponse(self.response_fds[1], self.io, .{
                            .tag = .failed,
                            .buffer_index = buffer_index,
                            .snapshot_slot = snapshot_slot,
                            .serial = request.serial,
                        });
                        continue;
                    };

                    const elapsed_ms = timer.elapsedMs();
                    log.debug(.cpu, "frame complete", .{
                        .buffer = buffer_index,
                        .snapshot = snapshot_slot,
                        .elapsed_ms = log.fmt("{d:.1}", .{elapsed_ms}),
                    });
                    writeResponse(self.response_fds[1], self.io, .{
                        .tag = .frame,
                        .buffer_index = buffer_index,
                        .snapshot_slot = snapshot_slot,
                        .serial = request.serial,
                    });
                    if (warn_slow_budget_ms) |budget_ms| {
                        if (elapsed_ms > @as(f64, @floatFromInt(budget_ms))) {
                            log.warn(.cpu, "slow frame", .{
                                .elapsed_ms = log.fmt("{d:.1}", .{elapsed_ms}),
                                .budget_ms = budget_ms,
                            });
                        }
                    }
                },
            }
        }
    }
};

fn writeResponse(fd: c_int, io: std.Io, response: Response) void {
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.writeStreamingAll(io, std.mem.asBytes(&response)) catch {};
}
