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

/// Most `args` entries, and most `env` entries, one launch takes.
pub const MAX_EXTRA = 64;
/// Longest `args` entry, `env` name or `env` value.
pub const MAX_EXTRA_BYTES = 4096;
/// Longest single argv string Linux execs (`MAX_ARG_STRLEN`).
pub const MAX_EXEC_STRING = 128 * 1024;

pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// A caller's additions to every launch of the agent's binary: `args`
/// right after the binary, `env` exempt from `unset_env`, `path_prepend`
/// in front of the PATH the binary is looked up in and runs with.
pub const Extra = struct {
    args: []const []const u8 = &.{},
    env: []const EnvVar = &.{},
    path_prepend: []const []const u8 = &.{},
    /// Remote probes and starts run in the user's login shell environment.
    login_shell: bool = true,

    pub fn clone(self: Extra, a: std.mem.Allocator) !Extra {
        var out: Extra = .{ .login_shell = self.login_shell };
        errdefer out.free(a);
        const args = try a.alloc([]const u8, self.args.len);
        @memset(args, "");
        out.args = args;
        for (self.args, args) |s, *d| d.* = try a.dupe(u8, s);
        const dirs = try a.alloc([]const u8, self.path_prepend.len);
        @memset(dirs, "");
        out.path_prepend = dirs;
        for (self.path_prepend, dirs) |s, *d| d.* = try a.dupe(u8, s);
        const env = try a.alloc(EnvVar, self.env.len);
        @memset(env, .{ .name = "", .value = "" });
        out.env = env;
        for (self.env, env) |s, *d| {
            d.name = try a.dupe(u8, s.name);
            d.value = try a.dupe(u8, s.value);
        }
        return out;
    }

    /// Free what `clone` allocated.
    pub fn free(self: Extra, a: std.mem.Allocator) void {
        for (self.args) |s| a.free(s);
        a.free(self.args);
        for (self.path_prepend) |s| a.free(s);
        a.free(self.path_prepend);
        for (self.env) |v| {
            a.free(v.name);
            a.free(v.value);
        }
        a.free(self.env);
    }

    pub fn names(self: Extra, arena: std.mem.Allocator) ![]const []const u8 {
        const out = try arena.alloc([]const u8, self.env.len);
        for (self.env, out) |v, *o| o.* = v.name;
        return out;
    }

    /// The env as spawn-request entries ("NAME=VALUE").
    pub fn assignments(self: Extra, arena: std.mem.Allocator) ![]const []const u8 {
        const out = try arena.alloc([]const u8, self.env.len);
        for (self.env, out) |v, *o| o.* = try std.fmt.allocPrint(arena, "{s}={s}", .{ v.name, v.value });
        return out;
    }
};

/// Why `x` cannot be passed to a launch of `launch`'s binary, or null when
/// it can: the one rule for caller `args`/`env`, refused, never sanitized.
pub fn checkExtra(arena: std.mem.Allocator, launch: adapter.Launch, x: Extra) !?[]const u8 {
    if (x.args.len > MAX_EXTRA) return try std.fmt.allocPrint(arena, "args: at most {d} entries (got {d})", .{ MAX_EXTRA, x.args.len });
    for (x.args, 0..) |s, i| {
        if (s.len == 0 or s.len > MAX_EXTRA_BYTES) return try std.fmt.allocPrint(arena, "args[{d}] must be 1-{d} bytes (got {d})", .{ i, MAX_EXTRA_BYTES, s.len });
        if (try textProblem(arena, s)) |p| return try std.fmt.allocPrint(arena, "args[{d}] {s}", .{ i, p });
    }
    if (x.env.len > MAX_EXTRA) return try std.fmt.allocPrint(arena, "env: at most {d} entries (got {d})", .{ MAX_EXTRA, x.env.len });
    for (x.env, 0..) |v, i| {
        if (!validEnvName(v.name)) return try std.fmt.allocPrint(arena, "env name {f} must match [A-Za-z_][A-Za-z0-9_]* (at most {d} bytes)", .{ std.json.fmt(v.name, .{}), MAX_EXTRA_BYTES });
        for (x.env[0..i]) |prev| if (std.mem.eql(u8, prev.name, v.name)) return try std.fmt.allocPrint(arena, "env name {s} is given twice", .{v.name});
        if (launch.password_env) |pw| if (std.mem.eql(u8, pw, v.name))
            return try std.fmt.allocPrint(arena, "env {s} is the adapter's own password variable, which sketerm sets", .{v.name});
        if (v.value.len > MAX_EXTRA_BYTES) return try std.fmt.allocPrint(arena, "env {s}: the value must be at most {d} bytes (got {d})", .{ v.name, MAX_EXTRA_BYTES, v.value.len });
        if (try textProblem(arena, v.value)) |p| return try std.fmt.allocPrint(arena, "env {s}: the value {s}", .{ v.name, p });
    }
    if (x.path_prepend.len > MAX_EXTRA) return try std.fmt.allocPrint(arena, "path_prepend: at most {d} entries (got {d})", .{ MAX_EXTRA, x.path_prepend.len });
    for (x.path_prepend, 0..) |d, i| {
        if (d.len == 0 or d.len > MAX_EXTRA_BYTES) return try std.fmt.allocPrint(arena, "path_prepend[{d}] must be 1-{d} bytes (got {d})", .{ i, MAX_EXTRA_BYTES, d.len });
        if (try textProblem(arena, d)) |p| return try std.fmt.allocPrint(arena, "path_prepend[{d}] {s}", .{ i, p });
        if (d[0] != '/') return try std.fmt.allocPrint(arena, "path_prepend[{d}] must be an absolute directory", .{i});
        if (std.mem.indexOfScalar(u8, d, ':') != null) return try std.fmt.allocPrint(arena, "path_prepend[{d}] contains ':', the PATH separator", .{i});
    }
    return null;
}

