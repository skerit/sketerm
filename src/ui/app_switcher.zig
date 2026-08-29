//! Searchable task overview for forwarded applications, audio and mux sessions.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const pulse = @import("../mux/pulse.zig");
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;
const Terminal = @import("../terminal.zig").Terminal;
const AppHost = @import("../wlapp.zig").AppHost;
const WsHost = @import("../winapp.zig").WsHost;
const mux_client = @import("../mux/client.zig");
const mux_wire = @import("../mux/wire.zig");
const mux_cli = @import("../ipc/mux_cli.zig");
const muxtabs = @import("muxtabs.zig");
const assistants = @import("assistants.zig");

const Section = enum(u8) { audio, applications, attached, available };

const Group = struct {
    widget: ?*c.GtkWidget = null,
    list: ?*c.GtkWidget = null,
    matches: usize = 0,
};

const SessionTarget = struct {
    session: []u8,
    host: ?[]u8,
    origin_id: ?[]u8 = null,

    fn deinit(self: *SessionTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.session);
        if (self.host) |host| allocator.free(host);
        if (self.origin_id) |origin_id| allocator.free(origin_id);
    }
};

const Entry = struct {
    kind: enum { native_window, streamed_window, pane, hidden_app, audio, attach },
    section: Section,
    row: *c.GtkWidget,
    search: []u8,
    identity: []u8 = &.{},
    native_host: ?*AppHost = null,
    streamed_host: ?*WsHost = null,
    surface: u32 = 0,
    pane: ?*Pane = null,
    app_session: ?*muxtabs.AppSession = null,
    target: ?SessionTarget = null,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.search);
        if (self.identity.len > 0) allocator.free(self.identity);
        if (self.target) |*target| target.deinit(allocator);
        allocator.destroy(self);
    }
};

const DaemonState = struct {
    host: ?[]u8,
    origin: []u8,
    listing: ?std.json.Parsed(mux_cli.Welcome) = null,
    /// Idle persistent connection, reused by every poll/stop/attach for
    /// this daemon — dialing fresh per poll spawned ssh every 5s.
    conn: ?mux_client.Conn = null,
    /// A worker thread currently owns the connection; ops are strictly
    /// serialized per daemon.
    busy: bool = false,
    /// At most one stop request queued while busy (switcher allocator).
    pending_kill: ?[]u8 = null,
    pending_kill_origin: ?[]u8 = null,
    fingerprint: u64 = 0,
    generation: u64 = 0,
    failed: bool = false,

    fn deinit(self: *DaemonState, allocator: std.mem.Allocator) void {
        if (self.host) |host| allocator.free(host);
        allocator.free(self.origin);
        if (self.listing) |*listing| listing.deinit();
        if (self.conn) |*conn| conn.deinit();
        if (self.pending_kill) |session| allocator.free(session);
        if (self.pending_kill_origin) |origin_id| allocator.free(origin_id);
    }
};

const Switcher = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    window: *c.GtkWidget,
    search: *c.GtkWidget,
    groups_box: *c.GtkWidget,
    status: *c.GtkWidget,
    empty: ?*c.GtkWidget = null,
    refresh_button: *c.GtkWidget,
    groups: [4]Group = .{ .{}, .{}, .{}, .{} },
    entries: std.ArrayList(*Entry) = .empty,
    daemons: std.ArrayList(DaemonState) = .empty,
    /// Sessions with a stop in flight; every matching stop button
    /// renders insensitive until the kill resolves.
    kills: std.ArrayList(SessionTarget) = .empty,
    /// Static failure note appended to the status line until the next
    /// user-initiated operation.
    note: []const u8 = "",
    pending_ops: usize = 0,
    attaching: bool = false,
    dead: bool = false,
    refresh_source: c_uint = 0,
    render_source: c_uint = 0,
    refresh_ticks: u8 = 0,
    attached_hash: u64 = 0,
    open_windows: usize = 0,
    playing_apps: usize = 0,
    attached_sessions: usize = 0,
    available_sessions: usize = 0,

    fn group(self: *Switcher, section: Section) *Group {
        return &self.groups[@intFromEnum(section)];
    }

    fn opDone(self: *Switcher) bool {
        self.pending_ops -= 1;
        if (self.dead and self.pending_ops == 0) {
            self.allocator.destroy(self);
            return false;
        }
        return true;
    }

    fn clearRendered(self: *Switcher) void {
        while (c.gtk_widget_get_first_child(self.groups_box)) |child| {
            c.gtk_box_remove(@ptrCast(self.groups_box), child);
        }
        self.empty = null;
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
        self.groups = .{ .{}, .{}, .{}, .{} };
        self.open_windows = 0;
        self.playing_apps = 0;
        self.attached_sessions = 0;
        self.available_sessions = 0;
    }

    fn freeAll(self: *Switcher) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        for (self.daemons.items) |*daemon| daemon.deinit(self.allocator);
        self.daemons.deinit(self.allocator);
        for (self.kills.items) |*mark| mark.deinit(self.allocator);
        self.kills.deinit(self.allocator);
    }

    fn isKilling(self: *Switcher, host: ?[]const u8, session: []const u8) bool {
        for (self.kills.items) |mark| {
            if (optionalEql(mark.host, host) and std.mem.eql(u8, mark.session, session)) return true;
        }
        return false;
    }

    fn markKilling(self: *Switcher, host: ?[]const u8, session: []const u8) void {
        if (self.isKilling(host, session)) return;
        const host_copy = if (host) |value| self.allocator.dupe(u8, value) catch return else null;
        const session_copy = self.allocator.dupe(u8, session) catch {
            if (host_copy) |value| self.allocator.free(value);
            return;
        };
        self.kills.append(self.allocator, .{ .host = host_copy, .session = session_copy }) catch {
            if (host_copy) |value| self.allocator.free(value);
            self.allocator.free(session_copy);
        };
    }

    fn unmarkKilling(self: *Switcher, host: ?[]const u8, session: []const u8) void {
        for (self.kills.items, 0..) |mark, index| {
            if (!optionalEql(mark.host, host) or !std.mem.eql(u8, mark.session, session)) continue;
            var removed = self.kills.swapRemove(index);
            removed.deinit(self.allocator);
            return;
        }
    }

    fn nativeHostLive(self: *Switcher, host: *AppHost) bool {
        for (self.win.app_sessions.items) |as| {
            const remote = as.terminal.remote orelse continue;
            for (remote.napps.items) |app| if (app.host == host) return true;
        }
        for (self.win.panes.items) |pane| {
            const remote = pane.terminal.remote orelse continue;
            for (remote.napps.items) |app| if (app.host == host) return true;
        }
        return false;
    }

    fn streamedHostLive(self: *Switcher, host: *WsHost) bool {
        for (self.win.app_sessions.items) |as| {
            const remote = as.terminal.remote orelse continue;
            for (remote.wsapps.items) |app| if (app.host == host) return true;
        }
        for (self.win.panes.items) |pane| {
            const remote = pane.terminal.remote orelse continue;
            for (remote.wsapps.items) |app| if (app.host == host) return true;
        }
        return false;
    }

    /// The status line is derived from live state only, so a completing
    /// fetch can never clobber a "stopping" or "attaching" message.
    fn updateStatus(self: *Switcher) void {
        if (self.dead) return;
        if (self.attaching) {
            c.gtk_label_set_text(@ptrCast(self.status), "Connecting and attaching session...");
            c.gtk_widget_set_sensitive(self.refresh_button, 0);
            return;
        }
        var failures: usize = 0;
        for (self.daemons.items) |daemon| if (daemon.failed) {
            failures += 1;
        };
        var buf: [320:0]u8 = undefined;
        const suffix = if (self.pending_ops > 0) " - refreshing daemons..." else "";
        const stopping = if (self.kills.items.len > 0) " - stopping session..." else "";
        const failed = if (failures > 0)
            std.fmt.bufPrint(&buf, " - {d} daemon(s) unavailable", .{failures}) catch ""
        else
            "";
        var note_buf: [200:0]u8 = undefined;
        const note = if (self.note.len > 0)
            std.fmt.bufPrint(&note_buf, " - {s}", .{self.note}) catch ""
        else
            "";
        var out: [768:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&out, "{d} playing, {d} application window(s), {d} attached, {d} available{s}{s}{s}{s}", .{
            self.playing_apps,
            self.open_windows,
            self.attached_sessions,
            self.available_sessions,
            suffix,
            stopping,
            failed,
            note,
        }) catch "Session overview";
        c.gtk_label_set_text(@ptrCast(self.status), text.ptr);
        c.gtk_widget_set_sensitive(self.refresh_button, @intFromBool(self.pending_ops == 0));
    }
};

