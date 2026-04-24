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
    pub fn newShellTab(self: *Window, title: [*:0]const u8) !void {
        const shell_env = c.getenv("SHELL");
        const shell: [*:0]const u8 = if (shell_env != null) @ptrCast(shell_env) else "/bin/bash";
        const argv = [_][*:0]const u8{shell};
        try self.addTabInternal(title, &argv, null);
    }

    /// Spawn a new tab from a layout TabSpec (used on --restore).
    pub fn newTabFromSpec(self: *Window, spec: @import("../layout.zig").TabSpec) !void {
        if (spec.command.len == 0) return error.EmptyCommand;

        // Allocate null-terminated argv strings.
        var argv_buf = try self.allocator.alloc([*:0]const u8, spec.command.len);
        defer self.allocator.free(argv_buf);
        var arg_owners: std.ArrayList([:0]u8) = .{};
        defer {
            for (arg_owners.items) |s| self.allocator.free(s);
            arg_owners.deinit(self.allocator);
        }
        for (spec.command, 0..) |cmd, i| {
            const z = try self.allocator.allocSentinel(u8, cmd.len, 0);
            try arg_owners.append(self.allocator, z);
            @memcpy(z, cmd);
            argv_buf[i] = z.ptr;
        }

        const title_z = try self.allocator.allocSentinel(u8, spec.title.len, 0);
        defer self.allocator.free(title_z);
        @memcpy(title_z, spec.title);

        try self.addTabInternal(title_z, argv_buf, spec.cwd);
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

        term.user_ctx = @ptrCast(self);
        term.on_clipboard_set = onTermClipboardSet;

        const pane = try Pane.init(self.allocator, term);

        if (pane.input_ctx) |ictx| {
            ictx.shortcut_sink = onShortcut;
            ictx.shortcut_ctx = @ptrCast(self);
        }
        pane.menu_sink = onMenuAction;
        pane.menu_sink_ctx = @ptrCast(self);

        const page = c.adw_tab_view_append(self.tab_view, pane.widget());
        c.adw_tab_page_set_title(page, title_z);

        try self.panes.append(self.allocator, pane);
        try self.terminals.append(self.allocator, term);
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

    /// Build a Layout snapshot of the current window state.
    /// Caller must arena-free or otherwise track strings.
    pub fn collectLayout(self: *Window, arena: std.mem.Allocator) !layout_mod.Layout {
        var tabs: std.ArrayList(layout_mod.TabSpec) = .{};
        const n_pages = c.adw_tab_view_get_n_pages(self.tab_view);
        var i: c_int = 0;
        while (i < n_pages) : (i += 1) {
            if (i >= self.terminals.items.len) break;
            const term = self.terminals.items[@intCast(i)];
            const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
            const title_cstr = c.adw_tab_page_get_title(page);
            const title = if (title_cstr != null) std.mem.span(@as([*:0]const u8, @ptrCast(title_cstr))) else "";

            const cwd = layout_mod.cwdOfPid(term.pty.child_pid, arena) catch try arena.dupe(u8, "/");
            const cmd = try arena.alloc([]const u8, 1);
            cmd[0] = try arena.dupe(u8, std.posix.getenv("SHELL") orelse "/bin/bash");
            try tabs.append(arena, .{
                .title = try arena.dupe(u8, title),
                .cwd = cwd,
                .command = cmd,
            });
        }
        return .{ .version = 1, .tabs = try tabs.toOwnedSlice(arena) };
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
        .new_tab => self.newShellTab("shell") catch {},
        .close_tab => self.closeCurrentTab(),
        .next_tab => self.nextTab(),
        .prev_tab => self.prevTab(),
        else => {},
    }
}

fn onMenuAction(ctx: ?*anyopaque, action: @import("menu.zig").Action) void {
    const self: *Window = @ptrCast(@alignCast(ctx.?));
    switch (action) {
        .new_tab => self.newShellTab("shell") catch {},
        .close_tab => self.closeCurrentTab(),
        .rename_tab => {
            // TODO: show GtkPopover with GtkEntry. Stub for now.
        },
        .split_h, .split_v, .close_pane => {
            // TODO: M7 implements splits. Stub.
        },
        else => {},
    }
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
