//! MCP pane tools, and the terminal-content half of the term_* tools.
//!
//! Every GUI pane is a daemon session, so typing into a terminal,
//! pressing keys, reading its grid, waiting for quiet and running a
//! command are the same operation whether the session is reached
//! through the GUI's control socket or driven directly over termdrive.
//! `Target` is that one seam: each content tool is written ONCE against
//! it and serves both its pane name and its `term_*` twin. Without a GUI
//! socket the pane names address the headless terminals this server
//! opened, by the same id `term_*` uses. Tools that arrange or
//! photograph GUI panes (split, focus, close, screenshot) have no
//! headless meaning and answer `unavailable` saying so.

const std = @import("std");
const mcp_tools = @import("mcp_tools.zig");
const mcp = @import("mcp.zig");
const mcp_term = @import("mcp_term.zig");
const termdrive = @import("termdrive.zig");
const protocol = @import("protocol.zig");
const Backend = mcp.Backend;
const Res = mcp.Res;
const ErrCode = mcp.ErrCode;
const argBool = mcp.argBool;
const argInt = mcp.argInt;
const argStr = mcp.argStr;
const errRes = mcp.errRes;
const objBool = mcp.objBool;
const objInt = mcp.objInt;
const objStr = mcp.objStr;
const waitCap = mcp.waitCap;

pub const Tool = mcp_tools.GroupTool(.panes);

pub fn panesTool(arena: std.mem.Allocator, backend: Backend, tool: Tool, args: std.json.Value) ![]const u8 {
    return switch (tool) {
        .list_terminals => listTerminals(arena, .pane, backend, args),
        .read_screen => readScreen(arena, .pane, backend, args),
        .send_text => sendText(arena, .pane, backend, args),
        .send_keys => sendKeys(arena, .pane, backend, args),
        .run_command => runCommand(arena, .pane, backend, args),
        .wait_idle => waitIdle(arena, .pane, backend, args),
        .record_pane_start => recordStart(arena, backend, args),
        .record_pane_stop => recordStop(arena, backend, args),
        .new_tab => newTab(arena, backend, args),
        .screenshot_pane => guiOnly(arena, tool, backend, args, screenshotPane),
        .split_pane => guiOnly(arena, tool, backend, args, splitPane),
        .focus_pane => guiOnly(arena, tool, backend, args, focusPane),
        .close_pane => guiOnly(arena, tool, backend, args, closePane),
    };
}

/// Which name a content tool was called by: it decides how the terminal
/// is addressed and what the address is called in the result.
pub const Family = enum {
    /// A GUI pane by `pane` id, or with no GUI socket a headless
    /// terminal by the same argument.
    pane,
    /// A headless terminal by `term` id.
    term,

    fn addr(self: Family) []const u8 {
        return switch (self) {
            .pane => "pane",
            .term => "term",
        };
    }

    /// The listing's array key, as each family has always spelled it.
    fn listKey(self: Family) []const u8 {
        return switch (self) {
            .pane => "terminals",
            .term => "terms",
        };
    }
};

/// A failure, ready for `errRes`.
const Fail = struct { code: ErrCode, msg: []const u8 };

fn failRes(arena: std.mem.Allocator, f: Fail) ![]const u8 {
    return errRes(arena, f.code, f.msg);
}

fn Outcome(comptime T: type) type {
    return union(enum) { ok: T, fail: Fail };
}

/// The GUI to use for a pane-family call, or null when none is attached.
fn guiOf(family: Family, backend: ?Backend) ?Backend {
    if (family != .pane) return null;
    const b = backend orelse return null;
    return if (b.gui_attached) b else null;
}

fn paneFromArgs(args: std.json.Value) ?u32 {
    const p = argInt(args, "pane") orelse return null;
    if (p < 0 or p > std.math.maxInt(u32)) return null;
    return @intCast(p);
}

/// A terminal's grid metadata: what `screen-info` reports for a GUI
/// pane and what a headless mirror holds, as one vocabulary.
const Grid = struct {
    rows: i64 = 0,
    cols: i64 = 0,
    cursor_row: i64 = 0,
    cursor_col: i64 = 0,
    alt_screen: bool = false,
    view_offset: i64 = 0,
    app_cursor_keys: bool = false,
    sync_output: bool = false,
    title: []const u8 = "",
    seq: i64 = 0,
    /// Completed OSC 133 command zones so far: the zone IDENTITY. Null
    /// when a GUI too old to report it answered.
    completion_seq: ?u64 = null,
    /// An OSC 133 command zone is open; null when it cannot be known
    /// (no shell integration, or an older GUI).
    command_running: ?bool = null,
};

/// The last completed OSC 133 command zone.
const LastCommand = struct {
    text: []const u8,
    exit: i64,
    /// The zone's identity; null from a GUI too old to report it.
    completion_seq: ?u64,
};

