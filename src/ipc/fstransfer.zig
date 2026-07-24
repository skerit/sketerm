//! Client-mediated cross-host file transfer (phase 4 of docs/
//! filebrowser-roadmap.md): the client reads from the SOURCE host's
//! daemon (fs_op read → fs_data) and writes to the DESTINATION host's
//! daemon (fs_write), so two hosts that cannot see each other still
//! transfer through the client. Single files and whole trees.
//!
//! Resume model mirrors fsjob: data lands in `<dst>.skpart` and is
//! renamed into place only when complete, so the staged partial IS
//! the journal. A resumed file continues from the partial's size.
//!
//! Verification is both-ends: the client hashes every byte it
//! forwards (SHA-256) and compares against a daemon-side hash job on
//! the final destination file. A resumed file (where the client never
//! saw the partial's bytes) falls back to hash jobs on BOTH ends.
//! Mismatch = destination deleted + honest failure, never silence.
//!
//! Pure state machine over two caller-owned Conns: the caller pumps
//! both sockets and offers every frame via feed(); no thread, no GTK,
//! no blocking wait lives here (the no-hang invariant is the
//! caller's poll loop).

const std = @import("std");
const client = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const fsserve = @import("../mux/fsserve.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Read/write chunk size. Under fsserve.MAX_READ and comfortably
/// inside one wire frame with the fs_write header.
pub const CHUNK: u32 = 1 << 20;

pub const Side = enum { src, dst };

const Reply = struct {
    req: u32 = 0,
    ok: bool = false,
    @"error": []const u8 = "",
    entries: []fsserve.Entry = &.{},
    more: bool = false,
    truncated: bool = false,
    entry: ?fsserve.Entry = null,
    size: u64 = 0,
    eof: bool = false,
    written: u64 = 0,
    job: u64 = 0,
};

const JobEv = struct {
    job: u64 = 0,
    ev: []const u8 = "",
    hash: []const u8 = "",
    message: []const u8 = "",
};

fn parseReply(arena: std.mem.Allocator, payload: []const u8) ?Reply {
    return std.json.parseFromSliceLeaky(Reply, arena, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// One file moving between hosts. Owned by Xfer (or used standalone).
pub const Transfer = struct {
    allocator: std.mem.Allocator,
    src: *client.Conn,
    dst: *client.Conn,
    /// Shared request-nonce counter (the owner may multiplex other
    /// fs traffic on the same connections).
    next_req: *u32,
    src_path: []u8,
    dst_path: []u8,
    staged: []u8,
    resumable: bool,
    /// Tree-resume semantics: a destination that already exists with
    /// the source's size is skipped without hashing (fsjob parity).
    skip_if_same_size: bool = false,

    state: State = .idle,
    size: u64 = 0,
    off: u64 = 0,
    resumed_from: u64 = 0,
    chunk: std.ArrayList(u8) = .empty,
    req_src: u32 = 0,
    req_dst: u32 = 0,
    hasher: Sha256 = Sha256.init(.{}),
    /// Hash job bookkeeping for the verify phase.
    job_src: u64 = 0,
    job_dst: u64 = 0,
    hash_src: [64]u8 = undefined,
    have_hash_src: bool = false,
    hash_dst: [64]u8 = undefined,
    have_hash_dst: bool = false,
    /// Same-size tree entries are hash-verified before being skipped.
    verifying_skip: bool = false,
    /// A corrupt resumed partial is discarded and copied once from zero.
    verify_retried: bool = false,
    err_buf: [192]u8 = undefined,
    err_len: usize = 0,

    pub const State = enum {
        idle,
        stat_src,
        stat_final,
        stat_staged,
        read,
        write,
        rename,
        hash_start_dst,
        hash_start_src,
        hash_wait,
        cleanup_fail,
        done,
        skipped,
        failed,
        canceled,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        src: *client.Conn,
        dst: *client.Conn,
        next_req: *u32,
        src_path: []const u8,
        dst_path: []const u8,
        resumable: bool,
    ) !*Transfer {
        const self = try allocator.create(Transfer);
        errdefer allocator.destroy(self);
        const sp = try allocator.dupe(u8, src_path);
        errdefer allocator.free(sp);
        const dp = try allocator.dupe(u8, dst_path);
        errdefer allocator.free(dp);
        const st = try std.fmt.allocPrint(allocator, "{s}.skpart", .{dst_path});
        self.* = .{
            .allocator = allocator,
            .src = src,
            .dst = dst,
            .next_req = next_req,
            .src_path = sp,
            .dst_path = dp,
            .staged = st,
            .resumable = resumable,
        };
        return self;
    }

    pub fn deinit(self: *Transfer) void {
        self.chunk.deinit(self.allocator);
        self.allocator.free(self.src_path);
        self.allocator.free(self.dst_path);
        self.allocator.free(self.staged);
        self.allocator.destroy(self);
    }

    pub fn errMsg(self: *const Transfer) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn isTerminal(self: *const Transfer) bool {
        return switch (self.state) {
            .done, .skipped, .failed, .canceled => true,
            else => false,
        };
    }

    pub fn ok(self: *const Transfer) bool {
        return self.state == .done or self.state == .skipped;
    }

    fn nr(self: *Transfer) u32 {
        const r = self.next_req.*;
        self.next_req.* +%= 1;
        if (self.next_req.* == 0) self.next_req.* = 1;
        return r;
    }

    fn fail(self: *Transfer, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
        self.state = .failed;
    }

    fn failFmt(self: *Transfer, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.err_buf, fmt, args) catch fmt;
        self.err_len = msg.len;
        self.state = .failed;
    }

    fn sendSrcOp(self: *Transfer, args: anytype) bool {
        self.src.sendJson(.fs_op, args) catch {
            self.fail("source connection lost");
            return false;
        };
        return true;
    }

    fn sendDstOp(self: *Transfer, args: anytype) bool {
        self.dst.sendJson(.fs_op, args) catch {
            self.fail("destination connection lost");
            return false;
        };
        return true;
    }

    pub fn start(self: *Transfer) void {
        self.req_src = self.nr();
        self.state = .stat_src;
        _ = self.sendSrcOp(.{ .req = self.req_src, .op = "stat", .path = self.src_path });
    }

    /// Best-effort cancel: drops the staged partial only when resume
    /// is off (a resumable partial is worth keeping for later).
    pub fn cancel(self: *Transfer) void {
        if (self.isTerminal()) return;
        if (!self.resumable and (self.state == .read or self.state == .write)) {
            _ = self.sendDstOp(.{ .req = self.nr(), .op = "delete", .path = self.staged });
        }
        self.state = .canceled;
    }

    /// Offer a frame that arrived on `side`'s connection. Returns
    /// true when the frame belonged to this transfer.
    pub fn feed(self: *Transfer, side: Side, ftype: wire.FrameType, payload: []const u8) bool {
        if (self.isTerminal()) return false;
        switch (ftype) {
            .fs_data => {
                if (side != .src or payload.len < 12) return false;
                if (std.mem.readInt(u32, payload[0..4], .little) != self.req_src) return false;
                if (self.state == .read)
                    self.chunk.appendSlice(self.allocator, payload[12..]) catch self.fail("out of memory");
                return true;
            },
            .fs_reply => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const rep = parseReply(arena.allocator(), payload) orelse return false;
                const mine = (side == .src and rep.req == self.req_src and self.req_src != 0) or
                    (side == .dst and rep.req == self.req_dst and self.req_dst != 0);
                if (!mine) return false;
                self.onReply(side, rep);
                return true;
            },
            .fs_job => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const ev = std.json.parseFromSliceLeaky(JobEv, arena.allocator(), payload, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                }) catch return false;
                const mine = (side == .src and ev.job == self.job_src and self.job_src != 0) or
                    (side == .dst and ev.job == self.job_dst and self.job_dst != 0);
                if (!mine) return false;
                self.onJobEvent(side, ev);
                return true;
            },
            else => return false,
        }
    }

    fn onReply(self: *Transfer, side: Side, rep: Reply) void {
        switch (self.state) {
            .stat_src => {
                if (!rep.ok) return self.failFmt("source: {s}", .{rep.@"error"});
                const e = rep.entry orelse return self.fail("source: bad stat reply");
                if (!std.mem.eql(u8, e.kind, "file"))
                    return self.fail("source is not a regular file");
                self.size = e.size;
                if (self.skip_if_same_size) {
                    self.req_dst = self.nr();
                    self.state = .stat_final;
                    _ = self.sendDstOp(.{ .req = self.req_dst, .op = "stat", .path = self.dst_path });
                    return;
                }
                self.afterFinalStat();
            },
            .stat_final => {
                if (rep.ok) {
                    if (rep.entry) |e| {
                        if (std.mem.eql(u8, e.kind, "file") and e.size == self.size) {
                            self.verifying_skip = true;
                            self.req_dst = self.nr();
                            self.state = .hash_start_dst;
                            _ = self.sendDstOp(.{ .req = self.req_dst, .op = "hash", .path = self.dst_path });
                            return;
                        }
                    }
                }
                self.afterFinalStat();
            },
            .stat_staged => {
                if (rep.ok) {
                    if (rep.entry) |e| {
                        if (std.mem.eql(u8, e.kind, "file") and e.size <= self.size) {
                            self.off = e.size;
                            self.resumed_from = e.size;
                        }
                    }
                }
                self.beginData();
            },
            .read => {
                if (side != .src) return;
                if (!rep.ok) return self.failFmt("read: {s}", .{rep.@"error"});
                if (self.chunk.items.len == 0 and self.off < self.size)
                    return self.fail("source shrank during copy");
                self.hasher.update(self.chunk.items);
                self.sendChunk();
            },
            .write => {
                if (side != .dst) return;
                if (!rep.ok) return self.failFmt("write: {s}", .{rep.@"error"});
                self.off += self.chunk.items.len;
                self.chunk.clearRetainingCapacity();
                if (self.off >= self.size) {
                    self.req_dst = self.nr();
                    self.state = .rename;
                    _ = self.sendDstOp(.{
                        .req = self.req_dst,
                        .op = "rename",
                        .path = self.staged,
                        .to = self.dst_path,
                    });
                    return;
                }
                self.requestRead();
            },
            .rename => {
                if (!rep.ok) return self.failFmt("finalize: {s}", .{rep.@"error"});
                self.req_dst = self.nr();
                self.state = .hash_start_dst;
                _ = self.sendDstOp(.{ .req = self.req_dst, .op = "hash", .path = self.dst_path });
            },
            .hash_start_dst => {
                if (!rep.ok or rep.job == 0) return self.failFmt("verify: {s}", .{rep.@"error"});
                self.job_dst = rep.job;
                if (self.resumed_from > 0 or self.verifying_skip) {
                    // The client never saw the partial's bytes — hash
                    // the source daemon-side instead of locally.
                    self.req_src = self.nr();
                    self.state = .hash_start_src;
                    _ = self.sendSrcOp(.{ .req = self.req_src, .op = "hash", .path = self.src_path });
                    return;
                }
                var out: [32]u8 = undefined;
                self.hasher.final(&out);
                const hex = std.fmt.bytesToHex(out, .lower);
                @memcpy(&self.hash_src, &hex);
                self.have_hash_src = true;
                self.state = .hash_wait;
            },
            .hash_start_src => {
                if (!rep.ok or rep.job == 0) return self.failFmt("verify: {s}", .{rep.@"error"});
                self.job_src = rep.job;
                self.state = .hash_wait;
            },
            .cleanup_fail => {
                if (self.resumed_from > 0 and !self.verify_retried) {
                    self.verify_retried = true;
                    self.resumed_from = 0;
                    self.off = 0;
                    self.job_src = 0;
                    self.job_dst = 0;
                    self.have_hash_src = false;
                    self.have_hash_dst = false;
                    self.hasher = Sha256.init(.{});
                    self.beginData();
                } else {
                    self.fail("verify failed: content hash mismatch");
                }
            },
            else => {},
        }
    }

    fn onJobEvent(self: *Transfer, side: Side, ev: JobEv) void {
        if (std.mem.eql(u8, ev.ev, "progress")) return;
        const done_ok = std.mem.eql(u8, ev.ev, "done") and ev.hash.len == 64;
        if (!done_ok) {
            if (std.mem.eql(u8, ev.ev, "done")) return; // ignore stray
            return self.failFmt("verify job failed: {s}", .{ev.message});
        }
        switch (side) {
            .src => {
                @memcpy(&self.hash_src, ev.hash[0..64]);
                self.have_hash_src = true;
            },
            .dst => {
                @memcpy(&self.hash_dst, ev.hash[0..64]);
                self.have_hash_dst = true;
            },
        }
        if (self.state != .hash_wait or !self.have_hash_src or !self.have_hash_dst) return;
        if (std.mem.eql(u8, &self.hash_src, &self.hash_dst)) {
            self.state = if (self.verifying_skip) .skipped else .done;
            if (self.verifying_skip) self.off = self.size;
            return;
        }
        if (self.verifying_skip) {
            self.verifying_skip = false;
            self.job_src = 0;
            self.job_dst = 0;
            self.have_hash_src = false;
            self.have_hash_dst = false;
            self.afterFinalStat();
            return;
        }
        // Never leave a corrupt file wearing the final name.
        self.req_dst = self.nr();
        self.state = .cleanup_fail;
        _ = self.sendDstOp(.{ .req = self.req_dst, .op = "delete", .path = self.dst_path });
    }

    fn afterFinalStat(self: *Transfer) void {
        if (self.resumable) {
            self.req_dst = self.nr();
            self.state = .stat_staged;
            _ = self.sendDstOp(.{ .req = self.req_dst, .op = "stat", .path = self.staged });
            return;
        }
        self.beginData();
    }

    fn beginData(self: *Transfer) void {
        if (self.off >= self.size) {
            // Empty file, or a staged partial that already holds every
            // byte: (re)create/complete the staged file, then rename.
            self.req_dst = self.nr();
            self.state = .write;
            self.chunk.clearRetainingCapacity();
            self.sendWriteFrame(&.{}) catch return self.fail("destination connection lost");
            return;
        }
        self.requestRead();
    }

    fn requestRead(self: *Transfer) void {
        self.req_src = self.nr();
        self.state = .read;
        const want: u32 = @intCast(@min(@as(u64, CHUNK), self.size - self.off));
        _ = self.sendSrcOp(.{
            .req = self.req_src,
            .op = "read",
            .path = self.src_path,
            .off = self.off,
            .len = want,
        });
    }

    fn sendChunk(self: *Transfer) void {
        self.req_dst = self.nr();
        self.state = .write;
        self.sendWriteFrame(self.chunk.items) catch return self.fail("destination connection lost");
    }

    fn sendWriteFrame(self: *Transfer, data: []const u8) !void {
        if (self.staged.len > std.math.maxInt(u16)) return error.PathTooLong;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var hdr: [15]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], self.req_dst, .little);
        std.mem.writeInt(u64, hdr[4..12], self.off, .little);
        // create always; truncate only on a from-scratch first chunk
        // (a resumed partial must keep its bytes).
        hdr[12] = if (self.off == 0 and self.resumed_from == 0) 0b011 else 0b001;
        std.mem.writeInt(u16, hdr[13..15], @intCast(self.staged.len), .little);
        try payload.appendSlice(self.allocator, &hdr);
        try payload.appendSlice(self.allocator, self.staged);
        try payload.appendSlice(self.allocator, data);
        try self.dst.sendFrame(.fs_write, payload.items);
    }
};

