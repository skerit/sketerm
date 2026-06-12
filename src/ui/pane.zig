//! Pane — wraps a GtkGLArea + Atlas + GridPass + Terminal.
//!
//! On `realize`, GL resources are constructed.
//! On `render`, the screen state is rebuilt into the vertex buffer
//! and drawn.
//!
//! For M3, this is the bare-minimum bridge: one Pane, no splits,
//! no input handling. M4 wires keyboard/mouse.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Atlas = @import("../render/atlas.zig").Atlas;
const GridPass = @import("../render/grid_pass.zig").GridPass;
const CellPass = @import("../render/cell_pass.zig").CellPass;
const ImagePass = @import("../render/image_pass.zig").ImagePass;
const BgPass = @import("../render/bg_pass.zig").BgPass;
const ShaderPass = @import("../render/shader_pass.zig").ShaderPass;
const ShaderSource = @import("../render/shader_pass.zig").Source;
const ShaderParamKV = @import("../render/shader_pass.zig").ParamKV;
const gl_mod = @import("../render/gl.zig");
const ImageStore = @import("../grid/image_store.zig").Store;
const Screen = @import("../grid/screen.zig").Screen;
const Terminal = @import("../terminal.zig").Terminal;
const DrainHandle = @import("../terminal.zig").DrainHandle;
const input = @import("input.zig");
const menu = @import("menu.zig");
const clipboard = @import("clipboard.zig");
const MouseAction = @import("../config.zig").MouseAction;
pub const InputCtx = input.Ctx;
pub const MenuAction = menu.Action;

