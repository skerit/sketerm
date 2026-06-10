//! Window — wraps an AdwApplicationWindow with AdwTabView + TabBar.
//!
//! Each tab hosts one Pane (one Terminal). Multi-pane (split) per
//! tab arrives in M7.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Pane = @import("pane.zig").Pane;
const Pty = @import("../pty.zig").Pty;
const Terminal = @import("../terminal.zig").Terminal;
const layout_mod = @import("../layout.zig");
const palette_mod = @import("palette.zig");
const clipboard = @import("clipboard.zig");
const Config = @import("../config.zig").Config;

/// One-shot hint. Reset to false at startup; flipped on first
/// `always_on_top = true` so we don't spam the log on every
/// applyConfigChange.
var always_on_top_warned: bool = false;

/// Broadcast typing mode. Off / group / all — Terminator semantics.
pub const GroupSend = enum { off, group, all };

/// Snapshot of a closed tab's restorable state. Owned strings live
/// in `Window.closed_arena`. Recent ring grows up to 16 entries.
pub const ClosedTab = struct {
    title: []const u8,
    cwd: ?[]const u8 = null,
    profile_name: ?[]const u8 = null,
};

/// Owned ratio holder for `applyPanedRatio` / `applyPanedRatioMap` /
/// `freePanedRatio`. Carries its own allocator so the GTK destroy-notify
/// can free without needing a Window pointer.
/// Live ratio tracker for a GtkPaned. `ratio` is updated whenever the
/// user drags (via notify::position) and re-applied on every map (via
/// the map signal). Tab switches unmap+remap the paged subtree; without
/// re-apply, GtkPaned reverts to natural sizes on remap.
///
/// `setting` guards against the feedback loop: our own gtk_paned_set_
/// position triggers notify::position, which would re-read total (which
/// may be transient during allocation) and corrupt ratio. We bracket
/// every set_position with setting=true so the notify handler ignores
/// our own writes.
const PanedRatioCtx = struct {
    allocator: std.mem.Allocator,
    ratio: f32,
    setting: bool = false,
};

/// Smallest M such that `scale * M` is integer (within 1e-3 tolerance).
/// 1.0 → 1, 1.5 → 2, 1.25/1.75 → 4. Caps at 16; anything past that we
/// pretend is integer (no realistic compositor reports those scales).
///
/// Used to snap GtkPaned divider positions to a logical-pixel grid that
/// maps onto integer device pixels at the current surface scale —
/// without this, GtkGraphicsOffload rejects every frame at fractional
/// scale and GTK silently falls back to the GSK FBO composite path
/// (which c3db441 was supposed to escape). Diagnose with
/// `GDK_DEBUG=offload` — the "Non-integral device coordinates" line
/// is the rejection.
fn alignmentForScale(scale: f64) u32 {
    if (scale <= 0) return 1;
    const tol: f64 = 1e-3;
    var m: u32 = 1;
    while (m <= 16) : (m += 1) {
        const v = scale * @as(f64, @floatFromInt(m));
        if (@abs(v - @round(v)) < tol) return m;
    }
    return 1;
}

/// Surface scale for `widget`'s native, or 1.0 if not realized yet.
fn widgetSurfaceScale(widget: *c.GtkWidget) f64 {
    const native = c.gtk_widget_get_native(widget) orelse return 1.0;
    const surface = c.gtk_native_get_surface(native) orelse return 1.0;
    return c.gdk_surface_get_scale(surface);
}

/// Round `pos` down to the nearest multiple of M that's still > 0.
fn snapDown(pos: c_int, m: u32) c_int {
    if (m <= 1) return pos;
    if (pos <= 0) return pos;
    const im: c_int = @intCast(m);
    const snapped = @divFloor(pos, im) * im;
    return if (snapped <= 0) im else snapped;
}

/// Called from user-triggered action dispatch (menu items, keybinds,
/// window callbacks) when a fallible op (`newShellTab`, `splitFocused`,
/// …) fails. The previous `catch {}` swallowed errors silently — the
/// user clicked, nothing happened, and there was no log line.
fn logActionError(action: []const u8, err: anyerror) void {
    std.debug.print("sketerm: action '{s}' failed: {s}\n", .{ action, @errorName(err) });
}

