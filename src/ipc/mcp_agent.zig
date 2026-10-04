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
const select = @import("../agent/select.zig");
const launch = @import("../agent/launch.zig");
const screen_source = @import("../agent/screen_source.zig");
const opencode = @import("../agent/opencode.zig");
const retry_mod = @import("../agent/retry.zig");
const stall_mod = @import("../agent/stall.zig");
const statusline = @import("../agent/statusline.zig");
const wire = @import("../mux/wire.zig");
const Screen = @import("../grid/screen.zig").Screen;
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
const transport_mod = @import("transport.zig");
const mcp_registry = @import("mcp_registry.zig");
const agentindex = @import("agentindex.zig");
const muxconnect = @import("muxconnect.zig");
const muxclient = @import("../mux/client.zig");
const tombstones = @import("../mux/tombstones.zig");
const sockpath = @import("../mux/sockpath.zig");
const Config = @import("../config.zig").Config;
const Transport = transport_mod.Transport;
const Res = mcp.Res;
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

// What this file takes from the split modules; the `pub` ones keep the
// public surface (`mcp_agent.*`) where its callers expect it.
const HOST_LIST_WAIT_MS = mcp_agent_hosts.HOST_LIST_WAIT_MS;
const HostProbe = mcp_agent_hosts.HostProbe;
const serviceHostProbes = mcp_agent_hosts.serviceHostProbes;
const readHosts = mcp_agent_hosts.readHosts;
const hostsReport = mcp_agent_hosts.hostsReport;
pub const factsCapability = mcp_agent_hosts.factsCapability;
const factsOf = mcp_agent_hosts.factsOf;
const Block = mcp_agent_results.Block;
const combine = mcp_agent_results.combine;
const pending = mcp_agent_results.pending;
pub const outcomeOf = mcp_agent_results.outcomeOf;
const EventJson = mcp_agent_results.EventJson;
const toJson = mcp_agent_results.toJson;
const finish = mcp_agent_results.finish;
const conversationOf = mcp_agent_results.conversationOf;
const permissionsValue = mcp_agent_results.permissionsValue;
const relaunchableOf = mcp_agent_results.relaunchableOf;
const block = mcp_agent_results.block;
const eventsJson = mcp_agent_results.eventsJson;
const writeSelection = mcp_agent_results.writeSelection;
pub const armPush = mcp_agent_waiter.armPush;
pub const startPush = mcp_agent_waiter.startPush;
pub const instructions = mcp_agent_waiter.instructions;
pub const followers = mcp_agent_waiter.followers;
const pushing = mcp_agent_waiter.pushing;
const rememberFilter = mcp_agent_waiter.rememberFilter;
const servicePush = mcp_agent_waiter.servicePush;
const Waiter = mcp_agent_waiter.Waiter;
const endWaitersOf = mcp_agent_waiter.endWaitersOf;
const writeDescriptor = mcp_agent_index.writeDescriptor;
const removeDescriptor = mcp_agent_index.removeDescriptor;
pub const reattach = mcp_agent_index.reattach;
const canRelaunch = mcp_agent_index.canRelaunch;
pub const publishTo = mcp_agent_index.publishTo;
const publishAgents = mcp_agent_index.publishAgents;
const askWhyGone = mcp_agent_index.askWhyGone;
const attachIdTool = mcp_agent_index.attachIdTool;
const busy = mcp_agent_act.busy;
const Prompt = mcp_agent_act.Prompt;
const refuse = mcp_agent_act.refuse;
const promptFrom = mcp_agent_act.promptFrom;
const templateSaveTool = mcp_agent_act.templateSaveTool;
const templatesTool = mcp_agent_act.templatesTool;
const templateDeleteTool = mcp_agent_act.templateDeleteTool;
const submitAndWait = mcp_agent_act.submitAndWait;
const Requeued = mcp_agent_act.Requeued;
const requeueDropped = mcp_agent_act.requeueDropped;
const submitPrompt = mcp_agent_act.submitPrompt;
const sendFailRes = mcp_agent_act.sendFailRes;
const Stopped = mcp_agent_act.Stopped;
const stopForSend = mcp_agent_act.stopForSend;
const waitAfter = mcp_agent_act.waitAfter;
const act = mcp_agent_act.act;
const noteSetting = mcp_agent_act.noteSetting;
const optionList = mcp_agent_act.optionList;
const RequeuedItem = mcp_agent_act.RequeuedItem;
const Submitted = mcp_agent_act.Submitted;
const retryPolicyFrom = mcp_agent_open.retryPolicyFrom;
const stallFrom = mcp_agent_open.stallFrom;
const setRetryPolicy = mcp_agent_open.setRetryPolicy;
const adaptersTool = mcp_agent_open.adaptersTool;
const effortRefusal = mcp_agent_open.effortRefusal;
const openTool = mcp_agent_open.openTool;
const attachTool = mcp_agent_open.attachTool;
const discard = mcp_agent_open.discard;

