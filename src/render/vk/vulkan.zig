//! Shared Vulkan C API import. All vk/ files import this to ensure
//! opaque handle types (VkDevice, VkInstance, etc.) are the same type
//! across translation units.

pub const vk = @cImport({
    @cInclude("vulkan/vulkan.h");
});
