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
//!
//! The implementation is split by concern into sibling files, which take
//! the shared `state` and `Entry` from here; this file keeps the state, the
//! tool dispatch (`agentTool`) and the public entry points:
//! mcp_agent_loop.zig (the server loop, waits, reconnection, retry),
//! mcp_agent_open.zig (agent_adapters / agent_open / agent_attach of a
//! terminal and the spawn machinery), mcp_agent_act.zig (prompts, the send
//! path, recipes, relaunch, templates), mcp_agent_talk.zig (the tools on a
//! running agent), mcp_agent_results.zig (result writing),
//! mcp_agent_waiter.zig (push delivery and the waiter socket),
//! mcp_agent_index.zig (the per-user index, ownership and reattach) and
//! mcp_agent_hosts.zig (host stats, caps and facts).

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
const select = @import("../agent/select.zig");
const launch = @import("../agent/launch.zig");
const retry_mod = @import("../agent/retry.zig");
const stall_mod = @import("../agent/stall.zig");
const statusline = @import("../agent/statusline.zig");
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
const transport_mod = @import("transport.zig");
const mcp_registry = @import("mcp_registry.zig");
const agentindex = @import("agentindex.zig");
const tombstones = @import("../mux/tombstones.zig");
const sockpath = @import("../mux/sockpath.zig");
const Config = @import("../config.zig").Config;
const Transport = transport_mod.Transport;
const errRes = mcp.errRes;
const argStr = mcp.argStr;
const argInt = mcp.argInt;
const argBool = mcp.argBool;

const mcp_agent_hosts = @import("mcp_agent_hosts.zig");
const mcp_agent_results = @import("mcp_agent_results.zig");
const mcp_agent_waiter = @import("mcp_agent_waiter.zig");
const mcp_agent_index = @import("mcp_agent_index.zig");
const mcp_agent_act = @import("mcp_agent_act.zig");
const mcp_agent_open = @import("mcp_agent_open.zig");
const mcp_agent_talk = @import("mcp_agent_talk.zig");
const mcp_agent_loop = @import("mcp_agent_loop.zig");

// What this file takes from the split modules; the `pub` ones keep the
// public surface (`mcp_agent.*`) where its callers expect it.
const HostProbe = mcp_agent_hosts.HostProbe;
pub const factsCapability = mcp_agent_hosts.factsCapability;
pub const outcomeOf = mcp_agent_results.outcomeOf;
pub const armPush = mcp_agent_waiter.armPush;
pub const startPush = mcp_agent_waiter.startPush;
pub const instructions = mcp_agent_waiter.instructions;
pub const followers = mcp_agent_waiter.followers;
const Waiter = mcp_agent_waiter.Waiter;
pub const reattach = mcp_agent_index.reattach;
pub const publishTo = mcp_agent_index.publishTo;
const attachIdTool = mcp_agent_index.attachIdTool;
const templateSaveTool = mcp_agent_act.templateSaveTool;
const templatesTool = mcp_agent_act.templatesTool;
const templateDeleteTool = mcp_agent_act.templateDeleteTool;
const adaptersTool = mcp_agent_open.adaptersTool;
const openTool = mcp_agent_open.openTool;
const attachTool = mcp_agent_open.attachTool;
const sendTool = mcp_agent_talk.sendTool;
const sendManyTool = mcp_agent_talk.sendManyTool;
const waitTool = mcp_agent_talk.waitTool;
const waitAllTool = mcp_agent_talk.waitAllTool;
const waitAnyTool = mcp_agent_talk.waitAnyTool;
const answerTool = mcp_agent_talk.answerTool;
const setTool = mcp_agent_talk.setTool;
const interruptTool = mcp_agent_talk.interruptTool;
const askTool = mcp_agent_talk.askTool;
const readTool = mcp_agent_talk.readTool;
const listTool = mcp_agent_talk.listTool;
const closeTool = mcp_agent_talk.closeTool;
const closeGoneTool = mcp_agent_talk.closeGoneTool;
pub const Observation = mcp_agent_loop.Observation;
pub const observeScreen = mcp_agent_loop.observeScreen;
pub const pollFds = mcp_agent_loop.pollFds;
pub const dueInMs = mcp_agent_loop.dueInMs;
pub const service = mcp_agent_loop.service;
pub const sweep = mcp_agent_loop.sweep;
const ReconnectJob = mcp_agent_loop.ReconnectJob;
const abandonReconnect = mcp_agent_loop.abandonReconnect;
const serviceReconnects = mcp_agent_loop.serviceReconnects;
const reconnectIfLost = mcp_agent_loop.reconnectIfLost;
const gone = mcp_agent_loop.gone;

