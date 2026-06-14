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
const ipc_server = @import("../ipc/server.zig");
const bg_pass_mod = @import("../render/bg_pass.zig");
const shader_pass_mod = @import("../render/shader_pass.zig");
const shader_preset_mod = @import("../shader_preset.zig");
const tree_mod = @import("tree.zig");
const tabbar_mod = @import("tabbar.zig");

/// Toolkit-free pane-tree model — one per tab, attached to the
/// AdwTabPage as qdata (travels with cross-window tab drags). The
/// GtkPaned nesting is a VIEW of this; every widget-tree mutation
/// below also updates the model. See src/ui/tree.zig.
pub const PaneTree = tree_mod.Tree(*Pane);
const TAB_TREE_KEY = "sketerm-tree";
const ipc_protocol = @import("../ipc/protocol.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const Screen = @import("../grid/screen.zig").Screen;

/// One-shot hint. Reset to false at startup; flipped on first
/// `always_on_top = true` so we don't spam the log on every
/// applyConfigChange.
var always_on_top_warned: bool = false;

/// Broadcast typing mode. Off / group / all — Terminator semantics.
pub const GroupSend = enum { off, group, all };

/// Copy-mode selection kind. `cell` = v (char-wise), `line` = V,
/// `rect` = Ctrl+v / r.
const CopyModeSel = enum { none, cell, line, rect };

/// Snapshot of a closed tab's restorable state. Owned strings live
/// in `Window.closed_arena`. Recent ring grows up to 16 entries.
pub const ClosedTab = struct {
    title: []const u8,
    cwd: ?[]const u8 = null,
    profile_name: ?[]const u8 = null,
};

/// One OSC 99 notification that may still be activated from the
/// desktop. `id` is the sanitized protocol identifier (owned),
/// echoed back in the activation report.
const NotifySlot = struct {
    token: u32,
    pane: *Pane,
    id: []u8,
    want_report: bool,
    want_focus: bool,
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

/// "closed" handler for popovers we build fresh per-open and parent
/// manually with gtk_widget_set_parent. GTK does NOT destroy such a
/// popover on popdown — it stays parented and leaks (the widget
/// subtree plus every heap ctx whose GDestroyNotify only fires when
/// its child widget is destroyed). Unparenting here on every dismissal
/// (click-away, Escape, action-completed — "closed" covers all three)
/// destroys the popover and its children, which in turn fires the
/// child-signal GDestroyNotify callbacks that free the ctxs. `user` is
/// the popover itself (same convention as menu.zig onItemClicked), so
/// no extra heap state or destroy-notify is needed here.
fn onManualPopoverClosed(_: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const pop: *c.GtkWidget = @ptrCast(@alignCast(u));
        if (c.gtk_widget_get_parent(pop) != null) {
            c.gtk_widget_unparent(pop);
        }
    }
}

/// Wire the per-open unparent-on-close for a manually-parented
/// popover. Call once, right after gtk_widget_set_parent.
fn connectManualPopoverClose(popover: *c.GtkWidget) void {
    _ = c.g_signal_connect_data(
        popover,
        "closed",
        @ptrCast(&onManualPopoverClosed),
        @ptrCast(popover),
        null,
        c.G_CONNECT_DEFAULT,
    );
}

pub const Window = struct {
    app_window: *c.GtkWidget,
    tab_view: *c.AdwTabView,
    /// Held so applyConfigChange can re-parent the tab bar between
    /// top and bottom of the toolbar view at runtime.
    tab_bar: *c.GtkWidget,
    /// Custom tab strip controller (owns rendering; bound to tab_view).
    /// `tab_bar` is its root widget, used for show/hide + toolbar moves.
    tabbar: *tabbar_mod.TabBar,
    toolbar_view: *c.GtkWidget,
    title_buf: [256]u8 = undefined,
    panes: std.ArrayList(*Pane) = .empty,
    terminals: std.ArrayList(*Terminal) = .empty,
    allocator: std.mem.Allocator,
    tab_counter: u32 = 0,
    /// Remote control: monotonic pane / tab ids + the socket server.
    /// Pane ids are allocated BEFORE the PTY spawn so the child env
    /// can carry SKETERM_PANE_ID.
    next_pane_id: u32 = 1,
    next_tab_id: u32 = 1,
    ipc: ?*ipc_server.Server = null,
    /// OSC 99 notifications awaiting a possible activation: token →
    /// originating pane + sanitized id (owned). Bounded ring — oldest
    /// evicted at 32; entries for closing panes dropped in unlistPane.
    notify_slots: std.ArrayList(NotifySlot) = .empty,
    next_notify_token: u32 = 1,
    /// Zoomed pane (tmux z): non-null while one pane fills its tab.
    /// `zoom_hidden` holds the sibling subtrees we hid, each with a
    /// strong ref so the pointers stay valid for the restore even if
    /// GTK re-shuffles the tree in between.
    zoom_pane: ?*Pane = null,
    zoom_hidden: std.ArrayList(*c.GtkWidget) = .empty,
    /// Shared background-layer source (one image decode for every
    /// pane). Panes hold a pointer; refreshBgSource mutates + bumps
    /// the generation.
    bg_source: bg_pass_mod.Source = .{},
    /// Custom post-process shader source (one file read shared by
    /// every pane). `src` is window-allocator-owned.
    shader_source: shader_pass_mod.Source = .{},
    /// The first window of the process: owns the IPC socket, quake
    /// toggle, and layout persistence. Secondary windows (tab
    /// drag-out) close when their last tab leaves; closing the
    /// primary quits the app.
    is_primary: bool = false,
    /// Resolved auto shell-integration paths (allocator-owned,
    /// sentinel-terminated). All null when the script dir wasn't
    /// found; gated on Config.shell_integration at spawn time.
    si_zsh_script: ?[:0]u8 = null,
    si_fish_script: ?[:0]u8 = null,
    si_zsh_shim: ?[:0]u8 = null,
    si_fish_shim: ?[:0]u8 = null,
    /// Socket path, computed at init (before any spawn) so every
    /// child gets SKETERM_SOCKET even if the listener starts later.
    ipc_path: ?[:0]u8 = null,
    debug_events: bool = false,
    /// Last (visible|urgent|percent) published to the taskbar via
    /// the Unity LauncherEntry signal; dedups OSC progress floods.
    taskbar_sent: u32 = 0xFFFF_FFFF,
    debug_images: bool = false,
    /// --hold: per-invocation exit_action override. Lives outside
    /// Config so a SIGUSR1 config reload can't clear it.
    hold_override: bool = false,
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

    /// Copy mode (keyboard-driven selection). Raw pane pointer —
    /// MUST be cleared on pane close, same rule as `search_pane`.
    /// Cursor uses display-buffer coords (negative row = scrollback),
    /// the Screen.SearchMatch / Selection convention.
    copymode_pane: ?*Pane = null,
    copymode_row: i32 = 0,
    copymode_col: u16 = 0,
    /// Active selection kind + the cell where the anchor was dropped.
    copymode_sel: CopyModeSel = .none,
    copymode_anchor_row: i32 = 0,
    copymode_anchor_col: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, app: ?*c.GtkApplication) !*Window {
        return initWithConfig(allocator, app, null);
    }

    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        app: ?*c.GtkApplication,
        config_override: ?Config,
        is_primary: bool,
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
        const tab_view_w = c.adw_tab_view_new();
        // Custom tab strip in place of AdwTabBar — we own the rendering
        // (activity glow). AdwTabView still owns the page model.
        const tabbar = try tabbar_mod.TabBar.create(allocator, @ptrCast(tab_view_w));
        const tab_bar_w = tabbar.root;
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
            .tabbar = tabbar,
            .toolbar_view = @ptrCast(@alignCast(toolbar_view)),
            .allocator = allocator,
            .config = if (config_override) |co| co else Config.load(allocator),
            .is_primary = is_primary,
            .search_bar = search_bar,
            .search_entry = search_entry,
            .search_label = search_label,
        };

        // Drag-a-tab-out-of-the-strip → new window.
        self.tabbar.detach_ctx = @ptrCast(self);
        self.tabbar.on_detach = onTabDetach;

        // Honor the configured GTK theme (libadwaita otherwise ignores
        // it) so the user's tab styling applies to our real `tab` nodes.
        tabbar_mod.loadTheme(self.tabbar, self.config.gtk_theme);

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

        // Detachable tabs: dragging a tab out of the tab bar asks for
        // a window to drop it into; we spawn a fresh (secondary)
        // Window and hand back its tab view.
        _ = c.g_signal_connect_data(
            tab_view_w,
            "create-window",
            @ptrCast(&onCreateWindow),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Counterpart of page-detached for cross-window transfers:
        // adopt the panes living in the attached page (move them out
        // of the source Window's bookkeeping into ours).
        _ = c.g_signal_connect_data(
            tab_view_w,
            "page-attached",
            @ptrCast(&onPageAttached),
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

        // Multi-window lifecycle: closing the primary quits the app
        // (it owns IPC/quake/layout); a secondary frees its Zig state
        // once the GTK destroy chain has unwound.
        _ = c.g_signal_connect_data(
            app_window,
            "destroy",
            @ptrCast(&onWindowDestroyed),
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

        // App-scoped action for desktop-notification activation (GIO
        // requires "app." actions on GNotifications). Target (uu) =
        // (slot token, button number; 0 = the notification body).
        if (app) |a| {
            if (c.g_action_map_lookup_action(@ptrCast(a), "notify-act") == null) {
                const vt = c.g_variant_type_new("(uu)");
                defer c.g_variant_type_free(vt);
                const act = c.g_simple_action_new("notify-act", vt);
                _ = c.g_signal_connect_data(
                    act,
                    "activate",
                    @ptrCast(&onNotifyActivate),
                    @ptrCast(self),
                    null,
                    c.G_CONNECT_DEFAULT,
                );
                c.g_action_map_add_action(@ptrCast(a), @ptrCast(act));
                c.g_object_unref(act);
            }
        }

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

        // Background image / gradient layer.
        self.refreshBgSource();

        // Custom post-process shader.
        self.refreshShaderSource();

        // Auto shell-integration script discovery.
        self.resolveShellIntegration();

        // Remote-control socket (sketerm cli). Failure is non-fatal:
        // the terminal works fine without scripting. Primary only —
        // the socket path is keyed on the pid, so a secondary window
        // would collide with (and clobber) the primary's socket.
        if (is_primary) {
            if (ipc_server.defaultSocketPath(allocator)) |sock_path| {
                self.ipc_path = sock_path;
                self.ipc = ipc_server.start(allocator, sock_path, @ptrCast(self), ipcDispatchTrampoline) catch |err| blk: {
                    std.debug.print("sketerm: remote control disabled: {s}\n", .{@errorName(err)});
                    break :blk null;
                };
                if (self.ipc == null) {
                    allocator.free(sock_path);
                    self.ipc_path = null;
                }
            } else |_| {}
        }

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
        for (self.zoom_hidden.items) |w| c.g_object_unref(w);
        self.zoom_hidden.deinit(self.allocator);
        for (self.notify_slots.items) |slot| self.allocator.free(slot.id);
        self.notify_slots.deinit(self.allocator);
        self.search_matches.deinit(self.allocator);
        @import("hints.zig").freeMatches(self.allocator, self.hint_matches);
        self.allocator.free(self.hint_matches);
        self.hints_overlay_buf.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.closed_tabs.deinit(self.allocator);
        if (self.closed_arena) |*a| a.deinit();
        if (self.ipc) |srv| srv.deinit(); // frees ipc_path (server owns it)
        if (self.bg_source.pixels) |px| c.stbi_image_free(px);
        if (self.shader_source.src) |s| self.allocator.free(s);
        if (self.shader_source.dir) |d| self.allocator.free(d);
        if (self.si_zsh_script) |s| self.allocator.free(s);
        if (self.si_fish_script) |s| self.allocator.free(s);
        if (self.si_zsh_shim) |s| self.allocator.free(s);
        if (self.si_fish_shim) |s| self.allocator.free(s);
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
        // Modes are mutually exclusive — both intercept all keys.
        if (self.copymode_pane != null) self.exitCopyMode();
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
            .path => {
                // A path hint whose file exists locally opens in the
                // editor; anything else (remote pane paths, deleted
                // files, no editor configured) copies as before.
                if (self.openPathInEditor(pane, m.text)) return;
                const z = self.allocator.allocSentinel(u8, m.text.len, 0) catch return;
                defer self.allocator.free(z);
                @memcpy(z, m.text);
                clipboard.copyToClipboard(@ptrCast(pane.area), z);
                clipboard.copyToPrimary(@ptrCast(pane.area), z);
            },
            .hash => {
                const z = self.allocator.allocSentinel(u8, m.text.len, 0) catch return;
                defer self.allocator.free(z);
                @memcpy(z, m.text);
                clipboard.copyToClipboard(@ptrCast(pane.area), z);
                clipboard.copyToPrimary(@ptrCast(pane.area), z);
            },
        }
    }

    /// Try to open a path-hint's target in the configured editor, in
    /// a new tab whose cwd matches the originating pane (compiler
    /// output is usually cwd-relative). Returns false when the file
    /// doesn't exist locally or no editor is available — the caller
    /// falls back to copying.
    fn openPathInEditor(self: *Window, pane: *Pane, text: []const u8) bool {
        const hints_mod = @import("hints.zig");
        const fl = hints_mod.parseFileLine(text);
        if (fl.path.len == 0) return false;

        // Resolve to an absolute path: ~ → $HOME, relative → pane cwd.
        var abs_buf: [4096]u8 = undefined;
        const cwd: ?[]const u8 = if (pane.terminal.cwd) |d| d else null;
        const abs: []const u8 = blk: {
            if (fl.path[0] == '/') break :blk fl.path;
            if (fl.path.len >= 2 and fl.path[0] == '~' and fl.path[1] == '/') {
                const home = @import("../util/profile.zig").getenv("HOME") orelse return false;
                break :blk std.fmt.bufPrint(&abs_buf, "{s}{s}", .{ home, fl.path[1..] }) catch return false;
            }
            const base = cwd orelse return false;
            break :blk std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ base, fl.path }) catch return false;
        };
        var z_buf: [4096]u8 = undefined;
        const abs_z = std.fmt.bufPrintZ(&z_buf, "{s}", .{abs}) catch return false;
        if (c.access(abs_z.ptr, c.F_OK) != 0) return false;

        const editor: []const u8 = blk: {
            if (self.config.hint_editor.len > 0) break :blk self.config.hint_editor;
            const profile_util = @import("../util/profile.zig");
            if (profile_util.getenv("EDITOR")) |e| {
                if (e.len > 0) break :blk e;
            }
            if (profile_util.getenv("VISUAL")) |v| {
                if (v.len > 0) break :blk v;
            }
            return false;
        };

        // The file path is shell-quoted by buildEditorCommand — it
        // came off the screen and may contain metacharacters.
        const cmd = hints_mod.buildEditorCommand(self.allocator, editor, abs, fl.line, fl.col) catch return false;
        defer self.allocator.free(cmd);
        var sh_buf: [5200:0]u8 = undefined;
        const sh_cmd = std.fmt.bufPrintZ(&sh_buf, "{s}", .{cmd}) catch return false;
        const argv = [_][*:0]const u8{ "/bin/sh", "-c", sh_cmd.ptr };
        self.addTabInternal("Editor", &argv, cwd) catch return false;
        return true;
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

    // ── Copy mode (keyboard-driven selection) ─────────────────────

    /// Enter copy mode on the focused pane. The copy cursor starts at
    /// the terminal cursor; every key press is routed through the
    /// pane input ctx's `copymode_sink` until exit (Esc/q/y/Enter).
    pub fn openCopyMode(self: *Window) void {
        if (self.copymode_pane != null) self.exitCopyMode();
        // Modes are mutually exclusive — both intercept all keys.
        if (self.hints_pane != null) self.exitHints();
        const pane = self.focusedPane() orelse return;
        const ictx = pane.input_ctx orelse return;
        const screen = pane.terminal.screen;
        self.copymode_pane = pane;
        self.copymode_sel = .none;
        self.copymode_row = @intCast(@min(screen.row, screen.rows -| 1));
        self.copymode_col = @min(screen.col, screen.cols -| 1);
        ictx.copymode_sink = onCopyModeKey;
        ictx.copymode_ctx = @ptrCast(self);
        self.copyModeRefresh();
    }

    /// Leave copy mode: uninstall the key sink, drop the overlay
    /// cursor and any in-progress selection, repaint.
    pub fn exitCopyMode(self: *Window) void {
        const pane = self.copymode_pane orelse return;
        self.copymode_pane = null;
        self.copymode_sel = .none;
        if (pane.input_ctx) |ictx| {
            ictx.copymode_sink = null;
            ictx.copymode_ctx = null;
        }
        const screen = pane.terminal.screen;
        screen.copy_cursor = null;
        screen.selection.clear();
        screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(pane.area));
    }

    /// Copy-mode key dispatch. Returns true when the key is
    /// consumed; bare modifier presses return false so chords (e.g.
    /// Ctrl+v) can still assemble in GTK's modifier tracking.
    fn handleCopyModeKey(self: *Window, keyval: c_uint, state: c.GdkModifierType) bool {
        const pane = self.copymode_pane orelse return false;
        const screen = pane.terminal.screen;
        const ctrl = (state & c.GDK_CONTROL_MASK) != 0;
        const row = self.copymode_row;
        const col: i32 = self.copymode_col;
        switch (keyval) {
            c.GDK_KEY_Shift_L, c.GDK_KEY_Shift_R,
            c.GDK_KEY_Control_L, c.GDK_KEY_Control_R,
            c.GDK_KEY_Alt_L, c.GDK_KEY_Alt_R,
            c.GDK_KEY_Super_L, c.GDK_KEY_Super_R,
            c.GDK_KEY_Hyper_L, c.GDK_KEY_Hyper_R,
            c.GDK_KEY_Meta_L, c.GDK_KEY_Meta_R,
            c.GDK_KEY_Caps_Lock, c.GDK_KEY_Num_Lock,
            => return false,
            c.GDK_KEY_Escape, c.GDK_KEY_q => self.exitCopyMode(),
            c.GDK_KEY_y, c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => self.copyModeYank(),
            c.GDK_KEY_h, c.GDK_KEY_Left => self.copyModeMoveTo(row, col - 1),
            c.GDK_KEY_l, c.GDK_KEY_Right => self.copyModeMoveTo(row, col + 1),
            c.GDK_KEY_k, c.GDK_KEY_Up => self.copyModeMoveTo(row - 1, col),
            c.GDK_KEY_j, c.GDK_KEY_Down => self.copyModeMoveTo(row + 1, col),
            c.GDK_KEY_0, c.GDK_KEY_Home => self.copyModeMoveTo(row, 0),
            c.GDK_KEY_dollar, c.GDK_KEY_End => self.copyModeMoveTo(row, copyModeLineEnd(screen, row)),
            // g / G — scrollback top / live bottom (cursor keeps its
            // column, mirroring scrollback_top/bottom actions).
            c.GDK_KEY_g => {
                const sb: i32 = if (screen.use_alt) 0 else @intCast(screen.scrollbackCount());
                self.copyModeMoveTo(-sb, col);
            },
            c.GDK_KEY_G => self.copyModeMoveTo(@as(i32, @intCast(screen.rows)) - 1, col),
            c.GDK_KEY_w => self.copyModeWord(.next),
            c.GDK_KEY_b => self.copyModeWord(.prev),
            // v = cell-wise anchor toggle; Ctrl+v (or r) = rectangular;
            // V = line-wise.
            c.GDK_KEY_v => self.copyModeToggleSel(if (ctrl) .rect else .cell),
            c.GDK_KEY_V => self.copyModeToggleSel(.line),
            c.GDK_KEY_r => self.copyModeToggleSel(.rect),
            // Everything else is swallowed while copy mode is active.
            else => {},
        }
        return true;
    }

    /// Toggle the selection anchor. Re-pressing the active kind drops
    /// the anchor; switching kinds keeps the existing anchor cell.
    fn copyModeToggleSel(self: *Window, kind: CopyModeSel) void {
        if (self.copymode_sel == kind) {
            self.copymode_sel = .none;
        } else {
            if (self.copymode_sel == .none) {
                self.copymode_anchor_row = self.copymode_row;
                self.copymode_anchor_col = self.copymode_col;
            }
            self.copymode_sel = kind;
        }
        self.copyModeRefresh();
    }

    /// Move the copy cursor, clamping into the buffer (scrollback top
    /// .. live bottom) and scrolling the view so it stays visible.
    fn copyModeMoveTo(self: *Window, row: i32, col: i32) void {
        const pane = self.copymode_pane orelse return;
        const screen = pane.terminal.screen;
        const sb: i32 = if (screen.use_alt) 0 else @intCast(screen.scrollbackCount());
        const max_row: i32 = @as(i32, @intCast(screen.rows)) - 1;
        const max_col: i32 = @as(i32, @intCast(screen.cols)) - 1;
        self.copymode_row = std.math.clamp(row, -sb, max_row);
        self.copymode_col = @intCast(std.math.clamp(col, 0, max_col));
        // Keep the cursor on-screen: its visible row is row +
        // view_offset. Moving past the top scrolls back; past the
        // bottom scrolls forward (same clamping as scrollback_page_*).
        const view_off: i32 = @intCast(@min(screen.view_offset, screen.scrollbackCount()));
        if (self.copymode_row + view_off < 0) {
            screen.view_offset = @intCast(-self.copymode_row);
        } else if (self.copymode_row + view_off > max_row) {
            screen.view_offset = @intCast(max_row - self.copymode_row);
        }
        self.copyModeRefresh();
    }

    const WordDir = enum { next, prev };

    /// w / b — jump to the next / previous word start, wrapping to
    /// adjacent lines when the current one runs out of words.
    fn copyModeWord(self: *Window, dir: WordDir) void {
        const pane = self.copymode_pane orelse return;
        const screen = pane.terminal.screen;
        const wm = @import("../grid/word_motion.zig");
        if (screen.lineCellsAtPub(self.copymode_row)) |cells| {
            const hit = switch (dir) {
                .next => wm.nextWordStart(cells, screen.word_chars, self.copymode_col),
                .prev => wm.prevWordStart(cells, screen.word_chars, self.copymode_col),
            };
            if (hit) |c2| {
                self.copyModeMoveTo(self.copymode_row, @intCast(c2));
                return;
            }
        }
        const sb: i32 = if (screen.use_alt) 0 else @intCast(screen.scrollbackCount());
        const max_row: i32 = @as(i32, @intCast(screen.rows)) - 1;
        var row = self.copymode_row;
        while (true) {
            row = if (dir == .next) row + 1 else row - 1;
            if (row < -sb or row > max_row) return; // buffer edge — stay put
            const cells = screen.lineCellsAtPub(row) orelse continue;
            const hit = switch (dir) {
                .next => wm.firstWordStart(cells, screen.word_chars),
                .prev => wm.lastWordStart(cells, screen.word_chars),
            };
            if (hit) |c2| {
                self.copyModeMoveTo(row, @intCast(c2));
                return;
            }
        }
    }

    /// y / Enter — copy the active selection to CLIPBOARD + PRIMARY
    /// and leave copy mode. No selection → just exits.
    fn copyModeYank(self: *Window) void {
        const pane = self.copymode_pane orelse return;
        const screen = pane.terminal.screen;
        if (screen.selection.isActive()) blk: {
            const text = screen.extractSelection(self.allocator) catch break :blk;
            defer self.allocator.free(text);
            if (text.len == 0) break :blk;
            const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch break :blk;
            defer self.allocator.free(cstr);
            @memcpy(cstr, text);
            clipboard.copyToClipboard(@ptrCast(pane.area), cstr);
            clipboard.copyToPrimary(@ptrCast(pane.area), cstr);
        }
        self.exitCopyMode();
    }

    /// Re-derive `screen.selection` from anchor + cursor, publish the
    /// overlay cursor, repaint. Called after every copy-mode change.
    fn copyModeRefresh(self: *Window) void {
        const pane = self.copymode_pane orelse return;
        const screen = pane.terminal.screen;
        const row = self.copymode_row;
        const col = self.copymode_col;
        const a_row = self.copymode_anchor_row;
        const a_col = self.copymode_anchor_col;
        switch (self.copymode_sel) {
            .none => screen.selection.clear(),
            .cell => {
                // Inclusive both ways: Selection's bottom column is
                // exclusive, so bump whichever endpoint is later.
                if (row > a_row or (row == a_row and col >= a_col)) {
                    screen.selection.start(a_row, a_col, .normal);
                    screen.selection.extend(row, @as(i32, col) + 1);
                } else {
                    screen.selection.start(a_row, @as(i32, a_col) + 1, .normal);
                    screen.selection.extend(row, col);
                }
            },
            .line => {
                // Whole lines, anchor row through cursor row.
                screen.selection.start(@min(a_row, row), 0, .normal);
                screen.selection.extend(@max(a_row, row), @intCast(screen.cols));
            },
            .rect => {
                const lo: i32 = @min(a_col, col);
                const hi: i32 = @as(i32, @max(a_col, col)) + 1;
                screen.selection.start(a_row, lo, .rectangular);
                screen.selection.extend(row, hi);
            },
        }
        screen.copy_cursor = .{ .row = row, .col = col };
        screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(pane.area));
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

        const page = self.appendOrInsertTab(wrapper, .{ .leaf = pane });
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

        var model_root: PaneTree.Node = undefined;
        const root_widget = try self.buildTreeWidget(spec.tree, &model_root);
        c.gtk_box_append(@ptrCast(wrapper), root_widget);

        const title_z = try self.allocator.allocSentinel(u8, spec.title.len, 0);
        defer self.allocator.free(title_z);
        @memcpy(title_z, spec.title);

        const page = self.appendOrInsertTab(wrapper, model_root);
        c.adw_tab_page_set_title(page, title_z.ptr);
        c.adw_tab_page_set_tooltip(page, title_z.ptr);
        // Re-arm the user-rename lock so OSC titles can't stomp a
        // deliberately named tab. Files predating the flag (null)
        // count as renamed — restored titles never followed OSC then.
        if (spec.title_locked orelse true) {
            c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-title-locked", @ptrCast(page));
        }
        if (spec.pinned) c.adw_tab_view_set_page_pinned(self.tab_view, page, 1);
        if (spec.color) |col_str| {
            if (parseHexRGB(col_str)) |col| self.setTabColor(page, col);
        }
    }

    /// Re-apply a PaneSpec's saved shader state: preset by name
    /// first, then the explicit path pick, then a sticky clear.
    fn restorePaneShader(self: *Window, pane: *Pane, p: @import("../layout.zig").PaneSpec) void {
        if (p.shader_preset.len > 0) {
            if (self.applyShaderPresetByName(pane, p.shader_preset)) return;
        }
        if (p.custom_shader.len > 0)
            _ = pane.setCustomShader(p.custom_shader, self.config.custom_shader_animation, true)
        else if (p.shader_cleared)
            pane.clearShader();
    }

    /// Build the widget subtree for a layout spec, producing the
    /// matching model node in `node_out` (valid only on success).
    fn buildTreeWidget(self: *Window, tree: @import("../layout.zig").Tree, node_out: *PaneTree.Node) !*c.GtkWidget {
        switch (tree) {
            .pane => |p| {
                // Durable mux pane: reattach (or recreate under the
                // same name) instead of spawning a local PTY. A dead
                // host / failed daemon falls through to the plain
                // spawn below so startup never wedges on a layout.
                if (p.mux_session.len > 0) {
                    if (self.restoreMuxPane(p)) |pane| {
                        self.restorePaneShader(pane, p);
                        node_out.* = .{ .leaf = pane };
                        return pane.widget();
                    } else |err| {
                        std.debug.print(
                            "sketerm: mux restore '{s}'{s}{s} failed ({s}) — spawning local shell\n",
                            .{ p.mux_session, if (p.mux_host.len > 0) " @ " else "", p.mux_host, @errorName(err) },
                        );
                    }
                }

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
                    // The profile's shell overrides command[0] if
                    // set, so duplicating an "ssh" profile keeps
                    // using ssh even after a layout round-trip
                    // captured the current $SHELL.
                    const eff_cmd: []const u8 = if (i == 0 and profile != null and profile.?.settings.shell != null)
                        profile.?.settings.shell.?
                    else
                        cmd;
                    const z = try self.allocator.allocSentinel(u8, eff_cmd.len, 0);
                    try arg_owners.append(self.allocator, z);
                    @memcpy(z, eff_cmd);
                    argv_buf[i] = z.ptr;
                }

                const pane_id = self.allocPaneId();
                var pty = try Pty.spawn(.{
                    .argv = argv_buf,
                    .cwd = p.cwd,
                    .rows = 24,
                    .cols = 80,
                    .pane_id = pane_id,
                    .socket_path = if (self.ipc_path) |sp| sp.ptr else null,
                    .shell_integration = self.shellIntegrationFor(argv_buf[0]),
                });
                errdefer _ = pty.closeAndReap();

                const term = try Terminal.init(self.allocator, pty, 80, 24);
                errdefer term.deinit();
                term.debug_to_stderr = self.debug_events;

                const pane = try self.makePane(term);
                pane.id = pane_id;
                pane.setSpawnArgv(argv_buf);
                self.wirePaneSinks(pane);
                // Profile name on the pane so cycle/restore tracks it.
                if (profile) |pr| pane.active_profile = pr.name;
                self.applyPaneConfig(pane, .{
                    .profile = profile,
                    .font_size_override = p.font_size,
                });
                // Explicit per-pane shader preset/pick (wins over the
                // profile/global shader applyPaneConfig resolved), or
                // an explicit clear that turns the shader off.
                self.restorePaneShader(pane, p);

                try self.panes.append(self.allocator, pane);
                try self.terminals.append(self.allocator, term);
                node_out.* = .{ .leaf = pane };
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
                var first_node: PaneTree.Node = undefined;
                var second_node: PaneTree.Node = undefined;
                const first = try self.buildTreeWidget(s.children[0], &first_node);
                const second = try self.buildTreeWidget(s.children[1], &second_node);
                c.gtk_paned_set_start_child(@ptrCast(paned), first);
                c.gtk_paned_set_end_child(@ptrCast(paned), second);
                const split_node = try self.allocator.create(PaneTree.Split);
                split_node.* = .{
                    .orientation = if (s.orientation == .horizontal) .horizontal else .vertical,
                    .ratio = if (s.ratio > 0 and s.ratio < 1) s.ratio else 0.5,
                    .children = .{ first_node, second_node },
                    .view = paned,
                };
                node_out.* = .{ .split = split_node };

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
        const pane_id = self.allocPaneId();
        var pty = try Pty.spawn(.{
            .argv = argv,
            .cwd = cwd,
            .rows = 24,
            .cols = 80,
            .login_shell = self.config.settings.login_shell,
            .pane_id = pane_id,
            .socket_path = if (self.ipc_path) |sp| sp.ptr else null,
            .shell_integration = self.shellIntegrationFor(argv[0]),
        });
        errdefer _ = pty.closeAndReap();

        const term = try Terminal.init(self.allocator, pty, 80, 24);
        errdefer term.deinit();
        term.debug_to_stderr = self.debug_events;

        const pane = try self.makePane(term);
        pane.id = pane_id;
        pane.setSpawnArgv(argv);
        // If anything below this fails (alloc failure adding to the
        // panes/terminals list, etc.) we'd otherwise leave a Pane
        // alive whose Terminal we just reaped via the prior errdefer
        // — its on_* callbacks would still point at the dead
        // Terminal, and the next render would fault. Drop the Pane
        // explicitly on failure so neither side outlives the other.
        errdefer pane.deinit();

        self.wirePaneSinks(pane);

        self.applyPaneConfig(pane, .{});

        // Wrap pane.widget() in a Box so we can swap it for a Paned
        // when splits happen. Box always has exactly one child.
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_box_append(@ptrCast(wrapper), pane.widget());

        const page = self.appendOrInsertTab(wrapper, .{ .leaf = pane });
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
        pane.middle_click_action = self.config.mouse_middle_click;
        pane.right_click_action = self.config.mouse_right_click;
        pane.bg_pass.source = &self.bg_source;
        pane.shader_default_source = &self.shader_source;
        pane.refreshShaderBinding();
        pane.updateShaderTick();
        // Renderer bold flags.
        pane.grid_pass.allow_bold = self.config.allow_bold;
        pane.grid_pass.bold_is_bright = self.config.bold_is_bright;
        pane.cell_pass.allow_bold = self.config.allow_bold;
        pane.cell_pass.bold_is_bright = self.config.bold_is_bright;
        pane.grid_pass.min_contrast = self.config.minimum_contrast;
        pane.cell_pass.min_contrast = self.config.minimum_contrast;
        pane.grid_pass.enable_url_underline = self.config.auto_url_detect;
        // Per-pane titlebar visibility.
        pane.setTitlebarVisible(self.config.show_titlebar);
        // Inactive-pane dimming factors.
        pane.inactive_darken = self.config.inactive_darken;
        pane.inactive_desaturate = self.config.inactive_desaturate;
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
        const adw_page = self.appendOrInsertTab(wrapper, .{ .leaf = pane });
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
    /// The pane gets the profile's complete settings bundle (shell,
    /// font, colors, scrollback, shader, …); empty/null profile = the
    /// window default profile, falling back to the Default settings.
    fn spawnShellPaneOpts(self: *Window, inherit_cwd: ?[]const u8, profile_name: ?[]const u8) !*Pane {
        const profile: ?*const @import("../config.zig").Profile = if (profile_name) |n|
            self.findProfile(n)
        else if (self.config.default_profile.len > 0)
            self.findProfile(self.config.default_profile)
        else
            null;
        const s: *const @import("../config.zig").ProfileSettings =
            if (profile) |p| &p.settings else &self.config.settings;

        // Pick effective shell: settings.shell → $SHELL env → /bin/bash.
        var shell_buf: [256:0]u8 = undefined;
        const shell: [*:0]const u8 = if (s.shell) |sh| blk: {
            const n = @min(sh.len, shell_buf.len);
            @memcpy(shell_buf[0..n], sh[0..n]);
            shell_buf[n] = 0;
            break :blk @ptrCast(&shell_buf);
        } else if (c.getenv("SHELL")) |env_ptr| @as([*:0]const u8, @ptrCast(env_ptr)) else "/bin/bash";

        const argv = [_][*:0]const u8{shell};

        var term_buf: [64:0]u8 = undefined;
        var ct_buf: [64:0]u8 = undefined;
        const tlen = @min(s.term_env.len, term_buf.len);
        @memcpy(term_buf[0..tlen], s.term_env[0..tlen]);
        term_buf[tlen] = 0;
        const ctlen = @min(s.color_term_env.len, ct_buf.len);
        @memcpy(ct_buf[0..ctlen], s.color_term_env[0..ctlen]);
        ct_buf[ctlen] = 0;

        const pane_id = self.allocPaneId();
        var pty = try Pty.spawn(.{
            .argv = &argv,
            .rows = 24,
            .cols = 80,
            .term = @ptrCast(&term_buf),
            .color_term = @ptrCast(&ct_buf),
            .cwd = inherit_cwd,
            .login_shell = s.login_shell,
            .pane_id = pane_id,
            .socket_path = if (self.ipc_path) |sp| sp.ptr else null,
            .shell_integration = self.shellIntegrationFor(argv[0]),
        });
        errdefer _ = pty.closeAndReap();

        const term = try Terminal.init(self.allocator, pty, 80, 24);
        errdefer term.deinit();
        term.debug_to_stderr = self.debug_events;

        const pane = try self.makePane(term);
        pane.id = pane_id;
        pane.setSpawnArgv(&argv);
        self.wirePaneSinks(pane);

        // Profile name on the pane so cycle/restore knows which one
        // it spawned with.
        if (profile) |p| pane.active_profile = p.name;

        self.applyPaneConfig(pane, .{ .profile = profile });
        try self.panes.append(self.allocator, pane);
        try self.terminals.append(self.allocator, term);
        return pane;
    }

    /// Wire every Window-level sink onto a fresh pane. THE single
    /// place pane→window callbacks are connected — every pane
    /// creation path (tab, split, layout restore, mux attach) goes
    /// through here, so a new sink added here reaches all of them.
    /// All handlers are pane-aware and no-op when irrelevant (e.g.
    /// child-exit on a remote pane means "session ended / connection
    /// lost" and detaches to a local shell instead of exit_action).
    fn wirePaneSinks(self: *Window, pane: *Pane) void {
        pane.win_clip_ctx = @ptrCast(self);
        pane.win_on_clipboard = onTermClipboardSet;
        pane.win_notify_ctx = @ptrCast(self);
        pane.win_on_notification = onTermNotification;
        pane.win_progress_ctx = @ptrCast(self);
        pane.win_on_progress = onTermProgress;
        pane.win_bell_ctx = @ptrCast(self);
        pane.win_on_bell = onTermBell;
        pane.win_child_ctx = @ptrCast(self);
        pane.win_on_child_exit = onTermChildExit;
        pane.win_cwd_ctx = @ptrCast(self);
        pane.win_on_cwd = onTermCwdChanged;
        pane.win_setprofile_ctx = @ptrCast(self);
        pane.win_on_set_profile = onTermSetProfile;
        pane.win_focus_ctx = @ptrCast(self);
        pane.win_on_focus_enter = onPaneFocused;
        pane.win_activity_ctx = @ptrCast(self);
        pane.win_on_activity = onTermActivity;
        // OSC 0/1/2 titles drive the AdwTabPage title — but only
        // until the user explicitly renames the tab (which sets the
        // "user-locked" flag on the page). Renaming with an empty
        // string clears the lock and lets OSC tracking resume.
        pane.win_title_ctx = @ptrCast(self);
        pane.win_on_title = onTermTitleChanged;
        pane.win_session_rename_ctx = @ptrCast(self);
        pane.win_on_session_renamed = onTermSessionRenamed;
    }

    /// Drop every window-level pointer into a pane (search / hints /
    /// copy mode / zoom / notify slots) and unlist it + its terminal —
    /// WITHOUT tearing the pane down. Shared by the close path
    /// (unlistPane) and cross-window tab adoption, where the pane
    /// lives on under another Window.
    fn disownPane(self: *Window, pane: *Pane) void {
        if (self.search_pane == pane) self.closeSearch();
        if (self.hints_pane == pane) self.exitHints();
        if (self.copymode_pane == pane) self.exitCopyMode();
        // ANY pane removal unzooms (tmux semantics) — the close is
        // about to collapse a GtkPaned, and doing that surgery inside
        // a hidden tree would leave half-restored visibility behind.
        self.unzoomPane();
        self.dropNotifySlotsForPane(pane);
        for (self.panes.items, 0..) |p, idx| {
            if (p == pane) {
                _ = self.panes.orderedRemove(idx);
                break;
            }
        }
        const term = pane.terminal;
        for (self.terminals.items, 0..) |t, ti| {
            if (t == term) {
                _ = self.terminals.orderedRemove(ti);
                break;
            }
        }
    }

    /// Sever a pane from the window before teardown: disown it, fence
    /// the terminal's sinks, and defer the actual deinit past GTK's
    /// widget-destroy chain. Counterpart of wirePaneSinks — the
    /// single removal path.
    fn unlistPane(self: *Window, pane: *Pane) void {
        self.disownPane(pane);
        const term = pane.terminal;
        term.clearSinks();
        schedulePaneTeardown(pane, term);
    }

    /// "Pane Shader…": pick a GLSL file for the focused pane only.
    /// The pick is sticky across config reloads (custom_shader_user).
    fn pickPaneShader(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        const dialog = c.gtk_file_dialog_new();
        c.gtk_file_dialog_set_title(dialog, "Choose Pane Shader (GLSL, shadertoy mainImage)");
        // Start where the user will actually find shaders: the
        // pane's current pick, else the shipped presets directory.
        if (pane.custom_shader_path) |cur| {
            var buf: [4096]u8 = undefined;
            if (std.fmt.bufPrintZ(&buf, "{s}", .{cur})) |z| {
                const gf = c.g_file_new_for_path(z.ptr);
                c.gtk_file_dialog_set_initial_file(dialog, gf);
                c.g_object_unref(gf);
            } else |_| {}
        } else if (shaderPresetDirZ()) |dir| {
            const gf = c.g_file_new_for_path(dir);
            c.gtk_file_dialog_set_initial_folder(dialog, gf);
            c.g_object_unref(gf);
        }
        const ctx = self.allocator.create(ShaderPickCtx) catch return;
        ctx.* = .{ .win = self, .pane = pane };
        c.gtk_file_dialog_open(dialog, @ptrCast(self.app_window), null, @ptrCast(&onShaderPicked), @ptrCast(ctx));
    }

    /// Directory holding the shipped CRT shader presets, or null.
    /// Same resolution order as the shell-integration scripts:
    /// installed share dir next to the exe → repo data/ (dev tree)
    /// → /usr/share. Resolved once, cached for the process.
    fn shaderPresetDirZ() ?[*:0]const u8 {
        const S = struct {
            var buf: [4096]u8 = undefined;
            var resolved: ?[*:0]const u8 = null;
            var done: bool = false;
        };
        if (S.done) return S.resolved;
        S.done = true;
        var exe_buf: [4096]u8 = undefined;
        if (@import("../util/platform.zig").exePath(&exe_buf)) |exe_path| {
            const exe_dir = std.fs.path.dirname(exe_path) orelse "/usr/bin";
            const candidates = [_][]const u8{
                "/../share/sketerm/shaders",
                "/../../data/shaders",
            };
            for (candidates) |suffix| {
                const cand = std.fmt.bufPrintZ(&S.buf, "{s}{s}", .{ exe_dir, suffix }) catch continue;
                if (c.access(cand.ptr, c.R_OK) == 0) {
                    S.resolved = cand.ptr;
                    return S.resolved;
                }
            }
        }
        const sys = std.fmt.bufPrintZ(&S.buf, "/usr/share/sketerm/shaders", .{}) catch return null;
        if (c.access(sys.ptr, c.R_OK) == 0) S.resolved = sys.ptr;
        return S.resolved;
    }

    /// The shader_params items slice may have been reallocated (or
    /// the config arena swapped) — re-point every Source at it.
    fn repointShaderOverrides(self: *Window) void {
        self.shader_source.overrides = self.config.shader_params.items;
        for (self.panes.items) |p| {
            // A preset pane owns its override slice — leave it alone.
            if (!p.hasOwnShaderParams())
                p.shader_own.overrides = self.config.shader_params.items;
        }
    }

    /// Route a shader-param edit: a preset pane edits its own per-
    /// pane set (saved via the preset, not the config); a plain pane
    /// edits the global config entry.
    pub fn setPaneShaderParam(self: *Window, pane: *Pane, name: []const u8, value: f32, color: ?[3]f32) void {
        if (pane.hasOwnShaderParams()) {
            pane.setPresetParam(name, value, color);
        } else {
            self.setShaderParam(name, value, color);
        }
    }

    /// Load + apply a named shader preset to `pane`. False when the
    /// preset (or its shader file) can't be read.
    pub fn applyShaderPresetByName(self: *Window, pane: *Pane, name: []const u8) bool {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const preset = shader_preset_mod.load(arena_state.allocator(), name) catch return false;
        if (preset.shader_path.len == 0) return false;
        if (!pane.setCustomShader(preset.shader_path, preset.animate, true)) return false;
        pane.applyShaderPresetParams(name, preset.params);
        return true;
    }

    /// Set (or update) one shader_param override, live + persisted.
    /// Called per slider tick from the shader config dialog — values
    /// upload each frame, so the very next render shows it.
    pub fn setShaderParam(self: *Window, name: []const u8, value: f32, color: ?[3]f32) void {
        if (self.config.arena == null) {
            // Defaults-only config (no file yet) has no arena to own
            // the entry name; give it one.
            self.config.arena = std.heap.ArenaAllocator.init(self.allocator);
        }
        const arena = self.config.arena.?.allocator();
        var found = false;
        for (self.config.shader_params.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.value = value;
                entry.color = color;
                found = true;
                break;
            }
        }
        if (!found) {
            const name_dup = arena.dupe(u8, name) catch return;
            self.config.shader_params.append(arena, .{
                .name = name_dup,
                .value = value,
                .color = color,
            }) catch return;
        }
        self.repointShaderOverrides();
        for (self.panes.items) |p| c.gtk_gl_area_queue_render(@ptrCast(p.area));
        self.persistConfig();
    }

    fn clearPaneShader(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        // Strictly per-pane: explicit, sticky "no shader" — overrides
        // profile/global and survives config reloads (Pane.shader_cleared).
        pane.dropShaderPreset(self.config.shader_params.items);
        pane.clearShader();
    }

    /// applyPaneConfig with the pane's stored profile re-resolved by
    /// name — for paths that need a config re-push outside the
    /// spawn/restore flows.
    fn applyPaneConfigByName(self: *Window, pane: *Pane) void {
        var profile: ?*const @import("../config.zig").Profile = null;
        if (pane.active_profile) |name| {
            for (self.config.profiles.items) |*p| {
                if (std.mem.eql(u8, p.name, name)) {
                    profile = p;
                    break;
                }
            }
        }
        self.applyPaneConfig(pane, .{ .profile = profile });
    }

    /// Spawn an empty secondary Window sharing this one's config.
    /// Used by tab drag-out (AdwTabView "create-window") and the
    /// detach_tab action.
    fn spawnSecondaryWindow(self: *Window) ?*Window {
        const app = c.gtk_window_get_application(@ptrCast(self.app_window));
        const cfg = self.config.clone(self.allocator) catch null;
        const win = Window.initWithConfig(self.allocator, @ptrCast(app), cfg, false) catch |err| {
            std.debug.print("sketerm: secondary window spawn failed: {s}\n", .{@errorName(err)});
            return null;
        };
        win.debug_events = self.debug_events;
        win.hold_override = self.hold_override;
        c.gtk_window_present(@ptrCast(win.app_window));
        return win;
    }

    /// detach_tab action: move the selected tab into a fresh window —
    /// keyboard/palette equivalent of dragging it out of the tab bar.
    fn detachCurrentTab(self: *Window) void {
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
        const win = self.spawnSecondaryWindow() orelse return;
        c.adw_tab_view_transfer_page(self.tab_view, page, win.tab_view, 0);
    }

    /// Take ownership of a pane that arrived from another Window via
    /// tab drag-out/drag-in: unhook it there, list it here, rewire
    /// every sink and config-derived field against this window.
    fn adoptPane(self: *Window, pane: *Pane) void {
        const src_any = pane.win_clip_ctx orelse return;
        const src: *Window = @ptrCast(@alignCast(src_any));
        if (src == self) return;
        src.disownPane(pane);
        self.panes.append(self.allocator, pane) catch return;
        self.terminals.append(self.allocator, pane.terminal) catch {};
        self.wirePaneSinks(pane);
        // Re-point active_profile off the SOURCE window's config arena
        // (which is freed on its next applyConfigChange / deinit) onto
        // a name owned by OUR arena — same pattern as applyConfigChange.
        // The source name is still valid here (source window is alive),
        // so capture it before re-pointing. No matching profile in this
        // window → drop to Default (null).
        if (pane.active_profile) |pn| {
            pane.active_profile = null;
            for (self.config.profiles.items) |*pr| {
                if (std.mem.eql(u8, pr.name, pn)) {
                    pane.active_profile = pr.name;
                    break;
                }
            }
        }
        // Re-point bindings, menu/shortcut sinks, bg/shader sources and
        // push this window's config, resolving the pane's profile BY
        // NAME so it keeps its font/colors/scrollback. The pane now
        // renders under our atlas settings; per-pane font zoom resets,
        // same as a config reload.
        self.applyPaneConfigByName(pane);
    }

    /// Walk a transferred page's widget tree and adopt every pane in
    /// it (split trees carry several).
    fn adoptPanesInTree(self: *Window, w: *c.GtkWidget) void {
        if (c.g_object_get_data(@ptrCast(@alignCast(w)), "sketerm-pane")) |data| {
            const pane: *Pane = @ptrCast(@alignCast(data));
            self.adoptPane(pane);
            return;
        }
        var child = c.gtk_widget_get_first_child(w);
        while (child) |ch| : (child = c.gtk_widget_get_next_sibling(ch)) {
            self.adoptPanesInTree(ch);
        }
    }

    const PaneConfigOpts = struct {
        profile: ?*const @import("../config.zig").Profile = null,
        /// Saved per-pane font size (layout restore / Ctrl± zoom).
        /// Wins over the profile's font_size.
        font_size_override: ?u16 = null,
    };

    /// Push the pane's effective settings bundle (its profile, or
    /// the Default settings) + app-level config onto a fresh pane +
    /// its terminal. The single source of truth for ALL
    /// pane-creation paths (new tab/split, layout restore,
    /// addTabInternal) — restored panes used to skip the color push
    /// entirely and kept the built-in gray background.
    fn applyPaneConfig(self: *Window, pane: *Pane, opts: PaneConfigOpts) void {
        const s: *const @import("../config.zig").ProfileSettings =
            if (opts.profile) |p| &p.settings else &self.config.settings;
        const term = pane.terminal;

        pane.font_size = opts.font_size_override orelse s.font_size;
        pane.font_path = s.font_path;
        pane.font_family = if (s.font_family.len > 0) s.font_family else null;
        pane.font_features = if (s.font_features.len > 0) s.font_features else null;
        pane.cursor_blink_us = @as(i64, @intCast(self.config.cursor_blink_ms)) * 1000;
        pane.line_pad_px = s.line_pad_px;
        pane.grid_pass.pad = s.padding;
        pane.cell_pass.pad = s.padding;
        const fg_bg = self.resolveColorsFor(s);
        pane.grid_pass.default_fg = fg_bg.fg;
        pane.grid_pass.default_bg = fg_bg.bg;
        pane.cell_pass.default_fg = fg_bg.fg;
        pane.cell_pass.default_bg = fg_bg.bg;
        pane.grid_pass.enable_ligatures = self.config.ligatures;
        pane.grid_pass.enable_bidi = self.config.bidi;
        // Push config-driven defaults onto the screen so OSC 4/10/11
        // queries reply with the configured values until apps override.
        term.screen.default_fg = fg_bg.fg;
        term.screen.default_bg = fg_bg.bg;
        term.screen.configured_fg = fg_bg.fg;
        term.screen.configured_bg = fg_bg.bg;
        term.screen.cursor_color = if (s.cursor_color_default)
            .{ 0, 0, 0, 0 }
        else
            s.cursor_color;
        term.screen.scrollback_capacity = s.scrollback;
        term.screen.bracketed_paste = self.config.bracketed_paste;
        term.screen.scroll_on_output = self.config.scroll_on_output;
        term.screen.track_activity = self.config.track_tab_activity;
        term.screen.allow_clipboard_read = self.config.clipboard_read;
        // Initial dark/light for DSR ?996 / mode 2031, derived from
        // the effective background's luminance — that's what apps
        // actually want to know (vim background=dark/light).
        term.screen.color_scheme_dark = isDarkBg(fg_bg.bg);
        term.screen.word_chars = self.config.word_chars;
        // Effective palette: explicit palette > scheme lookup >
        // built-in defaults.
        if (resolvePalette(s)) |pal| {
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                term.screen.palette[i] = pal[i];
                pane.grid_pass.palette[i] = pal[i];
            }
        }

        // Shader resolution: explicit user pick / clear > profile
        // settings. Both the pick and an explicit clear are sticky —
        // config reloads / profile pushes leave them alone.
        pane.shader_default_source = &self.shader_source;
        if (!pane.hasOwnShaderParams())
            pane.shader_own.overrides = self.config.shader_params.items;
        if (!pane.custom_shader_user and !pane.shader_cleared) {
            _ = pane.setCustomShader(
                if (s.custom_shader.len > 0) s.custom_shader else null,
                self.config.custom_shader_animation,
                false,
            );
        }
        pane.refreshShaderBinding();
        pane.updateShaderTick();
    }

    /// Effective 16-colour palette for a settings bundle: explicit
    /// `palette` wins; `scheme` alone resolves through the built-in
    /// table; null = keep the built-in 256-table values.
    fn resolvePalette(s: *const @import("../config.zig").ProfileSettings) ?[16][3]u8 {
        if (s.palette) |p| return p;
        if (s.scheme.len > 0) {
            if (@import("../grid/schemes.zig").lookup(s.scheme)) |sch| return sch.palette;
        }
        return null;
    }

    /// Split the focused pane: spawn a new pane and place the two
    /// inside a GtkPaned. orientation = HORIZONTAL splits side-by-side,
    /// VERTICAL splits top/bottom.
    /// Toggle tmux-style pane zoom: the focused pane fills its tab;
    /// toggling again restores the split layout. Implemented by
    /// hiding the sibling subtree at every GtkPaned level on the path
    /// to the tab root — a paned with one hidden child gives the
    /// other the full allocation and hides its handle, so nested
    /// splits collapse cleanly with NO reparenting (reparenting would
    /// unrealize the GLArea and tear down its GL context).
    pub fn toggleZoomPane(self: *Window) void {
        if (self.zoom_pane != null) {
            self.unzoomPane();
            return;
        }
        const pane = self.focusedPane() orelse return;
        const page = tabPageForPane(self, pane) orelse return;
        const tab_child = c.adw_tab_page_get_child(page) orelse return;

        var w: *c.GtkWidget = pane.widget();
        while (w != @as(*c.GtkWidget, @ptrCast(tab_child))) {
            const parent = c.gtk_widget_get_parent(w) orelse break;
            if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(parent)), c.gtk_paned_get_type()) != 0) {
                const start = c.gtk_paned_get_start_child(@ptrCast(parent));
                const end = c.gtk_paned_get_end_child(@ptrCast(parent));
                const sibling: ?*c.GtkWidget = if (start == w) end else start;
                if (sibling) |sib| {
                    // Strong ref so the restore pointers stay valid no
                    // matter what happens to the tree in between.
                    _ = c.g_object_ref(sib);
                    c.gtk_widget_set_visible(sib, 0);
                    self.zoom_hidden.append(self.allocator, sib) catch {
                        c.gtk_widget_set_visible(sib, 1);
                        c.g_object_unref(sib);
                    };
                }
            }
            w = parent;
        }
        if (self.zoom_hidden.items.len == 0) return; // single pane — nothing to zoom
        self.zoom_pane = pane;
        _ = c.gtk_widget_grab_focus(@ptrCast(pane.area));
    }

    pub fn unzoomPane(self: *Window) void {
        const pane = self.zoom_pane orelse return;
        self.zoom_pane = null;
        for (self.zoom_hidden.items) |w| {
            c.gtk_widget_set_visible(w, 1);
            c.g_object_unref(w);
        }
        self.zoom_hidden.clearRetainingCapacity();
        _ = c.gtk_widget_grab_focus(@ptrCast(pane.area));
    }

    pub fn splitFocused(self: *Window, orientation: c_uint) !void {
        // Splitting a zoomed layout would wire the new pane into a
        // hidden tree — restore the real layout first.
        self.unzoomPane();
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

        // Mirror the widget surgery in the tab's tree model: focused
        // keeps the first slot (start child), new pane the second.
        if (is_paned or is_box) {
            if (tabPageForPane(self, focused_pane)) |page| {
                if (tabTreeOf(page)) |t| {
                    const orient: tree_mod.Orient = if (orientation == c.GTK_ORIENTATION_HORIZONTAL) .horizontal else .vertical;
                    t.splitLeaf(focused_pane, new_pane, orient, 0.5, paned) catch
                        std.debug.print("sketerm: tree model split desync (leaf not found)\n", .{});
                }
            }
        }

        self.verifyAllTabs();

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
        const p = pathZ(&path_z, path) catch {
            std.debug.print("sketerm: path too long: {s}\n", .{path});
            return false;
        };
        const fp = c.fopen(p, "rb") orelse {
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
        connectManualPopoverClose(popover);
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
        /// Target pane, captured at popover build time. Resolving the
        /// focused pane at CLICK time silently fails: the popover's
        /// button holds the window focus by then, so focusedPane()
        /// returns null. Null for the new-tab flow (no target pane).
        pane: ?*Pane = null,
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

        presentPanePopover(pane, popover, box);
    }

    /// Right-click → "Apply Profile to Pane…" picker. Same popover
    /// shape as openProfilePicker, but the pick re-applies the
    /// chosen profile's settings to the focused LIVE pane instead of
    /// spawning a tab. "default" is always listed first.
    pub fn openApplyProfilePicker(self: *Window) void {
        const pane = self.focusedPane() orelse return;

        const popover = c.gtk_popover_new();
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        c.gtk_widget_set_margin_top(box, 6);
        c.gtk_widget_set_margin_bottom(box, 6);
        c.gtk_widget_set_margin_start(box, 6);
        c.gtk_widget_set_margin_end(box, 6);

        var names_buf: [1][]const u8 = .{"default"};
        addApplyProfileButtons(self, pane, @ptrCast(box), popover, &names_buf);
        var prof_names = std.ArrayList([]const u8).empty;
        defer prof_names.deinit(self.allocator);
        for (self.config.profiles.items) |p| {
            prof_names.append(self.allocator, p.name) catch break;
        }
        addApplyProfileButtons(self, pane, @ptrCast(box), popover, prof_names.items);

        presentPanePopover(pane, popover, box);
    }

    /// Show a picker popover over a pane. Wraps the content in a
    /// natural-size scroller and anchors at the pane's center:
    /// GTK4 silently popdowns an autohide popover whose MINIMUM size
    /// doesn't fit the space the compositor grants (same quirk the
    /// context menu works around in menu.zig) — anchored at the
    /// pane's bottom edge, any popover taller than the strip below
    /// the window vanished the frame it mapped.
    fn presentPanePopover(pane: *Pane, popover: *c.GtkWidget, content: ?*c.GtkWidget) void {
        const scroller = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
        c.gtk_scrolled_window_set_propagate_natural_width(@ptrCast(scroller), 1);
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), content);
        c.gtk_popover_set_child(@ptrCast(popover), scroller);
        c.gtk_widget_set_parent(popover, @ptrCast(pane.area));
        connectManualPopoverClose(popover);
        var rect = c.GdkRectangle{
            .x = @divTrunc(c.gtk_widget_get_width(@ptrCast(pane.area)), 2),
            .y = @divTrunc(c.gtk_widget_get_height(@ptrCast(pane.area)), 2),
            .width = 1,
            .height = 1,
        };
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        c.gtk_popover_popup(@ptrCast(popover));
    }

    fn addApplyProfileButtons(self: *Window, pane: *Pane, box: *c.GtkBox, popover: *c.GtkWidget, names: []const []const u8) void {
        for (names) |name| {
            const name_z = self.allocator.allocSentinel(u8, name.len, 0) catch continue;
            @memcpy(name_z, name);

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
                .pane = pane,
            };
            _ = c.g_signal_connect_data(
                btn,
                "clicked",
                @ptrCast(&onApplyProfilePicked),
                @ptrCast(ctx),
                @ptrCast(&freeProfileButtonCtx),
                c.G_CONNECT_DEFAULT,
            );
            c.gtk_box_append(box, btn);
        }
    }

    /// Re-apply a profile's settings bundle to a LIVE pane: records
    /// the pane's profile, pushes settings, and runs the font
    /// rebuild that applyPaneConfig (a spawn-path helper) leaves to
    /// the realize path. The shell/$TERM fields only affect future
    /// respawns — the running child keeps its environment.
    pub fn applyProfileToPane(self: *Window, pane: *Pane, profile_name: []const u8) void {
        const profile = self.findProfile(profile_name);
        pane.active_profile = if (profile) |p| p.name else null;

        const old_size = pane.font_size;
        const old_path = pane.font_path;
        const old_family = pane.font_family;
        const old_features = pane.font_features;
        const old_line_pad = pane.line_pad_px;

        self.applyPaneConfig(pane, .{ .profile = profile });

        const font_changed = pane.font_size != old_size or
            !eqOptStr(old_path, pane.font_path) or
            !eqOptStr(old_family, pane.font_family) or
            !eqOptStr(old_features, pane.font_features) or
            pane.line_pad_px != old_line_pad;
        if (font_changed) pane.refreshFont();
        c.gtk_widget_queue_resize(pane.widget());
        pane.terminal.screen.dirty = true;
        pane.cell_pass.markAllDirty();
        c.gtk_gl_area_queue_render(@ptrCast(pane.area));
    }

    const PresetButtonCtx = struct {
        window: *Window,
        preset_name: [:0]u8, // owned, freed by GDestroyNotify
        popover: *c.GtkWidget,
        allocator: std.mem.Allocator,
        /// Target pane, captured at popover build time (the popover
        /// button holds the window focus at click time, so resolving
        /// focusedPane() then returns null). Null = delete-only ctx.
        pane: ?*Pane = null,
    };

    /// Right-click → "Shader Preset…" picker. A popover anchored on
    /// the focused pane: a button per saved preset (applies it to
    /// that pane) plus a trash button to delete the preset file.
    /// With no presets, a placeholder explains where they come from.
    pub fn openShaderPresetPicker(self: *Window) void {
        const pane = self.focusedPane() orelse return;

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const names = shader_preset_mod.list(arena_state.allocator()) catch return;

        const popover = c.gtk_popover_new();
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        c.gtk_widget_set_margin_top(box, 6);
        c.gtk_widget_set_margin_bottom(box, 6);
        c.gtk_widget_set_margin_start(box, 6);
        c.gtk_widget_set_margin_end(box, 6);

        if (names.len == 0) {
            const lbl = c.gtk_label_new("No shader presets saved yet.\nConfigure Shader… has a \"Save as Preset\" button.");
            c.gtk_label_set_xalign(@ptrCast(lbl), 0);
            c.gtk_box_append(@ptrCast(box), lbl);
        } else {
            for (names) |name| {
                const name_z = self.allocator.allocSentinel(u8, name.len, 0) catch continue;
                @memcpy(name_z, name);

                const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
                const btn = c.gtk_button_new_with_label(name_z.ptr);
                c.gtk_widget_set_hexpand(btn, 1);
                c.gtk_widget_set_halign(btn, c.GTK_ALIGN_FILL);
                c.gtk_widget_add_css_class(btn, "flat");

                const apply_ctx = self.allocator.create(PresetButtonCtx) catch {
                    self.allocator.free(name_z);
                    continue;
                };
                apply_ctx.* = .{
                    .window = self,
                    .preset_name = name_z,
                    .popover = popover,
                    .allocator = self.allocator,
                    .pane = pane,
                };
                _ = c.g_signal_connect_data(
                    btn,
                    "clicked",
                    @ptrCast(&onPresetPicked),
                    @ptrCast(apply_ctx),
                    @ptrCast(&freePresetButtonCtx),
                    c.G_CONNECT_DEFAULT,
                );
                c.gtk_box_append(@ptrCast(row), btn);

                const del = c.gtk_button_new_from_icon_name("user-trash-symbolic");
                c.gtk_widget_add_css_class(del, "flat");
                c.gtk_widget_set_tooltip_text(del, "Delete preset");
                const del_name = self.allocator.allocSentinel(u8, name.len, 0) catch {
                    c.gtk_box_append(@ptrCast(box), row);
                    continue;
                };
                @memcpy(del_name, name);
                const del_ctx = self.allocator.create(PresetButtonCtx) catch {
                    self.allocator.free(del_name);
                    c.gtk_box_append(@ptrCast(box), row);
                    continue;
                };
                del_ctx.* = .{
                    .window = self,
                    .preset_name = del_name,
                    .popover = popover,
                    .allocator = self.allocator,
                };
                _ = c.g_signal_connect_data(
                    del,
                    "clicked",
                    @ptrCast(&onPresetDeleted),
                    @ptrCast(del_ctx),
                    @ptrCast(&freePresetButtonCtx),
                    c.G_CONNECT_DEFAULT,
                );
                c.gtk_box_append(@ptrCast(row), del);

                c.gtk_box_append(@ptrCast(box), row);
            }
        }

        presentPanePopover(pane, popover, box);
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
        connectManualPopoverClose(popover);

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

    const MuxRenameCtx = struct {
        window: *Window,
        pane: *Pane,
        popover: *c.GtkWidget,
        entry: *c.GtkWidget,
        allocator: std.mem.Allocator,
    };

    /// "Rename Session…" on a mux pane: popover entry pre-filled with
    /// the session name. Enter sends the rename to the daemon; the
    /// tab retitles only when the daemon's OK comes back.
    pub fn renameFocusedMuxSession(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        const remote = pane.terminal.remote orelse return;

        const popover = c.gtk_popover_new();
        const entry = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Session name");

        const z = self.allocator.allocSentinel(u8, remote.session.len, 0) catch null;
        if (z) |zz| {
            defer self.allocator.free(zz);
            @memcpy(zz, remote.session);
            c.gtk_editable_set_text(@ptrCast(entry), zz.ptr);
            c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
        }

        c.gtk_popover_set_child(@ptrCast(popover), entry);
        c.gtk_widget_set_parent(popover, @ptrCast(pane.area));
        connectManualPopoverClose(popover);
        const w = c.gtk_widget_get_width(@ptrCast(pane.area));
        const rect = c.GdkRectangle{
            .x = @divFloor(w, 2),
            .y = 1,
            .width = 1,
            .height = 1,
        };
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);

        const ctx = self.allocator.create(MuxRenameCtx) catch return;
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
            @ptrCast(&onMuxRenameActivate),
            @ptrCast(ctx),
            @ptrCast(&freeMuxRenameCtx),
            c.G_CONNECT_DEFAULT,
        );

        c.gtk_popover_popup(@ptrCast(popover));
        _ = c.gtk_widget_grab_focus(entry);
    }

    /// "Kill Session" on a mux pane: tell the daemon to tear the
    /// session down, then close the pane. The daemon's GONE broadcast
    /// covers any other client attached to the same session.
    pub fn killFocusedMuxSession(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        const remote = pane.terminal.remote orelse return;
        if (!remote.closed) {
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            if (std.json.Stringify.value(.{ .name = remote.session }, .{}, &aw.writer)) {
                remote.conn.sendFrame(.kill, aw.written()) catch {};
            } else |_| {}
        }
        self.closeFocusedPane();
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
        const base = self.config.profileSettings(pane.active_profile orelse "").font_size;
        if (pane.font_size == base) return;
        pane.setFontSize(base);
    }

    const ColorPair = struct { fg: [4]f32, bg: [4]f32 };

    /// Derive the effective default fg/bg for the Default settings.
    fn resolveDefaultColors(self: *const Window) ColorPair {
        return self.resolveColorsFor(&self.config.settings);
    }

    /// Derive the effective default fg/bg for a settings bundle.
    /// When auto_theme is on we follow AdwStyleManager's dark/light
    /// state so sketerm matches the system appearance. Otherwise
    /// honour the bundle's explicit colors. `background_opacity` is
    /// applied to bg.a after theme resolution so transparency works
    /// under both auto and manual themes.
    fn resolveColorsFor(self: *const Window, s: *const @import("../config.zig").ProfileSettings) ColorPair {
        var pair: ColorPair = if (!self.config.auto_theme) blk: {
            break :blk .{ .fg = s.default_fg, .bg = s.default_bg };
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

    pub fn focusedPane(self: *Window) ?*Pane {
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

        // Background layer: only re-decode when one of its keys
        // actually moved (image decode is not keystroke-cheap).
        if (!std.mem.eql(u8, old_cfg.background_image, self.config.background_image) or
            old_cfg.background_image_opacity != self.config.background_image_opacity or
            !std.mem.eql(f32, &old_cfg.background_gradient_from, &self.config.background_gradient_from) or
            !std.mem.eql(f32, &old_cfg.background_gradient_to, &self.config.background_gradient_to) or
            old_cfg.background_gradient_angle != self.config.background_gradient_angle)
        {
            self.refreshBgSource();
        }

        // Window-level custom shader source follows the Default
        // settings. Re-read the file only when its keys moved — but
        // ALWAYS re-point the param overrides, which live in the
        // config arena that gets freed when this function returns.
        if (!std.mem.eql(u8, old_cfg.settings.custom_shader, self.config.settings.custom_shader) or
            old_cfg.custom_shader_animation != self.config.custom_shader_animation)
        {
            self.refreshShaderSource();
        }
        self.shader_source.overrides = self.config.shader_params.items;

        // Push into every pane, resolving each pane's profile to its
        // settings bundle in the NEW config (deleted profiles degrade
        // to the Default settings).
        for (self.panes.items) |p| {
            const screen = p.terminal.screen;
            // The pane's old effective settings — old name slice and
            // old config arena both stay alive until function end.
            const old_s = old_cfg.profileSettings(p.active_profile orelse "");
            // Re-point active_profile at the new arena's copy (or
            // drop it if the profile no longer exists).
            if (p.active_profile) |pn| {
                p.active_profile = null;
                for (self.config.profiles.items) |*pr| {
                    if (std.mem.eql(u8, pr.name, pn)) {
                        p.active_profile = pr.name;
                        break;
                    }
                }
            }
            const s = self.config.profileSettings(p.active_profile orelse "");

            // Colors. resolveColorsFor applies auto-theme +
            // background_opacity so panes get the actual rendering
            // values, not the raw settings struct.
            const eff = self.resolveColorsFor(s);
            screen.default_fg = eff.fg;
            screen.default_bg = eff.bg;
            screen.configured_fg = eff.fg;
            screen.configured_bg = eff.bg;
            screen.notifyColorScheme(isDarkBg(eff.bg));
            screen.allow_clipboard_read = self.config.clipboard_read;
            screen.track_activity = self.config.track_tab_activity;
            // Renderer convention: alpha=0 means "use fg colour". We
            // map cursor_color_default → that sentinel.
            screen.cursor_color = if (s.cursor_color_default)
                .{ 0, 0, 0, 0 }
            else
                s.cursor_color;
            p.grid_pass.default_fg = eff.fg;
            p.grid_pass.default_bg = eff.bg;
            p.cell_pass.default_fg = eff.fg;
            p.cell_pass.default_bg = eff.bg;
            // Palette (16 ANSI colours). Entries 16..255 keep their
            // built-in 256-table values.
            if (resolvePalette(s)) |pal| {
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
            if (s.padding != old_s.padding) {
                p.grid_pass.pad = s.padding;
                p.cell_pass.pad = s.padding;
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
            p.grid_pass.min_contrast = self.config.minimum_contrast;
            p.cell_pass.min_contrast = self.config.minimum_contrast;
            // Behavior.
            screen.bracketed_paste = self.config.bracketed_paste;
            screen.modify_other_keys = self.config.modify_other_keys;
            screen.scrollback_capacity = s.scrollback;
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
            p.font_path = s.font_path;
            p.font_family = if (s.font_family.len > 0) s.font_family else null;
            p.font_features = if (s.font_features.len > 0) s.font_features else null;
            p.line_pad_px = s.line_pad_px;
            // Shader state: the overrides slice points into the
            // config arena (about to be freed) — re-point it
            // UNCONDITIONALLY (preset panes own their slice and skip
            // this), then re-resolve the settings shader for panes
            // without a sticky user pick.
            p.shader_default_source = &self.shader_source;
            if (!p.hasOwnShaderParams())
                p.shader_own.overrides = self.config.shader_params.items;
            if (!p.custom_shader_user and !p.shader_cleared) {
                _ = p.setCustomShader(
                    if (s.custom_shader.len > 0) s.custom_shader else null,
                    self.config.custom_shader_animation,
                    false,
                );
            } else if (p.custom_shader_user) {
                p.shader_own.animate = self.config.custom_shader_animation;
            }
            p.refreshShaderBinding();
            // Mouse / link / autohide flags on the Pane itself.
            p.copy_on_selection = self.config.copy_on_selection;
            p.clear_select_on_copy = self.config.clear_select_on_copy;
            p.disable_mouse_paste = self.config.disable_mouse_paste;
            p.disable_mousewheel_zoom = self.config.disable_mousewheel_zoom;
            p.link_single_click = self.config.link_single_click;
            p.mouse_autohide = self.config.mouse_autohide;
            p.middle_click_action = self.config.mouse_middle_click;
            p.right_click_action = self.config.mouse_right_click;
            // Per-pane titlebar visibility.
            p.setTitlebarVisible(self.config.show_titlebar);
            // Inactive-pane dimming.
            p.inactive_darken = self.config.inactive_darken;
            p.inactive_desaturate = self.config.inactive_desaturate;
            p.applyDim();
            // Font rebuilds, per pane against ITS settings bundle. A
            // size change takes the heavy atlas-rebuild path (and
            // resets any Ctrl± zoom, like before); same size with a
            // different file/family/features rebuilds explicitly
            // since setFontSize would early-return.
            if (s.font_size != old_s.font_size) {
                p.setFontSize(s.font_size);
            } else {
                const path_changed = !eqOptStr(old_s.font_path, s.font_path);
                const family_changed = !std.mem.eql(u8, old_s.font_family, s.font_family);
                const features_changed = !std.mem.eql(u8, old_s.font_features, s.font_features);
                const line_pad_changed = old_s.line_pad_px != s.line_pad_px;
                if (path_changed or family_changed or features_changed or line_pad_changed) {
                    p.refreshFont();
                }
            }
            // Repaint.
            screen.dirty = true;
            p.cell_pass.markAllDirty();
            c.gtk_gl_area_queue_render(@ptrCast(p.area));
        }

        // Refresh CSS provider so any title_*_* color changes take
        // effect immediately on the active/inactive classes.
        self.refreshTitlebarCss();

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
    fn appendOrInsertTab(self: *Window, child: *c.GtkWidget, tree_root: PaneTree.Node) *c.AdwTabPage {
        const page = blk: {
            if (self.config.new_tab_after_current) {
                const sel = c.adw_tab_view_get_selected_page(self.tab_view);
                if (sel != null) {
                    const idx = c.adw_tab_view_get_page_position(self.tab_view, sel);
                    if (c.adw_tab_view_insert(self.tab_view, child, idx + 1)) |p| break :blk p;
                }
            }
            break :blk c.adw_tab_view_append(self.tab_view, child).?;
        };
        // Stable id for remote-control addressing, stored on the
        // GObject (survives reorder; pages are never re-tagged).
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-id", @ptrFromInt(self.next_tab_id));
        self.next_tab_id += 1;
        self.attachTabTree(page, tree_root);
        return page;
    }

    /// Attach the pane-tree model to a tab page. Best-effort on OOM
    /// (queries fall back gracefully on a missing tree).
    fn attachTabTree(self: *Window, page: *c.AdwTabPage, root: PaneTree.Node) void {
        const t = self.allocator.create(PaneTree) catch return;
        t.* = .{ .allocator = self.allocator, .root = root };
        c.g_object_set_data(@ptrCast(@alignCast(page)), TAB_TREE_KEY, @ptrCast(t));
    }

    pub fn tabTreeOf(page: *c.AdwTabPage) ?*PaneTree {
        const p = c.g_object_get_data(@ptrCast(@alignCast(page)), TAB_TREE_KEY) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    /// Free a page's tree model — call ONLY on true tab teardown
    /// (close/shutdown), never on cross-window transfer (the qdata
    /// must travel with the page).
    fn freeTabTree(self: *Window, page: *c.AdwTabPage) void {
        if (tabTreeOf(page)) |t| {
            t.deinit();
            self.allocator.destroy(t);
            c.g_object_set_data(@ptrCast(@alignCast(page)), TAB_TREE_KEY, null);
        }
    }

    // ── Remote control (sketerm cli) ─────────────────────────────

    fn allocPaneId(self: *Window) u32 {
        const id = self.next_pane_id;
        self.next_pane_id += 1;
        return id;
    }

    /// Park an interactive OSC 99 notification so its desktop
    /// activation can find the pane + identifier later. Bounded:
    /// the oldest slot is evicted at 32. Returns the slot token.
    fn registerNotifySlot(self: *Window, pane: *Pane, ev: Screen.NotificationEvent) ?u32 {
        const id_copy = self.allocator.dupe(u8, ev.id) catch return null;
        if (self.notify_slots.items.len >= 32) {
            const old = self.notify_slots.orderedRemove(0);
            self.allocator.free(old.id);
        }
        const token = self.next_notify_token;
        self.next_notify_token +%= 1;
        if (self.next_notify_token == 0) self.next_notify_token = 1;
        self.notify_slots.append(self.allocator, .{
            .token = token,
            .pane = pane,
            .id = id_copy,
            .want_report = ev.want_report,
            .want_focus = ev.want_focus,
        }) catch {
            self.allocator.free(id_copy);
            return null;
        };
        return token;
    }

    fn dropNotifySlotsForPane(self: *Window, pane: *Pane) void {
        var i: usize = 0;
        while (i < self.notify_slots.items.len) {
            if (self.notify_slots.items[i].pane == pane) {
                const slot = self.notify_slots.orderedRemove(i);
                self.allocator.free(slot.id);
            } else {
                i += 1;
            }
        }
    }

    fn tabPageId(page: *c.AdwTabPage) u32 {
        return @intCast(@intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-tab-id")));
    }

    /// Resolve a pane address: explicit id, else the focused pane,
    /// else the selected tab's first pane, else the first pane.
    fn paneById(self: *Window, id_opt: ?u32) ?*Pane {
        if (id_opt) |id| {
            for (self.panes.items) |p| if (p.id == id) return p;
            return null;
        }
        if (self.focusedPane()) |p| return p;
        const sel = c.adw_tab_view_get_selected_page(self.tab_view);
        if (sel != null) {
            if (c.adw_tab_page_get_child(sel)) |child| {
                for (self.panes.items) |p| {
                    if (widgetIsAncestor(@ptrCast(child), p.widget())) return p;
                }
            }
        }
        if (self.panes.items.len > 0) return self.panes.items[0];
        return null;
    }

    fn tabPageById(self: *Window, id_opt: ?u32) ?*c.AdwTabPage {
        if (id_opt) |id| {
            const n = c.adw_tab_view_get_n_pages(self.tab_view);
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
                if (tabPageId(page) == id) return page;
            }
            return null;
        }
        return c.adw_tab_view_get_selected_page(self.tab_view);
    }

    // ── Durable tabs (sketerm-mux) ───────────────────────────────

    /// Connect to the mux daemon — local (spawning it if absent) or
    /// on an SSH host (`ssh <host> sketerm-mux --proxy`).
    fn muxConnect(self: *Window, host: ?[]const u8) !@import("../mux/client.zig").Conn {
        const mux_client = @import("../mux/client.zig");
        if (host) |h| {
            // "udp:host" selects the mosh-style encrypted UDP
            // transport (ssh bootstrap, then roaming datagrams).
            if (std.mem.startsWith(u8, h, "udp:")) {
                const range: ?[]const u8 = if (self.config.mux_udp_port_range.len > 0)
                    self.config.mux_udp_port_range
                else
                    null;
                return mux_client.Conn.connectUdp(self.allocator, h[4..], range);
            }
            return mux_client.Conn.connectSsh(self.allocator, h);
        }
        return mux_client.Conn.connectLocalAutostart(self.allocator);
    }

    /// Spawn a shell session in the daemon (local or `host`'s) and
    /// attach it as a tab.
    pub fn newDurableTab(self: *Window, host: ?[]const u8) !void {
        try self.newDurableSession(host, null);
    }

    /// Spawn a fresh session on the daemon and attach it — into a new
    /// tab, or into `takeover`'s slot when the request came from a
    /// `sketerm mux` CLI running inside that pane.
    pub fn newDurableSession(self: *Window, host: ?[]const u8, takeover: ?*Pane) !void {
        var name_buf: [64]u8 = undefined;
        // Unique-enough name: pid + monotonic counter.
        self.tab_counter += 1;
        const name = std.fmt.bufPrint(&name_buf, "s{d}-{d}", .{ c.getpid(), self.tab_counter }) catch "s0";

        var conn = try self.muxConnect(host);
        {
            // This errdefer covers ONLY the spawn phase; once the
            // block exits cleanly, attachMuxTab owns the conn (and
            // deinits it on its own failures).
            errdefer conn.deinit();
            // Local spawns honour the configured shell + cwd; remote
            // spawns send empty argv = "the remote's login shell"
            // and no cwd (local paths mean nothing over there).
            const argv: []const []const u8 = if (host != null) &.{} else blk: {
                const sh: []const u8 = if (self.config.settings.shell) |s| s else sh2: {
                    const env = c.getenv("SHELL");
                    break :sh2 if (env != null) std.mem.span(env) else "/bin/sh";
                };
                break :blk &.{sh};
            };
            try conn.sendJson(.spawn, .{
                .name = name,
                .argv = argv,
                .cwd = if (host != null) null else self.focusedPaneCwd(),
                .rows = @as(u16, 24),
                .cols = @as(u16, 80),
            });
            (try conn.recvExpect(&.{.ok})).deinit(self.allocator);
        }
        try self.attachMux(conn, name, host, takeover);
    }

    pub fn attachMuxTab(self: *Window, conn_in: @import("../mux/client.zig").Conn, name: []const u8, host: ?[]const u8) !void {
        try self.attachMux(conn_in, name, host, null);
    }

    /// Attach `conn` to session `name` — wrapped in a new tab, or
    /// replacing `takeover`'s spot in its split tree (the pane the
    /// `sketerm mux` CLI was invoked from; its shell — including that
    /// CLI — is torn down once the remote pane is in place).
    /// Takes ownership of `conn` on success AND failure.
    /// Build a remote (mux) pane from an attach snapshot: Terminal +
    /// Pane, sinks wired, config pushed, listed, images replayed —
    /// but NO tab page; the caller decides where the widget goes.
    /// Takes ownership of `conn` on success and failure.
    fn makeRemotePaneFromSnap(
        self: *Window,
        conn_in: @import("../mux/client.zig").Conn,
        name: []const u8,
        host: ?[]const u8,
        snap_payload: []const u8,
    ) !*Pane {
        var conn = conn_in;
        const term = blk: {
            errdefer conn.deinit();
            break :blk try Terminal.initRemote(self.allocator, conn, name, snap_payload);
        };
        errdefer term.deinit();
        term.debug_to_stderr = self.debug_events;
        // Remember the transport host so session renames can rebuild
        // the "⌁ name @ host" tab title (and layout save records it).
        if (host) |h| {
            term.remote.?.host = self.allocator.dupe(u8, h) catch null;
        }

        const pane = try self.makePane(term);
        pane.id = self.allocPaneId();
        errdefer pane.deinit();
        self.wirePaneSinks(pane);
        // Fonts, colors, padding, palette — same push every other
        // pane-creation path gets. Must happen before the widget
        // enters the tree (realize builds the atlas from pane state).
        self.applyPaneConfig(pane, .{});
        try self.panes.append(self.allocator, pane);
        try self.terminals.append(self.allocator, term);
        // Pane sinks are wired — push snapshot-restored image
        // placements into the ImageStore.
        term.replayRetainedImages();
        return pane;
    }

    /// Layout restore for a durable mux pane: attach when the
    /// session still exists, otherwise recreate it under the SAME
    /// name (daemon restarted / server rebooted) and attach that —
    /// "resume or create". Returns the placed-nowhere pane.
    fn restoreMuxPane(self: *Window, spec: layout_mod.PaneSpec) !*Pane {
        const host: ?[]const u8 = if (spec.mux_host.len > 0) spec.mux_host else null;
        var conn = try self.muxConnect(host);

        const Owned = @TypeOf(try conn.recvFrame());
        var snap: Owned = undefined;
        {
            errdefer conn.deinit();
            try conn.sendJson(.attach, .{ .name = spec.mux_session });
            const reply = try conn.recvExpect(&.{ .snapshot, .err });
            if (reply.ftype == .snapshot) {
                snap = reply;
            } else {
                reply.deinit(self.allocator);
                // Session gone — recreate. Local spawns honour the
                // saved cwd + configured shell; remote spawns send
                // empty argv = the remote's login shell.
                const argv: []const []const u8 = if (host != null) &.{} else blk: {
                    const sh: []const u8 = if (self.config.settings.shell) |s| s else sh2: {
                        const env = c.getenv("SHELL");
                        break :sh2 if (env != null) std.mem.span(env) else "/bin/sh";
                    };
                    break :blk &.{sh};
                };
                try conn.sendJson(.spawn, .{
                    .name = spec.mux_session,
                    .argv = argv,
                    .cwd = if (host != null or spec.cwd.len == 0) null else spec.cwd,
                    .rows = @as(u16, 24),
                    .cols = @as(u16, 80),
                });
                (try conn.recvExpect(&.{.ok})).deinit(self.allocator);
                try conn.sendJson(.attach, .{ .name = spec.mux_session });
                snap = try conn.recvExpect(&.{.snapshot});
            }
        }
        defer snap.deinit(self.allocator);
        return self.makeRemotePaneFromSnap(conn, spec.mux_session, host, snap.payload);
    }

    /// Put `pane` into `old`'s slot — tree model and widget tree in
    /// the same function — then unlist `old` (its teardown is
    /// deferred past GTK's destroy chain). Shared by the mux takeover
    /// and the detach-to-local-shell path.
    fn swapPaneInPlace(self: *Window, old: *Pane, pane: *Pane) !*c.AdwTabPage {
        const page = tabPageForPane(self, old) orelse return error.PaneHasNoTab;
        // Mirror in the tree model: the new pane takes the old
        // leaf's slot in place.
        if (tabTreeOf(page)) |t| {
            t.replaceLeaf(old, pane) catch
                std.debug.print("sketerm: tree model takeover desync (leaf not found)\n", .{});
        }
        const old_w = old.widget();
        const parent = c.gtk_widget_get_parent(old_w) orelse return error.PaneHasNoTab;
        const is_paned = c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(parent)),
            c.gtk_paned_get_type(),
        ) != 0;
        // Drop the new pane into the old one's slot. Replacing /
        // removing the child destroys old_w's widget subtree;
        // Zig-side teardown is deferred below.
        if (is_paned) {
            if (c.gtk_paned_get_start_child(@ptrCast(parent)) == old_w) {
                c.gtk_paned_set_start_child(@ptrCast(parent), pane.widget());
            } else {
                c.gtk_paned_set_end_child(@ptrCast(parent), pane.widget());
            }
        } else {
            c.gtk_box_remove(@ptrCast(parent), old_w);
            c.gtk_box_append(@ptrCast(parent), pane.widget());
        }

        self.unlistPane(old);
        return page;
    }

    /// Detach a remote (mux) pane back into a fresh local shell in
    /// the same slot — the session keeps running on the daemon; the
    /// pane does NOT close (tmux semantics: detach lands you in a
    /// shell). Also the landing path when a remote session ends or
    /// the connection drops. Falls back to closing the pane only if
    /// the local shell spawn itself fails.
    fn detachPaneToShell(self: *Window, pane: *Pane) void {
        if (pane.terminal.remote == null) return;
        const fresh = self.spawnShellPaneOpts(null, null) catch {
            std.debug.print("sketerm: detach: local shell spawn failed — closing pane\n", .{});
            self.closePane(pane);
            return;
        };
        const page = self.swapPaneInPlace(pane, fresh) catch {
            // No tab slot to land in (mid-teardown) — drop the fresh
            // pane again and close the remote one.
            self.unlistPane(fresh);
            self.closePane(pane);
            return;
        };
        // The "⌁ session @ host" title is stale now; hand the tab
        // back to OSC tracking unless the user renamed it.
        if (c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-title-locked") == null) {
            var num_buf: [32]u8 = undefined;
            self.tab_counter += 1;
            const t = std.fmt.bufPrintZ(&num_buf, "Tab {d}", .{self.tab_counter}) catch "shell";
            c.adw_tab_page_set_title(page, t.ptr);
            c.adw_tab_page_set_tooltip(page, t.ptr);
        }
        _ = c.gtk_widget_grab_focus(@ptrCast(fresh.area));
    }

    pub fn attachMux(self: *Window, conn_in: @import("../mux/client.zig").Conn, name: []const u8, host: ?[]const u8, takeover: ?*Pane) !void {
        var conn = conn_in;

        const snap = blk: {
            errdefer conn.deinit();
            try conn.sendJson(.attach, .{ .name = name });
            break :blk try conn.recvExpect(&.{.snapshot});
        };
        defer snap.deinit(self.allocator);
        const pane = try self.makeRemotePaneFromSnap(conn, name, host, snap.payload);

        var title_buf: [160:0]u8 = undefined;
        const title_z = if (host) |h|
            std.fmt.bufPrintZ(&title_buf, "⌁ {s} @ {s}", .{ name, h }) catch "mux"
        else
            std.fmt.bufPrintZ(&title_buf, "⌁ {s}", .{name}) catch "mux";

        const page = if (takeover) |old|
            try self.swapPaneInPlace(old, pane)
        else blk: {
            const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
            c.gtk_widget_set_hexpand(wrapper, 1);
            c.gtk_widget_set_vexpand(wrapper, 1);
            c.gtk_box_append(@ptrCast(wrapper), pane.widget());
            break :blk self.appendOrInsertTab(wrapper, .{ .leaf = pane });
        };
        c.adw_tab_page_set_title(page, title_z.ptr);
        c.adw_tab_page_set_tooltip(page, title_z.ptr);
        c.adw_tab_view_set_selected_page(self.tab_view, page);
        _ = c.gtk_widget_grab_focus(@ptrCast(pane.area));
    }

    // ── Background layer (image / gradient) ─────────────────────

    /// Locate the shell-integration script directory and cache the
    /// per-shell script + shim paths. Resolution: env override →
    /// installed share dir next to the exe → repo data/ (dev tree)
    /// → /usr/share. Missing dir = feature silently off.
    fn resolveShellIntegration(self: *Window) void {
        const ally = self.allocator;
        var base_buf: [4096]u8 = undefined;
        const base: []const u8 = blk: {
            if (@import("../util/profile.zig").getenv("SKETERM_SHELL_INTEGRATION_DIR")) |env| break :blk env;
            var exe_buf: [4096]u8 = undefined;
            if (@import("../util/platform.zig").exePath(&exe_buf)) |exe_path| {
                const exe_dir = std.fs.path.dirname(exe_path) orelse "/usr/bin";
                const candidates = [_][]const u8{
                    "/../share/sketerm/shell-integration",
                    "/../../data/shell-integration",
                };
                for (candidates) |suffix| {
                    const cand = std.fmt.bufPrintZ(&base_buf, "{s}{s}/sketerm.zsh", .{ exe_dir, suffix }) catch continue;
                    if (c.access(cand.ptr, c.R_OK) == 0) {
                        break :blk base_buf[0 .. exe_dir.len + suffix.len];
                    }
                }
            }
            const sys = "/usr/share/sketerm/shell-integration";
            const sys_probe = std.fmt.bufPrintZ(&base_buf, "{s}/sketerm.zsh", .{sys}) catch return;
            if (c.access(sys_probe.ptr, c.R_OK) == 0) break :blk sys;
            return;
        };
        self.si_zsh_script = std.fmt.allocPrintSentinel(ally, "{s}/sketerm.zsh", .{base}, 0) catch null;
        self.si_fish_script = std.fmt.allocPrintSentinel(ally, "{s}/sketerm.fish", .{base}, 0) catch null;
        self.si_zsh_shim = std.fmt.allocPrintSentinel(ally, "{s}/zsh", .{base}, 0) catch null;
        self.si_fish_shim = std.fmt.allocPrintSentinel(ally, "{s}/fish-xdg", .{base}, 0) catch null;
    }

    /// Pick the injection setup for the program being spawned, or
    /// null (no injection) for shells we don't auto-integrate.
    fn shellIntegrationFor(self: *const Window, argv0: [*:0]const u8) ?@import("../pty.zig").ShellIntegration {
        if (!self.config.shell_integration) return null;
        const prog = std.mem.span(argv0);
        const base = std.fs.path.basename(prog);
        if (std.mem.eql(u8, base, "zsh")) {
            const script = self.si_zsh_script orelse return null;
            const shim = self.si_zsh_shim orelse return null;
            return .{ .kind = .zsh, .script = script.ptr, .shim_dir = shim.ptr };
        }
        if (std.mem.eql(u8, base, "fish")) {
            const script = self.si_fish_script orelse return null;
            const shim = self.si_fish_shim orelse return null;
            return .{ .kind = .fish, .script = script.ptr, .shim_dir = shim.ptr };
        }
        return null;
    }

    /// Rebuild bg_source from config: decode the image (if any) or
    /// arm the gradient. Frees the previous stbi allocation. Call on
    /// startup and whenever a background_* key may have changed.
    fn refreshBgSource(self: *Window) void {
        if (self.bg_source.pixels) |px| {
            c.stbi_image_free(px);
            self.bg_source.pixels = null;
        }
        self.bg_source.mode = .none;

        const cfg = &self.config;
        if (cfg.background_image.len > 0) blk: {
            var path_z_buf: [4096]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{cfg.background_image}) catch break :blk;
            var w: c_int = 0;
            var h: c_int = 0;
            var n: c_int = 0;
            const px = c.stbi_load(path_z.ptr, &w, &h, &n, 4);
            if (px == null) {
                std.debug.print("sketerm: background_image load failed: {s}\n", .{cfg.background_image});
                break :blk;
            }
            self.bg_source.pixels = px;
            self.bg_source.w = w;
            self.bg_source.h = h;
            self.bg_source.opacity = cfg.background_image_opacity;
            self.bg_source.mode = .image;
        }
        if (self.bg_source.mode == .none and
            cfg.background_gradient_from[3] > 0 and cfg.background_gradient_to[3] > 0)
        {
            self.bg_source.color0 = cfg.background_gradient_from;
            self.bg_source.color1 = cfg.background_gradient_to;
            self.bg_source.angle_deg = cfg.background_gradient_angle;
            self.bg_source.opacity = 1.0;
            self.bg_source.mode = .gradient;
        }
        self.bg_source.generation +%= 1;
    }

    /// (Re-)read the custom_shader file into shader_source. Call on
    /// startup and whenever a custom_shader* key may have changed.
    fn refreshShaderSource(self: *Window) void {
        if (self.shader_source.src) |s| {
            self.allocator.free(s);
            self.shader_source.src = null;
        }
        if (self.shader_source.dir) |d| {
            self.allocator.free(d);
            self.shader_source.dir = null;
        }
        self.shader_source.animate = self.config.custom_shader_animation;
        self.shader_source.overrides = self.config.shader_params.items;

        const path = self.config.settings.custom_shader;
        if (path.len > 0) {
            // Shader-relative //@texture paths resolve against this.
            if (std.fs.path.dirname(path)) |d| {
                self.shader_source.dir = self.allocator.dupe(u8, d) catch null;
            }
        }
        if (path.len > 0) blk: {
            var path_z: [4096]u8 = undefined;
            if (path.len >= path_z.len) break :blk;
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            const fp = c.fopen(@ptrCast(&path_z), "rb") orelse {
                std.debug.print("sketerm: custom_shader not readable: {s}\n", .{path});
                break :blk;
            };
            defer _ = c.fclose(fp);
            const max_bytes: usize = 256 * 1024;
            const buf = self.allocator.alloc(u8, max_bytes) catch break :blk;
            const n = c.fread(buf.ptr, 1, buf.len, fp);
            if (n == 0) {
                self.allocator.free(buf);
                break :blk;
            }
            self.shader_source.src = self.allocator.realloc(buf, n) catch buf[0..n];
        }
        self.shader_source.generation +%= 1;
    }

    // ── Per-tab colours ──────────────────────────────────────────

    /// Wrap a 64×64 RGBA buffer in a GdkTexture for tab iconography
    /// (colour swatch, progress ring). Caller unrefs.
    fn iconTexture64(px: *const [64 * 64 * 4]u8) ?*c.GdkTexture {
        const bytes = c.g_bytes_new(px, px.len);
        defer c.g_bytes_unref(bytes);
        return c.gdk_memory_texture_new(64, 64, c.GDK_MEMORY_R8G8B8A8, bytes, 64 * 4);
    }

    /// Set or clear a tab's colour: a round swatch as the
    /// page icon, plus the packed value on the GObject so layout
    /// save and `cli list` can read it back. Marker bit 1<<24
    /// distinguishes "black" from "unset".
    pub fn setTabColor(self: *Window, page: *c.AdwTabPage, rgb: ?[3]u8) void {
        _ = self;
        if (rgb) |col| {
            // 4× supersampled disc with a soft rim, like the progress
            // ring — a raw 16px circle renders visibly jagged.
            const S = 64;
            const ctr = (@as(f32, S) - 1.0) / 2.0;
            var px: [S * S * 4]u8 = undefined;
            for (0..S) |yy| {
                for (0..S) |xx| {
                    const dx = @as(f32, @floatFromInt(xx)) - ctr;
                    const dy = @as(f32, @floatFromInt(yy)) - ctr;
                    const r = @sqrt(dx * dx + dy * dy);
                    const cov = std.math.clamp(28.0 - r + 0.5, 0.0, 1.0);
                    const o = (yy * S + xx) * 4;
                    px[o + 0] = col[0];
                    px[o + 1] = col[1];
                    px[o + 2] = col[2];
                    px[o + 3] = @intFromFloat(255.0 * cov);
                }
            }
            const tex = iconTexture64(&px) orelse return;
            c.adw_tab_page_set_icon(page, @ptrCast(@alignCast(tex)));
            c.g_object_unref(tex);
            const packed_val: usize = (1 << 24) |
                (@as(usize, col[0]) << 16) | (@as(usize, col[1]) << 8) | col[2];
            c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-color", @ptrFromInt(packed_val));
        } else {
            c.adw_tab_page_set_icon(page, null);
            c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-color", null);
        }
    }

    /// Tab progress ring (OSC 9;4), drawn into the page's INDICATOR
    /// icon so it coexists with the tab-colour swatch (which owns the
    /// regular icon). State 0 clears. The packed value also lands on
    /// the GObject (marker 1<<24 | state<<8 | percent) so the taskbar
    /// aggregate can walk pages without touching panes.
    pub fn setTabProgress(self: *Window, page: ?*c.AdwTabPage, state: u8, percent: u8) void {
        _ = self;
        if (state == 0) {
            c.adw_tab_page_set_indicator_icon(page, null);
            c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-progress", null);
            return;
        }
        const color: [3]u8 = switch (state) {
            2 => .{ 0xE0, 0x1B, 0x24 }, // error: red
            4 => .{ 0xF5, 0xC2, 0x11 }, // paused: amber
            else => .{ 0x35, 0x84, 0xE4 }, // normal/indeterminate: blue
        };
        // Indeterminate has no meaningful percent; a 3/4 ring reads
        // as "busy" without pretending to know how far along.
        const turn = if (state == 3)
            0.75 * std.math.tau
        else
            @as(f32, @floatFromInt(percent)) / 100.0 * std.math.tau;
        // Rendered at 4× the display size with soft edges; GTK's
        // downscale does the rest. Drawing at 16px directly gives a
        // visibly lumpy ring.
        const S = 64;
        const ctr = (@as(f32, S) - 1.0) / 2.0;
        const r_out = 30.0;
        const r_in = 18.0;
        var px: [S * S * 4]u8 = undefined;
        for (0..S) |yy| {
            for (0..S) |xx| {
                const dx = @as(f32, @floatFromInt(xx)) - ctr;
                const dy = @as(f32, @floatFromInt(yy)) - ctr;
                const r = @sqrt(dx * dx + dy * dy);
                const o = (yy * S + xx) * 4;
                px[o + 0] = color[0];
                px[o + 1] = color[1];
                px[o + 2] = color[2];
                // Radial coverage: 1 inside the annulus, fading over
                // ~1px at both rims.
                const cov = std.math.clamp(@min(r_out - r, r - r_in) + 0.5, 0.0, 1.0);
                // Angle from 12 o'clock, clockwise. The unfilled
                // remainder stays as a faint track; the arc tip gets
                // a ~1px angular feather (scaled by radius so the
                // feather width is constant in pixels).
                var ang = std.math.atan2(dx, -dy);
                if (ang < 0) ang += std.math.tau;
                const fill = std.math.clamp((turn - ang) * @max(r, 1.0) + 0.5, 0.0, 1.0);
                const a = (56.0 + fill * (255.0 - 56.0)) * cov;
                px[o + 3] = @intFromFloat(a);
            }
        }
        const tex = iconTexture64(&px) orelse return;
        c.adw_tab_page_set_indicator_icon(page, @ptrCast(@alignCast(tex)));
        c.g_object_unref(tex);
        const packed_val: usize = (1 << 24) | (@as(usize, state) << 8) | percent;
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-progress", @ptrFromInt(packed_val));
    }

    /// Aggregate every tab's progress into one window-level value and
    /// publish it over the Unity LauncherEntry D-Bus signal — KDE's
    /// task manager and most docks fill the taskbar button with it.
    /// Mean percent across active tabs (indeterminate counts as 50);
    /// any error state raises the urgent flag. Deduplicated so OSC
    /// floods don't spam the bus.
    pub fn updateTaskbarProgress(self: *Window) void {
        var total: u32 = 0;
        var count: u32 = 0;
        var urgent = false;
        const n = c.adw_tab_view_get_n_pages(self.tab_view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
            if (page == null) continue;
            const v = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-tab-progress"));
            if (v & (1 << 24) == 0) continue;
            const state: u8 = @truncate(v >> 8);
            total += if (state == 3) 50 else @as(u8, @truncate(v));
            count += 1;
            if (state == 2) urgent = true;
        }
        const visible = count != 0;
        const pct: u32 = if (visible) total / count else 0;
        const packed_sig: u32 = (@as(u32, @intFromBool(visible)) << 16) |
            (@as(u32, @intFromBool(urgent)) << 8) | pct;
        if (packed_sig == self.taskbar_sent) return;
        self.taskbar_sent = packed_sig;

        const app = c.gtk_window_get_application(@ptrCast(self.app_window));
        if (app == null) return;
        const conn = c.g_application_get_dbus_connection(@ptrCast(app));
        if (conn == null) return;
        const dict_type = c.g_variant_type_new("a{sv}");
        defer c.g_variant_type_free(dict_type);
        var builder: c.GVariantBuilder = undefined;
        c.g_variant_builder_init(&builder, dict_type);
        c.g_variant_builder_add(&builder, "{sv}", "progress", c.g_variant_new_double(@as(f64, @floatFromInt(pct)) / 100.0));
        c.g_variant_builder_add(&builder, "{sv}", "progress-visible", c.g_variant_new_boolean(@intFromBool(visible)));
        c.g_variant_builder_add(&builder, "{sv}", "urgent", c.g_variant_new_boolean(@intFromBool(urgent)));
        _ = c.g_dbus_connection_emit_signal(
            conn,
            null,
            "/dev/sker/sketerm/launcherentry",
            "com.canonical.Unity.LauncherEntry",
            "Update",
            c.g_variant_new("(sa{sv})", "application://dev.sker.sketerm.desktop", &builder),
            null,
        );
    }

    fn tabColorOf(page: *c.AdwTabPage) ?[3]u8 {
        const v = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-tab-color"));
        if (v & (1 << 24) == 0) return null;
        return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
    }

    fn parseHexRGB(s: []const u8) ?[3]u8 {
        const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
        if (hex.len != 6) return null;
        const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
        return .{ r, g, b };
    }

    const TabColorCtx = struct {
        allocator: std.mem.Allocator,
        win: *Window,
        page: *c.AdwTabPage,
    };

    /// "Tab Colour…" menu entry: GtkColorDialog on the selected tab.
    /// Picking a fully-transparent colour (alpha ≈ 0) clears it.
    fn chooseTabColor(self: *Window) void {
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
        const ctx = self.allocator.create(TabColorCtx) catch return;
        // Ref the page: the tab may be closed while the dialog is up.
        _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(page)));
        ctx.* = .{ .allocator = self.allocator, .win = self, .page = page };
        const dialog = c.gtk_color_dialog_new();
        c.gtk_color_dialog_set_with_alpha(dialog, 1);
        const initial: c.GdkRGBA = if (tabColorOf(page)) |col| .{
            .red = @as(f32, @floatFromInt(col[0])) / 255.0,
            .green = @as(f32, @floatFromInt(col[1])) / 255.0,
            .blue = @as(f32, @floatFromInt(col[2])) / 255.0,
            .alpha = 1.0,
        } else .{ .red = 0.8, .green = 0.2, .blue = 0.2, .alpha = 1.0 };
        c.gtk_color_dialog_choose_rgba(dialog, @ptrCast(self.app_window), &initial, null, @ptrCast(&onTabColorChosen), @ptrCast(ctx));
    }

    fn onTabColorChosen(source: ?*c.GObject, res: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(TabColorCtx, user);
        const dialog: ?*c.GtkColorDialog = @ptrCast(@alignCast(source));
        const rgba = c.gtk_color_dialog_choose_rgba_finish(dialog, res, null);
        if (rgba != null) {
            // Only apply if the page is still alive in the view.
            if (ctx.win.pageStillOpen(ctx.page)) {
                if (rgba.*.alpha < 0.01) {
                    ctx.win.setTabColor(ctx.page, null);
                } else {
                    ctx.win.setTabColor(ctx.page, .{
                        @intFromFloat(std.math.clamp(rgba.*.red, 0.0, 1.0) * 255.0),
                        @intFromFloat(std.math.clamp(rgba.*.green, 0.0, 1.0) * 255.0),
                        @intFromFloat(std.math.clamp(rgba.*.blue, 0.0, 1.0) * 255.0),
                    });
                }
            }
            c.gdk_rgba_free(rgba);
        }
        c.g_object_unref(dialog);
        c.g_object_unref(@as(?*anyopaque, @ptrCast(ctx.page)));
        ctx.allocator.destroy(ctx);
    }

    fn pageStillOpen(self: *Window, page: *c.AdwTabPage) bool {
        const n = c.adw_tab_view_get_n_pages(self.tab_view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            if (c.adw_tab_view_get_nth_page(self.tab_view, i) == page) return true;
        }
        return false;
    }

    fn ipcDispatchTrampoline(ctx: *anyopaque, req: ipc_protocol.Request, out: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        self.ipcDispatch(req, out, allocator) catch {
            out.clearRetainingCapacity();
            ipc_protocol.writeErr(out, allocator, "internal error") catch {};
        };
    }

    fn ipcDispatch(self: *Window, req: ipc_protocol.Request, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        const eql = std.mem.eql;
        if (eql(u8, req.cmd, "list")) {
            try self.ipcList(out, allocator);
        } else if (eql(u8, req.cmd, "send-text")) {
            const data = req.data orelse return ipc_protocol.writeErr(out, allocator, "send-text requires data");
            const pane = self.paneById(req.pane) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
            if (req.paste)
                clipboard.pasteText(pane.terminal, data)
            else
                pane.terminal.writeUserInput(data);
            try ipc_protocol.writeOk(out, allocator, null, {});
        } else if (eql(u8, req.cmd, "get-text")) {
            const pane = self.paneById(req.pane) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
            const screen = pane.terminal.screen;
            const text = if (req.scrollback > 0)
                try screen.extractScrollback(allocator)
            else
                try screen.extractScreen(allocator);
            defer allocator.free(text);
            try ipc_protocol.writeOk(out, allocator, "text", text);
        } else if (eql(u8, req.cmd, "new-tab")) {
            var title_buf: [256:0]u8 = undefined;
            const title_z: ?[*:0]const u8 = if (req.title) |t| blk: {
                const s = std.fmt.bufPrintZ(&title_buf, "{s}", .{t}) catch break :blk null;
                break :blk s.ptr;
            } else null;
            if (req.cwd) |cwd| {
                var num_buf: [32]u8 = undefined;
                const t: [*:0]const u8 = title_z orelse tdef: {
                    self.tab_counter += 1;
                    const s = std.fmt.bufPrintZ(&num_buf, "Tab {d}", .{self.tab_counter}) catch "shell";
                    break :tdef s.ptr;
                };
                try self.addTabWithProfile(t, cwd, null);
            } else {
                try self.newShellTab(title_z);
            }
            try ipc_protocol.writeOk(out, allocator, "created", .{
                .tab = self.next_tab_id - 1,
                .pane = self.next_pane_id - 1,
            });
        } else if (eql(u8, req.cmd, "split")) {
            const pane = self.paneById(req.pane) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
            _ = c.gtk_widget_grab_focus(@ptrCast(pane.area));
            const dir = req.direction orelse "h";
            const orient: c_uint = if (eql(u8, dir, "v"))
                @intCast(c.GTK_ORIENTATION_VERTICAL)
            else
                @intCast(c.GTK_ORIENTATION_HORIZONTAL);
            try self.splitFocused(orient);
            try ipc_protocol.writeOk(out, allocator, "created", .{
                .pane = self.next_pane_id - 1,
            });
        } else if (eql(u8, req.cmd, "focus")) {
            if (req.pane != null) {
                const pane = self.paneById(req.pane) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
                if (tabPageForPane(self, pane)) |page| c.adw_tab_view_set_selected_page(self.tab_view, page);
                _ = c.gtk_widget_grab_focus(@ptrCast(pane.area));
                try ipc_protocol.writeOk(out, allocator, null, {});
            } else if (req.tab != null) {
                const page = self.tabPageById(req.tab) orelse return ipc_protocol.writeErr(out, allocator, "no such tab");
                c.adw_tab_view_set_selected_page(self.tab_view, page);
                try ipc_protocol.writeOk(out, allocator, null, {});
            } else {
                try ipc_protocol.writeErr(out, allocator, "focus requires pane or tab");
            }
        } else if (eql(u8, req.cmd, "close-pane")) {
            const pane = self.paneById(req.pane) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
            self.closePane(pane);
            try ipc_protocol.writeOk(out, allocator, null, {});
        } else if (eql(u8, req.cmd, "set-title")) {
            const text = req.title orelse req.data orelse return ipc_protocol.writeErr(out, allocator, "set-title requires title");
            var z_buf: [512:0]u8 = undefined;
            const z = std.fmt.bufPrintZ(&z_buf, "{s}", .{text}) catch return ipc_protocol.writeErr(out, allocator, "title too long");
            const page = if (req.pane != null) pg: {
                const pane = self.paneById(req.pane) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
                break :pg tabPageForPane(self, pane) orelse return ipc_protocol.writeErr(out, allocator, "pane has no tab");
            } else self.tabPageById(req.tab) orelse return ipc_protocol.writeErr(out, allocator, "no such tab");
            c.adw_tab_page_set_title(page, z.ptr);
            c.adw_tab_page_set_tooltip(page, z.ptr);
            try ipc_protocol.writeOk(out, allocator, null, {});
        } else if (eql(u8, req.cmd, "new-durable-tab")) {
            // req.pane set = the CLI runs inside that pane (SKETERM_
            // PANE_ID): the session takes the pane over, tmux-style,
            // instead of opening a tab.
            const takeover: ?*Pane = if (req.pane != null)
                self.paneById(req.pane) orelse return ipc_protocol.writeErr(out, allocator, "no such pane")
            else
                null;
            self.newDurableSession(req.host, takeover) catch return ipc_protocol.writeErr(out, allocator, "durable spawn failed (ssh/key auth?)");
            try ipc_protocol.writeOk(out, allocator, "pane", self.next_pane_id - 1);
        } else if (eql(u8, req.cmd, "attach-session")) {
            const name = req.data orelse return ipc_protocol.writeErr(out, allocator, "attach-session requires data (session name)");
            const takeover: ?*Pane = if (req.pane != null)
                self.paneById(req.pane) orelse return ipc_protocol.writeErr(out, allocator, "no such pane")
            else
                null;
            const conn = self.muxConnect(req.host) catch return ipc_protocol.writeErr(out, allocator, "mux daemon unreachable");
            self.attachMux(conn, name, req.host, takeover) catch |err| {
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "attach failed: {s}", .{@errorName(err)}) catch "attach failed";
                return ipc_protocol.writeErr(out, allocator, msg);
            };
            try ipc_protocol.writeOk(out, allocator, null, {});
        } else if (eql(u8, req.cmd, "set-tab-color")) {
            const page = self.tabPageById(req.tab) orelse return ipc_protocol.writeErr(out, allocator, "no such tab");
            const spec = req.data orelse return ipc_protocol.writeErr(out, allocator, "set-tab-color requires data (#RRGGBB or none)");
            if (eql(u8, spec, "none")) {
                self.setTabColor(page, null);
            } else if (parseHexRGB(spec)) |col| {
                self.setTabColor(page, col);
            } else {
                return ipc_protocol.writeErr(out, allocator, "bad color (want #RRGGBB or none)");
            }
            try ipc_protocol.writeOk(out, allocator, null, {});
        } else if (eql(u8, req.cmd, "action")) {
            // Dispatch any bindable action by name — the scripting
            // equivalent of pressing its keybind ("zoom_pane",
            // "copy_mode", "split_h", …; names as in `keybind.*`).
            const name = req.data orelse return ipc_protocol.writeErr(out, allocator, "action needs data=<name>");
            const action = @import("input.zig").actionFromName(name) orelse
                return ipc_protocol.writeErr(out, allocator, "unknown action");
            if (req.pane != null) {
                const pane = self.paneById(req.pane) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
                _ = c.gtk_widget_grab_focus(@ptrCast(pane.area));
            }
            dispatchAction(self, action);
            try ipc_protocol.writeOk(out, allocator, null, {});
        } else {
            try ipc_protocol.writeErr(out, allocator, "unknown command");
        }
    }

    fn ipcList(self: *Window, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var tabs: std.ArrayList(ipc_protocol.TabInfo) = .empty;
        const focused = self.focusedPane();
        const sel = c.adw_tab_view_get_selected_page(self.tab_view);
        const n = c.adw_tab_view_get_n_pages(self.tab_view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
            const child = c.adw_tab_page_get_child(page);
            var pane_infos: std.ArrayList(ipc_protocol.PaneInfo) = .empty;
            for (self.panes.items) |p| {
                if (child == null) continue;
                if (!widgetIsAncestor(@ptrCast(child), p.widget())) continue;
                const scr = p.terminal.screen;
                try pane_infos.append(arena, .{
                    .id = p.id,
                    .title = if (scr.last_title) |t| try arena.dupe(u8, t) else "",
                    .cwd = if (p.terminal.cwd) |cw| try arena.dupe(u8, cw) else "",
                    .pid = p.terminal.pty.child_pid,
                    .rows = scr.rows,
                    .cols = scr.cols,
                    .focused = (p == focused),
                    .zoomed = (p == self.zoom_pane),
                });
            }
            const title_c = c.adw_tab_page_get_title(page);
            try tabs.append(arena, .{
                .id = tabPageId(page),
                .title = if (title_c != null) try arena.dupe(u8, std.mem.span(title_c)) else "",
                .selected = (page == sel),
                .color = if (tabColorOf(page)) |col|
                    try std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}", .{ col[0], col[1], col[2] })
                else
                    null,
                .panes = pane_infos.items,
            });
        }
        try ipc_protocol.writeOk(out, allocator, "tabs", tabs.items);
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
        source.writeRaw(bytes);

        if (self.groupsend == .off) return;

        for (self.terminals.items) |t| {
            if (t == source) continue;
            switch (self.groupsend) {
                .off => unreachable,
                .all => t.writeRaw(bytes),
                .group => {
                    // Find the source pane's group + this pane's group.
                    const src_group: ?[]const u8 = self.groupForTerminal(source);
                    const dst_group: ?[]const u8 = self.groupForTerminal(t);
                    if (src_group) |sg| {
                        if (dst_group) |dg| {
                            if (std.mem.eql(u8, sg, dg)) t.writeRaw(bytes);
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
            // Last pane in its tab — close the tab.
            const page = tabPageForPane(self, target) orelse return;
            _ = c.adw_tab_view_close_page(self.tab_view, page);
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
        // Resolve the page BEFORE the widget surgery below detaches
        // the pane from it — needed for the tree-model update.
        const tree_page = tabPageForPane(self, pane);

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
        // Mirror the collapse in the tab's tree model.
        var focus_hint: ?*Pane = null;
        if (tree_page) |page| {
            if (tabTreeOf(page)) |t| {
                if (t.removeLeaf(pane)) |r| {
                    focus_hint = r.focus_hint;
                } else |_| {
                    std.debug.print("sketerm: tree model close desync (leaf not found)\n", .{});
                }
            }
        }

        // The search bar / hint mode hold raw pane pointers — drop
        // them before the pane is freed.
        self.unlistPane(pane);

        // Move focus to the first pane of the surviving sibling
        // subtree (model hint) — without this, focus can land on the
        // now-empty GtkPaned wrapper and keypresses go nowhere.
        if (focus_hint) |fp| {
            _ = c.gtk_widget_grab_focus(@ptrCast(fp.area));
        } else if (sibling) |sib| {
            for (self.panes.items) |p| {
                if (widgetIsAncestor(@ptrCast(sib), @ptrCast(p.widget()))) {
                    _ = c.gtk_widget_grab_focus(@ptrCast(p.area));
                    break;
                }
            }
        }

        self.verifyAllTabs();
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

            self.verifyTreeModel(page.?, root.?);
            // Model-based serialization (correct even while zoomed);
            // widget walk only as fallback for a missing model.
            const tree = if (Window.tabTreeOf(page.?)) |t|
                self.modelTreeToLayout(arena, t.root) catch continue
            else
                self.collectTree(arena, root.?) catch continue;
            try tabs.append(arena, .{
                .title = try arena.dupe(u8, title),
                .tree = tree,
                .pinned = c.adw_tab_page_get_pinned(page) != 0,
                .color = if (tabColorOf(page.?)) |col|
                    try std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}", .{ col[0], col[1], col[2] })
                else
                    null,
                .title_locked = c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-title-locked") != null,
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
                return .{ .pane = try self.paneSpec(arena, p) };
            }
        }
        return error.PaneNotFound;
    }

    /// Serialize one pane's restore state (cwd, command, profile,
    /// shader, mux session) — shared by the model- and widget-based
    /// layout walkers.
    fn paneSpec(self: *Window, arena: std.mem.Allocator, p: *Pane) !layout_mod.PaneSpec {
        {
            {
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
                // Save font_size only if it diverges from the pane's
                // profile settings — keeps layout files terse.
                const base_fs = self.config.profileSettings(p.active_profile orelse "").font_size;
                const fs: ?u16 = if (p.font_size != base_fs) p.font_size else null;
                // Carry profile name so split-tree restore / duplicate
                // can reapply per-pane profile overrides.
                const prof: []const u8 = if (p.active_profile) |pn|
                    try arena.dupe(u8, pn)
                else
                    "";
                // Explicit shader pick travels with the layout;
                // profile/global shaders re-resolve on restore.
                const shader: []const u8 = if (p.custom_shader_user)
                    (if (p.custom_shader_path) |sp| try arena.dupe(u8, sp) else "")
                else
                    "";
                const preset: []const u8 = if (p.preset_name) |pn|
                    try arena.dupe(u8, pn)
                else
                    "";
                // Durable mux panes: session + transport so restore
                // can reattach (or recreate under the same name).
                var mux_session: []const u8 = "";
                var mux_host: []const u8 = "";
                if (p.terminal.remote) |r| {
                    mux_session = try arena.dupe(u8, r.session);
                    if (r.host) |h| mux_host = try arena.dupe(u8, h);
                }
                return .{
                    .cwd = cwd,
                    .command = cmd,
                    .font_size = fs,
                    .profile = prof,
                    .custom_shader = shader,
                    .shader_preset = preset,
                    .shader_cleared = p.shader_cleared,
                    .mux_session = mux_session,
                    .mux_host = mux_host,
                };
            }
        }
    }

    /// Serialize a model node to a layout tree. Split ratios are
    /// read live from the view handle (the GtkPaned) at save time.
    fn modelTreeToLayout(self: *Window, arena: std.mem.Allocator, node: PaneTree.Node) !layout_mod.Tree {
        switch (node) {
            .leaf => |p| return .{ .pane = try self.paneSpec(arena, p) },
            .split => |sp| {
                var ratio: f32 = if (sp.ratio > 0 and sp.ratio < 1) sp.ratio else 0.5;
                if (sp.view) |v| {
                    const paned: *c.GtkWidget = @ptrCast(@alignCast(v));
                    const total: c_int = if (sp.orientation == .horizontal)
                        c.gtk_widget_get_width(paned)
                    else
                        c.gtk_widget_get_height(paned);
                    const pos = c.gtk_paned_get_position(@ptrCast(paned));
                    if (total > 0) ratio = @as(f32, @floatFromInt(pos)) / @as(f32, @floatFromInt(total));
                }
                const children = try arena.alloc(layout_mod.Tree, 2);
                children[0] = try self.modelTreeToLayout(arena, sp.children[0]);
                children[1] = try self.modelTreeToLayout(arena, sp.children[1]);
                return .{ .split = .{
                    .orientation = if (sp.orientation == .horizontal) .horizontal else .vertical,
                    .ratio = ratio,
                    .children = children,
                } };
            },
        }
    }

    /// SKETERM_VERIFY_TREE=1: structural cross-check of the tree
    /// model against the live widget tree. Skipped while a pane is
    /// zoomed (zoom reparents widgets; the model is authoritative).
    fn verifyTreeModel(self: *Window, page: *c.AdwTabPage, root_widget: *c.GtkWidget) void {
        const S = struct {
            var enabled: ?bool = null;
        };
        if (S.enabled == null) S.enabled = c.getenv("SKETERM_VERIFY_TREE") != null;
        if (!S.enabled.?) return;
        if (self.zoom_pane != null) return;
        const t = Window.tabTreeOf(page) orelse {
            std.debug.print("sketerm: VERIFY: page has no tree model\n", .{});
            return;
        };
        if (!self.widgetMatchesNode(root_widget, t.root)) {
            std.debug.print("sketerm: VERIFY FAILED: tree model diverges from widget tree\n", .{});
            // Test-only env var: die loudly so the e2e harness fails.
            c.abort();
        }
    }

    /// Verify every tab's model (SKETERM_VERIFY_TREE only; no-op
    /// otherwise). Called after each tree mutation.
    fn verifyAllTabs(self: *Window) void {
        if (c.getenv("SKETERM_VERIFY_TREE") == null) return;
        const n = c.adw_tab_view_get_n_pages(self.tab_view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
            const wrapper = c.adw_tab_page_get_child(page) orelse continue;
            const root = c.gtk_widget_get_first_child(@ptrCast(wrapper)) orelse continue;
            self.verifyTreeModel(page, root);
        }
    }

    fn widgetMatchesNode(self: *Window, w: *c.GtkWidget, node: PaneTree.Node) bool {
        const is_paned = c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(w)),
            c.gtk_paned_get_type(),
        ) != 0;
        switch (node) {
            .leaf => |p| return !is_paned and @intFromPtr(p.widget()) == @intFromPtr(w),
            .split => |sp| {
                if (!is_paned) return false;
                const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(w)));
                const want_horiz = sp.orientation == .horizontal;
                if ((orientation == c.GTK_ORIENTATION_HORIZONTAL) != want_horiz) return false;
                const start = c.gtk_paned_get_start_child(@ptrCast(w)) orelse return false;
                const end = c.gtk_paned_get_end_child(@ptrCast(w)) orelse return false;
                return self.widgetMatchesNode(start, sp.children[0]) and
                    self.widgetMatchesNode(end, sp.children[1]);
            },
        }
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

    /// Open a GtkFileDialog to pick a saved layout (.json/.layout)
    /// and append its tabs to the current window — same semantics as
    /// the `--layout` CLI flag (existing tabs are kept).
    pub fn loadLayoutAs(self: *Window) void {
        const dialog = c.gtk_file_dialog_new();
        c.gtk_file_dialog_set_title(dialog, "Load Layout");
        c.gtk_file_dialog_open(
            dialog,
            @ptrCast(self.app_window),
            null,
            @ptrCast(&onLoadLayoutDone),
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

        // Split tree — round-trip via the tree model → newTabFromSpec
        // (widget walk only as fallback for a missing model).
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const tree = (if (Window.tabTreeOf(sel)) |t|
            self.modelTreeToLayout(arena, t.root)
        else
            self.collectTree(arena, root.?)) catch |err| {
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
        const p = pathZ(&path_z, path) catch return false;
        if (c.access(p, c.F_OK) != 0) return false;

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
        .load_layout => self.loadLayoutAs(),
        .prompt_prev => self.jumpPromptOnFocused(.prev),
        .prompt_next => self.jumpPromptOnFocused(.next),
        // tmux semantics: navigating away from a zoomed pane unzooms.
        .pane_prev => {
            self.unzoomPane();
            self.cyclePane(.prev);
        },
        .pane_next => {
            self.unzoomPane();
            self.cyclePane(.next);
        },
        .zoom_pane => self.toggleZoomPane(),
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
        .detach_tab => self.detachCurrentTab(),
        .configure_shader => {
            if (!@import("shader_dialog.zig").open(self)) self.pickPaneShader();
        },
        .shader_preset_pick => self.openShaderPresetPicker(),
        .apply_profile => self.openApplyProfilePicker(),
        .show_scrollback => self.openScrollbackPager(),
        .new_durable_tab => self.newDurableTab(null) catch |err| logActionError("new_durable_tab", err),
        .mux_detach => if (self.focusedPane()) |p| self.detachPaneToShell(p),
        .command_palette => palette_mod.open(self) catch |err| logActionError("command_palette", err),
        .hints_open => self.openHints(),
        .copy_mode => self.openCopyMode(),
        else => {},
    }
}

/// input.Ctx copy-mode sink — forwards into the Window method.
fn onCopyModeKey(ctx: ?*anyopaque, keyval: c_uint, state: c.GdkModifierType) bool {
    const self = cast.userData(Window, ctx);
    return self.handleCopyModeKey(keyval, state);
}

/// Column of the last non-blank cell on a display row ($ motion).
/// Blank line → column 0.
fn copyModeLineEnd(screen: *const @import("../grid/screen.zig").Screen, row: i32) i32 {
    const cells = screen.lineCellsAtPub(row) orelse return 0;
    var i: usize = cells.len;
    while (i > 0 and cells[i - 1].rune == 0) i -= 1;
    if (i == 0) return 0;
    return @intCast(i - 1);
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
        .apply_profile => self.openApplyProfilePicker(),
        .duplicate_tab => self.duplicateCurrentTab(),
        .shader_pick => self.pickPaneShader(),
        .shader_preset => self.openShaderPresetPicker(),
        .shader_config => {
            // No active shader → offer the picker instead.
            if (!@import("shader_dialog.zig").open(self)) self.pickPaneShader();
        },
        .shader_clear => self.clearPaneShader(),
        .close_tab => self.closeCurrentTab(),
        .rename_tab => self.renameCurrentTab(),
        .color_tab => self.chooseTabColor(),
        .pin_tab => self.togglePinCurrentTab(),
        .split_h => self.splitFocused(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch |err| logActionError("split_h", err),
        .split_v => self.splitFocused(@intCast(c.GTK_ORIENTATION_VERTICAL)) catch |err| logActionError("split_v", err),
        .close_pane => self.closeFocusedPane(),
        .zoom_pane => self.toggleZoomPane(),
        .set_pane_title => self.setFocusedPaneTitle(),
        // Detach = close the pane; Terminal.deinit on a remote pane
        // sends DETACH and leaves the session running in the daemon.
        .mux_detach => if (self.focusedPane()) |p| self.detachPaneToShell(p),
        .mux_rename => self.renameFocusedMuxSession(),
        .mux_kill => self.killFocusedMuxSession(),
        .copy_screen => self.copyFocusedScreen(),
        .copy_scrollback => self.copyFocusedScrollback(),
        .prefs_open => self.openPrefs(),
        else => {},
    }
}

const ShaderPickCtx = struct {
    win: *Window,
    pane: *Pane,
};

fn onShaderPicked(source: *c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ShaderPickCtx, user);
    defer ctx.win.allocator.destroy(ctx);
    const dialog: *c.GtkFileDialog = @ptrCast(source);
    const file = c.gtk_file_dialog_open_finish(dialog, result, null) orelse return;
    defer c.g_object_unref(file);
    const path_cstr = c.g_file_get_path(file) orelse return;
    defer c.g_free(path_cstr);

    // The pane may have closed while the dialog was up — only act if
    // it's still listed (the pointer would be dangling otherwise).
    var alive = false;
    for (ctx.win.panes.items) |p| {
        if (p == ctx.pane) {
            alive = true;
            break;
        }
    }
    if (!alive) return;
    const path = std.mem.span(@as([*:0]const u8, @ptrCast(path_cstr)));
    // Strictly per-pane: the pick lands on the clicked pane only. A
    // manual file pick replaces any bound preset.
    ctx.pane.dropShaderPreset(ctx.win.config.shader_params.items);
    _ = ctx.pane.setCustomShader(path, ctx.win.config.custom_shader_animation, true);
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

fn onLoadLayoutDone(source: *c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    const dialog: *c.GtkFileDialog = @ptrCast(source);
    const file = c.gtk_file_dialog_open_finish(dialog, result, null) orelse return;
    defer c.g_object_unref(file);
    const path_cstr = c.g_file_get_path(file) orelse return;
    defer c.g_free(path_cstr);
    const path = std.mem.span(@as([*:0]const u8, @ptrCast(path_cstr)));
    _ = self.loadLayoutFromPath(path) catch |err|
        std.debug.print("sketerm: load layout failed: {s}\n", .{@errorName(err)});
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
        p.terminal.screen.configured_fg = fg_bg.fg;
        p.terminal.screen.configured_bg = fg_bg.bg;
        p.terminal.screen.notifyColorScheme(isDarkBg(fg_bg.bg));
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

fn onApplyProfilePicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.ProfileButtonCtx, user);
    if (ctx.pane) |pane| {
        ctx.window.applyProfileToPane(pane, ctx.profile_name);
    }
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
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

fn onPresetPicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.PresetButtonCtx, user);
    if (ctx.pane) |pane| {
        if (!ctx.window.applyShaderPresetByName(pane, ctx.preset_name)) {
            std.debug.print("sketerm: shader preset '{s}' failed to apply\n", .{ctx.preset_name});
        }
    }
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
}

