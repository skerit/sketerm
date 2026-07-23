//! File-browser pane face (phases 3+4 of docs/filebrowser-roadmap.md).
//!
//! A BrowserView rides a regular terminal Pane as its second face:
//! the pane keeps its shell session (that IS "Open Terminal Here" —
//! one toggle away), the browser renders on top. Internal tab strip
//! per pane (the Nemo per-split-tabs model): browser tabs are cheap
//! VIEW state; the heavy session state stays with the pane.
//!
//! Remote (phase 4): every tab references a shared per-view HostConn
//! (null host = local daemon, "user@box" = SSH, "udp:box" = UDP —
//! same host strings as terminals). Remote connects run on a worker
//! thread with a g_idle_add handback, so a dead host degrades ONE
//! tab with an error and never stalls the GUI. Cross-host copy and
//! remote-file-open ride fstransfer.Xfer (client-mediated, staged
//! .skpart resume, both-ends hash verify).
//!
//! Async by construction: non-blocking mux connections watched via
//! g_unix_fd_add — the GLib loop is NEVER blocked on a reply.
//! Listings are subscriptions (fs_op open_view): pushed fs_delta
//! frames keep every visible directory live, including tree-expanded
//! subdirectories (expanded set == watch set).

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const fsserve = @import("../mux/fsserve.zig");
const fstransfer = @import("../ipc/fstransfer.zig");
const input = @import("input.zig");
const Pane = @import("pane.zig").Pane;

/// One owned directory entry (strings owned by the Dir's allocator).
const Entry = struct {
    name: []u8,
    kind: []u8,
    size: u64,
    mode: u32,
    mtime_ms: i64,
    target: ?[]u8,
    tdir: bool,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        if (self.target) |t| allocator.free(t);
    }
};

/// Wire mirror of the fs_reply fields the browser consumes.
const WireEntry = struct {
    name: []const u8 = "",
    kind: []const u8 = "",
    size: u64 = 0,
    mode: u32 = 0,
    mtime_ms: i64 = 0,
    target: ?[]const u8 = null,
    tdir: bool = false,
};

const WireReply = struct {
    req: u32 = 0,
    ok: bool = false,
    @"error": []const u8 = "",
    path: []const u8 = "",
    entries: []WireEntry = &.{},
    more: bool = false,
    truncated: bool = false,
    job: u64 = 0,
};

const WireDelta = struct {
    view: u32 = 0,
    gone: bool = false,
    resync: bool = false,
    changes: []struct {
        op: []const u8 = "",
        name: []const u8 = "",
        entry: ?WireEntry = null,
    } = &.{},
};

const WireJobEv = struct {
    job: u64 = 0,
    ev: []const u8 = "",
    state: []const u8 = "",
    done: u64 = 0,
    total: u64 = 0,
    message: []const u8 = "",
};

/// A parsed location spec. Bare "/path" keeps the CURRENT host
/// (current = local when there is no current tab); "local:/path"
/// forces local; "host:/path", "user@host:/path" and "udp:host:/path"
/// use the terminal host-string convention.
pub const Loc = struct {
    /// null = local, .current = keep the tab's host.
    host: ?[]const u8,
    current_host: bool,
    path: []const u8,
};

pub fn parseSpec(spec: []const u8) Loc {
    if (spec.len == 0) return .{ .host = null, .current_host = false, .path = "/" };
    if (spec[0] == '/') return .{ .host = null, .current_host = true, .path = spec };
    if (std.mem.indexOf(u8, spec, ":/")) |i| {
        const host = spec[0..i];
        const path = spec[i + 1 ..];
        if (host.len == 0 or std.mem.eql(u8, host, "local"))
            return .{ .host = null, .current_host = false, .path = path };
        return .{ .host = host, .current_host = false, .path = path };
    }
    return .{ .host = null, .current_host = true, .path = spec };
}

fn hostEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// One shared connection to a host's daemon. Referenced by tabs and
/// transfers; owned by the BrowserView.
const HostConn = struct {
    view: *BrowserView,
    /// null = local; otherwise the terminal host-string form.
    host: ?[]u8,
    conn: muxclient.Conn = undefined,
    state: enum { connecting, ready, dead } = .connecting,
    watch_id: c.guint = 0,
    /// Owning view died while the connect thread was in flight; the
    /// idle handback frees this struct.
    orphaned: bool = false,

    fn label(self: *const HostConn) []const u8 {
        return self.host orelse "local";
    }

    fn destroy(self: *HostConn, allocator: std.mem.Allocator) void {
        if (self.watch_id != 0) _ = c.g_source_remove(self.watch_id);
        if (self.state == .ready) self.conn.deinit();
        if (self.host) |h| allocator.free(h);
        allocator.destroy(self);
    }
};

/// Heap context handed to the connect worker thread. The thread only
/// touches this struct (its own allocator for the Conn); the idle
/// handback runs on the main thread.
const ConnectCtx = struct {
    allocator: std.mem.Allocator,
    hc: *HostConn,
    host: []u8,
    result: ?muxclient.Conn = null,
};

/// One live (subscribed) directory: a browser tab's root, or an
/// expanded subdirectory.
const Dir = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    view_id: u32,
    entries: std.ArrayList(Entry) = .empty,
    loaded: bool = false,
    gone: bool = false,

    fn deinit(self: *Dir) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn find(self: *Dir, name: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }

    fn own(self: *Dir, we: WireEntry) ?Entry {
        const a = self.allocator;
        const name = a.dupe(u8, we.name) catch return null;
        const kind = a.dupe(u8, we.kind) catch {
            a.free(name);
            return null;
        };
        var tgt: ?[]u8 = null;
        if (we.target) |t| tgt = a.dupe(u8, t) catch null;
        return .{
            .name = name,
            .kind = kind,
            .size = we.size,
            .mode = we.mode,
            .mtime_ms = we.mtime_ms,
            .target = tgt,
            .tdir = we.tdir,
        };
    }

    fn upsert(self: *Dir, we: WireEntry) void {
        if (self.find(we.name)) |i| {
            var old = self.entries.items[i];
            old.deinit(self.allocator);
            if (self.own(we)) |e| {
                self.entries.items[i] = e;
            } else {
                _ = self.entries.orderedRemove(i);
            }
        } else if (self.own(we)) |e| {
            self.entries.append(self.allocator, e) catch {
                var ec = e;
                ec.deinit(self.allocator);
                return;
            };
        }
        self.sort();
    }

    fn del(self: *Dir, name: []const u8) void {
        if (self.find(name)) |i| {
            var e = self.entries.orderedRemove(i);
            e.deinit(self.allocator);
        }
    }

    fn sort(self: *Dir) void {
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.tdir != b.tdir) return a.tdir;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lt);
    }
};

/// One internal browser tab.
const BTab = struct {
    view: *BrowserView,
    hc: *HostConn,
    root: *Dir,
    /// Expanded subdirectories (tree-expand-inline), each its own
    /// live view. Flat list; nesting is reconstructed by path at
    /// render time.
    subdirs: std.ArrayList(*Dir) = .empty,
    /// History entries are SPEC strings (host-qualified), so back/
    /// forward can cross hosts.
    back: std.ArrayList([]u8) = .empty,
    fwd: std.ArrayList([]u8) = .empty,
    page: *c.GtkWidget,
    listbox: *c.GtkListBox,
    tab_label: *c.GtkLabel,

    fn subdirByPath(self: *BTab, path: []const u8) ?*Dir {
        for (self.subdirs.items) |d| {
            if (std.mem.eql(u8, d.path, path)) return d;
        }
        return null;
    }

    fn dirByView(self: *BTab, view_id: u32) ?*Dir {
        if (self.root.view_id == view_id) return self.root;
        for (self.subdirs.items) |d| {
            if (d.view_id == view_id) return d;
        }
        return null;
    }

    fn dropSubdirsUnder(self: *BTab, prefix: []const u8) void {
        var i: usize = 0;
        while (i < self.subdirs.items.len) {
            const d = self.subdirs.items[i];
            const under = std.mem.startsWith(u8, d.path, prefix) and
                (d.path.len == prefix.len or d.path[prefix.len] == '/');
            if (under) {
                self.view.closeViewOf(self.hc, d);
                _ = self.subdirs.swapRemove(i);
                d.deinit();
            } else i += 1;
        }
    }

    /// The host-qualified spec for this tab's current location.
    fn spec(self: *BTab, buf: []u8) []const u8 {
        if (self.hc.host) |h| {
            return std.fmt.bufPrint(buf, "{s}:{s}", .{ h, self.root.path }) catch self.root.path;
        }
        return self.root.path;
    }

    fn deinit(self: *BTab) void {
        const a = self.view.allocator;
        self.view.closeViewOf(self.hc, self.root);
        for (self.subdirs.items) |d| {
            self.view.closeViewOf(self.hc, d);
            d.deinit();
        }
        self.subdirs.deinit(a);
        self.root.deinit();
        for (self.back.items) |p| a.free(p);
        self.back.deinit(a);
        for (self.fwd.items) |p| a.free(p);
        self.fwd.deinit(a);
        a.destroy(self);
    }
};

