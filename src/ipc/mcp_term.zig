//! MCP headless-terminal tools (term_*), file transfers and port
//! forwards — split out of mcp.zig. Shared server state stays in
//! mcp.zig and is referenced through it.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const termdrive = @import("termdrive.zig");
const mcp = @import("mcp.zig");
const termIdOf = mcp.termIdOf;
const commandCompletionResult = mcp.commandCompletionResult;
const argBool = mcp.argBool;
const forwardFromArgs = mcp.forwardFromArgs;
const Forward = mcp.Forward;
const termFromArgs = mcp.termFromArgs;
const argInt = mcp.argInt;
const argStr = mcp.argStr;
const appErr = mcp.appErr;
const recordAuxTerm = mcp.recordAuxTerm;
const recordRegisteredTerm = mcp.recordRegisteredTerm;
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
    const t = termdrive.Term.spawnRemoteMux(mcp.term_state.allocator, host, argv, cols, rows) catch
        return error.SpawnFailed;
    const id = mcp.term_state.next_id;
    mcp.term_state.next_id += 1;
    mcp.term_state.terms.put(mcp.term_state.allocator, id, t) catch {
        t.deinit();
        return error.OutOfMemory;
    };
    return id;
}

/// Spawn + register a headless terminal; returns its id.
pub fn spawnRegisteredTerm(argv: ?[]const []const u8, cols: u16, rows: u16) !u32 {
    const t = termdrive.Term.spawn(mcp.term_state.allocator, argv, cols, rows, mcp.term_state.mux_sock) catch
        return error.SpawnFailed;
    const id = mcp.term_state.next_id;
    mcp.term_state.next_id += 1;
    mcp.term_state.terms.put(mcp.term_state.allocator, id, t) catch {
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
    defer mcp.term_state.allocator.free(text);
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
            defer mcp.term_state.allocator.free(screen_text);
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

pub fn termTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (mcp.term_state.mux_sock == null)
        return mcp.errRes(arena, .unavailable, "headless terminal tools need isolated mode; in --shared mode use the GUI-backed terminal tools (list_terminals, run_command, ...)");

    if (eql(u8, name, "term_open")) {
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
        const t = mcp.term_state.terms.get(id).?;
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
        const rec_note = if (mcp.rec_state.casts.get(id)) |p|
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
        if (mcp.rec_state.casts.get(id)) |p| try res.fact("recording", p);
        try res.textf("opened headless terminal {d} ({d}x{d}{s}){s}{s}", .{ id, cols, rows, shell_note, where, rec_note });
        return res.finish();
    }
    if (eql(u8, name, "term_list")) {
        var res = mcp.Res.init(arena);
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        var first = true;
        var count: usize = 0;
        var it = mcp.term_state.terms.iterator();
        while (it.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
            count += 1;
            const t = e.value_ptr.*;
            t.drain();
            _ = t.scanShellAnnounce();
            try w.print("{{\"term\":{d},\"exited\":{}", .{ e.key_ptr.*, t.exited });
            if (t.shell_name) |sn| {
                try w.writeAll(",\"shell\":");
                try std.json.Stringify.value(sn, .{}, w);
                try w.print(",\"integration\":{}", .{t.integration});
            }
            if (t.remote_host) |rh| {
                try w.writeAll(",\"transport\":\"sketerm-mux\",\"host\":");
                try std.json.Stringify.value(rh, .{}, w);
            }
            if (t.exited and t.exit_status_known) try w.print(",\"exit_status\":{d}", .{t.exit_status});
            if (t.hasPendingCommand()) try w.writeAll(",\"pending_command\":true");
            if (t.hasPendingExec()) try w.writeAll(",\"pending_exec\":true");
            const last = termLastLine(arena, t);
            if (last.len > 0) {
                try w.writeAll(",\"last_line\":");
                try std.json.Stringify.value(last, .{}, w);
            }
            if (mcp.rec_state.casts.get(e.key_ptr.*)) |p| {
                try w.writeAll(",\"recording\":");
                try std.json.Stringify.value(p, .{}, w);
            }
            try w.writeAll("}");

            // One compact human line per terminal, same facts, no JSON.
            try res.textf("term {d}: {s}", .{ e.key_ptr.*, if (t.exited) "exited" else "running" });
            if (t.exited and t.exit_status_known) try res.textf("  exit_status: {d}", .{t.exit_status});
            if (t.shell_name) |sn|
                try res.textf("  shell: {s}, integration: {}", .{ sn, t.integration });
            if (t.remote_host) |rh| try res.textf("  host: {s} (sketerm-mux)", .{rh});
            if (t.hasPendingCommand()) try res.text("  pending_command: true");
            if (t.hasPendingExec()) try res.text("  pending_exec: true");
            if (last.len > 0) try res.textf("  last line: {s}", .{last});
            if (mcp.rec_state.casts.get(e.key_ptr.*)) |p| try res.textf("  recording: {s}", .{p});
        }
        try w.writeAll("]");
        try res.raw("terms", aw.written());
        try res.fact("count", count);
        if (count == 0) try res.text("no headless terminals are open");
        return res.finish();
    }

    const t = termFromArgs(args) orelse
        return mcp.errRes(arena, .not_found, "no such terminal (pass 'term' id, or omit it when only one is open)");
    const term_id = termIdOf(t);

    if (eql(u8, name, "term_send_text")) {
        const text = argStr(args, "text") orelse return mcp.errRes(arena, .invalid_args, "term_send_text requires 'text'");
        const enter = argBool(args, "enter");
        const data = if (enter)
            try std.fmt.allocPrint(arena, "{s}\r", .{text})
        else
            text;
        t.sendText(data) catch return mcp.errRes(arena, .conflict, "send failed (terminal exited?)");
        var res = mcp.Res.init(arena);
        try res.fact("term", term_id);
        try res.fact("bytes", data.len);
        try res.fact("enter", enter);
        try res.textf("sent {d} bytes to terminal {d}{s}", .{ data.len, term_id, if (enter) " (enter pressed)" else "" });
        return res.finish();
    }
    if (eql(u8, name, "term_send_keys")) {
        const keychords = argStr(args, "keys") orelse return mcp.errRes(arena, .invalid_args, "term_send_keys requires 'keys'");
        t.sendKeys(keychords) catch |err| return switch (err) {
            termdrive.Error.BadKey => mcp.errRes(arena, .invalid_args, "unknown key chord"),
            else => mcp.errRes(arena, .conflict, "send failed (terminal exited?)"),
        };
        var res = mcp.Res.init(arena);
        try res.fact("term", term_id);
        try res.fact("keys", keychords);
        try res.textf("sent keys {s} to terminal {d}", .{ keychords, term_id });
        return res.finish();
    }
    if (eql(u8, name, "term_read")) {
        t.drain();
        const sb = argBool(args, "scrollback");
        const text = t.readScreen(sb) catch |err| return switch (err) {
            termdrive.Error.Desynced => mcp.errRes(arena, .conflict, "this terminal's mirror lost sync with the session and could not be rebuilt; its content is stale. Close it (term_close) and open a new one"),
            else => mcp.errRes(arena, .conflict, "read failed (terminal exited?)"),
        };
        defer mcp.term_state.allocator.free(text);
        var res = mcp.Res.init(arena);
        try res.fact("term", term_id);
        try res.fact("exited", t.exited);
        try res.fact("scrollback", sb);
        try res.fact("screen", text);
        if (t.exited) {
            // Make an exited terminal's state unambiguous: the final
            // rendered frame plus the real exit status, so a stale
            // progress line (scp "1%") cannot be mistaken for truth.
            if (t.exit_status_known) {
                try res.fact("exit_status", t.exit_status);
                try res.textf("[process exited with status {d} - final rendered screen below]", .{t.exit_status});
            } else {
                try res.text("[process exited (status unknown) - final rendered screen below]");
            }
        }
        try res.text(text);
        return res.finish();
    }
    if (eql(u8, name, "term_exec")) {
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
            if (t.waitExecResult(0)) |r0| mcp.term_state.allocator.free(r0.output);
            if (t.hasPendingExec())
                return mcp.errRes(arena, .conflict, "a previous term_exec is still running in this terminal; continue it with term_exec_wait (or interrupt with term_send_keys ctrl+c)");
        }
        if (t.hasPendingCommand())
            return mcp.errRes(arena, .conflict, "a term_run wait_for=command command is still tracked; resolve it with term_wait_command first");
        const r = t.execCommand(cmd, subshell, noninteractive, shell, timeout_ms) catch |err| return switch (err) {
            termdrive.Error.NotConnected => mcp.errRes(arena, .conflict, "terminal exited"),
            else => appErr(arena, "exec failed"),
        };
        defer mcp.term_state.allocator.free(r.output);
        return execResultJson(arena, r, t, argStr(args, "output_file"));
    }
    if (eql(u8, name, "term_exec_wait")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const r = t.waitExecResult(timeout_ms) orelse
            return mcp.errRes(arena, .not_found, "no pending term_exec in this terminal");
        defer mcp.term_state.allocator.free(r.output);
        return execResultJson(arena, r, t, argStr(args, "output_file"));
    }
    if (eql(u8, name, "term_wait_exit")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const exited = t.waitExit(timeout_ms);
        const tail = blk: {
            const text = t.readScreen(false) catch break :blk "";
            defer mcp.term_state.allocator.free(text);
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
    if (eql(u8, name, "term_run")) {
        const cmd = argStr(args, "command") orelse return mcp.errRes(arena, .invalid_args, "term_run requires 'command'");
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const wait_for = argStr(args, "wait_for") orelse "idle";
        if (!eql(u8, wait_for, "idle") and !eql(u8, wait_for, "command"))
            return mcp.errRes(arena, .invalid_args, "wait_for must be 'idle' or 'command'");
        if (eql(u8, wait_for, "command")) {
            // A tracked command may have completed since its timeout:
            // one short drain clears it so the new send is accepted.
            if (t.hasPendingCommand()) _ = t.waitPendingCommand(0);
            if (t.hasPendingCommand()) {
                return commandCompletionResult(arena, .{ .state = .running }, false, null, null, "a previously timed-out command is still running; use term_wait_command instead of resending");
            }
            // The token wait spends from the same budget as the
            // completion wait, so the call never outlives timeout_ms.
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

            var owned_output: ?[]u8 = null;
            defer if (owned_output) |text| mcp.term_state.allocator.free(text);
            var output_kind: []const u8 = "screen";
            if (result.state == .completed and result.source == .shell_integration and argBool(args, "output_only")) {
                if (t.lastCommand() catch null) |lc| {
                    owned_output = lc.text;
                    output_kind = "command";
                }
            }
            if (owned_output == null) {
                owned_output = t.readScreen(false) catch null;
            }
            return commandCompletionResult(arena, result, true, owned_output, output_kind, switch (result.state) {
                .running => "timeout expired while the command was still running; output may have been idle",
                .unknown => "terminal disconnected before a reliable completion status was received",
                .unsupported => unreachable,
                .completed => null,
            });
        }
        // Idle mode must not run a NEW command while a command-mode
        // token is unresolved: the interloper's OSC 133 D would be
        // reported by term_wait_command as the tracked command's exit.
        if (t.hasPendingCommand()) _ = t.waitPendingCommand(0);
        if (t.hasPendingCommand())
            return mcp.errRes(arena, .conflict, "a command-mode command is still being tracked; resolve it with term_wait_command before running another command, or its exit status would be misattributed");
        // Honesty over silent queueing: when integration shows an
        // open command zone, the typed line goes to the RUNNING
        // program's stdin (or sits queued by the shell), not to a new
        // shell command — say so instead of letting a quiet screen
        // read as "executed".
        const busy_before = t.integration and t.foregroundRunning();
        const line = try std.fmt.allocPrint(arena, "{s}\r", .{cmd});
        t.sendText(line) catch return mcp.errRes(arena, .conflict, "send failed (terminal exited?)");
        const settled = t.waitIdle(quiet_ms, timeout_ms);
        var res = mcp.Res.init(arena);
        try res.fact("term", term_id);
        try res.fact("wait_for", "idle");
        try res.fact("command_sent", true);
        try res.fact("settled", settled);
        try res.fact("went_to_foreground_stdin", busy_before);
        var note: []const u8 = if (settled) "" else "\n[note: output still flowing at timeout]";
        if (busy_before)
            note = try std.fmt.allocPrint(arena, "{s}\n[note: a foreground command was already running when this text was sent — it went to that program's stdin, or the shell queued it as pending input; it did NOT start as a new shell command. Wait with term_wait_idle, or interrupt with term_send_keys ctrl+c]", .{note});
        const want_output_only = argBool(args, "output_only");
        if (want_output_only) {
            // OSC 133 zone: output + exit code only. Screen-scrape
            // fallback when no zone completed — announced below,
            // never a silent shape change.
            if (t.lastCommand() catch null) |lc| {
                defer mcp.term_state.allocator.free(lc.text);
                try res.fact("output_kind", "command");
                try res.fact("exit_status", lc.exit);
                try res.fact("output", lc.text);
                try res.textf("exit: {d}", .{lc.exit});
                try res.text("---");
                try res.textf("{s}{s}", .{ lc.text, note });
                return res.finish();
            }
        }
        const text = t.readScreen(false) catch return appErr(arena, "read failed");
        defer mcp.term_state.allocator.free(text);
        try res.fact("output_kind", "screen");
        try res.fact("output", text);
        if (want_output_only) {
            try res.fact("output_only_unavailable", true);
            try res.text("[output_only unavailable: no completed OSC 133 command zone — shell integration is inactive in this terminal (unsupported shell, or the command emitted no marks); returning the rendered screen]");
        }
        try res.textf("{s}{s}", .{ text, note });
        return res.finish();
    }
    if (eql(u8, name, "term_wait_command")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const result = t.waitPendingCommand(timeout_ms) orelse
            return mcp.errRes(arena, .not_found, "no timed-out command is being tracked");
        var owned_output: ?[]u8 = null;
        defer if (owned_output) |text| mcp.term_state.allocator.free(text);
        var output_kind: []const u8 = "screen";
        if (result.state == .completed and result.source == .shell_integration and argBool(args, "output_only")) {
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
    if (eql(u8, name, "term_wait_idle")) {
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 500;
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const settled = t.waitIdle(quiet_ms, timeout_ms);
        // Prompt-aware verdict when integration can tell: "quiet
        // because sleeping" must not masquerade as "done".
        const desynced = !settled and t.isDesynced();
        const foreground = settled and t.integration and t.foregroundRunning();
        const msg = if (desynced)
            "NOT idle: this terminal's mirror lost sync with the session and could not be rebuilt, so quiescence cannot be observed. Close it (term_close) and open a new one"
        else if (!settled)
            "still active at timeout"
        else if (foreground)
            "idle, but a foreground command is still RUNNING (output is quiet, not finished)"
        else if (t.integration)
            "idle at shell prompt"
        else
            "idle";
        var res = mcp.Res.init(arena);
        try res.fact("term", term_id);
        try res.fact("idle", settled);
        try res.fact("timed_out", !settled);
        try res.fact("desynced", desynced);
        try res.fact("foreground_running", foreground);
        try res.text(msg);
        return res.finish();
    }
    if (eql(u8, name, "term_resize")) {
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
    if (eql(u8, name, "term_close")) {
        const id = termIdOf(t);
        _ = mcp.term_state.terms.swapRemove(id);
        t.deinit();
        // The daemon finalizes the cast with the session; keep the
        // path out of future term_list output.
        if (mcp.rec_state.casts.fetchSwapRemove(id)) |kv| mcp.rec_state.allocator.free(kv.value);
        var res = mcp.Res.init(arena);
        try res.fact("term", id);
        try res.fact("closed", true);
        try res.textf("terminal {d} closed", .{id});
        return res.finish();
    }
    return mcp.errRes(arena, .unknown_tool, "unknown tool");
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
    const t = termdrive.Term.spawn(mcp.term_state.allocator, argv, 120, 30, mcp.term_state.mux_sock) catch
        return .{ .err = "spawn failed (mux daemon unreachable?)" };
    defer t.deinit();
    recordAuxTerm(t, std.fs.path.basename(argv[0]));
    const exited = t.waitExit(timeout_ms);
    const output = blk: {
        const text = t.readScreen(true) catch break :blk "";
        defer mcp.term_state.allocator.free(text);
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

pub fn xferTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (mcp.term_state.mux_sock == null)
        return mcp.errRes(arena, .unavailable, "file transfer / port forward tools need isolated mode (they run over private headless terminals)");

    if (eql(u8, name, "upload_file") or eql(u8, name, "download_file")) {
        const upload = eql(u8, name, "upload_file");
        const local = argStr(args, "local_path") orelse return mcp.errRes(arena, .invalid_args, "requires 'local_path'");
        const remote = argStr(args, "remote_path") orelse return mcp.errRes(arena, .invalid_args, "requires 'remote_path'");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 120_000;
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
            var move_argv: std.ArrayList([]const u8) = .empty;
            defer move_argv.deinit(arena);
            try move_argv.appendSlice(arena, &.{ "ssh", "-o", "BatchMode=yes" });
            const move_dest = appendRoute(arena, &move_argv, h, false) catch
                return mcp.errRes(arena, .refused, "cannot build the forced route for this host");
            try move_argv.appendSlice(arena, &.{ move_dest, try remoteShLine(arena, script) });
            switch (try runArgvTerm(arena, move_argv.items, 60_000)) {
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
        switch (try runArgvTerm(arena, &.{ "ssh", "-o", "BatchMode=yes", h, try remoteShLine(arena, script) }, 30_000)) {
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

    if (eql(u8, name, "port_forward_open")) {
        const h = argStr(args, "host") orelse return mcp.errRes(arena, .invalid_args, "port_forward_open requires 'host'");
        const rp_i = argInt(args, "remote_port") orelse return mcp.errRes(arena, .invalid_args, "port_forward_open requires 'remote_port'");
        if (rp_i < 1 or rp_i > 65535) return mcp.errRes(arena, .invalid_args, "remote_port out of range");
        const rp: u16 = @intCast(rp_i);
        const rh = argStr(args, "remote_host") orelse "127.0.0.1";
        const lp: u16 = if (argInt(args, "local_port")) |v| blk: {
            if (v < 1 or v > 65535) return mcp.errRes(arena, .invalid_args, "local_port out of range");
            break :blk @intCast(v);
        } else pickFreePort() orelse return mcp.errRes(arena, .unavailable, "could not pick a free local port");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 20_000;

        const t = spawnForwardTerm(arena, h, lp, rh, rp) catch
            return mcp.errRes(arena, .unavailable, "spawn failed (mux daemon unreachable?)");
        switch (try waitForwardReady(arena, t, lp, timeout_ms)) {
            .ready => {},
            .err => |e| {
                t.deinit();
                return mcp.errRes(arena, .unavailable, e);
            },
        }
        const a = mcp.forward_state.allocator;
        const f = a.create(Forward) catch {
            t.deinit();
            return error.OutOfMemory;
        };
        f.* = .{
            .id = mcp.forward_state.next_id,
            .host = a.dupe(u8, h) catch return error.OutOfMemory,
            .local_port = lp,
            .remote_host = a.dupe(u8, rh) catch return error.OutOfMemory,
            .remote_port = rp,
            .term = t,
        };
        mcp.forward_state.next_id += 1;
        mcp.forward_state.forwards.put(a, f.id, f) catch {
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
    if (eql(u8, name, "port_forward_list")) {
        var res = mcp.Res.init(arena);
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        for (mcp.forward_state.forwards.values(), 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            f.term.drain();
            try w.print("{{\"forward\":{d},\"host\":\"{s}\",\"local_port\":{d},\"remote_host\":\"{s}\",\"remote_port\":{d},\"alive\":{},\"reconnects\":{d}}}", .{ f.id, f.host, f.local_port, f.remote_host, f.remote_port, !f.term.exited, f.reconnects });
            try res.textf("forward {d}: 127.0.0.1:{d} -> {s} ({s}:{d}), alive: {}, reconnects: {d}", .{ f.id, f.local_port, f.host, f.remote_host, f.remote_port, !f.term.exited, f.reconnects });
        }
        try w.writeAll("]");
        try res.raw("forwards", aw.written());
        try res.fact("count", mcp.forward_state.forwards.count());
        if (mcp.forward_state.forwards.count() == 0) try res.text("no port forwards are open");
        return res.finish();
    }

    const f = forwardFromArgs(args) orelse
        return mcp.errRes(arena, .not_found, "no such forward (pass 'forward' from port_forward_open, or omit it when only one is open)");

    if (eql(u8, name, "port_forward_check")) {
        f.term.drain();
        var reconnected = false;
        if (f.term.exited) {
            // The ssh process died (network blip, sshd restart):
            // respawn the same spec — this IS the reconnect behavior.
            const nt = spawnForwardTerm(arena, f.host, f.local_port, f.remote_host, f.remote_port) catch
                return mcp.errRes(arena, .unavailable, "forward is dead and respawn failed (mux daemon unreachable?)");
            switch (try waitForwardReady(arena, nt, f.local_port, argInt(args, "timeout_ms") orelse 20_000)) {
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
    if (eql(u8, name, "port_forward_close")) {
        const closed_id = f.id;
        mcp.forward_state.removeOne(f);
        var res = mcp.Res.init(arena);
        try res.fact("forward", closed_id);
        try res.fact("closed", true);
        try res.textf("forward {d} closed", .{closed_id});
        return res.finish();
    }
    return mcp.errRes(arena, .unknown_tool, "unknown tool");
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
    const t = termdrive.Term.spawn(mcp.term_state.allocator, argv.items, 120, 30, mcp.term_state.mux_sock) catch return error.SpawnFailed;
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
                defer mcp.term_state.allocator.free(text);
                break :blk try arena.dupe(u8, tailLines(text, 6));
            };
            return .{ .err = try std.fmt.allocPrint(arena, "ssh exited (status {d}) before the forward came up:\n{s}", .{ t.exit_status, tail }) };
        }
        if (tcpListening(lp, 300)) return .ready;
        if (nowMs() >= deadline) {
            const tail = blk: {
                const text = t.readScreen(false) catch break :blk "";
                defer mcp.term_state.allocator.free(text);
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

test "upload_file result: transfer facts structured, one prose line" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sha = "a" ** 64;
    const up = try xferOk(arena, "upload", "/srv/app.service", 16, sha);
    const parsed = try mcp.expectToolResultShape(arena, "upload_file", up);
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
    const dparsed = try mcp.expectToolResultShape(arena, "download_file", down);
    try t.expectEqual(std.json.Value{ .null = {} }, dparsed.object.get("structuredContent").?.object.get("bytes").?);
}

test "every tool this module serves declares an output schema" {
    // The dispatcher routes term_*, upload/download and port_forward_*
    // here; wave 3a gave all of them structured results, so a new tool
    // added to this module without a schema fails here rather than
    // silently shipping a text-only result.
    const mcp_tools = @import("mcp_tools.zig");
    for (mcp_tools.TOOLS) |tool| {
        const mine = std.mem.startsWith(u8, tool.name, "term_") or
            std.mem.startsWith(u8, tool.name, "port_forward_") or
            std.mem.eql(u8, tool.name, "upload_file") or
            std.mem.eql(u8, tool.name, "download_file");
        if (!mine) continue;
        if (tool.output_schema == null) {
            std.debug.print("{s} has no output schema\n", .{tool.name});
            return error.MissingOutputSchema;
        }
    }
}
