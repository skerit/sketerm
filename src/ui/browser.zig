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
const places_mod = @import("../filebrowser/places.zig");
const emblems_mod = @import("../filebrowser/emblems.zig");
const thumbs_mod = @import("../filebrowser/thumbs.zig");
const fsjob = @import("../mux/fsjob.zig");
const mounts = @import("../util/mounts.zig");
const input = @import("input.zig");
const Pane = @import("pane.zig").Pane;
const file_transfers = @import("file_transfers.zig");

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
    /// Values for the tab's attribute columns, in column order.
    attrs: [][]u8 = &.{},

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        if (self.target) |t| allocator.free(t);
        if (self.tags.len > 0) allocator.free(self.tags);
        for (self.attrs) |v| allocator.free(v);
        if (self.attrs.len > 0) allocator.free(self.attrs);
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
    attrs: []const []const u8 = &.{},
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
    home: []const u8 = "",
    cache: []const u8 = "",
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
    hash: []const u8 = "",

    /// True for the events that end a job.
    fn terminalEv(self: WireJobEv) bool {
        return std.mem.eql(u8, self.ev, "done") or
            std.mem.eql(u8, self.ev, "error") or
            std.mem.eql(u8, self.ev, "canceled");
    }
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
    /// The host's cache dir (thumbnail placement); fetched once via
    /// the homedir op.
    cache_dir: ?[]u8 = null,
    cache_req: u32 = 0,

    fn label(self: *const HostConn) []const u8 {
        return self.host orelse "local";
    }

    fn destroy(self: *HostConn, allocator: std.mem.Allocator) void {
        if (self.watch_id != 0) _ = c.g_source_remove(self.watch_id);
        if (self.state == .ready) self.conn.deinit();
        if (self.cache_dir) |cd| allocator.free(cd);
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
    /// Archive-browse mode: rows are MEMBERS of this archive path
    /// (owned); activation extracts host-side then opens.
    archive: []u8 = &.{},
    /// Sort parameters (kept on the Dir so delta-driven re-sorts in
    /// onDelta need no tab lookup); the owning tab pushes changes.
    sort_key: browser_model.SortKey = .name,
    /// Attribute-column index this dir is sorted by, if any.
    attr_sort: ?usize = null,
    descending: bool = false,
    dirs_first: bool = true,

    fn deinit(self: *Dir) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        if (self.archive.len > 0) self.allocator.free(self.archive);
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
        var attrs: [][]u8 = &.{};
        if (we.attrs.len > 0) attrs = blk: {
            const values = a.alloc([]u8, we.attrs.len) catch break :blk &.{};
            for (we.attrs, 0..) |v, i| {
                values[i] = a.dupe(u8, v) catch {
                    // Partial ownership would make deinit free memory
                    // it does not own; drop the whole set instead.
                    for (values[0..i]) |owned| a.free(owned);
                    a.free(values);
                    break :blk &.{};
                };
            }
            break :blk values;
        };
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
            .attrs = attrs,
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
        const Ctx = struct { key: browser_model.SortKey, desc: bool, dirs_first: bool, attr: ?usize };
        std.mem.sort(Entry, self.entries.items, Ctx{
            .key = self.sort_key,
            .desc = self.descending,
            .dirs_first = self.dirs_first,
            .attr = self.attr_sort,
        }, struct {
            fn lt(ctx: Ctx, a_in: Entry, b_in: Entry) bool {
                // dirs-first is decided BEFORE the descending swap so
                // it never inverts.
                if (ctx.dirs_first and a_in.tdir != b_in.tdir) return a_in.tdir;
                const a = if (ctx.desc) b_in else a_in;
                const b = if (ctx.desc) a_in else b_in;
                if (ctx.attr) |i| {
                    const av = if (i < a.attrs.len) a.attrs[i] else "";
                    const bv = if (i < b.attrs.len) b.attrs[i] else "";
                    // Entries WITHOUT the attribute sort last either
                    // way: an empty value is absence, not "smallest".
                    if ((av.len == 0) != (bv.len == 0)) return bv.len == 0;
                    if (!std.mem.eql(u8, av, bv)) return std.ascii.lessThanIgnoreCase(av, bv);
                    return std.ascii.lessThanIgnoreCase(a.name, b.name);
                }
                return switch (ctx.key) {
                    .size => if (a.size != b.size) a.size < b.size else std.ascii.lessThanIgnoreCase(a.name, b.name),
                    .mtime => if (a.mtime_ms != b.mtime_ms) a.mtime_ms < b.mtime_ms else std.ascii.lessThanIgnoreCase(a.name, b.name),
                    .ctime => if (a.ctime_ms != b.ctime_ms) a.ctime_ms < b.ctime_ms else std.ascii.lessThanIgnoreCase(a.name, b.name),
                    .kind => if (!std.mem.eql(u8, a.kind, b.kind)) std.mem.lessThan(u8, a.kind, b.kind) else std.ascii.lessThanIgnoreCase(a.name, b.name),
                    .owner => if (a.uid != b.uid) a.uid < b.uid else std.ascii.lessThanIgnoreCase(a.name, b.name),
                    .group => if (a.gid != b.gid) a.gid < b.gid else std.ascii.lessThanIgnoreCase(a.name, b.name),
                    .permissions => if (a.mode != b.mode) a.mode < b.mode else std.ascii.lessThanIgnoreCase(a.name, b.name),
                    .name => std.ascii.lessThanIgnoreCase(a.name, b.name),
                };
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
    navigation_generation: u64 = 0,
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
    /// Details/compact sort header (hidden in grid/miller). Rebuilt
    /// whenever the column set or sort changes.
    header_box: *c.GtkWidget = undefined,
    /// Optional details columns, rendered in Column declaration order.
    columns: std.EnumSet(browser_model.Column) =
        std.EnumSet(browser_model.Column).initMany(&browser_model.default_columns),
    /// Extended-attribute columns (full user.* names, owned). Their
    /// values ride the listing itself, so a remote attribute column
    /// costs no extra round trip per row.
    attr_columns: std.ArrayList([]u8) = .empty,
    /// Index into attr_columns the view is sorted by, if any.
    attr_sort: ?usize = null,
    /// The scrolled window whose child swaps listbox <-> flowbox.
    scroller: *c.GtkWidget = undefined,
    /// Icon-grid view (lazily created).
    flowbox: ?*c.GtkFlowBox = null,
    /// Miller mode: ancestor columns to the LEFT of the listbox.
    /// Each column subscribes its directory like a subdir does.
    miller_box: *c.GtkWidget = undefined,
    ancestors: std.ArrayList(*Dir) = .empty,
    /// Grid view lives in its own scroller so the listbox (and every
    /// popover parented near it) never leaves the widget tree.
    flow_scroller: ?*c.GtkWidget = null,

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
        for (self.ancestors.items) |d| {
            if (d.view_id == view_id) return d;
        }
        return null;
    }

    /// Push the tab's sort parameters onto every live Dir and re-sort.
    fn applySort(self: *BTab) void {
        const dirs = [_]?*Dir{self.root};
        for (dirs) |d| {
            d.?.sort_key = self.sort_key;
            d.?.attr_sort = self.attr_sort;
            d.?.descending = self.descending;
            d.?.dirs_first = self.dirs_first;
            d.?.sort();
        }
        for (self.subdirs.items) |d| {
            d.sort_key = self.sort_key;
            d.attr_sort = self.attr_sort;
            d.descending = self.descending;
            d.dirs_first = self.dirs_first;
            d.sort();
        }
    }

    fn dropAncestors(self: *BTab) void {
        for (self.ancestors.items) |d| {
            self.view.cancelPendingDir(d);
            self.view.closeViewOf(self.hc, d);
            d.deinit();
        }
        self.ancestors.clearRetainingCapacity();
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
        return std.fmt.bufPrint(buf, "local:{s}", .{self.root.path}) catch self.root.path;
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
        self.dropAncestors();
        self.ancestors.deinit(a);
        self.root.deinit();
        for (self.back.items) |p| a.free(p);
        self.back.deinit(a);
        for (self.fwd.items) |p| a.free(p);
        self.fwd.deinit(a);
        for (self.selected.items) |p| a.free(p);
        self.selected.deinit(a);
        for (self.attr_columns.items) |name| a.free(name);
        self.attr_columns.deinit(a);
        if (self.filter.len > 0) a.free(self.filter);
        if (self.virtual_spec.len > 0) a.free(self.virtual_spec);
        a.destroy(self);
    }
};

/// In-flight listing request (open_view or refresh `list`). `sent`
/// is false while the tab's host is still connecting; the connect
/// handback flushes unsent requests.
const NavigationIntent = enum { push, back, forward };

const Pending = struct {
    req: u32,
    tab: *BTab,
    /// Accumulating target; entries replace dir.entries when the
    /// chunk run ends.
    dir: *Dir,
    hc: *HostConn,
    op: enum { open_view, list },
    navigation: ?NavigationIntent = null,
    navigation_generation: u64 = 0,
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
    /// Pushed to the undo stack when the job finishes.
    undo_op: ?*UndoOp = null,
    /// Trash jobs learn the trashed/info paths only at DONE; this
    /// holds the ORIGINAL path until then (owned).
    undo_trash_orig: ?[]u8 = null,
    open_on_done: bool = false,
    history_op: ?*UndoOp = null,
    history_direction: ?HistoryDirection = null,

    fn terminal(self: *const JobRow) bool {
        return self.state == .finished or self.state == .failed or self.state == .canceled;
    }
};

/// A job-start request awaiting its reply (which carries the id).
const PendingJob = struct {
    req: u32,
    hc: *HostConn,
    label: []u8,
    kind: enum { normal, search, compare_left, compare_right, calc_size, dup_scan, archive_list } = .normal,
    undo_op: ?*UndoOp = null,
    undo_trash_orig: ?[]u8 = null,
    /// The done event's `path` opens when the job lands (archive
    /// member extraction).
    open_on_done: bool = false,
    history_op: ?*UndoOp = null,
    history_direction: ?HistoryDirection = null,
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
    /// Cross-host move: delete the source after a verified copy.
    delete_src_after: bool = false,
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
    /// Hash-verify pass over equal-size "differs" rows.
    hpairs: std.ArrayList(*CmpPair) = .empty,

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
    const Action = enum(c.guint) { skip = 0, to_right = 1, to_left = 2, delete = 3 };
    const DiffRow = struct {
        rel: []u8,
        dir: bool,
        status: DiffStatus,
        l: ?CmpInfo,
        r: ?CmpInfo,
        dd: *c.GtkWidget,
        lab: *c.GtkWidget,
    };

    const CmpPair = struct {
        row: *DiffRow,
        l_req: u32,
        r_req: u32,
        l_job: u64 = 0,
        r_job: u64 = 0,
        l_hash: [64]u8 = undefined,
        r_hash: [64]u8 = undefined,
        l_have: bool = false,
        r_have: bool = false,
        failed: bool = false,
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

        const options = [_:null]?[*:0]const u8{ "Skip", "Copy to target", "Copy to source", "Delete (from the side that has it)" };
        const dd = c.gtk_drop_down_new_from_strings(@ptrCast(&options));
        c.gtk_drop_down_set_selected(@ptrCast(dd), @intFromEnum(action));
        c.gtk_box_append(@ptrCast(hbox), dd);

        const lrow = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(lrow), hbox);
        c.gtk_list_box_append(self.listbox, lrow);

        row.* = .{ .rel = rel_owned, .dir = is_dir, .status = status, .l = l, .r = r, .dd = dd, .lab = lab };
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
                if (trunc) " WARNING: scan truncated at 100k entries/side — comparison is PARTIAL." else "",
            }) catch "identical"
        else
            std.fmt.bufPrintZ(&info, "{d} difference(s). Review directions, then Execute.{s}", .{
                ndiff,
                if (trunc) " WARNING: scan truncated at 100k entries/side — comparison is PARTIAL." else "",
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
                3 => .delete,
                else => .skip,
            };
            if (action == .skip) continue;
            if (self.excluded(row.rel)) {
                excluded_n += 1;
                continue;
            }
            if (action == .delete) {
                // Mirror deletion: remove the row's entry from the
                // side that has it (only-one-side rows).
                const del_side = if (row.l != null and row.r == null) &self.left else if (row.r != null and row.l == null) &self.right else continue;
                var del_buf: [4096]u8 = undefined;
                const dp = std.fmt.bufPrint(&del_buf, "{s}/{s}", .{ del_side.root, row.rel }) catch continue;
                var dlbl: [128]u8 = undefined;
                const dl = std.fmt.bufPrint(&dlbl, "mirror delete {s}", .{std.fs.path.basename(row.rel)}) catch "mirror delete";
                view.startDaemonJob(del_side.hc, "delete_tree", dp, "", dl);
                started += 1;
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
        for (self.hpairs.items) |pp| self.allocator.destroy(pp);
        self.hpairs.deinit(self.allocator);
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
    /// Hash-verify equal-size "differs" rows: identical digests
    /// flip the row to Skip (mtime noise, not content).
    fn startHashVerify(self: *CompareCtx) void {
        const view = self.view;
        var started: usize = 0;
        for (self.rows.items) |row| {
            if (started >= 40) break;
            if (row.status != .differs or row.dir) continue;
            if (row.l == null or row.r == null or row.l.?.size != row.r.?.size) continue;
            const already = for (self.hpairs.items) |pp| {
                if (pp.row == row) break true;
            } else false;
            if (already) continue;
            const pp = self.allocator.create(CmpPair) catch break;
            pp.* = .{ .row = row, .l_req = view.nextReq(), .r_req = view.nextReq() };
            self.hpairs.append(self.allocator, pp) catch {
                self.allocator.destroy(pp);
                break;
            };
            var pbuf: [4096]u8 = undefined;
            const lp = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ self.left.root, row.rel }) catch continue;
            view.sendOp(self.left.hc, .{ .req = pp.l_req, .op = "hash", .path = lp });
            const rp = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ self.right.root, row.rel }) catch continue;
            view.sendOp(self.right.hc, .{ .req = pp.r_req, .op = "hash", .path = rp });
            started += 1;
        }
        view.setStatusFmt("hash-verifying {d} equal-size row(s)…", .{started});
    }

    /// Match a hash-job start reply to a pair. True when consumed.
    fn consumeHashStart(self: *CompareCtx, hc: *HostConn, rep: WireReply) bool {
        for (self.hpairs.items) |pp| {
            if (hc == self.left.hc and pp.l_req == rep.req and pp.l_job == 0) {
                if (rep.ok and rep.job != 0) pp.l_job = rep.job else pp.failed = true;
                return true;
            }
            if (hc == self.right.hc and pp.r_req == rep.req and pp.r_job == 0) {
                if (rep.ok and rep.job != 0) pp.r_job = rep.job else pp.failed = true;
                return true;
            }
        }
        return false;
    }

    /// Hash-job done events for verify pairs. True when consumed.
    fn consumeHashEvent(self: *CompareCtx, hc: *HostConn, e: WireJobEv) bool {
        if (!std.mem.eql(u8, e.ev, "done") or e.hash.len != 64) return false;
        for (self.hpairs.items) |pp| {
            if (hc == self.left.hc and pp.l_job == e.job and pp.l_job != 0 and !pp.l_have) {
                @memcpy(&pp.l_hash, e.hash[0..64]);
                pp.l_have = true;
            } else if (hc == self.right.hc and pp.r_job == e.job and pp.r_job != 0 and !pp.r_have) {
                @memcpy(&pp.r_hash, e.hash[0..64]);
                pp.r_have = true;
            } else continue;
            if (pp.l_have and pp.r_have) {
                var lz: [700:0]u8 = undefined;
                if (std.mem.eql(u8, &pp.l_hash, &pp.r_hash)) {
                    c.gtk_drop_down_set_selected(@ptrCast(pp.row.dd), @intFromEnum(Action.skip));
                    if (std.fmt.bufPrintZ(&lz, "{s}  [content IDENTICAL — mtime noise]", .{pp.row.rel})) |t| {
                        c.gtk_label_set_text(@ptrCast(pp.row.lab), t.ptr);
                    } else |_| {}
                } else {
                    if (std.fmt.bufPrintZ(&lz, "{s}  [content DIFFERS — hash mismatch]", .{pp.row.rel})) |t| {
                        c.gtk_label_set_text(@ptrCast(pp.row.lab), t.ptr);
                    } else |_| {}
                }
            }
            return false; // let the jobs panel row complete too
        }
        return false;
    }

    fn onHashVerifyClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *CompareCtx = @ptrCast(@alignCast(user.?));
        self.startHashVerify();
    }

    fn onMirrorClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *CompareCtx = @ptrCast(@alignCast(user.?));
        var n: usize = 0;
        for (self.rows.items) |row| {
            if (row.status == .right_only) {
                c.gtk_drop_down_set_selected(@ptrCast(row.dd), @intFromEnum(Action.delete));
                n += 1;
            }
        }
        self.view.setStatusFmt("mirror: {d} target-only row(s) marked for deletion — review, then Execute", .{n});
    }
    fn onCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *CompareCtx = @ptrCast(@alignCast(user.?));
        self.close();
    }
};

/// An owned collection item.
const OwnedColl = struct {
    spec: []u8,
    dir: bool,
};

/// An owned saved-search record.
const OwnedSearch = struct {
    spec: []u8,
    pattern: []u8,
    content: bool,

    fn deinitOwned(self: OwnedSearch, allocator: std.mem.Allocator) void {
        allocator.free(self.spec);
        allocator.free(self.pattern);
    }
};

/// One file-coloring rule from filecolors.conf ("glob=#RRGGBB").
const FileColor = struct {
    glob: []u8,
    color: [7]u8,
};

/// Git-status worker context. The thread runs `git status` via
/// popen (never on the GLib loop); the idle handback applies the
/// result unless the view died (orphaned) or navigation moved on
/// (generation mismatch).
const GitCtx = struct {
    view: *BrowserView,
    root: []u8,
    gen: u64,
    out: ?[]u8 = null,
    orphaned: bool = false,

    fn destroy(self: *GitCtx) void {
        const a = std.heap.c_allocator;
        a.free(self.root);
        if (self.out) |o| a.free(o);
        a.destroy(self);
    }
};

/// One undoable mutation. `a`/`b`/`p` meanings depend on kind:
/// rename_back: a = current path, b = original path;
/// delete_created: a = the path our copy created;
/// trash_restore: a = trashed path, b = original path, p = info file;
/// rmdir_created: a = the directory mkdir created.
const UndoOp = struct {
    host: ?[]u8,
    kind: enum { rename_back, delete_created, trash_restore, rmdir_created },
    a: []u8,
    b: []u8 = &.{},
    p: []u8 = &.{},

    fn destroy(self: *UndoOp, allocator: std.mem.Allocator) void {
        if (self.host) |h| allocator.free(h);
        allocator.free(self.a);
        if (self.b.len > 0) allocator.free(self.b);
        if (self.p.len > 0) allocator.free(self.p);
        allocator.destroy(self);
    }

    fn describe(self: *const UndoOp) []const u8 {
        return switch (self.kind) {
            .rename_back => "undo rename/move",
            .delete_created => "undo copy (delete the created item)",
            .trash_restore => "undo trash (restore)",
            .rmdir_created => "undo new folder",
        };
    }
};

/// A plain-op undo record waiting for its ok reply.
const PendingUndo = struct {
    req: u32,
    op: *UndoOp,
};

const HistoryDirection = enum { undo, redo };
const PendingHistory = struct {
    req: u32,
    hc: *HostConn,
    op: *UndoOp,
    direction: HistoryDirection,
};

/// Duplicate finder: a host-side scan buckets files by SIZE, then
/// same-size candidates are hash-confirmed with daemon hash jobs.
/// Only confirmed same-digest groups are reported.
const DupState = struct {
    hc: *HostConn,
    root: []u8,
    job: u64 = 0,
    scanning: bool = true,
    sizes: std.AutoHashMapUnmanaged(u64, std.ArrayList([]u8)) = .empty,
    hashes: std.ArrayList(DupHash) = .empty,

    const DupHash = struct {
        req: u32,
        job: u64 = 0,
        path: []u8,
        size: u64,
        hash: [64]u8 = undefined,
        have: bool = false,
        failed: bool = false,
    };

    /// Files hashed at most, across all buckets (bounded work).
    const MAX_HASHED = 200;

    fn destroy(self: *DupState, allocator: std.mem.Allocator) void {
        var it = self.sizes.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.items) |p| allocator.free(p);
            kv.value_ptr.deinit(allocator);
        }
        self.sizes.deinit(allocator);
        for (self.hashes.items) |h| allocator.free(h.path);
        self.hashes.deinit(allocator);
        allocator.free(self.root);
        allocator.destroy(self);
    }
};

/// Shared context between a BrowserView and its thumbnail worker
/// thread. Refcounted: the thread holds one ref, every in-flight
/// idle handback holds one; the view's deinit orphans it so late
/// results are dropped, never applied to a dead view.
const ThumbCtx = struct {
    view: *BrowserView,
    /// pthread via libc: Zig 0.16 std.Thread has no Mutex.
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    queue: std.ArrayList(ThumbReq) = .empty,
    shutdown: bool = false,
    orphaned: bool = false,
    refs: u32 = 1,
    /// LOCAL cache dir (owned, c_allocator).
    cache_dir: []u8,

    fn lock(self: *ThumbCtx) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *ThumbCtx) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn ref(self: *ThumbCtx) void {
        self.lock();
        defer self.unlock();
        self.refs += 1;
    }

    fn unref(self: *ThumbCtx) void {
        self.lock();
        self.refs -= 1;
        const dead = self.refs == 0;
        self.unlock();
        if (dead) {
            const a = std.heap.c_allocator;
            for (self.queue.items) |*q| q.deinitReq();
            self.queue.deinit(a);
            a.free(self.cache_dir);
            _ = c.pthread_mutex_destroy(&self.mutex);
            _ = c.pthread_cond_destroy(&self.cond);
            a.destroy(self);
        }
    }
};

/// One worker task: probe/generate a LOCAL thumbnail, or decode
/// remote SOURCE bytes into a spec-compliant thumbnail PNG.
const ThumbReq = struct {
    /// Absolute path on its OWNING host (key material).
    path: []u8,
    mtime_ms: i64,
    /// Remote-source bytes to decode (null = local file probe).
    data: ?[]u8 = null,
    /// Viewer-memory identity includes host; disk identity deliberately
    /// remains path-only because each host owns a separate cache.
    cache_key: []u8,
    cached_png: bool = false,
    preview_generation: u64 = 0,
    remote_id: u64 = 0,

    fn deinitReq(self: *ThumbReq) void {
        const a = std.heap.c_allocator;
        a.free(self.path);
        a.free(self.cache_key);
        if (self.data) |d| a.free(d);
    }
};

/// Worker -> main-thread handback.
const ThumbResult = struct {
    ctx: *ThumbCtx,
    /// In-memory cache key ("path\x00mtime", owned by c_allocator).
    key: []u8,
    pixbuf: ?*c.GdkPixbuf,
    /// Spec PNG bytes for remote write-back (owned, c_allocator).
    png: ?[]u8 = null,
    /// Original path (owned) — locates the remote write-back target.
    path: []u8,
    mtime_ms: i64,
    preview_generation: u64 = 0,
    remote_id: u64 = 0,
};