pub const Tool = mcp_tools.GroupTool(.agent);

/// A wait's default bound (agent_open with a prompt, send, answer, wait).
pub const DEFAULT_WAIT_MS: i64 = 60_000;
/// agent_attach's default wait for the app to be ready.
pub const ATTACH_WAIT_MS: i64 = 10_000;
/// Bound on one `wait` step of an action recipe (a picker to show up).
pub const STEP_WAIT_MS: i64 = 10_000;
/// A screen engine's settle rules need ticks while something is pending.
const TICK_MS: i64 = 250;
/// Pause after an interrupt so the reply shows the state it caused.
pub const INTERRUPT_SETTLE_MS: i64 = 300;
/// How long a screen app gets to show it took a typed prompt (a turn, a
/// user record, a queue preview) before the send is `not_delivered`.
pub const DELIVERY_CONFIRM_MS: i64 = 10_000;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 40;
/// Records one agent_read returns by default, and at most.
const READ_DEFAULT: usize = 100;
const READ_MAX: usize = 500;
/// The waiter socket's name in the instance dir.
pub const WAITER_SOCKET = "agents.sock";
/// How often a dead forward is respawned / a lost link retried.
const FORWARD_RETRY_MS: i64 = 3_000;
/// Background reconnection of a lost remote link: the first retry, doubled
/// after each failure up to the cap, forever while the agent is here.
const RECONNECT_MIN_MS: i64 = 2_000;
const RECONNECT_MAX_MS: i64 = 60_000;
/// How often `sweep` checks that this server still owns its agents.
const SWEEP_EVERY_MS: i64 = 1_000;
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
    fn dropQueued(self: *Entry, n: usize) void {
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
        if (!e.relaunching) _ = e.stall.check(e.agent.queue(), e.agent.state(), e.agent.lastActivityMs(), now_ms) catch {};
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
fn reconnectIfLost(e: *Entry) void {
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

/// One agent's line of an `all` wake: the settling kind (else the state).
pub fn settledOf(e: *const Entry, s: Settle) agentwait.Settled {
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

pub fn filterFrom(args: std.json.Value) events.Filter {
    const m = argStr(args, "match");
    return .{ .messages = argBool(args, "messages"), .match = if (m != null and m.?.len > 0) m else null, .retrying = argBool(args, "retrying"), .background = argBool(args, "background") };
}

pub fn deadlineFrom(args: std.json.Value, default_ms: i64) i64 {
    return clock.nowMs() + mcp.waitCap(argInt(args, "timeout_ms"), default_ms);
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
    var requeued: Requeued = .{};
    switch (try submitAndWait(arena, e, text, filter, deadlineFrom(args, DEFAULT_WAIT_MS), interrupt, stop[0].dropped_sent, &requeued)) {
        .fail => |f| return sendFailRes(arena, e, f),
        .ok => |dv| {
            var res = Res.init(arena);
            try requeued.report(arena, &res);
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
    /// The prompts this server had queued that the interrupt made the app
    /// drop, queued again behind this one (`requeueDropped`).
    requeued: ?[]const RequeuedItem = null,
    requeue_failed: ?struct { code: []const u8, message: []const u8, not_requeued: usize } = null,
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
        switch (outcome) {
            .fail => {},
            .ok => {
                const rq = try requeueDropped(arena, e, stop.dropped_sent, deadline);
                if (rq.done.len > 0) r.requeued = try rq.items(arena);
                if (rq.fail) |f| r.requeue_failed = .{ .code = @tagName(f.code), .message = f.msg, .not_requeued = rq.left };
            },
        }
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
    const stall_arg = mcp.argValue(args, "stall_after_min");
    if (model == null and effort == null and retry_arg == null and stall_arg == null) return errRes(arena, .invalid_args, "agent_set needs 'model', 'effort', 'retry_on_overload' and/or 'stall_after_min'");
    inline for (.{ "model", "effort" }) |key| {
        if (argStr(args, key)) |v| if (!launch.validValue(v)) return errRes(arena, .invalid_args, key ++ " must be 1-256 printable characters");
    }
    // Refused before anything is typed, stopped or restarted.
    if (effort) |x| if (!launch.validEffort(e.loaded.spec.launch, x)) return errRes(arena, .invalid_args, try effortRefusal(arena, e.loaded));
    // The settings that apply at any time: both checked before either is set.
    if (retry_arg != null or stall_arg != null) {
        var why: Fail = undefined;
        const p = if (retry_arg) |v| retryPolicyFrom(arena, v, &why) catch |err| switch (err) {
            error.Refused => return errRes(arena, why.code, why.msg),
            else => return err,
        } else null;
        const stall = if (stall_arg) |v| stallFrom(arena, v, &why) catch |err| switch (err) {
            error.Refused => return errRes(arena, why.code, why.msg),
            else => return err,
        } else null;
        if (retry_arg != null) setRetryPolicy(e, p);
        if (stall_arg != null) e.stall.set(stall, clock.nowMs());
        writeDescriptor(e);
        service(clock.nowMs());
        if (model == null and effort == null) {
            var res = Res.init(arena);
            if (retry_arg != null) {
                if (p) |x|
                    try res.textf("{s}: retry_on_overload on: up to {d} retr{s} per job, the first after {d} s, doubling", .{ e.id, x.max, if (x.max == 1) "y" else "ies", x.backoff_s })
                else
                    try res.textf("{s}: retry_on_overload off", .{e.id});
            }
            if (stall_arg != null) {
                if (stall) |m|
                    try res.textf("{s}: stall_after_min {d}: one stalled event when it shows nothing for {d} minutes while busy", .{ e.id, m, m })
                else
                    try res.textf("{s}: stall_after_min off", .{e.id});
            }
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

/// agent_ask: a side question answered from the agent's current context
/// without a turn. Nothing is recorded, no event is raised or taken, the
/// handed-out state and the remembered waiter filter stay as they were.
fn askTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const text = argStr(args, "text") orelse return errRes(arena, .invalid_args, "agent_ask needs 'text', the question");
    if (std.mem.trim(u8, text, " \t").len == 0) return errRes(arena, .invalid_args, "text is empty");
    for (text) |ch| if (ch < 0x20 or ch == 0x7f)
        return errRes(arena, .invalid_args, "a side question is one line of text (no line breaks or control characters)");
    if (!e.agent.supports(.side_question))
        return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "the {s} adapter has no side questions (capabilities.agent_side_question lists the apps that do); agent_send asks it as a prompt", .{e.loaded.spec.id}));
    if (e.loaded.spec.screen) |sc| if (sc.paste) |p| if (p.collapses(text))
        return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "a side question is at most {d} bytes (the app would collapse a longer one into a paste its panel cannot show)", .{p.over_chars}));
    service(clock.nowMs());
    const st = e.agent.state();
    if (!st.takesSideQuestion()) return switch (st) {
        .waiting_user => errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} is waiting for an answer: its prompt has the keyboard, so nothing was typed (agent_answer it first)", .{e.id})),
        .starting => errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} is not ready yet (state starting); nothing was typed", .{e.id})),
        else => errRes(arena, .unavailable, try std.fmt.allocPrint(arena, "agent {s} is {s}; agent_close it", .{ e.id, @tagName(st) })),
    };
    const d = e.agent.driver().screen;
    if (d.sideOpen())
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} already shows a side panel (someone else's question) and it has the keyboard; nothing was typed", .{e.id}));
    if (!d.inputShowing())
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} shows no input box; nothing was typed", .{e.id}));
    if (!d.inputEmpty())
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s}'s input box holds text someone is typing; nothing was typed (it would merge with theirs)", .{e.id}));
    const t0 = clock.nowMs();
    const o = switch (try act(arena, e, .{ .side_question = text }, deadlineFrom(args, DEFAULT_WAIT_MS))) {
        .fail => |f| {
            if (!d.sideOpen()) return sendFailRes(arena, e, f);
            return sendFailRes(arena, e, .{ .code = f.code, .msg = try std.fmt.allocPrint(arena, "{s}\n(its side panel still shows and has the keyboard: Escape in its session closes it)", .{f.msg}) });
        },
        .ok => |o| o,
    };
    service(clock.nowMs());
    const answer = o.answer orelse "";
    const closed = o.side_closed orelse !d.sideOpen();
    var res = Res.init(arena);
    try res.textf("{s} answered the side question from its current context: no turn, nothing recorded (state {s})", .{ e.id, @tagName(e.agent.state()) });
    if (!closed) try res.textf("its side panel did not close and has the keyboard: {s} takes no input until it does (Escape in its session closes it)", .{e.id});
    try res.fact("agent", e.id);
    if (e.name) |n| try res.fact("name", n);
    try res.fact("app", e.loaded.spec.id);
    try res.fact("state", @tagName(e.agent.state()));
    try res.fact("question", text);
    try res.fact("answer", answer);
    try res.fact("panel_closed", closed);
    try res.fact("waited_ms", clock.nowMs() - t0);
    try block(&res, .{ .name = "answer", .body = answer });
    return res.finish();
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
    // One bounded read of every host, for `hosts` and for remote facts.
    const until = clock.nowMs() + HOST_LIST_WAIT_MS;
    _ = try readHosts(arena, until);
    if (!argBool(args, "detail")) return listCompact(arena, until);
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
        stall_after_min: ?u32,
        relaunchable: ?bool,
        gone_reason: ?[]const u8,
        facts: ?std.json.Value,
        facts_unknown: ?[]const u8,
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
        const fr = try factsOf(arena, e);
        out.* = .{
            .facts = fr.json,
            .facts_unknown = fr.unknown,
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
            .stall_after_min = e.stall.after_min,
            .relaunchable = relaunchableOf(e),
            .gone_reason = if (e.gone_why) |g| g.reasonName() else null,
        };
        try res.textf("{s} ({s}{s}{s}): {s} on {s} in {s}, up {d}s, active {s} ago, {d} undelivered event(s)", .{
            out.agent,                         out.app,                    if (model != null) ", " else "",                          model orelse "",
            out.state,                         e.host orelse "this machine", out.cwd,                                                   @divTrunc(@max(0, wall - e.started_ms), 1000),
            if (out.last_activity_ms) |x| try std.fmt.allocPrint(arena, "{d}s", .{@divTrunc(@max(0, wall - x), 1000)}) else "never", out.pending_events,
        });
        if (fr.line) |l| try res.textf("{s}: {s}", .{ out.agent, l });
    }
    try hostsReport(arena, &res, until);
    try res.raw("agents", try toJson(arena, items));
    try res.fact("count", items.len);
    try res.fact("detail", true);
    return res.finish();
}

