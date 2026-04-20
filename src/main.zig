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
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const ghostty_c = @cImport(@cInclude("ghostty/vt.h"));
const xkb_syms = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

/// mmap a font file — zero copy, stays mapped for process lifetime.
fn mmapFont(path: []const u8) ![]const u8 {
    const path_z = std.heap.smp_allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer std.heap.smp_allocator.free(path_z);

    const fd = c.open(path_z.ptr, c.O_RDONLY);
    if (fd < 0) return error.FileNotFound;

    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) < 0) {
        _ = c.close(fd);
        return error.StatFailed;
    }
    const size: usize = @intCast(st.st_size);

    const map = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    _ = c.close(fd); // fd can be closed after mmap
    if (map == c.MAP_FAILED) return error.MmapFailed;

    const ptr: [*]const u8 = @ptrCast(map);
    return ptr[0..size];
}

const fc = @cImport(@cInclude("fontconfig/fontconfig.h"));

/// Find a monospace font via fontconfig C API (no subprocess).
fn findFontPath(allocator: std.mem.Allocator, config_path: []const u8) ![]const u8 {
    if (config_path.len > 0) return try allocator.dupe(u8, config_path);

    const pattern = fc.FcNameParse("monospace") orelse return error.NoFontFound;
    defer fc.FcPatternDestroy(pattern);

    _ = fc.FcConfigSubstitute(null, pattern, fc.FcMatchPattern);
    fc.FcDefaultSubstitute(pattern);

    var result: fc.FcResult = undefined;
    const match = fc.FcFontMatch(null, pattern, &result) orelse return error.NoFontFound;
    defer fc.FcPatternDestroy(match);

    var file_ptr: [*c]u8 = undefined;
    if (fc.FcPatternGetString(match, fc.FC_FILE, 0, &file_ptr) != fc.FcResultMatch)
        return error.NoFontFound;

    return try allocator.dupe(u8, std.mem.sliceTo(file_ptr, 0));
}

/// Background thread: font discovery + parse + atlas build (all CPU, no GL).
/// Overlaps with EGL init on the main thread.
fn prepThread(renderer: *renderer_mod.Renderer, font_path_out: *[]const u8, cfg_font_path: []const u8, font_size: f32) void {
    const allocator = std.heap.smp_allocator;
    const path = findFontPath(allocator, cfg_font_path) catch return;
    font_path_out.* = path;
    const data = mmapFont(path) catch return;
    renderer.initCpu(allocator, data, font_size) catch return;
}

// Shared state for callbacks
var g_term: *terminal_mod.Terminal = undefined;
var g_pty: *pty_mod.Pty = undefined;
var g_renderer: *renderer_mod.Renderer = undefined;
var g_wl: *wayland_mod.Wayland = undefined;

fn onKey(ev: wayland_mod.KeyEvent) void {
    if (ev.state == .released) return;

    const utf8 = if (ev.utf8_len > 0) ev.utf8[0..ev.utf8_len] else null;

    // If xkb produced UTF-8 (including control chars like \x04 for ctrl+d,
    // \x03 for ctrl+c, \r for Enter, \t for Tab, etc), send it directly.
    // This is correct for standard terminal protocols. The ghostty encoder
    // is only needed for keys that have no UTF-8 representation (arrows,
    // function keys, etc).
    if (utf8) |text| {
        g_pty.write(text) catch {};
        return;
    }

    // No UTF-8 → use ghostty encoder for escape sequences
    const gkey = keysymToGhosttyKey(ev.keysym);
    if (gkey != 0) {
        const encoded = g_term.encodeKey(
            gkey,
            ghostty_c.GHOSTTY_KEY_ACTION_PRESS,
            modsToGhostty(ev.mods),
            null,
        );
        if (encoded) |data| {
            g_pty.write(data) catch {};
        }
    }
}

fn onResize(w: u32, h: u32) void {
    const grid = g_renderer.computeGridSize(w, h);
    if (grid.cols == 0 or grid.rows == 0) return;
    g_renderer.setViewport(w, h);
    g_term.resize(grid.cols, grid.rows, @intFromFloat(g_renderer.cell_width), @intFromFloat(g_renderer.cell_height)) catch {};
    g_pty.resize(grid.cols, grid.rows, w, h);
}

fn onFocus(focused: bool) void {
    _ = focused;
}

