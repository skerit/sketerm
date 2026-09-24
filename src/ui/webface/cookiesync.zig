//! Cookie synchronisation across route instances (protocol 0xE0 block),
//! the GUI half, split out of `webface.zig`.

const std = @import("std");
const proto = @import("../../web/protocol.zig");
const host_mod = @import("../webface.zig");
const wf_ctn = @import("containers.zig");
const Client = host_mod.Client;

// ---------------------------------------------------------------------
// Cookie synchronisation across route instances (protocol 0xE0 block)
// ---------------------------------------------------------------------
//
// A route is a whole helper process with its own profile, so the same
// container is a different cookie jar in every instance. This block
// buys the identity back: every LOCAL instance that advertises
// "cookie-sync" is subscribed once a second instance exists, each
// observed change is applied to every other peer, and a freshly started
// instance is seeded from the default one, jar by jar. Remote-browser
// instances are deliberately not peers: their jar lives on the remote
// host, and cookie VALUES crossing to another machine is a decision
// nobody made by picking "browser runs on".

pub const SeedJob = struct {
    /// The `cookie_dump_req` id outstanding on the default instance.
    req: u32,
    /// The instance the dumped page is applied to.
    target: *Client,
    context: u32,
};

pub var g_seed_jobs: std.ArrayList(SeedJob) = .empty;
pub var g_sync_req: u32 = 1;

pub fn nextSyncReq() u32 {
    const r = g_sync_req;
    g_sync_req +%= 1;
    if (g_sync_req == 0) g_sync_req = 1;
    return r;
}

/// A subscribed-or-subscribable sync participant.
pub fn isSyncPeer(cl: *const Client) bool {
    return !cl.isRemote() and cl.state == .ready and cl.hello_done and cl.has(.cookie_sync);
}

pub fn syncPeerCount() usize {
    var n: usize = 0;
    if (isSyncPeer(&host_mod.g_client)) n += 1;
    for (host_mod.g_aux_clients.items) |cl| {
        if (isSyncPeer(cl)) n += 1;
    }
    return n;
}

pub fn enableSyncOn(cl: *Client) void {
    if (cl.sync_enabled or !isSyncPeer(cl)) return;
    cl.post(proto.CookieSyncEnable{ .enable = 1 });
    cl.sync_enabled = true;
}

/// An instance finished its handshake: with two or more peers alive
/// every one of them is subscribed (the first stays unsubscribed while
/// alone, since observing costs a periodic walk of every jar), and a
/// non-default instance is seeded from the default one.
pub fn cookieSyncOnReady(cl: *Client) void {
    if (!isSyncPeer(cl)) return;
    if (syncPeerCount() < 2) return;
    enableSyncOn(&host_mod.g_client);
    for (host_mod.g_aux_clients.items) |peer| enableSyncOn(peer);
    if (cl == &host_mod.g_client or !isSyncPeer(&host_mod.g_client)) return;
    // Seed: the shared jar plus every container jar the registry
    // publishes to both instances.
    requestSeed(cl, 0);
    for (wf_ctn.g_containers.items) |*ctn| requestSeed(cl, ctn.id);
}

pub fn requestSeed(target: *Client, context: u32) void {
    const req = nextSyncReq();
    g_seed_jobs.append(host_mod.g_client.gpa, .{ .req = req, .target = target, .context = context }) catch return;
    host_mod.g_client.post(proto.CookieDumpReq{ .req = req, .context = context, .cursor = 0 });
}

/// A jar changed in `src`: replay it into every other peer. The helper
/// settles its own shadow on apply, so nothing here loops.
pub fn onCookieChange(src: *Client, ev: proto.EvCookieChange) void {
    applyToPeers(src, ev.context, ev.removed, ev.url, ev.cookie);
}

pub fn applyToPeers(src: ?*Client, context: u32, remove: u8, url: []const u8, cookie: proto.SyncCookie) void {
    if (src != &host_mod.g_client and isSyncPeer(&host_mod.g_client)) applyTo(&host_mod.g_client, context, remove, url, cookie);
    for (host_mod.g_aux_clients.items) |peer| {
        if (peer == src or !isSyncPeer(peer)) continue;
        applyTo(peer, context, remove, url, cookie);
    }
}

pub fn applyTo(cl: *Client, context: u32, remove: u8, url: []const u8, cookie: proto.SyncCookie) void {
    cl.post(proto.CookieApply{
        .req = nextSyncReq(),
        .context = context,
        .remove = remove,
        .url = url,
        .cookie = cookie,
    });
}

/// One page of a seed dump landed on the default instance: apply it to
/// the job's target and ask for the next page while there is one.
pub fn onCookieDump(src: *Client, ev: proto.EvCookieDump) void {
    if (src != &host_mod.g_client) return;
    var idx: ?usize = null;
    for (g_seed_jobs.items, 0..) |job, i| {
        if (job.req == ev.req) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return;
    const job = g_seed_jobs.items[i];
    if (ev.ok == 0 or !isSyncPeer(job.target)) {
        _ = g_seed_jobs.swapRemove(i);
        return;
    }
    for (ev.cookies) |ck| {
        var ubuf: [1024]u8 = undefined;
        const url = cookieUrl(&ubuf, ck) orelse continue;
        applyTo(job.target, job.context, 0, url, ck);
    }
    if (ev.more != 0) {
        const req = nextSyncReq();
        g_seed_jobs.items[i].req = req;
        host_mod.g_client.post(proto.CookieDumpReq{ .req = req, .context = job.context, .cursor = ev.next_cursor });
    } else {
        _ = g_seed_jobs.swapRemove(i);
    }
}

/// The url a dumped cookie is applied under: its domain (dot-less) and
/// path, on https for a Secure cookie. `cookie_apply` needs a url the
/// engine will accept the cookie for, and a dump carries none.
pub fn cookieUrl(buf: []u8, ck: proto.SyncCookie) ?[]const u8 {
    const domain = std.mem.trimStart(u8, ck.domain, ".");
    if (domain.len == 0) return null;
    const path = if (ck.path.len != 0 and ck.path[0] == '/') ck.path else "/";
    const scheme: []const u8 = if (ck.flags & proto.cookie_secure != 0) "https" else "http";
    return std.fmt.bufPrint(buf, "{s}://{s}{s}", .{ scheme, domain, path }) catch null;
}

test "a dumped cookie is applied under the url its attributes imply" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    const base = proto.SyncCookie{
        .name = "sid",
        .value = "v",
        .domain = ".example.com",
        .path = "/app",
        .flags = proto.cookie_secure,
        .same_site = 0,
        .priority = 1,
        .creation_ms = 0,
        .last_access_ms = 0,
        .expires_ms = 0,
    };
    try t.expectEqualStrings("https://example.com/app", cookieUrl(&buf, base).?);
    var plain = base;
    plain.flags = 0;
    plain.path = "";
    try t.expectEqualStrings("http://example.com/", cookieUrl(&buf, plain).?);
    var nodomain = base;
    nodomain.domain = "";
    try t.expect(cookieUrl(&buf, nodomain) == null);
}
