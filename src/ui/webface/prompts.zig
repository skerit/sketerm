//! Held security decisions, the face half: the TLS interstitial and the
//! permission banner (see "Security surfaces" in `webface.zig`'s header).
//! Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const navfault = @import("../../web/navfault.zig");
const proto = @import("../../web/protocol.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;
const permissionLabel = host_mod.permissionLabel;

/// One permission prompt the helper is holding, as the banner shows it.
/// `origin` is owned by the face.
pub const PermPrompt = struct {
    prompt: u64,
    origin: []u8,
    types: u32,
};

/// A remembered Allow/Block for one origin and one exact permission
/// set. Matching is on the exact bits: a page that later asks for
/// camera alone has not been answered by a camera+microphone decision.
pub const SiteSetting = struct {
    origin: []u8,
    types: u32,
    allow: bool,
};

// ---- TLS interstitial -------------------------------------------

/// The helper is HOLDING a request whose certificate failed. Until
/// `certDecide` answers, the page is neither loaded nor failed.
pub fn onCertError(self: *WebFace, ev: proto.EvCertError) void {
    self.cert_pending = true;
    self.cert_cancelled = false;
    if (self.cert_rec) |*old| old.free(self.allocator);
    self.cert_rec = navfault.CertRec.init(self.allocator, ev, .pending) catch null;
    if (self.widgets_dead) return;
    // The generic status overlay would otherwise sit on top of the
    // interstitial saying the same thing in weaker words.
    self.clearStatus();

    var buf: [512]u8 = undefined;
    const named = if (ev.host.len != 0) ev.host else ev.url;
    const title = std.fmt.bufPrintZ(
        &buf,
        "sketerm cannot verify that this is {s}. Someone may be impersonating it to steal what you type.",
        .{named},
    ) catch "This site's certificate could not be verified.";
    c.gtk_label_set_text(@ptrCast(self.cert_title), title.ptr);

    var dbuf: [1024]u8 = undefined;
    const detail = std.fmt.bufPrintZ(&dbuf, "{s} ({d})\nIssued to: {s}\nIssued by: {s}\nSHA-256: {s}", .{
        ev.msg,
        ev.code,
        if (ev.subject.len != 0) ev.subject else "(unknown)",
        if (ev.issuer.len != 0) ev.issuer else "(unknown)",
        if (ev.fingerprint.len != 0) ev.fingerprint else "(unavailable)",
    }) catch "";
    c.gtk_label_set_text(@ptrCast(self.cert_detail), detail.ptr);
    c.gtk_widget_set_visible(self.cert_box, 1);
}

/// Answer the held request. `proceed` accepts the certificate for
/// THIS request only: nothing is remembered, here or helper-side.
pub fn certDecide(self: *WebFace, proceed: bool) void {
    if (!self.cert_pending) return;
    self.cert_pending = false;
    self.cert_cancelled = !proceed;
    if (self.cert_rec) |*rec| rec.verdict = if (proceed) .accepted else .refused;
    // A helper without the capability never sent the event, so it
    // can only be a decision for a request nobody holds.
    if (self.cl.has(.tls)) self.cl.post(proto.CertDecision{
        .view = self.view,
        .proceed = if (proceed) 1 else 0,
    });
    if (!self.widgets_dead) c.gtk_widget_set_visible(self.cert_box, 0);
    if (proceed) {
        // The padlock must stop claiming a verified identity the
        // moment the user overrode the verification.
        self.cert_exception = true;
        self.updateSiteButton();
        return;
    }
    // "Back to safety" means LEAVING, not sitting on a cancelled
    // request: back where there is history, a blank page where the
    // bad site was the first thing this tab ever opened.
    if (self.can_back) {
        self.navAction(.back);
    } else {
        self.cl.post(proto.Navigate{ .view = self.view, .url = "about:blank" });
    }
}

pub fn onCertBack(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    cast.userData(WebFace, user).certDecide(false);
}

pub fn onCertProceed(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    cast.userData(WebFace, user).certDecide(true);
}

// ---- permission prompts -----------------------------------------

/// A page asked for a permission and the helper is holding it.
/// A remembered answer for the same (origin, permission set) is
/// applied at once and nothing is shown.
pub fn onPermission(self: *WebFace, ev: proto.EvPermission) void {
    if (self.rememberedSetting(ev.origin, ev.types)) |allow| {
        self.postPermission(ev.prompt, allow);
        return;
    }
    const origin = self.allocator.dupe(u8, ev.origin) catch return;
    self.perm_queue.append(self.allocator, .{
        .prompt = ev.prompt,
        .origin = origin,
        .types = ev.types,
    }) catch {
        self.allocator.free(origin);
        // Nobody can answer a prompt that was not queued, so answer
        // it now rather than leaving the page waiting forever.
        self.postPermission(ev.prompt, false);
        return;
    };
    self.showPermPrompt();
}

pub fn postPermission(self: *WebFace, prompt: u64, allow: bool) void {
    if (!self.cl.has(.permissions)) return;
    self.cl.post(proto.PermissionDecision{
        .view = self.view,
        .prompt = prompt,
        .allow = if (allow) 1 else 0,
    });
}

pub fn rememberedSetting(self: *WebFace, origin: []const u8, types: u32) ?bool {
    for (self.site_settings.items) |s| {
        if (s.types == types and std.mem.eql(u8, s.origin, origin)) return s.allow;
    }
    return null;
}

pub fn rememberSetting(self: *WebFace, origin: []const u8, types: u32, allow: bool) void {
    for (self.site_settings.items) |*s| {
        if (s.types == types and std.mem.eql(u8, s.origin, origin)) {
            s.allow = allow;
            break;
        }
    } else {
        const owned = self.allocator.dupe(u8, origin) catch return;
        self.site_settings.append(self.allocator, .{
            .origin = owned,
            .types = types,
            .allow = allow,
        }) catch {
            self.allocator.free(owned);
            return;
        };
    }
    if (!self.isPrivate()) {
        if (host_mod.g_site_setting_sink) |sink| sink(origin, types, allow);
    }
}

/// Show the head of the queue, or hide the banner when it is empty.
pub fn showPermPrompt(self: *WebFace) void {
    if (self.widgets_dead) return;
    if (self.perm_queue.items.len == 0) {
        c.gtk_widget_set_visible(self.perm_bar, 0);
        return;
    }
    const p = self.perm_queue.items[0];
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "{s} wants to use {s}", .{
        if (p.origin.len != 0) p.origin else "This page",
        permissionLabel(p.types),
    }) catch "This page wants a permission";
    c.gtk_label_set_text(@ptrCast(self.perm_label), text.ptr);
    c.gtk_widget_set_visible(self.perm_bar, 1);
}

