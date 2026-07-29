//! Session overview — the window's task switcher. One dialog lists
//! everything a user might be looking for: open forwarded-app windows
//! (with live thumbnails), every attached session (panes and tabless
//! apps, including windowless ones — the "what is playing that
//! sound?" case), and attachable sessions on the local daemon, on
//! every REMOTE daemon this window has sessions on, and on assistant
//! (MCP) daemon instances. Rows carry an audio badge (local sink
//! truth for attached sessions, the daemon's `audio` list field for
//! fetched ones) and unattached sessions get a kill button.
//!
//! Remote/local daemon lists are fetched on worker threads — a slow
//! ssh host must never freeze the GUI — and their rows arrive
//! asynchronously. Lifetime: heap-allocated `Switcher`; the dialog's
//! "destroy" frees the entries, and the LAST in-flight worker op
//! (fetch or kill) frees the struct itself via `pending_ops`/`dead`.

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
const muxtabs = @import("muxtabs.zig");

const Entry = struct {
    kind: enum { win_floating, win_embedded, pane, app_hidden, attach },
    /// win_* rows: the rendering host + surface (host re-validated
    /// against the window's live terminals before use).
    host_ptr: ?*AppHost = null,
    surface: u32 = 0,
    /// win_embedded/pane rows: the pane to focus.
    pane: ?*Pane = null,
    /// app_hidden rows: the tabless session to adopt into a tab
    /// (re-validated against win.app_sessions before use).
    as: ?*muxtabs.AppSession = null,
    /// attach rows (owned).
    session: []u8 = &.{},
    /// attach rows: muxConnect host string, null = local daemon (owned).
    host: ?[]u8 = null,
    /// The listbox row, so a kill can remove it.
    row: ?*c.GtkWidget = null,
};

const Switcher = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    window: *c.GtkWidget,
    listbox: *c.GtkWidget,
    status: *c.GtkWidget,
    entries: std.ArrayList(*Entry) = .empty,
    /// Status-line counters, updated as async rows arrive.
    open_windows: usize = 0,
    shown: usize = 0,
    attachable: usize = 0,
    /// Worker ops (daemon-list fetches, kills) still in flight. The
    /// struct outlives the dialog until they all land.
    pending_ops: usize = 0,
    /// Dialog destroyed; entries are gone, pending ops must not touch
    /// widgets, and the last one frees the struct.
    dead: bool = false,

    fn freeEntries(self: *Switcher) void {
        for (self.entries.items) |e| {
            if (e.session.len > 0) self.allocator.free(e.session);
            if (e.host) |h| self.allocator.free(h);
            self.allocator.destroy(e);
        }
        self.entries.deinit(self.allocator);
        self.entries = .empty;
    }

    /// One async op finished. Frees the switcher when it was the last
    /// thing keeping a destroyed dialog's state alive.
    fn opDone(self: *Switcher) void {
        self.pending_ops -= 1;
        if (self.dead and self.pending_ops == 0) self.allocator.destroy(self);
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

    fn updateStatus(self: *Switcher) void {
        if (self.dead) return;
        var buf: [224]u8 = undefined;
        const fetching: []const u8 = if (self.pending_ops > 0) " · querying daemons…" else "";
        if (self.open_windows == 0 and self.shown == 0 and self.attachable == 0) {
            const txt = std.fmt.bufPrintZ(&buf, "No sessions found.{s}", .{fetching}) catch "";
            c.gtk_label_set_text(@ptrCast(self.status), txt.ptr);
            return;
        }
        const txt = std.fmt.bufPrintZ(&buf, "{d} window(s), {d} shown session(s), {d} attachable{s}. Enter raises / focuses / attaches.", .{
            self.open_windows, self.shown, self.attachable, fetching,
        }) catch "";
        c.gtk_label_set_text(@ptrCast(self.status), txt.ptr);
    }
};

/// Open the overview for `win`.
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

    c.gtk_window_set_title(@ptrCast(window), "Session Overview");
    c.gtk_window_set_default_size(@ptrCast(window), 560, 600);
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
    if (self.pending_ops == 0) {
        self.allocator.destroy(self);
        return;
    }
    // In-flight worker ops still hold the struct; the last one frees it.
    self.dead = true;
}

