//! `sketerm mount <host>[:/path] <mountpoint>` — pure-Zig FUSE
//! client (phase 6 of docs/filebrowser-roadmap.md): local apps open
//! remote files through the kernel, backed by the mux file service.
//! No libfuse: the /dev/fuse fd comes from the fusermount3 setuid
//! helper (SCM_RIGHTS over a socketpair — the unprivileged path),
//! and the kernel protocol is spoken directly via <linux/fuse.h>.
//!
//! Shape: single-threaded request loop (the kio-fuse structural
//! mold); every operation is one bounded fsdrive round trip, so a
//! wedged daemon costs a described EIO, never a hung kernel thread
//! held forever (fsdrive's 10s op deadline applies). Reads are
//! RANGED — streaming the head of a huge video never downloads the
//! tail. Writes go straight through (fs_write at explicit offsets).
//!
//! Known limitation (wire has no ftruncate): SETATTR size is honored
//! for 0 (O_TRUNC) and the current size (no-op); anything else is
//! EOPNOTSUPP.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const muxclient = @import("mux/client.zig");
const fsdrive = @import("ipc/fsdrive.zig");
const platform = @import("util/platform.zig");

const is_linux = builtin.os.tag == .linux;

var g_stop: bool = false;

fn onSignal(_: @TypeOf(std.posix.SIG.INT)) callconv(.c) void {
    g_stop = true;
}

/// Errno (positive) from an fsdrive error + lastErr text.
fn errnoOf(err: fsdrive.Error, last: []const u8) i32 {
    switch (err) {
        error.Timeout, error.NotConnected => return c.EIO,
        error.OutOfMemory => return c.ENOMEM,
        error.BadReply => return c.EIO,
        error.FsOpFailed => {},
    }
    const map = .{
        .{ "NOENT", c.ENOENT },     .{ "ACCES", c.EACCES },
        .{ "EXIST", c.EEXIST },     .{ "NOTEMPTY", c.ENOTEMPTY },
        .{ "NOTDIR", c.ENOTDIR },   .{ "ISDIR", c.EISDIR },
        .{ "INVAL", c.EINVAL },     .{ "PERM", c.EPERM },
        .{ "NOSPC", c.ENOSPC },     .{ "XDEV", c.EXDEV },
        .{ "ROFS", c.EROFS },       .{ "NAMETOOLONG", c.ENAMETOOLONG },
    };
    inline for (map) |m| {
        if (std.mem.indexOf(u8, last, m[0]) != null) return m[1];
    }
    return c.EIO;
}

const Node = struct {
    path: []u8,
    nlookup: u64,
};

const DirH = struct {
    listing: fsdrive.Listing,
};

