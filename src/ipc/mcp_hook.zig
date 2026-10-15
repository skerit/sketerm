//! Presence from a session's own hooks and status line, never its screen.
//! `sketerm mcp hook` (a Claude Code hook command) and `sketerm mcp
//! statusline` (its status line command) find the sketerm MCP servers
//! their client started (the calling process's ancestry against the
//! registry, the walk `sketerm mcp agents` does; `--parent PID`
//! overrides) and post one `agentwait.Presence` line to each one's
//! waiter socket. The server maps it (`stateFor`) and re-registers as a
//! peer with it.
//!
//! Neither may ever hold up its client: the hook exits 0 whatever
//! happens, prints nothing on stdout (SessionStart and UserPromptSubmit
//! inject a hook's stdout into Claude's context), and bounds its whole
//! run; the status line posts without waiting on the server and then
//! runs the user's own status command with the same stdin, passing its
//! stdout through untouched.

const std = @import("std");
const c = @import("../c.zig").c;
const fdio = @import("../util/fdio.zig");
const platform = @import("../util/platform.zig");
const clock = @import("../util/clock.zig");
const env = @import("../util/env.zig");
const vocab = @import("../agent/vocab.zig");
const facts = @import("../agent/facts.zig");
const adapter = @import("../agent/adapter.zig");
const statusline = @import("../agent/statusline.zig");
const registry = @import("mcp_registry.zig");
const agentwait = @import("agentwait.zig");
const agentsline = @import("agentsline.zig");
const PeerState = vocab.PeerState;

/// The argv words after `mcp` that select these commands.
pub const HOOK_SUBCOMMAND = "hook";
pub const STATUSLINE_SUBCOMMAND = "statusline";
/// What the printed settings run (the installed `sketerm` on PATH).
pub const HOOK_COMMAND = "sketerm mcp " ++ HOOK_SUBCOMMAND;
pub const STATUSLINE_COMMAND = "sketerm mcp " ++ STATUSLINE_SUBCOMMAND;
/// `1`: say on stderr why nothing was posted.
pub const DEBUG_ENV = "SKETERM_HOOK_DEBUG";
/// Set in the user command's environment. A forwarder that finds it is
/// running as its own user command (directly or through a wrapper) and
/// stops there, so the chain never loops.
pub const NESTED_ENV = "SKETERM_STATUSLINE_FORWARDED";
/// The adapter whose facts map and settings files the status line reads.
pub const ADAPTER_ID = "claude";
/// The hook's whole run, stdin included.
pub const HOOK_BUDGET_MS: i64 = 300;
/// How long the status line waits for its stdin to end.
pub const STATUSLINE_STDIN_MS: i64 = 1_000;
/// The status line's `refreshInterval` in the printed settings.
pub const REFRESH_INTERVAL_S = 5;
/// Bigger stdin is not a hook or status line document.
const STDIN_MAX: usize = 1 << 20;

/// The hook events presence subscribes to, in the printed settings' order.
pub const HookEvent = enum {
    SessionStart,
    UserPromptSubmit,
    Stop,
    Notification,
    SessionEnd,

    /// The state the event means, null = no change; a Notification
    /// decides by its type (an unknown type changes nothing).
    pub fn state(self: HookEvent, notification: ?NotificationKind) ?PeerState {
        return switch (self) {
            .SessionStart, .Stop => .idle,
            .UserPromptSubmit => .working,
            .SessionEnd => .gone,
            .Notification => if (notification) |k| (if (k.waitsOnUser()) .waiting_user else null) else null,
        };
    }
};

/// Claude Code's `notification_type` values; a family member matches
/// every `<name>_...` type.
pub const NotificationKind = enum {
    permission_prompt,
    idle_prompt,
    elicitation,
    agent_needs_input,
    agent_completed,
    auth_success,
    quota,

    fn family(self: NotificationKind) bool {
        return switch (self) {
            .elicitation, .quota => true,
            .permission_prompt, .idle_prompt, .agent_needs_input, .agent_completed, .auth_success => false,
        };
    }

    /// The session waits for its user (a prompt is on its screen).
    pub fn waitsOnUser(self: NotificationKind) bool {
        return switch (self) {
            .permission_prompt, .idle_prompt, .elicitation => true,
            .agent_needs_input, .agent_completed, .auth_success, .quota => false,
        };
    }

    pub fn parse(name: []const u8) ?NotificationKind {
        for (std.enums.values(NotificationKind)) |k| {
            const tag = @tagName(k);
            if (k.family()) {
                if (name.len > tag.len + 1 and std.mem.startsWith(u8, name, tag) and name[tag.len] == '_') return k;
            } else if (std.mem.eql(u8, name, tag)) return k;
        }
        return null;
    }
};

