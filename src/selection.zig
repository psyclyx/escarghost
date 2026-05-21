//! Terminal text selection state machine. Owned by main.zig and updated
//! from mouse events. The selection itself is a (start_cell, end_cell, mode)
//! triple in *viewport* coordinates (row 0 = top of visible viewport), which
//! both renderers can highlight directly. Scrolling the viewport does not
//! shift the highlighted region — selection follows the screen, not the
//! scrollback, to keep the implementation small. That's an acceptable
//! compromise for the first cut; future work could anchor the selection to
//! ghostty GridRefs and survive scrolling.
//!
//! The state machine handles drag (char), double-click (word), and
//! triple-click (line) modes, plus shift+click extend. Word boundaries
//! are detected from a small predicate over codepoints; line mode
//! always selects whole rows. The renderer treats the selection as an
//! ordered (top-left → bottom-right) rect band.

const std = @import("std");

pub const Cell = struct {
    row: u16,
    col: u16,

    pub fn lessThan(a: Cell, b: Cell) bool {
        if (a.row != b.row) return a.row < b.row;
        return a.col < b.col;
    }

    pub fn eql(a: Cell, b: Cell) bool {
        return a.row == b.row and a.col == b.col;
    }
};

pub const Mode = enum {
    /// Character-level drag selection. start = anchor, end = pointer.
    char,
    /// Word selection (double-click). Start/end are word boundaries
    /// snapped from the click cell.
    word,
    /// Line selection (triple-click). Whole-row(s) between start.row
    /// and end.row.
    line,
};

pub const Range = struct {
    anchor: Cell,
    head: Cell,
    mode: Mode,

    /// Ordered (top-left → bottom-right) endpoints. Renderers prefer
    /// this form; the anchor/head distinction matters only for extend.
    pub fn ordered(self: Range) struct { start: Cell, end: Cell } {
        if (Cell.lessThan(self.anchor, self.head))
            return .{ .start = self.anchor, .end = self.head };
        return .{ .start = self.head, .end = self.anchor };
    }

    pub fn isEmpty(self: Range) bool {
        return Cell.eql(self.anchor, self.head) and self.mode == .char;
    }
};

pub const MAX_CLICK_INTERVAL_MS: u32 = 350;
/// Allowed pointer drift between clicks (in cells) to still count as a
/// multi-click. Compositors deliver pixel coordinates with subpixel
/// precision, so the same physical click can show up at slightly
/// different cell positions; clicks must land on the *same* cell.
const SAME_CELL_TOLERANCE: i32 = 0;

