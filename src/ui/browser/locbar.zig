//! The location bar: the breadcrumb FACE of the path control, its
//! per-segment sibling dropdowns, the back/forward history dropdowns
//! and the mouse side-button navigation.
//!
//! The breadcrumb is not a second location mechanism: it renders the
//! current tab's root and navigates through `navigate`/`historyJump`,
//! and Ctrl+L swaps it for the existing editable entry (completion
//! popup and host:/path parsing included). Escape swaps back.
//!
//! A segment dropdown lists the segment's SIBLINGS (the root's
//! children, since it has no siblings) from a real listing of the
//! parent directory: the request goes out through the normal fs wire
//! and the popover is built when the reply lands, so nothing here
//! ever waits on the daemon.

const std = @import("std");
const c = @import("../../c.zig").c;
const crumbs = @import("../../filebrowser/crumbs.zig");
const toolbtn = @import("../toolbtn.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const WireReply = @import("types.zig").WireReply;
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const dnd = @import("dnd.zig");
const dropValueIntoAction = @import("ops.zig").dropValueIntoAction;
const millerNextSegment = @import("../../filebrowser/paths.zig").millerNextSegment;

/// Segment budget for one bar. Deeper paths keep the root plus the
/// deepest segments (see crumbs.split); the horizontal scroller
/// handles what still does not fit on screen.
pub const MAX_SEGMENTS = 48;

/// Rows shown in a dropdown before it stops adding.
const MAX_DROPDOWN_ROWS = 200;

/// Which stack a history dropdown or jump walks.
pub const HistorySide = enum { back, forward };

/// All navigation-chrome state, so BrowserView keeps one field.
pub const State = struct {
    /// Horizontal scroller around `box`: a deep path scrolls instead
    /// of widening the toolbar.
    scroller: ?*c.GtkWidget = null,
    /// The segment buttons live here; rebuilt on every navigation.
    box: ?*c.GtkWidget = null,
    /// True while the editable entry face is showing.
    editing: bool = false,
    /// The one in-flight sibling listing (a rebuild cancels it).
    siblings: ?*SiblingReq = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.siblings) |s| s.destroy(allocator);
        self.siblings = null;
    }
};

/// A segment dropdown waiting for its parent listing. Names
/// accumulate across reply chunks; the popover pops when the run
/// ends.
pub const SiblingReq = struct {
    req: u32,
    hc: *HostConn,
    /// The arrow button the popover hangs off. Valid for as long as
    /// this request is: rebuilding the bar cancels it.
    anchor: *c.GtkWidget,
    /// Directory being listed (owned).
    parent: []u8,
    /// The child that is on the current path (owned, "" at the root).
    current: []u8,
    show_hidden: bool,
    names: std.ArrayList([]u8) = .empty,

    pub fn destroy(self: *SiblingReq, allocator: std.mem.Allocator) void {
        allocator.free(self.parent);
        allocator.free(self.current);
        for (self.names.items) |n| allocator.free(n);
        self.names.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Click context for a segment button, a segment drop target or a
/// dropdown row: everything that navigates to one absolute path.
pub const PathCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    path: []u8,

    /// GDestroyNotify shape (g_object_set_data_full).
    pub fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *PathCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.path);
        ctx.allocator.destroy(ctx);
    }

    /// GClosureNotify shape (g_signal_connect_data).
    pub fn freeClosure(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        free(user);
    }

    fn create(view: *BrowserView, path: []const u8) ?*PathCtx {
        const ctx = view.allocator.create(PathCtx) catch return null;
        ctx.* = .{
            .allocator = view.allocator,
            .view = view,
            .path = view.allocator.dupe(u8, path) catch {
                view.allocator.destroy(ctx);
                return null;
            },
        };
        return ctx;
    }
};

/// Click context for one history dropdown row.
pub const HistoryCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    side: HistorySide,
    /// How many entries back/forward this row travels (1 = nearest).
    steps: usize,

    /// GDestroyNotify shape (g_object_set_data_full).
    pub fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *HistoryCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }

    /// GClosureNotify shape (g_signal_connect_data).
    pub fn freeClosure(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        free(user);
    }
};

