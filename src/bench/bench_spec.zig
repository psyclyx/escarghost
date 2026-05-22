//! Per-terminal launch spec. Shared between every scenario so the
//! "how do I spawn this terminal with a command" knowledge lives in
//! one place. Bin paths come from env vars set by the nix wrapper.
//!
//! wezterm: `--always-new-process` keeps us out of the mux daemon
//! (otherwise `wezterm start` may reuse an existing GUI process and
//! our pid no longer owns the window). `start --class bench-wezterm`
//! sets the wayland app_id so we have a stable string to wait on
//! regardless of nixpkgs' default app_id.

pub const TerminalSpec = struct {
    label: []const u8,
    app_id: []const u8,
    env_var: []const u8,
    /// Tokens that go between <bin> and the command (e.g. "-e" for
    /// foot/alacritty/kitty/scrgo, the `start --` dance for wezterm).
    args_after_bin: []const []const u8,
};

pub const all = [_]TerminalSpec{
    .{ .label = "scrgo", .app_id = "scrgo", .env_var = "SCRGO_BIN", .args_after_bin = &.{"-e"} },
    .{ .label = "foot", .app_id = "foot", .env_var = "FOOT_BIN", .args_after_bin = &.{} },
    .{ .label = "alacritty", .app_id = "Alacritty", .env_var = "ALACRITTY_BIN", .args_after_bin = &.{"-e"} },
    .{ .label = "kitty", .app_id = "kitty", .env_var = "KITTY_BIN", .args_after_bin = &.{"-e"} },
    .{
        .label = "wezterm",
        .app_id = "bench-wezterm",
        .env_var = "WEZTERM_BIN",
        .args_after_bin = &.{ "start", "--always-new-process", "--class", "bench-wezterm", "--" },
    },
};

pub fn findByLabel(label: []const u8) ?TerminalSpec {
    const std = @import("std");
    for (all) |s| if (std.mem.eql(u8, s.label, label)) return s;
    return null;
}

/// Build an argv list ready for posix_spawn / exec. Caller passes
/// scratch buffer big enough to hold bin + args_after_bin + extras.
pub fn buildArgv(buf: [][]const u8, bin: []const u8, spec: TerminalSpec, extras: []const []const u8) []const []const u8 {
    var n: usize = 0;
    buf[n] = bin;
    n += 1;
    for (spec.args_after_bin) |a| {
        buf[n] = a;
        n += 1;
    }
    for (extras) |e| {
        buf[n] = e;
        n += 1;
    }
    return buf[0..n];
}
