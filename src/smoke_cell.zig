//! Headless cell-render smoke — validates the full cell pipeline:
//! Atlas (multi-page array texture) + CellPass (instanced) + GridPass
//! (overlay) on an EGL surfaceless context. Drives a small Screen
//! through some text + style changes, renders, reads pixels back,
//! asserts something visible was drawn.
//!
//! Run: `zig build smoke-cell`. Exits 0 on PASS.

const std = @import("std");
const c = @import("c.zig").c;
const Atlas = @import("render/atlas.zig").Atlas;
const CellPass = @import("render/cell_pass.zig").CellPass;
const GridPass = @import("render/grid_pass.zig").GridPass;
const Screen = @import("grid/screen.zig").Screen;
const StylePool = @import("grid/style_pool.zig").Pool;

const c_egl = @cImport({
    @cInclude("epoxy/egl.h");
});

const FONT_CANDIDATES = [_][*:0]const u8{
    "/usr/share/fonts/TTF/Hack-Regular.ttf",
    "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/TTF/VeraMono.ttf",
    "/usr/share/fonts/gnu-free/FreeMono.otf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
};

const W: c_int = 320;
const H: c_int = 96;
const FONT_SIZE: u16 = 14;

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // EGL surfaceless context.
    const display = blk: {
        const eglGetPlatformDisplayEXT_addr = c_egl.eglGetProcAddress("eglGetPlatformDisplayEXT");
        if (eglGetPlatformDisplayEXT_addr) |p| {
            const fn_ptr: *const fn (c_uint, ?*anyopaque, ?[*]const c_egl.EGLint) callconv(.c) c_egl.EGLDisplay = @ptrCast(@alignCast(p));
            const PLATFORM_SURFACELESS_MESA: c_uint = 0x31DD;
            const d = fn_ptr(PLATFORM_SURFACELESS_MESA, null, null);
            if (d != null and d != c_egl.EGL_NO_DISPLAY) break :blk d;
        }
        break :blk c_egl.eglGetDisplay(c_egl.EGL_DEFAULT_DISPLAY);
    };
    if (display == c_egl.EGL_NO_DISPLAY) {
        std.debug.print("smoke-cell: eglGetDisplay failed\n", .{});
        return 1;
    }
    var major: c_egl.EGLint = 0;
    var minor: c_egl.EGLint = 0;
    if (c_egl.eglInitialize(display, &major, &minor) == c_egl.EGL_FALSE) return 1;
    if (c_egl.eglBindAPI(c_egl.EGL_OPENGL_ES_API) == c_egl.EGL_FALSE) return 1;

    const cfg_attribs = [_]c_egl.EGLint{
        c_egl.EGL_RED_SIZE, 8, c_egl.EGL_GREEN_SIZE, 8, c_egl.EGL_BLUE_SIZE, 8, c_egl.EGL_ALPHA_SIZE, 8,
        c_egl.EGL_RENDERABLE_TYPE, c_egl.EGL_OPENGL_ES3_BIT,
        c_egl.EGL_SURFACE_TYPE, c_egl.EGL_PBUFFER_BIT,
        c_egl.EGL_NONE,
    };
    var cfg: c_egl.EGLConfig = null;
    var n_cfg: c_egl.EGLint = 0;
    if (c_egl.eglChooseConfig(display, &cfg_attribs, &cfg, 1, &n_cfg) == c_egl.EGL_FALSE or n_cfg < 1) return 1;
    const ctx_attribs = [_]c_egl.EGLint{ c_egl.EGL_CONTEXT_MAJOR_VERSION, 3, c_egl.EGL_CONTEXT_MINOR_VERSION, 0, c_egl.EGL_NONE };
    const ctx = c_egl.eglCreateContext(display, cfg, c_egl.EGL_NO_CONTEXT, &ctx_attribs);
    if (ctx == c_egl.EGL_NO_CONTEXT) return 1;
    if (c_egl.eglMakeCurrent(display, c_egl.EGL_NO_SURFACE, c_egl.EGL_NO_SURFACE, ctx) == c_egl.EGL_FALSE) return 1;

    std.debug.print("smoke-cell: GL_VERSION={s}\n", .{c.glGetString(c.GL_VERSION)});

    // Offscreen FBO.
    var fbo: c_uint = 0;
    var rbo: c_uint = 0;
    c.glGenFramebuffers(1, &fbo);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glGenRenderbuffers(1, &rbo);
    c.glBindRenderbuffer(c.GL_RENDERBUFFER, rbo);
    c.glRenderbufferStorage(c.GL_RENDERBUFFER, c.GL_RGBA8, W, H);
    c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_RENDERBUFFER, rbo);
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("smoke-cell: framebuffer incomplete\n", .{});
        return 1;
    }
    c.glViewport(0, 0, W, H);
    c.glClearColor(0.05, 0.05, 0.10, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    // Atlas — pick a font that exists.
    var atlas: ?*Atlas = null;
    for (FONT_CANDIDATES) |path| {
        if (Atlas.init(allocator, path, FONT_SIZE)) |a| {
            atlas = a;
            break;
        } else |_| continue;
    }
    if (atlas == null) {
        std.debug.print("smoke-cell: no font found\n", .{});
        return 1;
    }
    defer atlas.?.deinit();
    atlas.?.realize();

    // Screen — 40 cols × 5 rows, will fit comfortably in 320x96.
    var pool = try StylePool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, 40, 5);
    defer screen.deinit();

    // Drive bytes through a Parser so we exercise the same path the
    // real terminal uses. Color text via SGR 38;5;2 (palette green).
    var parser = @import("parser/vt.zig").Parser.init(allocator);
    defer parser.deinit();
    const Ctx = struct {
        screen: *Screen,
        allocator: std.mem.Allocator,
    };
    const Emit = struct {
        fn cb(user: ?*anyopaque, ev: @import("parser/event.zig").Event) void {
            const ec: *Ctx = @ptrCast(@alignCast(user.?));
            var mut_ev = ev;
            ec.screen.apply(ev);
            mut_ev.deinit(ec.allocator);
        }
    };
    var ec = Ctx{ .screen = screen, .allocator = allocator };
    // Row 0: green text (SGR 38;5;2).
    // Row 2: red underlined text (SGR 31;4).
    // Row 4: a row of box-drawing chars (┌─┐│). These are non-ASCII
    // (U+2500 range) but don't need bidi/complex shaping. The
    // selective predicate keeps them in CellPass instead of routing
    // them to GridPass — preserving per-row dirty optimizations on
    // box-drawing-heavy TUIs (htop, btop, lf, yazi…).
    const greeting = "\x1b[38;5;2mHello, sketerm!\x1b[0m" ++
        // Row 1: colour emoji (U+1F600, grinning face) — exercises the
        // fontconfig colour-font fallback + BGRA strike rescale + the
        // GridPass colored-glyph shader branch. Soft assertion below:
        // machines without a colour emoji font render it monochrome.
        "\x1b[2;1H😀" ++
        "\x1b[3;1H\x1b[31;4mUnderlined\x1b[0m" ++
        // Box-drawing in cyan to verify CellPass renders them. The
        // chars are encoded as UTF-8 here — the parser turns them
        // into single u32 runes per cell.
        "\x1b[5;1H\x1b[36m┌─┐│└─┘\x1b[0m" ++
        // Row 4 (the only free row in this 5-row grid): a failed
        // OSC 133 command zone — exercises the command-block gutter
        // bar (red, leftmost ~3px of the row). CUP (not LF) moves to
        // the D row so nothing scrolls.
        "\x1b[4;1H\x1b]133;C\x07command output\x1b[5;1H\x1b]133;D;2\x07";
    parser.advance(greeting, Emit.cb, @ptrCast(&ec));

    // Cell pass.
    var cell_pass = CellPass.init(allocator);
    defer cell_pass.deinit();
    try cell_pass.realize();
    try cell_pass.rebuildAndUpload(screen, &pool, atlas.?);
    cell_pass.draw(atlas.?, W, H);

    // Keyboard-hints overlay — exercise the badge + highlight path
    // under real GL (label "a" over the first word of row 0).
    const hint_overlays = [_]Screen.HintOverlay{
        .{ .row = 0, .col_start = 0, .col_end = 5, .label = .{ 'a', 0 }, .label_len = 1, .typed = 0 },
    };
    screen.hints_overlay = &hint_overlays;

    // Overlay pass — draws cursor + focus border + scrollback indicator.
    var grid_pass = GridPass.init(allocator);
    defer grid_pass.deinit();
    try grid_pass.realize();
    grid_pass.canvas_w = @floatFromInt(W);
    grid_pass.canvas_h = @floatFromInt(H);
    try grid_pass.buildVertices(screen, &pool, atlas.?, true, true, &.{});
    grid_pass.draw(atlas.?, W, H);
    c.glFinish();

    // Read pixels back.
    const fb_bytes: usize = @intCast(W * H * 4);
    const fb = try allocator.alloc(u8, fb_bytes);
    defer allocator.free(fb);
    c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);

    // Assertions:
    // 1. Some non-bg, non-pure-white pixel exists where text was drawn
    //    (the green "Hello" — channel: G > R, G > B is the marker).
    // 2. Some focus-border accent (blue-ish, B > G > R) along the edge.
    // 3. Some red pixels in row 2 (the underlined text + the underline
    //    strip — both red).
    var greenish: usize = 0;
    var bluish_border: usize = 0;
    var reddish: usize = 0;
    var yellowish: usize = 0;
    var gutter_red: usize = 0;
    var any_text: usize = 0;
    var i: usize = 0;
    while (i < fb_bytes) : (i += 4) {
        const r: i32 = fb[i + 0];
        const g: i32 = fb[i + 1];
        const b: i32 = fb[i + 2];
        if (r < 0x20 and g < 0x20 and b < 0x30) continue;
        any_text += 1;
        if (g > r + 30 and g > b + 30) greenish += 1;
        if (b > g + 20 and b > r + 30) bluish_border += 1;
        if (r > g + 30 and r > b + 30) reddish += 1;
        // Emoji yellow: warm pixel, red+green both well above blue.
        if (r > 150 and g > 100 and r > b + 80 and g > b + 50) yellowish += 1;
        // Command-zone gutter bar: red pixels hugging the left edge
        // (x < 3, inside the padding strip — no glyph reaches there).
        if ((i / 4) % @as(usize, @intCast(W)) < 3 and r > g + 30 and r > b + 30) gutter_red += 1;
    }
    std.debug.print(
        "smoke-cell: any_text={d} greenish={d} bluish_border={d} reddish={d} emoji_yellowish={d} gutter_red={d}\n",
        .{ any_text, greenish, bluish_border, reddish, yellowish, gutter_red },
    );
    // Soft check only: no colour emoji font installed → 0 is legitimate.
    if (yellowish < 5) {
        std.debug.print("smoke-cell: note — no colour emoji pixels (colour font missing or colour pipeline broken)\n", .{});
    }

    if (any_text < 50) {
        std.debug.print("smoke-cell: FAIL — too few non-bg pixels (text not rendered?)\n", .{});
        return 2;
    }
    if (greenish < 5) {
        std.debug.print("smoke-cell: FAIL — no green text from SGR 38;5;2\n", .{});
        return 3;
    }
    if (bluish_border < 5) {
        std.debug.print("smoke-cell: FAIL — focus border not drawn\n", .{});
        return 4;
    }
    if (reddish < 5) {
        std.debug.print("smoke-cell: FAIL — no red text/underline (deco pass broken?)\n", .{});
        return 5;
    }
    if (gutter_red < 3) {
        std.debug.print("smoke-cell: FAIL — command-zone gutter bar not drawn\n", .{});
        return 6;
    }

    // Custom-shader pass: re-render the scene through a channel-
    // swapping user shader (r<->b). The red gutter bar must come out
    // blue — proves the offscreen detour + user program both ran.
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        const ShaderSource = @import("render/shader_pass.zig").Source;
        const user_src =
            \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            \\    vec4 t = texture(iChannel0, fragCoord / iResolution.xy);
            \\    fragColor = vec4(t.b, t.g, t.r, 1.0);
            \\}
        ;
        var shader_src = ShaderSource{ .src = user_src, .generation = 1 };
        var sp = ShaderPass{ .source = &shader_src };
        if (!sp.begin(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — shader pass begin/compile failed\n", .{});
            return 7;
        }
        c.glViewport(0, 0, W, H);
        c.glClearColor(0.05, 0.05, 0.08, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        cell_pass.draw(atlas.?, W, H);
        grid_pass.draw(atlas.?, W, H);
        sp.finish(W, H, 0.5);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        var gutter_blue: usize = 0;
        var j: usize = 0;
        while (j < fb_bytes) : (j += 4) {
            const r: i32 = fb[j + 0];
            const g: i32 = fb[j + 1];
            const b: i32 = fb[j + 2];
            if ((j / 4) % @as(usize, @intCast(W)) < 3 and b > g + 30 and b > r + 30) gutter_blue += 1;
        }
        std.debug.print("smoke-cell: shader gutter_blue={d}\n", .{gutter_blue});
        if (gutter_blue < 3) {
            std.debug.print("smoke-cell: FAIL — custom shader did not transform the frame\n", .{});
            return 8;
        }
    }

    // Shipped CRT shader: compile + run the real file (embedded at
    // build time) and assert the output is phosphor-amber — warm
    // pixels where text was, black bezel in the curved-off corner.
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        const ShaderSource = @import("render/shader_pass.zig").Source;
        const crt_src = @embedFile("crt_glsl");
        var shader_src = ShaderSource{ .src = crt_src, .generation = 1 };
        var sp = ShaderPass{ .source = &shader_src };
        if (!sp.begin(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — crt.glsl failed to compile\n", .{});
            return 9;
        }
        c.glViewport(0, 0, W, H);
        c.glClearColor(0.05, 0.05, 0.08, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        cell_pass.draw(atlas.?, W, H);
        grid_pass.draw(atlas.?, W, H);
        sp.finish(W, H, 0.5);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        var amber: usize = 0;
        var corner_dark = true;
        var j: usize = 0;
        while (j < fb_bytes) : (j += 4) {
            const r: i32 = fb[j + 0];
            const g: i32 = fb[j + 1];
            const b: i32 = fb[j + 2];
            // Amber phosphor: r > g > b with real brightness.
            if (r > 60 and r > g and g > b + 10) amber += 1;
        }
        // Corner pixel sits outside the curved tube → pure black.
        const cr = fb[0];
        const cg = fb[1];
        const cb = fb[2];
        if (cr > 8 or cg > 8 or cb > 8) corner_dark = false;
        std.debug.print("smoke-cell: crt amber={d} corner_dark={}\n", .{ amber, corner_dark });
        if (amber < 50 or !corner_dark) {
            std.debug.print("smoke-cell: FAIL — crt shader output wrong\n", .{});
            return 10;
        }

        // shader_param override path: mono=0 keeps the original
        // colors, so the phosphor-amber count must collapse (the
        // green/red/cyan test text stops being warm). Same program,
        // no recompile — overrides upload per frame.
        const ParamKV = @import("render/shader_pass.zig").ParamKV;
        const flat = [_]ParamKV{.{ .name = "colorize", .value = 0.0 }};
        shader_src.overrides = &flat;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, sp.fbo);
        c.glViewport(0, 0, W, H);
        c.glClearColor(0.05, 0.05, 0.08, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        cell_pass.draw(atlas.?, W, H);
        grid_pass.draw(atlas.?, W, H);
        sp.finish(W, H, 0.6);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        var amber2: usize = 0;
        var k: usize = 0;
        while (k < fb_bytes) : (k += 4) {
            const r: i32 = fb[k + 0];
            const g: i32 = fb[k + 1];
            const b: i32 = fb[k + 2];
            if (r > 60 and r > g and g > b + 10) amber2 += 1;
        }
        std.debug.print("smoke-cell: crt mono-override amber={d} (was {d})\n", .{ amber2, amber });
        if (amber2 * 2 >= amber) {
            std.debug.print("smoke-cell: FAIL — shader_param override did not reach the GPU\n", .{});
            return 11;
        }
    }

    // CRT-Lottes port: compile + render the shipped file, assert it
    // produces output (beam math is easy to break silently) and the
    // warped-off corner is black.
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        const ShaderSource = @import("render/shader_pass.zig").Source;
        const lottes_src = @embedFile("crt_lottes_glsl");
        var ssrc = ShaderSource{ .src = lottes_src, .generation = 1 };
        var sp = ShaderPass{ .source = &ssrc };
        if (!sp.begin(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — crt-lottes.glsl failed to compile\n", .{});
            return 14;
        }
        c.glViewport(0, 0, W, H);
        c.glClearColor(0.05, 0.05, 0.08, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        cell_pass.draw(atlas.?, W, H);
        grid_pass.draw(atlas.?, W, H);
        sp.finish(W, H, 0.3);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        var lit: usize = 0;
        var lm: usize = 0;
        while (lm < fb_bytes) : (lm += 4) {
            if (@max(fb[lm], @max(fb[lm + 1], fb[lm + 2])) > 60) lit += 1;
        }
        const corner_black = fb[0] < 8 and fb[1] < 8 and fb[2] < 8;
        std.debug.print("smoke-cell: lottes lit={d} corner_black={}\n", .{ lit, corner_black });
        if (lit < 100 or !corner_black) {
            std.debug.print("smoke-cell: FAIL — crt-lottes output wrong\n", .{});
            return 15;
        }
    }

    // RetroArch ports: compile + render each, assert output exists.
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        const ShaderSource = @import("render/shader_pass.zig").Source;
        const ports = [_]struct { name: []const u8, src: []const u8 }{
            .{ .name = "crt-easymode", .src = @embedFile("crt_easymode_glsl") },
            .{ .name = "zfast-crt", .src = @embedFile("zfast_crt_glsl") },
        };
        for (ports) |port| {
            var ssrc = ShaderSource{ .src = port.src, .generation = 1 };
            var sp = ShaderPass{ .source = &ssrc };
            if (!sp.begin(allocator, W, H)) {
                std.debug.print("smoke-cell: FAIL — {s} failed to compile\n", .{port.name});
                return 16;
            }
            c.glViewport(0, 0, W, H);
            c.glClearColor(0.05, 0.05, 0.08, 1.0);
            c.glClear(c.GL_COLOR_BUFFER_BIT);
            cell_pass.draw(atlas.?, W, H);
            grid_pass.draw(atlas.?, W, H);
            sp.finish(W, H, 0.3);
            c.glFinish();
            c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
            var lit: usize = 0;
            var pm: usize = 0;
            while (pm < fb_bytes) : (pm += 4) {
                if (@max(fb[pm], @max(fb[pm + 1], fb[pm + 2])) > 60) lit += 1;
            }
            std.debug.print("smoke-cell: {s} lit={d}\n", .{ port.name, lit });
            if (lit < 100) {
                std.debug.print("smoke-cell: FAIL — {s} output wrong\n", .{port.name});
                return 17;
            }
        }
    }

    // Previous-frame feedback (iChannel1): a decaying-max shader run
    // twice — second frame's scene is empty, so anything bright on
    // screen can ONLY be the ghost of frame one at half brightness.
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        const ShaderSource = @import("render/shader_pass.zig").Source;
        const fb_user =
            \\void mainImage(out vec4 o, in vec2 fc) {
            \\    vec2 uv = fc / iResolution.xy;
            \\    o = vec4(max(texture(iChannel0, uv).rgb, texture(iChannel1, uv).rgb * 0.5), 1.0);
            \\}
        ;
        var ssrc = ShaderSource{ .src = fb_user, .generation = 1 };
        var sp2 = ShaderPass{ .source = &ssrc };

        // Frame 1: real scene.
        if (!sp2.begin(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — feedback shader begin failed\n", .{});
            return 12;
        }
        c.glViewport(0, 0, W, H);
        c.glClearColor(0.0, 0.0, 0.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        cell_pass.draw(atlas.?, W, H);
        sp2.finish(W, H, 0.1);

        // Frame 2: empty scene — only the ghost should remain.
        if (!sp2.begin(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — feedback shader re-begin failed\n", .{});
            return 12;
        }
        c.glViewport(0, 0, W, H);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        sp2.finish(W, H, 0.2);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        var ghost: usize = 0;
        var bright: usize = 0;
        var m: usize = 0;
        while (m < fb_bytes) : (m += 4) {
            const r: i32 = fb[m + 0];
            const g: i32 = fb[m + 1];
            const b: i32 = fb[m + 2];
            const mx = @max(r, @max(g, b));
            if (mx > 40) ghost += 1;
            if (mx > 200) bright += 1;
        }
        std.debug.print("smoke-cell: feedback ghost={d} bright={d}\n", .{ ghost, bright });
        // Ghost present (history sampled) AND dimmed (it decayed —
        // i.e. not just the original frame leaking through).
        if (ghost < 50 or bright > 10) {
            std.debug.print("smoke-cell: FAIL — iChannel1 feedback broken\n", .{});
            return 13;
        }
    }

    // //@texture inputs: builtin:noise and a file LUT. The shaders
    // output ONLY the texture, so the framebuffer content proves the
    // load+bind path end to end.
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        const ShaderSource = @import("render/shader_pass.zig").Source;

        // builtin:noise — output should be wideband noise.
        const noise_user =
            \\//@texture noiseTex builtin:noise
            \\uniform sampler2D noiseTex;
            \\void mainImage(out vec4 o, in vec2 fc) {
            \\    o = vec4(texture(noiseTex, fc / 256.0).rgb, 1.0);
            \\}
        ;
        var nsrc = ShaderSource{ .src = noise_user, .generation = 1 };
        var nsp = ShaderPass{ .source = &nsrc };
        if (!nsp.begin(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — noise texture shader begin failed\n", .{});
            return 18;
        }
        c.glViewport(0, 0, W, H);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        nsp.finish(W, H, 0.0);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        var lo: usize = 0;
        var hi: usize = 0;
        var nm: usize = 0;
        while (nm < fb_bytes) : (nm += 4) {
            if (fb[nm] < 64) lo += 1;
            if (fb[nm] > 192) hi += 1;
        }
        std.debug.print("smoke-cell: noise-tex lo={d} hi={d}\n", .{ lo, hi });
        if (lo < 1000 or hi < 1000) {
            std.debug.print("smoke-cell: FAIL — builtin:noise texture not sampled\n", .{});
            return 19;
        }

        // File LUT: a hand-written 2x2 pure-red BMP, loaded via a
        // shader-relative path (Source.dir).
        const bmp_path = "/tmp/sketerm-smoke-lut.bmp";
        {
            // 24-bit BMP, 2x2, rows padded to 4 bytes (2*3=6 → pad 2).
            const px_data = [_]u8{
                0, 0, 255, 0, 0, 255, 0, 0, // row 0: BGR red ×2 + pad
                0, 0, 255, 0, 0, 255, 0, 0, // row 1
            };
            var header = [_]u8{0} ** 54;
            header[0] = 'B';
            header[1] = 'M';
            std.mem.writeInt(u32, header[2..6], 54 + px_data.len, .little);
            std.mem.writeInt(u32, header[10..14], 54, .little);
            std.mem.writeInt(u32, header[14..18], 40, .little);
            std.mem.writeInt(i32, header[18..22], 2, .little);
            std.mem.writeInt(i32, header[22..26], 2, .little);
            std.mem.writeInt(u16, header[26..28], 1, .little);
            std.mem.writeInt(u16, header[28..30], 24, .little);
            const f = c.fopen(bmp_path, "wb") orelse {
                std.debug.print("smoke-cell: FAIL — cannot write LUT bmp\n", .{});
                return 20;
            };
            _ = c.fwrite(&header, 1, header.len, f);
            _ = c.fwrite(&px_data, 1, px_data.len, f);
            _ = c.fclose(f);
        }
        const lut_user =
            \\//@texture lut sketerm-smoke-lut.bmp
            \\uniform sampler2D lut;
            \\void mainImage(out vec4 o, in vec2 fc) {
            \\    o = vec4(texture(lut, fc / iResolution.xy).rgb, 1.0);
            \\}
        ;
        var lsrc = ShaderSource{ .src = lut_user, .generation = 1, .dir = "/tmp" };
        var lsp = ShaderPass{ .source = &lsrc };
        if (!lsp.begin(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — file LUT shader begin failed\n", .{});
            return 21;
        }
        c.glViewport(0, 0, W, H);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        lsp.finish(W, H, 0.0);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        var red: usize = 0;
        var lm: usize = 0;
        while (lm < fb_bytes) : (lm += 4) {
            if (fb[lm] > 200 and fb[lm + 1] < 50 and fb[lm + 2] < 50) red += 1;
        }
        _ = c.remove(bmp_path);
        std.debug.print("smoke-cell: file-lut red={d}/{d}\n", .{ red, fb_bytes / 4 });
        if (red < fb_bytes / 8) {
            std.debug.print("smoke-cell: FAIL — file LUT not loaded/bound\n", .{});
            return 22;
        }
    }

    // Inactive-pane dim: the dim-only post path (no user shader).
    // Render a known mid-gray scene, then darken 0.5 + desaturate 0,
    // and confirm the output is ~half brightness with hue intact.
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        var sp = ShaderPass{};
        sp.dim_darken = 0.5;
        sp.dim_desat = 0.0;
        if (!sp.beginDim(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — beginDim failed\n", .{});
            return 23;
        }
        c.glViewport(0, 0, W, H);
        // Distinct channels so a desaturate bug would show as channel
        // convergence: (200, 100, 40).
        c.glClearColor(200.0 / 255.0, 100.0 / 255.0, 40.0 / 255.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        sp.finishDim(W, H);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        const r: i32 = fb[0];
        const g: i32 = fb[1];
        const b: i32 = fb[2];
        std.debug.print("smoke-cell: dim darken r={d} g={d} b={d}\n", .{ r, g, b });
        // Each channel ~halved (200->100, 100->50, 40->20), ±8.
        if (@abs(r - 100) > 8 or @abs(g - 50) > 8 or @abs(b - 20) > 8) {
            std.debug.print("smoke-cell: FAIL — darken math wrong\n", .{});
            return 24;
        }
        // Dither must produce per-pixel variation on this flat input
        // (otherwise banding stays). The red channel should span more
        // than one 8-bit level across the buffer.
        var rmin: i32 = 255;
        var rmax: i32 = 0;
        var di: usize = 0;
        while (di < fb_bytes) : (di += 4) {
            const rv: i32 = fb[di];
            if (rv < rmin) rmin = rv;
            if (rv > rmax) rmax = rv;
        }
        std.debug.print("smoke-cell: dim dither red span {d}..{d}\n", .{ rmin, rmax });
        if (rmax - rmin < 1) {
            std.debug.print("smoke-cell: FAIL — dither not applied (flat output)\n", .{});
            return 27;
        }
        sp.releaseGL();
    }

    // Inactive-pane desaturate: full desaturate must collapse the
    // channels to a single luma value (no darken).
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        var sp = ShaderPass{};
        sp.dim_darken = 0.0;
        sp.dim_desat = 1.0;
        if (!sp.beginDim(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — beginDim (desat) failed\n", .{});
            return 25;
        }
        c.glViewport(0, 0, W, H);
        c.glClearColor(200.0 / 255.0, 100.0 / 255.0, 40.0 / 255.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        sp.finishDim(W, H);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        const r: i32 = fb[0];
        const g: i32 = fb[1];
        const b: i32 = fb[2];
        std.debug.print("smoke-cell: dim desat r={d} g={d} b={d}\n", .{ r, g, b });
        // luma = 0.2126*200 + 0.7152*100 + 0.0722*40 ≈ 116; all equal.
        if (@abs(r - g) > 3 or @abs(g - b) > 3 or @abs(r - 116) > 8) {
            std.debug.print("smoke-cell: FAIL — desaturate math wrong\n", .{});
            return 26;
        }
        sp.releaseGL();
    }

    std.debug.print("smoke-cell: PASS\n", .{});
    return 0;
}
