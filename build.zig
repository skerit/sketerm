const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // LLD is pinned on Linux because the self-hosted ELF linker
    // chokes on gcc 15's `.sframe` relocs in crt1.o. On macOS the
    // self-hosted Mach-O linker is the supported path — LLD's
    // Mach-O port is not.
    const use_lld = target.result.os.tag == .linux;

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

    // Lean translation of `vendor/cimport_core.h` for the GTK-free
    // mux binaries — keeps their libc surface explicit and identical
    // to what the musl-targeted mux-portable build sees.
    const core_cbindings_mod = buildCoreCBindings(b, target, optimize);

    // Build options: `glib` tells pty.zig whether a GLib main loop
    // exists (GUI) or not (sketerm-mux daemon, which must not link
    // glib and uses blocking fallbacks for the write queue).
    // `winstream_sck` enables the ScreenCaptureKit window-stream
    // backend (winstream/sck.zig + sck_shim.m): only on NATIVE
    // macOS builds — cross builds (mux-portable from Linux) have no
    // macOS SDK to link the frameworks against.
    const native_sck = b.graph.host.result.os.tag == .macos and
        target.result.os.tag == .macos;
    // Same condition, named for the NSAccessibility bridge (a11y/nsax*):
    // its ObjC shim only builds on a native macOS toolchain.
    const native_macos = native_sck;
    // Software H.264 (libx264) for the lossy video-tile path. Dynamically
    // linked on native builds when present (declared a package dep, like
    // gtk4); the musl-portable daemon never gets it and falls back to
    // lossless. Auto-detected so the default `zig build`/`test` exercises
    // it wherever x264 is installed; `-Dvideo=false` forces it off.
    const have_x264 = b.option(bool, "video", "H.264 video-tile codec via libx264 — requires libx264 (default off)") orelse false;
    const glib_opts = b.addOptions();
    glib_opts.addOption(bool, "glib", true);
    glib_opts.addOption(bool, "winstream_sck", native_sck);
    glib_opts.addOption(bool, "video", have_x264);
    const glib_opts_mod = glib_opts.createModule();
    const noglib_opts = b.addOptions();
    noglib_opts.addOption(bool, "glib", false);
    noglib_opts.addOption(bool, "winstream_sck", native_sck);
    noglib_opts.addOption(bool, "video", have_x264);
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
    // NSAccessibility bridge for the (nascent) AppKit pane: link the
    // ObjC shim so the future frontend can call a11y/nsax.zig. main.zig
    // force-includes nsax.zig on macOS so its export callbacks are
    // present for the shim to resolve.
    if (native_macos) addNsaxBridge(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "sketerm",
        .root_module = exe_mod,
        .use_lld = use_lld,
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
    configureCoreDeps(b, mux_mod, core_cbindings_mod);
    mux_mod.addImport("build_options", noglib_opts_mod);
    if (native_sck) addSckBackend(b, mux_mod);
    if (have_x264) addVideo(b, mux_mod); // daemon-side x264 encode (-Dvideo)
    const mux_exe = b.addExecutable(.{
        .name = "sketerm-mux",
        .root_module = mux_mod,
        .use_lld = use_lld,
    });
    b.installArtifact(mux_exe);
    const mux_step = b.step("mux", "Build the sketerm-mux session daemon");
    mux_step.dependOn(&b.addInstallArtifact(mux_exe, .{}).step);

    // Portable daemon for server deployment — `zig build mux-portable`.
    // The default build targets the NATIVE CPU (ReleaseFast), so a
    // binary built on a Zen 4 laptop SIGILLs on a Zen 2 server (AVX-512
    // in, e.g., memcpy-sized vector loops). This artifact is baseline
    // CPU + static musl: one binary that runs on any Linux box of the
    // same architecture, regardless of CPU generation or libc. Cross-
    // arch via `-Dportable-target=aarch64-linux-musl`.
    // fribidi is deliberately NOT linked: the daemon never calls bidi
    // (ldd of the native build confirms it's dropped), and there is no
    // static musl fribidi on build hosts. A new daemon-side fribidi
    // reference fails this link — that's the desired signal.
    const portable_triple = b.option(
        []const u8,
        "portable-target",
        "target triple for mux-portable (default x86_64-linux-musl)",
    ) orelse "x86_64-linux-musl";
    const portable_query = std.Target.Query.parse(.{
        .arch_os_abi = portable_triple,
    }) catch @panic("bad -Dportable-target triple");
    const portable_target = b.resolveTargetQuery(portable_query);
    const portable_cbindings = buildCoreCBindings(b, portable_target, optimize);
    const mux_portable_mod = b.createModule(.{
        .root_source_file = b.path("src/mux_main.zig"),
        .target = portable_target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    mux_portable_mod.addImport("cbindings", portable_cbindings);
    addPkgConfigIncludes(b, mux_portable_mod, "fribidi");
    mux_portable_mod.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    addZstd(b, mux_portable_mod);
    mux_portable_mod.addIncludePath(b.path("vendor"));
    // mux-portable NEVER carries the ScreenCaptureKit backend:
    // explicit -Dportable-target triples count as cross builds, so
    // zig adds no macOS SDK framework search paths — even on a Mac
    // host. A capture-capable Mac daemon is the native `zig build
    // mux`; portable stays the lowest-common-denominator artifact.
    const portable_opts = b.addOptions();
    portable_opts.addOption(bool, "glib", false);
    portable_opts.addOption(bool, "winstream_sck", false);
    portable_opts.addOption(bool, "video", false);
    mux_portable_mod.addImport("build_options", portable_opts.createModule());
    const mux_portable_exe = b.addExecutable(.{
        .name = "sketerm-mux-portable",
        .root_module = mux_portable_mod,
        // Keyed on the PORTABLE triple, not the host target — a
        // `-Dportable-target=aarch64-macos` cross build needs the
        // self-hosted Mach-O linker.
        .use_lld = portable_target.result.os.tag == .linux,
    });
    const mux_portable_step = b.step(
        "mux-portable",
        "Build a baseline-CPU static-musl sketerm-mux for scp-to-server",
    );
    mux_portable_step.dependOn(&b.addInstallArtifact(mux_portable_exe, .{}).step);

    // Mux end-to-end smoke — `zig build smoke-mux` (headless).
    const smoke_mux_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_mux.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, smoke_mux_mod, core_cbindings_mod);
    smoke_mux_mod.addImport("build_options", noglib_opts_mod);
    if (native_sck) addSckBackend(b, smoke_mux_mod);
    if (have_x264) addVideo(b, smoke_mux_mod);
    const smoke_mux = b.addExecutable(.{
        .name = "sketerm-smoke-mux",
        .root_module = smoke_mux_mod,
        .use_lld = use_lld,
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
        .use_lld = use_lld,
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
        .use_lld = use_lld,
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
        .use_lld = use_lld,
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
        .use_lld = use_lld,
    });
    b.installArtifact(bench);
    const bench_run = b.addRunArtifact(bench);
    const bench_step = b.step("bench-parser", "Parser microbenchmark");
    bench_step.dependOn(&bench_run.step);

    // The headless GL harnesses below (smoke-image, smoke-cell,
    // bench-cell-upload, smoke-transparency, smoke-gl-core) drive GL
    // through EGL surfaceless contexts — there is no EGL on macOS, so
    // they are registered only for Linux targets. `zig build test`
    // plus running the app is the macOS verification path.
    const has_egl = target.result.os.tag == .linux;

    // Headless image-render smoke — `zig build smoke-image`.
    if (has_egl) {
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
        .use_lld = use_lld,
    });
    b.installArtifact(smoke);
    const smoke_run = b.addRunArtifact(smoke);
    const smoke_step = b.step("smoke-image", "Headless GL image render check");
    smoke_step.dependOn(&smoke_run.step);
    }

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
        .use_lld = use_lld,
    });
    b.installArtifact(smoke_e2e);
    const smoke_e2e_run = b.addRunArtifact(smoke_e2e);
    // It execs zig-out/bin/sketerm, so the main install must finish
    // first, and the cwd must be the project root (default).
    smoke_e2e_run.step.dependOn(b.getInstallStep());
    smoke_e2e_run.setCwd(b.path("."));
    const smoke_e2e_step = b.step("smoke-e2e", "End-to-end smoke via remote-control socket (needs display)");
    smoke_e2e_step.dependOn(&smoke_e2e_run.step);

    // macOS NSAccessibility smoke — `zig build smoke-a11y`. Drives a
    // real SketermTermView through the AX selectors VoiceOver uses and
    // asserts they match a known screen (incl. an astral char, so the
    // codepoint→UTF-16 translation is checked end-to-end). Native macOS
    // only: it links the ObjC accessibility shim + a test probe.
    if (native_macos) {
        const smoke_a11y_mod = b.createModule(.{
            .root_source_file = b.path("src/smoke_a11y_macos.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        configureSysDeps(b, smoke_a11y_mod, cbindings_mod);
        smoke_a11y_mod.addImport("build_options", glib_opts_mod);
        addNsaxBridge(b, smoke_a11y_mod);
        smoke_a11y_mod.addCSourceFile(.{
            .file = b.path("src/a11y/nsax_probe.m"),
            .flags = &.{"-fobjc-arc"},
        });
        const smoke_a11y = b.addExecutable(.{
            .name = "sketerm-smoke-a11y",
            .root_module = smoke_a11y_mod,
            .use_lld = use_lld,
        });
        const smoke_a11y_run = b.addRunArtifact(smoke_a11y);
        const smoke_a11y_step = b.step("smoke-a11y", "macOS NSAccessibility round-trip check (native macOS only)");
        smoke_a11y_step.dependOn(&smoke_a11y_run.step);
    }

    // Headless cell-render smoke — `zig build smoke-cell`. Drives a
    // small Screen → Atlas → CellPass → GridPass through an EGL
    // surfaceless context, reads pixels back, asserts text + focus
    // border were rendered. Catches regressions in the instanced
    // cell pipeline + multi-page atlas.
    if (has_egl) {
    const smoke_cell_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_cell.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, smoke_cell_mod, cbindings_mod);
    smoke_cell_mod.addImport("build_options", glib_opts_mod);
    smoke_cell_mod.linkSystemLibrary("EGL", .{});
    // The shipped CRT shader, embedded so the smoke test compiles
    // and runs the REAL file (data/ is outside the module root).
    smoke_cell_mod.addAnonymousImport("crt_glsl", .{
        .root_source_file = b.path("data/shaders/crt.glsl"),
    });
    smoke_cell_mod.addAnonymousImport("crt_lottes_glsl", .{
        .root_source_file = b.path("data/shaders/crt-lottes.glsl"),
    });
    // GPL-licensed port files — embedded ONLY into this test binary,
    // which is never distributed (see data/shaders/README).
    smoke_cell_mod.addAnonymousImport("crt_easymode_glsl", .{
        .root_source_file = b.path("data/shaders/crt-easymode.glsl"),
    });
    smoke_cell_mod.addAnonymousImport("zfast_crt_glsl", .{
        .root_source_file = b.path("data/shaders/zfast-crt.glsl"),
    });
    const smoke_cell = b.addExecutable(.{
        .name = "sketerm-smoke-cell",
        .root_module = smoke_cell_mod,
        .use_lld = use_lld,
    });
    b.installArtifact(smoke_cell);
    const smoke_cell_run = b.addRunArtifact(smoke_cell);
    const smoke_cell_step = b.step("smoke-cell", "Headless GL cell-pipeline render check");
    smoke_cell_step.dependOn(&smoke_cell_run.step);
    }

    // Headless cell-upload microbench — `zig build bench-cell-upload`.
    // Same EGL surfaceless context as smoke-cell, but at 4K with a
    // realistic-sized cell grid, looped to measure per-frame upload +
    // draw + GPU-finish latency. Used to isolate GL cost from GTK4 /
    // Wayland integration when chasing render stalls.
    if (has_egl) {
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
        .use_lld = use_lld,
    });
    b.installArtifact(bench_cell);
    const bench_cell_run = b.addRunArtifact(bench_cell);
    const bench_cell_step = b.step("bench-cell-upload", "Headless cell-upload microbench (isolates GL from GTK)");
    bench_cell_step.dependOn(&bench_cell_run.step);
    }

    // Headless transparency smoke — `zig build smoke-transparency`.
    // Drives the same stack as smoke-cell but with bg alpha=0.5,
    // asserts the readback FBO retains translucency. Plan-v3 had
    // this gating C; added retroactively as regression coverage.
    if (has_egl) {
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
        .use_lld = use_lld,
    });
    b.installArtifact(smoke_trans);
    const smoke_trans_run = b.addRunArtifact(smoke_trans);
    const smoke_trans_step = b.step("smoke-transparency", "Headless GL bg-alpha render check");
    smoke_trans_step.dependOn(&smoke_trans_run.step);
    }

    // Desktop-GL core shader smoke — `zig build smoke-gl-core`.
    // Compiles every shader under a GL 3.3 core context: the macOS
    // GDK path, provable on a Linux box via Mesa's EGL desktop-GL.
    if (has_egl) {
    const smoke_core_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_gl_core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, smoke_core_mod, cbindings_mod);
    smoke_core_mod.addImport("build_options", glib_opts_mod);
    smoke_core_mod.linkSystemLibrary("EGL", .{});
    smoke_core_mod.addAnonymousImport("crt_glsl", .{
        .root_source_file = b.path("data/shaders/crt.glsl"),
    });
    const smoke_core = b.addExecutable(.{
        .name = "sketerm-smoke-gl-core",
        .root_module = smoke_core_mod,
        .use_lld = use_lld,
    });
    b.installArtifact(smoke_core);
    const smoke_core_run = b.addRunArtifact(smoke_core);
    const smoke_core_step = b.step("smoke-gl-core", "Compile all shaders under desktop GL 3.3 core (macOS GL path)");
    smoke_core_step.dependOn(&smoke_core_run.step);
    }

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, tests_mod, cbindings_mod);
    tests_mod.addImport("build_options", glib_opts_mod);
    if (native_sck) addSckBackend(b, tests_mod);
    // Link the NSAccessibility shim so `zig build test` compiles AND
    // links the macOS a11y bridge end-to-end (tests.zig imports nsax.zig).
    if (native_macos) addNsaxBridge(b, tests_mod);
    // libx264 + shim so `zig build test` compiles AND exercises the
    // vcodec x264 backend wherever x264 is installed.
    if (have_x264) addVideo(b, tests_mod);
    const tests = b.addTest(.{
        .root_module = tests_mod,
        .use_lld = use_lld,
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

/// Translate the lean core header set (`vendor/cimport_core.h`) for
/// GTK-free binaries. Separate from `buildCBindings` because the full
/// set drags in GTK system headers, which only translate against the
/// native glibc — the portable musl daemon needs a root that stays
/// libc-clean. Translated output lands at
/// `.zig-cache/o/*/cimport_core_fixed.zig`.
fn buildCoreCBindings(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("vendor/cimport_core.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", "fribidi" });
    var it_inc = std.mem.tokenizeAny(u8, cflags, " \r\n\t");
    while (it_inc.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            tc.addIncludePath(.{ .cwd_relative = b.dupe(tok[2..]) });
        }
    }
    tc.addIncludePath(b.path("vendor"));

    // Same discard-cast fixup as the full set (see buildCBindings);
    // harmless when the pattern never matches.
    const fix = b.addSystemCommand(&.{
        "sed",
        "-E",
        "s/_ = @ptrCast\\(@alignCast\\(([^;]+)\\)\\);/_ = \\1;/g",
    });
    fix.addFileArg(tc.getOutput());
    const fixed = fix.captureStdOut(.{ .basename = "cimport_core_fixed.zig" });

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
    addZstd(b, mod);
    mod.addIncludePath(b.path("vendor"));
}

