const std = @import("std");
const math = std.math;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromHex(hex: []const u8) !Rgb {
        const s = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
        if (s.len != 6) return error.InvalidHexColor;
        return .{
            .r = try std.fmt.parseInt(u8, s[0..2], 16),
            .g = try std.fmt.parseInt(u8, s[2..4], 16),
            .b = try std.fmt.parseInt(u8, s[4..6], 16),
        };
    }

    /// Convert to float4 in sRGB space (for CPU rendering / SHM output).
    pub fn toFloat4(self: Rgb, alpha: f32) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.r)) / 255.0,
            @as(f32, @floatFromInt(self.g)) / 255.0,
            @as(f32, @floatFromInt(self.b)) / 255.0,
            alpha,
        };
    }

    /// Convert to float4 in LINEAR space (for GPU rendering with GL_FRAMEBUFFER_SRGB).
    pub fn toLinearFloat4(self: Rgb, alpha: f32) [4]f32 {
        return .{
            srgbToLinearF(@as(f32, @floatFromInt(self.r)) / 255.0),
            srgbToLinearF(@as(f32, @floatFromInt(self.g)) / 255.0),
            srgbToLinearF(@as(f32, @floatFromInt(self.b)) / 255.0),
            alpha,
        };
    }

    fn srgbToLinearF(v: f32) f32 {
        if (v <= 0.04045) return v / 12.92;
        return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }
};

pub const Lab = struct {
    l: f64,
    a: f64,
    b: f64,
};

// sRGB → linear
fn srgbToLinear(c: f64) f64 {
    if (c <= 0.04045) return c / 12.92;
    return math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

// linear → sRGB
fn linearToSrgb(c: f64) f64 {
    if (c <= 0.0031308) return c * 12.92;
    return 1.055 * math.pow(f64, c, 1.0 / 2.4) - 0.055;
}

// CIE XYZ f(t) helper
fn labF(t: f64) f64 {
    const delta: f64 = 6.0 / 29.0;
    if (t > delta * delta * delta) return math.cbrt(t);
    return t / (3.0 * delta * delta) + 4.0 / 29.0;
}

// CIE XYZ f^-1(t) helper
fn labFInv(t: f64) f64 {
    const delta: f64 = 6.0 / 29.0;
    if (t > delta) return t * t * t;
    return 3.0 * delta * delta * (t - 4.0 / 29.0);
}

// D65 white point
const xn: f64 = 0.950489;
const yn: f64 = 1.0;
const zn: f64 = 1.088840;

pub fn srgbToLab(rgb: Rgb) Lab {
    const r = srgbToLinear(@as(f64, @floatFromInt(rgb.r)) / 255.0);
    const g = srgbToLinear(@as(f64, @floatFromInt(rgb.g)) / 255.0);
    const b = srgbToLinear(@as(f64, @floatFromInt(rgb.b)) / 255.0);

    // sRGB → XYZ (D65)
    const x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b;
    const y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
    const z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b;

    const fx = labF(x / xn);
    const fy = labF(y / yn);
    const fz = labF(z / zn);

    return .{
        .l = 116.0 * fy - 16.0,
        .a = 500.0 * (fx - fy),
        .b = 200.0 * (fy - fz),
    };
}

pub fn labToSrgb(lab: Lab) Rgb {
    const fy = (lab.l + 16.0) / 116.0;
    const fx = lab.a / 500.0 + fy;
    const fz = fy - lab.b / 200.0;

    const x = xn * labFInv(fx);
    const y = yn * labFInv(fy);
    const z = zn * labFInv(fz);

    // XYZ → linear sRGB
    const rl = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    const gl = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    const bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;

    return .{
        .r = clampToByte(linearToSrgb(rl)),
        .g = clampToByte(linearToSrgb(gl)),
        .b = clampToByte(linearToSrgb(bl)),
    };
}

fn clampToByte(v: f64) u8 {
    const clamped = @max(0.0, @min(1.0, v));
    return @intFromFloat(@round(clamped * 255.0));
}

fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

fn lerpLab(a: Lab, b: Lab, t: f64) Lab {
    return .{
        .l = lerp(a.l, b.l, t),
        .a = lerp(a.a, b.a, t),
        .b = lerp(a.b, b.b, t),
    };
}

/// Trilinear interpolation in CIELAB space.
/// corners[0..8] mapped as: [0]=000, [1]=100, [2]=010, [3]=110, [4]=001, [5]=101, [6]=011, [7]=111
pub fn trilinearLab(corners: [8]Lab, u: f64, v: f64, w: f64) Lab {
    // Interpolate along u (red axis)
    const c00 = lerpLab(corners[0], corners[1], u);
    const c10 = lerpLab(corners[2], corners[3], u);
    const c01 = lerpLab(corners[4], corners[5], u);
    const c11 = lerpLab(corners[6], corners[7], u);

    // Interpolate along v (green axis)
    const c0 = lerpLab(c00, c10, v);
    const c1 = lerpLab(c01, c11, v);

    // Interpolate along w (blue axis)
    return lerpLab(c0, c1, w);
}

/// Generate a full 256-color palette from 16 base16 colors.
///
/// - Indices 0-15: copied from base16
/// - Indices 16-231: 6×6×6 color cube via trilinear CIELAB interpolation
///   using the 8 normal ANSI colors (base16 indices 0-7) as cube corners
/// - Indices 232-255: 24-step grayscale ramp between base00 and base05
pub fn generatePalette(base16: [16]Rgb) [256]Rgb {
    var palette: [256]Rgb = undefined;

    // Copy base16 colors
    for (0..16) |i| {
        palette[i] = base16[i];
    }

    // Build CIELAB corners from the 8 ANSI colors (base16[0..8]).
    // Mapping: black=0, red=1, green=2, yellow=3, blue=4, magenta=5, cyan=6, white=7
    // Cube corners: (r,g,b) → index mapping:
    //   (0,0,0)=black, (1,0,0)=red, (0,1,0)=green, (1,1,0)=yellow,
    //   (0,0,1)=blue, (1,0,1)=magenta, (0,1,1)=cyan, (1,1,1)=white
    const corner_indices = [8]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var corners: [8]Lab = undefined;
    for (corner_indices, 0..) |ci, i| {
        corners[i] = srgbToLab(base16[ci]);
    }

    // Generate 6×6×6 cube (indices 16-231)
    for (0..216) |i| {
        const ri = i / 36;
        const gi = (i / 6) % 6;
        const bi = i % 6;

        const u: f64 = @as(f64, @floatFromInt(ri)) / 5.0;
        const v: f64 = @as(f64, @floatFromInt(gi)) / 5.0;
        const w: f64 = @as(f64, @floatFromInt(bi)) / 5.0;

        palette[16 + i] = labToSrgb(trilinearLab(corners, u, v, w));
    }

    // Generate grayscale ramp (indices 232-255)
    // Interpolate between base00 (background/dark) and base05 (light foreground)
    const gray_dark = srgbToLab(base16[0]);
    const gray_light = srgbToLab(base16[5]);
    for (0..24) |i| {
        const t: f64 = (@as(f64, @floatFromInt(i)) + 1.0) / 25.0;
        palette[232 + i] = labToSrgb(lerpLab(gray_dark, gray_light, t));
    }

    return palette;
}

// ── Tests ──

test "srgb round-trip through CIELAB" {
    const colors = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
        .{ .r = 128, .g = 64, .b = 192 },
    };
    for (colors) |c| {
        const lab = srgbToLab(c);
        const back = labToSrgb(lab);
        try std.testing.expectEqual(c.r, back.r);
        try std.testing.expectEqual(c.g, back.g);
        try std.testing.expectEqual(c.b, back.b);
    }
}

