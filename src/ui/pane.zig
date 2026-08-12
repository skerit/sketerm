//! Pane — the interactive terminal workspace cell of a tab.
//!
//! Composes a `TerminalSurface` (the renderer: GtkGLArea + passes +
//! visual timers, see terminal_surface.zig) and adds everything
//! interactive around it: keyboard/mouse/paste/drop input, selection
//! and context menus, terminal session lifecycle + Window sinks,
//! titlebars/banners, the browser/editor/panel/app faces, and
//! split-pane tree participation.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const TerminalSurface = @import("terminal_surface.zig").TerminalSurface;
const ShaderParamKV = @import("../render/shader_pass.zig").ParamKV;
const scrollbar = @import("../render/scrollbar.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Terminal = @import("../terminal.zig").Terminal;
const DrainHandle = @import("../terminal.zig").DrainHandle;
const input = @import("input.zig");
const a11y = @import("../a11y/atspi.zig");
const platform = @import("../util/platform.zig");
const render_kick = @import("../util/render_kick.zig");
/// macOS NSAccessibility bridge. GTK4 has no NSAccessibility backend
/// (only AT-SPI, unavailable on macOS), so on macOS the pane's text
/// reaches VoiceOver by attaching an element to the window's GdkMacos
/// content NSView — `a11y` (atspi) does nothing there. On Linux this is
/// a no-op stub so nothing references the macOS-only shim/externs.
const nsax = if (platform.is_macos)
    @import("../a11y/nsax.zig")
else
    struct {
        pub fn contentView(_: *anyopaque) ?*anyopaque {
            return null;
        }
        pub fn attach(_: *anyopaque, _: *Terminal) ?*anyopaque {
            return null;
        }
        pub fn detach(_: *anyopaque, _: *anyopaque) void {}
        pub fn setFrameInParent(_: *anyopaque, _: f64, _: f64, _: f64, _: f64) void {}
        pub fn notifyChanged(_: *anyopaque) void {}
        pub fn selfCheck(_: *anyopaque, _: *anyopaque) c_int {
            return 0;
        }
    };
const menu = @import("menu.zig");
const clipboard = @import("clipboard.zig");
const MouseAction = @import("../config.zig").MouseAction;
pub const InputCtx = input.Ctx;
pub const MenuAction = menu.Action;

pub const FONT_CANDIDATES = @import("terminal_surface.zig").FONT_CANDIDATES;

/// The face an editor face displaced when it was raised. The panel
/// face is deliberately not tracked — it is never the thing an editor
/// is opened on top of, so it folds into `terminal`.
pub const PrevFace = enum { terminal, browser };

pub const Pane = struct {
    /// Stable monotonic id for remote-control addressing. Assigned
    /// by Window before the PTY spawn so the child env can carry it.
    id: u32 = 0,
    /// The terminal renderer: GtkGLArea + render passes + visual
    /// timers. Pane owns it by value (heap-stable inside this
    /// heap-allocated Pane) and drives it through its public API.
    surface: TerminalSurface,
    terminal: *Terminal,
    /// macOS only: the SketermTermAXElement exposing this pane's text to
    /// VoiceOver, and the GdkMacos content NSView it is attached to.
    /// Attached on map, detached on unmap/close. Opaque `NSObject *`.
    ax_element: ?*anyopaque = null,
    ax_content_view: ?*anyopaque = null,
    /// One-shot SKETERM_A11Y_SELFCHECK reporting guard.
    ax_selfcheck_done: bool = false,
    allocator: std.mem.Allocator,
    input_ctx: ?*input.Ctx = null,
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
    /// Forward remote file-transfer lifecycle (upload + download) so
    /// Window can drive the tab ring + a completion toast. Reuses
    /// win_progress_ctx.
    win_on_transfer: ?*const fn (ctx: ?*anyopaque, pane: *Pane, ev: Terminal.TransferEvent) void = null,
    /// Forward OSC 133 command lifecycle so Window can drive the tab
    /// status dot + finished notifications. Reuses win_progress_ctx.
    win_on_cmd_status: ?*const fn (ctx: ?*anyopaque, pane: *Pane, running: bool, exit: i32, duration_ms: i64) void = null,
    /// Forward OSC 7 cwd updates so Window can rewrite the tab tooltip.
    win_cwd_ctx: ?*anyopaque = null,
    win_on_cwd: ?*const fn (ctx: ?*anyopaque, pane: *Pane, cwd: []const u8) void = null,
    /// Forward the daemon-sampled foreground process name so Window
    /// can re-render a `{{ PROGRAM }}` title template. Reuses
    /// win_cwd_ctx — same owner, same lifetime.
    win_on_program: ?*const fn (ctx: ?*anyopaque, pane: *Pane, program: []const u8) void = null,
    /// Fires when a resize changed the pane's column/row COUNT, so a
    /// `{{ COLUMNS }}`/`{{ LINES }}` title can follow. Reuses
    /// win_cwd_ctx.
    win_on_geometry: ?*const fn (ctx: ?*anyopaque, pane: *Pane) void = null,
    /// Forward OSC 1337 ; SetProfile so Window can restyle this pane.
    win_setprofile_ctx: ?*anyopaque = null,
    win_on_set_profile: ?*const fn (ctx: ?*anyopaque, pane: *Pane, name: []const u8) void = null,
    /// Forward BEL events for tab-bar attention.
    win_bell_ctx: ?*anyopaque = null,
    win_child_ctx: ?*anyopaque = null,
    win_on_bell: ?*const fn (ctx: ?*anyopaque, pane: *Pane) void = null,
    /// Fired when this pane gains keyboard focus, so the Window can
    /// record it as its tab's last-focused pane (restored on tab switch).
    win_focus_ctx: ?*anyopaque = null,
    win_on_focus_enter: ?*const fn (ctx: ?*anyopaque, pane: *Pane) void = null,
    /// Fired when this pane's visible grid changed (tab-activity signal).
    win_activity_ctx: ?*anyopaque = null,
    win_on_activity: ?*const fn (ctx: ?*anyopaque, pane: *Pane) void = null,
    /// Fired exactly once when the PTY child exits. Window decides
    /// what to do (close pane / restart shell / hold).
    win_on_child_exit: ?*const fn (ctx: ?*anyopaque, pane: *Pane, status: i32) void = null,
    /// Fired when the session died unexpectedly (crash/OOM). Window shows the
    /// crashed-tab overlay (sad face + "Start new session").
    win_crash_ctx: ?*anyopaque = null,
    win_on_crashed: ?*const fn (ctx: ?*anyopaque, pane: *Pane) void = null,
    /// Forward mux session renames so Window can retitle the tab.
    win_session_rename_ctx: ?*anyopaque = null,
    win_on_session_renamed: ?*const fn (ctx: ?*anyopaque, pane: *Pane, name: []const u8) void = null,
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
    /// Set from wrapper_box's ::destroy. Pane.deinit is DEFERRED past
    /// GTK's widget-destroy chain, so teardown code (detachBrowser)
    /// can run after the widget tree is gone — this fence is what
    /// tells it the GtkWidget pointers above are no longer callable.
    widgets_dead: bool = false,
    /// File-browser face (src/ui/browser.zig): a second widget in the
    /// wrapper box, toggled against the GL area. The pane runs
    /// `browser_deinit(browser_ctx)` in detachBrowser — the browser's
    /// fd watch must never outlive the pane.
    browser_widget: ?*c.GtkWidget = null,
    browser_ctx: ?*anyopaque = null,
    browser_prepare_destroy: ?*const fn (*anyopaque) void = null,
    browser_deinit: ?*const fn (*anyopaque) void = null,
    /// Put GTK focus inside the browser face (its listing). Called
    /// whenever that face becomes the visible one.
    browser_focus: ?*const fn (*anyopaque) void = null,

    /// Editor face (src/ui/editorview.zig), same five-pointer contract
    /// and two-phase teardown as the browser face above.
    editor_widget: ?*c.GtkWidget = null,
    editor_ctx: ?*anyopaque = null,
    /// `widgets_dead` tells the face whether its widget subtree is
    /// still alive: the ordinary path (severFaces) calls it with the
    /// widgets up, the last-resort path from `Pane.deinit` calls it
    /// after GTK has already finalized them. Passing it is not
    /// optional — the editor face restores window-level shortcuts
    /// through its root widget, which is a use-after-free on the late
    /// path.
    editor_prepare_destroy: ?*const fn (*anyopaque, widgets_dead: bool) void = null,
    editor_deinit: ?*const fn (*anyopaque) void = null,
    editor_focus: ?*const fn (*anyopaque) void = null,
    /// Font-zoom hook for the editor face: font_inc/font_dec/
    /// font_reset (and Ctrl+wheel routed via Window) land here while
    /// that face is visible. delta is in points; reset=true returns to
    /// the prefs-resolved size and wins over delta. Set by the face
    /// AFTER attachEditor (not part of the shared five-pointer
    /// contract); cleared by detachEditor.
    editor_zoom: ?*const fn (*anyopaque, delta: i32, reset: bool) void = null,
    /// Which face the editor displaced when it was last raised, so
    /// hiding it again returns there instead of always falling through
    /// to the terminal ("Edit in Sketerm Editor" from the browser's
    /// context menu converts the pane in place, and the browser has no
    /// visible way back). ONE slot, not a history stack: it is written
    /// only on a raise, and cleared by detachBrowser/detachEditor so a
    /// dead face can never be resurrected.
    editor_prev_face: PrevFace = .terminal,

    /// Panel face (src/ui/panel/view.zig, hosted by ui/panelhost.zig):
    /// a declarative document an assistant authored, rendered as real
    /// widgets. Same five-pointer contract and two-phase teardown as
    /// the editor face above.
    panel_widget: ?*c.GtkWidget = null,
    panel_ctx: ?*anyopaque = null,
    panel_prepare_destroy: ?*const fn (*anyopaque, widgets_dead: bool) void = null,
    panel_deinit: ?*const fn (*anyopaque) void = null,
    panel_focus: ?*const fn (*anyopaque) void = null,
    /// Web face (src/ui/webface.zig): a browser view rendered from the
    /// `sketerm-webengine` helper. Same five-pointer contract and two-phase
    /// teardown as the editor and panel faces above.
    web_widget: ?*c.GtkWidget = null,
    web_ctx: ?*anyopaque = null,
    web_prepare_destroy: ?*const fn (*anyopaque, widgets_dead: bool) void = null,
    web_deinit: ?*const fn (*anyopaque) void = null,
    web_focus: ?*const fn (*anyopaque) void = null,
    /// True only while the pane-wide teardown choke point is detaching faces.
    /// Panelhost uses it to distinguish viewer loss from an explicit close.
    severing_faces: bool = false,
    /// "File browser hidden - click to show it" strip, shown on the
    /// TERMINAL face while a browser face exists on this pane. Without
    /// it the browser is unreachable once hidden: only its own toolbar
    /// could flip the faces.
    browser_banner: ?*c.GtkWidget = null,
    /// Persistent transport-loss status; click retries immediately.
    connection_banner: ?*c.GtkWidget = null,
    /// The GraphicsOffload wrapping the GLArea — hidden while an app
    /// view (mirror of the session's forwarded windows) is shown.
    offload_widget: ?*c.GtkWidget = null,
    /// Current primary AppHost of an app session (erased *AppHost;
    /// pane installs its embed box + callbacks on it).
    app_host: ?*anyopaque = null,
    /// Container hosting the embedded (in-tab, interactive) app view
    /// — the AppHost reparents its window overlay into this.
    app_embed_box: ?*c.GtkWidget = null,
    /// True while the embedded view is showing (terminal hidden).
    app_embed_active: bool = false,
    /// "App window open — click to raise" banner, shown in window
    /// view mode while the app has floating windows.
    app_banner: ?*c.GtkWidget = null,
    /// Config app_view pushed by the Window: embed apps in the tab
    /// (true) or float them with a banner tab (false, default).
    app_view_tab: bool = false,
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
    /// Title provided by the visible non-terminal face (web page
    /// title, browser directory, editor document). Shown while such
    /// a face covers the terminal; the OSC/manual title returns when
    /// the terminal face shows again. Owned; freed in deinit.
    face_title: ?[]u8 = null,

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

    /// Overlay-scrollbar drag in progress. While set, every pointer
    /// handler yields to the scrollbar — no selection, no mouse
    /// reports — until the button comes up.
    sb_dragging: bool = false,
    /// Pointer offset inside the thumb at grab time (framebuffer
    /// pixels), so the thumb doesn't jump to centre on the pointer.
    sb_drag_dy: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, terminal: *Terminal) !*Pane {
        const self = try allocator.create(Pane);
        errdefer allocator.destroy(self);

        // The renderer half: creates the GtkGLArea (a SketermTermArea
        // subclass for AT-SPI), connects the GL lifecycle signals and
        // installs the first frame tick. Constructed in place — the
        // surface's address is baked into GTK signal user-data, and
        // this Pane allocation is its final home.
        self.* = .{
            .surface = undefined,
            .terminal = terminal,
            .allocator = allocator,
        };
        TerminalSurface.initInPlace(&self.surface, allocator, terminal);
        // What the surface noticed but the session owner must act on.
        self.surface.host_ctx = @ptrCast(self);
        self.surface.on_child_exit = onSurfaceChildExit;
        self.surface.on_before_redraw = onSurfaceBeforeRedraw;
        self.surface.on_grid_geometry = onSurfaceGridGeometry;
        const area_widget: *c.GtkWidget = self.surface.widget();
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

        // Right-click on the titlebar opens the pane's own context
        // menu. It forwards to the GLArea's popover rather than
        // attaching a second one, so there is exactly one menu, one
        // action group and one pre-popup hook per pane.
        const tb_rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(tb_rclick), 3);
        _ = c.g_signal_connect_data(
            tb_rclick,
            "pressed",
            @ptrCast(&onTitlebarRightClicked),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.gtk_widget_add_controller(tb_box, @ptrCast(tb_rclick));

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

        self.wrapper_box = wrap;
        self.offload_widget = offload;
        self.titlebar_box = tb_box;
        self.titlebar_label = @ptrCast(@alignCast(tb_label_w));

        // The widgets-dead fence: closing a pane destroys its widget
        // subtree immediately while Pane.deinit is deferred, so late
        // teardown must know when the pointers stop being widgets.
        _ = c.g_signal_connect_data(wrap, "destroy", @ptrCast(&onWrapperDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Pane is the Terminal's user_ctx for ALL sink callbacks.
        // Pane dispatches: image → its own store, clipboard/title →
        // forwarded to Window if its sinks are set.
        terminal.user_ctx = @ptrCast(self);
        terminal.on_image = onImageEvent;
        terminal.on_image_delete_full = onImageDeleteFullEvent;
        terminal.on_title = onTitleEvent;
        terminal.on_cwd_changed = onCwdEvent;
        terminal.on_program_changed = onProgramEvent;
        terminal.on_clipboard_set = onClipboardEvent;
        terminal.on_clipboard_get = onClipboardGetEvent;
        terminal.on_glyph_coverage = onGlyphCoverageEvent;
        terminal.on_render_request = onRenderRequest;
        terminal.on_crashed = onCrashEvent;
        terminal.on_connection_state = onConnectionStateEvent;
        terminal.on_activity = onActivityEvent;
        terminal.on_notification = onNotificationEvent;
        terminal.on_progress = onProgressEvent;
        terminal.on_transfer = onTransferEvent;
        terminal.on_cmd_status = onCmdStatusEvent;
        terminal.on_bell = onBellEvent;
        terminal.on_pointer_shape = onPointerShapeEvent;
        terminal.on_set_profile = onSetProfileEvent;
        terminal.on_session_renamed = onSessionRenamedEvent;
        terminal.on_peers = onPeersChanged;
        terminal.on_app_view = onAppViewEvent;
        terminal.on_app_window = onAppWindowEvent;

        // M4: keyboard input → PTY (also handles shortcuts).
        self.input_ctx = try input.attach(area_widget, terminal, allocator);
        if (self.input_ctx) |ictx| {
            ictx.pane_ctx = @ptrCast(self);
            ictx.autohide_set = setCursorHiddenSink;
            ictx.browser_toggle = toggleBrowserFaceSink;
            ictx.editor_toggle = toggleEditorFaceSink;
            ictx.context_menu = contextMenuAtCursorSink;
        }

        // Mouse-wheel scroll → adjust view_offset.
        // (Resize → grid geometry → TIOCSWINSZ is the surface's.)
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

        // Right-click context allocations are owned by their GTK closures and
        // may be released after Pane teardown while the widget tree unwinds.
        try menu.attachWithPrePopup(area_widget, allocator, paneMenuSink, @ptrCast(self), paneMenuPrePopup, @ptrCast(self));

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

        // macOS: (de)attach the VoiceOver element as the pane's window
        // backing comes and goes (no-op signal handlers on Linux).
        // The surface has its own "map" handler for tick/animation
        // resume; these carry only the a11y half.
        _ = c.g_signal_connect_data(area_widget, "map", @ptrCast(&onAreaMap), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(area_widget, "unmap", @ptrCast(&onAreaUnmap), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        return self;
    }

    fn handleMenuLocal(self: *Pane, action: menu.Action) bool {
        switch (action) {
            .copy => {
                if (!self.terminal.screen.selection.isActive()) return true;
                const text = self.terminal.screen.extractSelection(self.allocator) catch return true;
                defer self.allocator.free(text);
                if (text.len == 0) return true;
                clipboard.copyText(self.allocator, @ptrCast(self.surface.area), text);
                if (self.clear_select_on_copy) {
                    self.terminal.screen.selection.clear();
                    self.terminal.screen.dirty = true;
                    c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
                    self.a11yNudge();
                }
                return true;
            },
            .paste => {
                clipboard.pasteFromClipboard(@ptrCast(self.surface.area), self.terminal);
                return true;
            },
            .copy_output => {
                const maybe = self.terminal.screen.extractLastCommandOutput(self.allocator) catch return true;
                const text = maybe orelse return true;
                defer self.allocator.free(text);
                if (text.len == 0) return true;
                clipboard.copyText(self.allocator, @ptrCast(self.surface.area), text);
                return true;
            },
            .reset_terminal => {
                self.terminal.screen.fullReset();
                return true;
            },
            .copy_link => {
                const uri = self.menu_link_uri orelse return true;
                if (uri.len == 0) return true;
                clipboard.copyText(self.allocator, @ptrCast(self.surface.area), uri);
                return true;
            },
            .open_link => {
                const uri = self.menu_link_uri orelse return true;
                launchUri(uri);
                return true;
            },
            // These three already exist as keybind actions. Delegating
            // keeps ONE implementation each: a menu row and its chord
            // can never drift apart.
            .select_all => {
                const ictx = self.input_ctx orelse return true;
                _ = input.runAction(ictx, .select_all);
                self.a11yNudge();
                return true;
            },
            .select_output => {
                const ictx = self.input_ctx orelse return true;
                _ = input.runAction(ictx, .select_command_output);
                self.a11yNudge();
                return true;
            },
            .clear_scrollback => {
                const ictx = self.input_ctx orelse return true;
                _ = input.runAction(ictx, .clear_scrollback);
                return true;
            },
            else => return false,
        }
    }

    /// Wired into input.zig's `context_menu`: the Menu key / Shift+F10
    /// path. Pops the SAME popover a right-click does, anchored at the
    /// caret, and runs the same pre-popup hook — so link rows, session
    /// rows and every sensitivity below reflect current state.
    fn contextMenuAtCursorSink(ctx: ?*anyopaque) bool {
        const self = cast.userData(Pane, ctx);
        if (self.nonTerminalFaceVisible()) return false;
        const at = self.surface.cursorAnchor();
        return menu.popupAt(@ptrCast(self.surface.area), at.x, at.y);
    }

    /// True while a face (editor/browser/web) covers the grid. The pane
    /// menu's gesture lives on the GLArea, which is UNMAPPED then, so
    /// the only paths that can still reach it are the titlebar and the
    /// keyboard sink — and neither is about the terminal any more.
    /// Popping it would offer Reset Terminal over an editor, against a
    /// widget that is not on screen.
    pub fn nonTerminalFaceVisible(self: *Pane) bool {
        return self.editorFaceVisible() or self.browserFaceVisible() or self.webFaceVisible();
    }

    /// Route a font-zoom request (font_inc/font_dec/font_reset) to the
    /// VISIBLE face. The single dispatch point for per-face zoom — the
    /// browser/web faces join here when they grow a zoom hook.
    /// @return true when a non-terminal face consumed it, so the caller
    /// must leave the terminal surface's font size alone.
    pub fn faceZoom(self: *Pane, delta: i32, reset: bool) bool {
        if (self.editorFaceVisible()) {
            if (self.editor_zoom) |zoom| {
                if (self.editor_ctx) |ctx| {
                    zoom(ctx, delta, reset);
                    return true;
                }
            }
        }
        return false;
    }

    /// Wired into input.zig's autohide_set. Lets onKeyPressed flip
    /// Pane.cursor_hidden without input.zig importing pane.zig.
    fn setCursorHiddenSink(ctx: ?*anyopaque, hidden: bool) void {
        const self = cast.userData(Pane, ctx);
        self.cursor_hidden = hidden;
    }

    /// Wired into input.zig's browser_toggle: the `toggle_browser_face`
    /// action, dispatched without input.zig importing pane.zig.
    fn toggleBrowserFaceSink(ctx: ?*anyopaque) bool {
        const self = cast.userData(Pane, ctx);
        return self.toggleBrowserFace();
    }

    /// Wired into input.zig's editor_toggle: the `toggle_editor_face`
    /// action, dispatched without input.zig importing pane.zig.
    fn toggleEditorFaceSink(ctx: ?*anyopaque) bool {
        const self = cast.userData(Pane, ctx);
        return self.toggleEditorFace();
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
        clipboard.copyToPrimary(@ptrCast(self.surface.area), cstr);
        if (self.copy_on_selection) {
            clipboard.copyToClipboard(@ptrCast(self.surface.area), cstr);
        }
    }

    pub const CellPos = TerminalSurface.CellPos;

    /// Hover tooltip for a link: the URI, plus the Ctrl+click hint
    /// when single-click open is off (otherwise the pointer-cursor
    /// affordance lies — plain clicks do nothing).
    fn setLinkTooltip(self: *Pane, uri: []const u8) void {
        const hint = "\nCtrl+click to open";
        var buf: [4096 + hint.len]u8 = undefined;
        const n = @min(uri.len, 4095);
        @memcpy(buf[0..n], uri[0..n]);
        var end = n;
        if (!self.link_single_click) {
            @memcpy(buf[end .. end + hint.len], hint);
            end += hint.len;
        }
        buf[end] = 0;
        c.gtk_widget_set_tooltip_text(@ptrCast(self.surface.area), &buf);
    }

    pub fn deinit(self: *Pane) void {
        // GLib timeouts hold a raw *TerminalSurface — sever them
        // before freeing. (The frame-clock tick is widget-owned and
        // dies with the GtkGLArea; the g_timeout sources are not.)
        self.surface.stopVisualSources();
        // Defensive: unmap normally detaches first, but a pane torn down
        // while still mapped must not leave a dangling AX child.
        detachA11y(self);
        // Last-resort sever for a teardown path that never called
        // severFaces() while the widgets were alive. Idempotent, so it
        // is a no-op on every ordinary path.
        self.severFaces();
        // A pane deinited while its widgets still exist (window
        // teardown order varies) must not leave the destroy fence
        // pointing at freed memory.
        if (!self.widgets_dead) {
            if (self.wrapper_box) |wrap| {
                _ = c.g_signal_handlers_disconnect_matched(
                    @ptrCast(wrap),
                    c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    @ptrCast(@constCast(&onWrapperDestroy)),
                    @ptrCast(self),
                );
            }
        }
        self.surface.deinit();
        if (self.input_ctx) |ictx| self.allocator.destroy(ictx);
        if (self.menu_link_uri) |uri| self.allocator.free(uri);
        if (self.titlebar_text) |t| self.allocator.free(t);
        if (self.face_title) |t| self.allocator.free(t);
        self.freeSpawnArgv();
        self.allocator.destroy(self);
    }

    /// Sever every face that outlives the pane's widget subtree — IM
    /// context, browser, editor, panel, forwarded-app embed — while
    /// that subtree is still alive. Idempotent.
    ///
    /// THE single teardown entry point: every path that is about to
    /// destroy a pane's widgets (close, split-collapse, mux takeover,
    /// tab-close sweep, `Window.unlistPane`) calls this and nothing
    /// else. It used to be a hand-copied list of `detachIm();
    /// detachBrowser();` at four call sites, and the editor face —
    /// added later — was never added to any of them, so it was severed
    /// only from the deferred `Pane.deinit`, i.e. against widgets GTK
    /// had already finalized.
    pub fn severFaces(self: *Pane) void {
        const was_severing = self.severing_faces;
        self.severing_faces = true;
        defer self.severing_faces = was_severing;
        self.detachIm();
        self.detachBrowser();
        self.detachEditor();
        self.detachPanel();
        self.detachWeb();
        self.detachAppHost();
        // AT-SPI bridge: drop the Terminal back-pointer and cancel the
        // coalescing timer before the Terminal can die. The area's own
        // ::destroy severs too, but on ordinary paths the Terminal is
        // torn down first — this call is the one that runs in time.
        // Skip once the widgets are gone (last-resort deinit call): the
        // destroy signal already severed, and self.surface.area then dangles.
        if (!platform.is_macos and !self.widgets_dead) a11y.sever(@ptrCast(self.surface.area));
    }

    /// Nudge the AT-SPI bridge after a host-side selection mutation —
    /// selection lives GUI-side, so no daemon drain (and thus no
    /// onRenderRequest) announces it. Coalesced in the bridge; free
    /// when no screen reader is attached.
    fn a11yNudge(self: *Pane) void {
        if (platform.is_macos) return;
        a11y.notifyChanged(@ptrCast(self.surface.area));
    }

    /// Adopt an existing AppHost (a tabless session materialized
    /// into this pane): wire the pane callbacks and embed its
    /// primary window.
    pub fn adoptAppHost(self: *Pane, host_opaque: *anyopaque) void {
        const AppHost = @import("../wlapp.zig").AppHost;
        const h: *AppHost = @ptrCast(@alignCast(host_opaque));
        self.app_host = host_opaque;
        h.embed_ctx = @ptrCast(self);
        h.on_embed = onAppEmbedChanged;
        h.on_request_embed = onAppRequestEmbed;
        installEmbedBox(self, h);
        h.popIn();
    }

    /// Attach a file-browser face (src/ui/browser.zig): the widget
    /// joins the pane's wrapper box as a second face; the terminal
    /// stays alive underneath (it IS "Open Terminal Here"). The pane
    /// owns teardown: `deinit_cb(ctx)` runs from detachBrowser.
    pub fn attachBrowser(
        self: *Pane,
        face: *c.GtkWidget,
        ctx: *anyopaque,
        prepare_destroy_cb: *const fn (*anyopaque) void,
        deinit_cb: *const fn (*anyopaque) void,
        focus_cb: *const fn (*anyopaque) void,
    ) void {
        const wrap = self.wrapper_box orelse return;
        self.detachBrowser();
        self.browser_widget = face;
        self.browser_ctx = ctx;
        self.browser_prepare_destroy = prepare_destroy_cb;
        self.browser_deinit = deinit_cb;
        self.browser_focus = focus_cb;
        c.gtk_widget_set_vexpand(face, 1);
        c.gtk_widget_set_hexpand(face, 1);
        c.gtk_box_append(@ptrCast(wrap), face);
        self.setBrowserVisible(true);
    }

    /// Flip between the browser face and the terminal face. Hiding the
    /// browser raises the strip that flips back: the terminal face has
    /// no browser toolbar to click, so without it the trip is one-way.
    pub fn setBrowserVisible(self: *Pane, show: bool) void {
        const bw = self.browser_widget orelse return;
        c.gtk_widget_set_visible(bw, if (show) @as(c_int, 1) else 0);
        // The face title belongs to whichever face is raised: drop it
        // on every flip; the focus callback below re-asserts it.
        self.clearFaceTitle();
        if (show) {
            // Faces are exclusive: raising the browser hides an
            // editor, panel or web face too.
            if (self.editor_widget) |ew| c.gtk_widget_set_visible(ew, 0);
            if (self.panel_widget) |pw| c.gtk_widget_set_visible(pw, 0);
            if (self.web_widget) |ww| c.gtk_widget_set_visible(ww, 0);
        }
        if (self.offload_widget) |ow|
            c.gtk_widget_set_visible(ow, if (show) @as(c_int, 0) else 1);
        setBrowserBanner(self, !show);
        // Focus follows the visible face, in BOTH directions. A hidden
        // widget cannot hold GTK focus, so leaving it on the GL area
        // while the browser shows left the keyboard talking to nothing:
        // no chord, no type-ahead, and no way back by keyboard either.
        if (show) {
            if (self.browser_focus) |focus| {
                if (self.browser_ctx) |ctx| focus(ctx);
            }
        } else {
            _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));
        }
    }

    /// True when this pane has a browser face at all (visible or not).
    pub fn hasBrowserFace(self: *Pane) bool {
        return self.browser_widget != null;
    }

    /// True while the browser face is the one showing.
    pub fn browserFaceVisible(self: *Pane) bool {
        const bw = self.browser_widget orelse return false;
        return c.gtk_widget_get_visible(bw) != 0;
    }

    /// Swap the pane's two faces. @return false when there is no
    /// browser face to swap to, so a caller can say so instead of
    /// silently doing nothing.
    pub fn toggleBrowserFace(self: *Pane) bool {
        if (!self.hasBrowserFace()) return false;
        self.setBrowserVisible(!self.browserFaceVisible());
        return true;
    }

    /// Tear the browser face down without freeing its state during GTK destruction signals.
    pub fn detachBrowser(self: *Pane) void {
        const ctx = self.browser_ctx;
        const prepare_destroy_cb = self.browser_prepare_destroy;
        const deinit_cb = self.browser_deinit;
        const face = self.browser_widget;
        // Clear pane ownership first so widget-destruction signals cannot
        // re-enter through the pane and try to detach the same face again.
        self.browser_ctx = null;
        self.browser_prepare_destroy = null;
        self.browser_deinit = null;
        self.browser_focus = null;
        self.browser_widget = null;
        // No browser face left to return to.
        self.editor_prev_face = .terminal;
        self.clearFaceTitle();
        if (ctx) |browser_ctx| {
            if (prepare_destroy_cb) |cb| cb(browser_ctx);
        }
        if (face) |bw| {
            // After the widget tree's destroy these pointers are no
            // longer widgets; GTK already removed everything itself.
            if (!self.widgets_dead) {
                if (self.wrapper_box) |wrap| c.gtk_box_remove(@ptrCast(wrap), bw);
                if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 1);
            }
        }
        // Unparenting synchronously emits sorter and selection signals that
        // still use BrowserView. Free it, and remove its mux watch, only
        // after that GTK destruction chain has completed.
        if (ctx) |browser_ctx| {
            if (deinit_cb) |cb| cb(browser_ctx);
        }
        // No face left to go back to.
        if (!self.widgets_dead) setBrowserBanner(self, false);
    }

    /// Attach a text-editor face: the widget joins the pane's wrapper
    /// box as another face; the terminal stays alive underneath. Same
    /// ownership contract as attachBrowser.
    pub fn attachEditor(
        self: *Pane,
        face: *c.GtkWidget,
        ctx: *anyopaque,
        prepare_destroy_cb: *const fn (*anyopaque, widgets_dead: bool) void,
        deinit_cb: *const fn (*anyopaque) void,
        focus_cb: *const fn (*anyopaque) void,
    ) void {
        const wrap = self.wrapper_box orelse return;
        self.detachEditor();
        self.editor_widget = face;
        self.editor_ctx = ctx;
        self.editor_prepare_destroy = prepare_destroy_cb;
        self.editor_deinit = deinit_cb;
        self.editor_focus = focus_cb;
        c.gtk_widget_set_vexpand(face, 1);
        c.gtk_widget_set_hexpand(face, 1);
        c.gtk_box_append(@ptrCast(wrap), face);
        self.setEditorVisible(true);
    }

    /// Flip between the editor face and whatever else the pane shows
    /// (terminal, or a browser face — showing the editor hides both).
    /// Hiding it returns to whichever face the raise displaced, so a
    /// pane converted from the file browser goes back to the browser.
    pub fn setEditorVisible(self: *Pane, show: bool) void {
        const ew = self.editor_widget orelse return;
        // Record the displaced face on the RAISE only. A raise over a
        // visible browser is the interesting case; `terminal` is only
        // recorded when the editor was actually down, so a redundant
        // show (the attach path re-raising an existing face) cannot
        // overwrite the memory. GTK4 widgets are visible by default,
        // so a freshly appended face reads as visible here — hence the
        // browser check comes first.
        if (show) {
            if (self.browserFaceVisible())
                self.editor_prev_face = .browser
            else if (c.gtk_widget_get_visible(ew) == 0)
                self.editor_prev_face = .terminal;
        }
        c.gtk_widget_set_visible(ew, if (show) @as(c_int, 1) else 0);
        // Face title follows the raised face; the focus callback (or
        // setBrowserVisible below) re-asserts the new face's title.
        self.clearFaceTitle();
        if (!show and self.editor_prev_face == .browser and self.hasBrowserFace()) {
            // setBrowserVisible owns the rest: offload widget, banner
            // and focus.
            self.setBrowserVisible(true);
            return;
        }
        if (show) {
            if (self.browser_widget) |bw| c.gtk_widget_set_visible(bw, 0);
            if (self.panel_widget) |pw| c.gtk_widget_set_visible(pw, 0);
            if (self.web_widget) |ww| c.gtk_widget_set_visible(ww, 0);
            if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 0);
            if (self.editor_focus) |focus| {
                if (self.editor_ctx) |ctx| focus(ctx);
            }
        } else {
            if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 1);
            _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));
        }
    }

    pub fn hasEditorFace(self: *Pane) bool {
        return self.editor_widget != null;
    }

    /// True when hiding the editor face will raise the file browser
    /// rather than the shell — the editor's "back" affordance names
    /// its destination from this.
    pub fn editorReturnsToBrowser(self: *Pane) bool {
        return self.editor_prev_face == .browser and self.hasBrowserFace();
    }

    pub fn editorFaceVisible(self: *Pane) bool {
        const ew = self.editor_widget orelse return false;
        return c.gtk_widget_get_visible(ew) != 0;
    }

    /// Swap editor face and shell. @return false when there is no
    /// editor face to swap to.
    pub fn toggleEditorFace(self: *Pane) bool {
        if (!self.hasEditorFace()) return false;
        self.setEditorVisible(!self.editorFaceVisible());
        return true;
    }

    /// Two-phase editor teardown, tolerant of dead widgets — mirror
    /// of detachBrowser.
    pub fn detachEditor(self: *Pane) void {
        const ctx = self.editor_ctx;
        const prepare_destroy_cb = self.editor_prepare_destroy;
        const deinit_cb = self.editor_deinit;
        const face = self.editor_widget;
        self.editor_ctx = null;
        self.editor_prepare_destroy = null;
        self.editor_deinit = null;
        self.editor_focus = null;
        self.editor_zoom = null;
        self.editor_widget = null;
        self.editor_prev_face = .terminal;
        self.clearFaceTitle();
        if (ctx) |editor_ctx| {
            if (prepare_destroy_cb) |cb| cb(editor_ctx, self.widgets_dead);
        }
        if (face) |ew| {
            if (!self.widgets_dead) {
                if (self.wrapper_box) |wrap| c.gtk_box_remove(@ptrCast(wrap), ew);
                if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 1);
            }
        }
        if (ctx) |editor_ctx| {
            if (deinit_cb) |cb| cb(editor_ctx);
        }
    }

    /// Attach a panel face (src/ui/panel/view.zig): the widget joins
    /// the pane's wrapper box as another face; the terminal stays alive
    /// underneath. Identical ownership contract to attachEditor — the
    /// view's exported `prepareDestroyCb`/`destroyCb`/`focusCb`
    /// trampolines match these parameters by design.
    pub fn attachPanel(
        self: *Pane,
        face: *c.GtkWidget,
        ctx: *anyopaque,
        prepare_destroy_cb: *const fn (*anyopaque, widgets_dead: bool) void,
        deinit_cb: *const fn (*anyopaque) void,
        focus_cb: *const fn (*anyopaque) void,
    ) bool {
        const wrap = self.wrapper_box orelse return false;
        self.detachPanel();
        self.panel_widget = face;
        self.panel_ctx = ctx;
        self.panel_prepare_destroy = prepare_destroy_cb;
        self.panel_deinit = deinit_cb;
        self.panel_focus = focus_cb;
        c.gtk_widget_set_vexpand(face, 1);
        c.gtk_widget_set_hexpand(face, 1);
        c.gtk_box_append(@ptrCast(wrap), face);
        self.setPanelVisible(true);
        return true;
    }

    pub fn canAdoptPanelFace(self: *const Pane) bool {
        return !self.widgets_dead and !self.severing_faces and
            self.wrapper_box != null and self.panel_ctx == null;
    }

    pub fn isSeveringFaces(self: *const Pane) bool {
        return self.severing_faces;
    }

    /// Flip between the panel face and whatever else the pane shows
    /// (terminal, browser or editor — showing the panel hides them all).
    pub fn setPanelVisible(self: *Pane, show: bool) void {
        const pw = self.panel_widget orelse return;
        c.gtk_widget_set_visible(pw, if (show) @as(c_int, 1) else 0);
        // The panel face carries no title of its own; drop any other
        // face's leftover so the OSC title shows underneath.
        self.clearFaceTitle();
        if (show) {
            if (self.browser_widget) |bw| c.gtk_widget_set_visible(bw, 0);
            if (self.editor_widget) |ew| c.gtk_widget_set_visible(ew, 0);
            if (self.web_widget) |ww| c.gtk_widget_set_visible(ww, 0);
            if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 0);
            if (self.panel_focus) |focus| {
                if (self.panel_ctx) |ctx| focus(ctx);
            }
        } else {
            if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 1);
            _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));
        }
    }

    pub fn hasPanelFace(self: *Pane) bool {
        return self.panel_widget != null;
    }

    pub fn panelFaceVisible(self: *Pane) bool {
        const pw = self.panel_widget orelse return false;
        return c.gtk_widget_get_visible(pw) != 0;
    }

    /// Swap panel face and shell. @return false when there is no panel
    /// face to swap to.
    pub fn togglePanelFace(self: *Pane) bool {
        if (!self.hasPanelFace()) return false;
        self.setPanelVisible(!self.panelFaceVisible());
        return true;
    }

    /// Two-phase panel teardown, tolerant of dead widgets — mirror of
    /// detachEditor. Reached from `severFaces`, never from a call site.
    pub fn detachPanel(self: *Pane) void {
        const ctx = self.panel_ctx;
        const prepare_destroy_cb = self.panel_prepare_destroy;
        const deinit_cb = self.panel_deinit;
        const face = self.panel_widget;
        self.panel_ctx = null;
        self.panel_prepare_destroy = null;
        self.panel_deinit = null;
        self.panel_focus = null;
        self.panel_widget = null;
        self.clearFaceTitle();
        if (ctx) |panel_ctx| {
            if (prepare_destroy_cb) |cb| cb(panel_ctx, self.widgets_dead);
        }
        if (face) |pw| {
            if (!self.widgets_dead) {
                if (self.wrapper_box) |wrap| c.gtk_box_remove(@ptrCast(wrap), pw);
                if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 1);
            }
        }
        if (ctx) |panel_ctx| {
            if (deinit_cb) |cb| cb(panel_ctx);
        }
    }

    /// Attach a web face (src/ui/webface.zig): the widget joins the
    /// pane's wrapper box as another face; the terminal stays alive
    /// underneath. Identical ownership contract to attachPanel.
    pub fn attachWeb(
        self: *Pane,
        face: *c.GtkWidget,
        ctx: *anyopaque,
        prepare_destroy_cb: *const fn (*anyopaque, widgets_dead: bool) void,
        deinit_cb: *const fn (*anyopaque) void,
        focus_cb: *const fn (*anyopaque) void,
    ) bool {
        const wrap = self.wrapper_box orelse return false;
        self.detachWeb();
        self.web_widget = face;
        self.web_ctx = ctx;
        self.web_prepare_destroy = prepare_destroy_cb;
        self.web_deinit = deinit_cb;
        self.web_focus = focus_cb;
        c.gtk_widget_set_vexpand(face, 1);
        c.gtk_widget_set_hexpand(face, 1);
        c.gtk_box_append(@ptrCast(wrap), face);
        self.setWebVisible(true);
        return true;
    }

    /// Flip between the web face and whatever else the pane shows
    /// (terminal, browser, editor or panel — showing it hides them all).
    pub fn setWebVisible(self: *Pane, show: bool) void {
        const ww = self.web_widget orelse return;
        c.gtk_widget_set_visible(ww, if (show) @as(c_int, 1) else 0);
        // Face title follows the raised face; the focus callback
        // re-asserts the web face's page title.
        self.clearFaceTitle();
        if (show) {
            if (self.browser_widget) |bw| c.gtk_widget_set_visible(bw, 0);
            if (self.editor_widget) |ew| c.gtk_widget_set_visible(ew, 0);
            if (self.panel_widget) |pw| c.gtk_widget_set_visible(pw, 0);
            if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 0);
            if (self.web_focus) |focus| {
                if (self.web_ctx) |ctx| focus(ctx);
            }
        } else {
            if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 1);
            _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));
        }
    }

    pub fn hasWebFace(self: *Pane) bool {
        return self.web_widget != null;
    }

    pub fn webFaceVisible(self: *Pane) bool {
        const ww = self.web_widget orelse return false;
        return c.gtk_widget_get_visible(ww) != 0;
    }

    /// Two-phase web teardown, tolerant of dead widgets — mirror of
    /// detachPanel. Reached from `severFaces`, never from a call site.
    pub fn detachWeb(self: *Pane) void {
        const ctx = self.web_ctx;
        const prepare_destroy_cb = self.web_prepare_destroy;
        const deinit_cb = self.web_deinit;
        const face = self.web_widget;
        self.web_ctx = null;
        self.web_prepare_destroy = null;
        self.web_deinit = null;
        self.web_focus = null;
        self.web_widget = null;
        self.clearFaceTitle();
        if (ctx) |web_ctx| {
            if (prepare_destroy_cb) |cb| cb(web_ctx, self.widgets_dead);
        }
        if (face) |ww| {
            if (!self.widgets_dead) {
                if (self.wrapper_box) |wrap| c.gtk_box_remove(@ptrCast(wrap), ww);
                if (self.offload_widget) |ow| c.gtk_widget_set_visible(ow, 1);
            }
        }
        if (ctx) |web_ctx| {
            if (deinit_cb) |cb| cb(web_ctx);
        }
    }

    fn onWrapperDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Pane, user);
        self.widgets_dead = true;
    }

    /// Sever the pane from its AppHost: return any embedded view to
    /// its hidden window and drop the host's pane callbacks. Must run
    /// BEFORE the pane's widget tree is torn down (the embedded
    /// overlay lives inside it). Idempotent.
    pub fn detachAppHost(self: *Pane) void {
        const AppHost = @import("../wlapp.zig").AppHost;
        if (self.app_host) |hp| {
            const h: *AppHost = @ptrCast(@alignCast(hp));
            h.releaseEmbed();
        }
        self.app_host = null;
        self.app_embed_active = false;
    }

    /// Sever the terminal face's IM context NOW. Prefer `severFaces`;
    /// this is the per-face half of it. The IM context is not owned by
    /// the widget tree, so GTK can still emit `commit` /
    /// `preedit-changed` (fcitx5/ibus route asynchronously through
    /// D-Bus) between the widget surgery and the deferred `Pane.deinit`,
    /// and those handlers dereference the dangling GLArea (Gtk-CRITICAL
    /// in gtk_gl_area_queue_render). Idempotent. Dropping the ref here
    /// also plugs the one-IM-context-per-closed-pane leak (and its
    /// inner D-Bus name watch).
    pub fn detachIm(self: *Pane) void {
        const ictx = self.input_ctx orelse return;
        const im = ictx.im orelse return;
        ictx.im = null;
        im.deinit();
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
        return @ptrCast(self.surface.area);
    }

    // ── TerminalSurface forwarders ───────────────────────────────
    // The render half lives in `surface` (terminal_surface.zig).
    // These one-liners are the pane's public render API so callers
    // (Window config pushes, layout save/restore, remote control)
    // keep one entry point per operation; Pane itself never reaches
    // into a pass.

    /// Render the pane's current pixels to a PNG (owned GBytes).
    pub fn screenshotPng(self: *Pane) ?*c.GBytes {
        return self.surface.screenshotPng();
    }

    pub fn queueRender(self: *Pane) void {
        self.surface.queueRender();
    }

    pub fn applyDim(self: *Pane) void {
        self.surface.applyDim();
    }

    pub fn restartBlinkTimer(self: *Pane) void {
        self.surface.restartBlinkTimer();
    }

    pub fn applyTrailConfig(self: *Pane, enabled: bool, duration_ms: u32) void {
        self.surface.applyTrailConfig(enabled, duration_ms);
    }

    pub fn setFontSize(self: *Pane, new_size: u16) void {
        self.surface.setFontSize(new_size);
    }

    pub fn refreshFont(self: *Pane) void {
        self.surface.refreshFont();
    }

    pub fn updateShaderTick(self: *Pane) void {
        self.surface.updateShaderTick();
    }

    pub fn setCustomShader(self: *Pane, path: ?[]const u8, animate: bool, user_pick: bool) bool {
        return self.surface.setCustomShader(path, animate, user_pick);
    }

    pub fn refreshShaderBinding(self: *Pane) void {
        self.surface.refreshShaderBinding();
    }

    pub fn applyShaderPresetParams(self: *Pane, name: []const u8, params: []const ShaderParamKV) void {
        self.surface.applyShaderPresetParams(name, params);
    }

    pub fn hasOwnShaderParams(self: *const Pane) bool {
        return self.surface.hasOwnShaderParams();
    }

    pub fn unbindPresetName(self: *Pane) void {
        self.surface.unbindPresetName();
    }

    pub fn setPresetParam(self: *Pane, name: []const u8, value: f32, color: ?[3]f32) void {
        self.surface.setPresetParam(name, value, color);
    }

    pub fn dropShaderPreset(self: *Pane, global_overrides: []const ShaderParamKV) void {
        self.surface.dropShaderPreset(global_overrides);
    }

    pub fn clearShader(self: *Pane) void {
        self.surface.clearShader();
    }

    /// Toggle the GtkGraphicsOffload fast path (config
    /// `graphics_offload`). DISABLED falls back to normal GSK
    /// compositing — no Wayland subsurfaces, no dmabuf scanout.
    pub fn setGraphicsOffload(self: *Pane, enabled: bool) void {
        const w = self.offload_widget orelse return;
        // While an in-window dialog has offload suspended (render_kick),
        // enabling now would put the subsurface back above the dialog —
        // the suspend mark already means "re-enable on dialog close".
        if (enabled and render_kick.offloadSuspended(w)) return;
        if (!enabled) render_kick.clearOffloadSuspended(w);
        c.gtk_graphics_offload_set_enabled(
            @ptrCast(w),
            if (enabled) c.GTK_GRAPHICS_OFFLOAD_ENABLED else c.GTK_GRAPHICS_OFFLOAD_DISABLED,
        );
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
        // Screen readers announce the pane by its accessible label:
        // keep it tracking the terminal title (OSC 0/1/2).
        if (!platform.is_macos and !self.widgets_dead and text.len > 0) {
            if (self.allocator.allocSentinel(u8, text.len, 0) catch null) |z| {
                defer self.allocator.free(z);
                @memcpy(z, text);
                a11y.setLabel(@ptrCast(self.surface.area), z.ptr);
            }
        }
        self.refreshTitlebarLabel();
    }

    /// Title from the visible non-terminal face (web page, browser
    /// directory, editor document). Displayed only while such a face
    /// covers the terminal, and never over a user-locked title.
    pub fn setFaceTitle(self: *Pane, text: []const u8) void {
        if (self.face_title) |old| {
            if (std.mem.eql(u8, old, text)) return;
            self.allocator.free(old);
        }
        self.face_title = self.allocator.dupe(u8, text) catch null;
        self.refreshTitlebarLabel();
    }

    /// Drop the face-provided title; the OSC/manual title returns.
    pub fn clearFaceTitle(self: *Pane) void {
        const old = self.face_title orelse return;
        self.allocator.free(old);
        self.face_title = null;
        self.refreshTitlebarLabel();
    }

    /// True while a non-terminal face covers the terminal face.
    fn faceCoversTerminal(self: *Pane) bool {
        return self.browserFaceVisible() or self.editorFaceVisible() or
            self.panelFaceVisible() or self.webFaceVisible();
    }

    /// Recompute the titlebar label from the precedence chain:
    /// manual lock > visible face title > OSC title.
    fn refreshTitlebarLabel(self: *Pane) void {
        if (self.widgets_dead) return;
        const lbl = self.titlebar_label orelse return;
        const text: []const u8 = pick: {
            if (!self.title_locked) {
                if (self.face_title) |ft| {
                    if (self.faceCoversTerminal()) break :pick ft;
                }
            }
            break :pick self.titlebar_text orelse "Terminal";
        };
        const z = self.allocator.allocSentinel(u8, text.len, 0) catch return;
        defer self.allocator.free(z);
        @memcpy(z, text);
        c.gtk_label_set_text(lbl, z.ptr);
    }

    /// Lock the title bar to a manual string. Subsequent OSC 0/1/2
    /// updates are dropped until `unlockTitle` is called.
    pub fn lockTitle(self: *Pane, text: []const u8) void {
        // Locked BEFORE applying so the refresh inside applyTitle
        // already prefers the manual string over any face title.
        self.title_locked = true;
        self.applyTitle(text);
        self.refreshTitlebarLabel();
    }

    /// Resume tracking incoming OSC 0/1/2 titles. The current label
    /// stays as-is until the next OSC update arrives -- unless a face
    /// title is waiting behind the lock, which shows immediately.
    pub fn unlockTitle(self: *Pane) void {
        self.title_locked = false;
        self.refreshTitlebarLabel();
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
};

