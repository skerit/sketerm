//! Window — wraps an AdwApplicationWindow with AdwTabView + TabBar.
//!
//! Each tab owns a PaneTree (src/ui/tree.zig) of one or more split
//! Panes, each wrapping a Terminal.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const confirm = @import("confirm.zig");
const Pane = @import("pane.zig").Pane;
const Pty = @import("../pty.zig").Pty;
const Terminal = @import("../terminal.zig").Terminal;
const layout_mod = @import("../layout.zig");
const palette_mod = @import("palette.zig");
const clipboard = @import("clipboard.zig");
const remotectl_mod = @import("remotectl.zig");
const modes_mod = @import("modes.zig");
const winlayout_mod = @import("winlayout.zig");
const winconfig_mod = @import("winconfig.zig");
const quake = @import("quake.zig");
const termsinks_mod = @import("termsinks.zig");
const tabchrome_mod = @import("tabchrome.zig");
const Config = @import("../config.zig").Config;
const ipc_server = @import("../ipc/server.zig");
const bg_pass_mod = @import("../render/bg_pass.zig");
const shader_pass_mod = @import("../render/shader_pass.zig");
const shader_preset_mod = @import("../shader_preset.zig");
const tree_mod = @import("tree.zig");
const tabbar_mod = @import("tabbar.zig");
const tab_effects = @import("tab_effects.zig");
const file_transfers = @import("file_transfers.zig");
const files_entry = @import("../filebrowser/entry.zig");
const crashlog = @import("../util/crashlog.zig");

/// Toolkit-free pane-tree model — one per tab, attached to the
/// AdwTabPage as qdata (travels with cross-window tab drags). The
/// GtkPaned nesting is a VIEW of this; every widget-tree mutation
/// below also updates the model. See src/ui/tree.zig.
pub const PaneTree = tree_mod.Tree(*Pane);
const TAB_TREE_KEY = "sketerm-tree";
const tabforest_mod = @import("tabforest.zig");
const tabsidebar_mod = @import("tabsidebar.zig");

