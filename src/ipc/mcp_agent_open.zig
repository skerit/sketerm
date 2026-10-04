//! Starting agents: agent_adapters, agent_open (`openOpts`,
//! `startAgent`, the one start every relaunch goes through too), the
//! spawn of its sessions locally, on a remote daemon or over plain ssh
//! (`spawnOn`, `spawnScreen`, `spawnApi`), and agent_attach of a
//! term_open terminal. The launch-value parsers agent_set shares
//! (`retryPolicyFrom`, `stallFrom`) live here too.

const std = @import("std");
const c = @import("../c.zig").c;
const mcp = @import("mcp.zig");
const mcp_term = @import("mcp_term.zig");
const termdrive = @import("termdrive.zig");
const adapter = @import("../agent/adapter.zig");
const agent_mod = @import("../agent/agent.zig");
const vocab = @import("../agent/vocab.zig");
const launch = @import("../agent/launch.zig");
const opencode = @import("../agent/opencode.zig");
const retry_mod = @import("../agent/retry.zig");
const stall_mod = @import("../agent/stall.zig");
const statusline = @import("../agent/statusline.zig");
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
const pathz = @import("../util/pathz.zig");
const readfile = @import("../util/readfile.zig");
const transport_mod = @import("transport.zig");
const agentindex = @import("agentindex.zig");
const muxclient = @import("../mux/client.zig");
const deploy = @import("../mux/deploy.zig");
const sshroute = @import("../mux/sshroute.zig");
const Res = mcp.Res;
const errRes = mcp.errRes;
const argStr = mcp.argStr;
const argInt = mcp.argInt;
const argBool = mcp.argBool;

const mcp_agent = @import("mcp_agent.zig");
const mcp_agent_hosts = @import("mcp_agent_hosts.zig");
const mcp_agent_results = @import("mcp_agent_results.zig");
const mcp_agent_waiter = @import("mcp_agent_waiter.zig");
const mcp_agent_index = @import("mcp_agent_index.zig");
const mcp_agent_act = @import("mcp_agent_act.zig");
const mcp_agent_loop = @import("mcp_agent_loop.zig");

const DEFAULT_WAIT_MS = mcp_agent.DEFAULT_WAIT_MS;
const ATTACH_WAIT_MS = mcp_agent.ATTACH_WAIT_MS;
const DEFAULT_COLS = mcp_agent.DEFAULT_COLS;
const DEFAULT_ROWS = mcp_agent.DEFAULT_ROWS;
const Entry = mcp_agent.Entry;
const Where = mcp_agent.Where;
const hold = mcp_agent.hold;
const state = &mcp_agent.state;
const adapters = mcp_agent.adapters;
const findByName = mcp_agent.findByName;
const mintId = mcp_agent.mintId;
const localHost = mcp_agent.localHost;
const envValue = mcp_agent.envValue;
const statusCommandOf = mcp_agent.statusCommandOf;
const statusOf = mcp_agent.statusOf;
const Fail = mcp_agent.Fail;
const filterFrom = mcp_agent.filterFrom;
const deadlineFrom = mcp_agent.deadlineFrom;
const capCheck = mcp_agent_hosts.capCheck;
const Delivered = mcp_agent_results.Delivered;
const Block = mcp_agent_results.Block;
const pending = mcp_agent_results.pending;
const toJson = mcp_agent_results.toJson;
const Watch = mcp_agent_results.Watch;
const finish = mcp_agent_results.finish;
const conversationOf = mcp_agent_results.conversationOf;
const permissionsValue = mcp_agent_results.permissionsValue;
const block = mcp_agent_results.block;
const endWaitersOf = mcp_agent_waiter.endWaitersOf;
const claimNew = mcp_agent_index.claimNew;
const writeDescriptor = mcp_agent_index.writeDescriptor;
const removeDescriptor = mcp_agent_index.removeDescriptor;
const descRelaunchable = mcp_agent_index.descRelaunchable;
const publishAgents = mcp_agent_index.publishAgents;
const Prompt = mcp_agent_act.Prompt;
const promptFrom = mcp_agent_act.promptFrom;
const submitAndWait = mcp_agent_act.submitAndWait;
const Requeued = mcp_agent_act.Requeued;
const sendFailRes = mcp_agent_act.sendFailRes;
const applySet = mcp_agent_act.applySet;
const spawnForward = mcp_agent_loop.spawnForward;
const foldHistory = mcp_agent_loop.foldHistory;
const pumpFor = mcp_agent_loop.pumpFor;
const gone = mcp_agent_loop.gone;
const waitReady = mcp_agent_loop.waitReady;

