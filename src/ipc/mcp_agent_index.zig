//! The per-user agent index (`agentindex.zig`): descriptors, ownership
//! (a held flock per agent), the durable and legacy reattach, the gone
//! descriptor's keep-or-remove rule (`retireDescriptor`), and
//! `agent_attach {agent}` with its relaunch (`relaunchFrom`).

const std = @import("std");
const c = @import("../c.zig").c;
const mcp = @import("mcp.zig");
const mcp_term = @import("mcp_term.zig");
const termdrive = @import("termdrive.zig");
const adapter = @import("../agent/adapter.zig");
const agent_mod = @import("../agent/agent.zig");
const select = @import("../agent/select.zig");
const launch = @import("../agent/launch.zig");
const wire = @import("../mux/wire.zig");
const clock = @import("../util/clock.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const pathz = @import("../util/pathz.zig");
const readfile = @import("../util/readfile.zig");
const transport_mod = @import("transport.zig");
const mcp_registry = @import("mcp_registry.zig");
const agentindex = @import("agentindex.zig");
const muxconnect = @import("muxconnect.zig");
const muxclient = @import("../mux/client.zig");
const tombstones = @import("../mux/tombstones.zig");
const sockpath = @import("../mux/sockpath.zig");
const sshroute = @import("../mux/sshroute.zig");
const Transport = transport_mod.Transport;
const Res = mcp.Res;
const errRes = mcp.errRes;
const argStr = mcp.argStr;
const argBool = mcp.argBool;

const mcp_agent = @import("mcp_agent.zig");
const mcp_agent_results = @import("mcp_agent_results.zig");
const mcp_agent_waiter = @import("mcp_agent_waiter.zig");

const DEFAULT_WAIT_MS = mcp_agent.DEFAULT_WAIT_MS;
const ATTACH_WAIT_MS = mcp_agent.ATTACH_WAIT_MS;
const Entry = mcp_agent.Entry;
const GoneFacts = mcp_agent.GoneFacts;
const hold = mcp_agent.hold;
const state = &mcp_agent.state;
const adapters = mcp_agent.adapters;
const findByName = mcp_agent.findByName;
const lockPath = mcp_agent.lockPath;
const findById = mcp_agent.findById;
const setRetryPolicy = mcp_agent.setRetryPolicy;
const goneDetail = mcp_agent.goneDetail;
const spawnForward = mcp_agent.spawnForward;
const gone = mcp_agent.gone;
const waitReady = mcp_agent.waitReady;
const Fail = mcp_agent.Fail;
const deadlineFrom = mcp_agent.deadlineFrom;
const OpenOpts = mcp_agent.OpenOpts;
const startAgent = mcp_agent.startAgent;
const LaunchFacts = mcp_agent.LaunchFacts;
const newEntry = mcp_agent.newEntry;
const dropBare = mcp_agent.dropBare;
const sshDiagnose = mcp_agent.sshDiagnose;
const applySet = mcp_agent.applySet;
const Block = mcp_agent_results.Block;
const pending = mcp_agent_results.pending;
const finish = mcp_agent_results.finish;
const writeSelection = mcp_agent_results.writeSelection;
const endWaitersOf = mcp_agent_waiter.endWaitersOf;

/// Legacy descriptors (durable instances before the per-user index) live
/// here, in the instance dir.
const DESCRIPTOR_DIR = "agents";
const DESCRIPTOR_MAX_BYTES = agentindex.DESCRIPTOR_MAX_BYTES;
/// Bound on asking a daemon why a session ended.
const TOMBSTONE_WAIT_MS: i64 = 5_000;

// ── the per-user index: descriptors, ownership and reattach ──────

const Descriptor = agentindex.Descriptor;

/// Legacy durable-instance descriptor path (`<instance>/agents/<id>.<ext>`).
fn legacyPath(arena: std.mem.Allocator, id: []const u8, ext: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/" ++ DESCRIPTOR_DIR ++ "/{s}.{s}", .{ state.dir.?, id, ext });
}

/// Hold a freshly opened agent in the index (its id is new: nobody else
/// can hold it).
pub fn claimNew(e: *Entry) void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const lp = lockPath(fba.allocator(), e.id) catch return;
    pathz.makeDirs(state.index_dir.?, 0o700) catch return;
    e.claim = agentindex.claim(lp, false) catch null;
}

