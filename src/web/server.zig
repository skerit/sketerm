//! Unix-socket server for the browser helper: one listener, N clients,
//! one poll loop that also drives CEF (capability "multi-client").
//!
//! SINGLE-THREADED BY CONSTRUCTION. `cef_do_message_loop_work()` is
//! called from this loop, and CEF is initialized with
//! `multi_threaded_message_loop = 0` / `external_message_pump = 0`, so
//! every CEF callback (paint, title, load, popup) runs INSIDE that call
//! — on this thread, between two poll iterations. Nothing in
//! sketerm-web is therefore locked, atomic, or handed across threads,
//! and introducing a thread would break all of it at once. Multi-client
//! is MORE DESCRIPTORS ON THIS LOOP, never a thread.
//!
//! Each connection keeps its own inbound buffer, its own outbox, its
//! own handshake state, and its own view/context id namespace: client
//! ids are translated into globals by adding the connection's
//! `proto.CONN_ID_WINDOW` multiple on the way in and subtracting it on
//! the way out, so two clients both minting view 1 never meet. The
//! engine exits when the LAST client disconnects — the only path to
//! `cef_shutdown`, which is what flushes persistent cookie jars.
//!
//! No CEF type appears here: the loop talks to `cefhost` and moves
//! `protocol` frames.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("cbindings");
const proto = @import("protocol.zig");
const cefhost = @import("cefhost.zig");
const clock = @import("../util/clock.zig");

/// Poll timeout while at least one view exists — CEF wants to be
/// pumped at roughly frame rate. With no view there is nothing to
/// render and the loop idles instead.
const busy_timeout_ms: c_int = 5;
const idle_timeout_ms: c_int = 50;

/// Poll timeout while a blocking-webRequest decision is outstanding.
/// The reply travels renderer -> browser process and is only delivered
/// inside `cef_do_message_loop_work`, so the loop's period IS the
/// round-trip's floor. 1ms rather than 0 because a held request is
/// short-lived and a busy spin would burn a core for it.
const wreq_timeout_ms: c_int = 1;

/// `SKETERM_WEB_WREQ_SPIN=1` drops that 1ms to 0, i.e. busy-pumps CEF
/// while a decision is outstanding. It measurably removes most of the
/// hold's added latency and costs a whole core while it is doing so,
/// which is why it is a knob for measurement and not the default —
/// `zig build bench-webreq` reports both numbers.
var wreq_spin: bool = false;

/// `SKETERM_WEB_DEBUG_CONNS=1`: say WHY a connection is being cut.
var debug_conns: bool = false;

fn connNote(comptime why: []const u8, id: u32) void {
    if (!debug_conns) return;
    std.debug.print("sketerm-web: conn {d} cut: " ++ why ++ "\n", .{id});
}

fn readWreqSpin() void {
    const v = c.getenv("SKETERM_WEB_WREQ_SPIN") orelse return;
    const s = std.mem.span(v);
    wreq_spin = s.len != 0 and !std.mem.eql(u8, s, "0");
}

/// Wall-clock budget for CEF to finish closing every browser after the
/// last client goes away. `close_browser` is asynchronous renderer IPC —
/// iterations alone are not time — and `cef_shutdown` with a live
/// browser hangs the process, so the drain waits for
/// `cefhost.openBrowsers() == 0` under this cap.
const drain_deadline_ms: i64 = 5_000;

/// Cadence of the engine's own persistent-jar flush (see step()).
/// Chromium's cookie commit timer is ~30s and localStorage's LevelDB
/// log lands within ~15s; this halves the worst-case loss window of an
/// uncleanly-killed long-lived engine to ~20s of tail.
const flush_interval_ms: i64 = 20_000;

/// Concurrent connections the poll array carries. A connect past this
/// is accepted and immediately closed — fail-closed, like every other
/// exhausted budget on this wire.
const max_conns = 32;

/// Bytes a connection may leave undelivered before it is declared
/// wedged and cut off. Protocol frames cannot be dropped one by one
/// (a client misses a `frame_buffer` and paints garbage forever), so
/// the flood discipline here is the daemon's other half: bound the
/// buffer, and when a reader has clearly stopped, disconnect it rather
/// than stall CEF's pump or starve the clients that still read. Paint
/// traffic — the only unbounded producer — is already dropped per
/// connection by `max_frame_backlog`, so this cap is the belt.
const max_conn_backlog_bytes: usize = 64 * 1024 * 1024;

/// Highest connection id the window arithmetic can namespace:
/// `id * CONN_ID_WINDOW` must stay below `ENGINE_VIEW_BASE`. Ids are
/// never reused, so this is a lifetime budget per engine, not a
/// concurrency limit; an engine that served this many connections
/// refuses further ones.
const max_conn_id: u32 = proto.ENGINE_VIEW_BASE / proto.CONN_ID_WINDOW - 1;

/// Capabilities this helper normally advertises. `frames-shm` is here
/// even in GPU mode: the engine drops back to software compositing on
/// its own when the GPU goes away, and the client must be ready for the
/// memfd frames that follow. Conditional ones are appended at handshake
/// time — adding either kind is ONE line and nothing else, which is the
/// whole point of the shape below.
const unconditional_caps = [_][]const u8{
    proto.CAP_FRAMES_SHM,
    proto.CAP_INPUT,
    proto.CAP_NAVIGATION,
    proto.CAP_SEMANTIC,
    proto.CAP_VIEW_CREATE_URL,
    proto.CAP_DISCARD,
    proto.CAP_FIND,
    proto.CAP_ZOOM,
    proto.CAP_CONTEXT_MENU,
    proto.CAP_INTERCEPT,
    proto.CAP_NET_POLICY,
    proto.CAP_TLS,
    proto.CAP_PERMISSIONS,
    proto.CAP_SCROLL,
    proto.CAP_DEVTOOLS,
    proto.CAP_PRINT_PDF,
    proto.CAP_CLIPBOARD,
    proto.CAP_POPUP_OPEN,
    proto.CAP_DOWNLOADS,
    proto.CAP_DOWNLOAD_START,
    proto.CAP_A11Y,
    proto.CAP_A11Y_CARET,
    proto.CAP_CONTEXTS,
    proto.CAP_CONTEXTS_FAIL_CLOSED,
    proto.CAP_USERSCRIPTS,
    proto.CAP_SITEDATA,
    proto.CAP_FLUSH,
    proto.CAP_FRAMES_INLINE,
    proto.CAP_WEBEXT,
    proto.CAP_WEBEXT_TABS,
    proto.CAP_WEBEXT_ACTION,
    proto.CAP_WEBEXT_TRANSACTION,
    proto.CAP_FILTER_SUBSCRIBE,
    proto.CAP_READER_IDS,
    proto.CAP_SEMANTIC_REQUEST_IDS,
    proto.CAP_MULTI_CLIENT,
    proto.CAP_COOKIE_SYNC,
    proto.CAP_OBSERVE,
    proto.CAP_LOAD_RETRY,
};

