const std = @import("std");

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xdg-decoration-client-protocol.h");
});

const egl = @cImport({
    @cInclude("EGL/egl.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const gl = @cImport({
    @cInclude("GL/gl.h");
});

pub const KeyEvent = struct {
    keysym: u32,
    utf8: [64]u8 = undefined,
    utf8_len: usize = 0,
    state: enum { pressed, released, repeat },
    mods: Mods,
};

pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super_: bool = false,
};

pub const MouseEvent = struct {
    kind: enum { button_press, button_release, motion, scroll },
    button: u32 = 0,
    x: f64 = 0,
    y: f64 = 0,
    scroll_dx: f64 = 0,
    scroll_dy: f64 = 0,
    mods: Mods = .{},
};

pub const Wayland = struct {
    display: *wl.wl_display,
    registry: *wl.wl_registry,
    compositor: ?*wl.wl_compositor = null,
    xdg_wm_base: ?*wl.xdg_wm_base = null,
    seat: ?*wl.wl_seat = null,
    keyboard: ?*wl.wl_keyboard = null,
    pointer: ?*wl.wl_pointer = null,
    decoration_manager: ?*wl.zxdg_decoration_manager_v1 = null,

    shm: ?*wl.wl_shm = null,
    surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    xdg_toplevel: ?*wl.xdg_toplevel = null,
    decoration: ?*wl.zxdg_toplevel_decoration_v1 = null,
    frame_callback: ?*wl.wl_callback = null,

    egl_display: egl.EGLDisplay = egl.EGL_NO_DISPLAY,
    egl_context: egl.EGLContext = egl.EGL_NO_CONTEXT,
    egl_surface: egl.EGLSurface = egl.EGL_NO_SURFACE,
    egl_config: egl.EGLConfig = null,
    egl_window: ?*wl.wl_egl_window = null,

    xkb_context: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,

    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
    closed: bool = false,
    frame_pending: bool = false,
    focused: bool = false,

    // Callbacks
    on_key: ?*const fn (KeyEvent) void = null,
    on_mouse: ?*const fn (MouseEvent) void = null,
    on_resize: ?*const fn (u32, u32) void = null,
    on_focus: ?*const fn (bool) void = null,

    pub fn init(self: *Wayland, width: u32, height: u32, title: [:0]const u8) !void {
        self.shm = null;
        self.compositor = null;
        self.xdg_wm_base = null;
        self.seat = null;
        self.keyboard = null;
        self.pointer = null;
        self.decoration_manager = null;
        self.decoration = null;
        self.frame_callback = null;
        self.surface = null;
        self.xdg_surface = null;
        self.xdg_toplevel = null;
        self.egl_display = egl.EGL_NO_DISPLAY;
        self.egl_context = egl.EGL_NO_CONTEXT;
        self.egl_surface = egl.EGL_NO_SURFACE;
        self.egl_config = null;
        self.egl_window = null;
        self.xkb_context = null;
        self.xkb_keymap = null;
        self.xkb_state = null;
        self.configured = false;
        self.closed = false;
        self.frame_pending = false;
        self.focused = false;
        self.on_key = null;
        self.on_mouse = null;
        self.on_resize = null;
        self.on_focus = null;
        self.width = width;
        self.height = height;

        // Connect to Wayland
        self.display = wl.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer wl.wl_display_disconnect(self.display);

        self.registry = wl.wl_display_get_registry(self.display) orelse return error.RegistryFailed;
        _ = wl.wl_registry_add_listener(self.registry, &registry_listener, @ptrCast(self));
        _ = wl.wl_display_roundtrip(self.display);

        if (self.compositor == null) return error.NoCompositor;
        if (self.xdg_wm_base == null) return error.NoXdgWmBase;

        // xdg_wm_base ping listener
        _ = wl.xdg_wm_base_add_listener(self.xdg_wm_base.?, &xdg_wm_base_listener, null);

        // Create surface
        self.surface = wl.wl_compositor_create_surface(self.compositor.?) orelse return error.SurfaceFailed;

        // Create xdg surface + toplevel
        self.xdg_surface = wl.xdg_wm_base_get_xdg_surface(self.xdg_wm_base.?, self.surface.?) orelse return error.XdgSurfaceFailed;
        _ = wl.xdg_surface_add_listener(self.xdg_surface.?, &xdg_surface_listener, @ptrCast(self));

        self.xdg_toplevel = wl.xdg_surface_get_toplevel(self.xdg_surface.?) orelse return error.ToplevelFailed;
        _ = wl.xdg_toplevel_add_listener(self.xdg_toplevel.?, &xdg_toplevel_listener, @ptrCast(self));

        wl.xdg_toplevel_set_title(self.xdg_toplevel.?, title.ptr);
        wl.xdg_toplevel_set_app_id(self.xdg_toplevel.?, "mollusk");

        // Request server-side decorations
        if (self.decoration_manager) |dm| {
            self.decoration = wl.zxdg_decoration_manager_v1_get_toplevel_decoration(dm, self.xdg_toplevel.?);
            if (self.decoration) |dec| {
                wl.zxdg_toplevel_decoration_v1_set_mode(dec, wl.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
            }
        }

        // Init xkbcommon (must be before roundtrip since keymap event fires during dispatch)
        self.xkb_context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
        self.xkb_keymap = null;
        self.xkb_state = null;

        // Commit to trigger configure, wait for it
        wl.wl_surface_commit(self.surface.?);
        while (!self.configured) {
            if (wl.wl_display_roundtrip(self.display) < 0) return error.DispatchFailed;
        }
    }

    /// Initialize EGL. Separate from init() so caller can do work between
    /// Wayland setup and EGL (e.g. fork PTY while EGL driver initializes).
    pub fn initEglPublic(self: *Wayland) !void {
        try self.initEgl();
    }

    fn initEgl(self: *Wayland) !void {
        // Use eglGetPlatformDisplay (EGL 1.5) to skip platform detection probing.
        // EGL_PLATFORM_WAYLAND_KHR = 0x31D8
        const eglGetPlatformDisplay_ = @as(
            ?*const fn (u32, ?*anyopaque, ?[*]const egl.EGLAttrib) callconv(.c) egl.EGLDisplay,
            @ptrCast(egl.eglGetProcAddress("eglGetPlatformDisplay")),
        );
        if (eglGetPlatformDisplay_) |getPlatformDisplay| {
            self.egl_display = getPlatformDisplay(0x31D8, @ptrCast(self.display), null);
        } else {
            self.egl_display = egl.eglGetDisplay(@ptrCast(self.display));
        }
        if (self.egl_display == egl.EGL_NO_DISPLAY) return error.EglDisplayFailed;

        var major: egl.EGLint = 0;
        var minor: egl.EGLint = 0;
        if (egl.eglInitialize(self.egl_display, &major, &minor) == egl.EGL_FALSE)
            return error.EglInitFailed;

        _ = egl.eglBindAPI(egl.EGL_OPENGL_API);

        // Try MSAA 4x first for smoother edges, fall back to no MSAA
        const base_attribs = [_]egl.EGLint{
            egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
            egl.EGL_RED_SIZE,        8,
            egl.EGL_GREEN_SIZE,      8,
            egl.EGL_BLUE_SIZE,       8,
            egl.EGL_ALPHA_SIZE,      8,
            egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
        };
        const msaa_attribs = base_attribs ++ [_]egl.EGLint{
            egl.EGL_SAMPLE_BUFFERS, 1,
            egl.EGL_SAMPLES,        4,
            egl.EGL_NONE,
        };
        const plain_attribs = base_attribs ++ [_]egl.EGLint{
            egl.EGL_NONE,
        };

        var num_configs: egl.EGLint = 0;
        _ = egl.eglChooseConfig(self.egl_display, &msaa_attribs, &self.egl_config, 1, &num_configs);
        if (num_configs == 0) {
            if (egl.eglChooseConfig(self.egl_display, &plain_attribs, &self.egl_config, 1, &num_configs) == egl.EGL_FALSE)
                return error.EglConfigFailed;
        }
        if (num_configs == 0) return error.EglNoConfig;

        // Try GL 4.4 first (enables persistent mapped VBOs in snail), fall back to 3.3
        const gl44_attribs = [_]egl.EGLint{
            egl.EGL_CONTEXT_MAJOR_VERSION, 4,
            egl.EGL_CONTEXT_MINOR_VERSION, 4,
            egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            egl.EGL_NONE,
        };
        const gl33_attribs = [_]egl.EGLint{
            egl.EGL_CONTEXT_MAJOR_VERSION, 3,
            egl.EGL_CONTEXT_MINOR_VERSION, 3,
            egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            egl.EGL_NONE,
        };

        self.egl_context = egl.eglCreateContext(self.egl_display, self.egl_config, egl.EGL_NO_CONTEXT, &gl44_attribs);
        if (self.egl_context == egl.EGL_NO_CONTEXT) {
            self.egl_context = egl.eglCreateContext(self.egl_display, self.egl_config, egl.EGL_NO_CONTEXT, &gl33_attribs);
        }
        if (self.egl_context == egl.EGL_NO_CONTEXT) return error.EglContextFailed;

        self.egl_window = wl.wl_egl_window_create(self.surface.?, @intCast(self.width), @intCast(self.height));
        if (self.egl_window == null) return error.EglWindowFailed;

        self.egl_surface = egl.eglCreateWindowSurface(self.egl_display, self.egl_config, @intFromPtr(self.egl_window.?), null);
        if (self.egl_surface == egl.EGL_NO_SURFACE) return error.EglSurfaceFailed;

        if (egl.eglMakeCurrent(self.egl_display, self.egl_surface, self.egl_surface, self.egl_context) == egl.EGL_FALSE)
            return error.EglMakeCurrentFailed;

        _ = egl.eglSwapInterval(self.egl_display, 0);
    }

    pub fn deinit(self: *Wayland) void {
        if (self.xkb_state) |s| xkb.xkb_state_unref(s);
        if (self.xkb_keymap) |k| xkb.xkb_keymap_unref(k);
        if (self.xkb_context) |ctx| xkb.xkb_context_unref(ctx);

        if (self.egl_display != egl.EGL_NO_DISPLAY) {
            _ = egl.eglMakeCurrent(self.egl_display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);
            if (self.egl_surface != egl.EGL_NO_SURFACE) _ = egl.eglDestroySurface(self.egl_display, self.egl_surface);
            if (self.egl_context != egl.EGL_NO_CONTEXT) _ = egl.eglDestroyContext(self.egl_display, self.egl_context);
            _ = egl.eglTerminate(self.egl_display);
        }
        if (self.egl_window) |w| wl.wl_egl_window_destroy(w);

        if (self.frame_callback) |cb| wl.wl_callback_destroy(cb);
        if (self.decoration) |d| wl.zxdg_toplevel_decoration_v1_destroy(d);
        if (self.xdg_toplevel) |tl| wl.xdg_toplevel_destroy(tl);
        if (self.xdg_surface) |xs| wl.xdg_surface_destroy(xs);
        if (self.surface) |s| wl.wl_surface_destroy(s);
        if (self.pointer) |p| wl.wl_pointer_destroy(p);
        if (self.keyboard) |k| wl.wl_keyboard_destroy(k);

        wl.wl_display_disconnect(self.display);
    }

    pub fn displayFd(self: *Wayland) std.posix.fd_t {
        return wl.wl_display_get_fd(self.display);
    }

    pub fn dispatch(self: *Wayland) !void {
        if (wl.wl_display_dispatch(self.display) < 0) return error.DispatchFailed;
    }

    pub fn flush(self: *Wayland) void {
        _ = wl.wl_display_flush(self.display);
    }

    pub fn swapBuffers(self: *Wayland) void {
        _ = egl.eglSwapBuffers(self.egl_display, self.egl_surface);
    }

    pub fn requestFrame(self: *Wayland) void {
        if (self.frame_pending) return;
        self.frame_callback = wl.wl_surface_frame(self.surface.?);
        if (self.frame_callback) |cb| {
            _ = wl.wl_callback_add_listener(cb, &frame_listener, @ptrCast(self));
            self.frame_pending = true;
        }
        wl.wl_surface_commit(self.surface.?);
    }

    pub fn resizeEgl(self: *Wayland, w: u32, h: u32) void {
        self.width = w;
        self.height = h;
        // Only resize if EGL is already initialized
        if (self.egl_window) |win| {
            wl.wl_egl_window_resize(win, @intCast(w), @intCast(h), 0, 0);
            gl.glViewport(0, 0, @intCast(w), @intCast(h));
        }
    }

    pub fn setTitle(self: *Wayland, title: [:0]const u8) void {
        if (self.xdg_toplevel) |tl| {
            wl.xdg_toplevel_set_title(tl, title.ptr);
        }
    }

    // ── Wayland listeners ──

    const registry_listener = wl.wl_registry_listener{
        .global = registryGlobal,
        .global_remove = registryGlobalRemove,
    };

    fn registryGlobal(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        const iface = std.mem.span(interface);

        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            self.xdg_wm_base = @ptrCast(wl.wl_registry_bind(registry, name, &wl.xdg_wm_base_interface, @min(version, 2)));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_seat_interface, @min(version, 5)));
            if (self.seat) |seat| {
                _ = wl.wl_seat_add_listener(seat, &seat_listener, @ptrCast(self));
            }
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
            self.decoration_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.zxdg_decoration_manager_v1_interface, 1));
        }
    }

    fn registryGlobalRemove(_: ?*anyopaque, _: ?*wl.wl_registry, _: u32) callconv(.c) void {}

    // ── xdg_wm_base ──

    const xdg_wm_base_listener = wl.xdg_wm_base_listener{
        .ping = xdgWmBasePing,
    };

    fn xdgWmBasePing(_: ?*anyopaque, wm_base: ?*wl.xdg_wm_base, serial: u32) callconv(.c) void {
        wl.xdg_wm_base_pong(wm_base, serial);
    }

    // ── xdg_surface ──

    const xdg_surface_listener = wl.xdg_surface_listener{
        .configure = xdgSurfaceConfigure,
    };

    fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surf: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        wl.xdg_surface_ack_configure(xdg_surf, serial);
        self.configured = true;
    }

    // ── xdg_toplevel ──

    const xdg_toplevel_listener = wl.xdg_toplevel_listener{
        .configure = xdgToplevelConfigure,
        .close = xdgToplevelClose,
        .configure_bounds = xdgToplevelConfigureBounds,
        .wm_capabilities = xdgToplevelWmCapabilities,
    };

    fn xdgToplevelConfigure(data: ?*anyopaque, _: ?*wl.xdg_toplevel, width: i32, height: i32, _: ?*wl.wl_array) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        if (width > 0 and height > 0) {
            const w: u32 = @intCast(width);
            const h: u32 = @intCast(height);
            // Store new dimensions; only do EGL resize if EGL is initialized
            if (w != self.width or h != self.height) {
                self.width = w;
                self.height = h;
                if (self.egl_window != null) {
                    self.resizeEgl(w, h);
                    if (self.on_resize) |cb| cb(w, h);
                }
            }
        }
    }

    fn xdgToplevelClose(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        self.closed = true;
    }

    fn xdgToplevelConfigureBounds(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
    fn xdgToplevelWmCapabilities(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: ?*wl.wl_array) callconv(.c) void {}

    // ── wl_seat ──

    const seat_listener = wl.wl_seat_listener{
        .capabilities = seatCapabilities,
        .name = seatName,
    };

    fn seatCapabilities(data: ?*anyopaque, seat: ?*wl.wl_seat, caps: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));

        if (caps & wl.WL_SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard == null) {
            self.keyboard = wl.wl_seat_get_keyboard(seat);
            if (self.keyboard) |kb| {
                _ = wl.wl_keyboard_add_listener(kb, &keyboard_listener, @ptrCast(self));
            }
        }
        if (caps & wl.WL_SEAT_CAPABILITY_POINTER != 0 and self.pointer == null) {
            self.pointer = wl.wl_seat_get_pointer(seat);
            if (self.pointer) |ptr| {
                _ = wl.wl_pointer_add_listener(ptr, &pointer_listener, @ptrCast(self));
            }
        }
    }

    fn seatName(_: ?*anyopaque, _: ?*wl.wl_seat, _: [*c]const u8) callconv(.c) void {}

    // ── wl_keyboard ──

    const keyboard_listener = wl.wl_keyboard_listener{
        .keymap = keyboardKeymap,
        .enter = keyboardEnter,
        .leave = keyboardLeave,
        .key = keyboardKey,
        .modifiers = keyboardModifiers,
        .repeat_info = keyboardRepeatInfo,
    };

    fn keyboardKeymap(data: ?*anyopaque, _: ?*wl.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        defer _ = std.c.close(fd);

        if (format != wl.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;

        const c_mmap = @cImport(@cInclude("sys/mman.h"));
        const map = c_mmap.mmap(null, size, c_mmap.PROT_READ, c_mmap.MAP_PRIVATE, fd, 0);
        if (map == c_mmap.MAP_FAILED) return;
        defer _ = c_mmap.munmap(map, size);

        const new_keymap = xkb.xkb_keymap_new_from_buffer(
            self.xkb_context,
            @ptrCast(map),
            size - 1,
            xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
            xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return;

        const new_state = xkb.xkb_state_new(new_keymap) orelse {
            xkb.xkb_keymap_unref(new_keymap);
            return;
        };

        if (self.xkb_state) |s| xkb.xkb_state_unref(s);
        if (self.xkb_keymap) |k| xkb.xkb_keymap_unref(k);
        self.xkb_keymap = new_keymap;
        self.xkb_state = new_state;
    }

    fn keyboardEnter(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface, _: ?*wl.wl_array) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        self.focused = true;
        if (self.on_focus) |cb| cb(true);
    }

    fn keyboardLeave(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        self.focused = false;
        if (self.on_focus) |cb| cb(false);
    }

    fn keyboardKey(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        const xkb_state = self.xkb_state orelse return;

        const keycode = key + 8; // evdev offset
        const keysym = xkb.xkb_state_key_get_one_sym(xkb_state, keycode);

        var ev: KeyEvent = .{
            .keysym = keysym,
            .state = if (state == wl.WL_KEYBOARD_KEY_STATE_PRESSED) .pressed else .released,
            .mods = self.getCurrentMods(),
        };

        // Get UTF-8 text
        const n = xkb.xkb_state_key_get_utf8(xkb_state, keycode, &ev.utf8, ev.utf8.len);
        ev.utf8_len = if (n >= 0) @intCast(@min(@as(usize, @intCast(n)), ev.utf8.len)) else 0;

        // Don't filter control characters — Enter (\r), Tab (\t), etc.
        // need to reach the key handler for proper encoding.

        if (self.on_key) |cb| cb(ev);
    }

    fn keyboardModifiers(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        if (self.xkb_state) |state| {
            _ = xkb.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
        }
    }

    fn keyboardRepeatInfo(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

    fn getCurrentMods(self: *Wayland) Mods {
        const state = self.xkb_state orelse return .{};
        return .{
            .shift = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_SHIFT, xkb.XKB_STATE_MODS_EFFECTIVE) == 1,
            .ctrl = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_CTRL, xkb.XKB_STATE_MODS_EFFECTIVE) == 1,
            .alt = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_ALT, xkb.XKB_STATE_MODS_EFFECTIVE) == 1,
            .super_ = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_LOGO, xkb.XKB_STATE_MODS_EFFECTIVE) == 1,
        };
    }

    // ── wl_pointer ──

    const pointer_listener = wl.wl_pointer_listener{
        .enter = pointerEnter,
        .leave = pointerLeave,
        .motion = pointerMotion,
        .button = pointerButton,
        .axis = pointerAxis,
        .frame = pointerFrame,
        .axis_source = pointerAxisSource,
        .axis_stop = pointerAxisStop,
        .axis_discrete = pointerAxisDiscrete,
        .axis_value120 = pointerAxisValue120,
        .axis_relative_direction = pointerAxisRelativeDirection,
    };

    fn pointerEnter(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface, _: i32, _: i32) callconv(.c) void {}
    fn pointerLeave(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface) callconv(.c) void {}

    fn pointerMotion(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, sx: i32, sy: i32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        if (self.on_mouse) |cb| cb(.{
            .kind = .motion,
            .x = @as(f64, @floatFromInt(sx)) / 256.0,
            .y = @as(f64, @floatFromInt(sy)) / 256.0,
        });
    }

    fn pointerButton(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        if (self.on_mouse) |cb| cb(.{
            .kind = if (state == wl.WL_POINTER_BUTTON_STATE_PRESSED) .button_press else .button_release,
            .button = button,
        });
    }

    fn pointerAxis(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, axis: u32, value: i32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        const v = @as(f64, @floatFromInt(value)) / 256.0;
        if (self.on_mouse) |cb| cb(.{
            .kind = .scroll,
            .scroll_dx = if (axis == wl.WL_POINTER_AXIS_HORIZONTAL_SCROLL) v else 0,
            .scroll_dy = if (axis == wl.WL_POINTER_AXIS_VERTICAL_SCROLL) v else 0,
        });
    }

    fn pointerFrame(_: ?*anyopaque, _: ?*wl.wl_pointer) callconv(.c) void {}
    fn pointerAxisSource(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32) callconv(.c) void {}
    fn pointerAxisStop(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn pointerAxisDiscrete(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn pointerAxisValue120(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn pointerAxisRelativeDirection(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}

    // ── Frame callback ──

    const frame_listener = wl.wl_callback_listener{
        .done = frameDone,
    };

    fn frameDone(data: ?*anyopaque, callback: ?*wl.wl_callback, _: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        if (callback) |cb| wl.wl_callback_destroy(cb);
        self.frame_callback = null;
        self.frame_pending = false;
    }
};
