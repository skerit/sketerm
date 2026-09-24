//! Daemon-hosted web state: the `web_op` store (history, bookmarks,
//! per-site settings on the daemon's host) and the broker-owned
//! headless browser-profile stores (the `profile_*` ops, refused by
//! workers). Split out of daemon_serve.zig.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const platform = @import("../util/platform.zig");
const selfexec = @import("selfexec.zig");
const fsserve = @import("fsserve.zig");
const fsjob = @import("fsjob.zig");
const daemon_fsjobs = @import("daemon_fsjobs.zig");
const pulse = @import("pulse.zig");
const snapshot = @import("snapshot.zig");
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Worker = dmod.Worker;
const Session = dmod.Session;
const Channel = dmod.Channel;
const Upload = dmod.Upload;
const Download = dmod.Download;
const FsView = dmod.FsView;
const SpawnReq = dmod.SpawnReq;
const AttachReq = dmod.AttachReq;
const WorkerReady = dmod.WorkerReady;
const WorkerMeta = dmod.WorkerMeta;
const WorkerPush = dmod.WorkerPush;
const nowMs = @import("../util/clock.zig").nowMs;
const cwdOfPid = dmod.cwdOfPid;
const pathZ = @import("../util/pathz.zig").pathZ;
const version = @import("../version.zig");
const cast_rec = @import("cast.zig");
const opuscodec = @import("opuscodec.zig");
const build_options = @import("build_options");
const wsproto = @import("../winstream/proto.zig");
const wallMs = @import("../util/clock.zig").wallMs;
const webstore = @import("webstore.zig");
const webprofiles = @import("../ipc/webprofiles.zig");
const webfindbin = @import("../web/findbin.zig");
const capabilities = @import("capabilities.zig");

const daemon_webengine = @import("daemon_webengine.zig");
const handleWebEngineOpen = daemon_webengine.handleWebEngineOpen;
const sweepWebEngines = daemon_webengine.sweepWebEngines;

// === Web store (web_op / web_reply) ============================
// Browsing history, bookmarks and per-site settings persisted on THIS
// daemon's host ($XDG_STATE_HOME/sketerm/web) — a GUI attached to a
// remote daemon sees that host's browsing state. All verbs are bounded
// inline work in the poll loop. NOT attach-scoped: served by whichever
// process owns the client connection (the broker, in broker mode).

pub const WebOpReq = struct {
    req: u32 = 0,
    op: []const u8 = "",
    /// profile_* ops: the MCP instance key whose store the op names
    /// ("" = the anonymous store). Client-sent, same-user trust domain
    /// (the store root is 0700); the daemon's own socket already scopes
    /// which clients can reach it at all.
    instance: []const u8 = "",
    url: []const u8 = "",
    title: []const u8 = "",
    /// history_query search text ("" = overall top entries).
    q: []const u8 = "",
    /// history_query result bound (0 = default 20, hard cap 200).
    max: u32 = 0,
    /// bookmark_remove/bookmark_update target.
    id: u64 = 0,
    /// Absent = leave a bookmark's folder alone; "" moves it back to
    /// the top level. Optional rather than "" -meaning-unchanged so
    /// that "no folder" stays expressible.
    folder: ?[]const u8 = null,
    /// bookmark_update reorder destination.
    index: ?u32 = null,
    origin: []const u8 = "",
    zoom_x100: ?i32 = null,
    popup: ?[]const u8 = null,
    block: ?bool = null,
    block_clear: bool = false,
    perm: []const u8 = "",
    decision: []const u8 = "",
    /// userscript_add display name.
    name: []const u8 = "",
    /// userscript_add raw source / userstyle_set CSS carrier.
    source: []const u8 = "",
    /// userscript_enable / userstyle_set enabled flag.
    enabled: ?bool = null,
    /// userstyle host key ("" = every page — which is why this is not
    /// `origin`: an empty origin is invalid there).
    host: []const u8 = "",
    css: []const u8 = "",
    /// container_update/remove target, and the container a
    /// container_site_set rule points at (0 clears the rule).
    container: u32 = 0,
    /// container_add stable jar key ("" = seed it from `name`).
    jar: []const u8 = "",
    /// Container accent as 0xRRGGBB; absent leaves it alone.
    color: ?u32 = null,
    /// Container default route in `web/route.zig`'s text grammar;
    /// absent leaves it alone, "" clears it to direct.
    route: ?[]const u8 = null,
};

fn rgbFromU32(v: u32) [3]u8 {
    return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}

