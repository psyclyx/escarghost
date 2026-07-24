const std = @import("std");
const snail = @import("snail");
const atlas_ref_mod = @import("atlas_ref.zig");
const log = @import("../log.zig");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("errno.h");
    @cInclude("sys/stat.h");
    @cInclude("fontconfig/fontconfig.h");
});

pub const ResponseTag = enum(u8) {
    failed = 2,
    font_ready = 3,
    bootstrap_ready = 4,
};

pub const Response = extern struct {
    tag: ResponseTag,
    reserved: [3]u8 = [_]u8{0} ** 3,
};

pub const BootstrapConfig = struct {
    allocator: std.mem.Allocator,
    font_path_cfg: []const u8,
    /// Fontconfig family names (or any FcNameParse-able pattern) tried
    /// in order when the primary font lacks a glyph. Empty = no
    /// fallback chain. Caller owns the slice & contents; bootstrap
    /// reads them and drops the references after resolving.
    fallback_fonts: []const []const u8 = &.{},
    font_size: f32,
};

/// Runs font + atlas bootstrap on a worker thread, then exits. Once
/// bootstrap is done the atlas lives entirely behind `AtlasRef`, which
/// the render thread mutates synchronously via `AtlasRef.extend`.
/// There's no post-bootstrap loop — the thread joins cleanly on stop.
pub const AtlasWorker = struct {
    atlas_ref: *atlas_ref_mod.AtlasRef = undefined,
    response_fds: [2]c_int = [_]c_int{-1} ** 2,
    thread: ?std.Thread = null,
    active: bool = false,
    io: std.Io = undefined,

    // Bootstrap state — set by thread, read by main after responses.
    bootstrap_config: ?BootstrapConfig = null,
    bootstrap_font_path: []const u8 = "",
    bootstrap_err: ?anyerror = null,

    pub fn responseFd(self: *const AtlasWorker) c_int {
        return self.response_fds[0];
    }

    pub fn startWithBootstrap(self: *AtlasWorker, io: std.Io, config: BootstrapConfig) !void {
        if (self.active) return;
        self.* = .{ .bootstrap_config = config, .io = io };

        const pipe_fds = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return error.PipeFailed;
        self.response_fds = pipe_fds;
        errdefer {
            std.Io.File{ .handle = self.response_fds[0], .flags = .{ .nonblocking = false } }.close(io);
            std.Io.File{ .handle = self.response_fds[1], .flags = .{ .nonblocking = false } }.close(io);
            self.response_fds = [_]c_int{-1} ** 2;
        }

        self.active = true;
        self.thread = try std.Thread.spawn(.{}, AtlasWorker.workerMain, .{self});
        log.info(.atlas, "bootstrap started", .{});
    }

    pub fn stop(self: *AtlasWorker) void {
        if (!self.active) return;
        // No interrupt mechanism — bootstrap is short (a few ms) and
        // post-bootstrap the thread is already exited. join() returns
        // immediately for the already-exited case.
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.response_fds[0] >= 0) std.Io.File{ .handle = self.response_fds[0], .flags = .{ .nonblocking = false } }.close(self.io);
        if (self.response_fds[1] >= 0) std.Io.File{ .handle = self.response_fds[1], .flags = .{ .nonblocking = false } }.close(self.io);
        self.response_fds = [_]c_int{-1} ** 2;
        self.active = false;
        log.info(.atlas, "stopped", .{});
    }

    pub fn readResponse(self: *AtlasWorker) !?Response {
        var response: Response = undefined;
        const file = std.Io.File{ .handle = self.response_fds[0], .flags = .{ .nonblocking = false } };
        const n = file.readStreaming(self.io, &.{std.mem.asBytes(&response)}) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return error.ReadFailed,
        };
        if (n < @sizeOf(Response)) return error.ShortRead;
        return response;
    }

    fn workerMain(self: *AtlasWorker) void {
        log.info(.atlas, "thread running", .{});

        if (self.bootstrap_config) |config| {
            self.runBootstrap(config) catch |err| {
                self.bootstrap_err = err;
                writeResponse(self.response_fds[1], self.io, .{ .tag = .failed });
                return;
            };
            writeResponse(self.response_fds[1], self.io, .{ .tag = .bootstrap_ready });
        }
    }

    fn runBootstrap(self: *AtlasWorker, config: BootstrapConfig) !void {
        const alloc = config.allocator;

        // Phase 1: parse the primary font into a TextAtlas. Fallbacks
        // (if any) are resolved through fontconfig and appended as
        // additional FaceSpec entries with `fallback = true` so snail's
        // shaper consults them only when the primary face's cmap is
        // missing the codepoint. No rasterization happens here.
        const font_path = resolvePrimaryFont(alloc, self.io, config.font_path_cfg) catch |err| {
            log.err(.atlas, "primary font resolution failed", .{
                .config_value = config.font_path_cfg,
                .err = err,
            });
            return err;
        };
        errdefer alloc.free(font_path);

        const font_data = mmapFontFile(self.io, font_path) catch |err| {
            log.err(.atlas, "primary font mmap failed", .{ .path = font_path, .err = err });
            return err;
        };

        var specs: std.ArrayListUnmanaged(snail.FaceSpec) = .empty;
        defer specs.deinit(alloc);
        try specs.append(alloc, .{ .data = font_data });

        for (config.fallback_fonts) |name| {
            const path = resolveFontByQuery(alloc, name) catch |err| {
                log.warn(.atlas, "fallback lookup failed", .{ .name = name, .err = err });
                continue;
            };
            defer alloc.free(path);
            const data = mmapFontFile(self.io, path) catch |err| {
                log.warn(.atlas, "fallback mmap failed", .{ .name = name, .err = err });
                continue;
            };
            try specs.append(alloc, .{ .data = data, .fallback = true });
            log.info(.atlas, "fallback registered", .{ .name = name, .path = path });
        }

        var initial_atlas = try snail.TextAtlas.init(alloc, specs.items);
        errdefer initial_atlas.deinit();

        const atlas_ref = try alloc.create(atlas_ref_mod.AtlasRef);
        errdefer alloc.destroy(atlas_ref);
        atlas_ref.* = try atlas_ref_mod.AtlasRef.init(alloc, initial_atlas);

        self.bootstrap_font_path = font_path;
        self.atlas_ref = atlas_ref;
        log.info(.atlas, "font ready", .{ .fallbacks = specs.items.len - 1 });

        // Tell main it can compute cell metrics and fork the PTY now.
        // Glyph rasterization happens lazily on the render thread via
        // AtlasRef.extend whenever shaping turns up a miss.
        writeResponse(self.response_fds[1], self.io, .{ .tag = .font_ready });
    }
};

