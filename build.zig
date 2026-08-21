const std = @import("std");

/// Single source of truth for the semver: `build.zig.zon`'s `.version`,
/// handed to every target as `build_options.version` and re-exported by
/// `src/version.zig`. `dist/PKGBUILD`'s `pkgver()` greps the same line.
const semver = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // `vendor/pkgconfig/sketerm-gui.pc` (see `gui_pkg`) has to be on the
    // pkg-config search path before any step resolves it.
    registerGuiPkgConfigPath(b);

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

    // LLVM spends minutes optimizing the monolithic test roots. Zig's
    // self-hosted x86 backend compiles the same ReleaseFast suites in
    // seconds; shipped artifacts still use LLVM. Keep an explicit parity
    // switch for compiler-sensitive failures and unsupported hosts.
    const test_llvm = b.option(
        bool,
        "test-llvm",
        "compile unit tests with LLVM (slower; matches production codegen)",
    ) orelse !(target.result.os.tag == .linux and target.result.cpu.arch == .x86_64);

    // Pre-translate the GTK+glib+freetype+stb C headers into a single
    // generated Zig module via a TranslateC step. In Zig 0.16 the
    // in-process `@cImport` on this header set crashes `zig build-exe`
    // (SEGV inside Aro), but the same input through a standalone
    // `zig translate-c` subprocess succeeds. Out-of-process step it
    // is. See `vendor/cimport_root.h` for the headers + workaround
    // defines. pkg-config resolution is attached to this TranslateC
    // step, not run here, so `zig build mux` never probes GUI packages.
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
    // VideoToolbox H.264 encoder — the Mac-native video-tile encode path
    // (no libx264/libavcodec needed; a system framework). Auto-on for a
    // native macOS toolchain so the daemon can produce tiles a -Dvideo
    // client decodes. Only activates when such a client attaches.
    const have_vtenc = native_macos;
    // Opus for the remote-audio path (mux/opuscodec.zig): ~12x less
    // bandwidth than raw PCM. Normal builds probe libopus at runtime,
    // preserving the daemon's dependency-free link graph; portable
    // builds compile the probe out. `false` is an explicit opt-out.
    const have_opus = b.option(bool, "audio-opus", "Runtime Opus compression for remote audio (default on)") orelse true;
    // Runtime EGL/GLES probing imports modifier-backed linux-dmabufs
    // without adding either library to the daemon's ELF dependencies.
    const have_dmabuf_import = target.result.os.tag == .linux and
        (b.option(bool, "dmabuf-import", "Runtime EGL/GLES import for modifier-backed dma-bufs (default on on Linux)") orelse true);
    // Commit id + commit date for Help > About. Stable per commit so a
    // rebuild without new commits stays fully cached; tarball builds
    // without git degrade to "unknown".
    const git_commit = runCapture(b, &.{ "git", "-C", b.build_root.path orelse ".", "describe", "--always", "--dirty" }) orelse "unknown";
    const git_date = runCapture(b, &.{ "git", "-C", b.build_root.path orelse ".", "log", "-1", "--format=%cd", "--date=format:%Y-%m-%d %H:%M" }) orelse "unknown";

    const glib_opts = b.addOptions();
    glib_opts.addOption(bool, "glib", true);
    glib_opts.addOption([]const u8, "version", semver);
    glib_opts.addOption([]const u8, "commit", git_commit);
    glib_opts.addOption([]const u8, "commit_date", git_date);
    glib_opts.addOption(bool, "winstream_sck", native_sck);
    glib_opts.addOption(bool, "video", have_x264);
    glib_opts.addOption(bool, "vtenc", have_vtenc);
    glib_opts.addOption(bool, "audio_opus", have_opus);
    glib_opts.addOption(bool, "dmabuf_import", have_dmabuf_import);
    const glib_opts_mod = glib_opts.createModule();
    const noglib_opts = b.addOptions();
    noglib_opts.addOption(bool, "glib", false);
    noglib_opts.addOption([]const u8, "version", semver);
    noglib_opts.addOption([]const u8, "commit", git_commit);
    noglib_opts.addOption([]const u8, "commit_date", git_date);
    noglib_opts.addOption(bool, "winstream_sck", native_sck);
    noglib_opts.addOption(bool, "video", have_x264);
    noglib_opts.addOption(bool, "vtenc", have_vtenc);
    noglib_opts.addOption(bool, "audio_opus", have_opus);
    noglib_opts.addOption(bool, "dmabuf_import", have_dmabuf_import);
    const noglib_opts_mod = noglib_opts.createModule();

    // Vendored Tree-sitter runtime + grammars for the editor's syntax
    // highlighting. Built once and linked into the GUI-side artifacts
    // only — see `buildTreeSitter`/`addTreeSitter`.
    const tree_sitter = buildTreeSitter(b, target, optimize, use_lld);

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
    if (have_x264) addVideo(b, exe_mod); // GUI-side H.264 decode (-Dvideo)
    if (have_vtenc) addVtEnc(b, exe_mod); // VideoToolbox H.264 encode (macOS)
    addTreeSitter(b, exe_mod, tree_sitter); // editor syntax highlighting (GUI only)

    const exe = b.addExecutable(.{
        .name = "sketerm",
        .root_module = exe_mod,
        .use_lld = use_lld,
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    // Second install of the SAME artifact as `sketerm-files`: the
    // dedicated file manager ships as its own executable (argv[0]
    // dispatch in filebrowser/entry.zig) so desktop taskbars that
    // match windows by process/cmdline can never merge the two apps.
    // The PKGBUILD hardlinks instead of shipping this copy twice.
    b.getInstallStep().dependOn(
        &b.addInstallArtifact(exe, .{ .dest_sub_path = "sketerm-files" }).step,
    );
    b.getInstallStep().dependOn(
        &b.addInstallArtifact(exe, .{ .dest_sub_path = "sketerm-viewer" }).step,
    );
    b.getInstallStep().dependOn(
        &b.addInstallArtifact(exe, .{ .dest_sub_path = "sketerm-editor" }).step,
    );
    // The browser identity is `sketerm-web`; the CEF helper it drives is
    // `sketerm-webengine` precisely so this name stays free for it.
    b.getInstallStep().dependOn(
        &b.addInstallArtifact(exe, .{ .dest_sub_path = "sketerm-web" }).step,
    );

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
    if (have_vtenc) addVtEnc(b, mux_mod); // daemon-side VideoToolbox encode (macOS)
    const mux_exe = b.addExecutable(.{
        .name = "sketerm-mux",
        .root_module = mux_mod,
        .use_lld = use_lld,
    });
    const install_mux = b.addInstallArtifact(mux_exe, .{});
    b.getInstallStep().dependOn(&install_mux.step);
    const mux_step = b.step("mux", "Build the sketerm-mux session daemon");
    mux_step.dependOn(&install_mux.step);

    // Public mux-client SDK — the supported module for OUT-OF-REPO
    // daemon clients (agent harnesses, automation). Consumers add
    // sketerm as a build.zig.zon dependency and import
    // `dep.module("mux-client")`; the module carries its own core
    // cbindings + build_options, so a consumer never touches that
    // plumbing. Same lean dep set as sketerm-mux (libc only, no
    // GTK/GLib) — `mux-client-check` below is the guard that keeps
    // the exported graph that way.
    const mux_client_mod = b.addModule("mux-client", .{
        .root_source_file = b.path("src/mux_client_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, mux_client_mod, core_cbindings_mod);
    mux_client_mod.addImport("build_options", noglib_opts_mod);

    const mux_client_check_mod = b.createModule(.{
        .root_source_file = b.path("src/mux_client_check.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    mux_client_check_mod.addImport("mux-client", mux_client_mod);
    const mux_client_check_exe = b.addExecutable(.{
        .name = "mux-client-check",
        .root_module = mux_client_check_mod,
        .use_lld = use_lld,
    });
    const mux_client_check_step = b.step(
        "mux-client-check",
        "Compile the public mux-client SDK module standalone (guards its lean dep graph)",
    );
    mux_client_check_step.dependOn(&mux_client_check_exe.step);

    // Portable daemon for server deployment — `zig build mux-portable`.
    // The default build targets the NATIVE CPU (ReleaseFast), so a
    // binary built on a Zen 4 laptop SIGILLs on a Zen 2 server (AVX-512
    // in, e.g., memcpy-sized vector loops). This artifact is baseline
    // CPU + static musl: one binary that runs on any Linux box of the
    // same architecture, regardless of CPU generation or libc. Cross-
    // arch via `-Dportable-target=aarch64-linux-musl`. Linux packaging
    // always passes its package architecture explicitly; the x86_64
    // fallback below is only the direct developer-command default.
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
    // Compile the focused test root for every portable target. This analyzes
    // both the production and fault-injected syscall adapters without trying
    // to run a cross-compiled test binary on the build host.
    const atomicwrite_portable_test_mod = b.createModule(.{
        .root_source_file = b.path("src/util/atomicwrite.zig"),
        .target = portable_target,
        .optimize = optimize,
        .link_libc = true,
    });
    atomicwrite_portable_test_mod.addImport("cbindings", portable_cbindings);
    const atomicwrite_portable_tests = b.addTest(.{
        .root_module = atomicwrite_portable_test_mod,
        .use_lld = portable_target.result.os.tag == .linux,
    });
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
    portable_opts.addOption([]const u8, "version", semver);
    portable_opts.addOption([]const u8, "commit", git_commit);
    portable_opts.addOption([]const u8, "commit_date", git_date);
    portable_opts.addOption(bool, "winstream_sck", false);
    portable_opts.addOption(bool, "video", false);
    portable_opts.addOption(bool, "vtenc", false);
    portable_opts.addOption(bool, "audio_opus", false);
    portable_opts.addOption(bool, "dmabuf_import", false);
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
    mux_portable_step.dependOn(&atomicwrite_portable_tests.step);
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
    if (have_vtenc) addVtEnc(b, smoke_mux_mod);
    const smoke_mux = b.addExecutable(.{
        .name = "sketerm-smoke-mux",
        .root_module = smoke_mux_mod,
        .use_lld = use_lld,
    });
    const smoke_mux_run = b.addRunArtifact(smoke_mux);
    // The ticket stage spawns real --udp-listen/--udp-connect children.
    smoke_mux_run.addArtifactArg(mux_exe);
    const smoke_mux_step = b.step("smoke-mux", "Mux daemon end-to-end smoke (headless)");
    smoke_mux_step.dependOn(&smoke_mux_run.step);

    // UDP transport + NAT hole-punch smoke — `zig build smoke-udp`
    // (headless). Drives the REAL bootstrap: fake ssh execs the built
    // sketerm-mux --udp-listen against an isolated in-process daemon,
    // including a wrong-announced-port stage only the punch survives.
    const smoke_udp_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_udp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, smoke_udp_mod, core_cbindings_mod);
    smoke_udp_mod.addImport("build_options", noglib_opts_mod);
    if (native_sck) addSckBackend(b, smoke_udp_mod);
    if (have_x264) addVideo(b, smoke_udp_mod);
    if (have_vtenc) addVtEnc(b, smoke_udp_mod);
    const smoke_udp = b.addExecutable(.{
        .name = "sketerm-smoke-udp",
        .root_module = smoke_udp_mod,
        .use_lld = use_lld,
    });
    const smoke_udp_run = b.addRunArtifact(smoke_udp);
    smoke_udp_run.addArtifactArg(mux_exe);
    const smoke_udp_step = b.step("smoke-udp", "UDP transport + hole-punch smoke (headless)");
    smoke_udp_step.dependOn(&smoke_udp_run.step);

    // xdg-foreign / xdg-dialog smoke — `zig build smoke-foreign`
    // (headless). Daemon thread + scripted raw-Wayland clients:
    // cross-connection parenting, revocation (surface death AND
    // vanished exporter, both through the idle-brain sweep), reattach
    // replay, session-scoped handles, modality.
    const smoke_foreign_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_foreign.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, smoke_foreign_mod, core_cbindings_mod);
    smoke_foreign_mod.addImport("build_options", noglib_opts_mod);
    if (native_sck) addSckBackend(b, smoke_foreign_mod);
    if (have_x264) addVideo(b, smoke_foreign_mod);
    if (have_vtenc) addVtEnc(b, smoke_foreign_mod);
    const smoke_foreign = b.addExecutable(.{
        .name = "sketerm-smoke-foreign",
        .root_module = smoke_foreign_mod,
        .use_lld = use_lld,
    });
    const smoke_foreign_run = b.addRunArtifact(smoke_foreign);
    const smoke_foreign_step = b.step("smoke-foreign", "xdg-foreign cross-connection parenting smoke (headless)");
    smoke_foreign_step.dependOn(&smoke_foreign_run.step);

    // File-service smoke — `zig build smoke-fs` (headless). Daemon
    // thread + fsdrive client: listings, live view deltas, verbs,
    // ranged read/write, monolith AND broker mode.
    const smoke_fs_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_fs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, smoke_fs_mod, core_cbindings_mod);
    smoke_fs_mod.addImport("build_options", noglib_opts_mod);
    if (native_sck) addSckBackend(b, smoke_fs_mod);
    if (have_x264) addVideo(b, smoke_fs_mod);
    if (have_vtenc) addVtEnc(b, smoke_fs_mod);
    const smoke_fs = b.addExecutable(.{
        .name = "sketerm-smoke-fs",
        .root_module = smoke_fs_mod,
        .use_lld = use_lld,
    });
    const smoke_fs_run = b.addRunArtifact(smoke_fs);
    const smoke_fs_step = b.step("smoke-fs", "Mux file-service end-to-end smoke (headless)");
    smoke_fs_step.dependOn(&smoke_fs_run.step);

    // FUSE-mount smoke — `zig build smoke-fuse` (headless; SKIPs
    // where fusermount3 / /dev/fuse is unavailable). Daemon thread +
    // fsmount serve thread + kernel-visible file ops.
    const smoke_fuse_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_fuse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, smoke_fuse_mod, core_cbindings_mod);
    smoke_fuse_mod.addImport("build_options", noglib_opts_mod);
    if (native_sck) addSckBackend(b, smoke_fuse_mod);
    if (have_x264) addVideo(b, smoke_fuse_mod);
    if (have_vtenc) addVtEnc(b, smoke_fuse_mod);
    const smoke_fuse = b.addExecutable(.{
        .name = "sketerm-smoke-fuse",
        .root_module = smoke_fuse_mod,
        .use_lld = use_lld,
    });
    const smoke_fuse_run = b.addRunArtifact(smoke_fuse);
    const smoke_fuse_step = b.step("smoke-fuse", "FUSE mount end-to-end smoke (headless)");
    smoke_fuse_step.dependOn(&smoke_fuse_run.step);

    // MCP isolation + headless-terminal smoke — `zig build smoke-mcp`.
    // Spawns `zig-out/bin/sketerm mcp` and drives it over stdio; only
    // needs /bin/sh (no display / GUI apps / a11y bus).
    const smoke_mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_mcp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, smoke_mcp_mod, core_cbindings_mod);
    smoke_mcp_mod.addImport("build_options", noglib_opts_mod);
    if (native_sck) addSckBackend(b, smoke_mcp_mod);
    if (have_x264) addVideo(b, smoke_mcp_mod);
    if (have_vtenc) addVtEnc(b, smoke_mcp_mod);
    const smoke_mcp = b.addExecutable(.{
        .name = "sketerm-smoke-mcp",
        .root_module = smoke_mcp_mod,
        .use_lld = use_lld,
    });
    const smoke_mcp_run = b.addRunArtifact(smoke_mcp);
    smoke_mcp_run.step.dependOn(&install_exe.step);
    smoke_mcp_run.step.dependOn(&install_mux.step);
    smoke_mcp_run.setCwd(b.path("."));
    const smoke_mcp_step = b.step("smoke-mcp", "MCP isolation + headless-terminal smoke (headless)");
    smoke_mcp_step.dependOn(&smoke_mcp_run.step);

    // Broker (process-isolation) smoke — `zig build smoke-broker` (headless).
    const smoke_broker_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_broker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, smoke_broker_mod, core_cbindings_mod);
    smoke_broker_mod.addImport("build_options", noglib_opts_mod);
    if (native_sck) addSckBackend(b, smoke_broker_mod);
    if (have_x264) addVideo(b, smoke_broker_mod);
    if (have_vtenc) addVtEnc(b, smoke_broker_mod);
    const smoke_broker = b.addExecutable(.{
        .name = "sketerm-smoke-broker",
        .root_module = smoke_broker_mod,
        .use_lld = use_lld,
    });
    const smoke_broker_run = b.addRunArtifact(smoke_broker);
    // The ticket stage spawns real --udp-listen/--udp-connect children.
    smoke_broker_run.addArtifactArg(mux_exe);
    const smoke_broker_step = b.step("smoke-broker", "Broker process-isolation end-to-end smoke (headless)");
    smoke_broker_step.dependOn(&smoke_broker_run.step);

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
    const bench_run = b.addRunArtifact(bench);
    const bench_step = b.step("bench-parser", "Parser microbenchmark");
    bench_step.dependOn(&bench_run.step);

    // Editor text-core benchmark — `zig build bench-editor [-- --quick]`.
    // Core dependency set only: the rope/document/unicode core is GTK-free
    // and must stay that way, so this target links what `sketerm-mux` does.
    const bench_ed_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_editor.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    configureCoreDeps(b, bench_ed_mod, core_cbindings_mod);
    bench_ed_mod.addImport("build_options", noglib_opts_mod);
    const bench_ed = b.addExecutable(.{
        .name = "sketerm-bench-editor",
        .root_module = bench_ed_mod,
        .use_lld = use_lld,
    });
    const bench_ed_run = b.addRunArtifact(bench_ed);
    if (b.args) |args| bench_ed_run.addArgs(args);
    const bench_ed_step = b.step("bench-editor", "Editor rope/document large-file benchmark");
    bench_ed_step.dependOn(&bench_ed_run.step);

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
    const smoke_run = b.addRunArtifact(smoke);
    const smoke_step = b.step("smoke-image", "Headless GL image render check");
    smoke_step.dependOn(&smoke_run.step);
    }

    // End-to-end GUI smoke — `zig build smoke-e2e`. Fully headless and
    // self-hosted: it starts a private daemon, asks it for a display
    // session, and runs the built app as a Wayland client of sketerm's
    // own compositor. Drives it over the remote-control socket AND over
    // a real seat (keys/clicks + pixel assertions). No Xvfb — X11
    // changes GTK's input-method behaviour and produces false greens.
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
    const smoke_e2e_run = b.addRunArtifact(smoke_e2e);
    // It execs the canonical GUI and daemon from zig-out/bin.
    smoke_e2e_run.step.dependOn(&install_exe.step);
    smoke_e2e_run.step.dependOn(&install_mux.step);
    smoke_e2e_run.setCwd(b.path("."));
    const smoke_e2e_step = b.step("smoke-e2e", "End-to-end GUI smoke on sketerm's own compositor (headless, no X)");
    smoke_e2e_step.dependOn(&smoke_e2e_run.step);

    // Remote-playback smoke — `zig build smoke-stream` (headless, no
    // display): daemon thread + the viewer's remotestream GObject driven
    // as giostreamsrc drives it, both transcode and raw modes.
    const smoke_stream_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_stream.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, smoke_stream_mod, cbindings_mod);
    smoke_stream_mod.addImport("build_options", glib_opts_mod);
    const smoke_stream = b.addExecutable(.{
        .name = "sketerm-smoke-stream",
        .root_module = smoke_stream_mod,
        .use_lld = use_lld,
    });
    const smoke_stream_run = b.addRunArtifact(smoke_stream);
    const smoke_stream_step = b.step("smoke-stream", "Remote video playback stream smoke: daemon transcode spool + GIO stream (headless)");
    smoke_stream_step.dependOn(&smoke_stream_run.step);

    // Browser measurement rig — `zig build measure-web`. Same display-
    // session recipe as smoke-e2e, plus a fractional viewer scale, for
    // the hover-latency and sharpness numbers (src/web_measure.zig).
    {
        const wm_mod = b.createModule(.{
            .root_source_file = b.path("src/web_measure.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        configureSysDeps(b, wm_mod, cbindings_mod);
        wm_mod.addImport("build_options", glib_opts_mod);
        const wm = b.addExecutable(.{
            .name = "sketerm-web-measure",
            .root_module = wm_mod,
            .use_lld = use_lld,
        });
        const wm_run = b.addRunArtifact(wm);
        wm_run.step.dependOn(&install_exe.step);
        wm_run.step.dependOn(&install_mux.step);
        wm_run.setCwd(b.path("."));
        if (b.args) |args| wm_run.addArgs(args);
        const wm_step = b.step("measure-web", "Browser latency/sharpness measurement rig (headless display session)");
        wm_step.dependOn(&wm_run.step);
    }

    // LSP GUI smoke — `zig build smoke-lsp-gui`. Same rig as smoke-e2e
    // (private daemon, display session, viewer attached first), running
    // the real editor against a real language server:
    // typescript-language-server when it is on PATH, else the scripted
    // sketerm-lsp-stub. Asserts diagnostics render and that the
    // completion / hover popups actually open, with screenshots.
    const smoke_lsp_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_lsp_gui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, smoke_lsp_mod, cbindings_mod);
    smoke_lsp_mod.addImport("build_options", glib_opts_mod);
    const smoke_lsp = b.addExecutable(.{
        .name = "sketerm-smoke-lsp-gui",
        .root_module = smoke_lsp_mod,
        .use_lld = use_lld,
    });
    const smoke_lsp_run = b.addRunArtifact(smoke_lsp);
    smoke_lsp_run.step.dependOn(&install_exe.step);
    smoke_lsp_run.step.dependOn(&install_mux.step);
    smoke_lsp_run.setCwd(b.path("."));
    const smoke_lsp_step = b.step("smoke-lsp-gui", "Drive the real editor GUI against a real language server (headless, no X)");
    smoke_lsp_step.dependOn(&smoke_lsp_run.step);

    // AT-SPI accessibility smoke — `zig build smoke-atspi` (Linux).
    // Same self-hosted rig as smoke-e2e, PLUS a private accessibility
    // bus (dbus-daemon + at-spi2-registryd via mux/a11yhub.zig): the
    // GUI runs with GTK_A11Y=atspi on that bus and the harness asserts
    // real org.a11y.atspi.Text replies — terminal text, caret motion,
    // drag selection. Separate from smoke-e2e on purpose: that harness
    // pins GTK_A11Y=none so its GUI children can never register on the
    // user's live a11y bus. SKIPs where the bus tooling is absent.
    if (!native_macos) {
        const smoke_atspi_mod = b.createModule(.{
            .root_source_file = b.path("src/smoke_atspi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        configureSysDeps(b, smoke_atspi_mod, cbindings_mod);
        smoke_atspi_mod.addImport("build_options", glib_opts_mod);
        const smoke_atspi = b.addExecutable(.{
            .name = "sketerm-smoke-atspi",
            .root_module = smoke_atspi_mod,
            .use_lld = use_lld,
        });
        const smoke_atspi_run = b.addRunArtifact(smoke_atspi);
        smoke_atspi_run.step.dependOn(&install_exe.step);
        smoke_atspi_run.step.dependOn(&install_mux.step);
        smoke_atspi_run.setCwd(b.path("."));
        const smoke_atspi_step = b.step("smoke-atspi", "Terminal-pane AT-SPI accessibility smoke on a private a11y bus (headless, no X)");
        smoke_atspi_step.dependOn(&smoke_atspi_run.step);
    }

    // Web-page AT-SPI projection smoke — `zig build smoke-webax`.
    // No CEF and no GUI: wire frames feed the mirrored AX tree, the
    // pure-Zig projection embeds it on a private a11y bus, and the
    // daemon's own AT-SPI client walks the registry and asserts roles,
    // names, extents and incremental updates. SKIPs where the bus
    // tooling is absent.
    if (!native_macos) {
        const smoke_webax_mod = b.createModule(.{
            .root_source_file = b.path("src/smoke_webax.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        configureSysDeps(b, smoke_webax_mod, cbindings_mod);
        smoke_webax_mod.addImport("build_options", glib_opts_mod);
        const smoke_webax = b.addExecutable(.{
            .name = "sketerm-smoke-webax",
            .root_module = smoke_webax_mod,
            .use_lld = use_lld,
        });
        const smoke_webax_run = b.addRunArtifact(smoke_webax);
        smoke_webax_run.setCwd(b.path("."));
        const smoke_webax_step = b.step("smoke-webax", "Web-page AT-SPI projection smoke on a private a11y bus (no CEF, no GUI)");
        smoke_webax_step.dependOn(&smoke_webax_run.step);
    }

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
    const smoke_trans_run = b.addRunArtifact(smoke_trans);
    const smoke_trans_step = b.step("smoke-transparency", "Headless GL bg-alpha render check");
    smoke_trans_step.dependOn(&smoke_trans_run.step);
    }

    // Proportional-text editor spike — `zig build spike-editor-text`.
    // Proves the Atlas + HarfBuzz + gl.zig stack renders variable-
    // width text headlessly (EGL surfaceless, same as smoke-cell) and
    // that shaping cluster maps support pixel<->byte hit testing.
    if (has_egl) {
    const spike_editor_mod = b.createModule(.{
        .root_source_file = b.path("src/spike_editor_text.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, spike_editor_mod, cbindings_mod);
    spike_editor_mod.addImport("build_options", glib_opts_mod);
    spike_editor_mod.linkSystemLibrary("EGL", .{});
    const spike_editor = b.addExecutable(.{
        .name = "sketerm-spike-editor-text",
        .root_module = spike_editor_mod,
        .use_lld = use_lld,
    });
    const spike_editor_run = b.addRunArtifact(spike_editor);
    const spike_editor_step = b.step("spike-editor-text", "Headless proportional-text render spike (editor foundation)");
    spike_editor_step.dependOn(&spike_editor_run.step);
    }

    // Scripted stub language server — `sketerm-lsp-stub`. A REAL
    // process speaking the LSP base protocol over stdio, so the smoke
    // rig exercises spawn + pipes + framing without depending on zls or
    // clangd being installed on the build host. Core dependency set:
    // it must stay as GTK-free as the protocol code it tests.
    const lsp_stub_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp_stub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, lsp_stub_mod, core_cbindings_mod);
    lsp_stub_mod.addImport("build_options", noglib_opts_mod);
    const lsp_stub = b.addExecutable(.{
        .name = "sketerm-lsp-stub",
        .root_module = lsp_stub_mod,
        .use_lld = use_lld,
    });
    const install_lsp_stub = b.addInstallArtifact(lsp_stub, .{});
    const lsp_stub_step = b.step("lsp-stub", "Build the scripted stub language server used by the tests");
    lsp_stub_step.dependOn(&install_lsp_stub.step);
    smoke_lsp_run.step.dependOn(&install_lsp_stub.step);

    // Headless editor-pipeline smoke — `zig build smoke-editor`.
    // Renders a real Document through editor_font itemization +
    // editor_layout + EditorPass (EGL surfaceless, same as smoke-cell),
    // asserting itemization, bidi order, hit testing, cache
    // invalidation, and rendered selection/caret pixels.
    if (has_egl) {
    const smoke_editor_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_editor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureSysDeps(b, smoke_editor_mod, cbindings_mod);
    smoke_editor_mod.addImport("build_options", glib_opts_mod);
    smoke_editor_mod.linkSystemLibrary("EGL", .{});
    addTreeSitter(b, smoke_editor_mod, tree_sitter);
    const smoke_editor = b.addExecutable(.{
        .name = "sketerm-smoke-editor",
        .root_module = smoke_editor_mod,
        .use_lld = use_lld,
    });
    const smoke_editor_run = b.addRunArtifact(smoke_editor);
    // The LSP stage spawns the stub server by path; building it first
    // is what makes `zig build smoke-editor` self-contained.
    smoke_editor_run.step.dependOn(&install_lsp_stub.step);
    const smoke_editor_step = b.step("smoke-editor", "Headless editor text pipeline render check");
    smoke_editor_step.dependOn(&smoke_editor_run.step);
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
    if (have_vtenc) addVtEnc(b, tests_mod);
    addTreeSitter(b, tests_mod, tree_sitter);
    const tests = b.addTest(.{
        .root_module = tests_mod,
        .use_llvm = test_llvm,
        .use_lld = if (test_llvm) use_lld else false,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_roots = b.addSystemCommand(&.{ "bash" });
    test_roots.addFileArg(b.path("dist/test-test-roots.sh"));
    test_roots.has_side_effects = true;
    const test_graph_step = b.step("test-graph", "Verify direct unit-test root coverage and dependency tiers");
    test_graph_step.dependOn(&test_roots.step);

    // `errdefer` in a function that cannot return an error compiles
    // clean and never runs. See src/lint_errdefer.zig; every test step
    // depends on it so the class cannot come back.
    const lint_errdefer_mod = b.createModule(.{
        .root_source_file = b.path("src/lint_errdefer.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    // Same trade as `test_llvm` above, but this helper is built for the
    // HOST, so it is the host that must support the self-hosted backend
    // — not the target. On aarch64-macOS `-fno-llvm` dies with SIGKILL,
    // which reds out `test`, `test-core` and `test-web` before a single
    // test runs.
    const lint_self_hosted = b.graph.host.result.os.tag == .linux and
        b.graph.host.result.cpu.arch == .x86_64;
    const lint_errdefer_exe = b.addExecutable(.{
        .name = "sketerm-lint-errdefer",
        .root_module = lint_errdefer_mod,
        .use_llvm = !lint_self_hosted,
        .use_lld = if (lint_self_hosted) false else b.graph.host.result.os.tag == .linux,
    });
    const lint_errdefer_self = b.addRunArtifact(lint_errdefer_exe);
    lint_errdefer_self.addArg("--self-check");
    const lint_errdefer = b.addRunArtifact(lint_errdefer_exe);
    lint_errdefer.addDirectoryArg(b.path("src"));
    lint_errdefer.step.dependOn(&lint_errdefer_self.step);
    const lint_errdefer_step = b.step("lint-errdefer", "Reject `errdefer` in functions that cannot return an error");
    lint_errdefer_step.dependOn(&lint_errdefer.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_roots.step);
    test_step.dependOn(&lint_errdefer.step);
    test_step.dependOn(&run_tests.step);

    const atomicwrite_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/util/atomicwrite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    atomicwrite_tests_mod.addImport("cbindings", core_cbindings_mod);
    const atomicwrite_tests = b.addTest(.{
        .root_module = atomicwrite_tests_mod,
        .use_llvm = test_llvm,
        .use_lld = if (test_llvm) use_lld else false,
    });
    const atomicwrite_test_step = b.step("test-atomicwrite", "Run atomic file replacement tests");
    atomicwrite_test_step.dependOn(&b.addRunArtifact(atomicwrite_tests).step);

    // GTK-free subset — `zig build test-core`. The full `test` step
    // above compiles the GUI, so on a host whose GTK is older than the
    // GUI requires (Ubuntu 22.04 ships 4.6 against the 4.14 the GUI
    // calls into) NOTHING is runnable, daemon logic included. This step
    // uses the same lean dependency set as `sketerm-mux` so the core is
    // always testable wherever the daemon itself builds.
    const coretests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests_core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureCoreDeps(b, coretests_mod, core_cbindings_mod);
    coretests_mod.addImport("build_options", noglib_opts_mod);
    if (native_sck) addSckBackend(b, coretests_mod);
    if (have_x264) addVideo(b, coretests_mod);
    if (have_vtenc) addVtEnc(b, coretests_mod);
    // test-core covers src/editor/syntax.zig, which is GTK-free but
    // tree-sitter-backed. This is the ONLY non-GUI module that gets the
    // C runtime — `mux`/`mux-portable` use configureCoreDeps WITHOUT it,
    // which is what keeps the daemon's link graph clean.
    addTreeSitter(b, coretests_mod, tree_sitter);
    const coretests = b.addTest(.{
        .root_module = coretests_mod,
        .use_llvm = test_llvm,
        .use_lld = if (test_llvm) use_lld else false,
    });
    const core_test_step = b.step("test-core", "Run the GTK-free unit-test subset (no GUI toolchain needed)");
    core_test_step.dependOn(&test_roots.step);
    core_test_step.dependOn(&lint_errdefer.step);
    core_test_step.dependOn(&b.addRunArtifact(coretests).step);

    // Optional CEF browser helper — `zig build fetch-cef` / `zig build
    // web`. Strictly opt-in: nothing below is reachable from the default
    // step, the binary distribution is never downloaded unless the fetch
    // step is asked for by name, and the CEF headers are only translated
    // when that distribution is already on disk.
    addCef(b, target, optimize, strip, use_lld, core_cbindings_mod, mux_exe, smoke_mcp_run, &test_roots.step, &lint_errdefer.step);
}

/// Pinned CEF binary distribution ("minimal" distro). SINGLE source of
/// truth: the download URL, the cache directory, the translated
/// bindings and the linked engine all derive from it. Bumping CEF is
/// this one line plus the per-platform checksums and a `zig build
/// fetch-cef`.
const CEF_VERSION = "151.3.16+gbe1e15d+chromium-151.0.7922.109";

/// SHA-256 of the "minimal" tarball for CEF_VERSION, per CDN platform,
/// checked after download. Each was cross-checked once against the
/// SHA-1 the CDN's index.json publishes for the same file; bump them
/// together with CEF_VERSION.
const CEF_SHA256_LINUX64 = "eaeb313e6039de464855893d287c4d5eb4ec7126978ea83c6164bf4a23dc017a";
const CEF_SHA256_MACOSARM64 = "80e6d586fc683a13002d49b913f7b71d01866b7619bec759e5b302b9d53e6995";

/// The CDN platform slug and the checksum for a build target.
///
/// macOS is arm64-only here deliberately: `macosx64` exists on the CDN
/// but nothing in this project has ever run on an Intel Mac, and a pin
/// nobody verifies is worse than an honest refusal.
fn cefPlatform(target: std.Target) ?struct { slug: []const u8, sha256: []const u8 } {
    if (target.os.tag == .linux and target.cpu.arch == .x86_64)
        return .{ .slug = "linux64", .sha256 = CEF_SHA256_LINUX64 };
    if (target.os.tag == .macos and target.cpu.arch == .aarch64)
        return .{ .slug = "macosarm64", .sha256 = CEF_SHA256_MACOSARM64 };
    return null;
}

/// The REAL uBlock Origin build smoke-web stage 35 measures against.
///
/// A fixture of our own can only prove that our own code paths run;
/// only the shipped extension can prove that uBO's module graph, its
/// Port traffic and its filter engine survive contact with this host.
/// Pinned by version AND checksum, and fetched by `zig build
/// fetch-webext-fixtures` — never by `zig build smoke-web`, which must
/// not touch the network. Stage 35b reports itself SKIPPED when the file
/// is absent instead of failing, exactly as stage 24 reports a host with
/// no GPU.
const UBO_VERSION = "1.73.0";
const UBO_URL = "https://addons.mozilla.org/firefox/downloads/file/4940584/ublock_origin-1.73.0.xpi";
const UBO_SHA256 = "bccc51a773150af4af6e1fd62c7bfdeb7238b79ff2381b998fa9f2e38f64786a";

/// Register the optional CEF acquisition step and the `sketerm-webengine`
/// helper it feeds.
///
/// Two hard rules shape this function. (1) A plain `zig build` must
/// never touch the network nor translate a CEF header, so the only
/// unconditional work here is a directory `access()` — the download
/// lives behind `fetch-cef`, and the TranslateC step + executable are
/// only CONFIGURED when the distribution is already unpacked. (2) When
/// it is absent, `zig build web` must still exist and say what to run,
/// which is what the `addFail` branch is for; every other step is
/// unaffected either way.
fn addCef(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    use_lld: bool,
    core_cbindings_mod: *std.Build.Module,
    mux_exe: *std.Build.Step.Compile,
    smoke_mcp_run: *std.Build.Step.Run,
    test_roots: *std.Build.Step,
    lint_errdefer: *std.Build.Step,
) void {
    // Default cache location, XDG-correct: $XDG_CACHE_HOME/sketerm/cef/
    // <version>/ (~/.cache/... when unset). Version-scoped so several
    // pinned distributions can coexist and a bump never half-overwrites
    // the previous one.
    const default_root = if (b.graph.environ_map.get("XDG_CACHE_HOME")) |xdg|
        b.fmt("{s}/sketerm/cef/{s}", .{ xdg, CEF_VERSION })
    else if (b.graph.environ_map.get("HOME")) |home|
        b.fmt("{s}/.cache/sketerm/cef/{s}", .{ home, CEF_VERSION })
    else
        b.fmt("{s}/.zig-cache/cef/{s}", .{ b.build_root.path orelse ".", CEF_VERSION });
    const cef_root = b.option(
        []const u8,
        "cef-root",
        "unpacked CEF binary distribution to build sketerm-webengine against (default: $XDG_CACHE_HOME/sketerm/cef/<pinned version>)",
    ) orelse default_root;
    // A downloaded distribution keeps headers and libraries in one
    // tree (<root>/include, <root>/Release); a DISTRO-PACKAGED CEF
    // splits them (/usr/include/cef, /usr/lib/cef). Both are supported
    // by overriding the two halves independently — which is how the
    // Arch package builds against `cef` instead of shipping 300MB of
    // its own Chromium.
    const include_root = b.option(
        []const u8,
        "cef-include",
        "directory whose include/capi/*.h are the CEF headers (default: <cef-root>)",
    ) orelse cef_root;
    const release_dir = b.option(
        []const u8,
        "cef-lib",
        "directory holding libcef.so and its .pak/icudtl.dat siblings (default: <cef-root>/Release)",
    ) orelse b.fmt("{s}/Release", .{cef_root});

    // `+` is not URL-safe in a path segment; the CDN serves the encoded
    // form. Everything else in a CEF version string already is.
    var url_version: std.ArrayList(u8) = .empty;
    for (CEF_VERSION) |ch| {
        if (ch == '+') {
            url_version.appendSlice(b.allocator, "%2B") catch @panic("OOM");
        } else {
            url_version.append(b.allocator, ch) catch @panic("OOM");
        }
    }
    // The CDN slug for THIS target. A platform with no pin gets a
    // `web` step that says so rather than a build that half-works.
    const cef_plat = cefPlatform(target.result);
    const is_mac_cef = target.result.os.tag == .macos;
    const url = b.fmt(
        "https://cef-builds.spotifycdn.com/cef_binary_{s}_{s}_minimal.tar.bz2",
        .{ url_version.items, if (cef_plat) |p| p.slug else "linux64" },
    );

    // curl + tar rather than Zig code: the fetch is a developer-invoked
    // one-off, and shelling out keeps resume/retry/decompression out of
    // build.zig. Unpacks to a sibling `.tmp` and renames, so an aborted
    // download can never leave a half-distribution that later looks
    // cached.
    const fetch = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\root="$1"; url="$2"; sum="$3"; kind="$4"
        \\fw="Chromium Embedded Framework"
        \\if [ "$kind" = mac ]; then
        \\  marker="$root/Release/$fw.framework/$fw"
        \\else
        \\  marker="$root/Release/libcef.so"
        \\fi
        \\if [ -e "$marker" ]; then
        \\  echo "cef: already present at $root"
        \\  exit 0
        \\fi
        \\tmp="$root.tmp"
        \\rm -rf "$tmp"
        \\mkdir -p "$tmp"
        \\echo "cef: downloading $url"
        \\curl -fL --retry 3 -o "$tmp/cef.tar.bz2" "$url"
        \\# sha256sum is coreutils; macOS ships `shasum -a 256`. Pick
        \\# whichever exists rather than making coreutils a build dep.
        \\if command -v sha256sum >/dev/null 2>&1; then
        \\  echo "$sum  $tmp/cef.tar.bz2" | sha256sum -c - >/dev/null || bad=1
        \\else
        \\  echo "$sum  $tmp/cef.tar.bz2" | shasum -a 256 -c - >/dev/null || bad=1
        \\fi
        \\if [ "${bad:-0}" = 1 ]; then
        \\  echo "cef: SHA-256 mismatch, refusing to unpack" >&2
        \\  rm -rf "$tmp"; exit 1
        \\fi
        \\tar -xjf "$tmp/cef.tar.bz2" -C "$tmp" --strip-components=1
        \\rm -f "$tmp/cef.tar.bz2"
        \\if [ "$kind" = mac ]; then
        \\  # macOS ships everything INSIDE the framework already —
        \\  # there is no top-level Resources/ to flatten. What it does
        \\  # need is the VERSIONED bundle layout: macOS 26 / Xcode 26
        \\  # reject a flat framework, and CEF's README documents the
        \\  # relative-symlink shape below as the fix.
        \\  d="$tmp/Release/$fw.framework"
        \\  mkdir -p "$d/Versions/A"
        \\  for item in "$fw" Libraries Resources; do
        \\    [ -e "$d/$item" ] || continue
        \\    mv "$d/$item" "$d/Versions/A/$item"
        \\    ln -s "Versions/Current/$item" "$d/$item"
        \\  done
        \\  ln -s A "$d/Versions/Current"
        \\else
        \\  # icudtl.dat, the .pak files and locales/ are looked up NEXT
        \\  # TO libcef.so — CefSettings.resources_dir_path does NOT
        \\  # redirect the icudtl probe. Flattening Resources/* into
        \\  # Release/ is the standard CEF deploy layout and is
        \\  # required, not a shortcut.
        \\  cp -a "$tmp/Resources/." "$tmp/Release/"
        \\fi
        \\rm -rf "$root"
        \\mv "$tmp" "$root"
        \\echo "cef: installed at $root"
        ,
        "sh",
    });
    fetch.addArg(cef_root);
    fetch.addArg(url);
    fetch.addArg(if (cef_plat) |p| p.sha256 else CEF_SHA256_LINUX64);
    fetch.addArg(if (is_mac_cef) "mac" else "elf");
    // Produces no build output the graph can hash; without this the Run
    // step would be cached away and a deleted cache never re-fetched.
    fetch.has_side_effects = true;
    const fetch_step = b.step("fetch-cef", b.fmt("Download the pinned CEF binary distribution ({s}) into the build cache", .{CEF_VERSION}));
    fetch_step.dependOn(&fetch.step);

    // The real-extension fixture for smoke-web stage 35. Same shape as
    // fetch-cef and for the same reasons: developer-invoked, checksum
    // pinned, never reached by a plain build or by the smoke run itself.
    const ubo_dir = if (b.graph.environ_map.get("XDG_CACHE_HOME")) |xdg|
        b.fmt("{s}/sketerm/webext-fixtures", .{xdg})
    else if (b.graph.environ_map.get("HOME")) |home|
        b.fmt("{s}/.cache/sketerm/webext-fixtures", .{home})
    else
        b.fmt("{s}/.zig-cache/webext-fixtures", .{b.build_root.path orelse "."});
    const ubo_xpi = b.fmt("{s}/ublock_origin-{s}.xpi", .{ ubo_dir, UBO_VERSION });
    const fetch_ext = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\out="$1"; url="$2"; sum="$3"
        \\if [ -e "$out" ]; then
        \\  echo "webext-fixtures: already present at $out"
        \\  exit 0
        \\fi
        \\mkdir -p "$(dirname "$out")"
        \\echo "webext-fixtures: downloading $url"
        \\curl -fL --retry 3 -o "$out.tmp" "$url"
        \\echo "$sum  $out.tmp" | sha256sum -c - >/dev/null || {
        \\  echo "webext-fixtures: SHA-256 mismatch, refusing to keep it" >&2
        \\  rm -f "$out.tmp"; exit 1
        \\}
        \\mv "$out.tmp" "$out"
        \\echo "webext-fixtures: installed $out"
        ,
        "sh",
    });
    fetch_ext.addArg(ubo_xpi);
    fetch_ext.addArg(UBO_URL);
    fetch_ext.addArg(UBO_SHA256);
    fetch_ext.has_side_effects = true;
    const fetch_ext_step = b.step(
        "fetch-webext-fixtures",
        b.fmt("Download the real uBlock Origin {s} XPI smoke-web stage 35 measures against", .{UBO_VERSION}),
    );
    fetch_ext_step.dependOn(&fetch_ext.step);

    const web_step = b.step("web", "Build sketerm-webengine, the CEF browser helper (needs `zig build fetch-cef`)");
    const test_web_step = b.step("test-web", "Run CEF-gated browser-helper unit tests");
    test_web_step.dependOn(test_roots);
    test_web_step.dependOn(lint_errdefer);
    const smoke_web_step = b.step("smoke-web", "browser-helper end-to-end smoke (headless)");
    const bench_wreq_step = b.step("bench-webreq", "Blocking-webRequest added-latency benchmark (real helper, real page)");

    // The engine binary this platform actually ships: an ELF shared
    // object on Linux, an unversioned framework bundle on macOS.
    const cef_binary_rel = if (is_mac_cef)
        "Chromium Embedded Framework.framework/Chromium Embedded Framework"
    else
        "libcef.so";

    // Probe the two halves separately: a split system install has no
    // Release dir at all, and a header-only hit would fail at link.
    const have_cef = blk: {
        if (cef_plat == null) break :blk false;
        std.Io.Dir.accessAbsolute(b.graph.io, b.fmt("{s}/{s}", .{ release_dir, cef_binary_rel }), .{}) catch break :blk false;
        std.Io.Dir.accessAbsolute(b.graph.io, b.fmt("{s}/include/capi/cef_app_capi.h", .{include_root}), .{}) catch break :blk false;
        break :blk true;
    };
    if (!have_cef) {
        const missing = if (cef_plat == null) b.addFail(b.fmt(
            "no pinned CEF distribution for {s}-{s} — the browser helper is Linux x86_64 and macOS arm64 only",
            .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) },
        )) else b.addFail(b.fmt(
            "no usable CEF at {s} ({s}) + {s} (headers) — run `zig build fetch-cef`, " ++
                "or point -Dcef-include=/-Dcef-lib= at a system install (e.g. /usr/include/cef and /usr/lib/cef)",
            .{ release_dir, cef_binary_rel, include_root },
        ));
        web_step.dependOn(&missing.step);
        test_web_step.dependOn(&missing.step);
        smoke_web_step.dependOn(&missing.step);
        bench_wreq_step.dependOn(&missing.step);
        return;
    }

    // The spike proved this header set translates clean, so unlike the
    // GTK/core roots there is no sed fixup pass here. `-I` is the
    // distribution root because CEF's headers include each other as
    // "include/capi/...".
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("vendor/cef_root.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // macOS SDKs before Xcode 14.3 ship no <uchar.h>, and CEF's
    // cef_string_types.h only guards that include behind `#ifdef
    // __clang__` — which Aro does not define, so it takes the
    // unconditional branch and fails on a Command Line Tools SDK.
    // Shim FIRST so it shadows nothing on a host that has the real one.
    if (is_mac_cef) tc.addIncludePath(b.path("vendor/aro_shims/cef"));
    tc.addIncludePath(.{ .cwd_relative = include_root });
    const cef_mod = tc.createModule();

    // Rooted at src/ (see src/webengine.zig): the helper's own code is
    // all under src/web/, but a module cannot import above its root
    // directory and the helper legitimately shares libc-only helpers
    // with the daemon and the GUI.
    const web_mod = b.createModule(.{
        .root_source_file = b.path("src/webengine.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    web_mod.addImport("cef", cef_mod);
    // libc decls only (sockets, poll, mmap): the helper is GTK-free by
    // the same rule the daemon follows, and the fribidi/stb declarations
    // this module also carries are never referenced, so nothing extra
    // links.
    web_mod.addImport("cbindings", core_cbindings_mod);
    // Raw-deflate codec for inline frames (frames-inline): the same
    // pure-std module pool updates on the native app pipe use. A named
    // module because src/wlhost/ sits outside the helper's module root.
    web_mod.addImport("zpool", b.createModule(.{
        .root_source_file = b.path("src/wlhost/zpool.zig"),
        .target = target,
        .optimize = optimize,
    }));
    // `cef_release_dir` is what the LD_PRELOAD re-exec points at — the
    // helper must preload the SAME libcef.so it linked against, so the
    // path belongs to the build, not to a runtime search.
    // Where libcef.so will LIVE when the helper runs, which is not
    // where it lives when the helper links: a package builds against
    // the cached distribution and ships the runtime under /usr/lib.
    // Both the rpath and the LD_PRELOAD path follow this one.
    const runtime_dir = b.option(
        []const u8,
        "cef-runtime-dir",
        "directory holding libcef.so at RUN time (packaging; default: the build-time Release dir)",
    ) orelse release_dir;
    const web_opts = b.addOptions();
    web_opts.addOption([]const u8, "version", semver);
    web_opts.addOption([]const u8, "cef_release_dir", runtime_dir);
    web_mod.addImport("build_options", web_opts.createModule());
    if (is_mac_cef) {
        // macOS links the framework DIRECTLY, and the framework's own
        // install name is what makes that work:
        //
        //   @executable_path/../Frameworks/Chromium Embedded Framework
        //       .framework/Chromium Embedded Framework
        //
        // That path is relative to the executable, and it is EXACTLY
        // the layout a macOS bundle already has (`Contents/MacOS/exe`
        // beside `Contents/Frameworks/`). So one binary works both
        // from a bundle and from `zig-out/bin/` with the framework
        // staged at `zig-out/Frameworks/` — see the install step below.
        //
        // CEF's README advises loading the framework dynamically
        // instead (`cef_load_library`, via `libcef_dll_dylib.cc`). That
        // route was tried first and abandoned for a toolchain reason,
        // recorded here so nobody re-treads it: the wrapper is C++, its
        // capi includes pull in <cstring>, and Zig 0.16 cannot supply
        // C++ headers here — its BUNDLED libc++ fails to compile
        // against a current macOS SDK (`INFINITY` undeclared in
        // __random/clamp_to_integral.h), while the SDK's own libc++
        // headers refuse to be used out of Zig's include order
        // ("<cstring> tried including <string.h> but didn't find
        // libc++'s"). Direct linking needs no C++ translation unit at
        // all. The cost is that the helper is not relocatable away from
        // its framework — which it never was on Linux either (it needs
        // the .pak/icudtl.dat siblings there).
        web_mod.addFrameworkPath(.{ .cwd_relative = release_dir });
        web_mod.linkFramework("Chromium Embedded Framework", .{});
        // CEF's macOS message pump runs on Cocoa's run loop, so the
        // helper needs an NSApplication (implementing CefAppProtocol)
        // before cef_initialize — without one it starts, spawns its
        // children, and then never finishes a navigation. See the file.
        web_mod.addCSourceFile(.{
            .file = b.path("src/web/mac_app.m"),
            .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        web_mod.linkFramework("Cocoa", .{});
    } else {
        web_mod.addLibraryPath(.{ .cwd_relative = release_dir });
        web_mod.linkSystemLibrary("cef", .{});
        // libcef.so is not on the loader's search path; the helper is
        // not relocatable anyway (it needs the .pak/icudtl.dat next to
        // the lib).
        web_mod.addRPath(.{ .cwd_relative = runtime_dir });
    }
    // KNOWN CONSTRAINT, harmless for this stub: Zig emits libc BEFORE
    // libcef in DT_NEEDED no matter the CLI order, and libcef's zygote
    // resolves dlsym(RTLD_NEXT, "close") — which then misses and aborts
    // with SIGTRAP "close symbol missing". It only bites once a browser
    // process is actually spawned, so the stub (which merely reads the
    // API hash) runs fine. The helper will re-exec itself with
    // LD_PRELOAD=<Release>/libcef.so to fix the resolution order;
    // implementation comes with the helper.
    const web_exe = b.addExecutable(.{
        // "sketerm-webengine", not "sketerm-web": the latter is the
        // GUI's identity hardlink (Plasma groups taskbar entries by
        // process, so `sketerm web` needs a distinct argv0 like
        // `sketerm-files` has). The engine helper is internal.
        .name = "sketerm-webengine",
        .root_module = web_mod,
        .use_lld = use_lld,
    });
    const web_tests = b.addTest(.{
        .root_module = web_mod,
        .use_lld = use_lld,
    });
    test_web_step.dependOn(&b.addRunArtifact(web_tests).step);
    // Installed by the `web` step only — never by `b.installArtifact`,
    // which would drag CEF into the default build.
    web_step.dependOn(&b.addInstallArtifact(web_exe, .{}).step);

    // macOS: the bare executable in `zig-out/bin/` CANNOT RUN. Chromium
    // resolves icudtl.dat and its .pak files through the framework
    // BUNDLE, which it only finds from a bundled main executable
    // ("icudtl.dat not found in bundle", then cef_initialize fails),
    // and it launches renderer/GPU/network children from a separate
    // helper .app rather than by re-executing us. So the real artifact
    // on this platform is `zig-out/sketerm-webengine.app`, assembled
    // here; every piece of it answers a failure documented in the
    // script. The loose binary is left in place as the thing the
    // bundle is built FROM, not as something to run.
    const mac_bundle = b.addSystemCommand(&.{"dist/macos-bundle.sh"});
    if (is_mac_cef) {
        mac_bundle.addArg(b.getInstallPath(.prefix, ""));
        mac_bundle.addArtifactArg(web_exe);
        mac_bundle.addArg(release_dir);
        mac_bundle.has_side_effects = true;
        web_step.dependOn(&mac_bundle.step);
    }

    // Browser-helper smoke — `zig build smoke-web` (headless). Spawns
    // the helper on a private short socket and drives the v1 protocol
    // as a client: handshake, memfd paint, trusted click, typing,
    // resize, popup request, history, clean shutdown. CEF-gated like
    // everything else here, and never reachable from the default step.
    const smoke_web_mod = b.createModule(.{
        .root_source_file = b.path("src/smoke_web.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_web_mod.addImport("cbindings", core_cbindings_mod);
    const smoke_web = b.addExecutable(.{
        .name = "sketerm-smoke-web",
        .root_module = smoke_web_mod,
        .use_lld = use_lld,
    });
    const smoke_web_run = b.addRunArtifact(smoke_web);
    if (is_mac_cef) {
        // The loose executable cannot run on macOS (no bundle, so no
        // icudtl.dat and no helper for children) — the rig has to drive
        // the assembled .app, and therefore has to wait for it.
        smoke_web_run.addArg(b.getInstallPath(.prefix, "sketerm-webengine.app/Contents/MacOS/sketerm-webengine"));
        smoke_web_run.step.dependOn(&mac_bundle.step);
    } else smoke_web_run.addArtifactArg(web_exe);
    // The remote-helper stage spawns a private sketerm-mux and asks IT
    // to launch the helper over a bridged byte channel.
    smoke_web_run.addArtifactArg(mux_exe);
    // Stage 35b's real-extension fixture. Passed as a PATH, not a
    // dependency: the file may legitimately be absent (the stage then
    // reports itself skipped), and making the smoke step depend on the
    // fetch would put a download in everybody's test run.
    smoke_web_run.addArg(ubo_xpi);
    smoke_web_step.dependOn(&smoke_web_run.step);

    // smoke-mcp's real-engine stage runs the helper this build produced,
    // never whatever `zig-out/bin/sketerm-webengine` happens to hold: a
    // stale artifact there (a mid-refactor `zig build web`, an older
    // checkout) reads as a live protocol failure — every semantic op
    // timing out while load and title events still arrive — and the
    // smoke blames the client. Without CEF this function returns early
    // and the stage stays a clean SKIP.
    smoke_mcp_run.addArg("--web-bin");
    if (is_mac_cef) {
        smoke_mcp_run.addArg(b.getInstallPath(.prefix, "sketerm-webengine.app/Contents/MacOS/sketerm-webengine"));
        smoke_mcp_run.step.dependOn(&mac_bundle.step);
    } else smoke_mcp_run.addArtifactArg(web_exe);

    // Blocking-webRequest latency benchmark — `zig build bench-webreq`.
    // Same shape as the smoke rig (a real helper on a private short
    // socket) because the number that matters is an END-TO-END one: a
    // microbenchmark of the registry would measure the wrong half.
    const bench_wreq_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_webreq.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_wreq_mod.addImport("cbindings", core_cbindings_mod);
    const bench_wreq = b.addExecutable(.{
        .name = "sketerm-bench-webreq",
        .root_module = bench_wreq_mod,
        .use_lld = use_lld,
    });
    const bench_wreq_run = b.addRunArtifact(bench_wreq);
    bench_wreq_run.addArtifactArg(web_exe);
    bench_wreq_step.dependOn(&bench_wreq_run.step);
}

/// The one GUI system-package roster lives in
/// `vendor/pkgconfig/sketerm-gui.pc` as a virtual package whose
/// `Requires:` lists gtk4, libadwaita-1, freetype2, harfbuzz, epoxy,
/// fribidi and fontconfig. TranslateC header resolution and module link
/// flags both ask for THIS name, so they cannot drift apart.
///
/// It is one package rather than seven because Zig resolves pkg-config
/// per package and dedupes only by package NAME: gtk4 and libadwaita-1
/// both expand to `-lgtk-4 -lharfbuzz -lglib-2.0 …`, so seven packages
/// hand the linker the same library up to three times. Zig's self-hosted
/// Mach-O linker (the only one that links Mach-O now — LLD's port is
/// unsupported) emits one LC_LOAD_DYLIB per `-l`, and current dyld
/// ABORTS a binary that names the same dylib twice. pkg-config dedupes a
/// `Requires:` closure itself, so asking it once fixes this at the
/// source. ELF hid the bug: GNU ld coalesces DT_NEEDED.
const gui_pkg = "sketerm-gui";

/// Make `vendor/pkgconfig/` visible to the pkg-config invocations Zig
/// runs for `gui_pkg`, without disturbing a PKG_CONFIG_PATH the caller
/// set. Only the search path is touched here — no package is resolved,
/// so a GTK-less host can still build the daemon (`dist/test-mux-build.sh`).
fn registerGuiPkgConfigPath(b: *std.Build) void {
    const dir = b.pathFromRoot("vendor/pkgconfig");
    const merged = if (b.graph.environ_map.get("PKG_CONFIG_PATH")) |prev|
        b.fmt("{s}:{s}", .{ dir, prev })
    else
        dir;
    b.graph.environ_map.put("PKG_CONFIG_PATH", merged) catch @panic("OOM");
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
    tc.linkSystemLibrary(gui_pkg, .{ .use_pkg_config = .force });
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

/// Vendored Tree-sitter runtime + the generated grammars behind the
/// editor's syntax highlighting (src/editor/syntax.zig). See
/// vendor/tree-sitter/PROVENANCE.txt for commits and licenses.
///
/// GUI-side artifacts ONLY. `configureCoreDeps` deliberately does not
/// call this: `sketerm-mux` must keep its libc-only link graph, and
/// `mux-portable` must keep building against static musl. The one
/// non-GUI exception is `test-core`, which exercises syntax.zig.
///
/// Everything here is generated or hand-written C — no node/JS
/// toolchain runs at build time. `lib/src/lib.c` is upstream's
/// amalgamation (it `#include`s every other runtime .c), so exactly one
/// translation unit compiles the runtime. Each grammar gets ITS OWN
/// include path because its `tree_sitter/parser.h` pins the language
/// ABI its table was generated against.
const TS_GRAMMARS = [_]struct { dir: []const u8, scanner: bool }{
    .{ .dir = "zig", .scanner = false },
    .{ .dir = "c", .scanner = false },
    .{ .dir = "json", .scanner = false },
    .{ .dir = "markdown", .scanner = true },
    .{ .dir = "markdown_inline", .scanner = true },
};

const TS_CFLAGS = [_][]const u8{
    // gnu11, not c11: the runtime calls fdopen() and the byte-order
    // macros (be16toh), which strict ISO mode hides behind feature-test
    // macros. This is upstream's own dialect.
    "-std=gnu11",
    "-O2",
    "-Wno-unused-but-set-variable",
    "-Wno-unused-parameter",
    "-Wno-unused-function",
};

/// The runtime + one static lib per grammar. Each is a SEPARATE
/// compilation because `tree_sitter/parser.h` is a different file for
/// each of them: the runtime has its own internal `lib/src/parser.h`,
/// and a grammar's copy pins the language ABI its tables were generated
/// against (json is v14, the rest v15). Merging the include paths into
/// one module would let whichever `-I` came first silently shadow the
/// others.
const TreeSitter = struct {
    libs: [1 + TS_GRAMMARS.len]*std.Build.Step.Compile,
};

fn buildTreeSitter(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_lld: bool,
) TreeSitter {
    var out: TreeSitter = undefined;

    const rt_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rt_mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    rt_mod.addIncludePath(b.path("vendor/tree-sitter/lib/src"));
    // Upstream's amalgamation: lib.c `#include`s every other runtime
    // .c, so the whole runtime is one translation unit.
    rt_mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/lib/src/lib.c"),
        .flags = &TS_CFLAGS,
    });
    out.libs[0] = b.addLibrary(.{
        .name = "tree-sitter",
        .root_module = rt_mod,
        .linkage = .static,
        .use_lld = use_lld,
    });

    for (TS_GRAMMARS, 0..) |g, i| {
        const dir = b.fmt("vendor/tree-sitter/grammars/{s}", .{g.dir});
        const g_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        g_mod.addIncludePath(b.path(dir));
        g_mod.addCSourceFile(.{
            .file = b.path(b.fmt("{s}/parser.c", .{dir})),
            .flags = &TS_CFLAGS,
        });
        if (g.scanner) {
            g_mod.addCSourceFile(.{
                .file = b.path(b.fmt("{s}/scanner.c", .{dir})),
                .flags = &TS_CFLAGS,
            });
        }
        out.libs[1 + i] = b.addLibrary(.{
            .name = b.fmt("tree-sitter-{s}", .{g.dir}),
            .root_module = g_mod,
            .linkage = .static,
            .use_lld = use_lld,
        });
    }
    return out;
}

fn addTreeSitter(b: *std.Build, mod: *std.Build.Module, ts: TreeSitter) void {
    mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    for (ts.libs) |lib| mod.linkLibrary(lib);
    // The highlight queries ride along as embedded assets — vendor/ is
    // outside the source module root, so @embedFile needs an anonymous
    // import (same trick as the CRT shaders in smoke-cell).
    for (TS_GRAMMARS) |g| {
        mod.addAnonymousImport(b.fmt("ts_query_{s}", .{g.dir}), .{
            .root_source_file = b.path(b.fmt("vendor/tree-sitter/queries/{s}.scm", .{g.dir})),
        });
    }
}

/// libx264 + the C shim (vendor/x264_shim.c) for the lossy video path.
/// Dynamically links the SYSTEM x264 (declared a package dep) rather
/// than vendoring it — x264's speed lives in per-arch asm, so a vendored
/// C-only build would be too slow, and the optional video path can be
/// absent on the portable binary (→ lossless). Gated on build_options.video.
fn addVideo(b: *std.Build, mod: *std.Build.Module) void {
    // Encode: libx264 + shim. Decode: libavcodec/avutil + shim. Both
    // link into any artifact under -Dvideo; the encoder is referenced
    // only daemon-side and the decoder only GUI-side, so the "other"
    // library is dead weight there — fine on native builds (it's the
    // portable musl daemon that stays codec-free).
    addPkgConfig(b, mod, "x264");
    addPkgConfig(b, mod, "libavcodec");
    addPkgConfig(b, mod, "libavutil");
    mod.addCSourceFile(.{ .file = b.path("vendor/x264_shim.c"), .flags = &.{"-O2"} });
    mod.addCSourceFile(.{ .file = b.path("vendor/avdec_shim.c"), .flags = &.{"-O2"} });
    mod.addCSourceFile(.{ .file = b.path("vendor/avenc_shim.c"), .flags = &.{"-O2"} });
    mod.addIncludePath(b.path("vendor"));
}

/// VideoToolbox H.264 encoder shim (vendor/vtenc_shim.c) + the system
/// frameworks it needs — the Mac-native video-tile encode path. No
/// external codec lib: the daemon produces H.264 a `-Dvideo` (libavcodec)
/// client decodes. Gated on `vtenc` (native macOS toolchain).
fn addVtEnc(b: *std.Build, mod: *std.Build.Module) void {
    mod.addCSourceFile(.{ .file = b.path("vendor/vtenc_shim.c"), .flags = &.{"-O2"} });
    mod.linkFramework("VideoToolbox", .{});
    mod.linkFramework("CoreMedia", .{});
    mod.linkFramework("CoreVideo", .{});
    mod.linkFramework("CoreFoundation", .{});
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
    mod.addImport("cbindings", cbindings_mod);
    mod.addIncludePath(b.path("vendor/aro_shims"));
    addPkgConfig(b, mod, gui_pkg);
    // Per-window WM_CLASS for remote app windows (wlapp.zig calls
    // XChangeProperty directly — GTK links X11 but doesn't re-export
    // it). Linux-only; the macOS GUI has no X11.
    if (mod.resolved_target.?.result.os.tag == .linux) {
        mod.linkSystemLibrary("X11", .{ .use_pkg_config = .yes });
        // Remote-audio playback (audio_sink.zig): async libpulse on
        // the GLib main loop. GUI-only — the daemon's PA *server*
        // (mux/pulse.zig) is hand-rolled and links nothing.
        addPkgConfig(b, mod, "libpulse");
        addPkgConfig(b, mod, "libpulse-mainloop-glib");
    }
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
        .flags = &.{ "-O2", "-Wno-unused-function", "-Wno-unused-but-set-variable" },
    });
    // VP9/WebM app-window recording (videorec.zig) — GUI-side only; the
    // daemon (configureCoreDeps) links no libvpx and stays libc-clean.
    addPkgConfig(b, mod, "vpx");
    mod.addCSourceFile(.{ .file = b.path("vendor/vpxenc_shim.c"), .flags = &.{"-O2"} });
    addZstd(b, mod);
    mod.addIncludePath(b.path("vendor"));
}

/// Resolve a pkg-config package only when a reachable compile step needs it.
fn addPkgConfig(b: *std.Build, mod: *std.Build.Module, pkg: []const u8) void {
    _ = b;
    mod.linkSystemLibrary(pkg, .{ .use_pkg_config = .force });
}

/// Capture a command's trimmed stdout, or null when the command is
/// unavailable or fails (tarball builds without git).
fn runCapture(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(argv, &code, .ignore) catch return null;
    const trimmed = std.mem.trim(u8, out, " \r\n\t");
    if (trimmed.len == 0) return null;
    return trimmed;
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
