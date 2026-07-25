//! GPU atlas cache: creates and manages the four atlas textures
//! (curve, band, layer-info, image array) and the descriptor set
//! that the renderer binds.
//!
//! Uses snail's atlas_upload.Planner for region planning. The actual
//! GPU texture creation, staging, and upload is Vulkan-specific.

const std = @import("std");
const snail = @import("snail");
const log = @import("../../log.zig");
const Context = @import("context.zig").Context;

const vk = @import("vulkan.zig").vk;

const Binding = snail.render.records.Binding;
const Region = snail.atlas_upload.Region;

// Atlas texture dimensions (from snail's format/abi.zig and atlas config)
const CURVE_TEX_WIDTH: u32 = 4096;
const BAND_TEX_WIDTH: u32 = 4096;
const INFO_WIDTH: u32 = 4096;
const CURVE_WORDS_PER_ROW: u32 = CURVE_TEX_WIDTH * 4; // R16G16B16A16 = 4 u16 words
const BAND_WORDS_PER_ROW: u32 = BAND_TEX_WIDTH * 2; // R16G16 = 2 u16 words

pub const DeviceAtlasOptions = struct {
    max_bindings: u32 = 16,
    layer_info_height: u32 = 64,
    max_images: u32 = 16,
    max_image_width: u32 = 1024,
    max_image_height: u32 = 1024,
};

