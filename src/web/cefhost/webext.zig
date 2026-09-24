//! WebExtensions (0xB0 block, capability "webext"), split out of
//! `cefhost.zig`: extension load/install/remove, background pages and
//! popups, content-script injection, the browser.* API bridge, runtime
//! Ports, and the chrome-extension:// scheme handler (IO thread). The
//! `Host` methods are free functions taking `*Host`, re-exported from
//! `Host` under their old names.

const std = @import("std");
const bgpage = @import("../webext/bgpage.zig");
const c = @import("cbindings");
const cef = @import("cef");
const extassets = @import("../webext/assets.zig");
const extinstall = @import("../webext/install.zig");
const extmanifest = @import("../webext/manifest.zig");
const extmatch = @import("../webext/match.zig");
const extorigins = @import("../webext/origins.zig");
const exttabs = @import("../webext/tabs.zig");
const nowMs = @import("../../util/clock.zig").nowMs;
const proto = @import("../protocol.zig");
const semantic = @import("../semantic.zig");
const webexthost = @import("../webext/host.zig");
const webrequest = @import("../webext/webrequest.zig");
const host_mod = @import("../cefhost.zig");
const HeapRef = host_mod.HeapRef;
const Host = host_mod.Host;
const PendingReply = Host.PendingReply;
const Port = Host.Port;
const View = host_mod.View;
const applyA11yState = host_mod.applyA11yState;
const browserInt = host_mod.browserInt;
const frameIdOf = host_mod.frameIdOf;
const innerJson = host_mod.innerJson;
const isMainFrame = host_mod.isMainFrame;
const jsonBool = host_mod.jsonBool;
const jsonStr = host_mod.jsonStr;
const jsonStrField = host_mod.jsonStrField;
const jsonU32 = host_mod.jsonU32;
const manifestContentScript = host_mod.manifestContentScript;
const manifestRunAt = host_mod.manifestRunAt;
const parentFrameIdOf = host_mod.parentFrameIdOf;
const physicalOf = host_mod.physicalOf;
const release = host_mod.release;
const releaseArg = host_mod.releaseArg;
const route_reply_timeout_ms = host_mod.route_reply_timeout_ms;
const runJs = host_mod.runJs;
const setStr = host_mod.setStr;
const userfreeInto = host_mod.userfreeInto;
const webext_max_asset = host_mod.webext_max_asset;
const windowlessInfo = host_mod.windowlessInfo;
const windowlessSettings = host_mod.windowlessSettings;
const withHost = host_mod.withHost;
const wreqAbandonExt = host_mod.wreqAbandonExt;
const wreqAbandonView = host_mod.wreqAbandonView;

// -- WebExtensions -------------------------------------------------

/// Load-or-toggle an extension (`webext_set`) and report its state.
pub fn webextSet(self: *Host, req: proto.WebextSet) void {
    if (!extmanifest.idValid(req.id)) {
        self.post(proto.EvWebextState{
            .id = "",
            .name = "",
            .version = "",
            .enabled = 0,
            .ok = 0,
            .err = "invalid extension id",
        });
        return;
    }
    // A `webext_set` for a LIVE extension is a reinstall: the running
    // instance is quiesced, its capability rotated (smoke-web stage
    // 40 pins that). A client that only wants to learn state sends
    // `webext_list_req`; a GUI joining another window's helper does
    // exactly that (`webext.publish`), never a re-post.
    var prepared = self.webext.prepareSet(req.id, req.dir, req.enabled != 0) catch {
        if (self.webext.find(req.id)) |old| {
            self.postWebextState(old);
            return;
        }
        self.post(proto.EvWebextState{
            .id = req.id,
            .name = "",
            .version = "",
            .enabled = 0,
            .ok = 0,
            .err = "out of memory",
        });
        return;
    };
    defer prepared.deinit();
    self.quiesceWebext(req.id, "extension was reinstalled or toggled");
    const e = self.webext.commitSet(&prepared);
    if (e.enabled and e.ok) {
        self.publishOrigin(e);
        self.ensureBackground(e);
        self.injectContentScriptsAll(e);
    } else {
        wreqAbandonExt(req.id);
        self.repliesAbandonExt(req.id);
        self.portsAbandonExt(req.id);
        self.webext.clearListeners(e);
        self.teardownBackground(e);
        self.unpublishOrigin(e.id);
        self.teardownPopups(e.id);
    }
    self.postWebextState(e);
    self.postActionsForActiveViews();
}

/// Validate a staged tree before quiescing the currently running instance.
pub fn webextInstallPrepare(self: *Host, req: proto.WebextInstallPrepare) void {
    if (!extmanifest.idValid(req.id)) {
        self.post(proto.EvWebextInstallPrepared{ .req = req.req, .id = req.id, .ok = 0, .err = "invalid extension id" });
        return;
    }
    var candidate = extinstall.validateDirectory(self.gpa, req.dir, req.id, req.version, null) catch |err| {
        self.post(proto.EvWebextInstallPrepared{ .req = req.req, .id = req.id, .ok = 0, .err = @errorName(err) });
        return;
    };
    candidate.deinit();
    self.quiesceWebext(req.id, "extension upgrade is committing");
    self.postActionsForActiveViews();
    self.post(proto.EvWebextInstallPrepared{ .req = req.req, .id = req.id, .ok = 1, .err = "" });
}

/// Load a package after the GUI's atomic swap and correlate the result.
pub fn webextInstallCommit(self: *Host, req: proto.WebextInstallCommit) void {
    self.webextSet(.{ .id = req.id, .dir = req.dir, .enabled = req.enabled });
    const installed = self.webext.find(req.id);
    const ok = if (installed) |e|
        e.ok and e.enabled == (req.enabled != 0) and
            std.mem.eql(u8, if (e.man) |*m| m.version else "", req.version)
    else
        false;
    var detail: []const u8 = "extension load failed";
    if (installed) |e| {
        if (!ok) {
            if (e.err.len != 0) detail = e.err else if (!std.mem.eql(u8, if (e.man) |*m| m.version else "", req.version)) detail = "extension version mismatch";
            self.quiesceWebext(req.id, "extension upgrade was refused");
        }
    }
    self.post(proto.EvWebextInstallCommitted{
        .req = req.req,
        .id = req.id,
        .ok = @intFromBool(ok),
        .err = if (ok) "" else detail,
    });
}

pub fn quiesceWebext(self: *Host, id: []const u8, reason: []const u8) void {
    const old = self.webext.find(id) orelse return;
    self.revokeExtension(old, reason);
    wreqAbandonExt(id);
    self.repliesAbandonExt(id);
    self.portsAbandonExt(id);
    self.webext.clearListeners(old);
    self.teardownBackground(old);
    self.teardownPopups(id);
    self.unpublishOrigin(id);
    old.enabled = false;
    old.capability = @splat(0);
    old.capability_ok = false;
}

/// Make `chrome-extension://<host>/` resolve to this extension's
/// unpacked directory. The locale is negotiated HERE, on the main
/// thread, because the IO thread that serves the origin must not
/// scan a directory to work one out per request.
pub fn publishOrigin(self: *Host, e: *webexthost.Extension) void {
    var host_buf: [16]u8 = undefined;
    const host = extmanifest.originHost(e.id, &host_buf);
    var loc_buf: [extorigins.MAX_LOCALE]u8 = undefined;
    const locale = self.webext.resolveLocale(e, &loc_buf) orelse "";
    const war: []const []const u8 = if (e.man) |*m| m.web_accessible_resources else &.{};
    if (!e.capability_ok) return;
    _ = extorigins.publish(host, e.id, e.dir, war, locale, &e.capability);
}

pub fn unpublishOrigin(self: *Host, id: []const u8) void {
    _ = self;
    var host_buf: [16]u8 = undefined;
    extorigins.unpublish(extmanifest.originHost(id, &host_buf));
}

pub fn revokeExtension(self: *Host, e: *const webexthost.Extension, reason: []const u8) void {
    if (!e.capability_ok) return;
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.writeAll("{\"op\":\"ext-revoke\",\"tok\":\"") catch return;
    w.writeAll(&host_mod.sem_secret.nonce) catch return;
    w.writeAll("\",\"ext\":") catch return;
    jsonStr(w, e.id) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.writeAll(",\"reason\":") catch return;
    jsonStr(w, reason) catch return;
    w.writeByte('}') catch return;
    for (self.views.items) |v| {
        if (v.browser == null or v.discarded) continue;
        self.sendScriptAllFrames(v, cmd.written());
    }
}

pub fn webextRemove(self: *Host, id: []const u8) void {
    if (!extmanifest.idValid(id)) return;
    // An enumerated exit: every request this extension was holding
    // is continued before its registry goes away.
    wreqAbandonExt(id);
    self.repliesAbandonExt(id);
    self.portsAbandonExt(id);
    if (self.webext.find(id)) |e| {
        self.revokeExtension(e, "extension was removed");
        self.webext.clearListeners(e);
        self.teardownBackground(e);
    }
    self.teardownPopups(id);
    self.unpublishOrigin(id);
    self.webext.remove(id);
    self.postActionsForActiveViews();
    // A removal has no dedicated frame; the client already dropped
    // the row. Nothing more to report.
}

pub fn teardownPopups(self: *Host, id: []const u8) void {
    while (true) {
        var found: u32 = 0;
        for (self.views.items) |v| {
            if (!v.webext_popup) continue;
            if (std.mem.eql(u8, v.popup_ext[0..v.popup_ext_len], id)) {
                found = v.id;
                break;
            }
        }
        if (found == 0) return;
        self.destroyView(found);
    }
}

pub fn webextList(self: *Host) void {
    for (self.webext.exts.items) |*e| self.postWebextState(e);
}

/// `webext_tabs`: replace the mirrored tab list and turn the DIFF
/// into MV2 `tabs.on*` events for every enabled extension.
///
/// Deriving the events from a replace-all diff rather than trusting
/// the client to send them is what makes a dropped or coalesced
/// update harmless: the table is the truth and the events are a
/// function of two consecutive tables.
pub fn webextTabs(self: *Host, tabs_json: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, tabs_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .array) return;

    var incoming: std.ArrayList(exttabs.Incoming) = .empty;
    defer incoming.deinit(self.gpa);
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        incoming.append(self.gpa, .{
            // A tab id is the GUI's view id, so two GUIs on one
            // helper mint the same numbers: window it exactly as
            // the view id is, so `tabId` stays unique per browser.
            .id = self.mapDispatchView(jsonU32(o, "id")),
            // The tabs JSON names views in the SENDER's namespace;
            // the edge cannot see into it, so translate at parse.
            .view = self.mapDispatchView(jsonU32(o, "view")),
            .window_id = jsonU32(o, "windowId"),
            .index = jsonU32(o, "index"),
            .active = jsonBool(o, "active"),
            .focused_window = jsonBool(o, "focusedWindow"),
            .url = jsonStrField(o, "url"),
            .title = jsonStrField(o, "title"),
            .loading = jsonBool(o, "loading"),
        }) catch return;
    }

    // Scoped to the SENDER's tabs: with two GUIs on one helper, one
    // window's replace-all used to read the other window's tabs as
    // removed and the next post re-created them, so extensions saw
    // every tab churn on every change.
    var diff = self.webext.tabs.replaceOwner(self.gpa, self.dispatch_conn, incoming.items) catch return;
    defer diff.deinit(self.gpa);

    for (diff.created) |id| {
        if (self.webext.tabs.find(id)) |tb| self.postTabEvent("onCreated", tb, null);
    }
    for (diff.updated) |ch| {
        const tb = self.webext.tabs.find(ch.id) orelse continue;
        self.postTabEvent("onUpdated", tb, ch);
    }
    if (diff.activated) |id| {
        if (self.webext.tabs.find(id)) |tb| self.postTabEvent("onActivated", tb, null);
    }
    for (diff.removed) |id| {
        self.postTabRemoved(id);
        for (self.webext.exts.items) |*e| e.action.removeTab(self.gpa, id);
    }
    self.postActionsForActiveViews();
}

/// Replace-all toolbar action state for every active page view.
pub fn postActionsForActiveViews(self: *Host) void {
    for (self.webext.tabs.tabs.items) |*tb| {
        if (tb.view == 0 or self.find(tb.view) == null) continue;
        if (tb.active) {
            const json = self.actionSnapshot(tb.id) orelse continue;
            defer self.gpa.free(json);
            self.post(proto.EvWebextActions{ .view = tb.view, .actions_json = json });
        } else {
            // Replace-all means inactive views must receive the empty
            // replacement too. Otherwise a split pane that loses focus
            // keeps a stale, clickable toolbar action forever.
            self.post(proto.EvWebextActions{ .view = tb.view, .actions_json = "[]" });
        }
    }
}

pub fn actionSnapshot(self: *Host, tab: u32) ?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(self.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch return null;
    var first = true;
    for (self.webext.exts.items) |*e| {
        if (!e.enabled or !e.ok or !e.action.present) continue;
        const a = e.action.effective(tab);
        if (!a.visible) continue;
        if (!first) w.writeByte(',') catch return null;
        first = false;
        w.writeAll("{\"id\":") catch return null;
        jsonStr(w, e.id) catch return null;
        w.writeAll(",\"title\":") catch return null;
        jsonStr(w, if (a.title.len != 0) a.title else if (e.man) |*m| m.name else e.id) catch return null;
        w.writeAll(",\"icon\":") catch return null;
        jsonStr(w, a.icon) catch return null;
        w.writeAll(",\"badge\":") catch return null;
        jsonStr(w, a.badge) catch return null;
        w.print(",\"badgeTextColor\":[{d},{d},{d},{d}],\"badgeBackgroundColor\":[{d},{d},{d},{d}],\"enabled\":{s},\"popup\":{s}}}", .{
            a.badge_text_color.r,               a.badge_text_color.g,                      a.badge_text_color.b,       a.badge_text_color.a,
            a.badge_background_color.r,         a.badge_background_color.g,                a.badge_background_color.b, a.badge_background_color.a,
            if (a.enabled) "true" else "false", if (a.popup.len != 0) "true" else "false",
        }) catch return null;
    }
    w.writeByte(']') catch return null;
    return aw.toOwnedSlice() catch null;
}

