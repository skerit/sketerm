//! Durable mux tabs: session attach/restore, layout-restore jobs,
//! and tabless app sessions — split out of window.zig. Every function
//! takes the owning *Window and is aliased back into Window, so call
//! sites read identically on both sides of the split.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const crashlog = @import("../util/crashlog.zig");
const strz = @import("../util/strz.zig");
const layout_mod = @import("../layout.zig");
const Terminal = @import("../terminal.zig").Terminal;
const Pane = @import("pane.zig").Pane;
const winmod = @import("window.zig");
const Window = winmod.Window;

// ── Durable tabs (sketerm-mux) ───────────────────────────────

/// Connect locally or to a remote host using its transport policy.
pub fn muxConnect(self: *Window, host: ?[]const u8) !@import("../mux/client.zig").Conn {
    const mux_client = @import("../mux/client.zig");
    // The transport handshake forks and blocks the main loop; name it so
    // a death in here is attributable. Bare hosts bootstrap over SSH and
    // Terminal upgrades the live attachment to UDP in the background.
    crashlog.set("mux connect host={s}", .{host orelse "local"});
    defer crashlog.clear();
    if (host) |h| {
        // "sock:/path" targets a specific daemon instance's unix
        // socket (an MCP private/named daemon) — connect only,
        // NEVER autostart: a dead assistant daemon must not be
        // resurrected empty by a viewer.
        if (std.mem.startsWith(u8, h, "sock:")) {
            return mux_client.Conn.connectProbed(self.allocator, h[5..]);
        }
        const remote = mux_client.RemoteSpec.parse(h);
        if (remote.mode == .auto) return mux_client.Conn.connectSsh(self.allocator, remote.host);
        return mux_client.Conn.connectRemote(self.allocator, h, self.config.muxConnectOptions());
    }
    return mux_client.Conn.connectLocalAutostart(self.allocator);
}

/// Connect + attach a session as a viewer tab/app (switcher rows,
/// `sketerm cli attach-session`). Host semantics of muxConnect
/// (null local, bare auto, forced "udp:"/"ssh:", "sock:/path").
pub fn attachSessionByHost(self: *Window, name: []const u8, host: ?[]const u8) bool {
    const conn = muxConnect(self, host) catch return false;
    self.attachMux(conn, name, host, null) catch return false;
    return true;
}

/// Select the tab containing `pane`, focus it and raise the
/// window (switcher activate on an embedded app / pane row).
pub fn focusPaneTab(self: *Window, pane: *Pane) void {
    if (winmod.tabPageForPane(self, pane)) |page| {
        c.adw_tab_view_set_selected_page(self.tab_view, page);
        _ = c.gtk_widget_grab_focus(@ptrCast(pane.surface.area));
    }
    c.gtk_window_present(@ptrCast(self.app_window));
}

/// Spawn a shell session in the daemon (local or `host`'s) and
/// attach it as a tab.
pub fn newDurableTab(self: *Window, host: ?[]const u8) !void {
    try self.newDurableSession(host, null);
}

/// Durable shell tab on `host` starting in `cwd` — the browser's
/// "Open Terminal Here (new tab)". Unlike newDurableSession, the
/// cwd travels even for remote hosts (it names a REMOTE path).
pub fn newDurableSessionAt(self: *Window, host: ?[]const u8, cwd: []const u8) !void {
    var name_buf: [64]u8 = undefined;
    const name = Window.nextSessionName(&name_buf);
    var conn = try muxConnect(self, host);
    {
        errdefer conn.deinit();
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
            .cwd = cwd,
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
            .kb_layout = self.config.app_keyboard_layout,
        });
        (try conn.recvExpect(&.{.ok})).deinit(self.allocator);
    }
    try self.attachMux(conn, name, host, null);
}

/// Spawn a fresh session on the daemon and attach it — into a new
/// tab, or into `takeover`'s slot when the request came from a
/// `sketerm mux` CLI running inside that pane.
pub fn newDurableSession(self: *Window, host: ?[]const u8, takeover: ?*Pane) !void {
    var name_buf: [64]u8 = undefined;
    // Process-unique name (pid + global counter); see nextSessionName.
    const name = Window.nextSessionName(&name_buf);
    const profile = if (self.config.default_profile.len > 0) self.findProfile(self.config.default_profile) else null;
    const settings = if (profile) |p| &p.settings else &self.config.settings;

    var conn = try muxConnect(self, host);
    {
        // This errdefer covers ONLY the spawn phase; once the
        // block exits cleanly, attachMuxTab owns the conn (and
        // deinits it on its own failures).
        errdefer conn.deinit();
        // The account-shell launcher works with older remote daemons that
        // incorrectly use their inherited $SHELL.
        const argv: []const []const u8 = if (host != null)
            &@import("../mux/shell.zig").remote_login_argv
        else blk: {
            const sh: []const u8 = if (settings.shell) |s| s else sh2: {
                const env = c.getenv("SHELL");
                break :sh2 if (env != null) std.mem.span(env) else "/bin/sh";
            };
            break :blk &.{sh};
        };
        var remote_shell_buf: [512]u8 = undefined;
        var remote_env_items: [2][]const u8 = undefined;
        var remote_env_len: usize = 0;
        if (host != null) {
            if (settings.shell) |shell| {
                remote_env_items[remote_env_len] = try std.fmt.bufPrint(&remote_shell_buf, "SKETERM_REMOTE_SHELL={s}", .{shell});
                remote_env_len += 1;
            }
            remote_env_items[remote_env_len] = if (settings.login_shell) "SKETERM_REMOTE_LOGIN=1" else "SKETERM_REMOTE_LOGIN=0";
            remote_env_len += 1;
        }
        try conn.sendJson(.spawn, .{
            .name = name,
            .argv = argv,
            .env = remote_env_items[0..remote_env_len],
            .cwd = if (host != null) null else self.focusedPaneCwd(),
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
            .term = settings.term_env,
            .color_term = settings.color_term_env,
            .login_shell = host == null and settings.login_shell,
            .kb_layout = self.config.app_keyboard_layout,
        });
        (try conn.recvExpect(&.{.ok})).deinit(self.allocator);
    }
    try attachMuxProfile(self, conn, name, host, takeover, profile);
}

