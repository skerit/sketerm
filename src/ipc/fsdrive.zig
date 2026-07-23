//! fsdrive: mux file-service client (fs_op / fs_write frames).
//!
//! The client half of the phase-1 file browser (docs/
//! filebrowser-roadmap.md): rich listings, live directory views with
//! pushed deltas, ranged read/write, and the small mutation verbs —
//! all over one mux connection (local socket, SSH, or UDP; the
//! transport is Conn's business). GTK-free and libc-only so it serves
//! the GUI browser pane, MCP tools, and headless smokes alike.
//!
//! No-hang invariant: every wait is deadline-bounded (recvFrameFor);
//! replies are matched by the `req` nonce in the fs_reply HEADER,
//! never by arrival order, and fs_delta pushes arriving mid-wait are
//! stashed, not dropped.

const std = @import("std");
const c = @import("../c.zig").c;
const client = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
pub const fsserve = @import("../mux/fsserve.zig");

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

pub const Entry = fsserve.Entry;

/// Bound on any single fs round trip. Well under the MCP watchdog.
pub const OP_TIMEOUT_MS: i64 = 10_000;

pub const Error = error{
    NotConnected,
    Timeout,
    /// Daemon answered ok:false — message in `lastErr()`.
    FsOpFailed,
    BadReply,
    OutOfMemory,
};

/// A collected listing (open_view or one-shot list). Entry strings
/// live in the listing's own arena.
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8 = "",
    entries: []Entry = &.{},
    truncated: bool = false,

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
    }
};

/// One pushed view delta. Owned by its arena; free via deinit.
pub const Delta = struct {
    arena: std.heap.ArenaAllocator,
    view: u32 = 0,
    gone: bool = false,
    resync: bool = false,
    changes: []Change = &.{},

    pub const Change = struct {
        op: []const u8 = "",
        name: []const u8 = "",
        entry: ?Entry = null,
    };

    pub fn deinit(self: *Delta) void {
        self.arena.deinit();
    }
};

pub const WriteFlags = struct {
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,

    fn byte(self: WriteFlags) u8 {
        var b: u8 = 0;
        if (self.create) b |= 1;
        if (self.truncate) b |= 2;
        if (self.append) b |= 4;
        if (self.exclusive) b |= 8;
        return b;
    }
};

pub const ReadInfo = struct { size: u64, eof: bool };

/// Superset JSON shape of every fs_reply; absent fields keep their
/// defaults, unknown (future) fields are ignored.
const Reply = struct {
    req: u32 = 0,
    ok: bool = false,
    @"error": []const u8 = "",
    path: []const u8 = "",
    entries: []Entry = &.{},
    more: bool = false,
    truncated: bool = false,
    entry: ?Entry = null,
    size: u64 = 0,
    eof: bool = false,
    written: u64 = 0,
};

