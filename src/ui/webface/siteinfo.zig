//! The site info popover (permissions, cookies, site data) and the route
//! menu, the face half; `websiteinfo.zig` builds the popover itself.
//! Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const classicmenu = @import("../browser/classicmenu.zig");
const proto = @import("../../web/protocol.zig");
const toolbtn = @import("../toolbtn.zig");
const webroute = @import("../../web/route.zig");
const websiteinfo = @import("../websiteinfo.zig");
const webstore = @import("../webstore.zig");
const host_mod = @import("../webface.zig");
const MenuCtx = WebFace.MenuCtx;
const WebFace = host_mod.WebFace;
const freeMenuCtx = WebFace.freeMenuCtx;
const torEndpoint = host_mod.torEndpoint;

// ---- site info popover (permissions, cookies, site data) --------

pub fn onSiteInfo(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(WebFace, user);
    self.showSiteInfo();
}

/// Build the popover if it does not exist yet, refresh it from the
/// live state and pop it up. A face whose widgets are gone does
/// nothing.
pub fn showSiteInfo(self: *WebFace) void {
    if (self.widgets_dead) return;
    if (self.site_info == null)
        self.site_info = websiteinfo.SiteInfo.create(self.allocator, self.view, self.site_btn);
    const info = self.site_info orelse return;
    self.refreshSiteInfo(true);
    // The cookie count is asynchronous: the popover shows
    // "counting" until the helper answers.
    _ = info;
    self.requestCookies();
}

pub fn onRouteButton(btn: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    cast.userData(WebFace, user).showRouteMenu(btn);
}

/// Per-row context of the route menu: the face and the choice the
/// row stands for. Owned by the menu root (`root.own`), freed when
/// the popover dies.
pub const RouteRowCtx = struct {
    allocator: std.mem.Allocator,
    face: *WebFace,
    choice: webroute.Choice,
};

pub fn freeRouteRowCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RouteRowCtx, user);
    ctx.allocator.destroy(ctx);
}

/// The one-click route menu under the toolbar's route button: one
/// checked row per `webroute.Choice` (Direct and Tor apply at
/// once; the host-bound two open the site popover with that route
/// pre-selected, since their one missing piece is a host), then
/// "New Tor Tab" and the full route settings. Same rows, same
/// order, as the site popover's dropdown and the palette.
pub fn showRouteMenu(self: *WebFace, anchor: *c.GtkWidget) void {
    if (self.widgets_dead) return;
    const root = classicmenu.Root.create(self.allocator) orelse return;
    const current = webroute.Choice.fromKind(self.routeSpec().kind);
    const m = root.top();
    self.appendRouteRows(root, m, current);
    const more = m.section();
    const ctx = self.allocator.create(MenuCtx) catch {
        root.destroy();
        return;
    };
    ctx.* = .{ .allocator = self.allocator, .face = self };
    root.own(freeMenuCtx, ctx);
    more.itemIcon("New Tor Web Tab", .{ .name = webroute.Choice.tor.icon() }, &onMenuTorTab, ctx);
    more.itemIcon("Route Settings...", .{ .name = "channel-secure-symbolic" }, &onMenuSiteInfo, ctx);
    _ = root.popup(
        anchor,
        @floatFromInt(@divTrunc(c.gtk_widget_get_width(anchor), 2)),
        @floatFromInt(c.gtk_widget_get_height(anchor)),
    );
}

/// One checked row per `webroute.Choice` into `menu`, the current
/// one ticked; the host-bound choices get an ellipsis because they
/// open the site popover for a host rather than applying at once.
/// Rows are disabled on an attached view, which cannot move.
pub fn appendRouteRows(self: *WebFace, root: *classicmenu.Root, menu: classicmenu.Menu, current: webroute.Choice) void {
    for (webroute.Choice.all) |choice| {
        const rc = self.allocator.create(RouteRowCtx) catch continue;
        rc.* = .{ .allocator = self.allocator, .face = self, .choice = choice };
        root.own(freeRouteRowCtx, rc);
        var lbuf: [64]u8 = undefined;
        const label: [*:0]const u8 = if (choice.needsHost()) blk: {
            const z = std.fmt.bufPrintZ(&lbuf, "{s}...", .{choice.label()}) catch break :blk choice.label();
            break :blk z.ptr;
        } else choice.label();
        menu.checkEnabled(label, choice == current, !self.attached, &onRouteRow, rc);
    }
}

pub fn onRouteRow(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const rc = cast.userData(RouteRowCtx, user);
    rc.face.chooseRoute(rc.choice);
}

pub fn onMenuSiteInfo(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    cast.userData(MenuCtx, user).face.showSiteInfo();
}

pub fn onMenuTorTab(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const win = cast.userData(MenuCtx, user).face.ownerWindow() orelse return;
    win.newTorWebTab() catch {};
}

