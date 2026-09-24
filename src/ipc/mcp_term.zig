//! MCP headless-terminal tools (term_*), file transfers and port
//! forwards — split out of mcp.zig. Shared server state stays in
//! mcp.zig and is referenced through it.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const termdrive = @import("termdrive.zig");
const mcp = @import("mcp.zig");
const mcp_panes = @import("mcp_panes.zig");
const mcp_tools = @import("mcp_tools.zig");
const eql = std.mem.eql;
const McpLog = mcp.McpLog;
const Res = mcp.Res;
const expectToolResultShape = mcp.expectToolResultShape;
const run = mcp.run;
const argBool = mcp.argBool;
const argInt = mcp.argInt;
const argStr = mcp.argStr;
const appErr = mcp.appErr;
const tailLines = mcp.tailLines;
const nowMs = @import("../util/clock.zig").nowMs;
const shellquote = mcp.shellquote;
const sshroute = @import("../mux/sshroute.zig");
const Config = @import("../config.zig").Config;

// ── headless terminal tools (shell sessions on the private daemon) ─

/// Spawn + register a terminal on a REMOTE host's own sketerm-mux
/// daemon. No local asciicast: rec_start writes on the daemon's host,
/// which would litter the remote box.
pub fn spawnRegisteredRemoteTerm(host: []const u8, argv: []const []const u8, cols: u16, rows: u16) !u32 {
    const t = termdrive.Term.spawnRemoteMux(term_state.allocator, host, argv, cols, rows) catch
        return error.SpawnFailed;
    const id = term_state.next_id;
    term_state.next_id += 1;
    term_state.terms.put(term_state.allocator, id, t) catch {
        t.deinit();
        return error.OutOfMemory;
    };
    return id;
}

/// Spawn + register a headless terminal; returns its id.
pub fn spawnRegisteredTerm(argv: ?[]const []const u8, cols: u16, rows: u16) !u32 {
    const t = termdrive.Term.spawn(term_state.allocator, argv, cols, rows, term_state.mux_sock) catch
        return error.SpawnFailed;
    const id = term_state.next_id;
    term_state.next_id += 1;
    term_state.terms.put(term_state.allocator, id, t) catch {
        t.deinit();
        return error.OutOfMemory;
    };
    _ = recordRegisteredTerm(t, id);
    return id;
}

/// Last non-empty rendered line of a term's screen (for term_list), or
/// "". Arena-owned.
pub fn termLastLine(arena: std.mem.Allocator, t: *termdrive.Term) []const u8 {
    const text = t.readScreen(false) catch return "";
    defer term_state.allocator.free(text);
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const cap = @min(trimmed.len, 160);
        return arena.dupe(u8, trimmed[0..cap]) catch "";
    }
    return "";
}

/// Serialize a termdrive exec outcome as the term_exec reply. On a
/// pending outcome the reply carries everything needed to understand a
/// blocked command WITHOUT further calls: the live screen tail, the
/// alt-screen flag, output idleness, an interactive-prompt hint and
/// the tracker id. `output_file` (optional, absolute, local) receives
/// the FULL untruncated output; the inline payload then keeps a tail.
pub fn execResultJson(arena: std.mem.Allocator, r: termdrive.ExecOutcome, t: *termdrive.Term, output_file: ?[]const u8) ![]const u8 {
    // The live rendered screen: an interactive dialog (apt's
    // needrestart, a password ask) must be VISIBLE in the reply, never
    // hidden behind a bare timeout.
    var screen_tail: ?[]const u8 = null;
    if (r.pending) {
        if (t.readScreen(false)) |screen_text| {
            defer term_state.allocator.free(screen_text);
            screen_tail = try arena.dupe(u8, tailLines(screen_text, 20));
        } else |_| {}
    }
    return execResult(arena, r, screen_tail, output_file);
}

/// The terminal-free half of execResultJson: everything the reply says
/// about an outcome, given the screen tail already read.
pub fn execResult(arena: std.mem.Allocator, r: termdrive.ExecOutcome, screen_tail: ?[]const u8, output_file: ?[]const u8) ![]const u8 {
    var res = mcp.Res.init(arena);
    try res.fact("completed", r.completed);
    try res.fact("exit_status", r.exit_status);
    try res.fact("timed_out", r.timed_out);
    try res.fact("truncated", r.truncated);
    try res.fact("shell_died", r.shell_died);
    try res.fact("pending", r.pending);
    if (r.completed) {
        if (r.exit_status) |st|
            try res.textf("exit {d}", .{st})
        else
            try res.text("completed, exit status unknown");
    } else if (r.pending) {
        try res.text(if (r.interactive_hint)
            "still running and apparently WAITING FOR INPUT (see the screen below)"
        else
            "still running");
    } else if (r.timed_out) {
        try res.text("timed out with no completion marker");
    }
    if (r.pending) {
        if (r.tracker) |nonce| {
            const tok: []const u8 = &nonce;
            try res.fact("tracker", tok);
            try res.textf("tracker: {s}", .{tok});
        }
        try res.fact("alt_screen", r.alt_screen);
        try res.fact("output_idle_ms", r.idle_ms);
        try res.fact("interactive_prompt", r.interactive_hint);
        try res.textf("alt_screen: {}, output_idle_ms: {d}", .{ r.alt_screen, r.idle_ms });
        if (screen_tail) |tail| try res.fact("screen", tail);
    }
    var file_note: ?[]const u8 = null;
    var inline_out: []const u8 = r.output;
    var inline_cap: usize = 200_000;
    if (output_file) |path| {
        if (path.len == 0 or path[0] != '/') {
            file_note = "output_file must be an absolute local path - ignored, full output inline";
        } else if (writeFileBytes(path, r.output)) {
            try res.fact("output_file", path);
            try res.fact("output_bytes", r.output.len);
            try res.textf("output_file: {s} ({d} bytes)", .{ path, r.output.len });
            inline_cap = 2_000;
        } else {
            file_note = "output_file could not be written (dir missing / not writable?) - full output inline";
        }
    }
    if (inline_out.len > inline_cap) {
        try res.fact("output_dropped_chars", inline_out.len - inline_cap);
        try res.textf("(dropped {d} leading chars)", .{inline_out.len - inline_cap});
        inline_out = inline_out[inline_out.len - inline_cap ..];
    }
    try res.fact("output", inline_out);
    if (file_note) |n| {
        try res.fact("output_file_note", n);
        try res.text(n);
    }
    const reason: ?[]const u8 = if (r.shell_died)
        "the shell/connection died before the command finished"
    else if (r.pending and r.interactive_hint)
        "the command appears to be WAITING FOR INPUT (see screen) - answer it with term_send_text/term_send_keys; the tracker stays attached and term_exec_wait picks up the completion afterwards"
    else if (r.pending)
        "still running - continue with term_exec_wait (do not resend); the tracker survives client-side timeouts and aborts"
    else
        null;
    if (reason) |n| {
        try res.fact("reason", n);
        try res.text(n);
    }
    if (r.pending) {
        if (screen_tail) |tail| {
            try res.text("--- screen ---");
            try res.text(tail);
        }
    }
    try res.text("--- output ---");
    try res.text(inline_out);
    return res.finish();
}

/// A safe interpreter name/path for term_exec's `shell` option: it is
/// interpolated into the transport script, so it must not carry shell
/// metacharacters.
pub fn validShellName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-' or ch == '/';
        if (!ok) return false;
    }
    return true;
}

test "validShellName" {
    const t = std.testing;
    try t.expect(validShellName("bash"));
    try t.expect(validShellName("/usr/bin/zsh"));
    try t.expect(validShellName("busybox-sh"));
    try t.expect(!validShellName(""));
    try t.expect(!validShellName("bash; rm -rf /"));
    try t.expect(!validShellName("bash $(x)"));
    try t.expect(!validShellName("../../bin/sh"));
}

/// Write bytes to an absolute local path the CALLER named; false on any failure.
///
/// A fresh file is private, but an existing one keeps its own mode: this is
/// the user's path, and clamping `output_file=/srv/www/build.log` back to
/// 0600 on every write makes the server that reads it start returning 403.
pub fn writeFileBytes(path: []const u8, bytes: []const u8) bool {
    atomicwrite.writeFile(path, bytes, 0o600) catch return false;
    return true;
}

test "term output files are created private and keep the user's mode" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-term-output-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/output.txt", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    try t.expect(writeFileBytes(path, "first"));
    var st: c.struct_stat = undefined;
    try t.expect(c.stat(path_z.ptr, &st) == 0);
    try t.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(st.st_mode & 0o777)));

    try t.expect(c.chmod(path_z.ptr, @as(c.mode_t, 0o644)) == 0);
    try t.expect(writeFileBytes(path, "second-and-complete"));
    try t.expect(c.stat(path_z.ptr, &st) == 0);
    try t.expectEqual(@as(c_uint, 0o644), @as(c_uint, @intCast(st.st_mode & 0o777)));
}

pub const Tool = mcp_tools.GroupTool(.term);

