//! The server loop's view of the agents: `pollFds`/`dueInMs`/`service`
//! between requests, and `pump` plus the waits every tool call runs on
//! it (`waitReady`, `waitAny`, `settleOf`, ...); the background
//! reconnection of lost remote links (`ReconnectJob`), forwards, the
//! resumed-history window, retry on overload and `sweep`.

const std = @import("std");
const c = @import("../c.zig").c;
const mcp = @import("mcp.zig");
const mcp_term = @import("mcp_term.zig");
const termdrive = @import("termdrive.zig");
const agentwait = @import("agentwait.zig");
const adapter = @import("../agent/adapter.zig");
const events = @import("../agent/events.zig");
const vocab = @import("../agent/vocab.zig");
const screen_source = @import("../agent/screen_source.zig");
const wire = @import("../mux/wire.zig");
const Screen = @import("../grid/screen.zig").Screen;
const clock = @import("../util/clock.zig");
const agent_mod = @import("../agent/agent.zig");
const stall = @import("../agent/stall.zig");
const muxconnect = @import("muxconnect.zig");
const muxclient = @import("../mux/client.zig");

const mcp_agent = @import("mcp_agent.zig");
const mcp_agent_hosts = @import("mcp_agent_hosts.zig");
const mcp_agent_waiter = @import("mcp_agent_waiter.zig");
const mcp_agent_index = @import("mcp_agent_index.zig");
const mcp_agent_act = @import("mcp_agent_act.zig");

const STEP_WAIT_MS = mcp_agent.STEP_WAIT_MS;
const DELIVERY_CONFIRM_MS = mcp_agent.DELIVERY_CONFIRM_MS;
const RECONNECT_MIN_MS = mcp_agent.RECONNECT_MIN_MS;
const RECONNECT_MAX_MS = mcp_agent.RECONNECT_MAX_MS;
const Entry = mcp_agent.Entry;
const GoneFacts = mcp_agent.GoneFacts;
const hold = mcp_agent.hold;
const state = &mcp_agent.state;
const lockPath = mcp_agent.lockPath;
const serviceHostProbes = mcp_agent_hosts.serviceHostProbes;
const servicePush = mcp_agent_waiter.servicePush;
const endWaitersOf = mcp_agent_waiter.endWaitersOf;
const writeDescriptor = mcp_agent_index.writeDescriptor;
const removeDescriptor = mcp_agent_index.removeDescriptor;
const canRelaunch = mcp_agent_index.canRelaunch;
const publishAgents = mcp_agent_index.publishAgents;
const askWhyGone = mcp_agent_index.askWhyGone;
const submitPrompt = mcp_agent_act.submitPrompt;

/// A screen engine's settle rules need ticks while something is pending.
const TICK_MS: i64 = 250;
/// How often a dead forward is respawned / a lost link retried.
const FORWARD_RETRY_MS: i64 = 3_000;
/// How often `sweep` checks that this server still owns its agents.
const SWEEP_EVERY_MS: i64 = 1_000;
/// The exit status ssh reports for a lost connection.
const SSH_LOST_STATUS: i32 = 255;

// ── the server loop's view ───────────────────────────────────────

/// What a screen agent's terminal shows now, for `observeScreen`.
pub const Observation = struct {
    screen: ?*const Screen,
    /// The mirror was replaced wholesale since the last observation.
    resynced: bool = false,
    exited: bool = false,
    exit_status: ?i32 = null,
};

/// Hand one observation to a screen engine. Everything the engine
/// decides comes from the content, so an observation made late (the loop
/// was busy while the app drew a whole turn) reads the same as a stream
/// of early ones.
pub fn observeScreen(e: *screen_source.Engine, o: Observation, now_ms: i64) !void {
    if (o.resynced) e.noteResync();
    if (o.screen) |s| try e.feed(s, now_ms) else try e.tick(now_ms);
    if (o.exited) try e.noteExited(now_ms, o.exit_status);
}

/// Every fd the loop should wake for: agent terminals, API streams and
/// requests, the waiter socket and its clients.
pub fn pollFds(out: []c.struct_pollfd) usize {
    var n: usize = 0;
    for (state.entries.items) |e| {
        if (e.visibleTerm()) |t| n = addFd(out, n, t);
        if (e.server) |t| n = addFd(out, n, t);
        if (e.forward) |t| n = addFd(out, n, t);
        switch (e.agent.source) {
            .opencode_api => |*api| n += api.pollFds(out[n..]),
            .screen => {},
        }
    }
    n += state.waiter.pollFds(out[n..]);
    return n;
}

fn addFd(out: []c.struct_pollfd, n: usize, t: *termdrive.Term) usize {
    if (t.exited or n >= out.len) return n;
    out[n] = .{ .fd = t.conn.fd, .events = c.POLLIN, .revents = 0 };
    return n + 1;
}

