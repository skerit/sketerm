//! The places sidebar: bookmarks, recent locations, saved queries and
//! the daemon-reported devices, persisted through filebrowser/places.
//!
//! A saved query and a saved search are ONE record: the root spec plus
//! the query text as typed. Whether opening it subscribes (a live name
//! query) or scans once (a grep, a panel command) follows from the
//! text, so there is one list and one label rather than two mechanisms
//! for one concept.

const std = @import("std");
const c = @import("../../c.zig").c;
const places_mod = @import("../../filebrowser/places.zig");
const query_mod = @import("../../filebrowser/query.zig");

const BrowserView = @import("view.zig").BrowserView;
const trashFilesDir = @import("../../filebrowser/paths.zig").trashFilesDir;
const classicmenu = @import("classicmenu.zig");
const iconload = @import("iconload.zig");

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
    c.gtk_widget_set_visible(self.places_box, @intFromBool(self.places_on));
    if (self.places_on) {
        // The splitter forgets a position set while its start child
        // was hidden; re-assert the saved width as it comes back.
        c.gtk_paned_set_position(@ptrCast(self.content_paned), self.sidebar_px);
        self.renderPlaces();
    }
    // Only a real toggle is a preference: the one applyChromeState
    // performs at startup IS the stored state.
    if (self.chrome_ready) {
        self.sidebar_open = self.places_on;
        self.savePlaces();
    }
}

/// True when the user folded `name` shut. Unknown sections are open,
/// so a places.json written before this existed reads as all-expanded.
pub fn sectionCollapsed(self: *BrowserView, name: []const u8) bool {
    for (self.collapsed.items) |s| {
        if (std.mem.eql(u8, s, name)) return true;
        // The top section used to be called "Places"; a fold saved
        // under the old name keeps working.
        if (std.mem.eql(u8, name, "Local Places") and std.mem.eql(u8, s, "Places")) return true;
    }
    return false;
}

/// "user@box" / "udp:box" as a section title: the bare host name,
/// first letter upcased ("Archdev Places").
pub fn hostSectionTitle(host: []const u8, buf: []u8) []const u8 {
    var name = host;
    if (std.mem.lastIndexOfScalar(u8, name, '@')) |at| name = name[at + 1 ..];
    if (std.mem.startsWith(u8, name, "udp:")) name = name["udp:".len..];
    if (std.mem.startsWith(u8, name, "ssh:")) name = name["ssh:".len..];
    if (name.len == 0) name = host;
    const text = std.fmt.bufPrint(buf, "{s} Places", .{name}) catch return "Remote Places";
    if (text.len > 0) text[0] = std.ascii.toUpper(text[0]);
    return text;
}

/// Fold a section open or shut and persist it. The caller re-renders:
/// the whole list is rebuilt on every change anyway, so collapsing is
/// "leave the member rows out this time" rather than widget surgery.
fn toggleSection(self: *BrowserView, name: []const u8) void {
    for (self.collapsed.items, 0..) |s, i| {
        if (!std.mem.eql(u8, s, name)) continue;
        self.allocator.free(s);
        _ = self.collapsed.orderedRemove(i);
        return;
    }
    const owned = self.allocator.dupe(u8, name) catch return;
    self.collapsed.append(self.allocator, owned) catch self.allocator.free(owned);
}

/// A section header row. It is activatable -- but as a fold control,
/// not as a place: its ctx spec is "section:<text>", which
/// onPlaceActivated routes to the fold before any navigation.
pub fn placeHeader(self: *BrowserView, text: [*:0]const u8) void {
    const name = std.mem.span(text);
    const folded = sectionCollapsed(self, name);
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    c.gtk_widget_add_css_class(hbox, "sketerm-fb-section");
    c.gtk_widget_set_margin_top(hbox, 8);
    c.gtk_widget_set_margin_start(hbox, 4);
    const arrow = c.gtk_image_new_from_icon_name(if (folded) "pan-end-symbolic" else "pan-down-symbolic");
    c.gtk_box_append(@ptrCast(hbox), arrow);
    const lab = c.gtk_label_new(text);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_widget_add_css_class(lab, "dim-label");
    c.gtk_widget_set_hexpand(lab, 1);
    c.gtk_box_append(@ptrCast(hbox), lab);

    const ctx = self.allocator.create(PlaceCtx) catch return;
    var spec_buf: [128]u8 = undefined;
    const spec = std.fmt.bufPrint(&spec_buf, "section:{s}", .{name}) catch {
        self.allocator.destroy(ctx);
        return;
    };
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .spec = self.allocator.dupe(u8, spec) catch {
            self.allocator.destroy(ctx);
            return;
        },
        .is_bookmark = false,
    };
    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), hbox);
    c.gtk_widget_set_tooltip_text(@ptrCast(row), if (folded) "Show this section" else "Hide this section");
    c.g_object_set_data_full(@ptrCast(row), "sketerm-place", @ptrCast(ctx), @ptrCast(&PlaceCtx.free));
    c.gtk_list_box_append(self.places_list, row);
}

