//! Language-server connections and the PROCESS-WIDE registry that owns
//! them.
//!
//! ## One server per (server, root), for the whole process
//!
//! Every editor face (a pane's, a split's, the standalone window's) has
//! its own `Manager` for popups and per-tab state, but the servers are
//! shared: `registry` keys local ones by (server name, workspace root)
//! and remote ones by (host link, name, root), and `Conn.refs` counts
//! the tabs attached from EVERY face. The last tab out, whichever face it
//! is in, shuts the server down (`shutdown`, `exit`, SIGKILL after
//! `SHUTDOWN_GRACE_MS`). Remote links are shared the same way, one per
//! host.
//!
//! Answers are routed back by tab id (document tab ids are unique across
//! faces), notifications by document URI, and a server-initiated
//! `workspace/applyEdit` to the face that sent the server's latest
//! request.
//!
//! ## One document, one owner
//!
//! LSP lets a client open a URI once. The same file open in two faces is
//! two buffers, so the first tab to open it owns the server's view of it;
//! a second copy is PASSIVE (no didOpen, no diagnostics) until the owner
//! closes, at which point it is promoted and opened with its own text.
//! Asking a passive copy for a feature says so on the status line.
//!
//! ## Threading
//!
//! None. The server's stdout and stderr are non-blocking pipes watched
//! with `g_unix_fd_add`, exactly like the mux socket, and stdin gets a
//! G_IO_OUT watch only while a write is short.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const editorlsp = @import("editorlsp.zig");
const Manager = editorlsp.Manager;
const TabState = editorlsp.TabState;
const ETab = @import("editorview.zig").ETab;
const link_mod = @import("editorlsp_link.zig");
const RemoteLink = link_mod.RemoteLink;
const rpc = @import("../lsp/rpc.zig");
const session = @import("../lsp/session.zig");
const proc = @import("../lsp/proc.zig");
const servers = @import("../lsp/servers.zig");
const stderrtail = @import("../lsp/stderrtail.zig");
const wire = @import("../mux/wire.zig");
const clock = @import("../util/clock.zig");
const Config = @import("../config.zig").Config;
const LspServer = @import("../config.zig").LspServer;
const dbg = editorlsp.dbg;

/// How long a server gets to exit after `shutdown` before SIGKILL.
pub const SHUTDOWN_GRACE_MS: c_uint = 1500;