/// A whole (host,path) → (host,path) operation: one file OR a tree.
/// Walks the source (rich listings), recreates directories and
/// symlinks, then streams files one at a time through Transfer.
pub const Xfer = struct {
    allocator: std.mem.Allocator,
    src: *client.Conn,
    dst: *client.Conn,
    next_req: *u32,
    src_root: []u8,
    dst_root: []u8,
    resumable: bool,

    state: State = .idle,
    /// Relative dir paths ("" = root) still to list during the walk.
    walk_queue: std.ArrayList([]u8) = .empty,
    /// All discovered relative dir paths, walk order (parents first).
    dirs: std.ArrayList([]u8) = .empty,
    files: std.ArrayList(Item) = .empty,
    links: std.ArrayList(Link) = .empty,
    list_req: u32 = 0,
    /// Dir currently being listed (owned; freed when its run ends).
    listing_rel: ?[]u8 = null,
    setup_req: u32 = 0,
    setup_idx: usize = 0,
    cur: ?*Transfer = null,
    cur_idx: usize = 0,
    total_bytes: u64 = 0,
    done_bytes: u64 = 0,
    files_done: usize = 0,
    /// Bytes NOT re-sent thanks to staged partials (proof of resume).
    resumed_bytes: u64 = 0,
    /// Files skipped whole (destination already complete).
    files_skipped: usize = 0,
    single_file: bool = false,
    err_buf: [192]u8 = undefined,
    err_len: usize = 0,

    const Item = struct { rel: []u8, size: u64 };
    const Link = struct { rel: []u8, target: []u8 };

    pub const State = enum { idle, stat_root, walking, mkdirs, symlinks, copying, done, failed, canceled };

    pub fn init(
        allocator: std.mem.Allocator,
        src: *client.Conn,
        dst: *client.Conn,
        next_req: *u32,
        src_root: []const u8,
        dst_root: []const u8,
        resumable: bool,
    ) !*Xfer {
        const self = try allocator.create(Xfer);
        errdefer allocator.destroy(self);
        const sr = try allocator.dupe(u8, src_root);
        errdefer allocator.free(sr);
        const dr = try allocator.dupe(u8, dst_root);
        self.* = .{
            .allocator = allocator,
            .src = src,
            .dst = dst,
            .next_req = next_req,
            .src_root = sr,
            .dst_root = dr,
            .resumable = resumable,
        };
        return self;
    }

    pub fn deinit(self: *Xfer) void {
        const a = self.allocator;
        for (self.walk_queue.items) |p| a.free(p);
        self.walk_queue.deinit(a);
        for (self.dirs.items) |p| a.free(p);
        self.dirs.deinit(a);
        for (self.files.items) |f| a.free(f.rel);
        self.files.deinit(a);
        for (self.links.items) |l| {
            a.free(l.rel);
            a.free(l.target);
        }
        self.links.deinit(a);
        if (self.listing_rel) |p| a.free(p);
        if (self.cur) |t| t.deinit();
        a.free(self.src_root);
        a.free(self.dst_root);
        a.destroy(self);
    }

    pub fn errMsg(self: *const Xfer) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn isTerminal(self: *const Xfer) bool {
        return switch (self.state) {
            .done, .failed, .canceled => true,
            else => false,
        };
    }

    pub fn ok(self: *const Xfer) bool {
        return self.state == .done;
    }

    /// Bytes transferred (completed files + current file position)
    /// over total. Total is 0 until the walk finishes.
    pub fn progress(self: *const Xfer) struct { done: u64, total: u64 } {
        var d = self.done_bytes;
        if (self.cur) |t| d += t.off;
        return .{ .done = d, .total = self.total_bytes };
    }

    fn nr(self: *Xfer) u32 {
        const r = self.next_req.*;
        self.next_req.* +%= 1;
        if (self.next_req.* == 0) self.next_req.* = 1;
        return r;
    }

    fn fail(self: *Xfer, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
        self.state = .failed;
    }

    fn failFmt(self: *Xfer, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.err_buf, fmt, args) catch fmt;
        self.err_len = msg.len;
        self.state = .failed;
    }

    pub fn start(self: *Xfer) void {
        self.list_req = self.nr();
        self.state = .stat_root;
        self.src.sendJson(.fs_op, .{ .req = self.list_req, .op = "stat", .path = self.src_root }) catch
            self.fail("source connection lost");
    }

    pub fn cancel(self: *Xfer) void {
        if (self.isTerminal()) return;
        if (self.cur) |t| t.cancel();
        self.state = .canceled;
    }

    fn srcAbs(self: *Xfer, buf: []u8, rel: []const u8) ?[]const u8 {
        if (rel.len == 0) return self.src_root;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.src_root, rel }) catch null;
    }

    fn dstAbs(self: *Xfer, buf: []u8, rel: []const u8) ?[]const u8 {
        if (rel.len == 0) return self.dst_root;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.dst_root, rel }) catch null;
    }

    pub fn feed(self: *Xfer, side: Side, ftype: wire.FrameType, payload: []const u8) bool {
        if (self.isTerminal()) return false;
        if (self.cur) |t| {
            if (t.feed(side, ftype, payload)) {
                self.afterCurFeed();
                return true;
            }
        }
        if (ftype != .fs_reply) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const rep = parseReply(arena.allocator(), payload) orelse return false;
        const mine = (side == .src and self.list_req != 0 and rep.req == self.list_req) or
            (side == .dst and self.setup_req != 0 and rep.req == self.setup_req);
        if (!mine) return false;
        self.onReply(side, rep);
        return true;
    }

    fn onReply(self: *Xfer, side: Side, rep: Reply) void {
        _ = side;
        switch (self.state) {
            .stat_root => {
                if (!rep.ok) return self.failFmt("source: {s}", .{rep.@"error"});
                const e = rep.entry orelse return self.fail("source: bad stat reply");
                if (std.mem.eql(u8, e.kind, "file")) {
                    self.single_file = true;
                    self.total_bytes = e.size;
                    self.files.append(self.allocator, .{
                        .rel = self.allocator.dupe(u8, "") catch return self.fail("out of memory"),
                        .size = e.size,
                    }) catch return self.fail("out of memory");
                    self.state = .copying;
                    self.startNextFile();
                    return;
                }
                if (!e.tdir) return self.fail("source is neither file nor directory");
                self.enqueueDir("") catch return self.fail("out of memory");
                self.state = .walking;
                self.listNext();
            },
            .walking => {
                if (!rep.ok) return self.failFmt("list: {s}", .{rep.@"error"});
                if (rep.truncated) return self.fail("directory too large (listing truncated)");
                const rel = self.listing_rel orelse return self.fail("walk state lost");
                for (rep.entries) |e| {
                    var relbuf: [4096]u8 = undefined;
                    const crel = if (rel.len == 0)
                        e.name
                    else
                        std.fmt.bufPrint(&relbuf, "{s}/{s}", .{ rel, e.name }) catch continue;
                    if (std.mem.eql(u8, e.kind, "dir")) {
                        self.enqueueDir(crel) catch return self.fail("out of memory");
                    } else if (std.mem.eql(u8, e.kind, "file")) {
                        const owned = self.allocator.dupe(u8, crel) catch return self.fail("out of memory");
                        self.files.append(self.allocator, .{ .rel = owned, .size = e.size }) catch {
                            self.allocator.free(owned);
                            return self.fail("out of memory");
                        };
                        self.total_bytes += e.size;
                    } else if (std.mem.eql(u8, e.kind, "link")) {
                        const t = e.target orelse continue;
                        const orel = self.allocator.dupe(u8, crel) catch return self.fail("out of memory");
                        const otgt = self.allocator.dupe(u8, t) catch {
                            self.allocator.free(orel);
                            return self.fail("out of memory");
                        };
                        self.links.append(self.allocator, .{ .rel = orel, .target = otgt }) catch
                            return self.fail("out of memory");
                    }
                    // "other" (sockets, fifos, devices) deliberately skipped.
                }
                if (rep.more) return; // chunk run continues
                self.allocator.free(rel);
                self.listing_rel = null;
                self.listNext();
            },
            .mkdirs, .symlinks => {
                if (!rep.ok and std.mem.indexOf(u8, rep.@"error", "EXIST") == null)
                    return self.failFmt("destination setup: {s}", .{rep.@"error"});
                self.setup_idx += 1;
                self.setupNext();
            },
            else => {},
        }
    }

    fn enqueueDir(self: *Xfer, rel: []const u8) !void {
        const q = try self.allocator.dupe(u8, rel);
        errdefer self.allocator.free(q);
        try self.walk_queue.append(self.allocator, q);
        const d = try self.allocator.dupe(u8, rel);
        errdefer self.allocator.free(d);
        try self.dirs.append(self.allocator, d);
    }

    fn listNext(self: *Xfer) void {
        if (self.walk_queue.items.len == 0) {
            self.state = .mkdirs;
            self.setup_idx = 0;
            self.setupNext();
            return;
        }
        const rel = self.walk_queue.orderedRemove(0);
        self.listing_rel = rel;
        var buf: [4096]u8 = undefined;
        const abs = self.srcAbs(&buf, rel) orelse return self.fail("path too long");
        self.list_req = self.nr();
        self.src.sendJson(.fs_op, .{ .req = self.list_req, .op = "list", .path = abs }) catch
            self.fail("source connection lost");
    }

    fn setupNext(self: *Xfer) void {
        switch (self.state) {
            .mkdirs => {
                if (self.setup_idx >= self.dirs.items.len) {
                    self.state = .symlinks;
                    self.setup_idx = 0;
                    return self.setupNext();
                }
                var buf: [4096]u8 = undefined;
                const abs = self.dstAbs(&buf, self.dirs.items[self.setup_idx]) orelse
                    return self.fail("path too long");
                self.setup_req = self.nr();
                self.dst.sendJson(.fs_op, .{ .req = self.setup_req, .op = "mkdir", .path = abs }) catch
                    self.fail("destination connection lost");
            },
            .symlinks => {
                if (self.setup_idx >= self.links.items.len) {
                    self.state = .copying;
                    self.cur_idx = 0;
                    return self.startNextFile();
                }
                const l = self.links.items[self.setup_idx];
                var buf: [4096]u8 = undefined;
                const abs = self.dstAbs(&buf, l.rel) orelse return self.fail("path too long");
                self.setup_req = self.nr();
                self.dst.sendJson(.fs_op, .{
                    .req = self.setup_req,
                    .op = "symlink",
                    .path = abs,
                    .to = l.target,
                }) catch self.fail("destination connection lost");
            },
            else => {},
        }
    }

    fn startNextFile(self: *Xfer) void {
        if (self.cur) |t| {
            t.deinit();
            self.cur = null;
        }
        if (self.cur_idx >= self.files.items.len) {
            self.state = .done;
            return;
        }
        const f = self.files.items[self.cur_idx];
        var sbuf: [4096]u8 = undefined;
        var dbuf: [4096]u8 = undefined;
        const sabs = self.srcAbs(&sbuf, f.rel) orelse return self.fail("path too long");
        const dabs = self.dstAbs(&dbuf, f.rel) orelse return self.fail("path too long");
        const t = Transfer.init(self.allocator, self.src, self.dst, self.next_req, sabs, dabs, self.resumable) catch
            return self.fail("out of memory");
        // Tree resume: completed files (final name, same size) skip.
        t.skip_if_same_size = self.resumable and !self.single_file;
        self.cur = t;
        t.start();
        self.afterCurFeed();
    }

    fn afterCurFeed(self: *Xfer) void {
        const t = self.cur orelse return;
        if (!t.isTerminal()) return;
        if (!t.ok()) {
            if (t.state == .canceled) {
                self.state = .canceled;
                return;
            }
            var buf: [256]u8 = undefined;
            const base = std.fs.path.basename(t.src_path);
            const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ base, t.errMsg() }) catch t.errMsg();
            return self.fail(msg);
        }
        self.done_bytes += self.files.items[self.cur_idx].size;
        self.files_done += 1;
        self.resumed_bytes += t.resumed_from;
        if (t.state == .skipped) self.files_skipped += 1;
        self.cur_idx += 1;
        self.startNextFile();
    }
};