/// Toolkit-free tab-forest model — window-level tree-style-tabs
/// nesting (parent/child + collapse per AdwTabPage), one per Window.
/// The strip (hidden tabs) and the vertical sidebar are VIEWS of it;
/// every mutation goes through Window methods that call
/// `forestChanged`. See src/ui/tabforest.zig.
pub const TabForest = tabforest_mod.Forest(*c.AdwTabPage);
const ipc_protocol = @import("../ipc/protocol.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const picker = @import("picker.zig");
const fpicker = @import("../filebrowser/picker.zig");
const Screen = @import("../grid/screen.zig").Screen;

/// One-shot hint. Reset to false at startup; flipped on first
/// `always_on_top = true` so we don't spam the log on every
/// applyConfigChange.
var always_on_top_warned: bool = false;

/// Pane, tab and window ids are PROCESS-global, not per-window: they
/// address panes across every window of this process (`sketerm cli
/// --pane N`, `sketerm files --here`), and a per-window counter handed
/// two windows a pane 1 each, so "the window owning pane N" had no
/// answer.
pub var next_tab_id: u32 = 1;
var next_window_id: u32 = 1;

/// This PROCESS serves the dedicated file-manager identity (launched
/// as `sketerm files`): its own GApplication id, its own taskbar icon,
/// no layout persistence, and a control socket kept out of `sketerm
/// cli` auto-discovery. Set once by main.zig before the first window.
///
/// It says nothing about browser FACES: a browser pane inside an
/// ordinary terminal window is a first-class thing and never depends on
/// this flag.
var files_identity: bool = false;

/// Window title of the file-manager identity, and the icon name its
/// desktop entry installs (data/dev.sker.sketerm.files.desktop).
pub const FILES_TITLE = "Sketerm Files";
pub const FILES_ICON = "dev.sker.sketerm.files";
pub const TERMINAL_ICON = "dev.sker.sketerm";

/// Same for the browser identity (`sketerm web` / the `sketerm-web`
/// hardlink). As with files, a web FACE in a terminal window is
/// unrelated to this and never sets it.
var web_identity: bool = false;
pub const WEB_TITLE = "Sketerm Web";
pub const WEB_ICON = "dev.sker.sketerm.web";

/// Broadcast typing mode. Off / group / all — Terminator semantics.
pub const GroupSend = enum { off, group, all };

/// Copy-mode selection kind. `cell` = v (char-wise), `line` = V,
/// `rect` = Ctrl+v / r.
pub const CopyModeSel = enum { none, cell, line, rect };

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
pub fn alignmentForScale(scale: f64) u32 {
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
pub fn widgetSurfaceScale(widget: *c.GtkWidget) f64 {
    const native = c.gtk_widget_get_native(widget) orelse return 1.0;
    const surface = c.gtk_native_get_surface(native) orelse return 1.0;
    return c.gdk_surface_get_scale(surface);
}

/// Round `pos` down to the nearest multiple of M that's still > 0.
pub fn snapDown(pos: c_int, m: u32) c_int {
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
pub fn logActionError(action: []const u8, err: anyerror) void {
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
pub fn connectManualPopoverClose(popover: *c.GtkWidget) void {
    _ = c.g_signal_connect_data(
        popover,
        "closed",
        @ptrCast(&onManualPopoverClosed),
        @ptrCast(popover),
        null,
        c.G_CONNECT_DEFAULT,
    );
}

var theme_flip_installed = false;

/// Test hook: `SKETERM_THEME_FLIP_MS=<ms>` flips the process-global
/// colour scheme on a timer. It exists because `notify::dark` has no
/// other trigger a test rig can reach — libadwaita 1.9 takes the
/// system preference from the desktop portal only (its GSettings
/// fallback is gone; `system_supports_color_schemes` reads 0 without a
/// portal), so nothing outside the process can emit that signal.
/// Unset, this costs one getenv per process.
fn installThemeFlipHook() void {
    if (theme_flip_installed) return; // the style manager is a singleton
    const raw = c.getenv("SKETERM_THEME_FLIP_MS") orelse return;
    const ms = std.fmt.parseInt(c_uint, std.mem.span(raw), 10) catch return;
    if (ms == 0) return;
    theme_flip_installed = true;
    _ = c.g_timeout_add(ms, @ptrCast(&onThemeFlipTick), null);
}

fn onThemeFlipTick(_: ?*anyopaque) callconv(.c) c.gboolean {
    const sm = c.adw_style_manager_get_default();
    c.adw_style_manager_set_color_scheme(sm, if (c.adw_style_manager_get_color_scheme(sm) == c.ADW_COLOR_SCHEME_FORCE_DARK)
        c.ADW_COLOR_SCHEME_FORCE_LIGHT
    else
        c.ADW_COLOR_SCHEME_FORCE_DARK);
    return 1; // G_SOURCE_CONTINUE
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
    /// Floats transient notices (upload finished/failed) over the grid.
    toast_overlay: *c.AdwToastOverlay,
    /// Tree-style tabs model: parent/child + collapse per page.
    tab_forest: TabForest,
    /// Vertical tree sidebar (view of tab_forest). Null only when its
    /// creation failed; visibility follows Config.show_tab_sidebar +
    /// the toggle_tab_sidebar action.
    tab_sidebar: ?*tabsidebar_mod.Sidebar = null,
    /// HBox holding [sidebar | toast_overlay] as the toolbar content.
    content_box: *c.GtkWidget,
    /// Opener page consumed by the NEXT page-attached, so a web popup /
    /// open-link-in-new-tab nests as a CHILD of the tab that opened it.
    forest_pending_parent: ?*c.AdwTabPage = null,
    /// Reentrancy guard for the close-subtree policy sweep.
    closing_subtree: bool = false,
    title_buf: [256]u8 = undefined,
    panes: std.ArrayList(*Pane) = .empty,
    terminals: std.ArrayList(*Terminal) = .empty,
    /// Tabless forwarded-app sessions (window view mode): the mux
    /// attach client feeding the app's floating windows — no pane,
    /// no tab, nothing in the workspace. A tab materializes only on
    /// "Show in Tab" or when the app exits without ever opening a
    /// window (the log is the user's only diagnostic).
    app_sessions: std.ArrayList(*AppSession) = .empty,
    /// In-flight async remote-mux reattaches from layout restore
    /// (one background thread each; results land via g_idle_add).
    /// Window teardown marks them canceled — the idle frees them.
    mux_restore_jobs: std.ArrayList(*MuxRestoreJob) = .empty,
    allocator: std.mem.Allocator,
    /// Process-shared durable download/edit-sync service, acquired
    /// lazily when this window creates its first browser face.
    file_transfer_service: ?*file_transfers.Service = null,
    /// Last directory a web download's save dialog picked in THIS
    /// window (owned spec, possibly host-qualified); the next dialog
    /// starts there.
    web_download_dir: ?[]u8 = null,
    tab_counter: u32 = 0,
    /// Process-global identity of this window, for cross-window
    /// addressing (the `window` field of an IPC `list`). The pane / tab
    /// id counters are process-global too; see next_pane_id.
    id: u32 = 0,
    /// Daemon's reason for the last failed `attachMux`, so the IPC /
    /// `sketerm app` layer surfaces it ("no such session") instead of a
    /// bare "DaemonError".
    mux_attach_err: [192]u8 = undefined,
    mux_attach_err_len: usize = 0,
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
    /// drag-out, a repeat launch) close when their last tab leaves;
    /// closing the primary quits the app.
    is_primary: bool = false,
    /// Window title before the broadcast suffix. The file-manager
    /// identity titles its windows "Sketerm Files"; a terminal window
    /// is never relabelled, whatever faces its panes wear.
    title_base: []const u8 = "sketerm",
    /// Resolved auto shell-integration paths (allocator-owned,
    /// sentinel-terminated). All null when the script dir wasn't
    /// found; gated on Config.shell_integration at spawn time.
    si_zsh_script: ?[:0]u8 = null,
    si_fish_script: ?[:0]u8 = null,
    si_bash_script: ?[:0]u8 = null,
    si_zsh_shim: ?[:0]u8 = null,
    si_fish_shim: ?[:0]u8 = null,
    si_bash_shim: ?[:0]u8 = null,
    /// Socket path, computed at init (before any spawn) so every
    /// child gets SKETERM_SOCKET even if the listener starts later.
    ipc_path: ?[:0]u8 = null,
    debug_events: bool = false,
    /// Save the layout right before an X-button close destroys the
    /// widget tree (the shutdown hook runs too late — tabs are gone).
    save_on_close: bool = true,
    /// A close-path save already ran; the shutdown hook must not
    /// overwrite it with the post-teardown (empty) state.
    layout_saved_final: bool = false,
    /// Last (visible|urgent|percent) published to the taskbar via
    /// the Unity LauncherEntry signal; dedups OSC progress floods.
    taskbar_sent: u32 = 0xFFFF_FFFF,
    debug_images: bool = false,
    /// --hold: per-invocation exit_action override. Lives outside
    /// Config so a SIGUSR1 config reload can't clear it.
    hold_override: bool = false,
    /// Set before deinit starts so lifecycle helpers do not enqueue GTK work
    /// carrying this Window beyond its final teardown.
    destroying: bool = false,
    /// `page-detached` decisions hold a raw Window until their idle runs.
    /// Secondary finalization waits for this count rather than freeing under
    /// one of those callbacks.
    pending_page_detaches: usize = 0,
    /// Secondary finalize handed off to the last page-detach idle (see
    /// `deferredWindowFree`); never set while `pending_page_detaches` is 0.
    free_after_detaches: bool = false,
    config: Config = .{},
    /// GFileMonitor on config.conf (`config_auto_reload`). Null when
    /// the key is off or no monitor could be created.
    config_watch: ?*@import("configwatch.zig").Watcher = null,
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
    /// Pending delayed tab-acknowledge (clears the inactivity warning only
    /// after the tab has stayed selected for `tab_ack_delay_secs`).
    ack_timer_id: c.guint = 0,
    ack_timer_page: ?*c.AdwTabPage = null,
    /// Most recent page created via appendOrInsertTab — the tab
    /// overview's create-tab callback returns it.
    last_created_page: ?*c.AdwTabPage = null,
    /// The currently-selected page, tracked so a selection change can anchor
    /// the silence countdown on the tab being LEFT (the inactive-warning
    /// measures quiet from when you walk away). null before the first select.
    selected_page_now: ?*c.AdwTabPage = null,
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
    /// The config's symbol maps in the atlas's own type, rebuilt once
    /// per config generation (`winconfig.rebuildSymbolSpecs`). Panes
    /// borrow this slice, so nothing else may reallocate it.
    symbol_specs: std.ArrayList(@import("../render/atlas.zig").Atlas.SymbolMapSpec) = .empty,

    /// Hint mode keeps going after each pick, collecting matches
    /// instead of activating them; Enter copies the lot. Seeded from
    /// `Config.hint_multiple`, toggled in-mode with Tab.
    hints_multi: bool = false,
    /// Newline-joined text collected in multi-select mode.
    hints_collected: std.ArrayList(u8) = .empty,

    /// f/F/t/T have eaten their key and are waiting for the character
    /// to search for. 0 when no motion is pending.
    copymode_find_pending: u8 = 0,
    /// The last f/F/t/T, for `;` and `,` to repeat and reverse.
    copymode_find_kind: u8 = 0,
    copymode_find_char: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, app: ?*c.GtkApplication) !*Window {
        return initWithConfig(allocator, app, null, true);
    }

    /// Declare this PROCESS the dedicated file manager (`sketerm
    /// files`). Call before the first window; see `files_identity`.
    pub fn setFilesIdentity() void {
        files_identity = true;
    }

    /// Declare this PROCESS the dedicated browser (`sketerm web`).
    /// Call before the first window; see `web_identity`.
    pub fn setWebIdentity() void {
        web_identity = true;
    }

    /// True when this process IS the file manager (`sketerm files`).
    /// Read by the browser chrome for defaults that only make sense
    /// for a dedicated file manager (the places sidebar starts open).
    pub fn filesIdentity() bool {
        return files_identity;
    }

    /// True when this process IS the dedicated browser (`sketerm
    /// web`). Like the files identity, the per-pane titlebar is
    /// suppressed here: the URL toolbar already names the pane.
    pub fn webIdentity() bool {
        return web_identity;
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
        // Files mode gets a classic menubar (Nemo-style) between the
        // header and the tab strip. `self` is only STORED by the
        // buttons here; nothing dereferences it until a menu opens.
        if (files_identity)
            c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar_view), @import("browser/menubar.zig").build(allocator, self, @ptrCast(app_window)));
        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar_view), @ptrCast(@alignCast(tab_bar_w)));
        // Toast overlay wraps the tab area so transient notices (file
        // upload finished / failed) float over the terminal grid.
        const toast_overlay = c.adw_toast_overlay_new();
        c.gtk_widget_set_vexpand(toast_overlay, 1);
        c.gtk_widget_set_hexpand(toast_overlay, 1);
        c.adw_toast_overlay_set_child(@ptrCast(@alignCast(toast_overlay)), @ptrCast(@alignCast(tab_view_w)));
        // Content hbox: the (initially absent/hidden) tree-style tab
        // sidebar is prepended here after `self` is initialized.
        const content_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_box_append(@ptrCast(content_box), toast_overlay);
        c.adw_toolbar_view_set_content(@ptrCast(toolbar_view), content_box);

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

        // Tab overview: a grid of live thumbnails of every tab's pane
        // (AdwTabOverview snapshots each page child on open — the GL
        // panes render via the same paintable path as screenshots).
        // Wraps the whole toolbar view; a tab-count button in the
        // header toggles it, and its "+" creates a tab.
        const overview = c.adw_tab_overview_new();
        c.adw_tab_overview_set_view(@ptrCast(overview), @ptrCast(tab_view_w));
        c.adw_tab_overview_set_child(@ptrCast(overview), toolbar_view);
        c.adw_tab_overview_set_enable_new_tab(@ptrCast(overview), 1);
        _ = c.g_signal_connect_data(overview, "create-tab", @ptrCast(&onOverviewCreateTab), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        const tab_btn = c.adw_tab_button_new();
        c.adw_tab_button_set_view(@ptrCast(tab_btn), @ptrCast(tab_view_w));
        c.gtk_widget_set_tooltip_text(tab_btn, "Tab Overview");
        c.gtk_actionable_set_action_name(@ptrCast(tab_btn), "overview.open");
        // AdwHeaderBar spaces packed children against each other but
        // not against the window edge; without CSD window controls the
        // last pack_end child sits flush right. 6 px mirrors the pane
        // titlebar's margin convention.
        c.gtk_widget_set_margin_end(tab_btn, 6);
        c.adw_header_bar_pack_end(@ptrCast(header_bar), tab_btn);
        c.adw_application_window_set_content(@ptrCast(app_window), overview);

        // Double-click on the tab bar → rename the selected tab.
        // AdwTabBar handles single-click selection internally, so
        // by the time n_press == 2 fires, the tab is already current.
        const tabbar_dblclk = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(tabbar_dblclk), 1);
        _ = c.g_signal_connect_data(
            tabbar_dblclk,
            "pressed",
            @ptrCast(&tabchrome_mod.onTabBarPressed),
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
            @ptrCast(&tabchrome_mod.onTabBarScroll),
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
            .toast_overlay = @ptrCast(@alignCast(toast_overlay)),
            .tab_forest = TabForest.init(allocator),
            .content_box = @ptrCast(@alignCast(content_box)),
            .allocator = allocator,
            .config = if (config_override) |co| co else Config.load(allocator),
            .is_primary = is_primary,
            .id = next_window_id,
            .title_base = if (files_identity) FILES_TITLE else if (web_identity) WEB_TITLE else "sketerm",
            .search_bar = search_bar,
            .search_entry = search_entry,
            .search_label = search_label,
        };
        next_window_id += 1;

        // Browser frame cap: app-level like the IM strategy below, and
        // module-level in webface, which owns the one helper client.
        @import("webface.zig").setMaxFps(self.config.browser_max_fps);
        @import("webface.zig").setDiscardMinutes(self.config.web_discard_minutes);
        @import("webface.zig").setDownloadAsk(self.config.web_download_ask);
        @import("webface.zig").setPopupPolicy(switch (self.config.web_popup_policy) {
            .block_gestureless => .block_gestureless,
            .allow => .allow,
            .block_all => .block_all,
        });
        @import("webface.zig").setSearchEngine(self.config.web_search_engine);
        // Permission answers outlive the face that made them: the
        // daemon web store is where they go.
        @import("webface.zig").installStoreSiteSink(allocator);
        // IM strategy is an app-level key; every face reads it at
        // construction time (imhost.resolve).
        @import("imhost.zig").setPreference(switch (self.config.input_method) {
            .auto => .auto,
            .simple => .simple,
            .multi => .multi,
        });

        // The file-manager identity dresses EVERY window it owns. The
        // icon name matters on X11 (_NET_WM_ICON); on Wayland the icon
        // follows the app id / prgname main.zig sets, which is why files
        // mode is its own GApplication rather than a window flag.
        c.gtk_window_set_icon_name(@ptrCast(app_window), if (files_identity)
            FILES_ICON
        else if (web_identity)
            WEB_ICON
        else
            TERMINAL_ICON);
        if (files_identity) {
            c.gtk_window_set_title(@ptrCast(app_window), FILES_TITLE);
        } else if (web_identity) {
            c.gtk_window_set_title(@ptrCast(app_window), WEB_TITLE);
        }

        // Make this Zig Window reachable from its GtkWindow, so any
        // window can be found by walking gtk_application_get_windows
        // (cross-window pane resolution for IPC / `sketerm mux`).
        c.g_object_set_data(@ptrCast(@alignCast(app_window)), remotectl_mod.WINDOW_QDATA, @ptrCast(self));

        // Drag-a-tab-out-of-the-strip → new window.
        self.tabbar.detach_ctx = @ptrCast(self);
        self.tabbar.on_detach = onTabDetach;
        self.tabbar.transfer_ctx = @ptrCast(self);
        self.tabbar.on_transfer = onTabTransfer;
        // Right-click-a-tab → context menu.
        self.tabbar.context_ctx = @ptrCast(self);
        self.tabbar.on_context = tabchrome_mod.onTabContextMenu;
        // Let the tab effects read this window's live config (gates,
        // thresholds). The Config value is embedded in Window, so its
        // address is stable across applyConfigChange.
        self.tabbar.config = &self.config;

        // Honor the configured GTK theme (libadwaita otherwise ignores
        // it) so the user's tab styling applies to our real `tab` nodes.
        tabbar_mod.loadTheme(self.tabbar, self.config.gtk_theme);

        // Honour Config.show_tab_bar at startup. Default true matches
        // the GTK widget default; users can hide via config or the
        // toggle_tab_bar action at runtime.
        if (!self.config.show_tab_bar) c.gtk_widget_set_visible(self.tab_bar, 0);

        // Tree-style tabs: the strip hides pages inside a collapsed
        // subtree; the vertical sidebar renders the tree itself.
        self.tabbar.hidden_ctx = @ptrCast(self);
        self.tabbar.is_hidden = tabForestHiddenHook;
        if (tabsidebar_mod.Sidebar.create(allocator, self)) |sb| {
            self.tab_sidebar = sb;
            c.gtk_box_prepend(@ptrCast(content_box), sb.root);
            c.gtk_widget_set_visible(sb.root, @intFromBool(self.config.show_tab_sidebar));
        } else |err| {
            std.debug.print("sketerm: tab sidebar init failed: {s}\n", .{@errorName(err)});
        }

        // Search wiring.
        _ = c.g_signal_connect_data(search_entry, "search-changed", @ptrCast(&modes_mod.onSearchChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(search_entry, "activate", @ptrCast(&modes_mod.onSearchActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(search_entry, "stop-search", @ptrCast(&modes_mod.onSearchStop), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(prev_btn, "clicked", @ptrCast(&modes_mod.onSearchPrev), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(next_btn, "clicked", @ptrCast(&modes_mod.onSearchNext), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(close_btn, "clicked", @ptrCast(&modes_mod.onSearchClose), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Shift+Enter on the entry → previous (entry "activate" only
        // fires plain Enter; intercept via a key-controller).
        const search_keys = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(search_keys, "key-pressed", @ptrCast(&modes_mod.onSearchKeyPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
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

        // Tab ORDER changes shift every `{{ INDEX }}` after the moved
        // tab, so re-render the labels. Connected after the attach /
        // detach handlers above so the pane bookkeeping is already
        // settled by the time we walk it; a no-op unless a template
        // actually mentions the index.
        for ([_][*:0]const u8{ "page-reordered", "page-attached", "page-detached" }) |sig| {
            _ = c.g_signal_connect_data(
                tab_view_w,
                sig,
                @ptrCast(&onPageOrderChanged),
                @ptrCast(self),
                null,
                c.G_CONNECT_AFTER,
            );
        }

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
                    @ptrCast(&termsinks_mod.onNotifyActivate),
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
            @ptrCast(&tabchrome_mod.onSelectedPageChanged),
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
            @ptrCast(&winconfig_mod.onThemeChanged),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        installThemeFlipHook();

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

        // Translate `symbol_map.*` into the atlas's own type. Must run
        // before the first pane: applyPaneConfig hands the pane a slice
        // of this list, and an empty one meant a configured symbol map
        // did nothing at all until the first config reload.
        winconfig_mod.rebuildSymbolSpecs(self);

        // Background image / gradient layer.
        self.refreshBgSource();

        // Custom post-process shader.
        self.refreshShaderSource();

        // Auto shell-integration script discovery.
        self.resolveShellIntegration();

        // Live config reload: watch the file this process reads.
        @import("configwatch.zig").install(self);

        // Remote-control socket (sketerm cli). Failure is non-fatal:
        // the terminal works fine without scripting. Primary only —
        // the socket path is keyed on the pid, so a secondary window
        // would collide with (and clobber) the primary's socket.
        if (is_primary) {
            if (ipc_server.defaultSocketPath(allocator, files_identity)) |sock_path| {
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

        // Quake geometry replaces the 1000x700 default size. Primary
        // only: `--toggle` drives the primary window, and a secondary
        // is an ordinary window.
        if (is_primary) self.applyQuakeGeometry();

        return self;
    }

    pub fn deinit(self: *Window) void {
        self.destroying = true;
        self.detachGlobalSignals();
        // Teardown order matters. Steps:
        //
        // 1. Null every Terminal sink + user_ctx so any idle/deferred
        //    callback already queued on the main loop can't reach into
        //    a Pane via stale callback pointers — it sees the cleared
        //    sinks and produces no calls into Pane.
        // 2. Deinit terminals (removes fd watches and timers, detaches
        //    the daemon connections, frees parser + screen + pool).
        //    After this returns, no further terminal activity is
        //    possible against any of these terminals.
        // 3. Deinit panes (GL passes, atlas, IM context, arenas,
        //    GObject unrefs). Safe now that the terminal-side
        //    machinery is fully quiesced.
        //
        // Reversing #2 and #3 — the obvious order — would let a
        // late queued callback dispatch into a freed Pane.
        if (self.ack_timer_id != 0) {
            _ = c.g_source_remove(self.ack_timer_id);
            self.ack_timer_id = 0;
        }
        // Before anything else: a pending debounce timer would fire
        // into a half-torn-down window.
        @import("configwatch.zig").uninstall(self);
        // Relay-origin cleanup may close panel tabs and therefore mutate the
        // pane/terminal arrays. Finish it before iterating those arrays for
        // terminal teardown.
        while (true) {
            var origin: ?*Terminal = null;
            for (self.terminals.items) |terminal| {
                if (terminal.on_panel_origin_close != null) {
                    origin = terminal;
                    break;
                }
            }
            if (origin == null) {
                for (self.app_sessions.items) |app_session| {
                    if (app_session.terminal.on_panel_origin_close != null) {
                        origin = app_session.terminal;
                        break;
                    }
                }
            }
            const terminal = origin orelse break;
            terminal.closePanelOrigin();
        }
        for (self.panes.items) |p| p.detachAppHost();
        for (self.terminals.items) |t| t.clearSinks();
        for (self.terminals.items) |t| t.deinit();
        for (self.panes.items) |p| p.deinit();
        if (self.file_transfer_service) |service| file_transfers.release(service, @ptrCast(self));
        if (self.web_download_dir) |d| self.allocator.free(d);
        self.panes.deinit(self.allocator);
        self.terminals.deinit(self.allocator);
        // Tabless app sessions: detach (apps are durable — they keep
        // running in the daemon like any other session).
        for (self.app_sessions.items) |as| {
            if (as.reap_idle_id != 0) _ = c.g_source_remove(as.reap_idle_id);
            as.terminal.clearSinks();
            as.terminal.deinit();
            self.allocator.destroy(as);
        }
        self.app_sessions.deinit(self.allocator);
        // In-flight async reattaches: mark canceled so their idle
        // callbacks drop results without touching the freed window
        // (each idle frees its own job).
        for (self.mux_restore_jobs.items) |job| job.canceled = true;
        self.mux_restore_jobs.deinit(self.allocator);
        for (self.zoom_hidden.items) |w| c.g_object_unref(w);
        self.zoom_hidden.deinit(self.allocator);
        for (self.notify_slots.items) |slot| self.allocator.free(slot.id);
        self.notify_slots.deinit(self.allocator);
        self.search_matches.deinit(self.allocator);
        @import("hints.zig").freeMatches(self.allocator, self.hint_matches);
        self.allocator.free(self.hint_matches);
        self.hints_overlay_buf.deinit(self.allocator);
        self.hints_collected.deinit(self.allocator);
        self.symbol_specs.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.closed_tabs.deinit(self.allocator);
        if (self.closed_arena) |*a| a.deinit();
        if (self.ipc) |srv| srv.deinit(); // frees ipc_path (server owns it)
        if (self.bg_source.pixels) |px| c.stbi_image_free(px);
        if (self.shader_source.src) |s| self.allocator.free(s);
        if (self.shader_source.dir) |d| self.allocator.free(d);
        if (self.si_zsh_script) |s| self.allocator.free(s);
        if (self.si_fish_script) |s| self.allocator.free(s);
        if (self.si_bash_script) |s| self.allocator.free(s);
        if (self.si_zsh_shim) |s| self.allocator.free(s);
        if (self.si_fish_shim) |s| self.allocator.free(s);
        if (self.si_bash_shim) |s| self.allocator.free(s);
        if (self.tab_sidebar) |sb| sb.deinit();
        self.tab_sidebar = null;
        self.tab_forest.deinit();
        self.config.deinit();
        self.allocator.destroy(self);
    }

    /// Drop every signal handler this Window installed on an object
    /// that OUTLIVES it — the `AdwStyleManager` singleton and the
    /// application's own action map. Both are process-global, so a
    /// handler left behind dispatches into freed memory the next time
    /// the desktop flips light/dark or a notification is activated.
    ///
    /// Mechanism 2 of CLAUDE.md's memory-ownership rules (disconnect at
    /// teardown, `G_SIGNAL_MATCH_DATA`), which is sound here because
    /// `deinit` is the single choke point every teardown path reaches:
    /// a secondary window's `onWindowDestroyed` -> `deferredWindowFree`
    /// idle, and `shutdownWindow` in `main.zig` for app shutdown.
    /// A `GDestroyNotify` (mechanism 1) is wrong for the same reason —
    /// the data must outlive the widgets, not die with them.
    fn detachGlobalSignals(self: *Window) void {
        _ = c.g_signal_handlers_disconnect_matched(
            @as(c.gpointer, @ptrCast(c.adw_style_manager_get_default())),
            c.G_SIGNAL_MATCH_DATA,
            0,
            0,
            null,
            null,
            @as(c.gpointer, @ptrCast(self)),
        );

        // "notify-act" is registered ONCE, by whichever window found it
        // missing, and its GSimpleAction lives as long as the
        // application. Take the action away with the handler rather
        // than leave an inert one behind: the next window's init sees
        // it missing again and re-registers against itself.
        //
        // `gtk_window_get_application` is useless from here — GTK has
        // already unlinked a destroyed window from its application.
        if (c.g_application_get_default()) |gapp| {
            if (c.g_action_map_lookup_action(@ptrCast(gapp), "notify-act")) |act| {
                const n = c.g_signal_handlers_disconnect_matched(
                    @as(c.gpointer, @ptrCast(act)),
                    c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    null,
                    @as(c.gpointer, @ptrCast(self)),
                );
                if (n > 0) c.g_action_map_remove_action(@ptrCast(gapp), "notify-act");
            }
        }
    }

    // ── Tab chrome: split out to ui/tabchrome.zig ──
    const tabchrome = @import("tabchrome.zig");
    pub const scheduleTabAck = tabchrome.scheduleTabAck;
    pub const setTabColor = tabchrome.setTabColor;
    pub const setTabProgress = tabchrome.setTabProgress;
    pub const setTabCmdStatus = tabchrome.setTabCmdStatus;
    pub const updateTaskbarProgress = tabchrome.updateTaskbarProgress;
    pub const tabColorOf = tabchrome.tabColorOf;
    pub const parseHexRGB = tabchrome.parseHexRGB;
    const addTabMenuAction = tabchrome.addTabMenuAction;
    const addTabMenuToggle = tabchrome.addTabMenuToggle;
    const onTabMenuActionClicked = tabchrome.onTabMenuActionClicked;
    const onTabMenuToggled = tabchrome.onTabMenuToggled;
    const iconTexture64 = tabchrome.iconTexture64;
    const drawTabCmdDot = tabchrome.drawTabCmdDot;
    const chooseTabColor = tabchrome.chooseTabColor;
    const onTabColorChosen = tabchrome.onTabColorChosen;
    const pageStillOpen = tabchrome.pageStillOpen;

    // ── Terminal sink callbacks: split out to ui/termsinks.zig ──
    const termsinks = @import("termsinks.zig");

    // ── Config / profiles / shaders: split out to ui/winconfig.zig ──
    const winconfig = @import("winconfig.zig");
    pub const findProfile = winconfig.findProfile;
    pub const setPaneShaderParam = winconfig.setPaneShaderParam;
    pub const applyShaderPresetByName = winconfig.applyShaderPresetByName;
    pub const setShaderParam = winconfig.setShaderParam;
    pub const applyPaneConfigByName = winconfig.applyPaneConfigByName;
    pub const applyPaneConfig = winconfig.applyPaneConfig;
    pub const openProfilePicker = winconfig.openProfilePicker;
    pub const openApplyProfilePicker = winconfig.openApplyProfilePicker;
    pub const applyProfileToPane = winconfig.applyProfileToPane;
    pub const openShaderPresetPicker = winconfig.openShaderPresetPicker;
    /// winconfig's pane push, then the faces that keep their own
    /// resolved copies. Editor faces MUST re-read here: their settings
    /// came out of the config arena winconfig just freed.
    pub fn applyConfigChange(self: *Window, new_cfg: *const Config) void {
        self.applyConfigChangeOpts(new_cfg, .{});
    }
    pub fn applyConfigChangeOpts(self: *Window, new_cfg: *const Config, opts: winconfig.ApplyOpts) void {
        winconfig.applyConfigChangeOpts(self, new_cfg, opts);
        for (self.panes.items) |p| {
            if (@import("editorview.zig").EditorView.fromPane(p)) |ev| ev.syncConfig();
        }
    }
    pub const refreshBindings = winconfig.refreshBindings;
    pub const reloadConfigFromDisk = winconfig.reloadConfigFromDisk;
    const pickPaneShader = winconfig.pickPaneShader;
    const shaderPresetDirZ = winconfig.shaderPresetDirZ;
    const repointShaderOverrides = winconfig.repointShaderOverrides;
    const clearPaneShader = winconfig.clearPaneShader;
    const resolvePalette = winconfig.resolvePalette;
    const presentPanePopover = winconfig.presentPanePopover;
    const addApplyProfileButtons = winconfig.addApplyProfileButtons;
    const resolveDefaultColors = winconfig.resolveDefaultColors;
    const resolveColorsFor = winconfig.resolveColorsFor;
    pub const openPrefs = winconfig.openPrefs;
    const persistConfig = winconfig.persistConfig;
    const refreshBgSource = winconfig.refreshBgSource;
    const refreshShaderSource = winconfig.refreshShaderSource;
    const refreshTitlebarCss = winconfig.refreshTitlebarCss;

    // ── Layout persistence: split out to ui/winlayout.zig ──
    const winlayout = @import("winlayout.zig");
    pub const newTabFromSpec = winlayout.newTabFromSpec;
    pub const restoreLastClosed = winlayout.restoreLastClosed;
    pub const loadLayoutDefault = winlayout.loadLayoutDefault;
    pub const loadLayoutFromPath = winlayout.loadLayoutFromPath;
    pub const collectLayout = winlayout.collectLayout;
    pub const saveLayoutAs = winlayout.saveLayoutAs;
    pub const loadLayoutAs = winlayout.loadLayoutAs;
    pub const saveLayoutQuietly = winlayout.saveLayoutQuietly;
    pub const duplicateCurrentTab = winlayout.duplicateCurrentTab;
    pub const saveDefaultLayout = winlayout.saveDefaultLayout;
    pub const loadDefaultLayoutIfPresent = winlayout.loadDefaultLayoutIfPresent;
    const restorePaneShader = winlayout.restorePaneShader;
    const buildTreeWidget = winlayout.buildTreeWidget;
    const captureClosedTab = winlayout.captureClosedTab;
    const loadLayoutSimple = winlayout.loadLayoutSimple;
    const collectTree = winlayout.collectTree;
    const paneSpec = winlayout.paneSpec;
    const modelTreeToLayout = winlayout.modelTreeToLayout;
    const verifyTreeModel = winlayout.verifyTreeModel;
    const verifyAllTabs = winlayout.verifyAllTabs;
    const verifyTabForest = winlayout.verifyTabForest;
    const widgetMatchesNode = winlayout.widgetMatchesNode;
    const saveLayoutToDefault = winlayout.saveLayoutToDefault;

    // ── Hints / search / copy mode: split out to ui/modes.zig ──
    const modes = @import("modes.zig");
    pub const openHints = modes.openHints;
    pub const exitHints = modes.exitHints;
    pub const openSearch = modes.openSearch;
    pub const closeSearch = modes.closeSearch;
    pub const openCopyMode = modes.openCopyMode;
    pub const exitCopyMode = modes.exitCopyMode;
    const refreshHintOverlay = modes.refreshHintOverlay;
    const activateHint = modes.activateHint;
    const openPathInEditor = modes.openPathInEditor;
    const updateSearch = modes.updateSearch;
    const refreshSearchLabel = modes.refreshSearchLabel;
    const applyCurrentMatch = modes.applyCurrentMatch;
    const nextMatch = modes.nextMatch;
    const prevMatch = modes.prevMatch;
    const handleCopyModeKey = modes.handleCopyModeKey;
    const copyModeToggleSel = modes.copyModeToggleSel;
    const copyModeMoveTo = modes.copyModeMoveTo;
    const WordDir = modes.WordDir;
    const copyModeWord = modes.copyModeWord;
    const copyModeYank = modes.copyModeYank;
    const copyModeRefresh = modes.copyModeRefresh;

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
        // Re-resolve the geometry on every reveal: with
        // `quake_monitor = active` the target follows the pointer's
        // monitor, and monitors come and go.
        self.applyQuakeGeometry();
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

    /// Size the window per the `quake_*` config against its target
    /// monitor. No-op unless `quake_enabled`.
    ///
    /// What actually reaches the compositor: the SIZE (always) and
    /// the MONITOR (only when the requested coverage is the whole
    /// screen, since `gtk_window_fullscreen_on_monitor` is the sole
    /// GTK4 call that names one). The EDGE cannot be applied at all —
    /// GTK4 has no toplevel-positioning API on any backend and
    /// Wayland forbids self-placement — so a partial-size quake
    /// window lands wherever the compositor puts it. See
    /// `ui/quake.zig`.
    pub fn applyQuakeGeometry(self: *Window) void {
        if (!self.config.quake_enabled) return;
        const window: *c.GtkWindow = @ptrCast(@alignCast(self.app_window));
        const wp = self.config.quake_width_percent;
        const hp = self.config.quake_height_percent;
        const monitor = self.quakeMonitor();

        if (quake.coversMonitor(wp, hp)) {
            if (monitor) |m| {
                c.gtk_window_fullscreen_on_monitor(window, m);
                return;
            }
            c.gtk_window_fullscreen(window);
            return;
        }
        c.gtk_window_unfullscreen(window);

        var geo: c.GdkRectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (monitor) |m| c.gdk_monitor_get_geometry(m, &geo);
        if (geo.width <= 0 or geo.height <= 0) return;
        const want = quake.geometry(
            .{ .x = geo.x, .y = geo.y, .w = geo.width, .h = geo.height },
            wp,
            hp,
            self.config.quake_edge,
        );
        c.gtk_window_set_default_size(window, want.w, want.h);
    }

    /// The `GdkMonitor` `quake_monitor` names, or null when the
    /// display has none. Ownership: `g_list_model_get_item` returns a
    /// ref we drop immediately — the display owns its monitors and
    /// outlives any use here.
    fn quakeMonitor(self: *Window) ?*c.GdkMonitor {
        const display = c.gtk_widget_get_display(self.app_window) orelse return null;
        const spec = quake.parseMonitor(self.config.quake_monitor);
        if (spec == .active) {
            if (c.gtk_native_get_surface(@ptrCast(@alignCast(self.app_window)))) |surface| {
                if (c.gdk_display_get_monitor_at_surface(display, surface)) |m| return m;
            }
        }
        const monitors = c.gdk_display_get_monitors(display) orelse return null;
        const n = c.g_list_model_get_n_items(@ptrCast(@alignCast(monitors)));
        if (n == 0) return null;
        const wanted: u32 = switch (spec) {
            .index => |i| i,
            .connector => |name| blk: {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const item = c.g_list_model_get_item(@ptrCast(@alignCast(monitors)), i) orelse continue;
                    defer c.g_object_unref(item);
                    const conn = c.gdk_monitor_get_connector(@ptrCast(@alignCast(item)));
                    if (conn != null and std.mem.eql(u8, std.mem.span(conn), name)) break :blk i;
                }
                break :blk 0;
            },
            // `active` only lands here when the window has no surface
            // yet (first show), where the first monitor is the best
            // guess available.
            .active, .primary => 0,
        };
        const idx = if (wanted < n) wanted else 0;
        const item = c.g_list_model_get_item(@ptrCast(@alignCast(monitors)), idx) orelse return null;
        c.g_object_unref(item);
        return @ptrCast(@alignCast(item));
    }

    /// Spawn a new shell pane and add it as a tab.
    /// If title == null, a "Tab N" default is used.
    pub fn newShellTab(self: *Window, title_opt: ?[*:0]const u8) !void {
        return self.newShellTabWithProfile(title_opt, null);
    }

    /// New tab whose pane wears the file-browser face (the shell
    /// session underneath stays one toolbar click away).
    pub fn newBrowserTab(self: *Window) !void {
        try self.newBrowserTabAt(null);
    }

    /// Browser tab starting at `spec` (host-qualified allowed); null
    /// = the focused pane's location.
    pub fn newBrowserTabAt(self: *Window, spec: ?[]const u8) !void {
        try self.newBrowserTabFrom(self.focusedPane(), spec);
    }

    /// Browser tab starting at `spec`, else at `origin`'s host-qualified
    /// location. `origin` is the pane the request came FROM (the
    /// invoking pane for `sketerm files --tab`), never the pane that
    /// ends up wearing the browser face.
    pub fn newBrowserTabFrom(self: *Window, origin: ?*Pane, spec: ?[]const u8) !void {
        return self.newBrowserTabFromReveal(origin, spec, null);
    }

    pub fn newBrowserTabFromReveal(self: *Window, origin: ?*Pane, spec: ?[]const u8, reveal: ?[]const u8) !void {
        var spec_buf: [@import("browser.zig").SPEC_BUF_LEN]u8 = undefined;
        const start_spec: ?[]const u8 = if (spec) |s|
            files_entry.startLocation(&spec_buf, s)
        else if (origin) |p|
            paneBrowserSpec(p, &spec_buf)
        else
            null;
        // Take the pane the tab spawn APPENDED, exactly like
        // newBrowserSplit: focus does not reliably sit on the fresh
        // pane, and attaching to the focused one turned a PRE-EXISTING
        // pane into a browser while the new tab kept an unused shell.
        const before = self.panes.items.len;
        try self.newShellTab("Files");
        if (self.panes.items.len <= before) return error.TabSpawnFailed;
        const pane = self.panes.items[self.panes.items.len - 1];
        const bv = @import("browser.zig").BrowserView.attach(self.allocator, pane, start_spec) catch |err| {
            logActionError("new_browser_tab attach", err);
            return err;
        };
        self.installBrowserHooks(bv);
        if (reveal) |target| bv.queueReveal(target);
    }

    /// New tab whose pane wears the WEB face (src/ui/webface.zig): a
    /// browser view served by the `sketerm-webengine` helper. The shell
    /// session underneath stays one toolbar click away, exactly like
    /// the file-browser and editor faces.
    pub fn newWebTab(self: *Window) !void {
        try self.newWebTabAt(null);
    }

    /// Web tab opening `url`; null = an empty address bar. Also the
    /// landing point for a page's popup request (target=_blank).
    pub fn newWebTabAt(self: *Window, url: ?[]const u8) !void {
        // Same appended-pane rule as newBrowserTabFromReveal: focus
        // does not reliably sit on the fresh pane.
        const before = self.panes.items.len;
        try self.newShellTab("Web");
        if (self.panes.items.len <= before) return error.TabSpawnFailed;
        const pane = self.panes.items[self.panes.items.len - 1];
        _ = @import("webface.zig").WebFace.attach(self.allocator, pane, url) catch |err| {
            logActionError("new_web_tab attach", err);
            return err;
        };
    }

    /// Fill this window with the web tabs a `sketerm web [urls...]`
    /// invocation asked for: one tab per address, or a single blank tab
    /// (address entry focused) when none were given.
    pub fn openWebTabs(self: *Window, urls: []const []u8) !void {
        if (urls.len == 0) return self.newWebTabAt(null);
        for (urls) |url| try self.newWebTabAt(url);
    }

    /// A repeat launch of the browser identity (`sketerm web` again):
    /// another web window, the way a browser behaves.
    pub fn openWebWindow(self: *Window, urls: []const []u8) !*Window {
        const win = self.spawnSecondaryWindow() orelse return error.WindowSpawnFailed;
        try win.openWebTabs(urls);
        return win;
    }

    /// Split the focused pane and give the new pane a web face.
    pub fn newWebSplit(self: *Window, orient: c_uint) !void {
        const before = self.panes.items.len;
        try self.splitFocused(orient);
        if (self.panes.items.len <= before) return error.SplitFailed;
        const pane = self.panes.items[self.panes.items.len - 1];
        _ = @import("webface.zig").WebFace.attach(self.allocator, pane, null) catch |err| {
            logActionError("new_web_split attach", err);
            return err;
        };
    }

    /// `web_discard_background`: let go of every web page that is not
    /// on screen, right now. The panes keep their last frame; each
    /// reloads when it is next looked at.
    pub fn discardBackgroundWebTabs(self: *Window) void {
        const webface = @import("webface.zig");
        if (!webface.discardSupported()) {
            showToast(self, "The browser helper in use cannot discard pages.");
            return;
        }
        const n = webface.discardBackground();
        if (n == 0) {
            showToast(self, "No background web pages to discard.");
            return;
        }
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Discarded {d} background web page{s}.", .{
            n,
            if (n == 1) "" else "s",
        }) catch return;
        showToast(self, msg);
    }

    /// A palette verb that only means something on a pane wearing the
    /// WEB face. A pane without one is told so, rather than left
    /// wondering why the action did nothing.
    pub fn webFaceAction(self: *Window, what: enum { devtools, print_pdf, fill_password }) void {
        const pane = self.focusedPane() orelse return;
        const face = @import("webface.zig").WebFace.fromPane(pane) orelse {
            showToast(self, "This pane has no web page. Use New Web Tab.");
            return;
        };
        switch (what) {
            .devtools => face.openDevTools(),
            .print_pdf => face.printToPdf(),
            .fill_password => face.fillPassword(),
        }
    }

    /// Split `source` and give the new pane a web face bound to an
    /// EXISTING helper-side view — the inspector `devtools_show`
    /// minted for the page in `source` (src/ui/webface.zig).
    ///
    /// `splitPane`, not `splitFocused`: the reply that brings the view
    /// id arrives from the socket, by which time focus may sit
    /// anywhere, and splitting the wrong pane would put DevTools
    /// beside a page it does not inspect.
    pub fn openDevToolsSplit(self: *Window, source: *Pane, view: u32) !void {
        const before = self.panes.items.len;
        try self.splitPane(source, @intCast(c.GTK_ORIENTATION_HORIZONTAL));
        if (self.panes.items.len <= before) return error.SplitFailed;
        const pane = self.panes.items[self.panes.items.len - 1];
        _ = @import("webface.zig").WebFace.attachView(self.allocator, pane, view) catch |err| {
            logActionError("web_devtools attach", err);
            return err;
        };
    }

    /// New tab whose pane wears the text-editor face (the shell
    /// session underneath stays one toolbar click away).
    pub fn newEditorTab(self: *Window) !void {
        try self.newEditorTabAt(null);
    }

    /// Editor tab opening `spec` (host-qualified allowed); null = an
    /// empty Untitled buffer.
    pub fn newEditorTabAt(self: *Window, spec: ?[]const u8) !void {
        // Same appended-pane rule as newBrowserTabFromReveal.
        const before = self.panes.items.len;
        try self.newShellTab("Editor");
        if (self.panes.items.len <= before) return error.TabSpawnFailed;
        const pane = self.panes.items[self.panes.items.len - 1];
        _ = @import("editorview.zig").EditorView.attach(self.allocator, pane, spec) catch |err| {
            logActionError("new_editor_tab attach", err);
            return err;
        };
    }

    /// Split the focused pane and give the new pane an editor face,
    /// on the same empty Untitled buffer `new_editor_tab` starts from.
    pub fn newEditorSplit(self: *Window, orient: c_uint) !void {
        // Take the pane the split APPENDED: focus may still sit on the
        // source pane, and attaching there would turn an existing pane
        // into an editor instead of the new one.
        const before = self.panes.items.len;
        try self.splitFocused(orient);
        if (self.panes.items.len <= before) return error.SplitFailed;
        const pane = self.panes.items[self.panes.items.len - 1];
        _ = @import("editorview.zig").EditorView.attach(self.allocator, pane, null) catch |err| {
            logActionError("new_editor_split attach", err);
            return err;
        };
    }

    /// Put an editor face on `pane` itself (the browser's "Edit in
    /// Sketerm Editor"). A pane already wearing one gains a document
    /// tab instead (attach handles that).
    pub fn openEditorOn(self: *Window, pane: *Pane, spec: ?[]const u8) !void {
        _ = try @import("editorview.zig").EditorView.attach(self.allocator, pane, spec);
    }

    /// Unsaved editor tabs across every pane of this window.
    pub fn editorDirtyTotal(self: *Window) usize {
        var n: usize = 0;
        for (self.panes.items) |p| {
            if (@import("editorview.zig").EditorView.fromPane(p)) |ev| n += ev.dirtyCount();
        }
        return n;
    }

    /// Put a browser face on `pane` itself (`sketerm files --here`):
    /// the pane's shell stays alive underneath, one toolbar click away.
    /// A pane that ALREADY wears a browser face gains a browser tab
    /// instead -- re-attaching is a no-op that would silently drop the
    /// requested location.
    pub fn openBrowserHere(self: *Window, pane: *Pane, spec: ?[]const u8) !void {
        const browser_mod = @import("browser.zig");
        var spec_buf: [browser_mod.SPEC_BUF_LEN]u8 = undefined;
        const start_spec: ?[]const u8 = if (spec) |s|
            files_entry.startLocation(&spec_buf, s)
        else
            paneBrowserSpec(pane, &spec_buf);
        if (browser_mod.BrowserView.fromPane(pane)) |bv| {
            if (start_spec) |s| _ = bv.newTabSpec(s);
            return;
        }
        const bv = try browser_mod.BrowserView.attach(self.allocator, pane, start_spec);
        self.installBrowserHooks(bv);
    }

    /// Split the focused pane and give the new pane a browser face:
    /// the way a dual-pane (source/target) layout is created.
    pub fn newBrowserSplit(self: *Window, orient: c_uint) !void {
        // Outlives the block: currentSpec writes into the caller's buffer.
        var spec_buf: [@import("browser.zig").SPEC_BUF_LEN]u8 = undefined;
        const start_cwd: ?[]const u8 = blk: {
            const focused = self.focusedPane() orelse break :blk null;
            if (@import("browser.zig").BrowserView.fromPane(focused)) |bv| break :blk bv.currentSpec(&spec_buf);
            break :blk paneBrowserSpec(focused, &spec_buf);
        };
        // Take the pane the split APPENDED: focus may still sit on the
        // source pane's browser widget, and attaching there would be a
        // no-op on the pane that already has a browser.
        const before = self.panes.items.len;
        try self.splitFocused(orient);
        if (self.panes.items.len <= before) return error.SplitFailed;
        const pane = self.panes.items[self.panes.items.len - 1];
        const bv = @import("browser.zig").BrowserView.attach(self.allocator, pane, start_cwd) catch |err| {
            logActionError("new_browser_split attach", err);
            return err;
        };
        self.installBrowserHooks(bv);
    }

    /// The process-shared durable transfer service, acquired on first
    /// use. Null only when the ledger directory is unusable.
    pub fn transferService(self: *Window) ?*file_transfers.Service {
        if (self.file_transfer_service == null) {
            self.file_transfer_service = file_transfers.acquire(
                self.allocator,
                @ptrCast(self),
                &browserTransferNotify,
            ) catch null;
        }
        return self.file_transfer_service;
    }

    /// Give a browser face its window-level abilities: durable
    /// terminal tabs on any host, and app-forwarded remote opens.
    pub fn installBrowserHooks(self: *Window, bv: *@import("browser.zig").BrowserView) void {
        bv.transfer_service = self.transferService();
        // Client-mediated transfers need a browser face with both host
        // connections; the service hands over any whose owner is gone.
        if (self.file_transfer_service) |service|
            service.addMediatedDriver(
                @ptrCast(bv),
                &@import("browser/jobs.zig").adoptMediated,
                &@import("browser/ops.zig").adoptPasteBatch,
                &@import("browser/jobs.zig").refreshJobsPanel,
            );
        bv.hooks_ctx = @ptrCast(self);
        bv.on_peer = &browserPeerCb;
        bv.on_host_term = &browserHostTermCb;
        bv.on_host_open = &browserHostOpenCb;
        bv.on_host_exec = &browserHostExecCb;
    }

    /// The other browser face in `pane`'s tab, from the pane-tree
    /// MODEL (correct while a pane is zoomed). Exactly two browser
    /// faces make a dual-pane pair; with more, the first other one
    /// wins so the destination stays deterministic.
    fn browserPeerCb(ctx: *anyopaque, pane: *Pane) ?*@import("browser.zig").BrowserView {
        const self: *Window = @ptrCast(@alignCast(ctx));
        const page = tabPageForPane(self, pane) orelse return null;
        const tree = Window.tabTreeOf(page) orelse return null;
        var leaves: std.ArrayList(*Pane) = .empty;
        defer leaves.deinit(self.allocator);
        tree.appendLeaves(self.allocator, &leaves) catch return null;
        for (leaves.items) |leaf| {
            if (leaf == pane) continue;
            if (@import("browser.zig").BrowserView.fromPane(leaf)) |bv| return bv;
        }
        return null;
    }

    fn browserTransferNotify(ctx: *anyopaque, text: []const u8) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        showToast(self, text);
    }

    fn browserHostTermCb(ctx: *anyopaque, host: []const u8, path: []const u8) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        const h: ?[]const u8 = if (host.len > 0) host else null;
        self.newDurableSessionAt(h, path) catch |err|
            logActionError("browser terminal-here", err);
    }

    fn browserHostExecCb(ctx: *anyopaque, host: []const u8, cmdline: []const u8) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        const h: ?[]const u8 = if (host.len > 0) host else null;
        const argv = [_][]const u8{ "/bin/sh", "-c", cmdline };
        self.launchRemoteAppSession(h, &argv, false) catch |err|
            logActionError("browser action-exec", err);
    }

    fn browserHostOpenCb(ctx: *anyopaque, host: []const u8, path: []const u8) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        const h: ?[]const u8 = if (host.len > 0) host else null;
        const argv = [_][]const u8{ "xdg-open", path };
        self.launchRemoteAppSession(h, &argv, false) catch |err|
            logActionError("browser open-on-host", err);
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
    pub fn addTabWithProfile(
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

        const page = self.appendOrInsertTab(wrapper, .{ .leaf = pane }, false);
        c.adw_tab_page_set_title(page, title_z);
        c.adw_tab_page_set_tooltip(page, title_z);
    }

    /// Host-qualified browser location for `pane`: its last-reported
    /// cwd (OSC 7) on the host its session actually runs on. A remote
    /// pane's cwd is a path on THAT host, so passing the bare path to a
    /// browser face would open a local directory that usually does not
    /// exist. Writes into `buf`; null when the pane reported no cwd.
    fn paneBrowserSpec(pane: *Pane, buf: []u8) ?[]const u8 {
        const raw: ?[]const u8 = if (pane.terminal.remote) |r| r.host else null;
        const host = @import("../filebrowser/paths.zig").browserHost(raw);
        return files_entry.startSpec(buf, host, pane.terminal.cwd);
    }

    /// "Open in Sketerm Files": hand the focused pane's host-qualified
    /// location to the SEPARATE file-manager application by spawning
    /// our own executable as `sketerm files <spec>`. GApplication
    /// uniqueness forwards a second invocation into an already-running
    /// files instance, so this either starts it or reaches it. The
    /// child inherits this process's environment (an isolated test rig
    /// keeps its own XDG dirs / app id); without G_SPAWN_DO_NOT_REAP_CHILD
    /// GLib reaps the child itself, so no zombie and nothing for us to
    /// waitpid.
    fn openInFilesApp(self: *Window) void {
        var spec_buf: [@import("browser.zig").SPEC_BUF_LEN]u8 = undefined;
        const spec: ?[]const u8 = if (self.focusedPane()) |p|
            paneBrowserSpec(p, &spec_buf)
        else
            null;

        // Connection-ticket brokering: when the focused pane's session
        // runs on a host we reach over UDP, pre-mint a ticket over
        // that live connection and hand it to the files process via
        // env — it then dials the daemon directly, no ssh bootstrap.
        // The spawn is deferred by one daemon round trip (bounded 3s);
        // any failure degrades to the plain spawn.
        if (spec != null) blk: {
            const pane = self.focusedPane() orelse break :blk;
            const remote = pane.terminal.remote orelse break :blk;
            const bare = @import("../filebrowser/paths.zig").browserHost(remote.host) orelse break :blk;
            const launch = self.allocator.create(FilesLaunch) catch break :blk;
            launch.* = .{
                .allocator = self.allocator,
                .spec = self.allocator.dupe(u8, spec.?) catch {
                    self.allocator.destroy(launch);
                    break :blk;
                },
                .host = self.allocator.dupe(u8, bare) catch {
                    self.allocator.free(launch.spec);
                    self.allocator.destroy(launch);
                    break :blk;
                },
            };
            if (self.mintUdpTicket(bare, @ptrCast(launch), onFilesLaunchTicket)) return;
            self.allocator.free(launch.spec);
            self.allocator.free(launch.host);
            self.allocator.destroy(launch);
        }

        if (!spawnFilesProcess(spec, null, null)) {
            showToast(self, "Sketerm Files: launch failed");
        }
    }

    /// Deferred `openInFilesApp` spawn: self-contained (the Window may
    /// have closed during the mint round trip, so nothing here may
    /// touch it — a launch failure logs instead of toasting).
    const FilesLaunch = struct {
        allocator: std.mem.Allocator,
        spec: []u8,
        host: []u8,
    };

    fn onFilesLaunchTicket(ctx: ?*anyopaque, ticket: ?@import("../mux/client.zig").UdpTicket) void {
        const l = cast.userData(FilesLaunch, ctx);
        const host: ?[]const u8 = if (ticket != null) l.host else null;
        if (!spawnFilesProcess(l.spec, host, ticket)) {
            std.debug.print("sketerm: files launch failed (deferred spawn)\n", .{});
        }
        l.allocator.free(l.spec);
        l.allocator.free(l.host);
        l.allocator.destroy(l);
    }

    /// Spawn the files application. Window-independent (callable from
    /// a deferred callback after the spawning Window closed). A
    /// non-null ticket rides $SKETERM_UDP_TICKET in the child's env.
    fn spawnFilesProcess(
        spec: ?[]const u8,
        ticket_host: ?[]const u8,
        ticket: ?@import("../mux/client.zig").UdpTicket,
    ) bool {
        var exe_buf: [4096:0]u8 = undefined;
        const exe = @import("../util/platform.zig").exePathZ(&exe_buf) orelse return false;

        // Prefer the sibling `sketerm-files` binary: taskbars that
        // match windows by process/cmdline see a distinct executable
        // instead of `sketerm files`, which they merge with the
        // terminal's entry. Fall back to the subcommand spelling when
        // the sibling is absent (dev tree before install).
        var files_buf: [4096:0]u8 = undefined;
        const sibling: ?[*:0]const u8 = blk: {
            const dir_end = std.mem.lastIndexOfScalar(u8, exe, '/') orelse break :blk null;
            const p = std.fmt.bufPrintZ(&files_buf, "{s}/sketerm-files", .{exe[0..dir_end]}) catch break :blk null;
            if (c.access(p.ptr, c.X_OK) != 0) break :blk null;
            break :blk p.ptr;
        };

        var spec_z_buf: [@import("browser.zig").SPEC_BUF_LEN + 1]u8 = undefined;
        var argv: [4][*c]u8 = @splat(null);
        var n: usize = 0;
        if (sibling) |fb| {
            argv[n] = @constCast(@as([*c]const u8, fb));
            n += 1;
        } else {
            argv[n] = @constCast(@as([*c]const u8, exe.ptr));
            argv[n + 1] = @constCast(@as([*c]const u8, "files"));
            n += 2;
        }
        if (spec) |s| {
            if (std.fmt.bufPrintZ(&spec_z_buf, "{s}", .{s})) |z| {
                argv[n] = @constCast(@as([*c]const u8, z.ptr));
            } else |_| {}
        }

        // A ticket rides the child's env; envp == null keeps plain
        // inheritance (isolated test rigs keep their XDG dirs / app id).
        var envp: [*c][*c]c.gchar = null;
        var ticket_buf: [512:0]u8 = undefined;
        if (ticket) |t| if (ticket_host) |h| {
            if (std.fmt.bufPrintZ(&ticket_buf, "{s} {d} {s}", .{ h, t.port, t.keyhex() })) |v| {
                envp = c.g_environ_setenv(c.g_get_environ(), "SKETERM_UDP_TICKET", v.ptr, 1);
            } else |_| {}
        };
        defer if (envp != null) c.g_strfreev(envp);

        var gerr: [*c]c.GError = null;
        const ok = c.g_spawn_async(
            null,
            &argv,
            envp,
            @intCast(c.G_SPAWN_DEFAULT),
            null,
            null,
            null,
            &gerr,
        );
        if (ok == 0) {
            if (gerr != null) c.g_error_free(gerr);
            return false;
        }
        return true;
    }

    /// Last-reported cwd of the focused pane (OSC 7), or null if no
    /// pane has the focus or no cwd has been reported. Bare path, for
    /// spawning a shell -- browser faces want `paneBrowserSpec`.
    pub fn focusedPaneCwd(self: *Window) ?[]const u8 {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return null;
        for (self.panes.items) |p| {
            if (focus == @as(*c.GtkWidget, @ptrCast(p.surface.area))) {
                return p.terminal.cwd;
            }
        }
        return null;
    }

    pub fn addTabInternal(
        self: *Window,
        title_z: [*:0]const u8,
        argv: []const [*:0]const u8,
        cwd: ?[]const u8,
    ) !void {
        // Convert the null-terminated argv to slices for the wire spawn.
        var argv_slices: std.ArrayList([]const u8) = .empty;
        defer argv_slices.deinit(self.allocator);
        for (argv) |a| try argv_slices.append(self.allocator, std.mem.span(a));

        // Daemon-backed pane (the factory tracks it in panes/terminals).
        const pane = try self.daemonSpawnPane(.{
            .argv = argv_slices.items,
            .cwd = cwd,
            .login_shell = self.config.settings.login_shell,
            .si = self.shellIntegrationFor(argv[0]),
        });
        pane.setSpawnArgv(argv);

        // Wrap pane.widget() in a Box so we can swap it for a Paned
        // when splits happen. Box always has exactly one child.
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_box_append(@ptrCast(wrapper), pane.widget());

        const page = self.appendOrInsertTab(wrapper, .{ .leaf = pane }, false);
        c.adw_tab_page_set_title(page, title_z);
        // Full-title tooltip — useful when titles are truncated.
        c.adw_tab_page_set_tooltip(page, title_z);
    }

    pub fn makePane(self: *Window, term: *Terminal) !*Pane {
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
        pane.surface.image_store.debug = self.debug_images;
        pane.surface.image_store.budget_bytes = @as(usize, self.config.image_memory_mb) * 1024 * 1024;
        pane.surface.image_pass.debug = self.debug_images;
        pane.terminal.screen.kitty_images.debug = self.debug_images;
        pane.terminal.screen.kitty_images.budget_bytes = @as(usize, self.config.image_memory_mb) * 1024 * 1024;
        // Mouse / link flags from config.
        pane.copy_on_selection = self.config.copy_on_selection;
        pane.clear_select_on_copy = self.config.clear_select_on_copy;
        pane.disable_mouse_paste = self.config.disable_mouse_paste;
        pane.disable_mousewheel_zoom = self.config.disable_mousewheel_zoom;
        pane.link_single_click = self.config.link_single_click;
        pane.mouse_autohide = self.config.mouse_autohide;
        pane.middle_click_action = self.config.mouse_middle_click;
        pane.right_click_action = self.config.mouse_right_click;
        pane.surface.bg_pass.source = &self.bg_source;
        pane.surface.shader_default_source = &self.shader_source;
        pane.refreshShaderBinding();
        pane.updateShaderTick();
        // Renderer bold flags.
        pane.surface.grid_pass.allow_bold = self.config.allow_bold;
        pane.surface.grid_pass.bold_is_bright = self.config.bold_is_bright;
        pane.surface.cell_pass.allow_bold = self.config.allow_bold;
        pane.surface.cell_pass.bold_is_bright = self.config.bold_is_bright;
        pane.surface.grid_pass.min_contrast = self.config.minimum_contrast;
        pane.surface.cell_pass.min_contrast = self.config.minimum_contrast;
        pane.surface.grid_pass.enable_url_underline = self.config.auto_url_detect;
        // Per-pane titlebar visibility. The file-manager and browser
        // identities never show it: their panes wear a face whose own
        // location/URL bar already names the pane, so the strip under
        // the tab bar is pure redundancy there.
        pane.setTitlebarVisible(self.config.show_titlebar and !files_identity and !web_identity);
        // Inactive-pane dimming factors.
        pane.surface.inactive_darken = self.config.inactive_darken;
        pane.surface.inactive_desaturate = self.config.inactive_desaturate;
        pane.applyDim();
        return pane;
    }

    fn spawnShellPane(self: *Window) !*Pane {
        return self.spawnShellPaneOpts(null, null);
    }

    /// Spawn a shell with an optional starting cwd and named profile.
    /// The pane gets the profile's complete settings bundle (shell,
    /// font, colors, scrollback, shader, …); empty/null profile = the
    /// window default profile, falling back to the Default settings.
    pub fn spawnShellPaneOpts(self: *Window, inherit_cwd: ?[]const u8, profile_name: ?[]const u8) !*Pane {
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

        const pane = try self.daemonSpawnPane(.{
            .argv = &[_][]const u8{std.mem.span(shell)},
            .cwd = inherit_cwd,
            .term = s.term_env,
            .color_term = s.color_term_env,
            .login_shell = s.login_shell,
            .si = self.shellIntegrationFor(shell),
            .profile = profile,
        });
        // Record the spawn argv so layout-save serializes the real command
        // (profile shell override included), not a $SHELL fallback — and so a
        // restored ephemeral pane re-spawns the same shell. setSpawnArgv copies.
        pane.setSpawnArgv(&[_][*:0]const u8{shell});
        return pane;
    }

    const SiWire = struct { kind: []const u8, script: []const u8, shim_dir: []const u8 };

    /// Process-global counter for daemon session names. MUST NOT be per-window:
    /// two windows in one process (e.g. palette "Load layout" opens a new
    /// window) share the same pid, so a per-window counter mints colliding
    /// `s<pid>-N` names and the daemon rejects the dupes ("session name already
    /// exists" → DaemonError), which dropped most tabs on a multi-tab load.
    /// pid + this counter is unique within and across GUI processes/restarts.
    var session_seq: u64 = 0;
    pub fn nextSessionName(buf: []u8) []const u8 {
        session_seq += 1;
        return std.fmt.bufPrint(buf, "s{d}-{d}", .{ c.getpid(), session_seq }) catch "s0";
    }

    /// Everything needed to spawn one local pane through the daemon. Built by
    /// each call site (new-tab/split, editor/scrollback, layout restore).
    const DaemonSpawnSpec = struct {
        argv: []const []const u8,
        cwd: ?[]const u8 = null,
        term: []const u8 = "",
        color_term: []const u8 = "",
        login_shell: bool = false,
        si: ?@import("../pty.zig").ShellIntegration = null,
        profile: ?*const @import("../config.zig").Profile = null,
    };

    /// THE local-pane factory. Now that there is no in-process PTY path, every
    /// local shell is a GUI-owned (ephemeral) session on the auto-started local
    /// daemon that the GUI attaches to — durable across a GUI crash, shareable,
    /// one session model. Exports the pane id + IPC socket for
    /// `sketerm cli --pane self`, forwards TERM/COLORTERM/login-shell/
    /// shell-integration for full parity with the old in-process spawn, and
    /// disables the predictor (the local socket hop is sub-ms, so speculative
    /// echo would only add flicker).
    pub fn daemonSpawnPane(self: *Window, spec: DaemonSpawnSpec) !*Pane {
        var name_buf: [64]u8 = undefined;
        const name = nextSessionName(&name_buf);
        const pane_id = self.allocPaneId();

        const si_wire: ?SiWire = if (spec.si) |si| .{
            .kind = switch (si.kind) {
                .zsh => "zsh",
                .fish => "fish",
                .bash => "bash",
            },
            .script = std.mem.span(si.script),
            .shim_dir = std.mem.span(si.shim_dir),
        } else null;

        var conn = try self.muxConnect(null);
        var attached: @import("../mux/client.zig").Conn.GuiAttachResult = undefined;
        {
            errdefer conn.deinit();
            // Local GUI-owned pane: let its child GUI apps render on
            // THIS desktop's compositor (no sketerm Wayland hub). Pass
            // our own $WAYLAND_DISPLAY so the daemon points the child at
            // it directly (its inherited value may be stale/absent).
            const host_wl: []const u8 = if (c.getenv("WAYLAND_DISPLAY")) |w|
                std.mem.span(w)
            else
                "";
            try conn.sendJson(.spawn, .{
                .name = name,
                .argv = spec.argv,
                .cwd = spec.cwd,
                .rows = @as(u16, 24),
                .cols = @as(u16, 80),
                .pane_id = pane_id,
                .socket = if (self.ipc_path) |sp| @as([]const u8, sp) else "",
                .term = spec.term,
                .color_term = spec.color_term,
                .login_shell = spec.login_shell,
                .shell_integration = si_wire,
                .local = true,
                .host_wayland_display = host_wl,
            });
            (try conn.recvExpect(&.{.ok})).deinit(self.allocator);
            try conn.sendAttach(name, .{ .kind = "gui", .panel_rpc = conn.panel_rpc });
            attached = try conn.recvGuiAttach();
        }
        defer attached.snapshot.deinit(self.allocator);
        // Pass the pre-allocated id so it isn't double-allocated (keeps pane
        // ids contiguous + matches the env-exported SKETERM_PANE_ID).
        const pane = try self.makeRemotePaneFromSnap(conn, name, null, attached.snapshot.payload, attached.identity, pane_id, false, false, true);
        if (pane.terminal.remote) |r| {
            r.ephemeral = true; // GUI-owned → close kills the session (no leak)
            r.predictor.force = .never;
        }
        // Profile visuals: makeRemotePaneFromSnap applied the base config, so
        // re-apply with the profile to pick up its font/colours.
        if (spec.profile) |p| {
            pane.active_profile = p.name;
            self.applyPaneConfig(pane, .{ .profile = p });
        }
        return pane;
    }

    /// Wire every Window-level sink onto a fresh pane. THE single
    /// place pane→window callbacks are connected — every pane
    /// creation path (tab, split, layout restore, mux attach) goes
    /// through here, so a new sink added here reaches all of them.
    /// All handlers are pane-aware and no-op when irrelevant (e.g.
    /// child-exit on a remote pane means "session ended / connection
    /// lost" and detaches to a local shell instead of exit_action).
    pub fn wirePaneSinks(self: *Window, pane: *Pane) void {
        pane.terminal.on_panel_request = onPanePanelRequest;
        pane.terminal.on_panel_origin_close = @import("panelhost.zig").closeOrigin;
        pane.terminal.on_panel_origin_renamed = @import("panelhost.zig").renameOrigin;
        pane.terminal.on_panel_work_cancel = @import("panelhost.zig").cancelPanelWork;
        @import("panelhost.zig").attachOrigin(pane.terminal, pane);
        pane.win_clip_ctx = @ptrCast(self);
        pane.win_on_clipboard = termsinks_mod.onTermClipboardSet;
        pane.win_notify_ctx = @ptrCast(self);
        pane.win_on_notification = termsinks_mod.onTermNotification;
        pane.win_progress_ctx = @ptrCast(self);
        pane.win_on_progress = termsinks_mod.onTermProgress;
        pane.win_on_transfer = termsinks_mod.onTermTransfer;
        pane.win_on_cmd_status = termsinks_mod.onTermCmdStatus;
        pane.win_bell_ctx = @ptrCast(self);
        pane.win_on_bell = termsinks_mod.onTermBell;
        pane.win_child_ctx = @ptrCast(self);
        pane.win_on_child_exit = termsinks_mod.onTermChildExit;
        pane.win_crash_ctx = @ptrCast(self);
        pane.win_on_crashed = onPaneCrashed;
        pane.win_cwd_ctx = @ptrCast(self);
        pane.win_on_cwd = termsinks_mod.onTermCwdChanged;
        pane.win_setprofile_ctx = @ptrCast(self);
        pane.win_on_set_profile = termsinks_mod.onTermSetProfile;
        pane.win_focus_ctx = @ptrCast(self);
        pane.win_on_focus_enter = termsinks_mod.onPaneFocused;
        pane.win_activity_ctx = @ptrCast(self);
        pane.win_on_activity = termsinks_mod.onTermActivity;
        // OSC 0/1/2 titles drive the AdwTabPage title — but only
        // until the user explicitly renames the tab (which sets the
        // "user-locked" flag on the page). Renaming with an empty
        // string clears the lock and lets OSC tracking resume.
        pane.win_title_ctx = @ptrCast(self);
        pane.win_on_title = termsinks_mod.onTermTitleChanged;
        pane.win_on_program = termsinks_mod.onTermProgramChanged;
        pane.win_on_geometry = termsinks_mod.onPaneGeometryChanged;
        pane.win_session_rename_ctx = @ptrCast(self);
        pane.win_on_session_renamed = termsinks_mod.onTermSessionRenamed;
    }

    fn onPanePanelRequest(
        ctx: ?*anyopaque,
        terminal: *Terminal,
        request_id: u64,
        request: []const u8,
    ) void {
        const pane = cast.userData(Pane, ctx);
        const owner: *Window = if (pane.win_clip_ctx) |win| @ptrCast(@alignCast(win)) else {
            terminal.replyPanelRequest(request_id, "{\"ok\":false,\"error\":\"panel pane has no window\"}");
            return;
        };
        @import("panelhost.zig").dispatchRelay(owner, terminal, pane, request_id, request);
    }

    /// Drop every window-level pointer into a pane (search / hints /
    /// copy mode / zoom / notify slots) and unlist it + its terminal —
    /// WITHOUT tearing the pane down. Shared by the close path
    /// (unlistPane) and cross-window tab adoption, where the pane
    /// lives on under another Window.
    pub fn disownPane(self: *Window, pane: *Pane) void {
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
    pub fn unlistPane(self: *Window, pane: *Pane) void {
        self.disownPane(pane);
        // Not in disownPane: adoption (cross-window tab drag) also
        // disowns, but there the pane lives on and must keep its faces.
        pane.severFaces();
        const term = pane.terminal;
        term.clearSinks();
        schedulePaneTeardown(pane, term);
    }

    /// Spawn an empty secondary Window sharing this one's config.
    /// Used by tab drag-out (AdwTabView "create-window") and the
    /// detach_tab action.
    pub fn spawnSecondaryWindow(self: *Window) ?*Window {
        const app = c.gtk_window_get_application(@ptrCast(self.app_window));
        const cfg = self.config.clone(self.allocator) catch null;
        const win = Window.initWithConfig(self.allocator, @ptrCast(app), cfg, false) catch |err| {
            std.debug.print("sketerm: secondary window spawn failed: {s}\n", .{@errorName(err)});
            return null;
        };
        win.debug_events = self.debug_events;
        win.hold_override = self.hold_override;
        win.save_on_close = self.save_on_close;
        c.gtk_window_present(@ptrCast(win.app_window));
        return win;
    }

    /// A repeat launch of this identity (`sketerm` again, no args):
    /// another window with one shell tab. SECONDARY on purpose: a
    /// second is_primary window would quit the whole app when closed
    /// and would clobber the process's notion of "the primary".
    pub fn openShellWindow(self: *Window) !*Window {
        const win = self.spawnSecondaryWindow() orelse return error.WindowSpawnFailed;
        try win.newShellTab(null);
        return win;
    }

    /// A repeat launch of the file-manager identity (`sketerm files`
    /// again): another browser window, the way a file manager behaves.
    /// Inherits this window's config; wears the files title/icon because
    /// the whole PROCESS does.
    pub fn openFilesWindow(self: *Window, spec: ?[]const u8, reveal: ?[]const u8) !*Window {
        const win = self.spawnSecondaryWindow() orelse return error.WindowSpawnFailed;
        try win.newBrowserTabFromReveal(null, spec, reveal);
        return win;
    }

    /// detach_tab action: move the selected tab into a fresh window —
    /// keyboard/palette equivalent of dragging it out of the tab bar.
    fn detachCurrentTab(self: *Window) void {
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
        const win = self.spawnSecondaryWindow() orelse return;
        if (!win.transferPageFrom(self.tab_view, page, 0))
            c.gtk_window_destroy(@ptrCast(win.app_window));
    }

    /// Take ownership of a pane that arrived from another Window via
    /// tab drag-out/drag-in: unhook it there, list it here, rewire
    /// every sink and config-derived field against this window.
    fn adoptPane(self: *Window, pane: *Pane) void {
        const src_any = pane.win_clip_ctx orelse return;
        const src: *Window = @ptrCast(@alignCast(src_any));
        if (src == self) return;
        // Reserve here, before unhooking the source. transferPageFrom and
        // onCreateWindow reserve up front so a doomed move is refused before
        // libadwaita reparents anything, but a page can also arrive through a
        // path neither of them sees (dragging between two tab OVERVIEWS), so
        // this must never assume the capacity is already there.
        self.reserveAdoptionCapacity(1) catch {
            showToast(self, "Could not move the tab: out of memory");
            return;
        };
        src.disownPane(pane);
        self.panes.appendAssumeCapacity(pane);
        self.terminals.appendAssumeCapacity(pane.terminal);
        self.wirePaneSinks(pane);
        if (@import("browser.zig").BrowserView.fromPane(pane)) |bv| self.installBrowserHooks(bv);
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
    pub fn adoptPanesInTree(self: *Window, w: *c.GtkWidget) void {
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

    fn foreignPaneCount(self: *Window, w: *c.GtkWidget) usize {
        if (c.g_object_get_data(@ptrCast(@alignCast(w)), "sketerm-pane")) |data| {
            const pane: *Pane = @ptrCast(@alignCast(data));
            const src_any = pane.win_clip_ctx orelse return 0;
            const src: *Window = @ptrCast(@alignCast(src_any));
            return @intFromBool(src != self);
        }
        var count: usize = 0;
        var child = c.gtk_widget_get_first_child(w);
        while (child) |ch| : (child = c.gtk_widget_get_next_sibling(ch))
            count += self.foreignPaneCount(ch);
        return count;
    }

    fn reserveAdoptionCapacity(self: *Window, count: usize) !void {
        if (count == 0) return;
        try self.panes.ensureUnusedCapacity(self.allocator, count);
        try self.terminals.ensureUnusedCapacity(self.allocator, count);
    }

    /// Reserve ownership before libadwaita reparents the page.
    fn transferPageFrom(
        self: *Window,
        source: *c.AdwTabView,
        page: *c.AdwTabPage,
        position: c_int,
    ) bool {
        const child = c.adw_tab_page_get_child(page) orelse return false;
        const count = self.foreignPaneCount(@ptrCast(child));
        self.reserveAdoptionCapacity(count) catch {
            showToast(self, "Could not move the tab: out of memory");
            return false;
        };
        c.adw_tab_view_transfer_page(source, page, self.tab_view, position);
        return true;
    }

    pub const PaneConfigOpts = struct {
        profile: ?*const @import("../config.zig").Profile = null,
        /// Saved per-pane font size (layout restore / Ctrl± zoom).
        /// Wins over the profile's font_size.
        font_size_override: ?u16 = null,
    };

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
        termsinks_mod.titleFactChanged(self, pane, .zoom);
        _ = c.gtk_widget_grab_focus(@ptrCast(pane.surface.area));
    }

    pub fn unzoomPane(self: *Window) void {
        const pane = self.zoom_pane orelse return;
        self.zoom_pane = null;
        termsinks_mod.titleFactChanged(self, pane, .zoom);
        for (self.zoom_hidden.items) |w| {
            c.gtk_widget_set_visible(w, 1);
            c.g_object_unref(w);
        }
        self.zoom_hidden.clearRetainingCapacity();
        _ = c.gtk_widget_grab_focus(@ptrCast(pane.surface.area));
    }

    /// Split whatever currently has keyboard focus. A no-op when focus
    /// is not on a pane (an empty window, a dialog, a background tab).
    pub fn splitFocused(self: *Window, orientation: c_uint) !void {
        // Find the focused Pane. The wrapper Box isn't focusable, so
        // gtk_window_get_focus returns the inner GLArea. Match against
        // p.surface.area, then operate on p.widget() (== the wrapper) for
        // reparenting.
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return;
        const focused_pane = self.paneForWidget(focus) orelse return;
        try self.splitPane(focused_pane, orientation);
    }

    /// Split a SPECIFIC pane. Callers that already know which pane they
    /// mean — `sketerm cli split --pane N`, the palette acting on a
    /// referenced pane — must use this rather than focusing the pane and
    /// calling splitFocused: focus does not follow a `grab_focus` on a
    /// widget in a background tab, so that route silently split whatever
    /// happened to be focused instead, or nothing at all.
    pub fn splitPane(self: *Window, focused_pane: *Pane, orientation: c_uint) !void {
        // Splitting a zoomed layout would wire the new pane into a
        // hidden tree — restore the real layout first.
        self.unzoomPane();
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
        const ratio_holder = try self.allocator.create(winlayout_mod.PanedRatioCtx);
        ratio_holder.* = .{ .allocator = self.allocator, .ratio = 0.5 };
        _ = c.g_signal_connect_data(
            paned,
            "notify::position",
            @ptrCast(&winlayout_mod.onPanedPositionChanged),
            @ptrCast(ratio_holder),
            @ptrCast(cast.destroyCtx(winlayout_mod.PanedRatioCtx)),
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            paned,
            "map",
            @ptrCast(&winlayout_mod.applyPanedRatioMap),
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
        // new_w is the wrapper Box when padding is set — queue the
        // render on the GLArea itself, not the wrapper.
        c.gtk_gl_area_queue_render(@ptrCast(new_pane.surface.area));
        c.gtk_widget_queue_resize(@ptrCast(paned));

        _ = c.gtk_widget_grab_focus(focused_w);
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
            @ptrCast(cast.destroyCtx(Window.RenameCtx)),
            c.G_CONNECT_DEFAULT,
        );

        c.gtk_popover_popup(@ptrCast(popover));
        _ = c.gtk_widget_grab_focus(entry);
    }

    // ── tab context menu (right-click a tab) ─────────────────────────

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
            c.gtk_widget_set_parent(popover, @ptrCast(pane.surface.area));
            const w = c.gtk_widget_get_width(@ptrCast(pane.surface.area));
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
            @ptrCast(cast.destroyCtx(Window.PaneTitleCtx)),
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
        c.gtk_widget_set_parent(popover, @ptrCast(pane.surface.area));
        connectManualPopoverClose(popover);
        const w = c.gtk_widget_get_width(@ptrCast(pane.surface.area));
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
            @ptrCast(cast.destroyCtx(Window.MuxRenameCtx)),
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
        if (!remote.closed and remote.connected) {
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
        // A visible non-terminal face owns the zoom; resizing the
        // hidden terminal behind it would be invisible and surprising.
        if (pane.faceZoom(delta, false)) return;
        const new: i32 = @as(i32, @intCast(pane.surface.font_size)) + delta;
        const clamped: u16 = @intCast(std.math.clamp(new, 6, 72));
        if (clamped == pane.surface.font_size) return;
        pane.setFontSize(clamped);
    }

    pub fn resetFocusedFontSize(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        if (pane.faceZoom(0, true)) return;
        const base = self.config.profileSettings(pane.active_profile orelse "").font_size;
        if (pane.surface.font_size == base) return;
        pane.setFontSize(base);
    }

    const PromptDir = enum { prev, next };

    fn jumpPromptOnFocused(self: *Window, dir: PromptDir) void {
        const pane = self.focusedPane() orelse return;
        const screen = pane.terminal.screen;
        _ = switch (dir) {
            .prev => screen.jumpPrevPrompt(),
            .next => screen.jumpNextPrompt(),
        };
        c.gtk_gl_area_queue_render(@ptrCast(pane.surface.area));
    }

    pub fn focusedPane(self: *Window) ?*Pane {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return null;
        return self.paneForWidget(focus);
    }

    /// The pane owning `widget`. Matching the GLArea alone is not
    /// enough: a pane wearing the browser face has focus on a browser
    /// widget, so climb to the wrapper each pane owns.
    pub fn paneForWidget(self: *Window, widget: *c.GtkWidget) ?*Pane {
        var w: ?*c.GtkWidget = widget;
        while (w) |cur| : (w = c.gtk_widget_get_parent(cur)) {
            for (self.panes.items) |p| {
                if (@intFromPtr(p.surface.area) == @intFromPtr(cur)) return p;
                if (@intFromPtr(p.widget()) == @intFromPtr(cur)) return p;
            }
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
                if (focus == @as(*c.GtkWidget, @ptrCast(p.surface.area))) {
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
        _ = c.gtk_widget_grab_focus(@ptrCast(in_tab.items[next].surface.area));
    }

    /// Insert a new tab into self.tab_view, honouring the
    /// `new_tab_after_current` config: at the end (default) or
    /// immediately after the currently-selected page. Returns the
    /// AdwTabPage so callers can set its title/tooltip.
    /// `at_end` forces an append regardless of the `new_tab_after_current`
    /// preference — used by layout restore, which must preserve the saved
    /// tab order (insert-after-current would reverse a bulk load).
    pub fn appendOrInsertTab(self: *Window, child: *c.GtkWidget, tree_root: PaneTree.Node, at_end: bool) *c.AdwTabPage {
        const page = blk: {
            if (!at_end and self.config.new_tab_after_current) {
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
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-id", @ptrFromInt(next_tab_id));
        next_tab_id += 1;
        self.attachTabTree(page, tree_root);
        self.last_created_page = page;
        return page;
    }

    /// AdwTabOverview "create-tab": the "+" tile in the overview.
    /// Must return the new page so the overview can select it.
    fn onOverviewCreateTab(_: *c.AdwTabOverview, user: ?*anyopaque) callconv(.c) ?*c.AdwTabPage {
        const self = cast.userData(Window, user);
        self.last_created_page = null;
        self.newShellTab(null) catch |err| {
            logActionError("overview_create_tab", err);
            return null;
        };
        return self.last_created_page;
    }

    /// Attach the pane-tree model to a tab page. Best-effort on OOM
    /// (queries fall back gracefully on a missing tree).
    pub fn attachTabTree(self: *Window, page: *c.AdwTabPage, root: PaneTree.Node) void {
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
    pub fn freeTabTree(self: *Window, page: *c.AdwTabPage) void {
        if (tabTreeOf(page)) |t| {
            t.deinit();
            self.allocator.destroy(t);
            c.g_object_set_data(@ptrCast(@alignCast(page)), TAB_TREE_KEY, null);
        }
    }

    // ── Remote control (sketerm cli): split out to ui/remotectl.zig ──
    // Aliased like the muxtabs split.
    const remotectl = @import("remotectl.zig");
    pub const allocPaneId = remotectl.allocPaneId;
    pub const paneById = remotectl.paneById;
    pub const liveWindows = remotectl.liveWindows;
    pub const windowForPane = remotectl.windowForPane;
    pub const PaneRef = remotectl.PaneRef;
    pub const detachWindowSignals = remotectl.detachWindowSignals;
    pub const findPaneAcrossWindows = remotectl.findPaneAcrossWindows;
    pub const paneBySession = remotectl.paneBySession;
    pub const mintUdpTicket = remotectl.mintUdpTicket;
    pub const canMintUdpTicket = remotectl.canMintUdpTicket;
    pub const TabRef = remotectl.TabRef;
    const registerNotifySlot = remotectl.registerNotifySlot;
    const dropNotifySlotsForPane = remotectl.dropNotifySlotsForPane;
    const ipcDispatchTrampoline = remotectl.ipcDispatchTrampoline;

    // ── Durable tabs + app sessions: split out to ui/muxtabs.zig ──
    // Aliased so `self.method()` call sites and Window.Type references
    // keep working unchanged on both sides of the split.
    const muxtabs = @import("muxtabs.zig");
    pub const attachSessionByHost = muxtabs.attachSessionByHost;
    pub const focusPaneTab = muxtabs.focusPaneTab;
    pub const newDurableTab = muxtabs.newDurableTab;
    pub const newDurableSessionAt = muxtabs.newDurableSessionAt;
    pub const newDurableSession = muxtabs.newDurableSession;
    pub const attachMuxTab = muxtabs.attachMuxTab;
    pub const sessionShown = muxtabs.sessionShown;
    pub const attachAllSessions = muxtabs.attachAllSessions;
    pub const focusOrAttachSession = muxtabs.focusOrAttachSession;
    pub const AppSession = muxtabs.AppSession;
    pub const launchRemoteAppSession = muxtabs.launchRemoteAppSession;
    pub const Lease = muxtabs.Lease;
    pub const attachMux = muxtabs.attachMux;
    const muxConnect = muxtabs.muxConnect;
    const makeRemotePaneFromSnap = muxtabs.makeRemotePaneFromSnap;
    const restoreMuxPane = muxtabs.restoreMuxPane;
    const MuxRestoreJob = muxtabs.MuxRestoreJob;
    const startMuxRestoreJob = muxtabs.startMuxRestoreJob;
    const muxRestoreJobFor = muxtabs.muxRestoreJobFor;
    const attachMuxLease = muxtabs.attachMuxLease;

    /// Carry a pane's per-pane shader choice onto its in-place
    /// replacement, so a mux takeover or a detach-to-shell doesn't
    /// silently snap the shader back to the profile/global default.
    /// Mirrors the layout save/restore precedence (preset, then an
    /// explicit pick, then a sticky clear); `new` already had the
    /// default applied by its config push, so this is an override.
    pub fn transferPaneShader(self: *Window, old: *Pane, new: *Pane) void {
        if (old.surface.preset_name) |pn| {
            if (self.applyShaderPresetByName(new, pn)) return;
        }
        if (old.surface.custom_shader_user) {
            if (old.surface.custom_shader_path) |sp| {
                _ = new.setCustomShader(sp, self.config.custom_shader_animation, true);
                return;
            }
        }
        if (old.surface.shader_cleared) new.clearShader();
    }

    /// Put `pane` into `old`'s slot — tree model and widget tree in
    /// the same function — then unlist `old` (its teardown is
    /// deferred past GTK's destroy chain). Shared by the mux takeover
    /// and the detach-to-local-shell path.
    pub fn swapPaneInPlace(self: *Window, old: *Pane, pane: *Pane) !*c.AdwTabPage {
        // Resolve BOTH failure conditions before touching anything: an
        // error after the model swap would leave the model pointing at a
        // pane the widget tree doesn't have (and the caller then frees that
        // pane, leaving the model holding freed memory).
        const page = tabPageForPane(self, old) orelse return error.PaneHasNoTab;
        const old_w = old.widget();
        const parent = c.gtk_widget_get_parent(old_w) orelse return error.PaneHasNoTab;
        // Preserve the user's per-pane shader across the swap (old's
        // Zig-side shader fields stay valid until the deferred unlist).
        self.transferPaneShader(old, pane);
        // Mirror in the tree model: the new pane takes the old
        // leaf's slot in place.
        if (tabTreeOf(page)) |t| {
            t.replaceLeaf(old, pane) catch
                std.debug.print("sketerm: tree model takeover desync (leaf not found)\n", .{});
        }
        const is_paned = c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(parent)),
            c.gtk_paned_get_type(),
        ) != 0;
        // Drop the new pane into the old one's slot. Replacing /
        // removing the child destroys old_w's widget subtree;
        // Zig-side teardown is deferred below — but every face must
        // be severed BEFORE the destroy, or its still-connected
        // handlers fire against the dangling GLArea in the gap.
        old.severFaces();
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
    pub fn detachPaneToShell(self: *Window, pane: *Pane) void {
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
        _ = c.gtk_widget_grab_focus(@ptrCast(fresh.surface.area));
    }

    /// A forwarded app (`sketerm app`) exited before ever showing a
    /// window — almost always a failed launch. Keep the pane and its
    /// now-frozen log on screen (the user's only diagnostic) instead of
    /// detaching to a shell, and retitle the tab to flag the exit. The
    /// user reads the log and closes the tab manually.
    pub fn holdExitedAppPane(self: *Window, pane: *Pane, status: i32) void {
        std.debug.print("sketerm: forwarded app exited ({d}) without opening a window — holding pane so the log stays visible\n", .{status});
        const page = tabPageForPane(self, pane) orelse return;
        var buf: [96:0]u8 = undefined;
        const t = std.fmt.bufPrintZ(&buf, "app exited ({d})", .{status}) catch "app exited";
        c.adw_tab_page_set_title(page, t.ptr);
        c.adw_tab_page_set_tooltip(page, "The app exited without opening a window here. " ++
            "Single-instance apps hand off to an already-running instance " ++
            "(its window opened THERE); otherwise the launch failed — " ++
            "see the log in this tab.");
        if (page != c.adw_tab_view_get_selected_page(self.tab_view))
            c.adw_tab_page_set_needs_attention(page, 1);
    }

    pub fn holdUnavailableAppPane(self: *Window, pane: *Pane) void {
        const page = tabPageForPane(self, pane) orelse return;
        c.adw_tab_page_set_title(page, "app session unavailable");
        c.adw_tab_page_set_tooltip(page, "The remote daemon no longer has this app session. Its last log remains in this tab.");
        if (page != c.adw_tab_view_get_selected_page(self.tab_view))
            c.adw_tab_page_set_needs_attention(page, 1);
    }

    const CrashBtnCtx = struct { allocator: std.mem.Allocator, window: *Window, pane: *Pane };

    /// The pane's session died unexpectedly — replace the GL terminal with a
    /// crashed-tab panel (sad face + "Start new session" button). The pane
    /// stays so the crash is visible; the button spawns a fresh session into
    /// the same slot (reusing the detach-to-shell swap).
    fn onPaneCrashed(ctx: ?*anyopaque, pane: *Pane) void {
        const self = cast.userData(Window, ctx);
        const wrap = pane.widget();
        // The GLArea sits inside a graphics-offload widget (black bg); hide
        // that whole subtree, not just the GLArea, so the crash panel fills.
        if (c.gtk_widget_get_parent(@ptrCast(pane.surface.area))) |offload| {
            c.gtk_widget_set_visible(offload, 0);
        } else {
            c.gtk_widget_set_visible(@ptrCast(pane.surface.area), 0);
        }
        // Drop the per-pane titlebar too (if any): its stale session title
        // above a "session crashed" panel reads as a contradiction.
        if (pane.titlebar_box) |tb| c.gtk_widget_set_visible(tb, 0);
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12) orelse return;
        c.gtk_widget_set_hexpand(box, 1);
        c.gtk_widget_set_vexpand(box, 1);
        c.gtk_widget_set_valign(box, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_halign(box, c.GTK_ALIGN_CENTER);
        const face = c.gtk_label_new(null);
        c.gtk_label_set_markup(@ptrCast(face), "<span size=\"xx-large\">:(</span>");
        const msg = c.gtk_label_new("This session crashed.");
        const btn = c.gtk_button_new_with_label("Start new session");
        c.gtk_widget_set_halign(btn, c.GTK_ALIGN_CENTER);
        const cctx = self.allocator.create(CrashBtnCtx) catch return;
        cctx.* = .{ .allocator = self.allocator, .window = self, .pane = pane };
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onCrashRestartClicked), @ptrCast(cctx), @ptrCast(cast.destroyCtx(Window.CrashBtnCtx)), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), face);
        c.gtk_box_append(@ptrCast(box), msg);
        c.gtk_box_append(@ptrCast(box), btn);
        c.gtk_box_append(@ptrCast(wrap), box);
    }

    // ── Background layer (image / gradient) ─────────────────────

    /// Locate the shell-integration script directory (shared
    /// resolution in util/shellintegration.zig) and cache the
    /// per-shell script + shim paths. Missing dir = feature
    /// silently off.
    pub fn resolveShellIntegration(self: *Window) void {
        const ally = self.allocator;
        var base_buf: [4096]u8 = undefined;
        const base = @import("../util/shellintegration.zig").baseDir(&base_buf) orelse return;
        self.si_zsh_script = std.fmt.allocPrintSentinel(ally, "{s}/sketerm.zsh", .{base}, 0) catch null;
        self.si_fish_script = std.fmt.allocPrintSentinel(ally, "{s}/sketerm.fish", .{base}, 0) catch null;
        self.si_bash_script = std.fmt.allocPrintSentinel(ally, "{s}/sketerm.bash", .{base}, 0) catch null;
        self.si_zsh_shim = std.fmt.allocPrintSentinel(ally, "{s}/zsh", .{base}, 0) catch null;
        self.si_fish_shim = std.fmt.allocPrintSentinel(ally, "{s}/fish-xdg", .{base}, 0) catch null;
        self.si_bash_shim = std.fmt.allocPrintSentinel(ally, "{s}/bash/sketerm-rc.bash", .{base}, 0) catch null;
    }

    /// Pick the injection setup for the program being spawned, or
    /// null (no injection) for shells we don't auto-integrate.
    pub fn shellIntegrationFor(self: *const Window, argv0: [*:0]const u8) ?@import("../pty.zig").ShellIntegration {
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
        if (std.mem.eql(u8, base, "bash")) {
            const script = self.si_bash_script orelse return null;
            const shim = self.si_bash_shim orelse return null;
            return .{ .kind = .bash, .script = script.ptr, .shim_dir = shim.ptr };
        }
        return null;
    }

    // ── Per-tab colours ──────────────────────────────────────────

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
        // With a window_title_template set, the focused pane owns the
        // title text; the broadcast suffix is appended to whatever it
        // renders (setWindowTitleText).
        if (self.config.window_title_template.len > 0) {
            termsinks_mod.refreshWindowTitleTemplate(self);
            return;
        }
        self.setWindowTitleText(self.title_base);
    }

    /// Set the GTK window title to `base` plus the broadcast suffix.
    /// The suffix is the one thing that must survive whatever supplies
    /// the base — a fixed name, a file-manager identity, or a rendered
    /// title template.
    pub fn setWindowTitleText(self: *Window, base: []const u8) void {
        const suffix: []const u8 = switch (self.groupsend) {
            .off => "",
            .group => " — broadcast: group",
            .all => " — broadcast: all",
        };
        // title_base as the fallback, not a literal: a file-manager
        // window keeps its own name when a template renders empty.
        const text = if (base.len > 0) base else self.title_base;
        var buf: [640:0]u8 = undefined;
        const title = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ text, suffix }) catch return;
        c.gtk_window_set_title(@ptrCast(self.app_window), title.ptr);
    }

    /// Wire / unwire each Terminal's broadcast_sink based on the
    /// current groupsend mode. Off = no sink installed (direct writes).
    pub fn refreshBroadcastSink(self: *Window) void {
        const sink: ?*const fn (ctx: ?*anyopaque, source: *Terminal, bytes: []const u8) void = if (self.groupsend == .off) null else termsinks_mod.broadcastSinkFn;
        for (self.terminals.items) |t| {
            t.broadcast_sink = sink;
            t.broadcast_ctx = if (sink != null) @ptrCast(self) else null;
        }
    }

    pub fn applyBroadcastCss(self: *Window, p: *Pane) void {
        if (p.titlebar_box) |tb| {
            const w: *c.GtkWidget = @ptrCast(@alignCast(tb));
            if (self.groupsend != .off) {
                c.gtk_widget_add_css_class(w, "sketerm-broadcast");
            } else {
                c.gtk_widget_remove_css_class(w, "sketerm-broadcast");
            }
        }
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
        _ = c.gtk_widget_grab_focus(@ptrCast(target.surface.area));
        self.closeFocusedPane();
    }

    pub fn closeFocusedPane(self: *Window) void {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return;
        const pane = self.paneForWidget(focus) orelse return;
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

        // The widget surgery below destroys the pane's GLArea while
        // Pane.deinit is still an idle away — sever every face first,
        // so nothing (IM commit/preedit, browser fd watch, editor
        // shortcut restore) fires against dead widgets in that gap.
        pane.severFaces();

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
        // its controller / signal-closure cleanups before Pane teardown.
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
            _ = c.gtk_widget_grab_focus(@ptrCast(fp.surface.area));
        } else if (sibling) |sib| {
            for (self.panes.items) |p| {
                if (widgetIsAncestor(@ptrCast(sib), @ptrCast(p.widget()))) {
                    _ = c.gtk_widget_grab_focus(@ptrCast(p.surface.area));
                    break;
                }
            }
        }

        self.verifyAllTabs();
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
        clipboard.copyText(self.app_window, text);
    }

    /// Copy the focused pane's scrollback ring + active screen.
    pub fn copyFocusedScrollback(self: *Window) void {
        const pane = self.focusedPane() orelse return;
        const screen = pane.terminal.screen;
        const text = screen.extractScrollback(self.allocator) catch return;
        defer self.allocator.free(text);
        if (text.len == 0) return;
        clipboard.copyText(self.app_window, text);
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

    /// Toggle the current tab's pinned state. Pinned tabs sit in a
    /// separate region at the start of the tab bar (AdwTabView
    /// native): close button is hidden, drag-reorder is restricted
    /// to among the pinned set.
    pub fn togglePinCurrentTab(self: *Window) void {
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
        const is_pinned = c.adw_tab_page_get_pinned(page) != 0;
        c.adw_tab_view_set_page_pinned(self.tab_view, page, if (is_pinned) 0 else 1);
    }

    // ── Tree-style tabs (model: src/ui/tabforest.zig, sidebar:
    //    src/ui/tabsidebar.zig) ──────────────────────────────────────

    fn childInsertPos(self: *const Window) tabforest_mod.InsertPos {
        return switch (self.config.tab_child_insert) {
            .last => .last,
            .first => .first,
        };
    }

    /// Refresh every view of the tab forest after a mutation: the
    /// strip's hidden state, the sidebar rows, and (under
    /// SKETERM_VERIFY_TREE) the model/view cross-check.
    pub fn forestChanged(self: *Window) void {
        if (self.destroying) return;
        self.tabbar.refreshHidden();
        if (self.tab_sidebar) |sb| {
            if (c.gtk_widget_get_visible(sb.root) != 0) sb.rebuild();
        }
        // Forest-only verify: forestChanged fires from page-attached,
        // BEFORE appendOrInsertTab has attached the new page's
        // PaneTree — the pane-tree check would warn spuriously there.
        self.verifyTabForest();
    }

    /// Collapse / expand a tab's subtree. Collapsing pulls the
    /// selection up to the collapsed tab if it sat inside the hidden
    /// subtree (TST behaviour), and offers the newly hidden WEB panes
    /// to the discard path — a collapsed subtree is the natural
    /// unload candidate.
    pub fn setTabCollapsed(self: *Window, page: *c.AdwTabPage, collapsed: bool) void {
        self.tab_forest.setCollapsed(page, collapsed);
        if (collapsed) {
            if (c.adw_tab_view_get_selected_page(self.tab_view)) |sel| {
                if (self.tab_forest.isHidden(sel))
                    c.adw_tab_view_set_selected_page(self.tab_view, page);
            }
            self.discardCollapsedWebPanes(page);
        }
        self.forestChanged();
    }

    /// Discard the web pages of every pane hidden by collapsing
    /// `page`'s subtree (the descendants, not the collapsed tab
    /// itself). Panes without a web face are untouched; discard keeps
    /// the last frame and revives on next look, so this is free.
    fn discardCollapsedWebPanes(self: *Window, page: *c.AdwTabPage) void {
        const webface = @import("webface.zig");
        if (!webface.discardSupported()) return;
        var subtree: std.ArrayList(*c.AdwTabPage) = .empty;
        defer subtree.deinit(self.allocator);
        self.tab_forest.appendSubtree(self.allocator, page, &subtree) catch return;
        if (subtree.items.len <= 1) return;
        for (subtree.items[1..]) |desc| {
            const t = tabTreeOf(desc) orelse continue;
            var leaves: std.ArrayList(*Pane) = .empty;
            defer leaves.deinit(self.allocator);
            t.appendLeaves(self.allocator, &leaves) catch continue;
            for (leaves.items) |pane| {
                if (webface.WebFace.fromPane(pane)) |face| _ = face.discardNow();
            }
        }
    }

    /// Reparent `page` (subtree and all) under `new_parent`, or to
    /// the root level when null — the sidebar drag-drop entry point.
    pub fn tabForestReparent(self: *Window, page: *c.AdwTabPage, new_parent: ?*c.AdwTabPage) void {
        self.tab_forest.reparent(page, new_parent, self.childInsertPos()) catch |err| {
            if (err == error.WouldCycle)
                showToast(self, "Cannot drop a tab into its own subtree.");
            return;
        };
        self.forestChanged();
    }

    /// Show / hide the vertical tree-style tab sidebar
    /// (toggle_tab_sidebar action; startup state = show_tab_sidebar).
    pub fn toggleTabSidebarVisibility(self: *Window) void {
        const sb = self.tab_sidebar orelse return;
        const visible = c.gtk_widget_get_visible(sb.root) != 0;
        c.gtk_widget_set_visible(sb.root, @intFromBool(!visible));
        // Rows are not rebuilt while hidden; catch up on reveal.
        if (!visible) sb.rebuild();
    }

    /// tab_collapse / tab_expand on the selected tab. Collapsing a
    /// tab without children is a no-op rather than a surprise.
    pub fn collapseCurrentTab(self: *Window, collapse: bool) void {
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
        if (collapse and !self.tab_forest.hasChildren(page)) return;
        self.setTabCollapsed(page, collapse);
    }

    /// tab_tree_next / tab_tree_prev: walk the VISIBLE tree order
    /// (collapsed subtrees skipped), wrapping at the ends.
    pub fn tabTreeStep(self: *Window, forward: bool) void {
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
        const next = (self.tab_forest.stepVisible(self.allocator, page, forward) catch return) orelse return;
        c.adw_tab_view_set_selected_page(self.tab_view, next);
    }

    /// Web tab nested under `opener` in the tab tree (a page popup or
    /// an open-link-in-new-tab from that tab). The pending parent is
    /// consumed by the page-attached handler minting the forest node.
    pub fn newWebTabFrom(self: *Window, url: ?[]const u8, opener: ?*c.AdwTabPage) !void {
        self.forest_pending_parent = opener;
        defer self.forest_pending_parent = null;
        try self.newWebTabAt(url);
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
        .cross_search => @import("xsearch.zig").open(self) catch |err| logActionError("cross_search", err),
        .attach_all => _ = self.attachAllSessions(null),
        // The user asked for this one, so a silent no-op is a lie: a
        // toast on top of the log line, but still no dialog.
        .save_layout => self.saveLayoutToDefault() catch |err| {
            logActionError("save_layout", err);
            var msg: [160]u8 = undefined;
            showToast(self, std.fmt.bufPrint(&msg, "Could not save layout: {s}", .{@errorName(err)}) catch "Could not save layout");
        },
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
        .toggle_tab_sidebar => self.toggleTabSidebarVisibility(),
        .tab_collapse => self.collapseCurrentTab(true),
        .tab_expand => self.collapseCurrentTab(false),
        .tab_tree_next => self.tabTreeStep(true),
        .tab_tree_prev => self.tabTreeStep(false),
        .reload_config => self.reloadConfigFromDisk(),
        .launch_app => if (self.focusedPane()) |p| @import("app_launcher.zig").open(self, p),
        .app_windows => @import("app_switcher.zig").open(self),
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
        .new_browser_tab => self.newBrowserTab() catch |err| logActionError("new_browser_tab", err),
        .new_browser_split => self.newBrowserSplit(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch |err| logActionError("new_browser_split", err),
        .new_web_tab => self.newWebTab() catch |err| logActionError("new_web_tab", err),
        .new_web_split => self.newWebSplit(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch |err| logActionError("new_web_split", err),
        // Only reached when the focused pane shows NO web face (the
        // pane-local dispatch consumes it otherwise).
        .web_hints => showToast(self, "This pane shows no web page. Use New Web Tab."),
        // Reader mode belongs to the face, not the window; the window
        // only routes the action to the focused pane's web face.
        .web_reader => if (self.focusedPane()) |p| {
            if (@import("webface.zig").WebFace.fromPane(p)) |face|
                face.toggleReader()
            else
                showToast(self, "This pane has no web page. Use New Web Tab.");
        },
        .web_discard_background => self.discardBackgroundWebTabs(),
        .web_devtools => self.webFaceAction(.devtools),
        .web_print_pdf => self.webFaceAction(.print_pdf),
        .web_fill_password => self.webFaceAction(.fill_password),
        // Both windows work with no web pane in sight: they list the
        // daemon's store, and a row without a face to navigate opens a
        // new web tab.
        .web_history => @import("webhistory.zig").openHistory(self, self.focusedPane()),
        .web_bookmarks => @import("webhistory.zig").openBookmarks(self, self.focusedPane()),
        .close_pane => self.closeFocusedPane(),
        // Only reached when the focused pane has NO browser face (the
        // pane-local dispatch consumes it otherwise): say so, rather
        // than let the action look broken.
        .toggle_browser_face => showToast(self, "This pane has no file browser. Use New File Browser Tab."),
        .new_editor_tab => self.newEditorTab() catch |err| logActionError("new_editor_tab", err),
        .new_editor_split => self.newEditorSplit(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch |err| logActionError("new_editor_split", err),
        // Only reached when the focused pane has NO editor face.
        .toggle_editor_face => showToast(self, "This pane has no editor. Use New Editor Tab."),
        .panel_open => @import("panelpicker.zig").open(self),
        .panel_close => if (!@import("panelhost.zig").closeNearest(self, self.focusedPane()))
            showToast(self, "No panel to close here. Use Open Saved Panel… to show one."),
        .mux_detach => if (self.focusedPane()) |p| self.detachPaneToShell(p),
        .command_palette => palette_mod.open(self) catch |err| logActionError("command_palette", err),
        .hints_open => self.openHints(),
        .copy_mode => self.openCopyMode(),
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
        .files_browse_here => if (self.focusedPane()) |p| self.openBrowserHere(p, null) catch |err|
            logActionError("files_browse_here", err),
        .files_browse_tab => self.newBrowserTabFrom(self.focusedPane(), null) catch |err|
            logActionError("files_browse_tab", err),
        .files_open_app => self.openInFilesApp(),
        .close_pane => self.closeFocusedPane(),
        .zoom_pane => self.toggleZoomPane(),
        .set_pane_title => self.setFocusedPaneTitle(),
        // Detach = close the pane; Terminal.deinit on a remote pane
        // sends DETACH and leaves the session running in the daemon.
        .upload_file => openUploadDialog(self),
        .download_file => if (self.focusedPane()) |p| @import("remote_browser.zig").open(self, p),
        .mux_detach => if (self.focusedPane()) |p| self.detachPaneToShell(p),
        .mux_rename => self.renameFocusedMuxSession(),
        .mux_kill => self.killFocusedMuxSession(),
        .copy_screen => self.copyFocusedScreen(),
        .copy_scrollback => self.copyFocusedScrollback(),
        .screenshot_pane => screenshotFocusedPane(self),
        .record_session => recordFocusedSession(self),
        .record_session_stop => if (self.focusedPane()) |p| p.terminal.requestRecordStop(),
        .launch_remote_app => if (self.focusedPane()) |p| @import("app_launcher.zig").open(self, p),
        .prefs_open => self.openPrefs(),
        .search => self.openSearch(),
        else => {},
    }
}

/// Carries its own allocator: the picker's cancel callback can fire
/// during window teardown, and freeing must not go through `win`.
const ScreenshotCtx = struct {
    win: *Window,
    pane: *Pane,
    allocator: std.mem.Allocator,
};

/// "Record Session (asciicast)…" — pick a .cast destination, then ask
/// the daemon to start recording the focused pane's session. The file
/// is written by the daemon: for SSH/UDP sessions the picked path is
/// interpreted on the REMOTE host.
fn recordFocusedSession(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    if (pane.terminal.remote == null) return;
    const ctx = self.allocator.create(ScreenshotCtx) catch return;
    ctx.* = .{ .win = self, .pane = pane, .allocator = self.allocator };
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .save_file,
            .title = "Record Session As",
            .suggested_name = "session.cast",
            .filters = &.{.{ .label = "Asciicasts", .patterns = &.{"*.cast"} }},
        },
        &onRecordPicked,
        @ptrCast(ctx),
    ) catch {
        self.allocator.destroy(ctx);
        return;
    };
}

fn onRecordPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx = cast.userData(ScreenshotCtx, user);
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up.
    var alive = false;
    for (ctx.win.panes.items) |p| {
        if (p == ctx.pane) {
            alive = true;
            break;
        }
    }
    if (!alive) return;
    // The wire carries a BARE path the session's own daemon resolves,
    // with no way to say "on host X" — so a pick from some third host
    // has no meaning here and is refused rather than silently written
    // somewhere else. A plain path keeps the pre-picker behaviour.
    const path = picker.localPathOrRefuse(
        @ptrCast(ctx.win.app_window),
        res.specs[0],
        "A recording path is resolved by the session's own host — pick a plain path instead.",
    ) orelse return;
    ctx.pane.terminal.requestRecordStart(path);
}

/// "Screenshot Pane…" — render the focused pane to a PNG the user
/// picks a destination for.
fn screenshotFocusedPane(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    const ctx = self.allocator.create(ScreenshotCtx) catch return;
    ctx.* = .{ .win = self, .pane = pane, .allocator = self.allocator };
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .save_file,
            .title = "Save Pane Screenshot",
            .suggested_name = "sketerm.png",
            .filters = &.{.{ .label = "PNG images", .patterns = &.{"*.png"} }},
        },
        &onScreenshotPicked,
        @ptrCast(ctx),
    ) catch {
        self.allocator.destroy(ctx);
        return;
    };
}

fn onScreenshotPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx = cast.userData(ScreenshotCtx, user);
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up.
    var alive = false;
    for (ctx.win.panes.items) |p| {
        if (p == ctx.pane) {
            alive = true;
            break;
        }
    }
    if (!alive) return;
    // The PNG bytes are written by this process — a remote pick has
    // no local file to write to.
    const path = picker.localPathOrRefuse(
        @ptrCast(ctx.win.app_window),
        res.specs[0],
        "Sketerm writes the screenshot itself — pick a location on this machine.",
    ) orelse return;
    const bytes = ctx.pane.screenshotPng() orelse return;
    defer c.g_bytes_unref(bytes);
    var pz: [4096]u8 = undefined;
    const path_z = pathZ(&pz, path) catch return;
    const file = c.g_file_new_for_path(path_z) orelse return;
    defer c.g_object_unref(file);
    var gerr: [*c]c.GError = null;
    // g_file_replace_contents wants the raw buffer; pull it from GBytes.
    var sz: c.gsize = 0;
    const ptr = c.g_bytes_get_data(bytes, &sz);
    _ = c.g_file_replace_contents(file, @ptrCast(ptr), sz, null, 0, c.G_FILE_CREATE_NONE, null, null, &gerr);
    if (gerr != null) c.g_error_free(gerr);
}

/// Carries its own allocator for the same reason ScreenshotCtx does.
const UploadPickCtx = struct {
    win: *Window,
    pane: *Pane,
    allocator: std.mem.Allocator,
};

/// "Upload File…" — pick a local file, then stream it to the focused
/// remote pane's session (which writes it into the shell's cwd).
fn openUploadDialog(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    if (pane.terminal.remote == null) return; // remote panes only
    const ctx = self.allocator.create(UploadPickCtx) catch return;
    ctx.* = .{ .win = self, .pane = pane, .allocator = self.allocator };
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .open_file,
            .title = "Upload File to Remote",
            .accept_label = "Upload",
        },
        &onUploadFilePicked,
        @ptrCast(ctx),
    ) catch {
        self.allocator.destroy(ctx);
        return;
    };
}

fn onUploadFilePicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx = cast.userData(UploadPickCtx, user);
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up.
    var alive = false;
    for (ctx.win.panes.items) |p| {
        if (p == ctx.pane) {
            alive = true;
            break;
        }
    }
    if (!alive) return;
    // startUpload reads the bytes HERE and streams them to the pane's
    // session; there is no local file behind a remote pick.
    const path = picker.localPathOrRefuse(
        @ptrCast(ctx.win.app_window),
        res.specs[0],
        "The upload reads the file from this machine — pick a local file.",
    ) orelse return;
    ctx.pane.terminal.startUpload(&[_][]const u8{path});
}