fn onPresetDeleted(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.PresetButtonCtx, user);
    shader_preset_mod.delete(ctx.allocator, ctx.preset_name) catch {
        std.debug.print("sketerm: shader preset '{s}' delete failed\n", .{ctx.preset_name});
        return;
    };
    // Hide the row (button + delete button) — the popover rebuilds
    // fresh on next open.
    if (c.gtk_widget_get_parent(@ptrCast(btn))) |row| c.gtk_widget_set_visible(row, 0);
}

fn freePresetButtonCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.PresetButtonCtx, user);
    ctx.allocator.free(ctx.preset_name);
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

fn onMuxRenameActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.MuxRenameCtx, user);
    // The pane can close while the popover is open — verify it's
    // still alive before dereferencing.
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
            if (text.len > 0) ctx.pane.terminal.renameSession(text);
        }
    }
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
}

fn freeMuxRenameCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.MuxRenameCtx, user);
    ctx.allocator.destroy(ctx);
}

/// Wired from `Pane.win_on_session_renamed` — the daemon confirmed a
/// session rename; rebuild the "⌁ name [@ host]" tab title.
fn onTermSessionRenamed(ctx: ?*anyopaque, pane: *Pane, name: []const u8) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane) orelse return;
    const remote = pane.terminal.remote orelse return;
    var title_buf: [160:0]u8 = undefined;
    const title_z = if (remote.host) |h|
        std.fmt.bufPrintZ(&title_buf, "⌁ {s} @ {s}", .{ name, h }) catch return
    else
        std.fmt.bufPrintZ(&title_buf, "⌁ {s}", .{name}) catch return;
    c.adw_tab_page_set_title(page, title_z.ptr);
    c.adw_tab_page_set_tooltip(page, title_z.ptr);
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
    // A remote pane "exiting" means the mux session ended or the
    // connection dropped — never close the pane for that; land in a
    // local shell instead (exit_action governs local children only).
    if (pane.terminal.remote != null) {
        self.detachPaneToShell(pane);
        return;
    }
    const action = if (self.hold_override) .hold else self.config.exit_action;
    switch (action) {
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

    // Mark the containing tab needs-attention (unless it's the
    // currently selected one).
    const page = tabPageForPane(self, pane) orelse return;
    if (page == c.adw_tab_view_get_selected_page(self.tab_view)) return;
    c.adw_tab_page_set_needs_attention(page, 1);
}

