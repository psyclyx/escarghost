const std = @import("std");
const terminal_mod = @import("terminal.zig");
const config_mod = @import("config.zig");

const c = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
});

const ghostty_c = @cImport(@cInclude("ghostty/vt.h"));

/// Headless test that exercises the input round-trip: bytes written to the
/// PTY master come back via the kernel's line-discipline echo (ECHO is on
/// by default), get fed to the Terminal, and land in the expected cells.
///
/// This bypasses Wayland and the renderer — the goal is to catch
/// regressions in scrgo's "input bytes → PTY → terminal grid" path
/// without needing a compositor or a GL context. Real input-to-pixel
/// timing is covered by the integration harness.
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
    _ = c.close(p.master);
    _ = c.close(p.slave);
}

fn writeAll(fd: c_int, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data.ptr + off, data.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Poll-wait for `master` to become readable, then drain everything
/// currently buffered. Caller picks a deadline. Returns total bytes read.
fn waitAndDrain(fd: c_int, out: []u8, timeout_ms: c_int) !usize {
    var total: usize = 0;
    var poll_timeout = timeout_ms;
    while (total < out.len) {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const rc = c.poll(&pfd, 1, poll_timeout);
        if (rc < 0) return error.PollFailed;
        if (rc == 0) break;
        if (pfd.revents & c.POLLIN == 0) break;
        while (total < out.len) {
            const n = c.read(fd, out.ptr + total, out.len - total);
            if (n <= 0) break;
            total += @intCast(n);
        }
        // Kernel may deliver echo in pieces — give it one short follow-up
        // poll before giving up.
        poll_timeout = 5;
    }
    return total;
}

/// Copy printable bytes from `row` of the terminal into `out`. Non-text
/// cells and codepoints outside basic-ASCII become spaces.
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

fn runRoundTripCase(allocator: std.mem.Allocator, cfg: *const config_mod.Config, case: Case) !bool {
    _ = allocator;
    const cols: u16 = 40;
    const rows: u16 = 4;
    var term: terminal_mod.Terminal = undefined;
    try term.init(cols, rows, 100, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    const pair = try openPair();
    defer closePair(pair);

    try writeAll(pair.master, case.send);

    var rbuf: [256]u8 = undefined;
    const n = try waitAndDrain(pair.master, &rbuf, 200);
    if (n == 0) {
        std.debug.print("FAIL [{s}]: no echo from PTY (line discipline?)\n", .{case.name});
        return false;
    }
    term.feedData(rbuf[0..n]);
    try term.updateRenderState();

    var row_buf: [40]u8 = undefined;
    const got_len = collectRow(&term, case.row, &row_buf);
    const got = rtrimSpaces(row_buf[0..got_len]);
    const want = rtrimSpaces(case.expect);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("FAIL [{s}]: want='{s}' got='{s}' (read {} echo bytes)\n", .{ case.name, want, got, n });
        return false;
    }
    std.debug.print("ok   [{s}]: row{}='{s}'\n", .{ case.name, case.row, got });
    return true;
}

fn checkEncodedKey(term: *terminal_mod.Terminal, key: c_uint, label: []const u8) bool {
    const enc = term.encodeKey(key, ghostty_c.GHOSTTY_KEY_ACTION_PRESS, 0, null);
    if (enc == null or enc.?.len == 0) {
        std.debug.print("FAIL: encodeKey({s}) returned empty\n", .{label});
        return false;
    }
    var hex_buf: [128]u8 = undefined;
    var w: usize = 0;
    for (enc.?) |b| {
        if (w + 3 > hex_buf.len) break;
        _ = std.fmt.bufPrint(hex_buf[w..], "{x:0>2} ", .{b}) catch {};
        w += 3;
    }
    std.debug.print("ok   encodeKey({s}) = {} bytes [{s}]\n", .{ label, enc.?.len, hex_buf[0 .. if (w > 0) w - 1 else 0] });
    return true;
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var cfg = try config_mod.load(allocator);
    defer cfg.deinit(allocator);

    var failed: u32 = 0;

    for (cases) |case| {
        const ok = runRoundTripCase(allocator, &cfg, case) catch |err| blk: {
            std.debug.print("FAIL [{s}]: error {}\n", .{ case.name, err });
            break :blk false;
        };
        if (!ok) failed += 1;
    }

    {
        var term: terminal_mod.Terminal = undefined;
        try term.init(80, 24, 100, cfg.palette, cfg.foreground, cfg.background);
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
            if (!checkEncodedKey(&term, s.key, s.label)) failed += 1;
        }
    }

    if (failed > 0) {
        std.debug.print("FAIL: {} input test(s) failed\n", .{failed});
        std.process.exit(1);
    }
    std.debug.print("PASS: all input round-trip tests passed\n", .{});
}