/// Write `e`'s descriptor (and opencode's password beside it) into the
/// per-user index, where any server can resume it.
pub fn writeDescriptor(e: *Entry) void {
    const index_dir = state.index_dir orelse return;
    const vis = if (e.visible) |l| switch (l) {
        .owned => |t| t,
        .borrowed => return,
    } else e.server orelse return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pw_path: ?[]const u8 = if (e.password) |p|
        (agentindex.writePassword(arena, index_dir, e.id, p) catch return)
    else
        null;
    const d = Descriptor{
        .id = e.id,
        .app = e.loaded.spec.id,
        .name = e.name,
        .session = vis.name,
        .origin = &vis.origin_id,
        .socket = e.socket,
        .instance = state.instance,
        .server_session = if (e.server) |s| s.name else null,
        .server_origin = if (e.server) |s| @as([]const u8, &s.origin_id) else null,
        .port = e.port,
        .password_file = pw_path,
        .api_session = switch (e.agent.source) {
            .opencode_api => |*api| api.sessionId(),
            .screen => null,
        },
        .binary = e.binary,
        .cwd = e.cwd,
        .host = e.host,
        .transport = @tagName(e.transport),
        .remote_port = e.remote_port,
        .conversation = e.conversation,
        .conversed = e.conversed,
        .launch_model = e.launch_model,
        .launch_effort = e.launch_effort,
        .picked_model = e.picked_model,
        .relaunches = e.relaunches,
        .cols = e.cols,
        .rows = e.rows,
        .args = e.extra.args,
        .server_args = e.extra.server_args,
        .tui_args = e.extra.tui_args,
        .env = e.extra.env,
        .path_prepend = e.extra.path_prepend,
        .login_shell = e.extra.login_shell,
        .permissions = e.extra.permissions,
        .retry_on_overload = e.retry.policy,
        .stall_after_min = e.stall.after_min orelse 0,
        .facts_file = e.facts_file,
        .status_user = e.status_user,
        .started_ms = e.started_ms,
        .gone_ms = e.ended_ms,
    };
    agentindex.write(arena, index_dir, d) catch return;
    e.indexed = true;
}

/// The agent is over: out of the index (descriptor, password, lock) and,
/// for a legacy durable descriptor, out of the instance dir too.
pub fn removeDescriptor(e: *Entry) void {
    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    if (state.index_dir) |d| agentindex.remove(a, d, e.id);
    fba.reset();
    if (e.claim) |*cl| {
        if (lockPath(a, e.id)) |lp| cl.release(lp, true) else |_| {}
        e.claim = null;
    }
    e.indexed = false;
    if (state.dir == null) return;
    fba.reset();
    if (legacyPath(a, e.id, "json")) |p| pathz.unlinkPath(p) else |_| {}
    fba.reset();
    if (legacyPath(a, e.id, "pw")) |p| pathz.unlinkPath(p) else |_| {}
}

/// Startup: a durable instance picks up its legacy descriptors
/// (`<instance>/agents/`, sessions on its own daemon) and the index entries
/// it opened, unless another live server holds them; a descriptor whose
/// session is gone is removed. Every server also drops index entries whose
/// local sessions are known to have ended. Never auto-reattaches anything
/// for an isolated server: that is `agent_attach`.
pub fn reattach() void {
    if (state.dir == null) return;
    if (state.durable) {
        reattachLegacy();
        reattachInstance();
    }
    sweepIndex();
    publishAgents();
}

fn reattachLegacy() void {
    const dir = state.dir orelse return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sub = std.fmt.allocPrintSentinel(arena, "{s}/" ++ DESCRIPTOR_DIR, .{dir}, 0) catch return;
    const d = c.opendir(sub.ptr) orelse return;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |de| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&de.*.d_name)), 0);
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ sub, name }) catch continue;
        const parsed = readfile.json(Descriptor, state.allocator, path, DESCRIPTOR_MAX_BYTES) orelse {
            pathz.unlinkPath(path);
            continue;
        };
        defer parsed.deinit();
        var why: AttachWhy = .{};
        var desc = parsed.value;
        // Its sessions are on this instance's own daemon.
        if (desc.socket == null) desc.socket = state.mux_sock;
        const e = reattachOne(arena, desc, null, &why) catch |err| {
            if (err == error.SessionGone) {
                pathz.unlinkPath(path);
                if (parsed.value.password_file) |p| pathz.unlinkPath(p);
            }
            continue;
        };
        // Migrated: the index holds it from now on.
        claimNew(e);
        writeDescriptor(e);
        if (e.indexed) {
            pathz.unlinkPath(path);
            if (parsed.value.password_file) |p| pathz.unlinkPath(p);
        }
    }
}

fn reattachInstance() void {
    const index_dir = state.index_dir orelse return;
    const inst = state.instance orelse return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (agentindex.ids(arena, index_dir) catch return) |id| {
        if (findById(id) != null) continue;
        const parsed = agentindex.read(arena, index_dir, id) orelse continue;
        const d = parsed.value;
        const mine = if (d.instance) |x| std.mem.eql(u8, x, inst) else false;
        // Known gone: only agent_attach relaunch starts it again.
        if (!mine or d.gone_ms > 0) continue;
        const lp = lockPath(arena, id) catch continue;
        var claimed = agentindex.claim(lp, false) catch continue;
        var why: AttachWhy = .{};
        _ = reattachOne(arena, d, claimed, &why) catch |err| {
            if (err == error.SessionGone) {
                _ = retireDescriptor(arena, index_dir, d, &claimed, lp);
            } else claimed.release(lp, false);
        };
    }
}

