//! `sketerm mux` — session management CLI + TUI picker.
//!
//! `sketerm mux` with no arguments opens a raw-mode TUI listing the
//! daemon's sessions: ↑/↓/j/k select, Enter attaches the session, n
//! spawns a new durable session, x kills the selected session, q/Esc
//! quits.
//!
//! WHERE an attach shows up depends on where the command runs. Inside
//! a sketerm pane (SKETERM_PANE_ID set) the running GUI takes over
//! that pane or opens a tab, as before. On any OTHER terminal — a
//! VT, kitty, an ssh client — the session is shown right here,
//! tmux-style, through `mux_tty.zig`; `--alternate` forces that even
//! inside sketerm, `--new-tab` forces the GUI even outside it.
//!
//! Subcommands for scripting: list, attach <name>, kill <name>, new.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const mux_client = @import("../mux/client.zig");
const channel_pump = @import("../mux/channel_pump.zig");
const deploy = @import("../mux/deploy.zig");
const clock = @import("../util/clock.zig");
const mux_daemon = @import("../mux/daemon.zig");
const mux_wire = @import("../mux/wire.zig");
const pulse = @import("../mux/pulse.zig");
const ipc_client = @import("client.zig");
const mux_tty = @import("mux_tty.zig");

const MUX_HELP =
    \\Usage: sketerm mux [host] [--alternate] [command]
    \\
    \\No command: interactive session picker (TUI) — local daemon,
    \\or <host>'s daemon (UDP when reachable, SSH fallback).
    \\  Up/Down or j/k  select        Enter  attach
    \\  n  new durable session        x      kill selected session
    \\  r  rename selected session    q / Esc  quit
    \\
    \\Where a session shows up: inside a sketerm pane the GUI takes
    \\that pane over (or opens a tab); on any OTHER terminal the
    \\session is shown right here, tmux-style. In that mode
    \\  Ctrl-\ Ctrl-\  (or Ctrl-\ d)  detach -- the session keeps running
    \\  Ctrl-\ [       scroll back (PgUp/PgDn/j/k/g/G; q returns)
    \\  Ctrl-\ \       send a literal Ctrl-\
    \\Only the shell exiting ends a session; detaching never does.
    \\  --alternate    show it here even inside a sketerm pane
    \\  --new-tab      open a GUI tab even from another terminal
    \\
    \\Commands (each accepts an optional leading host):
    \\  list                  print sessions
    \\  attach <name>         attach a session (here, or as a GUI tab)
    \\      --new-tab    always a NEW GUI tab; without it, running this
    \\                   INSIDE a pane takes over that pane (tmux-style)
    \\      --read-only  view a forwarded app without driving it
    \\      --control    take the app's controller lease by force
    \\  attach-all            attach EVERY session not already shown
    \\                        (bulk handoff after a move/crash; GUI only)
    \\  new                   spawn a durable session and attach it
    \\  kill <name>           kill a session
    \\  rename <old> <new>    rename a session
    \\
    \\Headless commands (no GUI needed; talk to the daemon directly):
    \\  spawn <name> [opts] [command...]   create a session
    \\      --cwd DIR --rows N --cols N    (default: login shell, 80x24)
    \\  send <name> [opts] <text...>       write text to the session PTY
    \\      --enter     append Enter (CR) after the text
    \\      --type      emulate human typing (paced keystrokes)
    \\      --delay MS  base inter-key delay  (default 60)
    \\      --jitter MS random extra delay    (default 90)
    \\  get-text <name> [--scrollback]     print the session's screen
    \\  search <pattern>                   case-insensitive substring
    \\      search across every session's scrollback + screen; prints
    \\      "name:-N: line" (N = lines up from the bottom)
    \\  forward <local[:remote]>           tunnel 127.0.0.1:<local> to
    \\      127.0.0.1:<remote> on the daemon's host over the mux
    \\      connection (SSH/UDP transports included); runs until killed
    \\
    \\Headless GUI apps (no screen needed): `sketerm run <command...>`
    \\runs a command against a private Wayland display and exits with
    \\its status (the Xvfb/xvfb-run replacement); `sketerm-mux display
    \\<create|run|inspect|list|destroy>` manages persistent ones.
    \\
    \\`sketerm ssh <host>` = `sketerm mux <host> new` — open a
    \\remote shell that survives disconnects (key auth required).
    \\Bare hosts select transport automatically; udp:<host>, ssh:<host>,
    \\and tor:<host> force one transport. Tor never falls back direct.
    \\
;

pub const SessionInfo = struct {
    name: []const u8,
    origin_name: []const u8 = "",
    origin_id: []const u8 = "",
    rows: u16 = 0,
    cols: u16 = 0,
    clients: u32 = 0,
    /// Explicit terminal viewers from new daemons; absent means the old
    /// daemon's clients count is the only available approximation.
    viewers: ?u32 = null,
    exited: bool = false,
    title: []const u8 = "",
    app: bool = false,
    /// Ms since last output, computed daemon-side. 0 from an older daemon
    /// that doesn't report it → shown as "active" (harmless default).
    idle_ms: i64 = 0,
    /// Child cwd (daemon-resolved). Empty from an older daemon.
    cwd: []const u8 = "",
    /// An uncorked audio stream is playing right now (false from an
    /// older daemon) — how "what is making that sound?" gets answered.
    audio: bool = false,
    audio_streams: []pulse.AudioInfo = &.{},

    pub fn viewerCount(self: SessionInfo) u32 {
        return self.viewers orelse self.clients;
    }
};

test "session metadata prefers explicit viewers and falls back for old daemons" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old = try std.json.parseFromSliceLeaky(SessionInfo, arena, "{\"name\":\"old\",\"clients\":3}", .{});
    try t.expectEqual(@as(u32, 3), old.viewerCount());
    const current = try std.json.parseFromSliceLeaky(SessionInfo, arena, "{\"name\":\"new\",\"clients\":4,\"viewers\":1}", .{});
    try t.expectEqual(@as(u32, 1), current.viewerCount());
}

/// Human-readable activity for the `idle_ms` a session reports. Recent output
/// reads as "active"; otherwise a coarse age ("idle 5m", "idle 2h13m").
fn fmtIdle(buf: []u8, idle_ms: i64) [:0]const u8 {
    if (idle_ms < 2000) return "active";
    const secs: i64 = @divTrunc(idle_ms, 1000);
    if (secs < 60) return std.fmt.bufPrintZ(buf, "idle {d}s", .{secs}) catch "idle";
    const mins = @divTrunc(secs, 60);
    if (mins < 60) return std.fmt.bufPrintZ(buf, "idle {d}m", .{mins}) catch "idle";
    const hours = @divTrunc(mins, 60);
    if (hours < 24) return std.fmt.bufPrintZ(buf, "idle {d}h{d}m", .{ hours, @mod(mins, 60) }) catch "idle";
    const days = @divTrunc(hours, 24);
    return std.fmt.bufPrintZ(buf, "idle {d}d{d}h", .{ days, @mod(hours, 24) }) catch "idle";
}

test "fmtIdle: thresholds and coarse buckets" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("active", fmtIdle(&buf, 0));
    try std.testing.expectEqualStrings("active", fmtIdle(&buf, 1999));
    try std.testing.expectEqualStrings("idle 2s", fmtIdle(&buf, 2000));
    try std.testing.expectEqualStrings("idle 59s", fmtIdle(&buf, 59_000));
    try std.testing.expectEqualStrings("idle 1m", fmtIdle(&buf, 60_000));
    try std.testing.expectEqualStrings("idle 2h13m", fmtIdle(&buf, (2 * 3600 + 13 * 60) * 1000));
    try std.testing.expectEqualStrings("idle 3d4h", fmtIdle(&buf, (3 * 86400 + 4 * 3600) * 1000));
}

pub const Welcome = struct {
    proto: u32 = 0,
    sessions: []SessionInfo = &.{},
};

