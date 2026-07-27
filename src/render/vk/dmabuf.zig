//! Vulkan image with external memory → dmabuf fd export.
//!
//! Creates a VkImage with DRM format modifier tiling and external
//! memory DMA_BUF handle type, exports a dmabuf fd, and extracts
//! (modifier, stride, offset) for Wayland linux-dmabuf.
//!
//! No Wayland types, no GBM, no EGL. The output (fd + BufferDesc) is
//! the only thing that crosses to the compositor layer.

const std = @import("std");
const gpu_buffer = @import("../gpu_buffer.zig");
const log = @import("../../log.zig");
const Context = @import("context.zig").Context;
const memtrack = @import("memtrack.zig");

const vk = @import("vulkan.zig").vk;

const drm = @cImport({
    @cInclude("drm_fourcc.h");
});

pub const DmabufTarget = struct {
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
    view: vk.VkImageView,
    framebuffer: vk.VkFramebuffer,
    fd: c_int = -1,
    desc: gpu_buffer.BufferDesc = .{},

    pub fn create(ctx: *const Context, width: u32, height: u32) !DmabufTarget {
        const vk_format = vk.VK_FORMAT_R8G8B8A8_UNORM;
        const drm_format: u32 = drm.DRM_FORMAT_ABGR8888;

        // ── Enumerate the format's DRM modifiers ──
        // The old code hard-coded DRM_FORMAT_MOD_LINEAR, which many GPUs
        // (notably NVIDIA) cannot use as a color attachment — rendering into
        // such an image faults the device. Instead we query every modifier
        // the driver advertises for this format and keep only those whose
        // tiling features include COLOR_ATTACHMENT, then let the driver pick
        // the best one from that renderable set.
        var mod_list = vk.VkDrmFormatModifierPropertiesListEXT{
            .sType = vk.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
            .drmFormatModifierCount = 0,
            .pDrmFormatModifierProperties = null,
        };
        var fmt_props2 = vk.VkFormatProperties2{
            .sType = vk.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
            .formatProperties = std.mem.zeroes(vk.VkFormatProperties),
        };
        fmt_props2.pNext = &mod_list;
        vk.vkGetPhysicalDeviceFormatProperties2(ctx.physical_device, vk_format, &fmt_props2);

        const max_mods = 256;
        var mod_props_buf: [max_mods]vk.VkDrmFormatModifierPropertiesEXT = undefined;
        const mod_count = @min(mod_list.drmFormatModifierCount, max_mods);
        mod_list.drmFormatModifierCount = mod_count;
        mod_list.pDrmFormatModifierProperties = &mod_props_buf;
        vk.vkGetPhysicalDeviceFormatProperties2(ctx.physical_device, vk_format, &fmt_props2);

        var renderable: [max_mods]u64 = undefined;
        var renderable_count: u32 = 0;
        for (mod_props_buf[0..mod_count]) |mp| {
            if (mp.drmFormatModifierTilingFeatures & vk.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT == 0) continue;
            // Confirm this modifier is exportable as a dmabuf at the size/usage
            // we need.
            const drm_mod_info = vk.VkPhysicalDeviceImageDrmFormatModifierInfoEXT{
                .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
                .drmFormatModifier = mp.drmFormatModifier,
                .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            };
            var ext_image_info = vk.VkPhysicalDeviceExternalImageFormatInfo{
                .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
                .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
            };
            ext_image_info.pNext = &drm_mod_info;
            var format_info = vk.VkPhysicalDeviceImageFormatInfo2{
                .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
                .format = vk_format,
                .type = vk.VK_IMAGE_TYPE_2D,
                .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
                .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                .flags = 0,
            };
            format_info.pNext = &ext_image_info;

            var ext_props = vk.VkExternalImageFormatProperties{
                .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
                .externalMemoryProperties = std.mem.zeroes(vk.VkExternalMemoryProperties),
            };
            var props2 = vk.VkImageFormatProperties2{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
                .imageFormatProperties = std.mem.zeroes(vk.VkImageFormatProperties),
            };
            props2.pNext = &ext_props;

            if (vk.vkGetPhysicalDeviceImageFormatProperties2(ctx.physical_device, &format_info, &props2) != vk.VK_SUCCESS) continue;
            if (ext_props.externalMemoryProperties.externalMemoryFeatures & vk.VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT == 0) continue;

            renderable[renderable_count] = mp.drmFormatModifier;
            renderable_count += 1;
        }

        if (renderable_count == 0) {
            log.err(.gpu, "no renderable+exportable dmabuf modifier for format", .{ .format = drm_format });
            return error.NoRenderableModifier;
        }

        const modifier_list = vk.VkImageDrmFormatModifierListCreateInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
            .drmFormatModifierCount = renderable_count,
            .pDrmFormatModifiers = &renderable,
        };

        // ── Create image ──
        const external_mem_info = vk.VkExternalMemoryImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };

        // The image memory is exported as `vk_format` (UNORM → DRM ABGR8888),
        // but the framebuffer binds an sRGB view so the hardware does
        // gamma-correct linear blending. That requires MUTABLE_FORMAT + a
        // view-format list naming both compatible formats.
        const view_formats = [_]vk.VkFormat{ vk_format, vk.VK_FORMAT_R8G8B8A8_SRGB };
        const format_list = vk.VkImageFormatListCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO,
            .viewFormatCount = view_formats.len,
            .pViewFormats = &view_formats,
        };

        const image_create_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk_format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .flags = vk.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT,
            .pNext = &external_mem_info,
        };
        // pNext chain: image ← external_mem_info ← modifier_list ← format_list.
        var modifier_list_mut = modifier_list;
        modifier_list_mut.pNext = &format_list;
        var ext_mem_info_mut = external_mem_info;
        ext_mem_info_mut.pNext = &modifier_list_mut;
        var image_ci_mut = image_create_info;
        image_ci_mut.pNext = &ext_mem_info_mut;

        var image: vk.VkImage = null;
        if (vk.vkCreateImage(ctx.device, &image_ci_mut, null, &image) != vk.VK_SUCCESS) {
            return error.ImageCreationFailed;
        }
        errdefer vk.vkDestroyImage(ctx.device, image, null);

        // ── Memory requirements ──
        const mem_reqs_info = vk.VkImageMemoryRequirementsInfo2{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2,
            .image = image,
        };

        var mem_reqs2 = vk.VkMemoryRequirements2{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2,
            .memoryRequirements = std.mem.zeroes(vk.VkMemoryRequirements),
        };

        var dedicated_reqs = vk.VkMemoryDedicatedRequirements{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS,
            .prefersDedicatedAllocation = vk.VK_FALSE,
            .requiresDedicatedAllocation = vk.VK_FALSE,
        };
        mem_reqs2.pNext = &dedicated_reqs;

        vk.vkGetImageMemoryRequirements2(ctx.device, &mem_reqs_info, &mem_reqs2);

        // Find memory type with DEVICE_LOCAL_BIT
        var memory_type_index: u32 = 0;
        {
            var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
            vk.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_props);
            const req_bits = mem_reqs2.memoryRequirements.memoryTypeBits;
            for (0..mem_props.memoryTypeCount) |i| {
                if (req_bits & (@as(u32, 1) << @intCast(i)) != 0 and
                    mem_props.memoryTypes[i].propertyFlags & vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0)
                {
                    memory_type_index = @intCast(i);
                    break;
                }
            }
        }

        // ── Allocate memory with export + dedicated ──
        const export_info = vk.VkExportMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
            .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };

        const dedicated_alloc_info = vk.VkMemoryDedicatedAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .image = image,
            .buffer = null,
        };

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = mem_reqs2.memoryRequirements.size,
            .memoryTypeIndex = memory_type_index,
            .pNext = &export_info,
        };
        // Chain: export_info ← dedicated_alloc_info
        var export_info_mut = export_info;
        export_info_mut.pNext = &dedicated_alloc_info;
        var alloc_info_mut = alloc_info;
        alloc_info_mut.pNext = &export_info_mut;

        var memory: vk.VkDeviceMemory = null;
        if (vk.vkAllocateMemory(ctx.device, &alloc_info_mut, null, &memory) != vk.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }
        errdefer vk.vkFreeMemory(ctx.device, memory, null);
        memtrack.dmabuf_mem.onAlloc(0); // count-only: resize-bounded, not a per-frame suspect

        if (vk.vkBindImageMemory(ctx.device, image, memory, 0) != vk.VK_SUCCESS) {
            return error.BindImageFailed;
        }

        // ── Export dmabuf fd ──
        // vkGetMemoryFdKHR is an extension function — load it via vkGetDeviceProcAddr
        const vkGetMemoryFdKHR = @as(
            ?*const fn (vk.VkDevice, *const vk.VkMemoryGetFdInfoKHR, *c_int) callconv(.c) vk.VkResult,
            @ptrCast(vk.vkGetDeviceProcAddr(ctx.device, "vkGetMemoryFdKHR")),
        ) orelse return error.FdExportNotAvailable;

        const fd_info = vk.VkMemoryGetFdInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
            .memory = memory,
            .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };

        var fd: c_int = -1;
        if (vkGetMemoryFdKHR(ctx.device, &fd_info, &fd) != vk.VK_SUCCESS) {
            return error.FdExportFailed;
        }
        errdefer _ = std.c.close(fd);

        // ── Get modifier and stride ──
        // vkGetImageDrmFormatModifierPropertiesEXT is also an extension function
        const vkGetImageDrmFormatModifierPropertiesEXT = @as(
            ?*const fn (vk.VkDevice, vk.VkImage, *vk.VkImageDrmFormatModifierPropertiesEXT) callconv(.c) vk.VkResult,
            @ptrCast(vk.vkGetDeviceProcAddr(ctx.device, "vkGetImageDrmFormatModifierPropertiesEXT")),
        ) orelse return error.ModifierQueryNotAvailable;

        var mod_props = vk.VkImageDrmFormatModifierPropertiesEXT{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT,
            .drmFormatModifier = 0,
        };
        if (vkGetImageDrmFormatModifierPropertiesEXT(ctx.device, image, &mod_props) != vk.VK_SUCCESS) {
            return error.ModifierQueryFailed;
        }

        const subresource = vk.VkImageSubresource{
            .aspectMask = vk.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT,
            .mipLevel = 0,
            .arrayLayer = 0,
        };
        var layout: vk.VkSubresourceLayout = undefined;
        vk.vkGetImageSubresourceLayout(ctx.device, image, &subresource, &layout);

        const desc: gpu_buffer.BufferDesc = .{
            .width = width,
            .height = height,
            .stride = @intCast(layout.rowPitch),
            .offset = @intCast(layout.offset),
            .format = drm_format,
            .modifier_hi = @intCast((mod_props.drmFormatModifier >> 32) & 0xFFFFFFFF),
            .modifier_lo = @intCast(mod_props.drmFormatModifier & 0xFFFFFFFF),
        };

        // ── Image view (sRGB) — the render pass attachment is sRGB, so the
        // hardware handles the linear↔sRGB conversions on blend and store. ──
        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_SRGB,
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
                .layerCount = 1,
            },
        };

        var view: vk.VkImageView = null;
        if (vk.vkCreateImageView(ctx.device, &view_info, null, &view) != vk.VK_SUCCESS) {
            return error.ImageViewCreationFailed;
        }
        errdefer vk.vkDestroyImageView(ctx.device, view, null);

        // ── Framebuffer ──
        const fb_info = vk.VkFramebufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = ctx.render_pass,
            .attachmentCount = 1,
            .pAttachments = &view,
            .width = width,
            .height = height,
            .layers = 1,
        };

        var framebuffer: vk.VkFramebuffer = null;
        if (vk.vkCreateFramebuffer(ctx.device, &fb_info, null, &framebuffer) != vk.VK_SUCCESS) {
            return error.FramebufferCreationFailed;
        }

        log.info(.gpu, "dmabuf target created", .{
            .width = width,
            .height = height,
            .stride = desc.stride,
            .modifier = mod_props.drmFormatModifier,
        });

        return .{
            .image = image,
            .memory = memory,
            .view = view,
            .framebuffer = framebuffer,
            .fd = fd,
            .desc = desc,
        };
    }

    pub fn destroy(self: *DmabufTarget, ctx: *const Context) void {
        vk.vkDestroyFramebuffer(ctx.device, self.framebuffer, null);
        vk.vkDestroyImageView(ctx.device, self.view, null);
        vk.vkDestroyImage(ctx.device, self.image, null);
        vk.vkFreeMemory(ctx.device, self.memory, null);
        memtrack.dmabuf_mem.onFree(0);
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }

    /// Duplicate the dmabuf fd for Wayland. The caller owns the dup'd fd
    /// and must close it (or transfer it to the compositor).
    pub fn dupFd(self: *const DmabufTarget) !c_int {
        if (self.fd < 0) return error.NoFd;
        const new_fd = std.c.fcntl(self.fd, std.c.F.DUP_CLOEXEC, 0);
        if (new_fd < 0) return error.DupFailed;
        return @intCast(new_fd);
    }
};