/// Drop index entries no live server holds whose LOCAL sessions their
/// daemon says ended. A daemon that does not answer proves nothing: its
/// session workers outlive it until the next one adopts them. Remote
/// entries are checked when someone attaches them.
fn sweepIndex() void {
    const index_dir = state.index_dir orelse return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (agentindex.ids(arena, index_dir) catch return) |id| {
        const parsed = agentindex.read(arena, index_dir, id) orelse continue;
        const d = parsed.value;
        // Kept for a relaunch: for the idle lifetime its sessions would have had.
        if (d.gone_ms > 0) {
            if (clock.wallMs() - d.gone_ms < @as(i64, state.ttl_secs) * 1000) continue;
            const lp = lockPath(arena, id) catch continue;
            var claimed = agentindex.claim(lp, false) catch continue;
            agentindex.remove(arena, index_dir, id);
            claimed.release(lp, true);
            continue;
        }
        const sock = d.socket orelse continue;
        if (d.host != null and !std.mem.eql(u8, d.transport orelse "", @tagName(Transport.ssh))) continue;
        const lp = lockPath(arena, id) catch continue;
        var claimed = agentindex.claim(lp, false) catch continue;
        var ended = false;
        if (muxclient.Conn.connectProbed(arena, sock)) |conn_val| {
            var conn = conn_val;
            defer conn.deinit();
            conn.setNonBlocking();
            if (conn.tombstone(arena, d.session, d.origin, TOMBSTONE_WAIT_MS) catch null) |r| ended = r.value.found;
        } else |_| {}
        if (ended) {
            _ = retireDescriptor(arena, index_dir, d, &claimed, lp);
        } else claimed.release(lp, false);
    }
}

/// Whether an agent that ended can be started again with its launch
/// settings, resuming its conversation (`agent_attach relaunch`).
pub fn canRelaunch(loaded: *const adapter.Loaded, binary: []const u8, cwd: []const u8, conversed: bool, conversation: ?[]const u8) bool {
    if (binary.len == 0 or cwd.len == 0) return false;
    return switch (loaded.spec.source) {
        .screen => !conversed or (conversation != null and loaded.spec.launch.resume_args.len > 0),
        .opencode_api => true,
    };
}

pub fn descRelaunchable(d: Descriptor) bool {
    const loaded = (adapters() catch return false).get(d.app) orelse return false;
    if (d.transport) |t| if (std.meta.stringToEnum(Transport, t) == null) return false;
    return canRelaunch(loaded, d.binary, d.cwd, d.conversed, d.conversation);
}

/// Descriptor `d`'s sessions are gone: it stays, stamped `gone_ms`, while it
/// can be relaunched, else it leaves the index with its lock. `claimed` is
/// released either way.
/// @return whether it was kept.
fn retireDescriptor(arena: std.mem.Allocator, index_dir: []const u8, d: Descriptor, claimed: *agentindex.Claim, lp: []const u8) bool {
    if (descRelaunchable(d)) {
        if (d.gone_ms == 0) {
            var kept = d;
            kept.gone_ms = clock.wallMs();
            // Unstamped, the descriptor never ages out of the index (the
            // next sweep retries the stamp): say why it lingers.
            agentindex.write(arena, index_dir, kept) catch |err|
                mcp.warn("agent {s}: could not stamp its descriptor gone ({s}); it stays in the index until a later sweep stamps it", .{ d.id, @errorName(err) });
        }
        claimed.release(lp, false);
        return true;
    }
    agentindex.remove(arena, index_dir, d.id);
    claimed.release(lp, true);
    return false;
}

/// Publish into the MCP registry record (`mcp_registry.Lease`) so a viewer
/// on any host can find the agents: set by `mcp.zig` before `reattach`.
pub fn publishTo(lease: ?*mcp_registry.Lease) void {
    state.registry = lease;
    const l = lease orelse return;
    // Where a client's plugin follows this server's agents (`agent-wait
    // --parent`); published with the (still empty) agent list.
    if (state.waiter.path) |p| l.setAgentSocket(p) catch {};
    publishAgents();
}

/// Rewrite the registry record's agent list from `state.entries`: called
/// after every open, attach, close, relaunch and the startup reattach.
/// Best effort: a failed rewrite leaves the previous list, never the server.
pub fn publishAgents() void {
    const lease = state.registry orelse return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(mcp_registry.Agent) = .empty;
    for (state.entries.items) |e| {
        var sessions: std.ArrayList([]const u8) = .empty;
        sessions.append(arena, e.session) catch return;
        if (e.server_session) |s| sessions.append(arena, s) catch return;
        // The term's own fact: it runs on a host's daemon, on this host's
        // per-user daemon, or on our private one (a term_open terminal, a
        // legacy durable agent). `ssh:box` is reached at `box`.
        const remote: ?[]const u8 = if (e.visibleTerm() orelse e.server) |t| t.remote_host else null;
        const where: sshroute.Location = if (remote) |h|
            .{ .host = if (sshroute.RemoteSpec.parse(h).mode == .ssh) sshroute.RemoteSpec.parse(h).host else h }
        else if (e.socket) |s|
            (if (state.mux_sock != null and std.mem.eql(u8, s, state.mux_sock.?)) .instance else .user)
        else
            .instance;
        var buf: [300]u8 = undefined;
        const location = arena.dupe(u8, where.format(&buf) catch continue) catch return;
        out.append(arena, .{ .id = e.id, .app = e.loaded.spec.id, .sessions = sessions.items, .location = location }) catch return;
    }
    lease.publishAgents(out.items) catch {};
}

fn originOf(s: ?[]const u8) !wire.SessionOriginId {
    const v = s orelse return error.BadDescriptor;
    if (!wire.validSessionOriginId(v)) return error.BadDescriptor;
    var id: wire.SessionOriginId = undefined;
    @memcpy(&id, v);
    return id;
}

