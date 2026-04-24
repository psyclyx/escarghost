const std = @import("std");
const atlas_owner = @import("atlas_owner.zig");
const renderer_mod = @import("renderer.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const shared_shm = @import("shared_shm.zig");
const shm_render = @import("shm_render.zig");
const perf = @import("perf.zig");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

fn rendererDebugOptions() render_env.RendererDebug {
    if (c.getenv("MOLLUSK_LOG")) |value|
        return render_env.parseRendererDebug(std.mem.sliceTo(value, 0));
    return .{};
}

fn cpuRendererDebugEnabled() bool {
    return rendererDebugOptions().renderers;
}

fn cpuRendererDebug(timer: perf.Timer, comptime fmt: []const u8, args: anytype) void {
    if (!cpuRendererDebugEnabled()) return;
    std.debug.print("mollusk[cpu-renderer] {d:.1}ms: " ++ fmt ++ "\n", .{timer.elapsedMs()} ++ args);
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
    renderer: *renderer_mod.Renderer = undefined,
    renderer_mutex: *anyopaque = undefined,
    atlas_thread: ?*atlas_owner.Frontend = null,
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
    buffers: [BufferCount]shared_shm.SharedBuffer = undefined,
    buffer_count: usize = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn responseFd(self: *const Frontend) c_int {
        return self.response_fds[0];
    }

    pub fn start(
        self: *Frontend,
        shm_opaque: *anyopaque,
        renderer: *renderer_mod.Renderer,
        renderer_mutex: *anyopaque,
        atlas_thread: *atlas_owner.Frontend,
        width: u32,
        height: u32,
    ) !void {
        if (self.active) return;
        const timer = perf.Timer.now();
        self.* = .{
            .renderer = renderer,
            .renderer_mutex = renderer_mutex,
            .atlas_thread = atlas_thread,
        };
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

        try self.ensureBuffers(shm_opaque, width, height);
        errdefer self.destroyBuffers();

        self.active = true;
        self.thread = try std.Thread.spawn(.{}, Frontend.workerMain, .{self});
        cpuRendererDebug(timer, "start {}x{}", .{ width, height });
    }

    pub fn stop(self: *Frontend) void {
        if (!self.active) return;
        const timer = perf.Timer.now();
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
        cpuRendererDebug(timer, "stop", .{});
    }

    pub fn ensureBuffers(self: *Frontend, shm_opaque: *anyopaque, width: u32, height: u32) !void {
        if (self.buffer_count > 0 and self.width == width and self.height == height) return;
        if (self.render_in_flight or self.request_pending) return error.Busy;
        const timer = perf.Timer.now();
        self.destroyBuffers();
        errdefer self.destroyBuffers();
        for (0..BufferCount) |i| {
            self.buffers[i] = try shared_shm.SharedBuffer.create(shm_opaque, width, height);
            self.buffers[i].attachListener();
            self.buffer_count += 1;
        }
        self.width = width;
        self.height = height;
        cpuRendererDebug(timer, "buffers ready {}x{} count={}", .{ width, height, self.buffer_count });
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
    ) !void {
        if (!self.active) return error.Inactive;
        if (self.render_in_flight or self.request_pending) return error.Busy;
        const timer = perf.Timer.now();
        const buffer_index = self.freeBufferIndex() orelse return error.NoFreeBuffer;
        const snapshot_slot = self.freeSnapshotSlot() orelse return error.NoFreeSnapshot;

        try render_snapshot.capture(&self.snapshots[snapshot_slot], term, &self.renderer.font);
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
        cpuRendererDebug(timer, "queue frame buffer={} snapshot={} serial={} {}x{}", .{
            buffer_index,
            snapshot_slot,
            serial,
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
        if (cpuRendererDebugEnabled()) {
            std.debug.print("mollusk[cpu-renderer] thread running\n", .{});
        }
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
                    if (buffer_index >= self.buffer_count or snapshot_slot >= SnapshotSlotCount) {
                        cpuRendererDebug(timer, "reject frame buffer={} snapshot={} serial={}", .{
                            buffer_index,
                            snapshot_slot,
                            request.serial,
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
                        cpuRendererDebug(timer, "missing shm map buffer={} serial={}", .{
                            buffer_index,
                            request.serial,
                        });
                        writeResponse(self.response_fds[1], .{
                            .tag = .failed,
                            .buffer_index = buffer_index,
                            .snapshot_slot = snapshot_slot,
                            .serial = request.serial,
                        });
                        continue;
                    };

                    const renderer_mutex: *c.pthread_mutex_t = @ptrCast(@alignCast(self.renderer_mutex));
                    _ = c.pthread_mutex_lock(renderer_mutex);
                    defer _ = c.pthread_mutex_unlock(renderer_mutex);
                    self.renderer.maybeResetAtlasForDebug() catch {};
                    shm_render.renderSnapshotToMemory(
                        self.atlas_thread,
                        map_ptr,
                        buffer.desc.width,
                        buffer.desc.height,
                        buffer.desc.stride,
                        &self.snapshots[snapshot_slot],
                        &self.renderer.atlas,
                        &self.renderer.font,
                        request.font_size,
                        request.cell_width,
                        request.cell_height,
                    );
                    cpuRendererDebug(timer, "frame complete buffer={} snapshot={} serial={} in {d:.1}ms", .{
                        buffer_index,
                        snapshot_slot,
                        request.serial,
                        timer.elapsedMs(),
                    });
                    writeResponse(self.response_fds[1], .{
                        .tag = .frame,
                        .buffer_index = buffer_index,
                        .snapshot_slot = snapshot_slot,
                        .serial = request.serial,
                    });
                },
            }
        }
    }
};

fn writeResponse(fd: c_int, response: Response) void {
    _ = c.write(fd, &response, @sizeOf(Response));
}