/// Carries a script past the login shell's profile; the script unsets it.
const LOGIN_SCRIPT_ENV = "SKETERM_LOGIN_SCRIPT";
/// A remote daemon start carries the caller's `env` values under this
/// prefix past the login shell, which could otherwise override them.
pub const ENV_RELAY_PREFIX = "SKETERM_AGENT_ENV_";
/// How long a probe waits for the login shell before it falls back to the
/// plain environment (a profile that execs another shell never returns).
pub const LOGIN_PROBE_SECS = 10;

/// POSIX sh that picks the user's login shell: `$SHELL` (sshd sets it from
/// the passwd entry), except csh/tcsh, which refuse `-l` beside `-c` and
/// get `/bin/sh -l` (its `~/.profile`) instead.
const PICK_LOGIN_SHELL =
    "sk_ls=${SHELL:-/bin/sh}\n" ++
    "case \"${sk_ls##*/}\" in csh|tcsh) sk_ls=/bin/sh;; esac\n" ++
    "[ -x \"$sk_ls\" ] || sk_ls=/bin/sh\n";

/// The `-c` command handed to the login shell: the same text in sh, dash,
/// bash, zsh, ksh and fish, and it only re-enters POSIX sh.
const LOGIN_REENTRY = "'exec /bin/sh -c \"$" ++ LOGIN_SCRIPT_ENV ++ "\"'";

/// Export `inner` for the login shell to run (the inner script starts by
/// unsetting it, see `innerPrelude`).
fn exportLoginScript(arena: std.mem.Allocator, s: *std.ArrayList(u8), inner: []const u8) !void {
    try s.appendSlice(arena, LOGIN_SCRIPT_ENV ++ "=");
    try shellquote.appendQuoted(s, arena, inner);
    try s.appendSlice(arena, "; export " ++ LOGIN_SCRIPT_ENV ++ "\n");
}

/// POSIX sh that runs the POSIX sh `inner` in the environment of the
/// user's login shell (whatever it is), replacing this shell.
pub fn loginExec(arena: std.mem.Allocator, inner: []const u8) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, PICK_LOGIN_SHELL);
    try exportLoginScript(arena, &s, inner);
    try s.appendSlice(arena, "exec \"$sk_ls\" -l -c " ++ LOGIN_REENTRY ++ "\n");
    return s.items;
}

/// `dirs` in front of `path`, the local twin of the scripts' PATH prepend.
pub fn prependPath(arena: std.mem.Allocator, dirs: []const []const u8, path: []const u8) ![]const u8 {
    if (dirs.len == 0) return path;
    const head = try std.mem.join(arena, ":", dirs);
    return if (path.len == 0) head else std.fmt.allocPrint(arena, "{s}:{s}", .{ head, path });
}

/// What an inner script does first: drop the login carrier, prepend PATH.
fn innerPrelude(arena: std.mem.Allocator, s: *std.ArrayList(u8), login: bool, path_prepend: []const []const u8) !void {
    if (login) try s.appendSlice(arena, "unset " ++ LOGIN_SCRIPT_ENV ++ "\n");
    if (path_prepend.len == 0) return;
    try s.appendSlice(arena, "PATH=");
    for (path_prepend) |d| {
        try shellquote.appendQuoted(s, arena, d);
        try s.append(arena, ':');
    }
    try s.appendSlice(arena, "\"$PATH\"; export PATH\n");
}

fn validEnvName(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_EXTRA_BYTES) return false;
    for (s, 0..) |b, i| switch (b) {
        'A'...'Z', 'a'...'z', '_' => {},
        '0'...'9' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

/// Invalid UTF-8 or a control character (C0, DEL, C1), described.
fn textProblem(arena: std.mem.Allocator, s: []const u8) !?[]const u8 {
    const view = std.unicode.Utf8View.init(s) catch return "is not valid UTF-8";
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f))
            return try std.fmt.allocPrint(arena, "contains a control character (U+{X:0>4})", .{cp});
    }
    return null;
}