const FONT_CANDIDATES = if (@import("../util/platform.zig").is_macos) [_][*:0]const u8{
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
const FONT_SIZE: u16 = 14;

pub const Pane = struct {
    /// Stable monotonic id for remote-control addressing. Assigned
    /// by Window before the PTY spawn so the child env can carry it.
    id: u32 = 0,
    area: *c.GtkGLArea,
    terminal: *Terminal,
    atlas: ?*Atlas = null,
    grid_pass: GridPass,
    cell_pass: CellPass,
    image_pass: ImagePass = ImagePass.init(),
    bg_pass: BgPass = .{},
    shader_pass: ShaderPass = .{},
    /// iTime epoch for the custom shader (monotonic µs; 0 = unset).
    shader_epoch_us: i64 = 0,
    /// Window-level shader source (the config-global one). The pane
    /// falls back to this when it has no own shader. Set by
    /// applyPaneConfig.
    shader_default_source: ?*const ShaderSource = null,
    /// Pane-owned shader (profile override or explicit user pick) —
    /// wins over the window default. `shader_own_src` backs
    /// `shader_own.src`; `custom_shader_path` is kept for change
    /// detection + layout persistence. All pane-allocator-owned.
    shader_own: ShaderSource = .{},
    shader_own_src: ?[]u8 = null,
    shader_own_dir: ?[]u8 = null,
    custom_shader_path: ?[]u8 = null,
    /// True when the user picked the shader explicitly (context
    /// menu / palette / restored layout) — config reloads and
    /// profile pushes then leave it alone.
    custom_shader_user: bool = false,
    /// Shader preset applied to this pane (see shader_preset.zig):
    /// the preset's param values live in `preset_params` (names
    /// owned) and `shader_own.overrides` points at them instead of
    /// the global config slice — making params per-pane while a
    /// preset is active. Both cleared by dropShaderPreset.
    preset_name: ?[]u8 = null,
    preset_params: std.ArrayList(ShaderParamKV) = .empty,
    /// True when the user explicitly cleared this pane's shader.
    /// Distinct from "no pick" (which inherits profile/global): a
    /// cleared pane shows NO shader and, like a user pick, is sticky
    /// across config reloads and profile pushes.
    shader_cleared: bool = false,
    image_store: ImageStore,
    allocator: std.mem.Allocator,
    input_ctx: ?*input.Ctx = null,
    /// Arena holding menu's per-pane closure ctxs. Deinit frees all.
    menu_arena: std.heap.ArenaAllocator,
    /// External sink for menu actions (set by Window).
    menu_sink: ?menu.Sink = null,
    menu_sink_ctx: ?*anyopaque = null,
    /// Window-level forwarding for terminal sinks.
    win_title_ctx: ?*anyopaque = null,
    win_on_title: ?*const fn (ctx: ?*anyopaque, pane: *Pane, title: []const u8) void = null,
    win_clip_ctx: ?*anyopaque = null,
    win_on_clipboard: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// Forward desktop notifications (OSC 9 / 99 / 777 / 1337).
    win_notify_ctx: ?*anyopaque = null,
    win_on_notification: ?*const fn (ctx: ?*anyopaque, pane: *Pane, ev: Screen.NotificationEvent) void = null,
    /// Forward OSC 9;4 progress so Window can drive tab + taskbar.
    win_progress_ctx: ?*anyopaque = null,
    win_on_progress: ?*const fn (ctx: ?*anyopaque, pane: *Pane, state: u8, percent: u8) void = null,
    /// Forward OSC 7 cwd updates so Window can rewrite the tab tooltip.
    win_cwd_ctx: ?*anyopaque = null,
    win_on_cwd: ?*const fn (ctx: ?*anyopaque, pane: *Pane, cwd: []const u8) void = null,
    /// Forward BEL events for tab-bar attention.
    win_bell_ctx: ?*anyopaque = null,
    win_child_ctx: ?*anyopaque = null,
    win_on_bell: ?*const fn (ctx: ?*anyopaque, pane: *Pane) void = null,
    /// Fired exactly once when the PTY child exits. Window decides
    /// what to do (close pane / restart shell / hold).
    win_on_child_exit: ?*const fn (ctx: ?*anyopaque, pane: *Pane, status: i32) void = null,
    /// Forward mux session renames so Window can retitle the tab.
    win_session_rename_ctx: ?*anyopaque = null,
    win_on_session_renamed: ?*const fn (ctx: ?*anyopaque, pane: *Pane, name: []const u8) void = null,
    /// Cursor blink timing.
    last_blink_us: i64 = 0,
    /// GTK tick callback id (0 = not registered). The tick is the
    /// only thing pumping at frame rate; we self-remove it when no
    /// time-driven work is active (cursor blink, bell flash,
    /// animation) and re-install on triggers that need it.
    tick_id: c_uint = 0,
    /// Last cursor (row, col) reported to the IM context. -1 = never
    /// reported — first call sets the actual coords.
    last_im_row: i32 = -1,
    last_im_col: i32 = -1,
    /// Last reported mouse-motion cell, to suppress duplicates.
    last_motion_row: i32 = -2,
    last_motion_col: i32 = -2,
    /// Sub-line scroll accumulator for high-resolution / touchpad
    /// scroll events. dy is scaled by SCROLL_LINES_PER_NOTCH (3) and
    /// integer-truncated; the fractional remainder carries forward
    /// so a string of small dy events eventually advances by a line.
    scroll_accum: f64 = 0,
    /// xterm button code (0=L,1=M,2=R) currently held, or -1 = none.
    /// Used by DECSET 1002 button-event tracking.
    held_button: i32 = -1,
    /// URI captured at right-click time. menu_pre_popup writes here
    /// when the click landed on an OSC 8 hyperlink cell; the
    /// "copy-link" action reads it on activate.
    menu_link_uri: ?[]u8 = null,
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
    /// like `font_family`; applied to every atlas this pane creates.
    font_features: ?[]const u8 = null,
    /// Cursor blink half-cycle interval in microseconds. 500_000
    /// (= 500 ms) is the xterm default.
    cursor_blink_us: i64 = 500_000,
    /// Extra pixels added to cell_h for visual line spacing (passed
    /// to Atlas.initOpts). 0 = font default.
    line_pad_px: i16 = 0,
    /// Mouse / link / search behaviour mirrors Window.config and is
    /// pushed down via applyConfigChange so each frame's hot path
    /// reads from the local Pane instead of dereffing through Window.
    copy_on_selection: bool = false,
    clear_select_on_copy: bool = false,
    disable_mouse_paste: bool = false,
    disable_mousewheel_zoom: bool = false,
    link_single_click: bool = false,
    /// Rebindable click actions (config mouse_middle_click /
    /// mouse_right_click). Only consulted when mouse_mode == 0.
    middle_click_action: MouseAction = .paste_primary,
    right_click_action: MouseAction = .menu,
    mouse_autohide: bool = true,
    /// True while mouse_autohide has set the pointer to "none". The
    /// motion handler restores the default cursor on any movement.
    cursor_hidden: bool = false,
    /// True while the pointer is over a hyperlinked cell — cursor
    /// is forced to the "pointer" shape (gnome-terminal / kitty
    /// convention). Cleared when the pointer leaves the link.
    cursor_over_link: bool = false,

    /// Per-pane title bar (Terminator-style). The wrapper Box owns
    /// the header + GLArea; `widget()` returns the wrapper when
    /// present. The label is updated from on_title (OSC 0/1/2).
    /// Active / inactive colouring is handled via CSS classes
    /// "sketerm-titlebar-active" / "sketerm-titlebar-inactive" plus
    /// a Window-level GtkCssProvider that supplies the actual rgba
    /// values from Config.title_*_*.
    wrapper_box: ?*c.GtkWidget = null,
    titlebar_box: ?*c.GtkWidget = null,
    titlebar_label: ?*c.GtkLabel = null,
    titlebar_visible: bool = false,
    titlebar_active: bool = false,
    /// User-locked title — when true, on_title sink drops incoming
    /// OSC 0/1/2 updates so the manual string sticks. Cleared via
    /// the menu's "Set Pane Title…" → empty input.
    title_locked: bool = false,
    /// Latest OSC 0/1/2 title text. Owned; freed in deinit.
    titlebar_text: ?[]u8 = null,

    /// Optional group name. When the Window's groupsend mode is `.group`,
    /// keystrokes typed in any pane with the same group name are
    /// fanned out across the group. Owned by the Window (Config arena).
    group: ?[]const u8 = null,
    /// Optional profile name. When set, Window.spawnShellPaneOpts uses
    /// the profile's overrides for shell, scheme, font_size, etc.
    /// Owned by the Window (Config arena).
    active_profile: ?[]const u8 = null,

    /// argv the PTY child was spawned with, deep-copied. Layout save
    /// reads this so a round-trip keeps the real command (`ssh host`,
    /// `nvim .`) instead of collapsing every pane to $SHELL. Owned;
    /// freed in deinit.
    spawn_argv: ?[][]u8 = null,

    /// Inactive-pane dimming. When `is_focused` is false, the FINAL
    /// composited pane is uniformly darkened (`inactive_darken`) and
    /// optionally desaturated (`inactive_desaturate`) by a post-
    /// process step — preserving every fg/bg colour relationship,
    /// unlike a per-cell multiply. 0/0 = no dim.
    is_focused: bool = false,
    inactive_darken: f32 = 0.2,
    inactive_desaturate: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator, terminal: *Terminal) !*Pane {
        const self = try allocator.create(Pane);
        errdefer allocator.destroy(self);

        const area_widget = c.gtk_gl_area_new();
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
        // Widget → Pane back-pointer for tree walks that only have
        // the GTK side (tab transfer between windows adopts panes by
        // walking the page's widget tree).
        c.g_object_set_data(@ptrCast(@alignCast(area_widget)), "sketerm-pane", @ptrCast(self));

        // Titlebar header: hidden by default. The label has 6 px
        // horizontal padding so text doesn't sit flush against the
        // window edge; the wrapping box gets CSS classes for active
        // / inactive colouring (resolved by Window-level provider).
        const tb_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_add_css_class(tb_box, "sketerm-titlebar");
        c.gtk_widget_add_css_class(tb_box, "sketerm-titlebar-inactive");
        c.gtk_widget_set_visible(tb_box, 0);
        const tb_label_w = c.gtk_label_new("Terminal");
        c.gtk_widget_add_css_class(tb_label_w, "sketerm-titlebar-label");
        c.gtk_label_set_xalign(@ptrCast(@alignCast(tb_label_w)), 0.0);
        c.gtk_label_set_ellipsize(@ptrCast(@alignCast(tb_label_w)), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_hexpand(tb_label_w, 1);
        c.gtk_widget_set_margin_start(tb_label_w, 6);
        c.gtk_widget_set_margin_end(tb_label_w, 6);
        c.gtk_widget_set_margin_top(tb_label_w, 1);
        c.gtk_widget_set_margin_bottom(tb_label_w, 1);
        c.gtk_box_append(@ptrCast(tb_box), tb_label_w);

        // Click on the titlebar to focus the underlying GLArea so
        // typing immediately reaches that pane.
        const tb_click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(tb_click), 1);
        _ = c.g_signal_connect_data(
            tb_click,
            "pressed",
            @ptrCast(&onTitlebarClicked),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.gtk_widget_add_controller(tb_box, @ptrCast(tb_click));

        // Wrap the GLArea in a GtkGraphicsOffload (GTK ≥ 4.16). The
        // offload widget tells GTK4 to attach our rendered output as
        // a Wayland subsurface with a dmabuf, bypassing GSK's
        // offscreen-FBO + composite step. Without this, the FBO blit
        // + GTK chrome composite holds the GPU after every frame,
        // and our next `glBufferData` stalls 5-8 ms on the implicit
        // sync — visible as sluggish menu hover whenever content
        // updates. Maintainer reference + the chain that makes this
        // work for GLArea specifically: the GTK 4.16 release added
        // dmabuf export to GLArea so offload can pass-through.
        //
        // black_background=true draws a solid black under the
        // offloaded subsurface — avoids the brief transparency flash
        // on first realise while the dmabuf is still being attached.
        // ENABLED forces the offload path even when GTK can't fully
        // verify the offload is safe (fall-through is automatic if
        // the compositor or driver actually rejects it).
        //
        // Verify this is hitting the fast path with `GDK_DEBUG=offload`
        // — every frame logs either an offload success or the reason
        // it fell back (CSS effects, overlapping siblings, etc.).
        const offload = c.gtk_graphics_offload_new(area_widget);
        c.gtk_graphics_offload_set_enabled(@ptrCast(offload), c.GTK_GRAPHICS_OFFLOAD_ENABLED);
        c.gtk_graphics_offload_set_black_background(@ptrCast(offload), 1);
        c.gtk_widget_set_vexpand(offload, 1);
        c.gtk_widget_set_hexpand(offload, 1);

        // Wrapper that holds [titlebar][offload(GLArea)] vertically.
        // We make the wrapper the publicly-exposed widget so splits /
        // layout restore reparent the whole stack rather than just
        // the area.
        const wrap = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrap, 1);
        c.gtk_widget_set_vexpand(wrap, 1);
        c.gtk_box_append(@ptrCast(wrap), tb_box);
        c.gtk_box_append(@ptrCast(wrap), offload);

        self.* = .{
            .area = @ptrCast(area_widget),
            .terminal = terminal,
            .grid_pass = GridPass.init(allocator),
            .cell_pass = CellPass.init(allocator),
            .image_store = ImageStore.init(allocator),
            .menu_arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .wrapper_box = wrap,
            .titlebar_box = tb_box,
            .titlebar_label = @ptrCast(@alignCast(tb_label_w)),
        };

        // Pane is the Terminal's user_ctx for ALL sink callbacks.
        // Pane dispatches: image → its own store, clipboard/title →
        // forwarded to Window if its sinks are set.
        terminal.user_ctx = @ptrCast(self);
        terminal.on_image = onImageEvent;
        terminal.on_image_delete_full = onImageDeleteFullEvent;
        terminal.on_title = onTitleEvent;
        terminal.on_cwd_changed = onCwdEvent;
        terminal.on_clipboard_set = onClipboardEvent;
        terminal.on_clipboard_get = onClipboardGetEvent;
        terminal.on_render_request = onRenderRequest;
        terminal.on_notification = onNotificationEvent;
        terminal.on_progress = onProgressEvent;
        terminal.on_bell = onBellEvent;
        terminal.on_pointer_shape = onPointerShapeEvent;
        terminal.on_session_renamed = onSessionRenamedEvent;

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
        // pane's program / VAOs / VBOs / textures leak into the
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

        // Tick is installed on demand via ensureTickRunning. It
        // self-removes when no time-driven work is active. First
        // install happens here so the cold-start cursor settles in
        // and any early animation events are picked up.
        self.ensureTickRunning();

        // M4: keyboard input → PTY (also handles shortcuts).
        self.input_ctx = try input.attach(area_widget, terminal, allocator);
        if (self.input_ctx) |ictx| {
            ictx.autohide_ctx = @ptrCast(self);
            ictx.autohide_set = setCursorHiddenSink;
        }

        // Resize → TIOCSWINSZ → SIGWINCH child.
        _ = c.g_signal_connect_data(
            area_widget,
            "resize",
            @ptrCast(&onResize),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Mouse-wheel scroll → adjust view_offset.
        const scroll_ctrl = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
        _ = c.g_signal_connect_data(
            scroll_ctrl,
            "scroll",
            @ptrCast(&onScroll),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.gtk_widget_add_controller(area_widget, @ptrCast(scroll_ctrl));

        // Left-button drag → selection (and ctrl-click on links).
        const drag = c.gtk_gesture_drag_new();
        c.gtk_gesture_single_set_button(@ptrCast(drag), 1);
        _ = c.g_signal_connect_data(drag, "drag-begin", @ptrCast(&onDragBegin), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drag, "drag-update", @ptrCast(&onDragUpdate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drag, "drag-end", @ptrCast(&onDragEnd), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(drag));

        // Right-click → context menu. Allocations go into menu_arena
        // so they're freed when the pane is destroyed.
        try menu.attachWithPrePopup(area_widget, self.menu_arena.allocator(), paneMenuSink, @ptrCast(self), paneMenuPrePopup, @ptrCast(self));

        // Mouse reporting (DECSET 1006). Click controller covers
        // press / release for any button; emits the SGR sequence
        // when mouse_mode is enabled by the shell-side app.
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0); // any button
        _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onMousePressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(click, "released", @ptrCast(&onMouseReleased), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(click));

        // Mouse motion → hover tooltip for OSC 8 hyperlinks.
        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(
            motion,
            "motion",
            @ptrCast(&onMotion),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.gtk_widget_add_controller(area_widget, @ptrCast(motion));
        c.gtk_widget_set_has_tooltip(area_widget, 1);

        // File drag & drop → paste shell-quoted path(s). Accepts file
        // lists from file managers and plain text as fallback.
        const drop = c.gtk_drop_target_new(c.G_TYPE_INVALID, @intCast(c.GDK_ACTION_COPY));
        var drop_types = [_]c.GType{ c.gdk_file_list_get_type(), c.G_TYPE_STRING };
        c.gtk_drop_target_set_gtypes(drop, &drop_types, drop_types.len);
        _ = c.g_signal_connect_data(drop, "drop", @ptrCast(&onFileDrop), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(drop));

        // Focus reporting (DECSET 1004). Apps that opt in get
        // \x1b[I on enter, \x1b[O on leave.
        const focus = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(focus, "enter", @ptrCast(&onFocusEnter), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(focus, "leave", @ptrCast(&onFocusLeave), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(focus));

        // Becoming visible again (tab switched back) must restart the
        // tick: an animating shader self-removes it while unmapped, so
        // nothing else would resume the animation.
        _ = c.g_signal_connect_data(area_widget, "map", @ptrCast(&onAreaMap), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        return self;
    }

    fn handleMenuLocal(self: *Pane, action: menu.Action) bool {
        switch (action) {
            .copy => {
                if (!self.terminal.screen.selection.isActive()) return true;
                const text = self.terminal.screen.extractSelection(self.allocator) catch return true;
                defer self.allocator.free(text);
                if (text.len == 0) return true;
                const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return true;
                defer self.allocator.free(cstr);
                @memcpy(cstr, text);
                const display = c.gtk_widget_get_display(@ptrCast(self.area));
                const clip = c.gdk_display_get_clipboard(display);
                c.gdk_clipboard_set_text(clip, cstr.ptr);
                if (self.clear_select_on_copy) {
                    self.terminal.screen.selection.clear();
                    self.terminal.screen.dirty = true;
                    c.gtk_gl_area_queue_render(@ptrCast(self.area));
                }
                return true;
            },
            .paste => {
                clipboard.pasteFromClipboard(@ptrCast(self.area), self.terminal);
                return true;
            },
            .copy_output => {
                const maybe = self.terminal.screen.extractLastCommandOutput(self.allocator) catch return true;
                const text = maybe orelse return true;
                defer self.allocator.free(text);
                if (text.len == 0) return true;
                const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return true;
                defer self.allocator.free(cstr);
                @memcpy(cstr, text);
                const display = c.gtk_widget_get_display(@ptrCast(self.area));
                const clip = c.gdk_display_get_clipboard(display);
                c.gdk_clipboard_set_text(clip, cstr.ptr);
                return true;
            },
            .reset_terminal => {
                self.terminal.screen.fullReset();
                return true;
            },
            .copy_link => {
                const uri = self.menu_link_uri orelse return true;
                if (uri.len == 0) return true;
                const cstr = self.allocator.allocSentinel(u8, uri.len, 0) catch return true;
                defer self.allocator.free(cstr);
                @memcpy(cstr, uri);
                const display = c.gtk_widget_get_display(@ptrCast(self.area));
                const clip = c.gdk_display_get_clipboard(display);
                c.gdk_clipboard_set_text(clip, cstr.ptr);
                return true;
            },
            else => return false,
        }
    }

    /// Wired into input.zig's autohide_set. Lets onKeyPressed flip
    /// Pane.cursor_hidden without input.zig importing pane.zig.
    fn setCursorHiddenSink(ctx: ?*anyopaque, hidden: bool) void {
        const self = cast.userData(Pane, ctx);
        self.cursor_hidden = hidden;
    }

    /// Push the current focus / dim settings into the renderer. Called
    /// on focus change AND when dim factors change via prefs. The dim
    /// is a uniform post-process (shader_pass), not a per-cell
    /// multiply — so the cell/grid dim uniforms stay neutral.
    pub fn applyDim(self: *Pane) void {
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
        // redraw — applyDim runs during early pane setup too, when
        // self.area isn't a realizable GL area yet.
    }

    /// Push the current selection to PRIMARY (always, for middle-
    /// click paste) and optionally to the SYSTEM clipboard
    /// (`copy_on_selection`). No-op when the selection is empty.
    fn pushSelectionToClipboards(self: *Pane) void {
        const screen = self.terminal.screen;
        if (!screen.selection.isActive()) return;
        const text = screen.extractSelection(self.allocator) catch return;
        defer self.allocator.free(text);
        if (text.len == 0) return;
        const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return;
        defer self.allocator.free(cstr);
        @memcpy(cstr, text);
        clipboard.copyToPrimary(@ptrCast(self.area), cstr);
        if (self.copy_on_selection) {
            clipboard.copyToClipboard(@ptrCast(self.area), cstr);
        }
    }

    pub const CellPos = struct { row: i32, col: i32 };

    /// Map widget pixel coords to a Screen selection coordinate.
    /// Returns the VISUAL column (left-to-right pixel order). Callers
    /// that need a LOGICAL column (selection storage on bidi rows)
    /// should use `cellAtLogical`.
    ///
    /// GTK gesture/motion events report widget-local LOGICAL pixels
    /// (pre-HiDPI). The cell grid + `pad` live in PHYSICAL framebuffer
    /// pixels (atlas measures cells via `FT_Set_Pixel_Sizes`, GL
    /// viewport uses `widget_size * scale_factor`). Scale up the
    /// pointer coords first so the divide is unit-consistent — without
    /// this, clicks on HiDPI displays land 1/scale of the way to the
    /// intended cell.
    fn cellAt(self: *Pane, x: f64, y: f64) CellPos {
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
    fn cellAtLogical(self: *Pane, x: f64, y: f64) CellPos {
        const c0 = self.cellAt(x, y);
        if (!self.grid_pass.enable_bidi or c0.col < 0) return c0;
        const logical_col: u16 = self.terminal.screen.visualToLogicalCol(
            self.allocator,
            c0.row,
            @intCast(c0.col),
        );
        return .{ .col = @intCast(logical_col), .row = c0.row };
    }

    pub fn deinit(self: *Pane) void {
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
        if (self.input_ctx) |ictx| {
            // Disconnect every signal handler we connected with `ctx`
            // as user-data, then drop the IM context's ref. Without
            // this, fcitx5 / ibus may still emit `commit` or
            // `preedit-changed` against the freed Ctx (we're not the
            // sole owner of the IM context's lifetime — the GTK IM
            // module routes events asynchronously through D-Bus).
            // Also leaks one GtkIMMulticontext (and its inner D-Bus
            // name watch) per closed pane, which is what we're
            // really fixing here.
            if (ictx.im_ctx) |im| {
                // Disconnect every handler we attached with `ictx` as
                // user_data. `g_signal_handlers_disconnect_by_data`
                // is a macro in glib; spell out the underlying call
                // because the cImport translation of the macro form
                // loses the gpointer target types.
                const im_obj: ?*anyopaque = @ptrCast(im);
                const ictx_data: ?*anyopaque = @ptrCast(ictx);
                _ = c.g_signal_handlers_disconnect_matched(
                    im_obj,
                    c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    null,
                    ictx_data,
                );
                c.gtk_im_context_set_client_widget(@ptrCast(im), null);
                c.g_object_unref(im_obj);
            }
            self.allocator.destroy(ictx);
        }
        if (self.menu_link_uri) |uri| self.allocator.free(uri);
        if (self.titlebar_text) |t| self.allocator.free(t);
        self.freeSpawnArgv();
        self.menu_arena.deinit();
        self.allocator.destroy(self);
    }

    fn freeSpawnArgv(self: *Pane) void {
        if (self.spawn_argv) |av| {
            for (av) |a| self.allocator.free(a);
            self.allocator.free(av);
            self.spawn_argv = null;
        }
    }

    /// Record the child's argv (NUL-terminated form, as handed to
    /// Pty.spawn). Best-effort: on OOM the pane simply keeps no argv
    /// and layout save falls back to $SHELL.
    pub fn setSpawnArgv(self: *Pane, argv: []const [*:0]const u8) void {
        self.freeSpawnArgv();
        const out = self.allocator.alloc([]u8, argv.len) catch return;
        for (argv, 0..) |a, i| {
            out[i] = self.allocator.dupe(u8, std.mem.span(a)) catch {
                for (out[0..i]) |s| self.allocator.free(s);
                self.allocator.free(out);
                return;
            };
        }
        self.spawn_argv = out;
    }

    pub fn widget(self: *Pane) *c.GtkWidget {
        if (self.wrapper_box) |w| return w;
        return @ptrCast(self.area);
    }

    /// Build an Atlas at the pane's current size. Resolution order:
    /// explicit file path → family name via fontconfig → $SKETERM_FONT
    /// → built-in candidate list. Returns null when nothing loads.
    fn createAtlas(self: *Pane) ?*Atlas {
        const a = self.createAtlasInner() orelse return null;
        if (self.font_features) |spec| a.setFontFeatures(spec);
        return a;
    }

    fn createAtlasInner(self: *Pane) ?*Atlas {
        const size: u16 = self.physicalFontSize();
        if (self.font_path) |fp| {
            if (self.tryAtlasPath(fp, size)) |a| return a;
        }
        if (self.font_family) |fam| {
            if (@import("../render/atlas.zig").resolveFamilyPath(self.allocator, fam)) |path| {
                defer self.allocator.free(path);
                if (Atlas.initOpts(self.allocator, path.ptr, size, self.line_pad_px)) |a| {
                    return a;
                } else |_| {}
            }
        }
        if (@import("../util/profile.zig").getenv("SKETERM_FONT")) |env_path| {
            if (self.tryAtlasPath(env_path, size)) |a| return a;
        }
        for (FONT_CANDIDATES) |path| {
            if (Atlas.initOpts(self.allocator, path, size, self.line_pad_px)) |a| {
                return a;
            } else |_| continue;
        }
        return null;
    }

    fn tryAtlasPath(self: *Pane, fp: []const u8, size: u16) ?*Atlas {
        const z = self.allocator.allocSentinel(u8, fp.len, 0) catch return null;
        defer self.allocator.free(z);
        @memcpy(z, fp);
        return Atlas.initOpts(self.allocator, z.ptr, size, self.line_pad_px) catch null;
    }

    /// Install the frame-clock tick callback if it isn't already
    /// running. Cheap idempotent — can be called from event handlers
    /// without checking state. Triggers that start time-driven work
    /// (focus-in with blinking cursor, bell event, image arrival
    /// with animation) call this so the tick is alive to pump.
    pub fn ensureTickRunning(self: *Pane) void {
        if (self.tick_id != 0) return;
        self.tick_id = c.gtk_widget_add_tick_callback(
            @ptrCast(self.area),
            @ptrCast(&onTick),
            @ptrCast(self),
            null,
        );
    }

    /// Re-arm rendering after a custom_shader config change: queue a
    /// frame (recompile happens lazily in onRender) and make sure the
    /// tick is alive so animation can self-sustain via `dirty`.
    pub fn updateShaderTick(self: *Pane) void {
        self.ensureTickRunning();
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Set (or clear, with null) this pane's own shader. Reads the
    /// file immediately; a same-path call only refreshes `animate`.
    /// `user_pick` marks the choice as explicit so profile/config
    /// pushes won't overwrite it. Returns false when the file could
    /// not be read (pane falls back to the window default).
    pub fn setCustomShader(self: *Pane, path: ?[]const u8, animate: bool, user_pick: bool) bool {
        // Setting a real shader cancels an explicit clear.
        if (path != null) self.shader_cleared = false;
        if (path == null and self.custom_shader_path == null) return true;
        if (path) |p| if (self.custom_shader_path) |cur| {
            if (std.mem.eql(u8, p, cur)) {
                self.shader_own.animate = animate;
                if (user_pick) self.custom_shader_user = true;
                self.updateShaderTick();
                return true;
            }
        };

        // Drop the old own shader.
        if (self.shader_own_src) |s| self.allocator.free(s);
        if (self.custom_shader_path) |s| self.allocator.free(s);
        if (self.shader_own_dir) |d| self.allocator.free(d);
        self.shader_own_src = null;
        self.custom_shader_path = null;
        self.shader_own_dir = null;
        self.shader_own.src = null;
        self.shader_own.dir = null;
        self.custom_shader_user = false;

        var ok = true;
        if (path) |p| read: {
            var path_z: [4096]u8 = undefined;
            if (p.len >= path_z.len) {
                ok = false;
                break :read;
            }
            @memcpy(path_z[0..p.len], p);
            path_z[p.len] = 0;
            const fp = c.fopen(@ptrCast(&path_z), "rb") orelse {
                std.debug.print("sketerm: pane shader not readable: {s}\n", .{p});
                ok = false;
                break :read;
            };
            defer _ = c.fclose(fp);
            const buf = self.allocator.alloc(u8, 256 * 1024) catch {
                ok = false;
                break :read;
            };
            const n = c.fread(buf.ptr, 1, buf.len, fp);
            if (n == 0) {
                self.allocator.free(buf);
                ok = false;
                break :read;
            }
            self.shader_own_src = self.allocator.realloc(buf, n) catch buf[0..n];
            self.shader_own.src = self.shader_own_src;
            self.custom_shader_path = self.allocator.dupe(u8, p) catch null;
            // Shader-relative //@texture paths resolve against this.
            if (std.fs.path.dirname(p)) |d| {
                self.shader_own_dir = self.allocator.dupe(u8, d) catch null;
                self.shader_own.dir = self.shader_own_dir;
            }
            self.custom_shader_user = user_pick;
        }
        self.shader_own.animate = animate;
        self.shader_own.generation +%= 1;
        self.refreshShaderBinding();
        self.updateShaderTick();
        return ok;
    }

    /// Point the GL pass at the pane's own shader when one is
    /// loaded, at nothing when the user explicitly cleared it, else
    /// at the window-level default.
    pub fn refreshShaderBinding(self: *Pane) void {
        if (self.shader_own.src != null) {
            self.shader_pass.source = &self.shader_own;
        } else if (self.shader_cleared) {
            self.shader_pass.source = null;
        } else {
            self.shader_pass.source = self.shader_default_source;
        }
    }

    /// Bind a shader preset's params to this pane: own copies of the
    /// values, and `shader_own.overrides` re-pointed at them so the
    /// preset tunes THIS pane only. Call after setCustomShader
    /// succeeded for the preset's shader path.
    pub fn applyShaderPresetParams(self: *Pane, name: []const u8, params: []const ShaderParamKV) void {
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

    /// Whether the pane owns its shader-param override slice (bound
    /// preset, or an unbound-but-kept per-pane set after a preset
    /// delete). Window's config repoints must skip such panes.
    pub fn hasOwnShaderParams(self: *const Pane) bool {
        return self.preset_name != null or self.preset_params.items.len > 0;
    }

    /// Forget the preset NAME but keep the per-pane param values —
    /// used when the preset file is deleted out from under the pane.
    pub fn unbindPresetName(self: *Pane) void {
        if (self.preset_name) |n| self.allocator.free(n);
        self.preset_name = null;
    }

    /// Set/update one param in this pane's per-pane override set
    /// (live — values upload each frame). No-op when the pane rides
    /// the global config params.
    pub fn setPresetParam(self: *Pane, name: []const u8, value: f32, color: ?[3]f32) void {
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
    /// shader_params slice the pane falls back to.
    pub fn dropShaderPreset(self: *Pane, global_overrides: []const ShaderParamKV) void {
        self.freePresetData();
        self.shader_own.overrides = global_overrides;
    }

    fn freePresetData(self: *Pane) void {
        if (self.preset_name) |n| self.allocator.free(n);
        self.preset_name = null;
        for (self.preset_params.items) |p| self.allocator.free(p.name);
        self.preset_params.clearRetainingCapacity();
    }

    /// Explicitly turn this pane's shader off (sticky). Picking a
    /// shader later un-clears it.
    pub fn clearShader(self: *Pane) void {
        // Drop any pane-owned shader first.
        _ = self.setCustomShader(null, self.shader_own.animate, false);
        self.shader_cleared = true;
        self.custom_shader_user = false;
        self.refreshShaderBinding();
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }

    /// Set the per-pane title bar text. Called from the on_title sink
    /// when the running shell emits an OSC 0/1/2 escape. Idempotent
    /// when the new text matches the cached value. The label is set
    /// even if the bar is hidden — it'll display when revealed.
    /// Drops the call when `title_locked` is set so the user's manual
    /// override sticks across subsequent OSC updates.
    pub fn setTitle(self: *Pane, text: []const u8) void {
        if (self.title_locked) return;
        self.applyTitle(text);
    }

    /// Internal: same as setTitle but bypasses the lock. Used by
    /// `lockTitle` so the manual string is applied at lock time.
    fn applyTitle(self: *Pane, text: []const u8) void {
        if (self.titlebar_text) |old| {
            if (std.mem.eql(u8, old, text)) return;
            self.allocator.free(old);
        }
        self.titlebar_text = self.allocator.dupe(u8, text) catch null;
        const lbl = self.titlebar_label orelse return;
        const z = self.allocator.allocSentinel(u8, text.len, 0) catch return;
        defer self.allocator.free(z);
        @memcpy(z, text);
        c.gtk_label_set_text(lbl, z.ptr);
    }

    /// Lock the title bar to a manual string. Subsequent OSC 0/1/2
    /// updates are dropped until `unlockTitle` is called.
    pub fn lockTitle(self: *Pane, text: []const u8) void {
        self.applyTitle(text);
        self.title_locked = true;
    }

    /// Resume tracking incoming OSC 0/1/2 titles. The current label
    /// stays as-is until the next OSC update arrives.
    pub fn unlockTitle(self: *Pane) void {
        self.title_locked = false;
    }

    /// Show / hide the per-pane title bar.
    pub fn setTitlebarVisible(self: *Pane, visible: bool) void {
        const tb = self.titlebar_box orelse return;
        if (self.titlebar_visible == visible) return;
        self.titlebar_visible = visible;
        c.gtk_widget_set_visible(tb, if (visible) 1 else 0);
    }

    /// Toggle active / inactive CSS class on the title bar. The
    /// Window-level CSS provider supplies the actual rgba colours.
    pub fn setTitlebarActive(self: *Pane, active: bool) void {
        const tb = self.titlebar_box orelse return;
        if (self.titlebar_active == active) return;
        self.titlebar_active = active;
        if (active) {
            c.gtk_widget_remove_css_class(tb, "sketerm-titlebar-inactive");
            c.gtk_widget_add_css_class(tb, "sketerm-titlebar-active");
        } else {
            c.gtk_widget_remove_css_class(tb, "sketerm-titlebar-active");
            c.gtk_widget_add_css_class(tb, "sketerm-titlebar-inactive");
        }
    }

    /// Convert a point size (Pane.font_size, the user-facing config
    /// value) to PHYSICAL framebuffer pixels honouring the widget's
    /// HiDPI scale factor. FreeType + the cell grid both work in
    /// physical pixels — feed it the result of this. Without the
    /// scale_factor multiply the same point size renders tiny on
    /// HiDPI surfaces because GTK reports logical CSS pixels and we'd
    /// be sizing cells as if 1 logical px == 1 device px.
    fn physicalFontSize(self: *const Pane) u16 {
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
    pub fn setFontSize(self: *Pane, new_size: u16) void {
        if (new_size == self.font_size) return;
        self.font_size = new_size;
        self.refreshFont();
    }

    /// Rebuild the atlas against the pane's CURRENT font fields
    /// (size, path, family, line padding). Used by setFontSize and by
    /// applyConfigChange when the font selection changed at the same
    /// size.
    pub fn refreshFont(self: *Pane) void {
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

        // The atlas was just rebuilt: every glyph UV cached in the
        // passes points into the dead texture. The fresh atlas starts
        // at generation 0 — same as the passes' last-seen generations —
        // so eviction detection won't fire; force the rebuild here.
        // Without this, an unchanged grid renders stale/blank glyphs
        // until each line happens to go dirty on its own.
        self.cell_pass.markAllDirty();
        self.grid_pass.vbuf_valid = false;
        self.grid_pass.vbo_uploaded = false;
        for (self.grid_pass.row_caches_valid.items) |*r| r.* = false;

        self.image_store.cell_w = @floatFromInt(self.atlas.?.cell_w);
        self.image_store.cell_h = @floatFromInt(self.atlas.?.cell_h);
        // Sync to Screen so CSI 14t/16t reports use the new metrics
        // without waiting for the next window resize.
        self.terminal.screen.cell_pixel_w = self.atlas.?.cell_w;
        self.terminal.screen.cell_pixel_h = self.atlas.?.cell_h;

        // Force a SIGWINCH on the child — terminal winsize in cells
        // changes when the cell size changes. Widget size is logical
        // CSS pixels; cell metrics are framebuffer pixels — multiply
        // by scale_factor to compare in the same space.
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

        self.terminal.screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
    }
};

fn onUnrealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
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
        self.image_store.forgetGL();
        return;
    }
    self.grid_pass.releaseGL();
    self.cell_pass.releaseGL();
    self.image_pass.releaseGL();
    self.bg_pass.releaseGL();
    self.shader_pass.releaseGL();
    self.image_store.releaseGL();
    if (self.atlas) |a| a.releaseGL();
}

fn onRealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
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
    // and gives us a fresh one on the next realize. Drop every
    // cached GL handle so the realize path below actually rebuilds
    // them — without this, grid_pass.realize() returns early on
    // `program != 0` and we'd glUseProgram a dead ID.
    if (self.atlas) |old| {
        old.deinit();
        self.atlas = null;
    }
    self.grid_pass.forgetGL();
    self.cell_pass.forgetGL();
    self.image_pass.forgetGL();
    self.bg_pass.forgetGL();
    self.shader_pass.forgetGL();
    self.image_store.forgetGL();

    // Resolution order: explicit Pane.font_path → Pane.font_family
    // (fontconfig) → $SKETERM_FONT env → built-in candidate list.
    // Size from Pane.font_size (set by Config or Ctrl+/Ctrl-).
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

fn onRender(area: *c.GtkGLArea, _: *c.GdkGLContext, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Pane, user);
    const atlas = self.atlas orelse return @intFromBool(false);
    const profile = @import("../util/profile.zig");
    const t_total = if (profile.enabled) profile.nanoTimestamp() else 0;

    const w = c.gtk_widget_get_width(@ptrCast(area));
    const h = c.gtk_widget_get_height(@ptrCast(area));
    const scale = c.gtk_widget_get_scale_factor(@ptrCast(area));
    const phys_w: c_int = w * scale;
    const phys_h: c_int = h * scale;

    // Custom-shader detour: render the whole scene into an offscreen
    // texture; finish() maps it through the user shader at the end.
    // When there's no custom shader but the pane is inactive (dim
    // requested), take the same offscreen path for a dim-only post.
    const shader_on = self.shader_pass.active() and
        self.shader_pass.begin(self.allocator, phys_w, phys_h);
    const dim_on = !shader_on and self.shader_pass.beginDim(self.allocator, phys_w, phys_h);

    c.glViewport(0, 0, phys_w, phys_h);
    c.glClearColor(self.grid_pass.default_bg[0], self.grid_pass.default_bg[1], self.grid_pass.default_bg[2], self.grid_pass.default_bg[3]);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    self.grid_pass.canvas_w = @floatFromInt(phys_w);
    self.grid_pass.canvas_h = @floatFromInt(phys_h);

    // Background layer (gradient / image) — under everything,
    // including kitty below-text images.
    self.bg_pass.draw(phys_w, phys_h);

    // is_focused is kept in sync by onFocusEnter/onFocusLeave;
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
        self.image_pass.drawZ(&self.image_store, phys_w, phys_h, .below);
        if (profile.enabled) img_ns += @intCast(profile.nanoTimestamp() - t_img);
    }

    const t_cell_draw = if (profile.enabled) profile.nanoTimestamp() else 0;
    self.cell_pass.draw(atlas, phys_w, phys_h);
    if (profile.enabled) profile.record(.cell_draw, @intCast(profile.nanoTimestamp() - t_cell_draw));
    // Overlay pipeline (per-vertex VBO) — cursor, selection, focus
    // border, scrollback indicator, preedit, bell, and any rows that
    // need bidi reorder or DH/DW per-line scaling.
    const t_grid_build = if (profile.enabled) profile.nanoTimestamp() else 0;
    self.grid_pass.buildVertices(self.terminal.screen, &self.terminal.pool, atlas, focused, cells_changed, rebuilt_rows) catch return @intFromBool(false);
    if (profile.enabled) profile.record(.grid_build, @intCast(profile.nanoTimestamp() - t_grid_build));
    const t_grid_draw = if (profile.enabled) profile.nanoTimestamp() else 0;
    self.grid_pass.draw(atlas, phys_w, phys_h);
    if (profile.enabled) profile.record(.grid_draw, @intCast(profile.nanoTimestamp() - t_grid_draw));

    // Foreground images (z >= 0).
    {
        const t_img = if (profile.enabled) profile.nanoTimestamp() else 0;
        self.image_pass.drawZ(&self.image_store, phys_w, phys_h, .above);
        if (profile.enabled) img_ns += @intCast(profile.nanoTimestamp() - t_img);
    }
    if (shader_on) {
        const now_us = c.g_get_monotonic_time();
        if (self.shader_epoch_us == 0) self.shader_epoch_us = now_us;
        const time_s: f32 = @as(f32, @floatFromInt(now_us - self.shader_epoch_us)) / 1e6;
        self.shader_pass.finish(phys_w, phys_h, time_s);
    } else if (dim_on) {
        self.shader_pass.finishDim(phys_w, phys_h);
    }

    if (profile.enabled) {
        profile.record(.image_pass, img_ns);
        profile.record(.onrender_total, @intCast(profile.nanoTimestamp() - t_total));
    }

    return @intFromBool(true);
}

fn onImageEvent(ctx: ?*anyopaque, img: Screen.ImageEvent) void {
    const self = cast.userData(Pane, ctx);
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
    }) catch |err| {
        std.debug.print("sketerm: image_store.addFull failed (id={d}): {s}\n", .{ img.image_id, @errorName(err) });
    };
    // Force redraw to upload + display. Set dirty so onTick paints AND
    // queue_draw directly so we don't have to wait a frame.
    self.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
    // Image arrival may include an animation; ensure tick is up to
    // pump frames if the idle path had stopped it.
    self.ensureTickRunning();
}

fn onImageDeleteFullEvent(ctx: ?*anyopaque, ev: @import("../grid/screen.zig").Screen.ImageDeleteEvent) void {
    const self = cast.userData(Pane, ctx);
    // Kitty `d=` semantics. Lowercase leaves data on disk, uppercase
    // also frees it. We don't distinguish on free behaviour — every
    // delete tears down the GL texture on the next flush.
    switch (ev.what) {
        'a', 'A' => self.image_store.markAllForDelete(),
        'i', 'I' => {
            if (ev.image_id != 0) self.image_store.markByIdForDelete(ev.image_id);
        },
        'p', 'P' => {
            if (ev.image_id != 0) self.image_store.markByPlacementForDelete(ev.image_id, ev.placement_id);
        },
        // 'n','N' (image_number), 'r','R' (z-range), 'x','y','c'
        // (coordinates), 'z','Z' (z-index): not yet implemented.
        // Fallback: if we have an image_id, scope the delete to that
        // image; otherwise leave images alone rather than nuke all.
        else => {
            if (ev.image_id != 0) {
                if (ev.placement_id != 0)
                    self.image_store.markByPlacementForDelete(ev.image_id, ev.placement_id)
                else
                    self.image_store.markByIdForDelete(ev.image_id);
            }
        },
    }
    self.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
}

fn onTitleEvent(ctx: ?*anyopaque, title: []const u8) void {
    const self = cast.userData(Pane, ctx);
    self.setTitle(title);
    if (self.win_on_title) |f| f(self.win_title_ctx, self, title);
}

fn onCwdEvent(ctx: ?*anyopaque, cwd: []const u8) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_cwd) |f| f(self.win_cwd_ctx, self, cwd);
}

/// Drain finished a batch with screen.dirty set — schedule a GL
/// render now instead of waiting for the next frame's tick to
/// notice. Also clears the dirty flag so the tick path doesn't
/// queue a redundant render this frame.
fn onRenderRequest(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    self.terminal.screen.dirty = false;
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
}

fn onClipboardEvent(ctx: ?*anyopaque, text: []const u8) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_clipboard) |f| f(self.win_clip_ctx, text);
}