/// One remote thumbnail fetch in flight (serial per view).
const RemoteThumb = struct {
    id: u64,
    hc: *HostConn,
    path: []u8,
    mtime_ms: i64,
    phase: enum { start_job, wait_job, read_thumb } = .start_job,
    req: u32 = 0,
    job: u64 = 0,
    buf: std.ArrayList(u8) = .empty,

    fn destroy(self: *RemoteThumb, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
};

/// One in-flight .trashinfo fetch for Restore from Trash.
const RestoreRead = struct {
    req: u32,
    hc: *HostConn,
    /// The trashed entry (…/Trash/files/<name>).
    trashed: []u8,
    /// Its metadata file (…/Trash/info/<name>.trashinfo).
    info: []u8,
    buf: std.ArrayList(u8) = .empty,

    fn destroy(self: *RestoreRead, allocator: std.mem.Allocator) void {
        allocator.free(self.trashed);
        allocator.free(self.info);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
};

/// One in-flight remote preview fetch (chunked fs read).
const PreviewRead = struct {
    req: u32,
    hc: *HostConn,
    path: []u8,
    phase: enum { start_job, wait_job, read_asset } = .start_job,
    job: u64 = 0,
    generation: u64,
    off: u64 = 0,
    buf: std.ArrayList(u8) = .empty,

    fn destroy(self: *PreviewRead, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
};

const PathCompletion = struct {
    req: u32,
    hc: *HostConn,
    display_prefix: []u8,
    typed_prefix: []u8,
    names: std.ArrayList([]u8) = .empty,

    fn destroy(self: *PathCompletion, allocator: std.mem.Allocator) void {
        allocator.free(self.display_prefix);
        allocator.free(self.typed_prefix);
        for (self.names.items) |name| allocator.free(name);
        self.names.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Extensions the preview pane and row thumbnails treat as images
/// (decodable by gdk-pixbuf).
fn isImageName(name: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".ico", ".tif", ".tiff", ".avif", ".heic", ".heif" };
    for (exts) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

fn isWorkerImageName(name: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".ico", ".tif", ".tiff" };
    for (exts) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

fn isPreviewMediaName(name: []const u8) bool {
    if (isImageName(name)) return true;
    const exts = [_][]const u8{
        ".pdf", ".mp4", ".mkv", ".webm", ".avi", ".mov", ".m4v", ".mpeg", ".mpg",
        ".mp3", ".flac", ".ogg", ".opus", ".wav", ".m4a", ".aac",
    };
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
    next_remote_thumb_id: u64 = 1,
    next_view: u32 = 1,
    tabs: std.ArrayList(*BTab) = .empty,
    pending: std.ArrayList(*Pending) = .empty,
    pending_jobs: std.ArrayList(*PendingJob) = .empty,
    jobs: std.ArrayList(*JobRow) = .empty,
    transfers: std.ArrayList(*ActiveTransfer) = .empty,

    root_box: *c.GtkWidget = undefined,
    notebook: *c.GtkNotebook = undefined,
    path_entry: *c.GtkEntry = undefined,
    back_button: *c.GtkWidget = undefined,
    fwd_button: *c.GtkWidget = undefined,
    completion_popover: ?*c.GtkWidget = null,
    completion_request: ?*PathCompletion = null,
    completion_source: c.guint = 0,
    syncing_path_entry: bool = false,
    status_label: *c.GtkLabel = undefined,
    jobs_box: *c.GtkWidget = undefined,
    /// Copy-source for the context menu's Copy/Paste (owned).
    /// clip_paths holds the full multi-selection; clip_path mirrors
    /// its first item (single-source verbs: Sync Here, Compare).
    clip_host: ?[]u8 = null,
    clip_path: ?[]u8 = null,
    clip_paths: std.ArrayList([]u8) = .empty,
    /// Cut mode: paste MOVES (rename same-host, transfer+delete
    /// cross-host) and then clears the clipboard.
    clip_cut: bool = false,
    /// Undo stack (newest last), bounded.
    undo_stack: std.ArrayList(*UndoOp) = .empty,
    redo_stack: std.ArrayList(*UndoOp) = .empty,
    pending_undo: std.ArrayList(PendingUndo) = .empty,
    pending_history: std.ArrayList(PendingHistory) = .empty,
    history_busy: bool = false,
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
    preview_generation: u64 = 0,
    restore_read: ?*RestoreRead = null,
    /// Row-thumbnail cache: "path\x00mtime" -> owned texture ref.
    thumbs: std.StringHashMap(*c.GdkTexture) = undefined,
    /// Keys that failed to thumbnail (skip re-tries this session).
    thumb_failed: std.StringHashMap(void) = undefined,
    /// Async thumbnail worker (freedesktop cache; lazily started).
    thumb_ctx: ?*ThumbCtx = null,
    /// Serial remote-thumbnail pipeline.
    remote_thumb: ?*RemoteThumb = null,
    remote_thumb_queue: std.ArrayList(*RemoteThumb) = .empty,
    /// Coalesced re-render after thumbnails land.
    thumb_render_src: c.guint = 0,
    /// Live local-edit sync-back watches (remote files opened here).
    watches: std.ArrayList(*EditWatch) = .empty,
    /// The one open Open With chooser (its popover owns the ctx).
    openwith: ?*OpenWithCtx = null,
    /// The one open compare/sync window.
    compare: ?*CompareCtx = null,
    /// Places sidebar (bookmarks / recent / devices).
    places_scroller: *c.GtkWidget = undefined,
    places_list: *c.GtkListBox = undefined,
    places_on: bool = false,
    bookmarks: std.ArrayList([]u8) = .empty,
    recent: std.ArrayList([]u8) = .empty,
    /// Saved searches (persisted with places).
    saved_searches: std.ArrayList(OwnedSearch) = .empty,
    /// Persistent collection shelf (specs + kind).
    collection_items: std.ArrayList(OwnedColl) = .empty,
    /// The most recent search run (owned), for the save button.
    last_search: ?OwnedSearch = null,
    /// Relative-time filter for the NEXT find job ("@7d pattern").
    search_within_ms: u64 = 0,
    /// Match-cap override for the NEXT find job (compare scans).
    search_max_matches: u64 = 0,
    /// User file-coloring rules (~/.config/sketerm/filecolors.conf).
    file_colors: std.ArrayList(FileColor) = .empty,
    /// Git status overlay for the current LOCAL root: child name ->
    /// porcelain status char. Rebuilt by a worker thread per navigate.
    git_map: std.StringHashMap(u8) = undefined,
    git_root: []u8 = &.{},
    git_gen: u64 = 0,
    git_inflight: ?*GitCtx = null,
    /// Running "Calculate Size" scan (0 = none).
    calc_job: u64 = 0,
    calc_hc: ?*HostConn = null,
    calc_total: u64 = 0,
    calc_files: u64 = 0,
    /// Running duplicate scan: size-bucket phase then hash-confirm.
    dup: ?*DupState = null,
    /// Running archive listing job and its results tab.
    arch_job: u64 = 0,
    arch_hc: ?*HostConn = null,
    arch_tab: ?*BTab = null,
    /// Live $EDITOR batch-rename session (at most one).
    editor_rename: ?*EditorRename = null,
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
    /// In-flight attr_list for an open Properties dialog.
    attr_request: ?AttrRequest = null,
    /// The open column picker, so editing a column can close it.
    column_picker: ?*c.GtkWidget = null,
    /// Emblem rules (name globs / attribute predicates -> badge icon).
    emblems: emblems_mod.Rules = undefined,
    /// Label probes in flight (folder size, checksum, media info).
    probes: std.ArrayList(LabelProbe) = .empty,
    /// Resolve the other browser face in this sketerm tab (the
    /// orthodox dual-pane destination); null when there is only one.
    on_peer: ?*const fn (ctx: *anyopaque, pane: *Pane) ?*BrowserView = null,
    /// Window-owned service: durable downloads and sync-back survive
    /// this pane, this window, and GUI process restarts.
    transfer_service: ?*file_transfers.Service = null,
    /// Scratch for currentSpec's caller-visible slice.
    spec_scratch: [4300]u8 = undefined,
    /// Type-ahead jump buffer; cleared after TYPEAHEAD_RESET_US idle.
    ta_buf: [64]u8 = undefined,
    ta_len: usize = 0,
    ta_last_us: i64 = 0,

    /// Create a browser face on `pane`, starting at `start_spec`
    /// (a path or host-qualified spec; null/relative = $HOME).
    pub fn attach(allocator: std.mem.Allocator, pane: *Pane, start_spec: ?[]const u8) !*BrowserView {
        // A pane owns at most one browser face; re-attaching would
        // orphan the previous one together with its connections.
        if (fromPane(pane)) |existing| return existing;
        const self = try allocator.create(BrowserView);
        self.* = .{ .allocator = allocator, .pane = pane };
        self.emblems = emblems_mod.load(allocator);
        self.thumbs = std.StringHashMap(*c.GdkTexture).init(allocator);
        self.thumb_failed = std.StringHashMap(void).init(allocator);
        self.git_map = std.StringHashMap(u8).init(allocator);
        if (places_mod.load(allocator)) |parsed| {
            defer parsed.deinit();
            for (parsed.value.bookmarks) |b| {
                const owned = allocator.dupe(u8, b) catch continue;
                self.bookmarks.append(allocator, owned) catch allocator.free(owned);
            }
            for (parsed.value.recent) |r| {
                const owned = allocator.dupe(u8, r) catch continue;
                self.recent.append(allocator, owned) catch allocator.free(owned);
            }
            for (parsed.value.collection) |ci| {
                const spec = allocator.dupe(u8, ci.spec) catch continue;
                self.collection_items.append(allocator, .{ .spec = spec, .dir = ci.dir }) catch allocator.free(spec);
            }
            for (parsed.value.searches) |sq| {
                const spec = allocator.dupe(u8, sq.spec) catch continue;
                const pat = allocator.dupe(u8, sq.pattern) catch {
                    allocator.free(spec);
                    continue;
                };
                self.saved_searches.append(allocator, .{ .spec = spec, .pattern = pat, .content = sq.content }) catch {
                    allocator.free(spec);
                    allocator.free(pat);
                };
            }
        }
        self.loadFileColors();

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

    /// The current tab's location as a host-qualified spec, in a
    /// caller-owned static buffer valid until the next call.
    pub fn currentSpec(self: *BrowserView) ?[]const u8 {
        const tab = self.currentTab() orelse return null;
        return tab.spec(&self.spec_scratch);
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
                .columns = try columnsOf(arena, tab),
                .attr_columns = try attrColumnsOf(arena, tab),
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

    fn columnsOf(arena: std.mem.Allocator, tab: *BTab) ![]const browser_model.Column {
        var out: std.ArrayList(browser_model.Column) = .empty;
        for (std.enums.values(browser_model.Column)) |col| {
            if (tab.columns.contains(col)) try out.append(arena, col);
        }
        return out.items;
    }

    fn attrColumnsOf(arena: std.mem.Allocator, tab: *BTab) ![]const []const u8 {
        const out = try arena.alloc([]const u8, tab.attr_columns.items.len);
        for (tab.attr_columns.items, 0..) |name, i| out[i] = try arena.dupe(u8, name);
        return out;
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
        if (state.columns.len > 0) {
            tab.columns = .initEmpty();
            for (state.columns) |col| tab.columns.insert(col);
        }
        for (state.attr_columns) |name| {
            if (!std.mem.startsWith(u8, name, "user.")) continue;
            if (tab.attr_columns.items.len >= MAX_ATTR_COLUMNS) break;
            const owned = self.allocator.dupe(u8, name) catch continue;
            tab.attr_columns.append(self.allocator, owned) catch self.allocator.free(owned);
        }
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
            // A navigation candidate is owned by the request until it
            // commits; the tabs above never saw it.
            if (p.navigation != null) p.dir.deinit();
            self.allocator.destroy(p);
        }
        self.pending.deinit(self.allocator);
        for (self.pending_jobs.items) |pj| {
            if (pj.undo_op) |u| u.destroy(self.allocator);
            if (pj.undo_trash_orig) |o| self.allocator.free(o);
            if (pj.history_op) |op| op.destroy(self.allocator);
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
        }
        self.pending_jobs.deinit(self.allocator);
        for (self.jobs.items) |j| {
            if (j.undo_op) |u| u.destroy(self.allocator);
            if (j.undo_trash_orig) |o| self.allocator.free(o);
            if (j.history_op) |op| op.destroy(self.allocator);
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
        self.closePathCompletion();
        if (self.completion_source != 0) _ = c.g_source_remove(self.completion_source);
        if (self.completion_request) |request| request.destroy(self.allocator);
        self.emblems.deinit();
        self.endProbesFor(null, "");
        self.probes.deinit(self.allocator);
        self.endAttrRequest();
        if (self.preview_read) |pr| pr.destroy(self.allocator);
        if (self.restore_read) |rr| rr.destroy(self.allocator);
        if (self.dup) |d| d.destroy(self.allocator);
        if (self.editor_rename) |er| er.destroy(self.allocator);
        if (self.thumb_render_src != 0) _ = c.g_source_remove(self.thumb_render_src);
        if (self.thumb_ctx) |tc| {
            tc.lock();
            tc.orphaned = true;
            tc.shutdown = true;
            _ = c.pthread_cond_signal(&tc.cond);
            tc.unlock();
            tc.unref(); // the view's ref; thread + idles drop theirs
        }
        if (self.remote_thumb) |rt| rt.destroy(self.allocator);
        for (self.remote_thumb_queue.items) |rt| rt.destroy(self.allocator);
        self.remote_thumb_queue.deinit(self.allocator);
        for (self.undo_stack.items) |u| u.destroy(self.allocator);
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |u| u.destroy(self.allocator);
        self.redo_stack.deinit(self.allocator);
        for (self.pending_undo.items) |pu| pu.op.destroy(self.allocator);
        self.pending_undo.deinit(self.allocator);
        for (self.pending_history.items) |ph| ph.op.destroy(self.allocator);
        self.pending_history.deinit(self.allocator);
        for (self.bookmarks.items) |b| self.allocator.free(b);
        self.bookmarks.deinit(self.allocator);
        for (self.recent.items) |r| self.allocator.free(r);
        self.recent.deinit(self.allocator);
        for (self.saved_searches.items) |sq| sq.deinitOwned(self.allocator);
        self.saved_searches.deinit(self.allocator);
        for (self.collection_items.items) |ci| self.allocator.free(ci.spec);
        self.collection_items.deinit(self.allocator);
        if (self.last_search) |ls| ls.deinitOwned(self.allocator);
        for (self.file_colors.items) |fc| self.allocator.free(fc.glob);
        self.file_colors.deinit(self.allocator);
        if (self.git_inflight) |g| g.orphaned = true;
        self.clearGitMap();
        self.git_map.deinit();
        if (self.git_root.len > 0) self.allocator.free(self.git_root);
        self.clearThumbCache();
        self.thumbs.deinit();
        var fit = self.thumb_failed.iterator();
        while (fit.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.thumb_failed.deinit();
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
            if (p.sent or p.hc != hc) continue;
            self.sendListingOp(p);
        }
        self.pumpTransferQueue();
    }

    /// Connection died: fail its transfers FIRST (they hold *Conn),
    /// then release the socket. Tabs keep referencing the dead
    /// HostConn; navigating again reconnects.
    fn hostDied(self: *BrowserView, hc: *HostConn) void {
        var i: usize = 0;
        // In-flight listings can never be answered. A navigation
        // request also OWNS its candidate directory until it commits,
        // so dropping it here is what frees it.
        while (i < self.pending.items.len) {
            if (self.pending.items[i].hc == hc) self.dropPending(i) else i += 1;
        }
        i = 0;
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
        i = 0;
        while (i < self.pending_history.items.len) {
            const ph = self.pending_history.items[i];
            if (ph.hc == hc) {
                ph.op.destroy(self.allocator);
                _ = self.pending_history.orderedRemove(i);
                self.history_busy = false;
                self.setStatus("history outcome unknown after connection loss");
            } else i += 1;
        }
        for (self.pending_jobs.items) |pj| {
            if (pj.hc == hc and pj.history_op != null) {
                pj.history_op.?.destroy(self.allocator);
                pj.history_op = null;
                pj.history_direction = null;
                self.history_busy = false;
            }
        }
        for (self.jobs.items) |job| {
            if (job.hc == hc and job.history_op != null) {
                job.history_op.?.destroy(self.allocator);
                job.history_op = null;
                job.history_direction = null;
                self.history_busy = false;
            }
        }
        if (self.preview_read) |pr| {
            if (pr.hc == hc) self.abandonPreviewRead();
        }
        self.endProbesFor(hc, "host connection lost");
        if (self.attr_request) |request| {
            if (request.hc == hc) self.endAttrRequest();
        }
        if (self.remote_thumb) |rt| {
            if (rt.hc == hc) {
                rt.destroy(self.allocator);
                self.remote_thumb = null;
            }
        }
        i = 0;
        while (i < self.remote_thumb_queue.items.len) {
            const rt = self.remote_thumb_queue.items[i];
            if (rt.hc == hc) {
                _ = self.remote_thumb_queue.orderedRemove(i);
                rt.destroy(self.allocator);
            } else i += 1;
        }
        self.pumpRemoteThumbs();
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

    /// The tab's attribute columns as the wire's comma-separated
    /// request. Empty when the tab shows none, so ordinary listings
    /// pay nothing for the feature.
    fn attrSpec(self: *BrowserView, tab: *BTab, buf: []u8) []const u8 {
        var emblem_names: [MAX_ATTR_COLUMNS][]const u8 = undefined;
        const wanted = self.emblems.attrNames(&emblem_names);
        if (tab.attr_columns.items.len == 0 and wanted.len == 0) return "";
        var w = std.Io.Writer.fixed(buf);
        var n: usize = 0;
        for (tab.attr_columns.items) |name| {
            if (n > 0) w.writeByte(',') catch break;
            w.writeAll(name) catch break;
            n += 1;
        }
        // Emblem attributes ride the same listing; the column values
        // stay first so row rendering can index by column position.
        for (wanted) |name| {
            var dup = false;
            for (tab.attr_columns.items) |col| {
                if (std.mem.eql(u8, col, name)) dup = true;
            }
            if (dup or n >= MAX_ATTR_COLUMNS) continue;
            if (n > 0) w.writeByte(',') catch break;
            w.writeAll(name) catch break;
            n += 1;
        }
        return w.buffered();
    }

    fn sendListingOp(self: *BrowserView, p: *Pending) void {
        p.sent = true;
        var spec_buf: [1024]u8 = undefined;
        const attrs = self.attrSpec(p.tab, &spec_buf);
        switch (p.op) {
            .open_view => self.sendOp(p.hc, .{
                .req = p.req,
                .op = "open_view",
                .path = p.dir.path,
                .view = p.dir.view_id,
                .attrs = attrs,
            }),
            .list => self.sendOp(p.hc, .{
                .req = p.req,
                .op = "list",
                .path = p.dir.path,
                .attrs = attrs,
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
        p.* = .{ .req = req, .tab = tab, .dir = dir, .hc = tab.hc, .op = op };
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
        const alive = hc.conn.fillAvailable();
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
            if (self.feedRestore(hc, f.ftype, f.payload)) continue;
            if (self.feedRemoteThumb(hc, f.ftype, f.payload)) continue;
            if (self.feedProbes(hc, f.ftype, f.payload)) continue;
            if (self.feedAttrRequest(hc, f.ftype, f.payload)) continue;
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
        if (!alive or cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
            self.hostDied(hc);
            return 0;
        }
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
                if (t.delete_src_after) {
                    // The copy hash-verified; complete the MOVE by
                    // removing the source (recursive when a tree).
                    var lbl: [128]u8 = undefined;
                    const dlabel = std.fmt.bufPrint(&lbl, "move cleanup {s}", .{std.fs.path.basename(t.x.src_root)}) catch "move cleanup";
                    self.startDaemonJob(t.src_hc, "delete_tree", t.x.src_root, "", dlabel);
                }
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
        /// Cross-host MOVE: delete the source once the copy landed.
        delete_src_after: bool = false,
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
        if (!open_when_done and opts.upload_watch == null and !opts.delete_src_after) {
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
            .delete_src_after = opts.delete_src_after,
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
        self.openRemoteFileHc(tab.hc, path, appid);
    }

    fn openRemoteFileHc(self: *BrowserView, hc: *HostConn, path: []const u8, appid: ?[]const u8) void {
        const host = hc.host orelse return;
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
        const service = self.transfer_service orelse {
            // No ledger (another process holds it, or it is unreadable):
            // degrade to the in-view transfer rather than refusing to
            // open the file at all. It just does not survive a restart.
            const local = self.hostConnFor(null) orelse return;
            if (local.state != .ready) {
                self.setStatus("local daemon unreachable");
                return;
            }
            self.startTransfer(hc, path, local, dst, .{
                .open_when_done = true,
                .open_with_appid = appid,
                .watch_host = host,
                .watch_remote = path,
            });
            self.setStatus("download is not restart-durable (recovery ledger unavailable)");
            return;
        };
        service.submitDownload(host, path, dst, appid);
        self.setStatusFmt("durable download queued: {s}", .{std.fs.path.basename(path)});
        self.renderJobs();
    }

    /// Open a path that lives on `hc`'s host: directly for local,
    /// download-and-open for remote.
    fn openPathOnHost(self: *BrowserView, hc: *HostConn, path: []const u8) void {
        if (hc.host == null) {
            launchLocal(path);
        } else {
            self.openRemoteFileHc(hc, path, null);
        }
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
            // search_within_ms / search_max_matches are single-shot:
            // set right before their find job, zero for everything
            // else.
            const within = self.search_within_ms;
            self.search_within_ms = 0;
            const maxm = self.search_max_matches;
            self.search_max_matches = 0;
            self.sendOp(hc, .{ .req = req, .op = op, .path = path, .pattern = pattern, .within_ms = within, .max_matches = maxm });
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
            if (cmp.consumeHashEvent(hc, e)) return;
        }
        // Calculate Size scan.
        if (self.calc_job != 0 and e.job == self.calc_job and hc == self.calc_hc) {
            if (std.mem.eql(u8, e.ev, "match")) {
                if (!std.mem.eql(u8, e.kind, "dir")) {
                    self.calc_total += e.size;
                    self.calc_files += 1;
                }
                return;
            }
            if (std.mem.eql(u8, e.ev, "done")) {
                var sz: [48:0]u8 = undefined;
                self.setStatusFmt("total size: {s} in {d} file(s){s}", .{
                    fmtSize(&sz, self.calc_total),
                    self.calc_files,
                    if (e.truncated) " (PARTIAL — scan truncated)" else "",
                });
                self.calc_job = 0;
                // fall through so the jobs panel row completes too
            }
        }
        // Duplicate finder (scan phase + hash-confirm phase).
        if (self.dup) |d| {
            if (d.hc == hc and self.dupConsumeEvent(d, e)) return;
        }
        // Archive member listing.
        if (self.arch_job != 0 and e.job == self.arch_job and hc == self.arch_hc) {
            if (std.mem.eql(u8, e.ev, "match")) {
                self.onArchiveMember(e);
                return;
            }
            if (std.mem.eql(u8, e.ev, "done")) {
                self.setStatusFmt("archive: {d} member(s){s}", .{
                    e.matches, if (e.truncated) " (truncated)" else "",
                });
                self.arch_job = 0;
            } else if (std.mem.eql(u8, e.ev, "error")) {
                self.arch_job = 0;
            }
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
            if (row.undo_op) |u| {
                row.undo_op = null;
                self.pushUndo(u);
            }
            if (row.undo_trash_orig) |orig| {
                row.undo_trash_orig = null;
                if (e.path.len > 0) {
                    self.recordTrashUndo(row.hc, orig, e.path, e.text);
                }
                self.allocator.free(orig);
            }
            if (row.open_on_done and e.path.len > 0) {
                row.open_on_done = false;
                self.openPathOnHost(row.hc, e.path);
            }
            if (row.history_op) |op| {
                row.history_op = null;
                const direction = row.history_direction.?;
                row.history_direction = null;
                if (direction == .redo and op.kind == .trash_restore and e.path.len > 0)
                    self.updateTrashResult(op, e.path, e.text);
                self.finishHistory(op, direction);
            }
        } else if (std.mem.eql(u8, e.ev, "error")) {
            row.state = .failed;
            self.setStatusFmt("job failed: {s} ({s})", .{ row.label, e.message });
            if (row.undo_op) |u| {
                row.undo_op = null;
                u.destroy(self.allocator);
            }
            if (row.undo_trash_orig) |orig| {
                row.undo_trash_orig = null;
                self.allocator.free(orig);
            }
            if (row.history_op) |op| {
                row.history_op = null;
                const direction = row.history_direction.?;
                row.history_direction = null;
                self.restoreHistory(op, direction);
            }
        } else if (std.mem.eql(u8, e.ev, "canceled")) {
            row.state = .canceled;
            self.setStatusFmt("canceled: {s}", .{row.label});
            if (row.undo_op) |u| {
                row.undo_op = null;
                u.destroy(self.allocator);
            }
            if (row.undo_trash_orig) |orig| {
                row.undo_trash_orig = null;
                self.allocator.free(orig);
            }
            if (row.history_op) |op| {
                row.history_op = null;
                const direction = row.history_direction.?;
                row.history_direction = null;
                self.restoreHistory(op, direction);
            }
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

        if (self.completion_request) |completion| {
            if (completion.hc == hc and completion.req == rep.req) {
                if (!rep.ok) {
                    completion.destroy(self.allocator);
                    self.completion_request = null;
                    return false;
                }
                for (rep.entries) |entry| {
                    if (!entry.tdir) continue;
                    const name = self.allocator.dupe(u8, entry.name) catch continue;
                    completion.names.append(self.allocator, name) catch self.allocator.free(name);
                }
                if (!rep.more) {
                    self.showCompletionNames(completion.display_prefix, completion.typed_prefix, completion.names.items);
                    completion.destroy(self.allocator);
                    self.completion_request = null;
                }
                return false;
            }
        }

        // Listing chunk run?
        for (self.pending.items, 0..) |p, i| {
            if (p.req != rep.req) continue;
            if (!rep.ok) {
                self.setStatusFmt("cannot open: {s}", .{rep.@"error"});
                if (p.navigation != null and p.navigation_generation == p.tab.navigation_generation) self.syncPathEntry(p.tab);
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
                if (p.navigation) |intent| {
                    if (p.navigation_generation != p.tab.navigation_generation) {
                        self.dropPending(i);
                        return false;
                    }
                    p.navigation = null;
                    _ = self.pending.swapRemove(i);
                    p.staged.deinit(self.allocator);
                    self.commitNavigation(p.tab, p.hc, p.dir, intent, rep.path);
                    self.allocator.destroy(p);
                    return true;
                }
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
                if (pj.kind == .calc_size) {
                    self.calc_job = rep.job;
                    self.calc_hc = hc;
                    self.calc_total = 0;
                    self.calc_files = 0;
                }
                if (pj.kind == .dup_scan) {
                    if (self.dup) |d| {
                        if (d.hc == hc) d.job = rep.job;
                    }
                }
                if (pj.kind == .archive_list) {
                    self.arch_job = rep.job;
                    self.arch_hc = hc;
                }
                const row = self.allocator.create(JobRow) catch break;
                row.* = .{
                    .hc = hc,
                    .job = rep.job,
                    .label = pj.label,
                    .undo_op = pj.undo_op,
                    .undo_trash_orig = pj.undo_trash_orig,
                    .open_on_done = pj.open_on_done,
                    .history_op = pj.history_op,
                    .history_direction = pj.history_direction,
                };
                self.jobs.append(self.allocator, row) catch {
                    if (row.history_op) |op| self.restoreHistory(op, row.history_direction.?);
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
                if (pj.undo_op) |u| u.destroy(self.allocator);
                if (pj.undo_trash_orig) |o| self.allocator.free(o);
                if (pj.history_op) |op| self.restoreHistory(op, pj.history_direction.?);
                self.allocator.free(pj.label);
                _ = self.pending_jobs.orderedRemove(i);
                self.allocator.destroy(pj);
            }
            return false;
        }
        // Undo record for a plain op (rename/mkdir/move)?
        for (self.pending_undo.items, 0..) |pu, i| {
            if (pu.req != rep.req) continue;
            if (rep.ok) {
                self.pushUndo(pu.op);
            } else {
                pu.op.destroy(self.allocator);
                self.setStatusFmt("operation failed: {s}", .{rep.@"error"});
            }
            _ = self.pending_undo.orderedRemove(i);
            return false;
        }
        // Completion of a redo/undo plain mutation.
        for (self.pending_history.items, 0..) |ph, i| {
            if (ph.req != rep.req) continue;
            _ = self.pending_history.orderedRemove(i);
            if (rep.ok) {
                self.finishHistory(ph.op, ph.direction);
            } else {
                self.restoreHistory(ph.op, ph.direction);
                self.setStatusFmt("history operation failed: {s}", .{rep.@"error"});
            }
            return false;
        }
        // Compare hash-verify start reply?
        if (self.compare) |cmp| {
            if (cmp.consumeHashStart(hc, rep)) return false;
        }
        // Duplicate-finder hash-start reply?
        if (self.dup) |d| {
            if (d.hc == hc) {
                for (d.hashes.items) |*h| {
                    if (h.req == rep.req) {
                        if (rep.ok and rep.job != 0) {
                            h.job = rep.job;
                        } else {
                            h.failed = true;
                            h.job = 1; // sentinel: no longer "starting"
                            self.dupMaybeFinish();
                        }
                        return false;
                    }
                }
            }
        }
        // Host cache-dir (homedir) reply?
        if (hc.cache_req != 0 and rep.req == hc.cache_req) {
            hc.cache_req = 0;
            if (rep.ok and rep.cache.len > 0) {
                hc.cache_dir = self.allocator.dupe(u8, rep.cache) catch null;
            }
            self.pumpRemoteThumbs();
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
        if (p.navigation != null) {
            self.closeViewOf(p.hc, p.dir);
            p.dir.deinit();
        }
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

        const page = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(page, 1);
        c.gtk_widget_set_vexpand(page, 1);

        // Sort header (details/compact views); contents are built by
        // rebuildHeader once the tab exists.
        const header = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_box_append(@ptrCast(page), header);

        const content = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_hexpand(content, 1);
        c.gtk_widget_set_vexpand(content, 1);
        const miller_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_visible(miller_box, 0);
        c.gtk_box_append(@ptrCast(content), miller_box);

        const scroller = c.gtk_scrolled_window_new();
        c.gtk_widget_set_hexpand(scroller, 1);
        c.gtk_widget_set_vexpand(scroller, 1);
        const listbox = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(listbox), c.GTK_SELECTION_MULTIPLE);
        c.gtk_list_box_set_activate_on_single_click(@ptrCast(listbox), 0);
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), listbox);
        c.gtk_box_append(@ptrCast(content), scroller);
        c.gtk_box_append(@ptrCast(page), content);

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
            .page = page,
            .listbox = @ptrCast(listbox),
            .tab_label = @ptrCast(@alignCast(label)),
            .header_box = header,
            .scroller = scroller,
            .miller_box = miller_box,
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

        // Internal DnD: dropping an entry spec here moves (same
        // host) or copies (cross-host) into the target directory.
        const dropt = c.gtk_drop_target_new(c.G_TYPE_STRING, c.GDK_ACTION_COPY | c.GDK_ACTION_MOVE);
        _ = c.g_signal_connect_data(dropt, "drop", @ptrCast(&onListDrop), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(listbox, @ptrCast(dropt));

        const page_idx = c.gtk_notebook_append_page(self.notebook, page, label_box);
        c.gtk_notebook_set_current_page(self.notebook, page_idx);
        self.updateTabLabel(tab);
        self.openDir(tab, dir);
        self.syncPathEntry(tab);
        self.refreshGitOverlay(tab);
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
        if (self.arch_tab == tab) {
            self.arch_tab = null;
            self.arch_job = 0;
        }
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

    /// Navigate a tab to (host, path), recording history. Back/forward
    /// traversal goes through navigateSpecMode with its own intent.
    fn navigate(self: *BrowserView, tab: *BTab, host_in: ?[]const u8, path_in: []const u8) void {
        self.navigateMode(tab, host_in, path_in, .push);
    }

    fn navigateMode(self: *BrowserView, tab: *BTab, host_in: ?[]const u8, path_in: []const u8, intent: NavigationIntent) void {
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
        tab.navigation_generation +%= 1;
        if (tab.navigation_generation == 0) tab.navigation_generation = 1;
        // Navigation is transactional: the visible root and history do
        // not change until the candidate listing succeeds.
        const p = self.allocator.create(Pending) catch { new_dir.deinit(); return; };
        p.* = .{ .req = self.nextReq(), .tab = tab, .dir = new_dir, .hc = new_hc, .op = .open_view, .navigation = intent, .navigation_generation = tab.navigation_generation };
        self.pending.append(self.allocator, p) catch { self.allocator.destroy(p); new_dir.deinit(); return; };
        if (new_hc.state == .ready) {
            self.sendListingOp(p);
        } else if (new_hc.state == .dead) {
            self.setStatus("destination host is unavailable");
            self.dropPending(self.pending.items.len - 1);
        }
    }

    fn navigateSpec(self: *BrowserView, tab: *BTab, spec: []const u8) void {
        self.navigateSpecMode(tab, spec, .push);
    }

    fn navigateSpecMode(self: *BrowserView, tab: *BTab, spec: []const u8, intent: NavigationIntent) void {
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
        self.navigateMode(tab, host, path, intent);
    }

    fn goBack(self: *BrowserView, tab: *BTab) void {
        if (tab.back.items.len == 0) return;
        self.navigateSpecMode(tab, tab.back.items[tab.back.items.len - 1], .back);
    }

    fn goForward(self: *BrowserView, tab: *BTab) void {
        if (tab.fwd.items.len == 0) return;
        self.navigateSpecMode(tab, tab.fwd.items[tab.fwd.items.len - 1], .forward);
    }

    fn commitNavigation(self: *BrowserView, tab: *BTab, hc: *HostConn, candidate: *Dir, intent: NavigationIntent, canonical: []const u8) void {
        if (canonical.len > 0 and !std.mem.eql(u8, candidate.path, canonical)) {
            const owned = self.allocator.dupe(u8, canonical) catch null;
            if (owned) |path| { self.allocator.free(candidate.path); candidate.path = path; }
        }
        var current_buf: [4300]u8 = undefined;
        const current = self.allocator.dupe(u8, tab.spec(&current_buf)) catch null;
        switch (intent) {
            .push => {
                if (current) |value| tab.back.append(self.allocator, value) catch self.allocator.free(value);
                for (tab.fwd.items) |value| self.allocator.free(value);
                tab.fwd.clearRetainingCapacity();
            },
            .back => {
                if (tab.back.pop()) |value| self.allocator.free(value);
                if (current) |value| tab.fwd.append(self.allocator, value) catch self.allocator.free(value);
            },
            .forward => {
                if (tab.fwd.pop()) |value| self.allocator.free(value);
                if (current) |value| tab.back.append(self.allocator, value) catch self.allocator.free(value);
            },
        }
        while (tab.back.items.len > 100) self.allocator.free(tab.back.orderedRemove(0));
        while (tab.fwd.items.len > 100) self.allocator.free(tab.fwd.orderedRemove(0));
        for (tab.selected.items) |value| self.allocator.free(value);
        tab.selected.clearRetainingCapacity();
        self.ta_len = 0;
        tab.dropSubdirsUnder(tab.root.path);
        self.cancelPendingDir(tab.root);
        self.closeViewOf(tab.hc, tab.root);
        tab.root.deinit();
        tab.root = candidate;
        tab.hc = hc;
        self.updateTabLabel(tab);
        self.syncPathEntry(tab);
        self.renderTab(tab);
        self.refreshGitOverlay(tab);
        var recent_buf: [4300]u8 = undefined;
        self.recordRecentSpec(tab.spec(&recent_buf));
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
        self.navigate(tab, host, copy);
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
        self.syncing_path_entry = true;
        c.gtk_editable_set_text(@ptrCast(self.path_entry), &z);
        self.syncing_path_entry = false;
        // The entry no longer holds what the user was completing.
        self.cancelPathCompletion();
        c.gtk_widget_set_sensitive(self.back_button, @intFromBool(tab.back.items.len > 0));
        c.gtk_widget_set_sensitive(self.fwd_button, @intFromBool(tab.fwd.items.len > 0));
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
        tab.applySort();
        self.updateSortHeader(tab);
        self.applyViewChrome(tab);
        switch (tab.view_mode) {
            .details, .compact => self.renderList(tab),
            .icons => self.renderGrid(tab),
            .miller => {
                self.renderMillerCols(tab);
                self.renderList(tab);
            },
        }
        var count_buf: [96]u8 = undefined;
        const cmsg = std.fmt.bufPrint(&count_buf, "{d} items", .{tab.root.entries.items.len}) catch "";
        self.setStatus(cmsg);
    }

    /// Show/hide the chrome that belongs to the tab's view mode.
    fn applyViewChrome(self: *BrowserView, tab: *BTab) void {
        _ = self;
        const mode = tab.view_mode;
        c.gtk_widget_set_visible(tab.header_box, @intFromBool(mode == .details or mode == .compact));
        c.gtk_widget_set_visible(tab.miller_box, @intFromBool(mode == .miller));
        c.gtk_widget_set_visible(tab.scroller, @intFromBool(mode != .icons));
        if (tab.flow_scroller) |fs| c.gtk_widget_set_visible(fs, @intFromBool(mode == .icons));
        if (mode != .miller and tab.ancestors.items.len > 0) tab.dropAncestors();
    }

    /// Heap context for one header button (a column or the picker).
    const HeaderCtx = struct {
        allocator: std.mem.Allocator,
        tab: *BTab,
        column: ?browser_model.Column,

        fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
            ctx.allocator.destroy(ctx);
        }
    };

    fn headerButton(self: *BrowserView, tab: *BTab, label: [*:0]const u8, column: ?browser_model.Column, width: i32, expand: bool) void {
        const btn = c.gtk_button_new_with_label(label);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        if (expand) {
            c.gtk_widget_set_hexpand(btn, 1);
            c.gtk_widget_set_halign(c.gtk_button_get_child(@ptrCast(btn)), c.GTK_ALIGN_START);
        } else {
            c.gtk_widget_set_size_request(btn, width, -1);
        }
        const ctx = self.allocator.create(HeaderCtx) catch return;
        ctx.* = .{ .allocator = self.allocator, .tab = tab, .column = column };
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onHeaderClicked), @ptrCast(ctx), @ptrCast(&HeaderCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(tab.header_box), btn);
    }

    /// Width of an attribute column; values are free-form text, so
    /// they get one generous ellipsized column each.
    const ATTR_COLUMN_WIDTH = 160;
    /// Cap on attribute columns: each one costs an lgetxattr per entry
    /// per listing, and the daemon refuses more than this anyway.
    const MAX_ATTR_COLUMNS = 8;

    fn attrHeaderButton(self: *BrowserView, tab: *BTab, label: [*:0]const u8, index: usize) void {
        const btn = c.gtk_button_new_with_label(label);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_set_size_request(btn, ATTR_COLUMN_WIDTH, -1);
        const ctx = self.allocator.create(AttrColumnCtx) catch return;
        ctx.* = .{ .allocator = self.allocator, .tab = tab, .index = index, .entry = null };
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onAttrHeaderClicked), @ptrCast(ctx), @ptrCast(&AttrColumnCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(tab.header_box), btn);
    }

    /// Heap context for an attribute-column header, remove button, or
    /// the add-column entry.
    const AttrColumnCtx = struct {
        allocator: std.mem.Allocator,
        tab: *BTab,
        index: usize,
        entry: ?*c.GtkWidget,

        fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const ctx: *AttrColumnCtx = @ptrCast(@alignCast(user.?));
            ctx.allocator.destroy(ctx);
        }
    };

    fn onAttrHeaderClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *AttrColumnCtx = @ptrCast(@alignCast(user.?));
        const tab = ctx.tab;
        if (ctx.index >= tab.attr_columns.items.len) return;
        if (tab.attr_sort != null and tab.attr_sort.? == ctx.index) {
            tab.descending = !tab.descending;
        } else {
            tab.attr_sort = ctx.index;
            tab.descending = false;
        }
        // Attribute order is its own key; the fixed-column key stops
        // claiming the header marker.
        tab.sort_key = .name;
        tab.view.updateSortHeader(tab);
        tab.view.renderTab(tab);
    }

    fn onAttrColumnRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *AttrColumnCtx = @ptrCast(@alignCast(user.?));
        const tab = ctx.tab;
        if (ctx.index >= tab.attr_columns.items.len) return;
        const self = tab.view;
        self.allocator.free(tab.attr_columns.orderedRemove(ctx.index));
        tab.attr_sort = null;
        self.closeColumnPicker();
        self.reopenTabListing(tab);
    }

    fn onAttrColumnAdd(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const ctx: *AttrColumnCtx = @ptrCast(@alignCast(user.?));
        const tab = ctx.tab;
        const self = tab.view;
        const raw = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) return;
        if (!std.mem.startsWith(u8, name, "user."))
            return self.setStatus("attribute names must start with user.");
        if (tab.attr_columns.items.len >= MAX_ATTR_COLUMNS)
            return self.setStatusFmt("at most {d} attribute columns", .{MAX_ATTR_COLUMNS});
        for (tab.attr_columns.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return self.setStatus("that column is already shown");
        }
        const owned = self.allocator.dupe(u8, name) catch return;
        tab.attr_columns.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return;
        };
        self.closeColumnPicker();
        self.reopenTabListing(tab);
    }

    fn closeColumnPicker(self: *BrowserView) void {
        const pop = self.column_picker orelse return;
        self.column_picker = null;
        c.gtk_popover_popdown(@ptrCast(pop));
    }

    /// Re-SUBSCRIBE the tab's directories so both the listing and the
    /// pushed deltas carry the new attribute set. A plain re-list
    /// would leave the daemon-side view on the old attributes, and the
    /// next delta would blank the new column.
    fn reopenTabListing(self: *BrowserView, tab: *BTab) void {
        self.cancelPendingDir(tab.root);
        self.closeViewOf(tab.hc, tab.root);
        self.openDir(tab, tab.root);
        for (tab.subdirs.items) |d| {
            self.cancelPendingDir(d);
            self.closeViewOf(tab.hc, d);
            self.openDir(tab, d);
        }
        self.updateSortHeader(tab);
    }

    fn onHeaderClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
        sortClicked(ctx.tab, if (ctx.column) |col| col.sortKey() else .name);
    }

    /// Rebuild the sort header for the tab's current column set. Also
    /// the single place that renders sort direction.
    fn updateSortHeader(self: *BrowserView, tab: *BTab) void {
        while (c.gtk_widget_get_first_child(tab.header_box)) |child|
            c.gtk_box_remove(@ptrCast(tab.header_box), child);
        const mark = if (tab.descending) " v" else " ^";
        var buf: [32:0]u8 = undefined;
        const nm = std.fmt.bufPrintZ(&buf, "Name{s}", .{if (tab.sort_key == .name) mark else ""}) catch "Name";
        self.headerButton(tab, nm.ptr, null, 0, true);
        if (tab.view_mode == .details) {
            for (std.enums.values(browser_model.Column)) |col| {
                if (!tab.columns.contains(col)) continue;
                var cb: [32:0]u8 = undefined;
                const marked = tab.sort_key == col.sortKey() and col != .target;
                const txt: [*:0]const u8 = if (std.fmt.bufPrintZ(&cb, "{s}{s}", .{ col.title(), if (marked) mark else "" })) |v| v.ptr else |_| col.title();
                self.headerButton(tab, txt, col, col.width(), false);
            }
            for (tab.attr_columns.items, 0..) |name, i| {
                var cb: [64:0]u8 = undefined;
                const marked = tab.attr_sort != null and tab.attr_sort.? == i;
                const txt: [*:0]const u8 = if (std.fmt.bufPrintZ(&cb, "{s}{s}", .{
                    attrLabel(name), if (marked) mark else "",
                })) |v| v.ptr else |_| "attr";
                self.attrHeaderButton(tab, txt, i);
            }
            const picker = c.gtk_button_new_from_icon_name("view-more-symbolic");
            c.gtk_button_set_has_frame(@ptrCast(picker), 0);
            c.gtk_widget_set_tooltip_text(picker, "Choose columns");
            const ctx = self.allocator.create(HeaderCtx) catch return;
            ctx.* = .{ .allocator = self.allocator, .tab = tab, .column = null };
            _ = c.g_signal_connect_data(picker, "clicked", @ptrCast(&onColumnPicker), @ptrCast(ctx), @ptrCast(&HeaderCtx.free), c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(tab.header_box), picker);
        }
    }

    fn onColumnPicker(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.tab.view;
        const popover = c.gtk_popover_new();
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
        c.gtk_widget_set_margin_start(box, 10);
        c.gtk_widget_set_margin_end(box, 10);
        c.gtk_widget_set_margin_top(box, 10);
        c.gtk_widget_set_margin_bottom(box, 10);
        for (std.enums.values(browser_model.Column)) |col| {
            const check = c.gtk_check_button_new_with_label(col.title());
            c.gtk_check_button_set_active(@ptrCast(check), @intFromBool(ctx.tab.columns.contains(col)));
            const cctx = self.allocator.create(HeaderCtx) catch continue;
            cctx.* = .{ .allocator = self.allocator, .tab = ctx.tab, .column = col };
            _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onColumnToggled), @ptrCast(cctx), @ptrCast(&HeaderCtx.free), c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(box), check);
        }
        c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));
        const attr_head = c.gtk_label_new("Attribute columns");
        c.gtk_label_set_xalign(@ptrCast(attr_head), 0);
        c.gtk_widget_add_css_class(attr_head, "dim-label");
        c.gtk_box_append(@ptrCast(box), attr_head);
        for (ctx.tab.attr_columns.items, 0..) |name, i| {
            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
            var nz: [256:0]u8 = undefined;
            const lbl = c.gtk_label_new(copyZ(@ptrCast(&nz), name));
            c.gtk_label_set_xalign(@ptrCast(lbl), 0);
            c.gtk_widget_set_hexpand(lbl, 1);
            c.gtk_box_append(@ptrCast(row), lbl);
            const remove = c.gtk_button_new_from_icon_name("list-remove-symbolic");
            const rctx = self.allocator.create(AttrColumnCtx) catch continue;
            rctx.* = .{ .allocator = self.allocator, .tab = ctx.tab, .index = i, .entry = null };
            _ = c.g_signal_connect_data(remove, "clicked", @ptrCast(&onAttrColumnRemove), @ptrCast(rctx), @ptrCast(&AttrColumnCtx.free), c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(row), remove);
            c.gtk_box_append(@ptrCast(box), row);
        }
        const add = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(add), "user.name — Enter to add");
        const actx = self.allocator.create(AttrColumnCtx) catch return;
        actx.* = .{ .allocator = self.allocator, .tab = ctx.tab, .index = 0, .entry = add };
        _ = c.g_signal_connect_data(add, "activate", @ptrCast(&onAttrColumnAdd), @ptrCast(actx), @ptrCast(&AttrColumnCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), add);

        c.gtk_popover_set_child(@ptrCast(popover), box);
        // Parent to the PAGE, not the button: every toggle rebuilds
        // the header, which would destroy a button-parented popover
        // and close the picker after a single click.
        var bounds: c.graphene_rect_t = undefined;
        if (c.gtk_widget_compute_bounds(@ptrCast(btn), ctx.tab.page, &bounds) != 0) {
            const rect = c.GdkRectangle{
                .x = @intFromFloat(bounds.origin.x),
                .y = @intFromFloat(bounds.origin.y),
                .width = @intFromFloat(bounds.size.width),
                .height = @intFromFloat(bounds.size.height),
            };
            c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        }
        c.gtk_widget_set_parent(popover, ctx.tab.page);
        connectPopoverAutoUnparent(popover);
        self.column_picker = popover;
        c.gtk_popover_popup(@ptrCast(popover));
    }

    fn onColumnToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *HeaderCtx = @ptrCast(@alignCast(user.?));
        const col = ctx.column orelse return;
        const on = c.gtk_check_button_get_active(check) != 0;
        if (on) ctx.tab.columns.insert(col) else ctx.tab.columns.remove(col);
        const self = ctx.tab.view;
        // A hidden column must not keep sorting the view.
        if (!on and ctx.tab.sort_key == col.sortKey() and col != .target) {
            ctx.tab.sort_key = .name;
            ctx.tab.applySort();
        }
        self.updateSortHeader(ctx.tab);
        self.renderTab(ctx.tab);
    }

    fn renderList(self: *BrowserView, tab: *BTab) void {
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
    }

    // ── icon-grid view ──────────────────────────────────────────

    fn ensureFlowbox(self: *BrowserView, tab: *BTab) *c.GtkFlowBox {
        if (tab.flowbox) |fb| return fb;
        const fs = c.gtk_scrolled_window_new();
        c.gtk_widget_set_hexpand(fs, 1);
        c.gtk_widget_set_vexpand(fs, 1);
        const fb = c.gtk_flow_box_new();
        c.gtk_flow_box_set_selection_mode(@ptrCast(fb), c.GTK_SELECTION_MULTIPLE);
        c.gtk_flow_box_set_activate_on_single_click(@ptrCast(fb), 0);
        c.gtk_flow_box_set_homogeneous(@ptrCast(fb), 1);
        c.gtk_flow_box_set_max_children_per_line(@ptrCast(fb), 32);
        c.gtk_scrolled_window_set_child(@ptrCast(fs), fb);
        // content box = miller_box | scroller | flow_scroller
        const content = c.gtk_widget_get_parent(tab.scroller);
        c.gtk_box_append(@ptrCast(content), fs);
        _ = c.g_signal_connect_data(fb, "child-activated", @ptrCast(&onGridChildActivated), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(fb, "selected-children-changed", @ptrCast(&onGridSelectionChanged), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
        const rclick = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(rclick), 3);
        _ = c.g_signal_connect_data(rclick, "pressed", @ptrCast(&onGridRightClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(@ptrCast(fb), @ptrCast(rclick));
        tab.flow_scroller = fs;
        tab.flowbox = @ptrCast(@alignCast(fb));
        _ = self;
        return tab.flowbox.?;
    }

    fn renderGrid(self: *BrowserView, tab: *BTab) void {
        const fb = self.ensureFlowbox(tab);
        c.gtk_widget_set_visible(tab.flow_scroller.?, 1);
        tab.rendering = true;
        defer tab.rendering = false;
        while (c.gtk_flow_box_get_child_at_index(fb, 0)) |child| {
            c.gtk_flow_box_remove(fb, @ptrCast(child));
        }
        for (tab.root.entries.items) |e| {
            if (!tab.show_hidden and e.name.len > 0 and e.name[0] == '.') continue;
            self.appendTile(tab, fb, e);
        }
        // Restore selection.
        var i: c_int = 0;
        while (c.gtk_flow_box_get_child_at_index(fb, i)) |child| : (i += 1) {
            const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse continue;
            const ctx: *RowCtx = @ptrCast(@alignCast(data));
            for (tab.selected.items) |path| {
                if (std.mem.eql(u8, path, ctx.path)) {
                    c.gtk_flow_box_select_child(fb, child);
                    break;
                }
            }
        }
    }

    fn appendTile(self: *BrowserView, tab: *BTab, fb: *c.GtkFlowBox, e: Entry) void {
        var full_buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{
            if (tab.root.path.len == 1) "" else tab.root.path, e.name,
        }) catch return;

        const tile = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        c.gtk_widget_set_size_request(tile, 96, -1);
        var icon: ?*c.GtkWidget = null;
        if (self.thumbLookup(tab.hc, full, e)) |tex| {
            const img = c.gtk_image_new_from_paintable(@ptrCast(tex));
            c.gtk_image_set_pixel_size(@ptrCast(img), 48);
            icon = img;
        }
        if (icon == null) {
            const icon_name: [*:0]const u8 = if (std.mem.eql(u8, e.kind, "dir"))
                "folder-symbolic"
            else if (std.mem.eql(u8, e.kind, "link"))
                "emblem-symbolic-link"
            else
                "text-x-generic-symbolic";
            const img = c.gtk_image_new_from_icon_name(icon_name);
            c.gtk_image_set_pixel_size(@ptrCast(img), 48);
            icon = img;
        }
        c.gtk_box_append(@ptrCast(tile), icon);

        var name_z: [256:0]u8 = undefined;
        const nn = @min(e.name.len, name_z.len - 1);
        @memcpy(name_z[0..nn], e.name[0..nn]);
        name_z[nn] = 0;
        const lab = c.gtk_label_new(&name_z);
        c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(@ptrCast(lab), 12);
        c.gtk_box_append(@ptrCast(tile), lab);

        const child = c.gtk_flow_box_child_new();
        c.gtk_flow_box_child_set_child(@ptrCast(child), tile);
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
        c.g_object_set_data_full(@ptrCast(child), "sketerm-row", @ptrCast(ctx), @ptrCast(&freeRowCtx));
        c.gtk_flow_box_append(fb, child);
    }

    fn onGridChildActivated(_: *c.GtkFlowBox, child: *c.GtkFlowBoxChild, user: ?*anyopaque) callconv(.c) void {
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse return;
        const ctx: *RowCtx = @ptrCast(@alignCast(data));
        activateEntry(tab, ctx);
    }

    fn onGridSelectionChanged(fb: *c.GtkFlowBox, user: ?*anyopaque) callconv(.c) void {
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        if (tab.rendering) return;
        const a = tab.view.allocator;
        for (tab.selected.items) |p| a.free(p);
        tab.selected.clearRetainingCapacity();
        var children = c.gtk_flow_box_get_selected_children(fb);
        const head = children;
        while (children != null) : (children = children.*.next) {
            const child: *c.GtkWidget = @ptrCast(@alignCast(children.*.data orelse continue));
            const data = c.g_object_get_data(@ptrCast(child), "sketerm-row") orelse continue;
            const ctx: *RowCtx = @ptrCast(@alignCast(data));
            const owned = a.dupe(u8, ctx.path) catch continue;
            tab.selected.append(a, owned) catch a.free(owned);
        }
        if (head != null) c.g_list_free(head);
        tab.view.updatePreview();
    }

    fn onGridRightClick(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        _ = gesture;
        _ = n_press;
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        const self = tab.view;
        const fb = tab.flowbox orelse return;
        var path: ?[]u8 = null;
        var name: ?[]u8 = null;
        var is_dir = false;
        if (c.gtk_flow_box_get_child_at_pos(fb, @intFromFloat(x), @intFromFloat(y))) |child| {
            if (c.g_object_get_data(@ptrCast(child), "sketerm-row")) |data| {
                const rctx: *RowCtx = @ptrCast(@alignCast(data));
                path = self.allocator.dupe(u8, rctx.path) catch null;
                name = self.allocator.dupe(u8, std.fs.path.basename(rctx.path)) catch null;
                is_dir = rctx.is_dir;
                c.gtk_flow_box_select_child(fb, child);
            }
        }
        self.showEntryMenu(tab, @as(*c.GtkWidget, @ptrCast(@alignCast(fb))), x, y, path, name, is_dir);
    }

    // ── miller columns ──────────────────────────────────────────

    /// Rebuild the ancestor-column strip: one subscribed Dir per
    /// ancestor of the current root, "/" first.
    fn renderMillerCols(self: *BrowserView, tab: *BTab) void {
        // Desired chain: every ancestor of root (excluding root).
        var chain_buf: [64][]const u8 = undefined;
        var chain_n: usize = 0;
        {
            var p: []const u8 = tab.root.path;
            while (chain_n < chain_buf.len) {
                const parent = std.fs.path.dirname(p) orelse break;
                chain_buf[chain_n] = parent;
                chain_n += 1;
                if (parent.len <= 1) break;
                p = parent;
            }
        }
        // chain_buf is child-to-root; reverse into root-first order.
        var want: [64][]const u8 = undefined;
        for (0..chain_n) |i| want[i] = chain_buf[chain_n - 1 - i];

        // Resubscribe when the chain changed.
        var same = tab.ancestors.items.len == chain_n;
        if (same) {
            for (tab.ancestors.items, 0..) |d, i| {
                if (!std.mem.eql(u8, d.path, want[i])) same = false;
            }
        }
        if (!same) {
            tab.dropAncestors();
            for (want[0..chain_n]) |ap| {
                const d = self.makeDir(ap) orelse continue;
                tab.ancestors.append(self.allocator, d) catch {
                    d.deinit();
                    continue;
                };
                self.queueListing(tab, d, .open_view);
            }
        }

        // Rebuild the column widgets.
        while (c.gtk_widget_get_first_child(tab.miller_box)) |child| {
            c.gtk_box_remove(@ptrCast(tab.miller_box), child);
        }
        for (tab.ancestors.items) |d| {
            const col_scroll = c.gtk_scrolled_window_new();
            c.gtk_widget_set_size_request(col_scroll, 190, -1);
            c.gtk_widget_set_vexpand(col_scroll, 1);
            const col = c.gtk_list_box_new();
            c.gtk_list_box_set_selection_mode(@ptrCast(col), c.GTK_SELECTION_SINGLE);
            c.gtk_list_box_set_activate_on_single_click(@ptrCast(col), 1);
            _ = c.g_signal_connect_data(col, "row-activated", @ptrCast(&onMillerRowActivated), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
            c.gtk_scrolled_window_set_child(@ptrCast(col_scroll), col);
            // The child on the path to root gets selected.
            const next_seg = millerNextSegment(d.path, tab.root.path);
            for (d.entries.items) |e| {
                if (!tab.show_hidden and e.name.len > 0 and e.name[0] == '.') continue;
                if (!e.tdir) continue; // ancestor columns list directories only
                const row_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
                c.gtk_widget_set_margin_start(row_box, 6);
                const icon = c.gtk_image_new_from_icon_name("folder-symbolic");
                c.gtk_box_append(@ptrCast(row_box), icon);
                var nz: [256:0]u8 = undefined;
                const nn = @min(e.name.len, nz.len - 1);
                @memcpy(nz[0..nn], e.name[0..nn]);
                nz[nn] = 0;
                const lab = c.gtk_label_new(&nz);
                c.gtk_label_set_xalign(@ptrCast(lab), 0);
                c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_MIDDLE);
                c.gtk_box_append(@ptrCast(row_box), lab);
                const row = c.gtk_list_box_row_new();
                c.gtk_list_box_row_set_child(@ptrCast(row), row_box);
                var full_buf: [4096]u8 = undefined;
                const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{
                    if (d.path.len == 1) "" else d.path, e.name,
                }) catch continue;
                const ctx = self.allocator.create(RowCtx) catch continue;
                ctx.* = .{
                    .allocator = self.allocator,
                    .tab = tab,
                    .path = self.allocator.dupe(u8, full) catch {
                        self.allocator.destroy(ctx);
                        continue;
                    },
                    .is_dir = true,
                };
                c.g_object_set_data_full(@ptrCast(row), "sketerm-row", @ptrCast(ctx), @ptrCast(&freeRowCtx));
                c.gtk_list_box_append(@ptrCast(col), row);
                if (next_seg != null and std.mem.eql(u8, e.name, next_seg.?))
                    c.gtk_list_box_select_row(@ptrCast(col), @ptrCast(row));
            }
            c.gtk_box_append(@ptrCast(tab.miller_box), col_scroll);
            const sep = c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL);
            c.gtk_box_append(@ptrCast(tab.miller_box), sep);
        }
    }

    fn onMillerRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse return;
        const ctx: *RowCtx = @ptrCast(@alignCast(data));
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
        tab.view.navigate(tab, host, path);
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

        // Image files get a real freedesktop thumbnail (async: rows
        // show the generic icon until the texture lands); works for
        // local AND remote entries.
        var icon: ?*c.GtkWidget = null;
        if (self.thumbLookup(tab.hc, full, e)) |tex| {
            const img = c.gtk_image_new_from_paintable(@ptrCast(tex));
            c.gtk_image_set_pixel_size(@ptrCast(img), 24);
            icon = img;
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

        if (self.emblemFor(tab, e)) |emblem| {
            var iz: [128:0]u8 = undefined;
            const badge = c.gtk_image_new_from_icon_name(copyZ(@ptrCast(&iz), emblem));
            c.gtk_image_set_pixel_size(@ptrCast(badge), 12);
            c.gtk_widget_set_valign(badge, c.GTK_ALIGN_END);
            c.gtk_box_append(@ptrCast(row_box), badge);
        }

        var name_buf: [512:0]u8 = undefined;
        const nn = @min(e.name.len, name_buf.len - 1);
        @memcpy(name_buf[0..nn], e.name[0..nn]);
        name_buf[nn] = 0;
        const name_label = c.gtk_label_new(&name_buf);
        if (self.fileColorFor(e.name)) |color| {
            const esc = c.g_markup_escape_text(&name_buf, -1);
            var mk: [640:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&mk, "<span foreground=\"{s}\">{s}</span>", .{
                color, std.mem.span(@as([*:0]const u8, @ptrCast(esc))),
            })) |m| {
                c.gtk_label_set_markup(@ptrCast(name_label), m.ptr);
            } else |_| {}
            c.g_free(esc);
        }
        c.gtk_label_set_xalign(@ptrCast(name_label), 0);
        c.gtk_widget_set_hexpand(name_label, 1);
        c.gtk_label_set_ellipsize(@ptrCast(name_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_box_append(@ptrCast(row_box), name_label);

        // Git status badge (local current dir only).
        if (tab.hc.host == null and dir == tab.root) {
            if (self.git_map.get(e.name)) |st| {
                var gz: [8:0]u8 = undefined;
                const gtxt = std.fmt.bufPrintZ(&gz, "[{c}]", .{st}) catch "";
                const gl = c.gtk_label_new(gtxt.ptr);
                c.gtk_widget_add_css_class(gl, if (st == '?') "dim-label" else "warning");
                c.gtk_box_append(@ptrCast(row_box), gl);
            }
        }

        if (e.tags.len > 0) {
            var tag_z: [128:0]u8 = undefined;
            const ttxt = std.fmt.bufPrintZ(&tag_z, "[{s}]", .{e.tags}) catch "";
            const tag_label = c.gtk_label_new(ttxt.ptr);
            // Deterministic per-tagset color chip (markup only when
            // the text is markup-safe).
            if (std.mem.indexOfAny(u8, e.tags, "<>&\"") == null) {
                var mk: [192:0]u8 = undefined;
                if (std.fmt.bufPrintZ(&mk, "<span foreground=\"{s}\">[{s}]</span>", .{
                    tagColorHex(e.tags), e.tags,
                })) |m| {
                    c.gtk_label_set_markup(@ptrCast(tag_label), m.ptr);
                } else |_| {}
            } else {
                c.gtk_widget_add_css_class(tag_label, "dim-label");
            }
            c.gtk_box_append(@ptrCast(row_box), tag_label);
        }

        // Compact view is name (+tags) only; details renders the
        // tab's chosen columns, in Column declaration order.
        if (tab.view_mode == .details) {
            for (std.enums.values(browser_model.Column)) |col| {
                if (!tab.columns.contains(col)) continue;
                self.appendColumnCell(row_box, e, col);
            }
            for (tab.attr_columns.items, 0..) |_, i| {
                var vz: [256:0]u8 = undefined;
                const label = c.gtk_label_new(copyZ(@ptrCast(&vz), if (i < e.attrs.len) e.attrs[i] else ""));
                c.gtk_widget_add_css_class(label, "dim-label");
                c.gtk_label_set_xalign(@ptrCast(label), 0);
                c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
                c.gtk_widget_set_size_request(label, ATTR_COLUMN_WIDTH, -1);
                c.gtk_box_append(@ptrCast(row_box), label);
            }
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

        // Drag source: host-qualified spec as text. A terminal drop
        // types it (plain path for local files); a drop on another
        // browser tab moves/copies (internal DnD).
        {
            var pz: [4500:0]u8 = undefined;
            const spec_res = if (tab.hc.host) |h|
                std.fmt.bufPrintZ(&pz, "{s}:{s}", .{ h, full })
            else
                std.fmt.bufPrintZ(&pz, "{s}", .{full});
            if (spec_res) |pzs| {
                const provider = c.gdk_content_provider_new_typed(c.G_TYPE_STRING, pzs.ptr);
                const dsrc = c.gtk_drag_source_new();
                c.gtk_drag_source_set_content(dsrc, provider);
                c.g_object_unref(provider);
                c.gtk_widget_add_controller(row, @ptrCast(dsrc));
            } else |_| {}
        }

        c.gtk_list_box_append(tab.listbox, row);
    }

    /// Resolve an entry's badge icon from the emblem rules. Attribute
    /// values come from the listing itself: the rules' attributes were
    /// requested with it, so this costs no round trip.
    fn emblemFor(self: *BrowserView, tab: *BTab, e: Entry) ?[]const u8 {
        if (self.emblems.list.len == 0) return null;
        var spec_buf: [1024]u8 = undefined;
        const spec = self.attrSpec(tab, &spec_buf);
        const Lookup = struct {
            spec: []const u8,
            entry: Entry,
            fn get(self2: @This(), name: []const u8) ?[]const u8 {
                var i: usize = 0;
                var it = std.mem.splitScalar(u8, self2.spec, ',');
                while (it.next()) |requested| : (i += 1) {
                    if (!std.mem.eql(u8, requested, name)) continue;
                    return if (i < self2.entry.attrs.len) self2.entry.attrs[i] else null;
                }
                return null;
            }
        };
        return self.emblems.iconFor(e.name, Lookup{ .spec = spec, .entry = e }, Lookup.get);
    }

    /// One details-view column cell. Widths match the header buttons
    /// so the columns line up without a size group.
    fn appendColumnCell(self: *BrowserView, row_box: *c.GtkWidget, e: Entry, col: browser_model.Column) void {
        _ = self;
        var buf: [256:0]u8 = undefined;
        var mode_buf: [16:0]u8 = undefined;
        var size_buf: [48:0]u8 = undefined;
        var time_buf: [40:0]u8 = undefined;
        const text: [*:0]const u8 = switch (col) {
            .kind => copyZ(&buf, e.kind),
            .permissions => fmtModeZ(&mode_buf, e.mode, e.tdir),
            .owner => if (std.fmt.bufPrintZ(&buf, "{d}", .{e.uid})) |v| v.ptr else |_| "",
            .group => if (std.fmt.bufPrintZ(&buf, "{d}", .{e.gid})) |v| v.ptr else |_| "",
            .size => if (std.mem.eql(u8, e.kind, "dir")) "" else @as([*:0]const u8, fmtSize(&size_buf, e.size).ptr),
            .mtime => if (e.mtime_ms == 0) "" else fmtTimeZ(&time_buf, e.mtime_ms),
            .ctime => if (e.ctime_ms == 0) "" else fmtTimeZ(&time_buf, e.ctime_ms),
            .target => copyZ(&buf, e.target orelse ""),
        };
        const label = c.gtk_label_new(text);
        c.gtk_widget_add_css_class(label, "dim-label");
        if (col == .permissions) c.gtk_widget_add_css_class(label, "monospace");
        c.gtk_label_set_xalign(@ptrCast(label), if (col == .size) 1.0 else 0.0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_widget_set_size_request(label, col.width(), -1);
        c.gtk_box_append(@ptrCast(row_box), label);
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
        activateEntry(tab, ctx);
    }

    fn activateEntry(tab: *BTab, ctx: *RowCtx) void {
        const self = tab.view;
        if (tab.root.archive.len > 0) {
            if (!ctx.is_dir) {
                var mbuf: [4096]u8 = undefined;
                if (ctx.path.len >= mbuf.len) return;
                @memcpy(mbuf[0..ctx.path.len], ctx.path);
                self.extractAndOpenMember(tab, mbuf[0..ctx.path.len]);
            }
            return;
        }
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
            self.navigate(tab, host, path);
        } else if (tab.hc.host == null) {
            // Local file: default application, straight from disk.
            launchLocal(ctx.path);
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
        mode: enum { none, rename, mkdir, tags } = .none,
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
        self.showEntryMenu(tab, @ptrCast(@alignCast(tab.listbox)), x, y, path, name, is_dir);
    }

    /// Build and pop the entry context menu. Takes ownership of
    /// `path`/`name`; `parent` is the visible widget the click hit.
    fn showEntryMenu(
        self: *BrowserView,
        tab: *BTab,
        parent: *c.GtkWidget,
        x: f64,
        y: f64,
        path: ?[]u8,
        name: ?[]u8,
        is_dir: bool,
    ) void {
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
        if (tab.root.archive.len > 0) {
            // Archive members: extract-and-open is the only verb
            // (path ops would misparse member names).
            if (ctx.path != null and !is_dir)
                menuButton(box, "Extract and Open", &onMenuExtractMember, ctx, false);
        } else if (tab.root.collection) {
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
                menuButton(box, "Calculate Size", &onMenuCalcSize, ctx, false);
                menuButton(box, "Find Duplicates Here", &onMenuFindDups, ctx, false);
                menuButton(box, "Add Bookmark", &onMenuBookmark, ctx, false);
            } else if (!is_local and self.on_host_open != null) {
                menuButton(box, "Open on Host (app forward)", &onMenuHostOpen, ctx, false);
            }
            if (!is_dir)
                menuButton(box, "Open With…", &onMenuOpenWith, ctx, false);
            if (isTrashPath(ctx.path.?))
                menuButton(box, "Restore from Trash", &onMenuTrashRestoreItem, ctx, false);
            if (is_local and !is_dir and isSketermMount(ctx.path.?)) {
                menuButton(box, "Pin (keep hydrated)", &onMenuPin, ctx, false);
                menuButton(box, "Evict Cached Data", &onMenuEvict, ctx, false);
            }
            menuButton(box, "Copy", &onMenuCopy, ctx, false);
            menuButton(box, "Cut", &onMenuCut, ctx, false);
            if (self.peerView()) |peer| {
                if (peer.currentTab()) |pt| {
                    var pbuf: [4300]u8 = undefined;
                    var lbuf: [4400:0]u8 = undefined;
                    const dest = pt.spec(&pbuf);
                    if (std.fmt.bufPrintZ(&lbuf, "Copy to Other Pane ({s})  F5", .{dest})) |t| {
                        menuButton(box, t.ptr, &onMenuCopyToPeer, ctx, false);
                    } else |_| {}
                    if (std.fmt.bufPrintZ(&lbuf, "Move to Other Pane ({s})  F6", .{dest})) |t| {
                        menuButton(box, t.ptr, &onMenuMoveToPeer, ctx, false);
                    } else |_| {}
                }
            }
            menuButton(box, "Copy Path", &onMenuCopyPath, ctx, false);
            menuButton(box, "Rename…", &onMenuRename, ctx, false);
            menuButton(box, "Properties…", &onMenuProperties, ctx, false);
            menuButton(box, "Tags…", &onMenuTags, ctx, false);
            if (!is_dir and isArchivePath(ctx.path.?)) {
                menuButton(box, "Browse Archive", &onMenuBrowseArchive, ctx, false);
                menuButton(box, "Extract Here", &onMenuExtractHere, ctx, false);
            }
            menuButton(box, "Compress to .tar.gz", &onMenuArchiveCreate, ctx, false);
            menuButton(box, "Add to Collection", &onMenuCollectionAdd, ctx, false);
            menuButton(box, "Export Selection to Shell ($SK_SEL)", &onMenuExportSel, ctx, false);
            if (countSelected(tab) > 1) {
                menuButton(box, "Batch Rename Selected…", &onMenuBatchRename, ctx, false);
                menuButton(box, "Batch Rename in $EDITOR…", &onMenuEditorRename, ctx, false);
            }
            menuButton(box, "Move to Trash", &onMenuTrash, ctx, false);
            menuButton(box, "Delete Permanently…", &onMenuDelete, ctx, true);
        }
        if (self.clip_path != null) {
            menuButton(box, "Paste Here", &onMenuPaste, ctx, false);
            menuButton(box, "Sync Here (mirror copy, resumable)", &onMenuSyncHere, ctx, false);
            menuButton(box, "Compare / Sync with Copied…", &onMenuCompare, ctx, false);
        }
        menuButton(box, "New Folder…", &onMenuNewFolder, ctx, false);
        if (self.undo_stack.items.len > 0) {
            var uz: [96:0]u8 = undefined;
            const last = self.undo_stack.items[self.undo_stack.items.len - 1];
            const utxt = std.fmt.bufPrintZ(&uz, "Undo ({s})", .{last.describe()}) catch "Undo";
            menuButton(box, utxt.ptr, &onMenuUndo, ctx, false);
        }
        if (ctx.path != null) self.appendActionButtons(box, ctx);
        }

        c.gtk_popover_set_child(@ptrCast(popover), box);
        c.gtk_widget_set_parent(popover, parent);
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
        copyToClip(@ptrCast(@alignCast(user.?)), false);
    }

    fn onMenuCut(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        copyToClip(@ptrCast(@alignCast(user.?)), true);
    }

    fn onMenuCopyToPeer(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = if (ctx.path) |p| self.allocator.dupe(u8, p) catch null else null;
        defer if (path) |p| self.allocator.free(p);
        menuDone(ctx);
        self.sendToPeer(false, path);
    }

    fn onMenuMoveToPeer(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = if (ctx.path) |p| self.allocator.dupe(u8, p) catch null else null;
        defer if (path) |p| self.allocator.free(p);
        menuDone(ctx);
        self.sendToPeer(true, path);
    }

    fn copyToClip(ctx: *MenuCtx, cut: bool) void {
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        self.clip_cut = cut;
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
        const verb: []const u8 = if (cut) "cut" else "copied";
        if (self.clip_paths.items.len > 1) {
            self.setStatusFmt("{s} {d} items", .{ verb, self.clip_paths.items.len });
        } else {
            self.setStatusFmt("{s}: {s}", .{ verb, path });
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
        /// Source host and whether this is a move; carried explicitly
        /// so a dual-pane send is not tied to the clipboard.
        src_host: ?[]u8 = null,
        cut: bool = false,
        clear_clipboard: bool = false,

        fn free(user: ?*anyopaque) callconv(.c) void {
            const p: *PasteCtx = @ptrCast(@alignCast(user.?));
            for (p.sources.items) |s| p.allocator.free(s);
            p.sources.deinit(p.allocator);
            if (p.src_host) |h| p.allocator.free(h);
            p.allocator.destroy(p);
        }
    };

    const ConflictChoice = enum { overwrite, keep_both, skip };

    fn onMenuPaste(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        if (self.clip_paths.items.len == 0 and self.clip_path == null) return menuDone(ctx);
        const srcs: []const []u8 = if (self.clip_paths.items.len > 0)
            self.clip_paths.items
        else
            (&[_][]u8{self.clip_path.?})[0..];
        self.beginPaste(ctx.tab, self.clip_host, srcs, self.clip_cut, true);
        menuDone(ctx);
    }

    /// Copy/move `sources` (living on `src_host`) into `tab`'s
    /// directory, asking about name collisions first. The clipboard is
    /// only consulted by the caller, so a dual-pane send uses the same
    /// path as Paste Here.
    fn beginPaste(
        self: *BrowserView,
        tab: *BTab,
        src_host: ?[]const u8,
        srcs: []const []u8,
        cut: bool,
        clear_clipboard: bool,
    ) void {
        // Count collisions against the LIVE target listing.
        var conflicts: usize = 0;
        for (srcs) |src| {
            if (tab.root.find(std.fs.path.basename(src)) != null) conflicts += 1;
        }
        if (conflicts == 0) {
            self.pasteExecute(tab, srcs, .overwrite, src_host, cut, clear_clipboard);
            return;
        }

        // Conflict dialog: one choice applies to every conflicting
        // item; non-conflicting items copy either way.
        const popover = c.gtk_popover_new();
        const pctx = self.allocator.create(PasteCtx) catch return;
        pctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = tab,
            .popover = popover,
            .conflicts = conflicts,
            .src_host = if (src_host) |h| (self.allocator.dupe(u8, h) catch null) else null,
            .cut = cut,
            .clear_clipboard = clear_clipboard,
        };
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
        c.gtk_widget_set_parent(popover, tab.page);
        connectPopoverAutoUnparent(popover);
        c.gtk_popover_popup(@ptrCast(popover));
    }

    fn pasteChoiceButton(box: *c.GtkWidget, label: [*:0]const u8, cb: anytype, pctx: *PasteCtx, destructive: bool) void {
        const btn = c.gtk_button_new_with_label(label);
        if (destructive) c.gtk_widget_add_css_class(btn, "destructive-action");
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(cb), @ptrCast(pctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), btn);
    }

    fn onPasteOverwrite(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const p: *PasteCtx = @ptrCast(@alignCast(user.?));
        p.view.pasteExecute(p.tab, p.sources.items, .overwrite, p.src_host, p.cut, p.clear_clipboard);
        c.gtk_popover_popdown(@ptrCast(p.popover));
    }
    fn onPasteKeepBoth(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const p: *PasteCtx = @ptrCast(@alignCast(user.?));
        p.view.pasteExecute(p.tab, p.sources.items, .keep_both, p.src_host, p.cut, p.clear_clipboard);
        c.gtk_popover_popdown(@ptrCast(p.popover));
    }
    fn onPasteSkip(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const p: *PasteCtx = @ptrCast(@alignCast(user.?));
        p.view.pasteExecute(p.tab, p.sources.items, .skip, p.src_host, p.cut, p.clear_clipboard);
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

    /// Start one copy (or move, when the clipboard is CUT) per
    /// source, honoring `choice` for names that already exist in the
    /// target directory.
    fn pasteExecute(
        self: *BrowserView,
        tab: *BTab,
        sources: []const []u8,
        choice: ConflictChoice,
        src_host: ?[]const u8,
        cut: bool,
        clear_clipboard: bool,
    ) void {
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
            // Pasting onto itself is a no-op, not a copy/move.
            if (hostEq(src_host, tab.hc.host) and std.mem.eql(u8, src, dst)) {
                skipped += 1;
                continue;
            }
            if (hostEq(src_host, tab.hc.host)) {
                if (cut) {
                    // Same-host move = one rename, undoable.
                    const req = self.nextReq();
                    self.deferUndo(req, self.makeUndo(tab.hc.host, .rename_back, dst, src, ""));
                    self.sendOp(tab.hc, .{ .req = req, .op = "rename", .path = src, .to = dst });
                } else {
                    var lbl: [128]u8 = undefined;
                    const label = std.fmt.bufPrint(&lbl, "copy {s}", .{base}) catch base;
                    self.startDaemonJobUndo(tab.hc, "copy", src, dst, label, self.makeUndo(tab.hc.host, .delete_created, dst, src, ""));
                }
            } else {
                const src_hc = self.hostConnFor(src_host) orelse continue;
                self.startTransfer(src_hc, src, tab.hc, dst, .{ .delete_src_after = cut });
            }
        }
        if (skipped > 0) self.setStatusFmt("skipped {d} existing item(s)", .{skipped});
        if (cut and clear_clipboard) {
            // Cut is one-shot: the sources are moving away.
            if (self.clip_path) |s| self.allocator.free(s);
            self.clip_path = null;
            for (self.clip_paths.items) |p| self.allocator.free(p);
            self.clip_paths.clearRetainingCapacity();
            self.clip_cut = false;
        }
    }

    /// startDaemonJob variant that records an undo op on completion.
    fn startDaemonJobUndo(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8, undo: ?*UndoOp) void {
        if (hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{hc.label()});
            if (undo) |u| u.destroy(self.allocator);
            return;
        }
        const req = self.nextReq();
        const pj = self.allocator.create(PendingJob) catch {
            if (undo) |u| u.destroy(self.allocator);
            return;
        };
        pj.* = .{
            .req = req,
            .hc = hc,
            .label = self.allocator.dupe(u8, label) catch {
                self.allocator.destroy(pj);
                if (undo) |u| u.destroy(self.allocator);
                return;
            },
            .undo_op = undo,
        };
        self.pending_jobs.append(self.allocator, pj) catch {
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
            if (undo) |u| u.destroy(self.allocator);
            return;
        };
        self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .@"resume" = false });
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
        // Copy the path out and close the menu popover FIRST — its
        // popdown must not race the new popover's grab.
        var pbuf: [4096]u8 = undefined;
        if (orig.len >= pbuf.len) return menuDone(mctx);
        @memcpy(pbuf[0..orig.len], orig);
        const path = pbuf[0..orig.len];
        menuDone(mctx);
        self.openWithDialog(tab, path);
    }

    /// The application chooser: local apps for the guessed type plus,
    /// on a remote tab, the apps installed on the file's host.
    fn openWithDialog(self: *BrowserView, tab: *BTab, path: []const u8) void {
        const is_local = tab.hc.host == null;
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

        const owdef = c.gtk_check_button_new_with_label("Always use for this file type");
        c.g_object_set_data(@ptrCast(popover), "sketerm-owdef", @ptrCast(owdef));

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
        c.gtk_box_append(@ptrCast(box), owdef);

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
        c.gtk_widget_set_parent(popover, tab.page);
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
            // "Always use for this type": register the association
            // before launching.
            if (c.g_object_get_data(@ptrCast(actx.popover), "sketerm-owdef")) |cb| {
                if (c.gtk_check_button_get_active(@ptrCast(@alignCast(cb))) != 0)
                    setDefaultAppForPath(appid, actx.path);
            }
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
        c.gtk_widget_set_parent(popover, ctx.tab.page);
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
        const tab = self.ensureCollectionTab(ctx.tab.hc.host, ctx.tab.root.path) orelse return menuDone(ctx);
        // Entry: display = host-qualified spec; target = same spec.
        var spec_buf: [4400]u8 = undefined;
        const spec = if (ctx.tab.hc.host) |h|
            std.fmt.bufPrint(&spec_buf, "{s}:{s}", .{ h, path }) catch return menuDone(ctx)
        else
            path;
        if (tab.root.find(spec) != null) return menuDone(ctx); // already shelved
        self.appendCollectionEntry(tab, spec, ctx.is_dir);
        const already = for (self.collection_items.items) |ci| {
            if (std.mem.eql(u8, ci.spec, spec)) break true;
        } else false;
        if (!already) {
            const owned = self.allocator.dupe(u8, spec) catch null;
            if (owned) |o| {
                self.collection_items.append(self.allocator, .{ .spec = o, .dir = ctx.is_dir }) catch self.allocator.free(o);
                self.savePlaces();
            }
        }
        self.setStatusFmt("added to collection: {s}", .{spec});
        menuDone(ctx);
    }

    /// The collection shelf tab, created (and seeded from the
    /// persisted list) on first use.
    fn ensureCollectionTab(self: *BrowserView, host: ?[]const u8, path: []const u8) ?*BTab {
        if (self.collection_tab) |t| return t;
        const t = self.newTab(host, path) orelse return null;
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
        for (self.collection_items.items) |ci| self.appendCollectionEntry(t, ci.spec, ci.dir);
        return t;
    }

    fn appendCollectionEntry(self: *BrowserView, tab: *BTab, spec: []const u8, is_dir: bool) void {
        const a = self.allocator;
        if (tab.root.find(spec) != null) return;
        const name = a.dupe(u8, spec) catch return;
        const kind = a.dupe(u8, if (is_dir) "dir" else "file") catch {
            a.free(name);
            return;
        };
        const tgt = a.dupe(u8, spec) catch {
            a.free(name);
            a.free(kind);
            return;
        };
        tab.root.entries.append(a, .{
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
        var ci: usize = 0;
        var changed = false;
        while (ci < self.collection_items.items.len) {
            if (std.mem.eql(u8, self.collection_items.items[ci].spec, spec)) {
                self.allocator.free(self.collection_items.items[ci].spec);
                _ = self.collection_items.orderedRemove(ci);
                changed = true;
            } else ci += 1;
        }
        if (changed) self.savePlaces();
        menuDone(ctx);
    }

    fn onMenuExportSel(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const tab = ctx.tab;
        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(self.allocator);
        const paths: []const []u8 = if (tab.selected.items.len > 0)
            tab.selected.items
        else if (ctx.path) |pp|
            (&[_][]u8{pp})[0..]
        else
            return menuDone(ctx);
        cmd.appendSlice(self.allocator, "SK_SEL=") catch return menuDone(ctx);
        appendQuoted(&cmd, self.allocator, paths[0]) catch return menuDone(ctx);
        cmd.appendSlice(self.allocator, "; SK_SEL_ALL='") catch return menuDone(ctx);
        for (paths, 0..) |sp, i| {
            if (i > 0) cmd.append(self.allocator, ' ') catch return menuDone(ctx);
            for (sp) |ch| {
                if (ch == '\'') {
                    cmd.appendSlice(self.allocator, "'\\''") catch return menuDone(ctx);
                } else cmd.append(self.allocator, ch) catch return menuDone(ctx);
            }
        }
        cmd.appendSlice(self.allocator, "'\n") catch return menuDone(ctx);
        self.pane.terminal.writeRaw(cmd.items);
        self.pane.setBrowserVisible(false);
        self.setStatusFmt("exported {d} path(s) as $SK_SEL / $SK_SEL_ALL", .{paths.len});
        menuDone(ctx);
    }

    // ── $EDITOR batch rename ────────────────────────────────────

    /// Editor-buffer rename: selection names go to a temp file, the
    /// pane's SHELL runs $EDITOR on it, and a sentinel "done" file
    /// (watched with GFileMonitor) triggers applying the renames.
    const EditorRename = struct {
        view: *BrowserView,
        host: ?[]u8,
        paths: std.ArrayList([]u8) = .empty,
        tmp: []u8,
        done: []u8,
        monitor: ?*c.GFileMonitor = null,

        fn destroy(self: *EditorRename, allocator: std.mem.Allocator) void {
            if (self.monitor) |m| {
                _ = c.g_file_monitor_cancel(m);
                c.g_object_unref(m);
            }
            var zb: [4300]u8 = undefined;
            if (std.fmt.bufPrintZ(&zb, "{s}", .{self.tmp})) |z| {
                _ = c.unlink(z.ptr);
            } else |_| {}
            if (std.fmt.bufPrintZ(&zb, "{s}", .{self.done})) |z| {
                _ = c.unlink(z.ptr);
            } else |_| {}
            for (self.paths.items) |sp| allocator.free(sp);
            self.paths.deinit(allocator);
            if (self.host) |h| allocator.free(h);
            allocator.free(self.tmp);
            allocator.free(self.done);
            allocator.destroy(self);
        }
    };

    fn onMenuEditorRename(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const tab = ctx.tab;
        if (tab.selected.items.len < 2) return menuDone(ctx);
        if (self.editor_rename) |er| {
            er.destroy(self.allocator);
            self.editor_rename = null;
        }
        var stamp: [32]u8 = undefined;
        var t: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
        const tag = std.fmt.bufPrint(&stamp, "{d}", .{@as(u64, @intCast(t.tv_nsec)) ^ @as(u64, @intCast(t.tv_sec))}) catch return menuDone(ctx);
        const cache_root = c.g_get_user_cache_dir();
        var tb: [4200]u8 = undefined;
        var db: [4200]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tb, "{s}/sketerm-rename-{s}.txt", .{ cache_root, tag }) catch return menuDone(ctx);
        const done = std.fmt.bufPrint(&db, "{s}/sketerm-rename-{s}.done", .{ cache_root, tag }) catch return menuDone(ctx);

        const er = self.allocator.create(EditorRename) catch return menuDone(ctx);
        er.* = .{
            .view = self,
            .host = if (tab.hc.host) |h| (self.allocator.dupe(u8, h) catch null) else null,
            .tmp = self.allocator.dupe(u8, tmp) catch {
                self.allocator.destroy(er);
                return menuDone(ctx);
            },
            .done = self.allocator.dupe(u8, done) catch {
                self.allocator.free(er.tmp);
                self.allocator.destroy(er);
                return menuDone(ctx);
            },
        };
        // Write one basename per line; remember the full paths.
        var zb: [4300:0]u8 = undefined;
        const tz = std.fmt.bufPrintZ(&zb, "{s}", .{tmp}) catch {
            er.destroy(self.allocator);
            return menuDone(ctx);
        };
        const f = c.fopen(tz.ptr, "wb") orelse {
            er.destroy(self.allocator);
            return menuDone(ctx);
        };
        for (tab.selected.items) |sp| {
            const owned = self.allocator.dupe(u8, sp) catch continue;
            er.paths.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                continue;
            };
            const base = std.fs.path.basename(sp);
            _ = c.fwrite(base.ptr, 1, base.len, f);
            _ = c.fwrite("\n", 1, 1, f);
        }
        _ = c.fclose(f);

        var dzb: [4300:0]u8 = undefined;
        const dz = std.fmt.bufPrintZ(&dzb, "{s}", .{done}) catch {
            er.destroy(self.allocator);
            return menuDone(ctx);
        };
        const gfile = c.g_file_new_for_path(dz.ptr);
        er.monitor = c.g_file_monitor_file(gfile, c.G_FILE_MONITOR_NONE, null, null);
        c.g_object_unref(gfile);
        if (er.monitor == null) {
            er.destroy(self.allocator);
            return menuDone(ctx);
        }
        _ = c.g_signal_connect_data(er.monitor, "changed", @ptrCast(&onEditorRenameDone), @ptrCast(er), null, c.G_CONNECT_DEFAULT);
        self.editor_rename = er;

        // Run $EDITOR in the pane's shell; touching the done file
        // fires the monitor.
        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(self.allocator);
        cmd.appendSlice(self.allocator, "\"${EDITOR:-vi}\" ") catch return menuDone(ctx);
        appendQuoted(&cmd, self.allocator, tmp) catch return menuDone(ctx);
        cmd.appendSlice(self.allocator, " && touch ") catch return menuDone(ctx);
        appendQuoted(&cmd, self.allocator, done) catch return menuDone(ctx);
        cmd.append(self.allocator, '\n') catch return menuDone(ctx);
        self.pane.terminal.writeRaw(cmd.items);
        self.pane.setBrowserVisible(false);
        self.setStatus("edit the names, save, and quit the editor to apply");
        menuDone(ctx);
    }

    fn onEditorRenameDone(
        _: *c.GFileMonitor,
        _: ?*c.GFile,
        _: ?*c.GFile,
        event: c.GFileMonitorEvent,
        user: ?*anyopaque,
    ) callconv(.c) void {
        if (event != c.G_FILE_MONITOR_EVENT_CREATED and event != c.G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT) return;
        const er: *EditorRename = @ptrCast(@alignCast(user.?));
        const self = er.view;
        if (self.editor_rename != er) return;
        defer {
            self.editor_rename = null;
            er.destroy(self.allocator);
        }
        var zb: [4300:0]u8 = undefined;
        const tz = std.fmt.bufPrintZ(&zb, "{s}", .{er.tmp}) catch return;
        const f = c.fopen(tz.ptr, "rb") orelse return;
        var content: [64 * 1024]u8 = undefined;
        const n = c.fread(&content, 1, content.len, f);
        _ = c.fclose(f);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var it = std.mem.splitScalar(u8, content[0..n], '\n');
        while (it.next()) |line| {
            const nm = std.mem.trim(u8, line, " \t\r");
            if (nm.len > 0) names.append(self.allocator, nm) catch return;
        }
        if (names.items.len != er.paths.items.len) {
            self.setStatusFmt("rename aborted: {d} line(s) for {d} file(s) — line count must match", .{
                names.items.len, er.paths.items.len,
            });
            return;
        }
        const hc = self.hostConnFor(if (er.host) |h| @as(?[]const u8, h) else null) orelse return;
        var renamed: usize = 0;
        for (er.paths.items, names.items) |old, new_name| {
            const base = std.fs.path.basename(old);
            if (std.mem.eql(u8, base, new_name)) continue;
            if (std.mem.indexOfScalar(u8, new_name, '/') != null) continue;
            const dir = std.fs.path.dirname(old) orelse continue;
            var nb: [4300]u8 = undefined;
            const np = std.fmt.bufPrint(&nb, "{s}/{s}", .{ if (dir.len == 1) "" else dir, new_name }) catch continue;
            const req = self.nextReq();
            self.deferUndo(req, self.makeUndo(hc.host, .rename_back, np, old, ""));
            self.sendOp(hc, .{ .req = req, .op = "rename", .path = old, .to = np });
            renamed += 1;
        }
        self.setStatusFmt("editor rename: {d} file(s) renamed", .{renamed});
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
        c.gtk_widget_set_parent(popover, tab.page);
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
        const hashb = c.gtk_button_new_with_label("Hash-verify equal-size rows");
        _ = c.g_signal_connect_data(hashb, "clicked", @ptrCast(&CompareCtx.onHashVerifyClicked), @ptrCast(cmp), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(btns), hashb);
        const mirrorb = c.gtk_button_new_with_label("Mirror: mark target-only rows for deletion");
        _ = c.g_signal_connect_data(mirrorb, "clicked", @ptrCast(&CompareCtx.onMirrorClicked), @ptrCast(cmp), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(btns), mirrorb);
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

        // Host-side digest scans (pattern * = everything; raised cap
        // so big trees compare fully).
        self.search_max_matches = 100_000;
        self.startDaemonJobKind(left_hc, "find", cmp.left.root, "", "*", "scan source tree", .compare_left);
        self.search_max_matches = 100_000;
        self.startDaemonJobKind(right_hc, "find", cmp.right.root, "", "*", "scan target tree", .compare_right);
    }

    fn onMenuBookmark(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        var spec_buf: [4400]u8 = undefined;
        const spec = if (ctx.tab.hc.host) |h|
            std.fmt.bufPrint(&spec_buf, "{s}:{s}", .{ h, path }) catch return menuDone(ctx)
        else
            path;
        self.addBookmark(spec);
        menuDone(ctx);
    }

    fn onMenuPin(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        setMountXattr(@ptrCast(@alignCast(user.?)), "user.sketerm.pin", "pinned — hydrating in the background");
    }
    fn onMenuEvict(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        setMountXattr(@ptrCast(@alignCast(user.?)), "user.sketerm.evict", "cached data evicted");
    }
    fn setMountXattr(ctx: *MenuCtx, comptime attr: [:0]const u8, comptime okmsg: []const u8) void {
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        var z: [4300:0]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return menuDone(ctx);
        if (c.setxattr(pz.ptr, attr.ptr, "1", 1, 0) != 0) {
            self.setStatusFmt("{s} failed (is this really a sketerm mount?)", .{attr});
        } else {
            self.setStatusFmt("{s}: {s}", .{ std.fs.path.basename(path), okmsg });
        }
        menuDone(ctx);
    }

    fn onMenuTrashRestoreItem(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        const tab = ctx.tab;
        var pbuf: [4096]u8 = undefined;
        if (path.len >= pbuf.len) return menuDone(ctx);
        @memcpy(pbuf[0..path.len], path);
        const pcopy = pbuf[0..path.len];
        menuDone(ctx);
        self.startTrashRestore(tab, pcopy);
    }

    fn onMenuUndo(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const view = ctx.view;
        menuDone(ctx);
        view.performUndo();
    }

    fn onMenuCalcSize(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const path = ctx.path orelse return menuDone(ctx);
        ctx.view.startDaemonJobKind(ctx.tab.hc, "find", path, "", "*", "calculate size", .calc_size);
        menuDone(ctx);
    }

    fn onMenuFindDups(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        const tab = ctx.tab;
        var pbuf: [4096]u8 = undefined;
        if (path.len >= pbuf.len) return menuDone(ctx);
        @memcpy(pbuf[0..path.len], path);
        const pcopy = pbuf[0..path.len];
        menuDone(ctx);
        self.startDupScan(tab, pcopy);
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

    fn onMenuBrowseArchive(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const tab = ctx.tab;
        const path = ctx.path orelse return menuDone(ctx);
        var pbuf: [4096]u8 = undefined;
        if (path.len >= pbuf.len) return menuDone(ctx);
        @memcpy(pbuf[0..path.len], path);
        const pcopy = pbuf[0..path.len];
        menuDone(ctx);
        self.startArchiveBrowse(tab, pcopy);
    }

    fn onMenuExtractMember(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const tab = ctx.tab;
        const member = ctx.path orelse return menuDone(ctx);
        var mbuf: [4096]u8 = undefined;
        if (member.len >= mbuf.len) return menuDone(ctx);
        @memcpy(mbuf[0..member.len], member);
        const mcopy = mbuf[0..member.len];
        menuDone(ctx);
        self.extractAndOpenMember(tab, mcopy);
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
        const self = ctx.view;
        const path = ctx.path orelse return menuDone(ctx);
        const hc = ctx.tab.hc;
        if (hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{hc.label()});
            return menuDone(ctx);
        }
        const req = self.nextReq();
        const pj = self.allocator.create(PendingJob) catch return menuDone(ctx);
        pj.* = .{
            .req = req,
            .hc = hc,
            .label = self.allocator.dupe(u8, "move to trash") catch {
                self.allocator.destroy(pj);
                return menuDone(ctx);
            },
            .undo_trash_orig = self.allocator.dupe(u8, path) catch null,
        };
        self.pending_jobs.append(self.allocator, pj) catch {
            if (pj.undo_trash_orig) |o| self.allocator.free(o);
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
            return menuDone(ctx);
        };
        self.sendOp(hc, .{ .req = req, .op = "trash", .path = path });
        menuDone(ctx);
    }

    fn entryForPath(tab: *BTab, path: []const u8) ?*Entry {
        const parent = std.fs.path.dirname(path) orelse return null;
        const dir = if (std.mem.eql(u8, tab.root.path, parent)) tab.root else tab.subdirByPath(parent) orelse return null;
        const idx = dir.find(std.fs.path.basename(path)) orelse return null;
        return &dir.entries.items[idx];
    }

    /// Recursive size probe: a daemon job so the walk happens on the
    /// host that owns the tree.
    /// One label fed by a daemon job: recursive size, checksum, or
    /// media metadata. The label is g_object_ref'd, so a dialog closed
    /// mid-flight cannot dangle.
    const LabelProbe = struct {
        kind: enum { size, hash, media },
        req: u32,
        job: u64 = 0,
        hc: *HostConn,
        label: *c.GtkWidget,
    };

    fn endProbe(self: *BrowserView, i: usize) void {
        const probe = self.probes.items[i];
        c.g_object_unref(@ptrCast(probe.label));
        _ = self.probes.orderedRemove(i);
    }

    fn endProbesFor(self: *BrowserView, hc: ?*HostConn, message: [*:0]const u8) void {
        var i: usize = 0;
        while (i < self.probes.items.len) {
            const probe = self.probes.items[i];
            if (hc == null or probe.hc == hc.?) {
                c.gtk_label_set_text(@ptrCast(probe.label), message);
                self.endProbe(i);
            } else i += 1;
        }
    }

    fn startProbe(self: *BrowserView, kind: @FieldType(LabelProbe, "kind"), hc: *HostConn, label: *c.GtkWidget, op: []const u8, path: []const u8) void {
        if (hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{hc.label()});
            return;
        }
        const req = self.nextReq();
        _ = c.g_object_ref(@ptrCast(label));
        self.probes.append(self.allocator, .{ .kind = kind, .req = req, .hc = hc, .label = label }) catch {
            c.g_object_unref(@ptrCast(label));
            return;
        };
        c.gtk_label_set_text(@ptrCast(label), "calculating…");
        self.sendOp(hc, .{ .req = req, .op = op, .path = path });
    }

    fn feedProbes(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
        if (self.probes.items.len == 0) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        switch (ftype) {
            .fs_reply => {
                const rep = std.json.parseFromSliceLeaky(struct {
                    req: u32 = 0,
                    ok: bool = false,
                    job: u64 = 0,
                }, arena.allocator(), payload, .{ .ignore_unknown_fields = true }) catch return false;
                for (self.probes.items, 0..) |*probe, i| {
                    if (probe.hc != hc or probe.req != rep.req) continue;
                    if (!rep.ok or rep.job == 0) {
                        c.gtk_label_set_text(@ptrCast(probe.label), "unavailable");
                        self.endProbe(i);
                    } else probe.job = rep.job;
                    return true;
                }
                return false;
            },
            .fs_job => {
                const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{ .ignore_unknown_fields = true }) catch return false;
                for (self.probes.items, 0..) |probe, i| {
                    if (probe.hc != hc or probe.job == 0 or probe.job != ev.job) continue;
                    const done = std.mem.eql(u8, ev.ev, "done");
                    if (!done and !std.mem.eql(u8, ev.ev, "progress")) {
                        if (ev.terminalEv()) {
                            c.gtk_label_set_text(@ptrCast(probe.label), "unavailable");
                            self.endProbe(i);
                        }
                        return true;
                    }
                    var buf: [1024:0]u8 = undefined;
                    var human: [48:0]u8 = undefined;
                    const text: [*:0]const u8 = switch (probe.kind) {
                        .size => if (std.fmt.bufPrintZ(&buf, "{s} ({d} bytes) in {d} items{s}", .{
                            fmtSize(&human, ev.done), ev.done, ev.total, if (done) "" else " …",
                        })) |v| v.ptr else |_| "",
                        .hash => if (!done) "hashing…" else copyZ(@ptrCast(&buf), ev.hash),
                        .media => if (!done) "reading…" else copyZ(@ptrCast(&buf), if (ev.text.len > 0) ev.text else "(no metadata)"),
                    };
                    c.gtk_label_set_text(@ptrCast(probe.label), text);
                    if (done) self.endProbe(i);
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Properties: identity + timestamps, an on-demand recursive size
    /// for directories, and a full permission/ownership editor with
    /// optional recursive apply.
    const PropsCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        tab: *BTab,
        path: []u8,
        is_dir: bool,
        /// u/g/o x r/w/x, then setuid/setgid/sticky.
        perm_bits: [12]*c.GtkWidget = undefined,
        octal: *c.GtkWidget = undefined,
        uid_entry: *c.GtkWidget = undefined,
        gid_entry: *c.GtkWidget = undefined,
        recursive: ?*c.GtkWidget = null,
        size_label: *c.GtkWidget = undefined,
        hash_label: *c.GtkWidget = undefined,
        media_label: ?*c.GtkWidget = null,
        attr_box: *c.GtkWidget = undefined,
        attr_name_entry: *c.GtkWidget = undefined,
        attr_value_entry: *c.GtkWidget = undefined,
        syncing: bool = false,

        fn free(user: ?*anyopaque) callconv(.c) void {
            const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
            ctx.allocator.free(ctx.path);
            ctx.allocator.destroy(ctx);
        }

        /// Bit weight of perm_bits[i]: 0o400 down to 0o1, then the
        /// setuid/setgid/sticky triple.
        fn weight(i: usize) u32 {
            if (i < 9) return @as(u32, 1) << @intCast(8 - i);
            return switch (i) {
                9 => 0o4000,
                10 => 0o2000,
                else => 0o1000,
            };
        }

        fn modeFromChecks(self: *const PropsCtx) u32 {
            var mode: u32 = 0;
            for (self.perm_bits, 0..) |btn, i| {
                if (c.gtk_check_button_get_active(@ptrCast(btn)) != 0) mode |= weight(i);
            }
            return mode;
        }

        fn applyChecks(self: *PropsCtx, mode: u32) void {
            self.syncing = true;
            for (self.perm_bits, 0..) |btn, i|
                c.gtk_check_button_set_active(@ptrCast(btn), @intFromBool(mode & weight(i) != 0));
            self.syncing = false;
        }

        fn setOctal(self: *PropsCtx, mode: u32) void {
            var buf: [16:0]u8 = undefined;
            const txt = std.fmt.bufPrintZ(&buf, "{o:0>4}", .{mode & 0o7777}) catch return;
            self.syncing = true;
            c.gtk_editable_set_text(@ptrCast(self.octal), txt.ptr);
            self.syncing = false;
        }
    };

    fn propsRow(box: *c.GtkWidget, label: []const u8, value: []const u8) void {
        var buf: [1024:0]u8 = undefined;
        const txt = std.fmt.bufPrintZ(&buf, "{s}: {s}", .{ label, value }) catch return;
        const w = c.gtk_label_new(txt.ptr);
        c.gtk_label_set_xalign(@ptrCast(w), 0);
        c.gtk_label_set_selectable(@ptrCast(w), 1);
        c.gtk_label_set_ellipsize(@ptrCast(w), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_box_append(@ptrCast(box), w);
    }

    fn onMenuProperties(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const old: *MenuCtx = @ptrCast(@alignCast(user.?));
        const old_path = old.path orelse return menuDone(old);
        const self = old.view;
        const tab = old.tab;
        // Pop the context menu down FIRST: a popover built while the
        // menu is still up loses its grab when the menu closes.
        var path_buf: [4096]u8 = undefined;
        const n = @min(old_path.len, path_buf.len);
        @memcpy(path_buf[0..n], old_path[0..n]);
        const path = path_buf[0..n];
        menuDone(old);
        const e = entryForPath(tab, path) orelse {
            self.setStatus("properties: entry is no longer in the listing");
            return;
        };
        const popover = c.gtk_popover_new();
        const ctx = self.allocator.create(PropsCtx) catch return;
        ctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = tab,
            .path = self.allocator.dupe(u8, path) catch {
                self.allocator.destroy(ctx);
                return;
            },
            .is_dir = e.tdir,
        };
        c.g_object_set_data_full(@ptrCast(popover), "sketerm-props", @ptrCast(ctx), @ptrCast(&PropsCtx.free));

        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
        c.gtk_widget_set_margin_start(box, 10);
        c.gtk_widget_set_margin_end(box, 10);
        c.gtk_widget_set_margin_top(box, 10);
        c.gtk_widget_set_margin_bottom(box, 10);

        var name_z: [512:0]u8 = undefined;
        const title = c.gtk_label_new(copyZ(@ptrCast(&name_z), std.fs.path.basename(path)));
        c.gtk_widget_add_css_class(title, "heading");
        c.gtk_label_set_xalign(@ptrCast(title), 0);
        c.gtk_box_append(@ptrCast(box), title);

        var scratch: [1024]u8 = undefined;
        propsRow(box, "Location", std.fs.path.dirname(path) orelse "/");
        propsRow(box, "Host", if (tab.hc.host) |h| h else "local");
        // MIME comes from the NAME only: guessing from content would
        // mean reading the file, which is wrong for a remote entry.
        var content_type: ?[*c]c.gchar = null;
        if (!e.tdir) {
            var basez: [512:0]u8 = undefined;
            content_type = c.g_content_type_guess(copyZ(@ptrCast(&basez), std.fs.path.basename(path)), null, 0, null);
        }
        defer if (content_type) |ct| c.g_free(ct);
        propsRow(box, "Type", if (content_type) |ct|
            std.fmt.bufPrint(&scratch, "{s} ({s})", .{ e.kind, std.mem.span(@as([*:0]const u8, @ptrCast(ct))) }) catch e.kind
        else
            e.kind);
        if (e.target) |t| propsRow(box, "Symlink target", t);
        var human: [48:0]u8 = undefined;
        // st_blocks is 0 on filesystems that do not report allocation
        // (tmpfs directories); saying "0 on disk" would read as a fact.
        propsRow(box, "Size", if (e.blocks > 0)
            std.fmt.bufPrint(&scratch, "{s} ({d} bytes, {d} on disk)", .{
                fmtSize(&human, e.size), e.size, e.blocks * 512,
            }) catch ""
        else
            std.fmt.bufPrint(&scratch, "{s} ({d} bytes)", .{ fmtSize(&human, e.size), e.size }) catch "");
        propsRow(box, "Links", std.fmt.bufPrint(&scratch, "{d}", .{e.nlink}) catch "");
        var tbuf: [40:0]u8 = undefined;
        propsRow(box, "Modified", std.mem.span(fmtTimeZ(&tbuf, e.mtime_ms)));
        propsRow(box, "Accessed", std.mem.span(fmtTimeZ(&tbuf, e.atime_ms)));
        propsRow(box, "Changed", std.mem.span(fmtTimeZ(&tbuf, e.ctime_ms)));

        if (e.tdir) {
            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
            const lbl = c.gtk_label_new("Contents: not calculated");
            c.gtk_label_set_xalign(@ptrCast(lbl), 0);
            c.gtk_widget_set_hexpand(lbl, 1);
            ctx.size_label = lbl;
            c.gtk_box_append(@ptrCast(row), lbl);
            const calc = c.gtk_button_new_with_label("Calculate");
            _ = c.g_signal_connect_data(calc, "clicked", @ptrCast(&onPropsCalcSize), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(row), calc);
            c.gtk_box_append(@ptrCast(box), row);
        } else {
            // Checksum on demand: hashing runs on the file's host, so
            // a remote checksum never streams the file to us.
            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
            const lbl = c.gtk_label_new("SHA-256: not calculated");
            c.gtk_label_set_xalign(@ptrCast(lbl), 0);
            c.gtk_label_set_selectable(@ptrCast(lbl), 1);
            c.gtk_label_set_ellipsize(@ptrCast(lbl), c.PANGO_ELLIPSIZE_MIDDLE);
            c.gtk_widget_set_hexpand(lbl, 1);
            ctx.hash_label = lbl;
            c.gtk_box_append(@ptrCast(row), lbl);
            const calc = c.gtk_button_new_with_label("Checksum");
            _ = c.g_signal_connect_data(calc, "clicked", @ptrCast(&onPropsChecksum), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(row), calc);
            c.gtk_box_append(@ptrCast(box), row);

            // Default application, changeable from here.
            const app_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
            var app_buf: [256:0]u8 = undefined;
            const app_name: [*:0]const u8 = blk: {
                const ct = content_type orelse break :blk "Opens with: (unknown type)";
                const info = c.g_app_info_get_default_for_type(ct, 0) orelse break :blk "Opens with: (no default)";
                defer c.g_object_unref(@as(?*anyopaque, @ptrCast(info)));
                const name = c.g_app_info_get_display_name(info) orelse break :blk "Opens with: (no default)";
                if (std.fmt.bufPrintZ(&app_buf, "Opens with: {s}", .{std.mem.span(@as([*:0]const u8, @ptrCast(name)))})) |v| {
                    break :blk v.ptr;
                } else |_| break :blk "Opens with:";
            };
            const app_label = c.gtk_label_new(app_name);
            c.gtk_label_set_xalign(@ptrCast(app_label), 0);
            c.gtk_widget_set_hexpand(app_label, 1);
            c.gtk_box_append(@ptrCast(app_row), app_label);
            const change = c.gtk_button_new_with_label("Change…");
            _ = c.g_signal_connect_data(change, "clicked", @ptrCast(&onPropsOpenWith), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(app_row), change);
            c.gtk_box_append(@ptrCast(box), app_row);

            if (isPreviewMediaName(path) and !isImageName(path)) {
                const media_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
                const lbl2 = c.gtk_label_new("Media info: not read");
                c.gtk_label_set_xalign(@ptrCast(lbl2), 0);
                c.gtk_label_set_selectable(@ptrCast(lbl2), 1);
                c.gtk_widget_set_hexpand(lbl2, 1);
                ctx.media_label = lbl2;
                c.gtk_box_append(@ptrCast(media_row), lbl2);
                const read = c.gtk_button_new_with_label("Read");
                _ = c.g_signal_connect_data(read, "clicked", @ptrCast(&onPropsMediaInfo), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
                c.gtk_box_append(@ptrCast(media_row), read);
                c.gtk_box_append(@ptrCast(box), media_row);
            }
        }

        c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));

        // Extended attributes: metadata that travels WITH the file,
        // including the freedesktop comment and download origin.
        const attr_head = c.gtk_label_new("Attributes");
        c.gtk_widget_add_css_class(attr_head, "heading");
        c.gtk_label_set_xalign(@ptrCast(attr_head), 0);
        c.gtk_box_append(@ptrCast(box), attr_head);
        const attr_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
        ctx.attr_box = attr_box;
        const loading = c.gtk_label_new("reading…");
        c.gtk_label_set_xalign(@ptrCast(loading), 0);
        c.gtk_widget_add_css_class(loading, "dim-label");
        c.gtk_box_append(@ptrCast(attr_box), loading);
        c.gtk_box_append(@ptrCast(box), attr_box);

        const add_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        const add_name = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(add_name), "user.name");
        c.gtk_widget_set_hexpand(add_name, 1);
        const add_value = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(add_value), "value");
        c.gtk_widget_set_hexpand(add_value, 1);
        ctx.attr_name_entry = add_name;
        ctx.attr_value_entry = add_value;
        const add_btn = c.gtk_button_new_with_label("Set");
        _ = c.g_signal_connect_data(add_btn, "clicked", @ptrCast(&onPropsAttrAdd), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(add_row), add_name);
        c.gtk_box_append(@ptrCast(add_row), add_value);
        c.gtk_box_append(@ptrCast(add_row), add_btn);
        c.gtk_box_append(@ptrCast(box), add_row);
        self.requestAttrs(ctx);

        c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));

        const grid = c.gtk_grid_new();
        c.gtk_grid_set_row_spacing(@ptrCast(grid), 2);
        c.gtk_grid_set_column_spacing(@ptrCast(grid), 8);
        const who = [_][*:0]const u8{ "Owner", "Group", "Others" };
        const what = [_][*:0]const u8{ "read", "write", "exec" };
        for (who, 0..) |w, r| {
            const wl = c.gtk_label_new(w);
            c.gtk_label_set_xalign(@ptrCast(wl), 0);
            c.gtk_grid_attach(@ptrCast(grid), wl, 0, @intCast(r), 1, 1);
            for (what, 0..) |bit, col| {
                const check = c.gtk_check_button_new_with_label(bit);
                ctx.perm_bits[r * 3 + col] = check;
                _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onPropsBitToggled), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
                c.gtk_grid_attach(@ptrCast(grid), check, @intCast(col + 1), @intCast(r), 1, 1);
            }
        }
        const special = [_][*:0]const u8{ "setuid", "setgid", "sticky" };
        const sl = c.gtk_label_new("Special");
        c.gtk_label_set_xalign(@ptrCast(sl), 0);
        c.gtk_grid_attach(@ptrCast(grid), sl, 0, 3, 1, 1);
        for (special, 0..) |bit, col| {
            const check = c.gtk_check_button_new_with_label(bit);
            ctx.perm_bits[9 + col] = check;
            _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onPropsBitToggled), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
            c.gtk_grid_attach(@ptrCast(grid), check, @intCast(col + 1), 3, 1, 1);
        }
        c.gtk_box_append(@ptrCast(box), grid);

        const octal_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_box_append(@ptrCast(octal_row), c.gtk_label_new("Octal"));
        const octal = c.gtk_entry_new();
        c.gtk_entry_set_max_length(@ptrCast(octal), 4);
        ctx.octal = octal;
        _ = c.g_signal_connect_data(octal, "changed", @ptrCast(&onPropsOctalChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(octal_row), octal);
        c.gtk_box_append(@ptrCast(box), octal_row);
        ctx.applyChecks(e.mode);
        ctx.setOctal(e.mode);

        const own_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_box_append(@ptrCast(own_row), c.gtk_label_new("uid"));
        const uid_entry = c.gtk_entry_new();
        c.gtk_widget_set_size_request(uid_entry, 80, -1);
        var idbuf: [16:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&idbuf, "{d}", .{e.uid})) |v| c.gtk_editable_set_text(@ptrCast(uid_entry), v.ptr) else |_| {}
        ctx.uid_entry = uid_entry;
        c.gtk_box_append(@ptrCast(own_row), uid_entry);
        c.gtk_box_append(@ptrCast(own_row), c.gtk_label_new("gid"));
        const gid_entry = c.gtk_entry_new();
        c.gtk_widget_set_size_request(gid_entry, 80, -1);
        if (std.fmt.bufPrintZ(&idbuf, "{d}", .{e.gid})) |v| c.gtk_editable_set_text(@ptrCast(gid_entry), v.ptr) else |_| {}
        ctx.gid_entry = gid_entry;
        c.gtk_box_append(@ptrCast(own_row), gid_entry);
        c.gtk_box_append(@ptrCast(box), own_row);

        if (e.tdir) {
            const rec = c.gtk_check_button_new_with_label("Apply to enclosed files and folders");
            ctx.recursive = rec;
            c.gtk_box_append(@ptrCast(box), rec);
        }

        const apply = c.gtk_button_new_with_label("Apply");
        c.gtk_widget_add_css_class(apply, "suggested-action");
        _ = c.g_signal_connect_data(apply, "clicked", @ptrCast(&onPropsApply), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), apply);

        const scroll = c.gtk_scrolled_window_new();
        c.gtk_widget_set_size_request(scroll, 400, 520);
        c.gtk_scrolled_window_set_child(@ptrCast(scroll), box);
        c.gtk_popover_set_child(@ptrCast(popover), scroll);
        c.gtk_widget_set_parent(popover, tab.page);
        connectPopoverAutoUnparent(popover);
        const rect = c.GdkRectangle{ .x = 320, .y = 120, .width = 1, .height = 1 };
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
        c.gtk_popover_popup(@ptrCast(popover));
    }

    /// In-flight attr_list for an open Properties dialog. The box is
    /// g_object_ref'd so a closed dialog cannot dangle; the path is
    /// kept because the reply carries no echo of it.
    const AttrRequest = struct {
        req: u32,
        hc: *HostConn,
        box: *c.GtkWidget,
        path: []u8,
    };

    fn endAttrRequest(self: *BrowserView) void {
        const request = self.attr_request orelse return;
        c.g_object_unref(@ptrCast(request.box));
        self.allocator.free(request.path);
        self.attr_request = null;
    }

    fn requestAttrs(self: *BrowserView, ctx: *PropsCtx) void {
        const hc = ctx.tab.hc;
        if (hc.state != .ready) return;
        self.endAttrRequest();
        const path = self.allocator.dupe(u8, ctx.path) catch return;
        const req = self.nextReq();
        _ = c.g_object_ref(@ptrCast(ctx.attr_box));
        self.attr_request = .{ .req = req, .hc = hc, .box = ctx.attr_box, .path = path };
        self.sendOp(hc, .{ .req = req, .op = "attr_list", .path = ctx.path });
    }

    /// Heap context for one attribute row's Set button.
    const AttrRowCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        hc: *HostConn,
        path: []u8,
        name: []u8,
        entry: *c.GtkWidget,

        fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const ctx: *AttrRowCtx = @ptrCast(@alignCast(user.?));
            ctx.allocator.free(ctx.path);
            ctx.allocator.free(ctx.name);
            ctx.allocator.destroy(ctx);
        }
    };

    fn feedAttrRequest(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
        if (ftype != .fs_reply) return false;
        const request = self.attr_request orelse return false;
        if (request.hc != hc) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const rep = std.json.parseFromSliceLeaky(struct {
            req: u32 = 0,
            ok: bool = false,
            attrs: []const fsserve.Attr = &.{},
        }, arena.allocator(), payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return false;
        if (rep.req != request.req) return false;

        while (c.gtk_widget_get_first_child(request.box)) |child|
            c.gtk_box_remove(@ptrCast(request.box), child);
        if (!rep.ok or rep.attrs.len == 0) {
            const none = c.gtk_label_new(if (rep.ok) "(none)" else "(unavailable)");
            c.gtk_label_set_xalign(@ptrCast(none), 0);
            c.gtk_widget_add_css_class(none, "dim-label");
            c.gtk_box_append(@ptrCast(request.box), none);
            self.endAttrRequest();
            return true;
        }
        for (rep.attrs) |attr| {
            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
            var name_z: [256:0]u8 = undefined;
            const label = c.gtk_label_new(copyZ(@ptrCast(&name_z), attrLabel(attr.name)));
            c.gtk_label_set_xalign(@ptrCast(label), 0);
            c.gtk_widget_set_size_request(label, 150, -1);
            c.gtk_widget_set_tooltip_text(label, copyZ(@ptrCast(&name_z), attr.name));
            c.gtk_box_append(@ptrCast(row), label);
            const entry = c.gtk_entry_new();
            c.gtk_widget_set_hexpand(entry, 1);
            var value_z: [1024:0]u8 = undefined;
            c.gtk_editable_set_text(@ptrCast(entry), copyZ(@ptrCast(&value_z), attr.value));
            c.gtk_box_append(@ptrCast(row), entry);
            const set = c.gtk_button_new_with_label("Set");
            const rctx = self.allocator.create(AttrRowCtx) catch continue;
            rctx.* = .{
                .allocator = self.allocator,
                .view = self,
                .hc = hc,
                .path = self.allocator.dupe(u8, request.path) catch {
                    self.allocator.destroy(rctx);
                    continue;
                },
                .name = self.allocator.dupe(u8, attr.name) catch {
                    self.allocator.free(rctx.path);
                    self.allocator.destroy(rctx);
                    continue;
                },
                .entry = entry,
            };
            _ = c.g_signal_connect_data(set, "clicked", @ptrCast(&onAttrRowSet), @ptrCast(rctx), @ptrCast(&AttrRowCtx.free), c.G_CONNECT_DEFAULT);
            _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onAttrRowActivate), @ptrCast(rctx), null, c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(row), set);
            c.gtk_box_append(@ptrCast(request.box), row);
        }
        self.endAttrRequest();
        return true;
    }

    /// Friendly name for the attributes with agreed meanings; other
    /// names show as-is (minus the namespace).
    fn attrLabel(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, "user.xdg.comment")) return "Comment";
        if (std.mem.eql(u8, name, "user.xdg.origin.url")) return "Where from";
        if (std.mem.eql(u8, name, "user.xdg.referrer.url")) return "Referrer";
        if (std.mem.eql(u8, name, fsserve.TAGS_XATTR)) return "Tags";
        if (std.mem.startsWith(u8, name, "user.sketerm.")) return name["user.sketerm.".len..];
        if (std.mem.startsWith(u8, name, "user.")) return name["user.".len..];
        return name;
    }

    fn onAttrRowSet(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *AttrRowCtx = @ptrCast(@alignCast(user.?));
        const value = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.entry)))));
        const self = ctx.view;
        self.sendOp(ctx.hc, .{ .req = self.nextReq(), .op = "attr_set", .path = ctx.path, .pattern = ctx.name, .to = value });
        if (value.len == 0)
            self.setStatusFmt("cleared {s}", .{attrLabel(ctx.name)})
        else
            self.setStatusFmt("set {s}", .{attrLabel(ctx.name)});
    }

    fn onAttrRowActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        onAttrRowSet(undefined, user);
    }

    fn onPropsAttrAdd(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.attr_name_entry)))));
        const value = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.attr_value_entry)))));
        if (name.len == 0) return self.setStatus("attribute name required");
        if (!std.mem.startsWith(u8, name, "user."))
            return self.setStatus("attribute names must start with user.");
        self.sendOp(ctx.tab.hc, .{ .req = self.nextReq(), .op = "attr_set", .path = ctx.path, .pattern = name, .to = value });
        self.setStatusFmt("set {s}", .{name});
        // Re-read so the list shows what the host actually stored.
        self.requestAttrs(ctx);
    }

    fn onPropsChecksum(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        ctx.view.startProbe(.hash, ctx.tab.hc, ctx.hash_label, "hash", ctx.path);
    }

    fn onPropsMediaInfo(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        const label = ctx.media_label orelse return;
        ctx.view.startProbe(.media, ctx.tab.hc, label, "preview", ctx.path);
    }

    fn onPropsOpenWith(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        ctx.view.openWithDialog(ctx.tab, ctx.path);
    }

    fn onPropsBitToggled(_: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        if (ctx.syncing) return;
        ctx.setOctal(ctx.modeFromChecks());
    }

    fn onPropsOctalChanged(entry: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        if (ctx.syncing) return;
        const txt = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
        const mode = std.fmt.parseInt(u32, txt, 8) catch return;
        if (mode > 0o7777) return;
        ctx.applyChecks(mode);
    }

    fn onPropsCalcSize(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const hc = ctx.tab.hc;
        if (hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{hc.label()});
            return;
        }
        self.startProbe(.size, hc, ctx.size_label, "dir_size", ctx.path);
    }

    fn onPropsApply(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        const hc = ctx.tab.hc;
        if (hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{hc.label()});
            return;
        }
        const mode = ctx.modeFromChecks();
        const uid = parseId(ctx.uid_entry);
        const gid = parseId(ctx.gid_entry);
        const recursive = if (ctx.recursive) |r| c.gtk_check_button_get_active(@ptrCast(r)) != 0 else false;
        if (recursive) {
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "permissions {s}", .{std.fs.path.basename(ctx.path)}) catch "permissions";
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
            self.sendOp(hc, .{
                .req = req,
                .op = "perm_tree",
                .path = ctx.path,
                .mode = mode,
                .uid = uid,
                .gid = gid,
            });
            self.setStatus("applying permissions recursively");
            return;
        }
        self.sendOp(hc, .{ .req = self.nextReq(), .op = "chmod", .path = ctx.path, .mode = mode });
        if (uid != null or gid != null)
            self.sendOp(hc, .{ .req = self.nextReq(), .op = "chown", .path = ctx.path, .uid = uid, .gid = gid });
        self.setStatusFmt("applied {o:0>4} to {s}", .{ mode & 0o7777, std.fs.path.basename(ctx.path) });
    }

    /// Entry text as a uid/gid, or null when it is empty or invalid
    /// (null leaves the current owner alone).
    fn parseId(entry: *c.GtkWidget) ?u32 {
        const txt = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
        if (txt.len == 0) return null;
        return std.fmt.parseInt(u32, txt, 10) catch null;
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
        c.gtk_widget_set_parent(popover, ctx.tab.page);
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
        c.gtk_widget_set_parent(popover, tab.page);
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
                self.deferUndo(req, self.makeUndo(ctx.tab.hc.host, .rmdir_created, w.buffered(), "", ""));
                self.sendOp(ctx.tab.hc, .{ .req = req, .op = "mkdir", .path = w.buffered() });
            },
            .rename => {
                const old = ctx.path orelse return menuDone(ctx);
                const dir = std.fs.path.dirname(old) orelse return menuDone(ctx);
                w.print("{s}/{s}", .{ if (dir.len == 1) "" else dir, name }) catch return menuDone(ctx);
                self.deferUndo(req, self.makeUndo(ctx.tab.hc.host, .rename_back, w.buffered(), old, ""));
                self.sendOp(ctx.tab.hc, .{ .req = req, .op = "rename", .path = old, .to = w.buffered() });
            },
            .none, .tags => {},
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
        var pattern: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        if (pattern.len == 0) return;
        // Relative-time prefix: "@7d pat" / "@12h pat" / "@30m pat"
        // limits name matches to entries modified in that window.
        self.search_within_ms = 0;
        if (pattern[0] == '@') {
            if (std.mem.indexOfScalar(u8, pattern, ' ')) |sp| {
                const tok = pattern[1..sp];
                if (tok.len >= 2) {
                    const unit: u64 = switch (tok[tok.len - 1]) {
                        'd' => 24 * 3600 * 1000,
                        'h' => 3600 * 1000,
                        'm' => 60 * 1000,
                        else => 0,
                    };
                    const num = std.fmt.parseInt(u64, tok[0 .. tok.len - 1], 10) catch 0;
                    if (unit != 0 and num != 0) {
                        self.search_within_ms = num * unit;
                        pattern = std.mem.trimStart(u8, pattern[sp + 1 ..], " ");
                    }
                }
            }
        }
        if (pattern.len == 0) return;
        const panelize = pattern.len > 1 and pattern[0] == '!';
        const content = !panelize and c.gtk_check_button_get_active(@ptrCast(self.search_content)) != 0;

        // Remember for the save-search button.
        if (!panelize) {
            var spec_buf: [4400]u8 = undefined;
            const root_spec = tab.spec(&spec_buf);
            const spec_owned = self.allocator.dupe(u8, root_spec) catch null;
            const pat_owned = self.allocator.dupe(u8, pattern) catch null;
            if (spec_owned != null and pat_owned != null) {
                if (self.last_search) |ls| ls.deinitOwned(self.allocator);
                self.last_search = .{ .spec = spec_owned.?, .pattern = pat_owned.?, .content = content };
            } else {
                if (spec_owned) |so| self.allocator.free(so);
                if (pat_owned) |po| self.allocator.free(po);
            }
        }

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

    // ── git status overlay (local roots) ────────────────────────

    fn clearGitMap(self: *BrowserView) void {
        var it = self.git_map.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.git_map.clearRetainingCapacity();
    }

    /// Kick a background `git status` for a LOCAL root. Results land
    /// via idle handback; a stale generation is discarded.
    fn refreshGitOverlay(self: *BrowserView, tab: *BTab) void {
        if (tab.hc.host != null) return;
        self.git_gen +%= 1;
        self.clearGitMap();
        if (self.git_root.len > 0) self.allocator.free(self.git_root);
        self.git_root = self.allocator.dupe(u8, tab.root.path) catch &.{};
        if (self.git_inflight) |g| g.orphaned = true;
        const a = std.heap.c_allocator;
        const ctx = a.create(GitCtx) catch return;
        ctx.* = .{
            .view = self,
            .root = a.dupe(u8, tab.root.path) catch {
                a.destroy(ctx);
                return;
            },
            .gen = self.git_gen,
        };
        self.git_inflight = ctx;
        const th = std.Thread.spawn(.{}, gitThreadMain, .{ctx}) catch {
            self.git_inflight = null;
            ctx.destroy();
            return;
        };
        th.detach();
    }

    fn gitThreadMain(ctx: *GitCtx) void {
        const a = std.heap.c_allocator;
        // Quoted root; popen runs through sh.
        var cmd: [4400:0]u8 = undefined;
        var w = std.Io.Writer.fixed(cmd[0 .. cmd.len - 1]);
        w.writeAll("cd '") catch return finishGit(ctx);
        for (ctx.root) |ch| {
            if (ch == '\'') w.writeAll("'\\''") catch return finishGit(ctx) else w.writeByte(ch) catch return finishGit(ctx);
        }
        w.writeAll("' 2>/dev/null && git status --porcelain --no-renames -z 2>/dev/null | head -c 65536 && printf '\\x01' && git rev-parse --show-prefix 2>/dev/null") catch return finishGit(ctx);
        cmd[w.buffered().len] = 0;
        const fp = c.popen(&cmd, "r") orelse return finishGit(ctx);
        var out: std.ArrayList(u8) = .empty;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = c.fread(&buf, 1, buf.len, fp);
            if (n == 0) break;
            out.appendSlice(a, buf[0..n]) catch break;
            if (out.items.len > 128 * 1024) break;
        }
        _ = c.pclose(fp);
        ctx.out = out.toOwnedSlice(a) catch null;
        finishGit(ctx);
    }

    fn finishGit(ctx: *GitCtx) void {
        _ = c.g_idle_add(@ptrCast(&onGitIdle), @ptrCast(ctx));
    }

    fn onGitIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const ctx: *GitCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        if (ctx.orphaned) return 0;
        const self = ctx.view;
        if (self.git_inflight == ctx) self.git_inflight = null;
        if (ctx.gen != self.git_gen) return 0;
        const out = ctx.out orelse return 0;
        // out = "<porcelain -z>\x01<prefix>\n"
        const sep = std.mem.indexOfScalar(u8, out, 1) orelse return 0;
        const status = out[0..sep];
        var prefix = std.mem.trim(u8, out[sep + 1 ..], "\n ");
        _ = &prefix;
        var it = std.mem.tokenizeScalar(u8, status, 0);
        while (it.next()) |rec| {
            if (rec.len < 4) continue;
            const st: u8 = if (rec[0] != ' ' and rec[0] != '?') rec[0] else rec[1];
            var path = rec[3..];
            // Paths are repo-root-relative; strip the prefix of the
            // browsed subdir, skip entries outside it.
            if (prefix.len > 0) {
                if (!std.mem.startsWith(u8, path, prefix)) continue;
                path = path[prefix.len..];
            }
            if (path.len == 0) continue;
            const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
            const child = path[0..end];
            if (child.len == 0) continue;
            const gop = self.git_map.getOrPut(child) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = self.allocator.dupe(u8, child) catch {
                    _ = self.git_map.remove(child);
                    continue;
                };
                gop.value_ptr.* = st;
            } else if (gop.value_ptr.* == '?' and st != '?') {
                // A real change outranks "untracked" for aggregation.
                gop.value_ptr.* = st;
            }
        }
        if (self.git_map.count() > 0) self.renderCurrent();
        return 0;
    }

    // ── file color rules ────────────────────────────────────────

    /// ~/.config/sketerm/filecolors.conf: one "glob=#RRGGBB" per
    /// line; first matching rule colors the file name.
    fn loadFileColors(self: *BrowserView) void {
        var pbuf: [4096:0]u8 = undefined;
        const cfg = c.g_get_user_config_dir();
        const path = std.fmt.bufPrintZ(&pbuf, "{s}/sketerm/filecolors.conf", .{cfg}) catch return;
        const f = c.fopen(path.ptr, "rb") orelse return;
        defer _ = c.fclose(f);
        var content: [16 * 1024]u8 = undefined;
        const n = c.fread(&content, 1, content.len, f);
        var it = std.mem.tokenizeScalar(u8, content[0..n], '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const glob = std.mem.trim(u8, line[0..eq], " ");
            const color = std.mem.trim(u8, line[eq + 1 ..], " ");
            if (glob.len == 0 or color.len != 7 or color[0] != '#') continue;
            var fc = FileColor{
                .glob = self.allocator.dupe(u8, glob) catch continue,
                .color = undefined,
            };
            @memcpy(&fc.color, color[0..7]);
            self.file_colors.append(self.allocator, fc) catch self.allocator.free(fc.glob);
        }
    }

    fn fileColorFor(self: *BrowserView, name: []const u8) ?*const [7]u8 {
        for (self.file_colors.items) |*fc| {
            if (fsjob.nameMatches(fc.glob, name)) return &fc.color;
        }
        return null;
    }

    // ── restore from trash ──────────────────────────────────────

    /// Fetch the .trashinfo for a trashed entry, then restore it to
    /// the Path= recorded inside.
    fn startTrashRestore(self: *BrowserView, tab: *BTab, trashed: []const u8) void {
        if (self.restore_read) |rr| {
            rr.destroy(self.allocator);
            self.restore_read = null;
        }
        const name = std.fs.path.basename(trashed);
        const files_dir = std.fs.path.dirname(trashed) orelse return;
        const trash_root = std.fs.path.dirname(files_dir) orelse return;
        var info_buf: [4300]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "{s}/info/{s}.trashinfo", .{ trash_root, name }) catch return;
        const rr = self.allocator.create(RestoreRead) catch return;
        rr.* = .{
            .req = self.nextReq(),
            .hc = tab.hc,
            .trashed = self.allocator.dupe(u8, trashed) catch {
                self.allocator.destroy(rr);
                return;
            },
            .info = self.allocator.dupe(u8, info) catch {
                self.allocator.free(rr.trashed);
                self.allocator.destroy(rr);
                return;
            },
        };
        self.restore_read = rr;
        self.sendOp(tab.hc, .{ .req = rr.req, .op = "read", .path = rr.info, .off = @as(u64, 0), .len = @as(u64, 8192) });
    }

    fn feedRestore(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
        const rr = self.restore_read orelse return false;
        if (rr.hc != hc) return false;
        switch (ftype) {
            .fs_data => {
                if (payload.len < 12) return false;
                if (std.mem.readInt(u32, payload[0..4], .little) != rr.req) return false;
                rr.buf.appendSlice(self.allocator, payload[12..]) catch {};
                return true;
            },
            .fs_reply => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                    .ignore_unknown_fields = true,
                }) catch return false;
                if (rep.req != rr.req) return false;
                defer {
                    rr.destroy(self.allocator);
                    self.restore_read = null;
                }
                if (!rep.ok) {
                    self.setStatus("cannot read trash metadata");
                    return true;
                }
                // Parse Path= (URL-escaped) from the .trashinfo.
                var orig_buf: [4096]u8 = undefined;
                var orig: ?[]const u8 = null;
                var it = std.mem.tokenizeScalar(u8, rr.buf.items, '\n');
                while (it.next()) |line_raw| {
                    const line = std.mem.trim(u8, line_raw, " \t\r");
                    if (std.mem.startsWith(u8, line, "Path=")) {
                        orig = urlUnescape(line[5..], &orig_buf);
                        break;
                    }
                }
                const dst = orig orelse {
                    self.setStatus("trash metadata has no Path entry");
                    return true;
                };
                var lbl: [128]u8 = undefined;
                const label = std.fmt.bufPrint(&lbl, "restore {s}", .{std.fs.path.basename(dst)}) catch "restore";
                self.startDaemonJobTo(rr.hc, "trash_restore", rr.trashed, dst, rr.info, label);
                return true;
            },
            else => return false,
        }
    }

    // ── undo ────────────────────────────────────────────────────

    const UNDO_CAP = 20;

    fn clearRedo(self: *BrowserView) void {
        for (self.redo_stack.items) |op| op.destroy(self.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    fn pushUndo(self: *BrowserView, op: *UndoOp) void {
        self.clearRedo();
        self.pushHistoryStack(&self.undo_stack, op);
    }

    fn pushHistoryStack(self: *BrowserView, stack: *std.ArrayList(*UndoOp), op: *UndoOp) void {
        stack.append(self.allocator, op) catch {
            op.destroy(self.allocator);
            return;
        };
        while (stack.items.len > UNDO_CAP) {
            const old = stack.orderedRemove(0);
            old.destroy(self.allocator);
        }
    }

    fn makeUndo(
        self: *BrowserView,
        host: ?[]const u8,
        kind: @FieldType(UndoOp, "kind"),
        a: []const u8,
        b: []const u8,
        p: []const u8,
    ) ?*UndoOp {
        const op = self.allocator.create(UndoOp) catch return null;
        const host_owned = if (host) |h| self.allocator.dupe(u8, h) catch { self.allocator.destroy(op); return null; } else null;
        const a_owned = self.allocator.dupe(u8, a) catch { self.allocator.destroy(op); return null; };
        const b_owned: []u8 = if (b.len > 0) self.allocator.dupe(u8, b) catch { self.allocator.free(a_owned); if (host_owned) |h| self.allocator.free(h); self.allocator.destroy(op); return null; } else @constCast(&[_]u8{});
        const p_owned: []u8 = if (p.len > 0) self.allocator.dupe(u8, p) catch { if (b_owned.len > 0) self.allocator.free(b_owned); self.allocator.free(a_owned); if (host_owned) |h| self.allocator.free(h); self.allocator.destroy(op); return null; } else @constCast(&[_]u8{});
        op.* = .{ .host = host_owned, .kind = kind, .a = a_owned, .b = b_owned, .p = p_owned };
        return op;
    }

    /// Register an undo that becomes real when req's reply is ok.
    fn deferUndo(self: *BrowserView, req: u32, op: ?*UndoOp) void {
        const u = op orelse return;
        self.pending_undo.append(self.allocator, .{ .req = req, .op = u }) catch u.destroy(self.allocator);
    }

    fn recordTrashUndo(self: *BrowserView, hc: *HostConn, orig: []const u8, trashed: []const u8, info: []const u8) void {
        if (self.makeUndo(hc.host, .trash_restore, trashed, orig, info)) |op| self.pushUndo(op);
    }

    fn performUndo(self: *BrowserView) void {
        self.beginHistory(.undo);
    }

    fn performRedo(self: *BrowserView) void {
        self.beginHistory(.redo);
    }

    fn beginHistory(self: *BrowserView, direction: HistoryDirection) void {
        if (self.history_busy) {
            self.setStatus("a history operation is still running");
            return;
        }
        const source = if (direction == .undo) &self.undo_stack else &self.redo_stack;
        const op = source.pop() orelse {
            self.setStatus(if (direction == .undo) "nothing to undo" else "nothing to redo");
            return;
        };
        const hc = self.hostConnFor(if (op.host) |h| @as(?[]const u8, h) else null) orelse {
            self.pushHistoryStack(source, op);
            return;
        };
        if (hc.state != .ready) {
            self.setStatus("host not connected; history operation retained");
            self.pushHistoryStack(source, op);
            return;
        }
        self.history_busy = true;
        switch (op.kind) {
            .rename_back => {
                const req = self.nextReq();
                if (!self.deferHistory(req, hc, op, direction)) return;
                self.sendOp(hc, .{ .req = req, .op = "rename", .path = if (direction == .undo) op.a else op.b, .to = if (direction == .undo) op.b else op.a });
            },
            .delete_created => {
                var lbl: [128]u8 = undefined;
                const label = std.fmt.bufPrint(&lbl, "{s} copy {s}", .{ @tagName(direction), std.fs.path.basename(op.a) }) catch "copy history";
                if (direction == .undo)
                    self.startHistoryJob(hc, "delete_tree", op.a, "", "", label, op, direction)
                else if (op.b.len > 0)
                    self.startHistoryJob(hc, "copy", op.b, op.a, "", label, op, direction)
                else
                    self.restoreHistory(op, direction);
            },
            .trash_restore => {
                var lbl: [128]u8 = undefined;
                const label = std.fmt.bufPrint(&lbl, "{s} trash {s}", .{ @tagName(direction), std.fs.path.basename(op.b) }) catch "trash history";
                if (direction == .undo)
                    self.startHistoryJob(hc, "trash_restore", op.a, op.b, op.p, label, op, direction)
                else
                    self.startHistoryJob(hc, "trash", op.b, "", "", label, op, direction);
            },
            .rmdir_created => {
                const req = self.nextReq();
                if (!self.deferHistory(req, hc, op, direction)) return;
                self.sendOp(hc, .{ .req = req, .op = if (direction == .undo) "delete" else "mkdir", .path = op.a });
            },
        }
    }

    fn deferHistory(self: *BrowserView, req: u32, hc: *HostConn, op: *UndoOp, direction: HistoryDirection) bool {
        self.pending_history.append(self.allocator, .{ .req = req, .hc = hc, .op = op, .direction = direction }) catch {
            self.restoreHistory(op, direction);
            return false;
        };
        return true;
    }

    fn finishHistory(self: *BrowserView, op: *UndoOp, direction: HistoryDirection) void {
        self.history_busy = false;
        self.pushHistoryStack(if (direction == .undo) &self.redo_stack else &self.undo_stack, op);
        self.setStatus(if (direction == .undo) "undo complete" else "redo complete");
    }

    fn restoreHistory(self: *BrowserView, op: *UndoOp, direction: HistoryDirection) void {
        self.history_busy = false;
        self.pushHistoryStack(if (direction == .undo) &self.undo_stack else &self.redo_stack, op);
    }

    fn updateTrashResult(self: *BrowserView, op: *UndoOp, trashed: []const u8, info: []const u8) void {
        const a = self.allocator.dupe(u8, trashed) catch return;
        const p = self.allocator.dupe(u8, info) catch { self.allocator.free(a); return; };
        self.allocator.free(op.a);
        if (op.p.len > 0) self.allocator.free(op.p);
        op.a = a;
        op.p = p;
    }

    fn startHistoryJob(self: *BrowserView, hc: *HostConn, op_name: []const u8, path: []const u8, to: []const u8, pattern: []const u8, label: []const u8, op: *UndoOp, direction: HistoryDirection) void {
        const req = self.nextReq();
        const pj = self.allocator.create(PendingJob) catch return self.restoreHistory(op, direction);
        pj.* = .{
            .req = req,
            .hc = hc,
            .label = self.allocator.dupe(u8, label) catch { self.allocator.destroy(pj); return self.restoreHistory(op, direction); },
            .history_op = op,
            .history_direction = direction,
        };
        self.pending_jobs.append(self.allocator, pj) catch {
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
            return self.restoreHistory(op, direction);
        };
        self.sendOp(hc, .{ .req = req, .op = op_name, .path = path, .to = to, .pattern = pattern });
    }

    /// Job start with path+to+pattern (trash_restore shape).
    fn startDaemonJobTo(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, pattern: []const u8, label: []const u8) void {
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
        self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .pattern = pattern });
    }

    // ── archive browsing ────────────────────────────────────────

    /// Open a flat results tab listing an archive's members (host-
    /// side bsdtar; only the member table crosses the wire).
    fn startArchiveBrowse(self: *BrowserView, tab: *BTab, archive: []const u8) void {
        var rbuf: [4096]u8 = undefined;
        const parent = std.fs.path.dirname(archive) orelse "/";
        if (parent.len >= rbuf.len) return;
        @memcpy(rbuf[0..parent.len], parent);
        var hbuf: [256]u8 = undefined;
        var host: ?[]const u8 = null;
        if (tab.hc.host) |h| {
            if (h.len >= hbuf.len) return;
            @memcpy(hbuf[0..h.len], h);
            host = hbuf[0..h.len];
        }
        const rtab = self.newTab(host, rbuf[0..parent.len]) orelse return;
        self.closeViewOf(rtab.hc, rtab.root);
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].tab == rtab) self.dropPending(i) else i += 1;
        }
        rtab.root.flat = true;
        rtab.root.loaded = true;
        rtab.root.view_id = 0;
        rtab.root.archive = self.allocator.dupe(u8, archive) catch &.{};
        var lbl: [96:0]u8 = undefined;
        const l = std.fmt.bufPrintZ(&lbl, "{s}", .{std.fs.path.basename(archive)}) catch "archive";
        c.gtk_label_set_text(rtab.tab_label, l.ptr);
        self.arch_tab = rtab;
        self.startDaemonJobKind(rtab.hc, "archive_list", archive, "", "", "list archive", .archive_list);
    }

    fn onArchiveMember(self: *BrowserView, e: WireJobEv) void {
        const rtab = self.arch_tab orelse return;
        if (e.path.len == 0) return;
        const dir = rtab.root;
        if (dir.find(e.path) != null) return;
        const a = self.allocator;
        const name = a.dupe(u8, e.path) catch return;
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
            .tdir = false,
        }) catch {
            a.free(name);
            a.free(kind);
            a.free(tgt);
            return;
        };
        if (self.currentTab() == rtab) self.renderTab(rtab);
    }

    /// Extract one member on the archive's host, then open it.
    fn extractAndOpenMember(self: *BrowserView, tab: *BTab, member: []const u8) void {
        const archive = tab.root.archive;
        if (archive.len == 0) return;
        const hc = tab.hc;
        if (hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{hc.label()});
            return;
        }
        const req = self.nextReq();
        const pj = self.allocator.create(PendingJob) catch return;
        var lbl: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&lbl, "extract {s}", .{std.fs.path.basename(member)}) catch "extract member";
        pj.* = .{
            .req = req,
            .hc = hc,
            .label = self.allocator.dupe(u8, label) catch {
                self.allocator.destroy(pj);
                return;
            },
            .open_on_done = true,
        };
        self.pending_jobs.append(self.allocator, pj) catch {
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
            return;
        };
        self.sendOp(hc, .{ .req = req, .op = "archive_extract", .path = archive, .pattern = member });
        self.setStatusFmt("extracting {s} on {s}…", .{ member, hc.label() });
    }

    // ── duplicate finder ────────────────────────────────────────

    fn startDupScan(self: *BrowserView, tab: *BTab, root: []const u8) void {
        if (self.dup) |old| {
            old.destroy(self.allocator);
            self.dup = null;
        }
        const d = self.allocator.create(DupState) catch return;
        d.* = .{
            .hc = tab.hc,
            .root = self.allocator.dupe(u8, root) catch {
                self.allocator.destroy(d);
                return;
            },
        };
        self.dup = d;
        self.startDaemonJobKind(tab.hc, "find", d.root, "", "*", "duplicate scan", .dup_scan);
    }

    /// Handle scan matches / completion and hash-confirm results.
    /// Returns true when the event belonged to the dup machinery.
    fn dupConsumeEvent(self: *BrowserView, d: *DupState, e: WireJobEv) bool {
        if (d.scanning and e.job == d.job and d.job != 0) {
            if (std.mem.eql(u8, e.ev, "match")) {
                if (std.mem.eql(u8, e.kind, "file") and e.size > 0) {
                    const gop = d.sizes.getOrPut(self.allocator, e.size) catch return true;
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    const p = self.allocator.dupe(u8, e.path) catch return true;
                    gop.value_ptr.append(self.allocator, p) catch self.allocator.free(p);
                }
                return true;
            }
            if (std.mem.eql(u8, e.ev, "done")) {
                self.dupStartHashPhase(d);
                return false; // let the jobs panel finish its row
            }
            if (std.mem.eql(u8, e.ev, "error") or std.mem.eql(u8, e.ev, "canceled")) {
                d.destroy(self.allocator);
                self.dup = null;
                return false;
            }
            return false;
        }
        // Hash-confirm phase: match done events to our hash jobs.
        if (!d.scanning and std.mem.eql(u8, e.ev, "done") and e.hash.len == 64) {
            for (d.hashes.items) |*h| {
                if (h.job == e.job and h.job != 0 and !h.have) {
                    @memcpy(&h.hash, e.hash[0..64]);
                    h.have = true;
                    self.dupMaybeFinish();
                    return true;
                }
            }
        }
        if (!d.scanning and (std.mem.eql(u8, e.ev, "error") or std.mem.eql(u8, e.ev, "canceled"))) {
            for (d.hashes.items) |*h| {
                if (h.job == e.job and h.job != 0 and !h.have and !h.failed) {
                    h.failed = true;
                    self.dupMaybeFinish();
                    return true;
                }
            }
        }
        return false;
    }

    fn dupStartHashPhase(self: *BrowserView, d: *DupState) void {
        d.scanning = false;
        var hashed: usize = 0;
        var it = d.sizes.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.items.len < 2) continue;
            if (hashed + kv.value_ptr.items.len > DupState.MAX_HASHED) continue;
            for (kv.value_ptr.items) |p| {
                const req = self.nextReq();
                const owned = self.allocator.dupe(u8, p) catch continue;
                d.hashes.append(self.allocator, .{
                    .req = req,
                    .path = owned,
                    .size = kv.key_ptr.*,
                }) catch {
                    self.allocator.free(owned);
                    continue;
                };
                self.sendOp(d.hc, .{ .req = req, .op = "hash", .path = p });
                hashed += 1;
            }
        }
        if (d.hashes.items.len == 0) {
            self.setStatus("no same-size duplicate candidates found");
            d.destroy(self.allocator);
            self.dup = null;
            return;
        }
        self.setStatusFmt("hash-confirming {d} duplicate candidate(s)…", .{d.hashes.items.len});
    }

    fn dupMaybeFinish(self: *BrowserView) void {
        const d = self.dup orelse return;
        if (d.scanning) return;
        for (d.hashes.items) |h| {
            if (h.job == 0) continue; // start reply not yet in
            if (!h.have and !h.failed) return;
        }
        for (d.hashes.items) |h| {
            if (h.job == 0 and !h.failed) return; // still starting
        }
        // Group confirmed digests.
        const H = DupState.DupHash;
        std.mem.sort(H, d.hashes.items, {}, struct {
            fn lt(_: void, a: H, b: H) bool {
                if (a.have != b.have) return a.have;
                return std.mem.lessThan(u8, &a.hash, &b.hash);
            }
        }.lt);
        // Build a flat results tab listing every confirmed group.
        var groups: usize = 0;
        var files: usize = 0;
        var host_buf: [256]u8 = undefined;
        var host: ?[]const u8 = null;
        if (d.hc.host) |h| {
            const n = @min(h.len, host_buf.len);
            @memcpy(host_buf[0..n], h[0..n]);
            host = host_buf[0..n];
        }
        var root_buf: [4096]u8 = undefined;
        const n = @min(d.root.len, root_buf.len);
        @memcpy(root_buf[0..n], d.root[0..n]);
        const rtab = self.newTab(host, root_buf[0..n]) orelse {
            d.destroy(self.allocator);
            self.dup = null;
            return;
        };
        self.closeViewOf(rtab.hc, rtab.root);
        var pi: usize = 0;
        while (pi < self.pending.items.len) {
            if (self.pending.items[pi].tab == rtab) self.dropPending(pi) else pi += 1;
        }
        rtab.root.flat = true;
        rtab.root.loaded = true;
        rtab.root.view_id = 0;

        var i: usize = 0;
        while (i < d.hashes.items.len) {
            const start = i;
            var end = i + 1;
            while (end < d.hashes.items.len and d.hashes.items[start].have and
                d.hashes.items[end].have and
                std.mem.eql(u8, &d.hashes.items[start].hash, &d.hashes.items[end].hash))
            {
                end += 1;
            }
            if (d.hashes.items[start].have and end - start > 1) {
                groups += 1;
                for (d.hashes.items[start..end]) |h| {
                    files += 1;
                    var disp: [640]u8 = undefined;
                    const rel = if (std.mem.startsWith(u8, h.path, d.root) and h.path.len > d.root.len + 1)
                        h.path[d.root.len + 1 ..]
                    else
                        h.path;
                    const display = std.fmt.bufPrint(&disp, "[group {d}] {s}", .{ groups, rel }) catch rel;
                    const a = self.allocator;
                    const nm = a.dupe(u8, display) catch continue;
                    const kd = a.dupe(u8, "file") catch {
                        a.free(nm);
                        continue;
                    };
                    const tg = a.dupe(u8, h.path) catch {
                        a.free(nm);
                        a.free(kd);
                        continue;
                    };
                    rtab.root.entries.append(a, .{
                        .name = nm,
                        .kind = kd,
                        .size = h.size,
                        .mode = 0,
                        .mtime_ms = 0,
                        .target = tg,
                        .tdir = false,
                    }) catch {
                        a.free(nm);
                        a.free(kd);
                        a.free(tg);
                    };
                }
            }
            i = end;
        }
        var lbl: [64:0]u8 = undefined;
        const l = std.fmt.bufPrintZ(&lbl, "duplicates ({d})", .{files}) catch "duplicates";
        c.gtk_label_set_text(rtab.tab_label, l.ptr);
        self.setStatusFmt("duplicates: {d} file(s) in {d} confirmed group(s)", .{ files, groups });
        self.renderTab(rtab);
        d.destroy(self.allocator);
        self.dup = null;
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
        service_token: ?[]u8 = null,
        kind: enum { pause, resume_, cancel, dismiss, move_up, move_down },

        fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
            _ = closure;
            const ctx: *JobBtnCtx = @ptrCast(@alignCast(user.?));
            if (ctx.service_token) |token| ctx.allocator.free(token);
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
        if (ctx.service_token) |token| {
            const service = self.transfer_service orelse return;
            switch (ctx.kind) {
                .move_up => service.moveQueued(token, -1),
                .move_down => service.moveQueued(token, 1),
                .cancel => service.cancel(token),
                else => {},
            }
            self.renderJobs();
            return;
        }
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
                        if (j.undo_op) |u| u.destroy(self.allocator);
                        if (j.undo_trash_orig) |o| self.allocator.free(o);
                        self.allocator.free(j.label);
                        self.allocator.destroy(j);
                        _ = self.jobs.orderedRemove(i);
                        break;
                    }
                }
            },
            .move_up, .move_down => {},
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
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const durable_rows = if (self.transfer_service) |service|
            service.rows(scratch.allocator()) catch &.{}
        else
            &.{};
        const any = self.transfers.items.len > 0 or self.jobs.items.len > 0 or durable_rows.len > 0;
        c.gtk_widget_set_visible(self.jobs_box, if (any) 1 else 0);
        if (!any) return;

        for (durable_rows) |d| {
            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
            c.gtk_widget_set_margin_start(row, 6);
            c.gtk_widget_set_margin_end(row, 6);
            var buf: [256:0]u8 = undefined;
            const txt = std.fmt.bufPrintZ(&buf, "durable: {s} [{s}]", .{ d.label, @tagName(d.state) }) catch "durable transfer";
            const label = c.gtk_label_new(txt.ptr);
            c.gtk_label_set_xalign(@ptrCast(label), 0);
            c.gtk_widget_set_hexpand(label, 1);
            c.gtk_box_append(@ptrCast(row), label);
            if (d.state == .queued or d.state == .waiting_retry) {
                self.jobsButton(row, "go-up-symbolic", .{ .allocator = self.allocator, .view = self, .service_token = self.allocator.dupe(u8, d.token) catch null, .kind = .move_up });
                self.jobsButton(row, "go-down-symbolic", .{ .allocator = self.allocator, .view = self, .service_token = self.allocator.dupe(u8, d.token) catch null, .kind = .move_down });
            }
            self.jobsButton(row, "process-stop-symbolic", .{ .allocator = self.allocator, .view = self, .service_token = self.allocator.dupe(u8, d.token) catch null, .kind = .cancel });
            c.gtk_box_append(@ptrCast(self.jobs_box), row);
        }

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

    // ── async freedesktop thumbnails ────────────────────────────
    //
    // Nothing here ever blocks the GLib loop: local probe/decode/
    // save runs on a worker thread; remote thumbnails ride the
    // nonblocking fs wire (read the HOST's cache, else fetch source
    // bytes, encode on the worker, write the PNG BACK to the host's
    // cache so it is shared with that machine's own apps).

    fn ensureThumbWorker(self: *BrowserView) ?*ThumbCtx {
        if (self.thumb_ctx) |tc| return tc;
        const a = std.heap.c_allocator;
        const cache_root = c.g_get_user_cache_dir();
        const cd = std.mem.span(@as([*:0]const u8, @ptrCast(cache_root)));
        const tc = a.create(ThumbCtx) catch return null;
        tc.* = .{
            .view = self,
            .refs = 2, // worker thread + this view
            .cache_dir = a.dupe(u8, cd) catch {
                a.destroy(tc);
                return null;
            },
        };
        _ = c.pthread_mutex_init(&tc.mutex, null);
        _ = c.pthread_cond_init(&tc.cond, null);
        const th = std.Thread.spawn(.{}, thumbWorkerMain, .{tc}) catch {
            a.free(tc.cache_dir);
            a.destroy(tc);
            return null;
        };
        th.detach();
        self.thumb_ctx = tc;
        return tc;
    }

    fn thumbWorkerMain(tc: *ThumbCtx) void {
        defer tc.unref();
        while (true) {
            tc.lock();
            while (tc.queue.items.len == 0 and !tc.shutdown)
                _ = c.pthread_cond_wait(&tc.cond, &tc.mutex);
            if (tc.shutdown) {
                tc.unlock();
                return;
            }
            var req = tc.queue.orderedRemove(0);
            tc.unlock();
            thumbProcess(tc, &req);
            req.deinitReq();
        }
    }

    /// Worker-side: probe the freedesktop cache, else decode +
    /// save (local) / encode for write-back (remote bytes).
    fn thumbProcess(tc: *ThumbCtx, req: *ThumbReq) void {
        const a = std.heap.c_allocator;
        var pixbuf: ?*c.GdkPixbuf = null;
        var png_out: ?[]u8 = null;

        var ubuf: [4096 * 3 + 8]u8 = undefined;
        const uri = thumbs_mod.fileUri(req.path, &ubuf) orelse return;
        var mstr: [24:0]u8 = undefined;
        const msec = std.fmt.bufPrintZ(&mstr, "{d}", .{@divTrunc(req.mtime_ms, 1000)}) catch return;

        if (req.data == null) {
            // LOCAL: cached thumbnail first (validated by MTime).
            var tp_buf: [4300:0]u8 = undefined;
            const tp = thumbs_mod.thumbPath(tc.cache_dir, req.path, tp_buf[0 .. tp_buf.len - 1]) orelse return;
            tp_buf[tp.len] = 0;
            if (c.gdk_pixbuf_new_from_file(&tp_buf, null)) |cached| {
                const mt = c.gdk_pixbuf_get_option(cached, "tEXt::Thumb::MTime");
                const ur = c.gdk_pixbuf_get_option(cached, "tEXt::Thumb::URI");
                if (mt != null and ur != null and std.mem.eql(u8, std.mem.span(mt), msec) and std.mem.eql(u8, std.mem.span(ur), uri)) {
                    pixbuf = cached;
                } else {
                    c.g_object_unref(cached);
                }
            }
            if (pixbuf == null) {
                var pz: [4300:0]u8 = undefined;
                const pp = std.fmt.bufPrintZ(&pz, "{s}", .{req.path}) catch return;
                pixbuf = c.gdk_pixbuf_new_from_file_at_size(pp.ptr, 128, 128, null);
                if (pixbuf != null) thumbSaveLocal(tc, pixbuf.?, &tp_buf, tp.len, uri, msec);
            }
        } else {
            // Wire-delivered PNG/source bytes: all decode/scale work
            // stays on this worker, never in the fd callback.
            const loader = c.gdk_pixbuf_loader_new();
            var loaded = false;
            if (c.gdk_pixbuf_loader_write(loader, req.data.?.ptr, req.data.?.len, null) != 0)
                loaded = c.gdk_pixbuf_loader_close(loader, null) != 0
            else
                _ = c.gdk_pixbuf_loader_close(loader, null);
            if (loaded) {
                if (c.gdk_pixbuf_loader_get_pixbuf(loader)) |full| {
                    const w: f64 = @floatFromInt(c.gdk_pixbuf_get_width(full));
                    const h: f64 = @floatFromInt(c.gdk_pixbuf_get_height(full));
                    const bound: f64 = if (req.preview_generation != 0) 480.0 else 128.0;
                    const scale = @max(w / bound, h / bound);
                    const nw: c_int = if (scale > 1) @intFromFloat(@max(1.0, w / scale)) else @intFromFloat(w);
                    const nh: c_int = if (scale > 1) @intFromFloat(@max(1.0, h / scale)) else @intFromFloat(h);
                    pixbuf = c.gdk_pixbuf_scale_simple(full, nw, nh, c.GDK_INTERP_BILINEAR);
                }
            }
            c.g_object_unref(loader); // drops `full` with it
            if (pixbuf) |pb| if (!req.cached_png and req.preview_generation == 0) {
                var uz: [4096 * 3 + 8:0]u8 = undefined;
                @memcpy(uz[0..uri.len], uri);
                uz[uri.len] = 0;
                var out_buf: [*c]u8 = null;
                var out_len: usize = 0;
                if (c.gdk_pixbuf_save_to_buffer(pb, &out_buf, &out_len, "png", null, "tEXt::Thumb::URI", &uz, "tEXt::Thumb::MTime", msec.ptr, @as(?*anyopaque, null)) != 0) {
                    png_out = a.dupe(u8, out_buf[0..out_len]) catch null;
                    c.g_free(out_buf);
                }
            };
        }

        // Hand the result to the main thread.
        const key = std.fmt.allocPrint(a, "{s}\x00{d}", .{ req.cache_key, req.mtime_ms }) catch {
            if (pixbuf) |pb| c.g_object_unref(pb);
            if (png_out) |pg| a.free(pg);
            return;
        };
        const res = a.create(ThumbResult) catch {
            a.free(key);
            if (pixbuf) |pb| c.g_object_unref(pb);
            if (png_out) |pg| a.free(pg);
            return;
        };
        res.* = .{
            .ctx = tc,
            .key = key,
            .pixbuf = pixbuf,
            .png = png_out,
            .path = a.dupe(u8, req.path) catch {
                a.free(key);
                a.destroy(res);
                if (pixbuf) |pb| c.g_object_unref(pb);
                if (png_out) |pg| a.free(pg);
                return;
            },
            .mtime_ms = req.mtime_ms,
            .preview_generation = req.preview_generation,
            .remote_id = req.remote_id,
        };
        tc.ref();
        _ = c.g_idle_add(@ptrCast(&onThumbIdle), @ptrCast(res));
    }

    /// Worker-side spec save: dirs 700, temp file in place, PNG with
    /// URI/MTime tEXt chunks, chmod 600, atomic rename.
    fn thumbSaveLocal(tc: *ThumbCtx, pb: *c.GdkPixbuf, tp_buf: *[4300:0]u8, tp_len: usize, uri: []const u8, msec: [:0]const u8) void {
        var dbuf: [4300]u8 = undefined;
        const dir1 = std.fmt.bufPrint(&dbuf, "{s}/thumbnails", .{tc.cache_dir}) catch return;
        var z: [4300:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&z, "{s}", .{dir1})) |d1| {
            _ = c.mkdir(d1.ptr, 0o700);
        } else |_| return;
        if (std.fmt.bufPrintZ(&z, "{s}/normal", .{dir1})) |d2| {
            _ = c.mkdir(d2.ptr, 0o700);
        } else |_| return;
        var tmp: [4320:0]u8 = undefined;
        const tmps = std.fmt.bufPrintZ(&tmp, "{s}.sketerm-tmp-{x}", .{ tp_buf[0..tp_len], @intFromPtr(tc) }) catch return;
        var uz: [4096 * 3 + 8:0]u8 = undefined;
        @memcpy(uz[0..uri.len], uri);
        uz[uri.len] = 0;
        if (c.gdk_pixbuf_save(pb, tmps.ptr, "png", null, "tEXt::Thumb::URI", &uz, "tEXt::Thumb::MTime", msec.ptr, @as(?*anyopaque, null)) == 0) return;
        _ = c.chmod(tmps.ptr, 0o600);
        _ = c.rename(tmps.ptr, tp_buf);
    }

    fn onThumbIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const res: *ThumbResult = @ptrCast(@alignCast(user.?));
        const a = std.heap.c_allocator;
        const tc = res.ctx;
        defer {
            a.free(res.key);
            a.free(res.path);
            if (res.png) |pg| a.free(pg);
            a.destroy(res);
            tc.unref();
        }
        tc.lock();
        const orphaned = tc.orphaned;
        tc.unlock();
        if (orphaned) {
            if (res.pixbuf) |pb| c.g_object_unref(pb);
            return 0;
        }
        const self = tc.view;
        self.applyThumbResult(res);
        return 0;
    }

    fn applyThumbResult(self: *BrowserView, res: *ThumbResult) void {
        if (res.preview_generation != 0) {
            defer if (res.pixbuf) |pb| c.g_object_unref(pb);
            if (res.preview_generation == self.preview_generation) {
                if (res.pixbuf) |pb| {
                    const tex = c.gdk_texture_new_for_pixbuf(pb);
                    if (tex) |t| {
                        c.gtk_picture_set_paintable(@ptrCast(self.preview_pic), @ptrCast(t));
                        c.g_object_unref(@as(?*anyopaque, @ptrCast(t)));
                    }
                } else {
                    c.gtk_label_set_text(self.preview_text, "(cannot decode preview image)");
                }
            }
            return;
        }
        if (res.pixbuf) |pb| {
            defer c.g_object_unref(pb);
            const tex = c.gdk_texture_new_for_pixbuf(pb) orelse return;
            if (self.thumbs.count() >= THUMB_CACHE_CAP) self.clearThumbCache();
            const owned = self.allocator.dupe(u8, res.key) catch {
                c.g_object_unref(@as(?*anyopaque, @ptrCast(tex)));
                return;
            };
            self.thumbs.put(owned, tex) catch {
                self.allocator.free(owned);
                c.g_object_unref(@as(?*anyopaque, @ptrCast(tex)));
                return;
            };
            // Remote result: write the PNG back into the OWNING
            // host's cache (best-effort, req 0 = replies ignored).
            if (res.png) |png| self.thumbWriteBack(res.remote_id, res.path, png);
            self.scheduleThumbRender();
        } else {
            if (self.thumb_failed.count() >= THUMB_CACHE_CAP) {
                var it = self.thumb_failed.iterator();
                while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
                self.thumb_failed.clearRetainingCapacity();
            }
            const owned = self.allocator.dupe(u8, res.key) catch return;
            self.thumb_failed.put(owned, {}) catch self.allocator.free(owned);
        }
        // A remote decode holds the pipeline slot until now.
        self.releaseRemoteThumbFor(res.remote_id);
    }

    /// Push a generated thumbnail PNG into the owning host's
    /// freedesktop cache over the fs wire (mkdirs + write + rename;
    /// all best-effort with ignored replies).
    fn thumbWriteBack(self: *BrowserView, remote_id: u64, path: []const u8, png: []const u8) void {
        // The path's host is the CURRENT remote pipeline's host.
        const rt = self.remote_thumb orelse return;
        if (remote_id == 0 or rt.id != remote_id or !std.mem.eql(u8, rt.path, path)) return;
        const hc = rt.hc;
        if (hc.state != .ready) return;
        const cache = hc.cache_dir orelse return;
        var tbuf: [4300]u8 = undefined;
        const tp = thumbs_mod.thumbPath(cache, path, &tbuf) orelse return;
        var dbuf: [4300]u8 = undefined;
        if (std.fmt.bufPrint(&dbuf, "{s}/thumbnails", .{cache})) |d| {
            self.sendOp(hc, .{ .req = @as(u32, 0), .op = "mkdir", .path = d });
        } else |_| {}
        if (std.fmt.bufPrint(&dbuf, "{s}/thumbnails/normal", .{cache})) |d| {
            self.sendOp(hc, .{ .req = @as(u32, 0), .op = "mkdir", .path = d });
        } else |_| {}
        var tmpb: [4340]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmpb, "{s}.sketerm-tmp", .{tp}) catch return;
        // fs_write frame: [u32 req][u64 off][u8 flags][u16 len][path][data]
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var hdr: [15]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 0, .little);
        std.mem.writeInt(u64, hdr[4..12], 0, .little);
        hdr[12] = 0b011; // create + truncate
        std.mem.writeInt(u16, hdr[13..15], @intCast(tmp.len), .little);
        payload.appendSlice(self.allocator, &hdr) catch return;
        payload.appendSlice(self.allocator, tmp) catch return;
        payload.appendSlice(self.allocator, png) catch return;
        hc.conn.sendFrame(.fs_write, payload.items) catch return;
        self.sendOp(hc, .{ .req = @as(u32, 0), .op = "rename", .path = tmp, .to = tp });
    }

    /// Coalesced re-render ~8x/s while thumbnails trickle in.
    fn scheduleThumbRender(self: *BrowserView) void {
        if (self.thumb_render_src != 0) return;
        self.thumb_render_src = c.g_timeout_add(120, @ptrCast(&onThumbRenderTick), @ptrCast(self));
    }

    fn onThumbRenderTick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.thumb_render_src = 0;
        self.renderCurrent();
        return 0; // one-shot
    }

    /// The render-time lookup: cached texture, or a queued async
    /// request (local worker / remote pipeline) and null for now.
    fn thumbLookup(self: *BrowserView, hc: *HostConn, full: []const u8, e: Entry) ?*c.GdkTexture {
        if (!std.mem.eql(u8, e.kind, "file") or !isPreviewMediaName(e.name)) return null;
        if (isImageName(e.name) and e.size > THUMB_FILE_CAP) return null;
        var identity_buf: [4600]u8 = undefined;
        const identity = if (hc.host) |host|
            std.fmt.bufPrint(&identity_buf, "{s}:{s}", .{ host, full }) catch return null
        else
            full;
        var key_buf: [4700]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{d}", .{ identity, e.mtime_ms }) catch return null;
        if (self.thumbs.get(key)) |t| return t;
        if (self.thumb_failed.contains(key)) return null;
        if (hc.host == null and isWorkerImageName(e.name)) {
            const tc = self.ensureThumbWorker() orelse return null;
            const a = std.heap.c_allocator;
            tc.lock();
            defer tc.unlock();
            for (tc.queue.items) |q| {
                if (std.mem.eql(u8, q.path, full)) return null; // queued
            }
            if (tc.queue.items.len > 512) return null; // bounded
            const owned = a.dupe(u8, full) catch return null;
            const cache_key = a.dupe(u8, full) catch { a.free(owned); return null; };
            tc.queue.append(a, .{ .path = owned, .cache_key = cache_key, .mtime_ms = e.mtime_ms }) catch {
                a.free(owned);
                a.free(cache_key);
                return null;
            };
            _ = c.pthread_cond_signal(&tc.cond);
        } else {
            self.enqueueRemoteThumb(hc, full, e.mtime_ms);
        }
        return null;
    }

    // ── remote thumbnail pipeline (serial per view) ─────────────

    fn enqueueRemoteThumb(self: *BrowserView, hc: *HostConn, path: []const u8, mtime_ms: i64) void {
        if (self.remote_thumb) |rt| {
            if (rt.hc == hc and std.mem.eql(u8, rt.path, path)) return;
        }
        for (self.remote_thumb_queue.items) |rt| {
            if (rt.hc == hc and std.mem.eql(u8, rt.path, path)) return;
        }
        if (self.remote_thumb_queue.items.len > 128) return;
        const rt = self.allocator.create(RemoteThumb) catch return;
        const id = self.next_remote_thumb_id;
        self.next_remote_thumb_id +%= 1;
        if (self.next_remote_thumb_id == 0) self.next_remote_thumb_id = 1;
        rt.* = .{
            .id = id,
            .hc = hc,
            .path = self.allocator.dupe(u8, path) catch {
                self.allocator.destroy(rt);
                return;
            },
            .mtime_ms = mtime_ms,
        };
        self.remote_thumb_queue.append(self.allocator, rt) catch {
            rt.destroy(self.allocator);
            return;
        };
        self.pumpRemoteThumbs();
    }

    fn pumpRemoteThumbs(self: *BrowserView) void {
        if (self.remote_thumb != null) return;
        while (self.remote_thumb_queue.items.len > 0) {
            const rt = self.remote_thumb_queue.orderedRemove(0);
            if (rt.hc.state != .ready) {
                rt.destroy(self.allocator);
                continue;
            }
            rt.req = self.nextReq();
            rt.phase = .start_job;
            self.remote_thumb = rt;
            // Generation happens on the file-owning host. Only the
            // bounded cached PNG returns over the wire.
            self.sendOp(rt.hc, .{ .req = rt.req, .op = "thumbnail", .path = rt.path });
            return;
        }
    }

    fn finishRemoteThumb(self: *BrowserView) void {
        if (self.remote_thumb) |rt| {
            rt.destroy(self.allocator);
            self.remote_thumb = null;
        }
        self.pumpRemoteThumbs();
    }

    /// Feed frames into the remote-thumbnail pipeline.
    fn feedRemoteThumb(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
        const rt = self.remote_thumb orelse return false;
        if (rt.hc != hc) return false;
        switch (ftype) {
            .fs_data => {
                if (payload.len < 12) return false;
                if (std.mem.readInt(u32, payload[0..4], .little) != rt.req) return false;
                rt.buf.appendSlice(self.allocator, payload[12..]) catch {};
                return true;
            },
            .fs_reply => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                    .ignore_unknown_fields = true,
                }) catch return false;
                if (rep.req != rt.req) return false;
                switch (rt.phase) {
                    .start_job => {
                        if (!rep.ok or rep.job == 0) {
                            self.markThumbFailed(rt.hc, rt.path, rt.mtime_ms);
                            self.finishRemoteThumb();
                            return true;
                        }
                        rt.job = rep.job;
                        rt.phase = .wait_job;
                        return true;
                    },
                    .read_thumb => {
                        if (!rep.ok or rt.buf.items.len == 0) {
                            self.markThumbFailed(rt.hc, rt.path, rt.mtime_ms);
                            self.finishRemoteThumb();
                            return true;
                        }
                        self.queueRemoteDecode(rt, true, 0);
                        self.finishRemoteThumbKeepCurrent();
                        return true;
                    },
                    .wait_job => return false,
                }
            },
            .fs_job => {
                if (rt.phase != .wait_job) return false;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{ .ignore_unknown_fields = true }) catch return false;
                if (ev.job != rt.job) return false;
                if (std.mem.eql(u8, ev.ev, "done") and ev.path.len > 0) {
                    rt.req = self.nextReq();
                    rt.phase = .read_thumb;
                    rt.buf.clearRetainingCapacity();
                    self.sendOp(rt.hc, .{ .req = rt.req, .op = "read", .path = ev.path, .off = @as(u64, 0), .len = @as(u64, 2 << 20) });
                } else if (std.mem.eql(u8, ev.ev, "error") or std.mem.eql(u8, ev.ev, "canceled")) {
                    self.markThumbFailed(rt.hc, rt.path, rt.mtime_ms);
                    self.finishRemoteThumb();
                }
                return true;
            },
            else => return false,
        }
    }

    /// Source bytes arrived: hand them to the worker for decode +
    /// spec-PNG encode (write-back happens when the result lands).
    fn queueRemoteDecode(self: *BrowserView, rt: *RemoteThumb, cached_png: bool, preview_generation: u64) void {
        const tc = self.ensureThumbWorker() orelse return;
        const a = std.heap.c_allocator;
        const path = a.dupe(u8, rt.path) catch return;
        const key = if (rt.hc.host) |host|
            std.fmt.allocPrint(a, "{s}:{s}", .{ host, rt.path }) catch { a.free(path); return; }
        else
            a.dupe(u8, rt.path) catch { a.free(path); return; };
        const data = a.dupe(u8, rt.buf.items) catch {
            a.free(path);
            a.free(key);
            return;
        };
        tc.lock();
        defer tc.unlock();
        tc.queue.append(a, .{ .path = path, .cache_key = key, .mtime_ms = rt.mtime_ms, .data = data, .cached_png = cached_png, .preview_generation = preview_generation, .remote_id = rt.id }) catch {
            a.free(path);
            a.free(key);
            a.free(data);
            return;
        };
        _ = c.pthread_cond_signal(&tc.cond);
    }

    /// Advance the queue but KEEP self.remote_thumb until the worker
    /// result lands (thumbWriteBack needs its host + path).
    fn finishRemoteThumbKeepCurrent(self: *BrowserView) void {
        // The worker handback frees it via releaseRemoteThumbFor.
        _ = self;
    }

    fn releaseRemoteThumbFor(self: *BrowserView, remote_id: u64) void {
        if (remote_id == 0) return;
        if (self.remote_thumb) |rt| {
            if (rt.id == remote_id) {
                rt.destroy(self.allocator);
                self.remote_thumb = null;
                self.pumpRemoteThumbs();
            }
        }
    }

    fn markThumbFailed(self: *BrowserView, hc: *HostConn, path: []const u8, mtime_ms: i64) void {
        var identity_buf: [4600]u8 = undefined;
        const identity = if (hc.host) |host|
            std.fmt.bufPrint(&identity_buf, "{s}:{s}", .{ host, path }) catch return
        else
            path;
        var key_buf: [4300]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{d}", .{ identity, mtime_ms }) catch return;
        const owned = self.allocator.dupe(u8, key) catch return;
        self.thumb_failed.put(owned, {}) catch self.allocator.free(owned);
    }

    // ── preview pane + thumbnails ───────────────────────────────

    fn clearThumbCache(self: *BrowserView) void {
        var it = self.thumbs.iterator();
        while (it.next()) |kv| {
            c.g_object_unref(@ptrCast(kv.value_ptr.*));
            self.allocator.free(kv.key_ptr.*);
        }
        self.thumbs.clearRetainingCapacity();
    }

    fn clearPreviewContent(self: *BrowserView) void {
        c.gtk_picture_set_paintable(@ptrCast(self.preview_pic), null);
        c.gtk_label_set_text(self.preview_text, "");
    }

    fn abandonPreviewRead(self: *BrowserView) void {
        if (self.preview_read) |pr| {
            if (pr.phase == .wait_job and pr.job != 0 and pr.hc.state == .ready) {
                // req 0 = fire-and-forget: the helper is ephemeral and
                // may already have finished and been reaped, and that
                // "no such job" reply is not a user-facing failure.
                self.sendOp(pr.hc, .{ .req = @as(u32, 0), .op = "job_cancel", .job = pr.job });
            }
            pr.destroy(self.allocator);
            self.preview_read = null;
        }
    }

    /// Refresh the preview panel from the current tab's selection.
    fn updatePreview(self: *BrowserView) void {
        if (!self.preview_on) return;
        self.preview_generation +%= 1;
        if (self.preview_generation == 0) self.preview_generation = 1;
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
        self.previewRemoteStart(tab, path);
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

    fn previewRemoteStart(self: *BrowserView, tab: *BTab, path: []const u8) void {
        if (tab.hc.state != .ready) return;
        const pr = self.allocator.create(PreviewRead) catch return;
        pr.* = .{
            .req = self.nextReq(),
            .hc = tab.hc,
            .path = self.allocator.dupe(u8, path) catch {
                self.allocator.destroy(pr);
                return;
            },
            .generation = self.preview_generation,
        };
        self.preview_read = pr;
        c.gtk_label_set_text(self.preview_text, "loading…");
        self.sendOp(tab.hc, .{ .req = pr.req, .op = "preview", .path = pr.path });
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
                if (pr.phase == .start_job) {
                    if (!rep.ok or rep.job == 0) {
                        c.gtk_label_set_text(self.preview_text, "(preview unavailable)");
                        self.abandonPreviewRead();
                    } else {
                        pr.job = rep.job;
                        pr.phase = .wait_job;
                    }
                    return true;
                }
                if (pr.phase != .read_asset) return false;
                if (!rep.ok or pr.buf.items.len == 0) {
                    c.gtk_label_set_text(self.preview_text, "(cannot read generated preview)");
                    self.abandonPreviewRead();
                    return true;
                }
                self.queuePreviewDecode(pr);
                self.abandonPreviewRead();
                return true;
            },
            .fs_job => {
                if (pr.phase != .wait_job) return false;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{ .ignore_unknown_fields = true }) catch return false;
                if (ev.job != pr.job) return false;
                if (std.mem.eql(u8, ev.ev, "done")) {
                    if (ev.text.len > 0)
                        self.showTextPreview(ev.text)
                    else
                        // Drop the "loading…" placeholder; a rendered
                        // image must not sit under stale status text.
                        c.gtk_label_set_text(self.preview_text, "");
                    if (ev.path.len == 0) {
                        self.abandonPreviewRead();
                    } else {
                        pr.phase = .read_asset;
                        pr.req = self.nextReq();
                        pr.buf.clearRetainingCapacity();
                        self.sendOp(pr.hc, .{ .req = pr.req, .op = "read", .path = ev.path, .off = @as(u64, 0), .len = @as(u64, 2 << 20) });
                    }
                } else if (std.mem.eql(u8, ev.ev, "error") or std.mem.eql(u8, ev.ev, "canceled")) {
                    self.showTextPreview(if (ev.message.len > 0) ev.message else "(preview unavailable)");
                    self.abandonPreviewRead();
                }
                return true;
            },
            else => return false,
        }
    }

    fn queuePreviewDecode(self: *BrowserView, pr: *PreviewRead) void {
        const tc = self.ensureThumbWorker() orelse return;
        const a = std.heap.c_allocator;
        const path = a.dupe(u8, pr.path) catch return;
        const key = a.dupe(u8, pr.path) catch { a.free(path); return; };
        const data = a.dupe(u8, pr.buf.items) catch { a.free(path); a.free(key); return; };
        tc.lock();
        defer tc.unlock();
        tc.queue.append(a, .{
            .path = path,
            .cache_key = key,
            .mtime_ms = 0,
            .data = data,
            .cached_png = true,
            .preview_generation = pr.generation,
        }) catch {
            a.free(path);
            a.free(key);
            a.free(data);
            return;
        };
        _ = c.pthread_cond_signal(&tc.cond);
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
        c.gtk_widget_set_sensitive(back, 0);
        _ = c.g_signal_connect_data(back, "clicked", @ptrCast(&onBackClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), back);
        const fwd = c.gtk_button_new_from_icon_name("go-next-symbolic");
        c.gtk_widget_set_sensitive(fwd, 0);
        _ = c.g_signal_connect_data(fwd, "clicked", @ptrCast(&onFwdClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), fwd);
        const up = c.gtk_button_new_from_icon_name("go-up-symbolic");
        _ = c.g_signal_connect_data(up, "clicked", @ptrCast(&onUpClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), up);

        const entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(entry, 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "/path — or host:/path, user@host:/path, udp:host:/path, local:/path");
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onPathActivate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(entry, "changed", @ptrCast(&onPathChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        const entry_keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(entry_keys), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(entry_keys, "key-pressed", @ptrCast(&onPathKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(entry, @ptrCast(entry_keys));
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

        const places_toggle = c.gtk_toggle_button_new();
        c.gtk_button_set_icon_name(@ptrCast(places_toggle), "user-bookmarks-symbolic");
        c.gtk_widget_set_tooltip_text(places_toggle, "Places sidebar (bookmarks, recent, devices)");
        _ = c.g_signal_connect_data(places_toggle, "toggled", @ptrCast(&onPlacesToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), places_toggle);

        const viewmode = c.gtk_button_new_from_icon_name("view-grid-symbolic");
        c.gtk_widget_set_tooltip_text(viewmode, "Cycle view: details / compact / grid / columns");
        _ = c.g_signal_connect_data(viewmode, "clicked", @ptrCast(&onViewModeClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), viewmode);

        const preview_toggle = c.gtk_toggle_button_new();
        c.gtk_button_set_icon_name(@ptrCast(preview_toggle), "view-dual-symbolic");
        c.gtk_widget_set_tooltip_text(preview_toggle, "Preview panel (images, text head, metadata)");
        _ = c.g_signal_connect_data(preview_toggle, "toggled", @ptrCast(&onPreviewToggled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), preview_toggle);

        const newtab = c.gtk_button_new_from_icon_name("tab-new-symbolic");
        c.gtk_widget_set_tooltip_text(newtab, "New browser tab");
        _ = c.g_signal_connect_data(newtab, "clicked", @ptrCast(&onNewTabClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), newtab);

        const cwdbtn = c.gtk_button_new_from_icon_name("go-jump-symbolic");
        c.gtk_widget_set_tooltip_text(cwdbtn, "Go to the shell's current directory (OSC 7)");
        _ = c.g_signal_connect_data(cwdbtn, "clicked", @ptrCast(&onCwdSyncClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(bar), cwdbtn);

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
        const ssave = c.gtk_button_new_from_icon_name("starred-symbolic");
        c.gtk_widget_set_tooltip_text(ssave, "Save the last search (shows in the Places sidebar)");
        _ = c.g_signal_connect_data(ssave, "clicked", @ptrCast(&onSaveSearchClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(sbar), ssave);
        c.gtk_widget_set_visible(sbar, 0);
        c.gtk_box_append(@ptrCast(vbox), sbar);

        const notebook = c.gtk_notebook_new();
        c.gtk_notebook_set_scrollable(@ptrCast(notebook), 1);
        c.gtk_widget_set_hexpand(notebook, 1);
        c.gtk_widget_set_vexpand(notebook, 1);
        _ = c.g_signal_connect_data(notebook, "switch-page", @ptrCast(&onSwitchPage), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        // Content row: places | notebook | preview (side panels
        // hidden until toggled).
        const content = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_hexpand(content, 1);
        c.gtk_widget_set_vexpand(content, 1);

        const pl_scroll = c.gtk_scrolled_window_new();
        c.gtk_widget_set_size_request(pl_scroll, 190, -1);
        const pl_list = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(pl_list), c.GTK_SELECTION_NONE);
        c.gtk_list_box_set_activate_on_single_click(@ptrCast(pl_list), 1);
        _ = c.g_signal_connect_data(pl_list, "row-activated", @ptrCast(&onPlaceActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_scrolled_window_set_child(@ptrCast(pl_scroll), pl_list);
        c.gtk_widget_set_visible(pl_scroll, 0);
        c.gtk_box_append(@ptrCast(content), pl_scroll);

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
        self.back_button = back;
        self.fwd_button = fwd;
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
        self.places_scroller = pl_scroll;
        self.places_list = @ptrCast(@alignCast(pl_list));
    }

    // ── places sidebar ──────────────────────────────────────────

    /// Heap ctx on each places row (freed with the row).
    const PlaceCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        /// Host-qualified location spec; empty = section header.
        spec: []u8,
        is_bookmark: bool,

        fn free(user: ?*anyopaque) callconv(.c) void {
            const p: *PlaceCtx = @ptrCast(@alignCast(user.?));
            p.allocator.free(p.spec);
            p.allocator.destroy(p);
        }
    };

    fn onPlacesToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.places_on = c.gtk_toggle_button_get_active(btn) != 0;
        c.gtk_widget_set_visible(self.places_scroller, @intFromBool(self.places_on));
        if (self.places_on) self.renderPlaces();
    }

    fn placeHeader(self: *BrowserView, text: [*:0]const u8) void {
        const lab = c.gtk_label_new(text);
        c.gtk_label_set_xalign(@ptrCast(lab), 0);
        c.gtk_widget_add_css_class(lab, "dim-label");
        c.gtk_widget_set_margin_top(lab, 8);
        c.gtk_widget_set_margin_start(lab, 6);
        const row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
        c.gtk_list_box_row_set_child(@ptrCast(row), lab);
        c.gtk_list_box_append(self.places_list, row);
    }

    fn placeRow(self: *BrowserView, icon: [*:0]const u8, label: []const u8, spec: []const u8, is_bookmark: bool) void {
        const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_margin_start(hbox, 10);
        const img = c.gtk_image_new_from_icon_name(icon);
        c.gtk_box_append(@ptrCast(hbox), img);
        var lz: [256:0]u8 = undefined;
        const n = @min(label.len, lz.len - 1);
        @memcpy(lz[0..n], label[0..n]);
        lz[n] = 0;
        const lab = c.gtk_label_new(&lz);
        c.gtk_label_set_xalign(@ptrCast(lab), 0);
        c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_widget_set_hexpand(lab, 1);
        c.gtk_box_append(@ptrCast(hbox), lab);
        const ctx = self.allocator.create(PlaceCtx) catch return;
        ctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .spec = self.allocator.dupe(u8, spec) catch {
                self.allocator.destroy(ctx);
                return;
            },
            .is_bookmark = is_bookmark,
        };
        if (is_bookmark) {
            const rm = c.gtk_button_new_from_icon_name("window-close-symbolic");
            c.gtk_button_set_has_frame(@ptrCast(rm), 0);
            c.gtk_widget_set_tooltip_text(rm, "Remove bookmark");
            _ = c.g_signal_connect_data(rm, "clicked", @ptrCast(&onBookmarkRemove), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(hbox), rm);
        }
        const row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(row), hbox);
        c.g_object_set_data_full(@ptrCast(row), "sketerm-place", @ptrCast(ctx), @ptrCast(&PlaceCtx.free));
        c.gtk_list_box_append(self.places_list, row);
    }

    fn renderPlaces(self: *BrowserView) void {
        while (c.gtk_list_box_get_row_at_index(self.places_list, 0)) |row| {
            c.gtk_list_box_remove(self.places_list, @ptrCast(row));
        }
        self.placeHeader("Places");
        const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/";
        self.placeRow("user-home-symbolic", "Home", home, false);
        self.placeRow("drive-harddisk-symbolic", "File System", "local:/", false);
        var trash_buf: [4200]u8 = undefined;
        if (trashFilesDir(&trash_buf)) |td| self.placeRow("user-trash-symbolic", "Trash", td, false);
        if (self.collection_items.items.len > 0)
            self.placeRow("folder-saved-search-symbolic", "Collection", "collection:", false);
        if (self.bookmarks.items.len > 0) {
            self.placeHeader("Bookmarks");
            for (self.bookmarks.items) |b| {
                self.placeRow("starred-symbolic", std.fs.path.basename(b), b, true);
            }
        }
        if (self.saved_searches.items.len > 0) {
            self.placeHeader("Saved Searches");
            for (self.saved_searches.items, 0..) |sq, i| {
                var lbl: [300]u8 = undefined;
                const ltxt = std.fmt.bufPrint(&lbl, "{s}{s} in {s}", .{
                    sq.pattern,
                    if (sq.content) " (content)" else "",
                    sq.spec,
                }) catch sq.pattern;
                // Encode the index as "search:<i>" — rows resolve it
                // at click time so edits do not dangle.
                var spec_buf: [32]u8 = undefined;
                const sspec = std.fmt.bufPrint(&spec_buf, "search:{d}", .{i}) catch continue;
                self.placeRow("system-search-symbolic", ltxt, sspec, true);
            }
        }
        if (self.recent.items.len > 0) {
            self.placeHeader("Recent");
            for (self.recent.items) |r| {
                self.placeRow("document-open-recent-symbolic", r, r, false);
            }
        }
        // Devices: real block-device and network mounts.
        const f = c.fopen("/proc/mounts", "rb") orelse {
            return;
        };
        var buf: [32 * 1024]u8 = undefined;
        const nread = c.fread(&buf, 1, buf.len, f);
        _ = c.fclose(f);
        var shown: usize = 0;
        var first_dev = true;
        var it = std.mem.tokenizeScalar(u8, buf[0..nread], '\n');
        while (it.next()) |line| {
            if (shown >= 12) break;
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const src = fields.next() orelse continue;
            const mp = fields.next() orelse continue;
            const fstype = fields.next() orelse continue;
            const interesting = std.mem.startsWith(u8, src, "/dev/") or
                std.mem.startsWith(u8, fstype, "nfs") or
                std.mem.eql(u8, fstype, "fuse.sshfs");
            if (!interesting) continue;
            if (first_dev) {
                self.placeHeader("Devices");
                first_dev = false;
            }
            // /proc/mounts octal-escapes spaces; show raw (rare).
            self.placeRow("drive-harddisk-symbolic", mp, mp, false);
            shown += 1;
        }
    }

    fn onPlaceActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const data = c.g_object_get_data(@ptrCast(row), "sketerm-place") orelse return;
        const ctx: *PlaceCtx = @ptrCast(@alignCast(data));
        if (ctx.spec.len == 0) return;
        if (std.mem.startsWith(u8, ctx.spec, "search:")) {
            const idx = std.fmt.parseInt(usize, ctx.spec[7..], 10) catch return;
            self.runSavedSearch(idx);
            return;
        }
        if (std.mem.eql(u8, ctx.spec, "collection:")) {
            const t = self.ensureCollectionTab(null, "/") orelse return;
            const pn = c.gtk_notebook_page_num(self.notebook, t.page);
            if (pn >= 0) c.gtk_notebook_set_current_page(self.notebook, pn);
            self.renderTab(t);
            return;
        }
        const tab = self.currentTab() orelse {
            _ = self.newTabSpec(ctx.spec);
            return;
        };
        var buf: [4300]u8 = undefined;
        if (ctx.spec.len >= buf.len) return;
        @memcpy(buf[0..ctx.spec.len], ctx.spec);
        self.navigateSpec(tab, buf[0..ctx.spec.len]);
    }

    /// Re-run a saved search: navigate its root, refill the search
    /// bar, and fire.
    fn runSavedSearch(self: *BrowserView, idx: usize) void {
        if (idx >= self.saved_searches.items.len) return;
        const sq = self.saved_searches.items[idx];
        const tab = self.currentTab() orelse (self.newTabSpec(sq.spec) orelse return);
        var buf: [4300]u8 = undefined;
        if (sq.spec.len >= buf.len) return;
        @memcpy(buf[0..sq.spec.len], sq.spec);
        self.navigateSpec(tab, buf[0..sq.spec.len]);
        var pz: [512:0]u8 = undefined;
        const pat = std.fmt.bufPrintZ(&pz, "{s}", .{sq.pattern}) catch return;
        c.gtk_editable_set_text(@ptrCast(self.search_entry), pat.ptr);
        c.gtk_check_button_set_active(@ptrCast(self.search_content), @intFromBool(sq.content));
        c.gtk_widget_set_visible(self.search_bar, 1);
        self.startSearch();
    }

    fn onSaveSearchClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const ls = self.last_search orelse {
            self.setStatus("run a search first, then save it");
            return;
        };
        for (self.saved_searches.items) |sq| {
            if (std.mem.eql(u8, sq.spec, ls.spec) and std.mem.eql(u8, sq.pattern, ls.pattern) and sq.content == ls.content) {
                self.setStatus("search already saved");
                return;
            }
        }
        const spec = self.allocator.dupe(u8, ls.spec) catch return;
        const pat = self.allocator.dupe(u8, ls.pattern) catch {
            self.allocator.free(spec);
            return;
        };
        self.saved_searches.append(self.allocator, .{ .spec = spec, .pattern = pat, .content = ls.content }) catch {
            self.allocator.free(spec);
            self.allocator.free(pat);
            return;
        };
        self.savePlaces();
        if (self.places_on) self.renderPlaces();
        self.setStatusFmt("saved search: {s}", .{ls.pattern});
    }

    fn onBookmarkRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PlaceCtx = @ptrCast(@alignCast(user.?));
        const self = ctx.view;
        if (std.mem.startsWith(u8, ctx.spec, "search:")) {
            const idx = std.fmt.parseInt(usize, ctx.spec[7..], 10) catch return;
            if (idx < self.saved_searches.items.len) {
                self.saved_searches.items[idx].deinitOwned(self.allocator);
                _ = self.saved_searches.orderedRemove(idx);
            }
        } else {
            var i: usize = 0;
            while (i < self.bookmarks.items.len) {
                if (std.mem.eql(u8, self.bookmarks.items[i], ctx.spec)) {
                    self.allocator.free(self.bookmarks.items[i]);
                    _ = self.bookmarks.orderedRemove(i);
                } else i += 1;
            }
        }
        self.savePlaces();
        self.renderPlaces();
    }

    fn savePlaces(self: *BrowserView) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const bm = a.alloc([]const u8, self.bookmarks.items.len) catch return;
        for (self.bookmarks.items, 0..) |b, i| bm[i] = b;
        const rc = a.alloc([]const u8, self.recent.items.len) catch return;
        for (self.recent.items, 0..) |r, i| rc[i] = r;
        const sq = a.alloc(places_mod.SavedSearch, self.saved_searches.items.len) catch return;
        for (self.saved_searches.items, 0..) |sv, i| {
            sq[i] = .{ .spec = sv.spec, .pattern = sv.pattern, .content = sv.content };
        }
        const cl = a.alloc(places_mod.CollItem, self.collection_items.items.len) catch return;
        for (self.collection_items.items, 0..) |ci, i| {
            cl[i] = .{ .spec = ci.spec, .dir = ci.dir };
        }
        places_mod.save(self.allocator, .{ .bookmarks = bm, .recent = rc, .searches = sq, .collection = cl });
    }

    fn addBookmark(self: *BrowserView, spec: []const u8) void {
        for (self.bookmarks.items) |b| {
            if (std.mem.eql(u8, b, spec)) return;
        }
        const owned = self.allocator.dupe(u8, spec) catch return;
        self.bookmarks.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return;
        };
        self.savePlaces();
        if (self.places_on) self.renderPlaces();
        self.setStatusFmt("bookmarked: {s}", .{spec});
    }

    fn recordRecentSpec(self: *BrowserView, spec: []const u8) void {
        places_mod.recordRecent(self.allocator, &self.recent, spec, places_mod.RECENT_CAP);
        self.savePlaces();
        if (self.places_on) self.renderPlaces();
    }

    fn onBrowserKey(
        _: *c.GtkEventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const lower_pre: c_uint = c.gdk_keyval_to_lower(keyval);
        const mods = state & input.SIGNIFICANT_MODS;
        if (mods == c.GDK_CONTROL_MASK and lower_pre == c.GDK_KEY_z) {
            self.performUndo();
            return 1;
        }
        if (mods == (c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK) and lower_pre == c.GDK_KEY_z) {
            self.performRedo();
            return 1;
        }
        if (mods == c.GDK_CONTROL_MASK and lower_pre == c.GDK_KEY_l) {
            _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(self.path_entry)));
            c.gtk_editable_select_region(@ptrCast(self.path_entry), 0, -1);
            return 1;
        }
        if (mods == c.GDK_CONTROL_MASK and lower_pre == c.GDK_KEY_s) {
            self.showSelectPattern();
            return 1;
        }
        if (mods == c.GDK_CONTROL_MASK and lower_pre == c.GDK_KEY_a) {
            self.selectPattern("*", false);
            return 1;
        }
        if (mods == c.GDK_CONTROL_MASK and lower_pre == c.GDK_KEY_i) {
            self.selectPattern("*", true);
            return 1;
        }
        if (mods == c.GDK_ALT_MASK) {
            const tab = self.currentTab() orelse return 0;
            if (keyval == c.GDK_KEY_Left) { self.goBack(tab); return 1; }
            if (keyval == c.GDK_KEY_Right) { self.goForward(tab); return 1; }
            if (keyval == c.GDK_KEY_Up) { self.goUp(tab); return 1; }
        }
        // Orthodox dual-pane verbs: the other browser pane in this tab
        // is the implicit destination.
        if (mods == 0 and (keyval == c.GDK_KEY_F5 or keyval == c.GDK_KEY_F6)) {
            if (self.peerView() != null) {
                self.sendToPeer(keyval == c.GDK_KEY_F6, null);
                return 1;
            }
        }
        if (mods == 0 and keyval == c.GDK_KEY_BackSpace) {
            if (self.typeaheadBackspace()) return 1;
        }
        if (mods == 0 and keyval == c.GDK_KEY_Escape and self.ta_len > 0) {
            self.typeaheadReset();
            return 1;
        }
        // Type-ahead: plain printable keys jump to the first matching
        // name. Runs BEFORE the binding table only for keys no binding
        // claims, since this handler is bubble-phase and a focused
        // entry has already consumed its own input.
        if ((mods == 0 or mods == c.GDK_SHIFT_MASK) and self.typeahead(keyval)) return 1;
        const ictx = self.pane.input_ctx orelse return 0;
        const lower_kv: c_uint = lower_pre;
        const bindings: []const input.Binding = if (ictx.bindings.len > 0) ictx.bindings else &input.default_bindings;
        if (input.matchBinding(bindings, lower_kv, state) orelse input.matchBinding(bindings, keyval, state)) |action| {
            return input.runAction(ictx, action);
        }
        return 0;
    }

    /// Drop of an entry spec onto the listing: target dir = the row
    /// under the pointer when it's a directory, else the tab root.
    /// Same host = MOVE (rename, undoable); cross-host = copy.
    fn onListDrop(
        target: *c.GtkDropTarget,
        value: *c.GValue,
        x: f64,
        y: f64,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        _ = target;
        _ = x;
        const tab: *BTab = @ptrCast(@alignCast(user.?));
        const self = tab.view;
        const cstr = c.g_value_get_string(value) orelse return 0;
        const spec = std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));
        if (spec.len == 0) return 0;
        const loc = parseSpec(spec);
        const src_host: ?[]const u8 = if (loc.current_host) null else loc.host;
        const src = loc.path;
        if (src.len == 0 or src[0] != '/') return 0;

        var dst_dir: []const u8 = tab.root.path;
        var dbuf: [4096]u8 = undefined;
        if (c.gtk_list_box_get_row_at_y(tab.listbox, @intFromFloat(y))) |row| {
            if (c.g_object_get_data(@ptrCast(row), "sketerm-row")) |data| {
                const rctx: *RowCtx = @ptrCast(@alignCast(data));
                if (rctx.is_dir) {
                    if (rctx.path.len < dbuf.len) {
                        @memcpy(dbuf[0..rctx.path.len], rctx.path);
                        dst_dir = dbuf[0..rctx.path.len];
                    }
                }
            }
        }
        const base = std.fs.path.basename(src);
        var dst_buf: [4200]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
            if (dst_dir.len == 1) "" else dst_dir, base,
        }) catch return 0;

        if (hostEq(src_host, tab.hc.host)) {
            if (std.mem.eql(u8, src, dst)) return 0; // dropped in place
            const req = self.nextReq();
            self.deferUndo(req, self.makeUndo(tab.hc.host, .rename_back, dst, src, ""));
            self.sendOp(tab.hc, .{ .req = req, .op = "rename", .path = src, .to = dst });
            self.setStatusFmt("moved {s} -> {s}", .{ base, dst_dir });
        } else {
            const src_hc = self.hostConnFor(src_host) orelse return 0;
            self.startTransfer(src_hc, src, tab.hc, dst, .{});
            self.setStatusFmt("copying {s} -> {s}", .{ base, dst_dir });
        }
        return 1;
    }

    fn sortClicked(tab: *BTab, key: browser_model.SortKey) void {
        // Only one key orders the view; picking a fixed column drops
        // any attribute ordering.
        tab.attr_sort = null;
        if (tab.sort_key == key) {
            tab.descending = !tab.descending;
        } else {
            tab.sort_key = key;
            tab.descending = false;
        }
        tab.view.updateSortHeader(tab);
        tab.view.renderTab(tab);
    }

    fn onViewModeClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const tab = self.currentTab() orelse return;
        tab.view_mode = switch (tab.view_mode) {
            .details => .compact,
            .compact => .icons,
            .icons => .miller,
            .miller => .details,
        };
        self.setStatusFmt("view: {s}", .{@tagName(tab.view_mode)});
        self.renderTab(tab);
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
    fn onCwdSyncClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const tab = self.currentTab() orelse return;
        const cwd = self.pane.terminal.cwd orelse {
            self.setStatus("the shell has not reported a directory yet (needs OSC 7 shell integration)");
            return;
        };
        var buf: [4096]u8 = undefined;
        if (cwd.len >= buf.len) return;
        @memcpy(buf[0..cwd.len], cwd);
        self.navigate(tab, null, buf[0..cwd.len]);
    }
    fn onHiddenToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (self.currentTab()) |tab| tab.show_hidden = c.gtk_toggle_button_get_active(btn) != 0;
        self.renderCurrent();
    }

    const CompletionCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        text: []u8,
        fn free(user: ?*anyopaque) callconv(.c) void {
            const ctx: *CompletionCtx = @ptrCast(@alignCast(user.?));
            ctx.allocator.free(ctx.text);
            ctx.allocator.destroy(ctx);
        }
    };

    /// Close the popup AND drop the debounce timer: a timer left armed
    /// re-opens the list right after the user has already navigated,
    /// leaving a popover nothing dismisses (it is autohide-free).
    fn cancelPathCompletion(self: *BrowserView) void {
        if (self.completion_source != 0) {
            _ = c.g_source_remove(self.completion_source);
            self.completion_source = 0;
        }
        if (self.completion_request) |request| {
            request.destroy(self.allocator);
            self.completion_request = null;
        }
        self.closePathCompletion();
    }

    fn closePathCompletion(self: *BrowserView) void {
        if (self.completion_popover) |pop| {
            self.completion_popover = null;
            if (c.gtk_widget_get_parent(pop) != null) c.gtk_widget_unparent(pop);
        }
    }

    fn onPathChanged(_: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (self.syncing_path_entry) return;
        if (self.completion_source != 0) _ = c.g_source_remove(self.completion_source);
        self.completion_source = c.g_timeout_add(150, @ptrCast(&onCompletionTimeout), @ptrCast(self));
    }

    fn onCompletionTimeout(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        self.completion_source = 0;
        self.renderPathCompletion();
        return 0;
    }

    fn renderPathCompletion(self: *BrowserView) void {
        self.closePathCompletion();
        if (self.completion_request) |request| {
            request.destroy(self.allocator);
            self.completion_request = null;
        }
        const tab = self.currentTab() orelse return;
        const raw = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(self.path_entry)))));
        const slash = std.mem.lastIndexOfScalar(u8, raw, '/') orelse return;
        const loc = parseSpec(raw);
        if (loc.path.len == 0 or loc.path[0] != '/') return;
        const path_slash = std.mem.lastIndexOfScalar(u8, loc.path, '/') orelse return;
        const candidate_host: ?[]const u8 = if (loc.current_host) tab.hc.host else loc.host;
        // Split at the last slash rather than using dirname: for the
        // trailing-slash case ("/a/b/") dirname answers "/a", so the
        // popup would list the grandparent of what was typed.
        const parent = if (path_slash == 0) "/" else loc.path[0..path_slash];
        const prefix = loc.path[path_slash + 1 ..];
        if (hostEq(candidate_host, tab.hc.host) and std.mem.eql(u8, parent, tab.root.path)) {
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(self.allocator);
            for (tab.root.entries.items) |entry| {
                if (entry.tdir) names.append(self.allocator, entry.name) catch {};
            }
            self.showCompletionNames(raw[0 .. slash + 1], prefix, names.items);
            return;
        }
        const hc = self.hostConnFor(candidate_host) orelse return;
        if (hc.state != .ready) return;
        const request = self.allocator.create(PathCompletion) catch return;
        const display_owned = self.allocator.dupe(u8, raw[0 .. slash + 1]) catch { self.allocator.destroy(request); return; };
        const prefix_owned = self.allocator.dupe(u8, prefix) catch { self.allocator.free(display_owned); self.allocator.destroy(request); return; };
        request.* = .{
            .req = self.nextReq(),
            .hc = hc,
            .display_prefix = display_owned,
            .typed_prefix = prefix_owned,
        };
        self.completion_request = request;
        self.sendOp(hc, .{ .req = request.req, .op = "list", .path = parent });
    }

    fn showCompletionNames(self: *BrowserView, display_prefix: []const u8, prefix: []const u8, names: []const []const u8) void {
        self.closePathCompletion();
        const pop = c.gtk_popover_new();
        const list = c.gtk_list_box_new();
        c.gtk_popover_set_autohide(@ptrCast(pop), 0);
        c.gtk_widget_set_can_focus(pop, 0);
        c.gtk_widget_set_can_focus(list, 0);
        c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_BROWSE);
        c.gtk_list_box_set_activate_on_single_click(@ptrCast(list), 1);
        var count: usize = 0;
        for (names) |name| {
            if (name.len > 0 and name[0] == '.') continue;
            if (prefix.len > name.len or !std.ascii.eqlIgnoreCase(prefix, name[0..prefix.len])) continue;
            var text_buf: [4600]u8 = undefined;
            const completed = std.fmt.bufPrint(&text_buf, "{s}{s}/", .{ display_prefix, name }) catch continue;
            const ctx = self.allocator.create(CompletionCtx) catch continue;
            ctx.* = .{ .allocator = self.allocator, .view = self, .text = self.allocator.dupe(u8, completed) catch { self.allocator.destroy(ctx); continue; } };
            const row = c.gtk_list_box_row_new();
            c.gtk_widget_set_can_focus(row, 0);
            const label = c.gtk_label_new(null);
            var name_z: [512:0]u8 = undefined;
            const n = @min(name.len, name_z.len - 1);
            @memcpy(name_z[0..n], name[0..n]);
            name_z[n] = 0;
            c.gtk_label_set_text(@ptrCast(label), &name_z);
            c.gtk_label_set_xalign(@ptrCast(label), 0);
            c.gtk_list_box_row_set_child(@ptrCast(row), label);
            c.g_object_set_data_full(@ptrCast(row), "sketerm-completion", @ptrCast(ctx), @ptrCast(&CompletionCtx.free));
            c.gtk_list_box_append(@ptrCast(list), row);
            count += 1;
            if (count >= 30) break;
        }
        if (count == 0) { c.g_object_unref(pop); return; }
        _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onCompletionActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_popover_set_child(@ptrCast(pop), list);
        c.gtk_widget_set_parent(pop, @ptrCast(@alignCast(self.path_entry)));
        self.completion_popover = pop;
        c.gtk_popover_popup(@ptrCast(pop));
    }

    fn onCompletionActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const data = c.g_object_get_data(@ptrCast(row), "sketerm-completion") orelse return;
        const ctx: *CompletionCtx = @ptrCast(@alignCast(data));
        self.syncing_path_entry = true;
        var z: [4600:0]u8 = undefined;
        const n = @min(ctx.text.len, z.len - 1);
        @memcpy(z[0..n], ctx.text[0..n]);
        z[n] = 0;
        c.gtk_editable_set_text(@ptrCast(self.path_entry), &z);
        c.gtk_editable_set_position(@ptrCast(self.path_entry), -1);
        self.syncing_path_entry = false;
        self.closePathCompletion();
        if (self.completion_source != 0) _ = c.g_source_remove(self.completion_source);
        self.completion_source = c.g_timeout_add(150, @ptrCast(&onCompletionTimeout), @ptrCast(self));
    }

    fn onPathKey(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        if (keyval == c.GDK_KEY_Escape and self.completion_popover != null) {
            self.closePathCompletion();
            return 1;
        }
        if (keyval == c.GDK_KEY_Tab) {
            const pop = self.completion_popover orelse return 0;
            const child = c.gtk_popover_get_child(@ptrCast(pop)) orelse return 0;
            const row = c.gtk_list_box_get_row_at_index(@ptrCast(@alignCast(child)), 0) orelse return 0;
            onCompletionActivated(@ptrCast(@alignCast(child)), row, self);
            return 1;
        }
        return 0;
    }

    const PatternCtx = struct {
        allocator: std.mem.Allocator,
        view: *BrowserView,
        popover: *c.GtkWidget,
        fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const ctx: *PatternCtx = @ptrCast(@alignCast(user.?));
            ctx.allocator.destroy(ctx);
        }
    };

    fn showSelectPattern(self: *BrowserView) void {
        const pop = c.gtk_popover_new();
        const entry = c.gtk_entry_new();
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Select name/glob (* and ?)");
        const ctx = self.allocator.create(PatternCtx) catch { c.g_object_unref(pop); return; };
        ctx.* = .{ .allocator = self.allocator, .view = self, .popover = pop };
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onPatternActivate), @ptrCast(ctx), @ptrCast(&PatternCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_popover_set_child(@ptrCast(pop), entry);
        c.gtk_widget_set_parent(pop, @ptrCast(@alignCast(self.path_entry)));
        c.gtk_popover_popup(@ptrCast(pop));
        _ = c.gtk_widget_grab_focus(entry);
    }

    fn onPatternActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const ctx: *PatternCtx = @ptrCast(@alignCast(user.?));
        const pattern = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
        if (pattern.len > 0) ctx.view.selectPattern(pattern, false);
        if (c.gtk_widget_get_parent(ctx.popover) != null) c.gtk_widget_unparent(ctx.popover);
    }

    fn selectPattern(self: *BrowserView, pattern: []const u8, invert: bool) void {
        const tab = self.currentTab() orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var existing = std.StringHashMap(void).init(arena.allocator());
        for (tab.selected.items) |path| existing.put(arena.allocator().dupe(u8, path) catch continue, {}) catch {};
        for (tab.selected.items) |path| self.allocator.free(path);
        tab.selected.clearRetainingCapacity();
        const dirs = [_]*Dir{tab.root};
        self.selectPatternDirs(tab, &dirs, pattern, invert, &existing);
        if (tab.view_mode != .icons) self.selectPatternDirs(tab, tab.subdirs.items, pattern, invert, &existing);
        self.renderTab(tab);
        self.updatePreview();
        self.setStatusFmt("selected {d} item(s)", .{tab.selected.items.len});
    }

    fn selectPatternDirs(self: *BrowserView, tab: *BTab, dirs: []const *Dir, pattern: []const u8, invert: bool, existing: *std.StringHashMap(void)) void {
        for (dirs) |dir| for (dir.entries.items) |entry| {
            if (!tab.show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
            var path_buf: [4200]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ if (dir.path.len == 1) "" else dir.path, entry.name }) catch continue;
            const matched = fsjob.nameMatches(pattern, entry.name);
            const selected = if (invert) (existing.contains(path) != matched) else matched;
            if (!selected) continue;
            const owned = self.allocator.dupe(u8, path) catch continue;
            tab.selected.append(self.allocator, owned) catch self.allocator.free(owned);
        };
    }

    // ── type-ahead jump ─────────────────────────────────────────

    /// Idle gap after which the next keystroke starts a fresh prefix.
    const TYPEAHEAD_RESET_US: i64 = 1_200_000;

    fn typeaheadReset(self: *BrowserView) void {
        self.ta_len = 0;
        self.setStatus("");
    }

    fn typeaheadBackspace(self: *BrowserView) bool {
        if (self.ta_len == 0) return false;
        self.ta_len -= 1;
        if (self.ta_len == 0) {
            self.typeaheadReset();
            return true;
        }
        _ = self.typeaheadJump();
        return true;
    }

    /// Consume a printable key as a jump-to-name prefix. Returns false
    /// for keys that are not type-ahead material so the caller can
    /// keep dispatching them.
    fn typeahead(self: *BrowserView, keyval: c_uint) bool {
        const uni = c.gdk_keyval_to_unicode(keyval);
        // Printable ASCII only: a jump prefix is compared against
        // file names byte-wise, and space is a selection key.
        if (uni < 0x21 or uni > 0x7e) return false;
        const tab = self.currentTab() orelse return false;
        if (tab.view_mode == .icons) return false;
        const now = c.g_get_monotonic_time();
        if (now - self.ta_last_us > TYPEAHEAD_RESET_US) self.ta_len = 0;
        self.ta_last_us = now;
        if (self.ta_len >= self.ta_buf.len) return true;
        self.ta_buf[self.ta_len] = @intCast(uni);
        self.ta_len += 1;
        if (!self.typeaheadJump()) {
            // Keep the prefix: the user is mid-word and the next
            // keystroke may still match once the listing settles.
            self.setStatusFmt("no match: {s}", .{self.ta_buf[0..self.ta_len]});
        }
        return true;
    }

    fn typeaheadJump(self: *BrowserView) bool {
        const tab = self.currentTab() orelse return false;
        const prefix = self.ta_buf[0..self.ta_len];
        var idx: c_int = 0;
        while (c.gtk_list_box_get_row_at_index(tab.listbox, idx)) |row| : (idx += 1) {
            const data = c.g_object_get_data(@ptrCast(row), "sketerm-row") orelse continue;
            const ctx: *RowCtx = @ptrCast(@alignCast(data));
            const name = std.fs.path.basename(ctx.path);
            if (name.len < prefix.len) continue;
            if (!std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) continue;
            c.gtk_list_box_unselect_all(tab.listbox);
            c.gtk_list_box_select_row(tab.listbox, @ptrCast(row));
            _ = c.gtk_widget_grab_focus(@ptrCast(row));
            self.setStatusFmt("jump: {s}", .{prefix});
            return true;
        }
        return false;
    }

    // ── dual-pane source/target ─────────────────────────────────

    /// The other browser face in this sketerm tab, if any: the
    /// orthodox implicit destination.
    fn peerView(self: *BrowserView) ?*BrowserView {
        const lookup = self.on_peer orelse return null;
        const ctx = self.hooks_ctx orelse return null;
        const peer = lookup(ctx, self.pane) orelse return null;
        return if (peer == self) null else peer;
    }

    /// Copy (or move) the current selection into the other pane's
    /// current directory, conflict dialog included.
    fn sendToPeer(self: *BrowserView, move: bool, clicked: ?[]const u8) void {
        const tab = self.currentTab() orelse return;
        const peer = self.peerView() orelse {
            self.setStatus("no second browser pane in this tab");
            return;
        };
        const peer_tab = peer.currentTab() orelse return;
        // Same rule as Copy: a clicked row outside the selection acts
        // on itself, not on the selection.
        var one: [1][]u8 = undefined;
        var sources: []const []u8 = tab.selected.items;
        if (clicked) |path| {
            const in_selection = for (tab.selected.items) |sp| {
                if (std.mem.eql(u8, sp, path)) break true;
            } else false;
            if (!in_selection or tab.selected.items.len <= 1) {
                one[0] = @constCast(path);
                sources = one[0..];
            }
        }
        if (sources.len == 0) {
            self.setStatus("select something to send to the other pane");
            return;
        }
        if (hostEq(tab.hc.host, peer_tab.hc.host) and std.mem.eql(u8, tab.root.path, peer_tab.root.path)) {
            self.setStatus("both panes show the same directory");
            return;
        }
        peer.beginPaste(peer_tab, tab.hc.host, sources, move, false);
        var buf: [4300]u8 = undefined;
        self.setStatusFmt("{s} {d} item(s) to {s}", .{
            if (move) "moving" else "copying",
            sources.len,
            peer_tab.spec(&buf),
        });
    }

    fn onPathActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const self: *BrowserView = @ptrCast(@alignCast(user.?));
        const tab = self.currentTab() orelse return;
        const txt = c.gtk_editable_get_text(@ptrCast(entry));
        const spec = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        if (spec.len == 0) return;
        self.cancelPathCompletion();
        const loc = parseSpec(spec);
        if (loc.path.len == 0 or loc.path[0] != '/') {
            self.setStatus("path must be absolute (host:/path for remote)");
            return;
        }
        self.navigateSpec(tab, spec);
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

