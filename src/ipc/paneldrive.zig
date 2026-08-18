//! GTK-free MCP client for the mux panel relay.

const std = @import("std");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");
const muxclient = @import("../mux/client.zig");
const muxdaemon = @import("../mux/daemon.zig");
const panelrpc = @import("../mux/panelrpc.zig");
const protocol = @import("protocol.zig");
const wire = @import("../mux/wire.zig");

pub const SocketSource = enum {
    /// Exact daemon inherited from the PTY that owns the session.
    environment,
    /// Canonical per-user daemon, connect-only for legacy environments.
    default_compat,
};

pub const Origin = struct {
    socket: []u8,
    session: []const u8,
    source: SocketSource,

    pub fn resolve(allocator: std.mem.Allocator, session: ?[]const u8) !Origin {
        const scoped = session orelse return error.MissingSession;
        if (scoped.len == 0) return error.MissingSession;
        if (getenv("SKETERM_MUX_SOCKET")) |socket| {
            return .{
                .socket = try muxdaemon.canonicalSocketPath(allocator, socket),
                .session = scoped,
                .source = .environment,
            };
        }
        const socket = try muxdaemon.defaultSocketPath(allocator);
        defer allocator.free(socket);
        return .{
            .socket = try muxdaemon.canonicalSocketPath(allocator, socket),
            .session = scoped,
            .source = .default_compat,
        };
    }

    pub fn deinit(self: *Origin, allocator: std.mem.Allocator) void {
        allocator.free(self.socket);
        self.* = undefined;
    }
};

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
    return if (span.len == 0) null else span;
}

pub fn hasEnvironmentSocket() bool {
    return getenv("SKETERM_MUX_SOCKET") != null;
}

pub const EnvironmentIdentity = union(enum) {
    none,
    exact: []const u8,
    malformed,
};

/// Resolve inherited identity only when it belongs to the selected session.
pub fn environmentIdentity(session: []const u8) EnvironmentIdentity {
    const inherited_session = getenv("SKETERM_SESSION") orelse return .none;
    if (!std.mem.eql(u8, inherited_session, session)) return .none;
    const raw = c.getenv("SKETERM_SESSION_ORIGIN_ID") orelse return .none;
    const id = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    return if (muxdaemon.validSessionOriginId(id)) .{ .exact = id } else .malformed;
}

/// Fast exact identity inherited from a new daemon-owned session child.
pub fn environmentOriginId(session: []const u8) ?[]const u8 {
    return switch (environmentIdentity(session)) {
        .exact => |id| id,
        .none, .malformed => null,
    };
}

pub const FailureKind = enum {
    /// Valid daemon negotiation positively identifies a pre-lifetime-ID peer.
    legacy_daemon,
    unsupported,
    no_compatible_gui,
    no_such_session,
    origin_unreachable,
    origin_timeout,
    attach_failed,
    identity_mismatch,
    malformed_attach,
    malformed_welcome,
    request_too_large,
    allocation_failed,
    send_pre_delivery,
    delivery_uncertain,
    reply_timeout,
    disconnected,
    malformed_reply,
};

pub const Failure = struct {
    kind: FailureKind,
    detail: []const u8,
    /// The daemon connection itself remains framed and reusable. This is true
    /// only for structured daemon replies, never for requester send failures.
    connection_usable: bool = false,

    /// True once a panel request may have reached the daemon.
    pub fn uncertain(self: Failure) bool {
        return switch (self.kind) {
            .delivery_uncertain, .reply_timeout, .disconnected, .malformed_reply => true,
            else => false,
        };
    }
};

pub const Reply = struct {
    json: []u8,
    /// The presenter reported a validated `failure_class=pre_delivery`.
    pre_delivery: bool = false,
};

pub const Outcome = union(enum) {
    reply: Reply,
    failure: Failure,
};

pub const Identity = struct {
    daemon_origin: []u8,
    origin_id: []u8,

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        allocator.free(self.daemon_origin);
        allocator.free(self.origin_id);
        self.* = undefined;
    }
};

pub const IdentityOutcome = union(enum) {
    identity: Identity,
    failure: Failure,
};

const Entry = struct {
    socket: []u8,
    /// Mutable alias used to establish this connection.
    session: []u8,
    /// Lifetime-unique immutable daemon session incarnation.
    origin_id: []u8,
    conn: muxclient.Conn,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.conn.deinit();
        allocator.free(self.socket);
        allocator.free(self.session);
        allocator.free(self.origin_id);
        self.* = undefined;
    }
};