pub const Window = struct {
    app_window: *c.GtkWidget,
    tab_view: *c.AdwTabView,
    /// Held so applyConfigChange can re-parent the tab bar between
    /// top and bottom of the toolbar view at runtime.
    tab_bar: *c.GtkWidget,
    toolbar_view: *c.GtkWidget,
    title_buf: [256]u8 = undefined,
    panes: std.ArrayList(*Pane) = .empty,
    terminals: std.ArrayList(*Terminal) = .empty,
    allocator: std.mem.Allocator,
    tab_counter: u32 = 0,
    debug_events: bool = false,
    debug_images: bool = false,
    config: Config = .{},
    /// Scrollback search (Ctrl+F).
    search_bar: ?*c.GtkWidget = null,
    search_entry: ?*c.GtkWidget = null,
    search_label: ?*c.GtkWidget = null,
    search_pane: ?*Pane = null,
    search_matches: std.ArrayList(@import("../grid/screen.zig").Screen.SearchMatch) = .empty,

    /// Keyboard-hints (quick-select) mode state. `hints_pane` non-null
    /// = mode active on that pane; its input Ctx then routes keys to
    /// `onHintKey`. `hint_matches` owns the extracted texts.
    hints_pane: ?*Pane = null,
    hint_matches: []@import("hints.zig").Match = &.{},
    hints_typed: [2]u8 = .{ 0, 0 },
    hints_typed_len: u8 = 0,
    hints_overlay_buf: std.ArrayList(@import("../grid/screen.zig").Screen.HintOverlay) = .empty,
    search_idx: usize = 0,
    /// Case-insensitive search toggle. Defaults to smart-case
    /// (lower-only needle implies CI; mixed-case implies CS).
    search_case_insensitive: bool = false,
    search_case_button: ?*c.GtkWidget = null,
    /// When set, skip the smart-case heuristic — every search is
    /// case-sensitive by default. Mirrors Config.search_case_sensitive.
    /// Ctrl+I still toggles per-search override.
    search_force_cs: bool = false,
    /// Regex-mode toggle (Ctrl+R inside the search bar). When on,
    /// the entry text is treated as POSIX Extended Regular Expression.
    search_regex: bool = false,
    /// Resolved custom keybinding table. Built from
    /// `Config.keybinds` overlaid on `input.default_bindings`, sorted
    /// for first-match dispatch in `onKeyPressed`. Re-resolved on
    /// every `applyConfigChange`.
    bindings: std.ArrayList(@import("input.zig").Binding) = .empty,

    /// CSS provider for the per-pane titlebar colour classes
    /// (sketerm-titlebar-active / -inactive). Loaded lazily on first
    /// applyConfigChange or initial show; regenerated whenever
    /// title_*_* colours change.
    titlebar_css: ?*c.GtkCssProvider = null,

    /// Sub-notch accumulator for tab-bar scroll → tab switch.
    /// Touchpads emit many small dy events per gesture; we sum them
    /// and only flip a tab once |accum| crosses 1.0.
    tab_scroll_accum: f64 = 0,
    /// Broadcast typing mode. Off = each pane gets its own keystrokes
    /// (default). Group = fan out to every pane sharing the source's
    /// `group` name. All = fan out to every pane in this window.
    groupsend: GroupSend = .off,
    /// Recently-closed tab ring. Newest entry at the end; cap at 16.
    /// Strings owned by `closed_arena`.
    closed_tabs: std.ArrayList(ClosedTab) = .empty,
    closed_arena: ?std.heap.ArenaAllocator = null,

    pub fn init(allocator: std.mem.Allocator, app: ?*c.GtkApplication) !*Window {
        return initWithConfig(allocator, app, null);
    }

    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        app: ?*c.GtkApplication,
        config_override: ?Config,
    ) !*Window {
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);

        const app_window = c.adw_application_window_new(app);
        c.gtk_window_set_title(@ptrCast(app_window), "sketerm");
        // refreshWindowTitle re-applies once groupsend / etc. settle.
        c.gtk_window_set_default_size(@ptrCast(app_window), 1000, 700);

        // Adw toolbar layout — gives us a header bar (= draggable
        // title region) on top, the tab bar under that, and the tab
        // view as the main content. Without the header bar there's
        // no drag handle for the window.
        const toolbar_view = c.adw_toolbar_view_new();
        const header_bar = c.adw_header_bar_new();
        const tab_bar_w = c.adw_tab_bar_new();
        const tab_view_w = c.adw_tab_view_new();
        c.adw_tab_bar_set_view(@ptrCast(tab_bar_w), @ptrCast(tab_view_w));
        c.adw_tab_bar_set_autohide(@ptrCast(tab_bar_w), 0);
        c.gtk_widget_set_vexpand(@ptrCast(@alignCast(tab_view_w)), 1);

        // "+" button in the header bar to create a new tab even when
        // there are no panes left to right-click on.
        const new_tab_btn = c.gtk_button_new_from_icon_name("list-add-symbolic");
        c.gtk_widget_set_tooltip_text(new_tab_btn, "New Tab (Ctrl+Shift+T)");
        c.gtk_actionable_set_action_name(@ptrCast(new_tab_btn), "win.new-tab");
        c.adw_header_bar_pack_start(@ptrCast(header_bar), new_tab_btn);

        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar_view), header_bar);
        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar_view), @ptrCast(@alignCast(tab_bar_w)));
        c.adw_toolbar_view_set_content(@ptrCast(toolbar_view), @ptrCast(@alignCast(tab_view_w)));

        // Scrollback search bar — bottom of the window. Hidden by
        // default; revealed by Ctrl+F (search_open shortcut).
        const search_bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_margin_start(search_bar, 8);
        c.gtk_widget_set_margin_end(search_bar, 8);
        c.gtk_widget_set_margin_top(search_bar, 4);
        c.gtk_widget_set_margin_bottom(search_bar, 4);
        c.gtk_widget_set_visible(search_bar, 0);
        const search_entry = c.gtk_search_entry_new();
        c.gtk_widget_set_hexpand(search_entry, 1);
        const search_label = c.gtk_label_new("");
        const prev_btn = c.gtk_button_new_from_icon_name("go-up-symbolic");
        c.gtk_widget_set_tooltip_text(prev_btn, "Previous match (Shift+Enter)");
        const next_btn = c.gtk_button_new_from_icon_name("go-down-symbolic");
        c.gtk_widget_set_tooltip_text(next_btn, "Next match (Enter)");
        const close_btn = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_widget_set_tooltip_text(close_btn, "Close search (Esc)");
        c.gtk_box_append(@ptrCast(search_bar), search_entry);
        c.gtk_box_append(@ptrCast(search_bar), search_label);
        c.gtk_box_append(@ptrCast(search_bar), prev_btn);
        c.gtk_box_append(@ptrCast(search_bar), next_btn);
        c.gtk_box_append(@ptrCast(search_bar), close_btn);
        c.adw_toolbar_view_add_bottom_bar(@ptrCast(toolbar_view), search_bar);

        c.adw_application_window_set_content(@ptrCast(app_window), toolbar_view);

        // Double-click on the tab bar → rename the selected tab.
        // AdwTabBar handles single-click selection internally, so
        // by the time n_press == 2 fires, the tab is already current.
        const tabbar_dblclk = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(tabbar_dblclk), 1);
        _ = c.g_signal_connect_data(
            tabbar_dblclk,
            "pressed",
            @ptrCast(&onTabBarPressed),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.gtk_widget_add_controller(@ptrCast(@alignCast(tab_bar_w)), @ptrCast(tabbar_dblclk));

        // Scroll on the tab bar → switch tabs (Firefox / GNOME-Terminal
        // convention). dy<0 = scroll up = previous, dy>0 = scroll down
        // = next. Uses an `accum` field so a touchpad's many small
        // delta events still snap to one tab change per "notch"-ish.
        const tabbar_scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        // CAPTURE phase: AdwTabBar uses scroll internally to pan its
        // tab strip when tabs overflow; with the default BUBBLE phase
        // we'd never see the event. CAPTURE fires before children, so
        // we get first dibs and return TRUE to stop further handling.
        c.gtk_event_controller_set_propagation_phase(
            @ptrCast(tabbar_scroll),
            c.GTK_PHASE_CAPTURE,
        );
        _ = c.g_signal_connect_data(
            tabbar_scroll,
            "scroll",
            @ptrCast(&onTabBarScroll),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.gtk_widget_add_controller(@ptrCast(@alignCast(tab_bar_w)), @ptrCast(tabbar_scroll));

        self.* = .{
            .app_window = app_window,
            .tab_view = @ptrCast(tab_view_w),
            .tab_bar = @ptrCast(@alignCast(tab_bar_w)),
            .toolbar_view = @ptrCast(@alignCast(toolbar_view)),
            .allocator = allocator,
            .config = if (config_override) |co| co else Config.load(allocator),
            .search_bar = search_bar,
            .search_entry = search_entry,
            .search_label = search_label,
        };

        // Honour Config.show_tab_bar at startup. Default true matches
        // the GTK widget default; users can hide via config or the
        // toggle_tab_bar action at runtime.
        if (!self.config.show_tab_bar) c.gtk_widget_set_visible(self.tab_bar, 0);

        // Search wiring.
        _ = c.g_signal_connect_data(search_entry, "search-changed", @ptrCast(&onSearchChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(search_entry, "activate", @ptrCast(&onSearchActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(search_entry, "stop-search", @ptrCast(&onSearchStop), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(prev_btn, "clicked", @ptrCast(&onSearchPrev), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(next_btn, "clicked", @ptrCast(&onSearchNext), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(close_btn, "clicked", @ptrCast(&onSearchClose), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Shift+Enter on the entry → previous (entry "activate" only
        // fires plain Enter; intercept via a key-controller).
        const search_keys = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(search_keys, "key-pressed", @ptrCast(&onSearchKeyPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(search_entry, @ptrCast(search_keys));

        // When a tab is removed (close button, Ctrl+Shift+W, etc),
        // tear down the Pane + Terminal Zig-side state. AdwTabView
        // emits "page-detached" after the page is gone.
        _ = c.g_signal_connect_data(
            tab_view_w,
            "page-detached",
            @ptrCast(&onPageDetached),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Confirm-on-close gate. AdwTabView emits "close-page" before
        // detaching; returning TRUE = "I'll handle it asynchronously",
        // then we MUST call adw_tab_view_close_page_finish(view, page,
        // accept) once the user has decided. Returning FALSE on some
        // branches and TRUE on others races — always TRUE.
        _ = c.g_signal_connect_data(
            tab_view_w,
            "close-page",
            @ptrCast(&onClosePage),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Window-level close-request gate. Same idea: when there are
        // multiple panes/tabs, prompt before letting the toplevel die.
        _ = c.g_signal_connect_data(
            app_window,
            "close-request",
            @ptrCast(&onWindowCloseRequest),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Window-level "new-tab" GAction so the header-bar "+" button
        // works without a focused pane.
        const new_tab_action = c.g_simple_action_new("new-tab", null);
        _ = c.g_signal_connect_data(
            new_tab_action,
            "activate",
            @ptrCast(&onNewTabAction),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.g_action_map_add_action(@ptrCast(@alignCast(app_window)), @ptrCast(new_tab_action));
        c.g_object_unref(new_tab_action);

        // Move keyboard focus to the newly selected tab's pane.
        _ = c.g_signal_connect_data(
            tab_view_w,
            "notify::selected-page",
            @ptrCast(&onSelectedPageChanged),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Theme reactivity — when AdwStyleManager flips dark/light
        // (system-driven or user toggle), repaint every pane with
        // updated default colours (only when auto_theme is on).
        const sm = c.adw_style_manager_get_default();
        _ = c.g_signal_connect_data(
            @ptrCast(sm),
            "notify::dark",
            @ptrCast(&onThemeChanged),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Apply persisted tab_position. Init defaults to top via the
        // add_top_bar call earlier; only reposition on bottom.
        if (self.config.tab_position == .bottom) {
            self.setTabPosition(.bottom);
        }

        // Persisted search default + always-on-top advisory.
        self.search_force_cs = self.config.search_case_sensitive;
        self.setAlwaysOnTop(self.config.always_on_top);

        // Per-pane titlebar CSS — install once at startup. Pane init
        // adds the inactive class by default; refreshTitlebarCss
        // populates the colours.
        self.refreshTitlebarCss();

        // Resolve keybinds from defaults + Config overrides.
        self.refreshBindings();

        // After the window is realized we have a GdkSurface and can
        // tell the compositor not to assume our content is opaque.
        // Without this, blending behind transparent areas may not
        // happen even if our framebuffer alpha is < 1.0.
        _ = c.g_signal_connect_data(
            app_window,
            "realize",
            @ptrCast(&onWindowRealized),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        return self;
    }

    pub fn deinit(self: *Window) void {
        // Teardown order matters. Steps:
        //
        // 1. Null every Terminal sink + user_ctx so any
        //    `g_main_context_invoke(mainDrain, …)` already queued by
        //    a worker thread can't reach into a Pane via stale
        //    callback pointers — the dispatched mainDrain will see
        //    the cleared callbacks and produce no calls into Pane.
        // 2. Deinit terminals (joins their worker threads, drains
        //    the ring, frees PTY + parser + screen + style pool).
        //    After this returns, no further worker activity is
        //    possible against any of these terminals.
        // 3. Deinit panes (GL passes, atlas, IM context, arenas,
        //    GObject unrefs). Safe now that the terminal-side
        //    machinery is fully quiesced.
        //
        // Reversing #2 and #3 — the obvious order — would let a
        // late mainDrain dispatch into a freed Pane, since worker
        // joins happen inside Terminal.deinit, not before it.
        for (self.terminals.items) |t| t.clearSinks();
        for (self.terminals.items) |t| t.deinit();
        for (self.panes.items) |p| p.deinit();
        self.panes.deinit(self.allocator);
        self.terminals.deinit(self.allocator);
        self.search_matches.deinit(self.allocator);
        @import("hints.zig").freeMatches(self.allocator, self.hint_matches);
        self.allocator.free(self.hint_matches);
        self.hints_overlay_buf.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.closed_tabs.deinit(self.allocator);
        if (self.closed_arena) |*a| a.deinit();
        self.config.deinit();
        self.allocator.destroy(self);
    }

    // ── Keyboard hints (quick-select) ───────────────────────────

    /// Enter hint mode on the focused pane: scan the visible screen
    /// for URLs / paths / hashes, overlay labels, route keys to
    /// `onHintKey` until a label is completed or Esc.
    pub fn openHints(self: *Window) void {
        if (self.hints_pane != null) {
            self.exitHints();
            return;
        }
        const pane = self.focusedPane() orelse return;
        const hints_mod = @import("hints.zig");
        const matches = hints_mod.collectVisible(self.allocator, pane.terminal.screen) catch return;
        if (matches.len == 0) {
            self.allocator.free(matches);
            return;
        }
        self.hint_matches = matches;
        self.hints_pane = pane;
        self.hints_typed_len = 0;
        if (pane.input_ctx) |ictx| {
            ictx.hint_sink = onHintKey;
            ictx.hint_ctx = @ptrCast(self);
        }
        self.refreshHintOverlay();
    }

    pub fn exitHints(self: *Window) void {
        const pane = self.hints_pane orelse return;
        self.hints_pane = null;
        if (pane.input_ctx) |ictx| {
            ictx.hint_sink = null;
            ictx.hint_ctx = null;
        }
        pane.terminal.screen.hints_overlay = &.{};
        pane.terminal.screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(pane.area));
        @import("hints.zig").freeMatches(self.allocator, self.hint_matches);
        self.allocator.free(self.hint_matches);
        self.hint_matches = &.{};
        self.hints_overlay_buf.clearRetainingCapacity();
    }

    /// Rebuild the overlay slice from matches whose label starts with
    /// the typed prefix, then queue a redraw.
    fn refreshHintOverlay(self: *Window) void {
        const pane = self.hints_pane orelse return;
        self.hints_overlay_buf.clearRetainingCapacity();
        const typed = self.hints_typed[0..self.hints_typed_len];
        for (self.hint_matches) |m| {
            if (!std.mem.startsWith(u8, m.label[0..m.label_len], typed)) continue;
            self.hints_overlay_buf.append(self.allocator, .{
                .row = m.row,
                .col_start = m.col_start,
                .col_end = m.col_end,
                .label = m.label,
                .label_len = m.label_len,
                .typed = self.hints_typed_len,
            }) catch break;
        }
        pane.terminal.screen.hints_overlay = self.hints_overlay_buf.items;
        pane.terminal.screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(pane.area));
    }

    /// A label was completed: open URLs with the default handler;
    /// copy paths / hashes to both clipboards.
    fn activateHint(self: *Window, m: @import("hints.zig").Match) void {
        const pane = self.hints_pane orelse return;
        if (m.text.len == 0) return;
        switch (m.kind) {
            .url => {
                var buf: [4096]u8 = undefined;
                const n = @min(m.text.len, buf.len - 1);
                @memcpy(buf[0..n], m.text[0..n]);
                buf[n] = 0;
                _ = c.g_app_info_launch_default_for_uri(&buf, null, null);
            },
            .path, .hash => {
                const z = self.allocator.allocSentinel(u8, m.text.len, 0) catch return;
                defer self.allocator.free(z);
                @memcpy(z, m.text);
                clipboard.copyToClipboard(@ptrCast(pane.area), z);
                clipboard.copyToPrimary(@ptrCast(pane.area), z);
            },
        }
    }

    /// Open the scrollback search bar against the focused pane.
    pub fn openSearch(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        self.search_pane = pane;
        if (self.search_bar) |w| c.gtk_widget_set_visible(w, 1);
        if (self.search_entry) |w| {
            c.gtk_editable_set_text(@ptrCast(w), "");
            _ = c.gtk_widget_grab_focus(w);
        }
        self.search_matches.clearRetainingCapacity();
        self.search_idx = 0;
        // Stale highlights from a previous open should not bleed into
        // this fresh session.
        pane.terminal.screen.search_highlights = &.{};
        pane.terminal.screen.search_active_idx = -1;
        if (self.search_label) |l| c.gtk_label_set_text(@ptrCast(l), "");
    }

    /// Close the search bar and clear any selection used as highlight.
    pub fn closeSearch(self: *Window) void {
        if (self.search_bar) |w| c.gtk_widget_set_visible(w, 0);
        if (self.search_pane) |p| {
            p.terminal.screen.selection.clear();
            // Clear borrowed highlight slice BEFORE freeing the
            // backing storage — otherwise renderer reads dangling.
            p.terminal.screen.search_highlights = &.{};
            p.terminal.screen.search_active_idx = -1;
            p.terminal.screen.dirty = true;
            _ = c.gtk_widget_grab_focus(@ptrCast(p.area));
        }
        self.search_pane = null;
        self.search_matches.clearRetainingCapacity();
        self.search_idx = 0;
    }

    fn updateSearch(self: *Window, query: []const u8) void {
        const pane = self.search_pane orelse return;
        self.search_matches.deinit(self.allocator);
        self.search_matches = .empty;
        self.search_idx = 0;
        if (query.len > 0) {
            // Smart-case: lowercase-only needle implies CI; any
            // uppercase letter forces CS. The explicit per-search
            // toggle (Ctrl+I) and the config-level `search_case_sensitive`
            // both override.
            var ci = self.search_case_insensitive;
            if (!ci and !self.search_force_cs) {
                var has_upper = false;
                for (query) |b| {
                    if (b >= 'A' and b <= 'Z') {
                        has_upper = true;
                        break;
                    }
                }
                ci = !has_upper;
            }
            const matches = if (self.search_regex)
                pane.terminal.screen.searchOptsRegex(self.allocator, query, ci) catch return
            else
                pane.terminal.screen.searchOpts(self.allocator, query, ci) catch return;
            defer self.allocator.free(matches);
            self.search_matches.appendSlice(self.allocator, matches) catch return;
        }
        // Publish to the renderer — every match gets a translucent
        // overlay; the active one is brighter.
        pane.terminal.screen.search_highlights = self.search_matches.items;
        self.refreshSearchLabel();
        if (self.search_matches.items.len > 0) {
            // Jump to the last (most-recent) match — usually what users want.
            self.search_idx = self.search_matches.items.len - 1;
            pane.terminal.screen.search_active_idx = @intCast(self.search_idx);
            self.applyCurrentMatch();
        } else {
            pane.terminal.screen.selection.clear();
            pane.terminal.screen.search_active_idx = -1;
            pane.terminal.screen.dirty = true;
            // Pane is unfocused (search bar has focus); explicit
            // render needed to clear the previous highlight overlay.
            c.gtk_gl_area_queue_render(@ptrCast(pane.area));
        }
    }

    fn refreshSearchLabel(self: *Window) void {
        const lab = self.search_label orelse return;
        var buf: [64:0]u8 = undefined;
        if (self.search_matches.items.len == 0) {
            const s = std.fmt.bufPrintZ(&buf, "0/0", .{}) catch "0/0";
            c.gtk_label_set_text(@ptrCast(lab), s.ptr);
        } else {
            const s = std.fmt.bufPrintZ(&buf, "{d}/{d}", .{
                self.search_idx + 1,
                self.search_matches.items.len,
            }) catch "?/?";
            c.gtk_label_set_text(@ptrCast(lab), s.ptr);
        }
    }

    fn applyCurrentMatch(self: *Window) void {
        const pane = self.search_pane orelse return;
        if (self.search_matches.items.len == 0) return;
        const m = self.search_matches.items[self.search_idx];
        const screen = pane.terminal.screen;
        screen.search_active_idx = @intCast(self.search_idx);
        // Scroll into view.
        if (m.row < 0) {
            const dist: u32 = @intCast(-m.row);
            screen.view_offset = @min(screen.scrollbackCount(), dist);
        } else {
            screen.view_offset = 0;
        }
        screen.dirty = true;
        // Search interactions happen with the search bar focused,
        // not the pane — the pane's tick may be paused (no blink /
        // bell / animation). Without an explicit queue_render the
        // view-offset change wouldn't repaint until something else
        // wakes the GLArea.
        c.gtk_gl_area_queue_render(@ptrCast(pane.area));
        self.refreshSearchLabel();
    }

    fn nextMatch(self: *Window) void {
        if (self.search_matches.items.len == 0) return;
        self.search_idx = (self.search_idx + 1) % self.search_matches.items.len;
        self.applyCurrentMatch();
    }

    fn prevMatch(self: *Window) void {
        if (self.search_matches.items.len == 0) return;
        if (self.search_idx == 0) {
            self.search_idx = self.search_matches.items.len - 1;
        } else {
            self.search_idx -= 1;
        }
        self.applyCurrentMatch();
    }

    pub fn present(self: *Window) void {
        c.gtk_window_present(@ptrCast(self.app_window));
    }

    /// Quake-mode toggle. If the window is hidden / minimized,
    /// raise + focus it. Otherwise minimize. We minimize rather than
    /// `set_visible(false)` because hiding destroys the GdkSurface →
    /// GL context loss → atlas + image upload rebuild on every reveal.
    /// Wayland caveat: focus-stealing prevention may delay the raise.
    pub fn toggleQuake(self: *Window) void {
        const window: *c.GtkWindow = @ptrCast(@alignCast(self.app_window));
        // gtk_window_is_active reflects "this window has focus AND is
        // visible". Minimized windows return false; so do unfocused
        // ones. Combine with mapped-state to disambiguate.
        const mapped = c.gtk_widget_get_mapped(self.app_window) != 0;
        const active = c.gtk_window_is_active(window) != 0;
        if (mapped and active) {
            c.gtk_window_minimize(window);
        } else {
            c.gtk_window_unminimize(window);
            c.gtk_window_present(window);
        }
    }

    /// Spawn a new shell pane and add it as a tab.
    /// If title == null, a "Tab N" default is used.
    pub fn newShellTab(self: *Window, title_opt: ?[*:0]const u8) !void {
        return self.newShellTabWithProfile(title_opt, null);
    }

    pub fn newShellTabWithProfile(self: *Window, title_opt: ?[*:0]const u8, profile_name: ?[]const u8) !void {
        var num_buf: [32]u8 = undefined;
        const title = if (title_opt) |t| t else blk: {
            self.tab_counter += 1;
            const slice = std.fmt.bufPrintZ(&num_buf, "Tab {d}", .{self.tab_counter}) catch "shell";
            break :blk @as([*:0]const u8, slice.ptr);
        };
        // Inherit the focused pane's last-reported cwd (OSC 7) so a
        // new tab starts in the same directory — matches gnome-terminal /
        // kitty / wezterm convention. Falls back to inherited cwd
        // when no focused pane has reported one.
        const cwd = self.focusedPaneCwd();
        try self.addTabWithProfile(title, cwd, profile_name);
    }

    /// Spawn a tab via spawnShellPaneOpts (which honours the profile)
    /// and wrap it in an AdwTabPage. Used by newShellTabWithProfile
    /// and the right-click "as <profile>…" menu items.
    fn addTabWithProfile(
        self: *Window,
        title_z: [*:0]const u8,
        cwd: ?[]const u8,
        profile_name: ?[]const u8,
    ) !void {
        const pane = try self.spawnShellPaneOpts(cwd, profile_name);
        // spawnShellPaneOpts already appended to self.panes / .terminals.
        // Wrap pane.widget() in a Box so layout reparenting on splits
        // matches the addTabInternal path.
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_box_append(@ptrCast(wrapper), pane.widget());

        const page = self.appendOrInsertTab(wrapper);
        c.adw_tab_page_set_title(page, title_z);
        c.adw_tab_page_set_tooltip(page, title_z);
    }

    /// Last-reported cwd of the focused pane (OSC 7), or null if no
    /// pane has the focus or no cwd has been reported.
    fn focusedPaneCwd(self: *Window) ?[]const u8 {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return null;
        for (self.panes.items) |p| {
            if (focus == @as(*c.GtkWidget, @ptrCast(p.area))) {
                return p.terminal.cwd;
            }
        }
        return null;
    }

    /// Spawn a new tab from a layout TabSpec (used on --restore).
    /// Handles both v2 (tree) and v1-compat (cwd/command) fields.
    pub fn newTabFromSpec(self: *Window, spec: @import("../layout.zig").TabSpec) !void {
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_widget_set_hexpand(wrapper, 1);

        const root_widget = try self.buildTreeWidget(spec.tree);
        c.gtk_box_append(@ptrCast(wrapper), root_widget);

        const title_z = try self.allocator.allocSentinel(u8, spec.title.len, 0);
        defer self.allocator.free(title_z);
        @memcpy(title_z, spec.title);

        const page = self.appendOrInsertTab(wrapper);
        c.adw_tab_page_set_title(page, title_z.ptr);
        c.adw_tab_page_set_tooltip(page, title_z.ptr);
        if (spec.pinned) c.adw_tab_view_set_page_pinned(self.tab_view, page, 1);
    }

    fn buildTreeWidget(self: *Window, tree: @import("../layout.zig").Tree) !*c.GtkWidget {
        switch (tree) {
            .pane => |p| {
                if (p.command.len == 0) return error.EmptyCommand;

                // Resolve profile (if any) so we can honour profile.shell
                // override before constructing argv.
                const profile: ?*const @import("../config.zig").Profile = if (p.profile.len > 0)
                    self.findProfile(p.profile)
                else
                    null;

                var argv_buf = try self.allocator.alloc([*:0]const u8, p.command.len);
                defer self.allocator.free(argv_buf);
                var arg_owners: std.ArrayList([:0]u8) = .empty;
                defer {
                    for (arg_owners.items) |s| self.allocator.free(s);
                    arg_owners.deinit(self.allocator);
                }
                for (p.command, 0..) |cmd, i| {
                    // Profile.shell overrides command[0] if set, so
                    // duplicating an "ssh" profile keeps using ssh
                    // even after a layout round-trip captured the
                    // current $SHELL.
                    const eff_cmd: []const u8 = if (i == 0 and profile != null and profile.?.shell.len > 0)
                        profile.?.shell
                    else
                        cmd;
                    const z = try self.allocator.allocSentinel(u8, eff_cmd.len, 0);
                    try arg_owners.append(self.allocator, z);
                    @memcpy(z, eff_cmd);
                    argv_buf[i] = z.ptr;
                }

                var pty = try Pty.spawn(.{
                    .argv = argv_buf,
                    .cwd = p.cwd,
                    .rows = 24,
                    .cols = 80,
                });
                errdefer pty.closeAndReap();

                const term = try Terminal.init(self.allocator, pty, 80, 24);
                errdefer term.deinit();
                term.debug_to_stderr = self.debug_events;

                const pane = try self.makePane(term);
                pane.setSpawnArgv(argv_buf);
                pane.win_clip_ctx = @ptrCast(self);
                pane.win_on_clipboard = onTermClipboardSet;
                pane.win_notify_ctx = @ptrCast(self);
                pane.win_on_notification = onTermNotification;
                pane.win_bell_ctx = @ptrCast(self);
                pane.win_on_bell = onTermBell;
                pane.win_child_ctx = @ptrCast(self);
                pane.win_on_child_exit = onTermChildExit;
                pane.win_cwd_ctx = @ptrCast(self);
                pane.win_on_cwd = onTermCwdChanged;
                // Profile name on the pane so cycle/restore tracks it.
                if (profile) |pr| pane.active_profile = pr.name;
                // Effective font: profile > spec.font_size > global.
                pane.font_size = if (profile) |pr|
                    (if (pr.font_size != 0) pr.font_size else (p.font_size orelse self.config.font_size))
                else
                    (p.font_size orelse self.config.font_size);
                pane.font_path = if (profile) |pr|
                    (if (pr.font_path.len > 0) pr.font_path else self.config.font_path)
                else
                    self.config.font_path;
                const eff_fam: []const u8 = if (profile) |pr|
                    (if (pr.font_family.len > 0) pr.font_family else self.config.font_family)
                else
                    self.config.font_family;
                pane.font_family = if (eff_fam.len > 0) eff_fam else null;
                pane.cursor_blink_us = @as(i64, @intCast(self.config.cursor_blink_ms)) * 1000;
                pane.line_pad_px = self.config.line_pad_px;
                pane.grid_pass.pad = self.config.padding;
                pane.grid_pass.enable_ligatures = self.config.ligatures;
        pane.grid_pass.enable_bidi = self.config.bidi;

                try self.panes.append(self.allocator, pane);
                try self.terminals.append(self.allocator, term);
                return pane.widget();
            },
            .split => |s| {
                if (s.children.len < 2) return error.InvalidLayout;
                const orientation: c_uint = if (s.orientation == .horizontal)
                    @intCast(c.GTK_ORIENTATION_HORIZONTAL)
                else
                    @intCast(c.GTK_ORIENTATION_VERTICAL);
                const paned = c.gtk_paned_new(orientation);
                c.gtk_paned_set_resize_start_child(@ptrCast(paned), 1);
                c.gtk_paned_set_resize_end_child(@ptrCast(paned), 1);
                c.gtk_paned_set_shrink_start_child(@ptrCast(paned), 0);
                c.gtk_paned_set_shrink_end_child(@ptrCast(paned), 0);
                // Wide handle so GtkPaned honours CSS min-width on
                // the separator (gives us the gutter around the line).
                c.gtk_paned_set_wide_handle(@ptrCast(paned), 1);
                const first = try self.buildTreeWidget(s.children[0]);
                const second = try self.buildTreeWidget(s.children[1]);
                c.gtk_paned_set_start_child(@ptrCast(paned), first);
                c.gtk_paned_set_end_child(@ptrCast(paned), second);

                // Apply saved ratio after the widget gets its first
                // allocation. Until then we don't know the total
                // size in pixels.
                const ratio_holder = try self.allocator.create(PanedRatioCtx);
                ratio_holder.* = .{
                    .allocator = self.allocator,
                    .ratio = if (s.ratio > 0 and s.ratio < 1) s.ratio else 0.5,
                };
                _ = c.g_signal_connect_data(
                    paned,
                    "notify::position",
                    @ptrCast(&onPanedPositionChanged),
                    @ptrCast(ratio_holder),
                    @ptrCast(&freePanedRatio),
                    c.G_CONNECT_DEFAULT,
                );
                _ = c.g_signal_connect_data(
                    paned,
                    "map",
                    @ptrCast(&applyPanedRatioMap),
                    @ptrCast(ratio_holder),
                    null,
                    c.G_CONNECT_DEFAULT,
                );
                return paned;
            },
        }
    }

    fn addTabInternal(
        self: *Window,
        title_z: [*:0]const u8,
        argv: []const [*:0]const u8,
        cwd: ?[]const u8,
    ) !void {
        var pty = try Pty.spawn(.{
            .argv = argv,
            .cwd = cwd,
            .rows = 24,
            .cols = 80,
            .login_shell = self.config.login_shell,
        });
        errdefer pty.closeAndReap();

        const term = try Terminal.init(self.allocator, pty, 80, 24);
        errdefer term.deinit();
        term.debug_to_stderr = self.debug_events;

        const pane = try self.makePane(term);
        pane.setSpawnArgv(argv);
        // If anything below this fails (alloc failure adding to the
        // panes/terminals list, etc.) we'd otherwise leave a Pane
        // alive whose Terminal we just reaped via the prior errdefer
        // — its on_* callbacks would still point at the dead
        // Terminal, and the next render would fault. Drop the Pane
        // explicitly on failure so neither side outlives the other.
        errdefer pane.deinit();

        // Forward terminal sinks to Window where appropriate.
        pane.win_clip_ctx = @ptrCast(self);
        pane.win_on_clipboard = onTermClipboardSet;
        pane.win_notify_ctx = @ptrCast(self);
        pane.win_on_notification = onTermNotification;
        pane.win_bell_ctx = @ptrCast(self);
        pane.win_on_bell = onTermBell;
        pane.win_child_ctx = @ptrCast(self);
        pane.win_on_child_exit = onTermChildExit;
        pane.win_cwd_ctx = @ptrCast(self);
        pane.win_on_cwd = onTermCwdChanged;
        // OSC 0/1/2 titles drive the AdwTabPage title — but only
        // until the user explicitly renames the tab (which sets the
        // "user-locked" flag on the page). Renaming with an empty
        // string clears the lock and lets OSC tracking resume.
        pane.win_title_ctx = @ptrCast(self);
        pane.win_on_title = onTermTitleChanged;

        // Wrap pane.widget() in a Box so we can swap it for a Paned
        // when splits happen. Box always has exactly one child.
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_box_append(@ptrCast(wrapper), pane.widget());

        const page = self.appendOrInsertTab(wrapper);
        c.adw_tab_page_set_title(page, title_z);
        // Full-title tooltip — useful when titles are truncated.
        c.adw_tab_page_set_tooltip(page, title_z);

        try self.panes.append(self.allocator, pane);
        try self.terminals.append(self.allocator, term);
    }

    fn makePane(self: *Window, term: *Terminal) !*Pane {
        const pane = try Pane.init(self.allocator, term);
        if (pane.input_ctx) |ictx| {
            ictx.shortcut_sink = onShortcut;
            ictx.shortcut_ctx = @ptrCast(self);
            ictx.smart_copy = self.config.smart_copy;
            ictx.clear_select_on_copy = self.config.clear_select_on_copy;
            ictx.mouse_autohide = self.config.mouse_autohide;
            ictx.bindings = self.bindings.items;
        }
        pane.menu_sink = onMenuAction;
        pane.menu_sink_ctx = @ptrCast(self);
        pane.image_store.debug = self.debug_images;
        pane.image_pass.debug = self.debug_images;
        pane.terminal.screen.kitty_images.debug = self.debug_images;
        // Mouse / link flags from config.
        pane.copy_on_selection = self.config.copy_on_selection;
        pane.clear_select_on_copy = self.config.clear_select_on_copy;
        pane.disable_mouse_paste = self.config.disable_mouse_paste;
        pane.disable_mousewheel_zoom = self.config.disable_mousewheel_zoom;
        pane.link_single_click = self.config.link_single_click;
        pane.mouse_autohide = self.config.mouse_autohide;
        // Renderer bold flags.
        pane.grid_pass.allow_bold = self.config.allow_bold;
        pane.grid_pass.bold_is_bright = self.config.bold_is_bright;
        pane.cell_pass.allow_bold = self.config.allow_bold;
        pane.cell_pass.bold_is_bright = self.config.bold_is_bright;
        pane.grid_pass.enable_url_underline = self.config.auto_url_detect;
        // Per-pane titlebar visibility.
        pane.setTitlebarVisible(self.config.show_titlebar);
        // Inactive-pane dimming factors.
        pane.inactive_fg_dim = self.config.inactive_fg_dim;
        pane.inactive_bg_dim = self.config.inactive_bg_dim;
        pane.applyDim();
        return pane;
    }

    fn spawnShellPane(self: *Window) !*Pane {
        return self.spawnShellPaneOpts(null, null);
    }

    /// Snapshot a tab into the recently-closed ring before its panes
    /// are torn down. Stores title + first-pane cwd + active profile.
    /// Splits aren't preserved — the restore spawns a single shell.
    fn captureClosedTab(self: *Window, page: *c.AdwTabPage, root: *c.GtkWidget) void {
        if (self.closed_arena == null) {
            self.closed_arena = std.heap.ArenaAllocator.init(self.allocator);
        }
        const arena = self.closed_arena.?.allocator();

        // Title (AdwTabPage owns the string; dup into our arena).
        const title_c = c.adw_tab_page_get_title(page);
        const title_dup: []const u8 = if (title_c == null) "Tab" else blk: {
            const span = std.mem.span(@as([*:0]const u8, @ptrCast(title_c)));
            break :blk arena.dupe(u8, span) catch "Tab";
        };

        // Find the first pane in this page's tree → snapshot its cwd
        // + profile.
        var snap_cwd: ?[]const u8 = null;
        var snap_profile: ?[]const u8 = null;
        for (self.panes.items) |p| {
            if (widgetIsAncestor(root, p.widget())) {
                if (p.terminal.cwd) |c2| snap_cwd = arena.dupe(u8, c2) catch null;
                if (p.active_profile) |pn| snap_profile = arena.dupe(u8, pn) catch null;
                break;
            }
        }

        const entry: ClosedTab = .{
            .title = title_dup,
            .cwd = snap_cwd,
            .profile_name = snap_profile,
        };

        // Cap at 16; drop the oldest when full.
        const max_closed: usize = 16;
        if (self.closed_tabs.items.len >= max_closed) {
            _ = self.closed_tabs.orderedRemove(0);
        }
        self.closed_tabs.append(self.allocator, entry) catch {};
    }

    /// Pop the most-recently-closed tab and respawn it with its
    /// captured title / cwd / profile. No-op when the ring is empty.
    pub fn restoreLastClosed(self: *Window) void {
        if (self.closed_tabs.items.len == 0) return;
        const entry = self.closed_tabs.pop().?;
        // newShellTabWithProfile takes a NUL-terminated title.
        var title_buf: [256:0]u8 = undefined;
        const n = @min(entry.title.len, title_buf.len);
        @memcpy(title_buf[0..n], entry.title[0..n]);
        title_buf[n] = 0;
        const title_z: ?[*:0]const u8 = if (entry.title.len > 0) @ptrCast(&title_buf) else null;
        // The captured cwd is owned by closed_arena; the spawn path
        // dups it into the child PTY's env briefly so it's safe.
        const pane = self.spawnShellPaneOpts(entry.cwd, entry.profile_name) catch |err| {
            std.debug.print("sketerm: restore-closed-tab spawn failed: {s}\n", .{@errorName(err)});
            return;
        };
        // Wrap pane.widget() in a Box so layout reparenting works the
        // same as addTabWithProfile does.
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_box_append(@ptrCast(wrapper), pane.widget());
        const adw_page = self.appendOrInsertTab(wrapper);
        const title_for_page: [*:0]const u8 = title_z orelse "Tab";
        c.adw_tab_page_set_title(adw_page, title_for_page);
        c.adw_tab_page_set_tooltip(adw_page, title_for_page);
        _ = c.gtk_widget_grab_focus(@ptrCast(pane.area));
    }

    /// Look up a named profile in the active Config, or null if no
    /// such profile exists. Caller-borrowed slice (Config arena).
    pub fn findProfile(self: *const Window, name: []const u8) ?*const @import("../config.zig").Profile {
        if (name.len == 0) return null;
        for (self.config.profiles.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Spawn a shell with an optional starting cwd and named profile.
    /// Profile fields override the global Config: shell, font path,
    /// font size, $TERM, $COLORTERM, scrollback, login_shell, scheme,
    /// palette. Empty profile string / null profile = global config.
    fn spawnShellPaneOpts(self: *Window, inherit_cwd: ?[]const u8, profile_name: ?[]const u8) !*Pane {
        const profile: ?*const @import("../config.zig").Profile = if (profile_name) |n|
            self.findProfile(n)
        else if (self.config.default_profile.len > 0)
            self.findProfile(self.config.default_profile)
        else
            null;

        // Pick effective shell: profile.shell wins → Config.shell →
        // $SHELL env → /bin/bash.
        var shell_buf: [256:0]u8 = undefined;
        const eff_shell_str: ?[]const u8 = blk: {
            if (profile) |p| if (p.shell.len > 0) break :blk p.shell;
            if (self.config.shell) |s| break :blk s;
            break :blk null;
        };
        const shell: [*:0]const u8 = if (eff_shell_str) |s| blk: {
            const n = @min(s.len, shell_buf.len);
            @memcpy(shell_buf[0..n], s[0..n]);
            shell_buf[n] = 0;
            break :blk @ptrCast(&shell_buf);
        } else if (c.getenv("SHELL")) |env_ptr| @as([*:0]const u8, @ptrCast(env_ptr)) else "/bin/bash";

        const argv = [_][*:0]const u8{shell};

        // TERM / COLORTERM, profile-overridable.
        const eff_term: []const u8 = if (profile) |p|
            (if (p.term_env.len > 0) p.term_env else self.config.term_env)
        else
            self.config.term_env;
        const eff_color_term: []const u8 = if (profile) |p|
            (if (p.color_term_env.len > 0) p.color_term_env else self.config.color_term_env)
        else
            self.config.color_term_env;

        var term_buf: [64:0]u8 = undefined;
        var ct_buf: [64:0]u8 = undefined;
        const tlen = @min(eff_term.len, term_buf.len);
        @memcpy(term_buf[0..tlen], eff_term[0..tlen]);
        term_buf[tlen] = 0;
        const ctlen = @min(eff_color_term.len, ct_buf.len);
        @memcpy(ct_buf[0..ctlen], eff_color_term[0..ctlen]);
        ct_buf[ctlen] = 0;

        const eff_login_shell: bool = if (profile) |p|
            (p.login_shell orelse self.config.login_shell)
        else
            self.config.login_shell;

        var pty = try Pty.spawn(.{
            .argv = &argv,
            .rows = 24,
            .cols = 80,
            .term = @ptrCast(&term_buf),
            .color_term = @ptrCast(&ct_buf),
            .cwd = inherit_cwd,
            .login_shell = eff_login_shell,
        });
        errdefer pty.closeAndReap();

        const term = try Terminal.init(self.allocator, pty, 80, 24);
        errdefer term.deinit();
        term.debug_to_stderr = self.debug_events;

        const pane = try self.makePane(term);
        pane.setSpawnArgv(&argv);
        pane.win_clip_ctx = @ptrCast(self);
        pane.win_on_clipboard = onTermClipboardSet;
        pane.win_notify_ctx = @ptrCast(self);
        pane.win_on_notification = onTermNotification;
        pane.win_bell_ctx = @ptrCast(self);
        pane.win_on_bell = onTermBell;
        pane.win_child_ctx = @ptrCast(self);
        pane.win_on_child_exit = onTermChildExit;
        pane.win_cwd_ctx = @ptrCast(self);
        pane.win_on_cwd = onTermCwdChanged;

        // Profile name on the pane so cycle/restore knows which one
        // it spawned with.
        if (profile) |p| pane.active_profile = p.name;

        // Effective values per-field: profile wins over global.
        const eff_font_size: u16 = if (profile) |p|
            (if (p.font_size != 0) p.font_size else self.config.font_size)
        else
            self.config.font_size;
        const eff_font_path: ?[]const u8 = if (profile) |p|
            (if (p.font_path.len > 0) p.font_path else self.config.font_path)
        else
            self.config.font_path;
        const eff_font_family: []const u8 = if (profile) |p|
            (if (p.font_family.len > 0) p.font_family else self.config.font_family)
        else
            self.config.font_family;
        const eff_scrollback: u32 = if (profile) |p|
            (if (p.scrollback != 0) p.scrollback else self.config.scrollback)
        else
            self.config.scrollback;

        // Push config-derived fields into the pane before realize.
        pane.font_size = eff_font_size;
        pane.font_path = eff_font_path;
        pane.font_family = if (eff_font_family.len > 0) eff_font_family else null;
        pane.cursor_blink_us = @as(i64, @intCast(self.config.cursor_blink_ms)) * 1000;
        pane.grid_pass.pad = self.config.padding;
        const fg_bg = self.resolveDefaultColors();
        pane.grid_pass.default_fg = fg_bg.fg;
        pane.grid_pass.default_bg = fg_bg.bg;
        pane.grid_pass.enable_ligatures = self.config.ligatures;
        pane.grid_pass.enable_bidi = self.config.bidi;
        // Push config-driven defaults onto the screen so OSC 4/10/11
        // queries reply with the configured values until apps override.
        term.screen.default_fg = fg_bg.fg;
        term.screen.default_bg = fg_bg.bg;
        term.screen.cursor_color = if (self.config.cursor_color_default)
            .{ 0, 0, 0, 0 }
        else
            self.config.cursor_color;
        term.screen.scrollback_capacity = eff_scrollback;
        term.screen.bracketed_paste = self.config.bracketed_paste;
        term.screen.scroll_on_output = self.config.scroll_on_output;
        term.screen.word_chars = self.config.word_chars;
        // Resolve effective palette: profile.palette > config.palette
        // > profile.scheme lookup > config.scheme lookup > defaults.
        const eff_pal: ?[16][3]u8 = blk: {
            if (profile) |p| if (p.palette) |pp| break :blk pp;
            if (self.config.palette) |gp| break :blk gp;
            if (profile) |p| if (p.scheme.len > 0) {
                if (@import("../grid/schemes.zig").lookup(p.scheme)) |sch| break :blk sch.palette;
            };
            if (self.config.scheme.len > 0) {
                if (@import("../grid/schemes.zig").lookup(self.config.scheme)) |sch| {
                    break :blk sch.palette;
                }
            }
            break :blk null;
        };
        if (eff_pal) |pal| {
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                term.screen.palette[i] = pal[i];
                pane.grid_pass.palette[i] = pal[i];
            }
        }
        try self.panes.append(self.allocator, pane);
        try self.terminals.append(self.allocator, term);
        return pane;
    }

    /// Split the focused pane: spawn a new pane and place the two
    /// inside a GtkPaned. orientation = HORIZONTAL splits side-by-side,
    /// VERTICAL splits top/bottom.
    pub fn splitFocused(self: *Window, orientation: c_uint) !void {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return;

        // Find the focused Pane. The wrapper Box isn't focusable, so
        // gtk_window_get_focus returns the inner GLArea. Match against
        // p.area, then operate on p.widget() (== the wrapper) for
        // reparenting.
        var found_idx: ?usize = null;
        for (self.panes.items, 0..) |p, idx| {
            if (@intFromPtr(p.area) == @intFromPtr(focus)) {
                found_idx = idx;
                break;
            }
        }
        if (found_idx == null) return;
        const focused_pane = self.panes.items[found_idx.?];
        const focused_w = focused_pane.widget();

        const parent = c.gtk_widget_get_parent(focused_w) orelse return;

        // Inherit the focused pane's last-reported cwd (OSC 7) when
        // available, so the new shell starts in the same directory.
        // Falls back to inherited (parent process) cwd when null.
        const inherit_cwd: ?[]const u8 = focused_pane.terminal.cwd;
        // Splits inherit the focused pane's profile (matches Terminator).
        const new_pane = try self.spawnShellPaneOpts(inherit_cwd, focused_pane.active_profile);
        const new_w = new_pane.widget();

        const paned = c.gtk_paned_new(orientation);
        c.gtk_paned_set_resize_start_child(@ptrCast(paned), 1);
        c.gtk_paned_set_resize_end_child(@ptrCast(paned), 1);
        c.gtk_paned_set_shrink_start_child(@ptrCast(paned), 0);
        c.gtk_paned_set_shrink_end_child(@ptrCast(paned), 0);
        // Wide handle so GtkPaned honours CSS min-width on the
        // separator (gives us the gutter around the line).
        c.gtk_paned_set_wide_handle(@ptrCast(paned), 1);
        // Make the paned itself stretch to fill its container — without
        // this, a paned in a Box wrapper takes natural size only.
        c.gtk_widget_set_hexpand(@ptrCast(paned), 1);
        c.gtk_widget_set_vexpand(@ptrCast(paned), 1);

        // Without an explicit position, GtkPaned defaults to start_
        // child's natural size (which is 0 for an empty GLArea) — the
        // new pane ends up with zero width and renders black. Pre-
        // seed position to half the focused widget's current dim.
        const focused_dim: c_int = if (orientation == c.GTK_ORIENTATION_HORIZONTAL)
            c.gtk_widget_get_width(focused_w)
        else
            c.gtk_widget_get_height(focused_w);
        if (focused_dim > 0) {
            c.gtk_paned_set_position(@ptrCast(paned), @divFloor(focused_dim, 2));
        }
        // Safety net: also apply 0.5 ratio on map, in case the paned
        // gets a different allocation than its focused predecessor.
        const ratio_holder = try self.allocator.create(PanedRatioCtx);
        ratio_holder.* = .{ .allocator = self.allocator, .ratio = 0.5 };
        _ = c.g_signal_connect_data(
            paned,
            "notify::position",
            @ptrCast(&onPanedPositionChanged),
            @ptrCast(ratio_holder),
            @ptrCast(&freePanedRatio),
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            paned,
            "map",
            @ptrCast(&applyPanedRatioMap),
            @ptrCast(ratio_holder),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Hold an extra reference to focused_w during reparent — without
        // it, gtk_box_remove / gtk_paned_set_*_child(NULL) drops the
        // parent's only ref and destroys the widget before we can put
        // it in its new home.
        _ = c.g_object_ref(@ptrCast(@alignCast(focused_w)));
        defer c.g_object_unref(@ptrCast(@alignCast(focused_w)));

        const is_paned = c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(parent)),
            c.gtk_paned_get_type(),
        ) != 0;
        const is_box = c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(parent)),
            c.gtk_box_get_type(),
        ) != 0;

        if (is_paned) {
            const start = c.gtk_paned_get_start_child(@ptrCast(parent));
            const end = c.gtk_paned_get_end_child(@ptrCast(parent));
            if (start == focused_w) {
                c.gtk_paned_set_start_child(@ptrCast(parent), null);
                c.gtk_paned_set_start_child(@ptrCast(paned), focused_w);
                c.gtk_paned_set_end_child(@ptrCast(paned), new_w);
                c.gtk_paned_set_start_child(@ptrCast(parent), paned);
            } else if (end == focused_w) {
                c.gtk_paned_set_end_child(@ptrCast(parent), null);
                c.gtk_paned_set_start_child(@ptrCast(paned), focused_w);
                c.gtk_paned_set_end_child(@ptrCast(paned), new_w);
                c.gtk_paned_set_end_child(@ptrCast(parent), paned);
            }
        } else if (is_box) {
            c.gtk_box_remove(@ptrCast(parent), focused_w);
            c.gtk_paned_set_start_child(@ptrCast(paned), focused_w);
            c.gtk_paned_set_end_child(@ptrCast(paned), new_w);
            c.gtk_box_append(@ptrCast(parent), paned);
        }

        // Make sure the new GLArea has actually been kicked into life:
        // realize the GL context now (instead of waiting for the first
        // frame clock tick) and queue a draw so render fires.
        c.gtk_widget_queue_resize(new_w);
        c.gtk_gl_area_queue_render(@ptrCast(new_w));
        c.gtk_widget_queue_resize(@ptrCast(paned));

        _ = c.gtk_widget_grab_focus(focused_w);
    }

    /// Load the default last.json and rebuild tabs from it.
    pub fn loadLayoutDefault(self: *Window) !bool {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const path = try layout_mod.defaultSavePath(arena);
        var parsed = layout_mod.load(self.allocator, path) catch |err| {
            std.debug.print("sketerm: cannot load layout from {s}: {s}\n", .{ path, @errorName(err) });
            return false;
        };
        defer parsed.deinit();

        for (parsed.value.tabs) |tab| {
            self.newTabFromSpec(tab) catch |err| {
                std.debug.print("sketerm: load tab '{s}' failed: {s}\n", .{ tab.title, @errorName(err) });
            };
        }
        return true;
    }

    pub fn loadLayoutFromPath(self: *Window, path: []const u8) !bool {
        if (std.mem.endsWith(u8, path, ".layout")) {
            return self.loadLayoutSimple(path);
        }
        var parsed = layout_mod.load(self.allocator, path) catch |err| {
            std.debug.print("sketerm: cannot load layout from {s}: {s}\n", .{ path, @errorName(err) });
            return false;
        };
        defer parsed.deinit();
        for (parsed.value.tabs) |tab| {
            self.newTabFromSpec(tab) catch |err| {
                std.debug.print("sketerm: load tab '{s}' failed: {s}\n", .{ tab.title, @errorName(err) });
            };
        }
        return true;
    }

    fn loadLayoutSimple(self: *Window, path: []const u8) !bool {
        const layout_simple = @import("../layout_simple.zig");
        // Zig 0.16's `std.fs.cwd().openFile` requires an `Io`. Use libc.
        var path_z: [4096]u8 = undefined;
        if (path.len >= path_z.len) {
            std.debug.print("sketerm: path too long: {s}\n", .{path});
            return false;
        }
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        const fp = c.fopen(@ptrCast(&path_z), "rb") orelse {
            std.debug.print("sketerm: cannot open {s}\n", .{path});
            return false;
        };
        defer _ = c.fclose(fp);
        if (c.fseek(fp, 0, c.SEEK_END) != 0) return false;
        const size_long = c.ftell(fp);
        if (size_long <= 0 or size_long > 1024 * 1024) return false;
        if (c.fseek(fp, 0, c.SEEK_SET) != 0) return false;
        const size: usize = @intCast(size_long);
        const bytes = self.allocator.alloc(u8, size) catch return false;
        defer self.allocator.free(bytes);
        if (c.fread(bytes.ptr, 1, size, fp) != size) {
            std.debug.print("sketerm: short read on {s}\n", .{path});
            return false;
        }
        var parsed = layout_simple.parse(self.allocator, bytes) catch |err| {
            std.debug.print("sketerm: parse {s}: {s}\n", .{ path, @errorName(err) });
            return false;
        };
        defer parsed.deinit();
        for (parsed.value.tabs) |tab| {
            self.newTabFromSpec(tab) catch |err| {
                std.debug.print("sketerm: load tab '{s}' failed: {s}\n", .{ tab.title, @errorName(err) });
            };
        }
        return true;
    }

    pub fn closeCurrentTab(self: *Window) void {
        const sel = c.adw_tab_view_get_selected_page(self.tab_view);
        if (sel == null) return;
        _ = c.adw_tab_view_close_page(self.tab_view, sel);
        // Auto-spawn-on-last-close is handled in onPageDetached so it
        // also covers the AdwTabView "X" button path.
    }

    pub fn nextTab(self: *Window) void {
        _ = c.adw_tab_view_select_next_page(self.tab_view);
    }

    pub fn prevTab(self: *Window) void {
        _ = c.adw_tab_view_select_previous_page(self.tab_view);
    }

    const RenameCtx = struct {
        page: *c.AdwTabPage,
        popover: *c.GtkWidget,
        entry: *c.GtkWidget,
        allocator: std.mem.Allocator,
        window: *Window,
    };

    /// Show a popover with an entry pre-filled to the current tab's
    /// title. Pressing Enter renames; Escape dismisses.
    pub fn renameCurrentTab(self: *Window) void {
        self.renameCurrentTabAt(null);
    }

    /// Variant that anchors the popover at a specific point inside the
    /// tab bar — used by the double-click gesture so the popover
    /// pops up next to the tab the user double-clicked rather than
    /// dropping below the toplevel window (which puts it off-screen
    /// when the window is maximized).
    pub fn renameCurrentTabAt(self: *Window, click: ?struct { x: f64, y: f64 }) void {
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;

        const popover = c.gtk_popover_new();
        const entry = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Tab title");

        const current = c.adw_tab_page_get_title(page);
        if (current != null) {
            c.gtk_editable_set_text(@ptrCast(entry), current);
            c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
        }

        c.gtk_popover_set_child(@ptrCast(popover), entry);
        // Parent on the tab bar so the popover lands beneath the tab
        // strip, not beneath the whole window. Pointing_to narrows the
        // anchor point to the click location when known; otherwise we
        // anchor the popover under the visual center of the tab bar.
        c.gtk_widget_set_parent(popover, self.tab_bar);
        var alloc_w: c_int = 0;
        var alloc_h: c_int = 0;
        if (click) |pt| {
            const rect = c.GdkRectangle{
                .x = @intFromFloat(pt.x),
                .y = @intFromFloat(pt.y),
                .width = 1,
                .height = 1,
            };
            c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        } else {
            alloc_w = c.gtk_widget_get_width(self.tab_bar);
            alloc_h = c.gtk_widget_get_height(self.tab_bar);
            const rect = c.GdkRectangle{
                .x = @divFloor(alloc_w, 2),
                .y = @divFloor(alloc_h, 2),
                .width = 1,
                .height = 1,
            };
            c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        }

        const ctx = self.allocator.create(RenameCtx) catch return;
        ctx.* = .{
            .page = page,
            .popover = popover,
            .entry = entry,
            .allocator = self.allocator,
            .window = self,
        };

        _ = c.g_signal_connect_data(
            entry,
            "activate",
            @ptrCast(&onRenameActivate),
            @ptrCast(ctx),
            @ptrCast(&freeRenameCtx),
            c.G_CONNECT_DEFAULT,
        );

        c.gtk_popover_popup(@ptrCast(popover));
        _ = c.gtk_widget_grab_focus(entry);
    }

    const ProfileButtonCtx = struct {
        window: *Window,
        profile_name: [:0]u8, // owned, freed by GDestroyNotify
        popover: *c.GtkWidget,
        allocator: std.mem.Allocator,
    };

    /// Right-click → "New Tab as Profile…" picker. Opens a popover
    /// anchored on the focused pane with a button per defined profile.
    /// When no profiles exist, shows a single disabled placeholder so
    /// the user learns where to define them. Clicking a button spawns
    /// a tab via newShellTabWithProfile and closes the popover.
    pub fn openProfilePicker(self: *Window) void {
        const pane = self.focusedPane() orelse return;

        const popover = c.gtk_popover_new();
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        c.gtk_widget_set_margin_top(box, 6);
        c.gtk_widget_set_margin_bottom(box, 6);
        c.gtk_widget_set_margin_start(box, 6);
        c.gtk_widget_set_margin_end(box, 6);

        if (self.config.profiles.items.len == 0) {
            const lbl = c.gtk_label_new("No profiles defined.\nAdd `[profile.<name>]` to config.conf.");
            c.gtk_label_set_xalign(@ptrCast(lbl), 0);
            c.gtk_box_append(@ptrCast(box), lbl);
        } else {
            for (self.config.profiles.items) |p| {
                const name_z = self.allocator.allocSentinel(u8, p.name.len, 0) catch continue;
                @memcpy(name_z, p.name);

                const btn = c.gtk_button_new_with_label(name_z.ptr);
                c.gtk_widget_set_halign(btn, c.GTK_ALIGN_FILL);
                c.gtk_widget_add_css_class(btn, "flat");

                const ctx = self.allocator.create(ProfileButtonCtx) catch {
                    self.allocator.free(name_z);
                    continue;
                };
                ctx.* = .{
                    .window = self,
                    .profile_name = name_z,
                    .popover = popover,
                    .allocator = self.allocator,
                };

                _ = c.g_signal_connect_data(
                    btn,
                    "clicked",
                    @ptrCast(&onProfilePicked),
                    @ptrCast(ctx),
                    @ptrCast(&freeProfileButtonCtx),
                    c.G_CONNECT_DEFAULT,
                );

                c.gtk_box_append(@ptrCast(box), btn);
            }
        }

        c.gtk_popover_set_child(@ptrCast(popover), box);
        c.gtk_widget_set_parent(popover, @ptrCast(pane.area));
        c.gtk_popover_popup(@ptrCast(popover));
    }

    const PaneTitleCtx = struct {
        window: *Window,
        pane: *Pane,
        popover: *c.GtkWidget,
        entry: *c.GtkWidget,
        allocator: std.mem.Allocator,
    };

    /// Show a popover anchored on the focused pane with an entry to
    /// set its title manually. Empty input → unlock (resume OSC
    /// tracking). Non-empty → lock the title against further OSC
    /// 0/1/2 updates so the user's string sticks.
    pub fn setFocusedPaneTitle(self: *Window) void {
        const pane = self.focusedPane() orelse return;

        const popover = c.gtk_popover_new();
        const entry = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Pane title (empty = follow OSC)");

        if (pane.titlebar_text) |cur| {
            const z = self.allocator.allocSentinel(u8, cur.len, 0) catch null;
            if (z) |zz| {
                defer self.allocator.free(zz);
                @memcpy(zz, cur);
                c.gtk_editable_set_text(@ptrCast(entry), zz.ptr);
                c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
            }
        }

        c.gtk_popover_set_child(@ptrCast(popover), entry);
        // Anchor on the per-pane title bar when it's visible — that's
        // the natural visual anchor for "set pane title". Falls back
        // to a thin rect at the top of the GLArea so the popover
        // lands at the top of the pane instead of dropping below it.
        if (pane.titlebar_box) |tb| {
            c.gtk_widget_set_parent(popover, tb);
        } else {
            c.gtk_widget_set_parent(popover, @ptrCast(pane.area));
            const w = c.gtk_widget_get_width(@ptrCast(pane.area));
            const rect = c.GdkRectangle{
                .x = @divFloor(w, 2),
                .y = 1,
                .width = 1,
                .height = 1,
            };
            c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        }

        const ctx = self.allocator.create(PaneTitleCtx) catch return;
        ctx.* = .{
            .window = self,
            .pane = pane,
            .popover = popover,
            .entry = entry,
            .allocator = self.allocator,
        };

        _ = c.g_signal_connect_data(
            entry,
            "activate",
            @ptrCast(&onPaneTitleActivate),
            @ptrCast(ctx),
            @ptrCast(&freePaneTitleCtx),
            c.G_CONNECT_DEFAULT,
        );

        c.gtk_popover_popup(@ptrCast(popover));
        _ = c.gtk_widget_grab_focus(entry);
    }

    /// Bump the focused pane's font size by `delta` points (clamped
     /// 6..72) and rebuild the atlas. -1 / +1 / reset are exposed via
     /// Ctrl+- / Ctrl+= / Ctrl+0.
    pub fn adjustFocusedFontSize(self: *Window, delta: i32) void {
        const pane = self.focusedPane() orelse return;
        const new: i32 = @as(i32, @intCast(pane.font_size)) + delta;
        const clamped: u16 = @intCast(std.math.clamp(new, 6, 72));
        if (clamped == pane.font_size) return;
        pane.setFontSize(clamped);
    }

    pub fn resetFocusedFontSize(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        if (pane.font_size == self.config.font_size) return;
        pane.setFontSize(self.config.font_size);
    }

    const ColorPair = struct { fg: [4]f32, bg: [4]f32 };

    /// Derive the effective default fg/bg. When auto_theme is on we
    /// follow AdwStyleManager's dark/light state so sketerm matches
    /// the system appearance. Otherwise honour the explicit config.
    /// `background_opacity` is applied to bg.a after theme resolution
    /// so transparency works under both auto and manual themes.
    fn resolveDefaultColors(self: *const Window) ColorPair {
        var pair: ColorPair = if (!self.config.auto_theme) blk: {
            break :blk .{ .fg = self.config.default_fg, .bg = self.config.default_bg };
        } else blk: {
            const sm = c.adw_style_manager_get_default();
            const dark = c.adw_style_manager_get_dark(sm) != 0;
            if (dark) {
                break :blk .{
                    .fg = .{ 0.92, 0.92, 0.92, 1.0 },
                    .bg = .{ 0.10, 0.10, 0.10, 1.0 },
                };
            } else {
                break :blk .{
                    .fg = .{ 0.10, 0.10, 0.10, 1.0 },
                    .bg = .{ 0.97, 0.97, 0.97, 1.0 },
                };
            }
        };
        pair.bg[3] *= self.config.background_opacity;
        return pair;
    }

    const PromptDir = enum { prev, next };

    fn jumpPromptOnFocused(self: *Window, dir: PromptDir) void {
        const pane = self.focusedPane() orelse return;
        const screen = pane.terminal.screen;
        _ = switch (dir) {
            .prev => screen.jumpPrevPrompt(),
            .next => screen.jumpNextPrompt(),
        };
        c.gtk_gl_area_queue_render(@ptrCast(pane.area));
    }

    fn focusedPane(self: *Window) ?*Pane {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return null;
        for (self.panes.items) |p| {
            if (@intFromPtr(p.area) == @intFromPtr(focus)) return p;
        }
        return null;
    }

    const PaneDir = enum { prev, next };

    /// Cycle keyboard focus through panes inside the current tab.
    /// Wraps at either end. If the focused widget isn't a known pane
    /// we just pick the first pane in the current tab.
    fn cyclePane(self: *Window, dir: PaneDir) void {
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
        const root = c.adw_tab_page_get_child(page) orelse return;
        var in_tab: std.ArrayList(*Pane) = .empty;
        defer in_tab.deinit(self.allocator);
        for (self.panes.items) |p| {
            if (widgetIsAncestor(@ptrCast(root), @ptrCast(p.widget()))) {
                in_tab.append(self.allocator, p) catch return;
            }
        }
        if (in_tab.items.len <= 1) return;
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window));
        var idx: usize = 0;
        if (focus != null) {
            for (in_tab.items, 0..) |p, i| {
                if (focus == @as(*c.GtkWidget, @ptrCast(p.area))) {
                    idx = i;
                    break;
                }
            }
        }
        const n = in_tab.items.len;
        const next = switch (dir) {
            .next => (idx + 1) % n,
            .prev => (idx + n - 1) % n,
        };
        _ = c.gtk_widget_grab_focus(@ptrCast(in_tab.items[next].area));
    }

    /// Open the preferences dialog. Live-applies changes via
    /// applyConfigChange + persists to ~/.config/sketerm/config.conf
    /// on every mutation.
    fn openPrefs(self: *Window) void {
        const prefs = @import("prefs.zig");
        prefs.open(self.allocator, @ptrCast(self.app_window), @ptrCast(self), self.config, prefsApplyCallback) catch |err| {
            std.debug.print("sketerm: prefs dialog: {s}\n", .{@errorName(err)});
        };
    }

    /// Push a (possibly-mutated) Config into all live state. Called
    /// by the prefs dialog whenever the user changes anything; also
    /// persists the new values to disk so they survive restart.
    pub fn applyConfigChange(self: *Window, new_cfg: *const Config) void {
        // Compute diffs we need to react to BEFORE swapping config.
        const old_size = self.config.font_size;
        const old_pad = self.config.padding;
        // Old font selection strings stay alive until the deferred
        // old-arena free at function end, so comparing later is safe.
        const old_font_path = self.config.font_path;
        const old_font_family = self.config.font_family;
        const old_blink_ms = self.config.cursor_blink_ms;
        const old_tab_pos = self.config.tab_position;
        // Replace config wholesale via a deep copy into a fresh
        // window-owned arena, then free the previous one. Never adopt
        // `new_cfg.arena` or alias its strings: the prefs dialog's
        // working copy and reload-from-disk configs have their own
        // lifetimes (dialog close / caller deinit).
        const cloned = new_cfg.clone(self.allocator) catch |err| {
            std.debug.print("sketerm: config apply failed: {s}\n", .{@errorName(err)});
            return;
        };
        // Defer freeing the old arena to the end of this function —
        // panes still hold slices into it (screen.word_chars et al.)
        // until the push-loop below reassigns them.
        var old_cfg = self.config;
        defer old_cfg.deinit();
        self.config = cloned;

        // Push into every pane.
        const eff = self.resolveDefaultColors();
        for (self.panes.items) |p| {
            const screen = p.terminal.screen;
            // Colors. resolveDefaultColors applies auto-theme +
            // background_opacity so panes get the actual rendering
            // values, not the raw config struct.
            screen.default_fg = eff.fg;
            screen.default_bg = eff.bg;
            // Renderer convention: alpha=0 means "use fg colour". We
            // map cursor_color_default → that sentinel.
            screen.cursor_color = if (self.config.cursor_color_default)
                .{ 0, 0, 0, 0 }
            else
                self.config.cursor_color;
            p.grid_pass.default_fg = eff.fg;
            p.grid_pass.default_bg = eff.bg;
            p.cell_pass.default_fg = eff.fg;
            p.cell_pass.default_bg = eff.bg;
            // Palette (16 ANSI colours). Explicit `palette` wins;
            // `scheme` alone resolves through the built-in table.
            // Entries 16..255 keep their built-in 256-table values.
            const eff_pal: ?[16][3]u8 = self.config.palette orelse blk: {
                if (self.config.scheme.len > 0) {
                    if (@import("../grid/schemes.zig").lookup(self.config.scheme)) |sch| {
                        break :blk sch.palette;
                    }
                }
                break :blk null;
            };
            if (eff_pal) |pal| {
                var i: usize = 0;
                while (i < 16) : (i += 1) {
                    screen.palette[i] = pal[i];
                    p.grid_pass.palette[i] = pal[i];
                }
            }
            // Cursor.
            screen.cursor_shape = mapCursorShape(self.config.cursor_shape, self.config.cursor_blink);
            if (self.config.cursor_blink_ms != old_blink_ms) {
                p.cursor_blink_us = @as(i64, @intCast(self.config.cursor_blink_ms)) * 1000;
            }
            // Padding.
            if (self.config.padding != old_pad) {
                p.grid_pass.pad = self.config.padding;
                p.cell_pass.pad = self.config.padding;
                c.gtk_widget_queue_resize(p.widget());
            }
            // Rendering.
            p.grid_pass.enable_ligatures = self.config.ligatures;
            p.grid_pass.enable_bidi = self.config.bidi;
            p.grid_pass.enable_url_underline = self.config.auto_url_detect;
            p.grid_pass.allow_bold = self.config.allow_bold;
            p.grid_pass.bold_is_bright = self.config.bold_is_bright;
            p.cell_pass.allow_bold = self.config.allow_bold;
            p.cell_pass.bold_is_bright = self.config.bold_is_bright;
            // Behavior.
            screen.bracketed_paste = self.config.bracketed_paste;
            screen.modify_other_keys = self.config.modify_other_keys;
            screen.scrollback_capacity = self.config.scrollback;
            screen.scroll_on_output = self.config.scroll_on_output;
            screen.word_chars = self.config.word_chars;
            if (p.input_ctx) |ictx| {
                ictx.smart_copy = self.config.smart_copy;
                ictx.clear_select_on_copy = self.config.clear_select_on_copy;
                ictx.mouse_autohide = self.config.mouse_autohide;
            }
            // These slices pointed into the old config arena (freed
            // when this function returns) — re-point them at the new
            // config's copies.
            if (p.active_profile) |pn| {
                p.active_profile = null;
                for (self.config.profiles.items) |*pr| {
                    if (std.mem.eql(u8, pr.name, pn)) {
                        p.active_profile = pr.name;
                        break;
                    }
                }
            }
            p.font_path = blk: {
                if (p.active_profile) |pn| {
                    for (self.config.profiles.items) |*pr| {
                        if (std.mem.eql(u8, pr.name, pn) and pr.font_path.len > 0)
                            break :blk pr.font_path;
                    }
                }
                break :blk self.config.font_path;
            };
            p.font_family = blk: {
                if (p.active_profile) |pn| {
                    for (self.config.profiles.items) |*pr| {
                        if (std.mem.eql(u8, pr.name, pn) and pr.font_family.len > 0)
                            break :blk pr.font_family;
                    }
                }
                break :blk if (self.config.font_family.len > 0) self.config.font_family else null;
            };
            // Mouse / link / autohide flags on the Pane itself.
            p.copy_on_selection = self.config.copy_on_selection;
            p.clear_select_on_copy = self.config.clear_select_on_copy;
            p.disable_mouse_paste = self.config.disable_mouse_paste;
            p.disable_mousewheel_zoom = self.config.disable_mousewheel_zoom;
            p.link_single_click = self.config.link_single_click;
            p.mouse_autohide = self.config.mouse_autohide;
            // Per-pane titlebar visibility.
            p.setTitlebarVisible(self.config.show_titlebar);
            // Inactive-pane dimming.
            p.inactive_fg_dim = self.config.inactive_fg_dim;
            p.inactive_bg_dim = self.config.inactive_bg_dim;
            p.applyDim();
            // Repaint.
            screen.dirty = true;
            p.cell_pass.markAllDirty();
            c.gtk_gl_area_queue_render(@ptrCast(p.area));
        }

        // Refresh CSS provider so any title_*_* color changes take
        // effect immediately on the active/inactive classes.
        self.refreshTitlebarCss();

        // Font size needs the heavy atlas-rebuild path.
        if (self.config.font_size != old_size) {
            for (self.panes.items) |p| p.setFontSize(self.config.font_size);
        } else {
            // Same size, different font file/family: setFontSize would
            // early-return, so rebuild the atlases explicitly.
            const path_changed = !eqOptStr(old_font_path, self.config.font_path);
            const family_changed = !std.mem.eql(u8, old_font_family, self.config.font_family);
            if (path_changed or family_changed) {
                for (self.panes.items) |p| p.refreshFont();
            }
        }

        // Tab position swap.
        if (self.config.tab_position != old_tab_pos) {
            self.setTabPosition(self.config.tab_position);
        }

        // Window-level flags.
        self.search_force_cs = self.config.search_case_sensitive;
        self.setAlwaysOnTop(self.config.always_on_top);
        self.refreshOpaqueRegion();
        self.refreshBindings();
        c.gtk_widget_set_visible(self.tab_bar, if (self.config.show_tab_bar) 1 else 0);

        // Persist.
        self.persistConfig();
    }

    fn persistConfig(self: *Window) void {
        const path = resolveConfigSavePath(self.allocator) catch return;
        defer self.allocator.free(path);
        self.config.save(path) catch |err| {
            std.debug.print("sketerm: prefs persist failed: {s}\n", .{@errorName(err)});
        };
    }

    /// Insert a new tab into self.tab_view, honouring the
    /// `new_tab_after_current` config: at the end (default) or
    /// immediately after the currently-selected page. Returns the
    /// AdwTabPage so callers can set its title/tooltip.
    fn appendOrInsertTab(self: *Window, child: *c.GtkWidget) *c.AdwTabPage {
        if (self.config.new_tab_after_current) {
            const sel = c.adw_tab_view_get_selected_page(self.tab_view);
            if (sel != null) {
                const idx = c.adw_tab_view_get_page_position(self.tab_view, sel);
                if (c.adw_tab_view_insert(self.tab_view, child, idx + 1)) |p| return p;
            }
        }
        return c.adw_tab_view_append(self.tab_view, child).?;
    }

    /// Tell the compositor that our content is no longer opaque when
    /// background_opacity < 1.0. Only takes effect under Wayland with
    /// a compositor that honours surface alpha (KWin / Mutter do).
    /// X11 ignores opaque regions silently.
    ///
    /// Caveat: once we override the region, GTK's auto-tracking is
    /// permanently bypassed for this surface. Live-toggling back to
    /// 1.0 won't reinstate compositor optimisations until the window
    /// is recreated. We document this and accept it.
    pub fn refreshOpaqueRegion(self: *Window) void {
        if (self.config.background_opacity >= 0.999) return;
        const native = c.gtk_widget_get_native(self.app_window);
        if (native == null) return;
        const surface = c.gtk_native_get_surface(@ptrCast(@alignCast(native)));
        if (surface == null) return;
        // NULL region → "nothing in this surface is opaque" → the
        // compositor blends every pixel against what's behind us.
        c.gdk_surface_set_opaque_region(surface, null);
    }

    /// Broadcast user input from `source` across the broadcast set,
    /// per the current groupsend mode. ALWAYS writes to source first
    /// (so the typing pane sees its own keystrokes immediately).
    /// Mouse selections / paste interactions on receivers should not
    /// fire from here — only keystrokes route through this path.
    pub fn broadcastBytes(self: *Window, source: *Terminal, bytes: []const u8) void {
        // Source always gets the bytes — direct PTY write to avoid
        // re-entering the broadcast sink.
        _ = source.pty.writeAll(bytes);

        if (self.groupsend == .off) return;

        for (self.terminals.items) |t| {
            if (t == source) continue;
            switch (self.groupsend) {
                .off => unreachable,
                .all => _ = t.pty.writeAll(bytes),
                .group => {
                    // Find the source pane's group + this pane's group.
                    const src_group: ?[]const u8 = self.groupForTerminal(source);
                    const dst_group: ?[]const u8 = self.groupForTerminal(t);
                    if (src_group) |sg| {
                        if (dst_group) |dg| {
                            if (std.mem.eql(u8, sg, dg)) _ = t.pty.writeAll(bytes);
                        }
                    }
                },
            }
        }
    }

    fn groupForTerminal(self: *Window, term: *Terminal) ?[]const u8 {
        for (self.panes.items) |p| {
            if (p.terminal == term) return p.group;
        }
        return null;
    }

    /// Cycle the broadcast mode (off → group → all → off). UI binds
    /// this to Ctrl+Shift+G via the Action enum.
    pub fn cycleGroupSend(self: *Window) void {
        self.groupsend = switch (self.groupsend) {
            .off => .group,
            .group => .all,
            .all => .off,
        };
        self.refreshBroadcastSink();
        // Visual indicator on the focused pane: queue a draw so
        // the titlebar's broadcast CSS class refresh is immediate.
        for (self.panes.items) |p| {
            self.applyBroadcastCss(p);
            c.gtk_widget_queue_draw(p.widget());
        }
        self.refreshWindowTitle();
    }

    /// Set the GTK window title based on current state — currently
    /// just appends a broadcast indicator when groupsend != off.
    /// Visible regardless of `show_titlebar` (per-pane bars), so
    /// users always have a cue that typing is being multiplexed.
    fn refreshWindowTitle(self: *Window) void {
        const suffix: ?[]const u8 = switch (self.groupsend) {
            .off => null,
            .group => " — broadcast: group",
            .all => " — broadcast: all",
        };
        if (suffix) |s| {
            const total = "sketerm".len + s.len;
            const buf = self.allocator.allocSentinel(u8, total, 0) catch return;
            defer self.allocator.free(buf);
            @memcpy(buf[0.."sketerm".len], "sketerm");
            @memcpy(buf["sketerm".len..total], s);
            c.gtk_window_set_title(@ptrCast(self.app_window), buf.ptr);
        } else {
            c.gtk_window_set_title(@ptrCast(self.app_window), "sketerm");
        }
    }

    /// Wire / unwire each Terminal's broadcast_sink based on the
    /// current groupsend mode. Off = no sink installed (direct writes).
    fn refreshBroadcastSink(self: *Window) void {
        const sink: ?*const fn (ctx: ?*anyopaque, source: *Terminal, bytes: []const u8) void = if (self.groupsend == .off) null else broadcastSinkFn;
        for (self.terminals.items) |t| {
            t.broadcast_sink = sink;
            t.broadcast_ctx = if (sink != null) @ptrCast(self) else null;
        }
    }

    fn applyBroadcastCss(self: *Window, p: *Pane) void {
        if (p.titlebar_box) |tb| {
            const w: *c.GtkWidget = @ptrCast(@alignCast(tb));
            if (self.groupsend != .off) {
                c.gtk_widget_add_css_class(w, "sketerm-broadcast");
            } else {
                c.gtk_widget_remove_css_class(w, "sketerm-broadcast");
            }
        }
    }

    /// Build the active keybinding table from default_bindings overlaid
    /// with Config.keybinds. Each (action, accel) override either
    /// replaces a default's accel for that action OR (if the action's
    /// default is unbound and the user-supplied accel matches an
    /// existing default's accel) does nothing — the user can't "free
    /// up" a default chord without an explicit unbind.
    /// Empty accel means "unbind that action" (remove all entries).
    /// Logs duplicate-accel collisions to stderr but doesn't error.
    pub fn refreshBindings(self: *Window) void {
        const input = @import("input.zig");
        const ally = self.allocator;
        // Reset.
        self.bindings.clearRetainingCapacity();
        // Start with defaults.
        for (input.default_bindings) |b| self.bindings.append(ally, b) catch return;
        // Apply overrides.
        for (self.config.keybinds.items) |kb| {
            const action = input.actionFromName(kb.name) orelse {
                std.debug.print("sketerm: keybind: unknown action '{s}'\n", .{kb.name});
                continue;
            };
            // Drop every existing binding for this action (multiple
            // defaults may map to the same action — e.g. font_inc has
            // 4 entries; an override clears all of them).
            var i: usize = 0;
            while (i < self.bindings.items.len) {
                if (self.bindings.items[i].action == action) {
                    _ = self.bindings.orderedRemove(i);
                } else i += 1;
            }
            if (kb.accel.len == 0) continue; // unbound
            const parsed = input.parseAccel(kb.accel) orelse {
                std.debug.print("sketerm: keybind: bad accelerator '{s}' for '{s}'\n", .{ kb.accel, kb.name });
                continue;
            };
            // Conflict warn if another action already uses this combo.
            for (self.bindings.items) |existing| {
                if (existing.keyval == parsed.keyval and (existing.mods & input.SIGNIFICANT_MODS) == (parsed.mods & input.SIGNIFICANT_MODS)) {
                    std.debug.print(
                        "sketerm: keybind: '{s}' shadows '{s}' (same accelerator)\n",
                        .{ input.actionName(action), input.actionName(existing.action) },
                    );
                    break;
                }
            }
            self.bindings.append(ally, .{
                .keyval = parsed.keyval,
                .mods = parsed.mods,
                .action = action,
            }) catch {};
        }
        // Push pointer into every existing pane's Ctx.
        for (self.panes.items) |p| {
            if (p.input_ctx) |ictx| ictx.bindings = self.bindings.items;
        }
    }

    /// (Re)build the per-pane titlebar CSS so the four colour classes
    /// resolve to the user-configured rgba values. Called at startup
    /// and on every applyConfigChange.
    fn refreshTitlebarCss(self: *Window) void {
        if (self.titlebar_css == null) {
            const provider = c.gtk_css_provider_new();
            const display = c.gtk_widget_get_display(self.app_window);
            // STYLE_PROVIDER_PRIORITY_APPLICATION beats theme defaults
            // but loses to user CSS — the right level for "we own this
            // widget class".
            c.gtk_style_context_add_provider_for_display(
                display,
                @ptrCast(@alignCast(provider)),
                c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
            self.titlebar_css = provider;
        }
        const af = self.config.title_active_fg;
        const ab = self.config.title_active_bg;
        const inf = self.config.title_inactive_fg;
        const ib = self.config.title_inactive_bg;
        // Format rgba(r, g, b, a) with values 0..255 + 0..1 alpha.
        var buf: [4096]u8 = undefined;
        const css = std.fmt.bufPrintZ(&buf,
            \\.sketerm-titlebar {{ padding: 1px 2px; min-height: 18px; }}
            \\.sketerm-titlebar-active {{ background-color: rgba({d}, {d}, {d}, {d:.3}); color: rgba({d}, {d}, {d}, {d:.3}); }}
            \\.sketerm-titlebar-inactive {{ background-color: rgba({d}, {d}, {d}, {d:.3}); color: rgba({d}, {d}, {d}, {d:.3}); }}
            \\.sketerm-titlebar-label {{ font-weight: bold; }}
            \\.sketerm-titlebar.sketerm-broadcast {{ box-shadow: inset 0 0 0 2px rgba(255, 200, 60, 0.95); }}
            \\
            \\/* Active-tab indicator — accent line under the selected
            \\   tab plus a stronger background tint, à la Terminator.
            \\   Inactive tabs dim to ~55% so the active one stands
            \\   out. libadwaita uses `tab:selected` (pseudo-class),
            \\   not `.selected` / `:checked`. We give the selected
            \\   rule higher specificity (`tabbar tabbox tab`) so it
            \\   wins over libadwaita's own `tabbar tab:selected`
            \\   block at the same priority level. */
            \\tabbar tab {{ opacity: 0.55; }}
            \\tabbar tabbox tab:selected {{
            \\    opacity: 1.0;
            \\    box-shadow: inset 0 -3px 0 0 #3584e4;
            \\    background-color: rgba(53, 132, 228, 0.18);
            \\}}
            \\
            \\/* Split-pane separator — solid 4-px #353535 line.
            \\   `gtk_paned_set_wide_handle(paned, TRUE)` adds the
            \\   `.wide` style class to the separator. libadwaita's
            \\   `paned.horizontal > separator.wide` rule has higher
            \\   specificity than `paned > separator` and paints
            \\   1-px box-shadow lines on both edges; we have to
            \\   match that selector to override.
            \\
            \\   Width is 4 logical px (not 2) so it stays a multiple
            \\   of 4 — every fractional surface scale we care about
            \\   (1.25, 1.5, 1.75) maps that to integer device pixels,
            \\   keeping the pane rectangles on the GtkGraphicsOffload-
            \\   compatible grid. With an odd-width separator at scale
            \\   1.5 one pane always falls off-grid and offload
            \\   silently rejects every frame. */
            \\paned.horizontal > separator,
            \\paned.vertical > separator,
            \\paned.horizontal > separator.wide,
            \\paned.vertical > separator.wide {{
            \\    background-color: #353535;
            \\    background-image: none;
            \\    box-shadow: none;
            \\    border: none;
            \\    margin: 0;
            \\    padding: 0;
            \\    min-width: 4px;
            \\    min-height: 4px;
            \\}}
            \\paned.horizontal > separator:hover,
            \\paned.vertical > separator:hover,
            \\paned.horizontal > separator.wide:hover,
            \\paned.vertical > separator.wide:hover,
            \\paned.horizontal > separator:active,
            \\paned.vertical > separator:active,
            \\paned.horizontal > separator.wide:active,
            \\paned.vertical > separator.wide:active {{
            \\    background-color: #5a5a5a;
            \\    box-shadow: none;
            \\}}
        , .{
            @as(u8, @intFromFloat(@round(ab[0] * 255))),
            @as(u8, @intFromFloat(@round(ab[1] * 255))),
            @as(u8, @intFromFloat(@round(ab[2] * 255))),
            ab[3],
            @as(u8, @intFromFloat(@round(af[0] * 255))),
            @as(u8, @intFromFloat(@round(af[1] * 255))),
            @as(u8, @intFromFloat(@round(af[2] * 255))),
            af[3],
            @as(u8, @intFromFloat(@round(ib[0] * 255))),
            @as(u8, @intFromFloat(@round(ib[1] * 255))),
            @as(u8, @intFromFloat(@round(ib[2] * 255))),
            ib[3],
            @as(u8, @intFromFloat(@round(inf[0] * 255))),
            @as(u8, @intFromFloat(@round(inf[1] * 255))),
            @as(u8, @intFromFloat(@round(inf[2] * 255))),
            inf[3],
        }) catch return;
        c.gtk_css_provider_load_from_string(self.titlebar_css.?, css.ptr);
    }

    /// Stay-above-other-windows hint. GTK4 dropped the X11-era
    /// `gtk_window_set_keep_above`; on modern Wayland clients can't
    /// request this directly. We log a one-time hint pointing the
    /// user at their compositor's window-rules feature and remember
    /// the setting so config round-trips.
    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        _ = self;
        if (!on) return;
        if (always_on_top_warned) return;
        always_on_top_warned = true;
        std.debug.print(
            \\sketerm: always_on_top: GTK4 doesn't expose a "keep above" API.
            \\  Set this via your compositor's window rules:
            \\    KDE Plasma: System Settings → Window Management → Window Rules
            \\    GNOME:      gnome-tweaks → Workspaces (or `wmctrl -r sketerm -b add,above`)
            \\
        , .{});
    }

    /// Move the tab bar to the top or bottom of the toolbar view.
    /// Idempotent — safe to call when the bar is already there.
    pub fn setTabPosition(self: *Window, pos: @import("../config.zig").TabPosition) void {
        // Remove from whichever bar holds it now (Adw allows safe
        // removal from top OR bottom regardless of current location).
        c.adw_toolbar_view_remove(@ptrCast(@alignCast(self.toolbar_view)), self.tab_bar);
        switch (pos) {
            .top => c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(self.toolbar_view)), self.tab_bar),
            .bottom => c.adw_toolbar_view_add_bottom_bar(@ptrCast(@alignCast(self.toolbar_view)), self.tab_bar),
        }
    }

    /// Close the focused pane. If it's the only pane in its tab,
    /// closes the tab. Otherwise the pane is removed from its
    /// parent GtkPaned and the sibling takes its place.
    /// Close a specific pane (used by exit_action=close). If the
    /// pane is the only one in its tab, closes the whole tab.
    pub fn closePane(self: *Window, target: *Pane) void {
        const w = target.widget();
        const parent = c.gtk_widget_get_parent(w) orelse return;
        const is_paned = c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(parent)),
            c.gtk_paned_get_type(),
        ) != 0;
        if (!is_paned) {
            // Last pane in its tab — close the tab. Find the AdwTabPage.
            const n = c.adw_tab_view_get_n_pages(self.tab_view);
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
                if (page == null) continue;
                const child = c.adw_tab_page_get_child(page);
                if (child == null) continue;
                if (widgetIsAncestor(@ptrCast(child), w)) {
                    _ = c.adw_tab_view_close_page(self.tab_view, page);
                    return;
                }
            }
            return;
        }
        // Re-use closeFocusedPane's path by temporarily focusing the
        // target then calling it. Simpler than duplicating.
        _ = c.gtk_widget_grab_focus(@ptrCast(target.area));
        self.closeFocusedPane();
    }

    pub fn closeFocusedPane(self: *Window) void {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return;
        var found_idx: ?usize = null;
        for (self.panes.items, 0..) |p, idx| {
            if (@intFromPtr(p.area) == @intFromPtr(focus)) {
                found_idx = idx;
                break;
            }
        }
        if (found_idx == null) return;

        const pane = self.panes.items[found_idx.?];
        const w = pane.widget();
        const parent = c.gtk_widget_get_parent(w) orelse return;

        const is_paned = c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(parent)),
            c.gtk_paned_get_type(),
        ) != 0;

        if (!is_paned) {
            // Last pane in tab — close the whole tab.
            self.closeCurrentTab();
            return;
        }

        const start = c.gtk_paned_get_start_child(@ptrCast(parent));
        const end = c.gtk_paned_get_end_child(@ptrCast(parent));
        const sibling = if (start == w) end else start;
        if (sibling == null) return;

        // Take an explicit ref on sibling — detaching from the paned
        // drops the paned's only ref, which would destroy the widget
        // before we can re-parent it. Same pattern splitFocused uses
        // around its reparent. (Don't lose this — symptom is the
        // entire tab going blank when closing a split pane.)
        _ = c.g_object_ref(@ptrCast(@alignCast(sibling.?)));
        defer c.g_object_unref(@ptrCast(@alignCast(sibling.?)));

        // Also ref the paned itself so removing it from the grandparent
        // (gtk_box_remove / gtk_paned_set_*_child(..., new)) doesn't
        // destroy it before we're done detaching the closing pane's
        // child relationship. Otherwise w could be torn down via the
        // paned's destructor mid-cleanup.
        _ = c.g_object_ref(@ptrCast(@alignCast(parent)));
        defer c.g_object_unref(@ptrCast(@alignCast(parent)));

        // Detach sibling from paned.
        if (start == w) {
            c.gtk_paned_set_end_child(@ptrCast(parent), null);
        } else {
            c.gtk_paned_set_start_child(@ptrCast(parent), null);
        }

        // Replace paned with sibling in grandparent.
        const gp = c.gtk_widget_get_parent(parent) orelse return;
        const gp_is_paned = c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(gp)),
            c.gtk_paned_get_type(),
        ) != 0;

        if (gp_is_paned) {
            const gp_start = c.gtk_paned_get_start_child(@ptrCast(gp));
            if (gp_start == parent) {
                c.gtk_paned_set_start_child(@ptrCast(gp), sibling);
            } else {
                c.gtk_paned_set_end_child(@ptrCast(gp), sibling);
            }
        } else {
            c.gtk_box_remove(@ptrCast(gp), parent);
            c.gtk_box_append(@ptrCast(gp), sibling);
        }

        // Clean up. Terminal.deinit kills worker + closes PTY.
        // Pane.deinit frees Zig-side state; GL resources are tied
        // to the GL context which GTK tears down on unparent.
        // Defer the actual `Pane.deinit` / `Terminal.deinit` to a
        // `g_idle_add` so the trailing widget-destroy chain can fire
        // its controller / signal-closure cleanups (which dereference
        // `pane.menu_arena` via the click-context GDestroyNotify)
        // BEFORE we tear `menu_arena` down.
        // The search bar / hint mode hold raw pane pointers — drop
        // them before the pane is freed.
        if (self.search_pane == pane) self.closeSearch();
        if (self.hints_pane == pane) self.exitHints();
        _ = self.panes.orderedRemove(found_idx.?);
        const term = pane.terminal;
        for (self.terminals.items, 0..) |t, ti| {
            if (t == term) {
                _ = self.terminals.orderedRemove(ti);
                break;
            }
        }
        term.clearSinks();
        schedulePaneTeardown(pane, term);

        // Move focus to the first pane inside the surviving sibling
        // subtree — without this, focus can land on the now-empty
        // GtkPaned wrapper and keypresses go nowhere.
        if (sibling) |sib| {
            for (self.panes.items) |p| {
                if (widgetIsAncestor(@ptrCast(sib), @ptrCast(p.widget()))) {
                    _ = c.gtk_widget_grab_focus(@ptrCast(p.area));
                    break;
                }
            }
        }
    }

    /// Build a Layout snapshot of the current window state.
    /// Caller must arena-free or otherwise track strings.
    pub fn collectLayout(self: *Window, arena: std.mem.Allocator) !layout_mod.Layout {
        var tabs: std.ArrayList(layout_mod.TabSpec) = .empty;
        const n_pages = c.adw_tab_view_get_n_pages(self.tab_view);
        var i: c_int = 0;
        while (i < n_pages) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
            const wrapper = c.adw_tab_page_get_child(page);
            const root = c.gtk_widget_get_first_child(@ptrCast(wrapper));
            if (root == null) continue;

            const title_cstr = c.adw_tab_page_get_title(page);
            const title = if (title_cstr != null) std.mem.span(@as([*:0]const u8, @ptrCast(title_cstr))) else "";

            const tree = self.collectTree(arena, root.?) catch continue;
            try tabs.append(arena, .{
                .title = try arena.dupe(u8, title),
                .tree = tree,
                .pinned = c.adw_tab_page_get_pinned(page) != 0,
            });
        }
        return .{ .version = 2, .tabs = try tabs.toOwnedSlice(arena) };
    }

    fn collectTree(self: *Window, arena: std.mem.Allocator, w: *c.GtkWidget) !layout_mod.Tree {
        const is_paned = c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(w)),
            c.gtk_paned_get_type(),
        ) != 0;
        if (is_paned) {
            const start = c.gtk_paned_get_start_child(@ptrCast(w)) orelse return error.MissingChild;
            const end = c.gtk_paned_get_end_child(@ptrCast(w)) orelse return error.MissingChild;
            const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(w)));
            const total: c_int = if (orientation == c.GTK_ORIENTATION_HORIZONTAL)
                c.gtk_widget_get_width(w)
            else
                c.gtk_widget_get_height(w);
            const pos = c.gtk_paned_get_position(@ptrCast(w));
            const ratio: f32 = if (total > 0)
                @as(f32, @floatFromInt(pos)) / @as(f32, @floatFromInt(total))
            else
                0.5;
            const children = try arena.alloc(layout_mod.Tree, 2);
            children[0] = try self.collectTree(arena, start);
            children[1] = try self.collectTree(arena, end);
            return .{ .split = .{
                .orientation = if (orientation == c.GTK_ORIENTATION_HORIZONTAL) .horizontal else .vertical,
                .ratio = ratio,
                .children = children,
            } };
        }

        // Leaf — find the Pane that owns this widget.
        for (self.panes.items) |p| {
            if (@intFromPtr(p.widget()) == @intFromPtr(w)) {
                // Prefer OSC 7 cwd if the shell reported it; fall
                // back to /proc/<pid>/cwd; finally to "/".
                const cwd: []const u8 = if (p.terminal.cwd) |reported|
                    try arena.dupe(u8, reported)
                else
                    layout_mod.cwdOfPid(p.terminal.pty.child_pid, arena) catch try arena.dupe(u8, "/");
                // Serialize the command the pane was actually spawned
                // with; fall back to $SHELL for panes without a record.
                const cmd: [][]const u8 = if (p.spawn_argv) |av| blk: {
                    const out = try arena.alloc([]const u8, av.len);
                    for (av, 0..) |a, i| out[i] = try arena.dupe(u8, a);
                    break :blk out;
                } else blk: {
                    const out = try arena.alloc([]const u8, 1);
                    out[0] = try arena.dupe(u8, @import("../util/profile.zig").getenv("SHELL") orelse "/bin/bash");
                    break :blk out;
                };
                // Save font_size only if it diverges from the global
                // default — keeps layout files terse.
                const fs: ?u16 = if (p.font_size != self.config.font_size) p.font_size else null;
                // Carry profile name so split-tree restore / duplicate
                // can reapply per-pane profile overrides.
                const prof: []const u8 = if (p.active_profile) |pn|
                    try arena.dupe(u8, pn)
                else
                    "";
                return .{ .pane = .{ .cwd = cwd, .command = cmd, .font_size = fs, .profile = prof } };
            }
        }
        return error.PaneNotFound;
    }

    /// Open a GtkFileChooserNative for save-as; user picks a path,
    /// we serialize the current layout to it. Defaults to .json (the
    /// authoritative format) — pick `.layout` if you want the simple
    /// DSL but only JSON is implemented for save right now.
    pub fn saveLayoutAs(self: *Window) void {
        const dialog = c.gtk_file_dialog_new();
        c.gtk_file_dialog_set_title(dialog, "Save Layout");
        c.gtk_file_dialog_set_initial_name(dialog, "layout.json");
        c.gtk_file_dialog_save(
            dialog,
            @ptrCast(self.app_window),
            null,
            @ptrCast(&onSaveLayoutAsDone),
            @ptrCast(self),
        );
    }

    /// Save current state to the default path. Best-effort.
    pub fn saveLayoutQuietly(self: *Window) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const path = layout_mod.defaultSavePath(arena) catch return;
        const layout = self.collectLayout(arena) catch return;
        layout_mod.save(layout, path) catch return;
    }

    /// Duplicate the focused tab — spawn a new tab inheriting the
    /// focused pane's cwd and profile. Splits in the source tab are
    /// NOT replicated (the new tab gets one shell pane); cloning a
    /// full split tree would duplicate the layout snapshot/restore
    /// path, which is a bigger feature. Most user value is "open
    /// another shell here in this dir as this profile."
    pub fn duplicateCurrentTab(self: *Window) void {
        const pane = self.focusedPane() orelse return;

        // Detect single-pane vs split-tree by inspecting the tab page's
        // root widget. Single-pane case wins by preserving the profile
        // (which TabSpec doesn't carry today). Split-tree case loses
        // profile-per-pane but keeps the layout — picked over the
        // alternative of flattening to one pane and dropping the
        // splits the user spent time arranging.
        const sel = c.adw_tab_view_get_selected_page(self.tab_view) orelse {
            self.newShellTabWithProfile(null, pane.active_profile) catch |err| logActionError("duplicate_tab", err);
            return;
        };
        const wrapper = c.adw_tab_page_get_child(sel);
        const root = if (wrapper != null) c.gtk_widget_get_first_child(@ptrCast(wrapper)) else null;
        const is_paned = root != null and c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(root.?)),
            c.gtk_paned_get_type(),
        ) != 0;

        if (!is_paned) {
            // Single pane — use the profile-aware fast path.
            self.newShellTabWithProfile(null, pane.active_profile) catch |err| {
                std.debug.print("sketerm: duplicate tab failed: {s}\n", .{@errorName(err)});
            };
            return;
        }

        // Split tree — round-trip via collectTree → newTabFromSpec.
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const tree = self.collectTree(arena, root.?) catch |err| {
            std.debug.print("sketerm: duplicate split tree failed: {s}\n", .{@errorName(err)});
            return;
        };

        const title_cstr = c.adw_tab_page_get_title(sel);
        const title = if (title_cstr != null)
            std.mem.span(@as([*:0]const u8, @ptrCast(title_cstr)))
        else
            "shell";

        const spec = layout_mod.TabSpec{
            .title = arena.dupe(u8, title) catch return,
            .tree = tree,
            .pinned = false, // duplicates start unpinned
        };
        self.newTabFromSpec(spec) catch |err| {
            std.debug.print("sketerm: duplicate split tree failed: {s}\n", .{@errorName(err)});
        };
    }

    /// Copy the focused pane's visible screen to the system clipboard.
    /// Same body as input.zig::copyScreen — duplicated here because
    /// the menu sink hits the Window directly while runAction goes
    /// through the per-pane Ctx. Both paths feed the same extractScreen.
    pub fn copyFocusedScreen(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        const screen = pane.terminal.screen;
        const text = screen.extractScreen(self.allocator) catch return;
        defer self.allocator.free(text);
        if (text.len == 0) return;
        const display = c.gtk_widget_get_display(self.app_window);
        const clip = c.gdk_display_get_clipboard(display);
        const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return;
        defer self.allocator.free(cstr);
        @memcpy(cstr, text);
        c.gdk_clipboard_set_text(clip, cstr.ptr);
    }

    /// Copy the focused pane's scrollback ring + active screen.
    pub fn copyFocusedScrollback(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        const screen = pane.terminal.screen;
        const text = screen.extractScrollback(self.allocator) catch return;
        defer self.allocator.free(text);
        if (text.len == 0) return;
        const display = c.gtk_widget_get_display(self.app_window);
        const clip = c.gdk_display_get_clipboard(display);
        const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return;
        defer self.allocator.free(cstr);
        @memcpy(cstr, text);
        c.gdk_clipboard_set_text(clip, cstr.ptr);
    }

    /// Open the focused pane's scrollback + screen in a pager tab.
    /// Kitty's show_scrollback: dump to a 0600 temp file, spawn
    /// `less -R +G <file>` (or `$PAGER <file>`) in a new tab; the
    /// wrapping `sh -c` rm's the file once the pager exits.
    pub fn openScrollbackPager(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        const screen = pane.terminal.screen;
        const text = screen.extractScrollback(self.allocator) catch return;
        defer self.allocator.free(text);

        const dir = @import("../util/profile.zig").getenv("XDG_RUNTIME_DIR") orelse "/tmp";
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrintZ(
            &path_buf,
            "{s}/sketerm-scrollback-{d}-{d}.txt",
            .{ dir, c.getpid(), @import("../util/profile.zig").milliTimestamp() },
        ) catch return;

        const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o600));
        if (fd < 0) return;
        var off: usize = 0;
        while (off < text.len) {
            const n = c.write(fd, text.ptr + off, text.len - off);
            if (n <= 0) {
                _ = c.close(fd);
                _ = c.unlink(path.ptr);
                return;
            }
            off += @intCast(n);
        }
        if (c.close(fd) != 0) {
            _ = c.unlink(path.ptr);
            return;
        }

        // $PAGER overrides; default matches kitty (-R raw colours,
        // +G jump to end). The path is single-quoted — safe because
        // we generated it from safe chars (XDG_RUNTIME_DIR/tmp +
        // pid + timestamp, no quotes possible).
        const pager = blk: {
            const env = @import("../util/profile.zig").getenv("PAGER") orelse break :blk "less -R +G";
            break :blk if (env.len == 0) "less -R +G" else env;
        };
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(
            &cmd_buf,
            "{s} '{s}'; rm -f '{s}'",
            .{ pager, path, path },
        ) catch {
            _ = c.unlink(path.ptr);
            return;
        };
        const argv = [_][*:0]const u8{ "/bin/sh", "-c", cmd.ptr };
        self.addTabInternal("Scrollback", &argv, null) catch |err| {
            _ = c.unlink(path.ptr);
            logActionError("show_scrollback", err);
        };
    }

    /// Show / hide the tab bar. Bound via keybind.toggle_tab_bar
    /// (no default — common terminator-style binding is Ctrl+Shift+B
    /// but we leave it user-configurable).
    pub fn toggleTabBarVisibility(self: *Window) void {
        const visible = c.gtk_widget_get_visible(self.tab_bar) != 0;
        c.gtk_widget_set_visible(self.tab_bar, if (visible) 0 else 1);
    }

    /// Jump to a specific tab by 0-based index. No-op if the index
    /// is out of range (fewer tabs than requested).
    pub fn gotoTab(self: *Window, index: c_int) void {
        const n = c.adw_tab_view_get_n_pages(self.tab_view);
        if (index < 0 or index >= n) return;
        const page = c.adw_tab_view_get_nth_page(self.tab_view, index);
        if (page == null) return;
        c.adw_tab_view_set_selected_page(self.tab_view, page);
    }

    /// Reload config.conf from disk and live-apply. Uses the XDG
    /// search path (~/.config/sketerm/config.conf or
    /// $XDG_CONFIG_HOME/sketerm/config.conf). Doesn't honour
    /// `--config <path>` overrides — user passed a non-default
    /// path on the command line would need to restart for that.
    pub fn reloadConfigFromDisk(self: *Window) void {
        var new_cfg = Config.load(self.allocator);
        // applyConfigChange deep-copies; the loaded config (and its
        // arena) is ours to free.
        defer new_cfg.deinit();
        self.applyConfigChange(&new_cfg);
        std.debug.print("sketerm: config reloaded\n", .{});
    }

    /// Toggle the current tab's pinned state. Pinned tabs sit in a
    /// separate region at the start of the tab bar (AdwTabView
    /// native): close button is hidden, drag-reorder is restricted
    /// to among the pinned set.
    pub fn togglePinCurrentTab(self: *Window) void {
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
        const is_pinned = c.adw_tab_page_get_pinned(page) != 0;
        c.adw_tab_view_set_page_pinned(self.tab_view, page, if (is_pinned) 0 else 1);
    }

    /// Save current state as the "default" layout that's auto-loaded
    /// on subsequent cold starts (no --layout / --restore needed).
    /// Best-effort; user gets stderr feedback on failure.
    pub fn saveDefaultLayout(self: *Window) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const path = layout_mod.defaultLayoutPath(arena) catch return;
        const layout = self.collectLayout(arena) catch |err| {
            std.debug.print("sketerm: collect layout failed: {s}\n", .{@errorName(err)});
            return;
        };
        layout_mod.save(layout, path) catch |err| {
            std.debug.print("sketerm: save default layout to {s} failed: {s}\n", .{ path, @errorName(err) });
            return;
        };
        std.debug.print("sketerm: saved default layout to {s}\n", .{path});
    }

    /// Load $XDG_STATE_HOME/sketerm/default.json if it exists. Returns
    /// false silently when the file isn't there (the common case on a
    /// fresh install). Distinct from loadLayoutDefault, which targets
    /// last.json under --restore.
    pub fn loadDefaultLayoutIfPresent(self: *Window) !bool {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const path = try layout_mod.defaultLayoutPath(arena);
        // Existence check via libc. F_OK = 0 in POSIX; Aro translates
        // the F_OK macro fine but it's only accessible inside `c.`.
        var path_z: [4096]u8 = undefined;
        if (path.len >= path_z.len) return false;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        if (c.access(@ptrCast(&path_z), c.F_OK) != 0) return false;

        var parsed = layout_mod.load(self.allocator, path) catch |err| {
            std.debug.print("sketerm: cannot load default layout {s}: {s}\n", .{ path, @errorName(err) });
            return false;
        };
        defer parsed.deinit();

        for (parsed.value.tabs) |tab| {
            self.newTabFromSpec(tab) catch |err| {
                std.debug.print("sketerm: load tab '{s}' failed: {s}\n", .{ tab.title, @errorName(err) });
            };
        }
        return true;
    }
};

