const std = @import("std");

/// Toolchain bits shared by every target. Per-target dependencies (env
/// vars, system libraries) are passed into the per-target factories
/// directly so each target can be built in isolation — `zig build
/// bench-suite` doesn't need libghostty-vt set up, etc.
const Deps = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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

fn addStableProtocol(
    b: *std.Build,
    mod: *std.Build.Module,
    scanner: []const u8,
    protocols_dir: []const u8,
    comptime name: []const u8,
) void {
    addScannedWaylandProtocol(
        b,
        mod,
        scanner,
        b.pathJoin(&.{ protocols_dir, "stable", name, name ++ ".xml" }),
        name ++ "-client-protocol.h",
        name ++ "-protocol.c",
    );
}

fn addStagingProtocol(
    b: *std.Build,
    mod: *std.Build.Module,
    scanner: []const u8,
    protocols_dir: []const u8,
    comptime path: []const u8,
    comptime header: []const u8,
    comptime code: []const u8,
) void {
    addScannedWaylandProtocol(
        b,
        mod,
        scanner,
        b.pathJoin(&.{ protocols_dir, path }),
        header,
        code,
    );
}

fn addLocalProtocol(
    b: *std.Build,
    mod: *std.Build.Module,
    scanner: []const u8,
    comptime xml: []const u8,
    comptime header: []const u8,
    comptime code: []const u8,
) void {
    addScannedWaylandProtocol(
        b,
        mod,
        scanner,
        b.path(xml).getPath(b),
        header,
        code,
    );
}

/// color.zig is referenced by terminal/config (used by headless tests)
/// and by render/* (used by main). Promoting it to a named module
/// avoids "file exists in modules X and Y" when both the test modules
/// and main_module would otherwise each adopt it as a sibling file.
fn createColorModule(b: *std.Build, deps: Deps) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/color.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
}

fn createSnailModule(b: *std.Build, deps: Deps) *std.Build.Module {
    const snail_dep = b.dependency("snail", .{});
    const snail_opts = b.addOptions();
    snail_opts.addOption(bool, "enable_profiling", false);
    snail_opts.addOption(bool, "enable_harfbuzz", true);
    snail_opts.addOption(bool, "enable_vulkan", false);
    // snail 0.11.0 split the GL backend into three independent toggles.
    // scrgo only uses the GLES 3.0 renderer; gl33/gl44 stay disabled so
    // the snail module doesn't link libOpenGL.
    snail_opts.addOption(bool, "enable_gl33", false);
    snail_opts.addOption(bool, "enable_gl44", false);
    snail_opts.addOption(bool, "enable_gles30", true);
    snail_opts.addOption(bool, "enable_cpu", true);

    const vk_stub = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("vk_stub.zig", ""),
    });

    const snail_mod = b.createModule(.{
        .root_source_file = snail_dep.path("src/snail/root.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    snail_mod.addOptions("build_options", snail_opts);
    snail_mod.linkSystemLibrary("GLESv2", .{});
    snail_mod.linkSystemLibrary("harfbuzz", .{});
    snail_mod.addImport("vulkan_shaders", vk_stub);
    return snail_mod;
}

const MainOptions = struct {
    vt_include: []const u8,
    vt_static_lib: []const u8,
    wayland_protocols_dir: []const u8,
    wayland_scanner: []const u8,
};

/// Module for the main scrgo executable: libghostty-vt + snail + the
/// Wayland/EGL/OpenGL stack + first-party and scanned protocols.
fn createMainModule(b: *std.Build, deps: Deps, opts: MainOptions) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = opts.vt_include });
    mod.addObjectFile(.{ .cwd_relative = opts.vt_static_lib });
    mod.addImport("snail", createSnailModule(b, deps));
    mod.addImport("color", createColorModule(b, deps));

    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("wayland-egl", .{});
    mod.linkSystemLibrary("egl", .{});
    mod.linkSystemLibrary("xkbcommon", .{});
    mod.linkSystemLibrary("GLESv2", .{});
    mod.linkSystemLibrary("gbm", .{});
    mod.linkSystemLibrary("libdrm", .{ .use_pkg_config = .force });
    mod.linkSystemLibrary("fontconfig", .{});

    mod.addCSourceFile(.{ .file = b.path("protocol/xdg-shell-protocol.c") });
    mod.addCSourceFile(.{ .file = b.path("protocol/xdg-decoration-protocol.c") });
    // cursor-shape-v1's wl_message tables reference zwp_tablet_tool_v2_interface
    // for the get_tablet_tool_v2 request. We never call that request — pointer
    // input only — but the symbol must resolve at link time, so we ship a
    // minimal interface struct in lieu of pulling in all of tablet-v2.
    mod.addCSourceFile(.{ .file = b.path("protocol/tablet-v2-stub.c") });
    mod.addIncludePath(b.path("protocol"));

    addStableProtocol(b, mod, opts.wayland_scanner, opts.wayland_protocols_dir, "viewporter");
    addStagingProtocol(b, mod, opts.wayland_scanner, opts.wayland_protocols_dir, "staging/single-pixel-buffer/single-pixel-buffer-v1.xml", "single-pixel-buffer-v1-client-protocol.h", "single-pixel-buffer-v1-protocol.c");
    addStagingProtocol(b, mod, opts.wayland_scanner, opts.wayland_protocols_dir, "staging/cursor-shape/cursor-shape-v1.xml", "cursor-shape-v1-client-protocol.h", "cursor-shape-v1-protocol.c");
    addStagingProtocol(b, mod, opts.wayland_scanner, opts.wayland_protocols_dir, "unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml", "linux-dmabuf-unstable-v1-client-protocol.h", "linux-dmabuf-unstable-v1-protocol.c");
    addStagingProtocol(b, mod, opts.wayland_scanner, opts.wayland_protocols_dir, "unstable/primary-selection/primary-selection-unstable-v1.xml", "primary-selection-unstable-v1-client-protocol.h", "primary-selection-unstable-v1-protocol.c");

    return mod;
}