pub fn attachMuxTab(self: *Window, conn_in: @import("../mux/client.zig").Conn, name: []const u8, host: ?[]const u8) !void {
    try self.attachMux(conn_in, name, host, null);
}

/// True when a pane or tabless app session in this window already
/// renders mux session `name` on `host` (null = local daemon).
pub fn sessionShown(self: *Window, name: []const u8, host: ?[]const u8) bool {
    for (self.panes.items) |p| {
        const r = p.terminal.remote orelse continue;
        if (!hostEql(r.host, host)) continue;
        if (std.mem.eql(u8, r.session, name)) return true;
    }
    for (self.app_sessions.items) |as| {
        const r = as.terminal.remote orelse continue;
        if (!hostEql(r.host, host)) continue;
        if (std.mem.eql(u8, r.session, name)) return true;
    }
    return false;
}

pub const hostEql = strz.eqOpt;

/// Bulk handoff: attach every non-exited session on `host` that
/// this window isn't already showing. Terminal sessions become
/// tabs; app sessions follow app_view (tabless in window mode).
/// Returns the number attached.
pub fn attachAllSessions(self: *Window, host: ?[]const u8) u32 {
    const mux_cli = @import("../ipc/mux_cli.zig");
    var sessions = mux_cli.fetchSessions(self.allocator, host) orelse return 0;
    defer sessions.deinit();
    var n: u32 = 0;
    for (sessions.value.sessions) |s| {
        if (s.exited) continue;
        if (self.sessionShown(s.name, host)) continue;
        const conn = muxConnect(self, host) catch return n;
        self.attachMux(conn, s.name, host, null) catch continue;
        n += 1;
    }
    return n;
}

/// Focus the pane already rendering local mux session `name`, or
/// attach it as a new tab. Cross-session-search jump target.
pub fn focusOrAttachSession(self: *Window, name: []const u8) void {
    for (self.panes.items) |p| {
        const r = p.terminal.remote orelse continue;
        if (r.host != null) continue;
        if (!std.mem.eql(u8, r.session, name)) continue;
        if (winmod.tabPageForPane(self, p)) |page| {
            c.adw_tab_view_set_selected_page(self.tab_view, page);
            _ = c.gtk_widget_grab_focus(@ptrCast(p.surface.area));
            return;
        }
    }
    const conn = muxConnect(self, null) catch return;
    self.attachMux(conn, name, null, null) catch {};
}

/// Tabless forwarded-app session (window view mode): the mux
/// attach client feeding the app's floating windows. See the
/// `app_sessions` field docs.
pub const AppSession = struct {
    window: *Window,
    terminal: *Terminal,
    /// Exit handled — reap is deferred to an idle (the exit
    /// fires inside the terminal's own socket callback).
    doomed: bool = false,
    unavailable: bool = false,
    reap_idle_id: c_uint = 0,
};

/// Attach an app session with NO pane and NO tab: like a desktop
/// launcher, the app's own windows are the only thing that
/// appears. Takes ownership of `conn`.
pub fn attachMuxApp(
    self: *Window,
    conn_in: @import("../mux/client.zig").Conn,
    name: []const u8,
    host: ?[]const u8,
    snap_payload: []const u8,
    identity: @import("../mux/client.zig").AttachIdentity,
    read_only: bool,
    want_control: bool,
) !void {
    var conn = conn_in;
    const term = blk: {
        errdefer conn.deinit();
        break :blk try Terminal.initRemote(
            self.allocator,
            conn,
            name,
            snap_payload,
            identity,
            host,
            self.config.mux_udp_port_range,
            self.config.mux_tor_socks_endpoint,
            read_only,
            want_control,
        );
    };
    errdefer term.deinit();
    term.debug_to_stderr = self.debug_events;
    const as = try self.allocator.create(AppSession);
    errdefer self.allocator.destroy(as);
    as.* = .{ .window = self, .terminal = term };
    try self.app_sessions.append(self.allocator, as);
    term.user_ctx = @ptrCast(as);
    // Render requests only matter as the exit signal here
    // (remoteClosed sets child_exited, then fires this).
    term.on_render_request = appSessionRender;
    term.on_crashed = appSessionCrashed;
    term.on_connection_state = appSessionConnectionState;
    term.on_peers = appSessionPeers;
    term.on_app_view = appSessionAppView;
    term.on_panel_request = appSessionPanelRequest;
    term.on_panel_origin_close = @import("panelhost.zig").closeOrigin;
    term.on_panel_origin_renamed = @import("panelhost.zig").renameOrigin;
    term.on_panel_work_cancel = @import("panelhost.zig").cancelPanelWork;
    @import("panelhost.zig").attachOrigin(term, null);
}

/// A tabless app session ended. Normal quit (a window was shown)
/// drops it quietly; an exit with NO window ever shown means the
/// log is the user's only diagnostic (failed launch, or a
/// single-instance handoff) — materialize a held tab around it.
pub fn appSessionExited(self: *Window, as: *AppSession) void {
    _ = self;
    if (as.doomed) return;
    as.doomed = true;
    // Always defer: this is called from the Terminal's socket callback,
    // so even an allocation failure while materializing a log tab must
    // not deinit that Terminal before its callback returns.
    as.reap_idle_id = c.g_idle_add(@ptrCast(&appSessionReapIdle), @ptrCast(as));
}

pub fn appSessionReapIdle(user: ?*anyopaque) callconv(.c) c_int {
    const as = cast.userData(AppSession, user);
    as.reap_idle_id = 0;
    if (!as.terminal.remote.?.app_window_opened) {
        const status = as.terminal.screen.child_exit_status;
        const win = as.window;
        const unavailable = as.unavailable;
        if (adoptAppSessionIntoTab(win, as)) |pane| {
            if (unavailable)
                win.holdUnavailableAppPane(pane)
            else
                win.holdExitedAppPane(pane, status);
        }
        return 0;
    }
    unlistAppSession(as.window, as);
    return 0; // G_SOURCE_REMOVE
}

