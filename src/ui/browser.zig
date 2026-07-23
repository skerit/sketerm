//! File-browser pane face (phase 3 of docs/filebrowser-roadmap.md).
//!
//! A BrowserView rides a regular terminal Pane as its second face:
//! the pane keeps its shell session (that IS "Open Terminal Here" —
//! one toggle away), the browser renders on top. Internal tab strip
//! per pane (the Nemo per-split-tabs model): browser tabs are cheap
//! VIEW state; the heavy session state stays with the pane.
//!
//! Async by construction: one non-blocking mux connection per view,
//! watched via g_unix_fd_add — the GLib loop is NEVER blocked on a
//! reply. Listings are subscriptions (fs_op open_view): pushed
//! fs_delta frames keep every visible directory live, including
//! tree-expanded subdirectories (expanded set == watch set).

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const fsserve = @import("../mux/fsserve.zig");
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
    root: *Dir,
    /// Expanded subdirectories (tree-expand-inline), each its own
    /// live view. Flat list; nesting is reconstructed by path at
    /// render time.
    subdirs: std.ArrayList(*Dir) = .empty,
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
                self.view.closeViewOf(d);
                _ = self.subdirs.swapRemove(i);
                d.deinit();
            } else i += 1;
        }
    }

    fn deinit(self: *BTab) void {
        const a = self.view.allocator;
        self.view.closeViewOf(self.root);
        for (self.subdirs.items) |d| {
            self.view.closeViewOf(d);
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

/// In-flight listing request (open_view or refresh `list`).
const Pending = struct {
    req: u32,
    tab: *BTab,
    /// Accumulating target; entries replace dir.entries when the
    /// chunk run ends.
    dir: *Dir,
    staged: std.ArrayList(Entry) = .empty,
};

pub const BrowserView = struct {
    allocator: std.mem.Allocator,
    pane: *Pane,
    conn: muxclient.Conn,
    watch_id: c.guint = 0,
    next_req: u32 = 1,
    next_view: u32 = 1,
    tabs: std.ArrayList(*BTab) = .empty,
    pending: std.ArrayList(*Pending) = .empty,
    show_hidden: bool = false,

    root_box: *c.GtkWidget = undefined,
    notebook: *c.GtkNotebook = undefined,
    path_entry: *c.GtkEntry = undefined,
    status_label: *c.GtkLabel = undefined,
    /// Copy-source path for the context menu's Copy/Paste (owned).
    clip_src: ?[]u8 = null,

    /// Create a browser face on `pane`, starting at `start_path`
    /// (absolute; "~" and relative fall back to $HOME).
    pub fn attach(allocator: std.mem.Allocator, pane: *Pane, start_path: ?[]const u8) !*BrowserView {
        const conn = muxclient.Conn.connectLocalAutostart(allocator) catch
            return error.DaemonUnreachable;
        const self = try allocator.create(BrowserView);
        self.* = .{ .allocator = allocator, .pane = pane, .conn = conn };
        errdefer allocator.destroy(self);

        const fl = c.fcntl(self.conn.fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(self.conn.fd, c.F_SETFL, fl | c.O_NONBLOCK);

        self.buildUi();
        pane.attachBrowser(self.root_box, @ptrCast(self), destroyCb);

        self.watch_id = c.g_unix_fd_add(
            self.conn.fd,
            c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&onFdReadable),
            @ptrCast(self),
        );

        const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/";
        const start = if (start_path) |p| (if (p.len > 0 and p[0] == '/') p else home) else home;
        _ = self.newTab(start);
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

    /// Internal tab paths in notebook order (layout persistence).
    pub fn tabPaths(self: *BrowserView, arena: std.mem.Allocator) ![]const []const u8 {
        const out = try arena.alloc([]const u8, self.tabs.items.len);
        for (self.tabs.items, 0..) |t, i| out[i] = try arena.dupe(u8, t.root.path);
        return out;
    }

    pub fn deinit(self: *BrowserView) void {
        if (self.watch_id != 0) _ = c.g_source_remove(self.watch_id);
        self.watch_id = 0;
        for (self.tabs.items) |t| t.deinit();
        self.tabs.deinit(self.allocator);
        for (self.pending.items) |p| {
            for (p.staged.items) |*e| e.deinit(self.allocator);
            p.staged.deinit(self.allocator);
            self.allocator.destroy(p);
        }
        self.pending.deinit(self.allocator);
        if (self.clip_src) |s| self.allocator.free(s);
        self.conn.deinit();
        self.allocator.destroy(self);
    }

    // ── wire plumbing ───────────────────────────────────────────

    fn sendOp(self: *BrowserView, op: []const u8, req: u32, path: []const u8, view_id: u32) void {
        self.conn.sendJson(.fs_op, .{
            .req = req,
            .op = op,
            .path = path,
            .view = view_id,
        }) catch self.setStatus("daemon connection lost");
    }

    fn sendOp2(self: *BrowserView, op: []const u8, req: u32, path: []const u8, to: []const u8) void {
        self.conn.sendJson(.fs_op, .{
            .req = req,
            .op = op,
            .path = path,
            .to = to,
        }) catch self.setStatus("daemon connection lost");
    }

    fn closeViewOf(self: *BrowserView, dir: *Dir) void {
        if (dir.view_id == 0) return;
        self.conn.sendJson(.fs_op, .{
            .req = @as(u32, 0),
            .op = "close_view",
            .view = dir.view_id,
        }) catch {};
    }

    /// Subscribe a directory and start collecting its listing.
    fn openDir(self: *BrowserView, tab: *BTab, dir: *Dir) void {
        const req = self.next_req;
        self.next_req +%= 1;
        const p = self.allocator.create(Pending) catch return;
        p.* = .{ .req = req, .tab = tab, .dir = dir };
        self.pending.append(self.allocator, p) catch {
            self.allocator.destroy(p);
            return;
        };
        self.sendOp("open_view", req, dir.path, dir.view_id);
    }

    fn onFdReadable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        _ = fd;
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
            self.setStatus("daemon connection lost");
            self.watch_id = 0;
            return 0; // remove source
        }
        if (!self.conn.fillAvailable()) {
            self.setStatus("daemon connection lost");
            self.watch_id = 0;
            return 0;
        }
        var dirty = false;
        while (self.conn.takeFrame() catch null) |f| {
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .fs_reply => {
                    if (self.onReply(f.payload)) dirty = true;
                },
                .fs_delta => {
                    if (self.onDelta(f.payload)) dirty = true;
                },
                .fs_job => self.onJobEvent(f.payload),
                else => {},
            }
        }
        if (dirty) self.renderCurrent();
        return 1;
    }

    /// Job progress in the status bar (deltas already update the
    /// listing itself when the copy lands).
    fn onJobEvent(self: *BrowserView, payload: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const Ev = struct {
            job: u64 = 0,
            ev: []const u8 = "",
            done: u64 = 0,
            total: u64 = 0,
            message: []const u8 = "",
        };
        const e = std.json.parseFromSliceLeaky(Ev, arena.allocator(), payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        if (std.mem.eql(u8, e.ev, "progress")) {
            self.setStatusFmt("copying… {d} / {d} MB", .{ e.done >> 20, e.total >> 20 });
        } else if (std.mem.eql(u8, e.ev, "done")) {
            self.setStatus("done");
        } else if (std.mem.eql(u8, e.ev, "error")) {
            self.setStatusFmt("job failed: {s}", .{e.message});
        }
    }

    fn onReply(self: *BrowserView, payload: []const u8) bool {
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

    fn onDelta(self: *BrowserView, payload: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const d = std.json.parseFromSliceLeaky(WireDelta, arena.allocator(), payload, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        for (self.tabs.items) |tab| {
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

    /// Refetch a live dir's entries without dropping its view: the
    /// one-shot `list` op reuses the Pending accumulation path.
    fn refreshDir(self: *BrowserView, tab: *BTab, dir: *Dir) void {
        const req = self.next_req;
        self.next_req +%= 1;
        const p = self.allocator.create(Pending) catch return;
        p.* = .{ .req = req, .tab = tab, .dir = dir };
        self.pending.append(self.allocator, p) catch {
            self.allocator.destroy(p);
            return;
        };
        self.sendOp("list", req, dir.path, 0);
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

    pub fn newTab(self: *BrowserView, path: []const u8) ?*BTab {
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
        c.gtk_label_set_max_width_chars(@ptrCast(label), 20);

        tab.* = .{
            .view = self,
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

    /// Navigate a tab to `path`. `push_history` false = back/forward
    /// traversal (history untouched).
    fn navigate(self: *BrowserView, tab: *BTab, path: []const u8, push_history: bool) void {
        if (std.mem.eql(u8, tab.root.path, path)) return;
        const new_dir = self.makeDir(path) orelse return;
        if (push_history) {
            const old = self.allocator.dupe(u8, tab.root.path) catch null;
            if (old) |o| tab.back.append(self.allocator, o) catch self.allocator.free(o);
            for (tab.fwd.items) |p| self.allocator.free(p);
            tab.fwd.clearRetainingCapacity();
        }
        tab.dropSubdirsUnder(tab.root.path);
        self.closeViewOf(tab.root);
        tab.root.deinit();
        tab.root = new_dir;
        self.updateTabLabel(tab);
        self.openDir(tab, new_dir);
        self.syncPathEntry(tab);
        self.renderTab(tab);
    }

    fn goBack(self: *BrowserView, tab: *BTab) void {
        const prev = tab.back.pop() orelse return;
        const cur = self.allocator.dupe(u8, tab.root.path) catch null;
        if (cur) |cp| tab.fwd.append(self.allocator, cp) catch self.allocator.free(cp);
        self.navigate(tab, prev, false);
        self.allocator.free(prev);
    }

    fn goForward(self: *BrowserView, tab: *BTab) void {
        const next = tab.fwd.pop() orelse return;
        const cur = self.allocator.dupe(u8, tab.root.path) catch null;
        if (cur) |cp| tab.back.append(self.allocator, cp) catch self.allocator.free(cp);
        self.navigate(tab, next, false);
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
        self.navigate(tab, copy, true);
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
        var buf: [128:0]u8 = undefined;
        const name = if (base.len == 0) "/" else base;
        const n = @min(name.len, buf.len - 1);
        @memcpy(buf[0..n], name[0..n]);
        buf[n] = 0;
        c.gtk_label_set_text(tab.tab_label, &buf);
    }

    fn syncPathEntry(self: *BrowserView, tab: *BTab) void {
        if (self.currentTab() != tab) return;
        var buf: [4096:0]u8 = undefined;
        const n = @min(tab.root.path.len, buf.len - 1);
        @memcpy(buf[0..n], tab.root.path[0..n]);
        buf[n] = 0;
        c.gtk_editable_set_text(@ptrCast(self.path_entry), &buf);
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
        if (ctx.is_dir) {
            // navigate() frees rows (and this ctx) — copy the path out.
            var buf: [4096]u8 = undefined;
            if (ctx.path.len >= buf.len) return;
            @memcpy(buf[0..ctx.path.len], ctx.path);
            const path = buf[0..ctx.path.len];
            tab.view.navigate(tab, path, true);
        } else {
            // Open with the default local application (local files —
            // this connection browses the local daemon's host).
            var uri_buf: [4200:0]u8 = undefined;
            const uri = std.fmt.bufPrintZ(&uri_buf, "file://{s}", .{ctx.path}) catch return;
            _ = c.g_app_info_launch_default_for_uri(uri.ptr, null, null);
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
        if (ctx.path != null) {
            if (is_dir) {
                menuButton(box, "Open Terminal Here", &onMenuTerminalHere, ctx, false);
                menuButton(box, "Open in New Browser Tab", &onMenuOpenTab, ctx, false);
            }
            menuButton(box, "Copy", &onMenuCopy, ctx, false);
            menuButton(box, "Copy Path", &onMenuCopyPath, ctx, false);
            menuButton(box, "Rename…", &onMenuRename, ctx, false);
            menuButton(box, "Delete…", &onMenuDelete, ctx, true);
        }
        if (self.clip_src != null)
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
        if (ctx.path) |p| _ = ctx.view.newTab(p);
        menuDone(ctx);
    }

    fn onMenuCopy(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const path = ctx.path orelse return menuDone(ctx);
        if (ctx.view.clip_src) |s| ctx.view.allocator.free(s);
        ctx.view.clip_src = ctx.view.allocator.dupe(u8, path) catch null;
        ctx.view.setStatusFmt("copied: {s}", .{path});
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
        const src = self.clip_src orelse return menuDone(ctx);
        const base = std.fs.path.basename(src);
        var dst_buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&dst_buf);
        const dir = ctx.tab.root.path;
        // Same-name collision in the target listing → "-copy" suffix
        // instead of a silent overwrite.
        const collides = ctx.tab.root.find(base) != null;
        w.print("{s}/{s}{s}", .{ if (dir.len == 1) "" else dir, base, if (collides) "-copy" else "" }) catch return menuDone(ctx);
        const req = self.next_req;
        self.next_req +%= 1;
        self.conn.sendJson(.fs_op, .{
            .req = req,
            .op = "copy",
            .path = src,
            .to = w.buffered(),
        }) catch self.setStatus("daemon connection lost");
        self.setStatus("copying…");
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
        const req = self.next_req;
        self.next_req +%= 1;
        self.conn.sendJson(.fs_op, .{
            .req = req,
            .op = if (ctx.is_dir) "delete_tree" else "delete",
            .path = path,
        }) catch self.setStatus("daemon connection lost");
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
        const req = self.next_req;
        self.next_req +%= 1;
        switch (ctx.mode) {
            .mkdir => {
                const dir = ctx.tab.root.path;
                w.print("{s}/{s}", .{ if (dir.len == 1) "" else dir, name }) catch return menuDone(ctx);
                self.conn.sendJson(.fs_op, .{ .req = req, .op = "mkdir", .path = w.buffered() }) catch
                    self.setStatus("daemon connection lost");
            },
            .rename => {
                const old = ctx.path orelse return menuDone(ctx);
                const dir = std.fs.path.dirname(old) orelse return menuDone(ctx);
                w.print("{s}/{s}", .{ if (dir.len == 1) "" else dir, name }) catch return menuDone(ctx);
                self.conn.sendJson(.fs_op, .{ .req = req, .op = "rename", .path = old, .to = w.buffered() }) catch
                    self.setStatus("daemon connection lost");
            },
            .none => {},
        }
        menuDone(ctx);
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

        const status = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(status), 0);
        c.gtk_widget_add_css_class(status, "dim-label");
        c.gtk_widget_set_margin_start(status, 6);
        c.gtk_widget_set_margin_bottom(status, 2);
        c.gtk_box_append(@ptrCast(vbox), status);

        self.root_box = vbox;
        self.notebook = @ptrCast(@alignCast(notebook));
        self.path_entry = @ptrCast(@alignCast(entry));
        self.status_label = @ptrCast(@alignCast(status));
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
        const start = if (self.currentTab()) |t| t.root.path else "/";
        _ = self.newTab(start);
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
        const path = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        if (path.len == 0 or path[0] != '/') {
            self.setStatus("path must be absolute");
            return;
        }
        self.navigate(tab, path, true);
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