pub const Mount = struct {
    allocator: std.mem.Allocator,
    fs: *fsdrive.Fs,
    fuse_fd: c_int,
    /// Remote root this mount exposes ("/" or a prefix, no trailing
    /// slash unless root itself).
    root: []u8,
    nodes: std.ArrayList(?Node) = .empty,
    free_ids: std.ArrayList(usize) = .empty,
    by_path: std.StringHashMap(u64),
    dirs: std.AutoHashMap(u64, *DirH),
    next_fh: u64 = 1,
    uid: u32,
    gid: u32,

    fn init(allocator: std.mem.Allocator, fs: *fsdrive.Fs, root: []const u8, fuse_fd: c_int) !*Mount {
        const self = try allocator.create(Mount);
        self.* = .{
            .allocator = allocator,
            .fs = fs,
            .fuse_fd = fuse_fd,
            .root = try allocator.dupe(u8, root),
            .by_path = std.StringHashMap(u64).init(allocator),
            .dirs = std.AutoHashMap(u64, *DirH).init(allocator),
            .uid = @intCast(c.getuid()),
            .gid = @intCast(c.getgid()),
        };
        // nodeid 1 = the root.
        try self.nodes.append(allocator, .{ .path = try allocator.dupe(u8, root), .nlookup = 1 });
        return self;
    }

    fn deinit(self: *Mount) void {
        for (self.nodes.items) |n| {
            if (n) |node| self.allocator.free(node.path);
        }
        self.nodes.deinit(self.allocator);
        self.free_ids.deinit(self.allocator);
        self.by_path.deinit();
        var it = self.dirs.valueIterator();
        while (it.next()) |dh| {
            dh.*.listing.deinit();
            self.allocator.destroy(dh.*);
        }
        self.dirs.deinit();
        self.allocator.free(self.root);
        self.allocator.destroy(self);
    }

    fn pathOf(self: *Mount, nodeid: u64) ?[]const u8 {
        if (nodeid == 0 or nodeid > self.nodes.items.len) return null;
        const n = self.nodes.items[@intCast(nodeid - 1)] orelse return null;
        return n.path;
    }

    /// nodeid for `path`, creating (nlookup 0) when new. The caller
    /// bumps nlookup for LOOKUP/CREATE-style replies.
    fn ensureNode(self: *Mount, path: []const u8) !u64 {
        if (self.by_path.get(path)) |id| return id;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        var id: u64 = undefined;
        if (self.free_ids.pop()) |slot| {
            self.nodes.items[slot] = .{ .path = owned, .nlookup = 0 };
            id = slot + 1;
        } else {
            try self.nodes.append(self.allocator, .{ .path = owned, .nlookup = 0 });
            id = self.nodes.items.len;
        }
        try self.by_path.put(owned, id);
        return id;
    }

    fn forget(self: *Mount, nodeid: u64, n: u64) void {
        if (nodeid <= 1 or nodeid > self.nodes.items.len) return;
        const slot: usize = @intCast(nodeid - 1);
        const node = &(self.nodes.items[slot] orelse return);
        node.nlookup -|= n;
        if (node.nlookup == 0) {
            _ = self.by_path.remove(node.path);
            self.allocator.free(node.path);
            self.nodes.items[slot] = null;
            self.free_ids.append(self.allocator, slot) catch {};
        }
    }

    /// Rewrite node paths after a rename (dir renames carry their
    /// subtree along).
    fn renamePaths(self: *Mount, old: []const u8, new: []const u8) void {
        for (self.nodes.items, 0..) |*maybe, i| {
            const node = &(maybe.* orelse continue);
            const p = node.path;
            const hit = std.mem.startsWith(u8, p, old) and
                (p.len == old.len or p[old.len] == '/');
            if (!hit) continue;
            var buf: [4096]u8 = undefined;
            const np = std.fmt.bufPrint(&buf, "{s}{s}", .{ new, p[old.len..] }) catch continue;
            const owned = self.allocator.dupe(u8, np) catch continue;
            _ = self.by_path.remove(p);
            self.allocator.free(p);
            node.path = owned;
            self.by_path.put(owned, i + 1) catch {};
        }
    }

    fn joinChild(buf: []u8, parent: []const u8, name: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{
            if (parent.len == 1 and parent[0] == '/') "" else parent, name,
        }) catch null;
    }

    /// LOOKUP-style reply for `full` (stat + node + entry_out).
    fn replyEntry(m: *Mount, unique: u64, full: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(m.allocator);
        defer arena.deinit();
        const e = m.fs.statPath(arena.allocator(), full) catch |err| {
            return replyErr(m.fuse_fd, unique, errnoOf(err, m.fs.lastErr()));
        };
        const id = m.ensureNode(full) catch return replyErr(m.fuse_fd, unique, c.ENOMEM);
        m.nodes.items[@intCast(id - 1)].?.nlookup += 1;
        var out = std.mem.zeroes(c.struct_fuse_entry_out);
        out.nodeid = id;
        out.entry_valid = 1;
        out.attr_valid = 1;
        m.fillAttr(id, e, &out.attr);
        replyStruct(m.fuse_fd, unique, out);
    }

    fn fillAttr(self: *Mount, nodeid: u64, e: fsdrive.Entry, out: *c.struct_fuse_attr) void {
        out.* = std.mem.zeroes(c.struct_fuse_attr);
        out.ino = nodeid;
        out.size = e.size;
        out.blocks = (e.size + 511) / 512;
        const sec: u64 = @intCast(@divTrunc(@max(e.mtime_ms, 0), 1000));
        const nsec: u32 = @intCast(@mod(@max(e.mtime_ms, 0), 1000) * 1_000_000);
        out.atime = sec;
        out.mtime = sec;
        out.ctime = sec;
        out.atimensec = nsec;
        out.mtimensec = nsec;
        out.ctimensec = nsec;
        const ifmt: u32 = if (std.mem.eql(u8, e.kind, "dir"))
            c.S_IFDIR
        else if (std.mem.eql(u8, e.kind, "link"))
            c.S_IFLNK
        else
            c.S_IFREG;
        out.mode = ifmt | e.mode;
        out.nlink = 1;
        out.uid = self.uid;
        out.gid = self.gid;
        out.blksize = 4096;
    }
};