pub const Conn = struct {
    /// Registry name ("zls"), owned.
    name: []u8,
    /// Workspace root path, owned.
    root: []u8,
    /// `file://` root URI, owned.
    root_uri: []u8,
    child: proc.Child = .{},
    /// Remote transport: the server runs on the daemon's host and its
    /// stdio rides `link` as chan_data frames for channel `chan`. Null =
    /// local child process. Everything except `pumpWrite` and teardown is
    /// transport-blind.
    remote: ?Remote = null,
    sess: session.Session,
    watch_out: c_uint = 0,
    watch_err: c_uint = 0,
    watch_in: c_uint = 0,
    /// Bytes of `sess.out` already handed to the pipe.
    out_pos: usize = 0,
    /// Tabs currently attached, from every face.
    refs: usize = 0,
    /// Set once teardown has begun; every callback becomes a no-op.
    closing: bool = false,
    /// Grace timer between `shutdown` and SIGKILL; 0 = none.
    kill_timer: c_uint = 0,
    /// Deferred removal after a transport/session failure; 0 = none.
    remove_idle: c_uint = 0,
    /// Exact-pid child watch. It outlives this connection when teardown
    /// wins the race with child exit.
    child_watch: ?*LocalChildWatch = null,
    /// The server's last stderr lines: its pipe for a local server, the
    /// daemon's copy (shipped with the channel's close) for a remote one.
    tail: stderrtail.Tail = .{},
    /// The server reached `.ready`, so a later death is a FAILURE worth
    /// telling the user about rather than a missing server.
    was_ready: bool = false,
    /// The face whose request went out last: where a server-initiated
    /// `workspace/applyEdit` lands.
    last_mgr: ?*Manager = null,

    pub fn handler(self: *Conn) session.Handler {
        return .{
            .ctx = self,
            .on_response = onResponse,
            .on_notification = onNotification,
            .on_state = onState,
            .on_apply_edit = onApplyEdit,
        };
    }

    /// The server asked us to write a `WorkspaceEdit`: how a code action
    /// that carries only a `command` gets its work done.
    fn onApplyEdit(ctx: *anyopaque, params: std.json.Value) bool {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        if (self.closing) return false;
        const mgr = registry.managerForEdit(self) orelse return false;
        return mgr.onServerApplyEdit(self, params);
    }

    fn onResponse(ctx: *anyopaque, req: session.Request, env: rpc.Envelope) void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        if (self.closing) return;
        const mgr = registry.managerForTab(req.tab_id) orelse return;
        mgr.handleResponse(self, req, env);
    }

    fn onNotification(ctx: *anyopaque, method: []const u8, params: std.json.Value) void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        if (self.closing) return;
        registry.onNotification(self, method, params);
    }

    fn onState(ctx: *anyopaque, state: session.State) void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        switch (state) {
            .ready => {
                self.was_ready = true;
                registry.onReady(self);
            },
            .dead => registry.onDead(self),
            else => {},
        }
    }

    pub const Remote = struct {
        link: *RemoteLink,
        chan: u32,
        /// False once chan_close went out (or came in) — nothing may be
        /// queued for the channel after that.
        open: bool = true,
    };

    /// Push whatever the session queued into the server's stdin.
    /// Installs a writable watch only when the pipe is full, so the
    /// common case costs one write() and no GLib source.
    ///
    /// Remote transport: the bytes become chan_data frames on the link's
    /// mux connection instead — the link owns the partial-write
    /// buffering (its own G_IO_OUT watch), so the whole queue moves at
    /// once.
    pub fn pumpWrite(self: *Conn) void {
        if (self.closing) return;
        if (self.remote) |*rm| {
            if (self.sess.out.items.len == 0) return;
            defer {
                self.sess.out.clearRetainingCapacity();
                self.out_pos = 0;
            }
            if (!rm.open or rm.link.state != .up) return;
            const CHUNK: usize = 1 << 20;
            var off: usize = 0;
            const bytes = self.sess.out.items;
            while (off < bytes.len) {
                const end = @min(off + CHUNK, bytes.len);
                const payload = registry.alloc.alloc(u8, 4 + (end - off)) catch {
                    self.sess.markDead();
                    return;
                };
                defer registry.alloc.free(payload);
                std.mem.writeInt(u32, payload[0..4], rm.chan, .little);
                @memcpy(payload[4..], bytes[off..end]);
                rm.link.io().queueFrame(.chan_data, payload) catch {
                    rm.link.markDead();
                    return;
                };
                off = end;
            }
            rm.link.armWriteWatch();
            return;
        }
        if (self.child.stdin < 0) return;
        while (self.out_pos < self.sess.out.items.len) {
            const rest = self.sess.out.items[self.out_pos..];
            const n = c.write(self.child.stdin, rest.ptr, rest.len);
            if (n > 0) {
                self.out_pos += @intCast(n);
                continue;
            }
            const err = std.posix.errno(@as(isize, @intCast(n)));
            if (err == .AGAIN or err == .INTR) {
                if (self.watch_in == 0) {
                    self.watch_in = c.g_unix_fd_add(
                        self.child.stdin,
                        c.G_IO_OUT | c.G_IO_ERR | c.G_IO_HUP,
                        @ptrCast(&onWritable),
                        @ptrCast(self),
                    );
                }
                return;
            }
            // A broken pipe means the server is gone.
            self.sess.markDead();
            return;
        }
        self.sess.out.clearRetainingCapacity();
        self.out_pos = 0;
        if (self.watch_in != 0) {
            _ = c.g_source_remove(self.watch_in);
            self.watch_in = 0;
        }
    }

    fn onWritable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Conn, user);
        if (self.closing) {
            self.watch_in = 0;
            return 0;
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_in = 0;
            self.sess.markDead();
            return 0;
        }
        const had = self.watch_in;
        self.watch_in = 0;
        self.pumpWrite();
        // pumpWrite reinstalls the watch when it is still short; if it
        // did, keep THIS source (same fd, same callback) rather than
        // leaving two behind.
        if (self.watch_in != 0) {
            _ = c.g_source_remove(self.watch_in);
            self.watch_in = had;
            return 1;
        }
        return 0;
    }

    fn onReadable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Conn, user);
        if (self.closing) {
            self.watch_out = 0;
            return 0;
        }
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n > 0) {
                self.sess.feed(buf[0..@intCast(n)]);
                if (self.sess.state == .dead) break;
                continue;
            }
            if (n == 0) {
                // EOF: the server exited (or never exec'd).
                self.watch_out = 0;
                self.sess.markDead();
                return 0;
            }
            const err = std.posix.errno(@as(isize, @intCast(n)));
            if (err == .AGAIN) break;
            if (err == .INTR) continue;
            self.watch_out = 0;
            self.sess.markDead();
            return 0;
        }
        self.pumpWrite();
        if (self.sess.state == .dead) {
            self.watch_out = 0;
            return 0;
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_out = 0;
            self.sess.markDead();
            return 0;
        }
        return 1;
    }

    /// Drain stderr so the pipe never fills (a server whose stderr blocks
    /// stops serving), keeping its tail for the status line.
    fn onStderr(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Conn, user);
        if (self.closing) {
            self.watch_err = 0;
            return 0;
        }
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            self.tail.feed(buf[0..@intCast(n)]);
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_err = 0;
            return 0;
        }
        return 1;
    }

    /// Why the server stopped, for the status line: the session's own
    /// error, else the last stderr lines. Empty when there is nothing to
    /// say.
    pub fn failureText(self: *const Conn, out: []u8) []const u8 {
        const err = self.sess.errText();
        if (err.len > 0) {
            const n = @min(err.len, out.len);
            @memcpy(out[0..n], err[0..n]);
            return out[0..n];
        }
        return self.tail.lastLines(2, out);
    }

    pub fn dropWatches(self: *Conn) void {
        for ([_]*c_uint{ &self.watch_out, &self.watch_err, &self.watch_in }) |w| {
            if (w.* != 0) _ = c.g_source_remove(w.*);
            w.* = 0;
        }
        if (self.kill_timer != 0) {
            _ = c.g_source_remove(self.kill_timer);
            self.kill_timer = 0;
        }
        if (self.remove_idle != 0) {
            _ = c.g_source_remove(self.remove_idle);
            self.remove_idle = 0;
        }
    }

    pub fn destroy(self: *Conn) void {
        self.closing = true;
        self.dropWatches();
        var drop_link: ?*RemoteLink = null;
        if (self.remote) |*rm| {
            // Tell the daemon to take the server down (SIGTERM its
            // group). A dropped link needs nothing: client death kills
            // the channel and its child daemon-side.
            if (rm.open and rm.link.state == .up) {
                var hdr: [4]u8 = undefined;
                rm.link.io().queueFrame(.chan_close, wire.putChanHeader(&hdr, rm.chan)) catch {};
                rm.link.armWriteWatch();
            }
            rm.open = false;
            drop_link = rm.link;
            self.remote = null;
        }
        self.child.killHard();
        self.child.closePipes();
        if (self.child_watch) |watch| {
            watch.conn = null;
            self.child_watch = null;
            self.child.pid = -1;
        } else {
            // Only possible if installing the child watch failed before
            // this connection became visible to the main loop.
            self.child.reapBlocking();
        }
        self.sess.deinit();
        const a = registry.alloc;
        a.free(self.name);
        a.free(self.root);
        a.free(self.root_uri);
        a.destroy(self);
        // After the free: the idle-link scan must not see this Conn.
        if (drop_link) |link| registry.maybeDropLink(link);
    }
};

