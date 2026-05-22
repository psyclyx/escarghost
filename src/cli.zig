//! Command-line argument parsing.
//!
//! Options are declared once in `option_specs` (and `verbosity_help` for
//! the `-v` ladder). The usage text and shell completions are *generated*
//! from those declarations — no hand-written duplicate to drift.
//!
//! Long options accept `--name value` and `--name=value`; short options
//! accept `-x value` and `-xvalue`. Everything after `--` is treated as
//! positional arguments for whatever `-e` selected. Unknown args trigger
//! `printUsage(2)` + exit(2), matching getopt-style tools.

const std = @import("std");
const log = @import("log.zig");

const c = @cImport({
    @cInclude("unistd.h");
});

pub const version_string = "scrgo 0.0.1";

/// Mirror of `render_env.RequestedRenderPath`. Defined here to keep
/// `cli.zig` free of the snail/render dependency chain, so the CLI's
/// tests can run in the headless test build. Converted at the call
/// site in main.zig.
pub const Renderer = enum { auto, cpu, gpu };

pub const Args = struct {
    /// Path to a config file. `null` means "use the default lookup
    /// (XDG_CONFIG_HOME / HOME)".
    config_path: ?[]const u8 = null,
    /// argv[0] of the command launched into the PTY. `null` means
    /// "use the configured / $SHELL shell".
    exec_program: ?[]const u8 = null,
    /// argv tail for the exec'd command. Empty when no `--` was passed.
    /// Pointed-into argv strings: do not free.
    exec_args: []const []const u8 = &.{},
    /// Renderer preference. `null` means "leave to env / auto".
    renderer: ?Renderer = null,
    /// Number of `-v` levels accumulated. Mapped to log scopes by
    /// `applyVerbosity`.
    verbosity: u2 = 0,
    /// When set, the caller should write the requested completion
    /// script to stdout and exit instead of starting the terminal.
    generate_completion: ?CompletionShell = null,
};

pub const CompletionShell = enum { bash, zsh, fish };

pub const ParseError = error{
    HelpRequested,
    VersionRequested,
    BadArgs,
};

/// Completion shape for a single option's value. Drives both the
/// generated bash/zsh/fish scripts and (eventually) any in-process
/// validation.
pub const Completion = union(enum) {
    /// No completion (flag, or a free-form string we can't constrain).
    none,
    /// Filesystem path.
    file,
    /// An executable name (looked up via $PATH).
    command,
    /// A fixed set of choices.
    values: []const []const u8,
};

/// One declarative entry per CLI option. The parser and the generators
/// both read from this list. Order is the order shown in `--help`.
pub const Option = struct {
    /// e.g. "config" — drives `--config`. Required.
    long: []const u8,
    /// e.g. 'c' — drives `-c`. Null = long-only.
    short: ?u8 = null,
    /// Argument placeholder shown in help, e.g. "PATH". Null = flag (no
    /// value). When non-null, the option *must* take a value.
    arg: ?[]const u8 = null,
    /// One-paragraph help text. Wrapping is up to the caller.
    help: []const u8,
    /// Completion hint for the option's value.
    completion: Completion = .none,
};

const renderer_choices = [_][]const u8{ "auto", "cpu", "gpu" };

const completion_choices = [_][]const u8{ "bash", "zsh", "fish" };

pub const option_specs = [_]Option{
    .{ .long = "help", .short = 'h', .help = "Show this help and exit" },
    .{ .long = "version", .short = 'V', .help = "Show version and exit" },
    .{
        .long = "config",
        .short = 'c',
        .arg = "PATH",
        .help = "Use this config file (default: $XDG_CONFIG_HOME/scrgo/config.json or ~/.config/scrgo/config.json)",
        .completion = .file,
    },
    .{
        .long = "exec",
        .short = 'e',
        .arg = "COMMAND",
        .help = "Run COMMAND instead of $SHELL. Pass extra args after `--`, e.g. scrgo -e echo -- hello world",
        .completion = .command,
    },
    .{
        .long = "renderer",
        .arg = "BACKEND",
        .help = "Renderer backend (default: auto)",
        .completion = .{ .values = &renderer_choices },
    },
    .{
        .long = "generate-completion",
        .arg = "SHELL",
        .help = "Print a shell completion script to stdout (bash|zsh|fish) and exit",
        .completion = .{ .values = &completion_choices },
    },
};

