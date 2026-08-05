//! Headless offscreen screenshot: render one terminal frame to a PPM via
//! Vulkan, with no Wayland/compositor. Used to verify the render pipeline
//! (and dependency upgrades like snail) end-to-end without a display.
//!
//! Reuses the real render modules — bootstrap → shape → prep → upload →
//! emit → renderToTarget — driven synchronously here instead of by the
//! GPU worker thread + Wayland event loop. The async prep thread still runs
//! (started at bootstrap); we warm the atlas over a few frames (short sleeps
//! between them so prep can publish), then read the dmabuf image back.

const std = @import("std");
const snail = @import("snail");
const vk = @import("vk/root.zig");
const vkb = @import("vk/vulkan.zig").vk;
const gpu_pipeline = @import("gpu_pipeline.zig");
const cpu_pipeline = @import("cpu_pipeline.zig");
const render_snapshot = @import("render_snapshot.zig");
const atlas_worker = @import("atlas_worker.zig");
const terminal_mod = @import("../terminal.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");

const c = @cImport({
    @cInclude("time.h");
});

pub const Options = struct {
    text: []const u8,
    width: u32 = 1000,
    height: u32 = 600,
    out_path: []const u8,
    /// Upper bound on warm frames before giving up on full glyph coverage.
    max_frames: u32 = 120,
};

