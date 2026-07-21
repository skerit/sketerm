//! Headless terminal driver for the MCP server: a GTK-free mux client
//! that spawns and drives plain SHELL sessions on the (isolated)
//! daemon, maintaining a client-side Screen mirror from the snapshot +
//! event stream. This is the terminal counterpart of appdrive.zig —
//! it lets `sketerm mcp` run commands and read output with no GUI and
//! nothing of the user's reachable (each Term is a session on the
//! private daemon).

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const snapshot = @import("../mux/snapshot.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;
const keys = @import("keys.zig");

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

pub const Error = error{
    SpawnFailed,
    NotConnected,
    Timeout,
    BadKey,
    OutOfMemory,
};

pub const CompletionSource = enum { none, shell_integration, process_tracking };

pub const CommandCompletion = struct {
    state: enum { unsupported, running, completed, unknown },
    exit_status: ?i32 = null,
    timed_out: bool = false,
    source: CompletionSource = .none,
};

pub const CommandToken = struct {
    completion_seq: u64,
};

/// Result of a sentinel-based exec (term_exec): structured completion
/// for commands run inside an EXISTING interactive shell, including
/// remote SSH sessions where OSC 133 integration cannot reach.
pub const ExecOutcome = struct {
    completed: bool,
    exit_status: ?i32 = null,
    timed_out: bool = false,
    /// Output between the sentinel markers (rendered lines; wrapped at
    /// the terminal width). Allocator-owned by the caller.
    output: []u8 = &.{},
    /// The begin marker scrolled out of the mirror's scrollback: the
    /// output is a TAIL, not the whole thing.
    truncated: bool = false,
    /// The terminal/shell itself died before the end marker.
    shell_died: bool = false,
};

const ExecPending = struct {
    nonce: [12]u8,
};

/// POSIX single-quote: wrap in '...', embedded ' becomes '\''.
fn posixSquote(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('\'');
    for (s) |ch| {
        if (ch == '\'') try w.writeAll("'\\''") else try w.writeByte(ch);
    }
    try w.writeByte('\'');
    return allocator.dupe(u8, aw.written());
}

/// Where a sentinel scan landed in the rendered text.
pub const SentinelParse = union(enum) {
    pending,
    done: struct { status: i32, start: usize, end: usize, truncated: bool },
};

/// Build the one-line command that brackets `command` with echo-safe
/// sentinel markers.
///
/// subshell=true (the robust default): the script travels base64-
/// encoded and runs under a fresh `sh` from a temp file — DIALECT-
/// INDEPENDENT (works typed into fish/zsh/bash/dash sessions alike,
/// local or over SSH) and shell state stays out of the session. The
/// pipeline uses only syntax every shell family shares (`|`, `>`,
/// `&&`, `;`) and the script always exits 0, so an active `set -e` in
/// the session never kills it.
///
/// subshell=false: the POSIX construction is typed directly so state
/// changes (cd/export/set) PERSIST in the session; needs a POSIX-ish
/// interactive shell (bash/zsh/dash — not fish). Marker strings are
/// quote-split in the typed text so the command echo can never be
/// mistaken for a marker; the `if` wrapper keeps a failing command
/// from tripping an active `set -e`.
pub fn buildExecLine(allocator: std.mem.Allocator, nonce: []const u8, command: []const u8, subshell: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    if (subshell) {
        // The command runs in a `sh -c` CHILD of the script's sh, so
        // an `exit`/`exec` in the command can only leave the child —
        // the end marker always prints with the child's real status.
        const quoted_cmd = try posixSquote(allocator, command);
        defer allocator.free(quoted_cmd);
        const script = try std.fmt.allocPrint(
            allocator,
            "printf '\\n%s\\n' SKB{s}\nsh -c {s}\n__sk_s=$?\nprintf '\\n%s%d\\n' SKE{s}. \"$__sk_s\"\n",
            .{ nonce, quoted_cmd, nonce },
        );
        defer allocator.free(script);
        const enc = std.base64.standard.Encoder;
        const b64 = try allocator.alloc(u8, enc.calcSize(script.len));
        defer allocator.free(b64);
        _ = enc.encode(b64, script);
        try w.print("echo {s} | base64 -d > /tmp/.sk_{s} && sh /tmp/.sk_{s}; rm -f /tmp/.sk_{s}", .{ b64, nonce, nonce, nonce });
        return allocator.dupe(u8, aw.written());
    }
    try w.print("printf '\\n%s\\n' SKB''{s}; if {{ {s}\n}}; then __sk_s=0; else __sk_s=$?; fi; printf '\\n%s%d\\n' SKE''{s}. \"$__sk_s\"", .{ nonce, command, nonce });
    return allocator.dupe(u8, aw.written());
}

/// Scan rendered terminal text (scrollback + screen) for the LAST
/// begin marker and its matching end marker. Markers sit on their own
/// lines (printed after \n) so line-exact matching is safe from wrap.
pub fn findSentinel(text: []const u8, nonce: []const u8) SentinelParse {
    var begin_after: ?usize = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var off: usize = 0;
    var end_line_start: ?usize = null;
    var status: i32 = 0;
    while (it.next()) |line| {
        const line_start = off;
        off += line.len + 1;
        const trimmed = std.mem.trimEnd(u8, line, " \r");
        if (trimmed.len == 3 + nonce.len and std.mem.startsWith(u8, trimmed, "SKB") and
            std.mem.eql(u8, trimmed[3..], nonce))
        {
            begin_after = @min(off, text.len);
            end_line_start = null;
            continue;
        }
        if (trimmed.len > 4 + nonce.len and std.mem.startsWith(u8, trimmed, "SKE") and
            std.mem.eql(u8, trimmed[3 .. 3 + nonce.len], nonce) and trimmed[3 + nonce.len] == '.')
        {
            const digits = trimmed[4 + nonce.len ..];
            const st = std.fmt.parseInt(i32, digits, 10) catch continue;
            status = st;
            end_line_start = line_start;
        }
    }
    if (end_line_start) |endpos| {
        const truncated = begin_after == null or begin_after.? > endpos;
        const start = if (truncated) 0 else begin_after.?;
        return .{ .done = .{ .status = status, .start = start, .end = endpos, .truncated = truncated } };
    }
    return .pending;
}

test "buildExecLine wraps and quote-splits markers" {
    const t = std.testing;
    const line = try buildExecLine(t.allocator, "aabbccddeeff", "echo hi", false);
    defer t.allocator.free(line);
    // The typed text never contains a contiguous marker string.
    try t.expect(std.mem.indexOf(u8, line, "SKBaabbccddeeff") == null);
    try t.expect(std.mem.indexOf(u8, line, "SKB''aabbccddeeff") != null);
    try t.expect(std.mem.indexOf(u8, line, "{ echo hi\n}") != null);
    // Subshell mode: dialect-independent base64 → sh transport, and
    // the decoded script carries the plain markers + set -e guard.
    const sub = try buildExecLine(t.allocator, "aabbccddeeff", "cd /tmp && pwd", true);
    defer t.allocator.free(sub);
    try t.expect(std.mem.startsWith(u8, sub, "echo "));
    try t.expect(std.mem.indexOf(u8, sub, "| base64 -d > /tmp/.sk_aabbccddeeff && sh /tmp/.sk_aabbccddeeff; rm -f /tmp/.sk_aabbccddeeff") != null);
    try t.expect(std.mem.indexOf(u8, sub, "SKBaabbccddeeff") == null); // only inside the b64 payload
    const b64 = sub["echo ".len..std.mem.indexOf(u8, sub, " |").?];
    const dec = std.base64.standard.Decoder;
    const buf = try t.allocator.alloc(u8, try dec.calcSizeForSlice(b64));
    defer t.allocator.free(buf);
    try dec.decode(buf, b64);
    try t.expect(std.mem.indexOf(u8, buf, "SKBaabbccddeeff") != null);
    try t.expect(std.mem.indexOf(u8, buf, "sh -c 'cd /tmp && pwd'\n__sk_s=$?") != null);
    try t.expect(std.mem.indexOf(u8, buf, "SKEaabbccddeeff.") != null);
    // Embedded single quotes survive the POSIX quoting.
    const q = try buildExecLine(t.allocator, "aabbccddeeff", "echo 'it''s'", true);
    defer t.allocator.free(q);
    const qb64 = q["echo ".len..std.mem.indexOf(u8, q, " |").?];
    const qbuf = try t.allocator.alloc(u8, try dec.calcSizeForSlice(qb64));
    defer t.allocator.free(qbuf);
    try dec.decode(qbuf, qb64);
    try t.expect(std.mem.indexOf(u8, qbuf, "sh -c 'echo '\\''it'\\'''\\''s'\\'''") != null);
}

test "findSentinel extracts output and status" {
    const t = std.testing;
    const nonce = "aabbccddeeff";
    const text = "$ printf ... SKB''aabbccddeeff; ...\nSKBaabbccddeeff\nhello\nworld\nSKEaabbccddeeff.3\n$ ";
    const r = findSentinel(text, nonce);
    try t.expect(r == .done);
    try t.expectEqual(@as(i32, 3), r.done.status);
    try t.expectEqualStrings("hello\nworld\n", text[r.done.start..r.done.end]);
    try t.expect(!r.done.truncated);
    // No end marker yet: pending.
    try t.expect(findSentinel("SKBaabbccddeeff\npartial", nonce) == .pending);
    // Begin marker scrolled away: truncated tail.
    const tail = findSentinel("late output\nSKEaabbccddeeff.0\n", nonce);
    try t.expect(tail == .done and tail.done.truncated);
    // The echoed quote-split typed text never matches.
    try t.expect(findSentinel("$ printf '\\n%s\\n' SKB''aabbccddeeff; if ...", nonce) == .pending);
}

pub const TokenResult = union(enum) {
    /// No shell integration was injected for this shell.
    unsupported,
    /// Integration is injected but no prompt mark has arrived within
    /// the wait — slow shell startup, or a shell whose rc files broke
    /// the injection. Retryable, unlike `unsupported`.
    not_ready,
    /// A foreground command (started outside command mode) is still
    /// between OSC 133 C and D; its D would be misattributed to a new
    /// command-mode send.
    busy,
    token: CommandToken,
};

var name_counter: u32 = 0;

pub const Term = struct {
    allocator: std.mem.Allocator,
    conn: muxclient.Conn,
    name: []u8,
    pool: *Pool,
    screen: ?*Screen = null,
    /// Highest snapshot/events seq seen — the quiescence signal.
    seq: u64 = 0,
    exited: bool = false,
    exit_status: i32 = 0,
    exit_status_known: bool = false,
    app_cursor: bool = false,
    integration: bool = false,
    /// One full-length first-prompt wait already expired with no mark:
    /// later commandToken calls fail fast instead of re-burning it.
    /// Never blocks success — a mark that shows up later still wins.
    prompt_wait_exhausted: bool = false,
    pending_command: ?CommandToken = null,
    pending_exec: ?ExecPending = null,

    /// Spawn a shell session on the daemon at `local_sock` (null = the
    /// shared per-user daemon) and attach. `argv` null = the login
    /// shell; non-null runs that argv.
    pub fn spawn(
        allocator: std.mem.Allocator,
        argv: ?[]const []const u8,
        cols: u16,
        rows: u16,
        local_sock: ?[]const u8,
    ) Error!*Term {
        var conn = muxclient.Conn.connectLocalAutostartAt(allocator, local_sock) catch return Error.SpawnFailed;
        errdefer conn.deinit();
        // Non-blocking + deadline recv everywhere: a wedged daemon
        // costs a bounded error, never a hung MCP tool call.
        conn.setNonBlocking();
        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.SpawnFailed;
        (conn.recvExpectFor(&.{.welcome}, 15_000) catch return Error.SpawnFailed).deinit(allocator);

        name_counter += 1;
        const name = std.fmt.allocPrint(allocator, "mcpterm-{d}-{d}", .{ c.getpid(), name_counter }) catch
            return Error.OutOfMemory;
        errdefer allocator.free(name);

        // Auto shell-integration, like a GUI pane would get: the OSC
        // 133 zones it injects are what powers term_run output_only.
        // The daemon is local (term tools are isolated-mode only), so
        // client-resolved script paths are valid on its host. With no
        // explicit argv the daemon spawns ITS $SHELL — same process
        // environment, so resolving against ours matches.
        const shellintegration = @import("../util/shellintegration.zig");
        const shell: []const u8 = if (argv) |av| av[0] else blk: {
            const sh = c.getenv("SHELL");
            break :blk if (sh != null) std.mem.span(@as([*:0]const u8, @ptrCast(sh))) else "/bin/sh";
        };
        const si = shellintegration.resolve(allocator, shell);
        defer if (si) |r| r.deinit(allocator);
        const SiWire = struct { kind: []const u8, script: []const u8, shim_dir: []const u8 };
        const si_wire: ?SiWire = if (si) |r| .{ .kind = r.kind, .script = r.script, .shim_dir = r.shim } else null;

        if (argv) |av| {
            conn.sendJson(.spawn, .{ .name = name, .argv = av, .rows = rows, .cols = cols, .shell_integration = si_wire }) catch return Error.SpawnFailed;
        } else {
            conn.sendJson(.spawn, .{ .name = name, .rows = rows, .cols = cols, .shell_integration = si_wire }) catch return Error.SpawnFailed;
        }
        (conn.recvExpectFor(&.{.ok}, 15_000) catch return Error.SpawnFailed).deinit(allocator);
        conn.sendJson(.attach, .{ .name = name, .kind = "mcp" }) catch return Error.SpawnFailed;
        const snap = conn.recvExpectFor(&.{.snapshot}, 15_000) catch return Error.SpawnFailed;
        defer snap.deinit(allocator);

        const pool = allocator.create(Pool) catch return Error.OutOfMemory;
        errdefer allocator.destroy(pool);
        pool.* = Pool.init(allocator) catch return Error.OutOfMemory;
        errdefer pool.deinit();
        const self = allocator.create(Term) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator, .conn = conn, .name = name, .pool = pool, .integration = si != null };
        self.applySnapshot(snap.payload) catch {};
        return self;
    }

    pub fn deinit(self: *Term) void {
        const a = self.allocator;
        if (!self.exited) self.conn.sendJson(.kill, .{ .name = self.name }) catch {};
        self.conn.deinit();
        if (self.screen) |s| s.deinit();
        self.pool.deinit();
        a.destroy(self.pool);
        a.free(self.name);
        a.destroy(self);
    }

    fn applySnapshot(self: *Term, payload: []const u8) !void {
        if (payload.len < 9) return error.Truncated; // [seq:u64][app:u8]
        self.seq = std.mem.readInt(u64, payload[0..8], .little);
        if (self.screen) |s| s.deinit();
        self.screen = null;
        self.pool.deinit();
        self.pool.* = try Pool.init(self.allocator);
        self.screen = try snapshot.restore(self.allocator, self.pool, payload[9..]);
        if (self.screen) |s| self.app_cursor = s.app_cursor_keys;
    }

    fn applyEvents(self: *Term, payload: []const u8) void {
        if (payload.len < 12) return;
        const base = std.mem.readInt(u64, payload[0..8], .little);
        const n = std.mem.readInt(u32, payload[8..12], .little);
        const screen = self.screen orelse return;
        var r = wire.Reader.init(payload[12..]);
        while (!r.atEnd()) {
            var ev = r.getEvent(self.allocator) catch break;
            screen.apply(ev);
            ev.deinit(self.allocator);
        }
        self.app_cursor = screen.app_cursor_keys;
        self.seq = base + n;
    }

    fn handleFrame(self: *Term, ftype: wire.FrameType, payload: []const u8) void {
        switch (ftype) {
            .snapshot => self.applySnapshot(payload) catch {},
            .events => self.applyEvents(payload),
            .exit => {
                self.exited = true;
                if (payload.len >= 4) {
                    self.exit_status = std.mem.readInt(i32, payload[0..4], .little);
                    self.exit_status_known = true;
                }
            },
            .gone => self.exited = true,
            else => {},
        }
    }

    fn pollIn(fd: c_int, ms: i32) bool {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        return c.poll(&pfd, 1, ms) > 0 and (pfd.revents & (c.POLLIN | c.POLLHUP)) != 0;
    }

    /// Process at most one COMPLETE queued frame, waiting up to
    /// `wait_ms`. Never blocks past that: a readable fd does not mean
    /// a whole frame arrived, so this peels from the buffer instead
    /// of calling recvFrame (whose read() would park on a frame tail
    /// a wedged daemon never sends).
    pub fn pumpOnce(self: *Term, wait_ms: i32) bool {
        if (self.exited) return false;
        if (self.takeOne()) return true;
        if (!pollIn(self.conn.fd, wait_ms)) return false;
        if (!self.conn.fillAvailable()) {
            self.exited = true;
            return false;
        }
        return self.takeOne();
    }

    fn takeOne(self: *Term) bool {
        const f = (self.conn.takeFrame() catch {
            self.exited = true;
            return false;
        }) orelse return false;
        defer f.deinit(self.allocator);
        self.handleFrame(f.ftype, f.payload);
        return true;
    }

    /// Time-boxed like appdrive.drain: a flooding shell (`cat` of a
    /// huge file) must not wedge the single-threaded MCP loop.
    pub fn drain(self: *Term) void {
        const deadline = nowMs() + 100;
        while (self.pumpOnce(0)) {
            if (nowMs() >= deadline) break;
        }
    }

    /// Raw bytes to the shell's PTY.
    pub fn sendText(self: *Term, text: []const u8) Error!void {
        if (self.exited) return Error.NotConnected;
        self.conn.sendFrame(.input, text) catch return Error.NotConnected;
    }

    /// Named-key chords ("ctrl+c", "enter", "up", ...), space-separated.
    pub fn sendKeys(self: *Term, chords: []const u8) Error!void {
        self.drain(); // refresh app_cursor from any pending events
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        keys.encode(&out, self.allocator, chords, self.app_cursor) catch return Error.BadKey;
        self.conn.sendFrame(.input, out.items) catch return Error.NotConnected;
    }

    /// Ask the daemon to record this session as an asciicast v2 file
    /// at `path` (on the daemon's host). Fire-and-forget: the ok/err
    /// reply rides the frame stream and is ignored by handleFrame, so
    /// a bad path just means no file appears. The daemon finalizes
    /// the cast when the session ends and fflushes per event, so the
    /// file is replayable at any point.
    pub fn startRecording(self: *Term, path: []const u8) void {
        if (self.exited) return;
        self.conn.sendJson(.rec_start, .{ .path = path }) catch {};
    }

    pub fn resize(self: *Term, cols: u16, rows: u16) Error!void {
        if (self.exited) return Error.NotConnected;
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], rows, .little);
        std.mem.writeInt(u16, buf[2..4], cols, .little);
        self.conn.sendFrame(.resize, &buf) catch return Error.NotConnected;
    }

    /// Output + exit code of the last COMPLETED command (OSC 133
    /// zone, mirrored from the daemon's event stream). Null when no
    /// zone exists yet (shell integration off, or nothing ran).
    /// Caller owns `.text`.
    pub fn lastCommand(self: *Term) Error!?struct { text: []u8, exit: i32 } {
        self.drain();
        const screen = self.screen orelse return Error.NotConnected;
        const text = (screen.extractLastCommandOutput(self.allocator) catch return Error.OutOfMemory) orelse
            return null;
        return .{ .text = text, .exit = screen.last_cmd_exit };
    }

    fn commandTokenFor(screen: *const Screen) CommandToken {
        return .{ .completion_seq = screen.cmd_completion_seq };
    }

    /// Capture the completed-zone baseline for a command-mode send.
    /// Integration was injected at spawn but the first prompt may not
    /// have rendered yet on a freshly opened terminal, so this waits
    /// (bounded by `wait_ms`) for the first OSC 133 prompt mark
    /// instead of misreporting a race as unsupported.
    pub fn commandToken(self: *Term, wait_ms: i64) Error!TokenResult {
        self.drain();
        if (self.exited) return Error.NotConnected;
        if (self.screen == null) return Error.NotConnected;
        if (!self.integration) return .unsupported;
        const deadline = nowMs() + wait_ms;
        while (true) {
            // Re-fetch each pass: a resync snapshot swaps self.screen.
            const screen = self.screen orelse return Error.NotConnected;
            if (screen.prompt_marks_len > 0) break;
            if (self.exited) return Error.NotConnected;
            if (self.prompt_wait_exhausted or nowMs() >= deadline) {
                self.prompt_wait_exhausted = true;
                return .not_ready;
            }
            _ = self.pumpOnce(50);
        }
        // A raw send's Enter races its OSC 133 C mark: settle briefly
        // so an in-flight command surfaces before the busy judgment,
        // or its D would complete the new command-mode wait.
        _ = self.waitIdle(100, 500);
        if (self.exited) return Error.NotConnected;
        const screen = self.screen orelse return Error.NotConnected;
        if (screen.pending_output_start_id != 0 or screen.pending_output_awaits_nl)
            return .busy;
        return .{ .token = commandTokenFor(screen) };
    }

    pub fn trackCommand(self: *Term, token: CommandToken) void {
        self.pending_command = token;
    }

    pub fn hasPendingCommand(self: *const Term) bool {
        return self.pending_command != null;
    }

    /// Wait for a new OSC 133 command zone or a tracked shell-process exit.
    pub fn waitCommand(self: *Term, token: CommandToken, timeout_ms: i64) CommandCompletion {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            _ = self.pumpOnce(50);
            if (self.screen) |screen| {
                const current = commandTokenFor(screen);
                if (!std.meta.eql(token, current)) {
                    self.pending_command = null;
                    return .{
                        .state = .completed,
                        .exit_status = screen.last_cmd_exit,
                        .source = .shell_integration,
                    };
                }
            }
            if (self.exited) {
                if (self.exit_status_known) {
                    self.pending_command = null;
                    return .{
                        .state = .completed,
                        .exit_status = self.exit_status,
                        .source = .process_tracking,
                    };
                }
                self.pending_command = null;
                return .{ .state = .unknown };
            }
            if (nowMs() >= deadline) {
                // Nothing completed: no source to attribute.
                return .{
                    .state = .running,
                    .timed_out = true,
                    .source = .none,
                };
            }
        }
    }

    pub fn waitPendingCommand(self: *Term, timeout_ms: i64) ?CommandCompletion {
        const token = self.pending_command orelse return null;
        return self.waitCommand(token, timeout_ms);
    }

    /// Block until the terminal's child process exits (or timeout).
    /// Returns true when it exited; exit_status/exit_status_known then
    /// carry the result.
    pub fn waitExit(self: *Term, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (!self.exited) {
            if (nowMs() >= deadline) return false;
            _ = self.pumpOnce(50);
        }
        return true;
    }

    pub fn hasPendingExec(self: *const Term) bool {
        return self.pending_exec != null;
    }

    /// Sentinel-based structured exec inside the LIVE interactive
    /// shell (works over SSH, where OSC 133 integration cannot reach).
    /// On timeout the sentinel stays pending; continue with
    /// waitExecResult. Caller frees `.output`.
    pub fn execCommand(self: *Term, command: []const u8, subshell: bool, timeout_ms: i64) Error!ExecOutcome {
        self.drain();
        if (self.exited) return Error.NotConnected;
        if (self.pending_exec != null) return Error.BadKey; // caller checks hasPendingExec first
        var pend: ExecPending = undefined;
        var raw: [6]u8 = undefined;
        if (c.getentropy(&raw, raw.len) != 0) return Error.SpawnFailed;
        const hex = "0123456789abcdef";
        for (raw, 0..) |b, i| {
            pend.nonce[i * 2] = hex[b >> 4];
            pend.nonce[i * 2 + 1] = hex[b & 0xf];
        }
        const line = buildExecLine(self.allocator, &pend.nonce, command, subshell) catch return Error.OutOfMemory;
        defer self.allocator.free(line);
        const with_cr = std.fmt.allocPrint(self.allocator, "{s}\r", .{line}) catch return Error.OutOfMemory;
        defer self.allocator.free(with_cr);
        try self.sendText(with_cr);
        self.pending_exec = pend;
        return self.waitExecResult(timeout_ms) orelse Error.NotConnected;
    }

    /// Continue waiting for a pending exec sentinel. Null when none is
    /// pending. Caller frees `.output`.
    pub fn waitExecResult(self: *Term, timeout_ms: i64) ?ExecOutcome {
        const pend = self.pending_exec orelse return null;
        const deadline = nowMs() + timeout_ms;
        while (true) {
            _ = self.pumpOnce(50);
            // Scan at a coarse cadence: extracting the whole
            // scrollback per pump would hurt under output floods.
            const text = blk: {
                const screen = self.screen orelse break :blk null;
                break :blk screen.extractScrollback(self.allocator) catch null;
            };
            if (text) |t| {
                defer self.allocator.free(t);
                switch (findSentinel(t, &pend.nonce)) {
                    .done => |d| {
                        self.pending_exec = null;
                        const out = self.allocator.dupe(u8, t[d.start..d.end]) catch &[_]u8{};
                        return .{
                            .completed = true,
                            .exit_status = d.status,
                            .output = @constCast(out),
                            .truncated = d.truncated,
                        };
                    },
                    .pending => {},
                }
            }
            if (self.exited) {
                self.pending_exec = null;
                return .{ .completed = false, .shell_died = true, .exit_status = if (self.exit_status_known) self.exit_status else null };
            }
            if (nowMs() >= deadline) {
                return .{ .completed = false, .timed_out = true };
            }
            // Pace the scrollback scans.
            var waited: i64 = 0;
            while (waited < 100 and nowMs() < deadline) {
                if (self.pumpOnce(50)) {} else waited += 50;
                if (self.exited) break;
            }
        }
    }

    /// Rendered screen text (drains pending events first).
    pub fn readScreen(self: *Term, scrollback: bool) Error![]u8 {
        self.drain();
        const screen = self.screen orelse return Error.NotConnected;
        return (if (scrollback)
            screen.extractScrollback(self.allocator)
        else
            screen.extractScreen(self.allocator)) catch Error.OutOfMemory;
    }

    /// Block until output is quiet; this does not imply the foreground command exited.
    pub fn waitIdle(self: *Term, quiet_ms: i64, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        var last_seq = self.seq;
        var last_change = nowMs();
        while (true) {
            _ = self.pumpOnce(50);
            const now = nowMs();
            if (self.seq != last_seq) {
                last_seq = self.seq;
                last_change = now;
            }
            if (self.exited) return true;
            if (now - last_change >= quiet_ms) return true;
            if (now >= deadline) return false;
        }
    }
};
