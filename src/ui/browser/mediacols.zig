//! Media-metadata columns: the client half of the daemon's batched
//! `media_meta` extractor.
//!
//! An extended-attribute column rides the listing, so it costs
//! nothing extra per row. A media column cannot: the values come
//! from reading file bytes, and that has to happen on the host that
//! owns them. So this module asks for the rows the user can actually
//! SEE (plus a fixed overscan), in ONE batch at a time, coalesced
//! behind a short timer and cancelled on navigation. That bound is
//! the whole point of the daemon-side design -- never one request
//! per row, and never a job stream that grows with the directory.
//!
//! Values land asynchronously and are stitched onto the entries by
//! `applyValues` before each render, so a row fills in when its
//! answer arrives without anything ever blocking the GLib loop.
//!
//! What a key MEANS (source, ordering, label, display form) is not
//! here: that is src/filebrowser/colkeys.zig, which both column
//! sources share.

const std = @import("std");
const c = @import("../../c.zig").c;
const colkeys = @import("../../filebrowser/colkeys.zig");
const fsdrive = @import("../../ipc/fsdrive.zig");
const wire = @import("../../mux/wire.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Dir = @import("types.zig").Dir;
const Entry = @import("types.zig").Entry;
const HostConn = @import("types.zig").HostConn;
const colview = @import("colview.zig");
const WireJobEv = @import("types.zig").WireJobEv;
const WireReply = @import("types.zig").WireReply;
const isPreviewMediaName = @import("../../filebrowser/paths.zig").isPreviewMediaName;
const cast = @import("../../util/cast.zig");

/// Files whose metadata is remembered. Each row is a handful of
/// short strings, and re-entering a folder should not re-extract.
pub const CACHE_ROWS: usize = 4096;

/// Scroll settle before a batch goes out. Long enough that dragging
/// a scrollbar across a directory produces one request, short enough
/// that it feels immediate when you stop.
pub const COALESCE_MS: u32 = 120;

/// Extra files a media-column SORT may pull in beyond the visible
/// window, across all its batches. Sorting by a value nobody has
/// read is useless, but a whole-directory read is exactly the
/// unbounded stream this design exists to prevent -- so the fill is
/// user-initiated (clicking the header), bounded, and reported.
pub const SORT_FILL_MAX: usize = 512;

/// Bytes of separator-joined names one request may carry. The daemon
/// refuses more than 16K; this leaves room for the frame's own JSON.
const BATCH_BYTES_MAX: usize = 15 * 1024;

pub const Field = struct {
    k: []u8,
    v: []u8,
};

/// One file's answer. An EMPTY field set is a real answer ("the host
/// found no metadata"), not a miss: without it a file the extractor
/// cannot read would be re-requested on every scroll forever.
pub const Row = struct {
    fields: []Field,

    fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        for (self.fields) |f| {
            allocator.free(f.k);
            allocator.free(f.v);
        }
        if (self.fields.len > 0) allocator.free(self.fields);
    }

    pub fn get(self: Row, key: []const u8) ?[]const u8 {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.k, key)) return f.v;
        }
        return null;
    }
};

/// Everything the media columns own. One BrowserView field rather
/// than a scalar per concern.
pub const State = struct {
    /// key ("host\x00path\x00mtime") -> answer. The map owns its keys.
    rows: std.StringHashMap(Row) = undefined,
    /// Insertion order for drop-oldest eviction (borrowed key refs).
    order: std.ArrayList([]const u8) = .empty,
    /// The one batch in flight: its request nonce, then its job id.
    req: u32 = 0,
    job: u64 = 0,
    hc: ?*HostConn = null,
    /// Cache keys the in-flight batch asked about (owned). Whatever
    /// the daemon does not answer for is recorded as an empty row on
    /// the terminal event, so a skipped file is asked about once.
    asked: std.ArrayList([]u8) = .empty,
    /// Navigation happened while the batch's reply was outstanding:
    /// cancel as soon as the job id is known.
    cancel_pending: bool = false,
    /// Coalescing timer (0 = none).
    timer: c.guint = 0,
    /// Files a media-column sort may still pull in beyond the window.
    sort_budget: usize = 0,
    /// Requests actually put on a daemon connection. The bound this
    /// module exists to enforce is only meaningful if it is counted.
    requests: u64 = 0,

    pub fn init(self: *State, allocator: std.mem.Allocator) void {
        self.rows = std.StringHashMap(Row).init(allocator);
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        var it = self.rows.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(allocator);
        }
        self.rows.deinit();
        self.order.deinit(allocator);
        for (self.asked.items) |k| allocator.free(k);
        self.asked.deinit(allocator);
    }

    fn put(self: *State, allocator: std.mem.Allocator, key: []const u8, row: Row) void {
        var mut = row;
        if (self.rows.getPtr(key)) |existing| {
            existing.deinit(allocator);
            existing.* = row;
            return;
        }
        const owned = allocator.dupe(u8, key) catch {
            mut.deinit(allocator);
            return;
        };
        self.rows.put(owned, row) catch {
            allocator.free(owned);
            mut.deinit(allocator);
            return;
        };
        self.order.append(allocator, owned) catch {};
        while (self.order.items.len > CACHE_ROWS) {
            const oldest = self.order.orderedRemove(0);
            if (self.rows.fetchRemove(oldest)) |kv| {
                var dead = kv.value;
                dead.deinit(allocator);
                allocator.free(kv.key);
            }
        }
    }
};