/// The state a presence post means, null = no change: `state` when it
/// names a member, else its hook event's.
pub fn stateFor(p: agentwait.Presence) ?PeerState {
    if (p.state) |s| if (std.meta.stringToEnum(PeerState, s)) |st| return st;
    const ev = std.meta.stringToEnum(HookEvent, p.event) orelse return null;
    return ev.state(if (p.notification) |n| NotificationKind.parse(n) else null);
}

/// The notification type a post records as the latest, if it carries one.
pub fn notificationOf(p: agentwait.Presence) ?[]const u8 {
    if (!std.mem.eql(u8, p.event, @tagName(HookEvent.Notification))) return null;
    const n = p.notification orelse return null;
    return if (n.len > 0) n else null;
}

/// The servers the nearest of `starters` (nearest first) started that
/// listen on a waiter socket; one client may start several, all of them
/// its own.
pub fn ownServers(arena: std.mem.Allocator, entries: []const registry.Entry, starters: []const c.pid_t) ![]const registry.Entry {
    for (starters) |s| {
        var out: std.ArrayList(registry.Entry) = .empty;
        for (entries) |e| {
            if (e.ppid == s and e.agent_socket.len > 0) try out.append(arena, e);
        }
        if (out.items.len > 0) return out.items;
    }
    return &.{};
}

/// The waiter sockets of `ownServers`.
pub fn serverSockets(arena: std.mem.Allocator, entries: []const registry.Entry, starters: []const c.pid_t) ![]const []const u8 {
    const own = try ownServers(arena, entries, starters);
    const out = try arena.alloc([]const u8, own.len);
    for (own, out) |e, *o| o.* = e.agent_socket;
    return out;
}

/// The servers this process's client started, found by walking this
/// process's ancestry against the registry (`parent` overrides the walk).
/// An unreadable registry reads as none.
pub fn serversOfThisClient(arena: std.mem.Allocator, parent: ?c.pid_t) []const registry.Entry {
    var buf: [agentsline.MAX_ANCESTRY]c.pid_t = undefined;
    var one: [1]c.pid_t = undefined;
    const starters: []const c.pid_t = if (parent) |p| blk: {
        one[0] = p;
        break :blk &one;
    } else agentsline.ancestry(&buf, c.getpid(), platform.parentOf);
    const entries = registry.list(arena, false) catch return &.{};
    return ownServers(arena, entries, starters) catch &.{};
}

/// Post `line` to every server of this process's client.
/// @return how many took it.
pub fn postToServers(arena: std.mem.Allocator, parent: ?c.pid_t, line: []const u8) usize {
    var n: usize = 0;
    for (serversOfThisClient(arena, parent)) |e| n += @intFromBool(agentwait.postPresence(e.agent_socket, line));
    return n;
}

/// The hook's post for its stdin document; null when it is not one.
pub fn hookPresence(arena: std.mem.Allocator, text: []const u8) ?agentwait.Presence {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    if (doc != .object) return null;
    const ev = strAt(doc, &.{"hook_event_name"}) orelse return null;
    return .{ .event = ev, .notification = strAt(doc, &.{"notification_type"}) };
}

/// The status line's post for its stdin document: the adapter's facts
/// (`facts.map`) and the model; null when it is not JSON.
pub fn statusPresence(arena: std.mem.Allocator, map: facts.Map, text: []const u8) ?agentwait.Presence {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    if (doc != .object) return null;
    const v = facts.shipped() catch return null;
    const values = facts.read(arena, v, map, doc) catch return null;
    return .{
        .event = agentwait.STATUSLINE_EVENT,
        .facts = facts.toJson(arena, v, values) catch return null,
        .model = strAt(doc, &.{ "model", "display_name" }) orelse strAt(doc, &.{ "model", "id" }),
    };
}

