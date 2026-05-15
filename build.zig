const std = @import("std");

/// Toolchain + system libraries shared by every target. Built once at the
/// top of `build()` and threaded through the per-target helpers.
const Deps = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vt_include: ?[]const u8,
    vt_static_lib: ?[]const u8,
    wayland_protocols_dir: []const u8,
    wayland_scanner: []const u8,
    snail_module: *std.Build.Module,
};

fn addScannedWaylandProtocol(
    b: *std.Build,
    root_module: *std.Build.Module,
    scanner: []const u8,
    xml_path: []const u8,
    header_name: []const u8,
    code_name: []const u8,
) void {
    const header_step = b.addSystemCommand(&.{ scanner, "client-header" });
    header_step.addFileArg(.{ .cwd_relative = xml_path });
    const header = header_step.addOutputFileArg(header_name);

    const code_step = b.addSystemCommand(&.{ scanner, "private-code" });
    code_step.step.dependOn(&header_step.step);
    code_step.addFileArg(.{ .cwd_relative = xml_path });
    const code = code_step.addOutputFileArg(code_name);

    root_module.addIncludePath(header.dirname());
    root_module.addCSourceFile(.{ .file = code });
}

fn addStableProtocol(b: *std.Build, mod: *std.Build.Module, deps: Deps, comptime name: []const u8) void {
    addScannedWaylandProtocol(
        b,
        mod,
        deps.wayland_scanner,
        b.pathJoin(&.{ deps.wayland_protocols_dir, "stable", name, name ++ ".xml" }),
        name ++ "-client-protocol.h",
        name ++ "-protocol.c",
    );
}

fn addStagingProtocol(b: *std.Build, mod: *std.Build.Module, deps: Deps, comptime path: []const u8, comptime header: []const u8, comptime code: []const u8) void {
    addScannedWaylandProtocol(
        b,
        mod,
        deps.wayland_scanner,
        b.pathJoin(&.{ deps.wayland_protocols_dir, path }),
        header,
        code,
    );
}

fn addLocalProtocol(b: *std.Build, mod: *std.Build.Module, deps: Deps, comptime xml: []const u8, comptime header: []const u8, comptime code: []const u8) void {
    addScannedWaylandProtocol(
        b,
        mod,
        deps.wayland_scanner,
        b.path(xml).getPath(b),
        header,
        code,
    );
}

/// Module for the main scrgo executable: libghostty-vt + snail + the
/// Wayland/EGL/OpenGL stack, plus the project's three first-party
/// protocols (xdg-shell, xdg-decoration) and the scanned ones below.
fn createMainModule(b: *std.Build, deps: Deps) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    if (deps.vt_include) |inc| mod.addIncludePath(.{ .cwd_relative = inc });
    if (deps.vt_static_lib) |lib_path| mod.addObjectFile(.{ .cwd_relative = lib_path });
    mod.addImport("snail", deps.snail_module);

    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("wayland-egl", .{});
    mod.linkSystemLibrary("egl", .{});
    mod.linkSystemLibrary("xkbcommon", .{});
    mod.linkSystemLibrary("OpenGL", .{});
    mod.linkSystemLibrary("gbm", .{});
    mod.linkSystemLibrary("libdrm", .{ .use_pkg_config = .force });
    mod.linkSystemLibrary("fontconfig", .{});

    mod.addCSourceFile(.{ .file = b.path("protocol/xdg-shell-protocol.c") });
    mod.addCSourceFile(.{ .file = b.path("protocol/xdg-decoration-protocol.c") });
    mod.addIncludePath(b.path("protocol"));

    addStableProtocol(b, mod, deps, "viewporter");
    addStagingProtocol(b, mod, deps, "staging/single-pixel-buffer/single-pixel-buffer-v1.xml", "single-pixel-buffer-v1-client-protocol.h", "single-pixel-buffer-v1-protocol.c");
    addStagingProtocol(b, mod, deps, "unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml", "linux-dmabuf-unstable-v1-client-protocol.h", "linux-dmabuf-unstable-v1-protocol.c");

    return mod;
}

/// Module for headless executables (tests, repro tools): libghostty-vt
/// + libc only. No Wayland, no GL.
fn createHeadlessModule(b: *std.Build, deps: Deps, comptime root: []const u8) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    if (deps.vt_include) |inc| mod.addIncludePath(.{ .cwd_relative = inc });
    if (deps.vt_static_lib) |lib_path| mod.addObjectFile(.{ .cwd_relative = lib_path });
    return mod;
}

/// Module for wlroots-protocol clients (integration test, bench suite):
/// wayland-client + xkbcommon + the three wlroots protocols we use to
/// drive a nested compositor. Does not link libghostty-vt — these
/// binaries spawn scrgo as a child rather than embedding it.
fn createWlrClientModule(b: *std.Build, deps: Deps, comptime root: []const u8) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("xkbcommon", .{});
    addLocalProtocol(b, mod, deps, "protocol/wlr-foreign-toplevel-management-unstable-v1.xml", "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h", "wlr-foreign-toplevel-management-unstable-v1-protocol.c");
    addLocalProtocol(b, mod, deps, "protocol/wlr-screencopy-unstable-v1.xml", "wlr-screencopy-unstable-v1-client-protocol.h", "wlr-screencopy-unstable-v1-protocol.c");
    addLocalProtocol(b, mod, deps, "protocol/virtual-keyboard-unstable-v1.xml", "virtual-keyboard-unstable-v1-client-protocol.h", "virtual-keyboard-unstable-v1-protocol.c");
    return mod;
}