/// Resolve the `font` config value to a real on-disk path. Accepts
/// three forms:
///   1. Empty / unset: fontconfig query for "monospace".
///   2. A readable file path: used as-is.
///   3. Anything else (family name, fontconfig pattern): handed to
///      fontconfig via `resolveFontByQuery`.
/// Returns an owned, allocator-allocated path. The caller frees it.
fn resolvePrimaryFont(allocator: std.mem.Allocator, io: std.Io, config_value: []const u8) ![]const u8 {
    if (config_value.len == 0) return resolveFontByQuery(allocator, io, "monospace");

    // Treat as a path if the file exists and is readable.
    var path_z_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrintZ(&path_z_buf, "{s}", .{config_value})) |path_z| {
        if (c.access(path_z.ptr, c.R_OK) == 0) {
            return try allocator.dupe(u8, config_value);
        }
    } else |_| {}

    // Otherwise, hand it to fontconfig. Family name like "DejaVu Sans
    // Mono" works; full FcPattern strings work too.
    log.info(.atlas, "primary font: querying fontconfig", .{ .query = config_value });
    return resolveFontByQuery(allocator, io, config_value);
}

/// Resolve a fontconfig query (typically a family name) to a font file
/// path. The cache used by `findFontPathFc` is monospace-specific and
/// doesn't apply here, so this is unconditionally a fontconfig call.
fn findFontByName(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    const pattern = c.FcNameParse(query_z.ptr) orelse return error.NoFontFound;
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
    return try allocator.dupe(u8, path);
}

/// Resolve a fontconfig query (typically a family name like
/// "monospace" or "Noto Color Emoji") to a font file path. Reads /
/// writes a per-query cache so subsequent launches skip the fontconfig
/// XML parse.
fn resolveFontByQuery(allocator: std.mem.Allocator, io: std.Io, query: []const u8) ![]const u8 {
    if (tryReadFontPathCache(allocator, io, query)) |cached| return cached;

    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    const pattern = c.FcNameParse(query_z.ptr) orelse return error.NoFontFound;
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
    writeFontPathCache(io, query, path);
    return try allocator.dupe(u8, path);
}

// ── Font path cache ────────────────────────────────────────────────────────
//
// Caches each fontconfig query's resolution at
// $XDG_CACHE_HOME/scrgo/font-<sanitized>-<hash> (or ~/.cache/...) so
// subsequent launches skip fontconfig's XML parse — about 1.5 ms per
// query on a typical cold start. One file per query, so the primary
// ("monospace") and each fallback (e.g. "Noto Color Emoji") share the
// same invalidation logic but don't fight over a single cache file.
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