/// Milliseconds until `service` must run without fd activity, or null.
pub fn dueInMs(now_ms: i64) ?i64 {
    var due: ?i64 = null;
    for (state.entries.items) |e| {
        const d: ?i64 = switch (e.agent.source) {
            .screen => |*eng| if (screenNeedsTick(eng)) TICK_MS else eng.backgroundDueIn(now_ms),
            .opencode_api => |*api| api.serviceDueIn(now_ms),
        };
        if (d) |x| due = if (due) |y| @min(x, y) else x;
        if (e.retry.due_ms) |at| {
            const x = @max(0, at - now_ms);
            due = if (due) |y| @min(x, y) else x;
        }
        if (e.stall.dueIn(e.agent.state(), e.agent.lastActivityMs(), now_ms)) |x| due = if (due) |y| @min(x, y) else x;
        if (e.forward) |f| if (f.exited) {
            const x = @max(0, e.forward_retry_ms - now_ms);
            due = if (due) |y| @min(x, y) else x;
        };
        for ([_]?*termdrive.Term{ e.visibleTerm(), e.server }) |o| if (o) |t| if (t.lost and !inFlight(t)) {
            const x = @max(0, e.reconnect_ms - now_ms);
            due = if (due) |y| @min(x, y) else x;
        };
    }
    // A reconnect thread cannot wake the loop: look at it often.
    if (state.reconnects.items.len > 0) due = if (due) |y| @min(TICK_MS, y) else TICK_MS;
    if (state.waiter.dueIn(now_ms)) |x| due = if (due) |y| @min(x, y) else x;
    return due;
}

fn screenNeedsTick(e: *const screen_source.Engine) bool {
    if (e.exited or e.disconnected) return false;
    // Idle with background tasks needs no ticks: their line changing is
    // output, and the cap is a deadline (`backgroundDueIn`).
    return !e.ready or e.end_pending or e.lone_bell or e.retry_since_ms != null or (e.state != .idle and e.state != .waiting_background);
}

/// Read every agent's sources and deliver waiter wake-ups. Never blocks:
/// a lost remote link is retried by a background thread.
pub fn service(now_ms: i64) void {
    serviceReconnects(now_ms);
    for (state.entries.items) |e| {
        if (serviceEntry(e, now_ms)) |_| {
            e.service_failed = null;
        } else |err| noteServiceFailure(e, err);
        kickReconnects(e, now_ms);
        // An agent that ended is no longer one to resume; one that can be
        // started again keeps its descriptor for `agent_attach relaunch`.
        if (e.indexed and !e.relaunching and e.ended_ms == 0 and gone(e)) {
            if (canRelaunch(e.loaded, e.binary, e.cwd, e.conversed, e.conversation)) {
                e.ended_ms = clock.wallMs();
                writeDescriptor(e);
            } else removeDescriptor(e);
        }
    }
    // What the app took out of its queue is no longer sketerm's to retype.
    for (state.entries.items) |e| {
        const held = e.agent.queuedPrompts();
        if (e.queued_sent.items.len > held) e.dropQueued(e.queued_sent.items.len - held);
    }
    for (state.entries.items) |e| if (e.history) {
        if (e.agent.uptake().turns > e.history_turns) e.history = false else foldHistory(e);
    };
    serviceRetries(now_ms);
    for (state.entries.items) |e| {
        // A relaunch swaps the terminal: its silence is the adapter's.
        if (e.relaunching) continue;
        const act = e.agent.lastActivityMs();
        if (!e.stall.isDue(e.agent.state(), act, now_ms)) continue;
        var arena_state = std.heap.ArenaAllocator.init(state.allocator);
        defer arena_state.deinit();
        const last = stallLast(arena_state.allocator(), e.agent, act) catch stall.Tracker.Last{};
        _ = e.stall.check(e.agent.queue(), e.agent.state(), act, now_ms, last) catch {};
    }
    servicePush(now_ms);
    serviceHostProbes(now_ms);
    state.waiter.service(now_ms);
}

// ── retry on overload ────────────────────────────────────────────

/// Advance every agent's `retry_on_overload` episode and type a due
/// continue prompt. Not while a retry is typing one (its recipe pumps
/// this loop).
fn serviceRetries(now_ms: i64) void {
    if (state.retry_busy) return;
    for (state.entries.items) |e| serviceRetry(e, now_ms) catch |err| {
        // Held events wake nobody: a retry that cannot run must release
        // them, or the overload error and its done never reach the caller.
        e.retry.abandon(e.agent.queue());
        mcp.warn("agent {s}: retry_on_overload failed ({s}) and was abandoned", .{ e.id, @errorName(err) });
        var buf: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "retry_on_overload failed ({s}) and was abandoned", .{@errorName(err)}) catch continue;
        e.agent.addNotice(text) catch {};
    };
}

