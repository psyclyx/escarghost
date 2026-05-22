//! Process-wide logger. One line per call, with a consistent prefix
//! across every thread and code path.
//!
//! Line shape:
//!     +1234.5ms  [scope]   Δ12.3ms  f#42  message  k=v  k=v
//!
//! - `+ms`:        monotonic time since process_start.
//! - `[scope]`:    per-scope color; padded to fixed width.
//! - `Δms`:        time since the previous log in the same scope, in the
//!                 scope color so it visually clusters with the tag.
//! - `f#N`:        ambient frame # for the scope; six spaces when unset.
//! - `message`:    free-form text body.
//! - `k=v`:        structured data, taken from a struct literal at the
//!                 call site. Field names are pulled out at comptime; the
//!                 value is rendered + colored based on its Zig type.
//!                 `log.fmt("{d:.1}", .{x})` wraps a value that needs a
//!                 custom format spec.
//!
//! Scope filtering: `SCRGO_LOG=<scope>[,<scope>]*` enables those scopes.
//! Token names match the `Scope` enum names exactly (`gpu`, `cpu`,
//! `frame`, ...). `all` / `1` / `on` enables every scope; `0` / `off`
//! disables all. Only `info`-level messages are gated; `warn` and `err`
//! always emit.
//!
//! `init()` must run once near the top of `main` so process-start is
//! stamped before anything logs.

const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("pthread.h");
});

pub const Scope = enum {
    main,
    gpu,
    cpu,
    atlas,
    wayland,
    pty,
    diag,
    input,
    frame,
};

pub const Level = enum { info, warn, err };

const tag_width: usize = blk: {
    var w: usize = 0;
    for (std.meta.fields(Scope)) |f| if (f.name.len > w) {
        w = f.name.len;
    };
    break :blk w;
};

const ScopeState = struct {
    last_log_ns: u64 = 0,
    frame: ?u64 = null,
};

var process_start_ns: u64 = 0;
var color_enabled: bool = false;
var initialized: bool = false;
var write_mutex: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t);
var scope_state: [std.meta.fields(Scope).len]ScopeState =
    [_]ScopeState{.{}} ** std.meta.fields(Scope).len;
var scope_enabled: [std.meta.fields(Scope).len]bool =
    [_]bool{false} ** std.meta.fields(Scope).len;

const sgr_reset = "\x1b[0m";
const sgr_bold = "\x1b[1m";
const sgr_yellow = "\x1b[33m";
const sgr_red = "\x1b[31m";

// Value-type colors (used for the `value` half of `key=value` pairs).
const sgr_val_num = "\x1b[96m"; // bright cyan
const sgr_val_bool = "\x1b[93m"; // bright yellow
const sgr_val_str = "\x1b[92m"; // bright green
const sgr_val_enum = "\x1b[95m"; // bright magenta
const sgr_val_err = "\x1b[91m"; // bright red
const sgr_val_null = "\x1b[90m"; // gray (only place we use gray; it's
// explicitly "value is absent")

fn scopeColor(s: Scope) []const u8 {
    return switch (s) {
        .main => "\x1b[97m", // bright white
        .gpu => "\x1b[36m", // cyan
        .cpu => "\x1b[32m", // green
        .atlas => "\x1b[35m", // magenta
        .wayland => "\x1b[34m", // blue
        .pty => "\x1b[93m", // bright yellow
        .diag => "\x1b[33m", // yellow
        .input => "\x1b[95m", // bright magenta
        .frame => "\x1b[94m", // bright blue
    };
}

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.tv_nsec));
}

pub fn init() void {
    process_start_ns = nowNs();
    _ = c.pthread_mutex_init(&write_mutex, null);
    initialized = true;
    color_enabled = c.isatty(2) != 0;
    if (c.getenv("NO_COLOR") != null) color_enabled = false;
    if (c.getenv("FORCE_COLOR") != null) color_enabled = true;
    if (c.getenv("SCRGO_LOG_COLOR")) |v| {
        const s = std.mem.sliceTo(v, 0);
        if (eqIgnoreAny(s, &.{ "0", "off", "false", "never" })) {
            color_enabled = false;
        } else if (eqIgnoreAny(s, &.{ "1", "on", "true", "always", "force" })) {
            color_enabled = true;
        }
    }
    if (c.getenv("SCRGO_LOG")) |v| {
        parseScopeTokens(std.mem.sliceTo(v, 0));
    }
}

