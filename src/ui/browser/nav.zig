//! Browser tabs, navigation and the path bar.
//!
//! Tabs are cheap VIEW state; history entries are host-qualified SPEC
//! strings so back/forward can cross hosts. Also holds the path-entry
//! completion popover, select-by-pattern and the type-ahead jump.

const std = @import("std");
const c = @import("../../c.zig").c;
const fsjob = @import("../../mux/fsjob.zig");
const input = @import("../input.zig");
const places_mod = @import("../../filebrowser/places.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const BypassHit = @import("../../filebrowser/paths.zig").BypassHit;
const Dir = @import("types.zig").Dir;
const Entry = @import("types.zig").Entry;
const HostConn = @import("types.zig").HostConn;
const NavigationIntent = @import("types.zig").NavigationIntent;
const Pending = @import("types.zig").Pending;
const colview = @import("colview.zig");
const render_mod = @import("render.zig");
const selection = @import("selection.zig");
const completionMatches = @import("../../filebrowser/paths.zig").completionMatches;
const hostEq = @import("../../filebrowser/paths.zig").hostEq;
const mountBypass = @import("../../filebrowser/paths.zig").mountBypass;
const parseSpec = @import("../../filebrowser/paths.zig").parseSpec;

pub const PathCompletion = struct {
    req: u32,
    hc: *HostConn,
    display_prefix: []u8,
    typed_prefix: []u8,
    names: std.ArrayList([]u8) = .empty,

    pub fn destroy(self: *PathCompletion, allocator: std.mem.Allocator) void {
        allocator.free(self.display_prefix);
        allocator.free(self.typed_prefix);
        for (self.names.items) |name| allocator.free(name);
        self.names.deinit(allocator);
        allocator.destroy(self);
    }
};

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
    // These three failures are all out-of-memory; say so rather than
    // return null to a caller that has no way to tell the user.
    const hc = self.hostConnFor(host) orelse {
        self.setStatus("cannot open a tab: out of memory");
        return null;
    };
    const dir = self.makeDir(path) orelse {
        self.setStatus("cannot open a tab: out of memory");
        return null;
    };
    const tab = self.allocator.create(BTab) catch {
        dir.deinit();
        self.setStatus("cannot open a tab: out of memory");
        return null;
    };

    const page = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(page, 1);
    c.gtk_widget_set_vexpand(page, 1);

    const content = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_hexpand(content, 1);
    c.gtk_widget_set_vexpand(content, 1);
    const miller_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_visible(miller_box, 0);
    c.gtk_box_append(@ptrCast(content), miller_box);

    // The listing area's own message: shown instead of the rows when
    // there are none, so "empty", "still listing", "no matches" and
    // "refused, and here is why" can never look alike.
    const empty_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
    c.gtk_widget_set_hexpand(empty_box, 1);
    c.gtk_widget_set_vexpand(empty_box, 1);
    c.gtk_widget_set_valign(empty_box, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_halign(empty_box, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_visible(empty_box, 0);
    // Focusable on purpose: while this shows, the rows are hidden, and
    // a hidden widget cannot hold focus. Without somewhere for focus to
    // land inside the browser face, its chords (Ctrl+Shift+B included)
    // stop reaching it the moment a listing comes up empty.
    c.gtk_widget_set_focusable(empty_box, 1);
    const empty_title = c.gtk_label_new("");
    c.gtk_widget_add_css_class(empty_title, "title-2");
    c.gtk_label_set_wrap(@ptrCast(empty_title), 1);
    c.gtk_label_set_justify(@ptrCast(empty_title), c.GTK_JUSTIFY_CENTER);
    c.gtk_box_append(@ptrCast(empty_box), empty_title);
    const empty_detail = c.gtk_label_new("");
    c.gtk_widget_add_css_class(empty_detail, "dim-label");
    c.gtk_label_set_wrap(@ptrCast(empty_detail), 1);
    c.gtk_label_set_max_width_chars(@ptrCast(empty_detail), 60);
    // NOT selectable: a selectable label is focusable and swallows key
    // presses, which silently killed every browser chord (Ctrl+Shift+B
    // included) as soon as this message was the only thing on screen.
    c.gtk_label_set_justify(@ptrCast(empty_detail), c.GTK_JUSTIFY_CENTER);
    c.gtk_box_append(@ptrCast(empty_box), empty_detail);
    c.gtk_box_append(@ptrCast(content), empty_box);

    const scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_hexpand(scroller, 1);
    c.gtk_widget_set_vexpand(scroller, 1);
    // The GtkColumnView is the scrollable child: its header stays
    // pinned while the rows scroll, and an over-wide column set gets
    // a REAL horizontal scrollbar moving header and rows as one
    // widget (they are one widget).
    c.gtk_scrolled_window_set_overlay_scrolling(@ptrCast(scroller), 1);
    c.gtk_box_append(@ptrCast(content), scroller);
    c.gtk_box_append(@ptrCast(page), content);

    tab.* = .{
        .view = self,
        .hc = hc,
        .root = dir,
        .page = page,
        .colview = undefined,
        .tab_label = undefined,
        .scroller = scroller,
        .miller_box = miller_box,
        .empty_box = empty_box,
        .empty_title = @ptrCast(@alignCast(empty_title)),
        .empty_detail = @ptrCast(@alignCast(empty_detail)),
    };
    self.tabs.append(self.allocator, tab) catch {
        tab.root.deinit();
        self.allocator.destroy(tab);
        return null;
    };

    // The listing itself: model, columns, activation, selection,
    // context-menu/sticky/key controllers and the DnD target all
    // live in colview.zig.
    const cv = colview.installColumnView(self, tab);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), cv);
    // A narrower viewport must shrink the Name column, not push the
    // rest of the columns behind a horizontal scrollbar.
    colview.installWidthFit(tab);

    // The content box behind the rows: the background menu for the
    // states where the rows are HIDDEN (empty folder, failed listing)
    // and the column view's gesture therefore cannot fire. Bubble
    // phase and gated on empty_box visibility, so it never doubles
    // the view's own background menu.
    const area_click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(area_click), 3);
    _ = c.g_signal_connect_data(area_click, "pressed", @ptrCast(&@import("menu.zig").onAreaRightClick), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(content, @ptrCast(area_click));

    // Mouse side buttons navigate history anywhere in the listing;
    // middle click opens folders in tabs and closes this one.
    self.installNavGestures(tab, page);
    // Ctrl+wheel zoom, then the config defaults, then the folder's
    // remembered view settings (an explicit TabState restore runs
    // after newTab and wins over everything).
    self.installViewGestures(tab, page);
    if (self.ownerWindow()) |win| {
        tab.view_mode = switch (win.config.files_default_view) {
            .details => .details,
            .compact => .compact,
            .icons => .icons,
            .miller => .miller,
        };
        tab.show_hidden = win.config.files_show_hidden;
    }
    self.applyFolderMemory(tab);

    // The label + close button + middle-click/scroll gestures are the
    // shared tab-host recipe; the browser layers its own right-click
    // menu and file-drop target on the returned label box.
    const handle = self.tabhost.addPage(page.?, "...") orelse {
        for (self.tabs.items, 0..) |t, j| {
            if (t == tab) {
                _ = self.tabs.orderedRemove(j);
                break;
            }
        }
        colview.invalidateBackingRefs(tab);
        tab.deinit();
        self.setStatus("cannot open a tab: out of memory");
        return null;
    };
    tab.tab_label = handle.label;
    self.installTabConveniences(tab, handle.box);
    self.tabhost.setCurrentPage(page.?);
    self.updateTabLabel(tab);
    self.openDir(tab, dir);
    // Render once now: the listing area then says "Listing..." (or the
    // refusal, when the host is already known to be unreachable)
    // instead of showing a blank that reads as an empty folder.
    self.renderTab(tab);
    self.syncPathEntry(tab);
    self.refreshGitOverlay(tab);
    if (hc.state == .connecting) self.setStatusFmt("connecting to {s}…", .{hc.label()});
    return tab;
}

