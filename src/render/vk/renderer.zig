//! Custom Vulkan renderer: pipelines, vertex/index buffers, and command
//! recording. Consumes snail's render.records data contract (Instance,
//! DrawBatch) and renders into a caller-provided render pass.
//!
//! No Wayland types. The caller provides a VkCommandBuffer with an
//! already-begun render pass; this module records draw commands into it.

const std = @import("std");
const snail = @import("snail");
const shaders = @import("snail-shaders");
const log = @import("../../log.zig");
const Context = @import("context.zig").Context;
const DmabufTarget = @import("dmabuf.zig").DmabufTarget;
const memtrack = @import("memtrack.zig");

const vk = @import("vulkan.zig").vk;

// ── Pipeline contract (mirrors snail's demo render/vulkan/contract.zig) ──

pub const Family = enum {
    text,
    colr,
    path_quadratic,
    path_conic,
    path,
    tt_hinted_text,
    autohint,
    subpixel,
    tt_hinted_subpixel,
    autohint_subpixel,
};

pub const FAMILY_COUNT = @typeInfo(Family).@"enum".fields.len;

const Blend = enum { premultiplied, dual_source };

const PipelineRecipe = struct {
    vert: []align(4) const u8,
    frag: []align(4) const u8,
    blend: Blend,
    requires_dual_src: bool = false,
};

/// 4-byte-aligned SPIR-V for a *flat* (uniform-texel-buffer) fragment family.
/// snail 0.15 ships both image-sampled and flat fragment variants; we store
/// the atlas in flat texel buffers (device_atlas.zig), so the fragment shaders
/// must be the flat ones — `textSpv(.fragment)` etc. are the image-sampled
/// variants and mismatch the descriptor layout. `flatFragSpvRaw` returns an
/// unaligned slice, so re-materialize it into a static aligned array.
fn flatFrag(comptime fam: shaders.FlatFamily) []align(4) const u8 {
    const holder = struct {
        const aligned: [shaders.flatFragSpvRaw(fam).len]u8 align(4) = blk: {
            var a: [shaders.flatFragSpvRaw(fam).len]u8 align(4) = undefined;
            @memcpy(a[0..], shaders.flatFragSpvRaw(fam));
            break :blk a;
        };
    };
    return &holder.aligned;
}

fn recipe(family: Family) PipelineRecipe {
    return switch (family) {
        .text => .{ .vert = shaders.textSpv(.vertex), .frag = flatFrag(.text), .blend = .premultiplied },
        .colr => .{ .vert = shaders.textSpv(.vertex), .frag = flatFrag(.colr), .blend = .premultiplied },
        .path_quadratic => .{ .vert = shaders.textSpv(.vertex), .frag = flatFrag(.path_quadratic), .blend = .premultiplied },
        .path_conic => .{ .vert = shaders.textSpv(.vertex), .frag = flatFrag(.path_conic), .blend = .premultiplied },
        .path => .{ .vert = shaders.textSpv(.vertex), .frag = flatFrag(.path), .blend = .premultiplied },
        .tt_hinted_text => .{ .vert = shaders.textSpv(.vertex), .frag = flatFrag(.tt_hinted_text), .blend = .premultiplied },
        .autohint => .{ .vert = shaders.autohintSpv(.vertex), .frag = flatFrag(.autohint), .blend = .premultiplied },
        .subpixel => .{ .vert = shaders.textSpv(.vertex), .frag = flatFrag(.text_subpixel), .blend = .dual_source, .requires_dual_src = true },
        .tt_hinted_subpixel => .{ .vert = shaders.textSpv(.vertex), .frag = flatFrag(.tt_hinted_text_subpixel), .blend = .dual_source, .requires_dual_src = true },
        .autohint_subpixel => .{ .vert = shaders.autohintSpv(.vertex), .frag = flatFrag(.autohint_subpixel), .blend = .dual_source, .requires_dual_src = true },
    };
}

// ── Push constants (from snail-shaders reflection) ──

pub const PushConstants = shaders.reflection.PushConstants;

const PUSH_CONSTANT_SIZE: u32 = @sizeOf(PushConstants);
const PUSH_CONSTANT_STAGES = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT;

// ── Descriptor bindings ──

pub const CURVE_BINDING: u32 = 0;
pub const BAND_BINDING: u32 = 1;
pub const LAYER_INFO_BINDING: u32 = 2;
pub const IMAGE_BINDING: u32 = 3;

// ── Vertex format (Instance = 72 bytes, instance-rate) ──

