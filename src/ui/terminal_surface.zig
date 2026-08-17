//! TerminalSurface — the terminal RENDERER half of a pane.
//!
//! Owns the GtkGLArea and its realize/unrealize/re-realize lifecycle,
//! every render pass (grid/cell/image/bg/shader + the linear-light
//! blend target), the ImageStore, the Atlas *reference* (the Atlas
//! itself is window-shared), and the visual timers that exist purely
//! to redraw the surface (cursor blink, cursor trail, bell fade,
//! kitty animation, shader animation).
//!
//! It deliberately knows nothing about input, menus, faces, split
//! trees or Window sinks — that is `Pane`, which composes one of
//! these. A cast-playback viewer can render a terminal by composing a
//! TerminalSurface without inheriting any of Pane's interaction
//! machinery. The few things the render half must tell its host
//! (child exit noticed by the tick, an imminent dirty redraw, a grid
//! geometry change) go out through the nullable host hooks.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Atlas = @import("../render/atlas.zig").Atlas;
const GridPass = @import("../render/grid_pass.zig").GridPass;
const CellPass = @import("../render/cell_pass.zig").CellPass;
const ImagePass = @import("../render/image_pass.zig").ImagePass;
const BgPass = @import("../render/bg_pass.zig").BgPass;
const blend_mod = @import("../render/blend.zig");
const ShaderPass = @import("../render/shader_pass.zig").ShaderPass;
const ShaderSource = @import("../render/shader_pass.zig").Source;
const ShaderParamKV = @import("../render/shader_pass.zig").ParamKV;
const CursorTrail = @import("../render/cursor_trail.zig").Trail;
const gl_mod = @import("../render/gl.zig");
const scrollbar = @import("../render/scrollbar.zig");
const ImageStore = @import("../grid/image_store.zig").Store;
const Screen = @import("../grid/screen.zig").Screen;
const Terminal = @import("../terminal.zig").Terminal;
const termsource = @import("../a11y/termsource.zig");

pub const FONT_CANDIDATES = if (@import("../util/platform.zig").is_macos) [_][*:0]const u8{
    // System fonts every macOS install ships. Menlo is a .ttc
    // collection — FreeType opens face index 0 (Menlo-Regular).
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Monaco.ttf",
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Supplemental/Courier New.ttf",
} else [_][*:0]const u8{
    "/usr/share/fonts/TTF/Hack-Regular.ttf",
    "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/TTF/VeraMono.ttf",
    "/usr/share/fonts/gnu-free/FreeMono.otf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
};

pub fn loadShaderFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const max_size = 256 * 1024;
    var path_z: [4096]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fp = c.fopen(@ptrCast(&path_z), "rb") orelse return null;
    defer _ = c.fclose(fp);
    const scratch = allocator.alloc(u8, max_size + 1) catch return null;
    defer allocator.free(scratch);
    const n = c.fread(scratch.ptr, 1, scratch.len, fp);
    if (n == 0 or n > max_size or c.ferror(fp) != 0) return null;
    return allocator.dupe(u8, scratch[0..n]) catch null;
}