/// Build the two faces of the location control into the toolbar:
/// the breadcrumb scroller and the caller's existing path entry.
pub fn installLocationFace(self: *BrowserView, bar: *c.GtkWidget, entry: *c.GtkWidget) void {
    const holder = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_hexpand(holder, 1);
    // The whole holder reads as ONE bordered control (a path bar),
    // not as a row of loose flat buttons; see view.zig installCss.
    c.gtk_widget_add_css_class(holder, "sketerm-fb-path");

    const sw = c.gtk_scrolled_window_new();
    // EXTERNAL keeps the content scrollable without a scrollbar
    // stealing toolbar height; NEVER pins the row height.
    c.gtk_scrolled_window_set_policy(@ptrCast(sw), c.GTK_POLICY_EXTERNAL, c.GTK_POLICY_NEVER);
    c.gtk_widget_set_hexpand(sw, 1);
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_add_css_class(box, "linked");
    c.gtk_scrolled_window_set_child(@ptrCast(sw), box);
    c.gtk_box_append(@ptrCast(holder), sw);

    c.gtk_widget_set_visible(entry, 0);
    c.gtk_box_append(@ptrCast(holder), entry);
    c.gtk_box_append(@ptrCast(bar), holder);

    // Keep the deepest segment in view: "changed" fires when the
    // content or the viewport is resized (a rebuild), never on a
    // plain scroll, so this does not fight the user's own scrolling.
    const adj = c.gtk_scrolled_window_get_hadjustment(@ptrCast(sw));
    _ = c.g_signal_connect_data(adj, "changed", @ptrCast(&onCrumbAdjustment), null, null, c.G_CONNECT_DEFAULT);
    // This adjustment's page size IS the width the toolbar has left
    // over for the path, so it is also the signal that decides whether
    // the tool cluster still fits (view.zig owns that decision).
    _ = c.g_signal_connect_data(adj, "notify::page-size", @ptrCast(&BrowserView.onCrumbViewport), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(adj, "changed", @ptrCast(&BrowserView.onCrumbConfigured), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    // Double-clicking the path strip edits it, the way every file
    // manager's breadcrumb does. Bubble phase, so a single click on a
    // segment button still navigates.
    const edit_click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(edit_click), 1);
    _ = c.g_signal_connect_data(edit_click, "pressed", @ptrCast(&onPathDoubleClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(holder, @ptrCast(edit_click));

    self.locbar.scroller = sw;
    self.locbar.box = box;
}

/// Second press on the path strip = show the editable entry. Routed
/// through the toggle so `locbar.editing` cannot drift.
fn onPathDoubleClick(_: *c.GtkGestureClick, n_press: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    if (n_press != 2) return;
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (self.locbar.editing) return;
    self.toggleLocationFace();
}

/// A new segment set (or a resize) landed. The value cannot be set
/// from here: this signal is emitted from inside the adjustment's
/// own configure(), which assigns the value again right after and
/// would undo it. An idle carrying a REF to the adjustment (the
/// view may die first) does the pinning instead.
fn onCrumbAdjustment(adj: *c.GtkAdjustment, _: ?*anyopaque) callconv(.c) void {
    _ = c.g_object_ref(@ptrCast(adj));
    _ = c.g_idle_add(@ptrCast(&pinCrumbTail), @ptrCast(adj));
}

fn pinCrumbTail(user: ?*anyopaque) callconv(.c) c.gboolean {
    const adj: *c.GtkAdjustment = @ptrCast(@alignCast(user.?));
    const tail = c.gtk_adjustment_get_upper(adj) - c.gtk_adjustment_get_page_size(adj);
    if (tail > 0) c.gtk_adjustment_set_value(adj, tail);
    c.g_object_unref(@ptrCast(adj));
    return 0;
}

/// Hang the history dropdown of one side off a RIGHT-CLICK on the
/// back/forward button itself, the way Nemo does: the toolbar keeps
/// two nav buttons instead of four, and the several-steps-at-once
/// jump stays one gesture away.
pub fn installHistoryMenuGesture(self: *BrowserView, btn: *c.GtkWidget, side: HistorySide) void {
    const ctx = self.allocator.create(HistoryCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .view = self, .side = side, .steps = 0 };
    const gesture = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(gesture), 3);
    _ = c.g_signal_connect_data(gesture, "pressed", @ptrCast(&onHistoryGesture), @ptrCast(ctx), @ptrCast(&HistoryCtx.freeClosure), c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(btn, @ptrCast(gesture));
    c.gtk_widget_set_tooltip_text(btn, switch (side) {
        .back => "Back (Alt+Left). Right-click for recent locations.",
        .forward => "Forward (Alt+Right). Right-click for locations ahead.",
    });
}

fn onHistoryGesture(gesture: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx: *HistoryCtx = @ptrCast(@alignCast(user.?));
    const widget = c.gtk_event_controller_get_widget(@ptrCast(gesture)) orelse return;
    _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
    ctx.view.showHistoryMenu(widget, ctx.side);
}

/// Rebuild the breadcrumb for `tab`'s current location. Called from
/// syncPathEntry, so every committed navigation refreshes it.
pub fn rebuildCrumbs(self: *BrowserView, tab: *BTab) void {
    const box = self.locbar.box orelse return;
    // The pending dropdown belongs to buttons that are about to be
    // destroyed.
    self.cancelSiblings();
    while (c.gtk_widget_get_first_child(box)) |child|
        c.gtk_box_remove(@ptrCast(box), child);

    // A path whose listing was refused is NOT where you are: the
    // breadcrumb leads with a warning naming the reason, so the trail
    // cannot be read as a location that opened.
    if (tab.root.load_error) |why| {
        const warn = c.gtk_label_new("!");
        c.gtk_widget_add_css_class(warn, "error");
        var tip: [512:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&tip, "could not be opened: {s}", .{why}) catch null;
        c.gtk_widget_set_tooltip_text(warn, if (text) |t| t.ptr else "could not be opened");
        c.gtk_box_append(@ptrCast(box), warn);
    }

    var segs: [MAX_SEGMENTS]crumbs.Segment = undefined;
    const list = crumbs.split(tab.hc.host orelse "", tab.root.path, &segs);
    for (list) |seg| {
        if (seg.elided) {
            const dots = c.gtk_label_new("...");
            c.gtk_widget_add_css_class(dots, "dim-label");
            c.gtk_widget_set_tooltip_text(dots, "outer folders hidden (use the path entry with Ctrl+L)");
            c.gtk_box_append(@ptrCast(box), dots);
        }
        appendSegment(self, box, seg, tab);
    }
}

fn appendSegment(self: *BrowserView, box: *c.GtkWidget, seg: crumbs.Segment, tab: *BTab) void {
    var short_buf: [crumbs.MAX_LABEL_CHARS]u8 = undefined;
    const short = crumbs.shortLabel(seg.label, &short_buf);
    var label_z: [crumbs.MAX_LABEL_CHARS + 1:0]u8 = undefined;
    const n = @min(short.len, label_z.len - 1);
    @memcpy(label_z[0..n], short[0..n]);
    label_z[n] = 0;

    const btn = c.gtk_button_new_with_label(&label_z);
    // `.flat` as well as frameless: the hover/active rules in the
    // browser's stylesheet key off it, and a breadcrumb segment that
    // does not light up under the pointer does not read as clickable.
    toolbtn.flatten(btn.?);
    if (seg.root and tab.hc.host != null) c.gtk_widget_add_css_class(btn, "accent");
    var tip: [4200:0]u8 = undefined;
    if (std.fmt.bufPrintZ(&tip, "{s}", .{seg.path})) |t| c.gtk_widget_set_tooltip_text(btn, t.ptr) else |_| {}
    if (PathCtx.create(self, seg.path)) |ctx| {
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onCrumbClicked), @ptrCast(ctx), @ptrCast(&PathCtx.freeClosure), c.G_CONNECT_DEFAULT);
    }
    // A segment is a drop target for the same internal DnD the
    // listing accepts: dropping here targets that directory.
    if (PathCtx.create(self, seg.path)) |dctx| {
        const dropt = dnd.newTarget(tab);
        _ = c.g_signal_connect_data(dropt, "drop", @ptrCast(&onCrumbDrop), @ptrCast(dctx), @ptrCast(&PathCtx.freeClosure), c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(btn, @ptrCast(dropt));
    }
    c.gtk_box_append(@ptrCast(box), btn);

    const arrow = c.gtk_button_new_from_icon_name("pan-down-symbolic");
    toolbtn.flatten(arrow.?);
    c.gtk_widget_set_tooltip_text(arrow, if (seg.root)
        "Folders in this root"
    else
        "Folders beside this one");
    if (PathCtx.create(self, crumbs.dropdownSource(seg))) |actx| {
        _ = c.g_signal_connect_data(arrow, "clicked", @ptrCast(&onSiblingArrow), @ptrCast(actx), @ptrCast(&PathCtx.freeClosure), c.G_CONNECT_DEFAULT);
    }
    c.gtk_box_append(@ptrCast(box), arrow);
}

pub fn onCrumbClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PathCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = self.currentTab() orelse return;
    // Navigating rebuilds the bar, which destroys the button this
    // context belongs to: copy both strings out first.
    var pbuf: [4096]u8 = undefined;
    if (ctx.path.len >= pbuf.len) return;
    @memcpy(pbuf[0..ctx.path.len], ctx.path);
    var hbuf: [256]u8 = undefined;
    var host: ?[]const u8 = null;
    if (tab.hc.host) |h| {
        if (h.len >= hbuf.len) return;
        @memcpy(hbuf[0..h.len], h);
        host = hbuf[0..h.len];
    }
    self.navigate(tab, host, pbuf[0..ctx.path.len]);
}

pub fn onCrumbDrop(target: *c.GtkDropTarget, value: *c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx: *PathCtx = @ptrCast(@alignCast(user.?));
    const tab = ctx.view.currentTab() orelse return 0;
    return @intFromBool(dropValueIntoAction(ctx.view, tab, value, ctx.path, dnd.dropAction(target, tab)));
}

/// Ask the host for the dropdown's directory listing. The popover is
/// built in feedSiblings when the reply lands.
pub fn onSiblingArrow(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PathCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = self.currentTab() orelse return;
    if (tab.hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{tab.hc.label()});
        return;
    }
    self.cancelSiblings();
    const request = self.allocator.create(SiblingReq) catch return;
    const parent = self.allocator.dupe(u8, ctx.path) catch {
        self.allocator.destroy(request);
        return;
    };
    // The child of `parent` we are currently inside, so the list can
    // mark where we are. It is the next segment on the way to the
    // current directory, NOT its basename: a dropdown higher up the
    // path marks its own level.
    const inside = millerNextSegment(ctx.path, tab.root.path) orelse "";
    const current = self.allocator.dupe(u8, inside) catch {
        self.allocator.free(parent);
        self.allocator.destroy(request);
        return;
    };
    request.* = .{
        .req = self.nextReq(),
        .hc = tab.hc,
        .anchor = @ptrCast(@alignCast(btn)),
        .parent = parent,
        .current = current,
        .show_hidden = tab.show_hidden,
    };
    self.locbar.siblings = request;
    self.sendOp(tab.hc, .{ .req = request.req, .op = "list", .path = request.parent });
}