const BYTES_PER_INSTANCE: usize = 72;

const QUAD_INDICES = [_]u32{ 0, 1, 2, 0, 2, 3 };
const INDICES_PER_GLYPH: u32 = 6;

// ── ShapeKind → Family mapping ──

const ShapeKind = snail.render.records.ShapeKind;

fn kindHasSubpixelFamily(kind: ShapeKind) bool {
    return switch (kind) {
        .regular, .tt_hinted_text, .autohint => true,
        .colr, .path_quadratic, .path_conic, .path => false,
    };
}

const TextRenderMode = enum { grayscale, subpixel_dual_source };

fn textRenderMode(subpixel_order: snail.render.records.ShapeKind, supports_dual_src: bool, raster_subpixel: i32) TextRenderMode {
    _ = subpixel_order;
    if (supports_dual_src and raster_subpixel != 0) return .subpixel_dual_source;
    return .grayscale;
}

fn familyForKind(kind: ShapeKind, mode: TextRenderMode) Family {
    return switch (kind) {
        .regular => if (mode == .subpixel_dual_source) .subpixel else .text,
        .colr => .colr,
        .path_quadratic => .path_quadratic,
        .path_conic => .path_conic,
        .path => .path,
        .tt_hinted_text => if (mode == .subpixel_dual_source) .tt_hinted_subpixel else .tt_hinted_text,
        .autohint => if (mode == .subpixel_dual_source) .autohint_subpixel else .autohint,
    };
}

// ── Host-visible buffer ──

const HostBuffer = struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    mapped: [*]u8,
    size: usize,

    fn init(ctx: *const Context, size: usize, usage: vk.VkBufferUsageFlags) !HostBuffer {
        const buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        };
        var buffer: vk.VkBuffer = null;
        if (vk.vkCreateBuffer(ctx.device, &buffer_info, null, &buffer) != vk.VK_SUCCESS) return error.BufferCreationFailed;
        errdefer vk.vkDestroyBuffer(ctx.device, buffer, null);

        var mem_reqs: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(ctx.device, buffer, &mem_reqs);

        // Find HOST_VISIBLE | HOST_COHERENT memory type
        var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_props);
        var memory_type_index: u32 = 0;
        for (0..mem_props.memoryTypeCount) |i| {
            if (mem_reqs.memoryTypeBits & (@as(u32, 1) << @intCast(i)) != 0 and
                mem_props.memoryTypes[i].propertyFlags & (vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0)
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
        var memory: vk.VkDeviceMemory = null;
        if (vk.vkAllocateMemory(ctx.device, &alloc_info, null, &memory) != vk.VK_SUCCESS) return error.MemoryAllocationFailed;
        errdefer vk.vkFreeMemory(ctx.device, memory, null);

        if (vk.vkBindBufferMemory(ctx.device, buffer, memory, 0) != vk.VK_SUCCESS) return error.BindBufferFailed;

        var mapped_ptr: ?[*]u8 = null;
        if (vk.vkMapMemory(ctx.device, memory, 0, size, 0, @ptrCast(&mapped_ptr)) != vk.VK_SUCCESS) return error.MapFailed;
        errdefer vk.vkUnmapMemory(ctx.device, memory);

        memtrack.host_buffer.onAlloc(size);
        return .{
            .buffer = buffer,
            .memory = memory,
            .mapped = mapped_ptr.?,
            .size = size,
        };
    }

    fn bytes(self: *const HostBuffer) []u8 {
        return self.mapped[0..self.size];
    }

    fn deinit(self: *HostBuffer, device: vk.VkDevice) void {
        vk.vkUnmapMemory(device, self.memory);
        vk.vkDestroyBuffer(device, self.buffer, null);
        vk.vkFreeMemory(device, self.memory, null);
        memtrack.host_buffer.onFree(self.size);
    }
};

// ── Renderer ──

