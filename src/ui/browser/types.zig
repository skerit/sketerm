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
const TabQuery = @import("search.zig").TabQuery;
const TabSel = @import("selection.zig").TabSel;
const TabView = @import("views.zig").TabView;
const formatSpec = @import("../../filebrowser/paths.zig").formatSpec;
const naturalLess = @import("../../filebrowser/format.zig").naturalLess;

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
    /// Owner/group names resolved by the owning host ("" = unknown
    /// there; fall back to the numeric id).
    owner: []u8 = &.{},
    group: []u8 = &.{},
    /// Birth/creation time, 0 when the filesystem has none.
    btime_ms: i64 = 0,
    nlink: u64 = 1,
    blocks: u64 = 0,
    /// Directory child count from the owning host, -1 = unknown.
    children: i64 = -1,
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
        if (self.owner.len > 0) allocator.free(self.owner);
        if (self.group.len > 0) allocator.free(self.group);
        if (self.target) |t| allocator.free(t);
        if (self.tags.len > 0) allocator.free(self.tags);
        for (self.attrs) |v| allocator.free(v);
        if (self.attrs.len > 0) allocator.free(self.attrs);
        for (self.meta) |v| allocator.free(v);
        if (self.meta.len > 0) allocator.free(self.meta);
    }
};