/// A trusted browser-toolbar activation. The active mirrored tab is
/// the authority: a stale/background GUI face cannot activate one.
pub fn webextActionActivate(self: *Host, req: proto.WebextActionActivate) void {
    if (!extmanifest.idValid(req.id)) {
        self.popupError(req, "invalid extension id");
        return;
    }
    const tb = self.webext.tabs.findByView(req.view) orelse {
        self.popupError(req, "action is not available for this tab");
        return;
    };
    if (!tb.active) {
        self.popupError(req, "action is not available for this tab");
        return;
    }
    const owner = self.find(req.view) orelse {
        self.popupError(req, "action owner is gone");
        return;
    };
    const e = self.webext.find(req.id) orelse {
        self.popupError(req, "extension is not available");
        return;
    };
    if (!e.enabled or !e.ok or !e.action.present) {
        self.popupError(req, "extension action is not available");
        return;
    }
    const a = e.action.effective(tb.id);
    if (!a.visible or !a.enabled) {
        self.popupError(req, "extension action is disabled");
        return;
    }
    if (a.popup.len == 0) {
        const bg = if (e.bg_view != 0) self.find(e.bg_view) else null;
        if (bg) |v| {
            var cmd: std.Io.Writer.Allocating = .init(self.gpa);
            defer cmd.deinit();
            cmd.writer.writeAll("{\"op\":\"ext-action-clicked\",\"ext\":") catch return;
            jsonStr(&cmd.writer, e.id) catch return;
            cmd.writer.writeAll(",\"cap\":") catch return;
            jsonStr(&cmd.writer, &e.capability) catch return;
            cmd.writer.writeAll(",\"tab\":") catch return;
            exttabs.Table.writeTab(tb, &cmd.writer) catch return;
            cmd.writer.writeByte('}') catch return;
            self.sendScript(v, cmd.written());
        }
        self.popupError(req, "extension action has no popup");
        return;
    }
    if (req.popup_view < proto.WEBEXT_POPUP_VIEW_BASE or self.find(req.popup_view) != null) {
        self.popupError(req, "invalid popup view id");
        return;
    }
    while (self.popupForOwner(req.view)) |old| self.destroyView(old.id);
    const clean = std.mem.trimStart(u8, a.popup, "/");
    const asset_end = std.mem.indexOfAny(u8, clean, "?#") orelse clean.len;
    const asset = clean[0..asset_end];
    if (asset.len == 0 or std.mem.indexOf(u8, asset, "..") != null) {
        self.popupError(req, "invalid popup path");
        return;
    }
    const popup_asset = self.webext.readAsset(e, asset) orelse {
        self.popupError(req, "popup asset not found");
        return;
    };
    self.gpa.free(popup_asset);
    var host_buf: [16]u8 = undefined;
    var url_buf: [2048]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, ext_scheme ++ "://{s}/{s}", .{
        extmanifest.originHost(e.id, &host_buf), clean,
    }) catch {
        self.popupError(req, "popup URL is too long");
        return;
    };
    const v = self.gpa.create(View) catch {
        self.popupError(req, "out of memory");
        return;
    };
    const scale: u16 = if (req.scale_x1000 == 0) 1000 else req.scale_x1000;
    v.* = .{
        .id = req.popup_view,
        // Hand-built (not registerView), so the multi-client owner
        // stamp must be applied here too or the popup's frames are
        // routed to nobody.
        .owner = self.dispatch_conn,
        .inline_view = self.dispatch_inline,
        .w = @max(req.w, 1),
        .h = @max(req.h, 1),
        .scale_x1000 = scale,
        .pw = physicalOf(@max(req.w, 1), scale),
        .ph = physicalOf(@max(req.h, 1), scale),
        .context = owner.context,
        .webext_popup = true,
        .webext_origin = true,
        .popup_owner = req.view,
        .sem = semantic.View.init(self.gpa),
    };
    if (e.id.len > v.popup_ext.len) {
        v.sem.deinit();
        self.gpa.destroy(v);
        self.popupError(req, "invalid extension id");
        return;
    }
    @memcpy(v.popup_ext[0..e.id.len], e.id);
    v.popup_ext_len = e.id.len;
    self.views.append(self.gpa, v) catch {
        v.sem.deinit();
        self.gpa.destroy(v);
        self.popupError(req, "out of memory");
        return;
    };
    self.spawnPopup(v, url) catch |err| {
        self.removePopupView(v);
        self.popupError(req, switch (err) {
            error.ContextGone => "the page's browser context no longer exists",
            error.RouteRefused => self.route_refusal,
            else => "popup browser creation failed",
        });
    };
}

pub fn popupError(self: *Host, req: proto.WebextActionActivate, detail: []const u8) void {
    if (req.popup_view == 0) return;
    self.post(proto.EvWebextPopup{
        .owner_view = req.view,
        .popup_view = req.popup_view,
        .state = proto.webext_popup_error,
        .detail = detail,
    });
}

pub fn removePopupView(self: *Host, popup: *View) void {
    for (self.views.items, 0..) |v, i| {
        if (v != popup) continue;
        _ = self.views.swapRemove(i);
        self.freeView(v);
        return;
    }
}

pub fn spawnPopup(self: *Host, v: *View, url_utf8: []const u8) !void {
    // FIRST, before any engine call: the owner page's container may
    // have been destroyed since it opened, and a popup created on
    // the global context would leave the container's egress.
    const rc = try self.contextForSpawn(v);
    var winfo = windowlessInfo();
    // Popups are short-lived and small. Force software frames so the
    // GTK popover owns one simple mapping, never a dma-buf pool.
    winfo.shared_texture_enabled = 0;
    var settings = windowlessSettings(v);
    var url = std.mem.zeroes(cef.cef_string_t);
    setStr(url_utf8, &url);
    defer cef.cef_string_utf16_clear(&url);
    self.pending = v;
    defer self.pending = null;
    const browser = cef.cef_browser_host_create_browser_sync(
        &winfo,
        &host_mod.client,
        &url,
        &settings,
        null,
        rc,
    );
    if (browser == null) return error.BrowserCreateFailed;
    v.browser = browser;
    v.cef_id = browserInt(browser, "get_identifier");
    applyA11yState(v);
    try self.allocBuffer(v);
    self.post(proto.EvWebextPopup{
        .owner_view = v.popup_owner,
        .popup_view = v.id,
        .state = proto.webext_popup_opened,
        .detail = url_utf8,
    });
}

/// One `tabs.on*` event, to every enabled extension's background
/// page. Content frames do not get them: MV2 delivers `tabs` events
/// to extension pages only.
pub fn postTabEvent(self: *Host, ev: []const u8, tb: *const exttabs.Tab, change: ?exttabs.Change) void {
    for (self.webext.exts.items) |*e| {
        if (!e.enabled or !e.ok) continue;
        const bg = if (e.bg_view != 0) self.find(e.bg_view) else null;
        if (bg == null) continue;
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-tab-event\",\"ext\":") catch continue;
        jsonStr(w, e.id) catch continue;
        w.writeAll(",\"cap\":") catch continue;
        jsonStr(w, &e.capability) catch continue;
        w.writeAll(",\"ev\":") catch continue;
        jsonStr(w, ev) catch continue;
        w.writeAll(",\"args\":[") catch continue;
        if (std.mem.eql(u8, ev, "onActivated")) {
            w.print("{{\"tabId\":{d},\"windowId\":{d}}}", .{ tb.id, tb.window_id }) catch continue;
        } else if (change) |ch| {
            // MV2's onUpdated: (tabId, changeInfo, tab).
            w.print("{d},{{", .{tb.id}) catch continue;
            var first = true;
            if (ch.url) {
                w.writeAll("\"url\":") catch continue;
                jsonStr(w, tb.url) catch continue;
                first = false;
            }
            if (ch.title) {
                if (!first) w.writeByte(',') catch continue;
                w.writeAll("\"title\":") catch continue;
                jsonStr(w, tb.title) catch continue;
                first = false;
            }
            if (ch.status) {
                if (!first) w.writeByte(',') catch continue;
                w.writeAll("\"status\":") catch continue;
                jsonStr(w, if (tb.loading) "loading" else "complete") catch continue;
            }
            w.writeAll("},") catch continue;
            exttabs.Table.writeTab(tb, w) catch continue;
        } else {
            exttabs.Table.writeTab(tb, w) catch continue;
        }
        w.writeAll("]}") catch continue;
        self.sendScript(bg.?, cmd.written());
    }
}

pub fn postTabRemoved(self: *Host, id: u32) void {
    for (self.webext.exts.items) |*e| {
        if (!e.enabled or !e.ok) continue;
        const bg = if (e.bg_view != 0) self.find(e.bg_view) else null;
        if (bg == null) continue;
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-tab-event\",\"ext\":") catch continue;
        jsonStr(w, e.id) catch continue;
        w.writeAll(",\"cap\":") catch continue;
        jsonStr(w, &e.capability) catch continue;
        w.print(",\"ev\":\"onRemoved\",\"args\":[{d},{{\"windowId\":0,\"isWindowClosing\":false}}]}}", .{id}) catch continue;
        self.sendScript(bg.?, cmd.written());
    }
}

pub fn postWebextState(self: *Host, e: *webexthost.Extension) void {
    self.post(proto.EvWebextState{
        .id = e.id,
        .name = if (e.man) |*m| m.name else "",
        .version = if (e.man) |*m| m.version else "",
        .enabled = if (e.enabled) 1 else 0,
        .ok = if (e.ok) 1 else 0,
        .err = e.err,
    });
}

/// Spin up the hidden background page for an enabled extension that
/// declares one. Idempotent.
pub fn ensureBackground(self: *Host, e: *webexthost.Extension) void {
    const man = if (e.man) |*m| m else return;
    const bg = man.background orelse return;
    if (bg.scripts.len == 0 and bg.page == null) return;
    if (e.bg_view != 0 and self.find(e.bg_view) != null) return;

    const id = self.next_bg_view;
    self.next_bg_view += 1;
    const v = self.gpa.create(View) catch return;
    v.* = .{
        .id = id,
        .w = 1,
        .h = 1,
        .scale_x1000 = 1000,
        .pw = 1,
        .ph = 1,
        .context = 0,
        .webext_bg = true,
        .sem = semantic.View.init(self.gpa),
    };
    self.views.append(self.gpa, v) catch {
        v.sem.deinit();
        self.gpa.destroy(v);
        return;
    };
    e.bg_view = id;
    webrequest.setBgView(e.id, id);
    var url_buf: [512]u8 = undefined;
    const url = self.backgroundUrl(e, &url_buf);
    v.webext_origin = std.mem.startsWith(u8, url, ext_scheme ++ "://");
    self.spawnBackground(v, url) catch {
        webrequest.setBgView(e.id, 0);
        self.destroyView(id);
        e.bg_view = 0;
        return;
    };
}

/// Where a background page lives.
///
/// With a working `chrome-extension://` scheme this is the AUTHOR's
/// document at the extension's own origin, which is the whole reason
/// the scheme exists: the engine then loads its `<script src>` in
/// document order, ES modules and all, and every relative url,
/// `fetch` and `import` inside resolves. `background.scripts` gets a
/// generated document at the same origin, so both forms end up with
/// one origin and one code path.
///
/// Without the scheme (it was refused, or the extension declares no
/// background page) it falls back to the old `data:` document, and
/// `injectBackground` evaluates the scraped scripts instead — which
/// cannot run a module and says so in the log.
pub fn backgroundUrl(self: *Host, e: *webexthost.Extension, buf: []u8) []const u8 {
    const fallback = "data:text/html,<!doctype html><title>bg</title>";
    if (!ext_scheme_ok) return fallback;
    const man = if (e.man) |*m| m else return fallback;
    const bg = man.background orelse return fallback;
    var host_buf: [16]u8 = undefined;
    const host = extmanifest.originHost(e.id, &host_buf);
    _ = self;
    if (bg.page) |page| {
        const clean = std.mem.trimStart(u8, page, "/");
        return std.fmt.bufPrint(buf, ext_scheme ++ "://{s}/{s}", .{ host, clean }) catch fallback;
    }
    // `background.scripts`: a generated document at the same origin.
    // The path is reserved and served by the scheme handler.
    return std.fmt.bufPrint(buf, ext_scheme ++ "://{s}{s}", .{
        host, extorigins.GENERATED_BG_PATH,
    }) catch fallback;
}

