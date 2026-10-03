//! The status-command facts source (`adapter.StatusCommand`, Claude Code's
//! `statusLine`): `COMMAND` takes the place of the app's status command in
//! the settings document sketerm already passes, saves the JSON the app
//! hands it to a per-agent file (`FILE_ENV`) and runs the user's own
//! command (`USER_ENV`) with the same JSON, so the app shows what it
//! always showed. The user's command is looked up at launch, on the
//! agent's host, in the settings files the adapter declares.

const std = @import("std");
const adapter = @import("adapter.zig");
const launch = @import("launch.zig");
const shellquote = @import("../util/shellquote.zig");

/// The facts file the command writes (an absolute path on the agent's host).
pub const FILE_ENV = "SKETERM_AGENT_FACTS";
/// The user's own status command, absent when they have none.
pub const USER_ENV = "SKETERM_AGENT_STATUS";

/// POSIX sh: the JSON on stdin goes to `$FILE_ENV` through a temp file and
/// a rename, then to the user's command, whose output is the only output.
/// A file that cannot be written leaves stdin to the user's command.
const SCRIPT =
    "f=${" ++ FILE_ENV ++ "-} u=${" ++ USER_ENV ++ "-}\n" ++
    "if [ -n \"$f\" ] && mkdir -p -m 700 \"${f%/*}\" 2>/dev/null && (umask 077; cat >\"$f.$$\") 2>/dev/null; then\n" ++
    "  if mv -f \"$f.$$\" \"$f\" 2>/dev/null; then s=$f; else s=$f.$$; fi\n" ++
    "  [ -z \"$u\" ] || /bin/sh -c \"$u\" <\"$s\"\n" ++
    "  rm -f \"$f.$$\"\n" ++
    "elif [ -n \"$u\" ]; then exec /bin/sh -c \"$u\"\n" ++
    "fi";

/// What goes in the settings document: SCRIPT under `/bin/sh -c`, so it
/// runs the same whichever shell the app hands it to (fish included).
pub const COMMAND = "/bin/sh -c '" ++ SCRIPT ++ "'";

comptime {
    // Inside single quotes in every shell only if it has neither.
    if (std.mem.indexOfAny(u8, SCRIPT, "'\\") != null) @compileError("statusline SCRIPT must hold no single quote and no backslash");
}

/// Where agent `id`'s facts file lives under a host's runtime dir.
pub fn filePath(arena: std.mem.Allocator, run_dir: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/sketerm/agent-facts/{s}.json", .{ std.mem.trimEnd(u8, run_dir, "/"), id });
}

/// How one variable reads in the app's environment.
const EnvRead = union(enum) {
    /// The caller's `env` sets it.
    value: []const u8,
    /// The adapter's `unset_env` removes it.
    removed,
    /// Inherited from the host.
    host,
};

fn envRead(name: []const u8, x: launch.Extra, unset: []const []const u8) EnvRead {
    for (x.env) |v| if (std.mem.eql(u8, v.name, name)) return .{ .value = v.value };
    for (unset) |u| {
        const removed = if (std.mem.endsWith(u8, u, "*")) std.mem.startsWith(u8, name, u[0 .. u.len - 1]) else std.mem.eql(u8, u, name);
        if (removed) return .removed;
    }
    return .host;
}

fn baseName(path: []const u8) []const u8 {
    return path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return path) + 1 ..];
}

/// The settings files on this machine, in precedence order; null for one
/// that cannot be placed (a `~/` path without a home).
/// @param host_env the host's value of a variable (this process's environment).
pub fn localPaths(arena: std.mem.Allocator, sc: adapter.StatusCommand, cwd: []const u8, home: ?[]const u8, x: launch.Extra, unset: []const []const u8, host_env: *const fn ([]const u8) ?[]const u8) ![]const ?[]const u8 {
    const out = try arena.alloc(?[]const u8, sc.user_settings.len);
    for (sc.user_settings, out) |file, *o| {
        const dir: ?[]const u8 = if (file.dir_env) |name| switch (envRead(name, x, unset)) {
            .value => |v| v,
            .removed => null,
            .host => host_env(name),
        } else null;
        if (dir) |d| if (d.len > 0) {
            o.* = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, d, "/"), baseName(file.path) });
            continue;
        };
        const p = file.path;
        o.* = if (std.mem.startsWith(u8, p, "{cwd}/"))
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, cwd, "/"), p["{cwd}/".len..] })
        else if (std.mem.startsWith(u8, p, "~/"))
            (if (home) |h| try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, h, "/"), p[2..] }) else null)
        else
            p;
    }
    return out;
}