/// OSC 52 read query (config-gated upstream). GDK clipboard reads
/// are async; the reply ctx rides the terminal's DrainHandle so a
/// pane/terminal teardown between request and callback is detected
/// instead of dereferenced.
const ClipReadCtx = struct {
    allocator: std.mem.Allocator,
    drain: *DrainHandle,
    selection: u8,
};

fn onClipboardGetEvent(ctx: ?*anyopaque, selection: u8) void {
    const self = cast.userData(Pane, ctx);
    const display = c.gtk_widget_get_display(@ptrCast(self.area));
    const clip = if (selection == 'p')
        c.gdk_display_get_primary_clipboard(display)
    else
        c.gdk_display_get_clipboard(display);
    const rctx = self.allocator.create(ClipReadCtx) catch return;
    rctx.* = .{
        .allocator = self.allocator,
        .drain = self.terminal.drain,
        .selection = selection,
    };
    c.gdk_clipboard_read_text_async(clip, null, @ptrCast(&onClipReadDone), @ptrCast(rctx));
}

fn onClipReadDone(source: ?*c.GObject, res: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const rctx: *ClipReadCtx = @ptrCast(@alignCast(user.?));
    defer rctx.allocator.destroy(rctx);
    const text_c = c.gdk_clipboard_read_text_finish(@ptrCast(@alignCast(source)), res, null);
    defer if (text_c != null) c.g_free(text_c);
    if (!rctx.drain.alive.load(.acquire)) return;
    const term = rctx.drain.terminal orelse return;

    var text: []const u8 = if (text_c != null)
        std.mem.span(@as([*:0]const u8, @ptrCast(text_c)))
    else
        "";
    // Bound the reply: the response flows through the PTY input
    // path; cap mirrors the 1 MB write-side limit.
    if (text.len > 1_000_000) text = text[0..1_000_000];

    const enc_len = std.base64.standard.Encoder.calcSize(text.len);
    const buf = rctx.allocator.alloc(u8, enc_len + 16) catch return;
    defer rctx.allocator.free(buf);
    var w: usize = 0;
    const head = std.fmt.bufPrint(buf[0..16], "\x1b]52;{c};", .{rctx.selection}) catch return;
    w += head.len;
    const b64 = std.base64.standard.Encoder.encode(buf[w .. w + enc_len], text);
    w += b64.len;
    buf[w] = 0x1b;
    buf[w + 1] = '\\';
    w += 2;
    term.writeRaw(buf[0..w]);
}

