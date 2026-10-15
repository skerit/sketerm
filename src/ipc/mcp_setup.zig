//! `sketerm mcp setup`: merges sketerm's Claude Code and opencode
//! integration into one user's config, adding only what is missing.
//!
//! Generic on purpose (a public workspace bootstrap runs it for every
//! user): nothing user-specific is written, the MCP server is registered
//! as plain `sketerm mcp` on PATH. Never rewrites `.claude.json`, which
//! Claude Code rewrites while it runs: it is only read, and `claude mcp
//! add` registers the server.

const std = @import("std");
const c = @import("../c.zig").c;
const env = @import("../util/env.zig");
const fdio = @import("../util/fdio.zig");
const pathz = @import("../util/pathz.zig");
const readfile = @import("../util/readfile.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const shellquote = @import("../util/shellquote.zig");
const sharedata = @import("../util/sharedata.zig");
const mcp_hook = @import("mcp_hook.zig");

pub const SUBCOMMAND = "setup";
/// Denied so sketerm's peer bus, not Claude Code's own session discovery, finds other sessions.
pub const DENIED_TOOL = "ListAgents";
pub const SERVER_NAME = "sketerm";
pub const PLUGIN_FILE = "sketerm-agents.js";
const PLUGIN_REL = "opencode/" ++ PLUGIN_FILE;
/// `claude mcp add` arguments: the server is whatever `sketerm` is on PATH.
const CLAUDE_ADD = [_][]const u8{ "mcp", "add", "--scope", "user", SERVER_NAME, "--", "sketerm", "mcp" };
/// Claude Code reads `refreshInterval` in seconds; above this it was written in milliseconds.
const MAX_REFRESH_S = 600;
const FILE_CAP = 64 << 20;

pub const HELP =
    \\Usage: sketerm mcp setup [--user] [--config-dir DIR] [--dry-run]
    \\
    \\Merges sketerm's integration into this user's Claude Code and opencode
    \\config, adding only what is missing: the presence hooks and the status
    \\line of `sketerm mcp hook --print-settings` (a status line command of
    \\your own keeps running, wrapped with --user-command), ListAgents in
    \\permissions.deny, the sketerm MCP server (`claude mcp add --scope user`,
    \\unless it is registered already or a project's .mcp.json has it) and,
    \\when opencode's config directory exists, a link to the opencode plugin
    \\in its plugin/ directory. Settings: DIR/settings.json, else
    \\$CLAUDE_CONFIG_DIR/settings.json, else ~/.claude/settings.json; a file
    \\that is not plain JSON is left untouched (exit 1). --dry-run prints the
    \\changes and writes nothing. --user is the default and only scope.
    \\
;

const Whitespace = @FieldType(std.json.Stringify.Options, "whitespace");

pub const Merged = union(enum) {
    /// `text` is the new file, null when nothing changed.
    done: struct { text: ?[]const u8, changes: []const []const u8 },
    refused: []const u8,
};

/// Merge sketerm's settings into the settings file text `existing` (null: no file), keeping key order and indent width.
pub fn mergeSettings(arena: std.mem.Allocator, existing: ?[]const u8) !Merged {
    const src = existing orelse "";
    const blank = std.mem.trim(u8, src, " \t\r\n").len == 0;
    var root: std.json.Value = if (blank) .{ .object = .empty } else std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{ .parse_numbers = false }) catch
        return .{ .refused = "it is not plain JSON (comments? trailing commas?); merge `sketerm mcp hook --print-settings` by hand" };
    if (root != .object) return .{ .refused = "it does not hold a JSON object" };
    var changes: std.ArrayList([]const u8) = .empty;
    if (try mergeHooks(arena, &root.object, &changes)) |why| return .{ .refused = why };
    if (try mergeStatusLine(arena, &root.object, &changes)) |why| return .{ .refused = why };
    if (try mergeDeny(arena, &root.object, &changes)) |why| return .{ .refused = why };
    if (changes.items.len == 0) return .{ .done = .{ .text = null, .changes = &.{} } };
    const newline = blank or std.mem.endsWith(u8, src, "\n");
    const text = try std.fmt.allocPrint(arena, "{f}{s}", .{ std.json.fmt(root, .{ .whitespace = whitespaceOf(src) }), if (newline) "\n" else "" });
    return .{ .done = .{ .text = text, .changes = changes.items } };
}

/// The object at `key`, created when absent or null.
/// @return null when `key` holds something else.
fn objectAt(arena: std.mem.Allocator, parent: *std.json.ObjectMap, key: []const u8) !?*std.json.ObjectMap {
    const gop = try parent.getOrPut(arena, key);
    if (!gop.found_existing or gop.value_ptr.* == .null) gop.value_ptr.* = .{ .object = .empty };
    return if (gop.value_ptr.* == .object) &gop.value_ptr.object else null;
}

/// The list at `key`, created when absent or null.
/// @return null when `key` holds something else.
fn arrayAt(arena: std.mem.Allocator, parent: *std.json.ObjectMap, key: []const u8) !?*std.json.Array {
    const gop = try parent.getOrPut(arena, key);
    if (!gop.found_existing or gop.value_ptr.* == .null) gop.value_ptr.* = .{ .array = std.json.Array.init(arena) };
    return if (gop.value_ptr.* == .array) &gop.value_ptr.array else null;
}

fn mergeHooks(arena: std.mem.Allocator, root: *std.json.ObjectMap, changes: *std.ArrayList([]const u8)) !?[]const u8 {
    const hooks = (try objectAt(arena, root, "hooks")) orelse return "hooks is not an object";
    var added: std.ArrayList(u8) = .empty;
    for (std.enums.values(mcp_hook.HookEvent)) |ev| {
        const groups = (try arrayAt(arena, hooks, @tagName(ev))) orelse
            return try std.fmt.allocPrint(arena, "hooks.{s} is not a list", .{@tagName(ev)});
        if (hasHook(groups.items)) continue;
        try groups.append(try mcp_hook.hookGroup(arena));
        if (added.items.len > 0) try added.appendSlice(arena, ", ");
        try added.appendSlice(arena, @tagName(ev));
    }
    if (added.items.len > 0) try changes.append(arena, try std.fmt.allocPrint(arena, "added hooks: {s}", .{added.items}));
    return null;
}

/// Whether one of the hook groups `groups` already runs `sketerm mcp hook`.
fn hasHook(groups: []const std.json.Value) bool {
    for (groups) |g| {
        if (g != .object) continue;
        const list = g.object.get("hooks") orelse continue;
        if (list != .array) continue;
        for (list.array.items) |h| {
            if (h != .object) continue;
            const cmd = h.object.get("command") orelse continue;
            if (cmd == .string and mcp_hook.runsSubcommand(cmd.string, mcp_hook.HOOK_SUBCOMMAND)) return true;
        }
    }
    return false;
}

fn mergeStatusLine(arena: std.mem.Allocator, root: *std.json.ObjectMap, changes: *std.ArrayList([]const u8)) !?[]const u8 {
    const gop = try root.getOrPut(arena, "statusLine");
    if (!gop.found_existing or gop.value_ptr.* == .null) {
        gop.value_ptr.* = try mcp_hook.statusLineSetting(arena);
        try changes.append(arena, "set status line: " ++ mcp_hook.STATUSLINE_COMMAND);
        return null;
    }
    if (gop.value_ptr.* != .object) return "statusLine is not an object";
    const sl = &gop.value_ptr.object;
    const cmd = sl.getPtr("command") orelse return "statusLine has no command";
    if (cmd.* != .string) return "statusLine.command is not a string";
    if (!mcp_hook.runsSubcommand(cmd.string, mcp_hook.STATUSLINE_SUBCOMMAND)) {
        const theirs = cmd.string;
        var wrapped: std.ArrayList(u8) = .empty;
        try wrapped.appendSlice(arena, mcp_hook.STATUSLINE_COMMAND ++ " --user-command ");
        try shellquote.appendAlwaysQuoted(&wrapped, arena, theirs);
        cmd.* = .{ .string = wrapped.items };
        try changes.append(arena, try std.fmt.allocPrint(arena, "wrapped your status line: {s}", .{theirs}));
    }
    if (sl.getPtr("refreshInterval")) |ri| {
        const n = numberOf(ri.*) orelse return "statusLine.refreshInterval is not a number";
        if (n > MAX_REFRESH_S) {
            const secs: i64 = @intFromFloat(@max(1, @round(@min(n, 1e9) / 1000)));
            try changes.append(arena, try std.fmt.allocPrint(arena, "converted statusLine.refreshInterval {f} to {d}: Claude Code reads it in seconds, so it was almost certainly milliseconds", .{ std.json.fmt(ri.*, .{}), secs }));
            ri.* = .{ .integer = secs };
        }
    } else {
        try sl.put(arena, "refreshInterval", .{ .integer = mcp_hook.REFRESH_INTERVAL_S });
        try changes.append(arena, std.fmt.comptimePrint("set statusLine.refreshInterval to {d} (seconds)", .{mcp_hook.REFRESH_INTERVAL_S}));
    }
    return null;
}

fn numberOf(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn mergeDeny(arena: std.mem.Allocator, root: *std.json.ObjectMap, changes: *std.ArrayList([]const u8)) !?[]const u8 {
    const perms = (try objectAt(arena, root, "permissions")) orelse return "permissions is not an object";
    const deny = (try arrayAt(arena, perms, "deny")) orelse return "permissions.deny is not a list";
    for (deny.items) |rule| {
        if (rule == .string and std.mem.eql(u8, rule.string, DENIED_TOOL)) return null;
    }
    try deny.append(.{ .string = DENIED_TOOL });
    try changes.append(arena, "added deny " ++ DENIED_TOOL);
    return null;
}

/// The indent style of the JSON text `src`: its first indented line's, 2 spaces for an empty file.
fn whitespaceOf(src: []const u8) Whitespace {
    if (std.mem.trim(u8, src, " \t\r\n").len == 0) return .indent_2;
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse return .minified;
    const rest = src[nl + 1 ..];
    if (rest.len > 0 and rest[0] == '\t') return .indent_tab;
    var n: usize = 0;
    while (n < rest.len and rest[n] == ' ') n += 1;
    return switch (n) {
        1 => .indent_1,
        3 => .indent_3,
        4 => .indent_4,
        8 => .indent_8,
        else => .indent_2,
    };
}

pub const Paths = struct {
    settings: []const u8,
    /// `.claude.json`, where Claude Code keeps user-scoped MCP servers.
    registry: []const u8,
};

/// The Claude Code files setup reads: `--config-dir`, else `$CLAUDE_CONFIG_DIR`, else `~/.claude` (registry `~/.claude.json`).
pub fn claudePaths(arena: std.mem.Allocator, config_dir: ?[]const u8, claude_config_dir: ?[]const u8, home: []const u8) !Paths {
    if (config_dir orelse claude_config_dir) |dir| return .{
        .settings = try std.fs.path.join(arena, &.{ dir, "settings.json" }),
        .registry = try std.fs.path.join(arena, &.{ dir, ".claude.json" }),
    };
    return .{
        .settings = try std.fs.path.join(arena, &.{ home, ".claude", "settings.json" }),
        .registry = try std.fs.path.join(arena, &.{ home, ".claude.json" }),
    };
}

/// opencode's user config directory: `$OPENCODE_CONFIG_DIR`, else `$XDG_CONFIG_HOME/opencode`, else `~/.config/opencode`.
pub fn opencodeDir(arena: std.mem.Allocator, opencode_config_dir: ?[]const u8, xdg_config_home: ?[]const u8, home: []const u8) ![]const u8 {
    if (opencode_config_dir) |d| return d;
    if (xdg_config_home) |x| return std.fs.path.join(arena, &.{ x, "opencode" });
    return std.fs.path.join(arena, &.{ home, ".config", "opencode" });
}

/// Runs `claude` with `args` (`CLAUDE_CONFIG_DIR=config_dir` when set).
/// @return its exit status.
pub const Claude = *const fn (args: []const []const u8, config_dir: ?[]const u8) u8;

pub const Options = struct {
    dry_run: bool = false,
    paths: Paths,
    /// `--config-dir`, handed to `claude mcp add`.
    config_dir: ?[]const u8 = null,
    opencode_dir: []const u8,
    /// Where a project-scoped `.mcp.json` is looked for, then in each parent.
    cwd: []const u8,
    /// Null: `claude` is not on PATH.
    claude: ?Claude,
    /// The shipped opencode plugin (absolute); null when it cannot be found.
    plugin: ?[]const u8,
};

pub const Outcome = struct {
    lines: []const []const u8,
    /// A file was left untouched, or a step failed.
    failed: bool,
};

const Report = struct {
    arena: std.mem.Allocator,
    lines: std.ArrayList([]const u8) = .empty,
    changes: usize = 0,
    failed: bool = false,

    fn change(self: *Report, line: []const u8) !void {
        self.changes += 1;
        try self.lines.append(self.arena, line);
    }

    fn note(self: *Report, line: []const u8) !void {
        try self.lines.append(self.arena, line);
    }

    fn fail(self: *Report, line: []const u8) !void {
        self.failed = true;
        try self.lines.append(self.arena, line);
    }
};

/// Run every step; with `dry_run` nothing is written or run.
pub fn setup(arena: std.mem.Allocator, o: Options) !Outcome {
    var r: Report = .{ .arena = arena };
    if (o.dry_run) try r.note("dry run: nothing is written or run");
    try configureSettings(arena, o, &r);
    try registerServer(arena, o, &r);
    try linkPlugin(arena, o, &r);
    if (r.changes == 0 and !r.failed) try r.note("already set up");
    return .{ .lines = r.lines.items, .failed = r.failed };
}

fn errnoText() []const u8 {
    return std.mem.span(c.strerror(std.c._errno().*));
}

fn configureSettings(arena: std.mem.Allocator, o: Options, r: *Report) !void {
    const path = o.paths.settings;
    var zbuf: [4096]u8 = undefined;
    const pz = pathz.pathZ(&zbuf, path) catch return r.fail(try std.fmt.allocPrint(arena, "{s}: path too long", .{path}));
    var st: c.struct_stat = undefined;
    var real = path;
    var existing: ?[]const u8 = null;
    if (c.lstat(pz, &st) == 0) {
        // A link (a dotfiles repository's) stays a link: the write goes to its target.
        var real_buf: [4096]u8 = undefined;
        if (c.realpath(pz, @ptrCast(&real_buf)) == null)
            return r.fail(try std.fmt.allocPrint(arena, "{s}: left untouched, it cannot be resolved ({s})", .{ path, errnoText() }));
        real = try arena.dupe(u8, std.mem.sliceTo(&real_buf, 0));
        existing = readfile.cappedAlloc(arena, real, FILE_CAP) catch |err|
            return r.fail(try std.fmt.allocPrint(arena, "{s}: left untouched, it cannot be read ({s})", .{ path, @errorName(err) }));
    } else if (std.c._errno().* != c.ENOENT) {
        return r.fail(try std.fmt.allocPrint(arena, "{s}: left untouched, it cannot be read ({s})", .{ path, errnoText() }));
    }
    const merged = try mergeSettings(arena, existing);
    const done = switch (merged) {
        .refused => |why| return r.fail(try std.fmt.allocPrint(arena, "{s}: left untouched, since {s}", .{ path, why })),
        .done => |d| d,
    };
    for (done.changes) |line| try r.change(line);
    const text = done.text orelse return;
    if (o.dry_run) return;
    if (existing == null) pathz.makeParentDirs(real) catch {};
    // A new file gets the mode the user's umask gives; an existing one keeps its own.
    const mask = c.umask(0);
    _ = c.umask(mask);
    atomicwrite.writeFile(real, text, 0o666 & ~@as(u32, @intCast(mask))) catch |err|
        return r.fail(try std.fmt.allocPrint(arena, "{s}: could not be written ({s})", .{ path, @errorName(err) }));
}

/// Whether the JSON file at `path` names the server under `mcpServers`.
fn namesServer(arena: std.mem.Allocator, path: []const u8) bool {
    const bytes = readfile.cappedAlloc(arena, path, FILE_CAP) catch return false;
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return false;
    if (doc != .object) return false;
    const servers = doc.object.get("mcpServers") orelse return false;
    return servers == .object and servers.object.contains(SERVER_NAME);
}

/// The nearest `.mcp.json` from `cwd` up that registers the server, or null.
fn projectServer(arena: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    var dir = cwd;
    while (true) {
        const file = try std.fs.path.join(arena, &.{ dir, ".mcp.json" });
        if (namesServer(arena, file)) return file;
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

fn claudeAddLine(arena: std.mem.Allocator) ![]const u8 {
    return std.mem.join(arena, " ", &([_][]const u8{"claude"} ++ CLAUDE_ADD));
}

fn registerServer(arena: std.mem.Allocator, o: Options, r: *Report) !void {
    if (namesServer(arena, o.paths.registry)) return;
    if (try projectServer(arena, o.cwd)) |file|
        return r.note(try std.fmt.allocPrint(arena, "MCP server " ++ SERVER_NAME ++ " is project-scoped in {s}; no user-scoped one added", .{file}));
    const run = o.claude orelse
        return r.note(try std.fmt.allocPrint(arena, "claude is not on PATH; register the MCP server with: {s}", .{try claudeAddLine(arena)}));
    if (o.dry_run) return r.change(try std.fmt.allocPrint(arena, "would run: {s}", .{try claudeAddLine(arena)}));
    const status = run(&CLAUDE_ADD, o.config_dir);
    if (status == 0) return r.change("registered MCP server " ++ SERVER_NAME);
    try r.fail(try std.fmt.allocPrint(arena, "{s} failed (exit {d})", .{ try claudeAddLine(arena), status }));
}

fn linkPlugin(arena: std.mem.Allocator, o: Options, r: *Report) !void {
    if (!pathz.isDir(o.opencode_dir)) return;
    const src = o.plugin orelse
        return r.note("opencode plugin " ++ PLUGIN_FILE ++ " is not installed (share/sketerm/" ++ PLUGIN_REL ++ "); not linked");
    const dir = try std.fs.path.join(arena, &.{ o.opencode_dir, "plugin" });
    const link = try std.fs.path.join(arena, &.{ dir, PLUGIN_FILE });
    const link_z = try arena.dupeZ(u8, link);
    var st: c.struct_stat = undefined;
    var was: ?[]const u8 = null;
    if (c.lstat(link_z.ptr, &st) == 0) {
        if ((st.st_mode & c.S_IFMT) != c.S_IFLNK)
            return r.note(try std.fmt.allocPrint(arena, "{s} is not a symlink; left alone", .{link}));
        var buf: [4096]u8 = undefined;
        const n = c.readlink(link_z.ptr, &buf, buf.len);
        if (n >= 0 and std.mem.eql(u8, buf[0..@intCast(n)], src)) return;
        was = if (n >= 0) try arena.dupe(u8, buf[0..@intCast(n)]) else "?";
    }
    const line = if (was) |w|
        try std.fmt.allocPrint(arena, "relinked opencode plugin: {s} -> {s} (was {s})", .{ link, src, w })
    else
        try std.fmt.allocPrint(arena, "linked opencode plugin: {s} -> {s}", .{ link, src });
    if (o.dry_run) return r.change(line);
    pathz.makeDirs(dir, 0o755) catch return r.fail(try std.fmt.allocPrint(arena, "{s}: cannot be created", .{dir}));
    // Staged and renamed over, so a stale link is replaced in one step.
    var stage_buf: atomicwrite.StageBuf = undefined;
    const stage = try atomicwrite.stagePath(&stage_buf, link);
    const src_z = try arena.dupeZ(u8, src);
    if (c.symlink(src_z.ptr, stage.ptr) != 0 or c.rename(stage.ptr, link_z.ptr) != 0) {
        const why = errnoText();
        _ = c.unlink(stage.ptr);
        return r.fail(try std.fmt.allocPrint(arena, "{s}: cannot be linked ({s})", .{ link, why }));
    }
    try r.change(line);
}

/// The real `Claude`: `claude` on PATH, its stdout sent to stderr so setup's own lines stay apart.
fn runClaude(args: []const []const u8, config_dir: ?[]const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = arena.allocSentinel(?[*:0]const u8, args.len + 1, null) catch return 1;
    argv[0] = "claude";
    for (args, 1..) |a, i| argv[i] = (arena.dupeZ(u8, a) catch return 1).ptr;
    const dir_z: ?[:0]const u8 = if (config_dir) |d| arena.dupeZ(u8, d) catch return 1 else null;
    const pid = c.fork();
    if (pid < 0) return 1;
    if (pid == 0) {
        _ = c.dup2(2, 1);
        if (dir_z) |d| _ = c.setenv("CLAUDE_CONFIG_DIR", d.ptr, 1);
        _ = c.execvp("claude", @ptrCast(argv.ptr));
        c._exit(127);
    }
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0) {
        if (std.posix.errno(-1) != .INTR) return 1;
    }
    if (c.WIFEXITED(st)) return @intCast(c.WEXITSTATUS(st));
    return 1;
}

/// The shipped opencode plugin, as an absolute path without `..`.
fn shippedPlugin(arena: std.mem.Allocator) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const found = sharedata.find(&buf, PLUGIN_REL) orelse return null;
    var real: [4096]u8 = undefined;
    if (c.realpath(found.ptr, @ptrCast(&real)) == null) return null;
    return arena.dupe(u8, std.mem.sliceTo(&real, 0)) catch null;
}

fn usage(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    _ = fdio.writeAll(2, std.fmt.bufPrint(&buf, "sketerm mcp setup: " ++ fmt ++ " (see --help)\n", args) catch "sketerm mcp setup: bad arguments\n");
    return 2;
}

/// `sketerm mcp setup ...`.
/// @return 0 when set up, 1 when a file was left untouched or a step failed, 2 for a usage error.
pub fn cli(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var dry_run = false;
    var config_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            _ = fdio.writeAll(1, HELP);
            return 0;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--user")) {
            // nib's spelling; user scope is the only one.
        } else if (std.mem.eql(u8, a, "--config-dir")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return usage("--config-dir needs a directory", .{});
            config_dir = args[i];
        } else return usage("unknown argument {s}", .{a});
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = env.nonEmpty("HOME") orelse {
        _ = fdio.writeAll(2, "sketerm mcp setup: HOME is not set\n");
        return 1;
    };
    var cwd_buf: [4096]u8 = undefined;
    const cwd: []const u8 = if (c.getcwd(&cwd_buf, cwd_buf.len)) |p| std.mem.span(@as([*:0]u8, @ptrCast(p))) else "/";
    const outcome = setup(arena, .{
        .dry_run = dry_run,
        .paths = claudePaths(arena, config_dir, env.nonEmpty("CLAUDE_CONFIG_DIR"), home) catch return 1,
        .config_dir = config_dir,
        .opencode_dir = opencodeDir(arena, env.nonEmpty("OPENCODE_CONFIG_DIR"), env.nonEmpty("XDG_CONFIG_HOME"), home) catch return 1,
        .cwd = cwd,
        .claude = if (pathz.executableOnPath("claude")) runClaude else null,
        .plugin = shippedPlugin(arena),
    }) catch return 1;
    for (outcome.lines) |line| {
        _ = fdio.writeAll(1, line);
        _ = fdio.writeAll(1, "\n");
    }
    return if (outcome.failed) 1 else 0;
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

fn mergedText(m: Merged) ![]const u8 {
    return switch (m) {
        .done => |d| d.text orelse error.TestUnexpectedResult,
        .refused => error.TestUnexpectedResult,
    };
}

fn changesOf(m: Merged) ![]const []const u8 {
    return switch (m) {
        .done => |d| d.changes,
        .refused => error.TestUnexpectedResult,
    };
}

fn parse(a: std.mem.Allocator, text: []const u8) !std.json.ObjectMap {
    return (try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{})).object;
}

fn expectNoChange(a: std.mem.Allocator, text: []const u8) !void {
    const again = try mergeSettings(a, text);
    try t.expect(again.done.text == null);
    try t.expectEqual(@as(usize, 0), again.done.changes.len);
}

test "an empty or missing file gets every hook, the status line and the deny rule; a second run changes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]?[]const u8{ null, "", "\n" }) |input| {
        const m = try mergeSettings(a, input);
        const changes = try changesOf(m);
        try t.expectEqual(@as(usize, 3), changes.len);
        try t.expectEqualStrings("added hooks: SessionStart, UserPromptSubmit, Stop, Notification, SessionEnd", changes[0]);
        try t.expectEqualStrings("set status line: sketerm mcp statusline", changes[1]);
        try t.expectEqualStrings("added deny ListAgents", changes[2]);
        const text = try mergedText(m);
        // The same settings `--print-settings` shows, plus the deny rule.
        const doc = try parse(a, text);
        const printed = try parse(a, try mcp_hook.settingsJson(a));
        try t.expectEqual(printed.get("hooks").?.object.count(), doc.get("hooks").?.object.count());
        try t.expectEqualStrings(mcp_hook.STATUSLINE_COMMAND, doc.get("statusLine").?.object.get("command").?.string);
        try t.expectEqual(@as(i64, 5), doc.get("statusLine").?.object.get("refreshInterval").?.integer);
        try t.expect(std.mem.startsWith(u8, text, "{\n  \"hooks\""));
        try expectNoChange(a, text);
    }
}

