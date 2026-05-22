//! Process-wide logger. One line per call, with a consistent prefix
//! across every thread and code path.
//!
//! Line format:
//!     +1234.5ms  Δ12.3ms  [scope]    f#42  message
//!
//! Each column is an independent piece of information:
//!   - process-relative time (always)
//!   - per-scope delta since the previous log in the same scope
//!   - scope tag (per-scope color)
//!   - ambient frame number for the scope (when set)
//!   - message
//!
//! Color is one rendering of these columns; it's disabled when stderr
//! isn't a TTY or NO_COLOR is set, and turning it off doesn't change
//! the data layout.
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

const sgr_reset = "\x1b[0m";
const sgr_dim = "\x1b[90m";
const sgr_bold = "\x1b[1m";
const sgr_yellow = "\x1b[33m";
const sgr_red = "\x1b[31m";
const sgr_frame = "\x1b[96m";

fn scopeColor(s: Scope) []const u8 {
    return switch (s) {
        .main => "\x1b[97m", // bright white
        .gpu => "\x1b[36m", // cyan
        .cpu => "\x1b[32m", // green
        .atlas => "\x1b[35m", // magenta
        .wayland => "\x1b[34m", // blue
        .pty => "\x1b[93m", // bright yellow
        .diag => "\x1b[90m", // gray
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
}

fn eqIgnoreAny(needle: []const u8, options: []const []const u8) bool {
    for (options) |opt| {
        if (std.ascii.eqlIgnoreCase(needle, opt)) return true;
    }
    return false;
}

/// Set the ambient frame number for `scope`. Subsequent log calls in
/// that scope will render `f#N`. Pass `null` to clear.
pub fn setFrame(scope: Scope, frame: ?u64) void {
    scope_state[@intFromEnum(scope)].frame = frame;
}

pub fn info(scope: Scope, comptime fmt: []const u8, args: anytype) void {
    emit(scope, .info, fmt, args);
}

pub fn warn(scope: Scope, comptime fmt: []const u8, args: anytype) void {
    emit(scope, .warn, fmt, args);
}

pub fn err(scope: Scope, comptime fmt: []const u8, args: anytype) void {
    emit(scope, .err, fmt, args);
}

/// Continuation line — same scope context, no prefix, two-space indent.
/// For tabular dumps where a full prefix on every row would dominate.
pub fn cont(comptime fmt: []const u8, args: anytype) void {
    var line: Line = .{};
    line.write("  ");
    line.print(fmt, args);
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

    fn print(self: *Line, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.buf[self.n..], fmt, args) catch return;
        self.n += written.len;
    }

    fn slice(self: *const Line) []const u8 {
        return self.buf[0..self.n];
    }
};

fn emit(scope: Scope, level: Level, comptime fmt: []const u8, args: anytype) void {
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

    // Process-relative time, right-aligned in 10 chars: "+12345.6ms".
    if (color_enabled) line.write(sgr_dim);
    line.print("+{d:>8.1}ms", .{elapsed_ms});
    if (color_enabled) line.write(sgr_reset);
    line.write("  ");

    // Per-scope delta or blank pad (same width as "Δ1234.5ms" = 10 bytes
    // visible — Δ is one display column though it's a multi-byte UTF-8
    // glyph, so blank pad is 9 spaces to align visually).
    if (delta_ns) |d| {
        const delta_ms = @as(f64, @floatFromInt(d)) / ms_div;
        if (color_enabled) line.write(sgr_dim);
        line.print("Δ{d:>6.1}ms", .{delta_ms});
        if (color_enabled) line.write(sgr_reset);
    } else {
        line.write("         ");
    }
    line.write("  ");

    // Scope tag in brackets, padded to fixed width.
    const tag_name = @tagName(scope);
    if (color_enabled) line.write(scopeColor(scope));
    line.print("[{s}]", .{tag_name});
    if (color_enabled) line.write(sgr_reset);
    var pad: usize = tag_width - tag_name.len;
    while (pad > 0) : (pad -= 1) line.write(" ");
    line.write("  ");

    // Ambient frame number for this scope. Pad to "f#NNNN" = 6 bytes.
    if (state.frame) |f| {
        if (color_enabled) line.write(sgr_frame);
        line.print("f#{d:<4}", .{f});
        if (color_enabled) line.write(sgr_reset);
    } else {
        line.write("      ");
    }
    line.write("  ");

    // Level overlay colors the message body, leaves the scope tag alone
    // so scope identity stays visible on warn/err lines.
    switch (level) {
        .info => {},
        .warn => if (color_enabled) line.write(sgr_yellow ++ sgr_bold),
        .err => if (color_enabled) line.write(sgr_red ++ sgr_bold),
    }
    line.print(fmt, args);
    switch (level) {
        .info => {},
        .warn, .err => if (color_enabled) line.write(sgr_reset),
    }
    line.write("\n");

    flush(line.slice());
}

fn flush(bytes: []const u8) void {
    _ = c.pthread_mutex_lock(&write_mutex);
    defer _ = c.pthread_mutex_unlock(&write_mutex);
    _ = c.write(2, bytes.ptr, bytes.len);
}
