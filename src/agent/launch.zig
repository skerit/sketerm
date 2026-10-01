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

/// Where one launch candidate looks for the executable.
pub const Place = union(enum) {
    /// A search of the host's `$PATH`.
    path_search,
    /// A directory under the host's home (`~/x` = "/x", `~` = "").
    home: []const u8,
    /// An absolute directory.
    dir: []const u8,
};

/// The place a candidate names, or null for one that names none (a
/// relative path). The candidate's own basename is replaced by the name
/// being looked up.
pub fn candidatePlace(cand: []const u8) ?Place {
    if (std.mem.eql(u8, cand, "$PATH")) return .path_search;
    const dir = std.fs.path.dirname(cand) orelse return null;
    if (std.mem.startsWith(u8, dir, "~/") or std.mem.eql(u8, dir, "~")) return .{ .home = dir[1..] };
    if (dir.len > 0 and dir[0] == '/') return .{ .dir = dir };
    return null;
}

/// The executable name to look up: a bare `override`, else the adapter's.
fn lookupName(launch: adapter.Launch, override: ?[]const u8) []const u8 {
    return override orelse launch.binary;
}

/// The executable to run: an absolute `override` as is, else every
/// candidate in order with the executable's name (`override` when it is a
/// bare name, else `launch.binary`): `$PATH` searches the path, `~/x/name`
/// is under the home directory, and a candidate path keeps its directory
/// and takes that name.
/// @return an arena-owned absolute path, or null when nothing matches.
pub fn resolve(arena: std.mem.Allocator, launch: adapter.Launch, override: ?[]const u8, host: Host) !?[]const u8 {
    if (override) |o| {
        if (o[0] == '/') return if (host.probe(o)) try arena.dupe(u8, o) else null;
    }
    const name = lookupName(launch, override);
    for (launch.candidates) |cand| {
        const full = switch (candidatePlace(cand) orelse continue) {
            .path_search => {
                var it = std.mem.splitScalar(u8, host.path, ':');
                while (it.next()) |dir| {
                    if (dir.len == 0 or dir[0] != '/') continue;
                    const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), name });
                    if (host.probe(p)) return p;
                }
                continue;
            },
            .home => |rel| try std.fmt.allocPrint(arena, "{s}{s}/{s}", .{ host.home orelse continue, rel, name }),
            .dir => |dir| try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }),
        };
        if (host.probe(full)) return full;
    }
    return null;
}

/// One lookup of a remote probe: an adapter's launch and its override.
pub const Lookup = struct { launch: adapter.Launch, override: ?[]const u8 = null };

/// Marker lines of a probe's output.
const PROBE_BIN = "SK_BIN ";
const PROBE_NONE = "SK_NONE ";
const PROBE_DIR = "SK_DIR ";

/// A POSIX sh script that does `resolve` ON THE HOST IT RUNS ON, for every
/// lookup at once (one ssh round trip): `command -v` for `$PATH`, `$HOME`
/// for `~/`. It prints `SK_BIN <i> <path>` or `SK_NONE <i>` per lookup,
/// and `SK_DIR ok|missing` when `dir` is given (a remote working dir).
pub fn probeScript(arena: std.mem.Allocator, lookups: []const Lookup, dir: ?[]const u8) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, "sk_x() { case \"$1\" in /*) [ -f \"$1\" ] && [ -x \"$1\" ];; *) false;; esac; }\n");
    for (lookups, 0..) |l, i| {
        try s.appendSlice(arena, "p=''\n");
        if (l.override) |o| if (o[0] == '/') {
            try s.appendSlice(arena, "sk_x ");
            try shellquote.appendQuoted(&s, arena, o);
            try s.appendSlice(arena, " && p=");
            try shellquote.appendQuoted(&s, arena, o);
            try s.append(arena, '\n');
        };
        const name = lookupName(l.launch, l.override);
        if (l.override == null or l.override.?[0] != '/') for (l.launch.candidates) |cand| {
            const place = candidatePlace(cand) orelse continue;
            try s.appendSlice(arena, "[ -z \"$p\" ] && { c=");
            switch (place) {
                .path_search => {
                    try s.appendSlice(arena, "$(command -v ");
                    try shellquote.appendQuoted(&s, arena, name);
                    try s.appendSlice(arena, " 2>/dev/null)");
                },
                .home => |rel| {
                    try s.appendSlice(arena, "\"$HOME\"");
                    try shellquote.appendQuoted(&s, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, name }));
                },
                .dir => |d| try shellquote.appendQuoted(&s, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ d, name })),
            }
            try s.appendSlice(arena, "; sk_x \"$c\" && p=\"$c\"; }\n");
        };
        try s.print(arena, "if [ -n \"$p\" ]; then printf '" ++ PROBE_BIN ++ "{d} %s\\n' \"$p\"; else echo '" ++ PROBE_NONE ++ "{d}'; fi\n", .{ i, i });
    }
    if (dir) |d| {
        try s.appendSlice(arena, "if [ -d ");
        try shellquote.appendQuoted(&s, arena, d);
        try s.appendSlice(arena, " ]; then echo '" ++ PROBE_DIR ++ "ok'; else echo '" ++ PROBE_DIR ++ "missing'; fi\n");
    }
    try s.appendSlice(arena, "printf '" ++ PROBE_HOME ++ "%s\\n' \"$HOME\"\n");
    return s.items;
}

