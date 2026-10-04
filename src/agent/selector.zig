//! The agent selector: the ONE grammar that names a set of agents by what
//! they are instead of by id. agent_send, agent_wait and agent_close take
//! one as their `agents` string; agent_list's `state`/`host` filters go
//! through the same parse. docs/mcp.md "Selectors" is the reference.
//!
//! `*` is every live agent; `host:<name>` the live agents on that SSH host
//! (`host:local` = this machine); `state:<state>` the agents in that state,
//! exited ones included for `state:exited`. "Live" is any state but
//! `exited`. Anything else fails closed, naming what is accepted.

const std = @import("std");
const vocab = @import("vocab.zig");

/// Every live agent of the server.
pub const EVERY = "*";
/// The prefix of a host selector, and the name of this machine in it.
pub const HOST_PREFIX = "host:";
pub const LOCAL = "local";
/// The prefix of a state selector.
pub const STATE_PREFIX = "state:";

/// The selector forms (`capabilities.agent_selectors`).
pub const FORMS = [_][]const u8{ EVERY, HOST_PREFIX ++ "<name>", STATE_PREFIX ++ "<state>" };

/// The syntax as refusals and descriptions state it.
pub const SYNTAX = "\"" ++ EVERY ++ "\" (every live agent), \"" ++ HOST_PREFIX ++ "<name>\" (the live agents on that SSH host; " ++
    HOST_PREFIX ++ LOCAL ++ " = this machine) or \"" ++ STATE_PREFIX ++ "<state>\" (the agents in that state: " ++ stateList() ++ ")";

pub const Selector = union(enum) {
    every,
    /// null = this machine.
    host: ?[]const u8,
    state: vocab.State,

    /// What an agent shows a selector.
    pub const Agent = struct {
        /// The SSH host; null = this machine.
        host: ?[]const u8,
        state: vocab.State,
    };

    pub fn matches(self: Selector, a: Agent) bool {
        return self.matchesAny(a) and (self.takesExited() or a.state != .exited);
    }

    /// Whether `a` fits, exited or not (agent_list filters; `matches` adds
    /// the liveness).
    pub fn matchesAny(self: Selector, a: Agent) bool {
        return switch (self) {
            .every => true,
            .host => |h| if (h) |want| (if (a.host) |got| std.mem.eql(u8, got, want) else false) else a.host == null,
            .state => |s| a.state == s,
        };
    }

    /// It names exited agents too (only `state:exited` does).
    pub fn takesExited(self: Selector) bool {
        return self == .state and self.state == .exited;
    }
};

pub const Parsed = union(enum) {
    ok: Selector,
    /// Why not, naming what is accepted (static or `arena`-owned).
    err: []const u8,
};

/// `text` as a selector, failing closed on anything else.
pub fn parse(arena: std.mem.Allocator, text: []const u8) !Parsed {
    if (std.mem.eql(u8, text, EVERY)) return .{ .ok = .every };
    if (std.mem.startsWith(u8, text, HOST_PREFIX)) return hostOf(arena, text[HOST_PREFIX.len..]);
    if (std.mem.startsWith(u8, text, STATE_PREFIX)) return stateOf(arena, text[STATE_PREFIX.len..]);
    return .{ .err = try std.fmt.allocPrint(arena, "'{s}' is no agent selector: a selector is " ++ SYNTAX, .{text}) };
}

/// The host selector for `name` (`local` = this machine).
pub fn hostOf(arena: std.mem.Allocator, name: []const u8) !Parsed {
    if (name.len == 0) return .{ .err = "host: needs a host name (" ++ HOST_PREFIX ++ LOCAL ++ " for this machine)" };
    _ = arena;
    return .{ .ok = .{ .host = if (std.mem.eql(u8, name, LOCAL)) null else name } };
}

/// The state selector for `name`; an unknown state lists the known ones.
pub fn stateOf(arena: std.mem.Allocator, name: []const u8) !Parsed {
    const s = std.meta.stringToEnum(vocab.State, name) orelse
        return .{ .err = try std.fmt.allocPrint(arena, "'{s}' is no agent state: one of " ++ stateList(), .{name}) };
    return .{ .ok = .{ .state = s } };
}

fn stateList() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (std.meta.fieldNames(vocab.State), 0..) |n, i| out = out ++ (if (i > 0) ", " else "") ++ n;
        return out;
    }
}

const t = std.testing;

test "selectors: every, host, state; anything else fails closed" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const here_idle: Selector.Agent = .{ .host = null, .state = .idle };
    const box_working: Selector.Agent = .{ .host = "box", .state = .working };
    const box_gone: Selector.Agent = .{ .host = "box", .state = .exited };

    const every = (try parse(a, "*")).ok;
    try t.expect(every.matches(here_idle) and every.matches(box_working) and !every.matches(box_gone));
    const box = (try parse(a, "host:box")).ok;
    try t.expect(!box.matches(here_idle) and box.matches(box_working) and !box.matches(box_gone));
    const local = (try parse(a, "host:local")).ok;
    try t.expect(local.matches(here_idle) and !local.matches(box_working));
    const exited = (try parse(a, "state:exited")).ok;
    try t.expect(exited.matches(box_gone) and !exited.matches(here_idle));
    try t.expect((try parse(a, "state:working")).ok.matches(box_working));

    const bad_state = (try parse(a, "state:busy")).err;
    try t.expect(std.mem.startsWith(u8, bad_state, "'busy' is no agent state: one of starting, "));
    try t.expect(std.mem.indexOf(u8, bad_state, "waiting_user") != null);
    try t.expect(std.mem.indexOf(u8, (try parse(a, "all")).err, "\"host:<name>\"") != null);
    try t.expect((try parse(a, "host:")) == .err);
    try t.expect((try parse(a, "")) == .err);
}
