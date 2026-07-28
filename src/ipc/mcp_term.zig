//! MCP headless-terminal tools (term_*), file transfers and port
//! forwards — split out of mcp.zig. Shared server state stays in
//! mcp.zig and is referenced through it.

const std = @import("std");
const c = @import("../c.zig").c;
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
const monoMs = mcp.monoMs;
const shellquote = mcp.shellquote;
const toolResult = mcp.toolResult;

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
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{{\"completed\":{},\"exit_status\":", .{r.completed});
    if (r.exit_status) |st| try w.print("{d}", .{st}) else try w.writeAll("null");
    try w.print(",\"timed_out\":{},\"truncated\":{},\"shell_died\":{}", .{ r.timed_out, r.truncated, r.shell_died });
    if (r.pending) {
        try w.writeAll(",\"pending\":true");
        if (r.tracker) |nonce| try w.print(",\"tracker\":\"{s}\"", .{nonce});
        try w.print(",\"alt_screen\":{},\"output_idle_ms\":{d},\"interactive_prompt\":{}", .{ r.alt_screen, r.idle_ms, r.interactive_hint });
        // The live rendered screen: an interactive dialog (apt's
        // needrestart, a password ask) must be VISIBLE in the reply,
        // never hidden behind a bare timeout.
        if (t.readScreen(false)) |screen_text| {
            defer mcp.term_state.allocator.free(screen_text);
            try w.writeAll(",\"screen\":");
            try std.json.Stringify.value(tailLines(screen_text, 20), .{}, w);
        } else |_| {}
    }
    var file_note: ?[]const u8 = null;
    var inline_out: []const u8 = r.output;
    var inline_cap: usize = 200_000;
    if (output_file) |path| {
        if (path.len == 0 or path[0] != '/') {
            file_note = "output_file must be an absolute local path — ignored, full output inline";
        } else if (writeFileBytes(path, r.output)) {
            try w.writeAll(",\"output_file\":");
            try std.json.Stringify.value(path, .{}, w);
            try w.print(",\"output_bytes\":{d}", .{r.output.len});
            inline_cap = 2_000;
        } else {
            file_note = "output_file could not be written (dir missing / not writable?) — full output inline";
        }
    }
    if (inline_out.len > inline_cap) {
        try w.print(",\"output_dropped_chars\":{d}", .{inline_out.len - inline_cap});
        inline_out = inline_out[inline_out.len - inline_cap ..];
    }
    try w.writeAll(",\"output\":");
    try std.json.Stringify.value(inline_out, .{}, w);
    if (file_note) |n| {
        try w.writeAll(",\"output_file_note\":");
        try std.json.Stringify.value(n, .{}, w);
    }
    if (r.pending and r.interactive_hint) {
        try w.writeAll(",\"reason\":\"the command appears to be WAITING FOR INPUT (see screen) — answer it with term_send_text/term_send_keys; the tracker stays attached and term_exec_wait picks up the completion afterwards\"");
    } else if (r.pending) {
        try w.writeAll(",\"reason\":\"still running — continue with term_exec_wait (do not resend); the tracker survives client-side timeouts and aborts\"");
    }
    if (r.shell_died) try w.writeAll(",\"reason\":\"the shell/connection died before the command finished\"");
    try w.writeAll("}");
    return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
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

/// Write bytes to an absolute local path; false on any failure.
pub fn writeFileBytes(path: []const u8, bytes: []const u8) bool {
    var pbuf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return false;
    const f = c.fopen(path_z.ptr, "wb") orelse return false;
    const n = if (bytes.len == 0) 0 else c.fwrite(bytes.ptr, 1, bytes.len, f);
    const bad = c.fclose(f) != 0;
    return n == bytes.len and !bad;
}

pub fn termTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (mcp.term_state.mux_sock == null)
        return appErr(arena, "headless terminal tools need isolated mode; in --shared mode use the GUI-backed terminal tools (list_terminals, run_command, ...)");

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
                        if (item != .string) return appErr(arena, "command array must be strings");
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
            return appErr(arena, "transport must be 'auto', 'mux' or 'ssh'");

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
                    return appErr(arena, "no reachable sketerm-mux daemon on the remote host (needs key/agent auth and sketerm-mux in the remote PATH; transport 'auto' would fall back to plain ssh)");
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
                try argv_store.append(arena, h);
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
                error.SpawnFailed => return appErr(arena, "spawn failed (mux daemon unreachable?)"),
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
            const announce_deadline = monoMs() + 8_000;
            while (!t.scanShellAnnounce() and monoMs() < announce_deadline and !t.exited) {
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
        const msg = try std.fmt.allocPrint(arena, "opened headless terminal {d} ({d}x{d}{s}){s}{s}", .{ id, cols, rows, shell_note, where, rec_note });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_list")) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        var first = true;
        var it = mcp.term_state.terms.iterator();
        while (it.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
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
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }

    const t = termFromArgs(args) orelse
        return appErr(arena, "no such terminal (pass 'term' id, or omit it when only one is open)");

    if (eql(u8, name, "term_send_text")) {
        const text = argStr(args, "text") orelse return appErr(arena, "term_send_text requires 'text'");
        const data = if (argBool(args, "enter"))
            try std.fmt.allocPrint(arena, "{s}\r", .{text})
        else
            text;
        t.sendText(data) catch return appErr(arena, "send failed (terminal exited?)");
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_send_keys")) {
        const keychords = argStr(args, "keys") orelse return appErr(arena, "term_send_keys requires 'keys'");
        t.sendKeys(keychords) catch |err| return appErr(arena, switch (err) {
            termdrive.Error.BadKey => "unknown key chord",
            else => "send failed (terminal exited?)",
        });
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_read")) {
        t.drain();
        const sb = argBool(args, "scrollback");
        const text = t.readScreen(sb) catch return appErr(arena, "read failed (terminal exited?)");
        defer mcp.term_state.allocator.free(text);
        if (t.exited) {
            // Make an exited terminal's state unambiguous: the final
            // rendered frame plus the real exit status, so a stale
            // progress line (scp "1%") cannot be mistaken for truth.
            const msg = if (t.exit_status_known)
                try std.fmt.allocPrint(arena, "[process exited with status {d} — final rendered screen below]\n{s}", .{ t.exit_status, text })
            else
                try std.fmt.allocPrint(arena, "[process exited (status unknown) — final rendered screen below]\n{s}", .{text});
            return toolResult(arena, msg, false) orelse error.OutOfMemory;
        }
        return toolResult(arena, try arena.dupe(u8, text), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_exec")) {
        const cmd = argStr(args, "command") orelse return appErr(arena, "term_exec requires 'command'");
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
            return appErr(arena, "'noninteractive' needs the default isolated transport (drop subshell:false)");
        const shell = argStr(args, "shell");
        if (shell) |sh| {
            if (!subshell)
                return appErr(arena, "'shell' needs the default isolated transport (drop subshell:false)");
            if (!validShellName(sh))
                return appErr(arena, "invalid 'shell' (a command name or absolute path: letters, digits, . _ - / only)");
        }
        if (t.hasPendingExec()) {
            // A previously timed-out exec may have finished since;
            // resolve it silently so the new send is accepted.
            if (t.waitExecResult(0)) |r0| mcp.term_state.allocator.free(r0.output);
            if (t.hasPendingExec())
                return appErr(arena, "a previous term_exec is still running in this terminal; continue it with term_exec_wait (or interrupt with term_send_keys ctrl+c)");
        }
        if (t.hasPendingCommand())
            return appErr(arena, "a term_run wait_for=command command is still tracked; resolve it with term_wait_command first");
        const r = t.execCommand(cmd, subshell, noninteractive, shell, timeout_ms) catch |err| return appErr(arena, switch (err) {
            termdrive.Error.NotConnected => "terminal exited",
            else => "exec failed",
        });
        defer mcp.term_state.allocator.free(r.output);
        return execResultJson(arena, r, t, argStr(args, "output_file"));
    }
    if (eql(u8, name, "term_exec_wait")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const r = t.waitExecResult(timeout_ms) orelse
            return appErr(arena, "no pending term_exec in this terminal");
        defer mcp.term_state.allocator.free(r.output);
        return execResultJson(arena, r, t, argStr(args, "output_file"));
    }
    if (eql(u8, name, "term_wait_exit")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const exited = t.waitExit(timeout_ms);
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{{\"exited\":{}", .{exited});
        if (exited and t.exit_status_known) try w.print(",\"exit_status\":{d}", .{t.exit_status});
        if (!exited) try w.writeAll(",\"timed_out\":true");
        const tail = blk: {
            const text = t.readScreen(false) catch break :blk "";
            defer mcp.term_state.allocator.free(text);
            break :blk try arena.dupe(u8, tailLines(text, 8));
        };
        if (tail.len > 0) {
            try w.writeAll(",\"screen_tail\":");
            try std.json.Stringify.value(tail, .{}, w);
        }
        try w.writeAll("}");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_run")) {
        const cmd = argStr(args, "command") orelse return appErr(arena, "term_run requires 'command'");
        const quiet_ms: i64 = argInt(args, "quiet_ms") orelse 400;
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const wait_for = argStr(args, "wait_for") orelse "idle";
        if (!eql(u8, wait_for, "idle") and !eql(u8, wait_for, "command"))
            return appErr(arena, "wait_for must be 'idle' or 'command'");
        if (eql(u8, wait_for, "command")) {
            // A tracked command may have completed since its timeout:
            // one short drain clears it so the new send is accepted.
            if (t.hasPendingCommand()) _ = t.waitPendingCommand(0);
            if (t.hasPendingCommand()) {
                return commandCompletionResult(arena, .{ .state = .running }, false, null, null, "a previously timed-out command is still running; use term_wait_command instead of resending");
            }
            // The token wait spends from the same budget as the
            // completion wait, so the call never outlives timeout_ms.
            const started = monoMs();
            const token_res = t.commandToken(@min(timeout_ms, 10_000)) catch return appErr(arena, "command completion unavailable (terminal exited?)");
            const token = switch (token_res) {
                .unsupported => return commandCompletionResult(arena, .{ .state = .unsupported }, false, null, null, "shell integration is unavailable for this shell; command was not sent and no exit status was fabricated"),
                .not_ready => return commandCompletionResult(arena, .{ .state = .unsupported, .timed_out = true }, false, null, null, "shell integration is injected but no prompt mark has arrived yet (shell still starting, ssh auth still pending, an unsupported remote shell, or rc files broke the injection); command was not sent — retry shortly, or use term_exec"),
                .busy => return commandCompletionResult(arena, .{ .state = .running }, false, null, null, "a foreground command started outside command mode is still running; its completion would be misattributed. Wait for it (term_wait_idle) before sending in command mode"),
                .token => |tok| tok,
            };
            const line = try std.fmt.allocPrint(arena, "{s}\r", .{cmd});
            t.sendText(line) catch return appErr(arena, "send failed (terminal exited?)");
            t.trackCommand(token);
            const result = t.waitCommand(token, @max(0, timeout_ms - (monoMs() - started)));

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
            return appErr(arena, "a command-mode command is still being tracked; resolve it with term_wait_command before running another command, or its exit status would be misattributed");
        // Honesty over silent queueing: when integration shows an
        // open command zone, the typed line goes to the RUNNING
        // program's stdin (or sits queued by the shell), not to a new
        // shell command — say so instead of letting a quiet screen
        // read as "executed".
        const busy_before = t.integration and t.foregroundRunning();
        const line = try std.fmt.allocPrint(arena, "{s}\r", .{cmd});
        t.sendText(line) catch return appErr(arena, "send failed (terminal exited?)");
        const settled = t.waitIdle(quiet_ms, timeout_ms);
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
                const msg = try std.fmt.allocPrint(arena, "exit: {d}\n---\n{s}{s}", .{ lc.exit, lc.text, note });
                return toolResult(arena, msg, false) orelse error.OutOfMemory;
            }
        }
        const text = t.readScreen(false) catch return appErr(arena, "read failed");
        defer mcp.term_state.allocator.free(text);
        const fallback_note = if (want_output_only)
            "[output_only unavailable: no completed OSC 133 command zone — shell integration is inactive in this terminal (unsupported shell, or the command emitted no marks); returning the rendered screen]\n"
        else
            "";
        const msg = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ fallback_note, text, note });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_wait_command")) {
        const timeout_ms: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 30_000, 0, 120_000);
        const result = t.waitPendingCommand(timeout_ms) orelse
            return appErr(arena, "no timed-out command is being tracked");
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
        const msg = if (!settled)
            "still active at timeout"
        else if (t.integration and t.foregroundRunning())
            "idle, but a foreground command is still RUNNING (output is quiet, not finished)"
        else if (t.integration)
            "idle at shell prompt"
        else
            "idle";
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_resize")) {
        const cols: u16 = @intCast(std.math.clamp(argInt(args, "cols") orelse 120, 10, 500));
        const rows: u16 = @intCast(std.math.clamp(argInt(args, "rows") orelse 40, 4, 300));
        t.resize(cols, rows) catch return appErr(arena, "resize failed (terminal exited?)");
        _ = t.waitIdle(200, 2_000);
        return toolResult(arena, "ok", false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "term_close")) {
        const id = termIdOf(t);
        _ = mcp.term_state.terms.swapRemove(id);
        t.deinit();
        // The daemon finalizes the cast with the session; keep the
        // path out of future term_list output.
        if (mcp.rec_state.casts.fetchSwapRemove(id)) |kv| mcp.rec_state.allocator.free(kv.value);
        return toolResult(arena, "terminal closed", false) orelse error.OutOfMemory;
    }
    return appErr(arena, "unknown tool");
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
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{{\"ok\":true,\"direction\":\"{s}\",\"path\":", .{direction});
    try std.json.Stringify.value(path, .{}, w);
    if (bytes) |b| try w.print(",\"bytes\":{d}", .{b});
    try w.print(",\"sha256\":\"{s}\",\"verified\":true,\"atomic\":true}}", .{sha});
    return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
}