fn onShortcut(ctx: ?*anyopaque, action: @import("input.zig").Action) void {
    const self = cast.userData(Window, ctx);
    switch (action) {
        .new_tab => self.newShellTab(null) catch |err| logActionError("new_tab", err),
        .close_tab => self.closeCurrentTab(),
        .next_tab => self.nextTab(),
        .prev_tab => self.prevTab(),
        .split_h => self.splitFocused(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch |err| logActionError("split_h", err),
        .split_v => self.splitFocused(@intCast(c.GTK_ORIENTATION_VERTICAL)) catch |err| logActionError("split_v", err),
        .font_inc => self.adjustFocusedFontSize(1),
        .font_dec => self.adjustFocusedFontSize(-1),
        .font_reset => self.resetFocusedFontSize(),
        .search_open => self.openSearch(),
        .save_layout => self.saveLayoutQuietly(),
        .save_layout_as => self.saveLayoutAs(),
        .save_default_layout => self.saveDefaultLayout(),
        .prompt_prev => self.jumpPromptOnFocused(.prev),
        .prompt_next => self.jumpPromptOnFocused(.next),
        .pane_prev => self.cyclePane(.prev),
        .pane_next => self.cyclePane(.next),
        .prefs_open => self.openPrefs(),
        .broadcast_cycle => self.cycleGroupSend(),
        .restore_closed_tab => self.restoreLastClosed(),
        .toggle_pin_tab => self.togglePinCurrentTab(),
        .toggle_tab_bar => self.toggleTabBarVisibility(),
        .reload_config => self.reloadConfigFromDisk(),
        .goto_tab_1 => self.gotoTab(0),
        .goto_tab_2 => self.gotoTab(1),
        .goto_tab_3 => self.gotoTab(2),
        .goto_tab_4 => self.gotoTab(3),
        .goto_tab_5 => self.gotoTab(4),
        .goto_tab_6 => self.gotoTab(5),
        .goto_tab_7 => self.gotoTab(6),
        .goto_tab_8 => self.gotoTab(7),
        .goto_tab_9 => self.gotoTab(8),
        .duplicate_tab => self.duplicateCurrentTab(),
        .show_scrollback => self.openScrollbackPager(),
        .command_palette => palette_mod.open(self) catch |err| logActionError("command_palette", err),
        .hints_open => self.openHints(),
        else => {},
    }
}

/// Public entry-point used by the command palette. Tries the
/// focused pane's input controller first (covers per-pane actions
/// like copy_selection / paste_clipboard / scrollback_*) and falls
/// through to `onShortcut` for window-level actions. Mirrors the
/// dispatch order the keybind handler uses, so palette dispatch
/// and keybind dispatch hit the exact same code paths.
pub fn dispatchAction(window: *Window, action: @import("input.zig").Action) void {
    if (window.focusedPane()) |pane| {
        if (pane.input_ctx) |ictx| {
            if (@import("input.zig").runAction(ictx, action) != 0) return;
        }
    }
    onShortcut(@ptrCast(window), action);
}


fn onSearchChanged(entry: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    const text_ptr = c.gtk_editable_get_text(@ptrCast(entry));
    if (text_ptr == null) return;
    const cstr: [*:0]const u8 = @ptrCast(text_ptr);
    const len = std.mem.len(cstr);
    self.updateSearch(cstr[0..len]);
}

fn onSearchActivate(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    self.nextMatch();
}

fn onSearchStop(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    self.closeSearch();
}

fn onSearchClose(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    self.closeSearch();
}

fn onSearchNext(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    self.nextMatch();
}

fn onSearchPrev(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    self.prevMatch();
}

fn onSearchKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);
    const shift = (state & c.GDK_SHIFT_MASK) != 0;
    if (keyval == c.GDK_KEY_Return or keyval == c.GDK_KEY_KP_Enter) {
        if (shift) self.prevMatch() else self.nextMatch();
        return 1;
    }
    if (keyval == c.GDK_KEY_Escape) {
        self.closeSearch();
        return 1;
    }
    // Ctrl+I — toggle case-insensitive override and re-search the
    // current needle. Without the override, smart-case applies
    // (lower-only needle → CI, uppercase → CS).
    if ((keyval == c.GDK_KEY_i or keyval == c.GDK_KEY_I) and
        (state & c.GDK_CONTROL_MASK) != 0)
    {
        self.search_case_insensitive = !self.search_case_insensitive;
        if (self.search_entry) |w| {
            const txt = c.gtk_editable_get_text(@ptrCast(w));
            if (txt != null) {
                const slice = std.mem.span(txt);
                self.updateSearch(slice);
            }
        }
        return 1;
    }
    // Ctrl+R — toggle regex mode. The entry text is then treated
    // as a POSIX ERE pattern. Placeholder text flips to signal the
    // mode change.
    if ((keyval == c.GDK_KEY_r or keyval == c.GDK_KEY_R) and
        (state & c.GDK_CONTROL_MASK) != 0)
    {
        self.search_regex = !self.search_regex;
        if (self.search_entry) |w| {
            const placeholder: [*:0]const u8 = if (self.search_regex)
                "Search regex (Ctrl+R)"
            else
                "Search (Ctrl+R for regex)";
            c.gtk_entry_set_placeholder_text(@ptrCast(w), placeholder);
            const txt = c.gtk_editable_get_text(@ptrCast(w));
            if (txt != null) {
                const slice = std.mem.span(txt);
                self.updateSearch(slice);
            }
        }
        return 1;
    }
    return 0;
}