/// Selection state machine. `dragging == false` and `range == null` is
/// the rest state; the renderer skips selection rendering in that case.
pub const State = struct {
    range: ?Range = null,
    dragging: bool = false,
    /// True while the user is shift+clicking to extend without releasing
    /// the anchor.
    extending: bool = false,

    /// Click tracking for double/triple-click detection.
    last_click_cell: ?Cell = null,
    last_click_ms: i64 = 0,
    consecutive_clicks: u8 = 0,

    /// Begin a char-mode drag at `cell`. Shift+click extends the
    /// existing range's head instead of replacing the anchor.
    pub fn beginPrimary(self: *State, cell: Cell, shift: bool, now_ms: i64) void {
        const clicks = self.recordClick(cell, now_ms);
        // Multi-click promotes to word (2) or line (3+) selection.
        // Shift+click doesn't promote — it always extends in char mode.
        if (!shift and clicks >= 2) {
            const mode: Mode = if (clicks == 2) .word else .line;
            self.range = .{ .anchor = cell, .head = cell, .mode = mode };
            self.dragging = false;
            self.extending = false;
            return;
        }
        if (shift) {
            if (self.range) |existing| {
                self.range = .{ .anchor = existing.anchor, .head = cell, .mode = .char };
                self.dragging = true;
                self.extending = true;
                return;
            }
        }
        self.range = .{ .anchor = cell, .head = cell, .mode = .char };
        self.dragging = true;
        self.extending = false;
    }

    /// Update the drag endpoint as the pointer moves.
    pub fn updateDrag(self: *State, cell: Cell) void {
        if (!self.dragging) return;
        var r = self.range orelse return;
        r.head = cell;
        // A drag always operates in char mode, even after a multi-click
        // promotion: the user clearly wants to extend by character.
        r.mode = .char;
        self.range = r;
    }

    pub fn endDrag(self: *State) void {
        self.dragging = false;
        self.extending = false;
        if (self.range) |r| {
            // Drop empty selections so renderers don't paint a 0-width
            // band on a no-drag click.
            if (r.isEmpty()) self.range = null;
        }
    }

    pub fn clear(self: *State) void {
        self.range = null;
        self.dragging = false;
        self.extending = false;
        self.consecutive_clicks = 0;
        self.last_click_cell = null;
    }

    /// Snapshot the current state for the renderer pipeline. Returns
    /// null when there's no usable selection (rest state or a 0-width
    /// drag that hasn't moved off the anchor yet).
    pub fn toSnapshot(self: *const State) ?Snapshot {
        const r = self.range orelse return null;
        if (r.isEmpty()) return null;
        return .{ .anchor = r.anchor, .head = r.head, .mode = r.mode };
    }

    fn recordClick(self: *State, cell: Cell, now_ms: i64) u8 {
        const last_cell = self.last_click_cell;
        const dt = now_ms - self.last_click_ms;
        const is_same_cell = if (last_cell) |lc|
            (@abs(@as(i32, cell.col) - @as(i32, lc.col)) <= SAME_CELL_TOLERANCE and
                @abs(@as(i32, cell.row) - @as(i32, lc.row)) <= SAME_CELL_TOLERANCE)
        else
            false;
        if (is_same_cell and dt >= 0 and dt <= MAX_CLICK_INTERVAL_MS) {
            self.consecutive_clicks +|= 1;
        } else {
            self.consecutive_clicks = 1;
        }
        self.last_click_cell = cell;
        self.last_click_ms = now_ms;
        return self.consecutive_clicks;
    }
};

/// Frozen selection passed through the snapshot pipeline to the
/// renderers. Carries the raw anchor / head so word/line resolution can
/// happen at render time with access to the grid codepoints.
pub const Snapshot = struct {
    anchor: Cell,
    head: Cell,
    mode: Mode,

    pub fn ordered(self: Snapshot) struct { start: Cell, end: Cell } {
        if (Cell.lessThan(self.anchor, self.head))
            return .{ .start = self.anchor, .end = self.head };
        return .{ .start = self.head, .end = self.anchor };
    }
};


/// Classify a codepoint as a "word" character for word selection. Mirrors
/// xterm's `charClass` philosophy: alphanumerics plus a few common
/// path/code chars are part of a word, whitespace and most punctuation
/// are not. Symmetric so double-clicking on whitespace selects the
/// whitespace run, not a hidden word boundary.
pub fn isWordChar(cp: u32) bool {
    if (cp < 0x20) return false;
    if (cp == ' ' or cp == '\t') return false;
    // Common path / source-code identifier chars
    switch (cp) {
        '_', '-', '.', '/', '~', '+', '@', '#', '$', '%' => return true,
        else => {},
    }
    // ASCII alnum
    if ((cp >= '0' and cp <= '9') or
        (cp >= 'A' and cp <= 'Z') or
        (cp >= 'a' and cp <= 'z')) return true;
    // Anything outside ASCII is treated as a word char (CJK, accents, etc.).
    if (cp >= 0x80) return true;
    return false;
}

/// Expand a `word` mode selection over a single row given its codepoints.
/// Returns the [start, end] *inclusive* column range covering the word
/// (or whitespace run) that contains `col`. If `col` is out of bounds,
/// returns the cell itself.
pub fn expandWord(row_codepoints: []const u32, col: u16) struct { start: u16, end: u16 } {
    if (col >= row_codepoints.len) return .{ .start = col, .end = col };
    const center_is_word = isWordChar(row_codepoints[col]);
    var start: u16 = col;
    while (start > 0 and isWordChar(row_codepoints[start - 1]) == center_is_word) start -= 1;
    var end: u16 = col;
    while (end + 1 < row_codepoints.len and isWordChar(row_codepoints[end + 1]) == center_is_word) end += 1;
    return .{ .start = start, .end = end };
}

