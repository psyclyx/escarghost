const std = @import("std");
const snail = @import("snail");
const terminal_mod = @import("../terminal.zig");
const render_common = @import("render_common.zig");
const color = @import("color");
const selection_mod = @import("../selection.zig");
const Rgb = color.Rgb;

// Upper bounds on the rendered grid. The terminal grid is clamped to these
// (see computeGridSize), so a very wide / zoomed-out window pads on the far
// edge rather than silently dropping cells past the limit. Rows and columns
// share one bound so a portrait / rotated monitor gets the same headroom as a
// landscape one (a tall display needs as many rows as a wide one needs cols).
// The snapshot cell buffer is MaxCols*MaxRows cells (~16 MB each); the render
// workers that hold them are heap-allocated (and lazily faulted — only cells
// actually written touch memory) so this doesn't blow main's stack.
pub const MaxCols: u16 = 1024;
pub const MaxRows: u16 = 1024;
pub const MaxCells: usize = @as(usize, MaxCols) * MaxRows;

pub const CursorStyle = enum(u8) {
    bar,
    block,
    underline,
    block_hollow,
};

pub const CellFlags = packed struct(u8) {
    has_text: bool = false,
    has_fg: bool = false,
    has_bg: bool = false,
    inverse: bool = false,
    faint: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    reserved: bool = false,
};

pub const Cell = struct {
    codepoint: u32 = 0,
    glyph_id: u16 = 0,
    fg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    bg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    flags: u8 = 0,
};

pub const Header = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cell_count: u32 = 0,
    default_fg: Rgb = .{ .r = 255, .g = 255, .b = 255 },
    default_bg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    cursor_color: Rgb = .{ .r = 255, .g = 255, .b = 255 },
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_style: CursorStyle = .block,
    cursor_visible: u8 = 0,
    cursor_in_viewport: u8 = 0,
    cursor_has_color: u8 = 0,
    reserved: u8 = 0,
    /// Absolute screen-y of viewport row 0. Used by selection
    /// resolution to convert anchor/head screen coordinates back into
    /// viewport rows. Zero when there's no scrollback.
    viewport_offset: u32 = 0,
};

/// Visual-bell overlay sampled at snapshot time. Null = no bell
/// active. Renderers paint a full-viewport translucent rect over the
/// finished frame; `alpha` fades from 1 → 0 across the bell window.
pub const BellOverlay = struct {
    alpha: f32,
};

/// Scrollbar overlay sampled at snapshot time. Null = no scrollback
/// available, or scrollbar should be hidden. `alpha` lets the caller
/// animate fade in/out without renderer-side timing logic.
pub const ScrollbarOverlay = struct {
    /// Opacity in [0, 1]. Zero = fully hidden (renderers skip the
    /// pass); non-zero = visible at that alpha.
    alpha: f32,
    /// Top of the thumb as a fraction of the gutter (0 = top, 1 = bottom).
    thumb_offset: f32,
    /// Thumb height as a fraction of the gutter (always > 0 when visible).
    thumb_size: f32,
};

pub const SharedSnapshot = struct {
    header: Header = .{},
    // Undefined, not zero-filled: `capture` overwrites cells[0..cell_count]
    // before any render, and readers only touch cells[0..cell_count] (bounded
    // by the defaulted header). Zeroing ~5 MB/snapshot at every worker's
    // `.{}` was pure startup latency (several ms before the threads spawn).
    cells: [MaxCells]Cell = undefined,
    /// Active text selection at the time the snapshot was captured.
    /// Null = no selection; renderers skip the highlight pass.
    selection: ?selection_mod.Snapshot = null,
    /// Scrollbar overlay state. Null = hidden.
    scrollbar: ?ScrollbarOverlay = null,
    /// Visual-bell overlay state. Null = no active bell.
    bell: ?BellOverlay = null,
};

pub var updateRenderStateAccumNs: u64 = 0;
pub var updateRenderStateCount: u64 = 0;

