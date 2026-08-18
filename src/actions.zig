//! The action vocabulary — the single set of things a key chord or a command
//! palette entry can trigger. A std-only leaf so both `palette.zig` (a pure
//! leaf) and `keybindings.zig` (which pulls in xkbcommon/wayland) can share it
//! without either dragging C deps into the other. Dispatch lives in
//! `input.runAction`.

pub const Action = enum {
    open_palette,
    font_increase,
    font_decrease,
    font_reset,
    scroll_line_up,
    scroll_line_down,
    scroll_page_up,
    scroll_page_down,
    scroll_top,
    scroll_bottom,
    copy_selection,
    paste,
    toggle_custom_glyphs,
    toggle_tt_hint,
    swap_renderer,
    kill_renderer,
    force_redraw,
};
