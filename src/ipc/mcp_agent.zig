//! MCP `agent_*` tools (group `agent`): run another coding agent (Claude
//! Code, opencode) as a sub-agent and talk to it through its adapter, in
//! records, state, the pending prompt and events, never raw screens.
//!
//! An agent is a session (two for an API source) on the per-user daemon of
//! the host it runs on, named `agent-<id>` so the user's GUI lists it for
//! watch-along. It outlives this server: a server that exits only detaches,
//! the daemon ends the sessions after `mcp_agent_idle_ttl_hours` unattached,
//! and any later server resumes it from the per-user index
//! (`agentindex.zig`) with `agent_attach {agent}`.
//! The server loop observes every agent between requests (`pollFds`,
//! `dueInMs`, `service`), and so does every wait here, so a turn that ends
//! while the assistant is idle is noticed, and one that ended while an
//! unrelated tool blocked the loop is read correctly afterwards: the
//! sources decide everything from content, never from gaps between feeds.
//!
//! Waking the assistant is the waiter socket (`agentwait.zig` is its
//! protocol and CLI) or a push into its session (`agentpush.zig`: a
//! Claude Code channel, an `agent-wait --server` follower); all of them
//! and `agent_wait` go through `events.Cursor.take` on the agent's one
//! queue and limiter.
//!
//! Gotcha: an `Entry` is heap-allocated and stays put, because the
//! agent's driver points into it; entries are removed only by a tool
//! handler (agent_close), `sweep` (between requests) or `shutdown`, never
//! by `service`, which runs inside tool calls that hold entry pointers.

const std = @import("std");
const c = @import("../c.zig").c;
const mcp = @import("mcp.zig");
const mcp_tools = @import("mcp_tools.zig");
const mcp_term = @import("mcp_term.zig");
const termdrive = @import("termdrive.zig");
const agentwait = @import("agentwait.zig");
const agentpush = @import("agentpush.zig");
const adapter = @import("../agent/adapter.zig");
const agent_mod = @import("../agent/agent.zig");
const events = @import("../agent/events.zig");
const vocab = @import("../agent/vocab.zig");
const output = @import("../agent/output.zig");
const select = @import("../agent/select.zig");
const launch = @import("../agent/launch.zig");
const screen_source = @import("../agent/screen_source.zig");
const opencode = @import("../agent/opencode.zig");
const retry_mod = @import("../agent/retry.zig");
const brief = @import("../agent/brief.zig");
const mcpassets = @import("mcpassets.zig");
const wire = @import("../mux/wire.zig");
const Screen = @import("../grid/screen.zig").Screen;
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
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
const deploy = @import("../mux/deploy.zig");
const Config = @import("../config.zig").Config;
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
/// Legacy descriptors (durable instances before the per-user index) live
/// here, in the instance dir.
const DESCRIPTOR_DIR = "agents";
/// The waiter socket's name in the instance dir.
pub const WAITER_SOCKET = "agents.sock";
const MAX_SUBS = 32;
const DESCRIPTOR_MAX_BYTES = agentindex.DESCRIPTOR_MAX_BYTES;
/// Bound on the remote binary probe (one ssh round trip).
const PROBE_WAIT_MS: i64 = 30_000;
/// Bound on a remote start asking for its secret.
const SECRET_WAIT_MS: i64 = 30_000;
/// Bound on the app ending after its exit recipe, before it is killed.
const EXIT_WAIT_MS: i64 = 10_000;
/// How often a dead forward is respawned / a lost link retried.
const FORWARD_RETRY_MS: i64 = 3_000;
/// Background reconnection of a lost remote link: the first retry, doubled
/// after each failure up to the cap, forever while the agent is here.
const RECONNECT_MIN_MS: i64 = 2_000;
const RECONNECT_MAX_MS: i64 = 60_000;
/// How often `sweep` checks that this server still owns its agents.
const SWEEP_EVERY_MS: i64 = 1_000;
/// Bound on asking a daemon why a session ended.
const TOMBSTONE_WAIT_MS: i64 = 5_000;
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
    "per job for what no result has handed you yet: every message comes to you once (detail \"all\" or a since re-reads, include_tools adds tool calls). " ++
    "When a result says still_working (or sent: the agent had not started yet), run its watch_command in the background (or as a Monitor with --follow) " ++
    "to be woken when the agent finishes (done means settled: idle with no subagents or background tasks) or needs input, " ++
    "instead of polling with agent_wait; to watch several agents at once use agent-wait --any with their ids (--all: one wake-up once every one settled). " ++
    "A wake-up the waiter printed is not repeated by agent_* results, so read the agent afterwards. " ++
    "agent_send to a busy agent queues the prompt for its next turn without interrupting it (interrupt:true stops it first; agents:[...] sends to several at once), and agent_answer takes text when a prompt's right answer is none of its options. " ++
    "agent_read final:true returns just the newest job's last message, and agent_list is compact unless detail:true. " ++
    "Rules every brief repeats belong in a template (agent_template_save, then template + vars on agent_send/agent_open). " ++
    "agent_open returns an id; after a restart, agent_attach {agent: id} resumes it, and relaunch:true starts a gone one again under the same id.";

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
    /// `<app>-xxxx`, unique on this machine (`agentindex.mint`).
    id: []u8,
    /// agent_open's alias, usable wherever the id is (owned).
    name: ?[]u8 = null,
    /// The local daemon its sessions run on (local and plain-ssh agents;
    /// owned): the per-user daemon, or a legacy durable instance's.
    socket: ?[]u8 = null,
    /// This server's hold on the agent in the per-user index.
    claim: ?agentindex.Claim = null,
    /// Its descriptor is in the index (a borrowed terminal's never is).
    indexed: bool = false,
    /// Wait before the next background reconnect of a lost link.
    reconnect_delay_ms: i64 = RECONNECT_MIN_MS,
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
    /// The agent_* results' examined mark; what is DELIVERED is one state
    /// on the agent's queue, shared with every waiter.
    cursor: events.Cursor = .{},
    /// The records handed to the assistant (every result that carries a
    /// selection marks what it returned).
    handed: select.Handed = .{},
    /// The channel push's examined mark (delivery stays the queue's).
    push_cursor: events.Cursor = .{},
    /// What the last agent_* result's watch_command waits for: a push
    /// wakes for the same (its `match` is `push_match`, owned).
    push_filter: events.Filter = .{},
    push_match: ?[]u8 = null,
    /// The highest record id a `detail: all` read covered: the next one
    /// without `since` pages on from it.
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
    /// When the agent was opened or attached (`clock.wallMs`; a durable
    /// reattach keeps the first open's).
    started_ms: i64 = 0,
    forward: ?*termdrive.Term = null,
    /// The next respawn of a dead forward / reconnect of a lost link.
    forward_retry_ms: i64 = 0,
    reconnect_ms: i64 = 0,
    /// The queue's next seq when a prompt last went in: the agent has not
    /// settled since until an event from there settles the turn
    /// (`settleOf`); null before any prompt.
    sent_seq: ?u64 = null,
    /// When the agent was found ended (`clock.wallMs`), its descriptor kept
    /// for `agent_attach relaunch`; 0 while it runs.
    ended_ms: i64 = 0,
    /// `retry_on_overload`: the policy and its episode on the agent's queue.
    retry: retry_mod.Tracker = .{},
    /// An action (a recipe, an API call) runs on the agent now: a retry
    /// never types into it.
    acting: u32 = 0,
    /// A reconnect found its session gone from the daemon: what that
    /// daemon remembered of its end.
    gone_why: ?GoneFacts = null,

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
    /// keep running on the daemon (this server exiting, or another one
    /// taking the agent over). Its index claim is let go either way.
    fn destroy(self: *Entry, kill: bool) void {
        const a = self.allocator;
        self.agent.deinit();
        a.destroy(self.agent);
        for ([_]?*termdrive.Term{ self.visibleTerm(), self.server }) |o| if (o) |t| abandonReconnect(t);
        if (self.claim) |*cl| {
            var buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            if (lockPath(fba.allocator(), self.id)) |lp| cl.release(lp, false) else |_| {}
            self.claim = null;
        }
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
        for ([_]?[]u8{ self.server_session, self.host, self.conversation, self.launch_model, self.launch_effort, self.picked_model, self.name, self.socket, self.push_match }) |o| {
            if (o) |s| a.free(s);
        }
        self.extra.free(a);
        self.handed.deinit(a);
        for (self.recordings.items) |r| a.free(r);
        self.recordings.deinit(a);
        a.free(self.id);
        a.free(self.session);
        a.free(self.binary);
        a.free(self.cwd);
    }
};

/// Why a session is gone, as its daemon's tombstone says (all null: it
/// keeps no record, as a daemon fresh after a reboot).
const GoneFacts = struct {
    reason: ?tombstones.Reason = null,
    ended_ms: ?i64 = null,
    exit_status: ?i32 = null,
    signal: ?i32 = null,

    fn of(tomb: ?tombstones.Reply) GoneFacts {
        const tb = tomb orelse return .{};
        return .{ .reason = tb.reason orelse .unknown, .ended_ms = tb.ended_ms, .exit_status = tb.exit_status, .signal = tb.signal };
    }

    fn reasonName(self: GoneFacts) []const u8 {
        return @tagName(self.reason orelse .unknown);
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
    /// The durable instance's name (its startup reattaches what it opened).
    instance: ?[]const u8 = null,
    /// The per-user index (`agentindex`) and the per-user daemon's socket
    /// on this host (owned; null without a state dir / runtime dir).
    index_dir: ?[]u8 = null,
    user_sock: ?[]u8 = null,
    /// `mcp_agent_idle_ttl_hours`, in seconds: every agent session's
    /// daemon-enforced lifetime with no client attached.
    ttl_secs: u32 = 24 * 3600,
    /// The running executable, absolute (watch_command).
    exe: ?[]u8 = null,
    set: ?adapter.Set = null,
    entries: std.ArrayList(*Entry) = .empty,
    /// Background reconnects in flight (each owned here, freed only once
    /// its thread is done).
    reconnects: std.ArrayList(*ReconnectJob) = .empty,
    last_sweep_ms: i64 = 0,
    waiter: Waiter = .{},
    /// The server's registry record, which publishes `entries`.
    registry: ?*mcp_registry.Lease = null,
    /// The agents the running tool call acts on: their waiters deliver
    /// nothing until it returns, so its own result gets what happens.
    held: [MAX_ANY]*const Entry = undefined,
    held_len: usize = 0,
    /// The running tool call was asked not to wait (`timeout_ms: 0`): its
    /// wait running out is what it asked for, never `timed_out`.
    no_wait: bool = false,
    /// This MCP session's push route (`armPush`) and whether it pushes yet
    /// (`startPush`: the session made its first tool call).
    push: agentpush.Route = .none,
    push_live: bool = false,
    /// Where a channel notification line goes (the MCP server's stdout).
    push_sink: ?*const fn ([]const u8) void = null,
    /// A retry is typing its continue prompt: the service it pumps does
    /// not start another (nor count that prompt as the caller's).
    retry_busy: bool = false,
};

/// Agents one agent_wait or waiter watches at most.
pub const MAX_ANY = agentwait.MAX_ANY;

fn hold(e: *const Entry) void {
    if (isHeld(e) or state.held_len == state.held.len) return;
    state.held[state.held_len] = e;
    state.held_len += 1;
}

fn isHeld(e: *const Entry) bool {
    for (state.held[0..state.held_len]) |h| if (h == e) return true;
    return false;
}

pub var state: State = .{};

/// Arm the agent tools for an isolated or durable instance: `dir` holds
/// the waiter socket (and a durable instance's legacy descriptors).
/// `dir`, `mux_sock` and `instance` must outlive `shutdown`.
pub fn configure(allocator: std.mem.Allocator, dir: []const u8, mux_sock: []const u8, durable: bool, instance: ?[]const u8) void {
    state = .{ .allocator = allocator, .dir = dir, .mux_sock = mux_sock, .durable = durable, .instance = if (durable) instance else null };
    var buf: [4096]u8 = undefined;
    if (platform.exePath(&buf)) |p| state.exe = allocator.dupe(u8, p) catch null;
    state.index_dir = agentindex.dir(allocator);
    state.user_sock = sockpath.defaultSocketPath(allocator) catch null;
    var cfg = Config.load(allocator);
    defer cfg.deinit();
    state.ttl_secs = cfg.mcp_agent_idle_ttl_hours * 3600;
    state.waiter.listen(allocator, dir);
}

/// End every waiter and detach every agent: its sessions run on (their
/// daemon ends them after `ttl_secs` unattached) and any server can
/// `agent_attach` it. Idempotent.
pub fn shutdown() void {
    if (state.dir == null) return;
    const a = state.allocator;
    state.waiter.close(a, "the MCP server is exiting");
    for (state.entries.items) |e| e.destroy(false);
    state.entries.deinit(a);
    state.entries = .empty;
    // A job whose thread still runs cannot be freed: it is abandoned
    // (the process is exiting), a finished one is.
    serviceReconnects(clock.nowMs());
    state.reconnects.deinit(a);
    state.reconnects = .empty;
    if (state.set) |*s| s.deinit();
    state.set = null;
    if (state.exe) |e| a.free(e);
    state.exe = null;
    if (state.index_dir) |d| a.free(d);
    state.index_dir = null;
    if (state.user_sock) |s| a.free(s);
    state.user_sock = null;
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
    return try agentwait.watchCommand(arena, exe, sock, &.{"AGENT"}, .{}, .any);
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
        if (e.name) |n| if (std.mem.eql(u8, n, name)) return e;
    }
    return null;
}

/// Whether `key` names one of this server's agents (id, session or name).
fn knownHere(key: []const u8) bool {
    return findByName(key) != null;
}

/// A machine-unique id for a new agent of `app`.
fn mintId(arena: std.mem.Allocator, app: []const u8) ![]const u8 {
    return agentindex.mint(arena, state.index_dir, app, &knownHere);
}

fn lockPath(a: std.mem.Allocator, id: []const u8) ![]u8 {
    return agentindex.path(a, state.index_dir orelse return error.NoIndex, id, "lock");
}

fn findById(id: []const u8) ?*Entry {
    for (state.entries.items) |e| {
        if (std.mem.eql(u8, e.id, id)) return e;
    }
    return null;
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
            .screen => |*eng| if (screenNeedsTick(eng)) TICK_MS else eng.backgroundDueIn(now_ms),
            .opencode_api => |*api| api.serviceDueIn(now_ms),
        };
        if (d) |x| due = if (due) |y| @min(x, y) else x;
        if (e.retry.due_ms) |at| {
            const x = @max(0, at - now_ms);
            due = if (due) |y| @min(x, y) else x;
        }
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
        serviceEntry(e, now_ms) catch {};
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
    serviceRetries(now_ms);
    servicePush(now_ms);
    state.waiter.service(now_ms);
}

// ── retry on overload ────────────────────────────────────────────

/// Advance every agent's `retry_on_overload` episode and type a due
/// continue prompt. Not while a retry is typing one (its recipe pumps
/// this loop).
fn serviceRetries(now_ms: i64) void {
    if (state.retry_busy) return;
    for (state.entries.items) |e| serviceRetry(e, now_ms) catch {};
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

/// agent_open's / agent_set's `retry_on_overload`: an object (`max`,
/// `backoff_s`; `max` 0 turns it off) or null for off.
fn retryPolicyFrom(arena: std.mem.Allocator, v: std.json.Value, why: *Fail) !?retry_mod.Policy {
    if (v == .null) return null;
    if (v != .object) {
        why.* = .{ .code = .invalid_args, .msg = "retry_on_overload must be an object {max, backoff_s} (or null to turn it off)" };
        return error.Refused;
    }
    var p: retry_mod.Policy = .{};
    var it = v.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const n: i64 = switch (kv.value_ptr.*) {
            .integer => |x| x,
            else => -1,
        };
        if (std.mem.eql(u8, key, "max")) {
            if (n < 0 or n > retry_mod.MAX_RETRIES) {
                why.* = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "retry_on_overload.max must be an integer 0-{d} (0 turns it off)", .{retry_mod.MAX_RETRIES}) };
                return error.Refused;
            }
            p.max = @intCast(n);
        } else if (std.mem.eql(u8, key, "backoff_s")) {
            if (n < 1 or n > retry_mod.BACKOFF_CAP_S) {
                why.* = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "retry_on_overload.backoff_s must be an integer 1-{d}", .{retry_mod.BACKOFF_CAP_S}) };
                return error.Refused;
            }
            p.backoff_s = @intCast(n);
        } else {
            why.* = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "retry_on_overload takes max and backoff_s, not {f}", .{std.json.fmt(key, .{})}) };
            return error.Refused;
        }
    }
    return if (p.max == 0) null else p;
}

/// Set `e`'s retry policy; a pending retry of a policy turned off gives up.
fn setRetryPolicy(e: *Entry, p: ?retry_mod.Policy) void {
    if (e.retry.policy == null and !e.retry.active) e.retry.catchUp(e.agent.queue());
    e.retry.policy = p;
}

// ── push delivery ────────────────────────────────────────────────

/// Set this MCP session's push route (at `initialize`): `sink` gets each
/// channel notification line once `startPush` ran.
pub fn armPush(route: agentpush.Route, sink: ?*const fn ([]const u8) void) void {
    state.push = route;
    state.push_sink = sink;
    state.push_live = false;
}

/// The session is up (its first tool call): Claude Code registers its
/// channel listener after the handshake, and a push before that is lost.
pub fn startPush() void {
    if (state.push != .none) state.push_live = true;
}

/// Server instructions for an MCP session on push `route`.
pub fn instructions(route: agentpush.Route) []const u8 {
    return switch (route) {
        .channel => INSTRUCTIONS ++ " " ++ PUSH_CHANNEL_NOTE,
        .none => INSTRUCTIONS ++ " " ++ PUSH_NOTE,
    };
}

const PUSH_NOTE = "If agent events are pushed into this session (Claude Code: a <channel source=\"sketerm\"> message; opencode: a <sketerm-agent-event> message from the sketerm agents plugin), rely on them and end your turn instead of running watch_command; otherwise use the waiter.";
const PUSH_CHANNEL_NOTE = "This session receives every agent's events as <channel source=\"sketerm\"> messages that start a new turn (a done carries the job's answer when it is short), so after delegating END YOUR TURN: do not run watch_command, a Monitor or agent_wait to wait for them.";

/// `agent-wait --server` followers connected now (the opencode plugin
/// runs one).
pub fn followers() usize {
    var n: usize = 0;
    for (state.waiter.subs.items) |s| {
        if (s.server and s.subscribed and !s.done) n += 1;
    }
    return n;
}

/// Events reach the session without a waiter: a live channel, or a
/// follower watching every agent.
fn pushing() bool {
    return (state.push == .channel and state.push_live) or followers() > 0;
}