/// A readable, deterministic color for a tag set.
fn tagColorHex(tags: []const u8) []const u8 {
    const palette = [_][]const u8{
        "#e05050", "#d08030", "#a0a020", "#40a040",
        "#30a0a0", "#5080e0", "#9060d0", "#d060a0",
    };
    var h = std.hash.Wyhash.init(7);
    h.update(tags);
    return palette[@intCast(h.final() % palette.len)];
}

/// Decode %XX escapes (freedesktop .trashinfo Path values).
fn urlUnescape(s: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (out >= buf.len) return null;
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                buf[out] = s[i];
                out += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                buf[out] = s[i];
                out += 1;
                i += 1;
                continue;
            };
            buf[out] = (hi << 4) | lo;
            out += 1;
            i += 3;
        } else {
            buf[out] = s[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

/// True when a LOCAL path sits on a sketerm FUSE mount (whose pin/
/// evict xattrs control the hydration cache).
fn isSketermMount(path: []const u8) bool {
    const f = c.fopen("/proc/mounts", "rb") orelse return false;
    defer _ = c.fclose(f);
    var buf: [32 * 1024]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    var it = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        const mp = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;
        if (!std.mem.eql(u8, fstype, "fuse.sketerm")) continue;
        if (std.mem.startsWith(u8, path, mp) and
            (path.len == mp.len or path[mp.len] == '/')) return true;
    }
    return false;
}

/// The local freedesktop trash "files" directory.
fn trashFilesDir(buf: []u8) ?[]const u8 {
    if (c.getenv("XDG_DATA_HOME")) |xd| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(xd)));
        return std.fmt.bufPrint(buf, "{s}/Trash/files", .{s}) catch null;
    }
    if (c.getenv("HOME")) |h| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(h)));
        return std.fmt.bufPrint(buf, "{s}/.local/share/Trash/files", .{s}) catch null;
    }
    return null;
}