// ── population ───────────────────────────────────────────────────

fn populate(self: *Switcher) void {
    // Live windows: tabless app sessions first (the "desktop" ones),
    // then pane-hosted apps. A tabless session with NO open window is
    // the invisible one (window closed, app still running — often the
    // mystery sound); it gets its own row.
    for (self.win.app_sessions.items) |as| {
        const wins = addTerminalRows(self, as.terminal, null);
        self.open_windows += wins;
        if (wins == 0) {
            addHiddenAppRow(self, as);
            self.shown += 1;
        }
    }
    for (self.win.panes.items) |p| {
        self.open_windows += addTerminalRows(self, p.terminal, p);
        if (p.terminal.remote != null) {
            addPaneRow(self, p);
            self.shown += 1;
        }
    }

    // Attachable sessions on every daemon this window can name: the
    // local one plus each distinct remote host. Fetched on worker
    // threads — a wedged ssh host costs a stale "querying…" note,
    // never a frozen GUI.
    startFetch(self, null);
    var seen: [16][]const u8 = undefined;
    var n_seen: usize = 0;
    for (self.win.panes.items) |p| {
        collectHost(self, p.terminal, &seen, &n_seen);
    }
    for (self.win.app_sessions.items) |as| {
        collectHost(self, as.terminal, &seen, &n_seen);
    }

    // Assistant (MCP) daemon instances: every sketerm/mcp-*/mux.sock
    // under the runtime dir. Attaching NEVER autostarts a daemon.
    self.attachable += addMcpRows(self);

    self.updateStatus();
}