/// Keep the filter of the result's watch_command for the pushes.
fn rememberFilter(e: *Entry, f: events.Filter) void {
    const owned: ?[]u8 = if (f.match) |m| (e.allocator.dupe(u8, m) catch return) else null;
    if (e.push_match) |old| e.allocator.free(old);
    e.push_match = owned;
    e.push_filter = .{ .messages = f.messages, .retrying = f.retrying, .match = owned };
}

/// The push for `d`, its answer marked handed out (agent_read and done
/// results do not repeat what the push carried in full).
fn pushOf(arena: std.mem.Allocator, e: *Entry, d: events.Delivery) !agentpush.Push {
    const recs = e.agent.records();
    const p = try agentpush.compose(arena, .{ .agent = e.id, .name = e.name, .conversation = conversationOf(e), .state = e.agent.state() }, d, e.agent.queue(), recs, &e.handed);
    if (p.answer) |i| try e.handed.markRecord(e.allocator, recs[i]);
    return p;
}

/// Send every agent's pending wake-up as one channel notification each.
fn servicePush(now_ms: i64) void {
    if (state.push != .channel or !state.push_live) return;
    const sink = state.push_sink orelse return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (state.entries.items) |e| {
        // A tool call on this agent is under way: its result gets this.
        if (isHeld(e)) continue;
        const d = (e.push_cursor.take(e.agent.queue(), e.push_filter, now_ms, arena) catch continue) orelse continue;
        const p = pushOf(arena, e, d) catch continue;
        sink(agentpush.encodeChannel(arena, p) catch continue);
    }
}

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
const ReconnectJob = struct {
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
fn abandonReconnect(t: *const termdrive.Term) void {
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
fn serviceReconnects(now_ms: i64) void {
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
fn goneDetail(g: GoneFacts) []const u8 {
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

/// A call on an agent whose link is lost retries it at once (in the
/// background; the call does not wait for it) and restarts the backoff.
fn reconnectIfLost(e: *Entry) void {
    e.reconnect_ms = 0;
    e.reconnect_delay_ms = RECONNECT_MIN_MS;
    kickReconnects(e, clock.nowMs());
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
        // A prompt before the app is ready (a trust dialog) is the caller's.
        if (e.agent.interaction() != null) return false;
        if (gone(e) or e.agent.state() == .disconnected or clock.nowMs() >= deadline) return false;
        pump(deadline - clock.nowMs());
    }
    return true;
}

/// The assistant's next delivery with `filter`, waiting until `deadline`;
/// null on timeout or when the agent is gone with nothing left to hand.
fn waitDelivery(e: *Entry, filter: events.Filter, deadline: i64, arena: std.mem.Allocator) !?events.Delivery {
    const one = [1]*Entry{e};
    const got = (try waitAny(&one, filter, deadline, arena)) orelse return null;
    return got.delivery;
}

const Woken = struct { entry: *Entry, delivery: events.Delivery };

/// The first delivery from any of `entries` (in their order when several
/// have one), waiting until `deadline`; null on timeout or when every one
/// is gone with nothing left to hand.
fn waitAny(entries: []const *Entry, filter: events.Filter, deadline: i64, arena: std.mem.Allocator) !?Woken {
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
fn settleOf(e: *Entry) ?Settle {
    const st = e.agent.state();
    if (!st.settled()) return null;
    const q = e.agent.queue();
    if (e.sent_seq) |from| {
        const ev = q.lastSettle(from) orelse return null;
        return .{ .event = ev, .state = st };
    }
    return .{ .event = q.lastSettle(0), .state = st };
}

/// One agent's line of an `all` wake: the settling kind (else the state).
fn settledOf(e: *const Entry, s: Settle) agentwait.Settled {
    const ev = s.event orelse return .{ .agent = e.id, .outcome = @tagName(s.state), .state = @tagName(s.state) };
    return .{
        .agent = e.id,
        .outcome = @tagName(ev.kind),
        .state = @tagName(s.state),
        .text = if (ev.kind.announcesRecord()) events.preview(ev.text) else ev.text,
        .record = ev.record,
    };
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

/// One agent a waiter watches, with its own examined mark.
const Target = struct {
    id: []u8,
    cursor: events.Cursor,
    /// An `all` waiter's agent that closed: settled, as `closed`.
    closed: bool = false,
};

const Sub = struct {
    fd: c_int,
    inbuf: std.ArrayList(u8) = .empty,
    subscribed: bool = false,
    targets: std.ArrayList(Target) = .empty,
    match: ?[]u8 = null,
    messages: bool = false,
    retrying: bool = false,
    follow: bool = false,
    /// Every agent of the server, later ones included, with pushed text.
    server: bool = false,
    /// One wake once every target settled (`--all`).
    all: bool = false,
    done: bool = false,

    /// What wakes it for `e`: its own filter, and for a server follower
    /// also what the assistant's last call on `e` asked for.
    fn filterFor(self: *const Sub, e: *const Entry) events.Filter {
        const own: events.Filter = .{ .messages = self.messages, .match = self.match, .retrying = self.retrying };
        if (!self.server) return own;
        return .{
            .messages = own.messages or e.push_filter.messages,
            .retrying = own.retrying or e.push_filter.retrying,
            .match = own.match orelse e.push_filter.match,
        };
    }

    /// Add every agent it does not watch yet (a server follower).
    fn adoptAll(self: *Sub, a: std.mem.Allocator) void {
        for (state.entries.items) |e| {
            if (self.watches(e.id) != null) continue;
            const id = a.dupe(u8, e.id) catch return;
            self.targets.append(a, .{ .id = id, .cursor = .after(e.cursor.seen) }) catch return a.free(id);
        }
    }

    fn watches(self: *const Sub, id: []const u8) ?usize {
        for (self.targets.items, 0..) |tg, i| if (std.mem.eql(u8, tg.id, id)) return i;
        return null;
    }

    /// Stop watching target `i`.
    fn drop(self: *Sub, a: std.mem.Allocator, i: usize) void {
        a.free(self.targets.items[i].id);
        _ = self.targets.orderedRemove(i);
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
            for (s.targets.items) |*tg| {
                const e = findById(tg.id) orelse continue;
                if (tg.cursor.digestDueIn(e.agent.queue(), now_ms)) |d| due = if (due) |x| @min(x, d) else d;
            }
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
        const names = sub.names();
        if (names.len == 0 and !sub.server) return endSub(s, "no agent named");
        if (names.len > MAX_ANY) return endSub(s, "too many agents");
        for (names) |name| {
            const e = findByName(name) orelse
                return endSub(s, std.fmt.allocPrint(arena, "no agent {s} on this server", .{name}) catch "no such agent");
            if (s.watches(e.id) != null) continue;
            const id = a.dupe(u8, e.id) catch return endSub(s, "out of memory");
            // Without `since`: whatever nobody delivered yet, and opt-in
            // events the assistant's calls have not examined.
            const cursor = if (sub.since) |n| events.Cursor.replayFrom(n) else events.Cursor.after(e.cursor.seen);
            s.targets.append(a, .{ .id = id, .cursor = cursor }) catch {
                a.free(id);
                return endSub(s, "out of memory");
            };
        }
        if (sub.match) |m| s.match = a.dupe(u8, m) catch return endSub(s, "out of memory");
        s.messages = sub.messages;
        s.retrying = sub.retrying;
        s.follow = sub.follow;
        s.server = sub.server;
        s.all = sub.all and !sub.server;
    }
    if (s.all) return serviceAll(arena, s);
    if (s.server) s.adoptAll(a);
    var i: usize = 0;
    while (i < s.targets.items.len) {
        const tg = &s.targets.items[i];
        const e = findById(tg.id) orelse {
            s.drop(a, i);
            continue;
        };
        i += 1;
        // A tool call on this agent is under way: its result gets this.
        if (isHeld(e)) continue;
        const d = (tg.cursor.take(e.agent.queue(), s.filterFor(e), now_ms, arena) catch continue) orelse continue;
        const pushed: ?agentwait.Pushed = if (s.server) blk: {
            const p = pushOf(arena, e, d) catch continue;
            break :blk .{ .content = p.content, .meta = p.meta };
        } else null;
        sendLine(s, agentwait.encodeWake(arena, e.id, e.agent.state(), d, e.agent.queue(), pushed) catch continue);
        if (!s.follow) {
            s.done = true;
            return;
        }
    }
    // A server follower watches agents not opened yet.
    if (s.targets.items.len == 0 and !s.server) endSub(s, "agent closed");
}

/// An `all` waiter: once every target settled (a closed one included),
/// one line with each one's outcome, what it delivers marked delivered.
fn serviceAll(arena: std.mem.Allocator, s: *Sub) void {
    for (s.targets.items) |*tg| {
        if (tg.closed) continue;
        const e = findById(tg.id) orelse {
            tg.closed = true;
            continue;
        };
        // A tool call on it is under way: its result gets what happens.
        if (isHeld(e) or settleOf(e) == null) return;
    }
    const out = arena.alloc(agentwait.Settled, s.targets.items.len) catch return endSub(s, "out of memory");
    for (s.targets.items, out) |*tg, *o| {
        const e = (if (tg.closed) null else findById(tg.id)) orelse {
            o.* = .{ .agent = tg.id, .outcome = "closed", .state = "" };
            continue;
        };
        o.* = settledOf(e, settleOf(e).?);
        // Delivered like any wake-up: no result repeats it.
        if (tg.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena)) |_| {} else |_| {}
    }
    sendLine(s, agentwait.encodeAll(arena, out) catch return endSub(s, "out of memory"));
    s.done = true;
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
    for (s.targets.items) |tg| a.free(tg.id);
    s.targets.deinit(a);
    if (s.match) |m| a.free(m);
    a.destroy(s);
}

/// Drop an agent that is going away from every waiter, and end the
/// waiters left watching nothing.
fn endWaitersOf(id: []const u8, reason: []const u8) void {
    const a = state.allocator;
    var i: usize = 0;
    while (i < state.waiter.subs.items.len) {
        const s = state.waiter.subs.items[i];
        // An `all` waiter counts a closed agent as settled.
        if (s.subscribed) if (s.watches(id)) |ti| {
            if (s.all) s.targets.items[ti].closed = true else s.drop(a, ti);
        };
        if (s.subscribed and s.targets.items.len == 0 and !s.server) {
            if (!s.done) endSub(s, reason);
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
    state.held_len = 0;
    defer state.held_len = 0;
    state.no_wait = if (argInt(args, "timeout_ms")) |ms| ms == 0 else false;
    defer state.no_wait = false;
    sweep(clock.nowMs());
    return switch (tool) {
        .agent_adapters => adaptersTool(arena, args),
        .agent_open => openTool(arena, args),
        .agent_attach => if (argStr(args, "agent") != null) attachIdTool(arena, args) else attachTool(arena, args),
        .agent_list => listTool(arena, args),
        .agent_send => if (mcp.argValue(args, "agents")) |v| switch (v) {
            .array => |list| if (argStr(args, "agent") != null)
                errRes(arena, .invalid_args, "pass either 'agent' or 'agents', not both")
            else
                sendManyTool(arena, args, list.items),
            else => errRes(arena, .invalid_args, "agents must be an array of agent ids or names"),
        } else withEntry(arena, args, sendTool),
        .agent_wait => if (mcp.argValue(args, "agents")) |v| switch (v) {
            .array => |list| if (argBool(args, "all")) waitAllTool(arena, args, list.items) else waitAnyTool(arena, args, list.items),
            else => errRes(arena, .invalid_args, "agents must be an array of agent ids"),
        } else if (argBool(args, "all"))
            errRes(arena, .invalid_args, "all waits on several agents: pass them as 'agents'")
        else
            withEntry(arena, args, waitTool),
        .agent_read => withEntry(arena, args, readTool),
        .agent_answer => withEntry(arena, args, answerTool),
        .agent_set => withEntry(arena, args, setTool),
        .agent_interrupt => withEntry(arena, args, interruptTool),
        .agent_close => withEntry(arena, args, closeTool),
        .agent_template_save => templateSaveTool(arena, args),
        .agent_templates => templatesTool(arena, args),
        .agent_template_delete => templateDeleteTool(arena, args),
    };
}

fn withEntry(
    arena: std.mem.Allocator,
    args: std.json.Value,
    comptime body: fn (std.mem.Allocator, std.json.Value, *Entry) anyerror![]const u8,
) ![]const u8 {
    if (entryFromArgs(args)) |e| hold(e);
    service(clock.nowMs());
    const e = entryFromArgs(args) orelse return notFound(arena, args);
    hold(e);
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
    if (argStr(args, "agent")) |name| if (state.index_dir) |d| if (try agentindex.resolve(arena, d, name)) |desc|
        return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "agent '{s}' ({s}) is not attached to this server: agent_attach {{agent: \"{s}\"}} resumes it", .{ name, desc.id, name }));
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
    return .{ .messages = argBool(args, "messages"), .match = if (m != null and m.?.len > 0) m else null, .retrying = argBool(args, "retrying") };
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
    /// The call submitted a prompt (an outcome may be `sent`).
    sent: bool = false,
    /// The prompt went into the app's queue (an outcome may be `queued`).
    queued: bool = false,
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
/// `outcomeRank`, else `exited` for an agent that is gone, else `queued`
/// for a prompt the app still holds for a later turn, else `sent` for a
/// prompt the agent has not started on, else still working.
/// @param sent the call submitted a prompt.
/// @param queued the call queued it and the app has not taken it yet.
pub fn outcomeOf(items: []const events.Item, st: vocab.State, sent: bool, queued: bool) []const u8 {
    var best: ?vocab.EventKind = null;
    for (items) |it| {
        if (best == null or it.kind.outcomeRank() > best.?.outcomeRank()) best = it.kind;
    }
    if (best) |b| return @tagName(b);
    if (st == .exited) return @tagName(vocab.EventKind.exited);
    if (sent and queued) return @tagName(vocab.WaitOutcome.queued);
    if (sent and st.takesPrompt()) return @tagName(vocab.WaitOutcome.sent);
    return @tagName(vocab.WaitOutcome.still_working);
}

const EventJson = struct {
    seq: u64,
    kind: []const u8,
    text: []const u8,
    detail: []const u8,
    count: u32,
    class: ?[]const u8 = null,
    job: ?u32 = null,
    record: ?u64 = null,
    background_tasks: ?u32 = null,
};

/// An event's text as a result shows it: a record it announces is
/// referenced by id with a one-line preview, never repeated whole.
fn eventText(it: events.Item) []const u8 {
    return if (it.kind.announcesRecord()) events.preview(it.event.text) else it.event.text;
}

const InteractionJson = struct {
    kind: []const u8,
    title: []const u8,
    detail: []const u8,
    hint: []const u8,
    options: []const output.Option,
    free_text: bool,
};

fn toJson(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
}

/// What a result's watch_command waits for.
const Watch = struct {
    filter: events.Filter = .{},
    /// Several agents (agent_wait `agents`, agent_send `agents`).
    any: []const []const u8 = &.{},
    /// How the command wakes on several: the first of any, or once all settled.
    several: agentwait.Several = .any,
    /// The template the call's prompt was rendered from (the `template` fact).
    template: ?[]const u8 = null,
};

/// The facts and prose every per-agent result shares, then the payload
/// blocks (`extra` first) and the finished result.
fn finish(arena: std.mem.Allocator, res: *Res, e: *Entry, dv: Delivered, watch: Watch, extra: []const Block) ![]const u8 {
    const st = e.agent.state();
    const q = e.agent.queue();
    rememberFilter(e, watch.filter);
    try res.fact("agent", e.id);
    if (e.name) |n| try res.fact("name", n);
    try res.fact("app", e.loaded.spec.id);
    try res.fact("source", @tagName(e.agent.kind()));
    try res.fact("state", @tagName(st));
    try res.fact("ready", e.agent.ready());
    try res.fact("session", e.session);
    if (e.server_session) |s| try res.fact("server_session", s);
    if (e.host) |h| try res.fact("host", h);
    if (conversationOf(e)) |cv| try res.fact("conversation", cv);
    try res.fact("transport", @tagName(e.transport));
    try goneFacts(arena, res, e);
    try retryFacts(res, e);

    var message: ?[]const u8 = null;
    var job_block: ?Block = null;
    if (dv.wait) |w| {
        const post = dv.items[w.post_from..];
        const outcome = outcomeOf(post, st, w.sent, w.queued and e.agent.queuedPrompts() > 0);
        try res.fact("outcome", outcome);
        var job: ?u32 = null;
        var first: ?u32 = null;
        var background: ?u32 = null;
        for (post) |it| if (it.kind == .done) {
            message = it.event.text;
            job = it.event.job;
            background = it.event.background_tasks;
        };
        // A done covers every job since the previous one that woke (one a
        // queued prompt superseded has none of its own), a done that rode
        // along before the wait included.
        for (dv.items) |it| if (it.kind == .done) {
            const f = it.event.first_job orelse it.event.job orelse continue;
            first = if (first) |x| @min(x, f) else f;
        };
        // The finished job(s) as agent_read would return them, without
        // what the assistant was handed before: no extra read, no repeat.
        if (job) |j| {
            const lo = @min(first orelse j, j);
            const recs = e.agent.records();
            var jobs: std.ArrayList(u32) = .empty;
            for (try select.jobsAfter(arena, recs, 0)) |x| if (x >= lo and x < j) try jobs.append(arena, x);
            try jobs.append(arena, j);
            const fresh = if (select.answerIndex(recs, j)) |i| !e.handed.has(recs[i]) else false;
            if (!fresh) message = null;
            const sel = try select.select(arena, recs, jobs.items, .{ .handed = &e.handed, .keep_empty = true });
            job_block = .{ .name = try jobsName(arena, sel.jobs), .body = try writeSelection(arena, res, recs, sel) };
            try e.handed.markSelection(e.allocator, recs, sel);
        }
        if (message) |m| try res.fact("message", m);
        try res.fact("timed_out", w.timed_out and !state.no_wait);
        try res.textf("{s}: {s} (state {s})", .{ e.id, outcome, @tagName(st) });
        if (background) |n|
            try res.textf("done after {d} minutes idle with {d} background task(s) still running", .{ @divTrunc(select.BACKGROUND_DONE_CAP_MS, 60_000), n });
        if (w.timed_out and pushing()) {
            try res.textf("{s}: its events are pushed into this session as they happen, so end your turn here; no watch_command, Monitor or agent_wait is needed", .{outcome});
        } else if (w.timed_out) {
            if (std.mem.eql(u8, outcome, @tagName(vocab.WaitOutcome.queued)))
                try res.text("queued; the agent was busy and takes the prompt when its current turn ends: run watch_command in the background (or as a Monitor with --follow) to be woken once it has answered it")
            else if (std.mem.eql(u8, outcome, @tagName(vocab.WaitOutcome.sent)))
                try res.text("sent; the agent had not started on it when the call returned: run watch_command in the background (or as a Monitor with --follow) to be woken instead of polling")
            else
                try res.text("still working when the wait ran out: run watch_command in the background (or as a Monitor with --follow) to be woken instead of polling");
        }
    } else try res.textf("{s}: state {s}", .{ e.id, @tagName(st) });
    if (watch.template) |x| try res.fact("template", x);

    try res.raw("events", try toJson(arena, try eventsJson(arena, dv.items)));
    if (dv.digest) |g| {
        const latest = if (q.bySeq(g.latest_seq)) |ev| events.preview(ev.text) else "";
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
        .free_text = x.free_text,
    }));
    var cmd: ?[]const u8 = null;
    if (state.exe) |exe| {
        if (state.waiter.path) |sock| {
            const one = [1][]const u8{e.id};
            cmd = try agentwait.watchCommand(arena, exe, sock, if (watch.any.len > 0) watch.any else &one, watch.filter, watch.several);
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
            if (ev.event.record) |id| try aw.writer.print(" [{d}]", .{id});
            if (ev.event.text.len > 0) try aw.writer.print(": {s}", .{agentwait.clip(eventText(ev), 300)});
        }
        try block(res, .{ .name = "events", .body = aw.written() });
    }
    if (it) |x| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.print("{s}: {s}", .{ @tagName(x.kind), x.title });
        if (x.detail.len > 0) try aw.writer.print("\n{s}", .{x.detail});
        for (x.options, 1..) |o, n| try aw.writer.print("\n{d}. {s}{s}", .{ n, o.label, if (o.selected) " (selected)" else "" });
        if (x.hint.len > 0) try aw.writer.print("\n{s}", .{x.hint});
        if (x.free_text) try aw.writer.writeAll("\n(a free-text answer is accepted: agent_answer text)");
        try block(res, .{ .name = "prompt", .body = aw.written() });
    }
    if (cmd) |x| try block(res, .{ .name = "watch_command", .body = x });
    return res.finish();
}

/// The app conversation `e` runs (what `agent_open resume` takes), or null
/// while unknown: a screen app's session id, an API source's session.
fn conversationOf(e: *Entry) ?[]const u8 {
    return switch (e.agent.source) {
        .opencode_api => |*api| api.sessionId(),
        .screen => e.conversation,
    };
}

/// A permission policy as the `permissions` fact: name to action.
fn permissionsValue(arena: std.mem.Allocator, perms: []const launch.Permission) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (perms) |p| try obj.put(arena, p.name, .{ .string = @tagName(p.action) });
    return .{ .object = obj };
}

/// Whether a gone agent can be started again, as agent_attach answers it:
/// its descriptor was kept (`ended_ms`).
fn relaunchableOf(e: *const Entry) ?bool {
    return if (gone(e)) e.ended_ms != 0 else null;
}

/// A gone agent's `relaunchable` and, when a reconnect found its session
/// gone, `gone_reason`, with a line saying what to do.
fn goneFacts(arena: std.mem.Allocator, res: *Res, e: *Entry) !void {
    const can = relaunchableOf(e) orelse return;
    try res.fact("relaunchable", can);
    if (e.gone_why) |g| try res.fact("gone_reason", g.reasonName());
    const key = e.name orelse e.id;
    if (can)
        try res.textf("{s} is gone{s}{s}{s}: agent_attach with agent \"{s}\" and relaunch: true starts it again with its launch settings, resuming its conversation", .{
            e.id, if (e.gone_why != null) " (" else "", if (e.gone_why) |g| g.reasonName() else "", if (e.gone_why != null) ")" else "", key,
        })
    else
        try res.textf("{s} is gone and cannot be relaunched{s}; agent_open a new one", .{ e.id, if (e.gone_why) |g| try std.fmt.allocPrint(arena, " ({s})", .{g.reasonName()}) else "" });
}

/// The retry policy and where its episode stands, when one is set.
fn retryFacts(res: *Res, e: *const Entry) !void {
    const p = e.retry.policy orelse return;
    try res.fact("retry_on_overload", .{
        .max = p.max,
        .backoff_s = p.backoff_s,
        .used = e.retry.used,
        .pending = e.retry.active,
        .next_in_ms = if (e.retry.due_ms) |d| @max(0, d - clock.nowMs()) else null,
    });
}

/// A job block's header: the jobs it holds (`job 3`, `jobs 2, 4`, `jobs 2-4`).
fn jobsName(arena: std.mem.Allocator, jobs: []const select.JobSummary) ![]const u8 {
    if (jobs.len == 0) return "jobs";
    if (jobs.len == 1) return std.fmt.allocPrint(arena, "job {d}", .{jobs[0].job});
    var contiguous = true;
    for (jobs[1..], 0..) |s, i| {
        if (s.job != jobs[i].job + 1) contiguous = false;
    }
    if (contiguous) return std.fmt.allocPrint(arena, "jobs {d}-{d}", .{ jobs[0].job, jobs[jobs.len - 1].job });
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "jobs ");
    for (jobs, 0..) |s, i| try out.print(arena, "{s}{d}", .{ if (i > 0) ", " else "", s.job });
    return out.items;
}