// ── tests ──

test "Cell.lessThan and ordered" {
    var s = State{};
    s.beginPrimary(.{ .row = 2, .col = 5 }, false, 0);
    s.updateDrag(.{ .row = 0, .col = 3 });
    const ord = s.range.?.ordered();
    try std.testing.expect(Cell.eql(ord.start, .{ .row = 0, .col = 3 }));
    try std.testing.expect(Cell.eql(ord.end, .{ .row = 2, .col = 5 }));
}

test "single click without drag clears to null on endDrag" {
    var s = State{};
    s.beginPrimary(.{ .row = 1, .col = 1 }, false, 0);
    s.endDrag();
    try std.testing.expect(s.range == null);
}

test "drag with movement keeps a non-empty range" {
    var s = State{};
    s.beginPrimary(.{ .row = 1, .col = 1 }, false, 0);
    s.updateDrag(.{ .row = 1, .col = 5 });
    s.endDrag();
    try std.testing.expect(s.range != null);
    try std.testing.expect(s.range.?.mode == .char);
}

test "double click promotes to word mode" {
    var s = State{};
    s.beginPrimary(.{ .row = 0, .col = 3 }, false, 0);
    s.endDrag();
    s.beginPrimary(.{ .row = 0, .col = 3 }, false, 100);
    try std.testing.expect(s.range != null);
    try std.testing.expect(s.range.?.mode == .word);
}

test "triple click promotes to line mode" {
    var s = State{};
    s.beginPrimary(.{ .row = 0, .col = 3 }, false, 0);
    s.endDrag();
    s.beginPrimary(.{ .row = 0, .col = 3 }, false, 100);
    s.endDrag();
    s.beginPrimary(.{ .row = 0, .col = 3 }, false, 200);
    try std.testing.expect(s.range.?.mode == .line);
}

test "multi-click resets when cell changes" {
    var s = State{};
    s.beginPrimary(.{ .row = 0, .col = 3 }, false, 0);
    s.endDrag();
    s.beginPrimary(.{ .row = 0, .col = 4 }, false, 100);
    try std.testing.expect(s.range.?.mode == .char);
}

test "multi-click resets after timeout" {
    var s = State{};
    s.beginPrimary(.{ .row = 0, .col = 3 }, false, 0);
    s.endDrag();
    s.beginPrimary(.{ .row = 0, .col = 3 }, false, @as(i64, @intCast(MAX_CLICK_INTERVAL_MS)) + 50);
    try std.testing.expect(s.range.?.mode == .char);
}

test "shift+click extends head, preserves anchor" {
    var s = State{};
    s.beginPrimary(.{ .row = 1, .col = 2 }, false, 0);
    s.updateDrag(.{ .row = 1, .col = 5 });
    s.endDrag();
    s.beginPrimary(.{ .row = 3, .col = 10 }, true, 100);
    try std.testing.expect(Cell.eql(s.range.?.anchor, .{ .row = 1, .col = 2 }));
    try std.testing.expect(Cell.eql(s.range.?.head, .{ .row = 3, .col = 10 }));
}

test "word expansion on a simple sentence" {
    const text = [_]u32{ 'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd' };
    const w1 = expandWord(&text, 2);
    try std.testing.expectEqual(@as(u16, 0), w1.start);
    try std.testing.expectEqual(@as(u16, 4), w1.end);
    const w2 = expandWord(&text, 8);
    try std.testing.expectEqual(@as(u16, 6), w2.start);
    try std.testing.expectEqual(@as(u16, 10), w2.end);
    const ws = expandWord(&text, 5);
    try std.testing.expectEqual(@as(u16, 5), ws.start);
    try std.testing.expectEqual(@as(u16, 5), ws.end);
}

test "word expansion treats path-like chars as a single word" {
    const text = [_]u32{ '/', 't', 'm', 'p', '/', 'f', 'o', 'o', '.', 't', 'x', 't' };
    const w = expandWord(&text, 6);
    try std.testing.expectEqual(@as(u16, 0), w.start);
    try std.testing.expectEqual(@as(u16, 11), w.end);
}
