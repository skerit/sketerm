//! The places sidebar: bookmarks, recent locations, saved searches and
//! the daemon-reported devices, persisted through filebrowser/places.

const std = @import("std");
const c = @import("../../c.zig").c;
const places_mod = @import("../../filebrowser/places.zig");

const BrowserView = @import("view.zig").BrowserView;
const trashFilesDir = @import("../../filebrowser/paths.zig").trashFilesDir;

/// Heap ctx on each places row (freed with the row).
pub const PlaceCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    /// Host-qualified location spec; empty = section header.
    spec: []u8,
    is_bookmark: bool,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const p: *PlaceCtx = @ptrCast(@alignCast(user.?));
        p.allocator.free(p.spec);
        p.allocator.destroy(p);
    }
};

pub fn onPlacesToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.places_on = c.gtk_toggle_button_get_active(btn) != 0;
    c.gtk_widget_set_visible(self.places_scroller, @intFromBool(self.places_on));
    if (self.places_on) self.renderPlaces();
}

pub fn placeHeader(self: *BrowserView, text: [*:0]const u8) void {
    const lab = c.gtk_label_new(text);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_widget_add_css_class(lab, "dim-label");
    c.gtk_widget_set_margin_top(lab, 8);
    c.gtk_widget_set_margin_start(lab, 6);
    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
    c.gtk_list_box_row_set_child(@ptrCast(row), lab);
    c.gtk_list_box_append(self.places_list, row);
}

pub fn placeRow(self: *BrowserView, icon: [*:0]const u8, label: []const u8, spec: []const u8, is_bookmark: bool) void {
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_margin_start(hbox, 10);
    const img = c.gtk_image_new_from_icon_name(icon);
    c.gtk_box_append(@ptrCast(hbox), img);
    var lz: [256:0]u8 = undefined;
    const n = @min(label.len, lz.len - 1);
    @memcpy(lz[0..n], label[0..n]);
    lz[n] = 0;
    const lab = c.gtk_label_new(&lz);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_widget_set_hexpand(lab, 1);
    c.gtk_box_append(@ptrCast(hbox), lab);
    const ctx = self.allocator.create(PlaceCtx) catch return;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .spec = self.allocator.dupe(u8, spec) catch {
            self.allocator.destroy(ctx);
            return;
        },
        .is_bookmark = is_bookmark,
    };
    if (is_bookmark) {
        const rm = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_button_set_has_frame(@ptrCast(rm), 0);
        c.gtk_widget_set_tooltip_text(rm, "Remove bookmark");
        _ = c.g_signal_connect_data(rm, "clicked", @ptrCast(&onBookmarkRemove), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(hbox), rm);
    }
    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), hbox);
    c.g_object_set_data_full(@ptrCast(row), "sketerm-place", @ptrCast(ctx), @ptrCast(&PlaceCtx.free));
    c.gtk_list_box_append(self.places_list, row);
}