/// GLib owns this exact-pid child watch until reap, independently of its
/// nullable `Conn` back-pointer.
pub const LocalChildWatch = struct {
    pid: c.pid_t,
    conn: ?*Conn,
    source: c_uint = 0,

    pub fn create(pid: c.pid_t, conn: ?*Conn) ?*LocalChildWatch {
        const self = std.heap.c_allocator.create(LocalChildWatch) catch return null;
        self.* = .{ .pid = pid, .conn = conn };
        self.source = c.g_child_watch_add_full(
            c.G_PRIORITY_DEFAULT,
            pid,
            @ptrCast(&onExited),
            @ptrCast(self),
            @ptrCast(&free),
        );
        if (self.source == 0) {
            std.heap.c_allocator.destroy(self);
            return null;
        }
        return self;
    }

    fn onExited(pid: c.GPid, _: c_int, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(LocalChildWatch, user);
        self.source = 0;
        c.g_spawn_close_pid(pid);
        if (pid != self.pid) return;
        const cn = self.conn orelse return;
        self.conn = null;
        if (cn.child_watch != self) return;
        cn.child_watch = null;
        // A crashed leader may leave build tools in its process group.
        // While that group exists its id cannot be reused.
        _ = c.kill(-pid, c.SIGKILL);
        cn.child.pid = -1;
        if (!cn.closing) cn.sess.markDead();
    }

    fn free(user: ?*anyopaque) callconv(.c) void {
        std.heap.c_allocator.destroy(cast.userData(LocalChildWatch, user));
    }
};