/// What `reattachOne` has acquired so far, released together on failure.
const Parts = struct {
    vis: ?*termdrive.Term = null,
    server: ?*termdrive.Term = null,
    forward: ?*termdrive.Term = null,
    pw: ?[]u8 = null,
    ag: ?*agent_mod.Agent = null,
    ag_live: bool = false,

    fn release(self: *Parts, a: std.mem.Allocator) void {
        if (self.ag) |x| {
            if (self.ag_live) x.deinit();
            a.destroy(x);
        }
        if (self.pw) |p| {
            std.crypto.secureZero(u8, p);
            a.free(p);
        }
        if (self.forward) |x| x.deinit();
        if (self.server) |x| x.detach();
        if (self.vis) |x| x.detach();
        self.* = .{};
    }
};

/// Why a session could not be attached: `gone` when its daemon answered
/// that it does not exist (with the daemon's record of its end, when it
/// keeps one), `unreachable` when the host or its daemon did not answer.
const AttachWhy = struct {
    kind: enum { gone, unreachable_host } = .gone,
    msg: []const u8 = "",
    session: []const u8 = "",
    tomb: ?tombstones.Reply = null,
};

/// Attach session `name` where a descriptor says it runs: the remote
/// host's own daemon (over ssh, reattached on loss), else the local daemon
/// at `socket`.
fn attachSession(arena: std.mem.Allocator, transport: Transport, host: ?[]const u8, socket: ?[]const u8, name: []const u8, origin: ?[]const u8, why: *AttachWhy) !*termdrive.Term {
    const a = state.allocator;
    const id = try originOf(origin);
    const remote = transport == .@"sketerm-mux";
    why.session = name;
    var conn = if (remote)
        muxconnect.connectSsh(a, host orelse return error.BadDescriptor) catch {
            const said = muxclient.sshUnreachable();
            why.* = .{ .kind = .unreachable_host, .session = name, .msg = if (said.len > 0) try arena.dupe(u8, said) else try sshDiagnose(arena, host.?) };
            return error.Unreachable;
        }
    else blk: {
        const sock = socket orelse return error.NoDaemon;
        // The per-user daemon is started when it is down: the new one
        // adopts the session workers the old one left running.
        const default_sock = sockpath.defaultSocketPath(arena) catch "";
        const per_user = std.mem.eql(u8, default_sock, sock);
        break :blk (if (per_user) muxclient.Conn.connectLocalAutostartAt(a, null) else muxclient.Conn.connectProbed(a, sock)) catch {
            why.* = .{ .kind = .gone, .session = name, .msg = "the daemon that held it is not running, and none could be started" };
            return error.SessionGone;
        };
    };
    conn.setNonBlocking();
    conn.last_err_len = 0;
    if (termdrive.Term.attachVia(a, &conn, name, id, if (remote) host else null)) |t| return t else |_| {}
    defer conn.deinit();
    if (conn.last_err_len == 0) {
        why.* = .{ .kind = .unreachable_host, .session = name, .msg = "its daemon did not answer the attach in time" };
        return error.Unreachable;
    }
    // The daemon answered: no such session (lifetime). Ask it why.
    why.* = .{ .kind = .gone, .session = name, .msg = try arena.dupe(u8, conn.last_err[0..conn.last_err_len]) };
    why.tomb = askWhyGone(&conn, arena, name, origin.?);
    return error.SessionGone;
}

/// A daemon refused to attach session `name` (lifetime `origin`), so it does
/// not have it: why it ended, from its tombstone, or null when it keeps no
/// record (an older daemon, or a fresh one after a reboot). The one rule of
/// agent_attach and of a lost link's reconnect.
pub fn askWhyGone(conn: *muxclient.Conn, arena: std.mem.Allocator, name: []const u8, origin: []const u8) ?tombstones.Reply {
    const r = (conn.tombstone(arena, name, origin, TOMBSTONE_WAIT_MS) catch return null) orelse return null;
    return if (r.value.found) r.value else null;
}