/// Vendored single-file zstd, compiled statically into every artifact
/// that links src/wlhost/pixcodec.zig (called via extern fn — no header
/// needed). Self-contained C (ASM + legacy disabled in the amalgamation),
/// so it links the native daemon, the GUI, AND the musl-static portable
/// binary alike. See vendor/zstd/PROVENANCE.txt.
fn addZstd(b: *std.Build, mod: *std.Build.Module) void {
    mod.addCSourceFile(.{
        .file = b.path("vendor/zstd/zstd.c"),
        .flags = &.{ "-O3", "-Wno-unused-function", "-Wno-unused-but-set-variable", "-Wno-unused-parameter" },
    });
}

/// libx264 + the C shim (vendor/x264_shim.c) for the lossy video path.
/// Dynamically links the SYSTEM x264 (declared a package dep) rather
/// than vendoring it — x264's speed lives in per-arch asm, so a vendored
/// C-only build would be too slow, and the optional video path can be
/// absent on the portable binary (→ lossless). Gated on build_options.video.
fn addVideo(b: *std.Build, mod: *std.Build.Module) void {
    addPkgConfig(b, mod, "x264");
    mod.addCSourceFile(.{
        .file = b.path("vendor/x264_shim.c"),
        .flags = &.{"-O2"},
    });
    mod.addIncludePath(b.path("vendor"));
}