/// Drop a tabless app session: fence, deinit terminal, free.
pub fn unlistAppSession(self: *Window, as: *AppSession) void {
    if (as.reap_idle_id != 0) {
        _ = c.g_source_remove(as.reap_idle_id);
        as.reap_idle_id = 0;
    }
    for (self.app_sessions.items, 0..) |it, i| {
        if (it == as) {
            _ = self.app_sessions.swapRemove(i);
            break;
        }
    }
    as.terminal.clearSinks();
    as.terminal.deinit();
    self.allocator.destroy(as);
}

/// Materialize a real pane + tab around a live tabless app
/// terminal ("Show in Tab", or exit-without-window feedback).
/// Pane.init rewires user_ctx and callbacks; the AppSession is
/// freed (terminal ownership moves to panes/terminals). On
/// failure the whole session is dropped and null returned.
pub fn adoptAppSessionIntoTab(self: *Window, as: *AppSession) ?*Pane {
    const term = as.terminal;
    if (as.reap_idle_id != 0) {
        _ = c.g_source_remove(as.reap_idle_id);
        as.reap_idle_id = 0;
    }
    for (self.app_sessions.items, 0..) |it, i| {
        if (it == as) {
            _ = self.app_sessions.swapRemove(i);
            break;
        }
    }
    self.allocator.destroy(as);
    term.clearSinksForRewire();
    // Clear host callbacks still pointing at the freed AppSession;
    // the pane re-wires its own (adoptAppHost) after.
    if (term.remote) |r| {
        for (r.napps.items) |na| na.host.releaseEmbed();
    }
    const pane = self.makePane(term) catch {
        term.deinit();
        return null;
    };
    pane.id = self.allocPaneId();
    self.wirePaneSinks(pane);
    self.applyPaneConfig(pane, .{});
    registerPane(self, pane, term) catch {
        pane.deinit();
        term.deinit();
        return null;
    };
    @import("panelhost.zig").adoptTerminalOwner(term, pane, self);
    term.replayRetainedImages();

    var title_buf: [160:0]u8 = undefined;
    const title_z = if (term.remote.?.host) |h|
        std.fmt.bufPrintZ(&title_buf, "⌁ {s} @ {s}", .{ term.remote.?.session, h }) catch "app"
    else
        std.fmt.bufPrintZ(&title_buf, "⌁ {s}", .{term.remote.?.session}) catch "app";
    const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(wrapper, 1);
    c.gtk_widget_set_vexpand(wrapper, 1);
    c.gtk_box_append(@ptrCast(wrapper), pane.widget());
    const page = self.appendOrInsertTab(wrapper, .{ .leaf = pane }, false);
    c.adw_tab_page_set_title(page, title_z.ptr);
    c.adw_tab_page_set_tooltip(page, title_z.ptr);
    c.adw_tab_view_set_selected_page(self.tab_view, page);
    return pane;
}