pub const Renderer = struct {
    device: vk.VkDevice,
    pipeline_layout: vk.VkPipelineLayout,
    pipelines: [FAMILY_COUNT]vk.VkPipeline,
    supports_dual_src: bool,
    ibo: HostBuffer,
    vbo: HostBuffer,
    slot_bytes: usize,
    num_slots: u32,
    cur_slot_base: usize = 0,
    cursor: usize = 0,

    pub fn init(ctx: *const Context, desc_set_layout: vk.VkDescriptorSetLayout, slot_bytes: usize, num_slots: u32) !Renderer {
        // ── Pipeline layout ──
        const pc_range = vk.VkPushConstantRange{
            .stageFlags = PUSH_CONSTANT_STAGES,
            .offset = 0,
            .size = PUSH_CONSTANT_SIZE,
        };

        const layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &desc_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &pc_range,
        };

        var pipeline_layout: vk.VkPipelineLayout = null;
        if (vk.vkCreatePipelineLayout(ctx.device, &layout_info, null, &pipeline_layout) != vk.VK_SUCCESS) {
            return error.PipelineLayoutCreationFailed;
        }
        errdefer vk.vkDestroyPipelineLayout(ctx.device, pipeline_layout, null);

        // ── Index buffer ──
        const ibo_size = @sizeOf(@TypeOf(QUAD_INDICES));
        var ibo = try HostBuffer.init(ctx, ibo_size, vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        errdefer ibo.deinit(ctx.device);
        @memcpy(ibo.bytes()[0..ibo_size], std.mem.asBytes(&QUAD_INDICES));

        // ── Vertex ring buffer ──
        const vbo_size = slot_bytes * num_slots;
        var vbo = try HostBuffer.init(ctx, vbo_size, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        errdefer vbo.deinit(ctx.device);

        // ── Pipelines ──
        var pipelines: [FAMILY_COUNT]vk.VkPipeline = [_]vk.VkPipeline{null} ** FAMILY_COUNT;
        for (std.enums.values(Family)) |family| {
            const r = recipe(family);
            if (r.requires_dual_src and !ctx.supports_dual_source_blend) {
                // Skip subpixel families if device doesn't support dual-source blend
                continue;
            }
            pipelines[@intFromEnum(family)] = try buildPipeline(ctx, pipeline_layout, r);
        }
        errdefer {
            for (pipelines) |p| if (p != null) vk.vkDestroyPipeline(ctx.device, p, null);
        }

        return .{
            .device = ctx.device,
            .pipeline_layout = pipeline_layout,
            .pipelines = pipelines,
            .supports_dual_src = ctx.supports_dual_source_blend,
            .ibo = ibo,
            .vbo = vbo,
            .slot_bytes = slot_bytes,
            .num_slots = num_slots,
        };
    }

    pub fn deinit(self: *Renderer) void {
        for (self.pipelines) |p| if (p != null) vk.vkDestroyPipeline(self.device, p, null);
        vk.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.ibo.deinit(self.device);
        self.vbo.deinit(self.device);
    }

    /// Worst-case per-slot vertex-ring bytes for a `cols`×`rows` grid. Each
    /// cell can emit at most: a background fill, two decoration rects
    /// (underline + strike), a selection overlay, and *either* a glyph *or*
    /// up to four box-drawing rects — eight instances (glyph and box rects
    /// are mutually exclusive per cell). Sized to the actual grid, not the
    /// 1024×320 maximum, so the ring scales with the window instead of
    /// reserving ~380 MB up front. A floor keeps tiny windows workable.
    pub fn slotBytesForGrid(cols: usize, rows: usize) usize {
        const per_cell_worst: usize = 8;
        const overlay_slack: usize = 256; // cursor + scrollbar + bell + headroom
        const instances = cols * rows * per_cell_worst + overlay_slack;
        const min_bytes: usize = 256 * 1024;
        return @max(instances * BYTES_PER_INSTANCE, min_bytes);
    }

    /// Grow the vertex ring so each slot holds at least `slot_bytes`. No-op
    /// when already large enough (grow-only: an interactive resize settles at
    /// the largest grid seen rather than thrashing the allocation). Waits for
    /// the device to idle first — the old buffer may still be referenced by an
    /// in-flight frame — so call only from the (infrequent) configure path.
    pub fn ensureSlotCapacity(self: *Renderer, ctx: *const Context, slot_bytes: usize) !void {
        if (slot_bytes <= self.slot_bytes) return;
        _ = vk.vkDeviceWaitIdle(self.device);
        var new_vbo = try HostBuffer.init(ctx, slot_bytes * self.num_slots, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        errdefer new_vbo.deinit(self.device);
        self.vbo.deinit(self.device);
        self.vbo = new_vbo;
        self.slot_bytes = slot_bytes;
    }

    pub fn beginFrame(self: *Renderer, frame_slot: u32) void {
        self.cur_slot_base = (frame_slot % self.num_slots) * self.slot_bytes;
        self.cursor = 0;
    }

    pub const RenderError = error{
        VertexBufferFull,
        StaleBinding,
        EmptyShader,
    };

    pub fn render(
        self: *Renderer,
        cmd: vk.VkCommandBuffer,
        desc_set: vk.VkDescriptorSet,
        draw_state: anytype,
        atlas_page_texels: [2]i32,
        instances: []const snail.render.records.Instance,
        batches: []const snail.render.records.DrawBatch,
    ) RenderError!void {
        if (instances.len == 0 or batches.len == 0) return;

        const instance_bytes = std.mem.sliceAsBytes(instances);
        if (self.cursor + instance_bytes.len > self.slot_bytes) return error.VertexBufferFull;

        // Copy instance data into vertex ring
        const base = self.cur_slot_base + self.cursor;
        @memcpy(self.vbo.bytes()[base..][0..instance_bytes.len], instance_bytes);
        self.cursor += instance_bytes.len;

        // Set viewport (Y-flipped, matching GL convention)
        const w: f32 = @floatFromInt(draw_state.surface.pixel_width);
        const h: f32 = @floatFromInt(draw_state.surface.pixel_height);
        const viewport = vk.VkViewport{
            .x = 0,
            .y = h,
            .width = w,
            .height = -h,
            .minDepth = 0,
            .maxDepth = 1,
        };
        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = draw_state.surface.pixel_width, .height = draw_state.surface.pixel_height },
        };
        vk.vkCmdSetViewport(cmd, 0, 1, &viewport);
        vk.vkCmdSetScissor(cmd, 0, 1, &scissor);

        // Bind index buffer
        vk.vkCmdBindIndexBuffer(cmd, self.ibo.buffer, 0, vk.VK_INDEX_TYPE_UINT32);

        // Bind descriptor set (once — atlas cache owns it)
        vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &desc_set, 0, null);

        // Per batch: bind pipeline, push constants, bind vertex buffer, draw
        for (batches) |batch| {
            const family = familyForKind(batch.kind, textRenderMode(batch.kind, self.supports_dual_src, draw_state.raster.subpixel_order_int));
            const pipeline = self.pipelines[@intFromEnum(family)];
            if (pipeline == null) continue;

            vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);

            // Build push constants. page_base selects the batch's 256-layer
            // bank (snail 0.15 flat page storage).
            const pc = PushConstants{
                .mvp = draw_state.mvp.data,
                .viewport = .{ w, h },
                .subpixel_order = @intCast(draw_state.raster.subpixel_order_int),
                .output_srgb = if (draw_state.surface.encoding.shader_encodes_srgb) 1 else 0,
                .page_base = @intCast(batch.page_base),
                .coverage_exponent = draw_state.raster.coverage_exponent,
                .dither_scale = draw_state.surface.format.dither_amplitude,
                .mask_output = if (draw_state.surface.format.has_color) 0 else 1,
                .atlas_page_texels = atlas_page_texels,
            };
            vk.vkCmdPushConstants(cmd, self.pipeline_layout, PUSH_CONSTANT_STAGES, 0, PUSH_CONSTANT_SIZE, &pc);

            // Bind vertex buffer at batch's instance offset
            const vbo_offset: vk.VkDeviceSize = base + batch.first_instance * BYTES_PER_INSTANCE;
            vk.vkCmdBindVertexBuffers(cmd, 0, 1, &self.vbo.buffer, &vbo_offset);

            vk.vkCmdDrawIndexed(cmd, INDICES_PER_GLYPH, batch.instance_count, 0, 0, 0);
        }
    }
};