pub fn open(win: *Window) void {
    const allocator = win.allocator;
    const self = allocator.create(Switcher) catch return;
    const window = c.adw_window_new() orelse {
        allocator.destroy(self);
        return;
    };
    const search = c.gtk_search_entry_new() orelse {
        c.gtk_window_destroy(@ptrCast(window));
        allocator.destroy(self);
        return;
    };
    const groups_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 18).?;
    const status = c.gtk_label_new("").?;
    const refresh_button = c.gtk_button_new_from_icon_name("view-refresh-symbolic").?;
    self.* = .{
        .allocator = allocator,
        .win = win,
        .window = window,
        .search = search,
        .groups_box = groups_box,
        .status = status,
        .refresh_button = refresh_button,
    };

    c.gtk_window_set_title(@ptrCast(window), "Session Overview");
    c.gtk_window_set_default_size(@ptrCast(window), 820, 720);
    c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(win.app_window));
    c.gtk_window_set_destroy_with_parent(@ptrCast(window), 1);

    const toolbar = c.adw_toolbar_view_new().?;
    const header = c.adw_header_bar_new().?;
    c.gtk_widget_set_tooltip_text(refresh_button, "Refresh daemon sessions");
    c.adw_header_bar_pack_end(@ptrCast(header), refresh_button);
    c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), header);

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
    c.gtk_search_entry_set_placeholder_text(@ptrCast(search), "Search applications, media, hosts and sessions");
    c.gtk_widget_set_margin_start(search, 18);
    c.gtk_widget_set_margin_end(search, 18);
    c.gtk_widget_set_margin_top(search, 14);
    c.gtk_widget_set_margin_bottom(search, 10);
    c.gtk_box_append(@ptrCast(root), search);

    const scroll = c.gtk_scrolled_window_new().?;
    c.gtk_widget_set_vexpand(scroll, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_margin_start(groups_box, 18);
    c.gtk_widget_set_margin_end(groups_box, 18);
    c.gtk_widget_set_margin_top(groups_box, 6);
    c.gtk_widget_set_margin_bottom(groups_box, 18);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), groups_box);
    c.gtk_box_append(@ptrCast(root), scroll);

    c.gtk_label_set_xalign(@ptrCast(status), 0);
    c.gtk_label_set_ellipsize(@ptrCast(status), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(status, "dim-label");
    c.gtk_widget_set_margin_start(status, 18);
    c.gtk_widget_set_margin_end(status, 18);
    c.gtk_widget_set_margin_top(status, 7);
    c.gtk_widget_set_margin_bottom(status, 10);
    c.gtk_box_append(@ptrCast(root), status);
    c.adw_toolbar_view_set_content(@ptrCast(toolbar), root);
    c.adw_window_set_content(@ptrCast(window), toolbar);

    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(search, "search-changed", @ptrCast(&onSearchChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(refresh_button, "clicked", @ptrCast(&onRefreshClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    const keys = c.gtk_event_controller_key_new().?;
    c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKeyPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(window, @ptrCast(keys));

    discoverDaemons(self);
    render(self);
    startAllFetches(self);
    self.refresh_source = c.g_timeout_add(1000, @ptrCast(&onRefreshTick), @ptrCast(self));
    c.gtk_window_present(@ptrCast(window));
    _ = c.gtk_widget_grab_focus(search);
}

fn onDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Switcher, user);
    if (self.refresh_source != 0) {
        _ = c.g_source_remove(self.refresh_source);
        self.refresh_source = 0;
    }
    if (self.render_source != 0) {
        _ = c.g_source_remove(self.render_source);
        self.render_source = 0;
    }
    self.freeAll();
    self.dead = true;
    if (self.pending_ops == 0) self.allocator.destroy(self);
}

fn sectionInfo(section: Section) struct { title: [*:0]const u8, description: [*:0]const u8 } {
    return switch (section) {
        .audio => .{ .title = "Playing Audio", .description = "Applications using a mux session's internal PulseAudio server" },
        .applications => .{ .title = "Application Windows", .description = "Forwarded graphical applications currently known to this window" },
        .attached => .{ .title = "Attached Sessions", .description = "Shell and application sessions already shown in this window" },
        .available => .{ .title = "Available Sessions", .description = "Running sessions that can be attached or stopped" },
    };
}

fn createGroups(self: *Switcher) void {
    inline for (std.enums.values(Section)) |section| {
        const info = sectionInfo(section);
        const widget = c.adw_preferences_group_new().?;
        c.adw_preferences_group_set_title(@ptrCast(widget), info.title);
        c.adw_preferences_group_set_description(@ptrCast(widget), info.description);
        const list = c.gtk_list_box_new().?;
        c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_SINGLE);
        c.gtk_widget_add_css_class(list, "boxed-list");
        _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.adw_preferences_group_add(@ptrCast(widget), list);
        c.gtk_box_append(@ptrCast(self.groups_box), widget);
        self.group(section).* = .{ .widget = widget, .list = list };
    }
    const empty = c.gtk_label_new("No matching applications or sessions").?;
    c.gtk_widget_add_css_class(empty, "dim-label");
    c.gtk_widget_set_margin_top(empty, 36);
    c.gtk_widget_set_visible(empty, 0);
    c.gtk_box_append(@ptrCast(self.groups_box), empty);
    self.empty = empty;
}

fn render(self: *Switcher) void {
    if (self.dead) return;
    const selected = if (selectedEntry(self)) |entry|
        if (entry.identity.len > 0) self.allocator.dupe(u8, entry.identity) catch null else null
    else
        null;
    defer if (selected) |value| self.allocator.free(value);
    self.clearRendered();
    createGroups(self);
    populateAttached(self);
    populateFetched(self);
    self.attached_hash = attachedFingerprint(self);
    applySearch(self, selected);
    self.updateStatus();
}

fn scheduleRender(self: *Switcher) void {
    if (self.dead or self.render_source != 0) return;
    self.render_source = c.g_timeout_add(80, @ptrCast(&onRenderScheduled), @ptrCast(self));
}

fn onRenderScheduled(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Switcher, user);
    self.render_source = 0;
    if (!self.dead) render(self);
    return 0;
}

fn populateAttached(self: *Switcher) void {
    for (self.win.app_sessions.items) |app_session| {
        addAudioRows(self, app_session.terminal, null, app_session);
        const windows = addApplicationRows(self, app_session.terminal, null);
        self.open_windows += windows;
        if (windows == 0) addHiddenAppRow(self, app_session);
    }
    for (self.win.panes.items) |pane| {
        const term = pane.terminal;
        if (term.remote == null) continue;
        addAudioRows(self, term, pane, null);
        self.open_windows += addApplicationRows(self, term, pane);
        addPaneRow(self, pane);
        self.attached_sessions += 1;
    }
}