/// Whether every string of `argv` is one Linux can exec.
pub fn argvFits(argv: []const []const u8) bool {
    for (argv) |s| if (s.len >= MAX_EXEC_STRING) return false;
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

/// One lookup of a remote probe: an adapter's launch and its override;
/// `version` also asks the found binary for its `version_args` line.
pub const Lookup = struct { launch: adapter.Launch, override: ?[]const u8 = null, version: bool = false };

/// Marker lines of a probe's output.
const PROBE_BIN = "SK_BIN ";
const PROBE_NONE = "SK_NONE ";
const PROBE_DIR = "SK_DIR ";
const PROBE_VER = "SK_VER ";
const PROBE_ENV = "SK_ENV ";
const PROBE_SHELL = "SK_SHELL ";
const PROBE_END = "SK_END";

pub const ProbeOpts = struct {
    /// A remote working dir to check.
    dir: ?[]const u8 = null,
    /// Resolve in the login shell's environment (falls back to the plain one).
    login: bool = true,
    path_prepend: []const []const u8 = &.{},
    login_secs: u32 = LOGIN_PROBE_SECS,
};

/// A POSIX sh script that does `resolve` ON THE HOST IT RUNS ON, for every
/// lookup at once (one ssh round trip): `command -v` for `$PATH`, `$HOME`
/// for `~/`. It prints `SK_BIN <i> <path>` (plus `SK_VER <i> <line>` for a
/// `version` lookup) or `SK_NONE <i>` per lookup, `SK_DIR ok|missing` when
/// `dir` is given, and `SK_ENV login|plain` for the environment it used.
/// With `login`, the lookups run under the login shell, bounded by
/// `LOGIN_PROBE_SECS`; output a profile prints around them is ignored
/// (markers only), and a login run that never reaches `SK_END` is replaced
/// by a plain one.
pub fn probeScript(arena: std.mem.Allocator, lookups: []const Lookup, opts: ProbeOpts) ![]const u8 {
    const inner = try innerProbe(arena, lookups, opts);
    var s: std.ArrayList(u8) = .empty;
    if (!opts.login) {
        try s.appendSlice(arena, "echo '" ++ PROBE_ENV ++ "plain'\n");
        try s.appendSlice(arena, inner);
        return s.items;
    }
    try s.appendSlice(arena, PICK_LOGIN_SHELL);
    try s.appendSlice(arena, "printf '" ++ PROBE_SHELL ++ "%s\\n' \"$sk_ls\"\n");
    try exportLoginScript(arena, &s, inner);
    try s.appendSlice(arena, "umask 077; sk_t=/tmp/.sk_probe_$$\n");
    try s.appendSlice(arena, "\"$sk_ls\" -l -c " ++ LOGIN_REENTRY ++ " </dev/null >\"$sk_t\" 2>&1 &\nsk_p=$!\n");
    try s.print(arena, "( sleep {d}; kill \"$sk_p\" ) </dev/null >/dev/null 2>&1 &\nsk_w=$!\n", .{opts.login_secs});
    try s.appendSlice(arena, "wait \"$sk_p\" 2>/dev/null; kill \"$sk_w\" 2>/dev/null\n");
    // The end marker must be a whole line: a profile's noise may contain it.
    try s.appendSlice(arena, "if grep -qx '" ++ PROBE_END ++ "' \"$sk_t\" 2>/dev/null; then echo '" ++ PROBE_ENV ++ "login'; cat \"$sk_t\";\n" ++
        "else echo '" ++ PROBE_ENV ++ "plain'; /bin/sh -c \"$" ++ LOGIN_SCRIPT_ENV ++ "\" </dev/null; fi\n");
    try s.appendSlice(arena, "rm -f \"$sk_t\"\n");
    return s.items;
}

fn innerProbe(arena: std.mem.Allocator, lookups: []const Lookup, opts: ProbeOpts) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try innerPrelude(arena, &s, opts.login, opts.path_prepend);
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
        try s.print(arena, "if [ -n \"$p\" ]; then printf '" ++ PROBE_BIN ++ "{d} %s\\n' \"$p\"", .{i});
        if (l.version and l.launch.version_args.len > 0) {
            try s.appendSlice(arena, "; v=$(\"$p\"");
            for (l.launch.version_args) |a| {
                try s.append(arena, ' ');
                try shellquote.appendQuoted(&s, arena, a);
            }
            try s.print(arena, " </dev/null 2>&1 | sed -n '/[^[:space:]]/{{p;q;}}'); printf '" ++ PROBE_VER ++ "{d} %s\\n' \"$v\"", .{i});
        }
        try s.print(arena, "; else echo '" ++ PROBE_NONE ++ "{d}'; fi\n", .{i});
    }
    if (opts.dir) |d| {
        try s.appendSlice(arena, "if [ -d ");
        try shellquote.appendQuoted(&s, arena, d);
        try s.appendSlice(arena, " ]; then echo '" ++ PROBE_DIR ++ "ok'; else echo '" ++ PROBE_DIR ++ "missing'; fi\n");
    }
    try s.appendSlice(arena, "printf '" ++ PROBE_HOME ++ "%s\\n' \"$HOME\"\n");
    try s.appendSlice(arena, "echo '" ++ PROBE_END ++ "'\n");
    return s.items;
}

const PROBE_HOME = "SK_HOME ";

pub const ProbeResult = struct {
    /// Per lookup: the executable found, or null.
    binaries: []?[]const u8,
    /// Per lookup: the first line its `version_args` printed, or null.
    versions: []?[]const u8,
    /// Whether the lookups ran in the login shell's environment (null: not said).
    login: ?bool = null,
    /// The login shell the probe picked.
    shell: ?[]const u8 = null,
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
    const vers = try arena.alloc(?[]const u8, n);
    @memset(vers, null);
    const seen = try arena.alloc(bool, n);
    @memset(seen, false);
    var r = ProbeResult{ .binaries = bins, .versions = vers, .complete = false };
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        // A terminal transcript: CR line ends, and the marker may follow noise.
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.indexOf(u8, line, PROBE_ENV)) |at| {
            const v = line[at + PROBE_ENV.len ..];
            if (std.mem.eql(u8, v, "login")) r.login = true else if (std.mem.eql(u8, v, "plain")) r.login = false;
            continue;
        }
        if (std.mem.indexOf(u8, line, PROBE_SHELL)) |at| {
            const v = line[at + PROBE_SHELL.len ..];
            if (v.len > 0 and v[0] == '/') r.shell = v;
            continue;
        }
        if (std.mem.indexOf(u8, line, PROBE_VER)) |at| {
            const rest = line[at + PROBE_VER.len ..];
            const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            const i = std.fmt.parseInt(usize, rest[0..sp], 10) catch continue;
            const v = std.mem.trim(u8, rest[sp + 1 ..], " \t");
            if (i < n and v.len > 0) vers[i] = v;
            continue;
        }
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