pub const DeviceAtlas = struct {
    ctx: *const Context,
    options: DeviceAtlasOptions,
    pool: ?*snail.PagePool = null,

    // GPU images
    curve_image: vk.VkImage = null,
    curve_memory: vk.VkDeviceMemory = null,
    curve_view: vk.VkImageView = null,
    band_image: vk.VkImage = null,
    band_memory: vk.VkDeviceMemory = null,
    band_view: vk.VkImageView = null,
    layer_info_image: vk.VkImage = null,
    layer_info_memory: vk.VkDeviceMemory = null,
    layer_info_view: vk.VkImageView = null,
    image_array_image: vk.VkImage = null,
    image_array_memory: vk.VkDeviceMemory = null,
    image_array_view: vk.VkImageView = null,

    // Descriptor set
    desc_pool: vk.VkDescriptorPool = null,
    desc_set: vk.VkDescriptorSet = null,
    desc_set_layout: vk.VkDescriptorSetLayout = null,

    // Samplers
    sampler_nearest: vk.VkSampler = null,
    sampler_linear: vk.VkSampler = null,

    // Layout dimensions (set when pool is known)
    layer_count: u32 = 0,
    curve_height: u32 = 0,
    band_height: u32 = 0,

    // Atlas upload planner (created lazily on first upload)
    planner: ?snail.atlas_upload.OwnedPlanner = null,
    allocator: std.mem.Allocator = undefined,

    initialized: bool = false,

    pub fn init(ctx: *const Context, allocator: std.mem.Allocator, options: DeviceAtlasOptions) !DeviceAtlas {
        var self = DeviceAtlas{
            .ctx = ctx,
            .options = options,
            .allocator = allocator,
        };

        try self.createSamplers();
        try self.createDescriptorSetLayout();
        try self.createDescriptorPool();
        return self;
    }

    pub fn deinit(self: *DeviceAtlas) void {
        if (self.planner) |*p| p.deinit();
        const dev = self.ctx.device;
        if (self.image_array_view != null) vk.vkDestroyImageView(dev, self.image_array_view, null);
        if (self.image_array_image != null) vk.vkDestroyImage(dev, self.image_array_image, null);
        if (self.image_array_memory != null) vk.vkFreeMemory(dev, self.image_array_memory, null);
        if (self.layer_info_view != null) vk.vkDestroyImageView(dev, self.layer_info_view, null);
        if (self.layer_info_image != null) vk.vkDestroyImage(dev, self.layer_info_image, null);
        if (self.layer_info_memory != null) vk.vkFreeMemory(dev, self.layer_info_memory, null);
        if (self.band_view != null) vk.vkDestroyImageView(dev, self.band_view, null);
        if (self.band_image != null) vk.vkDestroyImage(dev, self.band_image, null);
        if (self.band_memory != null) vk.vkFreeMemory(dev, self.band_memory, null);
        if (self.curve_view != null) vk.vkDestroyImageView(dev, self.curve_view, null);
        if (self.curve_image != null) vk.vkDestroyImage(dev, self.curve_image, null);
        if (self.curve_memory != null) vk.vkFreeMemory(dev, self.curve_memory, null);
        if (self.desc_pool != null) vk.vkDestroyDescriptorPool(dev, self.desc_pool, null);
        if (self.desc_set_layout != null) vk.vkDestroyDescriptorSetLayout(dev, self.desc_set_layout, null);
        if (self.sampler_nearest != null) vk.vkDestroySampler(dev, self.sampler_nearest, null);
        if (self.sampler_linear != null) vk.vkDestroySampler(dev, self.sampler_linear, null);
    }

    fn createSamplers(self: *DeviceAtlas) !void {
        const nearest_info = vk.VkSamplerCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = vk.VK_FILTER_NEAREST,
            .minFilter = vk.VK_FILTER_NEAREST,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        };
        if (vk.vkCreateSampler(self.ctx.device, &nearest_info, null, &self.sampler_nearest) != vk.VK_SUCCESS) return error.SamplerCreationFailed;

        const linear_info = vk.VkSamplerCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = vk.VK_FILTER_LINEAR,
            .minFilter = vk.VK_FILTER_LINEAR,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        };
        if (vk.vkCreateSampler(self.ctx.device, &linear_info, null, &self.sampler_linear) != vk.VK_SUCCESS) return error.SamplerCreationFailed;
    }

    fn createDescriptorSetLayout(self: *DeviceAtlas) !void {
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = &self.sampler_nearest },
            .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = &self.sampler_nearest },
            .{ .binding = 2, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = &self.sampler_nearest },
            .{ .binding = 3, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = &self.sampler_linear },
        };

        const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = bindings.len,
            .pBindings = &bindings,
        };
        if (vk.vkCreateDescriptorSetLayout(self.ctx.device, &layout_info, null, &self.desc_set_layout) != vk.VK_SUCCESS) return error.DescSetLayoutCreationFailed;
    }

    fn createDescriptorPool(self: *DeviceAtlas) !void {
        const pool_size = vk.VkDescriptorPoolSize{
            .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 4,
        };
        const pool_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        if (vk.vkCreateDescriptorPool(self.ctx.device, &pool_info, null, &self.desc_pool) != vk.VK_SUCCESS) return error.DescPoolCreationFailed;

        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = self.desc_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.desc_set_layout,
        };
        if (vk.vkAllocateDescriptorSets(self.ctx.device, &alloc_info, &self.desc_set) != vk.VK_SUCCESS) return error.DescSetAllocationFailed;
    }

    pub fn descriptorSet(self: *const DeviceAtlas) vk.VkDescriptorSet {
        return self.desc_set;
    }

    pub fn descriptorSetLayout(self: *const DeviceAtlas) vk.VkDescriptorSetLayout {
        return self.desc_set_layout;
    }

    /// Ensure GPU resources are created for the given page pool config.
    /// Called lazily on first upload. Idempotent.
    pub fn ensureGpuResources(self: *DeviceAtlas, pool: *snail.PagePool) !void {
        if (self.initialized) return;

        self.pool = pool;
        self.planner = try snail.atlas_upload.OwnedPlanner.init(self.allocator, pool, .{
            .max_bindings = self.options.max_bindings,
            .layer_info_height = self.options.layer_info_height,
            .max_images = self.options.max_images,
            .max_image_width = self.options.max_image_width,
            .max_image_height = self.options.max_image_height,
        });
        errdefer {
            self.planner.?.deinit();
            self.planner = null;
        }

        const config = pool.config();
        self.layer_count = config.max_layers;
        self.curve_height = config.curve_words_per_page / CURVE_WORDS_PER_ROW;
        self.band_height = config.band_words_per_page / BAND_WORDS_PER_ROW;

        // Curve image: R16G16B16A16_SFLOAT, 2D array
        self.curve_image = try createImage2DArray(self.ctx, vk.VK_FORMAT_R16G16B16A16_SFLOAT, CURVE_TEX_WIDTH, self.curve_height, self.layer_count, &self.curve_memory);
        self.curve_view = try createImageView2DArray(self.ctx, self.curve_image, vk.VK_FORMAT_R16G16B16A16_SFLOAT);

        // Band image: R16G16_UINT, 2D array
        self.band_image = try createImage2DArray(self.ctx, vk.VK_FORMAT_R16G16_UINT, BAND_TEX_WIDTH, self.band_height, self.layer_count, &self.band_memory);
        self.band_view = try createImageView2DArray(self.ctx, self.band_image, vk.VK_FORMAT_R16G16_UINT);

        // Layer info image: R32G32B32A32_SFLOAT, 2D
        self.layer_info_image = try createImage2D(self.ctx, vk.VK_FORMAT_R32G32B32A32_SFLOAT, INFO_WIDTH, self.options.layer_info_height, &self.layer_info_memory);
        self.layer_info_view = try createImageView2D(self.ctx, self.layer_info_image, vk.VK_FORMAT_R32G32B32A32_SFLOAT);

        // Image array: R8G8B8A8_SRGB, 2D array (only if max_images > 0)
        if (self.options.max_images > 0) {
            self.image_array_image = try createImage2DArray(self.ctx, vk.VK_FORMAT_R8G8B8A8_SRGB, self.options.max_image_width, self.options.max_image_height, self.options.max_images, &self.image_array_memory);
            self.image_array_view = try createImageView2DArray(self.ctx, self.image_array_image, vk.VK_FORMAT_R8G8B8A8_SRGB);
        }

        // Transition all images to SHADER_READ_ONLY_OPTIMAL
        try self.transitionInitialLayouts();

        // Update descriptor set
        try self.updateDescriptorSet();

        self.initialized = true;
        log.info(.gpu, "atlas gpu resources ready", .{
            .layers = self.layer_count,
            .curve_h = self.curve_height,
            .band_h = self.band_height,
        });
    }

    fn transitionInitialLayouts(self: *DeviceAtlas) !void {
        const cmd = try self.ctx.allocCommandBuffer();
        defer self.ctx.freeCommandBuffer(cmd);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        if (vk.vkBeginCommandBuffer(cmd, &begin_info) != vk.VK_SUCCESS) return error.BeginCommandFailed;

        const images = [_]vk.VkImage{ self.curve_image, self.band_image, self.layer_info_image };
        for (images) |img| {
            if (img == null) continue;
            const barrier = vk.VkImageMemoryBarrier{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
                .image = img,
                .subresourceRange = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = vk.VK_REMAINING_ARRAY_LAYERS,
                },
                .srcAccessMask = 0,
                .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            };
            vk.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
        }

        if (self.image_array_image != null) {
            const barrier = vk.VkImageMemoryBarrier{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
                .image = self.image_array_image,
                .subresourceRange = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = vk.VK_REMAINING_ARRAY_LAYERS,
                },
                .srcAccessMask = 0,
                .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            };
            vk.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
        }

        _ = vk.vkEndCommandBuffer(cmd);
        try self.ctx.submitAndWait(cmd);
    }

    fn updateDescriptorSet(self: *DeviceAtlas) !void {
        var image_infos: [4]vk.VkDescriptorImageInfo = undefined;
        image_infos[0] = .{ .sampler = self.sampler_nearest, .imageView = self.curve_view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        image_infos[1] = .{ .sampler = self.sampler_nearest, .imageView = self.band_view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        image_infos[2] = .{ .sampler = self.sampler_nearest, .imageView = self.layer_info_view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        image_infos[3] = .{
            .sampler = self.sampler_linear,
            .imageView = if (self.image_array_view != null) self.image_array_view else self.curve_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        var writes: [4]vk.VkWriteDescriptorSet = undefined;
        for (&writes, 0..) |*w, i| {
            w.* = .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.desc_set,
                .dstBinding = @intCast(i),
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &image_infos[i],
            };
        }
        vk.vkUpdateDescriptorSets(self.ctx.device, writes.len, &writes, 0, null);
    }

    /// Plan and upload `atlas` into the GPU textures, returning the binding
    /// `emit` must reference. Lazily creates GPU resources. Caller owns the
    /// returned binding's lifetime (release via `releaseBinding`).
    pub fn upload(self: *DeviceAtlas, pool: *snail.PagePool, atlas: *const snail.Atlas) !Binding {
        try self.ensureGpuResources(pool);
        const planner = &self.planner.?;
        const plan = try planner.plan(atlas);
        errdefer _ = planner.release(plan.binding);
        try self.applyRegions(plan.regions);
        return plan.binding;
    }

    /// Release a binding previously returned by `upload`.
    pub fn releaseBinding(self: *DeviceAtlas, binding: Binding) void {
        if (self.planner) |*p| _ = p.release(binding);
    }

    /// Stage every planned region into one host-visible buffer and copy it
    /// into the four atlas textures in a single transfer submit.
    fn applyRegions(self: *DeviceAtlas, regions: []const Region) !void {
        if (regions.len == 0) return;
        var total: usize = 0;
        for (regions) |r| total += r.src.len;
        if (total == 0) return;

        var staging = try StagingBuffer.create(self.ctx, total);
        defer staging.destroy(self.ctx.device);

        const offsets = try self.allocator.alloc(usize, regions.len);
        defer self.allocator.free(offsets);

        var cursor: usize = 0;
        for (regions, 0..) |r, i| {
            @memcpy(staging.mapped[cursor..][0..r.src.len], r.src);
            offsets[i] = cursor;
            cursor += r.src.len;
        }

        const cmd = try self.ctx.allocCommandBuffer();
        defer self.ctx.freeCommandBuffer(cmd);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        if (vk.vkBeginCommandBuffer(cmd, &begin_info) != vk.VK_SUCCESS) return error.BeginCommandFailed;

        var has_curve = false;
        var has_band = false;
        var has_info = false;
        var has_image = false;
        for (regions) |r| switch (r.target) {
            .curve => has_curve = true,
            .band => has_band = true,
            .layer_info => has_info = true,
            .image => has_image = true,
        };

        if (has_curve) transitionAtlasImage(cmd, self.curve_image, self.layer_count, .to_transfer);
        if (has_band) transitionAtlasImage(cmd, self.band_image, self.layer_count, .to_transfer);
        if (has_info) transitionAtlasImage(cmd, self.layer_info_image, 1, .to_transfer);
        if (has_image) transitionAtlasImage(cmd, self.image_array_image, self.options.max_images, .to_transfer);

        for (regions, 0..) |r, i| {
            const dst_image = switch (r.target) {
                .curve => self.curve_image,
                .band => self.band_image,
                .layer_info => self.layer_info_image,
                .image => self.image_array_image,
            };
            if (dst_image == null) continue;
            const layer: u32 = if (r.target == .layer_info) 0 else r.layer;
            const copy = vk.VkBufferImageCopy{
                .bufferOffset = @intCast(offsets[i]),
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = layer,
                    .layerCount = 1,
                },
                .imageOffset = .{ .x = @intCast(r.col_base), .y = @intCast(r.row_base), .z = 0 },
                .imageExtent = .{ .width = r.width, .height = r.height, .depth = 1 },
            };
            vk.vkCmdCopyBufferToImage(cmd, staging.buffer, dst_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        }

        if (has_curve) transitionAtlasImage(cmd, self.curve_image, self.layer_count, .to_shader);
        if (has_band) transitionAtlasImage(cmd, self.band_image, self.layer_count, .to_shader);
        if (has_info) transitionAtlasImage(cmd, self.layer_info_image, 1, .to_shader);
        if (has_image) transitionAtlasImage(cmd, self.image_array_image, self.options.max_images, .to_shader);

        if (vk.vkEndCommandBuffer(cmd) != vk.VK_SUCCESS) return error.EndCommandFailed;
        try self.ctx.submitAndWait(cmd);
    }
};

const TransitionDir = enum { to_transfer, to_shader };

fn transitionAtlasImage(cmd: vk.VkCommandBuffer, image: vk.VkImage, layers: u32, dir: TransitionDir) void {
    if (image == null) return;
    const to_transfer = dir == .to_transfer;
    const barrier = vk.VkImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = if (to_transfer) vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = if (to_transfer) vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL else vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = layers,
        },
        .srcAccessMask = if (to_transfer) vk.VK_ACCESS_SHADER_READ_BIT else vk.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = if (to_transfer) vk.VK_ACCESS_TRANSFER_WRITE_BIT else vk.VK_ACCESS_SHADER_READ_BIT,
    };
    const src_stage: vk.VkPipelineStageFlags = if (to_transfer) vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT else vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
    const dst_stage: vk.VkPipelineStageFlags = if (to_transfer) vk.VK_PIPELINE_STAGE_TRANSFER_BIT else vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    vk.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
}