pub fn renderPlaces(self: *BrowserView) void {
    while (c.gtk_list_box_get_row_at_index(self.places_list, 0)) |row| {
        c.gtk_list_box_remove(self.places_list, @ptrCast(row));
    }
    self.placeHeader("Places");
    const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/";
    self.placeRow("user-home-symbolic", "Home", home, false);
    self.placeRow("drive-harddisk-symbolic", "File System", "local:/", false);
    var trash_buf: [4200]u8 = undefined;
    if (trashFilesDir(&trash_buf)) |td| self.placeRow("user-trash-symbolic", "Trash", td, false);
    const store = self.regStore();
    if (store.count() > 0) {
        self.placeHeader("Registers");
        var ri: usize = 0;
        while (ri < store.count()) : (ri += 1) {
            const name = store.nameAt(ri);
            var lbl: [160]u8 = undefined;
            const ltxt = std.fmt.bufPrint(&lbl, "{s} ({d})", .{ name, store.sizeOf(name) }) catch name;
            var spec_buf: [80]u8 = undefined;
            const rspec = std.fmt.bufPrint(&spec_buf, "register:{s}", .{name}) catch continue;
            self.placeRow("folder-saved-search-symbolic", ltxt, rspec, false);
        }
    }
    if (self.bookmarks.items.len > 0) {
        self.placeHeader("Bookmarks");
        for (self.bookmarks.items) |b| {
            self.placeRow("starred-symbolic", std.fs.path.basename(b), b, true);
        }
    }
    if (self.saved_searches.items.len > 0) {
        self.placeHeader("Saved Searches");
        for (self.saved_searches.items, 0..) |sq, i| {
            var lbl: [300]u8 = undefined;
            const ltxt = std.fmt.bufPrint(&lbl, "{s}{s} in {s}", .{
                sq.pattern,
                if (sq.content) " (content)" else "",
                sq.spec,
            }) catch sq.pattern;
            // Encode the index as "search:<i>" — rows resolve it
            // at click time so edits do not dangle.
            var spec_buf: [32]u8 = undefined;
            const sspec = std.fmt.bufPrint(&spec_buf, "search:{d}", .{i}) catch continue;
            self.placeRow("system-search-symbolic", ltxt, sspec, true);
        }
    }
    if (self.recent.items.len > 0) {
        self.placeHeader("Recent");
        for (self.recent.items) |r| {
            self.placeRow("document-open-recent-symbolic", r, r, false);
        }
    }
    // Devices: real block-device and network mounts.
    const f = c.fopen("/proc/mounts", "rb") orelse {
        return;
    };
    var buf: [32 * 1024]u8 = undefined;
    const nread = c.fread(&buf, 1, buf.len, f);
    _ = c.fclose(f);
    var shown: usize = 0;
    var first_dev = true;
    var it = std.mem.tokenizeScalar(u8, buf[0..nread], '\n');
    while (it.next()) |line| {
        if (shown >= 12) break;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const src = fields.next() orelse continue;
        const mp = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;
        const interesting = std.mem.startsWith(u8, src, "/dev/") or
            std.mem.startsWith(u8, fstype, "nfs") or
            std.mem.eql(u8, fstype, "fuse.sshfs");
        if (!interesting) continue;
        if (first_dev) {
            self.placeHeader("Devices");
            first_dev = false;
        }
        // /proc/mounts octal-escapes spaces; show raw (rare).
        self.placeRow("drive-harddisk-symbolic", mp, mp, false);
        shown += 1;
    }
}

pub fn onPlaceActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-place") orelse return;
    const ctx: *PlaceCtx = @ptrCast(@alignCast(data));
    if (ctx.spec.len == 0) return;
    if (std.mem.startsWith(u8, ctx.spec, "search:")) {
        const idx = std.fmt.parseInt(usize, ctx.spec[7..], 10) catch return;
        self.runSavedSearch(idx);
        return;
    }
    if (std.mem.startsWith(u8, ctx.spec, "register:")) {
        // registerTab re-points the tab, which frees the name it was
        // showing -- and that could be this very slice.
        var nbuf: [80]u8 = undefined;
        const name = ctx.spec["register:".len..];
        if (name.len > nbuf.len) return;
        @memcpy(nbuf[0..name.len], name);
        _ = self.registerTab(nbuf[0..name.len]);
        return;
    }
    const tab = self.currentTab() orelse {
        _ = self.newTabSpec(ctx.spec);
        return;
    };
    var buf: [4300]u8 = undefined;
    if (ctx.spec.len >= buf.len) return;
    @memcpy(buf[0..ctx.spec.len], ctx.spec);
    self.navigateSpec(tab, buf[0..ctx.spec.len]);
}