pub const Tool = mcp_tools.GroupTool(.agent);

/// A wait's default bound (agent_open with a prompt, send, answer, wait).
pub const DEFAULT_WAIT_MS: i64 = 60_000;
/// agent_attach's default wait for the app to be ready.
pub const ATTACH_WAIT_MS: i64 = 10_000;
/// Bound on one `wait` step of an action recipe (a picker to show up).
pub const STEP_WAIT_MS: i64 = 10_000;
/// Pause after an interrupt so the reply shows the state it caused.
pub const INTERRUPT_SETTLE_MS: i64 = 300;
/// How long a screen app gets to show it took a typed prompt (a turn, a
/// user record, a queue preview) before the send is `not_delivered`.
pub const DELIVERY_CONFIRM_MS: i64 = 10_000;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 40;
/// The waiter socket's name in the instance dir.
pub const WAITER_SOCKET = "agents.sock";
/// Background reconnection of a lost remote link: the first retry, doubled
/// after each failure up to the cap, forever while the agent is here.
pub const RECONNECT_MIN_MS: i64 = 2_000;
pub const RECONNECT_MAX_MS: i64 = 60_000;

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
    "A wake-up the waiter printed is not repeated by agent_* results; it carries a done's answer in full when short, and agent_read returns what it did not carry. " ++
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
    /// `stall_after_min`: one `stalled` event per silence.
    stall: stall_mod.Tracker = .{},
    /// An action (a recipe, an API call) runs on the agent now: a retry
    /// never types into it.
    acting: u32 = 0,
    /// A reconnect found its session gone from the daemon: what that
    /// daemon remembered of its end.
    gone_why: ?GoneFacts = null,
    /// The error `serviceEntry` last failed with, reported once until it
    /// succeeds again (`noteServiceFailure`).
    service_failed: ?anyerror = null,
    /// Started resuming its conversation, and no prompt went in since:
    /// whatever the app shows meanwhile is its past (`foldHistory`).
    history: bool = false,
    /// The turns the app had started when the history window opened: one
    /// more is a turn of its own (a human's prompt), which closes it.
    history_turns: u64 = 0,
    /// Prompts THIS server typed into the app's own queue that it has not
    /// taken yet, oldest first (owned): an interrupt that throws the queue
    /// away types them again. Never anything the app holds from elsewhere.
    queued_sent: std.ArrayList(QueuedPrompt) = .empty,
    /// The status command's facts file on the agent's host (owned); null
    /// when its adapter has none or the start could not set it up.
    facts_file: ?[]u8 = null,
    /// The user's own status object the command chains, as JSON (owned;
    /// null: they have none). Every restart builds the same command.
    status_user: ?[]u8 = null,
    /// Why the start set no status command up (static).
    facts_skipped: ?[]const u8 = null,

    /// Forget the oldest `n` prompts of `queued_sent`.
    pub fn dropQueued(self: *Entry, n: usize) void {
        const k = @min(n, self.queued_sent.items.len);
        for (self.queued_sent.items[0..k]) |q| q.free(self.allocator);
        self.queued_sent.replaceRangeAssumeCapacity(0, k, &.{});
    }

    pub fn visibleTerm(self: *const Entry) ?*termdrive.Term {
        const l = self.visible orelse return null;
        return switch (l) {
            .owned => |t| t,
            .borrowed => |id| mcp_term.term_state.terms.get(id),
        };
    }

    pub fn where(self: *const Entry) Where {
        return .{ .host = self.host, .transport = self.transport, .cols = self.cols, .rows = self.rows };
    }

    /// Free the entry. `kill` ends the sessions it owns; otherwise they
    /// keep running on the daemon (this server exiting, or another one
    /// taking the agent over). Its index claim is let go either way, and
    /// its port forward always ends: it is this server's own ssh, whose
    /// session name the agent's next start or attach asks for again.
    pub fn destroy(self: *Entry, kill: bool) void {
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
        if (self.forward) |t| t.deinit();
        self.freeFields();
        a.destroy(self);
    }

    /// Free what the entry owns besides its agent and terminals.
    pub fn freeFields(self: *Entry) void {
        const a = self.allocator;
        if (self.password) |p| {
            std.crypto.secureZero(u8, p);
            a.free(p);
        }
        for ([_]?[]u8{ self.server_session, self.host, self.conversation, self.launch_model, self.launch_effort, self.picked_model, self.name, self.socket, self.push_match, self.facts_file, self.status_user }) |o| {
            if (o) |s| a.free(s);
        }
        self.extra.free(a);
        self.handed.deinit(a);
        self.dropQueued(self.queued_sent.items.len);
        self.queued_sent.deinit(a);
        for (self.recordings.items) |r| a.free(r);
        self.recordings.deinit(a);
        a.free(self.id);
        a.free(self.session);
        a.free(self.binary);
        a.free(self.cwd);
    }
};

