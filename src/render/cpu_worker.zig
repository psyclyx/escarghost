const std = @import("std");
const snail = @import("snail");
const atlas_ref_mod = @import("atlas_ref.zig");
const atlas_worker = @import("atlas_worker.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const cpu_buffer = @import("cpu_buffer.zig");
const cpu_pipeline = @import("cpu_pipeline.zig");
const perf = @import("../perf.zig");
const log = @import("../log.zig");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

fn rendererDebugOptions() render_env.RendererDebug {
    if (c.getenv("SCRGO_LOG")) |value|
        return render_env.parseRendererDebug(std.mem.sliceTo(value, 0));
    return .{};
}

fn cpuRendererDebugEnabled() bool {
    return rendererDebugOptions().renderers;
}

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
    serial: u32 = 0,
};

pub const Frontend = struct {
    atlas_ref: *atlas_ref_mod.AtlasRef = undefined,
    atlas_thread: ?*atlas_worker.AtlasWorker = null,
    response_fds: [2]c_int = [_]c_int{-1} ** 2,
    thread: ?std.Thread = null,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    request_pending: bool = false,
    request: Request = .{ .tag = .quit },
    render_in_flight: bool = false,
    stop_requested: bool = false,
    active: bool = false,
    snapshots: [SnapshotSlotCount]render_snapshot.SharedSnapshot = [_]render_snapshot.SharedSnapshot{.{}} ** SnapshotSlotCount,
    snapshot_busy: [SnapshotSlotCount]bool = [_]bool{false} ** SnapshotSlotCount,
    buffers: [BufferCount]cpu_buffer.SharedBuffer = undefined,
    buffer_count: usize = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn responseFd(self: *const Frontend) c_int {
        return self.response_fds[0];
    }

    // Spawn the worker thread eagerly, before anything that might install
    // pthread_create wrappers (the NVIDIA EGL stack hooks libpthread when
    // it loads, costing every later spawn ~6 ms). The thread parks in
    // cond_wait until start() assigns it real work.
    pub fn spawnThread(self: *Frontend) !void {
        if (self.thread != null) return;
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);

        var pipe_fds: [2]c_int = undefined;
        if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        self.response_fds = pipe_fds;
        errdefer {
            _ = c.close(self.response_fds[0]);
            _ = c.close(self.response_fds[1]);
            self.response_fds = [_]c_int{-1} ** 2;
        }
        self.thread = try std.Thread.spawn(.{}, Frontend.workerMain, .{self});
        if (cpuRendererDebugEnabled()) log.info(.cpu, "spawned", .{});
    }

    pub fn start(
        self: *Frontend,
        shm_opaque: *anyopaque,
        atlas_ref: *atlas_ref_mod.AtlasRef,
        atlas_thread: *atlas_worker.AtlasWorker,
        width: u32,
        height: u32,
    ) !void {
        if (self.active) return;
        try self.spawnThread();
        self.atlas_ref = atlas_ref;
        self.atlas_thread = atlas_thread;
        try self.ensureBuffers(shm_opaque, width, height);
        self.active = true;
        if (cpuRendererDebugEnabled()) log.info(.cpu, "started  width={}  height={}", .{ width, height });
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
        if (self.response_fds[0] >= 0) _ = c.close(self.response_fds[0]);
        if (self.response_fds[1] >= 0) _ = c.close(self.response_fds[1]);
        self.response_fds = [_]c_int{-1} ** 2;
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.destroyBuffers();
        self.active = false;
        self.request_pending = false;
        self.render_in_flight = false;
        self.stop_requested = false;
        self.snapshot_busy = [_]bool{false} ** SnapshotSlotCount;
        if (cpuRendererDebugEnabled()) log.info(.cpu, "stopped", .{});
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
        if (cpuRendererDebugEnabled()) log.info(.cpu, "buffers ready  width={}  height={}  count={}", .{ width, height, self.buffer_count });
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
        serial: u32,
        selection: ?@import("../selection.zig").Snapshot,
        scrollbar: ?render_snapshot.ScrollbarOverlay,
    ) !void {
        if (!self.active) return error.Inactive;
        if (self.render_in_flight or self.request_pending) return error.Busy;
        const buffer_index = self.freeBufferIndex() orelse return error.NoFreeBuffer;
        const snapshot_slot = self.freeSnapshotSlot() orelse return error.NoFreeSnapshot;

        var atlas_lease = self.atlas_ref.acquire();
        defer atlas_lease.release();
        try render_snapshot.capture(&self.snapshots[snapshot_slot], term, atlas_lease.get(), selection, scrollbar);
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
            .serial = serial,
        };
        self.request_pending = true;
        self.render_in_flight = true;
        _ = c.pthread_cond_signal(&self.cond);
        log.setFrame(.cpu, serial);
        if (cpuRendererDebugEnabled()) log.info(.cpu, "queue frame  buffer={}  snapshot={}  width={}  height={}", .{
            buffer_index,
            snapshot_slot,
            width,
            height,
        });
    }

    pub fn readResponse(self: *Frontend) !?Response {
        var response: Response = undefined;
        const rc = c.read(self.response_fds[0], &response, @sizeOf(Response));
        if (rc == 0) return null;
        if (rc < 0) return error.ReadFailed;
        if (@as(usize, @intCast(rc)) < @sizeOf(Response)) return error.ShortRead;

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
        if (cpuRendererDebugEnabled()) log.info(.cpu, "thread running", .{});
        var ctx = cpu_pipeline.CpuPipeline.init(std.heap.smp_allocator) catch |e| {
            log.err(.cpu, "init failed  err={s}", .{@errorName(e)});
            return;
        };
        defer ctx.deinit();

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
                        log.warn(.cpu, "reject frame  buffer={}  snapshot={}", .{
                            buffer_index, snapshot_slot,
                        });
                        writeResponse(self.response_fds[1], .{
                            .tag = .failed,
                            .buffer_index = buffer_index,
                            .snapshot_slot = snapshot_slot,
                            .serial = request.serial,
                        });
                        continue;
                    }

                    const buffer = &self.buffers[buffer_index];
                    const map_ptr = buffer.map_ptr orelse {
                        log.warn(.cpu, "missing shm map  buffer={}", .{buffer_index});
                        writeResponse(self.response_fds[1], .{
                            .tag = .failed,
                            .buffer_index = buffer_index,
                            .snapshot_slot = snapshot_slot,
                            .serial = request.serial,
                        });
                        continue;
                    };

                    var atlas_lease = self.atlas_ref.acquire();
                    defer atlas_lease.release();

                    const misses = ctx.renderToMemory(
                        map_ptr,
                        buffer.desc.width,
                        buffer.desc.height,
                        buffer.desc.stride,
                        &self.snapshots[snapshot_slot],
                        &atlas_lease,
                        request.font_size,
                        request.cell_width,
                        request.cell_height,
                    ) catch |e| {
                        log.err(.cpu, "render failed  buffer={}  err={s}", .{ buffer_index, @errorName(e) });
                        writeResponse(self.response_fds[1], .{
                            .tag = .failed,
                            .buffer_index = buffer_index,
                            .snapshot_slot = snapshot_slot,
                            .serial = request.serial,
                        });
                        continue;
                    };

                    if (!misses.isEmpty()) {
                        if (self.atlas_thread) |thread| thread.requestMany(&misses);
                    }
                    const elapsed_ms = timer.elapsedMs();
                    if (cpuRendererDebugEnabled()) log.info(.cpu, "frame complete  buffer={}  snapshot={}  elapsed_ms={d:.1}", .{
                        buffer_index, snapshot_slot, elapsed_ms,
                    });
                    writeResponse(self.response_fds[1], .{
                        .tag = .frame,
                        .buffer_index = buffer_index,
                        .snapshot_slot = snapshot_slot,
                        .serial = request.serial,
                    });
                    if (warn_slow_budget_ms) |budget_ms| {
                        if (elapsed_ms > @as(f64, @floatFromInt(budget_ms))) {
                            log.warn(.cpu, "slow frame  elapsed_ms={d:.1}  budget_ms={}", .{
                                elapsed_ms, budget_ms,
                            });
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
