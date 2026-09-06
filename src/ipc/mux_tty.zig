//! In-terminal attach: show a mux session inside whatever terminal
//! `sketerm mux` runs in, tmux-style.
//!
//! The GUI is the normal viewer, but it is not always available (a
//! plain VT, another terminal emulator, an ssh client). This is the
//! fallback: raw tty, a local `Screen` mirror fed from the daemon's
//! snapshot + event stream, and `mux/ttyrender.zig` diffing it onto
//! the host. Keys go to the session unchanged except for the one
//! prefix chord (`Ctrl-\`), which is how a person leaves WITHOUT
//! ending the session: detaching never kills anything, only the
//! shell exiting does.
//!
//! GTK-free; `in_fd`/`out_fd` are parameters so the whole loop runs
//! over a socketpair in the mux smoke without any pty.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const clock = @import("../util/clock.zig");
const mux_client = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const snapshot = @import("../mux/snapshot.zig");
const ttyrender = @import("../mux/ttyrender.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Event = @import("../parser/event.zig").Event;

/// `Ctrl-\`: SIGQUIT's key on a cooked tty, which nothing interactive
/// wants, and easy to hit twice.
pub const PREFIX: u8 = 0x1c;

pub const HINT =
    "sketerm mux: detach with Ctrl-\\ Ctrl-\\ (or Ctrl-\\ d) -- the session keeps running.\n" ++
    "             Ctrl-\\ [ scrolls back (q returns); Ctrl-\\ \\ sends a literal Ctrl-\\.\n";

pub const Outcome = enum {
    /// The person detached (or the terminal went away); the session lives on.
    detached,
    /// The session's child exited or the session was killed.
    exited,
    /// The daemon connection died.
    lost,
    /// Attach itself was refused (no such session, bad snapshot).
    failed,
};

pub const Options = struct {
    in_fd: c_int = 0,
    out_fd: c_int = 1,
    read_only: bool = false,
    control: bool = false,
    /// Grid when `out_fd` is not a terminal (tests); a tty's own size wins.
    fixed_size: ?Size = null,
    /// Skip the hint line and the outcome line on stderr.
    quiet: bool = false,
    /// Install SIGWINCH/SIGTERM/SIGHUP handlers for the duration.
    signals: bool = true,
};

pub const Size = struct { cols: u16, rows: u16 };

pub const Command = union(enum) {
    detach,
    scroll_enter,
    scroll_leave,
    /// Positive = older (up).
    scroll_lines: i32,
    /// Positive = older (up), in pages.
    scroll_pages: i32,
    scroll_top,
    scroll_bottom,
};

/// The prefix-chord state machine over raw input bytes. Pass-through
/// bytes land in `pass`; recognised chords come back as commands.
pub const Filter = struct {
    prefix: bool = false,
    scrolling: bool = false,
    cmds: [16]Command = undefined,
    n: usize = 0,

    fn push(self: *Filter, cmd: Command) void {
        if (self.n < self.cmds.len) {
            self.cmds[self.n] = cmd;
            self.n += 1;
        }
    }

    pub fn feed(self: *Filter, allocator: std.mem.Allocator, bytes: []const u8, pass: *std.ArrayList(u8)) ![]const Command {
        self.n = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (self.prefix) {
                self.prefix = false;
                switch (b) {
                    PREFIX, 'd', 'D' => self.push(.detach),
                    '\\' => if (!self.scrolling) try pass.append(allocator, PREFIX),
                    '[' => if (!self.scrolling) {
                        self.scrolling = true;
                        self.push(.scroll_enter);
                    },
                    else => {
                        // Not a chord: the prefix was a stray press. Give
                        // the key back to the session (page keys after the
                        // prefix open scrollback instead).
                        if (std.mem.startsWith(u8, bytes[i..], "\x1b[5~")) {
                            if (!self.scrolling) {
                                self.scrolling = true;
                                self.push(.scroll_enter);
                            }
                            self.push(.{ .scroll_pages = 1 });
                            i += 4;
                            continue;
                        }
                        if (!self.scrolling) try pass.append(allocator, b);
                    },
                }
                i += 1;
                continue;
            }
            if (b == PREFIX) {
                self.prefix = true;
                i += 1;
                continue;
            }
            if (self.scrolling) {
                i += self.scrollKey(bytes[i..]);
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, bytes, i, PREFIX) orelse bytes.len;
            try pass.appendSlice(allocator, bytes[i..end]);
            i = end;
        }
        return self.cmds[0..self.n];
    }

    const ScrollKey = struct { seq: []const u8, cmd: Command };
    const scroll_keys = [_]ScrollKey{
        .{ .seq = "\x1b[5~", .cmd = .{ .scroll_pages = 1 } },
        .{ .seq = "\x1b[6~", .cmd = .{ .scroll_pages = -1 } },
        .{ .seq = "\x1b[A", .cmd = .{ .scroll_lines = 1 } },
        .{ .seq = "\x1bOA", .cmd = .{ .scroll_lines = 1 } },
        .{ .seq = "\x1b[B", .cmd = .{ .scroll_lines = -1 } },
        .{ .seq = "\x1bOB", .cmd = .{ .scroll_lines = -1 } },
        .{ .seq = "\x1b[H", .cmd = .scroll_top },
        .{ .seq = "\x1b[1~", .cmd = .scroll_top },
        .{ .seq = "\x1bOH", .cmd = .scroll_top },
        .{ .seq = "\x1b[F", .cmd = .scroll_bottom },
        .{ .seq = "\x1b[4~", .cmd = .scroll_bottom },
        .{ .seq = "\x1bOF", .cmd = .scroll_bottom },
        .{ .seq = "k", .cmd = .{ .scroll_lines = 1 } },
        .{ .seq = "j", .cmd = .{ .scroll_lines = -1 } },
        .{ .seq = "u", .cmd = .{ .scroll_pages = 1 } },
        .{ .seq = "d", .cmd = .{ .scroll_pages = -1 } },
        .{ .seq = " ", .cmd = .{ .scroll_pages = -1 } },
        .{ .seq = "b", .cmd = .{ .scroll_pages = 1 } },
        .{ .seq = "g", .cmd = .scroll_top },
        .{ .seq = "G", .cmd = .scroll_bottom },
        .{ .seq = "q", .cmd = .scroll_leave },
        .{ .seq = "\r", .cmd = .scroll_leave },
        .{ .seq = "\x1b", .cmd = .scroll_leave },
    };

    /// Consume one key in scroll mode; returns the bytes eaten.
    fn scrollKey(self: *Filter, rest: []const u8) usize {
        // SGR mouse wheel from a host that reports the mouse (the
        // session asked for it): 64 = up, 65 = down.
        if (std.mem.startsWith(u8, rest, "\x1b[<")) {
            const end = std.mem.indexOfAnyPos(u8, rest, 3, "Mm") orelse return rest.len;
            if (std.mem.startsWith(u8, rest[3..], "64;")) self.push(.{ .scroll_lines = 3 });
            if (std.mem.startsWith(u8, rest[3..], "65;")) self.push(.{ .scroll_lines = -3 });
            return end + 1;
        }
        for (scroll_keys) |k| {
            if (k.seq.len == 1 and k.seq[0] == 0x1b) continue;
            if (std.mem.startsWith(u8, rest, k.seq)) {
                self.apply(k.cmd);
                return k.seq.len;
            }
        }
        // A lone Escape (no sequence following in the same read) leaves.
        if (rest[0] == 0x1b and rest.len == 1) {
            self.apply(.scroll_leave);
            return 1;
        }
        return 1;
    }

    fn apply(self: *Filter, cmd: Command) void {
        if (cmd == .scroll_leave) self.scrolling = false;
        self.push(cmd);
    }
};

