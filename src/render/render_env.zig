const std = @import("std");
const snail = @import("snail");
const raster = @import("snail-raster");

const c = @cImport({
    @cInclude("stdlib.h");
});

pub const RequestedRenderPath = enum {
    auto,
    cpu,
    gpu,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn parseRequestedRenderPath(value: ?[]const u8) RequestedRenderPath {
    const raw = value orelse return .auto;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .auto;
    if (eql(trimmed, "cpu")) return .cpu;
    if (eql(trimmed, "gpu")) return .gpu;
    if (eql(trimmed, "auto")) return .auto;
    return .auto;
}

/// `SCRGO_TRACE=commits` (or `1` / `on`) opts into the commit-trace
/// profiling subsystem: phase counters, mem-poll thread, recorded
/// commit timeline, and exit summary. This is a tracing flag, not a
/// log scope — scope filtering happens in `log.zig` via `SCRGO_LOG`.
pub fn parseTraceCommits(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (eql(trimmed, "0") or eql(trimmed, "false") or eql(trimmed, "off")) return false;
    if (eql(trimmed, "1") or eql(trimmed, "true") or eql(trimmed, "on") or eql(trimmed, "all")) return true;
    var it = std.mem.tokenizeAny(u8, trimmed, ", ");
    while (it.next()) |token| {
        if (eql(token, "commits") or eql(token, "commit") or eql(token, "all") or eql(token, "1") or eql(token, "on") or eql(token, "true")) return true;
    }
    return false;
}

/// Parses `SCRGO_WARN_SLOW_MS`. Returns the per-frame budget in
/// milliseconds when warnings are enabled, or null when disabled.
///
/// - unset / "0" / "off" / "false" → disabled
/// - "1" / "on" / "true"           → enabled with default 16 ms budget
/// - integer N                      → enabled with N ms budget
pub fn parseWarnSlowMs(value: ?[]const u8) ?u32 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (eql(trimmed, "0") or eql(trimmed, "off") or eql(trimmed, "false")) return null;
    if (eql(trimmed, "1") or eql(trimmed, "on") or eql(trimmed, "true")) return 16;
    const parsed = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    if (parsed == 0) return null;
    return parsed;
}

pub const RuntimeFlags = struct {
    reset_atlas_each_frame: bool = false,
};

pub fn parseRuntimeFlags(value: ?[]const u8) RuntimeFlags {
    var result: RuntimeFlags = .{};
    const raw = value orelse return result;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return result;
    if (eql(trimmed, "0") or eql(trimmed, "false") or eql(trimmed, "off")) return result;

    var it = std.mem.tokenizeAny(u8, trimmed, ", ");
    while (it.next()) |token| {
        if (eql(token, "reset-atlas") or eql(token, "clear-atlas") or eql(token, "miss-glyphs")) {
            result.reset_atlas_each_frame = true;
        }
    }
    return result;
}

// Glyph hinting: terminal cells always snap to the device pixel grid (that's
// monospace layout, not a "mode"); glyph outlines currently render unhinted.
// snail's FreeType-style light autohinter is a planned follow-up — it needs a
// prep-pipeline rework (per-source AutohintContexts + model→glyph dependency
// ordering) that the parallel OutlineContext workers don't yet support.

pub var direct_resolve_enabled: bool = false;

pub fn directResolveEnabled() bool {
    return direct_resolve_enabled;
}

fn truthy(value: []const u8) bool {
    return !std.mem.eql(u8, value, "") and
        !std.mem.eql(u8, value, "0") and
        !std.mem.eql(u8, value, "false") and
        !std.mem.eql(u8, value, "off");
}

pub fn loadDirectResolveFromEnv() void {
    if (c.getenv("SCRGO_DIRECT_RESOLVE")) |value| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(value, 0), " \t\r\n");
        direct_resolve_enabled = truthy(trimmed);
    }
}