/// Test-only negotiation seam for exercising an older helper client path.
fn advertiseReaderIds() bool {
    return c.getenv("SKETERM_WEB_DISABLE_READER_IDS") == null;
}

fn advertiseSemanticRequestIds() bool {
    return c.getenv("SKETERM_WEB_DISABLE_SEMANTIC_REQUEST_IDS") == null;
}

fn advertiseNetPolicy() bool {
    return c.getenv("SKETERM_WEB_DISABLE_NET_POLICY") == null;
}

/// Bounded builder for the `hello_ack` capability set. Its capacity is
/// derived from the protocol's OWN vocabulary — the number of `CAP_*`
/// constants `protocol.zig` declares — so there is no size to bump and
/// no count to keep in step: advertising more capabilities than exist
/// is not expressible. This replaced a fixed array plus a hand-tracked
/// `ncaps`, which three parallel branches each had to merge by hand.
const CapList = struct {
    const capacity = blk: {
        @setEvalBranchQuota(20_000);
        var n: usize = 0;
        for (@typeInfo(proto).@"struct".decls) |d| {
            if (std.mem.startsWith(u8, d.name, "CAP_")) n += 1;
        }
        break :blk n;
    };

    buf: [capacity][]const u8 = undefined,
    len: usize = 0,

    fn add(self: *CapList, cap: []const u8) void {
        self.buf[self.len] = cap;
        self.len += 1;
    }

    fn addAll(self: *CapList, caps: []const []const u8) void {
        for (caps) |cap| self.add(cap);
    }

    fn slice(self: *const CapList) []const []const u8 {
        return self.buf[0..self.len];
    }
};