fn isSubcommand(s2: []const u8) bool {
    const known = [_][]const u8{ "list", "attach", "attach-all", "new", "kill", "rename", "spawn", "send", "get-text", "search", "forward" };
    for (known) |k| {
        if (std.mem.eql(u8, s2, k)) return true;
    }
    return false;
}

/// Where an attach/new should land, decided once per invocation.
pub const Placement = struct {
    /// `--alternate`: in-terminal even inside a sketerm pane.
    alternate: bool = false,

    /// In-terminal viewing wins on a real tty outside any sketerm pane;
    /// `--new-tab` asks for the GUI explicitly and always gets it.
    pub fn inTerminal(self: Placement, new_tab: bool, inside_pane: bool, is_tty: bool) bool {
        if (new_tab) return false;
        if (self.alternate) return true;
        return !inside_pane and is_tty;
    }

    fn inTerminalHere(self: Placement, new_tab: bool) bool {
        const is_tty = c.isatty(0) != 0 and c.isatty(1) != 0;
        return self.inTerminal(new_tab, c.getenv("SKETERM_PANE_ID") != null, is_tty);
    }
};

test "Placement: outside sketerm a tty attaches here, inside it the GUI does, flags override" {
    const t = std.testing;
    const plain: Placement = .{};
    try t.expect(plain.inTerminal(false, false, true));
    try t.expect(!plain.inTerminal(false, true, true));
    try t.expect(!plain.inTerminal(false, false, false)); // piped: scripts keep the GUI contract
    try t.expect(!plain.inTerminal(true, false, true)); // --new-tab
    const alt: Placement = .{ .alternate = true };
    try t.expect(alt.inTerminal(false, true, true));
    try t.expect(!alt.inTerminal(true, true, true));
}

/// Drop every `--alternate` from `args` (it may sit anywhere: before
/// the host, before or after the subcommand). Caller frees.
fn stripAlternate(allocator: std.mem.Allocator, args: []const []const u8, placement: *Placement) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    errdefer kept.deinit(allocator);
    for (args) |a| {
        if (std.mem.eql(u8, a, "--alternate") or std.mem.eql(u8, a, "-A")) {
            placement.alternate = true;
        } else {
            try kept.append(allocator, a);
        }
    }
    return kept.toOwnedSlice(allocator);
}

test "stripAlternate: removes the flag wherever it sits" {
    const t = std.testing;
    var p: Placement = .{};
    const out = try stripAlternate(t.allocator, &.{ "--alternate", "box", "attach", "--alternate", "work" }, &p);
    defer t.allocator.free(out);
    try t.expect(p.alternate);
    try t.expectEqual(@as(usize, 3), out.len);
    try t.expectEqualStrings("box", out[0]);
    try t.expectEqualStrings("work", out[2]);
}

pub fn run(allocator: std.mem.Allocator, args_in: []const []const u8) u8 {
    var placement: Placement = .{};
    const stripped = stripAlternate(allocator, args_in, &placement) catch return 1;
    defer allocator.free(stripped);
    // Optional leading host: anything that isn't a known subcommand
    // or flag ("sketerm mux user@box [cmd]").
    var host: ?[]const u8 = null;
    var args = stripped;
    var domain_spec: ?[]u8 = null;
    defer if (domain_spec) |s| allocator.free(s);
    if (args.len > 0 and !isSubcommand(args[0]) and !std.mem.startsWith(u8, args[0], "-")) {
        host = args[0];
        args = args[1..];
        // A bare name may be a [domain.<name>] from config.conf —
        // resolve it to its transport-prefixed host spec.
        var cfg = @import("../config.zig").Config.load(allocator);
        defer cfg.deinit();
        if (cfg.resolveDomain(host.?, allocator)) |spec| {
            domain_spec = spec;
            host = spec;
        }
    }
    if (args.len == 0) return tui(allocator, host, placement);
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        _ = c.fputs(MUX_HELP, platform.stdout());
        return 0;
    }
    // `mux spawn --help` (any subcommand): the word after the
    // subcommand is normally a session NAME, so without this a help
    // request would create a session literally named "--help".
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        _ = c.fputs(MUX_HELP, platform.stdout());
        return 0;
    }
    if (std.mem.eql(u8, cmd, "list")) {
        var sessions = fetchSessions(allocator, host) orelse return 1;
        defer sessions.deinit();
        for (sessions.value.sessions) |s| {
            var idle_buf: [32]u8 = undefined;
            _ = c.printf(
                "%-24.*s %-5s %ux%u  %u client(s)  %-11s%s  %.*s  %.*s\n",
                @as(c_int, @intCast(s.name.len)),
                s.name.ptr,
                @as([*:0]const u8, if (s.app) "app" else "shell"),
                @as(c_uint, s.cols),
                @as(c_uint, s.rows),
                @as(c_uint, s.viewerCount()),
                fmtIdle(&idle_buf, s.idle_ms).ptr,
                @as([*:0]const u8, if (s.exited) " [exited]" else if (s.audio) " [audio]" else ""),
                @as(c_int, @intCast(s.cwd.len)),
                s.cwd.ptr,
                @as(c_int, @intCast(s.title.len)),
                s.title.ptr,
            );
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "attach") and args.len >= 2) {
        const opts = AttachArgs.parse(args[1..]);
        const name = opts.target orelse {
            _ = c.fprintf(platform.stderr(), "sketerm mux: attach needs a session name\n");
            return 1;
        };
        if (placement.inTerminalHere(opts.new_tab)) {
            return switch (ttyAttach(allocator, host, name, opts.lease)) {
                .detached, .exited => 0,
                .lost, .failed => 1,
            };
        }
        if (opts.takesOverPane(c.getenv("SKETERM_PANE_ID") != null)) {
            const note = "sketerm mux: attaching INTO this pane (its shell is replaced); use --new-tab to open a tab instead\n";
            _ = c.fprintf(platform.stderr(), note);
        }
        return if (guiCommandLease(allocator, "attach-session", name, host, !opts.new_tab, opts.lease)) 0 else 1;
    }
    if (std.mem.eql(u8, cmd, "attach-all")) {
        return if (guiCommand(allocator, "attach-all", null, host, false)) 0 else 1;
    }
    if (std.mem.eql(u8, cmd, "new")) {
        if (placement.inTerminalHere(false)) {
            return switch (ttyNew(allocator, host)) {
                .detached, .exited => 0,
                .lost, .failed => 1,
            };
        }
        return if (guiCommand(allocator, "new-durable-tab", null, host, true)) 0 else 1;
    }
    if (std.mem.eql(u8, cmd, "kill") and args.len >= 2) {
        if (killSession(allocator, host, args[1])) return 0;
        _ = c.fprintf(platform.stderr(), "sketerm mux: kill failed\n");
        return 1;
    }
    if (std.mem.eql(u8, cmd, "rename") and args.len >= 3) {
        return if (renameSession(allocator, host, args[1], args[2])) 0 else 1;
    }
    if (std.mem.eql(u8, cmd, "spawn") and args.len >= 2) {
        return muxSpawn(allocator, host, args[1], args[2..]);
    }
    if (std.mem.eql(u8, cmd, "send") and args.len >= 2) {
        return muxSend(allocator, host, args[1], args[2..]);
    }
    if (std.mem.eql(u8, cmd, "get-text") and args.len >= 2) {
        return muxGetText(allocator, host, args[1], args[2..]);
    }
    if (std.mem.eql(u8, cmd, "search") and args.len >= 2) {
        return muxSearch(allocator, host, args[1]);
    }
    if (std.mem.eql(u8, cmd, "forward") and args.len >= 2) {
        return muxForward(allocator, host, args[1]);
    }
    _ = c.fputs(MUX_HELP, platform.stdout());
    return 2;
}

// ── headless commands ───────────────────────────────────────────

