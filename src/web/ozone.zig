//! Pure ozone-platform and WebGL decision for `sketerm-webengine` —
//! extracted from main.zig's buildCefArgv so the choice is testable
//! without CEF.
//!
//! `SKETERM_WEB_OZONE=wayland` is how webdrive forces the helper onto a
//! mux session's Wayland display even on a GPU-less host: the render
//! node veto is skipped. An unreachable compositor still falls back to
//! headless — wayland ozone is not optional-with-fallback inside
//! Chromium, and a wrong pick costs the whole process.
//!
//! `SKETERM_WEB_FRAMES=cpu` is a launcher that READS the pixels (MCP
//! screenshots, streams, the presenter): frames must stay on the CPU
//! `on_paint` path, which says nothing about where WebGL renders. Such a
//! helper uses the host GPU when a render node exists, exactly as the
//! GUI's helper and a real Chrome on the same machine do; the rest is
//! its `WebglPolicy` (`SKETERM_WEB_WEBGL`, config `web_webgl`).
//!
//! The default chain (wayland when GPU, compositor and render node are
//! all there) is unchanged for every launcher that does not say `cpu`.

const std = @import("std");

/// How the device scale reaches the engine.
pub const ScaleLever = enum {
    /// LOGICAL view rect and the real `get_screen_info` DPR. Headless
    /// ozone honours it, per browser, from a document's first layout.
    screen_info,
    /// PHYSICAL view rect and the scale carried as zoom: Wayland ozone
    /// ignores screen-info DPR (a CPU view painted at logical size and
    /// stayed black). Chromium keys zoom by HOST per profile, so a new
    /// host's first document lays out at zoom 0 and views of one host
    /// share one level (measured 2026-10-10); never used where
    /// `screen_info` works.
    zoom,

    fn of(platform: []const u8) ScaleLever {
        return if (std.mem.eql(u8, platform, "headless")) .screen_info else .zoom;
    }
};

pub const Choice = struct {
    platform: []const u8,
    /// Append `--disable-gpu`: no GPU process at all.
    disable_gpu: bool = false,
    /// Append `--disable-webgl --disable-webgl2`: no context of either.
    disable_webgl: bool = false,
    /// What cefhost.setAccelerated is handed: dma-buf frames.
    accelerated: bool = false,
    /// What cefhost.setScaleLever is handed; follows `platform`.
    scale_lever: ScaleLever = .zoom,
    /// What WebGL renders on; null leaves the engine's own default
    /// untouched (the GUI's and the untrusted helper's launches).
    webgl: ?Webgl = null,
};

/// Where a page's WebGL contexts render: the EFFECTIVE mode, advertised
/// as `webgl-gpu` / `software-webgl` / `webgl-off` and reported by MCP's
/// `web_webgl` fact under these very names.
pub const Webgl = enum {
    /// The host GPU through the GPU process (a render node exists).
    hardware,
    /// ANGLE on SwiftShader: a CPU rasteriser whose renderer string
    /// names it. A real headful Chrome on a GPU-less machine offers no
    /// WebGL at all (measured 2026-10-12); headless Chrome offers this.
    software,
    /// No WebGL or WebGL2 context at all.
    off,
};

/// What a CPU-frame helper is asked to do about WebGL: the ONE home of
/// the `web_webgl` config values and `SKETERM_WEB_WEBGL`.
pub const WebglPolicy = enum {
    /// The host GPU when a render node exists, else SwiftShader so WebGL
    /// pages keep working (Jelle's default, 2026-10-12).
    auto,
    /// The host GPU when a render node exists, else no WebGL at all: what
    /// a real Chrome on a GPU-less machine does.
    hardware,
    /// Never WebGL, GPU or not.
    off,

    pub const ENV = "SKETERM_WEB_WEBGL";

    /// A config/env spelling; null for anything else.
    pub fn parse(s: []const u8) ?WebglPolicy {
        return std.meta.stringToEnum(WebglPolicy, s);
    }
};