// ── reply plumbing ──────────────────────────────────────────────

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn replyErr(fd: c_int, unique: u64, errno_pos: i32) void {
    var hdr = std.mem.zeroes(c.struct_fuse_out_header);
    hdr.len = @sizeOf(c.struct_fuse_out_header);
    hdr.@"error" = -errno_pos;
    hdr.unique = unique;
    writeAll(fd, std.mem.asBytes(&hdr));
}

fn replyBytes(fd: c_int, unique: u64, payload: []const u8) void {
    var buf: [8192]u8 align(8) = undefined;
    const total = @sizeOf(c.struct_fuse_out_header) + payload.len;
    if (total <= buf.len) {
        var hdr: *c.struct_fuse_out_header = @ptrCast(&buf);
        hdr.* = std.mem.zeroes(c.struct_fuse_out_header);
        hdr.len = @intCast(total);
        hdr.unique = unique;
        @memcpy(buf[@sizeOf(c.struct_fuse_out_header)..][0..payload.len], payload);
        writeAll(fd, buf[0..total]);
        return;
    }
    // Large read replies: header + payload in one writev.
    var hdr = std.mem.zeroes(c.struct_fuse_out_header);
    hdr.len = @intCast(total);
    hdr.unique = unique;
    var iov = [_]c.struct_iovec{
        .{ .iov_base = @ptrCast(&hdr), .iov_len = @sizeOf(c.struct_fuse_out_header) },
        .{ .iov_base = @constCast(@ptrCast(payload.ptr)), .iov_len = payload.len },
    };
    while (true) {
        const n = c.writev(fd, &iov, 2);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        break;
    }
}

fn replyStruct(fd: c_int, unique: u64, value: anytype) void {
    replyBytes(fd, unique, std.mem.asBytes(&value));
}

// ── fusermount3 handshake ───────────────────────────────────────

/// Obtain a mounted /dev/fuse fd via the setuid fusermount3 helper
/// (SCM_RIGHTS over a socketpair; the documented unprivileged path).
pub fn openFuseFd(mountpoint: [*:0]const u8) !c_int {
    var sp: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sp) != 0) return error.SocketFailed;

    var opts_buf: [256:0]u8 = undefined;
    const opts = std.fmt.bufPrintZ(&opts_buf, "rootmode=40755,user_id={d},group_id={d},default_permissions,fsname=sketerm,subtype=sketerm", .{
        c.getuid(), c.getgid(),
    }) catch return error.SocketFailed;
    var commfd_buf: [32:0]u8 = undefined;
    const commfd = std.fmt.bufPrintZ(&commfd_buf, "{d}", .{sp[1]}) catch return error.SocketFailed;

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(sp[0]);
        _ = c.close(sp[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = c.close(sp[0]);
        _ = c.setenv("_FUSE_COMMFD", commfd.ptr, 1);
        const argv = [_:null]?[*:0]const u8{ "fusermount3", "-o", opts.ptr, "--", mountpoint, null };
        _ = c.execvp("fusermount3", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(sp[1]);
    defer _ = c.close(sp[0]);

    // Receive the fd (one data byte + SCM_RIGHTS cmsg).
    var data: [8]u8 = undefined;
    var iov = c.struct_iovec{ .iov_base = &data, .iov_len = data.len };
    var cmsg_buf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
    var msg = std.mem.zeroes(c.struct_msghdr);
    msg.msg_iov = @ptrCast(&iov);
    msg.msg_iovlen = 1;
    msg.msg_control = &cmsg_buf;
    msg.msg_controllen = cmsg_buf.len;
    var fd: c_int = -1;
    while (true) {
        const n = c.recvmsg(sp[0], &msg, 0);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        const cm: *c.struct_cmsghdr = @ptrCast(&cmsg_buf);
        if (cm.cmsg_level == c.SOL_SOCKET and cm.cmsg_type == c.SCM_RIGHTS and
            cm.cmsg_len >= @sizeOf(c.struct_cmsghdr) + @sizeOf(c_int))
        {
            const fd_bytes = cmsg_buf[@sizeOf(c.struct_cmsghdr)..][0..@sizeOf(c_int)];
            fd = std.mem.bytesToValue(c_int, fd_bytes);
        }
        break;
    }
    var st: c_int = 0;
    _ = c.waitpid(pid, &st, 0);
    if (fd < 0) return error.FusermountFailed;
    return fd;
}

pub fn unmount(mountpoint: [*:0]const u8) void {
    const pid = c.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "fusermount3", "-u", "-z", "--", mountpoint, null };
        _ = c.execvp("fusermount3", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    if (pid > 0) {
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
    }
}

// ── request loop ────────────────────────────────────────────────

const MAX_WRITE: u32 = 128 * 1024;

/// Serve FUSE requests until unmount (ENODEV) or a signal. `fs` and
/// the fuse fd are caller-owned; `root` is the remote path prefix.
pub fn serve(allocator: std.mem.Allocator, fs: *fsdrive.Fs, root: []const u8, fuse_fd: c_int) !void {
    if (comptime !is_linux) return error.Unsupported;
    const m = try Mount.init(allocator, fs, root, fuse_fd);
    defer m.deinit();

    const buf = try allocator.alignedAlloc(u8, std.mem.Alignment.of(u64), MAX_WRITE + 64 * 1024);
    defer allocator.free(buf);

    while (!g_stop) {
        const n = c.read(fuse_fd, buf.ptr, buf.len);
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e == .NODEV) return; // unmounted
            if (e == .AGAIN) continue;
            return;
        }
        if (n == 0) return;
        dispatch(m, buf[0..@intCast(n)]);
    }
}