/// Cache identity: host, path and mtime, so an edited file is never
/// shown from the answer for its previous contents.
fn cacheKey(buf: []u8, hc: *HostConn, path: []const u8, mtime_ms: i64) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}\x00{s}\x00{d}", .{ hc.host orelse "", path, mtime_ms }) catch null;
}

/// The tab's media column keys, in column order, written into `out`.
fn mediaColumns(tab: *BTab, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (tab.attr_columns.items) |name| {
        if (n >= out.len) break;
        if (colkeys.sourceOf(name) != .media) continue;
        out[n] = name;
        n += 1;
    }
    return out[0..n];
}

/// Whether the tab shows any media column at all. Nothing in this
/// module runs for a tab that does not.
pub fn tabWantsMedia(tab: *BTab) bool {
    for (tab.attr_columns.items) |name| {
        if (colkeys.sourceOf(name) == .media) return true;
    }
    return false;
}

// --- stitching answers onto entries ----------------------------

/// Fill every entry's `meta` from the cache, in media-column order.
///
/// Entries with no answer keep an EMPTY meta array rather than an
/// array of empty strings: in a directory of thousands only the
/// fetched window has values, and the readers already treat a short
/// array as "no value" (`i < e.meta.len`).
pub fn applyValues(self: *BrowserView, tab: *BTab) void {
    var col_buf: [MAX_MEDIA_COLUMNS][]const u8 = undefined;
    const cols = mediaColumns(tab, &col_buf);
    applyToDir(self, tab, tab.root, cols);
    for (tab.subdirs.items) |d| applyToDir(self, tab, d, cols);
    for (tab.ancestors.items) |d| applyToDir(self, tab, d, cols);
}

fn applyToDir(self: *BrowserView, tab: *BTab, dir: *Dir, cols: []const []const u8) void {
    const a = self.allocator;
    for (dir.entries.items) |*e| {
        if (cols.len == 0) {
            dropMeta(a, tab, dir, e);
            continue;
        }
        var path_buf: [4096]u8 = undefined;
        const full = dir.fullPath(e.*, &path_buf) orelse {
            dropMeta(a, tab, dir, e);
            continue;
        };
        var key_buf: [4300]u8 = undefined;
        const key = cacheKey(&key_buf, tab.hc, full, e.mtime_ms) orelse {
            dropMeta(a, tab, dir, e);
            continue;
        };
        const row = self.media.rows.get(key) orelse {
            // No answer yet: leave the row value-less rather than
            // allocating an empty array per entry.
            dropMeta(a, tab, dir, e);
            continue;
        };
        const values = a.alloc([]u8, cols.len) catch continue;
        var filled: usize = 0;
        for (cols, 0..) |col, i| {
            const raw = row.get(col) orelse "";
            values[i] = a.dupe(u8, raw) catch {
                for (values[0..filled]) |owned| a.free(owned);
                a.free(values);
                break;
            };
            filled += 1;
        }
        if (filled != cols.len) continue;
        // Value change detection feeds the windowed splice: a row
        // whose meta just arrived (or changed) must rebind, and
        // identity alone cannot see it.
        const changed = blk: {
            if (e.meta.len != values.len) break :blk true;
            for (e.meta, values) |old_v, new_v| {
                if (!std.mem.eql(u8, old_v, new_v)) break :blk true;
            }
            break :blk false;
        };
        if (changed) tab.noteChangedFull(full);
        freeMeta(a, e);
        e.meta = values;
    }
}