/// Persistent panel-only connections keyed by daemon, session, and lifetime.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    next_id: u64 = 1,
    /// The connection currently used by a tool call, including a socket still
    /// in nonblocking connect. Mirrored into `watchdog_fd` when the MCP
    /// watchdog registered one.
    active_fd: muxclient.FdCancel = .{},
    watchdog_fd: ?*muxclient.FdCancel = null,

    const MAX_CONNECTIONS: usize = 32;

    pub fn init(allocator: std.mem.Allocator) Pool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Pool) void {
        self.setActive(-1);
        const allocator = self.allocator;
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = .{ .allocator = allocator };
    }

    /// Copy live fds for the MCP watchdog without exposing connection state.
    pub fn fds(self: *const Pool, out: []c_int) usize {
        const count = @min(out.len, self.entries.items.len);
        for (self.entries.items[0..count], 0..) |entry, i| out[i] = entry.conn.fd;
        return count;
    }

    pub fn setWatchdogFd(self: *Pool, slot: *muxclient.FdCancel) void {
        self.watchdog_fd = slot;
    }

    fn setActive(self: *Pool, fd: c_int) void {
        setActiveSlot(&self.active_fd, fd);
        if (self.watchdog_fd) |slot| {
            if (slot != &self.active_fd) setActiveSlot(slot, fd);
        }
    }

    /// Send exactly once and wait for the matching reply ID.
    ///
    /// JSON stays opaque here; the selected GUI hydrates remote image paths
    /// after this relay boundary on its attached Terminal connection.
    fn callAt(
        self: *Pool,
        result_allocator: std.mem.Allocator,
        origin: Origin,
        op: panelrpc.Op,
        json: []const u8,
        timeout_ms: i64,
    ) !Outcome {
        return self.callUntil(result_allocator, origin, op, json, clock.nowMs() + @max(timeout_ms, 0));
    }

    /// Send once and wait under one deadline that also covers connection,
    /// hello negotiation, and panel-only attach. `op` is the caller's own
    /// authoritative command classification; the reply is validated against
    /// it here and nowhere else.
    pub fn callUntil(
        self: *Pool,
        result_allocator: std.mem.Allocator,
        origin: Origin,
        op: panelrpc.Op,
        json: []const u8,
        deadline_ms: i64,
    ) !Outcome {
        self.setActive(-1);
        defer self.setActive(-1);
        const found = self.ensure(origin, deadline_ms) catch |err| return .{ .failure = .{
            .kind = ensureFailureKind(err),
            .detail = @errorName(err),
        } };
        self.setActive(self.entries.items[found].conn.fd);

        const id = self.allocId();
        const outcome = request(&self.entries.items[found].conn, result_allocator, id, op, json, deadline_ms);
        if (outcome == .failure and failureRetiresConnection(outcome.failure)) {
            var removed = self.entries.orderedRemove(found);
            removed.deinit(self.allocator);
        }
        return outcome;
    }

    /// Resolve the exact daemon plus immutable spawn identity without sending
    /// a presenter request; failures here are always pre-delivery.
    pub fn identifyUntil(
        self: *Pool,
        result_allocator: std.mem.Allocator,
        origin: Origin,
        deadline_ms: i64,
    ) !IdentityOutcome {
        self.setActive(-1);
        defer self.setActive(-1);
        const found = self.ensure(origin, deadline_ms) catch |err| return .{ .failure = .{
            .kind = ensureFailureKind(err),
            .detail = @errorName(err),
        } };
        self.setActive(self.entries.items[found].conn.fd);
        const entry = self.entries.items[found];
        const daemon_origin = try result_allocator.dupe(u8, entry.socket);
        errdefer result_allocator.free(daemon_origin);
        const origin_id = try result_allocator.dupe(u8, entry.origin_id);
        return .{ .identity = .{
            .daemon_origin = daemon_origin,
            .origin_id = origin_id,
        } };
    }

    fn ensure(self: *Pool, origin: Origin, deadline_ms: i64) !usize {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (std.mem.eql(u8, entry.socket, origin.socket) and
                std.mem.eql(u8, entry.session, origin.session))
            {
                if (environmentOriginId(origin.session)) |expected| {
                    if (!std.mem.eql(u8, expected, entry.origin_id)) {
                        var removed = self.entries.orderedRemove(i);
                        removed.deinit(self.allocator);
                        continue;
                    }
                }
                if (entryAlive(entry)) return i;
                var removed = self.entries.orderedRemove(i);
                removed.deinit(self.allocator);
                continue;
            }
            i += 1;
        }

        // This path is intentionally connect-only. It never autostarts a
        // default daemon and can therefore neither create nor select the MCP
        // app tools' private instance.
        const expected_origin_id = environmentOriginId(origin.session) orelse "";
        var conn = try muxclient.connectPanelRequesterUntilExpected(
            self.allocator,
            origin.socket,
            origin.session,
            expected_origin_id,
            deadline_ms,
            self.watchdog_fd orelse &self.active_fd,
        );
        errdefer conn.deinit();
        conn.setNonBlocking();

        // The attach reply's identity was already validated by client.zig,
        // which refuses the connection outright when it is missing or bad.
        const immutable_id = conn.panelOriginId();
        i = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (!std.mem.eql(u8, entry.socket, origin.socket) or
                !std.mem.eql(u8, entry.origin_id, immutable_id))
            {
                i += 1;
                continue;
            }
            if (!entryAlive(entry)) {
                var removed = self.entries.orderedRemove(i);
                removed.deinit(self.allocator);
                continue;
            }
            try self.refreshSessionAlias(entry, origin.session);
            conn.deinit();
            return i;
        }

        const socket = try self.allocator.dupe(u8, origin.socket);
        errdefer self.allocator.free(socket);
        const session = try self.allocator.dupe(u8, origin.session);
        errdefer self.allocator.free(session);
        const origin_id = try self.allocator.dupe(u8, immutable_id);
        errdefer self.allocator.free(origin_id);

        if (self.entries.items.len >= MAX_CONNECTIONS) {
            var old = self.entries.orderedRemove(0);
            old.deinit(self.allocator);
        }
        try self.entries.append(self.allocator, .{
            .socket = socket,
            .session = session,
            .origin_id = origin_id,
            .conn = conn,
        });
        return self.entries.items.len - 1;
    }

    fn refreshSessionAlias(self: *Pool, entry: *Entry, session: []const u8) !void {
        if (std.mem.eql(u8, entry.session, session)) return;
        const current = try self.allocator.dupe(u8, session);
        self.allocator.free(entry.session);
        entry.session = current;
    }

    /// Consume asynchronous lifecycle frames before trusting cached identity.
    fn entryAlive(entry: *Entry) bool {
        if (!entry.conn.fillAvailable()) return false;
        while (entry.conn.takeFrame() catch return false) |frame| {
            defer frame.deinit(entry.conn.allocator);
            switch (frame.ftype) {
                .gone, .exit, .err => return false,
                else => {},
            }
        }
        return true;
    }

    fn allocId(self: *Pool) u64 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return if (id == 0) self.allocId() else id;
    }
};