fn block(res: *Res, b: Block) !void {
    try res.textf("--- {s} ---", .{b.name});
    try res.text(b.body);
}

// ── agent_adapters ───────────────────────────────────────────────

/// The one host rule of every ssh leg (`sshroute.validDestination`), so an
/// agent's host is also one its watch route can carry.
const validHost = mcp_term.validHostSpec;

const BAD_HOST = mcp_term.BAD_HOST;

/// Resolve executables on `host` in one ssh round trip (`launch.probeScript`).
fn probeRemote(arena: std.mem.Allocator, host: []const u8, lookups: []const launch.Lookup, opts: launch.ProbeOpts) !union(enum) { ok: launch.ProbeResult, fail: Fail } {
    const script = try launch.probeScript(arena, lookups, opts);
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
        switch (try probeRemote(arena, h, lookups, .{})) {
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
        /// The names agent_open `permissions` takes; null: none.
        permissions: ?struct { names: []const []const u8, patterns: []const []const u8 },
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
            .permissions = if (l.spec.launch.permissions) |p| .{ .names = p.names, .patterns = p.patterns } else null,
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
    prompt: ?Prompt,
    /// An existing conversation of the app to continue (`agent_open resume`).
    resume_id: ?[]const u8 = null,
    cols: u16,
    rows: u16,
    host: ?[]const u8,
    choice: transport_mod.Choice,
    extra: launch.Extra,
    /// The alias (`name`), also the sessions' title.
    name: ?[]const u8 = null,
    /// A relaunch keeps the agent's id instead of minting one.
    keep_id: ?[]const u8 = null,
    /// `retry_on_overload`; null = off.
    retry: ?retry_mod.Policy = null,
};

/// A conversation id travels on the app's argv and in an API path, so only
/// plain id characters are accepted.
fn validConversationId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

/// agent_open's `args` (strings) and `env` (string values), checked by
/// `launch.checkExtra`.
fn extraOpts(arena: std.mem.Allocator, args: std.json.Value, loaded: *const adapter.Loaded, why: *Fail) !launch.Extra {
    var x: launch.Extra = .{};
    inline for (.{ "args", "server_args", "tui_args" }) |key| {
        if (mcp.argValue(args, key)) |v| if (v != .null) {
            if (v != .array) {
                why.* = .{ .code = .invalid_args, .msg = key ++ " must be an array of strings" };
                return error.Refused;
            }
            const out = try arena.alloc([]const u8, v.array.items.len);
            for (v.array.items, out) |item, *o| {
                if (item != .string) {
                    why.* = .{ .code = .invalid_args, .msg = key ++ " must be an array of strings" };
                    return error.Refused;
                }
                o.* = item.string;
            }
            @field(x, key) = out;
        };
    }
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
    if (mcp.argValue(args, "path_prepend")) |v| if (v != .null) {
        if (v != .array) {
            why.* = .{ .code = .invalid_args, .msg = "path_prepend must be an array of absolute directories" };
            return error.Refused;
        }
        const out = try arena.alloc([]const u8, v.array.items.len);
        for (v.array.items, out) |item, *o| {
            if (item != .string) {
                why.* = .{ .code = .invalid_args, .msg = "path_prepend must be an array of absolute directories" };
                return error.Refused;
            }
            o.* = item.string;
        }
        x.path_prepend = out;
    };
    if (mcp.argValue(args, "permissions")) |v| if (v != .null) {
        const shape = "permissions must be an object of tool or permission names to allow, ask or deny";
        if (v != .object) {
            why.* = .{ .code = .invalid_args, .msg = shape };
            return error.Refused;
        }
        const out = try arena.alloc(launch.Permission, v.object.count());
        var it = v.object.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            const action = if (kv.value_ptr.* == .string) std.meta.stringToEnum(vocab.PermissionAction, kv.value_ptr.string) else null;
            out[i] = .{ .name = kv.key_ptr.*, .action = action orelse {
                why.* = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "permissions {f}: the value must be allow, ask or deny", .{std.json.fmt(kv.key_ptr.*, .{})}) };
                return error.Refused;
            } };
        }
        x.permissions = out;
    };
    // Default true: only an explicit false opts out.
    x.login_shell = if (mcp.argValue(args, "login_shell")) |v| !(v == .bool and !v.bool) else true;
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
    const prompt = try promptFrom(arena, args, "prompt", why);
    const name = argStr(args, "name");
    if (name) |n| {
        if (!agentindex.validName(n)) {
            why.* = .{ .code = .invalid_args, .msg = "name must be 1-64 letters, digits, '.', '-' or '_', starting with a letter or digit" };
            return error.Refused;
        }
        // Unique among this machine's live agents, ids included.
        const in_index = if (state.index_dir) |d| try agentindex.taken(arena, d, n) else false;
        if (knownHere(n) or in_index) {
            why.* = .{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "the name '{s}' is taken by a live agent on this machine (agent_attach {{agent: \"{s}\"}} resumes it); pick another", .{ n, n }) };
            return error.Refused;
        }
    }
    const resume_id = argStr(args, "resume");
    if (resume_id) |r| {
        if (!validConversationId(r)) {
            why.* = .{ .code = .invalid_args, .msg = "resume must be a conversation id: 1-128 letters, digits, '-' or '_'" };
            return error.Refused;
        }
        const resumable = switch (loaded.spec.source) {
            .screen => loaded.spec.launch.resume_args.len > 0,
            .opencode_api => true,
        };
        if (!resumable) {
            why.* = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "{s} cannot resume a conversation (its adapter declares no resume_args)", .{loaded.spec.id}) };
            return error.Refused;
        }
    }
    const retry = if (mcp.argValue(args, "retry_on_overload")) |v| try retryPolicyFrom(arena, v, why) else null;
    return .{
        .retry = retry,
        .name = name,
        .resume_id = resume_id,
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
    // timeout_ms 0 is about the turn: the start and, with a prompt, the
    // wait for the app to take it stay bounded by the default, so a prompt
    // is handed off in one call (`sent`) instead of never being sent.
    const start_deadline = if (state.no_wait) clock.nowMs() + DEFAULT_WAIT_MS else deadline;
    var facts: LaunchFacts = .{};
    var claim: ?agentindex.Claim = null;
    const st = startAgent(arena, loaded, &o, &claim, .{
        .fresh_login = argBool(args, "fresh_login"),
        .spawn = start_deadline,
        .ready = if (o.prompt != null) start_deadline else deadline,
    }, &facts, &why) catch |err| switch (err) {
        error.Refused => return errRes(arena, why.code, why.msg),
        else => return err,
    };
    const e = st.entry;
    const ready = st.ready;
    var notes = st.notes;
    const filter = filterFrom(args);

    var dv: Delivered = undefined;
    var sent = false;
    if (o.prompt) |p| {
        if (ready) {
            switch (try submitAndWait(arena, e, p, filter, deadline, false)) {
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
            try notes.append(arena, try std.fmt.allocPrint(arena, "prompt not sent: the agent was not ready within {d} ms", .{@max(0, start_deadline - st.started_ms)}));
            dv = try pending(arena, e);
        }
    } else dv = try pending(arena, e);
    return openResult(arena, e, ready, sent, notes.items, dv, .{ .filter = filter, .template = if (o.prompt) |p| p.template else null }, &facts);
}

/// The bounds of a start (`startAgent`).
const StartBounds = struct {
    fresh_login: bool = false,
    /// The spawn, an API server's health included.
    spawn: i64,
    /// The app becoming ready to take input.
    ready: i64,
};

/// A started agent: listed, indexed and held.
const Started = struct {
    entry: *Entry,
    ready: bool,
    /// What the start could not apply (a model or effort set in the app).
    notes: std.ArrayList([]const u8),
    started_ms: i64,
};

/// Resolve the binary where the agent runs, start it with `o`, list it,
/// index it (holding `claim`, which is moved into the entry and nulled, or
/// a fresh one) and wait for it to be ready. agent_open and agent_attach
/// relaunch share it.
/// @throws Refused with `why` set; `claim` is still the caller's unless nulled.
fn startAgent(arena: std.mem.Allocator, loaded: *const adapter.Loaded, o: *OpenOpts, claim: *?agentindex.Claim, bounds: StartBounds, facts: *LaunchFacts, why: *Fail) !Started {
    const started_ms = clock.nowMs();
    const name = o.override orelse loaded.spec.launch.binary;
    // Before the first connection: which login the agent's legs ride, and a
    // fresh one when sketerm's master is too old or the caller asks.
    if (o.host) |h| facts.master = try mcp_term.sshMasterCheck(arena, h, mcp_term.legs.script, bounds.fresh_login);
    const binary = if (o.host) |h| blk: {
        // One probe on the host, in its login environment: the binary from
        // the adapter's candidates, its version, the dir, the home.
        const r = switch (try probeRemote(arena, h, &.{.{ .launch = loaded.spec.launch, .override = o.override, .version = true }}, .{
            .dir = o.cwd,
            .login = o.extra.login_shell,
            .path_prepend = o.extra.path_prepend,
        })) {
            .fail => |f| {
                why.* = f;
                return error.Refused;
            },
            .ok => |r| r,
        };
        if (r.dir_ok) |ok| if (!ok) {
            why.* = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "cwd {s} is not a directory on {s}", .{ o.cwd.?, h }) };
            return error.Refused;
        };
        if (o.cwd == null) o.cwd = r.home orelse "/";
        facts.version = r.versions[0];
        facts.login = r.login;
        facts.shell = r.shell;
        break :blk r.binaries[0] orelse {
            why.* = .{ .code = .unavailable, .msg = try std.fmt.allocPrint(arena, "cannot find {s} on {s} (looked in: {s}{s}); pass 'binary' with its name or absolute path there", .{ name, h, try candidateList(arena, loaded), if (r.login == false and o.extra.login_shell) ", the login shell did not answer in time" else "" }) };
            return error.Refused;
        };
    } else blk: {
        var here = localHost();
        here.path = try launch.prependPath(arena, o.extra.path_prepend, here.path);
        const found = (try launch.resolve(arena, loaded.spec.launch, o.override, here)) orelse {
            why.* = .{ .code = .unavailable, .msg = try std.fmt.allocPrint(arena, "cannot find {s} on this machine (looked in: {s}); pass 'binary' with its name or absolute path", .{ name, try candidateList(arena, loaded) }) };
            return error.Refused;
        };
        facts.version = try localVersion(arena, loaded.spec.launch, found);
        break :blk found;
    };

    var where = Where{ .host = o.host, .cols = o.cols, .rows = o.rows };
    const e = try switch (loaded.spec.source) {
        .screen => spawnScreen(arena, loaded, binary, o.*, &where, bounds.spawn, why),
        .opencode_api => spawnApi(arena, loaded, binary, o.*, &where, bounds.spawn, why),
    };
    state.entries.append(state.allocator, e) catch |err| {
        e.destroy(true);
        return err;
    };
    setRetryPolicy(e, o.retry);
    if (claim.*) |cl| {
        e.claim = cl;
        claim.* = null;
    } else claimNew(e);
    writeDescriptor(e);
    publishAgents();
    hold(e);

    const ready = waitReady(e, bounds.ready);
    // A conversation the app does not have is an error, never a new one
    // left running in its name.
    if (o.resume_id) |rid| if (try resumeRefused(arena, e, rid)) |msg| {
        discard(e);
        why.* = .{ .code = .not_found, .msg = msg };
        return error.Refused;
    };
    // An adopted conversation's past was the caller's before: it is
    // history, never a first delivery (`since`/`detail:"all"` re-read it).
    if (o.resume_id != null and ready) {
        // A screen source only folds turns at a turn end; fold the
        // reprinted history now, or the first new turn delivers it.
        try e.agent.syncHistory();
        for (e.agent.records()) |r| try e.handed.markRecord(e.allocator, r);
    }
    var notes: std.ArrayList([]const u8) = .empty;
    // A model or effort the launch cannot take goes through the app.
    if (ready) {
        if (o.model) |m| if (!launch.launchTakes(loaded.spec.launch, .model)) {
            if (try applySet(arena, e, .{ .set_model = m }, bounds.ready)) |f| try notes.append(arena, try std.fmt.allocPrint(arena, "model not set: {s}", .{f.msg}));
        };
        if (o.effort) |x| if (!launch.launchTakes(loaded.spec.launch, .effort)) {
            if (try applySet(arena, e, .{ .set_effort = x }, bounds.ready)) |f| try notes.append(arena, try std.fmt.allocPrint(arena, "effort not set: {s}", .{f.msg}));
        };
    }
    return .{ .entry = e, .ready = ready, .notes = notes, .started_ms = started_ms };
}

/// What agent_open learned about the launch besides the entry itself.
const LaunchFacts = struct {
    /// The first line the binary's `version_args` printed.
    version: ?[]const u8 = null,
    /// Remote: whether the probe ran in the login environment.
    login: ?bool = null,
    shell: ?[]const u8 = null,
    master: ?@import("../mux/sshmaster.zig").Report = null,
};

/// How long a local `version_args` run may take.
const VERSION_WAIT_MS: i64 = 10_000;

/// The first non-empty line `binary` prints for the adapter's
/// `version_args`, run like the app (the `unset_env` wrapper applied).
fn localVersion(arena: std.mem.Allocator, l: adapter.Launch, binary: []const u8) !?[]const u8 {
    if (l.version_args.len == 0 or state.mux_sock == null) return null;
    const head = [_][]const u8{binary};
    const argv = try launch.withUnsetEnv(arena, l.unset_env, &.{}, try std.mem.concat(arena, []const u8, &.{ &head, l.version_args }));
    switch (try mcp_term.runArgvTerm(arena, argv, VERSION_WAIT_MS)) {
        .err => return null,
        .run => |r| {
            if (!r.exited) return null;
            var lines = std.mem.splitScalar(u8, r.output, '\n');
            while (lines.next()) |line| {
                const v = std.mem.trim(u8, line, " \r\t");
                if (v.len > 0) return v;
            }
            return null;
        },
    }
}