fn hostLabel(term: *Terminal) []const u8 {
    const remote = term.remote orelse return "local";
    return if (remote.host) |host| host else "local";
}

fn addAudioRows(self: *Switcher, term: *Terminal, pane: ?*Pane, app_session: ?*muxtabs.AppSession) void {
    if (term.remote == null) return;
    const infos = term.audioInfos(self.allocator);
    defer self.allocator.free(infos);
    var added: usize = 0;
    for (infos, 0..) |info, index| {
        if (!info.running) continue;
        var duplicate = false;
        for (infos[0..index]) |previous| {
            if (previous.running and sameAudioApplication(previous, info)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        var streams: usize = 0;
        for (infos) |candidate| if (candidate.running and sameAudioApplication(candidate, info)) {
            streams += 1;
        };
        addAudioRow(self, term, pane, app_session, info, streams);
        added += 1;
    }
    if (added == 0 and term.audioPlaying()) {
        addAudioRow(self, term, pane, app_session, .{ .running = true }, 1);
        added = 1;
    }
    self.playing_apps += added;
}

fn sameAudioApplication(a: pulse.AudioInfo, b: pulse.AudioInfo) bool {
    if (a.pid != 0 and b.pid != 0) return a.pid == b.pid;
    return std.mem.eql(u8, a.application, b.application) and std.mem.eql(u8, a.binary, b.binary);
}

fn displayApplication(info: pulse.AudioInfo) []const u8 {
    if (info.application.len > 0) return info.application;
    if (info.binary.len > 0) return std.fs.path.basename(info.binary);
    return "Unknown audio application";
}

fn addAudioRow(self: *Switcher, term: *Terminal, pane: ?*Pane, app_session: ?*muxtabs.AppSession, info: pulse.AudioInfo, streams: usize) void {
    const remote = term.remote orelse return;
    var subtitle_buf: [640:0]u8 = undefined;
    const pid_text = if (info.pid != 0)
        std.fmt.bufPrint(&subtitle_buf, " - PID {d}", .{info.pid}) catch ""
    else
        "";
    var subtitle_out: [896:0]u8 = undefined;
    const media = if (info.media.len > 0) info.media else "Active playback stream";
    const subtitle = std.fmt.bufPrintZ(&subtitle_out, "{s}{s} - {s} - session {s}{s}", .{
        media,
        if (streams > 1) " (multiple streams)" else "",
        hostLabel(term),
        remote.session,
        pid_text,
    }) catch "Playing through Sketerm";
    const entry = appendRow(self, .audio, displayApplication(info), subtitle, null, if (info.icon.len > 0) info.icon else "audio-x-generic-symbolic", true) orelse return;
    entry.kind = .audio;
    entry.pane = pane;
    entry.app_session = app_session;
    if (app_session != null and remote.napps.items.len > 0) entry.native_host = remote.napps.items[0].host;
    setSessionTarget(self, entry, remote.session, remote.host, remote.origin_id, true);
    setIdentity(self, entry, "audio-attached:{d}\x00{d}\x00{s}\x00{s}", .{ @intFromPtr(term), info.pid, info.application, info.binary });
}

fn addApplicationRows(self: *Switcher, term: *Terminal, pane: ?*Pane) usize {
    const remote = term.remote orelse return 0;
    var count: usize = 0;
    for (remote.napps.items) |native| {
        const infos = native.host.windowInfos(self.allocator);
        defer {
            for (infos) |info| if (info.paintable) |paintable| c.g_object_unref(paintable);
            self.allocator.free(infos);
        }
        for (infos) |info| {
            const title = std.mem.span(info.title);
            var subtitle_buf: [640:0]u8 = undefined;
            const app_id = if (info.app_id.len > 0) info.app_id else "application";
            const place = if (info.embedded) "in a pane" else "forwarded window";
            const subtitle = std.fmt.bufPrintZ(&subtitle_buf, "{s} - {s} - {s} - session {s}", .{ app_id, place, hostLabel(term), remote.session }) catch "Forwarded application";
            const entry = appendRow(self, .applications, if (title.len > 0) title else app_id, subtitle, info.paintable, "application-x-executable-symbolic", false) orelse continue;
            entry.kind = .native_window;
            entry.native_host = native.host;
            entry.surface = info.id;
            entry.pane = if (info.embedded) pane else null;
            setIdentity(self, entry, "native:{d}\x00{d}\x00{d}", .{ @intFromPtr(term), native.id, info.id });
            count += 1;
        }
    }
    for (remote.wsapps.items) |streamed| {
        const infos = streamed.host.windowInfos(self.allocator);
        defer {
            for (infos) |info| if (info.paintable) |paintable| c.g_object_unref(paintable);
            self.allocator.free(infos);
        }
        for (infos) |info| {
            const title = std.mem.span(info.title);
            var subtitle_buf: [512:0]u8 = undefined;
            const subtitle = std.fmt.bufPrintZ(&subtitle_buf, "streamed window - {s} - session {s}", .{ hostLabel(term), remote.session }) catch "Streamed application";
            const entry = appendRow(self, .applications, if (title.len > 0) title else remote.session, subtitle, info.paintable, "application-x-executable-symbolic", false) orelse continue;
            entry.kind = .streamed_window;
            entry.streamed_host = streamed.host;
            entry.surface = info.id;
            entry.pane = pane;
            setIdentity(self, entry, "streamed:{d}\x00{d}\x00{d}", .{ @intFromPtr(term), streamed.id, info.id });
            count += 1;
        }
    }
    return count;
}

fn addHiddenAppRow(self: *Switcher, app_session: *muxtabs.AppSession) void {
    const remote = app_session.terminal.remote orelse return;
    var subtitle_buf: [512:0]u8 = undefined;
    const subtitle = std.fmt.bufPrintZ(&subtitle_buf, "No window is open - {s} - activate to show its log in a tab", .{hostLabel(app_session.terminal)}) catch "Application session without a window";
    const entry = appendRow(self, .applications, remote.session, subtitle, null, "view-conceal-symbolic", false) orelse return;
    entry.kind = .hidden_app;
    entry.app_session = app_session;
    setSessionTarget(self, entry, remote.session, remote.host, remote.origin_id, true);
    setIdentity(self, entry, "hidden:{d}", .{@intFromPtr(app_session.terminal)});
}

fn addPaneRow(self: *Switcher, pane: *Pane) void {
    const term = pane.terminal;
    const remote = term.remote orelse return;
    const title = if (term.screen.last_title) |value| value else remote.session;
    var subtitle_buf: [768:0]u8 = undefined;
    const kind = if (remote.is_app) "Application session" else "Shell session";
    const subtitle = std.fmt.bufPrintZ(&subtitle_buf, "{s} - {s} - {s}", .{ kind, hostLabel(term), remote.session }) catch "Attached mux session";
    const entry = appendRow(self, .attached, title, subtitle, null, if (remote.is_app) "application-x-executable-symbolic" else "utilities-terminal-symbolic", false) orelse return;
    entry.kind = .pane;
    entry.pane = pane;
    setIdentity(self, entry, "pane:{s}\x00{s}\x00{d}", .{ remote.host orelse "", remote.session, pane.id });
}

fn populateFetched(self: *Switcher) void {
    for (self.daemons.items) |*daemon| {
        const listing = daemon.listing orelse continue;
        for (listing.value.sessions) |*session| {
            if (session.exited) continue;
            const host: ?[]const u8 = if (daemon.host) |value| value else null;
            if (self.win.sessionShown(session.name, host)) continue;
            var running_apps: usize = 0;
            for (session.audio_streams, 0..) |info, index| {
                if (!info.running) continue;
                var duplicate = false;
                for (session.audio_streams[0..index]) |previous| {
                    if (previous.running and sameAudioApplication(previous, info)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                var streams: usize = 0;
                for (session.audio_streams) |candidate| if (candidate.running and sameAudioApplication(candidate, info)) {
                    streams += 1;
                };
                addFetchedAudioRow(self, daemon, session, info, streams);
                running_apps += 1;
            }
            if (running_apps == 0 and session.audio) {
                addFetchedAudioRow(self, daemon, session, .{ .running = true }, 1);
                running_apps = 1;
            }
            self.playing_apps += running_apps;
            addAvailableRow(self, daemon, session);
            self.available_sessions += 1;
        }
    }
}

fn addFetchedAudioRow(self: *Switcher, daemon: *DaemonState, session: *const mux_cli.SessionInfo, info: pulse.AudioInfo, streams: usize) void {
    var pid_buf: [48]u8 = undefined;
    const pid = if (info.pid != 0) std.fmt.bufPrint(&pid_buf, " - PID {d}", .{info.pid}) catch "" else "";
    var subtitle_buf: [1024:0]u8 = undefined;
    const media = if (info.media.len > 0) info.media else "Active playback stream";
    const subtitle = std.fmt.bufPrintZ(&subtitle_buf, "{s}{s} - {s} - session {s}{s}", .{
        media,
        if (streams > 1) " (multiple streams)" else "",
        daemon.origin,
        session.name,
        pid,
    }) catch "Playing on an available session";
    const entry = appendRow(self, .audio, displayApplication(info), subtitle, null, if (info.icon.len > 0) info.icon else "audio-x-generic-symbolic", true) orelse return;
    entry.kind = .attach;
    setSessionTarget(self, entry, session.name, daemon.host, session.origin_id, true);
    addWatchButton(self, entry);
    setIdentity(self, entry, "audio:{s}\x00{s}\x00{d}\x00{s}\x00{s}", .{ daemon.host orelse "", session.name, info.pid, info.application, info.binary });
}

fn addAvailableRow(self: *Switcher, daemon: *DaemonState, session: *const mux_cli.SessionInfo) void {
    const title = if (session.title.len > 0) session.title else session.name;
    var subtitle_buf: [896:0]u8 = undefined;
    const kind = if (session.app) "Application" else "Shell";
    const cwd = if (session.cwd.len > 0) session.cwd else "working directory unavailable";
    const subtitle = std.fmt.bufPrintZ(&subtitle_buf, "{s} - {s} - session {s} - {s} - {d} viewer(s)", .{ kind, daemon.origin, session.name, cwd, session.viewerCount() }) catch "Available mux session";
    const entry = appendRow(self, .available, title, subtitle, null, if (session.app) "application-x-executable-symbolic" else "utilities-terminal-symbolic", false) orelse return;
    entry.kind = .attach;
    setSessionTarget(self, entry, session.name, daemon.host, session.origin_id, true);
    addWatchButton(self, entry);
    setIdentity(self, entry, "attach:{s}\x00{s}", .{ daemon.host orelse "", session.name });
}

fn setIdentity(self: *Switcher, entry: *Entry, comptime format: []const u8, args: anytype) void {
    entry.identity = std.fmt.allocPrint(self.allocator, format, args) catch &.{};
}

fn appendRow(self: *Switcher, section: Section, title: []const u8, subtitle: [:0]const u8, paintable: ?*c.GdkPaintable, icon_name: []const u8, playing: bool) ?*Entry {
    const group = self.group(section);
    const list = group.list orelse return null;
    const row = c.gtk_list_box_row_new().?;
    const body = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12).?;
    c.gtk_widget_set_margin_start(body, 10);
    c.gtk_widget_set_margin_end(body, 10);
    c.gtk_widget_set_margin_top(body, 8);
    c.gtk_widget_set_margin_bottom(body, 8);

    if (paintable) |value| {
        const picture = c.gtk_picture_new_for_paintable(value).?;
        c.gtk_widget_set_size_request(picture, 136, 82);
        c.gtk_picture_set_content_fit(@ptrCast(picture), c.GTK_CONTENT_FIT_COVER);
        c.gtk_widget_add_css_class(picture, "card");
        c.gtk_box_append(@ptrCast(body), picture);
    } else {
        var icon_buf: [192:0]u8 = undefined;
        const icon_z = std.fmt.bufPrintZ(&icon_buf, "{s}", .{icon_name}) catch "application-x-executable-symbolic";
        const icon = c.gtk_image_new_from_icon_name(icon_z.ptr).?;
        c.gtk_image_set_pixel_size(@ptrCast(icon), if (section == .audio) 44 else 40);
        c.gtk_widget_set_size_request(icon, 72, 64);
        c.gtk_box_append(@ptrCast(body), icon);
    }

    const text = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 3).?;
    c.gtk_widget_set_hexpand(text, 1);
    c.gtk_widget_set_valign(text, c.GTK_ALIGN_CENTER);
    var title_buf: [512:0]u8 = undefined;
    const title_z = std.fmt.bufPrintZ(&title_buf, "{s}", .{title}) catch "Application";
    const title_label = c.gtk_label_new(title_z.ptr).?;
    c.gtk_label_set_xalign(@ptrCast(title_label), 0);
    c.gtk_label_set_ellipsize(@ptrCast(title_label), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(title_label, "heading");
    c.gtk_box_append(@ptrCast(text), title_label);
    const subtitle_label = c.gtk_label_new(subtitle.ptr).?;
    c.gtk_label_set_xalign(@ptrCast(subtitle_label), 0);
    c.gtk_label_set_ellipsize(@ptrCast(subtitle_label), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(subtitle_label, "dim-label");
    c.gtk_box_append(@ptrCast(text), subtitle_label);
    c.gtk_box_append(@ptrCast(body), text);

    if (playing) {
        const badge = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 5).?;
        c.gtk_widget_set_valign(badge, c.GTK_ALIGN_CENTER);
        c.gtk_widget_add_css_class(badge, "accent");
        const speaker = c.gtk_image_new_from_icon_name("audio-volume-high-symbolic").?;
        c.gtk_box_append(@ptrCast(badge), speaker);
        const label = c.gtk_label_new("Playing").?;
        c.gtk_widget_add_css_class(label, "caption-heading");
        c.gtk_box_append(@ptrCast(badge), label);
        c.gtk_widget_set_tooltip_text(badge, "This application has an uncorked PulseAudio stream");
        c.gtk_box_append(@ptrCast(body), badge);
    }

    const arrow = c.gtk_image_new_from_icon_name("go-next-symbolic").?;
    c.gtk_widget_add_css_class(arrow, "dim-label");
    c.gtk_widget_set_valign(arrow, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(body), arrow);
    c.gtk_list_box_row_set_child(@ptrCast(row), body);

    const search = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ title, subtitle }) catch {
        c.g_object_unref(row);
        return null;
    };
    const entry = self.allocator.create(Entry) catch {
        self.allocator.free(search);
        c.g_object_unref(row);
        return null;
    };
    entry.* = .{ .kind = .attach, .section = section, .row = row, .search = search };
    self.entries.append(self.allocator, entry) catch {
        entry.deinit(self.allocator);
        c.g_object_unref(row);
        return null;
    };
    c.g_object_set_data(@ptrCast(row), "sketerm-overview-entry", @ptrCast(entry));
    c.gtk_list_box_append(@ptrCast(list), row);
    return entry;
}

fn setSessionTarget(
    self: *Switcher,
    entry: *Entry,
    session: []const u8,
    host: ?[]const u8,
    origin_id: []const u8,
    can_kill: bool,
) void {
    const host_copy = if (host) |value| self.allocator.dupe(u8, value) catch return else null;
    const session_copy = self.allocator.dupe(u8, session) catch {
        if (host_copy) |value| self.allocator.free(value);
        return;
    };
    const origin_copy = if (mux_wire.validSessionOriginId(origin_id))
        self.allocator.dupe(u8, origin_id) catch {
            if (host_copy) |value| self.allocator.free(value);
            self.allocator.free(session_copy);
            return;
        }
    else
        null;
    entry.target = .{ .host = host_copy, .session = session_copy, .origin_id = origin_copy };
    if (!can_kill) return;
    const body = c.gtk_list_box_row_get_child(@ptrCast(entry.row)) orelse return;
    const button = c.gtk_button_new_from_icon_name("process-stop-symbolic").?;
    c.gtk_widget_set_valign(button, c.GTK_ALIGN_CENTER);
    c.gtk_widget_add_css_class(button, "flat");
    c.gtk_widget_add_css_class(button, "destructive-action");
    c.gtk_widget_set_tooltip_text(button, "Stop the entire mux session and all of its processes");
    // Every button targeting a session with a stop in flight is
    // insensitive, including duplicates on other rows and rebuilds
    // from a mid-kill re-render.
    if (self.isKilling(host, session)) c.gtk_widget_set_sensitive(button, 0);
    c.g_object_set_data(@ptrCast(button), "sketerm-overview-entry", @ptrCast(entry));
    _ = c.g_signal_connect_data(button, "clicked", @ptrCast(&onKillClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    // Keep the stop action before the trailing navigation arrow.
    c.gtk_box_insert_child_after(@ptrCast(body), button, c.gtk_widget_get_prev_sibling(c.gtk_widget_get_last_child(body)));
}

/// Add the Watch (read-only) and Take Control actions to an
/// attachable row. A watch attach mirrors the session without taking
/// the controller lease, so it never steals input from whoever is
/// driving (an assistant included); Take Control is the deliberate
/// escalation, the same lease the pane chip's button asks for. Both
/// icons and tooltips come from `assistants.attachVerb`, the one home
/// for that vocabulary.
fn addWatchButton(self: *Switcher, entry: *Entry) void {
    const body = c.gtk_list_box_row_get_child(@ptrCast(entry.row)) orelse return;
    inline for (.{ muxtabs.Lease.control, muxtabs.Lease.read_only }) |lease| {
        const verb = assistants.attachVerb(lease);
        const button = c.gtk_button_new_from_icon_name(verb.icon).?;
        c.gtk_widget_set_valign(button, c.GTK_ALIGN_CENTER);
        c.gtk_widget_add_css_class(button, "flat");
        c.gtk_widget_set_tooltip_text(button, verb.tip);
        c.g_object_set_data(@ptrCast(button), "sketerm-overview-entry", @ptrCast(entry));
        _ = c.g_signal_connect_data(button, "clicked", @ptrCast(if (lease == .control) &onTakeControlClicked else &onWatchClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_insert_child_after(@ptrCast(body), button, c.gtk_widget_get_prev_sibling(c.gtk_widget_get_last_child(body)));
    }
}

fn onWatchClicked(button: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    attachClicked(button, user, .read_only);
}

fn onTakeControlClicked(button: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    attachClicked(button, user, .control);
}

fn attachClicked(button: *c.GtkButton, user: ?*anyopaque, lease: muxtabs.Lease) void {
    const self = cast.userData(Switcher, user);
    const data = c.g_object_get_data(@ptrCast(button), "sketerm-overview-entry") orelse return;
    const entry: *Entry = @ptrCast(@alignCast(data));
    const target = entry.target orelse return;
    startAttach(self, target, lease);
}

fn applySearch(self: *Switcher, preferred: ?[]const u8) void {
    const query = cast.editableText(self.search);
    for (&self.groups) |*group| group.matches = 0;
    for (self.entries.items) |entry| {
        const matches = matchesSearch(entry.search, query);
        c.gtk_widget_set_visible(entry.row, @intFromBool(matches));
        if (matches) self.group(entry.section).matches += 1;
    }
    var total: usize = 0;
    for (&self.groups) |*group| {
        total += group.matches;
        if (group.widget) |widget| c.gtk_widget_set_visible(widget, @intFromBool(group.matches > 0));
    }
    if (self.empty) |empty| c.gtk_widget_set_visible(empty, @intFromBool(total == 0));
    if (preferred) |key| {
        for (self.entries.items) |entry| {
            if (c.gtk_widget_get_visible(entry.row) != 0 and std.mem.eql(u8, entry.identity, key)) {
                selectOnly(self, entry);
                return;
            }
        }
    }
    selectFirstVisible(self);
}

/// Case-insensitive substring match over a row's joined title +
/// subtitle.
///
/// This one deliberately does NOT go through `suggest.zig`, unlike the
/// launcher, the bookmark list and the LSP popup. Two reasons, and the
/// first is decisive: rows here are application and session names,
/// which are routinely non-ASCII, and correct folding for them means
/// `g_utf8_casefold` — GLib, which `suggest.zig` cannot use because it
/// compiles into `sketerm-mux`'s test root. Swapping in the shared
/// ASCII matcher would regress "Música" matching "MÚSICA" (there is a
/// test for exactly that). Second, the result is a boolean feeding
/// per-section visibility counters across FOUR separate list boxes, so
/// the ranking framework's single global score sort has nothing to
/// offer it either.
fn matchesSearch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    const folded_needle = c.g_utf8_casefold(needle.ptr, @intCast(needle.len)) orelse
        return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    defer c.g_free(folded_needle);
    const folded_haystack = c.g_utf8_casefold(haystack.ptr, @intCast(haystack.len)) orelse
        return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    defer c.g_free(folded_haystack);
    return std.mem.indexOf(u8, std.mem.span(@as([*:0]const u8, @ptrCast(folded_haystack))), std.mem.span(@as([*:0]const u8, @ptrCast(folded_needle)))) != null;
}

fn selectFirstVisible(self: *Switcher) void {
    for (&self.groups) |*group| if (group.list) |list| c.gtk_list_box_unselect_all(@ptrCast(list));
    for (self.entries.items) |entry| {
        if (c.gtk_widget_get_visible(entry.row) == 0) continue;
        selectOnly(self, entry);
        return;
    }
}

fn selectedEntry(self: *Switcher) ?*Entry {
    for (self.entries.items) |entry| {
        const list = self.group(entry.section).list orelse continue;
        if (c.gtk_list_box_get_selected_row(@ptrCast(list))) |row| {
            if (@as(*c.GtkWidget, @ptrCast(row)) == entry.row) return entry;
        }
    }
    return null;
}

fn selectOnly(self: *Switcher, entry: *Entry) void {
    for (&self.groups) |*group| if (group.list) |list| c.gtk_list_box_unselect_all(@ptrCast(list));
    const list = self.group(entry.section).list orelse return;
    c.gtk_list_box_select_row(@ptrCast(list), @ptrCast(entry.row));
}

fn onSearchChanged(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    applySearch(cast.userData(Switcher, user), null);
}

fn onKeyPressed(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Switcher, user);
    switch (keyval) {
        c.GDK_KEY_Escape => {
            c.gtk_window_close(@ptrCast(self.window));
            return 1;
        },
        c.GDK_KEY_Up => {
            moveSelection(self, -1);
            return 1;
        },
        c.GDK_KEY_Down => {
            moveSelection(self, 1);
            return 1;
        },
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
            if (self.attaching) return 1;
            for (&self.groups) |*group| {
                const list = group.list orelse continue;
                if (c.gtk_list_box_get_selected_row(@ptrCast(list))) |row| {
                    if (c.gtk_widget_get_visible(@ptrCast(row)) == 0) continue;
                    const data = c.g_object_get_data(@ptrCast(row), "sketerm-overview-entry") orelse continue;
                    activateEntry(self, @ptrCast(@alignCast(data)));
                    return 1;
                }
            }
            for (self.entries.items) |entry| {
                if (c.gtk_widget_get_visible(entry.row) != 0) {
                    activateEntry(self, entry);
                    return 1;
                }
            }
            return 1;
        },
        else => return 0,
    }
}

fn moveSelection(self: *Switcher, delta: isize) void {
    var visible: std.ArrayList(*Entry) = .empty;
    defer visible.deinit(self.allocator);
    var selected: ?usize = null;
    for (self.entries.items) |entry| {
        if (c.gtk_widget_get_visible(entry.row) == 0) continue;
        const index = visible.items.len;
        visible.append(self.allocator, entry) catch return;
        const list = self.group(entry.section).list orelse continue;
        if (c.gtk_list_box_get_selected_row(@ptrCast(list))) |row| {
            if (@as(*c.GtkWidget, @ptrCast(row)) == entry.row) selected = index;
        }
    }
    if (visible.items.len == 0) return;
    const current: isize = @intCast(selected orelse if (delta > 0) 0 else visible.items.len - 1);
    const next = std.math.clamp(current + delta, 0, @as(isize, @intCast(visible.items.len - 1)));
    const entry = visible.items[@intCast(next)];
    selectOnly(self, entry);
    _ = c.gtk_widget_grab_focus(entry.row);
    _ = c.gtk_widget_grab_focus(self.search);
}

fn onRowActivated(_: *c.GtkListBox, row: ?*c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const data = c.g_object_get_data(@ptrCast(row orelse return), "sketerm-overview-entry") orelse return;
    const self = cast.userData(Switcher, user);
    const entry: *Entry = @ptrCast(@alignCast(data));
    selectOnly(self, entry);
    activateEntry(self, entry);
}

fn paneLive(self: *Switcher, pane: *Pane) bool {
    for (self.win.panes.items) |candidate| if (candidate == pane) return true;
    return false;
}

fn appSessionLive(self: *Switcher, app_session: *muxtabs.AppSession) bool {
    for (self.win.app_sessions.items) |candidate| if (candidate == app_session) return true;
    return false;
}

fn activateEntry(self: *Switcher, entry: *Entry) void {
    switch (entry.kind) {
        .native_window => if (entry.native_host) |host| {
            if (self.nativeHostLive(host)) {
                if (entry.pane) |pane| {
                    if (paneLive(self, pane)) self.win.focusPaneTab(pane);
                } else host.presentSurface(entry.surface);
            }
        },
        .streamed_window => if (entry.streamed_host) |host| {
            if (self.streamedHostLive(host)) host.presentWindow(entry.surface);
        },
        .pane => if (entry.pane) |pane| {
            if (paneLive(self, pane)) self.win.focusPaneTab(pane);
        },
        .hidden_app => if (entry.app_session) |app_session| {
            if (appSessionLive(self, app_session)) {
                if (muxtabs.adoptAppSessionIntoTab(self.win, app_session)) |pane| self.win.focusPaneTab(pane);
            }
        },
        .audio => {
            if (entry.native_host) |host| {
                if (self.nativeHostLive(host)) host.presentAll();
            } else if (entry.pane) |pane| {
                if (paneLive(self, pane)) self.win.focusPaneTab(pane);
            } else if (entry.app_session) |app_session| {
                if (appSessionLive(self, app_session)) {
                    if (muxtabs.adoptAppSessionIntoTab(self.win, app_session)) |pane| self.win.focusPaneTab(pane);
                }
            }
        },
        .attach => {
            const target = entry.target orelse return;
            startAttach(self, target, .default);
            return;
        },
    }
    c.gtk_window_close(@ptrCast(self.window));
}

fn attachedFingerprint(self: *Switcher) u64 {
    var hash: u64 = 0;
    for (self.win.app_sessions.items) |app_session| hash = hashTerminal(hash, app_session.terminal);
    for (self.win.panes.items) |pane| hash = hashTerminal(hash, pane.terminal);
    return hash;
}

fn hashTerminal(seed: u64, term: *Terminal) u64 {
    const remote = term.remote orelse return seed;
    var hash = std.hash.Wyhash.hash(seed, remote.session);
    if (remote.host) |host| hash = std.hash.Wyhash.hash(hash, host);
    if (term.screen.last_title) |title| hash = std.hash.Wyhash.hash(hash, title);
    var counts = [_]usize{ remote.napps.items.len, remote.wsapps.items.len, remote.aapps.items.len };
    hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&counts));
    for (remote.napps.items) |app| {
        hash = app.host.overviewHash(hash);
    }
    for (remote.wsapps.items) |app| {
        hash = app.host.overviewHash(hash);
    }
    const infos = term.audioInfos(std.heap.c_allocator);
    defer std.heap.c_allocator.free(infos);
    for (infos) |info| {
        hash = std.hash.Wyhash.hash(hash, info.application);
        hash = std.hash.Wyhash.hash(hash, info.binary);
        hash = std.hash.Wyhash.hash(hash, info.media);
        hash = std.hash.Wyhash.hash(hash, info.icon);
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&info.pid));
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&info.running));
    }
    return hash;
}