pub const TerminalSurface = struct {
    /// Presentation-geometry policy. `live_terminal` is the pane
    /// behaviour: the widget allocation drives the cell grid (the
    /// resize handler resizes the Screen, tells the session via
    /// `Terminal.requestResize`, and reports COUNT changes through
    /// `on_grid_geometry`). `fixed_grid` renders a fixed cols x rows
    /// grid letterboxed/scaled into the allocation and never
    /// propagates geometry anywhere — for playback viewers whose
    /// grid is dictated by a recording, not by the window. Input
    /// pixel-to-cell mapping (`cellAt`) is live-grid math; a
    /// fixed-grid host that wants hit-testing must undo the
    /// letterbox transform itself.
    pub const Geometry = union(enum) {
        live_terminal,
        fixed_grid: struct { cols: u16, rows: u16 },
    };

    area: *c.GtkGLArea,
    /// The rendered session. Referenced, not owned: the host decides
    /// the terminal's lifetime; the surface only reads its Screen /
    /// StylePool and (in live_terminal mode) requests resizes on it.
    terminal: *Terminal,
    atlas: ?*Atlas = null,
    grid_pass: GridPass,
    cell_pass: CellPass,
    image_pass: ImagePass = ImagePass.init(),
    bg_pass: BgPass = .{},
    shader_pass: ShaderPass = .{},
    /// sRGB offscreen detour for `text_blending = linear |
    /// linear_corrected`. Inert (no FBO, no pass) under `native`.
    linear_target: blend_mod.LinearTarget = .{},
    /// Configured `text_blending`. Kept on the surface rather than on
    /// a pass because a frame can fall back to `native` (sRGB target
    /// unavailable) and must not clobber the configured value.
    text_blending: blend_mod.Mode = .native,
    /// iTime epoch for the custom shader (monotonic µs; 0 = unset).
    shader_epoch_us: i64 = 0,
    /// Window-level shader source (the config-global one). The
    /// surface falls back to this when it has no own shader. Set by
    /// applyPaneConfig.
    shader_default_source: ?*const ShaderSource = null,
    /// Surface-owned shader (profile override or explicit user pick)
    /// — wins over the window default. `shader_own_src` backs
    /// `shader_own.src`; `custom_shader_path` is kept for change
    /// detection + layout persistence. All surface-allocator-owned.
    shader_own: ShaderSource = .{},
    shader_own_src: ?[]u8 = null,
    shader_own_dir: ?[]u8 = null,
    custom_shader_path: ?[]u8 = null,
    /// True when the user picked the shader explicitly (context
    /// menu / palette / restored layout) — config reloads and
    /// profile pushes then leave it alone.
    custom_shader_user: bool = false,
    /// Shader preset applied to this surface (see shader_preset.zig):
    /// the preset's param values live in `preset_params` (names
    /// owned) and `shader_own.overrides` points at them instead of
    /// the global config slice — making params per-pane while a
    /// preset is active. Both cleared by dropShaderPreset.
    preset_name: ?[]u8 = null,
    preset_params: std.ArrayList(ShaderParamKV) = .empty,
    /// True when the user explicitly cleared this surface's shader.
    /// Distinct from "no pick" (which inherits profile/global): a
    /// cleared surface shows NO shader and, like a user pick, is
    /// sticky across config reloads and profile pushes.
    shader_cleared: bool = false,
    image_store: ImageStore,
    allocator: std.mem.Allocator,
    /// GTK tick callback id (0 = not registered). The tick pumps at
    /// frame rate, so it is reserved for genuinely per-frame work
    /// (shader animation, kitty image animation) and self-removes
    /// when none is active. Slow timers (cursor blink, bell fade)
    /// run on GLib timeouts instead: an installed tick callback
    /// forces GDK's frame clock to cycle at monitor refresh even
    /// when nothing is drawn, and on Wayland each of those empty
    /// cycles requests frame callbacks on every offload subsurface
    /// (observed leaking one object id per tick per subsurface on
    /// KWin until the 0xf00000 id-space cap crashed the process).
    tick_id: c_uint = 0,
    /// GLib timeout id driving cursor blink (0 = not running). Armed
    /// while the surface is focused with a blinking cursor shape;
    /// self-removes otherwise.
    blink_timer: c_uint = 0,
    /// GLib timeout id driving the 200 ms bell-flash fade (0 = not
    /// running). One-shot burst per bell.
    bell_timer: c_uint = 0,
    /// Cursor-trail animation state (see render/cursor_trail.zig).
    /// GUI-side only: nothing about it reaches Screen or the daemon.
    cursor_trail: CursorTrail = .{},
    /// Config: whether the trail runs at all.
    cursor_trail_on: bool = false,
    /// GLib timeout id driving the trail at ~60 fps (0 = not
    /// running). Like the bell fade this is a short self-terminating
    /// burst on a timeout, NOT the frame-clock tick — see `tick_id`.
    /// It stops itself the frame the trail settles, after one last
    /// render that erases it.
    trail_timer: c_uint = 0,
    /// Monotonic microseconds at the previous trail integration, for
    /// the variable dt the springs want. 0 = no previous frame.
    trail_last_us: i64 = 0,
    /// `screen.viewport_epoch` as of the last trail update; a change
    /// means the grid was replaced under the cursor (clear, alt
    /// screen, resize, reattach) and the trail teleports.
    trail_epoch: u32 = 0,
    /// Whether the trail was allowed to draw on the previous frame.
    /// Regaining eligibility teleports rather than smearing from
    /// wherever the cursor was when it went away.
    trail_eligible: bool = false,
    /// Live font size in points. Initialised from Config.font_size,
    /// adjustable via Ctrl++ / Ctrl+- which rebuilds the atlas.
    font_size: u16 = 14,
    /// Optional explicit font path (overrides FONT_CANDIDATES). Owned
    /// by the Config arena, valid for the lifetime of the Window.
    font_path: ?[]const u8 = null,
    /// Optional font family name resolved via fontconfig. Used when
    /// `font_path` is unset (or fails to load). Owned by the Config
    /// arena like `font_path`.
    font_family: ?[]const u8 = null,
    /// OpenType feature spec for shaping. Owned by the Config arena
    /// like `font_family`; applied to every atlas this surface
    /// creates.
    font_features: ?[]const u8 = null,
    /// Per-style families, weights and symbol maps. All borrowed from
    /// the Config arena, and re-pointed by `applyPaneConfig` on every
    /// config change, like the rest of the font settings.
    font_opts: Atlas.Options = .{},
    /// Cursor blink half-cycle interval in microseconds. 500_000
    /// (= 500 ms) is the xterm default.
    cursor_blink_us: i64 = 500_000,
    /// Extra pixels added to cell_h for visual line spacing (passed
    /// to Atlas.initOpts). 0 = font default.
    line_pad_px: i16 = 0,
    /// Inactive-pane dimming. When `is_focused` is false, the FINAL
    /// composited surface is uniformly darkened (`inactive_darken`)
    /// and optionally desaturated (`inactive_desaturate`) by a post-
    /// process step — preserving every fg/bg colour relationship,
    /// unlike a per-cell multiply. 0/0 = no dim.
    is_focused: bool = false,
    inactive_darken: f32 = 0.2,
    inactive_desaturate: f32 = 0.0,
    /// Presentation geometry — see `Geometry`. Panes always run
    /// `live_terminal`.
    geometry: Geometry = .live_terminal,

    // ── host hooks ───────────────────────────────────────────────
    // The render half occasionally has to tell whoever owns the
    // session something it noticed. All nullable; a bare surface
    // (playback viewer) leaves them unset.
    host_ctx: ?*anyopaque = null,
    /// The tick found `screen.child_exited` set. Fired once per exit;
    /// the tick self-removed BEFORE this fires, so the host may tear
    /// the surface (and itself) down from inside the callback.
    on_child_exit: ?*const fn (ctx: ?*anyopaque, status: i32) void = null,
    /// A dirty redraw is about to be queued from the tick — the hook
    /// where the pane repositions the IME candidate popup.
    on_before_redraw: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The widget allocation changed the grid's column/row COUNT
    /// (live_terminal only). Never fired by fixed_grid.
    on_grid_geometry: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Continuous shader/kitty playback started or stopped. A GTK frame
    /// clock tick affects every offload subsurface in the toplevel, so
    /// the host must apply this as a window-wide presentation policy.
    on_continuous_frames: ?*const fn (ctx: ?*anyopaque) void = null,
    continuous_frames_reported: bool = false,
    /// Defers the inactive report until after GTK has removed the tick
    /// callback that returned G_SOURCE_REMOVE.
    continuous_release_idle: c_uint = 0,

    /// Construct the surface in place (its address is baked into GTK
    /// signal user-data, so it must already live at its final,
    /// heap-stable location — e.g. embedded in a heap-allocated
    /// Pane).
    pub fn initInPlace(self: *TerminalSurface, allocator: std.mem.Allocator, terminal: *Terminal) void {
        // A SketermTermArea (GtkGLArea subclass) so the surface
        // exposes its text + caret to AT-SPI / Orca via
        // GtkAccessibleText; otherwise a bare GL area is an opaque
        // box to a screen reader.
        const area_widget = termsource.newArea(terminal);
        gl_mod.requestArea(@ptrCast(area_widget));
        // auto_render=FALSE → GtkGLArea only invokes the render
        // signal on demand (queue_draw / queue_render). With TRUE,
        // GTK pumps a full GL frame at the display refresh rate
        // (60 Hz on most setups, 120/144 on high-refresh) regardless
        // of whether any cell changed — that's a hot CPU loop on
        // battery for an idle terminal. We schedule explicit
        // queue_draw via onTick + drain when content actually
        // changes, so giving up auto-render costs nothing.
        c.gtk_gl_area_set_auto_render(@ptrCast(area_widget), 0);
        c.gtk_widget_set_vexpand(area_widget, 1);
        c.gtk_widget_set_hexpand(area_widget, 1);
        c.gtk_widget_set_visible(area_widget, 1);

        self.* = .{
            .area = @ptrCast(area_widget),
            .terminal = terminal,
            .grid_pass = GridPass.init(allocator),
            .cell_pass = CellPass.init(allocator),
            .image_store = ImageStore.init(allocator),
            .allocator = allocator,
        };

        // GL lifecycle. These signals carry a raw *TerminalSurface:
        // the surface is embedded in its host's heap allocation,
        // whose free is deferred past the widget tree's destruction
        // (the host owns that ordering) — the same lifetime contract
        // the pre-split Pane had for these connections.
        _ = c.g_signal_connect_data(
            area_widget,
            "realize",
            @ptrCast(&onRealize),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        // unrealize fires while the GL context is STILL CURRENT —
        // last chance to glDelete owned resources. Without it the
        // surface's program / VAOs / VBOs / textures leak into the
        // window's shared context for as long as the window lives.
        _ = c.g_signal_connect_data(
            area_widget,
            "unrealize",
            @ptrCast(&onUnrealize),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            area_widget,
            "render",
            @ptrCast(&onRender),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        // Resize → grid geometry (live_terminal: TIOCSWINSZ →
        // SIGWINCH child, via Terminal.requestResize).
        _ = c.g_signal_connect_data(
            area_widget,
            "resize",
            @ptrCast(&onResize),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        // Becoming visible again (tab switched back) must restart the
        // tick: an animating shader self-removes it while unmapped,
        // so nothing else would resume the animation.
        _ = c.g_signal_connect_data(area_widget, "map", @ptrCast(&onAreaMap), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(area_widget, "unmap", @ptrCast(&onAreaUnmap), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Tick is installed on demand via ensureTickRunning. It
        // self-removes when no time-driven work is active. First
        // install happens here so the cold-start cursor settles in
        // and any early animation events are picked up.
        self.ensureTickRunning();
    }

    /// Free everything the surface owns. GLib timeouts hold a raw
    /// *TerminalSurface — the host must guarantee this runs before
    /// the surface's memory is freed. (The frame-clock tick is
    /// widget-owned and dies with the GtkGLArea; the g_timeout
    /// sources are not.)
    pub fn deinit(self: *TerminalSurface) void {
        self.stopVisualSources();
        self.grid_pass.deinit();
        self.cell_pass.deinit();
        self.image_pass.deinit();
        self.image_store.deinit();
        if (self.shader_own_src) |s| self.allocator.free(s);
        if (self.shader_own_dir) |d| self.allocator.free(d);
        if (self.custom_shader_path) |s| self.allocator.free(s);
        self.freePresetData();
        self.preset_params.deinit(self.allocator);
        if (self.atlas) |a| a.deinit();
        self.atlas = null;
    }

    /// Remove every GLib timeout that redraws this surface (cursor
    /// blink, cursor trail, bell fade). Idempotent; the single
    /// teardown point for all visual sources holding a raw
    /// *TerminalSurface.
    pub fn stopVisualSources(self: *TerminalSurface) void {
        self.stopTick();
        self.stopBlinkTimer();
        self.stopTrailTimer();
        if (self.bell_timer != 0) {
            _ = c.g_source_remove(self.bell_timer);
            self.bell_timer = 0;
        }
    }

    /// The surface's widget (the GtkGLArea).
    pub fn widget(self: *TerminalSurface) *c.GtkWidget {
        return @ptrCast(self.area);
    }

    /// Schedule a GL frame.
    pub fn queueRender(self: *TerminalSurface) void {
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Focus state drives the cursor style, focus border and the
    /// inactive-dim post-process. The host queues the redraw.
    pub fn setFocused(self: *TerminalSurface, focused: bool) void {
        self.is_focused = focused;
        self.applyDim();
    }

    /// Push the current focus / dim settings into the renderer.
    /// Called on focus change AND when dim factors change via prefs.
    /// The dim is a uniform post-process (shader_pass), not a
    /// per-cell multiply — so the cell/grid dim uniforms stay
    /// neutral.
    pub fn applyDim(self: *TerminalSurface) void {
        self.cell_pass.dim_fg = 1.0;
        self.cell_pass.dim_bg = 1.0;
        self.grid_pass.dim_fg = 1.0;
        self.grid_pass.dim_bg = 1.0;
        if (self.is_focused) {
            self.shader_pass.dim_darken = 0;
            self.shader_pass.dim_desat = 0;
        } else {
            self.shader_pass.dim_darken = self.inactive_darken;
            self.shader_pass.dim_desat = self.inactive_desaturate;
        }
        // Callers (focus handlers, config-change loop) queue the
        // redraw — applyDim runs during early setup too, when
        // self.area isn't a realizable GL area yet.
    }

    /// After ANY atlas rebuild/swap: every glyph UV cached in the
    /// passes points into the dead texture, and the fresh atlas
    /// restarts at generation 0 — same as the passes' last-seen
    /// generations — so eviction detection won't fire. Force the
    /// rebuild here. Without this, an unchanged grid renders
    /// stale/blank glyphs until each line happens to go dirty on its
    /// own. A single method so it can never be half-applied again.
    pub fn onAtlasRebuilt(self: *TerminalSurface) void {
        self.cell_pass.markAllDirty();
        self.grid_pass.vbuf_valid = false;
        self.grid_pass.vbo_uploaded = false;
        for (self.grid_pass.row_caches_valid.items) |*r| r.* = false;
    }

    /// Invalidate every cached cell row (config pushes that change
    /// how cells resolve — colors, bold flags — without an atlas
    /// swap).
    pub fn markAllCellsDirty(self: *TerminalSurface) void {
        self.cell_pass.markAllDirty();
    }

    /// The atlas's current cell metrics in physical framebuffer
    /// pixels, or null before the first realize.
    pub fn cellPixelSize(self: *const TerminalSurface) ?struct { w: u16, h: u16 } {
        const atlas = self.atlas orelse return null;
        return .{ .w = atlas.cell_w, .h = atlas.cell_h };
    }

    /// The grid's inner padding in physical framebuffer pixels.
    pub fn padPhysical(self: *const TerminalSurface) f32 {
        return self.grid_pass.pad;
    }

    /// Whether bidi reordering is enabled (mouse mapping needs the
    /// visual→logical remap exactly when it is).
    pub fn bidiEnabled(self: *const TerminalSurface) bool {
        return self.grid_pass.enable_bidi;
    }

    /// Whether the auto-URL detector underlines (and thus activates)
    /// plain-text links.
    pub fn urlDetectEnabled(self: *const TerminalSurface) bool {
        return self.grid_pass.enable_url_underline;
    }

    pub const CellPos = struct { row: i32, col: i32 };

    /// Widget-local pixel position of the text cursor's BOTTOM-left
    /// corner — the anchor a keyboard-opened context menu points at,
    /// chosen so the popover hangs below the caret instead of over
    /// it.
    ///
    /// Inverse of `cellAt`: the grid and `pad` are in physical
    /// framebuffer pixels, GTK coordinates are logical, so divide the
    /// scale factor back out.
    pub fn cursorAnchor(self: *TerminalSurface) struct { x: f64, y: f64 } {
        const atlas = self.atlas orelse return .{ .x = 0, .y = 0 };
        const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        if (scale == 0) return .{ .x = 0, .y = 0 };
        const pad: f64 = @floatCast(self.grid_pass.pad);
        const screen = self.terminal.screen;
        // The cursor is addressed against the LIVE screen; scrolled
        // back, its on-screen row shifts down by the view offset.
        const visible_row: f64 =
            @as(f64, @floatFromInt(screen.row)) + @as(f64, @floatFromInt(screen.view_offset));
        const px = pad + @as(f64, @floatFromInt(screen.col)) * @as(f64, @floatFromInt(atlas.cell_w));
        const py = pad + (visible_row + 1.0) * @as(f64, @floatFromInt(atlas.cell_h));
        return .{ .x = px / scale, .y = py / scale };
    }

    /// Map widget pixel coords to a Screen selection coordinate.
    /// Returns the VISUAL column (left-to-right pixel order). Callers
    /// that need a LOGICAL column (selection storage on bidi rows)
    /// should use `cellAtLogical`.
    ///
    /// GTK gesture/motion events report widget-local LOGICAL pixels
    /// (pre-HiDPI). The cell grid + `pad` live in PHYSICAL
    /// framebuffer pixels (atlas measures cells via
    /// `FT_Set_Pixel_Sizes`, GL viewport uses `widget_size * scale`).
    /// Scale up the pointer coords first so the divide is
    /// unit-consistent — without this, clicks on HiDPI displays land
    /// 1/scale of the way to the intended cell.
    pub fn cellAt(self: *TerminalSurface, x: f64, y: f64) CellPos {
        const atlas = self.atlas;
        if (atlas == null or atlas.?.cell_w == 0 or atlas.?.cell_h == 0) return .{ .row = 0, .col = 0 };
        const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        const sx = x * scale;
        const sy = y * scale;
        const pad: f64 = @floatCast(self.grid_pass.pad);
        const col_f = (sx - pad) / @as(f64, @floatFromInt(atlas.?.cell_w));
        const row_f = (sy - pad) / @as(f64, @floatFromInt(atlas.?.cell_h));
        const visible_row: i32 = @intFromFloat(@max(0.0, row_f));
        const view_off: i32 = @intCast(self.terminal.screen.view_offset);
        return .{
            .col = @intFromFloat(@max(0.0, col_f)),
            .row = visible_row - view_off,
        };
    }

    /// Like `cellAt`, but returns the LOGICAL column (post-bidi
    /// reorder undo). Selection start/extend uses this so the stored
    /// selection coordinates are invariant under bidi reorder.
    pub fn cellAtLogical(self: *TerminalSurface, x: f64, y: f64) CellPos {
        const c0 = self.cellAt(x, y);
        if (!self.grid_pass.enable_bidi or c0.col < 0) return c0;
        const logical_col: u16 = self.terminal.screen.visualToLogicalCol(
            self.allocator,
            c0.row,
            @intCast(c0.col),
        );
        return .{ .col = @intCast(logical_col), .row = c0.row };
    }

    /// Live scrollbar geometry for this surface, in framebuffer
    /// pixels, or null when the scrollbar is off or has nothing to
    /// show.
    pub const SbGeom = struct { view: scrollbar.View, layout: scrollbar.Layout };

    pub fn scrollbarGeom(self: *TerminalSurface) ?SbGeom {
        const w = c.gtk_widget_get_width(@ptrCast(self.area));
        const h = c.gtk_widget_get_height(@ptrCast(self.area));
        if (w <= 0 or h <= 0) return null;
        const scale = c.gtk_widget_get_scale_factor(@ptrCast(self.area));
        const view = self.grid_pass.scrollbarView(
            self.terminal.screen,
            @floatFromInt(w * scale),
            @floatFromInt(h * scale),
        ) orelse return null;
        const l = scrollbar.layout(view) orelse return null;
        return .{ .view = view, .layout = l };
    }

    /// GTK pointer coordinates are widget-local LOGICAL pixels; the
    /// scrollbar lives in framebuffer pixels. Same correction as
    /// `cellAt`.
    pub fn toPhysical(self: *TerminalSurface, v: f64) f32 {
        const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        return @floatCast(v * scale);
    }

    /// Render the surface's current pixels to a PNG (owned GBytes)
    /// via a GtkWidgetPaintable → texture → PNG round-trip, capturing
    /// the live GL content exactly as shown. Null if unrealized or
    /// the GSK renderer isn't available (widget not mapped yet).
    pub fn screenshotPng(self: *TerminalSurface) ?*c.GBytes {
        const w: *c.GtkWidget = @ptrCast(self.area);
        const width = c.gtk_widget_get_width(w);
        const height = c.gtk_widget_get_height(w);
        if (width <= 0 or height <= 0) return null;
        const native = c.gtk_widget_get_native(w) orelse return null;
        const renderer = c.gtk_native_get_renderer(native) orelse return null;

        const paintable = c.gtk_widget_paintable_new(w) orelse return null;
        defer c.g_object_unref(paintable);
        const snapshot = c.gtk_snapshot_new();
        c.gdk_paintable_snapshot(
            @ptrCast(paintable),
            @ptrCast(snapshot),
            @floatFromInt(width),
            @floatFromInt(height),
        );
        const node = c.gtk_snapshot_free_to_node(snapshot) orelse return null;
        defer c.gsk_render_node_unref(node);

        var bounds = c.graphene_rect_t{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        };
        const texture = c.gsk_renderer_render_texture(renderer, node, &bounds) orelse return null;
        defer c.g_object_unref(texture);
        return c.gdk_texture_save_to_png_bytes(texture);
    }

    /// Build an Atlas at the surface's current size. Resolution
    /// order: explicit file path → family name via fontconfig →
    /// $SKETERM_FONT → built-in candidate list. Returns null when
    /// nothing loads.
    fn createAtlas(self: *TerminalSurface) ?*Atlas {
        const a = self.createAtlasInner() orelse return null;
        if (self.font_features) |spec| a.setFontFeatures(spec);
        return a;
    }

    fn createAtlasInner(self: *TerminalSurface) ?*Atlas {
        const size: u16 = self.physicalFontSize();
        const atlas_mod = @import("../render/atlas.zig");
        var opts = self.font_opts;
        opts.line_pad_px = self.line_pad_px;

        if (self.font_path) |fp| {
            if (self.tryAtlasPath(fp, size, opts)) |a| return a;
        }
        if (self.font_family) |fam| {
            // The regular face follows the configured weight too, so
            // a `font_weight = 300` family resolves to its Light file
            // rather than being emboldened at render time.
            const path = atlas_mod.resolveFamilyStyled(
                self.allocator,
                fam,
                atlas_mod.fcWeightFor(opts.weight),
                c.FC_SLANT_ROMAN,
            );
            if (path) |p| {
                defer self.allocator.free(p);
                if (Atlas.initWith(self.allocator, p.ptr, size, opts)) |a| {
                    return a;
                } else |_| {}
            }
        }
        if (@import("../util/profile.zig").getenv("SKETERM_FONT")) |env_path| {
            if (self.tryAtlasPath(env_path, size, opts)) |a| return a;
        }
        for (FONT_CANDIDATES) |path| {
            if (Atlas.initWith(self.allocator, path, size, opts)) |a| {
                return a;
            } else |_| continue;
        }
        return null;
    }

    fn tryAtlasPath(self: *TerminalSurface, fp: []const u8, size: u16, opts: Atlas.Options) ?*Atlas {
        const z = self.allocator.allocSentinel(u8, fp.len, 0) catch return null;
        defer self.allocator.free(z);
        @memcpy(z, fp);
        return Atlas.initWith(self.allocator, z.ptr, size, opts) catch null;
    }

    /// Install the frame-clock tick callback if it isn't already
    /// running. Cheap idempotent — can be called from event handlers
    /// without checking state. Triggers that start per-frame work
    /// (shader animation, image arrival with animation, child exit)
    /// call this so the tick is alive to pump. Keep the tick OFF for
    /// slow timers — see the `tick_id` field doc for why.
    pub fn ensureTickRunning(self: *TerminalSurface) void {
        if (self.tick_id != 0) {
            if (self.continuousWorkRequested()) self.setContinuousFrames(true);
            return;
        }
        self.tick_id = c.gtk_widget_add_tick_callback(
            @ptrCast(self.area),
            @ptrCast(&onTick),
            @ptrCast(self),
            null,
        );
        if (self.tick_id != 0 and self.continuousWorkRequested())
            self.setContinuousFrames(true);
    }

    fn stopTick(self: *TerminalSurface) void {
        if (self.tick_id != 0) {
            c.gtk_widget_remove_tick_callback(@ptrCast(self.area), self.tick_id);
            self.tick_id = 0;
        }
        if (self.continuous_release_idle != 0) {
            _ = c.g_source_remove(self.continuous_release_idle);
            self.continuous_release_idle = 0;
        }
        self.setContinuousFrames(false);
    }

    /// Whether the current cursor shape is a blinking variant.
    fn cursorBlinks(self: *TerminalSurface) bool {
        return switch (self.terminal.screen.cursor_shape) {
            .block_blink, .underline_blink, .bar_blink => true,
            else => false,
        };
    }

    /// Arm the blink timeout when focused with a blinking cursor
    /// shape. Idempotent; the timer self-removes when either
    /// condition stops holding, so callers just poke this on focus-in
    /// and on redraws (DECSCUSR can flip the shape mid-session).
    pub fn ensureBlinkTimer(self: *TerminalSurface) void {
        if (self.blink_timer != 0) return;
        if (!self.is_focused or !self.cursorBlinks()) return;
        const half_ms: i64 = @divTrunc(self.cursor_blink_us, 1000);
        const ms: c_uint = if (half_ms <= 0) 500 else @intCast(half_ms);
        self.blink_timer = c.g_timeout_add(ms, @ptrCast(&onBlinkTimer), @ptrCast(self));
    }

    pub fn stopBlinkTimer(self: *TerminalSurface) void {
        if (self.blink_timer != 0) {
            _ = c.g_source_remove(self.blink_timer);
            self.blink_timer = 0;
        }
    }

    /// Config change (blink interval) — pick up the new period.
    pub fn restartBlinkTimer(self: *TerminalSurface) void {
        self.stopBlinkTimer();
        self.ensureBlinkTimer();
    }

    /// Whether the cursor trail may draw at all right now.
    ///
    /// Suppressed on an unfocused surface (its cursor is a hollow
    /// outline; a moving smear there advertises the wrong pane),
    /// while scrolled back or in copy mode (the overlay pass hides
    /// the live cursor in the first case and draws a separate amber
    /// one in the second), and while DECSET 25 has the cursor
    /// hidden.
    fn trailEligible(self: *TerminalSurface) bool {
        if (!self.cursor_trail_on) return false;
        if (!self.is_focused) return false;
        const screen = self.terminal.screen;
        if (!screen.cursor_visible) return false;
        if (screen.view_offset != 0) return false;
        if (screen.copy_cursor != null) return false;
        return true;
    }

    /// Retarget and integrate the cursor trail, and publish (or
    /// clear) the quad the overlay pass draws.
    ///
    /// Runs from `onRender`, which is the right hook because every
    /// cursor move already causes a render — that render starts the
    /// animation, and `trail_timer` supplies the frames after it
    /// until the trail settles. The frame it settles publishes a
    /// null quad, which is what erases the last one, and drops the
    /// timer in the same call: no timer and no tick survive an idle
    /// cursor.
    fn updateCursorTrail(self: *TerminalSurface) void {
        const gp = &self.grid_pass;
        const atlas = self.atlas;
        if (!self.trailEligible() or atlas == null) {
            gp.trail_quad = null;
            if (self.trail_eligible) self.cursor_trail.snap();
            self.trail_eligible = false;
            self.stopTrailTimer();
            return;
        }

        const screen = self.terminal.screen;
        const cw: f32 = @floatFromInt(atlas.?.cell_w);
        const ch: f32 = @floatFromInt(atlas.?.cell_h);

        // Teleport instead of animating when the trail has just
        // become eligible again, or when the grid was replaced under
        // the cursor (full erase, alternate-screen swap, resize,
        // reattach snapshot) — dragging a diagonal across a viewport
        // whose content changed wholesale is smear, not motion.
        if (!self.trail_eligible or screen.viewport_epoch != self.trail_epoch) {
            self.cursor_trail.snap();
            self.trail_last_us = 0;
        }
        self.trail_eligible = true;
        self.trail_epoch = screen.viewport_epoch;

        // KNOWN LIMITATIONS, both deliberate:
        //  - logical column, not the bidi-resolved visual one the
        //    cursor quad itself uses, so on an RTL row the trail
        //    lands beside the cursor rather than under it. Resolving
        //    bidi here means a second reorder pass per frame for a
        //    decoration.
        //  - one cell wide even when the cursor sits on a
        //    double-width cell (the cursor quad doubles there). The
        //    trail is a motion cue, not a cursor.
        const x = gp.pad + @as(f32, @floatFromInt(screen.col)) * cw;
        const y = gp.pad + @as(f32, @floatFromInt(screen.row)) * ch;
        self.cursor_trail.setDestination(x, y, cw, ch);

        const now = @import("../util/profile.zig").microTimestamp();
        const dt: f32 = if (self.trail_last_us == 0)
            0
        else
            @as(f32, @floatFromInt(now - self.trail_last_us)) / 1e6;
        self.trail_last_us = now;

        if (self.cursor_trail.advance(dt, cw, ch)) {
            gp.trail_quad = self.cursor_trail.quad();
            self.ensureTrailTimer();
        } else {
            gp.trail_quad = null;
            self.stopTrailTimer();
        }
    }

    /// Arm the ~60 fps trail timer. Like the bell fade this is a
    /// GLib timeout and NOT the frame-clock tick: it asks one pane
    /// for one frame at a time, so a sibling pane whose cursor is
    /// still never repaints. See the `tick_id` field doc.
    fn ensureTrailTimer(self: *TerminalSurface) void {
        if (self.trail_timer != 0) return;
        self.trail_timer = c.g_timeout_add(16, @ptrCast(&onTrailTimer), @ptrCast(self));
    }

    pub fn stopTrailTimer(self: *TerminalSurface) void {
        if (self.trail_timer != 0) {
            _ = c.g_source_remove(self.trail_timer);
            self.trail_timer = 0;
        }
        self.trail_last_us = 0;
    }

    /// Config change — enable/disable and re-time the trail.
    pub fn applyTrailConfig(self: *TerminalSurface, enabled: bool, duration_ms: u32) void {
        self.cursor_trail_on = enabled;
        self.cursor_trail.setDuration(@as(f32, @floatFromInt(duration_ms)) / 1000.0);
        if (!enabled) {
            self.stopTrailTimer();
            self.cursor_trail.snap();
            self.trail_eligible = false;
            self.grid_pass.trail_quad = null;
        }
    }

    /// BEL arrived: start the 200 ms visual-bell fade (a short ~30
    /// fps timeout drives it — NOT the frame-clock tick; see the
    /// `tick_id` doc) and queue the first flash frame.
    pub fn flashBell(self: *TerminalSurface) void {
        if (self.bell_timer == 0) {
            self.bell_timer = c.g_timeout_add(33, @ptrCast(&onBellTimer), @ptrCast(self));
        }
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Re-arm rendering after a custom_shader config change: queue a
    /// frame (recompile happens lazily in onRender) and make sure the
    /// tick is alive so animation can self-sustain via `dirty`.
    pub fn updateShaderTick(self: *TerminalSurface) void {
        self.ensureTickRunning();
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Set (or clear, with null) this surface's own shader. Reads the
    /// file immediately; a same-path call only refreshes `animate`.
    /// `user_pick` marks the choice as explicit so profile/config
    /// pushes won't overwrite it. Returns false when the file could
    /// not be read; the previous selection stays untouched then.
    pub fn setCustomShader(self: *TerminalSurface, path: ?[]const u8, animate: bool, user_pick: bool) bool {
        if (path == null and self.custom_shader_path == null) return true;
        if (path) |p| if (self.custom_shader_path) |cur| {
            if (std.mem.eql(u8, p, cur)) {
                self.shader_cleared = false;
                self.shader_own.animate = animate;
                if (user_pick) self.custom_shader_user = true;
                self.updateShaderTick();
                return true;
            }
        };

        // Load everything the swap needs BEFORE dropping the old
        // shader, so an unreadable file cannot destroy a working one.
        var new_src: ?[]u8 = null;
        var new_path: ?[]u8 = null;
        var new_dir: ?[]u8 = null;
        if (path) |p| {
            new_src = loadShaderFile(self.allocator, p) orelse {
                std.debug.print("sketerm: pane shader not readable: {s}\n", .{p});
                return false;
            };
            new_path = self.allocator.dupe(u8, p) catch {
                self.allocator.free(new_src.?);
                return false;
            };
            // Shader-relative //@texture paths resolve against this.
            if (std.fs.path.dirname(p)) |d| {
                new_dir = self.allocator.dupe(u8, d) catch {
                    self.allocator.free(new_src.?);
                    self.allocator.free(new_path.?);
                    return false;
                };
            }
        }

        if (self.shader_own_src) |s| self.allocator.free(s);
        if (self.custom_shader_path) |s| self.allocator.free(s);
        if (self.shader_own_dir) |d| self.allocator.free(d);
        self.shader_own_src = new_src;
        self.custom_shader_path = new_path;
        self.shader_own_dir = new_dir;
        self.shader_own.src = new_src;
        self.shader_own.dir = new_dir;
        self.custom_shader_user = if (path != null) user_pick else false;
        if (path != null) self.shader_cleared = false;
        self.shader_own.animate = animate;
        self.shader_own.generation +%= 1;
        self.refreshShaderBinding();
        self.updateShaderTick();
        return true;
    }

    /// Point the GL pass at the surface's own shader when one is
    /// loaded, at nothing when the user explicitly cleared it, else
    /// at the window-level default.
    pub fn refreshShaderBinding(self: *TerminalSurface) void {
        if (self.shader_own.src != null) {
            self.shader_pass.source = &self.shader_own;
        } else if (self.shader_cleared) {
            self.shader_pass.source = null;
        } else {
            self.shader_pass.source = self.shader_default_source;
        }
    }

    /// Whether the bound shader source requests continuous rendering.
    pub fn shaderRequestsAnimation(self: *const TerminalSurface) bool {
        const src = self.shader_pass.source orelse return false;
        return src.src != null and src.animate;
    }

    fn continuousWorkRequested(self: *const TerminalSurface) bool {
        if (c.gtk_widget_get_mapped(@ptrCast(self.area)) == 0) return false;
        if (self.shaderRequestsAnimation()) return true;
        var it = self.terminal.screen.kitty_images.store.iterator();
        while (it.next()) |entry| {
            const image = entry.value_ptr;
            if (image.frames.items.len >= 2 and image.playing) return true;
        }
        return false;
    }

    /// Whether this surface currently owns a continuous frame-clock
    /// callback, as reported to the window-wide offload policy.
    pub fn continuousFramesActive(self: *const TerminalSurface) bool {
        return self.continuous_frames_reported;
    }

    /// Start the continuous tick after an event changed shader/kitty
    /// playback state. Called only at transition points (kitty
    /// animation commands, shader changes), never per frame.
    pub fn syncContinuousTick(self: *TerminalSurface) void {
        if (!self.continuousWorkRequested()) return;
        self.ensureTickRunning();
    }

    fn setContinuousFrames(self: *TerminalSurface, active: bool) void {
        if (active == self.continuous_frames_reported) return;
        self.continuous_frames_reported = active;
        if (self.on_continuous_frames) |callback| callback(self.host_ctx);
    }

    fn scheduleContinuousRelease(self: *TerminalSurface) void {
        if (!self.continuous_frames_reported or self.continuous_release_idle != 0) return;
        self.continuous_release_idle = c.g_idle_add(@ptrCast(&onContinuousRelease), @ptrCast(self));
    }

    /// Bind a shader preset's params to this surface: own copies of
    /// the values, and `shader_own.overrides` re-pointed at them so
    /// the preset tunes THIS pane only. Call after setCustomShader
    /// succeeded for the preset's shader path.
    pub fn applyShaderPresetParams(self: *TerminalSurface, name: []const u8, params: []const ShaderParamKV) void {
        self.freePresetData();
        self.preset_name = self.allocator.dupe(u8, name) catch null;
        for (params) |p| {
            const pname = self.allocator.dupe(u8, p.name) catch continue;
            self.preset_params.append(self.allocator, .{
                .name = pname,
                .value = p.value,
                .color = p.color,
            }) catch {
                self.allocator.free(pname);
                continue;
            };
        }
        self.shader_own.overrides = self.preset_params.items;
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Whether the surface owns its shader-param override slice
    /// (bound preset, or an unbound-but-kept per-pane set after a
    /// preset delete). Window's config repoints must skip such panes.
    pub fn hasOwnShaderParams(self: *const TerminalSurface) bool {
        return self.preset_name != null or self.preset_params.items.len > 0;
    }

    /// Forget the preset NAME but keep the per-pane param values —
    /// used when the preset file is deleted out from under the pane.
    pub fn unbindPresetName(self: *TerminalSurface) void {
        if (self.preset_name) |n| self.allocator.free(n);
        self.preset_name = null;
    }

    /// Set/update one param in this surface's per-pane override set
    /// (live — values upload each frame). No-op when the surface
    /// rides the global config params.
    pub fn setPresetParam(self: *TerminalSurface, name: []const u8, value: f32, color: ?[3]f32) void {
        if (!self.hasOwnShaderParams()) return;
        for (self.preset_params.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.value = value;
                entry.color = color;
                self.shader_own.overrides = self.preset_params.items;
                c.gtk_gl_area_queue_render(@ptrCast(self.area));
                return;
            }
        }
        const pname = self.allocator.dupe(u8, name) catch return;
        self.preset_params.append(self.allocator, .{
            .name = pname,
            .value = value,
            .color = color,
        }) catch {
            self.allocator.free(pname);
            return;
        };
        self.shader_own.overrides = self.preset_params.items;
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Unbind the preset; `global_overrides` is the config-level
    /// shader_params slice the surface falls back to.
    pub fn dropShaderPreset(self: *TerminalSurface, global_overrides: []const ShaderParamKV) void {
        self.freePresetData();
        self.shader_own.overrides = global_overrides;
    }

    fn freePresetData(self: *TerminalSurface) void {
        if (self.preset_name) |n| self.allocator.free(n);
        self.preset_name = null;
        for (self.preset_params.items) |p| self.allocator.free(p.name);
        self.preset_params.clearRetainingCapacity();
    }

    /// Explicitly turn this surface's shader off (sticky). Picking a
    /// shader later un-clears it.
    pub fn clearShader(self: *TerminalSurface) void {
        // Drop any surface-owned shader first.
        _ = self.setCustomShader(null, self.shader_own.animate, false);
        self.shader_cleared = true;
        self.custom_shader_user = false;
        self.refreshShaderBinding();
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Convert a point size (font_size, the user-facing config value)
    /// to PHYSICAL framebuffer pixels honouring the widget's HiDPI
    /// scale factor. FreeType + the cell grid both work in physical
    /// pixels — feed it the result of this. Without the scale_factor
    /// multiply the same point size renders tiny on HiDPI surfaces
    /// because GTK reports logical CSS pixels and we'd be sizing
    /// cells as if 1 logical px == 1 device px.
    fn physicalFontSize(self: *const TerminalSurface) u16 {
        const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        const dpi: f64 = 96.0 * scale;
        const px: f64 = @as(f64, @floatFromInt(self.font_size)) * dpi / 72.0;
        const rounded = @round(px);
        return @intFromFloat(@max(1.0, rounded));
    }

    /// Live font-size change. Tears down the old atlas (and its GL
    /// texture), bumps `font_size`, and rebuilds against the current
    /// GL context. The renderer rebinds the new texture each frame.
    /// Also re-derives the cell size so PTY winsize tracks the
    /// new metrics on the next resize.
    pub fn setFontSize(self: *TerminalSurface, new_size: u16) void {
        if (new_size == self.font_size) return;
        self.font_size = new_size;
        self.refreshFont();
    }

    /// Rebuild the atlas against the surface's CURRENT font fields
    /// (size, path, family, line padding). Used by setFontSize and by
    /// applyConfigChange when the font selection changed at the same
    /// size.
    pub fn refreshFont(self: *TerminalSurface) void {
        // Bail before touching GL state if the GLArea hasn't realized
        // yet (theoretically possible when prefs / Ctrl+= fire on a
        // never-mapped tab via --restore + dialog open). The next
        // realize will pick up the font fields and build the atlas
        // from scratch.
        if (c.gtk_widget_get_realized(@ptrCast(self.area)) == 0) return;

        // Make our GL context current so the texture deletes hit the
        // right context.
        c.gtk_gl_area_make_current(self.area);
        if (c.gtk_gl_area_get_error(self.area) != null) return;

        if (self.atlas) |old| {
            // Drop the GL texture before destroying the atlas.
            if (old.realized) {
                var tex: c_uint = old.gl_tex;
                c.glDeleteTextures(1, &tex);
            }
            old.deinit();
            self.atlas = null;
        }

        // Same path as onRealize but inline so we don't re-do GL pass
        // setup (those programs / VBOs are still live).
        self.atlas = self.createAtlas();
        if (self.atlas == null) return;
        self.atlas.?.realize();

        // See onAtlasRebuilt: without it, an unchanged grid renders
        // stale/blank glyphs until each line goes dirty on its own.
        self.onAtlasRebuilt();

        self.image_store.cell_w = @floatFromInt(self.atlas.?.cell_w);
        self.image_store.cell_h = @floatFromInt(self.atlas.?.cell_h);
        // Sync to Screen so CSI 14t/16t reports use the new metrics
        // without waiting for the next window resize.
        self.terminal.screen.cell_pixel_w = self.atlas.?.cell_w;
        self.terminal.screen.cell_pixel_h = self.atlas.?.cell_h;

        // Under live_terminal, force a SIGWINCH on the child —
        // terminal winsize in cells changes when the cell size
        // changes. Widget size is logical CSS pixels; cell metrics
        // are framebuffer pixels — multiply by scale_factor to
        // compare in the same space. A fixed_grid surface never
        // follows the allocation, so its grid keeps its dimensions.
        if (self.geometry == .live_terminal) {
            const w = c.gtk_widget_get_width(@ptrCast(self.area));
            const h = c.gtk_widget_get_height(@ptrCast(self.area));
            const scale = c.gtk_widget_get_scale_factor(@ptrCast(self.area));
            const pad: f32 = self.grid_pass.pad;
            const inner_w = @as(f32, @floatFromInt(w * scale)) - 2 * pad;
            const inner_h = @as(f32, @floatFromInt(h * scale)) - 2 * pad;
            const cw: f32 = @floatFromInt(self.atlas.?.cell_w);
            const ch: f32 = @floatFromInt(self.atlas.?.cell_h);
            if (cw > 0 and ch > 0) {
                const cols: u16 = @intCast(@max(@as(i32, 1), @as(i32, @intFromFloat(@floor(inner_w / cw)))));
                const rows: u16 = @intCast(@max(@as(i32, 1), @as(i32, @intFromFloat(@floor(inner_h / ch)))));
                // If the screen rejected the new dimensions (OOM
                // reflowing the buffer, etc.), don't tell the child a
                // different size from what the renderer is using —
                // mismatched winsize makes the shell wrap output
                // off-screen.
                self.terminal.screen.resize(cols, rows) catch |err| {
                    std.debug.print("sketerm: pane resize failed: {s}\n", .{@errorName(err)});
                    return;
                };
                self.terminal.requestResize(rows, cols);
            }
        }

        self.terminal.screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Terminal image sink landed (kitty/iTerm2 image arrived): store
    /// it and schedule the frame that shows it.
    pub fn addImage(self: *TerminalSurface, img: Screen.ImageEvent) void {
        self.image_store.addFull(.{
            .rgba = img.rgba,
            .width = img.width,
            .height = img.height,
            .row = img.row,
            .col = img.col,
            .image_id = img.image_id,
            .placement_id = img.placement_id,
            .z_index = img.z_index,
            .cells_wide = img.cells_wide,
            .cells_high = img.cells_high,
            .src_x = img.src_x,
            .src_y = img.src_y,
            .src_w = img.src_w,
            .src_h = img.src_h,
            .cell_x_offset = img.cell_x_offset,
            .cell_y_offset = img.cell_y_offset,
            .anchor_id = img.anchor_id,
        }) catch |err| {
            std.debug.print("sketerm: image_store.addFull failed (id={d}): {s}\n", .{ img.image_id, @errorName(err) });
        };
        // Force redraw to upload + display. Set dirty so onTick
        // paints AND queue_draw directly so we don't have to wait a
        // frame.
        self.terminal.screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
        // Image arrival may include an animation; ensure tick is up
        // to pump frames if the idle path had stopped it.
        self.ensureTickRunning();
    }

    fn uploadKittyAnimationFrames(self: *TerminalSurface) void {
        var it = self.terminal.screen.kitty_images.store.iterator();
        while (it.next()) |entry| {
            const img = entry.value_ptr;
            if (img.frames.items.len < 2) continue;
            self.image_store.uploadFrame(entry.key_ptr.*, img.generation, img.rgba) catch |err| {
                std.debug.print("sketerm: image_store.uploadFrame failed (id={d}): {s}\n", .{ entry.key_ptr.*, @errorName(err) });
            };
        }
    }

    /// A Kitty frame/control command changed playback or selected a
    /// frame. Upload the selected pixels now and establish continuous
    /// policy before the next frame-clock callback.
    pub fn imageAnimationChanged(self: *TerminalSurface) void {
        self.uploadKittyAnimationFrames();
        self.syncContinuousTick();
        // DECSET 2026 stages image and text updates atomically. Keep
        // the selected frame uploaded internally, but wait for DECRST
        // before exposing it through the GLArea.
        if (!self.terminal.screen.sync_output)
            c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Kitty `d=` delete request against the stored images.
    pub fn deleteImages(self: *TerminalSurface, ev: Screen.ImageDeleteEvent) void {
        // Kitty `d=` semantics. Lowercase leaves data on disk,
        // uppercase also frees it. We don't distinguish on free
        // behaviour — every delete tears down the GL texture on the
        // next flush.
        switch (ev.what) {
            // `d=a` with no id is the common "clear the screen" call;
            // the selector table would need a rectangle for it.
            'a', 'A' => {
                if (ev.image_id == 0) {
                    self.image_store.markAllForDelete();
                } else {
                    self.image_store.markByIdForDelete(ev.image_id);
                }
            },
            // Everything else goes through the protocol's own
            // selector table, including the positional ones.
            else => self.image_store.markSelectedForDelete(ev, imageNumberOf, @ptrCast(self)),
        }
        self.terminal.screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Whether the surface's font stack can draw this codepoint
    /// (glyph-coverage sink for the daemon's fallback decisions).
    pub fn hasGlyph(self: *TerminalSurface, cp: u32) bool {
        const atlas = self.atlas orelse return false;
        return atlas.hasSystemGlyph(cp);
    }
};

/// The image NUMBER a stored image was transmitted with, for the
/// `d=n/N` selector. Lives on the Screen's manager, which the store
/// has no reference to.
fn imageNumberOf(ctx: ?*anyopaque, image_id: u32) u32 {
    const self = cast.userData(TerminalSurface, ctx);
    return self.terminal.screen.kitty_images.numberOf(image_id);
}

fn onUnrealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(TerminalSurface, user);
    // Make the about-to-die context current so glDelete* lands on the
    // right resources. After this signal returns GTK tears the context
    // down — there is no second chance.
    c.gtk_gl_area_make_current(area);
    if (c.gtk_gl_area_get_error(area) != null) {
        // Context is already broken; nothing useful to delete against
        // it. Forget the IDs so a future realize starts clean.
        self.grid_pass.forgetGL();
        self.cell_pass.forgetGL();
        self.image_pass.forgetGL();
        self.bg_pass.forgetGL();
        self.shader_pass.forgetGL();
        self.linear_target.forgetGL();
        self.image_store.forgetGL();
        return;
    }
    self.grid_pass.releaseGL();
    self.cell_pass.releaseGL();
    self.image_pass.releaseGL();
    self.bg_pass.releaseGL();
    self.shader_pass.releaseGL();
    self.linear_target.releaseGL();
    self.image_store.releaseGL();
    if (self.atlas) |a| a.releaseGL();
}

fn onRealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(TerminalSurface, user);
    c.gtk_gl_area_make_current(area);
    gl_mod.adoptAreaApi(area);
    if (c.gtk_gl_area_get_error(area) != null) {
        const err = c.gtk_gl_area_get_error(area);
        const msg: [*:0]const u8 = if (err != null) err.*.message else "<no message>";
        std.debug.print("sketerm: pane realize GL error: {s}\n", .{msg});
        return;
    }

    // gtk_widget_unparent unrealizes a widget. A reparent (split,
    // tab move, layout shuffle) therefore destroys our GL context
    // and gives us a fresh one on the next realize — EVERY realize
    // is potentially a re-realize. Drop every cached GL handle so
    // the realize path below actually rebuilds them — without this,
    // grid_pass.realize() returns early on `program != 0` and we'd
    // glUseProgram a dead ID (silent black renders).
    if (self.atlas) |old| {
        old.deinit();
        self.atlas = null;
    }
    self.grid_pass.forgetGL();
    self.cell_pass.forgetGL();
    self.image_pass.forgetGL();
    self.bg_pass.forgetGL();
    self.shader_pass.forgetGL();
    self.linear_target.forgetGL();
    self.image_store.forgetGL();

    // Resolution order: explicit font_path → font_family
    // (fontconfig) → $SKETERM_FONT env → built-in candidate list.
    // Size from font_size (set by Config or Ctrl+/Ctrl-).
    self.atlas = self.createAtlas();
    if (self.atlas == null) {
        std.debug.print("pane realize: no usable font in {d} candidates\n", .{FONT_CANDIDATES.len});
        return;
    }
    self.atlas.?.realize();
    // Surface the font path via OSC 50 ; ? queries so apps probing for
    // a font name get something back. Path-as-name is informational.
    if (self.font_path) |fp| self.terminal.screen.font_name = fp;

    self.grid_pass.realize() catch {
        std.debug.print("pane realize: grid_pass realize failed\n", .{});
        return;
    };
    self.cell_pass.realize() catch {
        std.debug.print("pane realize: cell_pass realize failed\n", .{});
        return;
    };
    self.image_pass.realize() catch {
        std.debug.print("pane realize: image_pass realize failed\n", .{});
        return;
    };
    self.bg_pass.realize() catch {
        std.debug.print("pane realize: bg_pass realize failed\n", .{});
        return;
    };

    // Cell metrics into image store so placements get pixel coords.
    self.image_store.cell_w = @floatFromInt(self.atlas.?.cell_w);
    self.image_store.cell_h = @floatFromInt(self.atlas.?.cell_h);
}

/// The letterbox rect a fixed_grid surface renders into: the grid's
/// native pixel size and the centered, aspect-preserving viewport it
/// scales into.
const FixedViewport = struct {
    grid_w: c_int,
    grid_h: c_int,
    vx: c_int,
    vy: c_int,
    vw: c_int,
    vh: c_int,
};

fn fixedViewport(self: *TerminalSurface, phys_w: c_int, phys_h: c_int) ?FixedViewport {
    const fg = switch (self.geometry) {
        .fixed_grid => |g| g,
        .live_terminal => return null,
    };
    const atlas = self.atlas orelse return null;
    if (atlas.cell_w == 0 or atlas.cell_h == 0) return null;
    if (phys_w <= 0 or phys_h <= 0) return null;
    const pad: c_int = @intFromFloat(self.grid_pass.pad);
    const gw: c_int = @as(c_int, fg.cols) * @as(c_int, atlas.cell_w) + 2 * pad;
    const gh: c_int = @as(c_int, fg.rows) * @as(c_int, atlas.cell_h) + 2 * pad;
    if (gw <= 0 or gh <= 0) return null;
    const sx = @as(f64, @floatFromInt(phys_w)) / @as(f64, @floatFromInt(gw));
    const sy = @as(f64, @floatFromInt(phys_h)) / @as(f64, @floatFromInt(gh));
    const s = @min(sx, sy);
    const vw: c_int = @max(1, @as(c_int, @intFromFloat(@floor(@as(f64, @floatFromInt(gw)) * s))));
    const vh: c_int = @max(1, @as(c_int, @intFromFloat(@floor(@as(f64, @floatFromInt(gh)) * s))));
    return .{
        .grid_w = gw,
        .grid_h = gh,
        .vx = @divTrunc(phys_w - vw, 2),
        .vy = @divTrunc(phys_h - vh, 2),
        .vw = vw,
        .vh = vh,
    };
}

fn onRender(area: *c.GtkGLArea, _: *c.GdkGLContext, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TerminalSurface, user);
    const atlas = self.atlas orelse return @intFromBool(false);
    const profile = @import("../util/profile.zig");
    const t_total = if (profile.enabled) profile.nanoTimestamp() else 0;

    const w = c.gtk_widget_get_width(@ptrCast(area));
    const h = c.gtk_widget_get_height(@ptrCast(area));
    const scale = c.gtk_widget_get_scale_factor(@ptrCast(area));
    const phys_w: c_int = w * scale;
    const phys_h: c_int = h * scale;

    // fixed_grid: the passes render the grid at its NATIVE pixel size
    // (rw x rh); GL's NDC->viewport mapping scales it into the
    // centered letterbox rect on the final framebuffer. live_terminal
    // renders 1:1 (fixed == null) and every expression below
    // degenerates to the allocation-sized path.
    const fixed = fixedViewport(self, phys_w, phys_h);
    const rw: c_int = if (fixed) |f| f.grid_w else phys_w;
    const rh: c_int = if (fixed) |f| f.grid_h else phys_h;

    // Custom-shader detour: render the whole scene into an offscreen
    // texture; finish() maps it through the user shader at the end.
    // When there's no custom shader but the pane is inactive (dim
    // requested), take the same offscreen path for a dim-only post.
    const shader_on = self.shader_pass.active() and
        self.shader_pass.begin(self.allocator, rw, rh);
    const dim_on = !shader_on and self.shader_pass.beginDim(self.allocator, rw, rh);

    // Linear-light detour, INSIDE the custom-shader / dim detour: the
    // scene blends in linear light, resolves back to sRGB-encoded
    // RGBA8, and only then does a user shader see it — so a CRT shader
    // keeps operating on the pixels it always did.
    const blend_mode = self.text_blending;
    const linear_on = self.linear_target.begin(blend_mode, rw, rh);

    // Offscreen detours draw at the grid's native size; only a direct
    // render to the window framebuffer letterboxes immediately.
    // (glClear ignores the viewport, so the letterbox bars clear to
    // the default background either way.)
    if (fixed) |f| {
        if (shader_on or dim_on or linear_on)
            c.glViewport(0, 0, rw, rh)
        else
            c.glViewport(f.vx, f.vy, f.vw, f.vh);
    } else {
        c.glViewport(0, 0, phys_w, phys_h);
    }
    // The clear writes through the same sRGB encode a fragment does,
    // so the linear modes owe glClearColor linear light. This is the
    // one colour that never passes through a shader.
    const clear = blend_mod.clearColor(
        if (linear_on) blend_mode else .native,
        self.grid_pass.default_bg,
    );
    c.glClearColor(clear[0], clear[1], clear[2], clear[3]);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    // If the sRGB target could not be built we render `native` this
    // frame: handing linear light to a plain RGBA8 framebuffer would
    // wash the whole pane out. Every pass writing into this
    // framebuffer must agree on one effective mode, so they are all
    // set from one value.
    const eff_mode: blend_mod.Mode = if (linear_on) blend_mode else .native;
    self.cell_pass.blend_mode = eff_mode;
    self.grid_pass.blend_mode = eff_mode;
    self.image_pass.blend_mode = eff_mode;
    self.bg_pass.blend_mode = eff_mode;

    self.grid_pass.canvas_w = @floatFromInt(rw);
    self.grid_pass.canvas_h = @floatFromInt(rh);

    // Background layer (gradient / image) — under everything,
    // including kitty below-text images.
    self.bg_pass.draw(rw, rh);

    // is_focused is kept in sync by the host's focus handlers;
    // skipping the GTK call shaves a few hundred ns per render.
    const focused = self.is_focused;
    // Bump atlas frame counter so multi-page LRU eviction has fresh
    // "last used" timestamps per render.
    atlas.markFrame();
    // Cell pipeline (instanced) — emits per-cell bg + per-cell glyph
    // for single-scale ASCII rows. Updates only dirty rows in the
    // persistent VBO.
    self.cell_pass.pad = self.grid_pass.pad;
    self.cell_pass.enable_ligatures = self.grid_pass.enable_ligatures;
    self.cell_pass.enable_bidi = self.grid_pass.enable_bidi;
    const t_cell_rebuild = if (profile.enabled) profile.nanoTimestamp() else 0;
    self.cell_pass.rebuildAndUpload(self.terminal.screen, &self.terminal.pool, atlas) catch return @intFromBool(false);
    if (profile.enabled) profile.record(.cell_rebuild, @intCast(profile.nanoTimestamp() - t_cell_rebuild));
    const cells_changed = self.cell_pass.cells_rebuilt;
    const rebuilt_rows = self.cell_pass.rebuilt_rows.items;

    // Resolve each anchored image to its live display row (so images
    // scroll with content and into scrollback) and reap any whose
    // anchor line has fallen out of the scrollback ring.
    resolveImageRows(self);
    // Z-ordering: images with z_index < 0 render BEHIND text/cells,
    // images with z_index >= 0 render in front (kitty default).
    // Sandwich the cell + overlay passes between two image passes.
    self.image_store.flushUploads();
    // Match the cell grid's inner padding so images align with the
    // cells that placed them.
    self.image_pass.pad = self.grid_pass.pad;
    var img_ns: u64 = 0;
    {
        const t_img = if (profile.enabled) profile.nanoTimestamp() else 0;
        self.image_pass.drawZ(&self.image_store, rw, rh, .below);
        if (profile.enabled) img_ns += @intCast(profile.nanoTimestamp() - t_img);
    }

    const t_cell_draw = if (profile.enabled) profile.nanoTimestamp() else 0;
    self.cell_pass.draw(atlas, rw, rh);
    if (profile.enabled) profile.record(.cell_draw, @intCast(profile.nanoTimestamp() - t_cell_draw));
    // Cursor trail: retarget + integrate before the overlay pass
    // builds its vertices, since the quad it publishes is one of
    // that pass's inputs (and part of its snapshot hash).
    self.updateCursorTrail();
    // Overlay pipeline (per-vertex VBO) — cursor, selection, focus
    // border, scrollback indicator, preedit, bell, and any rows that
    // need bidi reorder or DH/DW per-line scaling.
    const t_grid_build = if (profile.enabled) profile.nanoTimestamp() else 0;
    self.grid_pass.buildVertices(self.terminal.screen, &self.terminal.pool, atlas, focused, cells_changed, rebuilt_rows) catch return @intFromBool(false);
    if (profile.enabled) profile.record(.grid_build, @intCast(profile.nanoTimestamp() - t_grid_build));
    const t_grid_draw = if (profile.enabled) profile.nanoTimestamp() else 0;
    self.grid_pass.draw(atlas, rw, rh);
    if (profile.enabled) profile.record(.grid_draw, @intCast(profile.nanoTimestamp() - t_grid_draw));

    // Foreground images (z >= 0).
    {
        const t_img = if (profile.enabled) profile.nanoTimestamp() else 0;
        self.image_pass.drawZ(&self.image_store, rw, rh, .above);
        if (profile.enabled) img_ns += @intCast(profile.nanoTimestamp() - t_img);
    }
    // Resolve linear light back to the sRGB-encoded RGBA8 target the
    // custom-shader / dim post-process (or GTK itself) expects. When
    // this resolve is the LAST hop to the window framebuffer, a
    // fixed_grid surface letterboxes here.
    if (linear_on) {
        if (fixed) |f| if (!shader_on and !dim_on)
            c.glViewport(f.vx, f.vy, f.vw, f.vh);
        self.linear_target.finish(rw, rh);
    }
    if (shader_on) {
        if (fixed) |f| c.glViewport(f.vx, f.vy, f.vw, f.vh);
        const now_us = c.g_get_monotonic_time();
        if (self.shader_epoch_us == 0) self.shader_epoch_us = now_us;
        const time_s: f32 = @as(f32, @floatFromInt(now_us - self.shader_epoch_us)) / 1e6;
        self.shader_pass.finish(rw, rh, time_s);
    } else if (dim_on) {
        if (fixed) |f| c.glViewport(f.vx, f.vy, f.vw, f.vh);
        self.shader_pass.finishDim(rw, rh);
    }

    if (profile.enabled) {
        profile.record(.image_pass, img_ns);
        profile.record(.onrender_total, @intCast(profile.nanoTimestamp() - t_total));
    }

    return @intFromBool(true);
}

/// Recompute each anchored image's live display row from the Screen
/// before drawing. Pinned images (anchor_id == 0) keep their cell_row;
/// images whose anchor line scrolled out of the ring are marked for
/// deletion so flushUploads frees them.
fn resolveImageRows(self: *TerminalSurface) void {
    const screen = self.terminal.screen;
    for (self.image_store.images.items) |*img| {
        if (img.deleting) continue;
        if (img.anchor_id == 0) {
            img.draw_row = img.cell_row;
            img.on_screen = true;
            continue;
        }
        switch (screen.imageRowForAnchor(img.anchor_id)) {
            .visible => |r| {
                img.draw_row = r;
                img.on_screen = true;
            },
            .offscreen => img.on_screen = false,
            .evicted => {
                img.on_screen = false;
                img.deleting = true;
            },
        }
    }
}

fn onTick(area: *c.GtkWidget, _: *c.GdkFrameClock, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TerminalSurface, user);
    const screen = self.terminal.screen;

    // PTY child exited — fire the once-per-exit host hook so the
    // session owner can act per exit_action. Clear flag immediately
    // so subsequent ticks don't re-fire (the host may close the pane
    // mid-call).
    if (screen.child_exited) {
        screen.child_exited = false;
        self.tick_id = 0;
        // The continuous report drops via the release idle so it runs
        // only after GTK removed this callback; teardown paths cancel
        // it through stopVisualSources.
        self.scheduleContinuousRelease();
        if (self.on_child_exit) |f| f(self.host_ctx, screen.child_exit_status);
        // The exit hook may have torn the surface down (exit_action
        // .close); `self` is potentially freed. Returning CONTINUE
        // would re-enter next frame on dangling memory.
        return 0; // G_SOURCE_REMOVE
    }

    // NOTE: cursor blink and bell fade are NOT tick work — they run
    // on GLib timeouts (onBlinkTimer / onBellTimer) so an idle
    // focused pane keeps the frame clock stopped. See `tick_id` doc.
    const now = @import("../util/profile.zig").microTimestamp();
    const mapped = c.gtk_widget_get_mapped(@ptrCast(self.area)) != 0;

    // Custom-shader animation: redraw every frame so iTime advances —
    // but only while the pane is actually on screen. A pane on a
    // background tab is unmapped; animating it would burn GPU for
    // pixels nobody sees (and GTK may still tick it briefly during
    // tab transitions). Tying this to visibility, not focus, keeps
    // side-by-side splits animating in lockstep.
    const shader_animating = shaderAnimates(self) and mapped;
    if (shader_animating) screen.dirty = true;

    // Animation: advance frames in the kitty-graphics manager. When
    // any image stepped to a new frame, pull its bytes into the
    // matching placements so the next render shows the new frame.
    // Unmapped panes skip the advance entirely (nobody sees the
    // frames; onAreaMap re-arms the tick and playback resumes).
    if (mapped and screen.kitty_images.advanceAnimations(now)) {
        self.uploadKittyAnimationFrames();
        screen.dirty = true;
    }

    // Synchronized-output mode (DECSET 2026): suppress redraws so the
    // running app can stage a multi-step screen update and have it
    // appear atomically. The `dirty` flag stays set; we'll redraw
    // when the app sends DECRST 2026.
    if (screen.dirty and screen.sync_output) return 1;

    if (screen.dirty) {
        // Give the host its pre-redraw moment (the pane repositions
        // the IME candidate popup here, so fcitx5 / ibus track the
        // caret cell).
        if (self.on_before_redraw) |f| f(self.host_ctx);

        screen.dirty = false;
        c.gtk_gl_area_queue_render(@ptrCast(area));
    }

    // Self-remove when no per-frame work is active: the tick only
    // exists for shader animation and kitty-graphics playback, both
    // gated on mapped. Triggers (image-arrival, shader change,
    // onAreaMap) call ensureTickRunning to put us back. Idle panes —
    // including focused ones with a blinking cursor — keep the frame
    // clock fully stopped.
    const has_anim_work = mapped and blk: {
        var it = screen.kitty_images.store.iterator();
        while (it.next()) |e| {
            const img = e.value_ptr;
            if (img.frames.items.len >= 2 and img.playing) break :blk true;
        }
        break :blk false;
    };
    if (!has_anim_work and !shader_animating) {
        self.tick_id = 0;
        self.scheduleContinuousRelease();
        return 0; // G_SOURCE_REMOVE
    }
    self.setContinuousFrames(true);
    return 1; // G_SOURCE_CONTINUE
}

fn onContinuousRelease(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TerminalSurface, user);
    self.continuous_release_idle = 0;
    // New work may have installed another callback before this idle
    // ran. Its eventual removal owns the next release attempt.
    if (self.tick_id == 0) self.setContinuousFrames(false);
    return 0; // G_SOURCE_REMOVE
}

/// Blink timeout body — toggles the cursor phase and self-removes
/// when the pane loses focus or the shape stops blinking.
fn onBlinkTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TerminalSurface, user);
    const screen = self.terminal.screen;
    if (!self.is_focused or !self.cursorBlinks()) {
        // Don't strand a hidden cursor: snap visible on the way out.
        if (!screen.cursor_blink_on) {
            screen.cursor_blink_on = true;
            c.gtk_gl_area_queue_render(@ptrCast(self.area));
        }
        self.blink_timer = 0;
        return 0; // G_SOURCE_REMOVE
    }
    // Synchronized output (DECSET 2026): hold phase, keep ticking.
    // `screen.dirty` is the drain path's latch — never touch it here.
    if (screen.sync_output) return 1;
    screen.cursor_blink_on = !screen.cursor_blink_on;
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
    return 1; // G_SOURCE_CONTINUE
}

/// Bell-fade timeout body — redraws at ~30 fps while the 200 ms
/// flash decays, then stops itself with one final clearing frame.
fn onBellTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TerminalSurface, user);
    const screen = self.terminal.screen;
    const now = @import("../util/profile.zig").microTimestamp();
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
    if (screen.bell_at_us == 0 or now - screen.bell_at_us >= 200_000) {
        self.bell_timer = 0;
        return 0; // G_SOURCE_REMOVE (that render clears the flash)
    }
    return 1; // G_SOURCE_CONTINUE
}

/// Cursor-trail timeout body — asks for the next frame while the
/// trail is in flight. The integration itself lives in `onRender`
/// (`updateCursorTrail`), which stops this timer the frame the trail
/// settles, so this callback never has to decide when to quit; it
/// only bails when the pane stops being drawn at all, since an
/// unmapped GLArea would swallow every queued render and leave the
/// timer spinning against a pane nobody sees.
fn onTrailTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(TerminalSurface, user);
    if (c.gtk_widget_get_mapped(@ptrCast(self.area)) == 0) {
        self.cursor_trail.snap();
        self.grid_pass.trail_quad = null;
        self.trail_timer = 0;
        self.trail_last_us = 0;
        return 0; // G_SOURCE_REMOVE
    }
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
    return 1; // G_SOURCE_CONTINUE
}

/// Whether the surface's effective shader requests per-frame
/// animation.
fn shaderAnimates(self: *TerminalSurface) bool {
    return self.shader_pass.active() and self.shaderRequestsAnimation();
}

fn onAreaMap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(TerminalSurface, user);
    if (shaderAnimates(self)) self.updateShaderTick();
    // Kitty animations paused while unmapped (tick self-removed);
    // resume playback now that the pane is visible again. The tick
    // drops right back out if nothing is actually playing.
    self.ensureTickRunning();
}

fn onAreaUnmap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(TerminalSurface, user);
    self.stopTick();
}

fn onResize(_: *c.GtkGLArea, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(TerminalSurface, user);
    switch (self.geometry) {
        // A fixed grid never follows the allocation and never
        // reports geometry; the framebuffer was reallocated though,
        // so repaint the letterbox.
        .fixed_grid => {
            c.gtk_gl_area_queue_render(@ptrCast(self.area));
            return;
        },
        .live_terminal => {},
    }
    const atlas = self.atlas orelse return;
    if (atlas.cell_w == 0 or atlas.cell_h == 0) return;
    // Subtract pane padding (top+bottom, left+right) before computing
    // cell counts — otherwise we'd allocate cells that overflow the
    // visible content area. NOTE: GtkGLArea's resize signal fires with
    // the framebuffer dimensions in PHYSICAL pixels (that's the whole
    // reason the signal exists separately from size-allocate — to give
    // the user the right values for `glViewport`). Do not multiply by
    // scale_factor here; cell metrics are also in framebuffer pixels,
    // so the divide is already unit-consistent.
    const pad: c_int = @intFromFloat(self.grid_pass.pad);
    const inner_w: c_int = @max(1, width - 2 * pad);
    const inner_h: c_int = @max(1, height - 2 * pad);
    const cols: u16 = @intCast(@max(1, @divFloor(inner_w, @as(c_int, atlas.cell_w))));
    const rows: u16 = @intCast(@max(1, @divFloor(inner_h, @as(c_int, atlas.cell_h))));
    // Always sync the cell-pixel metrics — apps querying CSI 14t
    // / 18t expect accurate sizes even when col/row counts didn't
    // change (e.g. when the user just resized the window slightly).
    self.terminal.screen.cell_pixel_w = atlas.cell_w;
    self.terminal.screen.cell_pixel_h = atlas.cell_h;
    if (cols == self.terminal.screen.cols and rows == self.terminal.screen.rows) return;

    self.terminal.screen.resize(cols, rows) catch return;
    self.terminal.requestResize(rows, cols);
    // Only reached when the COUNT changed (the guard above returns
    // otherwise), so a dimensions-bearing title re-renders per real
    // geometry change, not per pixel of drag.
    if (self.on_grid_geometry) |f| f(self.host_ctx);
    // Resize reallocates the framebuffer; with auto_render off we
    // must explicitly schedule a repaint or the user sees stale
    // contents from the old size.
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
}