fn onProgressEvent(ctx: ?*anyopaque, state: u8, percent: u8) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_progress) |f| f(self.win_progress_ctx, self, state, percent);
}

fn onNotificationEvent(ctx: ?*anyopaque, ev: Screen.NotificationEvent) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_notification) |f| f(self.win_notify_ctx, self, ev);
}

fn onSessionRenamedEvent(ctx: ?*anyopaque, name: []const u8) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_session_renamed) |f| f(self.win_session_rename_ctx, self, name);
}

fn onBellEvent(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_bell) |f| f(self.win_bell_ctx, self);
    // Visual bell flash fades over 200ms — tick must be alive to
    // drive the fade. Idle path may have stopped it.
    self.ensureTickRunning();
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
}

/// OSC 22 — set the GTK pointer (mouse cursor) shape over this pane.
/// Empty name → restore default. Names are X cursor identifiers like
/// "default", "hand2", "watch", "crosshair", "text".
fn onPointerShapeEvent(ctx: ?*anyopaque, name: []const u8) void {
    const self = cast.userData(Pane, ctx);
    if (name.len == 0) {
        c.gtk_widget_set_cursor(@ptrCast(self.area), null);
        return;
    }
    // Need a NUL-terminated copy for gtk_widget_set_cursor_from_name.
    var buf: [64]u8 = undefined;
    if (name.len >= buf.len) return;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    c.gtk_widget_set_cursor_from_name(@ptrCast(self.area), &buf);
}