pub fn termTool(arena: std.mem.Allocator, tool: Tool, args: std.json.Value) ![]const u8 {
    if (term_state.mux_sock == null)
        return mcp.errRes(arena, .unavailable, "headless terminal tools need isolated mode; in --shared mode use the GUI-backed terminal tools (list_terminals, run_command, ...)");
    return switch (tool) {
        .term_open => termOpen(arena, args),
        // The terminal-content twins share one implementation with the
        // pane tools (mcp_panes.zig); `term` addresses the same sessions.
        .term_list => mcp_panes.listTerminals(arena, .term, null, args),
        .term_send_text => mcp_panes.sendText(arena, .term, null, args),
        .term_send_keys => mcp_panes.sendKeys(arena, .term, null, args),
        .term_read => mcp_panes.readScreen(arena, .term, null, args),
        .term_exec => withTerm(arena, args, termExec),
        .term_exec_wait => withTerm(arena, args, termExecWait),
        .term_wait_exit => withTerm(arena, args, termWaitExit),
        .term_run => mcp_panes.runCommand(arena, .term, null, args),
        .term_wait_command => withTerm(arena, args, termWaitCommand),
        .term_wait_idle => mcp_panes.waitIdle(arena, .term, null, args),
        .term_resize => withTerm(arena, args, termResize),
        .term_close => withTerm(arena, args, termClose),
    };
}

/// Resolve the addressed headless terminal, then run one term-scoped tool on it.
fn withTerm(
    arena: std.mem.Allocator,
    args: std.json.Value,
    comptime body: fn (std.mem.Allocator, std.json.Value, *termdrive.Term, u32) anyerror![]const u8,
) ![]const u8 {
    const t = termFromArgs(args, "term") orelse
        return mcp.errRes(arena, .not_found, "no such terminal (pass 'term' id, or omit it when only one is open)");
    return body(arena, args, t, termIdOf(t));
}

fn termOpen(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const cols: u16 = @intCast(std.math.clamp(argInt(args, "cols") orelse 120, 10, 500));
    const rows: u16 = @intCast(std.math.clamp(argInt(args, "rows") orelse 40, 4, 300));
    const host = argStr(args, "host");
    var cmd_string: ?[]const u8 = null;
    var cmd_array: ?[]const []const u8 = null;
    if (args == .object) {
        if (args.object.get("command")) |cmd| switch (cmd) {
            .string => cmd_string = cmd.string,
            .array => {
                const items = try arena.alloc([]const u8, cmd.array.items.len);
                for (cmd.array.items, 0..) |item, i| {
                    if (item != .string) return mcp.errRes(arena, .invalid_args, "command array must be strings");
                    items[i] = item.string;
                }
                if (items.len > 0) cmd_array = items;
            },
            else => {},
        };
    }
    const has_cmd = cmd_string != null or cmd_array != null;
    // Remote SHELL sessions get OSC 133 integration bootstrapped
    // into the remote bash/zsh so term_run wait_for=command works
    // on stock remotes. An explicit remote command,
    // integration:false, or a missing script dir keeps the plain
    // behavior.
    const want_integration = if (args == .object) blk: {
        const v = args.object.get("integration") orelse break :blk true;
        break :blk !(v == .bool and !v.bool);
    } else true;
    const transport = argStr(args, "transport") orelse "auto";
    if (!eql(u8, transport, "auto") and !eql(u8, transport, "mux") and !eql(u8, transport, "ssh"))
        return mcp.errRes(arena, .invalid_args, "transport must be 'auto', 'mux' or 'ssh'");

    var remote_integration = false;
    var via_mux = false;
    var id: u32 = 0;
    // Transparent transport upgrade: when the remote host has
    // sketerm-mux in PATH (key auth), the session lives on ITS
    // daemon — it survives connection drops (termdrive reattaches)
    // and the bootstrap rides the spawn argv instead of a typed
    // ssh forced command. Absent binary / password auth / any
    // failure falls back to plain interactive ssh below; the
    // assistant never chooses.
    if (host != null and !eql(u8, transport, "ssh")) mux: {
        var margv: []const []const u8 = undefined;
        if (cmd_array) |a| {
            margv = a;
        } else if (cmd_string) |s| {
            const trio = try arena.alloc([]const u8, 3);
            trio[0] = "/bin/sh";
            trio[1] = "-c";
            trio[2] = s;
            margv = trio;
        } else if (want_integration) {
            if (termdrive.integrationBootstrapScript(arena)) |script| {
                const trio = try arena.alloc([]const u8, 3);
                trio[0] = "/bin/sh";
                trio[1] = "-c";
                trio[2] = script;
                margv = trio;
                remote_integration = true;
            } else {
                margv = &@import("../mux/shell.zig").remote_login_argv;
            }
        } else {
            margv = &@import("../mux/shell.zig").remote_login_argv;
        }
        id = spawnRegisteredRemoteTerm(host.?, margv, cols, rows) catch {
            remote_integration = false;
            if (eql(u8, transport, "mux"))
                return mcp.errRes(arena, .unavailable, "no reachable sketerm-mux daemon on the remote host (needs key/agent auth and sketerm-mux in the remote PATH; transport 'auto' would fall back to plain ssh)");
            break :mux;
        };
        via_mux = true;
    }
    if (!via_mux) {
        var argv_store: std.ArrayList([]const u8) = .empty;
        defer argv_store.deinit(arena);
        if (host) |h| {
            // Persistent SSH session with keepalives: survives long
            // provisioning waits; interactive (auth prompts reach
            // the screen — drive them with term_send_text).
            try argv_store.appendSlice(arena, &.{
                "ssh", "-tt",
                "-o",  "ServerAliveInterval=15",
                "-o",  "ServerAliveCountMax=4",
            });
            // A forced route must survive the fall out of the mux path.
            const dest = appendRoute(arena, &argv_store, h, false) catch
                return mcp.errRes(arena, .refused, "cannot build the forced route for this host");
            try argv_store.append(arena, dest);
        }
        if (cmd_string) |s| {
            if (host != null) {
                try argv_store.append(arena, s);
            } else {
                try argv_store.appendSlice(arena, &.{ "/bin/sh", "-c", s });
            }
        } else if (cmd_array) |a| {
            try argv_store.appendSlice(arena, a);
        }
        if (host != null and !has_cmd and want_integration) {
            if (termdrive.sshIntegrationCommand(arena)) |boot| {
                try argv_store.append(arena, boot);
                remote_integration = true;
            }
        }
        const argv: ?[]const []const u8 = if (argv_store.items.len > 0) argv_store.items else null;
        id = spawnRegisteredTerm(argv, cols, rows) catch |err| switch (err) {
            error.SpawnFailed => return mcp.errRes(arena, .unavailable, "spawn failed (mux daemon unreachable?)"),
            else => return err,
        };
    }
    const t = term_state.terms.get(id).?;
    // The injection claim: command-mode still waits for the first
    // real prompt mark before trusting it, so an unsupported
    // remote shell degrades to an honest not-ready refusal.
    if (remote_integration) t.integration = true;
    if (host != null) t.setRemoteShellPending(remote_integration);
    // Let the shell print its first prompt.
    _ = t.waitIdle(250, 3_000);
    // SSH: wait (bounded) for the bootstrap's announce line so
    // THIS reply names the remote shell — bailing early when the
    // screen sits behind an auth prompt, because the assistant
    // needs the reply back to answer it.
    if (host != null and remote_integration and !t.scanShellAnnounce()) {
        const announce_deadline = nowMs() + 8_000;
        while (!t.scanShellAnnounce() and nowMs() < announce_deadline and !t.exited) {
            if (termdrive.looksInteractive(termLastLine(arena, t))) break;
            _ = t.waitIdle(150, 400);
        }
    }
    const shell_note: []const u8 = blk: {
        if (t.shell_name) |sn|
            break :blk try std.fmt.allocPrint(arena, ", shell: {s}, integration: {s}", .{ sn, if (t.integration) "active" else "inactive" });
        if (host != null and remote_integration)
            break :blk ", shell: not detected yet (ssh still connecting or auth pending; term_list reports it once the session is up)";
        if (host != null)
            break :blk ", shell: unknown (integration disabled; nothing injected to report it)";
        break :blk "";
    };
    const where = if (host) |h| blk: {
        // Key on the detected OUTCOME: a bootstrap that landed on
        // dash/fish announces "no integration" and flips
        // t.integration off — steering to wait_for=command there
        // would point at a tool that refuses.
        const drive_note = if (remote_integration and t.integration)
            "shell integration is auto-injected into a remote bash/zsh — prefer term_run wait_for=command for remote commands (stateful, readable, exact exit status); term_exec when you need isolation or a guaranteed dialect"
        else
            "term_exec gives structured remote command results";
        if (via_mux)
            break :blk try std.fmt.allocPrint(arena, " durable remote session on {s} via its sketerm-mux daemon (survives connection drops — reattached transparently; {s})", .{ h, drive_note });
        break :blk try std.fmt.allocPrint(arena, " running ssh to {s} (watch term_read for auth prompts; {s})", .{ h, drive_note });
    } else "";
    const rec_note = if (rec_state.casts.get(id)) |p|
        try std.fmt.allocPrint(arena, "\nrecording: {s} (asciicast v2, replayable with asciinema)", .{p})
    else
        "";
    var res = mcp.Res.init(arena);
    try res.fact("term", id);
    try res.fact("cols", cols);
    try res.fact("rows", rows);
    try res.fact("transport", if (via_mux) "sketerm-mux" else if (host != null) "ssh" else "local");
    if (host) |h| try res.fact("host", h);
    if (t.shell_name) |sn| try res.fact("shell", sn);
    try res.fact("integration", t.integration);
    if (rec_state.casts.get(id)) |p| try res.fact("recording", p);
    try res.textf("opened headless terminal {d} ({d}x{d}{s}){s}{s}", .{ id, cols, rows, shell_note, where, rec_note });
    return res.finish();
}





