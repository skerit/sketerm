//! Queries: live filename queries, content greps, panels, and the
//! duplicate finder.
//!
//! A query is a host-side job whose streamed events fill a flat
//! results tab; only the hits cross the wire. Every query is owned by
//! the TAB it fills (`BTab.query`), so any number of them stay open
//! and updating at once and closing a tab cancels exactly its own job
//! -- a live query holds a recursive host-side watcher, which is
//! expensive enough that leaking one is a real cost.
//!
//! There is one query concept, not a "search" and a separate "saved
//! live query": what a query text means is decided by
//! filebrowser/query.zig, and the daemon verb follows from that. A
//! name query is served by `live_find` and therefore always live; a
//! content grep and a panel command are one-shot because they cannot
//! be anything else. The flat/subtree view is the same machinery with
//! the pattern `*` over the tab's own directory.
//!
//! The collection shelf used to live here too; it is now the
//! `collection` register in selection.zig, which serves the same rows
//! through the same flat Dir mechanism.

const std = @import("std");
const c = @import("../../c.zig").c;
const query = @import("../../filebrowser/query.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const OwnedSearch = @import("types.zig").OwnedSearch;
const WireJobEv = @import("types.zig").WireJobEv;
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;

/// Duplicate finder: a host-side scan buckets files by SIZE, then
/// same-size candidates are hash-confirmed with daemon hash jobs.
/// Only confirmed same-digest groups are reported.
pub const DupState = struct {
    hc: *HostConn,
    root: []u8,
    job: u64 = 0,
    scanning: bool = true,
    sizes: std.AutoHashMapUnmanaged(u64, std.ArrayList([]u8)) = .empty,
    hashes: std.ArrayList(DupHash) = .empty,

    pub const DupHash = struct {
        req: u32,
        job: u64 = 0,
        path: []u8,
        size: u64,
        hash: [64]u8 = undefined,
        have: bool = false,
        failed: bool = false,
    };

    /// Files hashed at most, across all buckets (bounded work).
    pub const MAX_HASHED = 200;

    pub fn destroy(self: *DupState, allocator: std.mem.Allocator) void {
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

/// Longest rejected panel line kept for the report.
const MAX_REJECT_TEXT = 120;

/// One tab's running query: the daemon job filling its flat rows, plus
/// everything the tab has to be able to say about that job afterwards.
///
/// A live query never reaches a terminal event -- it ends when the tab
/// closes and cancels it -- so its bounds and counts arrive on `ready`
/// status events instead, and are re-reported from here on every
/// render rather than only in a status line the next action erases.
pub const TabQuery = struct {
    hc: *HostConn,
    /// 0 until the daemon answers the start request with an id.
    job: u64 = 0,
    kind: query.Kind,
    mode: Mode = .results,
    /// The query text exactly as typed, `@7d` and `!` included
    /// (owned): what gets saved, re-run and labelled.
    text: []u8,
    /// Where the job runs (owned). A results tab keeps its own root
    /// path, but the query belongs to the directory it was started in.
    root: []u8,
    /// Latest counts the host reported.
    matches: u64 = 0,
    watches: u64 = 0,
    truncated: bool = false,
    watch_limit: bool = false,
    /// The initial scan finished (live queries).
    ready: bool = false,
    /// The job reached a terminal event: the rows stay, but the tab
    /// stops claiming to be live.
    ended: bool = false,
    /// The host watcher overflowed; the row set may have drifted.
    stale: bool = false,
    /// panelize: output lines that named nothing on disk, plus the
    /// first of them and the command's own exit status.
    rejected: u64 = 0,
    reject: [MAX_REJECT_TEXT]u8 = undefined,
    reject_len: usize = 0,
    exit_status: i64 = 0,

    /// What the query is FOR. A results query owns a tab of its own;
    /// a flat query replaces a real directory's listing, so stopping
    /// it has to put the subscription back.
    pub const Mode = enum { results, flat };

    pub fn live(self: *const TabQuery) bool {
        return self.kind == .live_name and !self.ended;
    }

    pub fn destroy(self: *TabQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.root);
        allocator.destroy(self);
    }

    fn rejectText(self: *const TabQuery) []const u8 {
        return self.reject[0..self.reject_len];
    }
};

/// Start `q` on `tab`, whose root Dir the caller has already put into
/// flat mode. Replaces any query the tab was already running.
/// @return false when nothing was started.
pub fn queryStart(
    self: *BrowserView,
    tab: *BTab,
    root: []const u8,
    text: []const u8,
    q: query.Query,
    mode: TabQuery.Mode,
) bool {
    if (tab.hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{tab.hc.label()});
        return false;
    }
    queryForget(self, tab);
    const tq = self.allocator.create(TabQuery) catch return false;
    tq.* = .{
        .hc = tab.hc,
        .kind = q.kind,
        .mode = mode,
        .text = self.allocator.dupe(u8, text) catch {
            self.allocator.destroy(tq);
            return false;
        },
        .root = self.allocator.dupe(u8, root) catch {
            self.allocator.free(tq.text);
            self.allocator.destroy(tq);
            return false;
        },
    };
    tab.query = tq;

    var jl: [220]u8 = undefined;
    const jlbl = std.fmt.bufPrint(&jl, "{s} \"{s}\" in {s}", .{
        q.kindLabel(), q.pattern[0..@min(q.pattern.len, 80)], root,
    }) catch "query";
    // Single-shot by contract: the relative-time predicate belongs to
    // the job about to be started and to nothing after it.
    self.search_within_ms = q.within_ms;
    self.startDaemonJobKind(tab.hc, q.op(), tq.root, "", q.pattern, jlbl, .{
        .kind = .query,
        .tab = tab,
    });
    self.search_within_ms = 0;
    // startDaemonJobKind refuses on a dead connection without telling
    // us, so a query whose request never went out must not sit there
    // pretending to be live.
    if (tab.query == tq and !queryRequested(self, tab)) {
        queryForget(self, tab);
        return false;
    }
    return true;
}

/// Whether the tab's query still has a request in flight or an id.
fn queryRequested(self: *BrowserView, tab: *BTab) bool {
    const tq = tab.query orelse return false;
    if (tq.job != 0) return true;
    for (self.pending_jobs.items) |pj| {
        if (pj.kind == .query and pj.tab == tab) return true;
    }
    return false;
}

/// Cancel and forget the tab's query. The host job dies with it: a
/// recursive watcher on a big tree is expensive, and nothing is left
/// to consume its events.
pub fn queryForget(self: *BrowserView, tab: *BTab) void {
    const tq = tab.query orelse return;
    tab.query = null;
    if (tq.job != 0 and tq.hc.state == .ready)
        self.sendOp(tq.hc, .{ .req = self.nextReq(), .op = "job_cancel", .job = tq.job });
    // A start request still in flight would otherwise hand its id to a
    // query that no longer exists.
    for (self.pending_jobs.items) |pj| {
        if (pj.kind == .query and pj.tab == tab) pj.tab = null;
    }
    tq.destroy(self.allocator);
}

/// The daemon answered a query's start request with its job id.
pub fn queryStarted(self: *BrowserView, tab: *BTab, hc: *HostConn, job: u64) void {
    const tq = tab.query orelse return;
    if (tq.hc != hc) return;
    tq.job = job;
    if (self.currentTab() == tab) self.renderTab(tab);
}

/// Route one streamed job event to the tab that owns the job.
/// @return true when it belonged to a query (and must not fall
/// through to the generic jobs-panel handling).
pub fn queryConsumeEvent(self: *BrowserView, hc: *HostConn, e: WireJobEv) bool {
    if (e.job == 0) return false;
    const tab = for (self.tabs.items) |t| {
        const tq = t.query orelse continue;
        if (tq.job == e.job and tq.hc == hc) break t;
    } else return false;
    const tq = tab.query.?;

    // Rows are re-rendered through the coalescing timer, never per
    // event: a subtree stream lands thousands of matches, and a tab
    // that is not on screen is rebuilt when it is switched to.
    if (std.mem.eql(u8, e.ev, "match")) {
        upsertFlatMatch(self, tab, e);
        self.scheduleThumbRender();
        return true;
    }
    if (std.mem.eql(u8, e.ev, "unmatch")) {
        removeFlatMatch(self, tab, e.path);
        self.scheduleThumbRender();
        return true;
    }
    if (std.mem.eql(u8, e.ev, "ready")) {
        tq.ready = true;
        tq.matches = e.matches;
        tq.watches = e.watches;
        tq.truncated = e.truncated;
        tq.watch_limit = e.watch_limit;
        self.scheduleThumbRender();
        return true;
    }
    if (std.mem.eql(u8, e.ev, "reject")) {
        tq.rejected += 1;
        if (tq.reject_len == 0 and e.text.len > 0) {
            tq.reject_len = @min(e.text.len, tq.reject.len);
            @memcpy(tq.reject[0..tq.reject_len], e.text[0..tq.reject_len]);
        }
        self.scheduleThumbRender();
        return true;
    }
    if (std.mem.eql(u8, e.ev, "resync")) {
        tq.stale = true;
        self.setStatus("live query watcher overflowed; reopen the query to resync");
        return true;
    }
    if (e.terminalEv()) {
        tq.ended = true;
        if (std.mem.eql(u8, e.ev, "done")) {
            tq.matches = e.matches;
            tq.truncated = e.truncated;
            tq.rejected = e.rejected;
            tq.exit_status = e.exit_status;
        }
        // Deliberately the COALESCED render: this event falls through
        // to the jobs panel, whose own "done: ..." status would erase
        // an immediate one. The timer fires after that and wins.
        self.scheduleThumbRender();
        // Falls through so the jobs panel finishes its row.
    }
    return false;
}

/// The note the tab's status line carries about its query. Rendered
/// on every render, so a truncation or a rejected panel line stays
/// visible instead of being erased by the next status message.
pub fn queryNote(tab: *BTab, buf: []u8) []const u8 {
    const tq = tab.query orelse return "";
    var w = std.Io.Writer.fixed(buf);
    const state: []const u8 = if (tq.mode == .flat)
        (if (tq.live()) "flat view, live" else "flat view")
    else if (!tq.ready and tq.kind == .live_name)
        "live query, scanning"
    else if (tq.live())
        "live query"
    else
        tq.kind.label();
    w.print(" ({s}", .{state}) catch return "";
    if (tq.live() and tq.watches > 0) w.print(", {d} watched dir(s)", .{tq.watches}) catch {};
    if (tq.truncated) w.print(", TRUNCATED at the match cap", .{}) catch {};
    if (tq.watch_limit) w.print(", watch limit reached: deeper subdirectories are NOT live", .{}) catch {};
    if (tq.stale) w.print(", watcher overflowed", .{}) catch {};
    if (tq.rejected > 0) {
        const quoted = tq.rejectText();
        w.print(", {d} output line(s) were not paths: \"{s}\"", .{
            tq.rejected, quoted[0..@min(quoted.len, 60)],
        }) catch {};
    }
    if (tq.exit_status != 0) w.print(", command exit status {d}", .{tq.exit_status}) catch {};
    w.print(")", .{}) catch return "";
    return w.buffered();
}

/// Start a query from the search bar. Its results stream into a fresh
/// flat tab, which keeps updating for as long as it is open.
pub fn startSearch(self: *BrowserView) void {
    const tab = self.currentTab() orelse return;
    if (tab.hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{tab.hc.label()});
        return;
    }
    const txt = c.gtk_editable_get_text(@ptrCast(self.search_entry));
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
    const content = c.gtk_check_button_get_active(@ptrCast(self.search_content)) != 0;
    const q = query.parse(text, content) orelse return;
    runQuery(self, tab, text, q);
}

