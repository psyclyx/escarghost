//! Codegen binary for shell completion scripts.
//!
//! Usage: gen-completions <output-dir>
//!
//! Writes scrgo.bash, _scrgo, scrgo.fish into the output directory.
//! Imports cli.zig so the completions stay in lockstep with the option
//! table — no hand-written duplicates to drift.

const std = @import("std");
const cli = @import("cli.zig");

const shells = [_]struct { shell: cli.CompletionShell, name: []const u8 }{
    .{ .shell = .bash, .name = "scrgo.bash" },
    .{ .shell = .zsh, .name = "_scrgo" },
    .{ .shell = .fish, .name = "scrgo.fish" },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_list.deinit(init.gpa);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |a| try argv_list.append(init.gpa, a);

    if (argv_list.items.len < 2) {
        const msg = "usage: gen-completions <output-dir>\n";
        std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
        std.process.exit(2);
    }
    const out_dir = argv_list.items[1];

    // Make sure the directory exists. EEXIST is fine.
    std.Io.Dir.cwd.createDir(io, out_dir, .default_dir) catch {};

    for (shells) |s| {
        const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ out_dir, s.name });
        defer init.gpa.free(path);

        const file = std.Io.Dir.cwd.createFile(io, path, .{ .read = false, .truncate = true }) catch std.process.exit(1);
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try cli.writeCompletion(&writer.interface, s.shell);
    }
}