pub fn currentTab(self: *BrowserView) ?*BTab {
    const idx = c.gtk_notebook_get_current_page(self.notebook);
    if (idx < 0) return null;
    const page = c.gtk_notebook_get_nth_page(self.notebook, idx) orelse return null;
    for (self.tabs.items) |t| {
        if (t.page == page) return t;
    }
    return null;
}

pub fn onTabCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    tab.view.closeTab(tab);
}

pub fn closeTab(self: *BrowserView, tab: *BTab) void {
    // Snapshot first: undo-close-tab needs the location AND the
    // history this is about to free.
    self.stashClosedTab(tab);
    @import("ops.zig").cancelDropStateForTab(self, tab);
    self.visualForget(tab);
    if (self.register_tab == tab) self.register_tab = null;
    if (self.arch_tab == tab) {
        self.arch_tab = null;
        self.arch_job = 0;
    }
    var i: usize = 0;
    while (i < self.pending.items.len) {
        if (self.pending.items[i].tab == tab) self.dropPending(i) else i += 1;
    }
    // Both of these must run while the page's widgets are still
    // alive: the tab's extra reference on the column view's sorter
    // must not outlive the view (BTab.releaseSorter), and fencing the
    // recycled cells reads the view's list model.
    tab.releaseSorter();
    colview.invalidateBackingRefs(tab);
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
pub fn navigate(self: *BrowserView, tab: *BTab, host_in: ?[]const u8, path_in: []const u8) void {
    self.navigateMode(tab, host_in, path_in, .push);
}

pub fn navigateMode(self: *BrowserView, tab: *BTab, host_in: ?[]const u8, path_in: []const u8, intent: NavigationIntent) void {
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
    if (same_host and tab.hc.state != .dead and std.mem.eql(u8, tab.root.path, path)) {
        // Already there: nothing to list, but a history move still
        // has to walk the stacks (a location can repeat in them).
        switch (intent) {
            .push => {},
            else => {
                self.applyHistoryIntent(tab, intent);
                self.syncPathEntry(tab);
            },
        }
        return;
    }
    const new_hc = if (same_host and tab.hc.state != .dead)
        tab.hc
    else
        self.hostConnFor(host) orelse return;
    const new_dir = self.makeDir(path) orelse return;
    tab.navigation_generation +%= 1;
    if (tab.navigation_generation == 0) tab.navigation_generation = 1;
    // Navigation is transactional: the visible root and history do
    // not change until the candidate listing succeeds.
    const p = self.allocator.create(Pending) catch {
        new_dir.deinit();
        return;
    };
    p.* = .{ .req = self.nextReq(), .tab = tab, .dir = new_dir, .hc = new_hc, .op = .open_view, .navigation = intent, .navigation_generation = tab.navigation_generation };
    self.pending.append(self.allocator, p) catch {
        self.allocator.destroy(p);
        new_dir.deinit();
        return;
    };
    if (new_hc.state == .dead) {
        self.setStatus("destination host is unavailable");
        self.dropPending(self.pending.items.len - 1);
        return;
    }
    // The location changes NOW: the click's feedback is immediate —
    // an empty streaming page whose rows fill in as chunks land, not
    // a frozen click while a slow host computes the first reply.
    // Ownership of the candidate moves to the tab here (navigation
    // nulled, so no later dropPending frees it); a refused listing
    // lands as a load error on the visible dir, and Back works
    // because the history move already happened.
    new_dir.streaming = true;
    p.navigation = null;
    self.commitNavigation(tab, new_hc, new_dir, intent, "");
    if (new_hc.state == .ready) self.sendListingOp(p);
}

pub fn navigateSpec(self: *BrowserView, tab: *BTab, spec: []const u8) void {
    self.navigateSpecMode(tab, spec, .push);
}

pub fn navigateSpecMode(self: *BrowserView, tab: *BTab, spec: []const u8, intent: NavigationIntent) void {
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

pub fn goBack(self: *BrowserView, tab: *BTab) void {
    if (tab.back.items.len == 0) return;
    self.navigateSpecMode(tab, tab.back.items[tab.back.items.len - 1], .{ .back = 1 });
}

pub fn goForward(self: *BrowserView, tab: *BTab) void {
    if (tab.fwd.items.len == 0) return;
    self.navigateSpecMode(tab, tab.fwd.items[tab.fwd.items.len - 1], .{ .forward = 1 });
}

/// Move the tab's history stacks for a navigation that has landed.
/// A multi-step jump is exactly the sequence of single steps it
/// replaces: every entry it skipped ends up on the opposite stack,
/// nearest first.
pub fn applyHistoryIntent(self: *BrowserView, tab: *BTab, intent: NavigationIntent) void {
    var current_buf: [4300]u8 = undefined;
    const current = self.allocator.dupe(u8, tab.spec(&current_buf)) catch null;
    switch (intent) {
        .push => {
            if (current) |value| tab.back.append(self.allocator, value) catch self.allocator.free(value);
            for (tab.fwd.items) |value| self.allocator.free(value);
            tab.fwd.clearRetainingCapacity();
        },
        .back => |steps| {
            if (current) |value| tab.fwd.append(self.allocator, value) catch self.allocator.free(value);
            var i: usize = 1;
            while (i < steps) : (i += 1) {
                const skipped = tab.back.pop() orelse break;
                tab.fwd.append(self.allocator, skipped) catch self.allocator.free(skipped);
            }
            if (tab.back.pop()) |value| self.allocator.free(value);
        },
        .forward => |steps| {
            if (current) |value| tab.back.append(self.allocator, value) catch self.allocator.free(value);
            var i: usize = 1;
            while (i < steps) : (i += 1) {
                const skipped = tab.fwd.pop() orelse break;
                tab.back.append(self.allocator, skipped) catch self.allocator.free(skipped);
            }
            if (tab.fwd.pop()) |value| self.allocator.free(value);
        },
    }
    while (tab.back.items.len > 100) self.allocator.free(tab.back.orderedRemove(0));
    while (tab.fwd.items.len > 100) self.allocator.free(tab.fwd.orderedRemove(0));
}

const FreeNavigationState = struct { req: u32, dirty: bool };

fn freeNavigationState(req: u32, previous_host_ready: bool) FreeNavigationState {
    if (req != 0 and previous_host_ready) return .{ .req = req, .dirty = true };
    return .{ .req = 0, .dirty = false };
}

pub fn commitNavigation(self: *BrowserView, tab: *BTab, hc: *HostConn, candidate: *Dir, intent: NavigationIntent, canonical: []const u8) void {
    if (tab.pending_reveal) |path| {
        const parent = std.fs.path.dirname(path) orelse "/";
        const reveal_host = tab.pending_reveal_host orelse "";
        const target_host = hc.host orelse "";
        if (!std.mem.eql(u8, parent, candidate.path) or !std.mem.eql(u8, reveal_host, target_host)) {
            self.allocator.free(path);
            tab.pending_reveal = null;
            if (tab.pending_reveal_host) |host| self.allocator.free(host);
            tab.pending_reveal_host = null;
        }
    }
    if (canonical.len > 0 and !std.mem.eql(u8, candidate.path, canonical)) {
        const owned = self.allocator.dupe(u8, canonical) catch null;
        if (owned) |path| {
            self.allocator.free(candidate.path);
            candidate.path = path;
        }
    }
    // A landed navigation settles the previous refusal.
    tab.clearNavError();
    self.applyHistoryIntent(tab, intent);
    for (tab.selected.items) |value| self.allocator.free(value);
    tab.selected.clearRetainingCapacity();
    // The rows the visual range was anchored in are about to go.
    self.visualForget(tab);
    self.ta_len = 0;
    // A column-set rebuild can bind recycled cells before renderList
    // splices the new items. Fence those items off the old directory
    // before any of its backing storage is released.
    colview.invalidateBackingRefs(tab);
    tab.dropSubdirsUnder(tab.root.path);
    self.cancelPendingDir(tab.root);
    self.closeViewOf(tab.hc, tab.root);
    tab.root.deinit();
    tab.root = candidate;
    const free_state = freeNavigationState(tab.free_req, tab.hc.state == .ready);
    tab.hc = hc;
    // The old root may have lived on another filesystem. Never show
    // its capacity while the new root's statfs is in flight. Preserve
    // a request that can still answer: its late reply triggers exactly
    // one refresh for this new root instead of becoming unrecognized.
    tab.free_bytes = null;
    tab.free_req = free_state.req;
    tab.free_dirty = free_state.dirty;
    // A running query (flat view, search results) belonged to the OLD
    // root; the new folder brings its own remembered view settings,
    // and the host job has nothing left to fill.
    self.queryForget(tab);
    // A media batch in flight was asked for rows that no longer
    // exist; its answers would be paid for and thrown away.
    self.mediaResetForNavigation();
    // Queued thumbnail fetches belonged to the rows just left behind;
    // the new folder's rows re-queue theirs at first render.
    self.dropQueuedThumbs();
    self.applyFolderMemory(tab);
    self.updateTabLabel(tab);
    self.syncPathEntry(tab);
    self.renderTab(tab);
    self.refreshGitOverlay(tab);
    var recent_buf: [4300]u8 = undefined;
    self.recordRecentSpec(tab.spec(&recent_buf));
    // The picker hook covers LOCATION changes as well as selection
    // ones: its name entry holds a name that only meant something in
    // the directory just left.
    if (self.picker) |pk| pk.on_selection_changed(pk.ctx);
    // The row (or breadcrumb button) that was clicked to get here has
    // just been destroyed with its widget; GTK then moves focus to
    // whatever visible widget it finds -- outside the browser -- and
    // every chord stops working.
    self.refocusListingAfterNav();
}

pub fn goUp(self: *BrowserView, tab: *BTab) void {
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

pub fn toggleExpand(self: *BrowserView, tab: *BTab, dir_path: []const u8) void {
    if (tab.subdirByPath(dir_path)) |_| {
        colview.invalidateBackingRefs(tab);
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

pub fn updateTabLabel(self: *BrowserView, tab: *BTab) void {
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

pub fn syncPathEntry(self: *BrowserView, tab: *BTab) void {
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
    // A location that could not be opened must not be presented as the
    // one you are looking at: both faces of the control carry the
    // error style while the tab's own listing is refused.
    const refused = tab.root.load_error != null;
    if (refused)
        c.gtk_widget_add_css_class(@ptrCast(@alignCast(self.path_entry)), "error")
    else
        c.gtk_widget_remove_css_class(@ptrCast(@alignCast(self.path_entry)), "error");
    // The entry no longer holds what the user was completing.
    self.cancelPathCompletion();
    // The breadcrumb is the same location control's other face.
    self.rebuildCrumbs(tab);
    c.gtk_widget_set_sensitive(self.back_button, @intFromBool(tab.back.items.len > 0));
    c.gtk_widget_set_sensitive(self.fwd_button, @intFromBool(tab.fwd.items.len > 0));
}

pub fn setStatus(self: *BrowserView, msg: []const u8) void {
    var buf: [256:0]u8 = undefined;
    const n = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    c.gtk_label_set_text(self.status_label, &buf);
}

pub fn setStatusFmt(self: *BrowserView, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    self.setStatus(msg);
}

pub fn countSelected(tab: *BTab) usize {
    return colview.countSelected(tab);
}

/// The listing entry `path` names in `tab`, or null when the tab no
/// longer holds it.
///
/// The ordinary case is resolved by parent directory (O(1) dir
/// lookup). A FLAT tab -- search results, panelize output, registers
/// -- has rows from anywhere under one Dir, keyed by `target`, so its
/// root is asked directly; before that, every caller silently got
/// null for a search hit and quietly lost preview metadata,
/// Properties and the file-vs-directory verdict on those rows.
pub fn entryForPath(tab: *BTab, path: []const u8) ?*Entry {
    if (tab.root.findPath(path)) |e| return e;
    // Expanded subdirectories: only the ordinary form can match, and
    // findPath rejects a non-matching parent in one comparison.
    for (tab.subdirs.items) |d| {
        if (d.findPath(path)) |e| return e;
    }
    for (tab.ancestors.items) |d| {
        if (d.findPath(path)) |e| return e;
    }
    return null;
}

/// One chord the browser face claims before the global binding table
/// ever sees it.
///
/// This table IS the enumeration: `onBrowserKey` dispatches through
/// it, and the audit test below cross-references every entry against
/// `input.default_bindings`, so a chord that starts shadowing a
/// global action fails the suite instead of waiting for a reviewer.
pub const Chord = struct {
    /// Lower-cased keyval (`gdk_keyval_to_lower` is identity for the
    /// non-letter keys, so the handler can match one form).
    keyval: c_uint,
    mods: c_uint,
    /// What the browser face does with it (audit failure message).
    what: []const u8,
    /// The global action this DELIBERATELY shadows while the browser
    /// face has focus. Non-null is the allow-list: null means the
    /// chord must stay free in `input.zig`.
    shadows: ?input.Action = null,
    /// Returns true when the chord was consumed; false keeps
    /// dispatching (conditional chords: F5 without a peer pane,
    /// Escape with no type-ahead prefix, Space mid-word).
    /// null = the chord is consumed by a per-tab CAPTURE-phase
    /// controller instead (visual mode's movement keys, which
    /// GtkListBox would otherwise swallow before this handler runs);
    /// it is listed here so the audit still covers it.
    run: ?*const fn (self: *BrowserView) bool = null,
};

/// The chords the browser face intercepts, and why the two shadowed
/// globals are intentional:
///
/// - Ctrl+Shift+A shadows `copy_screen`. The browser face COVERS the
///   pane's terminal, so copying its screen has no visible subject;
///   Ctrl+Shift+A is Dolphin's invert-selection chord.
/// - Ctrl+Shift+X shadows `copy_mode`. Copy mode is the terminal's
///   keyboard-selection mode; visual select mode is the browser's.
///   Same chord, same concept, whichever face is showing.
///
/// Everything else here is free in `input.zig` and the audit test
/// keeps it that way. Note that these chords are HARDCODED: a user
/// who rebinds an action in config.conf changes the global table
/// (which this handler still consults, last), not this list.
pub const browser_chords = [_]Chord{
    .{ .keyval = c.GDK_KEY_z, .mods = c.GDK_CONTROL_MASK, .what = "undo", .run = &chordUndo },
    .{ .keyval = c.GDK_KEY_y, .mods = c.GDK_CONTROL_MASK, .what = "redo", .run = &chordRedo },
    .{ .keyval = c.GDK_KEY_l, .mods = c.GDK_CONTROL_MASK, .what = "edit location", .run = &chordLocation },
    .{ .keyval = c.GDK_KEY_s, .mods = c.GDK_CONTROL_MASK, .what = "select by pattern", .run = &chordSelectPattern },
    .{ .keyval = c.GDK_KEY_a, .mods = c.GDK_CONTROL_MASK, .what = "select all", .run = &chordSelectAll },
    .{
        .keyval = c.GDK_KEY_a,
        .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK,
        .what = "invert selection",
        .shadows = .copy_screen,
        .run = &chordInvertSelection,
    },
    .{ .keyval = c.GDK_KEY_x, .mods = c.GDK_CONTROL_MASK, .what = "cut selection", .run = &chordCut },
    .{ .keyval = c.GDK_KEY_c, .mods = c.GDK_CONTROL_MASK, .what = "copy selection", .run = &chordCopy },
    .{ .keyval = c.GDK_KEY_v, .mods = c.GDK_CONTROL_MASK, .what = "paste", .run = &chordPaste },
    .{ .keyval = c.GDK_KEY_i, .mods = c.GDK_CONTROL_MASK, .what = "filter listing", .run = &chordFilter },
    .{ .keyval = c.GDK_KEY_b, .mods = c.GDK_CONTROL_MASK, .what = "flat view", .run = &chordFlat },
    .{ .keyval = c.GDK_KEY_m, .mods = c.GDK_CONTROL_MASK, .what = "mark selection in a register", .run = &selection.chordMark },
    .{ .keyval = c.GDK_KEY_d, .mods = c.GDK_CONTROL_MASK, .what = "bookmark current folder", .run = &chordBookmark },
    .{ .keyval = c.GDK_KEY_j, .mods = c.GDK_CONTROL_MASK, .what = "frecency jump", .run = &chordJump },
    .{
        .keyval = c.GDK_KEY_j,
        .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK,
        .what = "toggle the transfer center",
        .run = &chordTransfers,
    },
    .{
        .keyval = c.GDK_KEY_x,
        .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK,
        .what = "visual select mode",
        .shadows = .copy_mode,
        .run = &selection.chordVisual,
    },
    // Marking is capture phase too: GtkListBox binds Ctrl+Space to
    // activate-cursor-row, which OPENS the focused file.
    .{ .keyval = c.GDK_KEY_Insert, .mods = 0, .what = "toggle mark, step down" },
    .{ .keyval = c.GDK_KEY_space, .mods = c.GDK_CONTROL_MASK, .what = "toggle mark, step down" },
    .{ .keyval = c.GDK_KEY_KP_Space, .mods = c.GDK_CONTROL_MASK, .what = "toggle mark, step down" },
    // Tree navigation, consumed by selection.zig's capture handler.
    .{ .keyval = c.GDK_KEY_Right, .mods = 0, .what = "expand focused directory (tree)" },
    .{ .keyval = c.GDK_KEY_Left, .mods = 0, .what = "collapse focused directory / go to parent row (tree)" },
    .{ .keyval = c.GDK_KEY_Left, .mods = c.GDK_ALT_MASK, .what = "back", .run = &chordBack },
    .{ .keyval = c.GDK_KEY_Right, .mods = c.GDK_ALT_MASK, .what = "forward", .run = &chordForward },
    .{ .keyval = c.GDK_KEY_Up, .mods = c.GDK_ALT_MASK, .what = "up one directory", .run = &chordUp },
    .{ .keyval = c.GDK_KEY_F2, .mods = 0, .what = "rename", .run = &chordRename },
    .{ .keyval = c.GDK_KEY_Delete, .mods = 0, .what = "move selection to trash", .run = &chordTrash },
    .{ .keyval = c.GDK_KEY_KP_Delete, .mods = 0, .what = "move selection to trash", .run = &chordTrash },
    .{ .keyval = c.GDK_KEY_Delete, .mods = c.GDK_SHIFT_MASK, .what = "permanently delete selection (confirmed)", .run = &chordDelete },
    .{ .keyval = c.GDK_KEY_KP_Delete, .mods = c.GDK_SHIFT_MASK, .what = "permanently delete selection (confirmed)", .run = &chordDelete },
    .{ .keyval = c.GDK_KEY_F5, .mods = 0, .what = "copy to the other pane", .run = &chordCopyPeer },
    .{ .keyval = c.GDK_KEY_F6, .mods = 0, .what = "move to the other pane", .run = &chordMovePeer },
    .{ .keyval = c.GDK_KEY_BackSpace, .mods = 0, .what = "type-ahead backspace", .run = &chordTypeaheadBackspace },
    .{ .keyval = c.GDK_KEY_Escape, .mods = 0, .what = "clear the type-ahead prefix", .run = &chordTypeaheadReset },
    .{ .keyval = c.GDK_KEY_space, .mods = 0, .what = "Quick Look", .run = &chordQuickLook },
    .{ .keyval = c.GDK_KEY_KP_Space, .mods = 0, .what = "Quick Look", .run = &chordQuickLook },
    // Visual mode's own keys: consumed per tab, in capture phase.
    .{ .keyval = c.GDK_KEY_Up, .mods = 0, .what = "visual mode: extend up" },
    .{ .keyval = c.GDK_KEY_Down, .mods = 0, .what = "visual mode: extend down" },
    .{ .keyval = c.GDK_KEY_Home, .mods = 0, .what = "visual mode: extend to the top" },
    .{ .keyval = c.GDK_KEY_End, .mods = 0, .what = "visual mode: extend to the bottom" },
    .{ .keyval = c.GDK_KEY_Return, .mods = 0, .what = "visual mode: commit" },
    .{ .keyval = c.GDK_KEY_KP_Enter, .mods = 0, .what = "visual mode: commit" },
};

fn chordUndo(self: *BrowserView) bool {
    self.performUndo();
    return true;
}

fn chordTransfers(self: *BrowserView) bool {
    @import("jobpanel.zig").toggleTransferCenter(self);
    return true;
}

/// F2: inline-rename the focused row, else a single selected entry.
fn chordRename(self: *BrowserView) bool {
    const tab = self.currentTab() orelse return false;
    var target: ?[]const u8 = null;
    if (colview.focusedItem(tab)) |p| {
        if (p.data.kind == .entry) target = p.data.path;
    }
    if (target == null and tab.selected.items.len == 1)
        target = tab.selected.items[0];
    const path = target orelse return false;
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    self.startInlineRename(tab, buf[0..path.len]);
    return true;
}

/// Ctrl+D, Nemo's add-bookmark chord.
fn chordBookmark(self: *BrowserView) bool {
    @import("places.zig").bookmarkCurrent(self);
    return true;
}

/// Delete: the selection goes to the trash, no confirmation (it is
/// undoable). Nothing selected = the key is not ours.
fn chordTrash(self: *BrowserView) bool {
    const tab = self.currentTab() orelse return false;
    if (tab.selected.items.len == 0) return false;
    @import("ops.zig").trashSelection(self);
    return true;
}

/// Shift+Delete: permanent delete, behind the modal confirmation.
fn chordDelete(self: *BrowserView) bool {
    const tab = self.currentTab() orelse return false;
    if (tab.selected.items.len == 0) return false;
    @import("ops.zig").deleteSelection(self);
    return true;
}

fn chordCut(self: *BrowserView) bool {
    @import("ops.zig").clipSelection(self, true);
    return true;
}

fn chordCopy(self: *BrowserView) bool {
    @import("ops.zig").clipSelection(self, false);
    return true;
}

fn chordPaste(self: *BrowserView) bool {
    @import("ops.zig").pasteIntoCurrent(self);
    return true;
}

fn chordRedo(self: *BrowserView) bool {
    self.performRedo();
    return true;
}

/// Ctrl+L OPENS this pane's location entry and selects it, the way
/// every browser and file manager does -- it does not toggle. Toggling
/// meant the second press in a dual-pane window closed an entry the
/// user was trying to reach, and left the other pane's entry standing
/// open next to it. Escape is the way back to the breadcrumb.
fn chordLocation(self: *BrowserView) bool {
    if (self.peerView()) |peer| _ = peer.foldLocationFace();
    self.showEntryFace();
    return true;
}

fn chordSelectPattern(self: *BrowserView) bool {
    self.showSelectPattern();
    return true;
}

fn chordSelectAll(self: *BrowserView) bool {
    self.selectPattern("*", false);
    return true;
}

fn chordInvertSelection(self: *BrowserView) bool {
    self.selectPattern("*", true);
    return true;
}

fn chordFilter(self: *BrowserView) bool {
    self.toggleFilter();
    return true;
}

fn chordFlat(self: *BrowserView) bool {
    if (self.currentTab()) |tab| self.toggleFlat(tab);
    return true;
}

fn chordBack(self: *BrowserView) bool {
    const tab = self.currentTab() orelse return false;
    self.goBack(tab);
    return true;
}

fn chordForward(self: *BrowserView) bool {
    const tab = self.currentTab() orelse return false;
    self.goForward(tab);
    return true;
}

fn chordUp(self: *BrowserView) bool {
    const tab = self.currentTab() orelse return false;
    self.goUp(tab);
    return true;
}

/// Orthodox dual-pane verbs: the other browser pane in this sketerm
/// tab is the implicit destination. With no peer the key is not ours.
fn chordCopyPeer(self: *BrowserView) bool {
    if (self.peerView() == null) return false;
    self.sendToPeer(false, null);
    return true;
}

fn chordMovePeer(self: *BrowserView) bool {
    if (self.peerView() == null) return false;
    self.sendToPeer(true, null);
    return true;
}

fn chordTypeaheadBackspace(self: *BrowserView) bool {
    return self.typeaheadBackspace();
}

fn chordTypeaheadReset(self: *BrowserView) bool {
    if (self.ta_len == 0) return false;
    self.typeaheadReset();
    return true;
}

/// Space previews the focused entry full-pane (preview.zig owns the
/// overlay and its own Escape/arrow/Enter keys). Mid-word the space
/// belongs to type-ahead instead.
fn chordQuickLook(self: *BrowserView) bool {
    return quickLookKey(self);
}

/// Capture- and bubble-phase entry point for Space. A stale type-ahead
/// prefix must not suppress preview forever after its timeout elapsed.
pub fn quickLookKey(self: *BrowserView) bool {
    if (self.ta_len != 0) {
        if (c.g_get_monotonic_time() - self.ta_last_us <= TYPEAHEAD_RESET_US) return false;
        self.typeaheadReset();
    }
    return self.quickLookToggle();
}

/// The chords a picker (suppress_ops) never runs: everything that
/// mutates files or types into the pane's shell. Compared by run
/// pointer so the table itself stays untouched.
fn chordIsFileOp(run: *const fn (*BrowserView) bool) bool {
    const blocked = [_]*const fn (*BrowserView) bool{
        &chordUndo,     &chordRedo,   &chordCut,      &chordPaste,
        &chordTrash,    &chordDelete, &chordRename,   &chordCopyPeer,
        &chordMovePeer,
    };
    for (blocked) |b| if (run == b) return true;
    return false;
}

pub fn onBrowserKey(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const lower_pre: c_uint = c.gdk_keyval_to_lower(keyval);
    const mods = state & input.SIGNIFICANT_MODS;
    for (browser_chords) |chord| {
        if (chord.keyval != lower_pre or chord.mods != mods) continue;
        const run = chord.run orelse continue;
        if (self.picker) |pk| if (pk.suppress_ops and chordIsFileOp(run)) continue;
        if (run(self)) return 1;
    }
    // Type-ahead: plain printable keys jump to the first matching
    // name. Runs BEFORE the binding table only for keys no binding
    // claims, since this handler is bubble-phase and a focused
    // entry has already consumed its own input.
    if ((mods == 0 or mods == c.GDK_SHIFT_MASK) and self.typeahead(keyval)) return 1;
    const pane = self.pane orelse return 0;
    const ictx = pane.input_ctx orelse return 0;
    const lower_kv: c_uint = lower_pre;
    const bindings: []const input.Binding = if (ictx.bindings.len > 0) ictx.bindings else &input.default_bindings;
    if (input.matchBinding(bindings, lower_kv, state) orelse input.matchBinding(bindings, keyval, state)) |action| {
        return input.runAction(ictx, action);
    }
    return 0;
}

pub fn onBackClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (self.currentTab()) |t| self.goBack(t);
}

pub fn onFwdClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (self.currentTab()) |t| self.goForward(t);
}

pub fn onUpClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (self.currentTab()) |t| self.goUp(t);
}

pub fn onNewTabClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
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

pub fn onTerminalClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const pane = self.pane orelse return;
    pane.setBrowserVisible(false);
}

pub fn onCwdSyncClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const tab = self.currentTab() orelse return;
    const pane = self.pane orelse return;
    const cwd = pane.terminal.cwd orelse {
        self.setStatus("the terminal session has not reported a directory yet");
        return;
    };
    var buf: [4096]u8 = undefined;
    if (cwd.len >= buf.len) return;
    @memcpy(buf[0..cwd.len], cwd);
    const raw: ?[]const u8 = if (pane.terminal.remote) |remote| remote.host else null;
    const host = @import("../../filebrowser/paths.zig").browserHost(raw);
    self.navigate(tab, host, buf[0..cwd.len]);
}

pub fn onHiddenToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (self.currentTab()) |tab| tab.show_hidden = c.gtk_toggle_button_get_active(btn) != 0;
    self.renderCurrent();
}

