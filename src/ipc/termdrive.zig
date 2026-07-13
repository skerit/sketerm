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
    app_cursor: bool = false,

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
        pool.* = Pool.init(allocator) catch {
            allocator.destroy(pool);
            return Error.OutOfMemory;
        };
        const self = allocator.create(Term) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator, .conn = conn, .name = name, .pool = pool };
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
                if (payload.len >= 4) self.exit_status = std.mem.readInt(i32, payload[0..4], .little);
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

    /// Rendered screen text (drains pending events first).
    pub fn readScreen(self: *Term, scrollback: bool) Error![]u8 {
        self.drain();
        const screen = self.screen orelse return Error.NotConnected;
        return (if (scrollback)
            screen.extractScrollback(self.allocator)
        else
            screen.extractScreen(self.allocator)) catch Error.OutOfMemory;
    }

    /// Block until `quiet_ms` passes with no new events, or `timeout_ms`
    /// elapses. Returns true if it settled (false = timed out / exited).
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