/// agent_open's result: the launch facts, then every per-agent fact.
fn openResult(arena: std.mem.Allocator, e: *Entry, ready: bool, sent: bool, notes: []const []const u8, dv: Delivered, watch: Watch, lf: *const LaunchFacts) ![]const u8 {
    var res = Res.init(arena);
    if (e.host) |h|
        try res.textf("opened {s} ({s}) on {s} over {s} in session {s}", .{ e.id, e.loaded.spec.name, h, @tagName(e.transport), e.session })
    else
        try res.textf("opened {s} ({s}) in session {s}", .{ e.id, e.loaded.spec.name, e.session });
    if (!ready) try res.textf("not ready yet (state {s}); agent_send waits for it", .{@tagName(e.agent.state())});
    if (notes.len > 0) try res.textf("{d} note(s) below", .{notes.len});
    try res.fact("binary", e.binary);
    try res.fact("binary_version", lf.version);
    try res.textf("binary: {s}{s}{s}", .{ e.binary, if (lf.version != null) ", " else "", lf.version orelse "" });
    if (conversationOf(e)) |cv| try res.textf("conversation {s} (agent_open resume takes it after a restart)", .{cv});
    try res.fact("path_prepend", e.extra.path_prepend);
    if (e.host != null) {
        try res.fact("login_shell", lf.login orelse false);
        try res.fact("login_shell_path", lf.shell);
        if (e.extra.login_shell and lf.login == false)
            try res.textf("the login shell ({s}) did not answer in time: the binary was looked up in the plain ssh environment", .{lf.shell orelse "?"});
    }
    if (lf.master) |*m| try mcp_term.masterFacts(&res, m);
    try res.fact("cwd", e.cwd);
    // The values of `env` are never echoed: only what was set.
    const env_names = try e.extra.names(arena);
    try res.fact("args", e.extra.args);
    if (e.extra.server_args.len > 0) try res.fact("server_args", e.extra.server_args);
    if (e.extra.tui_args.len > 0) try res.fact("tui_args", e.extra.tui_args);
    try res.fact("env_names", env_names);
    if (e.extra.permissions.len > 0) {
        try res.raw("permissions", try toJson(arena, try permissionsValue(arena, e.extra.permissions)));
        var aw: std.Io.Writer.Allocating = .init(arena);
        for (e.extra.permissions, 0..) |p, i| try aw.writer.print("{s}{s} {s}", .{ if (i > 0) ", " else "", p.name, @tagName(p.action) });
        try res.textf("permissions: {s}", .{aw.written()});
    }
    if (e.extra.args.len > 0 or env_names.len > 0)
        try res.textf("launched with {d} extra arg(s) and env {s}", .{ e.extra.args.len, if (env_names.len == 0) "(none)" else try std.mem.join(arena, ", ", env_names) });
    if (e.recordings.items.len > 0) try res.fact("recordings", e.recordings.items);
    try res.fact("prompt_sent", sent);
    var extra: std.ArrayList(Block) = .empty;
    try extra.append(arena, .{ .name = "binary", .body = e.binary });
    if (notes.len > 0) try extra.append(arena, .{ .name = "notes", .body = try std.mem.join(arena, "\n", notes) });
    return finish(arena, &res, e, dv, watch, extra.items);
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
        .started_ms = clock.wallMs(),
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
    // Local and plain-ssh sessions live on this host's per-user daemon.
    if (where.transport != .@"sketerm-mux") if (state.user_sock) |s| {
        e.socket = try a.dupe(u8, s);
    };
    if (o.name) |n| e.name = try a.dupe(u8, n);
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
    /// The caller's `env` (the spawn request's environment, or exported by
    /// a plain-ssh start's script), `path_prepend` and `login_shell`.
    extra: launch.Extra = .{},
    /// The session's listed title (the agent's name).
    title: []const u8 = "",
};

/// Start `argv` on the agent's host as session `spec.name`, with the
/// agents' unattached lifetime. Locally (and the local end of a plain-ssh
/// agent) that is this host's per-user daemon; remotely the host's own
/// daemon, the portable one deployed when it has none. A remote start
/// whose transport is not decided yet (`where.transport == .local` with a
/// host) never falls back to plain `ssh -tt`: only `choice` ssh runs it
/// there. The outcome is recorded in `where`.
fn spawnOn(arena: std.mem.Allocator, where: *Where, choice: transport_mod.Choice, argv: []const []const u8, spec: SpawnSpec, why: *Fail) !*termdrive.Term {
    const a = state.allocator;
    const extra_kv = try (launch.Extra{ .env = spec.extra.env }).assignments(arena);
    const login = spec.extra.login_shell;
    const host = where.host orelse {
        if (!try fitsExec(arena, argv, why)) return error.Refused;
        // The per-user daemon may have been started with another
        // environment: the agent gets this server's PATH, as it would here.
        const path_kv = try arena.alloc([]const u8, 1);
        path_kv[0] = try std.fmt.allocPrint(arena, "PATH={s}", .{try launch.prependPath(arena, spec.extra.path_prepend, localHost().path)});
        // null: the per-user daemon, autostarted as itself (an explicit
        // socket would start it as a private instance that retires idle).
        return termdrive.Term.spawnWith(a, argv, where.cols, where.rows, null, .{
            .name = spec.name,
            .env = try std.mem.concat(arena, []const u8, &.{ spec.env, extra_kv, path_kv }),
            .cwd = spec.cwd,
            .shell_integration = false,
            .ttl_secs = state.ttl_secs,
            .title = spec.title,
        }) catch {
            why.* = .{ .code = .unavailable, .msg = "could not start the agent's session on this host's per-user sketerm-mux daemon" };
            return error.Refused;
        };
    };
    const undecided = where.transport == .local;
    if ((undecided and choice != .ssh) or where.transport == .@"sketerm-mux") {
        // The child inherits the remote DAEMON's environment: the login
        // shell's is put back in, and the caller's env values ride the
        // spawn under the relay prefix so no profile overrides them.
        const relay = login and spec.extra.env.len > 0;
        const needs_script = spec.secret_env != null or login or spec.extra.path_prepend.len > 0;
        const margv: []const []const u8 = if (needs_script)
            try arena.dupe([]const u8, &.{ "/bin/sh", "-c", try launch.remoteScript(arena, argv, .{
                .secret_env = spec.secret_env,
                // A profile may change directory; the spawn's cwd comes first.
                .cwd = if (login) spec.cwd else null,
                .login = login,
                .path_prepend = spec.extra.path_prepend,
                .env_relay = if (relay) try spec.extra.names(arena) else &.{},
            }) })
        else
            argv;
        if (!try fitsExec(arena, margv, why)) return error.Refused;
        const spawn_env = if (relay) blk: {
            const out = try arena.alloc([]const u8, spec.extra.env.len);
            for (spec.extra.env, out) |v, *o| o.* = try std.fmt.allocPrint(arena, launch.ENV_RELAY_PREFIX ++ "{s}={s}", .{ v.name, v.value });
            break :blk out;
        } else extra_kv;
        const t = termdrive.Term.spawnRemoteMux(a, host, margv, where.cols, where.rows, .{
            .name = spec.name,
            .cwd = spec.cwd,
            .env = spawn_env,
            .ttl_secs = state.ttl_secs,
            .title = spec.title,
        }) catch {
            // Never a silent plain-ssh agent: it would die with the link.
            why.* = .{ .code = .unavailable, .msg = try noRemoteMux(arena, host) };
            return error.Refused;
        };
        where.transport = .@"sketerm-mux";
        return t;
    }
    // Plain ssh: the script rides the ssh command (base64, dialect-proof)
    // and runs with the terminal on stdin; no secret ever goes in it (the
    // caller's env does: it is documented as no place for secrets).
    const nonce = try randomHex(arena, 6);
    const file = try std.fmt.allocPrint(arena, "/tmp/.sk_ssh_{s}", .{nonce});
    const script = try launch.remoteScript(arena, argv, .{
        .cleanup = file,
        .cwd = spec.cwd,
        .secret_env = spec.secret_env,
        .env = spec.extra.env,
        .login = login,
        .path_prepend = spec.extra.path_prepend,
    });
    var sargv: std.ArrayList([]const u8) = .empty;
    mcp_term.appendSshTt(arena, &sargv, host) catch {
        why.* = .{ .code = .refused, .msg = "cannot build the forced route for this host" };
        return error.Refused;
    };
    try sargv.append(arena, try termdrive.sshScriptCommand(arena, nonce, script));
    if (!try fitsExec(arena, sargv.items, why)) return error.Refused;
    const t = termdrive.Term.spawnWith(a, sargv.items, where.cols, where.rows, null, .{
        .name = spec.name,
        .shell_integration = false,
        .ttl_secs = state.ttl_secs,
        .title = spec.title,
    }) catch {
        why.* = .{ .code = .unavailable, .msg = "could not start the agent's ssh session on this host's per-user sketerm-mux daemon" };
        return error.Refused;
    };
    where.transport = .ssh;
    return t;
}

/// Why no agent could start on `host`'s own daemon, naming what ssh said.
fn noRemoteMux(arena: std.mem.Allocator, host: []const u8) ![]const u8 {
    const said = try sshDiagnose(arena, host);
    if (!deploy.portableAvailable())
        return std.fmt.allocPrint(arena, "no sketerm-mux daemon answered on {s}, and this install has no portable sketerm-mux to deploy there (put sketerm-mux on the remote PATH); transport \"ssh\" runs the agent in a plain ssh session instead, which ends with the connection. ssh: {s}", .{ host, said });
    return std.fmt.allocPrint(arena, "could not start the agent on {s}'s sketerm-mux (the portable daemon is deployed there automatically, and that failed); transport \"ssh\" runs it in a plain ssh session instead, which ends with the connection. ssh: {s}", .{ host, said });
}

/// What a plain `ssh host true` says: its error, or that it connected.
fn sshDiagnose(arena: std.mem.Allocator, host: []const u8) ![]const u8 {
    const argv = mcp_term.remoteShArgv(arena, host, "true") catch return "cannot build the ssh route for this host";
    return switch (try mcp_term.runArgvTerm(arena, argv, PROBE_WAIT_MS)) {
        .err => |m| m,
        .run => |r| if (r.exited and r.status_known and r.status == 0)
            "ssh connected, but no sketerm-mux answered there"
        else if (!r.exited)
            "ssh did not finish connecting in time"
        else
            try std.fmt.allocPrint(arena, "{s}", .{if (r.output.len > 0) mcp.tailLines(r.output, 4) else "ssh failed with no message"}),
    };
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
    const id = o.keep_id orelse try mintId(arena, spec.id);
    const session = try std.fmt.allocPrint(arena, "agent-{s}", .{id});
    // A conversation id the agent owns, so a relaunch resumes exactly it;
    // `resume` continues the caller's existing one instead.
    const conversation: ?[]const u8 = if (o.resume_id) |r| r else if (spec.launch.session_args.len > 0) try newUuid(arena) else null;
    const x = try launch.applyPermissions(arena, spec.launch, o.extra);
    const argv = try launch.startArgv(arena, spec.launch, binary, x, .{
        .model = o.model,
        .effort = o.effort,
        .cwd = o.cwd,
        .session = conversation,
    }, .{ .main = if (o.resume_id != null) .resumed else .fresh });
    const t = try spawnOn(arena, where, o.choice, argv, .{ .name = session, .cwd = o.cwd.?, .extra = x, .title = o.name orelse "" }, why);
    errdefer t.deinit();
    const e = try newEntry(loaded, id, session, binary, o.cwd.?);
    errdefer dropBare(e);
    try setPlace(e, where.*, o);
    if (conversation) |cv| e.conversation = try a.dupe(u8, cv);
    // A resumed conversation has turns: a relaunch must resume it too.
    if (o.resume_id != null) e.conversed = true;
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
fn waitServerReady(arena: std.mem.Allocator, api: *opencode.Api, server: *termdrive.Term, what: []const u8, argv: []const []const u8, deadline: i64, why: *Fail) !void {
    const started = clock.nowMs();
    while (true) {
        server.drain();
        if (server.exited and !server.lost) {
            why.* = .{ .code = .failed, .msg = try exitedEarly(arena, server, what, launch.appArgv(argv)) };
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

/// Why a process exited before it was ready: its status, the argv that
/// ran and the error lines it printed, never the usage text around them.
fn exitedEarly(arena: std.mem.Allocator, t: *termdrive.Term, what: []const u8, argv: []const []const u8) ![]const u8 {
    const text = t.readScreen(true) catch try t.allocator.dupe(u8, "");
    defer t.allocator.free(text);
    const f = try launch.startFailure(arena, text, if (argv.len > 0) argv[0] else "");
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{s} exited", .{what});
    if (t.exit_status_known) try w.print(" with status {d}", .{t.exit_status});
    try w.writeAll(" before it was ready; it ran:");
    for (argv) |a| try w.print(" {s}", .{a});
    if (f.errors.len > 0) {
        try w.writeAll("\nit said:");
        for (f.errors[0..@min(f.errors.len, 12)]) |l| try w.print("\n{s}", .{l});
    } else if (f.usage) {
        try w.writeAll("\nit printed only its usage text, naming no error: it rejected its command line (an argument it does not take; server_args and tui_args target one of its processes)");
    } else try w.writeAll("\nit printed nothing");
    return aw.written();
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

    const id = o.keep_id orelse try mintId(arena, spec.id);
    const session = try std.fmt.allocPrint(arena, "agent-{s}", .{id});
    const server_session = try std.fmt.allocPrint(arena, "agent-{s}-server", .{id});
    const what = try std.fmt.allocPrint(arena, "the {s} server", .{spec.name});
    const x = try launch.applyPermissions(arena, spec.launch, o.extra);
    const server_argv = try launch.startArgv(arena, spec.launch, binary, x, .{
        .port = port_str,
        .cwd = cwd,
        .model = o.model,
        .effort = o.effort,
    }, .{ .main = .fresh });
    const server = try spawnOn(arena, where, o.choice, server_argv, .{ .name = server_session, .cwd = cwd, .env = env, .secret_env = secret_env, .extra = x, .title = o.name orelse "" }, why);
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
    try waitServerReady(arena, api, server, what, server_argv, @min(deadline, clock.nowMs() + PORT_WAIT_MS), why);
    // A conversation to resume must exist, or the caller would be handed
    // a new one under the old id's name.
    if (o.resume_id) |rid| {
        const known = api.sessionExists(rid) catch |err| {
            why.* = .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "could not check that {s} has conversation {s}: {s}", .{ what, rid, if (api.problem().len > 0) api.problem() else @errorName(err) }) };
            return error.Refused;
        };
        if (!known) {
            why.* = .{ .code = .not_found, .msg = try std.fmt.allocPrint(arena, "{s} has no conversation {s}: {s} serve, started in {s} on {s}, answered 404 for GET /session/{s} (it looks in its own storage of that user on that host); nothing was resumed and the server was stopped", .{ what, rid, binary, cwd, where.host orelse "this machine", rid }) };
            return error.Refused;
        }
    }
    api.connect(o.resume_id, clock.nowMs()) catch |err| {
        why.* = .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "the {s} API refused the connection: {s}", .{ spec.name, if (api.problem().len > 0) api.problem() else @errorName(err) }) };
        return error.Refused;
    };
    const sid = api.sessionId() orelse {
        why.* = .{ .code = .failed, .msg = "the app's API created no session" };
        return error.Refused;
    };
    const tui_argv = try launch.startArgv(arena, spec.launch, binary, x, .{
        .port = port_str,
        .cwd = cwd,
        .session = sid,
    }, .attach);
    const tui: ?*termdrive.Term = if (spec.launch.attach_args.len == 0) null else try spawnOn(arena, where, o.choice, tui_argv, .{ .name = session, .cwd = cwd, .env = env, .secret_env = secret_env, .extra = x, .title = o.name orelse "" }, why);
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
    const term_id = argInt(args, "term") orelse return errRes(arena, .invalid_args, "agent_attach needs 'agent' (an agent id or name to resume) or 'term' (a term_open terminal to put an adapter on)");
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
    const id = try mintId(arena, loaded.spec.id);
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
    try res.fact("attach", "adapter");
    try res.fact("term", tid);
    return finish(arena, &res, e, try pending(arena, e), .{}, &.{});
}

// ── acting ───────────────────────────────────────────────────────

/// Why the agent cannot take a prompt or a setting now, or null when it
/// is idle.
fn busy(arena: std.mem.Allocator, e: *Entry) !?Fail {
    const st = e.agent.state();
    if (st.takesPrompt()) return null;
    return switch (st) {
        .idle, .waiting_background => null,
        .starting => Fail{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "agent {s} is not ready yet (state starting); nothing was sent", .{e.id}) },
        .working, .waiting_subagent, .retrying => Fail{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} is busy (state {s}){s}: agent_wait for its turn to finish, or agent_interrupt it", .{ e.id, @tagName(st), if (e.agent.supports(.queue)) "" else try std.fmt.allocPrint(arena, " and the {s} adapter cannot queue a prompt", .{e.loaded.spec.id}) }) },
        .waiting_user => Fail{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} is waiting for an answer: agent_answer its prompt first", .{e.id}) },
        .exited, .disconnected => Fail{ .code = .unavailable, .msg = try std.fmt.allocPrint(arena, "agent {s} is {s}; agent_close it", .{ e.id, @tagName(st) }) },
    };
}

// ── prompts from templates ───────────────────────────────────────

/// A prompt as typed: the caller's text and/or a rendered template.
const Prompt = struct {
    text: []const u8,
    /// The template it was rendered from (results name it, never echo it).
    template: ?[]const u8 = null,
};

fn refuse(why: *Fail, code: mcp.ErrCode, msg: []const u8) error{Refused} {
    why.* = .{ .code = code, .msg = msg };
    return error.Refused;
}

/// A stored template, checked as at save.
/// @throws Refused with `why` set.
fn loadTemplate(arena: std.mem.Allocator, name: []const u8, why: *Fail) !brief.Template {
    if (!mcpassets.validName(name)) return refuse(why, .invalid_args, TEMPLATE_NAME_RULE);
    const bytes = mcpassets.load(arena, .agent_template, name) catch |err| return switch (err) {
        error.NotFound => refuse(why, .not_found, try std.fmt.allocPrint(arena, "no template '{s}' (agent_templates lists them)", .{name})),
        error.OutOfMemory => error.OutOfMemory,
        else => refuse(why, .io_failed, try std.fmt.allocPrint(arena, "cannot read template '{s}': {s}", .{ name, @errorName(err) })),
    };
    var r: brief.Refusal = undefined;
    return (try brief.parseStored(arena, name, bytes, &r)) orelse refuse(why, .failed, r.msg);
}