fn buildPipeline(ctx: *const Context, layout: vk.VkPipelineLayout, r: PipelineRecipe) !vk.VkPipeline {
    if (r.vert.len == 0 or r.frag.len == 0) return error.EmptyShader;

    // Shader modules
    const vert_module = try createShaderModule(ctx.device, r.vert);
    defer vk.vkDestroyShaderModule(ctx.device, vert_module, null);
    const frag_module = try createShaderModule(ctx.device, r.frag);
    defer vk.vkDestroyShaderModule(ctx.device, frag_module, null);

    const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_module,
            .pName = "main",
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_module,
            .pName = "main",
        },
    };

    // Vertex input (instance-rate, binding 0, stride 72)
    const binding_desc = vk.VkVertexInputBindingDescription{
        .binding = 0,
        .stride = @intCast(BYTES_PER_INSTANCE),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_INSTANCE,
    };

    // 7 attributes matching Instance layout
    const attr_descs = [_]vk.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = vk.VK_FORMAT_R16G16B16A16_SFLOAT, .offset = 0 }, // rect
        .{ .location = 1, .binding = 0, .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = 8 }, // xform
        .{ .location = 2, .binding = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 24 }, // origin
        .{ .location = 3, .binding = 0, .format = vk.VK_FORMAT_R32G32_UINT, .offset = 32 }, // glyph
        .{ .location = 4, .binding = 0, .format = vk.VK_FORMAT_R32G32B32A32_UINT, .offset = 40 }, // payload
        .{ .location = 5, .binding = 0, .format = vk.VK_FORMAT_R16G16B16A16_SFLOAT, .offset = 56 }, // color
        .{ .location = 6, .binding = 0, .format = vk.VK_FORMAT_R16G16B16A16_SFLOAT, .offset = 64 }, // tint
    };

    const vertex_input_state = vk.VkPipelineVertexInputStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding_desc,
        .vertexAttributeDescriptionCount = attr_descs.len,
        .pVertexAttributeDescriptions = &attr_descs,
    };

    const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };

    const viewport_state = vk.VkPipelineViewportStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };

    const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = vk.VK_POLYGON_MODE_FILL,
        .cullMode = vk.VK_CULL_MODE_NONE,
        .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0,
    };

    const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
    };

    // Blend
    const blend_attachment = blk: {
        const ba = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = if (r.blend == .dual_source) vk.VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR else vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };
        break :blk ba;
    };

    const color_blend_state = vk.VkPipelineColorBlendStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = vk.VK_FALSE,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    };

    const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
    const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = shader_stages.len,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_state,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pColorBlendState = &color_blend_state,
        .pDynamicState = &dynamic_state,
        .layout = layout,
        .renderPass = ctx.render_pass,
        .subpass = 0,
    };

    var pipeline: vk.VkPipeline = null;
    const result = vk.vkCreateGraphicsPipelines(ctx.device, null, 1, &pipeline_info, null, &pipeline);
    if (result != vk.VK_SUCCESS) {
        log.err(.gpu, "pipeline creation failed", .{ .err = result });
        return error.PipelineCreationFailed;
    }
    return pipeline;
}