// ── signal plumbing ───────────────────────────────────────────

var g_wake: platform.Wakeup = .{ .read_fd = -1, .write_fd = -1 };
var g_quit: bool = false;

const Signal = @TypeOf(std.posix.SIG.WINCH);

fn onSignal(sig: Signal) callconv(.c) void {
    if (sig != std.posix.SIG.WINCH) @atomicStore(bool, &g_quit, true, .seq_cst);
    if (g_wake.read_fd >= 0) g_wake.signal();
}

const Signals = struct {
    old: [sigs.len]std.posix.Sigaction = undefined,
    installed: bool = false,

    const sigs = [_]Signal{ std.posix.SIG.WINCH, std.posix.SIG.TERM, std.posix.SIG.HUP };

    fn install(self: *Signals) void {
        const action = std.posix.Sigaction{
            .handler = .{ .handler = &onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        for (sigs, 0..) |sig, i| std.posix.sigaction(sig, &action, &self.old[i]);
        self.installed = true;
    }

    fn restore(self: *Signals) void {
        if (!self.installed) return;
        for (sigs, 0..) |sig, i| std.posix.sigaction(sig, &self.old[i], null);
        self.installed = false;
    }
};

// ── tty plumbing ──────────────────────────────────────────────

const Tty = struct {
    fd: c_int,
    orig: c.struct_termios = undefined,
    raw: bool = false,

    fn enter(fd: c_int) Tty {
        var self: Tty = .{ .fd = fd };
        if (c.isatty(fd) == 0) return self;
        if (c.tcgetattr(fd, &self.orig) != 0) return self;
        var raw = self.orig;
        c.cfmakeraw(&raw);
        raw.c_cc[c.VMIN] = 1;
        raw.c_cc[c.VTIME] = 0;
        if (c.tcsetattr(fd, c.TCSANOW, &raw) == 0) self.raw = true;
        return self;
    }

    fn leave(self: *Tty) void {
        if (!self.raw) return;
        _ = c.tcsetattr(self.fd, c.TCSANOW, &self.orig);
        self.raw = false;
    }
};

fn querySize(fd: c_int, fallback: ?Size) Size {
    var ws: c.struct_winsize = undefined;
    if (c.isatty(fd) != 0 and c.ioctl(fd, c.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0)
        return .{ .cols = ws.ws_col, .rows = ws.ws_row };
    return fallback orelse .{ .cols = 80, .rows = 24 };
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        const e = std.posix.errno(n);
        if (e == .INTR) continue;
        if (e == .AGAIN) {
            var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
            _ = c.poll(&pfd, 1, 1000);
            continue;
        }
        return;
    }
}

fn flush(fd: c_int, buf: *std.ArrayList(u8)) void {
    if (buf.items.len == 0) return;
    writeAll(fd, buf.items);
    buf.clearRetainingCapacity();
}

fn sendResize(conn: *mux_client.Conn, size: Size) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], size.rows, .little);
    std.mem.writeInt(u16, buf[2..4], size.cols, .little);
    try conn.queueFrame(.resize, &buf);
}