const TEMPLATE_NAME_RULE = "template names are 1-64 letters, digits, '.', '_' or '-', not starting with '.'";

/// The prompt `args` carry: `key` and/or `template` + `vars` (the caller's
/// text after the rendered template); null when neither is given.
/// @throws Refused with `why` set.
fn promptFrom(arena: std.mem.Allocator, args: std.json.Value, key: []const u8, why: *Fail) !?Prompt {
    const text = argStr(args, key);
    if (text) |x| if (std.mem.trim(u8, x, " \t\r\n").len == 0)
        return refuse(why, .invalid_args, try std.fmt.allocPrint(arena, "{s} is empty", .{key}));
    const name = argStr(args, "template");
    const vars = mcp.argValue(args, "vars");
    if (name == null and vars != null) return refuse(why, .invalid_args, "vars fills a template: pass 'template' with it");
    const tpl: ?brief.Template = if (name) |n| try loadTemplate(arena, n, why) else null;
    if (text == null and tpl == null) return null;
    var body: []const u8 = text orelse "";
    if (tpl) |t| {
        var r: brief.Refusal = undefined;
        const rendered = (try brief.render(arena, t, vars, &r)) orelse return refuse(why, .invalid_args, r.msg);
        body = if (text) |x| try std.mem.concat(arena, u8, &.{ rendered, "\n\n", x }) else rendered;
    }
    return .{ .text = body, .template = name };
}

fn templateSaveTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const name = argStr(args, "name") orelse return errRes(arena, .invalid_args, "agent_template_save needs 'name'");
    if (!mcpassets.validName(name)) return errRes(arena, .invalid_args, TEMPLATE_NAME_RULE);
    const text = argStr(args, "text") orelse return errRes(arena, .invalid_args, "agent_template_save needs 'text'");
    var r: brief.Refusal = undefined;
    const tpl = (try brief.build(arena, name, text, mcp.argValue(args, "vars"), argStr(args, "description"), &r)) orelse
        return errRes(arena, .invalid_args, r.msg);
    const replaced = if (mcpassets.load(arena, .agent_template, name)) |_| true else |_| false;
    mcpassets.save(arena, .agent_template, name, try brief.serialize(arena, tpl)) catch |err|
        return errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "cannot save template '{s}': {s}", .{ name, @errorName(err) }));
    var names: std.ArrayList([]const u8) = .empty;
    for (tpl.vars) |v| try names.append(arena, v.name);
    var res = Res.init(arena);
    try res.textf("{s} template '{s}' (variables: {s}); agent_send or agent_open take it as template", .{ if (replaced) "replaced" else "saved", name, try brief.varNames(arena, tpl.vars) });
    try res.fact("template", name);
    try res.fact("vars", names.items);
    try res.fact("replaced", replaced);
    return res.finish();
}

const TemplateItem = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    vars: []const []const u8,
};

fn templatesTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    var why: Fail = undefined;
    if (argStr(args, "name")) |name| {
        const tpl = loadTemplate(arena, name, &why) catch |err| switch (err) {
            error.Refused => return errRes(arena, why.code, why.msg),
            else => return err,
        };
        var vars: std.json.ObjectMap = .empty;
        for (tpl.vars) |v| try vars.put(arena, v.name, if (v.default) |d| .{ .string = d } else .null);
        var res = Res.init(arena);
        try res.textf("template '{s}': variables {s}", .{ name, try brief.varNames(arena, tpl.vars) });
        try res.fact("name", name);
        if (tpl.description) |d| try res.fact("description", d);
        try res.fact("text", tpl.text);
        try res.raw("vars", try toJson(arena, std.json.Value{ .object = vars }));
        if (tpl.description) |d| try block(&res, .{ .name = "description", .body = d });
        try block(&res, .{ .name = "text", .body = tpl.text });
        return res.finish();
    }
    const names = mcpassets.list(arena, .agent_template) catch |err|
        return errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "cannot list templates: {s}", .{@errorName(err)}));
    var items: std.ArrayList(TemplateItem) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    var res = Res.init(arena);
    for (names) |n| {
        const tpl = loadTemplate(arena, n, &why) catch |err| switch (err) {
            error.Refused => {
                try problems.append(arena, why.msg);
                continue;
            },
            else => return err,
        };
        var vn: std.ArrayList([]const u8) = .empty;
        for (tpl.vars) |v| try vn.append(arena, v.name);
        try items.append(arena, .{ .name = n, .description = tpl.description, .vars = vn.items });
    }
    try res.textf("{d} template(s){s}", .{ items.items.len, if (problems.items.len > 0) " and stored files that do not load (problems)" else "" });
    for (items.items) |it| try res.textf("{s}: variables {s}", .{ it.name, if (it.vars.len == 0) "none" else try std.mem.join(arena, ", ", it.vars) });
    try res.raw("templates", try toJson(arena, items.items));
    try res.fact("count", items.items.len);
    try res.fact("problems", problems.items);
    return res.finish();
}

fn templateDeleteTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const name = argStr(args, "name") orelse return errRes(arena, .invalid_args, "agent_template_delete needs 'name'");
    if (!mcpassets.validName(name)) return errRes(arena, .invalid_args, TEMPLATE_NAME_RULE);
    mcpassets.delete(arena, .agent_template, name) catch |err| return switch (err) {
        error.NotFound => errRes(arena, .not_found, try std.fmt.allocPrint(arena, "no template '{s}' (agent_templates lists them)", .{name})),
        else => errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "cannot delete template '{s}': {s}", .{ name, @errorName(err) })),
    };
    var res = Res.init(arena);
    try res.textf("deleted template '{s}'", .{name});
    try res.fact("template", name);
    try res.fact("deleted", true);
    return res.finish();
}

const Sent = union(enum) { ok: Delivered, fail: Fail };

/// @param no_queue a busy agent is refused instead of queued (agent_send
/// interrupt: it was stopped for this prompt).
fn submitAndWait(arena: std.mem.Allocator, e: *Entry, p: Prompt, filter: events.Filter, deadline: i64, no_queue: bool) !Sent {
    service(clock.nowMs());
    const pre = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena);
    const queued = switch (try submitPrompt(arena, e, p, deadline, no_queue)) {
        .fail => |f| return .{ .fail = f },
        .ok => |q| q,
    };
    var dv = try waitAfter(arena, e, pre, filter, deadline);
    if (dv.wait) |*w| {
        w.sent = true;
        w.queued = queued;
    }
    return .{ .ok = dv };
}

/// Put `text` in as the agent's next prompt, or into its app's queue
/// while it works (unless `no_queue`); `ok` says whether it was queued.
/// The recipe's keys get at least `STEP_WAIT_MS` to land even when the
/// caller does not wait for the turn.
fn submitPrompt(arena: std.mem.Allocator, e: *Entry, p: Prompt, deadline: i64, no_queue: bool) !Submitted {
    const text = p.text;
    // The caller's own prompt starts a new job: a new retry budget.
    if (!state.retry_busy) e.retry.newPrompt();
    _ = waitReady(e, deadline);
    // A busy agent's app queues the prompt for its next turn, when it can.
    const queued = !no_queue and e.agent.state().queuesPrompt() and e.agent.supports(.queue);
    if (queued) {
        if (try queueRefusal(arena, e)) |f| return .{ .fail = f };
    } else if (try busy(arena, e)) |f| return .{ .fail = f };
    const act_deadline = @max(deadline, clock.nowMs() + STEP_WAIT_MS);
    const from = e.agent.queue().next_seq;
    switch (try act(arena, e, if (queued) .{ .queue = text } else .{ .submit = text }, act_deadline)) {
        .fail => |f| return .{ .fail = f },
        .ok => {},
    }
    if (queued) if (try confirmQueued(arena, e, act_deadline)) |f| return .{ .fail = f };
    e.sent_seq = from;
    // The conversation has a turn now: a relaunch resumes it.
    if (!e.conversed) {
        e.conversed = true;
        writeDescriptor(e);
    }
    return .{ .ok = queued };
}

/// What agent_send `interrupt` did to one agent before its prompt.
const Stopped = struct {
    interrupted: bool = false,
    /// Prompts the app held queued that the interrupt discarded.
    queued_dropped: u32 = 0,
    fail: ?Fail = null,
};

/// Whether `interrupt` must stop `e` before a prompt can go in as a new
/// one: it works, or a prompt waits on the user.
fn needsInterrupt(e: *Entry) bool {
    const st = e.agent.state();
    return st.queuesPrompt() or st == .waiting_user;
}

/// agent_send `interrupt`: interrupt every busy one of `list` at once, then
/// wait (bounded, `STEP_WAIT_MS`) until each takes a prompt; one that does
/// not gets a failure, never a prompt queued behind its turn.
fn stopForSend(arena: std.mem.Allocator, list: []const *Entry, out: []Stopped) !void {
    for (list, out) |e, *o| {
        o.* = .{};
        if (!needsInterrupt(e)) continue;
        o.queued_dropped = e.agent.queuedPrompts();
        switch (try act(arena, e, .interrupt, clock.nowMs() + STEP_WAIT_MS)) {
            .fail => |f| o.fail = f,
            .ok => o.interrupted = true,
        }
    }
    const until = clock.nowMs() + STEP_WAIT_MS;
    while (true) {
        service(clock.nowMs());
        var waiting = false;
        for (list, out) |e, o| {
            if (o.interrupted and !e.agent.state().takesPrompt() and !gone(e)) waiting = true;
        }
        if (!waiting or clock.nowMs() >= until) break;
        pump(until - clock.nowMs());
    }
    for (list, out) |e, *o| {
        if (!o.interrupted) continue;
        o.queued_dropped -|= e.agent.queuedPrompts();
        const st = e.agent.state();
        if (!st.takesPrompt()) o.fail = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "agent {s} was interrupted but did not become idle within {d} ms (state {s}); nothing was sent", .{ e.id, STEP_WAIT_MS, @tagName(st) }) };
    }
}

/// Why a prompt cannot be typed into a busy screen app's queue now, or
/// null: the input box must show and be empty (a human may be typing).
fn queueRefusal(arena: std.mem.Allocator, e: *Entry) !?Fail {
    const d = switch (e.agent.driver()) {
        .screen => |d| d,
        .opencode_api => return null,
    };
    service(clock.nowMs());
    if (!d.inputShowing())
        return Fail{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "agent {s} is busy and its input box is not showing; nothing was sent", .{e.id}) };
    if (!d.inputEmpty())
        return Fail{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} is busy and its input box holds text someone is typing; nothing was sent (it would merge with theirs)", .{e.id}) };
    return null;
}

/// A screen app took the queued prompt out of its input box; the failure
/// when it is still there (bounded), saying what the screen shows.
fn confirmQueued(arena: std.mem.Allocator, e: *Entry, deadline: i64) !?Fail {
    const d = switch (e.agent.driver()) {
        .screen => |d| d,
        .opencode_api => return null,
    };
    const until = @min(deadline, clock.nowMs() + STEP_WAIT_MS);
    service(clock.nowMs());
    while (!d.inputEmpty()) {
        if (gone(e) or clock.nowMs() >= until)
            return Fail{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "the app did not take the queued prompt: it is still in the input box; the screen shows:\n{s}", .{try screenTail(arena, e)}) };
        pump(until - clock.nowMs());
    }
    return null;
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
    e.acting += 1;
    defer e.acting -= 1;
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
        error.UnknownModel, error.AmbiguousModel, error.UnknownEffort, error.NoCurrentModel, error.NoSuchOption, error.NoFreeText => .invalid_args,
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
                var nb: [16]u8 = undefined;
                const keys = d.pickKeys(choice, &nb) catch |err| return .{ .fail = try pickFail(arena, e, choice, err) };
                t.sendText(keys) catch return gone_fail;
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
        .submit, .queue, .answer, .answer_text, .interrupt => return .{ .fail = .{ .code = .refused, .msg = "the adapter relaunches for an action that is no launch value" } },
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
    const x = try launch.applyPermissions(arena, e.loaded.spec.launch, e.extra);
    return .{
        .argv = try launch.startArgv(arena, e.loaded.spec.launch, e.binary, x, .{
            .model = model,
            .effort = effort,
            .cwd = e.cwd,
            .session = conversation,
        }, .{ .main = start }),
        .spec = .{ .name = e.session, .cwd = e.cwd, .extra = x, .title = e.name orelse "" },
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
                .submit, .queue, .answer, .answer_text, .interrupt => return,
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

/// agent_send's `text`, or why it is refused.
/// agent_send's prompt: `text` and/or `template`.
fn sendPrompt(arena: std.mem.Allocator, args: std.json.Value, why: *Fail) !Prompt {
    return (try promptFrom(arena, args, "text", why)) orelse refuse(why, .invalid_args, "agent_send needs 'text' or 'template'");
}

fn sendTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    var why: Fail = undefined;
    const text = sendPrompt(arena, args, &why) catch |err| switch (err) {
        error.Refused => return errRes(arena, why.code, why.msg),
        else => return err,
    };
    const filter = filterFrom(args);
    const interrupt = argBool(args, "interrupt");
    var stop = [1]Stopped{.{}};
    if (interrupt) {
        const one = [1]*Entry{e};
        try stopForSend(arena, &one, &stop);
        if (stop[0].fail) |f| return errRes(arena, f.code, f.msg);
    }
    switch (try submitAndWait(arena, e, text, filter, deadlineFrom(args, DEFAULT_WAIT_MS), interrupt)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => |dv| {
            var res = Res.init(arena);
            const queued = if (dv.wait) |w| w.queued else false;
            try res.fact("queued", queued);
            if (interrupt) try res.fact("interrupted", stop[0].interrupted);
            if (stop[0].queued_dropped > 0) try res.fact("queued_dropped", stop[0].queued_dropped);
            if (stop[0].interrupted) try res.textf("{s} was busy: interrupted it first, then sent the prompt as a new one{s}", .{ e.id, if (stop[0].queued_dropped > 0) " (its app dropped the prompts it held queued)" else "" });
            if (queued) try res.textf("{s} was busy: the prompt went into its queue for its next turn", .{e.id});
            return finish(arena, &res, e, dv, .{ .filter = filter, .template = text.template }, &.{});
        },
    }
}

/// One agent's line of a multi-agent agent_send.
const SendResult = struct {
    agent: []const u8,
    name: ?[]const u8 = null,
    /// sent, queued, still_working (`outcomeOf`), or failed.
    outcome: []const u8 = "failed",
    state: ?[]const u8 = null,
    queued: bool = false,
    interrupted: bool = false,
    queued_dropped: ?u32 = null,
    /// Events no result had handed out, taken with the send.
    events: ?[]const EventJson = null,
    @"error": ?struct { code: []const u8, message: []const u8 } = null,
};

/// agent_send with `agents`: the same prompt to each (interrupting the busy
/// ones first with `interrupt`), one result per agent; a failure is that
/// agent's, never the call's. It does not wait for the turns.
fn sendManyTool(arena: std.mem.Allocator, args: std.json.Value, list: []const std.json.Value) ![]const u8 {
    var why: Fail = undefined;
    const text = sendPrompt(arena, args, &why) catch |err| switch (err) {
        error.Refused => return errRes(arena, why.code, why.msg),
        else => return err,
    };
    if (list.len == 0) return errRes(arena, .invalid_args, "agents is empty: name at least one agent");
    if (list.len > MAX_ANY) return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "agents names at most {d} agents", .{MAX_ANY}));
    const interrupt = argBool(args, "interrupt");
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    var results: std.ArrayList(SendResult) = .empty;
    var entries: std.ArrayList(*Entry) = .empty;
    var slots: std.ArrayList(usize) = .empty;
    for (list) |v| {
        if (v != .string) {
            try results.append(arena, .{ .agent = "", .@"error" = .{ .code = @tagName(mcp.ErrCode.invalid_args), .message = "not an agent id or name (a string)" } });
            continue;
        }
        const e = findByName(v.string) orelse {
            try results.append(arena, .{ .agent = v.string, .@"error" = .{ .code = @tagName(mcp.ErrCode.not_found), .message = try std.fmt.allocPrint(arena, "no agent '{s}' on this server (open: {s})", .{ v.string, try idList(arena) }) } });
            continue;
        };
        if (std.mem.indexOfScalar(*Entry, entries.items, e) != null) continue;
        hold(e);
        try entries.append(arena, e);
        try slots.append(arena, results.items.len);
        try results.append(arena, .{ .agent = e.id, .name = e.name });
    }
    for (entries.items) |e| reconnectIfLost(e);
    service(clock.nowMs());
    const stops = try arena.alloc(Stopped, entries.items.len);
    @memset(stops, .{});
    if (interrupt) try stopForSend(arena, entries.items, stops);
    var sent: std.ArrayList([]const u8) = .empty;
    for (entries.items, slots.items, stops) |e, slot, stop| {
        const r = &results.items[slot];
        r.interrupted = stop.interrupted;
        if (stop.queued_dropped > 0) r.queued_dropped = stop.queued_dropped;
        // What no result handed out yet rides with this agent's line.
        if (try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena)) |d| r.events = try eventsJson(arena, d.items);
        const outcome = if (stop.fail) |f| Submitted{ .fail = f } else try submitPrompt(arena, e, text, deadline, interrupt);
        r.state = @tagName(e.agent.state());
        switch (outcome) {
            .fail => |f| r.@"error" = .{ .code = @tagName(f.code), .message = f.msg },
            .ok => |queued| {
                r.queued = queued;
                r.outcome = outcomeOf(&.{}, e.agent.state(), true, queued and e.agent.queuedPrompts() > 0);
                rememberFilter(e, .{});
                try sent.append(arena, e.id);
            },
        }
    }

    var res = Res.init(arena);
    const failed = results.items.len - sent.items.len;
    try res.textf("sent to {d} of {d} agent(s){s}", .{ sent.items.len, results.items.len, if (interrupt) ", the busy ones interrupted first" else "" });
    var ids: std.ArrayList([]const u8) = .empty;
    for (entries.items) |e| try ids.append(arena, e.id);
    try res.fact("agents", ids.items);
    try res.raw("results", try toJson(arena, results.items));
    try res.fact("count", results.items.len);
    try res.fact("failed", failed);
    if (text.template) |x| try res.fact("template", x);
    for (results.items) |r| {
        if (r.@"error") |er|
            try res.textf("{s}: failed ({s}): {s}", .{ if (r.agent.len > 0) r.agent else "?", er.code, er.message })
        else
            try res.textf("{s}: {s}{s}{s}", .{ r.agent, r.outcome, if (r.interrupted) " (interrupted first)" else "", if (r.queued_dropped != null) "; its app dropped the prompts it held queued" else "" });
    }
    var cmd: ?[]const u8 = null;
    if (sent.items.len > 0) if (state.exe) |exe| if (state.waiter.path) |sock| {
        cmd = try agentwait.watchCommand(arena, exe, sock, sent.items, .{}, if (sent.items.len > 1) .all else .any);
        try res.fact("watch_command", cmd.?);
    };
    if (sent.items.len > 0) {
        if (pushing())
            try res.text("their events are pushed into this session as they happen, so end your turn here; no watch_command, Monitor or agent_wait is needed")
        else if (sent.items.len > 1)
            try res.text("run watch_command in the background to be woken ONCE when every one of them has settled (agent-wait --all; --any wakes on the first), then agent_read final per agent")
        else
            try res.text("run watch_command in the background to be woken when it has answered");
    }
    if (cmd) |x| try block(&res, .{ .name = "watch_command", .body = x });
    return res.finish();
}

