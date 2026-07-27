//! Self-contained Vulkan context: instance, physical device, logical
//! device, graphics queue, command pool, and render pass.
//!
//! No Wayland types, no EGL, no GBM. The caller creates a Context and
//! passes it to DmabufTarget, Renderer, and DeviceAtlas. Everything
//! here is plain Vulkan C API via @cImport.

const std = @import("std");
const log = @import("../../log.zig");
const memtrack = @import("memtrack.zig");

const vk = @import("vulkan.zig").vk;

pub const Context = struct {
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family_index: u32,
    command_pool: vk.VkCommandPool,
    render_pass: vk.VkRenderPass,
    supports_dual_source_blend: bool,

    pub fn init(allocator: std.mem.Allocator) !Context {
        // ── Instance ──
        const instance_extensions = [_][*:0]const u8{
            vk.VK_KHR_EXTERNAL_MEMORY_CAPABILITIES_EXTENSION_NAME,
            vk.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
            vk.VK_KHR_SURFACE_EXTENSION_NAME,
        };

        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "scrgo",
            .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .pEngineName = "scrgo",
            .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.VK_API_VERSION_1_1,
        };

        const instance_create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = instance_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&instance_extensions),
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
        };

        var instance: vk.VkInstance = null;
        if (vk.vkCreateInstance(&instance_create_info, null, &instance) != vk.VK_SUCCESS) {
            return error.InstanceCreationFailed;
        }
        errdefer vk.vkDestroyInstance(instance, null);

        // ── Physical device selection ──
        var physical_device_count: u32 = 0;
        _ = vk.vkEnumeratePhysicalDevices(instance, &physical_device_count, null);
        if (physical_device_count == 0) return error.NoPhysicalDevice;

        const devices = try allocator.alloc(vk.VkPhysicalDevice, physical_device_count);
        defer allocator.free(devices);
        if (vk.vkEnumeratePhysicalDevices(instance, &physical_device_count, devices.ptr) != vk.VK_SUCCESS) {
            return error.EnumerateDevicesFailed;
        }

        // Pick: prefer discrete GPU, fallback to first available.
        var physical_device: vk.VkPhysicalDevice = null;
        var queue_family_index: u32 = 0;
        for (devices) |dev| {
            var props: vk.VkPhysicalDeviceProperties = undefined;
            vk.vkGetPhysicalDeviceProperties(dev, &props);
            if (findGraphicsQueue(dev)) |qfi| {
                if (props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                    physical_device = dev;
                    queue_family_index = qfi;
                    break;
                }
                if (physical_device == null) {
                    physical_device = dev;
                    queue_family_index = qfi;
                }
            }
        }
        if (physical_device == null) return error.NoSuitableDevice;

        // ── Device ──
        const device_extensions = [_][*:0]const u8{
            vk.VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
            vk.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
            vk.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
            vk.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
            // Required by VK_EXT_image_drm_format_modifier.
            vk.VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME,
            vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        };

        const queue_priorities = [_]f32{1.0};
        const queue_create_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &queue_priorities,
        };

        // Query features we care about.
        var features2 = vk.VkPhysicalDeviceFeatures2{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures),
        };
        var blend_features = vk.VkPhysicalDeviceBlendOperationAdvancedFeaturesEXT{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BLEND_OPERATION_ADVANCED_FEATURES_EXT,
            .advancedBlendCoherentOperations = vk.VK_FALSE,
        };
        features2.pNext = &blend_features;
        vk.vkGetPhysicalDeviceFeatures2(physical_device, &features2);

        const supports_dual_source_blend = features2.features.dualSrcBlend == vk.VK_TRUE;

        const device_create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&device_extensions),
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .pNext = &features2,
        };

        var device: vk.VkDevice = null;
        if (vk.vkCreateDevice(physical_device, &device_create_info, null, &device) != vk.VK_SUCCESS) {
            return error.DeviceCreationFailed;
        }
        errdefer vk.vkDestroyDevice(device, null);

        // ── Queue ──
        var queue: vk.VkQueue = null;
        vk.vkGetDeviceQueue(device, queue_family_index, 0, &queue);

        // ── Command pool ──
        const cmd_pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = queue_family_index,
        };
        var command_pool: vk.VkCommandPool = null;
        if (vk.vkCreateCommandPool(device, &cmd_pool_info, null, &command_pool) != vk.VK_SUCCESS) {
            return error.CommandPoolCreationFailed;
        }
        errdefer vk.vkDestroyCommandPool(device, command_pool, null);

        // ── Render pass ──
        const color_attachment = vk.VkAttachmentDescription{
            // sRGB attachment: the hardware decodes dst → linear before every
            // blend and encodes the result → sRGB on store, so all blending is
            // gamma-correct in linear light. The dmabuf image is created as
            // UNORM (for DRM export) but the framebuffer binds an sRGB view.
            .format = vk.VK_FORMAT_R8G8B8A8_SRGB,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .finalLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const color_attachment_ref = vk.VkAttachmentReference{
            .attachment = 0,
            .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = vk.VkSubpassDescription{
            .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
        };

        const render_pass_info = vk.VkRenderPassCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
        };

        var render_pass: vk.VkRenderPass = null;
        if (vk.vkCreateRenderPass(device, &render_pass_info, null, &render_pass) != vk.VK_SUCCESS) {
            return error.RenderPassCreationFailed;
        }

        log.info(.gpu, "vulkan context ready", .{
            .queue_family = queue_family_index,
            .dual_src_blend = supports_dual_source_blend,
        });

        return .{
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .queue = queue,
            .queue_family_index = queue_family_index,
            .command_pool = command_pool,
            .render_pass = render_pass,
            .supports_dual_source_blend = supports_dual_source_blend,
        };
    }

    pub fn deinit(self: *Context) void {
        vk.vkDestroyRenderPass(self.device, self.render_pass, null);
        vk.vkDestroyCommandPool(self.device, self.command_pool, null);
        vk.vkDestroyDevice(self.device, null);
        vk.vkDestroyInstance(self.instance, null);
    }

    /// Allocate a primary command buffer from the pool.
    pub fn allocCommandBuffer(self: *const Context) !vk.VkCommandBuffer {
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var cmd: vk.VkCommandBuffer = null;
        if (vk.vkAllocateCommandBuffers(self.device, &alloc_info, &cmd) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
        memtrack.cmd_bufs.onAlloc(0);
        return cmd;
    }

    pub fn freeCommandBuffer(self: *const Context, cmd: vk.VkCommandBuffer) void {
        vk.vkFreeCommandBuffers(self.device, self.command_pool, 1, &cmd);
        memtrack.cmd_bufs.onFree(0);
    }

    /// Submit a command buffer and wait for it to complete.
    pub fn submitAndWait(self: *const Context, cmd: vk.VkCommandBuffer) !void {
        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
        };
        const sr = vk.vkQueueSubmit(self.queue, 1, &submit_info, null);
        if (sr != vk.VK_SUCCESS) {
            log.err(.gpu, "vkQueueSubmit", .{ .result = sr });
            return error.SubmitFailed;
        }
        const wr = vk.vkQueueWaitIdle(self.queue);
        if (wr != vk.VK_SUCCESS) {
            log.err(.gpu, "vkQueueWaitIdle", .{ .result = wr });
            return error.QueueWaitFailed;
        }
    }
};

fn findGraphicsQueue(dev: vk.VkPhysicalDevice) ?u32 {
    var count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(dev, &count, null);
    const props = std.heap.smp_allocator.alloc(vk.VkQueueFamilyProperties, count) catch return null;
    defer std.heap.smp_allocator.free(props);
    vk.vkGetPhysicalDeviceQueueFamilyProperties(dev, &count, props.ptr);
    for (props, 0..) |p, i| {
        if (p.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) return @intCast(i);
    }
    return null;
}
