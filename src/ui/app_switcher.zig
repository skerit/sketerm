//! App-window switcher — a tab-switcher for forwarded GUI apps.
//! Lists every open app window this GUI renders (tabless sessions
//! and pane-hosted apps) with live thumbnails, plus ATTACHABLE app
//! sessions: ones running on the local daemon this window isn't
//! showing, and ones on assistant (MCP) daemon instances
//! ($XDG_RUNTIME_DIR/sketerm/mcp-*/mux.sock) — activate to raise the
//! window, focus its tab, or attach as a live viewer ("watch what
//! the assistant is doing"; input is a shared seat).
//!
//! Lifetime: heap-allocated `Switcher`, freed on the dialog
//! "destroy". Entries snapshot names/hosts at open time; activation
//! re-validates through the Window's live lists where it matters.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const profile = @import("../util/profile.zig");
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;
const Terminal = @import("../terminal.zig").Terminal;
const AppHost = @import("../wlapp.zig").AppHost;
const appdrive = @import("../ipc/appdrive.zig");
const mux_cli = @import("../ipc/mux_cli.zig");

const Entry = struct {
    kind: enum { win_floating, win_embedded, attach },
    /// win_* rows: the rendering host + surface (host re-validated
    /// against the window's live terminals before use).
    host_ptr: ?*AppHost = null,
    surface: u32 = 0,
    /// win_embedded rows: the pane whose tab shows the app.
    pane: ?*Pane = null,
    /// attach rows (owned).
    session: []u8 = &.{},
    /// attach rows: muxConnect host string, null = local daemon (owned).
    host: ?[]u8 = null,
};

const Switcher = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    window: *c.GtkWidget,
    listbox: *c.GtkWidget,
    status: *c.GtkWidget,
    entries: std.ArrayList(*Entry) = .empty,

    fn freeEntries(self: *Switcher) void {
        for (self.entries.items) |e| {
            if (e.session.len > 0) self.allocator.free(e.session);
            if (e.host) |h| self.allocator.free(h);
            self.allocator.destroy(e);
        }
        self.entries.deinit(self.allocator);
    }

    /// True while `host` is still one of the window's live app hosts
    /// (an app can exit between populate and activate).
    fn hostLive(self: *Switcher, host: *AppHost) bool {
        for (self.win.app_sessions.items) |as| {
            const r = as.terminal.remote orelse continue;
            for (r.napps.items) |na| {
                if (na.host == host) return true;
            }
        }
        for (self.win.panes.items) |p| {
            const r = p.terminal.remote orelse continue;
            for (r.napps.items) |na| {
                if (na.host == host) return true;
            }
        }
        return false;
    }
};

/// Open the switcher for `win`.
pub fn open(win: *Window) void {
    const allocator = win.allocator;
    const self = allocator.create(Switcher) catch return;
    const window = c.gtk_window_new();
    const list = c.gtk_list_box_new();
    const status = c.gtk_label_new(null);
    self.* = .{
        .allocator = allocator,
        .win = win,
        .window = window,
        .listbox = list,
        .status = status,
    };

    c.gtk_window_set_title(@ptrCast(window), "App Windows");
    c.gtk_window_set_default_size(@ptrCast(window), 520, 560);
    c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(win.app_window));

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), list);
    c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_SINGLE);
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(root), scroller);

    c.gtk_label_set_xalign(@ptrCast(status), 0.0);
    c.gtk_widget_set_margin_start(status, 10);
    c.gtk_widget_set_margin_end(status, 10);
    c.gtk_widget_set_margin_top(status, 2);
    c.gtk_widget_set_margin_bottom(status, 6);
    c.gtk_widget_add_css_class(status, "dim-label");
    c.gtk_box_append(@ptrCast(root), status);

    const esc = c.gtk_shortcut_controller_new();
    c.gtk_shortcut_controller_add_shortcut(
        @ptrCast(esc),
        c.gtk_shortcut_new(
            c.gtk_keyval_trigger_new(c.GDK_KEY_Escape, 0),
            c.gtk_callback_action_new(@ptrCast(&onEscape), @ptrCast(self), null),
        ),
    );
    c.gtk_widget_add_controller(window, esc);

    c.gtk_window_set_child(@ptrCast(window), root);
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    populate(self);
    c.gtk_window_present(@ptrCast(window));
}

fn onEscape(_: ?*c.GtkWidget, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Switcher, user);
    c.gtk_window_destroy(@ptrCast(self.window));
    return 1;
}

fn onDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Switcher, user);
    self.freeEntries();
    self.allocator.destroy(self);
}