pub fn cancelSiblings(self: *BrowserView) void {
    if (self.locbar.siblings) |s| {
        s.destroy(self.allocator);
        self.locbar.siblings = null;
    }
}

/// Consume a listing reply that belongs to an open segment dropdown.
/// @return true when the reply was ours.
pub fn feedSiblings(self: *BrowserView, hc: *HostConn, rep: WireReply) bool {
    const request = self.locbar.siblings orelse return false;
    if (request.hc != hc or request.req != rep.req) return false;
    if (!rep.ok) {
        self.setStatusFmt("cannot list {s}: {s}", .{ request.parent, rep.@"error" });
        self.cancelSiblings();
        return true;
    }
    for (rep.entries) |entry| {
        if (!entry.tdir) continue;
        if (!request.show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
        if (request.names.items.len >= MAX_DROPDOWN_ROWS) break;
        const owned = self.allocator.dupe(u8, entry.name) catch continue;
        request.names.append(self.allocator, owned) catch self.allocator.free(owned);
    }
    if (!rep.more) {
        self.showSiblingPopover(request);
        self.cancelSiblings();
    }
    return true;
}

pub fn showSiblingPopover(self: *BrowserView, request: *SiblingReq) void {
    if (request.names.items.len == 0) {
        self.setStatusFmt("no folders in {s}", .{request.parent});
        return;
    }
    const pop = c.gtk_popover_new();
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_NONE);
    c.gtk_list_box_set_activate_on_single_click(@ptrCast(list), 1);
    for (request.names.items) |name| {
        var full: [4300]u8 = undefined;
        const path = std.fmt.bufPrint(&full, "{s}/{s}", .{
            if (request.parent.len == 1) "" else request.parent, name,
        }) catch continue;
        const ctx = PathCtx.create(self, path) orelse continue;
        const row = c.gtk_list_box_row_new();
        var name_z: [512:0]u8 = undefined;
        const n = @min(name.len, name_z.len - 1);
        @memcpy(name_z[0..n], name[0..n]);
        name_z[n] = 0;
        const label = c.gtk_label_new(&name_z);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        if (std.mem.eql(u8, name, request.current)) c.gtk_widget_add_css_class(label, "heading");
        c.gtk_list_box_row_set_child(@ptrCast(row), label);
        c.g_object_set_data_full(@ptrCast(row), "sketerm-crumb", @ptrCast(ctx), @ptrCast(&PathCtx.free));
        c.gtk_list_box_append(@ptrCast(list), row);
    }
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onSiblingActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    const scroll = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_size_request(scroll, 240, @min(360, @as(c_int, @intCast(request.names.items.len)) * 34 + 8));
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), list);
    c.gtk_popover_set_child(@ptrCast(pop), scroll);
    popupAnchored(pop, request.anchor);
}

