//! MCP `agent_*` tools (group `agent`): run another coding agent (Claude
//! Code, opencode) as a sub-agent and talk to it through its adapter, in
//! records, state, the pending prompt and events, never raw screens.
//!
//! An agent is a session (two for an API source) on this server's private
//! daemon, named `agent-<id>` so the user's GUI lists it for watch-along.
//! The server loop observes every agent between requests (`pollFds`,
//! `dueInMs`, `service`), and so does every wait here, so a turn that ends
//! while the assistant is idle is noticed, and one that ended while an
//! unrelated tool blocked the loop is read correctly afterwards: the
//! sources decide everything from content, never from gaps between feeds.
//!
//! Waking the assistant is the waiter socket (`agentwait.zig` is its
//! protocol and CLI); it and `agent_wait` both go through
//! `events.Cursor.take` on the agent's one queue and limiter.
//!
//! Gotcha: an `Entry` is heap-allocated and stays put, because the
//! agent's driver points into it; entries are removed only by a tool
//! handler (agent_close) or `shutdown`, never by `service`.

const std = @import("std");
const c = @import("../c.zig").c;
const mcp = @import("mcp.zig");
const mcp_tools = @import("mcp_tools.zig");
const mcp_term = @import("mcp_term.zig");
const termdrive = @import("termdrive.zig");
const agentwait = @import("agentwait.zig");
const adapter = @import("../agent/adapter.zig");
const agent_mod = @import("../agent/agent.zig");
const events = @import("../agent/events.zig");
const vocab = @import("../agent/vocab.zig");
const output = @import("../agent/output.zig");
const select = @import("../agent/select.zig");
const launch = @import("../agent/launch.zig");
const screen_source = @import("../agent/screen_source.zig");
const opencode = @import("../agent/opencode.zig");
const wire = @import("../mux/wire.zig");
const Screen = @import("../grid/screen.zig").Screen;
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const pathz = @import("../util/pathz.zig");
const readfile = @import("../util/readfile.zig");
const transport_mod = @import("transport.zig");
const mcp_registry = @import("mcp_registry.zig");
const sshroute = @import("../mux/sshroute.zig");
const Transport = transport_mod.Transport;

const Res = mcp.Res;
const errRes = mcp.errRes;
const argStr = mcp.argStr;
const argInt = mcp.argInt;
const argBool = mcp.argBool;

pub const Tool = mcp_tools.GroupTool(.agent);

/// A wait's default bound (agent_open with a prompt, send, answer, wait).
pub const DEFAULT_WAIT_MS: i64 = 60_000;
/// agent_attach's default wait for the app to be ready.
const ATTACH_WAIT_MS: i64 = 10_000;
/// Bound on one `wait` step of an action recipe (a picker to show up).
const STEP_WAIT_MS: i64 = 10_000;
/// Bound on an API server's port starting to listen.
const PORT_WAIT_MS: i64 = 20_000;
/// A screen engine's settle rules need ticks while something is pending.
const TICK_MS: i64 = 250;
/// Pause after the keys that clear an input box: an Escape followed at
/// once by text reads as Alt+key to the app.
const CLEAR_SETTLE_MS: i64 = 200;
/// Pause after an interrupt so the reply shows the state it caused.
const INTERRUPT_SETTLE_MS: i64 = 300;
const DEFAULT_COLS: u16 = 120;
const DEFAULT_ROWS: u16 = 40;
/// Records one agent_read returns by default, and at most.
const READ_DEFAULT: usize = 100;
const READ_MAX: usize = 500;
/// Descriptor files and passwords live here, in the instance dir.
const DESCRIPTOR_DIR = "agents";
/// The waiter socket's name in the instance dir.
pub const WAITER_SOCKET = "agents.sock";
const MAX_SUBS = 32;
/// Room for `launch.MAX_EXTRA` args and env values of the longest kind,
/// JSON-escaped.
const DESCRIPTOR_MAX_BYTES = 4 * 1024 * 1024;
/// Bound on the remote binary probe (one ssh round trip).
const PROBE_WAIT_MS: i64 = 30_000;
/// Bound on a remote start asking for its secret.
const SECRET_WAIT_MS: i64 = 30_000;
/// Bound on the app ending after its exit recipe, before it is killed.
const EXIT_WAIT_MS: i64 = 10_000;
/// How often a dead forward is respawned / a lost link retried.
const FORWARD_RETRY_MS: i64 = 3_000;
const RECONNECT_RETRY_MS: i64 = 5_000;
/// Remote ports an API server is started on (the remote host's free ports
/// are not knowable from here; a taken one fails the open with the
/// server's own message).
const REMOTE_PORT_MIN: u16 = 20_000;
const REMOTE_PORT_SPAN: u16 = 40_000;
/// The exit status ssh reports for a lost connection.
const SSH_LOST_STATUS: i32 = 255;

/// Server `instructions` (the MCP initialize result) while the agent tools
/// are offered: MCP clients put them in the assistant's system prompt.
pub const INSTRUCTIONS =
    "sketerm can run other coding agents for you as sub-agents. To delegate work to Claude Code or opencode, call agent_open " ++
    "(app \"claude\" or \"opencode\", optionally with a prompt) and agent_send; results carry the finished job's answer and its " ++
    "other key messages, pending prompts (answer with agent_answer) and events, never raw screens, and agent_read returns the same " ++
    "per job for what you have not read yet (detail \"all\" for every message, include_tools for tool calls). " ++
    "When a result says still_working, run its watch_command in the background (or as a Monitor with --follow) " ++
    "to be woken when the agent finishes or needs input, instead of polling with agent_wait.";

// ── state ────────────────────────────────────────────────────────

/// Where an agent's visible terminal comes from.
const Link = union(enum) {
    /// Spawned by agent_open: killed by agent_close.
    owned: *termdrive.Term,
    /// A term_open terminal (agent_attach), looked up by id every time.
    borrowed: u32,
};

pub const Entry = struct {
    allocator: std.mem.Allocator,
    /// `<app>-<n>`.
    id: []u8,
    loaded: *const adapter.Loaded,
    agent: *agent_mod.Agent,
    /// The terminal the user watches: the app itself (screen sources) or
    /// the app's attached TUI (API sources).
    session: []u8,
    visible: ?Link,
    /// API sources: the session running the app's server.
    server: ?*termdrive.Term = null,
    server_session: ?[]u8 = null,
    port: u16 = 0,
    /// API sources: held in memory and, for a durable instance, in a 0600
    /// file beside the descriptor; never on an argv.
    password: ?[]u8 = null,
    binary: []u8,
    cwd: []u8,
    recordings: std.ArrayList([]u8) = .empty,
    seen_snapshots: u32 = 0,
    /// What the ASSISTANT has been handed (every agent_* result).
    cursor: events.Cursor = .{},
    /// The highest record id an agent_read covered: the next read without
    /// `since` returns the jobs holding newer records.
    read_cursor: u64 = 0,
    /// The SSH host the agent runs on; null = this machine.
    host: ?[]u8 = null,
    transport: Transport = .local,
    cols: u16 = DEFAULT_COLS,
    rows: u16 = DEFAULT_ROWS,
    /// The conversation id `launch.session_args` named (owned).
    conversation: ?[]u8 = null,
    /// A prompt went in: a relaunch resumes the conversation.
    conversed: bool = false,
    /// What the launch passed and a relaunch repeats (owned).
    launch_model: ?[]u8 = null,
    launch_effort: ?[]u8 = null,
    /// The caller's `args`/`env`, on every start of the binary (owned).
    extra: launch.Extra = .{},
    /// A model chosen in the app since the launch, re-applied after a
    /// relaunch (owned).
    picked_model: ?[]u8 = null,
    relaunches: u32 = 0,
    /// A relaunch is swapping the terminal: the old one's exit is not
    /// the agent's.
    relaunching: bool = false,
    /// API sources over SSH: the server's port on the remote host (`port`
    /// is the local end of the forward that reaches it).
    remote_port: u16 = 0,
    forward: ?*termdrive.Term = null,
    /// The next respawn of a dead forward / reconnect of a lost link.
    forward_retry_ms: i64 = 0,
    reconnect_ms: i64 = 0,

    fn visibleTerm(self: *const Entry) ?*termdrive.Term {
        const l = self.visible orelse return null;
        return switch (l) {
            .owned => |t| t,
            .borrowed => |id| mcp_term.term_state.terms.get(id),
        };
    }

    fn where(self: *const Entry) Where {
        return .{ .host = self.host, .transport = self.transport, .cols = self.cols, .rows = self.rows };
    }

    /// Free the entry. `kill` ends the sessions it owns; otherwise they
    /// keep running on the daemon (a durable instance exiting).
    fn destroy(self: *Entry, kill: bool) void {
        const a = self.allocator;
        self.agent.deinit();
        a.destroy(self.agent);
        if (self.visible) |l| switch (l) {
            .owned => |t| if (kill) t.deinit() else t.detach(),
            .borrowed => {},
        };
        if (self.server) |t| if (kill) t.deinit() else t.detach();
        if (self.forward) |t| if (kill) t.deinit() else t.detach();
        self.freeFields();
        a.destroy(self);
    }

    /// Free what the entry owns besides its agent and terminals.
    fn freeFields(self: *Entry) void {
        const a = self.allocator;
        if (self.password) |p| {
            std.crypto.secureZero(u8, p);
            a.free(p);
        }
        for ([_]?[]u8{ self.server_session, self.host, self.conversation, self.launch_model, self.launch_effort, self.picked_model }) |o| {
            if (o) |s| a.free(s);
        }
        self.extra.free(a);
        for (self.recordings.items) |r| a.free(r);
        self.recordings.deinit(a);
        a.free(self.id);
        a.free(self.session);
        a.free(self.binary);
        a.free(self.cwd);
    }
};

/// Where an agent's sessions run.
const Where = struct {
    host: ?[]const u8 = null,
    transport: Transport = .local,
    cols: u16 = DEFAULT_COLS,
    rows: u16 = DEFAULT_ROWS,
};

const State = struct {
    allocator: std.mem.Allocator = undefined,
    /// The instance dir; null = shared mode, where the agent tools are
    /// unavailable.
    dir: ?[]const u8 = null,
    mux_sock: ?[]const u8 = null,
    durable: bool = false,
    /// The running executable, absolute (watch_command).
    exe: ?[]u8 = null,
    set: ?adapter.Set = null,
    entries: std.ArrayList(*Entry) = .empty,
    /// Last number used per adapter id (keys borrow the loaded spec's id).
    counters: std.StringHashMapUnmanaged(u32) = .empty,
    waiter: Waiter = .{},
    /// The server's registry record, which publishes `entries`.
    registry: ?*mcp_registry.Lease = null,
};

pub var state: State = .{};

/// Arm the agent tools for an isolated or durable instance: `dir` holds
/// the waiter socket and (durable) the agent descriptors. Both slices
/// must outlive `shutdown`.
pub fn configure(allocator: std.mem.Allocator, dir: []const u8, mux_sock: []const u8, durable: bool) void {
    state = .{ .allocator = allocator, .dir = dir, .mux_sock = mux_sock, .durable = durable };
    var buf: [4096]u8 = undefined;
    if (platform.exePath(&buf)) |p| state.exe = allocator.dupe(u8, p) catch null;
    state.waiter.listen(allocator, dir);
}

/// End every waiter, then close (ephemeral) or detach (durable) every
/// agent. Idempotent.
pub fn shutdown() void {
    if (state.dir == null) return;
    const a = state.allocator;
    state.waiter.close(a, "the MCP server is exiting");
    for (state.entries.items) |e| e.destroy(!state.durable);
    state.entries.deinit(a);
    state.entries = .empty;
    state.counters.deinit(a);
    state.counters = .empty;
    if (state.set) |*s| s.deinit();
    state.set = null;
    if (state.exe) |e| a.free(e);
    state.exe = null;
    state.dir = null;
    state.registry = null;
}

pub fn available() bool {
    return state.dir != null;
}

fn adapters() !*adapter.Set {
    if (state.set == null) state.set = try adapter.Set.loadDefault(state.allocator);
    return &state.set.?;
}

/// The adapter ids this server can open, for `capabilities`.
pub fn adapterIds(arena: std.mem.Allocator) ![]const []const u8 {
    const set = try adapters();
    const ids = try arena.alloc([]const u8, set.items.items.len);
    for (set.items.items, ids) |l, *id| id.* = l.spec.id;
    return ids;
}

/// The waiter command with an `AGENT` placeholder, or null when there is
/// no waiter (shared mode, or its socket could not be bound).
pub fn waiterTemplate(arena: std.mem.Allocator) !?[]const u8 {
    const exe = state.exe orelse return null;
    const sock = state.waiter.path orelse return null;
    return try agentwait.watchCommand(arena, exe, sock, "AGENT", .{});
}

/// The conn fds the watchdog may shut down.
pub fn watchdogFds(out: []c_int) []c_int {
    var n: usize = 0;
    for (state.entries.items) |e| {
        if (e.visible) |l| switch (l) {
            .owned => |t| if (n < out.len) {
                out[n] = t.conn.fd;
                n += 1;
            },
            .borrowed => {},
        };
        for ([_]?*termdrive.Term{ e.server, e.forward }) |o| if (o) |t| if (n < out.len) {
            out[n] = t.conn.fd;
            n += 1;
        };
    }
    return out[0..n];
}

fn findByName(name: []const u8) ?*Entry {
    for (state.entries.items) |e| {
        if (std.mem.eql(u8, e.id, name) or std.mem.eql(u8, e.session, name)) return e;
    }
    return null;
}

fn findById(id: []const u8) ?*Entry {
    for (state.entries.items) |e| {
        if (std.mem.eql(u8, e.id, id)) return e;
    }
    return null;
}

fn nextNumber(app: []const u8) !u32 {
    const gop = try state.counters.getOrPut(state.allocator, app);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
    return gop.value_ptr.*;
}

fn localHost() launch.Host {
    return .{
        .path = if (c.getenv("PATH")) |p| std.mem.span(@as([*:0]const u8, @ptrCast(p))) else "",
        .home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else null,
    };
}

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
            .screen => |*eng| if (screenNeedsTick(eng)) TICK_MS else null,
            .opencode_api => |*api| api.serviceDueIn(now_ms),
        };
        if (d) |x| due = if (due) |y| @min(x, y) else x;
        if (e.forward) |f| if (f.exited) {
            const x = @max(0, e.forward_retry_ms - now_ms);
            due = if (due) |y| @min(x, y) else x;
        };
    }
    if (state.waiter.dueIn(now_ms)) |x| due = if (due) |y| @min(x, y) else x;
    return due;
}

fn screenNeedsTick(e: *const screen_source.Engine) bool {
    if (e.exited or e.disconnected) return false;
    return !e.ready or e.end_pending or e.lone_bell or e.retry_since_ms != null or e.state != .idle;
}

