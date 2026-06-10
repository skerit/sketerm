const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Default ReleaseFast for the shipped binary. Terminals are
    // perf-sensitive and runtime safety checks have measurable cost
    // (parser throughput, render latency). Debug builds fail to
    // compile entirely on Arch + gcc 15 because Zig's bundled LLD
    // can't handle gcc 15's `.sframe` section in crt1.o
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

    // Pre-translate the GTK+glib+freetype+stb C headers into a single
    // generated Zig module via a TranslateC step. In Zig 0.16 the
    // in-process `@cImport` on this header set crashes `zig build-exe`
    // (SEGV inside Aro), but the same input through a standalone
    // `zig translate-c` subprocess succeeds. Out-of-process step it
    // is. See `vendor/cimport_root.h` for the headers + workaround
    // defines.
    const cbindings_mod = buildCBindings(b, target, optimize);

    // Build options: `glib` tells pty.zig whether a GLib main loop
    // exists (GUI) or not (sketerm-mux daemon, which must not link
    // glib and uses blocking fallbacks for the write queue).
    const glib_opts = b.addOptions();
    glib_opts.addOption(bool, "glib", true);
    const glib_opts_mod = glib_opts.createModule();
    const noglib_opts = b.addOptions();
    noglib_opts.addOption(bool, "glib", false);
    const noglib_opts_mod = noglib_opts.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    configureSysDeps(b, exe_mod, cbindings_mod);
    exe_mod.addImport("build_options", glib_opts_mod);

    const exe = b.addExecutable(.{
        .name = "sketerm",
        .root_module = exe_mod,
        .use_lld = true, // self-hosted linker can't handle gcc 15's SFrame relocs in crt1
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run sketerm");
    run_step.dependOn(&run_cmd.step);

    // sketerm-mux session daemon — `zig build mux`. LEAN dependency
    // set: terminal core only (libc + fribidi + vendored stb), no
    // GTK — the whole point is scp-ing one binary to a server. The
    // cbindings module is imported for libc/fribidi decls; unused
    // GTK externs are never referenced so nothing GTK gets linked.
    const mux_mod = b.createModule(.{
        .root_source_file = b.path("src/mux_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    configureCoreDeps(b, mux_mod, cbindings_mod);
    mux_mod.addImport("build_options", noglib_opts_mod);
    const mux_exe = b.addExecutable(.{
        .name = "sketerm-mux",
        .root_module = mux_mod,
        .use_lld = true,
    });
    b.installArtifact(mux_exe);
    const mux_step = b.step("mux", "Build the sketerm-mux session daemon");
    mux_step.dependOn(&b.addInstallArtifact(mux_exe, .{}).step);

    // Mux end-to-end smoke — `zig build smoke-mux` (headless).
    const smoke_mux_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_mux.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, smoke_mux_mod, cbindings_mod);
    smoke_mux_mod.addImport("build_options", noglib_opts_mod);
    const smoke_mux = b.addExecutable(.{
        .name = "sketerm-smoke-mux",
        .root_module = smoke_mux_mod,
        .use_lld = true,
    });
    const smoke_mux_run = b.addRunArtifact(smoke_mux);
    const smoke_mux_step = b.step("smoke-mux", "Mux daemon end-to-end smoke (headless)");
    smoke_mux_step.dependOn(&smoke_mux_run.step);

    // M0.5 GL spike — `zig build spike-gl`.
    const spike_mod = b.createModule(.{
        .root_source_file = b.path("src/spike_gl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, spike_mod, cbindings_mod);
    spike_mod.addImport("build_options", glib_opts_mod);
    const spike = b.addExecutable(.{
        .name = "sketerm-spike-gl",
        .root_module = spike_mod,
        .use_lld = true,
    });
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
    configureSysDeps(b, shell_mod, cbindings_mod);
    shell_mod.addImport("build_options", glib_opts_mod);
    const shell = b.addExecutable(.{
        .name = "sketerm-spike-shell",
        .root_module = shell_mod,
        .use_lld = true,
    });
    b.installArtifact(shell);
    const shell_run = b.addRunArtifact(shell);
    const shell_step = b.step("spike-shell", "Headless PTY/parser/screen smoke");
    shell_step.dependOn(&shell_run.step);

    // Capture replay tool — `zig build replay -- capture.bin [cols rows]`.
    const replay_mod = b.createModule(.{
        .root_source_file = b.path("src/replay.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, replay_mod, cbindings_mod);
    replay_mod.addImport("build_options", glib_opts_mod);
    const replay = b.addExecutable(.{
        .name = "sketerm-replay",
        .root_module = replay_mod,
        .use_lld = true,
    });
    b.installArtifact(replay);
    const replay_run = b.addRunArtifact(replay);
    if (b.args) |args| replay_run.addArgs(args);
    const replay_step = b.step("replay", "Replay a captured PTY byte stream into a Screen dump");
    replay_step.dependOn(&replay_run.step);

    // Parser microbenchmark — `zig build bench-parser`.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_parser.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    configureSysDeps(b, bench_mod, cbindings_mod);
    bench_mod.addImport("build_options", glib_opts_mod);
    const bench = b.addExecutable(.{
        .name = "sketerm-bench-parser",
        .root_module = bench_mod,
        .use_lld = true,
    });
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
    // image_pass imports c.zig which @cIncludes gtk/gtk.h etc, so we
    // need every system header path. Reuse the same set as the main
    // exe.
    configureSysDeps(b, smoke_mod, cbindings_mod);
    smoke_mod.addImport("build_options", glib_opts_mod);
    smoke_mod.linkSystemLibrary("EGL", .{});
    const smoke = b.addExecutable(.{
        .name = "sketerm-smoke-image",
        .root_module = smoke_mod,
        .use_lld = true,
    });
    b.installArtifact(smoke);
    const smoke_run = b.addRunArtifact(smoke);
    const smoke_step = b.step("smoke-image", "Headless GL image render check");
    smoke_step.dependOn(&smoke_run.step);

    // IPC end-to-end smoke — `zig build smoke-e2e`. Launches the
    // built app (needs a display; SKIPs without one), drives it via
    // the remote-control socket, asserts on get-text output.
    const smoke_e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_e2e.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, smoke_e2e_mod, cbindings_mod);
    smoke_e2e_mod.addImport("build_options", glib_opts_mod);
    const smoke_e2e = b.addExecutable(.{
        .name = "sketerm-smoke-e2e",
        .root_module = smoke_e2e_mod,
        .use_lld = true,
    });
    b.installArtifact(smoke_e2e);
    const smoke_e2e_run = b.addRunArtifact(smoke_e2e);
    // It execs zig-out/bin/sketerm, so the main install must finish
    // first, and the cwd must be the project root (default).
    smoke_e2e_run.step.dependOn(b.getInstallStep());
    smoke_e2e_run.setCwd(b.path("."));
    const smoke_e2e_step = b.step("smoke-e2e", "End-to-end smoke via remote-control socket (needs display)");
    smoke_e2e_step.dependOn(&smoke_e2e_run.step);

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
    configureSysDeps(b, smoke_cell_mod, cbindings_mod);
    smoke_cell_mod.addImport("build_options", glib_opts_mod);
    smoke_cell_mod.linkSystemLibrary("EGL", .{});
    const smoke_cell = b.addExecutable(.{
        .name = "sketerm-smoke-cell",
        .root_module = smoke_cell_mod,
        .use_lld = true,
    });
    b.installArtifact(smoke_cell);
    const smoke_cell_run = b.addRunArtifact(smoke_cell);
    const smoke_cell_step = b.step("smoke-cell", "Headless GL cell-pipeline render check");
    smoke_cell_step.dependOn(&smoke_cell_run.step);

    // Headless cell-upload microbench — `zig build bench-cell-upload`.
    // Same EGL surfaceless context as smoke-cell, but at 4K with a
    // realistic-sized cell grid, looped to measure per-frame upload +
    // draw + GPU-finish latency. Used to isolate GL cost from GTK4 /
    // Wayland integration when chasing render stalls.
    const bench_cell_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_cell_upload.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, bench_cell_mod, cbindings_mod);
    bench_cell_mod.addImport("build_options", glib_opts_mod);
    bench_cell_mod.linkSystemLibrary("EGL", .{});
    const bench_cell = b.addExecutable(.{
        .name = "sketerm-bench-cell-upload",
        .root_module = bench_cell_mod,
        .use_lld = true,
    });
    b.installArtifact(bench_cell);
    const bench_cell_run = b.addRunArtifact(bench_cell);
    const bench_cell_step = b.step("bench-cell-upload", "Headless cell-upload microbench (isolates GL from GTK)");
    bench_cell_step.dependOn(&bench_cell_run.step);

    // Headless transparency smoke — `zig build smoke-transparency`.
    // Drives the same stack as smoke-cell but with bg alpha=0.5,
    // asserts the readback FBO retains translucency. Plan-v3 had
    // this gating C; added retroactively as regression coverage.
    const smoke_trans_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_transparency.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, smoke_trans_mod, cbindings_mod);
    smoke_trans_mod.addImport("build_options", glib_opts_mod);
    smoke_trans_mod.linkSystemLibrary("EGL", .{});
    const smoke_trans = b.addExecutable(.{
        .name = "sketerm-smoke-transparency",
        .root_module = smoke_trans_mod,
        .use_lld = true,
    });
    b.installArtifact(smoke_trans);
    const smoke_trans_run = b.addRunArtifact(smoke_trans);
    const smoke_trans_step = b.step("smoke-transparency", "Headless GL bg-alpha render check");
    smoke_trans_step.dependOn(&smoke_trans_run.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, tests_mod, cbindings_mod);
    tests_mod.addImport("build_options", glib_opts_mod);
    const tests = b.addTest(.{
        .root_module = tests_mod,
        .use_lld = true,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Set up the out-of-process TranslateC step that turns
/// `vendor/cimport_root.h` into a Zig module. Returns a module each
/// binary can import as `@import("cbindings")`.
///
/// The raw translate-c output contains some invalid Zig that Aro emits
/// for discarded pointer-returning calls inside `static inline` glib
/// functions (e.g. `g_set_object`): `_ = @ptrCast(@alignCast(call()))`
/// fails with "@ptrCast must have a known result type". A sed pass
/// strips the redundant outer cast so the discard typechecks.
fn buildCBindings(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("vendor/cimport_root.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Same `-I` order as `configureSysDeps`: shim path first so it
    // shadows the system gdkversionmacros.h.
    tc.addIncludePath(b.path("vendor/aro_shims"));
    const pkgs = [_][]const u8{
        "gtk4",
        "libadwaita-1",
        "freetype2",
        "harfbuzz",
        "epoxy",
        "fribidi",
        "fontconfig",
    };
    for (pkgs) |p| {
        const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", p });
        var it_inc = std.mem.tokenizeAny(u8, cflags, " \r\n\t");
        while (it_inc.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-I")) {
                tc.addIncludePath(.{ .cwd_relative = b.dupe(tok[2..]) });
            }
        }
    }
    tc.addIncludePath(b.path("vendor"));

    // Post-process: replace `_ = @ptrCast(@alignCast(<expr>));` with
    // `_ = <expr>;`. Aro emits the redundant casts when translating
    // discarded calls like `g_object_ref(x);` and Zig 0.16 rejects
    // `_ = @ptrCast(...)` because the result type is unknown at the
    // discard site. The capture is `[^;]+` rather than `.+` so it can
    // never run past the statement-terminating `;` — `.+` is greedy and
    // would corrupt two such discards sharing one line. Aro emits one
    // per line today, but the negated class keeps the rewrite correct
    // regardless of future output shape (the expr never contains `;`).
    const fix = b.addSystemCommand(&.{
        "sed",
        "-E",
        "s/_ = @ptrCast\\(@alignCast\\(([^;]+)\\)\\);/_ = \\1;/g",
    });
    fix.addFileArg(tc.getOutput());
    const fixed = fix.captureStdOut(.{ .basename = "cimport_root_fixed.zig" });

    return b.createModule(.{
        .root_source_file = fixed,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
}

/// Register the shared system-library / C-source / include-path set
/// on a module. Also wires the pre-translated C bindings module as
/// `@import("cbindings")` so `src/c.zig` can re-export it.
///
/// pkg-config is invoked here directly (rather than via `linkSystemLibrary`)
/// so we control include-path order: `vendor/aro_shims/` must come
/// FIRST so the patched `gdk/version/gdkversionmacros.h` shadows the
/// system one. (Aro reads gdkversionmacros.h's `#error` guard at line
/// 18 every re-include — its `#pragma once` lives at line 22, too
/// late to stop re-processing.)
/// Lean dependency set for GTK-free binaries built on the terminal
/// core (sketerm-mux): cbindings decls, fribidi (grid/bidi.zig),
/// vendored stb_image (kitty/iterm image decode), libc. Keep this
/// list minimal — every entry is something a server must have.
fn configureCoreDeps(
    b: *std.Build,
    mod: *std.Build.Module,
    cbindings_mod: *std.Build.Module,
) void {
    mod.addImport("cbindings", cbindings_mod);
    mod.addIncludePath(b.path("vendor/aro_shims"));
    addPkgConfig(b, mod, "fribidi");
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    mod.addIncludePath(b.path("vendor"));
}

fn configureSysDeps(
    b: *std.Build,
    mod: *std.Build.Module,
    cbindings_mod: *std.Build.Module,
) void {
    const sys_libs = [_][]const u8{
        "gtk4",
        "libadwaita-1",
        "freetype2",
        "harfbuzz",
        "epoxy",
        "fribidi",
        "fontconfig",
    };
    mod.addImport("cbindings", cbindings_mod);
    mod.addIncludePath(b.path("vendor/aro_shims"));
    for (sys_libs) |lib| addPkgConfig(b, mod, lib);
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    mod.addIncludePath(b.path("vendor"));
}

/// Resolve a pkg-config package and split its output into include
/// paths (added via `addIncludePath` AFTER any earlier shim paths) and
/// library names (added via `linkSystemLibrary` with `use_pkg_config =
/// .no` so the Zig build system doesn't reinvoke pkg-config).
fn addPkgConfig(b: *std.Build, mod: *std.Build.Module, pkg: []const u8) void {
    const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", pkg });
    var it_inc = std.mem.tokenizeAny(u8, cflags, " \r\n\t");
    while (it_inc.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            const path = tok[2..];
            mod.addIncludePath(.{ .cwd_relative = b.dupe(path) });
        }
    }

    const libs = b.run(&.{ "pkg-config", "--libs-only-l", pkg });
    var it_lib = std.mem.tokenizeAny(u8, libs, " \r\n\t");
    while (it_lib.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-l")) {
            mod.linkSystemLibrary(tok[2..], .{ .use_pkg_config = .no });
        }
    }
}
