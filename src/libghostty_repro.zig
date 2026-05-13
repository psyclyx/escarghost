//! Minimal repro for the libghostty-vt SEGV we hit while streaming
//! ~200k lines through scrgo. Strips everything except scrgo's
//! Terminal wrapper — no PTY, no renderer, no wayland, no threads —
//! and feeds linefeed-heavy VT data straight in via feedData.
//!
//! If this crashes → libghostty-vt has a real bug (file upstream).
//! If this is clean → scrgo's integration is to blame, look at the
//!   render thread / atlas thread / scroll viewport interaction.
//!
//! Reproduces the exact same crash path:
//!   terminal.Screen.cursorChangePin ← terminal.Terminal.index
//!   ← terminal.Terminal.linefeed   ← terminal.Terminal.feedData

const std = @import("std");
const terminal_mod = @import("terminal.zig");
const config_mod = @import("config.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var cfg = try config_mod.load(allocator);
    defer cfg.deinit(allocator);

    // Match scrgo's *host-display* config — when we hit the SEGV
    // scrgo was running on a 1880×2504 wayland surface, which at
    // default 14pt font lands around 220×140. Push scrollback past
    // what our payload generates so eviction happens often.
    const cols: u16 = 220;
    const rows: u16 = 140;
    const max_scrollback: u32 = 10_000;

    var term: terminal_mod.Terminal = undefined;
    try term.init(cols, rows, max_scrollback, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // Match what `seq 1 200000` produces — short numeric lines, each
    // ending in \n.
    //
    // scrgo doesn't just feed in a tight loop: between PTY drains it
    // calls term.updateRenderState + the cell-iteration cycle (via
    // render_snapshot.capture). That's the only meaningful difference
    // between this repro and how scrgo's main loop hits libghostty.
    // Periodically simulate that pattern so the repro actually
    // matches the live behaviour.
    var line_buf: [32]u8 = undefined;
    var lines_fed: u32 = 0;
    var bytes_fed: u64 = 0;

    const target_lines: u32 = 200_000;
    const iter_every: u32 = 64; // ~one render cycle per few KB of input
    while (lines_fed < target_lines) : (lines_fed += 1) {
        // PTY line discipline translates \n → \r\n on output, so the
        // bytes scrgo actually receives are CRLF-terminated, not LF.
        const slice = std.fmt.bufPrint(&line_buf, "{d}\r\n", .{lines_fed}) catch unreachable;
        term.feedData(slice);
        bytes_fed += slice.len;

        if (lines_fed % iter_every == 0) {
            try term.updateRenderState();
            term.beginRowIteration();
            var rc: u16 = 0;
            while (term.nextRow()) : (rc += 1) {
                term.beginCellIteration();
                while (term.nextCell()) {
                    _ = term.getCellInfo();
                }
            }
            term.resetDirty();
        }

        if (lines_fed % 10_000 == 0 and lines_fed > 0) {
            std.debug.print("  fed {d} lines ({d} bytes)\n", .{ lines_fed, bytes_fed });
        }
    }

    std.debug.print("DONE: {d} lines, {d} bytes, no crash.\n", .{ lines_fed, bytes_fed });
}