test "a packed 0xRRGGBB site color splits into its channels" {
    const t = std.testing;
    try t.expectEqual([3]u8{ 0x12, 0x34, 0x56 }, rgbFromU32(0x123456));
    try t.expectEqual([3]u8{ 0xff, 0x00, 0x00 }, rgbFromU32(0xff0000));
    // Bits above the low 24 are ignored, never folded into a channel.
    try t.expectEqual([3]u8{ 0x00, 0x00, 0x01 }, rgbFromU32(0xff000001));
}

test "a web op refusal echoes the request id the client correlates by" {
    const t = std.testing;
    const a = t.allocator;
    var cl = Client{ .allocator = a, .fd = -1 };
    defer cl.rbuf.deinit(a);
    defer cl.wbuf.deinit(a);
    defer cl.audio_wbuf.deinit(a);
    webReplyErr(&cl, 77, "unknown web op");
    const reply = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.web_reply, reply.frame.ftype);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "\"req\":77") != null);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "\"ok\":false") != null);
    // A worker refuses every profile op: the store must outlive clients.
    cl.wbuf.clearRetainingCapacity();
    var empty: [0]u8 = .{};
    var worker = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..], .role = .worker };
    var err: []const u8 = "";
    try t.expect(webProfileStore(&worker, "inst", &err) == null);
    try t.expect(std.mem.indexOf(u8, err, "broker") != null);
}

pub fn webReplyErr(cl: *Client, req: u32, msg: []const u8) void {
    cl.queueJson(.web_reply, .{ .req = req, .ok = false, .@"error" = msg });
}

/// The daemon's web store, opened on first use (missing files are an
/// empty store; an unresolvable state dir fails each op, not the daemon).
fn webStore(self: *Daemon) ?*webstore.WebStore {
    if (self.web_store == null) {
        const dir = webstore.defaultDirAlloc(self.allocator) catch return null;
        defer self.allocator.free(dir);
        self.web_store = webstore.WebStore.init(self.allocator, dir) catch return null;
    }
    return &self.web_store.?;
}

