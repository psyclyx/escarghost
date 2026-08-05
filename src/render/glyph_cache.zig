//! CPU-path glyph coverage cache.
//!
//! The software raster (snail-raster) computes a glyph's coverage by evaluating
//! its cubic-lowered quadratic curves per pixel. For the CPU path's full-surface
//! redraw that is O(quads × pixels) EVERY frame, and a screenful of fallback CJK
//! glyphs (cubic-heavy) costs ~85 ms. This memoizes each glyph's coverage as a
//! trimmed 8-bit alpha tile, so steady frames composite tiles (O(pixels))
//! instead of re-evaluating curves.
//!
//! Exactness. Cell origins are snapped to integer device pixels (snail's
//! `.grid` placement), so every instance of a glyph shares the same device
//! position and thus the same analytic coverage — one tile per glyph reproduces
//! the raster bit-for-bit. The only non-integer positions are HarfBuzz
//! intra-cluster offsets (combining marks); the key carries a sub-pixel bucket
//! so those stay exact too. Coverage is colour-independent, so the tile serves
//! any foreground colour; the colour is applied at blit time in linear light —
//! the exact blend the analytic raster does, minus the curve evaluation.
//!
//! This module is pure: it owns storage (the map) and compositing (the blit).
//! Producing a tile needs the raster machinery and lives in `cpu_pipeline`.

const std = @import("std");
const color = @import("color");

/// Sub-pixel buckets per axis for the cache key. Integer-positioned glyphs (the
/// terminal norm, `.grid` placement snaps cell origins to whole device pixels)
/// all fall in bucket 0 and are bit-exact with the analytic raster; fractional
/// offsets (e.g. combining marks, or a fractional cell width) bucket by their
/// offset, exact to within 1/(2·SUBPIXEL) px — sub-perceptual edge AA.
pub const SUBPIXEL: i32 = 16;

pub const Key = struct {
    /// snail `RecordKey` fields (namespace, a, b, c) — identifies the glyph
    /// record (font, id, size). Kept as raw u32s so this module stays
    /// snail-free and the key is collision-free.
    record: [4]u32,
    sub_x: u8,
    sub_y: u8,
};

/// A pen position split into its integer pixel and sub-pixel bucket, quantized
/// consistently: `round(pen · SUBPIXEL)` then divmod, so a pen of X.999 becomes
/// (X+1, 0) rather than (X, wrap) — the inconsistency that shifted glyphs a
/// whole pixel. The tile is rasterized at, and blitted to, this same quantized
/// position, so they always agree.
pub const Pos = struct { int: i32, sub: u8 };

pub fn quantize(pen: f32) Pos {
    const q: i32 = @intFromFloat(@round(pen * @as(f32, @floatFromInt(SUBPIXEL))));
    return .{ .int = @divFloor(q, SUBPIXEL), .sub = @intCast(@mod(q, SUBPIXEL)) };
}

/// A glyph's coverage, trimmed to its ink bbox and positioned by (left, top)
/// device pixels from the pen origin. `fallback = true` marks a glyph that can't
/// be reduced to one coverage (colour/COLR, or ink larger than the scratch
/// tile) — the caller renders it with the analytic raster and never retries.
/// A blank glyph (space) is `w = h = 0, fallback = false`: a cached no-op.
pub const Tile = struct {
    w: u16 = 0,
    h: u16 = 0,
    left: i16 = 0,
    top: i16 = 0,
    cov: []u8 = &.{},
    fallback: bool = false,
};

pub const Cache = struct {
    map: std.AutoHashMapUnmanaged(Key, Tile) = .{},
    gpa: std.mem.Allocator,
    bytes: usize = 0,
    max_bytes: usize,

    pub fn init(gpa: std.mem.Allocator, max_bytes: usize) Cache {
        ensureLuts();
        return .{ .gpa = gpa, .max_bytes = max_bytes };
    }

    pub fn deinit(self: *Cache) void {
        self.reset();
        self.map.deinit(self.gpa);
    }

    /// Free every tile's coverage and empty the map (retaining capacity). Called
    /// when the byte cap would be exceeded — a blunt but rare event: the working
    /// set is a screenful of glyphs, and keys never change meaning (records are
    /// append-only), so there's nothing subtler to do.
    pub fn reset(self: *Cache) void {
        var it = self.map.valueIterator();
        while (it.next()) |t| {
            if (t.cov.len > 0) self.gpa.free(t.cov);
        }
        self.map.clearRetainingCapacity();
        self.bytes = 0;
    }

    pub fn get(self: *const Cache, key: Key) ?Tile {
        return self.map.get(key);
    }

    /// Insert `tile`, copying its coverage into cache-owned memory. On allocation
    /// failure the glyph simply isn't cached (it re-rasters next time) — never a
    /// hard error on the render path.
    pub fn put(self: *Cache, key: Key, tile: Tile) void {
        if (self.bytes + tile.cov.len > self.max_bytes) self.reset();
        var stored = tile;
        if (tile.cov.len > 0) {
            stored.cov = self.gpa.dupe(u8, tile.cov) catch return;
            self.bytes += stored.cov.len;
        }
        self.map.put(self.gpa, key, stored) catch {
            if (stored.cov.len > 0) {
                self.gpa.free(stored.cov);
                self.bytes -= stored.cov.len;
            }
        };
    }
};