/// A prompt that went in (queued or not), or why not.
const Submitted = union(enum) { ok: bool, fail: Fail };

/// Delivered events as results list them (`finish`'s `events`).
fn eventsJson(arena: std.mem.Allocator, items: []const events.Item) ![]const EventJson {
    const evs = try arena.alloc(EventJson, items.len);
    for (items, evs) |it, *out| out.* = .{
        .seq = it.event.seq,
        .kind = @tagName(it.kind),
        .text = eventText(it),
        .record = it.event.record,
        .detail = it.event.detail,
        .count = it.event.count,
        .class = if (it.event.class) |cls| @tagName(cls) else null,
        .job = it.event.job,
        .background_tasks = it.event.background_tasks,
    };
    return evs;
}

fn waitTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const filter = filterFrom(args);
    const dv = try waitAfter(arena, e, null, filter, deadlineFrom(args, DEFAULT_WAIT_MS));
    var res = Res.init(arena);
    return finish(arena, &res, e, dv, .{ .filter = filter }, &.{});
}

/// agent_wait with `agents`: the first wake-up of any of them; the result
/// is that agent's (the first listed one's when none woke).
/// agent_wait's `agents`, each once, held; or the refusal.
const Waited = struct { entries: []*Entry, ids: []const []const u8 };

fn waitedOf(arena: std.mem.Allocator, list: []const std.json.Value) !union(enum) { ok: Waited, fail: Fail } {
    if (list.len == 0) return .{ .fail = .{ .code = .invalid_args, .msg = "agents is empty: name at least one agent id" } };
    if (list.len > MAX_ANY) return .{ .fail = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "agents names at most {d} agents", .{MAX_ANY}) } };
    var entries: std.ArrayList(*Entry) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    for (list) |v| {
        if (v != .string) return .{ .fail = .{ .code = .invalid_args, .msg = "agents must be an array of agent ids" } };
        const e = findByName(v.string) orelse
            return .{ .fail = .{ .code = .not_found, .msg = try std.fmt.allocPrint(arena, "no agent '{s}' (open: {s})", .{ v.string, try idList(arena) }) } };
        if (std.mem.indexOfScalar(*Entry, entries.items, e) != null) continue;
        try entries.append(arena, e);
        try ids.append(arena, e.id);
        hold(e);
    }
    for (entries.items) |e| reconnectIfLost(e);
    return .{ .ok = .{ .entries = entries.items, .ids = ids.items } };
}

/// agent_wait `agents` + `all`: wait until every one settled (`settleOf`),
/// then one line each with how it settled, what it delivers marked
/// delivered like a waiter's.
fn waitAllTool(arena: std.mem.Allocator, args: std.json.Value, list: []const std.json.Value) ![]const u8 {
    const w = switch (try waitedOf(arena, list)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => |x| x,
    };
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    service(clock.nowMs());
    var settled: usize = 0;
    while (true) {
        settled = 0;
        for (w.entries) |e| {
            if (settleOf(e) != null) settled += 1;
        }
        if (settled == w.entries.len or clock.nowMs() >= deadline) break;
        pump(deadline - clock.nowMs());
    }
    const Item = struct {
        agent: []const u8,
        name: ?[]const u8,
        outcome: []const u8,
        state: []const u8,
        settled: bool,
        text: []const u8,
        record: ?u64,
        conversation: ?[]const u8,
        events: []const EventJson,
    };
    const items = try arena.alloc(Item, w.entries.len);
    const all = settled == w.entries.len;
    var res = Res.init(arena);
    if (all)
        try res.textf("all {d} agent(s) settled", .{w.entries.len})
    else
        try res.textf("{d} of {d} agent(s) settled when the wait ran out", .{ settled, w.entries.len });
    for (w.entries, items) |e, *o| {
        const st = e.agent.state();
        o.* = .{ .agent = e.id, .name = e.name, .outcome = outcomeOf(&.{}, st, e.sent_seq != null, false), .state = @tagName(st), .settled = false, .text = "", .record = null, .conversation = conversationOf(e), .events = &.{} };
        if (settleOf(e)) |s| {
            const line = settledOf(e, s);
            o.outcome = line.outcome;
            o.text = line.text;
            o.record = line.record;
            o.settled = true;
            if (try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena)) |d| o.events = try eventsJson(arena, d.items);
        }
        try res.textf("{s}: {s}{s}{s}", .{ e.id, o.outcome, if (o.text.len > 0) ": " else "", agentwait.clip(events.firstLine(o.text), 160) });
    }
    try res.fact("agents", w.ids);
    try res.fact("outcome", if (all) @tagName(vocab.WaitOutcome.all_settled) else @tagName(vocab.WaitOutcome.still_working));
    try res.fact("timed_out", !all and !state.no_wait);
    try res.raw("results", try toJson(arena, items));
    if (all) try res.text("agent_read with final: true returns each one's final message whole");
    if (!all and pushing())
        try res.text("their events are pushed into this session as they happen, so end your turn here")
    else if (!all)
        try res.text("run watch_command in the background to be woken once every one of them has settled");
    if (state.exe) |exe| if (state.waiter.path) |sock| {
        const cmd = try agentwait.watchCommand(arena, exe, sock, w.ids, .{}, .all);
        try res.fact("watch_command", cmd);
        try block(&res, .{ .name = "watch_command", .body = cmd });
    };
    return res.finish();
}

fn waitAnyTool(arena: std.mem.Allocator, args: std.json.Value, list: []const std.json.Value) ![]const u8 {
    const w = switch (try waitedOf(arena, list)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => |x| x,
    };
    const entries = w.entries;
    const ids = w.ids;
    const filter = filterFrom(args);
    const got = try waitAny(entries, filter, deadlineFrom(args, DEFAULT_WAIT_MS), arena);
    const e = if (got) |g| g.entry else entries[0];
    const dv = try combine(arena, null, if (got) |g| g.delivery else null, true, got == null and !gone(e));
    var res = Res.init(arena);
    try res.fact("agents", ids);
    if (got != null) try res.textf("{s} woke first of {d} agent(s)", .{ e.id, ids.len });
    return finish(arena, &res, e, dv, .{ .filter = filter, .any = ids }, &.{});
}

fn answerTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    if (argStr(args, "text")) |text| {
        if (argStr(args, "choice") != null) return errRes(arena, .invalid_args, "pass either 'choice' or 'text', not both");
        return answerTextTool(arena, args, e, text);
    }
    const choice = argStr(args, "choice") orelse return errRes(arena, .invalid_args, "agent_answer needs 'choice' (an option label, its 1-based number or a unique part of a label) or 'text' (a free-text answer)");
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
    // A prompt before the app is ready (Claude Code's trust dialog): the
    // answer leads to the app getting ready, not to a turn.
    const startup = !e.agent.ready();
    const from = e.agent.queue().next_seq;
    switch (try act(arena, e, .{ .answer = choice }, deadline)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => {},
    }
    // The turn goes on: it has not settled until something after this does.
    if (!startup) e.sent_seq = from;
    if (startup) {
        const ready = waitReady(e, deadline);
        var res = Res.init(arena);
        try res.textf("answered the {s} prompt{s}", .{ @tagName(kind), if (ready) "; the agent is ready" else "" });
        try res.fact("answered", label);
        return finish(arena, &res, e, try combine(arena, pre, try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena), false, false), .{ .filter = filter }, &.{.{ .name = "answer", .body = try std.fmt.allocPrint(arena, "{s}\n-> {s}", .{ title, label }) }});
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
    return finish(arena, &res, e, dv, .{ .filter = filter }, &.{.{ .name = "answer", .body = answer }});
}

/// agent_answer `text`: a free-text answer through the route the app
/// offers (Claude Code: the option `screen.text_options` names, then the
/// text as its next prompt; opencode: a reject's message, a custom answer).
fn answerTextTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry, text: []const u8) ![]const u8 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return errRes(arena, .invalid_args, "text is empty");
    const filter = filterFrom(args);
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    const pre = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena);
    const it = e.agent.interaction() orelse
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} has no pending prompt (state {s})", .{ e.id, @tagName(e.agent.state()) }));
    // Never a silent pick: no route for text means the caller chooses.
    if (!it.free_text or !e.agent.supports(.answer_text))
        return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "this {s} prompt takes no free-text answer; answer with choice, one of: {s}", .{ @tagName(it.kind), try optionList(arena, it) }));
    const kind = it.kind;
    const title = try arena.dupe(u8, it.title);
    const label: []const u8 = switch (e.agent.driver()) {
        .screen => |d| try arena.dupe(u8, d.textOption() orelse
            return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "this {s} prompt takes no free-text answer; answer with choice, one of: {s}", .{ @tagName(kind), try optionList(arena, it) }))),
        .opencode_api => if (kind == .permission) opencode.PermissionReply.reject.label() else "free text",
    };
    switch (try act(arena, e, .{ .answer_text = .{ .option = label, .text = text } }, deadline)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => {},
    }
    // After the recipe: the turn the option ended settled inside it.
    e.sent_seq = e.agent.queue().next_seq;
    // What the recipe's own steps caused (the turn the option ended going
    // idle) rides along; the wait is for what the text brings.
    const mid = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena);
    switch (e.agent.source) {
        .screen => |*eng| {
            if (kind == .permission) try eng.addNotice(try std.fmt.allocPrint(arena, "permission \"{s}\" answered: {s}, with a message", .{ title, label }));
            if (!e.conversed) {
                e.conversed = true;
                writeDescriptor(e);
            }
        },
        .opencode_api => {},
    }
    const dv = try waitAfter(arena, e, try joinDeliveries(arena, pre, mid), filter, deadline);
    var res = Res.init(arena);
    try res.textf("answered the {s} prompt with text", .{@tagName(kind)});
    try res.fact("answered", label);
    try res.fact("free_text", true);
    const answer = try std.fmt.allocPrint(arena, "{s}\n-> {s}: {s}", .{ title, label, text });
    return finish(arena, &res, e, dv, .{ .filter = filter }, &.{.{ .name = "answer", .body = answer }});
}

/// Two deliveries as one (oldest first), digests added.
fn joinDeliveries(arena: std.mem.Allocator, a: ?events.Delivery, b: ?events.Delivery) !?events.Delivery {
    const x = a orelse return b;
    const y = b orelse return a;
    const items = try std.mem.concat(arena, events.Item, &.{ x.items, y.items });
    var digest = x.digest;
    if (y.digest) |d| digest = if (digest) |old| .{ .count = old.count + d.count, .latest_seq = d.latest_seq } else d;
    return .{ .items = items, .digest = digest };
}

fn setTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const model = argStr(args, "model");
    const effort = argStr(args, "effort");
    const retry_arg = mcp.argValue(args, "retry_on_overload");
    if (model == null and effort == null and retry_arg == null) return errRes(arena, .invalid_args, "agent_set needs 'model', 'effort' and/or 'retry_on_overload'");
    inline for (.{ "model", "effort" }) |key| {
        if (argStr(args, key)) |v| if (!launch.validValue(v)) return errRes(arena, .invalid_args, key ++ " must be 1-256 printable characters");
    }
    // Refused before anything is typed, stopped or restarted.
    if (effort) |x| if (!launch.validEffort(e.loaded.spec.launch, x)) return errRes(arena, .invalid_args, try effortRefusal(arena, e.loaded));
    if (retry_arg) |v| {
        var why: Fail = undefined;
        const p = retryPolicyFrom(arena, v, &why) catch |err| switch (err) {
            error.Refused => return errRes(arena, why.code, why.msg),
            else => return err,
        };
        setRetryPolicy(e, p);
        writeDescriptor(e);
        service(clock.nowMs());
        if (model == null and effort == null) {
            var res = Res.init(arena);
            if (p) |x|
                try res.textf("{s}: retry_on_overload on: up to {d} retr{s} per job, the first after {d} s, doubling", .{ e.id, x.max, if (x.max == 1) "y" else "ies", x.backoff_s })
            else
                try res.textf("{s}: retry_on_overload off", .{e.id});
            try res.fact("relaunched", false);
            return finish(arena, &res, e, try pending(arena, e), .{}, &.{});
        }
    }
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
    service(clock.nowMs());
    // An interrupted turn is not continued behind the caller's back.
    e.retry.newPrompt();
    const queued_before = e.agent.queuedPrompts();
    switch (try act(arena, e, .interrupt, deadlineFrom(args, DEFAULT_WAIT_MS))) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => {},
    }
    pumpFor(INTERRUPT_SETTLE_MS);
    // Claude Code's Escape throws its queue away with the turn: say so,
    // never leave the caller believing those prompts still wait.
    const dropped = queued_before -| e.agent.queuedPrompts();
    var res = Res.init(arena);
    try res.textf("{s}: interrupted", .{e.id});
    if (dropped > 0) try res.textf("{d} queued prompt(s) were dropped by the interrupt (the app discards its queue with the turn): agent_send them again", .{dropped});
    try res.fact("interrupted", true);
    try res.fact("queued_dropped", dropped);
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
    if (sel.jobs_pending > 0) try res.fact("jobs_pending", sel.jobs_pending);

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
        // What was handed out before is never repeated: one pointer.
        if (s.earlier) |x| {
            try w.print("\nearlier in job {d}: [{d}] {s}, ", .{ s.job, x.id, @tagName(x.kind) });
            if (x.chars >= 1000) try w.print("{d}.{d}k chars", .{ x.chars / 1000, x.chars % 1000 / 100 }) else try w.print("{d} chars", .{x.chars});
            try w.writeAll(", returned before");
            if (s.returned_before > 1) try w.print(" (with {d} more)", .{s.returned_before - 1});
        }
    }
    if (sel.cut.len > 0) {
        try w.print("\n{d} selected record(s) left out by the {d}-character cap, ids", .{ sel.cut.len, select.READ_CAP_CHARS });
        for (sel.cut) |id| try w.print(" {d}", .{id});
        try w.writeAll(": the next agent_read returns them");
    }
    if (sel.jobs_pending > 0)
        try w.print("\n{d} more job(s) with new records the cap kept out entirely: the next agent_read returns them", .{sel.jobs_pending});
    return aw.written();
}

fn readTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const detail = if (argStr(args, "detail")) |d|
        std.meta.stringToEnum(select.Detail, d) orelse return errRes(arena, .invalid_args, "detail must be selected or all")
    else
        select.Detail.selected;
    const explicit = argInt(args, "since");
    // Only the newest job's last assistant message.
    const final = argBool(args, "final");
    if (final and detail == .all) return errRes(arena, .invalid_args, "final returns one message: it does not combine with detail \"all\"");
    const limit: usize = @intCast(std.math.clamp(argInt(args, "limit") orelse READ_DEFAULT, 1, READ_MAX));
    const recs = e.agent.records();
    // The default read: every job, minus what was handed out before. An
    // explicit `since` or `all` is a deliberate re-read of what it names.
    const delivery = detail == .selected and explicit == null;
    const base: u64 = if (explicit) |s| @intCast(@max(s, 0)) else if (delivery) 0 else e.read_cursor;
    const after = try select.jobsAfter(arena, recs, base);
    const jobs = if (final and after.len > 0) after[after.len - 1 ..] else after;
    const sel = try select.select(arena, recs, jobs, .{
        .detail = detail,
        .include_tools = argBool(args, "include_tools"),
        .limit = limit,
        .since = base,
        .handed = if (delivery) &e.handed else null,
        // A final read names its job even with nothing new, to point at it.
        .keep_empty = final,
        .final_only = final,
    });
    try e.handed.markSelection(e.allocator, recs, sel);
    var high = base;
    for (recs) |r| high = @max(high, r.id);
    // A paged `all` read goes on after its last record; any other covers everything.
    const next: u64 = if (sel.more) recs[sel.picked[sel.picked.len - 1]].id else high;
    // Only `all` pages; the default read's delivery is per record.
    if (detail == .all) e.read_cursor = @max(e.read_cursor, next);

    var res = Res.init(arena);
    const body = try writeSelection(arena, &res, recs, sel);
    if (final) try res.fact("final", true);
    if (recs.len == 0)
        try res.text("no records yet")
    else if (final and sel.jobs.len > 0) {
        const j = sel.jobs[0];
        if (sel.picked.len > 0)
            try res.textf("job {d}'s final message [{d}]; next_since {d}", .{ j.job, recs[sel.picked[0]].id, next })
        else if (j.earlier) |x|
            try res.textf("job {d}'s final message [{d}] was returned before (final with since 0 re-reads it)", .{ j.job, x.id })
        else
            try res.textf("job {d} has no assistant message yet (state {s})", .{ j.job, @tagName(e.agent.state()) });
    } else if (sel.jobs.len == 0)
        try res.textf("nothing new since the last read; next_since {d}", .{next})
    else
        try res.textf("{d} record(s) of job(s) {d}-{d}; next_since {d}{s}", .{
            sel.picked.len,
            sel.jobs[0].job,
            sel.jobs[sel.jobs.len - 1].job,
            next,
            if (sel.more) " (more follow)" else "",
        });
    try res.fact("detail", @tagName(detail));
    try res.fact("next_since", next);
    try res.fact("more", sel.more);
    const blocks = [1]Block{.{ .name = "records", .body = body }};
    return finish(arena, &res, e, try pending(arena, e), .{}, blocks[0..@intFromBool(sel.jobs.len > 0)]);
}