/// Clear a row's meta; a row that HAD values must rebind (its cells
/// still show them).
fn dropMeta(a: std.mem.Allocator, tab: *BTab, dir: *Dir, e: *Entry) void {
    if (e.meta.len == 0) return;
    var path_buf: [4096]u8 = undefined;
    if (dir.fullPath(e.*, &path_buf)) |full| tab.noteChangedFull(full);
    freeMeta(a, e);
}

fn freeMeta(allocator: std.mem.Allocator, e: *Entry) void {
    if (e.meta.len == 0) return;
    for (e.meta) |v| allocator.free(v);
    allocator.free(e.meta);
    e.meta = &.{};
}

/// Media columns one tab may carry. The overall column cap is lower
/// (render.MAX_ATTR_COLUMNS); this is just the stack buffer's size.
const MAX_MEDIA_COLUMNS = 8;

/// How many of `dir`'s entries actually have a value for the sorted
/// media column -- what the status line reports, so "sorted by
/// Duration" never implies every row was read.
pub fn valuedCount(tab: *BTab) struct { have: usize, total: usize } {
    const idx = tab.attr_sort orelse return .{ .have = 0, .total = 0 };
    if (idx >= tab.attr_columns.items.len) return .{ .have = 0, .total = 0 };
    const sub = colkeys.subIndex(namesOf(tab), idx);
    var have: usize = 0;
    var total: usize = 0;
    for (tab.root.entries.items) |e| {
        if (e.tdir) continue;
        total += 1;
        if (sub < e.meta.len and e.meta[sub].len > 0) have += 1;
    }
    return .{ .have = have, .total = total };
}

/// The tab's column names as the const slice-of-slices colkeys takes.
pub fn namesOf(tab: *BTab) []const []const u8 {
    return tab.attr_columns.items;
}

// --- the bounded fetch -----------------------------------------

/// Ask again soon. Every caller (render, scroll, a landed batch)
/// goes through the same coalescing timer, so a scroll that crosses
/// a thousand rows still produces one request when it settles.
pub fn schedule(self: *BrowserView) void {
    if (self.media.timer != 0) return;
    self.media.timer = c.g_timeout_add(COALESCE_MS, @ptrCast(&onTimer), @ptrCast(self));
}

fn onTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(BrowserView, user);
    self.media.timer = 0;
    pump(self);
    return 0;
}

/// Connect the tab's scroller once, so scrolling re-arms the fetch.
/// Idempotent via a qdata flag: renderTab runs on every listing.
pub fn ensureScrollWatch(self: *BrowserView, tab: *BTab) void {
    const sw: *c.GtkScrolledWindow = @ptrCast(@alignCast(tab.scroller));
    const adj = c.gtk_scrolled_window_get_vadjustment(sw) orelse return;
    if (c.g_object_get_data(@ptrCast(adj), "sketerm-media-scroll") != null) return;
    c.g_object_set_data(@ptrCast(adj), "sketerm-media-scroll", @ptrCast(self));
    _ = c.g_signal_connect_data(adj, "value-changed", @ptrCast(&onScrolled), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
}

fn onScrolled(_: *c.GtkAdjustment, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(BrowserView, user);
    if (self.currentTab()) |tab| {
        if (tabWantsMedia(tab)) schedule(self);
    }
}

/// One candidate row: what the listbox is showing, in display order.
const Candidate = struct {
    path: []const u8,
    mtime_ms: i64,
};

/// Full path -> mtime for every entry the tab has live, built once
/// per pump.
///
/// The cache key mixes the mtime in, and it MUST be derived the same
/// way when asking, when storing and when stitching values back on
/// -- a flat search row's path comes from its `target`, not from its
/// parent directory, so deriving the mtime from the path afterwards
/// silently produced a different key and the values never appeared.
const PathIndex = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMap(i64),

    fn build(allocator: std.mem.Allocator, tab: *BTab) PathIndex {
        var self = PathIndex{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .map = undefined,
        };
        self.map = std.StringHashMap(i64).init(allocator);
        self.addDir(tab.root);
        for (tab.subdirs.items) |d| self.addDir(d);
        for (tab.ancestors.items) |d| self.addDir(d);
        return self;
    }

    fn addDir(self: *PathIndex, dir: *Dir) void {
        const a = self.arena.allocator();
        for (dir.entries.items) |e| {
            var buf: [4096]u8 = undefined;
            const full = dir.fullPath(e, &buf) orelse continue;
            const owned = a.dupe(u8, full) catch continue;
            self.map.put(owned, e.mtime_ms) catch {};
        }
    }

    fn mtimeOf(self: *const PathIndex, path: []const u8) i64 {
        return self.map.get(path) orelse 0;
    }

    fn deinit(self: *PathIndex) void {
        self.map.deinit();
        self.arena.deinit();
    }
};