// ── TerminalSurface host hooks ───────────────────────────────────
// The surface's tick/resize notice things only the session owner can
// act on; these land them back on the Pane.

/// The surface's tick saw the PTY child exit. Fire the once-per-exit
/// Window callback; Window decides what to do (close pane / restart
/// shell / hold) and may tear the pane down from inside the call.
fn onSurfaceChildExit(ctx: ?*anyopaque, status: i32) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_child_exit) |f| f(self.win_child_ctx, self, status);
}

/// A dirty redraw is about to be queued: update the IME cursor
/// location so fcitx5 / ibus position their popups at the right
/// cell. ImHost.setCursorLocation debounces against the last
/// rectangle sent (the call can hop into IBus/fcitx over D-Bus), so
/// this may run per dirty redraw.
fn onSurfaceBeforeRedraw(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    const screen = self.terminal.screen;
    if (self.input_ctx) |ictx| if (ictx.im) |im| if (self.surface.cellPixelSize()) |cell| {
        im.setCursorLocation(.{
            .x = @as(c_int, screen.col) * @as(c_int, cell.w),
            .y = @as(c_int, screen.row) * @as(c_int, cell.h),
            .width = cell.w,
            .height = cell.h,
        });
    };
}

/// A resize changed the pane's column/row COUNT — forward so a
/// `{{ COLUMNS }}`/`{{ LINES }}` title can follow.
fn onSurfaceGridGeometry(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_geometry) |f| f(self.win_cwd_ctx, self);
}