fn termExec(arena: std.mem.Allocator, args: std.json.Value, t: *termdrive.Term, _: u32) ![]const u8 {
    const cmd = argStr(args, "command") orelse return mcp.errRes(arena, .invalid_args, "term_exec requires 'command'");
    // Clamped below the 150s watchdog: one blocked call must never
    // wedge the single-threaded loop long enough to starve
    // term_list/term_read or trip the connection-aborting cap.
    // Longer waits = repeated term_exec_wait calls.
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
    // Default true: the isolated transport works typed into ANY
    // shell dialect (fish/zsh/bash, local or remote); false is the
    // POSIX-only state-persisting mode.
    const subshell = if (args == .object) blk: {
        const v = args.object.get("subshell") orelse break :blk true;
        break :blk v == .bool and v.bool;
    } else true;
    const noninteractive = argBool(args, "noninteractive");
    if (noninteractive and !subshell)
        return mcp.errRes(arena, .invalid_args, "'noninteractive' needs the default isolated transport (drop subshell:false)");
    const shell = argStr(args, "shell");
    if (shell) |sh| {
        if (!subshell)
            return mcp.errRes(arena, .invalid_args, "'shell' needs the default isolated transport (drop subshell:false)");
        if (!validShellName(sh))
            return mcp.errRes(arena, .invalid_args, "invalid 'shell' (a command name or absolute path: letters, digits, . _ - / only)");
    }
    if (t.hasPendingExec()) {
        // A previously timed-out exec may have finished since;
        // resolve it silently so the new send is accepted.
        if (t.waitExecResult(0)) |r0| term_state.allocator.free(r0.output);
        if (t.hasPendingExec())
            return mcp.errRes(arena, .conflict, "a previous term_exec is still running in this terminal; continue it with term_exec_wait (or interrupt with term_send_keys ctrl+c)");
    }
    if (t.hasPendingCommand())
        return mcp.errRes(arena, .conflict, "a term_run wait_for=command command is still tracked; resolve it with term_wait_command first");
    const r = t.execCommand(cmd, subshell, noninteractive, shell, timeout_ms) catch |err| return switch (err) {
        termdrive.Error.NotConnected => mcp.errRes(arena, .conflict, "terminal exited"),
        else => appErr(arena, "exec failed"),
    };
    defer term_state.allocator.free(r.output);
    return execResultJson(arena, r, t, argStr(args, "output_file"));
}

fn termExecWait(arena: std.mem.Allocator, args: std.json.Value, t: *termdrive.Term, _: u32) ![]const u8 {
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
    const r = t.waitExecResult(timeout_ms) orelse
        return mcp.errRes(arena, .not_found, "no pending term_exec in this terminal");
    defer term_state.allocator.free(r.output);
    return execResultJson(arena, r, t, argStr(args, "output_file"));
}

fn termWaitExit(arena: std.mem.Allocator, args: std.json.Value, t: *termdrive.Term, term_id: u32) ![]const u8 {
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
    const exited = t.waitExit(timeout_ms);
    const tail = blk: {
        const text = t.readScreen(false) catch break :blk "";
        defer term_state.allocator.free(text);
        break :blk try arena.dupe(u8, tailLines(text, 8));
    };
    var res = mcp.Res.init(arena);
    try res.fact("term", term_id);
    try res.fact("exited", exited);
    try res.fact("timed_out", !exited);
    if (exited and t.exit_status_known) {
        try res.fact("exit_status", t.exit_status);
        try res.textf("terminal {d} exited with status {d}", .{ term_id, t.exit_status });
    } else if (exited) {
        try res.textf("terminal {d} exited (status unknown)", .{term_id});
    } else {
        try res.textf("terminal {d} still running at timeout", .{term_id});
    }
    if (tail.len > 0) {
        try res.fact("screen_tail", tail);
        try res.text("--- screen tail ---");
        try res.text(tail);
    }
    return res.finish();
}

/// term_run / run_command with wait_for=command on a headless terminal:
/// wait for the shell's own completion mark (OSC 133 D) of THIS command,
/// never for output to go quiet.
pub fn runCommandMode(arena: std.mem.Allocator, t: *termdrive.Term, cmd: []const u8, timeout_ms: i64, output_only: bool) ![]const u8 {
    // A tracked command may have completed since its timeout: one short
    // drain clears it so the new send is accepted.
    if (t.hasPendingCommand()) _ = t.waitPendingCommand(0);
    if (t.hasPendingCommand()) {
        return commandCompletionResult(arena, .{ .state = .running }, false, null, null, "a previously timed-out command is still running; use term_wait_command instead of resending");
    }
    // The token wait spends from the same budget as the completion wait,
    // so the call never outlives timeout_ms.
    const started = nowMs();
    const token_res = t.commandToken(@min(timeout_ms, 10_000)) catch return mcp.errRes(arena, .unavailable, "command completion unavailable (terminal exited?)");
    const token = switch (token_res) {
        .unsupported => return commandCompletionResult(arena, .{ .state = .unsupported }, false, null, null, "shell integration is unavailable for this shell; command was not sent and no exit status was fabricated"),
        .not_ready => return commandCompletionResult(arena, .{ .state = .unsupported, .timed_out = true }, false, null, null, "shell integration is injected but no prompt mark has arrived yet (shell still starting, ssh auth still pending, an unsupported remote shell, or rc files broke the injection); command was not sent — retry shortly, or use term_exec"),
        .busy => return commandCompletionResult(arena, .{ .state = .running }, false, null, null, "a foreground command started outside command mode is still running; its completion would be misattributed. Wait for it (term_wait_idle) before sending in command mode"),
        .token => |tok| tok,
    };
    const line = try std.fmt.allocPrint(arena, "{s}\r", .{cmd});
    t.sendText(line) catch return mcp.errRes(arena, .conflict, "send failed (terminal exited?)");
    t.trackCommand(token);
    const result = t.waitCommand(token, @max(0, timeout_ms - (nowMs() - started)));
    return completionReply(arena, t, result, output_only);
}

/// A command-mode completion, with the command's own zone as the output
/// when asked for and the shell reported one, else the screen.
fn completionReply(arena: std.mem.Allocator, t: *termdrive.Term, result: termdrive.CommandCompletion, output_only: bool) ![]const u8 {
    var owned_output: ?[]u8 = null;
    defer if (owned_output) |text| term_state.allocator.free(text);
    var output_kind: []const u8 = "screen";
    if (result.state == .completed and result.source == .shell_integration and output_only) {
        if (t.lastCommand() catch null) |lc| {
            owned_output = lc.text;
            output_kind = "command";
        }
    }
    if (owned_output == null) owned_output = t.readScreen(false) catch null;
    return commandCompletionResult(arena, result, true, owned_output, output_kind, switch (result.state) {
        .running => "timeout expired while the command was still running; output may have been idle",
        .unknown => "terminal disconnected before a reliable completion status was received",
        .unsupported => unreachable,
        .completed => null,
    });
}

fn termWaitCommand(arena: std.mem.Allocator, args: std.json.Value, t: *termdrive.Term, _: u32) ![]const u8 {
    const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
    const result = t.waitPendingCommand(timeout_ms) orelse
        return mcp.errRes(arena, .not_found, "no timed-out command is being tracked");
    return completionReply(arena, t, result, argBool(args, "output_only"));
}


fn termResize(arena: std.mem.Allocator, args: std.json.Value, t: *termdrive.Term, term_id: u32) ![]const u8 {
    const cols: u16 = @intCast(std.math.clamp(argInt(args, "cols") orelse 120, 10, 500));
    const rows: u16 = @intCast(std.math.clamp(argInt(args, "rows") orelse 40, 4, 300));
    t.resize(cols, rows) catch return mcp.errRes(arena, .conflict, "resize failed (terminal exited?)");
    _ = t.waitIdle(200, 2_000);
    var res = mcp.Res.init(arena);
    try res.fact("term", term_id);
    try res.fact("cols", cols);
    try res.fact("rows", rows);
    try res.textf("terminal {d} resized to {d}x{d}", .{ term_id, cols, rows });
    return res.finish();
}

fn termClose(arena: std.mem.Allocator, _: std.json.Value, t: *termdrive.Term, _: u32) ![]const u8 {
    const id = termIdOf(t);
    _ = term_state.terms.swapRemove(id);
    t.deinit();
    // The daemon finalizes the cast with the session; keep the
    // path out of future term_list output.
    if (rec_state.casts.fetchSwapRemove(id)) |kv| rec_state.allocator.free(kv.value);
    var res = mcp.Res.init(arena);
    try res.fact("term", id);
    try res.fact("closed", true);
    try res.textf("terminal {d} closed", .{id});
    return res.finish();
}

// ── File transfer + port forwards ─────────────────────────────────

/// Streaming SHA-256 of a local file; null when unreadable.
pub fn sha256File(path: []const u8) ?[64]u8 {
    var pbuf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    const f = c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    var hex: [64]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = alphabet[b >> 4];
        hex[i * 2 + 1] = alphabet[b & 0xf];
    }
    return hex;
}

pub fn fileSize(path: []const u8) ?u64 {
    var pbuf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    var st: c.struct_stat = undefined;
    if (c.stat(path_z.ptr, &st) != 0) return null;
    return @intCast(@max(st.st_size, 0));
}