fn ensureFailureKind(err: anyerror) FailureKind {
    return switch (err) {
        error.LegacyPanelIdentityUnsupported => .legacy_daemon,
        error.PanelRpcUnsupported => .unsupported,
        error.PanelSessionNotFound => .no_such_session,
        error.SessionOriginMismatch => .identity_mismatch,
        error.DaemonError => .attach_failed,
        error.MalformedPanelAttachMetadata => .malformed_attach,
        error.MalformedPanelWelcome => .malformed_welcome,
        error.Timeout => .origin_timeout,
        else => .origin_unreachable,
    };
}

fn setActiveSlot(slot: *muxclient.FdCancel, fd: c_int) void {
    if (fd < 0) {
        slot.release();
        return;
    }
    // A stopped slot interrupts the duplicate immediately; the call it
    // belonged to is already being torn down either way.
    _ = slot.publish(fd) catch {};
}

test "paneldrive keeps legacy capability timeout and malformed negotiation distinct" {
    const t = std.testing;
    try t.expectEqual(FailureKind.legacy_daemon, ensureFailureKind(error.LegacyPanelIdentityUnsupported));
    try t.expectEqual(FailureKind.unsupported, ensureFailureKind(error.PanelRpcUnsupported));
    try t.expectEqual(FailureKind.no_such_session, ensureFailureKind(error.PanelSessionNotFound));
    try t.expectEqual(FailureKind.origin_timeout, ensureFailureKind(error.Timeout));
    try t.expectEqual(FailureKind.malformed_welcome, ensureFailureKind(error.MalformedPanelWelcome));
    try t.expectEqual(FailureKind.malformed_attach, ensureFailureKind(error.MalformedPanelAttachMetadata));
    try t.expectEqual(FailureKind.identity_mismatch, ensureFailureKind(error.SessionOriginMismatch));
    try t.expectEqual(FailureKind.attach_failed, ensureFailureKind(error.DaemonError));
    try t.expectEqual(FailureKind.origin_unreachable, ensureFailureKind(error.ConnectFailed));
}

fn request(
    conn: *muxclient.Conn,
    allocator: std.mem.Allocator,
    id: u64,
    op: panelrpc.Op,
    json: []const u8,
    deadline: i64,
) Outcome {
    conn.sendPanelRequestUntil(id, json, deadline) catch |err| return .{ .failure = .{
        .kind = switch (err) {
            error.TooLong, error.EmptyJson => .request_too_large,
            error.OutOfMemory => .allocation_failed,
            error.PanelSendPreDelivery, error.PanelRpcUnsupported => .send_pre_delivery,
            else => .delivery_uncertain,
        },
        .detail = @errorName(err),
    } };
    while (true) {
        const remain = deadline - clock.nowMs();
        if (remain <= 0) return .{ .failure = .{ .kind = .reply_timeout, .detail = "Timeout" } };
        const frame = conn.recvFrameFor(remain) catch |err| switch (err) {
            error.Timeout => return .{ .failure = .{ .kind = .reply_timeout, .detail = "Timeout" } },
            error.OutOfMemory => return .{ .failure = .{ .kind = .delivery_uncertain, .detail = "OutOfMemory" } },
            else => return .{ .failure = .{ .kind = .disconnected, .detail = @errorName(err) } },
        };
        defer frame.deinit(conn.allocator);
        switch (frame.ftype) {
            .panel_reply => {
                const envelope = wire.decodePanelEnvelope(frame.payload) catch
                    return .{ .failure = .{ .kind = .malformed_reply, .detail = "MalformedReply" } };
                if (envelope.id != id) continue;
                const meta = panelrpc.validateReply(allocator, op, envelope.json) catch |err|
                    return .{ .failure = .{ .kind = .malformed_reply, .detail = @errorName(err) } };
                if (meta.uncertain_delivery) return .{ .failure = .{
                    .kind = .delivery_uncertain,
                    .detail = "daemon reported failure_class=uncertain_delivery",
                    .connection_usable = true,
                } };
                if (meta.pre_delivery_code == .no_compatible_gui) return .{ .failure = .{
                    .kind = .no_compatible_gui,
                    .detail = "no compatible GUI is attached to this session",
                    .connection_usable = true,
                } };
                const reply = allocator.dupe(u8, envelope.json) catch
                    return .{ .failure = .{ .kind = .delivery_uncertain, .detail = "OutOfMemory copying delivered reply" } };
                return .{ .reply = .{ .json = reply, .pre_delivery = meta.pre_delivery } };
            },
            .err, .gone, .exit => return .{ .failure = .{ .kind = .disconnected, .detail = @tagName(frame.ftype) } },
            else => {},
        }
    }
}

fn failureRetiresConnection(failure: Failure) bool {
    return !failure.connection_usable;
}

test "paneldrive retains only failures received over a usable daemon connection" {
    const t = std.testing;
    try t.expect(!failureRetiresConnection(.{
        .kind = .delivery_uncertain,
        .detail = "structured daemon reply",
        .connection_usable = true,
    }));
    try t.expect(failureRetiresConnection(.{
        .kind = .delivery_uncertain,
        .detail = "partial requester write",
    }));
}

