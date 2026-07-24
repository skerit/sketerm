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
const browser_model = @import("../filebrowser/model.zig");
const fsjob = @import("../mux/fsjob.zig");
const mounts = @import("../util/mounts.zig");
const input = @import("input.zig");
const Pane = @import("pane.zig").Pane;

/// One owned directory entry (strings owned by the Dir's allocator).
const Entry = struct {
    name: []u8,
    kind: []u8,
    size: u64,
    mode: u32,
    mtime_ms: i64,
    atime_ms: i64 = 0,
    ctime_ms: i64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u64 = 1,
    blocks: u64 = 0,
    target: ?[]u8,
    tdir: bool,
    tags: []u8 = &.{},

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        if (self.target) |t| allocator.free(t);
        if (self.tags.len > 0) allocator.free(self.tags);
    }
};

/// Wire mirror of the fs_reply fields the browser consumes.
const WireEntry = struct {
    name: []const u8 = "",
    kind: []const u8 = "",
    size: u64 = 0,
    mode: u32 = 0,
    mtime_ms: i64 = 0,
    atime_ms: i64 = 0,
    ctime_ms: i64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u64 = 1,
    blocks: u64 = 0,
    target: ?[]const u8 = null,
    tdir: bool = false,
    tags: []const u8 = "",
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
    size: u64 = 0,
    eof: bool = false,
    apps: []WireApp = &.{},
};

/// One host-side application (daemon `apps` op reply).
const WireApp = struct {
    name: []const u8 = "",
    exec: []const u8 = "",
    mimes: []const u8 = "",
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
    path: []const u8 = "",
    line: u64 = 0,
    text: []const u8 = "",
    kind: []const u8 = "",
    size: u64 = 0,
    mtime_ms: i64 = 0,
    matches: u64 = 0,
    truncated: bool = false,
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

/// A network-mount bypass hit: (mountpoint under `path`) rewritten
/// to direct mux access on the mount's source host.
pub const BypassHit = struct {
    host_buf: [256]u8 = undefined,
    host_len: usize = 0,
    path_buf: [4096]u8 = undefined,
    path_len: usize = 0,
    mp_buf: [1024]u8 = undefined,
    mp_len: usize = 0,

    pub fn host(self: *const BypassHit) []const u8 {
        return self.host_buf[0..self.host_len];
    }
    pub fn path(self: *const BypassHit) []const u8 {
        return self.path_buf[0..self.path_len];
    }
    pub fn mountpoint(self: *const BypassHit) []const u8 {
        return self.mp_buf[0..self.mp_len];
    }
};

/// Decode /proc/mounts octal escapes (\040 = space, …) in place.
fn unescapeMnt(buf: []u8, src: []const u8) []const u8 {
    var w: usize = 0;
    var r: usize = 0;
    while (r < src.len and w < buf.len) {
        if (src[r] == '\\' and r + 3 < src.len) {
            const v = std.fmt.parseInt(u8, src[r + 1 .. r + 4], 8) catch {
                buf[w] = src[r];
                w += 1;
                r += 1;
                continue;
            };
            buf[w] = v;
            w += 1;
            r += 4;
        } else {
            buf[w] = src[r];
            w += 1;
            r += 1;
        }
    }
    return buf[0..w];
}

/// Detect an sshfs/NFS mount covering `p` and rewrite to direct mux
/// access: the mount source ("user@host:/remote") names both the ssh
/// host and the remote prefix. Longest mountpoint wins. Linux-only
/// (/proc/mounts); false elsewhere.
pub fn mountBypass(p: []const u8, out: *BypassHit) bool {
    var hit: mounts.Hit = .{};
    if (!mounts.detect(p, &hit)) return false;
    @memcpy(out.host_buf[0..hit.host_len], hit.host());
    out.host_len = hit.host_len;
    @memcpy(out.path_buf[0..hit.path_len], hit.path());
    out.path_len = hit.path_len;
    @memcpy(out.mp_buf[0..hit.mount_len], hit.mountpoint());
    out.mp_len = hit.mount_len;
    return true;
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
    /// Search-results mode: entries are FLAT rows whose full path
    /// lives in `target` (no subscription, no expanders).
    flat: bool = false,
    /// Collection mode: flat rows whose `target` is a host-qualified
    /// SPEC ("host:/path" or "/path") — entries span hosts.
    collection: bool = false,

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
        const tags: []u8 = if (we.tags.len > 0) (a.dupe(u8, we.tags) catch @constCast("")) else @constCast("");
        return .{
            .name = name,
            .kind = kind,
            .size = we.size,
            .mode = we.mode,
            .mtime_ms = we.mtime_ms,
            .atime_ms = we.atime_ms,
            .ctime_ms = we.ctime_ms,
            .uid = we.uid,
            .gid = we.gid,
            .nlink = we.nlink,
            .blocks = we.blocks,
            .target = tgt,
            .tdir = we.tdir,
            .tags = tags,
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
    selected: std.ArrayList([]u8) = .empty,
    rendering: bool = false,
    show_hidden: bool = false,
    view_mode: browser_model.ViewMode = .details,
    sort_key: browser_model.SortKey = .name,
    descending: bool = false,
    dirs_first: bool = true,
    filter: []u8 = &.{},
    virtual_spec: []u8 = &.{},
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
                self.view.cancelPendingDir(d);
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
        self.view.cancelPendingDir(self.root);
        self.view.closeViewOf(self.hc, self.root);
        for (self.subdirs.items) |d| {
            self.view.cancelPendingDir(d);
            self.view.closeViewOf(self.hc, d);
            d.deinit();
        }
        self.subdirs.deinit(a);
        self.root.deinit();
        for (self.back.items) |p| a.free(p);
        self.back.deinit(a);
        for (self.fwd.items) |p| a.free(p);
        self.fwd.deinit(a);
        for (self.selected.items) |p| a.free(p);
        self.selected.deinit(a);
        if (self.filter.len > 0) a.free(self.filter);
        if (self.virtual_spec.len > 0) a.free(self.virtual_spec);
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
    kind: enum { normal, search, compare_left, compare_right } = .normal,
};

/// One client-mediated cross-host transfer, running or queued.
const ActiveTransfer = struct {
    x: *fstransfer.Xfer,
    src_hc: *HostConn,
    dst_hc: *HostConn,
    label: []u8,
    /// Launch the local destination file when the transfer lands
    /// (remote-file open-with-default path).
    open_when_done: bool = false,
    /// Launch with this specific application id instead of the
    /// default handler (owned; Open With chooser).
    open_with_appid: ?[]u8 = null,
    /// Register a local-edit sync-back watch on the destination when
    /// the download lands (owned remote source host + path).
    watch_host: ?[]u8 = null,
    watch_remote: ?[]u8 = null,
    /// This transfer IS a sync-back upload for that watch (clears
    /// its uploading flag on completion).
    upload_watch: ?*EditWatch = null,
    /// Queue state: at most MAX_ACTIVE_TRANSFERS run concurrently;
    /// the rest wait here in order.
    started: bool = false,

    fn freeExtras(t: *ActiveTransfer, allocator: std.mem.Allocator) void {
        if (t.open_with_appid) |s| allocator.free(s);
        if (t.watch_host) |s| allocator.free(s);
        if (t.watch_remote) |s| allocator.free(s);
    }
};

/// A remote file opened locally: its cache copy is monitored, and a
/// local edit uploads back to the host (staged, hash-verified).
const EditWatch = struct {
    view: *BrowserView,
    /// The remote host string the file came from.
    host: []u8,
    remote_path: []u8,
    cache_path: []u8,
    monitor: ?*c.GFileMonitor = null,
    uploading: bool = false,

    fn destroy(self: *EditWatch, allocator: std.mem.Allocator) void {
        if (self.monitor) |m| {
            _ = c.g_file_monitor_cancel(m);
            c.g_object_unref(m);
        }
        allocator.free(self.host);
        allocator.free(self.remote_path);
        allocator.free(self.cache_path);
        allocator.destroy(self);
    }
};

/// Concurrent client-mediated transfers; more queue in order.
const MAX_ACTIVE_TRANSFERS = 2;

/// Two-tree compare/sync: both trees are scanned HOST-SIDE (find
/// jobs streaming path+kind+size+mtime digests — only digests cross
/// the wire), diffed client-side, and reconciled with per-row
/// direction choices executed as jobs/transfers. Copy-only: no
/// deletes, so a wrong direction cannot destroy data.
const CompareCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    left: CmpSide,
    right: CmpSide,
    window: ?*c.GtkWidget = null,
    listbox: *c.GtkListBox = undefined,
    info_label: *c.GtkLabel = undefined,
    excl_entry: *c.GtkEntry = undefined,
    rows: std.ArrayList(*DiffRow) = .empty,
    built: bool = false,

    const CmpSide = struct {
        hc: *HostConn,
        root: []u8,
        job: u64 = 0,
        done: bool = false,
        failed: bool = false,
        truncated: bool = false,
        /// rel path (owned) -> digest.
        entries: std.StringHashMapUnmanaged(CmpInfo) = .empty,
    };
    const CmpInfo = struct { dir: bool, size: u64, mtime_ms: i64 };
    const DiffStatus = enum { left_only, right_only, differs };
    const Action = enum(c.guint) { skip = 0, to_right = 1, to_left = 2 };
    const DiffRow = struct {
        rel: []u8,
        dir: bool,
        status: DiffStatus,
        l: ?CmpInfo,
        r: ?CmpInfo,
        dd: *c.GtkWidget,
    };

    fn sideFor(self: *CompareCtx, hc: *HostConn, job: u64) ?*CmpSide {
        if (self.left.hc == hc and self.left.job == job and job != 0) return &self.left;
        if (self.right.hc == hc and self.right.job == job and job != 0) return &self.right;
        return null;
    }

    fn sideFailed(self: *CompareCtx, is_left: bool) void {
        const s = if (is_left) &self.left else &self.right;
        s.failed = true;
        s.done = true;
        c.gtk_label_set_text(self.info_label, "scan failed — see status bar");
    }

    /// Digest/completion events for the two scan jobs. Match events
    /// are consumed; done/error also fall through to the jobs panel.
    fn consumeJobEvent(self: *CompareCtx, hc: *HostConn, e: WireJobEv) bool {
        const side = self.sideFor(hc, e.job) orelse return false;
        if (std.mem.eql(u8, e.ev, "match")) {
            self.record(side, e);
            return true;
        }
        if (std.mem.eql(u8, e.ev, "done")) {
            side.done = true;
            side.truncated = e.truncated;
            self.maybeBuild();
            return false;
        }
        if (std.mem.eql(u8, e.ev, "error") or std.mem.eql(u8, e.ev, "canceled")) {
            side.failed = true;
            side.done = true;
            c.gtk_label_set_text(self.info_label, "scan failed or canceled");
            return false;
        }
        return false;
    }

    fn record(self: *CompareCtx, side: *CmpSide, e: WireJobEv) void {
        if (!std.mem.startsWith(u8, e.path, side.root)) return;
        var rel = e.path[side.root.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (rel.len == 0) return;
        const gop = side.entries.getOrPut(self.allocator, rel) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, rel) catch {
                _ = side.entries.remove(rel);
                return;
            };
        }
        gop.value_ptr.* = .{
            .dir = std.mem.eql(u8, e.kind, "dir"),
            .size = e.size,
            .mtime_ms = e.mtime_ms,
        };
    }

    fn maybeBuild(self: *CompareCtx) void {
        if (self.built or !self.left.done or !self.right.done) return;
        if (self.left.failed or self.right.failed) return;
        self.built = true;
        self.buildDiff();
    }

    fn addRow(self: *CompareCtx, rel: []const u8, status: DiffStatus, l: ?CmpInfo, r: ?CmpInfo) void {
        const is_dir = if (l) |i| i.dir else if (r) |i| i.dir else false;
        // Default direction: copy from the side that has it; for a
        // content difference the newer side wins.
        var action: Action = switch (status) {
            .left_only => .to_right,
            .right_only => .to_left,
            .differs => if (l.?.mtime_ms >= r.?.mtime_ms) .to_right else .to_left,
        };
        if (is_dir and status == .differs) action = .skip;

        const row = self.allocator.create(DiffRow) catch return;
        const rel_owned = self.allocator.dupe(u8, rel) catch {
            self.allocator.destroy(row);
            return;
        };

        const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_set_margin_start(hbox, 6);
        c.gtk_widget_set_margin_end(hbox, 6);
        var lblz: [640:0]u8 = undefined;
        var szl: [48:0]u8 = undefined;
        var szr: [48:0]u8 = undefined;
        const desc = switch (status) {
            .left_only => std.fmt.bufPrintZ(&lblz, "{s}{s}  [only in source{s}]", .{
                rel, if (is_dir) "/" else "", if (is_dir) "" else (std.fmt.bufPrintZ(&szl, ", {d} B", .{l.?.size}) catch ""),
            }) catch "?",
            .right_only => std.fmt.bufPrintZ(&lblz, "{s}{s}  [only in target{s}]", .{
                rel, if (is_dir) "/" else "", if (is_dir) "" else (std.fmt.bufPrintZ(&szr, ", {d} B", .{r.?.size}) catch ""),
            }) catch "?",
            .differs => std.fmt.bufPrintZ(&lblz, "{s}  [differs: {s} vs {s}{s}]", .{
                rel,
                fmtSize(&szl, l.?.size),
                fmtSize(&szr, r.?.size),
                if (l.?.mtime_ms >= r.?.mtime_ms) ", source newer" else ", target newer",
            }) catch "?",
        };
        const lab = c.gtk_label_new(desc.ptr);
        c.gtk_label_set_xalign(@ptrCast(lab), 0);
        c.gtk_widget_set_hexpand(lab, 1);
        c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_box_append(@ptrCast(hbox), lab);

        const options = [_:null]?[*:0]const u8{ "Skip", "Copy to target", "Copy to source" };
        const dd = c.gtk_drop_down_new_from_strings(@ptrCast(&options));
        c.gtk_drop_down_set_selected(@ptrCast(dd), @intFromEnum(action));
        c.gtk_box_append(@ptrCast(hbox), dd);

        const lrow = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(lrow), hbox);
        c.gtk_list_box_append(self.listbox, lrow);

        row.* = .{ .rel = rel_owned, .dir = is_dir, .status = status, .l = l, .r = r, .dd = dd };
        self.rows.append(self.allocator, row) catch {
            self.allocator.free(rel_owned);
            self.allocator.destroy(row);
        };
    }

    fn buildDiff(self: *CompareCtx) void {
        // Deterministic order: parents before children (path sort).
        var rels: std.ArrayList([]const u8) = .empty;
        defer rels.deinit(self.allocator);
        var itl = self.left.entries.iterator();
        while (itl.next()) |kv| rels.append(self.allocator, kv.key_ptr.*) catch {};
        var itr = self.right.entries.iterator();
        while (itr.next()) |kv| {
            if (self.left.entries.get(kv.key_ptr.*) == null)
                rels.append(self.allocator, kv.key_ptr.*) catch {};
        }
        std.mem.sort([]const u8, rels.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        var ndiff: usize = 0;
        for (rels.items) |rel| {
            const l = self.left.entries.get(rel);
            const r = self.right.entries.get(rel);
            if (l != null and r == null) {
                self.addRow(rel, .left_only, l, null);
                ndiff += 1;
            } else if (l == null and r != null) {
                self.addRow(rel, .right_only, null, r);
                ndiff += 1;
            } else if (l != null and r != null) {
                if (l.?.dir or r.?.dir) continue;
                const differs = l.?.size != r.?.size or
                    @abs(l.?.mtime_ms - r.?.mtime_ms) > 2000;
                if (differs) {
                    self.addRow(rel, .differs, l, r);
                    ndiff += 1;
                }
            }
        }
        var info: [256:0]u8 = undefined;
        const trunc = self.left.truncated or self.right.truncated;
        const txt = if (ndiff == 0)
            std.fmt.bufPrintZ(&info, "Trees are identical ({d} entries scanned).{s}", .{
                self.left.entries.count() + self.right.entries.count(),
                if (trunc) " WARNING: scan truncated at 2000 entries/side — comparison is PARTIAL." else "",
            }) catch "identical"
        else
            std.fmt.bufPrintZ(&info, "{d} difference(s). Review directions, then Execute.{s}", .{
                ndiff,
                if (trunc) " WARNING: scan truncated at 2000 entries/side — comparison is PARTIAL." else "",
            }) catch "differences found";
        c.gtk_label_set_text(self.info_label, txt.ptr);
    }

    /// Comma-separated exclusion globs against the rel path.
    fn excluded(self: *CompareCtx, rel: []const u8) bool {
        const txt = c.gtk_editable_get_text(@ptrCast(self.excl_entry));
        const pats = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        var it = std.mem.tokenizeScalar(u8, pats, ',');
        while (it.next()) |p_raw| {
            const p = std.mem.trim(u8, p_raw, " ");
            if (p.len == 0) continue;
            if (fsjob.nameMatches(p, rel)) return true;
            if (fsjob.nameMatches(p, std.fs.path.basename(rel))) return true;
        }
        return false;
    }

    fn execute(self: *CompareCtx) void {
        const view = self.view;
        const same_host = hostEq(self.left.hc.host, self.right.hc.host);
        var started: usize = 0;
        var excluded_n: usize = 0;
        for (self.rows.items) |row| {
            const action: Action = switch (c.gtk_drop_down_get_selected(@ptrCast(row.dd))) {
                1 => .to_right,
                2 => .to_left,
                else => .skip,
            };
            if (action == .skip) continue;
            if (self.excluded(row.rel)) {
                excluded_n += 1;
                continue;
            }
            const src_side = if (action == .to_right) &self.left else &self.right;
            const dst_side = if (action == .to_right) &self.right else &self.left;
            var src_buf: [4096]u8 = undefined;
            var dst_buf: [4096]u8 = undefined;
            const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src_side.root, row.rel }) catch continue;
            const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dst_side.root, row.rel }) catch continue;
            if (row.dir) {
                // Rows are path-sorted, so parent dirs mkdir before
                // their children copy.
                view.sendOp(dst_side.hc, .{ .req = view.nextReq(), .op = "mkdir", .path = dst });
                started += 1;
                continue;
            }
            if (same_host) {
                var lbl: [128]u8 = undefined;
                const label = std.fmt.bufPrint(&lbl, "sync {s}", .{std.fs.path.basename(row.rel)}) catch "sync";
                view.startDaemonJob(dst_side.hc, "copy", src, dst, label);
            } else {
                view.startTransfer(src_side.hc, src, dst_side.hc, dst, .{});
            }
            started += 1;
        }
        view.setStatusFmt("sync: {d} operation(s) started, {d} excluded", .{ started, excluded_n });
        self.close();
    }

    fn close(self: *CompareCtx) void {
        if (self.window) |w| {
            self.window = null;
            c.gtk_window_destroy(@ptrCast(w));
        }
    }

    /// g_object destroy-notify on the window: final cleanup.
    fn free(user: ?*anyopaque) callconv(.c) void {
        const self: *CompareCtx = @ptrCast(@alignCast(user.?));
        if (self.view.compare == self) self.view.compare = null;
        self.window = null;
        for (self.rows.items) |row| {
            self.allocator.free(row.rel);
            self.allocator.destroy(row);
        }
        self.rows.deinit(self.allocator);
        freeSide(self.allocator, &self.left);
        freeSide(self.allocator, &self.right);
        self.allocator.destroy(self);
    }

    fn freeSide(allocator: std.mem.Allocator, side: *CmpSide) void {
        var it = side.entries.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        side.entries.deinit(allocator);
        allocator.free(side.root);
    }

    fn onExecuteClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *CompareCtx = @ptrCast(@alignCast(user.?));
        self.execute();
    }
    fn onCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *CompareCtx = @ptrCast(@alignCast(user.?));
        self.close();
    }
};