/// Spawn a forwarded GUI-app session (`app=true`) running `argv`
/// on `host`'s daemon and attach it; in window view mode this is
/// TABLESS (floating windows only), in tab mode it's an embedded
/// tab. Used by the app launcher. `host` null = the local
/// autostart daemon. `gpu` = per-session dmabuf opt-in.
pub fn launchRemoteAppSession(self: *Window, host: ?[]const u8, argv: []const []const u8, gpu: bool) !void {
    var name_buf: [64]u8 = undefined;
    const name = Window.nextSessionName(&name_buf);
    var conn = try muxConnect(self, host);
    {
        errdefer conn.deinit();
        try conn.sendJson(.spawn, .{
            .name = name,
            .argv = argv,
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
            .app = true,
            .gpu = gpu,
            .kb_layout = self.config.app_keyboard_layout,
        });
        (try conn.recvExpect(&.{.ok})).deinit(self.allocator);
    }
    try self.attachMux(conn, name, host, null);
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
pub fn makeRemotePaneFromSnap(
    self: *Window,
    conn_in: @import("../mux/client.zig").Conn,
    name: []const u8,
    host: ?[]const u8,
    snap_payload: []const u8,
    identity: @import("../mux/client.zig").AttachIdentity,
    // Pre-allocated pane id, or null to allocate one. Daemon-backed local
    // panes pre-allocate so they can export SKETERM_PANE_ID into the child
    // env at spawn time; passing it here keeps that id (no double-alloc,
    // so pane ids stay contiguous — `split --pane 2` must find pane 2).
    pane_id: ?u32,
    read_only: bool,
    want_control: bool,
    ephemeral: bool,
) !*Pane {
    var conn = conn_in;
    const term = blk: {
        errdefer {
            if (ephemeral) {
                conn.setNonBlocking();
                conn.queueKill(.{
                    .name = name,
                    .origin_id = identity.originId(),
                }) catch {};
            }
            conn.deinit();
        }
        break :blk try Terminal.initRemote(
            self.allocator,
            conn,
            name,
            snap_payload,
            identity,
            host,
            self.config.mux_udp_port_range,
            self.config.mux_tor_socks_endpoint,
            read_only,
            want_control,
        );
    };
    errdefer term.deinit();
    // Set this before Pane construction: if any later allocation fails,
    // Terminal.deinit must kill a GUI-owned session rather than detach and
    // leave it running without a tab.
    if (term.remote) |remote| remote.ephemeral = ephemeral;
    term.debug_to_stderr = self.debug_events;
    const pane = try self.makePane(term);
    pane.id = pane_id orelse self.allocPaneId();
    errdefer pane.deinit();
    self.wirePaneSinks(pane);
    // Fonts, colors, padding, palette — same push every other
    // pane-creation path gets. Must happen before the widget
    // enters the tree (realize builds the atlas from pane state).
    self.applyPaneConfig(pane, .{});
    try registerPane(self, pane, term);
    // Pane sinks are wired — push snapshot-restored image
    // placements into the ImageStore.
    term.replayRetainedImages();
    return pane;
}

/// Reserve both owner lists before publishing either pointer.
fn registerPane(self: *Window, pane: *Pane, term: *Terminal) !void {
    try self.panes.ensureUnusedCapacity(self.allocator, 1);
    try self.terminals.ensureUnusedCapacity(self.allocator, 1);
    self.panes.appendAssumeCapacity(pane);
    self.terminals.appendAssumeCapacity(term);
    self.syncWindowGraphicsOffload();
}

/// Layout restore for a durable mux pane: attach when the
/// session still exists, otherwise recreate it under the SAME
/// name (daemon restarted / server rebooted) and attach that —
/// "resume or create". Returns the placed-nowhere pane.
pub fn restoreMuxPane(self: *Window, spec: layout_mod.PaneSpec) !*Pane {
    const host: ?[]const u8 = if (spec.mux_host.len > 0) spec.mux_host else null;
    const settings = self.config.profileSettings(spec.profile);
    var conn = try muxConnect(self, host);

    const Owned = @TypeOf(try conn.recvFrame());
    var snap: Owned = undefined;
    var identity: @import("../mux/client.zig").AttachIdentity = .{};
    {
        errdefer conn.deinit();
        try conn.sendAttach(spec.mux_session, .{ .kind = "gui", .panel_rpc = conn.panel_rpc });
        if (conn.recvGuiAttach()) |attached| {
            snap = attached.snapshot;
            identity = attached.identity;
        } else |attach_err| {
            if (attach_err != error.DaemonError) return attach_err;
            // The explicit remote launcher also works with old daemons.
            const argv: []const []const u8 = if (host != null)
                &@import("../mux/shell.zig").remote_login_argv
            else blk: {
                const sh: []const u8 = if (settings.shell) |s| s else sh2: {
                    const env = c.getenv("SHELL");
                    break :sh2 if (env != null) std.mem.span(env) else "/bin/sh";
                };
                break :blk &.{sh};
            };
            var remote_shell_buf: [512]u8 = undefined;
            var remote_env_items: [2][]const u8 = undefined;
            var remote_env_len: usize = 0;
            if (host != null) {
                if (settings.shell) |shell| {
                    remote_env_items[remote_env_len] = try std.fmt.bufPrint(&remote_shell_buf, "SKETERM_REMOTE_SHELL={s}", .{shell});
                    remote_env_len += 1;
                }
                remote_env_items[remote_env_len] = if (settings.login_shell) "SKETERM_REMOTE_LOGIN=1" else "SKETERM_REMOTE_LOGIN=0";
                remote_env_len += 1;
            }
            try conn.sendJson(.spawn, .{
                .name = spec.mux_session,
                .argv = argv,
                .env = remote_env_items[0..remote_env_len],
                .cwd = if (host != null or spec.cwd.len == 0) null else spec.cwd,
                .rows = @as(u16, 24),
                .cols = @as(u16, 80),
                .term = settings.term_env,
                .color_term = settings.color_term_env,
                .login_shell = host == null and settings.login_shell,
                .kb_layout = self.config.app_keyboard_layout,
            });
            (try conn.recvExpect(&.{.ok})).deinit(self.allocator);
            try conn.sendAttach(spec.mux_session, .{ .kind = "gui", .panel_rpc = conn.panel_rpc });
            const attached = try conn.recvGuiAttach();
            snap = attached.snapshot;
            identity = attached.identity;
        }
    }
    defer snap.deinit(self.allocator);
    const pane = try makeRemotePaneFromSnap(self, conn, spec.mux_session, host, snap.payload, identity, null, false, false, false);
    const profile = self.findProfile(spec.profile);
    pane.active_profile = if (profile) |p| p.name else null;
    self.applyPaneConfig(pane, .{ .profile = profile, .font_size_override = spec.font_size });
    return pane;
}

/// One in-flight async remote-mux reattach (layout restore).
/// The background thread touches ONLY the connect/handshake
/// fields; `canceled` and the result consumption are main-thread
/// (g_idle_add's internal lock orders the hand-off).
pub const MuxRestoreJob = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    /// Placeholder pane to take over; resolved by id on completion
    /// (the pane may have been closed meanwhile).
    pane_id: u32,
    session: []u8,
    host: []u8,
    port_range: []u8,
    tor_socks_endpoint: []u8,
    kb_layout: []u8,
    remote_shell: []u8,
    term: []u8,
    color_term: []u8,
    login_shell: bool,
    /// Thread results — set before g_idle_add, read after.
    conn: ?@import("../mux/client.zig").Conn = null,
    snap: ?[]u8 = null,
    identity: @import("../mux/client.zig").AttachIdentity = .{},
    err_name: []const u8 = "unknown",
    /// Main-thread only: window torn down; idle must not touch it.
    canceled: bool = false,

    fn destroy(job: *MuxRestoreJob) void {
        if (job.conn) |*cn| cn.deinit();
        if (job.snap) |s| job.allocator.free(s);
        job.allocator.free(job.session);
        job.allocator.free(job.host);
        job.allocator.free(job.port_range);
        job.allocator.free(job.tor_socks_endpoint);
        job.allocator.free(job.kb_layout);
        job.allocator.free(job.remote_shell);
        job.allocator.free(job.term);
        job.allocator.free(job.color_term);
        job.allocator.destroy(job);
    }
};