/// Read every agent's sources and deliver waiter wake-ups. Never blocks.
pub fn service(now_ms: i64) void {
    for (state.entries.items) |e| serviceEntry(e, now_ms) catch {};
    state.waiter.service(now_ms);
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
    if (!f.exited or now_ms < e.forward_retry_ms) return;
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

/// Bring a lost remote link back, at most every RECONNECT_RETRY_MS (one
/// bounded ssh connect each). Runs on the agent's own calls, so a dead
/// host never stalls the loop for agents nobody asks about.
fn reconnectIfLost(e: *Entry) void {
    const now = clock.nowMs();
    if (now < e.reconnect_ms) return;
    var tried = false;
    for ([_]?*termdrive.Term{ e.visibleTerm(), e.server }) |o| {
        const t = o orelse continue;
        if (!t.lost) continue;
        tried = true;
        _ = t.reconnect();
    }
    if (tried) e.reconnect_ms = clock.nowMs() + RECONNECT_RETRY_MS;
}

/// Wait up to `max_ms` for any agent or waiter fd, then service.
fn pump(max_ms: i64) void {
    var pfds: [128]c.struct_pollfd = undefined;
    const n = pollFds(&pfds);
    var wait = std.math.clamp(max_ms, 0, 1000);
    if (dueInMs(clock.nowMs())) |d| wait = @min(wait, @max(d, 0));
    _ = c.poll(&pfds, @intCast(n), @intCast(wait));
    service(clock.nowMs());
}

/// Service everything for `ms` (a recipe's sleep).
fn pumpFor(ms: i64) void {
    const until = clock.nowMs() + ms;
    while (true) {
        const left = until - clock.nowMs();
        if (left <= 0) break;
        pump(left);
    }
}

/// The agent's app is gone for good: no wait can change anything.
fn gone(e: *const Entry) bool {
    return e.agent.state() == .exited;
}

/// Wait for the app to take input; false at the deadline, or at once
/// when it is gone or its connection is lost.
fn waitReady(e: *Entry, deadline: i64) bool {
    service(clock.nowMs());
    while (!e.agent.ready()) {
        if (gone(e) or e.agent.state() == .disconnected or clock.nowMs() >= deadline) return false;
        pump(deadline - clock.nowMs());
    }
    return true;
}

/// The assistant's next delivery with `filter`, waiting until `deadline`;
/// null on timeout or when the agent is gone with nothing left to hand.
fn waitDelivery(e: *Entry, filter: events.Filter, deadline: i64, arena: std.mem.Allocator) !?events.Delivery {
    service(clock.nowMs());
    while (true) {
        if (try e.cursor.take(e.agent.queue(), filter, clock.nowMs(), arena)) |d| return d;
        if (gone(e) or clock.nowMs() >= deadline) return null;
        pump(deadline - clock.nowMs());
    }
}

/// @param asked identity of the interaction showing when the recipe
/// started (`answered` waits for it to go).
fn waitStep(e: *Entry, what: adapter.WaitFor, asked: ?u64, deadline: i64) bool {
    service(clock.nowMs());
    while (true) {
        const met = switch (what) {
            .ready => e.agent.ready(),
            .choice => e.agent.interaction() != null,
            .idle => e.agent.state() == .idle,
            .answered => if (e.agent.interaction()) |it| asked == null or it.hash() != asked.? else true,
        };
        if (met) return true;
        if (gone(e) or clock.nowMs() >= deadline) return false;
        pump(deadline - clock.nowMs());
    }
}

// ── the waiter socket ────────────────────────────────────────────

const Sub = struct {
    fd: c_int,
    inbuf: std.ArrayList(u8) = .empty,
    subscribed: bool = false,
    agent: []u8 = &.{},
    match: ?[]u8 = null,
    messages: bool = false,
    follow: bool = false,
    cursor: events.Cursor = .{},
    done: bool = false,

    fn filter(self: *const Sub) events.Filter {
        return .{ .messages = self.messages, .match = self.match };
    }
};

const Waiter = struct {
    fd: c_int = -1,
    path: ?[]u8 = null,
    subs: std.ArrayList(*Sub) = .empty,

    fn listen(self: *Waiter, a: std.mem.Allocator, dir: []const u8) void {
        const path = std.fmt.allocPrint(a, "{s}/" ++ WAITER_SOCKET, .{dir}) catch return;
        var addr: c.struct_sockaddr_un = undefined;
        @import("../mux/sockpath.zig").fillSockaddrUn(&addr, path) catch return a.free(path);
        var zbuf: [4096]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return a.free(path);
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return a.free(path);
        _ = c.unlink(pz.ptr);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0 or c.listen(fd, 16) != 0) {
            _ = c.close(fd);
            return a.free(path);
        }
        _ = c.chmod(pz.ptr, 0o600);
        setNonBlocking(fd);
        self.fd = fd;
        self.path = path;
    }

    fn close(self: *Waiter, a: std.mem.Allocator, reason: []const u8) void {
        for (self.subs.items) |s| {
            if (s.subscribed and !s.done) endSub(s, reason);
            freeSub(a, s);
        }
        self.subs.deinit(a);
        self.subs = .empty;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        if (self.path) |p| {
            pathz.unlinkPath(p);
            a.free(p);
        }
        self.path = null;
    }

    fn pollFds(self: *const Waiter, out: []c.struct_pollfd) usize {
        var n: usize = 0;
        if (self.fd >= 0 and n < out.len) {
            out[n] = .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        for (self.subs.items) |s| {
            if (n >= out.len) break;
            out[n] = .{ .fd = s.fd, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        return n;
    }

    fn dueIn(self: *const Waiter, now_ms: i64) ?i64 {
        var due: ?i64 = null;
        for (self.subs.items) |s| {
            if (!s.subscribed) continue;
            const e = findById(s.agent) orelse continue;
            if (s.cursor.digestDueIn(e.agent.queue(), now_ms)) |d| due = if (due) |x| @min(x, d) else d;
        }
        return due;
    }

    fn service(self: *Waiter, now_ms: i64) void {
        const a = state.allocator;
        self.accept(a);
        var i: usize = 0;
        while (i < self.subs.items.len) {
            const s = self.subs.items[i];
            serviceSub(a, s, now_ms);
            if (s.done) {
                freeSub(a, s);
                _ = self.subs.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn accept(self: *Waiter, a: std.mem.Allocator) void {
        if (self.fd < 0) return;
        while (self.subs.items.len < MAX_SUBS) {
            const cfd = c.accept(self.fd, null, null);
            if (cfd < 0) return;
            _ = c.fcntl(cfd, c.F_SETFD, c.FD_CLOEXEC);
            setNonBlocking(cfd);
            const s = a.create(Sub) catch {
                _ = c.close(cfd);
                return;
            };
            s.* = .{ .fd = cfd };
            self.subs.append(a, s) catch {
                _ = c.close(cfd);
                a.destroy(s);
                return;
            };
        }
    }
};

fn setNonBlocking(fd: c_int) void {
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
}

fn serviceSub(a: std.mem.Allocator, s: *Sub, now_ms: i64) void {
    // Read the subscription, or notice the client leaving.
    var tmp: [1024]u8 = undefined;
    while (true) {
        const n = c.read(s.fd, &tmp, tmp.len);
        if (n == 0) {
            s.done = true;
            return;
        }
        if (n < 0) break;
        if (s.subscribed) continue;
        s.inbuf.appendSlice(a, tmp[0..@intCast(n)]) catch return endSub(s, "out of memory");
        if (s.inbuf.items.len > agentwait.MAX_SUBSCRIBE) return endSub(s, "subscribe line too long");
    }
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!s.subscribed) {
        const nl = std.mem.indexOfScalar(u8, s.inbuf.items, '\n') orelse return;
        s.subscribed = true;
        const sub = std.json.parseFromSliceLeaky(agentwait.Subscribe, arena, s.inbuf.items[0..nl], .{ .ignore_unknown_fields = true }) catch
            return endSub(s, "bad subscribe line");
        const e = findByName(sub.agent) orelse
            return endSub(s, std.fmt.allocPrint(arena, "no agent {s} on this server", .{sub.agent}) catch "no such agent");
        s.agent = a.dupe(u8, e.id) catch return endSub(s, "out of memory");
        if (sub.match) |m| s.match = a.dupe(u8, m) catch return endSub(s, "out of memory");
        s.messages = sub.messages;
        s.follow = sub.follow;
        s.cursor = .{ .seen = sub.since orelse e.cursor.seen };
    }
    const e = findById(s.agent) orelse return endSub(s, "agent closed");
    const d = (s.cursor.take(e.agent.queue(), s.filter(), now_ms, arena) catch return) orelse return;
    sendLine(s, agentwait.encodeWake(arena, e.id, e.agent.state(), d, e.agent.queue()) catch return);
    if (!s.follow) s.done = true;
}

/// Send the end line and let the client go.
fn endSub(s: *Sub, reason: []const u8) void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    sendLine(s, agentwait.encodeEnd(fba.allocator(), agentwait.clip(reason, 400)) catch "");
    s.done = true;
}

/// Write a whole line or give the client up: a waiter that does not read
/// its few short lines is gone, and the loop never blocks on it.
fn sendLine(s: *Sub, line: []const u8) void {
    var off: usize = 0;
    while (off < line.len) {
        const n = c.send(s.fd, line[off..].ptr, line.len - off, c.MSG_NOSIGNAL | c.MSG_DONTWAIT);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            s.done = true;
            return;
        }
        off += @intCast(n);
    }
}

fn freeSub(a: std.mem.Allocator, s: *Sub) void {
    _ = c.close(s.fd);
    s.inbuf.deinit(a);
    if (s.agent.len > 0) a.free(s.agent);
    if (s.match) |m| a.free(m);
    a.destroy(s);
}

/// End the waiters of an agent that is going away.
fn endWaitersOf(id: []const u8, reason: []const u8) void {
    const a = state.allocator;
    var i: usize = 0;
    while (i < state.waiter.subs.items.len) {
        const s = state.waiter.subs.items[i];
        if (s.subscribed and std.mem.eql(u8, s.agent, id)) {
            endSub(s, reason);
            freeSub(a, s);
            _ = state.waiter.subs.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

// ── tools ────────────────────────────────────────────────────────

/// A refusal with its code, for helpers whose caller builds the result.
const Fail = struct { code: mcp.ErrCode, msg: []const u8 };

pub fn agentTool(arena: std.mem.Allocator, tool: Tool, args: std.json.Value) ![]const u8 {
    if (!available())
        return errRes(arena, .unavailable, "the agent tools need an isolated or durable instance (the default, or --durable/--name); this server runs --shared, where agents are not available");
    return switch (tool) {
        .agent_adapters => adaptersTool(arena, args),
        .agent_open => openTool(arena, args),
        .agent_attach => attachTool(arena, args),
        .agent_list => listTool(arena),
        .agent_send => withEntry(arena, args, sendTool),
        .agent_wait => withEntry(arena, args, waitTool),
        .agent_read => withEntry(arena, args, readTool),
        .agent_answer => withEntry(arena, args, answerTool),
        .agent_set => withEntry(arena, args, setTool),
        .agent_interrupt => withEntry(arena, args, interruptTool),
        .agent_close => withEntry(arena, args, closeTool),
    };
}

fn withEntry(
    arena: std.mem.Allocator,
    args: std.json.Value,
    comptime body: fn (std.mem.Allocator, std.json.Value, *Entry) anyerror![]const u8,
) ![]const u8 {
    service(clock.nowMs());
    const e = entryFromArgs(args) orelse return notFound(arena, args);
    reconnectIfLost(e);
    return body(arena, args, e);
}

fn entryFromArgs(args: std.json.Value) ?*Entry {
    if (argStr(args, "agent")) |name| return findByName(name);
    if (state.entries.items.len == 1) return state.entries.items[0];
    return null;
}

fn idList(arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (state.entries.items, 0..) |e, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, e.id);
    }
    return out.items;
}

fn notFound(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const open = try idList(arena);
    const msg = if (argStr(args, "agent")) |name|
        try std.fmt.allocPrint(arena, "no agent '{s}' (open: {s})", .{ name, if (open.len > 0) open else "none" })
    else if (state.entries.items.len == 0)
        "no agents are open; start one with agent_open"
    else
        try std.fmt.allocPrint(arena, "several agents are open ({s}): pass 'agent'", .{open});
    return errRes(arena, .not_found, msg);
}

fn filterFrom(args: std.json.Value) events.Filter {
    const m = argStr(args, "match");
    return .{ .messages = argBool(args, "messages"), .match = if (m != null and m.?.len > 0) m else null };
}

fn deadlineFrom(args: std.json.Value, default_ms: i64) i64 {
    return clock.nowMs() + mcp.waitCap(argInt(args, "timeout_ms"), default_ms);
}

// ── results ──────────────────────────────────────────────────────

/// What a call hands the assistant: the events it had not been handed,
/// and whether a wait was part of the call.
const Delivered = struct {
    items: []const events.Item = &.{},
    digest: ?events.Digest = null,
    wait: ?WaitPart = null,
};

const WaitPart = struct {
    /// Items from here on arrived during the wait; earlier ones were
    /// pending before the call acted.
    post_from: usize,
    timed_out: bool,
};

/// A payload block of the text lane (after the prose).
const Block = struct { name: []const u8, body: []const u8 };

/// Events pending before the call plus what `wait` delivered.
fn combine(arena: std.mem.Allocator, pre: ?events.Delivery, post: ?events.Delivery, waited: bool, timed_out: bool) !Delivered {
    var items: std.ArrayList(events.Item) = .empty;
    var digest: ?events.Digest = null;
    if (pre) |p| {
        try items.appendSlice(arena, p.items);
        digest = p.digest;
    }
    const post_from = items.items.len;
    if (post) |p| {
        try items.appendSlice(arena, p.items);
        if (p.digest) |d| digest = if (digest) |old| .{ .count = old.count + d.count, .latest_seq = d.latest_seq } else d;
    }
    return .{
        .items = items.items,
        .digest = digest,
        .wait = if (waited) .{ .post_from = post_from, .timed_out = timed_out } else null,
    };
}

/// Pending always-on events, for results that do not wait.
fn pending(arena: std.mem.Allocator, e: *Entry) !Delivered {
    return combine(arena, try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena), null, false, false);
}

/// The kind a wake-up reports: the delivered kind of the highest
/// `outcomeRank`, else `exited` for an agent that is gone, else still
/// working.
pub fn outcomeOf(items: []const events.Item, st: vocab.State) []const u8 {
    var best: ?vocab.EventKind = null;
    for (items) |it| {
        if (best == null or it.kind.outcomeRank() > best.?.outcomeRank()) best = it.kind;
    }
    if (best) |b| return @tagName(b);
    if (st == .exited) return @tagName(vocab.EventKind.exited);
    return mcp_tools.OUTCOME_STILL_WORKING;
}

const EventJson = struct {
    seq: u64,
    kind: []const u8,
    text: []const u8,
    detail: []const u8,
    count: u32,
    class: ?[]const u8 = null,
    job: ?u32 = null,
};

const InteractionJson = struct {
    kind: []const u8,
    title: []const u8,
    detail: []const u8,
    hint: []const u8,
    options: []const output.Option,
};

fn toJson(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
}

/// The facts and prose every per-agent result shares, then the payload
/// blocks (`extra` first) and the finished result.
fn finish(arena: std.mem.Allocator, res: *Res, e: *Entry, dv: Delivered, filter: events.Filter, extra: []const Block) ![]const u8 {
    const st = e.agent.state();
    const q = e.agent.queue();
    try res.fact("agent", e.id);
    try res.fact("app", e.loaded.spec.id);
    try res.fact("source", @tagName(e.agent.kind()));
    try res.fact("state", @tagName(st));
    try res.fact("ready", e.agent.ready());
    try res.fact("session", e.session);
    if (e.server_session) |s| try res.fact("server_session", s);
    if (e.host) |h| try res.fact("host", h);
    try res.fact("transport", @tagName(e.transport));

    var message: ?[]const u8 = null;
    var job_block: ?Block = null;
    if (dv.wait) |w| {
        const post = dv.items[w.post_from..];
        const outcome = outcomeOf(post, st);
        try res.fact("outcome", outcome);
        var job: ?u32 = null;
        for (post) |it| if (it.kind == .done) {
            message = it.event.text;
            job = it.event.job;
        };
        if (message) |m| try res.fact("message", m);
        // The finished job as agent_read would return it: no extra read.
        if (job) |j| {
            var one = [1]u32{j};
            const recs = e.agent.records();
            const sel = try select.select(arena, recs, .{ .list = &one, .fallback = false }, .{});
            job_block = .{ .name = try std.fmt.allocPrint(arena, "job {d}", .{j}), .body = try writeSelection(arena, res, recs, sel) };
        }
        try res.fact("timed_out", w.timed_out);
        try res.textf("{s}: {s} (state {s})", .{ e.id, outcome, @tagName(st) });
        if (w.timed_out)
            try res.text("still working when the wait ran out: run watch_command in the background (or as a Monitor with --follow) to be woken instead of polling");
    } else try res.textf("{s}: state {s}", .{ e.id, @tagName(st) });

    const evs = try arena.alloc(EventJson, dv.items.len);
    for (dv.items, evs) |it, *out| out.* = .{
        .seq = it.event.seq,
        .kind = @tagName(it.kind),
        .text = it.event.text,
        .detail = it.event.detail,
        .count = it.event.count,
        .class = if (it.event.class) |cls| @tagName(cls) else null,
        .job = it.event.job,
    };
    try res.raw("events", try toJson(arena, evs));
    if (dv.digest) |g| {
        const latest = if (q.bySeq(g.latest_seq)) |ev| ev.text else "";
        try res.raw("digest", try toJson(arena, .{ .count = g.count, .latest = latest }));
        try res.textf("{d} more opt-in event(s) held back by the rate limit", .{g.count});
    }
    const it = e.agent.interaction();
    if (it) |x| try res.raw("interaction", try toJson(arena, InteractionJson{
        .kind = @tagName(x.kind),
        .title = x.title,
        .detail = x.detail,
        .hint = x.hint,
        .options = x.options,
    }));
    var cmd: ?[]const u8 = null;
    if (state.exe) |exe| {
        if (state.waiter.path) |sock| {
            cmd = try agentwait.watchCommand(arena, exe, sock, e.id, filter);
            try res.fact("watch_command", cmd.?);
        }
    }

    for (extra) |b| try block(res, b);
    // The job block holds the message among its selected ones.
    if (job_block) |b| try block(res, b) else if (message) |m| try block(res, .{ .name = "message", .body = m });
    if (dv.items.len > 0) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        for (dv.items, 0..) |ev, i| {
            if (i > 0) try aw.writer.writeAll("\n");
            try aw.writer.print("{d} {s}", .{ ev.event.seq, @tagName(ev.kind) });
            if (ev.event.count > 1) try aw.writer.print(" (x{d})", .{ev.event.count});
            if (ev.event.text.len > 0) try aw.writer.print(": {s}", .{agentwait.clip(ev.event.text, 300)});
        }
        try block(res, .{ .name = "events", .body = aw.written() });
    }
    if (it) |x| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.print("{s}: {s}", .{ @tagName(x.kind), x.title });
        if (x.detail.len > 0) try aw.writer.print("\n{s}", .{x.detail});
        for (x.options, 1..) |o, n| try aw.writer.print("\n{d}. {s}{s}", .{ n, o.label, if (o.selected) " (selected)" else "" });
        if (x.hint.len > 0) try aw.writer.print("\n{s}", .{x.hint});
        try block(res, .{ .name = "prompt", .body = aw.written() });
    }
    if (cmd) |x| try block(res, .{ .name = "watch_command", .body = x });
    return res.finish();
}

fn block(res: *Res, b: Block) !void {
    try res.textf("--- {s} ---", .{b.name});
    try res.text(b.body);
}

// ── agent_adapters ───────────────────────────────────────────────

/// An SSH destination as a caller may name it: no option-looking or
/// blank-carrying string ever reaches an ssh argv.
fn validHost(h: []const u8) bool {
    if (h.len == 0 or h.len > 255 or h[0] == '-') return false;
    for (h) |b| if (b <= 0x20 or b == 0x7f) return false;
    return true;
}

const BAD_HOST = "host must be an SSH destination (user@box or an ssh config alias)";

/// Resolve executables on `host` in one ssh round trip (`launch.probeScript`).
fn probeRemote(arena: std.mem.Allocator, host: []const u8, lookups: []const launch.Lookup, dir: ?[]const u8) !union(enum) { ok: launch.ProbeResult, fail: Fail } {
    const script = try launch.probeScript(arena, lookups, dir);
    const argv = mcp_term.remoteShArgv(arena, host, script) catch
        return .{ .fail = .{ .code = .refused, .msg = "cannot build the forced route for this host" } };
    switch (try mcp_term.runArgvTerm(arena, argv, PROBE_WAIT_MS)) {
        .err => |m| return .{ .fail = .{ .code = .unavailable, .msg = m } },
        .run => |r| {
            const res = try launch.parseProbe(arena, r.output, lookups.len);
            if (r.exited and r.status_known and r.status == 0 and res.complete) return .{ .ok = res };
            return .{ .fail = .{ .code = .unavailable, .msg = try std.fmt.allocPrint(arena, "could not look the agent up on {s} over ssh (key or agent auth is required; {s}):\n{s}", .{
                host,
                if (!r.exited) "the probe did not finish in time" else "the probe failed",
                mcp.tailLines(r.output, 8),
            }) } };
        },
    }
}

fn adaptersTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const set = try adapters();
    const host = argStr(args, "host");
    var remote: ?launch.ProbeResult = null;
    if (host) |h| {
        if (!validHost(h)) return errRes(arena, .invalid_args, BAD_HOST);
        const lookups = try arena.alloc(launch.Lookup, set.items.items.len);
        for (set.items.items, lookups) |l, *out| out.* = .{ .launch = l.spec.launch };
        switch (try probeRemote(arena, h, lookups, null)) {
            .fail => |f| return errRes(arena, f.code, f.msg),
            .ok => |r| remote = r,
        }
    }
    const Item = struct {
        id: []const u8,
        name: []const u8,
        source: []const u8,
        origin: []const u8,
        file: []const u8,
        installed: bool,
        binary: ?[]const u8,
        actions: []const []const u8,
    };
    const items = try arena.alloc(Item, set.items.items.len);
    var res = Res.init(arena);
    if (host) |h| {
        try res.textf("{d} agent adapter(s), binaries looked up on {s}", .{ items.len, h });
        try res.fact("host", h);
    } else try res.textf("{d} agent adapter(s) on this machine", .{items.len});
    var listing: std.Io.Writer.Allocating = .init(arena);
    for (set.items.items, items, 0..) |l, *out, i| {
        const bin = if (remote) |r| r.binaries[i] else try launch.resolve(arena, l.spec.launch, null, localHost());
        var acts: std.ArrayList([]const u8) = .empty;
        for (std.enums.values(agent_mod.ActionKind)) |k| {
            if (agent_mod.supportsAction(l, k)) try acts.append(arena, @tagName(k));
        }
        out.* = .{
            .id = l.spec.id,
            .name = l.spec.name,
            .source = @tagName(l.spec.source),
            .origin = @tagName(l.origin),
            .file = l.source,
            .installed = bin != null,
            .binary = bin,
            .actions = acts.items,
        };
        if (i > 0) try listing.writer.writeAll("\n");
        try listing.writer.print("{s} ({s}, {s} source, {s}): {s}", .{
            l.spec.id,
            l.spec.name,
            @tagName(l.spec.source),
            @tagName(l.origin),
            if (bin) |b| b else "NOT installed (agent_open accepts binary: a name or an absolute path)",
        });
    }
    try res.fact("adapters", items);
    try res.fact("count", items.len);
    try res.fact("problems", set.problems.items);
    if (set.problems.items.len > 0) try res.textf("{d} adapter file(s) could not be loaded", .{set.problems.items.len});
    try block(&res, .{ .name = "adapters", .body = listing.written() });
    if (set.problems.items.len > 0) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        for (set.problems.items, 0..) |p, i| {
            if (i > 0) try aw.writer.writeAll("\n");
            try aw.writer.writeAll(p);
        }
        try block(&res, .{ .name = "problems", .body = aw.written() });
    }
    return res.finish();
}