fn createSnailModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const snail_dep = b.dependency("snail", .{});
    const snail_opts = b.addOptions();
    snail_opts.addOption(bool, "enable_profiling", false);
    snail_opts.addOption(bool, "enable_harfbuzz", true);
    snail_opts.addOption(bool, "enable_vulkan", false);
    snail_opts.addOption(bool, "enable_opengl", true);
    snail_opts.addOption(bool, "enable_cpu", true);
    snail_opts.addOption(bool, "force_gl33", false);

    const vk_stub = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("vk_stub.zig", ""),
    });

    const snail_mod = b.createModule(.{
        .root_source_file = snail_dep.path("src/snail/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    snail_mod.addOptions("build_options", snail_opts);
    snail_mod.linkSystemLibrary("OpenGL", .{});
    snail_mod.linkSystemLibrary("harfbuzz", .{});
    snail_mod.addImport("vulkan_shaders", vk_stub);
    return snail_mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libghostty-vt: terminal emulation (parsing + state). Built separately
    // with its own zig version; consumed as a C library. In the nix shell,
    // GHOSTTY_VT_INCLUDE / GHOSTTY_VT_LIB are set automatically. Non-nix
    // users pass -Dghostty-vt-include=... -Dghostty-vt-static-lib=...
    const deps: Deps = .{
        .target = target,
        .optimize = optimize,
        .vt_include = b.option([]const u8, "ghostty-vt-include", "Path to libghostty-vt headers") orelse b.graph.environ_map.get("GHOSTTY_VT_INCLUDE"),
        .vt_static_lib = b.option([]const u8, "ghostty-vt-static-lib", "Full path to libghostty-vt.a") orelse b.graph.environ_map.get("GHOSTTY_VT_LIB"),
        .wayland_protocols_dir = b.option([]const u8, "wayland-protocols-dir", "Path to wayland-protocols pkgdatadir") orelse b.graph.environ_map.get("WAYLAND_PROTOCOLS_DIR") orelse @panic("WAYLAND_PROTOCOLS_DIR or -Dwayland-protocols-dir is required"),
        .wayland_scanner = b.option([]const u8, "wayland-scanner", "Path to wayland-scanner binary") orelse b.graph.environ_map.get("WAYLAND_SCANNER") orelse @panic("WAYLAND_SCANNER or -Dwayland-scanner is required"),
        .snail_module = createSnailModule(b, target, optimize),
    };

    // ── scrgo (default `zig build` + `zig build run`) ──────────────────
    const main_module = createMainModule(b, deps);
    const exe = b.addExecutable(.{ .name = "scrgo", .root_module = main_module });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run scrgo").dependOn(&run_cmd.step);

    // ── tests (`zig build test`, plus per-suite aliases) ───────────────
    const test_step = b.step("test", "Run all headless tests");

    const headless_module = createHeadlessModule(b, deps, "src/headless_test.zig");
    const headless_tests = b.addTest(.{ .root_module = headless_module });
    const run_headless_tests = b.addRunArtifact(headless_tests);
    test_step.dependOn(&run_headless_tests.step);
    b.step("test-headless", "Run headless terminal tests").dependOn(&run_headless_tests.step);

    const input_module = createHeadlessModule(b, deps, "src/headless_input_test.zig");
    const input_tests = b.addTest(.{ .root_module = input_module });
    const run_input_tests = b.addRunArtifact(input_tests);
    test_step.dependOn(&run_input_tests.step);
    b.step("test-input", "Run headless input round-trip tests").dependOn(&run_input_tests.step);

    // ── integration test (sway-headless harness) ───────────────────────
    // Spawns scrgo as a child, detects its window via wlr_foreign_toplevel,
    // injects keys via zwp_virtual_keyboard, captures frames via
    // zwlr_screencopy, and verifies per-keystroke pixel deltas. Run via
    // the `integration-test` nix wrapper which boots sway and supplies
    // WAYLAND_DISPLAY.
    const it_module = createWlrClientModule(b, deps, "src/integration_test.zig");
    const it_exe = b.addExecutable(.{ .name = "scrgo-integration-test", .root_module = it_module });
    b.installArtifact(it_exe);

    // ── bench suite (terminal comparison driver) ───────────────────────
    // Drives startup / stream / input-latency / memory / screenshot
    // scenarios from one binary against any subset of terminals, inside a
    // single nested compositor. Run via the `bench` nix wrapper.
    const bench_module = createWlrClientModule(b, deps, "src/bench_suite.zig");
    const bench_exe = b.addExecutable(.{ .name = "scrgo-bench-suite", .root_module = bench_module });
    b.installArtifact(bench_exe);
}