fn onMenuAction(ctx: ?*anyopaque, action: @import("menu.zig").Action) void {
    const self = cast.userData(Window, ctx);
    switch (action) {
        .new_tab => self.newShellTab(null) catch |err| logActionError("new_tab", err),
        .new_tab_as_profile => self.openProfilePicker(),
        .duplicate_tab => self.duplicateCurrentTab(),
        .close_tab => self.closeCurrentTab(),
        .rename_tab => self.renameCurrentTab(),
        .pin_tab => self.togglePinCurrentTab(),
        .split_h => self.splitFocused(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch |err| logActionError("split_h", err),
        .split_v => self.splitFocused(@intCast(c.GTK_ORIENTATION_VERTICAL)) catch |err| logActionError("split_v", err),
        .close_pane => self.closeFocusedPane(),
        .set_pane_title => self.setFocusedPaneTitle(),
        .copy_screen => self.copyFocusedScreen(),
        .copy_scrollback => self.copyFocusedScrollback(),
        .prefs_open => self.openPrefs(),
        else => {},
    }
}

fn onSaveLayoutAsDone(source: *c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    const dialog: *c.GtkFileDialog = @ptrCast(source);
    const file = c.gtk_file_dialog_save_finish(dialog, result, null) orelse return;
    defer c.g_object_unref(file);
    const path_cstr = c.g_file_get_path(file) orelse return;
    defer c.g_free(path_cstr);
    const path = std.mem.span(@as([*:0]const u8, @ptrCast(path_cstr)));

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layout = self.collectLayout(arena) catch return;
    layout_mod.save(layout, path) catch return;
}

fn onThemeChanged(_: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    if (!self.config.auto_theme) return;
    const fg_bg = self.resolveDefaultColors();
    for (self.panes.items) |p| {
        p.grid_pass.default_fg = fg_bg.fg;
        p.grid_pass.default_bg = fg_bg.bg;
        p.terminal.screen.default_fg = fg_bg.fg;
        p.terminal.screen.default_bg = fg_bg.bg;
        p.terminal.screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(p.area));
    }
}