/// OSC 7 cwd updated for `pane`. Find its AdwTabPage and rewrite
/// the tooltip to include the live cwd, so hovering tells the user
/// where each tab actually is. Format: "<title>\n<cwd>".
/// OSC 1337 ; SetProfile=<name> — an app asked to restyle its pane.
/// Untrusted input: applyProfileToPane maps unknown/empty names to the
/// Default profile, so a hostile sequence can only swap between the
/// user's own configured profiles, never inject arbitrary settings.
fn onTermSetProfile(ctx: ?*anyopaque, pane: *Pane, name: []const u8) void {
    const self = cast.userData(Window, ctx);
    self.applyProfileToPane(pane, name);
}

fn onTermCwdChanged(ctx: ?*anyopaque, pane: *Pane, cwd: []const u8) void {
    const self = cast.userData(Window, ctx);
    {
        const page = tabPageForPane(self, pane) orelse return;

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
    // Model first: pure data, correct even while a pane is zoomed
    // (zoom reparents widgets but never touches the model).
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
        if (Window.tabTreeOf(page)) |t| {
            if (t.contains(pane)) return page;
        }
    }
    // Widget-walk fallback for pages without a model (shouldn't
    // happen; kept for robustness during the model rollout).
    i = 0;
    while (i < n) : (i += 1) {
        const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
        const child = c.adw_tab_page_get_child(page);
        if (child == null) continue;
        if (widgetIsAncestor(@ptrCast(child), pane.widget())) return page;
    }
    return null;
}