fn addTestEntry(pool: *Pool, socket: []const u8, session: []const u8, fd: c_int) !void {
    var conn = muxclient.Conn{
        .allocator = pool.allocator,
        .fd = fd,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    conn.setNonBlocking();
    const owned_socket = try pool.allocator.dupe(u8, socket);
    errdefer pool.allocator.free(owned_socket);
    const owned_session = try pool.allocator.dupe(u8, session);
    errdefer pool.allocator.free(owned_session);
    const owned_origin_id = try pool.allocator.dupe(u8, "00000000000000000000000000000001");
    errdefer pool.allocator.free(owned_origin_id);
    try pool.entries.append(pool.allocator, .{
        .socket = owned_socket,
        .session = owned_session,
        .origin_id = owned_origin_id,
        .conn = conn,
    });
}

test "paneldrive origin prefers exact environment and otherwise names only the default socket" {
    const t = std.testing;
    const old_socket = if (getenv("SKETERM_MUX_SOCKET")) |value| try t.allocator.dupe(u8, value) else null;
    const old_runtime = if (getenv("XDG_RUNTIME_DIR")) |value| try t.allocator.dupe(u8, value) else null;
    defer {
        if (old_socket) |value| {
            const z = std.fmt.allocPrintSentinel(t.allocator, "{s}", .{value}, 0) catch @panic("restore env oom");
            defer t.allocator.free(z);
            _ = c.setenv("SKETERM_MUX_SOCKET", z.ptr, 1);
            t.allocator.free(value);
        } else _ = c.unsetenv("SKETERM_MUX_SOCKET");
        if (old_runtime) |value| {
            const z = std.fmt.allocPrintSentinel(t.allocator, "{s}", .{value}, 0) catch @panic("restore env oom");
            defer t.allocator.free(z);
            _ = c.setenv("XDG_RUNTIME_DIR", z.ptr, 1);
            t.allocator.free(value);
        } else _ = c.unsetenv("XDG_RUNTIME_DIR");
    }

    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact-panel-origin.sock", 1);
    var exact = try Origin.resolve(t.allocator, "session-a");
    defer exact.deinit(t.allocator);
    try t.expectEqual(SocketSource.environment, exact.source);
    try t.expectEqualStrings("/tmp/exact-panel-origin.sock", exact.socket);

    _ = c.setenv("SKETERM_MUX_SOCKET", "relative-panel-origin.sock", 1);
    var relative = try Origin.resolve(t.allocator, "session-a");
    defer relative.deinit(t.allocator);
    try t.expect(relative.socket.len > "relative-panel-origin.sock".len);
    try t.expect(relative.socket[0] == '/');
    try t.expect(std.mem.endsWith(u8, relative.socket, "/relative-panel-origin.sock"));

    _ = c.unsetenv("SKETERM_MUX_SOCKET");
    _ = c.setenv("XDG_RUNTIME_DIR", "/tmp/paneldrive-origin-test", 1);
    var compat = try Origin.resolve(t.allocator, "session-b");
    defer compat.deinit(t.allocator);
    try t.expectEqual(SocketSource.default_compat, compat.source);
    try t.expectEqualStrings("/tmp/paneldrive-origin-test/sketerm/mux.sock", compat.socket);
    try t.expectError(error.MissingSession, Origin.resolve(t.allocator, null));
}

const ReplyScript = struct {
    fd: c_int,
    two_calls: bool = false,
    tag: []const u8 = "ok",

    fn run(self: ReplyScript) void {
        const allocator = std.heap.c_allocator;
        var conn = muxclient.Conn{
            .allocator = allocator,
            .fd = self.fd,
            .panel_rpc = wire.PANEL_RPC_VERSION,
        };
        defer conn.deinit();
        conn.setNonBlocking();
        const first = conn.recvExpectFor(&.{.panel_request}, 2_000) catch
            @panic("paneldrive test did not receive first request");
        const first_env = wire.decodePanelEnvelope(first.payload) catch
            @panic("paneldrive test received malformed request");
        conn.sendPanelReply(first_env.id + 100, "{\"ok\":false,\"stale\":true}") catch
            @panic("paneldrive test could not send stale reply");
        var json_buf: [128]u8 = undefined;
        const json = std.fmt.bufPrint(&json_buf, "{{\"ok\":true,\"tag\":\"{s}\",\"call\":1}}", .{self.tag}) catch
            @panic("paneldrive test reply too long");
        conn.sendPanelReply(first_env.id, json) catch
            @panic("paneldrive test could not send first reply");
        first.deinit(allocator);

        if (!self.two_calls) return;
        const second = conn.recvExpectFor(&.{.panel_request}, 2_000) catch
            @panic("paneldrive test did not receive second request");
        defer second.deinit(allocator);
        const second_env = wire.decodePanelEnvelope(second.payload) catch
            @panic("paneldrive test received malformed second request");
        const json2 = std.fmt.bufPrint(&json_buf, "{{\"ok\":true,\"tag\":\"{s}\",\"call\":2}}", .{self.tag}) catch
            @panic("paneldrive test reply too long");
        conn.sendPanelReply(second_env.id, json2) catch
            @panic("paneldrive test could not send second reply");
    }
};

test "paneldrive skips stale IDs and reuses one session-keyed connection" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    try addTestEntry(&pool, "/tmp/panel-a.sock", "session-a", pair[0]);
    const thread = try std.Thread.spawn(.{}, ReplyScript.run, .{ReplyScript{
        .fd = pair[1],
        .two_calls = true,
    }});
    defer thread.join();

    const origin = Origin{
        .socket = @constCast("/tmp/panel-a.sock"),
        .session = "session-a",
        .source = .environment,
    };
    const first = try pool.callAt(t.allocator, origin, .close, "{\"cmd\":\"panel-close\"}", 2_000);
    switch (first) {
        .reply => |reply| {
            defer t.allocator.free(reply.json);
            try t.expect(std.mem.indexOf(u8, reply.json, "\"call\":1") != null);
            try t.expect(std.mem.indexOf(u8, reply.json, "stale") == null);
        },
        .failure => return error.UnexpectedFailure,
    }
    const second = try pool.callAt(t.allocator, origin, .close, "{\"cmd\":\"panel-close\"}", 2_000);
    switch (second) {
        .reply => |reply| {
            defer t.allocator.free(reply.json);
            try t.expect(std.mem.indexOf(u8, reply.json, "\"call\":2") != null);
        },
        .failure => return error.UnexpectedFailure,
    }
    try t.expectEqual(@as(usize, 1), pool.entries.items.len);
}