fn collectHost(self: *Switcher, term: *Terminal, seen: *[16][]const u8, n_seen: *usize) void {
    const r = term.remote orelse return;
    const h = r.host orelse return;
    for (seen[0..n_seen.*]) |s| {
        if (std.mem.eql(u8, s, h)) return;
    }
    if (n_seen.* >= seen.len) return;
    seen[n_seen.*] = h;
    n_seen.* += 1;
    startFetch(self, h);
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

fn hostLabelOf(term: *Terminal) []const u8 {
    const remote = term.remote orelse return "local";
    return if (remote.host) |h| h else "local";
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
    var sub_buf: [320]u8 = undefined;
    const driven: []const u8 = if (term.peer_drivers > 0) " — assistant attached" else "";
    const where: []const u8 = if (wi.embedded) "in tab" else "window";
    const audio: []const u8 = if (term.audioPlaying()) " · playing audio" else "";
    const sub = std.fmt.bufPrintZ(&sub_buf, "{s} · {s}{s}{s}", .{ remote.session, where, driven, audio }) catch "";
    appendRow(self, e, wi.paintable, if (title.len > 0) title else remote.session, sub, "window-symbolic", false);
}

/// One attached pane session (shell or embedded app): activate
/// focuses its tab. This is the per-pane half of the task overview.
fn addPaneRow(self: *Switcher, pane: *Pane) void {
    const term = pane.terminal;
    const remote = term.remote orelse return;
    const e = self.allocator.create(Entry) catch return;
    e.* = .{ .kind = .pane, .pane = pane };
    self.entries.append(self.allocator, e) catch {
        self.allocator.destroy(e);
        return;
    };
    const title: []const u8 = if (term.screen.last_title) |t| t else remote.session;
    var sub_buf: [320]u8 = undefined;
    const kind: []const u8 = if (remote.is_app) "app" else "shell";
    const audio: []const u8 = if (term.audioPlaying()) " · playing audio" else "";
    const sub = std.fmt.bufPrintZ(&sub_buf, "{s} · {s} · in pane{s}", .{ kind, hostLabelOf(term), audio }) catch "";
    appendRow(self, e, null, title, sub, "utilities-terminal-symbolic", false);
}

/// A tabless app session with no open window — running, invisible,
/// and the usual "what is playing that sound?" suspect. Activate
/// adopts it into a real tab (log + banner) so it can be seen and
/// closed; the kill button ends it directly.
fn addHiddenAppRow(self: *Switcher, as: *muxtabs.AppSession) void {
    const term = as.terminal;
    const remote = term.remote orelse return;
    const e = self.allocator.create(Entry) catch return;
    e.* = .{ .kind = .app_hidden, .as = as };
    self.entries.append(self.allocator, e) catch {
        self.allocator.destroy(e);
        return;
    };
    var sub_buf: [320]u8 = undefined;
    const audio: []const u8 = if (term.audioPlaying()) " · playing audio" else "";
    const sub = std.fmt.bufPrintZ(&sub_buf, "app, no window open · {s} · Enter shows it in a tab{s}", .{ hostLabelOf(term), audio }) catch "";
    appendRow(self, e, null, remote.session, sub, "view-conceal-symbolic", false);
}

fn addAttachRow(self: *Switcher, name: []const u8, host: ?[]const u8, origin: []const u8, audio: bool, can_kill: bool) void {
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
    const badge: []const u8 = if (audio) " · playing audio" else "";
    const sub = std.fmt.bufPrintZ(&sub_buf, "not shown — attach viewer · {s}{s}", .{ origin, badge }) catch "";
    appendRow(self, e, null, name, sub, "network-workgroup-symbolic", can_kill);
}

// ── async daemon-list fetches ────────────────────────────────────

/// One daemon-list fetch, alive across its worker thread. c_allocator
/// throughout: the GUI allocator is not thread-safe.
const Fetch = struct {
    sw: *Switcher,
    /// muxConnect host string, null = local daemon (owned).
    host: ?[]u8,
    rows: std.ArrayList(Row) = .empty,

    const Row = struct {
        name: []u8,
        app: bool,
        audio: bool,
    };

    fn destroy(self: *Fetch) void {
        const a = std.heap.c_allocator;
        for (self.rows.items) |r| a.free(r.name);
        self.rows.deinit(a);
        if (self.host) |h| a.free(h);
        a.destroy(self);
    }
};

fn startFetch(self: *Switcher, host: ?[]const u8) void {
    const a = std.heap.c_allocator;
    const ctx = a.create(Fetch) catch return;
    ctx.* = .{ .sw = self, .host = null };
    if (host) |h| {
        ctx.host = a.dupe(u8, h) catch {
            a.destroy(ctx);
            return;
        };
    }
    const th = std.Thread.spawn(.{}, fetchThreadMain, .{ctx}) catch {
        ctx.destroy();
        return;
    };
    th.detach();
    self.pending_ops += 1;
}

fn fetchThreadMain(ctx: *Fetch) void {
    const a = std.heap.c_allocator;
    if (mux_cli.fetchSessions(a, if (ctx.host) |h| @as(?[]const u8, h) else null)) |parsed| {
        defer parsed.deinit();
        for (parsed.value.sessions) |s| {
            if (s.exited) continue;
            const name = a.dupe(u8, s.name) catch continue;
            ctx.rows.append(a, .{ .name = name, .app = s.app, .audio = s.audio }) catch {
                a.free(name);
                continue;
            };
        }
    }
    _ = c.g_idle_add(@ptrCast(&onFetchIdle), @ptrCast(ctx));
}

fn onFetchIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx: *Fetch = @ptrCast(@alignCast(user.?));
    const self = ctx.sw;
    if (!self.dead) {
        const host: ?[]const u8 = if (ctx.host) |h| h else null;
        const origin: []const u8 = if (host) |h| h else "local daemon";
        for (ctx.rows.items) |r| {
            // Shown-ness is judged NOW, on the main thread — the
            // window may have attached or closed things while the
            // fetch was on the wire.
            if (self.win.sessionShown(r.name, host)) continue;
            addAttachRow(self, r.name, host, origin, r.audio, true);
            self.attachable += 1;
        }
    }
    ctx.destroy();
    self.opDone();
    if (!self.dead) self.updateStatus();
    return 0;
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
            addAttachRow(self, r.name, host, origin, false, false);
            n += 1;
        }
    }
    return n;
}