// ======================================================================
// The registry
// ======================================================================

pub const Registry = struct {
    alloc: std.mem.Allocator = std.heap.c_allocator,
    conns: std.ArrayList(*Conn) = .empty,
    /// One per remote host with (past or present) LSP traffic; dead ones
    /// stay listed with their redial backoff.
    links: std.ArrayList(*RemoteLink) = .empty,
    /// Every live Manager, one per editor face.
    managers: std.ArrayList(*Manager) = .empty,

    pub fn register(self: *Registry, mgr: *Manager) void {
        self.managers.append(self.alloc, mgr) catch {};
    }

    pub fn unregister(self: *Registry, mgr: *Manager) void {
        for (self.managers.items, 0..) |m, i| {
            if (m != mgr) continue;
            _ = self.managers.swapRemove(i);
            break;
        }
        for (self.conns.items) |cn| {
            if (cn.last_mgr == mgr) cn.last_mgr = null;
        }
    }

    /// The face holding document tab `tab_id`.
    pub fn managerForTab(self: *Registry, tab_id: u64) ?*Manager {
        if (tab_id == 0) return null;
        for (self.managers.items) |m| {
            if (m.view.findTabById(tab_id) != null) return m;
        }
        return null;
    }

    fn servesConn(m: *Manager, cn: *Conn) bool {
        for (m.view.tabs.items) |t| {
            const st = t.lsp orelse continue;
            if (st.conn == cn) return true;
        }
        return false;
    }

    /// Where a server-initiated edit goes: the face that talked to the
    /// server last, else any face with a document on it.
    fn managerForEdit(self: *Registry, cn: *Conn) ?*Manager {
        if (cn.last_mgr) |m| return m;
        for (self.managers.items) |m| {
            if (servesConn(m, cn)) return m;
        }
        return null;
    }

    fn onNotification(self: *Registry, cn: *Conn, method: []const u8, params: std.json.Value) void {
        if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            const uri = switch (params) {
                .object => |o| switch (o.get("uri") orelse std.json.Value.null) {
                    .string => |s| s,
                    else => return,
                },
                else => return,
            };
            for (self.managers.items) |m| {
                if (m.tabForUri(cn, uri)) |tab| m.handleDiagnostics(cn, tab, params);
            }
            return;
        }
        if (std.mem.eql(u8, method, "window/logMessage")) {
            dbg("{s} log: {s}", .{ cn.name, messageText(params) });
            return;
        }
        const shows = std.mem.eql(u8, method, "window/showMessage") or
            std.mem.eql(u8, method, "window/showMessageRequest");
        const progress = std.mem.eql(u8, method, "$/progress");
        if (!shows and !progress) return;
        for (self.managers.items) |m| {
            if (!servesConn(m, cn)) continue;
            if (shows) m.serverMessage(cn, params) else m.view.updateStatus();
        }
    }

    fn onReady(self: *Registry, cn: *Conn) void {
        dbg("{s} ready (sync={s} completion={} hover={} definition={})", .{ cn.name, @tagName(cn.sess.caps.sync), cn.sess.caps.completion, cn.sess.caps.hover, cn.sess.caps.definition });
        for (self.managers.items) |m| m.onServerReady(cn);
        cn.pumpWrite();
    }

    fn onDead(self: *Registry, cn: *Conn) void {
        var tail_buf: [200]u8 = undefined;
        dbg("{s} dead: {s} / stderr: {s}", .{ cn.name, cn.sess.errText(), cn.tail.lastLines(2, &tail_buf) });
        cn.closing = true;
        for (self.managers.items) |m| m.onServerDead(cn);
        cn.refs = 0;
        cn.dropWatches();
        // Session callbacks are reached from fd, child-watch and link
        // frame callbacks (the link's may be iterating `conns`).
        // Removing/freeing the Conn inline would return through freed
        // user-data, so removal always waits for a fresh main-loop turn.
        // A remote one still owes the daemon its chan_close then.
        if (cn.remove_idle == 0)
            cn.remove_idle = c.g_idle_add(@ptrCast(&onRemoveDeadIdle), @ptrCast(cn));
    }

    /// A face went away; when it was the last one, every server and link
    /// goes now, since a quitting app never runs the grace timers.
    pub fn noteFaceGone(self: *Registry) void {
        if (self.managers.items.len > 0) return;
        // Pop-based: `Conn.destroy` rescans `conns` (and may drop an idle
        // link), so neither list may hold a freed pointer mid-loop.
        while (self.conns.pop()) |cn| cn.destroy();
        while (self.links.pop()) |link| link.destroyLink();
    }

    fn onRemoveDeadIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const cn = cast.userData(Conn, user);
        cn.remove_idle = 0;
        registry.removeConn(cn);
        return 0;
    }

    /// A live local server for (name, root).
    pub fn findConn(self: *Registry, name: []const u8, root: []const u8) ?*Conn {
        for (self.conns.items) |cn| {
            if (cn.closing or cn.sess.state == .dead) continue;
            if (cn.remote != null) continue;
            if (std.mem.eql(u8, cn.name, name) and std.mem.eql(u8, cn.root, root)) return cn;
        }
        return null;
    }

    /// A live remote server for (host, name, root). Dead sessions are
    /// skipped: reusing one would attach the tab to a server that will
    /// never answer, where a fresh lsp_open might succeed.
    pub fn findRemoteConn(self: *Registry, link: *RemoteLink, name: []const u8, root: []const u8) ?*Conn {
        for (self.conns.items) |cn| {
            if (cn.closing or cn.sess.state == .dead) continue;
            const rm = cn.remote orelse continue;
            if (rm.link != link) continue;
            if (std.mem.eql(u8, cn.name, name) and std.mem.eql(u8, cn.root, root)) return cn;
        }
        return null;
    }

    fn newConn(self: *Registry, name: []const u8, root: []const u8) ?*Conn {
        const cn = self.alloc.create(Conn) catch return null;
        const name_dup = self.alloc.dupe(u8, name) catch {
            self.alloc.destroy(cn);
            return null;
        };
        const root_dup = self.alloc.dupe(u8, root) catch {
            self.alloc.free(name_dup);
            self.alloc.destroy(cn);
            return null;
        };
        const root_uri = servers.pathToUri(self.alloc, root) catch {
            self.alloc.free(name_dup);
            self.alloc.free(root_dup);
            self.alloc.destroy(cn);
            return null;
        };
        cn.* = .{ .name = name_dup, .root = root_dup, .root_uri = root_uri, .sess = undefined };
        cn.sess = session.Session.init(self.alloc, cn.handler());
        return cn;
    }

    fn freeUnlisted(self: *Registry, cn: *Conn) void {
        cn.sess.deinit();
        self.alloc.free(cn.name);
        self.alloc.free(cn.root);
        self.alloc.free(cn.root_uri);
        self.alloc.destroy(cn);
    }

    /// Spawn a local server for `srv` rooted at `root` and start it.
    pub fn spawnConn(self: *Registry, srv: *const LspServer, root: []const u8) ?*Conn {
        const cn = self.newConn(srv.name, root) orelse return null;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        proc.splitArgs(self.alloc, srv.args, &argv) catch {};
        cn.child = proc.spawn(self.alloc, srv.command, argv.items, root) catch {
            // Nothing was watched or listed yet, so tear down by hand
            // rather than through `destroy` (which would kill a pid we
            // never got).
            self.freeUnlisted(cn);
            return null;
        };
        cn.child_watch = LocalChildWatch.create(cn.child.pid, cn) orelse {
            // No source can reap this child later, so finish the exact
            // child synchronously before discarding the failed spawn.
            cn.child.killHard();
            cn.child.closePipes();
            cn.child.reapBlocking();
            self.freeUnlisted(cn);
            return null;
        };
        cn.watch_out = c.g_unix_fd_add(
            cn.child.stdout,
            c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP,
            @ptrCast(&Conn.onReadable),
            @ptrCast(cn),
        );
        cn.watch_err = c.g_unix_fd_add(
            cn.child.stderr,
            c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP,
            @ptrCast(&Conn.onStderr),
            @ptrCast(cn),
        );
        self.conns.append(self.alloc, cn) catch {
            cn.destroy();
            return null;
        };
        cn.sess.start(cn.root_uri, c.getpid(), srv.init_options, srv.settings);
        cn.pumpWrite();
        return cn;
    }

    /// A server the daemon on `link`'s host spawned on channel `chan`.
    /// `init_options` and `settings` stay CLIENT concerns (they travel
    /// inside the protocol), so the config record the daemon's pick
    /// corresponds to is looked up here. pid 0 = "no processId": ours
    /// means nothing on the server's host, and clangd exits when the
    /// advertised pid does not exist.
    pub fn createRemoteConn(self: *Registry, link: *RemoteLink, name: []const u8, root: []const u8, chan: u32, conf: *const Config) ?*Conn {
        const cn = self.newConn(name, root) orelse return null;
        cn.remote = .{ .link = link, .chan = chan };
        self.conns.append(self.alloc, cn) catch {
            self.freeUnlisted(cn);
            return null;
        };
        var init_options: []const u8 = "";
        var settings: []const u8 = "";
        const list = conf.lspServerList(self.alloc) catch &.{};
        defer self.alloc.free(list);
        for (list) |srv| {
            if (std.mem.eql(u8, srv.name, name)) {
                init_options = srv.init_options;
                settings = srv.settings;
                break;
            }
        }
        cn.sess.start(cn.root_uri, 0, init_options, settings);
        cn.pumpWrite();
        return cn;
    }

    pub fn removeConn(self: *Registry, cn: *Conn) void {
        for (self.conns.items, 0..) |x, i| {
            if (x != cn) continue;
            _ = self.conns.orderedRemove(i);
            cn.destroy();
            return;
        }
    }

    /// Ask a server to stop, and SIGKILL it if it does not.
    pub fn shutdownConn(self: *Registry, cn: *Conn) void {
        _ = self;
        if (cn.closing) return;
        cn.sess.stop();
        cn.pumpWrite();
        cn.child.terminate();
        if (cn.kill_timer == 0)
            cn.kill_timer = c.g_timeout_add(SHUTDOWN_GRACE_MS, @ptrCast(&onKillTimer), @ptrCast(cn));
    }

    fn onKillTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const cn = cast.userData(Conn, user);
        cn.kill_timer = 0;
        if (cn.closing) return 0;
        registry.removeConn(cn);
        return 0;
    }

    /// Another tab already has `uri` open on `cn`: this copy must stay
    /// passive (a client may open a URI once).
    pub fn uriOpenElsewhere(self: *Registry, cn: *Conn, uri: []const u8, except_tab_id: u64) bool {
        for (self.managers.items) |m| {
            for (m.view.tabs.items) |t| {
                if (t.id == except_tab_id) continue;
                const st = t.lsp orelse continue;
                if (st.conn == cn and st.sync.open and std.mem.eql(u8, st.sync.uri, uri)) return true;
            }
        }
        return false;
    }

    /// The owner of `uri` on `cn` closed it: open the first passive copy
    /// with its own text.
    pub fn promotePassive(self: *Registry, cn: *Conn, uri: []const u8) void {
        for (self.managers.items) |m| {
            for (m.view.tabs.items) |t| {
                const st = t.lsp orelse continue;
                if (st.conn != cn or !st.passive or !std.mem.eql(u8, st.sync.uri, uri)) continue;
                st.passive = false;
                m.openDocument(t, st);
                return;
            }
        }
    }

    // ---- remote links ----------------------------------------------------

    pub fn findLink(self: *Registry, host: []const u8) ?*RemoteLink {
        for (self.links.items) |link| {
            if (std.mem.eql(u8, link.host, host)) return link;
        }
        return null;
    }

    /// The link for `host`: an existing one (redialed when it is dead and
    /// its backoff has passed), or a fresh dial.
    pub fn linkFor(self: *Registry, host: []const u8) ?*RemoteLink {
        if (self.findLink(host)) |link| {
            if (link.due(clock.nowMs())) link.dial();
            return link;
        }
        const link = self.alloc.create(RemoteLink) catch return null;
        const host_dup = self.alloc.dupe(u8, host) catch {
            self.alloc.destroy(link);
            return null;
        };
        link.* = .{ .host = host_dup };
        self.links.append(self.alloc, link) catch {
            self.alloc.free(host_dup);
            self.alloc.destroy(link);
            return null;
        };
        link.dial();
        return link;
    }

    /// The link came up: open everything that parked on it, and give
    /// every serverless document on that host, in every face, its server
    /// back.
    pub fn onLinkUp(self: *Registry, link: *RemoteLink) void {
        var i: usize = 0;
        while (i < link.waiting.items.len) : (i += 1) {
            const id = link.waiting.items[i];
            const m = self.managerForTab(id) orelse continue;
            const tab = m.view.findTabById(id) orelse continue;
            const conf = m.cfg() orelse continue;
            link.sendOpen(conf, tab);
        }
        link.waiting.clearRetainingCapacity();
        for (self.managers.items) |m| m.reattachHost(link.host);
    }

    /// Drop `link` when nothing references it any more — the remote
    /// mirror of "the last tab out shuts the server down".
    pub fn maybeDropLink(self: *Registry, link: *RemoteLink) void {
        if (link.state != .up) return;
        if (link.pending.items.len > 0 or link.waiting.items.len > 0) return;
        for (self.conns.items) |cn| {
            if (cn.remote) |*rm| {
                if (rm.link == link) return;
            }
        }
        for (self.links.items, 0..) |x, i| {
            if (x != link) continue;
            _ = self.links.orderedRemove(i);
            break;
        }
        dbg("link {s}: dropped (idle)", .{link.host});
        link.destroyLink();
    }
};

