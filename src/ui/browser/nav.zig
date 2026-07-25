//! Browser tabs, navigation and the path bar.
//!
//! Tabs are cheap VIEW state; history entries are host-qualified SPEC
//! strings so back/forward can cross hosts. Also holds the path-entry
//! completion popover, select-by-pattern and the type-ahead jump.

const std = @import("std");
const c = @import("../../c.zig").c;
const fsjob = @import("../../mux/fsjob.zig");
const input = @import("../input.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const BypassHit = @import("../../filebrowser/paths.zig").BypassHit;
const Dir = @import("types.zig").Dir;
const Entry = @import("types.zig").Entry;
const HostConn = @import("types.zig").HostConn;
const NavigationIntent = @import("types.zig").NavigationIntent;
const Pending = @import("types.zig").Pending;
const RowCtx = @import("render.zig").RowCtx;
const completionMatches = @import("../../filebrowser/paths.zig").completionMatches;
const hostEq = @import("../../filebrowser/paths.zig").hostEq;
const mountBypass = @import("../../filebrowser/paths.zig").mountBypass;
const onListDrop = @import("ops.zig").onListDrop;
const onRightClick = @import("menu.zig").onRightClick;
const onRowActivated = @import("render.zig").onRowActivated;
const onSelectionChanged = @import("render.zig").onSelectionChanged;
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
    // An ellipsizing label reports the ellipsis itself as its minimum
    // width, so without width_chars the notebook collapses every tab
    // to "...". width_chars is the floor it always gets,
    // max_width_chars the ceiling before it ellipsizes.
    c.gtk_label_set_width_chars(@ptrCast(label), 14);
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

    // Mouse side buttons navigate history anywhere in the listing;
    // middle click opens folders in tabs and closes this one.
    self.installNavGestures(tab, page);
    self.installTabConveniences(tab, label_box);

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

pub fn commitNavigation(self: *BrowserView, tab: *BTab, hc: *HostConn, candidate: *Dir, intent: NavigationIntent, canonical: []const u8) void {
    if (canonical.len > 0 and !std.mem.eql(u8, candidate.path, canonical)) {
        const owned = self.allocator.dupe(u8, canonical) catch null;
        if (owned) |path| { self.allocator.free(candidate.path); candidate.path = path; }
    }
    self.applyHistoryIntent(tab, intent);
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
    var n: usize = 0;
    var rows = c.gtk_list_box_get_selected_rows(tab.listbox);
    const head = rows;
    while (rows != null) : (rows = rows.*.next) n += 1;
    if (head != null) c.g_list_free(head);
    return n;
}

pub fn entryForPath(tab: *BTab, path: []const u8) ?*Entry {
    const parent = std.fs.path.dirname(path) orelse return null;
    const dir = if (std.mem.eql(u8, tab.root.path, parent)) tab.root else tab.subdirByPath(parent) orelse return null;
    const idx = dir.find(std.fs.path.basename(path)) orelse return null;
    return &dir.entries.items[idx];
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
    if (mods == c.GDK_CONTROL_MASK and lower_pre == c.GDK_KEY_z) {
        self.performUndo();
        return 1;
    }
    if (mods == (c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK) and lower_pre == c.GDK_KEY_z) {
        self.performRedo();
        return 1;
    }
    if (mods == c.GDK_CONTROL_MASK and lower_pre == c.GDK_KEY_l) {
        self.toggleLocationFace();
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
    // Quick Look: Space previews the focused entry full-pane
    // (preview.zig owns the overlay and its own Escape/arrow/Enter
    // keys). Mid-word the space belongs to type-ahead instead.
    if (mods == 0 and self.ta_len == 0 and
        (keyval == c.GDK_KEY_space or keyval == c.GDK_KEY_KP_Space) and
        self.quickLookToggle()) return 1;
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
    self.pane.setBrowserVisible(false);
}

pub fn onCwdSyncClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
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
        self.renderTab(t);
    }
    self.updatePreview();
    return 0;
}