fn strAt(doc: std.json.Value, path: []const []const u8) ?[]const u8 {
    var v = doc;
    for (path) |k| {
        if (v != .object) return null;
        v = v.object.get(k) orelse return null;
    }
    return if (v == .string and v.string.len > 0) v.string else null;
}

/// Read stdin to its end, giving up at `deadline_ms`.
/// @return what arrived, and whether the end was seen.
fn readStdin(arena: std.mem.Allocator, deadline_ms: i64) struct { bytes: []const u8, complete: bool } {
    var out: std.ArrayList(u8) = .empty;
    while (out.items.len <= STDIN_MAX) {
        const left = deadline_ms - clock.nowMs();
        if (left <= 0) break;
        var pfd = c.struct_pollfd{ .fd = 0, .events = c.POLLIN, .revents = 0 };
        const rc = c.poll(&pfd, 1, @intCast(@min(left, 1000)));
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            break;
        }
        if (rc == 0) continue;
        var tmp: [8192]u8 = undefined;
        const n = c.read(0, &tmp, tmp.len);
        if (n == 0) return .{ .bytes = out.items, .complete = true };
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .INTR or e == .AGAIN) continue;
            break;
        }
        out.appendSlice(arena, tmp[0..@intCast(n)]) catch break;
    }
    return .{ .bytes = out.items, .complete = false };
}

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (env.nonEmpty(DEBUG_ENV) == null) return;
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "sketerm mcp hook: " ++ fmt ++ "\n", args) catch return;
    _ = fdio.writeAll(2, line);
}

/// `--parent PID` (and the flags a command takes alone), shared by both commands.
const Opts = struct {
    parent: ?c.pid_t = null,
    user_command: ?[]const u8 = null,
    print_settings: bool = false,
    help: bool = false,
    bad: ?[]const u8 = null,

    fn parse(args: []const []const u8, comptime statusline_flags: bool) Opts {
        var o: Opts = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
                o.help = true;
            } else if (!statusline_flags and std.mem.eql(u8, a, "--print-settings")) {
                o.print_settings = true;
            } else if (std.mem.eql(u8, a, "--parent") or (statusline_flags and std.mem.eql(u8, a, "--user-command"))) {
                if (i + 1 >= args.len) {
                    o.bad = a;
                    return o;
                }
                i += 1;
                if (std.mem.eql(u8, a, "--parent")) {
                    o.parent = std.fmt.parseInt(c.pid_t, args[i], 10) catch {
                        o.bad = a;
                        return o;
                    };
                } else o.user_command = args[i];
            } else {
                o.bad = a;
                return o;
            }
        }
        return o;
    }
};

pub const HOOK_HELP =
    \\Usage: sketerm mcp hook [--parent PID]
    \\       sketerm mcp hook --print-settings
    \\
    \\A Claude Code hook command: reads the hook's JSON on stdin and reports
    \\the session's presence (working, idle, waiting on its user, gone) to the
    \\sketerm MCP server that session started, found through this process's
    \\ancestry (--parent PID: the server PID started). peer_list shows it.
    \\Prints nothing, exits 0 whatever happens, and gives up after 300 ms;
    \\SKETERM_HOOK_DEBUG=1 says on stderr why nothing was reported.
    \\--print-settings prints the hooks and statusLine settings to paste into
    \\~/.claude/settings.json.
    \\
;

pub const STATUSLINE_HELP =
    \\Usage: sketerm mcp statusline [--parent PID] [--user-command CMD]
    \\
    \\A Claude Code status line command: reports the session's facts (context
    \\use, cost, model) to the sketerm MCP server that session started, without
    \\waiting on it, then runs your own status line command with the same
    \\stdin and prints exactly what it prints. Your command is the one your
    \\Claude Code settings name (as sketerm resolves it for the agents it
    \\opens), or CMD. When that command is this one, nothing more runs.
    \\
;

