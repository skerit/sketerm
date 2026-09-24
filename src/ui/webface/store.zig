//! The face's daemon web store traffic: history recording, per-site
//! settings (remembered permissions) and bookmarks. Private faces record
//! nothing (`recordableUrl` / `isPrivate`). Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const proto = @import("../../web/protocol.zig");
const toolbtn = @import("../toolbtn.zig");
const webstore = @import("../webstore.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;

// ---- web store (daemon-side history + per-site settings) --------

/// Bookkeeping on a committed navigation: record the visit in the
/// daemon web store (never for a private page, `isPrivate`) and,
/// when the origin changed, fetch its stored per-site settings.
pub fn noteNavigation(self: *WebFace, url: []const u8) void {
    if (!recordableUrl(url)) {
        // A blank/error page is bookmarkable by nothing; make sure
        // the star does not keep claiming the page before it.
        self.bookmark_id = 0;
        self.updateStar();
        return;
    }
    if (self.visit_url) |u| self.allocator.free(u);
    self.visit_url = null;
    if (!self.isPrivate()) {
        webstore.recordVisit(self.allocator, url, "");
        // The pending history entry `onTitle` completes.
        self.visit_url = self.allocator.dupe(u8, url) catch null;
    }
    // Per-URL, not per-origin: two pages of one site are two
    // different bookmarks.
    self.refreshBookmarkState();

    var obuf: [512]u8 = undefined;
    const origin = webstore.originOf(&obuf, url) orelse return;
    if (self.nav_origin) |o| {
        if (std.mem.eql(u8, o, origin)) return;
        self.allocator.free(o);
    }
    // A certificate the user accepted was accepted for the origin
    // they were looking at, not for the next one.
    self.cert_exception = false;
    // Same reasoning for a per-site popup rule: it was allowed for
    // THAT site. It used to be reset only inside onSiteReply, so
    // one site's "allow popups" survived into the next for the
    // length of a store round trip.
    self.site_popup = .inherit;
    self.pushPopupPolicy();
    self.nav_origin = self.allocator.dupe(u8, origin) catch null;
    // An observed page's site settings are its owner's: the helper
    // refuses every one of them for an observer anyway.
    if (!self.observed) _ = webstore.siteGet(self.allocator, origin, @ptrCast(self), &onSiteReply);
}

/// Only real documents make history; about:/data:/chrome-error
/// noise never does.
pub fn recordableUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "file://");
}

/// Whether `url` is the blank document a view reports before the
/// navigation this face asked for (`pending`) commits.
pub fn isPreNavigationBlank(url: []const u8, pending: ?[]const u8) bool {
    const want = pending orelse return false;
    const blank = url.len == 0 or std.mem.eql(u8, url, "about:blank");
    return blank and !std.mem.eql(u8, want, "about:blank");
}

/// site_get answer: apply everything the origin has stored — zoom,
/// content-blocking, popup policy, permission decisions — WITHOUT
/// writing any of it back (only a user action stores).
pub fn onSiteReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
    const self = cast.userData(WebFace, ctx);
    if (!ok) return;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const rep = webstore.parseSite(arena.allocator(), payload) orelse return;
    if (!rep.ok) return;
    // Stale reply: the face navigated elsewhere meanwhile.
    const cur = self.nav_origin orelse return;
    if (!std.ascii.eqlIgnoreCase(cur, rep.origin)) return;

    const zoom: i32 = if (rep.site) |site| site.zoom_x100 else 0;
    if (zoom != self.zoom_x100) {
        self.zoom_x100 = zoom;
        if (self.view_live)
            self.cl.post(proto.SetZoom{ .view = self.view, .level_x100 = zoom });
    }

    // An origin with no override follows the defaults, which is not
    // the same as "leave the previous origin's answer in place":
    // one view walks many sites.
    self.site_popup = .inherit;
    var want_block = true;
    if (rep.site) |site| {
        if (site.block) |b| want_block = b;
        if (std.mem.eql(u8, site.popup, "allow")) self.site_popup = .allow;
        if (std.mem.eql(u8, site.popup, "block")) self.site_popup = .block;
        for (site.perms) |p| self.preloadPermission(rep.origin, p);
    }
    // netStoreApply is the named hook; it no-ops when the live
    // state already matches.
    self.netStoreApply(want_block);
    // The helper decides popups synchronously, so its copy of the
    // policy has to be current BEFORE the page asks.
    self.pushPopupPolicy();
    // A prompt that arrived before this reply is answered now
    // rather than left on screen asking a question the store has
    // already answered.
    self.answerRememberedPrompts();
}

