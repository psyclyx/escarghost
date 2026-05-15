//! Per-renderer rendering knobs. Loaded once at startup and held by both
//! the GPU (Renderer) and CPU (SnapshotRenderer) paths so the
//! ResolveTarget passed into snail at submit is built from the same
//! source on both backends.

const std = @import("std");
const snail = @import("snail");

const c = @cImport({
    @cInclude("stdlib.h");
});

pub const RenderConfig = struct {
    /// Subpixel layout of the final destination. snail's text rasterizer
    /// only honors this when `effectiveSubpixelOrder` returns it (i.e.
    /// when the destination under the glyph is opaque); otherwise the
    /// per-draw target is downgraded to greyscale at submit time.
    subpixel_order: snail.SubpixelOrder = .none,
    /// 1.0 means the terminal background is opaque. A non-opaque
    /// background forces subpixel off because the destination under
    /// glyph rasterization is no longer guaranteed to be solid.
    background_alpha: f32 = 1.0,
};

/// Parse one of "rgb" / "bgr" / "vrgb" / "vbgr" / "none" (case-insensitive).
/// Anything else returns `.none`.
pub fn parseSubpixelOrder(value: ?[]const u8) snail.SubpixelOrder {
    const raw = value orelse return .none;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "rgb")) return .rgb;
    if (std.ascii.eqlIgnoreCase(trimmed, "bgr")) return .bgr;
    if (std.ascii.eqlIgnoreCase(trimmed, "vrgb")) return .vrgb;
    if (std.ascii.eqlIgnoreCase(trimmed, "vbgr")) return .vbgr;
    return .none;
}

/// Read SCRGO_SUBPIXEL from the environment. Future env knobs (e.g.
/// SCRGO_BG_ALPHA) plug in here.
pub fn loadFromEnv() RenderConfig {
    var config: RenderConfig = .{};
    if (c.getenv("SCRGO_SUBPIXEL")) |value| {
        config.subpixel_order = parseSubpixelOrder(std.mem.sliceTo(value, 0));
    }
    return config;
}

/// Subpixel order to actually pass into snail's ResolveTarget. Forces
/// `.none` when the destination under text is not guaranteed opaque, so
/// no submit site can ship subpixel-rasterized text against a non-opaque
/// backdrop (which would produce coloured fringing).
pub fn effectiveSubpixelOrder(config: RenderConfig) snail.SubpixelOrder {
    if (config.background_alpha < 1.0) return .none;
    return config.subpixel_order;
}
