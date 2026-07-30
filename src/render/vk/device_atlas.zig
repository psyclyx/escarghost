//! GPU atlas cache for snail 0.15's flat page storage.
//!
//! Curve and band pages live in flat uniform *texel buffers* (curve =
//! R16G16B16A16_SFLOAT, band = R16G16_UINT) sized by snail's `FlatLayout`;
//! layer-info and color-image data stay in sampled 2D images. Logical pages
//! are banked into 256-layer windows — the fragment shader selects a bank via
//! the per-draw `page_base` push constant (see renderer.zig).
//!
//! `upload(atlas)` is synchronous (submitAndWait): it runs snail's
//! `atlas_upload.Planner` to produce the dirty `Region`s, stages them into one
//! host buffer, records the copies, submits, waits, and frees the staging.
//! The planner is persistent, so a binding reuses pages unchanged since the
//! last upload.

const std = @import("std");
const snail = @import("snail");
const log = @import("../../log.zig");
const Context = @import("context.zig").Context;
const memtrack = @import("memtrack.zig");

const vk = @import("vulkan.zig").vk;
const upload_plan = snail.atlas_upload;

pub const Binding = snail.render.records.Binding;

const CURVE_FMT = vk.VK_FORMAT_R16G16B16A16_SFLOAT;
const BAND_FMT = vk.VK_FORMAT_R16G16_UINT;
const INFO_FMT = vk.VK_FORMAT_R32G32B32A32_SFLOAT;
const IMAGE_FMT = vk.VK_FORMAT_R8G8B8A8_SRGB;
const INFO_WIDTH: u32 = upload_plan.INFO_WIDTH;

pub const DeviceAtlasOptions = struct {
    max_bindings: u32 = 16,
    layer_info_height: u32 = 64,
    max_images: u32 = 16,
    max_image_width: u32 = 1024,
    max_image_height: u32 = 1024,
    /// Initial curve/band GPU buffer capacity, in pages. The buffers grow on
    /// demand up to the pool's `max_pages` ceiling (see `growPoolBuffers`), so
    /// this is just the starting size — big enough that a normal screen never
    /// triggers a grow, small relative to the ceiling so we don't reserve the
    /// worst case up front.
    initial_pages: u32 = 64,
};

// ── Descriptor bindings (must match renderer.zig / snail's shader ABI) ──
pub const CURVE_BINDING: u32 = 0;
pub const BAND_BINDING: u32 = 1;
pub const LAYER_INFO_BINDING: u32 = 2;
pub const IMAGE_BINDING: u32 = 3;

