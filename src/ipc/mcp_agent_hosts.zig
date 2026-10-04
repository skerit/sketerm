//! Hosts and facts of the `agent_*` tools: each host's memory and load
//! (`HostProbe`, read by short-lived terminals, never inline), the
//! optional per-host caps agent_open checks (`capCheck`), and an agent's
//! declared facts (`factsOf`, `capabilities.agent_facts`).

const std = @import("std");
const mcp = @import("mcp.zig");
const mcp_term = @import("mcp_term.zig");
const termdrive = @import("termdrive.zig");
const hoststats = @import("../agent/hoststats.zig");
const facts_mod = @import("../agent/facts.zig");
const clock = @import("../util/clock.zig");
const readfile = @import("../util/readfile.zig");
const Res = mcp.Res;

const mcp_agent = @import("mcp_agent.zig");
const mcp_agent_results = @import("mcp_agent_results.zig");
const mcp_agent_loop = @import("mcp_agent_loop.zig");

const Entry = mcp_agent.Entry;
const state = &mcp_agent.state;
const available = mcp_agent.available;
const adapters = mcp_agent.adapters;
const Fail = mcp_agent.Fail;
const toJson = mcp_agent_results.toJson;
const pump = mcp_agent_loop.pump;
const gone = mcp_agent_loop.gone;

// ── hosts: memory, load and the optional caps ────────────────────

/// A reading this young is reused, never probed again.
const HOST_STATS_TTL_MS: i64 = 15_000;
/// A probe that has not printed its line by then is ended: unknown.
const HOST_PROBE_MAX_MS: i64 = 15_000;
/// How long agent_list waits for readings of its hosts.
pub const HOST_LIST_WAIT_MS: i64 = 1_500;
/// How long agent_open waits for the reading its memory cap needs.
const HOST_CAP_WAIT_MS: i64 = 5_000;

/// One host's memory and load (`hoststats.SCRIPT`), read by a short-lived
/// terminal on this server's private daemon (over ssh for a remote host),
/// never inline, so a slow host costs a bounded wait and an unknown.
pub const HostProbe = struct {
    /// null = this machine (owned).
    host: ?[]u8,
    stats: ?hoststats.Stats = null,
    read_ms: i64 = 0,
    /// Why the last reading is missing, if it is (static).
    problem: []const u8 = "not read yet",
    term: ?*termdrive.Term = null,
    started_ms: i64 = 0,
    /// The last reading's whole output (owned): a remote host's probe also
    /// prints its agents' facts files (`facts_mod.probeScript`).
    output: ?[]const u8 = null,

    pub fn free(self: *HostProbe, a: std.mem.Allocator) void {
        if (self.term) |t| t.deinit();
        if (self.host) |h| a.free(h);
        if (self.output) |o| a.free(o);
        a.destroy(self);
    }

    fn same(self: *const HostProbe, host: ?[]const u8) bool {
        if (self.host == null or host == null) return self.host == null and host == null;
        return std.mem.eql(u8, self.host.?, host.?);
    }
};

fn hostProbe(host: ?[]const u8) !*HostProbe {
    for (state.hosts.items) |p| if (p.same(host)) return p;
    const a = state.allocator;
    const p = try a.create(HostProbe);
    errdefer a.destroy(p);
    p.* = .{ .host = if (host) |h| try a.dupe(u8, h) else null };
    errdefer if (p.host) |h| a.free(h);
    try state.hosts.append(a, p);
    return p;
}

/// Start a reading of `p` unless a fresh one is there or one runs.
fn kickProbe(p: *HostProbe, now_ms: i64) void {
    if (p.term != null) return;
    if (p.stats != null and now_ms - p.read_ms < HOST_STATS_TTL_MS) return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A remote host's agents' facts files ride the same reading; local
    // ones are read directly (`factsOf`).
    const argv: []const []const u8 = if (p.host) |h| blk: {
        var files: std.ArrayList(facts_mod.ProbeFile) = .empty;
        for (state.entries.items) |e| if (e.facts_file) |f| if (!gone(e) and sameHost(e.host, h)) {
            files.append(arena, .{ .id = e.id, .path = f }) catch return;
        };
        const script = std.mem.concat(arena, u8, &.{ hoststats.SCRIPT, "\n", facts_mod.probeScript(arena, files.items) catch return }) catch return;
        break :blk mcp_term.remoteShArgv(arena, h, script) catch return;
    } else &.{ "/bin/sh", "-c", hoststats.SCRIPT };
    p.term = termdrive.Term.spawnWith(state.allocator, argv, 200, 10, state.mux_sock, .{ .shell_integration = false }) catch {
        p.problem = "its probe could not be started";
        return;
    };
    p.started_ms = now_ms;
}