// ── population ───────────────────────────────────────────────────

fn populate(self: *Switcher) void {
    var open_windows: usize = 0;
    var attachable: usize = 0;

    // Live windows: tabless app sessions first (the "desktop" ones),
    // then pane-hosted apps.
    for (self.win.app_sessions.items) |as| {
        open_windows += addTerminalRows(self, as.terminal, null);
    }
    for (self.win.panes.items) |p| {
        open_windows += addTerminalRows(self, p.terminal, p);
    }

    // Attachable app sessions on the local (shared) daemon — spawned
    // by another GUI instance, surviving a GUI crash, or launched by
    // an assistant running `sketerm mcp --shared`.
    if (mux_cli.fetchSessions(self.allocator, null)) |parsed| {
        defer parsed.deinit();
        for (parsed.value.sessions) |s| {
            if (!s.app or s.exited) continue;
            if (self.win.sessionShown(s.name, null)) continue;
            addAttachRow(self, s.name, null, "local daemon");
            attachable += 1;
        }
    }

    // Assistant (MCP) daemon instances: every sketerm/mcp-*/mux.sock
    // under the runtime dir. Attaching NEVER autostarts a daemon.
    attachable += addMcpRows(self);

    if (open_windows == 0 and attachable == 0) {
        c.gtk_label_set_text(@ptrCast(self.status), "No forwarded-app windows are open and no attachable app sessions were found.");
    } else {
        var buf: [160]u8 = undefined;
        const txt = std.fmt.bufPrintZ(&buf, "{d} open window(s), {d} attachable session(s). Enter raises / focuses / attaches.", .{ open_windows, attachable }) catch "";
        c.gtk_label_set_text(@ptrCast(self.status), txt.ptr);
    }
}

/// Rows for every open window of one terminal's app channels.
fn addTerminalRows(self: *Switcher, term: *Terminal, pane: ?*Pane) usize {
    const remote = term.remote orelse return 0;
    var n: usize = 0;
    for (remote.napps.items) |na| {
        const infos = na.host.windowInfos(self.allocator);
        defer self.allocator.free(infos);
        for (infos) |wi| {
            addWinRow(self, term, pane, na.host, wi);
            n += 1;
        }
    }
    return n;
}

fn addWinRow(self: *Switcher, term: *Terminal, pane: ?*Pane, host: *AppHost, wi: AppHost.WinInfo) void {
    const remote = term.remote orelse return;
    const e = self.allocator.create(Entry) catch return;
    e.* = .{
        .kind = if (wi.embedded) .win_embedded else .win_floating,
        .host_ptr = host,
        .surface = wi.surface,
        .pane = pane,
    };
    self.entries.append(self.allocator, e) catch {
        self.allocator.destroy(e);
        return;
    };

    const title = std.mem.span(wi.title);
    var sub_buf: [256]u8 = undefined;
    const driven: []const u8 = if (term.peer_drivers > 0) " — assistant attached" else "";
    const where: []const u8 = if (wi.embedded) "in tab" else "window";
    const sub = std.fmt.bufPrintZ(&sub_buf, "{s} · {s}{s}", .{ remote.session, where, driven }) catch "";
    appendRow(self, e, wi.paintable, if (title.len > 0) title else remote.session, sub, "window-symbolic");
}

fn addAttachRow(self: *Switcher, name: []const u8, host: ?[]const u8, origin: []const u8) void {
    const e = self.allocator.create(Entry) catch return;
    e.* = .{ .kind = .attach };
    e.session = self.allocator.dupe(u8, name) catch {
        self.allocator.destroy(e);
        return;
    };
    if (host) |h| e.host = self.allocator.dupe(u8, h) catch null;
    self.entries.append(self.allocator, e) catch {
        self.allocator.free(e.session);
        if (e.host) |h| self.allocator.free(h);
        self.allocator.destroy(e);
        return;
    };
    var sub_buf: [512]u8 = undefined;
    const sub = std.fmt.bufPrintZ(&sub_buf, "not shown — attach viewer · {s}", .{origin}) catch "";
    appendRow(self, e, null, name, sub, "network-workgroup-symbolic");
}