/// The `hooks` and `statusLine` settings, as pasted into `~/.claude/settings.json`.
pub fn settingsJson(arena: std.mem.Allocator) ![]const u8 {
    var hook: std.json.ObjectMap = .empty;
    try hook.put(arena, "type", .{ .string = "command" });
    try hook.put(arena, "command", .{ .string = HOOK_COMMAND });
    // Never blocks the session: Claude Code does not wait for it at all.
    try hook.put(arena, "async", .{ .bool = true });
    var hook_list = std.json.Array.init(arena);
    try hook_list.append(.{ .object = hook });
    var group: std.json.ObjectMap = .empty;
    try group.put(arena, "hooks", .{ .array = hook_list });
    var hooks: std.json.ObjectMap = .empty;
    for (std.enums.values(HookEvent)) |ev| {
        var groups = std.json.Array.init(arena);
        try groups.append(.{ .object = group });
        try hooks.put(arena, @tagName(ev), .{ .array = groups });
    }
    var status: std.json.ObjectMap = .empty;
    try status.put(arena, "type", .{ .string = "command" });
    try status.put(arena, "command", .{ .string = STATUSLINE_COMMAND });
    try status.put(arena, "padding", .{ .integer = 0 });
    try status.put(arena, "refreshInterval", .{ .integer = REFRESH_INTERVAL_S });
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "hooks", .{ .object = hooks });
    try root.put(arena, "statusLine", .{ .object = status });
    return std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 })});
}

/// `sketerm mcp hook ...`.
/// @return 0, always (a usage error included): a hook must never fail its session.
pub fn hookCli(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const deadline = clock.nowMs() + HOOK_BUDGET_MS;
    platform.ignoreSigpipe();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const o = Opts.parse(args, false);
    if (o.help) {
        _ = fdio.writeAll(1, HOOK_HELP);
        return 0;
    }
    if (o.print_settings) {
        _ = fdio.writeAll(1, settingsJson(arena) catch return 0);
        return 0;
    }
    if (o.bad) |b| {
        debug("ignoring bad argument {s}", .{b});
        return 0;
    }
    const in = readStdin(arena, deadline);
    if (!in.complete) {
        debug("no complete hook JSON on stdin within {d} ms", .{HOOK_BUDGET_MS});
        return 0;
    }
    const p = hookPresence(arena, in.bytes) orelse {
        debug("stdin is not a hook document (no hook_event_name)", .{});
        return 0;
    };
    const line = agentwait.encodePresence(arena, p) catch return 0;
    if (postToServers(arena, o.parent, line) == 0) debug("no sketerm MCP server of this session took the {s} post", .{p.event});
    return 0;
}

/// `sketerm mcp statusline ...`.
/// @return the user command's exit status (0 without one).
pub fn statuslineCli(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const o = Opts.parse(args, true);
    if (o.help) {
        _ = fdio.writeAll(1, STATUSLINE_HELP);
        return 0;
    }
    if (o.bad) |b| {
        var buf: [256]u8 = undefined;
        _ = fdio.writeAll(2, std.fmt.bufPrint(&buf, "statusline: bad argument {s} (see --help)\n", .{b}) catch "statusline: bad argument\n");
        return 2;
    }
    // Run as its own user command: the outer forwarder posted and prints.
    if (env.nonEmpty(NESTED_ENV) != null) return 0;
    platform.ignoreSigpipe();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const in = readStdin(arena, clock.nowMs() + STATUSLINE_STDIN_MS);

    const set = adapter.Set.loadDefault(arena) catch adapter.Set.init(arena);
    const f: ?adapter.Facts = if (set.get(ADAPTER_ID)) |l| l.spec.facts else null;
    if (f) |ff| if (statusPresence(arena, ff.map, in.bytes)) |p| {
        if (agentwait.encodePresence(arena, p)) |line| {
            _ = postToServers(arena, o.parent, line);
        } else |_| {}
    };
    const cmd = o.user_command orelse userCommand(arena, f, in.bytes);
    return runUser(cmd orelse return 0, in.bytes, 1);
}