/// Re-run a saved search: navigate its root, refill the search
/// bar, and fire.
pub fn runSavedSearch(self: *BrowserView, idx: usize) void {
    if (idx >= self.saved_searches.items.len) return;
    const sq = self.saved_searches.items[idx];
    const tab = self.currentTab() orelse (self.newTabSpec(sq.spec) orelse return);
    var buf: [4300]u8 = undefined;
    if (sq.spec.len >= buf.len) return;
    @memcpy(buf[0..sq.spec.len], sq.spec);
    self.navigateSpec(tab, buf[0..sq.spec.len]);
    var pz: [512:0]u8 = undefined;
    const pat = std.fmt.bufPrintZ(&pz, "{s}", .{sq.pattern}) catch return;
    c.gtk_editable_set_text(@ptrCast(self.search_entry), pat.ptr);
    c.gtk_check_button_set_active(@ptrCast(self.search_content), @intFromBool(sq.content));
    c.gtk_widget_set_visible(self.search_bar, 1);
    self.startSearch();
}

pub fn onSaveSearchClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const ls = self.last_search orelse {
        self.setStatus("run a search first, then save it");
        return;
    };
    for (self.saved_searches.items) |sq| {
        if (std.mem.eql(u8, sq.spec, ls.spec) and std.mem.eql(u8, sq.pattern, ls.pattern) and sq.content == ls.content) {
            self.setStatus("search already saved");
            return;
        }
    }
    const spec = self.allocator.dupe(u8, ls.spec) catch return;
    const pat = self.allocator.dupe(u8, ls.pattern) catch {
        self.allocator.free(spec);
        return;
    };
    self.saved_searches.append(self.allocator, .{ .spec = spec, .pattern = pat, .content = ls.content }) catch {
        self.allocator.free(spec);
        self.allocator.free(pat);
        return;
    };
    self.savePlaces();
    if (self.places_on) self.renderPlaces();
    self.setStatusFmt("saved search: {s}", .{ls.pattern});
}

pub fn onBookmarkRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlaceCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    if (std.mem.startsWith(u8, ctx.spec, "search:")) {
        const idx = std.fmt.parseInt(usize, ctx.spec[7..], 10) catch return;
        if (idx < self.saved_searches.items.len) {
            self.saved_searches.items[idx].deinitOwned(self.allocator);
            _ = self.saved_searches.orderedRemove(idx);
        }
    } else {
        var i: usize = 0;
        while (i < self.bookmarks.items.len) {
            if (std.mem.eql(u8, self.bookmarks.items[i], ctx.spec)) {
                self.allocator.free(self.bookmarks.items[i]);
                _ = self.bookmarks.orderedRemove(i);
            } else i += 1;
        }
    }
    self.savePlaces();
    self.renderPlaces();
}

pub fn savePlaces(self: *BrowserView) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bm = a.alloc([]const u8, self.bookmarks.items.len) catch return;
    for (self.bookmarks.items, 0..) |b, i| bm[i] = b;
    const rc = a.alloc([]const u8, self.recent.items.len) catch return;
    for (self.recent.items, 0..) |r, i| rc[i] = r;
    const sq = a.alloc(places_mod.SavedSearch, self.saved_searches.items.len) catch return;
    for (self.saved_searches.items, 0..) |sv, i| {
        sq[i] = .{ .spec = sv.spec, .pattern = sv.pattern, .content = sv.content };
    }
    // `collection` is deliberately written empty: the shelf lives in
    // the register store now, and places.json only still carries the
    // field so a pre-register file can be migrated exactly once.
    places_mod.save(self.allocator, .{ .bookmarks = bm, .recent = rc, .searches = sq, .collection = &.{} });
}

pub fn addBookmark(self: *BrowserView, spec: []const u8) void {
    for (self.bookmarks.items) |b| {
        if (std.mem.eql(u8, b, spec)) return;
    }
    const owned = self.allocator.dupe(u8, spec) catch return;
    self.bookmarks.append(self.allocator, owned) catch {
        self.allocator.free(owned);
        return;
    };
    self.savePlaces();
    if (self.places_on) self.renderPlaces();
    self.setStatusFmt("bookmarked: {s}", .{spec});
}

pub fn recordRecentSpec(self: *BrowserView, spec: []const u8) void {
    places_mod.recordRecent(self.allocator, &self.recent, spec, places_mod.RECENT_CAP);
    self.savePlaces();
    if (self.places_on) self.renderPlaces();
}