/// snail's demo renderer consumes a `DrawState` whose color-space knobs are
/// methods; our `Renderer.render` reads them as plain fields, so we build a
/// matching literal here. The framebuffer binds an sRGB image view, so the
/// hardware encodes linear→sRGB on store — the shader must NOT encode itself
/// (`shader_encodes_srgb = false`) and outputs linear.
fn makeDrawState(width: u32, height: u32) DrawStateLit {
    const wf: f32 = @floatFromInt(width);
    const hf: f32 = @floatFromInt(height);
    return .{
        .surface = .{
            .pixel_width = width,
            .pixel_height = height,
            .encoding = .{ .shader_encodes_srgb = false },
            .format = .{ .dither_amplitude = 1.0 / 255.0, .has_color = true },
        },
        .mvp = snail.Mat4.ortho(0, wf, hf, 0, -1, 1),
        .raster = .{ .subpixel_order_int = 0, .coverage_exponent = 1.0 },
    };
}

const DrawStateLit = struct {
    surface: struct {
        pixel_width: u32,
        pixel_height: u32,
        encoding: struct { shader_encodes_srgb: bool },
        format: struct { dither_amplitude: f32, has_color: bool },
    },
    mvp: snail.Mat4,
    raster: struct { subpixel_order_int: i32, coverage_exponent: f32 },
};

fn imageBarrier(
    cmd: vk.VkCommandBuffer,
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    src_access: vk.VkAccessFlags,
    dst_access: vk.VkAccessFlags,
    src_stage: vk.VkPipelineStageFlags,
    dst_stage: vk.VkPipelineStageFlags,
) void {
    const barrier = vk.VkImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .srcAccessMask = src_access,
        .dstAccessMask = dst_access,
    };
    vk.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
}

/// Record a full frame into `target`: clear to `clear_color`, draw the
/// instances/batches, and leave the image in `GENERAL` for the compositor to
/// scan out. Blocks until the GPU finishes (submitAndWait).
///
/// Returns the GPU-side execution time of the frame command buffer in
/// nanoseconds (timestamp queries, top→bottom of pipe), or 0 when the device
/// doesn't support timestamps. The synchronous submit makes the readback
/// race-free.
/// How to submit the recorded frame.
///  - default (`.{}`): allocate a throwaway command buffer, `submitAndWait`,
///    read timestamps — the synchronous path (headless + no-explicit-sync).
///  - explicit sync: pass a caller-owned `cmd` (not freed here; it must outlive
///    the GPU work) and a `signal_sem` — submit async (no wait, no timestamps),
///    so the compositor waits on the exported semaphore instead.
pub const SubmitOpts = struct {
    cmd: vk.VkCommandBuffer = null,
    signal_sem: vk.VkSemaphore = null,
};

