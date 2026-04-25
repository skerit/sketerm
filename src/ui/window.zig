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

pub const Window = struct {
    app_window: *c.GtkWidget,
    tab_view: *c.AdwTabView,
    title_buf: [256]u8 = undefined,
    panes: std.ArrayList(*Pane) = .{},
    terminals: std.ArrayList(*Terminal) = .{},
    allocator: std.mem.Allocator,
    tab_counter: u32 = 0,
    debug_events: bool = false,

    pub fn init(allocator: std.mem.Allocator, app: ?*c.GtkApplication) !*Window {
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);

        const app_window = c.adw_application_window_new(app);
        c.gtk_window_set_title(@ptrCast(app_window), "sketerm");
        c.gtk_window_set_default_size(@ptrCast(app_window), 1000, 700);

        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        const tab_bar_w = c.adw_tab_bar_new();
        const tab_view_w = c.adw_tab_view_new();
        c.adw_tab_bar_set_view(@ptrCast(tab_bar_w), @ptrCast(tab_view_w));
        c.adw_tab_bar_set_autohide(@ptrCast(tab_bar_w), 0);
        c.gtk_widget_set_vexpand(@ptrCast(@alignCast(tab_view_w)), 1);

        c.gtk_box_append(@ptrCast(box), @ptrCast(@alignCast(tab_bar_w)));
        c.gtk_box_append(@ptrCast(box), @ptrCast(@alignCast(tab_view_w)));
        c.adw_application_window_set_content(@ptrCast(app_window), box);

        self.* = .{
            .app_window = app_window,
            .tab_view = @ptrCast(tab_view_w),
            .allocator = allocator,
        };

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

        // Move keyboard focus to the newly selected tab's pane.
        _ = c.g_signal_connect_data(
            tab_view_w,
            "notify::selected-page",
            @ptrCast(&onSelectedPageChanged),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        return self;
    }

    pub fn deinit(self: *Window) void {
        for (self.panes.items) |p| p.deinit();
        for (self.terminals.items) |t| t.deinit();
        self.panes.deinit(self.allocator);
        self.terminals.deinit(self.allocator);
        self.allocator.destroy(self);
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
        try self.addTabInternal(title, &argv, null);
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
        // Title forwarding intentionally null — tab titles are sticky.

        // Wrap pane.widget() in a Box so we can swap it for a Paned
        // when splits happen. Box always has exactly one child.
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_box_append(@ptrCast(wrapper), pane.widget());

        const page = c.adw_tab_view_append(self.tab_view, wrapper);
        c.adw_tab_page_set_title(page, title_z);

        try self.panes.append(self.allocator, pane);
        try self.terminals.append(self.allocator, term);
    }

    fn makePane(self: *Window, term: *Terminal) !*Pane {
        const pane = try Pane.init(self.allocator, term);
        if (pane.input_ctx) |ictx| {
            ictx.shortcut_sink = onShortcut;
            ictx.shortcut_ctx = @ptrCast(self);
        }
        pane.menu_sink = onMenuAction;
        pane.menu_sink_ctx = @ptrCast(self);
        return pane;
    }

    fn spawnShellPane(self: *Window) !*Pane {
        const shell_env = c.getenv("SHELL");
        const shell: [*:0]const u8 = if (shell_env != null) @ptrCast(shell_env) else "/bin/bash";
        const argv = [_][*:0]const u8{shell};
        const pty = try Pty.spawn(.{ .argv = &argv, .rows = 24, .cols = 80 });
        errdefer pty.closeAndReap();

        const term = try Terminal.init(self.allocator, pty, 80, 24);
        errdefer term.deinit();
        term.debug_to_stderr = self.debug_events;

        const pane = try self.makePane(term);
        pane.win_clip_ctx = @ptrCast(self);
        pane.win_on_clipboard = onTermClipboardSet;
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

        // Build new pane.
        const new_pane = try self.spawnShellPane();
        const new_w = new_pane.widget();

        const paned = c.gtk_paned_new(orientation);
        c.gtk_paned_set_resize_start_child(@ptrCast(paned), 1);
        c.gtk_paned_set_resize_end_child(@ptrCast(paned), 1);
        c.gtk_paned_set_shrink_start_child(@ptrCast(paned), 0);
        c.gtk_paned_set_shrink_end_child(@ptrCast(paned), 0);

        // Detach focused widget from parent (where to put new tree depends
        // on parent type).
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

    pub fn closeCurrentTab(self: *Window) void {
        const sel = c.adw_tab_view_get_selected_page(self.tab_view);
        if (sel == null) return;
        _ = c.adw_tab_view_close_page(self.tab_view, sel);
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

    /// Close the focused pane. If it's the only pane in its tab,
    /// closes the tab. Otherwise the pane is removed from its
    /// parent GtkPaned and the sibling takes its place.
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
                return .{ .pane = .{ .cwd = cwd, .command = cmd } };
            }
        }
        return error.PaneNotFound;
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
        else => {},
    }
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
        else => {},
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
    if (text != null) c.adw_tab_page_set_title(ctx.page, text);
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

/// Move keyboard focus into the newly selected tab's pane so
/// typing immediately reaches that PTY.
fn onSelectedPageChanged(view: *c.AdwTabView, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user.?));
    const page = c.adw_tab_view_get_selected_page(view);
    if (page == null) return;
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
}

fn collectAndFreePanes(self: *Window, root: *c.GtkWidget) void {
    // Walk the widget tree under `root` (Box / Paned / GLArea), find
    // matching Panes by their .widget(), and free them + their Terminal.
    var i: usize = 0;
    while (i < self.panes.items.len) {
        const pane = self.panes.items[i];
        if (widgetIsAncestor(root, pane.widget())) {
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