/// Float a transient toast over the grid (transfer finished / failed).
pub fn showToast(self: *Window, text: []const u8) void {
    var buf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch return;
    const toast = c.adw_toast_new(z.ptr);
    c.adw_toast_set_timeout(toast, 4);
    c.adw_toast_overlay_add_toast(self.toast_overlay, toast);
}

fn onCrashRestartClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const cctx = cast.userData(Window.CrashBtnCtx, user);
    // Reuse the detach-to-shell swap: spawn a fresh session into this slot.
    cctx.window.detachPaneToShell(cctx.pane);
}

fn onRenameActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Window.RenameCtx, user);
    const text = cast.editableText(entry);

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
                    termsinks_mod.setTabPageTitleFromUtf8(win.allocator, ctx.page, t);
                    break;
                }
            }
        }
    } else {
        c.adw_tab_page_set_title(ctx.page, text.ptr);
        c.adw_tab_page_set_tooltip(ctx.page, text.ptr);
        // Mark the page as user-renamed so subsequent OSC titles
        // don't overwrite it. Stored as a non-null marker; the
        // pointer value is unused — `g_object_get_data` only checks
        // for presence.
        c.g_object_set_data(@ptrCast(@alignCast(ctx.page)), "sketerm-title-locked", @ptrCast(ctx.page));
    }
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    // ctx is freed via GDestroyNotify when the
    // signal closure is destroyed.
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