pub fn serviceHostProbes(now_ms: i64) void {
    for (state.hosts.items) |p| {
        const t = p.term orelse continue;
        t.drain();
        if (t.exited) {
            const text = t.readScreen(true) catch "";
            if (p.output) |o| state.allocator.free(o);
            p.output = null;
            if (text.len > 0) p.output = text;
            if (hoststats.parse(text)) |st| {
                p.stats = st;
                p.read_ms = now_ms;
                p.problem = if (st.empty()) "it gave no numbers" else "";
            } else p.problem = "it did not answer the probe (ssh failed?)";
        } else if (now_ms - p.started_ms < HOST_PROBE_MAX_MS) continue else {
            p.problem = "its probe did not finish in time";
        }
        t.deinit();
        p.term = null;
    }
}

/// Wait up to `max_ms` for the probes of `list` that run.
fn waitProbes(list: []const *HostProbe, max_ms: i64) void {
    const until = clock.nowMs() + max_ms;
    while (clock.nowMs() < until) {
        var running = false;
        for (list) |p| running = running or p.term != null;
        if (!running) return;
        pump(until - clock.nowMs());
    }
}

const sameHost = @import("../util/strz.zig").eqOpt;

/// This server's live (not gone) agents on `host`.
fn agentsOn(host: ?[]const u8) u32 {
    var n: u32 = 0;
    for (state.entries.items) |e| {
        if (!gone(e) and sameHost(e.host, host)) n += 1;
    }
    return n;
}

/// Every host this server has live agents on, each with its probe kicked
/// (a reading at most `HOST_STATS_TTL_MS` old is kept) and waited for
/// until `until`: agent_list reads hosts once, for `hosts` and for the
/// facts files of remote agents alike.
pub fn readHosts(arena: std.mem.Allocator, until: i64) !struct { hosts: []const ?[]const u8, probes: []const *HostProbe } {
    var hosts: std.ArrayList(?[]const u8) = .empty;
    for (state.entries.items) |e| {
        if (gone(e)) continue;
        for (hosts.items) |h| {
            if (sameHost(h, e.host)) break;
        } else try hosts.append(arena, e.host);
    }
    const probes = try arena.alloc(*HostProbe, hosts.items.len);
    const now = clock.nowMs();
    for (hosts.items, probes) |h, *p| {
        p.* = try hostProbe(h);
        kickProbe(p.*, now);
    }
    waitProbes(probes, @max(0, until - clock.nowMs()));
    return .{ .hosts = hosts.items, .probes = probes };
}

/// agent_list's `hosts`: one line per host this server has agents on,
/// with its agent count, available memory and load (unknown when the host
/// cannot say), from `readHosts`.
pub fn hostsReport(arena: std.mem.Allocator, res: *Res, until: i64) !void {
    const read = try readHosts(arena, until);
    const hosts = read.hosts;
    const probes = read.probes;
    const Item = struct {
        host: []const u8,
        agents: u32,
        mem_available_mb: ?u64 = null,
        mem_total_mb: ?u64 = null,
        load: ?[3]?f64 = null,
        /// Seconds since the reading; null = none.
        age_s: ?i64 = null,
        unknown: ?[]const u8 = null,
    };
    const items = try arena.alloc(Item, probes.len);
    const later = clock.nowMs();
    for (hosts, probes, items) |h, p, *it| {
        it.* = .{ .host = h orelse "local", .agents = agentsOn(h) };
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("host {s}: {d} agent(s)", .{ it.host, it.agents });
        if (p.stats) |st| {
            it.mem_available_mb = st.availMb();
            it.mem_total_mb = st.totalMb();
            it.load = .{ st.load1, st.load5, st.load15 };
            it.age_s = @divTrunc(later - p.read_ms, 1000);
            if (st.availMb()) |m| try w.print(", {d} MB available", .{m}) else try w.writeAll(", memory unknown");
            if (st.totalMb()) |m| try w.print(" of {d} MB", .{m});
            if (st.load1) |l| try w.print(", load {d:.2} {d:.2} {d:.2}", .{ l, st.load5 orelse 0, st.load15 orelse 0 }) else try w.writeAll(", load unknown");
        } else {
            it.unknown = p.problem;
            try w.print(", memory and load unknown ({s})", .{p.problem});
        }
        try res.text(aw.written());
    }
    try res.raw("hosts", try toJson(arena, items));
}