/// One in-flight remote preview fetch (chunked fs read).
const PreviewRead = struct {
    req: u32,
    hc: *HostConn,
    path: []u8,
    is_image: bool,
    cap: usize,
    off: u64 = 0,
    buf: std.ArrayList(u8) = .empty,

    fn destroy(self: *PreviewRead, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Extensions the preview pane and row thumbnails treat as images
/// (decodable by gdk-pixbuf).
fn isImageName(name: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".ico", ".tiff" };
    for (exts) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

/// Content caps: whole image (bounded) vs a text head.
const PREVIEW_IMAGE_CAP: usize = 8 << 20;
const PREVIEW_TEXT_CAP: usize = 4096;
/// Row thumbnails decode local images up to this size.
const THUMB_FILE_CAP: u64 = 8 << 20;
const THUMB_CACHE_CAP: usize = 256;

pub const HostAction = *const fn (ctx: *anyopaque, host: []const u8, path: []const u8) void;

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

    root_box: *c.GtkWidget = undefined,
    notebook: *c.GtkNotebook = undefined,
    path_entry: *c.GtkEntry = undefined,
    status_label: *c.GtkLabel = undefined,
    jobs_box: *c.GtkWidget = undefined,
    /// Copy-source for the context menu's Copy/Paste (owned).
    /// clip_paths holds the full multi-selection; clip_path mirrors
    /// its first item (single-source verbs: Sync Here, Compare).
    clip_host: ?[]u8 = null,
    clip_path: ?[]u8 = null,
    clip_paths: std.ArrayList([]u8) = .empty,
    search_bar: *c.GtkWidget = undefined,
    search_entry: *c.GtkEntry = undefined,
    search_content: *c.GtkWidget = undefined,
    hidden_toggle: *c.GtkToggleButton = undefined,
    /// Preview side panel (toggleable): metadata always, image or
    /// text-head content when recognizably previewable.
    preview_box: *c.GtkWidget = undefined,
    preview_pic: *c.GtkWidget = undefined,
    preview_text: *c.GtkLabel = undefined,
    preview_meta: *c.GtkLabel = undefined,
    preview_on: bool = false,
    preview_read: ?*PreviewRead = null,
    /// Row-thumbnail cache: "path\x00mtime" -> owned texture ref.
    thumbs: std.StringHashMap(*c.GdkTexture) = undefined,
    /// Live local-edit sync-back watches (remote files opened here).
    watches: std.ArrayList(*EditWatch) = .empty,
    /// The one open Open With chooser (its popover owns the ctx).
    openwith: ?*OpenWithCtx = null,
    /// The one open compare/sync window.
    compare: ?*CompareCtx = null,
    switch_idle: c.guint = 0,
    /// Running search job (0 = none) and its host + results tab.
    search_job: u64 = 0,
    search_hc: ?*HostConn = null,
    search_tab: ?*BTab = null,
    collection_tab: ?*BTab = null,
    /// Window-level abilities, installed by the owning Window.
    hooks_ctx: ?*anyopaque = null,
    on_host_term: ?HostAction = null,
    on_host_open: ?HostAction = null,
    /// Run a shell command as an app session on a host (declarative
    /// .action files with RunsOnHost).
    on_host_exec: ?HostAction = null,

    /// Create a browser face on `pane`, starting at `start_spec`
    /// (a path or host-qualified spec; null/relative = $HOME).
    pub fn attach(allocator: std.mem.Allocator, pane: *Pane, start_spec: ?[]const u8) !*BrowserView {
        const self = try allocator.create(BrowserView);
        self.* = .{ .allocator = allocator, .pane = pane };
        self.thumbs = std.StringHashMap(*c.GdkTexture).init(allocator);

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

    fn refForTab(arena: std.mem.Allocator, tab: *BTab, path: []const u8) !browser_model.FileRef {
        return .{
            .host = if (tab.hc.host) |h| try arena.dupe(u8, h) else "",
            .path = try arena.dupe(u8, path),
        };
    }

    fn historyRefs(arena: std.mem.Allocator, current_host: []const u8, specs: []const []u8) ![]const browser_model.FileRef {
        const out = try arena.alloc(browser_model.FileRef, specs.len);
        for (specs, 0..) |spec, i| out[i] = try browser_model.dupeRef(arena, browser_model.parseSpec(spec, current_host).ref);
        return out;
    }

    /// Full GTK-free state projection used by layout persistence.
    pub fn paneState(self: *BrowserView, arena: std.mem.Allocator) !browser_model.PaneState {
        const tabs = try arena.alloc(browser_model.TabState, self.tabs.items.len);
        for (self.tabs.items, 0..) |tab, i| {
            const host = tab.hc.host orelse "";
            const expanded = try arena.alloc(browser_model.FileRef, tab.subdirs.items.len);
            for (tab.subdirs.items, 0..) |d, j| expanded[j] = try refForTab(arena, tab, d.path);
            const selected = try arena.alloc(browser_model.FileRef, tab.selected.items.len);
            for (tab.selected.items, 0..) |p, j| selected[j] = try refForTab(arena, tab, p);
            tabs[i] = .{
                .kind = if (tab.root.collection) .collection else if (tab.root.flat) .search else .directory,
                .location = try refForTab(arena, tab, tab.root.path),
                .back = try historyRefs(arena, host, tab.back.items),
                .forward = try historyRefs(arena, host, tab.fwd.items),
                .expanded = expanded,
                .selected = selected,
                .view = tab.view_mode,
                .sort = tab.sort_key,
                .descending = tab.descending,
                .dirs_first = tab.dirs_first,
                .show_hidden = tab.show_hidden,
                .filter = try arena.dupe(u8, tab.filter),
                .virtual_spec = try arena.dupe(u8, tab.virtual_spec),
            };
        }
        const active = c.gtk_notebook_get_current_page(self.notebook);
        return .{
            .active_tab = if (active >= 0) @intCast(active) else 0,
            .tabs = tabs,
        };
    }

    fn appendHistoryRef(self: *BrowserView, list: *std.ArrayList([]u8), ref: browser_model.FileRef) void {
        var buf: [4300]u8 = undefined;
        const spec = ref.format(&buf) catch return;
        const owned = self.allocator.dupe(u8, spec) catch return;
        list.append(self.allocator, owned) catch self.allocator.free(owned);
    }

    fn restoreTabState(self: *BrowserView, tab: *BTab, state: browser_model.TabState) void {
        for (state.back) |ref| self.appendHistoryRef(&tab.back, ref);
        for (state.forward) |ref| self.appendHistoryRef(&tab.fwd, ref);
        for (state.selected) |ref| {
            if (!std.mem.eql(u8, ref.host, tab.hc.host orelse "")) continue;
            const p = self.allocator.dupe(u8, ref.path) catch continue;
            tab.selected.append(self.allocator, p) catch self.allocator.free(p);
        }
        tab.show_hidden = state.show_hidden;
        tab.view_mode = state.view;
        tab.sort_key = state.sort;
        tab.descending = state.descending;
        tab.dirs_first = state.dirs_first;
        if (state.filter.len > 0) tab.filter = self.allocator.dupe(u8, state.filter) catch &.{};
        if (state.virtual_spec.len > 0) tab.virtual_spec = self.allocator.dupe(u8, state.virtual_spec) catch &.{};
        for (state.expanded) |ref| {
            if (!std.mem.eql(u8, ref.host, tab.hc.host orelse "")) continue;
            if (tab.subdirByPath(ref.path) != null) continue;
            const d = self.makeDir(ref.path) orelse continue;
            tab.subdirs.append(self.allocator, d) catch {
                d.deinit();
                continue;
            };
            self.openDir(tab, d);
        }
    }

    /// Restore the versioned browser model, retaining location-only layout compatibility.
    pub fn attachState(allocator: std.mem.Allocator, pane: *Pane, state: browser_model.PaneState) !*BrowserView {
        if (state.tabs.len == 0) return attach(allocator, pane, null);
        var first_buf: [4300]u8 = undefined;
        const self = try attach(allocator, pane, try state.tabs[0].location.format(&first_buf));
        self.restoreTabState(self.tabs.items[0], state.tabs[0]);
        for (state.tabs[1..]) |ts| {
            var buf: [4300]u8 = undefined;
            const tab = self.newTabSpec(ts.location.format(&buf) catch continue) orelse continue;
            self.restoreTabState(tab, ts);
        }
        if (state.active_tab < self.tabs.items.len)
            c.gtk_notebook_set_current_page(self.notebook, @intCast(state.active_tab));
        if (self.currentTab()) |tab|
            c.gtk_toggle_button_set_active(self.hidden_toggle, @intFromBool(tab.show_hidden));
        return self;
    }

    pub fn deinit(self: *BrowserView) void {
        if (self.switch_idle != 0) {
            _ = c.g_source_remove(self.switch_idle);
            self.switch_idle = 0;
        }
        for (self.transfers.items) |t| {
            t.x.deinit();
            self.allocator.free(t.label);
            t.freeExtras(self.allocator);
            self.allocator.destroy(t);
        }
        self.transfers.deinit(self.allocator);
        for (self.watches.items) |wt| wt.destroy(self.allocator);
        self.watches.deinit(self.allocator);
        if (self.compare) |cmp| cmp.close();
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
        for (self.clip_paths.items) |p| self.allocator.free(p);
        self.clip_paths.deinit(self.allocator);
        if (self.preview_read) |pr| pr.destroy(self.allocator);
        self.clearThumbCache();
        self.thumbs.deinit();
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
        self.pumpTransferQueue();
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
                if (t.upload_watch) |wt| wt.uploading = false;
                t.x.deinit();
                self.allocator.free(t.label);
                t.freeExtras(self.allocator);
                self.allocator.destroy(t);
                _ = self.transfers.orderedRemove(i);
            } else i += 1;
        }
        if (self.preview_read) |pr| {
            if (pr.hc == hc) self.abandonPreviewRead();
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
            if (self.feedPreview(hc, f.ftype, f.payload)) continue;
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

    /// Start queued transfers while below the concurrency cap.
    fn pumpTransferQueue(self: *BrowserView) void {
        var running: usize = 0;
        for (self.transfers.items) |t| {
            if (t.started and !t.x.isTerminal()) running += 1;
        }
        for (self.transfers.items) |t| {
            if (running >= MAX_ACTIVE_TRANSFERS) break;
            if (t.started or t.x.isTerminal()) continue;
            if (t.src_hc.state != .ready or t.dst_hc.state != .ready) continue;
            t.started = true;
            t.x.start();
            running += 1;
            self.setStatusFmt("transfer started: {s}", .{t.label});
        }
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
            if (t.upload_watch) |wt| {
                wt.uploading = false;
                if (t.x.ok()) {
                    self.setStatusFmt("synced back: {s}", .{std.fs.path.basename(wt.remote_path)});
                } else if (t.x.state != .canceled) {
                    self.setStatusFmt("sync-back failed: {s} ({s})", .{ t.label, t.x.errMsg() });
                }
            } else if (t.x.ok()) {
                self.setStatusFmt("transfer done: {s}", .{t.label});
                if (t.open_when_done) {
                    if (t.open_with_appid) |appid| {
                        launchLocalWithApp(appid, t.x.dst_root);
                    } else {
                        launchLocal(t.x.dst_root);
                    }
                    if (t.watch_host != null and t.watch_remote != null)
                        self.registerEditWatch(t.watch_host.?, t.watch_remote.?, t.x.dst_root);
                }
            } else if (t.x.state == .canceled) {
                self.setStatusFmt("transfer canceled: {s}", .{t.label});
            } else {
                self.setStatusFmt("transfer failed: {s} ({s})", .{ t.label, t.x.errMsg() });
            }
            t.x.deinit();
            self.allocator.free(t.label);
            t.freeExtras(self.allocator);
            self.allocator.destroy(t);
            _ = self.transfers.orderedRemove(i);
        }
        self.pumpTransferQueue();
    }

    const TransferOpts = struct {
        open_when_done: bool = false,
        /// Launch with a specific application id (duped in).
        open_with_appid: ?[]const u8 = null,
        /// Register a sync-back watch on the landed download.
        watch_host: ?[]const u8 = null,
        watch_remote: ?[]const u8 = null,
        /// This transfer is a sync-back upload for that watch.
        upload_watch: ?*EditWatch = null,
    };

    fn startTransfer(
        self: *BrowserView,
        src_hc: *HostConn,
        src_path: []const u8,
        dst_hc: *HostConn,
        dst_path: []const u8,
        opts: TransferOpts,
    ) void {
        const open_when_done = opts.open_when_done;
        if (src_hc.state != .ready or dst_hc.state != .ready) {
            self.setStatus("both hosts must be connected — retry in a moment");
            return;
        }
        if (!open_when_done and opts.upload_watch == null) {
            // User copies are coordinated by the local daemon, not this
            // BrowserView. They therefore survive pane/window teardown and
            // reconnect through the stable job journal.
            const coordinator = self.hostConnFor(null) orelse return;
            if (coordinator.state != .ready) {
                self.setStatus("local transfer coordinator is not connected");
                return;
            }
            const req = self.nextReq();
            const label = std.fmt.allocPrint(self.allocator, "{s}:{s} -> {s}", .{
                src_hc.label(), std.fs.path.basename(src_path), dst_hc.label(),
            }) catch return;
            const pj = self.allocator.create(PendingJob) catch {
                self.allocator.free(label);
                return;
            };
            pj.* = .{ .req = req, .hc = coordinator, .label = label };
            self.pending_jobs.append(self.allocator, pj) catch {
                self.allocator.free(label);
                self.allocator.destroy(pj);
                return;
            };
            self.sendOp(coordinator, .{
                .req = req,
                .op = "cross_copy",
                .path = src_path,
                .to = dst_path,
                .src_host = src_hc.host orelse "",
                .dst_host = dst_hc.host orelse "",
                .@"resume" = true,
            });
            self.setStatusFmt("durable transfer queued: {s}", .{label});
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
            .open_with_appid = if (opts.open_with_appid) |s| (self.allocator.dupe(u8, s) catch null) else null,
            .watch_host = if (opts.watch_host) |s| (self.allocator.dupe(u8, s) catch null) else null,
            .watch_remote = if (opts.watch_remote) |s| (self.allocator.dupe(u8, s) catch null) else null,
            .upload_watch = opts.upload_watch,
        };
        self.transfers.append(self.allocator, t) catch {
            x.deinit();
            self.allocator.free(label);
            self.allocator.destroy(t);
            return;
        };
        self.setStatusFmt("transfer queued: {s}", .{label});
        self.pumpTransferQueue();
        self.renderJobs();
    }

    /// Download a remote file into the local open-cache, launch an
    /// app on it when done (null appid = default handler), and watch
    /// the cache copy so local edits sync back to the host.
    fn openRemoteFile(self: *BrowserView, tab: *BTab, path: []const u8, appid: ?[]const u8) void {
        const local = self.hostConnFor(null) orelse return;
        if (local.state != .ready) {
            self.setStatus("local daemon unreachable");
            return;
        }
        const host = tab.hc.host orelse return;
        const cache_root = c.g_get_user_cache_dir();
        var dirbuf: [4096:0]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dirbuf, "{s}/sketerm/fsopen", .{cache_root}) catch return;
        _ = c.g_mkdir_with_parents(dir.ptr, 0o700);
        var h = std.hash.Wyhash.init(0);
        h.update(host);
        h.update(path);
        var dstbuf: [4600]u8 = undefined;
        const dst = std.fmt.bufPrint(&dstbuf, "{s}/{x:0>16}-{s}", .{
            dir, h.final(), std.fs.path.basename(path),
        }) catch return;
        self.startTransfer(tab.hc, path, local, dst, .{
            .open_when_done = true,
            .open_with_appid = appid,
            .watch_host = host,
            .watch_remote = path,
        });
    }

    // ── daemon jobs (same-host copy / recursive delete) ─────────

    fn startDaemonJob(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8) void {
        self.startDaemonJobKind(hc, op, path, to, "", label, .normal);
    }

    /// Like startDaemonJob, with hash-verified resume on (sync).
    fn startDaemonJobResumable(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8) void {
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
        self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .@"resume" = true });
    }

    fn startDaemonJobKind(
        self: *BrowserView,
        hc: *HostConn,
        comptime op: []const u8,
        path: []const u8,
        to: []const u8,
        pattern: []const u8,
        label: []const u8,
        kind: @FieldType(PendingJob, "kind"),
    ) void {
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
            .kind = kind,
        };
        self.pending_jobs.append(self.allocator, pj) catch {
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
            return;
        };
        if (pattern.len > 0) {
            self.sendOp(hc, .{ .req = req, .op = op, .path = path, .pattern = pattern });
        } else if (to.len > 0) {
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
        if (self.compare) |cmp| {
            if (cmp.consumeJobEvent(hc, e)) return;
        }
        if (std.mem.eql(u8, e.ev, "match")) {
            if (e.job == self.search_job and hc == self.search_hc) self.onSearchMatch(e);
            return;
        }
        if (std.mem.eql(u8, e.ev, "unmatch")) {
            if (e.job == self.search_job and hc == self.search_hc) self.onSearchUnmatch(e.path);
            return;
        }
        if (std.mem.eql(u8, e.ev, "resync")) {
            if (e.job == self.search_job and hc == self.search_hc)
                self.setStatus("live query watcher overflowed; rerun the saved query to resync");
            return;
        }
        if (e.job == self.search_job and hc == self.search_hc and std.mem.eql(u8, e.ev, "done")) {
            self.setStatusFmt("search done: {d} match(es){s}", .{
                e.matches, if (e.truncated) " (truncated)" else "",
            });
        }
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
                if (pj.kind == .search) {
                    self.search_job = rep.job;
                    self.search_hc = hc;
                }
                if (self.compare) |cmp| {
                    if (pj.kind == .compare_left) cmp.left.job = rep.job;
                    if (pj.kind == .compare_right) cmp.right.job = rep.job;
                }
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
                if (pj.kind == .compare_left or pj.kind == .compare_right) {
                    if (self.compare) |cmp| cmp.sideFailed(pj.kind == .compare_left);
                }
                self.allocator.free(pj.label);
                _ = self.pending_jobs.orderedRemove(i);
                self.allocator.destroy(pj);
            }
            return false;
        }
        // Open With host-apps reply?
        if (self.openwith) |ow| {
            if (ow.req != 0 and ow.req == rep.req) {
                self.populateHostApps(ow, rep.ok, rep.apps);
                return false;
            }
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

    /// Drop listing accumulators before their target directory is freed.
    fn cancelPendingDir(self: *BrowserView, dir: *Dir) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].dir == dir) {
                self.dropPending(i);
            } else {
                i += 1;
            }
        }
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
        const label_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_box_append(@ptrCast(label_box), label);
        const close_btn = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(close_btn), 0);
        c.gtk_box_append(@ptrCast(label_box), close_btn);

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
        _ = c.g_signal_connect_data(listbox, "selected-rows-changed", @ptrCast(&onSelectionChanged), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(close_btn, "clicked", @ptrCast(&onTabCloseClicked), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);

        const rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
        _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onRightClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(listbox, @ptrCast(rclick));

        const page_idx = c.gtk_notebook_append_page(self.notebook, scroller, label_box);
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

    fn onTabCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        tab.view.closeTab(tab);
    }

    fn closeTab(self: *BrowserView, tab: *BTab) void {
        if (self.search_tab == tab) self.search_tab = null;
        if (self.collection_tab == tab) self.collection_tab = null;
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].tab == tab) self.dropPending(i) else i += 1;
        }
        const page_idx = c.gtk_notebook_page_num(self.notebook, tab.page);
        if (page_idx >= 0) c.gtk_notebook_remove_page(self.notebook, page_idx);
        for (self.tabs.items, 0..) |t, j| {
            if (t == tab) {
                _ = self.tabs.orderedRemove(j);
                break;
            }
        }
        tab.deinit();
        if (self.currentTab()) |t| {
            self.syncPathEntry(t);
            self.renderTab(t);
        }
    }

    /// Navigate a tab to (host, path). `push_history` false = back/
    /// forward traversal (history untouched).
    fn navigate(self: *BrowserView, tab: *BTab, host_in: ?[]const u8, path_in: []const u8, push_history: bool) void {
        // Mount bypass: a local path under an sshfs/NFS mount is
        // silently rerouted to direct mux access on the source host
        // (fast listings, push deltas, host-side jobs).
        var host = host_in;
        var path = path_in;
        var bp: BypassHit = .{};
        if (host == null and mountBypass(path, &bp)) {
            host = bp.host();
            path = bp.path();
            self.setStatusFmt("via sketerm: {s} (bypassed mount {s})", .{ bp.host(), bp.mountpoint() });
        }
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
        self.cancelPendingDir(tab.root);
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
        tab.rendering = true;
        defer tab.rendering = false;
        while (c.gtk_list_box_get_row_at_index(tab.listbox, 0)) |row| {
            c.gtk_list_box_remove(tab.listbox, @ptrCast(row));
        }
        self.renderDirRows(tab, tab.root, 0);
        var row_idx: c_int = 0;
        while (c.gtk_list_box_get_row_at_index(tab.listbox, row_idx)) |row| : (row_idx += 1) {
            const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse continue;
            const ctx: *RowCtx = @ptrCast(@alignCast(data));
            for (tab.selected.items) |path| {
                if (std.mem.eql(u8, path, ctx.path)) {
                    c.gtk_list_box_select_row(tab.listbox, @ptrCast(row));
                    break;
                }
            }
        }
        var count_buf: [96]u8 = undefined;
        const cmsg = std.fmt.bufPrint(&count_buf, "{d} items", .{tab.root.entries.items.len}) catch "";
        self.setStatus(cmsg);
    }

    fn renderDirRows(self: *BrowserView, tab: *BTab, dir: *Dir, depth: u32) void {
        for (dir.entries.items) |e| {
            if (!tab.show_hidden and e.name.len > 0 and e.name[0] == '.') continue;
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
        const full = if (dir.flat)
            (e.target orelse return)
        else
            std.fmt.bufPrint(&full_buf, "{s}/{s}", .{
                if (dir.path.len == 1) "" else dir.path, e.name,
            }) catch return;

        if (e.tdir and !dir.flat) {
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

        // Local image files get a real thumbnail (bounded decode,
        // cached by path+mtime); everything else a symbolic icon.
        var icon: ?*c.GtkWidget = null;
        if (tab.hc.host == null and std.mem.eql(u8, e.kind, "file") and
            e.size <= THUMB_FILE_CAP and isImageName(e.name))
        {
            if (self.thumbTexture(full, e.mtime_ms)) |tex| {
                const img = c.gtk_image_new_from_paintable(@ptrCast(tex));
                c.gtk_image_set_pixel_size(@ptrCast(img), 24);
                icon = img;
            }
        }
        if (icon == null) {
            const icon_name: [*:0]const u8 = if (std.mem.eql(u8, e.kind, "dir"))
                "folder-symbolic"
            else if (std.mem.eql(u8, e.kind, "link"))
                "emblem-symbolic-link"
            else
                "text-x-generic-symbolic";
            icon = c.gtk_image_new_from_icon_name(icon_name);
        }
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

        if (e.tags.len > 0) {
            var tag_z: [128:0]u8 = undefined;
            const ttxt = std.fmt.bufPrintZ(&tag_z, "[{s}]", .{e.tags}) catch "";
            const tag_label = c.gtk_label_new(ttxt.ptr);
            c.gtk_widget_add_css_class(tag_label, "dim-label");
            c.gtk_box_append(@ptrCast(row_box), tag_label);
        }

        if (!std.mem.eql(u8, e.kind, "dir")) {
            var size_buf: [48:0]u8 = undefined;
            const s = fmtSize(&size_buf, e.size);
            const size_label = c.gtk_label_new(s.ptr);
            c.gtk_widget_add_css_class(size_label, "dim-label");
            c.gtk_box_append(@ptrCast(row_box), size_label);
        }

        if (e.mtime_ms != 0) {
            var time_buf: [40:0]u8 = undefined;
            const tstr = fmtTimeZ(&time_buf, e.mtime_ms);
            const time_label = c.gtk_label_new(tstr);
            c.gtk_widget_add_css_class(time_label, "dim-label");
            c.gtk_box_append(@ptrCast(row_box), time_label);
        }

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

        // Drag source: the entry's path as text — dropping on a
        // terminal pane types the path (pane accepts string drops).
        {
            var pz: [4200:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&pz, "{s}", .{full})) |pzs| {
                const provider = c.gdk_content_provider_new_typed(c.G_TYPE_STRING, pzs.ptr);
                const dsrc = c.gtk_drag_source_new();
                c.gtk_drag_source_set_content(dsrc, provider);
                c.g_object_unref(provider);
                c.gtk_widget_add_controller(row, @ptrCast(dsrc));
            } else |_| {}
        }

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

    fn onSelectionChanged(_: *c.GtkListBox, user: ?*anyopaque) callconv(.c) void {
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        if (tab.rendering) return;
        const a = tab.view.allocator;
        for (tab.selected.items) |p| a.free(p);
        tab.selected.clearRetainingCapacity();
        var rows = c.gtk_list_box_get_selected_rows(tab.listbox);
        const head = rows;
        while (rows != null) : (rows = rows.*.next) {
            const row: *c.GtkListBoxRow = @ptrCast(@alignCast(rows.*.data orelse continue));
            const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse continue;
            const ctx: *RowCtx = @ptrCast(@alignCast(data));
            const owned = a.dupe(u8, ctx.path) catch continue;
            tab.selected.append(a, owned) catch a.free(owned);
        }
        if (head != null) c.g_list_free(head);
        tab.view.updatePreview();
    }

    fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse return;
        const ctx: *RowCtx = @ptrCast(@alignCast(data));
        const self = tab.view;
        if (tab.root.collection) {
            // Collection rows hold host-qualified specs: open the
            // entry (dir) or its parent (file) in a NEW tab.
            const loc = parseSpec(ctx.path);
            var pbuf: [4096]u8 = undefined;
            const kind_dir = blk: {
                const i = tab.root.find(ctx.path) orelse break :blk false;
                break :blk std.mem.eql(u8, tab.root.entries.items[i].kind, "dir");
            };
            const dirp = if (kind_dir) loc.path else (std.fs.path.dirname(loc.path) orelse loc.path);
            if (dirp.len >= pbuf.len) return;
            @memcpy(pbuf[0..dirp.len], dirp);
            var hbuf: [256]u8 = undefined;
            var host: ?[]const u8 = null;
            if (loc.host) |h| {
                if (h.len >= hbuf.len) return;
                @memcpy(hbuf[0..h.len], h);
                host = hbuf[0..h.len];
            }
            _ = self.newTab(host, pbuf[0..dirp.len]);
            return;
        }
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
            self.openRemoteFile(tab, ctx.path, null);
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
        mode: enum { none, rename, mkdir, tags, permissions } = .none,
        entry: ?*c.GtkWidget = null,
        entry2: ?*c.GtkWidget = null,

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
        if (tab.root.collection) {
            // Collection rows: specs spanning hosts — navigation +
            // membership only (path verbs would misparse specs).
            if (ctx.path != null) {
                menuButton(box, "Open in New Browser Tab", &onMenuCollectionOpen, ctx, false);
                menuButton(box, "Remove from Collection", &onMenuCollectionRemove, ctx, false);
            }
        } else {
        if (ctx.path != null) {
            if (is_dir) {
                if (is_local)
                    menuButton(box, "Open Terminal Here", &onMenuTerminalHere, ctx, false);
                if (self.on_host_term != null)
                    menuButton(box, "Open Terminal Tab Here", &onMenuTermTab, ctx, false);
                menuButton(box, "Open in New Browser Tab", &onMenuOpenTab, ctx, false);
            } else if (!is_local and self.on_host_open != null) {
                menuButton(box, "Open on Host (app forward)", &onMenuHostOpen, ctx, false);
            }
            if (!is_dir)
                menuButton(box, "Open With…", &onMenuOpenWith, ctx, false);
            menuButton(box, "Copy", &onMenuCopy, ctx, false);
            menuButton(box, "Copy Path", &onMenuCopyPath, ctx, false);
            menuButton(box, "Rename…", &onMenuRename, ctx, false);
            menuButton(box, "Properties…", &onMenuProperties, ctx, false);
            menuButton(box, "Tags…", &onMenuTags, ctx, false);
            if (!is_dir and isArchivePath(ctx.path.?))
                menuButton(box, "Extract Here", &onMenuExtractHere, ctx, false);
            menuButton(box, "Compress to .tar.gz", &onMenuArchiveCreate, ctx, false);
            menuButton(box, "Add to Collection", &onMenuCollectionAdd, ctx, false);
            if (countSelected(tab) > 1)
                menuButton(box, "Batch Rename Selected…", &onMenuBatchRename, ctx, false);
            menuButton(box, "Move to Trash", &onMenuTrash, ctx, false);
            menuButton(box, "Delete Permanently…", &onMenuDelete, ctx, true);
        }
        if (self.clip_path != null) {
            menuButton(box, "Paste Here", &onMenuPaste, ctx, false);
            menuButton(box, "Sync Here (mirror copy, resumable)", &onMenuSyncHere, ctx, false);
            menuButton(box, "Compare / Sync with Copied…", &onMenuCompare, ctx, false);
        }
        menuButton(box, "New Folder…", &onMenuNewFolder, ctx, false);
        if (ctx.path != null) self.appendActionButtons(box, ctx);
        }

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
        self.clip_path = null;
        for (self.clip_paths.items) |p| self.allocator.free(p);
        self.clip_paths.clearRetainingCapacity();
        // A multi-selection that includes the clicked row copies the
        // whole selection; otherwise just the clicked entry.
        const in_selection = for (ctx.tab.selected.items) |sp| {
            if (std.mem.eql(u8, sp, path)) break true;
        } else false;
        if (in_selection and ctx.tab.selected.items.len > 1) {
            for (ctx.tab.selected.items) |sp| {
                const owned = self.allocator.dupe(u8, sp) catch continue;
                self.clip_paths.append(self.allocator, owned) catch self.allocator.free(owned);
            }
        } else {
            if (self.allocator.dupe(u8, path)) |owned| {
                self.clip_paths.append(self.allocator, owned) catch self.allocator.free(owned);
            } else |_| {}
        }
        if (self.clip_paths.items.len > 0)
            self.clip_path = self.allocator.dupe(u8, self.clip_paths.items[0]) catch null;
        if (self.clip_paths.items.len > 1) {
            self.setStatusFmt("copied {d} items", .{self.clip_paths.items.len});
        } else {
            self.setStatusFmt("copied: {s}", .{path});
        }
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

    /// Heap context for one pending paste batch, owned by its
    /// conflict popover (freed when the popover dies).
    const PasteCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        tab: *BTab,
        sources: std.ArrayList([]u8) = .empty,
        conflicts: usize = 0,
        popover: *c.GtkWidget,

        fn free(user: ?*anyopaque) callconv(.c) void {
            const p: *PasteCtx = @ptrCast(@alignCast(user.?));
            for (p.sources.items) |s| p.allocator.free(s);
            p.sources.deinit(p.allocator);
            p.allocator.destroy(p);
        }
    };

    const ConflictChoice = enum { overwrite, keep_both, skip };

    fn onMenuPaste(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const tab = ctx.tab;
        if (self.clip_paths.items.len == 0 and self.clip_path == null) return menuDone(ctx);

        // Count collisions against the LIVE target listing.
        var conflicts: usize = 0;
        const srcs: []const []u8 = if (self.clip_paths.items.len > 0)
            self.clip_paths.items
        else
            (&[_][]u8{self.clip_path.?})[0..];
        for (srcs) |src| {
            if (tab.root.find(std.fs.path.basename(src)) != null) conflicts += 1;
        }
        if (conflicts == 0) {
            self.pasteExecute(tab, srcs, .overwrite);
            return menuDone(ctx);
        }

        // Conflict dialog: one choice applies to every conflicting
        // item; non-conflicting items copy either way.
        const popover = c.gtk_popover_new();
        const pctx = self.allocator.create(PasteCtx) catch return menuDone(ctx);
        pctx.* = .{ .allocator = self.allocator, .view = self, .tab = tab, .popover = popover, .conflicts = conflicts };
        for (srcs) |src| {
            const owned = self.allocator.dupe(u8, src) catch continue;
            pctx.sources.append(self.allocator, owned) catch self.allocator.free(owned);
        }
        c.g_object_set_data_full(@ptrCast(popover), "sketerm-paste", @ptrCast(pctx), @ptrCast(&PasteCtx.free));

        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        c.gtk_widget_set_margin_start(box, 10);
        c.gtk_widget_set_margin_end(box, 10);
        c.gtk_widget_set_margin_top(box, 10);
        c.gtk_widget_set_margin_bottom(box, 10);
        var lbl: [256:0]u8 = undefined;
        const first = std.fs.path.basename(srcs[0]);
        const txt = if (conflicts == 1)
            std.fmt.bufPrintZ(&lbl, "\"{s}\" already exists here.", .{first}) catch "Name conflict."
        else
            std.fmt.bufPrintZ(&lbl, "{d} of {d} items already exist here.", .{ conflicts, srcs.len }) catch "Name conflicts.";
        const label = c.gtk_label_new(txt.ptr);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_box_append(@ptrCast(box), label);
        if (conflicts > 1) {
            const sub = c.gtk_label_new("The choice applies to all conflicting items.");
            c.gtk_widget_add_css_class(sub, "dim-label");
            c.gtk_label_set_xalign(@ptrCast(sub), 0);
            c.gtk_box_append(@ptrCast(box), sub);
        }
        pasteChoiceButton(box, "Keep Both (rename copy)", &onPasteKeepBoth, pctx, false);
        pasteChoiceButton(box, "Skip Existing", &onPasteSkip, pctx, false);
        pasteChoiceButton(box, "Overwrite", &onPasteOverwrite, pctx, true);

        c.gtk_popover_set_child(@ptrCast(popover), box);
        c.gtk_widget_set_parent(popover, @ptrCast(@alignCast(tab.listbox)));
        connectPopoverAutoUnparent(popover);
        c.gtk_popover_popup(@ptrCast(popover));
        menuDone(ctx);
    }

    fn pasteChoiceButton(box: *c.GtkWidget, label: [*:0]const u8, cb: anytype, pctx: *PasteCtx, destructive: bool) void {
        const btn = c.gtk_button_new_with_label(label);
        if (destructive) c.gtk_widget_add_css_class(btn, "destructive-action");
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(cb), @ptrCast(pctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), btn);
    }

    fn onPasteOverwrite(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const p: *PasteCtx = @ptrCast(@alignCast(user.?));
        p.view.pasteExecute(p.tab, p.sources.items, .overwrite);
        c.gtk_popover_popdown(@ptrCast(p.popover));
    }
    fn onPasteKeepBoth(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const p: *PasteCtx = @ptrCast(@alignCast(user.?));
        p.view.pasteExecute(p.tab, p.sources.items, .keep_both);
        c.gtk_popover_popdown(@ptrCast(p.popover));
    }
    fn onPasteSkip(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const p: *PasteCtx = @ptrCast(@alignCast(user.?));
        p.view.pasteExecute(p.tab, p.sources.items, .skip);
        c.gtk_popover_popdown(@ptrCast(p.popover));
    }

    /// Pick a destination name that does not collide with the live
    /// target listing: "name-copy", then "name-copy2"…
    fn uniqueDstName(tab: *BTab, base: []const u8, buf: []u8) ?[]const u8 {
        var candidate = std.fmt.bufPrint(buf, "{s}-copy", .{base}) catch return null;
        var n: u32 = 2;
        while (tab.root.find(candidate) != null) : (n += 1) {
            if (n > 999) return null;
            candidate = std.fmt.bufPrint(buf, "{s}-copy{d}", .{ base, n }) catch return null;
        }
        return candidate;
    }

    /// Start one copy per source, honoring `choice` for names that
    /// already exist in the target directory.
    fn pasteExecute(self: *BrowserView, tab: *BTab, sources: []const []u8, choice: ConflictChoice) void {
        const dir = tab.root.path;
        var skipped: usize = 0;
        for (sources) |src| {
            const base = std.fs.path.basename(src);
            var name_buf: [512]u8 = undefined;
            var name: []const u8 = base;
            if (tab.root.find(base) != null) {
                switch (choice) {
                    .overwrite => {},
                    .keep_both => name = uniqueDstName(tab, base, &name_buf) orelse {
                        skipped += 1;
                        continue;
                    },
                    .skip => {
                        skipped += 1;
                        continue;
                    },
                }
            }
            var dst_buf: [4096]u8 = undefined;
            const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
                if (dir.len == 1) "" else dir, name,
            }) catch continue;
            // Overwriting a file with itself is a no-op, not a copy.
            if (hostEq(self.clip_host, tab.hc.host) and std.mem.eql(u8, src, dst)) {
                skipped += 1;
                continue;
            }
            if (hostEq(self.clip_host, tab.hc.host)) {
                var lbl: [128]u8 = undefined;
                const label = std.fmt.bufPrint(&lbl, "copy {s}", .{base}) catch base;
                self.startDaemonJob(tab.hc, "copy", src, dst, label);
            } else {
                const src_hc = self.hostConnFor(if (self.clip_host) |h| @as(?[]const u8, h) else null) orelse continue;
                self.startTransfer(src_hc, src, tab.hc, dst, .{});
            }
        }
        if (skipped > 0) self.setStatusFmt("skipped {d} existing item(s)", .{skipped});
    }

    fn countSelected(tab: *BTab) usize {
        var n: usize = 0;
        var rows = c.gtk_list_box_get_selected_rows(tab.listbox);
        const head = rows;
        while (rows != null) : (rows = rows.*.next) n += 1;
        if (head != null) c.g_list_free(head);
        return n;
    }

    fn onMenuTermTab(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        if (self.on_host_term) |cb| {
            if (self.hooks_ctx) |hctx| cb(hctx, ctx.tab.hc.host orelse "", path);
        }
        menuDone(ctx);
    }

    fn onMenuHostOpen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        if (self.on_host_open) |cb| {
            if (self.hooks_ctx) |hctx| {
                cb(hctx, ctx.tab.hc.host orelse "", path);
                self.setStatus("opening on host (app window forwards here)…");
            }
        }
        menuDone(ctx);
    }

    // ── Open With chooser (local apps + host apps) ──────────────

    /// Heap context for one Open With popover; owned by the popover.
    const OpenWithCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        tab: *BTab,
        path: []u8,
        /// In-flight host `apps` request (0 = none).
        req: u32 = 0,
        host_box: *c.GtkWidget,
        host_label: *c.GtkWidget,
        popover: *c.GtkWidget,

        fn free(user: ?*anyopaque) callconv(.c) void {
            const ctx: *OpenWithCtx = @ptrCast(@alignCast(user.?));
            if (ctx.view.openwith == ctx) ctx.view.openwith = null;
            ctx.allocator.free(ctx.path);
            ctx.allocator.destroy(ctx);
        }
    };

    /// Heap context for one app button (GClosureNotify-freed).
    const AppBtnCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        tab: *BTab,
        path: []u8,
        /// Local application id (GAppInfo) — launch locally.
        appid: ?[]u8 = null,
        /// Host .desktop Exec line — launch on the file's host.
        exec: ?[]u8 = null,
        popover: *c.GtkWidget,

        fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
            _ = closure;
            const a: *AppBtnCtx = @ptrCast(@alignCast(user.?));
            a.allocator.free(a.path);
            if (a.appid) |s| a.allocator.free(s);
            if (a.exec) |s| a.allocator.free(s);
            a.allocator.destroy(a);
        }
    };

    fn onMenuOpenWith(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const mctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = mctx.view;
        const orig = mctx.path orelse return menuDone(mctx);
        const tab = mctx.tab;
        const is_local = tab.hc.host == null;
        // Copy the path out and close the menu popover FIRST — its
        // popdown must not race the new popover's grab.
        var pbuf: [4096]u8 = undefined;
        if (orig.len >= pbuf.len) return menuDone(mctx);
        @memcpy(pbuf[0..orig.len], orig);
        const path = pbuf[0..orig.len];
        menuDone(mctx);

        const popover = c.gtk_popover_new();
        const ctx = self.allocator.create(OpenWithCtx) catch return;
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
        const host_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
        const host_label = c.gtk_label_new("");
        ctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = tab,
            .path = self.allocator.dupe(u8, path) catch {
                self.allocator.destroy(ctx);
                return;
            },
            .host_box = host_box,
            .host_label = host_label,
            .popover = popover,
        };
        c.g_object_set_data_full(@ptrCast(popover), "sketerm-openwith", @ptrCast(ctx), @ptrCast(&OpenWithCtx.free));

        // Local applications for the file's guessed content type.
        const sec = c.gtk_label_new(if (is_local) "Open with:" else "Open locally (downloads a copy):");
        c.gtk_widget_add_css_class(sec, "dim-label");
        c.gtk_label_set_xalign(@ptrCast(sec), 0);
        c.gtk_box_append(@ptrCast(box), sec);

        var namez: [512:0]u8 = undefined;
        const base = std.fs.path.basename(path);
        var app_count: usize = 0;
        if (std.fmt.bufPrintZ(&namez, "{s}", .{base})) |bz| {
            var uncertain: c.gboolean = 0;
            const ct = c.g_content_type_guess(bz.ptr, null, 0, &uncertain);
            if (ct != null) {
                const apps = c.g_app_info_get_all_for_type(ct);
                var it = apps;
                while (it != null and app_count < 20) : (it = it.*.next) {
                    const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
                    const id = c.g_app_info_get_id(app) orelse continue;
                    const nm = c.g_app_info_get_name(app) orelse continue;
                    self.appChoiceButton(box, ctx, std.mem.span(nm), std.mem.span(id), null);
                    app_count += 1;
                }
                if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
                c.g_free(ct);
            }
        } else |_| {}
        if (app_count == 0) {
            const none = c.gtk_label_new("(no known local handler)");
            c.gtk_widget_add_css_class(none, "dim-label");
            c.gtk_box_append(@ptrCast(box), none);
        }

        // Host applications (remote tabs): one daemon round trip.
        // The widgets always join the tree (hidden locally) so they
        // never dangle as floating refs.
        c.gtk_widget_add_css_class(host_label, "dim-label");
        c.gtk_label_set_xalign(@ptrCast(host_label), 0);
        c.gtk_box_append(@ptrCast(box), host_label);
        c.gtk_box_append(@ptrCast(box), host_box);
        if (!is_local) {
            c.gtk_label_set_text(@ptrCast(host_label), "On host: loading…");
            if (tab.hc.state == .ready) {
                ctx.req = self.nextReq();
                self.openwith = ctx;
                self.sendOp(tab.hc, .{ .req = ctx.req, .op = "apps", .path = "/" });
            } else {
                c.gtk_label_set_text(@ptrCast(host_label), "On host: not connected");
            }
        } else {
            c.gtk_widget_set_visible(host_label, 0);
            c.gtk_widget_set_visible(host_box, 0);
        }

        const scroll = c.gtk_scrolled_window_new();
        c.gtk_widget_set_size_request(scroll, 320, 380);
        c.gtk_scrolled_window_set_child(@ptrCast(scroll), box);
        c.gtk_popover_set_child(@ptrCast(popover), scroll);
        c.gtk_widget_set_parent(popover, @ptrCast(@alignCast(tab.listbox)));
        connectPopoverAutoUnparent(popover);
        const rect = c.GdkRectangle{ .x = 320, .y = 200, .width = 1, .height = 1 };
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        c.gtk_popover_popup(@ptrCast(popover));
    }

    fn appChoiceButton(
        self: *BrowserView,
        box: *c.GtkWidget,
        ctx: *OpenWithCtx,
        name: []const u8,
        appid: ?[]const u8,
        exec: ?[]const u8,
    ) void {
        const actx = self.allocator.create(AppBtnCtx) catch return;
        actx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = ctx.tab,
            .path = self.allocator.dupe(u8, ctx.path) catch {
                self.allocator.destroy(actx);
                return;
            },
            .appid = if (appid) |s| (self.allocator.dupe(u8, s) catch null) else null,
            .exec = if (exec) |s| (self.allocator.dupe(u8, s) catch null) else null,
            .popover = ctx.popover,
        };
        var lbl: [256:0]u8 = undefined;
        const ltxt = std.fmt.bufPrintZ(&lbl, "{s}", .{name}) catch return;
        const btn = c.gtk_button_new_with_label(ltxt.ptr);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_set_halign(c.gtk_button_get_child(@ptrCast(btn)), c.GTK_ALIGN_START);
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onAppBtnClicked), @ptrCast(actx), @ptrCast(&AppBtnCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), btn);
    }

    fn onAppBtnClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const actx: *AppBtnCtx = @ptrCast(@alignCast(user.?));
        const self = actx.view;
        const tab = actx.tab;
        if (actx.exec) |exec| {
            // Host application: substituted Exec runs as an app
            // session on the file's host; its window forwards here.
            if (self.on_host_exec) |cb| {
                if (self.hooks_ctx) |hctx| {
                    if (buildHostExecCmd(self.allocator, exec, actx.path)) |cmd| {
                        defer self.allocator.free(cmd);
                        var z: [4600:0]u8 = undefined;
                        if (std.fmt.bufPrintZ(&z, "{s}", .{cmd})) |cz| {
                            cb(hctx, tab.hc.host orelse "", cz);
                            self.setStatus("opening on host (app window forwards here)…");
                        } else |_| {}
                    }
                }
            }
        } else if (actx.appid) |appid| {
            if (tab.hc.host == null) {
                launchLocalWithApp(appid, actx.path);
            } else {
                self.openRemoteFile(tab, actx.path, appid);
            }
        }
        c.gtk_popover_popdown(@ptrCast(actx.popover));
    }

    /// Fill the chooser's host section from the daemon's app list,
    /// filtered by the file's locally-guessed MIME type.
    fn populateHostApps(self: *BrowserView, ow: *OpenWithCtx, ok: bool, apps: []const WireApp) void {
        ow.req = 0;
        if (!ok) {
            c.gtk_label_set_text(@ptrCast(ow.host_label), "On host: unavailable (older daemon)");
            return;
        }
        var hostz: [280:0]u8 = undefined;
        const htxt = std.fmt.bufPrintZ(&hostz, "On {s}:", .{ow.tab.hc.label()}) catch "On host:";
        c.gtk_label_set_text(@ptrCast(ow.host_label), htxt.ptr);

        // Guess the MIME locally from the file name.
        var mime_buf: [256]u8 = undefined;
        var mime: []const u8 = "";
        var namez: [512:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&namez, "{s}", .{std.fs.path.basename(ow.path)})) |bz| {
            var uncertain: c.gboolean = 0;
            const ct = c.g_content_type_guess(bz.ptr, null, 0, &uncertain);
            if (ct != null) {
                const m = c.g_content_type_get_mime_type(ct);
                if (m != null) {
                    const ms = std.mem.span(@as([*:0]const u8, @ptrCast(m)));
                    if (ms.len < mime_buf.len) {
                        @memcpy(mime_buf[0..ms.len], ms);
                        mime = mime_buf[0..ms.len];
                    }
                    c.g_free(m);
                }
                c.g_free(ct);
            }
        } else |_| {}

        var shown: usize = 0;
        if (mime.len > 0) {
            for (apps) |app| {
                if (shown >= 20) break;
                if (!mimeListContains(app.mimes, mime)) continue;
                self.appChoiceButton(ow.host_box, ow, app.name, null, app.exec);
                shown += 1;
            }
        }
        if (shown == 0) {
            // No MIME match: offer everything, bounded.
            for (apps) |app| {
                if (shown >= 30) break;
                self.appChoiceButton(ow.host_box, ow, app.name, null, app.exec);
                shown += 1;
            }
        }
        if (shown == 0)
            c.gtk_label_set_text(@ptrCast(ow.host_label), "On host: no applications found");
    }

    // ── local-edit sync-back (remote files opened locally) ──────

    /// Watch a landed download; local saves upload back to the host.
    fn registerEditWatch(self: *BrowserView, host: []const u8, remote_path: []const u8, cache_path: []const u8) void {
        for (self.watches.items) |wt| {
            if (std.mem.eql(u8, wt.host, host) and std.mem.eql(u8, wt.remote_path, remote_path)) return;
        }
        const wt = self.allocator.create(EditWatch) catch return;
        wt.* = .{
            .view = self,
            .host = self.allocator.dupe(u8, host) catch {
                self.allocator.destroy(wt);
                return;
            },
            .remote_path = self.allocator.dupe(u8, remote_path) catch {
                self.allocator.free(wt.host);
                self.allocator.destroy(wt);
                return;
            },
            .cache_path = self.allocator.dupe(u8, cache_path) catch {
                self.allocator.free(wt.host);
                self.allocator.free(wt.remote_path);
                self.allocator.destroy(wt);
                return;
            },
        };
        var z: [4600:0]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&z, "{s}", .{cache_path}) catch {
            wt.destroy(self.allocator);
            return;
        };
        const gfile = c.g_file_new_for_path(pz.ptr);
        wt.monitor = c.g_file_monitor_file(gfile, c.G_FILE_MONITOR_NONE, null, null);
        c.g_object_unref(gfile);
        if (wt.monitor == null) {
            wt.destroy(self.allocator);
            return;
        }
        _ = c.g_signal_connect_data(wt.monitor, "changed", @ptrCast(&onEditWatchChanged), @ptrCast(wt), null, c.G_CONNECT_DEFAULT);
        self.watches.append(self.allocator, wt) catch {
            wt.destroy(self.allocator);
            return;
        };
        self.setStatusFmt("local edits to {s} will sync back to {s}", .{
            std.fs.path.basename(remote_path), host,
        });
    }

    fn onEditWatchChanged(
        _: *c.GFileMonitor,
        _: ?*c.GFile,
        _: ?*c.GFile,
        event: c.GFileMonitorEvent,
        user: ?*anyopaque,
    ) callconv(.c) void {
        if (event != c.G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT) return;
        const wt: *EditWatch = @ptrCast(@alignCast(user.?));
        wt.view.uploadEditWatch(wt);
    }

    fn uploadEditWatch(self: *BrowserView, wt: *EditWatch) void {
        if (wt.uploading) return;
        const local = self.hostConnFor(null) orelse return;
        const remote = self.hostConnFor(wt.host) orelse return;
        if (local.state != .ready or remote.state != .ready) {
            self.setStatusFmt("edit sync-back to {s} deferred (reconnecting) — save again to retry", .{wt.host});
            return;
        }
        wt.uploading = true;
        self.startTransfer(local, wt.cache_path, remote, wt.remote_path, .{ .upload_watch = wt });
        self.renderJobs();
    }

    // ── tags ────────────────────────────────────────────────────

    fn findEntryTags(tab: *BTab, path: []const u8) []const u8 {
        const base = std.fs.path.basename(path);
        const parent = std.fs.path.dirname(path) orelse return "";
        const dir: *Dir = if (std.mem.eql(u8, tab.root.path, parent))
            tab.root
        else
            tab.subdirByPath(parent) orelse return "";
        const i = dir.find(base) orelse return "";
        return dir.entries.items[i].tags;
    }

    fn onMenuTags(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        const popover = c.gtk_popover_new();
        const entry = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "comma,separated,tags (empty clears)");
        const cur = findEntryTags(ctx.tab, path);
        if (cur.len > 0) {
            var z: [256:0]u8 = undefined;
            const n = @min(cur.len, z.len - 1);
            @memcpy(z[0..n], cur[0..n]);
            z[n] = 0;
            c.gtk_editable_set_text(@ptrCast(entry), &z);
        }
        const tctx = self.allocator.create(MenuCtx) catch return menuDone(ctx);
        tctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = ctx.tab,
            .path = self.allocator.dupe(u8, path) catch null,
            .name = null,
            .is_dir = ctx.is_dir,
            .popover = popover,
            .mode = .tags,
            .entry = entry,
        };
        c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(tctx), @ptrCast(&MenuCtx.free));
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onTagsActivate), @ptrCast(tctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_popover_set_child(@ptrCast(popover), entry);
        c.gtk_widget_set_parent(popover, @ptrCast(@alignCast(ctx.tab.listbox)));
        connectPopoverAutoUnparent(popover);
        c.gtk_popover_popup(@ptrCast(popover));
        _ = c.gtk_widget_grab_focus(entry);
        menuDone(ctx);
    }

    fn onTagsActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        const txt = c.gtk_editable_get_text(@ptrCast(entry));
        const tags = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        self.sendOp(ctx.tab.hc, .{ .req = self.nextReq(), .op = "tag_set", .path = path, .to = tags });
        menuDone(ctx);
    }

    // ── collection (cross-host shelf) ───────────────────────────

    fn onMenuCollectionAdd(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        const tab = self.collection_tab orelse blk: {
            const t = self.newTab(ctx.tab.hc.host, ctx.tab.root.path) orelse return menuDone(ctx);
            self.closeViewOf(t.hc, t.root);
            var i: usize = 0;
            while (i < self.pending.items.len) {
                if (self.pending.items[i].tab == t) self.dropPending(i) else i += 1;
            }
            t.root.flat = true;
            t.root.collection = true;
            t.root.loaded = true;
            t.root.view_id = 0;
            c.gtk_label_set_text(t.tab_label, "collection");
            self.collection_tab = t;
            break :blk t;
        };
        // Entry: display = host-qualified spec; target = same spec.
        var spec_buf: [4400]u8 = undefined;
        const spec = if (ctx.tab.hc.host) |h|
            std.fmt.bufPrint(&spec_buf, "{s}:{s}", .{ h, path }) catch return menuDone(ctx)
        else
            path;
        const dir = tab.root;
        if (dir.find(spec) != null) return menuDone(ctx); // already shelved
        const a = self.allocator;
        const name = a.dupe(u8, spec) catch return menuDone(ctx);
        const kind = a.dupe(u8, if (ctx.is_dir) "dir" else "file") catch {
            a.free(name);
            return menuDone(ctx);
        };
        const tgt = a.dupe(u8, spec) catch {
            a.free(name);
            a.free(kind);
            return menuDone(ctx);
        };
        dir.entries.append(a, .{
            .name = name,
            .kind = kind,
            .size = 0,
            .mode = 0,
            .mtime_ms = 0,
            .target = tgt,
            .tdir = false,
        }) catch {
            a.free(name);
            a.free(kind);
            a.free(tgt);
        };
        self.setStatusFmt("added to collection: {s}", .{spec});
        menuDone(ctx);
    }

    fn onMenuCollectionOpen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const spec = ctx.path orelse return menuDone(ctx);
        const loc = parseSpec(spec);
        if (loc.path.len > 0) {
            // Open the entry itself (dir) or its parent (file).
            const dirp = if (ctx.is_dir) loc.path else (std.fs.path.dirname(loc.path) orelse loc.path);
            _ = self.newTab(loc.host, dirp);
        }
        menuDone(ctx);
    }

    fn onMenuCollectionRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const spec = ctx.path orelse return menuDone(ctx);
        if (self.collection_tab) |tab| {
            tab.root.del(std.fs.path.basename(spec));
            // Collection names ARE the specs (basename won't match) —
            // fall back to a full-name scan.
            if (tab.root.find(spec)) |i| {
                var e = tab.root.entries.orderedRemove(i);
                e.deinit(self.allocator);
            }
            if (self.currentTab() == tab) self.renderTab(tab);
        }
        menuDone(ctx);
    }

    // ── batch rename ────────────────────────────────────────────

    fn onMenuBatchRename(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const tab = ctx.tab;
        const popover = c.gtk_popover_new();
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        const find_e = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(find_e), "find (substring)");
        const repl_e = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(repl_e), "replace with");
        const apply = c.gtk_button_new_with_label("Rename selected");
        c.gtk_box_append(@ptrCast(box), find_e);
        c.gtk_box_append(@ptrCast(box), repl_e);
        c.gtk_box_append(@ptrCast(box), apply);
        const bctx = self.allocator.create(MenuCtx) catch return menuDone(ctx);
        bctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = tab,
            .path = null,
            .name = null,
            .is_dir = false,
            .popover = popover,
            .entry = find_e,
            .entry2 = repl_e,
        };
        c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(bctx), @ptrCast(&MenuCtx.free));
        _ = c.g_signal_connect_data(apply, "clicked", @ptrCast(&onBatchRenameApply), @ptrCast(bctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_popover_set_child(@ptrCast(popover), box);
        c.gtk_widget_set_parent(popover, @ptrCast(@alignCast(tab.listbox)));
        connectPopoverAutoUnparent(popover);
        c.gtk_popover_popup(@ptrCast(popover));
        menuDone(ctx);
    }

    fn onBatchRenameApply(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const tab = ctx.tab;
        const find_txt = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.entry.?)))));
        const repl_txt = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.entry2.?)))));
        if (find_txt.len == 0 or std.mem.indexOfScalar(u8, repl_txt, '/') != null) {
            self.setStatus("batch rename: bad pattern");
            return menuDone(ctx);
        }
        var renamed: usize = 0;
        var rows = c.gtk_list_box_get_selected_rows(tab.listbox);
        const head = rows;
        while (rows != null) : (rows = rows.*.next) {
            const row: *c.GtkListBoxRow = @ptrCast(@alignCast(rows.*.data));
            const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse continue;
            const rctx: *RowCtx = @ptrCast(@alignCast(data));
            const base = std.fs.path.basename(rctx.path);
            const parent = std.fs.path.dirname(rctx.path) orelse continue;
            // Replace ALL occurrences of `find` in the basename.
            var nb: [1024]u8 = undefined;
            var w = std.Io.Writer.fixed(&nb);
            var rest = base;
            var changed = false;
            while (std.mem.indexOf(u8, rest, find_txt)) |i| {
                w.writeAll(rest[0..i]) catch break;
                w.writeAll(repl_txt) catch break;
                rest = rest[i + find_txt.len ..];
                changed = true;
            }
            w.writeAll(rest) catch continue;
            if (!changed or w.buffered().len == 0) continue;
            var full: [4096]u8 = undefined;
            const to = std.fmt.bufPrint(&full, "{s}/{s}", .{
                if (parent.len == 1) "" else parent, w.buffered(),
            }) catch continue;
            self.sendOp(tab.hc, .{ .req = self.nextReq(), .op = "rename", .path = rctx.path, .to = to });
            renamed += 1;
        }
        if (head != null) c.g_list_free(head);
        self.setStatusFmt("batch rename: {d} rename(s) sent", .{renamed});
        menuDone(ctx);
    }

    fn onMenuSyncHere(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const src = self.clip_path orelse return menuDone(ctx);
        const tab = ctx.tab;
        const base = std.fs.path.basename(src);
        var dst_buf: [4096]u8 = undefined;
        const dir = tab.root.path;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ if (dir.len == 1) "" else dir, base }) catch
            return menuDone(ctx);
        if (hostEq(self.clip_host, tab.hc.host)) {
            // Same host: daemon copy with resume — completed files
            // skip, partials continue (incremental mirror, no deletes).
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "sync {s}", .{base}) catch base;
            self.startDaemonJobResumable(tab.hc, "copy", src, dst, label);
        } else {
            const src_hc = self.hostConnFor(if (self.clip_host) |h| @as(?[]const u8, h) else null) orelse
                return menuDone(ctx);
            self.startTransfer(src_hc, src, tab.hc, dst, .{});
        }
        menuDone(ctx);
    }

    fn onMenuCompare(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const tab = ctx.tab;
        const target = if (ctx.is_dir and ctx.path != null) ctx.path.? else tab.root.path;
        var tbuf: [4096]u8 = undefined;
        if (target.len >= tbuf.len) return menuDone(ctx);
        @memcpy(tbuf[0..target.len], target);
        const tcopy = tbuf[0..target.len];
        menuDone(ctx);
        self.startCompare(tab, tcopy);
    }

    /// Open the compare/sync window: source = the copied directory,
    /// target = `right_path` on this tab's host. Host-side scans.
    fn startCompare(self: *BrowserView, tab: *BTab, right_path: []const u8) void {
        const src_path = self.clip_path orelse return;
        if (self.compare != null) {
            self.setStatus("a compare window is already open");
            return;
        }
        const left_hc = self.hostConnFor(if (self.clip_host) |h| @as(?[]const u8, h) else null) orelse return;
        const right_hc = tab.hc;
        if (left_hc.state != .ready or right_hc.state != .ready) {
            self.setStatus("both hosts must be connected — retry in a moment");
            return;
        }

        const cmp = self.allocator.create(CompareCtx) catch return;
        cmp.* = .{
            .allocator = self.allocator,
            .view = self,
            .left = .{ .hc = left_hc, .root = self.allocator.dupe(u8, src_path) catch {
                self.allocator.destroy(cmp);
                return;
            } },
            .right = .{ .hc = right_hc, .root = self.allocator.dupe(u8, right_path) catch {
                self.allocator.free(cmp.left.root);
                self.allocator.destroy(cmp);
                return;
            } },
        };

        const win = c.gtk_window_new();
        c.gtk_window_set_title(@ptrCast(win), "Compare / Sync");
        c.gtk_window_set_default_size(@ptrCast(win), 760, 520);
        const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
        c.gtk_widget_set_margin_start(vbox, 10);
        c.gtk_widget_set_margin_end(vbox, 10);
        c.gtk_widget_set_margin_top(vbox, 10);
        c.gtk_widget_set_margin_bottom(vbox, 10);

        var hdr: [1024:0]u8 = undefined;
        const htxt = std.fmt.bufPrintZ(&hdr, "Source: {s}:{s}\nTarget: {s}:{s}", .{
            left_hc.label(), src_path, right_hc.label(), right_path,
        }) catch "Compare";
        const header = c.gtk_label_new(htxt.ptr);
        c.gtk_label_set_xalign(@ptrCast(header), 0);
        c.gtk_box_append(@ptrCast(vbox), header);

        const info = c.gtk_label_new("Scanning both trees host-side…");
        c.gtk_label_set_xalign(@ptrCast(info), 0);
        c.gtk_widget_add_css_class(info, "dim-label");
        c.gtk_box_append(@ptrCast(vbox), info);

        const excl = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(excl), "exclude globs, comma-separated (e.g. *.o, .git*)");
        c.gtk_box_append(@ptrCast(vbox), excl);

        const scroll = c.gtk_scrolled_window_new();
        c.gtk_widget_set_vexpand(scroll, 1);
        const listbox = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(listbox), c.GTK_SELECTION_NONE);
        c.gtk_scrolled_window_set_child(@ptrCast(scroll), listbox);
        c.gtk_box_append(@ptrCast(vbox), scroll);

        const btns = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_halign(btns, c.GTK_ALIGN_END);
        const closeb = c.gtk_button_new_with_label("Close");
        _ = c.g_signal_connect_data(closeb, "clicked", @ptrCast(&CompareCtx.onCloseClicked), @ptrCast(cmp), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(btns), closeb);
        const execb = c.gtk_button_new_with_label("Execute Sync (copy only, no deletes)");
        c.gtk_widget_add_css_class(execb, "suggested-action");
        _ = c.g_signal_connect_data(execb, "clicked", @ptrCast(&CompareCtx.onExecuteClicked), @ptrCast(cmp), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(btns), execb);
        c.gtk_box_append(@ptrCast(vbox), btns);

        c.gtk_window_set_child(@ptrCast(win), vbox);
        cmp.window = win;
        cmp.listbox = @ptrCast(@alignCast(listbox));
        cmp.info_label = @ptrCast(@alignCast(info));
        cmp.excl_entry = @ptrCast(@alignCast(excl));
        c.g_object_set_data_full(@ptrCast(win), "sketerm-compare", @ptrCast(cmp), @ptrCast(&CompareCtx.free));
        self.compare = cmp;
        c.gtk_window_present(@ptrCast(win));

        // Host-side digest scans (pattern * = everything).
        self.startDaemonJobKind(left_hc, "find", cmp.left.root, "", "*", "scan source tree", .compare_left);
        self.startDaemonJobKind(right_hc, "find", cmp.right.root, "", "*", "scan target tree", .compare_right);
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

    fn isArchivePath(path: []const u8) bool {
        const exts = [_][]const u8{ ".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".7z" };
        for (exts) |ext| if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
        return false;
    }

    fn onMenuExtractHere(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const path = ctx.path orelse return menuDone(ctx);
        const parent = std.fs.path.dirname(path) orelse "/";
        ctx.view.startDaemonJob(ctx.tab.hc, "extract", path, parent, "extract archive");
        menuDone(ctx);
    }

    fn onMenuArchiveCreate(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const path = ctx.path orelse return menuDone(ctx);
        var out: [4096]u8 = undefined;
        const archive = std.fmt.bufPrint(&out, "{s}.tar.gz", .{path}) catch return menuDone(ctx);
        ctx.view.startDaemonJob(ctx.tab.hc, "archive_create", path, archive, "create archive");
        menuDone(ctx);
    }

    fn onMenuTrash(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const path = ctx.path orelse return menuDone(ctx);
        ctx.view.startDaemonJob(ctx.tab.hc, "trash", path, "", "move to trash");
        menuDone(ctx);
    }

    fn entryForPath(tab: *BTab, path: []const u8) ?*Entry {
        const parent = std.fs.path.dirname(path) orelse return null;
        const dir = if (std.mem.eql(u8, tab.root.path, parent)) tab.root else tab.subdirByPath(parent) orelse return null;
        const idx = dir.find(std.fs.path.basename(path)) orelse return null;
        return &dir.entries.items[idx];
    }

    fn onMenuProperties(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const old: *MenuCtx = @ptrCast(@alignCast(user.?));
        const path = old.path orelse return menuDone(old);
        const e = entryForPath(old.tab, path) orelse return menuDone(old);
        const self = old.view;
        const popover = c.gtk_popover_new();
        const ctx = self.allocator.create(MenuCtx) catch return menuDone(old);
        ctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = old.tab,
            .path = self.allocator.dupe(u8, path) catch null,
            .name = null,
            .is_dir = old.is_dir,
            .popover = popover,
            .mode = .permissions,
        };
        c.g_object_set_data_full(@ptrCast(popover), "sketerm-menu", @ptrCast(ctx), @ptrCast(&MenuCtx.free));
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
        c.gtk_widget_set_margin_start(box, 10);
        c.gtk_widget_set_margin_end(box, 10);
        c.gtk_widget_set_margin_top(box, 10);
        c.gtk_widget_set_margin_bottom(box, 10);
        var info: [1024:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&info,
            "{s}\nType: {s}\nSize: {d} bytes ({d} allocated)\nOwner: {d}:{d}\nLinks: {d}\nModified: {d}\nChanged: {d}",
            .{ path, e.kind, e.size, e.blocks * 512, e.uid, e.gid, e.nlink, e.mtime_ms, e.ctime_ms }) catch "Properties";
        const label = c.gtk_label_new(text.ptr);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_selectable(@ptrCast(label), 1);
        c.gtk_box_append(@ptrCast(box), label);
        const mode_entry = c.gtk_entry_new();
        var modez: [16:0]u8 = undefined;
        const modes = std.fmt.bufPrintZ(&modez, "{o:0>4}", .{e.mode}) catch "0644";
        c.gtk_editable_set_text(@ptrCast(mode_entry), modes.ptr);
        c.gtk_entry_set_placeholder_text(@ptrCast(mode_entry), "permissions (octal), Enter to apply");
        ctx.entry = mode_entry;
        _ = c.g_signal_connect_data(mode_entry, "activate", @ptrCast(&onEntryDialogActivate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), mode_entry);
        c.gtk_popover_set_child(@ptrCast(popover), box);
        c.gtk_widget_set_parent(popover, @ptrCast(@alignCast(old.tab.listbox)));
        connectPopoverAutoUnparent(popover);
        c.gtk_popover_popup(@ptrCast(popover));
        menuDone(old);
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
        if (ctx.mode == .permissions) {
            const path = ctx.path orelse return menuDone(ctx);
            const mode = std.fmt.parseInt(u32, name, 8) catch {
                self.setStatus("invalid octal permissions");
                return;
            };
            if (mode > 0o7777) {
                self.setStatus("permissions must be between 0000 and 7777");
                return;
            }
            self.sendOp(ctx.tab.hc, .{ .req = self.nextReq(), .op = "chmod", .path = path, .mode = mode });
            return menuDone(ctx);
        }
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
            .none, .tags, .permissions => {},
        }
        menuDone(ctx);
    }

    // ── declarative actions (.action files) ─────────────────────

    /// Heap context for one action button; freed with the button.
    const ActionCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        host: ?[]u8,
        cmdline: []u8,
        runs_on_host: bool,

        fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
            _ = closure;
            const a: *ActionCtx = @ptrCast(@alignCast(user.?));
            if (a.host) |h| a.allocator.free(h);
            a.allocator.free(a.cmdline);
            a.allocator.destroy(a);
        }
    };

    /// User actions from $XDG_CONFIG_HOME/sketerm/actions/*.action:
    /// Name= / Exec= (%f = quoted path) / Ext=csv / RunsOnHost=true.
    /// Local-only actions hide on remote tabs (a local command cannot
    /// reach a remote path); RunsOnHost actions run as app sessions
    /// on the file's host (windows forward here).
    fn appendActionButtons(self: *BrowserView, box: *c.GtkWidget, ctx: *MenuCtx) void {
        const path = ctx.path orelse return;
        var dirbuf: [4096:0]u8 = undefined;
        const cfg = c.g_get_user_config_dir();
        const adir = std.fmt.bufPrintZ(&dirbuf, "{s}/sketerm/actions", .{cfg}) catch return;
        const d = c.opendir(adir.ptr) orelse return;
        defer _ = c.closedir(d);
        const remote = ctx.tab.hc.host != null;
        const base = std.fs.path.basename(path);
        const ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[i + 1 ..] else "";

        while (c.readdir(d)) |de| {
            const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
            if (!std.mem.endsWith(u8, fname, ".action")) continue;
            var fbuf: [4200:0]u8 = undefined;
            const fpath = std.fmt.bufPrintZ(&fbuf, "{s}/{s}", .{ adir, fname }) catch continue;
            const f = c.fopen(fpath.ptr, "rb") orelse continue;
            var content: [4096]u8 = undefined;
            const n = c.fread(&content, 1, content.len, f);
            _ = c.fclose(f);
            var name: []const u8 = "";
            var exec: []const u8 = "";
            var exts: []const u8 = "";
            var on_host = false;
            var it = std.mem.tokenizeScalar(u8, content[0..n], '\n');
            while (it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (std.mem.startsWith(u8, line, "Name=")) name = line[5..];
                if (std.mem.startsWith(u8, line, "Exec=")) exec = line[5..];
                if (std.mem.startsWith(u8, line, "Ext=")) exts = line[4..];
                if (std.mem.startsWith(u8, line, "RunsOnHost=")) on_host = std.mem.eql(u8, line[11..], "true");
            }
            if (name.len == 0 or exec.len == 0) continue;
            if (remote and !on_host) continue;
            if (exts.len > 0) {
                var matched = false;
                var eit = std.mem.tokenizeScalar(u8, exts, ',');
                while (eit.next()) |e| {
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, e, " "), ext)) matched = true;
                }
                if (!matched) continue;
            }
            // %f → single-quoted path, substituted now.
            var cmd: std.ArrayList(u8) = .empty;
            defer cmd.deinit(self.allocator);
            var rest = exec;
            while (std.mem.indexOf(u8, rest, "%f")) |i| {
                cmd.appendSlice(self.allocator, rest[0..i]) catch return;
                cmd.append(self.allocator, '\'') catch return;
                for (path) |ch| {
                    if (ch == '\'') {
                        cmd.appendSlice(self.allocator, "'\\''") catch return;
                    } else cmd.append(self.allocator, ch) catch return;
                }
                cmd.append(self.allocator, '\'') catch return;
                rest = rest[i + 2 ..];
            }
            cmd.appendSlice(self.allocator, rest) catch return;

            const actx = self.allocator.create(ActionCtx) catch return;
            actx.* = .{
                .allocator = self.allocator,
                .view = self,
                .host = if (ctx.tab.hc.host) |h| (self.allocator.dupe(u8, h) catch null) else null,
                .cmdline = self.allocator.dupe(u8, cmd.items) catch {
                    self.allocator.destroy(actx);
                    return;
                },
                .runs_on_host = on_host,
            };
            var lbl: [128:0]u8 = undefined;
            const ltxt = std.fmt.bufPrintZ(&lbl, "{s}{s}", .{
                name, if (on_host) " (on host)" else "",
            }) catch continue;
            const btn = c.gtk_button_new_with_label(ltxt.ptr);
            c.gtk_button_set_has_frame(@ptrCast(btn), 0);
            c.gtk_widget_set_halign(c.gtk_button_get_child(@ptrCast(btn)), c.GTK_ALIGN_START);
            _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onActionClicked), @ptrCast(actx), @ptrCast(&ActionCtx.free), c.G_CONNECT_DEFAULT);
            // Popdown when an action fires: reuse the menu ctx's popover.
            c.g_object_set_data(@ptrCast(btn), "sketerm-popover", @ptrCast(ctx.popover));
            c.gtk_box_append(@ptrCast(box), btn);
        }
    }

    fn onActionClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const actx: *ActionCtx = @ptrCast(@alignCast(user.?));
        const self = actx.view;
        if (actx.runs_on_host) {
            if (self.on_host_exec) |cb| {
                if (self.hooks_ctx) |hctx| {
                    var z: [4096:0]u8 = undefined;
                    const cl = std.fmt.bufPrintZ(&z, "{s}", .{actx.cmdline}) catch return;
                    cb(hctx, actx.host orelse "", cl);
                    self.setStatus("action started (app session)");
                }
            }
        } else {
            var z: [4096:0]u8 = undefined;
            const cl = std.fmt.bufPrintZ(&z, "{s}", .{actx.cmdline}) catch return;
            _ = c.g_spawn_command_line_async(cl.ptr, null);
            self.setStatus("action started");
        }
        if (c.g_object_get_data(@ptrCast(btn), "sketerm-popover")) |pop| {
            c.gtk_popover_popdown(@ptrCast(@alignCast(pop)));
        }
    }

    // ── search (find/grep jobs → panelize-style results tab) ────

    /// Start a search from the bar: name search by default, content
    /// grep when the toggle is on. Results stream into a flat tab.
    fn startSearch(self: *BrowserView) void {
        const tab = self.currentTab() orelse return;
        if (tab.hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{tab.hc.label()});
            return;
        }
        const txt = c.gtk_editable_get_text(@ptrCast(self.search_entry));
        const pattern = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        if (pattern.len == 0) return;
        const panelize = pattern.len > 1 and pattern[0] == '!';
        const content = !panelize and c.gtk_check_button_get_active(@ptrCast(self.search_content)) != 0;

        // One search at a time: a still-running previous job is
        // canceled (its JobRow stays for the record).
        if (self.search_job != 0) {
            if (self.search_hc) |shc| {
                if (shc.state == .ready)
                    self.sendOp(shc, .{ .req = self.nextReq(), .op = "job_cancel", .job = self.search_job });
            }
            self.search_job = 0;
        }

        // Fresh results tab rooted at the searched directory.
        var rbuf: [4096]u8 = undefined;
        if (tab.root.path.len >= rbuf.len) return;
        @memcpy(rbuf[0..tab.root.path.len], tab.root.path);
        const root = rbuf[0..tab.root.path.len];
        const host = tab.hc.host;
        const rtab = self.newTab(host, root) orelse return;
        // Flat results: no live view (newTab already subscribed the
        // root — undo that; the results are the search stream).
        self.closeViewOf(rtab.hc, rtab.root);
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].tab == rtab) self.dropPending(i) else i += 1;
        }
        rtab.root.flat = true;
        rtab.root.loaded = true;
        rtab.root.view_id = 0;
        self.search_tab = rtab;
        if (rtab.virtual_spec.len > 0) self.allocator.free(rtab.virtual_spec);
        rtab.virtual_spec = self.allocator.dupe(u8, pattern) catch &.{};
        var lbl: [160:0]u8 = undefined;
        const ltxt = std.fmt.bufPrintZ(&lbl, "{s}: {s}", .{ if (panelize) "panel" else "search", pattern }) catch "search";
        c.gtk_label_set_text(rtab.tab_label, ltxt.ptr);
        self.renderTab(rtab);

        var jl: [200]u8 = undefined;
        const jlbl = std.fmt.bufPrint(&jl, "{s} \"{s}\"", .{
            if (content) @as([]const u8, "grep") else "find", pattern,
        }) catch "search";
        if (panelize) {
            self.startDaemonJobKind(tab.hc, "panelize", root, "", pattern[1..], jlbl, .search);
        } else if (content) {
            self.startDaemonJobKind(tab.hc, "grep", root, "", pattern, jlbl, .search);
        } else {
            self.startDaemonJobKind(tab.hc, "live_find", root, "", pattern, jlbl, .search);
        }
        self.setStatusFmt("searching {s}…", .{root});
    }

    fn onSearchMatch(self: *BrowserView, e: WireJobEv) void {
        const rtab = self.search_tab orelse return;
        const dir = rtab.root;
        if (e.path.len == 0) return;
        // Display name: path relative to the search root (+ line
        // preview for content matches). Full path rides `target`.
        const rel = if (std.mem.startsWith(u8, e.path, dir.path) and e.path.len > dir.path.len + 1)
            e.path[dir.path.len + 1 ..]
        else
            e.path;
        var name_buf: [512]u8 = undefined;
        const display = if (e.line > 0)
            std.fmt.bufPrint(&name_buf, "{s}:{d}: {s}", .{ rel, e.line, e.text }) catch rel
        else
            rel;
        for (dir.entries.items) |*existing| {
            if (existing.target) |target| {
                if (std.mem.eql(u8, target, e.path) and e.line == 0) {
                    existing.size = e.size;
                    if (self.currentTab() == rtab) self.renderTab(rtab);
                    return;
                }
            }
        }
        const a = self.allocator;
        const name = a.dupe(u8, display) catch return;
        const kind = a.dupe(u8, if (e.kind.len > 0) e.kind else "file") catch {
            a.free(name);
            return;
        };
        const tgt = a.dupe(u8, e.path) catch {
            a.free(name);
            a.free(kind);
            return;
        };
        dir.entries.append(a, .{
            .name = name,
            .kind = kind,
            .size = e.size,
            .mode = 0,
            .mtime_ms = 0,
            .target = tgt,
            .tdir = std.mem.eql(u8, kind, "dir"),
        }) catch {
            a.free(name);
            a.free(kind);
            a.free(tgt);
            return;
        };
        if (self.currentTab() == rtab) self.renderTab(rtab);
    }

    fn onSearchUnmatch(self: *BrowserView, path: []const u8) void {
        const rtab = self.search_tab orelse return;
        var i: usize = 0;
        while (i < rtab.root.entries.items.len) {
            const target = rtab.root.entries.items[i].target orelse {
                i += 1;
                continue;
            };
            if (!std.mem.eql(u8, target, path)) {
                i += 1;
                continue;
            }
            var entry = rtab.root.entries.orderedRemove(i);
            entry.deinit(self.allocator);
        }
        if (self.currentTab() == rtab) self.renderTab(rtab);
    }

    fn onSearchToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const on = c.gtk_toggle_button_get_active(btn) != 0;
        c.gtk_widget_set_visible(self.search_bar, if (on) 1 else 0);
        if (on) _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(self.search_entry)));
    }

    fn onSearchActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.startSearch();
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
            const txt = if (!t.started)
                std.fmt.bufPrintZ(&lbl, "⇄ {s} — [queued]", .{t.label}) catch "transfer"
            else
                std.fmt.bufPrintZ(&lbl, "⇄ {s} — {d}% ({d}/{d} MB)", .{
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

    // ── preview pane + thumbnails ───────────────────────────────

    fn clearThumbCache(self: *BrowserView) void {
        var it = self.thumbs.iterator();
        while (it.next()) |kv| {
            c.g_object_unref(@ptrCast(kv.value_ptr.*));
            self.allocator.free(kv.key_ptr.*);
        }
        self.thumbs.clearRetainingCapacity();
    }

    /// A bounded-decode thumbnail texture for a LOCAL image file,
    /// cached by path+mtime (a changed file re-decodes).
    fn thumbTexture(self: *BrowserView, path: []const u8, mtime_ms: i64) ?*c.GdkTexture {
        var key_buf: [4200]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{d}", .{ path, mtime_ms }) catch return null;
        if (self.thumbs.get(key)) |t| return t;
        if (self.thumbs.count() >= THUMB_CACHE_CAP) self.clearThumbCache();
        var z: [4200:0]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return null;
        const pixbuf = c.gdk_pixbuf_new_from_file_at_size(pz.ptr, 24, 24, null) orelse return null;
        const tex = c.gdk_texture_new_for_pixbuf(pixbuf) orelse {
            c.g_object_unref(pixbuf);
            return null;
        };
        c.g_object_unref(pixbuf);
        const owned_key = self.allocator.dupe(u8, key) catch {
            c.g_object_unref(@as(?*anyopaque, @ptrCast(tex)));
            return null;
        };
        self.thumbs.put(owned_key, tex) catch {
            self.allocator.free(owned_key);
            c.g_object_unref(@as(?*anyopaque, @ptrCast(tex)));
            return null;
        };
        return tex;
    }

    fn clearPreviewContent(self: *BrowserView) void {
        c.gtk_picture_set_paintable(@ptrCast(self.preview_pic), null);
        c.gtk_label_set_text(self.preview_text, "");
    }

    fn abandonPreviewRead(self: *BrowserView) void {
        if (self.preview_read) |pr| {
            pr.destroy(self.allocator);
            self.preview_read = null;
        }
    }

    /// Refresh the preview panel from the current tab's selection.
    fn updatePreview(self: *BrowserView) void {
        if (!self.preview_on) return;
        self.abandonPreviewRead();
        self.clearPreviewContent();
        const tab = self.currentTab() orelse {
            c.gtk_label_set_text(self.preview_meta, "");
            return;
        };
        if (tab.selected.items.len == 0) {
            c.gtk_label_set_text(self.preview_meta, "No selection");
            return;
        }
        const path = tab.selected.items[tab.selected.items.len - 1];
        const entry = entryForPath(tab, path);

        var meta: [1024:0]u8 = undefined;
        var w = std.Io.Writer.fixed(meta[0 .. meta.len - 1]);
        w.print("{s}", .{std.fs.path.basename(path)}) catch {};
        if (entry) |e| {
            var sz: [48:0]u8 = undefined;
            var tz: [40:0]u8 = undefined;
            w.print("\n{s}", .{e.kind}) catch {};
            if (!std.mem.eql(u8, e.kind, "dir"))
                w.print("  {s}", .{fmtSize(&sz, e.size)}) catch {};
            if (e.mtime_ms != 0)
                w.print("\n{s}", .{fmtTimeZ(&tz, e.mtime_ms)}) catch {};
            if (e.tags.len > 0) w.print("\ntags: {s}", .{e.tags}) catch {};
        }
        meta[w.buffered().len] = 0;
        c.gtk_label_set_text(self.preview_meta, &meta);

        // Directories: metadata only.
        if (entry != null and entry.?.tdir) return;
        const is_image = isImageName(path);
        const known_size: u64 = if (entry) |e| e.size else 0;
        if (is_image and known_size > PREVIEW_IMAGE_CAP) {
            c.gtk_label_set_text(self.preview_text, "(image too large to preview)");
            return;
        }

        if (tab.hc.host == null) {
            self.previewLocal(path, is_image);
        } else {
            self.previewRemoteStart(tab, path, is_image);
        }
    }

    fn previewLocal(self: *BrowserView, path: []const u8, is_image: bool) void {
        var z: [4200:0]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return;
        if (is_image) {
            const pixbuf = c.gdk_pixbuf_new_from_file_at_size(pz.ptr, 480, 480, null) orelse {
                c.gtk_label_set_text(self.preview_text, "(cannot decode image)");
                return;
            };
            const tex = c.gdk_texture_new_for_pixbuf(pixbuf);
            c.g_object_unref(pixbuf);
            if (tex) |t| {
                c.gtk_picture_set_paintable(@ptrCast(self.preview_pic), @ptrCast(t));
                c.g_object_unref(@as(?*anyopaque, @ptrCast(t)));
            }
            return;
        }
        const f = c.fopen(pz.ptr, "rb") orelse return;
        var head: [PREVIEW_TEXT_CAP]u8 = undefined;
        const n = c.fread(&head, 1, head.len, f);
        _ = c.fclose(f);
        self.showTextPreview(head[0..n]);
    }

    fn showTextPreview(self: *BrowserView, data: []const u8) void {
        if (data.len == 0) {
            c.gtk_label_set_text(self.preview_text, "(empty file)");
            return;
        }
        if (std.mem.indexOfScalar(u8, data, 0) != null) {
            c.gtk_label_set_text(self.preview_text, "(binary file)");
            return;
        }
        var z: [PREVIEW_TEXT_CAP + 1:0]u8 = undefined;
        const n = @min(data.len, PREVIEW_TEXT_CAP);
        @memcpy(z[0..n], data[0..n]);
        z[n] = 0;
        const valid = c.g_utf8_make_valid(&z, @intCast(n));
        c.gtk_label_set_text(self.preview_text, valid);
        c.g_free(valid);
    }

    fn previewRemoteStart(self: *BrowserView, tab: *BTab, path: []const u8, is_image: bool) void {
        if (tab.hc.state != .ready) return;
        const pr = self.allocator.create(PreviewRead) catch return;
        pr.* = .{
            .req = self.nextReq(),
            .hc = tab.hc,
            .path = self.allocator.dupe(u8, path) catch {
                self.allocator.destroy(pr);
                return;
            },
            .is_image = is_image,
            .cap = if (is_image) PREVIEW_IMAGE_CAP else PREVIEW_TEXT_CAP,
        };
        self.preview_read = pr;
        c.gtk_label_set_text(self.preview_text, "loading…");
        self.sendOp(tab.hc, .{ .req = pr.req, .op = "read", .path = pr.path, .off = pr.off, .len = @as(u64, @intCast(pr.cap)) });
    }

    /// Feed preview-fetch frames; true when consumed.
    fn feedPreview(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
        const pr = self.preview_read orelse return false;
        if (pr.hc != hc) return false;
        switch (ftype) {
            .fs_data => {
                if (payload.len < 12) return false;
                if (std.mem.readInt(u32, payload[0..4], .little) != pr.req) return false;
                pr.buf.appendSlice(self.allocator, payload[12..]) catch {};
                return true;
            },
            .fs_reply => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                    .ignore_unknown_fields = true,
                }) catch return false;
                if (rep.req != pr.req) return false;
                if (!rep.ok) {
                    c.gtk_label_set_text(self.preview_text, "(cannot read file)");
                    self.abandonPreviewRead();
                    return true;
                }
                pr.off = pr.buf.items.len;
                if (rep.eof or pr.buf.items.len >= pr.cap) {
                    self.finishPreviewRead();
                } else {
                    pr.req = self.nextReq();
                    self.sendOp(pr.hc, .{
                        .req = pr.req,
                        .op = "read",
                        .path = pr.path,
                        .off = pr.off,
                        .len = @as(u64, @intCast(pr.cap - pr.buf.items.len)),
                    });
                }
                return true;
            },
            else => return false,
        }
    }

    fn finishPreviewRead(self: *BrowserView) void {
        const pr = self.preview_read orelse return;
        if (pr.is_image) {
            const bytes = c.g_bytes_new(pr.buf.items.ptr, pr.buf.items.len);
            const tex = c.gdk_texture_new_from_bytes(bytes, null);
            c.g_bytes_unref(bytes);
            if (tex) |t| {
                c.gtk_label_set_text(self.preview_text, "");
                c.gtk_picture_set_paintable(@ptrCast(self.preview_pic), @ptrCast(t));
                c.g_object_unref(@as(?*anyopaque, @ptrCast(t)));
            } else {
                c.gtk_label_set_text(self.preview_text, "(cannot decode image)");
            }
        } else {
            self.showTextPreview(pr.buf.items);
        }
        self.abandonPreviewRead();
    }

    fn onPreviewToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.preview_on = c.gtk_toggle_button_get_active(btn) != 0;
        c.gtk_widget_set_visible(self.preview_box, @intFromBool(self.preview_on));
        if (self.preview_on) self.updatePreview() else self.abandonPreviewRead();
    }

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

        const search_toggle = c.gtk_toggle_button_new();
        c.gtk_button_set_icon_name(@ptrCast(search_toggle), "system-search-symbolic");
        c.gtk_widget_set_tooltip_text(search_toggle, "Search this directory (daemon-side, recursive)");
        _ = c.g_signal_connect_data(search_toggle, "toggled", @ptrCast(&onSearchToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), search_toggle);

        const preview_toggle = c.gtk_toggle_button_new();
        c.gtk_button_set_icon_name(@ptrCast(preview_toggle), "view-dual-symbolic");
        c.gtk_widget_set_tooltip_text(preview_toggle, "Preview panel (images, text head, metadata)");
        _ = c.g_signal_connect_data(preview_toggle, "toggled", @ptrCast(&onPreviewToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), preview_toggle);

        const newtab = c.gtk_button_new_from_icon_name("tab-new-symbolic");
        c.gtk_widget_set_tooltip_text(newtab, "New browser tab");
        _ = c.g_signal_connect_data(newtab, "clicked", @ptrCast(&onNewTabClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), newtab);

        const term = c.gtk_button_new_from_icon_name("utilities-terminal-symbolic");
        c.gtk_widget_set_tooltip_text(term, "Show the pane's terminal (browser stays one click away)");
        _ = c.g_signal_connect_data(term, "clicked", @ptrCast(&onTerminalClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), term);

        c.gtk_box_append(@ptrCast(vbox), bar);

        const sbar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_set_margin_start(sbar, 4);
        c.gtk_widget_set_margin_end(sbar, 4);
        c.gtk_widget_set_margin_bottom(sbar, 4);
        const sentry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(sentry, 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(sentry), "name/glob, content toggle, or !command to panelize host output");
        _ = c.g_signal_connect_data(sentry, "activate", @ptrCast(&onSearchActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(sbar), sentry);
        const scontent = c.gtk_check_button_new_with_label("in contents");
        c.gtk_box_append(@ptrCast(sbar), scontent);
        c.gtk_widget_set_visible(sbar, 0);
        c.gtk_box_append(@ptrCast(vbox), sbar);

        const notebook = c.gtk_notebook_new();
        c.gtk_notebook_set_scrollable(@ptrCast(notebook), 1);
        c.gtk_widget_set_hexpand(notebook, 1);
        c.gtk_widget_set_vexpand(notebook, 1);
        _ = c.g_signal_connect_data(notebook, "switch-page", @ptrCast(&onSwitchPage), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Content row: notebook | preview panel (hidden until toggled).
        const content = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_hexpand(content, 1);
        c.gtk_widget_set_vexpand(content, 1);
        c.gtk_box_append(@ptrCast(content), notebook);

        const pbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
        c.gtk_widget_set_size_request(pbox, 300, -1);
        c.gtk_widget_set_margin_start(pbox, 8);
        c.gtk_widget_set_margin_end(pbox, 8);
        c.gtk_widget_set_margin_top(pbox, 8);
        const pmeta = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(pmeta), 0);
        c.gtk_label_set_wrap(@ptrCast(pmeta), 1);
        c.gtk_label_set_selectable(@ptrCast(pmeta), 1);
        c.gtk_box_append(@ptrCast(pbox), pmeta);
        const ppic = c.gtk_picture_new();
        c.gtk_widget_set_size_request(ppic, 284, 200);
        c.gtk_box_append(@ptrCast(pbox), ppic);
        const ptext_scroll = c.gtk_scrolled_window_new();
        c.gtk_widget_set_vexpand(ptext_scroll, 1);
        const ptext = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(ptext), 0);
        c.gtk_label_set_yalign(@ptrCast(ptext), 0);
        c.gtk_label_set_wrap(@ptrCast(ptext), 1);
        c.gtk_label_set_selectable(@ptrCast(ptext), 1);
        c.gtk_widget_add_css_class(ptext, "monospace");
        c.gtk_scrolled_window_set_child(@ptrCast(ptext_scroll), ptext);
        c.gtk_box_append(@ptrCast(pbox), ptext_scroll);
        c.gtk_widget_set_visible(pbox, 0);
        c.gtk_box_append(@ptrCast(content), pbox);

        c.gtk_box_append(@ptrCast(vbox), content);

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
        self.search_bar = sbar;
        self.search_entry = @ptrCast(@alignCast(sentry));
        self.search_content = scontent;
        self.hidden_toggle = @ptrCast(@alignCast(hidden));
        self.preview_box = pbox;
        self.preview_pic = ppic;
        self.preview_text = @ptrCast(@alignCast(ptext));
        self.preview_meta = @ptrCast(@alignCast(pmeta));
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
        if (self.currentTab()) |tab| tab.show_hidden = c.gtk_toggle_button_get_active(btn) != 0;
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
        if (self.switch_idle == 0)
            self.switch_idle = c.g_idle_add(@ptrCast(&idleAfterSwitch), @ptrCast(self));
    }
    fn idleAfterSwitch(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.switch_idle = 0;
        if (self.currentTab()) |t| {
            c.gtk_toggle_button_set_active(self.hidden_toggle, @intFromBool(t.show_hidden));
            self.syncPathEntry(t);
            self.renderTab(t);
        }
        self.updatePreview();
        return 0;
    }
};