fn applyEvent(screen: *Screen, ev: Event) void {
    screen.apply(ev);
}

fn msg(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeAll(2, text);
}

// ── the attach loop ───────────────────────────────────────────

const Viewer = struct {
    allocator: std.mem.Allocator,
    conn: *mux_client.Conn,
    name: []const u8,
    opts: Options,
    mirror: snapshot.OwnedRestore,
    seq: u64,
    renderer: ttyrender.Renderer,
    out: std.ArrayList(u8) = .empty,
    filter: Filter = .{},
    size: Size,
    need_render: bool = true,
    /// Set when a frame ended the session; the loop exits after it.
    outcome: ?Outcome = null,
    exit_status: ?i32 = null,
    /// The daemon's last `.err` text, shown after the tty is restored.
    last_err: [192]u8 = undefined,
    last_err_len: usize = 0,

    fn attachOpts(self: *const Viewer) mux_client.AttachOptions {
        return .{ .kind = "cli", .read_only = self.opts.read_only, .control = self.opts.control };
    }

    fn replaceMirror(self: *Viewer, payload: []const u8) bool {
        const fresh = snapshot.restoreOwned(self.allocator, payload) catch return false;
        self.mirror.deinit(self.allocator);
        self.mirror = fresh;
        self.mirror.screen.mute_responses = true;
        self.seq = fresh.seq;
        self.renderer.invalidate();
        self.need_render = true;
        return true;
    }

    /// Detach + attach on the same connection: the daemon answers every
    /// attach with a snapshot, which is the resync.
    fn resync(self: *Viewer) void {
        const conn = self.conn;
        conn.sendFrame(.detach, "") catch return self.lost();
        (conn.recvExpectFor(&.{.ok}, 5_000) catch return self.lost()).deinit(self.allocator);
        conn.sendAttach(self.name, self.attachOpts()) catch return self.lost();
        const snap = conn.recvExpectFor(&.{.snapshot}, 15_000) catch return self.lost();
        defer snap.deinit(self.allocator);
        if (!self.replaceMirror(snap.payload)) self.lost();
    }

    fn lost(self: *Viewer) void {
        if (self.outcome == null) self.outcome = .lost;
    }

    fn handleFrame(self: *Viewer, f: mux_client.Conn.OwnedFrame) void {
        switch (f.ftype) {
            .snapshot => {
                if (!self.replaceMirror(f.payload)) self.lost();
            },
            .events => {
                self.seq = wire.applyEventFrame(f.payload, self.seq, self.allocator, self.mirror.screen, applyEvent) catch {
                    self.resync();
                    return;
                };
                self.need_render = true;
            },
            .exit => {
                if (f.payload.len >= 4) self.exit_status = std.mem.readInt(i32, f.payload[0..4], .little);
                self.outcome = .exited;
            },
            .gone => self.outcome = .exited,
            .err => {
                const n = @min(f.payload.len, self.last_err.len);
                @memcpy(self.last_err[0..n], f.payload[0..n]);
                self.last_err_len = n;
            },
            else => {},
        }
    }

    fn drainConn(self: *Viewer) void {
        if (!self.conn.fillAvailable()) return self.lost();
        while (self.outcome == null) {
            const f = (self.conn.takeFrame() catch return self.lost()) orelse break;
            defer f.deinit(self.allocator);
            self.handleFrame(f);
        }
    }

    fn scrollBy(self: *Viewer, lines: i64) void {
        const total: i64 = self.mirror.screen.scrollbackCount();
        const cur: i64 = self.renderer.view_offset;
        const next = @max(0, @min(total, cur + lines));
        self.renderer.view_offset = @intCast(next);
        self.need_render = true;
    }

    fn runCommand(self: *Viewer, cmd: Command) void {
        const page: i64 = @max(1, @as(i64, self.size.rows) - 1);
        switch (cmd) {
            .detach => self.outcome = .detached,
            .scroll_enter => {
                self.renderer.scroll_mode = true;
                self.need_render = true;
            },
            .scroll_leave => {
                self.renderer.scroll_mode = false;
                self.renderer.view_offset = 0;
                self.need_render = true;
            },
            .scroll_lines => |n| self.scrollBy(n),
            .scroll_pages => |n| self.scrollBy(@as(i64, n) * page),
            .scroll_top => self.scrollBy(std.math.maxInt(i32)),
            .scroll_bottom => self.scrollBy(-std.math.maxInt(i32)),
        }
    }

    fn handleInput(self: *Viewer, bytes: []const u8) void {
        var pass: std.ArrayList(u8) = .empty;
        defer pass.deinit(self.allocator);
        const cmds = self.filter.feed(self.allocator, bytes, &pass) catch return;
        if (pass.items.len > 0 and !self.opts.read_only) {
            self.conn.queueFrame(.input, pass.items) catch return self.lost();
        }
        for (cmds) |cmd| self.runCommand(cmd);
    }

    fn checkSize(self: *Viewer) void {
        const now = querySize(self.opts.out_fd, self.opts.fixed_size);
        if (now.cols == self.size.cols and now.rows == self.size.rows) return;
        self.size = now;
        self.renderer.resize(now.cols, now.rows) catch return self.lost();
        sendResize(self.conn, now) catch return self.lost();
        self.need_render = true;
    }

    fn render(self: *Viewer) void {
        self.renderer.render(&self.out, self.mirror.screen) catch return;
        flush(self.opts.out_fd, &self.out);
        self.need_render = false;
    }

    fn loop(self: *Viewer) void {
        // A sync-output window (DECSET 2026) left open by a wedged app
        // must not freeze the view: render anyway after this long.
        const SYNC_CAP_MS: i64 = 150;
        var sync_since: ?i64 = null;
        while (self.outcome == null) {
            if (@atomicLoad(bool, &g_quit, .seq_cst)) {
                self.outcome = .detached;
                break;
            }
            if (self.need_render) {
                var held = false;
                if (self.mirror.screen.sync_output) {
                    const since = sync_since orelse clock.nowMs();
                    sync_since = since;
                    held = clock.nowMs() - since < SYNC_CAP_MS;
                }
                if (!held) {
                    self.render();
                    sync_since = null;
                }
            }
            const conn_events: c_short = @intCast(if (self.conn.wbuf.items.len > 0) c.POLLIN | c.POLLOUT else c.POLLIN);
            var fds = [_]c.struct_pollfd{
                .{ .fd = self.opts.in_fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.conn.fd, .events = conn_events, .revents = 0 },
                .{ .fd = g_wake.read_fd, .events = c.POLLIN, .revents = 0 },
            };
            const timeout: c_int = if (self.need_render) 50 else -1;
            const r = c.poll(&fds, fds.len, timeout);
            if (r < 0) {
                if (std.posix.errno(r) == .INTR) continue;
                self.lost();
                break;
            }
            if (r == 0) continue;
            if (fds[2].revents & c.POLLIN != 0) {
                var scratch: [64]u8 = undefined;
                _ = c.read(g_wake.read_fd, &scratch, scratch.len);
                self.checkSize();
            }
            if (fds[1].revents & c.POLLOUT != 0) self.conn.flushQueued() catch self.lost();
            if (fds[1].revents & (c.POLLIN | c.POLLHUP) != 0) self.drainConn();
            if (fds[1].revents & (c.POLLERR | c.POLLNVAL) != 0) self.lost();
            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
                var buf: [4096]u8 = undefined;
                const n = c.read(self.opts.in_fd, &buf, buf.len);
                if (n > 0) {
                    self.handleInput(buf[0..@intCast(n)]);
                } else if (n == 0 or std.posix.errno(n) != .AGAIN) {
                    // The host terminal went away: the session must not.
                    if (self.outcome == null) self.outcome = .detached;
                }
            }
            if (fds[0].revents & (c.POLLERR | c.POLLNVAL) != 0 and self.outcome == null) self.outcome = .detached;
        }
    }
};