/// `binary` + the caller's `extra_args` + the adapter's `args`, then
/// `session_args` (or `resume_args` for a resumed start) when a session id
/// is given, `model_args` when a model is and `effort_args` when an effort
/// level is, placeholders filled (never in `extra_args`).
pub fn mainArgv(arena: std.mem.Allocator, launch: adapter.Launch, binary: []const u8, extra_args: []const []const u8, values: Values, start: Start) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, binary);
    try out.appendSlice(arena, extra_args);
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
/// `cleanup` (the ssh transport's script file); with `login` it goes on in
/// the user's login shell environment (`loginExec`); then it prepends
/// `path_prepend` to PATH, changes to `cwd`, and with `secret_env` reads
/// that variable's value from the terminal with echo off (after printing
/// `SECRET_PROMPT`) and exports it, so the secret rides neither an argv nor
/// the spawn request. It exports `env` (values in the script, so never a
/// secret) and the `env_relay` names from their `ENV_RELAY_PREFIX` copies
/// (values in the spawn environment), then execs `argv`.
pub fn remoteScript(arena: std.mem.Allocator, argv: []const []const u8, opts: struct {
    cleanup: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    secret_env: ?[]const u8 = null,
    /// Names `checkExtra` validated.
    env: []const EnvVar = &.{},
    env_relay: []const []const u8 = &.{},
    login: bool = false,
    path_prepend: []const []const u8 = &.{},
}) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    if (opts.cleanup) |f| {
        try s.appendSlice(arena, "rm -f ");
        try shellquote.appendQuoted(&s, arena, f);
        try s.append(arena, '\n');
    }
    if (opts.login) {
        var inner_opts = opts;
        inner_opts.cleanup = null;
        inner_opts.login = false;
        var inner: std.ArrayList(u8) = .empty;
        try innerPrelude(arena, &inner, true, &.{});
        try inner.appendSlice(arena, try remoteScript(arena, argv, inner_opts));
        try s.appendSlice(arena, try loginExec(arena, inner.items));
        return s.items;
    }
    try innerPrelude(arena, &s, false, opts.path_prepend);
    if (opts.cwd) |d| {
        try s.appendSlice(arena, "cd ");
        try shellquote.appendQuoted(&s, arena, d);
        try s.appendSlice(arena, " || { echo '[sketerm] no such directory on this host'; exit 1; }\n");
    }
    if (opts.secret_env) |name| {
        // `adapter` validated the name; the value never touches argv.
        try s.print(arena, "stty -echo 2>/dev/null; printf '%s' '" ++ SECRET_PROMPT ++ "'; IFS= read -r {s}; stty echo 2>/dev/null; echo; export {s}\n", .{ name, name });
    }
    for (opts.env) |v| {
        try s.print(arena, "export {s}=", .{v.name});
        try shellquote.appendQuoted(&s, arena, v.value);
        try s.append(arena, '\n');
    }
    for (opts.env_relay) |name| try s.print(arena, "{s}=${s}{s}; export {s}; unset {s}{s}\n", .{ name, ENV_RELAY_PREFIX, name, name, ENV_RELAY_PREFIX, name });
    try s.appendSlice(arena, "exec");
    for (argv) |a| {
        try s.append(arena, ' ');
        try shellquote.appendQuoted(&s, arena, a);
    }
    try s.append(arena, '\n');
    return s.items;
}

/// `binary` + the caller's `extra_args` + the adapter's `attach_args`,
/// placeholders filled.
pub fn attachArgv(arena: std.mem.Allocator, launch: adapter.Launch, binary: []const u8, extra_args: []const []const u8, values: Values) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, binary);
    try out.appendSlice(arena, extra_args);
    try appendExpanded(arena, &out, launch.attach_args, values);
    return out.items;
}

/// Which of the adapter's argv a start runs.
pub const Run = union(enum) { main: Start, attach };

/// The argv that starts the binary for `run` with the caller's `x`:
/// `mainArgv`/`attachArgv` inside the `unset_env` wrapper that spares the
/// names `x.env` sets (the spawn or the remote script sets their values).
pub fn startArgv(arena: std.mem.Allocator, launch: adapter.Launch, binary: []const u8, x: Extra, values: Values, run: Run) ![]const []const u8 {
    const argv = switch (run) {
        .main => |start| try mainArgv(arena, launch, binary, x.args, values, start),
        .attach => try attachArgv(arena, launch, binary, x.args, values),
    };
    return withUnsetEnv(arena, launch.unset_env, try x.names(arena), argv);
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
/// removed (a trailing `*` matches a prefix) except the `keep` names. The
/// daemon's environment, not this process's, is what the child inherits,
/// so the names are matched in the child itself: `sh` lists its
/// environment, unsets the matches, then execs `argv` unchanged.
/// @param unset entries `adapter` validated (variable names, optional `*`).
/// @param keep names `checkExtra` validated: the caller's `env`, which the
/// spawn (or the remote script) sets, so it reads as applied after `unset`.
pub fn withUnsetEnv(arena: std.mem.Allocator, unset: []const []const u8, keep: []const []const u8, argv: []const []const u8) ![]const []const u8 {
    if (unset.len == 0) return argv;
    var script: std.ArrayList(u8) = .empty;
    try script.appendSlice(arena, "names=$(env | while IFS= read -r l; do case \"$l\" in ");
    for (unset, 0..) |u, i| {
        if (i > 0) try script.append(arena, '|');
        try script.appendSlice(arena, u);
        try script.appendSlice(arena, "=*");
    }
    try script.appendSlice(arena, ") printf '%s\\n' \"${l%%=*}\";; esac; done); for n in $names; do case \"$n\" in ");
    for (keep) |k| {
        try script.appendSlice(arena, k);
        try script.append(arena, '|');
    }
    try script.appendSlice(arena, "*[!A-Za-z0-9_]*) ;; *) unset \"$n\";; esac; done; exec \"$@\"");
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
    const plain = try mainArgv(a, test_launch, "/bin/oc", &.{}, .{ .port = "4100" }, .fresh);
    try t.expectEqual(@as(usize, 4), plain.len);
    try t.expectEqualStrings("4100", plain[3]);
    const with_model = try mainArgv(a, test_launch, "/bin/oc", &.{}, .{ .port = "4100", .model = "p/m" }, .fresh);
    try t.expectEqual(@as(usize, 6), with_model.len);
    try t.expectEqualStrings("p/m", with_model[5]);
    const attach = try attachArgv(a, test_launch, "/bin/oc", &.{}, .{ .port = "4100", .session = "ses_1" });
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
    const fresh = try mainArgv(a, claude, "/c", &.{}, .{ .session = "u-1", .effort = "low" }, .fresh);
    try t.expectEqualStrings("--session-id", fresh[2]);
    try t.expectEqualStrings("u-1", fresh[3]);
    try t.expectEqualStrings("low", fresh[5]);
    const resumed = try mainArgv(a, claude, "/c", &.{}, .{ .session = "u-1", .effort = "high" }, .resumed);
    try t.expectEqualStrings("--resume", resumed[2]);
    try t.expectEqualStrings("high", resumed[5]);
    // Without an id neither is added.
    try t.expectEqual(@as(usize, 2), (try mainArgv(a, claude, "/c", &.{}, .{}, .resumed)).len);
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
    }, .{ .dir = "/nonexistent-dir", .login = false });
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