fn applyPanedRatioMap(paned: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    applyPanedRatioImpl(paned, user);
}

/// notify::position fires when the user drags the divider AND when the
/// paned itself re-allocates on window resize. We re-snap to the
/// device-pixel grid (see `alignmentForScale`) so GtkGraphicsOffload
/// keeps engaging at fractional scale, and update ratio so the next
/// remap and layout save reflect the snapped position.
fn onPanedPositionChanged(paned: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(PanedRatioCtx, user);
    if (ctx.setting) return;
    const w: *c.GtkWidget = @ptrCast(paned);
    const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(w)));
    const total: c_int = if (orientation == c.GTK_ORIENTATION_HORIZONTAL)
        c.gtk_widget_get_width(w)
    else
        c.gtk_widget_get_height(w);
    if (total <= 0) return;
    const pos = c.gtk_paned_get_position(@ptrCast(w));
    if (pos <= 0) return;

    const m = alignmentForScale(widgetSurfaceScale(w));
    const snapped = snapDown(pos, m);
    if (snapped != pos) {
        ctx.setting = true;
        c.gtk_paned_set_position(@ptrCast(w), snapped);
        ctx.setting = false;
    }
    ctx.ratio = @as(f32, @floatFromInt(snapped)) / @as(f32, @floatFromInt(total));
}