test "a foreign status line is wrapped, shell-quoted, its padding kept; key order and indent width survive" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const input =
        \\{
        \\    "model": "opus",
        \\    "statusLine": {
        \\        "type": "command",
        \\        "command": "node ~/line.js 'it''s'",
        \\        "padding": 2
        \\    },
        \\    "zz": 1.50
        \\}
        \\
    ;
    const m = try mergeSettings(a, input);
    const changes = try changesOf(m);
    try t.expectEqualStrings("wrapped your status line: node ~/line.js 'it''s'", changes[1]);
    try t.expectEqualStrings("set statusLine.refreshInterval to 5 (seconds)", changes[2]);
    const text = try mergedText(m);
    const sl = (try parse(a, text)).get("statusLine").?.object;
    try t.expectEqualStrings("sketerm mcp statusline --user-command 'node ~/line.js '\\''it'\\'''\\''s'\\'''", sl.get("command").?.string);
    try t.expectEqual(@as(i64, 2), sl.get("padding").?.integer);
    // Existing keys keep their place and their number text; new keys come last; 4-space indent kept.
    const model_at = std.mem.indexOf(u8, text, "\"model\"").?;
    const status_at = std.mem.indexOf(u8, text, "\"statusLine\"").?;
    const zz_at = std.mem.indexOf(u8, text, "\"zz\": 1.50").?;
    const hooks_at = std.mem.indexOf(u8, text, "\"hooks\"").?;
    try t.expect(model_at < status_at and status_at < zz_at and zz_at < hooks_at);
    try t.expect(std.mem.startsWith(u8, text, "{\n    \"model\""));
    try t.expect(std.mem.endsWith(u8, text, "}\n"));
    try expectNoChange(a, text);
}