/// A prompt sketerm queued in an agent's app (`Entry.queued_sent`).
pub const QueuedPrompt = struct {
    text: []u8,
    template: ?[]u8 = null,

    pub fn free(self: QueuedPrompt, a: std.mem.Allocator) void {
        a.free(self.text);
        if (self.template) |t| a.free(t);
    }
};

/// Why a session is gone, as its daemon's tombstone says (all null: it
/// keeps no record, as a daemon fresh after a reboot).
pub const GoneFacts = struct {
    reason: ?tombstones.Reason = null,
    ended_ms: ?i64 = null,
    exit_status: ?i32 = null,
    signal: ?i32 = null,

    pub fn of(tomb: ?tombstones.Reply) GoneFacts {
        const tb = tomb orelse return .{};
        return .{ .reason = tb.reason orelse .unknown, .ended_ms = tb.ended_ms, .exit_status = tb.exit_status, .signal = tb.signal };
    }

    pub fn reasonName(self: GoneFacts) []const u8 {
        return @tagName(self.reason orelse .unknown);
    }
};

/// Where an agent's sessions run.
pub const Where = struct {
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
    /// `mcp_agent_max_per_host` / `mcp_agent_min_free_mb`; 0 = no cap.
    max_per_host: u32 = 0,
    min_free_mb: u32 = 0,
    /// Each host's last memory and load reading (`HostProbe`).
    hosts: std.ArrayList(*HostProbe) = .empty,
};

/// Agents one agent_wait or waiter watches at most.
pub const MAX_ANY = agentwait.MAX_ANY;

pub fn hold(e: *const Entry) void {
    if (isHeld(e) or state.held_len == state.held.len) return;
    state.held[state.held_len] = e;
    state.held_len += 1;
}