const PROBE_HOME = "SK_HOME ";

pub const ProbeResult = struct {
    /// Per lookup: the executable found, or null.
    binaries: []?[]const u8,
    /// Null when no dir was probed.
    dir_ok: ?bool = null,
    /// The host's `$HOME` (the default working directory there).
    home: ?[]const u8 = null,
    /// Every lookup answered (a probe cut short is not "not installed").
    complete: bool,
};

/// Read a probe's output; paths borrow from `output`.
pub fn parseProbe(arena: std.mem.Allocator, output: []const u8, n: usize) !ProbeResult {
    const bins = try arena.alloc(?[]const u8, n);
    @memset(bins, null);
    const seen = try arena.alloc(bool, n);
    @memset(seen, false);
    var r = ProbeResult{ .binaries = bins, .complete = false };
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        // A terminal transcript: CR line ends, and the marker may follow noise.
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.indexOf(u8, line, PROBE_HOME)) |at| {
            const v = line[at + PROBE_HOME.len ..];
            if (v.len > 0 and v[0] == '/') r.home = v;
            continue;
        }
        if (std.mem.indexOf(u8, line, PROBE_DIR)) |at| {
            const v = line[at + PROBE_DIR.len ..];
            if (std.mem.eql(u8, v, "ok")) r.dir_ok = true else if (std.mem.eql(u8, v, "missing")) r.dir_ok = false;
            continue;
        }
        const found = std.mem.indexOf(u8, line, PROBE_BIN);
        const none = std.mem.indexOf(u8, line, PROBE_NONE);
        const rest = if (found) |at| line[at + PROBE_BIN.len ..] else if (none) |at| line[at + PROBE_NONE.len ..] else continue;
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const i = std.fmt.parseInt(usize, rest[0..sp], 10) catch continue;
        if (i >= n) continue;
        seen[i] = true;
        if (found != null and sp < rest.len) {
            const path = rest[sp + 1 ..];
            if (path.len > 0 and path[0] == '/') bins[i] = path;
        }
    }
    r.complete = std.mem.indexOfScalar(bool, seen, false) == null;
    return r;
}

/// Which conversation a start names (adapters with `session_args`).
pub const Start = enum {
    /// A new conversation with the id in `{session}`.
    fresh,
    /// Resume the conversation `{session}` (a relaunch).
    resumed,
};

/// `binary` + the adapter's `args`, then `session_args` (or `resume_args`
/// for a resumed start) when a session id is given, `model_args` when a
/// model is and `effort_args` when an effort level is, placeholders filled.
pub fn mainArgv(arena: std.mem.Allocator, launch: adapter.Launch, binary: []const u8, values: Values, start: Start) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, binary);
    try appendExpanded(arena, &out, launch.args, values);
    if (values.session != null) try appendExpanded(arena, &out, switch (start) {
        .fresh => launch.session_args,
        .resumed => launch.resume_args,
    }, values);
    if (values.model != null) try appendExpanded(arena, &out, launch.model_args, values);
    if (values.effort != null) try appendExpanded(arena, &out, launch.effort_args, values);
    return out.items;
}

/// Whether `level` is one the adapter's `effort_args` accepts.
pub fn validEffort(launch: adapter.Launch, level: []const u8) bool {
    if (launch.effort_values.len == 0) return true;
    for (launch.effort_values) |v| if (std.mem.eql(u8, v, level)) return true;
    return false;
}