fn dispatch(m: *Mount, req: []align(8) u8) void {
    if (req.len < @sizeOf(c.struct_fuse_in_header)) return;
    const hdr: *const c.struct_fuse_in_header = @ptrCast(req.ptr);
    const body = req[@sizeOf(c.struct_fuse_in_header)..];
    const fd = m.fuse_fd;
    const u = hdr.unique;

    switch (hdr.opcode) {
        c.FUSE_INIT => {
            const in: *const c.struct_fuse_init_in = @ptrCast(@alignCast(body.ptr));
            var out = std.mem.zeroes(c.struct_fuse_init_out);
            out.major = c.FUSE_KERNEL_VERSION;
            out.minor = @min(in.minor, 36);
            out.max_readahead = in.max_readahead;
            // FUSE_BIG_WRITES: without it every write is one page.
            out.flags = in.flags & @as(u32, @intCast(c.FUSE_BIG_WRITES));
            out.max_background = 16;
            out.congestion_threshold = 12;
            out.max_write = MAX_WRITE;
            out.time_gran = 1;
            replyStruct(fd, u, out);
        },
        c.FUSE_GETATTR => {
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            var arena = std.heap.ArenaAllocator.init(m.allocator);
            defer arena.deinit();
            const e = m.fs.statPath(arena.allocator(), path) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            var out = std.mem.zeroes(c.struct_fuse_attr_out);
            out.attr_valid = 1;
            m.fillAttr(hdr.nodeid, e, &out.attr);
            replyStruct(fd, u, out);
        },
        c.FUSE_LOOKUP => {
            const parent = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const name = std.mem.sliceTo(body, 0);
            var pbuf: [4096]u8 = undefined;
            const full = Mount.joinChild(&pbuf, parent, name) orelse return replyErr(fd, u, c.ENAMETOOLONG);
            m.replyEntry(u, full);
        },
        c.FUSE_FORGET => {
            const in: *const c.struct_fuse_forget_in = @ptrCast(@alignCast(body.ptr));
            m.forget(hdr.nodeid, in.nlookup);
            // No reply, by protocol.
        },
        c.FUSE_BATCH_FORGET => {
            const in: *const c.struct_fuse_batch_forget_in = @ptrCast(@alignCast(body.ptr));
            const ones: [*]const c.struct_fuse_forget_one = @ptrCast(@alignCast(body.ptr + @sizeOf(c.struct_fuse_batch_forget_in)));
            var i: usize = 0;
            while (i < in.count) : (i += 1) m.forget(ones[i].nodeid, ones[i].nlookup);
        },
        c.FUSE_OPENDIR => {
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const listing = m.fs.list(path) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            const dh = m.allocator.create(DirH) catch return replyErr(fd, u, c.ENOMEM);
            dh.* = .{ .listing = listing };
            const fh = m.next_fh;
            m.next_fh += 1;
            m.dirs.put(fh, dh) catch {
                dh.listing.deinit();
                m.allocator.destroy(dh);
                return replyErr(fd, u, c.ENOMEM);
            };
            var out = std.mem.zeroes(c.struct_fuse_open_out);
            out.fh = fh;
            replyStruct(fd, u, out);
        },
        c.FUSE_READDIR => {
            const in: *const c.struct_fuse_read_in = @ptrCast(@alignCast(body.ptr));
            const dh = m.dirs.get(in.fh) orelse return replyErr(fd, u, c.EBADF);
            var out_buf: [64 * 1024]u8 align(8) = undefined;
            var w: usize = 0;
            var idx: u64 = in.offset;
            const total: u64 = dh.listing.entries.len + 2; // ".", ".."
            while (idx < total) : (idx += 1) {
                var name: []const u8 = undefined;
                var mode_type: u32 = c.S_IFDIR >> 12;
                var ino: u64 = hdr.nodeid;
                if (idx == 0) {
                    name = ".";
                } else if (idx == 1) {
                    name = "..";
                    ino = 1;
                } else {
                    const e = dh.listing.entries[@intCast(idx - 2)];
                    name = e.name;
                    mode_type = if (std.mem.eql(u8, e.kind, "dir"))
                        c.S_IFDIR >> 12
                    else if (std.mem.eql(u8, e.kind, "link"))
                        c.S_IFLNK >> 12
                    else
                        c.S_IFREG >> 12;
                    ino = idx; // stable-enough synthetic ino for listings
                }
                const rec = @sizeOf(c.struct_fuse_dirent) + name.len;
                const padded = (rec + 7) & ~@as(usize, 7);
                if (w + padded > @min(out_buf.len, in.size)) break;
                const de: *c.struct_fuse_dirent = @ptrCast(@alignCast(out_buf[w..].ptr));
                de.ino = ino;
                de.off = idx + 1;
                de.namelen = @intCast(name.len);
                de.@"type" = mode_type;
                @memcpy(out_buf[w + @sizeOf(c.struct_fuse_dirent) ..][0..name.len], name);
                @memset(out_buf[w + rec .. w + padded], 0);
                w += padded;
            }
            replyBytes(fd, u, out_buf[0..w]);
        },
        c.FUSE_RELEASEDIR => {
            const in: *const c.struct_fuse_release_in = @ptrCast(@alignCast(body.ptr));
            if (m.dirs.fetchRemove(in.fh)) |kv| {
                kv.value.listing.deinit();
                m.allocator.destroy(kv.value);
            }
            replyBytes(fd, u, "");
        },
        c.FUSE_OPEN => {
            const in: *const c.struct_fuse_open_in = @ptrCast(@alignCast(body.ptr));
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            if (in.flags & @as(u32, @intCast(c.O_TRUNC)) != 0) {
                _ = m.fs.write(path, 0, &.{}, .{ .create = true, .truncate = true }) catch |err|
                    return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            }
            var out = std.mem.zeroes(c.struct_fuse_open_out);
            out.fh = m.next_fh;
            m.next_fh += 1;
            replyStruct(fd, u, out);
        },
        c.FUSE_READ => {
            const in: *const c.struct_fuse_read_in = @ptrCast(@alignCast(body.ptr));
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(m.allocator);
            var got: usize = 0;
            // One kernel read may exceed a single fs round trip's cap.
            while (got < in.size) {
                const want: u32 = @intCast(@min(in.size - got, fsdrive.fsserve.MAX_READ));
                const info = m.fs.read(path, in.offset + got, want, &out) catch |err|
                    return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
                if (out.items.len == got) break; // EOF
                got = out.items.len;
                if (info.eof) break;
            }
            replyBytes(fd, u, out.items);
        },
        c.FUSE_WRITE => {
            const in: *const c.struct_fuse_write_in = @ptrCast(@alignCast(body.ptr));
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const data = body[@sizeOf(c.struct_fuse_write_in)..][0..in.size];
            const written = m.fs.write(path, in.offset, data, .{ .create = true }) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            var out = std.mem.zeroes(c.struct_fuse_write_out);
            out.size = @intCast(written);
            replyStruct(fd, u, out);
        },
        c.FUSE_FLUSH, c.FUSE_RELEASE, c.FUSE_FSYNC, c.FUSE_ACCESS => replyBytes(fd, u, ""),
        c.FUSE_SETATTR => {
            const in: *const c.struct_fuse_setattr_in = @ptrCast(@alignCast(body.ptr));
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            if (in.valid & c.FATTR_SIZE != 0) {
                if (in.size == 0) {
                    _ = m.fs.write(path, 0, &.{}, .{ .create = true, .truncate = true }) catch |err|
                        return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
                } else {
                    var arena0 = std.heap.ArenaAllocator.init(m.allocator);
                    defer arena0.deinit();
                    const cur = m.fs.statPath(arena0.allocator(), path) catch |err|
                        return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
                    if (cur.size != in.size) return replyErr(fd, u, c.EOPNOTSUPP);
                }
            }
            // Mode/times: accepted silently (the wire has no chmod yet);
            // the fresh stat below reports the real state — honesty
            // through the attr, not a fake success value.
            var arena = std.heap.ArenaAllocator.init(m.allocator);
            defer arena.deinit();
            const e = m.fs.statPath(arena.allocator(), path) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            var out = std.mem.zeroes(c.struct_fuse_attr_out);
            out.attr_valid = 1;
            m.fillAttr(hdr.nodeid, e, &out.attr);
            replyStruct(fd, u, out);
        },
        c.FUSE_CREATE => {
            const in: *const c.struct_fuse_create_in = @ptrCast(@alignCast(body.ptr));
            const parent = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const name = std.mem.sliceTo(body[@sizeOf(c.struct_fuse_create_in)..], 0);
            var pbuf: [4096]u8 = undefined;
            const full = Mount.joinChild(&pbuf, parent, name) orelse return replyErr(fd, u, c.ENAMETOOLONG);
            _ = m.fs.write(full, 0, &.{}, .{
                .create = true,
                .truncate = true,
                .exclusive = (in.flags & @as(u32, @intCast(c.O_EXCL))) != 0,
            }) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            // entry_out + open_out in one payload.
            var arena = std.heap.ArenaAllocator.init(m.allocator);
            defer arena.deinit();
            const e = m.fs.statPath(arena.allocator(), full) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            const id = m.ensureNode(full) catch return replyErr(fd, u, c.ENOMEM);
            m.nodes.items[@intCast(id - 1)].?.nlookup += 1;
            var pair: extern struct {
                entry: c.struct_fuse_entry_out,
                open: c.struct_fuse_open_out,
            } = undefined;
            pair.entry = std.mem.zeroes(c.struct_fuse_entry_out);
            pair.entry.nodeid = id;
            pair.entry.entry_valid = 1;
            pair.entry.attr_valid = 1;
            m.fillAttr(id, e, &pair.entry.attr);
            pair.open = std.mem.zeroes(c.struct_fuse_open_out);
            pair.open.fh = m.next_fh;
            m.next_fh += 1;
            replyStruct(fd, u, pair);
        },
        c.FUSE_MKDIR => {
            const parent = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const name = std.mem.sliceTo(body[@sizeOf(c.struct_fuse_mkdir_in)..], 0);
            var pbuf: [4096]u8 = undefined;
            const full = Mount.joinChild(&pbuf, parent, name) orelse return replyErr(fd, u, c.ENAMETOOLONG);
            m.fs.mkdir(full) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            m.replyEntry(u, full);
        },
        c.FUSE_UNLINK, c.FUSE_RMDIR => {
            const parent = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const name = std.mem.sliceTo(body, 0);
            var pbuf: [4096]u8 = undefined;
            const full = Mount.joinChild(&pbuf, parent, name) orelse return replyErr(fd, u, c.ENAMETOOLONG);
            m.fs.deletePath(full) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            replyBytes(fd, u, "");
        },
        c.FUSE_RENAME, c.FUSE_RENAME2 => {
            const hdr_size: usize = if (hdr.opcode == c.FUSE_RENAME2)
                @sizeOf(c.struct_fuse_rename2_in)
            else
                @sizeOf(c.struct_fuse_rename_in);
            const newdir: u64 = if (hdr.opcode == c.FUSE_RENAME2)
                @as(*const c.struct_fuse_rename2_in, @ptrCast(@alignCast(body.ptr))).newdir
            else
                @as(*const c.struct_fuse_rename_in, @ptrCast(@alignCast(body.ptr))).newdir;
            const parent = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const nparent = m.pathOf(newdir) orelse return replyErr(fd, u, c.ENOENT);
            const names = body[hdr_size..];
            const old_name = std.mem.sliceTo(names, 0);
            const new_name = std.mem.sliceTo(names[old_name.len + 1 ..], 0);
            var b1: [4096]u8 = undefined;
            var b2: [4096]u8 = undefined;
            const oldp = Mount.joinChild(&b1, parent, old_name) orelse return replyErr(fd, u, c.ENAMETOOLONG);
            const newp = Mount.joinChild(&b2, nparent, new_name) orelse return replyErr(fd, u, c.ENAMETOOLONG);
            m.fs.rename(oldp, newp) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            m.renamePaths(oldp, newp);
            replyBytes(fd, u, "");
        },
        c.FUSE_SYMLINK => {
            const parent = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const name = std.mem.sliceTo(body, 0);
            const target = std.mem.sliceTo(body[name.len + 1 ..], 0);
            var pbuf: [4096]u8 = undefined;
            const full = Mount.joinChild(&pbuf, parent, name) orelse return replyErr(fd, u, c.ENAMETOOLONG);
            m.fs.symlink(target, full) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            m.replyEntry(u, full);
        },
        c.FUSE_READLINK => {
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            var arena = std.heap.ArenaAllocator.init(m.allocator);
            defer arena.deinit();
            const e = m.fs.statPath(arena.allocator(), path) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            const tgt = e.target orelse return replyErr(fd, u, c.EINVAL);
            replyBytes(fd, u, tgt);
        },
        c.FUSE_STATFS => {
            var out = std.mem.zeroes(c.struct_fuse_statfs_out);
            out.st.bsize = 4096;
            out.st.frsize = 4096;
            out.st.namelen = 255;
            out.st.blocks = 1 << 30;
            out.st.bfree = 1 << 29;
            out.st.bavail = 1 << 29;
            out.st.files = 1 << 20;
            out.st.ffree = 1 << 19;
            replyStruct(fd, u, out);
        },
        c.FUSE_GETXATTR, c.FUSE_SETXATTR, c.FUSE_LISTXATTR, c.FUSE_REMOVEXATTR => replyErr(fd, u, c.ENOSYS),
        c.FUSE_DESTROY => replyBytes(fd, u, ""),
        else => replyErr(fd, u, c.ENOSYS),
    }
}