/// Attach `name` on `conn` (hello already exchanged) and show it on
/// `in_fd`/`out_fd` until detached, exited or lost. `conn` is left
/// connected (the caller closes it).
pub fn attach(allocator: std.mem.Allocator, conn: *mux_client.Conn, name: []const u8, opts: Options) Outcome {
    conn.sendAttach(name, .{ .kind = "cli", .read_only = opts.read_only, .control = opts.control }) catch return .failed;
    const snap = conn.recvExpectFor(&.{.snapshot}, 15_000) catch {
        const why = conn.lastErr();
        if (why.len > 0) {
            msg("sketerm mux: cannot attach '{s}': {s}\n", .{ name, why });
        } else {
            msg("sketerm mux: no such session '{s}'\n", .{name});
        }
        return .failed;
    };
    defer snap.deinit(allocator);
    const mirror = snapshot.restoreOwned(allocator, snap.payload) catch {
        msg("sketerm mux: bad snapshot for '{s}' (daemon/client version skew?)\n", .{name});
        return .failed;
    };
    mirror.screen.mute_responses = true;

    if (!opts.quiet) writeAll(2, HINT);

    var tty = Tty.enter(opts.in_fd);
    defer tty.leave();
    const size = querySize(opts.out_fd, opts.fixed_size);

    var viewer: Viewer = .{
        .allocator = allocator,
        .conn = conn,
        .name = name,
        .opts = opts,
        .mirror = mirror,
        .seq = mirror.seq,
        .renderer = ttyrender.Renderer.init(allocator, size.cols, size.rows) catch {
            mirror.deinit(allocator);
            return .failed;
        },
        .size = size,
    };
    defer viewer.mirror.deinit(allocator);
    defer viewer.renderer.deinit();
    defer viewer.out.deinit(allocator);

    const wake = platform.Wakeup.init() catch return .failed;
    g_wake = wake;
    @atomicStore(bool, &g_quit, false, .seq_cst);
    var signals: Signals = .{};
    if (opts.signals) signals.install();
    defer {
        signals.restore();
        g_wake = .{ .read_fd = -1, .write_fd = -1 };
        wake.close();
    }

    conn.setNonBlocking();
    viewer.renderer.enter(&viewer.out) catch return .failed;
    flush(opts.out_fd, &viewer.out);
    if (mirror.screen.cols != size.cols or mirror.screen.rows != size.rows)
        sendResize(conn, size) catch viewer.lost();

    viewer.loop();
    const outcome = viewer.outcome orelse .lost;

    if (outcome == .detached) {
        conn.sendFrame(.detach, "") catch {};
        if (conn.recvExpectFor(&.{.ok}, 2_000)) |f| f.deinit(allocator) else |_| {}
    }
    viewer.renderer.leave(&viewer.out) catch {};
    flush(opts.out_fd, &viewer.out);
    tty.leave();

    if (!opts.quiet) {
        switch (outcome) {
            .detached => msg("sketerm mux: detached from '{s}' (still running)\n", .{name}),
            .exited => if (viewer.exit_status) |st|
                msg("sketerm mux: session '{s}' ended (exit status {d})\n", .{ name, st })
            else
                msg("sketerm mux: session '{s}' ended\n", .{name}),
            .lost => msg("sketerm mux: connection to the daemon lost while viewing '{s}'\n", .{name}),
            .failed => {},
        }
        if (viewer.last_err_len > 0)
            msg("sketerm mux: daemon said: {s}\n", .{viewer.last_err[0..viewer.last_err_len]});
    }
    return outcome;
}