/// Pick a running agent up from descriptor `d`, holding `claim` (moved into
/// the entry on success): every session attached, the API reconnected, a
/// remote API agent's forward re-created on a free local port.
fn reattachOne(arena: std.mem.Allocator, d: Descriptor, claim: ?agentindex.Claim, why: *AttachWhy) !*Entry {
    const a = state.allocator;
    const loaded = (try adapters()).get(d.app) orelse return error.UnknownAdapter;
    const transport: Transport = if (d.transport) |s| std.meta.stringToEnum(Transport, s) orelse return error.BadDescriptor else .local;
    if (transport != .local and d.host == null) return error.BadDescriptor;
    const extra = launch.Extra{ .args = d.args, .server_args = d.server_args, .tui_args = d.tui_args, .env = d.env, .path_prepend = d.path_prepend, .login_shell = d.login_shell, .permissions = d.permissions };
    if ((try launch.checkExtra(arena, loaded.spec.launch, extra)) != null) return error.BadDescriptor;
    const socket = d.socket orelse state.mux_sock;
    var parts: Parts = .{};
    errdefer parts.release(a);
    parts.vis = try attachSession(arena, transport, d.host, socket, d.session, d.origin, why);
    var port = d.port;
    if (loaded.spec.source == .opencode_api) {
        parts.server = try attachSession(arena, transport, d.host, socket, d.server_session orelse return error.BadDescriptor, d.server_origin, why);
        parts.pw = readfile.cappedAlloc(a, d.password_file orelse return error.BadDescriptor, 4096) catch return error.BadDescriptor;
        // The forward is the attaching server's own ssh: a fresh one on a
        // free local port (the previous server's may still hold its port).
        if (d.host != null) {
            port = mcp_term.pickFreePort() orelse return error.NoFreePort;
            parts.forward = spawnForward(arena, d.id, d.host.?, port, d.remote_port) catch null;
            if (parts.forward) |f| _ = mcp_term.waitForwardReady(arena, f, port, 10_000) catch {};
        }
    }
    parts.ag = try a.create(agent_mod.Agent);
    parts.ag.?.* = switch (loaded.spec.source) {
        .screen => try agent_mod.Agent.initScreen(a, loaded, .{}),
        .opencode_api => try agent_mod.Agent.initOpencode(a, loaded, .{}, .{ .port = port, .password = parts.pw.? }),
    };
    parts.ag_live = true;

    try state.entries.ensureUnusedCapacity(a, 1);
    const e = try newEntry(loaded, d.id, d.session, d.binary, d.cwd);
    errdefer dropBare(e);
    if (d.name) |s| e.name = try a.dupe(u8, s);
    if (socket) |s| if (transport != .@"sketerm-mux") {
        e.socket = try a.dupe(u8, s);
    };
    if (d.server_session) |s| e.server_session = try a.dupe(u8, s);
    if (d.host) |h| e.host = try a.dupe(u8, h);
    if (d.conversation) |s| e.conversation = try a.dupe(u8, s);
    if (d.launch_model) |s| e.launch_model = try a.dupe(u8, s);
    if (d.launch_effort) |s| e.launch_effort = try a.dupe(u8, s);
    if (d.picked_model) |s| e.picked_model = try a.dupe(u8, s);
    if (d.facts_file) |s| e.facts_file = try a.dupe(u8, s);
    if (d.status_user) |s| e.status_user = try a.dupe(u8, s);
    e.extra = try extra.clone(a);
    e.transport = transport;
    e.conversed = d.conversed;
    e.relaunches = d.relaunches;
    e.cols = d.cols;
    e.rows = d.rows;
    e.remote_port = d.remote_port;
    if (d.started_ms > 0) e.started_ms = d.started_ms;
    // Nothing below fails: the parts move into the entry.
    e.agent = parts.ag.?;
    e.visible = .{ .owned = parts.vis.? };
    e.seen_snapshots = parts.vis.?.snapshots;
    e.server = parts.server;
    e.forward = parts.forward;
    e.port = port;
    e.password = parts.pw;
    e.claim = claim;
    parts = .{};
    state.entries.appendAssumeCapacity(e);
    setRetryPolicy(e, d.retry_on_overload);
    e.stall.set(if (d.stall_after_min > 0) d.stall_after_min else null, clock.nowMs());
    // An adopted session's past is history: it arms no turn. A server
    // whose forward is down answers once `service` brings it back.
    if (loaded.spec.source == .opencode_api) {
        const api = &e.agent.source.opencode_api;
        api.connect(d.api_session, clock.nowMs()) catch {
            // Reconnects with backoff from `service`, then resyncs the
            // session it drives.
            if (d.api_session) |sid| api.source.setRoot(sid) catch {};
            api.source.noteDisconnected(clock.nowMs(), "the app's server is not reachable yet") catch {};
            api.reconnect_at_ms = clock.nowMs() + 500;
        };
    }
    return e;
}