fn serviceRetry(e: *Entry, now_ms: i64) !void {
    if (e.retry.policy == null and !e.retry.active) return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = e.agent.queue();
    const prompt = e.loaded.spec.retry.prompt;
    while (true) {
        const note: []const u8 = switch (e.retry.next(q, now_ms)) {
            .none => break,
            .scheduled => |s| try std.fmt.allocPrint(arena, "the turn ended on a provider overload ({s}): retry {d} of {d}, sending \"{s}\" in {d} s (retry_on_overload)", .{ events.preview(s.text), s.attempt, s.max, prompt, @divTrunc(s.delay_ms, 1000) }),
            .recovered => |r| try std.fmt.allocPrint(arena, "the turn went on after {d} retr{s} on overload (retry_on_overload)", .{ r.attempts, if (r.attempts == 1) "y" else "ies" }),
            .gave_up => |g| switch (g.why) {
                .exhausted => try std.fmt.allocPrint(arena, "retry_on_overload gave up: the provider was still overloaded after {d} retr{s} in this job", .{ g.attempts, if (g.attempts == 1) "y" else "ies" }),
                .other_error, .exited, .off => try std.fmt.allocPrint(arena, "retry_on_overload stopped after {d} retr{s}: {s}", .{ g.attempts, if (g.attempts == 1) "y" else "ies", switch (g.why) {
                    .other_error => "the continued turn ended on another error",
                    .exited => "the app is gone",
                    else => "it was turned off",
                } }),
            },
        };
        e.agent.addNotice(note) catch {};
    }
    const due = e.retry.due_ms orelse return;
    if (now_ms < due or e.acting > 0 or e.relaunching or gone(e) or !e.agent.state().takesPrompt()) return;
    state.retry_busy = true;
    defer state.retry_busy = false;
    const from = q.next_seq;
    switch (try submitPrompt(arena, e, .{ .text = prompt }, clock.nowMs() + STEP_WAIT_MS, true)) {
        .ok => e.retry.sent(from),
        .fail => |f| {
            e.retry.abandon(q);
            e.agent.addNotice(try std.fmt.allocPrint(arena, "retry_on_overload could not send \"{s}\": {s}", .{ prompt, f.msg })) catch {};
        },
    }
}

// ── takeover sweep ───────────────────────────────────────────────

/// Between requests: drop the agents another server took over (`agent_attach
/// takeover`), detaching them. Never inside a tool call: it frees entries.
pub fn sweep(now_ms: i64) void {
    if (now_ms - state.last_sweep_ms < SWEEP_EVERY_MS) return;
    state.last_sweep_ms = now_ms;
    var i: usize = 0;
    while (i < state.entries.items.len) {
        const e = state.entries.items[i];
        if (e.claim) |*cl| {
            var buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const lp = lockPath(fba.allocator(), e.id) catch {
                i += 1;
                continue;
            };
            if (!cl.stillOwned(lp)) {
                endWaitersOf(e.id, "the agent was taken over by another MCP server");
                _ = state.entries.orderedRemove(i);
                e.destroy(false);
                publishAgents();
                continue;
            }
        }
        i += 1;
    }
}

// ── background reconnection ──────────────────────────────────────

/// One background reattach of a lost remote-mux session: the thread
/// connects and attaches, `serviceReconnects` hands the result to the Term
/// on the server loop. Only the loop frees a job, and only once its thread
/// is done, so an abandoned job never races its own teardown.
pub const ReconnectJob = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    name: []u8,
    origin: wire.SessionOriginId,
    /// Null once the Term went away: the result is dropped.
    term: ?*termdrive.Term,
    done: std.atomic.Value(bool) = .init(false),
    conn: ?muxclient.Conn = null,
    snapshot: ?[]u8 = null,
    /// The host's daemon answered, and has no such session (any more):
    /// what its tombstone says. Never set when the host did not answer.
    gone: ?GoneFacts = null,

    fn run(self: *ReconnectJob) void {
        defer self.done.store(true, .release);
        const a = self.allocator;
        var conn = muxconnect.connectSshOnce(a, self.host) catch return;
        conn.setNonBlocking();
        conn.last_err_len = 0;
        conn.sendAttach(self.name, .{ .origin_id = &self.origin, .kind = "mcp" }) catch return conn.deinit();
        const snap = conn.recvExpectFor(&.{.snapshot}, 15_000) catch {
            if (conn.last_err_len > 0) {
                var arena_state = std.heap.ArenaAllocator.init(a);
                defer arena_state.deinit();
                self.gone = GoneFacts.of(askWhyGone(&conn, arena_state.allocator(), self.name, &self.origin));
            }
            return conn.deinit();
        };
        defer snap.deinit(a);
        self.snapshot = a.dupe(u8, snap.payload) catch return conn.deinit();
        self.conn = conn;
    }

    fn free(self: *ReconnectJob) void {
        const a = self.allocator;
        if (self.conn) |*conn| conn.deinit();
        if (self.snapshot) |s| a.free(s);
        a.free(self.host);
        a.free(self.name);
        a.destroy(self);
    }
};

fn inFlight(t: *const termdrive.Term) bool {
    for (state.reconnects.items) |j| if (j.term == t) return true;
    return false;
}

/// `t` is going away: a reconnect still running for it is dropped.
pub fn abandonReconnect(t: *const termdrive.Term) void {
    for (state.reconnects.items) |j| if (j.term == t) {
        j.term = null;
    };
}

fn entryOfTerm(t: *const termdrive.Term) ?*Entry {
    for (state.entries.items) |e| {
        if (e.visibleTerm() == t or e.server == t) return e;
    }
    return null;
}