/// Kick off the background reattach for a restored remote mux
/// pane. Failure to start just leaves the placeholder shell.
pub fn startMuxRestoreJob(self: *Window, pane: *Pane, spec: layout_mod.PaneSpec) void {
    const a = self.allocator;
    const settings = self.config.profileSettings(spec.profile);
    const session = a.dupe(u8, spec.mux_session) catch return;
    const host = a.dupe(u8, spec.mux_host) catch {
        a.free(session);
        return;
    };
    const port_range = a.dupe(u8, self.config.mux_udp_port_range) catch {
        a.free(session);
        a.free(host);
        return;
    };
    const tor_socks_endpoint = a.dupe(u8, self.config.mux_tor_socks_endpoint) catch {
        a.free(session);
        a.free(host);
        a.free(port_range);
        return;
    };
    const kb_layout = a.dupe(u8, self.config.app_keyboard_layout) catch {
        a.free(session);
        a.free(host);
        a.free(port_range);
        a.free(tor_socks_endpoint);
        return;
    };
    const remote_shell = a.dupe(u8, settings.shell orelse "") catch {
        a.free(session);
        a.free(host);
        a.free(port_range);
        a.free(tor_socks_endpoint);
        a.free(kb_layout);
        return;
    };
    const term = a.dupe(u8, settings.term_env) catch {
        a.free(session);
        a.free(host);
        a.free(port_range);
        a.free(tor_socks_endpoint);
        a.free(kb_layout);
        a.free(remote_shell);
        return;
    };
    const color_term = a.dupe(u8, settings.color_term_env) catch {
        a.free(session);
        a.free(host);
        a.free(port_range);
        a.free(tor_socks_endpoint);
        a.free(kb_layout);
        a.free(remote_shell);
        a.free(term);
        return;
    };
    const job = a.create(MuxRestoreJob) catch {
        a.free(session);
        a.free(host);
        a.free(port_range);
        a.free(tor_socks_endpoint);
        a.free(kb_layout);
        a.free(remote_shell);
        a.free(term);
        a.free(color_term);
        return;
    };
    job.* = .{
        .allocator = a,
        .window = self,
        .pane_id = pane.id,
        .session = session,
        .host = host,
        .port_range = port_range,
        .tor_socks_endpoint = tor_socks_endpoint,
        .kb_layout = kb_layout,
        .remote_shell = remote_shell,
        .term = term,
        .color_term = color_term,
        .login_shell = settings.login_shell,
    };
    self.mux_restore_jobs.append(a, job) catch {
        job.destroy();
        return;
    };
    const th = std.Thread.spawn(.{}, muxRestoreThreadMain, .{job}) catch {
        std.debug.print(
            "sketerm: mux restore '{s}' @ {s}: thread spawn failed — pane stays a local shell\n",
            .{ job.session, job.host },
        );
        removeMuxRestoreJob(self, job);
        job.destroy();
        return;
    };
    th.detach();
}

pub fn removeMuxRestoreJob(self: *Window, job: *MuxRestoreJob) void {
    for (self.mux_restore_jobs.items, 0..) |it, i| {
        if (it == job) {
            _ = self.mux_restore_jobs.swapRemove(i);
            return;
        }
    }
}

/// Pending reattach targeting `pane_id`, if any — lets a layout
/// save while the connect is still in flight keep the mux
/// identity instead of demoting the pane to a plain local shell.
pub fn muxRestoreJobFor(self: *Window, pane_id: u32) ?*MuxRestoreJob {
    for (self.mux_restore_jobs.items) |job| {
        if (job.pane_id == pane_id) return job;
    }
    return null;
}

/// Background thread: connect + attach handshake, no GTK/Window
/// access. Results (or err_name) land on the job, then the idle
/// finishes on the main thread.
pub fn muxRestoreThreadMain(job: *MuxRestoreJob) void {
    muxRestoreConnect(job) catch |err| {
        job.err_name = @errorName(err);
    };
    _ = c.g_idle_add(@ptrCast(&onMuxRestoreDone), @ptrCast(job));
}

pub fn muxRestoreConnect(job: *MuxRestoreJob) !void {
    const mux_client = @import("../mux/client.zig");
    var conn = try mux_client.Conn.connectRemote(
        job.allocator,
        job.host,
        .{
            .udp_port_range = if (job.port_range.len > 0) job.port_range else null,
            .tor_socks_endpoint = job.tor_socks_endpoint,
        },
    );
    errdefer conn.deinit();

    // Bound the attach handshake: a remote that answers the hello
    // but then wedges would otherwise hang this thread (and leave
    // the placeholder pending) forever. Cleared before hand-off —
    // the GUI switches the fd to non-blocking anyway.
    setRecvTimeout(conn.fd, 30);
    defer setRecvTimeout(conn.fd, 0);

    try conn.sendAttach(job.session, .{ .kind = "gui", .panel_rpc = conn.panel_rpc });
    if (conn.recvGuiAttach()) |attached| {
        job.snap = attached.snapshot.payload;
        job.identity = attached.identity;
    } else |attach_err| {
        if (attach_err != error.DaemonError) return attach_err;
        // Session gone: recreate through the old-daemon-compatible
        // account-shell launcher under the same durable name.
        var remote_shell_buf: [512]u8 = undefined;
        var remote_env_items: [2][]const u8 = undefined;
        var remote_env_len: usize = 0;
        if (job.remote_shell.len > 0) {
            remote_env_items[remote_env_len] = try std.fmt.bufPrint(&remote_shell_buf, "SKETERM_REMOTE_SHELL={s}", .{job.remote_shell});
            remote_env_len += 1;
        }
        remote_env_items[remote_env_len] = if (job.login_shell) "SKETERM_REMOTE_LOGIN=1" else "SKETERM_REMOTE_LOGIN=0";
        remote_env_len += 1;
        try conn.sendJson(.spawn, .{
            .name = job.session,
            .argv = @as([]const []const u8, &@import("../mux/shell.zig").remote_login_argv),
            .env = remote_env_items[0..remote_env_len],
            .cwd = @as(?[]const u8, null),
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
            .term = job.term,
            .color_term = job.color_term,
            .kb_layout = job.kb_layout,
        });
        (try conn.recvExpect(&.{.ok})).deinit(job.allocator);
        try conn.sendAttach(job.session, .{ .kind = "gui", .panel_rpc = conn.panel_rpc });
        const attached = try conn.recvGuiAttach();
        job.snap = attached.snapshot.payload;
        job.identity = attached.identity;
    }
    job.conn = conn;
}

