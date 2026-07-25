//! Two-tree compare/sync.
//!
//! Both trees are scanned HOST-SIDE (find jobs streaming
//! path+kind+size+mtime digests -- only digests cross the wire),
//! diffed client-side, and reconciled with per-row direction choices
//! executed as jobs/transfers. Copy-only: no deletes, so a wrong
//! direction cannot destroy data.

const std = @import("std");
const c = @import("../../c.zig").c;
const fsjob = @import("../../mux/fsjob.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const MenuCtx = @import("menu.zig").MenuCtx;
const WireJobEv = @import("types.zig").WireJobEv;
const WireReply = @import("types.zig").WireReply;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const hostEq = @import("../../filebrowser/paths.zig").hostEq;
const menuDone = @import("menu.zig").menuDone;

/// Two-tree compare/sync: both trees are scanned HOST-SIDE (find
/// jobs streaming path+kind+size+mtime digests — only digests cross
/// the wire), diffed client-side, and reconciled with per-row
/// direction choices executed as jobs/transfers. Copy-only: no
/// deletes, so a wrong direction cannot destroy data.
pub const CompareCtx = struct {
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

    pub const CmpSide = struct {
        hc: *HostConn,
        root: []u8,
        job: u64 = 0,
        done: bool = false,
        failed: bool = false,
        truncated: bool = false,
        /// rel path (owned) -> digest.
        entries: std.StringHashMapUnmanaged(CmpInfo) = .empty,
    };
    pub const CmpInfo = struct { dir: bool, size: u64, mtime_ms: i64 };
    pub const DiffStatus = enum { left_only, right_only, differs };
    pub const Action = enum(c.guint) { skip = 0, to_right = 1, to_left = 2, delete = 3 };
    pub const DiffRow = struct {
        rel: []u8,
        dir: bool,
        status: DiffStatus,
        l: ?CmpInfo,
        r: ?CmpInfo,
        dd: *c.GtkWidget,
        lab: *c.GtkWidget,
    };

    pub const CmpPair = struct {
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

    pub fn sideFor(self: *CompareCtx, hc: *HostConn, job: u64) ?*CmpSide {
        if (self.left.hc == hc and self.left.job == job and job != 0) return &self.left;
        if (self.right.hc == hc and self.right.job == job and job != 0) return &self.right;
        return null;
    }

    pub fn sideFailed(self: *CompareCtx, is_left: bool) void {
        const s = if (is_left) &self.left else &self.right;
        s.failed = true;
        s.done = true;
        c.gtk_label_set_text(self.info_label, "scan failed — see status bar");
    }

    /// Digest/completion events for the two scan jobs. Match events
    /// are consumed; done/error also fall through to the jobs panel.
    pub fn consumeJobEvent(self: *CompareCtx, hc: *HostConn, e: WireJobEv) bool {
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

    pub fn record(self: *CompareCtx, side: *CmpSide, e: WireJobEv) void {
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

    pub fn maybeBuild(self: *CompareCtx) void {
        if (self.built or !self.left.done or !self.right.done) return;
        if (self.left.failed or self.right.failed) return;
        self.built = true;
        self.buildDiff();
    }

    pub fn addRow(self: *CompareCtx, rel: []const u8, status: DiffStatus, l: ?CmpInfo, r: ?CmpInfo) void {
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

    pub fn buildDiff(self: *CompareCtx) void {
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
    pub fn excluded(self: *CompareCtx, rel: []const u8) bool {
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

    pub fn execute(self: *CompareCtx) void {
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

    pub fn close(self: *CompareCtx) void {
        if (self.window) |w| {
            self.window = null;
            c.gtk_window_destroy(@ptrCast(w));
        }
    }

    /// g_object destroy-notify on the window: final cleanup.
    pub fn free(user: ?*anyopaque) callconv(.c) void {
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

    pub fn freeSide(allocator: std.mem.Allocator, side: *CmpSide) void {
        var it = side.entries.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        side.entries.deinit(allocator);
        allocator.free(side.root);
    }

    pub fn onExecuteClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *CompareCtx = @ptrCast(@alignCast(user.?));
        self.execute();
    }
    /// Hash-verify equal-size "differs" rows: identical digests
    /// flip the row to Skip (mtime noise, not content).
    pub fn startHashVerify(self: *CompareCtx) void {
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
    pub fn consumeHashStart(self: *CompareCtx, hc: *HostConn, rep: WireReply) bool {
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
    pub fn consumeHashEvent(self: *CompareCtx, hc: *HostConn, e: WireJobEv) bool {
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

    pub fn onHashVerifyClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *CompareCtx = @ptrCast(@alignCast(user.?));
        self.startHashVerify();
    }

    pub fn onMirrorClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
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
    pub fn onCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self: *CompareCtx = @ptrCast(@alignCast(user.?));
        self.close();
    }
};

pub fn onMenuSyncHere(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
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

/// Open the compare/sync window: source = the copied directory,
/// target = `right_path` on this tab's host. Host-side scans.
pub fn startCompare(self: *BrowserView, tab: *BTab, right_path: []const u8) void {
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