pub fn xferTool(arena: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]const u8 {
    const eql = std.mem.eql;
    if (mcp.term_state.mux_sock == null)
        return appErr(arena, "file transfer / port forward tools need isolated mode (they run over private headless terminals)");

    if (eql(u8, name, "upload_file") or eql(u8, name, "download_file")) {
        const upload = eql(u8, name, "upload_file");
        const local = argStr(args, "local_path") orelse return appErr(arena, "requires 'local_path'");
        const remote = argStr(args, "remote_path") orelse return appErr(arena, "requires 'remote_path'");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 120_000;
        const host = argStr(args, "host");

        if (host == null) {
            const src = if (upload) local else remote;
            const dst = if (upload) remote else local;
            switch (try localCopyAtomic(arena, src, dst)) {
                .ok => |r| return xferOk(arena, if (upload) "upload" else "download", dst, r.bytes, &r.sha),
                .err => |e| return appErr(arena, e),
            }
        }
        const h = host.?;

        if (upload) {
            const local_sha = sha256File(local) orelse return appErr(arena, "cannot read/hash the local file");
            const bytes = fileSize(local);
            const tmp = try stagedPartPath(arena, remote);
            const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ h, tmp });
            switch (try runArgvTerm(arena, &.{ "scp", "-q", "-o", "BatchMode=yes", local, spec }, timeout_ms)) {
                .err => |e| return appErr(arena, e),
                .run => |r| {
                    if (!r.exited) return appErr(arena, "scp still running at timeout; the transfer terminal was killed — retry with a larger timeout_ms");
                    if (!r.status_known or r.status != 0)
                        return appErr(arena, try std.fmt.allocPrint(arena, "scp failed (status {d}):\n{s}", .{ r.status, r.output }));
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
            switch (try runArgvTerm(arena, &.{ "ssh", "-o", "BatchMode=yes", h, try remoteShLine(arena, script) }, 60_000)) {
                .err => |e| return appErr(arena, e),
                .run => |r| {
                    if (std.mem.indexOf(u8, r.output, "SK_MOVED") != null)
                        return xferOk(arena, "upload", remote, bytes, &local_sha);
                    if (std.mem.indexOf(u8, r.output, "SK_VERIFYFAIL") != null)
                        return appErr(arena, try std.fmt.allocPrint(arena, "verify_command rejected the staged file — upload discarded, destination untouched:\n{s}", .{r.output}));
                    if (std.mem.indexOf(u8, r.output, "SK_MVFAIL") != null)
                        return appErr(arena, "checksum verified but the atomic move failed on the remote (target dir not writable?)");
                    if (std.mem.indexOf(u8, r.output, "SK_SHA:fail") != null)
                        return appErr(arena, "remote has no usable sha256sum — cannot verify; file left absent (partial removed)");
                    return appErr(arena, try std.fmt.allocPrint(arena, "remote checksum mismatch — corrupt transfer discarded:\n{s}", .{r.output}));
                },
            }
        }

        // download
        const part = try stagedPartPath(arena, local);
        const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ h, remote });
        switch (try runArgvTerm(arena, &.{ "scp", "-q", "-o", "BatchMode=yes", spec, part }, timeout_ms)) {
            .err => |e| return appErr(arena, e),
            .run => |r| {
                if (!r.exited) return appErr(arena, "scp still running at timeout; the transfer terminal was killed — retry with a larger timeout_ms");
                if (!r.status_known or r.status != 0)
                    return appErr(arena, try std.fmt.allocPrint(arena, "scp failed (status {d}):\n{s}", .{ r.status, r.output }));
            },
        }
        const part_sha = sha256File(part) orelse return appErr(arena, "downloaded file vanished before hashing");
        const bytes = fileSize(part);
        const script = try std.fmt.allocPrint(arena, "sha256sum {s} 2>/dev/null | cut -c1-64\n", .{try quoted(arena, remote)});
        switch (try runArgvTerm(arena, &.{ "ssh", "-o", "BatchMode=yes", h, try remoteShLine(arena, script) }, 30_000)) {
            .err => |e| return appErr(arena, e),
            .run => |r| {
                const remote_sha = findHex64(r.output) orelse
                    return appErr(arena, try std.fmt.allocPrint(arena, "remote sha256sum gave no hash — cannot verify (partial kept at {s}):\n{s}", .{ part, r.output }));
                if (!std.mem.eql(u8, remote_sha, &part_sha)) {
                    var pbuf: [4096]u8 = undefined;
                    if (std.fmt.bufPrintZ(&pbuf, "{s}", .{part})) |pz| _ = c.unlink(pz.ptr) else |_| {}
                    return appErr(arena, "checksum mismatch — corrupt download discarded");
                }
            },
        }
        var pbuf: [4096]u8 = undefined;
        var dbuf: [4096]u8 = undefined;
        const part_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{part}) catch return appErr(arena, "path too long");
        const local_z = std.fmt.bufPrintZ(&dbuf, "{s}", .{local}) catch return appErr(arena, "path too long");
        if (c.rename(part_z.ptr, local_z.ptr) != 0)
            return appErr(arena, "atomic rename into place failed");
        return xferOk(arena, "download", local, bytes, &part_sha);
    }

    if (eql(u8, name, "port_forward_open")) {
        const h = argStr(args, "host") orelse return appErr(arena, "port_forward_open requires 'host'");
        const rp_i = argInt(args, "remote_port") orelse return appErr(arena, "port_forward_open requires 'remote_port'");
        if (rp_i < 1 or rp_i > 65535) return appErr(arena, "remote_port out of range");
        const rp: u16 = @intCast(rp_i);
        const rh = argStr(args, "remote_host") orelse "127.0.0.1";
        const lp: u16 = if (argInt(args, "local_port")) |v| blk: {
            if (v < 1 or v > 65535) return appErr(arena, "local_port out of range");
            break :blk @intCast(v);
        } else pickFreePort() orelse return appErr(arena, "could not pick a free local port");
        const timeout_ms: i64 = argInt(args, "timeout_ms") orelse 20_000;

        const t = spawnForwardTerm(arena, h, lp, rh, rp) catch
            return appErr(arena, "spawn failed (mux daemon unreachable?)");
        switch (try waitForwardReady(arena, t, lp, timeout_ms)) {
            .ready => {},
            .err => |e| {
                t.deinit();
                return appErr(arena, e);
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
        const msg = try std.fmt.allocPrint(arena, "{{\"forward\":{d},\"local_port\":{d},\"remote\":\"{s}:{d}\",\"host\":\"{s}\",\"listening\":true}}", .{ f.id, lp, rh, rp, h });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "port_forward_list")) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        for (mcp.forward_state.forwards.values(), 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            f.term.drain();
            try w.print("{{\"forward\":{d},\"host\":\"{s}\",\"local_port\":{d},\"remote\":\"{s}:{d}\",\"alive\":{},\"reconnects\":{d}}}", .{ f.id, f.host, f.local_port, f.remote_host, f.remote_port, !f.term.exited, f.reconnects });
        }
        try w.writeAll("]");
        return toolResult(arena, aw.written(), false) orelse error.OutOfMemory;
    }

    const f = forwardFromArgs(args) orelse
        return appErr(arena, "no such forward (pass 'forward' from port_forward_open, or omit it when only one is open)");

    if (eql(u8, name, "port_forward_check")) {
        f.term.drain();
        var reconnected = false;
        if (f.term.exited) {
            // The ssh process died (network blip, sshd restart):
            // respawn the same spec — this IS the reconnect behavior.
            const nt = spawnForwardTerm(arena, f.host, f.local_port, f.remote_host, f.remote_port) catch
                return appErr(arena, "forward is dead and respawn failed (mux daemon unreachable?)");
            switch (try waitForwardReady(arena, nt, f.local_port, argInt(args, "timeout_ms") orelse 20_000)) {
                .ready => {
                    f.term.deinit();
                    f.term = nt;
                    f.reconnects += 1;
                    reconnected = true;
                },
                .err => |e| {
                    nt.deinit();
                    return appErr(arena, try std.fmt.allocPrint(arena, "forward is dead and the reconnect failed: {s}", .{e}));
                },
            }
        }
        const listening = tcpListening(f.local_port, 2_000);
        const msg = try std.fmt.allocPrint(arena, "{{\"forward\":{d},\"alive\":{},\"listening\":{},\"reconnected\":{},\"local_port\":{d}}}", .{ f.id, !f.term.exited, listening, reconnected, f.local_port });
        return toolResult(arena, msg, false) orelse error.OutOfMemory;
    }
    if (eql(u8, name, "port_forward_close")) {
        mcp.forward_state.removeOne(f);
        return toolResult(arena, "forward closed", false) orelse error.OutOfMemory;
    }
    return appErr(arena, "unknown tool");
}

pub fn spawnForwardTerm(arena: std.mem.Allocator, host: []const u8, lp: u16, rh: []const u8, rp: u16) !*termdrive.Term {
    const bindspec = try std.fmt.allocPrint(arena, "127.0.0.1:{d}:{s}:{d}", .{ lp, rh, rp });
    const argv = [_][]const u8{
        "ssh",                      "-N",
        "-T",                       "-o",
        "BatchMode=yes",            "-o",
        "ExitOnForwardFailure=yes", "-o",
        "ServerAliveInterval=15",   "-o",
        "ServerAliveCountMax=4",    "-L",
        bindspec,                   host,
    };
    const t = termdrive.Term.spawn(mcp.term_state.allocator, &argv, 120, 30, mcp.term_state.mux_sock) catch return error.SpawnFailed;
    recordAuxTerm(t, "forward");
    return t;
}

pub fn waitForwardReady(arena: std.mem.Allocator, t: *termdrive.Term, lp: u16, timeout_ms: i64) !union(enum) { ready, err: []const u8 } {
    const deadline = monoMs() + timeout_ms;
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
        if (monoMs() >= deadline) {
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
