const std = @import("std");
const app_state = @import("app_state.zig");
const diagnostics = @import("diagnostics.zig");
const render_loop = @import("render_loop.zig");
const selection_mod = @import("selection.zig");
const clipboard_mod = @import("clipboard.zig");
const wayland_mod = @import("wayland.zig");
const render_snapshot = @import("render/render_snapshot.zig");
const gpu_pipeline = @import("render/gpu_pipeline.zig");
const log = @import("log.zig");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("time.h");
});

const ghostty_c = @cImport(@cInclude("ghostty/vt.h"));
const xkb_syms = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));

// Wayland callbacks (wayland.zig:145-148) are bare function pointers with
// no userdata pointer, so the four on_* handlers reach AppState via this
// static. main() calls bind() exactly once after every state.refs.* is
// populated and before assigning wl.on_key = onKey etc.; if a callback
// fires before bind() runs, this deref panics with `state` undefined.
var state: *app_state.AppState = undefined;

pub fn bind(s: *app_state.AppState) void {
    state = s;
}

/// Wayland evdev codes for the buttons we care about. Imported here
/// rather than dragging in <linux/input-event-codes.h> for a handful of
/// constants.
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;

/// Hover detection: pointer is within this many pixels of the right edge.
const SCROLLBAR_HOVER_WIDTH: f64 = 16.0;

/// Velocity smoothing across motion samples. 0 = no smoothing
/// (each sample replaces the velocity), 1 = no update.
const TOUCH_VELOCITY_EWMA: f64 = 0.65;
/// A motion gap longer than this kills the velocity sample —
/// otherwise a finger that stalled before release would still flick.
const TOUCH_VELOCITY_STALL_MS: i64 = 80;
/// Friction applied to the fling integrator each second (lines/s²).
const TOUCH_FLING_DECEL: f64 = 14.0;
/// Stop the fling once |velocity| drops below this many lines/sec.
const TOUCH_FLING_MIN_LPS: f64 = 1.5;
/// Cap on initial fling speed so a fast flick doesn't catapult
/// past the scrollback.
const TOUCH_FLING_MAX_LPS: f64 = 80.0;

pub fn onKey(ev: wayland_mod.KeyEvent) void {
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
                state.refs.term.scrollViewport(-1);
                render_loop.markRenderDirty(state);
                return;
            },
            xkb_syms.XKB_KEY_Down => {
                state.refs.term.scrollViewport(1);
                render_loop.markRenderDirty(state);
                return;
            },
            xkb_syms.XKB_KEY_Page_Up => {
                state.refs.term.scrollViewport(-@as(isize, state.metrics.scroll_lines * 10));
                render_loop.markRenderDirty(state);
                return;
            },
            xkb_syms.XKB_KEY_Page_Down => {
                state.refs.term.scrollViewport(@as(isize, state.metrics.scroll_lines * 10));
                render_loop.markRenderDirty(state);
                return;
            },
            xkb_syms.XKB_KEY_Home => {
                state.refs.term.scrollToTop();
                render_loop.markRenderDirty(state);
                return;
            },
            xkb_syms.XKB_KEY_End => {
                state.refs.term.scrollToBottom();
                render_loop.markRenderDirty(state);
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
                state.refs.term.scrollViewport(-@as(isize, state.metrics.scroll_lines * 10));
                render_loop.markRenderDirty(state);
                return;
            },
            xkb_syms.XKB_KEY_Page_Down => {
                state.refs.term.scrollViewport(@as(isize, state.metrics.scroll_lines * 10));
                render_loop.markRenderDirty(state);
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
        state.refs.term.scrollToBottom();
        state.refs.pty.write(text) catch {};
        return;
    }

    const gkey = keysymToGhosttyKey(ev.keysym);
    if (gkey != 0) {
        state.refs.term.scrollToBottom();
        const encoded = state.refs.term.encodeKey(
            gkey,
            ghostty_c.GHOSTTY_KEY_ACTION_PRESS,
            modsToGhostty(ev.mods),
            null,
        );
        if (encoded) |data| {
            state.refs.pty.write(data) catch {};
        }
    }
}

