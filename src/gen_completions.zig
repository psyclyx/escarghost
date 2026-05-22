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
    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_list.deinit(init.gpa);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |a| try argv_list.append(init.gpa, a);

    if (argv_list.items.len < 2) {
        const msg = "usage: gen-completions <output-dir>\n";
        _ = std.c.write(2, msg, msg.len);
        std.process.exit(2);
    }
    const out_dir = argv_list.items[1];

    // Make sure the directory exists. EEXIST is fine.
    const dir_z = try init.gpa.dupeZ(u8, out_dir);
    defer init.gpa.free(dir_z);
    _ = std.c.mkdir(dir_z.ptr, @as(std.c.mode_t, 0o755));

    for (shells) |s| {
        const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ out_dir, s.name });
        defer init.gpa.free(path);

        const path_z = try init.gpa.dupeZ(u8, path);
        defer init.gpa.free(path_z);
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) std.process.exit(1);
        defer _ = std.c.close(fd);

        var writer = cli.fdWriter(fd);
        try cli.writeCompletion(&writer.writer, s.shell);
    }
}