/// The one registry: servers and links outlive any single editor face.
pub var registry: Registry = .{};

/// A `window/showMessage` / `logMessage` params object's text.
pub fn messageText(params: std.json.Value) []const u8 {
    if (params != .object) return "";
    return switch (params.object.get("message") orelse std.json.Value.null) {
        .string => |s| s,
        else => "",
    };
}

// ======================================================================
// Tests
// ======================================================================

test "editorlsp conn: the failure text prefers the session's own error" {
    const t = std.testing;
    var cn = Conn{
        .name = @constCast(@as([]const u8, "fake")),
        .root = @constCast(@as([]const u8, "/w")),
        .root_uri = @constCast(@as([]const u8, "file:///w")),
        .sess = session.Session.init(t.allocator, undefined),
    };
    defer cn.sess.deinit();
    var out: [128]u8 = undefined;
    try t.expectEqualStrings("", cn.failureText(&out));
    cn.tail.feed("warming up\nfatal: no compile_commands.json\n");
    try t.expectEqualStrings("warming up | fatal: no compile_commands.json", cn.failureText(&out));
}

fn testWaitForChildReaped(pid: c.pid_t, timeout_ms: usize) bool {
    var elapsed: usize = 0;
    while (elapsed < timeout_ms) : (elapsed += 1) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        if (c.kill(pid, 0) < 0 and std.posix.errno(-1) == .SRCH) {
            var status: c_int = 0;
            const r = c.waitpid(pid, &status, c.WNOHANG);
            if (r < 0 and std.posix.errno(r) == .INTR) continue;
            return r < 0;
        }
        _ = c.usleep(1000);
    }
    return false;
}