pub const CompletionCtx = struct {
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
pub fn cancelPathCompletion(self: *BrowserView) void {
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

pub fn closePathCompletion(self: *BrowserView) void {
    if (self.completion_popover) |pop| {
        self.completion_popover = null;
        if (c.gtk_widget_get_parent(pop) != null) c.gtk_widget_unparent(pop);
    }
}

pub fn onPathChanged(_: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (self.syncing_path_entry) return;
    if (self.completion_source != 0) _ = c.g_source_remove(self.completion_source);
    self.completion_source = c.g_timeout_add(150, @ptrCast(&onCompletionTimeout), @ptrCast(self));
}

pub fn onCompletionTimeout(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.completion_source = 0;
    self.renderPathCompletion();
    return 0;
}

pub fn renderPathCompletion(self: *BrowserView) void {
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
    const display_owned = self.allocator.dupe(u8, raw[0 .. slash + 1]) catch {
        self.allocator.destroy(request);
        return;
    };
    const prefix_owned = self.allocator.dupe(u8, prefix) catch {
        self.allocator.free(display_owned);
        self.allocator.destroy(request);
        return;
    };
    request.* = .{
        .req = self.nextReq(),
        .hc = hc,
        .display_prefix = display_owned,
        .typed_prefix = prefix_owned,
    };
    self.completion_request = request;
    self.sendOp(hc, .{ .req = request.req, .op = "list", .path = parent });
}

/// Dispose a widget that was created but never parented. Its initial
/// reference is still FLOATING, and g_object_unref on a floating
/// object warns and leaks -- it has to be sunk first.
fn unrefFloating(widget: ?*c.GtkWidget) void {
    c.g_object_unref(c.g_object_ref_sink(@ptrCast(widget)));
}

pub fn showCompletionNames(self: *BrowserView, display_prefix: []const u8, prefix: []const u8, names: []const []const u8) void {
    self.closePathCompletion();
    // Decide BEFORE building anything: a popover that is never
    // parented still holds its floating reference, and dropping that
    // with a plain g_object_unref is the GLib warning "A floating
    // object was finalized" plus a leaked child.
    var any = false;
    for (names) |name| {
        if (completionMatches(name, prefix)) {
            any = true;
            break;
        }
    }
    if (!any) return;
    const pop = c.gtk_popover_new();
    const list = c.gtk_list_box_new();
    c.gtk_popover_set_autohide(@ptrCast(pop), 0);
    c.gtk_widget_set_can_focus(pop, 0);
    c.gtk_widget_set_can_focus(list, 0);
    c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_BROWSE);
    c.gtk_list_box_set_activate_on_single_click(@ptrCast(list), 1);
    var count: usize = 0;
    for (names) |name| {
        if (!completionMatches(name, prefix)) continue;
        var text_buf: [4600]u8 = undefined;
        const completed = std.fmt.bufPrint(&text_buf, "{s}{s}/", .{ display_prefix, name }) catch continue;
        const ctx = self.allocator.create(CompletionCtx) catch continue;
        ctx.* = .{ .allocator = self.allocator, .view = self, .text = self.allocator.dupe(u8, completed) catch {
            self.allocator.destroy(ctx);
            continue;
        } };
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
    if (count == 0) {
        // Only reachable when every row allocation failed. Sink the
        // floating references before dropping them.
        unrefFloating(list);
        unrefFloating(pop);
        return;
    }
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onCompletionActivated), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(pop), list);
    c.gtk_widget_set_parent(pop, @ptrCast(@alignCast(self.path_entry)));
    self.completion_popover = pop;
    c.gtk_popover_popup(@ptrCast(pop));
}