/// Seed the in-process permission memory from the store. Never
/// reports to `SiteSettingSink`: this decision CAME from the store,
/// and echoing it back would be a write per navigation.
pub fn preloadPermission(self: *WebFace, origin: []const u8, p: webstore.PermEntry) void {
    const types = webstore.permTypes(p.name) orelse return;
    const allow = if (std.mem.eql(u8, p.decision, "allow"))
        true
    else if (std.mem.eql(u8, p.decision, "deny"))
        false
    else
        return;
    for (self.site_settings.items) |*s| {
        if (s.types == types and std.mem.eql(u8, s.origin, origin)) {
            s.allow = allow;
            return;
        }
    }
    const owned = self.allocator.dupe(u8, origin) catch return;
    self.site_settings.append(self.allocator, .{
        .origin = owned,
        .types = types,
        .allow = allow,
    }) catch self.allocator.free(owned);
}

/// Drain any held prompt the (now loaded) memory can answer.
pub fn answerRememberedPrompts(self: *WebFace) void {
    var i: usize = 0;
    while (i < self.perm_queue.items.len) {
        const p = self.perm_queue.items[i];
        const allow = self.rememberedSetting(p.origin, p.types) orelse {
            i += 1;
            continue;
        };
        _ = self.perm_queue.orderedRemove(i);
        self.postPermission(p.prompt, allow);
        self.allocator.free(p.origin);
    }
    self.showPermPrompt();
}

// ---- bookmarks --------------------------------------------------

/// Ask the store whether the current address is bookmarked; the
/// reply moves the star. Cheap enough per navigation: a bookmark
/// list is tens of entries, and it is the only way one window sees
/// what another one starred.
pub fn refreshBookmarkState(self: *WebFace) void {
    if (!webstore.bookmarkList(self.allocator, @ptrCast(self), &onBookmarkList)) {
        self.bookmark_id = 0;
        self.updateStar();
    }
}

pub fn onBookmarkList(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
    const self = cast.userData(WebFace, ctx);
    self.bookmark_id = 0;
    if (ok) {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const url = self.url orelse self.visit_url orelse "";
        if (url.len > 0) {
            for (webstore.parseBookmarks(arena.allocator(), payload)) |b| {
                if (std.mem.eql(u8, b.url, url)) {
                    self.bookmark_id = b.id;
                    break;
                }
            }
        }
    }
    self.updateStar();
}

pub fn updateStar(self: *WebFace) void {
    if (self.widgets_dead) return;
    const on = self.bookmark_id != 0;
    const icon: [*:0]const u8 = if (on) "sketerm-starred-symbolic" else "sketerm-non-starred-symbolic";
    const tip: [*:0]const u8 = if (on) "Remove this page from bookmarks" else "Bookmark this page";
    if (self.star_btn) |btn| {
        toolbtn.setIcon(btn, self.bar, icon, if (on) "Bookmarked" else "Bookmark");
        c.gtk_widget_set_tooltip_text(btn, tip);
        return;
    }
    c.gtk_entry_set_icon_from_icon_name(@ptrCast(self.entry), c.GTK_ENTRY_ICON_SECONDARY, icon);
    c.gtk_entry_set_icon_tooltip_text(@ptrCast(self.entry), c.GTK_ENTRY_ICON_SECONDARY, tip);
}

pub fn onEntryIconPress(_: *c.GtkEntry, pos: c.GtkEntryIconPosition, user: ?*anyopaque) callconv(.c) void {
    if (pos != c.GTK_ENTRY_ICON_SECONDARY) return;
    cast.userData(WebFace, user).toggleBookmark();
}

pub fn onStar(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    cast.userData(WebFace, user).toggleBookmark();
}

/// Star: add the current page, or remove the bookmark it already
/// has. The reply-driven refresh is what learns the new id, so the
/// star is only ever as wrong as one round trip.
pub fn toggleBookmark(self: *WebFace) void {
    if (self.bookmark_id != 0) {
        webstore.bookmarkRemove(self.allocator, self.bookmark_id);
        self.bookmark_id = 0;
        self.updateStar();
        self.toast("Bookmark removed");
        return;
    }
    const url = self.url orelse self.visit_url orelse return;
    if (!recordableUrl(url)) return;
    webstore.bookmarkAdd(self.allocator, url, self.title orelse "", "");
    self.toast("Bookmarked");
    // Ordered behind the add on the same connection, so it comes
    // back with the id the add just minted.
    self.refreshBookmarkState();
}
