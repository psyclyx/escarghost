const std = @import("std");

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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // libghostty-vt: terminal emulation (parsing + state).
    // Built separately with its own zig version; consumed as a C library.
    // In the nix shell, GHOSTTY_VT_INCLUDE and GHOSTTY_VT_LIB are set automatically.
    // Non-nix users can pass -Dghostty-vt-include=... -Dghostty-vt-static-lib=...
    const vt_include = b.option([]const u8, "ghostty-vt-include", "Path to libghostty-vt headers") orelse b.graph.environ_map.get("GHOSTTY_VT_INCLUDE");
    const vt_static_lib = b.option([]const u8, "ghostty-vt-static-lib", "Full path to libghostty-vt.a") orelse b.graph.environ_map.get("GHOSTTY_VT_LIB");
    const wayland_protocols_dir = b.option([]const u8, "wayland-protocols-dir", "Path to wayland-protocols pkgdatadir") orelse b.graph.environ_map.get("WAYLAND_PROTOCOLS_DIR") orelse @panic("WAYLAND_PROTOCOLS_DIR or -Dwayland-protocols-dir is required");
    const wayland_scanner = b.option([]const u8, "wayland-scanner", "Path to wayland-scanner binary") orelse b.graph.environ_map.get("WAYLAND_SCANNER") orelse @panic("WAYLAND_SCANNER or -Dwayland-scanner is required");

    if (vt_include) |inc| root_module.addIncludePath(.{ .cwd_relative = inc });
    if (vt_static_lib) |lib_path| root_module.addObjectFile(.{ .cwd_relative = lib_path });

    // Snail: GPU Bézier text rendering
    {
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
        root_module.addImport("snail", snail_mod);
    }

    // Wayland + EGL + OpenGL
    root_module.linkSystemLibrary("wayland-client", .{});
    root_module.linkSystemLibrary("wayland-egl", .{});
    root_module.linkSystemLibrary("egl", .{});
    root_module.linkSystemLibrary("xkbcommon", .{});
    root_module.linkSystemLibrary("OpenGL", .{});
    root_module.linkSystemLibrary("gbm", .{});
    root_module.linkSystemLibrary("libdrm", .{ .use_pkg_config = .force });
    root_module.linkSystemLibrary("fontconfig", .{});

    // Wayland protocol implementations
    root_module.addCSourceFile(.{ .file = b.path("protocol/xdg-shell-protocol.c") });
    root_module.addCSourceFile(.{ .file = b.path("protocol/xdg-decoration-protocol.c") });
    root_module.addIncludePath(b.path("protocol"));
    addScannedWaylandProtocol(
        b,
        root_module,
        wayland_scanner,
        b.pathJoin(&.{ wayland_protocols_dir, "stable/viewporter/viewporter.xml" }),
        "viewporter-client-protocol.h",
        "viewporter-protocol.c",
    );
    addScannedWaylandProtocol(
        b,
        root_module,
        wayland_scanner,
        b.pathJoin(&.{ wayland_protocols_dir, "staging/single-pixel-buffer/single-pixel-buffer-v1.xml" }),
        "single-pixel-buffer-v1-client-protocol.h",
        "single-pixel-buffer-v1-protocol.c",
    );
    addScannedWaylandProtocol(
        b,
        root_module,
        wayland_scanner,
        b.pathJoin(&.{ wayland_protocols_dir, "unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml" }),
        "linux-dmabuf-unstable-v1-client-protocol.h",
        "linux-dmabuf-unstable-v1-protocol.c",
    );

    const exe = b.addExecutable(.{
        .name = "scrgo",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run scrgo");
    run_step.dependOn(&run_cmd.step);

    // Benchmark (no GL, CPU-side perf)
    {
        const bench_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        if (vt_include) |inc| bench_module.addIncludePath(.{ .cwd_relative = inc });
        if (vt_static_lib) |lib_path| bench_module.addObjectFile(.{ .cwd_relative = lib_path });
        bench_module.linkSystemLibrary("fontconfig", .{});

        const bench_exe = b.addExecutable(.{ .name = "scrgo-bench", .root_module = bench_module });
        b.installArtifact(bench_exe);
        const bench_run = b.addRunArtifact(bench_exe);
        const bench_step = b.step("bench", "Run CPU benchmarks");
        bench_step.dependOn(&bench_run.step);
    }

    // Headless test (no GL, exercises terminal + render state iteration)
    {
        const headless_module = b.createModule(.{
            .root_source_file = b.path("src/headless_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        if (vt_include) |inc| headless_module.addIncludePath(.{ .cwd_relative = inc });
        if (vt_static_lib) |lib_path| headless_module.addObjectFile(.{ .cwd_relative = lib_path });

        const headless_exe = b.addExecutable(.{
            .name = "scrgo-headless-test",
            .root_module = headless_module,
        });
        b.installArtifact(headless_exe);

        const headless_run = b.addRunArtifact(headless_exe);
        const headless_step = b.step("test-headless", "Run headless terminal tests");
        headless_step.dependOn(&headless_run.step);
    }

    // Integration test (sway-headless harness; spawns scrgo as a child,
    // detects its window via wlr_foreign_toplevel, injects keys via
    // zwp_virtual_keyboard, captures frames via zwlr_screencopy, and
    // verifies per-keystroke pixel deltas. Run via the `integration-test`
    // nix wrapper which boots sway and supplies WAYLAND_DISPLAY.)
    {
        const it_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        it_module.linkSystemLibrary("wayland-client", .{});
        it_module.linkSystemLibrary("xkbcommon", .{});
        addScannedWaylandProtocol(
            b,
            it_module,
            wayland_scanner,
            b.path("protocol/wlr-foreign-toplevel-management-unstable-v1.xml").getPath(b),
            "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h",
            "wlr-foreign-toplevel-management-unstable-v1-protocol.c",
        );
        addScannedWaylandProtocol(
            b,
            it_module,
            wayland_scanner,
            b.path("protocol/wlr-screencopy-unstable-v1.xml").getPath(b),
            "wlr-screencopy-unstable-v1-client-protocol.h",
            "wlr-screencopy-unstable-v1-protocol.c",
        );
        addScannedWaylandProtocol(
            b,
            it_module,
            wayland_scanner,
            b.path("protocol/virtual-keyboard-unstable-v1.xml").getPath(b),
            "virtual-keyboard-unstable-v1-client-protocol.h",
            "virtual-keyboard-unstable-v1-protocol.c",
        );
        const it_exe = b.addExecutable(.{
            .name = "scrgo-integration-test",
            .root_module = it_module,
        });
        b.installArtifact(it_exe);
    }

    // Input-latency bench. Iterates scrgo/foot/alacritty/kitty/wezterm,
    // injects keys via virtual_keyboard, times each one's roundtrip to
    // a pixel change via screencopy. Shares the wlroots client
    // plumbing with the integration test via wlr_harness.zig.
    {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path("src/bench_input_latency.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        bench_mod.linkSystemLibrary("wayland-client", .{});
        bench_mod.linkSystemLibrary("xkbcommon", .{});
        addScannedWaylandProtocol(
            b,
            bench_mod,
            wayland_scanner,
            b.path("protocol/wlr-foreign-toplevel-management-unstable-v1.xml").getPath(b),
            "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h",
            "wlr-foreign-toplevel-management-unstable-v1-protocol.c",
        );
        addScannedWaylandProtocol(
            b,
            bench_mod,
            wayland_scanner,
            b.path("protocol/wlr-screencopy-unstable-v1.xml").getPath(b),
            "wlr-screencopy-unstable-v1-client-protocol.h",
            "wlr-screencopy-unstable-v1-protocol.c",
        );
        addScannedWaylandProtocol(
            b,
            bench_mod,
            wayland_scanner,
            b.path("protocol/virtual-keyboard-unstable-v1.xml").getPath(b),
            "virtual-keyboard-unstable-v1-client-protocol.h",
            "virtual-keyboard-unstable-v1-protocol.c",
        );
        const bench_exe = b.addExecutable(.{
            .name = "scrgo-bench-input-latency",
            .root_module = bench_mod,
        });
        b.installArtifact(bench_exe);
    }

    // Stream-under-load bench. Spawns each terminal with `cat <payload>`,
    // captures frames continuously to count distinct content hashes,
    // reports wall time / MB/s / distinct fps.
    {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path("src/bench_stream.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        bench_mod.linkSystemLibrary("wayland-client", .{});
        bench_mod.linkSystemLibrary("xkbcommon", .{});
        addScannedWaylandProtocol(
            b,
            bench_mod,
            wayland_scanner,
            b.path("protocol/wlr-foreign-toplevel-management-unstable-v1.xml").getPath(b),
            "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h",
            "wlr-foreign-toplevel-management-unstable-v1-protocol.c",
        );
        addScannedWaylandProtocol(
            b,
            bench_mod,
            wayland_scanner,
            b.path("protocol/wlr-screencopy-unstable-v1.xml").getPath(b),
            "wlr-screencopy-unstable-v1-client-protocol.h",
            "wlr-screencopy-unstable-v1-protocol.c",
        );
        addScannedWaylandProtocol(
            b,
            bench_mod,
            wayland_scanner,
            b.path("protocol/virtual-keyboard-unstable-v1.xml").getPath(b),
            "virtual-keyboard-unstable-v1-client-protocol.h",
            "virtual-keyboard-unstable-v1-protocol.c",
        );
        const bench_exe = b.addExecutable(.{
            .name = "scrgo-bench-stream",
            .root_module = bench_mod,
        });
        b.installArtifact(bench_exe);
    }

    // Minimal repro for the libghostty-vt linefeed/cursorChangePin
    // SEGV. Strips PTY, renderer, wayland — just hammers feedData
    // with linefeed-heavy content.
    {
        const repro_mod = b.createModule(.{
            .root_source_file = b.path("src/libghostty_repro.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        if (vt_include) |inc| repro_mod.addIncludePath(.{ .cwd_relative = inc });
        if (vt_static_lib) |lib_path| repro_mod.addObjectFile(.{ .cwd_relative = lib_path });
        const repro_exe = b.addExecutable(.{
            .name = "scrgo-libghostty-repro",
            .root_module = repro_mod,
        });
        b.installArtifact(repro_exe);

        const repro_run = b.addRunArtifact(repro_exe);
        const repro_step = b.step("repro-libghostty", "Run minimal libghostty-vt repro");
        repro_step.dependOn(&repro_run.step);
    }

    // Headless input test (no GL, no wayland; PTY round-trip via line
    // discipline echo into the Terminal grid).
    {
        const input_module = b.createModule(.{
            .root_source_file = b.path("src/headless_input_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        if (vt_include) |inc| input_module.addIncludePath(.{ .cwd_relative = inc });
        if (vt_static_lib) |lib_path| input_module.addObjectFile(.{ .cwd_relative = lib_path });

        const input_exe = b.addExecutable(.{
            .name = "scrgo-headless-input-test",
            .root_module = input_module,
        });
        b.installArtifact(input_exe);

        const input_run = b.addRunArtifact(input_exe);
        const input_step = b.step("test-input", "Run headless input round-trip tests");
        input_step.dependOn(&input_run.step);
    }
}