pub fn onCompletionActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
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

pub fn onPathKey(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (keyval == c.GDK_KEY_Escape) {
        // First Escape dismisses the completion list, the next one
        // abandons the entry face for the breadcrumb.
        if (self.completion_popover != null) {
            self.closePathCompletion();
            return 1;
        }
        if (self.showCrumbFace()) {
            if (self.currentTab()) |tab| self.syncPathEntry(tab);
            return 1;
        }
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

pub const JumpCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    popover: *c.GtkWidget,
    entry: *c.GtkWidget,
    list: *c.GtkWidget,
    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *JumpCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

/// Frecency jump (Ctrl+J): type a substring, land in the directory
/// you visit most, weighted by recency (zoxide model).
pub fn showFrecencyJump(self: *BrowserView) void {
    if (self.frecency.items.len == 0) {
        self.setStatus("no visited folders recorded yet");
        return;
    }
    const pop = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    const entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Jump to folder (frecency)");
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(@alignCast(list)), c.GTK_SELECTION_NONE);
    c.gtk_widget_set_size_request(list, 380, -1);
    c.gtk_box_append(@ptrCast(box), entry);
    c.gtk_box_append(@ptrCast(box), list);
    const ctx = self.allocator.create(JumpCtx) catch {
        unrefFloating(pop);
        unrefFloating(box);
        return;
    };
    ctx.* = .{ .allocator = self.allocator, .view = self, .popover = pop, .entry = entry, .list = list };
    _ = c.g_signal_connect_data(entry, "changed", @ptrCast(&onJumpChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onJumpActivate), @ptrCast(ctx), @ptrCast(&JumpCtx.free), c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onJumpRow), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(pop), box);
    c.gtk_widget_set_parent(pop, @ptrCast(@alignCast(self.path_entry)));
    fillJumpList(ctx, "");
    c.gtk_popover_popup(@ptrCast(pop));
    _ = c.gtk_widget_grab_focus(entry);
}