/// The user's own status command, resolved as the agents sketerm opens
/// get theirs (`statusline.localUserObject`), in the session's cwd.
fn userCommand(arena: std.mem.Allocator, f: ?adapter.Facts, text: []const u8) ?[]const u8 {
    const sc = (f orelse return null).status_command orelse return null;
    var cwd_buf: [4096]u8 = undefined;
    const doc_cwd: ?[]const u8 = if (std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{})) |doc| strAt(doc, &.{"cwd"}) else |_| null;
    const cwd = doc_cwd orelse (if (c.getcwd(&cwd_buf, cwd_buf.len)) |p| std.mem.span(@as([*:0]u8, @ptrCast(p))) else "/");
    const user = statusline.localUserObject(arena, sc, cwd, env.nonEmpty("HOME"), .{}, &.{}, env.nonEmptyName) catch return null;
    return statusline.userCommand(sc, user);
}

/// Run `cmd` under `/bin/sh -c` with `input` on its stdin and `out_fd` as
/// its stdout (bytes pass straight through), `NESTED_ENV` set.
/// @return its exit status (1 when it cannot run, 128+N for a signal).
pub fn runUser(cmd: []const u8, input: []const u8, out_fd: c_int) u8 {
    var zbuf: std.ArrayList(u8) = .empty;
    defer zbuf.deinit(std.heap.c_allocator);
    zbuf.appendSlice(std.heap.c_allocator, cmd) catch return 1;
    zbuf.append(std.heap.c_allocator, 0) catch return 1;
    const cmd_z: [*:0]const u8 = @ptrCast(zbuf.items.ptr);
    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return 1;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return 1;
    }
    if (pid == 0) {
        _ = c.dup2(pipe_fds[0], 0);
        if (out_fd != 1) _ = c.dup2(out_fd, 1);
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        _ = c.setenv(NESTED_ENV, "1", 1);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z };
        _ = c.execv("/bin/sh", @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.close(pipe_fds[0]);
    // A status line document fits a pipe's buffer; a command that exits
    // without reading it ends the write (EPIPE: SIGPIPE is ignored).
    _ = fdio.writeAll(pipe_fds[1], input);
    _ = c.close(pipe_fds[1]);
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0) {
        if (std.posix.errno(-1) != .INTR) return 1;
    }
    if (c.WIFEXITED(st)) return @intCast(c.WEXITSTATUS(st));
    return @intCast(128 + @as(u32, @intCast(st & 0x7f)));
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "hook mapping: every subscribed event and every notification type" {
    const P = agentwait.Presence;
    try t.expectEqual(@as(?PeerState, .idle), stateFor(P{ .event = "SessionStart" }));
    try t.expectEqual(@as(?PeerState, .working), stateFor(P{ .event = "UserPromptSubmit" }));
    try t.expectEqual(@as(?PeerState, .idle), stateFor(P{ .event = "Stop" }));
    try t.expectEqual(@as(?PeerState, .gone), stateFor(P{ .event = "SessionEnd" }));
    // Notifications: the prompts on its screen wait on the user; the rest
    // (and a type this build does not know, or none) change nothing.
    for ([_][]const u8{ "permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url" }) |n|
        try t.expectEqual(@as(?PeerState, .waiting_user), stateFor(P{ .event = "Notification", .notification = n }));
    for ([_]?[]const u8{ "agent_needs_input", "agent_completed", "auth_success", "quota_auto_resume_scheduled", "quota_auto_resume_done", "brand_new_type", "elicitation", "quota", null }) |n|
        try t.expectEqual(@as(?PeerState, null), stateFor(P{ .event = "Notification", .notification = n }));
    // Every member is reachable by its own name and decides one way.
    for (std.enums.values(NotificationKind)) |k| {
        const name = if (k.family()) try std.fmt.allocPrint(t.allocator, "{s}_x", .{@tagName(k)}) else @tagName(k);
        defer if (k.family()) t.allocator.free(name);
        try t.expectEqual(@as(?NotificationKind, k), NotificationKind.parse(name));
    }
    // Events not subscribed, and unknown ones, change nothing.
    for ([_][]const u8{ "SubagentStop", "PreCompact", "PermissionRequest", "", "stop" }) |e|
        try t.expectEqual(@as(?PeerState, null), stateFor(P{ .event = e }));
    // An explicit state wins; one this build does not know falls back.
    try t.expectEqual(@as(?PeerState, .working), stateFor(P{ .event = "Stop", .state = "working" }));
    try t.expectEqual(@as(?PeerState, .idle), stateFor(P{ .event = "Stop", .state = "dancing" }));
    // Only a Notification records its type.
    try t.expectEqualStrings("auth_success", notificationOf(P{ .event = "Notification", .notification = "auth_success" }).?);
    try t.expect(notificationOf(P{ .event = "Stop", .notification = "auth_success" }) == null);
}

