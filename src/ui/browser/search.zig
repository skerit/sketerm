//! Find/grep searches, the collection shelf and the duplicate finder.
//!
//! All three are host-side jobs whose streamed events fill a virtual
//! results tab; only digests cross the wire.

const std = @import("std");
const c = @import("../../c.zig").c;

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const MenuCtx = @import("menu.zig").MenuCtx;
const WireJobEv = @import("types.zig").WireJobEv;
const menuDone = @import("menu.zig").menuDone;

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

pub fn onMenuCollectionAdd(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
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
pub fn ensureCollectionTab(self: *BrowserView, host: ?[]const u8, path: []const u8) ?*BTab {
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

pub fn appendCollectionEntry(self: *BrowserView, tab: *BTab, spec: []const u8, is_dir: bool) void {
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

pub fn onMenuCollectionRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
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

/// Start a search from the bar: name search by default, content
/// grep when the toggle is on. Results stream into a flat tab.
pub fn startSearch(self: *BrowserView) void {
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

pub fn onSearchMatch(self: *BrowserView, e: WireJobEv) void {
    const rtab = self.search_tab orelse return;
    upsertFlatMatch(self, rtab, e);
    if (self.currentTab() == rtab) self.renderTab(rtab);
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

pub fn onSearchUnmatch(self: *BrowserView, path: []const u8) void {
    const rtab = self.search_tab orelse return;
    removeFlatMatch(self, rtab, path);
    if (self.currentTab() == rtab) self.renderTab(rtab);
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
    self.startDaemonJobKind(tab.hc, "find", d.root, "", "*", "duplicate scan", .dup_scan);
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
