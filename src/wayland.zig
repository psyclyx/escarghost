const std = @import("std");
const render_env = @import("render_env.zig");

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xdg-decoration-client-protocol.h");
    @cInclude("viewporter-client-protocol.h");
    @cInclude("single-pixel-buffer-v1-client-protocol.h");
    @cInclude("linux-dmabuf-unstable-v1-client-protocol.h");
});

const egl = @cImport({
    @cInclude("EGL/egl.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

fn rendererLogEnabled() bool {
    if (std.c.getenv("SCRGO_LOG")) |value| {
        const options = render_env.parseRendererDebug(std.mem.sliceTo(value, 0));
        return options.startup or options.renderers;
    }
    return false;
}

const time_c = @cImport(@cInclude("time.h"));

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

pub const PendingMods = struct {
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
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
    viewporter: ?*wl.wp_viewporter = null,
    single_pixel_buffer_manager: ?*wl.wp_single_pixel_buffer_manager_v1 = null,
    linux_dmabuf: ?*wl.zwp_linux_dmabuf_v1 = null,

    shm: ?*wl.wl_shm = null,
    surface: ?*wl.wl_surface = null,
    viewport: ?*wl.wp_viewport = null,
    solid_background_buffer: ?*wl.wl_buffer = null,
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
    // mmap'd keymap text from the compositor, owned by us, parsed lazily on
    // first key event. xkb_keymap_new_from_buffer is ~12% of total startup
    // cycles, and compositors push the keymap (and a modifier event) on
    // initial seat bind whether the surface ever gets focus or not — so for
    // short-lived sessions that never see a key press, the parse is waste.
    keymap_buf: ?[]const u8 = null,
    pending_mods: ?PendingMods = null,

    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
    closed: bool = false,
    frame_pending: bool = false,
    focused: bool = false,

    // Key repeat state
    repeat_rate: u32 = 25, // keys/sec (from compositor)
    repeat_delay: u32 = 600, // ms (from compositor)
    repeat_key: ?KeyEvent = null, // currently repeating key
    repeat_deadline_ns: i128 = 0, // next repeat fire time

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
        self.viewporter = null;
        self.single_pixel_buffer_manager = null;
        self.linux_dmabuf = null;
        self.decoration = null;
        self.frame_callback = null;
        self.surface = null;
        self.viewport = null;
        self.solid_background_buffer = null;
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
        self.repeat_rate = 25;
        self.repeat_delay = 600;
        self.repeat_key = null;
        self.repeat_deadline_ns = 0;
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
        wl.xdg_toplevel_set_app_id(self.xdg_toplevel.?, "scrgo");

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

    /// EGL Phase 1: display + context. Kept separate from initEglSurface()
    /// so startup can show a first frame before paying the EGL setup cost.
    pub fn initEglContext(self: *Wayland) !void {
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

        const base = [_]egl.EGLint{
            egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
            egl.EGL_RED_SIZE,        8,
            egl.EGL_GREEN_SIZE,      8,
            egl.EGL_BLUE_SIZE,       8,
            egl.EGL_ALPHA_SIZE,      8,
            egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
        };
        const msaa = base ++ [_]egl.EGLint{ egl.EGL_SAMPLE_BUFFERS, 1, egl.EGL_SAMPLES, 4, egl.EGL_NONE };
        const plain = base ++ [_]egl.EGLint{egl.EGL_NONE};

        var num: egl.EGLint = 0;
        _ = egl.eglChooseConfig(self.egl_display, &msaa, &self.egl_config, 1, &num);
        if (num == 0) {
            if (egl.eglChooseConfig(self.egl_display, &plain, &self.egl_config, 1, &num) == egl.EGL_FALSE)
                return error.EglConfigFailed;
        }
        if (num == 0) return error.EglNoConfig;

        const gl44 = [_]egl.EGLint{ egl.EGL_CONTEXT_MAJOR_VERSION, 4, egl.EGL_CONTEXT_MINOR_VERSION, 4, egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, egl.EGL_NONE };
        const gl33 = [_]egl.EGLint{ egl.EGL_CONTEXT_MAJOR_VERSION, 3, egl.EGL_CONTEXT_MINOR_VERSION, 3, egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, egl.EGL_NONE };

        self.egl_context = egl.eglCreateContext(self.egl_display, self.egl_config, egl.EGL_NO_CONTEXT, &gl44);
        if (self.egl_context == egl.EGL_NO_CONTEXT)
            self.egl_context = egl.eglCreateContext(self.egl_display, self.egl_config, egl.EGL_NO_CONTEXT, &gl33);
        if (self.egl_context == egl.EGL_NO_CONTEXT) return error.EglContextFailed;
    }

    /// EGL Phase 2: window surface + make current. Must be called on the
    /// main thread after initEglContext() completes and wl_surface exists.
    pub fn initEglSurface(self: *Wayland) !void {
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
        self.unmapKeymapBuf();

        if (self.egl_display != egl.EGL_NO_DISPLAY) {
            _ = egl.eglMakeCurrent(self.egl_display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);
            if (self.egl_surface != egl.EGL_NO_SURFACE) _ = egl.eglDestroySurface(self.egl_display, self.egl_surface);
            if (self.egl_context != egl.EGL_NO_CONTEXT) _ = egl.eglDestroyContext(self.egl_display, self.egl_context);
            _ = egl.eglTerminate(self.egl_display);
        }
        if (self.egl_window) |w| wl.wl_egl_window_destroy(w);

        if (self.frame_callback) |cb| wl.wl_callback_destroy(cb);
        if (self.solid_background_buffer) |buffer| wl.wl_buffer_destroy(buffer);
        if (self.viewport) |vp| wl.wp_viewport_destroy(vp);
        if (self.decoration) |d| wl.zxdg_toplevel_decoration_v1_destroy(d);
        if (self.xdg_toplevel) |tl| wl.xdg_toplevel_destroy(tl);
        if (self.xdg_surface) |xs| wl.xdg_surface_destroy(xs);
        if (self.surface) |s| wl.wl_surface_destroy(s);
        if (self.single_pixel_buffer_manager) |mgr| wl.wp_single_pixel_buffer_manager_v1_destroy(mgr);
        if (self.linux_dmabuf) |linux_dmabuf| wl.zwp_linux_dmabuf_v1_destroy(linux_dmabuf);
        if (self.viewporter) |viewporter| wl.wp_viewporter_destroy(viewporter);
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

    pub fn dispatchPending(self: *Wayland) !void {
        if (wl.wl_display_dispatch_pending(self.display) < 0) return error.DispatchFailed;
    }

    pub fn prepareRead(self: *Wayland) bool {
        return wl.wl_display_prepare_read(self.display) == 0;
    }

    pub fn cancelRead(self: *Wayland) void {
        wl.wl_display_cancel_read(self.display);
    }

    pub fn readEvents(self: *Wayland) !void {
        if (wl.wl_display_read_events(self.display) < 0) return error.DispatchFailed;
    }

    pub fn flush(self: *Wayland) void {
        _ = wl.wl_display_flush(self.display);
    }

    fn ensureViewport(self: *Wayland) ?*wl.wp_viewport {
        if (self.viewport) |viewport| return viewport;
        const viewporter = self.viewporter orelse return null;
        const surface = self.surface orelse return null;
        self.viewport = wl.wp_viewporter_get_viewport(viewporter, surface);
        return self.viewport;
    }

    fn expand8ToU32(value: u8) u32 {
        return @as(u32, value) * 0x01010101;
    }

    pub fn commitSolidBackground(self: *Wayland, r: u8, g: u8, b: u8, a: u8) bool {
        const manager = self.single_pixel_buffer_manager orelse return false;
        const surface = self.surface orelse return false;
        const viewport = self.ensureViewport() orelse return false;
        if (self.solid_background_buffer != null) return false;
        const buffer = wl.wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(
            manager,
            expand8ToU32(r),
            expand8ToU32(g),
            expand8ToU32(b),
            expand8ToU32(a),
        ) orelse return false;
        _ = wl.wl_buffer_add_listener(buffer, &solid_background_buffer_listener, @ptrCast(self));
        self.solid_background_buffer = buffer;

        wl.wp_viewport_set_destination(viewport, @intCast(self.width), @intCast(self.height));
        wl.wl_surface_set_buffer_transform(surface, wl.WL_OUTPUT_TRANSFORM_NORMAL);
        wl.wl_surface_attach(surface, buffer, 0, 0);
        wl.wl_surface_damage_buffer(surface, 0, 0, 1, 1);
        wl.wl_surface_commit(surface);
        _ = wl.wl_display_flush(self.display);
        return true;
    }

    pub fn clearSurfaceScaling(self: *Wayland) void {
        if (self.viewport) |viewport| {
            wl.wp_viewport_set_destination(viewport, -1, -1);
        }
    }

    const solid_background_buffer_listener = wl.wl_buffer_listener{
        .release = solidBackgroundBufferRelease,
    };

    fn solidBackgroundBufferRelease(data: ?*anyopaque, buffer: ?*wl.wl_buffer) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        if (self.solid_background_buffer == buffer) {
            wl.wl_buffer_destroy(buffer);
            self.solid_background_buffer = null;
        }
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

    /// Check and fire key repeat. Returns ms until next repeat (for poll timeout).
    pub fn pumpRepeat(self: *Wayland) ?u32 {
        const key = self.repeat_key orelse return null;
        if (self.repeat_rate == 0) return null;

        var ts: time_c.struct_timespec = undefined;
        _ = time_c.clock_gettime(time_c.CLOCK_MONOTONIC, &ts);
        const now_ns: i128 = @as(i128, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;

        if (now_ns >= self.repeat_deadline_ns) {
            // Fire repeat
            var repeat_ev = key;
            repeat_ev.state = .repeat;
            if (self.on_key) |cb| cb(repeat_ev);

            // Schedule next repeat
            const interval_ns: i128 = @divTrunc(1_000_000_000, @as(i128, self.repeat_rate));
            self.repeat_deadline_ns = now_ns + interval_ns;
            return @intCast(@divTrunc(interval_ns, 1_000_000));
        }

        // Return ms until next fire
        const remaining = self.repeat_deadline_ns - now_ns;
        return @intCast(@max(1, @divTrunc(remaining, 1_000_000)));
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
        } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
            self.viewporter = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wp_viewporter_interface, 1));
        } else if (std.mem.eql(u8, iface, "wp_single_pixel_buffer_manager_v1")) {
            self.single_pixel_buffer_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wp_single_pixel_buffer_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, iface, "zwp_linux_dmabuf_v1")) {
            self.linux_dmabuf = @ptrCast(wl.wl_registry_bind(registry, name, &wl.zwp_linux_dmabuf_v1_interface, @min(version, 3)));
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
            if (w != self.width or h != self.height) {
                self.width = w;
                self.height = h;
                if (self.egl_window != null) self.resizeEgl(w, h);
                if (self.on_resize) |cb| cb(w, h);
            }
            // The bg commit attached a 1px buffer scaled via wp_viewport
            // to (initial_width, initial_height). Once the compositor
            // gives us the real size we want our render buffers (always
            // sized to surface) composited 1:1; clear the viewport
            // destination so it doesn't downscale them.
            self.clearSurfaceScaling();
        }
    }

    fn xdgToplevelClose(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        if (rendererLogEnabled()) {
            std.debug.print("scrgo: received xdg_toplevel.close\n", .{});
        }
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

        // Discard any prior parsed state and mapping; we'll parse the new
        // keymap on demand via ensureKeymapParsed when a key/modifier
        // event arrives.
        if (self.xkb_state) |s| { xkb.xkb_state_unref(s); self.xkb_state = null; }
        if (self.xkb_keymap) |k| { xkb.xkb_keymap_unref(k); self.xkb_keymap = null; }
        self.unmapKeymapBuf();

        const c_mmap = @cImport(@cInclude("sys/mman.h"));
        const map = c_mmap.mmap(null, size, c_mmap.PROT_READ, c_mmap.MAP_PRIVATE, fd, 0);
        if (map == c_mmap.MAP_FAILED) return;
        self.keymap_buf = @as([*]const u8, @ptrCast(map))[0..size];
    }

    fn unmapKeymapBuf(self: *Wayland) void {
        const buf = self.keymap_buf orelse return;
        const c_mmap = @cImport(@cInclude("sys/mman.h"));
        _ = c_mmap.munmap(@constCast(@ptrCast(buf.ptr)), buf.len);
        self.keymap_buf = null;
    }

    fn ensureKeymapParsed(self: *Wayland) bool {
        if (self.xkb_keymap != null) return true;
        const buf = self.keymap_buf orelse return false;
        const km = xkb.xkb_keymap_new_from_buffer(
            self.xkb_context,
            buf.ptr,
            buf.len - 1, // strip trailing NUL the compositor includes
            xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
            xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return false;
        const state = xkb.xkb_state_new(km) orelse {
            xkb.xkb_keymap_unref(km);
            return false;
        };
        self.xkb_keymap = km;
        self.xkb_state = state;
        // Apply any modifier state the compositor delivered before this point.
        if (self.pending_mods) |m| {
            _ = xkb.xkb_state_update_mask(state, m.depressed, m.latched, m.locked, 0, 0, m.group);
            self.pending_mods = null;
        }
        return true;
    }

    fn keyboardEnter(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface, _: ?*wl.wl_array) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        self.focused = true;
        if (self.on_focus) |cb| cb(true);
    }

    fn keyboardLeave(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        self.focused = false;
        self.repeat_key = null;
        if (self.on_focus) |cb| cb(false);
    }

    fn keyboardKey(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        if (!self.ensureKeymapParsed()) return;
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

        // Track key repeat
        if (ev.state == .pressed and self.repeat_rate > 0) {
            self.repeat_key = ev;
            // First repeat after delay
            var ts: time_c.struct_timespec = undefined;
            _ = time_c.clock_gettime(time_c.CLOCK_MONOTONIC, &ts);
            const now_ns: i128 = @as(i128, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
            self.repeat_deadline_ns = now_ns + @as(i128, self.repeat_delay) * 1_000_000;
        } else if (ev.state == .released) {
            self.repeat_key = null;
        }
    }

    fn keyboardModifiers(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        // Stash; ensureKeymapParsed will apply on first parse if we haven't
        // already. If the keymap is already parsed, push the update through.
        self.pending_mods = .{
            .depressed = depressed,
            .latched = latched,
            .locked = locked,
            .group = group,
        };
        if (self.xkb_state) |state| {
            _ = xkb.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
            self.pending_mods = null;
        }
    }

    fn keyboardRepeatInfo(data: ?*anyopaque, _: ?*wl.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
        const self: *Wayland = @ptrCast(@alignCast(data));
        if (rate > 0) self.repeat_rate = @intCast(rate);
        if (delay > 0) self.repeat_delay = @intCast(delay);
    }

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