// ── tests ──────────────────────────────────────────────────────

const testing = std.testing;

fn feedFilter(f: *Filter, bytes: []const u8, pass: *std.ArrayList(u8)) ![]const Command {
    return f.feed(testing.allocator, bytes, pass);
}

test "Filter: plain bytes pass through, the double prefix detaches" {
    var f: Filter = .{};
    var pass: std.ArrayList(u8) = .empty;
    defer pass.deinit(testing.allocator);
    var cmds = try feedFilter(&f, "ls -la\r", &pass);
    try testing.expectEqual(@as(usize, 0), cmds.len);
    try testing.expectEqualStrings("ls -la\r", pass.items);

    pass.clearRetainingCapacity();
    cmds = try feedFilter(&f, "ab\x1c\x1c", &pass);
    try testing.expectEqualStrings("ab", pass.items);
    try testing.expectEqual(@as(usize, 1), cmds.len);
    try testing.expect(cmds[0] == .detach);
}

test "Filter: prefix then d detaches across two reads; prefix then backslash is literal" {
    var f: Filter = .{};
    var pass: std.ArrayList(u8) = .empty;
    defer pass.deinit(testing.allocator);
    var cmds = try feedFilter(&f, "\x1c", &pass);
    try testing.expectEqual(@as(usize, 0), cmds.len);
    try testing.expect(f.prefix);
    cmds = try feedFilter(&f, "d", &pass);
    try testing.expectEqual(@as(usize, 1), cmds.len);
    try testing.expect(cmds[0] == .detach);
    try testing.expectEqualStrings("", pass.items);

    cmds = try feedFilter(&f, "\x1c\\x", &pass);
    try testing.expectEqual(@as(usize, 0), cmds.len);
    try testing.expectEqualStrings("\x1cx", pass.items);
}

