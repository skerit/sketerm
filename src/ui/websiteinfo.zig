//! The web toolbar's site-info popover: what this site is, what it was
//! allowed to do, and what it has stored.
//!
//! Opened from the padlock button left of the address entry, it is the
//! one place a per-site decision can be READ BACK and undone. Until it
//! existed, a permission answered once (or remembered by the daemon
//! store) could never be found again, and cookies could not be seen at
//! all.
//!
//! LIFETIME. The popover is built once per face and owned by it: the
//! face's prepare-destroy choke point calls `sever` (pop down, unparent)
//! and its `deinit` calls `destroy`. Nothing here keeps a pointer to
//! the face — every callback carries the face's VIEW ID and resolves it
//! through `webface.faceByView` at dispatch time, which is the same
//! id-not-pointer fence the popup toast uses. A face that died between
//! a click and its handler therefore resolves to null instead of to
//! freed memory, and the per-row contexts (which own their strings) are
//! freed by their own widget's GDestroyNotify (mechanism 1) when the
//! row list is rebuilt or the popover goes.
//!
//! The cookie/site-data half is capability-gated: a helper that does
//! not advertise `sitedata` gets that whole section hidden, and the
//! permission + blocking half keeps working exactly as before.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const confirm = @import("confirm.zig");
const cssutil = @import("cssutil.zig");
const proto = @import("../web/protocol.zig");
const webstore = @import("webstore.zig");
const webface = @import("webface.zig");
const webroute = @import("../web/route.zig");

/// Widest the popover gets; a cookie name longer than this ellipsizes
/// rather than pushing the toolbar's popover off the screen.
const POPOVER_WIDTH: c_int = 360;
/// Cookie rows past this scroll rather than growing the popover.
const COOKIE_LIST_MAX_H: c_int = 220;

fn installCss(any_widget: *c.GtkWidget) void {
    const css =
        \\.sketerm-siteinfo { padding: 4px; }
        \\.sketerm-siteinfo-origin { font-weight: bold; }
        \\.sketerm-siteinfo-sep { margin-top: 2px; margin-bottom: 2px; }
        \\.sketerm-siteinfo-cookie { font-size: 0.9em; }
    ;
    cssutil.install("websiteinfo", any_widget, css);
}

/// How the connection to the current page reads.
pub const Tls = enum {
    /// Not a network page at all (about:, data:, the blank tab).
    none,
    /// Plain http.
    insecure,
    /// https, no certificate complaint.
    secure,
    /// https, but the user accepted an interstitial for this origin.
    exception,

    fn text(self: Tls) [*:0]const u8 {
        return switch (self) {
            .none => "Connection: local page",
            .insecure => "Connection: not secure (http)",
            .secure => "Connection: secure (https)",
            .exception => "Connection: certificate exception accepted",
        };
    }

    fn icon(self: Tls) [*:0]const u8 {
        return switch (self) {
            .none => "text-x-generic-symbolic",
            .insecure => "channel-insecure-symbolic",
            .secure => "channel-secure-symbolic",
            .exception => "dialog-warning-symbolic",
        };
    }
};

/// What the face hands over on every refresh. Everything borrowed for
/// the call.
pub const State = struct {
    origin: []const u8,
    /// This tab's network route, shown and editable in the popover.
    route: webroute.Spec = .{},
    /// The route can be changed here (false for an inspector view,
    /// which presents somebody else's view and cannot move).
    route_movable: bool = true,
    tls: Tls,
    blocking: bool,
    blocked: u32,
    total: u32,
    /// Permission decisions remembered for this origin.
    perms: []const Perm,
    /// The helper can answer cookie/site-data frames.
    sitedata: bool,

    pub const Perm = struct {
        /// A `webstore.permKey` string ("camera+microphone").
        name: []const u8,
        allow: bool,
    };
};