// ── agent_open / agent_attach ────────────────────────────────────

const OpenOpts = struct {
    override: ?[]const u8,
    model: ?[]const u8,
    effort: ?[]const u8,
    /// Absolute; null with a host until the probe names the remote home.
    cwd: ?[]const u8,
    prompt: ?[]const u8,
    cols: u16,
    rows: u16,
    host: ?[]const u8,
    choice: transport_mod.Choice,
    extra: launch.Extra,
};

/// agent_open's `args` (strings) and `env` (string values), checked by
/// `launch.checkExtra`.
fn extraOpts(arena: std.mem.Allocator, args: std.json.Value, loaded: *const adapter.Loaded, why: *Fail) !launch.Extra {
    var x: launch.Extra = .{};
    if (mcp.argValue(args, "args")) |v| if (v != .null) {
        if (v != .array) {
            why.* = .{ .code = .invalid_args, .msg = "args must be an array of strings" };
            return error.Refused;
        }
        const out = try arena.alloc([]const u8, v.array.items.len);
        for (v.array.items, out) |item, *o| {
            if (item != .string) {
                why.* = .{ .code = .invalid_args, .msg = "args must be an array of strings" };
                return error.Refused;
            }
            o.* = item.string;
        }
        x.args = out;
    };
    if (mcp.argValue(args, "env")) |v| if (v != .null) {
        if (v != .object) {
            why.* = .{ .code = .invalid_args, .msg = "env must be an object of variable names to string values" };
            return error.Refused;
        }
        const out = try arena.alloc(launch.EnvVar, v.object.count());
        var it = v.object.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            if (kv.value_ptr.* != .string) {
                why.* = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "env {f} must be a string", .{std.json.fmt(kv.key_ptr.*, .{})}) };
                return error.Refused;
            }
            out[i] = .{ .name = kv.key_ptr.*, .value = kv.value_ptr.string };
        }
        x.env = out;
    };
    if (try launch.checkExtra(arena, loaded.spec.launch, x)) |msg| {
        why.* = .{ .code = .invalid_args, .msg = msg };
        return error.Refused;
    }
    return x;
}

fn openOpts(arena: std.mem.Allocator, args: std.json.Value, loaded: *const adapter.Loaded, why: *Fail) !OpenOpts {
    const override = argStr(args, "binary");
    if (override) |b| if (!launch.validBinary(b)) {
        why.* = .{ .code = .invalid_args, .msg = "binary must be a bare executable name or an absolute path of plain characters (no shell metacharacters, no ..)" };
        return error.Refused;
    };
    const extra = try extraOpts(arena, args, loaded, why);
    inline for (.{ "model", "effort" }) |key| {
        if (argStr(args, key)) |v| if (!launch.validValue(v)) {
            why.* = .{ .code = .invalid_args, .msg = key ++ " must be 1-256 printable characters" };
            return error.Refused;
        };
    }
    if (argStr(args, "effort")) |x| if (!launch.validEffort(loaded.spec.launch, x)) {
        why.* = .{ .code = .invalid_args, .msg = try effortRefusal(arena, loaded) };
        return error.Refused;
    };
    const host = argStr(args, "host");
    if (host) |h| if (!validHost(h)) {
        why.* = .{ .code = .invalid_args, .msg = BAD_HOST };
        return error.Refused;
    };
    const choice = mcp_term.transportChoice(args) orelse {
        why.* = .{ .code = .invalid_args, .msg = "transport must be 'auto', 'mux' or 'ssh'" };
        return error.Refused;
    };
    const cwd: ?[]const u8 = if (argStr(args, "cwd")) |d| blk: {
        // A remote dir is checked by the host's probe.
        if (d.len == 0 or d[0] != '/' or (host == null and !isDir(d))) {
            why.* = .{ .code = .invalid_args, .msg = "cwd must be an absolute path to an existing directory" };
            return error.Refused;
        }
        break :blk d;
    } else if (host != null) null else blk: {
        var buf: [4096]u8 = undefined;
        const p = c.getcwd(&buf, buf.len) orelse break :blk "/";
        break :blk try arena.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(p))));
    };
    const prompt = argStr(args, "prompt");
    if (prompt) |p| if (std.mem.trim(u8, p, " \t\r\n").len == 0) {
        why.* = .{ .code = .invalid_args, .msg = "prompt is empty" };
        return error.Refused;
    };
    return .{
        .override = override,
        .model = argStr(args, "model"),
        .effort = argStr(args, "effort"),
        .cwd = cwd,
        .prompt = prompt,
        .cols = @intCast(std.math.clamp(argInt(args, "cols") orelse DEFAULT_COLS, 40, 500)),
        .rows = @intCast(std.math.clamp(argInt(args, "rows") orelse DEFAULT_ROWS, 10, 300)),
        .host = host,
        .choice = choice,
        .extra = extra,
    };
}

fn effortRefusal(arena: std.mem.Allocator, loaded: *const adapter.Loaded) ![]const u8 {
    return std.fmt.allocPrint(arena, "effort must be one of: {s}", .{try std.mem.join(arena, ", ", loaded.spec.launch.effort_values)});
}

fn isDir(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    var st: c.struct_stat = undefined;
    return c.stat(z.ptr, &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFDIR;
}

fn candidateList(arena: std.mem.Allocator, loaded: *const adapter.Loaded) ![]const u8 {
    return std.mem.join(arena, ", ", loaded.spec.launch.candidates);
}

fn openTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const app = argStr(args, "app") orelse
        return errRes(arena, .invalid_args, "agent_open needs 'app': an adapter id from agent_adapters (claude, opencode, ...)");
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    const set = try adapters();
    const loaded = set.get(app) orelse {
        var ids: std.ArrayList(u8) = .empty;
        for (set.items.items, 0..) |l, i| {
            if (i > 0) try ids.appendSlice(arena, ", ");
            try ids.appendSlice(arena, l.spec.id);
        }
        return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "no adapter '{s}' (available: {s})", .{ app, ids.items }));
    };
    var why: Fail = undefined;
    var o = openOpts(arena, args, loaded, &why) catch |err| switch (err) {
        error.Refused => return errRes(arena, why.code, why.msg),
        else => return err,
    };
    const name = o.override orelse loaded.spec.launch.binary;
    const binary = if (o.host) |h| blk: {
        // One probe on the host: the binary from the adapter's candidates
        // (an ssh login's PATH lacks ~/.local/bin), the dir, the home.
        const r = switch (try probeRemote(arena, h, &.{.{ .launch = loaded.spec.launch, .override = o.override }}, o.cwd)) {
            .fail => |f| return errRes(arena, f.code, f.msg),
            .ok => |r| r,
        };
        if (r.dir_ok) |ok| if (!ok) return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "cwd {s} is not a directory on {s}", .{ o.cwd.?, h }));
        if (o.cwd == null) o.cwd = r.home orelse "/";
        break :blk r.binaries[0] orelse return errRes(arena, .unavailable, try std.fmt.allocPrint(arena, "cannot find {s} on {s} (looked in: {s}); pass 'binary' with its name or absolute path there", .{ name, h, try candidateList(arena, loaded) }));
    } else (try launch.resolve(arena, loaded.spec.launch, o.override, localHost())) orelse
        return errRes(arena, .unavailable, try std.fmt.allocPrint(arena, "cannot find {s} on this machine (looked in: {s}); pass 'binary' with its name or absolute path", .{ name, try candidateList(arena, loaded) }));

    var where = Where{ .host = o.host, .cols = o.cols, .rows = o.rows };
    const e = (switch (loaded.spec.source) {
        .screen => spawnScreen(arena, loaded, binary, o, &where, deadline, &why),
        .opencode_api => spawnApi(arena, loaded, binary, o, &where, deadline, &why),
    }) catch |err| switch (err) {
        error.Refused => return errRes(arena, why.code, why.msg),
        else => return err,
    };
    state.entries.append(state.allocator, e) catch |err| {
        e.destroy(true);
        return err;
    };
    writeDescriptor(e);
    publishAgents();

    const filter = filterFrom(args);
    const ready = waitReady(e, deadline);
    var notes: std.ArrayList([]const u8) = .empty;
    // A model or effort the launch cannot take goes through the app.
    if (ready) {
        if (o.model) |m| if (!launch.launchTakes(loaded.spec.launch, .model)) {
            if (try applySet(arena, e, .{ .set_model = m }, deadline)) |f| try notes.append(arena, try std.fmt.allocPrint(arena, "model not set: {s}", .{f.msg}));
        };
        if (o.effort) |x| if (!launch.launchTakes(loaded.spec.launch, .effort)) {
            if (try applySet(arena, e, .{ .set_effort = x }, deadline)) |f| try notes.append(arena, try std.fmt.allocPrint(arena, "effort not set: {s}", .{f.msg}));
        };
    }

    var dv: Delivered = undefined;
    var sent = false;
    if (o.prompt) |p| {
        if (ready) {
            switch (try submitAndWait(arena, e, p, filter, deadline)) {
                .fail => |f| {
                    try notes.append(arena, try std.fmt.allocPrint(arena, "prompt not sent: {s}", .{f.msg}));
                    dv = try pending(arena, e);
                },
                .ok => |d| {
                    sent = true;
                    dv = d;
                },
            }
        } else {
            try notes.append(arena, "prompt not sent: the agent was not ready within timeout_ms");
            dv = try pending(arena, e);
        }
    } else dv = try pending(arena, e);
    return openResult(arena, e, ready, sent, notes.items, dv, filter);
}

/// agent_open's result: the launch facts, then every per-agent fact.
fn openResult(arena: std.mem.Allocator, e: *Entry, ready: bool, sent: bool, notes: []const []const u8, dv: Delivered, filter: events.Filter) ![]const u8 {
    var res = Res.init(arena);
    if (e.host) |h|
        try res.textf("opened {s} ({s}) on {s} over {s} in session {s}", .{ e.id, e.loaded.spec.name, h, @tagName(e.transport), e.session })
    else
        try res.textf("opened {s} ({s}) in session {s}", .{ e.id, e.loaded.spec.name, e.session });
    if (!ready) try res.textf("not ready yet (state {s}); agent_send waits for it", .{@tagName(e.agent.state())});
    if (notes.len > 0) try res.textf("{d} note(s) below", .{notes.len});
    try res.fact("binary", e.binary);
    try res.fact("cwd", e.cwd);
    // The values of `env` are never echoed: only what was set.
    const env_names = try e.extra.names(arena);
    try res.fact("args", e.extra.args);
    try res.fact("env_names", env_names);
    if (e.extra.args.len > 0 or env_names.len > 0)
        try res.textf("launched with {d} extra arg(s) and env {s}", .{ e.extra.args.len, if (env_names.len == 0) "(none)" else try std.mem.join(arena, ", ", env_names) });
    if (e.recordings.items.len > 0) try res.fact("recordings", e.recordings.items);
    try res.fact("prompt_sent", sent);
    var extra: std.ArrayList(Block) = .empty;
    try extra.append(arena, .{ .name = "binary", .body = e.binary });
    if (notes.len > 0) try extra.append(arena, .{ .name = "notes", .body = try std.mem.join(arena, "\n", notes) });
    return finish(arena, &res, e, dv, filter, extra.items);
}

fn randomHex(a: std.mem.Allocator, comptime nbytes: usize) ![]u8 {
    var raw: [nbytes]u8 = undefined;
    if (c.getentropy(&raw, raw.len) != 0) return error.NoEntropy;
    defer std.crypto.secureZero(u8, &raw);
    const out = try a.alloc(u8, nbytes * 2);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}