fn onImageEvent(ctx: ?*anyopaque, img: Screen.ImageEvent) void {
    const self = cast.userData(Pane, ctx);
    self.surface.addImage(img);
}

fn onImageDeleteFullEvent(ctx: ?*anyopaque, ev: @import("../grid/screen.zig").Screen.ImageDeleteEvent) void {
    const self = cast.userData(Pane, ctx);
    self.surface.deleteImages(ev);
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

fn onProgramEvent(ctx: ?*anyopaque, program: []const u8) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_program) |f| f(self.win_cwd_ctx, self, program);
}

/// Drain finished a batch with screen.dirty set — schedule a GL
/// render now instead of waiting for the next frame's tick to
/// notice. Also clears the dirty flag so the tick path doesn't
/// queue a redundant render this frame.
fn onRenderRequest(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    self.terminal.screen.dirty = false;
    self.surface.queueRender();
    // DECSCUSR can switch a steady shape to a blinking one mid-
    // session; the blink timer self-removed while the shape was
    // steady, so re-arm here (no-op unless focused + blink shape).
    self.surface.ensureBlinkTimer();
    // Child exit is acted on by the surface's tick (deferring to
    // the next frame avoids tearing the pane down from inside its
    // own apply; it lands back here via on_child_exit). The tick may
    // have self-removed while idle — put it back or the exit_action
    // would only fire on the next unrelated tick trigger.
    if (self.terminal.screen.child_exited) self.surface.ensureTickRunning();
    // Nudge AT clients (Orca/braille) that the caret/contents may have
    // moved. A no-op cost when no screen reader is attached, since GTK only
    // activates its AT-SPI backend on demand. On macOS GTK has no
    // NSAccessibility backend, so poke our own element instead.
    if (platform.is_macos) {
        if (self.ax_element) |el| {
            nsax.notifyChanged(el);
            updateA11yFrame(self);
            selfCheckA11y(self);
        }
    } else {
        a11y.notifyChanged(@ptrCast(self.surface.area));
    }
}

