//! Disk-backed Vulkan pipeline cache.
//!
//! Seeding `vkCreateGraphicsPipelines` from a prior run's cache lets the
//! driver (notably NVIDIA) skip recompiling the pipeline's shaders every
//! launch — the bulk of cold pipeline-creation cost. Isolated in its own file
//! so the file-I/O C bindings never mix with the Vulkan ones in `context.zig`.

const std = @import("std");
const vk = @import("vulkan.zig").vk;

const c = @cImport({
    // See main.zig: glibc fortify inline wrappers don't survive Zig 0.16
    // translate-c under ReleaseSafe.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
});

const file_name = "vk_pipeline_cache.bin";

fn cstr(p: [*c]const u8) []const u8 {
    return std.mem.sliceTo(p, 0);
}

/// Resolve `$XDG_CACHE_HOME/scrgo` (or `$HOME/.cache/scrgo`), create that dir,
/// and write the full cache-file path into `path_buf`. Null if unresolvable.
fn resolvePath(dir_buf: []u8, path_buf: []u8) ?[:0]const u8 {
    const dir = blk: {
        if (c.getenv("XDG_CACHE_HOME")) |x| {
            const s = cstr(x);
            if (s.len > 0) break :blk std.fmt.bufPrintZ(dir_buf, "{s}/scrgo", .{s}) catch return null;
        }
        const home = c.getenv("HOME") orelse return null;
        break :blk std.fmt.bufPrintZ(dir_buf, "{s}/.cache/scrgo", .{cstr(home)}) catch return null;
    };
    _ = c.mkdir(dir.ptr, @as(c.mode_t, 0o755)); // best-effort; ~/.cache usually exists
    return std.fmt.bufPrintZ(path_buf, "{s}/" ++ file_name, .{dir}) catch null;
}

/// Create a pipeline cache, seeded from disk if a prior run wrote one.
/// Returns null only if `vkCreatePipelineCache` fails (callers then pass null,
/// i.e. an uncached create).
pub fn create(device: vk.VkDevice, allocator: std.mem.Allocator) vk.VkPipelineCache {
    var dir_buf: [512]u8 = undefined;
    var path_buf: [512]u8 = undefined;
    const initial: []u8 = if (resolvePath(&dir_buf, &path_buf)) |path|
        readFile(path, allocator) orelse &.{}
    else
        &.{};
    defer if (initial.len > 0) allocator.free(initial);

    const info = vk.VkPipelineCacheCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
        .initialDataSize = initial.len,
        .pInitialData = if (initial.len > 0) initial.ptr else null,
    };
    var cache: vk.VkPipelineCache = null;
    if (vk.vkCreatePipelineCache(device, &info, null, &cache) != vk.VK_SUCCESS) return null;
    return cache;
}

/// Persist the cache to disk. Best-effort — a failure just means the next
/// launch recompiles.
pub fn save(device: vk.VkDevice, cache: vk.VkPipelineCache, allocator: std.mem.Allocator) void {
    var size: usize = 0;
    if (vk.vkGetPipelineCacheData(device, cache, &size, null) != vk.VK_SUCCESS or size == 0) return;
    const data = allocator.alloc(u8, size) catch return;
    defer allocator.free(data);
    if (vk.vkGetPipelineCacheData(device, cache, &size, data.ptr) != vk.VK_SUCCESS) return;

    var dir_buf: [512]u8 = undefined;
    var path_buf: [512]u8 = undefined;
    const path = resolvePath(&dir_buf, &path_buf) orelse return;
    writeFile(path, data[0..size]);
}

fn readFile(path: [:0]const u8, allocator: std.mem.Allocator) ?[]u8 {
    const fd = c.open(path.ptr, c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return null;
    const size: usize = @intCast(st.st_size);
    if (size == 0) return null;
    const data = allocator.alloc(u8, size) catch return null;
    var got: usize = 0;
    while (got < size) {
        const n = c.read(fd, data.ptr + got, size - got);
        if (n <= 0) {
            allocator.free(data);
            return null;
        }
        got += @intCast(n);
    }
    return data;
}

fn writeFile(path: [:0]const u8, data: []const u8) void {
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);
    var put: usize = 0;
    while (put < data.len) {
        const n = c.write(fd, data.ptr + put, data.len - put);
        if (n <= 0) return;
        put += @intCast(n);
    }
}