pub fn handleWebOp(self: *Daemon, cl: *Client, payload: []const u8) void {
    const parsed = std.json.parseFromSlice(WebOpReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad web_op");
        return;
    };
    defer parsed.deinit();
    const r = parsed.value;
    // The profile family has its own store (per instance, flock-held);
    // routing it first keeps the history/bookmark store untouched for
    // clients that only ever do profile work.
    if (std.mem.startsWith(u8, r.op, "profile_")) return handleWebProfileOp(self, cl, r);
    if (std.mem.eql(u8, r.op, "engine_open")) return handleWebEngineOpen(self, cl, r);
    if (std.mem.eql(u8, r.op, "engine_diagnostic")) {
        sweepWebEngines(self);
        for (self.web_engines.items) |*e| {
            if (std.mem.eql(u8, e.key, r.instance)) {
                cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .diagnostic = e.diagnostic.report() });
                return;
            }
        }
        return webReplyErr(cl, r.req, "no retained engine diagnostic for this instance");
    }
    const store = webStore(self) orelse return webReplyErr(cl, r.req, "web store unavailable");

    if (std.mem.eql(u8, r.op, "history_add")) {
        store.addVisit(r.url, r.title, wallMs()) catch return webReplyErr(cl, r.req, "history write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "history_title")) {
        store.setTitle(r.url, r.title) catch return webReplyErr(cl, r.req, "history write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "history_query")) {
        const max: usize = if (r.max == 0) 20 else @min(r.max, 200);
        const hits = store.query(self.allocator, r.q, max, wallMs()) catch
            return webReplyErr(cl, r.req, "query failed");
        defer self.allocator.free(hits);
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .hits = hits });
    } else if (std.mem.eql(u8, r.op, "history_delete")) {
        const removed = store.deleteUrl(r.url) catch return webReplyErr(cl, r.req, "history write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .removed = removed });
    } else if (std.mem.eql(u8, r.op, "history_clear")) {
        store.clearHistory() catch return webReplyErr(cl, r.req, "history write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "bookmark_add")) {
        const id = store.bookmarkAdd(r.url, r.title, r.folder orelse "") catch
            return webReplyErr(cl, r.req, "bookmark write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .id = id });
    } else if (std.mem.eql(u8, r.op, "bookmark_remove")) {
        const removed = store.bookmarkRemove(r.id) catch
            return webReplyErr(cl, r.req, "bookmark write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .removed = removed });
    } else if (std.mem.eql(u8, r.op, "bookmark_update")) {
        // An empty url/title means "leave unchanged" — a bookmark with
        // neither is cleared by removing it, not by blanking fields.
        // `folder` is the exception: an ABSENT folder is unchanged and
        // an empty one is the top level, which a bookmark must be able
        // to move back to.
        const found = store.bookmarkUpdate(r.id, .{
            .url = if (r.url.len > 0) r.url else null,
            .title = if (r.title.len > 0) r.title else null,
            .folder = r.folder,
            .index = if (r.index) |i| i else null,
        }) catch return webReplyErr(cl, r.req, "bookmark write failed");
        if (!found) return webReplyErr(cl, r.req, "no such bookmark");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "bookmark_list")) {
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .bookmarks = store.bookmarks.items });
    } else if (std.mem.eql(u8, r.op, "site_get")) {
        if (store.siteGet(r.origin)) |site| {
            cl.queueJson(.web_reply, .{
                .req = r.req,
                .ok = true,
                .origin = r.origin,
                .site = .{
                    .zoom_x100 = site.zoom_x100,
                    .popup = site.popup,
                    .block = site.block,
                    .perms = site.perms.items,
                },
            });
        } else {
            cl.queueJson(.web_reply, .{
                .req = r.req,
                .ok = true,
                .origin = r.origin,
                .site = @as(?u8, null),
            });
        }
    } else if (std.mem.eql(u8, r.op, "site_set")) {
        store.siteSet(r.origin, .{
            .zoom_x100 = r.zoom_x100,
            .popup = r.popup,
            .block = r.block,
            .block_clear = r.block_clear,
            .perm = r.perm,
            .decision = r.decision,
        }) catch return webReplyErr(cl, r.req, "site write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "userscript_add")) {
        const id = store.userscriptAdd(r.name, r.source) catch
            return webReplyErr(cl, r.req, "userscript write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .id = id });
    } else if (std.mem.eql(u8, r.op, "userscript_remove")) {
        const removed = store.userscriptRemove(r.id) catch
            return webReplyErr(cl, r.req, "userscript write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .removed = removed });
    } else if (std.mem.eql(u8, r.op, "userscript_enable")) {
        const found = store.userscriptEnable(r.id, r.enabled orelse true) catch
            return webReplyErr(cl, r.req, "userscript write failed");
        if (!found) return webReplyErr(cl, r.req, "no such userscript");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "userscript_list")) {
        // Sources included: the GUI pushes them whole to the helper.
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .scripts = store.userscripts.items });
    } else if (std.mem.eql(u8, r.op, "userstyle_set")) {
        store.userstyleSet(r.host, r.css, r.enabled orelse true) catch
            return webReplyErr(cl, r.req, "userstyle write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "userstyle_get")) {
        if (store.userstyleGet(r.host)) |style| {
            cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .style = style.* });
        } else {
            cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .style = @as(?u8, null) });
        }
    } else if (std.mem.eql(u8, r.op, "userstyle_list")) {
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .styles = store.userstyles.items });
    } else if (std.mem.eql(u8, r.op, "container_list")) {
        // Containers and their site rules travel together: a rule is
        // meaningless without the container it names, and the GUI
        // resolves both in one pass at startup.
        cl.queueJson(.web_reply, .{
            .req = r.req,
            .ok = true,
            .containers = store.containers.items,
            .sites = store.container_sites.items,
        });
    } else if (std.mem.eql(u8, r.op, "container_add")) {
        const id = store.containerAdd(
            r.name,
            r.jar,
            rgbFromU32(r.color orelse 0),
            r.route orelse "",
        ) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.BadContainer => "a container needs a name and a route of direct | tor | via:<host> | on:<host>",
            else => "container write failed",
        });
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .id = id });
    } else if (std.mem.eql(u8, r.op, "container_update")) {
        const found = store.containerUpdate(r.container, .{
            .name = if (r.name.len != 0) r.name else null,
            .color = if (r.color) |v| rgbFromU32(v) else null,
            .route = r.route,
        }) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.BadContainer => "a container route is direct | tor | via:<host> | on:<host>",
            else => "container write failed",
        });
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .found = found });
    } else if (std.mem.eql(u8, r.op, "container_remove")) {
        const removed = store.containerRemove(r.container) catch
            return webReplyErr(cl, r.req, "container write failed");
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .found = removed });
    } else if (std.mem.eql(u8, r.op, "container_site_set")) {
        store.containerSiteSet(r.host, r.container) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.NoSuchContainer => "no such container",
            error.BadContainer => "bad host",
            else => "container write failed",
        });
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else {
        webReplyErr(cl, r.req, "unknown web op");
    }
}