/// Walk every tab page and return the one whose widget tree contains
/// `pane`. O(tabs × panes-per-tab) — both small for any realistic
/// session.
pub fn tabPageForPane(self: *Window, pane: *Pane) ?*c.AdwTabPage {
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
pub fn isDarkBg(bg: [4]f32) bool {
    return (0.2126 * bg[0] + 0.7152 * bg[1] + 0.0722 * bg[2]) < 0.5;
}

/// `win.new-tab` GAction — fires from the header-bar "+" button
/// and is the safety net when no pane has focus.
fn onNewTabAction(_: *c.GSimpleAction, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    if (files_identity) {
        // The "+" of a file-manager window makes a browser tab (at the
        // focused browser's location), not a terminal tab.
        self.newBrowserTabFrom(self.focusedPane(), null) catch |err| {
            std.debug.print("sketerm: new-tab action failed: {s}\n", .{@errorName(err)});
        };
        return;
    }
    self.newShellTab(null) catch |err| {
        std.debug.print("sketerm: new-tab action failed: {s}\n", .{@errorName(err)});
    };
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

/// Accept a pending tab close. Single funnel for every accept branch
/// of the close-page gate, so the tree-style `tab_close_parent =
/// close-subtree` policy applies uniformly: the tab's descendants
/// (captured BEFORE finish detaches the page and the forest promotes
/// them) are closed along with it. Each descendant close re-enters
/// onClosePage with `closing_subtree` set, so it neither re-collects
/// nor recurses; its own dirty-editor veto still applies.
fn acceptTabClose(self: *Window, view: *c.AdwTabView, page: *c.AdwTabPage) void {
    var subtree: std.ArrayList(*c.AdwTabPage) = .empty;
    defer subtree.deinit(self.allocator);
    const close_kids = self.config.tab_close_parent == .close_subtree and !self.closing_subtree;
    if (close_kids) self.tab_forest.appendSubtree(self.allocator, page, &subtree) catch {};
    c.adw_tab_view_close_page_finish(view, page, 1);
    if (close_kids and subtree.items.len > 1) {
        self.closing_subtree = true;
        defer self.closing_subtree = false;
        for (subtree.items[1..]) |desc| _ = c.adw_tab_view_close_page(self.tab_view, desc);
    }
}

/// AdwTabView "close-page" gate. Always returns GDK_EVENT_STOP (TRUE)
/// so we own the close lifecycle; subsequent
/// adw_tab_view_close_page_finish(view, page, accept) actually
/// commits or aborts. Returning FALSE conditionally races.
fn onClosePage(view: *c.AdwTabView, page: *c.AdwTabPage, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);

    // Unsaved editor buffers in this tab veto the close until the
    // user confirms discarding them (saving happens inside the
    // editor face; this gate only prevents silent loss).
    {
        const child = c.adw_tab_page_get_child(page);
        var dirty: usize = 0;
        if (child != null) {
            for (self.panes.items) |p| {
                if (!widgetIsAncestor(@ptrCast(child), p.widget())) continue;
                if (@import("editorview.zig").EditorView.fromPane(p)) |ev| dirty += ev.dirtyCount();
            }
        }
        if (dirty > 0) {
            const pending = self.allocator.create(PendingCloseTab) catch {
                acceptTabClose(self, view, page);
                return 1;
            };
            pending.* = .{ .win = self, .page = page };
            if (confirm.present(self.app_window, .{
                .heading = "Discard unsaved changes?",
                .body = "This tab has editor files with unsaved changes. Closing it discards them.",
                .responses = &.{
                    .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
                    .{ .id = "close", .label = "Discard and Close", .appearance = .destructive },
                },
                .kick_root = self.app_window,
            }, .{ .allocator = self.allocator, .cb = &onCloseTabResponse, .ctx = @ptrCast(pending) }) == null) {
                self.allocator.destroy(pending);
                acceptTabClose(self, view, page);
            }
            return 1;
        }
    }

    if (self.config.confirm_close == .never) {
        acceptTabClose(self, view, page);
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
            acceptTabClose(self, view, page);
            return 1;
        }
    }

    const pending = self.allocator.create(PendingCloseTab) catch {
        // OOM — bail safely by accepting the close.
        acceptTabClose(self, view, page);
        return 1;
    };
    pending.* = .{ .win = self, .page = page };

    if (confirm.present(self.app_window, .{
        .heading = "Close tab?",
        .body = "This tab has split panes. Closing it will end every shell inside.",
        .responses = &.{
            .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
            .{ .id = "close", .label = "Close", .appearance = .destructive },
        },
        .kick_root = self.app_window,
    }, .{ .allocator = self.allocator, .cb = &onCloseTabResponse, .ctx = @ptrCast(pending) }) == null) {
        self.allocator.destroy(pending);
        acceptTabClose(self, view, page);
    }
    return 1;
}