/// A random (version 4) UUID, the form `--session-id` takes.
fn newUuid(a: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    if (c.getentropy(&raw, raw.len) != 0) return error.NoEntropy;
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

fn newEntry(loaded: *const adapter.Loaded, id: []const u8, session: []const u8, binary: []const u8, cwd: []const u8) !*Entry {
    const a = state.allocator;
    const e = try a.create(Entry);
    errdefer a.destroy(e);
    const id_owned = try a.dupe(u8, id);
    errdefer a.free(id_owned);
    const session_owned = try a.dupe(u8, session);
    errdefer a.free(session_owned);
    const binary_owned = try a.dupe(u8, binary);
    errdefer a.free(binary_owned);
    const cwd_owned = try a.dupe(u8, cwd);
    e.* = .{
        .allocator = a,
        .id = id_owned,
        .loaded = loaded,
        .agent = undefined,
        .session = session_owned,
        .visible = null,
        .binary = binary_owned,
        .cwd = cwd_owned,
    };
    return e;
}

/// Copy where the agent runs and what its launch passed into `e`.
fn setPlace(e: *Entry, where: Where, o: OpenOpts) !void {
    const a = e.allocator;
    e.transport = where.transport;
    e.cols = where.cols;
    e.rows = where.rows;
    if (where.host) |h| e.host = try a.dupe(u8, h);
    if (o.model) |m| e.launch_model = try a.dupe(u8, m);
    if (o.effort) |x| e.launch_effort = try a.dupe(u8, x);
    e.extra = try o.extra.clone(a);
}

/// Free a half-built entry whose agent is not set yet (the terms it
/// points at are the caller's to release).
fn dropBare(e: *Entry) void {
    e.freeFields();
    state.allocator.destroy(e);
}

/// Record a terminal of `e` as `<name>.cast`. A session on a remote
/// daemon is not recorded: the daemon writes the file, on ITS host.
fn record(e: *Entry, t: *termdrive.Term, name: []const u8) void {
    if (t.remote_host != null) return;
    const path = mcp_term.recordNamedTerm(state.allocator, t, name) orelse return;
    e.recordings.append(state.allocator, path) catch state.allocator.free(path);
}

/// What a spawn on the agent's host needs besides the argv.
const SpawnSpec = struct {
    name: []const u8,
    cwd: []const u8,
    /// Local sessions only: the secret's environment ("KEY=VALUE").
    env: []const []const u8 = &.{},
    /// Remote starts: the variable to read off the terminal (then the
    /// caller types its value at `launch.SECRET_PROMPT`).
    secret_env: ?[]const u8 = null,
    /// The caller's `env`, on every transport: the spawn request's
    /// environment, or exported by a plain-ssh start's script.
    extra_env: []const launch.EnvVar = &.{},
};

/// Start `argv` on the agent's host as session `spec.name`. A remote
/// start whose transport is not decided yet (`where.transport == .local`
/// with a host) tries the host's own daemon first unless `choice` says
/// ssh, falls back to plain `ssh -tt` unless it says mux, and records
/// the outcome in `where`.
fn spawnOn(arena: std.mem.Allocator, where: *Where, choice: transport_mod.Choice, argv: []const []const u8, spec: SpawnSpec, why: *Fail) !*termdrive.Term {
    const a = state.allocator;
    const extra_kv = try (launch.Extra{ .env = spec.extra_env }).assignments(arena);
    const host = where.host orelse {
        if (!try fitsExec(arena, argv, why)) return error.Refused;
        return termdrive.Term.spawnWith(a, argv, where.cols, where.rows, state.mux_sock, .{
            .name = spec.name,
            .env = try std.mem.concat(arena, []const u8, &.{ spec.env, extra_kv }),
            .cwd = spec.cwd,
            .shell_integration = false,
        }) catch {
            why.* = .{ .code = .unavailable, .msg = "could not start the agent's session on the private daemon" };
            return error.Refused;
        };
    };
    const undecided = where.transport == .local;
    if ((undecided and choice != .ssh) or where.transport == .@"sketerm-mux") mux: {
        const margv: []const []const u8 = if (spec.secret_env) |v|
            try arena.dupe([]const u8, &.{ "/bin/sh", "-c", try launch.remoteScript(arena, argv, .{ .secret_env = v }) })
        else
            argv;
        if (!try fitsExec(arena, margv, why)) return error.Refused;
        const t = termdrive.Term.spawnRemoteMux(a, host, margv, where.cols, where.rows, .{ .name = spec.name, .cwd = spec.cwd, .env = extra_kv }) catch {
            if (!undecided or choice == .mux) {
                why.* = .{ .code = .unavailable, .msg = mcp_term.NO_REMOTE_MUX };
                return error.Refused;
            }
            break :mux;
        };
        where.transport = .@"sketerm-mux";
        return t;
    }
    // Plain ssh: the script rides the ssh command (base64, dialect-proof)
    // and runs with the terminal on stdin; no secret ever goes in it (the
    // caller's env does: it is documented as no place for secrets).
    const nonce = try randomHex(arena, 6);
    const file = try std.fmt.allocPrint(arena, "/tmp/.sk_ssh_{s}", .{nonce});
    const script = try launch.remoteScript(arena, argv, .{ .cleanup = file, .cwd = spec.cwd, .secret_env = spec.secret_env, .env = spec.extra_env });
    var sargv: std.ArrayList([]const u8) = .empty;
    mcp_term.appendSshTt(arena, &sargv, host) catch {
        why.* = .{ .code = .refused, .msg = "cannot build the forced route for this host" };
        return error.Refused;
    };
    try sargv.append(arena, try termdrive.sshScriptCommand(arena, nonce, script));
    if (!try fitsExec(arena, sargv.items, why)) return error.Refused;
    const t = termdrive.Term.spawnWith(a, sargv.items, where.cols, where.rows, state.mux_sock, .{
        .name = spec.name,
        .shell_integration = false,
    }) catch {
        why.* = .{ .code = .unavailable, .msg = "could not start the agent's ssh session on the private daemon" };
        return error.Refused;
    };
    where.transport = .ssh;
    return t;
}

/// Whether every string of a start's argv can be exec'd (a plain-ssh
/// start carries `args` and `env` inside one quoted, base64'd string).
fn fitsExec(arena: std.mem.Allocator, argv: []const []const u8, why: *Fail) !bool {
    if (launch.argvFits(argv)) return true;
    var longest: usize = 0;
    for (argv) |s| longest = @max(longest, s.len);
    why.* = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "the start command is too long once args and env are quoted for the shell ({d} bytes in one argument; at most {d}): pass fewer or shorter args/env", .{ longest, launch.MAX_EXEC_STRING - 1 }) };
    return false;
}

/// Type `secret` into a remote start once it asks for it (echo is off
/// there by then, so nothing shows, and nothing is recorded).
fn typeSecret(arena: std.mem.Allocator, t: *termdrive.Term, secret: []const u8, deadline: i64, what: []const u8, why: *Fail) !void {
    const until = @min(deadline, clock.nowMs() + SECRET_WAIT_MS);
    while (true) {
        t.drain();
        if (t.readScreen(false)) |text| {
            defer t.allocator.free(text);
            if (std.mem.indexOf(u8, text, launch.SECRET_PROMPT) != null) break;
        } else |_| {}
        if (t.exited) {
            why.* = .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "{s} ended before it started (last line: {s})", .{ what, mcp_term.termLastLine(arena, t) }) };
            return error.Refused;
        }
        if (clock.nowMs() >= until) {
            why.* = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "{s} did not start in time (ssh still connecting or asking for a password? last line: {s})", .{ what, mcp_term.termLastLine(arena, t) }) };
            return error.Refused;
        }
        pumpFor(100);
    }
    const line = try std.fmt.allocPrint(state.allocator, "{s}\r", .{secret});
    defer {
        std.crypto.secureZero(u8, line);
        state.allocator.free(line);
    }
    t.sendText(line) catch {
        why.* = .{ .code = .unavailable, .msg = try std.fmt.allocPrint(arena, "{s}: the session is gone", .{what}) };
        return error.Refused;
    };
}

fn spawnScreen(arena: std.mem.Allocator, loaded: *const adapter.Loaded, binary: []const u8, o: OpenOpts, where: *Where, deadline: i64, why: *Fail) !*Entry {
    _ = deadline;
    const a = state.allocator;
    const spec = &loaded.spec;
    const n = try nextNumber(spec.id);
    const id = try std.fmt.allocPrint(arena, "{s}-{d}", .{ spec.id, n });
    const session = try std.fmt.allocPrint(arena, "agent-{s}", .{id});
    // A conversation id the agent owns, so a relaunch resumes exactly it.
    const conversation: ?[]const u8 = if (spec.launch.session_args.len > 0) try newUuid(arena) else null;
    const argv = try launch.startArgv(arena, spec.launch, binary, o.extra, .{
        .model = o.model,
        .effort = o.effort,
        .cwd = o.cwd,
        .session = conversation,
    }, .{ .main = .fresh });
    const t = try spawnOn(arena, where, o.choice, argv, .{ .name = session, .cwd = o.cwd.?, .extra_env = o.extra.env }, why);
    errdefer t.deinit();
    const e = try newEntry(loaded, id, session, binary, o.cwd.?);
    errdefer dropBare(e);
    try setPlace(e, where.*, o);
    if (conversation) |cv| e.conversation = try a.dupe(u8, cv);
    const ag = try a.create(agent_mod.Agent);
    errdefer a.destroy(ag);
    ag.* = try agent_mod.Agent.initScreen(a, loaded, .{});
    e.agent = ag;
    e.visible = .{ .owned = t };
    e.seen_snapshots = t.snapshots;
    record(e, t, session);
    return e;
}

/// Wait until an API server answers its health route (`probeHealth`),
/// watching its session: a server that swallows the requests of its
/// first seconds is waited out, one that exits is reported as such.
fn waitServerReady(arena: std.mem.Allocator, api: *opencode.Api, server: *termdrive.Term, what: []const u8, deadline: i64, why: *Fail) !void {
    const started = clock.nowMs();
    while (true) {
        server.drain();
        if (server.exited and !server.lost) {
            why.* = .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "{s} exited before it was ready (last line: {s})", .{ what, mcp_term.termLastLine(arena, server) }) };
            return error.Refused;
        }
        const now = clock.nowMs();
        if (now >= deadline) {
            why.* = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "{s} did not become ready within {d} ms (no answer to GET {s}: {s}; its last line: {s})", .{
                what, now - started, opencode.HEALTH_PATH, api.problem(), mcp_term.termLastLine(arena, server),
            }) };
            return error.Refused;
        }
        const ok = api.probeHealth(@min(deadline, now + opencode.HEALTH_PROBE_MS)) catch |err| switch (err) {
            error.Unauthorized => {
                why.* = .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "{s} refused the password it was started with: {s}", .{ what, api.problem() }) };
                return error.Refused;
            },
            else => return err,
        };
        if (ok) return;
        pumpFor(100);
    }
}

fn spawnApi(arena: std.mem.Allocator, loaded: *const adapter.Loaded, binary: []const u8, o: OpenOpts, where: *Where, deadline: i64, why: *Fail) !*Entry {
    const a = state.allocator;
    const spec = &loaded.spec;
    const pw_env = spec.launch.password_env orelse unreachable; // adapter.zig requires it for API sources
    const cwd = o.cwd.?;
    // The API client's port, here. A remote server listens on its own
    // host's loopback; the client reaches it through a forward from `port`.
    const port = mcp_term.pickFreePort() orelse {
        why.* = .{ .code = .unavailable, .msg = "no free local port for the app's server" };
        return error.Refused;
    };
    const server_port: u16 = if (where.host == null) port else try remotePort(port);
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{server_port}) catch unreachable;
    const password = try randomHex(a, 24);
    errdefer {
        std.crypto.secureZero(u8, password);
        a.free(password);
    }
    const env_kv = try std.fmt.allocPrint(arena, "{s}={s}", .{ pw_env, password });
    defer std.crypto.secureZero(u8, env_kv);
    // Local: the spawn request's environment. Remote: typed at the prompt.
    const env: []const []const u8 = if (where.host == null) try arena.dupe([]const u8, &.{env_kv}) else &.{};
    const secret_env: ?[]const u8 = if (where.host == null) null else pw_env;

    const n = try nextNumber(spec.id);
    const id = try std.fmt.allocPrint(arena, "{s}-{d}", .{ spec.id, n });
    const session = try std.fmt.allocPrint(arena, "agent-{s}", .{id});
    const server_session = try std.fmt.allocPrint(arena, "agent-{s}-server", .{id});
    const what = try std.fmt.allocPrint(arena, "the {s} server", .{spec.name});
    const server_argv = try launch.startArgv(arena, spec.launch, binary, o.extra, .{
        .port = port_str,
        .cwd = cwd,
        .model = o.model,
        .effort = o.effort,
    }, .{ .main = .fresh });
    const server = try spawnOn(arena, where, o.choice, server_argv, .{ .name = server_session, .cwd = cwd, .env = env, .secret_env = secret_env, .extra_env = o.extra.env }, why);
    errdefer server.deinit();
    if (secret_env != null) try typeSecret(arena, server, password, deadline, what, why);

    var forward: ?*termdrive.Term = null;
    errdefer if (forward) |f| f.deinit();
    if (where.host) |h| {
        const f = mcp_term.spawnForwardTermNamed(arena, h, port, "127.0.0.1", server_port, try forwardName(arena, id)) catch {
            why.* = .{ .code = .unavailable, .msg = "could not start the port forward to the app's server" };
            return error.Refused;
        };
        forward = f;
        switch (try mcp_term.waitForwardReady(arena, f, port, @max(1000, @min(deadline, clock.nowMs() + PORT_WAIT_MS) - clock.nowMs()))) {
            .ready => {},
            .err => |m| {
                why.* = .{ .code = .unavailable, .msg = try std.fmt.allocPrint(arena, "the port forward to {s} did not come up: {s}", .{ h, m }) };
                return error.Refused;
            },
        }
    }

    const ag = try a.create(agent_mod.Agent);
    errdefer a.destroy(ag);
    ag.* = try agent_mod.Agent.initOpencode(a, loaded, .{}, .{ .port = port, .password = password });
    errdefer ag.deinit();
    const api = &ag.source.opencode_api;
    // The server listens a while before it answers, and swallows what it
    // gets in between: wait for its health route before the event stream.
    try waitServerReady(arena, api, server, what, @min(deadline, clock.nowMs() + PORT_WAIT_MS), why);
    api.connect(null, clock.nowMs()) catch |err| {
        why.* = .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "the {s} API refused the connection: {s}", .{ spec.name, if (api.problem().len > 0) api.problem() else @errorName(err) }) };
        return error.Refused;
    };
    const sid = api.sessionId() orelse {
        why.* = .{ .code = .failed, .msg = "the app's API created no session" };
        return error.Refused;
    };
    const tui_argv = try launch.startArgv(arena, spec.launch, binary, o.extra, .{
        .port = port_str,
        .cwd = cwd,
        .session = sid,
    }, .attach);
    const tui: ?*termdrive.Term = if (spec.launch.attach_args.len == 0) null else try spawnOn(arena, where, o.choice, tui_argv, .{ .name = session, .cwd = cwd, .env = env, .secret_env = secret_env, .extra_env = o.extra.env }, why);
    errdefer if (tui) |t| t.deinit();
    if (tui) |t| if (secret_env != null) try typeSecret(arena, t, password, deadline, "the attached client", why);

    const e = try newEntry(loaded, id, if (tui != null) session else server_session, binary, cwd);
    errdefer dropBare(e);
    try setPlace(e, where.*, o);
    e.server_session = try a.dupe(u8, server_session);
    e.agent = ag;
    e.visible = if (tui) |t| .{ .owned = t } else null;
    e.server = server;
    e.port = port;
    e.remote_port = if (where.host != null) server_port else 0;
    e.forward = forward;
    e.password = password;
    if (tui) |t| record(e, t, session);
    record(e, server, server_session);
    return e;
}

/// A port for an API server on a remote host, other than `local` (on a
/// loopback ssh both ends share one port space).
fn remotePort(local: u16) !u16 {
    var raw: [2]u8 = undefined;
    while (true) {
        if (c.getentropy(&raw, raw.len) != 0) return error.NoEntropy;
        const p: u16 = REMOTE_PORT_MIN + std.mem.readInt(u16, &raw, .little) % REMOTE_PORT_SPAN;
        if (p != local) return p;
    }
}

