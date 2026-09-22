//! Cross-session search — palette action `cross_search`. AdwDialog
//! with a query entry; Enter searches EVERY session on the local mux
//! daemon server-side (scrollback + live grid, case-insensitive
//! substring) and lists the hits. Activating a hit focuses the pane
//! already showing that session or attaches it as a new tab.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const listdialog = @import("listdialog.zig");
const mux_cli = @import("../ipc/mux_cli.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;

const MAX_PER_SESSION = 20;

const Ctx = struct {
    allocator: std.mem.Allocator,
    /// Row contexts + hit strings; reset on every new query.
    arena: std.heap.ArenaAllocator,
    window: *Window,
    dialog: *c.AdwDialog,
    search_entry: *c.GtkWidget,
    listbox: *c.GtkWidget,
};

const RowCtx = struct {
    ctx: *Ctx,
    session: []const u8,
};

pub fn open(window: *Window) !void {
    const allocator = window.allocator;
    const ctx = try allocator.create(Ctx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .window = window,
        .dialog = undefined,
        .search_entry = undefined,
        .listbox = undefined,
    };

    const ld = listdialog.build(.{
        .title = "Search All Sessions",
        .width = 700,
        .height = 480,
        .search_placeholder = "Search scrollback of every session (Enter)…",
    });
    const dialog = ld.dialog;
    const root = ld.root;
    const search = ld.search.?;
    const listbox = ld.listbox;
    ctx.dialog = dialog;
    ctx.search_entry = search;
    ctx.listbox = listbox;

    // The dialog owns the context: the "closed" handler's destroy-notify
    // is its single free (CLAUDE.md mechanism 1).
    _ = c.g_signal_connect_data(
        dialog,
        "closed",
        @ptrCast(&onClosed),
        @ptrCast(ctx),
        @ptrCast(&freeCtx),
        c.G_CONNECT_DEFAULT,
    );

    // Enter in the entry runs the search (deliberately NOT
    // search-changed: a server-side sweep per keystroke is too heavy).
    _ = c.g_signal_connect_data(search, "activate", @ptrCast(&onActivate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(listbox, "row-activated", @ptrCast(&onRowActivated), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);

    c.adw_dialog_set_child(dialog, root);
    c.adw_dialog_present(dialog, window.app_window);
    _ = c.gtk_widget_grab_focus(search);
}

fn clearList(ctx: *Ctx) void {
    while (c.gtk_widget_get_first_child(ctx.listbox)) |child| {
        c.gtk_list_box_remove(@ptrCast(@alignCast(ctx.listbox)), child);
    }
}

fn addInfoRow(ctx: *Ctx, text: [*:0]const u8) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), text);
    c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 0);
    c.gtk_list_box_append(@ptrCast(@alignCast(ctx.listbox)), row);
}

fn onActivate(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const text_c = c.gtk_editable_get_text(@ptrCast(@alignCast(ctx.search_entry)));
    if (text_c == null) return;
    const pattern = std.mem.span(@as([*:0]const u8, @ptrCast(text_c)));
    clearList(ctx);
    if (pattern.len == 0) return;

    // Fresh arena per query: rows referencing the old strings are
    // gone (clearList above).
    _ = ctx.arena.reset(.free_all);
    const arena = ctx.arena.allocator();

    var sessions = mux_cli.fetchSessions(ctx.allocator, null) orelse {
        addInfoRow(ctx, "mux daemon not reachable");
        return;
    };
    defer sessions.deinit();

    // An allocation failure shows the rows found so far and no verdict.
    var hits: std.ArrayList(Hit) = .empty;
    const complete = if (collectHits(arena, ctx.allocator, sessions.value.sessions, pattern, DaemonSearch{}, &hits)) true else |_| false;
    for (hits.items) |h| {
        const rctx = arena.create(RowCtx) catch return;
        rctx.* = .{ .ctx = ctx, .session = h.session };

        const row = c.adw_action_row_new();
        // Titles are pango markup by default; show hit text verbatim.
        c.adw_preferences_row_set_use_markup(@ptrCast(@alignCast(row)), 0);
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), h.title.ptr);
        c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), h.subtitle.ptr);
        c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 1);
        c.g_object_set_data(@ptrCast(@alignCast(row)), "xsearch-row", @ptrCast(rctx));
        c.gtk_list_box_append(@ptrCast(@alignCast(ctx.listbox)), row);
    }
    if (complete and hits.items.len == 0) addInfoRow(ctx, "no matches");
}