/// Dark/light classification of an effective background, for the
/// DSR ?996 / mode 2031 color-scheme reports (relative luminance).
fn isDarkBg(bg: [4]f32) bool {
    return (0.2126 * bg[0] + 0.7152 * bg[1] + 0.0722 * bg[2]) < 0.5;
}

/// Stable GNotification tag for an OSC 99 identifier, so a repeated
/// id replaces the previous notification and p=close can withdraw
/// it. Null (untagged) when the app supplied no id.
fn notifyTag(buf: []u8, id: []const u8) ?[*:0]const u8 {
    if (id.len == 0) return null;
    const z = std.fmt.bufPrintZ(buf, "sketerm-osc99-{s}", .{id}) catch return null;
    return z.ptr;
}

fn onTermNotification(ctx: ?*anyopaque, pane: *Pane, ev: Screen.NotificationEvent) void {
    const self = cast.userData(Window, ctx);
    const app = c.gtk_window_get_application(@ptrCast(self.app_window));
    if (app == null) return;
    var tag_buf: [96]u8 = undefined;

    if (ev.close) {
        if (notifyTag(&tag_buf, ev.id)) |tag| {
            c.g_application_withdraw_notification(@ptrCast(app), tag);
        }
        return;
    }

    // Occasion gate: `unfocused` = skip while this window is active;
    // `invisible` additionally requires the pane's tab to be the
    // selected one (i.e. the pane is actually on screen).
    const win_active = c.gtk_window_is_active(@ptrCast(self.app_window)) != 0;
    switch (ev.occasion) {
        .always => {},
        .unfocused => if (win_active) return,
        .invisible => if (win_active) {
            const page = tabPageForPane(self, pane);
            if (page != null and page == c.adw_tab_view_get_selected_page(self.tab_view)) return;
        },
    }

    const effective_title = if (ev.title.len > 0) ev.title else "sketerm";
    const title_z = self.allocator.allocSentinel(u8, effective_title.len, 0) catch return;
    defer self.allocator.free(title_z);
    @memcpy(title_z, effective_title);
    const notif = c.g_notification_new(title_z.ptr);
    if (notif == null) return;
    defer c.g_object_unref(notif);

    if (ev.body.len > 0) {
        const body_z = self.allocator.allocSentinel(u8, ev.body.len, 0) catch return;
        defer self.allocator.free(body_z);
        @memcpy(body_z, ev.body);
        c.g_notification_set_body(notif, body_z.ptr);
    }

    // Icon: themed name wins when the theme has it; otherwise the
    // transmitted image bytes (PNG/JPEG/GIF — the notification daemon
    // decodes them from the serialized GBytesIcon).
    if (ev.icon_name.len > 0) {
        var name_buf: [128]u8 = undefined;
        if (std.fmt.bufPrintZ(&name_buf, "{s}", .{ev.icon_name})) |name_z| {
            const icon = c.g_themed_icon_new(name_z.ptr);
            c.g_notification_set_icon(notif, @ptrCast(icon));
            c.g_object_unref(icon);
        } else |_| {}
    } else if (ev.icon_data.len > 0) {
        const bytes = c.g_bytes_new(ev.icon_data.ptr, ev.icon_data.len);
        const icon = c.g_bytes_icon_new(bytes);
        c.g_bytes_unref(bytes);
        c.g_notification_set_icon(notif, @ptrCast(icon));
        c.g_object_unref(icon);
    }

    if (ev.urgency) |u| {
        c.g_notification_set_priority(notif, switch (u) {
            0 => c.G_NOTIFICATION_PRIORITY_LOW,
            2 => c.G_NOTIFICATION_PRIORITY_URGENT,
            else => c.G_NOTIFICATION_PRIORITY_NORMAL,
        });
    }

    // Activation slot — needed for reports AND for focusing the
    // originating pane. Plain notifications skip the bookkeeping.
    const interactive = ev.want_report or ev.buttons_raw.len > 0 or ev.want_focus;
    var token: u32 = 0;
    if (interactive) {
        token = self.registerNotifySlot(pane, ev) orelse 0;
    }
    if (token != 0) {
        c.g_notification_set_default_action_and_target(
            notif,
            "app.notify-act",
            "(uu)",
            token,
            @as(c_uint, 0),
        );
        // Buttons: U+2028-separated labels, numbered from 1 in
        // activation reports. Cap at 8 — desktop daemons show 2-3.
        var n_btn: c_uint = 0;
        var bit = std.mem.splitSequence(u8, ev.buttons_raw, "\xe2\x80\xa8");
        while (bit.next()) |label| {
            if (label.len == 0) continue;
            if (n_btn >= 8) break;
            n_btn += 1;
            const label_z = self.allocator.allocSentinel(u8, label.len, 0) catch break;
            defer self.allocator.free(label_z);
            @memcpy(label_z, label);
            c.g_notification_add_button_with_target(
                notif,
                label_z.ptr,
                "app.notify-act",
                "(uu)",
                token,
                n_btn,
            );
        }
    }

    c.g_application_send_notification(@ptrCast(app), notifyTag(&tag_buf, ev.id), notif);
}