test "fromHex" {
    const c = try Rgb.fromHex("#1d1f21");
    try std.testing.expectEqual(@as(u8, 0x1d), c.r);
    try std.testing.expectEqual(@as(u8, 0x1f), c.g);
    try std.testing.expectEqual(@as(u8, 0x21), c.b);

    const c2 = try Rgb.fromHex("ff8800");
    try std.testing.expectEqual(@as(u8, 0xff), c2.r);
    try std.testing.expectEqual(@as(u8, 0x88), c2.g);
    try std.testing.expectEqual(@as(u8, 0x00), c2.b);
}

test "generatePalette preserves base16" {
    var base16: [16]Rgb = undefined;
    for (0..16) |i| {
        base16[i] = .{
            .r = @intCast(i * 16),
            .g = @intCast(i * 8),
            .b = @intCast(i * 4),
        };
    }
    const palette = generatePalette(base16);
    for (0..16) |i| {
        try std.testing.expectEqual(base16[i].r, palette[i].r);
        try std.testing.expectEqual(base16[i].g, palette[i].g);
        try std.testing.expectEqual(base16[i].b, palette[i].b);
    }
}

test "generatePalette cube corners match ANSI colors" {
    // With this palette, the cube corners at (0,0,0), (5,0,0), etc. should
    // round-trip back to the original ANSI colors
    var base16: [16]Rgb = undefined;
    base16[0] = .{ .r = 30, .g = 30, .b = 30 }; // black
    base16[1] = .{ .r = 200, .g = 50, .b = 50 }; // red
    base16[2] = .{ .r = 50, .g = 200, .b = 50 }; // green
    base16[3] = .{ .r = 200, .g = 200, .b = 50 }; // yellow
    base16[4] = .{ .r = 50, .g = 50, .b = 200 }; // blue
    base16[5] = .{ .r = 200, .g = 50, .b = 200 }; // magenta
    base16[6] = .{ .r = 50, .g = 200, .b = 200 }; // cyan
    base16[7] = .{ .r = 220, .g = 220, .b = 220 }; // white
    for (8..16) |i| base16[i] = base16[i - 8];

    const palette = generatePalette(base16);

    // Index 16 = (0,0,0) = black
    try std.testing.expectEqual(base16[0].r, palette[16].r);
    try std.testing.expectEqual(base16[0].g, palette[16].g);
    // Index 231 = (5,5,5) = white
    try std.testing.expectEqual(base16[7].r, palette[231].r);
    try std.testing.expectEqual(base16[7].g, palette[231].g);
}