/// ScreenCaptureKit window-stream backend (macOS native builds
/// only): the ObjC capture/input shim plus the frameworks it needs.
/// Gated on `winstream_sck` — never call this for cross targets.
fn addSckBackend(b: *std.Build, mod: *std.Build.Module) void {
    mod.addCSourceFile(.{
        .file = b.path("src/winstream/sck_shim.m"),
        .flags = &.{"-fobjc-arc"},
    });
    mod.linkFramework("ScreenCaptureKit", .{});
    mod.linkFramework("CoreMedia", .{});
    mod.linkFramework("CoreVideo", .{});
    mod.linkFramework("CoreGraphics", .{});
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("ApplicationServices", .{});
    mod.linkFramework("Foundation", .{});
}

/// NSAccessibility (VoiceOver) bridge (macOS native builds only): the
/// ObjC `SketermTermView` shim + the frameworks it needs. Pairs with
/// the `export fn` callbacks in a11y/nsax.zig. Gated on `native_macos`.
fn addNsaxBridge(b: *std.Build, mod: *std.Build.Module) void {
    mod.addCSourceFile(.{
        .file = b.path("src/a11y/nsax_shim.m"),
        .flags = &.{"-fobjc-arc"},
    });
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("Foundation", .{});
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
    // Per-window WM_CLASS for remote app windows (wlapp.zig calls
    // XChangeProperty directly — GTK links X11 but doesn't re-export
    // it). Linux-only; the macOS GUI has no X11.
    if (mod.resolved_target.?.result.os.tag == .linux) {
        mod.linkSystemLibrary("X11", .{ .use_pkg_config = .yes });
    }
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    addZstd(b, mod);
    mod.addIncludePath(b.path("vendor"));
}