/// In-flight listing request (open_view or refresh `list`). `sent`
/// is false while the tab's host is still connecting; the connect
/// handback flushes unsent requests.
const Pending = struct {
    req: u32,
    tab: *BTab,
    /// Accumulating target; entries replace dir.entries when the
    /// chunk run ends.
    dir: *Dir,
    op: enum { open_view, list },
    sent: bool = false,
    staged: std.ArrayList(Entry) = .empty,
};

/// A daemon-side job (copy/delete_tree) started by this view, shown
/// in the jobs panel.
const JobRow = struct {
    hc: *HostConn,
    job: u64,
    label: []u8,
    done: u64 = 0,
    total: u64 = 0,
    state: enum { running, paused, finished, failed, canceled } = .running,

    fn terminal(self: *const JobRow) bool {
        return self.state == .finished or self.state == .failed or self.state == .canceled;
    }
};

/// A job-start request awaiting its reply (which carries the id).
const PendingJob = struct {
    req: u32,
    hc: *HostConn,
    label: []u8,
};

/// One client-mediated cross-host transfer in flight.
const ActiveTransfer = struct {
    x: *fstransfer.Xfer,
    src_hc: *HostConn,
    dst_hc: *HostConn,
    label: []u8,
    /// Launch the local destination file when the transfer lands
    /// (remote-file open-with-default path).
    open_when_done: bool = false,
};