/// Open `q` (typed as `text`) as a results tab rooted at `tab`'s
/// directory. Shared by the search bar and the saved-query list, so a
/// saved query can never run as something else than it was typed.
pub fn runQuery(self: *BrowserView, tab: *BTab, text: []const u8, q: query.Query) void {
    // Remember for the save button: the whole triple, command queries
    // included -- a panel preset is exactly as worth keeping as a
    // filename query.
    var spec_buf: [4400]u8 = undefined;
    const root_spec = tab.spec(&spec_buf);
    rememberLastSearch(self, root_spec, text, q.kind == .content);

    var rbuf: [4096]u8 = undefined;
    if (tab.root.path.len >= rbuf.len) return;
    @memcpy(rbuf[0..tab.root.path.len], tab.root.path);
    const root = rbuf[0..tab.root.path.len];
    const rtab = self.newTab(tab.hc.host, root) orelse return;
    // Flat results: no live view (newTab already subscribed the
    // root -- undo that; the query stream is the listing).
    self.closeViewOf(rtab.hc, rtab.root);
    var i: usize = 0;
    while (i < self.pending.items.len) {
        if (self.pending.items[i].tab == rtab) self.dropPending(i) else i += 1;
    }
    rtab.root.flat = true;
    rtab.root.loaded = true;
    rtab.root.view_id = 0;
    if (rtab.virtual_spec.len > 0) self.allocator.free(rtab.virtual_spec);
    rtab.virtual_spec = self.allocator.dupe(u8, text) catch &.{};
    var lbl: [200:0]u8 = undefined;
    const ltxt = std.fmt.bufPrintZ(&lbl, "{s}: {s}", .{ q.kindLabel(), text }) catch "query";
    c.gtk_label_set_text(rtab.tab_label, ltxt.ptr);
    _ = queryStart(self, rtab, root, text, q, .results);
    self.renderTab(rtab);
}

