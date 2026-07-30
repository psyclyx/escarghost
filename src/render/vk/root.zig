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
pub const Family = @import("renderer.zig").Family;
pub const PushConstants = @import("renderer.zig").PushConstants;
