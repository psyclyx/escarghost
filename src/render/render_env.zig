const std = @import("std");
const snail = @import("snail");

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

pub const SyncExtendConfig = struct {
    enabled: bool,
    /// Upper bound (ms) on the auto-computed budget. `null` means no
    /// cap — the budget is whatever the vsync-headroom calculation
    /// allows. A positive cap is useful for forcing the renderer to
    /// give up earlier than the headroom would suggest (e.g. while
    /// investigating frame-time issues).
    cap_ms: ?u32,
};

/// Parses `SCRGO_SYNC_EXTEND`. Controls whether the GPU renderer will,
/// on a miss-frame, block briefly waiting for the atlas thread to
/// publish an extended snapshot and then redraw with the new atlas
/// before shipping. The budget itself is derived per-frame from the
/// observed vsync period, the previous frame's full cost, and the time
/// already spent on the current frame's first draw — this knob only
/// disables the retry or caps the derived budget.
///
/// - unset / "auto" / "on" / "true" / "1" → enabled, no cap (default)
/// - "off" / "0" / "false"                → disabled (ship partial,
///                                           async-fix next frame, as
///                                           if this feature didn't
///                                           exist)
/// - integer N                            → enabled, cap auto budget
///                                           at N ms
pub fn parseSyncExtend(value: ?[]const u8) SyncExtendConfig {
    const raw = value orelse return .{ .enabled = true, .cap_ms = null };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .enabled = true, .cap_ms = null };
    if (eql(trimmed, "0") or eql(trimmed, "off") or eql(trimmed, "false")) {
        return .{ .enabled = false, .cap_ms = null };
    }
    if (eql(trimmed, "auto") or eql(trimmed, "1") or eql(trimmed, "on") or eql(trimmed, "true")) {
        return .{ .enabled = true, .cap_ms = null };
    }
    const n = std.fmt.parseInt(u32, trimmed, 10) catch {
        return .{ .enabled = true, .cap_ms = null };
    };
    if (n == 0) return .{ .enabled = false, .cap_ms = null };
    return .{ .enabled = true, .cap_ms = n };
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

/// Hint mode that drives both the cell-metrics snap step and the
/// row_build per-sub-range append path. Mutable at runtime via the
/// Ctrl+Shift+F4 debug keybinding so we can A/B/C compare without
/// rebuilding.
pub const HintMode = enum(u8) {
    /// No pixel-grid snap, no TT hinter. Glyphs raster at the raw
    /// requested em; baseline is the synthetic `cell_height * 0.8`.
    none = 0,
    /// Pixel-snapped em/cell_width/baseline via `atlas.cellGrid` but
    /// no TT hinter — the cheap "terminal grid" path.
    grid = 1,
    /// Grid snap + snail's `TrueTypeHintContext` best-effort hinter
    /// applied to every sub-range; this is the default.
    tt = 2,
};

/// Mode atomic shared between the main thread (writer, on keybinding)
/// and the worker threads (readers, per-frame). Initialised to .tt
/// at startup; `loadHintMode` does the relaxed read on the hot path.
pub var hint_mode_atomic: std.atomic.Value(u8) = .{ .raw = @intFromEnum(HintMode.tt) };

/// Set from SCRGO_HINT_DIAG=1 at startup. When true, row_build queries
/// the hint context per fallback glyph to bucket fallbacks by reject
/// reason — adds ~50ns per fallback glyph per frame, so off by default.
pub var hint_diag_enabled: bool = false;
pub var direct_resolve_enabled: bool = false;
pub var explicit_sync_enabled: bool = true;

pub fn directResolveEnabled() bool {
    return direct_resolve_enabled;
}

pub fn explicitSyncEnabled() bool {
    return explicit_sync_enabled;
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

/// Kill switch for the wp_linux_drm_syncobj_v1 explicit-sync path.
/// `SCRGO_EXPLICIT_SYNC=0` (or off/false) forces fall-back to the
/// implicit glClientWaitSync stall, even if the compositor and EGL
/// extension are both present. Useful for isolating sync-related
/// rendering bugs.
pub fn loadExplicitSyncFromEnv() void {
    if (c.getenv("SCRGO_EXPLICIT_SYNC")) |value| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(value, 0), " \t\r\n");
        explicit_sync_enabled = truthy(trimmed);
    }
}

pub fn loadHintDiagFromEnv() void {
    if (c.getenv("SCRGO_HINT_DIAG")) |value| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(value, 0), " \t\r\n");
        hint_diag_enabled = !std.mem.eql(u8, trimmed, "") and
            !std.mem.eql(u8, trimmed, "0") and
            !std.mem.eql(u8, trimmed, "false") and
            !std.mem.eql(u8, trimmed, "off");
    }
}

pub fn loadHintMode() HintMode {
    return @enumFromInt(hint_mode_atomic.load(.monotonic));
}

pub fn storeHintMode(mode: HintMode) void {
    hint_mode_atomic.store(@intFromEnum(mode), .monotonic);
}

pub fn cycleHintMode() HintMode {
    const current = loadHintMode();
    const next: HintMode = switch (current) {
        .none => .grid,
        .grid => .tt,
        .tt => .none,
    };
    storeHintMode(next);
    return next;
}

/// Per-renderer rendering knobs. Loaded once at startup and held by
/// both the GPU and CPU pipelines so the ResolveTarget passed into
/// snail at submit is built from the same source on both backends.
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
    /// Exponent applied to analytic edge coverage at the rasterizer.
    /// 1.0 is identity (gamma-correct linear blend); values <1.0
    /// thicken glyph stems (stem-darkening), >1.0 thins them. Used to
    /// compensate for the visual thinning that gamma-correct blending
    /// produces vs. the sRGB-domain blending users are used to from
    /// FreeType/CoreText.
    coverage_exponent: f32 = 1.0,
};

/// Parse one of "rgb" / "bgr" / "vrgb" / "vbgr" / "none" (case-insensitive).
pub fn parseSubpixelOrder(value: ?[]const u8) snail.SubpixelOrder {
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
    loadHintDiagFromEnv();
    loadDirectResolveFromEnv();
    loadExplicitSyncFromEnv();
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

/// Raster options to pass into snail at submit. Bundles the effective
/// subpixel order with the configured coverage exponent so both
/// backends share a single source of truth.
pub fn effectiveRasterOptions(config: RenderConfig) snail.RasterOptions {
    return .{
        .subpixel_order = effectiveSubpixelOrder(config),
        .coverage_transfer = .{ .exponent = config.coverage_exponent },
    };
}