pub fn onMouse(ev: wayland_mod.MouseEvent) void {
    state.input.pointer_x = ev.x;
    state.input.pointer_y = ev.y;
    switch (ev.kind) {
        .enter => state.input.pointer_in_surface = true,
        .leave => {
            state.input.pointer_in_surface = false;
            // Leaving the surface also kills hover detection — fall
            // back to scroll-driven visibility only.
        },
        .scroll => {
            const lines: isize = if (ev.scroll_dy > 0) @intCast(state.metrics.scroll_lines) else -@as(isize, @intCast(state.metrics.scroll_lines));
            state.refs.term.scrollViewport(lines);
            render_loop.bumpScrollbarVisibility(state);
            render_loop.markRenderDirty(state);
        },
        .button_press => {
            const cell = pixelToCell(ev.x, ev.y) orelse return;
            switch (ev.button) {
                BTN_LEFT => {
                    state.input.selection.beginPrimary(cell, ev.mods.shift, nowMs());
                    render_loop.markRenderDirty(state);
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
                    const had_selection = state.input.selection.range != null;
                    state.input.selection.endDrag();
                    // Drag finished with non-empty selection: claim
                    // the primary selection so middle-click in
                    // another app pastes our text.
                    if (had_selection and state.input.selection.range != null) {
                        copyToPrimary();
                    }
                    render_loop.markRenderDirty(state);
                },
                else => {},
            }
        },
        .motion => {
            const near_right_edge = @as(f64, @floatFromInt(state.metrics.viewport_w)) - ev.x <= SCROLLBAR_HOVER_WIDTH;
            if (near_right_edge) {
                render_loop.bumpScrollbarVisibility(state);
                render_loop.markRenderDirty(state);
            }
            if (state.input.selection.dragging) {
                const cell = pixelToCell(ev.x, ev.y) orelse return;
                state.input.selection.updateDrag(cell);
                render_loop.markRenderDirty(state);
            }
        },
    }
}

pub fn onTouch(ev: wayland_mod.TouchEvent) void {
    var ts = &state.input.touch;
    const now = nowMs();
    switch (ev.kind) {
        .down => {
            // Only track the first finger; secondary touches are
            // ignored until the active one lifts. A new touch always
            // kills any in-progress fling — direct manipulation wins.
            cancelFling();
            if (ts.active_id != null) return;
            ts.active_id = ev.id;
            ts.down_x = ev.x;
            ts.down_y = ev.y;
            ts.down_ms = now;
            ts.last_x = ev.x;
            ts.last_y = ev.y;
            ts.last_motion_ms = now;
            ts.mode = .undecided;
            ts.scroll_residual_lines = 0;
            ts.velocity_y_px_per_ms = 0;
            // A tap reveals the scrollbar (it'll fade on the regular
            // timer) so the user knows where in scrollback they are.
            render_loop.bumpScrollbarVisibility(state);
            render_loop.markRenderDirty(state);
        },
        .motion => {
            const active = ts.active_id orelse return;
            if (ev.id != active) return;
            const dy = ev.y - ts.last_y;
            const dt_ms_raw = now - ts.last_motion_ms;
            const dt_ms: f64 = if (dt_ms_raw > 0) @floatFromInt(dt_ms_raw) else 1.0;

            if (ts.mode == .undecided) {
                const ddx = ev.x - ts.down_x;
                const ddy = ev.y - ts.down_y;
                const drift_sq = ddx * ddx + ddy * ddy;
                const limit = @as(f64, state.input.touch_cfg.drift_px);
                if (drift_sq > limit * limit) {
                    ts.mode = .scroll;
                } else if (now - ts.down_ms >= @as(i64, @intCast(state.input.touch_cfg.long_press_ms))) {
                    promoteToSelect();
                }
            }

            switch (ts.mode) {
                .undecided => {},
                .scroll => {
                    // Natural-scroll convention: finger moves down →
                    // viewport scrolls toward older lines (negative).
                    if (state.metrics.cell_height > 0) {
                        ts.scroll_residual_lines += -dy / state.metrics.cell_height;
                        const whole = @trunc(ts.scroll_residual_lines);
                        if (whole != 0) {
                            const lines: isize = @intFromFloat(whole);
                            state.refs.term.scrollViewport(lines);
                            ts.scroll_residual_lines -= whole;
                            render_loop.bumpScrollbarVisibility(state);
                            render_loop.markRenderDirty(state);
                        }
                    }
                    // EWMA velocity in px/ms (signed: finger-down +y).
                    const sample = dy / dt_ms;
                    if (dt_ms_raw > TOUCH_VELOCITY_STALL_MS) {
                        ts.velocity_y_px_per_ms = sample;
                    } else {
                        ts.velocity_y_px_per_ms = TOUCH_VELOCITY_EWMA * ts.velocity_y_px_per_ms + (1.0 - TOUCH_VELOCITY_EWMA) * sample;
                    }
                },
                .select => {
                    const cell = pixelToCell(ev.x, ev.y) orelse return;
                    state.input.selection.updateDrag(cell);
                    render_loop.markRenderDirty(state);
                },
            }

            ts.last_x = ev.x;
            ts.last_y = ev.y;
            ts.last_motion_ms = now;
        },
        .up => {
            const active = ts.active_id orelse return;
            if (ev.id != active) return;
            switch (ts.mode) {
                .select => {
                    const had_selection = state.input.selection.range != null;
                    state.input.selection.endDrag();
                    if (had_selection and state.input.selection.range != null) {
                        copyToPrimary();
                    }
                    render_loop.markRenderDirty(state);
                },
                .scroll => {
                    if (state.input.touch_cfg.momentum) startFling();
                },
                .undecided => {
                    // Quick tap — nothing to do.
                },
            }
            ts.active_id = null;
            ts.mode = .undecided;
        },
        .cancel => {
            cancelTouch();
        },
    }
}