pub fn isHeld(e: *const Entry) bool {
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
    state.max_per_host = cfg.mcp_agent_max_per_host;
    state.min_free_mb = cfg.mcp_agent_min_free_mb;
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
    for (state.hosts.items) |h| h.free(a);
    state.hosts.deinit(a);
    state.hosts = .empty;
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

pub fn adapters() !*adapter.Set {
    if (state.set == null) state.set = try adapter.Set.loadDefault(state.allocator);
    return &state.set.?;
}

/// The adapters that answer side questions (`agent_ask`), for `capabilities`.
pub fn sideQuestionApps(arena: std.mem.Allocator) ![]const []const u8 {
    const set = try adapters();
    var out: std.ArrayList([]const u8) = .empty;
    for (set.items.items) |l| if (agent_mod.supportsAction(l, .side_question)) try out.append(arena, l.spec.id);
    return out.items;
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

pub fn findByName(name: []const u8) ?*Entry {
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
pub fn mintId(arena: std.mem.Allocator, app: []const u8) ![]const u8 {
    return agentindex.mint(arena, state.index_dir, app, &knownHere);
}

pub fn lockPath(a: std.mem.Allocator, id: []const u8) ![]u8 {
    return agentindex.path(a, state.index_dir orelse return error.NoIndex, id, "lock");
}

pub fn findById(id: []const u8) ?*Entry {
    for (state.entries.items) |e| {
        if (std.mem.eql(u8, e.id, id)) return e;
    }
    return null;
}

pub fn localHost() launch.Host {
    return .{
        .path = if (c.getenv("PATH")) |p| std.mem.span(@as([*:0]const u8, @ptrCast(p))) else "",
        .home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else null,
    };
}

/// This process's non-empty value of a variable: the host environment a
/// local start's settings lookup sees (`statusline.localPaths`).
pub fn envValue(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return null;
    return @import("../util/env.zig").nonEmpty(z.ptr);
}

/// The adapter's status command (a screen app's facts source), if any.
pub fn statusCommandOf(loaded: *const adapter.Loaded) ?adapter.StatusCommand {
    return (loaded.spec.facts orelse return null).status_command;
}

/// The status command a start passes: saving to `facts_file`, chaining
/// `user` (JSON); null without a file (none set up) or a status command.
pub fn statusOf(arena: std.mem.Allocator, loaded: *const adapter.Loaded, facts_file: ?[]const u8, user: ?[]const u8) !?launch.Status {
    const f = facts_file orelse return null;
    return try statusline.status(arena, statusCommandOf(loaded) orelse return null, f, user);
}

// ── tools ────────────────────────────────────────────────────────

/// A refusal with its code, for helpers whose caller builds the result.
pub const Fail = struct { code: mcp.ErrCode, msg: []const u8 };

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
        .agent_send => if (mcp.argValue(args, "agents")) |v| switch (try agentsList(arena, v)) {
            .fail => |f| errRes(arena, f.code, f.msg),
            .ok => |list| if (argStr(args, "agent") != null)
                errRes(arena, .invalid_args, "pass either 'agent' or 'agents', not both")
            else
                sendManyTool(arena, args, list),
        } else withEntry(arena, args, sendTool),
        .agent_wait => if (mcp.argValue(args, "agents")) |v| switch (try agentsList(arena, v)) {
            .fail => |f| errRes(arena, f.code, f.msg),
            .ok => |list| if (argBool(args, "all")) waitAllTool(arena, args, list) else waitAnyTool(arena, args, list),
        } else if (argBool(args, "all"))
            errRes(arena, .invalid_args, "all waits on several agents: pass them as 'agents'")
        else
            withEntry(arena, args, waitTool),
        .agent_read => withEntry(arena, args, readTool),
        .agent_answer => withEntry(arena, args, answerTool),
        .agent_set => withEntry(arena, args, setTool),
        .agent_interrupt => withEntry(arena, args, interruptTool),
        .agent_ask => if (mcp.argValue(args, "agents") != null)
            errRes(arena, .invalid_args, "agent_ask asks ONE agent: pass 'agent' (a side question is answered in that agent's own panel)")
        else
            withEntry(arena, args, askTool),
        .agent_close => if (entryFromArgs(args) == null and argStr(args, "agent") != null) closeGoneTool(arena, argStr(args, "agent").?) else withEntry(arena, args, closeTool),
        .agent_template_save => templateSaveTool(arena, args),
        .agent_templates => templatesTool(arena, args),
        .agent_template_delete => templateDeleteTool(arena, args),
    };
}

/// agent_send's and agent_wait's `agents`: the array given, or for
/// `mcp_tools.AGENTS_EVERY` the ids of every live (not exited) agent here.
fn agentsList(arena: std.mem.Allocator, v: std.json.Value) !union(enum) { ok: []const std.json.Value, fail: Fail } {
    switch (v) {
        .array => |list| return .{ .ok = list.items },
        // No service here: it would hand a waiter what this call's own
        // wait (which holds the agents first) should get.
        .string => |x| if (std.mem.eql(u8, x, mcp_tools.AGENTS_EVERY)) {
            var out: std.ArrayList(std.json.Value) = .empty;
            for (state.entries.items) |e| if (!gone(e)) try out.append(arena, .{ .string = e.id });
            if (out.items.len == 0) return .{ .fail = .{ .code = .not_found, .msg = if (state.entries.items.len == 0)
                "agents \"*\" means every live agent of this server, and none is open; start one with agent_open"
            else
                try std.fmt.allocPrint(arena, "agents \"*\" means every live agent of this server, and none is live (open, all exited: {s})", .{try idList(arena)}) } };
            if (out.items.len > MAX_ANY) return .{ .fail = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "agents \"*\" names {d} live agents, more than the {d} one call takes: list them in batches", .{ out.items.len, MAX_ANY }) } };
            return .{ .ok = out.items };
        },
        else => {},
    }
    return .{ .fail = .{ .code = .invalid_args, .msg = "agents must be an array of agent ids or names, or \"*\" for every live agent of this server" } };
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