/// One POSIX sh snippet per settings file that sets `f` to its path on the
/// host it runs on (a remote probe's `files`), in precedence order.
/// @param cwd the agent's working dir there; null = the host's home.
pub fn probeSnippets(arena: std.mem.Allocator, sc: adapter.StatusCommand, cwd: ?[]const u8, x: launch.Extra, unset: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, sc.user_settings.len);
    for (sc.user_settings, out) |file, *o| {
        var s: std.ArrayList(u8) = .empty;
        const p = file.path;
        var default: std.ArrayList(u8) = .empty;
        if (std.mem.startsWith(u8, p, "{cwd}/")) {
            if (cwd) |d| try shellquote.appendQuoted(&default, arena, std.mem.trimEnd(u8, d, "/")) else try default.appendSlice(arena, "\"$HOME\"");
            try default.append(arena, '/');
            try shellquote.appendQuoted(&default, arena, p["{cwd}/".len..]);
        } else if (std.mem.startsWith(u8, p, "~/")) {
            try default.appendSlice(arena, "\"$HOME\"/");
            try shellquote.appendQuoted(&default, arena, p[2..]);
        } else try shellquote.appendQuoted(&default, arena, p);
        const read: EnvRead = if (file.dir_env) |name| envRead(name, x, unset) else .removed;
        switch (read) {
            .value => |v| if (v.len > 0) {
                try s.appendSlice(arena, "f=");
                try shellquote.appendQuoted(&s, arena, std.mem.trimEnd(u8, v, "/"));
                try s.append(arena, '/');
                try shellquote.appendQuoted(&s, arena, baseName(p));
            } else {
                try s.appendSlice(arena, "f=");
                try s.appendSlice(arena, default.items);
            },
            .removed => {
                try s.appendSlice(arena, "f=");
                try s.appendSlice(arena, default.items);
            },
            // `adapter` validated the name.
            .host => {
                try s.print(arena, "if [ -n \"${{{s}-}}\" ]; then f=\"${s}\"/", .{ file.dir_env.?, file.dir_env.? });
                try shellquote.appendQuoted(&s, arena, baseName(p));
                try s.appendSlice(arena, "; else f=");
                try s.appendSlice(arena, default.items);
                try s.appendSlice(arena, "; fi");
            },
        }
        o.* = s.items;
    }
    return out;
}

/// The user's own status object: the first settings file (in precedence
/// order) holding an object at `settings_path` with a command string.
/// @param contents each file's JSON text, null when it is missing.
pub fn userObject(arena: std.mem.Allocator, sc: adapter.StatusCommand, contents: []const ?[]const u8) ?std.json.ObjectMap {
    for (contents) |maybe| {
        const text = maybe orelse continue;
        const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch continue;
        var v = doc;
        for (sc.settings_path) |k| {
            v = if (v == .object) (v.object.get(k) orelse break) else break;
        } else if (v == .object) {
            const cmd = v.object.get(sc.command_key) orelse continue;
            if (cmd == .string and cmd.string.len > 0) return v.object;
        }
    }
    return null;
}

/// The user's command in their status object, if any.
pub fn userCommand(sc: adapter.StatusCommand, user: ?std.json.ObjectMap) ?[]const u8 {
    const o = user orelse return null;
    const cmd = o.get(sc.command_key) orelse return null;
    return if (cmd == .string and cmd.string.len > 0) cmd.string else null;
}

/// What a start puts in the settings document and the app's environment:
/// the user's object (else `fields`) with `COMMAND` as its command, and
/// the facts file and the user's command as variables.
/// @param user_json the user's status object as JSON text, null for none.
pub fn status(arena: std.mem.Allocator, sc: adapter.StatusCommand, facts_file: []const u8, user_json: ?[]const u8) !launch.Status {
    const user: ?std.json.ObjectMap = if (user_json) |j| blk: {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, j, .{}) catch break :blk null;
        break :blk if (v == .object) v.object else null;
    } else null;
    var obj: std.json.ObjectMap = .empty;
    for (sc.fields.map.keys(), sc.fields.map.values()) |k, v| try obj.put(arena, k, .{ .string = v });
    if (user) |u| for (u.keys(), u.values()) |k, v| {
        if (!std.mem.eql(u8, k, sc.command_key)) try obj.put(arena, k, v);
    };
    try obj.put(arena, sc.command_key, .{ .string = COMMAND });
    var env: std.ArrayList(launch.EnvVar) = .empty;
    try env.append(arena, .{ .name = FILE_ENV, .value = facts_file });
    if (userCommand(sc, user)) |cmd| try env.append(arena, .{ .name = USER_ENV, .value = cmd });
    return .{ .value = .{ .object = obj }, .env = env.items };
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const facts = @import("facts.zig");