/// Local copy with checksum + atomic rename (the host==null transfer path).
pub fn localCopyAtomic(arena: std.mem.Allocator, src: []const u8, dst: []const u8) !union(enum) { ok: struct { bytes: u64, sha: [64]u8 }, err: []const u8 } {
    var sbuf: [4096]u8 = undefined;
    const src_z = std.fmt.bufPrintZ(&sbuf, "{s}", .{src}) catch return .{ .err = "path too long" };
    const part = try std.fmt.allocPrint(arena, "{s}.sketerm-part", .{dst});
    var dbuf: [4096]u8 = undefined;
    const part_z = std.fmt.bufPrintZ(&dbuf, "{s}", .{part}) catch return .{ .err = "path too long" };
    const in = c.fopen(src_z.ptr, "rb") orelse return .{ .err = "cannot read the source file" };
    defer _ = c.fclose(in);
    const out = c.fopen(part_z.ptr, "wb") orelse return .{ .err = "cannot write the destination (parent dir missing or not writable?)" };
    var total: u64 = 0;
    var buf: [65536]u8 = undefined;
    var write_failed = false;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, in);
        if (n == 0) break;
        if (c.fwrite(&buf, 1, n, out) != n) {
            write_failed = true;
            break;
        }
        total += n;
    }
    const flush_bad = c.fclose(out) != 0;
    if (write_failed or flush_bad) {
        _ = c.unlink(part_z.ptr);
        return .{ .err = "short write copying the file (disk full?)" };
    }
    const src_sha = sha256File(src) orelse return .{ .err = "cannot hash the source file" };
    const part_sha = sha256File(part) orelse return .{ .err = "cannot hash the copied file" };
    if (!std.mem.eql(u8, &src_sha, &part_sha)) {
        _ = c.unlink(part_z.ptr);
        return .{ .err = "checksum mismatch after local copy" };
    }
    var fbuf: [4096]u8 = undefined;
    const dst_z = std.fmt.bufPrintZ(&fbuf, "{s}", .{dst}) catch return .{ .err = "path too long" };
    if (c.rename(part_z.ptr, dst_z.ptr) != 0) {
        _ = c.unlink(part_z.ptr);
        return .{ .err = "atomic rename to the destination failed" };
    }
    return .{ .ok = .{ .bytes = total, .sha = src_sha } };
}

/// Ask the kernel for a free loopback TCP port.
pub fn pickFreePort() ?u16 {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = 0;
    _ = c.inet_pton(c.AF_INET, "127.0.0.1", &addr.sin_addr);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0) return null;
    var out: c.struct_sockaddr_in = undefined;
    var olen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    if (c.getsockname(fd, @ptrCast(&out), &olen) != 0) return null;
    const port = std.mem.bigToNative(u16, out.sin_port);
    if (port == 0) return null;
    return port;
}

/// Can something be connected to on 127.0.0.1:port right now?
pub fn tcpListening(port: u16, timeout_ms: i64) bool {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(port);
    _ = c.inet_pton(c.AF_INET, "127.0.0.1", &addr.sin_addr);
    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in));
    if (rc == 0) return true;
    if (std.posix.errno(rc) != .INPROGRESS) return false;
    var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
    if (c.poll(&pfd, 1, @intCast(std.math.clamp(timeout_ms, 1, 30_000))) <= 0) return false;
    var so_err: c_int = 0;
    var slen: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &so_err, &slen) != 0) return false;
    return so_err == 0;
}

/// Run a short-lived argv (scp / ssh command) in an unregistered
/// headless terminal, wait for its exit, and hand back status + the
/// rendered output. `.output` is arena-owned.
pub const ArgvRun = struct { exited: bool, status: i32, status_known: bool, output: []const u8 };
/// Append the route options for `host` and return its bare SSH destination.
///
/// `term_open`'s plain-ssh fallback, both transfer directions and the port
/// forwarder each build their own ssh/scp argv, so a `tor:` host reached any
/// of those ways would otherwise hand the literal prefixed alias to the
/// resolver instead of staying on the forced route. Options are duped into
/// `arena`: the Tor ProxyCommand lives inside the stack-local `Args`.
fn appendRoute(
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    host: []const u8,
    ssh_flags: bool,
) ![]const u8 {
    const remote = sshroute.RemoteSpec.parse(host);
    if (remote.mode != .tor) return host;
    var cfg = Config.load(arena);
    defer cfg.deinit();
    const plan = try sshroute.Plan.init(remote.host, .tor, cfg.mux_tor_socks_endpoint);
    var args = try plan.args(false);
    try args.appendSlices(arena, out, ssh_flags);
    return try arena.dupe(u8, remote.host);
}

pub fn runArgvTerm(arena: std.mem.Allocator, argv: []const []const u8, timeout_ms: i64) !union(enum) { run: ArgvRun, err: []const u8 } {
    const t = termdrive.Term.spawn(term_state.allocator, argv, 120, 30, term_state.mux_sock) catch
        return .{ .err = "spawn failed (mux daemon unreachable?)" };
    defer t.deinit();
    recordAuxTerm(t, std.fs.path.basename(argv[0]));
    const exited = t.waitExit(timeout_ms);
    const output = blk: {
        const text = t.readScreen(true) catch break :blk "";
        defer term_state.allocator.free(text);
        break :blk try arena.dupe(u8, std.mem.trim(u8, text, "\n "));
    };
    return .{ .run = .{
        .exited = exited,
        .status = t.exit_status,
        .status_known = t.exit_status_known,
        .output = output,
    } };
}

/// Shell-quote into an arena string.
pub fn quoted(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(arena);
    try shellquote.appendQuoted(&list, arena, s);
    return arena.dupe(u8, list.items);
}

/// Staged-transfer temp name that PRESERVES the file extension, so
/// suffix-sensitive validators (systemd-analyze verify needs .service)
/// accept the staged file: "a/b.service" → "a/b.sketerm-part.service";
/// extensionless paths get a plain ".sketerm-part" suffix.
pub fn stagedPartPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
    const base = path[base_start..];
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot > 0 and dot + 1 < base.len) {
            return std.fmt.allocPrint(arena, "{s}{s}.sketerm-part.{s}", .{ path[0..base_start], base[0..dot], base[dot + 1 ..] });
        }
    }
    return std.fmt.allocPrint(arena, "{s}.sketerm-part", .{path});
}

/// Wrap a POSIX script for execution on a REMOTE host regardless of
/// the login shell sshd hands it to (fish included): base64 → sh.
pub fn remoteShLine(arena: std.mem.Allocator, script: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(script.len));
    _ = enc.encode(b64, script);
    return std.fmt.allocPrint(arena, "echo {s} | base64 -d | sh", .{b64});
}

/// The follow-up leg's budget: what is left of the transfer's deadline,
/// capped at `cap` and floored at 5s so the checksum is always attempted.
/// The floor keeps the worst case (120s + 5s) under the 150s watchdog.
fn legBudget(deadline_ms: i64, cap: i64) i64 {
    return @max(5_000, @min(cap, deadline_ms - nowMs()));
}

/// One `port_forward_list` element.
///
/// `host`/`remote_host` are CALLER-supplied and must go through the JSON
/// encoder: ssh resolves a `-L` spec's remote host only when a connection
/// arrives, so it binds the local port for one holding a quote or a
/// newline, the forward registers, and a hand-written object then emitted
/// that byte raw — invalid JSON, and a newline splits the NDJSON line.
fn forwardElemJson(
    w: *std.Io.Writer,
    id: u32,
    host: []const u8,
    local_port: u16,
    remote_host: []const u8,
    remote_port: u16,
    alive: bool,
    reconnects: u32,
) !void {
    try w.print("{{\"forward\":{d},\"host\":", .{id});
    try std.json.Stringify.value(host, .{}, w);
    try w.print(",\"local_port\":{d},\"remote_host\":", .{local_port});
    try std.json.Stringify.value(remote_host, .{}, w);
    try w.print(",\"remote_port\":{d},\"alive\":{},\"reconnects\":{d}}}", .{ remote_port, alive, reconnects });
}

/// Full ssh argv running `script` on `host`, honouring the host's
/// forced route.
///
/// The one builder for every one-shot remote script leg of the transfer
/// tools: hand-assembling the argv is how `scp_get`'s checksum leg came
/// to pass a `tor:` alias straight to ssh as a hostname, so a Tor
/// download could never verify and always kept its partial.
pub fn remoteShArgv(arena: std.mem.Allocator, host: []const u8, script: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(arena);
    try argv.appendSlice(arena, &.{ "ssh", "-o", "BatchMode=yes" });
    const dest = try appendRoute(arena, &argv, host, false);
    try argv.appendSlice(arena, &.{ dest, try remoteShLine(arena, script) });
    return argv.toOwnedSlice(arena);
}

/// Find a 64-char lowercase-hex token in text (remote sha output).
pub fn findHex64(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 64 <= text.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < 64) : (j += 1) {
            const ch = text[i + j];
            if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) {
                ok = false;
                break;
            }
        }
        if (ok) {
            // Must not be part of a longer run.
            const before_ok = i == 0 or !std.ascii.isHex(text[i - 1]);
            const after_ok = i + 64 == text.len or !std.ascii.isHex(text[i + 64]);
            if (before_ok and after_ok) return text[i .. i + 64];
        }
    }
    return null;
}