// === Broker-owned browser-profile stores (web_op profile_*) =========
// The headless browser-profile store (jars + profiles.json + the
// exclusivity flock) is owned by THIS daemon rather than by any one
// MCP client, so N concurrent clients of one instance all resolve the
// same (name -> id) table and the second is no longer refused with
// "another sketerm mcp process owns the browser profile store". The
// flock is held for the daemon's lifetime; a client asks for ids and
// receives the store ROOT path to hand the helper as --cache-dir
// (same host by construction — this daemon spawned next to its
// clients' instance dir).

/// The store for `instance`, opened on first use and kept. On refusal
/// the reason is written to `err_out` and null returned.
pub fn webProfileStore(self: *Daemon, instance: []const u8, err_out: *[]const u8) ?*webprofiles.Store {
    if (self.isWorker()) {
        // A worker only ever owns fds passed to it AFTER attach; the
        // store must live in the one process that outlives clients.
        err_out.* = "browser profile ops are served by the broker, not a session worker";
        return null;
    }
    for (self.web_profile_stores.items) |*nps| {
        if (std.mem.eql(u8, nps.key, instance)) return &nps.store;
    }
    var holder: c.pid_t = 0;
    const inst: ?[]const u8 = if (instance.len == 0) null else instance;
    const store = webprofiles.Store.open(self.allocator, inst, &holder) catch |err| {
        err_out.* = switch (err) {
            // Another PROCESS holds this root (an old-build MCP client
            // flocking it itself, or a second daemon addressed at the
            // same instance key). The client's fallback path then shows
            // its own refusal sentence naming the pid.
            error.Locked => "the browser profile store is owned by another process",
            error.NoStateDir => "no state directory to keep browser profiles in (neither XDG_STATE_HOME nor HOME is set)",
            error.PathTooLong => "the browser profile store path is too long for the browser helper's cache-path limit (use a shorter XDG_STATE_HOME)",
            error.Io, error.OutOfMemory => "the browser profile store could not be created (check permissions on XDG_STATE_HOME/sketerm)",
        };
        return null;
    };
    const key = self.allocator.dupe(u8, instance) catch {
        var dead = store;
        dead.deinit();
        err_out.* = "out of memory";
        return null;
    };
    self.web_profile_stores.append(self.allocator, .{ .key = key, .store = store }) catch {
        self.allocator.free(key);
        var dead = store;
        dead.deinit();
        err_out.* = "out of memory";
        return null;
    };
    return &self.web_profile_stores.items[self.web_profile_stores.items.len - 1].store;
}

fn handleWebProfileOp(self: *Daemon, cl: *Client, r: WebOpReq) void {
    var why: []const u8 = "";
    const store = webProfileStore(self, r.instance, &why) orelse
        return webReplyErr(cl, r.req, why);

    if (std.mem.eql(u8, r.op, "profile_open")) {
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .root = store.root });
    } else if (std.mem.eql(u8, r.op, "profile_ensure")) {
        const id = store.ensure(r.name) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.BadName => "invalid profile name",
            error.Io, error.OutOfMemory => "the browser profile store could not be written",
        });
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .id = id, .root = store.root });
    } else if (std.mem.eql(u8, r.op, "profile_list")) {
        const Row = struct { name: []const u8, id: u32, created_ms: i64, last_used_ms: i64 };
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(self.allocator);
        for (store.list()) |e| {
            rows.append(self.allocator, .{
                .name = e.name,
                .id = e.id,
                .created_ms = e.created_ms,
                .last_used_ms = e.last_used_ms,
            }) catch return webReplyErr(cl, r.req, "out of memory");
        }
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .root = store.root, .profiles = rows.items });
    } else if (std.mem.eql(u8, r.op, "profile_touch")) {
        store.touch(r.name, wallMs());
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "profile_retire")) {
        const prior = store.find(r.name);
        const removed = store.retire(r.name) catch |err| return webReplyErr(cl, r.req, switch (err) {
            error.BadName => "invalid profile name",
            error.Io, error.OutOfMemory => "the browser profile store could not be written",
        });
        cl.queueJson(.web_reply, .{
            .req = r.req,
            .ok = true,
            .removed = removed,
            .id = if (prior) |e| e.id else 0,
        });
    } else {
        webReplyErr(cl, r.req, "unknown web profile op");
    }
}
