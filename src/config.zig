const std = @import("std");
const color = @import("color.zig");
const Rgb = color.Rgb;

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

pub const Config = struct {
    font_path: []const u8,
    font_size: f32,
    cols: u16,
    rows: u16,
    max_scrollback: usize,
    shell: []const u8,
    generate_256: bool,
    foreground: Rgb,
    background: Rgb,
    cursor_color: ?Rgb,
    base16: [16]Rgb,
    palette: [256]Rgb,

    // Key repeat (0 = use compositor default)
    repeat_rate: u32 = 0, // keys per second
    repeat_delay: u32 = 0, // ms before repeat starts

    // Scroll
    scroll_lines: u32 = 3, // lines per scroll event

    // Track ownership of heap-allocated strings
    owns_font_path: bool = false,
    owns_shell: bool = false,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.owns_font_path) allocator.free(self.font_path);
        if (self.owns_shell) allocator.free(self.shell);
    }
};

const fallback_shell = "/bin/sh";

// Tomorrow Night base16
const defaults = Config{
    .font_path = "",
    .font_size = 14.0,
    .cols = 80,
    .rows = 24,
    .max_scrollback = 10000,
    .shell = fallback_shell,
    .generate_256 = true,
    .background = .{ .r = 0x1d, .g = 0x1f, .b = 0x21 }, // base00
    .foreground = .{ .r = 0xc5, .g = 0xc8, .b = 0xc6 }, // base05
    .cursor_color = null,
    .base16 = .{
        .{ .r = 0x1d, .g = 0x1f, .b = 0x21 }, // base00
        .{ .r = 0x28, .g = 0x2a, .b = 0x2e }, // base01
        .{ .r = 0x37, .g = 0x3b, .b = 0x41 }, // base02
        .{ .r = 0x96, .g = 0x98, .b = 0x96 }, // base03
        .{ .r = 0xb4, .g = 0xb7, .b = 0xb4 }, // base04
        .{ .r = 0xc5, .g = 0xc8, .b = 0xc6 }, // base05
        .{ .r = 0xe0, .g = 0xe0, .b = 0xe0 }, // base06
        .{ .r = 0xff, .g = 0xff, .b = 0xff }, // base07
        .{ .r = 0xcc, .g = 0x66, .b = 0x66 }, // base08 (red)
        .{ .r = 0xde, .g = 0x93, .b = 0x5f }, // base09 (orange)
        .{ .r = 0xf0, .g = 0xc6, .b = 0x74 }, // base0A (yellow)
        .{ .r = 0xb5, .g = 0xbd, .b = 0x68 }, // base0B (green)
        .{ .r = 0x8a, .g = 0xbe, .b = 0xb7 }, // base0C (cyan)
        .{ .r = 0x81, .g = 0xa2, .b = 0xbe }, // base0D (blue)
        .{ .r = 0xb2, .g = 0x94, .b = 0xbb }, // base0E (purple)
        .{ .r = 0xa3, .g = 0x68, .b = 0x5a }, // base0F (brown)
    },
    .palette = undefined,
};

const base16_keys = [16][]const u8{
    "base00", "base01", "base02", "base03",
    "base04", "base05", "base06", "base07",
    "base08", "base09", "base0A", "base0B",
    "base0C", "base0D", "base0E", "base0F",
};

pub fn load(allocator: std.mem.Allocator) !Config {
    var cfg = defaults;
    cfg.shell = getenv("SHELL") orelse fallback_shell;

    const config_path = try getConfigPath(allocator);
    defer if (config_path) |p| allocator.free(p);

    if (config_path) |path| {
        const data = readFile(allocator, path) catch |err| switch (err) {
            error.FileNotFound => {
                finalizePalette(&cfg);
                return cfg;
            },
            else => return err,
        };
        defer allocator.free(data);

        try parseJson(allocator, data, &cfg);
    }

    finalizePalette(&cfg);
    return cfg;
}

fn finalizePalette(cfg: *Config) void {
    // Build the ANSI-mapped base16 for palette generation.
    // The standard terminal palette maps:
    //   0=black(base00), 1=red(base08), 2=green(base0B), 3=yellow(base0A),
    //   4=blue(base0D), 5=magenta(base0E), 6=cyan(base0C), 7=white(base05),
    //   8-15=bright variants (base01..base07 for grays, bright versions of colors)
    var ansi_mapped: [16]Rgb = undefined;
    ansi_mapped[0] = cfg.base16[0]; // black = base00
    ansi_mapped[1] = cfg.base16[8]; // red = base08
    ansi_mapped[2] = cfg.base16[11]; // green = base0B
    ansi_mapped[3] = cfg.base16[10]; // yellow = base0A
    ansi_mapped[4] = cfg.base16[13]; // blue = base0D
    ansi_mapped[5] = cfg.base16[14]; // magenta = base0E
    ansi_mapped[6] = cfg.base16[12]; // cyan = base0C
    ansi_mapped[7] = cfg.base16[5]; // white = base05
    // Bright variants
    ansi_mapped[8] = cfg.base16[3]; // bright black = base03
    ansi_mapped[9] = cfg.base16[8]; // bright red (same, will be fine)
    ansi_mapped[10] = cfg.base16[11]; // bright green
    ansi_mapped[11] = cfg.base16[10]; // bright yellow
    ansi_mapped[12] = cfg.base16[13]; // bright blue
    ansi_mapped[13] = cfg.base16[14]; // bright magenta
    ansi_mapped[14] = cfg.base16[12]; // bright cyan
    ansi_mapped[15] = cfg.base16[7]; // bright white = base07

    if (cfg.generate_256) {
        cfg.palette = color.generatePalette(ansi_mapped);
    } else {
        // Use the standard xterm 256-color palette for indices 16-255
        // but still set 0-15 from our theme
        for (0..16) |i| cfg.palette[i] = ansi_mapped[i];
        fillStandardExtended(&cfg.palette);
    }
}