/// Activation report / focus dispatch for "app.notify-act". Fired by
/// the desktop when the user clicks an OSC 99 notification (button 0)
/// or one of its buttons (1-based).
fn onNotifyActivate(_: *c.GSimpleAction, param: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    if (param == null) return;
    var token: c_uint = 0;
    var button: c_uint = 0;
    c.g_variant_get(param, "(uu)", &token, &button);

    const slot = blk: {
        for (self.notify_slots.items) |s| {
            if (s.token == token) break :blk s;
        }
        return; // pane closed, or slot evicted — nothing to do
    };

    if (slot.want_focus) {
        c.gtk_window_present(@ptrCast(self.app_window));
        if (tabPageForPane(self, slot.pane)) |page| {
            c.adw_tab_view_set_selected_page(self.tab_view, page);
        }
        _ = c.gtk_widget_grab_focus(@ptrCast(slot.pane.area));
    }
    if (slot.want_report) {
        // Spec: OSC 99 ; i=<id> ; <button-or-empty>. id was sanitized
        // at parse time, so it can't smuggle escape bytes.
        var buf: [96]u8 = undefined;
        const id: []const u8 = if (slot.id.len > 0) slot.id else "0";
        const out = if (button == 0)
            std.fmt.bufPrint(&buf, "\x1b]99;i={s};\x1b\\", .{id}) catch return
        else
            std.fmt.bufPrint(&buf, "\x1b]99;i={s};{d}\x1b\\", .{ id, button }) catch return;
        slot.pane.terminal.writeRaw(out);
    }
}