test "Filter: a stray prefix gives the following key back to the session" {
    var f: Filter = .{};
    var pass: std.ArrayList(u8) = .empty;
    defer pass.deinit(testing.allocator);
    const cmds = try feedFilter(&f, "\x1cq", &pass);
    try testing.expectEqual(@as(usize, 0), cmds.len);
    try testing.expectEqualStrings("q", pass.items);
    try testing.expect(!f.prefix);
}

test "Filter: scroll mode eats navigation keys and nothing reaches the session" {
    var f: Filter = .{};
    var pass: std.ArrayList(u8) = .empty;
    defer pass.deinit(testing.allocator);
    var cmds = try feedFilter(&f, "\x1c[", &pass);
    try testing.expectEqual(@as(usize, 1), cmds.len);
    try testing.expect(cmds[0] == .scroll_enter);
    try testing.expect(f.scrolling);

    cmds = try feedFilter(&f, "\x1b[5~k\x1bOBGq", &pass);
    try testing.expectEqualStrings("", pass.items);
    try testing.expectEqual(@as(usize, 5), cmds.len);
    try testing.expectEqual(@as(i32, 1), cmds[0].scroll_pages);
    try testing.expectEqual(@as(i32, 1), cmds[1].scroll_lines);
    try testing.expectEqual(@as(i32, -1), cmds[2].scroll_lines);
    try testing.expect(cmds[3] == .scroll_bottom);
    try testing.expect(cmds[4] == .scroll_leave);
    try testing.expect(!f.scrolling);

    // Back to pass-through.
    cmds = try feedFilter(&f, "k", &pass);
    try testing.expectEqual(@as(usize, 0), cmds.len);
    try testing.expectEqualStrings("k", pass.items);
}

test "Filter: PageUp right after the prefix opens scrollback; detach works while scrolling" {
    var f: Filter = .{};
    var pass: std.ArrayList(u8) = .empty;
    defer pass.deinit(testing.allocator);
    var cmds = try feedFilter(&f, "\x1c\x1b[5~", &pass);
    try testing.expectEqual(@as(usize, 2), cmds.len);
    try testing.expect(cmds[0] == .scroll_enter);
    try testing.expectEqual(@as(i32, 1), cmds[1].scroll_pages);
    try testing.expectEqualStrings("", pass.items);

    cmds = try feedFilter(&f, "\x1b[<64;10;5M\x1cd", &pass);
    try testing.expectEqual(@as(usize, 2), cmds.len);
    try testing.expectEqual(@as(i32, 3), cmds[0].scroll_lines);
    try testing.expect(cmds[1] == .detach);
    try testing.expectEqualStrings("", pass.items);
}
