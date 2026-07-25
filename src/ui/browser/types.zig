//! Shared browser data types: the wire mirrors of the daemon's fs
//! replies, the owned listing model (Entry/Dir/BTab), the per-host
//! connection record, and the small bookkeeping structs the view's
//! in-flight operations queue up.

const std = @import("std");
const c = @import("../../c.zig").c;
const muxclient = @import("../../mux/client.zig");
const colkeys = @import("../../filebrowser/colkeys.zig");
const fsdrive = @import("../../ipc/fsdrive.zig");
const fstransfer = @import("../../ipc/fstransfer.zig");
const browser_model = @import("../../filebrowser/model.zig");

const BrowserView = @import("view.zig").BrowserView;
const TabSel = @import("selection.zig").TabSel;
const TabView = @import("views.zig").TabView;
const formatSpec = @import("../../filebrowser/paths.zig").formatSpec;

/// One owned directory entry (strings owned by the Dir's allocator).
pub const Entry = struct {
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
    /// Values for the tab's extended-attribute columns, in xattr
    /// column order; they ride the listing itself.
    attrs: [][]u8 = &.{},
    /// Values for the tab's media-metadata columns, in media column
    /// order. Stitched on from the client-side cache by
    /// mediacols.applyValues, since they arrive from a batched job
    /// long after the listing. Short (or empty) means "no answer
    /// yet", which every reader treats as no value.
    meta: [][]u8 = &.{},

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        if (self.target) |t| allocator.free(t);
        if (self.tags.len > 0) allocator.free(self.tags);
        for (self.attrs) |v| allocator.free(v);
        if (self.attrs.len > 0) allocator.free(self.attrs);
        for (self.meta) |v| allocator.free(v);
        if (self.meta.len > 0) allocator.free(self.meta);
    }
};