/// Like `spawnBrowser` but for a hidden background page: no frame
/// buffer, so it never paints or is announced. The semantic bridge
/// still injects at context creation, so `injectBackground` can send
/// its scripts on load.
pub fn spawnBackground(self: *Host, v: *View, url_utf8: []const u8) !void {
    // A background page can fetch; on a refused route it must not.
    try self.requireContext(v);
    var winfo = windowlessInfo();
    var bsettings = windowlessSettings(v);
    var url = std.mem.zeroes(cef.cef_string_t);
    setStr(url_utf8, &url);
    defer cef.cef_string_utf16_clear(&url);
    self.pending = v;
    defer self.pending = null;
    const browser = cef.cef_browser_host_create_browser_sync(&winfo, &host_mod.client, &url, &bsettings, null, null);
    if (browser == null) return error.BrowserCreateFailed;
    v.browser = browser;
    v.cef_id = browserInt(browser, "get_identifier");
    v.hidden = true;
    // The SAME rule as `spawnBrowser`, and this is the other browser
    // creation path — now taken for every real extension. Leaving a
    // background page at STATE_DEFAULT lets the engine enable
    // accessibility on it by itself on any desktop with an at-spi
    // bus, and its tree then arrives carrying an `ax_tree_id` bound
    // to no view: `axResolveView` rebinds the unknown token onto the
    // single a11y-enabled CLIENT view, so a screen reader gets the
    // blank 1x1 background page instead of the page being read.
    applyA11yState(v);
    // Tell the engine the view is hidden so it keeps no compositor /
    // frame production alive for a page that never paints.
    withHost(v, struct {
        fn f(host: *cef.cef_browser_host_t) void {
            if (host.was_hidden) |wh| wh(host, 1);
        }
    }.f);
}

pub fn teardownBackground(self: *Host, e: *webexthost.Extension) void {
    if (e.bg_view == 0) return;
    const view = e.bg_view;
    e.bg_view = 0;
    webrequest.setBgView(e.id, 0);
    // An enumerated exit: the page that would answer is going away.
    wreqAbandonView(view);
    self.destroyView(view);
}

/// Inject an extension's content scripts into every live, non-hidden
/// client view whose url matches — used when an extension is enabled
/// while pages are already open.
pub fn injectContentScriptsAll(self: *Host, e: *webexthost.Extension) void {
    for (self.views.items) |v| {
        if (v.webext_bg or v.webext_popup or v.webext_origin or v.discarded or v.browser == null) continue;
        if (v.url.len == 0) continue;
        const b = v.browser orelse continue;
        const gf = b.get_main_frame orelse continue;
        const frame: *cef.cef_frame_t = gf(b) orelse continue;
        defer release(&frame.base);
        self.injectExtInto(frame, v.url, e, null);
    }
}

/// Inject every enabled extension's content scripts matching `v`'s
/// url. `only_phase` null runs every content script (load end / late
/// enable); a specific phase runs only scripts whose `run_at` equals
/// it (load start, for document_start scripts).
pub fn injectMatchingExtensions(
    self: *Host,
    v: *View,
    frame: *cef.cef_frame_t,
    only_phase: ?manifestRunAt,
) void {
    if (v.webext_bg or v.webext_popup or v.webext_origin) return;
    // A SUBFRAME's own url decides what matches there — an ad iframe
    // on `ads.example` is not the page's origin, and `all_frames`
    // exists precisely to reach it.
    const main = isMainFrame(frame);
    var url_buf: [2048]u8 = undefined;
    const url = if (main) v.url else blk: {
        const gu = frame.get_url orelse break :blk v.url;
        const u = userfreeInto(gu(frame), &url_buf);
        break :blk if (u.len != 0) u else v.url;
    };
    for (self.webext.exts.items) |*e| {
        if (!e.enabled or !e.ok) continue;
        self.injectExtInto(frame, url, e, only_phase);
    }
}

/// Build and send one `ext-inject` for extension `e` into view `v`,
/// including only content scripts whose match patterns accept the
/// url and (when `only_phase` is set) whose run_at equals it.
pub fn injectExtInto(
    self: *Host,
    frame: *cef.cef_frame_t,
    url: []const u8,
    e: *webexthost.Extension,
    only_phase: ?manifestRunAt,
) void {
    const man = if (e.man) |*m| m else return;
    const main = isMainFrame(frame);
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    var any = false;

    // Buffer CSS and JS across all matching content_scripts.
    var css_buf: std.Io.Writer.Allocating = .init(self.gpa);
    defer css_buf.deinit();
    var js_buf: std.Io.Writer.Allocating = .init(self.gpa);
    defer js_buf.deinit();
    var css_first = true;
    var js_first = true;

    for (man.content_scripts) |cs| {
        if (only_phase) |p| {
            if (cs.run_at != p) continue;
        }
        // `all_frames` was parsed and honoured by nothing: every
        // injection went to the main frame. Honouring it is the
        // whole point of ad-iframe filtering.
        if (!main and !cs.all_frames) continue;
        if (!self.contentScriptMatches(cs, url)) continue;
        any = true;
        for (cs.css) |rel| {
            const bytes = self.webext.readAsset(e, rel) orelse continue;
            defer self.gpa.free(bytes);
            if (!css_first) css_buf.writer.writeByte(',') catch {};
            css_first = false;
            jsonStr(&css_buf.writer, bytes) catch {};
        }
        for (cs.js) |rel| {
            const bytes = self.webext.readAsset(e, rel) orelse continue;
            defer self.gpa.free(bytes);
            if (!js_first) js_buf.writer.writeByte(',') catch {};
            js_first = false;
            jsonStr(&js_buf.writer, bytes) catch {};
        }
    }
    if (!any) return;

    // The nonce AUTHENTICATES the command; `priv` (deliberately
    // absent here) AUTHORIZES publishing the globals. Content
    // scripts must not get `window.browser`, but they must still
    // prove they came from this process: `ext-inject` hands the
    // scripts it runs a live `browser.*` bound to `ext`, so an
    // unauthenticated one let ANY page pass its own source and get
    // that extension's tabs and storage.local.
    w.writeAll("{\"op\":\"ext-inject\",\"tok\":\"") catch return;
    w.writeAll(&host_mod.sem_secret.nonce) catch return;
    w.writeAll("\",\"ext\":") catch return;
    jsonStr(w, e.id) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.writeAll(",\"base\":") catch return;
    var base_buf: [256]u8 = undefined;
    var host_buf: [16]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, ext_scheme ++ "://{s}/", .{
        extmanifest.originHost(e.id, &host_buf),
    }) catch "";
    jsonStr(w, base) catch return;
    w.writeAll(",\"uilang\":") catch return;
    jsonStr(w, webexthost.uiLanguage()) catch return;
    // manifest inline (small), for getManifest.
    w.writeAll(",\"manifest\":") catch return;
    self.writeManifestJson(w, e) catch w.writeAll("{}") catch return;
    w.writeAll(",\"messages\":") catch return;
    self.writeMessagesJson(w, e);
    w.writeAll(",\"css\":[") catch return;
    w.writeAll(css_buf.written()) catch return;
    w.writeAll("],\"scripts\":[") catch return;
    w.writeAll(js_buf.written()) catch return;
    w.writeAll("]}") catch return;
    self.sendScriptToFrame(frame, cmd.written());
}

pub fn writeManifestJson(self: *Host, w: *std.Io.Writer, e: *webexthost.Extension) !void {
    var buf: [4096]u8 = undefined;
    const mpath = std.fmt.bufPrint(&buf, "{s}/manifest.json", .{e.dir}) catch return error.Path;
    const bytes = webexthost.readFilePub(self.gpa, mpath, webext_max_asset) orelse return error.NoFile;
    defer self.gpa.free(bytes);
    // Inline the raw manifest bytes verbatim (already valid JSON).
    try w.writeAll(bytes);
}

/// Inline the `_locales/<default_locale>/messages.json` object (or
/// `null`) so `browser.i18n.getMessage` resolves synchronously in
/// the content script.
pub fn writeMessagesJson(self: *Host, w: *std.Io.Writer, e: *webexthost.Extension) void {
    var loc_buf: [extorigins.MAX_LOCALE]u8 = undefined;
    const locale = self.webext.resolveLocale(e, &loc_buf) orelse {
        w.writeAll("null") catch {};
        return;
    };
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/_locales/{s}/messages.json", .{ e.dir, locale }) catch {
        w.writeAll("null") catch {};
        return;
    };
    const bytes = webexthost.readFilePub(self.gpa, path, webext_max_asset) orelse {
        w.writeAll("null") catch {};
        return;
    };
    defer self.gpa.free(bytes);
    w.writeAll(bytes) catch {};
}

pub fn contentScriptMatches(self: *Host, cs: manifestContentScript, url: []const u8) bool {
    var set = extmatch.PatternSet{};
    defer set.deinit(self.gpa);
    for (cs.matches) |pat| set.addInclude(self.gpa, pat) catch continue;
    for (cs.exclude_matches) |pat| set.addExclude(self.gpa, pat) catch continue;
    if (set.include.items.len == 0) return false;
    return set.matchesUrl(url);
}

/// Bring an extension's background page up once its document is
/// loaded (called from the load handler).
///
/// On the ORIGIN path there is nothing to do: the served document
/// already carried the bootstrap and the engine already loaded the
/// author's scripts itself, in document order, modules included.
/// This function is therefore the FALLBACK — reached only when the
/// `chrome-extension` scheme was refused — and it evaluates the
/// scripts through the bridge instead.
pub fn injectBackground(self: *Host, v: *View, e: *webexthost.Extension) void {
    if (v.webext_origin) return;
    const man = if (e.man) |*m| m else return;
    const bg = man.background orelse return;
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.writeAll("{\"op\":\"ext-inject\",\"tok\":\"") catch return;
    w.writeAll(&host_mod.sem_secret.nonce) catch return;
    w.writeAll("\",\"priv\":true,") catch return;
    if (c.getenv("SKETERM_WEB_EXT_DEBUG") != null) w.writeAll("\"dbg\":true,") catch return;
    w.writeAll("\"ext\":") catch return;
    jsonStr(w, e.id) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.writeAll(",\"base\":") catch return;
    var base_buf: [256]u8 = undefined;
    var host_buf: [16]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, ext_scheme ++ "://{s}/", .{
        extmanifest.originHost(e.id, &host_buf),
    }) catch "";
    jsonStr(w, base) catch return;
    w.writeAll(",\"manifest\":") catch return;
    self.writeManifestJson(w, e) catch w.writeAll("{}") catch return;
    w.writeAll(",\"messages\":") catch return;
    self.writeMessagesJson(w, e);
    w.writeAll(",\"css\":[],\"scripts\":[") catch return;
    var first = true;
    if (bg.page) |page| {
        // `background.page`: read the document and run its scripts
        // in source order. A MODULE cannot be run this way (a static
        // import is a SyntaxError under `new Function`) so it is
        // skipped with a diagnostic rather than thrown into the log
        // as a mystery parse error.
        self.writeBackgroundPageScripts(w, e, page, &first);
    }
    for (bg.scripts) |rel| {
        const bytes = self.webext.readAsset(e, rel) orelse continue;
        defer self.gpa.free(bytes);
        if (!first) w.writeByte(',') catch {};
        first = false;
        jsonStr(w, bytes) catch {};
    }
    w.writeAll("]}") catch return;
    self.sendScript(v, cmd.written());
}

/// Append a `background.page` document's scripts, in source order,
/// to an `ext-inject` script array. FALLBACK PATH ONLY.
pub fn writeBackgroundPageScripts(
    self: *Host,
    w: *std.Io.Writer,
    e: *webexthost.Extension,
    page: []const u8,
    first: *bool,
) void {
    const html = self.webext.readAsset(e, page) orelse return;
    defer self.gpa.free(html);
    var buf: [64]bgpage.Script = undefined;
    for (bgpage.scan(html, &buf)) |s| {
        if (s.is_module) {
            self.post(proto.EvConsole{
                .view = 0,
                .level = 2,
                .msg = "[webext] background module skipped: no chrome-extension:// origin",
            });
            continue;
        }
        const src: []const u8 = if (s.src.len != 0) blk: {
            // Resolve relative to the page's own directory, as the
            // document itself would.
            var rel_buf: [1024]u8 = undefined;
            const rel = extassets.resolveRelative(page, s.src, &rel_buf) orelse continue;
            break :blk self.webext.readAsset(e, rel) orelse continue;
        } else s.body;
        defer if (s.src.len != 0) self.gpa.free(src);
        if (!first.*) w.writeByte(',') catch {};
        first.* = false;
        jsonStr(w, src) catch {};
    }
}