fn parseScopeTokens(value: []const u8) void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return;
    if (eqIgnoreAny(trimmed, &.{ "0", "off", "false" })) return;
    if (eqIgnoreAny(trimmed, &.{ "1", "on", "true", "all" })) {
        for (&scope_enabled) |*e| e.* = true;
        return;
    }
    var it = std.mem.tokenizeAny(u8, trimmed, ", ");
    while (it.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "all")) {
            for (&scope_enabled) |*e| e.* = true;
            continue;
        }
        inline for (std.meta.fields(Scope)) |f| {
            if (std.ascii.eqlIgnoreCase(token, f.name)) {
                scope_enabled[f.value] = true;
            }
        }
    }
}

fn eqIgnoreAny(needle: []const u8, options: []const []const u8) bool {
    for (options) |opt| {
        if (std.ascii.eqlIgnoreCase(needle, opt)) return true;
    }
    return false;
}

pub fn isScopeEnabled(scope: Scope) bool {
    return scope_enabled[@intFromEnum(scope)];
}

/// Set the ambient frame number for `scope`. Subsequent log calls in
/// that scope will render `f#N`. Pass `null` to clear.
pub fn setFrame(scope: Scope, frame: ?u64) void {
    scope_state[@intFromEnum(scope)].frame = frame;
}

/// Pre-formatted value wrapper. Use when the default type-based
/// rendering picks the wrong precision/specifier:
///
///     log.info(.gpu, "frame", .{ .ms = log.fmt("{d:.1}", .{x}) });
///
/// The bytes are stored inline (no allocation) so the wrapper is safe to
/// pass through anonymous struct literals.
pub const Fmt = struct {
    buf: [64]u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const Fmt) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn fmt(comptime format: []const u8, args: anytype) Fmt {
    var f: Fmt = .{};
    if (std.fmt.bufPrint(&f.buf, format, args)) |written| {
        f.len = @intCast(written.len);
    } else |_| {
        f.len = 0;
    }
    return f;
}

pub fn info(scope: Scope, comptime msg: []const u8, data: anytype) void {
    if (!scope_enabled[@intFromEnum(scope)]) return;
    emit(scope, .info, msg, data);
}

pub fn warn(scope: Scope, comptime msg: []const u8, data: anytype) void {
    emit(scope, .warn, msg, data);
}

pub fn err(scope: Scope, comptime msg: []const u8, data: anytype) void {
    emit(scope, .err, msg, data);
}

/// Continuation row — no prefix, two-space indent. Used by the
/// commit-trace dump where a full prefix on every row would dominate.
pub fn cont(comptime msg: []const u8, data: anytype) void {
    var line: Line = .{};
    line.write("  ");
    line.write(msg);
    const fields = @typeInfo(@TypeOf(data)).@"struct".fields;
    if (fields.len != 0) {
        if (msg.len != 0) line.write("  ");
        writeData(&line, data);
    }
    line.write("\n");
    flush(line.slice());
}

const Line = struct {
    buf: [4096]u8 = undefined,
    n: usize = 0,

    fn write(self: *Line, bytes: []const u8) void {
        const remaining = self.buf.len - self.n;
        const k = @min(bytes.len, remaining);
        @memcpy(self.buf[self.n .. self.n + k], bytes[0..k]);
        self.n += k;
    }

    fn print(self: *Line, comptime format: []const u8, args: anytype) void {
        if (std.fmt.bufPrint(self.buf[self.n..], format, args)) |written| {
            self.n += written.len;
        } else |_| {}
    }

    fn sgr(self: *Line, code: []const u8) void {
        if (color_enabled) self.write(code);
    }

    fn slice(self: *const Line) []const u8 {
        return self.buf[0..self.n];
    }
};

fn scopeTagBlock(comptime scope: Scope) []const u8 {
    return comptime "[" ++ @tagName(scope) ++ "]" ++
        (" " ** (tag_width - @tagName(scope).len));
}

fn scopeTagBlockRuntime(scope: Scope) []const u8 {
    return switch (scope) {
        inline else => |s| comptime scopeTagBlock(s),
    };
}