pub fn xferOk(arena: std.mem.Allocator, direction: []const u8, path: []const u8, bytes: ?u64, sha: []const u8) ![]const u8 {
    var res = mcp.Res.init(arena);
    try res.fact("direction", direction);
    try res.fact("path", path);
    try res.fact("bytes", bytes);
    try res.fact("sha256", sha);
    // Both are invariants of this code path: the transfer only reaches
    // here after a checksum match and an atomic rename/move.
    try res.fact("verified", true);
    try res.fact("atomic", true);
    if (bytes) |b|
        try res.textf("{s} ok: {s} ({d} bytes), sha256 verified, moved atomically", .{ direction, path, b })
    else
        try res.textf("{s} ok: {s}, sha256 verified, moved atomically", .{ direction, path });
    try res.textf("sha256: {s}", .{sha});
    return res.finish();
}

pub const ForwardTool = mcp_tools.GroupTool(.net);

pub fn forwardTool(arena: std.mem.Allocator, tool: ForwardTool, args: std.json.Value) ![]const u8 {
    if (term_state.mux_sock == null)
        return mcp.errRes(arena, .unavailable, "file transfer / port forward tools need isolated mode (they run over private headless terminals)");
    return switch (tool) {
        .port_forward_open => portForwardOpen(arena, args),
        .port_forward_list => portForwardList(arena, args),
        .port_forward_check => withForward(arena, args, portForwardCheck),
        .port_forward_close => withForward(arena, args, portForwardClose),
    };
}

pub fn scpTool(arena: std.mem.Allocator, upload: bool, args: std.json.Value) ![]const u8 {
    if (term_state.mux_sock == null)
        return mcp.errRes(arena, .unavailable, "file transfer / port forward tools need isolated mode (they run over private headless terminals)");
    const local = argStr(args, "local_path") orelse return mcp.errRes(arena, .invalid_args, "requires 'local_path'");
    const remote = argStr(args, "remote_path") orelse return mcp.errRes(arena, .invalid_args, "requires 'remote_path'");
    const timeout_ms: i64 = mcp.waitCap(argInt(args, "timeout_ms"), 120_000);
    // A transfer is TWO ssh legs, and their budgets used to add up
    // (120s + 60s) past the 150s watchdog, which aborts the call and
    // leaves the sessions reading as exited. `timeout_ms` bounds the
    // scp; the checksum leg gets what is left of it, floored so it
    // is always attempted.
    const xfer_deadline = nowMs() + timeout_ms;
    const host = argStr(args, "host");

    if (host == null) {
        const src = if (upload) local else remote;
        const dst = if (upload) remote else local;
        switch (try localCopyAtomic(arena, src, dst)) {
            .ok => |r| return xferOk(arena, if (upload) "upload" else "download", dst, r.bytes, &r.sha),
            .err => |e| return mcp.errRes(arena, .io_failed, e),
        }
    }
    const h = host.?;

    if (upload) {
        const local_sha = sha256File(local) orelse return mcp.errRes(arena, .io_failed, "cannot read/hash the local file");
        const bytes = fileSize(local);
        const tmp = try stagedPartPath(arena, remote);
        var scp_argv: std.ArrayList([]const u8) = .empty;
        defer scp_argv.deinit(arena);
        try scp_argv.appendSlice(arena, &.{ "scp", "-q", "-o", "BatchMode=yes" });
        const dest = appendRoute(arena, &scp_argv, h, false) catch
            return mcp.errRes(arena, .refused, "cannot build the forced route for this host");
        const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ dest, tmp });
        try scp_argv.appendSlice(arena, &.{ local, spec });
        switch (try runArgvTerm(arena, scp_argv.items, timeout_ms)) {
            .err => |e| return mcp.errRes(arena, .unavailable, e),
            .run => |r| {
                if (!r.exited) return mcp.errRes(arena, .timeout, "scp still running at timeout; the transfer terminal was killed — retry with a larger timeout_ms");
                if (!r.status_known or r.status != 0)
                    return mcp.errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "scp failed (status {d}):\n{s}", .{ r.status, r.output }));
            },
        }
        // Checksum + optional caller validation + atomic move in
        // ONE remote script (b64→sh so the remote login shell's
        // dialect is irrelevant); echo tokens report the branch.
        var verify_layer: []const u8 = "mv -f \"$SK_TMP\" \"$SK_DST\" && echo SK_MOVED || echo SK_MVFAIL";
        if (argStr(args, "verify_command")) |vc| {
            // "{}" marks where the staged path goes; without it
            // the path is appended as the final argument.
            const resolved = if (std.mem.indexOf(u8, vc, "{}")) |at|
                try std.fmt.allocPrint(arena, "{s}\"$SK_TMP\"{s}", .{ vc[0..at], vc[at + 2 ..] })
            else
                try std.fmt.allocPrint(arena, "{s} \"$SK_TMP\"", .{vc});
            verify_layer = try std.fmt.allocPrint(
                arena,
                "if ( {s} ); then mv -f \"$SK_TMP\" \"$SK_DST\" && echo SK_MOVED || echo SK_MVFAIL; else echo \"SK_VERIFYFAIL:$?\"; rm -f \"$SK_TMP\"; fi",
                .{resolved},
            );
        }
        const script = try std.fmt.allocPrint(
            arena,
            "SK_TMP={s}\nSK_DST={s}\nsha=$(sha256sum \"$SK_TMP\" 2>/dev/null | cut -c1-64) || sha=fail\nif [ \"$sha\" = \"{s}\" ]; then {s}; else echo \"SK_SHA:$sha\"; rm -f \"$SK_TMP\"; fi\n",
            .{ try quoted(arena, tmp), try quoted(arena, remote), local_sha, verify_layer },
        );
        const move_argv = remoteShArgv(arena, h, script) catch
            return mcp.errRes(arena, .refused, "cannot build the forced route for this host");
        switch (try runArgvTerm(arena, move_argv, legBudget(xfer_deadline, 60_000))) {
            .err => |e| return mcp.errRes(arena, .unavailable, e),
            .run => |r| {
                if (std.mem.indexOf(u8, r.output, "SK_MOVED") != null)
                    return xferOk(arena, "upload", remote, bytes, &local_sha);
                if (std.mem.indexOf(u8, r.output, "SK_VERIFYFAIL") != null)
                    return mcp.errRes(arena, .refused, try std.fmt.allocPrint(arena, "verify_command rejected the staged file — upload discarded, destination untouched:\n{s}", .{r.output}));
                if (std.mem.indexOf(u8, r.output, "SK_MVFAIL") != null)
                    return mcp.errRes(arena, .io_failed, "checksum verified but the atomic move failed on the remote (target dir not writable?)");
                if (std.mem.indexOf(u8, r.output, "SK_SHA:fail") != null)
                    return mcp.errRes(arena, .unavailable, "remote has no usable sha256sum — cannot verify; file left absent (partial removed)");
                return mcp.errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "remote checksum mismatch — corrupt transfer discarded:\n{s}", .{r.output}));
            },
        }
    }

    // download
    const part = try stagedPartPath(arena, local);
    var dl_argv: std.ArrayList([]const u8) = .empty;
    defer dl_argv.deinit(arena);
    try dl_argv.appendSlice(arena, &.{ "scp", "-q", "-o", "BatchMode=yes" });
    const dl_dest = appendRoute(arena, &dl_argv, h, false) catch
        return mcp.errRes(arena, .refused, "cannot build the forced route for this host");
    const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ dl_dest, remote });
    try dl_argv.appendSlice(arena, &.{ spec, part });
    switch (try runArgvTerm(arena, dl_argv.items, timeout_ms)) {
        .err => |e| return mcp.errRes(arena, .unavailable, e),
        .run => |r| {
            if (!r.exited) return mcp.errRes(arena, .timeout, "scp still running at timeout; the transfer terminal was killed — retry with a larger timeout_ms");
            if (!r.status_known or r.status != 0)
                return mcp.errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "scp failed (status {d}):\n{s}", .{ r.status, r.output }));
        },
    }
    const part_sha = sha256File(part) orelse return mcp.errRes(arena, .io_failed, "downloaded file vanished before hashing");
    const bytes = fileSize(part);
    const script = try std.fmt.allocPrint(arena, "sha256sum {s} 2>/dev/null | cut -c1-64\n", .{try quoted(arena, remote)});
    const verify_argv = remoteShArgv(arena, h, script) catch
        return mcp.errRes(arena, .refused, "cannot build the forced route for this host");
    switch (try runArgvTerm(arena, verify_argv, legBudget(xfer_deadline, 30_000))) {
        .err => |e| return mcp.errRes(arena, .unavailable, e),
        .run => |r| {
            const remote_sha = findHex64(r.output) orelse
                return mcp.errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "remote sha256sum gave no hash — cannot verify (partial kept at {s}):\n{s}", .{ part, r.output }));
            if (!std.mem.eql(u8, remote_sha, &part_sha)) {
                var pbuf: [4096]u8 = undefined;
                if (std.fmt.bufPrintZ(&pbuf, "{s}", .{part})) |pz| _ = c.unlink(pz.ptr) else |_| {}
                return mcp.errRes(arena, .io_failed, "checksum mismatch — corrupt download discarded");
            }
        },
    }
    var pbuf: [4096]u8 = undefined;
    var dbuf: [4096]u8 = undefined;
    const part_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{part}) catch return mcp.errRes(arena, .invalid_args, "path too long");
    const local_z = std.fmt.bufPrintZ(&dbuf, "{s}", .{local}) catch return mcp.errRes(arena, .invalid_args, "path too long");
    if (c.rename(part_z.ptr, local_z.ptr) != 0)
        return mcp.errRes(arena, .io_failed, "atomic rename into place failed");
    return xferOk(arena, "download", local, bytes, &part_sha);
}