/// One result row, its strings in the dialog's per-query arena.
pub const Hit = struct {
    session: []const u8,
    /// The matching line, verbatim.
    title: [:0]const u8,
    /// Which session, and how many lines back from the live bottom.
    subtitle: [:0]const u8,
};

/// Search every live session of `sessions` and append a row per hit,
/// in session order and then the daemon's own hit order. `searcher`
/// answers `search(gpa, name, pattern, max)` like
/// `mux_cli.searchSession`; a session it cannot answer for is skipped.
pub fn collectHits(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    sessions: []const mux_cli.SessionInfo,
    pattern: []const u8,
    searcher: anytype,
    out: *std.ArrayList(Hit),
) !void {
    for (sessions) |s| {
        if (s.exited) continue;
        const reply = searcher.search(gpa, s.name, pattern, MAX_PER_SESSION) orelse continue;
        defer reply.deinit();
        for (reply.value.hits) |h| {
            const hit = Hit{
                .session = try arena.dupe(u8, s.name),
                .title = try arena.dupeZ(u8, h.text),
                .subtitle = try std.fmt.allocPrintSentinel(arena, "{s}  (line -{d})", .{ s.name, h.back }, 0),
            };
            try out.append(arena, hit);
        }
    }
}

/// The local daemon, one session at a time.
const DaemonSearch = struct {
    fn search(_: DaemonSearch, gpa: std.mem.Allocator, name: []const u8, pattern: []const u8, max: u32) ?std.json.Parsed(mux_cli.SearchReply) {
        return mux_cli.searchSession(gpa, null, name, pattern, max);
    }
};

fn onRowActivated(_: *c.GtkListBox, row: ?*c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    if (row == null) return;
    const raw = c.g_object_get_data(@ptrCast(@alignCast(row)), "xsearch-row") orelse return;
    const rctx: *RowCtx = @ptrCast(@alignCast(raw));
    const win = ctx.window;
    // Copy the name out of the dialog arena BEFORE closing frees it.
    var name_buf: [256]u8 = undefined;
    if (rctx.session.len > name_buf.len) return;
    @memcpy(name_buf[0..rctx.session.len], rctx.session);
    const name = name_buf[0..rctx.session.len];
    c.adw_dialog_force_close(ctx.dialog);
    win.focusOrAttachSession(name);
}

fn onClosed(_: *c.AdwDialog, user: ?*anyopaque) callconv(.c) void {
    _ = user;
    // Cleanup runs via the GDestroyNotify (`freeCtx`).
}

fn freeCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ctx: *Ctx = @ptrCast(@alignCast(u));
        ctx.arena.deinit();
        ctx.allocator.destroy(ctx);
    }
}

// -- tests --------------------------------------------------------------

const testing = std.testing;

