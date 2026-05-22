const std = @import("std");
const snail = @import("snail");
const atlas_ref_mod = @import("atlas_ref.zig");
const glyph_misses = @import("glyph_misses.zig");
const perf = @import("../perf.zig");
const log = @import("../log.zig");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("errno.h");
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

pub const ExtendOutcome = enum {
    /// A new atlas snapshot was published since the caller's baseline,
    /// and the worker observed (and drained) the caller's misses before
    /// publishing. Caller can `refreshAtlas` and re-render.
    extended,
    /// The deadline elapsed before the worker drained pending and bumped
    /// the generation. Caller should ship its current frame.
    timed_out,
    /// The worker is inactive or prefetch is disabled. Caller has no
    /// async path to wait on; ship the current frame.
    unavailable,
};

pub const AtlasWorker = struct {
    atlas_ref: *atlas_ref_mod.AtlasRef = undefined,
    response_fds: [2]c_int = [_]c_int{-1} ** 2,
    thread: ?std.Thread = null,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    /// Signaled by the worker after each extend round (success or fail)
    /// so `extendBefore` callers waiting with a deadline can wake up and
    /// re-check the predicate (`pending` drained AND atlas generation
    /// advanced past their baseline).
    completion_cond: c.pthread_cond_t = undefined,
    pending: glyph_misses.Set = .{},
    request_pending: bool = false,
    stop_requested: bool = false,
    active: bool = false,
    /// Optional speculative atlas warming. Disabled with
    /// `SCRGO_ATLAS_PREFETCH=0`. Misses are still resolved synchronously
    /// on the render thread either way (see AtlasRef.extend).
    prefetch_enabled: bool = true,

    // Bootstrap state — set by thread, read by main after responses.
    bootstrap_config: ?BootstrapConfig = null,
    bootstrap_font_path: []const u8 = "",
    bootstrap_err: ?anyerror = null,

    pub fn responseFd(self: *const AtlasWorker) c_int {
        return self.response_fds[0];
    }

    pub fn start(self: *AtlasWorker, ref: *atlas_ref_mod.AtlasRef) !void {
        if (self.active) return;
        self.* = .{
            .atlas_ref = ref,
            .prefetch_enabled = prefetchEnabled(),
        };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);
        try initCompletionCond(&self.completion_cond);
        errdefer _ = c.pthread_cond_destroy(&self.completion_cond);

        var pipe_fds: [2]c_int = undefined;
        if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        self.response_fds = pipe_fds;
        errdefer {
            _ = c.close(self.response_fds[0]);
            _ = c.close(self.response_fds[1]);
            self.response_fds = [_]c_int{-1} ** 2;
        }

        self.active = true;
        self.thread = try std.Thread.spawn(.{}, AtlasWorker.workerMain, .{self});
        log.info(.atlas, "started", .{});
    }

    pub fn startWithBootstrap(self: *AtlasWorker, config: BootstrapConfig) !void {
        if (self.active) return;
        self.* = .{
            .bootstrap_config = config,
            .prefetch_enabled = prefetchEnabled(),
        };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);
        try initCompletionCond(&self.completion_cond);
        errdefer _ = c.pthread_cond_destroy(&self.completion_cond);

        var pipe_fds: [2]c_int = undefined;
        if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        self.response_fds = pipe_fds;
        errdefer {
            _ = c.close(self.response_fds[0]);
            _ = c.close(self.response_fds[1]);
            self.response_fds = [_]c_int{-1} ** 2;
        }

        self.active = true;
        self.thread = try std.Thread.spawn(.{}, AtlasWorker.workerMain, .{self});
        log.info(.atlas, "bootstrap started", .{});
    }

    pub fn stop(self: *AtlasWorker) void {
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
        _ = c.pthread_cond_destroy(&self.completion_cond);
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.pending = .{};
        self.request_pending = false;
        self.stop_requested = false;
        self.active = false;
        log.info(.atlas, "stopped", .{});
    }

    pub fn requestMany(self: *AtlasWorker, misses: *const glyph_misses.Set) void {
        if (!self.active or !self.prefetch_enabled or misses.isEmpty()) return;
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.pending.mergeFrom(misses);
        self.request_pending = !self.pending.isEmpty();
        _ = c.pthread_cond_signal(&self.cond);
        log.info(.atlas, "queue", .{ .bytes = self.pending.len });
    }

    /// Submit `misses` to the worker and block until the atlas
    /// generation advances past the caller's baseline AND `pending` has
    /// drained (i.e. the publish that bumped the generation included the
    /// caller's misses). Returns `.timed_out` if the worker doesn't get
    /// there before `deadline_ns` (a CLOCK_MONOTONIC absolute deadline
    /// in nanoseconds), or `.unavailable` if the worker is inactive /
    /// prefetch is off.
    ///
    /// On `.extended` the caller should `refreshAtlas` and redraw; on
    /// `.timed_out` they should ship the current frame and rely on the
    /// async `requestMany` path (which the caller is responsible for
    /// invoking as a fallback — `extendBefore` does *not* fall back on
    /// its own, so the caller keeps full control of the response-pipe
    /// signaling).
    pub fn extendBefore(
        self: *AtlasWorker,
        misses: *const glyph_misses.Set,
        deadline_ns: u64,
    ) ExtendOutcome {
        if (!self.active or !self.prefetch_enabled) return .unavailable;
        if (misses.isEmpty()) return .extended;

        const baseline_gen = self.atlas_ref.loadGeneration();
        const timer = perf.Timer.now();

        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        self.pending.mergeFrom(misses);
        self.request_pending = !self.pending.isEmpty();
        _ = c.pthread_cond_signal(&self.cond);

        var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
        nsToTimespec(deadline_ns, &ts);

        // Wait predicate: `pending` is drained (worker absorbed our merge
        // into a local batch) AND generation has advanced (publish
        // happened against that batch). Both together guarantee our
        // misses are reflected in the published snapshot.
        while (!(self.pending.isEmpty() and self.atlas_ref.loadGeneration() != baseline_gen)) {
            const rc = c.pthread_cond_timedwait(&self.completion_cond, &self.mutex, &ts);
            if (rc == c.ETIMEDOUT) {
                log.info(.atlas, "extendBefore timed out", .{
                    .elapsed_ms = log.fmt("{d:.2}", .{timer.elapsedMs()}),
                });
                return .timed_out;
            }
        }
        log.info(.atlas, "extendBefore satisfied", .{
            .elapsed_ms = log.fmt("{d:.2}", .{timer.elapsedMs()}),
        });
        return .extended;
    }

    pub fn readResponse(self: *AtlasWorker) !?Response {
        var response: Response = undefined;
        const rc = c.read(self.response_fds[0], &response, @sizeOf(Response));
        if (rc == 0) return null;
        if (rc < 0) return error.ReadFailed;
        if (@as(usize, @intCast(rc)) < @sizeOf(Response)) return error.ShortRead;
        return response;
    }

    fn workerMain(self: *AtlasWorker) void {
        log.info(.atlas, "thread running", .{});

        if (self.bootstrap_config) |config| {
            self.runBootstrap(config) catch |err| {
                self.bootstrap_err = err;
                writeResponse(self.response_fds[1], .{ .tag = .failed });
                return;
            };
            writeResponse(self.response_fds[1], .{ .tag = .bootstrap_ready });
        }

        // Misses now resolve synchronously on the render thread (see
        // AtlasRef.extend). Without prefetch, this thread has nothing
        // left to do post-bootstrap; exit so we don't burn an OS thread
        // on a permanently parked cond_wait.
        if (!self.prefetch_enabled) {
            log.info(.atlas, "prefetch disabled, thread exiting", .{});
            return;
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
            var current_lease = self.atlas_ref.acquire();
            defer current_lease.release();
            const current = current_lease.get();
            const pending_text = local_pending.text();

            // Goes through AtlasRef.extension_lock so a concurrent sync
            // extend on the render thread doesn't race the publish.
            const result_err = self.atlas_ref.extend(current, pending_text);
            self.signalRoundComplete();
            const result = result_err catch |e| {
                log.err(.atlas, "extend failed", .{
                    .bytes = pending_text.len,
                    .elapsed_ms = log.fmt("{d:.2}", .{timer.elapsedMs()}),
                    .err = e,
                });
                writeResponse(self.response_fds[1], .{
                    .tag = .failed,
                    .requested_count = @intCast(@min(pending_text.len, std.math.maxInt(u8))),
                });
                continue;
            };
            const tag: ResponseTag = switch (result) {
                .extended => .updated,
                .missing => .updated,
            };
            log.info(.atlas, "extend", .{
                .result = result,
                .bytes = pending_text.len,
                .elapsed_ms = log.fmt("{d:.2}", .{timer.elapsedMs()}),
            });
            writeResponse(self.response_fds[1], .{
                .tag = tag,
                .requested_count = @intCast(@min(pending_text.len, std.math.maxInt(u8))),
                .added_pages = 0,
            });
        }
    }

    /// Wake any `extendBefore` callers waiting on `completion_cond` so
    /// they re-check the (pending-drained + gen-advanced) predicate.
    /// Called by the worker after each extend round, success or failure.
    fn signalRoundComplete(self: *AtlasWorker) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        _ = c.pthread_cond_broadcast(&self.completion_cond);
    }

    fn prefetchEnabled() bool {
        const value = c.getenv("SCRGO_ATLAS_PREFETCH") orelse return true;
        const slice = std.mem.sliceTo(value, 0);
        if (slice.len == 0) return true;
        if (std.mem.eql(u8, slice, "0")) return false;
        if (std.ascii.eqlIgnoreCase(slice, "false")) return false;
        if (std.ascii.eqlIgnoreCase(slice, "off")) return false;
        return true;
    }

    fn runBootstrap(self: *AtlasWorker, config: BootstrapConfig) !void {
        const alloc = config.allocator;

        // Phase 1: parse the font into a TextAtlas. No rasterization yet, but
        // cellMetrics already works against the parsed font config.
        const font_path = try findFontPathFc(alloc, config.font_path_cfg);
        errdefer alloc.free(font_path);

        const font_data = try mmapFontFile(font_path);

        var initial_atlas = try snail.TextAtlas.init(alloc, &.{.{ .data = font_data }});
        errdefer initial_atlas.deinit();

        const atlas_ref = try alloc.create(atlas_ref_mod.AtlasRef);
        errdefer alloc.destroy(atlas_ref);
        atlas_ref.* = try atlas_ref_mod.AtlasRef.init(alloc, initial_atlas);

        self.bootstrap_font_path = font_path;
        self.atlas_ref = atlas_ref;
        log.info(.atlas, "font ready", .{});

        // Tell main it can compute cell metrics and fork the PTY now.
        // Glyph rasterization happens lazily via the atlas-thread miss
        // path — same mechanism programming ligatures and non-ASCII
        // already use. The renderer's actual shaping context picks the
        // correct GID, so we can't pollute the atlas with wrong variants.
        writeResponse(self.response_fds[1], .{ .tag = .font_ready });
    }
};