pub fn setRecvTimeout(fd: c_int, seconds: c_long) void {
    var tv: c.struct_timeval = .{ .tv_sec = seconds, .tv_usec = 0 };
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
}

/// Main-thread completion: swap the reattached session into the
/// placeholder pane's slot, or surface the failure as a toast.
pub fn onMuxRestoreDone(user: ?*anyopaque) callconv(.c) c_int {
    const job = cast.userData(MuxRestoreJob, user);
    defer job.destroy();
    // Window gone — job.window dangles; just drop everything
    // (destroy deinits the conn = clean detach, session persists).
    if (job.canceled) return 0;
    const win = job.window;
    removeMuxRestoreJob(win, job);

    if (job.conn == null or job.snap == null) {
        std.debug.print(
            "sketerm: mux restore '{s}' @ {s} failed ({s}) — pane stays a local shell\n",
            .{ job.session, job.host, job.err_name },
        );
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Couldn't reattach '{s}' @ {s} ({s}) — pane is a local shell",
            .{ job.session, job.host, job.err_name },
        ) catch "Couldn't reattach remote mux session";
        winmod.showToast(win, msg);
        return 0;
    }

    // Placeholder closed meanwhile, or the user already put a
    // durable session in its place — drop the attach quietly.
    const old = win.paneById(job.pane_id) orelse return 0;
    if (old.terminal.remote) |r| {
        if (!r.ephemeral) return 0;
    }

    const conn = job.conn.?;
    const remote = @import("../mux/client.zig").RemoteSpec.parse(job.host);
    const used_ssh_fallback = remote.mode == .auto and conn.transport == .ssh;
    job.conn = null; // ownership moves to makeRemotePaneFromSnap
    const pane = makeRemotePaneFromSnap(win, conn, job.session, job.host, job.snap.?, job.identity, null, false, false, false) catch |err| {
        std.debug.print(
            "sketerm: mux restore '{s}' @ {s}: pane build failed ({s})\n",
            .{ job.session, job.host, @errorName(err) },
        );
        return 0;
    };
    const profile = if (old.active_profile) |name| win.findProfile(name) else null;
    pane.active_profile = if (profile) |p| p.name else null;
    win.applyPaneConfig(pane, .{ .profile = profile, .font_size_override = old.surface.font_size });
    _ = win.swapPaneInPlace(old, pane) catch {
        // No tab slot to land in (mid-teardown) — drop the new pane.
        win.unlistPane(pane);
        return 0;
    };
    if (used_ssh_fallback) {
        var msg: [256]u8 = undefined;
        winmod.showToast(win, std.fmt.bufPrint(&msg, "UDP unavailable for {s}; restored over SSH", .{remote.host}) catch "UDP unavailable; restored over SSH");
    }
    return 0;
}

/// Controller-lease intent for one attach (see mux_cli.Lease).
pub const Lease = enum { default, read_only, control };

pub fn attachMux(self: *Window, conn_in: @import("../mux/client.zig").Conn, name: []const u8, host: ?[]const u8, takeover: ?*Pane) !void {
    return attachMuxProfile(self, conn_in, name, host, takeover, null);
}

pub fn attachMuxProfile(self: *Window, conn_in: @import("../mux/client.zig").Conn, name: []const u8, host: ?[]const u8, takeover: ?*Pane, profile: ?*const @import("../config.zig").Profile) !void {
    return attachMuxLease(self, conn_in, name, host, takeover, profile, .default);
}

pub fn attachMuxLease(self: *Window, conn_in: @import("../mux/client.zig").Conn, name: []const u8, host: ?[]const u8, takeover: ?*Pane, profile: ?*const @import("../config.zig").Profile, lease: Lease) !void {
    var conn = conn_in;
    self.mux_attach_err_len = 0;
    crashlog.set("mux attach '{s}' @ {s} takeover={} - handshake", .{ name, host orelse "local", takeover != null });

    const snap = blk: {
        errdefer conn.deinit();
        // A GUI attach asks for the app's controller lease by
        // default (it only lands if free); the daemon answers with
        // a control_state frame either way, so a viewer that did
        // not get it finds out.
        try conn.sendAttach(name, .{
            .kind = "gui",
            .read_only = lease == .read_only,
            .control = lease == .control,
            .panel_rpc = conn.panel_rpc,
        });
        break :blk conn.recvGuiAttach() catch |err| {
            // Stash the daemon's reason while `conn` is still alive
            // (the errdefer below frees it) so the caller surfaces it.
            const m = conn.lastErr();
            const n = @min(m.len, self.mux_attach_err.len);
            @memcpy(self.mux_attach_err[0..n], m[0..n]);
            self.mux_attach_err_len = n;
            return err;
        };
    };
    defer snap.snapshot.deinit(self.allocator);

    return attachMuxPrepared(self, conn, name, host, snap.snapshot.payload, snap.identity, takeover, profile, lease);
}

/// Finish an attach whose transport handshake and snapshot ran off-thread.
pub fn attachMuxPrepared(self: *Window, conn_in: @import("../mux/client.zig").Conn, name: []const u8, host: ?[]const u8, snapshot_payload: []const u8, identity: @import("../mux/client.zig").AttachIdentity, takeover: ?*Pane, profile: ?*const @import("../config.zig").Profile, lease: Lease) !void {
    _ = try attachMuxPreparedMode(self, conn_in, name, host, snapshot_payload, identity, takeover, profile, lease, false);
}

pub const PreparedTab = struct {
    pane: *Pane,
    page: *c.AdwTabPage,
};

/// Finish an off-thread attach in a new selected tab, including app sessions
/// that ordinary app-view policy would otherwise keep tabless.
pub fn attachMuxPreparedTab(self: *Window, conn_in: @import("../mux/client.zig").Conn, name: []const u8, host: ?[]const u8, snapshot_payload: []const u8, identity: @import("../mux/client.zig").AttachIdentity, lease: Lease) !PreparedTab {
    return (try attachMuxPreparedMode(self, conn_in, name, host, snapshot_payload, identity, null, null, lease, true)) orelse
        error.TabPlacementFailed;
}

