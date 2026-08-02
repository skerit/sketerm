//! Paste collisions: the non-blocking queue and the side-by-side
//! decision dialog.
//!
//! Explorer's model, not the usual GTK one: a collision does NOT stall
//! the batch. `beginPaste` starts every source whose name is free
//! immediately and parks only the colliding ones here; the dialog then
//! works through the parked list while the rest of the copy is already
//! running. "Apply to all" drains the queue in one decision.
//!
//! Each parked item asks BOTH hosts for the facts a person needs to
//! decide -- size, modification time, and a thumbnail where the
//! preview pipeline can produce one -- so the dialog compares two real
//! files rather than two names.

const std = @import("std");
const c = @import("../../c.zig").c;

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Entry = @import("types.zig").Entry;
const HostConn = @import("types.zig").HostConn;
const WireReply = @import("types.zig").WireReply;
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const copyZ = @import("../../filebrowser/format.zig").copyZN;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const fmtTimeZ = @import("../../filebrowser/format.zig").fmtTimeZ;
const uniqueDstNameIn = @import("ops.zig").uniqueDstNameIn;

/// What the user decided for one collision. `merge` and `replace` are
/// directory-only; `overwrite` is the file spelling of `replace`.
pub const Choice = enum { overwrite, keep_both, skip, merge, replace };

/// How often the dialog re-reads the thumbnail cache while a
/// generation it triggered is still in flight.
const THUMB_TICK_MS: c.guint = 300;
/// ...and how many ticks it waits before settling for the icon.
const THUMB_TICKS_MAX: u32 = 20;

/// One parked collision. Owned by the queue; never by a widget, so a
/// popover dying (or a whole batch being applied at once) cannot leave
/// a dangling decision.
pub const Item = struct {
    tab: *BTab,
    /// Destination host (the tab's) and the source's host.
    dst_hc: *HostConn,
    src_hc: *HostConn,
    /// Owned; `src_host` is the host STRING form the paste path wants.
    src: []u8,
    dst: []u8,
    src_host: ?[]u8,
    is_dir: bool,
    cut: bool,
    /// In-flight stat requests (0 = answered or never asked).
    src_req: u32 = 0,
    dst_req: u32 = 0,
    src_size: u64 = 0,
    src_mtime_ms: i64 = 0,
    src_is_dir: bool = false,
    src_known: bool = false,
    dst_size: u64 = 0,
    dst_mtime_ms: i64 = 0,
    dst_known: bool = false,

    fn destroy(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.src);
        allocator.free(self.dst);
        if (self.src_host) |h| allocator.free(h);
        allocator.destroy(self);
    }

    fn name(self: *const Item) []const u8 {
        return std.fs.path.basename(self.src);
    }

    /// Both sides live on the same daemon, so the daemon-side copy
    /// verbs (merge / replace) are available for this item.
    fn sameHost(self: *const Item) bool {
        return self.src_hc == self.dst_hc;
    }

    /// Merging needs a directory on BOTH sides. `is_dir` is the live
    /// listing's answer for the destination; the source side only
    /// becomes known once its stat lands, so the buttons are rebuilt
    /// when it does rather than offering a verb that cannot run.
    fn mergeable(self: *const Item) bool {
        return self.is_dir and self.src_known and self.src_is_dir;
    }

    fn canKeepBoth(self: *const Item) bool {
        const dir = std.fs.path.dirname(self.dst) orelse return false;
        return std.mem.eql(u8, dir, self.tab.root.path) or self.tab.subdirByPath(dir) != null;
    }
};

/// The parked collisions plus the one open dialog. Owned by the
/// BrowserView through a single field.
///
/// The dialog is held with an OWN reference: the tab it is parented to
/// can be closed under it, and a pointer to a widget the parent
/// already finalized would be used by the next decision.
pub const State = struct {
    queue: std.ArrayList(*Item) = .empty,
    popover: ?*c.GtkWidget = null,
    apply_all: ?*c.GtkWidget = null,
    /// Rebuilt in place as replies land, so the dialog can pop up
    /// immediately and fill itself in.
    detail_box: ?*c.GtkWidget = null,
    buttons_box: ?*c.GtkWidget = null,
    heading: ?*c.GtkLabel = null,
    thumb_tick: c.guint = 0,
    thumb_ticks: u32 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.thumb_tick != 0) {
            _ = c.g_source_remove(self.thumb_tick);
            self.thumb_tick = 0;
        }
        if (self.popover) |popover| {
            c.g_object_unref(@ptrCast(popover));
            self.popover = null;
        }
        for (self.queue.items) |item| item.destroy(allocator);
        self.queue.deinit(allocator);
    }
};