/// Transient host-visible upload buffer, mapped for the duration of one
/// atlas upload.
const StagingBuffer = struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    mapped: [*]u8,

    fn create(ctx: *const Context, size: usize) !StagingBuffer {
        const buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = @intCast(size),
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        };
        var buffer: vk.VkBuffer = null;
        if (vk.vkCreateBuffer(ctx.device, &buffer_info, null, &buffer) != vk.VK_SUCCESS) return error.BufferCreationFailed;
        errdefer vk.vkDestroyBuffer(ctx.device, buffer, null);

        var mem_reqs: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(ctx.device, buffer, &mem_reqs);

        var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_props);
        var mem_type: u32 = 0;
        for (0..mem_props.memoryTypeCount) |i| {
            if (mem_reqs.memoryTypeBits & (@as(u32, 1) << @intCast(i)) != 0 and
                mem_props.memoryTypes[i].propertyFlags & (vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) == (vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
            {
                mem_type = @intCast(i);
                break;
            }
        }

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = mem_type,
        };
        var memory: vk.VkDeviceMemory = null;
        if (vk.vkAllocateMemory(ctx.device, &alloc_info, null, &memory) != vk.VK_SUCCESS) return error.MemoryAllocationFailed;
        errdefer vk.vkFreeMemory(ctx.device, memory, null);

        if (vk.vkBindBufferMemory(ctx.device, buffer, memory, 0) != vk.VK_SUCCESS) return error.BindBufferFailed;

        var mapped: ?*anyopaque = null;
        if (vk.vkMapMemory(ctx.device, memory, 0, @intCast(size), 0, &mapped) != vk.VK_SUCCESS) return error.MapFailed;

        return .{ .buffer = buffer, .memory = memory, .mapped = @ptrCast(mapped.?) };
    }

    fn destroy(self: *StagingBuffer, device: vk.VkDevice) void {
        vk.vkUnmapMemory(device, self.memory);
        vk.vkDestroyBuffer(device, self.buffer, null);
        vk.vkFreeMemory(device, self.memory, null);
    }
};