/// The terminal a content tool acts on.
pub const Target = union(enum) {
    /// A GUI pane over the control socket; a null pane is the focused one.
    gui: Gui,
    /// A headless daemon session this server opened.
    term: Term,

    const Gui = struct { backend: Backend, pane: ?u32 };
    const Term = struct { t: *termdrive.Term, id: u32 };

    fn resolve(family: Family, backend: ?Backend, args: std.json.Value) Outcome(Target) {
        if (guiOf(family, backend)) |b| return .{ .ok = .{ .gui = .{ .backend = b, .pane = paneFromArgs(args) } } };
        if (mcp_term.term_state.mux_sock == null) return .{ .fail = noHeadlessFail(family) };
        const t = mcp_term.termFromArgs(args, family.addr()) orelse return .{ .fail = .{ .code = .not_found, .msg = switch (family) {
            .pane => "no such headless terminal: with no GUI socket attached, `pane` addresses the headless terminals this server opened (list_terminals lists them, new_tab opens one; omit `pane` when only one is open)",
            .term => "no such terminal (pass 'term' id, or omit it when only one is open)",
        } } };
        return .{ .ok = .{ .term = .{ .t = t, .id = mcp_term.termIdOf(t) } } };
    }

    /// The address facts: `pane` only when the caller named one (an
    /// omitted pane is "the focused one", and inventing an id would be a
    /// lie), `headless` for every pane-family result, `term` for a twin.
    fn addAddr(self: Target, res: *Res, family: Family) !void {
        switch (self) {
            .gui => |g| {
                if (g.pane) |p| try res.fact("pane", p);
                try res.fact("headless", false);
            },
            .term => |h| {
                try res.fact(family.addr(), h.id);
                if (family == .pane) try res.fact("headless", true);
            },
        }
    }

    fn send(self: Target, arena: std.mem.Allocator, data: []const u8) ?Fail {
        switch (self) {
            .gui => |g| switch (guiCall(arena, g.backend, .{ .cmd = "send-text", .pane = g.pane, .data = data })) {
                .ok => return null,
                .fail => |f| return f,
            },
            .term => |h| {
                h.t.sendText(data) catch return exitedFail();
                return null;
            },
        }
    }

    fn keys(self: Target, arena: std.mem.Allocator, chords: []const u8) ?Fail {
        switch (self) {
            .gui => |g| switch (guiCall(arena, g.backend, .{ .cmd = "send-keys", .pane = g.pane, .data = chords })) {
                .ok => return null,
                .fail => |f| return f,
            },
            .term => |h| {
                h.t.sendKeys(chords) catch |err| return switch (err) {
                    termdrive.Error.BadKey => .{ .code = .invalid_args, .msg = "unknown key chord" },
                    else => exitedFail(),
                };
                return null;
            },
        }
    }

    fn grid(self: Target, arena: std.mem.Allocator) Outcome(Grid) {
        switch (self) {
            .gui => |g| {
                const reply = switch (guiCall(arena, g.backend, .{ .cmd = "screen-info", .pane = g.pane })) {
                    .ok => |r| r,
                    .fail => |f| return .{ .fail = f },
                };
                const s = reply.value.object.get("screen") orelse
                    return .{ .fail = .{ .code = .io_failed, .msg = "the GUI answered screen-info without a screen" } };
                return .{ .ok = .{
                    .rows = objInt(s, "rows"),
                    .cols = objInt(s, "cols"),
                    .cursor_row = objInt(s, "cursor_row"),
                    .cursor_col = objInt(s, "cursor_col"),
                    .alt_screen = objBool(s, "alt_screen"),
                    .view_offset = objInt(s, "view_offset"),
                    .app_cursor_keys = objBool(s, "app_cursor_keys"),
                    .sync_output = objBool(s, "sync_output"),
                    .title = objStr(s, "title"),
                    .seq = objInt(s, "seq"),
                    .completion_seq = optU64(s, "completion_seq"),
                    .command_running = optBool(s, "command_running"),
                } };
            },
            .term => |h| {
                h.t.drain();
                if (h.t.isDesynced()) return .{ .fail = desyncedFail() };
                const s = h.t.screen orelse return .{ .fail = exitedFail() };
                return .{ .ok = .{
                    .rows = s.rows,
                    .cols = s.cols,
                    .cursor_row = s.row,
                    .cursor_col = s.col,
                    .alt_screen = s.use_alt,
                    .view_offset = s.view_offset,
                    .app_cursor_keys = s.app_cursor_keys,
                    .sync_output = s.sync_output,
                    .title = arena.dupe(u8, s.last_title orelse "") catch "",
                    .seq = @intCast(h.t.seq),
                    .completion_seq = s.cmd_completion_seq,
                    .command_running = if (h.t.integration)
                        s.pending_output_start_id != 0 or s.pending_output_awaits_nl
                    else
                        null,
                } };
            },
        }
    }

    /// The rendered text: the visible screen, or with `scrollback` the
    /// history above it too.
    fn text(self: Target, arena: std.mem.Allocator, scrollback: bool) Outcome([]const u8) {
        switch (self) {
            .gui => |g| {
                const reply = switch (guiCall(arena, g.backend, .{
                    .cmd = "get-text",
                    .pane = g.pane,
                    .scrollback = if (scrollback) 1 else 0,
                })) {
                    .ok => |r| r,
                    .fail => |f| return .{ .fail = f },
                };
                return .{ .ok = objStr(reply.value, "text") };
            },
            .term => |h| {
                const owned = h.t.readScreen(scrollback) catch |err| return .{ .fail = switch (err) {
                    termdrive.Error.Desynced => desyncedFail(),
                    else => exitedFail(),
                } };
                defer mcp_term.term_state.allocator.free(owned);
                return .{ .ok = arena.dupe(u8, owned) catch return .{ .fail = oomFail() } };
            },
        }
    }

    /// The last completed command zone, or null when none completed yet.
    fn lastCommand(self: Target, arena: std.mem.Allocator) Outcome(?LastCommand) {
        switch (self) {
            .gui => |g| {
                const reply = switch (guiCall(arena, g.backend, .{ .cmd = "get-text", .pane = g.pane, .last_command = true })) {
                    .ok => |r| r,
                    // "No completed zone yet" is an answer, not a failure.
                    .fail => |f| return if (f.code == .not_found) .{ .ok = null } else .{ .fail = f },
                };
                const last = reply.value.object.get("last") orelse
                    return .{ .fail = .{ .code = .io_failed, .msg = "the GUI answered get-text last_command without a zone" } };
                return .{ .ok = .{
                    .text = objStr(last, "text"),
                    .exit = objInt(last, "exit"),
                    .completion_seq = optU64(last, "completion_seq"),
                } };
            },
            .term => |h| {
                const lc = (h.t.lastCommand() catch return .{ .fail = exitedFail() }) orelse return .{ .ok = null };
                defer mcp_term.term_state.allocator.free(lc.text);
                const s = h.t.screen orelse return .{ .fail = exitedFail() };
                return .{ .ok = .{
                    .text = arena.dupe(u8, lc.text) catch return .{ .fail = oomFail() },
                    .exit = lc.exit,
                    .completion_seq = s.cmd_completion_seq,
                } };
            },
        }
    }

    /// Wait until output has been quiet for `quiet_ms`; false = timed out.
    fn waitQuiet(self: Target, arena: std.mem.Allocator, quiet_ms: i64, timeout_ms: i64) Outcome(bool) {
        switch (self) {
            .gui => |g| {
                // The GUI dispatch is synchronous, so quiescence is polled:
                // `seq` (Terminal.activity_seq) stops changing.
                const b = g.backend;
                const start = b.nowMs(b.ctx);
                var last_seq: ?i64 = null;
                var last_change = start;
                while (true) {
                    const now_grid = switch (self.grid(arena)) {
                        .ok => |gr| gr,
                        .fail => |f| return .{ .fail = f },
                    };
                    const now = b.nowMs(b.ctx);
                    if (last_seq == null or now_grid.seq != last_seq.?) {
                        last_seq = now_grid.seq;
                        last_change = now;
                    } else if (now - last_change >= quiet_ms) {
                        return .{ .ok = true };
                    }
                    if (now - start >= timeout_ms) return .{ .ok = false };
                    b.sleepMs(b.ctx, 50);
                }
            },
            .term => |h| return .{ .ok = h.t.waitIdle(quiet_ms, timeout_ms) },
        }
    }

    fn desynced(self: Target) bool {
        return switch (self) {
            .gui => false,
            .term => |h| h.t.isDesynced(),
        };
    }

    fn exited(self: Target) struct { exited: bool, status: ?i64 } {
        return switch (self) {
            .gui => .{ .exited = false, .status = null },
            .term => |h| .{
                .exited = h.t.exited,
                .status = if (h.t.exited and h.t.exit_status_known) h.t.exit_status else null,
            },
        };
    }
};