/// OSC 9;4 progress from `pane`: drive the tab's indicator ring and
/// re-aggregate the window-level taskbar progress.
fn onTermProgress(ctx: ?*anyopaque, pane: *Pane, state: u8, percent: u8) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane) orelse return;

    // One pane owns the tab's progress slot at a time: two builds in
    // split panes would otherwise overwrite each other's ring (and
    // wobble the taskbar aggregate) on every OSC update. The owner
    // releases by clearing (state 0) or by going quiet for 3s.
    const now_ms: usize = @intCast(@divTrunc(c.g_get_monotonic_time(), 1000));
    const owner: u32 = @truncate(@intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-progress-owner")));
    const stamp: usize = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-progress-stamp"));
    if (owner != 0 and owner != pane.id and now_ms -% stamp < 3000) return;
    if (state == 0) {
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-progress-owner", null);
    } else {
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-progress-owner", @ptrFromInt(@as(usize, pane.id)));
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-progress-stamp", @ptrFromInt(now_ms));
    }

    self.setTabProgress(page, state, percent);
    self.updateTaskbarProgress();
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
/// Record the pane that just gained focus as its tab's last-focused, so
/// re-selecting the tab restores it (instead of the first pane).
fn onPaneFocused(ctx: ?*anyopaque, pane: *Pane) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane) orelse return;
    if (Window.tabTreeOf(page)) |t| t.last_focused = pane;
}

