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

    pub fn spawn(shell: []const u8, cols: u16, rows: u16) !Pty {
        var master: c_int = undefined;
        var slave: c_int = undefined;

        if (c.openpty(&master, &slave, null, null, null) != 0) {
            return error.OpenPtyFailed;
        }
        errdefer _ = c.close(master);

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
            _ = c.close(master);
            _ = c.setsid();
            _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));

            _ = c.dup2(slave, c.STDIN_FILENO);
            _ = c.dup2(slave, c.STDOUT_FILENO);
            _ = c.dup2(slave, c.STDERR_FILENO);
            if (slave > c.STDERR_FILENO) _ = c.close(slave);

            // Null-terminate the shell path for exec
            var shell_buf: [4096]u8 = undefined;
            if (shell.len >= shell_buf.len) c._exit(127);
            @memcpy(shell_buf[0..shell.len], shell);
            shell_buf[shell.len] = 0;
            const shell_z: [*:0]const u8 = shell_buf[0..shell.len :0];

            // exec the shell (use execv since we have the full path)
            const argv_arr = [2:null]?[*:0]const u8{ shell_z, null };
            _ = c.execv(shell_z, @ptrCast(&argv_arr));
            c._exit(127);
        }

        // ── Parent process ──
        _ = c.close(slave);

        // Set master to non-blocking
        const flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK);

        return .{
            .master_fd = master,
            .child_pid = pid,
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
        const n = c.read(self.master_fd, buf.ptr, buf.len);
        if (n < 0) {
            const errno = std.c._errno().*;
            if (errno == @intFromEnum(std.posix.E.AGAIN) or
                errno == @intFromEnum(std.posix.E.AGAIN))
                return error.WouldBlock;
            if (errno == @intFromEnum(std.posix.E.IO))
                return 0; // EIO on PTY means child exited
            return error.ReadFailed;
        }
        return @intCast(n);
    }

    pub fn write(self: *Pty, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = c.write(self.master_fd, data.ptr + written, data.len - written);
            if (n < 0) {
                const errno = std.c._errno().*;
                if (errno == @intFromEnum(std.posix.E.AGAIN) or
                    errno == @intFromEnum(std.posix.E.AGAIN))
                    continue;
                return error.WriteFailed;
            }
            written += @intCast(n);
        }
    }

    pub fn close(self: *Pty) void {
        _ = c.close(self.master_fd);
        _ = c.waitpid(self.child_pid, null, 0);
    }

    /// Check if child has exited without blocking.
    pub fn checkChild(self: *Pty) ?i32 {
        var status: c_int = 0;
        const ret = c.waitpid(self.child_pid, &status, c.WNOHANG);
        if (ret > 0) {
            if (c.WIFEXITED(status)) return c.WEXITSTATUS(status);
            return -1; // signaled
        }
        return null; // still running
    }
};
