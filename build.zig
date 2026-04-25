const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Default ReleaseFast for the shipped binary. Terminals are
    // perf-sensitive and runtime safety checks have measurable cost
    // (parser throughput, render latency). Debug builds fail to
    // compile entirely on Arch + gcc 15 because Zig 0.15.2's bundled
    // LLD can't handle gcc 15's `.sframe` section in crt1.o
    // (R_X86_64_PC64 relocs); use `-Doptimize=ReleaseSafe` for
    // bounds + overflow checks while developing.
    const optimize_arg = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "build mode (default ReleaseFast; Debug fails on Arch + gcc 15)",
    );
    const optimize = optimize_arg orelse .ReleaseFast;

    const strip_default = optimize != .Debug and optimize != .ReleaseSafe;
    const strip = b.option(bool, "strip", "strip debug info") orelse strip_default;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });

    const sys_libs = [_][]const u8{
        "gtk4",
        "libadwaita-1",
        "freetype2",
        "harfbuzz",
        "epoxy",
        "fribidi",
    };

    const exe = b.addExecutable(.{
        .name = "sketerm",
        .root_module = exe_mod,
        .use_lld = true,  // self-hosted linker can't handle gcc 15's SFrame relocs in crt1
    });
    for (sys_libs) |lib| exe.linkSystemLibrary(lib);
    exe.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    exe.addIncludePath(b.path("vendor"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run sketerm");
    run_step.dependOn(&run_cmd.step);

    // M0.5 GL spike — `zig build spike-gl`.
    const spike_mod = b.createModule(.{
        .root_source_file = b.path("src/spike_gl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const spike = b.addExecutable(.{
        .name = "sketerm-spike-gl",
        .root_module = spike_mod,
        .use_lld = true,
    });
    for (sys_libs) |lib| spike.linkSystemLibrary(lib);
    spike.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    spike.addIncludePath(b.path("vendor"));
    b.installArtifact(spike);
    const spike_run = b.addRunArtifact(spike);
    const spike_step = b.step("spike-gl", "Run the M0.5 GL share-group spike");
    spike_step.dependOn(&spike_run.step);

    // Headless shell smoke runner — `zig build spike-shell`.
    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/spike_shell.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const shell = b.addExecutable(.{
        .name = "sketerm-spike-shell",
        .root_module = shell_mod,
        .use_lld = true,
    });
    for (sys_libs) |lib| shell.linkSystemLibrary(lib);
    shell.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    shell.addIncludePath(b.path("vendor"));
    b.installArtifact(shell);
    const shell_run = b.addRunArtifact(shell);
    const shell_step = b.step("spike-shell", "Headless PTY/parser/screen smoke");
    shell_step.dependOn(&shell_run.step);

    // Parser microbenchmark — `zig build bench-parser`.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_parser.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const bench = b.addExecutable(.{
        .name = "sketerm-bench-parser",
        .root_module = bench_mod,
        .use_lld = true,
    });
    for (sys_libs) |lib| bench.linkSystemLibrary(lib);
    bench.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    bench.addIncludePath(b.path("vendor"));
    b.installArtifact(bench);
    const bench_run = b.addRunArtifact(bench);
    const bench_step = b.step("bench-parser", "Parser microbenchmark");
    bench_step.dependOn(&bench_run.step);

    // Headless image-render smoke — `zig build smoke-image`.
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_image.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const smoke = b.addExecutable(.{
        .name = "sketerm-smoke-image",
        .root_module = smoke_mod,
        .use_lld = true,
    });
    smoke.linkSystemLibrary("EGL");
    // image_pass imports c.zig which @cIncludes gtk/gtk.h etc, so we
    // need every system header path. Reuse the same set as the main
    // exe.
    for (sys_libs) |lib| smoke.linkSystemLibrary(lib);
    smoke.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    smoke.addIncludePath(b.path("vendor"));
    b.installArtifact(smoke);
    const smoke_run = b.addRunArtifact(smoke);
    const smoke_step = b.step("smoke-image", "Headless GL image render check");
    smoke_step.dependOn(&smoke_run.step);

    // Headless cell-render smoke — `zig build smoke-cell`. Drives a
    // small Screen → Atlas → CellPass → GridPass through an EGL
    // surfaceless context, reads pixels back, asserts text + focus
    // border were rendered. Catches regressions in the instanced
    // cell pipeline + multi-page atlas.
    const smoke_cell_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_cell.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const smoke_cell = b.addExecutable(.{
        .name = "sketerm-smoke-cell",
        .root_module = smoke_cell_mod,
        .use_lld = true,
    });
    smoke_cell.linkSystemLibrary("EGL");
    for (sys_libs) |lib| smoke_cell.linkSystemLibrary(lib);
    smoke_cell.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    smoke_cell.addIncludePath(b.path("vendor"));
    b.installArtifact(smoke_cell);
    const smoke_cell_run = b.addRunArtifact(smoke_cell);
    const smoke_cell_step = b.step("smoke-cell", "Headless GL cell-pipeline render check");
    smoke_cell_step.dependOn(&smoke_cell_run.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tests = b.addTest(.{
        .root_module = tests_mod,
        .use_lld = true,
    });
    for (sys_libs) |lib| tests.linkSystemLibrary(lib);
    tests.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    tests.addIncludePath(b.path("vendor"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