/// A pane's visible grid changed (true content change, not just bytes).
/// Stamp the tab with a monotonic-us timestamp; the tab bar reads it to
/// drive the activity glow and decays it once output stops. The tab
/// you're already looking at is trivially "active", so skip it.
fn onTermActivity(ctx: ?*anyopaque, pane: *Pane) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane) orelse return;
    if (page == c.adw_tab_view_get_selected_page(self.tab_view)) return;
    tabbar_mod.recordActivity(page);
    self.tabbar.ensureTick();
}

fn onSelectedPageChanged(view: *c.AdwTabView, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    const page = c.adw_tab_view_get_selected_page(view);
    if (page == null) return;
    // Clear any needs-attention from the now-active tab.
    c.adw_tab_page_set_needs_attention(page, 0);
    const child = c.adw_tab_page_get_child(page);
    if (child == null) return;

    // Restore the tab's last-focused pane. Validate the stored pointer is
    // still a live pane in THIS tab (guards against a closed pane whose
    // address was reused) before grabbing focus.
    if (Window.tabTreeOf(page.?)) |t| {
        if (t.last_focused) |lf| {
            for (self.panes.items) |p| {
                if (p == lf and widgetIsAncestor(@ptrCast(child), p.widget())) {
                    _ = c.gtk_widget_grab_focus(@ptrCast(p.area));
                    return;
                }
            }
        }
    }

    // No (valid) last-focused pane — fall back to the first pane.
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

/// A tab left this view — closed by the user, OR mid-transfer to
/// another window (drag-out). Which one isn't knowable here: during
/// a transfer the destination's "page-attached" hasn't fired yet. So
/// defer the close-vs-transfer decision one main-loop iteration; by
/// then an adopted page's panes are gone from our lists and the
/// teardown below finds nothing to free.
fn onPageDetached(_: *c.AdwTabView, page: *c.AdwTabPage, _: c_int, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    const child = c.adw_tab_page_get_child(page);
    if (child == null) return;

    // App/window shutdown: no transfer is possible, and idles may
    // never run again — tear down synchronously (prior behaviour).
    if (c.gtk_widget_get_mapped(self.app_window) == 0) {
        collectAndFreePanes(self, @ptrCast(child));
        self.freeTabTree(page);
        return;
    }

    const pending = std.heap.c_allocator.create(PendingPageDetach) catch {
        // OOM — fall back to the synchronous path; a mid-transfer
        // page would be freed under the destination window, but
        // we're in OOM territory anyway.
        self.captureClosedTab(page, @ptrCast(child));
        collectAndFreePanes(self, @ptrCast(child));
        self.freeTabTree(page);
        return;
    };
    _ = c.g_object_ref(@ptrCast(@alignCast(page)));
    pending.* = .{ .win = self, .page = page };
    _ = c.g_idle_add(@ptrCast(&onPageDetachedIdle), @ptrCast(pending));
}

const PendingPageDetach = struct {
    win: *Window,
    page: *c.AdwTabPage,
};

fn onPageDetachedIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const pending = cast.userData(PendingPageDetach, user);
    const self = pending.win;
    const page = pending.page;
    defer {
        c.g_object_unref(@ptrCast(@alignCast(page)));
        std.heap.c_allocator.destroy(pending);
    }

    const child = c.adw_tab_page_get_child(page);
    if (child != null) {
        // Closed (not transferred) ⟺ some pane under this page is
        // still in OUR lists — a cross-window adoption would have
        // disowned them all by now.
        var was_close = false;
        for (self.panes.items) |p| {
            if (widgetIsAncestor(@ptrCast(child), p.widget())) {
                was_close = true;
                break;
            }
        }
        if (was_close) {
            // Capture the tab's basic state into the recently-closed
            // ring BEFORE we tear the panes down. We keep title +
            // first-pane's cwd + profile; split trees aren't preserved.
            self.captureClosedTab(page, @ptrCast(child));
            collectAndFreePanes(self, @ptrCast(child));
            self.freeTabTree(page);
        }
    }

    // Window-alive bookkeeping. Bail if the window died or the
    // tab_view has been finalised in the meantime (visible as
    // `ADW_IS_TAB_VIEW` assertion warnings during quit).
    if (c.gtk_widget_get_mapped(self.app_window) == 0) return 0;
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(self.tab_view)), c.adw_tab_view_get_type()) == 0) return 0;
    if (c.adw_tab_view_get_n_pages(self.tab_view) == 0) {
        if (self.is_primary) {
            // Keep the primary alive with a fresh shell (it owns the
            // IPC socket / quake toggle / layout persistence).
            self.newShellTab(null) catch |err| {
                std.debug.print("sketerm: replacement tab spawn failed: {s}\n", .{@errorName(err)});
            };
        } else {
            // A secondary window with no tabs left has no reason to
            // exist — its last tab was closed or dragged elsewhere.
            c.gtk_window_destroy(@ptrCast(self.app_window));
            return 0;
        }
    }

    // The closed page may have carried progress; re-aggregate so the
    // taskbar doesn't stay stuck at the dead tab's value.
    self.updateTaskbarProgress();
    return 0; // G_SOURCE_REMOVE
}