pub const Fs = struct {
    allocator: std.mem.Allocator,
    conn: client.Conn,
    next_req: u32 = 1,
    /// fs_delta frames that arrived while awaiting a reply; consumed
    /// via takeDelta(). Bounded by consumption — a caller that opens
    /// views must drain deltas.
    deltas: std.ArrayList(Delta) = .empty,
    last_err: [192]u8 = undefined,
    last_err_len: usize = 0,

    /// Adopt an already hello-probed connection (ownership moves).
    pub fn initConn(allocator: std.mem.Allocator, conn: client.Conn) Fs {
        return .{ .allocator = allocator, .conn = conn };
    }

    /// Connect to a daemon socket and complete the hello probe.
    pub fn connect(allocator: std.mem.Allocator, sock_path: []const u8) !Fs {
        const conn = try client.Conn.connectProbed(allocator, sock_path);
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn deinit(self: *Fs) void {
        for (self.deltas.items) |*d| d.deinit();
        self.deltas.deinit(self.allocator);
        self.conn.deinit();
    }

    pub fn lastErr(self: *const Fs) []const u8 {
        return self.last_err[0..self.last_err_len];
    }

    fn setErr(self: *Fs, msg: []const u8) void {
        const n = @min(msg.len, self.last_err.len);
        @memcpy(self.last_err[0..n], msg[0..n]);
        self.last_err_len = n;
    }

    fn nextReq(self: *Fs) u32 {
        const r = self.next_req;
        self.next_req +%= 1;
        if (self.next_req == 0) self.next_req = 1;
        return r;
    }

    fn stashDelta(self: *Fs, payload: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const a = arena.allocator();
        const Wire = struct {
            view: u32 = 0,
            gone: bool = false,
            resync: bool = false,
            changes: []Delta.Change = &.{},
        };
        // alloc_always: the frame payload dies with the caller's scope —
        // parsed strings must never alias it.
        const parsed = std.json.parseFromSliceLeaky(Wire, a, payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            arena.deinit();
            return;
        };
        self.deltas.append(self.allocator, .{
            .arena = arena,
            .view = parsed.view,
            .gone = parsed.gone,
            .resync = parsed.resync,
            .changes = parsed.changes,
        }) catch arena.deinit();
    }

    /// Pop the oldest pending delta (caller deinits), draining any
    /// bytes already on the socket first — never blocks.
    pub fn takeDelta(self: *Fs) ?Delta {
        _ = self.conn.fillAvailable();
        while (self.conn.takeFrame() catch null) |f| {
            defer f.deinit(self.allocator);
            if (f.ftype == .fs_delta) self.stashDelta(f.payload);
        }
        if (self.deltas.items.len == 0) return null;
        return self.deltas.orderedRemove(0);
    }

    /// Block (bounded) until at least one delta is pending or the
    /// timeout passes. Returns the number of pending deltas.
    pub fn waitDelta(self: *Fs, timeout_ms: i64) usize {
        const deadline = nowMs() + timeout_ms;
        while (self.deltas.items.len == 0) {
            const remain = deadline - nowMs();
            if (remain <= 0) break;
            const f = self.conn.recvFrameFor(remain) catch break;
            defer f.deinit(self.allocator);
            if (f.ftype == .fs_delta) self.stashDelta(f.payload);
        }
        return self.deltas.items.len;
    }

    /// Await the fs_reply matching `req`, stashing deltas and dropping
    /// stale replies meanwhile. On success the parsed Reply is arena-
    /// allocated into `arena`.
    fn awaitReply(self: *Fs, arena: std.mem.Allocator, req: u32, timeout_ms: i64) Error!Reply {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            const remain = deadline - nowMs();
            if (remain <= 0) return Error.Timeout;
            const f = self.conn.recvFrameFor(remain) catch |err| switch (err) {
                error.Timeout => return Error.Timeout,
                else => return Error.NotConnected,
            };
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .fs_delta => self.stashDelta(f.payload),
                .fs_reply => {
                    // alloc_always: f.payload is freed on return; the
                    // reply must own its strings (use-after-free bug
                    // class — flaky SEGV in the smoke, once).
                    const rep = std.json.parseFromSliceLeaky(Reply, arena, f.payload, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    }) catch return Error.BadReply;
                    if (rep.req != req) continue; // stale (abandoned request)
                    if (!rep.ok) {
                        self.setErr(rep.@"error");
                        return Error.FsOpFailed;
                    }
                    return rep;
                },
                .err => {
                    self.setErr(f.payload);
                    return Error.FsOpFailed;
                },
                else => {},
            }
        }
    }

    fn sendOp(self: *Fs, op: []const u8, req: u32, args: anytype) Error!void {
        const Base = struct {
            req: u32,
            op: []const u8,
            path: []const u8 = "",
            to: []const u8 = "",
            view: u32 = 0,
            off: u64 = 0,
            len: u32 = 0,
        };
        var b: Base = .{ .req = req, .op = op };
        inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |fld| {
            @field(b, fld.name) = @field(args, fld.name);
        }
        self.conn.sendJson(.fs_op, b) catch return Error.NotConnected;
    }

    /// Collect a chunked listing reply run into one Listing.
    fn collectListing(self: *Fs, req: u32) Error!Listing {
        var out: Listing = .{ .arena = std.heap.ArenaAllocator.init(self.allocator) };
        errdefer out.deinit();
        const a = out.arena.allocator();
        var entries: std.ArrayList(Entry) = .empty;

        while (true) {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const rep = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
            if (out.path.len == 0 and rep.path.len > 0)
                out.path = a.dupe(u8, rep.path) catch return Error.OutOfMemory;
            if (rep.truncated) out.truncated = true;
            for (rep.entries) |e| {
                entries.append(a, dupeEntry(a, e) catch return Error.OutOfMemory) catch
                    return Error.OutOfMemory;
            }
            if (!rep.more) break;
        }
        out.entries = entries.items;
        return out;
    }

    fn dupeEntry(a: std.mem.Allocator, e: Entry) !Entry {
        var d = e;
        d.name = try a.dupe(u8, e.name);
        d.kind = try a.dupe(u8, e.kind);
        if (e.target) |t| d.target = try a.dupe(u8, t);
        return d;
    }

    /// Open a live directory view: full listing now, fs_delta pushes
    /// until closeView. `view_id` is caller-chosen and client-scoped.
    pub fn openView(self: *Fs, view_id: u32, path: []const u8) Error!Listing {
        const req = self.nextReq();
        try self.sendOp("open_view", req, .{ .path = path, .view = view_id });
        return self.collectListing(req);
    }

    /// One-shot listing, no subscription.
    pub fn list(self: *Fs, path: []const u8) Error!Listing {
        const req = self.nextReq();
        try self.sendOp("list", req, .{ .path = path });
        return self.collectListing(req);
    }

    pub fn closeView(self: *Fs, view_id: u32) Error!void {
        const req = self.nextReq();
        try self.sendOp("close_view", req, .{ .view = view_id });
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        _ = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
    }

    /// Stat one path. Returned entry strings live in `arena` (caller-
    /// provided so the result can outlive the call).
    pub fn statPath(self: *Fs, arena: std.mem.Allocator, path: []const u8) Error!Entry {
        const req = self.nextReq();
        try self.sendOp("stat", req, .{ .path = path });
        const rep = try self.awaitReply(arena, req, OP_TIMEOUT_MS);
        return rep.entry orelse Error.BadReply;
    }

    pub fn mkdir(self: *Fs, path: []const u8) Error!void {
        try self.simpleOp("mkdir", .{ .path = path });
    }

    pub fn rename(self: *Fs, from: []const u8, to: []const u8) Error!void {
        try self.simpleOp("rename", .{ .path = from, .to = to });
    }

    /// Delete ONE entry (file/link/empty dir) — recursive delete is a
    /// phase-2 job.
    pub fn deletePath(self: *Fs, path: []const u8) Error!void {
        try self.simpleOp("delete", .{ .path = path });
    }

    /// Create a symlink at `path` pointing to `target`.
    pub fn symlink(self: *Fs, target: []const u8, path: []const u8) Error!void {
        try self.simpleOp("symlink", .{ .path = path, .to = target });
    }

    fn simpleOp(self: *Fs, op: []const u8, args: anytype) Error!void {
        const req = self.nextReq();
        try self.sendOp(op, req, args);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        _ = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
    }

    /// Ranged read appended to `out`. One call fetches at most
    /// fsserve.MAX_READ bytes; loop while !eof for more.
    pub fn read(self: *Fs, path: []const u8, off: u64, len: u32, out: *std.ArrayList(u8)) Error!ReadInfo {
        const req = self.nextReq();
        try self.sendOp("read", req, .{ .path = path, .off = off, .len = len });
        const deadline = nowMs() + OP_TIMEOUT_MS;
        while (true) {
            const remain = deadline - nowMs();
            if (remain <= 0) return Error.Timeout;
            const f = self.conn.recvFrameFor(remain) catch |err| switch (err) {
                error.Timeout => return Error.Timeout,
                else => return Error.NotConnected,
            };
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .fs_delta => self.stashDelta(f.payload),
                .fs_data => {
                    if (f.payload.len < 12) continue;
                    if (std.mem.readInt(u32, f.payload[0..4], .little) != req) continue;
                    out.appendSlice(self.allocator, f.payload[12..]) catch
                        return Error.OutOfMemory;
                },
                .fs_reply => {
                    var scratch = std.heap.ArenaAllocator.init(self.allocator);
                    defer scratch.deinit();
                    const rep = std.json.parseFromSliceLeaky(Reply, scratch.allocator(), f.payload, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    }) catch return Error.BadReply;
                    if (rep.req != req) continue;
                    if (!rep.ok) {
                        self.setErr(rep.@"error");
                        return Error.FsOpFailed;
                    }
                    return .{ .size = rep.size, .eof = rep.eof };
                },
                .err => {
                    self.setErr(f.payload);
                    return Error.FsOpFailed;
                },
                else => {},
            }
        }
    }

    /// Write `data` at `off` (or append). Returns bytes written.
    pub fn write(self: *Fs, path: []const u8, off: u64, data: []const u8, flags: WriteFlags) Error!u64 {
        if (path.len > std.math.maxInt(u16)) return Error.BadReply;
        const req = self.nextReq();
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var hdr: [15]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], req, .little);
        std.mem.writeInt(u64, hdr[4..12], off, .little);
        hdr[12] = flags.byte();
        std.mem.writeInt(u16, hdr[13..15], @intCast(path.len), .little);
        payload.appendSlice(self.allocator, &hdr) catch return Error.OutOfMemory;
        payload.appendSlice(self.allocator, path) catch return Error.OutOfMemory;
        payload.appendSlice(self.allocator, data) catch return Error.OutOfMemory;
        self.conn.sendFrame(.fs_write, payload.items) catch return Error.NotConnected;

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const rep = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
        return rep.written;
    }
};