fn findFontPathFc(allocator: std.mem.Allocator, config_path: []const u8) ![]const u8 {
    if (config_path.len > 0) return try allocator.dupe(u8, config_path);

    // Fast path: on-disk cache of the previous "monospace" resolution.
    // Skips fontconfig's XML parse (~1.5 ms cold) when nothing relevant
    // has changed. See font_path_cache.zig-style comment near
    // tryReadFontPathCache for the invalidation strategy and tradeoff.
    if (tryReadFontPathCache(allocator)) |cached| return cached;

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

    const path = std.mem.sliceTo(file_ptr, 0);
    writeFontPathCache(path);
    return try allocator.dupe(u8, path);
}

// ── Font path cache ────────────────────────────────────────────────────────
//
// Caches the fontconfig "monospace" resolution at
// $XDG_CACHE_HOME/scrgo/font-path (or ~/.cache/scrgo/font-path) so that
// subsequent launches can skip fontconfig's XML parse — about 1.5 ms of
// wall time on a typical cold start.
//
// Invalidation: the cache file's mtime is compared against:
//   - /etc/fonts/fonts.conf            (system fontconfig config)
//   - /var/cache/fontconfig            (system fontconfig cache dir)
//   - ~/.config/fontconfig/fonts.conf  (user fontconfig override)
//   - ~/.cache/fontconfig              (user fontconfig cache dir)
// If any of those is newer than our cache, we re-resolve. We also stat()
// the cached font path itself; a missing file forces re-resolution.
//
// Tradeoff: a user can edit fontconfig configuration in a way that
// doesn't bump any of these mtimes (e.g. adds a font to a directory that
// fontconfig hasn't yet rescanned), in which case our cache stays stale
// until something else nudges it. Recovery is a single `rm` of the cache
// file. We accept that residual stale window in exchange for the 1.5 ms
// saving on every cold start.