test "an already wrapped status line is left alone; a refreshInterval in milliseconds becomes seconds" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const input =
        \\{"statusLine": {"type": "command", "command": "/usr/bin/sketerm mcp statusline --user-command 'x'", "refreshInterval": 5000}}
    ;
    const m = try mergeSettings(a, input);
    const changes = try changesOf(m);
    for (changes) |line| try t.expect(std.mem.indexOf(u8, line, "wrapped") == null);
    try t.expectEqualStrings("converted statusLine.refreshInterval 5000 to 5: Claude Code reads it in seconds, so it was almost certainly milliseconds", changes[1]);
    const text = try mergedText(m);
    const sl = (try parse(a, text)).get("statusLine").?.object;
    try t.expectEqualStrings("/usr/bin/sketerm mcp statusline --user-command 'x'", sl.get("command").?.string);
    try t.expectEqual(@as(i64, 5), sl.get("refreshInterval").?.integer);
    // Minified stays minified.
    try t.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
    try expectNoChange(a, text);
}

test "other tools' hooks are kept in place; ours is appended once per event" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const input =
        \\{
        \\  "hooks": {
        \\    "PreToolUse": [{"matcher": "Bash|Grep", "hooks": [{"type": "command", "command": "nib hook"}]}],
        \\    "Stop": [{"hooks": [{"type": "command", "command": "notify-send done"}]}],
        \\    "SessionStart": [{"hooks": [{"type": "command", "command": "sketerm mcp hook", "async": true}]}]
        \\  }
        \\}
    ;
    const m = try mergeSettings(a, input);
    try t.expectEqualStrings("added hooks: UserPromptSubmit, Stop, Notification, SessionEnd", (try changesOf(m))[0]);
    const text = try mergedText(m);
    const hooks = (try parse(a, text)).get("hooks").?.object;
    try t.expectEqualStrings("PreToolUse", hooks.keys()[0]);
    const pre = hooks.get("PreToolUse").?.array.items;
    try t.expectEqual(@as(usize, 1), pre.len);
    try t.expectEqualStrings("Bash|Grep", pre[0].object.get("matcher").?.string);
    try t.expectEqualStrings("nib hook", pre[0].object.get("hooks").?.array.items[0].object.get("command").?.string);
    const stop = hooks.get("Stop").?.array.items;
    try t.expectEqual(@as(usize, 2), stop.len);
    try t.expectEqualStrings("notify-send done", stop[0].object.get("hooks").?.array.items[0].object.get("command").?.string);
    try t.expectEqualStrings(mcp_hook.HOOK_COMMAND, stop[1].object.get("hooks").?.array.items[0].object.get("command").?.string);
    try t.expectEqual(@as(usize, 1), hooks.get("SessionStart").?.array.items.len);
    try expectNoChange(a, text);
}