fn optU64(v: std.json.Value, key: []const u8) ?u64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer and x.integer >= 0) @intCast(x.integer) else null;
}

fn optBool(v: std.json.Value, key: []const u8) ?bool {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .bool) x.bool else null;
}

/// Neither a GUI nor a headless daemon: what each family's caller can do.
fn noHeadlessFail(family: Family) Fail {
    return .{ .code = .unavailable, .msg = switch (family) {
        .pane => "no GUI socket is attached and this server runs no headless daemon (--shared found no running GUI): start sketerm, or pass --socket",
        .term => "headless terminal tools need isolated mode; in --shared mode use the GUI-backed terminal tools (list_terminals, run_command, ...)",
    } };
}

fn exitedFail() Fail {
    return .{ .code = .conflict, .msg = "the terminal's session has exited or disconnected" };
}

fn desyncedFail() Fail {
    return .{ .code = .conflict, .msg = "this terminal's mirror lost sync with the session and could not be rebuilt; its content is stale. Close it (term_close) and open a new one" };
}

fn oomFail() Fail {
    return .{ .code = .failed, .msg = "out of memory" };
}

/// One GUI request whose failure is typed: a refusal carries the GUI's
/// own code, a GUI that does not answer is `unavailable`.
fn guiCall(arena: std.mem.Allocator, backend: Backend, req: protocol.Request) Outcome(mcp.IpcReply) {
    const reply = mcp.ipcParsed(arena, backend, req) catch |err| return .{ .fail = .{
        .code = .unavailable,
        .msg = std.fmt.allocPrint(arena, "the GUI control socket did not answer ({s})", .{@errorName(err)}) catch "the GUI control socket did not answer",
    } };
    if (!reply.ok) return .{ .fail = .{ .code = mcp.guiErrCode(reply), .msg = reply.err } };
    return .{ .ok = reply };
}

/// The grid vocabulary, written into a result once for every tool that
/// reports on one.
fn addGrid(res: *Res, g: Grid) !void {
    try res.fact("rows", g.rows);
    try res.fact("cols", g.cols);
    try res.fact("cursor_row", g.cursor_row);
    try res.fact("cursor_col", g.cursor_col);
    try res.fact("alt_screen", g.alt_screen);
    try res.fact("view_offset", g.view_offset);
    try res.fact("app_cursor_keys", g.app_cursor_keys);
    try res.fact("sync_output", g.sync_output);
    try res.fact("title", g.title);
    try res.fact("seq", g.seq);
    try res.textf("{d}x{d} grid, cursor at row {d} col {d}{s}{s}{s}", .{
        g.cols,
        g.rows,
        g.cursor_row,
        g.cursor_col,
        if (g.alt_screen) ", alt screen" else "",
        if (g.title.len > 0) ", title " else "",
        g.title,
    });
}

// ── content tools: one implementation per operation, both families ──

/// list_terminals / term_list.
pub fn listTerminals(arena: std.mem.Allocator, family: Family, backend: ?Backend, _: std.json.Value) ![]const u8 {
    if (guiOf(family, backend)) |b| {
        const reply = switch (guiCall(arena, b, .{ .cmd = "list" })) {
            .ok => |r| r,
            .fail => |f| return failRes(arena, f),
        };
        return listTerminalsResult(arena, reply.value);
    }
    if (mcp_term.term_state.mux_sock == null) return failRes(arena, noHeadlessFail(family));
    return listHeadless(arena, family);
}

