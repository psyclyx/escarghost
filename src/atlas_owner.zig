const std = @import("std");
const snail = @import("snail");
const atlas_ref_mod = @import("atlas_ref.zig");
const render_env = @import("render_env.zig");
const glyph_misses = @import("glyph_misses.zig");
const perf = @import("perf.zig");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("fontconfig/fontconfig.h");
});

pub const ResponseTag = enum(u8) {
    updated = 1,
    failed = 2,
    font_ready = 3,
    bootstrap_ready = 4,
};

pub const Response = extern struct {
    tag: ResponseTag,
    requested_count: u8 = 0,
    added_pages: u8 = 0,
    reserved: [2]u8 = [_]u8{0} ** 2,
};

pub const BootstrapConfig = struct {
    allocator: std.mem.Allocator,
    font_path_cfg: []const u8,
    font_size: f32,
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
    atlas_ref: *atlas_ref_mod.AtlasRef = undefined,
    response_fds: [2]c_int = [_]c_int{-1} ** 2,
    thread: ?std.Thread = null,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    pending: glyph_misses.Set = .{},
    request_pending: bool = false,
    stop_requested: bool = false,
    active: bool = false,

    // Bootstrap state (font + atlas init on thread)
    bootstrap_config: ?BootstrapConfig = null,
    bootstrap_font: ?*snail.Font = null,
    bootstrap_font_path: []const u8 = "",
    bootstrap_err: ?anyerror = null,

    pub fn responseFd(self: *const Frontend) c_int {
        return self.response_fds[0];
    }

    pub fn start(self: *Frontend, ref: *atlas_ref_mod.AtlasRef) !void {
        if (self.active) return;
        const timer = perf.Timer.now();
        self.* = .{
            .atlas_ref = ref,
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

    pub fn startWithBootstrap(self: *Frontend, config: BootstrapConfig) !void {
        if (self.active) return;
        const timer = perf.Timer.now();
        self.* = .{
            .bootstrap_config = config,
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
        atlasDebug(timer, "start (bootstrap)", .{});
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
        atlasDebug(timer, "queue {} bytes", .{self.pending.len});
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

        // Bootstrap: font + atlas init (before entering normal loop)
        if (self.bootstrap_config) |config| {
            self.runBootstrap(config) catch |err| {
                self.bootstrap_err = err;
                writeResponse(self.response_fds[1], .{ .tag = .failed });
                return;
            };
            writeResponse(self.response_fds[1], .{ .tag = .bootstrap_ready });
        }

        const allocator = self.atlas_ref.allocator;

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

            // Read current atlas (lock-free).
            const current = self.atlas_ref.load();
            const before_pages = current.pageCount();

            const pending_text = local_pending.text();
            const maybe_next = current.extendText(pending_text) catch {
                atlasDebug(timer, "extend failed for {} bytes", .{pending_text.len});
                writeResponse(self.response_fds[1], .{
                    .tag = .failed,
                    .requested_count = @intCast(@min(pending_text.len, std.math.maxInt(u8))),
                });
                continue;
            };

            if (maybe_next) |next_atlas| {
                // Move the new atlas to the heap and publish atomically.
                const heap_atlas = allocator.create(snail.Atlas) catch {
                    atlasDebug(timer, "alloc failed for atlas", .{});
                    var discard = next_atlas;
                    discard.deinit();
                    writeResponse(self.response_fds[1], .{
                        .tag = .failed,
                        .requested_count = @intCast(@min(pending_text.len, std.math.maxInt(u8))),
                    });
                    continue;
                };
                heap_atlas.* = next_atlas;

                const after_pages = heap_atlas.pageCount();
                self.atlas_ref.publish(heap_atlas);

                atlasDebug(timer, "extended text ({} bytes) pages {}->{}", .{
                    pending_text.len,
                    before_pages,
                    after_pages,
                });
                writeResponse(self.response_fds[1], .{
                    .tag = .updated,
                    .requested_count = @intCast(@min(pending_text.len, std.math.maxInt(u8))),
                    .added_pages = @intCast(@min(after_pages - before_pages, std.math.maxInt(u8))),
                });
            } else {
                atlasDebug(timer, "noop for {} bytes", .{pending_text.len});
                writeResponse(self.response_fds[1], .{
                    .tag = .updated,
                    .requested_count = @intCast(@min(pending_text.len, std.math.maxInt(u8))),
                    .added_pages = 0,
                });
            }
        }
    }

    fn runBootstrap(self: *Frontend, config: BootstrapConfig) !void {
        const timer = perf.Timer.now();
        const alloc = config.allocator;

        // Phase 1: font prep (main needs this for PTY grid size)
        const font_result = try bootstrapFont(alloc, config.font_path_cfg);
        self.bootstrap_font = font_result.font;
        self.bootstrap_font_path = font_result.path;
        atlasDebug(timer, "font ready", .{});

        // Signal font ready — main can fork PTY while atlas init continues
        writeResponse(self.response_fds[1], .{ .tag = .font_ready });

        // Phase 2: atlas init (overlaps with PTY fork on main thread)
        const ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
        var initial_atlas = try snail.Atlas.initAscii(alloc, font_result.font, ascii);
        errdefer initial_atlas.deinit();

        const atlas_ref = try alloc.create(atlas_ref_mod.AtlasRef);
        errdefer alloc.destroy(atlas_ref);
        atlas_ref.* = try atlas_ref_mod.AtlasRef.init(alloc, initial_atlas);

        self.atlas_ref = atlas_ref;
        atlasDebug(timer, "bootstrap complete", .{});
    }

    fn bootstrapFont(alloc: std.mem.Allocator, font_path_cfg: []const u8) !struct { font: *snail.Font, path: []const u8 } {
        const font_path = try findFontPathFc(alloc, font_path_cfg);
        errdefer alloc.free(font_path);

        const font_data = try mmapFontFile(font_path);

        const font = try alloc.create(snail.Font);
        errdefer alloc.destroy(font);
        font.* = try snail.Font.init(font_data);

        return .{ .font = font, .path = font_path };
    }
};

fn findFontPathFc(allocator: std.mem.Allocator, config_path: []const u8) ![]const u8 {
    if (config_path.len > 0) return try allocator.dupe(u8, config_path);

    const pattern = c.FcNameParse("monospace") orelse return error.NoFontFound;
    defer c.FcPatternDestroy(pattern);

    _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(null, pattern, &result) orelse return error.NoFontFound;
    defer c.FcPatternDestroy(match);

    var file_ptr: [*c]u8 = undefined;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch)
        return error.NoFontFound;

    return try allocator.dupe(u8, std.mem.sliceTo(file_ptr, 0));
}

fn mmapFontFile(path: []const u8) ![]const u8 {
    const path_z = std.heap.smp_allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer std.heap.smp_allocator.free(path_z);

    const fd = c.open(path_z.ptr, c.O_RDONLY);
    if (fd < 0) return error.FileNotFound;

    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) < 0) {
        _ = c.close(fd);
        return error.StatFailed;
    }
    const size: usize = @intCast(st.st_size);

    const map = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    _ = c.close(fd);
    if (map == c.MAP_FAILED) return error.MmapFailed;

    const ptr: [*]const u8 = @ptrCast(map);
    return ptr[0..size];
}

fn writeResponse(fd: c_int, response: Response) void {
    _ = c.write(fd, &response, @sizeOf(Response));
}