fn msleep(ms: u32) void {
    var ts: c.struct_timespec = .{
        .tv_sec = ms / 1000,
        .tv_nsec = @as(c_long, ms % 1000) * 1_000_000,
    };
    _ = c.nanosleep(&ts, null);
}

fn clockSeed() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @bitCast(@as(i64, ts.tv_nsec))) ^ (@as(u64, @bitCast(@as(i64, ts.tv_sec))) << 20);
}

/// Create a session without involving a GUI. Locally the daemon is
/// auto-started; over SSH/UDP the proxy bootstrap already does that.
fn muxSpawn(allocator: std.mem.Allocator, host: ?[]const u8, name: []const u8, rest: []const []const u8) u8 {
    var cwd: ?[]const u8 = null;
    var rows: u16 = 24;
    var cols: u16 = 80;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--cwd") and i + 1 < rest.len) {
            i += 1;
            cwd = rest[i];
        } else if (std.mem.eql(u8, a, "--rows") and i + 1 < rest.len) {
            i += 1;
            rows = std.fmt.parseInt(u16, rest[i], 10) catch 24;
        } else if (std.mem.eql(u8, a, "--cols") and i + 1 < rest.len) {
            i += 1;
            cols = std.fmt.parseInt(u16, rest[i], 10) catch 80;
        } else {
            // First non-flag word starts the command; everything
            // after belongs to it verbatim ("spawn s top -d 1").
            argv.appendSlice(allocator, rest[i..]) catch return 1;
            break;
        }
    }

    var conn = connectForSpawn(allocator, host) orelse return 1;
    defer conn.deinit();
    switch (spawnOn(allocator, &conn, host, name, cwd, rows, cols, argv.items)) {
        .ok => {},
        .name_taken => {
            _ = c.fprintf(platform.stderr(), "sketerm mux: session '%.*s' already exists\n", @as(c_int, @intCast(name.len)), name.ptr);
            return 1;
        },
        .failed => return 1,
    }
    _ = c.printf("%.*s\n", @as(c_int, @intCast(name.len)), name.ptr);
    return 0;
}

/// A connection that can create sessions: the local daemon is
/// auto-started, a remote one is reached through its proxy bootstrap.
fn connectForSpawn(allocator: std.mem.Allocator, host: ?[]const u8) ?mux_client.Conn {
    if (host != null) return muxConnect(allocator, host);
    return mux_client.Conn.connectLocalAutostart(allocator) catch {
        _ = c.fprintf(platform.stderr(), "sketerm mux: cannot start the local daemon\n");
        return null;
    };
}

/// Spawn `name` on `conn` with the configured shell (or `argv`), and
/// wait for the daemon's answer. Shared by `spawn` and the in-terminal
/// `new`.
fn spawnOn(
    allocator: std.mem.Allocator,
    conn: *mux_client.Conn,
    host: ?[]const u8,
    name: []const u8,
    cwd: ?[]const u8,
    rows: u16,
    cols: u16,
    argv: []const []const u8,
) SpawnResult {
    var cfg = @import("../config.zig").Config.load(allocator);
    defer cfg.deinit();
    const settings = cfg.profileSettings(cfg.default_profile);
    const spawn_argv: []const []const u8 = if (argv.len > 0)
        argv
    else if (host != null)
        &@import("../mux/shell.zig").remote_login_argv
    else if (settings.shell) |shell|
        &.{shell}
    else
        &.{@import("../mux/shell.zig").accountLoginShell()};
    var remote_shell_buf: [512]u8 = undefined;
    var remote_env_items: [2][]const u8 = undefined;
    var remote_env_len: usize = 0;
    if (argv.len == 0 and host != null) {
        if (settings.shell) |shell| {
            remote_env_items[remote_env_len] = std.fmt.bufPrint(&remote_shell_buf, "SKETERM_REMOTE_SHELL={s}", .{shell}) catch return false;
            remote_env_len += 1;
        }
        remote_env_items[remote_env_len] = if (settings.login_shell) "SKETERM_REMOTE_LOGIN=1" else "SKETERM_REMOTE_LOGIN=0";
        remote_env_len += 1;
    }
    conn.sendJson(.spawn, .{
        .name = name,
        .argv = spawn_argv,
        .env = remote_env_items[0..remote_env_len],
        .cwd = cwd,
        .rows = rows,
        .cols = cols,
        .term = settings.term_env,
        .color_term = settings.color_term_env,
        .login_shell = argv.len == 0 and host == null and settings.login_shell,
    }) catch return false;
    const f = conn.recvExpectFor(&.{.ok}, 30_000) catch {
        const why = conn.lastErr();
        if (std.mem.indexOf(u8, why, "already exists") != null) return .name_taken;
        if (why.len > 0) {
            _ = c.fprintf(platform.stderr(), "sketerm mux: spawn failed: %.*s\n", @as(c_int, @intCast(why.len)), why.ptr);
        } else {
            _ = c.fprintf(platform.stderr(), "sketerm mux: spawn failed\n");
        }
        return .failed;
    };
    f.deinit(allocator);
    return .ok;
}

const SpawnResult = enum { ok, name_taken, failed };

// ── in-terminal viewing ─────────────────────────────────────────

fn ttyOptions(lease: Lease) mux_tty.Options {
    return .{ .read_only = lease == .read_only, .control = lease == .control };
}

/// Show `name` in this terminal until detached or ended.
fn ttyAttach(allocator: std.mem.Allocator, host: ?[]const u8, name: []const u8, lease: Lease) mux_tty.Outcome {
    var conn = muxConnect(allocator, host) orelse return .failed;
    defer conn.deinit();
    return mux_tty.attach(allocator, &conn, name, ttyOptions(lease));
}

/// Per-process counter behind the `s<pid>-N` names, the same shape
/// the GUI mints for its sessions.
var tty_session_seq: u32 = 0;

/// Spawn a fresh durable session sized to this terminal and show it.
fn ttyNew(allocator: std.mem.Allocator, host: ?[]const u8) mux_tty.Outcome {
    var conn = connectForSpawn(allocator, host) orelse return .failed;
    defer conn.deinit();
    var ws: c.struct_winsize = undefined;
    var rows: u16 = 24;
    var cols: u16 = 80;
    if (c.ioctl(1, c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        rows = ws.ws_row;
        cols = ws.ws_col;
    }
    // A durable session outlives the process that named it, so a later
    // process reusing this pid can collide with `s<pid>-1`: walk the
    // counter past whatever exists instead of giving up.
    var name_buf: [32]u8 = undefined;
    var attempts: u8 = 0;
    while (attempts < 16) : (attempts += 1) {
        tty_session_seq += 1;
        const name = std.fmt.bufPrint(&name_buf, "s{d}-{d}", .{ c.getpid(), tty_session_seq }) catch return .failed;
        switch (spawnOn(allocator, &conn, host, name, null, rows, cols, &.{})) {
            .ok => return mux_tty.attach(allocator, &conn, name, ttyOptions(.default)),
            .name_taken => continue,
            .failed => return .failed,
        }
    }
    _ = c.fprintf(platform.stderr(), "sketerm mux: could not find a free session name\n");
    return .failed;
}

/// Attach just long enough to feed input — the daemon requires an
/// attached client for INPUT frames, and attach answers with a
/// snapshot we discard.
fn attachForIo(allocator: std.mem.Allocator, host: ?[]const u8, name: []const u8) ?struct { conn: mux_client.Conn, snap: mux_client.Conn.OwnedFrame } {
    var conn = muxConnect(allocator, host) orelse return null;
    // Read-only: a one-shot send/get-text must not take a session's
    // controller lease away from the viewer that holds it.
    conn.sendJson(.attach, .{ .name = name, .kind = "cli", .read_only = true }) catch {
        conn.deinit();
        return null;
    };
    const snap = conn.recvExpect(&.{.snapshot}) catch {
        _ = c.fprintf(
            platform.stderr(),
            "sketerm mux: no such session '%.*s'\n",
            @as(c_int, @intCast(name.len)),
            name.ptr,
        );
        conn.deinit();
        return null;
    };
    return .{ .conn = conn, .snap = snap };
}

fn muxSend(allocator: std.mem.Allocator, host: ?[]const u8, name: []const u8, rest: []const []const u8) u8 {
    var press_enter = false;
    var type_mode = false;
    var delay: u32 = 60;
    var jitter: u32 = 90;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--enter")) {
            press_enter = true;
        } else if (std.mem.eql(u8, a, "--type")) {
            type_mode = true;
        } else if (std.mem.eql(u8, a, "--delay") and i + 1 < rest.len) {
            i += 1;
            delay = std.fmt.parseInt(u32, rest[i], 10) catch 60;
        } else if (std.mem.eql(u8, a, "--jitter") and i + 1 < rest.len) {
            i += 1;
            jitter = std.fmt.parseInt(u32, rest[i], 10) catch 90;
        } else {
            parts.append(allocator, a) catch return 1;
        }
    }
    const joined = std.mem.join(allocator, " ", parts.items) catch return 1;
    defer allocator.free(joined);
    const text = if (press_enter)
        std.fmt.allocPrint(allocator, "{s}\r", .{joined}) catch return 1
    else
        joined;
    defer if (press_enter) allocator.free(text);

    var io = attachForIo(allocator, host, name) orelse return 1;
    defer io.conn.deinit();
    io.snap.deinit(allocator);

    if (!type_mode) {
        io.conn.sendFrame(.input, text) catch return 1;
        return finishSend(allocator, &io.conn);
    }
    const humantype = @import("../util/humantype.zig");
    var pacer = humantype.Pacer.init(delay, jitter, clockSeed());
    var chunks = humantype.Chunks{ .text = text };
    var first = true;
    while (chunks.next()) |chunk| {
        if (!first) msleep(pacer.delayMs(chunk));
        first = false;
        io.conn.sendFrame(.input, chunk) catch return 1;
    }
    return finishSend(allocator, &io.conn);
}

