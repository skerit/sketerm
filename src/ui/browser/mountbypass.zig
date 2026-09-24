//! The GTK side of the mount bypass (rules: filebrowser/bypass.zig).
//!
//! A navigation to a local path under an sshfs/NFS mount lands on the
//! mount FIRST, exactly as any local path does; a probe then dials the
//! mount's source host, stats the path through both daemons and, only
//! when the two views agree, reroutes the tab to the host's own copy
//! with a "via sketerm" badge. An ambiguous host string asks once and
//! remembers; an unreachable host or a mismatch leaves the tab on the
//! mount, and a host that dies later puts a rerouted tab back on it.

const std = @import("std");
const c = @import("../../c.zig").c;

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const BypassLink = @import("types.zig").BypassLink;
const HostConn = @import("types.zig").HostConn;
const WireReply = @import("types.zig").WireReply;
const bypass = @import("../../filebrowser/bypass.zig");
const confirm = @import("../confirm.zig");
const mounts = @import("../../util/mounts.zig");
const hostEq = @import("../../filebrowser/paths.zig").hostEq;
const cast = @import("../../util/cast.zig");

/// A mount whose identity check passed: later navigations under it
/// reroute at once instead of probing again.
pub const Verified = struct {
    mountpoint: []u8,
    root: []u8,
    host: []u8,

    fn destroy(self: *Verified, allocator: std.mem.Allocator) void {
        allocator.free(self.mountpoint);
        allocator.free(self.root);
        allocator.free(self.host);
    }
};

/// One side's answer, owned (the reply arena dies with the frame).
const Side = struct {
    req: u32 = 0,
    kind_buf: [8]u8 = undefined,
    kind_len: usize = 0,
    size: u64 = 0,
    mtime_ms: i64 = 0,
    have: bool = false,

    fn set(self: *Side, kind: []const u8, size: u64, mtime_ms: i64) void {
        self.kind_len = @min(kind.len, self.kind_buf.len);
        @memcpy(self.kind_buf[0..self.kind_len], kind[0..self.kind_len]);
        self.size = size;
        self.mtime_ms = mtime_ms;
        self.have = true;
    }

    fn identity(self: *const Side) bypass.Identity {
        return .{ .kind = self.kind_buf[0..self.kind_len], .size = self.size, .mtime_ms = self.mtime_ms };
    }
};

/// One in-flight identity check for one tab.
pub const Probe = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    /// The tab's navigation generation at start: a later navigation
    /// makes the answer moot.
    generation: u64,
    mountpoint: []u8,
    root: []u8,
    source: []u8,
    local_path: []u8,
    remote_path: []u8,
    host: ?[]u8 = null,
    hc: ?*HostConn = null,
    local: Side = .{},
    remote: Side = .{},

    fn destroy(self: *Probe) void {
        const a = self.allocator;
        a.free(self.mountpoint);
        a.free(self.root);
        a.free(self.source);
        a.free(self.local_path);
        a.free(self.remote_path);
        if (self.host) |h| a.free(h);
        a.destroy(self);
    }
};

/// The host a mount already proved itself for, if any.
pub fn verifiedFor(self: *BrowserView, mountpoint: []const u8) ?*const Verified {
    for (self.bypass_verified.items) |*v| {
        if (std.mem.eql(u8, v.mountpoint, mountpoint)) return v;
    }
    return null;
}

/// Mark `tab` as browsing `mountpoint` through `host` (the badge and
/// the fallback read this).
pub fn linkTab(self: *BrowserView, tab: *BTab, mountpoint: []const u8, root: []const u8, host: []const u8) void {
    const a = self.allocator;
    if (tab.bypass) |*old| old.destroy(a);
    tab.bypass = null;
    const mp = a.dupe(u8, mountpoint) catch return;
    const rt = a.dupe(u8, root) catch {
        a.free(mp);
        return;
    };
    const h = a.dupe(u8, host) catch {
        a.free(mp);
        a.free(rt);
        return;
    };
    tab.bypass = .{ .mountpoint = mp, .root = rt, .host = h };
}

/// A new LOCAL tab whose first listing is already on its way: a
/// proven mount reroutes it at once, any other mount starts the probe.
pub fn onTabOpened(self: *BrowserView, tab: *BTab) void {
    var hit: mounts.Hit = .{};
    if (!mounts.detect(tab.root.path, &hit)) return;
    if (verifiedFor(self, hit.mountpoint())) |v| {
        linkTab(self, tab, v.mountpoint, v.root, v.host);
        self.setStatusFmt("via sketerm: {s} (bypassed mount {s})", .{ v.host, hit.mountpoint() });
        self.navigateMode(tab, v.host, hit.path(), .reroute);
        return;
    }
    begin(self, tab, &hit, tab.root.path);
}