fn attachTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const term_id = argInt(args, "term") orelse return errRes(arena, .invalid_args, "agent_attach needs 'term': the id term_open returned");
    const app = argStr(args, "app") orelse return errRes(arena, .invalid_args, "agent_attach needs 'app': a screen adapter id from agent_adapters");
    const set = try adapters();
    const loaded = set.get(app) orelse return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "no adapter '{s}'", .{app}));
    if (loaded.spec.source != .screen)
        return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "agent_attach reads a terminal, and {s} is an {s} source; agent_open runs it", .{ app, @tagName(loaded.spec.source) }));
    if (term_id < 0 or term_id > std.math.maxInt(u32)) return errRes(arena, .invalid_args, "term out of range");
    const tid: u32 = @intCast(term_id);
    const t = mcp_term.term_state.terms.get(tid) orelse return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "no headless terminal {d} (term_list)", .{tid}));
    for (state.entries.items) |x| if (x.visible) |l| switch (l) {
        .borrowed => |b| if (b == tid) return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "terminal {d} already carries agent {s}", .{ tid, x.id })),
        .owned => {},
    };
    const a = state.allocator;
    const n = try nextNumber(loaded.spec.id);
    const id = try std.fmt.allocPrint(arena, "{s}-{d}", .{ loaded.spec.id, n });
    const e = try newEntry(loaded, id, t.name, "", "");
    errdefer dropBare(e);
    const ag = try a.create(agent_mod.Agent);
    errdefer a.destroy(ag);
    ag.* = try agent_mod.Agent.initScreen(a, loaded, .{});
    e.agent = ag;
    e.visible = .{ .borrowed = tid };
    e.seen_snapshots = t.snapshots;
    state.entries.append(a, e) catch |err| {
        e.destroy(false);
        return err;
    };
    publishAgents();
    const ready = waitReady(e, deadlineFrom(args, ATTACH_WAIT_MS));
    var res = Res.init(arena);
    try res.textf("{s} adapter attached to terminal {d} as {s}{s}", .{ loaded.spec.name, tid, e.id, if (ready) "" else " (not ready yet)" });
    try res.fact("term", tid);
    return finish(arena, &res, e, try pending(arena, e), .{}, &.{});
}

// ── acting ───────────────────────────────────────────────────────

/// Why the agent cannot take a prompt or a setting now, or null when it
/// is idle.
fn busy(arena: std.mem.Allocator, e: *Entry) !?Fail {
    const st = e.agent.state();
    return switch (st) {
        .idle => null,
        .starting => Fail{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "agent {s} is not ready yet (state starting); nothing was sent", .{e.id}) },
        .working, .waiting_subagent, .retrying => Fail{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} is busy (state {s}): agent_wait for its turn to finish, or agent_interrupt it", .{ e.id, @tagName(st) }) },
        .waiting_user => Fail{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} is waiting for an answer: agent_answer its prompt first", .{e.id}) },
        .exited, .disconnected => Fail{ .code = .unavailable, .msg = try std.fmt.allocPrint(arena, "agent {s} is {s}; agent_close it", .{ e.id, @tagName(st) }) },
    };
}

const Sent = union(enum) { ok: Delivered, fail: Fail };

fn submitAndWait(arena: std.mem.Allocator, e: *Entry, text: []const u8, filter: events.Filter, deadline: i64) !Sent {
    service(clock.nowMs());
    const pre = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena);
    _ = waitReady(e, deadline);
    if (try busy(arena, e)) |f| return .{ .fail = f };
    switch (try act(arena, e, .{ .submit = text }, deadline)) {
        .fail => |f| return .{ .fail = f },
        .ok => {},
    }
    // The conversation has a turn now: a relaunch resumes it.
    if (!e.conversed) {
        e.conversed = true;
        writeDescriptor(e);
    }
    return .{ .ok = try waitAfter(arena, e, pre, filter, deadline) };
}

/// The wait that follows an action, combined with what was pending
/// before it.
fn waitAfter(arena: std.mem.Allocator, e: *Entry, pre: ?events.Delivery, filter: events.Filter, deadline: i64) !Delivered {
    const post = try waitDelivery(e, filter, deadline, arena);
    return combine(arena, pre, post, true, post == null and !gone(e));
}

/// What an action came to.
const Acted = union(enum) {
    ok: Outcome,
    fail: Fail,
};

const Outcome = struct {
    /// The app's line confirming the action (a recipe's `confirm`).
    confirmation: ?[]const u8 = null,
    /// The app was restarted with the change (a recipe's `relaunch`).
    relaunched: bool = false,
};

/// Take `action` through the agent's source: an API call, or the
/// adapter's recipe run against the terminal.
fn act(arena: std.mem.Allocator, e: *Entry, action: agent_mod.Action, deadline: i64) anyerror!Acted {
    switch (e.agent.driver()) {
        .opencode_api => |d| {
            d.perform(action) catch |err| return .{ .fail = try apiFail(arena, d.api, err) };
            return .{ .ok = .{} };
        },
        .screen => |d| {
            var plan = d.plan(state.allocator, action) catch |err| switch (err) {
                error.Unsupported => return .{ .fail = .{ .code = .refused, .msg = try std.fmt.allocPrint(arena, "the {s} adapter has no recipe for {s}", .{ e.loaded.spec.id, @tagName(std.meta.activeTag(action)) }) } },
                else => return err,
            };
            defer plan.deinit();
            return runSteps(arena, e, action, plan.steps, deadline);
        },
    }
}

/// A setting through `act`; the failure, if any (agent_open's notes).
fn applySet(arena: std.mem.Allocator, e: *Entry, action: agent_mod.Action, deadline: i64) !?Fail {
    return switch (try act(arena, e, action, deadline)) {
        .ok => |o| blk: {
            try noteSetting(arena, e, action, o);
            break :blk null;
        },
        .fail => |f| f,
    };
}

fn apiFail(arena: std.mem.Allocator, api: *opencode.Api, err: anyerror) !Fail {
    const code: mcp.ErrCode = switch (err) {
        error.UnknownModel, error.AmbiguousModel, error.UnknownEffort, error.NoCurrentModel, error.NoSuchOption => .invalid_args,
        error.NoPendingInteraction => .conflict,
        error.NoSession => .unavailable,
        error.OutOfMemory => return err,
        else => .failed,
    };
    const why = if (api.problem().len > 0) api.problem() else @errorName(err);
    return .{ .code = code, .msg = try arena.dupe(u8, why) };
}

/// One recipe run's state the failure path needs.
const Run = struct {
    /// The adapter command typed last (`confirm` looks below it).
    command: ?[]const u8 = null,
};

/// Run recipe `steps` (of `action`, or the exit recipe for null) against
/// the agent's terminal. A command recipe that fails is cleaned up: the
/// picker it opened is cancelled, and announced if it will not go.
fn runSteps(arena: std.mem.Allocator, e: *Entry, action: ?agent_mod.Action, steps: []const adapter.Step, deadline: i64) anyerror!Acted {
    var run: Run = .{};
    const result = try runStepsIn(arena, e, action, steps, deadline, &run);
    const eng = &e.agent.source.screen;
    if (run.command != null) {
        if (result == .fail and e.agent.interaction() != null and e.visibleTerm() != null) {
            if (e.loaded.spec.actions.interrupt.len > 0) {
                var cancel = try e.agent.driver().screen.plan(state.allocator, .interrupt);
                defer cancel.deinit();
                _ = try runStepsIn(arena, e, agent_mod.Action.interrupt, cancel.steps, clock.nowMs() + STEP_WAIT_MS, &run);
                pumpFor(INTERRUPT_SETTLE_MS);
            }
        }
        try eng.endCommand(clock.nowMs());
    }
    return result;
}

fn runStepsIn(arena: std.mem.Allocator, e: *Entry, action: ?agent_mod.Action, steps: []const adapter.Step, deadline: i64, run: *Run) anyerror!Acted {
    const d = e.agent.driver().screen;
    const what: []const u8 = if (action) |x| @tagName(std.meta.activeTag(x)) else "exit";
    const gone_fail = Acted{ .fail = .{ .code = .unavailable, .msg = "the agent's terminal is gone" } };
    // The prompt showing now: `wait answered` waits for it to go.
    const asked: ?u64 = if (e.agent.interaction()) |it| it.hash() else null;
    var out: Outcome = .{};
    for (steps) |step| {
        const t = e.visibleTerm() orelse return gone_fail;
        const step_deadline = @min(deadline, clock.nowMs() + STEP_WAIT_MS);
        switch (step) {
            .text => |s| t.sendText(s) catch return gone_fail,
            .command => |s| {
                try d.engine.beginCommand(s);
                run.command = s;
                t.sendText(s) catch return gone_fail;
            },
            .key => |k| t.sendKeys(k) catch |err| return .{ .fail = try keyFail(arena, err, k) },
            .sleep_ms => |ms| pumpFor(ms),
            .clear_input => |ks| {
                service(clock.nowMs());
                if (!d.inputEmpty()) {
                    for (ks) |k| {
                        t.sendKeys(k) catch |err| return .{ .fail = try keyFail(arena, err, k) };
                        pumpFor(50);
                    }
                    pumpFor(CLEAR_SETTLE_MS);
                }
            },
            .wait => |w| if (!waitStep(e, w, asked, step_deadline))
                return .{ .fail = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "the agent did not become {s} while running its {s} recipe; the screen shows:\n{s}", .{ @tagName(w), what, try screenTail(arena, e) }) } },
            .pick => |choice| {
                service(clock.nowMs());
                const num = d.pickNumber(choice) catch |err| return .{ .fail = try pickFail(arena, e, choice, err) };
                var nb: [16]u8 = undefined;
                t.sendText(std.fmt.bufPrint(&nb, "{d}", .{num}) catch unreachable) catch return gone_fail;
            },
            .confirm => |r| {
                const m = try adapter.compileLine(arena, r);
                out.confirmation = (try waitConfirm(arena, e, m, run.command.?, step_deadline)) orelse
                    return .{ .fail = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "the app did not confirm {s}: no confirmation below `{s}` within {d} ms, so the change may not have taken effect; the screen shows:\n{s}", .{ what, run.command.?, STEP_WAIT_MS, try screenTail(arena, e) }) } };
            },
            .relaunch => return relaunch(arena, e, action orelse return gone_fail, deadline),
        }
    }
    return .{ .ok = out };
}

/// Wait until no interaction shows and the app printed a line matching
/// `rule` below `command`, then (still bounded) until the agent is idle
/// again, so the next call is not refused as busy; the line (owned by
/// `arena`), or null when it never showed.
fn waitConfirm(arena: std.mem.Allocator, e: *Entry, rule: adapter.Matcher, command: []const u8, deadline: i64) !?[]const u8 {
    const eng = &e.agent.source.screen;
    service(clock.nowMs());
    var seen: ?[]const u8 = null;
    while (true) {
        if (seen == null and e.agent.interaction() == null) {
            if (eng.confirmLine(rule, command)) |line| seen = try arena.dupe(u8, line);
        }
        if (seen != null and e.agent.state() == .idle) return seen;
        if (gone(e) or clock.nowMs() >= deadline) return seen;
        pump(deadline - clock.nowMs());
    }
}

/// The last lines of the agent's terminal, for a failure that must say
/// what the app shows.
fn screenTail(arena: std.mem.Allocator, e: *Entry) ![]const u8 {
    const t = e.visibleTerm() orelse return "(no terminal)";
    const text = t.readScreen(false) catch return "(the screen could not be read)";
    defer t.allocator.free(text);
    return arena.dupe(u8, mcp.tailLines(std.mem.trimEnd(u8, text, "\n "), 12));
}

/// Restart a screen app with `action`'s value as a launch value (the
/// effort Claude Code only takes at launch: its /effort saves the user's
/// default), in the same session, resuming its conversation.
fn relaunch(arena: std.mem.Allocator, e: *Entry, action: agent_mod.Action, deadline: i64) anyerror!Acted {
    const old = switch (e.visible orelse return .{ .fail = .{ .code = .unavailable, .msg = "the agent's terminal is gone" } }) {
        .owned => |t| t,
        .borrowed => return .{ .fail = .{ .code = .refused, .msg = "this agent runs on a term_open terminal (agent_attach): it cannot be restarted with new launch settings; agent_open it instead" } },
    };
    var model: ?[]const u8 = e.launch_model;
    var effort: ?[]const u8 = e.launch_effort;
    switch (action) {
        .set_effort => |x| effort = x,
        .set_model => |x| model = x,
        .submit, .answer, .interrupt => return .{ .fail = .{ .code = .refused, .msg = "the adapter relaunches for an action that is no launch value" } },
    }
    // A conversation with a turn is resumed; an empty one starts afresh
    // under a new id (the old id may already be taken by the app).
    const resumed = e.conversed and e.conversation != null;
    const conversation: ?[]const u8 = if (resumed) e.conversation else if (e.conversation != null) try newUuid(arena) else null;

    // 1. End the app the way a user would, then make sure it is gone.
    e.relaunching = true;
    defer e.relaunching = false;
    var exit_plan = try e.agent.driver().screen.exitPlan(state.allocator);
    defer exit_plan.deinit();
    _ = try runSteps(arena, e, null, exit_plan.steps, clock.nowMs() + STEP_WAIT_MS);
    const exit_until = clock.nowMs() + EXIT_WAIT_MS;
    while (!old.exited and clock.nowMs() < exit_until) {
        old.drain();
        if (!old.exited) _ = old.pumpOnce(100);
    }
    const ended = old.exited;
    e.visible = null;
    if (ended) old.detach() else old.deinit();

    // 2. Start it again in the same session name, with every launch value.
    const new_t = startAgain(arena, e, model, effort, conversation, if (resumed) .resumed else .fresh, deadline) catch |err| switch (err) {
        error.Refused => return .{ .fail = .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "the app was ended to apply the change and could not be started again; agent_close it and agent_open a new one", .{}) } },
        else => return err,
    };
    e.visible = .{ .owned = new_t };
    e.seen_snapshots = new_t.snapshots;
    e.agent.source.screen.noteRestart();
    e.relaunches += 1;
    const cast_name = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ e.session, e.relaunches });
    record(e, new_t, cast_name);
    if (conversation) |cv| if (!resumed) {
        if (e.conversation) |prev| e.allocator.free(prev);
        e.conversation = try e.allocator.dupe(u8, cv);
    };
    try replaceOwned(e, &e.launch_model, model);
    try replaceOwned(e, &e.launch_effort, effort);
    e.relaunching = false;
    writeDescriptor(e);
    publishAgents();

    // 3. It is back once its input box shows again.
    if (!waitReady(e, deadline))
        return .{ .fail = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "the app was restarted with the new setting but did not become ready in time; the screen shows:\n{s}", .{try screenTail(arena, e)}) } };
    // A model chosen in the app since the launch is not a launch value.
    if (e.picked_model) |m| if (action != .set_model) {
        const again = try arena.dupe(u8, m);
        switch (try act(arena, e, .{ .set_model = again }, deadline)) {
            .ok => {},
            .fail => |f| return .{ .fail = .{ .code = f.code, .msg = try std.fmt.allocPrint(arena, "restarted with the new setting, but the model chosen before ({s}) could not be chosen again: {s}", .{ again, f.msg }) } },
        }
    };
    return .{ .ok = .{ .relaunched = true } };
}

/// What a relaunch of `e` spawns: its binary with every launch value,
/// the caller's `args`/`env` included.
const Restart = struct { argv: []const []const u8, spec: SpawnSpec };

fn restartOf(arena: std.mem.Allocator, e: *const Entry, model: ?[]const u8, effort: ?[]const u8, conversation: ?[]const u8, start: launch.Start) !Restart {
    return .{
        .argv = try launch.startArgv(arena, e.loaded.spec.launch, e.binary, e.extra, .{
            .model = model,
            .effort = effort,
            .cwd = e.cwd,
            .session = conversation,
        }, .{ .main = start }),
        .spec = .{ .name = e.session, .cwd = e.cwd, .extra_env = e.extra.env },
    };
}

/// Spawn the agent's app again on its host as its session, for a relaunch.
fn startAgain(arena: std.mem.Allocator, e: *Entry, model: ?[]const u8, effort: ?[]const u8, conversation: ?[]const u8, start: launch.Start, deadline: i64) !*termdrive.Term {
    const r = try restartOf(arena, e, model, effort, conversation, start);
    var where = e.where();
    var why: Fail = undefined;
    // The ended session may hold its name a moment longer.
    const until = @min(deadline, clock.nowMs() + EXIT_WAIT_MS);
    while (true) {
        if (spawnOn(arena, &where, .auto, r.argv, r.spec, &why)) |t| return t else |err| {
            if (err != error.Refused or clock.nowMs() >= until) return err;
        }
        pumpFor(200);
    }
}

fn replaceOwned(e: *Entry, slot: *?[]u8, value: ?[]const u8) !void {
    const fresh: ?[]u8 = if (value) |v| try e.allocator.dupe(u8, v) else null;
    if (slot.*) |old| e.allocator.free(old);
    slot.* = fresh;
}

/// A setting the app took: what the adapter did goes into the transcript
/// as a notice (the app's own echo of an adapter command is hidden), and
/// a model chosen in the app is kept for a later relaunch.
fn noteSetting(arena: std.mem.Allocator, e: *Entry, action: agent_mod.Action, o: Outcome) !void {
    switch (e.agent.source) {
        .screen => |*eng| {
            const text = switch (action) {
                .set_model => |m| blk: {
                    if (!o.relaunched) try replaceOwned(e, &e.picked_model, m);
                    break :blk try std.fmt.allocPrint(arena, "model set to {s} for this session{s}{s}", .{ m, if (o.confirmation != null) ": " else "", o.confirmation orelse "" });
                },
                .set_effort => |x| try std.fmt.allocPrint(arena, "effort set to {s} for this session{s}", .{ x, if (o.relaunched) " (the app was restarted with it and the conversation resumed)" else "" }),
                .submit, .answer, .interrupt => return,
            };
            try eng.addNotice(text);
            writeDescriptor(e);
        },
        .opencode_api => {},
    }
}