const JUMP_ROWS = 10;

fn fillJumpList(ctx: *JumpCtx, filter: []const u8) void {
    const lb: *c.GtkListBox = @ptrCast(@alignCast(ctx.list));
    while (c.gtk_list_box_get_row_at_index(lb, 0)) |row|
        c.gtk_list_box_remove(lb, @ptrCast(@alignCast(row)));
    var idx: [JUMP_ROWS]usize = undefined;
    const ranked = places_mod.frecencyRank(ctx.view.frecency.items, filter, nowMsWall(), &idx);
    for (ranked) |i| {
        const spec = ctx.view.frecency.items[i].spec;
        var z: [4300:0]u8 = undefined;
        const n = @min(spec.len, z.len - 1);
        @memcpy(z[0..n], spec[0..n]);
        z[n] = 0;
        const label = c.gtk_label_new(&z);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_START);
        c.gtk_list_box_append(lb, label);
    }
}

fn nowMsWall() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

fn onJumpChanged(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx: *JumpCtx = @ptrCast(@alignCast(user.?));
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
    fillJumpList(ctx, text);
}

fn jumpTo(ctx: *JumpCtx, row_index: c_int) void {
    const lb: *c.GtkListBox = @ptrCast(@alignCast(ctx.list));
    const row = c.gtk_list_box_get_row_at_index(lb, row_index) orelse return;
    const label = c.gtk_list_box_row_get_child(@ptrCast(@alignCast(row))) orelse return;
    const text = c.gtk_label_get_text(@ptrCast(@alignCast(label))) orelse return;
    var spec_buf: [4300]u8 = undefined;
    const spec = std.mem.span(@as([*:0]const u8, @ptrCast(text)));
    const n = @min(spec.len, spec_buf.len);
    @memcpy(spec_buf[0..n], spec[0..n]);
    const self = ctx.view;
    if (c.gtk_widget_get_parent(ctx.popover) != null) c.gtk_widget_unparent(ctx.popover);
    const tab = self.currentTab() orelse return;
    self.navigateSpec(tab, spec_buf[0..n]);
}