fn emit(scope: Scope, level: Level, comptime msg: []const u8, data: anytype) void {
    const ns = nowNs();
    const state = &scope_state[@intFromEnum(scope)];
    const start = if (initialized) process_start_ns else ns;
    const elapsed_ns = ns -% start;
    const delta_ns: ?u64 = if (state.last_log_ns == 0)
        null
    else
        ns -% state.last_log_ns;
    state.last_log_ns = ns;

    const ms_div: f64 = @floatFromInt(@as(u64, std.time.ns_per_ms));
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / ms_div;

    var line: Line = .{};

    // Time block: "+12345.6ms" (11 chars). Default color — counts matter,
    // but they shouldn't be the visual center of the line.
    line.print("+{d:>8.1}ms", .{elapsed_ms});
    line.write("  ");

    // Scope tag + delta share the scope color so they read as one block.
    line.sgr(scopeColor(scope));
    line.write(scopeTagBlockRuntime(scope));
    line.write(" ");
    if (delta_ns) |d| {
        const delta_ms = @as(f64, @floatFromInt(d)) / ms_div;
        line.print("Δ{d:>6.1}ms", .{delta_ms});
    } else {
        line.write("         "); // 9 visual cols, matches "Δ123.4ms"
    }
    line.sgr(sgr_reset);
    line.write("  ");

    // Frame block: "f#NNNN" (6 chars), or 6 spaces if unset.
    if (state.frame) |f| {
        line.print("f#{d:<4}", .{f});
    } else {
        line.write("      ");
    }
    line.write("  ");

    // Message body. Warn/err overlay colors the body only, so the scope
    // tag stays identifiable on noisy lines.
    switch (level) {
        .info => {},
        .warn => line.sgr(sgr_yellow ++ sgr_bold),
        .err => line.sgr(sgr_red ++ sgr_bold),
    }
    line.write(msg);
    switch (level) {
        .info => {},
        .warn, .err => line.sgr(sgr_reset),
    }

    const fields = @typeInfo(@TypeOf(data)).@"struct".fields;
    if (fields.len != 0) {
        if (msg.len != 0) line.write("  ");
        writeData(&line, data);
    }

    line.write("\n");
    flush(line.slice());
}

fn writeData(line: *Line, data: anytype) void {
    const T = @TypeOf(data);
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        if (i != 0) line.write("  ");
        line.write(field.name);
        line.write("=");
        writeValue(line, @field(data, field.name));
    }
}

fn writeValue(line: *Line, value: anytype) void {
    const T = @TypeOf(value);

    if (T == Fmt) {
        line.sgr(sgr_val_num);
        line.write(value.slice());
        line.sgr(sgr_reset);
        return;
    }

    const ti = @typeInfo(T);
    switch (ti) {
        .bool => {
            line.sgr(sgr_val_bool);
            line.print("{}", .{value});
            line.sgr(sgr_reset);
        },
        .int, .comptime_int => {
            line.sgr(sgr_val_num);
            line.print("{}", .{value});
            line.sgr(sgr_reset);
        },
        .float, .comptime_float => {
            line.sgr(sgr_val_num);
            line.print("{d:.2}", .{value});
            line.sgr(sgr_reset);
        },
        .@"enum" => {
            line.sgr(sgr_val_enum);
            line.write(@tagName(value));
            line.sgr(sgr_reset);
        },
        .error_set => {
            line.sgr(sgr_val_err);
            line.write(@errorName(value));
            line.sgr(sgr_reset);
        },
        .optional => {
            if (value) |v| writeValue(line, v) else {
                line.sgr(sgr_val_null);
                line.write("null");
                line.sgr(sgr_reset);
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    line.sgr(sgr_val_str);
                    line.write(value);
                    line.sgr(sgr_reset);
                } else {
                    line.print("{any}", .{value});
                }
            },
            .one => {
                const child_ti = @typeInfo(p.child);
                if (child_ti == .array and child_ti.array.child == u8) {
                    line.sgr(sgr_val_str);
                    line.print("{s}", .{value});
                    line.sgr(sgr_reset);
                } else {
                    line.print("{*}", .{value});
                }
            },
            else => line.print("{any}", .{value}),
        },
        else => line.print("{any}", .{value}),
    }
}

fn flush(bytes: []const u8) void {
    _ = c.pthread_mutex_lock(&write_mutex);
    defer _ = c.pthread_mutex_unlock(&write_mutex);
    _ = c.write(2, bytes.ptr, bytes.len);
}
