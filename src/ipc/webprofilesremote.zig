//! The BROKER-owned face of the headless browser-profile store.
//!
//! `webprofiles.Store` is process-exclusive (one CEF `root_cache_path`,
//! one flock holder), which used to make the MCP client itself the
//! owner — and the SECOND concurrent client of one instance was
//! refused profiles outright. This module moves ownership to the mux
//! daemon (the one process that outlives every client): the client
//! asks the daemon for profile ids over `web_op profile_*` requests and
//! receives the store ROOT path to hand the helper as `--cache-dir`.
//! Same host by construction — the daemon lives next to the instance
//! dir it serves.
//!
//! Gated on the daemon welcome's `web_profiles` capability; against an
//! old daemon `open` fails with `error.Unsupported` and the caller
//! falls back to taking the flock itself, i.e. exactly the
//! pre-existing single-owner behavior.
//!
//! GTK-free and libc-only, like every other src/ipc module.

const std = @import("std");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const webprofiles = @import("webprofiles.zig");

/// Per-op deadline. Store ops are local disk work on the daemon; the
/// budget mostly covers a cold daemon autostart on reconnect.
const OP_DEADLINE_MS: i64 = 10_000;

pub const Error = webprofiles.Error;

/// One profile row as the daemon reports it. Name memory belongs to
/// the arena the call was given.
pub const Entry = struct {
    name: []const u8,
    id: u32,
    created_ms: i64,
    last_used_ms: i64,
};

pub const RetireResult = struct { removed: bool, id: u32 };