pub const DeviceAtlas = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    ctx: *const Context,
    pool: *snail.PagePool,
    options: DeviceAtlasOptions,

    sampler_nearest: vk.VkSampler = null,
    sampler_linear: vk.VkSampler = null,
    desc_set_layout: vk.VkDescriptorSetLayout = null,

    flat: upload_plan.FlatLayout,
    /// Current curve/band GPU buffer capacity, in pages. Starts at
    /// `options.initial_pages`, grows toward `flat.logical_pages` (`max_pages`)
    /// as the working set climbs. The buffers only ever hold pages
    /// `0..capacity_pages`; page k's byte offset is `k * page_texels * bpp`
    /// (snail's `FlatLayout.translate`), independent of total size, so a buffer
    /// smaller than the `max_pages` total is valid as long as it covers every
    /// page the current atlas touches.
    capacity_pages: u32 = 0,
    /// Hard cap on `capacity_pages`: the smaller of the pool ceiling and what a
    /// uniform texel buffer can address on this GPU (`maxTexelBufferElements /
    /// curve_page_texels`). Growth never exceeds this; a working set past it
    /// (physically enormous) degrades to partial rather than an OOB copy.
    max_gpu_pages: u32 = 0,

    curve_buffer: vk.VkBuffer = null,
    curve_memory: vk.VkDeviceMemory = null,
    curve_view: vk.VkBufferView = null,
    band_buffer: vk.VkBuffer = null,
    band_memory: vk.VkDeviceMemory = null,
    band_view: vk.VkBufferView = null,

    layer_info_image: vk.VkImage = null,
    layer_info_memory: vk.VkDeviceMemory = null,
    layer_info_view: vk.VkImageView = null,
    layer_info_layout: vk.VkImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,

    image_array_image: vk.VkImage = null,
    image_array_memory: vk.VkDeviceMemory = null,
    image_array_view: vk.VkImageView = null,
    image_array_layout: vk.VkImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,

    desc_pool: vk.VkDescriptorPool = null,
    desc_set: vk.VkDescriptorSet = null,

    // Planner (region/delta computation) — cache-owned backing slices.
    planner: upload_plan.Planner,
    plan_gen: []u64,
    plan_curve: []u32,
    plan_band: []u32,
    plan_slots: []upload_plan.Slot,
    plan_info_free: []upload_plan.Range,
    plan_image_free: []upload_plan.Range,
    plan_regions: []upload_plan.Region,
    plan_info_scratch: []f32,
    info_scratch_stride: usize,

    pub fn init(ctx: *const Context, allocator: std.mem.Allocator, pool: *snail.PagePool, options: DeviceAtlasOptions) !Self {
        const opts: upload_plan.Options = .{
            .max_bindings = options.max_bindings,
            .layer_info_height = options.layer_info_height,
            .max_images = options.max_images,
            .max_image_width = options.max_image_width,
            .max_image_height = options.max_image_height,
        };
        const sz = try upload_plan.sizes(pool, opts);
        const info_scratch_len = std.math.mul(usize, sz.layer_info_scratch, options.max_bindings) catch return error.InvalidOptions;

        const gen = try allocator.alloc(u64, sz.generation);
        errdefer allocator.free(gen);
        const curve_words = try allocator.alloc(u32, sz.curve_words);
        errdefer allocator.free(curve_words);
        const band_words = try allocator.alloc(u32, sz.band_words);
        errdefer allocator.free(band_words);
        const slots = try allocator.alloc(upload_plan.Slot, sz.bindings);
        errdefer allocator.free(slots);
        const info_free = try allocator.alloc(upload_plan.Range, sz.info_free);
        errdefer allocator.free(info_free);
        const image_free = try allocator.alloc(upload_plan.Range, sz.image_free);
        errdefer allocator.free(image_free);
        const regions = try allocator.alloc(upload_plan.Region, sz.regions);
        errdefer allocator.free(regions);
        const info_scratch = try allocator.alloc(f32, info_scratch_len);
        errdefer allocator.free(info_scratch);

        const flat = try upload_plan.FlatLayout.init(pool);

        // Clamp GPU capacity to what a uniform texel buffer can address here.
        var props: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(ctx.physical_device, &props);
        const limit_pages: u32 = @intCast(@min(@as(u64, props.limits.maxTexelBufferElements) / flat.curve_page_texels, @as(u64, flat.logical_pages)));
        const max_gpu_pages = @max(@as(u32, 1), limit_pages);

        var self: Self = .{
            .allocator = allocator,
            .ctx = ctx,
            .pool = pool,
            .options = options,
            .flat = flat,
            .max_gpu_pages = max_gpu_pages,
            .capacity_pages = @min(@max(1, options.initial_pages), max_gpu_pages),
            .planner = try upload_plan.Planner.init(pool, opts, gen, curve_words, band_words, slots, info_free, image_free),
            .plan_gen = gen,
            .plan_curve = curve_words,
            .plan_band = band_words,
            .plan_slots = slots,
            .plan_info_free = info_free,
            .plan_image_free = image_free,
            .plan_regions = regions,
            .plan_info_scratch = info_scratch,
            .info_scratch_stride = sz.layer_info_scratch,
        };
        errdefer self.destroyGpuResources();
        try self.initSamplersAndLayout();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.destroyGpuResources();
        const dev = self.ctx.device;
        if (self.desc_set_layout != null) vk.vkDestroyDescriptorSetLayout(dev, self.desc_set_layout, null);
        if (self.sampler_linear != null) vk.vkDestroySampler(dev, self.sampler_linear, null);
        if (self.sampler_nearest != null) vk.vkDestroySampler(dev, self.sampler_nearest, null);
        self.allocator.free(self.plan_gen);
        self.allocator.free(self.plan_curve);
        self.allocator.free(self.plan_band);
        self.allocator.free(self.plan_slots);
        self.allocator.free(self.plan_info_free);
        self.allocator.free(self.plan_image_free);
        self.allocator.free(self.plan_regions);
        self.allocator.free(self.plan_info_scratch);
    }

    pub fn descriptorSet(self: *const Self) vk.VkDescriptorSet {
        return self.desc_set;
    }

    pub fn descriptorSetLayout(self: *const Self) vk.VkDescriptorSetLayout {
        return self.desc_set_layout;
    }

    /// Fixed curve/band page strides (texels) for the flat-buffer shader ABI.
    pub fn atlasPageTexels(self: *const Self) [2]i32 {
        return .{ @intCast(self.flat.curve_page_texels), @intCast(self.flat.band_page_texels) };
    }

    /// Byte size of the curve/band buffers for a given page capacity. Curve
    /// texels are RGBA16F (8 B), band texels RG16UI (4 B).
    fn curveBytes(self: *const Self, pages: u32) u64 {
        return @as(u64, pages) * self.flat.curve_page_texels * 8;
    }
    fn bandBytes(self: *const Self, pages: u32) u64 {
        return @as(u64, pages) * self.flat.band_page_texels * 4;
    }

    /// Plan + upload `atlas` synchronously; returns the binding to emit with.
    pub fn upload(self: *Self, atlas: *const snail.Atlas) !Binding {
        try self.ensureGpuResources();

        var len: usize = 0;
        const info_scratch = self.plan_info_scratch[0..self.info_scratch_stride];
        const binding = try self.planner.plan(atlas, self.plan_regions, &len, info_scratch);
        errdefer _ = self.planner.release(binding);
        const regions = self.plan_regions[0..len];

        // Grow the curve/band buffers if this atlas references a page beyond
        // the current GPU capacity, before any copies target them.
        var max_page: u32 = 0;
        for (regions) |r| switch (r.target) {
            .curve, .band => max_page = @max(max_page, r.page + 1),
            else => {},
        };
        if (max_page > self.capacity_pages) try self.growPoolBuffers(max_page);

        var total: usize = 0;
        for (regions) |r| total = std.math.add(usize, total, r.src.len) catch return error.UploadSizeOverflow;
        if (total == 0) return binding; // everything already resident

        // Stage every region source into one host-visible buffer.
        var staging_buf: vk.VkBuffer = null;
        var staging_mem: vk.VkDeviceMemory = null;
        try createBuffer(self.ctx, total, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &staging_buf, &staging_mem);
        defer {
            vk.vkDestroyBuffer(self.ctx.device, staging_buf, null);
            vk.vkFreeMemory(self.ctx.device, staging_mem, null);
        }
        var mapped: ?*anyopaque = null;
        if (vk.vkMapMemory(self.ctx.device, staging_mem, 0, total, 0, &mapped) != vk.VK_SUCCESS) {
            self.planner.invalidateUploads();
            return error.VulkanError;
        }
        const dst: [*]u8 = @ptrCast(mapped.?);
        const offsets = try self.allocator.alloc(usize, regions.len);
        defer self.allocator.free(offsets);
        {
            var cursor: usize = 0;
            for (regions, 0..) |r, i| {
                @memcpy(dst[cursor..][0..r.src.len], r.src);
                offsets[i] = cursor;
                cursor += r.src.len;
            }
        }
        vk.vkUnmapMemory(self.ctx.device, staging_mem);

        // Record copies.
        const cmd = try self.ctx.allocCommandBuffer();
        defer self.ctx.freeCommandBuffer(cmd);
        const begin = vk.VkCommandBufferBeginInfo{ .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        if (vk.vkBeginCommandBuffer(cmd, &begin) != vk.VK_SUCCESS) return error.VulkanError;

        var has_curve = false;
        var has_band = false;
        var has_image = false;
        var has_info = false;
        for (regions) |r| switch (r.target) {
            .curve => has_curve = true,
            .band => has_band = true,
            .image => has_image = true,
            .layer_info => has_info = true,
        };

        if (has_image) transitionImageLayout(cmd, self.image_array_image, @max(1, self.options.max_images), self.image_array_layout, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
        if (has_info) transitionImageLayout(cmd, self.layer_info_image, 1, self.layer_info_layout, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);

        for (regions, 0..) |r, i| {
            switch (r.target) {
                .curve, .band => {
                    // Skip pages the GPU buffer can't hold (growth hit the
                    // texel-buffer limit); their glyphs render as gaps rather
                    // than overrun the buffer. Only reachable past ~128k
                    // distinct on-screen glyphs.
                    if (r.page >= self.capacity_pages) continue;
                    const copy = (try self.flat.translate(r)).?;
                    const region = vk.VkBufferCopy{ .srcOffset = @intCast(offsets[i]), .dstOffset = copy.byte_offset, .size = @intCast(r.src.len) };
                    const dst_buf = if (r.target == .curve) self.curve_buffer else self.band_buffer;
                    vk.vkCmdCopyBuffer(cmd, staging_buf, dst_buf, 1, &region);
                },
                .image => {
                    const region = std.mem.zeroInit(vk.VkBufferImageCopy, .{
                        .bufferOffset = @as(vk.VkDeviceSize, @intCast(offsets[i])),
                        .imageSubresource = vk.VkImageSubresourceLayers{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = r.layer, .layerCount = 1 },
                        .imageExtent = vk.VkExtent3D{ .width = r.width, .height = r.height, .depth = 1 },
                    });
                    vk.vkCmdCopyBufferToImage(cmd, staging_buf, self.image_array_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
                },
                .layer_info => {
                    const region = std.mem.zeroInit(vk.VkBufferImageCopy, .{
                        .bufferOffset = @as(vk.VkDeviceSize, @intCast(offsets[i])),
                        .imageSubresource = vk.VkImageSubresourceLayers{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
                        .imageOffset = vk.VkOffset3D{ .x = @intCast(r.col_base), .y = @intCast(r.row_base), .z = 0 },
                        .imageExtent = vk.VkExtent3D{ .width = r.width, .height = r.height, .depth = 1 },
                    });
                    vk.vkCmdCopyBufferToImage(cmd, staging_buf, self.layer_info_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
                },
            }
        }

        // Barrier the texel buffers transfer→shader; images back to sampled.
        var bb: [2]vk.VkBufferMemoryBarrier = undefined;
        var bbn: u32 = 0;
        if (has_curve) {
            bb[bbn] = bufBarrier(self.curve_buffer);
            bbn += 1;
        }
        if (has_band) {
            bb[bbn] = bufBarrier(self.band_buffer);
            bbn += 1;
        }
        if (bbn > 0) vk.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, bbn, &bb, 0, null);
        if (has_image) {
            transitionImageLayout(cmd, self.image_array_image, @max(1, self.options.max_images), vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
            self.image_array_layout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        }
        if (has_info) {
            transitionImageLayout(cmd, self.layer_info_image, 1, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
            self.layer_info_layout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        }

        if (vk.vkEndCommandBuffer(cmd) != vk.VK_SUCCESS) return error.VulkanError;
        try self.ctx.submitAndWait(cmd);
        return binding;
    }

    pub fn releaseBinding(self: *Self, binding: Binding) void {
        _ = self.planner.release(binding);
    }

    // ── Resident resources ──

    fn ensureGpuResources(self: *Self) !void {
        if (self.desc_set != null) return;
        errdefer self.destroyGpuResources();
        try self.createPoolBuffers();
        try self.createSampledImages();
        try self.createDescriptorSet();
    }

    fn createPoolBuffers(self: *Self) !void {
        const usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | vk.VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT;
        const curve_bytes = self.curveBytes(self.capacity_pages);
        const band_bytes = self.bandBytes(self.capacity_pages);
        try createBuffer(self.ctx, curve_bytes, usage, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &self.curve_buffer, &self.curve_memory);
        try createBuffer(self.ctx, band_bytes, usage, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &self.band_buffer, &self.band_memory);
        self.curve_view = try createBufferView(self.ctx, self.curve_buffer, CURVE_FMT, curve_bytes);
        self.band_view = try createBufferView(self.ctx, self.band_buffer, BAND_FMT, band_bytes);
        memtrack.atlas_image.onAlloc(curve_bytes + band_bytes);
    }

    /// Grow the curve/band GPU buffers so they cover at least `needed_pages`
    /// pages. New device-local buffers are allocated at the next power-of-two
    /// capacity (capped at the pool ceiling), the live region is copied
    /// old→new on the GPU (device-local→device-local, VRAM bandwidth), the old
    /// buffers are freed, and the descriptor set is repointed. Runs on the GPU
    /// worker between frames (synchronous `submitAndWait`), so no frame is
    /// mid-flight reading the descriptor during the swap. No-op if the current
    /// capacity already covers `needed_pages`.
    fn growPoolBuffers(self: *Self, needed_pages: u32) !void {
        const ceiling = self.max_gpu_pages;
        if (needed_pages <= self.capacity_pages) return;
        var new_cap = self.capacity_pages;
        while (new_cap < needed_pages) new_cap *|= 2;
        new_cap = @min(new_cap, ceiling);
        if (new_cap <= self.capacity_pages) return; // already at ceiling

        const usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | vk.VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT;
        const new_curve_bytes = self.curveBytes(new_cap);
        const new_band_bytes = self.bandBytes(new_cap);

        var new_curve_buf: vk.VkBuffer = null;
        var new_curve_mem: vk.VkDeviceMemory = null;
        try createBuffer(self.ctx, new_curve_bytes, usage, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &new_curve_buf, &new_curve_mem);
        errdefer {
            vk.vkDestroyBuffer(self.ctx.device, new_curve_buf, null);
            vk.vkFreeMemory(self.ctx.device, new_curve_mem, null);
        }
        var new_band_buf: vk.VkBuffer = null;
        var new_band_mem: vk.VkDeviceMemory = null;
        try createBuffer(self.ctx, new_band_bytes, usage, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &new_band_buf, &new_band_mem);
        errdefer {
            vk.vkDestroyBuffer(self.ctx.device, new_band_buf, null);
            vk.vkFreeMemory(self.ctx.device, new_band_mem, null);
        }

        // All remaining fallible work happens before the irreversible swap, so
        // a failure leaves the old buffers + descriptor intact (caller retries).
        const new_curve_view = try createBufferView(self.ctx, new_curve_buf, CURVE_FMT, new_curve_bytes);
        errdefer vk.vkDestroyBufferView(self.ctx.device, new_curve_view, null);
        const new_band_view = try createBufferView(self.ctx, new_band_buf, BAND_FMT, new_band_bytes);
        errdefer vk.vkDestroyBufferView(self.ctx.device, new_band_view, null);

        // Copy the live region old→new on the GPU, then barrier transfer→shader
        // so the copied pages are readable regardless of what the ensuing
        // upload touches. The queue is idle here (prior frame waited), so the
        // old buffers' last reads are already complete.
        const cmd = try self.ctx.allocCommandBuffer();
        defer self.ctx.freeCommandBuffer(cmd);
        const begin = vk.VkCommandBufferBeginInfo{ .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        if (vk.vkBeginCommandBuffer(cmd, &begin) != vk.VK_SUCCESS) return error.VulkanError;
        const curve_copy = vk.VkBufferCopy{ .srcOffset = 0, .dstOffset = 0, .size = self.curveBytes(self.capacity_pages) };
        vk.vkCmdCopyBuffer(cmd, self.curve_buffer, new_curve_buf, 1, &curve_copy);
        const band_copy = vk.VkBufferCopy{ .srcOffset = 0, .dstOffset = 0, .size = self.bandBytes(self.capacity_pages) };
        vk.vkCmdCopyBuffer(cmd, self.band_buffer, new_band_buf, 1, &band_copy);
        var bb = [2]vk.VkBufferMemoryBarrier{ bufBarrier(new_curve_buf), bufBarrier(new_band_buf) };
        vk.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 2, &bb, 0, null);
        if (vk.vkEndCommandBuffer(cmd) != vk.VK_SUCCESS) return error.VulkanError;
        try self.ctx.submitAndWait(cmd);

        // ── Irreversible from here (no fallible calls): retire old, install
        // new, repoint the descriptor set. ──
        const dev = self.ctx.device;
        memtrack.atlas_image.onFree(self.curveBytes(self.capacity_pages) + self.bandBytes(self.capacity_pages));
        if (self.curve_view != null) vk.vkDestroyBufferView(dev, self.curve_view, null);
        if (self.curve_buffer != null) vk.vkDestroyBuffer(dev, self.curve_buffer, null);
        if (self.curve_memory != null) vk.vkFreeMemory(dev, self.curve_memory, null);
        if (self.band_view != null) vk.vkDestroyBufferView(dev, self.band_view, null);
        if (self.band_buffer != null) vk.vkDestroyBuffer(dev, self.band_buffer, null);
        if (self.band_memory != null) vk.vkFreeMemory(dev, self.band_memory, null);

        self.curve_buffer = new_curve_buf;
        self.curve_memory = new_curve_mem;
        self.band_buffer = new_band_buf;
        self.band_memory = new_band_mem;
        self.curve_view = new_curve_view;
        self.band_view = new_band_view;

        var texel_views = [2]vk.VkBufferView{ self.curve_view, self.band_view };
        var writes = [2]vk.VkWriteDescriptorSet{
            std.mem.zeroInit(vk.VkWriteDescriptorSet, .{ .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.desc_set, .dstBinding = CURVE_BINDING, .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .pTexelBufferView = &texel_views[0] }),
            std.mem.zeroInit(vk.VkWriteDescriptorSet, .{ .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.desc_set, .dstBinding = BAND_BINDING, .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .pTexelBufferView = &texel_views[1] }),
        };
        vk.vkUpdateDescriptorSets(dev, 2, &writes, 0, null);
        memtrack.atlas_image.onAlloc(new_curve_bytes + new_band_bytes);
        log.info(.gpu, "atlas grew", .{ .pages = new_cap, .curve_mb = new_curve_bytes / (1 << 20) });
        self.capacity_pages = new_cap;
    }

    fn createSampledImages(self: *Self) !void {
        self.layer_info_image = try createImage2D(self.ctx, INFO_WIDTH, @max(1, self.options.layer_info_height), INFO_FMT);
        self.layer_info_memory = try allocateImageMemory(self.ctx, self.layer_info_image);
        if (vk.vkBindImageMemory(self.ctx.device, self.layer_info_image, self.layer_info_memory, 0) != vk.VK_SUCCESS) return error.VulkanError;
        self.layer_info_view = try createImageView2D(self.ctx, self.layer_info_image, INFO_FMT);

        self.image_array_image = try createImage2DArray(self.ctx, @max(1, self.options.max_image_width), @max(1, self.options.max_image_height), @max(1, self.options.max_images), IMAGE_FMT);
        self.image_array_memory = try allocateImageMemory(self.ctx, self.image_array_image);
        if (vk.vkBindImageMemory(self.ctx.device, self.image_array_image, self.image_array_memory, 0) != vk.VK_SUCCESS) return error.VulkanError;
        self.image_array_view = try createImageView(self.ctx, self.image_array_image, IMAGE_FMT, @max(1, self.options.max_images));
    }

    fn createDescriptorSet(self: *Self) !void {
        const dev = self.ctx.device;
        const sizes = [2]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .descriptorCount = 2 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 2 },
        };
        const dp = std.mem.zeroInit(vk.VkDescriptorPoolCreateInfo, .{ .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = sizes.len, .pPoolSizes = &sizes });
        if (vk.vkCreateDescriptorPool(dev, &dp, null, &self.desc_pool) != vk.VK_SUCCESS) return error.VulkanError;

        var ds = std.mem.zeroes(vk.VkDescriptorSetAllocateInfo);
        ds.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        ds.descriptorPool = self.desc_pool;
        ds.descriptorSetCount = 1;
        ds.pSetLayouts = @ptrCast(&self.desc_set_layout);
        if (vk.vkAllocateDescriptorSets(dev, &ds, &self.desc_set) != vk.VK_SUCCESS) return error.VulkanError;

        const image_infos = [2]vk.VkDescriptorImageInfo{
            .{ .sampler = self.sampler_nearest, .imageView = self.layer_info_view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
            .{ .sampler = self.sampler_linear, .imageView = self.image_array_view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        };
        var texel_views = [2]vk.VkBufferView{ self.curve_view, self.band_view };
        var writes = [4]vk.VkWriteDescriptorSet{
            std.mem.zeroInit(vk.VkWriteDescriptorSet, .{ .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.desc_set, .dstBinding = CURVE_BINDING, .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .pTexelBufferView = &texel_views[0] }),
            std.mem.zeroInit(vk.VkWriteDescriptorSet, .{ .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.desc_set, .dstBinding = BAND_BINDING, .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .pTexelBufferView = &texel_views[1] }),
            std.mem.zeroInit(vk.VkWriteDescriptorSet, .{ .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.desc_set, .dstBinding = LAYER_INFO_BINDING, .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &image_infos[0] }),
            std.mem.zeroInit(vk.VkWriteDescriptorSet, .{ .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.desc_set, .dstBinding = IMAGE_BINDING, .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &image_infos[1] }),
        };
        vk.vkUpdateDescriptorSets(dev, 4, &writes, 0, null);
    }

    fn initSamplersAndLayout(self: *Self) !void {
        self.sampler_nearest = try createSampler(self.ctx, vk.VK_FILTER_NEAREST);
        self.sampler_linear = try createSampler(self.ctx, vk.VK_FILTER_LINEAR);

        var bindings: [4]vk.VkDescriptorSetLayoutBinding = undefined;
        bindings[CURVE_BINDING] = std.mem.zeroInit(vk.VkDescriptorSetLayoutBinding, .{ .binding = CURVE_BINDING, .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT });
        bindings[BAND_BINDING] = std.mem.zeroInit(vk.VkDescriptorSetLayoutBinding, .{ .binding = BAND_BINDING, .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT });
        bindings[LAYER_INFO_BINDING] = std.mem.zeroInit(vk.VkDescriptorSetLayoutBinding, .{ .binding = LAYER_INFO_BINDING, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = &self.sampler_nearest });
        bindings[IMAGE_BINDING] = std.mem.zeroInit(vk.VkDescriptorSetLayoutBinding, .{ .binding = IMAGE_BINDING, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = &self.sampler_linear });
        const dsl = std.mem.zeroInit(vk.VkDescriptorSetLayoutCreateInfo, .{ .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 4, .pBindings = &bindings });
        if (vk.vkCreateDescriptorSetLayout(self.ctx.device, &dsl, null, &self.desc_set_layout) != vk.VK_SUCCESS) return error.VulkanError;
    }

    fn destroyGpuResources(self: *Self) void {
        const dev = self.ctx.device;
        if (dev == null) return;
        if (self.desc_pool != null) vk.vkDestroyDescriptorPool(dev, self.desc_pool, null);
        self.desc_pool = null;
        self.desc_set = null;
        if (self.curve_view != null) vk.vkDestroyBufferView(dev, self.curve_view, null);
        if (self.curve_buffer != null) vk.vkDestroyBuffer(dev, self.curve_buffer, null);
        if (self.curve_memory != null) vk.vkFreeMemory(dev, self.curve_memory, null);
        if (self.band_view != null) vk.vkDestroyBufferView(dev, self.band_view, null);
        if (self.band_buffer != null) vk.vkDestroyBuffer(dev, self.band_buffer, null);
        if (self.band_memory != null) vk.vkFreeMemory(dev, self.band_memory, null);
        self.curve_view = null;
        self.curve_buffer = null;
        self.curve_memory = null;
        self.band_view = null;
        self.band_buffer = null;
        self.band_memory = null;
        if (self.layer_info_view != null) vk.vkDestroyImageView(dev, self.layer_info_view, null);
        if (self.layer_info_image != null) vk.vkDestroyImage(dev, self.layer_info_image, null);
        if (self.layer_info_memory != null) vk.vkFreeMemory(dev, self.layer_info_memory, null);
        if (self.image_array_view != null) vk.vkDestroyImageView(dev, self.image_array_view, null);
        if (self.image_array_image != null) vk.vkDestroyImage(dev, self.image_array_image, null);
        if (self.image_array_memory != null) vk.vkFreeMemory(dev, self.image_array_memory, null);
        self.layer_info_view = null;
        self.layer_info_image = null;
        self.layer_info_memory = null;
        self.image_array_view = null;
        self.image_array_image = null;
        self.image_array_memory = null;
        self.layer_info_layout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
        self.image_array_layout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
    }
};

fn bufBarrier(buffer: vk.VkBuffer) vk.VkBufferMemoryBarrier {
    return std.mem.zeroInit(vk.VkBufferMemoryBarrier, .{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffer,
        .offset = 0,
        .size = vk.VK_WHOLE_SIZE,
    });
}

// ── Vulkan helpers (adapted from snail's demo device.zig, on our Context) ──

fn findMemoryType(ctx: *const Context, type_filter: u32, properties: vk.VkMemoryPropertyFlags) ?u32 {
    var mp: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &mp);
    for (0..mp.memoryTypeCount) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and (mp.memoryTypes[i].propertyFlags & properties) == properties) return @intCast(i);
    }
    return null;
}

fn createBuffer(ctx: *const Context, size: vk.VkDeviceSize, usage: vk.VkBufferUsageFlags, properties: vk.VkMemoryPropertyFlags, buffer: *vk.VkBuffer, memory: *vk.VkDeviceMemory) !void {
    const ci = std.mem.zeroInit(vk.VkBufferCreateInfo, .{ .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage, .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE });
    var buf: vk.VkBuffer = null;
    if (vk.vkCreateBuffer(ctx.device, &ci, null, &buf) != vk.VK_SUCCESS) return error.VulkanError;
    errdefer vk.vkDestroyBuffer(ctx.device, buf, null);
    var req: vk.VkMemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(ctx.device, buf, &req);
    const ai = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{ .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = findMemoryType(ctx, req.memoryTypeBits, properties) orelse return error.NoSuitableMemory });
    var mem: vk.VkDeviceMemory = null;
    if (vk.vkAllocateMemory(ctx.device, &ai, null, &mem) != vk.VK_SUCCESS) return error.VulkanError;
    errdefer vk.vkFreeMemory(ctx.device, mem, null);
    if (vk.vkBindBufferMemory(ctx.device, buf, mem, 0) != vk.VK_SUCCESS) return error.VulkanError;
    buffer.* = buf;
    memory.* = mem;
}

fn createBufferView(ctx: *const Context, buffer: vk.VkBuffer, format: vk.VkFormat, range: vk.VkDeviceSize) !vk.VkBufferView {
    const ci = std.mem.zeroInit(vk.VkBufferViewCreateInfo, .{ .sType = vk.VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO, .buffer = buffer, .format = format, .offset = 0, .range = range });
    var view: vk.VkBufferView = null;
    if (vk.vkCreateBufferView(ctx.device, &ci, null, &view) != vk.VK_SUCCESS) return error.VulkanError;
    return view;
}

fn createImage2D(ctx: *const Context, width: u32, height: u32, format: vk.VkFormat) !vk.VkImage {
    return createImageInner(ctx, width, height, 1, format);
}

fn createImage2DArray(ctx: *const Context, width: u32, height: u32, layers: u32, format: vk.VkFormat) !vk.VkImage {
    return createImageInner(ctx, width, height, layers, format);
}

fn createImageInner(ctx: *const Context, width: u32, height: u32, layers: u32, format: vk.VkFormat) !vk.VkImage {
    const ci = std.mem.zeroInit(vk.VkImageCreateInfo, .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = layers,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    });
    var image: vk.VkImage = null;
    if (vk.vkCreateImage(ctx.device, &ci, null, &image) != vk.VK_SUCCESS) return error.VulkanError;
    return image;
}