/// Write `body` to `path` with mode 0755.
fn writeExec(a: std.mem.Allocator, path: []const u8, body: []const u8) !void {
    const z = try a.dupeZ(u8, path);
    const f = c.fopen(z.ptr, "w") orelse return error.SkipZigTest;
    _ = c.fwrite(body.ptr, 1, body.len, f);
    _ = c.fclose(f);
    if (c.chmod(z.ptr, 0o755) != 0) return error.SkipZigTest;
}

/// A login shell whose profile prepends `dir` to PATH and prints noise
/// that looks almost like a marker.
fn fakeLoginShell(a: std.mem.Allocator, root: []const u8, dir: []const u8, hang: bool) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}/fakeshell{s}", .{ root, if (hang) "-hang" else "" });
    try writeExec(a, path, try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\[ "$1" = -l ] || exit 99
        \\echo 'Welcome! SK_BIN is not a marker, SK_ENDING neither'
        \\{s}
        \\PATH='{s}':"$PATH"; export PATH; FROM_PROFILE=yes; export FROM_PROFILE
        \\CLAUDE_KEEP=profile-clobbered; export CLAUDE_KEEP
        \\exec /bin/sh -c "$3"
        \\
    , .{ if (hang) "exec sleep 30" else "", dir }));
    return path;
}

test "the probe resolves in the login shell's environment, profile noise and all" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmpl = "/tmp/sketerm-login-XXXXXX".*;
    const root_ptr = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const root = std.mem.span(@as([*:0]u8, @ptrCast(root_ptr)));
    defer @import("../util/pathz.zig").removeTree(root);
    const login_dir = try std.fmt.allocPrint(a, "{s}/login-bin", .{root});
    const pre_dir = try std.fmt.allocPrint(a, "{s}/pre-bin", .{root});
    _ = try runSh(a, "", try std.fmt.allocPrint(a, "mkdir -p '{s}' '{s}'", .{ login_dir, pre_dir }));
    // Only the login PATH has the app; it prints a version after a blank line.
    try writeExec(a, try std.fmt.allocPrint(a, "{s}/skapp", .{login_dir}), "#!/bin/sh\n[ \"$1\" = --version ] && { echo; echo 'skapp 9.9.9 (login)'; echo second; }\n");
    const app = adapter.Launch{ .binary = "skapp", .candidates = &.{"$PATH"}, .version_args = &.{"--version"} };
    const lookups = [_]Lookup{.{ .launch = app, .version = true }};

    const shell = try fakeLoginShell(a, root, login_dir, false);
    const env = try std.fmt.allocPrint(a, "SHELL='{s}' PATH=/usr/bin:/bin", .{shell});
    const r = try parseProbe(a, try runSh(a, env, try probeScript(a, &lookups, .{})), 1);
    try t.expect(r.complete);
    try t.expectEqual(@as(?bool, true), r.login);
    try t.expectEqualStrings(shell, r.shell.?);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/skapp", .{login_dir}), r.binaries[0].?);
    try t.expectEqualStrings("skapp 9.9.9 (login)", r.versions[0].?);

    // path_prepend wins over the login PATH (applied after it).
    try writeExec(a, try std.fmt.allocPrint(a, "{s}/skapp", .{pre_dir}), "#!/bin/sh\necho 'skapp 1.0 (pre)'\n");
    const pre = try parseProbe(a, try runSh(a, env, try probeScript(a, &lookups, .{ .path_prepend = &.{pre_dir} })), 1);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/skapp", .{pre_dir}), pre.binaries[0].?);
    try t.expectEqualStrings("skapp 1.0 (pre)", pre.versions[0].?);

    // Without the login shell the plain PATH has no app: reported as such.
    const plain = try parseProbe(a, try runSh(a, env, try probeScript(a, &lookups, .{ .login = false })), 1);
    try t.expect(plain.complete);
    try t.expectEqual(@as(?bool, false), plain.login);
    try t.expect(plain.binaries[0] == null);

    // A profile that never returns costs the bound, then the plain run answers.
    const hang = try fakeLoginShell(a, root, login_dir, true);
    const started = @import("../util/clock.zig").nowMs();
    const hung = try parseProbe(a, try runSh(a, try std.fmt.allocPrint(a, "SHELL='{s}' PATH=/usr/bin:/bin", .{hang}), try probeScript(a, &lookups, .{ .login_secs = 1 })), 1);
    try t.expect(hung.complete);
    try t.expectEqual(@as(?bool, false), hung.login);
    try t.expect(@import("../util/clock.zig").nowMs() - started < 8_000);
}