/// `NAME=value ...` for `launch.runSh`, each value shell-quoted.
fn envOf(a: std.mem.Allocator, vars: []const launch.EnvVar) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (vars) |v| {
        try s.print(a, "{s}=", .{v.name});
        try shellquote.appendQuoted(&s, a, v.value);
        try s.append(a, ' ');
    }
    return s.items;
}

const demo = adapter.StatusCommand{
    .settings_path = &.{"statusLine"},
    .user_settings = &.{
        .{ .path = "{cwd}/.claude/settings.local.json" },
        .{ .path = "{cwd}/.claude/settings.json" },
        .{ .path = "~/.claude/settings.json", .dir_env = "CLAUDE_CONFIG_DIR" },
    },
};

fn noHostEnv(_: []const u8) ?[]const u8 {
    return null;
}

fn hostConfigDir(name: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, name, "CLAUDE_CONFIG_DIR")) "/host/cfg" else null;
}

test "settings files: precedence order, CLAUDE_CONFIG_DIR only as the app sees it" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const unset = [_][]const u8{"CLAUDE*"};
    const plain = try localPaths(a, demo, "/w/proj", "/home/u", .{}, &unset, hostConfigDir);
    try t.expectEqualStrings("/w/proj/.claude/settings.local.json", plain[0].?);
    try t.expectEqualStrings("/w/proj/.claude/settings.json", plain[1].?);
    // unset_env removes CLAUDE*: the host's value never reaches the app.
    try t.expectEqualStrings("/home/u/.claude/settings.json", plain[2].?);
    // A caller's env sets it in the app: that directory is used.
    const given = try localPaths(a, demo, "/w/proj", "/home/u", .{ .env = &.{.{ .name = "CLAUDE_CONFIG_DIR", .value = "/alt/cfg/" }} }, &unset, hostConfigDir);
    try t.expectEqualStrings("/alt/cfg/settings.json", given[2].?);
    // Nothing removes it: the host's environment decides.
    const inherited = try localPaths(a, demo, "/w/proj", null, .{}, &.{}, hostConfigDir);
    try t.expectEqualStrings("/host/cfg/settings.json", inherited[2].?);
    const homeless = try localPaths(a, demo, "/w/proj", null, .{}, &.{}, noHostEnv);
    try t.expect(homeless[2] == null);
}

test "the user's status object: the first file that has one, malformed files skipped" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = [_]?[]const u8{
        null,
        "{not json",
        "{\"permissions\":{},\"statusLine\":{\"command\":\"\"}}",
        "{\"statusLine\":{\"type\":\"command\",\"command\":\"node ~/.claude/statusline.js\",\"padding\":0}}",
        "{\"statusLine\":{\"type\":\"command\",\"command\":\"user-level\"}}",
    };
    const u = userObject(a, demo, &files).?;
    try t.expectEqualStrings("node ~/.claude/statusline.js", userCommand(demo, u).?);
    try t.expect(userObject(a, demo, &.{ null, "{}" }) == null);

    // The injected object keeps the user's keys, replaces only the command.
    const user_json = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = u }, .{});
    const with_user = try status(a, demo, "/run/sketerm/agent-facts/claude-ab12.json", user_json);
    try t.expectEqualStrings(COMMAND, with_user.value.object.get("command").?.string);
    try t.expectEqual(@as(i64, 0), with_user.value.object.get("padding").?.integer);
    try t.expectEqual(@as(usize, 2), with_user.env.len);
    try t.expectEqualStrings(FILE_ENV, with_user.env[0].name);
    try t.expectEqualStrings("node ~/.claude/statusline.js", with_user.env[1].value);
    var with_fields = demo;
    var fields: std.json.ArrayHashMap([]const u8) = .{};
    try fields.map.put(a, "type", "command");
    with_fields.fields = fields;
    const none = try status(a, with_fields, "/f.json", null);
    try t.expectEqualStrings("command", none.value.object.get("type").?.string);
    try t.expectEqual(@as(usize, 1), none.env.len);
}