const appendShellQuoted = @import("../util/shellquote.zig").appendQuoted;

fn onFileDrop(_: *c.GtkDropTarget, value: [*c]const c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Pane, user);

    if (c.g_type_check_value_holds(value, c.gdk_file_list_get_type()) != 0) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        const flist: ?*c.GdkFileList = @ptrCast(c.g_value_get_boxed(value));
        // get_files is transfer-container: free the list, not the GFiles.
        const files = c.gdk_file_list_get_files(flist);
        defer c.g_slist_free(files);
        var node = files;
        while (node != null) : (node = node.*.next) {
            const gfile: ?*c.GFile = @ptrCast(node.*.data);
            const path_c = c.g_file_get_path(gfile);
            if (path_c == null) continue; // non-local URI (e.g. sftp://)
            defer c.g_free(path_c);
            if (out.items.len > 0) out.append(self.allocator, ' ') catch return 0;
            const path = std.mem.span(@as([*:0]const u8, @ptrCast(path_c)));
            appendShellQuoted(&out, self.allocator, path) catch return 0;
        }
        if (out.items.len == 0) return 0;
        // Trailing space so the user can keep typing arguments.
        out.append(self.allocator, ' ') catch return 0;
        clipboard.pasteText(self.terminal, out.items);
        _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
        return 1;
    }

    if (c.g_type_check_value_holds(value, c.G_TYPE_STRING) != 0) {
        const s = c.g_value_get_string(value);
        if (s == null) return 0;
        const txt = std.mem.span(@as([*:0]const u8, @ptrCast(s)));
        if (txt.len == 0) return 0;
        clipboard.pasteText(self.terminal, txt);
        _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
        return 1;
    }

    return 0;
}

test "appendShellQuoted passes safe paths bare, quotes the rest" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    try appendShellQuoted(&out, a, "/home/user/file.txt");
    try std.testing.expectEqualStrings("/home/user/file.txt", out.items);

    out.clearRetainingCapacity();
    try appendShellQuoted(&out, a, "/tmp/my file (1).png");
    try std.testing.expectEqualStrings("'/tmp/my file (1).png'", out.items);

    out.clearRetainingCapacity();
    try appendShellQuoted(&out, a, "/tmp/it's.txt");
    try std.testing.expectEqualStrings("'/tmp/it'\\''s.txt'", out.items);
}

