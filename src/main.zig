const std = @import("std");
const config_mod = @import("config.zig");
const wayland_mod = @import("wayland.zig");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");
const renderer_mod = @import("renderer.zig");

const perf = @import("perf.zig");

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

const ghostty_c = @cImport(@cInclude("ghostty/vt.h"));
const xkb_syms = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

/// Find a monospace font. Try config path, then fc-match, then common paths.
fn findFont(allocator: std.mem.Allocator, config_path: []const u8) ![]const u8 {
    // Config-specified font
    if (config_path.len > 0) {
        return try allocator.dupe(u8, config_path);
    }

    // Try fc-match for a monospace font
    {
        const pipe = c.popen("fc-match -f '%{file}' monospace 2>/dev/null", "r");
        if (pipe) |p| {
            defer _ = c.pclose(p);
            var fc_buf: [4096]u8 = undefined;
            const n = c.fread(&fc_buf, 1, fc_buf.len, p);
            if (n > 0) {
                const fc_path = fc_buf[0..n];
                // Verify file exists
                const fc_z = try allocator.dupeZ(u8, fc_path);
                defer allocator.free(fc_z);
                if (c.fopen(fc_z.ptr, "rb")) |fp| {
                    _ = c.fclose(fp);
                    return try allocator.dupe(u8, fc_path);
                }
            }
        }
    }

    // Common system paths
    const fallbacks = [_][]const u8{
        "/usr/share/fonts/TTF/LiberationMono-Regular.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    };
    for (fallbacks) |path| {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        if (c.fopen(path_z.ptr, "rb")) |fp| {
            _ = c.fclose(fp);
            return try allocator.dupe(u8, path);
        }
    }

    return error.NoFontFound;
}

fn readFileC(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fp = c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(fp);

    _ = c.fseek(fp, 0, c.SEEK_END);
    const size_raw = c.ftell(fp);
    if (size_raw < 0) return error.ReadFailed;
    const size: usize = @intCast(size_raw);
    _ = c.fseek(fp, 0, c.SEEK_SET);

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    if (c.fread(buf.ptr, 1, size, fp) != size) return error.ReadFailed;
    return buf;
}

// Shared state for callbacks (avoids closures which aren't possible with C-callable fns)
var g_term: *terminal_mod.Terminal = undefined;
var g_pty: *pty_mod.Pty = undefined;
var g_renderer: *renderer_mod.Renderer = undefined;
var g_wl: *wayland_mod.Wayland = undefined;

fn onKey(ev: wayland_mod.KeyEvent) void {
    if (ev.state == .released) return;

    const utf8 = if (ev.utf8_len > 0) ev.utf8[0..ev.utf8_len] else null;
    const gkey = keysymToGhosttyKey(ev.keysym);

    // Try ghostty encoder for special keys and modified keys.
    // This handles arrow keys, function keys, ctrl+c, etc.
    if (gkey != 0) {
        const encoded = g_term.encodeKey(
            gkey,
            ghostty_c.GHOSTTY_KEY_ACTION_PRESS,
            modsToGhostty(ev.mods),
            utf8,
        );
        if (encoded) |data| {
            g_pty.write(data) catch {};
            return;
        }
    }

    // Fallback: send raw UTF-8 from xkb (handles regular text,
    // and ctrl+key combos where xkb produces the control char directly)
    if (utf8) |text| {
        g_pty.write(text) catch {};
    }
}

fn onResize(w: u32, h: u32) void {
    const grid = g_renderer.computeGridSize(w, h);
    if (grid.cols == 0 or grid.rows == 0) return;

    g_renderer.setViewport(w, h);

    g_term.resize(
        grid.cols,
        grid.rows,
        @intFromFloat(g_renderer.cell_width),
        @intFromFloat(g_renderer.cell_height),
    ) catch {};

    g_pty.resize(grid.cols, grid.rows, w, h);
}

fn onFocus(focused: bool) void {
    // Encode focus event if terminal has focus reporting enabled
    _ = focused;
    // TODO: ghostty_focus_encode
}

pub fn main() !void {
    const startup_timer = perf.Timer.now();
    const allocator = std.heap.smp_allocator;

    // Load config
    var cfg = try config_mod.load(allocator);
    defer cfg.deinit(allocator);

    // Find and load font
    const font_path = try findFont(allocator, cfg.font_path);
    defer allocator.free(font_path);

    const font_data = try readFileC(allocator, font_path);
    defer allocator.free(font_data);

    std.debug.print("mollusk: using font {s}\n", .{font_path});

    // Init Wayland + EGL (need GL context before snail)
    // Start with a rough window size, will resize after font metrics are known
    var wl: wayland_mod.Wayland = undefined;
    try wl.init(800, 600, "mollusk");
    defer wl.deinit();

    // Init renderer (needs active GL context)
    var renderer: renderer_mod.Renderer = undefined;
    try renderer.init(allocator, font_data, cfg.font_size);
    defer renderer.deinit();

    std.debug.print("mollusk: cell size {d:.1}x{d:.1}\n", .{ renderer.cell_width, renderer.cell_height });

    // Compute grid from actual window size
    const grid = renderer.computeGridSize(wl.width, wl.height);
    renderer.setViewport(wl.width, wl.height);

    std.debug.print("mollusk: grid {}x{} in {}x{} window\n", .{ grid.cols, grid.rows, wl.width, wl.height });

    // Init terminal
    var term: terminal_mod.Terminal = undefined;
    try term.init(
        grid.cols,
        grid.rows,
        cfg.max_scrollback,
        cfg.palette,
        cfg.foreground,
        cfg.background,
    );
    defer term.deinit();

    // Spawn PTY
    var pty = try pty_mod.Pty.spawn(cfg.shell, grid.cols, grid.rows);
    defer pty.close();

    // Wire terminal to PTY
    term.pty_fd = pty.master_fd;

    // Set up globals for callbacks
    g_term = &term;
    g_pty = &pty;
    g_renderer = &renderer;
    g_wl = &wl;

    wl.on_key = onKey;
    wl.on_resize = onResize;
    wl.on_focus = onFocus;

    std.debug.print("mollusk: ready ({d:.1}ms startup)\n", .{startup_timer.elapsedMs()});

    // Event loop
    var pty_buf: [65536]u8 = undefined;
    var child_exited = false;
    var has_pty_data = false;
    var first_paint = true;

    while (!wl.closed and !child_exited) {
        wl.flush();

        var pollfds = [_]c.struct_pollfd{
            .{ .fd = wl.displayFd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = pty.master_fd, .events = c.POLLIN, .revents = 0 },
        };

        // Block indefinitely when idle — no CPU burn, no battery drain.
        // Wake on wayland events (input, frame callback) or PTY data.
        _ = c.poll(&pollfds, 2, -1);

        // Handle Wayland events
        if (pollfds[0].revents & c.POLLIN != 0) {
            wl.dispatch() catch break;
        }

        // Handle PTY data — drain all available without blocking
        if (pollfds[1].revents & c.POLLIN != 0) {
            while (true) {
                const n = pty.read(&pty_buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => {
                        child_exited = true;
                        break;
                    },
                };
                if (n == 0) {
                    child_exited = true;
                    break;
                }
                term.feedData(pty_buf[0..n]);
                has_pty_data = true;
            }
        }

        // Check child exit
        if (pty.checkChild()) |_| child_exited = true;

        // Render — only when frame callback allows and we have something to show
        if (!wl.frame_pending) {
            const drew = renderer.drawFrame(&term) catch false;
            if (drew or has_pty_data) {
                wl.swapBuffers();
                wl.requestFrame();
                if (first_paint) {
                    std.debug.print("mollusk: first paint ({d:.1}ms)\n", .{startup_timer.elapsedMs()});
                    first_paint = false;
                }
            }
            has_pty_data = false;
        }
    }

    // Print perf summary
    renderer_mod.Renderer.frame_stats.log("frame");
    std.debug.print("mollusk: exiting\n", .{});
}

fn keysymToGhosttyKey(keysym: u32) c_uint {
    const ks: c_int = @intCast(keysym);
    return @intCast(switch (ks) {
        // Letters
        xkb_syms.XKB_KEY_a...xkb_syms.XKB_KEY_z => ghostty_c.GHOSTTY_KEY_A + (ks - xkb_syms.XKB_KEY_a),
        xkb_syms.XKB_KEY_A...xkb_syms.XKB_KEY_Z => ghostty_c.GHOSTTY_KEY_A + (ks - xkb_syms.XKB_KEY_A),
        // Digits
        xkb_syms.XKB_KEY_0...xkb_syms.XKB_KEY_9 => ghostty_c.GHOSTTY_KEY_DIGIT_0 + (ks - xkb_syms.XKB_KEY_0),
        // Special
        xkb_syms.XKB_KEY_Return => ghostty_c.GHOSTTY_KEY_ENTER,
        xkb_syms.XKB_KEY_KP_Enter => ghostty_c.GHOSTTY_KEY_NUMPAD_ENTER,
        xkb_syms.XKB_KEY_Tab => ghostty_c.GHOSTTY_KEY_TAB,
        xkb_syms.XKB_KEY_ISO_Left_Tab => ghostty_c.GHOSTTY_KEY_TAB,
        xkb_syms.XKB_KEY_BackSpace => ghostty_c.GHOSTTY_KEY_BACKSPACE,
        xkb_syms.XKB_KEY_Escape => ghostty_c.GHOSTTY_KEY_ESCAPE,
        xkb_syms.XKB_KEY_Delete => ghostty_c.GHOSTTY_KEY_DELETE,
        xkb_syms.XKB_KEY_Insert => ghostty_c.GHOSTTY_KEY_INSERT,
        xkb_syms.XKB_KEY_Home => ghostty_c.GHOSTTY_KEY_HOME,
        xkb_syms.XKB_KEY_End => ghostty_c.GHOSTTY_KEY_END,
        xkb_syms.XKB_KEY_Page_Up => ghostty_c.GHOSTTY_KEY_PAGE_UP,
        xkb_syms.XKB_KEY_Page_Down => ghostty_c.GHOSTTY_KEY_PAGE_DOWN,
        xkb_syms.XKB_KEY_Up => ghostty_c.GHOSTTY_KEY_ARROW_UP,
        xkb_syms.XKB_KEY_Down => ghostty_c.GHOSTTY_KEY_ARROW_DOWN,
        xkb_syms.XKB_KEY_Left => ghostty_c.GHOSTTY_KEY_ARROW_LEFT,
        xkb_syms.XKB_KEY_Right => ghostty_c.GHOSTTY_KEY_ARROW_RIGHT,
        // Punctuation / symbols
        xkb_syms.XKB_KEY_space => ghostty_c.GHOSTTY_KEY_SPACE,
        xkb_syms.XKB_KEY_apostrophe => ghostty_c.GHOSTTY_KEY_QUOTE,
        xkb_syms.XKB_KEY_comma => ghostty_c.GHOSTTY_KEY_COMMA,
        xkb_syms.XKB_KEY_minus => ghostty_c.GHOSTTY_KEY_MINUS,
        xkb_syms.XKB_KEY_period => ghostty_c.GHOSTTY_KEY_PERIOD,
        xkb_syms.XKB_KEY_slash => ghostty_c.GHOSTTY_KEY_SLASH,
        xkb_syms.XKB_KEY_semicolon => ghostty_c.GHOSTTY_KEY_SEMICOLON,
        xkb_syms.XKB_KEY_equal => ghostty_c.GHOSTTY_KEY_EQUAL,
        xkb_syms.XKB_KEY_bracketleft => ghostty_c.GHOSTTY_KEY_BRACKET_LEFT,
        xkb_syms.XKB_KEY_bracketright => ghostty_c.GHOSTTY_KEY_BRACKET_RIGHT,
        xkb_syms.XKB_KEY_backslash => ghostty_c.GHOSTTY_KEY_BACKSLASH,
        xkb_syms.XKB_KEY_grave => ghostty_c.GHOSTTY_KEY_BACKQUOTE,
        // Function keys
        xkb_syms.XKB_KEY_F1...xkb_syms.XKB_KEY_F12 => ghostty_c.GHOSTTY_KEY_F1 + (ks - xkb_syms.XKB_KEY_F1),
        xkb_syms.XKB_KEY_F13...xkb_syms.XKB_KEY_F25 => ghostty_c.GHOSTTY_KEY_F13 + (ks - xkb_syms.XKB_KEY_F13),
        // Modifiers — don't produce output, ignore
        xkb_syms.XKB_KEY_Shift_L, xkb_syms.XKB_KEY_Shift_R,
        xkb_syms.XKB_KEY_Control_L, xkb_syms.XKB_KEY_Control_R,
        xkb_syms.XKB_KEY_Alt_L, xkb_syms.XKB_KEY_Alt_R,
        xkb_syms.XKB_KEY_Super_L, xkb_syms.XKB_KEY_Super_R,
        xkb_syms.XKB_KEY_Caps_Lock, xkb_syms.XKB_KEY_Num_Lock,
        => 0,
        else => 0,
    });
}

fn modsToGhostty(mods: wayland_mod.Mods) c_ushort {
    var result: c_ushort = 0;
    if (mods.shift) result |= ghostty_c.GHOSTTY_MODS_SHIFT;
    if (mods.ctrl) result |= ghostty_c.GHOSTTY_MODS_CTRL;
    if (mods.alt) result |= ghostty_c.GHOSTTY_MODS_ALT;
    if (mods.super_) result |= ghostty_c.GHOSTTY_MODS_SUPER;
    return result;
}