// sRGB ↔ linear via LUTs, matching the analytic raster's conversions (same
// standard sRGB formula → same bytes) so the blit is both fast (no per-pixel
// pow) and bit-exact with the raster path.
const L2S_BUCKETS = 4096; // > 1 / min-threshold-gap (≈3.04e-4) ⇒ ≤1 threshold/bucket

var srgb_to_linear: [256]f32 = undefined;
/// Linear value at the rounding boundary between sRGB byte b and b+1.
var l2s_thresholds: [255]f32 = undefined;
/// bucket[i] = number of thresholds ≤ i/BUCKETS (the byte at the bucket's lower
/// edge); `linToByte` adds a single-threshold correction for exactness.
var l2s_bucket: [L2S_BUCKETS]u8 = undefined;
var luts_ready = false;

/// Fill the sRGB LUTs once. Called from `Cache.init` (single-threaded), before
/// any blit. `pow` is expensive at comptime (branch-quota blowups), so the
/// tables are built at runtime instead — a one-time ~microsecond fill.
fn ensureLuts() void {
    if (luts_ready) return;
    for (&srgb_to_linear, 0..) |*e, i| e.* = color.Rgb.srgbToLinearF(@as(f32, @floatFromInt(i)) / 255.0);
    for (&l2s_thresholds, 0..) |*e, b| e.* = color.Rgb.srgbToLinearF((@as(f32, @floatFromInt(b)) + 0.5) / 255.0);
    var b: usize = 0;
    for (&l2s_bucket, 0..) |*e, i| {
        const edge = @as(f32, @floatFromInt(i)) / L2S_BUCKETS;
        while (b < 255 and l2s_thresholds[b] <= edge) b += 1;
        e.* = @intCast(b);
    }
    luts_ready = true;
}

fn linToByte(v: f32) u8 {
    const c = std.math.clamp(v, 0, 1);
    const idx: usize = @min(L2S_BUCKETS - 1, @as(usize, @intFromFloat(c * L2S_BUCKETS)));
    var byte = l2s_bucket[idx];
    if (byte < 255 and c >= l2s_thresholds[byte]) byte += 1; // ≤1 threshold in (edge, c]
    return byte;
}

/// Composite `tile`'s coverage in `fg_linear` (linear-light straight alpha) over
/// the rgba8 sRGB `dst` at integer pen (`pen_x`, `pen_y`), in linear light. This
/// is the same over-blend the analytic raster does — read dst → linear, lerp
/// toward fg by coverage×fg_alpha, store sRGB — minus the curve evaluation. The
/// SHM surface is opaque, so alpha is left at 255.
pub fn blit(
    dst: []u8,
    width: u32,
    height: u32,
    stride: u32,
    tile: Tile,
    pen_x: i32,
    pen_y: i32,
    fg_linear: [4]f32,
) void {
    if (tile.cov.len == 0) return;
    const fr = fg_linear[0];
    const fg = fg_linear[1];
    const fb = fg_linear[2];
    const fa = fg_linear[3];
    var row: u16 = 0;
    while (row < tile.h) : (row += 1) {
        const dy = pen_y + tile.top + @as(i32, row);
        if (dy < 0 or dy >= height) continue;
        const cov_row = tile.cov[@as(usize, row) * tile.w ..][0..tile.w];
        const dst_row = dst[@as(usize, @intCast(dy)) * stride ..];
        var colx: u16 = 0;
        while (colx < tile.w) : (colx += 1) {
            const c = cov_row[colx];
            if (c == 0) continue;
            const dx = pen_x + tile.left + @as(i32, colx);
            if (dx < 0 or dx >= width) continue;
            const a = fa * (@as(f32, @floatFromInt(c)) / 255.0);
            const off = @as(usize, @intCast(dx)) * 4;
            const br = srgb_to_linear[dst_row[off + 0]];
            const bgc = srgb_to_linear[dst_row[off + 1]];
            const bb = srgb_to_linear[dst_row[off + 2]];
            dst_row[off + 0] = linToByte(fr * a + br * (1 - a));
            dst_row[off + 1] = linToByte(fg * a + bgc * (1 - a));
            dst_row[off + 2] = linToByte(fb * a + bb * (1 - a));
            dst_row[off + 3] = 255;
        }
    }
}