fn cancelTouch() void {
    var ts = &state.input.touch;
    if (ts.mode == .select) {
        // Don't commit a partial selection from a compositor-cancelled
        // touch; clear the in-progress range.
        state.input.selection.clear();
        render_loop.markRenderDirty(state);
    }
    ts.active_id = null;
    ts.mode = .undecided;
    cancelFling();
}

fn cancelFling() void {
    var ts = &state.input.touch;
    ts.fling_lines_per_s = 0;
    ts.fling_residual_lines = 0;
    ts.fling_last_tick_ns = 0;
}

fn promoteToSelect() void {
    var ts = &state.input.touch;
    const cell = pixelToCell(ts.last_x, ts.last_y) orelse return;
    state.input.selection.beginPrimary(cell, false, nowMs());
    ts.mode = .select;
    render_loop.markRenderDirty(state);
}

fn startFling() void {
    var ts = &state.input.touch;
    // A stalled finger at release has near-zero velocity already, but
    // also kill it explicitly if the last motion is too stale.
    if (nowMs() - ts.last_motion_ms > TOUCH_VELOCITY_STALL_MS) return;
    if (state.metrics.cell_height <= 0) return;
    // px/ms → px/s → lines/s; flip sign for natural-scroll.
    var lps = -ts.velocity_y_px_per_ms * 1000.0 / state.metrics.cell_height;
    if (lps > TOUCH_FLING_MAX_LPS) lps = TOUCH_FLING_MAX_LPS;
    if (lps < -TOUCH_FLING_MAX_LPS) lps = -TOUCH_FLING_MAX_LPS;
    if (@abs(lps) < TOUCH_FLING_MIN_LPS) return;
    ts.fling_lines_per_s = lps;
    ts.fling_residual_lines = 0;
    ts.fling_last_tick_ns = 0;
    render_loop.bumpScrollbarVisibility(state);
    render_loop.markRenderDirty(state);
}