fn applyPanedRatioImpl(paned: *c.GtkWidget, user: ?*anyopaque) void {
    const ctx = cast.userData(PanedRatioCtx, user);
    const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(paned)));
    const total: c_int = if (orientation == c.GTK_ORIENTATION_HORIZONTAL)
        c.gtk_widget_get_width(paned)
    else
        c.gtk_widget_get_height(paned);
    if (total <= 0) return;
    const raw_pos: c_int = @intFromFloat(@as(f32, @floatFromInt(total)) * ctx.ratio);
    const m = alignmentForScale(widgetSurfaceScale(paned));
    const pos = snapDown(raw_pos, m);
    ctx.setting = true;
    c.gtk_paned_set_position(@ptrCast(paned), pos);
    ctx.setting = false;
}

fn freePanedRatio(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ctx: *PanedRatioCtx = @ptrCast(@alignCast(u));
        ctx.allocator.destroy(ctx);
    }
}

fn onRenameActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.RenameCtx, user);
    const text_c = c.gtk_editable_get_text(@ptrCast(entry));
    const text: []const u8 = if (text_c == null) &.{}
        else std.mem.span(@as([*:0]const u8, @ptrCast(text_c)));

    if (text.len == 0) {
        // Empty input → clear the user-lock and resume OSC tracking.
        // Pull the current title from the page's first pane's
        // `titlebar_text` so the tab doesn't stay frozen on whatever
        // we last wrote — that field tracks OSC 0/1/2 in real time.
        c.g_object_set_data(@ptrCast(@alignCast(ctx.page)), "sketerm-title-locked", null);
        // Find Window via the dialog's parent — RenameCtx doesn't
        // carry it, but the tab view does via the page.
        const win = ctx.window;
        const child = c.adw_tab_page_get_child(ctx.page);
        if (child != null) {
            for (win.panes.items) |p| {
                if (widgetIsAncestor(@ptrCast(child), p.widget())) {
                    const t: []const u8 = if (p.titlebar_text) |tt| tt else "sketerm";
                    setTabPageTitleFromUtf8(win.allocator, ctx.page, t);
                    break;
                }
            }
        }
    } else {
        c.adw_tab_page_set_title(ctx.page, text_c);
        c.adw_tab_page_set_tooltip(ctx.page, text_c);
        // Mark the page as user-renamed so subsequent OSC titles
        // don't overwrite it. Stored as a non-null marker; the
        // pointer value is unused — `g_object_get_data` only checks
        // for presence.
        c.g_object_set_data(@ptrCast(@alignCast(ctx.page)), "sketerm-title-locked", @ptrCast(ctx.page));
    }
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    // ctx is freed via GDestroyNotify (freeRenameCtx) when the
    // signal closure is destroyed.
}