/// Wire mirror of the fs_reply fields the browser consumes.
pub const WireEntry = struct {
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

pub const WireReply = struct {
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
pub const WireApp = struct {
    name: []const u8 = "",
    exec: []const u8 = "",
    mimes: []const u8 = "",
};

pub const WireDelta = struct {
    view: u32 = 0,
    gone: bool = false,
    resync: bool = false,
    changes: []struct {
        op: []const u8 = "",
        name: []const u8 = "",
        entry: ?WireEntry = null,
    } = &.{},
};

pub const WireJobEv = struct {
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
    /// Bytes a staged partial contributed. The daemon only fills this
    /// on the terminal event, so the panel treats it as sticky.
    resumed_from: u64 = 0,
    /// media_meta match payload: one file's extracted fields, plus
    /// whether the host served them from its own cache.
    meta: []const fsdrive.MediaField = &.{},
    cached: bool = false,

    /// True for the events that end a job.
    pub fn terminalEv(self: WireJobEv) bool {
        return std.mem.eql(u8, self.ev, "done") or
            std.mem.eql(u8, self.ev, "error") or
            std.mem.eql(u8, self.ev, "canceled");
    }
};

/// One shared connection to a host's daemon. Referenced by tabs and
/// transfers; owned by the BrowserView.
pub const HostConn = struct {
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

    pub fn label(self: *const HostConn) []const u8 {
        return self.host orelse "local";
    }

    pub fn destroy(self: *HostConn, allocator: std.mem.Allocator) void {
        if (self.watch_id != 0) _ = c.g_source_remove(self.watch_id);
        if (self.state == .ready) self.conn.deinit();
        if (self.cache_dir) |cd| allocator.free(cd);
        if (self.host) |h| allocator.free(h);
        allocator.destroy(self);
    }
};

/// An extra column resolved down to what sorting actually needs:
/// which per-entry value array holds it, where in that array, and
/// how its values order. Resolving once per sort keeps the
/// comparator free of table lookups.
pub const ColumnSort = struct {
    source: colkeys.Source,
    /// Index within `Entry.attrs` (xattr) or `Entry.meta` (media).
    index: usize,
    kind: colkeys.ValueKind,

    fn valueOf(self: ColumnSort, e: Entry) []const u8 {
        const values = switch (self.source) {
            .xattr => e.attrs,
            .media => e.meta,
        };
        return if (self.index < values.len) values[self.index] else "";
    }
};

/// One live (subscribed) directory: a browser tab's root, or an
/// expanded subdirectory.
pub const Dir = struct {
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
    /// The extra column this dir is sorted by, if any (resolved once
    /// per sort by the owning tab, not looked up per comparison).
    attr_sort: ?ColumnSort = null,
    descending: bool = false,
    dirs_first: bool = true,

    pub fn deinit(self: *Dir) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        if (self.archive.len > 0) self.allocator.free(self.archive);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// The full path of one of this directory's entries. Flat rows
    /// (search results, collections) carry theirs in `target`.
    /// @return null when the name does not fit `buf` or a flat row
    /// has no target.
    pub fn fullPath(self: *Dir, e: Entry, buf: []u8) ?[]const u8 {
        if (self.flat or self.collection) return e.target;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{
            if (self.path.len == 1) "" else self.path, e.name,
        }) catch null;
    }

    pub fn find(self: *Dir, name: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }

    pub fn own(self: *Dir, we: WireEntry) ?Entry {
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

    pub fn upsert(self: *Dir, we: WireEntry) void {
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

    pub fn del(self: *Dir, name: []const u8) void {
        if (self.find(name)) |i| {
            var e = self.entries.orderedRemove(i);
            e.deinit(self.allocator);
        }
    }

    pub fn sort(self: *Dir) void {
        const Ctx = struct { key: browser_model.SortKey, desc: bool, dirs_first: bool, attr: ?ColumnSort };
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
                if (ctx.attr) |col| {
                    // colkeys owns the value semantics: type-aware
                    // ordering, missing last in BOTH directions, and
                    // malformed values that cannot corrupt the sort.
                    // It takes the UNSWAPPED pair plus `desc` for
                    // exactly that reason.
                    const o = colkeys.order(col.kind, col.valueOf(a_in), col.valueOf(b_in), ctx.desc);
                    if (o != .eq) return o == .lt;
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
pub const BTab = struct {
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
    /// Live view narrowing (filter-as-you-type); persisted per tab.
    filter: []u8 = &.{},
    virtual_spec: []u8 = &.{},
    /// Grouping, zoom and the collapsed-group set (views.zig).
    vs: TabView = .{},
    /// Sticky-click flag and visual-mode anchor (selection.zig).
    sel: TabSel = .{},
    page: *c.GtkWidget,
    listbox: *c.GtkListBox,
    tab_label: *c.GtkLabel,
    /// Details/compact sort header (hidden in grid/miller). Rebuilt
    /// whenever the column set or sort changes.
    header_box: *c.GtkWidget = undefined,
    /// Optional details columns, rendered in Column declaration order.
    columns: std.EnumSet(browser_model.Column) =
        std.EnumSet(browser_model.Column).initMany(&browser_model.default_columns),
    /// Extra columns the user added by KEY (owned, in display
    /// order). One list for both sources: `user.*` values ride the
    /// listing, `media.*`/`tag.*`/`exif.*`/`image.*`/`doc.*` values
    /// come from the batched media_meta job. colkeys.sourceOf tells
    /// them apart, so there is one add/remove/sort path, not two.
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

    pub fn subdirByPath(self: *BTab, path: []const u8) ?*Dir {
        for (self.subdirs.items) |d| {
            if (std.mem.eql(u8, d.path, path)) return d;
        }
        return null;
    }

    pub fn dirByView(self: *BTab, view_id: u32) ?*Dir {
        if (self.root.view_id == view_id) return self.root;
        for (self.subdirs.items) |d| {
            if (d.view_id == view_id) return d;
        }
        for (self.ancestors.items) |d| {
            if (d.view_id == view_id) return d;
        }
        return null;
    }

    /// The tab's extra-column sort, resolved to what the comparator
    /// needs. Done once per sort rather than per comparison.
    pub fn columnSort(self: *BTab) ?ColumnSort {
        const i = self.attr_sort orelse return null;
        if (i >= self.attr_columns.items.len) return null;
        const key = self.attr_columns.items[i];
        return .{
            .source = colkeys.sourceOf(key) orelse return null,
            .index = colkeys.subIndex(self.attr_columns.items, i),
            .kind = colkeys.kindOf(key),
        };
    }

    /// Push the tab's sort parameters onto every live Dir and re-sort.
    pub fn applySort(self: *BTab) void {
        const col = self.columnSort();
        const dirs = [_]?*Dir{self.root};
        for (dirs) |d| {
            d.?.sort_key = self.sort_key;
            d.?.attr_sort = col;
            d.?.descending = self.descending;
            d.?.dirs_first = self.dirs_first;
            d.?.sort();
        }
        for (self.subdirs.items) |d| {
            d.sort_key = self.sort_key;
            d.attr_sort = col;
            d.descending = self.descending;
            d.dirs_first = self.dirs_first;
            d.sort();
        }
    }

    pub fn dropAncestors(self: *BTab) void {
        for (self.ancestors.items) |d| {
            self.view.cancelPendingDir(d);
            self.view.closeViewOf(self.hc, d);
            d.deinit();
        }
        self.ancestors.clearRetainingCapacity();
    }

    pub fn dropSubdirsUnder(self: *BTab, prefix: []const u8) void {
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
    pub fn spec(self: *BTab, buf: []u8) []const u8 {
        return formatSpec(buf, self.hc.host, self.root.path);
    }

    pub fn deinit(self: *BTab) void {
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
        self.vs.deinit(a);
        self.sel.deinit(a);
        a.destroy(self);
    }
};

/// What a navigation does to the tab's history. The back/forward
/// payload is how many entries the move travels: 1 for the toolbar
/// buttons, N for a history-dropdown jump.
pub const NavigationIntent = union(enum) {
    push,
    back: usize,
    forward: usize,
};

/// In-flight listing request (open_view or refresh `list`). `sent`
/// is false while the tab's host is still connecting; the connect
/// handback flushes unsent requests.
pub const Pending = struct {
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

/// What a job operates on, for the jobs-panel detail view. Fixed
/// buffers (the daemon's own FsJob.done_path pattern) so a job record
/// stays destroyable by allocator.destroy alone; an over-long path
/// keeps its tail, which is the part that identifies the file.
pub const JobPaths = struct {
    src: [512]u8 = undefined,
    src_len: u16 = 0,
    dst: [512]u8 = undefined,
    dst_len: u16 = 0,

    pub fn set(self: *JobPaths, src: []const u8, dst: []const u8) void {
        self.src_len = copyTail(&self.src, src);
        self.dst_len = copyTail(&self.dst, dst);
    }

    pub fn srcPath(self: *const JobPaths) []const u8 {
        return self.src[0..self.src_len];
    }

    pub fn dstPath(self: *const JobPaths) []const u8 {
        return self.dst[0..self.dst_len];
    }

    fn copyTail(buf: *[512]u8, text: []const u8) u16 {
        if (text.len <= buf.len) {
            @memcpy(buf[0..text.len], text);
            return @intCast(text.len);
        }
        const tail = text[text.len - (buf.len - 3) ..];
        @memcpy(buf[0..3], "...");
        @memcpy(buf[3..][0..tail.len], tail);
        return @intCast(buf.len);
    }
};

/// A daemon-side job (copy/delete_tree) started by this view, shown
/// in the jobs panel.
pub const JobRow = struct {
    hc: *HostConn,
    job: u64,
    label: []u8,
    done: u64 = 0,
    total: u64 = 0,
    /// Bytes a staged partial contributed (sticky; the daemon fills it
    /// on the terminal event).
    resumed_from: u64 = 0,
    state: enum { running, paused, finished, failed, canceled } = .running,
    /// Pushed to the undo stack when the job finishes.
    undo_op: ?*UndoOp = null,
    /// Trash jobs learn the trashed/info paths only at DONE; this
    /// holds the ORIGINAL path until then (owned).
    undo_trash_orig: ?[]u8 = null,
    open_on_done: bool = false,
    history_op: ?*UndoOp = null,
    history_direction: ?HistoryDirection = null,
    /// Source and destination, for the panel's expanded detail.
    paths: JobPaths = .{},
    /// Destination identity for cross-host copies started by the
    /// transfer queue (0 = this job does not hold a destination slot).
    dest_key: u64 = 0,

    pub fn terminal(self: *const JobRow) bool {
        return self.state == .finished or self.state == .failed or self.state == .canceled;
    }
};

/// A job-start request awaiting its reply (which carries the id).
pub const PendingJob = struct {
    req: u32,
    hc: *HostConn,
    label: []u8,
    kind: enum { normal, search, compare_left, compare_right, calc_size, dup_scan, archive_list, flat_view } = .normal,
    undo_op: ?*UndoOp = null,
    undo_trash_orig: ?[]u8 = null,
    /// The done event's `path` opens when the job lands (archive
    /// member extraction).
    open_on_done: bool = false,
    history_op: ?*UndoOp = null,
    history_direction: ?HistoryDirection = null,
    /// Carried onto the JobRow when the daemon answers with the id.
    paths: JobPaths = .{},
    dest_key: u64 = 0,
};

/// One client-mediated cross-host transfer, running or queued.
pub const ActiveTransfer = struct {
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
    /// Queue state: transfers to one destination run one at a time,
    /// the rest wait here in order (see filebrowser/xferqueue.zig).
    started: bool = false,
    /// Scheduler identity of the destination (host plus local device).
    dest_key: u64 = 0,

    pub fn freeExtras(t: *ActiveTransfer, allocator: std.mem.Allocator) void {
        if (t.open_with_appid) |s| allocator.free(s);
        if (t.watch_host) |s| allocator.free(s);
        if (t.watch_remote) |s| allocator.free(s);
    }
};

/// A remote file opened locally: its cache copy is monitored, and a
/// local edit uploads back to the host (staged, hash-verified).
pub const EditWatch = struct {
    view: *BrowserView,
    /// The remote host string the file came from.
    host: []u8,
    remote_path: []u8,
    cache_path: []u8,
    monitor: ?*c.GFileMonitor = null,
    uploading: bool = false,

    pub fn destroy(self: *EditWatch, allocator: std.mem.Allocator) void {
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

/// An owned saved-search record.
pub const OwnedSearch = struct {
    spec: []u8,
    pattern: []u8,
    content: bool,

    pub fn deinitOwned(self: OwnedSearch, allocator: std.mem.Allocator) void {
        allocator.free(self.spec);
        allocator.free(self.pattern);
    }
};

/// One file-coloring rule from filecolors.conf ("glob=#RRGGBB").
pub const FileColor = struct {
    glob: []u8,
    color: [7]u8,
};

/// One undoable mutation. `a`/`b`/`p` meanings depend on kind:
/// rename_back: a = current path, b = original path;
/// delete_created: a = the path our copy created;
/// trash_restore: a = trashed path, b = original path, p = info file;
/// rmdir_created: a = the directory mkdir created.
pub const UndoOp = struct {
    host: ?[]u8,
    kind: enum { rename_back, delete_created, trash_restore, rmdir_created },
    a: []u8,
    b: []u8 = &.{},
    p: []u8 = &.{},

    pub fn destroy(self: *UndoOp, allocator: std.mem.Allocator) void {
        if (self.host) |h| allocator.free(h);
        allocator.free(self.a);
        if (self.b.len > 0) allocator.free(self.b);
        if (self.p.len > 0) allocator.free(self.p);
        allocator.destroy(self);
    }

    pub fn describe(self: *const UndoOp) []const u8 {
        return switch (self.kind) {
            .rename_back => "undo rename/move",
            .delete_created => "undo copy (delete the created item)",
            .trash_restore => "undo trash (restore)",
            .rmdir_created => "undo new folder",
        };
    }
};

/// A plain-op undo record waiting for its ok reply.
pub const PendingUndo = struct {
    req: u32,
    op: *UndoOp,
};

pub const HistoryDirection = enum { undo, redo };

pub const PendingHistory = struct {
    req: u32,
    hc: *HostConn,
    op: *UndoOp,
    direction: HistoryDirection,
};

pub const HostAction = *const fn (ctx: *anyopaque, host: []const u8, path: []const u8) void;