test "paneldrive keys persistent connections by daemon and session" {
    const t = std.testing;
    var a_pair: [2]c_int = undefined;
    var b_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &a_pair));
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &b_pair));
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    try addTestEntry(&pool, "/tmp/shared.sock", "a", a_pair[0]);
    try addTestEntry(&pool, "/tmp/shared.sock", "b", b_pair[0]);
    const ta = try std.Thread.spawn(.{}, ReplyScript.run, .{ReplyScript{ .fd = a_pair[1], .tag = "a" }});
    const tb = try std.Thread.spawn(.{}, ReplyScript.run, .{ReplyScript{ .fd = b_pair[1], .tag = "b" }});
    defer ta.join();
    defer tb.join();

    const oa = Origin{ .socket = @constCast("/tmp/shared.sock"), .session = "a", .source = .environment };
    const ob = Origin{ .socket = @constCast("/tmp/shared.sock"), .session = "b", .source = .environment };
    const ra = try pool.callAt(t.allocator, oa, .unknown, "{}", 2_000);
    const rb = try pool.callAt(t.allocator, ob, .unknown, "{}", 2_000);
    switch (ra) {
        .reply => |reply| {
            defer t.allocator.free(reply.json);
            try t.expect(std.mem.indexOf(u8, reply.json, "\"tag\":\"a\"") != null);
        },
        .failure => return error.UnexpectedFailure,
    }
    switch (rb) {
        .reply => |reply| {
            defer t.allocator.free(reply.json);
            try t.expect(std.mem.indexOf(u8, reply.json, "\"tag\":\"b\"") != null);
        },
        .failure => return error.UnexpectedFailure,
    }
    try t.expectEqual(@as(usize, 2), pool.entries.items.len);
}

test "paneldrive keeps immutable origin identity while refreshing a renamed alias" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    defer _ = c.close(pair[1]);
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    try addTestEntry(&pool, "/tmp/renamed.sock", "spawn-name", pair[0]);
    const entry = &pool.entries.items[0];
    const id_before = try t.allocator.dupe(u8, entry.origin_id);
    defer t.allocator.free(id_before);

    try pool.refreshSessionAlias(entry, "display-name");

    try t.expectEqualStrings("display-name", entry.session);
    try t.expectEqualStrings(id_before, entry.origin_id);

    const identified = try pool.identifyUntil(t.allocator, .{
        .socket = @constCast("/tmp/renamed.sock"),
        .session = "display-name",
        .source = .environment,
    }, clock.nowMs() + 1_000);
    switch (identified) {
        .identity => |identity_value| {
            var identity = identity_value;
            defer identity.deinit(t.allocator);
            try t.expectEqualStrings("/tmp/renamed.sock", identity.daemon_origin);
            try t.expectEqualStrings(id_before, identity.origin_id);
        },
        .failure => return error.UnexpectedFailure,
    }
}

const AttachMetadataScript = struct {
    listener: c_int,
    reply: []const u8,
    linger_us: u32 = 0,

    fn run(self: AttachMetadataScript) void {
        const accepted = c.accept(self.listener, null, null);
        if (accepted < 0) return;
        var peer = muxclient.Conn{ .allocator = std.heap.c_allocator, .fd = accepted };
        defer peer.deinit();
        const hello = peer.recvExpect(&.{.hello}) catch return;
        hello.deinit(peer.allocator);
        peer.sendFrame(.welcome, "{\"proto\":0,\"server_proto\":6,\"negotiation\":1,\"panel_rpc\":2}") catch return;
        const attach = peer.recvExpect(&.{.attach}) catch return;
        attach.deinit(peer.allocator);
        peer.sendFrame(.ok, self.reply) catch return;
        if (self.linger_us > 0) _ = c.usleep(self.linger_us);
    }
};