// ── macOS NSAccessibility attachment ─────────────────────────────────
// GTK4 exposes no NSAccessibility, so reach the window's GdkMacos
// content NSView and add a SketermTermAXElement for this pane's text.

/// Attach the pane's accessibility element to the current window's
/// content view (idempotent). Called on map — once realized + mapped
/// the GdkMacosSurface has its NSWindow.
fn attachA11y(self: *Pane) void {
    if (!platform.is_macos) return;
    if (self.ax_element != null) return;
    const native = c.gtk_widget_get_native(@ptrCast(self.surface.area)) orelse return;
    const surface = c.gtk_native_get_surface(native) orelse return;
    const cv = nsax.contentView(@ptrCast(surface)) orelse return;
    const el = nsax.attach(cv, self.terminal) orelse return;
    self.ax_content_view = cv;
    self.ax_element = el;
    self.ax_selfcheck_done = false;
    updateA11yFrame(self);
}

/// Detach + release the element (on unmap, reparent, or close). The
/// next map re-attaches against the (possibly new) window.
fn detachA11y(self: *Pane) void {
    if (!platform.is_macos) return;
    const el = self.ax_element orelse return;
    if (self.ax_content_view) |cv| nsax.detach(cv, el);
    self.ax_element = null;
    self.ax_content_view = null;
}