/// True when `path` is inside a freedesktop trash "files" dir —
/// the home trash (…/Trash/files) or a topdir one (…/.Trash-UID/files).
fn isTrashPath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "/Trash/files") != null) return true;
    if (std.mem.indexOf(u8, path, "/.Trash-")) |i| {
        return std.mem.indexOf(u8, path[i..], "/files") != null;
    }
    return false;
}

/// The child name inside `ancestor` on the way toward `root`, or
/// null when root is not under ancestor.
fn millerNextSegment(ancestor: []const u8, root: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, root, ancestor)) return null;
    var rest = root[ancestor.len..];
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    if (rest.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return rest[0..end];
}

fn launchLocal(path: []const u8) void {
    const uri = filenameUri(path) orelse return;
    defer c.g_free(uri);
    _ = c.g_app_info_launch_default_for_uri(uri, null, null);
}

/// Launch a specific installed application (by GAppInfo id) on a
/// local path; falls back to the default handler if the id vanished.
fn launchLocalWithApp(appid: []const u8, path: []const u8) void {
    const uri = filenameUri(path) orelse return;
    defer c.g_free(uri);
    const apps = c.g_app_info_get_all();
    defer if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
    var it = apps;
    while (it != null) : (it = it.*.next) {
        const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
        const id = c.g_app_info_get_id(app) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(id), appid)) continue;
        var list: ?*c.GList = null;
        list = c.g_list_append(list, @ptrCast(uri));
        _ = c.g_app_info_launch_uris(app, list, null, null);
        c.g_list_free(list);
        return;
    }
    launchLocal(path);
}