/// Detach + wait for the OK before closing. Frames are processed in
/// order, so the round-trip proves every input frame reached the PTY
/// — without it, closing right after the last write races the
/// daemon's poll loop (and loses outright against pre-fix daemons).
fn finishSend(allocator: std.mem.Allocator, conn: *mux_client.Conn) u8 {
    conn.sendJson(.detach, .{}) catch return 1;
    const f = conn.recvExpect(&.{.ok}) catch return 1;
    f.deinit(allocator);
    return 0;
}

fn muxGetText(allocator: std.mem.Allocator, host: ?[]const u8, name: []const u8, rest: []const []const u8) u8 {
    var want_scrollback = false;
    for (rest) |a| {
        if (std.mem.eql(u8, a, "--scrollback")) want_scrollback = true;
    }

    var io = attachForIo(allocator, host, name) orelse return 1;
    defer io.conn.deinit();
    defer io.snap.deinit(allocator);
    const Pool = @import("../grid/style_pool.zig").Pool;
    const snapshot = @import("../mux/snapshot.zig");
    const envelope = snapshot.peelEnvelope(io.snap.payload) catch return 1;
    var pool = Pool.init(allocator) catch return 1;
    defer pool.deinit();
    const screen = snapshot.restore(allocator, &pool, envelope.body) catch {
        _ = c.fprintf(platform.stderr(), "sketerm mux: bad snapshot\n");
        return 1;
    };
    defer screen.deinit();

    const text = (if (want_scrollback)
        screen.extractScrollback(allocator)
    else
        screen.extractScreen(allocator)) catch return 1;
    defer allocator.free(text);
    _ = c.fwrite(text.ptr, 1, text.len, platform.stdout());
    if (text.len == 0 or text[text.len - 1] != '\n') _ = c.fputc('\n', platform.stdout());
    return 0;
}

/// `sketerm mux [host] forward <local[:remote]>` — bind
/// 127.0.0.1:<local> here and tunnel every accepted connection to
/// 127.0.0.1:<remote> on the daemon's host over the mux connection
/// (so it rides SSH/UDP transports unchanged). Runs until killed.
fn muxForward(allocator: std.mem.Allocator, host: ?[]const u8, spec: []const u8) u8 {
    var local: u16 = 0;
    var remote: u16 = 0;
    if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
        local = std.fmt.parseInt(u16, spec[0..colon], 10) catch 0;
        remote = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch 0;
    } else {
        local = std.fmt.parseInt(u16, spec, 10) catch 0;
        remote = local;
    }
    if (local == 0 or remote == 0) {
        _ = c.fprintf(platform.stderr(), "sketerm mux forward: bad port spec '%.*s' (want <local[:remote]>)\n", @as(c_int, @intCast(spec.len)), spec.ptr);
        return 2;
    }

    var conn = muxConnect(allocator, host) orelse return 1;
    defer conn.deinit();

    const lfd = platform.socketCloexec(c.AF_INET, c.SOCK_STREAM, 0);
    if (lfd < 0) return 1;
    defer _ = c.close(lfd);
    channel_pump.configureFd(lfd) catch return 1;
    var one: c_int = 1;
    _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
    var sa = std.mem.zeroes(c.struct_sockaddr_in);
    sa.sin_family = c.AF_INET;
    sa.sin_port = std.mem.nativeToBig(u16, local);
    sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
    if (c.bind(lfd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(lfd, 16) != 0) {
        _ = c.fprintf(platform.stderr(), "sketerm mux forward: bind 127.0.0.1:%u failed (port in use?)\n", @as(c_uint, local));
        return 1;
    }
    _ = c.printf("forwarding 127.0.0.1:%u -> remote 127.0.0.1:%u (Ctrl+C stops)\n", @as(c_uint, local), @as(c_uint, remote));

    var forwarder = Forwarder.init(allocator, &conn, lfd, remote);
    defer forwarder.deinit();
    if (forwarder.run()) return 0;
    _ = c.fprintf(platform.stderr(), "sketerm mux forward: connection lost\n");
    return 1;
}

const MAX_FORWARDS = 64;
const MAX_FORWARD_OUT: usize = 1 << 20;