/// A committed navigation: drop the link once the tab has left the
/// export it was rerouted into.
pub fn onNavigated(self: *BrowserView, tab: *BTab, host: ?[]const u8, path: []const u8) void {
    const link = &(tab.bypass orelse return);
    if (bypass.within(host, path, link.host, link.root)) return;
    link.destroy(self.allocator);
    tab.bypass = null;
}

fn dropProbe(self: *BrowserView, probe: *Probe) void {
    for (self.bypass_probes.items, 0..) |p, i| {
        if (p == probe) {
            _ = self.bypass_probes.orderedRemove(i);
            break;
        }
    }
    probe.destroy();
}

fn dropProbesFor(self: *BrowserView, tab: *BTab) void {
    var i: usize = 0;
    while (i < self.bypass_probes.items.len) {
        const p = self.bypass_probes.items[i];
        if (p.tab == tab) {
            _ = self.bypass_probes.orderedRemove(i);
            p.destroy();
        } else i += 1;
    }
}

pub fn deinit(self: *BrowserView) void {
    for (self.bypass_probes.items) |p| p.destroy();
    self.bypass_probes.deinit(self.allocator);
    for (self.bypass_verified.items) |*v| v.destroy(self.allocator);
    self.bypass_verified.deinit(self.allocator);
}

fn rememberedHost(self: *BrowserView, source: []const u8) ?[]const u8 {
    for (self.mount_aliases.items) |alias| {
        if (std.mem.eql(u8, alias.source, source)) return alias.host;
    }
    return null;
}

/// Every host string this browser already reaches: connections that
/// are not dead, and the tabs' hosts.
fn knownHosts(self: *BrowserView, out: *[32][]const u8) []const []const u8 {
    var n: usize = 0;
    for (self.conns.items) |hc| {
        if (hc.state == .dead) continue;
        const h = hc.host orelse continue;
        if (n == out.len) break;
        out[n] = h;
        n += 1;
    }
    for (self.tabs.items) |tab| {
        const h = tab.hc.host orelse continue;
        if (n == out.len) break;
        out[n] = h;
        n += 1;
    }
    return out[0..n];
}

/// Start the identity check for a tab that just navigated to
/// `local_path` under the mount `hit` describes.
pub fn begin(self: *BrowserView, tab: *BTab, hit: *const mounts.Hit, local_path: []const u8) void {
    dropProbesFor(self, tab);
    const a = self.allocator;
    const probe = a.create(Probe) catch return;
    probe.* = .{
        .allocator = a,
        .view = self,
        .tab = tab,
        .generation = tab.navigation_generation,
        .mountpoint = a.dupe(u8, hit.mountpoint()) catch {
            a.destroy(probe);
            return;
        },
        .root = undefined,
        .source = undefined,
        .local_path = undefined,
        .remote_path = undefined,
    };
    probe.root = a.dupe(u8, hit.root()) catch {
        a.free(probe.mountpoint);
        a.destroy(probe);
        return;
    };
    probe.source = a.dupe(u8, hit.host()) catch {
        a.free(probe.mountpoint);
        a.free(probe.root);
        a.destroy(probe);
        return;
    };
    probe.local_path = a.dupe(u8, local_path) catch {
        a.free(probe.mountpoint);
        a.free(probe.root);
        a.free(probe.source);
        a.destroy(probe);
        return;
    };
    probe.remote_path = a.dupe(u8, hit.path()) catch {
        a.free(probe.mountpoint);
        a.free(probe.root);
        a.free(probe.source);
        a.free(probe.local_path);
        a.destroy(probe);
        return;
    };
    self.bypass_probes.append(a, probe) catch {
        probe.destroy();
        return;
    };
    var known_buf: [32][]const u8 = undefined;
    var cands: [bypass.MAX_CANDIDATES][]const u8 = undefined;
    switch (bypass.resolve(probe.source, knownHosts(self, &known_buf), rememberedHost(self, probe.source), &cands)) {
        .host => |h| proceed(self, probe, h),
        .ambiguous => |list| askHost(self, probe, list),
    }
}

/// The answer to an ambiguous mount source, carried through the
/// dialog. The probe is re-found in the view's list by pointer, never
/// dereferenced blindly: a navigation can drop it while the dialog is up.
const Ask = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    probe: *Probe,
    remember: *c.GtkWidget,
    hosts: [bypass.MAX_CANDIDATES][]u8,
    count: usize,

    fn destroy(self: *Ask) void {
        for (self.hosts[0..self.count]) |h| self.allocator.free(h);
        self.allocator.destroy(self);
    }
};