pub const Inputs = struct {
    /// An `--ozone-platform=` value already on argv (wins, passed
    /// through untouched — the smoke rig pins modes this way).
    explicit: ?[]const u8 = null,
    /// `$SKETERM_WEB_OZONE`, or null.
    env_override: ?[]const u8 = null,
    /// `$SKETERM_WEB_GPU` != off.
    gpu_wanted: bool = true,
    /// `$SKETERM_WEB_FRAMES=cpu`: the launcher reads pixels on the CPU.
    cpu_frames: bool = false,
    /// `$SKETERM_WEB_WEBGL`; read for CPU-frame helpers only.
    webgl_policy: WebglPolicy = .auto,
    /// A real connect() succeeded.
    wayland_reachable: bool = false,
    /// A /dev/dri/renderD* opened.
    render_node: bool = false,
};

pub fn choose(in: Inputs) Choice {
    var out = pick(in.explicit, in.env_override, in.gpu_wanted, in.wayland_reachable, in.render_node);
    out.scale_lever = ScaleLever.of(out.platform);
    if (in.cpu_frames) {
        out.accelerated = false;
        const gpu = in.gpu_wanted and in.render_node;
        const webgl: Webgl = switch (in.webgl_policy) {
            .off => .off,
            .hardware => if (gpu) .hardware else .off,
            .auto => if (gpu) .hardware else if (in.gpu_wanted) .software else .off,
        };
        out.webgl = webgl;
        // SwiftShader needs its GPU process; nothing else does without
        // a device to run on.
        out.disable_gpu = !gpu and webgl != .software;
        out.disable_webgl = webgl == .off;
    }
    return out;
}