/// Verbosity is a `-v`/`-vv`/`-vvv` ladder, not a generic option, so it
/// lives outside `option_specs`. Help and completions still pick it up.
const verbosity_help = "Increase log verbosity (cumulative)";

// ── Lookup helpers (used by parser + generators) ──

fn findLong(name: []const u8) ?*const Option {
    for (&option_specs) |*o| if (std.mem.eql(u8, o.long, name)) return o;
    return null;
}

fn findShort(ch: u8) ?*const Option {
    for (&option_specs) |*o| {
        if (o.short) |s| if (s == ch) return o;
    }
    return null;
}

// ── fd-backed writer ──
//
// std.Io.Writer is the canonical 0.16 sink. We pair it with a tiny vtable
// that drains by writing directly to a file descriptor — no allocator, no
// buffering quirks, just the kernel call. Used for `--help`, error messages,
// and the completion generators (they all want a *Writer).

const FdWriter = struct {
    writer: std.Io.Writer,
    fd: c_int,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdWriter = @fieldParentPtr("writer", w);
        // Drain `buffer[0..end]` first, exactly like the contract says.
        if (w.end > 0) {
            const written = writeAll(self.fd, w.buffer[0..w.end]) catch return error.WriteFailed;
            // Compact any unwritten remainder back to the buffer start.
            if (written < w.end) {
                std.mem.copyForwards(u8, w.buffer[0 .. w.end - written], w.buffer[written..w.end]);
            }
            w.end -= written;
            if (w.end > 0) return 0; // partial: caller retries
        }

        if (data.len == 0) return 0;

        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            const n = writeAll(self.fd, slice) catch return error.WriteFailed;
            total += n;
            if (n < slice.len) return total;
        }
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            const n = writeAll(self.fd, last) catch return error.WriteFailed;
            total += n;
            if (n < last.len) return total;
        }
        return total;
    }

    fn writeAll(fd: c_int, bytes: []const u8) !usize {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = c.write(fd, bytes.ptr + written, bytes.len - written);
            if (n < 0) return error.WriteFailed;
            if (n == 0) break;
            written += @intCast(n);
        }
        return written;
    }
};

const fd_writer_vtable: std.Io.Writer.VTable = .{ .drain = FdWriter.drain };

/// Build an unbuffered writer that drains directly to `fd`. The returned
/// FdWriter owns no resources — drop it when you're done.
pub fn fdWriter(fd: c_int) FdWriter {
    return .{
        .writer = .{ .vtable = &fd_writer_vtable, .buffer = &.{} },
        .fd = fd,
    };
}

// ── Public entrypoints ──

/// Write usage to `writer`. Generated from `option_specs`.
pub fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: scrgo [OPTIONS] [-e COMMAND] [-- ARGS...]
        \\
        \\A Wayland-native terminal emulator.
        \\
        \\Options:
        \\
    );

    // Two-column layout: option signature, then help. Width chosen to fit
    // the longest "  -x, --long ARG  " for the current option set.
    const sig_width: usize = 26;
    for (option_specs) |o| try writeOptionRow(writer, o, sig_width);
    try writePaddedRow(writer, "  -v, -vv, -vvv", verbosity_help, sig_width);

    try writer.writeAll(
        \\
        \\Anything after `--` is forwarded to the command from `-e`.
        \\When `-e` is omitted, $SHELL is launched.
        \\
    );
}

fn writeOptionRow(writer: *std.Io.Writer, o: Option, sig_width: usize) !void {
    var sig_buf: [128]u8 = undefined;
    var sig_stream = std.Io.Writer.fixed(&sig_buf);
    try sig_stream.writeAll("  ");
    if (o.short) |s| {
        try sig_stream.print("-{c}, ", .{s});
    } else {
        try sig_stream.writeAll("    ");
    }
    try sig_stream.print("--{s}", .{o.long});
    if (o.arg) |arg| try sig_stream.print(" {s}", .{arg});
    try writePaddedRow(writer, sig_stream.buffered(), o.help, sig_width);
}

fn writePaddedRow(writer: *std.Io.Writer, sig: []const u8, help: []const u8, sig_width: usize) !void {
    try writer.writeAll(sig);
    if (sig.len < sig_width) {
        try writer.splatByteAll(' ', sig_width - sig.len);
    } else {
        // Long signature: wrap help onto the next indented line.
        try writer.writeByte('\n');
        try writer.splatByteAll(' ', sig_width);
    }
    try writer.writeAll(help);
    try writer.writeByte('\n');
}