/// Handle one `ext-*` message from a content or background frame
/// (routed here from `onScriptMessage`). `v` is the frame's view.
pub fn onExtMessage(self: *Host, v: *View, op: []const u8, json: []const u8) void {
    if (std.mem.eql(u8, op, "ext-call")) {
        self.extApiCall(v, json);
    } else if (std.mem.eql(u8, op, "ext-send")) {
        self.extRouteSend(v, json);
    } else if (std.mem.eql(u8, op, "ext-wreq-decision")) {
        self.wreqDecision(v, json);
    } else if (std.mem.eql(u8, op, "ext-reply")) {
        self.extRouteReply(v, json);
    } else if (std.mem.eql(u8, op, "ext-exec-result")) {
        self.extExecResult(v, json);
    } else if (std.mem.eql(u8, op, "ext-connect")) {
        self.extPortConnect(v, json);
    } else if (std.mem.eql(u8, op, "ext-port-msg")) {
        self.extPortMessage(v, json);
    } else if (std.mem.eql(u8, op, "ext-port-close")) {
        self.extPortClose(v, json);
    } else if (std.mem.eql(u8, op, "ext-error")) {
        const E = struct { ext: []const u8 = "", cap: []const u8 = "", msg: []const u8 = "" };
        const e = std.json.parseFromSlice(E, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer e.deinit();
        if (self.webext.authorize(e.value.ext, e.value.cap) == null) return;
        // Surfaced as a console frame so it reaches the client log.
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[webext {s}] {s}", .{ e.value.ext, e.value.msg }) catch return;
        self.post(proto.EvConsole{ .view = v.id, .level = 2, .msg = line });
    }
}

/// A `browser.*` API call: dispatch through the host and reply with
/// `ext-result`. A storage mutation's `onChanged` is broadcast to
/// this extension's frames.
pub fn extApiCall(self: *Host, v: *View, json: []const u8) void {
    const R = struct {
        ext: []const u8 = "",
        cap: []const u8 = "",
        ns: []const u8 = "",
        method: []const u8 = "",
        args: std.json.Value = .null,
        req: u32 = 0,
    };
    const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const r = parsed.value;
    const e = self.webext.authorizeCapability(r.cap) orelse return;
    if (!std.mem.eql(u8, e.id, r.ext)) {
        self.extReplyErr(v, r.req, r.ext, r.cap, "extension capability does not authorize the requested id");
        return;
    }
    // A CONTENT SCRIPT has no business registering a network
    // filter: it runs in a page's renderer, in the main world, and
    // a page could reach it. Only the extension's own background
    // page may. This is the one gate `dispatchApi` cannot make on
    // its own — it has no idea which frame called.
    if (std.mem.eql(u8, r.ns, "webRequest") and !v.webext_bg) {
        self.extReplyErr(v, r.req, e.id, &e.capability, "webRequest listeners require an extension page");
        return;
    }
    // `tabs.sendMessage` has to reach a FRAME, which the engine-free
    // host cannot do; it is answered here instead and never reaches
    // `dispatchApi`.
    if (std.mem.eql(u8, r.ns, "runtime") and std.mem.eql(u8, r.method, "reload")) {
        self.extRequestReload(r.ext);
        self.extReplyOk(v, e, r.req, "null");
        return;
    }
    if (std.mem.eql(u8, r.ns, "tabs") and std.mem.eql(u8, r.method, "sendMessage")) {
        self.extTabsSendMessage(v, e, r.req, r.args);
        return;
    }
    // `tabs.update`/`reload` navigate a VIEW, which again only the
    // engine side can do. uBO reaches for `update` to show its
    // "blocked page" document, so a stub that silently dropped it
    // would leave the user on a dead tab with no explanation.
    if (std.mem.eql(u8, r.ns, "tabs") and
        (std.mem.eql(u8, r.method, "update") or std.mem.eql(u8, r.method, "reload")))
    {
        self.extTabsNavigate(v, e, r.req, r.method, r.args);
        return;
    }
    // Script and style injection reach a FRAME; zoom is the view's.
    if (std.mem.eql(u8, r.ns, "tabs") and
        (std.mem.eql(u8, r.method, "executeScript") or std.mem.eql(u8, r.method, "insertCSS") or
            std.mem.eql(u8, r.method, "removeCSS")))
    {
        self.extTabsExec(v, e, r.req, r.method, r.args);
        return;
    }
    if (std.mem.eql(u8, r.ns, "tabs") and std.mem.eql(u8, r.method, "getZoom")) {
        self.extTabsGetZoom(v, e, r.req, r.args);
        return;
    }
    if (std.mem.eql(u8, r.ns, "webNavigation")) {
        self.extWebNavFrames(v, e, r.req, r.method, r.args);
        return;
    }
    if (std.mem.eql(u8, r.ns, "browserAction") and
        std.mem.eql(u8, r.method, "openPopup"))
    {
        self.extOpenPopup(v, e, r.req);
        return;
    }
    // Re-serialize args as a JSON array string for the host.
    var args_buf: std.Io.Writer.Allocating = .init(self.gpa);
    defer args_buf.deinit();
    std.json.Stringify.value(r.args, .{}, &args_buf.writer) catch {
        self.extReplyErr(v, r.req, e.id, &e.capability, "arguments could not be encoded");
        return;
    };
    var changed: ?[]u8 = null;
    const result = self.webext.dispatchApi(e, r.ns, r.method, args_buf.written(), &changed);
    // A webRequest registration is the moment the request path
    // learns WHERE to send the question: `ensureBackground` may have
    // run before the extension was ever published, so recording the
    // view here — from the frame the call actually arrived on — is
    // the only placement that cannot be stale.
    if (std.mem.eql(u8, r.ns, "webRequest")) webrequest.setBgView(e.id, v.id);
    defer self.gpa.free(result);
    if (std.mem.eql(u8, r.ns, "browserAction") or std.mem.eql(u8, r.ns, "pageAction"))
        self.postActionsForActiveViews();
    // result is `{"result":..}` or `{"error":..}`; forward the inner
    // value/ok to the frame.
    self.sendExtResult(v, e, r.req, result);
    if (changed) |ch| {
        defer self.gpa.free(ch);
        self.broadcastChanged(e, ch);
    }
}

/// THE `ext-result` builder. Every answer to an extension API call
/// — a host dispatch result, an error, a routed reply — goes out
/// through here, so the command shape exists once.
/// `result_json` must already BE JSON; an error message is escaped
/// by `extReplyErr` before it gets here.
pub fn sendExtReply(
    self: *Host,
    v: *View,
    ext: []const u8,
    capability: []const u8,
    req: u32,
    ok: bool,
    result_json: []const u8,
) void {
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.writeAll("{\"op\":\"ext-result\",\"ext\":") catch return;
    jsonStr(w, ext) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, capability) catch return;
    w.print(",\"req\":{d},\"ok\":{s},\"result\":", .{ req, if (ok) "true" else "false" }) catch return;
    w.writeAll(result_json) catch return;
    w.writeByte('}') catch return;
    self.sendScript(v, cmd.written());
}

pub fn sendExtResult(self: *Host, v: *View, e: *const webexthost.Extension, req: u32, host_result: []const u8) void {
    // host_result is a full `{"result":X}` / `{"error":X}` object;
    // the frame wants the inner value plus an ok flag.
    const is_err = std.mem.indexOf(u8, host_result, "\"error\"") != null;
    self.sendExtReply(v, e.id, &e.capability, req, !is_err, innerJson(host_result));
}

pub fn extReplyErr(self: *Host, v: *View, req: u32, ext: []const u8, capability: []const u8, message: []const u8) void {
    var msg: std.Io.Writer.Allocating = .init(self.gpa);
    defer msg.deinit();
    jsonStr(&msg.writer, message) catch return;
    self.sendExtReply(v, ext, capability, req, false, msg.written());
}

pub fn extReplyOk(self: *Host, v: *View, e: *const webexthost.Extension, req: u32, result_json: []const u8) void {
    self.sendExtReply(v, e.id, &e.capability, req, true, result_json);
}

/// Route `browserAction.openPopup()` to the GUI that owns the native toolbar.
pub fn extOpenPopup(self: *Host, caller: *View, e: *webexthost.Extension, req: u32) void {
    if (e.action.kind != .browser or !(caller.webext_bg or caller.webext_popup or caller.webext_origin)) {
        self.extReplyErr(caller, req, e.id, &e.capability, "openPopup requires an extension page");
        return;
    }
    const tb = self.webext.tabs.active() orelse {
        self.extReplyErr(caller, req, e.id, &e.capability, "no active tab in the focused window");
        return;
    };
    const action = e.action.effective(tb.id);
    if (!action.visible or !action.enabled or action.popup.len == 0) {
        self.extReplyErr(caller, req, e.id, &e.capability, "extension action has no enabled visible popup");
        return;
    }
    const ext_copy = self.gpa.dupe(u8, e.id) catch {
        self.extReplyErr(caller, req, e.id, &e.capability, "out of memory");
        return;
    };
    const wire_req = self.webext_next_gid;
    self.webext_next_gid +%= 1;
    if (self.webext_next_gid == 0) self.webext_next_gid = 1;
    if (!self.pushReply(.{
        .kind = .popup,
        .gid = wire_req,
        .origin_req = req,
        .origin_view = caller.id,
        .reply_view = tb.view,
        .ext = ext_copy,
        // The GUI answers or it does not; without a deadline a
        // dropped 0xBB reply parks this Promise for the life of the
        // page. Same clock as a routed message.
        .deadline_ms = nowMs() + route_reply_timeout_ms,
    })) {
        self.gpa.free(ext_copy);
        self.extReplyErr(caller, req, e.id, &e.capability, "out of memory");
        return;
    }
    self.post(proto.EvWebextOpenPopup{ .view = tb.view, .id = e.id, .req = wire_req });
    // The Promise remains pending until the GUI acknowledges that
    // it created the native popup (or reports why it could not).
}

pub fn webextOpenPopupResult(self: *Host, result: proto.WebextOpenPopupResult) void {
    const wait = self.takeReply(.popup, result.req, result.view, result.id) orelse return;
    defer self.gpa.free(wait.ext);
    const caller = self.find(wait.origin_view) orelse return;
    const e = self.webext.find(wait.ext) orelse return;
    if (result.ok != 0) {
        self.extReplyOk(caller, e, wait.origin_req, "null");
    } else {
        const detail = if (result.detail.len != 0) result.detail else "native popup was not created";
        self.extReplyErr(caller, wait.origin_req, e.id, &e.capability, detail);
    }
}

/// Park a Promise on an answer from `reply_view`. The table is
/// bounded; the oldest entry is REJECTED (never silently dropped)
/// to make room.
/// @return false when the record could not be stored, in which case
/// the caller still owes its own Promise an answer.
pub fn pushReply(self: *Host, rec: PendingReply) bool {
    while (self.webext_replies.items.len >= 256) {
        const old = self.webext_replies.orderedRemove(0);
        self.failReply(old, "too many pending extension replies");
    }
    self.webext_replies.append(self.gpa, rec) catch return false;
    return true;
}

/// Remove the one record matching a recipient's answer. The triple
/// is what correlates: the id we minted, the view that answered,
/// and the extension it claims to be.
pub fn takeReply(self: *Host, kind: PendingReply.Kind, gid: u32, reply_view: u32, ext: []const u8) ?PendingReply {
    for (self.webext_replies.items, 0..) |rec, i| {
        if (rec.kind == kind and rec.gid == gid and rec.reply_view == reply_view and
            std.mem.eql(u8, rec.ext, ext))
            return self.webext_replies.orderedRemove(i);
    }
    return null;
}

/// Reject a parked Promise and free the record. Silent when the
/// waiting view or the extension is already gone — there is then
/// nothing left to answer.
pub fn failReply(self: *Host, rec: PendingReply, message: []const u8) void {
    if (self.find(rec.origin_view)) |origin| {
        if (self.webext.find(rec.ext)) |e|
            self.extReplyErr(origin, rec.origin_req, e.id, &e.capability, message);
    }
    self.gpa.free(rec.ext);
}

/// A view died: every record naming it on either end leaves, and
/// the OTHER end (if it is the one waiting) is told why.
pub fn repliesAbandonView(self: *Host, view: u32) void {
    var i: usize = 0;
    while (i < self.webext_replies.items.len) {
        const rec = self.webext_replies.items[i];
        if (rec.origin_view != view and rec.reply_view != view) {
            i += 1;
            continue;
        }
        const taken = self.webext_replies.orderedRemove(i);
        if (taken.origin_view != view) {
            self.failReply(taken, taken.kind.gone());
        } else {
            self.gpa.free(taken.ext);
        }
    }
}

/// An extension was disabled, removed, reloaded or reparsed: its
/// pages are going away with it, so the records are dropped without
/// an answer — the JS object waiting for one has just been revoked.
pub fn repliesAbandonExt(self: *Host, id: []const u8) void {
    var i: usize = 0;
    while (i < self.webext_replies.items.len) {
        if (!std.mem.eql(u8, self.webext_replies.items[i].ext, id)) {
            i += 1;
            continue;
        }
        self.gpa.free(self.webext_replies.orderedRemove(i).ext);
    }
}

/// A content frame's `runtime.sendMessage`: route it to the
/// extension's background page, remembering where to send the reply.
pub fn extRouteSend(self: *Host, v: *View, json: []const u8) void {
    const R = struct { ext: []const u8 = "", cap: []const u8 = "", req: u32 = 0, msg: std.json.Value = .null };
    const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const r = parsed.value;
    const e = self.webext.authorizeCapability(r.cap) orelse return;
    if (!std.mem.eql(u8, e.id, r.ext)) {
        self.extReplyErr(v, r.req, r.ext, r.cap, "extension capability does not authorize the requested id");
        return;
    }
    const bg = if (e.bg_view != 0) self.find(e.bg_view) else null;
    if (bg == null) {
        // No background listening: resolve to undefined, as the web
        // API does when nothing answers.
        self.extReplyErr(v, r.req, e.id, &e.capability, "extension has no background listener");
        return;
    }
    const gid = self.webext_next_gid;
    self.webext_next_gid +%= 1;
    if (self.webext_next_gid == 0) self.webext_next_gid = 1;
    const ext_copy = self.gpa.dupe(u8, e.id) catch {
        self.extReplyErr(v, r.req, e.id, &e.capability, "out of memory");
        return;
    };
    if (!self.pushReply(.{
        .kind = .message,
        .gid = gid,
        .origin_view = v.id,
        .origin_req = r.req,
        .reply_view = bg.?.id,
        .ext = ext_copy,
        .deadline_ms = nowMs() + route_reply_timeout_ms,
    })) {
        self.gpa.free(ext_copy);
        self.extReplyErr(v, r.req, e.id, &e.capability, "out of memory");
        return;
    }
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.print("{{\"op\":\"ext-message\",\"ext\":", .{}) catch return;
    jsonStr(w, e.id) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.print(",\"gid\":{d},\"sender\":", .{gid}) catch return;
    self.writeSender(w, v, e.id) catch return;
    w.writeAll(",\"msg\":") catch return;
    std.json.Stringify.value(r.msg, .{}, w) catch return;
    w.writeByte('}') catch return;
    self.sendScript(bg.?, cmd.written());
}