fn onCloseTabResponse(user: ?*anyopaque, resp: []const u8) void {
    const pending = cast.userData(PendingCloseTab, user);
    defer pending.win.allocator.destroy(pending);
    if (std.mem.eql(u8, resp, "close")) {
        acceptTabClose(pending.win, pending.win.tab_view, pending.page);
    } else {
        c.adw_tab_view_close_page_finish(pending.win.tab_view, pending.page, 0);
    }
}

/// Window-level close-request gate. Returning TRUE blocks the close
/// while we ask; on accept we close manually via gtk_window_close.
fn onWindowCloseRequest(_: *c.GtkWindow, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);

    // Capture the layout NOW: the default close destroys every tab
    // before the GApplication shutdown hook runs, which used to save
    // an EMPTY last.json after any X-button close.
    //
    // PRIMARY only: last.json holds ONE window's tabs, so a secondary
    // window closing used to overwrite the whole session with its own
    // handful of tabs.
    if (self.save_on_close and self.is_primary) {
        self.saveLayoutQuietly();
        self.layout_saved_final = true;
    }

    // Unsaved editor buffers veto the close regardless of the
    // confirm_close policy — silent loss of edits is never OK.
    {
        const dirty = self.editorDirtyTotal();
        if (dirty > 0) {
            var body: [160:0]u8 = undefined;
            const b = std.fmt.bufPrintZ(&body, "There {s} {d} editor file{s} with unsaved changes. Closing the window discards them.", .{
                if (dirty == 1) @as([]const u8, "is") else @as([]const u8, "are"),
                dirty,
                if (dirty == 1) @as([]const u8, "") else @as([]const u8, "s"),
            }) catch "There are editor files with unsaved changes.";
            const pending = self.allocator.create(PendingCloseWin) catch return 0;
            pending.* = .{ .win = self };
            if (confirm.present(self.app_window, .{
                .heading = "Discard unsaved changes?",
                .body = b.ptr,
                .responses = &.{
                    .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
                    .{ .id = "close", .label = "Discard and Close", .appearance = .destructive },
                },
                .kick_root = self.app_window,
            }, .{ .allocator = self.allocator, .cb = &onCloseWinResponse, .ctx = @ptrCast(pending) }) == null) {
                self.allocator.destroy(pending);
                return 0;
            }
            return 1;
        }
    }

    if (self.config.confirm_close == .never) return 0;

    const npanes = self.panes.items.len;
    if (self.config.confirm_close == .multiple and npanes <= 1) return 0;

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

    const pending = self.allocator.create(PendingCloseWin) catch return 0;
    pending.* = .{ .win = self };

    if (confirm.present(self.app_window, .{
        .heading = "Close window?",
        .body = body_buf.ptr,
        .responses = &.{
            .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
            .{ .id = "close", .label = "Close", .appearance = .destructive },
        },
        .kick_root = self.app_window,
    }, .{ .allocator = self.allocator, .cb = &onCloseWinResponse, .ctx = @ptrCast(pending) }) == null) {
        self.allocator.destroy(pending);
        return 0;
    }
    return 1; // block while dialog is up
}