test "a remote start runs in the login environment, then path_prepend, env and relayed env" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmpl = "/tmp/sketerm-login-XXXXXX".*;
    const root_ptr = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const root = std.mem.span(@as([*:0]u8, @ptrCast(root_ptr)));
    defer @import("../util/pathz.zig").removeTree(root);
    const shell = try fakeLoginShell(a, root, "/login/dir", false);
    const argv = try weirdArgv(a, root);
    const probe = [_][]const u8{ "/bin/sh", "-c", "printf 'P=%s F=%s L=%s\\n' \"$PATH\" \"$FROM_PROFILE\" \"${SKETERM_LOGIN_SCRIPT-unset}\"" };
    const env = try std.fmt.allocPrint(a, "SHELL='{s}' PATH=/usr/bin:/bin", .{shell});
    // Plain ssh: values in the script.
    const out = try runSh(a, env, try remoteScript(a, &probe, .{ .login = true, .path_prepend = &.{"/pre dir"} }));
    try t.expect(std.mem.indexOf(u8, out, "P=/pre dir:/login/dir:/usr/bin:/bin F=yes L=unset") != null);
    // The caller's env beats the profile's, byte-exact, args too.
    const run = try remoteScript(a, argv, .{ .cwd = root, .env = &WEIRD_ENV, .login = true });
    const got = try runSh(a, try std.fmt.allocPrint(a, "{s} CLAUDE_DROP=1 CLAUDE_KEEP=old", .{env}), run);
    try t.expect(std.mem.endsWith(u8, got, try expectedEcho(a)));
    // A remote daemon start: values ride the spawn env under the relay prefix.
    var relay_env: std.ArrayList(u8) = .empty;
    try relay_env.appendSlice(a, env);
    try relay_env.appendSlice(a, " CLAUDE_DROP=1");
    for (WEIRD_ENV) |v| {
        try relay_env.print(a, " " ++ ENV_RELAY_PREFIX ++ "{s}=", .{v.name});
        try shellquote.appendQuoted(&relay_env, a, v.value);
    }
    const relayed = try runSh(a, relay_env.items, try remoteScript(a, argv, .{ .cwd = root, .env_relay = &.{ "CLAUDE_KEEP", "PLAIN_SET" }, .login = true }));
    try t.expect(std.mem.endsWith(u8, relayed, try expectedEcho(a)));
}

test "real login shells on this machine: bash, zsh, dash and fish profiles reach the probe" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmpl = "/tmp/sketerm-login-XXXXXX".*;
    const root_ptr = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const root = std.mem.span(@as([*:0]u8, @ptrCast(root_ptr)));
    defer @import("../util/pathz.zig").removeTree(root);
    const dir = try std.fmt.allocPrint(a, "{s}/profile-bin", .{root});
    _ = try runSh(a, "", try std.fmt.allocPrint(a, "mkdir -p '{s}' '{s}/.config/fish'", .{ dir, root }));
    try writeExec(a, try std.fmt.allocPrint(a, "{s}/skreal", .{dir}), "#!/bin/sh\necho skreal 2.0\n");
    const app = adapter.Launch{ .binary = "skreal", .candidates = &.{"$PATH"}, .version_args = &.{"--version"} };
    const Case = struct { shell: []const u8, profile: []const u8, line: []const u8 };
    const cases = [_]Case{
        .{ .shell = "/usr/bin/bash", .profile = ".bash_profile", .line = "PATH=\"{s}:$PATH\"; export PATH; echo bash-profile-noise\n" },
        .{ .shell = "/usr/bin/zsh", .profile = ".zprofile", .line = "path=({s} $path); echo zsh-noise\n" },
        .{ .shell = "/usr/bin/dash", .profile = ".profile", .line = "PATH=\"{s}:$PATH\"; export PATH\n" },
        .{ .shell = "/usr/bin/fish", .profile = ".config/fish/config.fish", .line = "set -gx PATH {s} $PATH; echo fish-noise\n" },
    };
    var ran: usize = 0;
    inline for (cases) |cs| if (isExecutable(cs.shell)) {
        try writeExec(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ root, cs.profile }), try std.fmt.allocPrint(a, cs.line, .{dir}));
        const env = try std.fmt.allocPrint(a, "env -i HOME='{s}' SHELL='{s}' PATH=/usr/bin:/bin", .{ root, cs.shell });
        const out = try runSh(a, env, try probeScript(a, &.{.{ .launch = app, .version = true }}, .{}));
        const r = try parseProbe(a, out, 1);
        if (r.binaries[0] == null or r.login != true) std.debug.print("{s} probe output:\n{s}\n", .{ cs.shell, out });
        try t.expectEqual(@as(?bool, true), r.login);
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/skreal", .{dir}), r.binaries[0].?);
        try t.expectEqualStrings("skreal 2.0", r.versions[0].?);
        ran += 1;
    };
    if (ran == 0) return error.SkipZigTest;
}