fn testWaitForProcessGroupGone(pgid: c.pid_t, timeout_ms: usize) bool {
    var elapsed: usize = 0;
    while (elapsed < timeout_ms) : (elapsed += 1) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        if (c.kill(-pgid, 0) < 0 and std.posix.errno(-1) == .SRCH) return true;
        _ = c.usleep(1000);
    }
    return false;
}

fn testWaitForFakeServerReady(child: *proc.Child) bool {
    var buf: [64]u8 = undefined;
    var used: usize = 0;
    var elapsed: usize = 0;
    while (elapsed < 2000) : (elapsed += 1) {
        const n = c.read(child.stdout, buf[used..].ptr, buf.len - used);
        if (n > 0) {
            used += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..used], "ready") != null) return true;
        }
        _ = c.usleep(1000);
    }
    return false;
}

fn testConn(name: []const u8, root: []const u8) Conn {
    return .{
        .name = @constCast(name),
        .root = @constCast(root),
        .root_uri = @constCast(@as([]const u8, "file:///workspace")),
        .sess = undefined,
    };
}

test "editorlsp conn: the pool rejects a dead connection and selects its replacement" {
    const t = std.testing;
    var reg = Registry{ .alloc = t.allocator };
    defer reg.conns.deinit(t.allocator);

    var dead = testConn("fake", "/workspace");
    dead.sess = session.Session.init(t.allocator, dead.handler());
    defer dead.sess.deinit();
    dead.sess.state = .dead;
    try reg.conns.append(t.allocator, &dead);
    try t.expect(reg.findConn("fake", "/workspace") == null);

    var replacement = testConn("fake", "/workspace");
    replacement.sess = session.Session.init(t.allocator, replacement.handler());
    defer replacement.sess.deinit();
    replacement.sess.state = .initializing;
    try reg.conns.append(t.allocator, &replacement);
    try t.expectEqual(&replacement, reg.findConn("fake", "/workspace").?);
    // Another root is another server.
    try t.expect(reg.findConn("fake", "/elsewhere") == null);
}

