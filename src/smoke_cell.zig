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
const CursorTrail = @import("render/cursor_trail.zig").Trail;

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
        "\x1b[4;1H\x1b]133;C\x07command output\x1b[5;1H\x1b]133;D;2\x07" ++
        // Two vertically adjacent box-drawing verticals, away from
        // everything else. The built-in drawing exists so these join:
        // the assertion below reads the pixel column back and refuses
        // a gap at the cell boundary.
        "\x1b[1;30H│\x1b[2;30H│";
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

    // Box-drawing continuity. Two stacked U+2502 must read back as ONE
    // unbroken run of lit pixel rows: a gap there is exactly the seam
    // the built-in drawing exists to remove, and it is invisible to
    // every other assertion in this file. The line is found by
    // scanning for the tallest lit column rather than by computing
    // where it should be, so grid padding cannot make this pass or
    // fail for the wrong reason.
    {
        const ch: usize = atlas.?.cell_h;
        const wu: usize = @intCast(W);
        const hu: usize = @intCast(H);
        // The focus border runs along all four edges.
        const border: usize = 3;
        var best_rows: usize = 0;
        var best_span: usize = 0;
        var x: usize = border;
        while (x < wu - border) : (x += 1) {
            var rows: usize = 0;
            var first: ?usize = null;
            var last: usize = 0;
            var y: usize = border;
            while (y < hu - border) : (y += 1) {
                const o = (y * wu + x) * 4;
                const sum: u32 = @as(u32, fb[o]) + fb[o + 1] + fb[o + 2];
                if (sum <= 260) continue; // background is ~0.05,0.05,0.10
                rows += 1;
                if (first == null) first = y;
                last = y;
            }
            if (rows > best_rows) {
                best_rows = rows;
                best_span = if (first) |f| last - f + 1 else 0;
            }
        }
        std.debug.print("smoke-cell: tallest lit column rows={d} span={d} (2 cells = {d}px)\n", .{ best_rows, best_span, ch * 2 });
        if (best_rows + 2 < ch * 2) {
            std.debug.print("smoke-cell: FAIL — the stacked box-drawing verticals do not span both cells\n", .{});
            return 27;
        }
        if (best_span != best_rows) {
            std.debug.print("smoke-cell: FAIL — the box-drawing vertical has a gap at the cell boundary\n", .{});
            return 28;
        }
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

    // Pane corner radius: a non-zero radius must engage the
    // post-process on its own (no dim asked for) and cut the corner
    // pixels to alpha 0 while the centre stays untouched.
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        var sp = ShaderPass{};
        sp.corner_radius = 24.0;
        if (!sp.wantsDim()) {
            std.debug.print("smoke-cell: FAIL — corner radius did not request the post pass\n", .{});
            return 28;
        }
        if (!sp.beginDim(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — beginDim (corner) failed\n", .{});
            return 29;
        }
        c.glViewport(0, 0, W, H);
        c.glClearColor(1.0, 1.0, 1.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        sp.finishDim(W, H);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        const px = struct {
            fn a(buf: []const u8, x: usize, y: usize) i32 {
                return buf[(y * @as(usize, W) + x) * 4 + 3];
            }
        };
        const corner = px.a(fb, 0, 0);
        const centre = px.a(fb, W / 2, H / 2);
        const edge_mid = px.a(fb, 0, H / 2); // mid-height left edge: inside
        std.debug.print(
            "smoke-cell: corner radius alpha corner={d} centre={d} edge_mid={d}\n",
            .{ corner, centre, edge_mid },
        );
        if (corner != 0 or centre != 255 or edge_mid != 255) {
            std.debug.print("smoke-cell: FAIL — corner radius cut the wrong pixels\n", .{});
            return 30;
        }
        sp.releaseGL();
    }

    // …and a zero radius must leave every pixel alone, including the
    // very corner (the SDF sits exactly ON the edge there, so an
    // unguarded smoothstep would halve it).
    {
        const ShaderPass = @import("render/shader_pass.zig").ShaderPass;
        var sp = ShaderPass{};
        sp.corner_radius = 0.0;
        sp.dim_darken = 0.001; // engage the pass without changing colour
        if (!sp.beginDim(allocator, W, H)) {
            std.debug.print("smoke-cell: FAIL — beginDim (no corner) failed\n", .{});
            return 31;
        }
        c.glViewport(0, 0, W, H);
        c.glClearColor(1.0, 1.0, 1.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        sp.finishDim(W, H);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        if (fb[3] != 255) {
            std.debug.print("smoke-cell: FAIL — zero radius still cut the corner (a={d})\n", .{fb[3]});
            return 32;
        }
    }

    // Glyph Protocol (fmt=glyf + fmt=colrv0) rasteriser proof:
    // register through Parser→Screen, render, read pixels back. Also
    // proves overwrite invalidation (glossary generation → cell
    // rebuild), the clear fallback, width=2 spanning two cells,
    // re-rasterisation from retained payloads after an Atlas rebuild
    // at a new cell size, colrv0 painter-order layer compositing, and
    // the 0xFFFF current-foreground palette sentinel re-rasterising
    // per SGR foreground.
    {
        const helpers = struct {
            /// One-contour axis-aligned rectangle, coordinates in font
            /// units, y=0 at the baseline (Y-up).
            fn rectGlyf(a: std.mem.Allocator, x0: i16, y0: i16, x1: i16, y1: i16) ![]u8 {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(a);
                var tmp: [2]u8 = undefined;
                const wi16 = struct {
                    fn go(l: *std.ArrayList(u8), al: std.mem.Allocator, t: *[2]u8, v: i16) !void {
                        std.mem.writeInt(i16, t, v, .big);
                        try l.appendSlice(al, t);
                    }
                }.go;
                try wi16(&out, a, &tmp, 1); // numberOfContours
                try wi16(&out, a, &tmp, x0);
                try wi16(&out, a, &tmp, y0);
                try wi16(&out, a, &tmp, x1);
                try wi16(&out, a, &tmp, y1);
                std.mem.writeInt(u16, &tmp, 3, .big); // endPtsOfContours
                try out.appendSlice(a, &tmp);
                std.mem.writeInt(u16, &tmp, 0, .big); // instructionLength
                try out.appendSlice(a, &tmp);
                try out.appendSlice(a, &.{ 0x01, 0x01, 0x01, 0x01 }); // 4 on-curve
                for ([_]i16{ x0, x1 - x0, 0, x0 - x1 }) |dx| try wi16(&out, a, &tmp, dx);
                for ([_]i16{ y0, 0, y1 - y0, 0 }) |dy| try wi16(&out, a, &tmp, dy);
                return out.toOwnedSlice(a);
            }

            fn registerApc(a: std.mem.Allocator, cp: u32, extra: []const u8, glyf: []const u8) ![]u8 {
                const enc = std.base64.standard.Encoder;
                const b64 = try a.alloc(u8, enc.calcSize(glyf.len));
                defer a.free(b64);
                _ = enc.encode(b64, glyf);
                return std.fmt.allocPrint(a, "\x1b_25a1;r;cp={x};reply=0{s};{s}\x1b\\", .{ cp, extra, b64 });
            }

            /// Lit-pixel count + screen-y centroid over a screen-space
            /// rect (glReadPixels row 0 is the framebuffer BOTTOM).
            fn stats(fbuf: []const u8, x0: usize, y0: usize, w: usize, h: usize) struct { count: usize, ysum: usize } {
                var count: usize = 0;
                var ysum: usize = 0;
                var y = y0;
                while (y < y0 + h) : (y += 1) {
                    const fb_row = @as(usize, @intCast(H)) - 1 - y;
                    var x = x0;
                    while (x < x0 + w) : (x += 1) {
                        const o = (fb_row * @as(usize, @intCast(W)) + x) * 4;
                        const sum: u32 = @as(u32, fbuf[o]) + fbuf[o + 1] + fbuf[o + 2];
                        if (sum > 260) {
                            count += 1;
                            ysum += y;
                        }
                    }
                }
                return .{ .count = count, .ysum = ysum };
            }
        };

        const cw: usize = atlas.?.cell_w;
        const chh: usize = atlas.?.cell_h;
        const padu: usize = 6;

        // Wipe the earlier scene; drop overlays.
        screen.hints_overlay = &.{};
        parser.advance("\x1b[0m\x1b[2J\x1b[H", Emit.cb, @ptrCast(&ec));

        // Stage A: rect high above the baseline (y 250..450 of upm
        // 1000) at U+F0100 (plane-15 PUA: no system font covers it,
        // so the post-clear fallback below is honest tofu).
        const rect_hi = try helpers.rectGlyf(allocator, 0, 250, 1000, 450);
        defer allocator.free(rect_hi);
        const apc_hi = try helpers.registerApc(allocator, 0xF0100, "", rect_hi);
        defer allocator.free(apc_hi);
        parser.advance(apc_hi, Emit.cb, @ptrCast(&ec));
        parser.advance("\x1b[1;1H\u{F0100}", Emit.cb, @ptrCast(&ec));

        const render = struct {
            fn go(cp_: *CellPass, sc: *Screen, pl: *StylePool, at: *Atlas, fbuf: []u8) !void {
                // Caller has the offscreen FBO bound; keep it.
                c.glViewport(0, 0, W, H);
                c.glClearColor(0.05, 0.05, 0.10, 1.0);
                c.glClear(c.GL_COLOR_BUFFER_BIT);
                try cp_.rebuildAndUpload(sc, pl, at);
                cp_.draw(at, W, H);
                c.glFinish();
                c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fbuf.ptr);
            }
        }.go;

        // The offscreen FBO from the top of main is still what we
        // want to render into (id in `fbo`).
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        try render(&cell_pass, screen, &pool, atlas.?, fb);
        const a_stats = helpers.stats(fb, padu, padu, cw, chh);
        std.debug.print("smoke-cell: glyph-protocol A lit={d}\n", .{a_stats.count});
        if (a_stats.count < 4) {
            std.debug.print("smoke-cell: FAIL — registered glyph did not render\n", .{});
            return 40;
        }
        const a_centroid = a_stats.ysum / a_stats.count;

        // Stage B: overwrite the SAME codepoint with a rect hugging
        // the baseline (y -50..150). No cell changed — only the
        // glossary generation may trigger the rebuild. The centroid
        // must move DOWN the screen (also proves the Y-flip is right).
        const rect_lo = try helpers.rectGlyf(allocator, 0, -50, 1000, 150);
        defer allocator.free(rect_lo);
        const apc_lo = try helpers.registerApc(allocator, 0xF0100, "", rect_lo);
        defer allocator.free(apc_lo);
        parser.advance(apc_lo, Emit.cb, @ptrCast(&ec));
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        try render(&cell_pass, screen, &pool, atlas.?, fb);
        const b_stats = helpers.stats(fb, padu, padu, cw, chh);
        std.debug.print("smoke-cell: glyph-protocol B lit={d}\n", .{b_stats.count});
        if (b_stats.count < 4) {
            std.debug.print("smoke-cell: FAIL — overwritten glyph did not render\n", .{});
            return 41;
        }
        const b_centroid = b_stats.ysum / b_stats.count;
        std.debug.print("smoke-cell: glyph-protocol centroids a={d} b={d}\n", .{ a_centroid, b_centroid });
        if (b_centroid <= a_centroid + 1) {
            std.debug.print("smoke-cell: FAIL — overwrite did not change pixels (stale atlas?) or Y orientation wrong\n", .{});
            return 42;
        }

        // Stage C: clear the slot; the cell must fall back to tofu
        // (U+F0100 has no system-font coverage — the cell goes dark).
        parser.advance("\x1b_25a1;c;cp=F0100\x1b\\", Emit.cb, @ptrCast(&ec));
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        try render(&cell_pass, screen, &pool, atlas.?, fb);
        const c_stats = helpers.stats(fb, padu, padu, cw, chh);
        std.debug.print("smoke-cell: glyph-protocol post-clear lit={d}\n", .{c_stats.count});
        if (c_stats.count >= 4) {
            std.debug.print("smoke-cell: FAIL — cleared glyph still renders\n", .{});
            return 43;
        }

        // Stage D: width=2 paints across two cells (layout stays 1).
        const rect_wide = try helpers.rectGlyf(allocator, 0, 100, 2000, 500);
        defer allocator.free(rect_wide);
        const apc_wide = try helpers.registerApc(allocator, 0xF0101, ";width=2", rect_wide);
        defer allocator.free(apc_wide);
        parser.advance(apc_wide, Emit.cb, @ptrCast(&ec));
        parser.advance("\x1b[3;1H\u{F0101}", Emit.cb, @ptrCast(&ec));
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        try render(&cell_pass, screen, &pool, atlas.?, fb);
        const d_first = helpers.stats(fb, padu, padu + 2 * chh, cw, chh);
        const d_second = helpers.stats(fb, padu + cw, padu + 2 * chh, cw, chh);
        std.debug.print("smoke-cell: glyph-protocol width=2 first={d} second={d}\n", .{ d_first.count, d_second.count });
        if (d_first.count < 4 or d_second.count < 4) {
            std.debug.print("smoke-cell: FAIL — width=2 glyph does not span both cells\n", .{});
            return 44;
        }

        // Stage E: the GridPass overlay path (a row containing RTL is
        // routed there) must resolve the glossary too. Hebrew aleph +
        // the wide glyph on row 5.
        parser.advance("\x1b[5;1H\u{05D0} \u{F0101}", Emit.cb, @ptrCast(&ec));
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        try render(&cell_pass, screen, &pool, atlas.?, fb);
        try grid_pass.buildVertices(screen, &pool, atlas.?, false, true, &.{});
        grid_pass.draw(atlas.?, W, H);
        c.glFinish();
        c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
        // An RTL-leading row reorders to the right margin — accept
        // lit pixels anywhere in the row band (nothing else draws
        // there: focused=false means no border).
        const e_stats = helpers.stats(fb, padu, padu + 4 * chh, @as(usize, @intCast(W)) - 2 * padu, chh);
        std.debug.print("smoke-cell: glyph-protocol overlay-row lit={d}\n", .{e_stats.count});
        if (e_stats.count < 4) {
            std.debug.print("smoke-cell: FAIL — overlay (bidi) row lost the custom glyph\n", .{});
            return 45;
        }

        // Stage F: Atlas rebuild at a different cell size — the glyph
        // must re-rasterise from the retained payload (resolution
        // independence). Fresh Atlas exactly like a font-size change;
        // per the renderer invariants the passes are marked dirty.
        var atlas2: ?*Atlas = null;
        for (FONT_CANDIDATES) |path| {
            if (Atlas.init(allocator, path, FONT_SIZE + 6)) |a2| {
                atlas2 = a2;
                break;
            } else |_| continue;
        }
        if (atlas2 == null) return 46;
        atlas2.?.realize();
        cell_pass.markAllDirty();
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        try render(&cell_pass, screen, &pool, atlas2.?, fb);
        const cw2: usize = atlas2.?.cell_w;
        const ch2: usize = atlas2.?.cell_h;
        const f_stats = helpers.stats(fb, padu, padu + 2 * ch2, cw2 * 2, ch2);
        std.debug.print("smoke-cell: glyph-protocol rebuilt-atlas lit={d} (cell {d}x{d} -> {d}x{d})\n", .{ f_stats.count, cw, chh, cw2, ch2 });
        const f_failed = f_stats.count < 4;
        atlas2.?.releaseGL();
        atlas2.?.deinit();
        // Leave the shared passes pointing back at the original atlas.
        cell_pass.markAllDirty();
        if (f_failed) {
            std.debug.print("smoke-cell: FAIL — glyph did not re-rasterise after atlas rebuild\n", .{});
            return 47;
        }

        // ── colrv0 stages ────────────────────────────────────────
        const gp = @import("parser/glyph_protocol.zig");
        const colr_helpers = struct {
            fn registerColrApc(a: std.mem.Allocator, cp: u32, container: []const u8) ![]u8 {
                const enc = std.base64.standard.Encoder;
                const b64 = try a.alloc(u8, enc.calcSize(container.len));
                defer a.free(b64);
                _ = enc.encode(b64, container);
                return std.fmt.allocPrint(a, "\x1b_25a1;r;cp={x};fmt=colrv0;reply=0;{s}\x1b\\", .{ cp, b64 });
            }

            /// Sample the framebuffer at screen (x, y) — y from the TOP
            /// (glReadPixels row 0 is the framebuffer bottom).
            fn px(fbuf: []const u8, x: usize, y: usize) [3]u8 {
                const fb_row = @as(usize, @intCast(H)) - 1 - y;
                const o = (fb_row * @as(usize, @intCast(W)) + x) * 4;
                return .{ fbuf[o], fbuf[o + 1], fbuf[o + 2] };
            }

            fn countColor(fbuf: []const u8, x0: usize, y0: usize, w_: usize, h_: usize, hot: usize, cold_a: usize, cold_b: usize) usize {
                var count: usize = 0;
                var y = y0;
                while (y < y0 + h_) : (y += 1) {
                    var x = x0;
                    while (x < x0 + w_) : (x += 1) {
                        const p = px(fbuf, x, y);
                        if (p[hot] > 150 and p[cold_a] < 100 and p[cold_b] < 100) count += 1;
                    }
                }
                return count;
            }
        };

        // Stage G: a two-layer colrv0 glyph — layer 1 fills the box
        // red, layer 2 paints a smaller green rect ON TOP (painter's
        // order). Both colours must land, and the covered centre must
        // show the SECOND layer's green.
        const outer = try helpers.rectGlyf(allocator, 0, -200, 1000, 800);
        defer allocator.free(outer);
        // Full-width band: x is scaled by cell HEIGHT (scale = h/upm)
        // and clipped at the cell's right edge, so only y separates
        // the two layers reliably.
        const inner = try helpers.rectGlyf(allocator, 0, 200, 1000, 500);
        defer allocator.free(inner);
        const two_layer = try gp.colrContainerBytes(allocator, &.{ outer, inner }, &.{
            .{ .glyph = 0, .palette = 0 },
            .{ .glyph = 1, .palette = 1 },
        }, &.{ 0xFF0000FF, 0x00FF00FF });
        defer allocator.free(two_layer);
        const apc_colr = try colr_helpers.registerColrApc(allocator, 0xF0102, two_layer);
        defer allocator.free(apc_colr);
        parser.advance(apc_colr, Emit.cb, @ptrCast(&ec));
        parser.advance("\x1b[2;1H\u{F0102}", Emit.cb, @ptrCast(&ec));
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        try render(&cell_pass, screen, &pool, atlas.?, fb);
        const g_x0 = padu;
        const g_y0 = padu + 1 * chh;
        const reds = colr_helpers.countColor(fb, g_x0, g_y0, cw, chh, 0, 1, 2);
        const greens = colr_helpers.countColor(fb, g_x0, g_y0, cw, chh, 1, 0, 2);
        const center = colr_helpers.px(fb, g_x0 + cw / 2, g_y0 + (chh * 45) / 100);
        std.debug.print("smoke-cell: colrv0 two-layer reds={d} greens={d} center=({d},{d},{d})\n", .{ reds, greens, center[0], center[1], center[2] });
        if (reds < 3 or greens < 3) {
            std.debug.print("smoke-cell: FAIL — colrv0 layers missing a colour (red={d} green={d})\n", .{ reds, greens });
            return 48;
        }
        if (center[1] <= center[0]) {
            std.debug.print("smoke-cell: FAIL — colrv0 layer order wrong (centre not green)\n", .{});
            return 49;
        }

        // Stage H: palette 0xFFFF resolves to the CURRENT SGR
        // foreground, and a different foreground re-rasterises
        // rather than reusing the cached pixels (the Rio stale-colour
        // bug this build refuses to copy).
        const fg_container = try gp.colrContainerBytes(allocator, &.{outer}, &.{
            .{ .glyph = 0, .palette = gp.PALETTE_FOREGROUND },
        }, &.{});
        defer allocator.free(fg_container);
        const apc_fg = try colr_helpers.registerColrApc(allocator, 0xF0103, fg_container);
        defer allocator.free(apc_fg);
        parser.advance(apc_fg, Emit.cb, @ptrCast(&ec));
        parser.advance("\x1b[4;1H\x1b[38;2;255;0;0m\u{F0103}\x1b[4;3H\x1b[38;2;0;0;255m\u{F0103}\x1b[0m", Emit.cb, @ptrCast(&ec));
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        try render(&cell_pass, screen, &pool, atlas.?, fb);
        const fg_y = padu + 3 * chh + chh / 2;
        const p_red = colr_helpers.px(fb, padu + cw / 2, fg_y);
        const p_blue = colr_helpers.px(fb, padu + 2 * cw + cw / 2, fg_y);
        std.debug.print("smoke-cell: colrv0 0xFFFF fg red-cell=({d},{d},{d}) blue-cell=({d},{d},{d})\n", .{ p_red[0], p_red[1], p_red[2], p_blue[0], p_blue[1], p_blue[2] });
        if (!(p_red[0] > 150 and p_red[2] < 100)) {
            std.debug.print("smoke-cell: FAIL — 0xFFFF layer did not take the red foreground\n", .{});
            return 50;
        }
        if (!(p_blue[2] > 150 and p_blue[0] < 100)) {
            std.debug.print("smoke-cell: FAIL — 0xFFFF glyph reused the first foreground's pixels (Rio bug)\n", .{});
            return 51;
        }

        // ── colrv1 stages ────────────────────────────────────────
        // Paint-graph rasteriser proof: linear gradient direction,
        // radial falloff, a real composite blend, the graph-deep
        // 0xFFFF sentinel re-rasterising per foreground, and the
        // documented sweep degradation.
        const v1_helpers = struct {
            fn registerV1Apc(a: std.mem.Allocator, cp: u32, container: []const u8) ![]u8 {
                const enc = std.base64.standard.Encoder;
                const b64 = try a.alloc(u8, enc.calcSize(container.len));
                defer a.free(b64);
                _ = enc.encode(b64, container);
                return std.fmt.allocPrint(a, "\x1b_25a1;r;cp={x};fmt=colrv1;reply=0;{s}\x1b\\", .{ cp, b64 });
            }
        };

        // Font-unit helpers: upm 1000, scale = chh/1000 px per unit.
        const u_per_px: f32 = 1000.0 / @as(f32, @floatFromInt(chh));
        const units = struct {
            fn fromPx(px_v: f32, upp: f32) i16 {
                return @intFromFloat(@round(px_v * upp));
            }
        };
        const cw_units: i16 = units.fromPx(@floatFromInt(cw), u_per_px);
        const ascent_px: f32 = @floatFromInt(atlas.?.ascent);
        // Font-space y of the cell's vertical midline (y-up, baseline 0).
        const ymid_units: i16 = units.fromPx(ascent_px - @as(f32, @floatFromInt(chh)) / 2.0, u_per_px);

        // One rect outline that covers the whole cell after clipping.
        const cover = try helpers.rectGlyf(allocator, -100, -700, 3000, 1500);
        defer allocator.free(cover);

        const gpv = @import("parser/glyph_protocol.zig");

        // Stage I: linear gradient red→blue across the cell (+x).
        const i_stops = [_]gpv.V1Stop{
            .{ .offset = 0.0, .palette = 0 },
            .{ .offset = 1.0, .palette = 1 },
        };
        const i_lin = gpv.V1Node{ .linear = .{
            .stops = &i_stops,
            .x0 = 0,
            .y0 = 0,
            .x1 = cw_units,
            .y1 = 0,
            .x2 = 0,
            .y2 = 1000,
        } };
        const i_root = gpv.V1Node{ .glyph = .{ .glyph_id = 0, .child = &i_lin } };
        const i_container = try gpv.colr1ContainerBytes(allocator, &.{cover}, i_root, &.{ 0xFF0000FF, 0x0000FFFF }, null);
        defer allocator.free(i_container);
        const apc_i = try v1_helpers.registerV1Apc(allocator, 0xF0104, i_container);
        defer allocator.free(apc_i);

        // Stage J: radial red centre → blue rim, centred in the cell.
        const j_cx: i16 = units.fromPx(@as(f32, @floatFromInt(cw)) / 2.0, u_per_px);
        const j_r: u16 = @intCast(units.fromPx(@as(f32, @floatFromInt(chh)) / 2.0, u_per_px));
        const j_rad = gpv.V1Node{ .radial = .{
            .stops = &i_stops,
            .x0 = j_cx,
            .y0 = ymid_units,
            .r0 = 0,
            .x1 = j_cx,
            .y1 = ymid_units,
            .r1 = j_r,
        } };
        const j_root = gpv.V1Node{ .glyph = .{ .glyph_id = 0, .child = &j_rad } };
        const j_container = try gpv.colr1ContainerBytes(allocator, &.{cover}, j_root, &.{ 0xFF0000FF, 0x0000FFFF }, null);
        defer allocator.free(j_container);
        const apc_j = try v1_helpers.registerV1Apc(allocator, 0xF0105, j_container);
        defer allocator.free(apc_j);

        // Stage K: PaintComposite PLUS of a green source over a red
        // backdrop — the overlap must be YELLOW (src-over would leave
        // pure green, so this asserts the operator actually applied).
        const k_red = gpv.V1Node{ .solid = .{ .palette = 0 } };
        const k_green = gpv.V1Node{ .solid = .{ .palette = 1 } };
        const k_back = gpv.V1Node{ .glyph = .{ .glyph_id = 0, .child = &k_red } };
        const k_src = gpv.V1Node{ .glyph = .{ .glyph_id = 0, .child = &k_green } };
        const k_root = gpv.V1Node{ .composite = .{ .source = &k_src, .mode = 12, .backdrop = &k_back } };
        const k_container = try gpv.colr1ContainerBytes(allocator, &.{cover}, k_root, &.{ 0xFF0000FF, 0x00FF00FF }, null);
        defer allocator.free(k_container);
        const apc_k = try v1_helpers.registerV1Apc(allocator, 0xF0106, k_container);
        defer allocator.free(apc_k);

        // Stage L: the 0xFFFF sentinel DEEP in a v1 graph (glyph →
        // solid) — two SGR foregrounds must yield two pixel colours.
        const l_solid = gpv.V1Node{ .solid = .{ .palette = gpv.PALETTE_FOREGROUND } };
        const l_root = gpv.V1Node{ .glyph = .{ .glyph_id = 0, .child = &l_solid } };
        const l_container = try gpv.colr1ContainerBytes(allocator, &.{cover}, l_root, &.{}, null);
        defer allocator.free(l_container);
        const apc_l = try v1_helpers.registerV1Apc(allocator, 0xF0107, l_container);
        defer allocator.free(apc_l);

        // Stage M: sweep gradient — cairo has no sweep shader, so the
        // documented degradation paints the FIRST stop (green) as a
        // solid. No red (second stop) may appear, and no garbage.
        const m_stops = [_]gpv.V1Stop{
            .{ .offset = 0.0, .palette = 1 }, // green
            .{ .offset = 1.0, .palette = 0 }, // red
        };
        const m_sweep = gpv.V1Node{ .sweep = .{ .stops = &m_stops, .cx = j_cx, .cy = ymid_units } };
        const m_root = gpv.V1Node{ .glyph = .{ .glyph_id = 0, .child = &m_sweep } };
        const m_container = try gpv.colr1ContainerBytes(allocator, &.{cover}, m_root, &.{ 0xFF0000FF, 0x00FF00FF }, null);
        defer allocator.free(m_container);
        const apc_m = try v1_helpers.registerV1Apc(allocator, 0xF0108, m_container);
        defer allocator.free(apc_m);

        // Register everything, lay the five rows out, render once.
        parser.advance(apc_i, Emit.cb, @ptrCast(&ec));
        parser.advance(apc_j, Emit.cb, @ptrCast(&ec));
        parser.advance(apc_k, Emit.cb, @ptrCast(&ec));
        parser.advance(apc_l, Emit.cb, @ptrCast(&ec));
        parser.advance(apc_m, Emit.cb, @ptrCast(&ec));
        parser.advance("\x1b[0m\x1b[2J\x1b[H\u{F0104}", Emit.cb, @ptrCast(&ec));
        parser.advance("\x1b[2;1H\u{F0105}", Emit.cb, @ptrCast(&ec));
        parser.advance("\x1b[3;1H\u{F0106}", Emit.cb, @ptrCast(&ec));
        parser.advance("\x1b[4;1H\x1b[38;2;255;0;0m\u{F0107}\x1b[4;3H\x1b[38;2;0;0;255m\u{F0107}\x1b[0m", Emit.cb, @ptrCast(&ec));
        parser.advance("\x1b[5;1H\u{F0108}", Emit.cb, @ptrCast(&ec));
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        try render(&cell_pass, screen, &pool, atlas.?, fb);

        // Stage I assertions: colour varies across the cell in +x.
        const i_y = padu + chh / 2;
        const i_left = colr_helpers.px(fb, padu + 1, i_y);
        const i_right = colr_helpers.px(fb, padu + cw - 2, i_y);
        std.debug.print("smoke-cell: colrv1 linear left=({d},{d},{d}) right=({d},{d},{d})\n", .{ i_left[0], i_left[1], i_left[2], i_right[0], i_right[1], i_right[2] });
        if (!(i_left[0] > 150 and i_left[0] > i_left[2] + 60)) {
            std.debug.print("smoke-cell: FAIL — colrv1 linear gradient left edge not red\n", .{});
            return 52;
        }
        if (!(i_right[2] > 130 and i_right[2] > i_right[0] + 60)) {
            std.debug.print("smoke-cell: FAIL — colrv1 linear gradient does not shift to blue rightward\n", .{});
            return 53;
        }

        // Stage J assertions: red centre, blue at the cell corner.
        const j_center = colr_helpers.px(fb, padu + cw / 2, padu + chh + chh / 2);
        const j_corner = colr_helpers.px(fb, padu + 1, padu + chh + 1);
        std.debug.print("smoke-cell: colrv1 radial center=({d},{d},{d}) corner=({d},{d},{d})\n", .{ j_center[0], j_center[1], j_center[2], j_corner[0], j_corner[1], j_corner[2] });
        if (!(j_center[0] > 150 and j_center[0] > j_center[2] + 60)) {
            std.debug.print("smoke-cell: FAIL — colrv1 radial centre not red\n", .{});
            return 54;
        }
        if (!(j_corner[2] > 130 and j_corner[2] > j_corner[0] + 60)) {
            std.debug.print("smoke-cell: FAIL — colrv1 radial rim not blue\n", .{});
            return 55;
        }

        // Stage K assertions: PLUS blend of red + green = yellow.
        const k_px = colr_helpers.px(fb, padu + cw / 2, padu + 2 * chh + chh / 2);
        std.debug.print("smoke-cell: colrv1 composite-plus center=({d},{d},{d})\n", .{ k_px[0], k_px[1], k_px[2] });
        if (!(k_px[0] > 150 and k_px[1] > 150 and k_px[2] < 100)) {
            std.debug.print("smoke-cell: FAIL — colrv1 PLUS composite did not blend (want yellow)\n", .{});
            return 56;
        }

        // Stage L assertions: per-foreground re-rasterisation.
        const l_y = padu + 3 * chh + chh / 2;
        const l_red = colr_helpers.px(fb, padu + cw / 2, l_y);
        const l_blue = colr_helpers.px(fb, padu + 2 * cw + cw / 2, l_y);
        std.debug.print("smoke-cell: colrv1 0xFFFF fg red-cell=({d},{d},{d}) blue-cell=({d},{d},{d})\n", .{ l_red[0], l_red[1], l_red[2], l_blue[0], l_blue[1], l_blue[2] });
        if (!(l_red[0] > 150 and l_red[2] < 100)) {
            std.debug.print("smoke-cell: FAIL — colrv1 0xFFFF solid did not take the red foreground\n", .{});
            return 57;
        }
        if (!(l_blue[2] > 150 and l_blue[0] < 100)) {
            std.debug.print("smoke-cell: FAIL — colrv1 0xFFFF glyph reused the first foreground's pixels\n", .{});
            return 58;
        }

        // Stage M assertions: sweep degrades to the first stop's
        // green — some green must land, zero red anywhere in the cell.
        const m_y0 = padu + 4 * chh;
        const m_greens = colr_helpers.countColor(fb, padu, m_y0, cw, chh, 1, 0, 2);
        const m_reds = colr_helpers.countColor(fb, padu, m_y0, cw, chh, 0, 1, 2);
        std.debug.print("smoke-cell: colrv1 sweep greens={d} reds={d}\n", .{ m_greens, m_reds });
        if (m_greens < 4 or m_reds != 0) {
            std.debug.print("smoke-cell: FAIL — sweep degradation wrong (want first-stop green solid)\n", .{});
            return 59;
        }
    }

    // ── Stage N: cursor trail draws, then cleans up ──────────
    //
    // The two halves are the whole point. "It draws" is easy; "the
    // pixels are gone once it settles" is the property that decides
    // whether the effect leaves smear behind on a real screen.
    {
        const cwf: f32 = @floatFromInt(atlas.?.cell_w);
        const chf: f32 = @floatFromInt(atlas.?.cell_h);
        const padf: f32 = grid_pass.pad;

        // Blank grid, cursor parked at home so nothing but the trail
        // can light up the middle of the viewport.
        parser.advance("\x1b[0m\x1b[2J\x1b[H", Emit.cb, @ptrCast(&ec));
        screen.hints_overlay = &.{};
        screen.cursor_shape = .block_steady;

        const from_x = padf;
        const from_y = padf;
        const to_col: f32 = 20;
        const to_row: f32 = 3;
        const to_x = padf + to_col * cwf;
        const to_y = padf + to_row * chf;

        var trail = CursorTrail.init(0.3);
        trail.setDestination(from_x, from_y, cwf, chf);
        _ = trail.advance(1.0 / 60.0, cwf, chf); // teleport home
        trail.setDestination(to_x, to_y, cwf, chf);
        const moving = trail.advance(1.0 / 60.0, cwf, chf);
        if (!moving) {
            std.debug.print("smoke-cell: FAIL — trail reported settled on the frame it jumped\n", .{});
            return 60;
        }

        const trail_render = struct {
            fn go(gp: *GridPass, sc: *Screen, pl: *StylePool, at: *Atlas, fbuf: []u8) !void {
                c.glViewport(0, 0, W, H);
                c.glClearColor(0.05, 0.05, 0.10, 1.0);
                c.glClear(c.GL_COLOR_BUFFER_BIT);
                try gp.buildVertices(sc, pl, at, true, true, &.{});
                gp.draw(at, W, H);
                c.glFinish();
                c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fbuf.ptr);
            }
        }.go;

        // Sample halfway between the old and new cursor centres —
        // a spot no cursor quad and no glyph can ever reach, so any
        // lit pixel there is the trail and nothing else. Readback
        // row 0 is the framebuffer BOTTOM, hence the flip.
        const mid_x: usize = @intFromFloat((from_x + to_x) * 0.5 + cwf * 0.5);
        const mid_y_top: usize = @intFromFloat((from_y + to_y) * 0.5 + chf * 0.5);
        const mid_y: usize = @as(usize, @intCast(H)) - 1 - mid_y_top;
        const probe = struct {
            fn lit(fbuf: []const u8, cx: usize, cy: usize) usize {
                var n: usize = 0;
                var dy: usize = 0;
                while (dy < 3) : (dy += 1) {
                    var dx: usize = 0;
                    while (dx < 3) : (dx += 1) {
                        const x = cx + dx - 1;
                        const y = cy + dy - 1;
                        const off = (y * @as(usize, @intCast(W)) + x) * 4;
                        // Background is (13,13,26); the trail is the
                        // near-white cursor colour at alpha 0.45.
                        if (fbuf[off] > 60 and fbuf[off + 1] > 60) n += 1;
                    }
                }
                return n;
            }
        }.lit;

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        grid_pass.trail_quad = trail.quad();
        try trail_render(&grid_pass, screen, &pool, atlas.?, fb);
        const lit_moving = probe(fb, mid_x, mid_y);
        std.debug.print("smoke-cell: cursor trail mid-flight lit={d} at ({d},{d})\n", .{ lit_moving, mid_x, mid_y_top });
        if (lit_moving != 9) {
            std.debug.print("smoke-cell: FAIL — no trail between the old and new cursor cell\n", .{});
            return 61;
        }

        // Run it to rest the way the pane's timer would, then publish
        // what the pane publishes on the settling frame: nothing.
        var frames: usize = 0;
        while (trail.advance(1.0 / 60.0, cwf, chf)) {
            frames += 1;
            if (frames > 240) {
                std.debug.print("smoke-cell: FAIL — trail never settled\n", .{});
                return 62;
            }
        }
        grid_pass.trail_quad = null;
        try trail_render(&grid_pass, screen, &pool, atlas.?, fb);
        const lit_settled = probe(fb, mid_x, mid_y);
        std.debug.print("smoke-cell: cursor trail settled after {d} frames, lit={d}\n", .{ frames, lit_settled });
        if (lit_settled != 0) {
            std.debug.print("smoke-cell: FAIL — trail pixels survived the settle\n", .{});
            return 63;
        }

        // And the cursor itself is still there: a trail that erased
        // the cursor along with itself would pass the check above.
        const cur_y_top: usize = @intFromFloat(padf + chf * 0.5);
        const cur_lit = probe(fb, @intFromFloat(padf + cwf * 0.5), @as(usize, @intCast(H)) - 1 - cur_y_top);
        if (cur_lit != 9) {
            std.debug.print("smoke-cell: FAIL — cursor quad missing after the trail settled\n", .{});
            return 64;
        }
    }

    // text_blending = native | linear | linear_corrected.
    {
        const rc = try blendModeStage(allocator);
        if (rc != 0) return rc;
    }

    // Curly underline: a real wave in BOTH shader pairs.
    {
        const rc = try curlyUnderlineStage(allocator);
        if (rc != 0) return rc;
    }

    std.debug.print("smoke-cell: PASS\n", .{});
    return 0;
}