fn launchLocal(path: []const u8) void {
    var uri_buf: [4300:0]u8 = undefined;
    const uri = std.fmt.bufPrintZ(&uri_buf, "file://{s}", .{path}) catch return;
    _ = c.g_app_info_launch_default_for_uri(uri.ptr, null, null);
}

/// Launch a specific installed application (by GAppInfo id) on a
/// local path; falls back to the default handler if the id vanished.
fn launchLocalWithApp(appid: []const u8, path: []const u8) void {
    var uri_buf: [4300:0]u8 = undefined;
    const uri = std.fmt.bufPrintZ(&uri_buf, "file://{s}", .{path}) catch return;
    const apps = c.g_app_info_get_all();
    defer if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
    var it = apps;
    while (it != null) : (it = it.*.next) {
        const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
        const id = c.g_app_info_get_id(app) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(id), appid)) continue;
        var list: ?*c.GList = null;
        list = c.g_list_append(list, @ptrCast(@constCast(uri.ptr)));
        _ = c.g_app_info_launch_uris(app, list, null, null);
        c.g_list_free(list);
        return;
    }
    launchLocal(path);
}

/// True when a ';'-separated .desktop MimeType list contains `mime`.
fn mimeListContains(list: []const u8, mime: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ';');
    while (it.next()) |m| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, m, " "), mime)) return true;
    }
    return false;
}