/// `browser.runtime.reload()` — restart ONE extension.
///
/// Not a nicety. uBlock Origin's first run ends with
/// `vAPI.app.restart()` and a bare `return`: on a Chromium-flavoured
/// browser with no stored version it deliberately abandons the rest
/// of its boot and waits to be started again. With `reload` stubbed
/// out as a no-op, uBO therefore sat forever half-initialised —
/// enabled, listening, and filtering NOTHING, with no error anywhere.
///
/// Deferred to the next poll turn (`webextPump`) because it destroys
/// the background page whose script is mid-call.
pub fn extRequestReload(self: *Host, id: []const u8) void {
    for (self.webext_reload.items) |pending| {
        if (std.mem.eql(u8, pending, id)) return;
    }
    const copy = self.gpa.dupe(u8, id) catch return;
    self.webext_reload.append(self.gpa, copy) catch {
        self.gpa.free(copy);
        return;
    };
}

/// Perform the deferred extension restarts. Once per poll turn.
pub fn webextPump(self: *Host) void {
    // Debounced storage.local writes land here, one loop iteration
    // after their window expires.
    self.webext.flushStores(nowMs());
    self.gm_values.flush(nowMs());
    if (self.webext_reload.items.len == 0) return;
    const pending = self.webext_reload.toOwnedSlice(self.gpa) catch return;
    defer {
        for (pending) |p| self.gpa.free(p);
        self.gpa.free(pending);
    }
    for (pending) |id| {
        const e = self.webext.find(id) orelse continue;
        if (!e.enabled or !e.ok) continue;
        // A full down-and-up: the listeners, the Ports and the
        // background page all belong to the instance going away.
        self.revokeExtension(e, "extension reloaded");
        wreqAbandonExt(id);
        self.repliesAbandonExt(id);
        self.portsAbandonExt(id);
        self.webext.clearListeners(e);
        self.teardownBackground(e);
        if (!self.webext.rotateCapability(e)) {
            self.unpublishOrigin(id);
            self.postWebextState(e);
            continue;
        }
        self.publishOrigin(e);
        self.ensureBackground(e);
        self.injectContentScriptsAll(e);
    }
}

/// `browser.tabs.update({url})` / `tabs.reload()` — navigate the
/// view a tab is showing.
pub fn extTabsNavigate(self: *Host, v: *View, e: *webexthost.Extension, req: u32, method: []const u8, args: std.json.Value) void {
    const items = if (args == .array) args.array.items else &[_]std.json.Value{};
    const raw_id: i64 = if (items.len > 0 and items[0] == .integer) items[0].integer else -1;
    // A negative id means "the active tab", MV2's default.
    const tb = blk: {
        // Range-checked, not narrowed: an out-of-range id must
        // resolve to NO tab, not wrap onto a real one. In
        // ReleaseFast `@intCast` truncates, so `tabs.update(2**32+1,
        // {url})` navigated tab 1 — a tab the extension never named.
        if (raw_id >= 0) break :blk if (exttabs.u32Of(items[0])) |id| self.webext.tabs.find(id) else null;
        break :blk self.webext.tabs.active();
    } orelse {
        self.extReplyErr(v, req, e.id, &e.capability, "no such tab");
        return;
    };
    const target = if (tb.view != 0) self.find(tb.view) else null;
    if (target == null) {
        self.extReplyErr(v, req, e.id, &e.capability, "tab has no live browser view");
        return;
    }
    var url: []const u8 = "";
    if (std.mem.eql(u8, method, "update")) {
        if (items.len > 1 and items[1] == .object) {
            if (items[1].object.get("url")) |u| {
                if (u == .string) url = u.string;
            }
        }
    }
    if (c.getenv("SKETERM_WEB_WREQ_DEBUG") != null) {
        std.debug.print("tabs.{s} tab {d} -> \"{s}\"\n", .{ method, tb.id, url });
    }
    if (url.len != 0) {
        self.navigate(.{ .view = target.?.id, .url = url });
    } else if (std.mem.eql(u8, method, "reload")) {
        self.navAction(.{ .view = target.?.id, .action = @intFromEnum(proto.NavAct.reload) });
    }
    self.extReplyOk(v, e, req, "null");
}

/// The tab a `tabs.*` call names (negative = the active one) and its
/// live view; the reply is sent from here when there is none.
pub fn extTabView(self: *Host, v: *View, e: *webexthost.Extension, req: u32, id_arg: ?std.json.Value) ?struct { tab: *const exttabs.Tab, view: *View } {
    const raw_id: i64 = if (id_arg) |a| (if (a == .integer) a.integer else -1) else -1;
    const tb = blk: {
        if (raw_id >= 0) break :blk if (exttabs.u32Of(id_arg.?)) |id| self.webext.tabs.find(id) else null;
        break :blk self.webext.tabs.active();
    } orelse {
        self.extReplyErr(v, req, e.id, &e.capability, "no such tab");
        return null;
    };
    const target = (if (tb.view != 0) self.find(tb.view) else null) orelse {
        self.extReplyErr(v, req, e.id, &e.capability, "tab has no live browser view");
        return null;
    };
    return .{ .tab = tb, .view = target };
}

/// Whether the extension's host permissions cover `url` — what
/// `executeScript`/`insertCSS` require of the tab's document.
pub fn extHostAllowed(self: *Host, e: *const webexthost.Extension, url: []const u8) bool {
    const man = if (e.man) |*m| m else return false;
    var set: extmatch.PatternSet = .{};
    defer set.deinit(self.gpa);
    for (man.permissions) |p| set.addInclude(self.gpa, p) catch continue;
    for (man.host_permissions) |p| set.addInclude(self.gpa, p) catch continue;
    return set.matchesUrl(url);
}

/// `tabs.executeScript` / `insertCSS` / `removeCSS`, args
/// `[tabId, details]`. Runs in ONE frame — the main one, or
/// `details.frameId` — through the semantic slot, and answers with
/// that frame's `ext-exec-result`. `allFrames` is refused rather
/// than half-served. A `runAt:"document_start"` call against a view
/// that is mid-navigation waits for the new document's load start,
/// which is where uBlock Origin's scriptlets (sent from
/// `onResponseStarted`) have to land.
pub fn extTabsExec(self: *Host, v: *View, e: *webexthost.Extension, req: u32, method: []const u8, args: std.json.Value) void {
    const items = if (args == .array) args.array.items else &[_]std.json.Value{};
    const tv = self.extTabView(v, e, req, if (items.len > 0) items[0] else null) orelse return;
    const details: ?std.json.ObjectMap = if (items.len > 1 and items[1] == .object) items[1].object else null;
    const d = details orelse {
        self.extReplyErr(v, req, e.id, &e.capability, "missing details");
        return;
    };
    if (d.get("allFrames")) |af| if (af == .bool and af.bool) {
        self.extReplyErr(v, req, e.id, &e.capability, "allFrames is not supported: target one frame (frameId)");
        return;
    };
    const tab_url = if (tv.view.url.len != 0) tv.view.url else tv.tab.url;
    if (!self.extHostAllowed(e, tab_url)) {
        self.extReplyErr(v, req, e.id, &e.capability, "missing host permission for the tab");
        return;
    }
    var owned_file: ?[]u8 = null;
    defer if (owned_file) |f| self.gpa.free(f);
    var code: []const u8 = "";
    if (d.get("code")) |cv| {
        if (cv == .string) code = cv.string;
    } else if (d.get("file")) |fv| {
        if (fv == .string) {
            owned_file = self.webext.readAsset(e, fv.string);
            code = owned_file orelse {
                self.extReplyErr(v, req, e.id, &e.capability, "file not found in the extension package");
                return;
            };
        }
    }
    if (code.len == 0) {
        self.extReplyErr(v, req, e.id, &e.capability, "details need code or file");
        return;
    }
    const frame_id: i64 = if (d.get("frameId")) |fv| (if (fv == .integer) fv.integer else 0) else 0;
    const is_css = !std.mem.eql(u8, method, "executeScript");
    const gid = self.webext_next_gid;
    self.webext_next_gid +%= 1;
    if (self.webext_next_gid == 0) self.webext_next_gid = 1;

    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    const slot: []const u8 = &host_mod.sem_secret.slot;
    // An OBJECT command, so script code can travel as a function
    // literal compiled with the command itself: a page whose CSP
    // forbids eval() still runs it (the result is then undefined,
    // because only eval yields a completion value).
    w.print("window[\"{s}\"]&&window[\"{s}\"]({{\"op\":\"ext-exec\",\"ext\":", .{ slot, slot }) catch return;
    jsonStr(w, e.id) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.print(",\"gid\":{d}", .{gid}) catch return;
    if (is_css) {
        w.writeAll(",\"css\":") catch return;
        jsonStr(w, code) catch return;
        if (std.mem.eql(u8, method, "removeCSS")) w.writeAll(",\"remove\":true") catch return;
    } else {
        w.writeAll(",\"code\":") catch return;
        jsonStr(w, code) catch return;
        w.writeAll(",\"fn\":function(){\n") catch return;
        w.writeAll(code) catch return;
        w.writeAll("\n}") catch return;
    }
    w.writeAll("},0)") catch return;

    const ext_copy = self.gpa.dupe(u8, e.id) catch {
        self.extReplyErr(v, req, e.id, &e.capability, "out of memory");
        return;
    };
    if (!self.pushReply(.{
        .kind = .exec,
        .gid = gid,
        .origin_view = v.id,
        .origin_req = req,
        .reply_view = tv.view.id,
        .ext = ext_copy,
        .deadline_ms = nowMs() + route_reply_timeout_ms,
    })) {
        self.gpa.free(ext_copy);
        self.extReplyErr(v, req, e.id, &e.capability, "out of memory");
        return;
    }
    const run_at: []const u8 = if (d.get("runAt")) |rv| (if (rv == .string) rv.string else "") else "";
    if (frame_id == 0 and std.mem.eql(u8, run_at, "document_start") and tv.view.exec_nav_pending) {
        // The document this is meant for has not committed yet.
        const js = self.gpa.dupe(u8, cmd.written()) catch return;
        tv.view.exec_at_start.append(self.gpa, js) catch self.gpa.free(js);
        return;
    }
    const b = tv.view.browser orelse return;
    const frame: *cef.cef_frame_t = blk: {
        if (frame_id == 0) {
            const gf = b.get_main_frame orelse return;
            break :blk gf(b) orelse return;
        }
        break :blk self.frameById(tv.view, frame_id) orelse {
            if (self.takeReply(.exec, gid, tv.view.id, e.id)) |rec| self.failReply(rec, "no frame with that frameId");
            return;
        };
    };
    defer release(&frame.base);
    runJs(frame, cmd.written());
}

/// Run the `document_start` scripts queued for a view's next
/// document. Called from the main frame's load start.
pub fn flushExecAtStart(self: *Host, v: *View, frame: *cef.cef_frame_t) void {
    if (v.exec_at_start.items.len == 0) return;
    const list = v.exec_at_start.toOwnedSlice(self.gpa) catch return;
    defer {
        for (list) |js| self.gpa.free(js);
        self.gpa.free(list);
    }
    for (list) |js| runJs(frame, js);
}

/// A frame answered `tabs.executeScript`/`insertCSS`/`removeCSS`.
pub fn extExecResult(self: *Host, v: *View, json: []const u8) void {
    const R = struct { ext: []const u8 = "", cap: []const u8 = "", gid: u32 = 0, ok: bool = false, err: []const u8 = "", result: std.json.Value = .null };
    const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const e = self.webext.authorize(parsed.value.ext, parsed.value.cap) orelse return;
    const route = self.takeReply(.exec, parsed.value.gid, v.id, e.id) orelse return;
    defer self.gpa.free(route.ext);
    const origin = self.find(route.origin_view) orelse return;
    if (!parsed.value.ok) {
        self.extReplyErr(origin, route.origin_req, e.id, &e.capability, if (parsed.value.err.len != 0) parsed.value.err else "script failed");
        return;
    }
    // executeScript resolves with one result PER FRAME it ran in.
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    out.writer.writeByte('[') catch return;
    std.json.Stringify.value(parsed.value.result, .{}, &out.writer) catch return;
    out.writer.writeByte(']') catch return;
    self.sendExtReply(origin, e.id, &e.capability, route.origin_req, true, out.written());
}

/// A frame of `v` by the `frameId` this helper reports for it
/// (`frameIdOf`); the caller releases it.
pub fn frameById(self: *Host, v: *View, want: i64) ?*cef.cef_frame_t {
    _ = self;
    const b = v.browser orelse return null;
    const gfi = b.get_frame_identifiers orelse return null;
    const byid = b.get_frame_by_identifier orelse return null;
    const list = cef.cef_string_list_alloc() orelse return null;
    defer cef.cef_string_list_free(list);
    gfi(b, list);
    const n = cef.cef_string_list_size(list);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var ident = std.mem.zeroes(cef.cef_string_t);
        defer cef.cef_string_utf16_clear(&ident);
        if (cef.cef_string_list_value(list, i, &ident) == 0) continue;
        const frame: *cef.cef_frame_t = byid(b, &ident) orelse continue;
        if (frameIdOf(frame) == want) return frame;
        release(&frame.base);
    }
    return null;
}

/// `tabs.getZoom([tabId])`: the user zoom as a factor.
pub fn extTabsGetZoom(self: *Host, v: *View, e: *webexthost.Extension, req: u32, args: std.json.Value) void {
    const items = if (args == .array) args.array.items else &[_]std.json.Value{};
    const tv = self.extTabView(v, e, req, if (items.len > 0) items[0] else null) orelse return;
    const factor = std.math.pow(f64, 1.2, @as(f64, @floatFromInt(tv.view.user_zoom_x100)) / 100.0);
    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d:.4}", .{factor}) catch "1";
    self.extReplyOk(v, e, req, txt);
}