/// agent_attach {agent}: resume an agent of this machine's index, from any
/// server. Exactly one outcome: `reattached`, `gone` or `unreachable`.
pub fn attachIdTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const key = argStr(args, "agent").?;
    const deadline = deadlineFrom(args, ATTACH_WAIT_MS);
    const relaunch_asked = argBool(args, "relaunch");
    // This server's own hold on a gone entry moves into its relaunch: it is
    // never let go and taken again, so nothing comes between the two.
    var own_claim: ?agentindex.Claim = null;
    var kept_lp: []const u8 = "";
    defer if (own_claim) |*k| k.release(kept_lp, false);
    // And what it handed out, by content: record ids restart with the new
    // terminal, the app's reprinted past does not.
    var carried: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer carried.deinit(state.allocator);
    // Already ours: nothing to resume, unless its app ended here and the
    // caller asks to start it again.
    if (findByName(key)) |e| {
        hold(e);
        if (!relaunch_asked or !gone(e))
            return reattachedResult(arena, e, if (relaunch_asked) "already attached and not gone: relaunch only starts an agent whose session ended" else "already attached to this server");
        if (e.ended_ms == 0)
            return errRes(arena, .refused, try std.fmt.allocPrint(arena, "agent {s} ended and cannot be relaunched (no conversation to resume, or it runs on a term_open terminal); agent_open a new one", .{e.id}));
        kept_lp = try lockPath(arena, e.id);
        if (e.claim) |cl| if (cl.stillOwned(kept_lp)) {
            own_claim = cl;
            e.claim = null;
        };
        carried = e.handed.texts;
        e.handed.texts = .empty;
        // Let it go (its descriptor stays) and start it again below.
        endWaitersOf(e.id, "the agent is being relaunched");
        for (state.entries.items, 0..) |x, i| if (x == e) {
            _ = state.entries.orderedRemove(i);
            break;
        };
        e.destroy(false);
        publishAgents();
    }
    const index_dir = state.index_dir orelse
        return errRes(arena, .unavailable, "no state directory ($XDG_STATE_HOME or $HOME) to keep the agent index in");
    const d = (try agentindex.resolve(arena, index_dir, key)) orelse {
        // No longer in the index: this host's daemon may still say why it
        // ended (its tombstone knows the session name and the agent's name).
        if (try localTombstone(arena, key)) |why| return goneResult(arena, .{ .id = key, .app = "", .session = why.session, .origin = "" }, &why, false);
        var known: std.ArrayList(u8) = .empty;
        for (try agentindex.ids(arena, index_dir), 0..) |id, i| {
            if (i > 0) try known.appendSlice(arena, ", ");
            try known.appendSlice(arena, id);
            if (agentindex.read(arena, index_dir, id)) |p| if (p.value.name) |n| try known.print(arena, " ({s})", .{n});
        }
        return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "no live agent '{s}' on this machine (known: {s})", .{ key, if (known.items.len > 0) known.items else "none" }));
    };
    const lp = try lockPath(arena, d.id);
    // Only the lock of the very agent the gone entry was.
    const own = if (std.mem.eql(u8, kept_lp, lp)) own_claim else null;
    if (own != null) own_claim = null;
    var claimed = own orelse agentindex.claim(lp, argBool(args, "takeover")) catch |err| switch (err) {
        error.Held => return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} is in use by another live MCP server; agent_attach with takeover:true takes it over (that server then lets it go)", .{d.id})),
        error.LockFailed => return errRes(arena, .io_failed, "could not lock the agent in the index"),
    };
    var why: AttachWhy = .{};
    const e = reattachOne(arena, d, claimed, &why) catch |err| switch (err) {
        error.SessionGone => {
            if (relaunch_asked and descRelaunchable(d)) return relaunchFrom(arena, args, d, &claimed, lp, &why, &carried);
            const kept = retireDescriptor(arena, index_dir, d, &claimed, lp);
            return goneResult(arena, d, &why, kept);
        },
        error.Unreachable => {
            claimed.release(lp, false);
            return unreachableResult(arena, d, &why);
        },
        error.OutOfMemory => {
            claimed.release(lp, false);
            return err;
        },
        else => {
            claimed.release(lp, false);
            return errRes(arena, .failed, try std.fmt.allocPrint(arena, "agent {s} could not be resumed: {s}", .{ d.id, @errorName(err) }));
        },
    };
    hold(e);
    writeDescriptor(e);
    publishAgents();
    // A screen source folds turns only at a turn end: fold the transcript
    // the attach snapshot shows now, so its latest job can be returned.
    if (waitReady(e, deadline)) try e.agent.syncHistory();
    return reattachedResult(arena, e, if (relaunch_asked) "its session was still running: reattached, not relaunched" else null);
}

/// agent_attach relaunch: start a gone agent again from descriptor `d`
/// with its launch settings, resuming its conversation, under the same id
/// and name. `claimed` moves into the agent; on a failure it is released
/// and the descriptor stays, so the relaunch can be tried again.
/// `handed` (moved in on success) is what a gone entry of this server handed out.
fn relaunchFrom(arena: std.mem.Allocator, args: std.json.Value, d: Descriptor, claimed: *agentindex.Claim, lp: []const u8, gone_why: *const AttachWhy, handed: *std.AutoHashMapUnmanaged(u64, void)) ![]const u8 {
    const loaded = (try adapters()).get(d.app).?;
    const transport: Transport = if (d.transport) |s| std.meta.stringToEnum(Transport, s).? else .local;
    var o = OpenOpts{
        .override = d.binary,
        .model = d.launch_model,
        .effort = d.launch_effort,
        .cwd = d.cwd,
        .prompt = null,
        // The conversation it had: a screen app's only once it had a turn
        // (a fresh one starts afresh), an API source's session always.
        .resume_id = switch (loaded.spec.source) {
            .screen => if (d.conversed) d.conversation else null,
            .opencode_api => d.api_session,
        },
        .cols = d.cols,
        .rows = d.rows,
        .host = d.host,
        .choice = switch (transport) {
            .local => .auto,
            .ssh => .ssh,
            .@"sketerm-mux" => .mux,
        },
        .extra = .{ .args = d.args, .server_args = d.server_args, .tui_args = d.tui_args, .env = d.env, .path_prepend = d.path_prepend, .login_shell = d.login_shell, .permissions = d.permissions },
        .retry = d.retry_on_overload,
        .stall = if (d.stall_after_min > 0) d.stall_after_min else null,
        .name = d.name,
        .keep_id = d.id,
        .handed = handed,
    };
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    var claim: ?agentindex.Claim = claimed.*;
    var facts: LaunchFacts = .{};
    var why: Fail = undefined;
    const st = startAgent(arena, loaded, &o, &claim, .{ .fresh_login = argBool(args, "fresh_login"), .spawn = deadline, .ready = deadline }, &facts, &why) catch |err| {
        if (claim) |*cl| cl.release(lp, false);
        return switch (err) {
            error.Refused => errRes(arena, why.code, try std.fmt.allocPrint(arena, "agent {s} is gone and could not be relaunched: {s}", .{ d.id, why.msg })),
            else => err,
        };
    };
    const e = st.entry;
    var notes = st.notes;
    // A model chosen in the app since the launch is not a launch value.
    if (st.ready) if (d.picked_model) |m| {
        if (try applySet(arena, e, .{ .set_model = m }, deadline)) |f| try notes.append(arena, try std.fmt.allocPrint(arena, "the model chosen before ({s}) was not chosen again: {s}", .{ m, f.msg }));
    };
    var res = Res.init(arena);
    try res.fact("attach", "relaunched");
    try res.textf("relaunched {s}{s}{s}{s}: its session had ended ({s}), so it was started again with its launch settings{s}", .{
        e.id,
        if (e.name != null) " (" else "",
        e.name orelse "",
        if (e.name != null) ")" else "",
        if (gone_why.tomb) |tb| (if (tb.reason) |r| @tagName(r) else "reason unknown") else "reason unknown",
        if (o.resume_id != null) ", resuming its conversation" else "",
    });
    if (!st.ready) try res.textf("not ready yet (state {s}); agent_send waits for it", .{@tagName(e.agent.state())});
    for (notes.items) |n| try res.text(n);
    try res.fact("binary", e.binary);
    try res.fact("cwd", e.cwd);
    return finish(arena, &res, e, try pending(arena, e), .{}, &.{});
}