fn rememberLastSearch(self: *BrowserView, spec: []const u8, text: []const u8, content: bool) void {
    const spec_owned = self.allocator.dupe(u8, spec) catch return;
    const text_owned = self.allocator.dupe(u8, text) catch {
        self.allocator.free(spec_owned);
        return;
    };
    if (self.last_search) |ls| ls.deinitOwned(self.allocator);
    self.last_search = OwnedSearch{ .spec = spec_owned, .pattern = text_owned, .content = content };
}

/// Mark every row of the current results tab into a named register:
/// a query result becomes a keepable set that outlives the tab, the
/// query and the GUI process.
pub fn promoteResults(self: *BrowserView) void {
    self.markResultsDialog();
}

pub fn onPromoteClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    promoteResults(@ptrCast(@alignCast(user.?)));
}

/// The panelize preset menu: ready-made commands, dropped into the
/// search bar so they stay editable before they run.
pub fn onPresetClicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const popover = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_margin_start(box, 8);
    c.gtk_widget_set_margin_end(box, 8);
    c.gtk_widget_set_margin_top(box, 8);
    c.gtk_widget_set_margin_bottom(box, 8);
    const head = c.gtk_label_new("Run a command on this host and browse its output");
    c.gtk_label_set_xalign(@ptrCast(head), 0);
    c.gtk_widget_add_css_class(head, "dim-label");
    c.gtk_box_append(@ptrCast(box), head);
    for (query.presets, 0..) |preset, idx| {
        const item = c.gtk_button_new_with_label(preset.label.ptr);
        c.gtk_button_set_has_frame(@ptrCast(item), 0);
        c.gtk_widget_set_tooltip_text(item, preset.text.ptr);
        // The index rides the widget: a heap ctx per item would need a
        // destroy-notify for a menu rebuilt on every click, and the
        // index is all the handler needs.
        c.g_object_set_data(@ptrCast(item), "sketerm-preset", @ptrFromInt(idx + 1));
        _ = c.g_signal_connect_data(item, "clicked", @ptrCast(&onPresetPicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), item);
    }
    c.gtk_popover_set_child(@ptrCast(popover), box);
    // Without an explicit rect a popover with a wide child never maps.
    var bounds: c.graphene_rect_t = undefined;
    if (c.gtk_widget_compute_bounds(@ptrCast(btn), @ptrCast(btn), &bounds) != 0) {
        const rect = c.GdkRectangle{
            .x = @intFromFloat(bounds.origin.x),
            .y = @intFromFloat(bounds.origin.y),
            .width = @intFromFloat(bounds.size.width),
            .height = @intFromFloat(bounds.size.height),
        };
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    }
    c.gtk_widget_set_parent(popover, @ptrCast(btn));
    connectPopoverAutoUnparent(popover);
    c.gtk_popover_popup(@ptrCast(popover));
}