/// Hand finished reconnects to their terminals (the link is back: the
/// screen engine sees a resync and reports `connection_restored`).
pub fn serviceReconnects(now_ms: i64) void {
    var i: usize = 0;
    while (i < state.reconnects.items.len) {
        const j = state.reconnects.items[i];
        if (!j.done.load(.acquire)) {
            i += 1;
            continue;
        }
        _ = state.reconnects.swapRemove(i);
        if (j.term) |t| {
            if (j.conn) |conn| {
                t.adoptReattached(conn, j.snapshot.?);
                j.conn = null;
                if (entryOfTerm(t)) |e| e.reconnect_delay_ms = RECONNECT_MIN_MS;
            } else if (j.gone) |g| goneOnReconnect(t, g, j.host, now_ms);
        }
        j.free();
    }
}

/// A reconnect reached `t`'s daemon and it has no such session (the host
/// rebooted, the session was closed or expired meanwhile): the link is not
/// what is lost, so retrying stops, and an agent whose app ran there is
/// over, with one `exited` saying why.
fn goneOnReconnect(t: *termdrive.Term, g: GoneFacts, host: []const u8, now_ms: i64) void {
    t.markGone(g.exit_status);
    const e = entryOfTerm(t) orelse return;
    // An API source's attached TUI is not the agent: its server is.
    const main = switch (e.agent.source) {
        .screen => e.visibleTerm() == t,
        .opencode_api => e.server == t,
    };
    if (!main) return;
    e.gone_why = g;
    var buf: [512]u8 = undefined;
    const why = std.fmt.bufPrint(&buf, "the agent's session is gone from {s}'s daemon (reason {s}: {s}); it reconnected to find no such session", .{
        host, g.reasonName(), goneDetail(g),
    }) catch "the agent's session is gone from its daemon";
    e.agent.noteGone(now_ms, why) catch {};
}

/// What a gone session's reason means, in words.
pub fn goneDetail(g: GoneFacts) []const u8 {
    const r = g.reason orelse return "its daemon keeps no record of it (a daemon started fresh, after a reboot, or an older one)";
    return switch (r) {
        .expired => "it had no client attached for its idle lifetime (mcp_agent_idle_ttl_hours) and its daemon ended it",
        .closed => "it was closed (agent_close, or a kill)",
        .exited => "its app exited",
        .unknown => "its daemon does not know why it ended",
    };
}

/// Start a background reconnect for each of `e`'s lost links that is due,
/// backing off 2 s doubling to 60 s.
fn kickReconnects(e: *Entry, now_ms: i64) void {
    if (now_ms < e.reconnect_ms) return;
    var started = false;
    for ([_]?*termdrive.Term{ e.visibleTerm(), e.server }) |o| {
        const t = o orelse continue;
        if (!t.lost or inFlight(t)) continue;
        startReconnect(t);
        started = true;
    }
    if (!started) return;
    e.reconnect_ms = now_ms + e.reconnect_delay_ms;
    e.reconnect_delay_ms = @min(e.reconnect_delay_ms * 2, RECONNECT_MAX_MS);
}

fn startReconnect(t: *termdrive.Term) void {
    const a = state.allocator;
    const host = t.remote_host orelse return;
    if (!t.origin_id_valid) return;
    state.reconnects.ensureUnusedCapacity(a, 1) catch return;
    const j = a.create(ReconnectJob) catch return;
    const h = a.dupe(u8, host) catch return a.destroy(j);
    const n = a.dupe(u8, t.name) catch {
        a.free(h);
        return a.destroy(j);
    };
    j.* = .{ .allocator = a, .host = h, .name = n, .origin = t.origin_id, .term = t };
    const th = std.Thread.spawn(.{}, ReconnectJob.run, .{j}) catch return j.free();
    th.detach();
    state.reconnects.appendAssumeCapacity(j);
}

/// Observing `e` failed, so it stops updating until a later pass succeeds:
/// say so once per distinct error, on stderr (and `--log`) and as a notice.
fn noteServiceFailure(e: *Entry, err: anyerror) void {
    if (e.service_failed) |prev| if (prev == err) return;
    e.service_failed = err;
    mcp.warn("agent {s}: reading its app failed ({s}); it shows no updates until a later read succeeds", .{ e.id, @errorName(err) });
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "sketerm could not read this agent's app ({s}): its state and records stop updating until a later read succeeds", .{@errorName(err)}) catch return;
    e.agent.addNotice(text) catch {};
}