fn listTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    service(clock.nowMs());
    if (!argBool(args, "detail")) return listCompact(arena);
    const Item = struct {
        agent: []const u8,
        name: ?[]const u8,
        app: []const u8,
        source: []const u8,
        state: []const u8,
        ready: bool,
        /// The SSH host; null = this machine.
        host: ?[]const u8,
        transport: []const u8,
        cwd: []const u8,
        binary: []const u8,
        model: ?[]const u8,
        effort: ?[]const u8,
        session: []const u8,
        server_session: ?[]const u8,
        sessions: []const []const u8,
        started_ms: i64,
        last_activity_ms: ?i64,
        pending_events: usize,
        waiting_on_user: bool,
        queued_prompts: u32,
        conversation: ?[]const u8,
        recordings: []const []const u8,
        permissions: ?std.json.Value,
        retry_on_overload: ?retry_mod.Policy,
        relaunchable: ?bool,
        gone_reason: ?[]const u8,
    };
    const items = try arena.alloc(Item, state.entries.items.len);
    var res = Res.init(arena);
    try res.textf("{d} agent(s)", .{items.len});
    const wall = clock.wallMs();
    const mono = clock.nowMs();
    for (state.entries.items, items) |e, *out| {
        var model: ?[]const u8 = e.picked_model orelse e.launch_model;
        var effort: ?[]const u8 = e.launch_effort;
        switch (e.agent.source) {
            .opencode_api => |*api| {
                if (api.currentModel()) |m| model = try std.fmt.allocPrint(arena, "{s}/{s}", .{ m.provider, m.model });
                effort = api.currentEffort();
            },
            .screen => {},
        }
        var sessions: std.ArrayList([]const u8) = .empty;
        try sessions.append(arena, e.session);
        if (e.server_session) |s| try sessions.append(arena, s);
        const act_ms = e.agent.lastActivityMs();
        out.* = .{
            .agent = e.id,
            .name = e.name,
            .app = e.loaded.spec.id,
            .source = @tagName(e.agent.kind()),
            .state = @tagName(e.agent.state()),
            .ready = e.agent.ready(),
            .host = e.host,
            .transport = @tagName(e.transport),
            .cwd = e.cwd,
            .binary = e.binary,
            .model = model,
            .effort = effort,
            .session = e.session,
            .server_session = e.server_session,
            .sessions = sessions.items,
            .started_ms = e.started_ms,
            .last_activity_ms = if (act_ms > 0) wall - @max(0, mono - act_ms) else null,
            .pending_events = e.agent.queue().undelivered(),
            .waiting_on_user = e.agent.interaction() != null,
            .queued_prompts = e.agent.queuedPrompts(),
            .conversation = conversationOf(e),
            .recordings = e.recordings.items,
            .permissions = if (e.extra.permissions.len > 0) try permissionsValue(arena, e.extra.permissions) else null,
            .retry_on_overload = e.retry.policy,
            .relaunchable = relaunchableOf(e),
            .gone_reason = if (e.gone_why) |g| g.reasonName() else null,
        };
        try res.textf("{s} ({s}{s}{s}): {s} on {s} in {s}, up {d}s, active {s} ago, {d} undelivered event(s)", .{
            out.agent,                         out.app,                    if (model != null) ", " else "",                          model orelse "",
            out.state,                         e.host orelse "this machine", out.cwd,                                                   @divTrunc(@max(0, wall - e.started_ms), 1000),
            if (out.last_activity_ms) |x| try std.fmt.allocPrint(arena, "{d}s", .{@divTrunc(@max(0, wall - x), 1000)}) else "never", out.pending_events,
        });
    }
    try res.raw("agents", try toJson(arena, items));
    try res.fact("count", items.len);
    try res.fact("detail", true);
    return res.finish();
}

/// agent_list's default: what an orchestrator of many agents scans each
/// turn (with 17 agents the full facts cost ~5k tokens), one line each.
fn listCompact(arena: std.mem.Allocator) ![]const u8 {
    const Pending = struct { kind: []const u8, title: []const u8 };
    const Item = struct {
        agent: []const u8,
        name: ?[]const u8,
        app: []const u8,
        state: []const u8,
        /// The SSH host, or "local".
        host: []const u8,
        cwd: []const u8,
        /// Seconds since the app last drew or sent anything.
        idle_s: ?i64,
        queued: u32,
        pending: ?Pending,
        conversation: ?[]const u8,
        relaunchable: ?bool,
        gone_reason: ?[]const u8,
    };
    const items = try arena.alloc(Item, state.entries.items.len);
    var res = Res.init(arena);
    try res.textf("{d} agent(s)", .{items.len});
    const mono = clock.nowMs();
    for (state.entries.items, items) |e, *out| {
        const act_ms = e.agent.lastActivityMs();
        const it = e.agent.interaction();
        out.* = .{
            .agent = e.id,
            .name = e.name,
            .app = e.loaded.spec.id,
            .state = @tagName(e.agent.state()),
            .host = e.host orelse "local",
            .cwd = e.cwd,
            .idle_s = if (act_ms > 0) @divTrunc(@max(0, mono - act_ms), 1000) else null,
            .queued = e.agent.queuedPrompts(),
            .pending = if (it) |x| .{ .kind = @tagName(x.kind), .title = x.title } else null,
            .conversation = conversationOf(e),
            .relaunchable = relaunchableOf(e),
            .gone_reason = if (e.gone_why) |g| g.reasonName() else null,
        };
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{s}", .{e.id});
        if (e.name) |n| try w.print(" ({s})", .{n});
        try w.print(" {s} {s} on {s} in {s}", .{ out.app, out.state, out.host, out.cwd });
        if (out.gone_reason) |r| try w.print(" (gone: {s})", .{r});
        if (out.relaunchable) |can| try w.print(", {s}", .{if (can) "relaunchable (agent_attach relaunch: true)" else "not relaunchable"});
        if (out.idle_s) |x| try w.print(", idle {d}s", .{x});
        if (out.queued > 0) try w.print(", {d} queued", .{out.queued});
        if (out.pending) |p| try w.print(", pending {s}: {s}", .{ p.kind, agentwait.clip(events.firstLine(p.title), 80) });
        try res.text(aw.written());
    }
    try res.raw("agents", try toJson(arena, items));
    try res.fact("count", items.len);
    try res.fact("detail", false);
    return res.finish();
}

/// End agent `e` and everything it owns: its sessions, waiters and index
/// entry. `e` is freed.
fn discard(e: *Entry) void {
    endWaitersOf(e.id, "agent closed");
    removeDescriptor(e);
    for (state.entries.items, 0..) |x, i| if (x == e) {
        _ = state.entries.orderedRemove(i);
        break;
    };
    publishAgents();
    e.destroy(true);
}

/// Why `e`, started to resume conversation `id`, has not got it: the
/// adapter's `screen.resume_refused` line on its terminal, or null.
fn resumeRefused(arena: std.mem.Allocator, e: *Entry, id: []const u8) !?[]const u8 {
    const sc = e.loaded.screen orelse return null;
    const m = sc.resume_refused orelse return null;
    const t = e.visibleTerm() orelse return null;
    const text = t.readScreen(true) catch return null;
    defer t.allocator.free(text);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!m.matches(line)) continue;
        return try std.fmt.allocPrint(arena, "{s} has no conversation {s}: {s} {s} {s} said \"{s}\" (it looks among the conversations of its working directory {s}{s}{s}); nothing was resumed and the agent was closed", .{
            e.loaded.spec.name, id, e.binary, e.loaded.spec.launch.resume_args[0], id, line, e.cwd, if (e.host != null) " on " else "", e.host orelse "",
        });
    }
    return null;
}

fn closeTool(arena: std.mem.Allocator, _: std.json.Value, e: *Entry) ![]const u8 {
    const id = try arena.dupe(u8, e.id);
    var sessions: std.ArrayList([]const u8) = .empty;
    if (e.visible) |l| if (l == .owned) try sessions.append(arena, try arena.dupe(u8, e.session));
    if (e.server_session) |s| try sessions.append(arena, try arena.dupe(u8, s));
    discard(e);
    var res = Res.init(arena);
    try res.textf("closed {s}{s}", .{ id, if (sessions.items.len == 0) " (its terminal belongs to term_open and stays)" else "" });
    try res.fact("agent", id);
    try res.fact("closed", true);
    try res.fact("sessions", sessions.items);
    return res.finish();
}

// ── the per-user index: descriptors, ownership and reattach ──────

const Descriptor = agentindex.Descriptor;

/// Legacy durable-instance descriptor path (`<instance>/agents/<id>.<ext>`).
fn legacyPath(arena: std.mem.Allocator, id: []const u8, ext: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/" ++ DESCRIPTOR_DIR ++ "/{s}.{s}", .{ state.dir.?, id, ext });
}

/// Hold a freshly opened agent in the index (its id is new: nobody else
/// can hold it).
fn claimNew(e: *Entry) void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const lp = lockPath(fba.allocator(), e.id) catch return;
    pathz.makeDirs(state.index_dir.?, 0o700) catch return;
    e.claim = agentindex.claim(lp, false) catch null;
}

/// Write `e`'s descriptor (and opencode's password beside it) into the
/// per-user index, where any server can resume it.
fn writeDescriptor(e: *Entry) void {
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
        .started_ms = e.started_ms,
        .gone_ms = e.ended_ms,
    };
    agentindex.write(arena, index_dir, d) catch return;
    e.indexed = true;
}

/// The agent is over: out of the index (descriptor, password, lock) and,
/// for a legacy durable descriptor, out of the instance dir too.
fn removeDescriptor(e: *Entry) void {
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
fn canRelaunch(loaded: *const adapter.Loaded, binary: []const u8, cwd: []const u8, conversed: bool, conversation: ?[]const u8) bool {
    if (binary.len == 0 or cwd.len == 0) return false;
    return switch (loaded.spec.source) {
        .screen => !conversed or (conversation != null and loaded.spec.launch.resume_args.len > 0),
        .opencode_api => true,
    };
}

fn descRelaunchable(d: Descriptor) bool {
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
            agentindex.write(arena, index_dir, kept) catch {};
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
            why.* = .{ .kind = .unreachable_host, .session = name, .msg = try sshDiagnose(arena, host.?) };
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
fn askWhyGone(conn: *muxclient.Conn, arena: std.mem.Allocator, name: []const u8, origin: []const u8) ?tombstones.Reply {
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
            const fname = try forwardName(arena, d.id);
            parts.forward = mcp_term.spawnForwardTermNamed(arena, d.host.?, port, "127.0.0.1", d.remote_port, fname) catch null;
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
fn attachIdTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const key = argStr(args, "agent").?;
    const deadline = deadlineFrom(args, ATTACH_WAIT_MS);
    const relaunch_asked = argBool(args, "relaunch");
    // Already ours: nothing to resume, unless its app ended here and the
    // caller asks to start it again.
    if (findByName(key)) |e| {
        hold(e);
        if (!relaunch_asked or !gone(e))
            return reattachedResult(arena, e, if (relaunch_asked) "already attached and not gone: relaunch only starts an agent whose session ended" else "already attached to this server");
        if (e.ended_ms == 0)
            return errRes(arena, .refused, try std.fmt.allocPrint(arena, "agent {s} ended and cannot be relaunched (no conversation to resume, or it runs on a term_open terminal); agent_open a new one", .{e.id}));
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
    var claimed = agentindex.claim(lp, argBool(args, "takeover")) catch |err| switch (err) {
        error.Held => return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} is in use by another live MCP server; agent_attach with takeover:true takes it over (that server then lets it go)", .{d.id})),
        error.LockFailed => return errRes(arena, .io_failed, "could not lock the agent in the index"),
    };
    var why: AttachWhy = .{};
    const e = reattachOne(arena, d, claimed, &why) catch |err| switch (err) {
        error.SessionGone => {
            if (relaunch_asked and descRelaunchable(d)) return relaunchFrom(arena, args, d, &claimed, lp, &why);
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
fn relaunchFrom(arena: std.mem.Allocator, args: std.json.Value, d: Descriptor, claimed: *agentindex.Claim, lp: []const u8, gone_why: *const AttachWhy) ![]const u8 {
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
        .name = d.name,
        .keep_id = d.id,
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
    try testing.expectEqualStrings("needs_input", outcomeOf(d.items, .waiting_user, false, false));
    try testing.expectEqualStrings("done", outcomeOf(d.items[0..2], .idle, false, false));
    try testing.expectEqualStrings("message", outcomeOf(d.items[0..1], .working, false, false));
    try testing.expectEqualStrings("still_working", outcomeOf(&.{}, .working, false, false));
    try testing.expectEqualStrings("exited", outcomeOf(&.{}, .exited, true, false));
    // A prompt the agent has not started on yet is sent, not working.
    try testing.expectEqualStrings("sent", outcomeOf(&.{}, .idle, true, false));
    try testing.expectEqualStrings("still_working", outcomeOf(&.{}, .working, true, false));
    try testing.expectEqualStrings("still_working", outcomeOf(&.{}, .idle, false, false));
    // A prompt queued behind a busy agent's turn and not taken yet.
    try testing.expectEqualStrings("queued", outcomeOf(&.{}, .working, true, true));
    // Taken: it is the turn now, and a wake-up still outranks it.
    try testing.expectEqualStrings("still_working", outcomeOf(&.{}, .working, true, false));
    try testing.expectEqualStrings("needs_input", outcomeOf(d.items, .waiting_user, true, true));
}

/// A configured instance in a temp dir, torn down by `deinit`.
const ToolRig = struct {
    dir: pathz.TempDir,
    sock_buf: [128]u8 = undefined,
    arena: std.heap.ArenaAllocator,

    fn init(self: *ToolRig) !void {
        self.dir = pathz.TempDir.make("mcp-agent") orelse return error.SkipZigTest;
        const sock = try std.fmt.bufPrint(&self.sock_buf, "{s}/mux.sock", .{self.dir.path()});
        configure(testing.allocator, self.dir.path(), sock, false, null);
        // Never the user's real index or daemon.
        if (state.index_dir) |d| testing.allocator.free(d);
        state.index_dir = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{self.dir.path()});
        if (state.user_sock) |u| testing.allocator.free(u);
        state.user_sock = try std.fmt.allocPrint(testing.allocator, "{s}/user.sock", .{self.dir.path()});
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
    e.conversation = try state.allocator.dupe(u8, "0b5d4c1e-8f7a-4d2b-9c3e-1a2b3c4d5e6f");
    try state.entries.append(state.allocator, e);
    const eng = &ag.source.screen;
    _ = try eng.queue.push(clock.nowMs(), .needs_input, null, "permission: Bash", "1. Yes\n2. No");

    // Listing services the agent first: its terminal id names nothing, so
    // the connection is reported lost; neither event is taken by the list.
    const listed = try mcp.expectToolResultShape(a, "agent_list", try rig.call(.agent_list, "{\"detail\":true}"));
    const item = listed.object.get("structuredContent").?.object.get("agents").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 2), item.get("pending_events").?.integer);
    // The conversation a restarted orchestrator resumes it by.
    try testing.expectEqualStrings(e.conversation.?, item.get("conversation").?.string);

    const read = try mcp.expectToolResultShape(a, "agent_read", try rig.call(.agent_read, "{\"agent\":\"claude-1\"}"));
    const rsc = read.object.get("structuredContent").?.object;
    try testing.expectEqualStrings(e.conversation.?, rsc.get("conversation").?.string);
    // The pending event rode along; the terminal is gone, so the state says so.
    try testing.expectEqual(@as(usize, 2), rsc.get("events").?.array.items.len);
    try testing.expectEqualStrings("disconnected", rsc.get("state").?.string);
    try testing.expect(std.mem.indexOf(u8, rsc.get("watch_command").?.string, "agent-wait") != null);

    // Asked not to wait: running out is no timeout, the outcome says it all.
    const waited = try mcp.expectToolResultShape(a, "agent_wait", try rig.call(.agent_wait, "{\"timeout_ms\":0}"));
    try testing.expect(!waited.object.get("structuredContent").?.object.get("timed_out").?.bool);
    const waited_some = try mcp.expectToolResultShape(a, "agent_wait", try rig.call(.agent_wait, "{\"timeout_ms\":1}"));
    try testing.expect(waited_some.object.get("structuredContent").?.object.get("timed_out").?.bool);
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

    // ONE delivery state: the done the waiter printed went into the same
    // assistant's context, so no agent_* result hands it out again.
    try testing.expectEqual(@as(usize, 0), e.agent.queue().undelivered());
    try testing.expect((try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena_state.allocator())) == null);

    // The same watch command, run again later, waits for what is new: it
    // never re-wakes on an event already delivered (a baked-in cursor went
    // stale). Two waiters armed on one agent: the first delivers, the
    // other keeps waiting.
    const tmpl = (try waiterTemplate(arena_state.allocator())).?;
    try testing.expect(std.mem.indexOf(u8, tmpl, "--since") == null);
    const again = try connectSub("{\"agent\":\"claude-1\"}\n");
    defer _ = c.close(again);
    const twin = try connectSub("{\"agent\":\"claude-1\"}\n");
    defer _ = c.close(twin);
    try testing.expectError(error.Timeout, readLineFor(again, &buf, 400));
    _ = try ag.source.screen.queue.push(clock.nowMs(), .done, null, "second turn", "");
    service(clock.nowMs());
    var woken: usize = 0;
    for ([_]c_int{ again, twin }) |fd| {
        if (readLineFor(fd, &buf, 300)) |line| {
            woken += 1;
            try testing.expect(std.mem.indexOf(u8, line, "second turn") != null);
            try testing.expect(std.mem.indexOf(u8, line, "all done") == null);
        } else |_| {}
    }
    try testing.expectEqual(@as(usize, 1), woken);

    // A tool call on the agent holds its waiters: the call's own result
    // gets what happens meanwhile, never both.
    hold(e);
    _ = try ag.source.screen.queue.push(clock.nowMs(), .needs_input, null, "permission: rm", "");
    service(clock.nowMs());
    try testing.expect((try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena_state.allocator())) != null);
    state.held_len = 0;

    // A follower from seq 0 re-reads everything, delivered or not, then
    // gets the end on close.
    const follow = try connectSub("{\"agent\":\"agent-claude-1\",\"follow\":true,\"since\":0}\n");
    defer _ = c.close(follow);
    const all = try readLine(follow, &buf);
    try testing.expect(std.mem.indexOf(u8, all, "connection_lost") != null);
    try testing.expect(std.mem.indexOf(u8, all, "all done") != null);
    try testing.expect(std.mem.indexOf(u8, all, "second turn") != null);

    _ = try closeTool(arena_state.allocator(), .null, e);
    // The follower re-reads (since 0), so its later wake lines come first.
    var used: usize = 0;
    const deadline = clock.nowMs() + 3000;
    while (std.mem.indexOf(u8, buf[0..used], "agent closed") == null) {
        if (clock.nowMs() > deadline) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = follow, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 50) <= 0) continue;
        const n = c.read(follow, buf[used..].ptr, buf.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    try testing.expect(std.mem.indexOf(u8, buf[0..used], "agent closed") != null);
}

test "an event announcing a record carries its id and a one-line preview, never the text again" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    const set = try adapters();
    const e = try newEntry(set.get("claude").?, "claude-1", "agent-claude-1", "/bin/claude", "/");
    const ag = try state.allocator.create(agent_mod.Agent);
    ag.* = try agent_mod.Agent.initScreen(state.allocator, set.get("claude").?, .{});
    e.agent = ag;
    e.visible = .{ .borrowed = 4242 };
    try state.entries.append(state.allocator, e);
    const long = "first line of a long report\n" ++ "x" ** 3000;
    _ = try ag.source.screen.queue.pushDone(clock.nowMs(), 0, 0, long, 42, null);
    _ = try ag.source.screen.queue.push(clock.nowMs(), .needs_input, null, "permission: rm", "1. Yes");
    const read = try mcp.expectToolResultShape(a, "agent_read", try rig.call(.agent_read, "{}"));
    const sc = read.object.get("structuredContent").?.object;
    var saw_done = false;
    for (sc.get("events").?.array.items) |ev| {
        const kind = ev.object.get("kind").?.string;
        if (!std.mem.eql(u8, kind, "done")) continue;
        saw_done = true;
        try testing.expectEqualStrings("first line of a long report", ev.object.get("text").?.string);
        try testing.expectEqual(@as(i64, 42), ev.object.get("record").?.integer);
    }
    try testing.expect(saw_done);
    // Nothing of the long text anywhere in the result.
    const raw = try std.json.Stringify.valueAlloc(a, read, .{});
    try testing.expect(std.mem.indexOf(u8, raw, "xxxxxxxxxx") == null);
}

