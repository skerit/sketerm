//! Launching an agent app from its adapter: which executable, which argv,
//! which environment. Pure over its inputs (the PATH and HOME strings and
//! an executable probe), so it is unit-tested without spawning anything.
//!
//! Local resolution only: the MCP layer runs it on the host that runs the
//! app. The argv it builds (the `unset_env` wrapper included) is plain
//! POSIX sh, so the same argv works on a remote host.

const std = @import("std");
const adapter = @import("adapter.zig");
const shellquote = @import("../util/shellquote.zig");
const c = @import("../c.zig").c;

/// The `{placeholder}` values of one launch.
pub const Values = std.enums.EnumFieldStruct(adapter.Placeholder, ?[]const u8, @as(?[]const u8, null));

/// Longest binary override, model name or effort level accepted.
pub const MAX_ARG = 256;

/// A caller's binary override: a bare name (looked up like the adapter's
/// own binary) or an absolute path, of shell-safe bytes only and with no
/// `..` component.
pub fn validBinary(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_ARG) return false;
    for (s) |b| if (!shellquote.shellSafeChar(b)) return false;
    if (std.mem.indexOfScalar(u8, s, '/') == null) return !std.mem.eql(u8, s, ".") and !std.mem.eql(u8, s, "..");
    if (s[0] != '/') return false;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

/// A model name or effort level: printable, no control bytes (it is typed
/// into a TUI by some recipes).
pub fn validValue(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_ARG) return false;
    for (s) |b| if (b < 0x20 or b == 0x7f) return false;
    return true;
}

pub const Host = struct {
    /// `$PATH` on the host.
    path: []const u8,
    /// `$HOME` on the host; null leaves `~/` candidates unresolved.
    home: ?[]const u8,
    /// Whether a path names an executable file.
    probe: *const fn ([]const u8) bool = isExecutable,
};

pub fn isExecutable(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    var st: c.struct_stat = undefined;
    if (c.stat(z.ptr, &st) != 0) return false;
    if ((st.st_mode & c.S_IFMT) != c.S_IFREG) return false;
    return c.access(z.ptr, c.X_OK) == 0;
}

/// The executable to run: an absolute `override` as is, else every
/// candidate in order with the executable's name (`override` when it is a
/// bare name, else `launch.binary`): `$PATH` searches the path, `~/x/name`
/// is under the home directory, and a candidate path keeps its directory
/// and takes that name.
/// @return an arena-owned absolute path, or null when nothing matches.
pub fn resolve(arena: std.mem.Allocator, launch: adapter.Launch, override: ?[]const u8, host: Host) !?[]const u8 {
    const name = if (override) |o| blk: {
        if (o[0] == '/') return if (host.probe(o)) try arena.dupe(u8, o) else null;
        break :blk o;
    } else launch.binary;
    for (launch.candidates) |cand| {
        if (std.mem.eql(u8, cand, "$PATH")) {
            var it = std.mem.splitScalar(u8, host.path, ':');
            while (it.next()) |dir| {
                if (dir.len == 0 or dir[0] != '/') continue;
                const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), name });
                if (host.probe(full)) return full;
            }
            continue;
        }
        const dir = std.fs.path.dirname(cand) orelse continue;
        const full = if (std.mem.startsWith(u8, dir, "~/") or std.mem.eql(u8, dir, "~")) blk: {
            const home = host.home orelse continue;
            break :blk try std.fmt.allocPrint(arena, "{s}{s}/{s}", .{ home, dir[1..], name });
        } else if (dir.len > 0 and dir[0] == '/')
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name })
        else
            continue;
        if (host.probe(full)) return full;
    }
    return null;
}

/// `binary` + the adapter's `args`, then `model_args` when a model is
/// given and `effort_args` when an effort level is, placeholders filled.
pub fn mainArgv(arena: std.mem.Allocator, launch: adapter.Launch, binary: []const u8, values: Values) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, binary);
    try appendExpanded(arena, &out, launch.args, values);
    if (values.model != null) try appendExpanded(arena, &out, launch.model_args, values);
    if (values.effort != null) try appendExpanded(arena, &out, launch.effort_args, values);
    return out.items;
}

/// `binary` + the adapter's `attach_args`, placeholders filled.
pub fn attachArgv(arena: std.mem.Allocator, launch: adapter.Launch, binary: []const u8, values: Values) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, binary);
    try appendExpanded(arena, &out, launch.attach_args, values);
    return out.items;
}

fn appendExpanded(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), args: []const []const u8, values: Values) !void {
    for (args) |a| try out.append(arena, try adapter.expand(arena, a, values));
}

/// Whether the adapter can take the model / effort level at launch
/// (otherwise the MCP layer applies it through the running app).
pub fn launchTakes(launch: adapter.Launch, comptime which: enum { model, effort }) bool {
    return switch (which) {
        .model => launch.model_args.len > 0,
        .effort => launch.effort_args.len > 0,
    };
}

/// `argv` wrapped so the child starts with every variable `unset` names
/// removed (a trailing `*` matches a prefix). The daemon's environment,
/// not this process's, is what the child inherits, so the names are
/// matched in the child itself: `sh` lists its environment, unsets the
/// matches, then execs `argv` unchanged.
/// @param unset entries `adapter` validated (variable names, optional `*`).
pub fn withUnsetEnv(arena: std.mem.Allocator, unset: []const []const u8, argv: []const []const u8) ![]const []const u8 {
    if (unset.len == 0) return argv;
    var script: std.ArrayList(u8) = .empty;
    try script.appendSlice(arena, "names=$(env | while IFS= read -r l; do case \"$l\" in ");
    for (unset, 0..) |u, i| {
        if (i > 0) try script.append(arena, '|');
        try script.appendSlice(arena, u);
        try script.appendSlice(arena, "=*");
    }
    try script.appendSlice(arena, ") printf '%s\\n' \"${l%%=*}\";; esac; done); " ++
        "for n in $names; do case \"$n\" in *[!A-Za-z0-9_]*) ;; *) unset \"$n\";; esac; done; exec \"$@\"");
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, &.{ "/bin/sh", "-c", script.items, "sketerm-agent" });
    try out.appendSlice(arena, argv);
    return out.items;
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