test "path_prepend is refused, never cleaned: relative, PATH separator, control bytes" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = adapter.Launch{ .binary = "x", .candidates = &.{} };
    try t.expect((try checkExtra(a, l, .{ .path_prepend = &.{ "/opt/my tools/bin", "/a" } })) == null);
    try t.expect(std.mem.indexOf(u8, (try checkExtra(a, l, .{ .path_prepend = &.{"rel/bin"} })).?, "absolute") != null);
    try t.expect(std.mem.indexOf(u8, (try checkExtra(a, l, .{ .path_prepend = &.{"/a:/b"} })).?, "PATH separator") != null);
    try t.expect(std.mem.indexOf(u8, (try checkExtra(a, l, .{ .path_prepend = &.{"/a\nb"} })).?, "control character") != null);
    try t.expect(std.mem.indexOf(u8, (try checkExtra(a, l, .{ .path_prepend = &.{""} })).?, "1-4096 bytes") != null);
    const copy = try (Extra{ .path_prepend = &.{"/a"}, .login_shell = false }).clone(t.allocator);
    defer copy.free(t.allocator);
    try t.expectEqualStrings("/a", copy.path_prepend[0]);
    try t.expect(!copy.login_shell);
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
    try t.expectEqual(@as(usize, 1), (try withUnsetEnv(a, &.{}, &.{}, &.{"x"})).len);
    const argv = try withUnsetEnv(a, &.{ "CLAUDE*", "DROP_ME" }, &.{}, &.{"env"});
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

test "caller args and env: every refusal, never a sanitized value" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const oc = adapter.Launch{ .binary = "opencode", .candidates = &.{}, .password_env = "OC_PW" };
    const ok = Extra{
        .args = &.{ "--profile", "a b 'c' \"d\" $e ;f `g` *h \\i caf\xc3\xa9" },
        .env = &.{ .{ .name = "CLAUDE_CAPTURE_PROFILE", .value = "work" }, .{ .name = "_x9", .value = "" } },
    };
    try t.expect((try checkExtra(a, oc, ok)) == null);
    try t.expect((try checkExtra(a, oc, .{})) == null);

    const many = try a.alloc([]const u8, MAX_EXTRA + 1);
    @memset(many, "x");
    try t.expect((try checkExtra(a, oc, .{ .args = many[0..MAX_EXTRA] })) == null);
    const long = try a.alloc(u8, MAX_EXTRA_BYTES + 1);
    @memset(long, 'y');
    const max_env = try a.alloc(EnvVar, MAX_EXTRA + 1);
    for (max_env, 0..) |*v, i| v.* = .{ .name = try std.fmt.allocPrint(a, "V{d}", .{i}), .value = long[0..MAX_EXTRA_BYTES] };
    try t.expect((try checkExtra(a, oc, .{ .args = &.{long[0..MAX_EXTRA_BYTES]}, .env = max_env[0..MAX_EXTRA] })) == null);

    const Case = struct { x: Extra, says: []const u8 };
    const cases = [_]Case{
        .{ .x = .{ .args = many }, .says = "args: at most 64" },
        .{ .x = .{ .args = &.{""} }, .says = "args[0] must be 1-4096 bytes" },
        .{ .x = .{ .args = &.{ "ok", long } }, .says = "args[1] must be 1-4096 bytes" },
        .{ .x = .{ .args = &.{"a\nb"} }, .says = "args[0] contains a control character (U+000A)" },
        .{ .x = .{ .args = &.{"a\x00b"} }, .says = "U+0000" },
        .{ .x = .{ .args = &.{"tab\there"} }, .says = "U+0009" },
        .{ .x = .{ .args = &.{"del\x7f"} }, .says = "U+007F" },
        .{ .x = .{ .args = &.{"c1\xc2\x85"} }, .says = "U+0085" },
        .{ .x = .{ .args = &.{"bad\xff"} }, .says = "args[0] is not valid UTF-8" },
        .{ .x = .{ .env = max_env }, .says = "env: at most 64" },
        .{ .x = .{ .env = &.{.{ .name = "", .value = "v" }} }, .says = "must match" },
        .{ .x = .{ .env = &.{.{ .name = "9LIVES", .value = "v" }} }, .says = "must match" },
        .{ .x = .{ .env = &.{.{ .name = "A-B", .value = "v" }} }, .says = "must match" },
        .{ .x = .{ .env = &.{.{ .name = "A=B", .value = "v" }} }, .says = "must match" },
        .{ .x = .{ .env = &.{ .{ .name = "X", .value = "1" }, .{ .name = "X", .value = "2" } } }, .says = "given twice" },
        .{ .x = .{ .env = &.{.{ .name = "OC_PW", .value = "v" }} }, .says = "password variable" },
        .{ .x = .{ .env = &.{.{ .name = "X", .value = long }} }, .says = "at most 4096 bytes" },
        .{ .x = .{ .env = &.{.{ .name = "X", .value = "a\rb" }} }, .says = "env X: the value contains a control character (U+000D)" },
        .{ .x = .{ .env = &.{.{ .name = "X", .value = "\xc3" }} }, .says = "env X: the value is not valid UTF-8" },
    };
    for (cases) |cs| {
        const msg = (try checkExtra(a, oc, cs.x)) orelse {
            std.debug.print("accepted, expected a refusal saying: {s}\n", .{cs.says});
            return error.TestUnexpectedResult;
        };
        if (std.mem.indexOf(u8, msg, cs.says) == null) {
            std.debug.print("refusal {s} does not say {s}\n", .{ msg, cs.says });
            return error.TestUnexpectedResult;
        }
    }

    // A clone owns everything and frees cleanly.
    const copy = try ok.clone(t.allocator);
    defer copy.free(t.allocator);
    try t.expectEqualStrings(ok.args[1], copy.args[1]);
    try t.expectEqualStrings("work", copy.env[0].value);
    try t.expectEqualStrings("CLAUDE_CAPTURE_PROFILE=work", (try ok.assignments(a))[0]);
    try t.expectEqualStrings("_x9", (try ok.names(a))[1]);
    try t.expect(argvFits(&.{ "a", long }));
    const huge = try a.alloc(u8, MAX_EXEC_STRING);
    try t.expect(!argvFits(&.{ "a", huge }));
}