/// Scan the runtime dir for assistant daemon instances and add one
/// row per app session found. Read-only: list only, no autostart.
fn addMcpRows(self: *Switcher) usize {
    const rt = profile.getenv("XDG_RUNTIME_DIR") orelse return 0;
    var base_buf: [512]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "{s}/sketerm", .{rt}) catch return 0;
    const d = c.opendir(base.ptr) orelse return 0;
    defer _ = c.closedir(d);
    var n: usize = 0;
    while (c.readdir(d)) |ent| {
        const dname = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.startsWith(u8, dname, "mcp-")) continue;
        var sock_buf: [1024]u8 = undefined;
        const sock = std.fmt.bufPrint(&sock_buf, "{s}/{s}/mux.sock", .{ base, dname }) catch continue;
        const refs = appdrive.listAppSessions(self.allocator, sock) catch continue;
        defer {
            for (refs) |r| self.allocator.free(r.name);
            self.allocator.free(refs);
        }
        var host_buf: [1040]u8 = undefined;
        const host = std.fmt.bufPrint(&host_buf, "sock:{s}", .{sock}) catch continue;
        var origin_buf: [256]u8 = undefined;
        const origin = std.fmt.bufPrint(&origin_buf, "assistant daemon {s}", .{dname}) catch dname;
        for (refs) |r| {
            if (self.win.sessionShown(r.name, host)) continue;
            addAttachRow(self, r.name, host, origin);
            n += 1;
        }
    }
    return n;
}

/// Build one listbox row: thumbnail (or icon) + title + subtitle,
/// with the Entry pointer stashed as object data.
fn appendRow(self: *Switcher, e: *Entry, paintable: ?*c.GdkPaintable, title: []const u8, sub: [:0]const u8, icon: [*:0]const u8) void {
    const row_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    c.gtk_widget_set_margin_start(row_box, 8);
    c.gtk_widget_set_margin_end(row_box, 8);
    c.gtk_widget_set_margin_top(row_box, 6);
    c.gtk_widget_set_margin_bottom(row_box, 6);

    if (paintable) |p| {
        const pic = c.gtk_picture_new_for_paintable(p);
        c.gtk_widget_set_size_request(pic, 96, 60);
        c.gtk_picture_set_content_fit(@ptrCast(pic), c.GTK_CONTENT_FIT_COVER);
        c.gtk_widget_add_css_class(pic, "card");
        c.gtk_box_append(@ptrCast(row_box), pic);
    } else {
        const img = c.gtk_image_new_from_icon_name(icon);
        c.gtk_image_set_pixel_size(@ptrCast(img), 40);
        c.gtk_widget_set_size_request(img, 96, 60);
        c.gtk_box_append(@ptrCast(row_box), img);
    }

    const text_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_valign(text_box, c.GTK_ALIGN_CENTER);
    var tbuf: [256:0]u8 = undefined;
    const tz = std.fmt.bufPrintZ(&tbuf, "{s}", .{title}) catch "app";
    const tl = c.gtk_label_new(tz.ptr);
    c.gtk_label_set_xalign(@ptrCast(tl), 0.0);
    c.gtk_label_set_ellipsize(@ptrCast(tl), c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(text_box), tl);
    const sl = c.gtk_label_new(sub.ptr);
    c.gtk_label_set_xalign(@ptrCast(sl), 0.0);
    c.gtk_label_set_ellipsize(@ptrCast(sl), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(sl, "dim-label");
    c.gtk_box_append(@ptrCast(text_box), sl);
    c.gtk_box_append(@ptrCast(row_box), text_box);

    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), row_box);
    c.g_object_set_data(@ptrCast(row), "sketerm-app-entry", @ptrCast(e));
    c.gtk_list_box_append(@ptrCast(self.listbox), row);
}

// ── activation ───────────────────────────────────────────────────

fn onRowActivated(_: *c.GtkListBox, row: ?*c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Switcher, user);
    const data = c.g_object_get_data(@ptrCast(row orelse return), "sketerm-app-entry") orelse return;
    const e: *Entry = @ptrCast(@alignCast(data));
    switch (e.kind) {
        .win_floating => {
            if (e.host_ptr) |h| {
                if (self.hostLive(h)) h.presentSurface(e.surface);
            }
        },
        .win_embedded => {
            if (e.pane) |p| {
                // Re-validate: the pane may have closed since populate.
                for (self.win.panes.items) |lp| {
                    if (lp == p) {
                        self.win.focusPaneTab(p);
                        break;
                    }
                }
            }
        },
        .attach => {
            if (!self.win.attachSessionByHost(e.session, if (e.host) |h| h else null)) {
                c.gtk_label_set_text(@ptrCast(self.status), "Attach failed — the session or its daemon may be gone.");
                return; // keep the dialog open to show the message
            }
        },
    }
    c.gtk_window_destroy(@ptrCast(self.window));
}