/// Per-renderer rendering knobs. Loaded once at startup and held by
/// both the GPU and CPU pipelines so the ResolveTarget passed into
/// snail at submit is built from the same source on both backends.
pub const RenderConfig = struct {
    /// Subpixel layout of the final destination. snail's text rasterizer
    /// only honors this when `effectiveSubpixelOrder` returns it (i.e.
    /// when the destination under the glyph is opaque); otherwise the
    /// per-draw target is downgraded to greyscale at submit time.
    subpixel_order: raster.SubpixelOrder = .none,
    /// 1.0 means the terminal background is opaque. A non-opaque
    /// background forces subpixel off because the destination under
    /// glyph rasterization is no longer guaranteed to be solid.
    background_alpha: f32 = 1.0,
    /// Exponent applied to analytic edge coverage at the rasterizer.
    /// 1.0 is identity (gamma-correct linear blend); values <1.0
    /// thicken glyph stems (stem-darkening), >1.0 thins them. Used to
    /// compensate for the visual thinning that gamma-correct blending
    /// produces vs. the sRGB-domain blending users are used to from
    /// FreeType/CoreText.
    coverage_exponent: f32 = 1.0,
};

/// Parse one of "rgb" / "bgr" / "vrgb" / "vbgr" / "none" (case-insensitive).
pub fn parseSubpixelOrder(value: ?[]const u8) raster.SubpixelOrder {
    const raw = value orelse return .none;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .none;
    if (eql(trimmed, "rgb")) return .rgb;
    if (eql(trimmed, "bgr")) return .bgr;
    if (eql(trimmed, "vrgb")) return .vrgb;
    if (eql(trimmed, "vbgr")) return .vbgr;
    return .none;
}

/// Parse `SCRGO_COVERAGE_EXPONENT`. Accepts a positive finite float;
/// anything else (unset, empty, unparseable, non-positive, non-finite)
/// returns 1.0 (identity). Hard-clamps to (0, 4.0] so a typo can't
/// produce degenerate output.
pub fn parseCoverageExponent(value: ?[]const u8) f32 {
    const raw = value orelse return 1.0;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return 1.0;
    const parsed = std.fmt.parseFloat(f32, trimmed) catch return 1.0;
    if (!std.math.isFinite(parsed) or parsed <= 0.0) return 1.0;
    return @min(parsed, 4.0);
}

/// Read SCRGO_SUBPIXEL / SCRGO_COVERAGE_EXPONENT / SCRGO_HINT_DIAG from
/// the environment. Future env knobs (e.g. SCRGO_BG_ALPHA) plug in here.
pub fn loadRenderConfigFromEnv() RenderConfig {
    var config: RenderConfig = .{};
    if (c.getenv("SCRGO_SUBPIXEL")) |value| {
        config.subpixel_order = parseSubpixelOrder(std.mem.sliceTo(value, 0));
    }
    if (c.getenv("SCRGO_COVERAGE_EXPONENT")) |value| {
        config.coverage_exponent = parseCoverageExponent(std.mem.sliceTo(value, 0));
    }
    loadDirectResolveFromEnv();
    return config;
}

/// Subpixel order to actually pass into snail's ResolveTarget. Forces
/// `.none` when the destination under text is not guaranteed opaque, so
/// no submit site can ship subpixel-rasterized text against a non-opaque
/// backdrop (which would produce coloured fringing).
pub fn effectiveSubpixelOrder(config: RenderConfig) raster.SubpixelOrder {
    if (config.background_alpha < 1.0) return .none;
    return config.subpixel_order;
}

/// Raster options to pass into snail at submit. Bundles the effective
/// subpixel order with the configured coverage exponent so both
/// backends share a single source of truth.
pub fn effectiveRasterOptions(config: RenderConfig) raster.RasterOptions {
    return .{
        .subpixel_order = effectiveSubpixelOrder(config),
        .coverage_transfer = .{ .exponent = config.coverage_exponent },
    };
}