fn onRefreshTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Switcher, user);
    if (self.dead) return 0;
    // No polling while an attach owns the UI: a poll would dial a
    // second connection to the very daemon the attach is talking to.
    if (self.attaching) return 1;
    const current = attachedFingerprint(self);
    if (current != self.attached_hash) scheduleRender(self);
    self.refresh_ticks +%= 1;
    if (self.refresh_ticks >= 5) {
        self.refresh_ticks = 0;
        discoverDaemons(self);
        pruneDaemons(self);
        startAllFetches(self);
    }
    return 1;
}

fn onRefreshClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Switcher, user);
    self.note = "";
    discoverDaemons(self);
    pruneDaemons(self);
    startAllFetches(self);
}

/// Drop assistant (`sock:`) daemons whose socket vanished — their MCP
/// instance is gone and re-discovery will never re-add them. Host
/// daemons stay: their reachability is what `failed` reports.
fn pruneDaemons(self: *Switcher) void {
    var index: usize = 0;
    var changed = false;
    while (index < self.daemons.items.len) {
        const daemon = &self.daemons.items[index];
        const host = daemon.host orelse {
            index += 1;
            continue;
        };
        if (!std.mem.startsWith(u8, host, "sock:") or daemon.busy) {
            index += 1;
            continue;
        }
        var path_buf: [1200:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{host["sock:".len..]}) catch {
            index += 1;
            continue;
        };
        var st: c.struct_stat = undefined;
        if (c.stat(path.ptr, &st) == 0) {
            index += 1;
            continue;
        }
        var removed = self.daemons.swapRemove(index);
        removed.deinit(self.allocator);
        changed = true;
    }
    if (changed) scheduleRender(self);
}