/// Whether any DRM render node can be opened: the host has a GPU this
/// process may use. Without one the GPU process starts and dies, which
/// costs a second of startup and lands in software anyway. The one probe
/// the helper and the smoke rigs share.
pub fn renderNodePresent() bool {
    if (comptime @import("builtin").os.tag != .linux) return false;
    var i: u16 = 0;
    while (i < 8) : (i += 1) {
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrintZ(&path, "/dev/dri/renderD{d}", .{128 + i}) catch return false;
        const fd = std.c.open(p.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (fd >= 0) {
            _ = std.c.close(fd);
            return true;
        }
    }
    return false;
}

fn pick(
    explicit: ?[]const u8,
    env_override: ?[]const u8,
    gpu_wanted: bool,
    wayland_reachable: bool,
    render_node: bool,
) Choice {
    if (explicit) |p| return .{ .platform = p, .accelerated = std.mem.eql(u8, p, "wayland") };
    if (env_override) |o| {
        if (std.mem.eql(u8, o, "wayland") and wayland_reachable)
            return .{ .platform = "wayland", .disable_gpu = !gpu_wanted, .accelerated = gpu_wanted };
        if (std.mem.eql(u8, o, "headless"))
            return .{ .platform = "headless" };
        // Unknown value, or a forced compositor that is gone: probe.
    }
    if (gpu_wanted and wayland_reachable and render_node)
        return .{ .platform = "wayland", .accelerated = true };
    return .{ .platform = "headless" };
}

fn args(explicit: ?[]const u8, env_override: ?[]const u8, gpu_wanted: bool, wayland_reachable: bool, render_node: bool) Inputs {
    return .{ .explicit = explicit, .env_override = env_override, .gpu_wanted = gpu_wanted, .wayland_reachable = wayland_reachable, .render_node = render_node };
}

test "explicit --ozone-platform wins untouched" {
    const t = std.testing;
    const x11 = choose(args("x11", "wayland", true, true, true));
    try t.expectEqualStrings("x11", x11.platform);
    try t.expect(!x11.accelerated and !x11.disable_gpu);
    const wl = choose(args("wayland", null, false, false, false));
    try t.expect(wl.accelerated);
}

test "forced session mode reaches wayland without a render node, GPU-less" {
    const t = std.testing;
    const soft = choose(args(null, "wayland", false, true, false));
    try t.expectEqualStrings("wayland", soft.platform);
    try t.expect(soft.disable_gpu and !soft.accelerated);
    const gpu = choose(args(null, "wayland", true, true, false));
    try t.expect(gpu.accelerated and !gpu.disable_gpu);
}

test "a forced compositor that is unreachable falls back to the probe chain" {
    const t = std.testing;
    const gone = choose(args(null, "wayland", true, false, false));
    try t.expectEqualStrings("headless", gone.platform);
    const forced_off = choose(args(null, "headless", true, true, true));
    try t.expectEqualStrings("headless", forced_off.platform);
}

test "the default probe chain is unchanged" {
    const t = std.testing;
    const full = choose(args(null, null, true, true, true));
    try t.expectEqualStrings("wayland", full.platform);
    try t.expect(full.accelerated and !full.disable_gpu and full.webgl == null);
    try t.expectEqualStrings("headless", choose(args(null, null, true, true, false)).platform);
    try t.expectEqualStrings("headless", choose(args(null, null, false, true, true)).platform);
    try t.expectEqualStrings("headless", choose(args(null, null, true, false, true)).platform);
}

test "the scale lever follows the platform" {
    const t = std.testing;
    try t.expectEqual(ScaleLever.screen_info, choose(args(null, null, false, false, false)).scale_lever);
    try t.expectEqual(ScaleLever.screen_info, choose(args("headless", null, true, true, true)).scale_lever);
    try t.expectEqual(ScaleLever.zoom, choose(args(null, "wayland", false, true, false)).scale_lever);
    try t.expectEqual(ScaleLever.zoom, choose(args(null, null, true, true, true)).scale_lever);
    try t.expectEqual(ScaleLever.zoom, choose(args("x11", null, false, false, false)).scale_lever);
}

test "a CPU-frame helper keeps CPU paints whatever its WebGL policy" {
    const t = std.testing;
    for ([_][]const u8{ "headless", "wayland" }) |platform| {
        for ([_]bool{ false, true }) |node| {
            var in = args(null, platform, true, true, node);
            in.cpu_frames = true;
            const c = choose(in);
            try t.expectEqualStrings(platform, c.platform);
            try t.expect(!c.accelerated);
        }
    }
}

test "WebGL policy x render node decides the switches" {
    const t = std.testing;
    const Want = struct { policy: WebglPolicy, node: bool, webgl: Webgl, disable_gpu: bool, disable_webgl: bool };
    const table = [_]Want{
        .{ .policy = .auto, .node = true, .webgl = .hardware, .disable_gpu = false, .disable_webgl = false },
        .{ .policy = .auto, .node = false, .webgl = .software, .disable_gpu = false, .disable_webgl = false },
        .{ .policy = .hardware, .node = true, .webgl = .hardware, .disable_gpu = false, .disable_webgl = false },
        .{ .policy = .hardware, .node = false, .webgl = .off, .disable_gpu = true, .disable_webgl = true },
        .{ .policy = .off, .node = true, .webgl = .off, .disable_gpu = false, .disable_webgl = true },
        .{ .policy = .off, .node = false, .webgl = .off, .disable_gpu = true, .disable_webgl = true },
    };
    for (table) |w| {
        var in = args(null, "headless", true, false, w.node);
        in.cpu_frames = true;
        in.webgl_policy = w.policy;
        const c = choose(in);
        try t.expectEqual(w.webgl, c.webgl.?);
        try t.expectEqual(w.disable_gpu, c.disable_gpu);
        try t.expectEqual(w.disable_webgl, c.disable_webgl);
    }
    // The GUI's launch (no FRAMES) is not touched by any policy.
    var gui = args(null, null, true, true, true);
    gui.webgl_policy = .off;
    try t.expect(choose(gui).webgl == null and !choose(gui).disable_webgl);
    try t.expectEqual(WebglPolicy.hardware, WebglPolicy.parse("hardware").?);
    try t.expect(WebglPolicy.parse("software") == null);
}

test "SKETERM_WEB_GPU=0 still vetoes the GPU for a CPU-frame helper" {
    const t = std.testing;
    var in = args(null, "headless", false, false, true);
    in.cpu_frames = true;
    const c = choose(in);
    try t.expectEqual(Webgl.off, c.webgl.?);
    try t.expect(c.disable_gpu and !c.accelerated);
}