fn monotonicNs() u64 {
    const std_time = std.time;
    const c = struct {
        extern fn clock_gettime(clk_id: c_int, tp: *Timespec) callconv(.c) c_int;
        const Timespec = extern struct { tv_sec: i64, tv_nsec: i64 };
    };
    var ts: c.Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    if (c.clock_gettime(1, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std_time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

/// Update the terminal's render_state (consumes terminal/screen dirty
/// state). Must run on whichever thread owns the Terminal; cheap (<1 ms).
/// Pair with `captureCells` to read the resulting render_state into a
/// `SharedSnapshot` — `captureCells` only touches the render_state and
/// can run on a worker thread.
///
/// `selection` is stamped onto `snapshot` here so it stays consistent
/// across the prepare/captureCells split (the worker that runs
/// captureCells won't see selection mutations that happened mid-frame).
/// Pass null when there's no live selection.
pub fn prepare(
    snapshot: *SharedSnapshot,
    term: *terminal_mod.Terminal,
    selection: ?selection_mod.Snapshot,
    scrollbar: ?ScrollbarOverlay,
    bell: ?BellOverlay,
) !void {
    const t0 = monotonicNs();
    try term.updateRenderState();
    updateRenderStateAccumNs += monotonicNs() - t0;
    updateRenderStateCount += 1;
    snapshot.selection = selection;
    snapshot.scrollbar = scrollbar;
    snapshot.bell = bell;
}

/// Walk the terminal's render_state (already populated by `prepare`) into
/// `snapshot`. Reads the render_state only — safe to run on a worker
/// thread as long as `prepare` is not called concurrently.
pub fn captureCells(snapshot: *SharedSnapshot, term: *terminal_mod.Terminal, _: *const snail.Atlas) !void {
    const colors = term.getColors();
    const cursor = term.getCursor();

    snapshot.header.default_fg = colors.foreground;
    snapshot.header.default_bg = colors.background;
    snapshot.header.cursor_color = colors.cursor orelse colors.foreground;
    snapshot.header.cursor_x = cursor.x;
    snapshot.header.cursor_y = cursor.y;
    snapshot.header.cursor_style = switch (cursor.style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    snapshot.header.cursor_visible = @intFromBool(cursor.visible);
    snapshot.header.cursor_in_viewport = @intFromBool(cursor.in_viewport);
    snapshot.header.cursor_has_color = @intFromBool(colors.cursor != null);

    term.beginRowIteration();

    var row_count: u16 = 0;
    var max_cols: u16 = 0;
    var cell_index: usize = 0;
    const cursor_row: u16 = cursor.y;
    const cursor_col: u16 = cursor.x;
    const cursor_visible_in_view = cursor.visible and cursor.in_viewport;

    while (row_count < MaxRows and term.nextRow()) : (row_count += 1) {
        term.beginCellIteration();

        var row_cols: u16 = 0;
        while (row_cols < MaxCols and term.nextCell()) : (row_cols += 1) {
            if (cell_index >= MaxCells) break;

            const info = term.getCellInfo();
            const flags: CellFlags = .{
                .has_text = info.has_text,
                .has_fg = info.fg != null,
                .has_bg = info.bg != null,
                .inverse = info.style.inverse != false,
                .faint = info.style.faint != false,
                .underline = info.style.underline != 0,
                .strikethrough = info.style.strikethrough != false,
            };

            // glyph_id is only consulted for the cursor cell downstream;
            // skip the per-cell font cmap lookup for the rest of the
            // grid. Saves a hash/cmap probe per cell — adds up fast on
            // a streaming workload.
            const glyph_id: u16 = blk: {
                if (row_count != cursor_row or row_cols != cursor_col) break :blk 0;
                if (!cursor_visible_in_view) break :blk 0;
                if (!info.has_text) break :blk 0;
                if (!render_common.isRenderableCodepoint(info.codepoint)) break :blk 0;
                // TODO: look up glyph_id via snail.Font.glyphIndex — needs Faces ref
                break :blk 0;
            };

            snapshot.cells[cell_index] = .{
                .codepoint = info.codepoint,
                .glyph_id = glyph_id,
                .fg = info.fg orelse colors.foreground,
                .bg = info.bg orelse colors.background,
                .flags = @bitCast(flags),
            };
            cell_index += 1;
        }

        if (row_cols > max_cols) max_cols = row_cols;
    }

    snapshot.header.cols = max_cols;
    snapshot.header.rows = row_count;
    snapshot.header.cell_count = @intCast(cell_index);

    // Capture the viewport's position in the scrollback so selection
    // resolution downstream can recover the original screen y of
    // each anchored cell. `scrollbar()` returns offset = viewport
    // top in screen-row coords; zero when the viewport sits at the
    // start of an empty scrollback.
    const sb = term.scrollbarLocked();
    snapshot.header.viewport_offset = @intCast(@min(sb.offset, std.math.maxInt(u32)));
}

/// Convenience: prepare + captureCells on the same thread. Used by the
/// CPU worker path where snapshot capture already runs after the worker
/// has been signalled. The GPU path splits the two so iteration can run
/// off the main thread.
///
/// Takes the terminal lock for the whole capture: the PTY reader thread
/// feeds data concurrently, and both the render-state update and the
/// row/cell iteration must observe one consistent terminal state.
pub fn capture(
    snapshot: *SharedSnapshot,
    term: *terminal_mod.Terminal,
    atlas: *const snail.Atlas,
    selection: ?selection_mod.Snapshot,
    scrollbar: ?ScrollbarOverlay,
    bell: ?BellOverlay,
) !void {
    term.lock();
    defer term.unlock();
    try prepare(snapshot, term, selection, scrollbar, bell);
    try captureCells(snapshot, term, atlas);
}