/// Act on a route choice the user made from a one-click surface
/// (toolbar menu, palette): the host-less choices move the tab at
/// once; the host-bound ones open the site popover on that choice
/// so the host can be typed. Every refusal is said in a toast, so
/// a click can never silently do nothing.
pub fn chooseRoute(self: *WebFace, choice: webroute.Choice) void {
    if (choice.needsHost()) {
        self.showSiteInfo();
        if (self.site_info) |si| si.preset(choice);
        return;
    }
    const spec = choice.spec("", torEndpoint()) orelse {
        self.routeToast("Tor is not configured: mux_tor_socks_endpoint must be a host:port.");
        return;
    };
    self.setRoute(spec) catch |err| {
        self.routeToast(switch (err) {
            error.InvalidRoute => "That route is not valid.",
            error.AttachedView => "This kind of tab cannot change its route.",
            error.RouteUnavailable => "That route could not be started.",
        });
        return;
    };
    var msg: [96]u8 = undefined;
    var dbuf: [webroute.MAX_HOST + 16]u8 = undefined;
    const desc = spec.describe(&dbuf);
    self.routeToast(if (desc.len != 0)
        std.fmt.bufPrint(&msg, "This tab now browses {s}.", .{desc}) catch "Route changed."
    else
        "This tab now browses directly.");
}

pub fn routeToast(self: *WebFace, text: []const u8) void {
    const win = self.ownerWindow() orelse return;
    @import("../window.zig").showToast(win, text);
}

/// Push the current state into an existing popover. `open` also
/// pops it up.
pub fn refreshSiteInfo(self: *WebFace, open: bool) void {
    const info = self.site_info orelse return;
    // Rebuilding the rows costs an allocation per row, so a closed
    // popover is left alone: it is refreshed when it opens.
    if (!open and !info.isOpen()) return;
    // Fixed capacity: the store keys decisions by exact permission
    // set, and a site with more than this many distinct sets is not
    // a site anybody is auditing row by row.
    var keys: [16][80]u8 = undefined;
    var perms: [16]websiteinfo.State.Perm = undefined;
    var n: usize = 0;
    const origin = self.nav_origin orelse "";
    if (origin.len != 0) {
        for (self.site_settings.items) |s| {
            if (n >= perms.len) break;
            if (!std.mem.eql(u8, s.origin, origin)) continue;
            const key = webstore.permKey(&keys[n], s.types) orelse continue;
            perms[n] = .{ .name = key, .allow = s.allow };
            n += 1;
        }
    }
    info.refresh(.{
        .origin = origin,
        .route = self.routeSpec(),
        .route_movable = !self.attached,
        .tls = self.tlsState(),
        .blocking = self.net_enabled,
        .blocked = self.net_blocked,
        .total = self.net_total,
        .perms = perms[0..n],
        .sitedata = self.siteDataUsable(),
    }, open);
}

pub fn tlsState(self: *const WebFace) websiteinfo.Tls {
    const url = self.url orelse return .none;
    if (std.mem.startsWith(u8, url, "https://"))
        return if (self.cert_exception) .exception else .secure;
    if (std.mem.startsWith(u8, url, "http://")) return .insecure;
    return .none;
}

/// The padlock reflects the connection at a glance; the popover
/// spells it out.
pub fn updateSiteButton(self: *WebFace) void {
    if (self.widgets_dead) return;
    const tls = self.tlsState();
    const tls_icon: [*:0]const u8 = switch (tls) {
        .none => "text-x-generic-symbolic",
        .insecure => "channel-insecure-symbolic",
        .secure => "channel-secure-symbolic",
        .exception => "dialog-warning-symbolic",
    };
    // The padlock says how the CONNECTION reads; where the traffic
    // leaves is the route button's job next to it (it used to be
    // shown here too, and the two read as one duplicated fact).
    toolbtn.setIcon(self.site_btn, self.bar, tls_icon, "Site");
    const route = self.routeSpec();
    var dbuf: [webroute.MAX_HOST + 16]u8 = undefined;
    const desc = route.describe(&dbuf);
    // The route button: icon + short word for EVERY route, and a
    // tooltip that spells the route out in full. An attached view
    // (inspector, observed page) cannot move, so its button says
    // so rather than opening a menu that could do nothing. The
    // icons are sketerm's own, so they resolve; the guard keeps a
    // theme that somehow lacks them from drawing a broken glyph
    // beside a word that already carries the meaning.
    const choice = webroute.Choice.fromKind(route.kind);
    const have_icon = toolbtn.iconAvailable(choice.icon());
    c.gtk_widget_set_visible(self.route_icon, if (have_icon) 1 else 0);
    if (have_icon) c.gtk_image_set_from_icon_name(@ptrCast(self.route_icon), choice.icon());
    var sz: [webroute.HOST_LABEL_MAX + 16:0]u8 = undefined;
    var sbuf: [webroute.HOST_LABEL_MAX + 8]u8 = undefined;
    const short = std.fmt.bufPrintZ(&sz, "{s}", .{route.shortLabel(&sbuf)}) catch "Route";
    c.gtk_label_set_text(@ptrCast(self.route_text), short.ptr);
    var rtip: [webroute.MAX_HOST + 128]u8 = undefined;
    const rt = if (self.attached)
        std.fmt.bufPrintZ(&rtip, "Route: this view presents another page's browser and cannot change route.", .{}) catch "Route"
    else if (desc.len != 0)
        std.fmt.bufPrintZ(&rtip, "Route: this tab browses {s}. Click to change it.", .{desc}) catch "Route"
    else
        std.fmt.bufPrintZ(&rtip, "Route: direct, this machine's own network. Click to switch to Tor or a server.", .{}) catch "Route";
    c.gtk_widget_set_tooltip_text(self.route_btn, rt.ptr);
    var tip: [webroute.MAX_HOST + 96]u8 = undefined;
    const t = if (desc.len != 0)
        std.fmt.bufPrintZ(&tip, "Site information, permissions and stored data. This tab browses {s}.", .{desc}) catch "Site information"
    else
        std.fmt.bufPrintZ(&tip, "Site information, permissions and stored data", .{}) catch "Site information";
    c.gtk_widget_set_tooltip_text(self.site_btn, t.ptr);
    self.refreshSiteInfo(false);
}

