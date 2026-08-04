//! Public API for the escargost Vulkan renderer.
//!
//! Self-contained — no Wayland types, no EGL, no GBM. The interface
//! to the compositor is (fd, BufferDesc) via DmabufTarget.

pub const Context = @import("context.zig").Context;
pub const DmabufTarget = @import("dmabuf.zig").DmabufTarget;
pub const DeviceAtlas = @import("device_atlas.zig").DeviceAtlas;
pub const DeviceAtlasOptions = @import("device_atlas.zig").DeviceAtlasOptions;
pub const Renderer = @import("renderer.zig").Renderer;
pub const renderToTarget = @import("renderer.zig").renderToTarget;
pub const ExplicitSync = @import("sync.zig").ExplicitSync;

// Raw handle types the worker needs for the explicit-sync command-buffer ring.
pub const VkCommandBuffer = @import("vulkan.zig").vk.VkCommandBuffer;
pub const VkSemaphore = @import("vulkan.zig").vk.VkSemaphore;
pub const VkFence = @import("vulkan.zig").vk.VkFence;
pub const Family = @import("renderer.zig").Family;
pub const PushConstants = @import("renderer.zig").PushConstants;
