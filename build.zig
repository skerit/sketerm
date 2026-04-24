const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Force ReleaseSafe by default. Zig 0.15.2's bundled linker
    // (whether self-hosted or LLD) can't handle the .sframe section
    // gcc 15's crt1.o ships with on Arch (R_X86_64_PC64 relocations
    // in .sframe). Debug builds hit this; ReleaseSafe avoids it.
    // Override via `-Doptimize=Debug` once a newer LLD is installed.
    const optimize_arg = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "build mode (default ReleaseSafe to dodge gcc 15 .sframe + Zig LLD)",
    );
    const optimize = optimize_arg orelse .ReleaseSafe;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const sys_libs = [_][]const u8{
        "gtk4",
        "libadwaita-1",
        "freetype2",
        "harfbuzz",
        "epoxy",
    };

    const exe = b.addExecutable(.{
        .name = "sketerm",
        .root_module = exe_mod,
        .use_lld = true,  // self-hosted linker can't handle gcc 15's SFrame relocs in crt1
    });
    for (sys_libs) |lib| exe.linkSystemLibrary(lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run sketerm");
    run_step.dependOn(&run_cmd.step);

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
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