/// A recent-location row. The label is not the raw spec: the folder
/// name reads plainly and the path leading to it is dimmed, so a
/// column of recents scans as names rather than as repeated prefixes.
/// Activation still uses the raw spec.
fn recentRow(self: *BrowserView, spec: []const u8) void {
    const split = places_mod.splitRecentLabel(spec);
    var pz: [1024:0]u8 = undefined;
    var nz: [512:0]u8 = undefined;
    const pn = @min(split.parent.len, pz.len - 1);
    @memcpy(pz[0..pn], split.parent[0..pn]);
    pz[pn] = 0;
    const nn = @min(split.name.len, nz.len - 1);
    @memcpy(nz[0..nn], split.name[0..nn]);
    nz[nn] = 0;
    // Paths may contain &, < and >; Pango would reject the markup.
    const esc_parent = c.g_markup_escape_text(&pz, -1) orelse return;
    defer c.g_free(@ptrCast(esc_parent));
    const esc_name = c.g_markup_escape_text(&nz, -1) orelse return;
    defer c.g_free(@ptrCast(esc_name));
    var markup: [3072:0]u8 = undefined;
    const m = std.fmt.bufPrintZ(&markup, "<span alpha=\"55%\">{s}</span>{s}", .{
        std.mem.span(@as([*:0]const u8, @ptrCast(esc_parent))),
        std.mem.span(@as([*:0]const u8, @ptrCast(esc_name))),
    }) catch return;
    placeRowMarkup(self, "document-open-recent-symbolic", m.ptr, spec);
}

/// A places row whose label is Pango markup. The caller escapes.
fn placeRowMarkup(self: *BrowserView, icon: [*:0]const u8, markup: [*:0]const u8, spec: []const u8) void {
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_margin_start(hbox, 10);
    c.gtk_box_append(@ptrCast(hbox), iconload.newImageIcon(@ptrCast(@alignCast(self.places_list)), icon, 16));
    const lab = c.gtk_label_new(null);
    c.gtk_label_set_markup(@ptrCast(lab), markup);
    c.gtk_label_set_xalign(@ptrCast(lab), 0);
    c.gtk_label_set_ellipsize(@ptrCast(lab), c.PANGO_ELLIPSIZE_START);
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
        .is_bookmark = false,
    };
    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), hbox);
    var tip: [4300:0]u8 = undefined;
    if (std.fmt.bufPrintZ(&tip, "{s}", .{spec})) |t| c.gtk_widget_set_tooltip_text(@ptrCast(row), t.ptr) else |_| {}
    c.g_object_set_data_full(@ptrCast(row), "sketerm-place", @ptrCast(ctx), @ptrCast(&PlaceCtx.free));
    c.gtk_list_box_append(self.places_list, row);
}