/// Per-row state: never a pointer to the face or to the popover, only
/// the view id that resolves to one.
const RowCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
    /// Owned: the permission key or the cookie name this row acts on.
    name: []u8,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self: *RowCtx = @ptrCast(@alignCast(user orelse return));
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};

/// A confirmation waiting on the user. Same fence: an id, not a
/// pointer.
const ConfirmCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
    what: enum { cookies, sitedata },
};

pub const SiteInfo = struct {
    allocator: std.mem.Allocator,
    /// The face this belongs to, by id (see the header).
    view: u32,
    popover: *c.GtkWidget,
    /// The toolbar button the popover hangs off; the parent that must
    /// be told to let go before the widget tree dies.
    anchor: *c.GtkWidget,
    parented: bool = false,

    origin_label: *c.GtkWidget,
    /// The route dropdown and its host entry. The entry is sensitive
    /// only for the two host-bound routes; "Apply" moves the tab.
    route_row: *c.GtkWidget,
    route_drop: *c.GtkWidget,
    route_host: *c.GtkWidget,
    /// True while `refresh` sets the dropdown, so our own write does not
    /// fire the change handler and re-narrow the entry.
    route_syncing: bool = false,
    tls_icon: *c.GtkWidget,
    tls_label: *c.GtkWidget,
    block_switch: *c.GtkWidget,
    block_detail: *c.GtkWidget,
    perm_box: *c.GtkWidget,
    perm_empty: *c.GtkWidget,

    /// Everything the `sitedata` capability gates, hidden in one go.
    data_box: *c.GtkWidget,
    cookie_expander: *c.GtkWidget,
    cookie_box: *c.GtkWidget,
    cookie_status: *c.GtkWidget,

    /// True while `onBlockSwitch` is reacting to our own state sync, so
    /// a refresh never posts a toggle nobody asked for.
    syncing: bool = false,
    /// The `cookies_req` whose answer this popover is waiting for; a
    /// late reply for an older request is dropped.
    cookie_req: u32 = 0,

    pub fn create(allocator: std.mem.Allocator, view: u32, anchor: *c.GtkWidget) ?*SiteInfo {
        const self = allocator.create(SiteInfo) catch return null;
        installCss(anchor);

        const pop = c.gtk_popover_new() orelse {
            allocator.destroy(self);
            return null;
        };
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6).?;
        c.gtk_widget_add_css_class(box, "sketerm-siteinfo");
        c.gtk_widget_set_size_request(box, POPOVER_WIDTH, -1);

        const origin_label = c.gtk_label_new("").?;
        c.gtk_label_set_xalign(@ptrCast(origin_label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(origin_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_selectable(@ptrCast(origin_label), 1);
        c.gtk_widget_add_css_class(origin_label, "sketerm-siteinfo-origin");
        c.gtk_box_append(@ptrCast(box), origin_label);

        const tls_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).?;
        const tls_icon = c.gtk_image_new_from_icon_name("channel-insecure-symbolic").?;
        c.gtk_box_append(@ptrCast(tls_row), tls_icon);
        const tls_label = c.gtk_label_new("").?;
        c.gtk_label_set_xalign(@ptrCast(tls_label), 0);
        c.gtk_label_set_wrap(@ptrCast(tls_label), 1);
        c.gtk_widget_set_hexpand(tls_label, 1);
        c.gtk_box_append(@ptrCast(tls_row), tls_label);
        c.gtk_box_append(@ptrCast(box), tls_row);

        appendSeparator(box);

        // Where this tab's traffic leaves. A route is a whole browser
        // instance (`web/route.zig`); picking one here moves the tab.
        const route_title = c.gtk_label_new("Route").?;
        c.gtk_label_set_xalign(@ptrCast(route_title), 0);
        c.gtk_widget_add_css_class(route_title, "heading");
        c.gtk_box_append(@ptrCast(box), route_title);
        const route_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).?;
        const route_drop = c.gtk_drop_down_new_from_strings(@ptrCast(&route_names)).?;
        c.gtk_box_append(@ptrCast(route_row), route_drop);
        const route_host = c.gtk_entry_new().?;
        c.gtk_entry_set_placeholder_text(@ptrCast(route_host), "host");
        c.gtk_widget_set_hexpand(route_host, 1);
        c.gtk_box_append(@ptrCast(route_row), route_host);
        const route_apply = c.gtk_button_new_with_label("Apply").?;
        c.gtk_box_append(@ptrCast(route_row), route_apply);
        c.gtk_box_append(@ptrCast(box), route_row);

        appendSeparator(box);

        // Content blocking, as a switch rather than the toolbar's
        // badge button: here it reads as the site's SETTING, which is
        // what the store persists.
        const block_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
        const block_text = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        c.gtk_widget_set_hexpand(block_text, 1);
        const block_title = c.gtk_label_new("Block content on this site").?;
        c.gtk_label_set_xalign(@ptrCast(block_title), 0);
        c.gtk_box_append(@ptrCast(block_text), block_title);
        const block_detail = c.gtk_label_new("").?;
        c.gtk_label_set_xalign(@ptrCast(block_detail), 0);
        c.gtk_widget_add_css_class(block_detail, "dim-label");
        c.gtk_box_append(@ptrCast(block_text), block_detail);
        c.gtk_box_append(@ptrCast(block_row), block_text);
        const block_switch = c.gtk_switch_new().?;
        c.gtk_widget_set_valign(block_switch, c.GTK_ALIGN_CENTER);
        c.gtk_box_append(@ptrCast(block_row), block_switch);
        c.gtk_box_append(@ptrCast(box), block_row);

        appendSeparator(box);

        const perm_title = c.gtk_label_new("Permissions").?;
        c.gtk_label_set_xalign(@ptrCast(perm_title), 0);
        c.gtk_widget_add_css_class(perm_title, "heading");
        c.gtk_box_append(@ptrCast(box), perm_title);

        const perm_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
        c.gtk_box_append(@ptrCast(box), perm_box);
        const perm_empty = c.gtk_label_new("Nothing decided for this site.").?;
        c.gtk_label_set_xalign(@ptrCast(perm_empty), 0);
        c.gtk_widget_add_css_class(perm_empty, "dim-label");
        c.gtk_box_append(@ptrCast(box), perm_empty);

        // -- cookies + site data (capability "sitedata") -------------
        const data_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6).?;
        appendSeparator(data_box);
        const cookie_expander = c.gtk_expander_new("Cookies").?;
        c.gtk_box_append(@ptrCast(data_box), cookie_expander);
        const scroller = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_policy(
            @ptrCast(scroller),
            c.GTK_POLICY_NEVER,
            c.GTK_POLICY_AUTOMATIC,
        );
        c.gtk_scrolled_window_set_max_content_height(@ptrCast(scroller), COOKIE_LIST_MAX_H);
        c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
        const cookie_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), cookie_box);
        c.gtk_expander_set_child(@ptrCast(cookie_expander), scroller);

        const cookie_status = c.gtk_label_new("").?;
        c.gtk_label_set_xalign(@ptrCast(cookie_status), 0);
        c.gtk_widget_add_css_class(cookie_status, "dim-label");
        c.gtk_box_append(@ptrCast(data_box), cookie_status);

        const btn_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).?;
        c.gtk_widget_set_halign(btn_row, c.GTK_ALIGN_END);
        const clear_cookies = c.gtk_button_new_with_label("Clear cookies").?;
        c.gtk_box_append(@ptrCast(btn_row), clear_cookies);
        const clear_data = c.gtk_button_new_with_label("Clear site data").?;
        c.gtk_widget_add_css_class(clear_data, "destructive-action");
        c.gtk_box_append(@ptrCast(btn_row), clear_data);
        c.gtk_box_append(@ptrCast(data_box), btn_row);
        c.gtk_box_append(@ptrCast(box), data_box);

        c.gtk_popover_set_child(@ptrCast(pop), box);

        self.* = .{
            .allocator = allocator,
            .view = view,
            .popover = pop,
            .anchor = anchor,
            .origin_label = origin_label,
            .route_row = route_row,
            .route_drop = route_drop,
            .route_host = route_host,
            .tls_icon = tls_icon,
            .tls_label = tls_label,
            .block_switch = block_switch,
            .block_detail = block_detail,
            .perm_box = perm_box,
            .perm_empty = perm_empty,
            .data_box = data_box,
            .cookie_expander = cookie_expander,
            .cookie_box = cookie_box,
            .cookie_status = cookie_status,
        };

        // The three fixed controls carry THIS popover's context. It is
        // freed by `destroy` at the face's deinit, strictly after
        // `sever` has unparented (and so destroyed) the popover, so no
        // handler can outlive it. No GDestroyNotify here: combining one
        // with an owner-driven free is the double-free the CLAUDE.md
        // memory section warns about.
        _ = c.g_signal_connect_data(block_switch, "state-set", @ptrCast(&onBlockSwitch), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(clear_cookies, "clicked", @ptrCast(&onClearCookies), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(clear_data, "clicked", @ptrCast(&onClearData), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(route_drop, "notify::selected", @ptrCast(&onRouteChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(route_host, "activate", @ptrCast(&onRouteApply), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(route_apply, "clicked", @ptrCast(&onRouteApply), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        c.gtk_widget_set_parent(pop, anchor);
        self.parented = true;
        return self;
    }

    /// Pop down and let go of the widget tree. Idempotent, and safe on
    /// a tree that GTK has already finalized (`widgets_dead`).
    pub fn sever(self: *SiteInfo, widgets_dead: bool) void {
        if (!self.parented) return;
        self.parented = false;
        if (widgets_dead) return;
        c.gtk_popover_popdown(@ptrCast(self.popover));
        c.gtk_widget_unparent(self.popover);
    }

    pub fn destroy(self: *SiteInfo) void {
        self.allocator.destroy(self);
    }

    pub fn isOpen(self: *SiteInfo) bool {
        if (!self.parented) return false;
        return c.gtk_widget_get_visible(self.popover) != 0;
    }

    /// Redraw everything but the cookie list (which arrives async) and
    /// pop up if `open`.
    pub fn refresh(self: *SiteInfo, st: State, open: bool) void {
        if (!self.parented) return;

        var buf: [1024]u8 = undefined;
        const shown = if (st.origin.len != 0) st.origin else "No site loaded";
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{shown}) catch "";
        c.gtk_label_set_text(@ptrCast(self.origin_label), z.ptr);

        c.gtk_image_set_from_icon_name(@ptrCast(self.tls_icon), st.tls.icon());
        c.gtk_label_set_text(@ptrCast(self.tls_label), st.tls.text());

        self.route_syncing = true;
        const sel: c_uint = switch (st.route.kind) {
            .direct => 0,
            .tor => 1,
            .mux => 2,
            .remote_browser => 3,
        };
        c.gtk_drop_down_set_selected(@ptrCast(self.route_drop), sel);
        var hz: [webroute.MAX_HOST + 1:0]u8 = undefined;
        const hb = std.fmt.bufPrintZ(&hz, "{s}", .{st.route.host[0..@min(st.route.host.len, webroute.MAX_HOST)]}) catch "";
        c.gtk_editable_set_text(@ptrCast(self.route_host), hb.ptr);
        c.gtk_widget_set_sensitive(self.route_host, if (sel == 2 or sel == 3) 1 else 0);
        c.gtk_widget_set_sensitive(self.route_row, if (st.route_movable) 1 else 0);
        self.route_syncing = false;

        self.syncing = true;
        c.gtk_switch_set_active(@ptrCast(self.block_switch), if (st.blocking) 1 else 0);
        c.gtk_switch_set_state(@ptrCast(self.block_switch), if (st.blocking) 1 else 0);
        self.syncing = false;
        const detail = std.fmt.bufPrintZ(&buf, "{d} blocked of {d} requests", .{ st.blocked, st.total }) catch "";
        c.gtk_label_set_text(@ptrCast(self.block_detail), detail.ptr);

        self.fillPerms(st);

        c.gtk_widget_set_visible(self.data_box, if (st.sitedata and st.origin.len != 0) 1 else 0);
        if (st.sitedata and st.origin.len != 0) {
            clearBox(self.cookie_box);
            c.gtk_expander_set_label(@ptrCast(self.cookie_expander), "Cookies");
            c.gtk_label_set_text(@ptrCast(self.cookie_status), "Counting cookies…");
        }

        if (open) c.gtk_popover_popup(@ptrCast(self.popover));
    }

    fn fillPerms(self: *SiteInfo, st: State) void {
        clearBox(self.perm_box);
        c.gtk_widget_set_visible(self.perm_empty, if (st.perms.len == 0) 1 else 0);
        for (st.perms) |p| {
            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8) orelse continue;
            var buf: [256]u8 = undefined;
            const label_text = std.fmt.bufPrintZ(&buf, "{s}", .{p.name}) catch continue;
            const name_label = c.gtk_label_new(label_text.ptr).?;
            c.gtk_label_set_xalign(@ptrCast(name_label), 0);
            c.gtk_label_set_ellipsize(@ptrCast(name_label), c.PANGO_ELLIPSIZE_END);
            c.gtk_widget_set_hexpand(name_label, 1);
            c.gtk_box_append(@ptrCast(row), name_label);

            const state_label = c.gtk_label_new(if (p.allow) "Allowed" else "Blocked").?;
            c.gtk_widget_add_css_class(state_label, "dim-label");
            c.gtk_box_append(@ptrCast(row), state_label);

            const reset = c.gtk_button_new_from_icon_name("edit-undo-symbolic").?;
            c.gtk_widget_set_tooltip_text(reset, "Forget this decision");
            c.gtk_button_set_has_frame(@ptrCast(reset), 0);
            if (self.rowCtx(p.name)) |ctx| {
                _ = c.g_signal_connect_data(reset, "clicked", @ptrCast(&onResetPerm), @ptrCast(ctx), @ptrCast(&RowCtx.free), c.G_CONNECT_DEFAULT);
            } else c.gtk_widget_set_sensitive(reset, 0);
            c.gtk_box_append(@ptrCast(row), reset);
            c.gtk_box_append(@ptrCast(self.perm_box), row);
        }
    }

    fn rowCtx(self: *SiteInfo, name: []const u8) ?*RowCtx {
        const ctx = self.allocator.create(RowCtx) catch return null;
        const owned = self.allocator.dupe(u8, name) catch {
            self.allocator.destroy(ctx);
            return null;
        };
        ctx.* = .{ .allocator = self.allocator, .view = self.view, .name = owned };
        return ctx;
    }

    /// An `ev_cookies` for this view arrived. A reply for a request
    /// this popover is no longer waiting on is dropped: the site may
    /// have changed under it.
    pub fn onCookies(self: *SiteInfo, ev: proto.EvCookies) void {
        if (!self.parented) return;
        if (ev.req != self.cookie_req) return;
        clearBox(self.cookie_box);
        var buf: [256]u8 = undefined;
        if (ev.ok == 0) {
            c.gtk_label_set_text(@ptrCast(self.cookie_status), "Cookies could not be read.");
            c.gtk_expander_set_label(@ptrCast(self.cookie_expander), "Cookies");
            return;
        }
        const title = std.fmt.bufPrintZ(&buf, "Cookies ({d})", .{ev.total}) catch "Cookies";
        c.gtk_expander_set_label(@ptrCast(self.cookie_expander), title.ptr);
        if (ev.total == 0) {
            c.gtk_label_set_text(@ptrCast(self.cookie_status), "This site has stored no cookies.");
            return;
        }
        const shown = if (ev.entries.len < ev.total)
            std.fmt.bufPrintZ(&buf, "Showing {d} of {d} cookies.", .{ ev.entries.len, ev.total }) catch ""
        else
            std.fmt.bufPrintZ(&buf, "{d} cookies stored by this site.", .{ev.total}) catch "";
        c.gtk_label_set_text(@ptrCast(self.cookie_status), shown.ptr);
        for (ev.entries) |e| self.appendCookieRow(e);
    }

    fn appendCookieRow(self: *SiteInfo, e: proto.CookieEntry) void {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6) orelse return;
        const text = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        c.gtk_widget_set_hexpand(text, 1);

        var name_buf: [512]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{e.name}) catch return;
        const name_label = c.gtk_label_new(name_z.ptr).?;
        c.gtk_label_set_xalign(@ptrCast(name_label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(name_label), c.PANGO_ELLIPSIZE_END);
        c.gtk_box_append(@ptrCast(text), name_label);

        var sub_buf: [512]u8 = undefined;
        const sub_z = cookieSubtitle(&sub_buf, e);
        const sub_label = c.gtk_label_new(sub_z.ptr).?;
        c.gtk_label_set_xalign(@ptrCast(sub_label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(sub_label), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_add_css_class(sub_label, "dim-label");
        c.gtk_widget_add_css_class(sub_label, "sketerm-siteinfo-cookie");
        c.gtk_box_append(@ptrCast(text), sub_label);
        c.gtk_box_append(@ptrCast(row), text);

        const del = c.gtk_button_new_from_icon_name("user-trash-symbolic").?;
        c.gtk_widget_set_tooltip_text(del, "Delete this cookie");
        c.gtk_button_set_has_frame(@ptrCast(del), 0);
        c.gtk_widget_set_valign(del, c.GTK_ALIGN_CENTER);
        if (self.rowCtx(e.name)) |ctx| {
            _ = c.g_signal_connect_data(del, "clicked", @ptrCast(&onDeleteCookie), @ptrCast(ctx), @ptrCast(&RowCtx.free), c.G_CONNECT_DEFAULT);
        } else c.gtk_widget_set_sensitive(del, 0);
        c.gtk_box_append(@ptrCast(row), del);
        c.gtk_box_append(@ptrCast(self.cookie_box), row);
    }

    /// The answer to a delete/clear: refresh the list so the popover
    /// shows what is left rather than what was there.
    pub fn onSitedataDone(self: *SiteInfo, ev: proto.EvSitedataDone) void {
        if (!self.parented) return;
        var buf: [256]u8 = undefined;
        if (ev.ok == 0) {
            c.gtk_label_set_text(@ptrCast(self.cookie_status), "That could not be cleared.");
            return;
        }
        const note = if (ev.detail.len != 0)
            std.fmt.bufPrintZ(&buf, "Cleared ({d} cookies). Note: {s}.", .{ ev.removed, ev.detail }) catch ""
        else
            std.fmt.bufPrintZ(&buf, "Cleared {d} cookies.", .{ev.removed}) catch "";
        c.gtk_label_set_text(@ptrCast(self.cookie_status), note.ptr);
        if (webface.faceByView(self.view)) |face| face.requestCookies();
    }

    /// Remember which request the next `ev_cookies` must match.
    pub fn noteCookieRequest(self: *SiteInfo, req: u32) void {
        self.cookie_req = req;
    }
};

/// Route dropdown order == the switch in `refresh` / `onRouteApply`.
const route_names = [_:null]?[*:0]const u8{
    "Direct",
    "Tor",
    "Via server",
    "Browser runs on",
};

// ── row / button handlers ───────────────────────────────────────────

fn onRouteChanged(_: *c.GtkWidget, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(SiteInfo, user);
    if (self.route_syncing) return;
    const sel = c.gtk_drop_down_get_selected(@ptrCast(self.route_drop));
    c.gtk_widget_set_sensitive(self.route_host, if (sel == 2 or sel == 3) 1 else 0);
    // Direct and Tor need no host, so choosing them applies at once;
    // the host-bound ones wait for Apply (or Enter in the entry).
    if (sel == 0 or sel == 1) applyRoute(self);
}

fn onRouteApply(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    applyRoute(cast.userData(SiteInfo, user));
}

fn applyRoute(self: *SiteInfo) void {
    const face = webface.faceByView(self.view) orelse return;
    const sel = c.gtk_drop_down_get_selected(@ptrCast(self.route_drop));
    const host = std.mem.span(c.gtk_editable_get_text(@ptrCast(self.route_host)));
    const spec: webroute.Spec = switch (sel) {
        0 => .{},
        1 => .{ .kind = .tor, .endpoint = webface.torEndpoint() },
        2 => .{ .kind = .mux, .host = host },
        else => .{ .kind = .remote_browser, .host = host },
    };
    face.setRoute(spec) catch |err| {
        const msg: [*:0]const u8 = switch (err) {
            error.InvalidRoute => if (sel == 2 or sel == 3) "That route needs a host." else "That route is not valid.",
            error.AttachedView => "This kind of tab cannot change its route.",
            error.RouteUnavailable => "That route could not be started.",
        };
        c.gtk_label_set_text(@ptrCast(self.cookie_status), msg);
        return;
    };
    c.gtk_popover_popdown(@ptrCast(self.popover));
}

fn onResetPerm(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    const face = webface.faceByView(ctx.view) orelse return;
    face.forgetSitePermission(ctx.name);
}

fn onDeleteCookie(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    const face = webface.faceByView(ctx.view) orelse return;
    face.deleteCookie(ctx.name);
}

fn onBlockSwitch(_: *c.GtkWidget, state: c.gboolean, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(SiteInfo, user);
    if (self.syncing) return 0;
    const face = webface.faceByView(self.view) orelse return 0;
    face.setBlockingForSite(state != 0);
    return 0;
}

fn onClearCookies(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(SiteInfo, user);
    askAndClear(self, .cookies);
}

fn onClearData(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(SiteInfo, user);
    askAndClear(self, .sitedata);
}

fn askAndClear(self: *SiteInfo, what: @FieldType(ConfirmCtx, "what")) void {
    // The popover holds a grab; an alert dialog under it would be
    // dismissed by the same click that opened it.
    c.gtk_popover_popdown(@ptrCast(self.popover));
    const ctx = self.allocator.create(ConfirmCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .view = self.view, .what = what };
    const heading: [*:0]const u8 = switch (what) {
        .cookies => "Clear this site's cookies?",
        .sitedata => "Clear this site's data?",
    };
    const body: [*:0]const u8 = switch (what) {
        .cookies => "Cookies this site stored are deleted. You will be signed out of it.",
        .sitedata => "Cookies, local storage, IndexedDB and cached files for this site are deleted. You will be signed out of it.",
    };
    if (confirm.present(self.anchor, .{
        .heading = heading,
        .body = body,
        .responses = &.{
            .{ .id = "cancel", .label = "Cancel", .is_close = true },
            .{ .id = "clear", .label = "Clear", .appearance = .destructive, .is_default = true },
        },
    }, .{ .allocator = self.allocator, .cb = &onConfirm, .ctx = @ptrCast(ctx) }) == null) {
        self.allocator.destroy(ctx);
    }
}

fn onConfirm(user: ?*anyopaque, response: []const u8) void {
    const ctx: *ConfirmCtx = @ptrCast(@alignCast(user orelse return));
    defer ctx.allocator.destroy(ctx);
    if (!std.mem.eql(u8, response, "clear")) return;
    const face = webface.faceByView(ctx.view) orelse return;
    switch (ctx.what) {
        .cookies => face.clearCookies(),
        .sitedata => face.clearSiteData(),
    }
}

// ── small widget helpers ────────────────────────────────────────────

fn appendSeparator(box: *c.GtkWidget) void {
    const sep = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL) orelse return;
    c.gtk_widget_add_css_class(sep, "sketerm-siteinfo-sep");
    c.gtk_box_append(@ptrCast(box), sep);
}

fn clearBox(box: *c.GtkWidget) void {
    while (c.gtk_widget_get_first_child(box)) |child| c.gtk_box_remove(@ptrCast(box), child);
}

/// "domain path · secure, httponly · session" — everything a cookie
/// row can say WITHOUT the value, which never leaves the helper.
fn cookieSubtitle(buf: []u8, e: proto.CookieEntry) [:0]const u8 {
    var w = std.Io.Writer.fixed(buf[0 .. buf.len - 1]);
    w.print("{s}{s}", .{ e.domain, e.path }) catch {};
    if (e.flags & proto.cookie_secure != 0) w.writeAll(" · secure") catch {};
    if (e.flags & proto.cookie_httponly != 0) w.writeAll(" · httponly") catch {};
    switch (@as(proto.SameSite, @enumFromInt(e.same_site))) {
        .lax => w.writeAll(" · lax") catch {},
        .strict => w.writeAll(" · strict") catch {},
        .none => w.writeAll(" · cross-site") catch {},
        else => {},
    }
    if (e.flags & proto.cookie_session != 0) {
        w.writeAll(" · session") catch {};
    } else {
        const now_ms: u64 = @intCast(@max(@divTrunc(c.g_get_real_time(), 1000), 0));
        if (e.expires_ms > now_ms) {
            const days = (e.expires_ms - now_ms) / (24 * 60 * 60 * 1000);
            w.print(" · expires in {d}d", .{days}) catch {};
        } else w.writeAll(" · expired") catch {};
    }
    w.print(" · {d}B", .{e.value_len}) catch {};
    const n = w.buffered().len;
    buf[n] = 0;
    return buf[0..n :0];
}

// ── tests ───────────────────────────────────────────────────────────

test "cookieSubtitle states scope and flags, never a value" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    const s = cookieSubtitle(&buf, .{
        .name = "sid",
        .domain = ".site.example",
        .path = "/app",
        .flags = proto.cookie_secure | proto.cookie_httponly,
        .same_site = @intFromEnum(proto.SameSite.strict),
        .expires_ms = 0,
        .value_len = 42,
    });
    try t.expect(std.mem.startsWith(u8, s, ".site.example/app"));
    try t.expect(std.mem.indexOf(u8, s, "secure") != null);
    try t.expect(std.mem.indexOf(u8, s, "httponly") != null);
    try t.expect(std.mem.indexOf(u8, s, "strict") != null);
    try t.expect(std.mem.indexOf(u8, s, "42B") != null);
    // Not marked session, and long expired: the row says so rather
    // than printing an absurd countdown.
    try t.expect(std.mem.indexOf(u8, s, "expired") != null);

    const sess = cookieSubtitle(&buf, .{
        .name = "t",
        .domain = "site.example",
        .path = "/",
        .flags = proto.cookie_session,
        .same_site = @intFromEnum(proto.SameSite.unspecified),
        .expires_ms = 0,
        .value_len = 0,
    });
    try t.expect(std.mem.indexOf(u8, sess, "session") != null);
    try t.expect(std.mem.indexOf(u8, sess, "secure") == null);
}

test "cookieSubtitle truncates instead of overrunning its buffer" {
    const t = std.testing;
    var tiny: [24]u8 = undefined;
    const s = cookieSubtitle(&tiny, .{
        .name = "n",
        .domain = "a-very-long-domain-name.example.test",
        .path = "/some/deep/path",
        .flags = proto.cookie_secure,
        .same_site = 0,
        .expires_ms = 0,
        .value_len = 1,
    });
    try t.expect(s.len < tiny.len);
    try t.expectEqual(@as(u8, 0), tiny[s.len]);
}