pub const Remote = struct {
    gpa: std.mem.Allocator,
    /// Daemon socket; owned.
    sock: []u8,
    /// Instance key the store is asked under; owned.
    instance: []u8,
    /// Store root (the helper's future `--cache-dir`); owned.
    root: []u8,
    conn: ?muxclient.Conn = null,
    next_req: u32 = 1,

    pub const OpenError = error{ Unsupported, Refused, Io, OutOfMemory };

    /// Connect, verify the capability, and open the daemon-side store.
    /// On `error.Refused` the daemon's own sentence is copied into
    /// `reason_buf` (`reason_len` bytes).
    pub fn open(
        gpa: std.mem.Allocator,
        mux_sock: []const u8,
        instance: []const u8,
        reason_buf: []u8,
        reason_len: *usize,
    ) OpenError!Remote {
        reason_len.* = 0;
        var self = Remote{ .gpa = gpa, .sock = &.{}, .instance = &.{}, .root = &.{} };
        errdefer self.deinit();
        self.sock = gpa.dupe(u8, mux_sock) catch return error.OutOfMemory;
        self.instance = gpa.dupe(u8, instance) catch return error.OutOfMemory;
        _ = self.ensureConn() catch |err| return switch (err) {
            error.Unsupported => error.Unsupported,
            else => error.Io,
        };
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            root: []const u8 = "",
            @"error": []const u8 = "",
        };
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const reply = self.roundTrip(Reply, arena_state.allocator(), .{
            .op = "profile_open",
            .instance = self.instance,
        }) catch return error.Io;
        if (!reply.ok or reply.root.len == 0) {
            const msg = reply.@"error";
            const n = @min(msg.len, reason_buf.len);
            @memcpy(reason_buf[0..n], msg[0..n]);
            reason_len.* = n;
            return error.Refused;
        }
        self.root = gpa.dupe(u8, reply.root) catch return error.OutOfMemory;
        return self;
    }

    pub fn deinit(self: *Remote) void {
        self.dropConn();
        if (self.sock.len > 0) self.gpa.free(self.sock);
        if (self.instance.len > 0) self.gpa.free(self.instance);
        if (self.root.len > 0) self.gpa.free(self.root);
        self.sock = &.{};
        self.instance = &.{};
        self.root = &.{};
    }

    /// The daemon connection's fd for the MCP watchdog; -1 when none.
    pub fn watchdogFd(self: *const Remote) c_int {
        if (self.conn) |*cn| return cn.fd;
        return -1;
    }

    /// The id `name` must be opened with (daemon mints + persists it).
    pub fn ensure(self: *Remote, name: []const u8) Error!u32 {
        if (!webprofiles.validName(name)) return error.BadName;
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            id: u32 = 0,
            @"error": []const u8 = "",
        };
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const reply = self.opWithRetry(Reply, arena_state.allocator(), .{
            .op = "profile_ensure",
            .instance = self.instance,
            .name = name,
        }) catch return error.Io;
        if (!reply.ok or reply.id == 0) return error.Io;
        return reply.id;
    }

    /// Every profile the daemon-side store knows; rows live in `arena`.
    pub fn entries(self: *Remote, arena: std.mem.Allocator) Error![]Entry {
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            profiles: []Entry = &.{},
            @"error": []const u8 = "",
        };
        const reply = self.opWithRetry(Reply, arena, .{
            .op = "profile_list",
            .instance = self.instance,
        }) catch return error.Io;
        if (!reply.ok) return error.Io;
        return reply.profiles;
    }

    /// One profile's row, or null; name memory lives in `arena`.
    pub fn find(self: *Remote, arena: std.mem.Allocator, name: []const u8) ?Entry {
        const rows = self.entries(arena) catch return null;
        for (rows) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// Best-effort last-used stamp, like the local store's `touch`.
    pub fn touch(self: *Remote, name: []const u8) void {
        const Reply = struct { req: u32 = 0, ok: bool = false, @"error": []const u8 = "" };
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        _ = self.opWithRetry(Reply, arena_state.allocator(), .{
            .op = "profile_touch",
            .instance = self.instance,
            .name = name,
        }) catch return;
    }

    /// Drop the entry and erase its jar (the daemon does the rmtree —
    /// the jar is under ITS root).
    pub fn retire(self: *Remote, name: []const u8) Error!RetireResult {
        if (!webprofiles.validName(name)) return error.BadName;
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            removed: bool = false,
            id: u32 = 0,
            @"error": []const u8 = "",
        };
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const reply = self.opWithRetry(Reply, arena_state.allocator(), .{
            .op = "profile_retire",
            .instance = self.instance,
            .name = name,
        }) catch return error.Io;
        if (!reply.ok) return error.Io;
        return .{ .removed = reply.removed, .id = reply.id };
    }

    pub const EngineInfo = struct {
        /// The engine's listening socket path, in `arena`.
        sock: []const u8,
        /// Engine pid as the daemon knows it; 0 for an engine the
        /// daemon only probed (a predecessor broker's, still lingering).
        pid: c.pid_t,
        /// True when this call caused the spawn — the caller owns the
        /// bind wait (CEF startup is seconds).
        spawned: bool,
        diagnostics: bool = false,
    };

    /// Ask the daemon for its broker-owned engine (spawn-if-absent,
    /// linger lifecycle). `error.Unsupported` against a daemon without
    /// the `web_engine` capability — the caller then spawns the helper
    /// itself, i.e. the Phase 2 shape.
    pub fn engineOpen(self: *Remote, arena: std.mem.Allocator) error{ Unsupported, Io }!EngineInfo {
        {
            const cn = self.ensureConn() catch |err| return switch (err) {
                error.Unsupported => error.Unsupported,
                else => error.Io,
            };
            if (!cn.web_engine) return error.Unsupported;
        }
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            sock: []const u8 = "",
            pid: c.pid_t = 0,
            spawned: bool = false,
            diagnostics: bool = false,
            @"error": []const u8 = "",
        };
        const reply = self.opWithRetry(Reply, arena, .{
            .op = "engine_open",
            .instance = self.instance,
        }) catch return error.Io;
        if (!reply.ok or reply.sock.len == 0) return error.Io;
        return .{ .sock = reply.sock, .pid = reply.pid, .spawned = reply.spawned, .diagnostics = reply.diagnostics };
    }

    /// Call only after engine_open explicitly advertised diagnostics. Older
    /// brokers never receive an unknown verb. Does not spawn or restart anything.
    pub fn engineDiagnostic(self: *Remote, arena: std.mem.Allocator) !@import("../web/diagnostic.zig").Report {
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            diagnostic: @import("../web/diagnostic.zig").Report = .{},
        };
        const reply = try self.opWithRetry(Reply, arena, .{ .op = "engine_diagnostic", .instance = self.instance });
        if (!reply.ok) return error.Io;
        return reply.diagnostic;
    }

    /// Daemon advertises `web_engine` (it will answer engine_open).
    pub fn engineSupported(self: *Remote) bool {
        const cn = self.ensureConn() catch return false;
        return cn.web_engine;
    }

    fn dropConn(self: *Remote) void {
        if (self.conn) |*cn| {
            cn.deinit();
            self.conn = null;
        }
    }

    fn ensureConn(self: *Remote) error{ Unsupported, Io }!*muxclient.Conn {
        if (self.conn) |*cn| return cn;
        var cn = muxclient.Conn.connectLocalAutostartAt(self.gpa, self.sock) catch return error.Io;
        if (!cn.web_profiles) {
            cn.deinit();
            return error.Unsupported;
        }
        self.conn = cn;
        return &self.conn.?;
    }

    /// One request/reply, reconnecting ONCE on a dead connection (the
    /// daemon is durable, but it can have been retired or replaced
    /// between two of a long-lived client's calls).
    fn opWithRetry(self: *Remote, comptime Reply: type, arena: std.mem.Allocator, body: anytype) !Reply {
        return self.roundTrip(Reply, arena, body) catch {
            self.dropConn();
            _ = self.ensureConn() catch return error.Io;
            return self.roundTrip(Reply, arena, body);
        };
    }

    fn roundTrip(self: *Remote, comptime Reply: type, arena: std.mem.Allocator, body: anytype) !Reply {
        const cn = try self.ensureConn();
        const req = self.next_req;
        self.next_req +%= 1;
        if (self.next_req == 0) self.next_req = 1;
        const deadline = clock.nowMs() + OP_DEADLINE_MS;
        const Framed = WithReq(@TypeOf(body));
        try cn.sendJsonUntil(.web_op, Framed{ .req = req, .body = body }, deadline);
        while (true) {
            const left = deadline - clock.nowMs();
            if (left <= 0) return error.Timeout;
            const frame = try cn.recvFrameFor(left);
            defer frame.deinit(self.gpa);
            if (frame.ftype != .web_reply) continue;
            // alloc_always: the frame payload dies with this iteration,
            // so every string field must be copied into the arena — the
            // default hands back slices of the input when no unescaping
            // is needed, i.e. dangling pointers.
            const parsed = std.json.parseFromSliceLeaky(Reply, arena, frame.payload, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch continue;
            if (parsed.req != req) continue;
            return parsed;
        }
    }
};

/// The op body with `req` folded in at the top level (the wire shape
/// is flat; `body` is comptime-flattened by jsonStringify below).
fn WithReq(comptime Body: type) type {
    return struct {
        req: u32,
        body: Body,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("req");
            try jw.write(self.req);
            inline for (@typeInfo(Body).@"struct".fields) |f| {
                try jw.objectField(f.name);
                try jw.write(@field(self.body, f.name));
            }
            try jw.endObject();
        }
    };
}