test "the hook reads its event from a real hook document, nothing from others" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = hookPresence(a, "{\"session_id\":\"s\",\"transcript_path\":\"/t\",\"cwd\":\"/w\",\"hook_event_name\":\"Notification\",\"message\":\"Claude needs your permission to use Bash\",\"notification_type\":\"permission_prompt\"}").?;
    try t.expectEqualStrings("Notification", p.event);
    try t.expectEqual(@as(?PeerState, .waiting_user), stateFor(p));
    // The wire line round-trips and reads as presence, not a subscription.
    const line = try agentwait.encodePresence(a, p);
    try t.expect(std.mem.endsWith(u8, line, "\n") and std.mem.count(u8, line, "\n") == 1);
    try t.expect(agentwait.isPresence(a, std.mem.trimEnd(u8, line, "\n")));
    try t.expect(!agentwait.isPresence(a, "{\"agent\":\"claude-1\"}"));
    try t.expect(hookPresence(a, "not json") == null);
    try t.expect(hookPresence(a, "{\"cwd\":\"/w\"}") == null);
    try t.expect(hookPresence(a, "[1]") == null);
}

test "the status line maps a real Claude Code document through the claude adapter's facts" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var set = adapter.Set.init(a);
    try set.loadShipped();
    const map = set.get(ADAPTER_ID).?.spec.facts.?.map;
    const p = statusPresence(a, map, facts.CLAUDE_SAMPLE).?;
    try t.expectEqualStrings(agentwait.STATUSLINE_EVENT, p.event);
    try t.expectEqualStrings("Haiku 4.5", p.model.?);
    try t.expectEqual(@as(?PeerState, null), stateFor(p));
    // Only vocabulary names, the values the document carries.
    const obj = p.facts.?.object;
    const v = try facts.shipped();
    for (obj.keys()) |k| try t.expect(v.index(k) != null);
    try t.expectEqual(@as(f64, 14), number(obj.get("context_used_percent").?));
    try t.expectEqual(@as(f64, 200000), number(obj.get("context_window_tokens").?));
    try t.expectEqual(@as(f64, 98), number(obj.get("rate_7d_used_percent").?));
    // fromJson reads it back, so the broker's copy renders the compact line.
    const back = try facts.fromJson(a, v, p.facts.?);
    try t.expectEqualStrings("context 14%, 7d limit 98%", (try facts.compactLine(a, v, back)).?);
    // Before the first prompt: nulls are unknown, the model still known.
    const fresh = statusPresence(a, map, facts.CLAUDE_SAMPLE_FRESH).?;
    try t.expect(fresh.facts.?.object.get("context_used_percent") == null);
    try t.expectEqualStrings("Haiku 4.5", fresh.model.?);
    try t.expect(statusPresence(a, map, "garbage") == null);
}

fn number(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => -1,
    };
}

test "servers: the nearest ancestor that started one, all of its servers" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mk = struct {
        fn e(ppid: c.pid_t, sock: []const u8) registry.Entry {
            const none = @constCast(@as([]const u8, ""));
            return .{ .pid = 1, .mode = .isolated, .name = none, .profile = none, .log_dir = none, .mux_socket = none, .ppid = ppid, .agent_socket = @constCast(sock) };
        }
    }.e;
    const entries = [_]registry.Entry{ mk(30, "/s/a.sock"), mk(20, "/s/b.sock"), mk(20, "/s/c.sock"), mk(30, ""), mk(99, "/s/other.sock") };
    // node (40) -> sh (30) -> claude (20): sh is nearer and started a.
    try t.expectEqualDeep(@as([]const []const u8, &.{"/s/a.sock"}), try serverSockets(a, &entries, &.{ 40, 30, 20 }));
    // From claude itself: both of its servers.
    try t.expectEqualDeep(@as([]const []const u8, &.{ "/s/b.sock", "/s/c.sock" }), try serverSockets(a, &entries, &.{20}));
    // An ancestry that started none: nothing (another client's server is never taken).
    try t.expectEqual(@as(usize, 0), (try serverSockets(a, &entries, &.{ 41, 1 })).len);
}