/// A resumed agent with its latest job selection, as a first read returns
/// it (nothing was handed to this server yet).
fn reattachedResult(arena: std.mem.Allocator, e: *Entry, note: ?[]const u8) ![]const u8 {
    var res = Res.init(arena);
    try res.fact("attach", "reattached");
    try res.textf("reattached {s}{s}{s}{s}", .{ e.id, if (e.name != null) " (" else "", e.name orelse "", if (e.name != null) ")" else "" });
    if (note) |n| try res.text(n);
    const recs = e.agent.records();
    const jobs = try select.jobsAfter(arena, recs, 0);
    const latest: []const u32 = if (jobs.len > 0) jobs[jobs.len - 1 ..] else &.{};
    const sel = try select.select(arena, recs, latest, .{ .handed = &e.handed });
    try e.handed.markSelection(e.allocator, recs, sel);
    const body = try writeSelection(arena, &res, recs, sel);
    const blocks = [1]Block{.{ .name = "records", .body = body }};
    return finish(arena, &res, e, try pending(arena, e), .{}, blocks[0..@intFromBool(sel.jobs.len > 0)]);
}

/// What this host's per-user daemon remembers about the end of agent `key`
/// (its name, or the id of its session `agent-<key>`); null when nothing.
fn localTombstone(arena: std.mem.Allocator, key: []const u8) !?AttachWhy {
    const sock = state.user_sock orelse return null;
    var conn = muxclient.Conn.connectProbed(arena, sock) catch return null;
    defer conn.deinit();
    conn.setNonBlocking();
    const session = try std.fmt.allocPrint(arena, "agent-{s}", .{key});
    for ([_][]const u8{ session, key }) |name| {
        const r = (conn.tombstone(arena, name, "", TOMBSTONE_WAIT_MS) catch return null) orelse return null;
        if (r.value.found) return .{ .kind = .gone, .session = r.value.name, .tomb = r.value };
    }
    return null;
}

/// @param relaunchable its descriptor stays: `relaunch: true` starts it again.
fn goneResult(arena: std.mem.Allocator, d: Descriptor, why: *const AttachWhy, relaunchable: bool) ![]const u8 {
    var res = Res.init(arena);
    try res.fact("attach", "gone");
    try res.fact("agent", d.id);
    try res.fact("relaunchable", relaunchable);
    if (d.name) |n| try res.fact("name", n);
    try res.fact("session", why.session);
    if (d.host) |h| try res.fact("host", h);
    const reason: []const u8 = if (why.tomb) |tb| (if (tb.reason) |r| @tagName(r) else "unknown") else "unknown";
    try res.fact("reason", reason);
    if (why.tomb) |tb| {
        try res.fact("ended_ms", tb.ended_ms);
        if (tb.exit_status) |s| try res.fact("exit_status", s);
        if (tb.signal) |s| try res.fact("signal", s);
    }
    const g = GoneFacts.of(why.tomb);
    const detail: []const u8 = if (g.reason == .exited)
        (if (g.signal) |s| try std.fmt.allocPrint(arena, "its app was killed by signal {d}", .{s}) else try std.fmt.allocPrint(arena, "its app exited with status {d}", .{g.exit_status orelse 0}))
    else
        goneDetail(g);
    try res.textf("agent {s} is gone: {s}", .{ d.id, detail });
    if (why.msg.len > 0) try res.textf("the daemon said: {s}", .{why.msg});
    if (relaunchable)
        try res.textf("agent_attach with agent \"{s}\" and relaunch: true starts it again with its launch settings, resuming its conversation, under the same id and name", .{d.name orelse d.id})
    else
        try res.text("it is not in the agent index (any more); agent_open starts a new one");
    return res.finish();
}