/// Drop the in-flight batch (navigation, column change, host death).
pub fn cancel(self: *BrowserView) void {
    const st = &self.media;
    if (st.job != 0) {
        if (st.hc) |hc| {
            if (hc.state == .ready)
                self.sendOp(hc, .{ .req = @as(u32, 0), .op = "job_cancel", .job = st.job });
        }
    } else if (st.req != 0) {
        // The job id is not known yet; cancel when the reply lands.
        st.cancel_pending = true;
        return;
    }
    clearInflight(self);
}

fn clearInflight(self: *BrowserView) void {
    const st = &self.media;
    st.req = 0;
    st.job = 0;
    st.hc = null;
    st.cancel_pending = false;
    for (st.asked.items) |k| self.allocator.free(k);
    st.asked.clearRetainingCapacity();
}

/// Navigation: stop the current batch and forget any sort fill. The
/// cache itself survives, so going back is instant.
pub fn resetForNavigation(self: *BrowserView) void {
    self.media.sort_budget = 0;
    cancel(self);
}

pub fn hostDied(self: *BrowserView, hc: *HostConn) void {
    if (self.media.hc == hc) clearInflight(self);
}

/// A media column header was clicked: allow a bounded read-ahead so
/// the sort covers more than the rows that happen to be on screen.
pub fn beginSortFill(self: *BrowserView) void {
    self.media.sort_budget = SORT_FILL_MAX;
    schedule(self);
}

fn pump(self: *BrowserView) void {
    const st = &self.media;
    if (st.req != 0 or st.job != 0) return;
    const tab = self.currentTab() orelse return;
    if (!tabWantsMedia(tab)) return;
    const hc = tab.hc;
    if (hc.state != .ready) return;

    var index = PathIndex.build(self.allocator, tab);
    defer index.deinit();

    var rows_buf: [ROW_SCAN_MAX]Candidate = undefined;
    const rows = collectRows(tab, &index, &rows_buf);
    if (rows.len == 0) return;

    const vis = visibleRange(tab, rows.len);
    const window = colkeys.fetchWindow(vis.first, vis.count, rows.len);

    var names: std.ArrayList(Candidate) = .empty;
    defer names.deinit(self.allocator);
    var bytes: usize = 0;
    collectNames(
        self,
        tab,
        rows[@min(window.first, rows.len)..@min(window.end(), rows.len)],
        &names,
        &bytes,
        colkeys.FETCH_BATCH_MAX,
    );
    // The visible window is satisfied; a user-initiated media sort
    // may pull in a bounded amount beyond it.
    if (names.items.len == 0 and st.sort_budget > 0) {
        const cap = @min(st.sort_budget, colkeys.FETCH_BATCH_MAX);
        collectNames(self, tab, rows, &names, &bytes, cap);
        // A pass that finds nothing left to ask about ends the fill;
        // otherwise the timer would re-arm forever.
        st.sort_budget = if (names.items.len == 0) 0 else st.sort_budget -| names.items.len;
    }
    if (names.items.len == 0) return;

    sendBatch(self, tab, names.items);
}

/// Rows one pump inspects. Well past any plausible viewport, and it
/// is only a scan bound: the REQUEST bound is fetchWindow's.
const ROW_SCAN_MAX: usize = 4096;

/// Rows currently in the item model, in display order. The model IS
/// the display (grouping, filtering, expanded subdirs and flat
/// search results all resolve into it), so reading it avoids a
/// second, divergent idea of what the user sees.
fn collectRows(tab: *BTab, index: *const PathIndex, out: []Candidate) []Candidate {
    var n: usize = 0;
    const total = colview.itemCount(tab);
    var i: c.guint = 0;
    while (i < total) : (i += 1) {
        if (n >= out.len) break;
        const d = colview.itemDataAt(tab, i) orelse continue;
        if (d.kind != .entry or d.is_dir) continue;
        // Only files the host-side extractor covers. Asking about a
        // source tree's worth of .zig files would be host IO spent
        // to learn nothing.
        if (!isPreviewMediaName(d.path)) continue;
        out[n] = .{ .path = d.path, .mtime_ms = index.mtimeOf(d.path) };
        n += 1;
    }
    return out[0..n];
}