// ---- text_blending -------------------------------------------------

const Blend = @import("render/blend.zig");

/// Render the SAME scene once per `text_blending` mode and prove the
/// change is confined to antialiased coverage.
///
/// The scene is deliberately red fg on green bg: complementary
/// colours are the case gamma-space blending wrecks (a half-covered
/// edge pixel collapses toward black), so it is the case `linear`
/// exists to fix.
///
/// Nothing here is compared against a golden dump. Instead the native
/// pass is used to RECOVER each edge pixel's coverage — native IS a
/// lerp in encoded space, so `a = (N - B) / (F - B)` is exact — and
/// the other two modes are then predicted analytically from that same
/// `a`. That makes the test non-circular: it would still fail if the
/// native path had silently changed, because the recovered coverage
/// would no longer predict anything consistent, and it pins the
/// linear maths to the sRGB curve rather than to whatever the shader
/// happens to compute.
fn blendModeStage(allocator: std.mem.Allocator) !u8 {
    const BW: c_int = 256;
    const BH: c_int = 64;

    var fbo: c_uint = 0;
    var rbo: c_uint = 0;
    c.glGenFramebuffers(1, &fbo);
    c.glGenRenderbuffers(1, &rbo);
    c.glBindRenderbuffer(c.GL_RENDERBUFFER, rbo);
    c.glRenderbufferStorage(c.GL_RENDERBUFFER, c.GL_RGBA8, BW, BH);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_RENDERBUFFER, rbo);
    defer {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glDeleteFramebuffers(1, &fbo);
        c.glDeleteRenderbuffers(1, &rbo);
    }
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("smoke-cell: blend FAIL — framebuffer incomplete\n", .{});
        return 70;
    }

    var atlas: ?*Atlas = null;
    for (FONT_CANDIDATES) |path| {
        if (Atlas.init(allocator, path, FONT_SIZE)) |a| {
            atlas = a;
            break;
        } else |_| continue;
    }
    if (atlas == null) {
        std.debug.print("smoke-cell: blend FAIL — no font\n", .{});
        return 71;
    }
    defer atlas.?.deinit();
    atlas.?.realize();

    var pool = try StylePool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, 24, 3);
    defer screen.deinit();

    var parser = @import("parser/vt.zig").Parser.init(allocator);
    defer parser.deinit();
    const Ctx = struct { screen: *Screen, allocator: std.mem.Allocator };
    const Emit = struct {
        fn cb(user: ?*anyopaque, ev: @import("parser/event.zig").Event) void {
            const ec: *Ctx = @ptrCast(@alignCast(user.?));
            var mut = ev;
            ec.screen.apply(ev);
            mut.deinit(ec.allocator);
        }
    };
    var ec = Ctx{ .screen = screen, .allocator = allocator };
    // Row 0: pure red on pure green, ASCII — CellPass.
    // Row 2: the same colours and the same glyphs, but the line is
    //        DECDWL (ESC # 6). `ln.scaling != .single` is what routes
    //        a row to the GridPass overlay, so this exercises the
    //        OTHER shader pair without depending on a CJK or emoji
    //        font being installed on the build host.
    parser.advance(
        "\x1b[38;2;255;0;0m\x1b[48;2;0;255;0mHHHHHHHHHH" ++
            // Full blocks alongside the letters: a 2x-scaled `H` stem
            // never reaches full coverage under the atlas's linear
            // filter, so without them the row has no interior pixels
            // to hold still.
            "\x1b[3;1H\x1b#6\x1b[38;2;255;0;0m\x1b[48;2;0;255;0mH█H█H█H█\x1b[0m",
        Emit.cb,
        @ptrCast(&ec),
    );

    var cell_pass = CellPass.init(allocator);
    defer cell_pass.deinit();
    try cell_pass.realize();
    var grid_pass = GridPass.init(allocator);
    defer grid_pass.deinit();
    try grid_pass.realize();
    grid_pass.canvas_w = @floatFromInt(BW);
    grid_pass.canvas_h = @floatFromInt(BH);

    var target: Blend.LinearTarget = .{};
    defer target.releaseGL();

    const px_count: usize = @intCast(BW * BH);
    var shots: [3][]u8 = undefined;
    for (&shots) |*s| s.* = try allocator.alloc(u8, px_count * 4);
    defer for (shots) |s| allocator.free(s);

    const modes = [3]Blend.Mode{ .native, .linear, .linear_corrected };
    for (modes, 0..) |mode, mi| {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        const on = target.begin(mode, BW, BH);
        if (mode != .native and !on) {
            std.debug.print("smoke-cell: blend FAIL — sRGB target unavailable for {s}\n", .{@tagName(mode)});
            return 72;
        }
        const eff: Blend.Mode = if (on) mode else .native;
        cell_pass.blend_mode = eff;
        grid_pass.blend_mode = eff;
        c.glViewport(0, 0, BW, BH);
        // Black clear, so a background pixel is unambiguously "no cell
        // drew here" and the cell bg quads are what carry the green.
        const clear = Blend.clearColor(eff, .{ 0, 0, 0, 1 });
        c.glClearColor(clear[0], clear[1], clear[2], clear[3]);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        cell_pass.markAllDirty();
        try cell_pass.rebuildAndUpload(screen, &pool, atlas.?);
        cell_pass.draw(atlas.?, BW, BH);
        grid_pass.vbuf_valid = false;
        try grid_pass.buildVertices(screen, &pool, atlas.?, false, true, &.{});
        grid_pass.draw(atlas.?, BW, BH);
        if (on) target.finish(BW, BH);
        c.glFinish();
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        c.glReadPixels(0, 0, BW, BH, c.GL_RGBA, c.GL_UNSIGNED_BYTE, shots[mi].ptr);
    }

    // Cell geometry: row 0 is the CellPass row, row 2 the GridPass one.
    // glReadPixels is bottom-up, so a screen row r maps to scanlines
    // [BH - (pad + (r+1)*ch), BH - (pad + r*ch)).
    const ch: usize = atlas.?.cell_h;
    const pad: usize = @intFromFloat(grid_pass.pad);
    const hu: usize = @intCast(BH);
    const wu: usize = @intCast(BW);

    const Row = struct { name: []const u8, y_lo: usize, y_hi: usize };
    const rows = [2]Row{
        .{ .name = "CellPass(ASCII)", .y_lo = hu -| (pad + ch), .y_hi = hu -| pad },
        .{ .name = "GridPass(DECDWL)", .y_lo = hu -| (pad + 3 * ch), .y_hi = hu -| (pad + 2 * ch) },
    };

    var failures: u8 = 0;
    for (rows) |row| {
        var n_edge: usize = 0;
        var n_interior: usize = 0;
        var n_bg: usize = 0;
        var interior_moved: usize = 0;
        var bg_moved: usize = 0;
        var edge_moved_linear: usize = 0;
        var edge_moved_corrected: usize = 0;
        var edge_lighter: usize = 0;
        var edge_darker: usize = 0;
        var native_drifted: usize = 0;
        // Worst analytic mismatch across every edge pixel, in 8-bit
        // levels, for each of the two linear modes.
        var worst_lin: f32 = 0;
        var worst_cor: f32 = 0;

        var y = row.y_lo;
        while (y < row.y_hi) : (y += 1) {
            var x: usize = pad;
            while (x < wu - pad) : (x += 1) {
                const o = (y * wu + x) * 4;
                const nr: i32 = shots[0][o + 0];
                const ng: i32 = shots[0][o + 1];
                const nb: i32 = shots[0][o + 2];
                // Green cell bg with red text: R rises and G falls
                // together with coverage, B stays 0 throughout.
                if (nb != 0) continue;
                if (nr == 0 and ng == 0) continue; // outside the cell run
                const is_bg = (nr == 0 and ng == 255);
                const is_fg = (nr == 255 and ng == 0);
                const is_edge = !is_bg and !is_fg and nr > 4 and nr < 251;

                if (is_bg or is_fg) {
                    // Fully-covered and fully-uncovered pixels must not
                    // move: that is what proves the modes only touch
                    // partial coverage. One 8-bit level of slack for the
                    // sRGB texture round trip through the resolve.
                    if (is_bg) n_bg += 1 else n_interior += 1;
                    for (1..3) |m| {
                        var ch_i: usize = 0;
                        while (ch_i < 3) : (ch_i += 1) {
                            const d = @abs(@as(i32, shots[m][o + ch_i]) - @as(i32, shots[0][o + ch_i]));
                            if (d > 1) {
                                if (is_bg) bg_moved += 1 else interior_moved += 1;
                            }
                        }
                    }
                    continue;
                }
                if (!is_edge) continue;
                n_edge += 1;

                // Recover coverage from native: native = fg*a + bg*(1-a)
                // in ENCODED space, fg.r = 1, bg.r = 0 -> a = nr/255.
                const a: f32 = @as(f32, @floatFromInt(nr)) / 255.0;
                const fg = [3]f32{ 1, 0, 0 };
                const bg = [3]f32{ 0, 1, 0 };
                // ...and cross-check it against the OTHER channel. If
                // `native` had stopped being a plain lerp in encoded
                // space — i.e. if the default had drifted — green would
                // no longer be 255*(1-a).
                if (@abs(255.0 * (1.0 - a) - @as(f32, @floatFromInt(ng))) > 1.5) native_drifted += 1;

                // Predicted `linear`: lerp in linear light, re-encoded.
                var want_lin: [3]f32 = undefined;
                for (0..3) |k| {
                    const l = Blend.linearize(fg[k]) * a + Blend.linearize(bg[k]) * (1 - a);
                    want_lin[k] = Blend.unlinearize(l);
                }
                // Predicted `linear_corrected`: same, with the remapped
                // coverage.
                const a2 = Blend.correctCoverage(a, fg, bg);
                var want_cor: [3]f32 = undefined;
                for (0..3) |k| {
                    const l = Blend.linearize(fg[k]) * a2 + Blend.linearize(bg[k]) * (1 - a2);
                    want_cor[k] = Blend.unlinearize(l);
                }
                for (0..3) |k| {
                    const got_l: f32 = @floatFromInt(shots[1][o + k]);
                    const got_c: f32 = @floatFromInt(shots[2][o + k]);
                    worst_lin = @max(worst_lin, @abs(got_l - want_lin[k] * 255.0));
                    worst_cor = @max(worst_cor, @abs(got_c - want_cor[k] * 255.0));
                }

                var moved_l = false;
                var moved_c = false;
                for (0..3) |k| {
                    if (@abs(@as(i32, shots[1][o + k]) - @as(i32, shots[0][o + k])) > 2) moved_l = true;
                    if (@abs(@as(i32, shots[2][o + k]) - @as(i32, shots[0][o + k])) > 2) moved_c = true;
                }
                if (moved_l) edge_moved_linear += 1;
                if (moved_c) edge_moved_corrected += 1;

                // The artifact itself: red-on-green in gamma space
                // collapses the edge toward black. `linear` must give
                // that pixel MORE light.
                const lum_n = 0.2126 * Blend.linearize(@as(f32, @floatFromInt(nr)) / 255.0) +
                    0.7152 * Blend.linearize(@as(f32, @floatFromInt(ng)) / 255.0);
                const lum_l = 0.2126 * Blend.linearize(@as(f32, @floatFromInt(shots[1][o + 0])) / 255.0) +
                    0.7152 * Blend.linearize(@as(f32, @floatFromInt(shots[1][o + 1])) / 255.0);
                if (lum_l > lum_n + 0.002) edge_lighter += 1;
                if (lum_l < lum_n - 0.002) edge_darker += 1;
            }
        }

        std.debug.print(
            "smoke-cell: blend {s} edge={d} interior={d} bg={d} moved(lin/cor)={d}/{d} lighter={d} darker={d} native_drift={d} maxerr(lin/cor)={d:.2}/{d:.2}\n",
            .{ row.name, n_edge, n_interior, n_bg, edge_moved_linear, edge_moved_corrected, edge_lighter, edge_darker, native_drifted, worst_lin, worst_cor },
        );

        if (native_drifted != 0) {
            std.debug.print("smoke-cell: blend FAIL — {s} native is no longer a plain gamma-space lerp ({d} px)\n", .{ row.name, native_drifted });
            failures += 1;
        }

        if (n_edge < 5 or n_interior < 5 or n_bg < 5) {
            std.debug.print("smoke-cell: blend FAIL — {s} did not produce enough classified pixels\n", .{row.name});
            failures += 1;
            continue;
        }
        if (interior_moved != 0 or bg_moved != 0) {
            std.debug.print("smoke-cell: blend FAIL — {s} moved fully-covered ({d}) or background ({d}) pixels\n", .{ row.name, interior_moved, bg_moved });
            failures += 1;
        }
        if (edge_moved_linear == 0) {
            std.debug.print("smoke-cell: blend FAIL — {s} linear is indistinguishable from native at glyph edges\n", .{row.name});
            failures += 1;
        }
        if (edge_moved_corrected == 0) {
            std.debug.print("smoke-cell: blend FAIL — {s} linear_corrected is indistinguishable from native at glyph edges\n", .{row.name});
            failures += 1;
        }
        if (edge_lighter == 0 or edge_darker != 0) {
            std.debug.print("smoke-cell: blend FAIL — {s} red-on-green edges did not get lighter under linear\n", .{row.name});
            failures += 1;
        }
        // 3 levels of 255 covers the sRGB round trip plus the shader's
        // float pow; anything larger means the maths, not the encoding.
        if (worst_lin > 3.0 or worst_cor > 3.0) {
            std.debug.print("smoke-cell: blend FAIL — {s} pixels do not match the analytic prediction\n", .{row.name});
            failures += 1;
        }
    }

    if (failures != 0) return 73;
    return 0;
}