pub const BrowserView = struct {
    allocator: std.mem.Allocator,
    pane: *Pane,
    conns: std.ArrayList(*HostConn) = .empty,
    next_req: u32 = 1,
    next_view: u32 = 1,
    tabs: std.ArrayList(*BTab) = .empty,
    pending: std.ArrayList(*Pending) = .empty,
    pending_jobs: std.ArrayList(*PendingJob) = .empty,
    jobs: std.ArrayList(*JobRow) = .empty,
    transfers: std.ArrayList(*ActiveTransfer) = .empty,
    show_hidden: bool = false,

    root_box: *c.GtkWidget = undefined,
    notebook: *c.GtkNotebook = undefined,
    path_entry: *c.GtkEntry = undefined,
    status_label: *c.GtkLabel = undefined,
    jobs_box: *c.GtkWidget = undefined,
    /// Copy-source for the context menu's Copy/Paste (owned).
    clip_host: ?[]u8 = null,
    clip_path: ?[]u8 = null,

    /// Create a browser face on `pane`, starting at `start_spec`
    /// (a path or host-qualified spec; null/relative = $HOME).
    pub fn attach(allocator: std.mem.Allocator, pane: *Pane, start_spec: ?[]const u8) !*BrowserView {
        const self = try allocator.create(BrowserView);
        self.* = .{ .allocator = allocator, .pane = pane };

        self.buildUi();
        pane.attachBrowser(self.root_box, @ptrCast(self), destroyCb);

        const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/";
        if (start_spec) |sp| {
            const loc = parseSpec(sp);
            const path = if (loc.path.len > 0 and loc.path[0] == '/') loc.path else home;
            _ = self.newTab(loc.host, path);
        } else {
            _ = self.newTab(null, home);
        }
        return self;
    }

    fn destroyCb(ctx: *anyopaque) void {
        const self: *BrowserView = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// The BrowserView riding `pane`, if any. Safe cast: browser_ctx
    /// is only ever set by attach().
    pub fn fromPane(pane: *Pane) ?*BrowserView {
        const ctx = pane.browser_ctx orelse return null;
        return @ptrCast(@alignCast(ctx));
    }

    /// Internal tab location specs in notebook order (layout
    /// persistence; host-qualified for remote tabs).
    pub fn tabPaths(self: *BrowserView, arena: std.mem.Allocator) ![]const []const u8 {
        const out = try arena.alloc([]const u8, self.tabs.items.len);
        for (self.tabs.items, 0..) |t, i| {
            var buf: [4200]u8 = undefined;
            out[i] = try arena.dupe(u8, t.spec(&buf));
        }
        return out;
    }

    pub fn deinit(self: *BrowserView) void {
        for (self.transfers.items) |t| {
            t.x.deinit();
            self.allocator.free(t.label);
            self.allocator.destroy(t);
        }
        self.transfers.deinit(self.allocator);
        for (self.tabs.items) |t| t.deinit();
        self.tabs.deinit(self.allocator);
        for (self.pending.items) |p| {
            for (p.staged.items) |*e| e.deinit(self.allocator);
            p.staged.deinit(self.allocator);
            self.allocator.destroy(p);
        }
        self.pending.deinit(self.allocator);
        for (self.pending_jobs.items) |pj| {
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
        }
        self.pending_jobs.deinit(self.allocator);
        for (self.jobs.items) |j| {
            self.allocator.free(j.label);
            self.allocator.destroy(j);
        }
        self.jobs.deinit(self.allocator);
        for (self.conns.items) |hc| {
            if (hc.state == .connecting) {
                // A worker thread still owns the connect; the idle
                // handback frees the struct.
                hc.orphaned = true;
            } else {
                hc.destroy(self.allocator);
            }
        }
        self.conns.deinit(self.allocator);
        if (self.clip_host) |s| self.allocator.free(s);
        if (self.clip_path) |s| self.allocator.free(s);
        self.allocator.destroy(self);
    }

    // ── host connections ────────────────────────────────────────

    /// The live (ready or connecting) connection for `host`, creating
    /// one when needed. Dead connections are skipped, so navigating
    /// again after a drop reconnects. null on immediate failure.
    fn hostConnFor(self: *BrowserView, host: ?[]const u8) ?*HostConn {
        for (self.conns.items) |hc| {
            if (hc.state != .dead and hostEq(hc.host, host)) return hc;
        }
        const hc = self.allocator.create(HostConn) catch return null;
        hc.* = .{
            .view = self,
            .host = if (host) |h| (self.allocator.dupe(u8, h) catch {
                self.allocator.destroy(hc);
                return null;
            }) else null,
        };
        self.conns.append(self.allocator, hc) catch {
            if (hc.host) |h| self.allocator.free(h);
            self.allocator.destroy(hc);
            return null;
        };

        if (host == null) {
            // Local: synchronous autostart connect (fast; existing
            // GUI behavior for local panes).
            hc.conn = muxclient.Conn.connectLocalAutostart(self.allocator) catch {
                hc.state = .dead;
                self.setStatus("local daemon unreachable");
                return hc;
            };
            self.wireReady(hc);
            return hc;
        }

        // Remote: worker thread; Conn buffers use the C allocator
        // (thread-safe) since the connect runs off-main.
        const ctx = self.allocator.create(ConnectCtx) catch return hc;
        ctx.* = .{
            .allocator = self.allocator,
            .hc = hc,
            .host = self.allocator.dupe(u8, host.?) catch {
                self.allocator.destroy(ctx);
                return hc;
            },
        };
        const th = std.Thread.spawn(.{}, connectThreadMain, .{ctx}) catch {
            self.allocator.free(ctx.host);
            self.allocator.destroy(ctx);
            hc.state = .dead;
            self.setStatusFmt("cannot start connection to {s}", .{host.?});
            return hc;
        };
        th.detach();
        self.setStatusFmt("connecting to {s}…", .{host.?});
        return hc;
    }

    fn connectThreadMain(ctx: *ConnectCtx) void {
        const alloc = std.heap.c_allocator;
        const result = if (std.mem.startsWith(u8, ctx.host, "udp:"))
            muxclient.Conn.connectUdp(alloc, ctx.host[4..], null)
        else
            muxclient.Conn.connectSsh(alloc, ctx.host);
        if (result) |conn| {
            ctx.result = conn;
        } else |_| {
            ctx.result = null;
        }
        _ = c.g_idle_add(@ptrCast(&onConnectIdle), @ptrCast(ctx));
    }

    fn onConnectIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const ctx: *ConnectCtx = @ptrCast(@alignCast(user.?));
        const hc = ctx.hc;
        const allocator = ctx.allocator;
        defer {
            allocator.free(ctx.host);
            allocator.destroy(ctx);
        }
        if (hc.orphaned) {
            if (ctx.result) |conn| {
                var mut = conn;
                mut.deinit();
            }
            if (hc.host) |h| allocator.free(h);
            allocator.destroy(hc);
            return 0;
        }
        const view = hc.view;
        if (ctx.result) |conn| {
            hc.conn = conn;
            view.wireReady(hc);
            view.setStatusFmt("connected to {s}", .{hc.label()});
        } else {
            hc.state = .dead;
            view.setStatusFmt("cannot connect to {s}", .{hc.label()});
        }
        return 0;
    }

    /// Make a freshly connected HostConn live: non-blocking fd, GLib
    /// watch, and flush every request that queued while connecting.
    fn wireReady(self: *BrowserView, hc: *HostConn) void {
        hc.conn.setNonBlocking();
        hc.state = .ready;
        hc.watch_id = c.g_unix_fd_add(
            hc.conn.fd,
            c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&onFdReadable),
            @ptrCast(hc),
        );
        for (self.pending.items) |p| {
            if (p.sent or p.tab.hc != hc) continue;
            self.sendListingOp(p);
        }
    }

    /// Connection died: fail its transfers FIRST (they hold *Conn),
    /// then release the socket. Tabs keep referencing the dead
    /// HostConn; navigating again reconnects.
    fn hostDied(self: *BrowserView, hc: *HostConn) void {
        var i: usize = 0;
        while (i < self.transfers.items.len) {
            const t = self.transfers.items[i];
            if (t.src_hc == hc or t.dst_hc == hc) {
                self.setStatusFmt("transfer failed: connection to {s} lost", .{hc.label()});
                t.x.deinit();
                self.allocator.free(t.label);
                self.allocator.destroy(t);
                _ = self.transfers.orderedRemove(i);
            } else i += 1;
        }
        hc.watch_id = 0;
        hc.conn.deinit();
        hc.state = .dead;
        self.setStatusFmt("connection to {s} lost — navigate to reconnect", .{hc.label()});
        self.renderJobs();
    }

    // ── wire plumbing ───────────────────────────────────────────

    fn sendOp(self: *BrowserView, hc: *HostConn, args: anytype) void {
        if (hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{hc.label()});
            return;
        }
        hc.conn.sendJson(.fs_op, args) catch self.setStatus("daemon connection lost");
    }

    fn closeViewOf(self: *BrowserView, hc: *HostConn, dir: *Dir) void {
        _ = self;
        if (dir.view_id == 0 or hc.state != .ready) return;
        hc.conn.sendJson(.fs_op, .{
            .req = @as(u32, 0),
            .op = "close_view",
            .view = dir.view_id,
        }) catch {};
    }

    fn sendListingOp(self: *BrowserView, p: *Pending) void {
        p.sent = true;
        switch (p.op) {
            .open_view => self.sendOp(p.tab.hc, .{
                .req = p.req,
                .op = "open_view",
                .path = p.dir.path,
                .view = p.dir.view_id,
            }),
            .list => self.sendOp(p.tab.hc, .{
                .req = p.req,
                .op = "list",
                .path = p.dir.path,
            }),
        }
    }

    /// Subscribe a directory and start collecting its listing. When
    /// the tab's host is still connecting, the request queues and the
    /// connect handback sends it.
    fn openDir(self: *BrowserView, tab: *BTab, dir: *Dir) void {
        self.queueListing(tab, dir, .open_view);
    }

    /// Refetch a live dir's entries without dropping its view (the
    /// resync path): one-shot `list` reusing the Pending accumulator.
    fn refreshDir(self: *BrowserView, tab: *BTab, dir: *Dir) void {
        self.queueListing(tab, dir, .list);
    }

    fn queueListing(self: *BrowserView, tab: *BTab, dir: *Dir, op: @FieldType(Pending, "op")) void {
        const req = self.nextReq();
        const p = self.allocator.create(Pending) catch return;
        p.* = .{ .req = req, .tab = tab, .dir = dir, .op = op };
        self.pending.append(self.allocator, p) catch {
            self.allocator.destroy(p);
            return;
        };
        if (tab.hc.state == .ready) {
            self.sendListingOp(p);
        } else if (tab.hc.state == .dead) {
            self.setStatusFmt("not connected to {s}", .{tab.hc.label()});
        }
    }

    fn nextReq(self: *BrowserView) u32 {
        const r = self.next_req;
        self.next_req +%= 1;
        if (self.next_req == 0) self.next_req = 1;
        return r;
    }

    fn onFdReadable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        _ = fd;
        const hc: *HostConn = @ptrCast(@alignCast(user.?));
        const self = hc.view;
        if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
            self.hostDied(hc);
            return 0; // remove source
        }
        if (!hc.conn.fillAvailable()) {
            self.hostDied(hc);
            return 0;
        }
        var dirty = false;
        var xfer_touched = false;
        while (hc.conn.takeFrame() catch null) |f| {
            // The frame payload belongs to the CONN's allocator (the
            // C allocator for thread-connected remotes), not ours.
            defer f.deinit(hc.conn.allocator);
            if (self.feedTransfers(hc, f.ftype, f.payload)) {
                xfer_touched = true;
                continue;
            }
            switch (f.ftype) {
                .fs_reply => {
                    if (self.onReply(hc, f.payload)) dirty = true;
                },
                .fs_delta => {
                    if (self.onDelta(hc, f.payload)) dirty = true;
                },
                .fs_job => self.onJobEvent(hc, f.payload),
                else => {},
            }
        }
        if (xfer_touched) self.reapTransfers();
        if (xfer_touched) self.renderJobs();
        if (dirty) self.renderCurrent();
        return 1;
    }

    // ── transfers (cross-host, client-mediated) ─────────────────

    fn feedTransfers(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
        for (self.transfers.items) |t| {
            if (t.src_hc == hc and t.x.feed(.src, ftype, payload)) return true;
            if (t.dst_hc == hc and t.x.feed(.dst, ftype, payload)) return true;
        }
        return false;
    }

    /// Finish (and drop) transfers that reached a terminal state.
    fn reapTransfers(self: *BrowserView) void {
        var i: usize = 0;
        while (i < self.transfers.items.len) {
            const t = self.transfers.items[i];
            if (!t.x.isTerminal()) {
                i += 1;
                continue;
            }
            if (t.x.ok()) {
                self.setStatusFmt("transfer done: {s}", .{t.label});
                if (t.open_when_done) launchLocal(t.x.dst_root);
            } else if (t.x.state == .canceled) {
                self.setStatusFmt("transfer canceled: {s}", .{t.label});
            } else {
                self.setStatusFmt("transfer failed: {s} ({s})", .{ t.label, t.x.errMsg() });
            }
            t.x.deinit();
            self.allocator.free(t.label);
            self.allocator.destroy(t);
            _ = self.transfers.orderedRemove(i);
        }
    }

    fn startTransfer(
        self: *BrowserView,
        src_hc: *HostConn,
        src_path: []const u8,
        dst_hc: *HostConn,
        dst_path: []const u8,
        open_when_done: bool,
    ) void {
        if (src_hc.state != .ready or dst_hc.state != .ready) {
            self.setStatus("both hosts must be connected — retry in a moment");
            return;
        }
        const x = fstransfer.Xfer.init(
            self.allocator,
            &src_hc.conn,
            &dst_hc.conn,
            &self.next_req,
            src_path,
            dst_path,
            true,
        ) catch return;
        const label = std.fmt.allocPrint(self.allocator, "{s}:{s} → {s}", .{
            src_hc.label(), std.fs.path.basename(src_path), dst_hc.label(),
        }) catch {
            x.deinit();
            return;
        };
        const t = self.allocator.create(ActiveTransfer) catch {
            x.deinit();
            self.allocator.free(label);
            return;
        };
        t.* = .{
            .x = x,
            .src_hc = src_hc,
            .dst_hc = dst_hc,
            .label = label,
            .open_when_done = open_when_done,
        };
        self.transfers.append(self.allocator, t) catch {
            x.deinit();
            self.allocator.free(label);
            self.allocator.destroy(t);
            return;
        };
        x.start();
        self.setStatusFmt("transfer started: {s}", .{label});
        self.renderJobs();
    }

    /// Download a remote file into the local open-cache and launch
    /// the default app on it when done.
    fn openRemoteFile(self: *BrowserView, tab: *BTab, path: []const u8) void {
        const local = self.hostConnFor(null) orelse return;
        if (local.state != .ready) {
            self.setStatus("local daemon unreachable");
            return;
        }
        const cache_root = c.g_get_user_cache_dir();
        var dirbuf: [4096:0]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dirbuf, "{s}/sketerm/fsopen", .{cache_root}) catch return;
        _ = c.g_mkdir_with_parents(dir.ptr, 0o700);
        var h = std.hash.Wyhash.init(0);
        if (tab.hc.host) |hs| h.update(hs);
        h.update(path);
        var dstbuf: [4600]u8 = undefined;
        const dst = std.fmt.bufPrint(&dstbuf, "{s}/{x:0>16}-{s}", .{
            dir, h.final(), std.fs.path.basename(path),
        }) catch return;
        self.startTransfer(tab.hc, path, local, dst, true);
    }

    // ── daemon jobs (same-host copy / recursive delete) ─────────

    fn startDaemonJob(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8) void {
        if (hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{hc.label()});
            return;
        }
        const req = self.nextReq();
        const pj = self.allocator.create(PendingJob) catch return;
        pj.* = .{
            .req = req,
            .hc = hc,
            .label = self.allocator.dupe(u8, label) catch {
                self.allocator.destroy(pj);
                return;
            },
        };
        self.pending_jobs.append(self.allocator, pj) catch {
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
            return;
        };
        if (to.len > 0) {
            self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .@"resume" = false });
        } else {
            self.sendOp(hc, .{ .req = req, .op = op, .path = path });
        }
    }

    /// Job progress / completion → jobs panel + status bar (deltas
    /// already update the listing itself when the result lands).
    fn onJobEvent(self: *BrowserView, hc: *HostConn, payload: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const e = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        const row = for (self.jobs.items) |j| {
            if (j.hc == hc and j.job == e.job) break j;
        } else return;
        if (std.mem.eql(u8, e.ev, "progress")) {
            row.done = e.done;
            row.total = e.total;
            if (row.state == .running) self.setStatusFmt("{s}: {d} / {d} MB", .{
                row.label, e.done >> 20, e.total >> 20,
            });
        } else if (std.mem.eql(u8, e.ev, "done")) {
            row.state = .finished;
            row.done = e.done;
            row.total = e.total;
            self.setStatusFmt("done: {s}", .{row.label});
        } else if (std.mem.eql(u8, e.ev, "error")) {
            row.state = .failed;
            self.setStatusFmt("job failed: {s} ({s})", .{ row.label, e.message });
        } else if (std.mem.eql(u8, e.ev, "canceled")) {
            row.state = .canceled;
            self.setStatusFmt("canceled: {s}", .{row.label});
        }
        self.renderJobs();
    }

    fn onReply(self: *BrowserView, hc: *HostConn, payload: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        if (rep.req == 0) return false;

        // Listing chunk run?
        for (self.pending.items, 0..) |p, i| {
            if (p.req != rep.req) continue;
            if (!rep.ok) {
                self.setStatusFmt("cannot open: {s}", .{rep.@"error"});
                self.dropPending(i);
                return true;
            }
            for (rep.entries) |we| {
                if (p.dir.own(we)) |e| p.staged.append(self.allocator, e) catch {};
            }
            if (!rep.more) {
                for (p.dir.entries.items) |*e| e.deinit(self.allocator);
                p.dir.entries.deinit(self.allocator);
                p.dir.entries = p.staged;
                p.staged = .empty;
                p.dir.loaded = true;
                p.dir.sort();
                if (rep.truncated) self.setStatus("listing truncated (very large directory)");
                self.dropPending(i);
                return true;
            }
            return false;
        }
        // Job start reply?
        for (self.pending_jobs.items, 0..) |pj, i| {
            if (pj.req != rep.req) continue;
            if (rep.ok and rep.job != 0) {
                const row = self.allocator.create(JobRow) catch break;
                row.* = .{ .hc = hc, .job = rep.job, .label = pj.label };
                self.jobs.append(self.allocator, row) catch {
                    self.allocator.destroy(row);
                    self.allocator.free(pj.label);
                    _ = self.pending_jobs.orderedRemove(i);
                    self.allocator.destroy(pj);
                    return false;
                };
                _ = self.pending_jobs.orderedRemove(i);
                self.allocator.destroy(pj);
                self.renderJobs();
            } else {
                self.setStatusFmt("operation failed: {s}", .{rep.@"error"});
                self.allocator.free(pj.label);
                _ = self.pending_jobs.orderedRemove(i);
                self.allocator.destroy(pj);
            }
            return false;
        }
        // Plain op reply (mkdir/rename/delete fired from the UI).
        if (!rep.ok) {
            self.setStatusFmt("operation failed: {s}", .{rep.@"error"});
            return false;
        }
        return false;
    }

    fn dropPending(self: *BrowserView, i: usize) void {
        const p = self.pending.swapRemove(i);
        for (p.staged.items) |*e| e.deinit(self.allocator);
        p.staged.deinit(self.allocator);
        self.allocator.destroy(p);
    }

    fn onDelta(self: *BrowserView, hc: *HostConn, payload: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const d = std.json.parseFromSliceLeaky(WireDelta, arena.allocator(), payload, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        for (self.tabs.items) |tab| {
            if (tab.hc != hc) continue;
            const dir = tab.dirByView(d.view) orelse continue;
            if (d.gone) {
                dir.gone = true;
                if (dir == tab.root) {
                    self.setStatusFmt("{s} no longer exists", .{dir.path});
                } else {
                    // Expanded subdir vanished: its own delta already
                    // removed the entry from the parent; drop the view.
                    tab.dropSubdirsUnder(dir.path);
                }
                return true;
            }
            if (d.resync) {
                // Kernel dropped events: deltas alone are no longer
                // sufficient — refetch the whole listing on the SAME
                // live view.
                self.refreshDir(tab, dir);
                return false;
            }
            for (d.changes) |ch| {
                if (std.mem.eql(u8, ch.op, "upsert")) {
                    if (ch.entry) |we| dir.upsert(we);
                } else if (std.mem.eql(u8, ch.op, "del")) {
                    dir.del(ch.name);
                }
            }
            return true;
        }
        return false;
    }

    // ── tabs + navigation ───────────────────────────────────────

    fn makeDir(self: *BrowserView, path: []const u8) ?*Dir {
        const d = self.allocator.create(Dir) catch return null;
        const owned = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(d);
            return null;
        };
        d.* = .{ .allocator = self.allocator, .path = owned, .view_id = self.next_view };
        self.next_view += 1;
        return d;
    }

    /// Open a new internal tab from a location spec ("host:/path" /
    /// "/path"; bare paths inherit the current tab's host).
    pub fn newTabSpec(self: *BrowserView, spec: []const u8) ?*BTab {
        const loc = parseSpec(spec);
        const host = if (loc.current_host)
            (if (self.currentTab()) |t| t.hc.host else null)
        else
            loc.host;
        return self.newTab(if (host) |h| @as(?[]const u8, h) else null, loc.path);
    }

    pub fn newTab(self: *BrowserView, host: ?[]const u8, path: []const u8) ?*BTab {
        const hc = self.hostConnFor(host) orelse return null;
        const dir = self.makeDir(path) orelse return null;
        const tab = self.allocator.create(BTab) catch {
            dir.deinit();
            return null;
        };

        const scroller = c.gtk_scrolled_window_new();
        c.gtk_widget_set_hexpand(scroller, 1);
        c.gtk_widget_set_vexpand(scroller, 1);
        const listbox = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(listbox), c.GTK_SELECTION_MULTIPLE);
        c.gtk_list_box_set_activate_on_single_click(@ptrCast(listbox), 0);
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), listbox);

        const label = c.gtk_label_new("...");
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(@ptrCast(label), 24);

        tab.* = .{
            .view = self,
            .hc = hc,
            .root = dir,
            .page = scroller,
            .listbox = @ptrCast(listbox),
            .tab_label = @ptrCast(@alignCast(label)),
        };
        self.tabs.append(self.allocator, tab) catch {
            tab.root.deinit();
            self.allocator.destroy(tab);
            return null;
        };

        _ = c.g_signal_connect_data(listbox, "row-activated", @ptrCast(&onRowActivated), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);

        const rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
        _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onRightClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(listbox, @ptrCast(rclick));

        const page_idx = c.gtk_notebook_append_page(self.notebook, scroller, label);
        c.gtk_notebook_set_current_page(self.notebook, page_idx);
        self.updateTabLabel(tab);
        self.openDir(tab, dir);
        self.syncPathEntry(tab);
        if (hc.state == .connecting) self.setStatusFmt("connecting to {s}…", .{hc.label()});
        return tab;
    }

    fn currentTab(self: *BrowserView) ?*BTab {
        const idx = c.gtk_notebook_get_current_page(self.notebook);
        if (idx < 0) return null;
        const page = c.gtk_notebook_get_nth_page(self.notebook, idx) orelse return null;
        for (self.tabs.items) |t| {
            if (t.page == page) return t;
        }
        return null;
    }

    /// Navigate a tab to (host, path). `push_history` false = back/
    /// forward traversal (history untouched).
    fn navigate(self: *BrowserView, tab: *BTab, host: ?[]const u8, path: []const u8, push_history: bool) void {
        const same_host = hostEq(tab.hc.host, host);
        if (same_host and tab.hc.state != .dead and std.mem.eql(u8, tab.root.path, path)) return;
        const new_hc = if (same_host and tab.hc.state != .dead)
            tab.hc
        else
            self.hostConnFor(host) orelse return;
        const new_dir = self.makeDir(path) orelse return;
        if (push_history) {
            var buf: [4200]u8 = undefined;
            const old = self.allocator.dupe(u8, tab.spec(&buf)) catch null;
            if (old) |o| tab.back.append(self.allocator, o) catch self.allocator.free(o);
            for (tab.fwd.items) |p| self.allocator.free(p);
            tab.fwd.clearRetainingCapacity();
        }
        tab.dropSubdirsUnder(tab.root.path);
        self.closeViewOf(tab.hc, tab.root);
        tab.root.deinit();
        tab.root = new_dir;
        tab.hc = new_hc;
        self.updateTabLabel(tab);
        self.openDir(tab, new_dir);
        self.syncPathEntry(tab);
        self.renderTab(tab);
    }

    fn navigateSpec(self: *BrowserView, tab: *BTab, spec: []const u8, push_history: bool) void {
        const loc = parseSpec(spec);
        // Spec strings from history/path-entry may alias tab state
        // that navigate() frees — copy to the stack first.
        var hbuf: [256]u8 = undefined;
        var pbuf: [4096]u8 = undefined;
        if (loc.path.len >= pbuf.len) return;
        @memcpy(pbuf[0..loc.path.len], loc.path);
        const path = pbuf[0..loc.path.len];
        var host: ?[]const u8 = null;
        if (loc.current_host) {
            if (tab.hc.host) |h| {
                if (h.len >= hbuf.len) return;
                @memcpy(hbuf[0..h.len], h);
                host = hbuf[0..h.len];
            }
        } else if (loc.host) |h| {
            if (h.len >= hbuf.len) return;
            @memcpy(hbuf[0..h.len], h);
            host = hbuf[0..h.len];
        }
        self.navigate(tab, host, path, push_history);
    }

    fn goBack(self: *BrowserView, tab: *BTab) void {
        const prev = tab.back.pop() orelse return;
        var buf: [4200]u8 = undefined;
        const cur = self.allocator.dupe(u8, tab.spec(&buf)) catch null;
        if (cur) |cp| tab.fwd.append(self.allocator, cp) catch self.allocator.free(cp);
        self.navigateSpec(tab, prev, false);
        self.allocator.free(prev);
    }

    fn goForward(self: *BrowserView, tab: *BTab) void {
        const next = tab.fwd.pop() orelse return;
        var buf: [4200]u8 = undefined;
        const cur = self.allocator.dupe(u8, tab.spec(&buf)) catch null;
        if (cur) |cp| tab.back.append(self.allocator, cp) catch self.allocator.free(cp);
        self.navigateSpec(tab, next, false);
        self.allocator.free(next);
    }

    fn goUp(self: *BrowserView, tab: *BTab) void {
        const parent = std.fs.path.dirname(tab.root.path) orelse return;
        if (parent.len == 0) return;
        var buf: [4096]u8 = undefined;
        const copy = if (parent.len < buf.len) blk: {
            @memcpy(buf[0..parent.len], parent);
            break :blk buf[0..parent.len];
        } else return;
        var hbuf: [256]u8 = undefined;
        var host: ?[]const u8 = null;
        if (tab.hc.host) |h| {
            if (h.len >= hbuf.len) return;
            @memcpy(hbuf[0..h.len], h);
            host = hbuf[0..h.len];
        }
        self.navigate(tab, host, copy, true);
    }

    fn toggleExpand(self: *BrowserView, tab: *BTab, dir_path: []const u8) void {
        if (tab.subdirByPath(dir_path)) |_| {
            tab.dropSubdirsUnder(dir_path);
            self.renderTab(tab);
            return;
        }
        const d = self.makeDir(dir_path) orelse return;
        tab.subdirs.append(self.allocator, d) catch {
            d.deinit();
            return;
        };
        self.openDir(tab, d);
    }

    fn updateTabLabel(self: *BrowserView, tab: *BTab) void {
        _ = self;
        const base = std.fs.path.basename(tab.root.path);
        var buf: [160:0]u8 = undefined;
        const name = if (base.len == 0) "/" else base;
        const txt = if (tab.hc.host) |h|
            std.fmt.bufPrintZ(&buf, "{s}: {s}", .{ h, name }) catch return
        else
            std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return;
        c.gtk_label_set_text(tab.tab_label, txt.ptr);
    }

    fn syncPathEntry(self: *BrowserView, tab: *BTab) void {
        if (self.currentTab() != tab) return;
        var buf: [4200]u8 = undefined;
        const spec = tab.spec(&buf);
        var z: [4300:0]u8 = undefined;
        const n = @min(spec.len, z.len - 1);
        @memcpy(z[0..n], spec[0..n]);
        z[n] = 0;
        c.gtk_editable_set_text(@ptrCast(self.path_entry), &z);
    }

    fn setStatus(self: *BrowserView, msg: []const u8) void {
        var buf: [256:0]u8 = undefined;
        const n = @min(msg.len, buf.len - 1);
        @memcpy(buf[0..n], msg[0..n]);
        buf[n] = 0;
        c.gtk_label_set_text(self.status_label, &buf);
    }

    fn setStatusFmt(self: *BrowserView, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
        self.setStatus(msg);
    }

    // ── rendering ───────────────────────────────────────────────

    fn renderCurrent(self: *BrowserView) void {
        if (self.currentTab()) |t| self.renderTab(t);
    }

    fn renderTab(self: *BrowserView, tab: *BTab) void {
        // Full rebuild — simple and correct; fine for the row counts
        // a human browses. (Optimization: diff rows later.)
        while (c.gtk_list_box_get_row_at_index(tab.listbox, 0)) |row| {
            c.gtk_list_box_remove(tab.listbox, @ptrCast(row));
        }
        self.renderDirRows(tab, tab.root, 0);
        var count_buf: [96]u8 = undefined;
        const cmsg = std.fmt.bufPrint(&count_buf, "{d} items", .{tab.root.entries.items.len}) catch "";
        self.setStatus(cmsg);
    }

    fn renderDirRows(self: *BrowserView, tab: *BTab, dir: *Dir, depth: u32) void {
        for (dir.entries.items) |e| {
            if (!self.show_hidden and e.name.len > 0 and e.name[0] == '.') continue;
            self.appendRow(tab, dir, e, depth);
            if (e.tdir) {
                var buf: [4096]u8 = undefined;
                const child = std.fmt.bufPrint(&buf, "{s}/{s}", .{
                    if (dir.path.len == 1) "" else dir.path, e.name,
                }) catch continue;
                if (tab.subdirByPath(child)) |sub| {
                    if (sub.loaded) self.renderDirRows(tab, sub, depth + 1);
                }
            }
        }
    }

    const RowCtx = struct {
        allocator: std.mem.Allocator,
        tab: *BTab,
        /// Full path of the entry.
        path: []u8,
        is_dir: bool,
    };

    fn freeRowCtx(user: ?*anyopaque) callconv(.c) void {
        const ctx: *RowCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.path);
        ctx.allocator.destroy(ctx);
    }

    fn appendRow(self: *BrowserView, tab: *BTab, dir: *Dir, e: Entry, depth: u32) void {
        const row_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_margin_start(row_box, @intCast(6 + depth * 18));
        c.gtk_widget_set_margin_end(row_box, 6);
        c.gtk_widget_set_margin_top(row_box, 2);
        c.gtk_widget_set_margin_bottom(row_box, 2);

        var full_buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{
            if (dir.path.len == 1) "" else dir.path, e.name,
        }) catch return;

        if (e.tdir) {
            const expanded = tab.subdirByPath(full) != null;
            const exp = c.gtk_button_new_from_icon_name(if (expanded) "pan-down-symbolic" else "pan-end-symbolic");
            c.gtk_button_set_has_frame(@ptrCast(exp), 0);
            const ctx = self.allocator.create(RowCtx) catch return;
            ctx.* = .{
                .allocator = self.allocator,
                .tab = tab,
                .path = self.allocator.dupe(u8, full) catch {
                    self.allocator.destroy(ctx);
                    return;
                },
                .is_dir = true,
            };
            _ = c.g_signal_connect_data(exp, "clicked", @ptrCast(&onExpandClicked), @ptrCast(ctx), @ptrCast(&freeRowCtxClosure), c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(row_box), exp);
        } else {
            const spacer = c.gtk_label_new("");
            c.gtk_widget_set_size_request(spacer, 24, -1);
            c.gtk_box_append(@ptrCast(row_box), spacer);
        }

        const icon_name: [*:0]const u8 = if (std.mem.eql(u8, e.kind, "dir"))
            "folder-symbolic"
        else if (std.mem.eql(u8, e.kind, "link"))
            "emblem-symbolic-link"
        else
            "text-x-generic-symbolic";
        const icon = c.gtk_image_new_from_icon_name(icon_name);
        c.gtk_box_append(@ptrCast(row_box), icon);

        var name_buf: [512:0]u8 = undefined;
        const nn = @min(e.name.len, name_buf.len - 1);
        @memcpy(name_buf[0..nn], e.name[0..nn]);
        name_buf[nn] = 0;
        const name_label = c.gtk_label_new(&name_buf);
        c.gtk_label_set_xalign(@ptrCast(name_label), 0);
        c.gtk_widget_set_hexpand(name_label, 1);
        c.gtk_label_set_ellipsize(@ptrCast(name_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_box_append(@ptrCast(row_box), name_label);

        if (!std.mem.eql(u8, e.kind, "dir")) {
            var size_buf: [48:0]u8 = undefined;
            const s = fmtSize(&size_buf, e.size);
            const size_label = c.gtk_label_new(s.ptr);
            c.gtk_widget_add_css_class(size_label, "dim-label");
            c.gtk_box_append(@ptrCast(row_box), size_label);
        }

        var time_buf: [40:0]u8 = undefined;
        const tstr = fmtTimeZ(&time_buf, e.mtime_ms);
        const time_label = c.gtk_label_new(tstr);
        c.gtk_widget_add_css_class(time_label, "dim-label");
        c.gtk_box_append(@ptrCast(row_box), time_label);

        const row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(row), row_box);

        // Row context for activation, freed with the row.
        const ctx = self.allocator.create(RowCtx) catch return;
        ctx.* = .{
            .allocator = self.allocator,
            .tab = tab,
            .path = self.allocator.dupe(u8, full) catch {
                self.allocator.destroy(ctx);
                return;
            },
            .is_dir = e.tdir,
        };
        c.g_object_set_data_full(@ptrCast(row), "sketerm-row", @ptrCast(ctx), @ptrCast(&freeRowCtx));

        c.gtk_list_box_append(tab.listbox, row);
    }

    /// Signal-closure variant of freeRowCtx (GClosureNotify shape).
    fn freeRowCtxClosure(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
        _ = closure;
        freeRowCtx(user);
    }

    fn onExpandClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *RowCtx = @ptrCast(@alignCast(user.?));
        ctx.tab.view.toggleExpand(ctx.tab, ctx.path);
    }

    fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse return;
        const ctx: *RowCtx = @ptrCast(@alignCast(data));
        const self = tab.view;
        if (ctx.is_dir) {
            // navigate() frees rows (and this ctx) — copy the path out.
            var buf: [4096]u8 = undefined;
            if (ctx.path.len >= buf.len) return;
            @memcpy(buf[0..ctx.path.len], ctx.path);
            const path = buf[0..ctx.path.len];
            var hbuf: [256]u8 = undefined;
            var host: ?[]const u8 = null;
            if (tab.hc.host) |h| {
                if (h.len >= hbuf.len) return;
                @memcpy(hbuf[0..h.len], h);
                host = hbuf[0..h.len];
            }
            self.navigate(tab, host, path, true);
        } else if (tab.hc.host == null) {
            // Local file: default application, straight from disk.
            var uri_buf: [4200:0]u8 = undefined;
            const uri = std.fmt.bufPrintZ(&uri_buf, "file://{s}", .{ctx.path}) catch return;
            _ = c.g_app_info_launch_default_for_uri(uri.ptr, null, null);
        } else {
            // Remote file: download into the local open-cache, then
            // launch (phase-5's hydrating cache predecessor).
            self.openRemoteFile(tab, ctx.path);
        }
    }

    // ── context menu + file operations ──────────────────────────

    /// Heap context for one open menu/dialog popover; owned by the
    /// popover via g_object_set_data_full (freed when it dies).
    const MenuCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        tab: *BTab,
        /// Target entry (null = background click).
        path: ?[]u8,
        name: ?[]u8,
        is_dir: bool,
        popover: *c.GtkWidget,
        /// Entry-dialog mode: what Enter commits.
        mode: enum { none, rename, mkdir } = .none,
        entry: ?*c.GtkWidget = null,

        fn free(user: ?*anyopaque) callconv(.c) void {
            const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
            if (ctx.path) |p| ctx.allocator.free(p);
            if (ctx.name) |n| ctx.allocator.free(n);
            ctx.allocator.destroy(ctx);
        }
    };

    fn menuButton(box: *c.GtkWidget, label: [*:0]const u8, cb: anytype, ctx: *MenuCtx, destructive: bool) void {
        const btn = c.gtk_button_new_with_label(label);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_set_halign(c.gtk_button_get_child(@ptrCast(btn)), c.GTK_ALIGN_START);
        if (destructive) c.gtk_widget_add_css_class(btn, "destructive-action");
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(cb), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), btn);
    }

    fn onRightClick(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        _ = gesture;
        _ = n_press;
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        const self = tab.view;

        var path: ?[]u8 = null;
        var name: ?[]u8 = null;
        var is_dir = false;
        if (c.gtk_list_box_get_row_at_y(tab.listbox, @intFromFloat(y))) |row| {
            if (c.g_object_get_data(@ptrCast(row), "sketerm-row")) |data| {
                const rctx: *RowCtx = @ptrCast(@alignCast(data));
                path = self.allocator.dupe(u8, rctx.path) catch null;
                name = self.allocator.dupe(u8, std.fs.path.basename(rctx.path)) catch null;
                is_dir = rctx.is_dir;
                c.gtk_list_box_select_row(tab.listbox, row);
            }
        }

        const popover = c.gtk_popover_new();
        const ctx = self.allocator.create(MenuCtx) catch {
            if (path) |p| self.allocator.free(p);
            if (name) |n| self.allocator.free(n);
            return;
        };
        ctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = tab,
            .path = path,
            .name = name,
            .is_dir = is_dir,
            .popover = popover,
        };
        c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(ctx), @ptrCast(&MenuCtx.free));

        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        const is_local = tab.hc.host == null;
        if (ctx.path != null) {
            if (is_dir) {
                if (is_local)
                    menuButton(box, "Open Terminal Here", &onMenuTerminalHere, ctx, false);
                menuButton(box, "Open in New Browser Tab", &onMenuOpenTab, ctx, false);
            }
            menuButton(box, "Copy", &onMenuCopy, ctx, false);
            menuButton(box, "Copy Path", &onMenuCopyPath, ctx, false);
            menuButton(box, "Rename…", &onMenuRename, ctx, false);
            menuButton(box, "Delete…", &onMenuDelete, ctx, true);
        }
        if (self.clip_path != null)
            menuButton(box, "Paste Here", &onMenuPaste, ctx, false);
        menuButton(box, "New Folder…", &onMenuNewFolder, ctx, false);

        c.gtk_popover_set_child(@ptrCast(popover), box);
        c.gtk_widget_set_parent(popover, @ptrCast(@alignCast(tab.listbox)));
        connectPopoverAutoUnparent(popover);
        const rect = c.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        c.gtk_popover_popup(@ptrCast(popover));
    }

    fn onPopoverClosed(_: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
        if (user) |u| {
            const pop: *c.GtkWidget = @ptrCast(@alignCast(u));
            if (c.gtk_widget_get_parent(pop) != null) c.gtk_widget_unparent(pop);
        }
    }

    fn connectPopoverAutoUnparent(popover: *c.GtkWidget) void {
        _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&onPopoverClosed), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
    }

    fn menuDone(ctx: *MenuCtx) void {
        c.gtk_popover_popdown(@ptrCast(ctx.popover));
    }

    fn onMenuTerminalHere(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const path = ctx.path orelse return menuDone(ctx);
        // cd the pane's shell into the target (single-quoted; embedded
        // quotes escaped) and flip to the terminal face.
        var buf: [4600]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.writeAll("cd '") catch return menuDone(ctx);
        for (path) |ch| {
            if (ch == '\'') w.writeAll("'\\''") catch return menuDone(ctx) else w.writeByte(ch) catch return menuDone(ctx);
        }
        w.writeAll("'\n") catch return menuDone(ctx);
        ctx.view.pane.terminal.writeRaw(w.buffered());
        ctx.view.pane.setBrowserVisible(false);
        menuDone(ctx);
    }

    fn onMenuOpenTab(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        if (ctx.path) |p| _ = ctx.view.newTab(ctx.tab.hc.host, p);
        menuDone(ctx);
    }

    fn onMenuCopy(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        if (self.clip_host) |s| self.allocator.free(s);
        self.clip_host = null;
        if (ctx.tab.hc.host) |h| self.clip_host = self.allocator.dupe(u8, h) catch null;
        if (self.clip_path) |s| self.allocator.free(s);
        self.clip_path = self.allocator.dupe(u8, path) catch null;
        self.setStatusFmt("copied: {s}", .{path});
        menuDone(ctx);
    }

    fn onMenuCopyPath(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const path = ctx.path orelse return menuDone(ctx);
        var z: [4096:0]u8 = undefined;
        const n = @min(path.len, z.len - 1);
        @memcpy(z[0..n], path[0..n]);
        z[n] = 0;
        const clip = c.gtk_widget_get_clipboard(@ptrCast(@alignCast(ctx.tab.listbox)));
        c.gdk_clipboard_set_text(clip, &z);
        menuDone(ctx);
    }

    fn onMenuPaste(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const src = self.clip_path orelse return menuDone(ctx);
        const tab = ctx.tab;
        const base = std.fs.path.basename(src);
        var dst_buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&dst_buf);
        const dir = tab.root.path;
        // Same-name collision in the target listing → "-copy" suffix
        // instead of a silent overwrite.
        const collides = tab.root.find(base) != null;
        w.print("{s}/{s}{s}", .{ if (dir.len == 1) "" else dir, base, if (collides) "-copy" else "" }) catch return menuDone(ctx);
        const dst = w.buffered();

        if (hostEq(self.clip_host, tab.hc.host)) {
            // Same host: the daemon copies locally (job).
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "copy {s}", .{base}) catch base;
            self.startDaemonJob(tab.hc, "copy", src, dst, label);
        } else {
            // Cross-host: client-mediated transfer.
            const src_hc = self.hostConnFor(if (self.clip_host) |h| @as(?[]const u8, h) else null) orelse
                return menuDone(ctx);
            self.startTransfer(src_hc, src, tab.hc, dst, false);
        }
        menuDone(ctx);
    }

    fn onMenuNewFolder(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        ctx.view.entryDialog(ctx.tab, .mkdir, null);
        menuDone(ctx);
    }

    fn onMenuRename(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const path = ctx.path orelse return menuDone(ctx);
        ctx.view.entryDialog(ctx.tab, .rename, path);
        menuDone(ctx);
    }

    fn onMenuDelete(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        // Confirm popover with one destructive button.
        const popover = c.gtk_popover_new();
        const cctx = self.allocator.create(MenuCtx) catch return menuDone(ctx);
        cctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = ctx.tab,
            .path = self.allocator.dupe(u8, path) catch null,
            .name = null,
            .is_dir = ctx.is_dir,
            .popover = popover,
        };
        c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(cctx), @ptrCast(&MenuCtx.free));
        var lbl: [300:0]u8 = undefined;
        const base = std.fs.path.basename(path);
        const txt = std.fmt.bufPrintZ(&lbl, "Delete {s}{s}", .{ base, if (ctx.is_dir) " (recursively)" else "" }) catch "Delete";
        const btn = c.gtk_button_new_with_label(txt.ptr);
        c.gtk_widget_add_css_class(btn, "destructive-action");
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onDeleteConfirmed), @ptrCast(cctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_popover_set_child(@ptrCast(popover), btn);
        c.gtk_widget_set_parent(popover, @ptrCast(@alignCast(ctx.tab.listbox)));
        connectPopoverAutoUnparent(popover);
        c.gtk_popover_popup(@ptrCast(popover));
        menuDone(ctx);
    }

    fn onDeleteConfirmed(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        if (ctx.is_dir) {
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "delete {s}", .{std.fs.path.basename(path)}) catch "delete";
            self.startDaemonJob(ctx.tab.hc, "delete_tree", path, "", label);
        } else {
            self.sendOp(ctx.tab.hc, .{ .req = self.nextReq(), .op = "delete", .path = path });
        }
        menuDone(ctx);
    }

    /// One-entry popover shared by Rename (target = old full path)
    /// and New Folder (target = null → current dir).
    fn entryDialog(self: *BrowserView, tab: *BTab, mode: @TypeOf(@as(MenuCtx, undefined).mode), rename_path: ?[]const u8) void {
        const popover = c.gtk_popover_new();
        const entry = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), if (mode == .mkdir) "folder name" else "new name");
        if (rename_path) |rp| {
            var z: [512:0]u8 = undefined;
            const base = std.fs.path.basename(rp);
            const n = @min(base.len, z.len - 1);
            @memcpy(z[0..n], base[0..n]);
            z[n] = 0;
            c.gtk_editable_set_text(@ptrCast(entry), &z);
            c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
        }
        const ctx = self.allocator.create(MenuCtx) catch return;
        ctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = tab,
            .path = if (rename_path) |rp| (self.allocator.dupe(u8, rp) catch null) else null,
            .name = null,
            .is_dir = false,
            .popover = popover,
            .mode = mode,
            .entry = entry,
        };
        c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(ctx), @ptrCast(&MenuCtx.free));
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onEntryDialogActivate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_popover_set_child(@ptrCast(popover), entry);
        c.gtk_widget_set_parent(popover, @ptrCast(@alignCast(tab.listbox)));
        connectPopoverAutoUnparent(popover);
        c.gtk_popover_popup(@ptrCast(popover));
        _ = c.gtk_widget_grab_focus(entry);
    }

    fn onEntryDialogActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const txt = c.gtk_editable_get_text(@ptrCast(entry));
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
            self.setStatus("invalid name");
            return menuDone(ctx);
        }
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        const req = self.nextReq();
        switch (ctx.mode) {
            .mkdir => {
                const dir = ctx.tab.root.path;
                w.print("{s}/{s}", .{ if (dir.len == 1) "" else dir, name }) catch return menuDone(ctx);
                self.sendOp(ctx.tab.hc, .{ .req = req, .op = "mkdir", .path = w.buffered() });
            },
            .rename => {
                const old = ctx.path orelse return menuDone(ctx);
                const dir = std.fs.path.dirname(old) orelse return menuDone(ctx);
                w.print("{s}/{s}", .{ if (dir.len == 1) "" else dir, name }) catch return menuDone(ctx);
                self.sendOp(ctx.tab.hc, .{ .req = req, .op = "rename", .path = old, .to = w.buffered() });
            },
            .none => {},
        }
        menuDone(ctx);
    }

    // ── jobs / transfers panel ──────────────────────────────────

    /// Heap context for one jobs-panel button, freed with the button.
    const JobBtnCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        /// Daemon job target (hc+job), or transfer target (xfer).
        hc: ?*HostConn = null,
        job: u64 = 0,
        xfer: ?*fstransfer.Xfer = null,
        kind: enum { pause, resume_, cancel, dismiss },

        fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
            _ = closure;
            const ctx: *JobBtnCtx = @ptrCast(@alignCast(user.?));
            ctx.allocator.destroy(ctx);
        }
    };

    fn jobsButton(self: *BrowserView, row: *c.GtkWidget, icon: [*:0]const u8, ctx_in: JobBtnCtx) void {
        const ctx = self.allocator.create(JobBtnCtx) catch return;
        ctx.* = ctx_in;
        const btn = c.gtk_button_new_from_icon_name(icon);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onJobBtn), @ptrCast(ctx), @ptrCast(&JobBtnCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), btn);
    }

    fn onJobBtn(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *JobBtnCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        if (ctx.xfer) |x| {
            switch (ctx.kind) {
                .cancel => x.cancel(),
                else => {},
            }
            self.reapTransfers();
            self.renderJobs();
            return;
        }
        const hc = ctx.hc orelse return;
        switch (ctx.kind) {
            .pause => {
                self.sendOp(hc, .{ .req = self.nextReq(), .op = "job_pause", .job = ctx.job });
                self.markJob(hc, ctx.job, .paused);
            },
            .resume_ => {
                self.sendOp(hc, .{ .req = self.nextReq(), .op = "job_resume", .job = ctx.job });
                self.markJob(hc, ctx.job, .running);
            },
            .cancel => self.sendOp(hc, .{ .req = self.nextReq(), .op = "job_cancel", .job = ctx.job }),
            .dismiss => {
                var i: usize = 0;
                while (i < self.jobs.items.len) : (i += 1) {
                    const j = self.jobs.items[i];
                    if (j.hc == hc and j.job == ctx.job) {
                        self.allocator.free(j.label);
                        self.allocator.destroy(j);
                        _ = self.jobs.orderedRemove(i);
                        break;
                    }
                }
            },
        }
        self.renderJobs();
    }

    fn markJob(self: *BrowserView, hc: *HostConn, job: u64, state: @FieldType(JobRow, "state")) void {
        for (self.jobs.items) |j| {
            if (j.hc == hc and j.job == job and !j.terminal()) j.state = state;
        }
    }

    /// Rebuild the jobs/transfers panel (hidden when empty).
    fn renderJobs(self: *BrowserView) void {
        while (c.gtk_widget_get_first_child(self.jobs_box)) |child| {
            c.gtk_box_remove(@ptrCast(self.jobs_box), child);
        }
        const any = self.transfers.items.len > 0 or self.jobs.items.len > 0;
        c.gtk_widget_set_visible(self.jobs_box, if (any) 1 else 0);
        if (!any) return;

        for (self.transfers.items) |t| {
            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
            c.gtk_widget_set_margin_start(row, 6);
            c.gtk_widget_set_margin_end(row, 6);
            const p = t.x.progress();
            var lbl: [256:0]u8 = undefined;
            const pct: u64 = if (p.total > 0) p.done * 100 / p.total else 0;
            const txt = std.fmt.bufPrintZ(&lbl, "⇄ {s} — {d}% ({d}/{d} MB)", .{
                t.label, pct, p.done >> 20, p.total >> 20,
            }) catch "transfer";
            const l = c.gtk_label_new(txt.ptr);
            c.gtk_label_set_xalign(@ptrCast(l), 0);
            c.gtk_widget_set_hexpand(l, 1);
            c.gtk_label_set_ellipsize(@ptrCast(l), c.PANGO_ELLIPSIZE_MIDDLE);
            c.gtk_box_append(@ptrCast(row), l);
            self.jobsButton(row, "process-stop-symbolic", .{
                .allocator = self.allocator,
                .view = self,
                .xfer = t.x,
                .kind = .cancel,
            });
            c.gtk_box_append(@ptrCast(self.jobs_box), row);
        }

        for (self.jobs.items) |j| {
            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
            c.gtk_widget_set_margin_start(row, 6);
            c.gtk_widget_set_margin_end(row, 6);
            var lbl: [256:0]u8 = undefined;
            const state_txt: []const u8 = switch (j.state) {
                .running => "",
                .paused => " [paused]",
                .finished => " [done]",
                .failed => " [failed]",
                .canceled => " [canceled]",
            };
            const pct: u64 = if (j.total > 0) j.done * 100 / j.total else 0;
            const txt = std.fmt.bufPrintZ(&lbl, "{s}@{s} — {d}%{s}", .{
                j.label, j.hc.label(), pct, state_txt,
            }) catch "job";
            const l = c.gtk_label_new(txt.ptr);
            c.gtk_label_set_xalign(@ptrCast(l), 0);
            c.gtk_widget_set_hexpand(l, 1);
            c.gtk_label_set_ellipsize(@ptrCast(l), c.PANGO_ELLIPSIZE_MIDDLE);
            c.gtk_box_append(@ptrCast(row), l);
            if (!j.terminal()) {
                if (j.state == .paused) {
                    self.jobsButton(row, "media-playback-start-symbolic", .{
                        .allocator = self.allocator,
                        .view = self,
                        .hc = j.hc,
                        .job = j.job,
                        .kind = .resume_,
                    });
                } else {
                    self.jobsButton(row, "media-playback-pause-symbolic", .{
                        .allocator = self.allocator,
                        .view = self,
                        .hc = j.hc,
                        .job = j.job,
                        .kind = .pause,
                    });
                }
                self.jobsButton(row, "process-stop-symbolic", .{
                    .allocator = self.allocator,
                    .view = self,
                    .hc = j.hc,
                    .job = j.job,
                    .kind = .cancel,
                });
            } else {
                self.jobsButton(row, "window-close-symbolic", .{
                    .allocator = self.allocator,
                    .view = self,
                    .hc = j.hc,
                    .job = j.job,
                    .kind = .dismiss,
                });
            }
            c.gtk_box_append(@ptrCast(self.jobs_box), row);
        }
    }

    // ── toolbar ─────────────────────────────────────────────────

    fn buildUi(self: *BrowserView) void {
        const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(vbox, 1);
        c.gtk_widget_set_vexpand(vbox, 1);

        const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_set_margin_start(bar, 4);
        c.gtk_widget_set_margin_end(bar, 4);
        c.gtk_widget_set_margin_top(bar, 4);
        c.gtk_widget_set_margin_bottom(bar, 4);

        const back = c.gtk_button_new_from_icon_name("go-previous-symbolic");
        _ = c.g_signal_connect_data(back, "clicked", @ptrCast(&onBackClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), back);
        const fwd = c.gtk_button_new_from_icon_name("go-next-symbolic");
        _ = c.g_signal_connect_data(fwd, "clicked", @ptrCast(&onFwdClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), fwd);
        const up = c.gtk_button_new_from_icon_name("go-up-symbolic");
        _ = c.g_signal_connect_data(up, "clicked", @ptrCast(&onUpClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), up);

        const entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(entry, 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "/path — or host:/path, user@host:/path, udp:host:/path, local:/path");
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onPathActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), entry);

        const hidden = c.gtk_toggle_button_new();
        c.gtk_button_set_icon_name(@ptrCast(hidden), "view-reveal-symbolic");
        c.gtk_widget_set_tooltip_text(hidden, "Show hidden files");
        _ = c.g_signal_connect_data(hidden, "toggled", @ptrCast(&onHiddenToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), hidden);

        const newtab = c.gtk_button_new_from_icon_name("tab-new-symbolic");
        c.gtk_widget_set_tooltip_text(newtab, "New browser tab");
        _ = c.g_signal_connect_data(newtab, "clicked", @ptrCast(&onNewTabClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), newtab);

        const term = c.gtk_button_new_from_icon_name("utilities-terminal-symbolic");
        c.gtk_widget_set_tooltip_text(term, "Show the pane's terminal (browser stays one click away)");
        _ = c.g_signal_connect_data(term, "clicked", @ptrCast(&onTerminalClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), term);

        c.gtk_box_append(@ptrCast(vbox), bar);

        const notebook = c.gtk_notebook_new();
        c.gtk_notebook_set_scrollable(@ptrCast(notebook), 1);
        c.gtk_widget_set_hexpand(notebook, 1);
        c.gtk_widget_set_vexpand(notebook, 1);
        _ = c.g_signal_connect_data(notebook, "switch-page", @ptrCast(&onSwitchPage), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(vbox), notebook);

        const jobs_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
        c.gtk_widget_set_visible(jobs_box, 0);
        c.gtk_box_append(@ptrCast(vbox), jobs_box);

        const status = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(status), 0);
        c.gtk_widget_add_css_class(status, "dim-label");
        c.gtk_widget_set_margin_start(status, 6);
        c.gtk_widget_set_margin_bottom(status, 2);
        c.gtk_box_append(@ptrCast(vbox), status);

        // Pane-level keybinds (palette, save-layout, splits, …) must
        // keep working while browser widgets hold focus: bindings
        // normally live on the hidden GL area's controllers, so a
        // bubble-phase forwarder on the browser root re-runs the same
        // match+dispatch. Plain typing is untouched (entries consume
        // their keys before this fires; chords don't match entries).
        const keys = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onBrowserKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(vbox, @ptrCast(keys));

        self.root_box = vbox;
        self.notebook = @ptrCast(@alignCast(notebook));
        self.path_entry = @ptrCast(@alignCast(entry));
        self.status_label = @ptrCast(@alignCast(status));
        self.jobs_box = jobs_box;
    }

    fn onBrowserKey(
        _: *c.GtkEventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const ictx = self.pane.input_ctx orelse return 0;
        const lower_kv: c_uint = c.gdk_keyval_to_lower(keyval);
        const bindings: []const input.Binding = if (ictx.bindings.len > 0) ictx.bindings else &input.default_bindings;
        if (input.matchBinding(bindings, lower_kv, state) orelse input.matchBinding(bindings, keyval, state)) |action| {
            return input.runAction(ictx, action);
        }
        return 0;
    }

    fn onBackClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (self.currentTab()) |t| self.goBack(t);
    }
    fn onFwdClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (self.currentTab()) |t| self.goForward(t);
    }
    fn onUpClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (self.currentTab()) |t| self.goUp(t);
    }
    fn onNewTabClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (self.currentTab()) |t| {
            var buf: [4096]u8 = undefined;
            if (t.root.path.len >= buf.len) return;
            @memcpy(buf[0..t.root.path.len], t.root.path);
            _ = self.newTab(t.hc.host, buf[0..t.root.path.len]);
        } else {
            _ = self.newTab(null, "/");
        }
    }
    fn onTerminalClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.pane.setBrowserVisible(false);
    }
    fn onHiddenToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.show_hidden = c.gtk_toggle_button_get_active(btn) != 0;
        self.renderCurrent();
    }
    fn onPathActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const tab = self.currentTab() orelse return;
        const txt = c.gtk_editable_get_text(@ptrCast(entry));
        const spec = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        if (spec.len == 0) return;
        const loc = parseSpec(spec);
        if (loc.path.len == 0 or loc.path[0] != '/') {
            self.setStatus("path must be absolute (host:/path for remote)");
            return;
        }
        self.navigateSpec(tab, spec, true);
    }
    fn onSwitchPage(_: *c.GtkNotebook, _: *c.GtkWidget, _: c.guint, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        // currentTab still reports the OLD page during switch-page;
        // defer to idle so path entry + render see the new one.
        _ = c.g_idle_add(@ptrCast(&idleAfterSwitch), @ptrCast(self));
    }
    fn idleAfterSwitch(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (self.currentTab()) |t| {
            self.syncPathEntry(t);
            self.renderTab(t);
        }
        return 0;
    }
};