pub fn placeRow(self: *BrowserView, icon: [*:0]const u8, label: []const u8, spec: []const u8, is_bookmark: bool) void {
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_margin_start(hbox, 10);
    const img = iconload.newImageIcon(@ptrCast(@alignCast(self.places_list)), icon, 16);
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
    // Always the LOCAL machine, whatever host the current tab shows:
    // specs are "local:"-qualified so a click can never resolve
    // against the remote tab's host.
    self.placeHeader("Local Places");
    if (!sectionCollapsed(self, "Local Places")) {
        const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/";
        var home_spec_buf: [4200]u8 = undefined;
        if (std.fmt.bufPrint(&home_spec_buf, "local:{s}", .{home})) |hs|
            self.placeRow("user-home-symbolic", "Home", hs, false)
        else |_|
            self.placeRow("user-home-symbolic", "Home", home, false);
        self.placeRow("drive-harddisk-symbolic", "File System", "local:/", false);
        var trash_buf: [4200]u8 = undefined;
        if (trashFilesDir(&trash_buf)) |td| self.placeRow("user-trash-symbolic", "Trash", td, false);
    }
    // Browsing another machine adds ITS places right below, under its
    // own name — the two systems are never conflated in one section.
    if (self.currentTab()) |tab| {
        if (tab.hc.host) |host| {
            var title_buf: [160]u8 = undefined;
            var title_z: [160:0]u8 = undefined;
            const title = hostSectionTitle(host, &title_buf);
            const tn = @min(title.len, title_z.len - 1);
            @memcpy(title_z[0..tn], title[0..tn]);
            title_z[tn] = 0;
            self.placeHeader(&title_z);
            if (!sectionCollapsed(self, title_z[0..tn])) {
                var spec_buf: [4600]u8 = undefined;
                if (tab.hc.home_dir) |hd| {
                    if (std.fmt.bufPrint(&spec_buf, "{s}:{s}", .{ host, hd })) |hs|
                        self.placeRow("user-home-symbolic", "Home", hs, false)
                    else |_| {}
                }
                if (std.fmt.bufPrint(&spec_buf, "{s}:/", .{host})) |rs|
                    self.placeRow("drive-harddisk-symbolic", "File System", rs, false)
                else |_| {}
            }
        }
    }
    const store = self.regStore();
    if (store.count() > 0) {
        self.placeHeader("Registers");
        var ri: usize = if (sectionCollapsed(self, "Registers")) store.count() else 0;
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
        if (!sectionCollapsed(self, "Bookmarks")) for (self.bookmarks.items) |b| {
            self.placeRow("starred-symbolic", std.fs.path.basename(b), b, true);
        };
    }
    if (self.saved_searches.items.len > 0) {
        self.placeHeader("Saved Queries");
        if (!sectionCollapsed(self, "Saved Queries")) for (self.saved_searches.items, 0..) |sq, i| {
            // A saved query is durable, not a stored mode: what it is
            // follows from its own text, resolved here so the label
            // and the run can never disagree.
            const q = query_mod.parse(sq.pattern, sq.content);
            // Kind first: the row ellipsizes in the MIDDLE, so what a
            // query is has to sit where the ellipsis cannot eat it.
            var lbl: [300]u8 = undefined;
            const ltxt = std.fmt.bufPrint(&lbl, "[{s}] {s} in {s}", .{
                if (q) |v| v.kindLabel() else "empty",
                sq.pattern,
                sq.spec,
            }) catch sq.pattern;
            // Encode the index as "search:<i>" — rows resolve it
            // at click time so edits do not dangle.
            var spec_buf: [32]u8 = undefined;
            const sspec = std.fmt.bufPrint(&spec_buf, "search:{d}", .{i}) catch continue;
            const icon: [*:0]const u8 = if (q != null and q.?.live())
                "folder-saved-search-symbolic"
            else
                "system-search-symbolic";
            self.placeRow(icon, ltxt, sspec, true);
        };
    }
    if (self.recent.items.len > 0) {
        self.placeHeader("Recent");
        if (!sectionCollapsed(self, "Recent")) for (self.recent.items) |r| {
            recentRow(self, r);
        };
    }
    const devices_folded = sectionCollapsed(self, "Devices");
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
            if (devices_folded) break;
        }
        // /proc/mounts octal-escapes spaces; show raw (rare).
        // "local:"-qualified: /proc/mounts is THIS machine's table,
        // and a bare path would resolve against a remote tab's host.
        var mp_spec_buf: [1200]u8 = undefined;
        const mp_spec = std.fmt.bufPrint(&mp_spec_buf, "local:{s}", .{mp}) catch mp;
        self.placeRow("drive-harddisk-symbolic", mp, mp_spec, false);
        shown += 1;
    }
}

// ── row context menu ─────────────────────────────────────────────

/// Heap ctx for one open places menu; owned by its popover.
const PlacesMenuCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    /// The row's spec, copied: renderPlaces may destroy the row (and
    /// its PlaceCtx) while this menu is still up.
    spec: []u8,
    popover: *c.GtkWidget,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.spec);
        ctx.allocator.destroy(ctx);
    }
};