/// The headless terminals as a listing, keyed the way `family` addresses them.
fn listHeadless(arena: std.mem.Allocator, family: Family) ![]const u8 {
    var res = Res.init(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");
    var count: usize = 0;
    var it = mcp_term.term_state.terms.iterator();
    while (it.next()) |e| {
        if (count > 0) try w.writeAll(",");
        count += 1;
        const id = e.key_ptr.*;
        const t = e.value_ptr.*;
        t.drain();
        _ = t.scanShellAnnounce();
        try w.print("{{\"{s}\":{d},\"exited\":{}", .{ family.addr(), id, t.exited });
        if (family == .pane) try w.writeAll(",\"headless\":true");
        if (t.screen) |s| try w.print(",\"rows\":{d},\"cols\":{d}", .{ s.rows, s.cols });
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
        const last = mcp_term.termLastLine(arena, t);
        if (last.len > 0) {
            try w.writeAll(",\"last_line\":");
            try std.json.Stringify.value(last, .{}, w);
        }
        const cast = mcp_term.rec_state.casts.get(id);
        if (cast) |p| {
            try w.writeAll(",\"recording\":");
            try std.json.Stringify.value(p, .{}, w);
        }
        try w.writeAll("}");

        // One compact human line per terminal, same facts, no JSON.
        try res.textf("{s} {d}: {s}", .{ family.addr(), id, if (t.exited) "exited" else "running" });
        if (t.exited and t.exit_status_known) try res.textf("  exit_status: {d}", .{t.exit_status});
        if (t.shell_name) |sn| try res.textf("  shell: {s}, integration: {}", .{ sn, t.integration });
        if (t.remote_host) |rh| try res.textf("  host: {s} (sketerm-mux)", .{rh});
        if (t.hasPendingCommand()) try res.text("  pending_command: true");
        if (t.hasPendingExec()) try res.text("  pending_exec: true");
        if (last.len > 0) try res.textf("  last line: {s}", .{last});
        if (cast) |p| try res.textf("  recording: {s}", .{p});
    }
    try w.writeAll("]");
    try res.raw(family.listKey(), aw.written());
    try res.fact("count", count);
    if (family == .pane) try res.fact("headless", true);
    if (count == 0) try res.text("no headless terminals are open");
    return res.finish();
}

/// read_screen / term_read.
pub fn readScreen(arena: std.mem.Allocator, family: Family, backend: ?Backend, args: std.json.Value) ![]const u8 {
    const target = switch (Target.resolve(family, backend, args)) {
        .ok => |t| t,
        .fail => |f| return failRes(arena, f),
    };
    if (argBool(args, "last_command")) {
        const lc = switch (target.lastCommand(arena)) {
            .ok => |v| v orelse return errRes(arena, .not_found, "no command zone has completed in this terminal (shell integration inactive, or no command has finished yet)"),
            .fail => |f| return failRes(arena, f),
        };
        var res = Res.init(arena);
        try target.addAddr(&res, family);
        try res.fact("last_command", true);
        try res.field("exit_status", lc.exit);
        if (lc.completion_seq) |seq| try res.fact("completion_seq", seq);
        try res.fact("output", lc.text);
        try res.textf("--- command ---\n{s}", .{lc.text});
        return res.finish();
    }
    // `scrollback` was a line count on the pane tool and a flag on the
    // term tool; both only ever meant "the history too".
    const scrollback = argBool(args, "scrollback") or (argInt(args, "scrollback") orelse 0) > 0;
    const g = switch (target.grid(arena)) {
        .ok => |v| v,
        .fail => |f| return failRes(arena, f),
    };
    const txt = switch (target.text(arena, scrollback)) {
        .ok => |v| v,
        .fail => |f| return failRes(arena, f),
    };
    const ex = target.exited();
    var res = Res.init(arena);
    try target.addAddr(&res, family);
    try addGrid(&res, g);
    try res.fact("scrollback", scrollback);
    try res.fact("exited", ex.exited);
    try res.fact("text", txt);
    if (ex.exited) {
        // An exited terminal's state must be unambiguous: the final
        // frame plus the real exit status, so a stale progress line
        // (scp "1%") cannot be mistaken for truth.
        if (ex.status) |st| {
            try res.fact("exit_status", st);
            try res.textf("[process exited with status {d} - final rendered screen below]", .{st});
        } else try res.text("[process exited (status unknown) - final rendered screen below]");
    }
    try res.textf("--- screen ---\n{s}", .{txt});
    return res.finish();
}

/// send_text / term_send_text.
pub fn sendText(arena: std.mem.Allocator, family: Family, backend: ?Backend, args: std.json.Value) ![]const u8 {
    const text = argStr(args, "text") orelse return errRes(arena, .invalid_args, "requires 'text'");
    const target = switch (Target.resolve(family, backend, args)) {
        .ok => |t| t,
        .fail => |f| return failRes(arena, f),
    };
    const enter = argBool(args, "enter");
    const data = if (enter) try std.fmt.allocPrint(arena, "{s}\r", .{text}) else text;
    if (target.send(arena, data)) |f| return failRes(arena, f);
    var res = Res.init(arena);
    try target.addAddr(&res, family);
    try res.fact("bytes", data.len);
    try res.fact("enter", enter);
    try res.textf("typed {d} byte(s){s}", .{ text.len, if (enter) " and pressed Enter" else "" });
    return res.finish();
}

/// send_keys / term_send_keys.
pub fn sendKeys(arena: std.mem.Allocator, family: Family, backend: ?Backend, args: std.json.Value) ![]const u8 {
    const chords = argStr(args, "keys") orelse return errRes(arena, .invalid_args, "requires 'keys'");
    const target = switch (Target.resolve(family, backend, args)) {
        .ok => |t| t,
        .fail => |f| return failRes(arena, f),
    };
    if (target.keys(arena, chords)) |f| return failRes(arena, f);
    var res = Res.init(arena);
    try target.addAddr(&res, family);
    try res.field("keys", chords);
    try res.fact("sent", true);
    return res.finish();
}

/// wait_idle / term_wait_idle.
pub fn waitIdle(arena: std.mem.Allocator, family: Family, backend: ?Backend, args: std.json.Value) ![]const u8 {
    const target = switch (Target.resolve(family, backend, args)) {
        .ok => |t| t,
        .fail => |f| return failRes(arena, f),
    };
    const quiet_ms: i64 = argInt(args, "quiet_ms") orelse DEFAULT_QUIET_MS;
    const timeout_ms: i64 = waitCap(argInt(args, "timeout_ms"), DEFAULT_WAIT_MS);
    const settled = switch (target.waitQuiet(arena, quiet_ms, timeout_ms)) {
        .ok => |v| v,
        .fail => |f| return failRes(arena, f),
    };
    // Prompt-aware verdict where integration can tell: "quiet because
    // sleeping" must not masquerade as "done".
    const desynced = !settled and target.desynced();
    const running: ?bool = if (settled) switch (target.grid(arena)) {
        .ok => |g| g.command_running,
        .fail => null,
    } else null;
    var res = Res.init(arena);
    try target.addAddr(&res, family);
    try res.fact("settled", settled);
    try res.fact("timed_out", !settled);
    try res.fact("timeout_ms", timeout_ms);
    try res.fact("quiet_ms", quiet_ms);
    try res.fact("desynced", desynced);
    if (running) |r| try res.fact("foreground_running", r);
    try res.text(if (desynced)
        "NOT idle: this terminal's mirror lost sync with the session and could not be rebuilt, so quiescence cannot be observed. Close it (term_close) and open a new one"
    else if (!settled)
        "still active at timeout"
    else if (running == true)
        "idle, but a foreground command is still RUNNING (output is quiet, not finished)"
    else if (running == false)
        "idle at shell prompt"
    else
        "idle");
    return res.finish();
}

/// Output-idle defaults shared by run_command/term_run and wait_idle/term_wait_idle.
const DEFAULT_QUIET_MS: i64 = 400;
const DEFAULT_WAIT_MS: i64 = 30_000;

/// run_command / term_run.
pub fn runCommand(arena: std.mem.Allocator, family: Family, backend: ?Backend, args: std.json.Value) ![]const u8 {
    const command = argStr(args, "command") orelse return errRes(arena, .invalid_args, "requires 'command'");
    const wait_for = argStr(args, "wait_for") orelse "idle";
    if (!std.mem.eql(u8, wait_for, "idle") and !std.mem.eql(u8, wait_for, "command"))
        return errRes(arena, .invalid_args, "wait_for must be 'idle' or 'command'");
    const target = switch (Target.resolve(family, backend, args)) {
        .ok => |t| t,
        .fail => |f| return failRes(arena, f),
    };
    const timeout_ms: i64 = waitCap(argInt(args, "timeout_ms"), DEFAULT_WAIT_MS);
    if (std.mem.eql(u8, wait_for, "command")) return switch (target) {
        .gui => mcp_term.commandCompletionResult(arena, .{ .state = .unsupported }, false, null, null, "wait_for=command tracks a shell's completion marks through a headless terminal; for a GUI pane use the default output-idle wait (with output_only for the completed zone), or open a headless terminal with term_open"),
        .term => |h| mcp_term.runCommandMode(arena, h.t, command, timeout_ms, argBool(args, "output_only")),
    };

    // Idle mode must not run a NEW command while a command-mode token is
    // unresolved: the interloper's OSC 133 D would be reported by
    // term_wait_command as the tracked command's exit.
    if (target == .term) {
        const t = target.term.t;
        if (t.hasPendingCommand()) _ = t.waitPendingCommand(0);
        if (t.hasPendingCommand())
            return errRes(arena, .conflict, "a command-mode command is still being tracked; resolve it with term_wait_command before running another command, or its exit status would be misattributed");
    }
    const quiet_ms: i64 = argInt(args, "quiet_ms") orelse DEFAULT_QUIET_MS;
    const want_output_only = argBool(args, "output_only");

    // The zone baseline BEFORE sending: output_only may only report a
    // zone that completed after this command went out, or it hands back
    // the previous command's output and exit status as this one's.
    const before = switch (target.grid(arena)) {
        .ok => |g| g,
        .fail => |f| return failRes(arena, f),
    };
    // Honesty over silent queueing: text typed while a foreground
    // command runs goes to that program's stdin, not to a new command.
    const busy_before = before.command_running orelse false;
    const line = try std.fmt.allocPrint(arena, "{s}\r", .{command});
    if (target.send(arena, line)) |f| return failRes(arena, f);
    const settled = switch (target.waitQuiet(arena, quiet_ms, timeout_ms)) {
        .ok => |v| v,
        .fail => |f| return failRes(arena, f),
    };

    var res = Res.init(arena);
    try target.addAddr(&res, family);
    try res.fact("command", command);
    try res.fact("wait_for", @as([]const u8, "idle"));
    try res.fact("command_sent", true);
    try res.fact("settled", settled);
    try res.fact("timed_out", !settled);
    try res.fact("went_to_foreground_stdin", busy_before);
    if (!settled) try res.text("still producing output after the timeout");
    if (busy_before)
        try res.text("a foreground command was already running when this text was sent: it went to that program's stdin, or the shell queued it as pending input; it did NOT start as a new shell command. Wait with wait_idle, or interrupt with send_keys ctrl+c");

    if (want_output_only) {
        switch (try zoneForCommand(arena, target, before)) {
            .zone => |lc| {
                try res.fact("output_kind", @as([]const u8, "command"));
                try res.field("exit_status", lc.exit);
                try res.fact("output", lc.text);
                try res.textf("--- output ---\n{s}", .{lc.text});
                return res.finish();
            },
            .none => |why| {
                try res.fact("output_only_unavailable", true);
                try res.fact("reason", why);
                try res.textf("output_only unavailable: {s}; returning the rendered screen", .{why});
            },
            .fail => |f| return failRes(arena, f),
        }
    }
    const txt = switch (target.text(arena, false)) {
        .ok => |v| v,
        .fail => |f| return failRes(arena, f),
    };
    try res.fact("output_kind", @as([]const u8, "screen"));
    try res.fact("output", txt);
    try res.textf("--- screen ---\n{s}", .{txt});
    return res.finish();
}

const Zone = union(enum) {
    zone: LastCommand,
    /// Why no zone can be attributed to this command.
    none: []const u8,
    fail: Fail,
};

/// The completed zone that belongs to the command sent after `before`
/// was sampled: one whose identity moved past the baseline.
fn zoneForCommand(arena: std.mem.Allocator, target: Target, before: Grid) !Zone {
    const baseline = before.completion_seq orelse
        return .{ .none = "this GUI does not report command-zone identity, so the last completed zone cannot be shown to belong to this command (update sketerm)" };
    const lc = switch (target.lastCommand(arena)) {
        .ok => |v| v orelse return .{ .none = "no command zone has completed (shell integration inactive in this terminal, or the command emitted no marks)" },
        .fail => |f| return .{ .fail = f },
    };
    const seq = lc.completion_seq orelse
        return .{ .none = "this GUI does not report command-zone identity, so the last completed zone cannot be shown to belong to this command (update sketerm)" };
    if (seq == baseline)
        return .{ .none = "no command zone completed after this command was sent (still running, or the shell emitted no completion mark); the last completed zone belongs to an EARLIER command" };
    return .{ .zone = lc };
}

// ── pane-only tools ─────────────────────────────────────────────────

fn recordStart(arena: std.mem.Allocator, backend: Backend, args: std.json.Value) ![]const u8 {
    const path = argStr(args, "path") orelse
        return errRes(arena, .invalid_args, "record_pane_start requires 'path' (absolute .cast output)");
    if (path.len == 0 or path[0] != '/') return errRes(arena, .invalid_args, "record_pane_start path must be absolute");
    const target = switch (Target.resolve(.pane, backend, args)) {
        .ok => |t| t,
        .fail => |f| return failRes(arena, f),
    };
    switch (target) {
        .gui => |g| switch (guiCall(arena, g.backend, .{ .cmd = "record-start", .pane = g.pane, .data = path })) {
            .ok => {},
            .fail => |f| return failRes(arena, f),
        },
        .term => |h| mcp_term.recordTermAt(h.t, h.id, path) catch return errRes(arena, .failed, "out of memory"),
    }
    var res = Res.init(arena);
    try target.addAddr(&res, .pane);
    try res.field("path", path);
    try res.fact("recording", true);
    try res.text("recording started (asciicast v2; stop with record_pane_stop)");
    return res.finish();
}

fn recordStop(arena: std.mem.Allocator, backend: Backend, args: std.json.Value) ![]const u8 {
    const target = switch (Target.resolve(.pane, backend, args)) {
        .ok => |t| t,
        .fail => |f| return failRes(arena, f),
    };
    switch (target) {
        .gui => |g| switch (guiCall(arena, g.backend, .{ .cmd = "record-stop", .pane = g.pane })) {
            .ok => {},
            .fail => |f| return failRes(arena, f),
        },
        .term => |h| mcp_term.stopTermRecording(h.t, h.id),
    }
    var res = Res.init(arena);
    try target.addAddr(&res, .pane);
    try res.fact("recording", false);
    try res.text("recording stopped");
    return res.finish();
}

fn newTab(arena: std.mem.Allocator, backend: Backend, args: std.json.Value) ![]const u8 {
    if (backend.gui_attached) {
        const reply = switch (guiCall(arena, backend, .{ .cmd = "new-tab", .cwd = argStr(args, "cwd"), .title = argStr(args, "title") })) {
            .ok => |r| r,
            .fail => |f| return failRes(arena, f),
        };
        const created = reply.value.object.get("created");
        var res = Res.init(arena);
        try res.fact("headless", false);
        try res.field("tab", objInt(created, "tab"));
        try res.field("pane", objInt(created, "pane"));
        return res.finish();
    }
    // No GUI: a headless terminal is the pane, addressed by the same id
    // through every pane tool and every term_* tool.
    if (mcp_term.term_state.mux_sock == null) return failRes(arena, noHeadlessFail(.pane));
    const id = mcp_term.spawnRegisteredTerm(null, 120, 40) catch
        return errRes(arena, .unavailable, "no GUI socket, and opening a headless terminal failed too (mux daemon unreachable?)");
    const t = mcp_term.term_state.terms.get(id).?;
    _ = t.waitIdle(250, 3_000);
    var res = Res.init(arena);
    try res.fact("headless", true);
    try res.field("pane", id);
    try res.fact("term", id);
    try res.textf("no GUI socket is attached: opened headless terminal {d}; every pane tool (send_text, run_command, read_screen, ...) addresses it as pane {d}, and the term_* tools as term {d}", .{ id, id, id });
    return res.finish();
}

/// One tool body that needs the GUI itself.
const GuiBody = fn (std.mem.Allocator, Backend, std.json.Value) anyerror![]const u8;

/// Split, focus, close and screenshot act on the GUI's widgets, which a
/// headless terminal does not have: without a GUI socket they refuse,
/// naming what does exist.
fn guiOnly(arena: std.mem.Allocator, tool: Tool, backend: Backend, args: std.json.Value, comptime body: GuiBody) ![]const u8 {
    if (backend.gui_attached) return body(arena, backend, args);
    return errRes(arena, .unavailable, try std.fmt.allocPrint(
        arena,
        "{s} acts on the GUI's panes and this server has no GUI socket (isolated mode without --socket). Headless terminals have no GUI pane to arrange or photograph: read them with read_screen and close them with term_close, or restart the server with --socket/--shared to reach a running sketerm",
        .{@tagName(tool)},
    ));
}

fn screenshotPane(arena: std.mem.Allocator, backend: Backend, args: std.json.Value) ![]const u8 {
    return paneScreenshot(arena, backend, paneFromArgs(args));
}

fn splitPane(arena: std.mem.Allocator, backend: Backend, args: std.json.Value) ![]const u8 {
    const pane = paneFromArgs(args);
    const direction = argStr(args, "direction") orelse "h";
    const reply = switch (guiCall(arena, backend, .{ .cmd = "split", .pane = pane, .direction = direction })) {
        .ok => |r| r,
        .fail => |f| return failRes(arena, f),
    };
    var res = Res.init(arena);
    try res.field("pane", objInt(reply.value.object.get("created"), "pane"));
    try res.fact("direction", direction);
    if (pane) |p| try res.fact("split_from", p);
    try res.text(if (std.mem.eql(u8, direction, "v")) "stacked below the source pane" else "placed beside the source pane");
    return res.finish();
}

fn focusPane(arena: std.mem.Allocator, backend: Backend, args: std.json.Value) ![]const u8 {
    const pane = paneFromArgs(args) orelse return errRes(arena, .invalid_args, "focus_pane requires 'pane'");
    switch (guiCall(arena, backend, .{ .cmd = "focus", .pane = pane })) {
        .ok => {},
        .fail => |f| return failRes(arena, f),
    }
    var res = Res.init(arena);
    try res.field("pane", pane);
    try res.fact("focused", true);
    return res.finish();
}

fn closePane(arena: std.mem.Allocator, backend: Backend, args: std.json.Value) ![]const u8 {
    const pane = paneFromArgs(args) orelse return errRes(arena, .invalid_args, "close_pane requires 'pane'");
    switch (guiCall(arena, backend, .{ .cmd = "close-pane", .pane = pane })) {
        .ok => {},
        .fail => |f| return failRes(arena, f),
    }
    var res = Res.init(arena);
    try res.field("pane", pane);
    try res.fact("closed", true);
    return res.finish();
}

/// Screenshot one GUI pane. The GUI renders the PNG to a temp file (its
/// control protocol is line-JSON), which is read back and returned as an
/// inline image. Shared by `screenshot_pane` and `web_screenshot`.
pub fn paneScreenshot(arena: std.mem.Allocator, backend: Backend, pane: ?u32) ![]const u8 {
    const png = switch (try mcp.paneScreenshotPng(arena, backend, pane)) {
        .err => |e| return errRes(arena, .io_failed, e),
        .png => |bytes| bytes,
    };
    var res = Res.init(arena);
    if (pane) |p| try res.fact("pane", p);
    try res.fact("bytes", png.len);
    if (mcp.pngSize(png)) |s| {
        try res.fact("width", s.w);
        try res.fact("height", s.h);
        try res.textf("terminal pane screenshot, {d}x{d}", .{ s.w, s.h });
    } else try res.text("terminal pane screenshot");
    return res.finishWithImages(&.{png}, &.{"pane"});
}

/// The GUI's `list` reply (tabs, each with its panes) restructured into
/// the flat, addressable `terminals` array plus a one-line-per-pane
/// listing. Pure so the shape is testable without a GUI.
pub fn listTerminalsResult(arena: std.mem.Allocator, reply: std.json.Value) ![]const u8 {
    var res = Res.init(arena);
    var sc: std.Io.Writer.Allocating = .init(arena);
    var text: std.Io.Writer.Allocating = .init(arena);
    const jw = &sc.writer;
    const tw = &text.writer;
    try jw.writeAll("[");

    var panes: usize = 0;
    var tabs: usize = 0;
    const tabs_v = if (reply == .object) reply.object.get("tabs") else null;
    if (tabs_v != null and tabs_v.? == .array) {
        for (tabs_v.?.array.items) |tab| {
            if (tab != .object) continue;
            tabs += 1;
            const tab_id = objInt(tab, "id");
            const tab_title = objStr(tab, "title");
            const window = objInt(tab, "window");
            const selected = objBool(tab, "selected");
            const pane_list = tab.object.get("panes") orelse continue;
            if (pane_list != .array) continue;
            for (pane_list.array.items) |p| {
                if (p != .object) continue;
                if (panes > 0) try jw.writeAll(",");
                panes += 1;
                const id = objInt(p, "id");
                const title = objStr(p, "title");
                const cwd = objStr(p, "cwd");
                const rows = objInt(p, "rows");
                const cols = objInt(p, "cols");
                const focused = objBool(p, "focused");
                const zoomed = objBool(p, "zoomed");
                try jw.print("{{\"pane\":{d},\"tab\":{d},\"window\":{d},\"rows\":{d},\"cols\":{d},\"focused\":{},\"zoomed\":{},\"tab_selected\":{},\"title\":", .{
                    id, tab_id, window, rows, cols, focused, zoomed, selected,
                });
                try std.json.Stringify.value(title, .{}, jw);
                try jw.writeAll(",\"tab_title\":");
                try std.json.Stringify.value(tab_title, .{}, jw);
                try jw.writeAll(",\"cwd\":");
                try std.json.Stringify.value(cwd, .{}, jw);
                try jw.writeAll("}");

                if (text.written().len != 0) try tw.writeAll("\n");
                try tw.print("pane {d}  tab {d}  {d}x{d}", .{ id, tab_id, cols, rows });
                if (focused) try tw.writeAll("  focused");
                if (zoomed) try tw.writeAll("  zoomed");
                if (title.len > 0) try tw.print("  {s}", .{title});
                if (cwd.len > 0) try tw.print("  [{s}]", .{cwd});
            }
        }
    }
    try jw.writeAll("]");

    try res.raw("terminals", sc.written());
    try res.fact("count", panes);
    try res.fact("tabs", tabs);
    try res.fact("headless", false);
    try res.textf("{d} pane(s) in {d} tab(s)", .{ panes, tabs });
    if (panes > 0) try res.textf("--- panes ---\n{s}", .{text.written()});
    return res.finish();
}

// ── Tests ─────────────────────────────────────────────────────────

const FakeBackend = @import("mcp_testkit.zig").FakeBackend;
const handleMessage = mcp.handleMessage;
const expectToolResultShape = mcp.expectToolResultShape;
const rpcToolResult = mcp.rpcToolResult;
const textProse = mcp.textProse;
const WAIT_CAP_MS = mcp.WAIT_CAP_MS;

test "wait_idle clamps its budget to the app-side wait cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const info = "{\"ok\":true,\"screen\":{\"seq\":1}}";
    var fake = FakeBackend{
        .responses = &.{ info, info, info },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    // The MCP loop is single-threaded and the central watchdog cannot
    // reach the GUI control socket (RealBackend's own connection),
    // so an unclamped wait here blocks every other tool for its whole
    // duration and the watchdog only tears down unrelated sessions.
    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"wait_idle","arguments":{"pane":1,"timeout_ms":600000,"quiet_ms":10}}}
    ).?;
    const parsed = try expectToolResultShape(arena, "wait_idle", try rpcToolResult(arena, resp));
    const sc = parsed.object.get("structuredContent").?.object;
    try std.testing.expectEqual(WAIT_CAP_MS, sc.get("timeout_ms").?.integer);
}

