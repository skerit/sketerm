//! The broker-owned browser engine (`web_op engine_open`): the daemon
//! spawns the instance's `sketerm-webengine` with the linger lifecycle,
//! tracks it for successors and answers with its socket path. Split
//! out of daemon_serve.zig.

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

const daemon_web = @import("daemon_web.zig");
const WebOpReq = daemon_web.WebOpReq;
const webProfileStore = daemon_web.webProfileStore;
const webReplyErr = daemon_web.webReplyErr;

// === Broker-owned browser engine (web_op engine_open) ===============
// Phase 3 of the broker-owned-engine work: the daemon SPAWNS the
// instance's sketerm-webengine (with `--linger-ms`, so it survives its
// last client and reaps ITSELF through the graceful drain — the only
// path that reliably flushes profile jars) and answers with the
// engine's listening socket path. The daemon never relays a web byte:
// clients connect to that socket directly, exactly as they always
// connected to a sibling-spawned helper. Refcounting is deliberately
// absent — the engine's own connection count is the ground truth, and
// a client that crashes needs no bookkeeping to be forgotten.

/// How long a broker-owned engine keeps listening after its LAST
/// client disconnects. Overridable for the smoke rigs; the default
/// keeps a warm engine (and its logged-in profiles) across the gap
/// between one assistant task and the next.
fn engineLingerMs() i64 {
    const v = c.getenv("SKETERM_WEB_LINGER_MS") orelse return 180_000;
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
    return std.fmt.parseInt(i64, s, 10) catch 180_000;
}

/// The instance key this daemon serves, derived from its own socket
/// (`.../mcp-<name>/mux.sock`); null for the per-user default daemon
/// and ephemeral `mcp-tmp-<pid>` instances, which host no engine.
fn selfInstanceKey(self: *Daemon) ?[]const u8 {
    const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse return null;
    const dir = self.sock_path[0..dir_end];
    const base_start = (std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null) + 1;
    const base = dir[base_start..];
    if (!std.mem.startsWith(u8, base, "mcp-")) return null;
    if (std.mem.startsWith(u8, base, "mcp-tmp-")) return null;
    return base["mcp-".len..];
}

test "only a named MCP instance daemon hosts a browser engine" {
    const t = std.testing;
    const Case = struct { sock: []const u8, key: ?[]const u8 };
    for ([_]Case{
        .{ .sock = "/run/user/1000/sketerm/mcp-default/mux.sock", .key = "default" },
        .{ .sock = "/run/user/1000/sketerm/mcp-team-a/mux.sock", .key = "team-a" },
        .{ .sock = "/run/user/1000/sketerm/mcp-tmp-4242/mux.sock", .key = null },
        .{ .sock = "/run/user/1000/sketerm/mux.sock", .key = null },
        .{ .sock = "mux.sock", .key = null },
        .{ .sock = "", .key = null },
    }) |case| {
        var d = Daemon{ .allocator = t.allocator, .listen_fd = -1, .sock_path = @constCast(case.sock) };
        const got = selfInstanceKey(&d);
        if (case.key) |want| {
            try t.expectEqualStrings(want, got orelse return error.TestUnexpectedResult);
        } else try t.expect(got == null);
    }
}

test "the engine linger TTL reads its override and falls back on nonsense" {
    const t = std.testing;
    const saved = c.getenv("SKETERM_WEB_LINGER_MS");
    defer if (saved) |v| {
        _ = c.setenv("SKETERM_WEB_LINGER_MS", v, 1);
    } else {
        _ = c.unsetenv("SKETERM_WEB_LINGER_MS");
    };
    _ = c.unsetenv("SKETERM_WEB_LINGER_MS");
    try t.expectEqual(@as(i64, 180_000), engineLingerMs());
    _ = c.setenv("SKETERM_WEB_LINGER_MS", "2500", 1);
    try t.expectEqual(@as(i64, 2500), engineLingerMs());
    _ = c.setenv("SKETERM_WEB_LINGER_MS", "soon", 1);
    try t.expectEqual(@as(i64, 180_000), engineLingerMs());
}

/// Reap engines that exited on their own (the linger TTL); called
/// before every use so a dead entry never masks a needed spawn.
pub fn sweepWebEngines(self: *Daemon) void {
    for (self.web_engines.items) |*e| {
        e.diagnostic.drain();
        var status: c_int = 0;
        if (e.pid > 0 and c.waitpid(e.pid, &status, c.WNOHANG) == e.pid) {
            e.diagnostic.exited(status);
            e.diagnostic.deinit();
            e.pid = -1;
            removePresenceAt(e.sock);
        }
    }
}

/// A connect probe: someone is accepting on this engine socket.
fn engineSocketLive(sock: []const u8) bool {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    if (sock.len + 1 > addr.sun_path.len) return false;
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..sock.len], sock);
    const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0;
}

/// Unlink the `web.json` presence file next to an engine socket.
fn removePresenceAt(sock: []const u8) void {
    const dir_end = std.mem.lastIndexOfScalar(u8, sock, '/') orelse return;
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}/web.json", .{sock[0..dir_end]}) catch return;
    _ = c.unlink(p.ptr);
}