/// Build the cache file path for `query` into `buf`. Filename format:
/// `font-<sanitized>-<8hex>` — sanitized form is human-readable for
/// debugging; the hash suffix kills collisions between similar-looking
/// queries (e.g. "Foo Bar" vs "Foo_Bar"). Returns null if neither
/// XDG_CACHE_HOME nor HOME is set.
fn buildCachePathZ(buf: []u8, query: []const u8) ?[:0]const u8 {
    var name_buf: [128]u8 = undefined;
    const name = sanitizedCacheName(&name_buf, query);
    const hash: u32 = @truncate(std.hash.Wyhash.hash(0, query));
    if (c.getenv("XDG_CACHE_HOME")) |xdg_z| {
        const xdg = std.mem.sliceTo(xdg_z, 0);
        return std.fmt.bufPrintZ(buf, "{s}/scrgo/font-{s}-{x:0>8}", .{ xdg, name, hash }) catch null;
    }
    if (c.getenv("HOME")) |home_z| {
        const home = std.mem.sliceTo(home_z, 0);
        return std.fmt.bufPrintZ(buf, "{s}/.cache/scrgo/font-{s}-{x:0>8}", .{ home, name, hash }) catch null;
    }
    return null;
}

fn sanitizedCacheName(out: []u8, query: []const u8) []const u8 {
    const n = @min(out.len, query.len);
    for (0..n) |i| {
        const b = query[i];
        out[i] = switch (b) {
            'A'...'Z' => b - 'A' + 'a',
            'a'...'z', '0'...'9' => b,
            else => '_',
        };
    }
    return out[0..n];
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

fn tryReadFontPathCache(allocator: std.mem.Allocator, io: std.Io, query: []const u8) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    const cache_z = buildCachePathZ(&path_buf, query) orelse return null;

    const cache_mtime = mtimeNs(cache_z.ptr) orelse return null;
    if (cacheInvalidated(cache_mtime)) return null;

    const file = std.Io.Dir.cwd.openFile(io, cache_z, .{}) catch return null;
    defer file.close(io);

    var data_buf: [4096]u8 = undefined;
    const n = file.readStreaming(io, &.{&data_buf}) catch return null;
    if (n == 0) return null;
    const trimmed = std.mem.trim(u8, data_buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return null;

    var path_z_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{trimmed}) catch return null;
    if (c.access(path_z.ptr, c.F_OK) != 0) return null;

    return allocator.dupe(u8, trimmed) catch null;
}

fn writeFontPathCache(io: std.Io, query: []const u8, path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const cache_z = buildCachePathZ(&path_buf, query) orelse return;

    const last_slash = std.mem.lastIndexOfScalar(u8, cache_z, '/') orelse return;
    const dir = cache_z[0..last_slash];
    std.Io.Dir.cwd.createDir(io, dir, .default_dir) catch {};

    var tmp_buf: [4096]u8 = undefined;
    const tmp_z = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{cache_z}) catch return;

    const file = std.Io.Dir.cwd.createFile(io, tmp_z, .{ .read = false, .truncate = true }) catch return;
    file.writeStreamingAll(io, path) catch {};
    file.writeStreamingAll(io, "\n") catch {};
    file.close(io);

    std.Io.Dir.cwd.rename(io, tmp_z, cache_z) catch {};
}

fn mmapFontFile(io: std.Io, path: []const u8) ![]const u8 {
    const path_z = std.heap.smp_allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer std.heap.smp_allocator.free(path_z);

    const file = std.Io.Dir.cwd.openFile(io, path_z, .{}) catch return error.FileNotFound;
    const stat = file.stat(io) catch {
        file.close(io);
        return error.StatFailed;
    };
    const size: usize = @intCast(stat.size);

    var mm = std.Io.File.MemoryMap.create(io, file, .{
        .len = size,
        .protection = .{ .read = true, .write = false },
        .undefined_contents = false,
    }) catch {
        file.close(io);
        return error.MmapFailed;
    };
    file.close(io);

    // The MemoryMap owns the mapping; we return a slice into it.
    // MemoryMap.destroy is never called — the mapping lives for the
    // process lifetime (fonts are needed until exit, and we skip
    // teardown via _exit). This matches the previous c.mmap behavior.
    return mm.memory;
}

fn writeResponse(fd: c_int, io: std.Io, response: Response) void {
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.writeStreamingAll(io, std.mem.asBytes(&response)) catch {};
}