pub fn screenshot(allocator: std.mem.Allocator, io: std.Io, cfg: *const config_mod.Config, opts: Options) !void {
    // ── Bootstrap fonts + atlas (also starts the async prep thread) ──
    var atlas_thread: atlas_worker.AtlasWorker = .{};
    try atlas_thread.startWithBootstrap(io, .{
        .allocator = allocator,
        .font_path_cfg = cfg.font_path,
        .fallback_fonts = cfg.fallback_fonts,
        .font_size = cfg.font_size,
    });
    // metrics_ready then bootstrap_ready; wait for both so faces is live.
    for (0..2) |_| {
        const resp = (try atlas_thread.readResponse()) orelse return error.BootstrapFailed;
        if (resp.tag == .failed) return atlas_thread.bootstrap_err orelse error.BootstrapFailed;
    }
    const atlas_ref = atlas_thread.atlas_ref;
    atlas_ref.custom_glyphs = cfg.custom_glyphs;
    defer atlas_ref.stopPrep();
    const faces = atlas_thread.faces.?;

    // ── Metrics + grid + terminal ──
    const m = try gpu_pipeline.computeCellMetrics(faces, cfg.font_size);
    const grid = gpu_pipeline.computeGridSize(m.cell_width, m.cell_height, opts.width, opts.height);
    var term: terminal_mod.Terminal = undefined;
    try term.init(io, grid.cols, grid.rows, cfg.max_scrollback, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();
    term.feedData(opts.text);
    log.info(.main, "headless", .{ .cols = grid.cols, .rows = grid.rows, .w = opts.width, .h = opts.height });

    // ── Vulkan resources ──
    var ctx = try vk.Context.init(allocator);
    defer ctx.deinit();
    var device_atlas = try vk.DeviceAtlas.init(&ctx, std.heap.smp_allocator, atlas_ref.pool, .{});
    defer device_atlas.deinit();
    const slot_bytes = vk.Renderer.slotBytesForGrid(grid.cols, grid.rows);
    var renderer = try vk.Renderer.init(&ctx, device_atlas.descriptorSetLayout(), slot_bytes, 2);
    defer renderer.deinit();
    var target = try vk.DmabufTarget.create(&ctx, opts.width, opts.height);
    defer target.destroy(&ctx);

    // GpuPipeline + snapshot embed multi-MB scratch — heap-allocate.
    const pl = try allocator.create(gpu_pipeline.GpuPipeline);
    defer allocator.destroy(pl);
    try pl.init(allocator, atlas_ref);
    defer pl.deinit();
    pl.configure(opts.width, opts.height, m.em, m.cell_width, m.cell_height, m.baseline_offset, m.descent);
    const snap = try allocator.create(render_snapshot.SharedSnapshot);
    defer allocator.destroy(snap);

    const clear = cfg.background.toLinearFloat4(1.0);

    // ── Warm + render ──
    // Each frame: shape the snapshot, hand misses to the async prep thread,
    // and render what's prepped. Once a frame has no misses the atlas is
    // fully warm and we've drawn a complete frame; otherwise sleep briefly
    // to let prep publish and try again.
    var frame_slot: u32 = 0;
    var frame: u32 = 0;
    var complete = false;
    while (frame < opts.max_frames) : (frame += 1) {
        var lease = atlas_ref.acquire();
        const atlas = lease.get();
        try render_snapshot.capture(snap, &term, atlas, null, null, null);
        const had_misses = pl.buildShapes(atlas, faces, snap) catch |e| {
            lease.release();
            return e;
        };
        if (had_misses) atlas_ref.requestPrep(pl.misses.text());

        const binding = try device_atlas.upload(atlas);
        try pl.emitBuilt(atlas, binding, snap);
        _ = try vk.renderToTarget(&renderer, &ctx, &target, device_atlas.descriptorSet(), frame_slot, clear, device_atlas.atlasPageTexels(), pl.emittedInstances(), pl.emittedBatches(), .{});
        device_atlas.releaseBinding(binding);
        lease.release();
        frame_slot +%= 1;

        if (!had_misses) {
            complete = true;
            break;
        }
        // 30ms: let the async prep thread publish more prepped glyphs.
        var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 30_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    log.info(.main, "headless rendered", .{ .frames = frame + 1, .complete = complete });

    try readbackPpm(allocator, io, &ctx, &target, opts.out_path);
    log.info(.main, "headless screenshot written", .{ .path = opts.out_path });
}

/// Headless CPU (software-raster) screenshot — the CPU analog of `screenshot`,
/// with no Vulkan. Used to verify the CPU path (and diff the glyph coverage
/// cache against the analytic raster: same text, `SCRGO_CPU_GLYPH_CACHE=0/1`,
/// compare the PPMs).
pub fn screenshotCpu(allocator: std.mem.Allocator, io: std.Io, cfg: *const config_mod.Config, opts: Options) !void {
    var atlas_thread: atlas_worker.AtlasWorker = .{};
    try atlas_thread.startWithBootstrap(io, .{
        .allocator = allocator,
        .font_path_cfg = cfg.font_path,
        .fallback_fonts = cfg.fallback_fonts,
        .font_size = cfg.font_size,
    });
    for (0..2) |_| {
        const resp = (try atlas_thread.readResponse()) orelse return error.BootstrapFailed;
        if (resp.tag == .failed) return atlas_thread.bootstrap_err orelse error.BootstrapFailed;
    }
    const atlas_ref = atlas_thread.atlas_ref;
    atlas_ref.custom_glyphs = cfg.custom_glyphs;
    defer atlas_ref.stopPrep();
    const faces = atlas_thread.faces.?;

    const m = try gpu_pipeline.computeCellMetrics(faces, cfg.font_size);
    const grid = gpu_pipeline.computeGridSize(m.cell_width, m.cell_height, opts.width, opts.height);
    var term: terminal_mod.Terminal = undefined;
    try term.init(io, grid.cols, grid.rows, cfg.max_scrollback, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();
    term.feedData(opts.text);

    const pl = try allocator.create(cpu_pipeline.CpuPipeline);
    defer allocator.destroy(pl);
    try pl.init(allocator, atlas_ref);
    defer pl.deinit();
    pl.configure(opts.width, opts.height, m.em, m.cell_width, m.cell_height, m.baseline_offset, m.descent);
    const snap = try allocator.create(render_snapshot.SharedSnapshot);
    defer allocator.destroy(snap);

    const stride = opts.width * 4;
    const pixels = try allocator.alloc(u8, stride * opts.height);
    defer allocator.free(pixels);

    var frame: u32 = 0;
    var complete = false;
    while (frame < opts.max_frames) : (frame += 1) {
        var lease = atlas_ref.acquire();
        const atlas = lease.get();
        try render_snapshot.capture(snap, &term, atlas, null, null, null);
        pl.renderToMemory(pixels.ptr, opts.width, opts.height, stride, snap, atlas) catch |e| {
            lease.release();
            return e;
        };
        const had_misses = !pl.misses.isEmpty();
        lease.release();
        if (!had_misses) {
            complete = true;
            break;
        }
        var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 30_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    log.info(.main, "headless cpu rendered", .{ .frames = frame + 1, .complete = complete });

    // Write PPM (P6). The SHM buffer is R,G,B,A in memory order → take RGB.
    var file = try std.Io.Dir.cwd().createFile(io, opts.out_path, .{});
    defer file.close(io);
    var hdr: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ opts.width, opts.height }) catch unreachable;
    try file.writeStreamingAll(io, head);
    const rgb = try allocator.alloc(u8, @as(usize, opts.width) * opts.height * 3);
    defer allocator.free(rgb);
    var i: usize = 0;
    var y: u32 = 0;
    while (y < opts.height) : (y += 1) {
        var x: u32 = 0;
        while (x < opts.width) : (x += 1) {
            const o = @as(usize, y) * stride + @as(usize, x) * 4;
            rgb[i] = pixels[o];
            rgb[i + 1] = pixels[o + 1];
            rgb[i + 2] = pixels[o + 2];
            i += 3;
        }
    }
    try file.writeStreamingAll(io, rgb);
    log.info(.main, "headless cpu screenshot written", .{ .path = opts.out_path });
}

/// Copy the (complete, GENERAL-layout) dmabuf image back to host memory and
/// write a binary PPM (P6). The image is R8G8B8A8_UNORM → take RGB per pixel.
fn readbackPpm(allocator: std.mem.Allocator, io: std.Io, ctx: *const vk.Context, target: *const vk.DmabufTarget, path: []const u8) !void {
    const w = target.desc.width;
    const h = target.desc.height;
    const byte_len: usize = @as(usize, w) * h * 4;

    // Host-visible readback buffer.
    var buffer: vkb.VkBuffer = null;
    var memory: vkb.VkDeviceMemory = null;
    {
        const info = vkb.VkBufferCreateInfo{
            .sType = vkb.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = byte_len,
            .usage = vkb.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = vkb.VK_SHARING_MODE_EXCLUSIVE,
        };
        if (vkb.vkCreateBuffer(ctx.device, &info, null, &buffer) != vkb.VK_SUCCESS) return error.BufferCreationFailed;
        var reqs: vkb.VkMemoryRequirements = undefined;
        vkb.vkGetBufferMemoryRequirements(ctx.device, buffer, &reqs);
        var props: vkb.VkPhysicalDeviceMemoryProperties = undefined;
        vkb.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &props);
        var mem_type: u32 = 0;
        const want = vkb.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vkb.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        for (0..props.memoryTypeCount) |i| {
            if (reqs.memoryTypeBits & (@as(u32, 1) << @intCast(i)) != 0 and
                props.memoryTypes[i].propertyFlags & want == want)
            {
                mem_type = @intCast(i);
                break;
            }
        }
        const alloc_info = vkb.VkMemoryAllocateInfo{
            .sType = vkb.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = reqs.size,
            .memoryTypeIndex = mem_type,
        };
        if (vkb.vkAllocateMemory(ctx.device, &alloc_info, null, &memory) != vkb.VK_SUCCESS) return error.MemoryAllocationFailed;
        if (vkb.vkBindBufferMemory(ctx.device, buffer, memory, 0) != vkb.VK_SUCCESS) return error.BindBufferFailed;
    }
    defer {
        vkb.vkDestroyBuffer(ctx.device, buffer, null);
        vkb.vkFreeMemory(ctx.device, memory, null);
    }

    // Barrier GENERAL → TRANSFER_SRC, copy image → buffer.
    const cmd = try ctx.allocCommandBuffer();
    defer ctx.freeCommandBuffer(cmd);
    const begin = vkb.VkCommandBufferBeginInfo{
        .sType = vkb.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = vkb.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    if (vkb.vkBeginCommandBuffer(cmd, &begin) != vkb.VK_SUCCESS) return error.BeginCommandFailed;
    const barrier = vkb.VkImageMemoryBarrier{
        .sType = vkb.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = vkb.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = vkb.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = vkb.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vkb.VK_QUEUE_FAMILY_IGNORED,
        .image = target.image,
        .subresourceRange = .{ .aspectMask = vkb.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
        .srcAccessMask = vkb.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = vkb.VK_ACCESS_TRANSFER_READ_BIT,
    };
    vkb.vkCmdPipelineBarrier(cmd, vkb.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, vkb.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);
    const region = vkb.VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{ .aspectMask = vkb.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = w, .height = h, .depth = 1 },
    };
    vkb.vkCmdCopyImageToBuffer(cmd, target.image, vkb.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &region);
    if (vkb.vkEndCommandBuffer(cmd) != vkb.VK_SUCCESS) return error.EndCommandFailed;
    try ctx.submitAndWait(cmd);

    // Map + write PPM (P6). Rows are tightly packed (bufferRowLength = 0).
    var mapped: ?*anyopaque = null;
    if (vkb.vkMapMemory(ctx.device, memory, 0, byte_len, 0, &mapped) != vkb.VK_SUCCESS) return error.MapFailed;
    defer vkb.vkUnmapMemory(ctx.device, memory);
    const px: [*]const u8 = @ptrCast(mapped.?);

    const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ w, h });
    defer allocator.free(header);
    const rgb = try allocator.alloc(u8, @as(usize, w) * h * 3);
    defer allocator.free(rgb);
    var i: usize = 0;
    while (i < @as(usize, w) * h) : (i += 1) {
        rgb[i * 3 + 0] = px[i * 4 + 0];
        rgb[i * 3 + 1] = px[i * 4 + 1];
        rgb[i * 3 + 2] = px[i * 4 + 2];
    }

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = try std.Io.Dir.cwd().createFile(io, path_z, .{ .read = false, .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, rgb);
}
