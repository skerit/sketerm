//! Window — wraps an AdwApplicationWindow with AdwTabView + TabBar.
//!
//! Each tab hosts one Pane (one Terminal). Multi-pane (split) per
//! tab arrives in M7.

const std = @import("std");
const c = @import("../c.zig").c;
const Pane = @import("pane.zig").Pane;
const Pty = @import("../pty.zig").Pty;
const Terminal = @import("../terminal.zig").Terminal;
const layout_mod = @import("../layout.zig");
const Config = @import("../config.zig").Config;

pub const Window = struct {
    app_window: *c.GtkWidget,
    tab_view: *c.AdwTabView,
    /// Held so applyConfigChange can re-parent the tab bar between
    /// top and bottom of the toolbar view at runtime.
    tab_bar: *c.GtkWidget,
    toolbar_view: *c.GtkWidget,
    title_buf: [256]u8 = undefined,
    panes: std.ArrayList(*Pane) = .{},
    terminals: std.ArrayList(*Terminal) = .{},
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
    search_matches: std.ArrayList(@import("../grid/screen.zig").Screen.SearchMatch) = .{},
    search_idx: usize = 0,
    /// Case-insensitive search toggle. Defaults to smart-case
    /// (lower-only needle implies CI; mixed-case implies CS).
    search_case_insensitive: bool = false,
    search_case_button: ?*c.GtkWidget = null,

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

        return self;
    }

    pub fn deinit(self: *Window) void {
        for (self.panes.items) |p| p.deinit();
        for (self.terminals.items) |t| t.deinit();
        self.panes.deinit(self.allocator);
        self.terminals.deinit(self.allocator);
        self.search_matches.deinit(self.allocator);
        self.config.deinit();
        self.allocator.destroy(self);
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
            _ = c.gtk_widget_grab_focus(p.widget());
        }
        self.search_pane = null;
        self.search_matches.clearRetainingCapacity();
        self.search_idx = 0;
    }

    fn updateSearch(self: *Window, query: []const u8) void {
        const pane = self.search_pane orelse return;
        self.search_matches.deinit(self.allocator);
        self.search_matches = .{};
        self.search_idx = 0;
        if (query.len > 0) {
            // Smart-case: lowercase-only needle implies CI; any
            // uppercase letter forces CS. The explicit toggle wins
            // either way.
            var ci = self.search_case_insensitive;
            if (!ci) {
                var has_upper = false;
                for (query) |b| {
                    if (b >= 'A' and b <= 'Z') {
                        has_upper = true;
                        break;
                    }
                }
                ci = !has_upper;
            }
            const matches = pane.terminal.screen.searchOpts(self.allocator, query, ci) catch return;
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

    /// Spawn a new shell pane and add it as a tab.
    /// If title == null, a "Tab N" default is used.
    pub fn newShellTab(self: *Window, title_opt: ?[*:0]const u8) !void {
        const shell_env = c.getenv("SHELL");
        const shell: [*:0]const u8 = if (shell_env != null) @ptrCast(shell_env) else "/bin/bash";
        const argv = [_][*:0]const u8{shell};

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
        try self.addTabInternal(title, &argv, cwd);
    }

    /// Last-reported cwd of the focused pane (OSC 7), or null if no
    /// pane has the focus or no cwd has been reported.
    fn focusedPaneCwd(self: *Window) ?[]const u8 {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return null;
        for (self.panes.items) |p| {
            if (focus == @as(*c.GtkWidget, @ptrCast(p.widget()))) {
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

        const page = c.adw_tab_view_append(self.tab_view, wrapper);
        c.adw_tab_page_set_title(page, title_z.ptr);
        c.adw_tab_page_set_tooltip(page, title_z.ptr);
    }

    fn buildTreeWidget(self: *Window, tree: @import("../layout.zig").Tree) !*c.GtkWidget {
        switch (tree) {
            .pane => |p| {
                if (p.command.len == 0) return error.EmptyCommand;

                var argv_buf = try self.allocator.alloc([*:0]const u8, p.command.len);
                defer self.allocator.free(argv_buf);
                var arg_owners: std.ArrayList([:0]u8) = .{};
                defer {
                    for (arg_owners.items) |s| self.allocator.free(s);
                    arg_owners.deinit(self.allocator);
                }
                for (p.command, 0..) |cmd, i| {
                    const z = try self.allocator.allocSentinel(u8, cmd.len, 0);
                    try arg_owners.append(self.allocator, z);
                    @memcpy(z, cmd);
                    argv_buf[i] = z.ptr;
                }

                const pty = try Pty.spawn(.{
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
                pane.win_clip_ctx = @ptrCast(self);
                pane.win_on_clipboard = onTermClipboardSet;
                pane.win_notify_ctx = @ptrCast(self);
                pane.win_on_notification = onTermNotification;
                pane.win_bell_ctx = @ptrCast(self);
                pane.win_on_bell = onTermBell;
                pane.win_child_ctx = @ptrCast(self);
                pane.win_on_child_exit = onTermChildExit;
                pane.font_size = p.font_size orelse self.config.font_size;
                pane.font_path = self.config.font_path;
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

                const first = try self.buildTreeWidget(s.children[0]);
                const second = try self.buildTreeWidget(s.children[1]);
                c.gtk_paned_set_start_child(@ptrCast(paned), first);
                c.gtk_paned_set_end_child(@ptrCast(paned), second);

                // Apply saved ratio after the widget gets its first
                // allocation. Until then we don't know the total
                // size in pixels.
                const ratio_holder = try self.allocator.create(f32);
                ratio_holder.* = if (s.ratio > 0 and s.ratio < 1) s.ratio else 0.5;
                _ = c.g_signal_connect_data(
                    paned,
                    "notify::default-width",
                    @ptrCast(&applyPanedRatio),
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
        const pty = try Pty.spawn(.{
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

        // Forward terminal sinks to Window where appropriate.
        pane.win_clip_ctx = @ptrCast(self);
        pane.win_on_clipboard = onTermClipboardSet;
        pane.win_notify_ctx = @ptrCast(self);
        pane.win_on_notification = onTermNotification;
        pane.win_bell_ctx = @ptrCast(self);
        pane.win_on_bell = onTermBell;
        pane.win_child_ctx = @ptrCast(self);
        pane.win_on_child_exit = onTermChildExit;
        // Title forwarding intentionally null — tab titles are sticky.

        // Wrap pane.widget() in a Box so we can swap it for a Paned
        // when splits happen. Box always has exactly one child.
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_box_append(@ptrCast(wrapper), pane.widget());

        const page = c.adw_tab_view_append(self.tab_view, wrapper);
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
        }
        pane.menu_sink = onMenuAction;
        pane.menu_sink_ctx = @ptrCast(self);
        pane.image_store.debug = self.debug_images;
        pane.image_pass.debug = self.debug_images;
        pane.terminal.screen.kitty_images.debug = self.debug_images;
        return pane;
    }

    fn spawnShellPane(self: *Window) !*Pane {
        return self.spawnShellPaneOpts(null);
    }

    /// Spawn a shell with an optional starting cwd. When inherit_cwd
    /// is non-null, passed to PTY so the child starts there.
    fn spawnShellPaneOpts(self: *Window, inherit_cwd: ?[]const u8) !*Pane {
        // Config-driven shell, with $SHELL fallback, then /bin/bash.
        var shell_buf: [256:0]u8 = undefined;
        const shell: [*:0]const u8 = if (self.config.shell) |s| blk: {
            const n = @min(s.len, shell_buf.len);
            @memcpy(shell_buf[0..n], s[0..n]);
            shell_buf[n] = 0;
            break :blk @ptrCast(&shell_buf);
        } else if (c.getenv("SHELL")) |env_ptr| @as([*:0]const u8, @ptrCast(env_ptr)) else "/bin/bash";

        const argv = [_][*:0]const u8{shell};

        // Build TERM/COLORTERM as null-terminated for the child env.
        var term_buf: [64:0]u8 = undefined;
        var ct_buf: [64:0]u8 = undefined;
        const tlen = @min(self.config.term_env.len, term_buf.len);
        @memcpy(term_buf[0..tlen], self.config.term_env[0..tlen]);
        term_buf[tlen] = 0;
        const ctlen = @min(self.config.color_term_env.len, ct_buf.len);
        @memcpy(ct_buf[0..ctlen], self.config.color_term_env[0..ctlen]);
        ct_buf[ctlen] = 0;

        const pty = try Pty.spawn(.{
            .argv = &argv,
            .rows = 24,
            .cols = 80,
            .term = @ptrCast(&term_buf),
            .color_term = @ptrCast(&ct_buf),
            .cwd = inherit_cwd,
            .login_shell = self.config.login_shell,
        });
        errdefer pty.closeAndReap();

        const term = try Terminal.init(self.allocator, pty, 80, 24);
        errdefer term.deinit();
        term.debug_to_stderr = self.debug_events;

        const pane = try self.makePane(term);
        pane.win_clip_ctx = @ptrCast(self);
        pane.win_on_clipboard = onTermClipboardSet;
        pane.win_notify_ctx = @ptrCast(self);
        pane.win_on_notification = onTermNotification;
        pane.win_bell_ctx = @ptrCast(self);
        pane.win_on_bell = onTermBell;
        pane.win_child_ctx = @ptrCast(self);
        pane.win_on_child_exit = onTermChildExit;
        // Push config-derived fields into the pane before realize.
        pane.font_size = self.config.font_size;
        pane.font_path = self.config.font_path;
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
        term.screen.scrollback_capacity = self.config.scrollback;
        term.screen.bracketed_paste = self.config.bracketed_paste;
        term.screen.scroll_on_output = self.config.scroll_on_output;
        term.screen.word_chars = self.config.word_chars;
        // Resolve effective palette: explicit `palette` wins, else
        // look up `scheme` if set, else leave defaults.
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

        // Find the focused Pane.
        var found_idx: ?usize = null;
        for (self.panes.items, 0..) |p, idx| {
            if (@intFromPtr(p.widget()) == @intFromPtr(focus)) {
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
        const new_pane = try self.spawnShellPaneOpts(inherit_cwd);
        const new_w = new_pane.widget();

        const paned = c.gtk_paned_new(orientation);
        c.gtk_paned_set_resize_start_child(@ptrCast(paned), 1);
        c.gtk_paned_set_resize_end_child(@ptrCast(paned), 1);
        c.gtk_paned_set_shrink_start_child(@ptrCast(paned), 0);
        c.gtk_paned_set_shrink_end_child(@ptrCast(paned), 0);
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
        const ratio_holder = try self.allocator.create(f32);
        ratio_holder.* = 0.5;
        _ = c.g_signal_connect_data(
            paned,
            "map",
            @ptrCast(&applyPanedRatioMap),
            @ptrCast(ratio_holder),
            @ptrCast(&freePanedRatio),
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
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("sketerm: cannot open {s}: {s}\n", .{ path, @errorName(err) });
            return false;
        };
        defer file.close();
        const bytes = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
            std.debug.print("sketerm: read {s}: {s}\n", .{ path, @errorName(err) });
            return false;
        };
        defer self.allocator.free(bytes);
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
    };

    /// Show a popover with an entry pre-filled to the current tab's
    /// title. Pressing Enter renames; Escape dismisses.
    pub fn renameCurrentTab(self: *Window) void {
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
        c.gtk_widget_set_parent(popover, self.app_window);

        const ctx = self.allocator.create(RenameCtx) catch return;
        ctx.* = .{
            .page = page,
            .popover = popover,
            .entry = entry,
            .allocator = self.allocator,
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
    fn resolveDefaultColors(self: *const Window) ColorPair {
        if (!self.config.auto_theme) {
            return .{ .fg = self.config.default_fg, .bg = self.config.default_bg };
        }
        const sm = c.adw_style_manager_get_default();
        const dark = c.adw_style_manager_get_dark(sm) != 0;
        if (dark) {
            return .{
                .fg = .{ 0.92, 0.92, 0.92, 1.0 },
                .bg = .{ 0.10, 0.10, 0.10, 1.0 },
            };
        } else {
            return .{
                .fg = .{ 0.10, 0.10, 0.10, 1.0 },
                .bg = .{ 0.97, 0.97, 0.97, 1.0 },
            };
        }
    }

    const PromptDir = enum { prev, next };

    fn jumpPromptOnFocused(self: *Window, dir: PromptDir) void {
        const pane = self.focusedPane() orelse return;
        const screen = pane.terminal.screen;
        _ = switch (dir) {
            .prev => screen.jumpPrevPrompt(),
            .next => screen.jumpNextPrompt(),
        };
        c.gtk_widget_queue_draw(pane.widget());
    }

    fn focusedPane(self: *Window) ?*Pane {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return null;
        for (self.panes.items) |p| {
            if (@intFromPtr(p.widget()) == @intFromPtr(focus)) return p;
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
        var in_tab: std.ArrayList(*Pane) = .{};
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
                if (focus == @as(*c.GtkWidget, @ptrCast(p.widget()))) {
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
        _ = c.gtk_widget_grab_focus(@ptrCast(in_tab.items[next].widget()));
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
        const old_blink_ms = self.config.cursor_blink_ms;
        const old_tab_pos = self.config.tab_position;
        // Replace config wholesale, but dup any string fields into
        // the long-lived Window.config.arena. Without this, strings
        // duped by the dialog into its own arena would dangle when
        // the dialog closes.
        self.config = new_cfg.*;
        if (self.config.arena == null) self.config.arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena = self.config.arena.?.allocator();
        if (self.config.font_path) |fp| self.config.font_path = arena.dupe(u8, fp) catch self.config.font_path;
        if (self.config.shell) |sh| self.config.shell = arena.dupe(u8, sh) catch self.config.shell;
        self.config.term_env = arena.dupe(u8, self.config.term_env) catch self.config.term_env;
        self.config.color_term_env = arena.dupe(u8, self.config.color_term_env) catch self.config.color_term_env;
        self.config.word_chars = arena.dupe(u8, self.config.word_chars) catch self.config.word_chars;
        if (self.config.scheme.len > 0) self.config.scheme = arena.dupe(u8, self.config.scheme) catch self.config.scheme;

        // Push into every pane.
        for (self.panes.items) |p| {
            const screen = p.terminal.screen;
            // Colors.
            screen.default_fg = self.config.default_fg;
            screen.default_bg = self.config.default_bg;
            // Renderer convention: alpha=0 means "use fg colour". We
            // map cursor_color_default → that sentinel.
            screen.cursor_color = if (self.config.cursor_color_default)
                .{ 0, 0, 0, 0 }
            else
                self.config.cursor_color;
            p.grid_pass.default_fg = self.config.default_fg;
            p.grid_pass.default_bg = self.config.default_bg;
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
            // Behavior.
            screen.bracketed_paste = self.config.bracketed_paste;
            screen.modify_other_keys = self.config.modify_other_keys;
            screen.scrollback_capacity = self.config.scrollback;
            screen.scroll_on_output = self.config.scroll_on_output;
            screen.word_chars = self.config.word_chars;
            if (p.input_ctx) |ictx| ictx.smart_copy = self.config.smart_copy;
            // Repaint.
            screen.dirty = true;
            p.cell_pass.markAllDirty();
            c.gtk_widget_queue_draw(p.widget());
        }

        // Font size needs the heavy atlas-rebuild path.
        if (self.config.font_size != old_size) {
            for (self.panes.items) |p| p.setFontSize(self.config.font_size);
        }

        // Tab position swap.
        if (self.config.tab_position != old_tab_pos) {
            self.setTabPosition(self.config.tab_position);
        }

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
        _ = c.gtk_widget_grab_focus(w);
        self.closeFocusedPane();
    }

    pub fn closeFocusedPane(self: *Window) void {
        const focus = c.gtk_window_get_focus(@ptrCast(self.app_window)) orelse return;
        var found_idx: ?usize = null;
        for (self.panes.items, 0..) |p, idx| {
            if (@intFromPtr(p.widget()) == @intFromPtr(focus)) {
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
        _ = self.panes.orderedRemove(found_idx.?);
        const term = pane.terminal;
        for (self.terminals.items, 0..) |t, ti| {
            if (t == term) {
                _ = self.terminals.orderedRemove(ti);
                break;
            }
        }
        term.deinit();
        pane.deinit();

        // Move focus to the first pane inside the surviving sibling
        // subtree — without this, focus can land on the now-empty
        // GtkPaned wrapper and keypresses go nowhere.
        if (sibling) |sib| {
            for (self.panes.items) |p| {
                if (widgetIsAncestor(@ptrCast(sib), @ptrCast(p.widget()))) {
                    _ = c.gtk_widget_grab_focus(p.widget());
                    break;
                }
            }
        }
    }

    /// Build a Layout snapshot of the current window state.
    /// Caller must arena-free or otherwise track strings.
    pub fn collectLayout(self: *Window, arena: std.mem.Allocator) !layout_mod.Layout {
        var tabs: std.ArrayList(layout_mod.TabSpec) = .{};
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
                const cmd = try arena.alloc([]const u8, 1);
                cmd[0] = try arena.dupe(u8, std.posix.getenv("SHELL") orelse "/bin/bash");
                // Save font_size only if it diverges from the global
                // default — keeps layout files terse.
                const fs: ?u16 = if (p.font_size != self.config.font_size) p.font_size else null;
                return .{ .pane = .{ .cwd = cwd, .command = cmd, .font_size = fs } };
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
};

fn onShortcut(ctx: ?*anyopaque, action: @import("input.zig").Action) void {
    const self: *Window = @ptrCast(@alignCast(ctx.?));
    switch (action) {
        .new_tab => self.newShellTab(null) catch {},
        .close_tab => self.closeCurrentTab(),
        .next_tab => self.nextTab(),
        .prev_tab => self.prevTab(),
        .split_h => self.splitFocused(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch {},
        .split_v => self.splitFocused(@intCast(c.GTK_ORIENTATION_VERTICAL)) catch {},
        .font_inc => self.adjustFocusedFontSize(1),
        .font_dec => self.adjustFocusedFontSize(-1),
        .font_reset => self.resetFocusedFontSize(),
        .search_open => self.openSearch(),
        .save_layout => self.saveLayoutQuietly(),
        .save_layout_as => self.saveLayoutAs(),
        .prompt_prev => self.jumpPromptOnFocused(.prev),
        .prompt_next => self.jumpPromptOnFocused(.next),
        .pane_prev => self.cyclePane(.prev),
        .pane_next => self.cyclePane(.next),
        .prefs_open => self.openPrefs(),
        else => {},
    }
}


fn onSearchChanged(entry: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
    const text_ptr = c.gtk_editable_get_text(@ptrCast(entry));
    if (text_ptr == null) return;
    const cstr: [*:0]const u8 = @ptrCast(text_ptr);
    const len = std.mem.len(cstr);
    self.updateSearch(cstr[0..len]);
}

fn onSearchActivate(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
    self.nextMatch();
}

fn onSearchStop(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
    self.closeSearch();
}

fn onSearchClose(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
    self.closeSearch();
}

fn onSearchNext(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
    self.nextMatch();
}

fn onSearchPrev(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
    self.prevMatch();
}

fn onSearchKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const self: *Window = @ptrCast(@alignCast(user.?));
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
    return 0;
}

fn onMenuAction(ctx: ?*anyopaque, action: @import("menu.zig").Action) void {
    const self: *Window = @ptrCast(@alignCast(ctx.?));
    switch (action) {
        .new_tab => self.newShellTab(null) catch {},
        .close_tab => self.closeCurrentTab(),
        .rename_tab => self.renameCurrentTab(),
        .split_h => self.splitFocused(@intCast(c.GTK_ORIENTATION_HORIZONTAL)) catch {},
        .split_v => self.splitFocused(@intCast(c.GTK_ORIENTATION_VERTICAL)) catch {},
        .close_pane => self.closeFocusedPane(),
        .prefs_open => self.openPrefs(),
        else => {},
    }
}

fn onSaveLayoutAsDone(source: *c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
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
    const self: *Window = @ptrCast(@alignCast(user.?));
    if (!self.config.auto_theme) return;
    const fg_bg = self.resolveDefaultColors();
    for (self.panes.items) |p| {
        p.grid_pass.default_fg = fg_bg.fg;
        p.grid_pass.default_bg = fg_bg.bg;
        p.terminal.screen.default_fg = fg_bg.fg;
        p.terminal.screen.default_bg = fg_bg.bg;
        p.terminal.screen.dirty = true;
        c.gtk_widget_queue_draw(p.widget());
    }
}

fn applyPanedRatio(paned: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    applyPanedRatioImpl(@ptrCast(paned), user);
}

fn applyPanedRatioMap(paned: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    applyPanedRatioImpl(paned, user);
}

fn applyPanedRatioImpl(paned: *c.GtkWidget, user: ?*anyopaque) void {
    const ratio_ptr: *f32 = @ptrCast(@alignCast(user.?));
    const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(paned)));
    const total: c_int = if (orientation == c.GTK_ORIENTATION_HORIZONTAL)
        c.gtk_widget_get_width(paned)
    else
        c.gtk_widget_get_height(paned);
    if (total <= 0) return;
    const pos: c_int = @intFromFloat(@as(f32, @floatFromInt(total)) * ratio_ptr.*);
    c.gtk_paned_set_position(@ptrCast(paned), pos);
}

fn freePanedRatio(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ratio_ptr: *f32 = @ptrCast(@alignCast(u));
        // We don't know the allocator here; for v1 leak. Bounded.
        // (Future: wrap in a struct with allocator like RenameCtx.)
        _ = ratio_ptr;
    }
}

fn onRenameActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx: *Window.RenameCtx = @ptrCast(@alignCast(user.?));
    const text = c.gtk_editable_get_text(@ptrCast(entry));
    if (text != null) {
        c.adw_tab_page_set_title(ctx.page, text);
        c.adw_tab_page_set_tooltip(ctx.page, text);
    }
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    // ctx is freed via GDestroyNotify (freeRenameCtx) when the
    // signal closure is destroyed.
}

fn freeRenameCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx: *Window.RenameCtx = @ptrCast(@alignCast(user.?));
    ctx.allocator.destroy(ctx);
}

fn onTermClipboardSet(ctx: ?*anyopaque, text: []const u8) void {
    const self: *Window = @ptrCast(@alignCast(ctx.?));
    const display = c.gtk_widget_get_display(self.app_window);
    const clip = c.gdk_display_get_clipboard(display);
    const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return;
    defer self.allocator.free(cstr);
    @memcpy(cstr, text);
    c.gdk_clipboard_set_text(clip, cstr.ptr);
}

fn onTermChildExit(ctx: ?*anyopaque, pane: *Pane, status: i32) void {
    const self: *Window = @ptrCast(@alignCast(ctx.?));
    _ = status;
    switch (self.config.exit_action) {
        .close => self.closePane(pane),
        .restart => {
            // Spawn a fresh shell in a new pane and replace the
            // exited one. v1 implementation: just close the dead
            // pane and spawn a new tab. Truly in-place restart
            // would need PTY-level surgery in Terminal.
            self.closePane(pane);
            self.newShellTab(null) catch {};
        },
        .hold => {
            // Already showed the "[process exited]" banner; do
            // nothing further. User can close the pane manually.
        },
    }
}

fn onTermBell(ctx: ?*anyopaque, pane: *Pane) void {
    const self: *Window = @ptrCast(@alignCast(ctx.?));

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

fn onTermNotification(ctx: ?*anyopaque, title: []const u8, body: []const u8) void {
    const self: *Window = @ptrCast(@alignCast(ctx.?));
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
    const self: *Window = @ptrCast(@alignCast(user.?));
    self.newShellTab(null) catch |err| {
        std.debug.print("sketerm: new-tab action failed: {s}\n", .{@errorName(err)});
    };
}

/// Open the rename popover on a double-click on the tab bar. The
/// single-click that AdwTabBar handles internally has already
/// selected the right tab, so renameCurrentTab targets it.
fn onTabBarPressed(g: *c.GtkGestureClick, n_press: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    if (n_press != 2) return;
    const self: *Window = @ptrCast(@alignCast(user.?));
    _ = g;
    self.renameCurrentTab();
}

/// Move keyboard focus into the newly selected tab's pane so
/// typing immediately reaches that PTY.
fn onSelectedPageChanged(view: *c.AdwTabView, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
    const page = c.adw_tab_view_get_selected_page(view);
    if (page == null) return;
    // Clear any needs-attention from the now-active tab.
    c.adw_tab_page_set_needs_attention(page, 0);
    const child = c.adw_tab_page_get_child(page);
    if (child == null) return;
    // Find the first Pane whose widget is a descendant of `child`.
    for (self.panes.items) |p| {
        if (widgetIsAncestor(@ptrCast(child), p.widget())) {
            _ = c.gtk_widget_grab_focus(p.widget());
            return;
        }
    }
}

/// Tear down all Zig-side panes + terminals that lived in this
/// AdwTabPage's widget tree. Called when the user closes a tab.
fn onPageDetached(_: *c.AdwTabView, page: *c.AdwTabPage, _: c_int, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
    const child = c.adw_tab_page_get_child(page);
    if (child == null) return;
    collectAndFreePanes(self, @ptrCast(child));

    // If the user just closed the last tab via the AdwTabView "X"
    // button (which bypasses closeCurrentTab), keep the window
    // alive by auto-spawning a fresh shell. Skip during app
    // shutdown — once the window is no longer mapped, this signal
    // is firing as part of teardown and we'd just leak.
    if (c.gtk_widget_get_mapped(self.app_window) == 0) return;
    if (c.adw_tab_view_get_n_pages(self.tab_view) == 0) {
        self.newShellTab(null) catch |err| {
            std.debug.print("sketerm: replacement tab spawn failed: {s}\n", .{@errorName(err)});
        };
    }
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

            const term = pane.terminal;
            _ = self.panes.orderedRemove(i);
            for (self.terminals.items, 0..) |t, ti| {
                if (t == term) {
                    _ = self.terminals.orderedRemove(ti);
                    break;
                }
            }
            term.deinit();
            pane.deinit();
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
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/config.conf", .{x});
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/sketerm/config.conf", .{home});
    }
    return error.NoConfigPath;
}