fn keyFail(arena: std.mem.Allocator, err: anyerror, key: []const u8) !Fail {
    if (err == error.BadKey) return .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "the adapter names an unknown key '{s}'", .{key}) };
    return .{ .code = .unavailable, .msg = "the agent's terminal is gone" };
}

fn pickFail(arena: std.mem.Allocator, e: *Entry, choice: []const u8, err: anyerror) !Fail {
    if (err == error.NoPendingInteraction) return .{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} shows no prompt to answer", .{e.id}) };
    return .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "'{s}' names none of the options ({s})", .{ choice, try optionList(arena, e.agent.interaction()) }) };
}

fn optionList(arena: std.mem.Allocator, it: ?output.Interaction) ![]const u8 {
    const x = it orelse return "none";
    var out: std.ArrayList(u8) = .empty;
    for (x.options, 1..) |o, n| {
        if (n > 1) try out.appendSlice(arena, ", ");
        try out.print(arena, "{d}. {s}", .{ n, o.label });
    }
    return out.items;
}

// ── agent_send / agent_wait / agent_answer / agent_set / ... ─────

fn sendTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const text = argStr(args, "text") orelse return errRes(arena, .invalid_args, "agent_send needs 'text'");
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return errRes(arena, .invalid_args, "text is empty");
    const filter = filterFrom(args);
    switch (try submitAndWait(arena, e, text, filter, deadlineFrom(args, DEFAULT_WAIT_MS))) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => |dv| {
            var res = Res.init(arena);
            return finish(arena, &res, e, dv, filter, &.{});
        },
    }
}

fn waitTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const filter = filterFrom(args);
    const dv = try waitAfter(arena, e, null, filter, deadlineFrom(args, DEFAULT_WAIT_MS));
    var res = Res.init(arena);
    return finish(arena, &res, e, dv, filter, &.{});
}

fn answerTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const choice = argStr(args, "choice") orelse return errRes(arena, .invalid_args, "agent_answer needs 'choice': an option label, its 1-based number or a unique part of a label");
    const filter = filterFrom(args);
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    const pre = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena);
    const it = e.agent.interaction() orelse
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} has no pending prompt (state {s})", .{ e.id, @tagName(e.agent.state()) }));
    // Copied now: the interaction is gone once answered.
    const kind = it.kind;
    const title = try arena.dupe(u8, it.title);
    const label: []const u8 = switch (e.agent.kind()) {
        .screen => blk: {
            const i = it.pick(choice) orelse
                return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "'{s}' names none of the options ({s})", .{ choice, try optionList(arena, it) }));
            break :blk try arena.dupe(u8, it.options[i].label);
        },
        .opencode_api => if (kind == .permission)
            (if (opencode.PermissionReply.fromChoice(it, choice)) |r| r.label() else return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "'{s}' names none of the options ({s})", .{ choice, try optionList(arena, it) })))
        else
            try arena.dupe(u8, choice),
    };
    switch (try act(arena, e, .{ .answer = choice }, deadline)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => {},
    }
    // A denied call leaves no trace on a screen app: the adapter keeps one.
    if (kind == .permission) switch (e.agent.source) {
        .screen => |*eng| try eng.addNotice(try std.fmt.allocPrint(arena, "permission \"{s}\" answered: {s}", .{ title, label })),
        .opencode_api => {},
    };
    const dv = try waitAfter(arena, e, pre, filter, deadline);
    var res = Res.init(arena);
    try res.textf("answered the {s} prompt", .{@tagName(kind)});
    try res.fact("answered", label);
    const answer = try std.fmt.allocPrint(arena, "{s}\n-> {s}", .{ title, label });
    return finish(arena, &res, e, dv, filter, &.{.{ .name = "answer", .body = answer }});
}

fn setTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const model = argStr(args, "model");
    const effort = argStr(args, "effort");
    if (model == null and effort == null) return errRes(arena, .invalid_args, "agent_set needs 'model' and/or 'effort'");
    inline for (.{ "model", "effort" }) |key| {
        if (argStr(args, key)) |v| if (!launch.validValue(v)) return errRes(arena, .invalid_args, key ++ " must be 1-256 printable characters");
    }
    // Refused before anything is typed, stopped or restarted.
    if (effort) |x| if (!launch.validEffort(e.loaded.spec.launch, x)) return errRes(arena, .invalid_args, try effortRefusal(arena, e.loaded));
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    // A screen app is typed at: only while it is idle.
    if (e.agent.kind() == .screen) {
        _ = waitReady(e, deadline);
        if (try busy(arena, e)) |f| return errRes(arena, f.code, f.msg);
    }
    var confirmations: std.ArrayList([]const u8) = .empty;
    var relaunched = false;
    for ([_]?agent_mod.Action{
        if (model) |m| agent_mod.Action{ .set_model = m } else null,
        if (effort) |x| agent_mod.Action{ .set_effort = x } else null,
    }) |maybe| {
        const action = maybe orelse continue;
        switch (try act(arena, e, action, deadline)) {
            .fail => |f| return errRes(arena, f.code, f.msg),
            .ok => |o| {
                if (o.confirmation) |line| try confirmations.append(arena, line);
                relaunched = relaunched or o.relaunched;
                try noteSetting(arena, e, action, o);
            },
        }
    }
    service(clock.nowMs());
    var res = Res.init(arena);
    try res.textf("{s}: {s} set for this session only{s}", .{
        e.id,
        if (model != null and effort != null) "model and effort" else if (model != null) "model" else "effort",
        if (relaunched) " (restarted with it; the conversation was resumed)" else "",
    });
    if (model) |m| try res.fact("model", m);
    if (effort) |x| try res.fact("effort", x);
    if (confirmations.items.len > 0) try res.fact("confirmation", try std.mem.join(arena, "\n", confirmations.items));
    try res.fact("relaunched", relaunched);
    switch (e.agent.source) {
        .opencode_api => |*api| {
            if (api.currentModel()) |m| try res.fact("current_model", try std.fmt.allocPrint(arena, "{s}/{s}", .{ m.provider, m.model }));
            if (api.currentEffort()) |x| try res.fact("current_effort", x);
        },
        .screen => {},
    }
    const blocks = [1]Block{.{ .name = "confirmation", .body = try std.mem.join(arena, "\n", confirmations.items) }};
    return finish(arena, &res, e, try pending(arena, e), .{}, blocks[0..@intFromBool(confirmations.items.len > 0)]);
}

fn interruptTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    switch (try act(arena, e, .interrupt, deadlineFrom(args, DEFAULT_WAIT_MS))) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => {},
    }
    pumpFor(INTERRUPT_SETTLE_MS);
    var res = Res.init(arena);
    try res.textf("{s}: interrupted", .{e.id});
    try res.fact("interrupted", true);
    return finish(arena, &res, e, try pending(arena, e), .{}, &.{});
}

const RecordJson = struct {
    id: u64,
    kind: []const u8,
    text: []const u8,
    job: u32,
    synthetic: bool,
    tool: ?struct { name: []const u8, input: []const u8, status: []const u8, output: []const u8 } = null,
};

/// Write a selection's facts (`records`, `jobs`, `cut_ids`).
/// @return its text block: per job a marker line, then its records.
fn writeSelection(arena: std.mem.Allocator, res: *Res, recs: []const output.Record, sel: select.Selection) ![]const u8 {
    const out = try arena.alloc(RecordJson, sel.picked.len);
    for (sel.picked, out) |i, *j| {
        const r = recs[i];
        j.* = .{
            .id = r.id,
            .kind = @tagName(r.kind),
            .text = r.text,
            .job = r.job,
            .synthetic = r.synthetic,
            .tool = if (r.tool) |tc| .{ .name = tc.name, .input = tc.input, .status = @tagName(tc.status), .output = tc.output } else null,
        };
    }
    try res.raw("records", try toJson(arena, out));
    try res.raw("jobs", try toJson(arena, sel.jobs));
    try res.fact("cut_ids", sel.cut);

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (sel.jobs, 0..) |s, n| {
        if (n > 0) try w.writeAll("\n");
        try w.print("== job {d}", .{s.job});
        if (s.omitted_messages > 0 or s.omitted_tools > 0) {
            try w.writeAll(" (");
            if (s.omitted_messages > 0) try w.print("{d} more message{s}", .{ s.omitted_messages, if (s.omitted_messages == 1) "" else "s" });
            if (s.omitted_messages > 0 and s.omitted_tools > 0) try w.writeAll(", ");
            if (s.omitted_tools > 0) try w.print("{d} tool call{s}", .{ s.omitted_tools, if (s.omitted_tools == 1) "" else "s" });
            try w.writeAll(")");
        }
        try w.writeAll(" ==");
        for (sel.picked) |i| {
            const r = recs[i];
            if (r.job == s.job) try w.print("\n[{d}] {s}: {s}", .{ r.id, @tagName(r.kind), r.text });
        }
    }
    if (sel.cut.len > 0) {
        try w.print("\n{d} selected record(s) left out by the {d}-character cap, ids", .{ sel.cut.len, select.READ_CAP_CHARS });
        for (sel.cut) |id| try w.print(" {d}", .{id});
        try w.writeAll(": agent_read with detail all and a since below an id returns it");
    }
    return aw.written();
}

fn readTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const detail = if (argStr(args, "detail")) |d|
        std.meta.stringToEnum(select.Detail, d) orelse return errRes(arena, .invalid_args, "detail must be selected or all")
    else
        select.Detail.selected;
    const explicit = argInt(args, "since");
    const base: u64 = if (explicit) |s| @intCast(@max(s, 0)) else e.read_cursor;
    const limit: usize = @intCast(std.math.clamp(argInt(args, "limit") orelse READ_DEFAULT, 1, READ_MAX));
    const recs = e.agent.records();
    const jobs = try select.jobsAfter(arena, recs, base);
    const sel = try select.select(arena, recs, jobs, .{ .detail = detail, .include_tools = argBool(args, "include_tools"), .limit = limit, .since = base });
    var high = base;
    for (recs) |r| high = @max(high, r.id);
    // A paged `all` read goes on after its last record; any other covers everything.
    const next: u64 = if (sel.more) recs[sel.picked[sel.picked.len - 1]].id else high;
    e.read_cursor = @max(e.read_cursor, next);

    var res = Res.init(arena);
    const body = try writeSelection(arena, &res, recs, sel);
    if (jobs.list.len == 0)
        try res.text("no records yet")
    else
        try res.textf("{d} record(s) of job(s) {d}-{d}{s}; next_since {d}{s}", .{
            sel.picked.len,
            jobs.list[0],
            jobs.list[jobs.list.len - 1],
            if (jobs.fallback) " (nothing new: the latest job again)" else "",
            next,
            if (sel.more) " (more follow)" else "",
        });
    try res.fact("detail", @tagName(detail));
    try res.fact("next_since", next);
    try res.fact("more", sel.more);
    const blocks = [1]Block{.{ .name = "records", .body = body }};
    return finish(arena, &res, e, try pending(arena, e), .{}, blocks[0..@intFromBool(jobs.list.len > 0)]);
}

fn listTool(arena: std.mem.Allocator) ![]const u8 {
    service(clock.nowMs());
    const Item = struct {
        agent: []const u8,
        app: []const u8,
        source: []const u8,
        state: []const u8,
        ready: bool,
        session: []const u8,
        server_session: ?[]const u8,
        pending_events: usize,
        waiting_on_user: bool,
        host: ?[]const u8,
        transport: []const u8,
        recordings: []const []const u8,
    };
    const items = try arena.alloc(Item, state.entries.items.len);
    var res = Res.init(arena);
    try res.textf("{d} agent(s)", .{items.len});
    for (state.entries.items, items) |e, *out| {
        out.* = .{
            .agent = e.id,
            .app = e.loaded.spec.id,
            .source = @tagName(e.agent.kind()),
            .state = @tagName(e.agent.state()),
            .ready = e.agent.ready(),
            .session = e.session,
            .server_session = e.server_session,
            .pending_events = e.cursor.pendingAlwaysOn(e.agent.queue()),
            .waiting_on_user = e.agent.interaction() != null,
            .host = e.host,
            .transport = @tagName(e.transport),
            .recordings = e.recordings.items,
        };
        try res.textf("{s} ({s}): {s}, session {s}{s}{s}, {d} undelivered event(s)", .{ out.agent, out.app, out.state, out.session, if (e.host != null) " on " else "", e.host orelse "", out.pending_events });
        for (e.recordings.items) |r| try res.textf("  recording: {s}", .{r});
    }
    try res.raw("agents", try toJson(arena, items));
    try res.fact("count", items.len);
    return res.finish();
}

fn closeTool(arena: std.mem.Allocator, _: std.json.Value, e: *Entry) ![]const u8 {
    const id = try arena.dupe(u8, e.id);
    var sessions: std.ArrayList([]const u8) = .empty;
    if (e.visible) |l| if (l == .owned) try sessions.append(arena, try arena.dupe(u8, e.session));
    if (e.server_session) |s| try sessions.append(arena, try arena.dupe(u8, s));
    endWaitersOf(e.id, "agent closed");
    removeDescriptor(e);
    for (state.entries.items, 0..) |x, i| if (x == e) {
        _ = state.entries.orderedRemove(i);
        break;
    };
    publishAgents();
    e.destroy(true);
    var res = Res.init(arena);
    try res.textf("closed {s}{s}", .{ id, if (sessions.items.len == 0) " (its terminal belongs to term_open and stays)" else "" });
    try res.fact("agent", id);
    try res.fact("closed", true);
    try res.fact("sessions", sessions.items);
    return res.finish();
}

// ── durable instances: descriptors and reattach ──────────────────

/// What a durable instance needs to pick a running agent up again.
const Descriptor = struct {
    id: []const u8,
    app: []const u8,
    session: []const u8,
    origin: []const u8,
    server_session: ?[]const u8 = null,
    server_origin: ?[]const u8 = null,
    port: u16 = 0,
    password_file: ?[]const u8 = null,
    api_session: ?[]const u8 = null,
    binary: []const u8 = "",
    cwd: []const u8 = "",
    /// Remote agents: the host, and how the sessions reach it (a
    /// `Transport` name; absent = local, as P3 descriptors were written).
    host: ?[]const u8 = null,
    transport: ?[]const u8 = null,
    remote_port: u16 = 0,
    forward_session: ?[]const u8 = null,
    forward_origin: ?[]const u8 = null,
    conversation: ?[]const u8 = null,
    conversed: bool = false,
    launch_model: ?[]const u8 = null,
    launch_effort: ?[]const u8 = null,
    picked_model: ?[]const u8 = null,
    relaunches: u32 = 0,
    cols: u16 = DEFAULT_COLS,
    rows: u16 = DEFAULT_ROWS,
    /// agent_open's `args`/`env` (absent in older descriptors: none).
    args: []const []const u8 = &.{},
    env: []const launch.EnvVar = &.{},
};

fn descriptorPath(arena: std.mem.Allocator, id: []const u8, ext: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/" ++ DESCRIPTOR_DIR ++ "/{s}.{s}", .{ state.dir.?, id, ext });
}

fn writeDescriptor(e: *Entry) void {
    if (!state.durable or state.dir == null) return;
    const vis = if (e.visible) |l| switch (l) {
        .owned => |t| t,
        .borrowed => return,
    } else e.server orelse return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pw_path: ?[]const u8 = if (e.password) |p| blk: {
        const path = descriptorPath(arena, e.id, "pw") catch return;
        pathz.makeParentDirs(path) catch return;
        atomicwrite.writeFileExact(path, p, 0o600) catch return;
        break :blk path;
    } else null;
    const d = Descriptor{
        .id = e.id,
        .app = e.loaded.spec.id,
        .session = vis.name,
        .origin = &vis.origin_id,
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
        .forward_session = if (e.forward) |f| f.name else null,
        .forward_origin = if (e.forward) |f| @as([]const u8, &f.origin_id) else null,
        .conversation = e.conversation,
        .conversed = e.conversed,
        .launch_model = e.launch_model,
        .launch_effort = e.launch_effort,
        .picked_model = e.picked_model,
        .relaunches = e.relaunches,
        .cols = e.cols,
        .rows = e.rows,
        .args = e.extra.args,
        .env = e.extra.env,
    };
    const path = descriptorPath(arena, e.id, "json") catch return;
    pathz.makeParentDirs(path) catch return;
    atomicwrite.writeJsonExact(arena, path, d, 0o600) catch {};
}

fn removeDescriptor(e: *Entry) void {
    if (state.dir == null) return;
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    if (descriptorPath(a, e.id, "json")) |p| pathz.unlinkPath(p) else |_| {}
    fba.reset();
    if (descriptorPath(a, e.id, "pw")) |p| pathz.unlinkPath(p) else |_| {}
}

/// A durable instance's startup: pick up every agent whose descriptor is
/// in the instance dir and whose session still runs. A descriptor whose
/// session is gone is removed.
pub fn reattach() void {
    if (!state.durable) return;
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
        reattachOne(parsed.value) catch |err| {
            if (err == error.SessionGone) {
                pathz.unlinkPath(path);
                if (parsed.value.password_file) |p| pathz.unlinkPath(p);
            }
        };
    }
    publishAgents();
}