fn allocateImageMemory(ctx: *const Context, image: vk.VkImage) !vk.VkDeviceMemory {
    var req: vk.VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(ctx.device, image, &req);
    const ai = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{ .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = findMemoryType(ctx, req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.NoSuitableMemory });
    var mem: vk.VkDeviceMemory = null;
    if (vk.vkAllocateMemory(ctx.device, &ai, null, &mem) != vk.VK_SUCCESS) return error.VulkanError;
    return mem;
}

fn createImageView(ctx: *const Context, image: vk.VkImage, format: vk.VkFormat, layer_count: u32) !vk.VkImageView {
    const ci = std.mem.zeroInit(vk.VkImageViewCreateInfo, .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image, .viewType = vk.VK_IMAGE_VIEW_TYPE_2D_ARRAY, .format = format, .subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = layer_count } });
    var view: vk.VkImageView = null;
    if (vk.vkCreateImageView(ctx.device, &ci, null, &view) != vk.VK_SUCCESS) return error.VulkanError;
    return view;
}

fn createImageView2D(ctx: *const Context, image: vk.VkImage, format: vk.VkFormat) !vk.VkImageView {
    const ci = std.mem.zeroInit(vk.VkImageViewCreateInfo, .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image, .viewType = vk.VK_IMAGE_VIEW_TYPE_2D, .format = format, .subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 } });
    var view: vk.VkImageView = null;
    if (vk.vkCreateImageView(ctx.device, &ci, null, &view) != vk.VK_SUCCESS) return error.VulkanError;
    return view;
}