const IdentityRefusalScript = struct {
    listener: c_int,
    saw_fence: *std.atomic.Value(bool),

    fn run(self: IdentityRefusalScript) void {
        const accepted = c.accept(self.listener, null, null);
        if (accepted < 0) return;
        var peer = muxclient.Conn{ .allocator = std.heap.c_allocator, .fd = accepted };
        defer peer.deinit();
        const hello = peer.recvExpect(&.{.hello}) catch return;
        hello.deinit(peer.allocator);
        peer.sendFrame(.welcome, "{\"proto\":0,\"server_proto\":6,\"negotiation\":1,\"panel_rpc\":2}") catch return;
        const attach = peer.recvExpect(&.{.attach}) catch return;
        defer attach.deinit(peer.allocator);
        const Attach = struct { origin_id: []const u8 = "" };
        var parsed = std.json.parseFromSlice(Attach, peer.allocator, attach.payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        self.saw_fence.store(std.mem.eql(u8, parsed.value.origin_id, "00000000000000000000000000000001"), .release);
        peer.sendFrame(.err, "{\"error\":\"session origin identity changed\"}") catch return;
    }
};

fn attachMetadataListener(path: [:0]const u8) !c_int {
    const listener = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (listener < 0) return error.SocketFailed;
    errdefer _ = c.close(listener);
    var addr: c.struct_sockaddr_un = undefined;
    try muxdaemon.fillSockaddrUn(&addr, path);
    if (c.bind(listener, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0)
        return error.BindFailed;
    if (c.listen(listener, 1) != 0) return error.ListenFailed;
    return listener;
}

test "paneldrive evicts gone cached identity before a session alias is reused" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-reuse-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var old_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &old_pair));
    var old_peer = muxclient.Conn{ .allocator = t.allocator, .fd = old_pair[1] };
    defer old_peer.deinit();
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    try addTestEntry(&pool, path, "reused", old_pair[0]);
    try old_peer.sendFrame(.gone, "{\"reason\":\"session exited\"}");

    const listener = try attachMetadataListener(path);
    defer _ = c.close(listener);
    const thread = try std.Thread.spawn(.{}, AttachMetadataScript.run, .{AttachMetadataScript{
        .listener = listener,
        .reply = "{\"ok\":true,\"panel_only\":true,\"origin_name\":\"new-origin\",\"origin_id\":\"00000000000000000000000000000002\"}",
        .linger_us = 250_000,
    }});
    const origin = Origin{ .socket = @constCast(path), .session = "reused", .source = .environment };
    const outcome = try pool.identifyUntil(t.allocator, origin, clock.nowMs() + 2_000);
    switch (outcome) {
        .identity => |identity_value| {
            var identity = identity_value;
            defer identity.deinit(t.allocator);
            // The cached entry's lifetime id (…0001) was evicted, not reused.
            try t.expectEqualStrings("00000000000000000000000000000002", identity.origin_id);
        },
        .failure => return error.UnexpectedFailure,
    }
    thread.join();
    try t.expectEqual(@as(usize, 1), pool.entries.items.len);
    try t.expectEqualStrings("00000000000000000000000000000002", pool.entries.items[0].origin_id);
}

test "paneldrive reports stale inherited identity and never adopts a replacement" {
    const t = std.testing;
    const old_session = if (getenv("SKETERM_SESSION")) |value| try t.allocator.dupe(u8, value) else null;
    const old_id = if (getenv("SKETERM_SESSION_ORIGIN_ID")) |value| try t.allocator.dupe(u8, value) else null;
    defer {
        if (old_session) |value| {
            const z = std.fmt.allocPrintSentinel(t.allocator, "{s}", .{value}, 0) catch @panic("restore env oom");
            defer t.allocator.free(z);
            _ = c.setenv("SKETERM_SESSION", z.ptr, 1);
            t.allocator.free(value);
        } else _ = c.unsetenv("SKETERM_SESSION");
        if (old_id) |value| {
            const z = std.fmt.allocPrintSentinel(t.allocator, "{s}", .{value}, 0) catch @panic("restore env oom");
            defer t.allocator.free(z);
            _ = c.setenv("SKETERM_SESSION_ORIGIN_ID", z.ptr, 1);
            t.allocator.free(value);
        } else _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");
    }
    _ = c.setenv("SKETERM_SESSION", "reused", 1);
    _ = c.setenv("SKETERM_SESSION_ORIGIN_ID", "00000000000000000000000000000001", 1);

    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-stale-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try attachMetadataListener(path);
    defer _ = c.close(listener);
    var saw_fence: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, IdentityRefusalScript.run, .{IdentityRefusalScript{
        .listener = listener,
        .saw_fence = &saw_fence,
    }});
    defer thread.join();

    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    const outcome = try pool.identifyUntil(t.allocator, .{
        .socket = @constCast(path),
        .session = "reused",
        .source = .environment,
    }, clock.nowMs() + 2_000);
    switch (outcome) {
        .failure => |failure| try t.expectEqual(FailureKind.identity_mismatch, failure.kind),
        .identity => |identity_value| {
            var identity = identity_value;
            identity.deinit(t.allocator);
            return error.UnexpectedIdentity;
        },
    }
    try t.expect(saw_fence.load(.acquire));
    try t.expectEqual(@as(usize, 0), pool.entries.items.len);
}

test "paneldrive classifies missing attach identity as malformed and caches nothing" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-malformed-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try attachMetadataListener(path);
    defer _ = c.close(listener);
    const thread = try std.Thread.spawn(.{}, AttachMetadataScript.run, .{AttachMetadataScript{
        .listener = listener,
        .reply = "{\"ok\":true,\"panel_only\":true}",
    }});
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    const origin = Origin{ .socket = @constCast(path), .session = "requested-alias", .source = .environment };
    const outcome = try pool.identifyUntil(t.allocator, origin, clock.nowMs() + 2_000);
    switch (outcome) {
        .failure => |failure| try t.expectEqual(FailureKind.malformed_attach, failure.kind),
        .identity => |identity_value| {
            var identity = identity_value;
            identity.deinit(t.allocator);
            return error.UnexpectedIdentity;
        },
    }
    thread.join();
    try t.expectEqual(@as(usize, 0), pool.entries.items.len);
}

const TimeoutScript = struct {
    fd: c_int,
    requests: *std.atomic.Value(u32),

    fn run(self: TimeoutScript) void {
        const allocator = std.heap.c_allocator;
        var conn = muxclient.Conn{
            .allocator = allocator,
            .fd = self.fd,
            .panel_rpc = wire.PANEL_RPC_VERSION,
        };
        defer conn.deinit();
        conn.setNonBlocking();
        const first = conn.recvExpectFor(&.{.panel_request}, 2_000) catch
            @panic("paneldrive timeout test received no request");
        first.deinit(allocator);
        _ = self.requests.fetchAdd(1, .acq_rel);
        if (conn.recvExpectFor(&.{.panel_request}, 250)) |second| {
            second.deinit(allocator);
            _ = self.requests.fetchAdd(1, .acq_rel);
        } else |_| {}
    }
};