/// Called once per main-loop iteration. Promotes an undecided touch
/// to select-mode once the long-press threshold has passed (even
/// without a fresh motion event, so a perfectly still finger still
/// triggers selection on simulated mouse input).
pub fn tickTouch() void {
    const ts = &state.input.touch;
    if (ts.active_id == null) return;
    if (ts.mode != .undecided) return;
    if (nowMs() - ts.down_ms >= @as(i64, @intCast(state.input.touch_cfg.long_press_ms))) {
        promoteToSelect();
    }
}

/// Called once per main-loop iteration. Advances the fling
/// integrator and forwards whole-line steps to the terminal; the
/// fractional residual carries over so smooth motion survives
/// frame-rate jitter. Marks the frame dirty as long as the fling is
/// alive so the loop keeps presenting.
pub fn tickFling() void {
    var ts = &state.input.touch;
    if (ts.fling_lines_per_s == 0) return;
    const now_ns = diagnostics.monotonicNowNs();
    if (ts.fling_last_tick_ns == 0) {
        ts.fling_last_tick_ns = now_ns;
        return;
    }
    const dt_s = @as(f64, @floatFromInt(now_ns - ts.fling_last_tick_ns)) / @as(f64, std.time.ns_per_s);
    ts.fling_last_tick_ns = now_ns;

    const sign: f64 = if (ts.fling_lines_per_s > 0) 1.0 else -1.0;
    const speed = @abs(ts.fling_lines_per_s) - TOUCH_FLING_DECEL * dt_s;
    if (speed < TOUCH_FLING_MIN_LPS) {
        cancelFling();
        return;
    }
    ts.fling_lines_per_s = sign * speed;

    ts.fling_residual_lines += ts.fling_lines_per_s * dt_s;
    const whole = @trunc(ts.fling_residual_lines);
    if (whole != 0) {
        const lines: isize = @intFromFloat(whole);
        state.refs.term.scrollViewport(lines);
        ts.fling_residual_lines -= whole;
        render_loop.bumpScrollbarVisibility(state);
    }
    render_loop.markRenderDirty(state);
}

/// Poll-timeout hook: returns ms until the next gesture-driven
/// wakeup, or null when neither the long-press timer nor a fling
/// needs the loop to spin.
pub fn touchTimeoutMs() ?c_int {
    const ts = &state.input.touch;
    var soonest: ?c_int = null;
    if (ts.active_id != null and ts.mode == .undecided) {
        const elapsed = nowMs() - ts.down_ms;
        const remaining = @as(i64, @intCast(state.input.touch_cfg.long_press_ms)) - elapsed;
        const ms: c_int = if (remaining <= 0) 0 else @intCast(@min(remaining, @as(i64, std.math.maxInt(c_int))));
        soonest = ms;
    }
    if (ts.fling_lines_per_s != 0) {
        // Vsync-pace the fling integrator: 16ms is the worst case
        // for a 60Hz frame loop, but a frame_done arrival will wake
        // us earlier.
        soonest = if (soonest) |s| @min(s, @as(c_int, 16)) else 16;
    }
    return soonest;
}

pub fn onResize(w: u32, h: u32) void {
    const grid = gpu_pipeline.computeGridSize(state.metrics.cell_width, state.metrics.cell_height, w, h);
    if (grid.cols == 0 or grid.rows == 0) return;
    state.metrics.viewport_w = w;
    state.metrics.viewport_h = h;
    state.refs.term.resize(grid.cols, grid.rows, @intFromFloat(state.metrics.cell_width), @intFromFloat(state.metrics.cell_height)) catch {};
    state.refs.pty.resize(grid.cols, grid.rows, w, h);
    render_loop.markRenderDirty(state);
    state.render.gpu_reconfigure_requested = true;
}

pub fn onFocus(focused: bool) void {
    _ = focused;
}

/// IME / on-screen-keyboard commit. Bytes were already finalized at
/// a text-input-v3 `done` boundary, so we forward straight to the
/// PTY — same path as utf8 from a hardware key.
pub fn onTextCommit(text: []const u8) void {
    if (text.len == 0) return;
    state.refs.term.scrollToBottom();
    state.refs.pty.write(text) catch {};
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.tv_sec) * std.time.ms_per_s + @divTrunc(ts.tv_nsec, std.time.ns_per_ms);
}