fn serviceEntry(e: *Entry, now_ms: i64) !void {
    // A relaunch is replacing the terminal; it observes the new one itself.
    if (e.relaunching) return;
    switch (e.agent.source) {
        .screen => |*eng| {
            const t = e.visibleTerm() orelse return eng.noteDisconnected(now_ms, "the agent's terminal was closed");
            t.drain();
            var why_buf: [512]u8 = undefined;
            switch (linkEnd(e, t)) {
                .live => try observeScreen(eng, .{
                    .screen = t.screen,
                    .resynced = t.snapshots != e.seen_snapshots,
                    .exited = t.exited,
                    .exit_status = if (t.exit_status_known) t.exit_status else null,
                }, now_ms),
                // The remote session may run on: the link is what is gone.
                .lost => try eng.noteDisconnected(now_ms, lostReason(e, &why_buf)),
                .ssh_gone => {
                    try eng.noteDisconnected(now_ms, lostReason(e, &why_buf));
                    try eng.noteExited(now_ms, null);
                },
            }
            e.seen_snapshots = t.snapshots;
        },
        .opencode_api => |*api| {
            if (e.visibleTerm()) |t| t.drain();
            if (e.server) |srv| {
                srv.drain();
                // A lost link to a remote server's session is not its end:
                // the API (through the forward) says whether it runs.
                if (srv.exited and !srv.lost and !api.source.exited)
                    try api.noteExited(now_ms, if (srv.exit_status_known) srv.exit_status else null);
            }
            reviveForward(e, now_ms);
            try api.service(now_ms);
        },
    }
}

/// How a terminal's session ended for the agent, if it did.
const LinkEnd = enum {
    /// Running, or ended for real (`observeScreen` reports the exit).
    live,
    /// The link to a remote-mux session is lost; it may come back.
    lost,
    /// A plain-ssh session whose ssh lost the connection: the remote
    /// process went with it.
    ssh_gone,
};

fn linkEnd(e: *const Entry, t: *const termdrive.Term) LinkEnd {
    if (!t.exited) return .live;
    if (t.lost) return .lost;
    if (e.transport == .ssh and t.exit_status_known and t.exit_status == SSH_LOST_STATUS) return .ssh_gone;
    return .live;
}

fn lostReason(e: *const Entry, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "the connection to {s} was lost", .{e.host orelse "the agent's host"}) catch "the connection was lost";
}

/// Respawn a remote API agent's dead port forward (rate limited, never
/// waits for it: the API's own reconnect picks it up once it listens).
fn reviveForward(e: *Entry, now_ms: i64) void {
    const f = e.forward orelse return;
    f.drain();
    // A gone agent's server is not coming back behind it.
    if (!f.exited or now_ms < e.forward_retry_ms or gone(e)) return;
    e.forward_retry_ms = now_ms + FORWARD_RETRY_MS;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const host = e.host orelse return;
    const name = forwardName(arena_state.allocator(), e.id) catch return;
    // The dead one's session is gone: its name is free again.
    const nt = mcp_term.spawnForwardTermNamed(arena_state.allocator(), host, e.port, "127.0.0.1", e.remote_port, name) catch return;
    f.deinit();
    e.forward = nt;
    writeDescriptor(e);
}

fn forwardName(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "agent-{s}-forward", .{id});
}

/// How long a start waits for a stale session to give up its forward name.
const FORWARD_NAME_WAIT_MS: i64 = 5_000;

/// Start agent `id`'s port forward under its one name on this server's
/// private daemon. A session still holding that name (a dead agent's
/// forward, a previous server's on a durable instance's daemon) is ended
/// first, so a relaunch or reattach under the same id gets its forward.
pub fn spawnForward(arena: std.mem.Allocator, id: []const u8, host: []const u8, port: u16, remote_port: u16) !*termdrive.Term {
    const name = try forwardName(arena, id);
    if (mcp_term.spawnForwardTermNamed(arena, host, port, "127.0.0.1", remote_port, name)) |t| return t else |_| {}
    if (state.mux_sock) |sock| if (muxclient.Conn.connectProbed(state.allocator, sock)) |conn_val| {
        var conn = conn_val;
        defer conn.deinit();
        conn.sendKill(.{ .name = name }) catch {};
    } else |_| {};
    const until = clock.nowMs() + FORWARD_NAME_WAIT_MS;
    while (true) {
        pumpFor(200);
        if (mcp_term.spawnForwardTermNamed(arena, host, port, "127.0.0.1", remote_port, name)) |t| return t else |err| {
            if (clock.nowMs() >= until) return err;
        }
    }
}

/// A call on an agent whose link is lost retries it at once (in the
/// background; the call does not wait for it) and restarts the backoff.
pub fn reconnectIfLost(e: *Entry) void {
    e.reconnect_ms = 0;
    e.reconnect_delay_ms = RECONNECT_MIN_MS;
    kickReconnects(e, clock.nowMs());
}

/// What a resumed app showed so far is its past: every record handed out
/// and every event announcing one delivered, so no read, result or waiter
/// hands the conversation's history out as new.
pub fn foldHistory(e: *Entry) void {
    for (e.agent.records()) |r| {
        if (e.handed.has(r)) continue;
        e.handed.markRecord(e.allocator, r) catch return;
    }
    e.agent.queue().deliverAnnounced();
}

/// The resumed app is about to get a prompt or an answer: fold what it
/// showed until now, and what comes after is news.
pub fn closeHistory(e: *Entry) void {
    if (!e.history) return;
    foldHistory(e);
    e.history = false;
}