/// Canned daemon: each session answers with the JSON search reply it
/// is given, or fails when it has none. Records who was asked what.
const FakeDaemon = struct {
    replies: []const Reply,
    asked: std.ArrayList([]const u8) = .empty,
    last_pattern: []const u8 = "",
    last_max: u32 = 0,

    const Reply = struct { name: []const u8, json: []const u8 };

    fn search(self: *FakeDaemon, gpa: std.mem.Allocator, name: []const u8, pattern: []const u8, max: u32) ?std.json.Parsed(mux_cli.SearchReply) {
        self.asked.append(testing.allocator, name) catch return null;
        self.last_pattern = pattern;
        self.last_max = max;
        for (self.replies) |r| {
            if (!std.mem.eql(u8, r.name, name)) continue;
            return std.json.parseFromSlice(mux_cli.SearchReply, gpa, r.json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch null;
        }
        return null;
    }

    fn deinit(self: *FakeDaemon) void {
        self.asked.deinit(testing.allocator);
    }
};

test "hits come in session order, then the daemon's order, and exited sessions are not asked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sessions = [_]mux_cli.SessionInfo{
        .{ .name = "build" },
        .{ .name = "gone", .exited = true },
        .{ .name = "logs" },
    };
    var daemon = FakeDaemon{ .replies = &.{
        .{ .name = "build", .json = "{\"hits\":[{\"back\":3,\"text\":\"make: *** Error 1\"},{\"back\":0,\"text\":\"error: <b>&</b>\"}],\"total\":2}" },
        .{ .name = "gone", .json = "{\"hits\":[{\"back\":1,\"text\":\"stale error\"}]}" },
        .{ .name = "logs", .json = "{\"hits\":[{\"back\":120,\"text\":\"ERROR disk full\"}]}" },
    } };
    defer daemon.deinit();

    var hits: std.ArrayList(Hit) = .empty;
    try collectHits(arena.allocator(), testing.allocator, &sessions, "error", &daemon, &hits);

    try testing.expectEqual(@as(usize, 3), hits.items.len);
    try testing.expectEqualStrings("build", hits.items[0].session);
    try testing.expectEqualStrings("make: *** Error 1", hits.items[0].title);
    try testing.expectEqualStrings("build  (line -3)", hits.items[0].subtitle);
    // Hit text is shown verbatim, markup characters and all.
    try testing.expectEqualStrings("error: <b>&</b>", hits.items[1].title);
    try testing.expectEqualStrings("build  (line -0)", hits.items[1].subtitle);
    try testing.expectEqualStrings("logs", hits.items[2].session);
    try testing.expectEqualStrings("logs  (line -120)", hits.items[2].subtitle);

    // The exited session was never searched; the query and the
    // per-session cap went to the daemon untouched.
    try testing.expectEqual(@as(usize, 2), daemon.asked.items.len);
    try testing.expectEqualStrings("build", daemon.asked.items[0]);
    try testing.expectEqualStrings("logs", daemon.asked.items[1]);
    try testing.expectEqualStrings("error", daemon.last_pattern);
    try testing.expectEqual(@as(u32, MAX_PER_SESSION), daemon.last_max);
}

test "a session that cannot be searched is skipped and the rest still answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sessions = [_]mux_cli.SessionInfo{ .{ .name = "detached-host" }, .{ .name = "local" } };
    var daemon = FakeDaemon{ .replies = &.{
        // A malformed reply is as good as no reply.
        .{ .name = "detached-host", .json = "{\"hits\":" },
        .{ .name = "local", .json = "{\"hits\":[{\"back\":2,\"text\":\"found\"}]}" },
    } };
    defer daemon.deinit();

    var hits: std.ArrayList(Hit) = .empty;
    try collectHits(arena.allocator(), testing.allocator, &sessions, "found", &daemon, &hits);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqualStrings("local", hits.items[0].session);
    try testing.expectEqual(@as(usize, 2), daemon.asked.items.len);
}

test "no hits anywhere yields no rows at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sessions = [_]mux_cli.SessionInfo{ .{ .name = "a" }, .{ .name = "b" } };
    var daemon = FakeDaemon{ .replies = &.{
        .{ .name = "a", .json = "{\"hits\":[],\"total\":0}" },
        .{ .name = "b", .json = "{}" },
    } };
    defer daemon.deinit();

    var hits: std.ArrayList(Hit) = .empty;
    try collectHits(arena.allocator(), testing.allocator, &sessions, "zzz", &daemon, &hits);
    try testing.expectEqual(@as(usize, 0), hits.items.len);

    // No live session at all asks nobody.
    const dead = [_]mux_cli.SessionInfo{.{ .name = "a", .exited = true }};
    try collectHits(arena.allocator(), testing.allocator, &dead, "zzz", &daemon, &hits);
    try testing.expectEqual(@as(usize, 2), daemon.asked.items.len);
}