/// `webNavigation.getFrame({tabId, frameId})` /
/// `getAllFrames({tabId})`, from the engine's live frame tree.
pub fn extWebNavFrames(self: *Host, v: *View, e: *webexthost.Extension, req: u32, method: []const u8, args: std.json.Value) void {
    const man = if (e.man) |*m| m else return;
    if (!man.hasPermission("webNavigation")) {
        self.extReplyErr(v, req, e.id, &e.capability, "webNavigation permission is required");
        return;
    }
    const items = if (args == .array) args.array.items else &[_]std.json.Value{};
    const d: ?std.json.ObjectMap = if (items.len > 0 and items[0] == .object) items[0].object else null;
    const tab_arg: ?std.json.Value = if (d) |o| o.get("tabId") else null;
    const tv = self.extTabView(v, e, req, tab_arg) orelse return;
    const want_one = std.mem.eql(u8, method, "getFrame");
    const want_id: i64 = if (d) |o| (if (o.get("frameId")) |f| (if (f == .integer) f.integer else 0) else 0) else 0;
    const b = tv.view.browser orelse {
        self.extReplyOk(v, e, req, if (want_one) "null" else "[]");
        return;
    };
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    const w = &out.writer;
    if (!want_one) w.writeByte('[') catch return;
    var wrote = false;
    const gfi = b.get_frame_identifiers orelse return;
    const byid = b.get_frame_by_identifier orelse return;
    const list = cef.cef_string_list_alloc() orelse return;
    defer cef.cef_string_list_free(list);
    gfi(b, list);
    const n = cef.cef_string_list_size(list);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var ident = std.mem.zeroes(cef.cef_string_t);
        defer cef.cef_string_utf16_clear(&ident);
        if (cef.cef_string_list_value(list, i, &ident) == 0) continue;
        const frame: *cef.cef_frame_t = byid(b, &ident) orelse continue;
        defer release(&frame.base);
        const fid = frameIdOf(frame);
        if (want_one and fid != want_id) continue;
        if (wrote) w.writeByte(',') catch return;
        wrote = true;
        var url_buf: [2048]u8 = undefined;
        const url = if (frame.get_url) |gu| userfreeInto(gu(frame), &url_buf) else "";
        w.print("{{\"frameId\":{d},\"parentFrameId\":{d},\"errorOccurred\":false,\"url\":", .{ fid, parentFrameIdOf(frame) }) catch return;
        jsonStr(w, url) catch return;
        w.writeByte('}') catch return;
        if (want_one) break;
    }
    if (want_one) {
        if (!wrote) w.writeAll("null") catch return;
    } else w.writeByte(']') catch return;
    self.extReplyOk(v, e, req, out.written());
}

/// One `webNavigation.<ev>` event for a frame of a page view, to
/// every enabled extension holding the `webNavigation` permission.
pub fn webNavEvent(self: *Host, v: *View, frame: ?*cef.cef_frame_t, ev: []const u8, url_override: []const u8, extra: []const u8) void {
    if (v.webext_bg or v.webext_popup or v.devtools_of != 0) return;
    const f = frame orelse return;
    var any = false;
    for (self.webext.exts.items) |*e| {
        if (!e.enabled or !e.ok or e.bg_view == 0) continue;
        const man = if (e.man) |*m| m else continue;
        if (man.hasPermission("webNavigation")) {
            any = true;
            break;
        }
    }
    if (!any) return;
    var url_buf: [2048]u8 = undefined;
    const url = if (url_override.len != 0) url_override else if (f.get_url) |gu| userfreeInto(gu(f), &url_buf) else "";
    // A page no extension could see (the helper's own internal
    // documents) never produces an event.
    if (std.mem.startsWith(u8, url, ext_scheme ++ "://")) return;
    const tab_id: i64 = if (self.webext.tabs.findByView(v.id)) |tb| @intCast(tb.id) else -1;
    var details: std.Io.Writer.Allocating = .init(self.gpa);
    defer details.deinit();
    const dw = &details.writer;
    dw.print("{{\"tabId\":{d},\"frameId\":{d},\"parentFrameId\":{d},\"processId\":-1,\"timeStamp\":{d},\"url\":", .{
        tab_id, frameIdOf(f), parentFrameIdOf(f), @import("../../util/clock.zig").wallMs(),
    }) catch return;
    jsonStr(dw, url) catch return;
    if (extra.len != 0) {
        dw.writeByte(',') catch return;
        dw.writeAll(extra) catch return;
    }
    dw.writeByte('}') catch return;
    for (self.webext.exts.items) |*e| {
        if (!e.enabled or !e.ok) continue;
        const man = if (e.man) |*m| m else continue;
        if (!man.hasPermission("webNavigation")) continue;
        const bg = if (e.bg_view != 0) self.find(e.bg_view) else null;
        if (bg == null) continue;
        self.postNsEvent(bg.?, e, "webNavigation", ev, details.written());
    }
}

/// `{op:"ext-ns-event"}`: fire `browser.<ns>.<ev>(args...)` in one
/// extension page. `args_json` is the single argument, already JSON.
pub fn postNsEvent(self: *Host, target: *View, e: *const webexthost.Extension, ns: []const u8, ev: []const u8, arg_json: []const u8) void {
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.writeAll("{\"op\":\"ext-ns-event\",\"ext\":") catch return;
    jsonStr(w, e.id) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.writeAll(",\"ns\":") catch return;
    jsonStr(w, ns) catch return;
    w.writeAll(",\"ev\":") catch return;
    jsonStr(w, ev) catch return;
    w.writeAll(",\"args\":[") catch return;
    w.writeAll(arg_json) catch return;
    w.writeAll("]}") catch return;
    self.sendScript(target, cmd.written());
}

/// `browser.tabs.sendMessage(tabId, message)` — the direction that
/// did not exist: background -> a CONTENT frame.
///
/// It cannot live in `webext/host.zig` with the rest of `tabs`,
/// because delivering it means finding a view and evaluating in its
/// frames, which is engine work. It reuses the `webext_replies`
/// table, just with the roles swapped: the background is the origin
/// awaiting a reply and the content frame answers with `ext-reply`.
pub fn extTabsSendMessage(self: *Host, v: *View, e: *webexthost.Extension, req: u32, args: std.json.Value) void {
    const items = if (args == .array) args.array.items else &[_]std.json.Value{};
    if (items.len < 1 or items[0] != .integer) {
        self.extReplyErr(v, req, e.id, &e.capability, "bad tab id");
        return;
    }
    const tab_id: u32 = exttabs.u32Of(items[0]) orelse {
        // Same rule as extTabsNavigate: out of range names no tab.
        self.extReplyErr(v, req, e.id, &e.capability, "bad tab id");
        return;
    };
    const tb = self.webext.tabs.find(tab_id) orelse {
        self.extReplyErr(v, req, e.id, &e.capability, "no such tab");
        return;
    };
    const target = if (tb.view != 0) self.find(tb.view) else null;
    if (target == null) {
        self.extReplyErr(v, req, e.id, &e.capability, "tab has no live browser view");
        return;
    }
    const gid = self.webext_next_gid;
    self.webext_next_gid +%= 1;
    if (self.webext_next_gid == 0) self.webext_next_gid = 1;
    const ext_copy = self.gpa.dupe(u8, e.id) catch {
        self.extReplyErr(v, req, e.id, &e.capability, "out of memory");
        return;
    };
    if (!self.pushReply(.{
        .kind = .message,
        .gid = gid,
        .origin_view = v.id,
        .origin_req = req,
        .reply_view = target.?.id,
        .ext = ext_copy,
        .deadline_ms = nowMs() + route_reply_timeout_ms,
    })) {
        self.gpa.free(ext_copy);
        self.extReplyErr(v, req, e.id, &e.capability, "out of memory");
        return;
    }
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.writeAll("{\"op\":\"ext-message\",\"ext\":") catch return;
    jsonStr(w, e.id) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.print(",\"gid\":{d},\"sender\":{{\"id\":", .{gid}) catch return;
    jsonStr(w, e.id) catch return;
    w.writeAll("},\"msg\":") catch return;
    const msg = if (items.len > 1) items[1] else std.json.Value.null;
    std.json.Stringify.value(msg, .{}, w) catch return;
    w.writeByte('}') catch return;
    // Every frame of the tab, so a content script in an iframe is
    // reachable too; the FIRST reply wins, which is what MV2's
    // single-response contract already means.
    self.sendScriptAllFrames(target.?, cmd.written());
}

// -- runtime.connect Ports ----------------------------------------

/// A frame opened a Port. Mint the id, remember both ends, tell the
/// opener its number and the far end that it has a connection.
///
/// The far end is the extension's background page (MV2 routes a
/// content script's `connect` there). A connect with no background
/// listening is answered with `gid = 0`, which the JS side turns
/// into an immediate `onDisconnect` — never a silent hang, since a
/// content script that gets neither reply is a content script that
/// wedged.
pub fn extPortConnect(self: *Host, v: *View, json: []const u8) void {
    const R = struct { ext: []const u8 = "", cap: []const u8 = "", lid: u32 = 0, name: []const u8 = "" };
    const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const r = parsed.value;
    const e = self.webext.authorize(r.ext, r.cap);
    const bg_view = if (e) |ex| ex.bg_view else 0;
    // A background page cannot connect to itself.
    const target = if (bg_view != 0 and bg_view != v.id) self.find(bg_view) else null;
    if (e == null or target == null) {
        if (e) |ex| self.sendPortOpen(v, ex, r.lid, 0);
        return;
    }
    const gid = self.webext_next_port;
    self.webext_next_port +%= 1;
    if (self.webext_next_port == 0) self.webext_next_port = 1;
    // A page that opens ports without bound must not grow the table
    // without bound; the oldest is closed, exactly as `webext_replies`
    // drops its oldest entry.
    if (self.webext_ports.items.len >= 256) {
        const old = self.webext_ports.orderedRemove(0);
        self.notifyPortClosed(old.a_view, old.ext, old.gid);
        self.notifyPortClosed(old.b_view, old.ext, old.gid);
        self.gpa.free(old.ext);
    }
    const ext_copy = self.gpa.dupe(u8, r.ext) catch {
        self.sendPortOpen(v, e.?, r.lid, 0);
        return;
    };
    self.webext_ports.append(self.gpa, .{
        .gid = gid,
        .ext = ext_copy,
        .a_view = v.id,
        .b_view = bg_view,
    }) catch {
        self.gpa.free(ext_copy);
        self.sendPortOpen(v, e.?, r.lid, 0);
        return;
    };
    self.sendPortOpen(v, e.?, r.lid, gid);

    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.writeAll("{\"op\":\"ext-port-incoming\",\"ext\":") catch return;
    jsonStr(w, r.ext) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.?.capability) catch return;
    w.print(",\"gid\":{d},\"name\":", .{gid}) catch return;
    jsonStr(w, r.name) catch return;
    w.writeAll(",\"sender\":") catch return;
    self.writeSender(w, v, r.ext) catch return;
    w.writeByte('}') catch return;
    self.sendScript(target.?, cmd.written());
}

pub fn sendPortOpen(self: *Host, v: *View, e: *const webexthost.Extension, lid: u32, gid: u32) void {
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.writeAll("{\"op\":\"ext-port-open\",\"ext\":") catch return;
    jsonStr(w, e.id) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.print(",\"lid\":{d},\"gid\":{d}}}", .{ lid, gid }) catch return;
    self.sendScript(v, cmd.written());
}

pub fn findPort(self: *Host, gid: u32) ?*Port {
    for (self.webext_ports.items) |*p| {
        if (p.gid == gid) return p;
    }
    return null;
}

pub fn extPortMessage(self: *Host, v: *View, json: []const u8) void {
    const R = struct { ext: []const u8 = "", cap: []const u8 = "", gid: u32 = 0, msg: std.json.Value = .null };
    const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const e = self.webext.authorize(parsed.value.ext, parsed.value.cap) orelse return;
    const p = self.findPort(parsed.value.gid) orelse return;
    if (!std.mem.eql(u8, p.ext, e.id)) return;
    // "Not a participant" and "the peer is gone" are different
    // answers: `peerOf` returns 0 for both, and treating the first
    // as the second let a non-participant CLOSE any port it named.
    if (p.a_view != v.id and p.b_view != v.id) return;
    const peer_id = p.peerOf(v.id);
    const peer = if (peer_id != 0) self.find(peer_id) else null;
    if (peer == null) {
        // The far end went away: tell the sender rather than
        // dropping its message into nothing.
        self.closePortByGid(parsed.value.gid);
        return;
    }
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.writeAll("{\"op\":\"ext-port-recv\",\"ext\":") catch return;
    jsonStr(w, p.ext) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.print(",\"gid\":{d},\"msg\":", .{parsed.value.gid}) catch return;
    std.json.Stringify.value(parsed.value.msg, .{}, w) catch return;
    w.writeByte('}') catch return;
    self.sendScript(peer.?, cmd.written());
}

pub fn extPortClose(self: *Host, v: *View, json: []const u8) void {
    const R = struct { ext: []const u8 = "", cap: []const u8 = "", gid: u32 = 0 };
    const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const e = self.webext.authorize(parsed.value.ext, parsed.value.cap) orelse return;
    // ONLY a participant may close a port. gids are small and
    // sequential, so ignoring the calling view let anything able to
    // emit `ext-*` walk the space and disconnect ports belonging to
    // OTHER tabs — and a content script treats a disconnect as
    // teardown, so uBO and Violentmonkey would go silently dead
    // across every open tab with nothing logged.
    const p = self.findPort(parsed.value.gid) orelse return;
    if (!std.mem.eql(u8, p.ext, e.id)) return;
    if (p.a_view != v.id and p.b_view != v.id) return;
    self.closePortByGid(parsed.value.gid);
}