/// Destination side of a tab transfer: adopt every pane in the
/// arriving page. Pages attached by our own tab-creation paths are
/// already ours — adoptPane no-ops on them.
fn onPageAttached(_: *c.AdwTabView, page: *c.AdwTabPage, _: c_int, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    const child = c.adw_tab_page_get_child(page) orelse return;
    self.adoptPanesInTree(@ptrCast(child));
    self.updateTaskbarProgress();
}

/// Custom-strip drag-out: a tab was dropped outside any strip. Spawn a
/// secondary window and transfer the page into it (mirrors the AdwTabBar
/// "create-window" behaviour, but driven by our own GtkDragSource).
fn onTabDetach(ctx: ?*anyopaque, view: *c.AdwTabView, page: *c.AdwTabPage) void {
    const self = cast.userData(Window, ctx);
    const win = self.spawnSecondaryWindow() orelse return;
    c.adw_tab_view_transfer_page(view, page, win.tab_view, 0);
}

/// AdwTabView "create-window": a tab is being dragged out of every
/// existing window. Spawn an empty secondary Window and return its
/// view; libadwaita transfers the page into it.
fn onCreateWindow(_: *c.AdwTabView, user: ?*anyopaque) callconv(.c) ?*c.AdwTabView {
    const self = cast.userData(Window, user);
    const win = self.spawnSecondaryWindow() orelse return null;
    return win.tab_view;
}

/// GTK destroy of the toplevel. Primary: quit the whole app (it owns
/// the IPC socket and layout persistence; orphaned secondaries would
/// be half-functional). Secondary: free the Zig-side Window once the
/// destroy chain has unwound — its pages already tore down via the
/// unmapped path in onPageDetached.
fn onWindowDestroyed(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    if (self.is_primary) {
        const app = c.gtk_window_get_application(@ptrCast(self.app_window));
        if (app != null) c.g_application_quit(@ptrCast(@alignCast(app)));
        return;
    }
    _ = c.g_idle_add(@ptrCast(&deferredWindowFree), @ptrCast(self));
}

fn deferredWindowFree(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);
    self.deinit();
    return 0; // G_SOURCE_REMOVE
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
            if (self.copymode_pane == pane) self.exitCopyMode();
            if (self.zoom_pane == pane) self.unzoomPane();
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