fn addDaemon(self: *Switcher, host: ?[]const u8, origin: []const u8) void {
    for (self.daemons.items) |daemon| {
        if (optionalEql(daemon.host, host)) return;
    }
    const host_copy = if (host) |value| self.allocator.dupe(u8, value) catch return else null;
    const origin_copy = self.allocator.dupe(u8, origin) catch {
        if (host_copy) |value| self.allocator.free(value);
        return;
    };
    self.daemons.append(self.allocator, .{ .host = host_copy, .origin = origin_copy }) catch {
        if (host_copy) |value| self.allocator.free(value);
        self.allocator.free(origin_copy);
    };
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn discoverDaemons(self: *Switcher) void {
    addDaemon(self, null, "local daemon");
    for (self.win.panes.items) |pane| {
        const remote = pane.terminal.remote orelse continue;
        if (remote.host) |host| addDaemon(self, host, host);
    }
    for (self.win.app_sessions.items) |app_session| {
        const remote = app_session.terminal.remote orelse continue;
        if (remote.host) |host| addDaemon(self, host, host);
    }

    // Assistant daemons come from the window's registry watcher, the
    // one place that knows which `sketerm mcp` instances are live.
    const watcher = self.win.assistants orelse return;
    for (watcher.roster.items) |assistant| {
        var origin_buf: [320:0]u8 = undefined;
        const origin = std.fmt.bufPrintZ(&origin_buf, "assistant {s}", .{assistant.label()}) catch continue;
        addDaemon(self, assistant.host, origin);
    }
}

/// One serialized daemon operation (list poll or session stop). It
/// borrows the daemon's persistent connection for the thread's lifetime
/// and hands it back on success; a failed op drops the connection (its
/// stream may hold a half-consumed reply) and the next op redials once.
const Op = struct {
    sw: *Switcher,
    host: ?[]u8,
    kill_session: ?[]u8 = null,
    kill_origin_id: ?[]u8 = null,
    conn: ?mux_client.Conn = null,
    ticket: ?mux_client.UdpTicket = null,
    generation: u64 = 0,
    parsed: ?std.json.Parsed(mux_cli.Welcome) = null,
    fingerprint: u64 = 0,
    ok: bool = false,

    fn destroy(self: *Op) void {
        const allocator = std.heap.c_allocator;
        if (self.conn) |*conn| conn.deinit();
        if (self.parsed) |*parsed| parsed.deinit();
        if (self.host) |host| allocator.free(host);
        if (self.kill_session) |session| allocator.free(session);
        if (self.kill_origin_id) |origin_id| allocator.free(origin_id);
        allocator.destroy(self);
    }
};

fn startAllFetches(self: *Switcher) void {
    for (self.daemons.items) |*daemon| startOp(self, daemon, null, null);
    self.updateStatus();
}

/// A bare user@host suitable for UDP ticket minting; null for local,
/// `sock:`, and every forced non-UDP transport.
fn bareRemoteHost(host: ?[]const u8) ?[]const u8 {
    const value = host orelse return null;
    if (std.mem.startsWith(u8, value, "sock:")) return null;
    if (!mux_client.udpTicketEligible(value)) return null;
    return mux_client.RemoteSpec.parse(value).host;
}

test "app switcher never mints UDP tickets for a forced transport" {
    try std.testing.expect(bareRemoteHost("tor:work-alias") == null);
    try std.testing.expect(bareRemoteHost("ssh:work-alias") == null);
    try std.testing.expectEqualStrings("work-alias", bareRemoteHost("udp:work-alias").?);
    try std.testing.expectEqualStrings("work-alias", bareRemoteHost("work-alias").?);
}

/// Submit a list poll (`kill_session` null) or a session stop. Stops are
/// tracked in `kills` exactly while a submission exists (queued or in
/// flight), which is what keeps every matching stop button insensitive
/// across re-renders.
fn startOp(
    self: *Switcher,
    daemon: *DaemonState,
    kill_session: ?[]const u8,
    kill_origin_id: ?[]const u8,
) void {
    const daemon_host: ?[]const u8 = if (daemon.host) |value| value else null;
    if (daemon.busy) {
        if (kill_session) |session| {
            if (daemon.pending_kill != null) return;
            daemon.pending_kill = self.allocator.dupe(u8, session) catch return;
            if (kill_origin_id) |origin_id| {
                daemon.pending_kill_origin = self.allocator.dupe(u8, origin_id) catch {
                    self.allocator.free(daemon.pending_kill.?);
                    daemon.pending_kill = null;
                    return;
                };
            }
            self.markKilling(daemon_host, session);
        }
        return;
    }
    const allocator = std.heap.c_allocator;
    const ctx = allocator.create(Op) catch {
        if (kill_session) |session| self.unmarkKilling(daemon_host, session);
        return;
    };
    ctx.* = .{ .sw = self, .host = null, .generation = daemon.generation };
    if (daemon.host) |host| {
        ctx.host = allocator.dupe(u8, host) catch {
            allocator.destroy(ctx);
            if (kill_session) |session| self.unmarkKilling(daemon_host, session);
            return;
        };
    }
    if (kill_session) |session| {
        ctx.kill_session = allocator.dupe(u8, session) catch {
            if (ctx.host) |host| allocator.free(host);
            allocator.destroy(ctx);
            self.unmarkKilling(daemon_host, session);
            return;
        };
        if (kill_origin_id) |origin_id| {
            ctx.kill_origin_id = allocator.dupe(u8, origin_id) catch {
                allocator.free(ctx.kill_session.?);
                if (ctx.host) |host| allocator.free(host);
                allocator.destroy(ctx);
                self.unmarkKilling(daemon_host, session);
                return;
            };
        }
        self.markKilling(daemon_host, session);
    }
    if (daemon.conn) |conn| {
        ctx.conn = conn;
        daemon.conn = null;
    }
    daemon.busy = true;
    self.pending_ops += 1;
    // First dial to a remote host: a UDP ticket minted over an already
    // attached connection skips the ssh bootstrap entirely. The mint
    // callback fires exactly once (3s bound), then the op proceeds on
    // whatever transport it got.
    if (ctx.conn == null) {
        if (bareRemoteHost(if (ctx.host) |value| value else null)) |bare| {
            if (self.win.mintUdpTicket(bare, @ptrCast(ctx), onOpTicket)) return;
        }
    }
    spawnOp(ctx);
}

fn onOpTicket(user: ?*anyopaque, ticket: ?mux_client.UdpTicket) void {
    const ctx = cast.userData(Op, user);
    ctx.ticket = ticket;
    spawnOp(ctx);
}

fn spawnOp(ctx: *Op) void {
    const thread = std.Thread.spawn(.{}, opThreadMain, .{ctx}) catch {
        opFailedLocally(ctx);
        return;
    };
    thread.detach();
}

/// Spawn failed before any thread existed: undo the accounting startOp
/// already committed.
fn opFailedLocally(ctx: *Op) void {
    const self = ctx.sw;
    if (!self.dead) {
        const host: ?[]const u8 = if (ctx.host) |value| value else null;
        if (findDaemon(self, host)) |daemon| daemon.busy = false;
        if (ctx.kill_session) |session| self.unmarkKilling(host, session);
    }
    ctx.destroy();
    if (self.opDone() and !self.dead) self.updateStatus();
}

fn opConnect(ctx: *Op) ?mux_client.Conn {
    const allocator = std.heap.c_allocator;
    if (ctx.ticket) |ticket| {
        if (mux_client.Conn.connectUdpTicket(allocator, ctx.host.?, ticket)) |conn| {
            return conn;
        } else |_| {}
    }
    return mux_cli.muxConnect(allocator, if (ctx.host) |value| value else null);
}

fn opThreadMain(ctx: *Op) void {
    const reused = ctx.conn != null;
    if (ctx.conn == null) ctx.conn = opConnect(ctx);
    if (ctx.conn != null and !runOp(ctx) and reused) {
        // The idle connection died between polls (daemon restart,
        // dropped link): one fresh dial, then give up until next poll.
        ctx.conn.?.deinit();
        ctx.conn = null;
        ctx.conn = opConnect(ctx);
        if (ctx.conn != null) _ = runOp(ctx);
    }
    _ = c.g_idle_add(@ptrCast(&onOpIdle), @ptrCast(ctx));
}

fn runOp(ctx: *Op) bool {
    const allocator = std.heap.c_allocator;
    const conn = &ctx.conn.?;
    if (ctx.kill_session) |session| {
        conn.sendKill(.{
            .name = session,
            .origin_id = ctx.kill_origin_id orelse "",
        }) catch return false;
        const f = conn.recvExpectFor(&.{.ok}, 10_000) catch return false;
        f.deinit(allocator);
        ctx.ok = true;
        return true;
    }
    conn.sendFrame(.list, "") catch return false;
    const f = conn.recvExpectFor(&.{.welcome}, 10_000) catch return false;
    defer f.deinit(allocator);
    if (ctx.parsed) |*old| {
        old.deinit();
        ctx.parsed = null;
    }
    // alloc_always: the parse must own every string — the frame payload
    // is freed on return, and this listing outlives it by many renders.
    ctx.parsed = std.json.parseFromSlice(mux_cli.Welcome, allocator, f.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return false;
    ctx.fingerprint = listingFingerprint(ctx.parsed.?.value.sessions);
    ctx.ok = true;
    return true;
}

fn listingFingerprint(sessions: []const mux_cli.SessionInfo) u64 {
    var hash: u64 = 0;
    for (sessions) |session| {
        hash = std.hash.Wyhash.hash(hash, session.name);
        hash = std.hash.Wyhash.hash(hash, session.title);
        hash = std.hash.Wyhash.hash(hash, session.cwd);
        const viewers = session.viewerCount();
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&viewers));
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&session.exited));
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&session.app));
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&session.audio));
        for (session.audio_streams) |info| {
            hash = std.hash.Wyhash.hash(hash, info.application);
            hash = std.hash.Wyhash.hash(hash, info.binary);
            hash = std.hash.Wyhash.hash(hash, info.media);
            hash = std.hash.Wyhash.hash(hash, info.icon);
            hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&info.pid));
            hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&info.running));
        }
    }
    return hash;
}