test "paneldrive never resends after uncertain delivery" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    try addTestEntry(&pool, "/tmp/timeout.sock", "s", pair[0]);
    var requests: std.atomic.Value(u32) = .init(0);
    const thread = try std.Thread.spawn(.{}, TimeoutScript.run, .{TimeoutScript{
        .fd = pair[1],
        .requests = &requests,
    }});

    const origin = Origin{ .socket = @constCast("/tmp/timeout.sock"), .session = "s", .source = .environment };
    const outcome = try pool.callAt(t.allocator, origin, .show, "{\"cmd\":\"panel-show\"}", 50);
    switch (outcome) {
        .failure => |failure| {
            try t.expectEqual(FailureKind.reply_timeout, failure.kind);
            try t.expect(failure.uncertain());
        },
        .reply => |reply| {
            t.allocator.free(reply.json);
            return error.UnexpectedReply;
        },
    }
    thread.join();
    try t.expectEqual(@as(u32, 1), requests.load(.acquire));
    try t.expectEqual(@as(usize, 0), pool.entries.items.len);
}

const SingleReplyScript = struct {
    fd: c_int,
    json: []const u8,

    fn run(self: SingleReplyScript) void {
        const allocator = std.heap.c_allocator;
        var conn = muxclient.Conn{
            .allocator = allocator,
            .fd = self.fd,
            .panel_rpc = wire.PANEL_RPC_VERSION,
        };
        defer conn.deinit();
        conn.setNonBlocking();
        const frame = conn.recvExpectFor(&.{.panel_request}, 2_000) catch
            @panic("paneldrive shape test received no request");
        defer frame.deinit(allocator);
        const envelope_value = wire.decodePanelEnvelope(frame.payload) catch
            @panic("paneldrive shape test received malformed request");
        conn.sendPanelReply(envelope_value.id, self.json) catch
            @panic("paneldrive shape test could not send reply");
    }
};

test "paneldrive rejects malformed valid-JSON response shapes and missing panel ids" {
    const t = std.testing;
    for ([_][]const u8{
        "[]",
        "{}",
        "{\"ok\":\"yes\"}",
        "{\"ok\":true}",
        "{\"ok\":true,\"panel_id\":0}",
        "{\"ok\":false}",
    }) |bad_reply| {
        var pair: [2]c_int = undefined;
        try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
        var pool = Pool.init(t.allocator);
        defer pool.deinit();
        try addTestEntry(&pool, "/tmp/shape.sock", "s", pair[0]);
        const thread = try std.Thread.spawn(.{}, SingleReplyScript.run, .{SingleReplyScript{
            .fd = pair[1],
            .json = bad_reply,
        }});

        const origin = Origin{ .socket = @constCast("/tmp/shape.sock"), .session = "s", .source = .environment };
        const outcome = try pool.callAt(t.allocator, origin, .show, "{\"cmd\":\"panel-show\"}", 2_000);
        switch (outcome) {
            .failure => |failure| {
                try t.expectEqual(FailureKind.malformed_reply, failure.kind);
                try t.expect(failure.uncertain());
            },
            .reply => |reply| {
                t.allocator.free(reply.json);
                return error.UnexpectedReply;
            },
        }
        thread.join();
        try t.expectEqual(@as(usize, 0), pool.entries.items.len);
    }
}

test "paneldrive consumes daemon uncertain-delivery failures without retiring the connection" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    try addTestEntry(&pool, "/tmp/uncertain.sock", "s", pair[0]);
    const thread = try std.Thread.spawn(.{}, SingleReplyScript.run, .{SingleReplyScript{
        .fd = pair[1],
        .json = "{\"ok\":false,\"error\":\"presenter disconnected\",\"failure_class\":\"uncertain_delivery\",\"mutation_may_have_applied\":true,\"resend_safe\":false}",
    }});

    const origin = Origin{ .socket = @constCast("/tmp/uncertain.sock"), .session = "s", .source = .environment };
    const outcome = try pool.callAt(t.allocator, origin, .patch, "{\"cmd\":\"panel-patch\"}", 2_000);
    switch (outcome) {
        .failure => |failure| {
            try t.expectEqual(FailureKind.delivery_uncertain, failure.kind);
            try t.expect(failure.uncertain());
            try t.expect(std.mem.indexOf(u8, failure.detail, "failure_class=uncertain_delivery") != null);
        },
        .reply => |reply| {
            t.allocator.free(reply.json);
            return error.UnexpectedReply;
        },
    }
    thread.join();
    try t.expectEqual(@as(usize, 1), pool.entries.items.len);
}

test "paneldrive reports a validated pre-delivery reply without retiring the connection" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    try addTestEntry(&pool, "/tmp/predelivery.sock", "s", pair[0]);
    const thread = try std.Thread.spawn(.{}, SingleReplyScript.run, .{SingleReplyScript{
        .fd = pair[1],
        .json = "{\"ok\":false,\"error\":\"queue full\",\"failure_class\":\"pre_delivery\",\"mutation_may_have_applied\":false,\"resend_safe\":true}",
    }});

    const origin = Origin{ .socket = @constCast("/tmp/predelivery.sock"), .session = "s", .source = .environment };
    const outcome = try pool.callAt(t.allocator, origin, .show, "{\"cmd\":\"panel-show\"}", 2_000);
    switch (outcome) {
        .reply => |reply| {
            defer t.allocator.free(reply.json);
            try t.expect(reply.pre_delivery);
        },
        .failure => return error.UnexpectedFailure,
    }
    thread.join();
    try t.expectEqual(@as(usize, 1), pool.entries.items.len);
}