const Forwarder = struct {
    allocator: std.mem.Allocator,
    conn: *mux_client.Conn,
    listen_fd: c_int,
    remote_port: u16,
    cancel_fd: c_int = -1,
    locals: [MAX_FORWARDS]channel_pump.Local = @splat(.{}),
    /// Slot indexes awaiting ordered `chan_open` replies.
    pending: [MAX_FORWARDS]u8 = @splat(0),
    pending_n: usize = 0,

    fn init(allocator: std.mem.Allocator, conn: *mux_client.Conn, listen_fd: c_int, remote_port: u16) Forwarder {
        return .{ .allocator = allocator, .conn = conn, .listen_fd = listen_fd, .remote_port = remote_port };
    }

    fn newPump(self: *Forwarder) channel_pump.Pump {
        return channel_pump.Pump.init(self.allocator, self.conn);
    }

    fn deinit(self: *Forwarder) void {
        var pump = self.newPump();
        for (&self.locals) |*local| pump.closeLocal(local, false);
    }

    fn freeSlot(self: *Forwarder) ?usize {
        for (&self.locals, 0..) |*local, index| {
            if (!local.active()) return index;
        }
        return null;
    }

    fn byChan(self: *Forwarder, chan: u32) ?*channel_pump.Local {
        for (&self.locals) |*local| {
            if (local.active() and local.chan == chan) return local;
        }
        return null;
    }

    fn popPending(self: *Forwarder) ?usize {
        if (self.pending_n == 0) return null;
        const index = self.pending[0];
        std.mem.copyForwards(u8, self.pending[0 .. self.pending_n - 1], self.pending[1..self.pending_n]);
        self.pending_n -= 1;
        return index;
    }

    fn acceptOne(self: *Forwarder) bool {
        const fd = (channel_pump.accept(self.listen_fd) catch return false) orelse return true;
        const index = self.freeSlot() orelse {
            _ = c.close(fd);
            return true;
        };
        self.locals[index].open(fd, MAX_FORWARD_OUT) catch {
            _ = c.close(fd);
            return true;
        };
        self.conn.queueJson(.forward_open, .{ .port = self.remote_port }) catch {
            var pump = self.newPump();
            pump.closeLocal(&self.locals[index], false);
            return false;
        };
        self.pending[self.pending_n] = @intCast(index);
        self.pending_n += 1;
        return true;
    }

    fn handleFrame(self: *Forwarder, ftype: mux_wire.FrameType, payload: []const u8) bool {
        var pump = self.newPump();
        switch (ftype) {
            .chan_open => {
                const opened = mux_wire.decodeChanOpen(payload) orelse return true;
                if (opened.kind != .tcp_forward) return true;
                const index = self.popPending() orelse {
                    pump.queueClose(opened.id) catch {};
                    return true;
                };
                if (!self.locals[index].active()) {
                    pump.queueClose(opened.id) catch {};
                    return true;
                }
                self.locals[index].chan = opened.id;
            },
            .chan_data => {
                const id = mux_wire.decodeChanId(payload) orelse return true;
                const local = self.byChan(id) orelse return true;
                _ = pump.queueLocal(local, payload[4..], false, false) catch {
                    pump.closeLocal(local, true);
                    return true;
                };
            },
            .chan_close => {
                const id = mux_wire.decodeChanId(payload) orelse return true;
                if (self.byChan(id)) |local| _ = pump.remoteClose(local);
            },
            // A refused forward_open has no request id; replies are ordered.
            .err => if (self.popPending()) |index| pump.closeLocal(&self.locals[index], false),
            else => {},
        }
        return true;
    }

    fn drainBuffered(self: *Forwarder) bool {
        var pump = self.newPump();
        if (pump.drainBuffered(self, Forwarder.handleFrame) == .open) return true;
        self.finishMuxClose();
        return false;
    }

    fn receive(self: *Forwarder) bool {
        var pump = self.newPump();
        if (pump.receive(self, Forwarder.handleFrame) == .open) return true;
        self.finishMuxClose();
        return false;
    }

    fn finishMuxClose(self: *Forwarder) void {
        var refs: [MAX_FORWARDS]*channel_pump.Local = undefined;
        for (&self.locals, 0..) |*local, index| refs[index] = local;
        var pump = self.newPump();
        pump.finishAfterMuxClose(&refs, self.cancel_fd, clock.nowMs() + 5000);
    }

    fn pumpLocal(self: *Forwarder, local: *channel_pump.Local) void {
        var pump = self.newPump();
        var buf: [channel_pump.DATA_CHUNK]u8 = undefined;
        switch (channel_pump.readLocal(local.fd, &buf)) {
            .data => |data| pump.queueData(local.chan, data) catch pump.closeLocal(local, true),
            .would_block => {},
            .eof, .failed => pump.closeLocal(local, true),
        }
    }

    fn run(self: *Forwarder) bool {
        var pump = self.newPump();
        pump.prepare() catch return false;
        while (true) {
            if (!self.drainBuffered()) return false;
            const mux_blocked = self.conn.wbuf.items.len != 0;
            const cancel_index = 2 + MAX_FORWARDS;
            var fds: [3 + MAX_FORWARDS]c.struct_pollfd = undefined;
            fds[0] = .{ .fd = self.conn.fd, .events = pump.muxEvents(true), .revents = 0 };
            fds[1] = .{
                .fd = self.listen_fd,
                .events = if (!mux_blocked and self.pending_n < MAX_FORWARDS and self.freeSlot() != null) c.POLLIN else 0,
                .revents = 0,
            };
            for (&self.locals, 0..) |*local, index| {
                fds[2 + index] = .{
                    .fd = if (local.active()) local.fd else -1,
                    .events = if (local.active() and local.chan != 0) local.events(!mux_blocked) else 0,
                    .revents = 0,
                };
            }
            fds[cancel_index] = .{ .fd = self.cancel_fd, .events = c.POLLIN, .revents = 0 };
            switch (channel_pump.wait(&fds, if (self.cancel_fd >= 0) cancel_index else null, null)) {
                .ready => {},
                .cancelled => return true,
                // No deadline is passed, so poll(-1) cannot report one today.
                // Re-polling is the correct handling if a deadline is ever
                // added here; `unreachable` would be UB in ReleaseFast.
                .timeout => continue,
                .failed => return false,
            }

            if (fds[0].revents & c.POLLOUT != 0 and !pump.flushMux()) return false;
            if (fds[1].revents & c.POLLIN != 0 and self.conn.wbuf.items.len == 0)
                if (!self.acceptOne()) return false;
            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0)
                if (!self.receive()) return false;
            if (channel_pump.badPoll(fds[0].revents) or channel_pump.badPoll(fds[1].revents)) return false;

            for (&self.locals, 0..) |*local, index| {
                if (!local.active()) continue;
                const revents = fds[2 + index].revents;
                if (revents & c.POLLOUT != 0) _ = pump.flushLocal(local);
                if (!local.active()) continue;
                if (revents & (c.POLLIN | c.POLLHUP) != 0 and self.conn.wbuf.items.len == 0) {
                    self.pumpLocal(local);
                }
                if (local.active() and channel_pump.badPoll(revents)) pump.closeLocal(local, true);
            }
        }
    }
};

test "forward pump drains buffered open-data-close frames in order" {
    const t = std.testing;
    var mux_pair: [2]c_int = undefined;
    var local_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&mux_pair));
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&local_pair));
    defer _ = c.close(mux_pair[1]);
    defer _ = c.close(local_pair[1]);
    var conn = mux_client.Conn{ .allocator = t.allocator, .fd = mux_pair[0], .proto = mux_wire.PROTO_VERSION };
    defer conn.deinit();
    var forwarder = Forwarder.init(t.allocator, &conn, -1, 80);
    defer forwarder.deinit();
    try forwarder.locals[0].open(local_pair[0], MAX_FORWARD_OUT);
    forwarder.pending[0] = 0;
    forwarder.pending_n = 1;

    var open_buf: [5]u8 = undefined;
    try mux_wire.appendFrame(&conn.rbuf, t.allocator, .chan_open, mux_wire.encodeChanOpen(&open_buf, 7, .tcp_forward));
    var data: [4 + 9]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 7, .little);
    @memcpy(data[4..], "alphabeta");
    try mux_wire.appendFrame(&conn.rbuf, t.allocator, .chan_data, &data);
    var close_header: [4]u8 = undefined;
    try mux_wire.appendFrame(&conn.rbuf, t.allocator, .chan_close, mux_wire.putChanHeader(&close_header, 7));

    try t.expect(forwarder.drainBuffered());
    try t.expect(!forwarder.locals[0].active());
    var got: [9]u8 = undefined;
    try t.expectEqual(@as(isize, got.len), c.read(local_pair[1], &got, got.len));
    try t.expectEqualStrings("alphabeta", &got);
    var eof: [1]u8 = undefined;
    try t.expectEqual(@as(isize, 0), c.read(local_pair[1], &eof, eof.len));
}

test "forward pump turns local EOF into chan_close" {
    const t = std.testing;
    var mux_pair: [2]c_int = undefined;
    var local_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&mux_pair));
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&local_pair));
    var conn = mux_client.Conn{ .allocator = t.allocator, .fd = mux_pair[0], .proto = mux_wire.PROTO_VERSION };
    defer conn.deinit();
    var peer = mux_client.Conn{ .allocator = t.allocator, .fd = mux_pair[1], .proto = mux_wire.PROTO_VERSION };
    defer peer.deinit();
    var forwarder = Forwarder.init(t.allocator, &conn, -1, 80);
    defer forwarder.deinit();
    try forwarder.locals[0].open(local_pair[0], MAX_FORWARD_OUT);
    forwarder.locals[0].chan = 23;
    _ = c.close(local_pair[1]);

    forwarder.pumpLocal(&forwarder.locals[0]);
    try t.expect(!forwarder.locals[0].active());
    const frame = try peer.recvExpectFor(&.{.chan_close}, 1000);
    defer frame.deinit(t.allocator);
    try t.expectEqual(@as(?u32, 23), mux_wire.decodeChanId(frame.payload));
}