/// Remove every decision that references a tab before that tab is freed.
pub fn cancelTab(self: *BrowserView, tab: *BTab) void {
    closeDialog(self);
    var i: usize = 0;
    while (i < self.conflicts.queue.items.len) {
        const item = self.conflicts.queue.items[i];
        if (item.tab != tab) {
            i += 1;
            continue;
        }
        _ = self.conflicts.queue.orderedRemove(i);
        item.destroy(self.allocator);
    }
    if (self.conflicts.queue.items.len > 0) showDialog(self);
}

/// Heap context for one decision button, freed with the button.
const BtnCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    choice: Choice,

    fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
        _ = closure;
        const ctx: *BtnCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

// ── queueing ────────────────────────────────────────────────────

/// Park one collision and make sure the dialog is up. The rest of the
/// batch keeps copying: nothing here blocks it.
pub fn enqueue(
    self: *BrowserView,
    tab: *BTab,
    src_hc: *HostConn,
    src_host: ?[]const u8,
    src: []const u8,
    dst: []const u8,
    is_dir: bool,
    cut: bool,
) void {
    const item = self.allocator.create(Item) catch return;
    const src_owned = self.allocator.dupe(u8, src) catch {
        self.allocator.destroy(item);
        return;
    };
    const dst_owned = self.allocator.dupe(u8, dst) catch {
        self.allocator.free(src_owned);
        self.allocator.destroy(item);
        return;
    };
    const src_host_owned = if (src_host) |h| self.allocator.dupe(u8, h) catch {
        self.allocator.free(src_owned);
        self.allocator.free(dst_owned);
        self.allocator.destroy(item);
        return;
    } else null;
    item.* = .{
        .tab = tab,
        .dst_hc = tab.hc,
        .src_hc = src_hc,
        .src = src_owned,
        .dst = dst_owned,
        .src_host = src_host_owned,
        .is_dir = is_dir,
        .cut = cut,
    };
    self.conflicts.queue.append(self.allocator, item) catch {
        item.destroy(self.allocator);
        return;
    };
    askFacts(self, item);
    showDialog(self);
}

/// Ask both hosts what the two files actually are. Answers land in
/// feedConflicts and refresh the dialog in place.
fn askFacts(self: *BrowserView, item: *Item) void {
    if (item.src_hc.state == .ready) {
        item.src_req = self.nextReq();
        self.sendOp(item.src_hc, .{ .req = item.src_req, .op = "stat", .path = item.src });
    }
    if (item.dst_hc.state == .ready) {
        item.dst_req = self.nextReq();
        self.sendOp(item.dst_hc, .{ .req = item.dst_req, .op = "stat", .path = item.dst });
    }
}

/// Route a `stat` reply belonging to a parked collision.
/// @return true when the reply was ours (the caller must not treat it
/// as an unhandled plain-op reply).
pub fn feedConflicts(self: *BrowserView, hc: *HostConn, rep: WireReply) bool {
    for (self.conflicts.queue.items) |item| {
        const is_src = item.src_req != 0 and item.src_req == rep.req and item.src_hc == hc;
        const is_dst = item.dst_req != 0 and item.dst_req == rep.req and item.dst_hc == hc;
        if (!is_src and !is_dst) continue;
        if (is_src) item.src_req = 0 else item.dst_req = 0;
        // A stat reply carries the entry inline; `entries` is the
        // listing shape and stays empty here.
        if (rep.ok and rep.entry != null) {
            const e = rep.entry.?;
            if (is_src) {
                item.src_size = e.size;
                item.src_mtime_ms = e.mtime_ms;
                item.src_is_dir = e.tdir;
                item.src_known = true;
            } else {
                item.dst_size = e.size;
                item.dst_mtime_ms = e.mtime_ms;
                item.dst_known = true;
            }
        }
        if (self.conflicts.queue.items.len > 0 and self.conflicts.queue.items[0] == item)
            refreshDialog(self);
        return true;
    }
    return false;
}