/// What a remote start prints, with echo off, when it waits for its
/// secret on the terminal (the remote half of `password_env`).
pub const SECRET_PROMPT = "[sketerm] agent secret: ";

/// A POSIX sh script that starts `argv` on a remote host: it removes
/// `cleanup` (the ssh transport's script file), changes to `cwd`, and with
/// `secret_env` reads that variable's value from the terminal with echo
/// off (after printing `SECRET_PROMPT`) and exports it, so the secret
/// rides neither an argv nor the spawn request. Then it execs `argv`.
pub fn remoteScript(arena: std.mem.Allocator, argv: []const []const u8, opts: struct {
    cleanup: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    secret_env: ?[]const u8 = null,
}) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    if (opts.cleanup) |f| {
        try s.appendSlice(arena, "rm -f ");
        try shellquote.appendQuoted(&s, arena, f);
        try s.append(arena, '\n');
    }
    if (opts.cwd) |d| {
        try s.appendSlice(arena, "cd ");
        try shellquote.appendQuoted(&s, arena, d);
        try s.appendSlice(arena, " || { echo '[sketerm] no such directory on this host'; exit 1; }\n");
    }
    if (opts.secret_env) |name| {
        // `adapter` validated the name; the value never touches argv.
        try s.print(arena, "stty -echo 2>/dev/null; printf '%s' '" ++ SECRET_PROMPT ++ "'; IFS= read -r {s}; stty echo 2>/dev/null; echo; export {s}\n", .{ name, name });
    }
    try s.appendSlice(arena, "exec");
    for (argv) |a| {
        try s.append(arena, ' ');
        try shellquote.appendQuoted(&s, arena, a);
    }
    try s.append(arena, '\n');
    return s.items;
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
    const plain = try mainArgv(a, test_launch, "/bin/oc", .{ .port = "4100" }, .fresh);
    try t.expectEqual(@as(usize, 4), plain.len);
    try t.expectEqualStrings("4100", plain[3]);
    const with_model = try mainArgv(a, test_launch, "/bin/oc", .{ .port = "4100", .model = "p/m" }, .fresh);
    try t.expectEqual(@as(usize, 6), with_model.len);
    try t.expectEqualStrings("p/m", with_model[5]);
    const attach = try attachArgv(a, test_launch, "/bin/oc", .{ .port = "4100", .session = "ses_1" });
    try t.expectEqualStrings("http://127.0.0.1:4100", attach[2]);
    try t.expectEqualStrings("ses_1", attach[4]);
    try t.expect(launchTakes(test_launch, .model));
    try t.expect(!launchTakes(test_launch, .effort));

    // A conversation id: named on a fresh start, resumed on a relaunch.
    const claude = adapter.Launch{
        .binary = "claude",
        .candidates = &.{"$PATH"},
        .args = &.{"--ax-screen-reader"},
        .session_args = &.{ "--session-id", "{session}" },
        .resume_args = &.{ "--resume", "{session}" },
        .effort_args = &.{ "--effort", "{effort}" },
        .effort_values = &.{ "low", "high" },
    };
    const fresh = try mainArgv(a, claude, "/c", .{ .session = "u-1", .effort = "low" }, .fresh);
    try t.expectEqualStrings("--session-id", fresh[2]);
    try t.expectEqualStrings("u-1", fresh[3]);
    try t.expectEqualStrings("low", fresh[5]);
    const resumed = try mainArgv(a, claude, "/c", .{ .session = "u-1", .effort = "high" }, .resumed);
    try t.expectEqualStrings("--resume", resumed[2]);
    try t.expectEqualStrings("high", resumed[5]);
    // Without an id neither is added.
    try t.expectEqual(@as(usize, 2), (try mainArgv(a, claude, "/c", .{}, .resumed)).len);
    try t.expect(validEffort(claude, "high"));
    try t.expect(!validEffort(claude, "High"));
    try t.expect(validEffort(test_launch, "anything"));
}

/// Run `script` under /bin/sh with `env` and return its stdout.
fn runSh(a: std.mem.Allocator, env: []const u8, script: []const u8) ![]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(a, env);
    try cmd.appendSlice(a, " /bin/sh -c ");
    try shellquote.appendQuoted(&cmd, a, script);
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
    return out.items;
}