test "tools/call send_keys routes to IPC send-keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true}"},
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_keys","arguments":{"pane":4,"keys":"ctrl+c enter"}}}
    ).?;
    const parsed = try expectToolResultShape(arena, "send_keys", try rpcToolResult(arena, resp));
    const sc = parsed.object.get("structuredContent").?.object;
    try std.testing.expectEqualStrings("ctrl+c enter", sc.get("keys").?.string);
    try std.testing.expect(sc.get("sent").?.bool);
    try std.testing.expectEqual(@as(i64, 4), sc.get("pane").?.integer);
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"cmd\":\"send-keys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"pane\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "ctrl+c enter") != null);
}

test "read_screen last_command extracts the OSC 133 zone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true,\"last\":{\"text\":\"hi\\n\",\"exit\":3}}"},
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"read_screen","arguments":{"pane":2,"last_command":true}}}
    ).?;
    const parsed = try expectToolResultShape(arena, "read_screen", try rpcToolResult(arena, resp));
    const sc = parsed.object.get("structuredContent").?.object;
    try std.testing.expectEqual(@as(i64, 3), sc.get("exit_status").?.integer);
    try std.testing.expect(sc.get("last_command").?.bool);
    try std.testing.expectEqualStrings("hi\n", sc.get("output").?.string);
    // The output rides the text lane behind its payload divider.
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("exit_status: 3\n--- command ---\nhi\n", text);
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"last_command\":true") != null);
}

