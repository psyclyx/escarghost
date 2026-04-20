const std = @import("std");

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
    {
        const vt_include = b.option([]const u8, "ghostty-vt-include", "Path to libghostty-vt headers")
            orelse b.graph.environ_map.get("GHOSTTY_VT_INCLUDE");
        const vt_static_lib = b.option([]const u8, "ghostty-vt-static-lib", "Full path to libghostty-vt.a")
            orelse b.graph.environ_map.get("GHOSTTY_VT_LIB");

        if (vt_include) |inc| root_module.addIncludePath(.{ .cwd_relative = inc });
        if (vt_static_lib) |lib_path| root_module.addObjectFile(.{ .cwd_relative = lib_path });
    }

    // Snail: GPU Bézier text rendering
    {
        const snail_dep = b.dependency("snail", .{});
        const snail_opts = b.addOptions();
        snail_opts.addOption(bool, "enable_profiling", false);
        snail_opts.addOption(bool, "enable_harfbuzz", true);
        snail_opts.addOption(bool, "enable_vulkan", false);
        snail_opts.addOption(bool, "force_gl33", false);

        const vk_stub = b.createModule(.{
            .root_source_file = b.addWriteFiles().add("vk_stub.zig", ""),
        });

        const snail_mod = b.createModule(.{
            .root_source_file = snail_dep.path("src/snail.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        snail_mod.addOptions("build_options", snail_opts);
        snail_mod.linkSystemLibrary("gl", .{});
        snail_mod.linkSystemLibrary("harfbuzz", .{});
        snail_mod.addImport("vulkan_shaders", vk_stub);
        root_module.addImport("snail", snail_mod);
    }

    // Wayland + EGL + OpenGL
    root_module.linkSystemLibrary("wayland-client", .{});
    root_module.linkSystemLibrary("wayland-egl", .{});
    root_module.linkSystemLibrary("egl", .{});
    root_module.linkSystemLibrary("xkbcommon", .{});
    root_module.linkSystemLibrary("gl", .{});

    // Wayland protocol implementations
    root_module.addCSourceFile(.{ .file = b.path("protocol/xdg-shell-protocol.c") });
    root_module.addCSourceFile(.{ .file = b.path("protocol/xdg-decoration-protocol.c") });
    root_module.addIncludePath(b.path("protocol"));

    const exe = b.addExecutable(.{
        .name = "mollusk",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run mollusk");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const unit_tests = b.addTest(.{ .root_module = test_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