const HeadlessOptions = struct {
    vt_include: []const u8,
    vt_static_lib: []const u8,
};

/// Module for headless test binaries: libghostty-vt + libc only. The
/// tests live under src/test/, so terminal/config/selection — which
/// stay at src/ top level — are exposed by name through addImport;
/// Zig forbids `../` imports across a module's root directory.
fn createHeadlessModule(b: *std.Build, deps: Deps, opts: HeadlessOptions, comptime root: []const u8) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = opts.vt_include });
    mod.addObjectFile(.{ .cwd_relative = opts.vt_static_lib });

    // terminal.zig pulls in the libghostty-vt headers; color.zig is its
    // only first-party dependency. config.zig also depends on color.
    const color_mod = createColorModule(b, deps);
    const terminal_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    terminal_mod.addIncludePath(.{ .cwd_relative = opts.vt_include });
    terminal_mod.addImport("color", color_mod);
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    config_mod.addImport("color", color_mod);
    const selection_mod = b.createModule(.{
        .root_source_file = b.path("src/selection.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    mod.addImport("terminal_mod", terminal_mod);
    mod.addImport("config_mod", config_mod);
    mod.addImport("selection_mod", selection_mod);

    return mod;
}

/// Wlroots-protocol harness used by integration_test and bench_suite.
/// Owns wlr_harness.zig + the three wlroots protocol .c files; the
/// downstream binaries pull it in via addImport("wlr_harness", ...) so
/// each binary doesn't have to redeclare the protocol generators.
fn createHarnessModule(b: *std.Build, deps: Deps, wayland_scanner: []const u8) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/harness/wlr_harness.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("xkbcommon", .{});
    addLocalProtocol(b, mod, wayland_scanner, "protocol/wlr-foreign-toplevel-management-unstable-v1.xml", "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h", "wlr-foreign-toplevel-management-unstable-v1-protocol.c");
    addLocalProtocol(b, mod, wayland_scanner, "protocol/wlr-screencopy-unstable-v1.xml", "wlr-screencopy-unstable-v1-client-protocol.h", "wlr-screencopy-unstable-v1-protocol.c");
    addLocalProtocol(b, mod, wayland_scanner, "protocol/virtual-keyboard-unstable-v1.xml", "virtual-keyboard-unstable-v1-client-protocol.h", "virtual-keyboard-unstable-v1-protocol.c");
    return mod;
}

/// Module for wlroots-protocol clients (integration test, bench suite):
/// pulls in the shared harness module + perf, both surfaced via
/// addImport because they live outside the binary's src/{test,bench}/
/// module root.
fn createWlrClientModule(b: *std.Build, deps: Deps, harness_mod: *std.Build.Module, comptime root: []const u8) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    const perf_mod = b.createModule(.{
        .root_source_file = b.path("src/perf.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .link_libc = true,
    });
    mod.addImport("perf", perf_mod);
    mod.addImport("wlr_harness", harness_mod);
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Per-dependency env / -D flags. A target is only registered when
    // every flag it needs is set; this keeps `zig build bench-suite`
    // from requiring libghostty-vt env vars in its nix derivation.
    const vt_include = b.option([]const u8, "ghostty-vt-include", "Path to libghostty-vt headers") orelse b.graph.environ_map.get("GHOSTTY_VT_INCLUDE");
    const vt_static_lib = b.option([]const u8, "ghostty-vt-static-lib", "Full path to libghostty-vt.a") orelse b.graph.environ_map.get("GHOSTTY_VT_LIB");
    const wayland_protocols_dir = b.option([]const u8, "wayland-protocols-dir", "Path to wayland-protocols pkgdatadir") orelse b.graph.environ_map.get("WAYLAND_PROTOCOLS_DIR");
    const wayland_scanner = b.option([]const u8, "wayland-scanner", "Path to wayland-scanner binary") orelse b.graph.environ_map.get("WAYLAND_SCANNER");

    const deps: Deps = .{ .target = target, .optimize = optimize };

    // ── scrgo (default install + `zig build run`) ──────────────────────
    if (vt_include != null and vt_static_lib != null and wayland_protocols_dir != null and wayland_scanner != null) {
        const main_module = createMainModule(b, deps, .{
            .vt_include = vt_include.?,
            .vt_static_lib = vt_static_lib.?,
            .wayland_protocols_dir = wayland_protocols_dir.?,
            .wayland_scanner = wayland_scanner.?,
        });
        const exe = b.addExecutable(.{ .name = "scrgo", .root_module = main_module });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        b.step("run", "Run scrgo").dependOn(&run_cmd.step);
    }

    // ── headless tests (`zig build test`, plus per-suite aliases) ──────
    const test_step = b.step("test", "Run all headless tests");

    // cli.zig + bell.zig have no ghostty/snail/wayland deps — their
    // tests can always run.
    inline for (.{
        .{ .src = "src/cli.zig", .step = "test-cli", .desc = "Run CLI parser tests" },
        .{ .src = "src/bell.zig", .step = "test-bell", .desc = "Run bell manager tests" },
    }) |t| {
        const mod = b.createModule(.{
            .root_source_file = b.path(t.src),
            .target = deps.target,
            .optimize = deps.optimize,
            .link_libc = true,
        });
        const tests = b.addTest(.{ .root_module = mod });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        b.step(t.step, t.desc).dependOn(&run.step);
    }

    if (vt_include != null and vt_static_lib != null) {
        const headless_opts: HeadlessOptions = .{
            .vt_include = vt_include.?,
            .vt_static_lib = vt_static_lib.?,
        };

        const headless_module = createHeadlessModule(b, deps, headless_opts, "src/test/headless_test.zig");
        const headless_tests = b.addTest(.{ .root_module = headless_module });
        const run_headless_tests = b.addRunArtifact(headless_tests);
        test_step.dependOn(&run_headless_tests.step);
        b.step("test-headless", "Run headless terminal tests").dependOn(&run_headless_tests.step);

        const input_module = createHeadlessModule(b, deps, headless_opts, "src/test/headless_input_test.zig");
        const input_tests = b.addTest(.{ .root_module = input_module });
        const run_input_tests = b.addRunArtifact(input_tests);
        test_step.dependOn(&run_input_tests.step);
        b.step("test-input", "Run headless input round-trip tests").dependOn(&run_input_tests.step);
    }

    // ── wlroots-client tools — opt-in installs ─────────────────────────
    // Each is built only when its named step is requested; `zig build`
    // with no args does not produce them. Their nix derivations supply
    // wayland-scanner without libghostty-vt or snail.
    if (wayland_scanner) |scanner| {
        const harness_module = createHarnessModule(b, deps, scanner);

        const it_module = createWlrClientModule(b, deps, harness_module, "src/test/integration_test.zig");
        const it_exe = b.addExecutable(.{ .name = "scrgo-integration-test", .root_module = it_module });
        const it_install = b.addInstallArtifact(it_exe, .{});
        b.step("integration-test", "Build the integration-test binary").dependOn(&it_install.step);

        const bench_module = createWlrClientModule(b, deps, harness_module, "src/bench/bench_suite.zig");
        const bench_exe = b.addExecutable(.{ .name = "scrgo-bench-suite", .root_module = bench_module });
        const bench_install = b.addInstallArtifact(bench_exe, .{});
        b.step("bench-suite", "Build the bench-suite binary").dependOn(&bench_install.step);
    }
}
