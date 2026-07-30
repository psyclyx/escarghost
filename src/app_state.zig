const std = @import("std");
const selection_mod = @import("selection.zig");
const clipboard_mod = @import("clipboard.zig");
const terminal_mod = @import("terminal.zig");
const pty_mod = @import("pty.zig");
const wayland_mod = @import("wayland.zig");
const atlas_ref_mod = @import("render/atlas_ref.zig");
const atlas_worker = @import("render/atlas_worker.zig");
const cpu_worker = @import("render/cpu_worker.zig");
const gpu_worker = @import("render/gpu_worker.zig");
const diagnostics = @import("diagnostics.zig");
const bell_mod = @import("bell.zig");

pub const RenderPath = enum {
    cpu,
    gpu,
};

/// Exponential backoff with jitter for restarting the GPU thread after
/// failure. Stamps a `deadline_ns` when a retry is scheduled; the event
/// loop polls `.due()` each iteration. Lives on `AppState.render` so
/// debug hotkeys in input can poke it without depending on render_loop.
pub const GpuRestartBackoff = struct {
    initial_delay_ms: u32 = 0,
    max_delay_ms: u32 = 0,
    jitter_percent: u32 = 0,
    deadline_ns: ?u64 = null,
    attempts: u32 = 0,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

    pub fn init(initial_delay_ms: u32, max_delay_ms: u32, jitter_percent: u32) GpuRestartBackoff {
        return .{
            .initial_delay_ms = initial_delay_ms,
            .max_delay_ms = @max(initial_delay_ms, max_delay_ms),
            .jitter_percent = jitter_percent,
            .prng = std.Random.DefaultPrng.init(diagnostics.monotonicNowNs()),
        };
    }

    pub fn clear(self: *GpuRestartBackoff) void {
        self.deadline_ns = null;
        self.attempts = 0;
    }

    pub fn scheduleImmediate(self: *GpuRestartBackoff) void {
        self.deadline_ns = diagnostics.monotonicNowNs();
    }

    pub fn scheduleRetry(self: *GpuRestartBackoff) void {
        const shift = @min(self.attempts, 31);
        const scaled = (@as(u64, self.initial_delay_ms) << @intCast(shift));
        const capped = @min(scaled, @as(u64, self.max_delay_ms));
        const base_delay_ms: u32 = @intCast(capped);
        const jitter_pct = @min(self.jitter_percent, 1000);
        const jitter_span = @as(u64, base_delay_ms) * jitter_pct / 100;
        const min_delay: u32 = @intCast(base_delay_ms -| @as(u32, @intCast(@min(jitter_span, base_delay_ms))));
        const max_delay: u32 = @intCast(@min(@as(u64, self.max_delay_ms), @as(u64, base_delay_ms) + jitter_span));
        const delay_ms = if (min_delay < max_delay)
            self.prng.random().intRangeAtMost(u32, min_delay, max_delay)
        else
            min_delay;

        self.deadline_ns = diagnostics.monotonicNowNs() + @as(u64, delay_ms) * std.time.ns_per_ms;
        self.attempts +|= 1;
    }

    pub fn due(self: *const GpuRestartBackoff) bool {
        const deadline_ns = self.deadline_ns orelse return false;
        return diagnostics.monotonicNowNs() >= deadline_ns;
    }

    pub fn timeoutMs(self: *const GpuRestartBackoff) ?c_int {
        const deadline_ns = self.deadline_ns orelse return null;
        const now_ns = diagnostics.monotonicNowNs();
        if (deadline_ns <= now_ns) return 0;
        const delta_ns = deadline_ns - now_ns;
        const delta_ms = @max(@as(u64, 1), delta_ns / std.time.ns_per_ms);
        return @intCast(@min(delta_ms, @as(u64, std.math.maxInt(c_int))));
    }
};

/// Non-owning pointers to long-lived subsystems. Each field is left
/// undefined until the corresponding subsystem has been initialized in
/// main()'s startup phases; clipboard is optional because the
/// compositor may not advertise the data-device manager.
pub const Refs = struct {
    term: *terminal_mod.Terminal = undefined,
    pty: *pty_mod.Pty = undefined,
    wayland: *wayland_mod.Wayland = undefined,
    atlas_ref: *atlas_ref_mod.AtlasRef = undefined,
    clipboard: ?*clipboard_mod.Manager = null,
    gpu: *gpu_worker.GpuWorker = undefined,
    cpu: *cpu_worker.Frontend = undefined,
    atlas_thread: *atlas_worker.AtlasWorker = undefined,
    bell: *bell_mod.Manager = undefined,
};

pub const Metrics = struct {
    /// Pixel-snapped em used for rasterization and downstream metrics.
    /// Set from computeCellMetrics at bootstrap / zoom. Zoom steps add
    /// ±1 to this and re-run computeCellMetrics — snapping integer
    /// steps is identity, so behavior stays predictable.
    font_size: f32 = 14.0,
    base_font_size: f32 = 14.0,
    cell_width: f32 = 0,
    cell_height: f32 = 0,
    baseline_offset: f32 = 0,
    descent: f32 = 0,
    viewport_w: u32 = 0,
    viewport_h: u32 = 0,
    scroll_lines: u32 = 3,
};