/// Re-point the element's frame at the pane's on-screen rect (GTK
/// widget coords relative to the window; the shim handles AppKit's flip).
fn updateA11yFrame(self: *Pane) void {
    if (!platform.is_macos) return;
    const el = self.ax_element orelse return;
    const native = c.gtk_widget_get_native(@ptrCast(self.surface.area)) orelse return;
    var r: c.graphene_rect_t = undefined;
    const native_widget: *c.GtkWidget = @ptrCast(@alignCast(native));
    if (c.gtk_widget_compute_bounds(@ptrCast(self.surface.area), native_widget, &r) == 0) return;
    nsax.setFrameInParent(el, r.origin.x, r.origin.y, r.size.width, r.size.height);
}

/// SKETERM_A11Y_SELFCHECK=1: log once whether a VoiceOver client would
/// find this pane's text via window→contentView→child. No TCC needed.
fn selfCheckA11y(self: *Pane) void {
    if (!platform.is_macos) return;
    if (self.ax_selfcheck_done) return;
    if (c.getenv("SKETERM_A11Y_SELFCHECK") == null) return;
    const cv = self.ax_content_view orelse return;
    const el = self.ax_element orelse return;
    // Retry across renders until the screen has content (bit2), so a
    // first render that beats the shell prompt isn't a false FAIL.
    const bits = nsax.selfCheck(cv, el);
    if (bits == 7) {
        self.ax_selfcheck_done = true;
        std.debug.print("A11Y-SELFCHECK: pane={d} bits={d} (PASS)\n", .{ self.id, bits });
    }
}