test "ListAgents is added to permissions.deny once, other rules kept" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try mergeSettings(a, "{\"permissions\": {\"allow\": [\"Read\"], \"deny\": [\"Bash\"]}}");
    const text = try mergedText(m);
    const perms = (try parse(a, text)).get("permissions").?.object;
    try t.expectEqual(@as(usize, 1), perms.get("allow").?.array.items.len);
    const deny = perms.get("deny").?.array.items;
    try t.expectEqual(@as(usize, 2), deny.len);
    try t.expectEqualStrings("Bash", deny[0].string);
    try t.expectEqualStrings(DENIED_TOOL, deny[1].string);
    try expectNoChange(a, text);
}

test "a file that is not plain JSON, or holds the wrong shapes, is refused" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{
        "{\n  // my settings\n  \"model\": \"opus\"\n}\n",
        "{\"model\": \"opus\",}",
        "[1]",
        "{\"hooks\": []}",
        "{\"hooks\": {\"Stop\": {}}}",
        "{\"statusLine\": \"x\"}",
        "{\"permissions\": {\"deny\": \"Bash\"}}",
    }) |input| {
        try t.expect((try mergeSettings(a, input)) == .refused);
    }
}

test "config dirs: --config-dir, then CLAUDE_CONFIG_DIR, then home; opencode's own variable, then XDG, then home" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const flag = try claudePaths(a, "/f", "/e", "/h");
    try t.expectEqualStrings("/f/settings.json", flag.settings);
    try t.expectEqualStrings("/f/.claude.json", flag.registry);
    const envd = try claudePaths(a, null, "/e", "/h");
    try t.expectEqualStrings("/e/settings.json", envd.settings);
    try t.expectEqualStrings("/e/.claude.json", envd.registry);
    const home = try claudePaths(a, null, null, "/h");
    try t.expectEqualStrings("/h/.claude/settings.json", home.settings);
    try t.expectEqualStrings("/h/.claude.json", home.registry);
    try t.expectEqualStrings("/o", try opencodeDir(a, "/o", "/x", "/h"));
    try t.expectEqualStrings("/x/opencode", try opencodeDir(a, null, "/x", "/h"));
    try t.expectEqualStrings("/h/.config/opencode", try opencodeDir(a, null, null, "/h"));
}

