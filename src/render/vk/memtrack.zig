//! Lightweight VkDeviceMemory / command-buffer allocation counters for
//! leak hunting. Each Vulkan alloc/free site bumps a category counter; the
//! diagnostics exit report and the periodic RSS sample print `outstanding`
//! (allocs − frees) and `live_bytes` per category. A category whose
//! outstanding count climbs without bound is the leak. Atomic + process-
//! global because allocs happen on the GPU worker thread and the report is
//! read on the main thread.

const std = @import("std");

pub const Counter = struct {
    allocs: std.atomic.Value(u64) = .init(0),
    frees: std.atomic.Value(u64) = .init(0),
    live_bytes: std.atomic.Value(u64) = .init(0),

    pub fn onAlloc(self: *Counter, bytes: usize) void {
        _ = self.allocs.fetchAdd(1, .monotonic);
        _ = self.live_bytes.fetchAdd(bytes, .monotonic);
    }

    pub fn onFree(self: *Counter, bytes: usize) void {
        _ = self.frees.fetchAdd(1, .monotonic);
        _ = self.live_bytes.fetchSub(bytes, .monotonic);
    }

    pub fn outstanding(self: *const Counter) u64 {
        return self.allocs.load(.monotonic) -% self.frees.load(.monotonic);
    }

    pub fn liveMib(self: *const Counter) u64 {
        return self.live_bytes.load(.monotonic) / (1024 * 1024);
    }
};

/// Per-upload host-visible staging buffer (device_atlas). Prime per-frame suspect.
pub var staging: Counter = .{};
/// Fixed atlas textures (curve/band/layer_info/image array) — one-time.
pub var atlas_image: Counter = .{};
/// Renderer vertex/index rings (host-visible) — grow-only.
pub var host_buffer: Counter = .{};
/// dmabuf render targets.
pub var dmabuf_mem: Counter = .{};
/// Command buffers (count only; bytes unknown). Allocated per submit.
pub var cmd_bufs: Counter = .{};