/// Build one listbox row: thumbnail (or icon) + title + subtitle,
/// with the Entry pointer stashed as object data. `can_kill` adds a
/// stop button that ends the session on its daemon.
fn appendRow(self: *Switcher, e: *Entry, paintable: ?*c.GdkPaintable, title: []const u8, sub: [:0]const u8, icon: [*:0]const u8, can_kill: bool) void {
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
    c.gtk_widget_set_hexpand(text_box, 1);
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

    if (std.mem.indexOf(u8, sub, "playing audio") != null) {
        const spk = c.gtk_image_new_from_icon_name("audio-volume-high-symbolic");
        c.gtk_widget_set_valign(spk, c.GTK_ALIGN_CENTER);
        c.gtk_box_append(@ptrCast(row_box), spk);
    }

    if (can_kill) {
        const btn = c.gtk_button_new_from_icon_name("process-stop-symbolic");
        c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
        c.gtk_widget_add_css_class(btn, "flat");
        c.gtk_widget_set_tooltip_text(btn, "Kill this session on its daemon");
        c.g_object_set_data(@ptrCast(btn), "sketerm-app-entry", @ptrCast(e));
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onKillClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row_box), btn);
    }

    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), row_box);
    c.g_object_set_data(@ptrCast(row), "sketerm-app-entry", @ptrCast(e));
    e.row = row;
    c.gtk_list_box_append(@ptrCast(self.listbox), row);
}

// ── kill ─────────────────────────────────────────────────────────

/// One in-flight kill (c_allocator, worker thread). Owns copies of
/// everything it needs; the Entry may die with the dialog meanwhile.
const Kill = struct {
    sw: *Switcher,
    entry: *Entry,
    host: ?[]u8,
    name: []u8,
    ok: bool = false,

    fn destroy(self: *Kill) void {
        const a = std.heap.c_allocator;
        if (self.host) |h| a.free(h);
        a.free(self.name);
        a.destroy(self);
    }
};

fn onKillClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Switcher, user);
    const data = c.g_object_get_data(@ptrCast(btn), "sketerm-app-entry") orelse return;
    const e: *Entry = @ptrCast(@alignCast(data));
    if (e.session.len == 0) return;
    const a = std.heap.c_allocator;
    const ctx = a.create(Kill) catch return;
    ctx.* = .{
        .sw = self,
        .entry = e,
        .host = null,
        .name = a.dupe(u8, e.session) catch {
            a.destroy(ctx);
            return;
        },
    };
    if (e.host) |h| {
        ctx.host = a.dupe(u8, h) catch {
            a.free(ctx.name);
            a.destroy(ctx);
            return;
        };
    }
    const th = std.Thread.spawn(.{}, killThreadMain, .{ctx}) catch {
        ctx.destroy();
        return;
    };
    th.detach();
    self.pending_ops += 1;
    c.gtk_widget_set_sensitive(@ptrCast(btn), 0);
    c.gtk_label_set_text(@ptrCast(self.status), "Killing session…");
}

fn killThreadMain(ctx: *Kill) void {
    ctx.ok = mux_cli.killSession(std.heap.c_allocator, if (ctx.host) |h| @as(?[]const u8, h) else null, ctx.name);
    _ = c.g_idle_add(@ptrCast(&onKillIdle), @ptrCast(ctx));
}

fn onKillIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx: *Kill = @ptrCast(@alignCast(user.?));
    const self = ctx.sw;
    const alive = !self.dead;
    const ok = ctx.ok;
    if (alive and ok) {
        // The entry is only valid while the dialog lives — same
        // condition as !dead, so removing its row here is safe.
        if (ctx.entry.row) |row| {
            c.gtk_list_box_remove(@ptrCast(self.listbox), row);
            ctx.entry.row = null;
        }
        if (self.attachable > 0) self.attachable -= 1;
    }
    ctx.destroy();
    // Decrement BEFORE rendering, or the status keeps claiming
    // "querying daemons" after the last op landed. opDone only frees
    // the struct when the dialog is already dead, so `alive` still
    // guards the widget access.
    self.opDone();
    if (alive) {
        if (ok) {
            self.updateStatus();
        } else {
            c.gtk_label_set_text(@ptrCast(self.status), "Kill failed — the session or its daemon may be gone.");
        }
    }
    return 0;
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
        .win_embedded, .pane => {
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
        .app_hidden => {
            if (e.as) |as| {
                // Re-validate: the session may have exited meanwhile.
                for (self.win.app_sessions.items) |live| {
                    if (live == as) {
                        if (muxtabs.adoptAppSessionIntoTab(self.win, as)) |pane| {
                            self.win.focusPaneTab(pane);
                        }
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