fn launchLocal(path: []const u8) void {
    var uri_buf: [4300:0]u8 = undefined;
    const uri = std.fmt.bufPrintZ(&uri_buf, "file://{s}", .{path}) catch return;
    _ = c.g_app_info_launch_default_for_uri(uri.ptr, null, null);
}

fn fmtSize(buf: *[48:0]u8, size: u64) [:0]const u8 {
    const s = if (size >= (1 << 30))
        std.fmt.bufPrintZ(buf, "{d:.1} GB", .{@as(f64, @floatFromInt(size)) / (1 << 30)}) catch "?"
    else if (size >= (1 << 20))
        std.fmt.bufPrintZ(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(size)) / (1 << 20)}) catch "?"
    else if (size >= 1024)
        std.fmt.bufPrintZ(buf, "{d:.1} KB", .{@as(f64, @floatFromInt(size)) / 1024}) catch "?"
    else
        std.fmt.bufPrintZ(buf, "{d} B", .{size}) catch "?";
    return @ptrCast(s);
}

fn fmtTimeZ(buf: *[40:0]u8, ms: i64) [*:0]const u8 {
    var t: c.time_t = @intCast(@divTrunc(ms, 1000));
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return "";
    const n = c.strftime(buf, buf.len - 1, "%Y-%m-%d %H:%M", &tm);
    buf[n] = 0;
    return @ptrCast(buf);
}

test "parseSpec forms" {
    const t = std.testing;
    var l = parseSpec("/home/x");
    try t.expect(l.current_host and l.host == null);
    try t.expectEqualStrings("/home/x", l.path);
    l = parseSpec("nas:/srv/data");
    try t.expect(!l.current_host);
    try t.expectEqualStrings("nas", l.host.?);
    try t.expectEqualStrings("/srv/data", l.path);
    l = parseSpec("user@box:/p");
    try t.expectEqualStrings("user@box", l.host.?);
    l = parseSpec("udp:box:/p");
    try t.expectEqualStrings("udp:box", l.host.?);
    try t.expectEqualStrings("/p", l.path);
    l = parseSpec("local:/etc");
    try t.expect(l.host == null and !l.current_host);
    try t.expectEqualStrings("/etc", l.path);
}