pub const RenderState = struct {
    needs_redraw: bool = false,
    gpu_snapshot_dirty: bool = false,
    gpu_reconfigure_requested: bool = false,
    render_serial: u32 = 0,
    /// Atlas generation reflected by the last queued render. When the async
    /// prep thread publishes newly-prepped glyphs the generation advances; we
    /// re-render to fill in glyphs that were missing last frame, even if the
    /// terminal state itself hasn't changed.
    last_atlas_gen: u64 = 0,
    /// Whether the most recently committed frame was rendered with glyph
    /// misses (cells left blank pending async prep), and its serial. Feeds
    /// the anti-pop-in bypass: if the atlas catches up while that commit is
    /// still pending in the compositor, we render again inside the same
    /// vsync window and replace it (latest-commit-wins) so the incomplete
    /// frame is never latched.
    committed_had_misses: bool = false,
    committed_miss_serial: u32 = 0,
    /// One-shot permission for the next render to bypass the frame_pending
    /// vsync gate. Armed by pollAtlasUpdate when the atlas catches up to a
    /// pending miss-y commit; consumed when a render is queued. Each bypass
    /// costs one atlas publish to arm, so it cannot spin.
    atlas_catchup_bypass: bool = false,
    /// First-paint hold: before first content paint the screen shows the
    /// solid bg surface, which is already correct — so a miss-y first frame
    /// is withheld (never committed) until the atlas catches up or this
    /// monotonic-ns deadline passes. 0 = not armed.
    first_paint_hold_until_ns: u64 = 0,
    first_paint_hold_expired: bool = false,
    target_render_path: RenderPath = .gpu,
    active_render_path: RenderPath = .cpu,
    gpu_restart: GpuRestartBackoff = .{},
    buffer_starvation_start_ns: u64 = 0,
};

/// Mouse + selection state. `pointer_x/y` is in surface pixels
/// (already converted from Wayland's fixed-point form).
pub const InputState = struct {
    selection: selection_mod.State = .{},
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_in_surface: bool = false,
    /// Monotonic-ns deadline for the scrollbar fade. Bumped by scroll
    /// events and right-edge hover; once `monotonicNowNs() >=` this,
    /// the next render hides the overlay.
    scrollbar_visible_until_ns: u64 = 0,
    /// Tracks whether the previous render observed a visible scrollbar.
    /// Lets the hide-timeout know whether it still needs to redirty.
    scrollbar_was_visible: bool = false,
    touch: TouchState = .{},
    touch_cfg: TouchConfig = .{},
};

/// Tunables for the touch gesture handler. Copied from `config.zig`
/// at startup so the gesture code can read them without reaching
/// back through Refs.
pub const TouchConfig = struct {
    momentum: bool = true,
    long_press_ms: u32 = 400,
    drift_px: f32 = 8.0,
};

/// Touch gesture state. A single finger is tracked at a time —
/// secondary touches that land while `active_id` is set are dropped.
/// Gesture resolution is one of:
///   undecided → starting state; promotes to .scroll on first motion
///               past `drift_px` or to .select once long-press elapses
///   scroll    → finger Δy translates into viewport scrolling; at
///               touch-up, captured velocity feeds the fling integrator
///   select    → drag extends the active selection range
pub const TouchState = struct {
    /// Compositor slot id of the active finger, or null when idle.
    /// Sim mode always uses id 0.
    active_id: ?i32 = null,
    down_x: f64 = 0,
    down_y: f64 = 0,
    /// Monotonic ms (our clock) at touch-down. Drives long-press timing.
    down_ms: i64 = 0,
    last_x: f64 = 0,
    last_y: f64 = 0,
    last_motion_ms: i64 = 0,
    mode: enum { undecided, scroll, select } = .undecided,
    /// Sub-line scroll accumulator during a .scroll-mode drag.
    /// Whole-line steps get forwarded to the terminal; the remainder
    /// is kept so a slow drag still produces smooth motion.
    scroll_residual_lines: f64 = 0,
    /// EWMA-smoothed Y velocity (px/ms, signed). Captured at touch-up
    /// to seed the fling integrator.
    velocity_y_px_per_ms: f64 = 0,
    /// Active fling integrator (0 means no fling running). Sign
    /// matches scrollViewport's: positive = scroll toward newest.
    fling_lines_per_s: f64 = 0,
    fling_residual_lines: f64 = 0,
    /// Monotonic-ns timestamp of the last fling tick; 0 = freshly
    /// armed, advance from this iteration's clock without integrating.
    fling_last_tick_ns: u64 = 0,
};

/// Drain-phase tracking. After the PTY child exits we keep looping
/// until a frame containing its final output has been committed; these
/// two flags tell us when that has happened so we can exit instead of
/// waiting on the 250 ms watchdog.
pub const Lifecycle = struct {
    first_pty_data_seen: bool = false,
    first_content_painted: bool = false,
    /// render_serial stamped by the markRenderDirty that accompanied the
    /// first PTY data. A commit only counts as the first *content* paint
    /// when its serial is at or past this — a frame snapshotted before the
    /// data arrived (empty screen) committing after it must not count, or
    /// the first-paint hold loses its window and the real first content
    /// frame pops in with missing glyphs.
    first_content_serial: u32 = 0,
};

pub const DebugFlags = struct {
    warn_slow_budget_ms: ?u32 = null,
};

pub const AppState = struct {
    refs: Refs = .{},
    metrics: Metrics = .{},
    render: RenderState = .{},
    input: InputState = .{},
    lifecycle: Lifecycle = .{},
    diag: diagnostics.Diagnostics = .{},
    debug: DebugFlags = .{},
    /// Process-wide `Io` instance, set once in `main()`. Thread-safe
    /// (Threaded implementation); used by input dispatch and other
    /// subsystems that need to do IO through `state`.
    io: std.Io = undefined,
};