// ── the dialog ──────────────────────────────────────────────────

fn head(self: *BrowserView) ?*Item {
    if (self.conflicts.queue.items.len == 0) return null;
    return self.conflicts.queue.items[0];
}

fn detailRow(self: *BrowserView, parent: *c.GtkWidget, title: [*:0]const u8, hc: *HostConn, path: []const u8, size: u64, mtime_ms: i64, known: bool, is_dir: bool) void {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_margin_top(row, 4);

    var icon: ?*c.GtkWidget = null;
    if (!is_dir and known) {
        // Reuse the row-thumbnail pipeline: a hit renders now, a miss
        // starts a generation the tick below picks up.
        const e = Entry{
            .name = @constCast(std.fs.path.basename(path)),
            .kind = @constCast("file"),
            .size = size,
            .mode = 0,
            .mtime_ms = mtime_ms,
            .target = null,
            .tdir = false,
        };
        if (self.thumbLookup(hc, path, e)) |tex| {
            const img = c.gtk_image_new_from_paintable(@ptrCast(tex));
            c.gtk_image_set_pixel_size(@ptrCast(img), 64);
            icon = img;
        }
    }
    if (icon == null) {
        const img = c.gtk_image_new_from_icon_name(if (is_dir) "folder" else "text-x-generic");
        c.gtk_image_set_pixel_size(@ptrCast(img), 64);
        icon = img;
    }
    c.gtk_box_append(@ptrCast(row), icon.?);

    var text: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    var size_buf: [48:0]u8 = undefined;
    var time_buf: [40:0]u8 = undefined;
    w.print("{s}\n", .{title}) catch {};
    if (known) {
        if (is_dir) {
            w.print("folder on {s}\n", .{hc.label()}) catch {};
        } else {
            w.print("{s} on {s}\n", .{ fmtSize(&size_buf, size), hc.label() }) catch {};
        }
        w.print("modified {s}", .{fmtTimeZ(&time_buf, mtime_ms)}) catch {};
    } else {
        w.print("details unavailable", .{}) catch {};
    }
    var zbuf: [640:0]u8 = undefined;
    const label = c.gtk_label_new(copyZ(&zbuf, w.buffered()));
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_widget_set_hexpand(label, 1);
    c.gtk_box_append(@ptrCast(row), label);
    c.gtk_box_append(@ptrCast(parent), row);
}

/// Which of the two is newer, stated in words rather than left to the
/// reader to work out from two timestamps.
fn verdictText(buf: []u8, item: *const Item) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    if (!item.src_known or !item.dst_known) {
        w.print("Cannot compare: one side did not report its details.", .{}) catch {};
        return w.buffered();
    }
    if (item.src_mtime_ms > item.dst_mtime_ms) {
        w.print("The item being pasted is NEWER than the one already here.", .{}) catch {};
    } else if (item.src_mtime_ms < item.dst_mtime_ms) {
        w.print("The item being pasted is OLDER than the one already here.", .{}) catch {};
    } else {
        w.print("Both items have the same modification time.", .{}) catch {};
    }
    if (!item.is_dir and item.src_size != item.dst_size) {
        var a: [48:0]u8 = undefined;
        var b: [48:0]u8 = undefined;
        w.print(" Sizes differ ({s} vs {s}).", .{ fmtSize(&a, item.src_size), fmtSize(&b, item.dst_size) }) catch {};
    } else if (!item.is_dir) {
        w.print(" Both are the same size.", .{}) catch {};
    }
    return w.buffered();
}

fn choiceButton(self: *BrowserView, box: *c.GtkWidget, label: [*:0]const u8, choice: Choice, destructive: bool) void {
    choiceButtonStyled(self, box, label, choice, if (destructive) "destructive-action" else null);
}

