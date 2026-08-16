//! Command palette: a modal overlay for twiddling runtime settings and running
//! debug commands without a dedicated keybinding for each one. No persistence.
//!
//! This module is a pure leaf (imports only `std`): the command *metadata*
//! (id/name/category), the palette's interaction state, the fuzzy filter, and
//! the render-ready overlay snapshot. It deliberately does NOT know how to
//! *execute* a command — that dispatch lives in `input.zig`, which owns the
//! action functions and the global `AppState`, and switches on `Command.id`.
//! Keeping execution out of here avoids an input↔palette↔render_loop import
//! cycle: `app_state`, `input`, `render_loop`, `render_snapshot`, and the
//! pipelines all import this module one-directionally.

const std = @import("std");

/// Stable identity for a command. `input.zig` switches on this to run the
/// action; the metadata table below pairs each id with its display text.
pub const CommandId = enum {
    font_increase,
    font_decrease,
    font_reset,
    toggle_custom_glyphs,
    cycle_hint_mode,
    swap_renderer,
    kill_renderer,
    force_redraw,
    scroll_top,
    scroll_bottom,
    copy_selection,
    paste,
};

pub const Command = struct {
    id: CommandId,
    /// Display + fuzzy-match target. Static string literal, so slices of it are
    /// safe to hand to a render worker thread via the snapshot.
    name: []const u8,
    category: []const u8,
};

/// The registry. Order here is the tie-break order shown for a given filter.
pub const commands = [_]Command{
    .{ .id = .font_increase, .name = "Increase font size", .category = "Font" },
    .{ .id = .font_decrease, .name = "Decrease font size", .category = "Font" },
    .{ .id = .font_reset, .name = "Reset font size", .category = "Font" },
    .{ .id = .toggle_custom_glyphs, .name = "Toggle custom glyphs (Powerline/box)", .category = "View" },
    .{ .id = .cycle_hint_mode, .name = "Cycle hint mode", .category = "Render" },
    .{ .id = .swap_renderer, .name = "Toggle renderer (CPU/GPU)", .category = "Render" },
    .{ .id = .kill_renderer, .name = "Kill active renderer", .category = "Debug" },
    .{ .id = .force_redraw, .name = "Force redraw", .category = "Debug" },
    .{ .id = .scroll_top, .name = "Scroll to top", .category = "Scroll" },
    .{ .id = .scroll_bottom, .name = "Scroll to bottom", .category = "Scroll" },
    .{ .id = .copy_selection, .name = "Copy selection", .category = "Clipboard" },
    .{ .id = .paste, .name = "Paste", .category = "Clipboard" },
};

pub const MAX_QUERY: usize = 128;
/// Most command rows shown at once; longer filtered lists scroll a window.
pub const MAX_VISIBLE: usize = 12;

/// Interaction state, held on `AppState`. Pure data — no back-reference to the
/// app — so this module stays a leaf.
pub const PaletteState = struct {
    open: bool = false,
    query: [MAX_QUERY]u8 = undefined,
    query_len: usize = 0,
    /// Index into the *filtered* command list (not the registry).
    selected: usize = 0,

    pub fn queryText(self: *const PaletteState) []const u8 {
        return self.query[0..self.query_len];
    }

    pub fn openReset(self: *PaletteState) void {
        self.open = true;
        self.query_len = 0;
        self.selected = 0;
    }

    pub fn appendChar(self: *PaletteState, byte: u8) void {
        if (self.query_len >= self.query.len) return;
        self.query[self.query_len] = byte;
        self.query_len += 1;
        self.selected = 0;
    }

    pub fn backspace(self: *PaletteState) void {
        if (self.query_len == 0) return;
        self.query_len -= 1;
        self.selected = 0;
    }
};

fn asciiLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

/// Case-insensitive subsequence match: every char of `needle` appears in
/// `haystack` in order. Empty needle matches everything.
pub fn fuzzyMatch(needle: []const u8, haystack: []const u8) bool {
    var i: usize = 0;
    for (haystack) |h| {
        if (i >= needle.len) break;
        if (asciiLower(h) == asciiLower(needle[i])) i += 1;
    }
    return i == needle.len;
}

/// Write the registry indices matching `query` into `out` (registry order).
/// Returns the count written (capped at `out.len`).
pub fn filter(query: []const u8, out: []usize) usize {
    var n: usize = 0;
    for (commands, 0..) |cmd, idx| {
        if (n >= out.len) break;
        if (fuzzyMatch(query, cmd.name)) {
            out[n] = idx;
            n += 1;
        }
    }
    return n;
}

/// Total number of commands matching `query`.
pub fn matchCount(query: []const u8) usize {
    var n: usize = 0;
    for (commands) |cmd| {
        if (fuzzyMatch(query, cmd.name)) n += 1;
    }
    return n;
}

/// Registry index of the currently-selected command for `pal`, or null when
/// the filter matches nothing (Enter is then a no-op).
pub fn selectedCommand(pal: *const PaletteState) ?usize {
    var buf: [commands.len]usize = undefined;
    const n = filter(pal.queryText(), &buf);
    if (n == 0) return null;
    return buf[@min(pal.selected, n - 1)];
}

/// One rendered row: static name/category slices plus whether it's selected.
pub const Row = struct {
    name: []const u8,
    category: []const u8,
    selected: bool,
};

/// Render-ready snapshot of the palette, sampled into the frame snapshot. Self
/// contained (copied query bytes + static name slices) so a worker thread can
/// read it without touching live `AppState`.
pub const Overlay = struct {
    query: [MAX_QUERY]u8 = undefined,
    query_len: usize = 0,
    rows: [MAX_VISIBLE]Row = undefined,
    row_count: usize = 0,
    /// Total matches (may exceed row_count when the list scrolls).
    total: usize = 0,

    pub fn queryText(self: *const Overlay) []const u8 {
        return self.query[0..self.query_len];
    }
};

/// Build the render-ready overlay from interaction state. Windows the filtered
/// list around the selection so the selected row is always visible.
pub fn buildOverlay(pal: *const PaletteState) Overlay {
    var ov = Overlay{};
    @memcpy(ov.query[0..pal.query_len], pal.query[0..pal.query_len]);
    ov.query_len = pal.query_len;

    var idx_buf: [commands.len]usize = undefined;
    const n = filter(pal.queryText(), &idx_buf);
    ov.total = n;
    if (n == 0) return ov;

    const sel = @min(pal.selected, n - 1);
    // Scroll the visible window to keep `sel` in view.
    var start: usize = 0;
    if (n > MAX_VISIBLE and sel >= MAX_VISIBLE) start = sel - (MAX_VISIBLE - 1);
    const end = @min(start + MAX_VISIBLE, n);

    var r: usize = 0;
    var i = start;
    while (i < end) : (i += 1) {
        const cmd = commands[idx_buf[i]];
        ov.rows[r] = .{ .name = cmd.name, .category = cmd.category, .selected = (i == sel) };
        r += 1;
    }
    ov.row_count = r;
    return ov;
}