/// agent_list's default: what an orchestrator of many agents scans each
/// turn (with 17 agents the full facts cost ~5k tokens), one line each.
fn listCompact(arena: std.mem.Allocator, until: i64) ![]const u8 {
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
        /// The newest job's last assistant message, first line, clipped.
        preview: ?[]const u8,
        facts: ?std.json.Value,
    };
    // Gone agents are one line together: id, name and whether a relaunch
    // starts them again (detail:true lists them in full).
    const Gone = struct { agent: []const u8, name: ?[]const u8, relaunchable: bool };
    var gone_list: std.ArrayList(Gone) = .empty;
    var running: std.ArrayList(*Entry) = .empty;
    for (state.entries.items) |e| {
        if (gone(e)) try gone_list.append(arena, .{ .agent = e.id, .name = e.name, .relaunchable = e.ended_ms > 0 }) else try running.append(arena, e);
    }
    const items = try arena.alloc(Item, running.items.len);
    var res = Res.init(arena);
    try res.textf("{d} agent(s){s}", .{ state.entries.items.len, if (gone_list.items.len > 0) try std.fmt.allocPrint(arena, ", {d} of them gone", .{gone_list.items.len}) else "" });
    const mono = clock.nowMs();
    for (running.items, items) |e, *out| {
        const act_ms = e.agent.lastActivityMs();
        const it = e.agent.interaction();
        const fr = try factsOf(arena, e);
        out.* = .{
            .facts = fr.json,
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
            // A glance, never a delivery: nothing is marked handed.
            .preview = if (select.newestFinal(e.agent.records())) |i| events.preview(e.agent.records()[i].text) else null,
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
        if (fr.line) |l| try w.print(", {s}", .{l});
        if (out.pending) |p| try w.print(", pending {s}: {s}", .{ p.kind, agentwait.clip(events.firstLine(p.title), 80) });
        if (out.preview) |p| try w.print("; last: {s}", .{p});
        try res.text(aw.written());
    }
    if (gone_list.items.len > 0) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("gone:");
        for (gone_list.items, 0..) |g, i| {
            try w.print("{s} {s}", .{ if (i > 0) "," else "", g.agent });
            if (g.name) |n| try w.print(" ({s})", .{n});
            if (g.relaunchable) try w.writeAll(" relaunchable");
        }
        try w.writeAll(" (agent_attach {agent, relaunch: true} starts a relaunchable one again; agent_close forgets one)");
        try res.text(aw.written());
    }
    try hostsReport(arena, &res, until);
    try res.raw("agents", try toJson(arena, items));
    try res.raw("gone", try toJson(arena, gone_list.items));
    try res.fact("count", state.entries.items.len);
    try res.fact("detail", false);
    return res.finish();
}