// ---- curly underline ----------------------------------------------

/// Undercurl parity between the two shader pairs. Row 0 is ASCII, so
/// CellPass draws it in-shader; row 2 is Hebrew, which routes the row
/// to the GridPass overlay. Both carry `SGR 4:3` with an explicit red
/// decoration colour (SGR 58), so the wave can be isolated from the
/// white glyph pixels by colour alone.
///
/// The assertions are that each row's strip carries a wave at all (the
/// per-column centre of mass has to move, which a straight line cannot
/// do) and that the two rows' waves agree column by column.
fn curlyUnderlineStage(allocator: std.mem.Allocator) !u8 {
    const BW: c_int = 256;
    const BH: c_int = 64;

    var fbo: c_uint = 0;
    var rbo: c_uint = 0;
    c.glGenFramebuffers(1, &fbo);
    c.glGenRenderbuffers(1, &rbo);
    c.glBindRenderbuffer(c.GL_RENDERBUFFER, rbo);
    c.glRenderbufferStorage(c.GL_RENDERBUFFER, c.GL_RGBA8, BW, BH);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_RENDERBUFFER, rbo);
    defer {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glDeleteFramebuffers(1, &fbo);
        c.glDeleteRenderbuffers(1, &rbo);
    }
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("smoke-cell: curly FAIL - framebuffer incomplete\n", .{});
        return 80;
    }

    var atlas: ?*Atlas = null;
    for (FONT_CANDIDATES) |path| {
        if (Atlas.init(allocator, path, FONT_SIZE)) |a| {
            atlas = a;
            break;
        } else |_| continue;
    }
    if (atlas == null) {
        std.debug.print("smoke-cell: curly FAIL - no font\n", .{});
        return 81;
    }
    defer atlas.?.deinit();
    atlas.?.realize();

    var pool = try StylePool.init(allocator);
    defer pool.deinit();
    const cols: usize = 12;
    const screen = try Screen.init(allocator, &pool, @intCast(cols), 3);
    defer screen.deinit();

    var parser = @import("parser/vt.zig").Parser.init(allocator);
    defer parser.deinit();
    const Ctx = struct { screen: *Screen, allocator: std.mem.Allocator };
    const Emit = struct {
        fn cb(user: ?*anyopaque, ev: @import("parser/event.zig").Event) void {
            const ec: *Ctx = @ptrCast(@alignCast(user.?));
            var mut = ev;
            ec.screen.apply(ev);
            mut.deinit(ec.allocator);
        }
    };
    var ec = Ctx{ .screen = screen, .allocator = allocator };
    const deco = "\x1b[4:3m\x1b[58;2;255;0;0m";
    parser.advance(
        deco ++ "xxxxxxxxxxxx" ++
            "\x1b[3;1H" ++ deco ++ "\u{05D0}\u{05D0}\u{05D0}\u{05D0}\u{05D0}\u{05D0}" ++
            "\u{05D0}\u{05D0}\u{05D0}\u{05D0}\u{05D0}\u{05D0}\x1b[0m",
        Emit.cb,
        @ptrCast(&ec),
    );

    var cell_pass = CellPass.init(allocator);
    defer cell_pass.deinit();
    try cell_pass.realize();
    var grid_pass = GridPass.init(allocator);
    defer grid_pass.deinit();
    try grid_pass.realize();
    grid_pass.canvas_w = @floatFromInt(BW);
    grid_pass.canvas_h = @floatFromInt(BH);

    c.glViewport(0, 0, BW, BH);
    c.glClearColor(0.0, 0.0, 0.0, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    cell_pass.markAllDirty();
    try cell_pass.rebuildAndUpload(screen, &pool, atlas.?);
    cell_pass.draw(atlas.?, BW, BH);
    grid_pass.vbuf_valid = false;
    try grid_pass.buildVertices(screen, &pool, atlas.?, false, true, &.{});
    grid_pass.draw(atlas.?, BW, BH);
    c.glFinish();

    const wu: usize = @intCast(BW);
    const hu: usize = @intCast(BH);
    const fb = try allocator.alloc(u8, wu * hu * 4);
    defer allocator.free(fb);
    c.glReadPixels(0, 0, BW, BH, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);

    const ch: usize = atlas.?.cell_h;
    const cw: usize = atlas.?.cell_w;
    const pad: usize = @intFromFloat(grid_pass.pad);
    const strip_h: usize = @intFromFloat(@import("render/style.zig").curlyStripHeight(@floatFromInt(ch)));

    // Per-column centre of mass of the red decoration pixels inside a
    // row's strip, in top-down pixels relative to the strip's top.
    // NaN marks a column the wave does not reach.
    const profile = struct {
        fn go(buf: []const u8, w: usize, h: usize, top: usize, sh: usize, x0: usize, n: usize, out: []f32) void {
            for (0..n) |i| {
                var sum: f32 = 0;
                var weight: f32 = 0;
                for (0..sh) |dy| {
                    const y_td = top + dy;
                    if (y_td >= h) continue;
                    const y = h - 1 - y_td; // glReadPixels is bottom-up
                    const o = (y * w + x0 + i) * 4;
                    const r: f32 = @floatFromInt(buf[o + 0]);
                    const g: f32 = @floatFromInt(buf[o + 1]);
                    const b: f32 = @floatFromInt(buf[o + 2]);
                    // Decoration red; glyphs are white, bg is black.
                    if (r < 40.0 or g > r * 0.5 or b > r * 0.5) continue;
                    sum += r * @as(f32, @floatFromInt(dy));
                    weight += r;
                }
                out[i] = if (weight > 0) sum / weight else std.math.nan(f32);
            }
        }
    }.go;

    const span = cols * cw;
    const cell_profile = try allocator.alloc(f32, span);
    defer allocator.free(cell_profile);
    const grid_profile = try allocator.alloc(f32, span);
    defer allocator.free(grid_profile);
    profile(fb, wu, hu, pad + ch - strip_h, strip_h, pad, span, cell_profile);
    profile(fb, wu, hu, pad + 3 * ch - strip_h, strip_h, pad, span, grid_profile);

    var failures: u8 = 0;
    const rows = [2]struct { name: []const u8, prof: []const f32 }{
        .{ .name = "CellPass", .prof = cell_profile },
        .{ .name = "GridPass", .prof = grid_profile },
    };
    for (rows) |row| {
        var lo: f32 = std.math.floatMax(f32);
        var hi: f32 = -std.math.floatMax(f32);
        var lit: usize = 0;
        for (row.prof) |v| {
            if (std.math.isNan(v)) continue;
            lit += 1;
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        if (lit * 4 < span * 3) {
            std.debug.print("smoke-cell: curly FAIL - {s} drew the wave in only {d}/{d} columns\n", .{ row.name, lit, span });
            failures += 1;
            continue;
        }
        // A straight line (the old GridPass behaviour) has a constant
        // centre of mass; the wave's amplitude is 0.45 of the strip.
        if (hi - lo < @as(f32, @floatFromInt(strip_h)) * 0.4) {
            std.debug.print("smoke-cell: curly FAIL - {s} strip is flat (peak-to-peak {d:.2}px of {d}px strip)\n", .{ row.name, hi - lo, strip_h });
            failures += 1;
        }
    }

    // Column-by-column agreement: both passes must draw the same wave
    // at the same phase, or a row that straddles them shows a seam.
    var worst: f32 = 0;
    var compared: usize = 0;
    for (cell_profile, grid_profile) |a, b| {
        if (std.math.isNan(a) or std.math.isNan(b)) continue;
        compared += 1;
        worst = @max(worst, @abs(a - b));
    }
    if (compared * 4 < span * 3) {
        std.debug.print("smoke-cell: curly FAIL - only {d}/{d} columns comparable\n", .{ compared, span });
        failures += 1;
    } else if (worst > 1.0) {
        std.debug.print("smoke-cell: curly FAIL - passes disagree by {d:.2}px at worst\n", .{worst});
        failures += 1;
    }

    if (failures != 0) return 82;
    std.debug.print("smoke-cell: curly underline matches across CellPass/GridPass (worst {d:.2}px)\n", .{worst});
    return 0;
}