pub fn idList(arena: std.mem.Allocator) ![]const u8 {
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

pub fn filterFrom(args: std.json.Value) events.Filter {
    const m = argStr(args, "match");
    return .{ .messages = argBool(args, "messages"), .match = if (m != null and m.?.len > 0) m else null, .retrying = argBool(args, "retrying"), .background = argBool(args, "background") };
}

pub fn deadlineFrom(args: std.json.Value, default_ms: i64) i64 {
    return clock.nowMs() + mcp.waitCap(argInt(args, "timeout_ms"), default_ms);
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_agent_testkit = @import("mcp_agent_testkit.zig");
const live = mcp_agent_testkit.live;
const ToolRig = mcp_agent_testkit.ToolRig;
const expectError = mcp_agent_testkit.expectError;
const APP_IDLE = mcp_agent_testkit.APP_IDLE;
const FakeApp = mcp_agent_testkit.FakeApp;
const shaped = mcp_agent_testkit.shaped;
const combine = mcp_agent_results.combine;
const openResult = mcp_agent_open.openResult;
const newEntry = mcp_agent_open.newEntry;

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
    try expectError(a, "agent_open", try rig.call(.agent_open, "{\"app\":\"claude\",\"stall_after_min\":100000}"), "invalid_args");
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
    // agents "*" with nothing live is a clear not_found; any other string is no list.
    try expectError(a, "agent_send", try rig.call(.agent_send, "{\"agents\":\"*\",\"text\":\"hi\"}"), "not_found");
    try expectError(a, "agent_wait", try rig.call(.agent_wait, "{\"agents\":\"*\"}"), "not_found");
    try expectError(a, "agent_send", try rig.call(.agent_send, "{\"agents\":\"all\",\"text\":\"hi\"}"), "invalid_args");
    try expectError(a, "agent_wait", try rig.call(.agent_wait, "{\"agents\":7}"), "invalid_args");
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
        // Every action but a side question, which its API has no route for.
        const acts = item.object.get("actions").?.array.items;
        try testing.expectEqual(@as(usize, std.enums.values(agent_mod.ActionKind).len - 1), acts.len);
        for (acts) |x| try testing.expect(!std.mem.eql(u8, x.string, "side_question"));
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
    // The stall alarm: set at any time, a fact while on, refused out of range.
    const stall_on = try shaped(a, "agent_set", try rig.call(.agent_set, "{\"stall_after_min\":30}"));
    try testing.expectEqual(@as(i64, 30), stall_on.get("stall_after_min").?.integer);
    try testing.expectEqual(@as(?u32, 30), e.stall.after_min);
    try expectError(a, "agent_set", try rig.call(.agent_set, "{\"stall_after_min\":-1}"), "invalid_args");
    try expectError(a, "agent_set", try rig.call(.agent_set, "{\"stall_after_min\":\"5\"}"), "invalid_args");
    try testing.expectEqual(@as(?u32, 30), e.stall.after_min);
    const stall_off = try shaped(a, "agent_set", try rig.call(.agent_set, "{\"stall_after_min\":0}"));
    try testing.expect(stall_off.get("stall_after_min") == null);

    const closed = try mcp.expectToolResultShape(a, "agent_close", try rig.call(.agent_close, "{}"));
    try testing.expect(closed.object.get("structuredContent").?.object.get("closed").?.bool);
    try testing.expectEqual(@as(usize, 0), state.entries.items.len);
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
    // Records and events say when, in local wall time with its offset.
    var today: [clock.ISO_LEN]u8 = undefined;
    const day = clock.isoLocal(&today, clock.wallMs()).?[0..10];
    try testing.expect(std.mem.startsWith(u8, sent_recs[0].object.get("at").?.string, day));
    try testing.expectEqual(@as(usize, clock.ISO_LEN), sent_recs[0].object.get("at").?.string.len);
    for (sent.get("events").?.array.items) |ev| try testing.expect(std.mem.startsWith(u8, ev.object.get("at").?.string, day));

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
    // The refusal says how to answer and shows the prompt.
    const refused = try mcp_agent_testkit.errorMessage(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"again\"}"), "conflict");
    try testing.expect(std.mem.indexOf(u8, refused, "nothing was sent: answer it with agent_answer with choice (an option label, its 1-based number or a unique part of a label) or text (a free-text answer)") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "pending permission: \"") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "options: 1. Yes, 2. No") != null);
    const maybe = try mcp_agent_testkit.errorMessage(a, "agent_answer", try rig.call(.agent_answer, "{\"choice\":\"Maybe\"}"), "invalid_args");
    try testing.expectEqualStrings("'Maybe' names none of the options (1. Yes, 2. No); answer with agent_answer with choice (an option label, its 1-based number or a unique part of a label) or text (a free-text answer)", maybe);
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

    // The activity glance: state, last activity, the tool calls by name
    // and time; small, and it hands nothing out.
    const glance_raw = try rig.call(.agent_read, "{\"detail\":\"activity\"}");
    const glance = try shaped(a, "agent_read", glance_raw);
    try testing.expectEqualStrings("activity", glance.get("detail").?.string);
    try testing.expectEqualStrings("idle", glance.get("state").?.string);
    try testing.expectEqual(@as(usize, 0), glance.get("records").?.array.items.len);
    const gtools = glance.get("tools").?.array.items;
    try testing.expect(gtools.len >= 1);
    try testing.expectEqualStrings("Bash", gtools[gtools.len - 1].object.get("name").?.string);
    try testing.expectEqual(@as(usize, 8), gtools[gtools.len - 1].object.get("at").?.string.len);
    try testing.expectEqual(@as(usize, clock.ISO_LEN), glance.get("last_activity_at").?.string.len);
    try testing.expect(glance.get("idle_s").?.integer >= 0);
    try testing.expect(glance_raw.len < 1200);
    const one_tool = try shaped(a, "agent_read", try rig.call(.agent_read, "{\"detail\":\"activity\",\"limit\":1}"));
    try testing.expectEqual(@as(usize, 1), one_tool.get("tools").?.array.items.len);
    try expectError(a, "agent_read", try rig.call(.agent_read, "{\"detail\":\"activity\",\"since\":0}"), "invalid_args");

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
    try testing.expectEqual(@as(usize, clock.ISO_LEN), item.get("last_activity_at").?.string.len);
    try testing.expectEqual(@as(i64, 0), item.get("queued_prompts").?.integer);
    // The default list: the compact facts only.
    const compact = try shaped(a, "agent_list", try rig.call(.agent_list, "{}"));
    try testing.expect(!compact.get("detail").?.bool);
    const citem = compact.get("agents").?.array.items[0].object;
    try testing.expectEqualStrings("local", citem.get("host").?.string);
    try testing.expectEqual(@as(i64, 0), citem.get("queued").?.integer);
    try testing.expect(citem.get("idle_s").?.integer >= 0);
    try testing.expectEqual(@as(u8, 0x3a), citem.get("active_at").?.string[2]);
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

    // An interrupt throws the app's queue away: the urgent prompt goes in
    // first, then the prompts THIS server had queued, in their order.
    const glacial = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"a glacial one\",\"timeout_ms\":300}"));
    try testing.expect(!glacial.get("queued").?.bool);
    var glacial_polls: usize = 0;
    while (glacial_polls < 50) : (glacial_polls += 1) {
        const l = try shaped(a, "agent_list", try rig.call(.agent_list, "{}"));
        if (std.mem.eql(u8, l.get("agents").?.array.items[0].object.get("state").?.string, "working")) break;
        _ = c.usleep(50_000);
    }
    for ([_][]const u8{ "held one", "held two" }) |t| {
        const h = try shaped(a, "agent_send", try rig.call(.agent_send, try std.fmt.allocPrint(a, "{{\"text\":\"{s}\",\"timeout_ms\":300}}", .{t})));
        try testing.expect(h.get("queued").?.bool);
    }
    const urgent = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"urgent\",\"interrupt\":true,\"timeout_ms\":10000}"));
    try testing.expect(urgent.get("interrupted").?.bool);
    try testing.expectEqual(@as(i64, 2), urgent.get("queued_dropped").?.integer);
    const rq = urgent.get("requeued").?.array.items;
    try testing.expectEqual(@as(usize, 2), rq.len);
    try testing.expectEqualStrings("held one", rq[0].object.get("text").?.string);
    try testing.expectEqualStrings("held two", rq[1].object.get("text").?.string);
    try testing.expect(urgent.get("requeue_failed") == null);
    // All three answered, the urgent one first.
    _ = try shaped(a, "agent_wait", try rig.call(.agent_wait, "{\"timeout_ms\":3000}"));
    const after_rq = try shaped(a, "agent_read", try rig.call(.agent_read, "{\"detail\":\"all\",\"since\":0}"));
    var order: [3]?usize = .{ null, null, null };
    for (after_rq.get("records").?.array.items, 0..) |r, i| {
        const txt = r.object.get("text").?.string;
        for ([_][]const u8{ "echo: urgent", "echo: held one", "echo: held two" }, 0..) |want, k| {
            if (std.mem.eql(u8, txt, want)) order[k] = i;
        }
    }
    try testing.expect(order[0] != null and order[1] != null and order[2] != null);
    try testing.expect(order[0].? < order[1].? and order[1].? < order[2].?);

    // A plain agent_interrupt types this server's dropped prompts again too.
    _ = try shaped(a, "agent_send", try rig.call(.agent_send, "{\"text\":\"another glacial one\",\"timeout_ms\":300}"));
    glacial_polls = 0;
    while (glacial_polls < 50) : (glacial_polls += 1) {
        const l = try shaped(a, "agent_list", try rig.call(.agent_list, "{}"));
        if (std.mem.eql(u8, l.get("agents").?.array.items[0].object.get("state").?.string, "working")) break;
        _ = c.usleep(50_000);
    }
    for ([_][]const u8{ "held three", "held four" }) |t| {
        const h = try shaped(a, "agent_send", try rig.call(.agent_send, try std.fmt.allocPrint(a, "{{\"text\":\"{s}\",\"timeout_ms\":300}}", .{t})));
        try testing.expect(h.get("queued").?.bool);
    }
    const halted = try shaped(a, "agent_interrupt", try rig.call(.agent_interrupt, "{}"));
    try testing.expectEqual(@as(i64, 2), halted.get("queued_dropped").?.integer);
    const hrq = halted.get("requeued").?.array.items;
    try testing.expectEqual(@as(usize, 2), hrq.len);
    try testing.expectEqualStrings("held three", hrq[0].object.get("text").?.string);
    try testing.expectEqualStrings("held four", hrq[1].object.get("text").?.string);
    _ = try shaped(a, "agent_wait", try rig.call(.agent_wait, "{\"timeout_ms\":3000}"));
    const after_halt = try shaped(a, "agent_read", try rig.call(.agent_read, "{\"detail\":\"all\",\"since\":0}"));
    var halt_order: [2]?usize = .{ null, null };
    for (after_halt.get("records").?.array.items, 0..) |r, i| {
        const txt = r.object.get("text").?.string;
        for ([_][]const u8{ "echo: held three", "echo: held four" }, 0..) |want, k| {
            if (std.mem.eql(u8, txt, want)) halt_order[k] = i;
        }
    }
    try testing.expect(halt_order[0] != null and halt_order[1] != null and halt_order[0].? < halt_order[1].?);

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