test "run_command settles via seq polling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // baseline screen-info → send-text → seq 5 (start) → seq 7 (changed)
    // → seq 7 twice more (the quiet window elapses on the fake clock) →
    // get-text for the final screen.
    const screen5 = "{\"ok\":true,\"screen\":{\"rows\":24,\"cols\":80,\"cursor_row\":0,\"cursor_col\":0,\"alt_screen\":false,\"seq\":5}}";
    const screen7 = "{\"ok\":true,\"screen\":{\"rows\":24,\"cols\":80,\"cursor_row\":1,\"cursor_col\":0,\"alt_screen\":false,\"seq\":7}}";
    var fake = FakeBackend{
        .responses = &.{
            screen5, // the zone baseline, before anything is sent
            "{\"ok\":true}", // send-text
            screen5, // poll 1: baseline
            screen7, // poll 2: changed → reset quiet timer
            screen7, // poll 3: unchanged
            screen7, // poll 4: unchanged, quiet window passed → settled
            "{\"ok\":true,\"text\":\"$ echo hi\\nhi\\n\"}", // final get-text
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"run_command","arguments":{"pane":1,"command":"echo hi","quiet_ms":100,"timeout_ms":5000}}}
    ).?;
    const parsed = try expectToolResultShape(arena, "run_command", try rpcToolResult(arena, resp));
    const sc = parsed.object.get("structuredContent").?.object;
    try std.testing.expectEqualStrings("echo hi", sc.get("command").?.string);
    try std.testing.expectEqualStrings("screen", sc.get("output_kind").?.string);
    try std.testing.expect(sc.get("settled").?.bool);
    try std.testing.expect(!sc.get("timed_out").?.bool);
    try std.testing.expect(!sc.get("headless").?.bool);
    try std.testing.expectEqualStrings("$ echo hi\nhi\n", sc.get("output").?.string);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "--- screen ---\n$ echo hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, textProse(text), "timeout") == null);
    // The baseline was read BEFORE the send, which carried a trailing CR.
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"cmd\":\"screen-info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[1], "\"cmd\":\"send-text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[1], "echo hi\\r") != null);
}