fn attachMuxPreparedMode(self: *Window, conn_in: @import("../mux/client.zig").Conn, name: []const u8, host: ?[]const u8, snapshot_payload: []const u8, identity: @import("../mux/client.zig").AttachIdentity, takeover: ?*Pane, profile: ?*const @import("../config.zig").Profile, lease: Lease, force_tab: bool) !?PreparedTab {
    var conn = conn_in;

    // App sessions in window view mode attach TABLESS (their
    // floating windows are the only UI — a desktop launcher does
    // not open a terminal). Snapshot header byte 8 is the app
    // flag. Takeover keeps the tab path: the user explicitly
    // attached from inside a pane.
    const envelope = @import("../mux/snapshot.zig").peelEnvelope(snapshot_payload) catch {
        conn.deinit();
        return error.BadSnapshot;
    };
    if (!force_tab and takeover == null and self.config.app_view == .window and envelope.app) {
        try attachMuxApp(self, conn, name, host, snapshot_payload, identity, lease == .read_only, lease == .control);
        return null;
    }

    crashlog.set("mux attach '{s}' @ {s} takeover={} - building pane", .{ name, host orelse "local", takeover != null });
    const pane = try makeRemotePaneFromSnap(self, conn, name, host, snapshot_payload, identity, null, lease == .read_only, lease == .control, false);
    pane.active_profile = if (profile) |p| p.name else null;
    self.applyPaneConfig(pane, .{ .profile = profile });
    if (force_tab) pane.app_view_tab = true;

    var title_buf: [160:0]u8 = undefined;
    const title_z = if (host) |h|
        std.fmt.bufPrintZ(&title_buf, "⌁ {s} @ {s}", .{ name, h }) catch "mux"
    else
        std.fmt.bufPrintZ(&title_buf, "⌁ {s}", .{name}) catch "mux";

    // From here on the pane is LISTED (panes/terminals) and owns the
    // connection, so a failure must unlist it - leaving it listed with
    // no parent widget keeps a live fd watch and a phantom pane in every
    // later query (layout save, `cli list`, pane cycling).
    const page = if (takeover) |old|
        self.swapPaneInPlace(old, pane) catch |err| {
            self.unlistPane(pane);
            return err;
        }
    else blk: {
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_box_append(@ptrCast(wrapper), pane.widget());
        break :blk self.appendOrInsertTab(wrapper, .{ .leaf = pane }, false);
    };
    c.adw_tab_page_set_title(page, title_z.ptr);
    c.adw_tab_page_set_tooltip(page, title_z.ptr);
    c.adw_tab_view_set_selected_page(self.tab_view, page);
    _ = c.gtk_widget_grab_focus(@ptrCast(pane.surface.area));
    return .{ .pane = pane, .page = page };
}

// ── tabless app-session callbacks (Terminal → AppSession) ────────

/// Exit signal for tabless app sessions: remoteClosed sets
/// child_exited then fires on_render_request (there is no pane tick
/// to notice it).
pub fn appSessionRender(ctx: ?*anyopaque) void {
    const as = cast.userData(Window.AppSession, ctx);
    if (!as.terminal.screen.child_exited) return;
    as.terminal.screen.child_exited = false;
    appSessionExited(as.window, as);
}

/// Protocol corruption remains fatal; ordinary transport loss reconnects.
pub fn appSessionCrashed(ctx: ?*anyopaque) void {
    const as = cast.userData(Window.AppSession, ctx);
    appSessionExited(as.window, as);
}

pub fn appSessionConnectionState(ctx: ?*anyopaque, state: Terminal.ConnectionState, _: u32) void {
    const as = cast.userData(Window.AppSession, ctx);
    switch (state) {
        .lost => winmod.showToast(as.window, "Remote app connection lost; reconnecting"),
        .unavailable => {
            winmod.showToast(as.window, "Remote app session is no longer available");
            as.unavailable = true;
            appSessionExited(as.window, as);
        },
        .connected => winmod.showToast(as.window, "Remote app reconnected"),
        else => {},
    }
}

/// AI-driving badge on the floating windows (no pane border to tint).
pub fn appSessionPeers(ctx: ?*anyopaque) void {
    const as = cast.userData(Window.AppSession, ctx);
    const t = as.terminal;
    const remote = t.remote orelse return;
    for (remote.napps.items) |na| na.host.setDriven(t.peer_drivers > 0);
}

pub fn appSessionPanelRequest(
    ctx: ?*anyopaque,
    terminal: *Terminal,
    request_id: u64,
    request: []const u8,
) void {
    const as = cast.userData(Window.AppSession, ctx);
    @import("panelhost.zig").dispatchRelay(as.window, terminal, null, request_id, request);
}

/// New app host on a tabless session: offer "Show in Tab" via the
/// host menu (materializes a tab, then embeds).
pub fn appSessionAppView(ctx: ?*anyopaque, host_opaque: ?*anyopaque) void {
    const as = cast.userData(Window.AppSession, ctx);
    const AppHost = @import("../wlapp.zig").AppHost;
    const new: ?*AppHost = @ptrCast(@alignCast(host_opaque));
    if (new) |h| {
        h.embed_ctx = @ptrCast(as);
        h.on_request_embed = appSessionRequestEmbed;
        h.on_embed = null;
    }
}

pub fn appSessionRequestEmbed(ctx: ?*anyopaque) void {
    const as = cast.userData(Window.AppSession, ctx);
    const win = as.window;
    const term = as.terminal;
    const pane = adoptAppSessionIntoTab(win, as) orelse return;
    const remote = term.remote orelse return;
    if (remote.napps.items.len > 0)
        pane.adoptAppHost(@ptrCast(remote.napps.items[0].host));
}