/// Parse argv. The caller owns `argv`; this returns slices into it.
///
/// Errors:
/// - `HelpRequested`     — caller should print usage to stdout and exit 0.
/// - `VersionRequested`  — caller should print version to stdout and exit 0.
/// - `BadArgs`           — caller should print a brief message + usage to
///                         stderr and exit 2.
pub fn parse(argv: []const []const u8) ParseError!Args {
    var args: Args = .{};

    var i: usize = 1; // skip argv[0]
    while (i < argv.len) : (i += 1) {
        const a = argv[i];

        if (std.mem.eql(u8, a, "--")) {
            args.exec_args = argv[i + 1 ..];
            break;
        }

        // Verbosity cluster: `-v`, `-vv`, `-vvv`, ... Cap at 3.
        if (a.len >= 2 and a[0] == '-' and a[1] == 'v' and isAllV(a[1..])) {
            const requested: u8 = @intCast(a.len - 1);
            args.verbosity = @intCast(@min(@as(u8, 3), requested));
            continue;
        }

        // --long=value | --long value
        if (a.len > 2 and a[0] == '-' and a[1] == '-') {
            const eq_idx = std.mem.indexOfScalar(u8, a, '=');
            const long_name = if (eq_idx) |idx| a[2..idx] else a[2..];
            const opt = findLong(long_name) orelse return error.BadArgs;
            try applyOption(&args, opt, argv, &i, eq_idx);
            continue;
        }

        // -x value | -xvalue | -h
        if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            const opt = findShort(a[1]) orelse return error.BadArgs;
            const inline_value: ?[]const u8 = if (opt.arg != null and a.len > 2) a[2..] else null;
            try applyOptionShort(&args, opt, argv, &i, inline_value);
            continue;
        }

        return error.BadArgs;
    }

    return args;
}

fn applyOption(
    args: *Args,
    opt: *const Option,
    argv: []const []const u8,
    i: *usize,
    eq_idx: ?usize,
) ParseError!void {
    if (opt.arg) |_| {
        const value = if (eq_idx) |idx|
            argv[i.*][idx + 1 ..]
        else blk: {
            if (i.* + 1 >= argv.len) return error.BadArgs;
            i.* += 1;
            break :blk argv[i.*];
        };
        try setOption(args, opt, value);
    } else {
        if (eq_idx != null) return error.BadArgs; // flag doesn't take a value
        try setFlag(args, opt);
    }
}

fn applyOptionShort(
    args: *Args,
    opt: *const Option,
    argv: []const []const u8,
    i: *usize,
    inline_value: ?[]const u8,
) ParseError!void {
    if (opt.arg) |_| {
        const value = inline_value orelse blk: {
            if (i.* + 1 >= argv.len) return error.BadArgs;
            i.* += 1;
            break :blk argv[i.*];
        };
        try setOption(args, opt, value);
    } else {
        if (inline_value != null) return error.BadArgs;
        try setFlag(args, opt);
    }
}

fn setFlag(args: *Args, opt: *const Option) ParseError!void {
    _ = args;
    if (std.mem.eql(u8, opt.long, "help")) return error.HelpRequested;
    if (std.mem.eql(u8, opt.long, "version")) return error.VersionRequested;
    return error.BadArgs;
}

fn setOption(args: *Args, opt: *const Option, value: []const u8) ParseError!void {
    if (std.mem.eql(u8, opt.long, "config")) {
        args.config_path = value;
        return;
    }
    if (std.mem.eql(u8, opt.long, "exec")) {
        args.exec_program = value;
        return;
    }
    if (std.mem.eql(u8, opt.long, "renderer")) {
        args.renderer = parseRenderer(value) orelse return error.BadArgs;
        return;
    }
    if (std.mem.eql(u8, opt.long, "generate-completion")) {
        args.generate_completion = parseCompletionShell(value) orelse return error.BadArgs;
        return;
    }
    return error.BadArgs;
}

fn parseCompletionShell(s: []const u8) ?CompletionShell {
    if (std.ascii.eqlIgnoreCase(s, "bash")) return .bash;
    if (std.ascii.eqlIgnoreCase(s, "zsh")) return .zsh;
    if (std.ascii.eqlIgnoreCase(s, "fish")) return .fish;
    return null;
}