/// True when `spec` is one of the recent-location rows.
fn isRecentSpec(self: *BrowserView, spec: []const u8) bool {
    for (self.recent.items) |r| {
        if (std.mem.eql(u8, r, spec)) return true;
    }
    return false;
}

pub fn onPlacesRightClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const row = c.gtk_list_box_get_row_at_y(self.places_list, @intFromFloat(y)) orelse return;
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-place") orelse return;
    const pctx: *PlaceCtx = @ptrCast(@alignCast(data));
    if (pctx.spec.len == 0 or std.mem.startsWith(u8, pctx.spec, "section:")) return;

    const ctx = self.allocator.create(PlacesMenuCtx) catch return;
    const spec_owned = self.allocator.dupe(u8, pctx.spec) catch {
        self.allocator.destroy(ctx);
        return;
    };
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .spec = spec_owned,
        .popover = undefined,
    };
    const root = classicmenu.Root.create(self.allocator) orelse {
        self.allocator.free(ctx.spec);
        self.allocator.destroy(ctx);
        return;
    };
    const m = root.top();
    const is_search = std.mem.startsWith(u8, ctx.spec, "search:");
    const is_register = std.mem.startsWith(u8, ctx.spec, "register:");
    if (is_search) {
        m.item("Run Query", &onPlacesMenuOpen, @ptrCast(ctx));
        m.item("Remove Saved Query", &onPlacesMenuRemove, @ptrCast(ctx));
    } else if (is_register) {
        m.item("Open Register", &onPlacesMenuOpen, @ptrCast(ctx));
    } else {
        m.item("Open in New Tab", &onPlacesMenuOpenTab, @ptrCast(ctx));
        m.item("Open Here", &onPlacesMenuOpen, @ptrCast(ctx));
        m.item("Copy Location", &onPlacesMenuCopy, @ptrCast(ctx));
        const extra = m.section();
        if (pctx.is_bookmark)
            extra.item("Remove Bookmark", &onPlacesMenuRemove, @ptrCast(ctx))
        else if (isRecentSpec(self, ctx.spec))
            extra.item("Remove from Recent", &onPlacesMenuRemove, @ptrCast(ctx))
        else
            extra.item("Add Bookmark", &onPlacesMenuBookmark, @ptrCast(ctx));
    }
    const popover = root.popupVia(@ptrCast(@alignCast(self.places_list)), self.root_box, x, y);
    ctx.popover = popover;
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-placesmenu", @ptrCast(ctx), @ptrCast(&PlacesMenuCtx.free));
}

/// Activate the row exactly as a click would (navigate here, run the
/// query, open the register).
fn onPlacesMenuOpen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    var buf: [4600]u8 = undefined;
    if (ctx.spec.len >= buf.len) return;
    @memcpy(buf[0..ctx.spec.len], ctx.spec);
    const spec = buf[0..ctx.spec.len];
    if (std.mem.startsWith(u8, spec, "search:")) {
        const idx = std.fmt.parseInt(usize, spec[7..], 10) catch return;
        self.runSavedSearch(idx);
        return;
    }
    if (std.mem.startsWith(u8, spec, "register:")) {
        _ = self.registerTab(spec["register:".len..]);
        return;
    }
    const tab = self.currentTab() orelse {
        _ = self.newTabSpec(spec);
        return;
    };
    self.navigateSpec(tab, spec);
}

fn onPlacesMenuOpenTab(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    var buf: [4600]u8 = undefined;
    if (ctx.spec.len >= buf.len) return;
    @memcpy(buf[0..ctx.spec.len], ctx.spec);
    _ = self.newTabSpec(buf[0..ctx.spec.len]);
}

fn onPlacesMenuCopy(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    var z: [4600:0]u8 = undefined;
    const n = @min(ctx.spec.len, z.len - 1);
    @memcpy(z[0..n], ctx.spec[0..n]);
    z[n] = 0;
    const clip = c.gtk_widget_get_clipboard(@ptrCast(@alignCast(ctx.view.places_list)));
    c.gdk_clipboard_set_text(clip, &z);
    ctx.view.setStatus("location copied");
}

fn onPlacesMenuBookmark(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
    var buf: [4600]u8 = undefined;
    if (ctx.spec.len >= buf.len) return;
    @memcpy(buf[0..ctx.spec.len], ctx.spec);
    self.addBookmark(buf[0..ctx.spec.len]);
}