fn maxPanelDocument(allocator: std.mem.Allocator) ![]u8 {
    const prefix = "{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"ok\"}},\"padding\":\"";
    const suffix = "\"}";
    const max = 1 << 20;
    const out = try allocator.alloc(u8, max);
    @memcpy(out[0..prefix.len], prefix);
    const body = out[prefix.len .. max - suffix.len];
    var i: usize = 0;
    while (i + 1 < body.len) : (i += 2) {
        body[i] = '\\';
        body[i + 1] = '"';
    }
    if (i < body.len) body[i] = 'x';
    @memcpy(out[max - suffix.len ..], suffix);
    return out;
}

const MaxRequestScript = struct {
    fd: c_int,
    document_len: usize,

    fn run(self: MaxRequestScript) void {
        const allocator = std.heap.c_allocator;
        var conn = muxclient.Conn{
            .allocator = allocator,
            .fd = self.fd,
            .panel_rpc = wire.PANEL_RPC_VERSION,
        };
        defer conn.deinit();
        conn.setNonBlocking();
        const frame = conn.recvExpectFor(&.{.panel_request}, 5_000) catch
            @panic("maximum panel request did not reach relay peer");
        defer frame.deinit(allocator);
        const envelope_value = wire.decodePanelEnvelope(frame.payload) catch
            @panic("maximum panel request envelope was malformed");
        var parsed = protocol.parseRequest(allocator, envelope_value.json) catch
            @panic("maximum panel request did not pass direct protocol parsing");
        defer parsed.deinit();
        if (parsed.value.document == null or parsed.value.document.?.len != self.document_len)
            @panic("maximum panel document changed at the relay boundary");
        conn.sendPanelReply(envelope_value.id, "{\"ok\":true,\"panel_id\":91}") catch
            @panic("maximum panel request reply failed");
    }
};

test "maximum valid panel document fits direct request and relay envelopes exactly" {
    const t = std.testing;
    const document = try maxPanelDocument(t.allocator);
    defer t.allocator.free(document);
    try t.expectEqual(@as(usize, 1 << 20), document.len);
    var document_json = std.json.parseFromSlice(std.json.Value, t.allocator, document, .{}) catch
        return error.InvalidBoundaryDocument;
    document_json.deinit();

    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(protocol.Request{
        .cmd = "panel-show",
        .session = "boundary-session",
        .name = "boundary",
        .target = "tab",
        .document = document,
    }, .{}, &aw.writer);
    const line = aw.written();
    try t.expect(line.len > (1 << 20));
    try t.expect(line.len <= protocol.MAX_LINE);
    try t.expect(line.len <= wire.PANEL_JSON_MAX);
    var direct = try protocol.parseRequest(t.allocator, line);
    defer direct.deinit();
    try t.expectEqual(document.len, direct.value.document.?.len);

    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    try addTestEntry(&pool, "/tmp/max-panel.sock", "boundary-session", pair[0]);
    const thread = try std.Thread.spawn(.{}, MaxRequestScript.run, .{MaxRequestScript{
        .fd = pair[1],
        .document_len = document.len,
    }});
    const origin = Origin{
        .socket = @constCast("/tmp/max-panel.sock"),
        .session = "boundary-session",
        .source = .environment,
    };
    const outcome = try pool.callAt(t.allocator, origin, .show, line, 5_000);
    switch (outcome) {
        .reply => |reply| {
            defer t.allocator.free(reply.json);
            try t.expect(std.mem.indexOf(u8, reply.json, "\"panel_id\":91") != null);
        },
        .failure => return error.UnexpectedFailure,
    }
    thread.join();
}

test "panel relay oversize and allocation failures are definitely pre-delivery" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    defer _ = c.close(pair[1]);
    var conn = muxclient.Conn{
        .allocator = t.allocator,
        .fd = pair[0],
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer conn.deinit();
    conn.setNonBlocking();
    const too_large = try t.allocator.alloc(u8, wire.PANEL_JSON_MAX + 1);
    defer t.allocator.free(too_large);
    @memset(too_large, 'x');
    const oversized = request(&conn, t.allocator, 1, .show, too_large, clock.nowMs() + 1_000);
    switch (oversized) {
        .failure => |failure| {
            try t.expectEqual(FailureKind.request_too_large, failure.kind);
            try t.expect(!failure.uncertain());
        },
        .reply => |reply| {
            t.allocator.free(reply.json);
            return error.UnexpectedReply;
        },
    }
    var pfd = c.struct_pollfd{ .fd = pair[1], .events = c.POLLIN, .revents = 0 };
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));

    var oom_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &oom_pair));
    defer _ = c.close(oom_pair[1]);
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var oom_conn = muxclient.Conn{
        .allocator = failing.allocator(),
        .fd = oom_pair[0],
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer oom_conn.deinit();
    oom_conn.setNonBlocking();
    const oom = request(&oom_conn, t.allocator, 2, .show, "{\"cmd\":\"panel-show\"}", clock.nowMs() + 1_000);
    switch (oom) {
        .failure => |failure| {
            try t.expectEqual(FailureKind.allocation_failed, failure.kind);
            try t.expect(!failure.uncertain());
        },
        .reply => |reply| {
            t.allocator.free(reply.json);
            return error.UnexpectedReply;
        },
    }
    pfd = .{ .fd = oom_pair[1], .events = c.POLLIN, .revents = 0 };
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));
}