fn fakeProbe(path: []const u8) bool {
    const exists = [_][]const u8{
        "/usr/bin/claude",
        "/home/u/.local/bin/opencode-oc11",
        "/home/u/.opencode/bin/opencode",
        "/opt/custom/claude",
    };
    for (exists) |e| if (std.mem.eql(u8, e, path)) return true;
    return false;
}

const test_launch = adapter.Launch{
    .binary = "opencode",
    .candidates = &.{ "$PATH", "~/.opencode/bin/opencode", "~/.local/bin/opencode" },
    .args = &.{ "serve", "--port", "{port}" },
    .model_args = &.{ "--model", "{model}" },
    .attach_args = &.{ "attach", "http://127.0.0.1:{port}", "-s", "{session}" },
};

test "binary overrides: bare names and absolute paths of safe bytes" {
    try t.expect(validBinary("opencode-oc11"));
    try t.expect(validBinary("/opt/custom/claude"));
    try t.expect(!validBinary(""));
    try t.expect(!validBinary("relative/claude"));
    try t.expect(!validBinary("/opt/../bin/sh"));
    try t.expect(!validBinary(".."));
    try t.expect(!validBinary("claude; rm -rf /"));
    try t.expect(!validBinary("claude$(id)"));
    try t.expect(!validBinary("a b"));
    try t.expect(validValue("anthropic/claude-sonnet"));
    try t.expect(!validValue("x\ny"));
}

test "resolve: candidates in order, the override's name, absolute paths as is" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const host = Host{ .path = "/nope:/usr/bin", .home = "/home/u", .probe = fakeProbe };
    // $PATH has no opencode; the first ~ candidate does.
    try t.expectEqualStrings("/home/u/.opencode/bin/opencode", (try resolve(a, test_launch, null, host)).?);
    // A bare override keeps each candidate's directory.
    try t.expectEqualStrings("/home/u/.local/bin/opencode-oc11", (try resolve(a, test_launch, "opencode-oc11", host)).?);
    try t.expectEqualStrings("/opt/custom/claude", (try resolve(a, test_launch, "/opt/custom/claude", host)).?);
    try t.expect((try resolve(a, test_launch, "/opt/missing", host)) == null);
    try t.expect((try resolve(a, test_launch, "nothing-here", host)) == null);
    // No home: ~ candidates are skipped, not guessed.
    try t.expect((try resolve(a, test_launch, null, .{ .path = "", .home = null, .probe = fakeProbe })) == null);
    const claude = adapter.Launch{ .binary = "claude", .candidates = &.{"$PATH"} };
    try t.expectEqualStrings("/usr/bin/claude", (try resolve(a, claude, null, host)).?);
}

test "argv: args, then model and effort arguments only when given" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const plain = try mainArgv(a, test_launch, "/bin/oc", .{ .port = "4100" });
    try t.expectEqual(@as(usize, 4), plain.len);
    try t.expectEqualStrings("4100", plain[3]);
    const with_model = try mainArgv(a, test_launch, "/bin/oc", .{ .port = "4100", .model = "p/m" });
    try t.expectEqual(@as(usize, 6), with_model.len);
    try t.expectEqualStrings("p/m", with_model[5]);
    const attach = try attachArgv(a, test_launch, "/bin/oc", .{ .port = "4100", .session = "ses_1" });
    try t.expectEqualStrings("http://127.0.0.1:4100", attach[2]);
    try t.expectEqualStrings("ses_1", attach[4]);
    try t.expect(launchTakes(test_launch, .model));
    try t.expect(!launchTakes(test_launch, .effort));
}

test "the unset wrapper removes exact names and prefixes in the child" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqual(@as(usize, 1), (try withUnsetEnv(a, &.{}, &.{"x"})).len);
    const argv = try withUnsetEnv(a, &.{ "CLAUDE*", "DROP_ME" }, &.{"env"});
    try t.expectEqualStrings("/bin/sh", argv[0]);
    try t.expectEqualStrings("env", argv[4]);
    // Run it: the environment is the child's own, set on the command line.
    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(a, "CLAUDE_CODE_CHILD_SESSION=1 CLAUDECONFIG=2 DROP_ME=3 KEEP_ME=4 DROP_ME_NOT=5 ");
    for (argv, 0..) |arg, i| {
        if (i > 0) try cmd.append(a, ' ');
        try shellquote.appendQuoted(&cmd, a, arg);
    }
    try cmd.append(a, 0);
    const f = c.popen(@ptrCast(cmd.items.ptr), "r") orelse return error.SkipZigTest;
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    _ = c.pclose(f);
    try t.expect(std.mem.indexOf(u8, out.items, "KEEP_ME=4") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "DROP_ME_NOT=5") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "CLAUDE_CODE_CHILD_SESSION") == null);
    try t.expect(std.mem.indexOf(u8, out.items, "CLAUDECONFIG") == null);
    try t.expect(std.mem.indexOf(u8, out.items, "\nDROP_ME=") == null and !std.mem.startsWith(u8, out.items, "DROP_ME="));
}