fn choiceButtonStyled(self: *BrowserView, box: *c.GtkWidget, label: [*:0]const u8, choice: Choice, class: ?[*:0]const u8) void {
    const ctx = self.allocator.create(BtnCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .view = self, .choice = choice };
    const btn = c.gtk_button_new_with_label(label);
    if (class) |cl| c.gtk_widget_add_css_class(btn, cl);
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onChoice), @ptrCast(ctx), @ptrCast(&BtnCtx.free), c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), btn);
}

/// Build the decision popover once; the head item's details are filled
/// in (and refilled) by refreshDialog.
fn showDialog(self: *BrowserView) void {
    if (self.conflicts.popover != null) return refreshDialog(self);
    const item = head(self) orelse return;
    if (!self.tabAlive(item.tab)) return dropHead(self);

    const popover = c.gtk_popover_new();
    c.gtk_popover_set_autohide(@ptrCast(popover), 0);
    // Our own reference; released by closeDialog or State.deinit.
    _ = c.g_object_ref_sink(@ptrCast(popover));
    self.conflicts.popover = popover;

    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_widget_set_margin_start(box, 12);
    c.gtk_widget_set_margin_end(box, 12);
    c.gtk_widget_set_margin_top(box, 12);
    c.gtk_widget_set_margin_bottom(box, 12);

    const heading = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(heading), 0);
    c.gtk_widget_add_css_class(heading, "heading");
    c.gtk_box_append(@ptrCast(box), heading);
    self.conflicts.heading = @ptrCast(@alignCast(heading));

    const detail = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_box_append(@ptrCast(box), detail);
    self.conflicts.detail_box = detail;

    const apply_all = c.gtk_check_button_new_with_label("Apply to all remaining conflicts");
    c.gtk_box_append(@ptrCast(box), apply_all);
    self.conflicts.apply_all = apply_all;

    const buttons = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_margin_top(buttons, 6);
    c.gtk_box_append(@ptrCast(box), buttons);
    self.conflicts.buttons_box = buttons;

    c.gtk_popover_set_child(@ptrCast(popover), box);
    c.gtk_widget_set_parent(popover, item.tab.page);
    connectPopoverAutoUnparent(popover);
    // A popover with a large child and no pointing_to rect silently
    // fails to map.
    const rect = c.GdkRectangle{ .x = 40, .y = 40, .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    c.gtk_popover_popup(@ptrCast(popover));
    refreshDialog(self);
    armThumbTick(self);
}

fn refreshDialog(self: *BrowserView) void {
    const detail = self.conflicts.detail_box orelse return;
    const item = head(self) orelse return;
    while (c.gtk_widget_get_first_child(detail)) |child| {
        c.gtk_box_remove(@ptrCast(detail), child);
    }
    if (self.conflicts.heading) |label| {
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("\"{s}\" already exists here", .{item.name()}) catch {};
        if (self.conflicts.queue.items.len > 1)
            w.print(" ({d} conflicts waiting; the rest of the paste is already running)", .{self.conflicts.queue.items.len}) catch {};
        var z: [640:0]u8 = undefined;
        c.gtk_label_set_text(label, copyZ(&z, w.buffered()));
    }
    detailRow(self, detail, "Item being pasted", item.src_hc, item.src, item.src_size, item.src_mtime_ms, item.src_known, item.is_dir);
    detailRow(self, detail, "Item already here", item.dst_hc, item.dst, item.dst_size, item.dst_mtime_ms, item.dst_known, item.is_dir);
    var vbuf: [256]u8 = undefined;
    var vz: [320:0]u8 = undefined;
    const verdict = c.gtk_label_new(copyZ(&vz, verdictText(&vbuf, item)));
    c.gtk_label_set_xalign(@ptrCast(verdict), 0);
    c.gtk_label_set_wrap(@ptrCast(verdict), 1);
    c.gtk_widget_add_css_class(verdict, "dim-label");
    c.gtk_widget_set_margin_top(verdict, 6);
    c.gtk_box_append(@ptrCast(detail), verdict);
    refreshButtons(self, item);
}