const font_cache_rel = "scrgo/font-path";

fn buildCachePathZ(buf: []u8) ?[:0]const u8 {
    if (c.getenv("XDG_CACHE_HOME")) |xdg_z| {
        const xdg = std.mem.sliceTo(xdg_z, 0);
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ xdg, font_cache_rel }) catch null;
    }
    if (c.getenv("HOME")) |home_z| {
        const home = std.mem.sliceTo(home_z, 0);
        return std.fmt.bufPrintZ(buf, "{s}/.cache/{s}", .{ home, font_cache_rel }) catch null;
    }
    return null;
}

fn mtimeNs(path_z: [*:0]const u8) ?i128 {
    var st: c.struct_stat = undefined;
    if (c.stat(path_z, &st) < 0) return null;
    return @as(i128, st.st_mtim.tv_sec) * std.time.ns_per_s + @as(i128, st.st_mtim.tv_nsec);
}

fn pathNewerThan(path: []const u8, cache_mtime: i128) bool {
    var z_buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&z_buf, "{s}", .{path}) catch return false;
    const m = mtimeNs(z.ptr) orelse return false;
    return m > cache_mtime;
}

fn cacheInvalidated(cache_mtime: i128) bool {
    if (pathNewerThan("/etc/fonts/fonts.conf", cache_mtime)) return true;
    if (pathNewerThan("/var/cache/fontconfig", cache_mtime)) return true;
    if (c.getenv("HOME")) |home_z| {
        const home = std.mem.sliceTo(home_z, 0);
        var buf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/.config/fontconfig/fonts.conf", .{home})) |p| {
            if (pathNewerThan(p, cache_mtime)) return true;
        } else |_| {}
        if (std.fmt.bufPrint(&buf, "{s}/.cache/fontconfig", .{home})) |p| {
            if (pathNewerThan(p, cache_mtime)) return true;
        } else |_| {}
    }
    return false;
}