fn createSampler(ctx: *const Context, filter: vk.VkFilter) !vk.VkSampler {
    const ci = std.mem.zeroInit(vk.VkSamplerCreateInfo, .{
        .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = @as(c_uint, @intCast(filter)),
        .minFilter = @as(c_uint, @intCast(filter)),
        .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .mipmapMode = @as(c_uint, @intCast(if (filter == vk.VK_FILTER_LINEAR) vk.VK_SAMPLER_MIPMAP_MODE_LINEAR else vk.VK_SAMPLER_MIPMAP_MODE_NEAREST)),
    });
    var s: vk.VkSampler = null;
    if (vk.vkCreateSampler(ctx.device, &ci, null, &s) != vk.VK_SUCCESS) return error.VulkanError;
    return s;
}

fn transitionImageLayout(cmd: vk.VkCommandBuffer, image: vk.VkImage, layer_count: u32, old_layout: vk.VkImageLayout, new_layout: vk.VkImageLayout, shader_stages: vk.VkPipelineStageFlags) void {
    var src_stage: vk.VkPipelineStageFlags = 0;
    var dst_stage: vk.VkPipelineStageFlags = 0;
    var src_access: vk.VkAccessFlags = 0;
    var dst_access: vk.VkAccessFlags = 0;
    if (old_layout == vk.VK_IMAGE_LAYOUT_UNDEFINED and new_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
        dst_access = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        src_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        dst_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
    } else if (old_layout == vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL and new_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
        src_access = vk.VK_ACCESS_SHADER_READ_BIT;
        dst_access = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        src_stage = shader_stages;
        dst_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
    } else if (old_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and new_layout == vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
        src_access = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        dst_access = vk.VK_ACCESS_SHADER_READ_BIT;
        src_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
        dst_stage = shader_stages;
    } else unreachable;
    const barrier = std.mem.zeroInit(vk.VkImageMemoryBarrier, .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = src_access, .dstAccessMask = dst_access, .oldLayout = old_layout, .newLayout = new_layout, .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED, .image = image, .subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = layer_count } });
    vk.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
}