test "the printed settings: every subscribed event async, the status line with its interval" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = try settingsJson(a);
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const hooks = doc.object.get("hooks").?.object;
    try t.expectEqual(std.enums.values(HookEvent).len, hooks.count());
    for (std.enums.values(HookEvent)) |ev| {
        const h = hooks.get(@tagName(ev)).?.array.items[0].object.get("hooks").?.array.items[0].object;
        try t.expectEqualStrings(HOOK_COMMAND, h.get("command").?.string);
        try t.expect(h.get("async").?.bool);
    }
    const sl = doc.object.get("statusLine").?.object;
    try t.expectEqualStrings(STATUSLINE_COMMAND, sl.get("command").?.string);
    try t.expectEqual(@as(i64, REFRESH_INTERVAL_S), sl.get("refreshInterval").?.integer);
}

/// `runUser` into a pipe; what the command printed.
fn runCaptured(a: std.mem.Allocator, cmd: []const u8, input: []const u8) !struct { out: []const u8, status: u8 } {
    var p: [2]c_int = undefined;
    if (c.pipe(&p) != 0) return error.SkipZigTest;
    const status = runUser(cmd, input, p[1]);
    _ = c.close(p[1]);
    defer _ = c.close(p[0]);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(p[0], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(a, buf[0..@intCast(n)]);
    }
    return .{ .out = out.items, .status = status };
}

test "the user's command gets the same stdin; its stdout passes through byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 1. `cat` returns the document unchanged: no newline added, none lost.
    const doc = facts.CLAUDE_SAMPLE ++ "\x00\x1b[31mtail without newline";
    const echoed = try runCaptured(a, "cat", doc);
    try t.expectEqualStrings(doc, echoed.out);
    try t.expectEqual(@as(u8, 0), echoed.status);
    // 2. Colour codes and the exit status pass through.
    const coloured = try runCaptured(a, "printf '\\033[1;34mctx\\033[0m'; exit 3", "{}");
    try t.expectEqualStrings("\x1b[1;34mctx\x1b[0m", coloured.out);
    try t.expectEqual(@as(u8, 3), coloured.status);
    // 3. The nested marker is set, so a forwarder run as its own user
    // command (directly or through a wrapper) stops at once.
    const marked = try runCaptured(a, "printf '%s' \"$" ++ NESTED_ENV ++ "\"", "");
    try t.expectEqualStrings("1", marked.out);
}

test "no user command in any settings file: none, so nothing is printed" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var set = adapter.Set.init(a);
    try set.loadShipped();
    const f = set.get(ADAPTER_ID).?.spec.facts;
    var tmpl = "/tmp/.sk_hook_XXXXXX".*;
    const root = std.mem.span(@as([*:0]u8, @ptrCast(c.mkdtemp(&tmpl) orelse return error.SkipZigTest)));
    defer @import("../util/pathz.zig").removeTree(root);
    // A project without settings: no command (HOME's files are the
    // developer's, so only the project files are looked at here).
    const sc = f.?.status_command.?;
    const project_only = adapter.StatusCommand{ .settings_path = sc.settings_path, .command_key = sc.command_key, .user_settings = sc.user_settings[0..2] };
    try t.expect(statusline.userCommand(project_only, try statusline.localUserObject(a, project_only, root, null, .{}, &.{}, env.nonEmptyName)) == null);
    // One file naming a command: that command.
    const dir = try std.fmt.allocPrint(a, "{s}/.claude", .{root});
    try @import("../util/pathz.zig").makeDirs(dir, 0o700);
    try @import("../util/atomicwrite.zig").writeFile(try std.fmt.allocPrint(a, "{s}/settings.json", .{dir}), "{\"statusLine\":{\"type\":\"command\",\"command\":\"my-line\"}}", 0o600);
    try t.expectEqualStrings("my-line", statusline.userCommand(project_only, try statusline.localUserObject(a, project_only, root, null, .{}, &.{}, env.nonEmptyName)).?);
}
