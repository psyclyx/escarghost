const std = @import("std");
const color = @import("color.zig");
const Rgb = color.Rgb;

const c = @cImport({
    @cInclude("ghostty/vt.h");
});

fn ghosttyRgb(rgb: Rgb) c.GhosttyColorRgb {
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

fn fromGhosttyRgb(rgb: c.GhosttyColorRgb) Rgb {
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

pub const Dirty = enum {
    false_,
    partial,
    full,
};

pub const CursorVisualStyle = enum {
    bar,
    block,
    underline,
    block_hollow,
};

pub const CursorInfo = struct {
    visible: bool,
    in_viewport: bool,
    x: u16,
    y: u16,
    style: CursorVisualStyle,
    blinking: bool,
};

pub const CellStyle = extern struct {
    size: usize = @sizeOf(CellStyle),
    fg_color: c.GhosttyStyleColor = .{ .tag = c.GHOSTTY_STYLE_COLOR_NONE, .value = undefined },
    bg_color: c.GhosttyStyleColor = .{ .tag = c.GHOSTTY_STYLE_COLOR_NONE, .value = undefined },
    underline_color: c.GhosttyStyleColor = .{ .tag = c.GHOSTTY_STYLE_COLOR_NONE, .value = undefined },
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: c_int = 0,
};

pub const RenderColors = struct {
    foreground: Rgb,
    background: Rgb,
    cursor: ?Rgb,
    palette: [256]Rgb,
};

pub const Terminal = struct {
    handle: c.GhosttyTerminal,
    render_state: c.GhosttyRenderState,
    row_iterator: c.GhosttyRenderStateRowIterator,
    row_cells: c.GhosttyRenderStateRowCells,
    key_encoder: c.GhosttyKeyEncoder,
    key_event: c.GhosttyKeyEvent,
    mouse_encoder: c.GhosttyMouseEncoder,
    mouse_event: c.GhosttyMouseEvent,

    pty_fd: std.posix.fd_t = -1,
    title: []const u8 = "",

    // Callbacks
    on_bell: ?*const fn () void = null,
    on_title_changed: ?*const fn ([]const u8) void = null,

    /// Approximate bytes-per-row used to translate the caller's
    /// line-oriented scrollback budget into ghostty's byte-oriented
    /// `max_scrollback` field. Ghostty's own default of 10 MB
    /// corresponds to ~10k rows at this ratio, so 1 KB/row matches
    /// upstream's implied baseline. Worst-case (215-col rows packed
    /// with graphemes and per-cell styles) is denser than this;
    /// callers that need a guaranteed line count should size their
    /// `max_scrollback_lines` input with that in mind.
    pub const BYTES_PER_SCROLLBACK_LINE: usize = 1024;

    pub fn init(
        self: *Terminal,
        cols: u16,
        rows: u16,
        max_scrollback_lines: usize,
        palette: [256]Rgb,
        fg: Rgb,
        bg: Rgb,
    ) !void {

        // Create terminal. Ghostty's `max_scrollback` is documented in
        // its C header as "lines" but is actually bytes (its own
        // default is 10 MB). We convert at this single boundary so the
        // rest of scrgo can stay in line-units.
        const max_scrollback_bytes = max_scrollback_lines *| BYTES_PER_SCROLLBACK_LINE;
        const opts: c.GhosttyTerminalOptions = .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = max_scrollback_bytes,
        };
        if (c.ghostty_terminal_new(null, &self.handle, opts) != c.GHOSTTY_SUCCESS)
            return error.TerminalInitFailed;
        errdefer c.ghostty_terminal_free(self.handle);

        // Create render state
        if (c.ghostty_render_state_new(null, &self.render_state) != c.GHOSTTY_SUCCESS)
            return error.RenderStateInitFailed;
        errdefer c.ghostty_render_state_free(self.render_state);

        // Create row iterator
        if (c.ghostty_render_state_row_iterator_new(null, &self.row_iterator) != c.GHOSTTY_SUCCESS)
            return error.RowIteratorInitFailed;
        errdefer c.ghostty_render_state_row_iterator_free(self.row_iterator);

        // Create row cells
        if (c.ghostty_render_state_row_cells_new(null, &self.row_cells) != c.GHOSTTY_SUCCESS)
            return error.RowCellsInitFailed;
        errdefer c.ghostty_render_state_row_cells_free(self.row_cells);

        // Create key encoder + event
        if (c.ghostty_key_encoder_new(null, &self.key_encoder) != c.GHOSTTY_SUCCESS)
            return error.KeyEncoderInitFailed;
        errdefer c.ghostty_key_encoder_free(self.key_encoder);

        if (c.ghostty_key_event_new(null, &self.key_event) != c.GHOSTTY_SUCCESS)
            return error.KeyEventInitFailed;
        errdefer c.ghostty_key_event_free(self.key_event);

        // Create mouse encoder + event
        if (c.ghostty_mouse_encoder_new(null, &self.mouse_encoder) != c.GHOSTTY_SUCCESS)
            return error.MouseEncoderInitFailed;
        errdefer c.ghostty_mouse_encoder_free(self.mouse_encoder);

        if (c.ghostty_mouse_event_new(null, &self.mouse_event) != c.GHOSTTY_SUCCESS)
            return error.MouseEventInitFailed;
        // no more errdefer needed after last init

        self.pty_fd = -1;
        self.title = "";
        self.on_bell = null;
        self.on_title_changed = null;

        // Set colors
        var palette_c: [256]c.GhosttyColorRgb = undefined;
        for (0..256) |i| palette_c[i] = ghosttyRgb(palette[i]);
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette_c);

        var fg_c = ghosttyRgb(fg);
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg_c);

        var bg_c = ghosttyRgb(bg);
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg_c);

        // Register callbacks
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_USERDATA, @ptrCast(self));
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&writePtyCallback));
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_BELL, @ptrCast(&bellCallback));
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @ptrCast(&titleChangedCallback));

    }

    pub fn deinit(self: *Terminal) void {
        c.ghostty_mouse_event_free(self.mouse_event);
        c.ghostty_mouse_encoder_free(self.mouse_encoder);
        c.ghostty_key_event_free(self.key_event);
        c.ghostty_key_encoder_free(self.key_encoder);
        c.ghostty_render_state_row_cells_free(self.row_cells);
        c.ghostty_render_state_row_iterator_free(self.row_iterator);
        c.ghostty_render_state_free(self.render_state);
        c.ghostty_terminal_free(self.handle);
    }

    pub fn feedData(self: *Terminal, data: []const u8) void {
        c.ghostty_terminal_vt_write(self.handle, data.ptr, data.len);
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16, cell_w: u32, cell_h: u32) !void {
        if (c.ghostty_terminal_resize(self.handle, cols, rows, cell_w, cell_h) != c.GHOSTTY_SUCCESS)
            return error.ResizeFailed;
    }

    pub fn colCount(self: *Terminal) u16 {
        var n: u16 = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_COLS, &n);
        return n;
    }

    pub fn rowCount(self: *Terminal) u16 {
        var n: u16 = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_ROWS, &n);
        return n;
    }

    pub const Scrollbar = struct {
        total: u64,
        offset: u64,
        len: u64,
    };

    /// Snapshot the viewport's scroll position. `total` is the total
    /// number of rows including scrollback; `offset` is the topmost
    /// visible row; `len` is the viewport height in rows. When
    /// `total == len` the user is at the bottom with no scrollback.
    pub fn scrollbar(self: *Terminal) Scrollbar {
        var sb: c.GhosttyTerminalScrollbar = .{ .total = 0, .offset = 0, .len = 0 };
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
        return .{ .total = sb.total, .offset = sb.offset, .len = sb.len };
    }


    pub fn updateRenderState(self: *Terminal) !void {
        if (c.ghostty_render_state_update(self.render_state, self.handle) != c.GHOSTTY_SUCCESS)
            return error.RenderStateUpdateFailed;
    }

    /// Get the raw row identity handle for the current row iterator position.
    /// Compare between frames to detect row reuse (scroll detection).
    pub fn getRowId(self: *Terminal) u64 {
        var raw: c.GhosttyRow = 0;
        _ = c.ghostty_render_state_row_get(
            self.row_iterator,
            c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW,
            @ptrCast(&raw),
        );
        return raw;
    }

    pub fn getDirty(self: *Terminal) Dirty {
        var dirty: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
        return switch (dirty) {
            c.GHOSTTY_RENDER_STATE_DIRTY_FALSE => .false_,
            c.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL => .partial,
            c.GHOSTTY_RENDER_STATE_DIRTY_FULL => .full,
            else => .full,
        };
    }

    pub fn resetDirty(self: *Terminal) void {
        var dirty_false: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = c.ghostty_render_state_set(self.render_state, c.GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty_false);

        // Also reset per-row dirty flags
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.row_iterator));
        var row_dirty_false: bool = false;
        while (c.ghostty_render_state_row_iterator_next(self.row_iterator)) {
            _ = c.ghostty_render_state_row_set(
                self.row_iterator,
                c.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
                &row_dirty_false,
            );
        }
    }

    pub fn getColors(self: *Terminal) RenderColors {
        var colors: c.GhosttyRenderStateColors = undefined;
        colors.size = @sizeOf(c.GhosttyRenderStateColors);
        _ = c.ghostty_render_state_colors_get(self.render_state, &colors);

        var result: RenderColors = undefined;
        result.foreground = fromGhosttyRgb(colors.foreground);
        result.background = fromGhosttyRgb(colors.background);
        result.cursor = if (colors.cursor_has_value) fromGhosttyRgb(colors.cursor) else null;
        for (0..256) |i| {
            result.palette[i] = fromGhosttyRgb(colors.palette[i]);
        }
        return result;
    }

    pub fn getCursor(self: *Terminal) CursorInfo {
        var visible: bool = false;
        var in_viewport: bool = false;
        var x: u16 = 0;
        var y: u16 = 0;
        var style: c.GhosttyRenderStateCursorVisualStyle = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        var blinking: bool = false;

        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible);
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &in_viewport);
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x);
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y);
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style);
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking);

        return .{
            .visible = visible,
            .in_viewport = in_viewport,
            .x = x,
            .y = y,
            .style = switch (style) {
                c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => .bar,
                c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK => .block,
                c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => .underline,
                c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => .block_hollow,
                else => .block,
            },
            .blinking = blinking,
        };
    }

    pub fn beginRowIteration(self: *Terminal) void {
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.row_iterator));
    }

    pub fn nextRow(self: *Terminal) bool {
        return c.ghostty_render_state_row_iterator_next(self.row_iterator);
    }

    pub fn isRowDirty(self: *Terminal) bool {
        var dirty: bool = true;
        _ = c.ghostty_render_state_row_get(
            self.row_iterator,
            c.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
            @ptrCast(&dirty),
        );
        return dirty;
    }

    pub fn beginCellIteration(self: *Terminal) void {
        _ = c.ghostty_render_state_row_get(self.row_iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.row_cells));
    }

    pub fn nextCell(self: *Terminal) bool {
        return c.ghostty_render_state_row_cells_next(self.row_cells);
    }

    pub fn selectCell(self: *Terminal, col: u16) bool {
        return c.ghostty_render_state_row_cells_select(self.row_cells, col) == c.GHOSTTY_SUCCESS;
    }

    pub const CellInfo = struct {
        codepoint: u32,
        has_text: bool,
        graphemes_len: u32,
        fg: ?Rgb,
        bg: ?Rgb,
        style: c.GhosttyStyle,
        raw: c.GhosttyCell,
    };

    pub fn getCellInfo(self: *Terminal) CellInfo {
        var graphemes_len: u32 = 0;
        var style: c.GhosttyStyle = undefined;
        style.size = @sizeOf(c.GhosttyStyle);
        var fg_rgb: c.GhosttyColorRgb = undefined;
        var bg_rgb: c.GhosttyColorRgb = undefined;

        // Query fields that always succeed first, then fg/bg separately.
        // get_multi stops at first GHOSTTY_INVALID_VALUE, so a missing fg
        // would prevent bg from being queried.
        const base_keys = [2]c.GhosttyRenderStateRowCellsData{
            c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
            c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
        };
        var base_values = [2]?*anyopaque{
            @ptrCast(&graphemes_len),
            @ptrCast(&style),
        };
        _ = c.ghostty_render_state_row_cells_get_multi(
            self.row_cells, 2, &base_keys, &base_values, null,
        );
        const has_fg = c.ghostty_render_state_row_cells_get(
            self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, @ptrCast(&fg_rgb),
        ) == c.GHOSTTY_SUCCESS;
        const has_bg = c.ghostty_render_state_row_cells_get(
            self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, @ptrCast(&bg_rgb),
        ) == c.GHOSTTY_SUCCESS;

        var info: CellInfo = .{
            .codepoint = 0,
            .has_text = graphemes_len > 0,
            .graphemes_len = graphemes_len,
            .fg = if (has_fg) fromGhosttyRgb(fg_rgb) else null,
            .bg = if (has_bg) fromGhosttyRgb(bg_rgb) else null,
            .style = style,
            .raw = 0,
        };

        if (info.has_text) {
            var cp_buf: [64]u32 = undefined;
            _ = c.ghostty_render_state_row_cells_get(
                self.row_cells,
                c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                &cp_buf,
            );
            info.codepoint = cp_buf[0];
        }

        return info;
    }

    pub fn scrollViewport(self: *Terminal, delta: isize) void {
        c.ghostty_terminal_scroll_viewport(self.handle, .{
            .tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA,
            .value = .{ .delta = @intCast(delta) },
        });
    }

    pub fn scrollToTop(self: *Terminal) void {
        c.ghostty_terminal_scroll_viewport(self.handle, .{
            .tag = c.GHOSTTY_SCROLL_VIEWPORT_TOP,
            .value = .{ .delta = 0 },
        });
    }

    pub fn scrollToBottom(self: *Terminal) void {
        c.ghostty_terminal_scroll_viewport(self.handle, .{
            .tag = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
            .value = .{ .delta = 0 },
        });
    }

    /// Fill `out` with the UTF-32 codepoints of the row at absolute
    /// screen-y `screen_y`, where 0 is the top of the scrollback. Used
    /// by selection text extraction to walk rows that aren't currently
    /// in the viewport (and so aren't reachable from the render state
    /// iterator).
    ///
    /// Cost: one O(scrollback) page-list traversal per row + O(cols)
    /// cheap cell reads, by reusing the page node returned from the
    /// initial grid_ref lookup (grid refs are just (node, x, y); cells
    /// in the same row share node + y).
    pub fn fillRowFromScreen(self: *Terminal, screen_y: u32, out: []u32) usize {
        if (out.len == 0) return 0;
        var ref: c.GhosttyGridRef = .{ .size = @sizeOf(c.GhosttyGridRef), .node = null, .x = 0, .y = 0 };
        const pt: c.GhosttyPoint = .{
            .tag = c.GHOSTTY_POINT_TAG_SCREEN,
            .value = .{ .coordinate = .{ .x = 0, .y = screen_y } },
        };
        if (c.ghostty_terminal_grid_ref(self.handle, pt, &ref) != c.GHOSTTY_SUCCESS) return 0;

        // Walk the row by mutating ref.x. Same node + same y =
        // same row inside the page; only the column changes. Safe
        // as long as no terminal mutation happens between the
        // grid_ref lookup and these reads — we hold the main
        // thread throughout, so callers must not interleave PTY
        // writes between this call and consuming `out`.
        var col: u16 = 0;
        while (col < out.len) : (col += 1) {
            ref.x = col;
            var cell: c.GhosttyCell = 0;
            if (c.ghostty_grid_ref_cell(&ref, &cell) != c.GHOSTTY_SUCCESS) break;
            var has_text: bool = false;
            _ = c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
            if (has_text) {
                var cp: u32 = 0;
                _ = c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_CODEPOINT, &cp);
                out[col] = cp;
            } else {
                out[col] = ' ';
            }
        }
        return col;
    }

    pub fn isBracketedPaste(self: *Terminal) bool {
        var v: bool = false;
        // GHOSTTY_MODE_BRACKETED_PASTE is a non-ANSI mode (DEC 2004);
        // Zig's C translator chokes on the macro because the header
        // uses `false` from <stdbool.h> as a c_int. Encode it manually:
        // low 15 bits = mode value, bit 15 = ansi flag (0 for DEC modes).
        const mode_bracketed_paste: c.GhosttyMode = 2004;
        _ = c.ghostty_terminal_mode_get(self.handle, mode_bracketed_paste, &v);
        return v;
    }

    /// Encode `text` for paste into the PTY. Strips unsafe control
    /// bytes and wraps in bracketed-paste markers when the terminal
    /// has DEC mode 2004 set. Returns a freshly-allocated buffer the
    /// caller owns.
    pub fn encodePaste(self: *Terminal, allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
        const bracketed = self.isBracketedPaste();
        const in_copy = try allocator.alloc(u8, text.len);
        defer allocator.free(in_copy);
        @memcpy(in_copy, text);

        var needed: usize = 0;
        const probe = c.ghostty_paste_encode(in_copy.ptr, in_copy.len, bracketed, null, 0, &needed);
        if (probe != c.GHOSTTY_SUCCESS and probe != c.GHOSTTY_OUT_OF_SPACE) return null;
        const out = try allocator.alloc(u8, needed);
        errdefer allocator.free(out);
        var written: usize = 0;
        const result = c.ghostty_paste_encode(in_copy.ptr, in_copy.len, bracketed, out.ptr, out.len, &written);
        if (result != c.GHOSTTY_SUCCESS) {
            allocator.free(out);
            return null;
        }
        // Trim to the actual encoded length (out may be larger than
        // needed when no bracketing is added).
        if (written < out.len) {
            const trimmed = try allocator.realloc(out, written);
            return trimmed;
        }
        return out;
    }

    // Persistent buffer for encoded key output (avoids dangling stack pointer)
    var encode_buf: [128]u8 = undefined;

    pub fn encodeKey(
        self: *Terminal,
        key: c.GhosttyKey,
        action: c.GhosttyKeyAction,
        mods: c.GhosttyMods,
        utf8: ?[]const u8,
    ) ?[]const u8 {
        // Sync encoder settings from terminal state
        _ = c.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.handle);

        // Set up key event
        _ = c.ghostty_key_event_set_action(self.key_event, action);
        _ = c.ghostty_key_event_set_key(self.key_event, key);
        _ = c.ghostty_key_event_set_mods(self.key_event, mods);
        _ = c.ghostty_key_event_set_composing(self.key_event, false);

        if (utf8) |text| {
            _ = c.ghostty_key_event_set_utf8(self.key_event, text.ptr, text.len);
        } else {
            _ = c.ghostty_key_event_set_utf8(self.key_event, null, 0);
        }

        // Encode into persistent buffer
        var written: usize = 0;
        _ = c.ghostty_key_encoder_encode(self.key_encoder, self.key_event, &encode_buf, encode_buf.len, &written);
        if (written == 0) return null;
        return encode_buf[0..written];
    }

    var mouse_encode_buf: [128]u8 = undefined;

    pub fn encodeMouse(
        self: *Terminal,
        action: c.GhosttyMouseAction,
        button: c.GhosttyMouseButton,
        mods: c.GhosttyMods,
        x: f64,
        y: f64,
    ) ?[]const u8 {
        _ = c.ghostty_mouse_encoder_setopt_from_terminal(self.mouse_encoder, self.handle);

        _ = c.ghostty_mouse_event_set_action(self.mouse_event, action);
        if (action == c.GHOSTTY_MOUSE_ACTION_MOTION) {
            _ = c.ghostty_mouse_event_clear_button(self.mouse_event);
        } else {
            _ = c.ghostty_mouse_event_set_button(self.mouse_event, button);
        }
        _ = c.ghostty_mouse_event_set_mods(self.mouse_event, mods);
        _ = c.ghostty_mouse_event_set_position(self.mouse_event, .{ .x = x, .y = y });

        var written: usize = 0;
        _ = c.ghostty_mouse_encoder_encode(self.mouse_encoder, self.mouse_event, &mouse_encode_buf, mouse_encode_buf.len, &written);
        if (written == 0) return null;
        return mouse_encode_buf[0..written];
    }

    pub fn getTitle(self: *Terminal) []const u8 {
        var title_str: c.GhosttyString = .{ .ptr = null, .len = 0 };
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_TITLE, &title_str);
        if (title_str.ptr) |ptr| {
            return ptr[0..title_str.len];
        }
        return "";
    }

    // ── C-callable callbacks ──

    fn writePtyCallback(_: c.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const self: *Terminal = @ptrCast(@alignCast(userdata));
        if (self.pty_fd >= 0 and data != null) {
            _ = std.c.write(self.pty_fd, data, len);
        }
    }

    fn bellCallback(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Terminal = @ptrCast(@alignCast(userdata));
        if (self.on_bell) |cb| cb();
    }

    fn titleChangedCallback(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Terminal = @ptrCast(@alignCast(userdata));
        if (self.on_title_changed) |cb| cb(self.getTitle());
    }
};