fn findDaemon(self: *Switcher, host: ?[]const u8) ?*DaemonState {
    for (self.daemons.items) |*daemon| if (optionalEql(daemon.host, host)) return daemon;
    return null;
}

fn onOpIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx = cast.userData(Op, user);
    const self = ctx.sw;
    const alive = !self.dead;
    var changed = false;
    if (alive) {
        const host: ?[]const u8 = if (ctx.host) |value| value else null;
        if (findDaemon(self, host)) |daemon| {
            daemon.busy = false;
            // A clean op hands its connection back for the next one; a
            // failed op's stream may hold a half-consumed reply, so the
            // connection is dropped (destroyed with ctx) and the next
            // op redials once.
            if (ctx.ok) {
                if (ctx.conn) |conn| {
                    daemon.conn = conn;
                    ctx.conn = null;
                }
            }
            if (ctx.kill_session) |session| {
                self.unmarkKilling(host, session);
                changed = true;
                if (ctx.ok) {
                    markFetchedSessionExited(self, host, session);
                    startOp(self, daemon, null, null);
                } else {
                    self.note = "stop failed: the session or daemon may be gone";
                }
            } else if (ctx.generation != daemon.generation) {
                startOp(self, daemon, null, null);
            } else {
                const failed = !ctx.ok;
                changed = daemon.failed != failed;
                daemon.failed = failed;
                if (ctx.parsed != null and (daemon.listing == null or daemon.fingerprint != ctx.fingerprint)) {
                    if (daemon.listing) |*old| old.deinit();
                    daemon.listing = ctx.parsed;
                    ctx.parsed = null;
                    daemon.fingerprint = ctx.fingerprint;
                    changed = true;
                }
            }
            if (daemon.pending_kill) |session| {
                daemon.pending_kill = null;
                const pending_origin = daemon.pending_kill_origin;
                daemon.pending_kill_origin = null;
                // Already marked at queue time; startOp re-marks (dedup)
                // for the in-flight phase.
                startOp(self, daemon, session, pending_origin);
                if (pending_origin) |origin_id| self.allocator.free(origin_id);
                self.allocator.free(session);
            }
        }
    }
    ctx.destroy();
    if (!self.opDone()) return 0;
    if (alive) {
        if (changed) scheduleRender(self) else self.updateStatus();
    }
    return 0;
}