fn freeRenameCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.RenameCtx, user);
    ctx.allocator.destroy(ctx);
}

fn onProfilePicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.ProfileButtonCtx, user);
    // Spawn the tab first, then dismiss the popover so the user
    // sees the action take effect.
    ctx.window.newShellTabWithProfile(null, ctx.profile_name) catch |err| logActionError("new_tab_as_profile", err);
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
}

fn freeProfileButtonCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.ProfileButtonCtx, user);
    ctx.allocator.free(ctx.profile_name);
    ctx.allocator.destroy(ctx);
}

fn onPaneTitleActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.PaneTitleCtx, user);
    // The pane can be closed (keybind, child exit) while the popover
    // is open — verify it's still alive before dereferencing.
    var alive = false;
    for (ctx.window.panes.items) |p| {
        if (p == ctx.pane) {
            alive = true;
            break;
        }
    }
    if (alive) {
        const text_c = c.gtk_editable_get_text(@ptrCast(entry));
        if (text_c != null) {
            const text = std.mem.span(@as([*:0]const u8, @ptrCast(text_c)));
            if (text.len == 0) {
                ctx.pane.unlockTitle();
            } else {
                ctx.pane.lockTitle(text);
            }
        }
    }
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
}

fn freePaneTitleCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.PaneTitleCtx, user);
    ctx.allocator.destroy(ctx);
}

fn onTermClipboardSet(ctx: ?*anyopaque, text: []const u8) void {
    const self = cast.userData(Window, ctx);
    const display = c.gtk_widget_get_display(self.app_window);
    const clip = c.gdk_display_get_clipboard(display);
    const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return;
    defer self.allocator.free(cstr);
    @memcpy(cstr, text);
    c.gdk_clipboard_set_text(clip, cstr.ptr);
}

fn onTermChildExit(ctx: ?*anyopaque, pane: *Pane, status: i32) void {
    const self = cast.userData(Window, ctx);
    _ = status;
    switch (self.config.exit_action) {
        .close => self.closePane(pane),
        .restart => {
            // Spawn a fresh shell in a new pane and replace the
            // exited one. v1 implementation: just close the dead
            // pane and spawn a new tab. Truly in-place restart
            // would need PTY-level surgery in Terminal.
            self.closePane(pane);
            self.newShellTab(null) catch |err| logActionError("exit_restart_new_tab", err);
        },
        .hold => {
            // Already showed the "[process exited]" banner; do
            // nothing further. User can close the pane manually.
        },
    }
}

fn onTermBell(ctx: ?*anyopaque, pane: *Pane) void {
    const self = cast.userData(Window, ctx);

    // Audible bell — system beep through GdkDisplay (DE/portal aware).
    if (self.config.bell_audible) {
        const display = c.gtk_widget_get_display(self.app_window);
        if (display != null) c.gdk_display_beep(display);
    }

    // Visible flash — Pane.onBellEvent already records bell_at_us
    // and the renderer paints a brief tint. Just disable that path
    // when the user opted out.
    if (!self.config.bell_visible) {
        pane.terminal.screen.bell_at_us = 0;
    }

    if (!self.config.bell_urgent) return;

    // Find the AdwTabPage whose widget tree contains this pane and
    // mark it needs-attention (unless it's the currently selected one).
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    const selected = c.adw_tab_view_get_selected_page(self.tab_view);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
        if (page == null or page == selected) continue;
        const child = c.adw_tab_page_get_child(page);
        if (child == null) continue;
        if (widgetIsAncestor(@ptrCast(child), pane.widget())) {
            c.adw_tab_page_set_needs_attention(page, 1);
            return;
        }
    }
}

/// OSC 7 cwd updated for `pane`. Find its AdwTabPage and rewrite
/// the tooltip to include the live cwd, so hovering tells the user
/// where each tab actually is. Format: "<title>\n<cwd>".
fn onTermCwdChanged(ctx: ?*anyopaque, pane: *Pane, cwd: []const u8) void {
    const self = cast.userData(Window, ctx);
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
        if (page == null) continue;
        const child = c.adw_tab_page_get_child(page);
        if (child == null) continue;
        if (!widgetIsAncestor(@ptrCast(child), pane.widget())) continue;

        // Abbreviate $HOME → ~ so the tooltip stays compact for the
        // common case of working under your home directory. Falls
        // through to the raw cwd when HOME isn't set or doesn't
        // prefix the path (e.g. /tmp, /var/log).
        var abbrev_buf: [512]u8 = undefined;
        const display_cwd: []const u8 = blk: {
            const home = @import("../util/profile.zig").getenv("HOME") orelse break :blk cwd;
            if (home.len == 0 or !std.mem.startsWith(u8, cwd, home)) break :blk cwd;
            // Match either `HOME` exactly or `HOME/...` — `HOMEextra`
            // would be a different dir and shouldn't be folded.
            const after = cwd[home.len..];
            if (after.len != 0 and after[0] != '/') break :blk cwd;
            const total = 1 + after.len; // "~" + rest
            if (total > abbrev_buf.len) break :blk cwd;
            abbrev_buf[0] = '~';
            @memcpy(abbrev_buf[1..total], after);
            break :blk abbrev_buf[0..total];
        };

        const title_c = c.adw_tab_page_get_title(page);
        const title_str: []const u8 = if (title_c != null)
            std.mem.span(@as([*:0]const u8, @ptrCast(title_c)))
        else
            "";
        const total_len = if (title_str.len > 0) title_str.len + 1 + display_cwd.len else display_cwd.len;
        const tip = self.allocator.allocSentinel(u8, total_len, 0) catch return;
        defer self.allocator.free(tip);
        if (title_str.len > 0) {
            @memcpy(tip[0..title_str.len], title_str);
            tip[title_str.len] = '\n';
            @memcpy(tip[title_str.len + 1 .. total_len], display_cwd);
        } else {
            @memcpy(tip[0..display_cwd.len], display_cwd);
        }
        c.adw_tab_page_set_tooltip(page, tip.ptr);
        return;
    }
}