const VisibleRange = struct { first: usize, count: usize };

/// Which of `total` candidate rows the viewport shows. Only BOUND
/// cells have geometry (the column view recycles); scrolled-away
/// candidates simply have no bound cell, which is exactly "not
/// visible". Before the first allocation nothing is bound yet, so
/// the range degrades to the TOP of the list -- still a fixed-size
/// window, and the next settle corrects it.
fn visibleRange(tab: *BTab, total: usize) VisibleRange {
    const height = c.gtk_widget_get_height(tab.scroller);
    if (height <= 0) return .{ .first = 0, .count = 0 };
    var first: ?usize = null;
    var last: usize = 0;
    const n = colview.itemCount(tab);
    var i: c.guint = 0;
    var idx: usize = 0;
    while (i < n) : (i += 1) {
        const d = colview.itemDataAt(tab, i) orelse continue;
        if (d.kind != .entry or d.is_dir or !isPreviewMediaName(d.path)) continue;
        defer idx += 1;
        if (idx >= total) break;
        const root = tab.name_cells.get(d.path) orelse continue;
        var bounds: c.graphene_rect_t = undefined;
        if (c.gtk_widget_compute_bounds(root, tab.scroller, &bounds) == 0) continue;
        const top = bounds.origin.y;
        const bottom = top + bounds.size.height;
        if (bottom <= 0 or top >= @as(f32, @floatFromInt(height))) continue;
        if (first == null) first = idx;
        last = idx;
    }
    const f = first orelse return .{ .first = 0, .count = 0 };
    return .{ .first = f, .count = last - f + 1 };
}

fn collectNames(
    self: *BrowserView,
    tab: *BTab,
    rows: []const Candidate,
    names: *std.ArrayList(Candidate),
    bytes: *usize,
    cap: usize,
) void {
    for (rows) |cand| {
        if (names.items.len >= cap) return;
        var key_buf: [4300]u8 = undefined;
        const key = cacheKey(&key_buf, tab.hc, cand.path, cand.mtime_ms) orelse continue;
        // An answer already in hand, INCLUDING an empty one, is
        // never asked about again.
        if (self.media.rows.contains(key)) continue;
        if (bytes.* + cand.path.len + 1 > BATCH_BYTES_MAX) return;
        names.append(self.allocator, cand) catch return;
        bytes.* += cand.path.len + 1;
    }
}

/// Names travel as ABSOLUTE paths (the job helper takes those as-is),
/// so one batch may span an expanded subdirectory or a flat search
/// result without splitting into a request per directory.
fn sendBatch(self: *BrowserView, tab: *BTab, names: []const Candidate) void {
    const st = &self.media;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(self.allocator);
    for (names, 0..) |cand, i| {
        if (i > 0) joined.append(self.allocator, fsdrive.MEDIA_SEP) catch return;
        joined.appendSlice(self.allocator, cand.path) catch return;
    }
    // Remember the exact keys asked for BEFORE sending: the answers
    // are matched back against THESE (never re-derived), and the
    // terminal event records an empty answer for whatever the daemon
    // skipped, so an unreadable file is asked about once.
    for (names) |cand| {
        var key_buf: [4300]u8 = undefined;
        const key = cacheKey(&key_buf, tab.hc, cand.path, cand.mtime_ms) orelse continue;
        const owned = self.allocator.dupe(u8, key) catch continue;
        st.asked.append(self.allocator, owned) catch self.allocator.free(owned);
    }
    st.req = self.nextReq();
    st.hc = tab.hc;
    st.job = 0;
    st.requests += 1;
    self.sendOp(tab.hc, .{
        .req = st.req,
        .op = "media_meta",
        .path = "/",
        .pattern = joined.items,
    });
}

// --- replies ---------------------------------------------------