/// Submit a Watch (read-only) or Take Control attach for a row. The
/// dial + handshake run on `muxtabs.AttachJob`; this side only owns the
/// dialog state around it (one attach at a time, sensitivity, note).
fn startAttach(self: *Switcher, target: SessionTarget, lease: muxtabs.Lease) void {
    if (self.attaching) return;
    // The attach becomes the session's event stream, so it consumes a
    // whole connection -- take the daemon's idle one instead of dialing
    // (on a remote host a fresh dial is an ssh spawn).
    var reuse: ?mux_client.Conn = null;
    const target_host: ?[]const u8 = if (target.host) |value| value else null;
    if (findDaemon(self, target_host)) |daemon| {
        if (!daemon.busy) {
            if (daemon.conn) |conn| {
                reuse = conn;
                daemon.conn = null;
            }
        }
    }
    if (!muxtabs.AttachJob.start(self.win, target_host, target.session, lease, reuse, onAttachReady, @ptrCast(self))) {
        if (reuse) |*conn| conn.deinit();
        return;
    }
    self.attaching = true;
    self.pending_ops += 1;
    self.note = "";
    c.gtk_widget_set_sensitive(self.groups_box, 0);
    c.gtk_widget_set_sensitive(self.search, 0);
    self.updateStatus();
}