test "editorlsp conn: the child watch reaps a crashed fake server before restart" {
    const t = std.testing;
    var crashed = try proc.spawn(t.allocator, "sh", &.{ "-c", "exit 23" }, "/");
    const crashed_pid = crashed.pid;
    const crashed_watch = LocalChildWatch.create(crashed_pid, null);
    try t.expect(crashed_watch != null);
    if (crashed_watch == null) {
        crashed.killHard();
        crashed.closePipes();
        crashed.reapBlocking();
        return;
    }
    crashed.closePipes();
    try t.expect(testWaitForChildReaped(crashed_pid, 2000));

    var replacement = try proc.spawn(
        t.allocator,
        "sh",
        &.{ "-c", "trap '' TERM; printf 'ready\\n'; while :; do sleep 1; done" },
        "/",
    );
    const replacement_pid = replacement.pid;
    const replacement_watch = LocalChildWatch.create(replacement_pid, null);
    try t.expect(replacement_watch != null);
    if (replacement_watch == null) {
        replacement.killHard();
        replacement.closePipes();
        replacement.reapBlocking();
        return;
    }
    try t.expect(testWaitForFakeServerReady(&replacement));
    replacement.killHard();
    replacement.closePipes();
    try t.expect(testWaitForChildReaped(replacement_pid, 2000));
    try t.expect(testWaitForProcessGroupGone(replacement_pid, 2000));
}