pub fn nextSiteReq(self: *WebFace) u32 {
    const r = self.site_req_next;
    self.site_req_next +%= 1;
    if (self.site_req_next == 0) self.site_req_next = 1;
    return r;
}

/// Whether the site-data verbs can reach this page's jar: they go to
/// the tab's OWN helper (a routed tab's jar lives in its route's
/// instance), and never for an attached view, whose jar belongs to
/// the page it presents (an observer's cookie frames are refused by
/// the helper and would never be answered).
pub fn siteDataUsable(self: *const WebFace) bool {
    return self.view_live and !self.attached and self.cl.has(.sitedata);
}

/// Ask the helper what this site has stored. Silently does nothing
/// on a helper without the capability — the popover hides the
/// section it would fill.
pub fn requestCookies(self: *WebFace) void {
    const info = self.site_info orelse return;
    if (!self.siteDataUsable()) return;
    const req = self.nextSiteReq();
    info.noteCookieRequest(req);
    self.cl.post(proto.CookiesReq{ .view = self.view, .req = req, .url = "" });
}

pub fn deleteCookie(self: *WebFace, name: []const u8) void {
    if (!self.siteDataUsable()) return;
    self.cl.post(proto.CookieDelete{
        .view = self.view,
        .req = self.nextSiteReq(),
        .url = "",
        .name = name,
    });
}

pub fn clearCookies(self: *WebFace) void {
    if (!self.siteDataUsable()) return;
    self.cl.post(proto.CookiesClear{ .view = self.view, .req = self.nextSiteReq(), .url = "" });
}

/// Everything: cookies, the origin's script-visible storage, and
/// the HTTP cache. The helper reports what it could not do exactly
/// as asked in `EvSitedataDone.detail`.
pub fn clearSiteData(self: *WebFace) void {
    if (!self.siteDataUsable()) return;
    self.cl.post(proto.SitedataClear{
        .view = self.view,
        .req = self.nextSiteReq(),
        .url = "",
        .what = proto.sitedata_cookies | proto.sitedata_storage | proto.sitedata_cache,
    });
}

/// Forget one remembered permission decision, in this process AND
/// in the daemon store, so the next request prompts again.
pub fn forgetSitePermission(self: *WebFace, key: []const u8) void {
    const origin = self.nav_origin orelse return;
    const types = webstore.permTypes(key) orelse return;
    var i: usize = 0;
    while (i < self.site_settings.items.len) {
        const s = self.site_settings.items[i];
        if (s.types == types and std.mem.eql(u8, s.origin, origin)) {
            self.allocator.free(s.origin);
            _ = self.site_settings.orderedRemove(i);
            continue;
        }
        i += 1;
    }
    if (self.storeOrigin()) |o| webstore.siteSetPerm(self.allocator, o, key, "");
    self.refreshSiteInfo(false);
}

/// The origin whose stored site settings this page may WRITE: its
/// current origin, or null for a private page (`isPrivate`), whose
/// overrides apply to it alone and are never persisted.
pub fn storeOrigin(self: *const WebFace) ?[]const u8 {
    if (self.isPrivate()) return null;
    return self.nav_origin;
}

/// The popover's blocking switch: same decision as the toolbar
/// shield, so it stores the same override.
pub fn setBlockingForSite(self: *WebFace, on: bool) void {
    self.setNetwork(on);
    if (self.storeOrigin()) |origin|
        webstore.siteSetBlock(self.allocator, origin, if (on) null else false);
    self.refreshSiteInfo(false);
}

pub fn onCookies(self: *WebFace, ev: proto.EvCookies) void {
    if (self.site_info) |info| info.onCookies(ev);
}

pub fn onSitedataDone(self: *WebFace, ev: proto.EvSitedataDone) void {
    if (self.site_info) |info| info.onSitedataDone(ev);
}
