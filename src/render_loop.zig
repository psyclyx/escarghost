const std = @import("std");
const app_state = @import("app_state.zig");
const diagnostics = @import("diagnostics.zig");
const render_snapshot = @import("render/render_snapshot.zig");
const gpu_worker = @import("render/gpu_worker.zig");
const log = @import("log.zig");

const SCROLLBAR_HIDE_DELAY_NS: u64 = 1_000 * std.time.ns_per_ms;

pub fn markRenderDirty(s: *app_state.AppState) void {
    s.render.render_serial +%= 1;
    if (s.render.render_serial == 0) s.render.render_serial = 1;
    s.render.needs_redraw = true;
    s.render.gpu_snapshot_dirty = true;
}

pub fn markFirstContentPaint(s: *app_state.AppState) void {
    if (s.lifecycle.first_content_painted or !s.lifecycle.first_pty_data_seen) return;
    s.lifecycle.first_content_painted = true;
}

pub fn bumpScrollbarVisibility(s: *app_state.AppState) void {
    s.input.scrollbar_visible_until_ns = diagnostics.monotonicNowNs() + SCROLLBAR_HIDE_DELAY_NS;
}

/// Compute the scrollbar overlay for this snapshot. Returns null when
/// there's no scrollback or the visibility window has elapsed. The
/// renderer paints the overlay as a thin band on the right edge.
pub fn currentScrollbarOverlay(s: *app_state.AppState) ?render_snapshot.ScrollbarOverlay {
    const sb = s.refs.term.scrollbar();
    if (sb.total == 0 or sb.len == 0 or sb.total <= sb.len) {
        s.input.scrollbar_was_visible = false;
        return null;
    }
    const now = diagnostics.monotonicNowNs();
    if (now >= s.input.scrollbar_visible_until_ns) {
        s.input.scrollbar_was_visible = false;
        return null;
    }
    const total_f: f32 = @floatFromInt(sb.total);
    const offset_f: f32 = @floatFromInt(sb.offset);
    const len_f: f32 = @floatFromInt(sb.len);
    s.input.scrollbar_was_visible = true;
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
/// scrollbar gone. Returns null when the scrollbar is already hidden.
pub fn scrollbarTimeoutMs(s: *app_state.AppState) ?c_int {
    if (!s.input.scrollbar_was_visible) return null;
    const now = diagnostics.monotonicNowNs();
    if (now >= s.input.scrollbar_visible_until_ns) return 0;
    const delta_ns = s.input.scrollbar_visible_until_ns - now;
    const delta_ms = delta_ns / std.time.ns_per_ms + 1;
    return @intCast(@min(delta_ms, @as(u64, std.math.maxInt(c_int))));
}

/// Called once per loop iteration. Marks a redraw if the scrollbar
/// hide timer has elapsed and the previous frame still showed it.
pub fn maybeScheduleScrollbarHide(s: *app_state.AppState) void {
    if (!s.input.scrollbar_was_visible) return;
    if (diagnostics.monotonicNowNs() < s.input.scrollbar_visible_until_ns) return;
    markRenderDirty(s);
}

/// Vsync-gate the GPU render. Without this we'd kick off the render
/// whenever PTY produced fresh data — which lands at arbitrary phase
/// inside the vsync window. If the data arrives 12 ms into a 16.7 ms
/// vsync, our 5–7 ms of work finishes past the latch deadline and the
/// commit slips to the *next* vsync, dropping a frame. Waiting for the
/// frame callback re-bases the render to start at the vsync boundary so
/// the whole budget is available for the work.
pub fn maybeQueueGpuFrame(s: *app_state.AppState) void {
    const gpu = s.refs.gpu;
    const wl = s.refs.wayland;
    if (s.render.target_render_path != .gpu) return;
    if (!gpu.active or !gpu.ready or gpu.render_in_flight or !s.render.gpu_snapshot_dirty) return;
    if (wl.frame_pending) return;
    gpu.queueRender(s.refs.term, s.render.render_serial, s.input.selection.toSnapshot(), currentScrollbarOverlay(s)) catch |err| switch (err) {
        error.NoFreeBuffer => {
            // Track how long we're stuck without a released buffer so
            // we can see at exit whether compositor release latency is
            // the throughput bottleneck.
            if (s.diag.trace_commits or s.debug.warn_slow_budget_ms != null) {
                const now = diagnostics.monotonicNowNs();
                if (s.render.buffer_starvation_start_ns == 0) s.render.buffer_starvation_start_ns = now;
            }
            return;
        },
        error.NotReady, error.Busy, error.NoFreeSnapshot => return,
        else => return,
    };
    if (s.render.buffer_starvation_start_ns != 0) {
        const starvation_ns = diagnostics.monotonicNowNs() - s.render.buffer_starvation_start_ns;
        if (s.diag.trace_commits) {
            gpu_worker.bufferStarvationAccumNs += starvation_ns;
            gpu_worker.bufferStarvationCount += 1;
        }
        if (s.debug.warn_slow_budget_ms) |budget_ms| {
            const budget_ns = @as(u64, budget_ms) * std.time.ns_per_ms;
            if (starvation_ns > budget_ns) {
                log.warn(.frame, "buffer starvation", .{
                    .elapsed_ms = log.fmt("{d:.1}", .{
                        @as(f64, @floatFromInt(starvation_ns)) / @as(f64, std.time.ns_per_ms),
                    }),
                    .budget_ms = budget_ms,
                    .reason = "compositor_holding_dmabuf",
                });
            }
        }
        s.render.buffer_starvation_start_ns = 0;
    }
    log.setFrame(.frame, s.render.render_serial);
    log.info(.frame, "queued gpu frame", .{});
    s.render.gpu_snapshot_dirty = false;
}

pub fn renderActivePath(s: *app_state.AppState) void {
    const gpu = s.refs.gpu;
    const cpu = s.refs.cpu;
    const wl = s.refs.wayland;
    if (s.render.active_render_path != .cpu or !s.render.needs_redraw) return;
    if (s.render.target_render_path == .gpu and gpu.active and gpu.ready) return;
    // Same vsync throttle as the GPU path — wait for the compositor to
    // ack the previous commit before queueing the next one.
    if (wl.frame_pending) return;
    if (cpu.active) {
        const shm = wl.shm orelse return;
        cpu.ensureBuffers(@ptrCast(shm), wl.width, wl.height) catch |err| switch (err) {
            error.Busy => return,
            else => return,
        };
        cpu.queueRender(
            s.refs.term,
            s.metrics.viewport_w,
            s.metrics.viewport_h,
            s.metrics.font_size,
            s.metrics.cell_width,
            s.metrics.cell_height,
            s.render.render_serial,
            s.input.selection.toSnapshot(),
            currentScrollbarOverlay(s),
        ) catch |err| switch (err) {
            error.Busy, error.NoFreeBuffer, error.NoFreeSnapshot, error.Inactive => return,
            else => return,
        };
        s.render.needs_redraw = false;
        log.setFrame(.frame, s.render.render_serial);
        log.info(.frame, "queued cpu frame", .{ .width = wl.width, .height = wl.height });
        return;
    }
    s.render.needs_redraw = false;
}

pub fn noteGpuUnavailable(s: *app_state.AppState) void {
    s.refs.gpu.stop();
    log.warn(.gpu, "unavailable, switching to cpu and scheduling restart", .{});
    if (s.render.active_render_path == .gpu) {
        s.render.active_render_path = .cpu;
        s.render.needs_redraw = true;
    }
    s.render.gpu_restart.scheduleRetry();
}

pub fn combineTimeout(a: c_int, b_opt: ?c_int) c_int {
    const b = b_opt orelse return a;
    if (a < 0) return b;
    return @min(a, b);
}
