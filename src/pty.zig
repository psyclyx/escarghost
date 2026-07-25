const std = @import("std");
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
});

pub const Pty = struct {
    master_fd: std.posix.fd_t,
    child_pid: c.pid_t,
    io: std.Io = undefined,

    pub fn spawn(io: std.Io, shell: []const u8, cols: u16, rows: u16) !Pty {
        return spawnCommand(io, &[_][]const u8{shell}, cols, rows);
    }

    pub fn spawnCommand(io: std.Io, argv: []const []const u8, cols: u16, rows: u16) !Pty {
        if (argv.len == 0) return error.EmptyArgv;
        var master: c_int = undefined;
        var slave: c_int = undefined;

        if (c.openpty(&master, &slave, null, null, null) != 0) {
            return error.OpenPtyFailed;
        }
        errdefer _ = std.c.close(master);

        // Set initial terminal size on the slave
        var ws: c.winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(slave, c.TIOCSWINSZ, &ws);

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // ── Child process ──
            _ = std.c.close(master);
            _ = c.setsid();
            _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));

            _ = c.dup2(slave, c.STDIN_FILENO);
            _ = c.dup2(slave, c.STDOUT_FILENO);
            _ = c.dup2(slave, c.STDERR_FILENO);
            if (slave > c.STDERR_FILENO) _ = std.c.close(slave);

            // Build null-terminated argv for exec
            var c_argv: [64:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 64;
            var bufs: [64][4096]u8 = undefined;
            for (argv, 0..) |arg, i| {
                if (i >= 63 or arg.len >= 4096) c._exit(127);
                @memcpy(bufs[i][0..arg.len], arg);
                bufs[i][arg.len] = 0;
                c_argv[i] = bufs[i][0..arg.len :0];
            }

            // execvp searches $PATH so `-e echo` resolves to /usr/bin/echo
            // without the caller spelling the absolute path. Falls back to
            // exec(127) on lookup failure, same as a shell does.
            _ = c.execvp(c_argv[0].?, @ptrCast(&c_argv));
            c._exit(127);
        }

        // ── Parent process ──
        _ = std.c.close(slave);

        // Set master to non-blocking
        const flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK);

        return .{
            .master_fd = master,
            .child_pid = pid,
            .io = io,
        };
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16, width_px: u32, height_px: u32) void {
        var ws: c.winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = @intCast(@min(width_px, std.math.maxInt(u16))),
            .ws_ypixel = @intCast(@min(height_px, std.math.maxInt(u16))),
        };
        _ = c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws);
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        const file = std.Io.File{ .handle = self.master_fd, .flags = .{ .nonblocking = true } };
        const n = file.readStreaming(self.io, &.{buf}) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            error.EndOfStream => return 0, // EIO on PTY means child exited
            else => return error.ReadFailed,
        };
        return n;
    }

    pub fn write(self: *Pty, data: []const u8) !void {
        const file = std.Io.File{ .handle = self.master_fd, .flags = .{ .nonblocking = true } };
        var written: usize = 0;
        while (written < data.len) {
            const n = file.writeStreaming(self.io, &.{}, &.{data[written..]}, 1) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return error.WriteFailed,
            };
            if (n == 0) continue;
            written += n;
        }
    }

    pub fn close(self: *Pty) void {
        if (self.master_fd >= 0) {
            _ = std.c.close(self.master_fd);
            self.master_fd = -1;
        }
        if (self.child_pid > 0) {
            _ = c.waitpid(self.child_pid, null, 0);
            self.child_pid = -1;
        }
    }

    /// Check if child has exited without blocking.
    pub fn checkChild(self: *Pty) ?i32 {
        if (self.child_pid <= 0) return 0;
        var status: c_int = 0;
        const ret = c.waitpid(self.child_pid, &status, c.WNOHANG);
        if (ret > 0) {
            self.child_pid = -1; // already waited
            if (c.WIFEXITED(status)) return c.WEXITSTATUS(status);
            return -1;
        }
        return null;
    }
};