test "forward pump handles refusal, gone, mux EOF, and cancellation" {
    const t = std.testing;
    var mux_pair: [2]c_int = undefined;
    var local_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&mux_pair));
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&local_pair));
    var conn = mux_client.Conn{ .allocator = t.allocator, .fd = mux_pair[0], .proto = mux_wire.PROTO_VERSION };
    defer conn.deinit();
    var forwarder = Forwarder.init(t.allocator, &conn, -1, 80);
    defer forwarder.deinit();
    try forwarder.locals[0].open(local_pair[0], MAX_FORWARD_OUT);
    forwarder.pending[0] = 0;
    forwarder.pending_n = 1;
    try t.expect(forwarder.handleFrame(.err, "refused"));
    try t.expect(!forwarder.locals[0].active());
    try t.expectEqual(@as(usize, 0), forwarder.pending_n);
    _ = c.close(local_pair[1]);

    try mux_wire.appendFrame(&conn.rbuf, t.allocator, .gone, "");
    try t.expect(!forwarder.drainBuffered());

    const wake = try platform.Wakeup.init();
    defer wake.close();
    forwarder.cancel_fd = wake.read_fd;
    wake.signal();
    try t.expect(forwarder.run());

    _ = c.shutdown(mux_pair[1], c.SHUT_RDWR);
    _ = c.close(mux_pair[1]);
    mux_pair[1] = -1;
    forwarder.cancel_fd = -1;
    try t.expect(!forwarder.receive());
}

/// One search hit as the daemon reports it.
pub const SearchHit = struct { back: u32 = 0, text: []const u8 = "" };
pub const SearchReply = struct { hits: []const SearchHit = &.{}, total: u32 = 0 };