/// Wait up to `max_ms` for any agent or waiter fd, then service.
pub fn pump(max_ms: i64) void {
    var pfds: [128]c.struct_pollfd = undefined;
    const n = pollFds(&pfds);
    var wait = std.math.clamp(max_ms, 0, 1000);
    if (dueInMs(clock.nowMs())) |d| wait = @min(wait, @max(d, 0));
    _ = c.poll(&pfds, @intCast(n), @intCast(wait));
    service(clock.nowMs());
}

/// Service everything for `ms` (a recipe's sleep).
pub fn pumpFor(ms: i64) void {
    const until = clock.nowMs() + ms;
    while (true) {
        const left = until - clock.nowMs();
        if (left <= 0) break;
        pump(left);
    }
}

/// The agent's app is gone for good: no wait can change anything.
pub fn gone(e: *const Entry) bool {
    return e.agent.state() == .exited;
}

/// Wait for the app to take input; false at the deadline, or at once
/// when it is gone or its connection is lost.
pub fn waitReady(e: *Entry, deadline: i64) bool {
    service(clock.nowMs());
    while (!e.agent.ready()) {
        // A prompt before the app is ready (a trust dialog) is the caller's.
        if (e.agent.interaction() != null) return false;
        if (gone(e) or e.agent.state() == .disconnected or clock.nowMs() >= deadline) return false;
        pump(deadline - clock.nowMs());
    }
    return true;
}

/// The assistant's next delivery with `filter`, waiting until `deadline`;
/// null on timeout or when the agent is gone with nothing left to hand.
pub fn waitDelivery(e: *Entry, filter: events.Filter, deadline: i64, arena: std.mem.Allocator) !?events.Delivery {
    const one = [1]*Entry{e};
    const got = (try waitAny(&one, filter, deadline, arena)) orelse return null;
    return got.delivery;
}

const Woken = struct { entry: *Entry, delivery: events.Delivery };

/// The first delivery from any of `entries` (in their order when several
/// have one), waiting until `deadline`; null on timeout or when every one
/// is gone with nothing left to hand.
pub fn waitAny(entries: []const *Entry, filter: events.Filter, deadline: i64, arena: std.mem.Allocator) !?Woken {
    for (entries) |e| hold(e);
    service(clock.nowMs());
    while (true) {
        var all_gone = true;
        for (entries) |e| {
            if (try e.cursor.take(e.agent.queue(), filter, clock.nowMs(), arena)) |d| return .{ .entry = e, .delivery = d };
            if (!gone(e)) all_gone = false;
        }
        if (all_gone or clock.nowMs() >= deadline) return null;
        pump(deadline - clock.nowMs());
    }
}

/// How an agent settled: the event that settled its last prompt's turn
/// (null: it was never sent one and none ever settled), and its state.
const Settle = struct { event: ?*const events.Event, state: vocab.State };

/// Whether `e` settled (`vocab.State.settled`, and the turn of the prompt
/// it was last sent ended: an idle agent that has not started on it yet is
/// not settled), and how; null while it has not.
pub fn settleOf(e: *Entry) ?Settle {
    const st = e.agent.state();
    if (!st.settled()) return null;
    const q = e.agent.queue();
    if (e.sent_seq) |from| {
        const ev = q.lastSettle(from) orelse return null;
        return .{ .event = ev, .state = st };
    }
    return .{ .event = q.lastSettle(0), .state = st };
}

/// What a `stalled` event says `ag` last did: when (`activity_ms`, a
/// `clock.nowMs` reading; 0 = never) and its newest tool call's tool (a
/// busy screen app's included, `Agent.recentTools`).
fn stallLast(arena: std.mem.Allocator, ag: *const agent_mod.Agent, activity_ms: i64) !stall.Tracker.Last {
    const tools = try ag.recentTools(arena, 1);
    return .{
        .activity_wall_ms = if (activity_ms > 0) clock.wallOfMono(activity_ms) else 0,
        .tool = if (tools.len > 0) tools[0].name else null,
    };
}

/// One agent's line of an `all` wake: the settling kind (else the state).
pub fn settledOf(arena: std.mem.Allocator, e: *const Entry, s: Settle) !agentwait.Settled {
    const ev = s.event orelse return .{ .agent = e.id, .outcome = @tagName(s.state), .state = @tagName(s.state) };
    return .{
        .agent = e.id,
        .outcome = @tagName(ev.kind),
        .state = @tagName(s.state),
        .text = if (ev.kind.announcesRecord()) events.preview(ev.text) else ev.text,
        .record = ev.record,
        .at = try agentwait.eventAt(arena, ev),
    };
}

/// @param asked identity of the interaction showing when the recipe
/// started (`answered` waits for it to go).
pub fn waitStep(e: *Entry, what: adapter.WaitFor, asked: ?u64, deadline: i64) bool {
    service(clock.nowMs());
    while (true) {
        const met = switch (what) {
            .ready => e.agent.ready(),
            .choice => e.agent.interaction() != null,
            .idle => e.agent.state() == .idle,
            .answered => if (e.agent.interaction()) |it| asked == null or it.hash() != asked.? else true,
            // `runStepsIn` waits for these itself (they read the panel).
            .side_asked, .side_answer => return false,
        };
        if (met) return true;
        if (gone(e) or clock.nowMs() >= deadline) return false;
        pump(deadline - clock.nowMs());
    }
}