extern fn sketerm_web_add_iterate_timer(cb: *const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void;
extern fn sketerm_web_remove_iterate_timer() void;

/// CFRunLoop lifeline entry (macOS): one non-blocking iteration from
/// inside whatever run loop currently owns the main thread.
fn timerStep(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Server = @ptrCast(@alignCast(ctx orelse return));
    if (self.conns.items.len == 0) return;
    self.step_nonblocking = true;
    defer self.step_nonblocking = false;
    self.step();
}

/// One client connection: its socket, buffers, handshake state and id
/// namespace. Heap-allocated for pointer stability — the host routes
/// events straight into `out` between poll iterations.
const Conn = struct {
    /// Never-reused connection id; `base = id * CONN_ID_WINDOW` is the
    /// view/context id window this connection owns.
    id: u32,
    fd: c_int,
    in: std.ArrayList(u8) = .empty,
    out: proto.Outbox,
    /// Set once this connection's `hello` is answered.
    greeted: bool = false,
    /// This connection asked for inline frames (or spawn forced them).
    inline_mode: bool = false,
    /// Marked by a read/flush failure; reaped at the end of the step.
    dead: bool = false,

    fn base(self: *const Conn) u32 {
        return self.id * proto.CONN_ID_WINDOW;
    }

    /// Client view id -> engine-global id. Zero stays zero (the
    /// engine-global pseudo view), engine-minted inspector ids pass
    /// through (the ownership check in `cefhost.find` is their guard),
    /// a client-minted id past the window is a protocol violation.
    fn mapView(self: *const Conn, id: u32) !u32 {
        if (id == 0) return 0;
        if (id >= proto.ENGINE_VIEW_BASE) return id;
        if (id >= proto.CONN_ID_WINDOW) return error.ViewIdPastWindow;
        return self.base() + id;
    }

    /// Client context id -> engine-global id. The context space is
    /// PARTITIONED (proto.EPHEMERAL_CTX_BASE), not windowed like views:
    /// persisted profile ids pass through UNTRANSLATED because they are
    /// allocated by one store per engine and form a shared namespace —
    /// two connections naming the same persisted id share the identity
    /// context (and its live session) deliberately. Ephemeral ids are
    /// client-local and get the window, each connection owning
    /// [base+EPHEMERAL_CTX_BASE, base+EPHEMERAL_CTX_BASE+WINDOW).
    fn mapCtx(self: *const Conn, id: u32) !u32 {
        if (id < proto.EPHEMERAL_CTX_BASE) return id;
        if (id >= proto.EPHEMERAL_CTX_BASE + proto.CONN_ID_WINDOW) return error.ContextIdPastWindow;
        return self.base() + id;
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    listen_fd: c_int = -1,
    conns: std.ArrayList(*Conn) = .empty,
    /// Next connection id; ids are NEVER reused (a reused id would let
    /// a new client inherit routing meant for a dead one).
    next_conn_id: u32 = 1,
    /// A first client connected at least once — the run loop's reason
    /// to exist; when the last connection then leaves, the engine
    /// drains and exits.
    served: bool = false,
    /// True while `step` is on the stack. On macOS one iteration can
    /// re-enter through the CFRunLoop lifeline timer (see run()); the
    /// guard makes that a no-op instead of a recursive drain.
    in_step: bool = false,
    /// Set by the timer entry: this iteration must not block in poll —
    /// it runs INSIDE an AppKit run loop that has its own schedule.
    step_nonblocking: bool = false,
    path: []const u8,
    /// Legacy single-outbox target for a Host with no router; run()
    /// installs the router, so nothing lands here in practice.
    out: proto.Outbox,
    host: cefhost.Host = undefined,
    /// Root cache dir (the `--cache-dir`), under which per-context caches
    /// are minted; handed to the host before `run`.
    profile_dir: []const u8 = "",
    /// `--proxy`: this instance's route proxy url ("" = direct). Applied
    /// to the global context and to every container context.
    instance_proxy: []const u8 = "",
    /// `--frames-inline`: inline frame mode forced from spawn (the
    /// remote-helper launch shape — the daemon bridges the socket over
    /// the mux wire, where no descriptor can travel).
    force_inline: bool = false,
    /// `--socket-fd`: the client connection was handed to us pre-made
    /// (a socketpair from the spawning daemon); no listen/accept.
    preset_fd: bool = false,
    /// Adopted descriptor waiting for run() to mint its Conn.
    preset_client: c_int = -1,
    /// `--linger-ms`: after the LAST client disconnects, keep listening
    /// this long for the next one before draining and exiting. 0 keeps
    /// the exit-with-last-client shape; a preset-fd engine (no
    /// listener) cannot linger regardless.
    linger_ms: i64 = 0,
    /// Monotonic ms of the last periodic jar flush (see step()).
    last_flush_ms: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, path: []const u8) Server {
        return .{ .gpa = gpa, .path = path, .out = proto.Outbox.init(gpa) };
    }

    pub fn deinit(self: *Server) void {
        while (self.conns.pop()) |cn| self.freeConn(cn);
        self.conns.deinit(self.gpa);
        // Undelivered messages may still carry a memfd; nobody else
        // will close them.
        drainOutboxFds(&self.out);
        self.out.deinit();
        if (self.preset_client >= 0) _ = c.close(self.preset_client);
        if (self.listen_fd >= 0) _ = c.close(self.listen_fd);
    }

    fn drainOutboxFds(out: *proto.Outbox) void {
        while (out.front()) |m| {
            for (m.fdSlice()) |fd| _ = c.close(fd);
            out.advance(m.bytes.len);
        }
    }

    fn freeConn(self: *Server, cn: *Conn) void {
        cn.in.deinit(self.gpa);
        drainOutboxFds(&cn.out);
        cn.out.deinit();
        if (cn.fd >= 0) _ = c.close(cn.fd);
        self.gpa.destroy(cn);
    }

    /// Bind and listen. The path must be short: sockaddr_un caps at
    /// ~108 bytes and a deep path fails to bind.
    pub fn listen(self: *Server) !void {
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        if (self.path.len + 1 > @sizeOf(@TypeOf(addr.sun_path))) return error.SocketPathTooLong;
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..self.path.len], self.path);

        var z: [256]u8 = undefined;
        if (self.path.len + 1 > z.len) return error.SocketPathTooLong;
        @memcpy(z[0..self.path.len], self.path);
        z[self.path.len] = 0;
        _ = c.unlink(@ptrCast(&z));

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        self.listen_fd = fd;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
        if (c.listen(fd, 8) != 0) return error.ListenFailed;
    }

    /// Serve clients until the last one disconnects, then tear every
    /// view down. Later clients may join and leave freely; only the
    /// count reaching zero ends the engine.
    pub fn run(self: *Server) !void {
        readWreqSpin();
        debug_conns = c.getenv("SKETERM_WEB_DEBUG_CONNS") != null;
        // The first PERIODIC jar flush waits a full interval: a flush
        // issued while CEF's cookie storage is still initializing
        // intermittently crashed the engine (ECONNRESET for every
        // client, reproduced ~1 in 2 focused smoke runs). An explicit
        // client flush_req has no such window in practice — a client
        // exists to send one only after pages loaded.
        self.last_flush_ms = clock.nowMs();
        self.host = cefhost.Host.init(self.gpa, &self.out);
        self.host.profile_dir = self.profile_dir;
        self.host.instance_proxy = self.instance_proxy;
        self.host.router = .{
            .ctx = self,
            .route = routerRoute,
            .count = routerCount,
            .at = routerAt,
            .mapView = routerMapView,
        };
        if (self.force_inline) self.host.setInlineMode(true);
        defer self.host.deinit();
        self.host.install();
        // The Wayland presenter (session-mode helpers only): armed after
        // the handlers, before any client can create a view, so the very
        // first paint already has a toplevel to land in.
        self.host.presenterStart();
        // Load the seed list + config filters dir before any view
        // exists, so the very first navigation is already filtered.
        cefhost.interceptInit(self.gpa);
        defer cefhost.interceptDeinit(self.gpa);

        // macOS lifeline: Chromium UI-thread code can enter a nested
        // run loop that bootstraps [NSApp run] and never hands the
        // thread back to this loop (measured on the first
        // subresource-bearing page load — smoke-web stage 22d froze
        // with the main thread parked in -[NSApplication run]).
        // Chromium keeps running inside that loop; only our socket
        // serving would die. A repeating main-run-loop timer performs
        // one NON-BLOCKING iteration from wherever the thread actually
        // is, so the helper keeps serving through any nested loop.
        // Same thread always — the single-threaded invariant above
        // holds; `in_step` handles the re-entrancy.
        if (builtin.target.os.tag == .macos) {
            sketerm_web_add_iterate_timer(timerStep, self);
        }
        defer if (builtin.target.os.tag == .macos) {
            sketerm_web_remove_iterate_timer();
        };

        if (self.preset_client >= 0) {
            _ = self.addConn(self.preset_client);
            self.preset_client = -1;
        } else {
            try self.acceptFirst();
        }
        while (true) {
            while (self.conns.items.len > 0) {
                self.step();
            }
            if (self.linger_ms <= 0 or self.listen_fd < 0) break;
            // Broker-owned lifecycle: the last client left, but the
            // engine lingers for the next one. Views died with their
            // connections; the persistent CONTEXTS (and their live
            // cookie jars) are what survives — flush them to disk now,
            // since the graceful drain below is deferred and a crash
            // during the linger would otherwise lose the tail.
            self.host.flushProfileStores(0, 0);
            if (!self.lingerForClient()) break;
        }
        // Let CEF finish closing the browsers before the caller shuts
        // it down; close_browser is asynchronous, and a browser with
        // post-close work still queued (a cancelled download's cleanup)
        // outlives any fixed pump count — so pump until every browser
        // reported `on_before_close`, bounded, then drain the tail.
        self.host.destroyAll();
        cefhost.filterSubShutdown(&self.host);
        const deadline = clock.nowMs() + drain_deadline_ms;
        while ((cefhost.openBrowsers() > 0 or cefhost.filterSubBusy(&self.host)) and clock.nowMs() < deadline) {
            cefhost.pump();
            self.host.watchdog(clock.nowMs());
            _ = c.usleep(2_000);
        }
    }

    /// Adopt a pre-connected client descriptor (`--socket-fd`): the
    /// spawning daemon holds the other end of the socketpair. Marked
    /// cloexec here so CEF's own subprocesses never inherit it.
    pub fn adoptClientFd(self: *Server, fd: c_int) void {
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        self.preset_client = fd;
        self.preset_fd = true;
    }

    fn addConn(self: *Server, fd: c_int) ?*Conn {
        if (self.conns.items.len >= max_conns or self.next_conn_id > max_conn_id) {
            _ = c.close(fd);
            return null;
        }
        const cn = self.gpa.create(Conn) catch {
            _ = c.close(fd);
            return null;
        };
        cn.* = .{
            .id = self.next_conn_id,
            .fd = fd,
            .out = proto.Outbox.init(self.gpa),
            .inline_mode = self.force_inline,
        };
        self.next_conn_id += 1;
        self.conns.append(self.gpa, cn) catch {
            cn.out.deinit();
            self.gpa.destroy(cn);
            _ = c.close(fd);
            return null;
        };
        self.served = true;
        return cn;
    }

    /// Wait for the first client, pumping CEF meanwhile (it has nothing
    /// to do yet, but a stalled loop is a habit worth not forming).
    fn acceptFirst(self: *Server) !void {
        while (true) {
            var pfd = c.struct_pollfd{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 };
            const n = c.poll(@ptrCast(&pfd), 1, idle_timeout_ms);
            // BEFORE the pump. `cef_do_message_loop_work` runs a whole
            // Chromium message-loop iteration and clobbers errno, so
            // reading it afterwards reports whatever CEF's last syscall
            // set — and a poll interrupted by a signal then looks like a
            // hard failure. macOS makes this fatal on the FIRST idle
            // tick (the helper died with "serve failed: PollFailed"
            // before any client could connect); the same race was always
            // present on Linux, where poll simply woke cleanly more
            // often. `step()` below already reads errno immediately.
            const poll_errno = errno();
            cefhost.pump();
            if (n < 0) {
                if (poll_errno == c.EINTR) continue;
                return error.PollFailed;
            }
            if (n == 0) continue;
            if (self.acceptOne()) return;
        }
    }

    /// Wait out the linger window for a successor client, pumping CEF
    /// (its flush callbacks and background work still need the loop).
    /// True when a client connected; false when the window elapsed and
    /// the engine should drain and exit.
    fn lingerForClient(self: *Server) bool {
        const deadline = clock.nowMs() + self.linger_ms;
        while (clock.nowMs() < deadline) {
            var pfd = c.struct_pollfd{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 };
            const n = c.poll(@ptrCast(&pfd), 1, idle_timeout_ms);
            const poll_errno = errno();
            cefhost.pump();
            if (n < 0 and poll_errno != c.EINTR) return false;
            if (n > 0 and self.acceptOne()) return true;
        }
        return false;
    }

    /// Accept one pending connection, non-fatally.
    fn acceptOne(self: *Server) bool {
        const fd = c.accept(self.listen_fd, null, null);
        if (fd < 0) return false;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        return self.addConn(fd) != null;
    }

    /// One loop iteration: poll everything, drain sockets, pump CEF,
    /// flush every connection, reap the dead.
    fn step(self: *Server) void {
        if (self.in_step) return;
        self.in_step = true;
        defer self.in_step = false;
        // Descriptors: the listener (new clients may join a running
        // engine), the browser helper's blocking-webRequest wake pipe
        // (a request HELD on CEF's IO thread is a page that has stopped
        // loading, and the decision can only be dispatched from this
        // thread — the wake byte ends the poll the instant a hold
        // appears), then one per connection.
        var pfds: [3 + max_conns]c.struct_pollfd = undefined;
        var n_pfds: usize = 0;
        const listen_idx: ?usize = if (self.listen_fd >= 0) blk: {
            pfds[n_pfds] = .{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 };
            n_pfds += 1;
            break :blk n_pfds - 1;
        } else null;
        const wake_idx: ?usize = if (cefhost.webrequestWakeFd() >= 0) blk: {
            pfds[n_pfds] = .{ .fd = cefhost.webrequestWakeFd(), .events = c.POLLIN, .revents = 0 };
            n_pfds += 1;
            break :blk n_pfds - 1;
        } else null;
        _ = wake_idx;
        // The presenter's display socket: seat input and frame callbacks
        // arrive here, and a backed-up outbox asks for POLLOUT.
        if (self.host.presenterFd() >= 0) {
            pfds[n_pfds] = .{
                .fd = self.host.presenterFd(),
                .events = @as(c_short, c.POLLIN) | (if (self.host.presenterWantsWrite()) @as(c_short, c.POLLOUT) else @as(c_short, 0)),
                .revents = 0,
            };
            n_pfds += 1;
        }
        const conn_base = n_pfds;
        for (self.conns.items) |cn| {
            pfds[n_pfds] = .{
                .fd = cn.fd,
                .events = @as(c_short, c.POLLIN) | (if (cn.out.empty()) @as(c_short, 0) else @as(c_short, c.POLLOUT)),
                .revents = 0,
            };
            n_pfds += 1;
        }
        const timeout: c_int = if (self.step_nonblocking)
            0
        else if (cefhost.webrequestBusy())
            // Already holding something: the answer arrives through
            // CEF's message loop, which only turns when we pump.
            (if (wreq_spin) 0 else wreq_timeout_ms)
        else if (self.host.viewCount() > 0)
            busy_timeout_ms
        else
            idle_timeout_ms;
        const n = c.poll(&pfds, @intCast(n_pfds), timeout);
        const poll_errno = errno();
        if (n < 0 and poll_errno != c.EINTR) {
            // The poll set itself failed; nothing per-connection can be
            // decided from it. Drop everyone rather than spin forever.
            for (self.conns.items) |cn| cn.dead = true;
            self.reap();
            return;
        }
        if (n > 0) {
            if (listen_idx) |li| {
                if (pfds[li].revents & c.POLLIN != 0) _ = self.acceptOne();
            }
            for (self.conns.items, 0..) |cn, i| {
                const pfd = pfds[conn_base + i];
                if (pfd.fd != cn.fd) continue; // list changed under an accept
                if (pfd.revents & (c.POLLERR | c.POLLNVAL) != 0) {
                    connNote("POLLERR/POLLNVAL", cn.id);
                    cn.dead = true;
                    continue;
                }
                if (pfd.revents & c.POLLIN != 0 and !self.readIn(cn)) {
                    connNote("read failed or protocol violation", cn.id);
                    cn.dead = true;
                }
            }
        }
        // Nothing paints without a begin frame: keep a floor under every
        // visible view in case a client stopped asking for them.
        self.host.watchdog(clock.nowMs());
        // Display service: pending seat input becomes engine input on
        // this turn, and a frame callback that arrived lets the next
        // paint through.
        self.host.presenterPump();
        // An extension that asked to restart itself is restarted HERE,
        // never inside the call that asked: `runtime.reload` destroys
        // the very background page whose script is mid-call.
        self.host.webextPump();
        // Dispatch queued blocking-webRequest holds BEFORE pumping, so
        // the command reaches the background renderer in the same
        // message-loop turn that will carry its answer back.
        self.host.webrequestPump();
        self.host.semanticPump(clock.nowMs());
        // Cookie sync: fold what CEF's IO thread saw into the shadow
        // and run the periodic jar reconcile. A no-op — one branch —
        // while no connection has subscribed.
        self.host.cookieSyncPump(clock.nowMs());
        // CEF callbacks queue outbound frames, so pump BEFORE flushing.
        cefhost.pump();
        // A decision may have arrived in that pump; retire timeouts and
        // start any second phase without waiting a whole iteration.
        self.host.webrequestPump();
        // Coalesced per-view blocked/total counters: at most one
        // `intercept_status` per view per iteration, however many
        // requests the IO thread logged in between.
        self.host.flushInterceptStatus();
        self.host.flushNetPolicy();
        // Same coalescing for download progress: at most one
        // `ev_download_progress` per download per iteration.
        self.host.flushDownloadProgress();
        // Inline mode: ship damage the paint-time flush held back while
        // the outbox was backed up (union-and-flush backpressure).
        self.host.flushInline();
        // Periodic jar flush: a long-lived engine must not sit on the
        // ~30s Chromium commit window forever (Phase 0 measured cookies
        // lost to a kill inside it). Cheap when nothing is persistent —
        // flushProfileStores no-ops with zero flushable managers.
        const flush_now = clock.nowMs();
        if (flush_now - self.last_flush_ms >= flush_interval_ms) {
            self.last_flush_ms = flush_now;
            self.host.flushProfileStores(0, 0);
        }
        for (self.conns.items) |cn| {
            if (cn.dead) continue;
            if (!self.flushConn(cn)) {
                connNote("flush failed", cn.id);
                cn.dead = true;
                continue;
            }
            // The wedge cut-off: a reader that stopped consuming would
            // otherwise grow this queue without bound (see
            // max_conn_backlog_bytes). One wedged client must cost only
            // itself.
            if (cn.out.bytes > max_conn_backlog_bytes) {
                connNote("backlog cut-off", cn.id);
                cn.dead = true;
            }
        }
        self.reap();
    }

    /// Remove dead connections: close the socket, destroy the views and
    /// contexts they own, free their queues. The engine itself stays up
    /// for whoever remains; run() notices an empty list.
    fn reap(self: *Server) void {
        var i: usize = 0;
        while (i < self.conns.items.len) {
            const cn = self.conns.items[i];
            if (!cn.dead) {
                i += 1;
                continue;
            }
            _ = self.conns.orderedRemove(i);
            self.host.dropConn(cn.id);
            self.freeConn(cn);
        }
    }

    // -- host routing (cefhost.Router) ---------------------------------

    fn routerRoute(ctx: *anyopaque, conn_id: u32) ?*proto.Outbox {
        const self: *Server = @ptrCast(@alignCast(ctx));
        for (self.conns.items) |cn| {
            if (cn.id == conn_id and !cn.dead) return &cn.out;
        }
        return null;
    }

    fn routerCount(ctx: *anyopaque) usize {
        const self: *Server = @ptrCast(@alignCast(ctx));
        return self.conns.items.len;
    }

    fn routerAt(ctx: *anyopaque, i: usize) ?*proto.Outbox {
        const self: *Server = @ptrCast(@alignCast(ctx));
        if (i >= self.conns.items.len) return null;
        const cn = self.conns.items[i];
        if (cn.dead) return null;
        return &cn.out;
    }

    fn routerMapView(ctx: *anyopaque, conn_id: u32, id: u32) u32 {
        const self: *Server = @ptrCast(@alignCast(ctx));
        for (self.conns.items) |cn| {
            if (cn.id != conn_id) continue;
            return cn.mapView(id) catch 0;
        }
        return 0;
    }

    /// Read what is available and dispatch complete frames. Returns
    /// false on EOF or a fatal socket/protocol error.
    fn readIn(self: *Server, cn: *Conn) bool {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(cn.fd, &buf, buf.len);
            if (n == 0) return false;
            if (n < 0) {
                const e = errno();
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
                if (e == c.EINTR) continue;
                return false;
            }
            cn.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch return false;
            if (@as(usize, @intCast(n)) < buf.len) break;
        }

        var reader = proto.Reader.init(cn.in.items);
        while (true) {
            const frame = (reader.next() catch {
                connNote("malformed frame", cn.id);
                return false;
            }) orelse break;
            self.dispatch(cn, frame) catch |err| {
                // An observer's frame the lease gate refused, or an
                // alias verb served at the edge: not a violation, the
                // connection stays.
                if (err == error.ObserveDropped) continue;
                if (debug_conns)
                    std.debug.print("sketerm-web: conn {d} dispatch error on tag 0x{x}\n", .{ cn.id, @intFromEnum(frame.tag) });
                return false;
            };
        }
        const used = reader.consumed();
        if (used != 0) {
            const rest = cn.in.items.len - used;
            std.mem.copyForwards(u8, cn.in.items[0..rest], cn.in.items[used..]);
            cn.in.shrinkRetainingCapacity(rest);
        }
        return true;
    }

    /// Decode `T` and translate its client-namespace ids into the
    /// engine's global namespace — the socket-edge half of
    /// multi-client, so `cefhost` keeps thinking in one id space.
    fn dec(self: *Server, cn: *Conn, comptime T: type, payload: []const u8) !T {
        var req = try proto.decode(T, payload);
        try self.xlateIn(cn, T, &req);
        return req;
    }

    /// The inbound field vocabulary carrying client-minted ids: `view`
    /// and `popup_view` name views, `context` and the context frames'
    /// `id` name identity contexts. A new inbound frame naming a view
    /// or context under a FIFTH field name must be added here or its
    /// ids arrive untranslated (and, for a view, then fail `find`'s
    /// ownership check rather than touch a foreign view).
    fn xlateIn(self: *Server, cn: *Conn, comptime T: type, req: *T) !void {
        if (T == proto.ContextCreate or T == proto.ContextDestroy) {
            req.id = try cn.mapCtx(req.id);
            return;
        }
        inline for (.{ "view", "popup_view" }) |f| {
            if (@hasField(T, f)) @field(req, f) = try cn.mapView(@field(req, f));
        }
        if (@hasField(T, "context")) req.context = try cn.mapCtx(req.context);
        // An OBSERVER ALIAS (capability "observe"): the id names a
        // subscription of this connection, not a view of its own. The
        // alias-only verbs are served here; everything else passes the
        // lease gate and is re-addressed to the target, with
        // `dispatch_alias` telling the host why a foreign view is fair.
        if (@hasField(T, "view")) {
            if (self.host.aliasOf(cn.id, req.view)) |sub| {
                switch (T.tag) {
                    .view_destroy => {
                        self.host.observeUnsubscribe(cn.id, req.view);
                        return error.ObserveDropped;
                    },
                    .view_show => {
                        self.host.observePause(cn.id, req.view, false);
                        return error.ObserveDropped;
                    },
                    .view_hide => {
                        self.host.observePause(cn.id, req.view, true);
                        return error.ObserveDropped;
                    },
                    else => {},
                }
                if (!proto.observerAllows(T.tag, sub.control)) return error.ObserveDropped;
                self.host.dispatch_alias = req.view;
                req.view = sub.target;
            }
        }
    }

    fn dispatch(self: *Server, cn: *Conn, frame: proto.Frame) !void {
        // Nothing but the handshake is served before it: a client that
        // skipped `hello` has not agreed a protocol version, so acting
        // on its frames would be guessing.
        if (!cn.greeted and frame.tag != .hello) return;
        // Everything the host does inside this dispatch is on behalf of
        // this connection: view creation stamps the owner, `find`
        // refuses foreign views, viewless replies route back here.
        self.host.dispatch_conn = cn.id;
        self.host.dispatch_inline = cn.inline_mode;
        defer {
            self.host.dispatch_conn = 0;
            self.host.dispatch_inline = false;
            self.host.dispatch_alias = 0;
        }
        switch (frame.tag) {
            .hello => {
                const req = try proto.decode(proto.Hello, frame.payload);
                if (req.proto != proto.PROTO_VERSION) return error.ProtocolMismatch;
                var caps: CapList = .{};
                for (&unconditional_caps) |cap| {
                    if (std.mem.eql(u8, cap, proto.CAP_READER_IDS) and !advertiseReaderIds()) continue;
                    if (std.mem.eql(u8, cap, proto.CAP_SEMANTIC_REQUEST_IDS) and !advertiseSemanticRequestIds()) continue;
                    if (std.mem.eql(u8, cap, proto.CAP_NET_POLICY) and !advertiseNetPolicy()) continue;
                    caps.add(cap);
                }
                if (cefhost.isAccelerated()) caps.add(proto.CAP_FRAMES_DMABUF);
                if (self.host.presenterActive()) caps.add(proto.CAP_PRESENTER);
                try cn.out.post(proto.HelloAck{
                    .proto = proto.PROTO_VERSION,
                    .engine_name = cefhost.engineName(),
                    .engine_version = cefhost.engineVersion(),
                    .caps = caps.slice(),
                }, null);
                cn.greeted = true;
            },
            .context_create => self.host.contextCreate(try self.dec(cn, proto.ContextCreate, frame.payload)),
            .context_destroy => self.host.contextDestroy((try self.dec(cn, proto.ContextDestroy, frame.payload)).id),
            .view_create => try self.host.createView(try self.dec(cn, proto.ViewCreate, frame.payload)),
            .view_create_url => try self.host.createViewUrl(try self.dec(cn, proto.ViewCreateUrl, frame.payload)),
            .view_destroy => self.host.destroyView((try self.dec(cn, proto.ViewDestroy, frame.payload)).view),
            .view_discard => self.host.discardView((try self.dec(cn, proto.ViewDiscard, frame.payload)).view),
            .view_resize => try self.host.resizeView(try self.dec(cn, proto.ViewResize, frame.payload)),
            .view_show => self.host.showView((try self.dec(cn, proto.ViewShow, frame.payload)).view, true),
            .view_hide => self.host.showView((try self.dec(cn, proto.ViewHide, frame.payload)).view, false),
            .view_max_fps => self.host.setMaxFps(try self.dec(cn, proto.ViewMaxFps, frame.payload)),
            .cert_decision => self.host.certDecision(try self.dec(cn, proto.CertDecision, frame.payload)),
            .permission_decision => self.host.permissionDecision(try self.dec(cn, proto.PermissionDecision, frame.payload)),
            .navigate => self.host.navigate(try self.dec(cn, proto.Navigate, frame.payload)),
            .nav_action => self.host.navAction(try self.dec(cn, proto.NavAction, frame.payload)),
            .find => self.host.findInPage(try self.dec(cn, proto.Find, frame.payload)),
            .find_stop => self.host.findStop(try self.dec(cn, proto.FindStop, frame.payload)),
            .set_zoom => self.host.setZoom(try self.dec(cn, proto.SetZoom, frame.payload)),
            .input_pointer => self.host.pointer(try self.dec(cn, proto.InputPointer, frame.payload)),
            .input_scroll => self.host.scroll(try self.dec(cn, proto.InputScroll, frame.payload)),
            .input_key => self.host.key(try self.dec(cn, proto.InputKey, frame.payload)),
            .input_ime => self.host.ime(try self.dec(cn, proto.InputIme, frame.payload)),
            .input_paste => self.host.paste(try self.dec(cn, proto.InputPaste, frame.payload)),
            .popup_policy_set => self.host.popupPolicySet(try self.dec(cn, proto.PopupPolicySet, frame.payload)),
            .clipboard_read => self.host.clipboardRead(try self.dec(cn, proto.ClipboardRead, frame.payload)),
            .input_focus => self.host.focus(try self.dec(cn, proto.InputFocus, frame.payload)),
            // v1 accepts the release for symmetry but keeps no per-buffer
            // state: one memfd per view, replaced on resize.
            .frame_release => _ = try self.dec(cn, proto.FrameRelease, frame.payload),
            .frame_request => self.host.beginFrame(try self.dec(cn, proto.FrameRequest, frame.payload)),
            .frame_mode => {
                const req = try proto.decode(proto.FrameMode, frame.payload);
                // Per-connection, latching (an anonymous buffer is
                // never announced, so there is no way back): this
                // connection's views go inline, nobody else's do.
                if (req.mode == proto.frame_mode_inline) {
                    cn.inline_mode = true;
                    self.host.latchInlineForConn(cn.id);
                }
            },
            .sem_snapshot_req => try self.host.semSnapshot(try self.dec(cn, proto.SemSnapshotReq, frame.payload)),
            .sem_act => try self.host.semAct(try self.dec(cn, proto.SemAction, frame.payload)),
            .sem_expand => try self.host.semExpand(try self.dec(cn, proto.SemExpand, frame.payload)),
            .sem_query => try self.host.semQuery(try self.dec(cn, proto.SemQueryReq, frame.payload)),
            .sem_read => try self.host.semRead(try self.dec(cn, proto.SemRead, frame.payload)),
            .sem_read_ids => try self.host.semReadIds(try self.dec(cn, proto.SemReadIds, frame.payload)),
            .sem_act_guarded => try self.host.semActGuarded(try self.dec(cn, proto.SemActGuarded, frame.payload)),
            .sem_request => try self.host.semRequest(try self.dec(cn, proto.SemRequest, frame.payload)),
            .sem_eval => try self.host.semEval(try self.dec(cn, proto.SemEval, frame.payload)),
            .intercept_set => self.host.interceptSet(try self.dec(cn, proto.InterceptSet, frame.payload)),
            .intercept_lists => {
                // Process-global filter lists: deliberately UNTRANSLATED
                // and last-writer-wins across connections in Phase 1,
                // like the userscript/webext family below. Whether these
                // become per-connection overlays or broker-owned truth
                // is Phase 4's decision, made deliberately, not here.
                const req = try proto.InterceptLists.decodeAlloc(frame.payload, self.gpa);
                defer self.gpa.free(req.paths);
                self.host.interceptLists(req);
            },
            .intercept_subscribe => {
                var req = try proto.InterceptSubscribe.decodeAlloc(frame.payload, self.gpa);
                defer self.gpa.free(req.urls);
                try self.xlateIn(cn, proto.InterceptSubscribe, &req);
                self.host.interceptSubscribe(req);
            },
            .intercept_status_req => self.host.interceptStatus(try self.dec(cn, proto.InterceptStatusReq, frame.payload)),
            .intercept_log_req => self.host.interceptLog(try self.dec(cn, proto.InterceptLogReq, frame.payload)),
            .net_policy_set => {
                var req = try proto.NetPolicySet.decodeAlloc(frame.payload, self.gpa);
                defer self.gpa.free(req.allow_top);
                defer self.gpa.free(req.allow_sub);
                try self.xlateIn(cn, proto.NetPolicySet, &req);
                self.host.netPolicySet(req);
            },
            .net_policy_req => self.host.netPolicyStatus(try self.dec(cn, proto.NetPolicyReq, frame.payload)),
            .net_log_req => self.host.netLog(try self.dec(cn, proto.NetLogReq, frame.payload)),
            .download_decide => self.host.downloadDecide(try self.dec(cn, proto.DownloadDecide, frame.payload)),
            .download_cancel => self.host.downloadCancel(try self.dec(cn, proto.DownloadCancel, frame.payload)),
            .download_start => self.host.downloadStart(try self.dec(cn, proto.DownloadStart, frame.payload)),
            .a11y_enable => self.host.a11yEnable(try self.dec(cn, proto.A11yEnable, frame.payload)),
            .us_script_set => {
                // Process-global, last-writer-wins: see .intercept_lists.
                const req = try proto.UsScriptSet.decodeAlloc(frame.payload, self.gpa);
                defer self.gpa.free(req.scripts);
                self.host.usScriptSet(req);
            },
            .us_style_set => {
                // Process-global, last-writer-wins: see .intercept_lists.
                const req = try proto.UsStyleSet.decodeAlloc(frame.payload, self.gpa);
                defer self.gpa.free(req.styles);
                self.host.usStyleSet(req);
            },
            .scroll_to => self.host.scrollTo(try self.dec(cn, proto.ScrollTo, frame.payload)),
            .devtools_show => try self.host.devtoolsShow(try self.dec(cn, proto.DevToolsShow, frame.payload)),
            .print_pdf => self.host.printPdf(try self.dec(cn, proto.PrintPdf, frame.payload)),
            .flush_req => {
                const f = try proto.decode(proto.FlushReq, frame.payload);
                self.host.flushProfileStores(f.token, cn.id);
            },
            // Cookie sync (0xE0). Per-CONNECTION, unlike the
            // process-global families above: the subscription is what
            // decides whose socket cookie VALUES cross, so it cannot
            // be last-writer-wins. `cookie_apply` / `cookie_dump_req`
            // carry a `context` and are translated by `xlateIn` like
            // every other context-naming frame.
            .cookie_sync_enable => {
                const req = try proto.decode(proto.CookieSyncEnable, frame.payload);
                self.host.cookieSyncEnable(cn.id, req.enable != 0);
            },
            // Observation (0xF0). Per-connection like cookie sync. The
            // alias in `observe_subscribe`/`observe_control` is minted
            // by the observer in ITS window (mapView), while `target`
            // is an engine-global id it learnt from an announcement
            // and crosses untranslated. Frames naming a live alias are
            // re-addressed in `xlateIn`.
            .observe_enable => {
                const req = try proto.decode(proto.ObserveEnable, frame.payload);
                self.host.observeEnable(cn.id, req.enable != 0);
            },
            .observe_subscribe => {
                const req = try proto.decode(proto.ObserveSubscribe, frame.payload);
                self.host.observeSubscribe(cn.id, try cn.mapView(req.view), req.target, req.control != 0);
            },
            .observe_control => {
                const req = try proto.decode(proto.ObserveControl, frame.payload);
                self.host.observeControl(cn.id, try cn.mapView(req.view), req.control != 0);
            },
            .cookie_apply => self.host.cookieApply(try self.dec(cn, proto.CookieApply, frame.payload)),
            .cookie_dump_req => self.host.cookieDump(try self.dec(cn, proto.CookieDumpReq, frame.payload)),
            .cookies_req => self.host.cookiesReq(try self.dec(cn, proto.CookiesReq, frame.payload)),
            .cookie_delete => self.host.cookieDelete(try self.dec(cn, proto.CookieDelete, frame.payload)),
            .cookies_clear => self.host.cookiesClear(try self.dec(cn, proto.CookiesClear, frame.payload)),
            .sitedata_clear => self.host.sitedataClear(try self.dec(cn, proto.SitedataClear, frame.payload)),
            // The webext family is process-global (one extension
            // registry, one action set), last-writer-wins: see
            // .intercept_lists. webext_tabs embeds view ids inside its
            // JSON, which the edge cannot reach — the host translates
            // them at parse time via Router.mapView instead.
            .webext_set => self.host.webextSet(try self.dec(cn, proto.WebextSet, frame.payload)),
            .webext_install_prepare => self.host.webextInstallPrepare(try self.dec(cn, proto.WebextInstallPrepare, frame.payload)),
            .webext_install_commit => self.host.webextInstallCommit(try self.dec(cn, proto.WebextInstallCommit, frame.payload)),
            .webext_remove => self.host.webextRemove((try self.dec(cn, proto.WebextRemove, frame.payload)).id),
            .webext_list_req => self.host.webextList(),
            .webext_wreq_stats_req => self.host.webrequestStats(),
            .webext_tabs => self.host.webextTabs((try proto.decode(proto.WebextTabs, frame.payload)).tabs_json),
            .webext_action_activate => self.host.webextActionActivate(try self.dec(cn, proto.WebextActionActivate, frame.payload)),
            .webext_open_popup_result => self.host.webextOpenPopupResult(try self.dec(cn, proto.WebextOpenPopupResult, frame.payload)),
            // Helper-to-client frames arriving from the client, and any
            // tag this build does not act on, are ignored by design.
            else => {},
        }
    }

    /// Push one connection's queued messages. Returns false when its
    /// socket died.
    fn flushConn(self: *Server, cn: *Conn) bool {
        _ = self;
        while (cn.out.front()) |m| {
            const n = sendMsg(cn.fd, m);
            if (n < 0) {
                const e = errno();
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) return true;
                if (e == c.EINTR) continue;
                return false;
            }
            for (m.fdSlice()) |fd| _ = c.close(fd);
            cn.out.advance(@intCast(n));
        }
        return true;
    }

    /// sendmsg with the message's SCM_RIGHTS descriptors attached — one
    /// memfd for a `frame_buffer`, one per plane for a `frame_dmabuf`.
    /// They must travel as ONE control message: several SCM_RIGHTS
    /// headers on one sendmsg is not portable and a receiver reading a
    /// single cmsg would drop the rest on the floor.
    fn sendMsg(fd: c_int, m: proto.Message) isize {
        var iov = c.struct_iovec{
            .iov_base = @constCast(m.bytes.ptr),
            .iov_len = m.bytes.len,
        };
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
        const fds = m.fdSlice();
        if (fds.len != 0) {
            const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
            const payload = fds.len * @sizeOf(c_int);
            const cmsg: *c.struct_cmsghdr = @ptrCast(&cbuf);
            cmsg.cmsg_len = @intCast(hdr_size + payload);
            cmsg.cmsg_level = c.SOL_SOCKET;
            cmsg.cmsg_type = c.SCM_RIGHTS;
            @memcpy(cbuf[hdr_size..][0..payload], std.mem.sliceAsBytes(fds));
            mh.msg_control = &cbuf;
            mh.msg_controllen = @intCast(std.mem.alignForward(usize, hdr_size + payload, 8));
        }
        return c.sendmsg(fd, &mh, 0);
    }
};

fn errno() c_int {
    return std.c._errno().*;
}