/// Resolve the addressed port forward, then run one forward-scoped tool on it.
fn withForward(
    arena: std.mem.Allocator,
    args: std.json.Value,
    comptime body: fn (std.mem.Allocator, std.json.Value, *Forward) anyerror![]const u8,
) ![]const u8 {
    const f = forwardFromArgs(args) orelse
        return mcp.errRes(arena, .not_found, "no such forward (pass 'forward' from port_forward_open, or omit it when only one is open)");
    return body(arena, args, f);
}

fn portForwardOpen(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const h = argStr(args, "host") orelse return mcp.errRes(arena, .invalid_args, "port_forward_open requires 'host'");
    const rp_i = argInt(args, "remote_port") orelse return mcp.errRes(arena, .invalid_args, "port_forward_open requires 'remote_port'");
    if (rp_i < 1 or rp_i > 65535) return mcp.errRes(arena, .invalid_args, "remote_port out of range");
    const rp: u16 = @intCast(rp_i);
    const rh = argStr(args, "remote_host") orelse "127.0.0.1";
    const lp: u16 = if (argInt(args, "local_port")) |v| blk: {
        if (v < 1 or v > 65535) return mcp.errRes(arena, .invalid_args, "local_port out of range");
        break :blk @intCast(v);
    } else pickFreePort() orelse return mcp.errRes(arena, .unavailable, "could not pick a free local port");
    const timeout_ms: i64 = mcp.waitCap(argInt(args, "timeout_ms"), 20_000);

    const t = spawnForwardTerm(arena, h, lp, rh, rp) catch
        return mcp.errRes(arena, .unavailable, "spawn failed (mux daemon unreachable?)");
    switch (try waitForwardReady(arena, t, lp, timeout_ms)) {
        .ready => {},
        .err => |e| {
            t.deinit();
            return mcp.errRes(arena, .unavailable, e);
        },
    }
    const a = forward_state.allocator;
    const f = a.create(Forward) catch {
        t.deinit();
        return error.OutOfMemory;
    };
    f.* = .{
        .id = forward_state.next_id,
        .host = a.dupe(u8, h) catch return error.OutOfMemory,
        .local_port = lp,
        .remote_host = a.dupe(u8, rh) catch return error.OutOfMemory,
        .remote_port = rp,
        .term = t,
    };
    forward_state.next_id += 1;
    forward_state.forwards.put(a, f.id, f) catch {
        t.deinit();
        return error.OutOfMemory;
    };
    var res = mcp.Res.init(arena);
    try res.fact("forward", f.id);
    try res.fact("local_port", lp);
    try res.fact("host", h);
    try res.fact("remote_host", rh);
    try res.fact("remote_port", rp);
    try res.fact("listening", true);
    try res.textf("forward {d}: 127.0.0.1:{d} -> {s} ({s}:{d}), listening", .{ f.id, lp, h, rh, rp });
    return res.finish();
}

fn portForwardList(arena: std.mem.Allocator, _: std.json.Value) ![]const u8 {
    var res = mcp.Res.init(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");
    for (forward_state.forwards.values(), 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        f.term.drain();
        try forwardElemJson(w, f.id, f.host, f.local_port, f.remote_host, f.remote_port, !f.term.exited, f.reconnects);
        try res.textf("forward {d}: 127.0.0.1:{d} -> {s} ({s}:{d}), alive: {}, reconnects: {d}", .{ f.id, f.local_port, f.host, f.remote_host, f.remote_port, !f.term.exited, f.reconnects });
    }
    try w.writeAll("]");
    try res.raw("forwards", aw.written());
    try res.fact("count", forward_state.forwards.count());
    if (forward_state.forwards.count() == 0) try res.text("no port forwards are open");
    return res.finish();
}

fn portForwardCheck(arena: std.mem.Allocator, args: std.json.Value, f: *Forward) ![]const u8 {
    f.term.drain();
    var reconnected = false;
    if (f.term.exited) {
        // The ssh process died (network blip, sshd restart):
        // respawn the same spec — this IS the reconnect behavior.
        const nt = spawnForwardTerm(arena, f.host, f.local_port, f.remote_host, f.remote_port) catch
            return mcp.errRes(arena, .unavailable, "forward is dead and respawn failed (mux daemon unreachable?)");
        switch (try waitForwardReady(arena, nt, f.local_port, mcp.waitCap(argInt(args, "timeout_ms"), 20_000))) {
            .ready => {
                f.term.deinit();
                f.term = nt;
                f.reconnects += 1;
                reconnected = true;
            },
            .err => |e| {
                nt.deinit();
                return mcp.errRes(arena, .unavailable, try std.fmt.allocPrint(arena, "forward is dead and the reconnect failed: {s}", .{e}));
            },
        }
    }
    const listening = tcpListening(f.local_port, 2_000);
    var res = mcp.Res.init(arena);
    try res.fact("forward", f.id);
    try res.fact("alive", !f.term.exited);
    try res.fact("listening", listening);
    try res.fact("reconnected", reconnected);
    try res.fact("local_port", f.local_port);
    try res.textf("forward {d} on 127.0.0.1:{d}: alive: {}, listening: {}{s}", .{ f.id, f.local_port, !f.term.exited, listening, if (reconnected) ", reconnected" else "" });
    return res.finish();
}

fn portForwardClose(arena: std.mem.Allocator, _: std.json.Value, f: *Forward) ![]const u8 {
    const closed_id = f.id;
    forward_state.removeOne(f);
    var res = mcp.Res.init(arena);
    try res.fact("forward", closed_id);
    try res.fact("closed", true);
    try res.textf("forward {d} closed", .{closed_id});
    return res.finish();
}

pub fn spawnForwardTerm(arena: std.mem.Allocator, host: []const u8, lp: u16, rh: []const u8, rp: u16) !*termdrive.Term {
    const bindspec = try std.fmt.allocPrint(arena, "127.0.0.1:{d}:{s}:{d}", .{ lp, rh, rp });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(arena);
    try argv.appendSlice(arena, &.{
        "ssh",                      "-N",
        "-T",                       "-o",
        "BatchMode=yes",            "-o",
        "ExitOnForwardFailure=yes", "-o",
        "ServerAliveInterval=15",   "-o",
        "ServerAliveCountMax=4",
    });
    // A forward reconnect must stay on the route its host asked for.
    const dest = appendRoute(arena, &argv, host, false) catch return error.SpawnFailed;
    try argv.appendSlice(arena, &.{ "-L", bindspec, dest });
    const t = termdrive.Term.spawn(term_state.allocator, argv.items, 120, 30, term_state.mux_sock) catch return error.SpawnFailed;
    recordAuxTerm(t, "forward");
    return t;
}

pub fn waitForwardReady(arena: std.mem.Allocator, t: *termdrive.Term, lp: u16, timeout_ms: i64) !union(enum) { ready, err: []const u8 } {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        t.drain();
        if (t.exited) {
            const tail = blk: {
                const text = t.readScreen(false) catch break :blk "";
                defer term_state.allocator.free(text);
                break :blk try arena.dupe(u8, tailLines(text, 6));
            };
            return .{ .err = try std.fmt.allocPrint(arena, "ssh exited (status {d}) before the forward came up:\n{s}", .{ t.exit_status, tail }) };
        }
        if (tcpListening(lp, 300)) return .ready;
        if (nowMs() >= deadline) {
            const tail = blk: {
                const text = t.readScreen(false) catch break :blk "";
                defer term_state.allocator.free(text);
                break :blk try arena.dupe(u8, tailLines(text, 6));
            };
            return .{ .err = try std.fmt.allocPrint(arena, "the local forward port never started listening within the timeout (auth failure? host unreachable?):\n{s}", .{tail}) };
        }
        _ = t.pumpOnce(200);
    }
}

test "term_exec result: exec facts structured, exit header + output in the text lane" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try execResult(arena, .{
        .completed = true,
        .exit_status = 1,
        .output = @constCast("EXEC-STRUCT\n"),
    }, null, null);
    const parsed = try mcp.expectToolResultShape(arena, "term_exec", out);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expect(sc.get("completed").?.bool);
    try t.expectEqual(@as(i64, 1), sc.get("exit_status").?.integer);
    try t.expect(!sc.get("pending").?.bool);
    try t.expectEqualStrings("EXEC-STRUCT\n", sc.get("output").?.string);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expectEqualStrings("exit 1\n--- output ---\nEXEC-STRUCT\n", text);
}

test "term_exec_wait result: a pending command shows tracker, screen and reason without JSON" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try execResult(arena, .{
        .completed = false,
        .pending = true,
        .tracker = "abcdef012345".*,
        .interactive_hint = true,
        .idle_ms = 900,
        .output = @constCast("Continue? [y/N] "),
    }, "Continue? [y/N] ", null);
    const parsed = try mcp.expectToolResultShape(arena, "term_exec_wait", out);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expect(sc.get("pending").?.bool);
    try t.expect(sc.get("interactive_prompt").?.bool);
    try t.expectEqualStrings("abcdef012345", sc.get("tracker").?.string);
    try t.expectEqualStrings("Continue? [y/N] ", sc.get("screen").?.string);
    try t.expectEqual(@as(i64, 900), sc.get("output_idle_ms").?.integer);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "WAITING FOR INPUT") != null);
    try t.expect(std.mem.indexOf(u8, text, "--- screen ---") != null);
    try t.expect(std.mem.indexOf(u8, text, "term_exec_wait picks up the completion") != null);
    // A pending exec is a soft failure: the outcome is a fact.
    try t.expect(parsed.object.get("isError") == null);
}