fn onCloseWinResponse(user: ?*anyopaque, resp: []const u8) void {
    const pending = cast.userData(PendingCloseWin, user);
    defer pending.win.allocator.destroy(pending);
    if (std.mem.eql(u8, resp, "close")) {
        // Primary only; see onWindowCloseRequest.
        if (pending.win.save_on_close and pending.win.is_primary) {
            pending.win.saveLayoutQuietly();
            pending.win.layout_saved_final = true;
        }
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
/// Tab order moved: `{{ INDEX }}` in a title template is now stale for
/// every tab at or after the change. Cheap when no template uses it.
fn onPageOrderChanged(_: *c.AdwTabView, _: *c.AdwTabPage, _: c_int, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    if (!termsinks_mod.titlefmtUses(self, .index)) return;
    termsinks_mod.refreshAllTitles(self);
}

fn onPageDetached(_: *c.AdwTabView, page: *c.AdwTabPage, _: c_int, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    // Tree-style tabs: drop the page's forest node, PROMOTING its
    // children (they stay in this window whether the page was closed
    // or dragged to another window — a transfer moves one page).
    if (self.tab_forest.find(page) != null) {
        self.tab_forest.remove(page) catch {};
        self.forestChanged();
    }
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
    self.pending_page_detaches += 1;
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
        self.pending_page_detaches -|= 1;
        c.g_object_unref(@ptrCast(@alignCast(page)));
        std.heap.c_allocator.destroy(pending);
        // The destroyed toplevel's deferred free bowed out while this
        // detach was pending; the last one runs it.
        if (self.free_after_detaches and self.pending_page_detaches == 0) self.deinit();
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

    // The toplevel can be destroyed after page-detached queued this idle but
    // before it runs. Its GtkWidget pointer is no longer a valid object then;
    // the finalizer below is already waiting on our pending count.
    if (self.destroying) return 0;

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
    // Tree-style tabs: every page entering this view gets a forest
    // node — a child of its opener when one is pending (the popup /
    // open-in-new-tab path), a root otherwise (plain new tab, tab
    // transferred in from another window).
    if (self.tab_forest.find(page) == null) {
        const opener = self.forest_pending_parent;
        self.forest_pending_parent = null;
        var nested = false;
        if (opener) |parent| {
            if (self.tab_forest.find(parent) != null) {
                _ = self.tab_forest.addChild(page, parent, self.childInsertPos()) catch null;
                nested = self.tab_forest.find(page) != null;
            }
        }
        if (!nested) _ = self.tab_forest.add(page) catch null;
        self.forestChanged();
    }
    const child = c.adw_tab_page_get_child(page) orelse return;
    self.adoptPanesInTree(@ptrCast(child));
    self.updateTaskbarProgress();
}

/// TabBar hidden-page predicate (tree-style tabs): a page inside a
/// collapsed subtree is hidden from the strip.
fn tabForestHiddenHook(ctx: ?*anyopaque, page: *c.AdwTabPage) bool {
    const self = cast.userData(Window, ctx);
    return self.tab_forest.isHidden(page);
}

/// Custom-strip drag-out: a tab was dropped outside any strip. Spawn a
/// secondary window and transfer the page into it (mirrors the AdwTabBar
/// "create-window" behaviour, but driven by our own GtkDragSource).
fn onTabDetach(ctx: ?*anyopaque, view: *c.AdwTabView, page: *c.AdwTabPage) void {
    const self = cast.userData(Window, ctx);
    const win = self.spawnSecondaryWindow() orelse return;
    if (!win.transferPageFrom(view, page, 0))
        c.gtk_window_destroy(@ptrCast(win.app_window));
}

fn onTabTransfer(
    ctx: ?*anyopaque,
    source: *c.AdwTabView,
    page: *c.AdwTabPage,
    position: c_int,
) bool {
    const self = cast.userData(Window, ctx);
    return self.transferPageFrom(source, page, position);
}

/// AdwTabView "create-window": a tab is being dragged out of every
/// existing window. Spawn an empty secondary Window and return its
/// view; libadwaita transfers the page into it.
fn onCreateWindow(_: *c.AdwTabView, user: ?*anyopaque) callconv(.c) ?*c.AdwTabView {
    const self = cast.userData(Window, user);
    const win = self.spawnSecondaryWindow() orelse return null;
    reserveNativeDragDestination(self, win) catch {
        showToast(self, "Could not move the tab: out of memory");
        c.gtk_window_destroy(@ptrCast(win.app_window));
        return null;
    };
    return win.tab_view;
}

/// `create-window` does not identify the dragged page, so reserve for the
/// largest page the source can provide before libadwaita attaches anything.
fn reserveNativeDragDestination(source: *Window, destination: *Window) !void {
    try destination.reserveAdoptionCapacity(source.panes.items.len);
}

/// GTK destroy of the toplevel. Primary: quit the whole app (it owns
/// the IPC socket and layout persistence; orphaned secondaries would
/// be half-functional). Secondary: free the Zig-side Window once the
/// destroy chain has unwound — its pages already tore down via the
/// unmapped path in onPageDetached.
fn onWindowDestroyed(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    self.destroying = true;
    if (self.is_primary) {
        const app = c.g_application_get_default();
        if (app != null) c.g_application_quit(@ptrCast(@alignCast(app)));
        return;
    }
    // Sever the process-global handlers NOW, not in the deferred deinit:
    // the free can be gated behind pending page-detach idles, and a theme
    // flip in that window would walk this window's already-destroyed pane
    // widgets. Idempotent with deinit's own call.
    self.detachGlobalSignals();
    _ = c.g_idle_add(@ptrCast(&deferredWindowFree), @ptrCast(self));
}

fn deferredWindowFree(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);
    if (self.pending_page_detaches != 0) {
        // Hand the free to the last page-detach idle instead of spinning
        // this source until the count drains.
        self.free_after_detaches = true;
        return 0; // G_SOURCE_REMOVE
    }
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
/// per-Pane state down. Without this defer, callbacks from the same
/// widget subtree can still observe partially torn-down Pane state.
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
    // Closing a relay origin may itself close a panel tab and mutate these
    // arrays, so retire all origins under this root before index iteration.
    while (true) {
        var origin: ?*Terminal = null;
        for (self.panes.items) |pane| {
            if (widgetIsAncestor(root, pane.widget()) and pane.terminal.on_panel_origin_close != null) {
                origin = pane.terminal;
                break;
            }
        }
        const terminal = origin orelse break;
        terminal.closePanelOrigin();
    }
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
            // we're about to free — null them now so any callback
            // already queued on the main loop that fires before the
            // deferred teardown runs sees a quiesced Terminal and
            // produces no callbacks.
            // Same story for every face: their widgets die when the
            // detached page drops its last ref, before the deferred
            // Pane.deinit idle runs.
            pane.severFaces();
            term.clearSinks();
            schedulePaneTeardown(pane, term);
            continue;
        }
        i += 1;
    }
}