/// Convert surface-local pixel coords to a selection cell anchored in
/// absolute screen coordinates (row 0 = top of scrollback). Returns
/// null when metrics aren't ready yet (early startup). Clamps the
/// viewport portion to the grid so a drag past the window edge still
/// produces a valid cell, then offsets by the current viewport top so
/// the resulting Cell stays valid as the terminal scrolls.
fn pixelToCell(x: f64, y: f64) ?selection_mod.Cell {
    if (state.metrics.cell_width <= 0 or state.metrics.cell_height <= 0) return null;
    const term_cols = state.refs.term.colCount();
    const term_rows = state.refs.term.rowCount();
    if (term_cols == 0 or term_rows == 0) return null;
    const col_f = @floor(x / state.metrics.cell_width);
    const row_f = @floor(y / state.metrics.cell_height);
    const col_i = @as(i32, @intFromFloat(@max(0.0, col_f)));
    const row_i = @as(i32, @intFromFloat(@max(0.0, row_f)));
    const col: u16 = @intCast(@min(@as(i32, term_cols - 1), col_i));
    const view_row: u16 = @intCast(@min(@as(i32, term_rows - 1), row_i));
    const sb = state.refs.term.scrollbar();
    const screen_y: u32 = @intCast(@min(sb.offset + view_row, std.math.maxInt(u32)));
    return .{ .row = screen_y, .col = col };
}

fn zoomIn() void {
    state.metrics.font_size = @min(state.metrics.font_size + 1.0, 72.0);
    applyZoom();
}

fn zoomOut() void {
    state.metrics.font_size = @max(state.metrics.font_size - 1.0, 6.0);
    applyZoom();
}

fn zoomReset() void {
    state.metrics.font_size = state.metrics.base_font_size;
    applyZoom();
}

fn applyZoom() void {
    var atlas_lease = state.refs.atlas_ref.acquire();
    defer atlas_lease.release();
    const cm = gpu_pipeline.computeCellMetrics(atlas_lease.get(), state.metrics.font_size) catch return;
    state.metrics.cell_width = cm.cell_width;
    state.metrics.cell_height = cm.cell_height;

    const grid = gpu_pipeline.computeGridSize(state.metrics.cell_width, state.metrics.cell_height, state.metrics.viewport_w, state.metrics.viewport_h);
    if (grid.cols > 0 and grid.rows > 0) {
        state.refs.term.resize(grid.cols, grid.rows, @intFromFloat(state.metrics.cell_width), @intFromFloat(state.metrics.cell_height)) catch {};
        state.refs.pty.resize(grid.cols, grid.rows, state.metrics.viewport_w, state.metrics.viewport_h);
    }

    render_loop.markRenderDirty(state);
    state.render.gpu_reconfigure_requested = true;
}

/// Copy the current selection to the regular clipboard (Ctrl+Shift+C).
/// Silent no-op when there's nothing selected or no Wayland clipboard
/// support is available.
fn copySelectionToClipboard() void {
    const mgr = state.refs.clipboard orelse return;
    const allocator = std.heap.smp_allocator;
    const text = extractSelectionText(allocator) catch return orelse return;
    const serial = state.refs.wayland.last_input_serial;
    mgr.setText(.clipboard, text, serial) catch {
        allocator.free(text);
    };
}

/// Stamp the current selection onto the primary selection so middle-
/// click paste in other apps works. Called when a drag ends with a
/// non-empty range.
fn copyToPrimary() void {
    const mgr = state.refs.clipboard orelse return;
    const allocator = std.heap.smp_allocator;
    const text = extractSelectionText(allocator) catch return orelse return;
    const serial = state.refs.wayland.last_input_serial;
    mgr.setText(.primary, text, serial) catch {
        allocator.free(text);
    };
}