pub fn closeTool(arena: std.mem.Allocator, _: std.json.Value, e: *Entry) ![]const u8 {
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

/// agent_close of an agent this server does not hold: a GONE one in the
/// index is forgotten (descriptor, password, lock), which frees its name;
/// anything else is not found here, as before.
fn closeGoneTool(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    const dir = state.index_dir orelse return notFoundKey(arena, key);
    const d = (try agentindex.resolve(arena, dir, key)) orelse return notFoundKey(arena, key);
    if (d.gone_ms == 0) return notFoundKey(arena, key);
    const lp = try lockPath(arena, d.id);
    var claimed = agentindex.claim(lp, false) catch |err| switch (err) {
        error.Held => return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} is held by another live MCP server; agent_close it there", .{d.id})),
        error.LockFailed => return errRes(arena, .io_failed, "could not lock the agent in the index"),
    };
    agentindex.remove(arena, dir, d.id);
    claimed.release(lp, true);
    var res = Res.init(arena);
    try res.textf("forgot gone agent {s}{s}{s}{s}: it is out of the index and its name is free", .{ d.id, if (d.name != null) " (" else "", d.name orelse "", if (d.name != null) ")" else "" });
    try res.fact("agent", d.id);
    try res.fact("closed", true);
    try res.fact("sessions", @as([]const []const u8, &.{}));
    return res.finish();
}

fn notFoundKey(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "no agent '{s}' on this server (open: {s})", .{ key, try idList(arena) }));
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_agent_testkit = @import("mcp_agent_testkit.zig");
const live = mcp_agent_testkit.live;
const erase = mcp_agent_testkit.erase;
const ToolRig = mcp_agent_testkit.ToolRig;
const expectError = mcp_agent_testkit.expectError;
const APP_IDLE = mcp_agent_testkit.APP_IDLE;
const FakeApp = mcp_agent_testkit.FakeApp;
const shaped = mcp_agent_testkit.shaped;
const openResult = mcp_agent_open.openResult;
const newEntry = mcp_agent_open.newEntry;

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