fn filenameUri(path: []const u8) ?[*c]c.gchar {
    var path_buf: [4096:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    const uri = c.g_filename_to_uri(path_z.ptr, null, null);
    return if (uri == null) null else uri;
}

/// Make `appid` the default handler for `path`'s guessed type.
fn setDefaultAppForPath(appid: []const u8, path: []const u8) void {
    var namez: [512:0]u8 = undefined;
    const base = std.fs.path.basename(path);
    const bz = std.fmt.bufPrintZ(&namez, "{s}", .{base}) catch return;
    var uncertain: c.gboolean = 0;
    const ct = c.g_content_type_guess(bz.ptr, null, 0, &uncertain);
    if (ct == null) return;
    defer c.g_free(ct);
    const apps = c.g_app_info_get_all();
    defer if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
    var it = apps;
    while (it != null) : (it = it.*.next) {
        const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
        const id = c.g_app_info_get_id(app) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(id), appid)) continue;
        _ = c.g_app_info_set_as_default_for_type(app, ct, null);
        return;
    }
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

/// Truncating copy into a sentinel buffer for GTK label text.
fn copyZ(buf: *[256:0]u8, text: []const u8) [*:0]const u8 {
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf;
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

fn fmtModeZ(buf: *[16:0]u8, mode: u32, is_dir: bool) [*:0]const u8 {
    const bits = [_]u8{ 'r', 'w', 'x' };
    buf[0] = if (is_dir) 'd' else '-';
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const on = (mode >> @intCast(8 - i)) & 1 == 1;
        buf[1 + i] = if (on) bits[i % 3] else '-';
    }
    buf[10] = 0;
    return @ptrCast(buf);
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

test "isPreviewMediaName includes document video and audio formats" {
    const t = std.testing;
    try t.expect(isPreviewMediaName("manual.PDF"));
    try t.expect(isPreviewMediaName("clip.webm"));
    try t.expect(isPreviewMediaName("album.flac"));
    try t.expect(!isPreviewMediaName("source.zig"));
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