pub fn widgetIsAncestor(ancestor: *c.GtkWidget, w: *c.GtkWidget) bool {
    var cur: ?*c.GtkWidget = w;
    while (cur) |x| : (cur = c.gtk_widget_get_parent(x)) {
        if (x == ancestor) return true;
    }
    return false;
}

test "fresh native drag window reserve failure leaves ownership unchanged" {
    const a = std.testing.allocator;
    var pane: Pane = undefined;
    var terminal: Terminal = undefined;

    var source: Window = undefined;
    source.allocator = a;
    source.panes = .empty;
    source.terminals = .empty;
    defer source.panes.deinit(a);
    defer source.terminals.deinit(a);
    try source.panes.append(a, &pane);
    try source.terminals.append(a, &terminal);

    for ([_]usize{ 0, 1 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        var destination: Window = undefined;
        destination.allocator = failing.allocator();
        destination.panes = .empty;
        destination.terminals = .empty;
        defer destination.panes.deinit(destination.allocator);
        defer destination.terminals.deinit(destination.allocator);

        try std.testing.expectError(error.OutOfMemory, reserveNativeDragDestination(&source, &destination));
        try std.testing.expectEqualSlices(*Pane, &.{&pane}, source.panes.items);
        try std.testing.expectEqualSlices(*Terminal, &.{&terminal}, source.terminals.items);
        try std.testing.expectEqual(@as(usize, 0), destination.panes.items.len);
        try std.testing.expectEqual(@as(usize, 0), destination.terminals.items.len);
    }
}