fn fillStandardExtended(palette: *[256]Rgb) void {
    // Standard 6×6×6 cube
    for (0..216) |i| {
        const ri = i / 36;
        const gi = (i / 6) % 6;
        const bi = i % 6;
        palette[16 + i] = .{
            .r = if (ri == 0) 0 else @intCast(55 + ri * 40),
            .g = if (gi == 0) 0 else @intCast(55 + gi * 40),
            .b = if (bi == 0) 0 else @intCast(55 + bi * 40),
        };
    }
    // Standard grayscale ramp
    for (0..24) |i| {
        const v: u8 = @intCast(8 + i * 10);
        palette[232 + i] = .{ .r = v, .g = v, .b = v };
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fp = c.fopen(path_z.ptr, "rb") orelse {
        // Check errno for ENOENT
        const errno = std.c._errno().*;
        if (errno == @intFromEnum(std.posix.E.NOENT)) return error.FileNotFound;
        return error.OpenFailed;
    };
    defer _ = c.fclose(fp);

    _ = c.fseek(fp, 0, c.SEEK_END);
    const size_raw = c.ftell(fp);
    if (size_raw < 0) return error.ReadFailed;
    const size: usize = @intCast(size_raw);
    _ = c.fseek(fp, 0, c.SEEK_SET);

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    const read = c.fread(buf.ptr, 1, size, fp);
    if (read != size) return error.ReadFailed;

    return buf;
}

fn getConfigPath(allocator: std.mem.Allocator) !?[]const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return try std.fmt.allocPrint(allocator, "{s}/mollusk/config.json", .{xdg});
    }
    if (getenv("HOME")) |home| {
        return try std.fmt.allocPrint(allocator, "{s}/.config/mollusk/config.json", .{home});
    }
    return null;
}

fn parseJson(allocator: std.mem.Allocator, data: []const u8, cfg: *Config) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;
    const obj = root.object;

    if (obj.get("font")) |v| {
        if (v == .string) {
            cfg.font_path = try allocator.dupe(u8, v.string);
            cfg.owns_font_path = true;
        }
    }

    if (obj.get("font_size")) |v| {
        if (v == .float) cfg.font_size = @floatCast(v.float);
        if (v == .integer) cfg.font_size = @floatFromInt(v.integer);
    }

    if (obj.get("cols")) |v| {
        if (v == .integer and v.integer > 0) cfg.cols = @intCast(v.integer);
    }

    if (obj.get("rows")) |v| {
        if (v == .integer and v.integer > 0) cfg.rows = @intCast(v.integer);
    }

    if (obj.get("max_scrollback")) |v| {
        if (v == .integer and v.integer >= 0) cfg.max_scrollback = @intCast(v.integer);
    }

    if (obj.get("shell")) |v| {
        if (v == .string) {
            cfg.shell = try allocator.dupe(u8, v.string);
            cfg.owns_shell = true;
        }
    }

    if (obj.get("generate_256_from_base16")) |v| {
        if (v == .bool) cfg.generate_256 = v.bool;
    }

    if (obj.get("colors")) |colors_val| {
        if (colors_val == .object) {
            const colors_obj = colors_val.object;
            for (base16_keys, 0..) |key, i| {
                if (colors_obj.get(key)) |v| {
                    if (v == .string) {
                        cfg.base16[i] = Rgb.fromHex(v.string) catch cfg.base16[i];
                    }
                }
            }
        }
    }

    // Foreground/background override from base16 or explicit
    if (obj.get("foreground")) |v| {
        if (v == .string) cfg.foreground = Rgb.fromHex(v.string) catch cfg.foreground;
    } else {
        cfg.foreground = cfg.base16[5]; // base05
    }

    if (obj.get("background")) |v| {
        if (v == .string) cfg.background = Rgb.fromHex(v.string) catch cfg.background;
    } else {
        cfg.background = cfg.base16[0]; // base00
    }

    if (obj.get("cursor_color")) |v| {
        if (v == .string) cfg.cursor_color = Rgb.fromHex(v.string) catch null;
    }
}

// ── Tests ──

test "defaults load without config file" {
    var cfg = try load(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 80), cfg.cols);
    try std.testing.expectEqual(@as(u16, 24), cfg.rows);
    try std.testing.expectEqual(@as(f32, 14.0), cfg.font_size);
    // Palette index 0 should be ANSI black (base00 mapped)
    try std.testing.expectEqual(cfg.base16[0].r, cfg.palette[0].r);
}

test "parseJson basic" {
    const json =
        \\{"font_size": 16.0, "cols": 120, "rows": 40, "generate_256_from_base16": false}
    ;
    var cfg = defaults;
    try parseJson(std.testing.allocator, json, &cfg);
    try std.testing.expectEqual(@as(f32, 16.0), cfg.font_size);
    try std.testing.expectEqual(@as(u16, 120), cfg.cols);
    try std.testing.expectEqual(@as(u16, 40), cfg.rows);
    try std.testing.expectEqual(false, cfg.generate_256);
}

test "parseJson colors" {
    const json =
        \\{"colors": {"base00": "#000000", "base07": "#ffffff"}}
    ;
    var cfg = defaults;
    try parseJson(std.testing.allocator, json, &cfg);
    try std.testing.expectEqual(@as(u8, 0), cfg.base16[0].r);
    try std.testing.expectEqual(@as(u8, 255), cfg.base16[7].r);
}