pub fn main(init: std.process.Init) !void {
    const startup_timer = perf.Timer.now();
    const allocator = std.heap.smp_allocator;
    _ = init.gpa;

    // Mesa hints — don't override if already set (0 = no overwrite)
    _ = c.setenv("MESA_NO_ERROR", "1", 0); // skip GL error checking
    _ = c.setenv("MESA_DISK_CACHE_SINGLE_FILE", "1", 0); // faster shader cache reads

    // Auto-detect mesa driver via sysfs (no libdrm dependency).
    {
        var driver_buf: [256]u8 = undefined;
        const fp = c.fopen("/sys/class/drm/renderD128/device/driver/module/drivers", "r");
        if (fp) |f| {
            defer _ = c.fclose(f);
            const n = c.fread(&driver_buf, 1, driver_buf.len - 1, f);
            if (n > 0) {
                driver_buf[n] = 0;
                const s = driver_buf[0..n];
                if (std.mem.indexOf(u8, s, "i915") != null or std.mem.indexOf(u8, s, "xe") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "iris", 0)
                else if (std.mem.indexOf(u8, s, "amdgpu") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "radeonsi", 0)
                else if (std.mem.indexOf(u8, s, "nouveau") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "nouveau", 0)
                else if (std.mem.indexOf(u8, s, "nvidia") != null)
                    _ = c.setenv("MESA_LOADER_DRIVER_OVERRIDE", "nvidia", 0);
            }
        }
    }

    // Parse -e flag for command execution
    var exec_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exec_argv.deinit(allocator);
    {
        var args_iter = std.process.Args.Iterator.init(init.minimal.args);
        _ = args_iter.next(); // skip argv[0]
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-e")) {
                // Everything after -e is the command
                while (args_iter.next()) |cmd_arg| {
                    try exec_argv.append(allocator, cmd_arg);
                }
                break;
            }
        }
    }

    // ── Phase 1: config (fast, ~1ms) ──
    var cfg = try config_mod.load(allocator);
    defer cfg.deinit(allocator);

    // ── Phase 2: parallel prep thread + Wayland/EGL ──
    // Prep thread: fontconfig + mmap + font parse + atlas build (~10ms CPU)
    // Main thread: Wayland connect + EGL init (~75ms, driver-bound)
    // The prep thread finishes long before EGL, so CPU work is free.
    var renderer: renderer_mod.Renderer = undefined;
    defer renderer.deinit();
    var font_path: []const u8 = "";
    const prep_thread = try std.Thread.spawn(.{}, prepThread, .{ &renderer, &font_path, cfg.font_path, cfg.font_size });

    var wl: wayland_mod.Wayland = undefined;
    try wl.init(800, 600, "mollusk");
    defer wl.deinit();

    prep_thread.join();
    if (font_path.len == 0) return error.FontLoadFailed;
    defer allocator.free(font_path);

    std.debug.print("mollusk: font {s} ({d:.1}ms)\n", .{ font_path, startup_timer.elapsedMs() });

    // ── Phase 3: GPU init (needs EGL context from main thread + CPU data from prep thread) ──
    try renderer.initGpu();

    // ── Phase 4: now we know the real grid size — fork PTY ──
    const grid = renderer.computeGridSize(wl.width, wl.height);
    renderer.setViewport(wl.width, wl.height);

    var term: terminal_mod.Terminal = undefined;
    try term.init(grid.cols, grid.rows, cfg.max_scrollback, cfg.palette, cfg.foreground, cfg.background);
    defer term.deinit();

    // Fork PTY with correct grid size — no resize needed.
    var pty = if (exec_argv.items.len > 0)
        try pty_mod.Pty.spawnCommand(exec_argv.items, grid.cols, grid.rows)
    else
        try pty_mod.Pty.spawn(cfg.shell, grid.cols, grid.rows);
    defer pty.close();

    term.pty_fd = pty.master_fd;

    // Wire callbacks
    g_term = &term;
    g_pty = &pty;
    g_renderer = &renderer;
    g_wl = &wl;
    wl.on_key = onKey;
    wl.on_resize = onResize;
    wl.on_focus = onFocus;

    std.debug.print("mollusk: {}x{} ready ({d:.1}ms)\n", .{ grid.cols, grid.rows, startup_timer.elapsedMs() });

    // ── Event loop ──
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

        _ = c.poll(&pollfds, 2, -1);

        if (pollfds[0].revents & c.POLLIN != 0) {
            wl.dispatch() catch break;
        }

        if (pollfds[1].revents & c.POLLIN != 0) {
            while (true) {
                const n = pty.read(&pty_buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => { child_exited = true; break; },
                };
                if (n == 0) { child_exited = true; break; }
                term.feedData(pty_buf[0..n]);
                has_pty_data = true;
            }
        }

        if (pty.checkChild()) |_| child_exited = true;

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

    renderer_mod.Renderer.frame_stats.log("frame");
    std.debug.print("mollusk: exiting\n", .{});
}

fn keysymToGhosttyKey(keysym: u32) c_uint {
    const ks: c_int = @intCast(keysym);
    return @intCast(switch (ks) {
        xkb_syms.XKB_KEY_a...xkb_syms.XKB_KEY_z => ghostty_c.GHOSTTY_KEY_A + (ks - xkb_syms.XKB_KEY_a),
        xkb_syms.XKB_KEY_A...xkb_syms.XKB_KEY_Z => ghostty_c.GHOSTTY_KEY_A + (ks - xkb_syms.XKB_KEY_A),
        xkb_syms.XKB_KEY_0...xkb_syms.XKB_KEY_9 => ghostty_c.GHOSTTY_KEY_DIGIT_0 + (ks - xkb_syms.XKB_KEY_0),
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
        xkb_syms.XKB_KEY_F1...xkb_syms.XKB_KEY_F12 => ghostty_c.GHOSTTY_KEY_F1 + (ks - xkb_syms.XKB_KEY_F1),
        xkb_syms.XKB_KEY_F13...xkb_syms.XKB_KEY_F25 => ghostty_c.GHOSTTY_KEY_F13 + (ks - xkb_syms.XKB_KEY_F13),
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