fn tryReadFontPathCache(allocator: std.mem.Allocator) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    const cache_z = buildCachePathZ(&path_buf) orelse return null;

    const cache_mtime = mtimeNs(cache_z.ptr) orelse return null;
    if (cacheInvalidated(cache_mtime)) return null;

    const fd = c.open(cache_z.ptr, c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);

    var data_buf: [4096]u8 = undefined;
    const n = c.read(fd, &data_buf, data_buf.len);
    if (n <= 0) return null;
    const trimmed = std.mem.trim(u8, data_buf[0..@intCast(n)], " \t\r\n");
    if (trimmed.len == 0) return null;

    var path_z_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{trimmed}) catch return null;
    if (c.access(path_z.ptr, c.F_OK) != 0) return null;

    return allocator.dupe(u8, trimmed) catch null;
}

fn writeFontPathCache(path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const cache_z = buildCachePathZ(&path_buf) orelse return;

    const last_slash = std.mem.lastIndexOfScalar(u8, cache_z, '/') orelse return;
    var dir_buf: [4096]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{cache_z[0..last_slash]}) catch return;
    _ = c.mkdir(dir_z.ptr, 0o755); // ignore EEXIST

    var tmp_buf: [4096]u8 = undefined;
    const tmp_z = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{cache_z}) catch return;

    const fd = c.open(tmp_z.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return;
    _ = c.write(fd, path.ptr, path.len);
    _ = c.write(fd, "\n", 1);
    _ = c.close(fd);

    _ = c.rename(tmp_z.ptr, cache_z.ptr);
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

/// Initialize a condvar that interprets `pthread_cond_timedwait`
/// deadlines as CLOCK_MONOTONIC values. The default attr uses
/// CLOCK_REALTIME, which would let wall-clock adjustments (NTP slew,
/// suspend) skew our budget-bound waits.
fn initCompletionCond(cond: *c.pthread_cond_t) !void {
    var attr: c.pthread_condattr_t = undefined;
    if (c.pthread_condattr_init(&attr) != 0) return error.CondAttrInitFailed;
    defer _ = c.pthread_condattr_destroy(&attr);
    if (c.pthread_condattr_setclock(&attr, c.CLOCK_MONOTONIC) != 0) return error.CondAttrSetClockFailed;
    if (c.pthread_cond_init(cond, &attr) != 0) return error.CondInitFailed;
}

fn nsToTimespec(ns: u64, out: *c.struct_timespec) void {
    out.tv_sec = @intCast(ns / std.time.ns_per_s);
    out.tv_nsec = @intCast(ns % std.time.ns_per_s);
}