// ── Image creation helpers ──

fn createImage2DArray(ctx: *const Context, format: vk.VkFormat, width: u32, height: u32, layers: u32, out_memory: *vk.VkDeviceMemory) !vk.VkImage {
    return createImage(ctx, format, width, height, layers, true, out_memory);
}

fn createImage2D(ctx: *const Context, format: vk.VkFormat, width: u32, height: u32, out_memory: *vk.VkDeviceMemory) !vk.VkImage {
    return createImage(ctx, format, width, height, 1, false, out_memory);
}

fn createImage(ctx: *const Context, format: vk.VkFormat, width: u32, height: u32, layers: u32, _: bool, out_memory: *vk.VkDeviceMemory) !vk.VkImage {
    const usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT;
    const create_info = vk.VkImageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = layers,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    var image: vk.VkImage = null;
    if (vk.vkCreateImage(ctx.device, &create_info, null, &image) != vk.VK_SUCCESS) return error.ImageCreationFailed;
    errdefer vk.vkDestroyImage(ctx.device, image, null);

    var mem_reqs: vk.VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(ctx.device, image, &mem_reqs);

    // Find DEVICE_LOCAL memory type
    var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_props);
    var memory_type_index: u32 = 0;
    for (0..mem_props.memoryTypeCount) |i| {
        if (mem_reqs.memoryTypeBits & (@as(u32, 1) << @intCast(i)) != 0 and
            mem_props.memoryTypes[i].propertyFlags & vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0)
        {
            memory_type_index = @intCast(i);
            break;
        }
    }

    const alloc_info = vk.VkMemoryAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = memory_type_index,
    };
    if (vk.vkAllocateMemory(ctx.device, &alloc_info, null, out_memory) != vk.VK_SUCCESS) return error.MemoryAllocationFailed;
    errdefer vk.vkFreeMemory(ctx.device, out_memory.*, null);

    if (vk.vkBindImageMemory(ctx.device, image, out_memory.*, 0) != vk.VK_SUCCESS) return error.BindImageFailed;
    return image;
}

fn createImageView2DArray(ctx: *const Context, image: vk.VkImage, format: vk.VkFormat) !vk.VkImageView {
    return createImageView(ctx, image, format, vk.VK_IMAGE_VIEW_TYPE_2D_ARRAY, vk.VK_REMAINING_ARRAY_LAYERS);
}

fn createImageView2D(ctx: *const Context, image: vk.VkImage, format: vk.VkFormat) !vk.VkImageView {
    return createImageView(ctx, image, format, vk.VK_IMAGE_VIEW_TYPE_2D, 1);
}

fn createImageView(ctx: *const Context, image: vk.VkImage, format: vk.VkFormat, view_type: vk.VkImageViewType, layer_count: u32) !vk.VkImageView {
    const view_info = vk.VkImageViewCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = view_type,
        .format = format,
        .components = .{
            .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = layer_count,
        },
    };
    var view: vk.VkImageView = null;
    if (vk.vkCreateImageView(ctx.device, &view_info, null, &view) != vk.VK_SUCCESS) return error.ImageViewCreationFailed;
    return view;
}