fn onActivityEvent(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_activity) |f| f(self.win_activity_ctx, self);
}

fn onCrashEvent(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_crashed) |f| f(self.win_crash_ctx, self);
}

fn onConnectionStateEvent(ctx: ?*anyopaque, state: Terminal.ConnectionState, retry_seconds: u32) void {
    const self = cast.userData(Pane, ctx);
    if (self.widgets_dead) return;
    if (state == .connected) {
        if (self.connection_banner) |banner| c.gtk_widget_set_visible(banner, 0);
        return;
    }
    if (self.connection_banner == null) {
        const btn = c.gtk_button_new_with_label("");
        c.gtk_widget_add_css_class(btn, "sketerm-app-banner");
        c.gtk_widget_set_hexpand(btn, 1);
        c.gtk_widget_set_tooltip_text(btn, "The session is still running remotely. Click to retry now.");
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onConnectionBannerClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        if (self.wrapper_box) |wrap| c.gtk_box_prepend(@ptrCast(wrap), btn);
        self.connection_banner = btn;
    }
    var buf: [160:0]u8 = undefined;
    switch (state) {
        .lost, .reconnecting => c.gtk_button_set_label(@ptrCast(self.connection_banner.?), "Connection lost. Reconnecting..."),
        .retry_wait => {
            const text = std.fmt.bufPrintZ(&buf, "Reconnect failed. Retrying in {d}s. Click to retry now.", .{retry_seconds}) catch {
                c.gtk_button_set_label(@ptrCast(self.connection_banner.?), "Reconnect failed. Click to retry now.");
                c.gtk_widget_set_visible(self.connection_banner.?, 1);
                return;
            };
            c.gtk_button_set_label(@ptrCast(self.connection_banner.?), text.ptr);
        },
        .unavailable => c.gtk_button_set_label(@ptrCast(self.connection_banner.?), "Session is no longer available. Click to try again."),
        .connected => unreachable,
    }
    c.gtk_widget_set_visible(self.connection_banner.?, 1);
}

fn onConnectionBannerClick(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    self.terminal.retryRemoteNow();
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

fn onGlyphCoverageEvent(ctx: ?*anyopaque, cp: u32) bool {
    const self = cast.userData(Pane, ctx);
    return self.surface.hasGlyph(cp);
}

fn onClipboardGetEvent(ctx: ?*anyopaque, selection: u8) void {
    const self = cast.userData(Pane, ctx);
    const which: clipboard.Which = if (selection == 'p') .primary else .clipboard;
    const clip = clipboard.clipboardFor(@ptrCast(self.surface.area), which) orelse return;
    const rctx = self.allocator.create(ClipReadCtx) catch return;
    rctx.* = .{
        .allocator = self.allocator,
        .drain = self.terminal.drain,
        .selection = selection,
    };
    if (!clipboard.readFrom(self.allocator, clip, onClipReadDone, @ptrCast(rctx)))
        self.allocator.destroy(rctx);
}

fn onClipReadDone(user: ?*anyopaque, text_opt: ?[]const u8) void {
    const rctx: *ClipReadCtx = @ptrCast(@alignCast(user.?));
    defer rctx.allocator.destroy(rctx);
    if (!rctx.drain.alive.load(.acquire)) return;
    const term = rctx.drain.terminal orelse return;

    var text: []const u8 = text_opt orelse "";
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

fn onTransferEvent(ctx: ?*anyopaque, ev: Terminal.TransferEvent) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_transfer) |f| f(self.win_progress_ctx, self, ev);
}

fn onCmdStatusEvent(ctx: ?*anyopaque, running: bool, exit: i32, duration_ms: i64) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_cmd_status) |f| f(self.win_progress_ctx, self, running, exit, duration_ms);
}

fn onNotificationEvent(ctx: ?*anyopaque, ev: Screen.NotificationEvent) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_notification) |f| f(self.win_notify_ctx, self, ev);
}

fn onSessionRenamedEvent(ctx: ?*anyopaque, name: []const u8) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_session_renamed) |f| f(self.win_session_rename_ctx, self, name);
}

/// The session's primary app host changed (fires at channel open —
/// BEFORE the first frame, so embed_box installed here catches the
/// first toplevel). Null host = last app channel gone: the terminal
/// (app log) returns.
fn onAppViewEvent(ctx: ?*anyopaque, host_opaque: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    const AppHost = @import("../wlapp.zig").AppHost;
    const is_app = if (self.terminal.remote) |r| r.is_app else false;
    if (!is_app) {
        // Shell pane: no embed behavior, but apps launched FROM the
        // shell still float windows. Recompute the banner (this also
        // wires window-count tracking on every host) so it retires
        // when the last app goes away instead of going stale.
        updateAppBanner(self);
        return;
    }
    const old: ?*AppHost = @ptrCast(@alignCast(self.app_host));
    const new: ?*AppHost = @ptrCast(@alignCast(host_opaque));
    if (old == new) return;
    if (old) |h| h.releaseEmbed();
    self.app_host = host_opaque;
    setAppEmbedActive(self, false);
    if (new) |h| {
        h.embed_ctx = @ptrCast(self);
        h.on_embed = onAppEmbedChanged;
        h.on_request_embed = onAppRequestEmbed;
        h.on_windows_changed = onAppWindowsChanged;
        if (self.app_view_tab) installEmbedBox(self, h);
    } else {
        setAppBanner(self, false);
    }
}

/// The app's first real window appeared. In window view mode (or
/// after a pop-out) the tab shows the raise banner over the log.
fn onAppWindowEvent(ctx: ?*anyopaque) void {
    updateAppBanner(cast.userData(Pane, ctx));
}

/// The embedded app view appeared/disappeared: swap it against the
/// terminal (app log). A disappearance with windows still open
/// (pop-out) brings the banner back.
fn onAppEmbedChanged(ctx: ?*anyopaque, active: bool) void {
    const self = cast.userData(Pane, ctx);
    setAppEmbedActive(self, active);
    updateAppBanner(self);
}

/// Host menu "Show in Tab" on a floating window: install the embed
/// box and pull the primary window in.
fn onAppRequestEmbed(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    const AppHost = @import("../wlapp.zig").AppHost;
    const h: *AppHost = @ptrCast(@alignCast(self.app_host orelse return));
    installEmbedBox(self, h);
    h.popIn();
}

fn onAppBannerClick(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    const remote = self.terminal.remote orelse return;
    for (remote.napps.items) |na| na.host.presentAll();
}

/// The app's open-window count changed. Zero windows across every
/// channel (app exit, mode switch, single-instance handoff) must
/// retire the banner — clicking it would be a silent no-op; a later
/// window brings it back.
fn onAppWindowsChanged(ctx: ?*anyopaque, count: usize) void {
    _ = count; // one host's count; the banner needs the cross-host sum
    updateAppBanner(cast.userData(Pane, ctx));
}

/// Recompute banner visibility from ground truth: any live window
/// across ALL of the terminal's app channels. Also (re)wires window-
/// count tracking on every host — hosts beyond napps[0] never arrive
/// via on_app_view, and shell panes skip the app-view path entirely,
/// so this is the only place they get wired. Terminal.clearSinks
/// fences these callbacks again at pane teardown.
fn updateAppBanner(self: *Pane) void {
    var open: usize = 0;
    if (self.terminal.remote) |r| {
        for (r.napps.items) |na| {
            na.host.embed_ctx = @ptrCast(self);
            na.host.on_windows_changed = onAppWindowsChanged;
            open += na.host.windowCount();
        }
    }
    setAppBanner(self, open > 0 and !self.app_embed_active);
}

/// Ensure the embed container exists and hand it to the host (the
/// AppHost reparents its window overlay into it on the next embed).
fn installEmbedBox(self: *Pane, host: *@import("../wlapp.zig").AppHost) void {
    if (self.app_embed_box == null) {
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(box, 1);
        c.gtk_widget_set_vexpand(box, 1);
        c.gtk_widget_set_visible(box, 0);
        if (self.wrapper_box) |wrap| c.gtk_box_append(@ptrCast(wrap), box);
        self.app_embed_box = box;
    }
    host.embed_box = self.app_embed_box;
}

/// Swap the embedded app view against the terminal (app log).
fn setAppEmbedActive(self: *Pane, active: bool) void {
    if (self.app_embed_active == active) return;
    self.app_embed_active = active;
    if (self.app_embed_box) |box| c.gtk_widget_set_visible(box, @intFromBool(active));
    if (self.offload_widget) |o| c.gtk_widget_set_visible(o, @intFromBool(!active));
}

/// Show/hide the "back to the file browser" strip above the terminal.
///
/// The browser face is a sibling widget with its own toolbar; the
/// terminal face has nothing that mentions it, so this strip is what
/// makes the browser reachable again by pointing at it. Same idiom (and
/// CSS class) as the app-window banner.
fn setBrowserBanner(self: *Pane, show: bool) void {
    if (show) {
        if (self.browser_banner == null) {
            const btn = c.gtk_button_new_with_label("File browser hidden - click to show it (Ctrl+Shift+B)");
            c.gtk_widget_add_css_class(btn, "sketerm-app-banner");
            c.gtk_widget_set_hexpand(btn, 1);
            c.gtk_widget_set_tooltip_text(btn, "Show this pane's file browser again. The shell keeps running underneath either way.");
            _ = c.g_signal_connect_data(@ptrCast(btn), "clicked", @ptrCast(&onBrowserBannerClick), @ptrCast(self), null, 0);
            if (self.wrapper_box) |wrap| c.gtk_box_prepend(@ptrCast(wrap), btn);
            self.browser_banner = btn;
        }
        c.gtk_widget_set_visible(self.browser_banner.?, 1);
    } else if (self.browser_banner) |b| {
        c.gtk_widget_set_visible(b, 0);
    }
}