fn probeLive(self: *BrowserView, probe: *Probe) bool {
    for (self.bypass_probes.items) |p| if (p == probe) return true;
    return false;
}

fn askHost(self: *BrowserView, probe: *Probe, candidates: []const []const u8) void {
    const a = self.allocator;
    const ask = a.create(Ask) catch return dropProbe(self, probe);
    ask.* = .{ .allocator = a, .view = self, .probe = probe, .remember = undefined, .hosts = undefined, .count = 0 };
    for (candidates) |h| {
        ask.hosts[ask.count] = a.dupe(u8, h) catch break;
        ask.count += 1;
    }
    if (ask.count == 0) {
        ask.destroy();
        return dropProbe(self, probe);
    }
    var responses: [bypass.MAX_CANDIDATES + 1]confirm.Response = undefined;
    var ids: [bypass.MAX_CANDIDATES][4:0]u8 = undefined;
    var labels: [bypass.MAX_CANDIDATES][300:0]u8 = undefined;
    responses[0] = .{ .id = "cancel", .label = "Keep the mount", .is_default = true, .is_close = true };
    for (ask.hosts[0..ask.count], 0..) |h, i| {
        _ = std.fmt.bufPrintZ(&ids[i], "{d}", .{i}) catch unreachable;
        _ = std.fmt.bufPrintZ(&labels[i], "{s}", .{h}) catch {
            labels[i][0] = 0;
        };
        responses[i + 1] = .{ .id = &ids[i], .label = &labels[i] };
    }
    var head: [300:0]u8 = undefined;
    const heading = std.fmt.bufPrintZ(&head, "Browse {s} through which host?", .{probe.source}) catch "Browse the mount through which host?";
    const remember = c.gtk_check_button_new_with_label("Remember for this mount");
    ask.remember = remember;
    const root = c.gtk_widget_get_root(self.root_box);
    if (confirm.present(@ptrCast(@alignCast(root)), .{
        .heading = heading.ptr,
        .body = "More than one known host names the machine this mount comes from. The listing keeps working from the mount meanwhile.",
        .responses = responses[0 .. ask.count + 1],
        .extra_child = remember,
    }, .{ .allocator = a, .cb = &onHostChosen, .ctx = @ptrCast(ask) }) == null) {
        ask.destroy();
        dropProbe(self, probe);
    }
}

fn onHostChosen(user: ?*anyopaque, resp: []const u8) void {
    const ask = cast.userData(Ask, user);
    defer ask.destroy();
    const self = ask.view;
    if (self.widgets_dead or !probeLive(self, ask.probe)) return;
    const probe = ask.probe;
    const index = std.fmt.parseInt(usize, resp, 10) catch return dropProbe(self, probe);
    if (index >= ask.count) return dropProbe(self, probe);
    const host = ask.hosts[index];
    if (c.gtk_check_button_get_active(@ptrCast(ask.remember)) != 0) rememberAlias(self, probe.source, host);
    proceed(self, probe, host);
}

fn rememberAlias(self: *BrowserView, source: []const u8, host: []const u8) void {
    const a = self.allocator;
    for (self.mount_aliases.items) |*alias| {
        if (!std.mem.eql(u8, alias.source, source)) continue;
        const fresh = a.dupe(u8, host) catch return;
        a.free(alias.host);
        alias.host = fresh;
        _ = self.savePlaces();
        return;
    }
    const src = a.dupe(u8, source) catch return;
    const h = a.dupe(u8, host) catch {
        a.free(src);
        return;
    };
    self.mount_aliases.append(a, .{ .source = src, .host = h }) catch {
        a.free(src);
        a.free(h);
        return;
    };
    _ = self.savePlaces();
}

/// The host is decided: dial it (a connection may already exist) and
/// stat both sides as soon as both daemons answer.
fn proceed(self: *BrowserView, probe: *Probe, host: []const u8) void {
    probe.host = self.allocator.dupe(u8, host) catch return dropProbe(self, probe);
    probe.hc = self.hostConnFor(host) orelse return dropProbe(self, probe);
    sendStats(self, probe);
}

fn sendStats(self: *BrowserView, probe: *Probe) void {
    const hc = probe.hc orelse return;
    const local = self.hostConnFor(null) orelse return dropProbe(self, probe);
    if (hc.state == .dead or local.state == .dead) return dropProbe(self, probe);
    if (hc.state != .ready or local.state != .ready) return; // hostReady continues
    if (probe.local.req != 0 or probe.remote.req != 0) return;
    probe.local.req = self.nextReq();
    self.sendOp(local, .{ .req = probe.local.req, .op = "stat", .path = probe.local_path });
    probe.remote.req = self.nextReq();
    self.sendOp(hc, .{ .req = probe.remote.req, .op = "stat", .path = probe.remote_path });
}