/// Pop `pop` under `anchor`. A popover with a large child and no
/// pointing_to rect silently fails to map, so the rect is explicit.
fn popupAnchored(pop: *c.GtkWidget, anchor: *c.GtkWidget) void {
    c.gtk_widget_set_parent(pop, anchor);
    connectPopoverAutoUnparent(pop);
    const rect = c.GdkRectangle{
        .x = @divFloor(c.gtk_widget_get_width(anchor), 2),
        .y = c.gtk_widget_get_height(anchor),
        .width = 1,
        .height = 1,
    };
    c.gtk_popover_set_pointing_to(@ptrCast(pop), &rect);
    c.gtk_popover_popup(@ptrCast(pop));
}

pub fn onSiblingActivated(list: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-crumb") orelse return;
    const ctx: *PathCtx = @ptrCast(@alignCast(data));
    var path_buf: [4200]u8 = undefined;
    if (ctx.path.len >= path_buf.len) return;
    @memcpy(path_buf[0..ctx.path.len], ctx.path);
    const path = path_buf[0..ctx.path.len];
    // The popover (and the row's ctx with it) dies before the
    // navigation touches anything.
    if (c.gtk_widget_get_ancestor(@ptrCast(@alignCast(list)), c.gtk_popover_get_type())) |pop|
        c.gtk_popover_popdown(@ptrCast(pop));
    const tab = self.currentTab() orelse return;
    var hbuf: [256]u8 = undefined;
    var host: ?[]const u8 = null;
    if (tab.hc.host) |h| {
        if (h.len >= hbuf.len) return;
        @memcpy(hbuf[0..h.len], h);
        host = hbuf[0..h.len];
    }
    self.navigate(tab, host, path);
}