/// Search ONE attached session server-side. Returns the parsed reply
/// (caller deinits) or null on transport/attach failure.
pub fn searchSession(
    allocator: std.mem.Allocator,
    host: ?[]const u8,
    name: []const u8,
    pattern: []const u8,
    max: u32,
) ?std.json.Parsed(SearchReply) {
    var io = attachForIo(allocator, host, name) orelse return null;
    defer io.conn.deinit();
    io.snap.deinit(allocator);
    io.conn.sendJson(.search, .{ .pattern = pattern, .max = max }) catch return null;
    const f = io.conn.recvExpect(&.{.search_hits}) catch return null;
    defer f.deinit(allocator);
    // alloc_always: hit texts must not alias the frame payload freed
    // by the deinit above.
    return std.json.parseFromSlice(SearchReply, allocator, f.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// `sketerm mux [host] search <pattern>` — case-insensitive substring
/// search across every session on the daemon (scrollback + screen).
fn muxSearch(allocator: std.mem.Allocator, host: ?[]const u8, pattern: []const u8) u8 {
    var sessions = fetchSessions(allocator, host) orelse return 1;
    defer sessions.deinit();
    var total_hits: u32 = 0;
    for (sessions.value.sessions) |s| {
        if (s.exited) continue;
        const reply = searchSession(allocator, host, s.name, pattern, 50) orelse continue;
        defer reply.deinit();
        for (reply.value.hits) |h| {
            _ = c.printf(
                "%.*s:-%u: %.*s\n",
                @as(c_int, @intCast(s.name.len)),
                s.name.ptr,
                @as(c_uint, h.back),
                @as(c_int, @intCast(h.text.len)),
                h.text.ptr,
            );
        }
        if (reply.value.total > reply.value.hits.len) {
            _ = c.printf(
                "%.*s: (+%u more)\n",
                @as(c_int, @intCast(s.name.len)),
                s.name.ptr,
                @as(c_uint, reply.value.total - @as(u32, @intCast(reply.value.hits.len))),
            );
        }
        total_hits += reply.value.total;
    }
    return if (total_hits > 0) 0 else 1;
}

fn renameSession(allocator: std.mem.Allocator, host: ?[]const u8, old: []const u8, new: []const u8) bool {
    var conn = muxConnect(allocator, host) orelse return false;
    defer conn.deinit();
    conn.sendJson(.rename, .{ .name = old, .new_name = new }) catch return false;
    const f = conn.recvExpect(&.{.ok}) catch {
        _ = c.fprintf(platform.stderr(), "sketerm mux: rename failed\n");
        return false;
    };
    f.deinit(allocator);
    return true;
}

pub fn muxConnect(allocator: std.mem.Allocator, host: ?[]const u8) ?mux_client.Conn {
    if (host) |h| {
        // "sock:/path" = a specific daemon instance's unix socket (an
        // MCP private daemon). Connect only — never autostart one.
        if (std.mem.startsWith(u8, h, "sock:")) {
            return mux_client.Conn.connectProbed(allocator, h[5..]) catch {
                _ = c.fprintf(platform.stderr(), "sketerm mux: no daemon at that socket\n");
                return null;
            };
        }
        var cfg = @import("../config.zig").Config.load(allocator);
        defer cfg.deinit();
        const remote = mux_client.RemoteSpec.parse(h);
        const conn = mux_client.Conn.connectRemote(allocator, h, cfg.muxConnectOptions()) catch |err| {
            const mode_name = @tagName(remote.mode);
            const err_name = @errorName(err);
            // No portable artifact = this install cannot deploy the daemon
            // for the user (a Linux architecture the packaging has no musl
            // target for), so "not installed there" is the whole story.
            const deploy_note: [*:0]const u8 = if (deploy.portableAvailable())
                ""
            else
                "  this build ships no sketerm-mux-portable, so it cannot\n" ++
                    "  deploy the daemon itself: install sketerm-mux there\n";
            _ = c.fprintf(
                platform.stderr(),
                "sketerm mux: cannot reach %.*s using %.*s transport policy\n" ++
                    "  connection error: %.*s\n",
                @as(c_int, @intCast(remote.host.len)),
                remote.host.ptr,
                @as(c_int, @intCast(mode_name.len)),
                mode_name.ptr,
                @as(c_int, @intCast(err_name.len)),
                err_name.ptr,
            );
            if (remote.mode == .tor) {
                _ = c.fprintf(
                    platform.stderr(),
                    "  Tor policy was preserved; no direct SSH probe or fallback was attempted\n" ++
                        "  retry for the full transport error: sketerm mux tor:%.*s list\n",
                    @as(c_int, @intCast(remote.host.len)),
                    remote.host.ptr,
                );
            } else {
                _ = c.fprintf(
                    platform.stderr(),
                    "  safe SSH probe: ssh -T -x -o BatchMode=yes -o ControlMaster=no\n" ++
                        "                  -o ClearAllForwardings=yes %.*s sketerm-mux --help\n" ++
                        "  this checks host/auth/binary reachability without touching sessions\n",
                    @as(c_int, @intCast(remote.host.len)),
                    remote.host.ptr,
                );
            }
            _ = c.fputs(deploy_note, platform.stderr());
            return null;
        };
        if (remote.mode == .auto and conn.transport == .ssh) {
            const why = if (conn.udp_error) |e| mux_client.Conn.udpErrorText(e) else "reason unrecorded";
            _ = c.fprintf(
                platform.stderr(),
                "sketerm mux: UDP unavailable for %.*s; connected over SSH\n" ++
                    "  reason: %.*s\n" ++
                    "  force it to see the full error:  sketerm mux udp:%.*s\n",
                @as(c_int, @intCast(remote.host.len)),
                remote.host.ptr,
                @as(c_int, @intCast(why.len)),
                why.ptr,
                @as(c_int, @intCast(remote.host.len)),
                remote.host.ptr,
            );
        }
        return conn;
    }
    const path = mux_daemon.defaultSocketPath(allocator) catch return null;
    defer allocator.free(path);
    return mux_client.Conn.connectProbed(allocator, path) catch {
        _ = c.fprintf(platform.stderr(), "sketerm mux: daemon not running (no durable sessions yet)\n");
        return null;
    };
}

/// Kill one session on `host`'s daemon (muxConnect host semantics).
/// Shared by the CLI, the TUI picker and the GUI session overview.
pub fn killSession(allocator: std.mem.Allocator, host: ?[]const u8, name: []const u8) bool {
    var conn = muxConnect(allocator, host) orelse return false;
    defer conn.deinit();
    conn.sendJson(.kill, .{ .name = name }) catch return false;
    const f = conn.recvExpectFor(&.{.ok}, 10_000) catch return false;
    f.deinit(allocator);
    return true;
}

pub fn fetchSessions(allocator: std.mem.Allocator, host: ?[]const u8) ?std.json.Parsed(Welcome) {
    var conn = muxConnect(allocator, host) orelse return null;
    defer conn.deinit();
    conn.sendFrame(.list, "") catch return null;
    const f = conn.recvExpectFor(&.{.welcome}, 10_000) catch return null;
    defer f.deinit(allocator);
    return std.json.parseFromSlice(Welcome, allocator, f.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// Send one command to the running GUI over its IPC socket
/// ($SKETERM_SOCKET inside a pane, auto-discovery otherwise).
/// Controller-lease intent for an attach that goes through the GUI.
pub const Lease = enum { default, read_only, control };

/// `sketerm mux attach` arguments. The session name is the first
/// NON-flag argument, so `attach --read-only foo` and `attach foo
/// --control` both work.
///
/// Run from inside a pane, attach TAKES OVER that pane (the tmux
/// shape). That is right for a person typing it and wrong for a
/// command a tool ran in someone's shell — which is how a documented
/// attach consumed the user's own pane mid-session. `--new-tab` opts
/// out; the help says so, and so does the warning printed when a pane
/// is about to be taken over.
pub const AttachArgs = struct {
    lease: Lease = .default,
    target: ?[]const u8 = null,
    new_tab: bool = false,

    pub fn parse(args: []const []const u8) AttachArgs {
        var out: AttachArgs = .{};
        for (args) |a| {
            if (std.mem.eql(u8, a, "--read-only")) {
                out.lease = .read_only;
            } else if (std.mem.eql(u8, a, "--control")) {
                out.lease = .control;
            } else if (std.mem.eql(u8, a, "--new-tab")) {
                out.new_tab = true;
            } else if (out.target == null) {
                out.target = a;
            }
        }
        return out;
    }

    /// Whether this attach replaces the shell of the pane it runs in.
    pub fn takesOverPane(self: AttachArgs, inside_pane: bool) bool {
        return inside_pane and !self.new_tab;
    }
};

test "AttachArgs: flags in any order, --new-tab opts out of the takeover" {
    const t = std.testing;
    const a = AttachArgs.parse(&.{ "--read-only", "work" });
    try t.expectEqualStrings("work", a.target.?);
    try t.expectEqual(Lease.read_only, a.lease);
    try t.expect(a.takesOverPane(true));
    try t.expect(!a.takesOverPane(false));

    const b = AttachArgs.parse(&.{ "work", "--control", "--new-tab" });
    try t.expectEqualStrings("work", b.target.?);
    try t.expectEqual(Lease.control, b.lease);
    try t.expect(b.new_tab);
    try t.expect(!b.takesOverPane(true));

    // The first non-flag wins; a later one is not a second target.
    const c2 = AttachArgs.parse(&.{ "one", "two" });
    try t.expectEqualStrings("one", c2.target.?);
    try t.expect(AttachArgs.parse(&.{"--new-tab"}).target == null);
}

pub fn guiCommand(allocator: std.mem.Allocator, cmd: []const u8, data: ?[]const u8, host: ?[]const u8, use_pane: bool) bool {
    return guiCommandLease(allocator, cmd, data, host, use_pane, .default);
}

pub fn guiCommandLease(allocator: std.mem.Allocator, cmd: []const u8, data: ?[]const u8, host: ?[]const u8, use_pane: bool, lease: Lease) bool {
    return guiCommandLeaseMode(allocator, cmd, data, host, use_pane, lease, false);
}

fn guiCommandBackground(allocator: std.mem.Allocator, cmd: []const u8, data: ?[]const u8, host: ?[]const u8, use_pane: bool) bool {
    return guiCommandLeaseMode(allocator, cmd, data, host, use_pane, .default, true);
}

fn guiCommandLeaseMode(allocator: std.mem.Allocator, cmd: []const u8, data: ?[]const u8, host: ?[]const u8, use_pane: bool, lease: Lease, background: bool) bool {
    const sock = ipc_client.resolveSocket(allocator, null) orelse {
        _ = c.fprintf(platform.stderr(), "sketerm mux: no running sketerm window found\n");
        return false;
    };
    defer allocator.free(sock);

    // Inside a sketerm pane (SKETERM_PANE_ID in the env), attach/new
    // take over THIS pane instead of opening a tab — running
    // `sketerm mux` in a pane and picking a session should behave
    // like `tmux attach`, not spawn windows elsewhere.
    const self_pane: ?u32 = blk: {
        if (!use_pane) break :blk null;
        const env = c.getenv("SKETERM_PANE_ID") orelse break :blk null;
        break :blk std.fmt.parseInt(u32, std.mem.span(@as([*:0]const u8, @ptrCast(env))), 10) catch null;
    };
    // The stable identity: the daemon-owned session name, which the GUI
    // prefers over the pane id (the latter goes stale across a restart).
    const self_session: ?[]const u8 = blk: {
        if (!use_pane) break :blk null;
        const env = c.getenv("SKETERM_SESSION") orelse break :blk null;
        break :blk std.mem.span(@as([*:0]const u8, @ptrCast(env)));
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    std.json.Stringify.value(.{
        .cmd = cmd,
        .data = data,
        .host = host,
        .pane = self_pane,
        .session = self_session,
        .read_only = lease == .read_only,
        .control = lease == .control,
        .background = background,
    }, .{}, &aw.writer) catch return false;
    aw.writer.writeAll("\n") catch return false;

    const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    mux_daemon.fillSockaddrUn(&addr, sock) catch return false;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
        _ = c.fprintf(platform.stderr(), "sketerm mux: cannot reach the sketerm window\n");
        return false;
    }
    const line = aw.written();
    var off: usize = 0;
    while (off < line.len) {
        const n = c.write(fd, line.ptr + off, line.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    var resp: [4096]u8 = undefined;
    const rn = c.read(fd, &resp, resp.len);
    if (rn <= 0) return false;
    const ok = std.mem.indexOf(u8, resp[0..@intCast(rn)], "\"ok\":true") != null;
    if (!ok) _ = c.fprintf(platform.stderr(), "sketerm mux: %.*s", @as(c_int, @intCast(rn)), &resp);
    return ok;
}

// ── TUI ─────────────────────────────────────────────────────────

const RawMode = struct {
    orig: c.struct_termios,

    fn enter() ?RawMode {
        if (c.isatty(0) == 0) {
            _ = c.fprintf(platform.stderr(), "sketerm mux: stdin is not a terminal (use `sketerm mux list`)\n");
            return null;
        }
        var orig: c.struct_termios = undefined;
        if (c.tcgetattr(0, &orig) != 0) return null;
        var raw = orig;
        raw.c_lflag &= ~@as(@TypeOf(raw.c_lflag), c.ICANON | c.ECHO);
        raw.c_cc[c.VMIN] = 1;
        raw.c_cc[c.VTIME] = 0;
        _ = c.tcsetattr(0, c.TCSANOW, &raw);
        _ = c.printf("\x1b[?25l"); // hide cursor
        return .{ .orig = orig };
    }

    fn leave(self: *const RawMode) void {
        _ = c.printf("\x1b[?25h");
        _ = c.fflush(platform.stdout());
        _ = c.tcsetattr(0, c.TCSANOW, &self.orig);
    }
};

fn tui(allocator: std.mem.Allocator, host: ?[]const u8, placement: Placement) u8 {
    var parsed = fetchSessions(allocator, host) orelse return 1;
    defer parsed.deinit();

    var raw = RawMode.enter() orelse return 1;
    defer raw.leave();
    // Outside a sketerm pane, Enter/n show the session in THIS terminal
    // and the picker comes back afterwards (detach or exit), so one
    // `sketerm mux` is a whole session-hopping loop.
    const here = placement.inTerminalHere(false);

    var selected: usize = 0;
    var drawn_lines: usize = 0;
    while (true) {
        const sessions = parsed.value.sessions;
        // The list has one virtual trailing row: "create new session".
        const n_rows = sessions.len + 1;
        drawTui(sessions, selected, &drawn_lines, here);

        var buf: [8]u8 = undefined;
        const n = c.read(0, &buf, buf.len);
        if (n <= 0) return 1;
        const key = buf[0..@intCast(n)];

        if (key.len == 1 and (key[0] == 'q' or key[0] == 0x1b and n == 1)) {
            eraseTui(&drawn_lines);
            return 0;
        }
        const is_up = (key.len == 1 and key[0] == 'k') or std.mem.eql(u8, key, "\x1b[A");
        const is_down = (key.len == 1 and key[0] == 'j') or std.mem.eql(u8, key, "\x1b[B");
        if (is_up and selected > 0) selected -= 1;
        if (is_down and selected < n_rows - 1) selected += 1;

        const is_enter = key.len == 1 and (key[0] == '\r' or key[0] == '\n');
        const is_new = key.len == 1 and key[0] == 'n';
        if (here and (is_enter or is_new)) {
            eraseTui(&drawn_lines);
            raw.leave();
            const outcome = if (is_new or selected >= sessions.len)
                ttyNew(allocator, host)
            else
                ttyAttach(allocator, host, sessions[selected].name, .default);
            if (outcome == .failed or outcome == .lost) {
                // The reason is already on stderr; a blocked picker would
                // hide it behind the next redraw.
                msleep(800);
            }
            parsed.deinit();
            parsed = fetchSessions(allocator, host) orelse return 1;
            raw = RawMode.enter() orelse return 1;
            if (selected >= parsed.value.sessions.len + 1) selected = parsed.value.sessions.len;
            continue;
        }
        if (is_enter) {
            eraseTui(&drawn_lines);
            raw.leave();
            if (selected >= sessions.len) {
                // The "create new" row.
                return if (guiCommand(allocator, "new-durable-tab", null, host, true)) 0 else 1;
            }
            const name = sessions[selected].name;
            if (guiCommandBackground(allocator, "attach-session", name, host, true)) {
                const verb = if (host) |h| (if (std.mem.startsWith(u8, h, "sock:")) "attached" else "connecting to") else "attached";
                _ = c.printf("%.*s '%.*s'\n", @as(c_int, @intCast(verb.len)), verb.ptr, @as(c_int, @intCast(name.len)), name.ptr);
                return 0;
            }
            return 1;
        }
        if (is_new) {
            eraseTui(&drawn_lines);
            raw.leave();
            return if (guiCommand(allocator, "new-durable-tab", null, host, true)) 0 else 1;
        }
        if (key.len == 1 and key[0] == 'r' and selected < sessions.len) {
            const name = sessions[selected].name;
            // Inline cooked-mode prompt: drop raw, read one echoed
            // line, then restore raw and erase the prompt line.
            eraseTui(&drawn_lines);
            raw.leave();
            _ = c.printf("rename '%.*s' to: ", @as(c_int, @intCast(name.len)), name.ptr);
            _ = c.fflush(platform.stdout());
            var line_buf: [128]u8 = undefined;
            const rn = c.read(0, &line_buf, line_buf.len);
            raw = RawMode.enter() orelse return 1;
            _ = c.printf("\x1b[A\x1b[2K");
            if (rn > 0) {
                const new_name = std.mem.trim(u8, line_buf[0..@intCast(rn)], " \r\n");
                if (new_name.len > 0 and !std.mem.eql(u8, new_name, name)) {
                    _ = renameSession(allocator, host, name, new_name);
                }
            }
            parsed.deinit();
            parsed = fetchSessions(allocator, host) orelse {
                eraseTui(&drawn_lines);
                return 1;
            };
            if (selected >= parsed.value.sessions.len + 1) selected = parsed.value.sessions.len;
            continue;
        }
        if (key.len == 1 and key[0] == 'x' and selected < sessions.len) {
            const selected_session = sessions[selected];
            const name = selected_session.name;
            if (muxConnect(allocator, host)) |conn_v| {
                var conn = conn_v;
                defer conn.deinit();
                conn.sendKill(.{
                    .name = name,
                    .origin_id = selected_session.origin_id,
                }) catch {};
                if (conn.recvExpect(&.{.ok})) |f| f.deinit(allocator) else |_| {}
            }
            // Refresh the list.
            parsed.deinit();
            parsed = fetchSessions(allocator, host) orelse {
                eraseTui(&drawn_lines);
                return 1;
            };
            if (selected >= parsed.value.sessions.len and selected > 0) selected -= 1;
        }
    }
}

fn drawTui(sessions: []const SessionInfo, selected: usize, drawn_lines: *usize, here: bool) void {
    eraseTui(drawn_lines);
    _ = c.printf("\x1b[1msketerm sessions\x1b[0m  (Enter attach · n new · r rename · x kill · q quit)\r\n");
    var lines: usize = 1;
    if (here) {
        _ = c.printf("\x1b[2mshown in this terminal; Ctrl-\\ Ctrl-\\ detaches and returns here\x1b[0m\r\n");
        lines += 1;
    }
    for (sessions, 0..) |s, i| {
        const marker: [*:0]const u8 = if (i == selected) "\x1b[7m \xe2\x96\xb8 " else "   ";
        var idle_buf: [32]u8 = undefined;
        const active = s.idle_ms < 2000;
        _ = c.printf(
            "%s%-24.*s %s%3ux%-3u %u client(s)  %s%-11s\x1b[22;39m%s  \x1b[2m%.*s\x1b[0m\x1b[27m\r\n",
            marker,
            @as(c_int, @intCast(s.name.len)),
            s.name.ptr,
            @as([*:0]const u8, if (s.app) "\x1b[35m[gui app]\x1b[39m " else ""),
            @as(c_uint, s.cols),
            @as(c_uint, s.rows),
            @as(c_uint, s.viewerCount()),
            @as([*:0]const u8, if (active) "\x1b[32m" else "\x1b[2m"),
            fmtIdle(&idle_buf, s.idle_ms).ptr,
            @as([*:0]const u8, if (s.exited) " [exited]" else if (s.audio) " \x1b[33m[audio]\x1b[39m" else ""),
            @as(c_int, @intCast(@min(s.title.len, 30))),
            s.title.ptr,
        );
        lines += 1;
    }
    // Virtual trailing row: create a new session (same as `n`).
    const new_marker: [*:0]const u8 = if (selected >= sessions.len) "\x1b[7m \xe2\x96\xb8 " else "   ";
    _ = c.printf("%s\x1b[32m+ create new session\x1b[39m\x1b[27m\r\n", new_marker);
    lines += 1;
    _ = c.fflush(platform.stdout());
    drawn_lines.* = lines;
}

fn eraseTui(drawn_lines: *usize) void {
    if (drawn_lines.* == 0) return;
    var i: usize = 0;
    while (i < drawn_lines.*) : (i += 1) _ = c.printf("\x1b[A\x1b[2K");
    _ = c.fflush(platform.stdout());
    drawn_lines.* = 0;
}