/// Whether opening one more agent on `host` crosses a cap; `ok` carries a
/// note when the memory cap could not be checked.
pub fn capCheck(arena: std.mem.Allocator, host: ?[]const u8) !union(enum) { ok: ?[]const u8, fail: Fail } {
    const where = host orelse "this machine";
    if (state.max_per_host > 0) {
        const n = agentsOn(host);
        if (n >= state.max_per_host)
            return .{ .fail = .{ .code = .refused, .msg = try std.fmt.allocPrint(arena, "{s} already runs {d} agent(s) of this server, the cap (mcp_agent_max_per_host = {d}); close or wait for one, or raise the cap", .{ where, n, state.max_per_host }) } };
    }
    if (state.min_free_mb == 0) return .{ .ok = null };
    const p = try hostProbe(host);
    kickProbe(p, clock.nowMs());
    waitProbes(&.{p}, HOST_CAP_WAIT_MS);
    const avail = if (p.stats) |st| st.availMb() else null;
    const mb = avail orelse return .{ .ok = try std.fmt.allocPrint(arena, "the memory cap (mcp_agent_min_free_mb = {d}) was not checked: {s}'s available memory is unknown ({s})", .{ state.min_free_mb, where, if (p.stats == null) p.problem else "it gave no number" }) };
    if (mb < state.min_free_mb)
        return .{ .fail = .{ .code = .refused, .msg = try std.fmt.allocPrint(arena, "{s} has {d} MB available, below the cap (mcp_agent_min_free_mb = {d}); free memory there or lower the cap", .{ where, mb, state.min_free_mb }) } };
    return .{ .ok = null };
}

// ── facts ────────────────────────────────────────────────────────

/// Largest facts file read.
const FACTS_MAX_BYTES: usize = 256 * 1024;

/// `capabilities.agent_facts`: the vocabulary (type, meaning, compact
/// label per name) and the names each loaded adapter can give.
pub fn factsCapability(arena: std.mem.Allocator) !std.json.Value {
    var out: std.json.ObjectMap = .empty;
    var vocab_obj: std.json.ObjectMap = .empty;
    var by_adapter: std.json.ObjectMap = .empty;
    if (facts_mod.shipped()) |v| {
        for (v.names, v.decls) |n, d| {
            var o: std.json.ObjectMap = .empty;
            try o.put(arena, "type", .{ .string = @tagName(d.type) });
            try o.put(arena, "meaning", .{ .string = d.meaning });
            if (d.compact) |cp| try o.put(arena, "compact", .{ .string = cp });
            try vocab_obj.put(arena, n, .{ .object = o });
        }
        if (available()) {
            const set = try adapters();
            for (set.items.items) |l| {
                var names = std.json.Array.init(arena);
                if (l.spec.facts) |f| for (try facts_mod.provided(arena, v, f.map)) |n| try names.append(.{ .string = n });
                try by_adapter.put(arena, l.spec.id, .{ .array = names });
            }
        }
    } else |_| {}
    try out.put(arena, "facts", .{ .object = vocab_obj });
    try out.put(arena, "adapters", .{ .object = by_adapter });
    return .{ .object = out };
}

/// An agent's facts as its source says them now: known values, or why
/// there are none.
const FactsRead = struct {
    /// The known ones as a JSON object; null when none is known.
    json: ?std.json.Value = null,
    /// The `compact`-labelled ones on one line (`facts_mod.compactLine`).
    line: ?[]const u8 = null,
    /// Why nothing is known (agent_list detail's `facts_unknown`).
    unknown: ?[]const u8 = null,
};

/// Read `e`'s facts. Never waits: a local status command's file is read
/// directly, a remote one from its host's last probe (kicked here when
/// stale), an API source's from what its event stream already gave.
pub fn factsOf(arena: std.mem.Allocator, e: *Entry) !FactsRead {
    const decl = e.loaded.spec.facts orelse return .{ .unknown = "its adapter declares no facts" };
    const vocab_f = facts_mod.shipped() catch return .{ .unknown = "data/agents/facts.json does not load" };
    const values: facts_mod.Values = switch (e.agent.source) {
        .opencode_api => |*api| blk: {
            const doc = (api.factsDocument(arena) catch null) orelse return .{ .unknown = "no answer has reported token counts yet" };
            break :blk try facts_mod.read(arena, vocab_f, decl.map, doc);
        },
        .screen => blk: {
            const path = e.facts_file orelse return .{ .unknown = e.facts_skipped orelse "no status command was set up at its start (an older sketerm opened it)" };
            const text = if (e.host == null)
                readfile.capped(arena, path, FACTS_MAX_BYTES) orelse return .{ .unknown = "the app has not run its status command yet" }
            else remote: {
                const p = try hostProbe(e.host);
                kickProbe(p, clock.nowMs());
                const out = p.output orelse return .{ .unknown = try std.fmt.allocPrint(arena, "its host has not been read yet ({s})", .{p.problem}) };
                const content = facts_mod.probeContent(out, e.id) orelse return .{ .unknown = "its host has not been read since the agent started" };
                if (content.len == 0) return .{ .unknown = "the app has not run its status command yet" };
                break :remote content;
            };
            break :blk (try facts_mod.readText(arena, vocab_f, decl.map, text)) orelse return .{ .unknown = "its facts file is not JSON" };
        },
    };
    const json = try facts_mod.toJson(arena, vocab_f, values);
    if (json.object.count() == 0) return .{ .unknown = "the app has reported none of them yet" };
    return .{ .json = json, .line = try facts_mod.compactLine(arena, vocab_f, values) };
}