/// Read the named clipboard channel and write the bytes to the PTY,
/// wrapped in bracketed-paste markers if the terminal asked for them.
fn pasteFromClipboard(kind: clipboard_mod.Kind) void {
    const mgr = state.refs.clipboard orelse return;
    const allocator = std.heap.smp_allocator;
    const text = (mgr.getText(kind, allocator, 200) catch return) orelse return;
    defer allocator.free(text);
    writePasteToPty(text);
}

/// Forward a paste buffer to the PTY. Defers to terminal.encodePaste
/// which strips unsafe bytes and applies bracketed-paste wrapping.
fn writePasteToPty(text: []const u8) void {
    const allocator = std.heap.smp_allocator;
    const encoded = state.refs.term.encodePaste(allocator, text) catch return orelse return;
    defer allocator.free(encoded);
    state.refs.pty.write(encoded) catch {};
    state.refs.term.scrollToBottom();
    render_loop.markRenderDirty(state);
}

/// Read the codepoints of the row at absolute screen-y `target_screen_y`
/// into `out` (UTF-32). Returns the column count actually read.
/// Prefers the render-state iterator when the row is currently in
/// the viewport (fast path) and falls back to the grid_ref-based
/// scrollback walker for rows above or below the visible viewport.
fn fetchRowCodepoints(target_screen_y: u32, out: []u32) usize {
    const sb = state.refs.term.scrollbar();
    // Fast path: row is inside the viewport — iterate the render
    // state, which we already update once per frame.
    if (target_screen_y >= sb.offset and target_screen_y - sb.offset < sb.len) {
        const view_row: u16 = @intCast(target_screen_y - sb.offset);
        state.refs.term.updateRenderState() catch return 0;
        state.refs.term.beginRowIteration();
        var row_idx: u16 = 0;
        while (state.refs.term.nextRow()) : (row_idx += 1) {
            if (row_idx != view_row) continue;
            state.refs.term.beginCellIteration();
            var col: usize = 0;
            while (state.refs.term.nextCell() and col < out.len) : (col += 1) {
                const info = state.refs.term.getCellInfo();
                out[col] = if (info.has_text) info.codepoint else ' ';
            }
            return col;
        }
        return 0;
    }

    // Slow path: row is in scrollback (above viewport) or the
    // alternate-screen-but-history case (below viewport). Use the
    // grid_ref walker to reach it.
    return state.refs.term.fillRowFromScreen(target_screen_y, out);
}

/// Allocate and fill a UTF-8 buffer with the currently-selected text.
/// Returns null when there's nothing to copy. Caller frees with the
/// same allocator. Walks rows in absolute screen-y space; rows
/// outside the viewport are fetched via the grid_ref walker
/// (terminal.fillRowFromScreen) so copy works across scrollback.
fn extractSelectionText(allocator: std.mem.Allocator) !?[]u8 {
    const snap = state.input.selection.toSnapshot() orelse return null;
    const cols = state.refs.term.colCount();
    const rows = state.refs.term.rowCount();
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

fn debugKillActiveRenderer() void {
    if (state.render.active_render_path == .gpu and state.refs.gpu.active) {
        render_loop.noteGpuUnavailable(state);
        log.info(.input, "debug killed", .{ .target = "gpu" });
    } else if (state.refs.cpu.active) {
        state.refs.cpu.stop();
        log.info(.input, "debug killed", .{ .target = "cpu" });
    }
}

fn debugSwapRenderer() void {
    if (state.render.target_render_path == .gpu) {
        state.render.target_render_path = .cpu;
        state.render.active_render_path = .cpu;
        state.render.needs_redraw = true;
        log.info(.input, "debug target", .{ .renderer = "cpu" });
    } else {
        state.render.target_render_path = .gpu;
        state.render.gpu_snapshot_dirty = true;
        log.info(.input, "debug target", .{ .renderer = "gpu" });
    }
}

fn debugClearAtlas() void {
    // Re-publish the current atlas with a fresh ASCII population. Since
    // ensureText returns null when nothing's missing, we force a snapshot
    // change by allocating a fresh TextAtlas init from scratch using the
    // current atlas's font config bytes.
    render_loop.markRenderDirty(state);
    log.info(.input, "debug atlas clear", .{ .status = "noop" });
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