/// Publish into the MCP registry record (`mcp_registry.Lease`) so a viewer
/// on any host can find the agents: set by `mcp.zig` before `reattach`.
pub fn publishTo(lease: ?*mcp_registry.Lease) void {
    state.registry = lease;
}

/// Rewrite the registry record's agent list from `state.entries`: called
/// after every open, attach, close, relaunch and the startup reattach.
/// Best effort: a failed rewrite leaves the previous list, never the server.
fn publishAgents() void {
    const lease = state.registry orelse return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(mcp_registry.Agent) = .empty;
    for (state.entries.items) |e| {
        var sessions: std.ArrayList([]const u8) = .empty;
        sessions.append(arena, e.session) catch return;
        if (e.server_session) |s| sessions.append(arena, s) catch return;
        // The term's own fact: it runs on a host's daemon or on ours.
        const where: sshroute.Location = if (e.visibleTerm() orelse e.server) |t|
            (if (t.remote_host) |h| .{ .host = h } else .instance)
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
        if (self.forward) |x| x.detach();
        if (self.server) |x| x.detach();
        if (self.vis) |x| x.detach();
        self.* = .{};
    }
};

/// Attach session `name` where a descriptor says it runs: the remote
/// host's own daemon (reconnected over ssh), else this server's daemon
/// (local agents, and the local ssh sessions of plain-ssh ones).
fn attachWhere(transport: Transport, host: ?[]const u8, name: []const u8, origin: ?[]const u8) !*termdrive.Term {
    const a = state.allocator;
    const id = try originOf(origin);
    if (transport == .@"sketerm-mux") {
        return termdrive.Term.attachRemote(a, host orelse return error.BadDescriptor, name, id) catch error.SessionGone;
    }
    const sock = state.mux_sock orelse return error.NoDaemon;
    return termdrive.Term.attachExisting(a, name, id, sock) catch error.SessionGone;
}

fn reattachOne(d: Descriptor) !void {
    const a = state.allocator;
    const loaded = (try adapters()).get(d.app) orelse return error.UnknownAdapter;
    const transport: Transport = if (d.transport) |s| std.meta.stringToEnum(Transport, s) orelse return error.BadDescriptor else .local;
    if (transport != .local and d.host == null) return error.BadDescriptor;
    const extra = launch.Extra{ .args = d.args, .env = d.env };
    {
        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        if ((try launch.checkExtra(arena_state.allocator(), loaded.spec.launch, extra)) != null) return error.BadDescriptor;
    }
    var parts: Parts = .{};
    errdefer parts.release(a);
    parts.vis = try attachWhere(transport, d.host, d.session, d.origin);
    if (loaded.spec.source == .opencode_api) {
        parts.server = try attachWhere(transport, d.host, d.server_session orelse return error.BadDescriptor, d.server_origin);
        parts.pw = readfile.cappedAlloc(a, d.password_file orelse return error.BadDescriptor, 4096) catch return error.BadDescriptor;
        // The forward is this server's own ssh; a dead one is respawned
        // by `service` on the same local port.
        if (d.forward_session) |fs| parts.forward = attachWhere(.local, null, fs, d.forward_origin) catch null;
    }
    parts.ag = try a.create(agent_mod.Agent);
    parts.ag.?.* = switch (loaded.spec.source) {
        .screen => try agent_mod.Agent.initScreen(a, loaded, .{}),
        .opencode_api => try agent_mod.Agent.initOpencode(a, loaded, .{}, .{ .port = d.port, .password = parts.pw.? }),
    };
    parts.ag_live = true;

    try state.entries.ensureUnusedCapacity(a, 1);
    const e = try newEntry(loaded, d.id, d.session, d.binary, d.cwd);
    errdefer dropBare(e);
    if (d.server_session) |s| e.server_session = try a.dupe(u8, s);
    if (d.host) |h| e.host = try a.dupe(u8, h);
    if (d.conversation) |s| e.conversation = try a.dupe(u8, s);
    if (d.launch_model) |s| e.launch_model = try a.dupe(u8, s);
    if (d.launch_effort) |s| e.launch_effort = try a.dupe(u8, s);
    if (d.picked_model) |s| e.picked_model = try a.dupe(u8, s);
    e.extra = try extra.clone(a);
    e.transport = transport;
    e.conversed = d.conversed;
    e.relaunches = d.relaunches;
    e.cols = d.cols;
    e.rows = d.rows;
    e.remote_port = d.remote_port;
    // Nothing below fails: the parts move into the entry.
    e.agent = parts.ag.?;
    e.visible = .{ .owned = parts.vis.? };
    e.seen_snapshots = parts.vis.?.snapshots;
    e.server = parts.server;
    e.forward = parts.forward;
    e.port = d.port;
    e.password = parts.pw;
    parts = .{};
    state.entries.appendAssumeCapacity(e);
    // An adopted session's past is history: it arms no turn. A server
    // whose forward is down answers once `service` brings it back.
    if (loaded.spec.source == .opencode_api) {
        const api = &e.agent.source.opencode_api;
        if (e.forward == null and e.host != null) {
            e.forward_retry_ms = 0;
            e.forward = null;
            reviveForwardNow(e);
        }
        api.connect(d.api_session, clock.nowMs()) catch {
            // Reconnects with backoff from `service`, then resyncs the
            // session it drives.
            if (d.api_session) |sid| api.source.setRoot(sid) catch {};
            api.source.noteDisconnected(clock.nowMs(), "the app's server is not reachable yet") catch {};
            api.reconnect_at_ms = clock.nowMs() + 500;
        };
    }
    // New agents must not reuse this one's number.
    if (std.mem.lastIndexOfScalar(u8, d.id, '-')) |dash| {
        if (std.fmt.parseInt(u32, d.id[dash + 1 ..], 10)) |n| {
            const gop = state.counters.getOrPut(a, loaded.spec.id) catch return;
            if (!gop.found_existing or gop.value_ptr.* < n) gop.value_ptr.* = n;
        } else |_| {}
    }
}

/// Start a remote API agent's forward when it has none (a durable
/// instance whose forward session is gone).
fn reviveForwardNow(e: *Entry) void {
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const host = e.host orelse return;
    const name = forwardName(arena_state.allocator(), e.id) catch return;
    e.forward = mcp_term.spawnForwardTermNamed(arena_state.allocator(), host, e.port, "127.0.0.1", e.remote_port, name) catch null;
    if (e.forward) |f| _ = mcp_term.waitForwardReady(arena_state.allocator(), f, e.port, 10_000) catch {};
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;
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

const live = "[Haiku 4.5] repo:master\r\n[\xe2\x96\xa0\xe2\x96\xa1] 21%\r\nmanual mode on\r\n$";
const erase = "\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[G";
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

test "the outcome of a wake-up is its highest-ranked kind" {
    var q = events.Queue.init(testing.allocator, .{});
    defer q.deinit();
    _ = try q.push(0, .message, null, "part", "");
    _ = try q.push(0, .done, null, "final", "");
    _ = try q.push(0, .needs_input, null, "permission: rm?", "");
    var cur: events.Cursor = .{};
    const d = (try cur.take(&q, .{ .messages = true }, 0, testing.allocator)).?;
    defer testing.allocator.free(d.items);
    try testing.expectEqualStrings("needs_input", outcomeOf(d.items, .waiting_user));
    try testing.expectEqualStrings("done", outcomeOf(d.items[0..2], .idle));
    try testing.expectEqualStrings("message", outcomeOf(d.items[0..1], .working));
    try testing.expectEqualStrings(mcp_tools.OUTCOME_STILL_WORKING, outcomeOf(&.{}, .working));
    try testing.expectEqualStrings("exited", outcomeOf(&.{}, .exited));
}

/// A configured instance in a temp dir, torn down by `deinit`.
const ToolRig = struct {
    dir: pathz.TempDir,
    sock_buf: [128]u8 = undefined,
    arena: std.heap.ArenaAllocator,

    fn init(self: *ToolRig) !void {
        self.dir = pathz.TempDir.make("mcp-agent") orelse return error.SkipZigTest;
        const sock = try std.fmt.bufPrint(&self.sock_buf, "{s}/mux.sock", .{self.dir.path()});
        configure(testing.allocator, self.dir.path(), sock, false);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *ToolRig) void {
        shutdown();
        self.arena.deinit();
        self.dir.remove();
    }

    fn call(self: *ToolRig, tool: Tool, json: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        const args = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        return agentTool(a, tool, args);
    }
};

fn expectError(arena: std.mem.Allocator, tool: []const u8, result: []const u8, code: []const u8) !void {
    const parsed = try mcp.expectToolResultShape(arena, tool, result);
    const err = parsed.object.get("structuredContent").?.object.get("error") orelse return error.ExpectedError;
    try testing.expectEqualStrings(code, err.object.get("code").?.string);
}

test "argument validation refuses before anything is spawned" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    try expectError(a, "agent_open", try rig.call(.agent_open, "{}"), "invalid_args");
    try expectError(a, "agent_open", try rig.call(.agent_open, "{\"app\":\"nope\"}"), "not_found");
    // An option-looking host never reaches an ssh argv; a transport is one
    // of the three; an effort the app does not take is refused up front.
    try expectError(a, "agent_open", try rig.call(.agent_open, "{\"app\":\"claude\",\"host\":\"-oProxyCommand=sh\"}"), "invalid_args");
    try expectError(a, "agent_open", try rig.call(.agent_open, "{\"app\":\"claude\",\"host\":\"box\",\"transport\":\"pigeon\"}"), "invalid_args");
    try expectError(a, "agent_open", try rig.call(.agent_open, "{\"app\":\"claude\",\"effort\":\"extreme\"}"), "invalid_args");
    try expectError(a, "agent_open", try rig.call(.agent_open, "{\"app\":\"claude\",\"binary\":\"claude; rm -rf /\"}"), "invalid_args");
    try expectError(a, "agent_open", try rig.call(.agent_open, "{\"app\":\"claude\",\"binary\":\"/nonexistent/claude\"}"), "unavailable");
    try expectError(a, "agent_open", try rig.call(.agent_open, "{\"app\":\"claude\",\"cwd\":\"relative\"}"), "invalid_args");
    try expectError(a, "agent_open", try rig.call(.agent_open, "{\"app\":\"claude\",\"model\":\"a\\nb\"}"), "invalid_args");
    // A wrapper's args and env: refused whole, never cleaned up (the rules
    // themselves are launch.checkExtra's, tested there).
    for ([_][]const u8{
        "{\"app\":\"claude\",\"args\":\"--profile work\"}",
        "{\"app\":\"claude\",\"args\":[\"ok\",3]}",
        "{\"app\":\"claude\",\"args\":[\"line\\nbreak\"]}",
        "{\"app\":\"claude\",\"args\":[\"\"]}",
        "{\"app\":\"claude\",\"env\":[\"A=1\"]}",
        "{\"app\":\"claude\",\"env\":{\"A\":1}}",
        "{\"app\":\"claude\",\"env\":{\"1A\":\"x\"}}",
        "{\"app\":\"claude\",\"env\":{\"A\":\"x\\u0000y\"}}",
        "{\"app\":\"opencode\",\"env\":{\"OPENCODE_SERVER_PASSWORD\":\"mine\"}}",
    }) |json| {
        const r = try rig.call(.agent_open, json);
        expectError(a, "agent_open", r, "invalid_args") catch |err| {
            std.debug.print("not refused as invalid_args: {s}\n", .{json});
            return err;
        };
    }
    try expectError(a, "agent_attach", try rig.call(.agent_attach, "{\"term\":99,\"app\":\"claude\"}"), "not_found");
    try expectError(a, "agent_attach", try rig.call(.agent_attach, "{\"term\":1,\"app\":\"opencode\"}"), "invalid_args");
    try expectError(a, "agent_adapters", try rig.call(.agent_adapters, "{\"host\":\"a host\"}"), "invalid_args");
    inline for (.{ Tool.agent_send, Tool.agent_wait, Tool.agent_read, Tool.agent_answer, Tool.agent_set, Tool.agent_interrupt, Tool.agent_close }) |tool| {
        try expectError(a, @tagName(tool), try rig.call(tool, "{\"agent\":\"claude-9\"}"), "not_found");
    }
}

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
    try testing.expectEqual(@as(usize, 1), r.spec.extra_env.len);
    try testing.expectEqualStrings("w o'rk $x", r.spec.extra_env[0].value);
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

test "agent_adapters and agent_list speak both lanes" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    const ad = try mcp.expectToolResultShape(a, "agent_adapters", try rig.call(.agent_adapters, "{}"));
    const sc = ad.object.get("structuredContent").?.object;
    try testing.expect(sc.get("count").?.integer >= 2);
    var saw_opencode = false;
    for (sc.get("adapters").?.array.items) |item| {
        if (!std.mem.eql(u8, item.object.get("id").?.string, "opencode")) continue;
        saw_opencode = true;
        try testing.expectEqualStrings("opencode_api", item.object.get("source").?.string);
        try testing.expectEqual(@as(usize, std.enums.values(agent_mod.ActionKind).len), item.object.get("actions").?.array.items.len);
    }
    try testing.expect(saw_opencode);
    const ls = try mcp.expectToolResultShape(a, "agent_list", try rig.call(.agent_list, "{}"));
    try testing.expectEqual(@as(i64, 0), ls.object.get("structuredContent").?.object.get("count").?.integer);
    // The waiter template names the socket this instance serves.
    const tmpl = (try waiterTemplate(a)).?;
    try testing.expect(std.mem.indexOf(u8, tmpl, WAITER_SOCKET) != null);
    try testing.expect(std.mem.endsWith(u8, tmpl, " AGENT"));
}

test "shared mode answers unavailable for every agent tool" {
    const saved = state;
    state = .{};
    defer state = saved;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (std.enums.values(Tool)) |tool| {
        const r = try agentTool(a, tool, .null);
        try expectError(a, @tagName(tool), r, "unavailable");
    }
}

test "every per-agent result shape is declared: a live agent on a scripted screen" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    // An entry whose terminal is a borrowed id nobody holds: the adapter
    // reads nothing, and every read-side tool still answers in shape.
    const set = try adapters();
    const e = try newEntry(set.get("claude").?, "claude-1", "agent-claude-1", "/bin/claude", "/");
    const ag = try state.allocator.create(agent_mod.Agent);
    ag.* = try agent_mod.Agent.initScreen(state.allocator, set.get("claude").?, .{});
    e.agent = ag;
    e.visible = .{ .borrowed = 4242 };
    try state.entries.append(state.allocator, e);
    const eng = &ag.source.screen;
    _ = try eng.queue.push(clock.nowMs(), .needs_input, null, "permission: Bash", "1. Yes\n2. No");

    // Listing services the agent first: its terminal id names nothing, so
    // the connection is reported lost; neither event is taken by the list.
    const listed = try mcp.expectToolResultShape(a, "agent_list", try rig.call(.agent_list, "{}"));
    try testing.expectEqual(@as(i64, 2), listed.object.get("structuredContent").?.object.get("agents").?.array.items[0].object.get("pending_events").?.integer);

    const read = try mcp.expectToolResultShape(a, "agent_read", try rig.call(.agent_read, "{\"agent\":\"claude-1\"}"));
    const rsc = read.object.get("structuredContent").?.object;
    // The pending event rode along; the terminal is gone, so the state says so.
    try testing.expectEqual(@as(usize, 2), rsc.get("events").?.array.items.len);
    try testing.expectEqualStrings("disconnected", rsc.get("state").?.string);
    try testing.expect(std.mem.indexOf(u8, rsc.get("watch_command").?.string, "agent-wait") != null);

    const waited = try mcp.expectToolResultShape(a, "agent_wait", try rig.call(.agent_wait, "{\"timeout_ms\":0}"));
    try testing.expect(waited.object.get("structuredContent").?.object.get("timed_out").?.bool);
    try testing.expectEqualStrings("still_working", waited.object.get("structuredContent").?.object.get("outcome").?.string);

    try expectError(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"hi\"}"), "unavailable");
    try expectError(a, "agent_answer", try rig.call(.agent_answer, "{\"choice\":\"Yes\"}"), "conflict");
    try expectError(a, "agent_set", try rig.call(.agent_set, "{}"), "invalid_args");

    const closed = try mcp.expectToolResultShape(a, "agent_close", try rig.call(.agent_close, "{}"));
    try testing.expect(closed.object.get("structuredContent").?.object.get("closed").?.bool);
    try testing.expectEqual(@as(usize, 0), state.entries.items.len);
}