fn onTick(area: *c.GtkWidget, _: *c.GdkFrameClock, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Pane, user);
    const screen = self.terminal.screen;

    // PTY child exited — fire the once-per-exit callback so Window
    // can act per exit_action. Clear flag immediately so subsequent
    // ticks don't re-fire (Window may close the pane mid-call).
    if (screen.child_exited) {
        screen.child_exited = false;
        self.tick_id = 0;
        if (self.win_on_child_exit) |f| f(self.win_child_ctx, self, screen.child_exit_status);
        // The exit callback may have torn the pane down (exit_action
        // .close); `self` is potentially freed. Returning CONTINUE
        // would re-enter next frame on dangling memory.
        return 0; // G_SOURCE_REMOVE
    }

    // Cursor blink — toggle every 500ms for blinking shapes, but
    // only on the focused pane. Unfocused panes always show a static
    // (hollow) cursor and don't waste redraws toggling phase.
    const now = @import("../util/profile.zig").microTimestamp();
    if (self.last_blink_us == 0) self.last_blink_us = now;
    // Use the cached is_focused — saves a GTK round-trip on every
    // tick. Updated by onFocusEnter/Leave handlers.
    const focused = self.is_focused;
    const blinking = focused and switch (screen.cursor_shape) {
        .block_blink, .underline_blink, .bar_blink => true,
        else => false,
    };
    const elapsed = now - self.last_blink_us;
    if (blinking and elapsed > self.cursor_blink_us) {
        self.last_blink_us = now;
        screen.cursor_blink_on = !screen.cursor_blink_on;
        screen.dirty = true;
    } else if (!focused and !screen.cursor_blink_on) {
        // Coming back into focus from a mid-blink "off" phase would
        // leave the cursor invisible until the next toggle. Snap on.
        screen.cursor_blink_on = true;
        screen.dirty = true;
    }

    // Keep redrawing while bell flash is fading.
    if (screen.bell_at_us > 0) {
        const since_bell = now - screen.bell_at_us;
        if (since_bell < 200_000) screen.dirty = true;
    }

    // Custom-shader animation: redraw every frame so iTime advances —
    // but only while the pane is actually on screen. A pane on a
    // background tab is unmapped; animating it would burn GPU for
    // pixels nobody sees (and GTK may still tick it briefly during
    // tab transitions). Tying this to visibility, not focus, keeps
    // side-by-side splits animating in lockstep.
    const shader_animating = shaderAnimates(self) and c.gtk_widget_get_mapped(@ptrCast(self.area)) != 0;
    if (shader_animating) screen.dirty = true;

    // Animation: advance frames in the kitty-graphics manager. When
    // any image stepped to a new frame, pull its bytes into the
    // matching placements so the next render shows the new frame.
    if (screen.kitty_images.advanceAnimations(now)) {
        var it = screen.kitty_images.store.iterator();
        while (it.next()) |entry| {
            const img = entry.value_ptr;
            if (img.frames.items.len < 2) continue;
            self.image_store.uploadFrame(entry.key_ptr.*, img.generation, img.rgba) catch |err| {
                std.debug.print("sketerm: image_store.uploadFrame failed (id={d}): {s}\n", .{ entry.key_ptr.*, @errorName(err) });
            };
        }
        screen.dirty = true;
    }

    // Synchronized-output mode (DECSET 2026): suppress redraws so the
    // running app can stage a multi-step screen update and have it
    // appear atomically. The `dirty` flag stays set; we'll redraw
    // when the app sends DECRST 2026.
    if (screen.dirty and screen.sync_output) return 1;

    if (screen.dirty) {
        // Update IME cursor location so fcitx5 / ibus position
        // their popups at the right cell. Only fire when the cursor
        // ACTUALLY moved — `gtk_im_context_set_cursor_location` can
        // hop into IBus/fcitx via D-Bus / Wayland IPC, which is too
        // expensive to do on every dirty redraw.
        if (self.input_ctx) |ictx| if (ictx.im_ctx) |im| if (self.atlas) |atlas| {
            const cur_row: i32 = screen.row;
            const cur_col: i32 = screen.col;
            if (cur_row != self.last_im_row or cur_col != self.last_im_col) {
                self.last_im_row = cur_row;
                self.last_im_col = cur_col;
                var rect = c.GdkRectangle{
                    .x = cur_col * @as(c_int, atlas.cell_w),
                    .y = cur_row * @as(c_int, atlas.cell_h),
                    .width = atlas.cell_w,
                    .height = atlas.cell_h,
                };
                c.gtk_im_context_set_cursor_location(im, &rect);
            }
        };

        screen.dirty = false;
        c.gtk_gl_area_queue_render(@ptrCast(area));
    }

    // Self-remove when no time-driven work is active: with the
    // drain → render direct dispatch, the tick is only needed for
    // cursor blink, bell flash fade, and kitty-graphics animation.
    // Triggers (focus-in, bell, image-arrival) call ensureTickRunning
    // to put us back. Idle multi-pane setups drop to ~0% CPU here.
    const has_blink_work = blinking;
    const has_bell_work = screen.bell_at_us > 0 and (now - screen.bell_at_us) < 200_000;
    const has_anim_work = blk: {
        var it = screen.kitty_images.store.iterator();
        while (it.next()) |e| {
            const img = e.value_ptr;
            if (img.frames.items.len >= 2 and img.playing) break :blk true;
        }
        break :blk false;
    };
    // An animating shader on a visible pane is time-driven work too —
    // without this the tick self-removed the moment the pane lost
    // focus (cursor blink stopped keeping it alive) and the shader
    // froze. Goes idle on its own when the pane is unmapped.
    if (!has_blink_work and !has_bell_work and !has_anim_work and !shader_animating) {
        self.tick_id = 0;
        return 0; // G_SOURCE_REMOVE
    }
    return 1; // G_SOURCE_CONTINUE
}

/// Whether the pane's effective shader requests per-frame animation.
fn shaderAnimates(self: *Pane) bool {
    if (!self.shader_pass.active()) return false;
    const src = self.shader_pass.source orelse return false;
    return src.animate;
}

fn onAreaMap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    if (shaderAnimates(self)) self.updateShaderTick();
}

fn paneMenuSink(ctx: ?*anyopaque, action: menu.Action) void {
    const self = cast.userData(Pane, ctx);
    if (self.handleMenuLocal(action)) return;
    if (self.menu_sink) |f| f(self.menu_sink_ctx, action);
}

/// Called just before the right-click context menu pops up. We
/// inspect the cell under the click for an OSC 8 link, and toggle
/// the `term.copy-link` action's enabled state accordingly.
fn paneMenuPrePopup(ctx: ?*anyopaque, group: *c.GSimpleActionGroup, x: f64, y: f64) bool {
    const self = cast.userData(Pane, ctx);
    const screen = self.terminal.screen;

    // Right-click rebound away from the menu: run the bound action
    // instead (only when the running app isn't consuming the mouse;
    // with mouse_mode on, the click already reached it via SGR 1006).
    if (self.right_click_action != .menu) {
        if (screen.mouse_mode == 0) {
            switch (self.right_click_action) {
                .paste_primary => clipboard.pastePrimaryFromClipboard(@ptrCast(self.area), self.terminal),
                .paste_clipboard => clipboard.pasteFromClipboard(@ptrCast(self.area), self.terminal),
                .menu, .none => {},
            }
        }
        return false;
    }

    // "Copy Command Output" greys out until a completed OSC 133
    // command zone is reachable.
    if (c.g_action_map_lookup_action(@ptrCast(group), "copy-output")) |act| {
        const avail = self.terminal.screen.lastCommandOutputAvailable();
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(avail));
    }

    // Mux session rows (detach / rename / kill) only make sense on a
    // remote pane; menu.zig hides the rows of disabled mux actions.
    const is_remote = self.terminal.remote != null;
    for ([_][*:0]const u8{ "mux-detach", "mux-rename", "mux-kill" }) |name| {
        if (c.g_action_map_lookup_action(@ptrCast(group), name)) |act| {
            c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(is_remote));
        }
    }

    // Free any URI captured from a previous popup.
    if (self.menu_link_uri) |old| {
        self.allocator.free(old);
        self.menu_link_uri = null;
    }

    var has_link = false;
    const cell = self.cellAt(x, y);
    if (cell.col >= 0 and cell.col < screen.cols) {
        // cellAt's row can be negative when the click landed in
        // scrollback. Resolve via lineCellsAt (negative rows index
        // scrollback from the bottom).
        const cells_at = screen.lineCellsAtPub(cell.row);
        if (cells_at) |cells| {
            // Bidi remap: cellAt returns the *visual* column. For
            // mixed/RTL rows, the logical cell at that visual col
            // may be different. Resolve via fribidi when the row
            // contains any non-ASCII codepoint.
            var logical_col: usize = @intCast(cell.col);
            if (self.grid_pass.enable_bidi) {
                var any_non_ascii = false;
                for (cells) |rc| {
                    if (rc.rune > 0x7F) {
                        any_non_ascii = true;
                        break;
                    }
                }
                if (any_non_ascii) {
                    const bidi = @import("../grid/bidi.zig");
                    // One allocation, three views. Stack-buffer fast
                    // path covers typical row widths (<~630 cols);
                    // wider rows fall back to the heap.
                    var stack_buf: [8192]u8 align(@alignOf(usize)) = undefined;
                    const need_bytes =
                        cells.len * @sizeOf(usize) +
                        cells.len * @sizeOf(u32) +
                        cells.len * @sizeOf(u8);
                    var heap_buf: ?[]align(@alignOf(usize)) u8 = null;
                    defer if (heap_buf) |hb| self.allocator.free(hb);
                    var got_buf: bool = true;
                    const buf: []align(@alignOf(usize)) u8 = if (need_bytes <= stack_buf.len)
                        stack_buf[0..need_bytes]
                    else blk: {
                        const hb = self.allocator.alignedAlloc(u8, .of(usize), need_bytes) catch {
                            got_buf = false;
                            break :blk stack_buf[0..0];
                        };
                        heap_buf = hb;
                        break :blk hb;
                    };
                    if (got_buf) {
                        // Largest alignment first (usize), then u32,
                        // then u8 — keeps each view properly aligned.
                        var off: usize = 0;
                        const idx_bytes: []align(@alignOf(usize)) u8 = @alignCast(buf[off .. off + cells.len * @sizeOf(usize)]);
                        const idx_buf = std.mem.bytesAsSlice(usize, idx_bytes);
                        off += cells.len * @sizeOf(usize);
                        const cps_bytes: []align(@alignOf(u32)) u8 = @alignCast(buf[off .. off + cells.len * @sizeOf(u32)]);
                        const cps_buf = std.mem.bytesAsSlice(u32, cps_bytes);
                        off += cells.len * @sizeOf(u32);
                        const lvls_buf = buf[off .. off + cells.len];
                        for (cells, 0..) |rc, i| {
                            cps_buf[i] = if (rc.rune == 0) ' ' else rc.rune;
                            idx_buf[i] = i;
                        }
                        _ = bidi.lineLevels(cps_buf, lvls_buf, .auto);
                        bidi.levelsToVisualOrder(lvls_buf, idx_buf);
                        const v: usize = @intCast(cell.col);
                        if (v < idx_buf.len) logical_col = idx_buf[v];
                    }
                }
            }
            if (logical_col < cells.len) {
                const c_cell = cells[logical_col];
                if (c_cell.flags & 0b0000_0100 != 0) {
                    if (screen.linkUri(c_cell.reserved)) |uri| {
                        if (self.allocator.dupe(u8, uri)) |copy| {
                            self.menu_link_uri = copy;
                            has_link = true;
                        } else |_| {}
                    }
                }
            }
        }
    }

    if (c.g_action_map_lookup_action(@ptrCast(group), "copy-link")) |act| {
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), if (has_link) 1 else 0);
    }
    return true;
}

/// Click on the per-pane title bar. Focuses the underlying GLArea
/// so the running shell receives keystrokes — without this, clicking
/// the bar would just trap focus on the (un-focusable) Box.
fn onTitlebarClicked(_: *c.GtkGestureClick, n_press: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
    // Double-click → dispatch the menu's `set_pane_title` action
    // (same path as the right-click "Set Pane Title…" entry).
    if (n_press == 2) {
        paneMenuSink(@ptrCast(self), .set_pane_title);
    }
}

