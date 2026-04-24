const std = @import("std");
const snail = @import("snail");
const renderer_mod = @import("renderer.zig");
const render_env = @import("render_env.zig");
const glyph_misses = @import("glyph_misses.zig");
const perf = @import("perf.zig");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

pub const ResponseTag = enum(u8) {
    updated = 1,
    failed = 2,
};

pub const Response = extern struct {
    tag: ResponseTag,
    requested_count: u8 = 0,
    added_pages: u8 = 0,
    reserved: [2]u8 = [_]u8{0} ** 2,
};

fn debugOptions() render_env.RendererDebug {
    if (c.getenv("MOLLUSK_LOG")) |value|
        return render_env.parseRendererDebug(std.mem.sliceTo(value, 0));
    return .{};
}

fn atlasDebugEnabled() bool {
    const options = debugOptions();
    return options.atlas or options.renderers;
}

fn atlasDebug(timer: perf.Timer, comptime fmt: []const u8, args: anytype) void {
    if (!atlasDebugEnabled()) return;
    std.debug.print("mollusk[atlas-owner] {d:.1}ms: " ++ fmt ++ "\n", .{timer.elapsedMs()} ++ args);
}

pub const Frontend = struct {
    renderer: *renderer_mod.Renderer = undefined,
    renderer_mutex: *anyopaque = undefined,
    response_fds: [2]c_int = [_]c_int{-1} ** 2,
    thread: ?std.Thread = null,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    pending: glyph_misses.Set = .{},
    request_pending: bool = false,
    stop_requested: bool = false,
    active: bool = false,

    pub fn responseFd(self: *const Frontend) c_int {
        return self.response_fds[0];
    }

    pub fn start(self: *Frontend, renderer: *renderer_mod.Renderer, renderer_mutex: *anyopaque) !void {
        if (self.active) return;
        const timer = perf.Timer.now();
        self.* = .{
            .renderer = renderer,
            .renderer_mutex = renderer_mutex,
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

        self.active = true;
        self.thread = try std.Thread.spawn(.{}, Frontend.workerMain, .{self});
        atlasDebug(timer, "start", .{});
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
        self.pending = .{};
        self.request_pending = false;
        self.stop_requested = false;
        self.active = false;
        atlasDebug(timer, "stop", .{});
    }

    pub fn requestMany(self: *Frontend, misses: *const glyph_misses.Set) void {
        if (!self.active or misses.isEmpty()) return;
        const timer = perf.Timer.now();
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.pending.mergeFrom(misses);
        self.request_pending = !self.pending.isEmpty();
        _ = c.pthread_cond_signal(&self.cond);
        atlasDebug(timer, "queue {} codepoints", .{self.pending.count});
    }

    pub fn readResponse(self: *Frontend) !?Response {
        var response: Response = undefined;
        const rc = c.read(self.response_fds[0], &response, @sizeOf(Response));
        if (rc == 0) return null;
        if (rc < 0) return error.ReadFailed;
        if (@as(usize, @intCast(rc)) < @sizeOf(Response)) return error.ShortRead;
        return response;
    }

    fn workerMain(self: *Frontend) void {
        if (atlasDebugEnabled()) {
            std.debug.print("mollusk[atlas-owner] thread running\n", .{});
        }
        while (true) {
            var local_pending: glyph_misses.Set = .{};
            {
                _ = c.pthread_mutex_lock(&self.mutex);
                while (!self.request_pending and !self.stop_requested) {
                    _ = c.pthread_cond_wait(&self.cond, &self.mutex);
                }
                if (self.stop_requested) {
                    _ = c.pthread_mutex_unlock(&self.mutex);
                    return;
                }
                local_pending = self.pending;
                self.pending.clear();
                self.request_pending = false;
                _ = c.pthread_mutex_unlock(&self.mutex);
            }

            const timer = perf.Timer.now();
            const renderer_mutex: *c.pthread_mutex_t = @ptrCast(@alignCast(self.renderer_mutex));
            _ = c.pthread_mutex_lock(renderer_mutex);
            defer _ = c.pthread_mutex_unlock(renderer_mutex);

            const before_pages = self.renderer.atlas.pageCount();
            const next = self.renderer.atlas.extendCodepoints(local_pending.slice()) catch {
                atlasDebug(timer, "extend failed for {} codepoints", .{local_pending.count});
                writeResponse(self.response_fds[1], .{
                    .tag = .failed,
                    .requested_count = local_pending.count,
                });
                continue;
            };

            if (next) |atlas_next| {
                _ = snail.replaceAtlas(&self.renderer.atlas, atlas_next);
                if (self.renderer.gpu_initialized) {
                    self.renderer.atlas_view = self.renderer.snail_renderer.uploadAtlas(&self.renderer.atlas);
                } else {
                    self.renderer.atlas_view = .{ .atlas = &self.renderer.atlas, .layer_base = 0 };
                }
                self.renderer.generation += 1;
                self.renderer.has_prev_frame = false;
                self.renderer.prev_cursor_visible = false;
                self.renderer.prev_cursor_in_viewport = false;
                self.renderer.clearCache();

                const after_pages = self.renderer.atlas.pageCount();
                atlasDebug(timer, "extended {} codepoints pages {}->{}", .{
                    local_pending.count,
                    before_pages,
                    after_pages,
                });
                writeResponse(self.response_fds[1], .{
                    .tag = .updated,
                    .requested_count = local_pending.count,
                    .added_pages = @intCast(@min(after_pages - before_pages, std.math.maxInt(u8))),
                });
            } else {
                atlasDebug(timer, "noop for {} codepoints", .{local_pending.count});
                writeResponse(self.response_fds[1], .{
                    .tag = .updated,
                    .requested_count = local_pending.count,
                    .added_pages = 0,
                });
            }
        }
    }
};

fn writeResponse(fd: c_int, response: Response) void {
    _ = c.write(fd, &response, @sizeOf(Response));
}