/// A connection became ready: probes waiting on it send their stats.
pub fn hostReady(self: *BrowserView, hc: *HostConn) void {
    var i: usize = 0;
    while (i < self.bypass_probes.items.len) : (i += 1) {
        const probe = self.bypass_probes.items[i];
        if (probe.hc == hc or hostEq(hc.host, null)) sendStats(self, probe);
    }
}

/// A connection died: its probes give up (the mount keeps serving),
/// and tabs rerouted through it go back to the mount path.
pub fn hostDied(self: *BrowserView, hc: *HostConn) void {
    var i: usize = 0;
    while (i < self.bypass_probes.items.len) {
        const probe = self.bypass_probes.items[i];
        if (probe.hc == hc) {
            self.setStatusFmt("{s} is unreachable; staying on the mount {s}", .{ hc.label(), probe.mountpoint });
            _ = self.bypass_probes.orderedRemove(i);
            probe.destroy();
        } else i += 1;
    }
    var k: usize = 0;
    while (k < self.bypass_verified.items.len) {
        if (std.mem.eql(u8, self.bypass_verified.items[k].host, hc.host orelse "")) {
            var gone = self.bypass_verified.orderedRemove(k);
            gone.destroy(self.allocator);
        } else k += 1;
    }
    for (self.tabs.items) |tab| {
        if (tab.hc != hc) continue;
        const link = tab.bypass orelse continue;
        var buf: [4096]u8 = undefined;
        const local = bypass.mountPath(&buf, link.mountpoint, link.root, tab.root.path) orelse continue;
        self.setStatusFmt("{s} is unreachable; back on the mount {s}", .{ hc.label(), link.mountpoint });
        self.navigateMode(tab, null, local, .reroute);
    }
}

/// A stat reply: ours when it answers one side of a probe.
/// @return true when consumed.
pub fn feed(self: *BrowserView, hc: *HostConn, rep: WireReply) bool {
    for (self.bypass_probes.items) |probe| {
        const side: *Side = if (probe.remote.req != 0 and rep.req == probe.remote.req and probe.hc == hc)
            &probe.remote
        else if (probe.local.req != 0 and rep.req == probe.local.req and hc.host == null)
            &probe.local
        else
            continue;
        if (!rep.ok or rep.entry == null) {
            self.setStatusFmt("mount {s} stays local: {s} could not stat it", .{ probe.mountpoint, hc.label() });
            dropProbe(self, probe);
            return true;
        }
        const e = rep.entry.?;
        side.set(e.kind, e.size, e.mtime_ms);
        if (probe.local.have and probe.remote.have) settle(self, probe);
        return true;
    }
    return false;
}

fn settle(self: *BrowserView, probe: *Probe) void {
    defer dropProbe(self, probe);
    const tab = probe.tab;
    const host = probe.host orelse return;
    if (!bypass.sameFile(probe.local.identity(), probe.remote.identity())) {
        self.setStatusFmt("mount {s} stays local: {s} shows different files at {s}", .{ probe.mountpoint, host, probe.remote_path });
        return;
    }
    rememberVerified(self, probe.mountpoint, probe.root, host);
    // The tab may have moved on while the two daemons answered.
    if (!self.tabAlive(tab) or tab.navigation_generation != probe.generation) return;
    if (tab.hc.host != null or !std.mem.eql(u8, tab.root.path, probe.local_path)) return;
    linkTab(self, tab, probe.mountpoint, probe.root, host);
    self.setStatusFmt("via sketerm: {s} (bypassed mount {s})", .{ host, probe.mountpoint });
    self.navigateMode(tab, host, probe.remote_path, .reroute);
}

fn rememberVerified(self: *BrowserView, mountpoint: []const u8, root: []const u8, host: []const u8) void {
    if (verifiedFor(self, mountpoint) != null) return;
    const a = self.allocator;
    const mp = a.dupe(u8, mountpoint) catch return;
    const rt = a.dupe(u8, root) catch {
        a.free(mp);
        return;
    };
    const h = a.dupe(u8, host) catch {
        a.free(mp);
        a.free(rt);
        return;
    };
    self.bypass_verified.append(a, .{ .mountpoint = mp, .root = rt, .host = h }) catch {
        a.free(mp);
        a.free(rt);
        a.free(h);
    };
}