fn onFocusEnter(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    if (self.terminal.screen.focus_reports) {
        self.terminal.writeRaw("\x1b[I");
    }
    // Tell the IM context this widget owns focus. Required for both:
    // (1) dead-key state tracking in the simple IM module
    // (2) Wayland text-input-v3 enable (compositor only routes
    //     composed text to enabled clients). GtkEventControllerKey
    //     does NOT auto-fire focus_in/out — GtkText/GtkEntry call
    //     it from their own focus handlers; we have to do the same.
    if (self.input_ctx) |ictx| if (ictx.im_ctx) |im| {
        c.gtk_im_context_focus_in(im);
    };
    // Cursor style + focus border switch on focus change — force a
    // repaint so the swap is immediate.
    self.terminal.screen.cursor_blink_on = true;
    self.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
    // Per-pane titlebar: red (active) when this pane has focus.
    self.setTitlebarActive(true);
    // Inactive-pane dimming: full brightness now.
    self.is_focused = true;
    self.applyDim();
    // Tick may have self-removed while idle. Cursor blink starts now.
    self.ensureTickRunning();
}

fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    if (self.terminal.screen.focus_reports) {
        self.terminal.writeRaw("\x1b[O");
    }
    if (self.input_ctx) |ictx| if (ictx.im_ctx) |im| {
        c.gtk_im_context_focus_out(im);
    };
    self.terminal.screen.cursor_blink_on = true;
    self.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
    // Per-pane titlebar: grey (inactive) when focus leaves.
    self.setTitlebarActive(false);
    // Inactive-pane dimming: apply the configured factors.
    self.is_focused = false;
    self.applyDim();
}

fn onMotion(g: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);

    // Restore the cursor if mouse_autohide hid it on the last keystroke.
    if (self.cursor_hidden) {
        self.cursor_hidden = false;
        c.gtk_widget_set_cursor(@ptrCast(self.area), null);
    }

    const cell = self.cellAt(x, y);
    const screen = self.terminal.screen;

    // Mouse-motion reporting:
    //   DECSET 1003 = any motion
    //   DECSET 1002 = motion only while a button is held
    // Suppress duplicates within the same cell.
    if (cell.row >= 0 and cell.col >= 0) {
        const want_motion =
            (screen.mouse_mode == 1003) or
            (screen.mouse_mode == 1002 and self.held_button >= 0);
        if (want_motion and
            (cell.row != self.last_motion_row or cell.col != self.last_motion_col))
        {
            self.last_motion_row = cell.row;
            self.last_motion_col = cell.col;
            // Button bits: 32=motion, base 0=L,1=M,2=R or 3=no-button.
            var base: u32 = if (self.held_button >= 0)
                @intCast(self.held_button)
            else
                3;
            // Modifier bits (SGR 1006): +4 shift, +8 alt, +16 ctrl.
            const ev = c.gtk_event_controller_get_current_event(@ptrCast(g));
            if (ev != null) {
                const mods = c.gdk_event_get_modifier_state(ev);
                if (mods & c.GDK_SHIFT_MASK != 0) base += 4;
                if (mods & c.GDK_ALT_MASK != 0) base += 8;
                if (mods & c.GDK_CONTROL_MASK != 0) base += 16;
            }
            writeMouseEvent(self,32 + base, @as(u32, @intCast(cell.col + 1)), @as(u32, @intCast(cell.row + 1)), x, y, true);
        }
    }

    // Hyperlink hover tooltip + pointer cursor — OSC 8 first, then
    // auto-detected URL. Cursor flips to "pointer" while over a link
    // and back to default on leave (gnome-terminal / kitty convention).
    var over_link = false;
    if (cell.row >= 0 and cell.col >= 0 and
        cell.row < screen.rows and cell.col < screen.cols)
    {
        const c_row: u16 = @intCast(cell.row);
        const c_col: u16 = @intCast(cell.col);
        const cell_data = screen.cellAt(c_row, c_col);
        if (cell_data.flags & 0b0000_0100 != 0) {
            if (screen.linkUri(cell_data.reserved)) |uri| {
                var buf: [4096]u8 = undefined;
                const n = @min(uri.len, buf.len - 1);
                @memcpy(buf[0..n], uri[0..n]);
                buf[n] = 0;
                c.gtk_widget_set_tooltip_text(@ptrCast(self.area), &buf);
                over_link = true;
            }
        }
        if (!over_link and self.grid_pass.enable_url_underline) {
            if (screen.urlAtVisible(self.allocator, @intCast(c_row), @intCast(c_col)) catch null) |url| {
                defer self.allocator.free(url);
                const max = @min(url.len, 4095);
                var buf: [4096]u8 = undefined;
                @memcpy(buf[0..max], url[0..max]);
                buf[max] = 0;
                c.gtk_widget_set_tooltip_text(@ptrCast(self.area), &buf);
                over_link = true;
            }
        }
    }
    if (!over_link) c.gtk_widget_set_tooltip_text(@ptrCast(self.area), null);

    // Cursor shape flip — only on transitions, not every motion event,
    // to avoid hammering gtk_widget_set_cursor with redundant calls.
    if (over_link and !self.cursor_over_link) {
        c.gtk_widget_set_cursor_from_name(@ptrCast(self.area), "pointer");
        self.cursor_over_link = true;
    } else if (!over_link and self.cursor_over_link) {
        c.gtk_widget_set_cursor(@ptrCast(self.area), null);
        self.cursor_over_link = false;
    }
}

fn onDragBegin(g: *c.GtkGestureDrag, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    // Always grab focus on click.
    _ = c.gtk_widget_grab_focus(@ptrCast(self.area));

    // Read modifiers up-front — Shift overrides app-level mouse
    // tracking (xterm/kitty/gnome-terminal convention).
    var mods: c.GdkModifierType = 0;
    const ev = c.gtk_event_controller_get_current_event(@ptrCast(g));
    if (ev != null) mods = c.gdk_event_get_modifier_state(ev);
    const shift_held = (mods & c.GDK_SHIFT_MASK) != 0;
    const alt_held = (mods & c.GDK_ALT_MASK) != 0;

    // App captures the mouse (e.g. tmux mouse-mode, vim/htop):
    // forward the click as a mouse report unless Shift is held.
    // Without this, host-side selection is impossible inside a
    // tmux/mosh session.
    if (self.terminal.screen.mouse_mode != 0 and !shift_held) {
        if (self.terminal.screen.selection.isActive()) {
            self.terminal.screen.selection.clear();
            self.terminal.screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(self.area));
        }
        return;
    }

    // On the alternate screen (TUIs like vim, htop, less), the
    // running app owns the mouse model — host-side selection is
    // usually noise. Require Shift to override (matches xterm /
    // gnome-terminal / kitty conventions). Wipe any leftover
    // selection from the main screen so the user doesn't see a
    // ghost highlight.
    if (self.terminal.screen.use_alt and !shift_held) {
        if (self.terminal.screen.selection.isActive()) {
            self.terminal.screen.selection.clear();
            self.terminal.screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(self.area));
        }
        return;
    }

    const cell = self.cellAtLogical(x, y);
    const mode: @import("../grid/selection.zig").Mode = if (alt_held) .rectangular else .normal;
    self.terminal.screen.selection.start(cell.row, cell.col, mode);
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
}

fn onMousePressed(g: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    const button = c.gtk_gesture_single_get_current_button(@ptrCast(g));

    // Middle-click PRIMARY paste when the running app isn't asking
    // for mouse reports. With mouse_mode > 0 the app sees the click.
    // `disable_mouse_paste` opts out of this entirely.
    if (button == 2 and self.terminal.screen.mouse_mode == 0) {
        if (self.disable_mouse_paste) return;
        switch (self.middle_click_action) {
            .paste_primary => clipboard.pastePrimaryFromClipboard(@ptrCast(self.area), self.terminal),
            .paste_clipboard => clipboard.pasteFromClipboard(@ptrCast(self.area), self.terminal),
            .menu, .none => {},
        }
        return;
    }

    // Gutter click — a single left click in the left padding strip
    // on a row inside an OSC 133 command zone selects that command's
    // whole output (line-wise) and primes PRIMARY, Warp-block style.
    if (button == 1 and self.terminal.screen.mouse_mode == 0 and n_press == 1 and
        !self.terminal.screen.use_alt)
    {
        const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.area)));
        if (x * scale < @as(f64, @floatCast(self.grid_pass.pad))) {
            const cell = self.cellAt(x, y);
            if (self.terminal.screen.selectCmdZoneAt(cell.row)) {
                self.pushSelectionToClipboards();
                c.gtk_gl_area_queue_render(@ptrCast(self.area));
                return;
            }
        }
    }

    // Left double / triple click → word / line selection.
    if (button == 1 and self.terminal.screen.mouse_mode == 0 and n_press >= 2) {
        // On alt screen (TUIs), host-side selection is opt-in via
        // Shift. Same rule as drag selection — keeps the running
        // app's mouse model uncontested.
        var mods_d: c.GdkModifierType = 0;
        const ev_d = c.gtk_event_controller_get_current_event(@ptrCast(g));
        if (ev_d != null) mods_d = c.gdk_event_get_modifier_state(ev_d);
        const shift_d = (mods_d & c.GDK_SHIFT_MASK) != 0;
        if (self.terminal.screen.use_alt and !shift_d) {
            if (self.terminal.screen.selection.isActive()) {
                self.terminal.screen.selection.clear();
                self.terminal.screen.dirty = true;
                c.gtk_gl_area_queue_render(@ptrCast(self.area));
            }
            return;
        }

        const cell = self.cellAtLogical(x, y);
        const screen = self.terminal.screen;
        if (n_press == 2) {
            screen.selectWordAt(cell.row, cell.col);
        } else { // 3+
            screen.selectLineAt(cell.row);
        }
        // Push the new selection text to PRIMARY for middle-click
        // paste; also to SYSTEM clipboard if copy_on_selection is on.
        self.pushSelectionToClipboards();
        c.gtk_gl_area_queue_render(@ptrCast(self.area));
        return;
    }

    if (self.terminal.screen.mouse_mode == 0) return;
    // Shift-bypass: a Shift-held click belongs to the host
    // (selection / link follow), not the running app.
    if (shiftHeld(@ptrCast(g))) return;
    emitMouseSeq(self, g, x, y, true);
}

fn onMouseReleased(g: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    if (self.terminal.screen.mouse_mode == 0) return;
    if (shiftHeld(@ptrCast(g))) return;
    emitMouseSeq(self, g, x, y, false);
}

fn shiftHeld(g: *c.GtkEventController) bool {
    const ev = c.gtk_event_controller_get_current_event(g);
    if (ev == null) return false;
    return (c.gdk_event_get_modifier_state(ev) & c.GDK_SHIFT_MASK) != 0;
}

