const std = @import("std");
const config_mod = @import("config.zig");
const wayland_mod = @import("wayland.zig");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");
const renderer_mod = @import("renderer.zig");
const shm_render = @import("shm_render.zig");
const render_env = @import("render_env.zig");
const atlas_ref_mod = @import("atlas_ref.zig");
const atlas_owner = @import("atlas_owner.zig");
const cpu_renderer_worker = @import("cpu_worker.zig");
const gpu_renderer = @import("gpu_renderer.zig");
const perf = @import("perf.zig");
const selection_mod = @import("selection.zig");
const render_snapshot = @import("render_snapshot.zig");
const clipboard_mod = @import("clipboard.zig");
const diagnostics = @import("diagnostics.zig");
const app_state = @import("app_state.zig");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("poll.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const ghostty_c = @cImport(@cInclude("ghostty/vt.h"));
const xkb_syms = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

const monotonicNowNs = diagnostics.monotonicNowNs;

fn setCloseOnExec(fd: c_int) void {
    if (fd < 0) return;
    const flags = c.fcntl(fd, c.F_GETFD);
    if (flags < 0) return;
    _ = c.fcntl(fd, c.F_SETFD, flags | c.FD_CLOEXEC);
}

// Wayland callbacks (wayland.zig:145-148) are bare function pointers with
// no userdata, so the four on_* handlers reach AppState via this static.
// Bound in main() once `state` is fully populated. Migrates into
// input.zig in the next refactor commit.
var s_app: *app_state.AppState = undefined;

const RenderPath = app_state.RenderPath;
const GpuRestartBackoff = app_state.GpuRestartBackoff;

/// Scrollbar overlay state. The scrollbar is shown on scroll events
/// and when the pointer hovers near the right edge; otherwise hidden
/// after a 1s idle. Animation is plain on/off — no per-frame
/// interpolation, so we don't have to wake the render loop on a
/// tight timer.
const SCROLLBAR_HIDE_DELAY_NS: u64 = 1_000 * std.time.ns_per_ms;
/// Hover detection: pointer is within this many pixels of the right edge.
const SCROLLBAR_HOVER_WIDTH: f64 = 16.0;

fn markFirstContentPaint() void {
    if (s_app.lifecycle.first_content_painted or !s_app.lifecycle.first_pty_data_seen) return;
    s_app.lifecycle.first_content_painted = true;
}

fn rendererDebugOptions() render_env.RendererDebug {
    if (getenv("SCRGO_LOG")) |value|
        return render_env.parseRendererDebug(value);
    return .{};
}

fn debugStartupEnabled() bool {
    return s_app.debug.renderer_debug.startup;
}

fn debugRenderersEnabled() bool {
    return s_app.debug.renderer_debug.renderers;
}

fn debugFramesEnabled() bool {
    return s_app.debug.renderer_debug.frames;
}

fn debugPtyEnabled() bool {
    return s_app.debug.renderer_debug.pty;
}

fn markRenderDirty() void {
    s_app.render.render_serial +%= 1;
    if (s_app.render.render_serial == 0) s_app.render.render_serial = 1;
    s_app.render.needs_redraw = true;
    s_app.render.gpu_snapshot_dirty = true;
}

fn debugKillActiveRenderer() void {
    if (s_app.render.active_render_path == .gpu and s_app.refs.gpu.active) {
        noteGpuUnavailable(s_app.refs.gpu, &s_app.render.active_render_path, &s_app.render.gpu_restart);
        std.debug.print("scrgo: debug: killed gpu renderer\n", .{});
    } else if (s_app.refs.cpu.active) {
        s_app.refs.cpu.stop();
        std.debug.print("scrgo: debug: killed cpu renderer\n", .{});
    }
}

fn debugSwapRenderer() void {
    if (s_app.render.target_render_path == .gpu) {
        s_app.render.target_render_path = .cpu;
        s_app.render.active_render_path = .cpu;
        s_app.render.needs_redraw = true;
        std.debug.print("scrgo: debug: target renderer -> cpu\n", .{});
    } else {
        s_app.render.target_render_path = .gpu;
        s_app.render.gpu_snapshot_dirty = true;
        std.debug.print("scrgo: debug: target renderer -> gpu\n", .{});
    }
}

fn debugClearAtlas() void {
    // Re-publish the current atlas with a fresh ASCII population. Since
    // ensureText returns null when nothing's missing, we force a snapshot
    // change by allocating a fresh TextAtlas init from scratch using the
    // current atlas's font config bytes.
    _ = std.heap.smp_allocator;
    markRenderDirty();
    std.debug.print("scrgo: debug: atlas clear (no-op in 0.4.x)\n", .{});
}

fn onKey(ev: wayland_mod.KeyEvent) void {
    if (ev.state == .released) return;

    // Scrgo bindings (intercepted before sending to PTY)
    if (ev.mods.ctrl and ev.mods.shift) {
        switch (ev.keysym) {
            // Zoom: Ctrl+Shift+Plus / Ctrl+Shift+Minus / Ctrl+Shift+0
            xkb_syms.XKB_KEY_plus, xkb_syms.XKB_KEY_equal => {
                zoomIn();
                return;
            },
            xkb_syms.XKB_KEY_minus, xkb_syms.XKB_KEY_underscore => {
                zoomOut();
                return;
            },
            xkb_syms.XKB_KEY_0, xkb_syms.XKB_KEY_parenright => {
                zoomReset();
                return;
            },
            // Scroll: Ctrl+Shift+Up/Down/PageUp/PageDown/Home/End
            xkb_syms.XKB_KEY_Up => {
                s_app.refs.term.scrollViewport(-1);
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Down => {
                s_app.refs.term.scrollViewport(1);
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Page_Up => {
                s_app.refs.term.scrollViewport(-@as(isize, s_app.metrics.scroll_lines * 10));
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Page_Down => {
                s_app.refs.term.scrollViewport(@as(isize, s_app.metrics.scroll_lines * 10));
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Home => {
                s_app.refs.term.scrollToTop();
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_End => {
                s_app.refs.term.scrollToBottom();
                markRenderDirty();
                return;
            },
            // Copy: Ctrl+Shift+C
            xkb_syms.XKB_KEY_C, xkb_syms.XKB_KEY_c => {
                copySelectionToClipboard();
                return;
            },
            // Paste: Ctrl+Shift+V
            xkb_syms.XKB_KEY_V, xkb_syms.XKB_KEY_v => {
                pasteFromClipboard(.clipboard);
                return;
            },
            // Debug: Ctrl+Shift+F1/F2/F3
            xkb_syms.XKB_KEY_F1 => {
                debugKillActiveRenderer();
                return;
            },
            xkb_syms.XKB_KEY_F2 => {
                debugSwapRenderer();
                return;
            },
            xkb_syms.XKB_KEY_F3 => {
                debugClearAtlas();
                return;
            },
            else => {},
        }
    }
    // Shift+PageUp/Down for scroll (common terminal convention)
    if (ev.mods.shift and !ev.mods.ctrl) {
        switch (ev.keysym) {
            xkb_syms.XKB_KEY_Page_Up => {
                s_app.refs.term.scrollViewport(-@as(isize, s_app.metrics.scroll_lines * 10));
                markRenderDirty();
                return;
            },
            xkb_syms.XKB_KEY_Page_Down => {
                s_app.refs.term.scrollViewport(@as(isize, s_app.metrics.scroll_lines * 10));
                markRenderDirty();
                return;
            },
            else => {},
        }
    }

    const utf8_len = @min(ev.utf8_len, ev.utf8.len);
    const utf8 = if (utf8_len > 0) ev.utf8[0..utf8_len] else null;

    if (utf8) |text| {
        // Scroll to bottom on typing (common terminal behavior).
        // No markRenderDirty here: the PTY echo will mark dirty when
        // actual content arrives. Marking dirty before the echo
        // triggers a wasted render of pre-keystroke state, costing one
        // vsync — measured as ~17ms of extra input latency.
        s_app.refs.term.scrollToBottom();
        s_app.refs.pty.write(text) catch {};
        return;
    }

    const gkey = keysymToGhosttyKey(ev.keysym);
    if (gkey != 0) {
        s_app.refs.term.scrollToBottom();
        const encoded = s_app.refs.term.encodeKey(
            gkey,
            ghostty_c.GHOSTTY_KEY_ACTION_PRESS,
            modsToGhostty(ev.mods),
            null,
        );
        if (encoded) |data| {
            s_app.refs.pty.write(data) catch {};
        }
    }
}

/// Wayland evdev codes for the buttons we care about. Imported here
/// rather than dragging in <linux/input-event-codes.h> for a handful of
/// constants.
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;

/// Convert surface-local pixel coords to a selection cell anchored in
/// absolute screen coordinates (row 0 = top of scrollback). Returns
/// null when metrics aren't ready yet (early startup). Clamps the
/// viewport portion to the grid so a drag past the window edge still
/// produces a valid cell, then offsets by the current viewport top so
/// the resulting Cell stays valid as the terminal scrolls.
fn pixelToCell(x: f64, y: f64) ?selection_mod.Cell {
    if (s_app.metrics.cell_width <= 0 or s_app.metrics.cell_height <= 0) return null;
    const term_cols = s_app.refs.term.colCount();
    const term_rows = s_app.refs.term.rowCount();
    if (term_cols == 0 or term_rows == 0) return null;
    const col_f = @floor(x / s_app.metrics.cell_width);
    const row_f = @floor(y / s_app.metrics.cell_height);
    const col_i = @as(i32, @intFromFloat(@max(0.0, col_f)));
    const row_i = @as(i32, @intFromFloat(@max(0.0, row_f)));
    const col: u16 = @intCast(@min(@as(i32, term_cols - 1), col_i));
    const view_row: u16 = @intCast(@min(@as(i32, term_rows - 1), row_i));
    const sb = s_app.refs.term.scrollbar();
    const screen_y: u32 = @intCast(@min(sb.offset + view_row, std.math.maxInt(u32)));
    return .{ .row = screen_y, .col = col };
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.tv_sec) * std.time.ms_per_s + @divTrunc(ts.tv_nsec, std.time.ns_per_ms);
}

fn onMouse(ev: wayland_mod.MouseEvent) void {
    s_app.input.pointer_x = ev.x;
    s_app.input.pointer_y = ev.y;
    switch (ev.kind) {
        .enter => s_app.input.pointer_in_surface = true,
        .leave => {
            s_app.input.pointer_in_surface = false;
            // Leaving the surface also kills hover detection — fall
            // back to scroll-driven visibility only.
        },
        .scroll => {
            const lines: isize = if (ev.scroll_dy > 0) @intCast(s_app.metrics.scroll_lines) else -@as(isize, @intCast(s_app.metrics.scroll_lines));
            s_app.refs.term.scrollViewport(lines);
            bumpScrollbarVisibility();
            markRenderDirty();
        },
        .button_press => {
            const cell = pixelToCell(ev.x, ev.y) orelse return;
            switch (ev.button) {
                BTN_LEFT => {
                    s_app.input.selection.beginPrimary(cell, ev.mods.shift, nowMs());
                    markRenderDirty();
                },
                BTN_MIDDLE => {
                    // Middle-click paste: read primary selection and
                    // write to the pty. No-op when no primary owner.
                    pasteFromClipboard(.primary);
                },
                else => {},
            }
        },
        .button_release => {
            switch (ev.button) {
                BTN_LEFT => {
                    const had_selection = s_app.input.selection.range != null;
                    s_app.input.selection.endDrag();
                    // Drag finished with non-empty selection: claim
                    // the primary selection so middle-click in
                    // another app pastes our text.
                    if (had_selection and s_app.input.selection.range != null) {
                        copyToPrimary();
                    }
                    markRenderDirty();
                },
                else => {},
            }
        },
        .motion => {
            const near_right_edge = @as(f64, @floatFromInt(s_app.metrics.viewport_w)) - ev.x <= SCROLLBAR_HOVER_WIDTH;
            if (near_right_edge) {
                bumpScrollbarVisibility();
                markRenderDirty();
            }
            if (s_app.input.selection.dragging) {
                const cell = pixelToCell(ev.x, ev.y) orelse return;
                s_app.input.selection.updateDrag(cell);
                markRenderDirty();
            }
        },
    }
}

fn bumpScrollbarVisibility() void {
    s_app.input.scrollbar_visible_until_ns = monotonicNowNs() + SCROLLBAR_HIDE_DELAY_NS;
}

/// Copy the current selection to the regular clipboard (Ctrl+Shift+C).
/// Silent no-op when there's nothing selected or no Wayland clipboard
/// support is available.
fn copySelectionToClipboard() void {
    const mgr = s_app.refs.clipboard orelse return;
    const allocator = std.heap.smp_allocator;
    const text = extractSelectionText(allocator) catch return orelse return;
    const serial = s_app.refs.wayland.last_input_serial;
    mgr.setText(.clipboard, text, serial) catch {
        allocator.free(text);
    };
}

/// Stamp the current selection onto the primary selection so middle-
/// click paste in other apps works. Called when a drag ends with a
/// non-empty range.
fn copyToPrimary() void {
    const mgr = s_app.refs.clipboard orelse return;
    const allocator = std.heap.smp_allocator;
    const text = extractSelectionText(allocator) catch return orelse return;
    const serial = s_app.refs.wayland.last_input_serial;
    mgr.setText(.primary, text, serial) catch {
        allocator.free(text);
    };
}

/// Read the named clipboard channel and write the bytes to the PTY,
/// wrapped in bracketed-paste markers if the terminal asked for them.
fn pasteFromClipboard(kind: clipboard_mod.Kind) void {
    const mgr = s_app.refs.clipboard orelse return;
    const allocator = std.heap.smp_allocator;
    const text = (mgr.getText(kind, allocator, 200) catch return) orelse return;
    defer allocator.free(text);
    writePasteToPty(text);
}

/// Forward a paste buffer to the PTY. Defers to terminal.encodePaste
/// which strips unsafe bytes and applies bracketed-paste wrapping.
fn writePasteToPty(text: []const u8) void {
    const allocator = std.heap.smp_allocator;
    const encoded = s_app.refs.term.encodePaste(allocator, text) catch return orelse return;
    defer allocator.free(encoded);
    s_app.refs.pty.write(encoded) catch {};
    s_app.refs.term.scrollToBottom();
    markRenderDirty();
}

/// Read the codepoints of the row at absolute screen-y `target_screen_y`
/// into `out` (UTF-32). Returns the column count actually read.
/// Prefers the render-state iterator when the row is currently in
/// the viewport (fast path) and falls back to the grid_ref-based
/// scrollback walker for rows above or below the visible viewport.
fn fetchRowCodepoints(target_screen_y: u32, out: []u32) usize {
    const sb = s_app.refs.term.scrollbar();
    // Fast path: row is inside the viewport — iterate the render
    // state, which we already update once per frame.
    if (target_screen_y >= sb.offset and target_screen_y - sb.offset < sb.len) {
        const view_row: u16 = @intCast(target_screen_y - sb.offset);
        s_app.refs.term.updateRenderState() catch return 0;
        s_app.refs.term.beginRowIteration();
        var row_idx: u16 = 0;
        while (s_app.refs.term.nextRow()) : (row_idx += 1) {
            if (row_idx != view_row) continue;
            s_app.refs.term.beginCellIteration();
            var col: usize = 0;
            while (s_app.refs.term.nextCell() and col < out.len) : (col += 1) {
                const info = s_app.refs.term.getCellInfo();
                out[col] = if (info.has_text) info.codepoint else ' ';
            }
            return col;
        }
        return 0;
    }

    // Slow path: row is in scrollback (above viewport) or the
    // alternate-screen-but-history case (below viewport). Use the
    // grid_ref walker to reach it.
    return s_app.refs.term.fillRowFromScreen(target_screen_y, out);
}

/// Allocate and fill a UTF-8 buffer with the currently-selected text.
/// Returns null when there's nothing to copy. Caller frees with the
/// same allocator. Walks rows in absolute screen-y space; rows
/// outside the viewport are fetched via the grid_ref walker
/// (terminal.fillRowFromScreen) so copy works across scrollback.
fn extractSelectionText(allocator: std.mem.Allocator) !?[]u8 {
    const snap = s_app.input.selection.toSnapshot() orelse return null;
    const cols = s_app.refs.term.colCount();
    const rows = s_app.refs.term.rowCount();
    if (cols == 0 or rows == 0) return null;

    var row_cp_buf: [render_snapshot.MaxCols]u32 = undefined;

    // Resolve word/line modes to a (start_cell, end_cell) range in
    // screen-y space, then walk that range row-by-row.
    var start_cell: selection_mod.Cell = undefined;
    var end_cell: selection_mod.Cell = undefined;
    var force_full_row_band = false;

    switch (snap.mode) {
        .char => {
            const ord = snap.ordered();
            start_cell = .{ .row = ord.start.row, .col = @min(ord.start.col, cols - 1) };
            end_cell = .{ .row = ord.end.row, .col = @min(ord.end.col, cols - 1) };
        },
        .word => {
            const a = expandWordLive(snap.anchor, cols, &row_cp_buf);
            const h = expandWordLive(snap.head, cols, &row_cp_buf);
            start_cell = if (selection_mod.Cell.lessThan(a.start, h.start)) a.start else h.start;
            end_cell = if (selection_mod.Cell.lessThan(a.end, h.end)) h.end else a.end;
            start_cell.col = @min(start_cell.col, cols - 1);
            end_cell.col = @min(end_cell.col, cols - 1);
        },
        .line => {
            const ord = snap.ordered();
            start_cell = .{ .row = ord.start.row, .col = 0 };
            end_cell = .{ .row = ord.end.row, .col = cols - 1 };
            force_full_row_band = true;
        },
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var first_emitted = true;
    var row: u32 = start_cell.row;
    while (row <= end_cell.row) : (row += 1) {
        const sc_raw: u16 = if (!force_full_row_band and row == start_cell.row) start_cell.col else 0;
        const ec_raw: u16 = if (!force_full_row_band and row == end_cell.row) end_cell.col else cols - 1;
        if (ec_raw < sc_raw) continue;
        const span_raw: selection_mod.RowSpan = .{ .row = 0, .start_col = sc_raw, .end_col = ec_raw };
        const row_n = fetchRowCodepoints(row, row_cp_buf[0..cols]);
        // No content for this row (scrolled off, or empty): still
        // emit a line break so multi-row selections preserve their
        // structure; skip the cell loop.
        if (row_n == 0) {
            if (!first_emitted) try out.append(allocator, '\n');
            first_emitted = false;
            continue;
        }
        const span = selection_mod.trimSpanRight(row_cp_buf[0..row_n], span_raw);
        if (!first_emitted) try out.append(allocator, '\n');
        first_emitted = false;
        var col: u16 = span.start_col;
        while (col <= span.end_col) : (col += 1) {
            const cp: u32 = if (col < row_n) row_cp_buf[col] else ' ';
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch continue;
            try out.appendSlice(allocator, tmp[0..n]);
        }
    }

    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn expandWordLive(cell: selection_mod.Cell, cols: u16, row_cp_buf: *[render_snapshot.MaxCols]u32) struct { start: selection_mod.Cell, end: selection_mod.Cell } {
    const row_n = fetchRowCodepoints(cell.row, row_cp_buf[0..cols]);
    if (row_n == 0 or cell.col >= row_n) {
        return .{ .start = cell, .end = cell };
    }
    const w = selection_mod.expandWord(row_cp_buf[0..row_n], cell.col);
    return .{
        .start = .{ .row = cell.row, .col = w.start },
        .end = .{ .row = cell.row, .col = w.end },
    };
}

/// Compute the scrollbar overlay for this snapshot. Returns null when
/// there's no scrollback or the visibility window has elapsed. The
/// renderer paints the overlay as a thin band on the right edge.
fn currentScrollbarOverlay() ?render_snapshot.ScrollbarOverlay {
    const sb = s_app.refs.term.scrollbar();
    if (sb.total == 0 or sb.len == 0 or sb.total <= sb.len) {
        s_app.input.scrollbar_was_visible = false;
        return null;
    }
    const now = monotonicNowNs();
    if (now >= s_app.input.scrollbar_visible_until_ns) {
        s_app.input.scrollbar_was_visible = false;
        return null;
    }
    const total_f: f32 = @floatFromInt(sb.total);
    const offset_f: f32 = @floatFromInt(sb.offset);
    const len_f: f32 = @floatFromInt(sb.len);
    s_app.input.scrollbar_was_visible = true;
    return .{
        // Alpha is binary for the first cut — visible vs not. Fading
        // adds per-frame redraw cost that we can layer in later.
        .alpha = 0.7,
        .thumb_offset = offset_f / total_f,
        .thumb_size = @max(0.04, len_f / total_f),
    };
}

/// Time until the scrollbar should be hidden — feeds into poll_timeout
/// so the main loop wakes in time to redraw the frame with the
/// scrollbar gone. Returns null when the scrollbar is already hidden
/// (no timer needed).
fn scrollbarTimeoutMs() ?c_int {
    if (!s_app.input.scrollbar_was_visible) return null;
    const now = monotonicNowNs();
    if (now >= s_app.input.scrollbar_visible_until_ns) return 0;
    const delta_ns = s_app.input.scrollbar_visible_until_ns - now;
    const delta_ms = delta_ns / std.time.ns_per_ms + 1;
    return @intCast(@min(delta_ms, @as(u64, std.math.maxInt(c_int))));
}

/// Called once per loop iteration. Marks a redraw if the scrollbar
/// hide timer has elapsed and the previous frame still showed it.
fn maybeScheduleScrollbarHide() void {
    if (!s_app.input.scrollbar_was_visible) return;
    if (monotonicNowNs() < s_app.input.scrollbar_visible_until_ns) return;
    markRenderDirty();
}

fn zoomIn() void {
    s_app.metrics.font_size = @min(s_app.metrics.font_size + 1.0, 72.0);
    applyZoom();
}

fn zoomOut() void {
    s_app.metrics.font_size = @max(s_app.metrics.font_size - 1.0, 6.0);
    applyZoom();
}

fn zoomReset() void {
    s_app.metrics.font_size = s_app.metrics.base_font_size;
    applyZoom();
}

fn applyZoom() void {
    var atlas_lease = s_app.refs.atlas_ref.acquire();
    defer atlas_lease.release();
    const cm = renderer_mod.computeCellMetrics(atlas_lease.get(), s_app.metrics.font_size) catch return;
    s_app.metrics.cell_width = cm.cell_width;
    s_app.metrics.cell_height = cm.cell_height;

    const grid = renderer_mod.computeGridSize(s_app.metrics.cell_width, s_app.metrics.cell_height, s_app.metrics.viewport_w, s_app.metrics.viewport_h);
    if (grid.cols > 0 and grid.rows > 0) {
        s_app.refs.term.resize(grid.cols, grid.rows, @intFromFloat(s_app.metrics.cell_width), @intFromFloat(s_app.metrics.cell_height)) catch {};
        s_app.refs.pty.resize(grid.cols, grid.rows, s_app.metrics.viewport_w, s_app.metrics.viewport_h);
    }

    markRenderDirty();
    s_app.render.gpu_reconfigure_requested = true;
}

fn onResize(w: u32, h: u32) void {
    const grid = renderer_mod.computeGridSize(s_app.metrics.cell_width, s_app.metrics.cell_height, w, h);
    if (grid.cols == 0 or grid.rows == 0) return;
    s_app.metrics.viewport_w = w;
    s_app.metrics.viewport_h = h;
    s_app.refs.term.resize(grid.cols, grid.rows, @intFromFloat(s_app.metrics.cell_width), @intFromFloat(s_app.metrics.cell_height)) catch {};
    s_app.refs.pty.resize(grid.cols, grid.rows, w, h);
    markRenderDirty();
    s_app.render.gpu_reconfigure_requested = true;
}

fn onFocus(focused: bool) void {
    _ = focused;
}

fn maybeQueueGpuRendererFrame(gpu: *gpu_renderer.Frontend, wl: *const wayland_mod.Wayland, term: *terminal_mod.Terminal) void {
    if (s_app.render.target_render_path != .gpu) return;
    if (!gpu.active or !gpu.ready or gpu.render_in_flight or !s_app.render.gpu_snapshot_dirty) return;
    // Vsync-gate the GPU render. Without this we'd kick off the
    // render whenever PTY produced fresh data — which lands at
    // arbitrary phase inside the vsync window. If the data arrives
    // 12 ms into a 16.7 ms vsync, our 5–7 ms of work finishes past
    // the latch deadline and the commit slips to the *next* vsync,
    // dropping a frame. Waiting for the frame callback re-bases the
    // render to start at the vsync boundary so the whole budget is
    // available for the work. (The CPU path already does this; the
    // GPU path used to skip it for a marginal latency win that
    // turned out not to be worth the missed frames.)
    if (wl.frame_pending) return;
    gpu.queueRender(term, s_app.render.render_serial, s_app.input.selection.toSnapshot(), currentScrollbarOverlay()) catch |err| switch (err) {
        error.NoFreeBuffer => {
            // Track how long we're stuck without a released buffer
            // so we can see at exit whether compositor release
            // latency is the throughput bottleneck.
            if (s_app.debug.renderer_debug.commits or s_app.debug.warn_slow_budget_ms != null) {
                const now = monotonicNowNs();
                if (s_app.render.buffer_starvation_start_ns == 0) s_app.render.buffer_starvation_start_ns = now;
            }
            return;
        },
        error.NotReady, error.Busy, error.NoFreeSnapshot => return,
        else => return,
    };
    if (s_app.render.buffer_starvation_start_ns != 0) {
        const starvation_ns = monotonicNowNs() - s_app.render.buffer_starvation_start_ns;
        if (s_app.debug.renderer_debug.commits) {
            gpu_renderer.bufferStarvationAccumNs += starvation_ns;
            gpu_renderer.bufferStarvationCount += 1;
        }
        if (s_app.debug.warn_slow_budget_ms) |budget_ms| {
            const budget_ns = @as(u64, budget_ms) * std.time.ns_per_ms;
            if (starvation_ns > budget_ns) {
                std.debug.print("scrgo: buffer starvation {d:.1}ms (budget {}ms) — compositor hadn't released a dmabuf\n", .{
                    @as(f64, @floatFromInt(starvation_ns)) / @as(f64, std.time.ns_per_ms),
                    budget_ms,
                });
            }
        }
        s_app.render.buffer_starvation_start_ns = 0;
    }
    if (debugRenderersEnabled()) {
        std.debug.print("scrgo: queued gpu renderer frame serial={}\n", .{s_app.render.render_serial});
    }
    s_app.render.gpu_snapshot_dirty = false;
}

fn combineTimeout(a: c_int, b_opt: ?c_int) c_int {
    const b = b_opt orelse return a;
    if (a < 0) return b;
    return @min(a, b);
}

fn renderActivePath(
    active_path: RenderPath,
    gpu: *const gpu_renderer.Frontend,
    cpu: *cpu_renderer_worker.Frontend,
    wl: *wayland_mod.Wayland,
    term: *terminal_mod.Terminal,
) void {
    if (active_path != .cpu or !s_app.render.needs_redraw) return;
    if (s_app.render.target_render_path == .gpu and gpu.active and gpu.ready) return;
    // Same vsync throttle as the GPU path — wait for the compositor to
    // ack the previous commit before queueing the next one.
    if (wl.frame_pending) return;
    if (cpu.active) {
        const shm = wl.shm orelse return;
        cpu.ensureBuffers(@ptrCast(shm), wl.width, wl.height) catch |err| switch (err) {
            error.Busy => return,
            else => return,
        };
        cpu.queueRender(term, s_app.metrics.viewport_w, s_app.metrics.viewport_h, s_app.metrics.font_size, s_app.metrics.cell_width, s_app.metrics.cell_height, s_app.render.render_serial, s_app.input.selection.toSnapshot(), currentScrollbarOverlay()) catch |err| switch (err) {
            error.Busy, error.NoFreeBuffer, error.NoFreeSnapshot, error.Inactive => return,
            else => return,
        };
        s_app.render.needs_redraw = false;
        if (debugFramesEnabled()) {
            std.debug.print("scrgo: queue cpu renderer frame {}x{} ({d:.1}ms)\n", .{ wl.width, wl.height, s_app.diag.elapsedMs() });
        }
        return;
    }
    s_app.render.needs_redraw = false;
}

fn noteGpuUnavailable(
    gpu: *gpu_renderer.Frontend,
    active_path: *RenderPath,
    restart: *GpuRestartBackoff,
) void {
    gpu.stop();
    if (debugRenderersEnabled()) {
        std.debug.print("scrgo: gpu renderer unavailable, switching to cpu renderer and scheduling restart\n", .{});
    }
    if (active_path.* == .gpu) {
        active_path.* = .cpu;
        s_app.render.needs_redraw = true;
    }
    restart.scheduleRetry();
}

pub fn main(init: std.process.Init) !void {
    const startup_timer = perf.Timer.now();
    var state: app_state.AppState = .{};
    s_app = &state;
    state.diag.markStart();
    const allocator = std.heap.smp_allocator;
    _ = init.gpa;

    // Mesa hints — don't override if already set (0 = no overwrite)
    _ = c.setenv("MESA_NO_ERROR", "1", 0); // skip GL error checking
    _ = c.setenv("MESA_DISK_CACHE_SINGLE_FILE", "1", 0); // faster shader cache reads

    // Auto-detect mesa driver via sysfs (no libdrm dependency).
    {
        var driver_buf: [256]u8 = undefined;
        const fp = c.fopen("/sys/class/drm/renderD128/device/driver/module/drivers", "r");
        if (fp) |f| {
            defer _ = c.fclose(f);
            const n = c.fread(&driver_buf, 1, driver_buf.len - 1, f);
            if (n > 0) {
                driver_buf[n] = 0;
                const s = driver_buf[0..n];
                if (std.mem.indexOf(u8, s, "i915") != null or std.mem.indexOf(u8, s, "xe") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "iris", 0)
                else if (std.mem.indexOf(u8, s, "amdgpu") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "radeonsi", 0)
                else if (std.mem.indexOf(u8, s, "nouveau") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "nouveau", 0)
                else if (std.mem.indexOf(u8, s, "nvidia") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "nvidia", 0);
            }
        }
    }

    // Parse -e flag for command execution
    var exec_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exec_argv.deinit(allocator);
    {
        var args_iter = std.process.Args.Iterator.init(init.minimal.args);
        _ = args_iter.next(); // skip argv[0]
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-e")) {
                // Everything after -e is the command
                while (args_iter.next()) |cmd_arg| {
                    try exec_argv.append(allocator, cmd_arg);
                }
                break;
            }
        }
    }

    // ── Phase 0: config + spawn GPU thread ──
    var cfg = try config_mod.load(allocator);
    defer cfg.deinit(allocator);
    s_app.debug.renderer_debug = rendererDebugOptions();
    s_app.debug.warn_slow_budget_ms = render_env.parseWarnSlowMs(getenv("SCRGO_WARN_SLOW_MS"));
    wayland_mod.Wayland.log_frame_events = s_app.debug.renderer_debug.frames;
    s_app.diag.debug = s_app.debug.renderer_debug;
    // Background memory poller (SCRGO_LOG=commits). Mirrors what the
    // bench's poller thread sees from outside the process.
    const mem_thread = s_app.diag.startMemPollThread();
    defer s_app.diag.stopMemPollThread(mem_thread);
    const runtime_flags = render_env.parseRuntimeFlags(getenv("SCRGO_FLAGS"));
    const requested_render_path = render_env.parseRequestedRenderPath(getenv("SCRGO_RENDERER"));
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: debug flags startup={} renderers={} frames={} atlas={} pty={} reset_atlas={}\n", .{
            s_app.debug.renderer_debug.startup,
            s_app.debug.renderer_debug.renderers,
            s_app.debug.renderer_debug.frames,
            s_app.debug.renderer_debug.atlas,
            s_app.debug.renderer_debug.pty,
            runtime_flags.reset_atlas_each_frame,
        });
        std.debug.print("scrgo: requested renderer mode={s}\n", .{@tagName(requested_render_path)});
    }

    const gpu_allowed = requested_render_path != .cpu;
    if (debugStartupEnabled() and !gpu_allowed) {
        std.debug.print("scrgo: gpu renderer disabled by SCRGO_RENDERER=cpu\n", .{});
    }

    var gpu: gpu_renderer.Frontend = .{};
    state.render.gpu_restart = GpuRestartBackoff.init(
        cfg.gpu_restart_initial_delay_ms,
        cfg.gpu_restart_max_delay_ms,
        cfg.gpu_restart_jitter_percent,
    );

    // Spawn the CPU worker thread BEFORE anything pulls in NVIDIA EGL —
    // NVIDIA hooks pthread_create on load and every subsequent spawn costs
    // ~6 ms. The thread parks in cond_wait until start() assigns it work.
    var cpu: cpu_renderer_worker.Frontend = .{};
    defer cpu.stop();
    cpu.spawnThread() catch |err| {
        std.debug.print("scrgo: cpu renderer thread spawn failed: {}\n", .{err});
    };
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: cpu renderer thread spawned ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    // Start GPU thread early — it begins EGL init immediately, no deps needed
    if (gpu_allowed) {
        gpu.start() catch |err| {
            std.debug.print("scrgo: gpu renderer thread start failed: {}\n", .{err});
            state.render.gpu_restart.scheduleRetry();
        };
        if (debugStartupEnabled()) {
            std.debug.print("scrgo: gpu renderer thread started ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
        }
    }

    // Start atlas thread with font+atlas bootstrap — overlaps with Wayland init
    var atlas_thread: atlas_owner.Frontend = .{};
    try atlas_thread.startWithBootstrap(.{
        .allocator = allocator,
        .font_path_cfg = cfg.font_path,
        .font_size = cfg.font_size,
    });
    defer atlas_thread.stop();

    // ── Phase 1: Wayland connect + 1px background ──
    var wl: wayland_mod.Wayland = undefined;
    try wl.init(800, 600, "scrgo");
    defer wl.deinit();
    defer gpu.stop(); // must run before wl.deinit() to destroy wayland buffers first

    if (wl.commitSolidBackground(cfg.background.r, cfg.background.g, cfg.background.b, 255)) {
        s_app.diag.recordCommit('b');
        if (debugStartupEnabled()) {
            std.debug.print("scrgo: 1px bg ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
        }
    } else if (wl.shm) |shm| {
        var bg_frame = shm_render.ShmFrame.create(@ptrCast(shm), wl.width, wl.height);
        if (bg_frame) |*frame| {
            frame.fillBackground(cfg.background);
            frame.commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
            s_app.diag.recordCommit('b');
            if (debugStartupEnabled()) {
                std.debug.print("scrgo: SHM bg ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
            }
            frame.destroy();
        }
    }

    if (requested_render_path == .gpu and wl.linux_dmabuf == null) {
        std.debug.print("scrgo: GPU renderer requested but linux-dmabuf is unavailable; falling back to CPU\n", .{});
    }

    // ── Phase 2: wait for font (overlapped with Wayland init) ──
    const font_resp = (try atlas_thread.readResponse()) orelse return error.BootstrapFailed;
    if (font_resp.tag == .failed) {
        if (atlas_thread.bootstrap_err) |err| return err;
        return error.BootstrapFailed;
    }
    defer allocator.free(atlas_thread.bootstrap_font_path);
    const atlas_ref_ptr = atlas_thread.atlas_ref;
    s_app.refs.atlas_ref = atlas_ref_ptr;
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: font ready ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    var bootstrap_atlas_lease = atlas_ref_ptr.acquire();
    defer bootstrap_atlas_lease.release();
    const cell_metrics = try renderer_mod.computeCellMetrics(bootstrap_atlas_lease.get(), cfg.font_size);
    s_app.metrics.font_size = cfg.font_size;
    s_app.metrics.cell_width = cell_metrics.cell_width;
    s_app.metrics.cell_height = cell_metrics.cell_height;

    const grid = renderer_mod.computeGridSize(s_app.metrics.cell_width, s_app.metrics.cell_height, wl.width, wl.height);
    s_app.metrics.viewport_w = wl.width;
    s_app.metrics.viewport_h = wl.height;

    // ── Phase 3: fork PTY (while atlas init continues in background) ──
    var pty = if (exec_argv.items.len > 0)
        try pty_mod.Pty.spawnCommand(exec_argv.items, grid.cols, grid.rows)
    else
        try pty_mod.Pty.spawn(cfg.shell, grid.cols, grid.rows);
    defer pty.close();

    if (debugStartupEnabled()) {
        std.debug.print("scrgo: PTY forked, {}x{} ({d:.1}ms)\n", .{ grid.cols, grid.rows, startup_timer.elapsedMs() });
    }

    var term: terminal_mod.Terminal = undefined;
    try term.init(grid.cols, grid.rows, cfg.max_scrollback, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // ── Phase 4: wait for atlas (ASCII rasterization), start renderers ──
    const atlas_resp = (try atlas_thread.readResponse()) orelse return error.BootstrapFailed;
    if (atlas_resp.tag == .failed) {
        if (atlas_thread.bootstrap_err) |err| return err;
        return error.BootstrapFailed;
    }
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: atlas ready ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    if (wl.shm) |shm| {
        cpu.start(@ptrCast(shm), atlas_ref_ptr, &atlas_thread, wl.width, wl.height) catch |err| {
            std.debug.print("scrgo: cpu renderer start failed: {}\n", .{err});
        };
    }
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: cpu started ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    if (gpu.active and gpu.context_ready) {
        gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
        gpu.requestConfigure(wl.width, wl.height, s_app.metrics.font_size, s_app.metrics.cell_width, s_app.metrics.cell_height) catch |err| {
            std.debug.print("scrgo: gpu renderer initial configure failed: {}\n", .{err});
            gpu.stop();
            state.render.gpu_restart.scheduleRetry();
        };
        if (debugStartupEnabled()) {
            std.debug.print("scrgo: gpu renderer configured ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
        }
    } else if (gpu.active) {
        gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
    }

    term.pty_fd = pty.master_fd;

    s_app.refs.term = &term;
    s_app.refs.pty = &pty;
    s_app.refs.wayland = &wl;

    // Bring up the clipboard manager now that the seat-bound
    // data/primary devices exist. Use a stable address (declared on
    // main's stack) so the listeners' raw data pointer survives
    // every event for the program's lifetime.
    var clipboard = clipboard_mod.Manager.init(
        allocator,
        @ptrCast(wl.display),
        if (wl.data_device) |d| @ptrCast(d) else null,
        if (wl.primary_selection_device) |d| @ptrCast(d) else null,
        if (wl.data_device_manager) |m| @ptrCast(m) else null,
        if (wl.primary_selection_manager) |m| @ptrCast(m) else null,
    );
    defer clipboard.deinit();
    clipboard.bindListeners();
    s_app.refs.clipboard = &clipboard;
    wl.on_key = onKey;
    wl.on_mouse = onMouse;
    wl.on_resize = onResize;
    wl.on_focus = onFocus;
    s_app.metrics.scroll_lines = cfg.scroll_lines;
    s_app.metrics.base_font_size = cfg.font_size;
    s_app.render.needs_redraw = false;
    s_app.render.gpu_snapshot_dirty = false;
    s_app.render.gpu_reconfigure_requested = false;
    s_app.render.render_serial = 0;

    // ── Phase 5: early PTY drain + event loop ──
    state.refs.gpu = &gpu;
    state.refs.cpu = &cpu;
    state.refs.atlas_thread = &atlas_thread;
    state.render.active_render_path = .cpu;

    // ── Event loop (frontend Wayland + PTY, gpu/cpu renderer threads) ──
    var pty_buf: [65536]u8 = undefined;
    var child_exited = false;
    // Drain phase: after the child exits we keep looping just long enough
    // to commit a final frame containing its last output. Without this a
    // command like `-e echo hi` can exit before any paint reaches the
    // compositor — including from the bench harness, which would then
    // never observe first_content_paint.
    var draining = false;
    var drain_deadline_ns: u64 = 0;
    const drain_timeout_ns: u64 = 250 * std.time.ns_per_ms;

    if (debugStartupEnabled()) {
        std.debug.print("scrgo: main loop entry ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }

    main_loop: while (!wl.closed) {
        if (s_app.debug.renderer_debug.commits and child_exited and s_app.diag.t_child_exited_ns == 0) {
            s_app.diag.t_child_exited_ns = monotonicNowNs() - s_app.diag.commit_trace_start_ns;
        }
        if (child_exited and !draining) {
            // Slurp any bytes still buffered on the master before the kernel
            // closes the slave side.
            while (true) {
                const n = pty.read(&pty_buf) catch break;
                if (n == 0) break;
                term.feedData(pty_buf[0..n]);
                s_app.lifecycle.first_pty_data_seen = true;
                markRenderDirty();
            }
            draining = true;
            drain_deadline_ns = monotonicNowNs() + drain_timeout_ns;
            if (debugStartupEnabled()) {
                std.debug.print("scrgo: child exited, draining final frame ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
            }
        }

        if (draining) {
            // Exit as soon as a frame containing the final PTY output has
            // been committed (or no PTY output was ever produced). We
            // don't wait for the GPU renderer to overtake CPU — the user
            // has already seen the content.
            const painted = s_app.lifecycle.first_content_painted or !s_app.lifecycle.first_pty_data_seen;
            const renderers_idle = !gpu.render_in_flight and !cpu.render_in_flight;
            if (painted and renderers_idle) break;
            if (monotonicNowNs() >= drain_deadline_ns) {
                if (debugStartupEnabled()) {
                    std.debug.print("scrgo: drain timed out ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                }
                break;
            }
        }

        if (!gpu.active and s_app.render.target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null and state.render.gpu_restart.due()) {
            gpu.start() catch |err| {
                std.debug.print("scrgo: gpu renderer restart failed: {}\n", .{err});
                state.render.gpu_restart.scheduleRetry();
                continue;
            };
            gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
            if (debugRenderersEnabled() or debugStartupEnabled()) {
                std.debug.print("scrgo: restarting gpu renderer ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
            }
            state.render.gpu_restart.deadline_ns = null;
        }

        while (!wl.prepareRead()) {
            wl.dispatchPending() catch {
                std.debug.print("scrgo: wayland dispatchPending failed before poll, exiting\n", .{});
                break :main_loop;
            };
        }

        if (s_app.render.gpu_reconfigure_requested) {
            s_app.render.gpu_reconfigure_requested = false;
            if (gpu.active and gpu.context_ready) {
                gpu.requestConfigure(s_app.metrics.viewport_w, s_app.metrics.viewport_h, s_app.metrics.font_size, s_app.metrics.cell_width, s_app.metrics.cell_height) catch |err| {
                    std.debug.print("scrgo: gpu renderer reconfigure failed: {}\n", .{err});
                    noteGpuUnavailable(&gpu, &state.render.active_render_path, &state.render.gpu_restart);
                    continue;
                };
            } else if (s_app.render.target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null) {
                state.render.gpu_restart.scheduleImmediate();
            }
        }

        maybeScheduleScrollbarHide();
        maybeQueueGpuRendererFrame(&gpu, &wl, &term);
        renderActivePath(state.render.active_render_path, &gpu, &cpu, &wl, &term);
        wl.flush();

        // Key repeat timeout — wake up in time for next repeat event
        const repeat_timeout: c_int = if (wl.pumpRepeat()) |ms| @intCast(ms) else -1;
        const restart_timeout = if (!gpu.active and s_app.render.target_render_path == .gpu and gpu_allowed and wl.linux_dmabuf != null)
            state.render.gpu_restart.timeoutMs()
        else
            null;
        const scroll_timeout = scrollbarTimeoutMs();
        const poll_timeout = combineTimeout(combineTimeout(repeat_timeout, restart_timeout), scroll_timeout);

        var pollfds = [_]c.struct_pollfd{
            .{ .fd = wl.displayFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = pty.master_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (gpu.active) gpu.responseFd() else -1, .events = if (gpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (cpu.active) cpu.responseFd() else -1, .events = if (cpu.active) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (atlas_thread.active) atlas_thread.responseFd() else -1, .events = if (atlas_thread.active) c.POLLIN else 0, .revents = 0 },
        };

        const poll_t0 = if (s_app.debug.renderer_debug.commits) monotonicNowNs() else 0;
        const poll_rc = c.poll(&pollfds, 5, poll_timeout);
        if (s_app.debug.renderer_debug.commits) {
            s_app.diag.phase_poll_ns += monotonicNowNs() - poll_t0;
            s_app.diag.phase_poll_calls += 1;
        }
        if (poll_rc < 0) {
            wl.cancelRead();
            std.debug.print("scrgo: poll failed, exiting\n", .{});
            break;
        }

        if (pollfds[0].revents & c.POLLIN != 0) {
            wl.readEvents() catch {
                wl.cancelRead();
                std.debug.print("scrgo: wayland readEvents failed, exiting\n", .{});
                break;
            };
        } else {
            wl.cancelRead();
        }
        wl.dispatchPending() catch {
            std.debug.print("scrgo: wayland dispatchPending failed, exiting\n", .{});
            break :main_loop;
        };

        if (pollfds[2].fd >= 0 and pollfds[2].revents & c.POLLIN != 0) {
            const resp_opt = gpu.readResponse() catch null;
            if (resp_opt) |resp| {
                switch (resp.tag) {
                    .context_ready => {
                        if (debugRenderersEnabled() or debugStartupEnabled()) {
                            std.debug.print("scrgo: gpu renderer context ready ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                        }
                        if (gpu.atlas_ref == null) {
                            gpu.setSharedState(atlas_ref_ptr, &atlas_thread);
                        }
                        gpu.requestConfigure(s_app.metrics.viewport_w, s_app.metrics.viewport_h, s_app.metrics.font_size, s_app.metrics.cell_width, s_app.metrics.cell_height) catch |err| {
                            std.debug.print("scrgo: gpu renderer configure after context_ready failed: {}\n", .{err});
                            noteGpuUnavailable(&gpu, &state.render.active_render_path, &state.render.gpu_restart);
                            continue;
                        };
                    },
                    .ready => {
                        if (wl.linux_dmabuf) |linux_dmabuf| {
                            gpu.installBuffers(@ptrCast(linux_dmabuf)) catch |err| {
                                std.debug.print("scrgo: GPU dmabuf import failed: {}\n", .{err});
                                noteGpuUnavailable(&gpu, &state.render.active_render_path, &state.render.gpu_restart);
                                continue;
                            };
                            s_app.render.gpu_snapshot_dirty = true;
                            state.render.gpu_restart.clear();
                            if (debugRenderersEnabled() or debugStartupEnabled()) {
                                std.debug.print("scrgo: gpu renderer ready ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                            }
                        } else {
                            noteGpuUnavailable(&gpu, &state.render.active_render_path, &state.render.gpu_restart);
                        }
                    },
                    .frame => {
                        if (s_app.render.target_render_path != .gpu) {
                            // Target switched away from gpu; drop this frame.
                            s_app.diag.recordCommit('d');
                        } else {
                            if (debugRenderersEnabled()) {
                                std.debug.print("scrgo: gpu renderer frame ready buffer={} ({d:.1}ms)\n", .{
                                    resp.buffer_index,
                                    startup_timer.elapsedMs(),
                                });
                            }
                            if (resp.buffer_index < gpu.frontend_buffer_count) {
                                // Commit immediately. If the compositor
                                // still has the prior frame pending,
                                // this commit replaces it in the
                                // compositor's pending state — the
                                // prior render is discarded, but
                                // there's no latency penalty for the
                                // newer content.
                                gpu.buffers[resp.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                                s_app.diag.recordCommit('g');
                                s_app.diag.recordCommitSerial('g', resp.serial, s_app.render.render_serial, s_app.render.gpu_snapshot_dirty or s_app.render.needs_redraw);
                                if (!wl.frame_pending) wl.requestFrame();
                                if (state.render.active_render_path != .gpu) {
                                    if (debugFramesEnabled()) {
                                        std.debug.print("scrgo: switching render path cpu->gpu\n", .{});
                                    }
                                    state.render.active_render_path = .gpu;
                                }
                                if (!gpu.first_frame_presented) {
                                    if (debugFramesEnabled() or debugRenderersEnabled() or debugStartupEnabled()) {
                                        std.debug.print("scrgo: first gpu renderer paint ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                                    }
                                    gpu.first_frame_presented = true;
                                }
                                markFirstContentPaint();
                            }
                            // Only clear the dirty bit if the snapshot we
                            // committed reflects the latest state. If PTY
                            // produced more data while the renderer was
                            // working, we keep dirty=true and queue
                            // another render on the next loop iteration.
                            if (resp.serial == s_app.render.render_serial) {
                                s_app.render.needs_redraw = false;
                                term.resetDirty();
                            }
                        }
                    },
                    .retry => {
                        // Glyph miss — atlas extension requested, retry on next frame
                        s_app.render.gpu_snapshot_dirty = true;
                    },
                    .failed => {
                        std.debug.print("scrgo: gpu renderer failed\n", .{});
                        noteGpuUnavailable(&gpu, &state.render.active_render_path, &state.render.gpu_restart);
                    },
                }
            } else {
                noteGpuUnavailable(&gpu, &state.render.active_render_path, &state.render.gpu_restart);
            }
        }

        if (pollfds[3].fd >= 0 and pollfds[3].revents & c.POLLIN != 0) {
            const resp_opt = cpu.readResponse() catch null;
            if (resp_opt) |resp| {
                switch (resp.tag) {
                    .frame => {
                        const buffer_ok = resp.buffer_index < cpu.buffer_count;
                        const path_ok = state.render.active_render_path == .cpu;
                        const size_ok = cpu.width == wl.width and cpu.height == wl.height;
                        if (buffer_ok and path_ok and size_ok) {
                            cpu.buffers[resp.buffer_index].commit(@ptrCast(wl.surface.?), @ptrCast(wl.display));
                            s_app.diag.recordCommit('c');
                            s_app.diag.recordCommitSerial('c', resp.serial, s_app.render.render_serial, s_app.render.gpu_snapshot_dirty or s_app.render.needs_redraw);
                            if (!wl.frame_pending) wl.requestFrame();
                            if (debugFramesEnabled()) {
                                std.debug.print("scrgo: cpu renderer frame committed buffer={} ({d:.1}ms)\n", .{
                                    resp.buffer_index,
                                    s_app.diag.elapsedMs(),
                                });
                            }
                            markFirstContentPaint();
                        } else if (debugFramesEnabled()) {
                            const reason: []const u8 = if (!buffer_ok)
                                "bad buffer index"
                            else if (!path_ok)
                                "active path is gpu"
                            else
                                "size mismatch";
                            std.debug.print("scrgo: cpu renderer frame dropped buffer={} ({s}) ({d:.1}ms)\n", .{
                                resp.buffer_index,
                                reason,
                                s_app.diag.elapsedMs(),
                            });
                        }
                        // Only clear dirty if no new PTY data arrived
                        // while the renderer was working.
                        if (resp.serial == s_app.render.render_serial and !s_app.render.needs_redraw) {
                            term.resetDirty();
                        }
                    },
                    .failed => {
                        s_app.render.needs_redraw = true;
                    },
                }
            }
        }

        if (pollfds[4].fd >= 0 and pollfds[4].revents & c.POLLIN != 0) {
            const resp_opt = atlas_thread.readResponse() catch null;
            if (resp_opt) |resp| {
                switch (resp.tag) {
                    .updated => {
                        if (debugRenderersEnabled() or s_app.debug.renderer_debug.atlas) {
                            std.debug.print("scrgo: atlas owner applied {} codepoints pages+={}\n", .{
                                resp.requested_count,
                                resp.added_pages,
                            });
                        }
                        markRenderDirty();
                    },
                    .failed => {
                        std.debug.print("scrgo: atlas owner update failed for {} codepoints\n", .{resp.requested_count});
                    },
                    .font_ready, .bootstrap_ready => {},
                }
            }
        }

        // After zoom/resize, draw before reading PTY so the reflowed
        // content is presented before the shell's SIGWINCH response
        // can clear the prompt line.
        maybeQueueGpuRendererFrame(&gpu, &wl, &term);
        renderActivePath(state.render.active_render_path, &gpu, &cpu, &wl, &term);

        if (pollfds[1].revents & c.POLLIN != 0) {
            // Time-bounded drain: read until kernel buffer is empty OR
            // we've burned the budget. Without the budget cap, a long
            // stream (`cat largefile`) would hold the main thread for
            // its full duration and the renderer would only see/commit
            // the final state. With the cap we yield mid-stream so the
            // user sees the output scroll by. 4 ms is roughly a
            // quarter vblank — enough headroom that a slow feedData
            // call (atlas miss, etc.) won't push past one full frame.
            const read_start_ns = monotonicNowNs();
            const read_budget_ns: u64 = 4 * std.time.ns_per_ms;
            while (true) {
                const read_t0 = if (s_app.debug.renderer_debug.commits) monotonicNowNs() else 0;
                const n = pty.read(&pty_buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => {
                        if (debugStartupEnabled() or debugPtyEnabled()) {
                            std.debug.print("scrgo: PTY read failed: {}, exiting\n", .{err});
                        }
                        child_exited = true;
                        break;
                    },
                };
                if (n == 0) {
                    if (debugStartupEnabled() or debugPtyEnabled()) {
                        std.debug.print("scrgo: PTY EOF/EIO, exiting\n", .{});
                    }
                    child_exited = true;
                    break;
                }
                if (debugPtyEnabled()) {
                    std.debug.print("scrgo: PTY read {} bytes ({d:.1}ms)\n", .{ n, s_app.diag.elapsedMs() });
                }
                if (s_app.debug.renderer_debug.commits) {
                    s_app.diag.phase_pty_read_ns += monotonicNowNs() - read_t0;
                    s_app.diag.phase_bytes_read += @intCast(n);
                }
                const feed_t0 = if (s_app.debug.renderer_debug.commits) monotonicNowNs() else 0;
                term.feedData(pty_buf[0..n]);
                if (s_app.debug.renderer_debug.commits) {
                    s_app.diag.phase_feed_data_ns += monotonicNowNs() - feed_t0;
                    s_app.diag.phase_feed_calls += 1;
                }
                if (s_app.debug.renderer_debug.commits and s_app.diag.t_first_pty_ns == 0) {
                    s_app.diag.t_first_pty_ns = monotonicNowNs() - s_app.diag.commit_trace_start_ns;
                }
                s_app.lifecycle.first_pty_data_seen = true;
                markRenderDirty();
                if (monotonicNowNs() - read_start_ns >= read_budget_ns) break;
            }
        }

        if (!child_exited) {
            if (pty.checkChild()) |status| {
                if (debugStartupEnabled() or debugPtyEnabled()) {
                    std.debug.print("scrgo: PTY child exited status={}, exiting\n", .{status});
                }
                child_exited = true;
                if (s_app.debug.renderer_debug.commits and s_app.diag.t_child_exited_ns == 0) {
                    s_app.diag.t_child_exited_ns = monotonicNowNs() - s_app.diag.commit_trace_start_ns;
                }
            }
        }

        maybeQueueGpuRendererFrame(&gpu, &wl, &term);
        renderActivePath(state.render.active_render_path, &gpu, &cpu, &wl, &term);

        maybeQueueGpuRendererFrame(&gpu, &wl, &term);
    }

    if (s_app.debug.renderer_debug.commits) {
        s_app.diag.t_main_loop_exit_ns = monotonicNowNs() - s_app.diag.commit_trace_start_ns;
    }
    if (debugStartupEnabled()) {
        std.debug.print("scrgo: main loop exit ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
    }
    s_app.diag.dumpExitReport(.{
        .wl_closed = wl.closed,
        .child_exited = child_exited,
        .render_serial = s_app.render.render_serial,
        .pipeline_dirty = s_app.render.gpu_snapshot_dirty or s_app.render.needs_redraw,
    });

    // Skip the defer chain (cpu/atlas/gpu thread joins, wl_display_disconnect,
    // buffer/surface destroys, allocator frees). Wayland is designed so the
    // compositor treats socket close identically to a clean disconnect — it
    // tears down our resources either way. Threads and memory are reaped by
    // the kernel. Saves ~2 ms of teardown on the critical path.
    c._exit(0);
}

fn keysymToGhosttyKey(keysym: u32) c_uint {
    const ks: c_int = @intCast(keysym);
    return @intCast(switch (ks) {
        xkb_syms.XKB_KEY_a...xkb_syms.XKB_KEY_z => ghostty_c.GHOSTTY_KEY_A + (ks - xkb_syms.XKB_KEY_a),
        xkb_syms.XKB_KEY_A...xkb_syms.XKB_KEY_Z => ghostty_c.GHOSTTY_KEY_A + (ks - xkb_syms.XKB_KEY_A),
        xkb_syms.XKB_KEY_0...xkb_syms.XKB_KEY_9 => ghostty_c.GHOSTTY_KEY_DIGIT_0 + (ks - xkb_syms.XKB_KEY_0),
        xkb_syms.XKB_KEY_Return => ghostty_c.GHOSTTY_KEY_ENTER,
        xkb_syms.XKB_KEY_KP_Enter => ghostty_c.GHOSTTY_KEY_NUMPAD_ENTER,
        xkb_syms.XKB_KEY_Tab => ghostty_c.GHOSTTY_KEY_TAB,
        xkb_syms.XKB_KEY_ISO_Left_Tab => ghostty_c.GHOSTTY_KEY_TAB,
        xkb_syms.XKB_KEY_BackSpace => ghostty_c.GHOSTTY_KEY_BACKSPACE,
        xkb_syms.XKB_KEY_Escape => ghostty_c.GHOSTTY_KEY_ESCAPE,
        xkb_syms.XKB_KEY_Delete => ghostty_c.GHOSTTY_KEY_DELETE,
        xkb_syms.XKB_KEY_Insert => ghostty_c.GHOSTTY_KEY_INSERT,
        xkb_syms.XKB_KEY_Home => ghostty_c.GHOSTTY_KEY_HOME,
        xkb_syms.XKB_KEY_End => ghostty_c.GHOSTTY_KEY_END,
        xkb_syms.XKB_KEY_Page_Up => ghostty_c.GHOSTTY_KEY_PAGE_UP,
        xkb_syms.XKB_KEY_Page_Down => ghostty_c.GHOSTTY_KEY_PAGE_DOWN,
        xkb_syms.XKB_KEY_Up => ghostty_c.GHOSTTY_KEY_ARROW_UP,
        xkb_syms.XKB_KEY_Down => ghostty_c.GHOSTTY_KEY_ARROW_DOWN,
        xkb_syms.XKB_KEY_Left => ghostty_c.GHOSTTY_KEY_ARROW_LEFT,
        xkb_syms.XKB_KEY_Right => ghostty_c.GHOSTTY_KEY_ARROW_RIGHT,
        xkb_syms.XKB_KEY_space => ghostty_c.GHOSTTY_KEY_SPACE,
        xkb_syms.XKB_KEY_apostrophe => ghostty_c.GHOSTTY_KEY_QUOTE,
        xkb_syms.XKB_KEY_comma => ghostty_c.GHOSTTY_KEY_COMMA,
        xkb_syms.XKB_KEY_minus => ghostty_c.GHOSTTY_KEY_MINUS,
        xkb_syms.XKB_KEY_period => ghostty_c.GHOSTTY_KEY_PERIOD,
        xkb_syms.XKB_KEY_slash => ghostty_c.GHOSTTY_KEY_SLASH,
        xkb_syms.XKB_KEY_semicolon => ghostty_c.GHOSTTY_KEY_SEMICOLON,
        xkb_syms.XKB_KEY_equal => ghostty_c.GHOSTTY_KEY_EQUAL,
        xkb_syms.XKB_KEY_bracketleft => ghostty_c.GHOSTTY_KEY_BRACKET_LEFT,
        xkb_syms.XKB_KEY_bracketright => ghostty_c.GHOSTTY_KEY_BRACKET_RIGHT,
        xkb_syms.XKB_KEY_backslash => ghostty_c.GHOSTTY_KEY_BACKSLASH,
        xkb_syms.XKB_KEY_grave => ghostty_c.GHOSTTY_KEY_BACKQUOTE,
        xkb_syms.XKB_KEY_F1...xkb_syms.XKB_KEY_F12 => ghostty_c.GHOSTTY_KEY_F1 + (ks - xkb_syms.XKB_KEY_F1),
        xkb_syms.XKB_KEY_F13...xkb_syms.XKB_KEY_F25 => ghostty_c.GHOSTTY_KEY_F13 + (ks - xkb_syms.XKB_KEY_F13),
        xkb_syms.XKB_KEY_Shift_L,
        xkb_syms.XKB_KEY_Shift_R,
        xkb_syms.XKB_KEY_Control_L,
        xkb_syms.XKB_KEY_Control_R,
        xkb_syms.XKB_KEY_Alt_L,
        xkb_syms.XKB_KEY_Alt_R,
        xkb_syms.XKB_KEY_Super_L,
        xkb_syms.XKB_KEY_Super_R,
        xkb_syms.XKB_KEY_Caps_Lock,
        xkb_syms.XKB_KEY_Num_Lock,
        => 0,
        else => 0,
    });
}

fn modsToGhostty(mods: wayland_mod.Mods) c_ushort {
    var result: c_ushort = 0;
    if (mods.shift) result |= ghostty_c.GHOSTTY_MODS_SHIFT;
    if (mods.ctrl) result |= ghostty_c.GHOSTTY_MODS_CTRL;
    if (mods.alt) result |= ghostty_c.GHOSTTY_MODS_ALT;
    if (mods.super_) result |= ghostty_c.GHOSTTY_MODS_SUPER;
    return result;
}