/// Bound on an API server's port starting to listen.
const PORT_WAIT_MS: i64 = 20_000;
/// Bound on the remote binary probe (one ssh round trip).
const PROBE_WAIT_MS: i64 = 30_000;
/// Bound on a remote start asking for its secret.
const SECRET_WAIT_MS: i64 = 30_000;
/// Remote ports an API server is started on (the remote host's free ports
/// are not knowable from here; a taken one fails the open with the
/// server's own message).
const REMOTE_PORT_MIN: u16 = 20_000;
const REMOTE_PORT_SPAN: u16 = 40_000;

/// Largest settings file read for the user's own status command.
const SETTINGS_MAX_BYTES: usize = 1 << 20;

// ── launch values agent_open and agent_set share ─────────────────

/// agent_open's / agent_set's `retry_on_overload`: an object (`max`,
/// `backoff_s`; `max` 0 turns it off) or null for off.
pub fn retryPolicyFrom(arena: std.mem.Allocator, v: std.json.Value, why: *Fail) !?retry_mod.Policy {
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

/// agent_open's / agent_set's `stall_after_min`: minutes, 0 or null = off.
pub fn stallFrom(arena: std.mem.Allocator, v: std.json.Value, why: *Fail) !?u32 {
    const n: i64 = switch (v) {
        .null => return null,
        .integer => |x| x,
        else => -1,
    };
    if (n < 0 or n > stall_mod.MAX_MIN) {
        why.* = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "stall_after_min must be an integer 0-{d} (minutes; 0 turns it off)", .{stall_mod.MAX_MIN}) };
        return error.Refused;
    }
    return if (n == 0) null else @intCast(n);
}

/// Set `e`'s retry policy; a pending retry of a policy turned off gives up.
pub fn setRetryPolicy(e: *Entry, p: ?retry_mod.Policy) void {
    if (e.retry.policy == null and !e.retry.active) e.retry.catchUp(e.agent.queue());
    e.retry.policy = p;
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
            const res = try launch.parseProbe(arena, r.output, lookups.len, opts.files.len);
            if (r.exited and r.status_known and r.status == 0 and res.complete) return .{ .ok = res };
            if (sshroute.unreachableLine(r.output)) |said|
                return .{ .fail = .{ .code = .host_unreachable, .msg = try mcp_term.unreachableMsg(arena, host, said) } };
            return .{ .fail = .{ .code = .unavailable, .msg = try std.fmt.allocPrint(arena, "could not look the agent up on {s} over ssh (key or agent auth is required; {s}):\n{s}", .{
                host,
                if (!r.exited) "the probe did not finish in time" else "the probe failed",
                mcp.tailLines(r.output, 8),
            }) } };
        },
    }
}

pub fn adaptersTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
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

pub const OpenOpts = struct {
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
    /// `stall_after_min`; null = off.
    stall: ?u32 = null,
    /// A relaunch from this server: the content keys of what the gone
    /// entry handed out, moved into the new one (`select.Handed.texts`).
    handed: ?*std.AutoHashMapUnmanaged(u64, void) = null,
    /// The status command a screen start sets up (`startAgent` finds it on
    /// the agent's host); null: none, `facts_skipped` says why.
    status: ?StatusPlan = null,
    facts_skipped: ?[]const u8 = null,
};

/// Where a start's status command saves its document, and what it chains.
const StatusPlan = struct {
    /// The agent's host's per-user runtime dir.
    run_dir: []const u8,
    /// The user's own status object as JSON; null: they have none.
    user: ?[]const u8,
};

/// Why a start sets up no status command although the adapter has one.
const FACTS_ARG_TAKEN = "the launch args pass the app's own settings option, where the status command would go";

/// Which agent holds name (or id) `key` on this machine: this server's
/// entry, else a descriptor of the per-user index; null when it is free.
const NameHolder = struct { id: []const u8, gone: bool, relaunchable: bool };