/// One run_command output_only call against a scripted GUI.
fn outputOnlyRun(arena: std.mem.Allocator, fake: *FakeBackend) !std.json.ObjectMap {
    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"run_command","arguments":{"pane":1,"command":"make","quiet_ms":50,"timeout_ms":5000,"output_only":true}}}
    ).?;
    const parsed = try expectToolResultShape(arena, "run_command", try rpcToolResult(arena, resp));
    return parsed.object.get("structuredContent").?.object;
}

test "run_command output_only reports only a zone that completed after the send" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = "{\"ok\":true,\"screen\":{\"seq\":1,\"completion_seq\":4,\"command_running\":false}}";
    const quiet = "{\"ok\":true,\"screen\":{\"seq\":2,\"completion_seq\":4,\"command_running\":false}}";

    // The GUI's last zone is still the one that existed BEFORE the send:
    // reporting it would hand back an earlier command's output and exit.
    var stale = FakeBackend{
        .responses = &.{
            before,
            "{\"ok\":true}",
            quiet,
            quiet,
            "{\"ok\":true,\"last\":{\"text\":\"old output\\n\",\"exit\":7,\"completion_seq\":4}}",
            "{\"ok\":true,\"text\":\"$ make\\nbuilding...\\n\"}",
        },
        .allocator = t.allocator,
    };
    defer stale.deinit();
    const s1 = try outputOnlyRun(arena, &stale);
    try t.expectEqualStrings("screen", s1.get("output_kind").?.string);
    try t.expect(s1.get("output_only_unavailable").?.bool);
    try t.expect(std.mem.indexOf(u8, s1.get("reason").?.string, "EARLIER") != null);
    try t.expect(s1.get("exit_status") == null);
    try t.expectEqualStrings("$ make\nbuilding...\n", s1.get("output").?.string);

    // A zone whose identity moved past the baseline is this command's.
    var fresh = FakeBackend{
        .responses = &.{
            before,
            "{\"ok\":true}",
            quiet,
            quiet,
            "{\"ok\":true,\"last\":{\"text\":\"built\\n\",\"exit\":0,\"completion_seq\":5}}",
        },
        .allocator = t.allocator,
    };
    defer fresh.deinit();
    const s2 = try outputOnlyRun(arena, &fresh);
    try t.expectEqualStrings("command", s2.get("output_kind").?.string);
    try t.expectEqual(@as(i64, 0), s2.get("exit_status").?.integer);
    try t.expectEqualStrings("built\n", s2.get("output").?.string);

    // A GUI too old to report zone identity cannot prove a zone is this
    // command's: the screen, and the reason, never a guess.
    const old_gui = "{\"ok\":true,\"screen\":{\"seq\":1}}";
    var legacy = FakeBackend{
        .responses = &.{
            old_gui,
            "{\"ok\":true}",
            old_gui,
            old_gui,
            "{\"ok\":true,\"text\":\"$ make\\n\"}",
        },
        .allocator = t.allocator,
    };
    defer legacy.deinit();
    const s3 = try outputOnlyRun(arena, &legacy);
    try t.expectEqualStrings("screen", s3.get("output_kind").?.string);
    try t.expect(std.mem.indexOf(u8, s3.get("reason").?.string, "does not report command-zone identity") != null);
    // No last-command read was spent on a zone it could not attribute.
    for (legacy.requests.items) |req| try t.expect(std.mem.indexOf(u8, req, "\"last_command\":true") == null);
}