fn unreachableResult(arena: std.mem.Allocator, d: Descriptor, why: *const AttachWhy) ![]const u8 {
    var res = Res.init(arena);
    try res.fact("attach", "unreachable");
    try res.fact("agent", d.id);
    if (d.name) |n| try res.fact("name", n);
    try res.fact("session", why.session);
    try res.fact("host", d.host orelse "this machine");
    try res.fact("ssh_error", why.msg);
    try res.textf("agent {s} could not be reached on {s}: {s}", .{ d.id, d.host orelse "this machine", why.msg });
    try res.text("it may still run there: agent_attach again once the host answers (its entry stays in the index)");
    return res.finish();
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_agent_testkit = @import("mcp_agent_testkit.zig");
const restartOf = mcp_agent.restartOf;
const ToolRig = mcp_agent_testkit.ToolRig;

test "a relaunch and a durable descriptor keep the caller's args and env" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    const set = try adapters();
    const e = try newEntry(set.get("claude").?, "claude-1", "agent-claude-1", "/opt/wrap", "/srv");
    defer dropBare(e);
    const x = launch.Extra{
        .args = &.{ "--profile", "a b 'c' \"d\" $e ;f `g` *h" },
        .env = &.{.{ .name = "CLAUDE_CAPTURE_PROFILE", .value = "w o'rk $x" }},
    };
    e.extra = try x.clone(state.allocator);

    // The relaunch: the same args right after the binary, before the
    // adapter's own and the resumed conversation; the env still spared
    // from CLAUDE* and still set by the spawn.
    const r = try restartOf(a, e, null, "low", "u-1", .resumed);
    const want = [_][]const u8{ "/opt/wrap", x.args[0], x.args[1], "--ax-screen-reader", "--resume", "u-1", "--effort", "low" };
    try testing.expectEqualStrings("/bin/sh", r.argv[0]);
    try testing.expectEqual(want.len, r.argv.len - 4);
    for (want, r.argv[4..]) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expect(std.mem.indexOf(u8, r.argv[2], "case \"$n\" in CLAUDE_CAPTURE_PROFILE|") != null);
    try testing.expectEqual(@as(usize, 1), r.spec.extra.env.len);
    try testing.expectEqualStrings("w o'rk $x", r.spec.extra.env[0].value);
    try testing.expectEqualStrings("agent-claude-1", r.spec.name);

    // The descriptor carries them through a restart of this server, byte
    // for byte, and the reattached entry validates them again.
    const path = try std.fmt.allocPrint(a, "{s}/agents/claude-1.json", .{rig.dir.path()});
    const d = Descriptor{ .id = e.id, .app = "claude", .session = e.session, .origin = "o", .binary = e.binary, .args = e.extra.args, .env = e.extra.env };
    try atomicwrite.writeJsonExact(a, path, d, 0o600);
    const parsed = readfile.json(Descriptor, testing.allocator, path, DESCRIPTOR_MAX_BYTES) orelse return error.TestUnexpectedResult;
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.args.len);
    for (x.args, parsed.value.args) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqualStrings("CLAUDE_CAPTURE_PROFILE", parsed.value.env[0].name);
    try testing.expectEqualStrings(x.env[0].value, parsed.value.env[0].value);
    try testing.expect((try launch.checkExtra(a, set.get("claude").?.spec.launch, .{ .args = parsed.value.args, .env = parsed.value.env })) == null);
    // One written before args/env existed reads as none.
    const old = try std.json.parseFromSlice(Descriptor, testing.allocator, "{\"id\":\"claude-1\",\"app\":\"claude\",\"session\":\"s\",\"origin\":\"o\",\"binary\":\"/x\"}", .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer old.deinit();
    try testing.expectEqual(@as(usize, 0), old.value.args.len);
    try testing.expectEqual(@as(usize, 0), old.value.env.len);
}

test "a gone descriptor stays for a relaunch only when it can be started again" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    const dir = state.index_dir.?;
    const cases = [_]struct { d: Descriptor, keep: bool }{
        // A conversation to resume: kept.
        .{ .d = .{ .id = "claude-k3f9", .app = "claude", .session = "agent-claude-k3f9", .origin = "o", .binary = "/bin/claude", .cwd = "/", .conversed = true, .conversation = "c-1" }, .keep = true },
        // Never prompted: kept, it starts afresh.
        .{ .d = .{ .id = "claude-k3fa", .app = "claude", .session = "agent-claude-k3fa", .origin = "o", .binary = "/bin/claude", .cwd = "/" }, .keep = true },
        // A turn but no conversation id, an unknown adapter, no binary: gone for good.
        .{ .d = .{ .id = "claude-k3fb", .app = "claude", .session = "s", .origin = "o", .binary = "/bin/claude", .cwd = "/", .conversed = true }, .keep = false },
        .{ .d = .{ .id = "nope-k3fc", .app = "nope", .session = "s", .origin = "o", .binary = "/bin/x", .cwd = "/" }, .keep = false },
        .{ .d = .{ .id = "opencode-k3fd", .app = "opencode", .session = "s", .origin = "o", .cwd = "/" }, .keep = false },
    };
    for (cases) |cs| {
        try agentindex.write(a, dir, cs.d);
        const lp = try lockPath(a, cs.d.id);
        var cl = try agentindex.claim(lp, false);
        try testing.expectEqual(cs.keep, retireDescriptor(a, dir, cs.d, &cl, lp));
        const back = agentindex.read(a, dir, cs.d.id);
        try testing.expectEqual(cs.keep, back != null);
        if (back) |p| try testing.expect(p.value.gone_ms > 0);
        // The claim is released either way.
        var again = try agentindex.claim(lp, false);
        again.release(lp, true);
    }
}