fn nameHolder(arena: std.mem.Allocator, key: []const u8) !?NameHolder {
    if (findByName(key)) |e| return .{ .id = try arena.dupe(u8, e.id), .gone = gone(e), .relaunchable = e.ended_ms > 0 };
    const dir = state.index_dir orelse return null;
    const d = (try agentindex.resolve(arena, dir, key)) orelse return null;
    return .{ .id = d.id, .gone = d.gone_ms > 0, .relaunchable = d.gone_ms > 0 and descRelaunchable(d) };
}

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
        // Unique among this machine's agents, ids included.
        if (try nameHolder(arena, n)) |h| {
            why.* = .{ .code = .conflict, .msg = if (h.gone)
                try std.fmt.allocPrint(arena, "the name '{s}' belongs to agent {s}, which is gone{s}: agent_attach {{agent: \"{s}\", relaunch: true}} starts it again under this name, or agent_close {{agent: \"{s}\"}} forgets it and frees the name", .{ n, h.id, if (h.relaunchable) " (relaunchable)" else "", h.id, h.id })
            else
                try std.fmt.allocPrint(arena, "the name '{s}' is taken by live agent {s} on this machine (agent_attach {{agent: \"{s}\"}} resumes it); pick another", .{ n, h.id, n }) };
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
    const stall = if (mcp.argValue(args, "stall_after_min")) |v| try stallFrom(arena, v, why) else null;
    return .{
        .retry = retry,
        .stall = stall,
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

pub fn effortRefusal(arena: std.mem.Allocator, loaded: *const adapter.Loaded) ![]const u8 {
    return std.fmt.allocPrint(arena, "effort must be one of: {s}", .{try std.mem.join(arena, ", ", loaded.spec.launch.effort_values)});
}

const isDir = @import("../util/pathz.zig").isDir;

fn candidateList(arena: std.mem.Allocator, loaded: *const adapter.Loaded) ![]const u8 {
    return std.mem.join(arena, ", ", loaded.spec.launch.candidates);
}

pub fn openTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
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
    const cap_note = switch (try capCheck(arena, o.host)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => |n| n,
    };
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
    if (cap_note) |n| try notes.append(arena, n);
    const filter = filterFrom(args);

    var dv: Delivered = undefined;
    var sent = false;
    if (o.prompt) |p| {
        if (ready) {
            var none: Requeued = .{};
            switch (try submitAndWait(arena, e, p, filter, deadline, false, &.{}, &none)) {
                // Opened, but the prompt may or may not be in: an error that
                // names the agent, which stays open for the caller to look at.
                .fail => |f| if (f.code == .not_delivered) {
                    return sendFailRes(arena, e, .{ .code = f.code, .msg = try std.fmt.allocPrint(arena, "agent {s} was opened, but its prompt was not delivered: {s}", .{ e.id, f.msg }) });
                } else {
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
pub fn startAgent(arena: std.mem.Allocator, loaded: *const adapter.Loaded, o: *OpenOpts, claim: *?agentindex.Claim, bounds: StartBounds, facts: *LaunchFacts, why: *Fail) !Started {
    const started_ms = clock.nowMs();
    const name = o.override orelse loaded.spec.launch.binary;
    // Before the first connection: which login the agent's legs ride, and a
    // fresh one when sketerm's master is too old or the caller asks.
    if (o.host) |h| facts.master = try mcp_term.sshMasterCheck(arena, h, mcp_term.legs.script, bounds.fresh_login);
    // A status command (the facts source of a screen app) needs the app's
    // settings option free and the user's own command from their files.
    const status_cmd = statusCommandOf(loaded);
    if (status_cmd != null and launch.settingsArgTaken(loaded.spec.launch, o.extra)) o.facts_skipped = FACTS_ARG_TAKEN;
    const wants_status = status_cmd != null and o.facts_skipped == null;
    const binary = if (o.host) |h| blk: {
        // One probe on the host, in its login environment: the binary from
        // the adapter's candidates, its version, the dir, the home, and
        // the settings files the user's status command may be in.
        const r = switch (try probeRemote(arena, h, &.{.{ .launch = loaded.spec.launch, .override = o.override, .version = true }}, .{
            .dir = o.cwd,
            .login = o.extra.login_shell,
            .path_prepend = o.extra.path_prepend,
            .files = if (wants_status) try statusline.probeSnippets(arena, status_cmd.?, o.cwd, o.extra, loaded.spec.launch.unset_env) else &.{},
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
        if (wants_status) o.status = .{ .run_dir = r.run_dir orelse "/tmp", .user = try statusline.userJson(arena, status_cmd.?, r.files) };
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
        if (wants_status) {
            const paths = try statusline.localPaths(arena, status_cmd.?, o.cwd.?, localHost().home, o.extra, loaded.spec.launch.unset_env, envValue);
            const contents = try arena.alloc(?[]const u8, paths.len);
            for (paths, contents) |p, *ct| ct.* = if (p) |path| readfile.capped(arena, path, SETTINGS_MAX_BYTES) else null;
            o.status = .{ .run_dir = platform.runtimeDir(), .user = try statusline.userJson(arena, status_cmd.?, contents) };
        }
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
    if (o.handed) |h| {
        e.handed.texts.deinit(e.allocator);
        e.handed.texts = h.*;
        h.* = .empty;
    }
    // An adopted conversation's past was the caller's before: it is
    // history, never a first delivery (`since`/`detail:"all"` re-read it).
    if (o.resume_id != null) {
        e.history = true;
        e.history_turns = e.agent.uptake().turns;
    }
    setRetryPolicy(e, o.retry);
    e.stall.set(o.stall, clock.nowMs());
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
    if (e.history) {
        // A screen source only folds turns at a turn end; fold the
        // reprinted history now, or the first new turn delivers it.
        if (ready) try e.agent.syncHistory();
        foldHistory(e);
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
pub const LaunchFacts = struct {
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
pub fn openResult(arena: std.mem.Allocator, e: *Entry, ready: bool, sent: bool, notes: []const []const u8, dv: Delivered, watch: Watch, lf: *const LaunchFacts) ![]const u8 {
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
pub fn newUuid(a: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    if (c.getentropy(&raw, raw.len) != 0) return error.NoEntropy;
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

pub fn newEntry(loaded: *const adapter.Loaded, id: []const u8, session: []const u8, binary: []const u8, cwd: []const u8) !*Entry {
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
pub fn dropBare(e: *Entry) void {
    e.freeFields();
    state.allocator.destroy(e);
}

/// Record a terminal of `e` as `<name>.cast`. A session on a remote
/// daemon is not recorded: the daemon writes the file, on ITS host.
pub fn record(e: *Entry, t: *termdrive.Term, name: []const u8) void {
    if (t.remote_host != null) return;
    const path = mcp_term.recordNamedTerm(state.allocator, t, name) orelse return;
    e.recordings.append(state.allocator, path) catch state.allocator.free(path);
}

/// What a spawn on the agent's host needs besides the argv.
pub const SpawnSpec = struct {
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
pub fn spawnOn(arena: std.mem.Allocator, where: *Where, choice: transport_mod.Choice, argv: []const []const u8, spec: SpawnSpec, why: *Fail) !*termdrive.Term {
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
            if (muxclient.sshUnreachable().len > 0) {
                why.* = .{ .code = .host_unreachable, .msg = try mcp_term.unreachableMsg(arena, host, muxclient.sshUnreachable()) };
                return error.Refused;
            }
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
pub fn sshDiagnose(arena: std.mem.Allocator, host: []const u8) ![]const u8 {
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
    const facts_file: ?[]const u8 = if (o.status) |p| try statusline.filePath(arena, p.run_dir, id) else null;
    const x = try launch.applySettings(arena, spec, o.extra, try statusOf(arena, loaded, facts_file, if (o.status) |p| p.user else null));
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
    if (facts_file) |f| e.facts_file = try a.dupe(u8, f);
    if (o.status) |p| if (p.user) |u| {
        e.status_user = try a.dupe(u8, u);
    };
    e.facts_skipped = o.facts_skipped;
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
    const x = try launch.applySettings(arena, spec, o.extra, null);
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
        const f = spawnForward(arena, id, h, port, server_port) catch {
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

pub fn attachTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
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

/// End agent `e` and everything it owns: its sessions, waiters and index
/// entry. `e` is freed.
pub fn discard(e: *Entry) void {
    endWaitersOf(e.id, "agent closed");
    removeDescriptor(e);
    // A remote host's facts file stays: a few KB under its runtime dir.
    if (e.host == null) if (e.facts_file) |f| pathz.unlinkPath(f);
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