/// Wired from `Pane.win_on_title`. Updates the AdwTabPage's title from
/// OSC 0/1/2 events emitted by the shell, but only while the page
/// hasn't been user-renamed. The "user-locked" flag lives on the
/// page as `g_object_set_data(page, "sketerm-title-locked")`.
fn onTermTitleChanged(ctx: ?*anyopaque, pane: *Pane, title: []const u8) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane) orelse return;
    if (c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-title-locked") != null) return;
    setTabPageTitleFromUtf8(self.allocator, page, title);
}

fn setTabPageTitleFromUtf8(allocator: std.mem.Allocator, page: *c.AdwTabPage, title: []const u8) void {
    // Tabs render single-line — drop empty titles to a fallback so a
    // tab never goes blank.
    const effective = if (title.len > 0) title else "sketerm";
    const z = allocator.allocSentinel(u8, effective.len, 0) catch return;
    defer allocator.free(z);
    @memcpy(z, effective);
    c.adw_tab_page_set_title(page, z.ptr);
    c.adw_tab_page_set_tooltip(page, z.ptr);
}

/// Walk every tab page and return the one whose widget tree contains
/// `pane`. O(tabs × panes-per-tab) — both small for any realistic
/// session.
fn tabPageForPane(self: *Window, pane: *Pane) ?*c.AdwTabPage {
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
        const child = c.adw_tab_page_get_child(page);
        if (child == null) continue;
        if (widgetIsAncestor(@ptrCast(child), pane.widget())) return page;
    }
    return null;
}

fn onTermNotification(ctx: ?*anyopaque, title: []const u8, body: []const u8) void {
    const self = cast.userData(Window, ctx);
    const app = c.gtk_window_get_application(@ptrCast(self.app_window));
    if (app == null) return;
    // Title fallback so the notification widget isn't empty.
    const effective_title = if (title.len > 0) title else "sketerm";
    const title_z = self.allocator.allocSentinel(u8, effective_title.len, 0) catch return;
    defer self.allocator.free(title_z);
    @memcpy(title_z, effective_title);
    const body_z = self.allocator.allocSentinel(u8, body.len, 0) catch return;
    defer self.allocator.free(body_z);
    @memcpy(body_z, body);
    const notif = c.g_notification_new(title_z.ptr);
    if (notif == null) return;
    defer c.g_object_unref(notif);
    if (body.len > 0) c.g_notification_set_body(notif, body_z.ptr);
    c.g_application_send_notification(@ptrCast(app), null, notif);
}

/// `win.new-tab` GAction — fires from the header-bar "+" button
/// and is the safety net when no pane has focus.
fn onNewTabAction(_: *c.GSimpleAction, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    self.newShellTab(null) catch |err| {
        std.debug.print("sketerm: new-tab action failed: {s}\n", .{@errorName(err)});
    };
}

/// Open the rename popover on a double-click on the tab bar. The
/// single-click that AdwTabBar handles internally has already
/// selected the right tab, so renameCurrentTab targets it.
fn onTabBarPressed(_: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    if (n_press != 2) return;
    const self = cast.userData(Window, user);
    self.renameCurrentTabAt(.{ .x = x, .y = y });
}

/// Scroll on the tab bar → switch tabs (browser convention).
/// Vertical-scroll dy < 0 = up = previous, dy > 0 = down = next.
/// dx (horizontal scroll, common on touchpads) maps the same way:
/// left = previous, right = next. Touchpad smooth-scroll bursts are
/// summed into `tab_scroll_accum` so each ~1.0 of accumulated delta
/// triggers exactly one tab change.
fn onTabBarScroll(
    _: *c.GtkEventControllerScroll,
    dx: f64,
    dy: f64,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);
    const delta = if (dy != 0) dy else dx;
    if (delta == 0) return 0;
    self.tab_scroll_accum += delta;
    while (self.tab_scroll_accum >= 1.0) : (self.tab_scroll_accum -= 1.0) self.nextTab();
    while (self.tab_scroll_accum <= -1.0) : (self.tab_scroll_accum += 1.0) self.prevTab();
    return 1; // handled
}

/// Move keyboard focus into the newly selected tab's pane so
/// typing immediately reaches that PTY.
fn onSelectedPageChanged(view: *c.AdwTabView, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    const page = c.adw_tab_view_get_selected_page(view);
    if (page == null) return;
    // Clear any needs-attention from the now-active tab.
    c.adw_tab_page_set_needs_attention(page, 0);
    const child = c.adw_tab_page_get_child(page);
    if (child == null) return;
    // Find the first Pane whose widget is a descendant of `child`.
    for (self.panes.items) |p| {
        if (widgetIsAncestor(@ptrCast(child), p.widget())) {
            _ = c.gtk_widget_grab_focus(@ptrCast(p.area));
            return;
        }
    }
}

/// Wired into Terminal.broadcast_sink. Routes back to the Window
/// `broadcastBytes` for the actual fan-out logic.
fn broadcastSinkFn(ctx: ?*anyopaque, source: *Terminal, bytes: []const u8) void {
    const self = cast.userData(Window, ctx);
    self.broadcastBytes(source, bytes);
}

/// Called once after the toplevel realizes. Tell the compositor to
/// blend everything behind us (no opaque hint) when background_opacity
/// < 1.0, otherwise we restore an opaque region matching the window
/// for compositor efficiency.
fn onWindowRealized(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    // Re-applied any time the opacity changes — see refreshOpaqueRegion.
    self.refreshOpaqueRegion();
}

/// Count panes whose widget tree lives inside `root`. Used by the
/// confirm-on-close gate to decide whether the user is about to lose
/// more than one shell.
fn countPanesInTree(self: *Window, root: *c.GtkWidget) usize {
    var n: usize = 0;
    for (self.panes.items) |p| {
        if (widgetIsAncestor(root, p.widget())) n += 1;
    }
    return n;
}

/// Pending close-page request. Heap-allocated so the AdwAlertDialog's
/// async response can find its way back to a finish-the-close call.
const PendingCloseTab = struct {
    win: *Window,
    page: *c.AdwTabPage,
};

/// Pending window close-request. Same idea.
const PendingCloseWin = struct { win: *Window };

/// AdwTabView "close-page" gate. Always returns GDK_EVENT_STOP (TRUE)
/// so we own the close lifecycle; subsequent
/// adw_tab_view_close_page_finish(view, page, accept) actually
/// commits or aborts. Returning FALSE conditionally races.
fn onClosePage(view: *c.AdwTabView, page: *c.AdwTabPage, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);

    if (self.config.confirm_close == .never) {
        c.adw_tab_view_close_page_finish(view, page, 1);
        return 1;
    }

    // For the "multiple" policy, only ask when this tab actually
    // contains > 1 pane (i.e. the user has split-panes inside).
    if (self.config.confirm_close == .multiple) {
        const child = c.adw_tab_page_get_child(page);
        const npanes: usize = if (child != null)
            countPanesInTree(self, @ptrCast(child))
        else
            0;
        if (npanes <= 1) {
            c.adw_tab_view_close_page_finish(view, page, 1);
            return 1;
        }
    }

    const heading = "Close tab?";
    const body = "This tab has split panes. Closing it will end every shell inside.";
    const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(c.adw_alert_dialog_new(heading, body)));
    c.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    c.adw_alert_dialog_add_response(dialog, "close", "Close");
    c.adw_alert_dialog_set_response_appearance(dialog, "close", c.ADW_RESPONSE_DESTRUCTIVE);
    c.adw_alert_dialog_set_default_response(dialog, "cancel");
    c.adw_alert_dialog_set_close_response(dialog, "cancel");

    const pending = self.allocator.create(PendingCloseTab) catch {
        // OOM — bail safely by accepting the close.
        c.adw_tab_view_close_page_finish(view, page, 1);
        return 1;
    };
    pending.* = .{ .win = self, .page = page };

    c.adw_alert_dialog_choose(dialog, self.app_window, null, onCloseTabResponse, @ptrCast(pending));
    return 1;
}

fn onCloseTabResponse(source: [*c]c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const pending = cast.userData(PendingCloseTab, user);
    defer pending.win.allocator.destroy(pending);

    const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(source));
    const resp_c = c.adw_alert_dialog_choose_finish(dialog, result);
    const resp = std.mem.span(@as([*:0]const u8, @ptrCast(resp_c)));
    const accept = std.mem.eql(u8, resp, "close");
    c.adw_tab_view_close_page_finish(pending.win.tab_view, pending.page, if (accept) 1 else 0);
}

/// Window-level close-request gate. Returning TRUE blocks the close
/// while we ask; on accept we close manually via gtk_window_close.
fn onWindowCloseRequest(_: *c.GtkWindow, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);

    if (self.config.confirm_close == .never) return 0;

    const npanes = self.panes.items.len;
    if (self.config.confirm_close == .multiple and npanes <= 1) return 0;

    const heading = "Close window?";
    const body_buf = std.fmt.allocPrintSentinel(
        self.allocator,
        "There {s} {d} {s} open. Closing the window will end every shell.",
        .{
            if (npanes == 1) @as([]const u8, "is") else @as([]const u8, "are"),
            npanes,
            if (npanes == 1) @as([]const u8, "shell") else @as([]const u8, "shells"),
        },
        0,
    ) catch {
        // Fall back to a generic body — never block close on OOM.
        return 0;
    };
    defer self.allocator.free(body_buf);

    const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(c.adw_alert_dialog_new(heading, body_buf.ptr)));
    c.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    c.adw_alert_dialog_add_response(dialog, "close", "Close");
    c.adw_alert_dialog_set_response_appearance(dialog, "close", c.ADW_RESPONSE_DESTRUCTIVE);
    c.adw_alert_dialog_set_default_response(dialog, "cancel");
    c.adw_alert_dialog_set_close_response(dialog, "cancel");

    const pending = self.allocator.create(PendingCloseWin) catch return 0;
    pending.* = .{ .win = self };

    c.adw_alert_dialog_choose(dialog, self.app_window, null, onCloseWinResponse, @ptrCast(pending));
    return 1; // block while dialog is up
}

fn onCloseWinResponse(source: [*c]c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const pending = cast.userData(PendingCloseWin, user);
    defer pending.win.allocator.destroy(pending);

    const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(source));
    const resp_c = c.adw_alert_dialog_choose_finish(dialog, result);
    const resp = std.mem.span(@as([*:0]const u8, @ptrCast(resp_c)));
    if (std.mem.eql(u8, resp, "close")) {
        // Disconnect our close-request handler before destroying so
        // it doesn't fire again on the actual close.
        c.gtk_window_destroy(@ptrCast(pending.win.app_window));
    }
}

/// Tear down all Zig-side panes + terminals that lived in this
/// AdwTabPage's widget tree. Called when the user closes a tab.
fn onPageDetached(_: *c.AdwTabView, page: *c.AdwTabPage, _: c_int, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    const child = c.adw_tab_page_get_child(page);
    if (child == null) return;
    // Capture the tab's basic state into the recently-closed ring
    // BEFORE we tear the panes down. We keep title + first-pane's
    // cwd + profile. Split trees aren't preserved (a future v2 of
    // this could re-serialise the layout tree the same way --restore
    // does, but single-pane is the 95% case).
    self.captureClosedTab(page, @ptrCast(child));
    collectAndFreePanes(self, @ptrCast(child));

    // If the user just closed the last tab via the AdwTabView "X"
    // button (which bypasses closeCurrentTab), keep the window
    // alive by auto-spawning a fresh shell. Skip during app
    // shutdown — once the window is no longer mapped, this signal
    // is firing as part of teardown and we'd just leak. Also bail
    // if the tab_view itself has already been finalised (visible
    // as `ADW_IS_TAB_VIEW` assertion warnings during quit).
    if (c.gtk_widget_get_mapped(self.app_window) == 0) return;
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(self.tab_view)), c.adw_tab_view_get_type()) == 0) return;
    if (c.adw_tab_view_get_n_pages(self.tab_view) == 0) {
        self.newShellTab(null) catch |err| {
            std.debug.print("sketerm: replacement tab spawn failed: {s}\n", .{@errorName(err)});
        };
    }
}

/// Holder for `g_idle_add` deferred Pane/Terminal teardown. Heap-
/// allocated via `c_allocator` so its lifetime is independent of any
/// of our arena/GPA state. See `deferredPaneTeardown`.
const PendingPaneFree = struct {
    pane: *Pane,
    term: *Terminal,
};

/// `g_idle_add` callback — runs after the current main-loop iteration
/// unwinds, so the widget destroy chain has fully fired its
/// controller / signal-closure cleanups before we tear our own
/// per-Pane state down. Without this defer, `Pane.deinit` deinits
/// `menu_arena` while GTK is still mid-destroy on the same widget
/// subtree, and the trailing `freeClickCtx` GDestroyNotify lands on
/// a dead arena → segfault in `ArenaAllocator.free`.
fn deferredPaneTeardown(user: ?*anyopaque) callconv(.c) c.gboolean {
    const holder = cast.userData(PendingPaneFree, user);
    holder.term.deinit();
    holder.pane.deinit();
    std.heap.c_allocator.destroy(holder);
    return 0; // G_SOURCE_REMOVE
}

fn schedulePaneTeardown(pane: *Pane, term: *Terminal) void {
    const holder = std.heap.c_allocator.create(PendingPaneFree) catch {
        // OOM — fall back to synchronous teardown. Risks the same
        // crash this defer was added to dodge, but at least we're
        // not silently leaking the Pane + Terminal.
        term.deinit();
        pane.deinit();
        return;
    };
    holder.* = .{ .pane = pane, .term = term };
    _ = c.g_idle_add(@ptrCast(&deferredPaneTeardown), @ptrCast(holder));
}

fn collectAndFreePanes(self: *Window, root: *c.GtkWidget) void {
    // Walk the widget tree under `root` (Box / Paned / GLArea), find
    // matching Panes by their .widget(), and free them + their Terminal.
    var i: usize = 0;
    while (i < self.panes.items.len) {
        const pane = self.panes.items[i];
        if (widgetIsAncestor(root, pane.widget())) {
            // If the search bar is currently targeting this pane,
            // close it before tearing the pane down — otherwise
            // applyCurrentMatch / nextMatch would deref a dead Pane
            // and the search_highlights slice would become a
            // dangling pointer into freed Window memory.
            if (self.search_pane == pane) self.closeSearch();
            if (self.hints_pane == pane) self.exitHints();

            const term = pane.terminal;
            _ = self.panes.orderedRemove(i);
            for (self.terminals.items, 0..) |t, ti| {
                if (t == term) {
                    _ = self.terminals.orderedRemove(ti);
                    break;
                }
            }
            // Pane.terminal sinks reach into Terminal/Pane state that
            // we're about to free — null them now so any in-flight
            // `g_main_context_invoke(mainDrainEvents, …)` from the
            // PTY worker that fires before the deferred teardown runs
            // sees a quiesced Terminal and produces no callbacks.
            term.clearSinks();
            schedulePaneTeardown(pane, term);
            continue;
        }
        i += 1;
    }
}

fn widgetIsAncestor(ancestor: *c.GtkWidget, w: *c.GtkWidget) bool {
    var cur: ?*c.GtkWidget = w;
    while (cur) |x| : (cur = c.gtk_widget_get_parent(x)) {
        if (x == ancestor) return true;
    }
    return false;
}

/// Hint-mode key interceptor, installed on the focused pane's input
/// Ctx while hint mode is active. Returns true when the key was
/// consumed; bare modifiers fall through so autohide/IM bookkeeping
/// stays sane.
fn onHintKey(ctx: ?*anyopaque, keyval: c_uint) bool {
    const self = cast.userData(Window, ctx);
    if (self.hints_pane == null) return false;
    switch (keyval) {
        c.GDK_KEY_Escape => {
            self.exitHints();
            return true;
        },
        c.GDK_KEY_BackSpace => {
            if (self.hints_typed_len > 0) {
                self.hints_typed_len -= 1;
                self.refreshHintOverlay();
            }
            return true;
        },
        c.GDK_KEY_Shift_L, c.GDK_KEY_Shift_R,
        c.GDK_KEY_Control_L, c.GDK_KEY_Control_R,
        c.GDK_KEY_Alt_L, c.GDK_KEY_Alt_R,
        c.GDK_KEY_Super_L, c.GDK_KEY_Super_R,
        c.GDK_KEY_Caps_Lock, c.GDK_KEY_Num_Lock,
        => return false,
        else => {},
    }
    const u = c.gdk_keyval_to_unicode(keyval);
    if (u >= 'a' and u <= 'z' and self.hints_typed_len < 2) {
        const candidate_len = self.hints_typed_len + 1;
        self.hints_typed[self.hints_typed_len] = @intCast(u);
        // Count matches under the new prefix; activate on a unique
        // FULL match, revert the keystroke when nothing matches.
        var matching: usize = 0;
        var full: ?@import("hints.zig").Match = null;
        for (self.hint_matches) |m| {
            if (!std.mem.startsWith(u8, m.label[0..m.label_len], self.hints_typed[0..candidate_len])) continue;
            matching += 1;
            if (m.label_len == candidate_len) full = m;
        }
        if (matching == 0) return true; // ignore stray key
        if (full) |m| {
            self.activateHint(m);
            self.exitHints();
            return true;
        }
        self.hints_typed_len = candidate_len;
        self.refreshHintOverlay();
        return true;
    }
    // Swallow everything else — hint mode owns the keyboard.
    return true;
}

fn eqOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn prefsApplyCallback(win_ptr: *anyopaque, new_cfg: *const Config) void {
    const win: *Window = @ptrCast(@alignCast(win_ptr));
    win.applyConfigChange(new_cfg);
}

/// Map config (cursor_shape + cursor_blink) into the screen's
/// blink/steady cursor variant.
fn mapCursorShape(shape: @import("../config.zig").CursorShape, blink: bool) @import("../grid/screen.zig").Screen.CursorShape {
    return switch (shape) {
        .block => if (blink) .block_blink else .block_steady,
        .underline => if (blink) .underline_blink else .underline_steady,
        .bar => if (blink) .bar_blink else .bar_steady,
    };
}

/// Path the prefs dialog persists to. Honours XDG; falls back to
/// ~/.config/sketerm/config.conf. Caller frees.
fn resolveConfigSavePath(allocator: std.mem.Allocator) ![]u8 {
    if (@import("../util/profile.zig").getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/config.conf", .{x});
    }
    if (@import("../util/profile.zig").getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/sketerm/config.conf", .{home});
    }
    return error.NoConfigPath;
}