/// Only the verbs that can actually run for THIS item are rendered.
/// Rebuilt with the details because a source stat can turn a
/// "directory onto directory" collision into a plain overwrite.
fn refreshButtons(self: *BrowserView, item: *Item) void {
    const buttons = self.conflicts.buttons_box orelse return;
    while (c.gtk_widget_get_first_child(buttons)) |child| {
        c.gtk_box_remove(@ptrCast(buttons), child);
    }
    // A destination this same source already failed to copy onto is
    // most likely an interrupted transfer: offer to pick it up where
    // it stopped (the daemon's resume skips verified-complete files
    // and continues staged partials) rather than making the user
    // reason it out from Replace/Merge.
    if (item.mergeable() and @import("../../filebrowser/incomplete.zig").match(
        self.allocator,
        item.src_host orelse "",
        item.src,
        item.dst_hc.host orelse "",
        item.dst,
    )) {
        choiceButtonStyled(self, buttons, "Continue Copy (this transfer was interrupted)", .merge, "suggested-action");
    }
    if (item.mergeable()) {
        choiceButton(self, buttons, "Merge (files only in the destination stay)", .merge, false);
        // Replacing a folder means deleting what is there first, which
        // only the daemon-side copy can express; a cross-host paste
        // gets merge rather than a button that cannot work.
        if (item.sameHost())
            choiceButton(self, buttons, "Replace (delete the destination folder first)", .replace, true);
    } else {
        choiceButton(self, buttons, "Replace", .overwrite, true);
    }
    if (item.canKeepBoth()) choiceButton(self, buttons, "Keep Both (rename the pasted copy)", .keep_both, false);
    choiceButton(self, buttons, "Skip", .skip, false);
}

/// Thumbnails are generated asynchronously by the shared pipeline,
/// which reports back by re-rendering the LISTING. The dialog is not a
/// listing, so it re-reads the cache on a bounded tick instead.
fn armThumbTick(self: *BrowserView) void {
    if (self.conflicts.thumb_tick != 0) return;
    self.conflicts.thumb_ticks = 0;
    self.conflicts.thumb_tick = c.g_timeout_add(THUMB_TICK_MS, @ptrCast(&onThumbTick), @ptrCast(self));
}

fn onThumbTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.conflicts.thumb_ticks += 1;
    if (self.conflicts.popover == null or self.conflicts.thumb_ticks >= THUMB_TICKS_MAX) {
        self.conflicts.thumb_tick = 0;
        return 0;
    }
    refreshDialog(self);
    return 1;
}

fn closeDialog(self: *BrowserView) void {
    if (self.conflicts.popover) |popover| {
        c.gtk_popover_popdown(@ptrCast(popover));
        c.g_object_unref(@ptrCast(popover));
        self.conflicts.popover = null;
    }
    self.conflicts.apply_all = null;
    self.conflicts.detail_box = null;
    self.conflicts.buttons_box = null;
    self.conflicts.heading = null;
    if (self.conflicts.thumb_tick != 0) {
        _ = c.g_source_remove(self.conflicts.thumb_tick);
        self.conflicts.thumb_tick = 0;
    }
}

fn dropHead(self: *BrowserView) void {
    if (self.conflicts.queue.items.len == 0) return;
    const item = self.conflicts.queue.orderedRemove(0);
    item.destroy(self.allocator);
}

// ── applying a decision ─────────────────────────────────────────

fn onChoice(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *BtnCtx = @ptrCast(@alignCast(user.?));
    // Everything this handler needs is read BEFORE the popover goes
    // down: popping it down destroys the button, which frees `ctx`
    // through its GDestroyNotify.
    const self = ctx.view;
    const choice = ctx.choice;
    const all = if (self.conflicts.apply_all) |cb|
        c.gtk_check_button_get_active(@ptrCast(cb)) != 0
    else
        false;
    // Applying pops items, so the popover must not be asked about them
    // afterwards; close first and reopen for whatever is left.
    closeDialog(self);
    var applied: usize = 0;
    while (self.conflicts.queue.items.len > 0) {
        const item = self.conflicts.queue.items[0];
        applyOne(self, item, choice);
        dropHead(self);
        applied += 1;
        if (!all) break;
    }
    if (applied > 1) self.setStatusFmt("applied \"{s}\" to {d} conflicts", .{ @tagName(choice), applied });
    if (self.conflicts.queue.items.len > 0) showDialog(self);
}