/// Drop a port and tell BOTH ends. Telling the closer too is
/// deliberate: its own `disconnect()` already marked it dead, and a
/// close arriving from the other direction must reach it.
pub fn closePortByGid(self: *Host, gid: u32) void {
    for (self.webext_ports.items, 0..) |p, i| {
        if (p.gid != gid) continue;
        const rec = self.webext_ports.orderedRemove(i);
        self.notifyPortClosed(rec.a_view, rec.ext, rec.gid);
        self.notifyPortClosed(rec.b_view, rec.ext, rec.gid);
        self.gpa.free(rec.ext);
        return;
    }
}

pub fn notifyPortClosed(self: *Host, view: u32, ext: []const u8, gid: u32) void {
    const v = self.find(view) orelse return;
    const e = self.webext.find(ext) orelse return;
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.writeAll("{\"op\":\"ext-port-closed\",\"ext\":") catch return;
    jsonStr(w, ext) catch return;
    w.writeAll(",\"cap\":") catch return;
    jsonStr(w, &e.capability) catch return;
    w.print(",\"gid\":{d}}}", .{gid}) catch return;
    self.sendScript(v, cmd.written());
}

/// Every port either end of which was `view` is closed, and the
/// surviving end told. Called when a view goes away, and when its
/// main document is replaced: a Port whose peer is gone (or whose
/// peer's `Port` object died with its document) must disconnect,
/// never wait forever. Idempotent, so the paths that do both in
/// sequence cost only a scan.
pub fn portsAbandonView(self: *Host, view: u32) void {
    var i: usize = 0;
    while (i < self.webext_ports.items.len) {
        const p = self.webext_ports.items[i];
        if (p.a_view != view and p.b_view != view) {
            i += 1;
            continue;
        }
        const rec = self.webext_ports.orderedRemove(i);
        self.notifyPortClosed(rec.peerOf(view), rec.ext, rec.gid);
        self.gpa.free(rec.ext);
    }
}

/// Same, for every port of one extension (disabled, removed,
/// reparsed): the listener functions on both ends are going away.
pub fn portsAbandonExt(self: *Host, id: []const u8) void {
    var i: usize = 0;
    while (i < self.webext_ports.items.len) {
        const p = self.webext_ports.items[i];
        if (!std.mem.eql(u8, p.ext, id)) {
            i += 1;
            continue;
        }
        const rec = self.webext_ports.orderedRemove(i);
        self.notifyPortClosed(rec.a_view, rec.ext, rec.gid);
        self.notifyPortClosed(rec.b_view, rec.ext, rec.gid);
        self.gpa.free(rec.ext);
    }
}

/// The MV2 `MessageSender`. `{id}` alone was never enough: Dark
/// Reader keys its per-tab state on `sender.tab.id` and every
/// extension that answers a content script reads `sender.url`.
pub fn writeSender(self: *Host, w: *std.Io.Writer, v: *View, ext: []const u8) !void {
    try w.writeAll("{\"id\":");
    try jsonStr(w, ext);
    try w.writeAll(",\"url\":");
    try jsonStr(w, v.url);
    // Frame identity: 0 is the main frame, matching MV2. Subframe
    // ids are per-view sequence numbers assigned as frames are seen.
    try w.print(",\"frameId\":{d}", .{v.cur_frame_id});
    if (self.webext.tabs.findByView(v.id)) |tb| {
        try w.writeAll(",\"tab\":");
        try exttabs.Table.writeTab(tb, w);
    }
    try w.writeByte('}');
}

/// The background's reply to a routed message: deliver it to the
/// original content frame's pending promise.
pub fn extRouteReply(self: *Host, v: *View, json: []const u8) void {
    const R = struct { ext: []const u8 = "", cap: []const u8 = "", gid: u32 = 0, resp: std.json.Value = .null };
    const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const e = self.webext.authorize(parsed.value.ext, parsed.value.cap) orelse return;
    const route = self.takeReply(.message, parsed.value.gid, v.id, e.id) orelse return;
    defer self.gpa.free(route.ext);
    const origin = self.find(route.origin_view) orelse return;
    var resp: std.Io.Writer.Allocating = .init(self.gpa);
    defer resp.deinit();
    std.json.Stringify.value(parsed.value.resp, .{}, &resp.writer) catch return;
    self.sendExtReply(origin, e.id, &e.capability, route.origin_req, true, resp.written());
}

// ---------------------------------------------------------------------
// chrome-extension:// — the WebExtensions origin
// ---------------------------------------------------------------------
//
// An extension needs a real ORIGIN, not just a way to run scripts. Every
// MV2 extension worth hosting reaches for one within its first few
// lines: uBO's `js/start.js` is `type="module"` with twenty static
// imports, each of which is a FETCH that only a scheme handler can
// answer; `runtime.getURL` hands such urls to pages and to `fetch`;
// popup and options pages are documents at that origin. Evaluating
// scraped script text through `new Function` — which is all this host
// could do before — cannot supply any of it, and a static `import` is
// not even syntactically legal there.
//
// So: `chrome-extension` is registered as a CUSTOM SCHEME from the app,
// in every process (Chromium requires the registration to agree
// process-wide), and a factory serves it out of the unpacked directory.
// The host component is NOT the extension id — see `manifest.originHost`
// for why it cannot be — so the table is keyed on that derived host.
//
// EVERYTHING BELOW `create` RUNS ON CEF's IO THREAD. It reads the origin
// table under `origins.lock` (copying by value, then releasing), and it
// allocates through `std.heap.c_allocator` rather than the host's
// DebugAllocator — malloc is unambiguously thread-safe and the host's
// allocator belongs to the main thread's ownership story. The file read
// is synchronous on that thread, which is what CEF's own samples do and
// is bounded by `webext_max_asset`; an extension's assets are local
// files, so this trades a bounded local read for not having to keep a
// half-built response alive across a thread hop.

/// The extension origin's scheme.
///
/// **NOT `chrome-extension`, and that is measured, not preference.**
/// `cef_scheme_registrar_t::add_custom_scheme("chrome-extension")`
/// returns **0** on CEF 151.3.16 (Arch `cef`, 2026-08-12): Chromium owns
/// the name, so a client may not register it — and CEF's alloy runtime
/// has the extensions component removed, so nothing else serves it
/// either. `cef_register_scheme_handler_factory` still answers 1 for it,
/// which is the trap: registration LOOKS fine and every load then fails
/// `ERR_BLOCKED_BY_CLIENT` with the factory never once consulted.
/// `SKETERM_WEB_SCHEME_DEBUG=1` prints both return values.
///
/// So the origin gets a name of our own, exactly as Firefox uses
/// `moz-extension://` rather than Chrome's. Extensions cope: they build
/// their urls with `runtime.getURL`. What does NOT cope is an extension
/// that hard-codes the literal `chrome-extension:` — a real limitation,
/// and the reason this constant is one place.
pub const ext_scheme = "sketerm-extension";

/// Set when `cef_register_scheme_handler_factory` accepted the scheme.
/// When it did not, background pages fall back to running their scraped
/// scripts inline (no modules), and `webextSchemeOk` says so out loud
/// rather than leaving a silent half-working extension host.
pub var ext_scheme_ok = false;

pub fn webextSchemeOk() bool {
    return ext_scheme_ok;
}

pub var scheme_factory: cef.cef_scheme_handler_factory_t = undefined;

/// The one-line `<script src>` spliced into every extension HTML
/// document we serve, ahead of every author script.
pub const bootstrap_tag = "<script src=\"" ++ extorigins.BOOTSTRAP_PATH ++ "\"></script>";

/// One in-flight `chrome-extension://` load.
///
/// REALLY refcounted, unlike the process-lifetime statics around it:
/// CEF owns the reference `create` returns and releases it when the load
/// ends, which is also this object's free. There is exactly one other
/// refcounted client-side struct in this file (`CookieJob`) and it
/// documents the same rule.
pub const ExtResource = struct {
    handler: cef.cef_resource_handler_t,
    refs: std.atomic.Value(u32),
    /// Response body, owned by `std.heap.c_allocator`. Empty for a 404.
    data: []u8 = &.{},
    offset: usize = 0,
    status: c_int = 200,
    mime: []const u8 = "text/plain",
    /// Non-zero: the response is a NET ERROR of this code and nothing
    /// else (`cef_response_t.set_error`); the rig's fault injector.
    err: c_int = 0,

    pub fn fromSelf(self: [*c]cef.cef_resource_handler_t) ?*ExtResource {
        if (self == null) return null;
        const p: *cef.cef_resource_handler_t = @ptrCast(self);
        return @fieldParentPtr("handler", p);
    }

    pub fn destroyOwned(self: *ExtResource) void {
        if (self.data.len != 0) std.heap.c_allocator.free(self.data);
        std.heap.c_allocator.destroy(self);
    }
};

pub const ExtResRef = HeapRef(ExtResource, "handler");

/// IO THREAD. Resolve one `chrome-extension://` url to bytes.
/// One refusal is reported per process (see the branches that set it).
pub var g_ext_refusal_logged = false;

pub fn extSchemeCreate(
    _: [*c]cef.cef_scheme_handler_factory_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    _: [*c]const cef.cef_string_t,
    request: [*c]cef.cef_request_t,
) callconv(.c) [*c]cef.cef_resource_handler_t {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    const req: *cef.cef_request_t = request orelse return null;
    const gu = req.get_url orelse return null;
    var url_buf: [2048]u8 = undefined;
    const url = userfreeInto(gu(req), &url_buf);
    if (url.len == 0) return null;

    const host = extassets.urlHost(url);
    if (!extassets.sameOrigin(url, ext_scheme, host)) return null;
    const dbg = c.getenv("SKETERM_WEB_SCHEME_DEBUG") != null;
    const slot = extorigins.lookup(host) orelse {
        if (dbg) std.debug.print("sketerm-web: scheme create: no origin for host \"{s}\" ({s})\n", .{ host, url });
        return null;
    };
    if (dbg) std.debug.print("sketerm-web: scheme create: {s}\n", .{url});

    // The web_accessible_resources gate. An extension's OWN documents
    // may read anything in their package; anybody else gets only what
    // the manifest published. The initiator is identified by the
    // requesting FRAME's url, which is the document doing the loading —
    // a referrer would be wrong here, since a referrer policy is free to
    // strip it and a stripped referrer must not silently open the gate.
    const path = extassets.urlPath(url);
    // NO FRAME means the load did not come from a document at all: a
    // WEB WORKER's script, a `cef_urlrequest`, a fetch from a worker
    // context. Such a load cannot be attributed, and refusing it is
    // wrong in a way that is very hard to see — uBlock Origin
    // (de)serializes its filter cache on a Worker, and a 403 on the
    // worker script left `serializeAsync` pending FOREVER: uBO's boot
    // stopped mid-sequence with no error anywhere, and it simply never
    // filtered. A page cannot mint such a load for another origin, so
    // treating it as the extension's own is both safe and necessary.
    // A NAVIGATION is the only load whose initiating frame legitimately
    // still reports the PREVIOUS document's url. Narrowing the `about:`
    // relaxation to it is what stops a hostile page creating an
    // about:blank iframe and `fetch()`ing any file in any installed
    // package — including the generated bootstrap, which carries the
    // bridge NONCE in plaintext and would defeat every nonce gate in
    // semantic.js.
    const rtype_raw = if (req.get_resource_type) |grt| grt(req) else cef.RT_SUB_RESOURCE;
    const is_navigation = rtype_raw == cef.RT_MAIN_FRAME or rtype_raw == cef.RT_SUB_FRAME;
    // Measured 2026-08-12 with this print: the generated background
    // document and an author's own `background.html` both arrive as
    // rtype 0 (RT_MAIN_FRAME) with a frame, and the bootstrap arrives
    // as rtype 3 (RT_SCRIPT) with the frame already at the extension
    // origin. That is what makes the split below safe.
    if (dbg) std.debug.print(
        "sketerm-web: ext gate path={s} rtype={d} frame={d}\n",
        .{ path, rtype_raw, @intFromBool(frame != null) },
    );

    // `strict` = the initiating document really IS this extension.
    // Tracked apart from `same_origin` because the relaxations below are
    // right for package FILES and wrong for the generated paths.
    var strict = false;
    var first_party_buf: [2048]u8 = undefined;
    const first_party = if (req.get_first_party_for_cookies) |get|
        userfreeInto(get(req), &first_party_buf)
    else
        "";
    var same_origin = frame == null;
    if (frame) |f| {
        if (f.*.get_url) |fu| {
            var fbuf: [2048]u8 = undefined;
            const furl = userfreeInto(fu(f), &fbuf);
            strict = extassets.sameOrigin(furl, ext_scheme, host);
            same_origin = strict;
            // A top-level navigation TO the extension page reports the
            // frame's previous url, so allow the document itself: this
            // is how the background page, the popup and the options page
            // load at all.
            if (!same_origin and is_navigation and
                (furl.len == 0 or std.mem.startsWith(u8, furl, "about:"))) same_origin = true;
        } else same_origin = true;
    }
    // CEF may expose the requesting frame's PREVIOUS url while parser-
    // blocking extension scripts are fetched. The request's first-party
    // url already names the committed top-level extension document, and
    // matching the exact target host keeps this strict: ordinary, blank,
    // data and another extension's origin still fail.
    if (!strict and extassets.sameOrigin(first_party, ext_scheme, host)) {
        strict = true;
        same_origin = true;
    }
    if (!same_origin) {
        var pats: [32][]const u8 = undefined;
        if (!extassets.webAccessible(slot.warPatterns(&pats), path)) {
            if (dbg) std.debug.print("sketerm-web: WAR 403 {s} (rtype={d})\n", .{ path, rtype_raw });
            return extResourceFor(&.{}, "text/plain", 403);
        }
    }

    // The reserved paths are GENERATED, never read from the package —
    // and they are checked before the file lookup so a package cannot
    // shadow either with a file of its own.
    if (std.mem.eql(u8, path, extorigins.BOOTSTRAP_PATH)) {
        // STRICT only. This body contains the bridge nonce, so it is the
        // one path where "close enough to same-origin" is not good
        // enough: it is always a `<script src>` from the extension's own
        // document, where the frame reports the extension origin. A
        // manifest publishing `"/*"` must not put it in reach either,
        // which is why this is checked AFTER the WAR gate.
        if (!strict) {
            // UNCONDITIONAL: this should never fire for a legitimate
            // load, and when it does the extension silently has no
            // `browser` at all — which reads as "the background page
            // never registered its listener" three layers away.
            // ONCE per process, not per request: this fires only for a
            // load that should never happen, but the whole premise of
            // the gate is that a HOSTILE page can trigger it at will,
            // and an unbounded stderr write on CEF's IO thread is a
            // free amplifier. One line still surfaces a real
            // misconfiguration.
            if (!g_ext_refusal_logged) {
                g_ext_refusal_logged = true;
                std.debug.print("sketerm-web: REFUSED bootstrap for {s} (rtype={d} frame={d})\n", .{ host, rtype_raw, @intFromBool(frame != null) });
            }
            return extResourceFor(&.{}, "text/plain", 403);
        }
        const js = buildExtBootstrap(&slot, host) orelse
            return extResourceFor("", "text/javascript", 500);
        return extResourceOwned(js, "text/javascript", 200);
    }
    if (std.mem.eql(u8, path, extorigins.GENERATED_BG_PATH)) {
        // The background DOCUMENT is fetched by a navigation, so it
        // cannot require `strict`; it must still never be a subresource
        // another origin can read.
        if (!strict and !is_navigation) {
            if (!g_ext_refusal_logged) {
                g_ext_refusal_logged = true;
                std.debug.print("sketerm-web: REFUSED generated bg for {s} (rtype={d} frame={d})\n", .{ host, rtype_raw, @intFromBool(frame != null) });
            }
            return extResourceFor(&.{}, "text/plain", 403);
        }
        const doc = buildGeneratedBackground(&slot) orelse
            return extResourceFor("", "text/html", 500);
        return extResourceOwned(doc, "text/html", 200);
    }

    var full_buf: [4096]u8 = undefined;
    const full = extassets.resolve(slot.dirSlice(), path, &full_buf) catch {
        return extResourceFor("", "text/plain", 404);
    };

    const bytes = readFileC(full, webext_max_asset) orelse
        return extResourceFor("", "text/plain", 404);
    const mime = extassets.mimeFor(full);

    // An extension HTML document gets the bootstrap `<script src>`
    // spliced in ahead of every author script; that script is what
    // defines `browser`/`chrome` before the document's first statement
    // uses one.
    if (std.mem.eql(u8, mime, "text/html")) {
        if (spliceBootstrapTag(bytes)) |s| {
            std.heap.c_allocator.free(bytes);
            return extResourceOwned(s, mime, 200);
        }
    }
    return extResourceOwned(bytes, mime, 200);
}