// ── CLI entry (`sketerm mount`) ─────────────────────────────────

/// `sketerm mount <host>[:/path] <mountpoint>`. Foreground; Ctrl-C
/// or `fusermount3 -u <mountpoint>` ends it.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (comptime !is_linux) {
        _ = c.fprintf(platform.stderr(), "sketerm mount: Linux only (FUSE)\n");
        return 1;
    }
    if (args.len < 2) {
        _ = c.fprintf(platform.stderr(), "usage: sketerm mount <host>[:/path] <mountpoint>\n" ++
            "       host 'local' mounts the local daemon's view (testing)\n");
        return 2;
    }
    const spec = args[0];
    var host: ?[]const u8 = null;
    var root: []const u8 = "/";
    if (std.mem.indexOf(u8, spec, ":/")) |i| {
        const h = spec[0..i];
        root = spec[i + 1 ..];
        if (h.len > 0 and !std.mem.eql(u8, h, "local")) host = h;
    } else if (!std.mem.eql(u8, spec, "local")) {
        host = spec;
    }

    var mp_z: [4096:0]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&mp_z, "{s}", .{args[1]}) catch return 2;

    const conn = blk: {
        if (host) |h| {
            if (std.mem.startsWith(u8, h, "udp:")) {
                break :blk muxclient.Conn.connectUdp(allocator, h[4..], null) catch |err| {
                    _ = c.fprintf(platform.stderr(), "sketerm mount: cannot connect: %s\n", @errorName(err).ptr);
                    return 1;
                };
            }
            break :blk muxclient.Conn.connectSsh(allocator, h) catch |err| {
                _ = c.fprintf(platform.stderr(), "sketerm mount: cannot connect: %s\n", @errorName(err).ptr);
                return 1;
            };
        }
        break :blk muxclient.Conn.connectLocalAutostart(allocator) catch |err| {
            _ = c.fprintf(platform.stderr(), "sketerm mount: local daemon unreachable: %s\n", @errorName(err).ptr);
            return 1;
        };
    };
    var fs = fsdrive.Fs.initConn(allocator, conn);
    defer fs.deinit();

    const fuse_fd = openFuseFd(mp.ptr) catch |err| {
        _ = c.fprintf(platform.stderr(), "sketerm mount: fusermount3 failed: %s (is fuse3 installed?)\n", @errorName(err).ptr);
        return 1;
    };
    defer _ = c.close(fuse_fd);

    // No SA_RESTART: the fuse read must return EINTR so Ctrl-C is
    // seen between requests.
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    _ = c.fprintf(platform.stderr(), "sketerm mount: %s serving on %s (Ctrl-C or fusermount3 -u to stop)\n", if (host) |h| h.ptr else "local", mp.ptr);
    serve(allocator, &fs, root, fuse_fd) catch |err| {
        _ = c.fprintf(platform.stderr(), "sketerm mount: serve failed: %s\n", @errorName(err).ptr);
        unmount(mp.ptr);
        return 1;
    };
    if (g_stop) unmount(mp.ptr);
    return 0;
}