test "term_exec result: output_file writes the full output and reports it" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmpl = "/tmp/sketerm-exec-res-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    const path = try std.fmt.allocPrint(arena, "{s}/out.txt", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    const out = try execResult(arena, .{
        .completed = true,
        .exit_status = 0,
        .output = @constCast("payload"),
    }, null, path);
    const parsed = try mcp.expectToolResultShape(arena, "term_exec", out);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings(path, sc.get("output_file").?.string);
    try t.expectEqual(@as(i64, 7), sc.get("output_bytes").?.integer);

    // A relative output_file is refused in the reply, not silently dropped.
    const rel = try execResult(arena, .{
        .completed = true,
        .exit_status = 0,
        .output = @constCast("payload"),
    }, null, "relative.txt");
    const rparsed = try mcp.expectToolResultShape(arena, "term_exec", rel);
    try t.expect(rparsed.object.get("structuredContent").?.object.get("output_file") == null);
    try t.expect(std.mem.indexOf(
        u8,
        rparsed.object.get("content").?.array.items[0].object.get("text").?.string,
        "must be an absolute local path",
    ) != null);
}

test "scp_put result: transfer facts structured, one prose line" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sha = "a" ** 64;
    const up = try xferOk(arena, "upload", "/srv/app.service", 16, sha);
    const parsed = try mcp.expectToolResultShape(arena, "scp_put", up);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("upload", sc.get("direction").?.string);
    try t.expectEqualStrings("/srv/app.service", sc.get("path").?.string);
    try t.expectEqual(@as(i64, 16), sc.get("bytes").?.integer);
    try t.expectEqualStrings(sha, sc.get("sha256").?.string);
    try t.expect(sc.get("verified").?.bool);
    try t.expect(sc.get("atomic").?.bool);
    // No "ok" field survives: isError carries success now.
    try t.expect(sc.get("ok") == null);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "upload ok: /srv/app.service (16 bytes)") != null);

    // Unknown size still satisfies the schema (bytes is nullable).
    const down = try xferOk(arena, "download", "/tmp/x.bin", null, sha);
    const dparsed = try mcp.expectToolResultShape(arena, "scp_get", down);
    try t.expectEqual(std.json.Value{ .null = {} }, dparsed.object.get("structuredContent").?.object.get("bytes").?);
}

test "port_forward_list elements survive a hostile remote_host" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    // ssh listens for a -L spec it cannot resolve until a connection
    // arrives, so this forward really does register and get listed.
    try forwardElemJson(&aw.writer, 3, "box", 9000, "a\"b\nc", 22, true, 0);
    const line = aw.written();
    try t.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    try t.expectEqualStrings("a\"b\nc", parsed.object.get("remote_host").?.string);
    try t.expectEqual(@as(i64, 3), parsed.object.get("forward").?.integer);
    try t.expect(parsed.object.get("alive").?.bool);
}

test "remoteShArgv keeps a forced route off the ssh destination" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A plain host is its own destination, second-to-last in the argv.
    const plain = try remoteShArgv(arena, "box", "true\n");
    try t.expectEqualStrings("box", plain[plain.len - 2]);

    // A `tor:` alias is NOT a hostname: it must be resolved to the bare
    // host with the route's options in front of it. scp_get's checksum
    // leg used to hand ssh the literal alias, so every Tor download
    // failed to verify and kept its partial.
    const routed = try remoteShArgv(arena, "tor:box", "true\n");
    try t.expectEqualStrings("box", routed[routed.len - 2]);
    for (routed) |a| try t.expect(std.mem.indexOf(u8, a, "tor:") == null);
    var proxied = false;
    for (routed) |a| {
        if (std.mem.indexOf(u8, a, "ProxyCommand") != null) proxied = true;
    }
    try t.expect(proxied);
}

// ── session state: terminals, recordings, forwards ──────────────

/// Registry of headless SHELL sessions (term_*) on the private daemon,
/// parallel to AppState. Only used in isolated mode; in --shared mode
/// the GUI-backed terminal tools are used instead.
const TermState = struct {
    allocator: std.mem.Allocator,
    terms: std.AutoArrayHashMapUnmanaged(u32, *termdrive.Term) = .empty,
    next_id: u32 = 1,
    /// Isolated daemon socket (null = feature off; term tools then
    /// error, directing the user to the GUI-backed terminal tools).
    mux_sock: ?[]const u8 = null,

    pub fn deinit(self: *TermState) void {
        for (self.terms.values()) |t| t.deinit();
        self.terms.deinit(self.allocator);
        self.terms = .empty;
    }
};

pub var term_state: TermState = .{ .allocator = undefined };

/// Automatic asciicast recording of every headless terminal the MCP
/// server spawns (term_open, new_tab fallback, transfer/forward
/// helpers) — the terminal counterpart of the --log message trace.
/// Daemon-side recording via the rec_start wire frame, finalized with
/// each session; --no-record disables.
const RecState = struct {
    allocator: std.mem.Allocator,
    enabled: bool = true,
    /// Created lazily on the first spawn; null until then (and stays
    /// null when creation fails — recording then silently stays off,
    /// never blocking terminal work).
    dir: ?[]u8 = null,
    aux_counter: u32 = 0,
    /// term id → cast path, for term_list / term_open replies.
    casts: std.AutoArrayHashMapUnmanaged(u32, []u8) = .empty,

    pub fn deinit(self: *RecState) void {
        for (self.casts.values()) |p| self.allocator.free(p);
        self.casts.deinit(self.allocator);
        self.casts = .empty;
        if (self.dir) |d| self.allocator.free(d);
        self.dir = null;
    }
};

pub var rec_state: RecState = .{ .allocator = undefined };

/// The recordings directory, created on first use: the --log session
/// folder when logging is on (casts sit next to the message trace),
/// else $XDG_STATE_HOME/sketerm/mcp-casts/<stamp>-<pid>/.
pub fn recDir() ?[]const u8 {
    if (!rec_state.enabled) return null;
    if (rec_state.dir) |d| return d;
    const a = rec_state.allocator;
    if (mcp.mcp_log) |l| {
        rec_state.dir = a.dupe(u8, l.dir) catch return null;
        return rec_state.dir;
    }
    var base_buf: [4096]u8 = undefined;
    const state_base: []const u8 = if (c.getenv("XDG_STATE_HOME")) |sh|
        std.mem.span(@as([*:0]const u8, @ptrCast(sh)))
    else if (c.getenv("HOME")) |home|
        std.fmt.bufPrint(&base_buf, "{s}/.local/state", .{std.mem.span(@as([*:0]const u8, @ptrCast(home)))}) catch return null
    else
        return null;
    var stamp_buf: [40]u8 = undefined;
    const stamp = McpLog.stamp(&stamp_buf);
    const dir = std.fmt.allocPrint(a, "{s}/sketerm/mcp-casts/{s}-{d}", .{ state_base, stamp, c.getpid() }) catch return null;
    // mkdir -p, leaf included: this call replaced mcp_browser.mkdirs
    // when the CDP set was deleted — without it recording is silently
    // off on any fresh state dir.
    var probe: [4096]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&probe, "{s}", .{dir}) catch {
        a.free(dir);
        return null;
    };
    var i: usize = 1;
    while (i <= dir_z.len) : (i += 1) {
        if (i != dir_z.len and probe[i] != '/') continue;
        const save = probe[i];
        probe[i] = 0;
        _ = c.mkdir(&probe, 0o700);
        probe[i] = save;
    }
    if (c.access(dir_z.ptr, c.W_OK) != 0) {
        a.free(dir);
        return null;
    }
    rec_state.dir = dir;
    return rec_state.dir;
}

/// Start recording a REGISTERED terminal; returns the cast path (kept
/// in rec_state for term_list) or null when recording is off.
pub fn recordRegisteredTerm(t: *termdrive.Term, term_id: u32) ?[]const u8 {
    const dir = recDir() orelse return null;
    const a = rec_state.allocator;
    const path = std.fmt.allocPrint(a, "{s}/term-{d}.cast", .{ dir, term_id }) catch return null;
    t.startRecording(path);
    rec_state.casts.put(a, term_id, path) catch {
        a.free(path);
        return null;
    };
    return rec_state.casts.get(term_id);
}

/// Point a registered terminal's recording at `path`: the daemon
/// replaces its current recording (the automatic one included), so the
/// listing reports the file actually being written.
pub fn recordTermAt(t: *termdrive.Term, term_id: u32, path: []const u8) !void {
    const a = rec_state.allocator;
    const owned = try a.dupe(u8, path);
    errdefer a.free(owned);
    t.startRecording(path);
    if (try rec_state.casts.fetchPut(a, term_id, owned)) |old| a.free(old.value);
}

/// Stop a registered terminal's recording; the listing stops naming it.
pub fn stopTermRecording(t: *termdrive.Term, term_id: u32) void {
    t.stopRecording();
    if (rec_state.casts.fetchSwapRemove(term_id)) |kv| rec_state.allocator.free(kv.value);
}