test "the remote probe resolves candidates on the host it runs on, in one script" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmpl = "/tmp/sketerm-probe-XXXXXX".*;
    const root_ptr = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const root = std.mem.span(@as([*:0]u8, @ptrCast(root_ptr)));
    defer @import("../util/pathz.zig").removeTree(root);
    // A host whose PATH lacks ~/.local/bin (an ssh login), where the app
    // lives; a second app is installed nowhere, a third on PATH.
    const bin = try std.fmt.allocPrint(a, "{s}/home/.local/bin", .{root});
    const usr = try std.fmt.allocPrint(a, "{s}/usr/bin", .{root});
    // Names nothing on a developer's machine has (the probe sees only this PATH).
    _ = try runSh(a, "", try std.fmt.allocPrint(a, "mkdir -p '{s}' '{s}' && printf '#!/bin/sh\\n' > '{s}/skprobe-a' && chmod +x '{s}/skprobe-a' && printf x > '{s}/skprobe-b' && cp '{s}/skprobe-a' '{s}/skprobe-c'", .{ bin, usr, bin, bin, bin, bin, usr }));
    const claude = adapter.Launch{ .binary = "skprobe-a", .candidates = &.{ "$PATH", "~/.local/bin/skprobe-a" } };
    const opencode = adapter.Launch{ .binary = "skprobe-b", .candidates = &.{ "$PATH", "~/.local/bin/skprobe-b" } };
    const tool = adapter.Launch{ .binary = "skprobe-c", .candidates = &.{ "$PATH", "~/.local/bin/skprobe-c" } };
    const script = try probeScript(a, &.{
        .{ .launch = claude },
        // Not executable: a file is not an install.
        .{ .launch = opencode },
        .{ .launch = tool },
        .{ .launch = claude, .override = try std.fmt.allocPrint(a, "{s}/skprobe-a", .{bin}) },
        .{ .launch = claude, .override = "skprobe-missing" },
    }, "/nonexistent-dir");
    // The script uses shell builtins only: PATH is just the "remote" one.
    const env = try std.fmt.allocPrint(a, "HOME='{s}/home' PATH='{s}'", .{ root, usr });
    const out = try runSh(a, env, script);
    const r = try parseProbe(a, out, 5);
    if (!r.complete) std.debug.print("probe output:\n{s}\n", .{out});
    try t.expect(r.complete);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/skprobe-a", .{bin}), r.binaries[0].?);
    try t.expect(r.binaries[1] == null);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/skprobe-c", .{usr}), r.binaries[2].?);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/skprobe-a", .{bin}), r.binaries[3].?);
    try t.expect(r.binaries[4] == null);
    try t.expectEqual(@as(?bool, false), r.dir_ok);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/home", .{root}), r.home.?);
    // A cut-off transcript (CR line ends, a lookup missing) is incomplete.
    const cut = try parseProbe(a, "noise SK_BIN 0 /x/claude\r\nSK_NONE 1\r\n", 3);
    try t.expect(!cut.complete);
    try t.expectEqualStrings("/x/claude", cut.binaries[0].?);
}

test "the remote start script reads its secret off the terminal, never from argv" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const script = try remoteScript(a, &.{ "/opt/oc", "serve", "--port", "4100" }, .{ .cleanup = "/tmp/.sk_ssh_ab", .cwd = "/srv/my repo", .secret_env = "OC_PW" });
    try t.expect(std.mem.startsWith(u8, script, "rm -f /tmp/.sk_ssh_ab\n"));
    try t.expect(std.mem.indexOf(u8, script, "cd '/srv/my repo' ||") != null);
    try t.expect(std.mem.indexOf(u8, script, "stty -echo") != null);
    try t.expect(std.mem.endsWith(u8, script, "exec /opt/oc serve --port 4100\n"));
    // Run it: the value typed on stdin reaches the exec'd program's env.
    const run = try remoteScript(a, &.{ "/bin/sh", "-c", "printf 'got=%s' \"$OC_PW\"" }, .{ .secret_env = "OC_PW" });
    const out = try runSh(a, "printf 's3cret\\n' |", run);
    try t.expect(std.mem.indexOf(u8, out, SECRET_PROMPT) != null);
    try t.expect(std.mem.endsWith(u8, out, "got=s3cret"));
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