/// Substitute a .desktop Exec line's field codes: %f/%F/%u/%U become
/// the single-quoted path; other % codes are dropped; %% = literal %.
fn buildHostExecCmd(allocator: std.mem.Allocator, exec: []const u8, path: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var substituted = false;
    while (i < exec.len) : (i += 1) {
        if (exec[i] != '%' or i + 1 >= exec.len) {
            out.append(allocator, exec[i]) catch return null;
            continue;
        }
        i += 1;
        switch (exec[i]) {
            'f', 'F', 'u', 'U' => {
                appendQuoted(&out, allocator, path) catch return null;
                substituted = true;
            },
            '%' => out.append(allocator, '%') catch return null,
            else => {},
        }
    }
    if (!substituted) {
        out.append(allocator, ' ') catch return null;
        appendQuoted(&out, allocator, path) catch return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8) !void {
    try out.append(allocator, '\'');
    for (path) |ch| {
        if (ch == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, ch);
    }
    try out.append(allocator, '\'');
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

test "buildHostExecCmd substitutes and quotes field codes" {
    const t = std.testing;
    const a = t.allocator;
    const cmd = buildHostExecCmd(a, "gimp %U", "/tmp/a'b.png").?;
    defer a.free(cmd);
    try t.expectEqualStrings("gimp '/tmp/a'\\''b.png'", cmd);
    const cmd2 = buildHostExecCmd(a, "vlc --no-video %f %i", "/x.mp4").?;
    defer a.free(cmd2);
    try t.expectEqualStrings("vlc --no-video '/x.mp4' ", cmd2);
    // No field code at all: the path appends.
    const cmd3 = buildHostExecCmd(a, "xdg-open", "/f").?;
    defer a.free(cmd3);
    try t.expectEqualStrings("xdg-open '/f'", cmd3);
    // %% stays a literal percent.
    const cmd4 = buildHostExecCmd(a, "prog 100%% %f", "/f").?;
    defer a.free(cmd4);
    try t.expectEqualStrings("prog 100% '/f'", cmd4);
}

test "mimeListContains matches ';'-separated segments" {
    const t = std.testing;
    try t.expect(mimeListContains("image/png;image/jpeg;", "image/png"));
    try t.expect(mimeListContains("image/png;image/jpeg", "IMAGE/JPEG"));
    try t.expect(!mimeListContains("image/png;image/jpeg", "image/jp"));
    try t.expect(!mimeListContains("", "image/png"));
}

test "isImageName recognizes previewable extensions" {
    const t = std.testing;
    try t.expect(isImageName("photo.JPG"));
    try t.expect(isImageName("a.webp"));
    try t.expect(!isImageName("notes.txt"));
    try t.expect(!isImageName("jpg"));
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