/// Consume the frames belonging to the in-flight batch.
/// @return true when the frame was ours (the dispatcher stops).
pub fn feed(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    const st = &self.media;
    if (st.hc != hc) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    switch (ftype) {
        .fs_reply => {
            if (st.req == 0) return false;
            const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return false;
            if (rep.req != st.req) return false;
            if (!rep.ok or rep.job == 0) {
                // A refused request is not evidence about the files;
                // release the slot without recording answers, and do
                // NOT re-arm, or a persistent refusal would spin.
                finishBatch(self, false);
                return true;
            }
            st.job = rep.job;
            if (st.cancel_pending) {
                if (hc.state == .ready)
                    self.sendOp(hc, .{ .req = @as(u32, 0), .op = "job_cancel", .job = st.job });
                clearInflight(self);
            }
            return true;
        },
        .fs_job => {
            if (st.job == 0) return false;
            const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return false;
            if (ev.job != st.job) return false;
            if (std.mem.eql(u8, ev.ev, "match")) {
                store(self, ev);
                return true;
            }
            if (ev.terminalEv()) {
                const completed = std.mem.eql(u8, ev.ev, "done");
                finishBatch(self, completed);
                if (self.currentTab()) |tab| {
                    applyValues(self, tab);
                    self.renderTab(tab);
                }
                // More of the window (or the sort fill) may remain --
                // but only re-arm after a batch that actually ran, so
                // an erroring or cancelled one cannot spin.
                if (completed) schedule(self);
            }
            return true;
        },
        else => return false,
    }
}

fn store(self: *BrowserView, ev: WireJobEv) void {
    if (ev.path.len == 0) return;
    const a = self.allocator;
    const key = askedKeyFor(self, ev.path) orelse return;
    // A file the host skipped answers with a note and no fields; that
    // is still an answer, and recording it is what stops the file
    // being asked about on every scroll.
    if (ev.meta.len == 0) {
        self.media.put(a, key, .{ .fields = &.{} });
        return dropAsked(self, key);
    }
    const fields = a.alloc(Field, ev.meta.len) catch return;
    var n: usize = 0;
    for (ev.meta) |kv| {
        const k = a.dupe(u8, kv.k) catch break;
        const v = a.dupe(u8, kv.v) catch {
            a.free(k);
            break;
        };
        fields[n] = .{ .k = k, .v = v };
        n += 1;
    }
    if (n != fields.len) {
        // Out of memory mid-copy. Release the whole allocation: a
        // Row holding a SHORTENED slice would be freed at the wrong
        // length. The terminal event records the empty answer.
        for (fields[0..n]) |f| {
            a.free(f.k);
            a.free(f.v);
        }
        a.free(fields);
        return;
    }
    self.media.put(a, key, .{ .fields = fields });
    dropAsked(self, key);
}

/// The cache key this batch asked about for `path`. Answers are
/// matched to the key that was SENT rather than re-derived from the
/// path, so an entry replaced by a delta mid-batch cannot silently
/// file its answer under a key nothing will ever look up.
fn askedKeyFor(self: *BrowserView, path: []const u8) ?[]const u8 {
    for (self.media.asked.items) |key| {
        // key is "host\x00path\x00mtime".
        const first = std.mem.indexOfScalar(u8, key, 0) orelse continue;
        const rest = key[first + 1 ..];
        const second = std.mem.indexOfScalar(u8, rest, 0) orelse continue;
        if (std.mem.eql(u8, rest[0..second], path)) return key;
    }
    return null;
}

fn dropAsked(self: *BrowserView, key: []const u8) void {
    const st = &self.media;
    for (st.asked.items, 0..) |k, i| {
        if (!std.mem.eql(u8, k, key)) continue;
        self.allocator.free(st.asked.orderedRemove(i));
        return;
    }
}

/// Release the in-flight slot.
///
/// `ran` means the batch completed: everything it asked about but the
/// daemon never reported (unreadable, not a regular file, or the
/// helper's read budget ran out) is recorded as an EMPTY answer, so
/// it is asked about once rather than on every scroll. A batch that
/// failed or was cancelled proves nothing about those files and
/// records nothing.
fn finishBatch(self: *BrowserView, ran: bool) void {
    const st = &self.media;
    if (ran) {
        for (st.asked.items) |key| {
            if (st.rows.contains(key)) continue;
            st.put(self.allocator, key, .{ .fields = &.{} });
        }
    }
    clearInflight(self);
}

// --- readers ---------------------------------------------------

/// One cached field for a file, for the Properties dialog and the
/// preview panel. Never triggers a fetch: those surfaces have their
/// own on-demand path.
pub fn lookup(self: *BrowserView, hc: *HostConn, path: []const u8, mtime_ms: i64, key: []const u8) ?[]const u8 {
    var key_buf: [4300]u8 = undefined;
    const ck = cacheKey(&key_buf, hc, path, mtime_ms) orelse return null;
    const row = self.media.rows.get(ck) orelse return null;
    const v = row.get(key) orelse return null;
    return if (v.len > 0) v else null;
}