// -- the editable-entry face -------------------------------------

/// Ctrl+L: swap between the breadcrumb and the editable path entry.
pub fn toggleLocationFace(self: *BrowserView) void {
    if (self.locbar.editing) {
        _ = self.showCrumbFace();
    } else {
        self.showEntryFace();
    }
}

pub fn showEntryFace(self: *BrowserView) void {
    const sw = self.locbar.scroller orelse return;
    self.locbar.editing = true;
    c.gtk_widget_set_visible(sw, 0);
    c.gtk_widget_set_visible(@ptrCast(@alignCast(self.path_entry)), 1);
    _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(self.path_entry)));
    c.gtk_editable_select_region(@ptrCast(self.path_entry), 0, -1);
}

/// Back to the breadcrumb; focus returns to the listing so type-ahead
/// and the arrow keys work again.
/// @return false when the entry face was not showing.
pub fn showCrumbFace(self: *BrowserView) bool {
    if (!foldLocationFace(self)) return false;
    if (self.currentTab()) |tab| _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(tab.colview)));
    return true;
}

/// Back to the breadcrumb WITHOUT taking focus, for folding a pane
/// the user just left. `showCrumbFace` pulls focus back into the
/// listing, which is right for the pane being abandoned by its own
/// Escape and wrong for one being abandoned for another pane.
pub fn foldLocationFace(self: *BrowserView) bool {
    const sw = self.locbar.scroller orelse return false;
    if (!self.locbar.editing) return false;
    self.locbar.editing = false;
    self.cancelPathCompletion();
    c.gtk_widget_set_visible(@ptrCast(@alignCast(self.path_entry)), 0);
    c.gtk_widget_set_visible(sw, 1);
    return true;
}