pub fn handleWebEngineOpen(self: *Daemon, cl: *Client, r: WebOpReq) void {
    if (self.isWorker())
        return webReplyErr(cl, r.req, "browser engine ops are served by the broker, not a session worker");
    const key = selfInstanceKey(self) orelse
        return webReplyErr(cl, r.req, "this daemon hosts no browser engine (not a named MCP instance daemon)");
    if (r.instance.len != 0 and !std.mem.eql(u8, r.instance, key))
        return webReplyErr(cl, r.req, "engine_open named a different instance than this daemon serves");

    sweepWebEngines(self);
    var sock_buf: [4096]u8 = undefined;
    const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse
        return webReplyErr(cl, r.req, "unresolvable instance dir");
    const sock = std.fmt.bufPrint(&sock_buf, "{s}/web.sock", .{self.sock_path[0..dir_end]}) catch
        return webReplyErr(cl, r.req, "engine socket path too long");

    for (self.web_engines.items) |e| {
        if (e.pid > 0 and std.mem.eql(u8, e.key, key)) {
            cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .sock = e.sock, .pid = e.pid, .spawned = false, .diagnostics = true });
            return;
        }
    }

    // An engine THIS broker did not spawn may still be listening — a
    // predecessor broker's lingering engine (brokers idle-exit; their
    // engines deliberately outlive them), or an old client-spawned
    // helper. Spawning beside it would collide two CEF processes on
    // one root; hand out the live socket instead.
    if (engineSocketLive(sock)) {
        cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .sock = sock, .pid = @as(c.pid_t, 0), .spawned = false });
        return;
    }

    // The engine's --cache-dir must BE the profile store root, so the
    // store is opened (and its flock taken by THIS daemon) first.
    var why: []const u8 = "";
    const store = webProfileStore(self, key, &why) orelse return webReplyErr(cl, r.req, why);

    var bin_buf: [4096:0]u8 = undefined;
    const bin = webfindbin.find(&bin_buf) orelse
        return webReplyErr(cl, r.req, "sketerm-webengine is not installed on this host");

    // NUL-terminated argv, prepared before the fork.
    var sock_z: [4096:0]u8 = undefined;
    const sock_arg = std.fmt.bufPrintZ(&sock_z, "{s}", .{sock}) catch
        return webReplyErr(cl, r.req, "engine socket path too long");
    var cache_z: [4096:0]u8 = undefined;
    const cache_arg = std.fmt.bufPrintZ(&cache_z, "{s}", .{store.root}) catch
        return webReplyErr(cl, r.req, "engine cache path too long");
    var linger_z: [24:0]u8 = undefined;
    const linger_arg = std.fmt.bufPrintZ(&linger_z, "{d}", .{engineLingerMs()}) catch unreachable;

    // A stale socket from a crashed engine would make clients connect
    // against nothing; the daemon's single loop serializes this unlink
    // against every sibling engine_open.
    _ = c.unlink(sock_arg.ptr);

    // Reserve every fallible allocation BEFORE spawning: an OOM must not
    // leave an untracked engine holding the profile store's CEF files.
    var slot: ?*Daemon.WebEngine = null;
    for (self.web_engines.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) slot = e;
    }
    if (slot == null) {
        const owned_key = self.allocator.dupe(u8, key) catch return webReplyErr(cl, r.req, "oom");
        const owned_sock = self.allocator.dupe(u8, sock) catch {
            self.allocator.free(owned_key);
            return webReplyErr(cl, r.req, "oom");
        };
        self.web_engines.append(self.allocator, .{ .key = owned_key, .pid = -1, .sock = owned_sock }) catch {
            self.allocator.free(owned_key);
            self.allocator.free(owned_sock);
            return webReplyErr(cl, r.req, "oom");
        };
        slot = &self.web_engines.items[self.web_engines.items.len - 1];
    }
    const entry = slot.?;
    entry.diagnostic.deinit();
    entry.diagnostic = @import("../web/diagnostic.zig").Capture.init() catch
        return webReplyErr(cl, r.req, "could not create helper diagnostic capture");
    const pid = c.fork();
    if (pid < 0) {
        entry.diagnostic.deinit();
        return webReplyErr(cl, r.req, "fork failed");
    }
    if (pid == 0) {
        entry.diagnostic.child();
        // Own process group so a future teardown can take CEF's whole
        // subprocess tree; stdio to /dev/null (CEF noise), like the
        // remote-helper spawn above.
        _ = c.setpgid(0, 0);
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            if (devnull > 2) _ = c.close(devnull);
        }
        var argv: [8:null]?[*:0]const u8 = .{ bin, "--socket", sock_arg.ptr, "--cache-dir", cache_arg.ptr, "--linger-ms", linger_z[0..linger_arg.len :0].ptr, null };
        _ = c.execv(bin, @ptrCast(@constCast(&argv)));
        @import("../web/diagnostic.zig").Capture.execFailed();
        c._exit(127);
    }
    entry.diagnostic.parent();
    entry.pid = pid;
    writeEnginePresence(self, sock, pid, key);
    log.debug("engine_open: spawned sketerm-webengine pid {d} for instance {s}", .{ pid, key });
    // The client owns the bind wait: replying now keeps the daemon's
    // loop free while CEF pays its multi-second startup.
    cl.queueJson(.web_reply, .{ .req = r.req, .ok = true, .sock = entry.sock, .pid = pid, .spawned = true, .diagnostics = true });
}

/// The presence file `web.json` (see webdrive's header), now written by
/// the OWNER of the engine pid — this daemon.
fn writeEnginePresence(self: *Daemon, sock: []const u8, pid: c.pid_t, key: []const u8) void {
    const dir_end = std.mem.lastIndexOfScalar(u8, sock, '/') orelse return;
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}/web.json", .{sock[0..dir_end]}) catch return;
    const f = c.fopen(p.ptr, "w") orelse return;
    defer _ = c.fclose(f);
    var line: [640]u8 = undefined;
    const body = std.fmt.bufPrint(&line, "{{\"broker_pid\":{d},\"helper_pid\":{d},\"client\":\"sketerm-mux:{s}\",\"started_at_ms\":{d}}}\n", .{
        c.getpid(), pid, key, wallMs(),
    }) catch return;
    _ = c.fwrite(body.ptr, 1, body.len, f);
    _ = self;
}