/// Extension after the last dot ("" for dotless and dotfile names).
pub fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or dot + 1 == name.len) return "";
    return name[dot + 1 ..];
}

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
    owner: []const u8 = "",
    group: []const u8 = "",
    btime_ms: i64 = 0,
    nlink: u64 = 1,
    blocks: u64 = 0,
    children: i64 = -1,
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
    /// `stat` answers with ONE entry rather than a listing.
    entry: ?WireEntry = null,
    /// Device id of a listed directory: the hard-link pre-check.
    dev: u64 = 0,
    more: bool = false,
    truncated: bool = false,
    job: u64 = 0,
    state: []const u8 = "",
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    file: []const u8 = "",
    files_done: u64 = 0,
    files_total: u64 = 0,
    size: u64 = 0,
    eof: bool = false,
    apps: []WireApp = &.{},
    home: []const u8 = "",
    cache: []const u8 = "",
    /// The HOST's freedesktop template directory (XDG_TEMPLATES_DIR),
    /// resolved by the daemon that owns the files.
    templates: []const u8 = "",
    /// statfs: free space = bavail * frsize.
    bavail: u64 = 0,
    frsize: u64 = 0,
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
    /// done: `path` is a persistent host-side cache file — the
    /// consumer must NOT unlink it after reading.
    keep: bool = false,
    /// Live-query status detail (ev == "ready").
    watches: u64 = 0,
    watch_limit: bool = false,
    /// panelize: output lines that named nothing on disk, and the
    /// command's own exit status (both on the done event).
    rejected: u64 = 0,
    exit_status: i64 = 0,
    hash: []const u8 = "",
    /// Bytes a staged partial contributed. Sticky: the helper reports
    /// it once and the daemon repeats it on every later event.
    resumed_from: u64 = 0,
    /// media_meta match payload: one file's extracted fields, plus
    /// whether the host served them from its own cache.
    meta: []const fsdrive.MediaField = &.{},
    cached: bool = false,
    /// The entry the job is working on right now, and how far through
    /// its entry count it is (tree operations; 0 total = not counted).
    file: []const u8 = "",
    files_done: u64 = 0,
    files_total: u64 = 0,
    /// git_status match detail: the two porcelain-v2 columns and a
    /// rename/copy source. Empty from a daemon too old to send them,
    /// which is exactly what makes `text` still load-bearing.
    xy: []const u8 = "",
    orig: []const u8 = "",
    /// git_status `repo` event: the branch header of the browsed root,
    /// and the only way to tell a clean repository from a directory
    /// that is no repository at all.
    repo: bool = false,
    branch: []const u8 = "",
    upstream: []const u8 = "",
    ahead: i64 = 0,
    behind: i64 = 0,
    have_ab: bool = false,
    detached: bool = false,
    initial: bool = false,
    root: bool = false,

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
    /// POLLOUT watch draining a queued-send backlog (0 = none). Sends
    /// on the GUI thread only queue; this finishes the delivery.
    write_watch_id: c.guint = 0,
    /// Idle continuing a budget-cut frame drain (0 = none): one main-
    /// loop dispatch parses at most a few ms of buffered frames.
    drain_idle: c.guint = 0,
    /// Owning view died while the connect thread was in flight; the
    /// idle handback frees this struct.
    orphaned: bool = false,
    /// The host's freedesktop Templates dir, resolved by the daemon
    /// that owns the files: "New from Template" on a remote tab must
    /// offer THAT host's templates, and only its daemon can read its
    /// user-dirs.dirs.
    templates_dir: ?[]u8 = null,
    /// The host's home directory (same `homedir` reply); what the
    /// sidebar's per-host places section navigates to.
    home_dir: ?[]u8 = null,
    /// The one in-flight `homedir` request (0 = none). A second
    /// request for the same facts would be a wasted round trip that
    /// could also land first and be dropped as unrecognized.
    dirs_req: u32 = 0,
    /// The host has ANSWERED `homedir`. Distinguishes "asked, this
    /// host reports no such directory" from "never asked", so a
    /// waiter is never left expecting a reply that will not come.
    dirs_known: bool = false,

    pub fn label(self: *const HostConn) []const u8 {
        return self.host orelse "local";
    }

    pub fn destroy(self: *HostConn, allocator: std.mem.Allocator) void {
        if (self.watch_id != 0) _ = c.g_source_remove(self.watch_id);
        if (self.write_watch_id != 0) _ = c.g_source_remove(self.write_watch_id);
        if (self.drain_idle != 0) _ = c.g_source_remove(self.drain_idle);
        if (self.state == .ready) self.conn.deinit();
        if (self.templates_dir) |td| allocator.free(td);
        if (self.home_dir) |hd| allocator.free(hd);
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
/// Stand-in for a listing failure whose reason could not be
/// duplicated. Static storage, so `clearLoadError` must not free it.
const LOAD_ERROR_OOM: []u8 = @constCast("the listing failed and the reason could not be kept");

pub const Dir = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    view_id: u32,
    entries: std.ArrayList(Entry) = .empty,
    loaded: bool = false,
    /// A chunked listing is still arriving: rows are already visible
    /// and grow per chunk, so the status line says "listing…" rather
    /// than presenting the running count as final.
    streaming: bool = false,
    gone: bool = false,
    /// Why the last listing of this directory was refused (owned), or
    /// null. It rides the DIR so it dies with it, and so every render
    /// keeps saying it: a status-bar line alone is erased by the next
    /// render, which is exactly how a refused listing came to read as
    /// "0 items".
    load_error: ?[]u8 = null,
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
    /// Device id of this directory (from the listing reply). Zero
    /// until a listing lands; two paths sharing it are on one
    /// filesystem, which is what a hard link needs.
    dev: u64 = 0,
    descending: bool = false,
    dirs_first: bool = true,

    pub fn deinit(self: *Dir) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        if (self.archive.len > 0) self.allocator.free(self.archive);
        self.clearLoadError();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Record why this directory could not be listed. An unrecordable
    /// reason (OOM) still marks the failure, so the listing can never
    /// fall back to reading as empty.
    pub fn setLoadError(self: *Dir, reason: []const u8) void {
        self.clearLoadError();
        self.load_error = self.allocator.dupe(u8, reason) catch LOAD_ERROR_OOM;
    }

    pub fn clearLoadError(self: *Dir) void {
        const msg = self.load_error orelse return;
        self.load_error = null;
        if (msg.ptr != LOAD_ERROR_OOM.ptr) self.allocator.free(msg);
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

    /// True when this directory's rows are NOT children of its own
    /// path: search results, panelize output and register rows all
    /// carry their real location in `target`.
    pub fn isFlat(self: *const Dir) bool {
        return self.flat or self.collection;
    }

    /// The entry whose full path is `path`, or null.
    ///
    /// Mirrors `fullPath` exactly, which is why the target scan is
    /// restricted to flat dirs: an ordinary directory's `target` is a
    /// SYMLINK's destination, and matching on it would hand back the
    /// link when asked about the file it points at.
    pub fn findPath(self: *Dir, path: []const u8) ?*Entry {
        if (self.isFlat()) {
            for (self.entries.items) |*e| {
                const t = e.target orelse continue;
                if (std.mem.eql(u8, t, path)) return e;
            }
            return null;
        }
        const parent = std.fs.path.dirname(path) orelse return null;
        if (!std.mem.eql(u8, self.path, parent)) return null;
        const i = self.find(std.fs.path.basename(path)) orelse return null;
        return &self.entries.items[i];
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
            .owner = if (we.owner.len > 0) (a.dupe(u8, we.owner) catch @constCast("")) else @constCast(""),
            .group = if (we.group.len > 0) (a.dupe(u8, we.group) catch @constCast("")) else @constCast(""),
            .btime_ms = we.btime_ms,
            .nlink = we.nlink,
            .blocks = we.blocks,
            .children = we.children,
            .target = tgt,
            .tdir = we.tdir,
            .tags = tags,
            .attrs = attrs,
        };
    }

    /// Index of an existing entry for which `we` differs ONLY by
    /// `children` — the daemon's async child-count delta re-sends the
    /// stat it already shipped with the count filled in. Such an
    /// update is written in place by the caller: `children` is never
    /// a sort input, nothing reallocates, so bound rows stay valid
    /// and no listing rebuild is owed. Anything else returns null and
    /// takes the full upsert path.
    pub fn countOnlyIndex(self: *Dir, we: WireEntry) ?usize {
        if (we.children < 0) return null;
        const i = self.find(we.name) orelse return null;
        const e = &self.entries.items[i];
        if (e.children == we.children) return i;
        if (!std.mem.eql(u8, e.kind, we.kind)) return null;
        if (e.size != we.size or e.mode != we.mode) return null;
        if (e.mtime_ms != we.mtime_ms or e.ctime_ms != we.ctime_ms) return null;
        if (e.atime_ms != we.atime_ms or e.btime_ms != we.btime_ms) return null;
        if (e.uid != we.uid or e.gid != we.gid) return null;
        if (e.nlink != we.nlink or e.blocks != we.blocks) return null;
        if (e.tdir != we.tdir) return null;
        if (!std.mem.eql(u8, e.owner, we.owner)) return null;
        if (!std.mem.eql(u8, e.group, we.group)) return null;
        if (!std.mem.eql(u8, e.tags, we.tags)) return null;
        if ((e.target == null) != (we.target == null)) return null;
        if (e.target) |t| {
            if (!std.mem.eql(u8, t, we.target.?)) return null;
        }
        if (e.attrs.len != we.attrs.len) return null;
        for (e.attrs, we.attrs) |a, b| {
            if (!std.mem.eql(u8, a, b)) return null;
        }
        return i;
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
        if (self.sortableNow()) self.sort();
    }

    /// May a pushed delta re-sort this directory on its own?
    ///
    /// Only when the sort key is carried BY the delta. Media-column
    /// values are not: they come from a batched media_meta job and
    /// are stitched onto the entries by mediacols.applyValues at
    /// render time, so `own()` above hands back an entry with an
    /// EMPTY `meta`. Sorting here would order the fresh row by a
    /// value that provably is not there yet -- it sinks to the
    /// missing end and jumps back the moment renderTab re-stitches
    /// and re-sorts. Deferring costs nothing: renderTab's sort is
    /// the one the user ever sees, and skipping this one also drops
    /// an O(n log n) pass per delta on a busy directory.
    ///
    /// Everything else (name/size/mtime/kind and `user.*` xattr
    /// columns) rides the listing itself, so the delta path stays
    /// self-sufficient for it.
    fn sortableNow(self: *const Dir) bool {
        const col = self.attr_sort orelse return true;
        return col.source != .media;
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
                    return naturalLess(a.name, b.name);
                }
                return switch (ctx.key) {
                    .size => if (a.size != b.size) a.size < b.size else naturalLess(a.name, b.name),
                    .allocated => if (a.blocks != b.blocks) a.blocks < b.blocks else naturalLess(a.name, b.name),
                    .mtime => if (a.mtime_ms != b.mtime_ms) a.mtime_ms < b.mtime_ms else naturalLess(a.name, b.name),
                    .ctime => if (a.ctime_ms != b.ctime_ms) a.ctime_ms < b.ctime_ms else naturalLess(a.name, b.name),
                    .atime => if (a.atime_ms != b.atime_ms) a.atime_ms < b.atime_ms else naturalLess(a.name, b.name),
                    .btime => if (a.btime_ms != b.btime_ms) a.btime_ms < b.btime_ms else naturalLess(a.name, b.name),
                    .kind => if (!std.mem.eql(u8, a.kind, b.kind)) std.mem.lessThan(u8, a.kind, b.kind) else naturalLess(a.name, b.name),
                    .extension => blk: {
                        const ea = extensionOf(a.name);
                        const eb = extensionOf(b.name);
                        if (!std.ascii.eqlIgnoreCase(ea, eb)) break :blk std.ascii.lessThanIgnoreCase(ea, eb);
                        break :blk naturalLess(a.name, b.name);
                    },
                    .owner => blk: {
                        // Names when the host resolved both; ids otherwise.
                        if (a.owner.len > 0 and b.owner.len > 0 and !std.ascii.eqlIgnoreCase(a.owner, b.owner))
                            break :blk std.ascii.lessThanIgnoreCase(a.owner, b.owner);
                        if (a.uid != b.uid) break :blk a.uid < b.uid;
                        break :blk naturalLess(a.name, b.name);
                    },
                    .group => blk: {
                        if (a.group.len > 0 and b.group.len > 0 and !std.ascii.eqlIgnoreCase(a.group, b.group))
                            break :blk std.ascii.lessThanIgnoreCase(a.group, b.group);
                        if (a.gid != b.gid) break :blk a.gid < b.gid;
                        break :blk naturalLess(a.name, b.name);
                    },
                    .nlink => if (a.nlink != b.nlink) a.nlink < b.nlink else naturalLess(a.name, b.name),
                    .permissions => if (a.mode != b.mode) a.mode < b.mode else naturalLess(a.name, b.name),
                    .name => naturalLess(a.name, b.name),
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
    /// Full path selected once it appears in a streamed listing.
    pending_reveal: ?[]u8 = null,
    pending_reveal_host: ?[]u8 = null,
    /// Selection captured on button-down before GTK collapses it while
    /// deciding whether the gesture becomes a click or a drag.
    drag_selected: std.ArrayList([]u8) = .empty,
    rendering: bool = false,
    /// Hash of the listing the last render showed; a re-render of the
    /// SAME listing keeps its scroll position (render.zig
    /// keepScrollPosition), a navigation starts at the top.
    scroll_path_hash: u64 = 0,
    show_hidden: bool = false,
    view_mode: browser_model.ViewMode = .details,
    sort_key: browser_model.SortKey = .name,
    descending: bool = false,
    dirs_first: bool = true,
    /// Live view narrowing (filter-as-you-type); persisted per tab.
    filter: []u8 = &.{},
    /// Free space of the filesystem behind `root` (statfs bavail *
    /// frsize), null until the host answered. Refreshed with every
    /// root listing; the status line shows it.
    free_bytes: ?u64 = null,
    /// The in-flight statfs request (0 = none).
    free_req: u32 = 0,
    /// A filesystem mutation landed while statfs was in flight; issue
    /// one coalesced refresh after that reply instead of flooding one
    /// request per watcher delta.
    free_dirty: bool = false,
    virtual_spec: []u8 = &.{},
    /// The live/one-shot query filling this tab's flat rows, if any
    /// (search.zig). Per TAB, not per view: several live queries stay
    /// open and updating at once, and closing the tab cancels its own
    /// job so no recursive watcher outlives the rows it feeds.
    query: ?*TabQuery = null,
    /// Grouping, zoom and the collapsed-group set (views.zig).
    vs: TabView = .{},
    /// Sticky-click flag and visual-mode anchor (selection.zig).
    sel: TabSel = .{},
    page: *c.GtkWidget,
    /// The details/compact listing: ONE GtkColumnView owns the header
    /// and the rows (colview.zig), so their columns cannot disagree.
    colview: *c.GtkColumnView,
    /// Held so its raw-BTab signal can be disconnected before GTK's
    /// deferred column teardown outlives this tab.
    sorter: ?*c.GtkSorter = null,
    sorter_handler: c.gulong = 0,
    /// Flat item model the listing renders from; rebuilt by splice on
    /// every render (items borrow entries between renders).
    store: *c.GListStore = undefined,
    /// The GtkMultiSelection over `store`; `selected` mirrors it.
    selmodel: *c.GtkSelectionModel = undefined,
    /// Live path → bound-name-cell map (colview.zig): thumbnails land
    /// in place and inline rename finds its label through it. Keys
    /// borrow the bound item's owned path.
    name_cells: std.StringHashMapUnmanaged(*c.GtkWidget) = .empty,
    /// Signature of the column set the view currently shows;
    /// syncColumns rebuilds the columns only when it changes.
    col_sig: u64 = 0,
    /// Guards the GTK sorter/width callbacks against programmatic
    /// sync (syncColumns) re-entering as if the user acted.
    col_syncing: bool = false,
    /// Debounce source for persisting dragged column widths.
    width_save_src: c.guint = 0,
    /// Coalescing idle that re-fits the Name column after the listing
    /// viewport changed size (colview.zig). Sizes are only valid after
    /// allocation, so the work cannot run from the size signal itself.
    width_fit_src: c.guint = 0,
    /// Press coords of a possible click-on-empty-space (colview.zig
    /// clears the selection when it releases without travel).
    empty_press: ?struct { x: f64, y: f64 } = null,
    tab_label: *c.GtkLabel,
    /// Optional details columns, rendered in Column declaration order.
    columns: std.EnumSet(browser_model.Column) =
        std.EnumSet(browser_model.Column).initMany(&browser_model.default_columns),
    /// Extra columns the user added by KEY (owned, in display
    /// order). One list for both sources: `user.*` values ride the
    /// listing, `media.*`/`tag.*`/`exif.*`/`image.*`/`doc.*` values
    /// come from the batched media_meta job. colkeys.sourceOf tells
    /// them apart, so there is one add/remove/sort path, not two.
    attr_columns: std.ArrayList([]u8) = .empty,
    /// Widths the user dragged the fixed columns to; 0 means "use
    /// `Column.width()`". Read only through render.columnWidthOf, so
    /// a header button and its data cells cannot disagree.
    col_widths: std.EnumArray(browser_model.Column, i32) = .initFill(0),
    /// Dragged widths of the extra columns, indexed like
    /// `attr_columns`. Deliberately allowed to be SHORTER than that
    /// list (a restore fills the names first): a missing entry reads
    /// as the default width.
    attr_col_widths: std.ArrayList(i32) = .empty,
    /// Width the user dragged the Name column to; 0 = auto (the name
    /// takes all leftover width, the pre-resize behavior).
    name_width: i32 = 0,
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
    /// Shown INSTEAD of the rows when there are none: what an empty
    /// listing area means, in the listing area itself. A status-bar
    /// line is too easy to miss and the next render overwrites it.
    empty_box: *c.GtkWidget = undefined,
    empty_title: *c.GtkLabel = undefined,
    empty_detail: *c.GtkLabel = undefined,
    /// Why the last navigation from this tab was refused (owned), or
    /// null. Distinct from `root.load_error`: the tab still shows a
    /// perfectly good directory, so the listing area must NOT be
    /// replaced -- but the refusal still has to be said, on every
    /// render, until the next navigation lands.
    nav_error: ?[]u8 = null,
    /// Full paths (owned) whose entries changed content since the last
    /// render: renderList's windowed splice forces these rows to
    /// rebind even though their identity (path/depth/parity) matches.
    /// Overflow trades precision for correctness via `changed_all`.
    changed_paths: std.ArrayList([]u8) = .empty,
    changed_all: bool = false,

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

    /// Remember that a navigation was refused. Owned; replaced rather
    /// than stacked, since the newest refusal is the one the user just
    /// caused.
    pub fn setNavError(self: *BTab, msg: []const u8) void {
        const a = self.view.allocator;
        self.clearNavError();
        self.nav_error = a.dupe(u8, msg) catch null;
    }

    pub fn clearNavError(self: *BTab) void {
        const msg = self.nav_error orelse return;
        self.nav_error = null;
        self.view.allocator.free(msg);
    }

    /// Record one full path as content-changed for the next render's
    /// windowed splice. Any failure widens the window to everything —
    /// imprecision may cost a repaint, never a stale row.
    pub fn noteChangedFull(self: *BTab, full: []const u8) void {
        if (self.changed_all) return;
        const a = self.view.allocator;
        if (self.changed_paths.items.len >= 256) {
            self.changed_all = true;
            return;
        }
        for (self.changed_paths.items) |existing| {
            if (std.mem.eql(u8, existing, full)) return;
        }
        const owned = a.dupe(u8, full) catch {
            self.changed_all = true;
            return;
        };
        self.changed_paths.append(a, owned) catch {
            a.free(owned);
            self.changed_all = true;
        };
    }

    pub fn noteChanged(self: *BTab, dir: *const Dir, name: []const u8) void {
        var buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{
            if (dir.path.len == 1) "" else dir.path, name,
        }) catch {
            self.changed_all = true;
            return;
        };
        self.noteChangedFull(full);
    }

    pub fn clearChanged(self: *BTab) void {
        const a = self.view.allocator;
        for (self.changed_paths.items) |p| a.free(p);
        self.changed_paths.clearRetainingCapacity();
        self.changed_all = false;
    }

    pub fn deinit(self: *BTab) void {
        const a = self.view.allocator;
        if (self.sorter) |sorter| {
            if (self.sorter_handler != 0)
                c.g_signal_handler_disconnect(@ptrCast(sorter), self.sorter_handler);
            c.g_object_unref(sorter);
            self.sorter = null;
            self.sorter_handler = 0;
        }
        // Before anything else: a running query holds a host-side
        // recursive watcher, which must not outlive this tab.
        self.view.queryForget(self);
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
        if (self.pending_reveal) |path| a.free(path);
        if (self.pending_reveal_host) |host| a.free(host);
        for (self.drag_selected.items) |p| a.free(p);
        self.drag_selected.deinit(a);
        for (self.attr_columns.items) |name| a.free(name);
        self.attr_columns.deinit(a);
        self.attr_col_widths.deinit(a);
        self.name_cells.deinit(a);
        if (self.width_save_src != 0) _ = c.g_source_remove(self.width_save_src);
        if (self.width_fit_src != 0) _ = c.g_source_remove(self.width_fit_src);
        if (self.filter.len > 0) a.free(self.filter);
        if (self.virtual_spec.len > 0) a.free(self.virtual_spec);
        self.clearChanged();
        self.changed_paths.deinit(a);
        self.clearNavError();
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

/// Everything needed to resubmit a cross-host copy. The panel's
/// `JobPaths` cannot serve: it keeps only a 512-byte TAIL of each
/// path, which identifies a file but cannot address one.
///
/// A resubmission always carries `resume`, so it continues from the
/// staged `.skpart` the failed attempt left on the destination rather
/// than starting a multi-gigabyte transfer over.
pub const CopyRetry = struct {
    coordinator: *HostConn,
    src_hc: *HostConn,
    dst_hc: *HostConn,
    src_path: []u8,
    dst_path: []u8,
    label: []u8,
    /// Persistent record identity. The record outlives this pane;
    /// each daemon attempt uses the record's separately-rotated token.
    token: []u8,
    batch_id: u64 = 0,
    batch_total: usize = 0,
    dest_key: u64,
    /// Automatic attempts already spent, so a host that is simply gone
    /// stops costing retries and the row settles as failed.
    attempts: u8 = 0,
    /// A MOVE: the helper deletes the verified source (delete_src).
    move: bool = false,
    no_replace: bool = false,
    /// The coordinator is a REMOTE daemon dialing its peer directly.
    /// An "unreachable" failure re-coordinates through the local
    /// daemon instead of burning resume attempts.
    direct: bool = false,

    pub fn destroy(self: *CopyRetry, allocator: std.mem.Allocator) void {
        allocator.free(self.src_path);
        allocator.free(self.dst_path);
        allocator.free(self.label);
        allocator.free(self.token);
        allocator.destroy(self);
    }

    pub fn clone(self: *const CopyRetry, allocator: std.mem.Allocator) ?*CopyRetry {
        const out = allocator.create(CopyRetry) catch return null;
        const src = allocator.dupe(u8, self.src_path) catch {
            allocator.destroy(out);
            return null;
        };
        const dst = allocator.dupe(u8, self.dst_path) catch {
            allocator.free(src);
            allocator.destroy(out);
            return null;
        };
        const label = allocator.dupe(u8, self.label) catch {
            allocator.free(src);
            allocator.free(dst);
            allocator.destroy(out);
            return null;
        };
        const token = allocator.dupe(u8, self.token) catch {
            allocator.free(src);
            allocator.free(dst);
            allocator.free(label);
            allocator.destroy(out);
            return null;
        };
        out.* = .{
            .coordinator = self.coordinator,
            .src_hc = self.src_hc,
            .dst_hc = self.dst_hc,
            .src_path = src,
            .dst_path = dst,
            .label = label,
            .token = token,
            .batch_id = self.batch_id,
            .batch_total = self.batch_total,
            .dest_key = self.dest_key,
            .attempts = self.attempts,
            .move = self.move,
            .no_replace = self.no_replace,
            .direct = self.direct,
        };
        return out;
    }
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

    pub fn copyTail(buf: *[512]u8, text: []const u8) u16 {
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
    /// Nonzero when this job is one item in a user paste/drop batch.
    batch_id: u64 = 0,
    batch_total: usize = 0,
    done: u64 = 0,
    total: u64 = 0,
    /// Bytes a staged partial contributed (sticky).
    resumed_from: u64 = 0,
    /// The entry the daemon says the job is working on right now, and
    /// the entry counters of a tree operation.
    current_file: [512]u8 = undefined,
    current_file_len: u16 = 0,
    files_done: u64 = 0,
    files_total: u64 = 0,
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
    /// Last thing the daemon said about this job: the failure reason on
    /// a terminal event, and on a running one the reason it is not
    /// advancing (a cross-host copy waiting on a reconnect).
    message: [256]u8 = undefined,
    message_len: u16 = 0,
    /// Everything needed to run this job AGAIN. Only cross-host copies
    /// carry it: they are the ones that can die from a dropped link
    /// with a verified partial already staged, so "Retry" is a resume.
    retry: ?*CopyRetry = null,
    /// A resume for this failed copy is armed or already running, so
    /// the row offers no Retry button (pressing it would double the
    /// copy) and disappears once the new attempt's row lands.
    retry_scheduled: bool = false,

    pub fn terminal(self: *const JobRow) bool {
        return self.state == .finished or self.state == .failed or self.state == .canceled;
    }

    pub fn messageText(self: *const JobRow) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn setMessage(self: *JobRow, text: []const u8) void {
        const n = @min(text.len, self.message.len);
        @memcpy(self.message[0..n], text[0..n]);
        self.message_len = @intCast(n);
    }

    pub fn currentFile(self: *const JobRow) []const u8 {
        return self.current_file[0..self.current_file_len];
    }

    pub fn setCurrentFile(self: *JobRow, path: []const u8) void {
        self.current_file_len = JobPaths.copyTail(&self.current_file, path);
    }
};

/// A job-start request awaiting its reply (which carries the id).
pub const PendingJob = struct {
    req: u32,
    hc: *HostConn,
    label: []u8,
    batch_id: u64 = 0,
    batch_total: usize = 0,
    kind: enum { normal, query, compare_left, compare_right, calc_size, dup_scan, archive_list } = .normal,
    /// The tab whose query this job feeds (`.query` only). Validated
    /// with `tabAlive` before use: a tab can close between the start
    /// request and its reply.
    tab: ?*BTab = null,
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
    /// Cross-host copies only; moves onto the JobRow with the id.
    retry: ?*CopyRetry = null,
};

/// One client-mediated cross-host transfer, running or queued.
pub const ActiveTransfer = struct {
    x: *fstransfer.Xfer,
    src_hc: *HostConn,
    dst_hc: *HostConn,
    label: []u8,
    batch_id: u64 = 0,
    batch_total: usize = 0,
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
    /// Ordinary durable copy/move using the mediated fallback.
    user_copy: bool = false,
    /// Queue state: transfers to one destination run one at a time,
    /// the rest wait here in order (see filebrowser/xferqueue.zig).
    started: bool = false,
    /// User-held. A started one stops at its next chunk boundary; an
    /// unstarted one is simply not admitted by the queue. Persisted
    /// through `token`, so the hold survives a GUI restart.
    paused: bool = false,
    /// Durable ledger record for this transfer (owned), null when it
    /// is not recorded (sync-back uploads, or no ledger at all).
    token: ?[]u8 = null,
    /// Scheduler identity of the destination (host plus local device).
    dest_key: u64 = 0,

    pub fn freeExtras(t: *ActiveTransfer, allocator: std.mem.Allocator) void {
        if (t.open_with_appid) |s| allocator.free(s);
        if (t.watch_host) |s| allocator.free(s);
        if (t.watch_remote) |s| allocator.free(s);
        if (t.token) |s| allocator.free(s);
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
/// rmdir_created: a = the directory mkdir created;
/// link_created: a = the link created, b = its target, p = the verb
/// ("symlink" or "hardlink") that redo must repeat.
pub const UndoOp = struct {
    host: ?[]u8,
    kind: enum { rename_back, delete_created, trash_restore, rmdir_created, link_created },
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
            .link_created => "undo link creation",
        };
    }
};

/// A plain-op undo record waiting for its ok reply.
pub const PendingUndo = struct {
    req: u32,
    op: *UndoOp,
    no_replace: bool = false,
};

pub const HistoryDirection = enum { undo, redo };

pub const PendingHistory = struct {
    req: u32,
    hc: *HostConn,
    op: *UndoOp,
    direction: HistoryDirection,
};

pub const HostAction = *const fn (ctx: *anyopaque, host: []const u8, path: []const u8) void;

test "JobRow keeps the identifying TAIL of an over-long current file" {
    const t = std.testing;
    var row: JobRow = .{ .hc = undefined, .job = 1, .label = @constCast("copy") };
    try t.expectEqualStrings("", row.currentFile());
    row.setCurrentFile("/srv/data/report.pdf");
    try t.expectEqualStrings("/srv/data/report.pdf", row.currentFile());

    var long: [900]u8 = @splat('a');
    @memcpy(long[long.len - 9 ..], "/last.bin");
    row.setCurrentFile(&long);
    const kept = row.currentFile();
    try t.expectEqual(@as(usize, 512), kept.len);
    try t.expectEqualStrings("...", kept[0..3]);
    // The part that names the file survives; the head does not.
    try t.expectEqualStrings("/last.bin", kept[kept.len - 9 ..]);
}

/// A listing entry owned by `a`, for the Dir tests below and for
/// nav.zig's entryForPath test.
pub fn testEntry(a: std.mem.Allocator, name: []const u8, target: ?[]const u8) !Entry {
    return .{
        .name = try a.dupe(u8, name),
        .kind = try a.dupe(u8, "file"),
        .size = 0,
        .mode = 0,
        .mtime_ms = 0,
        .target = if (target) |t| try a.dupe(u8, t) else null,
        .tdir = false,
    };
}

fn freeTestDir(dir: *Dir) void {
    for (dir.entries.items) |*e| e.deinit(dir.allocator);
    dir.entries.deinit(dir.allocator);
}

test "Dir keeps the reason a listing failed, and frees it exactly once" {
    const t = std.testing;
    const a = t.allocator;
    var dir = Dir{ .allocator = a, .path = @constCast("/data"), .view_id = 1 };
    defer freeTestDir(&dir);

    try t.expect(dir.load_error == null);
    dir.setLoadError("no such file or directory");
    try t.expectEqualStrings("no such file or directory", dir.load_error.?);
    // Replacing frees the old one (a leak here would fail the test
    // allocator), and clearing leaves nothing behind.
    dir.setLoadError("permission denied");
    try t.expectEqualStrings("permission denied", dir.load_error.?);
    dir.clearLoadError();
    try t.expect(dir.load_error == null);
    // Clearing twice is harmless.
    dir.clearLoadError();

    // Out of memory still marks the failure -- a listing may never
    // fall back to looking empty -- with a STATIC message that
    // clearLoadError must not hand to the allocator.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var poor = Dir{ .allocator = failing.allocator(), .path = @constCast("/data"), .view_id = 2 };
    poor.setLoadError("permission denied");
    try t.expect(poor.load_error != null);
    try t.expect(poor.load_error.?.ptr == LOAD_ERROR_OOM.ptr);
    poor.clearLoadError();
    try t.expect(poor.load_error == null);
}

test "findPath resolves an ordinary child, and rejects a foreign parent" {
    const t = std.testing;
    const a = t.allocator;
    var dir = Dir{ .allocator = a, .path = @constCast("/data"), .view_id = 1 };
    defer freeTestDir(&dir);
    try dir.entries.append(a, try testEntry(a, "one.txt", null));
    try dir.entries.append(a, try testEntry(a, "two.txt", null));

    try t.expectEqualStrings("two.txt", (dir.findPath("/data/two.txt") orelse return error.NotFound).name);
    // A different directory's child never resolves here.
    try t.expect(dir.findPath("/other/two.txt") == null);
    try t.expect(dir.findPath("/data/missing.txt") == null);
    try t.expect(dir.findPath("relative") == null);
}

test "findPath resolves a FLAT row by its target, not by its parent" {
    const t = std.testing;
    const a = t.allocator;
    var dir = Dir{ .allocator = a, .path = @constCast("/search"), .view_id = 1 };
    dir.flat = true;
    defer freeTestDir(&dir);
    // Search hits keep their own name but live anywhere.
    try dir.entries.append(a, try testEntry(a, "hit.txt", "/srv/deep/nested/hit.txt"));
    try dir.entries.append(a, try testEntry(a, "other.txt", "/tmp/other.txt"));

    const hit = dir.findPath("/srv/deep/nested/hit.txt") orelse return error.NotFound;
    try t.expectEqualStrings("hit.txt", hit.name);
    // The dirname-derived form is exactly what used to be asked, and
    // it must NOT match: the row is not a child of the flat dir.
    try t.expect(dir.findPath("/search/hit.txt") == null);
}

test "an ordinary dir never resolves a path through a symlink's target" {
    const t = std.testing;
    const a = t.allocator;
    var dir = Dir{ .allocator = a, .path = @constCast("/data"), .view_id = 1 };
    defer freeTestDir(&dir);
    // `target` on a normal listing row is the SYMLINK's destination.
    // Matching on it would hand back the link when asked about the
    // file it points at, so the target scan is flat-dirs only.
    try dir.entries.append(a, try testEntry(a, "link", "/etc/passwd"));
    try t.expect(dir.findPath("/etc/passwd") == null);
    try t.expectEqualStrings("link", (dir.findPath("/data/link") orelse return error.NotFound).name);
}

test "countOnlyIndex accepts the daemon's count re-send and nothing else" {
    const t = std.testing;
    const a = t.allocator;
    var dir = Dir{ .allocator = a, .path = @constCast("/d"), .view_id = 1 };
    defer freeTestDir(&dir);
    var sub = try testEntry(a, "sub", null);
    a.free(sub.kind);
    sub.kind = try a.dupe(u8, "dir");
    sub.tdir = true;
    sub.mtime_ms = 111;
    try dir.entries.append(a, sub);
    try dir.entries.append(a, try testEntry(a, "plain.txt", null));

    // The daemon's async count delta: the SAME stat it already
    // shipped, with children filled in. Fast path.
    const count_resend = WireEntry{ .name = "sub", .kind = "dir", .tdir = true, .mtime_ms = 111, .children = 7 };
    try t.expectEqual(@as(?usize, 0), dir.countOnlyIndex(count_resend));

    // A count for an entry we never saw is structural.
    try t.expectEqual(@as(?usize, null), dir.countOnlyIndex(.{ .name = "ghost", .kind = "dir", .tdir = true, .children = 3 }));
    // No count at all is never the fast path (a watch delta).
    try t.expectEqual(@as(?usize, null), dir.countOnlyIndex(.{ .name = "sub", .kind = "dir", .tdir = true, .mtime_ms = 111 }));
    // A count riding a REAL change (mtime moved) is structural: the
    // in-place write would hide the change from the sort.
    try t.expectEqual(@as(?usize, null), dir.countOnlyIndex(.{ .name = "sub", .kind = "dir", .tdir = true, .mtime_ms = 222, .children = 7 }));
    // Same count again is still the fast (no-op) path.
    dir.entries.items[0].children = 7;
    try t.expectEqual(@as(?usize, 0), dir.countOnlyIndex(count_resend));
}

test "upsert defers the sort for a media column and performs it otherwise" {
    const t = std.testing;
    const a = t.allocator;
    var dir = Dir{ .allocator = a, .path = @constCast("/d"), .view_id = 1 };
    dir.dirs_first = false;
    defer freeTestDir(&dir);
    try dir.entries.append(a, try testEntry(a, "m.txt", null));
    try dir.entries.append(a, try testEntry(a, "z.txt", null));

    // Media column: the row's values are stitched on at RENDER time,
    // so `own()` hands back an empty `meta` and sorting now would
    // rank the fresh row by a value that is not there yet.
    dir.attr_sort = .{ .source = .media, .index = 0, .kind = .text };
    dir.upsert(.{ .name = "a.txt", .kind = "file" });
    try t.expectEqual(@as(usize, 3), dir.entries.items.len);
    try t.expectEqualStrings("a.txt", dir.entries.items[2].name);

    // An xattr column's values ride the listing itself, so the delta
    // path stays self-sufficient and sorts immediately.
    dir.attr_sort = .{ .source = .xattr, .index = 0, .kind = .text };
    dir.upsert(.{ .name = "b.txt", .kind = "file" });
    try t.expectEqualStrings("a.txt", dir.entries.items[0].name);
    try t.expectEqualStrings("b.txt", dir.entries.items[1].name);

    // No extra column at all: ordinary keys always sort on the delta.
    dir.attr_sort = null;
    dir.upsert(.{ .name = "aa.txt", .kind = "file" });
    try t.expectEqualStrings("a.txt", dir.entries.items[0].name);
    try t.expectEqualStrings("aa.txt", dir.entries.items[1].name);
}