/// Wait (at most `DELIVERY_CONFIRM_MS`, the bound every send's evidence
/// gets) until the side panel names the question typed as `asked`.
pub fn waitSideAsked(arena: std.mem.Allocator, e: *Entry, asked: []const u8) !bool {
    const eng = &e.agent.source.screen;
    const until = clock.nowMs() + DELIVERY_CONFIRM_MS;
    service(clock.nowMs());
    while (true) {
        if (try eng.sideAnswer(arena, asked) != null) return true;
        if (gone(e) or clock.nowMs() >= until) return false;
        pump(until - clock.nowMs());
    }
}

/// The answer to `asked` once it is drawn (not pending, not empty) and has
/// not changed for the adapter's `side_question.settle_ms`, owned by
/// `arena`; null at the deadline.
pub fn waitSideAnswer(arena: std.mem.Allocator, e: *Entry, asked: []const u8, deadline: i64) !?[]const u8 {
    const eng = &e.agent.source.screen;
    const settle: i64 = if (eng.sc.side) |sd| sd.spec.settle_ms else 0;
    var last: ?[]const u8 = null;
    var since: i64 = 0;
    service(clock.nowMs());
    while (true) {
        const now = clock.nowMs();
        const got = try eng.sideAnswer(arena, asked);
        if (got != null and !got.?.pending and got.?.text.len > 0) {
            if (last == null or !std.mem.eql(u8, last.?, got.?.text)) {
                last = got.?.text;
                since = now;
            } else if (now - since >= settle) return last;
        } else last = null;
        if (gone(e) or now >= deadline) return null;
        // Wake for the settle bound even when the screen is quiet.
        pump(@min(deadline - now, 100));
    }
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_agent_testkit = @import("mcp_agent_testkit.zig");
const live = mcp_agent_testkit.live;
const erase = mcp_agent_testkit.erase;

const Parser = @import("../parser/vt.zig").Parser;
const Event = @import("../parser/event.zig").Event;
const StylePool = @import("../grid/style_pool.zig").Pool;

/// A Screen the tests write Claude-Code-style ax bytes into, observed
/// through `observeScreen` exactly as the loop does.
const ScreenRig = struct {
    pool: StylePool,
    screen: *Screen,
    parser: Parser,
    set: adapter.Set,
    engine: screen_source.Engine,

    fn init(self: *ScreenRig) !void {
        self.pool = try StylePool.init(testing.allocator);
        self.screen = try Screen.init(testing.allocator, &self.pool, 80, 24);
        self.parser = Parser.init(testing.allocator);
        self.set = adapter.Set.init(testing.allocator);
        try self.set.loadShipped();
        self.engine = try screen_source.Engine.init(testing.allocator, self.set.get("claude").?, .{});
    }

    fn deinit(self: *ScreenRig) void {
        self.engine.deinit();
        self.set.deinit();
        self.parser.deinit();
        self.screen.deinit();
        self.pool.deinit();
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *ScreenRig = @ptrCast(@alignCast(user.?));
        var e = ev;
        self.screen.apply(ev);
        e.deinit(testing.allocator);
    }

    fn write(self: *ScreenRig, bytes: []const u8) void {
        self.parser.advance(bytes, emit, @ptrCast(self));
    }

    fn observe(self: *ScreenRig, now: i64) !void {
        try observeScreen(&self.engine, .{ .screen = self.screen }, now);
    }

    fn count(self: *const ScreenRig, k: vocab.EventKind) usize {
        var n: usize = 0;
        for (self.engine.queue.events.items) |ev| {
            if (ev.kind == k) n += 1;
        }
        return n;
    }
};
const turn_chunks = [_][]const u8{
    "\x1b]133;A\x07\x1b]0;\xe2\x97\x90 Working\x07" ++ erase ++ "you: first question\r\n" ++ live,
    erase ++ "tool: Read (notes.md)\r\nclaude: the first answer\r\n" ++ live,
    "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 Claude Code\x07" ++ erase ++ "Brewed for 1s \xc2\xb7 done\r\n" ++ live,
    "\x1b]133;A\x07\x1b]0;\xe2\x97\x90 Working\x07" ++ erase ++ "you: second question\r\n" ++ live,
    erase ++ "claude: the second answer\r\n" ++ live,
    "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 Claude Code\x07" ++ erase ++ "Baked for 2s \xc2\xb7 done\r\n" ++ live,
};

fn startRig(rig: *ScreenRig) !void {
    try rig.init();
    rig.write("\x1b]0;\xe2\x9c\xb3 Claude Code\x07Claude Code v9 (test)\r\n" ++ live);
    try rig.observe(0);
    try rig.observe(1000);
    try testing.expect(rig.engine.ready);
}

test "a stalled event names the last activity's wall time and the busy turn's last tool" {
    var rig: ScreenRig = undefined;
    try startRig(&rig);
    defer rig.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    rig.write(turn_chunks[0]);
    try rig.observe(2000);
    rig.write(turn_chunks[1]);
    try rig.observe(3000);
    // Busy: the call is on screen, not a record yet.
    try testing.expectEqual(vocab.State.working, rig.engine.state);
    try testing.expectEqual(@as(usize, 0), rig.engine.records.items.len);
    // A read-only view of the same engine, as the loop has it.
    const ag: agent_mod.Agent = .{ .allocator = testing.allocator, .loaded = rig.set.get("claude").?, .source = .{ .screen = rig.engine } };
    const act = clock.nowMs();
    const last = try stallLast(a, &ag, act);
    try testing.expectEqualStrings("Read", last.tool.?);
    try testing.expectEqual(@as(usize, 0), rig.engine.records.items.len);
    var tracker: stall.Tracker = .{};
    tracker.set(1, act);
    try testing.expect(!tracker.isDue(.working, act, act + 59_999));
    try testing.expect(tracker.isDue(.working, act, act + 60_000));
    try testing.expect(try tracker.check(&rig.engine.queue, .working, act, act + 60_000, last));
    const ev = rig.engine.queue.events.items[rig.engine.queue.events.items.len - 1];
    var iso: [clock.ISO_LEN]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, ev.text, clock.isoLocal(&iso, last.activity_wall_ms).?) != null);
    try testing.expect(std.mem.indexOf(u8, ev.text, ", last tool Read: ") != null);
    // Captured at the turn's end: the same call, now with its record's time.
    rig.write(turn_chunks[2]);
    try rig.observe(4000);
    try rig.observe(9000);
    const ag2: agent_mod.Agent = .{ .allocator = testing.allocator, .loaded = rig.set.get("claude").?, .source = .{ .screen = rig.engine } };
    const seen = try ag2.recentTools(a, 10);
    try testing.expectEqual(@as(usize, 1), seen.len);
    try testing.expectEqualStrings("Read", seen[0].name);
    try testing.expect(seen[0].at_ms > 0);
}

