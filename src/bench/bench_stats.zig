//! Common sample-summary helpers used across scenarios.

const std = @import("std");

pub const Stats = struct {
    mean: f64 = 0,
    median: f64 = 0,
    p99: f64 = 0,
    max: f64 = 0,
    min: f64 = 0,
    n: usize = 0,
    dropped: usize = 0,
};

pub fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const idx_f = p * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(idx_f));
    const hi: usize = @intFromFloat(@ceil(idx_f));
    if (lo == hi) return sorted[lo];
    const t = idx_f - @as(f64, @floatFromInt(lo));
    return sorted[lo] * (1 - t) + sorted[hi] * t;
}

pub fn summarize(buf: []f64, dropped: usize) Stats {
    if (buf.len == 0) return .{ .dropped = dropped };
    std.mem.sort(f64, buf, {}, comptime std.sort.asc(f64));
    var sum: f64 = 0;
    for (buf) |v| sum += v;
    return .{
        .mean = sum / @as(f64, @floatFromInt(buf.len)),
        .median = percentile(buf, 0.5),
        .p99 = percentile(buf, 0.99),
        .max = buf[buf.len - 1],
        .min = buf[0],
        .n = buf.len,
        .dropped = dropped,
    };
}