fn onJumpActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    jumpTo(@ptrCast(@alignCast(user.?)), 0);
}

fn onJumpRow(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    jumpTo(@ptrCast(@alignCast(user.?)), c.gtk_list_box_row_get_index(row));
}

fn chordJump(self: *BrowserView) bool {
    self.showFrecencyJump();
    return true;
}

pub const PatternCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    popover: *c.GtkWidget,
    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *PatternCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.destroy(ctx);
    }
};

pub fn showSelectPattern(self: *BrowserView) void {
    const pop = c.gtk_popover_new();
    const entry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Select name/glob (* and ?)");
    const ctx = self.allocator.create(PatternCtx) catch {
        // pop is still floating here (set_parent happens below).
        unrefFloating(pop);
        unrefFloating(entry);
        return;
    };
    ctx.* = .{ .allocator = self.allocator, .view = self, .popover = pop };
    _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onPatternActivate), @ptrCast(ctx), @ptrCast(&PatternCtx.free), c.G_CONNECT_DEFAULT);
    c.gtk_popover_set_child(@ptrCast(pop), entry);
    c.gtk_widget_set_parent(pop, @ptrCast(@alignCast(self.path_entry)));
    c.gtk_popover_popup(@ptrCast(pop));
    _ = c.gtk_widget_grab_focus(entry);
}