/// Remove the row from whichever durable list owns it (bookmark,
/// saved query, recent location).
fn onPlacesMenuRemove(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PlacesMenuCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
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
        i = 0;
        while (i < self.recent.items.len) {
            if (std.mem.eql(u8, self.recent.items[i], ctx.spec)) {
                self.allocator.free(self.recent.items[i]);
                _ = self.recent.orderedRemove(i);
            } else i += 1;
        }
    }
    self.savePlaces();
    self.renderPlaces();
}

pub fn onPlaceActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-place") orelse return;
    const ctx: *PlaceCtx = @ptrCast(@alignCast(data));
    if (ctx.spec.len == 0) return;
    if (std.mem.startsWith(u8, ctx.spec, "section:")) {
        // renderPlaces destroys every row -- and this ctx with it --
        // so the section name is copied out before anything runs.
        var nbuf: [128]u8 = undefined;
        const name = ctx.spec["section:".len..];
        if (name.len > nbuf.len) return;
        @memcpy(nbuf[0..name.len], name);
        toggleSection(self, nbuf[0..name.len]);
        self.savePlaces();
        self.renderPlaces();
        return;
    }
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

/// Open a saved query: navigate its root, refill the search bar, and
/// fire. A name query comes back LIVE -- reopening one is a
/// subscription, not a re-run, which is the whole point of saving it.
pub fn runSavedSearch(self: *BrowserView, idx: usize) void {
    if (idx >= self.saved_searches.items.len) return;
    const sq = self.saved_searches.items[idx];
    const tab = self.currentTab() orelse (self.newTabSpec(sq.spec) orelse return);
    // Both strings live in the saved list, which navigateSpec's own
    // recent-list bookkeeping can reallocate underneath us.
    var buf: [4300]u8 = undefined;
    var pbuf: [512]u8 = undefined;
    if (sq.spec.len >= buf.len or sq.pattern.len >= pbuf.len) return;
    @memcpy(buf[0..sq.spec.len], sq.spec);
    @memcpy(pbuf[0..sq.pattern.len], sq.pattern);
    const spec = buf[0..sq.spec.len];
    const text = pbuf[0..sq.pattern.len];
    const content = sq.content;
    self.navigateSpec(tab, spec);
    var pz: [512:0]u8 = undefined;
    const pat = std.fmt.bufPrintZ(&pz, "{s}", .{text}) catch return;
    c.gtk_editable_set_text(@ptrCast(self.search_entry), pat.ptr);
    c.gtk_check_button_set_active(@ptrCast(self.search_content), @intFromBool(content));
    c.gtk_widget_set_visible(self.search_bar, 1);
    const q = query_mod.parse(text, content) orelse return;
    self.runQuery(tab, text, q);
}

pub fn onSaveSearchClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    const ls = self.last_search orelse {
        self.setStatus("run a query first, then save it");
        return;
    };
    for (self.saved_searches.items) |sq| {
        if (std.mem.eql(u8, sq.spec, ls.spec) and std.mem.eql(u8, sq.pattern, ls.pattern) and sq.content == ls.content) {
            self.setStatus("query already saved");
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
    self.setStatusFmt("saved query: {s}", .{ls.pattern});
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
    const cl = a.alloc([]const u8, self.collapsed.items.len) catch return;
    for (self.collapsed.items, 0..) |s, i| cl[i] = s;
    places_mod.save(self.allocator, .{
        .bookmarks = bm,
        .recent = rc,
        .searches = sq,
        .collection = &.{},
        .collapsed = cl,
        .sidebar_px = self.sidebar_px,
        .sidebar_open = self.sidebar_open,
        .zebra = self.zebra,
        .preview_px = self.preview_px,
        .side_info = self.side_info,
    });
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

test "hostSectionTitle titleizes the bare host name" {
    const t = std.testing;
    var buf: [160]u8 = undefined;
    try t.expectEqualStrings("Archdev Places", hostSectionTitle("archdev", &buf));
    try t.expectEqualStrings("Box Places", hostSectionTitle("skerit@box", &buf));
    try t.expectEqualStrings("Box Places", hostSectionTitle("udp:box", &buf));
    try t.expectEqualStrings("Aeor Places", hostSectionTitle("user@aeor", &buf));
}