test "the waiter --any: the first wake-up of several agents names its agent; a closed one is dropped" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const set = try adapters();
    var ags: [2]*agent_mod.Agent = undefined;
    for ([_][]const u8{ "claude-1", "claude-2" }, 0..) |id, i| {
        const e = try newEntry(set.get("claude").?, id, id, "/bin/claude", "/");
        const ag = try state.allocator.create(agent_mod.Agent);
        ag.* = try agent_mod.Agent.initScreen(state.allocator, set.get("claude").?, .{});
        e.agent = ag;
        e.visible = .{ .borrowed = 4242 };
        try state.entries.append(state.allocator, e);
        ags[i] = ag;
    }
    // The terminals name nothing: take the connection_lost both report.
    service(clock.nowMs());
    for (state.entries.items) |e| _ = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), rig.arena.allocator());

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    try @import("../mux/sockpath.zig").fillSockaddrUn(&addr, state.waiter.path.?);
    try testing.expect(c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0);
    const line = "{\"agent\":\"claude-1\",\"agents\":[\"claude-1\",\"claude-2\"],\"follow\":true}\n";
    _ = c.write(fd, line, line.len);
    var buf: [4096]u8 = undefined;
    try testing.expectError(error.Timeout, readLineFor(fd, &buf, 300));
    _ = try ags[1].source.screen.queue.push(clock.nowMs(), .done, null, "two finished", "");
    const woke = try readLineFor(fd, &buf, 3000);
    try testing.expect(std.mem.indexOf(u8, woke, "\"agent\":\"claude-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, woke, "two finished") != null);
    // Closing one leaves the waiter on the other.
    _ = try closeTool(rig.arena.allocator(), .null, state.entries.items[1]);
    _ = try ags[0].source.screen.queue.push(clock.nowMs(), .done, null, "one finished", "");
    const next = try readLineFor(fd, &buf, 3000);
    try testing.expect(std.mem.indexOf(u8, next, "\"agent\":\"claude-1\"") != null);
    // agent_wait agents: the same first-wins rule, through the tool.
    _ = try ags[0].source.screen.queue.push(clock.nowMs(), .needs_input, null, "permission: x", "");
    const waited = try shaped(rig.arena.allocator(), "agent_wait", try rig.call(.agent_wait, "{\"agents\":[\"claude-1\"],\"timeout_ms\":0}"));
    try testing.expectEqualStrings("claude-1", waited.get("agent").?.string);
    try testing.expectEqual(@as(usize, 1), waited.get("agents").?.array.items.len);
    try expectError(rig.arena.allocator(), "agent_wait", try rig.call(.agent_wait, "{\"agents\":[\"nope-9\"]}"), "not_found");
    try expectError(rig.arena.allocator(), "agent_wait", try rig.call(.agent_wait, "{\"agents\":\"claude-1\"}"), "invalid_args");
}

test "a job block names exactly the jobs it holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("job 2", try jobsName(a, &.{.{ .job = 2 }}));
    try testing.expectEqualStrings("jobs 1-3", try jobsName(a, &.{ .{ .job = 1 }, .{ .job = 2 }, .{ .job = 3 } }));
    try testing.expectEqualStrings("jobs 0, 2", try jobsName(a, &.{ .{ .job = 0 }, .{ .job = 2 } }));
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
    /// A slow turn is under way: the next line is queued behind it.
    slow: bool = false,
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
        if (self.slow) {
            // Typed while working: queued (a preview above the status
            // block), then taken at the turn's end as Claude Code 2.1.287
            // draws it.
            self.slow = false;
            try self.draw(try std.fmt.bufPrint(&buf, erase ++ "you: {s}\r\nctrl+enter to send now\r\n" ++ live, .{line}));
            _ = c.usleep(300_000);
            try self.draw("\x1b]133;C\x07\x1b]133;D\x07\x07" ++ APP_IDLE);
            try self.draw(try std.fmt.bufPrint(&buf, "\x1b[2K\x1b[1A" ** 5 ++ "\x1b[2K\x1b[G" ++ "Churned for 2s \xc2\xb7 done\r\nyou: {s}\r\n" ++ live ++ "\x1b]133;A\x07" ++ APP_BUSY, .{line}));
            try self.draw(try std.fmt.bufPrint(&buf, erase ++ "claude: echo: {s}\r\n" ++ live, .{line}));
            return self.draw(APP_END);
        }
        if (std.mem.eql(u8, line, "2")) {
            try self.draw("\r\x1b[5A\x1b[Jclaude: permission answered No\r\n" ++ live);
            return self.draw(APP_END);
        }
        if (std.mem.eql(u8, line, "/model")) return self.draw("\x1b]133;A\x07" ++ erase ++ "you: /model\r\n" ++ MODEL_PICKER);
        try self.draw(try std.fmt.bufPrint(&buf, "\x1b]133;A\x07" ++ APP_BUSY ++ erase ++ "you: {s}\r\n" ++ live, .{line}));
        if (std.mem.indexOf(u8, line, "permission") != null) return self.draw(APP_PERMISSION);
        if (std.mem.indexOf(u8, line, "slow") != null) {
            self.slow = true;
            return self.draw(erase ++ "claude: started the slow one\r\n" ++ live);
        }
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
    // A machine-unique id: the app, then four random characters.
    try testing.expect(std.mem.startsWith(u8, attached.get("agent").?.string, "claude-"));
    try testing.expectEqual(@as(usize, "claude-".len + agentindex.ID_CHARS), attached.get("agent").?.string.len);
    try testing.expectEqualStrings("adapter", attached.get("attach").?.string);

    const sent = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"hello\",\"timeout_ms\":10000}"));
    try testing.expectEqualStrings("done", sent.get("outcome").?.string);
    try testing.expectEqualStrings("echo: hello", sent.get("message").?.string);
    // The done carries its job's selection: the answer, never the prompt.
    const sent_recs = sent.get("records").?.array.items;
    try testing.expectEqual(@as(usize, 1), sent_recs.len);
    try testing.expectEqualStrings("echo: hello", sent_recs[0].object.get("text").?.string);
    try testing.expectEqual(@as(i64, 0), sent.get("jobs").?.array.items[0].object.get("job").?.integer);

    // The done result handed the answer out: a read right after has
    // nothing new (it used to repeat the job), and says so.
    const read = try shaped(a, "agent_read", try rig.call(.agent_read, "{}"));
    try testing.expectEqual(@as(usize, 0), read.get("records").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), read.get("jobs").?.array.items.len);
    try testing.expectEqualStrings("selected", read.get("detail").?.string);
    // A deliberate re-read returns it: an explicit since, or detail all.
    const again = try shaped(a, "agent_read", try rig.call(.agent_read, "{\"since\":0}"));
    const again_recs = again.get("records").?.array.items;
    try testing.expectEqual(@as(usize, 1), again_recs.len);
    try testing.expectEqualStrings("assistant", again_recs[0].object.get("kind").?.string);
    try testing.expectEqual(read.get("next_since").?.integer, again.get("next_since").?.integer);
    const all = try shaped(a, "agent_read", try rig.call(.agent_read, "{\"detail\":\"all\",\"include_tools\":true,\"since\":0}"));
    try testing.expectEqual(@as(usize, 1), all.get("records").?.array.items.len);
    try expectError(a, "agent_read", try rig.call(.agent_read, "{\"detail\":\"everything\"}"), "invalid_args");

    const asked = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"please ask permission\",\"timeout_ms\":10000}"));
    try testing.expectEqualStrings("needs_input", asked.get("outcome").?.string);
    try testing.expectEqualStrings("permission", asked.get("interaction").?.object.get("kind").?.string);
    // An agent waiting for an answer refuses a prompt: its keys would answer it.
    try expectError(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"again\"}"), "conflict");
    try expectError(a, "agent_answer", try rig.call(.agent_answer, "{\"choice\":\"Maybe\"}"), "invalid_args");
    try testing.expect(asked.get("interaction").?.object.get("free_text").?.bool);
    try expectError(a, "agent_answer", try rig.call(.agent_answer, "{\"choice\":\"no\",\"text\":\"x\"}"), "invalid_args");
    // A free-text answer: No, then the text as the next prompt. The wait is
    // for the text's turn; the refused job's done rides along.
    const texted = try shaped(a, "agent_answer", try rig.call(.agent_answer, "{\"text\":\"do it differently\",\"timeout_ms\":10000}"));
    try testing.expectEqualStrings("No", texted.get("answered").?.string);
    try testing.expect(texted.get("free_text").?.bool);
    try testing.expectEqualStrings("done", texted.get("outcome").?.string);
    try testing.expectEqualStrings("echo: do it differently", texted.get("message").?.string);
    try expectError(a, "agent_answer", try rig.call(.agent_answer, "{\"text\":\"nothing asked\"}"), "conflict");

    const asked2 = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"please ask permission again\",\"timeout_ms\":10000}"));
    try testing.expectEqualStrings("needs_input", asked2.get("outcome").?.string);

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

    // A prompt sent while the agent works goes into the app's queue; the
    // wait is for its turn, and the turn it waited behind is not lost.
    const slow = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"a slow one\",\"timeout_ms\":300}"));
    // The recipe outlasts the 300 ms: the call may return before it saw the turn start.
    const slow_outcome = slow.get("outcome").?.string;
    try testing.expect(std.mem.eql(u8, slow_outcome, "still_working") or std.mem.eql(u8, slow_outcome, "sent"));
    try testing.expect(!slow.get("queued").?.bool);
    var polls: usize = 0;
    while (polls < 50) : (polls += 1) {
        const l = try shaped(a, "agent_list", try rig.call(.agent_list, "{}"));
        if (std.mem.eql(u8, l.get("agents").?.array.items[0].object.get("state").?.string, "working")) break;
        _ = c.usleep(50_000);
    }
    const queued = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"queued one\",\"timeout_ms\":10000}"));
    try testing.expect(queued.get("queued").?.bool);
    try testing.expectEqualStrings("done", queued.get("outcome").?.string);
    try testing.expectEqualStrings("echo: queued one", queued.get("message").?.string);
    const q_recs = queued.get("records").?.array.items;
    try testing.expectEqual(@as(usize, 2), q_recs.len);
    try testing.expectEqualStrings("started the slow one", q_recs[0].object.get("text").?.string);
    try testing.expectEqualStrings("echo: queued one", q_recs[1].object.get("text").?.string);
    try testing.expectEqual(@as(usize, 2), queued.get("jobs").?.array.items.len);
    // Effort only takes at launch; a term_open terminal cannot be relaunched.
    try expectError(a, "agent_set", try rig.call(.agent_set, "{\"effort\":\"high\"}"), "refused");
    try expectError(a, "agent_set", try rig.call(.agent_set, "{\"effort\":\"turbo\"}"), "invalid_args");
    const stopped = try shaped(a, "agent_interrupt", try rig.call(.agent_interrupt, "{}"));
    try testing.expect(stopped.get("interrupted").?.bool);
    _ = try shaped(a, "agent_wait", try rig.call(.agent_wait, "{\"timeout_ms\":300}"));
    const listed = try shaped(a, "agent_list", try rig.call(.agent_list, "{\"detail\":true}"));
    try testing.expectEqual(@as(i64, 1), listed.get("count").?.integer);
    try testing.expect(listed.get("detail").?.bool);
    const item = listed.get("agents").?.array.items[0].object;
    try testing.expectEqualStrings("fake-claude", item.get("sessions").?.array.items[0].string);
    try testing.expect(item.get("started_ms").?.integer > 0);
    try testing.expect(item.get("last_activity_ms").?.integer >= item.get("started_ms").?.integer - 1000);
    try testing.expectEqual(@as(i64, 0), item.get("queued_prompts").?.integer);
    // The default list: the compact facts only.
    const compact = try shaped(a, "agent_list", try rig.call(.agent_list, "{}"));
    try testing.expect(!compact.get("detail").?.bool);
    const citem = compact.get("agents").?.array.items[0].object;
    try testing.expectEqualStrings("local", citem.get("host").?.string);
    try testing.expectEqual(@as(i64, 0), citem.get("queued").?.integer);
    try testing.expect(citem.get("idle_s").?.integer >= 0);
    try testing.expect(citem.get("sessions") == null and citem.get("recordings") == null and citem.get("pending") == null);

    // final: the newest job's last message, under the handed-out state.
    const fin = try shaped(a, "agent_read", try rig.call(.agent_read, "{\"final\":true}"));
    try testing.expect(fin.get("final").?.bool);
    try testing.expectEqual(@as(usize, 0), fin.get("records").?.array.items.len);
    try testing.expect(fin.get("jobs").?.array.items[0].object.get("earlier") != null);
    const fin_since = try shaped(a, "agent_read", try rig.call(.agent_read, "{\"final\":true,\"since\":0}"));
    try testing.expectEqual(@as(usize, 1), fin_since.get("records").?.array.items.len);
    try testing.expectEqualStrings("echo: queued one", fin_since.get("records").?.array.items[0].object.get("text").?.string);
    try expectError(a, "agent_read", try rig.call(.agent_read, "{\"final\":true,\"detail\":\"all\"}"), "invalid_args");

    // One text to several (an unknown one fails alone), then a wait for all.
    const id = try a.dupe(u8, attached.get("agent").?.string);
    const many = try shaped(a, "agent_send", try rig.call(.agent_send, try std.fmt.allocPrint(a, "{{\"agents\":[\"{s}\",\"nope-zz\"],\"text\":\"fanned\",\"interrupt\":true,\"timeout_ms\":10000}}", .{id})));
    const mr = many.get("results").?.array.items;
    try testing.expectEqual(@as(usize, 2), mr.len);
    try testing.expectEqual(@as(i64, 1), many.get("failed").?.integer);
    try testing.expect(!mr[0].object.get("interrupted").?.bool);
    try testing.expect(mr[0].object.get("error") == null);
    try testing.expectEqualStrings("not_found", mr[1].object.get("error").?.object.get("code").?.string);
    try expectError(a, "agent_send", try rig.call(.agent_send, try std.fmt.allocPrint(a, "{{\"agent\":\"{s}\",\"agents\":[\"{s}\"],\"text\":\"x\"}}", .{ id, id })), "invalid_args");
    const all_done = try shaped(a, "agent_wait", try rig.call(.agent_wait, try std.fmt.allocPrint(a, "{{\"agents\":[\"{s}\"],\"all\":true,\"timeout_ms\":10000}}", .{id})));
    try testing.expectEqualStrings("all_settled", all_done.get("outcome").?.string);
    try testing.expect(!all_done.get("timed_out").?.bool);
    const ar = all_done.get("results").?.array.items[0].object;
    try testing.expectEqualStrings("done", ar.get("outcome").?.string);
    try testing.expectEqualStrings("echo: fanned", ar.get("text").?.string);
    try testing.expect(std.mem.indexOf(u8, all_done.get("watch_command").?.string, " --all ") != null);
    // It marked no record: final returns the answer.
    const fin2 = try shaped(a, "agent_read", try rig.call(.agent_read, "{\"final\":true}"));
    try testing.expectEqualStrings("echo: fanned", fin2.get("records").?.array.items[0].object.get("text").?.string);
    try expectError(a, "agent_wait", try rig.call(.agent_wait, "{\"agents\":[\"nope-zz\"],\"all\":true}"), "not_found");
    try expectError(a, "agent_wait", try rig.call(.agent_wait, "{\"all\":true}"), "invalid_args");

    // agent_open's own facts around the same per-agent ones.
    const e = state.entries.items[0];
    const dv = try combine(a, null, null, true, true);
    const opened = try shaped(a, "agent_open", try openResult(a, e, true, false, &.{"a note"}, dv, .{ .filter = .{ .match = "x" } }, &.{ .version = "9.9 (x)" }));
    try testing.expect(!opened.get("prompt_sent").?.bool);
    try testing.expectEqualStrings("9.9 (x)", opened.get("binary_version").?.string);
    try testing.expectEqual(@as(usize, 0), opened.get("path_prepend").?.array.items.len);
    // A remote launch's login and ControlMaster facts match the schema too.
    var m: @import("../mux/sshmaster.zig").Report = .{ .kind = .sketerm, .reused = true, .age_s = 42 };
    @memcpy(m.path_buf[0..9], "/x/sk-abc");
    m.path_len = 9;
    // Borrowed for this one result; agent_close below frees the entry.
    const was_host = e.host;
    e.host = @constCast("box");
    const remote_out = openResult(a, e, true, false, &.{}, dv, .{}, &.{ .login = true, .shell = "/bin/bash", .master = m });
    e.host = was_host;
    const remote = try shaped(a, "agent_open", try remote_out);
    try testing.expect(remote.get("login_shell").?.bool);
    try testing.expectEqual(@as(i64, 42), remote.get("ssh_master_age_s").?.integer);
    try testing.expectEqualStrings("sketerm", remote.get("ssh_master").?.string);
    try testing.expect(std.mem.indexOf(u8, opened.get("watch_command").?.string, "--match x") != null);

    const closed = try shaped(a, "agent_close", try rig.call(.agent_close, "{}"));
    // An attached terminal belongs to term_open: nothing was killed.
    try testing.expectEqual(@as(usize, 0), closed.get("sessions").?.array.items.len);
    try testing.expect(!app.failed.load(.acquire));
}