fn onBrowserBannerClick(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    self.setBrowserVisible(true);
}

/// Show/hide the "app window open" banner above the log.
fn setAppBanner(self: *Pane, show: bool) void {
    if (show) {
        if (self.app_banner == null) {
            const btn = c.gtk_button_new_with_label("App window open — click to raise");
            c.gtk_widget_add_css_class(btn, "sketerm-app-banner");
            c.gtk_widget_set_hexpand(btn, 1);
            _ = c.g_signal_connect_data(@ptrCast(btn), "clicked", @ptrCast(&onAppBannerClick), @ptrCast(self), null, 0);
            if (self.wrapper_box) |wrap| c.gtk_box_prepend(@ptrCast(wrap), btn);
            self.app_banner = btn;
        }
        c.gtk_widget_set_visible(self.app_banner.?, 1);
    } else if (self.app_banner) |b| {
        c.gtk_widget_set_visible(b, 0);
    }
}

/// Attach roster changed: show/hide the "assistant is driving"
/// indicator — an accent border on the pane, plus the AI badge on
/// every forwarded app window of this session.
fn onPeersChanged(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    const driven = self.terminal.peer_drivers > 0;
    if (self.wrapper_box) |wrap| {
        if (driven)
            c.gtk_widget_add_css_class(wrap, "sketerm-driven")
        else
            c.gtk_widget_remove_css_class(wrap, "sketerm-driven");
    }
    if (self.terminal.remote) |remote| {
        for (remote.napps.items) |na| na.host.setDriven(driven);
    }
}

fn onSetProfileEvent(ctx: ?*anyopaque, name: []const u8) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_set_profile) |f| f(self.win_setprofile_ctx, self, name);
}

fn onBellEvent(ctx: ?*anyopaque) void {
    const self = cast.userData(Pane, ctx);
    if (self.win_on_bell) |f| f(self.win_bell_ctx, self);
    // Visual bell flash: the surface drives the 200 ms fade.
    self.surface.flashBell();
}

/// OSC 22 — set the GTK pointer (mouse cursor) shape over this pane.
/// Empty name → restore default. Names are X cursor identifiers like
/// "default", "hand2", "watch", "crosshair", "text".
fn onPointerShapeEvent(ctx: ?*anyopaque, name: []const u8) void {
    const self = cast.userData(Pane, ctx);
    if (name.len == 0) {
        c.gtk_widget_set_cursor(@ptrCast(self.surface.area), null);
        return;
    }
    // Need a NUL-terminated copy for gtk_widget_set_cursor_from_name.
    var buf: [64]u8 = undefined;
    if (name.len >= buf.len) return;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    c.gtk_widget_set_cursor_from_name(@ptrCast(self.surface.area), &buf);
}

const appendShellQuoted = @import("../util/shellquote.zig").appendQuoted;

fn onFileDrop(_: *c.GtkDropTarget, value: [*c]const c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Pane, user);

    if (c.g_type_check_value_holds(value, c.gdk_file_list_get_type()) != 0) {
        const flist: ?*c.GdkFileList = @ptrCast(c.g_value_get_boxed(value));
        // get_files is transfer-container: free the list, not the GFiles.
        const files = c.gdk_file_list_get_files(flist);
        defer c.g_slist_free(files);

        // On a REMOTE pane, a dropped file is uploaded to the session's
        // working directory instead of pasted as a path. (Local panes
        // keep the paste-the-path behaviour — the file is already here.)
        if (self.terminal.remote != null) {
            var paths: std.ArrayList([]const u8) = .empty;
            defer {
                for (paths.items) |p| self.allocator.free(p);
                paths.deinit(self.allocator);
            }
            var rnode = files;
            while (rnode != null) : (rnode = rnode.*.next) {
                const gfile: ?*c.GFile = @ptrCast(rnode.*.data);
                const path_c = c.g_file_get_path(gfile);
                if (path_c == null) continue; // non-local URI (e.g. sftp://)
                defer c.g_free(path_c);
                const span = std.mem.span(@as([*:0]const u8, @ptrCast(path_c)));
                const owned = self.allocator.dupe(u8, span) catch continue;
                paths.append(self.allocator, owned) catch self.allocator.free(owned);
            }
            if (paths.items.len == 0) return 0;
            self.terminal.startUpload(paths.items);
            _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));
            return 1;
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
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
        _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));
        return 1;
    }

    if (c.g_type_check_value_holds(value, c.G_TYPE_STRING) != 0) {
        const s = c.g_value_get_string(value);
        if (s == null) return 0;
        const txt = std.mem.span(@as([*:0]const u8, @ptrCast(s)));
        if (txt.len == 0) return 0;
        clipboard.pasteText(self.terminal, txt);
        _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));
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

fn onAreaMap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    // Tick/animation resume is the surface's own map handler. The
    // window's GdkMacosSurface now has its NSWindow; expose the
    // pane's text to VoiceOver. No-op on Linux.
    attachA11y(self);
}

fn onAreaUnmap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    // Reparent (tab move / split) unmaps before unrealizing, and a
    // closed pane unmaps too — drop the AX element from the old window's
    // content view so a later map re-attaches against the right one.
    detachA11y(self);
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
                .paste_primary => clipboard.pastePrimaryFromClipboard(@ptrCast(self.surface.area), self.terminal),
                .paste_clipboard => clipboard.pasteFromClipboard(@ptrCast(self.surface.area), self.terminal),
                .menu, .none => {},
            }
        }
        return false;
    }

    // Menu rows act on the FOCUSED pane (the window-level sink has no
    // other handle on the pane the click landed in), so take the focus
    // here: right-clicking pane B while pane A had it must not run the
    // row against A.
    _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));

    // "Copy" and "Select Command Output" / "Copy Command Output" grey
    // out rather than silently doing nothing. Copy reads the SAME
    // selection model the mouse drives (word / line / rectangular all
    // set `selection.mode`), so there is no second notion of "what is
    // selected" here.
    // hasContent, not isActive: a bare left click leaves an active
    // but empty selection, which would keep Copy sensitive and
    // copying nothing.
    if (c.g_action_map_lookup_action(@ptrCast(group), "copy")) |act| {
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(screen.selection.hasContent()));
    }
    const output_avail = screen.lastCommandOutputAvailable();
    for ([_][*:0]const u8{ "copy-output", "select-output" }) |name| {
        if (c.g_action_map_lookup_action(@ptrCast(group), name)) |act| {
            c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(output_avail));
        }
    }
    // Nothing in the ring → nothing to clear, and Select All would
    // produce the same selection as selecting the screen.
    if (c.g_action_map_lookup_action(@ptrCast(group), "clear-scrollback")) |act| {
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(screen.scrollbackCount() > 0));
    }

    // The Session submenu splits into two independent conditions:
    //   - detach / rename / kill make sense on any DURABLE session
    //     (one that survives the pane closing). A plain local shell
    //     tab is GUI-owned and ephemeral, so they are meaningless.
    //   - upload / download only make sense when the PTY lives on
    //     ANOTHER machine (SSH / UDP host); file transfer to a local
    //     session is pointless.
    // menu.zig hides each group's rows (and the submenu shell) when
    // its representative action is left disabled.
    const is_durable = if (self.terminal.remote) |r| !r.ephemeral else false;
    const is_host_remote = if (self.terminal.remote) |r| r.host != null else false;
    for ([_][*:0]const u8{ "mux-detach", "mux-rename", "mux-kill" }) |name| {
        if (c.g_action_map_lookup_action(@ptrCast(group), name)) |act| {
            c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(is_durable));
        }
    }
    for ([_][*:0]const u8{ "upload-file", "download-file" }) |name| {
        if (c.g_action_map_lookup_action(@ptrCast(group), name)) |act| {
            c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(is_host_remote));
        }
    }

    // Recording rows: exactly one of the start/stop pair shows,
    // tracking the session's asciicast recording state.
    if (c.g_action_map_lookup_action(@ptrCast(group), "record-session")) |act| {
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(!self.terminal.recording));
    }
    if (c.g_action_map_lookup_action(@ptrCast(group), "record-stop")) |act| {
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(self.terminal.recording));
    }

    // Free any URI captured from a previous popup.
    if (self.menu_link_uri) |old| {
        self.allocator.free(old);
        self.menu_link_uri = null;
    }

    var has_link = false;
    const cell = self.surface.cellAt(x, y);
    // A negative anchor means the menu was opened from OUTSIDE the
    // grid (the pane titlebar, which sits above it). cellAt clamps
    // such coordinates to cell (0,0), so probing would report a link
    // belonging to the top-left cell that the user never pointed at.
    const on_grid = x >= 0 and y >= 0;
    if (on_grid and cell.col >= 0 and cell.col < screen.cols) {
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
            if (self.surface.bidiEnabled()) {
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

    // No OSC 8 link — fall back to the auto-URL detector, same as
    // hover and Ctrl+click do.
    if (on_grid and !has_link and self.surface.urlDetectEnabled()) {
        if (screen.urlAtVisible(self.allocator, cell.row, cell.col) catch null) |url| {
            self.menu_link_uri = url;
            has_link = true;
        }
    }

    for ([_][*:0]const u8{ "copy-link", "open-link" }) |name| {
        if (c.g_action_map_lookup_action(@ptrCast(group), name)) |act| {
            c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), if (has_link) 1 else 0);
        }
    }
    return true;
}

/// Click on the per-pane title bar. Focuses the underlying GLArea
/// so the running shell receives keystrokes — without this, clicking
/// the bar would just trap focus on the (un-focusable) Box.
fn onTitlebarClicked(_: *c.GtkGestureClick, n_press: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));
    // Double-click → dispatch the menu's `set_pane_title` action
    // (same path as the right-click "Set Pane Title…" entry).
    if (n_press == 2) {
        paneMenuSink(@ptrCast(self), .set_pane_title);
    }
}