var fake_calls: usize = 0;
var fake_config_dir: ?[]const u8 = null;

/// Stands in for `claude mcp add`: records the call and registers the server as Claude Code would.
fn fakeClaude(args: []const []const u8, config_dir: ?[]const u8) u8 {
    fake_calls += 1;
    if (args.len != CLAUDE_ADD.len) return 9;
    for (args, CLAUDE_ADD) |got, want| if (!std.mem.eql(u8, got, want)) return 9;
    const dir = config_dir orelse return 9;
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.claude.json", .{dir}) catch return 9;
    atomicwrite.writeFile(path, "{\"mcpServers\": {\"sketerm\": {\"command\": \"sketerm\"}}}", 0o600) catch return 9;
    return 0;
}

fn fileText(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return readfile.cappedAlloc(a, path, 1 << 20);
}

test "setup writes through a settings symlink keeping its mode, registers once, links the plugin; dry run writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const td = pathz.TempDir.make("mcpsetup") orelse return error.SkipZigTest;
    defer td.remove();
    const root = td.path();
    const cfg = try std.fs.path.join(a, &.{ root, "claude" });
    const dotfiles = try std.fs.path.join(a, &.{ root, "dotfiles" });
    const oc = try std.fs.path.join(a, &.{ root, "opencode" });
    const work = try std.fs.path.join(a, &.{ root, "work" });
    for ([_][]const u8{ cfg, dotfiles, oc, work }) |d| try pathz.makeDirs(d, 0o700);
    const real = try std.fs.path.join(a, &.{ dotfiles, "settings.json" });
    try atomicwrite.writeFileExact(real, "{\"statusLine\": {\"type\": \"command\", \"command\": \"ccline\"}}\n", 0o600);
    const settings = try std.fs.path.join(a, &.{ cfg, "settings.json" });
    try t.expectEqual(@as(c_int, 0), c.symlink((try a.dupeZ(u8, real)).ptr, (try a.dupeZ(u8, settings)).ptr));
    const plugin = try std.fs.path.join(a, &.{ root, PLUGIN_FILE });
    try atomicwrite.writeFile(plugin, "// plugin\n", 0o644);
    const link = try std.fs.path.join(a, &.{ oc, "plugin", PLUGIN_FILE });
    // A stale link from an older install is replaced.
    try pathz.makeDirs(try std.fs.path.join(a, &.{ oc, "plugin" }), 0o700);
    try t.expectEqual(@as(c_int, 0), c.symlink("/gone/" ++ PLUGIN_FILE, (try a.dupeZ(u8, link)).ptr));

    var o: Options = .{
        .dry_run = true,
        .paths = try claudePaths(a, cfg, null, root),
        .config_dir = cfg,
        .opencode_dir = oc,
        .cwd = work,
        .claude = fakeClaude,
        .plugin = plugin,
    };
    fake_calls = 0;
    // 1. A dry run reports every change and writes or runs nothing.
    const dry = try setup(a, o);
    try t.expect(!dry.failed);
    try t.expectEqualStrings("dry run: nothing is written or run", dry.lines[0]);
    try t.expectEqualStrings("would run: claude mcp add --scope user sketerm -- sketerm mcp", dry.lines[dry.lines.len - 2]);
    try t.expectEqual(@as(usize, 0), fake_calls);
    try t.expectEqualStrings("{\"statusLine\": {\"type\": \"command\", \"command\": \"ccline\"}}\n", try fileText(a, real));

    // 2. The real run writes through the link, keeps 0600, registers and relinks.
    o.dry_run = false;
    const run = try setup(a, o);
    try t.expect(!run.failed);
    try t.expectEqualStrings("wrapped your status line: ccline", run.lines[1]);
    try t.expectEqualStrings("registered MCP server sketerm", run.lines[4]);
    try t.expect(std.mem.startsWith(u8, run.lines[5], "relinked opencode plugin: "));
    try t.expectEqual(@as(usize, 1), fake_calls);
    var st: c.struct_stat = undefined;
    try t.expectEqual(@as(c_int, 0), c.lstat((try a.dupeZ(u8, settings)).ptr, &st));
    try t.expectEqual(@as(c_uint, c.S_IFLNK), st.st_mode & c.S_IFMT);
    try t.expectEqual(@as(c_int, 0), c.stat((try a.dupeZ(u8, real)).ptr, &st));
    try t.expectEqual(@as(c_uint, 0o600), st.st_mode & 0o777);
    const doc = try parse(a, try fileText(a, real));
    try t.expectEqualStrings("sketerm mcp statusline --user-command 'ccline'", doc.get("statusLine").?.object.get("command").?.string);
    var buf: [4096]u8 = undefined;
    const n = c.readlink((try a.dupeZ(u8, link)).ptr, &buf, buf.len);
    try t.expectEqualStrings(plugin, buf[0..@intCast(n)]);

    // 3. A second run finds everything in place.
    const again = try setup(a, o);
    try t.expectEqual(@as(usize, 1), again.lines.len);
    try t.expectEqualStrings("already set up", again.lines[0]);
    try t.expectEqual(@as(usize, 1), fake_calls);

    // 4. A project's .mcp.json counts; no claude: a note, not a failure.
    const fresh = try std.fs.path.join(a, &.{ root, "fresh" });
    try pathz.makeDirs(fresh, 0o700);
    try atomicwrite.writeFile(try std.fs.path.join(a, &.{ root, ".mcp.json" }), "{\"mcpServers\": {\"sketerm\": {}}}", 0o600);
    o.paths = try claudePaths(a, fresh, null, root);
    o.claude = null;
    const project = try setup(a, o);
    try t.expect(!project.failed);
    try t.expect(std.mem.indexOf(u8, project.lines[3], "is project-scoped in ") != null);
    try t.expectEqual(@as(usize, 1), fake_calls);
}