test "editorlsp conn: shutdown keeps the reap watch after the connection is gone" {
    const t = std.testing;
    var child = try proc.spawn(
        t.allocator,
        "sh",
        &.{ "-c", "trap '' TERM; printf 'ready\\n'; while :; do sleep 1; done" },
        "/",
    );
    const pid = child.pid;
    var child_owned = true;
    defer if (child_owned) {
        child.killHard();
        child.closePipes();
        child.reapBlocking();
    };
    try t.expect(testWaitForFakeServerReady(&child));

    // `destroy` frees through the global registry's allocator.
    const a = registry.alloc;
    const cn = try a.create(Conn);
    cn.* = .{
        .name = try a.dupe(u8, "fake"),
        .root = try a.dupe(u8, "/workspace"),
        .root_uri = try a.dupe(u8, "file:///workspace"),
        .child = child,
        .sess = undefined,
    };
    child_owned = false;
    cn.sess = session.Session.init(a, cn.handler());
    cn.child_watch = LocalChildWatch.create(pid, cn);
    try t.expect(cn.child_watch != null);
    if (cn.child_watch == null) {
        cn.destroy();
        return;
    }
    try registry.conns.append(a, cn);

    cn.child.terminate();
    var elapsed: usize = 0;
    while (elapsed < 30) : (elapsed += 1) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        _ = c.usleep(1000);
    }
    try t.expect(c.kill(pid, 0) == 0);

    // The dead-session callback schedules this idle instead of freeing
    // the Conn on its own stack; after it runs, only the detached
    // child-watch record remains to observe and reap the SIGKILLed child.
    cn.closing = true;
    cn.remove_idle = c.g_idle_add(@ptrCast(&Registry.onRemoveDeadIdle), @ptrCast(cn));
    try t.expect(cn.remove_idle != 0);
    var idle_spins: usize = 0;
    while (registry.conns.items.len > 0 and idle_spins < 100) : (idle_spins += 1) {
        _ = c.g_main_context_iteration(null, 0);
        _ = c.usleep(1000);
    }
    try t.expectEqual(@as(usize, 0), registry.conns.items.len);
    try t.expect(testWaitForChildReaped(pid, 2000));
    try t.expect(testWaitForProcessGroupGone(pid, 2000));
}