test "pane registration publishes neither pointer when terminal reserve fails" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    var window: Window = undefined;
    window.allocator = failing.allocator();
    window.panes = .empty;
    window.terminals = .empty;
    defer window.panes.deinit(window.allocator);
    defer window.terminals.deinit(window.allocator);
    var pane: Pane = undefined;
    var terminal: Terminal = undefined;

    try std.testing.expectError(error.OutOfMemory, registerPane(&window, &pane, &terminal));
    try std.testing.expect(window.panes.capacity > 0);
    try std.testing.expectEqual(@as(usize, 0), window.panes.items.len);
    try std.testing.expectEqual(@as(usize, 0), window.terminals.items.len);
}

// ── Off-thread session attach ────────────────────────────────

/// One session attach whose transport dial and snapshot handshake run
/// off the main loop, finishing on an idle with `attachMuxPrepared`.
///
/// The one home for "attach a session I only know by host + name"
/// from a click: the Session Overview and the assistant activity chip
/// both go through it, so a wedged daemon costs a bounded, described
/// failure rather than a frozen GUI. `on_ready` fires exactly once on
/// the main thread with the job still alive: the caller checks its own
/// liveness fence and calls `finish` (the attach itself) only while its
/// window still exists; the job is freed when the callback returns.
pub const AttachJob = struct {
    win: *Window,
    host: ?[]u8,
    session: []u8,
    origin_id: []u8,
    lease: Lease,
    placement: Placement,
    /// Idle connection to the daemon taken at submit time; a fresh dial
    /// follows when it is absent or has died between polls.
    reuse: ?mux_client.Conn = null,
    conn: ?mux_client.Conn = null,
    snapshot: ?mux_client.Conn.OwnedFrame = null,
    identity: mux_client.AttachIdentity = .{},
    on_ready: *const fn (ctx: ?*anyopaque, job: *AttachJob) void,
    ctx: ?*anyopaque,

    const mux_client = @import("../mux/client.zig");
    const mux_cli = @import("../ipc/mux_cli.zig");

    pub const Placement = enum { policy, tab };

    /// Spawn the job. Returns false (nothing scheduled, `on_ready`
    /// never called) when the worker could not be created.
    pub fn start(
        win: *Window,
        host: ?[]const u8,
        session: []const u8,
        origin_id: []const u8,
        lease: Lease,
        placement: Placement,
        reuse: ?mux_client.Conn,
        on_ready: *const fn (ctx: ?*anyopaque, job: *AttachJob) void,
        ctx: ?*anyopaque,
    ) bool {
        const allocator = std.heap.c_allocator;
        const job = allocator.create(AttachJob) catch return false;
        const session_owned = allocator.dupe(u8, session) catch {
            allocator.destroy(job);
            return false;
        };
        const origin_owned = allocator.dupe(u8, origin_id) catch {
            allocator.free(session_owned);
            allocator.destroy(job);
            return false;
        };
        job.* = .{
            .win = win,
            .host = null,
            .session = session_owned,
            .origin_id = origin_owned,
            .lease = lease,
            .placement = placement,
            .reuse = reuse,
            .on_ready = on_ready,
            .ctx = ctx,
        };
        if (host) |h| {
            job.host = allocator.dupe(u8, h) catch {
                job.destroy();
                return false;
            };
        }
        const thread = std.Thread.spawn(.{}, threadMain, .{job}) catch {
            job.destroy();
            return false;
        };
        thread.detach();
        return true;
    }

    fn destroy(self: *AttachJob) void {
        const allocator = std.heap.c_allocator;
        if (self.reuse) |*conn| conn.deinit();
        if (self.conn) |*conn| conn.deinit();
        if (self.snapshot) |snapshot| snapshot.deinit(allocator);
        if (self.host) |host| allocator.free(host);
        allocator.free(self.session);
        allocator.free(self.origin_id);
        allocator.destroy(self);
    }

    fn attachOn(self: *AttachJob, conn: *mux_client.Conn) bool {
        conn.sendAttach(self.session, .{
            .kind = "gui",
            .origin_id = self.origin_id,
            .read_only = self.lease == .read_only,
            .control = self.lease == .control,
            .panel_rpc = conn.panel_rpc,
        }) catch return false;
        const attached = conn.recvGuiAttachFor(20_000) catch return false;
        self.snapshot = attached.snapshot;
        self.identity = attached.identity;
        return true;
    }

    fn threadMain(self: *AttachJob) void {
        const host: ?[]const u8 = if (self.host) |value| value else null;
        if (self.reuse) |value| {
            var conn = value;
            self.reuse = null;
            if (self.attachOn(&conn)) {
                self.conn = conn;
                _ = c.g_idle_add(@ptrCast(&onIdle), @ptrCast(self));
                return;
            }
            // The idle connection may have died between polls; one
            // fresh dial before reporting failure.
            conn.deinit();
        }
        if (mux_cli.muxConnect(std.heap.c_allocator, host)) |fresh| {
            var conn = fresh;
            if (self.attachOn(&conn)) {
                self.conn = conn;
            } else {
                conn.deinit();
            }
        }
        _ = c.g_idle_add(@ptrCast(&onIdle), @ptrCast(self));
    }

    /// Whether the handshake produced something to attach; false is
    /// the daemon or session being gone.
    pub fn ready(self: *const AttachJob) bool {
        return self.conn != null and self.snapshot != null;
    }

    /// Attach the prepared session into the window (main thread, from
    /// `on_ready` only). Consumes the connection either way.
    pub fn finish(self: *AttachJob) bool {
        if (!self.ready()) return false;
        const conn = self.conn.?;
        self.conn = null;
        const snapshot = self.snapshot.?;
        switch (self.placement) {
            .policy => attachMuxPrepared(
                self.win,
                conn,
                self.session,
                if (self.host) |host| host else null,
                snapshot.payload,
                self.identity,
                null,
                null,
                self.lease,
            ) catch return false,
            .tab => _ = attachMuxPreparedTab(
                self.win,
                conn,
                self.session,
                if (self.host) |host| host else null,
                snapshot.payload,
                self.identity,
                self.lease,
            ) catch return false,
        }
        return true;
    }

    fn onIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(AttachJob, user);
        self.on_ready(self.ctx, self);
        self.destroy();
        return 0;
    }
};