fn applyOne(self: *BrowserView, item: *Item, choice_in: Choice) void {
    if (!self.tabAlive(item.tab)) {
        self.setStatus("the target tab closed; conflict dropped");
        return;
    }
    if (item.tab.hc != item.dst_hc) {
        self.setStatus("the target tab moved to another host; conflict dropped");
        return;
    }
    // A directory cannot be "overwritten" in place and a file cannot be
    // merged: map an apply-to-all decision onto what this item is.
    const choice: Choice = switch (choice_in) {
        .overwrite, .replace => if (item.mergeable())
            (if (item.sameHost()) Choice.replace else Choice.merge)
        else
            Choice.overwrite,
        .merge => if (item.mergeable()) Choice.merge else Choice.overwrite,
        else => choice_in,
    };
    switch (choice) {
        .skip => self.setStatusFmt("skipped {s}", .{item.name()}),
        .keep_both => {
            var name_buf: [512]u8 = undefined;
            const dir = std.fs.path.dirname(item.dst) orelse return;
            const unique = uniqueDstNameIn(item.tab, dir, item.name(), &name_buf) orelse {
                self.setStatusFmt("no free name for {s}", .{item.name()});
                return;
            };
            var dst_buf: [4096]u8 = undefined;
            const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
                if (dir.len == 1) "" else dir, unique,
            }) catch return;
            self.pasteOne(item.tab, item.src_host, item.src, dst, item.cut, .{ .no_replace = true });
        },
        .overwrite => self.pasteOne(item.tab, item.src_host, item.src, item.dst, item.cut, .{}),
        .merge => {
            self.pasteOne(item.tab, item.src_host, item.src, item.dst, item.cut, .{ .dir_mode = "merge", .undoable = false });
            self.setStatusFmt("merging into {s} (a merge cannot be undone)", .{item.name()});
        },
        .replace => {
            self.pasteOne(item.tab, item.src_host, item.src, item.dst, item.cut, .{ .dir_mode = "replace", .undoable = false });
            self.setStatusFmt("replacing {s} (a replace cannot be undone)", .{item.name()});
        },
    }
}

test "verdictText names the newer side and compares sizes" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    var item = Item{
        .tab = undefined,
        .dst_hc = undefined,
        .src_hc = undefined,
        .src = @constCast("/a/x.txt"),
        .dst = @constCast("/b/x.txt"),
        .src_host = null,
        .is_dir = false,
        .cut = false,
        .src_size = 100,
        .src_mtime_ms = 2000,
        .src_known = true,
        .dst_size = 40,
        .dst_mtime_ms = 1000,
        .dst_known = true,
    };
    const newer = verdictText(&buf, &item);
    try t.expect(std.mem.indexOf(u8, newer, "NEWER") != null);
    try t.expect(std.mem.indexOf(u8, newer, "Sizes differ") != null);

    item.src_mtime_ms = 500;
    try t.expect(std.mem.indexOf(u8, verdictText(&buf, &item), "OLDER") != null);

    item.src_mtime_ms = 1000;
    item.src_size = 40;
    const same = verdictText(&buf, &item);
    try t.expect(std.mem.indexOf(u8, same, "same modification time") != null);
    try t.expect(std.mem.indexOf(u8, same, "same size") != null);

    // A side that never answered must not be compared at all.
    item.dst_known = false;
    try t.expect(std.mem.indexOf(u8, verdictText(&buf, &item), "Cannot compare") != null);
}

test "merge is offered only when BOTH sides are known directories" {
    const t = std.testing;
    var file = Item{
        .tab = undefined,
        .dst_hc = undefined,
        .src_hc = undefined,
        .src = @constCast("/a/x.txt"),
        .dst = @constCast("/b/x.txt"),
        .src_host = null,
        .is_dir = false,
        .cut = false,
        .src_known = true,
    };
    // A file can never be merged; an apply-to-all merge degrades to a
    // plain replace for it.
    try t.expect(!file.mergeable());
    var dir = file;
    dir.is_dir = true;
    dir.src_is_dir = true;
    try t.expect(dir.mergeable());
    // Until the source stat lands, a destination directory is still
    // not offered merge: the source might be a plain file.
    dir.src_known = false;
    try t.expect(!dir.mergeable());
}