/// Right-click on the per-pane titlebar → the pane's context menu.
/// The popover is parented to the GLArea, so the titlebar-local
/// pointer position is translated into area coordinates first; the
/// resulting y is NEGATIVE (the bar sits above the grid), which is
/// exactly what tells `paneMenuPrePopup` not to probe for a link.
fn onTitlebarRightClicked(g: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    if (self.nonTerminalFaceVisible()) return;
    const widget = c.gtk_event_controller_get_widget(@ptrCast(@alignCast(g))) orelse return;
    var out: c.graphene_point_t = undefined;
    const from = c.graphene_point_t{ .x = @floatCast(x), .y = @floatCast(y) };
    if (c.gtk_widget_compute_point(widget, @ptrCast(self.surface.area), &from, &out) == 0) return;
    // Claim before popping up, for the same reason menu.zig's own
    // gesture does: an unclaimed RELEASE dismisses the fresh popover.
    _ = c.gtk_gesture_set_state(@ptrCast(@alignCast(g)), c.GTK_EVENT_SEQUENCE_CLAIMED);
    _ = menu.popupAt(@ptrCast(self.surface.area), @floatCast(out.x), @floatCast(out.y));
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
    if (self.input_ctx) |ictx| if (ictx.im) |im| im.focusIn();
    // Cursor style + focus border switch on focus change — force a
    // repaint so the swap is immediate.
    self.terminal.screen.cursor_blink_on = true;
    self.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
    // Per-pane titlebar: red (active) when this pane has focus.
    self.setTitlebarActive(true);
    // Inactive-pane dimming: full brightness now.
    self.surface.setFocused(true);
    // Record this pane as its tab's last-focused, for tab-switch restore.
    if (self.win_on_focus_enter) |f| f(self.win_focus_ctx, self);
    // Cursor blink starts now (timer self-removes on focus loss).
    self.surface.ensureBlinkTimer();
}

fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    if (self.terminal.screen.focus_reports) {
        self.terminal.writeRaw("\x1b[O");
    }
    if (self.input_ctx) |ictx| if (ictx.im) |im| im.focusOut();
    self.terminal.screen.cursor_blink_on = true;
    self.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
    // Per-pane titlebar: grey (inactive) when focus leaves.
    self.setTitlebarActive(false);
    // Inactive-pane dimming: apply the configured factors.
    self.surface.stopBlinkTimer();
    self.surface.setFocused(false);
}

fn onMotion(g: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);

    // Restore the cursor if mouse_autohide hid it on the last keystroke.
    if (self.cursor_hidden) {
        self.cursor_hidden = false;
        c.gtk_widget_set_cursor(@ptrCast(self.surface.area), null);
    }

    // A held thumb owns the pointer; a hover over the track keeps
    // motion reports (and link hovers) off the app's plate.
    if (self.sb_dragging) return;
    if (overScrollbar(self, x, y)) {
        c.gtk_widget_set_tooltip_text(@ptrCast(self.surface.area), null);
        if (self.cursor_over_link) {
            c.gtk_widget_set_cursor(@ptrCast(self.surface.area), null);
            self.cursor_over_link = false;
        }
        return;
    }

    const cell = self.surface.cellAt(x, y);
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
            writeMouseEvent(self, 32 + base, @as(u32, @intCast(cell.col + 1)), @as(u32, @intCast(cell.row + 1)), x, y, true);
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
                self.setLinkTooltip(uri);
                over_link = true;
            }
        }
        if (!over_link and self.surface.urlDetectEnabled()) {
            if (screen.urlAtVisible(self.allocator, @intCast(c_row), @intCast(c_col)) catch null) |url| {
                defer self.allocator.free(url);
                self.setLinkTooltip(url);
                over_link = true;
            }
        }
    }
    if (!over_link) c.gtk_widget_set_tooltip_text(@ptrCast(self.surface.area), null);

    // Cursor shape flip — only on transitions, not every motion event,
    // to avoid hammering gtk_widget_set_cursor with redundant calls.
    if (over_link and !self.cursor_over_link) {
        c.gtk_widget_set_cursor_from_name(@ptrCast(self.surface.area), "pointer");
        self.cursor_over_link = true;
    } else if (!over_link and self.cursor_over_link) {
        c.gtk_widget_set_cursor(@ptrCast(self.surface.area), null);
        self.cursor_over_link = false;
    }
}

/// True when the pointer is over the scrollbar track. Consulted
/// BEFORE mouse reporting so the scrollbar stays usable while an app
/// holds the mouse — but only for points actually over it, so every
/// other pixel of the pane keeps reaching the app.
fn overScrollbar(self: *Pane, x: f64, y: f64) bool {
    const g = self.surface.scrollbarGeom() orelse return false;
    return scrollbar.hitTest(g.layout, self.surface.toPhysical(x), self.surface.toPhysical(y)) != .none;
}

fn setViewOffset(self: *Pane, off: u32) void {
    if (self.terminal.screen.view_offset == off) return;
    self.terminal.screen.view_offset = off;
    c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
}

/// Button-1 press over the scrollbar: grab the thumb, or page toward
/// a click in the trough. Returns true when the press was consumed.
fn scrollbarPress(self: *Pane, x: f64, y: f64) bool {
    const g = self.surface.scrollbarGeom() orelse return false;
    const py = self.surface.toPhysical(y);
    switch (scrollbar.hitTest(g.layout, self.surface.toPhysical(x), py)) {
        .none => return false,
        .thumb => {
            self.sb_dragging = true;
            self.sb_drag_dy = py - g.layout.thumb_y;
        },
        .page_up => setViewOffset(self, scrollbar.pageOffset(g.view, true)),
        .page_down => setViewOffset(self, scrollbar.pageOffset(g.view, false)),
    }
    return true;
}

/// Pointer moved while the thumb is held: map its top edge back to a
/// view offset.
fn scrollbarDrag(self: *Pane, y: f64) void {
    const g = self.surface.scrollbarGeom() orelse return;
    const thumb_y = self.surface.toPhysical(y) - self.sb_drag_dy;
    setViewOffset(self, scrollbar.offsetForThumbTop(g.view, g.layout, thumb_y));
}

fn onDragBegin(g: *c.GtkGestureDrag, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    // Always grab focus on click.
    _ = c.gtk_widget_grab_focus(@ptrCast(self.surface.area));

    // Overlay scrollbar first — it outranks selection AND the app's
    // mouse mode, but only for presses actually on the track.
    if (scrollbarPress(self, x, y)) return;

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
            c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
            self.a11yNudge();
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
            c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
            self.a11yNudge();
        }
        return;
    }

    const cell = self.surface.cellAtLogical(x, y);
    const mode: @import("../grid/selection.zig").Mode = if (alt_held) .rectangular else .normal;
    self.terminal.screen.selection.start(cell.row, cell.col, mode);
    c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
    self.a11yNudge();
}

fn onMousePressed(g: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);
    const button = c.gtk_gesture_single_get_current_button(@ptrCast(g));

    // A press on the overlay scrollbar belongs to it (the drag
    // gesture already acted on it) — never to the app, and never to
    // middle-click paste or the gutter/word-selection paths.
    if (self.sb_dragging or overScrollbar(self, x, y)) return;

    // Middle-click PRIMARY paste when the running app isn't asking
    // for mouse reports. With mouse_mode > 0 the app sees the click.
    // `disable_mouse_paste` opts out of this entirely.
    if (button == 2 and self.terminal.screen.mouse_mode == 0) {
        if (self.disable_mouse_paste) return;
        switch (self.middle_click_action) {
            .paste_primary => clipboard.pastePrimaryFromClipboard(@ptrCast(self.surface.area), self.terminal),
            .paste_clipboard => clipboard.pasteFromClipboard(@ptrCast(self.surface.area), self.terminal),
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
        const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@ptrCast(self.surface.area)));
        if (x * scale < @as(f64, @floatCast(self.surface.padPhysical()))) {
            const cell = self.surface.cellAt(x, y);
            if (self.terminal.screen.selectCmdZoneAt(cell.row)) {
                self.pushSelectionToClipboards();
                c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
                self.a11yNudge();
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
                c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
                self.a11yNudge();
            }
            return;
        }

        const cell = self.surface.cellAtLogical(x, y);
        const screen = self.terminal.screen;
        if (n_press == 2) {
            screen.selectWordAt(cell.row, cell.col);
        } else { // 3+
            screen.selectLineAt(cell.row);
        }
        // Push the new selection text to PRIMARY for middle-click
        // paste; also to SYSTEM clipboard if copy_on_selection is on.
        self.pushSelectionToClipboards();
        c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
        self.a11yNudge();
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
    if (self.sb_dragging or overScrollbar(self, x, y)) return;
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
    const cell = self.surface.cellAt(x, y);
    if (cell.row < 0 or cell.col < 0) return;
    writeMouseEvent(self, @intCast(xterm_button), @intCast(cell.col + 1), @intCast(cell.row + 1), x, y, press);
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
                0x1B,                         '[',                'M',
                @intCast(@min(cb_val, 0xFF)), @intCast(cx_clamp), @intCast(cy_clamp),
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
    if (self.sb_dragging) {
        scrollbarDrag(self, sy + dy);
        return;
    }
    const cell = self.surface.cellAtLogical(sx + dx, sy + dy);
    self.terminal.screen.selection.extend(cell.row, cell.col);
    c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
    self.a11yNudge();
}

fn onDragEnd(g: *c.GtkGestureDrag, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Pane, user);

    // Scrollbar drag: no selection to push, no link to follow.
    if (self.sb_dragging) {
        self.sb_dragging = false;
        return;
    }

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
    const cell = self.surface.cellAt(sx, sy);
    if (cell.row < 0 or cell.col < 0) return;
    const screen = self.terminal.screen;
    if (cell.row >= screen.rows or cell.col >= screen.cols) return;
    const cell_data = screen.cellAt(@intCast(cell.row), @intCast(cell.col));

    // OSC 8 hyperlink — preferred path when the cell carries one.
    if (cell_data.flags & 0b0000_0100 != 0) {
        if (screen.linkUri(cell_data.reserved)) |uri| {
            launchUri(uri);
            return;
        }
    }

    // No OSC 8 — fall back to the auto-URL detector.
    if (!self.surface.urlDetectEnabled()) return;
    const url = (screen.urlAtVisible(self.allocator, cell.row, cell.col) catch null) orelse return;
    defer self.allocator.free(url);
    launchUri(url);
}

/// Open a URI with the desktop's default handler.
fn launchUri(uri: []const u8) void {
    var buf: [4096]u8 = undefined;
    const n = @min(uri.len, buf.len - 1);
    @memcpy(buf[0..n], uri[0..n]);
    buf[n] = 0;
    var err: ?*c.GError = null;
    if (c.g_app_info_launch_default_for_uri(&buf, null, &err) == 0) {
        if (err) |e| {
            std.log.warn("open link failed: {s}", .{e.message});
            c.g_error_free(e);
        }
    }
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
                    self.surface.setFontSize(@min(self.surface.font_size + 1, 72));
                } else if (dy > 0) {
                    self.surface.setFontSize(@max(self.surface.font_size - 1, 6));
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
        const cw_px: f64 = if (self.surface.cellPixelSize()) |cs| @floatFromInt(cs.w) else 0.0;
        const ch_px: f64 = if (self.surface.cellPixelSize()) |cs| @floatFromInt(cs.h) else 0.0;
        const px = @as(f64, @floatFromInt(col)) * cw_px;
        const py = @as(f64, @floatFromInt(row)) * ch_px;
        writeMouseEvent(self, button, @as(u32, @intCast(col + 1)), @as(u32, @intCast(row + 1)), px, py, true);
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
    c.gtk_gl_area_queue_render(@ptrCast(self.surface.area));
    return 1;
}
