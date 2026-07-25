//! Headless tests for the input round-trip: bytes written to a real PTY
//! master come back via the kernel's line-discipline echo, get fed to
//! Terminal, and land in the expected cells. Bypasses Wayland and the
//! renderer; real input-to-pixel timing is covered by the integration
//! harness. Run via `zig build test-input` (or `zig build test`).

const std = @import("std");
const testing = std.testing;
const terminal_mod = @import("terminal_mod");
const config_mod = @import("config_mod");

const c = @cImport({
    @cInclude("pty.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
});

const ghostty_c = @cImport(@cInclude("ghostty/vt.h"));

/// Build a thread-safe `Io` instance for tests. The caller must keep
/// `t` alive for as long as `io` is used.
fn testIo(t: *std.Io.Threaded) std.Io {
    t.* = std.Io.Threaded.init(testing.allocator, .{});
    return t.io();
}

const PtyPair = struct {
    master: c_int,
    slave: c_int,
};

fn openPair() !PtyPair {
    var master: c_int = 0;
    var slave: c_int = 0;
    if (c.openpty(&master, &slave, null, null, null) != 0) return error.OpenPtyFailed;
    const flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK);
    return .{ .master = master, .slave = slave };
}

fn closePair(p: PtyPair) void {
    _ = std.c.close(p.master);
    _ = std.c.close(p.slave);
}

fn writeAll(io: std.Io, fd: c_int, data: []const u8) !void {
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.writeStreamingAll(io, data) catch return error.WriteFailed;
}

/// Poll-wait for `master` to become readable, then drain everything
/// currently buffered. Caller picks a deadline. Returns total bytes read.
fn waitAndDrain(io: std.Io, fd: c_int, out: []u8, timeout_ms: c_int) !usize {
    var total: usize = 0;
    var poll_timeout = timeout_ms;
    while (total < out.len) {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const rc = c.poll(&pfd, 1, poll_timeout);
        if (rc < 0) return error.PollFailed;
        if (rc == 0) break;
        if (pfd.revents & c.POLLIN == 0) break;
        const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = true } };
        while (total < out.len) {
            const n = file.readStreaming(io, &.{out[total..]}) catch |err| switch (err) {
                error.WouldBlock => break,
                error.EndOfStream => break,
                else => break,
            };
            if (n == 0) break;
            total += n;
        }
        // Kernel may deliver echo in pieces — give it one short follow-up
        // poll before giving up.
        poll_timeout = 5;
    }
    return total;
}

fn collectRow(term: *terminal_mod.Terminal, row: u16, out: []u8) usize {
    @memset(out, ' ');
    term.beginRowIteration();
    var r: u16 = 0;
    while (term.nextRow()) : (r += 1) {
        if (r != row) continue;
        term.beginCellIteration();
        var col: usize = 0;
        while (term.nextCell() and col < out.len) : (col += 1) {
            const ci = term.getCellInfo();
            if (ci.has_text and ci.codepoint >= 0x20 and ci.codepoint < 0x7f) {
                out[col] = @intCast(ci.codepoint);
            }
        }
        return col;
    }
    return 0;
}

fn rtrimSpaces(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') end -= 1;
    return s[0..end];
}

const Case = struct {
    name: []const u8,
    send: []const u8,
    row: u16 = 0,
    expect: []const u8,
};

// Default line discipline: ICRNL turns input '\r' into '\n', OPOST/ONLCR
// then turns output '\n' into '\r\n' on echo. So a write of "ab\ncd"
// reaches the master read as "ab\r\ncd" — row 0 is "ab", row 1 is "cd".
// That's the same shape as a real shell echoing what the user typed.
const cases = [_]Case{
    .{ .name = "ascii abc", .send = "abc", .expect = "abc" },
    .{ .name = "with space", .send = "a b c", .expect = "a b c" },
    .{ .name = "digits + punct", .send = "1+2=3", .expect = "1+2=3" },
    .{ .name = "newline row0", .send = "ab\ncd", .row = 0, .expect = "ab" },
    .{ .name = "newline row1", .send = "ab\ncd", .row = 1, .expect = "cd" },
};

fn runRoundTripCase(io: std.Io, cfg: *const config_mod.Config, case: Case) !void {
    const cols: u16 = 40;
    const rows: u16 = 4;
    var term: terminal_mod.Terminal = undefined;
    try term.init(io, cols, rows, 100, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    const pair = try openPair();
    defer closePair(pair);

    try writeAll(io, pair.master, case.send);

    var rbuf: [256]u8 = undefined;
    const n = try waitAndDrain(io, pair.master, &rbuf, 200);
    if (n == 0) {
        std.debug.print("case [{s}]: PTY produced no echo (line-discipline state?)\n", .{case.name});
        return error.NoEcho;
    }
    term.feedData(rbuf[0..n]);
    try term.updateRenderState();

    var row_buf: [40]u8 = undefined;
    const got_len = collectRow(&term, case.row, &row_buf);
    const got = rtrimSpaces(row_buf[0..got_len]);
    const want = rtrimSpaces(case.expect);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("case [{s}]: want='{s}' got='{s}' (read {} echo bytes)\n", .{ case.name, want, got, n });
        return error.MismatchedRow;
    }
}

test "PTY echo round-trip lands in the expected cells" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try config_mod.load(allocator, io, null);
    defer cfg.deinit(allocator);

    for (cases) |case| try runRoundTripCase(io, &cfg, case);
}

test "encodeKey returns non-empty bytes for the common special keys" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    var cfg = try config_mod.load(allocator, io, null);
    defer cfg.deinit(allocator);

    var term: terminal_mod.Terminal = undefined;
    try term.init(io, 80, 24, 100, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    const specials = [_]struct { key: c_uint, label: []const u8 }{
        .{ .key = ghostty_c.GHOSTTY_KEY_ENTER, .label = "Enter" },
        .{ .key = ghostty_c.GHOSTTY_KEY_ARROW_UP, .label = "ArrowUp" },
        .{ .key = ghostty_c.GHOSTTY_KEY_ARROW_DOWN, .label = "ArrowDown" },
        .{ .key = ghostty_c.GHOSTTY_KEY_F1, .label = "F1" },
        .{ .key = ghostty_c.GHOSTTY_KEY_TAB, .label = "Tab" },
        .{ .key = ghostty_c.GHOSTTY_KEY_BACKSPACE, .label = "Backspace" },
    };
    for (specials) |s| {
        const enc = term.encodeKey(s.key, ghostty_c.GHOSTTY_KEY_ACTION_PRESS, 0, null);
        if (enc == null or enc.?.len == 0) {
            std.debug.print("encodeKey({s}) returned empty\n", .{s.label});
            return error.EmptyEncoding;
        }
    }
}