/// Record an UNREGISTERED helper terminal (scp/ssh/forward).
pub fn recordAuxTerm(t: *termdrive.Term, label: []const u8) void {
    const dir = recDir() orelse return;
    const a = rec_state.allocator;
    rec_state.aux_counter += 1;
    const path = std.fmt.allocPrint(a, "{s}/aux-{d}-{s}.cast", .{ dir, rec_state.aux_counter, label }) catch return;
    defer a.free(path);
    t.startRecording(path);
}

/// One structured SSH port forward: an owned `ssh -N -L` headless
/// terminal plus its spec, so it can be health-checked and respawned.
pub const Forward = struct {
    id: u32,
    host: []u8,
    local_port: u16,
    remote_host: []u8,
    remote_port: u16,
    term: *termdrive.Term,
    reconnects: u32 = 0,
};

const ForwardState = struct {
    allocator: std.mem.Allocator,
    forwards: std.AutoArrayHashMapUnmanaged(u32, *Forward) = .empty,
    next_id: u32 = 1,

    pub fn removeOne(self: *ForwardState, f: *Forward) void {
        _ = self.forwards.swapRemove(f.id);
        f.term.deinit();
        self.allocator.free(f.host);
        self.allocator.free(f.remote_host);
        self.allocator.destroy(f);
    }

    pub fn deinit(self: *ForwardState) void {
        for (self.forwards.values()) |f| {
            f.term.deinit();
            self.allocator.free(f.host);
            self.allocator.free(f.remote_host);
            self.allocator.destroy(f);
        }
        self.forwards.deinit(self.allocator);
        self.forwards = .empty;
    }
};

pub var forward_state: ForwardState = .{ .allocator = undefined };

pub fn forwardFromArgs(args: std.json.Value) ?*Forward {
    if (argInt(args, "forward")) |id| {
        if (id < 0) return null;
        return forward_state.forwards.get(@intCast(id));
    }
    if (forward_state.forwards.count() == 1) return forward_state.forwards.values()[0];
    return null;
}

/// The headless terminal `args` addresses under `key` ("term", or "pane"
/// when a pane tool runs without a GUI), or the only one open.
pub fn termFromArgs(args: std.json.Value, key: []const u8) ?*termdrive.Term {
    if (argInt(args, key)) |id| {
        if (id < 0) return null;
        return term_state.terms.get(@intCast(id));
    }
    if (term_state.terms.count() == 1) return term_state.terms.values()[0];
    return null;
}

pub fn termIdOf(t: *termdrive.Term) u32 {
    var it = term_state.terms.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == t) return e.key_ptr.*;
    }
    return 0;
}

pub fn commandCompletionResult(
    arena: std.mem.Allocator,
    result: termdrive.CommandCompletion,
    command_sent: bool,
    output: ?[]const u8,
    output_kind: ?[]const u8,
    reason: ?[]const u8,
) ![]const u8 {
    var r = Res.init(arena);
    try r.fact("state", @tagName(result.state));
    try r.fact("command_sent", command_sent);
    try r.fact("exit_status", result.exit_status);
    try r.fact("timed_out", result.timed_out);
    try r.fact("completion_source", @tagName(result.source));
    // A soft failure (running/unsupported/timed out) is a FACT here,
    // not a tool error: isError stays false and the text lane says so.
    if (result.exit_status) |status| {
        try r.textf("{s}: exit {d} ({s})", .{ @tagName(result.state), status, @tagName(result.source) });
    } else {
        try r.textf("{s}{s} ({s})", .{
            @tagName(result.state),
            if (result.timed_out) ", timed out" else "",
            @tagName(result.source),
        });
    }
    if (!command_sent) try r.text("the command was NOT sent");
    if (reason) |text| {
        try r.fact("reason", text);
        try r.text(text);
    }
    if (output_kind) |kind| try r.fact("output_kind", kind);
    if (output) |text| {
        try r.fact("output", text);
        try r.textf("--- {s} ---", .{output_kind orelse "output"});
        try r.text(text);
    }
    return r.finish();
}

test "stagedPartPath preserves the extension" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings("/etc/systemd/system/hohenheim.sketerm-part.service", try @import("mcp_term.zig").stagedPartPath(arena, "/etc/systemd/system/hohenheim.service"));
    // Last-suffix preservation (what suffix-sensitive validators need).
    try t.expectEqualStrings("/srv/app.tar.sketerm-part.gz", try @import("mcp_term.zig").stagedPartPath(arena, "/srv/app.tar.gz"));
    try t.expectEqualStrings("/usr/local/bin/hohenheim.sketerm-part", try @import("mcp_term.zig").stagedPartPath(arena, "/usr/local/bin/hohenheim"));
    // Dotfiles and trailing dots don't split.
    try t.expectEqualStrings("/home/x/.bashrc.sketerm-part", try @import("mcp_term.zig").stagedPartPath(arena, "/home/x/.bashrc"));
    try t.expectEqualStrings("/tmp/weird..sketerm-part", try @import("mcp_term.zig").stagedPartPath(arena, "/tmp/weird."));
}

test "findHex64 finds standalone sha tokens" {
    const t = std.testing;
    const sha = "a" ** 64;
    try t.expectEqualStrings(sha, @import("mcp_term.zig").findHex64("prefix " ++ sha ++ "  /path/file").?);
    try t.expect(@import("mcp_term.zig").findHex64("short deadbeef only") == null);
    // 65 hex chars: not a standalone 64-run.
    try t.expect(@import("mcp_term.zig").findHex64("f" ** 65) == null);
}

test "pickFreePort and tcpListening agree" {
    const t = std.testing;
    const port = @import("mcp_term.zig").pickFreePort() orelse return error.SkipZigTest;
    try t.expect(port > 0);
    // Nothing listens there after the probe socket closed.
    try t.expect(!@import("mcp_term.zig").tcpListening(port, 200));
}

test "localCopyAtomic copies, verifies and renames" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sbuf: [128]u8 = undefined;
    var dbuf: [128]u8 = undefined;
    const src = try std.fmt.bufPrintZ(&sbuf, "/tmp/sketerm-xfer-src-{d}", .{c.getpid()});
    const dst = try std.fmt.bufPrintZ(&dbuf, "/tmp/sketerm-xfer-dst-{d}", .{c.getpid()});
    const f = c.fopen(src.ptr, "wb") orelse return error.SkipZigTest;
    _ = c.fwrite("hello transfer", 1, 14, f);
    _ = c.fclose(f);
    defer _ = c.unlink(src.ptr);
    defer _ = c.unlink(dst.ptr);
    const r = try @import("mcp_term.zig").localCopyAtomic(arena, src, dst);
    try t.expect(r == .ok);
    try t.expectEqual(@as(u64, 14), r.ok.bytes);
    try t.expectEqual(@as(?u64, 14), @import("mcp_term.zig").fileSize(dst));
    const src_sha = @import("mcp_term.zig").sha256File(src).?;
    try t.expectEqualStrings(&src_sha, &r.ok.sha);
    // Missing source is a described error, not a crash.
    const bad = try @import("mcp_term.zig").localCopyAtomic(arena, "/nonexistent/nope", dst);
    try t.expect(bad == .err);
}

test "commandCompletionResult: facts in structuredContent, compact prose in the text lane" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const done = try commandCompletionResult(
        arena,
        .{ .state = .completed, .exit_status = 0, .source = .shell_integration },
        true,
        "hello world",
        "command",
        null,
    );
    const parsed = try expectToolResultShape(arena, "term_wait_command", done);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqualStrings("completed", sc.get("state").?.string);
    try t.expect(sc.get("command_sent").?.bool);
    try t.expectEqual(@as(i64, 0), sc.get("exit_status").?.integer);
    try t.expect(!sc.get("timed_out").?.bool);
    try t.expectEqualStrings("shell_integration", sc.get("completion_source").?.string);
    try t.expectEqualStrings("hello world", sc.get("output").?.string);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expectEqualStrings("completed: exit 0 (shell_integration)\n--- command ---\nhello world", text);
    // Soft outcomes are facts, never tool errors.
    try t.expect(parsed.object.get("isError") == null);
}

test "commandCompletionResult: a refused send stays a soft failure" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refused = try commandCompletionResult(
        arena,
        .{ .state = .unsupported },
        false,
        null,
        null,
        "shell integration is unavailable for this shell",
    );
    const parsed = try expectToolResultShape(arena, "term_wait_command", refused);
    const obj = parsed.object;
    try t.expect(obj.get("isError") == null);
    const sc = obj.get("structuredContent").?.object;
    try t.expectEqualStrings("unsupported", sc.get("state").?.string);
    try t.expect(!sc.get("command_sent").?.bool);
    try t.expectEqual(std.json.Value{ .null = {} }, sc.get("exit_status").?);
    const text = obj.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "the command was NOT sent") != null);
    try t.expect(std.mem.indexOf(u8, text, "shell integration is unavailable") != null);

    // A timed-out still-running command: also isError:false.
    const running = try commandCompletionResult(
        arena,
        .{ .state = .running, .timed_out = true },
        true,
        "partial output",
        "screen",
        "timeout expired while the command was still running",
    );
    const rparsed = try expectToolResultShape(arena, "term_run", running);
    try t.expect(rparsed.object.get("isError") == null);
    try t.expect(rparsed.object.get("structuredContent").?.object.get("timed_out").?.bool);
}