// -- history dropdowns and side buttons --------------------------

/// Pop the actual history entries of one side, newest first, so a
/// user can jump several steps at once.
pub fn showHistoryMenu(self: *BrowserView, anchor: *c.GtkWidget, side: HistorySide) void {
    const tab = self.currentTab() orelse return;
    const entries = if (side == .back) tab.back.items else tab.fwd.items;
    if (entries.len == 0) {
        self.setStatus(if (side == .back) "no locations behind" else "no locations ahead");
        return;
    }
    const pop = c.gtk_popover_new();
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_NONE);
    c.gtk_list_box_set_activate_on_single_click(@ptrCast(list), 1);
    var steps: usize = 1;
    while (steps <= entries.len and steps <= MAX_DROPDOWN_ROWS) : (steps += 1) {
        const spec = entries[entries.len - steps];
        const ctx = self.allocator.create(HistoryCtx) catch break;
        ctx.* = .{ .allocator = self.allocator, .view = self, .side = side, .steps = steps };
        const row = c.gtk_list_box_row_new();
        var spec_z: [512:0]u8 = undefined;
        const n = @min(spec.len, spec_z.len - 1);
        @memcpy(spec_z[0..n], spec[0..n]);
        spec_z[n] = 0;
        const label = c.gtk_label_new(&spec_z);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(@ptrCast(label), 48);
        c.gtk_list_box_row_set_child(@ptrCast(row), label);
        c.g_object_set_data_full(@ptrCast(row), "sketerm-history", @ptrCast(ctx), @ptrCast(&HistoryCtx.free));
        c.gtk_list_box_append(@ptrCast(list), row);
    }
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onHistoryActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    const scroll = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_size_request(scroll, 320, @min(360, @as(c_int, @intCast(entries.len)) * 34 + 8));
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), list);
    c.gtk_popover_set_child(@ptrCast(pop), scroll);
    popupAnchored(pop, anchor);
}

pub fn onHistoryActivated(list: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-history") orelse return;
    const ctx: *HistoryCtx = @ptrCast(@alignCast(data));
    const side = ctx.side;
    const steps = ctx.steps;
    if (c.gtk_widget_get_ancestor(@ptrCast(@alignCast(list)), c.gtk_popover_get_type())) |pop|
        c.gtk_popover_popdown(@ptrCast(pop));
    const tab = self.currentTab() orelse return;
    self.historyJump(tab, side, steps);
}

/// Travel `steps` entries along one history stack in a single
/// navigation. The skipped entries move to the opposite stack, so
/// the jump is exactly the sequence of single steps it replaces.
pub fn historyJump(self: *BrowserView, tab: *BTab, side: HistorySide, steps: usize) void {
    const entries = if (side == .back) tab.back.items else tab.fwd.items;
    if (steps == 0 or steps > entries.len) return;
    const spec = entries[entries.len - steps];
    self.navigateSpecMode(tab, spec, switch (side) {
        .back => .{ .back = steps },
        .forward => .{ .forward = steps },
    });
}

/// Mouse side buttons (8 = back, 9 = forward) over the listing.
pub fn installNavGestures(self: *BrowserView, tab: *BTab, widget: *c.GtkWidget) void {
    _ = self;
    const gesture = c.gtk_gesture_click_new();
    // Button 0 = every button; the handler ignores all but 8 and 9,
    // so the ordinary click/right-click gestures keep their events.
    c.gtk_gesture_single_set_button(@ptrCast(gesture), 0);
    _ = c.g_signal_connect_data(gesture, "pressed", @ptrCast(&onSideButton), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(widget, @ptrCast(gesture));
}

pub fn onSideButton(gesture: *c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    switch (c.gtk_gesture_single_get_current_button(@ptrCast(gesture))) {
        8 => tab.view.goBack(tab),
        9 => tab.view.goForward(tab),
        else => return,
    }
    _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
}
