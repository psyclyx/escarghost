const std = @import("std");
const log = @import("log.zig");
const c = @cImport({
    @cInclude("time.h");
});

/// Observed vsync period in nanoseconds — written by the wayland frame
/// callback from the inter-callback interval, read by the GPU worker
/// thread when computing the sync-extend budget. Zero until at least
/// two frames have been observed. Single writer (main thread), single
/// reader (gpu worker); relaxed atomic since we tolerate a one-frame
/// lag in the budget calculation.
pub var vsync_period_ns: std.atomic.Value(u64) = .init(0);

/// High-resolution monotonic timer using clock_gettime(CLOCK_MONOTONIC).
/// Avoids std.time overhead and gives ns precision.
pub const Timer = struct {
    start: c.struct_timespec,

    pub fn now() Timer {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return .{ .start = ts };
    }

    pub fn elapsedNs(self: Timer) u64 {
        var end: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &end);
        const total_start: i128 = @as(i128, self.start.tv_sec) * 1_000_000_000 + self.start.tv_nsec;
        const total_end: i128 = @as(i128, end.tv_sec) * 1_000_000_000 + end.tv_nsec;
        return @intCast(total_end - total_start);
    }

    pub fn elapsedUs(self: Timer) f64 {
        return @as(f64, @floatFromInt(self.elapsedNs())) / 1000.0;
    }

    pub fn elapsedMs(self: Timer) f64 {
        return @as(f64, @floatFromInt(self.elapsedNs())) / 1_000_000.0;
    }
};

/// Frame statistics tracker. Ring buffer of frame times.
pub const FrameStats = struct {
    times_us: [256]f64 = [_]f64{0} ** 256,
    idx: u8 = 0,
    count: u32 = 0,
    total_frames: u64 = 0,

    pub fn record(self: *FrameStats, us: f64) void {
        self.times_us[self.idx] = us;
        self.idx +%= 1;
        if (self.count < 256) self.count += 1;
        self.total_frames += 1;
    }

    pub fn avgUs(self: *const FrameStats) f64 {
        if (self.count == 0) return 0;
        var sum: f64 = 0;
        for (0..self.count) |i| sum += self.times_us[i];
        return sum / @as(f64, @floatFromInt(self.count));
    }

    pub fn maxUs(self: *const FrameStats) f64 {
        if (self.count == 0) return 0;
        var m: f64 = 0;
        for (0..self.count) |i| m = @max(m, self.times_us[i]);
        return m;
    }

    pub fn p99Us(self: *const FrameStats) f64 {
        if (self.count == 0) return 0;
        var sorted: [256]f64 = undefined;
        @memcpy(sorted[0..self.count], self.times_us[0..self.count]);
        std.mem.sort(f64, sorted[0..self.count], {}, std.sort.asc(f64));
        const idx = (self.count * 99) / 100;
        return sorted[idx];
    }

    pub fn dump(self: *const FrameStats, label: []const u8) void {
        if (self.count == 0) return;
        log.info(.diag, "stats", .{
            .label = label,
            .avg_us = log.fmt("{d:.1}", .{self.avgUs()}),
            .max_us = log.fmt("{d:.1}", .{self.maxUs()}),
            .p99_us = log.fmt("{d:.1}", .{self.p99Us()}),
            .frames = self.total_frames,
        });
    }
};