test "run_command refuses command mode on a GUI pane without typing anything" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_command","arguments":{"pane":1,"command":"true","wait_for":"command"}}}
    ).?;
    const parsed = try expectToolResultShape(arena, "run_command", try rpcToolResult(arena, resp));
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expect(!sc.get("command_sent").?.bool);
    try t.expectEqualStrings("unsupported", sc.get("state").?.string);
    try t.expectEqual(@as(usize, 0), fake.requests.items.len);
}

test "pane tools without a GUI socket reach headless terminals or say what exists" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{ .responses = &.{}, .gui_attached = false, .allocator = t.allocator };
    defer fake.deinit();
    const saved_sock = mcp_term.term_state.mux_sock;
    defer mcp_term.term_state.mux_sock = saved_sock;

    // No GUI and no headless daemon (--shared found no GUI): unavailable.
    mcp_term.term_state.mux_sock = null;
    const nothing = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_text","arguments":{"text":"hi"}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, nothing, "\"code\":\"unavailable\"") != null);
    try t.expect(std.mem.indexOf(u8, nothing, "no GUI socket") != null);

    // A headless daemon but no terminal open: not_found, naming new_tab.
    mcp_term.term_state.mux_sock = "/tmp/sketerm-mcp-panes-test/mux.sock";
    const none_open = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_screen","arguments":{}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, none_open, "\"code\":\"not_found\"") != null);
    try t.expect(std.mem.indexOf(u8, none_open, "new_tab") != null);
    const listed = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_terminals","arguments":{}}}
    ).?;
    const lparsed = try expectToolResultShape(arena, "list_terminals", try rpcToolResult(arena, listed));
    try t.expect(lparsed.object.get("structuredContent").?.object.get("headless").?.bool);

    // Tools that only mean something for GUI panes refuse, precisely.
    for ([_][]const u8{ "split_pane", "focus_pane", "close_pane", "screenshot_pane" }) |tool| {
        const msg = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{\"pane\":1}}}}}}", .{tool});
        const resp = handleMessage(arena, fake.backend(), msg).?;
        try t.expect(std.mem.indexOf(u8, resp, "\"code\":\"unavailable\"") != null);
        try t.expect(std.mem.indexOf(u8, resp, tool) != null);
    }
    // No GUI request was ever attempted.
    try t.expectEqual(@as(usize, 0), fake.requests.items.len);
}

test "wait_idle times out when output keeps flowing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // seq keeps incrementing forever; fake clock advances 50ms per
    // poll, timeout at 200ms.
    var bufs: [8][]const u8 = undefined;
    var storage: [8][96]u8 = undefined;
    for (0..8) |n| {
        bufs[n] = std.fmt.bufPrint(&storage[n], "{{\"ok\":true,\"screen\":{{\"seq\":{d}}}}}", .{n}) catch unreachable;
    }
    var fake = FakeBackend{ .responses = &bufs, .allocator = std.testing.allocator };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"wait_idle","arguments":{"quiet_ms":100,"timeout_ms":200}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "timeout") != null);
}

test "list_terminals flattens the GUI's tabs into addressable panes" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reply = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"ok":true,"tabs":[
        \\{"id":1,"window":3,"title":"shell","selected":true,"panes":[
        \\{"id":4,"title":"zsh","cwd":"/home/u","pid":0,"rows":24,"cols":80,"focused":true,"zoomed":false},
        \\{"id":5,"title":"logs","cwd":"/var/log","pid":0,"rows":12,"cols":80,"focused":false,"zoomed":true}]},
        \\{"id":2,"window":3,"title":"docs","selected":false,"panes":[]}]}
    , .{});

    const out = try listTerminalsResult(arena, reply);
    const parsed = try expectToolResultShape(arena, "list_terminals", out);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expectEqual(@as(i64, 2), sc.get("count").?.integer);
    try t.expectEqual(@as(i64, 2), sc.get("tabs").?.integer);
    const terms = sc.get("terminals").?.array.items;
    try t.expectEqual(@as(usize, 2), terms.len);
    try t.expectEqual(@as(i64, 4), terms[0].object.get("pane").?.integer);
    try t.expectEqual(@as(i64, 1), terms[0].object.get("tab").?.integer);
    try t.expectEqual(@as(i64, 3), terms[0].object.get("window").?.integer);
    try t.expect(terms[0].object.get("focused").?.bool);
    try t.expect(terms[1].object.get("zoomed").?.bool);
    try t.expectEqualStrings("/var/log", terms[1].object.get("cwd").?.string);
    // Tab-level identity rides every pane, so nothing is lost by
    // flattening — and the text lane is one line per pane.
    try t.expectEqualStrings("shell", terms[1].object.get("tab_title").?.string);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.startsWith(u8, text, "2 pane(s) in 2 tab(s)"));
    try t.expect(std.mem.indexOf(u8, text, "pane 4  tab 1  80x24  focused  zsh  [/home/u]") != null);
    try t.expect(std.mem.indexOf(u8, text, "pane 5  tab 1  80x12  zoomed  logs  [/var/log]") != null);

    // A GUI with nothing open answers the same shape, not an error.
    const empty = try listTerminalsResult(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"ok\":true,\"tabs\":[]}", .{}));
    const eparsed = try expectToolResultShape(arena, "list_terminals", empty);
    try t.expectEqual(@as(i64, 0), eparsed.object.get("structuredContent").?.object.get("count").?.integer);
}