pub fn answerPermission(self: *WebFace, allow: bool) void {
    if (self.perm_queue.items.len == 0) {
        if (!self.widgets_dead) c.gtk_widget_set_visible(self.perm_bar, 0);
        return;
    }
    const p = self.perm_queue.orderedRemove(0);
    defer self.allocator.free(p.origin);
    self.postPermission(p.prompt, allow);
    if (p.origin.len != 0) self.rememberSetting(p.origin, p.types, allow);
    // Anything else already answered by the same decision goes with
    // it, so one Allow does not produce four identical banners.
    var i: usize = 0;
    while (i < self.perm_queue.items.len) {
        const q = self.perm_queue.items[i];
        if (q.types == p.types and std.mem.eql(u8, q.origin, p.origin)) {
            _ = self.perm_queue.orderedRemove(i);
            self.postPermission(q.prompt, allow);
            self.allocator.free(q.origin);
            continue;
        }
        i += 1;
    }
    self.showPermPrompt();
}

/// Drop every held prompt without answering: the engine dismisses
/// its own prompts across a navigation, so the callbacks are gone.
pub fn clearPermPrompts(self: *WebFace) void {
    for (self.perm_queue.items) |p| self.allocator.free(p.origin);
    self.perm_queue.clearRetainingCapacity();
    if (!self.widgets_dead) c.gtk_widget_set_visible(self.perm_bar, 0);
}

pub fn onPermAllow(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    cast.userData(WebFace, user).answerPermission(true);
}

pub fn onPermBlock(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    cast.userData(WebFace, user).answerPermission(false);
}