fn emitMouseSeq(self: *Pane, g: *c.GtkGestureClick, x: f64, y: f64, press: bool) void {
    const button_raw = c.gtk_gesture_single_get_current_button(@ptrCast(g));
    if (button_raw == 0) return;
    // Map GTK button numbers (1=L, 2=M, 3=R) to xterm button bits
    // (0=L, 1=M, 2=R per SGR 1006).
    var xterm_button: i32 = switch (button_raw) {
        1 => 0,
        2 => 1,
        3 => 2,
        else => return,
    };
    if (press) {
        self.held_button = xterm_button;
    } else if (self.held_button == xterm_button) {
        self.held_button = -1;
    }
    // Encode modifiers per xterm SGR 1006: +4 shift, +8 meta/alt, +16 ctrl.
    const ev = c.gtk_event_controller_get_current_event(@ptrCast(g));
    if (ev != null) {
        const mods = c.gdk_event_get_modifier_state(ev);
        if (mods & c.GDK_SHIFT_MASK != 0) xterm_button += 4;
        if (mods & c.GDK_ALT_MASK != 0) xterm_button += 8;
        if (mods & c.GDK_CONTROL_MASK != 0) xterm_button += 16;
    }
    const cell = self.cellAt(x, y);
    if (cell.row < 0 or cell.col < 0) return;
    writeMouseEvent(self,@intCast(xterm_button), @intCast(cell.col + 1), @intCast(cell.row + 1), x, y, press);
}

/// Encode a single mouse event using the screen's currently-active
/// encoding flavour and write it back to the PTY. Cell coords are
/// 1-based; pixel coords are widget-local pixels (used by
/// DECSET 1016 only). `press=true` is press / motion / wheel;
/// `press=false` is button release (only emitted by SGR/SGR-pixel).
fn writeMouseEvent(self: *Pane, button: u32, col_1: u32, row_1: u32, px_x: f64, px_y: f64, press: bool) void {
    const screen = self.terminal.screen;
    const px_x_u: u32 = @intFromFloat(@max(@as(f64, 0), px_x));
    const px_y_u: u32 = @intFromFloat(@max(@as(f64, 0), px_y));
    var buf: [64]u8 = undefined;
    switch (screen.mouse_enc) {
        .sgr => {
            const final: u8 = if (press) 'M' else 'm';
            const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ button, col_1, row_1, final }) catch return;
            self.terminal.writeRaw(seq);
        },
        .sgr_pixel => {
            const final: u8 = if (press) 'M' else 'm';
            const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ button, px_x_u, px_y_u, final }) catch return;
            self.terminal.writeRaw(seq);
        },
        .urxvt => {
            // urxvt: ESC [ b+32 ; col ; row M  — releases not distinct;
            // apps reading 1015 expect a press-shaped event with
            // button = 3 + modifier bits when buttons go up.
            const b: u32 = if (press) button else 3 | (button & 0x1C);
            const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d};{d}M", .{ b + 32, col_1, row_1 }) catch return;
            self.terminal.writeRaw(seq);
        },
        .legacy => {
            const cb_val: u32 = if (press) button + 32 else (3 | (button & 0x1C)) + 32;
            const cx_clamp: u32 = @min(col_1 + 32, 255);
            const cy_clamp: u32 = @min(row_1 + 32, 255);
            const out = [_]u8{
                0x1B, '[', 'M',
                @intCast(@min(cb_val, 0xFF)),
                @intCast(cx_clamp),
                @intCast(cy_clamp),
            };
            self.terminal.writeRaw(&out);
        },
        .utf8 => {
            const cb_val: u32 = if (press) button + 32 else (3 | (button & 0x1C)) + 32;
            var off: usize = 0;
            buf[off] = 0x1B;
            off += 1;
            buf[off] = '[';
            off += 1;
            buf[off] = 'M';
            off += 1;
            buf[off] = @intCast(@min(cb_val, 0xFF));
            off += 1;
            off += encodeUtf8Cp(buf[off..], col_1 + 32);
            off += encodeUtf8Cp(buf[off..], row_1 + 32);
            self.terminal.writeRaw(buf[0..off]);
        },
    }
}

/// Minimal UTF-8 encoder for mouse-mode 1005. Codepoints up to
/// 0x7FF need 2 bytes; >0x7FF (very wide windows) need 3.
fn encodeUtf8Cp(out: []u8, cp: u32) usize {
    if (cp < 0x80) {
        if (out.len < 1) return 0;
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        if (out.len < 2) return 0;
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        if (out.len < 3) return 0;
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    return 0;
}

fn onDragUpdate(g: *c.GtkGestureDrag, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    var sx: f64 = 0;
    var sy: f64 = 0;
    _ = c.gtk_gesture_drag_get_start_point(g, &sx, &sy);
    const cell = self.cellAtLogical(sx + dx, sy + dy);
    self.terminal.screen.selection.extend(cell.row, cell.col);
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
}

fn onDragEnd(g: *c.GtkGestureDrag, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);

    // Tiny drags = a click. If Ctrl was held and the click landed on
    // a hyperlinked cell, launch its URI.
    const moved = @abs(dx) > 4 or @abs(dy) > 4;
    if (moved) {
        // Real drag: push the selection text to PRIMARY so middle-click
        // paste works (Linux convention); also to SYSTEM clipboard if
        // copy_on_selection is on.
        self.pushSelectionToClipboards();
        return;
    }

    // Ctrl+click hyperlink launch — but ONLY when the running app
    // isn't capturing the mouse (mouse_mode 1000+). Otherwise we'd
    // hijack a click that the app expected to receive.
    if (self.terminal.screen.mouse_mode != 0) return;

    const event = c.gtk_event_controller_get_current_event(@ptrCast(g));
    if (event == null) return;
    const mods = c.gdk_event_get_modifier_state(event);
    // Plain click activates links when `link_single_click` is set;
    // otherwise require Ctrl.
    if (!self.link_single_click and (mods & c.GDK_CONTROL_MASK) == 0) return;

    var sx: f64 = 0;
    var sy: f64 = 0;
    _ = c.gtk_gesture_drag_get_start_point(g, &sx, &sy);
    const cell = self.cellAt(sx, sy);
    if (cell.row < 0 or cell.col < 0) return;
    const screen = self.terminal.screen;
    if (cell.row >= screen.rows or cell.col >= screen.cols) return;
    const cell_data = screen.cellAt(@intCast(cell.row), @intCast(cell.col));

    // OSC 8 hyperlink — preferred path when the cell carries one.
    if (cell_data.flags & 0b0000_0100 != 0) {
        if (screen.linkUri(cell_data.reserved)) |uri| {
            var buf: [4096]u8 = undefined;
            const n = @min(uri.len, buf.len - 1);
            @memcpy(buf[0..n], uri[0..n]);
            buf[n] = 0;
            _ = c.g_app_info_launch_default_for_uri(&buf, null, null);
            return;
        }
    }

    // No OSC 8 — fall back to the auto-URL detector.
    if (!self.grid_pass.enable_url_underline) return;
    const url = (screen.urlAtVisible(self.allocator, cell.row, cell.col) catch null) orelse return;
    defer self.allocator.free(url);
    var buf: [4096]u8 = undefined;
    const n = @min(url.len, buf.len - 1);
    @memcpy(buf[0..n], url[0..n]);
    buf[n] = 0;
    _ = c.g_app_info_launch_default_for_uri(&buf, null, null);
}

fn onScroll(g: *c.GtkEventControllerScroll, _: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Pane, user);
    const screen = self.terminal.screen;

    // Ctrl+wheel = font-size zoom (Terminator/gnome-terminal/iTerm
    // convention). Only active when not disabled and not currently
    // captured by a TUI's mouse model.
    if (!self.disable_mousewheel_zoom and screen.mouse_mode == 0) {
        const ev_z = c.gtk_event_controller_get_current_event(@ptrCast(g));
        if (ev_z != null) {
            const mods_z = c.gdk_event_get_modifier_state(ev_z);
            if (mods_z & c.GDK_CONTROL_MASK != 0) {
                if (dy < 0) {
                    self.setFontSize(@min(self.font_size + 1, 72));
                } else if (dy > 0) {
                    self.setFontSize(@max(self.font_size - 1, 6));
                }
                return 1;
            }
        }
    }

    // Apps in alt-screen + mouse mode (htop, vim, less, …) want
    // wheel events as mouse buttons 4 / 5. Send those instead of
    // adjusting the (irrelevant) scrollback view.
    if (screen.mouse_mode > 0 and screen.use_alt) {
        if (dy == 0) return 1;
        var button: u32 = if (dy < 0) 64 else 65; // 64 = btn4, 65 = btn5
        // Modifier bits: +4 shift, +8 alt, +16 ctrl.
        const ev = c.gtk_event_controller_get_current_event(@ptrCast(g));
        if (ev != null) {
            const mods = c.gdk_event_get_modifier_state(ev);
            if (mods & c.GDK_SHIFT_MASK != 0) button += 4;
            if (mods & c.GDK_ALT_MASK != 0) button += 8;
            if (mods & c.GDK_CONTROL_MASK != 0) button += 16;
        }
        const row: i32 = if (self.last_motion_row >= 0) self.last_motion_row else 0;
        const col: i32 = if (self.last_motion_col >= 0) self.last_motion_col else 0;
        const cw_px: f64 = if (self.atlas) |a| @floatFromInt(a.cell_w) else 0.0;
        const ch_px: f64 = if (self.atlas) |a| @floatFromInt(a.cell_h) else 0.0;
        const px = @as(f64, @floatFromInt(col)) * cw_px;
        const py = @as(f64, @floatFromInt(row)) * ch_px;
        writeMouseEvent(self,button, @as(u32, @intCast(col + 1)), @as(u32, @intCast(row + 1)), px, py, true);
        return 1;
    }

    // Smooth-scroll accumulator. Notched wheels (dy = ±1) still
    // scroll a full 3 lines per click — the accumulator just lets
    // touchpad / high-res wheels send fractional dy without each
    // micro-event flooring to a 3-line jump.
    const SCROLL_LINES_PER_NOTCH: f64 = 3.0;
    self.scroll_accum -= dy * SCROLL_LINES_PER_NOTCH; // up = positive view_offset
    const whole: f64 = @trunc(self.scroll_accum);
    self.scroll_accum -= whole;
    const delta_lines: i32 = @intFromFloat(whole);
    if (delta_lines == 0) return 1;

    const sb = screen.scrollbackCount();
    if (delta_lines > 0) {
        const want: u64 = @as(u64, @intCast(screen.view_offset)) + @as(u64, @intCast(delta_lines));
        screen.view_offset = if (want > sb) sb else @intCast(want);
    } else {
        const dec: u32 = @intCast(-delta_lines);
        screen.view_offset = if (screen.view_offset >= dec) screen.view_offset - dec else 0;
    }
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
    return 1;
}

fn onResize(_: *c.GtkGLArea, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
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
    // Resize reallocates the framebuffer; with auto_render off we
    // must explicitly schedule a repaint or the user sees stale
    // contents from the old size.
    c.gtk_gl_area_queue_render(@ptrCast(self.area));
}