test "caller args come right after the binary, before the adapter's own" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const extra: []const []const u8 = &.{ "--profile", "work" };
    const main = try mainArgv(a, test_launch, "/w", extra, .{ .port = "4100", .model = "p/m" }, .fresh);
    const want_main = [_][]const u8{ "/w", "--profile", "work", "serve", "--port", "4100", "--model", "p/m" };
    try t.expectEqual(want_main.len, main.len);
    for (want_main, main) |w, g| try t.expectEqualStrings(w, g);
    const attach = try attachArgv(a, test_launch, "/w", extra, .{ .port = "4100", .session = "s" });
    try t.expectEqualStrings("--profile", attach[1]);
    try t.expectEqualStrings("attach", attach[3]);
    // Placeholders are the adapter's: a caller's `{port}` stays literal.
    const lit = try mainArgv(a, test_launch, "/w", &.{"{port}"}, .{ .port = "4100" }, .fresh);
    try t.expectEqualStrings("{port}", lit[1]);
}

/// Every byte a shell treats specially, in args and env values.
const WEIRD_ARGS = [_][]const u8{
    "a b",                  "it's",  "\"dq\"",                   "$HOME",              "${x:-y}", "$(id)", "`id`",
    "semi;colon",           "*",     "glob*?[a]",                "back\\slash",        "'\\''",   "-dash", "~tilde",
    "!bang & | <in> #hash", "%s %d", "caf\xc3\xa9 \xe2\x9c\x93", "--ax-screen-reader",
};
const WEIRD_ENV = [_]EnvVar{
    .{ .name = "CLAUDE_KEEP", .value = "a b $c 'q' \"d\" `e` ;f *g \\h $(id) caf\xc3\xa9" },
    .{ .name = "PLAIN_SET", .value = "" },
};

/// A script that prints its argv, then three variables, NUL-separated.
fn echoScript(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}/echo args", .{dir});
    const z = try a.dupeZ(u8, path);
    const f = c.fopen(z.ptr, "w") orelse return error.SkipZigTest;
    const body = "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done\n" ++
        "printf 'KEEP=%s\\0PLAIN=%s\\0DROP=%s\\0' \"${CLAUDE_KEEP-unset}\" \"${PLAIN_SET-unset}\" \"${CLAUDE_DROP-unset}\"\n";
    _ = c.fwrite(body.ptr, 1, body.len, f);
    _ = c.fclose(f);
    if (c.chmod(z.ptr, 0o755) != 0) return error.SkipZigTest;
    return path;
}

/// What `echoScript` prints given the weird args, the adapter's
/// `--adapter-arg` and the weird env, with CLAUDE_DROP removed.
fn expectedEcho(a: std.mem.Allocator) ![]const u8 {
    var want: std.ArrayList(u8) = .empty;
    for (WEIRD_ARGS) |arg| {
        try want.appendSlice(a, arg);
        try want.append(a, 0);
    }
    try want.appendSlice(a, "--adapter-arg\x00");
    try want.print(a, "KEEP={s}\x00PLAIN=\x00DROP=unset\x00", .{WEIRD_ENV[0].value});
    return want.items;
}

/// The weird args and env through the unset wrapper, in a fresh dir.
fn weirdArgv(a: std.mem.Allocator, root: []const u8) ![]const []const u8 {
    const x = Extra{ .args = &WEIRD_ARGS, .env = &WEIRD_ENV };
    try t.expect((try checkExtra(a, .{ .binary = "x", .candidates = &.{} }, x)) == null);
    const l = adapter.Launch{ .binary = "x", .candidates = &.{}, .args = &.{"--adapter-arg"}, .unset_env = &.{"CLAUDE*"} };
    return startArgv(a, l, try echoScript(a, root), x, .{}, .{ .main = .fresh });
}

test "caller args and env reach the child byte-exact through the unset wrapper" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmpl = "/tmp/sketerm-extra-XXXXXX".*;
    const root_ptr = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const root = std.mem.span(@as([*:0]u8, @ptrCast(root_ptr)));
    defer @import("../util/pathz.zig").removeTree(root);
    const argv = try weirdArgv(a, root);
    // The spawn's environment: the daemon's own (CLAUDE_DROP, an older
    // CLAUDE_KEEP) overridden by the caller's, as `pty` putenv()s it.
    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(a, "env CLAUDE_DROP=1 CLAUDE_KEEP=old");
    for (try (Extra{ .env = &WEIRD_ENV }).assignments(a)) |kv| {
        try cmd.append(a, ' ');
        try shellquote.appendQuoted(&cmd, a, kv);
    }
    for (argv) |arg| {
        try cmd.append(a, ' ');
        try shellquote.appendQuoted(&cmd, a, arg);
    }
    try t.expectEqualStrings(try expectedEcho(a), try runSh(a, "", try std.fmt.allocPrint(a, "exec {s}", .{cmd.items})));
}

test "the remote start script exports the caller's env and execs args byte-exact" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmpl = "/tmp/sketerm-extra-XXXXXX".*;
    const root_ptr = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const root = std.mem.span(@as([*:0]u8, @ptrCast(root_ptr)));
    defer @import("../util/pathz.zig").removeTree(root);
    const argv = try weirdArgv(a, root);
    // Plain ssh: no spawn environment, the script carries it.
    const run = try remoteScript(a, argv, .{ .cwd = root, .env = &WEIRD_ENV });
    try t.expectEqualStrings(try expectedEcho(a), try runSh(a, "CLAUDE_DROP=1 CLAUDE_KEEP=old", run));
}