/// A preset fills the search bar rather than running straight away:
/// `rg -l TEXT` needs its TEXT replaced, and every preset is worth a
/// look before it executes on the host.
pub fn onPresetPicked(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const raw = c.g_object_get_data(@ptrCast(btn), "sketerm-preset") orelse return;
    const idx = @intFromPtr(raw) - 1;
    if (idx >= query.presets.len) return;
    if (c.gtk_widget_get_ancestor(@ptrCast(btn), c.gtk_popover_get_type())) |menu|
        c.gtk_popover_popdown(@ptrCast(@alignCast(menu)));
    c.gtk_check_button_set_active(@ptrCast(self.search_content), 0);
    c.gtk_editable_set_text(@ptrCast(self.search_entry), query.presets[idx].text.ptr);
    _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(self.search_entry)));
    c.gtk_editable_select_region(@ptrCast(self.search_entry), 0, -1);
    self.setStatus("edit the command if you like, then press Enter to browse its output");
}

/// Add (or refresh) one streamed job match as a flat row of `tab`.
/// Shared by the search results tab and the flat/branch view: both
/// are a host-side job filling a flat Dir whose display name is the
/// path relative to the job's root and whose `target` is the full
/// path every entry verb operates on.
pub fn upsertFlatMatch(self: *BrowserView, tab: *BTab, e: WireJobEv) void {
    const dir = tab.root;
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
                existing.mtime_ms = e.mtime_ms;
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
        .mtime_ms = e.mtime_ms,
        .target = tgt,
        .tdir = std.mem.eql(u8, kind, "dir"),
    }) catch {
        a.free(name);
        a.free(kind);
        a.free(tgt);
        return;
    };
}