// ── tests (pure bookkeeping; the kernel loop needs /dev/fuse) ───

test "node table: ensure, lookup-count, forget, slot reuse" {
    const t = std.testing;
    if (comptime !is_linux) return error.SkipZigTest;
    var fs_dummy: fsdrive.Fs = undefined;
    const m = try Mount.init(t.allocator, &fs_dummy, "/root", -1);
    defer m.deinit();

    const a = try m.ensureNode("/root/a");
    try t.expectEqual(@as(u64, 2), a);
    try t.expectEqual(a, try m.ensureNode("/root/a")); // stable
    m.nodes.items[@intCast(a - 1)].?.nlookup += 1;

    const b = try m.ensureNode("/root/b");
    try t.expectEqual(@as(u64, 3), b);
    m.nodes.items[@intCast(b - 1)].?.nlookup += 1;

    m.forget(a, 1);
    try t.expect(m.nodes.items[@intCast(a - 1)] == null);
    // Freed slot is reused for the next new path.
    const cid = try m.ensureNode("/root/c");
    try t.expectEqual(a, cid);
}

test "renamePaths rewrites the subtree" {
    const t = std.testing;
    if (comptime !is_linux) return error.SkipZigTest;
    var fs_dummy: fsdrive.Fs = undefined;
    const m = try Mount.init(t.allocator, &fs_dummy, "/", -1);
    defer m.deinit();
    _ = try m.ensureNode("/old");
    _ = try m.ensureNode("/old/child");
    _ = try m.ensureNode("/oldish"); // prefix but NOT under /old
    m.renamePaths("/old", "/new");
    try t.expect(m.by_path.get("/new") != null);
    try t.expect(m.by_path.get("/new/child") != null);
    try t.expect(m.by_path.get("/oldish") != null);
    try t.expect(m.by_path.get("/old") == null);
}

test "errnoOf maps daemon errno names" {
    const t = std.testing;
    if (comptime !is_linux) return error.SkipZigTest;
    try t.expectEqual(@as(i32, c.ENOENT), errnoOf(error.FsOpFailed, "NOENT"));
    try t.expectEqual(@as(i32, c.EACCES), errnoOf(error.FsOpFailed, "open src: ACCES"));
    try t.expectEqual(@as(i32, c.EIO), errnoOf(error.FsOpFailed, "weird"));
    try t.expectEqual(@as(i32, c.EIO), errnoOf(error.Timeout, ""));
}