pub fn onPatternActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PatternCtx = @ptrCast(@alignCast(user.?));
    const pattern = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
    if (pattern.len > 0) ctx.view.selectPattern(pattern, false);
    if (c.gtk_widget_get_parent(ctx.popover) != null) c.gtk_widget_unparent(ctx.popover);
}

pub fn selectPattern(self: *BrowserView, pattern: []const u8, invert: bool) void {
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

pub fn selectPatternDirs(self: *BrowserView, tab: *BTab, dirs: []const *Dir, pattern: []const u8, invert: bool, existing: *std.StringHashMap(void)) void {
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

/// Idle gap after which the next keystroke starts a fresh prefix.
pub const TYPEAHEAD_RESET_US: i64 = 1_200_000;

pub fn typeaheadReset(self: *BrowserView) void {
    self.ta_len = 0;
    self.setStatus("");
}

pub fn typeaheadBackspace(self: *BrowserView) bool {
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
pub fn typeahead(self: *BrowserView, keyval: c_uint) bool {
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

pub fn typeaheadJump(self: *BrowserView) bool {
    const tab = self.currentTab() orelse return false;
    const prefix = self.ta_buf[0..self.ta_len];
    const n = colview.itemCount(tab);
    var idx: c.guint = 0;
    while (idx < n) : (idx += 1) {
        const d = colview.itemDataAt(tab, idx) orelse continue;
        if (d.kind != .entry) continue;
        const name = std.fs.path.basename(d.path);
        if (name.len < prefix.len) continue;
        if (!std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) continue;
        colview.focusRow(tab, idx, true);
        self.setStatusFmt("jump: {s}", .{prefix});
        return true;
    }
    return false;
}

pub fn onPathActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
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
    // The typed location is committed: hand the toolbar back to the
    // breadcrumb face.
    _ = self.showCrumbFace();
}

pub fn onSwitchPage(_: *c.GtkNotebook, _: *c.GtkWidget, _: c.guint, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    // Quick Look owns a path on the old tab's host. Close it rather than
    // silently resolving that path against the newly selected host.
    if (self.preview_state.ql != null) self.quickLookClose();
    // currentTab still reports the OLD page during switch-page;
    // defer to idle so path entry + render see the new one.
    if (self.switch_idle == 0)
        self.switch_idle = c.g_idle_add(@ptrCast(&idleAfterSwitch), @ptrCast(self));
}

pub fn idleAfterSwitch(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.switch_idle = 0;
    if (self.currentTab()) |t| {
        c.gtk_toggle_button_set_active(self.hidden_toggle, @intFromBool(t.show_hidden));
        self.syncPathEntry(t);
        // The overlay is per VIEW, not per tab: the newly selected tab
        // shows another root, so its own status has to be asked for
        // (the recency cache makes a flip back to a just-left tab free).
        self.refreshGitOverlay(t);
        self.renderTab(t);
    }
    self.updatePreview();
    // The sidebar's per-host section follows the CURRENT tab's host.
    if (self.places_on) self.renderPlaces();
    return 0;
}

test "entryForPath resolves flat rows, expanded subdirs and miller ancestors" {
    const t = std.testing;
    const a = t.allocator;
    const types = @import("types.zig");

    var root = Dir{ .allocator = a, .path = @constCast("/data"), .view_id = 1 };
    var sub = Dir{ .allocator = a, .path = @constCast("/data/sub"), .view_id = 2 };
    var anc = Dir{ .allocator = a, .path = @constCast("/"), .view_id = 3 };
    defer {
        for ([_]*Dir{ &root, &sub, &anc }) |d| {
            for (d.entries.items) |*e| e.deinit(a);
            d.entries.deinit(a);
        }
    }
    try root.entries.append(a, try types.testEntry(a, "top.txt", null));
    try sub.entries.append(a, try types.testEntry(a, "deep.txt", null));
    try anc.entries.append(a, try types.testEntry(a, "data", null));

    // Only the fields entryForPath reads are set; the rest is widget
    // state it never touches.
    var tab = BTab{
        .view = undefined,
        .hc = undefined,
        .root = &root,
        .page = undefined,
        .colview = undefined,
        .tab_label = undefined,
    };
    defer {
        tab.subdirs.deinit(a);
        tab.ancestors.deinit(a);
    }
    try tab.subdirs.append(a, &sub);
    try tab.ancestors.append(a, &anc);

    try t.expectEqualStrings("top.txt", (entryForPath(&tab, "/data/top.txt") orelse return error.NotFound).name);
    try t.expectEqualStrings("deep.txt", (entryForPath(&tab, "/data/sub/deep.txt") orelse return error.NotFound).name);
    try t.expectEqualStrings("data", (entryForPath(&tab, "/data") orelse return error.NotFound).name);
    try t.expect(entryForPath(&tab, "/data/nope.txt") == null);

    // A FLAT root (search results, panelize output, registers) keeps
    // each row's real location in `target`. Deriving the parent from
    // the path finds nothing there, which is what silently cost these
    // rows their preview metadata, Properties and dir/file verdict.
    var flat = Dir{ .allocator = a, .path = @constCast("/data"), .view_id = 4 };
    flat.flat = true;
    defer {
        for (flat.entries.items) |*e| e.deinit(a);
        flat.entries.deinit(a);
    }
    try flat.entries.append(a, try types.testEntry(a, "hit.txt", "/elsewhere/hit.txt"));
    tab.root = &flat;
    const hit = entryForPath(&tab, "/elsewhere/hit.txt") orelse return error.NotFound;
    try t.expectEqualStrings("hit.txt", hit.name);
}

test "navigation preserves a live statfs request for one late refresh" {
    const t = std.testing;
    try t.expectEqual(FreeNavigationState{ .req = 41, .dirty = true }, freeNavigationState(41, true));
    try t.expectEqual(FreeNavigationState{ .req = 0, .dirty = false }, freeNavigationState(41, false));
    try t.expectEqual(FreeNavigationState{ .req = 0, .dirty = false }, freeNavigationState(0, true));
}

test "no browser-face chord shadows a global binding undeclared" {
    // onBrowserKey runs in the bubble phase and returns 1 for every
    // chord it claims, so anything in `browser_chords` is INVISIBLE
    // to the global binding table while a browser face has focus.
    // A shadow is therefore only allowed when the entry declares it.
    for (browser_chords) |chord| {
        const hit = input.matchBinding(&input.default_bindings, chord.keyval, chord.mods);
        if (hit) |action| {
            const declared = chord.shadows orelse {
                std.debug.print("browser chord ({s}) silently shadows the global action {s}\n", .{
                    chord.what, input.actionName(action),
                });
                return error.UndeclaredBrowserChordShadow;
            };
            if (declared != action) {
                std.debug.print("browser chord ({s}) declares a shadow of {s} but now shadows {s}\n", .{
                    chord.what, input.actionName(declared), input.actionName(action),
                });
                return error.BrowserChordShadowDrifted;
            }
        } else if (chord.shadows) |stale| {
            // The global moved away: drop the declaration rather than
            // keep a rationale for a shadow that no longer happens.
            std.debug.print("browser chord ({s}) still declares a shadow of {s}, which no longer binds it\n", .{
                chord.what, input.actionName(stale),
            });
            return error.StaleBrowserChordShadow;
        }
    }
}

test "type-ahead cannot swallow an unmodified global binding" {
    // Type-ahead claims every printable key with no modifier (or
    // Shift), which would shadow any global bound the same way.
    for (input.default_bindings) |b| {
        const mods = b.mods & input.SIGNIFICANT_MODS;
        if (mods != 0 and mods != c.GDK_SHIFT_MASK) continue;
        const uni = c.gdk_keyval_to_unicode(b.keyval);
        if (uni >= 0x21 and uni <= 0x7e) {
            std.debug.print("global binding {s} uses a bare printable key type-ahead eats first\n", .{
                input.actionName(b.action),
            });
            return error.TypeaheadShadowsGlobalBinding;
        }
    }
}