test "a backlog observed late yields the records and events of a live stream" {
    // Live: observed after every batch, 100ms apart.
    var eager: ScreenRig = undefined;
    try startRig(&eager);
    defer eager.deinit();
    var now: i64 = 1000;
    for (turn_chunks) |chunk| {
        eager.write(chunk);
        now += 100;
        try eager.observe(now);
    }
    try eager.engine.tick(now + 5000);

    // Late: the loop was blocked (an unrelated tool call) while the app
    // drew both turns; one observation, long after, sees it all at once.
    var late: ScreenRig = undefined;
    try startRig(&late);
    defer late.deinit();
    for (turn_chunks) |chunk| late.write(chunk);
    try late.observe(60_000);
    try late.engine.tick(65_000);

    for ([_]*ScreenRig{ &eager, &late }) |rig| {
        const recs = rig.engine.records.items;
        try testing.expectEqual(@as(usize, 5), recs.len);
        try testing.expectEqualStrings("first question", recs[0].text);
        try testing.expectEqual(vocab.RecordKind.tool, recs[1].kind);
        try testing.expectEqualStrings("the first answer", recs[2].text);
        try testing.expectEqualStrings("second question", recs[3].text);
        try testing.expectEqualStrings("the second answer", recs[4].text);
        try testing.expectEqual(vocab.State.idle, rig.engine.state);
        try testing.expectEqual(@as(usize, 2), rig.count(.message));
        try testing.expectEqual(@as(usize, 0), rig.count(.needs_input));
    }
    // The late reader may fold the two turn ends into one done (it saw a
    // single finished state); what it reports is the latest turn's answer,
    // exactly as the live reader's last done does.
    try testing.expectEqual(@as(usize, 2), eager.count(.done));
    try testing.expect(late.count(.done) >= 1);
    const last = late.engine.queue.events.items[late.engine.queue.events.items.len - 1];
    try testing.expectEqual(vocab.EventKind.done, last.kind);
    try testing.expectEqualStrings("the second answer", last.text);
}

test "a resynced mirror is a wipe: nothing is captured twice" {
    var rig: ScreenRig = undefined;
    try startRig(&rig);
    defer rig.deinit();
    for (turn_chunks[0..3]) |chunk| rig.write(chunk);
    try rig.observe(2000);
    try rig.engine.tick(9000);
    try testing.expectEqual(@as(usize, 3), rig.engine.records.items.len);
    // A snapshot swap reprints the same transcript into a fresh Screen.
    try observeScreen(&rig.engine, .{ .screen = rig.screen, .resynced = true }, 9100);
    try rig.engine.tick(20_000);
    try testing.expectEqual(@as(usize, 3), rig.engine.records.items.len);
    try testing.expectEqual(@as(usize, 1), rig.count(.done));
    // An exit rides the same observation.
    try observeScreen(&rig.engine, .{ .screen = rig.screen, .exited = true, .exit_status = 0 }, 21_000);
    try testing.expectEqual(vocab.State.exited, rig.engine.state);
    try testing.expectEqual(@as(usize, 1), rig.count(.exited));
}