test "remote snippets place every file on the host they run on" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const snips = try probeSnippets(a, demo, "/srv/my proj", .{}, &.{});
    var script: std.ArrayList(u8) = .empty;
    for (snips) |s| try script.print(a, "{s}; printf '%s\\n' \"$f\"\n", .{s});
    const out = try launch.runSh(a, "HOME=/home/r CLAUDE_CONFIG_DIR=/cfg/x", script.items);
    try t.expectEqualStrings("/srv/my proj/.claude/settings.local.json\n/srv/my proj/.claude/settings.json\n/cfg/x/settings.json\n", out);
    // No cwd: the host's home is the agent's dir; unset_env drops the variable.
    const unset = [_][]const u8{"CLAUDE*"};
    const homed = try probeSnippets(a, demo, null, .{}, &unset);
    script.clearRetainingCapacity();
    for (homed) |s| try script.print(a, "{s}; printf '%s\\n' \"$f\"\n", .{s});
    const out2 = try launch.runSh(a, "HOME=/home/r CLAUDE_CONFIG_DIR=/cfg/x", script.items);
    try t.expectEqualStrings("/home/r/.claude/settings.local.json\n/home/r/.claude/settings.json\n/home/r/.claude/settings.json\n", out2);
}

/// Run `COMMAND` like the app does: JSON on stdin, in `env`.
fn runCommand(a: std.mem.Allocator, env: []const u8, stdin_path: []const u8) ![]u8 {
    var script: std.ArrayList(u8) = .empty;
    try script.appendSlice(a, COMMAND ++ " < ");
    try shellquote.appendQuoted(&script, a, stdin_path);
    return launch.runSh(a, env, script.items);
}

test "the command saves the JSON atomically and chains the user's command with the same stdin" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try std.fmt.allocPrint(a, "/tmp/.sk_statusline_test_{d}", .{c.getpid()});
    defer pathz.removeTree(dir);
    try pathz.makeDirs(dir, 0o700);
    const sample = try std.fmt.allocPrint(a, "{s}/sample.json", .{dir});
    try atomicwrite.writeFile(sample, facts.CLAUDE_SAMPLE, 0o600);
    const out_file = try std.fmt.allocPrint(a, "{s}/run/sketerm/agent-facts/claude-ab12.json", .{dir});

    // The user's command sees the same JSON (its byte count and a field of
    // it), and what it prints is all the app shows.
    const user_cmd = "printf 'USER %s bytes ' \"$(wc -c | tr -d \" \")\"";
    const env = try envOf(a, &.{ .{ .name = FILE_ENV, .value = out_file }, .{ .name = USER_ENV, .value = user_cmd } });
    const shown = try runCommand(a, env, sample);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "USER {d} bytes ", .{facts.CLAUDE_SAMPLE.len}), shown);
    const saved = try @import("../util/readfile.zig").cappedAlloc(a, out_file, 1 << 20);
    try t.expectEqualStrings(facts.CLAUDE_SAMPLE, saved);
    // The rename left no temp file, and the directory is private.
    const listing = try launch.runSh(a, "", try std.fmt.allocPrint(a, "ls -A '{s}/run/sketerm/agent-facts'; stat -c %a '{s}/run/sketerm/agent-facts' '{s}'", .{ dir, dir, out_file }));
    try t.expectEqualStrings("claude-ab12.json\n700\n600\n", listing);

    // No user command: the file is written and nothing is printed.
    pathz.unlinkPath(out_file);
    const silent = try runCommand(a, try envOf(a, &.{.{ .name = FILE_ENV, .value = out_file }}), sample);
    try t.expectEqualStrings("", silent);
    try t.expectEqualStrings(facts.CLAUDE_SAMPLE, try @import("../util/readfile.zig").cappedAlloc(a, out_file, 1 << 20));

    // No facts file, or one that cannot be written: the user's command
    // still gets the whole JSON.
    const no_file = try runCommand(a, try envOf(a, &.{.{ .name = USER_ENV, .value = user_cmd }}), sample);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "USER {d} bytes ", .{facts.CLAUDE_SAMPLE.len}), no_file);
    const blocked = try runCommand(a, try envOf(a, &.{ .{ .name = FILE_ENV, .value = "/proc/self/nope/x.json" }, .{ .name = USER_ENV, .value = user_cmd } }), sample);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "USER {d} bytes ", .{facts.CLAUDE_SAMPLE.len}), blocked);
}