/// Dispatch to the correct generator. Used by the runtime
/// `--generate-completion` path *and* by the install-time codegen
/// step in build.zig.
pub fn writeCompletion(writer: *std.Io.Writer, shell: CompletionShell) !void {
    switch (shell) {
        .bash => try writeBashCompletion(writer),
        .zsh => try writeZshCompletion(writer),
        .fish => try writeFishCompletion(writer),
    }
}

fn isAllV(s: []const u8) bool {
    for (s) |b| if (b != 'v') return false;
    return s.len > 0;
}

fn parseRenderer(s: []const u8) ?Renderer {
    if (std.ascii.eqlIgnoreCase(s, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(s, "cpu")) return .cpu;
    if (std.ascii.eqlIgnoreCase(s, "gpu")) return .gpu;
    return null;
}

/// Enable the curated set of log scopes implied by `-v[v[v]]`. CLI
/// verbosity layers *on top of* whatever `SCRGO_LOG` already enabled;
/// it never disables a scope the env var asked for.
pub fn applyVerbosity(verbosity: u2) void {
    if (verbosity == 0) return;
    log.enableScope(.main);
    log.enableScope(.pty);
    log.enableScope(.frame);
    if (verbosity >= 2) {
        log.enableScope(.gpu);
        log.enableScope(.cpu);
        log.enableScope(.atlas);
        log.enableScope(.input);
    }
    if (verbosity >= 3) {
        log.enableScope(.wayland);
        log.enableScope(.diag);
    }
}

// ── Completion-script generators ──
//
// These walk `option_specs` to emit bash/zsh/fish completion files.
// Used by the `completions` build step; not called at runtime.

pub fn writeBashCompletion(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\# scrgo bash completion — generated, do not edit by hand
        \\_scrgo() {
        \\    local cur prev words cword
        \\    _init_completion || return
        \\
        \\    case "$prev" in
        \\
    );
    for (option_specs) |o| if (o.arg != null) {
        try writer.print("        --{s}", .{o.long});
        if (o.short) |s| try writer.print("|-{c}", .{s});
        try writer.writeAll(")\n");
        switch (o.completion) {
            .none => try writer.writeAll("            return\n"),
            .file => try writer.writeAll("            _filedir\n            return\n"),
            .command => try writer.writeAll("            COMPREPLY=( $(compgen -c -- \"$cur\") )\n            return\n"),
            .values => |vs| {
                try writer.writeAll("            COMPREPLY=( $(compgen -W \"");
                for (vs, 0..) |v, idx| {
                    if (idx != 0) try writer.writeByte(' ');
                    try writer.writeAll(v);
                }
                try writer.writeAll("\" -- \"$cur\") )\n            return\n");
            },
        }
        try writer.writeAll("            ;;\n");
    };
    try writer.writeAll(
        \\    esac
        \\
        \\    if [[ "$cur" == -* ]]; then
        \\        COMPREPLY=( $(compgen -W "
    );
    for (option_specs, 0..) |o, idx| {
        if (idx != 0) try writer.writeByte(' ');
        try writer.print("--{s}", .{o.long});
        if (o.short) |s| try writer.print(" -{c}", .{s});
    }
    try writer.writeAll(" -v -vv -vvv\" -- \"$cur\") )\n");
    try writer.writeAll(
        \\    fi
        \\}
        \\complete -F _scrgo scrgo
        \\
    );
}

pub fn writeZshCompletion(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#compdef scrgo
        \\# scrgo zsh completion — generated, do not edit by hand
        \\
        \\_scrgo() {
        \\    _arguments -s \
        \\
    );
    for (option_specs) |o| {
        try writer.writeAll("        ");
        if (o.short) |s| {
            try writer.print("'(-{c} --{s})'{{-{c},--{s}}}", .{ s, o.long, s, o.long });
        } else {
            try writer.print("'--{s}'", .{o.long});
        }
        try writer.print("'[{s}]", .{o.help});
        if (o.arg) |arg| {
            try writer.print(":{s}:", .{arg});
            switch (o.completion) {
                .none => {},
                .file => try writer.writeAll("_files"),
                .command => try writer.writeAll("_command_names"),
                .values => |vs| {
                    try writer.writeAll("(");
                    for (vs, 0..) |v, idx| {
                        if (idx != 0) try writer.writeByte(' ');
                        try writer.writeAll(v);
                    }
                    try writer.writeAll(")");
                },
            }
        }
        try writer.writeAll("' \\\n");
    }
    try writer.writeAll("        '*-v[Increase log verbosity (cumulative)]'\n");
    try writer.writeAll(
        \\}
        \\
        \\_scrgo "$@"
        \\
    );
}

pub fn writeFishCompletion(writer: *std.Io.Writer) !void {
    try writer.writeAll("# scrgo fish completion — generated, do not edit by hand\n");
    for (option_specs) |o| {
        try writer.writeAll("complete -c scrgo");
        if (o.short) |s| try writer.print(" -s {c}", .{s});
        try writer.print(" -l {s}", .{o.long});
        try writer.print(" -d '{s}'", .{o.help});
        if (o.arg) |_| {
            try writer.writeAll(" -r");
            switch (o.completion) {
                .none => {},
                .file => try writer.writeAll(" -F"),
                .command => try writer.writeAll(" -xa '(__fish_complete_command)'"),
                .values => |vs| {
                    try writer.writeAll(" -xa '");
                    for (vs, 0..) |v, idx| {
                        if (idx != 0) try writer.writeByte(' ');
                        try writer.writeAll(v);
                    }
                    try writer.writeAll("'");
                },
            }
        } else {
            try writer.writeAll(" -f");
        }
        try writer.writeAll("\n");
    }
    try writer.writeAll("complete -c scrgo -s v -d 'Increase log verbosity (cumulative)'\n");
}

// ── Tests ──

test "parse: no args" {
    const argv: []const []const u8 = &.{"scrgo"};
    const a = try parse(argv);
    try std.testing.expect(a.exec_program == null);
    try std.testing.expectEqual(@as(usize, 0), a.exec_args.len);
    try std.testing.expectEqual(@as(u2, 0), a.verbosity);
}

test "parse: -e plus -- args" {
    const argv: []const []const u8 = &.{ "scrgo", "-e", "echo", "--", "foo", "bar" };
    const a = try parse(argv);
    try std.testing.expectEqualStrings("echo", a.exec_program.?);
    try std.testing.expectEqual(@as(usize, 2), a.exec_args.len);
    try std.testing.expectEqualStrings("foo", a.exec_args[0]);
    try std.testing.expectEqualStrings("bar", a.exec_args[1]);
}

test "parse: --config=path" {
    const argv: []const []const u8 = &.{ "scrgo", "--config=/etc/scrgo.json" };
    const a = try parse(argv);
    try std.testing.expectEqualStrings("/etc/scrgo.json", a.config_path.?);
}

test "parse: -c path" {
    const argv: []const []const u8 = &.{ "scrgo", "-c", "/etc/scrgo.json" };
    const a = try parse(argv);
    try std.testing.expectEqualStrings("/etc/scrgo.json", a.config_path.?);
}

test "parse: verbosity ladder" {
    try std.testing.expectEqual(@as(u2, 1), (try parse(&.{ "scrgo", "-v" })).verbosity);
    try std.testing.expectEqual(@as(u2, 2), (try parse(&.{ "scrgo", "-vv" })).verbosity);
    try std.testing.expectEqual(@as(u2, 3), (try parse(&.{ "scrgo", "-vvv" })).verbosity);
    try std.testing.expectEqual(@as(u2, 3), (try parse(&.{ "scrgo", "-vvvv" })).verbosity);
}

test "parse: --renderer" {
    const a = try parse(&.{ "scrgo", "--renderer", "cpu" });
    try std.testing.expectEqual(Renderer.cpu, a.renderer.?);
}

test "parse: --renderer=invalid" {
    try std.testing.expectError(error.BadArgs, parse(&.{ "scrgo", "--renderer=lol" }));
}

test "parse: help short and long" {
    try std.testing.expectError(error.HelpRequested, parse(&.{ "scrgo", "-h" }));
    try std.testing.expectError(error.HelpRequested, parse(&.{ "scrgo", "--help" }));
}

test "parse: unknown option" {
    try std.testing.expectError(error.BadArgs, parse(&.{ "scrgo", "--nope" }));
}

test "parse: stray positional" {
    try std.testing.expectError(error.BadArgs, parse(&.{ "scrgo", "stray" }));
}

test "parse: missing value" {
    try std.testing.expectError(error.BadArgs, parse(&.{ "scrgo", "-c" }));
}

test "printUsage mentions every long option" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printUsage(&w);
    inline for (option_specs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), o.long) != null);
    }
}