/// Resolve a pkg-config package and split its output into include
/// paths (added via `addIncludePath` AFTER any earlier shim paths) and
/// library names (added via `linkSystemLibrary` with `use_pkg_config =
/// .no` so the Zig build system doesn't reinvoke pkg-config).
fn addPkgConfig(b: *std.Build, mod: *std.Build.Module, pkg: []const u8) void {
    addPkgConfigIncludes(b, mod, pkg);

    // Library search paths (`-L`). Zig resolves dynamic system libs
    // itself at the build-exe stage (`paths_first`) and only searches
    // the SDK plus explicit `-L` dirs — it ignores `LIBRARY_PATH`. On a
    // Homebrew (non-/usr/lib) prefix the dylibs are invisible without
    // these, so feed pkg-config's `-L` output before the `-l` names.
    const libdirs = b.run(&.{ "pkg-config", "--libs-only-L", pkg });
    var it_dir = std.mem.tokenizeAny(u8, libdirs, " \r\n\t");
    while (it_dir.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-L")) {
            mod.addLibraryPath(.{ .cwd_relative = b.dupe(tok[2..]) });
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

/// Include paths only — for modules that compile against a package's
/// headers but must not link it (mux-portable: static musl, no system
/// shared libs available).
fn addPkgConfigIncludes(b: *std.Build, mod: *std.Build.Module, pkg: []const u8) void {
    const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", pkg });
    var it_inc = std.mem.tokenizeAny(u8, cflags, " \r\n\t");
    while (it_inc.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            const path = tok[2..];
            mod.addIncludePath(.{ .cwd_relative = b.dupe(path) });
        }
    }
}