test "the waiter socket: subscribe, wake once, and end when the agent closes" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const set = try adapters();
    const e = try newEntry(set.get("claude").?, "claude-1", "agent-claude-1", "/bin/claude", "/");
    const ag = try state.allocator.create(agent_mod.Agent);
    ag.* = try agent_mod.Agent.initScreen(state.allocator, set.get("claude").?, .{});
    e.agent = ag;
    e.visible = .{ .borrowed = 4242 };
    try state.entries.append(state.allocator, e);

    const connectSub = struct {
        fn f(line: []const u8) !c_int {
            const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
            var addr: c.struct_sockaddr_un = undefined;
            try @import("../mux/sockpath.zig").fillSockaddrUn(&addr, state.waiter.path.?);
            if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.ConnectFailed;
            _ = c.write(fd, line.ptr, line.len);
            return fd;
        }
    }.f;
    const readLine = struct {
        fn f(fd: c_int, buf: []u8) ![]const u8 {
            return readLineFor(fd, buf, 3000);
        }
    }.f;

    // Unknown agent: an end line at once.
    const bad = try connectSub("{\"agent\":\"nope-1\"}\n");
    defer _ = c.close(bad);
    var buf: [4096]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try readLine(bad, &buf), "\"type\":\"end\"") != null);

    // The terminal id names nothing, so the first service reports the
    // connection lost; the assistant takes that, and a subscriber without
    // `since` starts after what the assistant was handed.
    service(clock.nowMs());
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect((try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena_state.allocator())) != null);

    // A one-shot subscriber wakes on done, then is let go.
    const one = try connectSub("{\"agent\":\"claude-1\"}\n");
    defer _ = c.close(one);
    service(clock.nowMs());
    _ = try ag.source.screen.queue.push(clock.nowMs(), .done, null, "all done", "");
    const woke = try readLine(one, &buf);
    try testing.expect(std.mem.indexOf(u8, woke, "\"kind\":\"done\"") != null);
    try testing.expect(std.mem.indexOf(u8, woke, "connection_lost") == null);
    try testing.expect(std.mem.indexOf(u8, woke, "all done") != null);

    // A follower from seq 0 sees everything, then the end on close.
    const follow = try connectSub("{\"agent\":\"agent-claude-1\",\"follow\":true,\"since\":0}\n");
    defer _ = c.close(follow);
    const all = try readLine(follow, &buf);
    try testing.expect(std.mem.indexOf(u8, all, "connection_lost") != null);
    try testing.expect(std.mem.indexOf(u8, all, "all done") != null);
    // The assistant's own cursor is untouched by the waiters.
    try testing.expectEqual(@as(usize, 1), e.cursor.pendingAlwaysOn(e.agent.queue()));

    // The same watch command, run again after a later call handed the
    // assistant that done, waits for what is new: it never re-wakes on an
    // event the assistant already has (a baked-in cursor went stale).
    try testing.expect((try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena_state.allocator())) != null);
    const tmpl = (try waiterTemplate(arena_state.allocator())).?;
    try testing.expect(std.mem.indexOf(u8, tmpl, "--since") == null);
    const again = try connectSub("{\"agent\":\"claude-1\"}\n");
    defer _ = c.close(again);
    try testing.expectError(error.Timeout, readLineFor(again, &buf, 400));
    _ = try ag.source.screen.queue.push(clock.nowMs(), .done, null, "second turn", "");
    const fresh = try readLine(again, &buf);
    try testing.expect(std.mem.indexOf(u8, fresh, "second turn") != null);
    try testing.expect(std.mem.indexOf(u8, fresh, "all done") == null);

    _ = try closeTool(arena_state.allocator(), .null, e);
    try testing.expect(std.mem.indexOf(u8, try readLine(follow, &buf), "agent closed") != null);
}

/// Read one waiter line within `ms`, servicing the server meanwhile.
fn readLineFor(fd: c_int, buf: []u8, ms: i64) ![]const u8 {
    var used: usize = 0;
    const deadline = clock.nowMs() + ms;
    while (clock.nowMs() < deadline) {
        service(clock.nowMs());
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 20) <= 0) continue;
        const n = c.read(fd, buf[used..].ptr, buf.len - used);
        if (n <= 0) return buf[0..used];
        used += @intCast(n);
        if (std.mem.indexOfScalar(u8, buf[0..used], '\n') != null) return buf[0..used];
    }
    return error.Timeout;
}

const fake_daemon = @import("launch_cleanup_test.zig");

const APP_BUSY = "\x1b]0;\xe2\x97\x90 Working\x07";
const APP_IDLE = "\x1b]0;\xe2\x9c\xb3 Claude Code\x07";
const APP_END = "\x1b]133;C\x07\x1b]133;D\x07\x07" ++ APP_IDLE ++ erase ++ "Brewed for 1s \xc2\xb7 done\r\n" ++ live;
const APP_PERMISSION = erase ++ "tool: Bash (rm notes.md)\r\nPermission Required: Bash command\r\n> rm notes.md\r\n" ++
    "Do you want to proceed?\r\n1. Yes\r\n2. No\r\nSelect with numbers [1-2]. Then Enter to submit or Escape to cancel:\x07";

/// A Claude-Code-shaped app behind a fake daemon: a real Term over a
/// socketpair whose peer turns the input the adapter types into the
/// screen events the app would draw, so every agent tool runs its real
/// path (plans, waits, records) without a daemon or an app.
const FakeApp = struct {
    daemon: fake_daemon.Harness,
    parser: Parser,
    writer: wire.Writer,
    count: u32 = 0,
    /// The mirror's seq after the attach snapshot.
    seq: u64 = 7,
    typed: std.ArrayList(u8) = .empty,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn init(self: *FakeApp) !*termdrive.Term {
        self.* = .{
            .daemon = try fake_daemon.Harness.init(testing.allocator),
            .parser = Parser.init(testing.allocator),
            .writer = wire.Writer.init(testing.allocator),
        };
        const payload = try fake_daemon.snapshotPayloadSized(testing.allocator, false, 80, 24);
        defer testing.allocator.free(payload);
        try self.daemon.queueSnapshot(payload);
        var conn = self.daemon.takePrimary(testing.allocator);
        var origin: wire.SessionOriginId = undefined;
        @memcpy(&origin, fake_daemon.ORIGIN_ID);
        return termdrive.Term.attachConn(testing.allocator, &conn, "fake-claude", origin);
    }

    fn start(self: *FakeApp) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *FakeApp) void {
        self.stop.store(true, .release);
        if (self.thread) |th| th.join();
        self.typed.deinit(testing.allocator);
        self.writer.deinit();
        self.parser.deinit();
        self.daemon.deinit();
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *FakeApp = @ptrCast(@alignCast(user.?));
        var e = ev;
        defer e.deinit(testing.allocator);
        self.writer.putEvent(ev) catch return self.failed.store(true, .release);
        self.count += 1;
    }

    /// Draw `bytes` on the app's screen: one events frame.
    fn draw(self: *FakeApp, bytes: []const u8) !void {
        self.writer.buf.clearRetainingCapacity();
        self.count = 0;
        self.parser.advance(bytes, emit, @ptrCast(self));
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(testing.allocator);
        var head: [12]u8 = undefined;
        std.mem.writeInt(u64, head[0..8], self.seq, .little);
        std.mem.writeInt(u32, head[8..12], self.count, .little);
        try payload.appendSlice(testing.allocator, &head);
        try payload.appendSlice(testing.allocator, self.writer.buf.items);
        try self.daemon.queueEvents(payload.items);
        self.seq += self.count;
    }

    fn run(self: *FakeApp) void {
        var picker = false;
        var choice: u8 = 0;
        while (!self.stop.load(.acquire)) {
            const f = self.daemon.primary_peer.recvExpectFor(&.{.input}, 50) catch continue;
            defer f.deinit(testing.allocator);
            for (f.payload) |b| {
                if (picker) {
                    switch (b) {
                        '1'...'9' => choice = b - '0',
                        // Session only: applied a moment later, as Claude Code does.
                        's' => {
                            picker = false;
                            _ = c.usleep(400_000);
                            self.draw(if (choice == 1) MODEL_SET_SONNET else MODEL_SET_HAIKU) catch self.failed.store(true, .release);
                        },
                        else => {},
                    }
                    continue;
                }
                switch (b) {
                    '\r' => {
                        picker = std.mem.eql(u8, self.typed.items, "/model");
                        self.respond(self.typed.items) catch self.failed.store(true, .release);
                        self.typed.clearRetainingCapacity();
                    },
                    0x1b => self.typed.clearRetainingCapacity(),
                    else => self.typed.append(testing.allocator, b) catch self.failed.store(true, .release),
                }
            }
        }
    }

    /// What the app draws for a submitted line.
    fn respond(self: *FakeApp, line: []const u8) !void {
        var buf: [512]u8 = undefined;
        if (std.mem.eql(u8, line, "2")) {
            try self.draw("\r\x1b[5A\x1b[Jclaude: permission answered No\r\n" ++ live);
            return self.draw(APP_END);
        }
        if (std.mem.eql(u8, line, "/model")) return self.draw("\x1b]133;A\x07" ++ erase ++ "you: /model\r\n" ++ MODEL_PICKER);
        try self.draw(try std.fmt.bufPrint(&buf, "\x1b]133;A\x07" ++ APP_BUSY ++ erase ++ "you: {s}\r\n" ++ live, .{line}));
        if (std.mem.indexOf(u8, line, "permission") != null) return self.draw(APP_PERMISSION);
        try self.draw(try std.fmt.bufPrint(&buf, erase ++ "claude: echo: {s}\r\n" ++ live, .{line}));
        return self.draw(APP_END);
    }
};

const MODEL_PICKER = "Select model\r\n1. Sonnet 4.5\r\n2. Haiku 4.5 (selected)\r\nSelect with numbers [1-2]. Then Enter to submit or Escape to cancel:";
const MODEL_SET = "\r\x1b[3A\x1b[JSet model to {s} for this session only\r\n" ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07";
const MODEL_SET_HAIKU = std.fmt.comptimePrint(MODEL_SET, .{"Haiku 4.5"});
const MODEL_SET_SONNET = std.fmt.comptimePrint(MODEL_SET, .{"Sonnet 4.5"});

fn shaped(arena: std.mem.Allocator, tool: []const u8, result: []const u8) !std.json.ObjectMap {
    const parsed = try mcp.expectToolResultShape(arena, tool, result);
    const sc = parsed.object.get("structuredContent").?.object;
    if (sc.get("error")) |err| {
        std.debug.print("{s}: {s}\n", .{ tool, err.object.get("message").?.string });
        return error.UnexpectedToolError;
    }
    return sc;
}

test "every agent tool answers in its declared shape: a scripted Claude Code on a fake daemon" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();

    var app: FakeApp = undefined;
    const term = try app.init();
    defer app.deinit();
    const saved_terms = mcp_term.term_state;
    mcp_term.term_state = .{ .allocator = testing.allocator, .mux_sock = "unused" };
    defer {
        mcp_term.term_state.terms.deinit(testing.allocator);
        mcp_term.term_state = saved_terms;
        term.exited = true; // the fake daemon takes no kill
        term.deinit();
    }
    try mcp_term.term_state.terms.put(testing.allocator, 1, term);
    try app.draw(APP_IDLE ++ "Claude Code v9 (test)\r\n" ++ live);
    try app.start();

    const attached = try shaped(a, "agent_attach", try rig.call(.agent_attach, "{\"term\":1,\"app\":\"claude\",\"timeout_ms\":5000}"));
    try testing.expect(attached.get("ready").?.bool);
    try testing.expectEqualStrings("claude-1", attached.get("agent").?.string);

    const sent = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"hello\",\"timeout_ms\":10000}"));
    try testing.expectEqualStrings("done", sent.get("outcome").?.string);
    try testing.expectEqualStrings("echo: hello", sent.get("message").?.string);
    // The done carries its job's selection: the answer, never the prompt.
    const sent_recs = sent.get("records").?.array.items;
    try testing.expectEqual(@as(usize, 1), sent_recs.len);
    try testing.expectEqualStrings("echo: hello", sent_recs[0].object.get("text").?.string);
    try testing.expectEqual(@as(i64, 0), sent.get("jobs").?.array.items[0].object.get("job").?.integer);

    const read = try shaped(a, "agent_read", try rig.call(.agent_read, "{}"));
    const read_recs = read.get("records").?.array.items;
    try testing.expectEqual(@as(usize, 1), read_recs.len);
    try testing.expectEqualStrings("assistant", read_recs[0].object.get("kind").?.string);
    try testing.expectEqualStrings("selected", read.get("detail").?.string);
    // Nothing unread: the latest job again; detail all with tools has the
    // same (the fake app draws no tool call).
    const again = try shaped(a, "agent_read", try rig.call(.agent_read, "{}"));
    try testing.expectEqual(@as(usize, 1), again.get("records").?.array.items.len);
    try testing.expectEqual(read.get("next_since").?.integer, again.get("next_since").?.integer);
    const all = try shaped(a, "agent_read", try rig.call(.agent_read, "{\"detail\":\"all\",\"include_tools\":true,\"since\":0}"));
    try testing.expectEqual(@as(usize, 1), all.get("records").?.array.items.len);
    try expectError(a, "agent_read", try rig.call(.agent_read, "{\"detail\":\"everything\"}"), "invalid_args");

    const asked = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"please ask permission\",\"timeout_ms\":10000}"));
    try testing.expectEqualStrings("needs_input", asked.get("outcome").?.string);
    try testing.expectEqualStrings("permission", asked.get("interaction").?.object.get("kind").?.string);
    // Busy agents refuse a prompt rather than queue it.
    try expectError(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"again\"}"), "conflict");
    try expectError(a, "agent_answer", try rig.call(.agent_answer, "{\"choice\":\"Maybe\"}"), "invalid_args");

    const answered = try shaped(a, "agent_answer", try rig.call(.agent_answer, "{\"choice\":\"no\",\"timeout_ms\":10000}"));
    try testing.expectEqualStrings("No", answered.get("answered").?.string);
    try testing.expectEqualStrings("done", answered.get("outcome").?.string);
    try testing.expectEqualStrings("permission answered No", answered.get("message").?.string);

    // The model picker: agent_set returns only once the app confirmed the
    // change (it does so 400 ms after `s`), so the next call finds it idle.
    const before_set = (try shaped(a, "agent_read", try rig.call(.agent_read, "{}"))).get("next_since").?.integer;
    const set = try shaped(a, "agent_set", try rig.call(.agent_set, "{\"model\":\"haiku\",\"timeout_ms\":10000}"));
    try testing.expectEqualStrings("haiku", set.get("model").?.string);
    try testing.expectEqualStrings("Set model to Haiku 4.5 for this session only", set.get("confirmation").?.string);
    try testing.expect(!set.get("relaunched").?.bool);
    try testing.expectEqualStrings("idle", set.get("state").?.string);
    // The adapter's own picker raised nothing for the assistant.
    for (set.get("events").?.array.items) |ev| try testing.expect(!std.mem.eql(u8, ev.object.get("kind").?.string, "needs_input"));
    const after_set = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"right after\",\"timeout_ms\":10000}"));
    try testing.expectEqualStrings("echo: right after", after_set.get("message").?.string);
    // The transcript says what the adapter did, not `user: /model`.
    var arg_buf: [64]u8 = undefined;
    const set_read = try shaped(a, "agent_read", try rig.call(.agent_read, try std.fmt.bufPrint(&arg_buf, "{{\"since\":{d}}}", .{before_set})));
    const set_recs = set_read.get("records").?.array.items;
    try testing.expectEqual(@as(usize, 2), set_recs.len);
    try testing.expectEqualStrings("notice", set_recs[0].object.get("kind").?.string);
    try testing.expect(std.mem.indexOf(u8, set_recs[0].object.get("text").?.string, "model set to haiku for this session: Set model to Haiku 4.5") != null);
    try testing.expectEqualStrings("echo: right after", set_recs[1].object.get("text").?.string);
    // Effort only takes at launch; a term_open terminal cannot be relaunched.
    try expectError(a, "agent_set", try rig.call(.agent_set, "{\"effort\":\"high\"}"), "refused");
    try expectError(a, "agent_set", try rig.call(.agent_set, "{\"effort\":\"turbo\"}"), "invalid_args");
    const stopped = try shaped(a, "agent_interrupt", try rig.call(.agent_interrupt, "{}"));
    try testing.expect(stopped.get("interrupted").?.bool);
    _ = try shaped(a, "agent_wait", try rig.call(.agent_wait, "{\"timeout_ms\":300}"));
    const listed = try shaped(a, "agent_list", try rig.call(.agent_list, "{}"));
    try testing.expectEqual(@as(i64, 1), listed.get("count").?.integer);

    // agent_open's own facts around the same per-agent ones.
    const e = state.entries.items[0];
    const dv = try combine(a, null, null, true, true);
    const opened = try shaped(a, "agent_open", try openResult(a, e, true, false, &.{"a note"}, dv, .{ .match = "x" }));
    try testing.expect(!opened.get("prompt_sent").?.bool);
    try testing.expect(std.mem.indexOf(u8, opened.get("watch_command").?.string, "--match x") != null);

    const closed = try shaped(a, "agent_close", try rig.call(.agent_close, "{}"));
    // An attached terminal belongs to term_open: nothing was killed.
    try testing.expectEqual(@as(usize, 0), closed.get("sessions").?.array.items.len);
    try testing.expect(!app.failed.load(.acquire));
}