fn onAttachReady(user: ?*anyopaque, job: *muxtabs.AttachJob) void {
    const self = cast.userData(Switcher, user);
    const alive = !self.dead;
    const ok = alive and job.finish();
    self.attaching = false;
    if (!self.opDone()) return;
    if (alive) {
        if (ok) {
            c.gtk_window_close(@ptrCast(self.window));
        } else {
            c.gtk_widget_set_sensitive(self.groups_box, 1);
            c.gtk_widget_set_sensitive(self.search, 1);
            self.note = "attach failed: the session or daemon may be gone";
            self.updateStatus();
        }
    }
}

fn onKillClicked(button: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Switcher, user);
    const data = c.g_object_get_data(@ptrCast(button), "sketerm-overview-entry") orelse return;
    const entry: *Entry = @ptrCast(@alignCast(data));
    const target = entry.target orelse return;
    const host: ?[]const u8 = if (target.host) |value| value else null;
    if (self.isKilling(host, target.session)) return;
    const daemon = findDaemon(self, host) orelse return;
    self.note = "";
    startOp(self, daemon, target.session, target.origin_id);
    // A re-render mid-kill rebuilds every row; the kill mark keeps the
    // rebuilt buttons insensitive, so disabling + rendering is enough.
    c.gtk_widget_set_sensitive(@ptrCast(button), 0);
    scheduleRender(self);
    self.updateStatus();
}

fn markFetchedSessionExited(self: *Switcher, host: ?[]const u8, session: []const u8) void {
    const daemon = findDaemon(self, host) orelse return;
    daemon.generation +%= 1;
    const listing = if (daemon.listing) |*value| value else return;
    for (listing.value.sessions) |*candidate| {
        if (!std.mem.eql(u8, candidate.name, session)) continue;
        candidate.exited = true;
        daemon.fingerprint = listingFingerprint(listing.value.sessions);
        return;
    }
}

test "overview search is case insensitive across row metadata" {
    try std.testing.expect(matchesSearch("Firefox Conference call dalaran", "conference"));
    try std.testing.expect(matchesSearch("Firefox Conference call dalaran", "DALARAN"));
    try std.testing.expect(matchesSearch("Música", "MÚSICA"));
    try std.testing.expect(!matchesSearch("Firefox Conference call dalaran", "terminal"));
}