/// Read a whole file into a `c_allocator` buffer. IO-thread safe.
pub fn readFileC(path: []const u8, max: usize) ?[]u8 {
    var zbuf: [4200]u8 = undefined;
    if (path.len + 1 > zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&zbuf), c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return null;
    // A directory opens fine and then reads nothing; refuse it here so
    // `chrome-extension://host/js` is a 404 rather than an empty 200.
    if (st.st_mode & c.S_IFMT != c.S_IFREG) return null;
    const size: usize = @intCast(@max(st.st_size, 0));
    if (size > max) return null;
    if (size == 0) return std.heap.c_allocator.alloc(u8, 0) catch null;
    const buf = std.heap.c_allocator.alloc(u8, size) catch return null;
    var got: usize = 0;
    while (got < size) {
        const n = c.read(fd, buf.ptr + got, size - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != size) {
        std.heap.c_allocator.free(buf);
        return null;
    }
    return buf;
}

/// Splice the bootstrap `<script src>` into an HTML document. Returns a
/// new `c_allocator` buffer, or null when it could not be built (the
/// original is then served unchanged).
pub fn spliceBootstrapTag(html: []const u8) ?[]u8 {
    const off = @min(bgpage.bootstrapOffset(html), html.len);
    const out = std.heap.c_allocator.alloc(u8, html.len + bootstrap_tag.len) catch return null;
    @memcpy(out[0..off], html[0..off]);
    @memcpy(out[off..][0..bootstrap_tag.len], bootstrap_tag);
    @memcpy(out[off + bootstrap_tag.len ..], html[off..]);
    return out;
}

/// IO THREAD. The document a `background.scripts` extension gets: the
/// bootstrap followed by one classic `<script src>` per declared script,
/// in manifest order (MV2's own ordering).
pub fn buildGeneratedBackground(slot: *const extorigins.Lookup) ?[]u8 {
    return buildGeneratedBackgroundAlloc(slot) catch null;
}

/// Error-returning so the `errdefer` runs; as a `?[]u8` body every
/// write failure leaked the document built so far.
pub fn buildGeneratedBackgroundAlloc(slot: *const extorigins.Lookup) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const mpath = try std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{slot.dirSlice()});
    const bytes = readFileC(mpath, webext_max_asset) orelse return error.ManifestUnreadable;
    defer std.heap.c_allocator.free(bytes);
    var man = try extmanifest.parse(std.heap.c_allocator, bytes);
    defer man.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><title>background</title>");
    try w.writeAll(bootstrap_tag);
    if (man.background) |bg| {
        for (bg.scripts) |rel| {
            const clean = std.mem.trimStart(u8, rel, "/");
            // The path goes into an HTML attribute; anything that could
            // close it out is refused rather than escaped, because a
            // manifest naming such a file is broken either way.
            if (std.mem.indexOfAny(u8, clean, "\"'<>") != null) continue;
            try w.writeAll("<script src=\"/");
            try w.writeAll(clean);
            try w.writeAll("\"></script>");
        }
    }
    try w.writeAll("</head><body></body></html>");
    return out.toOwnedSlice();
}

/// IO THREAD. Build the extension API bootstrap script.
///
/// It calls the semantic bridge's own command entry point, which
/// `on_context_created` has already installed on this frame, so
/// `browser` exists SYNCHRONOUSLY before the document's first author
/// statement. A command sent the usual way — `execute_java_script` from
/// the browser process — would race that statement and lose.
///
/// Every input is a file on disk or a process-global secret; nothing
/// here reads main-thread state.
pub fn buildExtBootstrap(slot: *const extorigins.Lookup, host: []const u8) ?[]u8 {
    if (!host_mod.sem_secret.ok) return null;
    return buildExtBootstrapAlloc(slot, host) catch null;
}

/// Error-returning so the `errdefer` runs; as a `?[]u8` body each of
/// the twenty-odd `catch return null` paths leaked the script so far.
pub fn buildExtBootstrapAlloc(slot: *const extorigins.Lookup, host: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    errdefer out.deinit();
    const w = &out.writer;

    var path_buf: [4096]u8 = undefined;
    const mpath = try std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{slot.dirSlice()});
    const man_bytes = readFileC(mpath, webext_max_asset);
    defer if (man_bytes) |b| std.heap.c_allocator.free(b);

    var msg_bytes: ?[]u8 = null;
    defer if (msg_bytes) |b| std.heap.c_allocator.free(b);
    if (slot.locale_len != 0) {
        var lbuf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&lbuf, "{s}/_locales/{s}/messages.json", .{
            slot.dirSlice(), slot.localeSlice(),
        })) |lpath| {
            msg_bytes = readFileC(lpath, webext_max_asset);
        } else |_| {}
    }

    try w.writeAll("(function(){try{var f=window[\"");
    try w.writeAll(&host_mod.sem_secret.slot);
    try w.writeAll("\"];if(!f)return;f(JSON.stringify({op:\"ext-inject\",tok:\"");
    try w.writeAll(&host_mod.sem_secret.nonce);
    try w.writeAll("\",priv:true,");
    if (c.getenv("SKETERM_WEB_EXT_DEBUG") != null) try w.writeAll("dbg:true,");
    try w.writeAll("ext:");
    try jsonStr(w, slot.idSlice());
    try w.writeAll(",cap:");
    try jsonStr(w, &slot.capability);
    try w.writeAll(",base:");
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ext_scheme ++ "://{s}/", .{host});
    try jsonStr(w, base);
    try w.writeAll(",manifest:");
    try w.writeAll(if (man_bytes) |b| b else "{}");
    try w.writeAll(",messages:");
    try w.writeAll(if (msg_bytes) |b| b else "null");
    // A bootstrap that fails silently is an extension that is enabled,
    // loads, and does nothing at all — the exact failure mode this whole
    // area kept producing. Say so instead.
    try w.writeAll(",scripts:[],css:[]}));}catch(e){try{console.error(" ++
        "'[sketerm-webext] API bootstrap failed: '+(e&&e.stack||e));}catch(e2){}}})()");
    return out.toOwnedSlice();
}

pub fn extResourceFor(data: []const u8, mime: []const u8, status: c_int) [*c]cef.cef_resource_handler_t {
    const copy = std.heap.c_allocator.dupe(u8, data) catch return null;
    return extResourceOwned(copy, mime, status);
}

/// Wrap an owned buffer as a resource handler. Takes ownership of
/// `data` on success AND on failure (nothing is leaked either way).
pub fn extResourceOwned(data: []u8, mime: []const u8, status: c_int) [*c]cef.cef_resource_handler_t {
    const r = std.heap.c_allocator.create(ExtResource) catch {
        std.heap.c_allocator.free(data);
        return null;
    };
    r.* = .{
        .handler = std.mem.zeroes(cef.cef_resource_handler_t),
        .refs = .init(1),
        .data = data,
        .status = status,
        .mime = mime,
    };
    r.handler.base = ExtResRef.base();
    r.handler.open = extResOpen;
    r.handler.get_response_headers = extResHeaders;
    r.handler.read = extResRead;
    r.handler.cancel = extResCancel;
    return &r.handler;
}

pub fn extResOpen(
    self: [*c]cef.cef_resource_handler_t,
    request: [*c]cef.cef_request_t,
    handle_request: [*c]c_int,
    callback: [*c]cef.cef_callback_t,
) callconv(.c) c_int {
    releaseArg(request);
    releaseArg(callback);
    _ = ExtResource.fromSelf(self) orelse return 0;
    // The bytes are already in hand, so this is the synchronous form:
    // handled immediately, no callback, no second thread.
    if (handle_request) |hr| hr.* = 1;
    return 1;
}

pub fn extResHeaders(
    self: [*c]cef.cef_resource_handler_t,
    response: [*c]cef.cef_response_t,
    response_length: [*c]i64,
    _: [*c]cef.cef_string_t,
) callconv(.c) void {
    defer releaseArg(response);
    const r = ExtResource.fromSelf(self) orelse return;
    const resp: *cef.cef_response_t = response orelse return;
    if (r.err != 0) {
        // A net error at header time fails the load with exactly that
        // code, through the same navigation path a real one takes.
        if (resp.set_error) |se| se(resp, r.err);
        if (response_length) |rl| rl.* = 0;
        return;
    }
    if (resp.set_status) |ss| ss(resp, r.status);
    var mime = std.mem.zeroes(cef.cef_string_t);
    setStr(r.mime, &mime);
    defer cef.cef_string_utf16_clear(&mime);
    if (resp.set_mime_type) |sm| sm(resp, &mime);
    // Text formats are UTF-8; without saying so, a non-ASCII message
    // catalogue or a UTF-8 source file is decoded as Latin-1.
    if (std.mem.startsWith(u8, r.mime, "text/") or
        std.mem.eql(u8, r.mime, "application/json"))
    {
        var cs = std.mem.zeroes(cef.cef_string_t);
        setStr("utf-8", &cs);
        defer cef.cef_string_utf16_clear(&cs);
        if (resp.set_charset) |sc| sc(resp, &cs);
    }
    setResponseHeader(resp, "Access-Control-Allow-Origin", "*");
    if (response_length) |rl| rl.* = @intCast(r.data.len);
}

pub fn setResponseHeader(resp: *cef.cef_response_t, name: []const u8, value: []const u8) void {
    const set = resp.set_header_by_name orelse return;
    var n = std.mem.zeroes(cef.cef_string_t);
    setStr(name, &n);
    defer cef.cef_string_utf16_clear(&n);
    var v = std.mem.zeroes(cef.cef_string_t);
    setStr(value, &v);
    defer cef.cef_string_utf16_clear(&v);
    set(resp, &n, &v, 1);
}

pub fn extResRead(
    self: [*c]cef.cef_resource_handler_t,
    data_out: ?*anyopaque,
    bytes_to_read: c_int,
    bytes_read: [*c]c_int,
    callback: [*c]cef.cef_resource_read_callback_t,
) callconv(.c) c_int {
    releaseArg(callback);
    const r = ExtResource.fromSelf(self) orelse return 0;
    if (bytes_read) |br| br.* = 0;
    if (r.offset >= r.data.len) return 0;
    const want: usize = @intCast(@max(bytes_to_read, 0));
    const n = @min(want, r.data.len - r.offset);
    if (n == 0) return 0;
    const dst: [*]u8 = @ptrCast(data_out orelse return 0);
    @memcpy(dst[0..n], r.data[r.offset..][0..n]);
    r.offset += n;
    if (bytes_read) |br| br.* = @intCast(n);
    return 1;
}

pub fn extResCancel(_: [*c]cef.cef_resource_handler_t) callconv(.c) void {}