pub fn renderToTarget(
    self: *Renderer,
    ctx: *const Context,
    target: *const DmabufTarget,
    desc_set: vk.VkDescriptorSet,
    frame_slot: u32,
    clear_color: [4]f32,
    atlas_page_texels: [2]i32,
    instances: []const snail.render.records.Instance,
    batches: []const snail.render.records.DrawBatch,
    submit: SubmitOpts,
) !u64 {
    const w = target.desc.width;
    const h = target.desc.height;

    const cmd = submit.cmd orelse try ctx.allocCommandBuffer();
    defer if (submit.cmd == null) ctx.freeCommandBuffer(cmd);

    const begin_info = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    if (vk.vkBeginCommandBuffer(cmd, &begin_info) != vk.VK_SUCCESS) return error.BeginCommandFailed;

    // Async submit skips timestamps: the query readback needs the frame to
    // have completed, which the synchronous path guarantees and this one does
    // not (single shared query pool).
    const ts_pool = if (submit.signal_sem == null) ctx.timestamp_query_pool else null;
    if (ts_pool != null) {
        vk.vkCmdResetQueryPool(cmd, ts_pool, 0, 2);
        vk.vkCmdWriteTimestamp(cmd, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, ts_pool, 0);
    }

    // Whatever the image's prior layout, discard it — the render pass clears.
    imageBarrier(
        cmd,
        target.image,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        0,
        vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    );

    const clear = vk.VkClearValue{ .color = .{ .float32 = clear_color } };
    const rp_begin = vk.VkRenderPassBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = ctx.render_pass,
        .framebuffer = target.framebuffer,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = w, .height = h } },
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vk.vkCmdBeginRenderPass(cmd, &rp_begin, vk.VK_SUBPASS_CONTENTS_INLINE);

    // Diagnostic: SCRGO_GPU_CLEAR_ONLY skips the glyph draw (clear pass only)
    // to isolate framebuffer/dmabuf issues from draw-command issues.
    if (std.c.getenv("SCRGO_GPU_CLEAR_ONLY") == null) {
        self.beginFrame(frame_slot);
        const draw_state = makeDrawState(w, h);
        self.render(cmd, desc_set, draw_state, atlas_page_texels, instances, batches) catch |err| {
            log.warn(.gpu, "draw record failed", .{ .err = err });
        };
    }

    vk.vkCmdEndRenderPass(cmd);

    // Hand the image off for external (compositor) scanout.
    imageBarrier(
        cmd,
        target.image,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_GENERAL,
        vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        0,
        vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
    );

    if (ts_pool != null) {
        vk.vkCmdWriteTimestamp(cmd, vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, ts_pool, 1);
    }

    if (vk.vkEndCommandBuffer(cmd) != vk.VK_SUCCESS) return error.EndCommandFailed;
    if (submit.signal_sem) |sem| {
        // Async: the compositor waits on `sem` (bridged to a DRM syncobj); we
        // don't drain the queue. No timestamp readback (frame isn't done).
        try ctx.submitSignal(cmd, sem);
        return 0;
    }
    try ctx.submitAndWait(cmd);

    if (ts_pool != null) {
        var raw: [2]u64 = undefined;
        const qr = vk.vkGetQueryPoolResults(
            ctx.device,
            ts_pool,
            0,
            2,
            @sizeOf([2]u64),
            &raw,
            @sizeOf(u64),
            vk.VK_QUERY_RESULT_64_BIT,
        );
        if (qr == vk.VK_SUCCESS) {
            const mask: u64 = if (ctx.timestamp_valid_bits >= 64)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(ctx.timestamp_valid_bits)) - 1;
            const ticks = (raw[1] -% raw[0]) & mask;
            return @intFromFloat(@as(f64, @floatFromInt(ticks)) * ctx.timestamp_period);
        }
    }
    return 0;
}

fn createShaderModule(device: vk.VkDevice, spv: []align(4) const u8) !vk.VkShaderModule {
    const create_info = vk.VkShaderModuleCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spv.len,
        .pCode = @ptrCast(spv.ptr),
    };
    var module: vk.VkShaderModule = null;
    if (vk.vkCreateShaderModule(device, &create_info, null, &module) != vk.VK_SUCCESS) {
        return error.ShaderModuleCreationFailed;
    }
    return module;
}