/// Drop every flat row of `tab` whose full path is `path`.
pub fn removeFlatMatch(self: *BrowserView, tab: *BTab, path: []const u8) void {
    var i: usize = 0;
    while (i < tab.root.entries.items.len) {
        const target = tab.root.entries.items[i].target orelse {
            i += 1;
            continue;
        };
        if (!std.mem.eql(u8, target, path)) {
            i += 1;
            continue;
        }
        var entry = tab.root.entries.orderedRemove(i);
        entry.deinit(self.allocator);
    }
}

pub fn startDupScan(self: *BrowserView, tab: *BTab, root: []const u8) void {
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
    self.startDaemonJobKind(tab.hc, "find", d.root, "", "*", "duplicate scan", .{ .kind = .dup_scan });
}

/// Handle scan matches / completion and hash-confirm results.
/// Returns true when the event belonged to the dup machinery.
pub fn dupConsumeEvent(self: *BrowserView, d: *DupState, e: WireJobEv) bool {
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

pub fn dupStartHashPhase(self: *BrowserView, d: *DupState) void {
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

pub fn dupMaybeFinish(self: *BrowserView) void {
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

pub fn onSearchToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const on = c.gtk_toggle_button_get_active(btn) != 0;
    c.gtk_widget_set_visible(self.search_bar, if (on) 1 else 0);
    if (on) _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(self.search_entry)));
}

pub fn onSearchActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.startSearch();
}
