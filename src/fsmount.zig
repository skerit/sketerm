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
//! SETATTR size maps to the wire `truncate` op (any length), with
//! cached ranges invalidated afterward.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const muxclient = @import("mux/client.zig");
const fsdrive = @import("ipc/fsdrive.zig");
const platform = @import("util/platform.zig");
const fscache = @import("filebrowser/cache.zig");

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
    path: []u8,
    view_id: u32,
};

const PendingPin = struct {
    path: []u8,
    retry_at_ms: i64 = 0,
    retry_delay_ms: i64 = 1000,
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
    next_view: u32 = 1,
    pin_queue: std.ArrayList(PendingPin) = .empty,
    uid: u32,
    gid: u32,
    cache: fscache.Cache,

    fn init(allocator: std.mem.Allocator, fs: *fsdrive.Fs, root: []const u8, namespace: []const u8, fuse_fd: c_int) !*Mount {
        const self = try allocator.create(Mount);
        errdefer allocator.destroy(self);
        const root_owned = try allocator.dupe(u8, root);
        errdefer allocator.free(root_owned);
        self.* = .{
            .allocator = allocator,
            .fs = fs,
            .fuse_fd = fuse_fd,
            .root = root_owned,
            .by_path = std.StringHashMap(u64).init(allocator),
            .dirs = std.AutoHashMap(u64, *DirH).init(allocator),
            .uid = @intCast(c.getuid()),
            .gid = @intCast(c.getgid()),
            .cache = try fscache.Cache.init(allocator, namespace),
        };
        errdefer self.cache.deinit();
        errdefer self.dirs.deinit();
        errdefer self.by_path.deinit();
        // nodeid 1 = the root.
        const node_root = try allocator.dupe(u8, root);
        errdefer allocator.free(node_root);
        try self.nodes.append(allocator, .{ .path = node_root, .nlookup = 1 });
        errdefer self.nodes.deinit(allocator);
        try self.by_path.put(node_root, 1);
        if (self.cache.pinnedKeys(allocator)) |keys| {
            defer {
                for (keys) |key| allocator.free(key);
                allocator.free(keys);
            }
            for (keys) |key| self.queuePin(key);
        } else |_| {}
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
            self.allocator.free(dh.*.path);
            self.allocator.destroy(dh.*);
        }
        self.dirs.deinit();
        for (self.pin_queue.items) |pin| self.allocator.free(pin.path);
        self.pin_queue.deinit(self.allocator);
        self.cache.deinit();
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
        var id: u64 = undefined;
        if (self.free_ids.getLastOrNull()) |slot| {
            id = slot + 1;
            self.by_path.put(owned, id) catch {
                self.allocator.free(owned);
                return error.OutOfMemory;
            };
            _ = self.free_ids.pop();
            self.nodes.items[slot] = .{ .path = owned, .nlookup = 0 };
        } else {
            id = self.nodes.items.len;
            id += 1;
            self.by_path.put(owned, id) catch {
                self.allocator.free(owned);
                return error.OutOfMemory;
            };
            self.nodes.append(self.allocator, .{ .path = owned, .nlookup = 0 }) catch {
                _ = self.by_path.remove(owned);
                self.allocator.free(owned);
                return error.OutOfMemory;
            };
        }
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

    fn renameDirHandles(self: *Mount, old: []const u8, new: []const u8) void {
        var it = self.dirs.valueIterator();
        while (it.next()) |dh_ptr| {
            const dh = dh_ptr.*;
            const hit = std.mem.startsWith(u8, dh.path, old) and
                (dh.path.len == old.len or dh.path[old.len] == '/');
            if (!hit) continue;
            const replacement = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ new, dh.path[old.len..] }) catch continue;
            const new_view = self.next_view;
            self.next_view +%= 1;
            if (self.next_view == 0) self.next_view = 1;
            const listing = self.fs.openView(new_view, replacement) catch {
                self.allocator.free(replacement);
                continue;
            };
            const old_view = dh.view_id;
            dh.listing.deinit();
            dh.listing = listing;
            self.allocator.free(dh.path);
            dh.path = replacement;
            dh.view_id = new_view;
            self.fs.closeView(old_view) catch {};
        }
    }

    fn renameCachedPaths(self: *Mount, old: []const u8, new: []const u8) void {
        _ = self.cache.rename(old, new);
        if (self.cache.pinnedKeys(self.allocator)) |keys| {
            defer {
                for (keys) |key| self.allocator.free(key);
                self.allocator.free(keys);
            }
            for (keys) |key| {
                const hit = std.mem.startsWith(u8, key, old) and
                    key.len > old.len and key[old.len] == '/';
                if (!hit) continue;
                const replacement = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ new, key[old.len..] }) catch continue;
                defer self.allocator.free(replacement);
                _ = self.cache.rename(key, replacement);
            }
        } else |_| {}
        for (self.nodes.items) |maybe_node| {
            const node = maybe_node orelse continue;
            const hit = std.mem.startsWith(u8, node.path, old) and
                node.path.len > old.len and node.path[old.len] == '/';
            if (!hit) continue;
            if (!self.cache.has(node.path)) continue;
            var buf: [4096]u8 = undefined;
            const replacement = std.fmt.bufPrint(&buf, "{s}{s}", .{ new, node.path[old.len..] }) catch continue;
            _ = self.cache.rename(node.path, replacement);
        }
        self.renameQueuedPins(old, new);
    }

    fn queuePin(self: *Mount, path: []const u8) void {
        for (self.pin_queue.items) |*queued| {
            if (std.mem.eql(u8, queued.path, path)) {
                queued.retry_at_ms = 0;
                queued.retry_delay_ms = 1000;
                return;
            }
        }
        const owned = self.allocator.dupe(u8, path) catch return;
        self.pin_queue.append(self.allocator, .{ .path = owned }) catch self.allocator.free(owned);
    }

    fn removeQueuedPin(self: *Mount, index: usize) void {
        self.allocator.free(self.pin_queue.items[index].path);
        _ = self.pin_queue.orderedRemove(index);
    }

    fn retryQueuedPin(self: *Mount, index: usize) void {
        const pin = &self.pin_queue.items[index];
        pin.retry_at_ms = monotonicNowMs() + pin.retry_delay_ms;
        pin.retry_delay_ms = @min(pin.retry_delay_ms * 2, 60_000);
    }

    fn renameQueuedPins(self: *Mount, old: []const u8, new: []const u8) void {
        for (self.pin_queue.items) |*pin| {
            const hit = std.mem.startsWith(u8, pin.path, old) and
                (pin.path.len == old.len or pin.path[old.len] == '/');
            if (!hit) continue;
            const replacement = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ new, pin.path[old.len..] }) catch continue;
            self.allocator.free(pin.path);
            pin.path = replacement;
            pin.retry_at_ms = 0;
            pin.retry_delay_ms = 1000;
        }
    }

    fn removeQueuedPins(self: *Mount, path: []const u8) void {
        var i: usize = 0;
        while (i < self.pin_queue.items.len) {
            const queued = self.pin_queue.items[i].path;
            const hit = std.mem.startsWith(u8, queued, path) and
                (queued.len == path.len or queued[path.len] == '/');
            if (hit) self.removeQueuedPin(i) else i += 1;
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
        out.blocks = e.blocks;
        setFuseTime(&out.atime, &out.atimensec, e.atime_ms);
        setFuseTime(&out.mtime, &out.mtimensec, e.mtime_ms);
        setFuseTime(&out.ctime, &out.ctimensec, e.ctime_ms);
        const ifmt: u32 = if (std.mem.eql(u8, e.kind, "dir"))
            c.S_IFDIR
        else if (std.mem.eql(u8, e.kind, "link"))
            c.S_IFLNK
        else
            c.S_IFREG;
        out.mode = ifmt | e.mode;
        out.nlink = @intCast(@min(e.nlink, std.math.maxInt(u32)));
        out.uid = self.uid;
        out.gid = self.gid;
        out.blksize = 4096;
    }
};

fn entryVersion(e: fsdrive.Entry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&e.dev));
    h.update(std.mem.asBytes(&e.ino));
    h.update(std.mem.asBytes(&e.mtime_ms));
    h.update(std.mem.asBytes(&e.ctime_ms));
    h.update(std.mem.asBytes(&e.mtime_ns));
    h.update(std.mem.asBytes(&e.ctime_ns));
    h.update(std.mem.asBytes(&e.size));
    return h.final();
}

fn setFuseTime(sec: *u64, nsec: *u32, ms: i64) void {
    const nonneg = @max(ms, 0);
    sec.* = @intCast(@divTrunc(nonneg, 1000));
    nsec.* = @intCast(@mod(nonneg, 1000) * 1_000_000);
}

fn realNowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

fn monotonicNowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

fn fuseTimeMs(sec: u64, nsec: u32) ?i64 {
    if (nsec >= std.time.ns_per_s) return null;
    const max_sec: u64 = @intCast(@divTrunc(std.math.maxInt(i64), 1000));
    if (sec > max_sec) return null;
    return @as(i64, @intCast(sec)) * 1000 + @divTrunc(@as(i64, @intCast(nsec)), 1_000_000);
}

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

fn notifyInvalInode(fd: c_int, nodeid: u64) void {
    var hdr = std.mem.zeroes(c.struct_fuse_out_header);
    var out = std.mem.zeroes(c.struct_fuse_notify_inval_inode_out);
    hdr.len = @sizeOf(c.struct_fuse_out_header) + @sizeOf(c.struct_fuse_notify_inval_inode_out);
    hdr.@"error" = c.FUSE_NOTIFY_INVAL_INODE;
    out.ino = nodeid;
    out.off = 0;
    out.len = -1;
    var iov = [_]c.struct_iovec{
        .{ .iov_base = @ptrCast(&hdr), .iov_len = @sizeOf(c.struct_fuse_out_header) },
        .{ .iov_base = @ptrCast(&out), .iov_len = @sizeOf(c.struct_fuse_notify_inval_inode_out) },
    };
    _ = c.writev(fd, &iov, iov.len);
}

fn notifyInvalEntry(fd: c_int, parent: u64, name: []const u8) void {
    var hdr = std.mem.zeroes(c.struct_fuse_out_header);
    var out = std.mem.zeroes(c.struct_fuse_notify_inval_entry_out);
    hdr.len = @intCast(@sizeOf(c.struct_fuse_out_header) + @sizeOf(c.struct_fuse_notify_inval_entry_out) + name.len);
    hdr.@"error" = c.FUSE_NOTIFY_INVAL_ENTRY;
    out.parent = parent;
    out.namelen = @intCast(name.len);
    var iov = [_]c.struct_iovec{
        .{ .iov_base = @ptrCast(&hdr), .iov_len = @sizeOf(c.struct_fuse_out_header) },
        .{ .iov_base = @ptrCast(&out), .iov_len = @sizeOf(c.struct_fuse_notify_inval_entry_out) },
        .{ .iov_base = @constCast(@ptrCast(name.ptr)), .iov_len = name.len },
    };
    _ = c.writev(fd, &iov, iov.len);
}

const cache_state_xattr = "user.sketerm.cache-state";
const cache_pin_xattr = "user.sketerm.pin";
const cache_evict_xattr = "user.sketerm.evict";
const cache_xattrs = cache_state_xattr ++ "\x00" ++ cache_pin_xattr ++ "\x00" ++ cache_evict_xattr ++ "\x00";

fn replyXattr(fd: c_int, unique: u64, requested: u32, value: []const u8) void {
    if (requested == 0) {
        var out = std.mem.zeroes(c.struct_fuse_getxattr_out);
        out.size = @intCast(value.len);
        return replyStruct(fd, unique, out);
    }
    if (requested < value.len) return replyErr(fd, unique, c.ERANGE);
    replyBytes(fd, unique, value);
}

const CacheRef = struct { entry: *fscache.Entry, regular: bool };

fn cacheEntry(m: *Mount, path: []const u8) fsdrive.Error!CacheRef {
    var arena = std.heap.ArenaAllocator.init(m.allocator);
    defer arena.deinit();
    const attr = try m.fs.statPath(arena.allocator(), path);
    const entry = m.cache.get(path, entryVersion(attr), attr.size) catch return error.OutOfMemory;
    if (entry.pinned and entry.ranges.firstMissing(entry.size) != null) m.queuePin(path);
    return .{ .entry = entry, .regular = std.mem.eql(u8, attr.kind, "file") };
}

fn invalidateCached(m: *Mount, path: []const u8) void {
    if (m.cache.invalidate(path)) m.queuePin(path);
}

fn processDeltas(m: *Mount) void {
    while (m.fs.takeDelta()) |delta_value| {
        var delta = delta_value;
        defer delta.deinit();
        var dir_it = m.dirs.valueIterator();
        while (dir_it.next()) |dh_ptr| {
            const dh = dh_ptr.*;
            if (dh.view_id != delta.view) continue;
            const parent = m.by_path.get(dh.path) orelse 1;
            if (delta.resync or delta.gone) {
                notifyInvalInode(m.fuse_fd, parent);
                for (m.nodes.items) |maybe_node| {
                    const node = maybe_node orelse continue;
                    const node_parent = std.fs.path.dirname(node.path) orelse continue;
                    if (!std.mem.eql(u8, node_parent, dh.path)) continue;
                    invalidateCached(m, node.path);
                    notifyInvalEntry(m.fuse_fd, parent, std.fs.path.basename(node.path));
                    if (m.by_path.get(node.path)) |nodeid| notifyInvalInode(m.fuse_fd, nodeid);
                }
            }
            for (delta.changes) |change| {
                notifyInvalEntry(m.fuse_fd, parent, change.name);
                var path_buf: [4096]u8 = undefined;
                const full = Mount.joinChild(&path_buf, dh.path, change.name) orelse continue;
                invalidateCached(m, full);
                if (m.by_path.get(full)) |nodeid| notifyInvalInode(m.fuse_fd, nodeid);
            }
            if (!delta.gone) {
                if (m.fs.list(dh.path)) |listing| {
                    dh.listing.deinit();
                    dh.listing = listing;
                } else |_| {}
            }
            break;
        }
    }
}

fn servicePinnedCache(m: *Mount) void {
    if (m.pin_queue.items.len == 0) return;
    const now = monotonicNowMs();
    var index: ?usize = null;
    for (m.pin_queue.items, 0..) |pin, i| {
        if (pin.retry_at_ms <= now) {
            index = i;
            break;
        }
    }
    const pin_index = index orelse return;
    const path = m.pin_queue.items[pin_index].path;
    var arena = std.heap.ArenaAllocator.init(m.allocator);
    defer arena.deinit();
    const attr = m.fs.statPath(arena.allocator(), path) catch {
        m.retryQueuedPin(pin_index);
        return;
    };
    const entry = m.cache.get(path, entryVersion(attr), attr.size) catch {
        m.retryQueuedPin(pin_index);
        return;
    };
    if (!entry.pinned) {
        m.removeQueuedPin(pin_index);
        return;
    }
    const off = entry.ranges.firstMissing(entry.size) orelse {
        m.removeQueuedPin(pin_index);
        return;
    };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(m.allocator);
    const want: u32 = @intCast(@min(entry.size - off, fsdrive.fsserve.MAX_READ));
    _ = m.fs.read(path, off, want, &bytes) catch {
        m.retryQueuedPin(pin_index);
        return;
    };
    if (bytes.items.len == 0) {
        m.retryQueuedPin(pin_index);
        return;
    }
    if (!m.cache.store(entry, off, bytes.items)) {
        m.retryQueuedPin(pin_index);
        return;
    }
    if (entry.ranges.firstMissing(entry.size) == null) m.removeQueuedPin(pin_index);
}

fn pinPollTimeout(m: *const Mount) c_int {
    if (m.pin_queue.items.len == 0) return -1;
    const now = monotonicNowMs();
    var delay: i64 = std.math.maxInt(c_int);
    for (m.pin_queue.items) |pin| delay = @min(delay, @max(pin.retry_at_ms - now, 0));
    return @intCast(delay);
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
    return serveNamespaced(allocator, fs, root, root, fuse_fd);
}

fn serveNamespaced(allocator: std.mem.Allocator, fs: *fsdrive.Fs, root: []const u8, namespace: []const u8, fuse_fd: c_int) !void {
    if (comptime !is_linux) return error.Unsupported;
    const m = try Mount.init(allocator, fs, root, namespace, fuse_fd);
    defer m.deinit();

    const buf = try allocator.alignedAlloc(u8, std.mem.Alignment.of(u64), MAX_WRITE + 64 * 1024);
    defer allocator.free(buf);

    while (!g_stop) {
        var fds = [_]c.struct_pollfd{
            .{ .fd = fuse_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = fs.pollFd(), .events = c.POLLIN, .revents = 0 },
        };
        const timeout = pinPollTimeout(m);
        const ready = c.poll(&fds, fds.len, timeout);
        if (ready < 0) {
            if (std.posix.errno(ready) == .INTR) continue;
            return error.PollFailed;
        }
        if (fds[1].revents & (c.POLLHUP | c.POLLERR) != 0) return error.TransportClosed;
        if (fds[1].revents & c.POLLIN != 0) processDeltas(m);
        if (ready == 0) {
            servicePinnedCache(m);
            continue;
        }
        if (fds[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) == 0) continue;
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
        processDeltas(m);
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
            // Notifications shorten normal kernel cache lifetimes, but do
            // not claim explicit-only invalidation: watches are scoped to
            // open directory handles.
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
            const view_id = m.next_view;
            m.next_view +%= 1;
            if (m.next_view == 0) m.next_view = 1;
            var listing = m.fs.openView(view_id, path) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            const dh = m.allocator.create(DirH) catch {
                listing.deinit();
                m.fs.closeView(view_id) catch {};
                return replyErr(fd, u, c.ENOMEM);
            };
            const owned_path = m.allocator.dupe(u8, path) catch {
                listing.deinit();
                m.fs.closeView(view_id) catch {};
                m.allocator.destroy(dh);
                return replyErr(fd, u, c.ENOMEM);
            };
            dh.* = .{ .listing = listing, .path = owned_path, .view_id = view_id };
            const fh = m.next_fh;
            m.next_fh += 1;
            m.dirs.put(fh, dh) catch {
                m.fs.closeView(view_id) catch {};
                dh.listing.deinit();
                m.allocator.free(dh.path);
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
                m.fs.closeView(kv.value.view_id) catch {};
                kv.value.listing.deinit();
                m.allocator.free(kv.value.path);
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
            var cache_arena = std.heap.ArenaAllocator.init(m.allocator);
            defer cache_arena.deinit();
            const attr = m.fs.statPath(cache_arena.allocator(), path) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            const ce = m.cache.get(path, entryVersion(attr), attr.size) catch
                return replyErr(fd, u, c.ENOMEM);
            if (ce.pinned and ce.ranges.firstMissing(ce.size) != null) m.queuePin(path);
            if (m.cache.read(ce, in.offset, in.size, &out)) {
                return replyBytes(fd, u, out.items);
            }
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
            _ = m.cache.store(ce, in.offset, out.items);
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
            invalidateCached(m, path);
            notifyInvalInode(fd, hdr.nodeid);
            replyStruct(fd, u, out);
        },
        c.FUSE_FLUSH, c.FUSE_RELEASE => replyBytes(fd, u, ""),
        c.FUSE_FSYNC => {
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            m.fs.fsync(path) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            replyBytes(fd, u, "");
        },
        c.FUSE_ACCESS => {
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const in: *const c.struct_fuse_access_in = @ptrCast(@alignCast(body.ptr));
            m.fs.access(path, in.mask) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            replyBytes(fd, u, "");
        },
        c.FUSE_SETATTR => {
            const in: *const c.struct_fuse_setattr_in = @ptrCast(@alignCast(body.ptr));
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const supported = c.FATTR_MODE | c.FATTR_UID | c.FATTR_GID | c.FATTR_SIZE |
                c.FATTR_ATIME | c.FATTR_MTIME | c.FATTR_FH | c.FATTR_ATIME_NOW |
                c.FATTR_MTIME_NOW | c.FATTR_LOCKOWNER | c.FATTR_KILL_SUIDGID;
            if (in.valid & ~@as(u32, @intCast(supported)) != 0)
                return replyErr(fd, u, c.EOPNOTSUPP);
            if (in.valid & c.FATTR_SIZE != 0) {
                m.fs.truncate(path, in.size) catch |err|
                    return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
                invalidateCached(m, path);
                notifyInvalInode(fd, hdr.nodeid);
            }
            if (in.valid & c.FATTR_MODE != 0)
                m.fs.chmod(path, in.mode) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            if (in.valid & (c.FATTR_UID | c.FATTR_GID) != 0)
                m.fs.chown(
                    path,
                    if (in.valid & c.FATTR_UID != 0) in.uid else null,
                    if (in.valid & c.FATTR_GID != 0) in.gid else null,
                ) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            if (in.valid & (c.FATTR_ATIME | c.FATTR_MTIME | c.FATTR_ATIME_NOW | c.FATTR_MTIME_NOW) != 0) {
                const now = realNowMs();
                const atime: ?i64 = if (in.valid & c.FATTR_ATIME_NOW != 0)
                    now
                else if (in.valid & c.FATTR_ATIME != 0)
                    fuseTimeMs(in.atime, in.atimensec) orelse return replyErr(fd, u, c.EOVERFLOW)
                else
                    null;
                const mtime: ?i64 = if (in.valid & c.FATTR_MTIME_NOW != 0)
                    now
                else if (in.valid & c.FATTR_MTIME != 0)
                    fuseTimeMs(in.mtime, in.mtimensec) orelse return replyErr(fd, u, c.EOVERFLOW)
                else
                    null;
                m.fs.utimens(path, atime, mtime) catch |err|
                    return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            }
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
            if (hdr.opcode == c.FUSE_RMDIR) {
                m.fs.rmdir(full) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            } else {
                m.fs.unlink(full) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            }
            m.cache.remove(full);
            m.removeQueuedPins(full);
            notifyInvalEntry(fd, hdr.nodeid, name);
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
            if (hdr.opcode == c.FUSE_RENAME2) {
                const rin: *const c.struct_fuse_rename2_in = @ptrCast(@alignCast(body.ptr));
                if (rin.flags != 0) return replyErr(fd, u, c.EOPNOTSUPP);
            }
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
            m.renameCachedPaths(oldp, newp);
            notifyInvalEntry(fd, hdr.nodeid, old_name);
            notifyInvalEntry(fd, newdir, new_name);
            m.renameDirHandles(oldp, newp);
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
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const st = m.fs.statFs(path) catch |err| return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            var out = std.mem.zeroes(c.struct_fuse_statfs_out);
            out.st.bsize = @intCast(st.bsize);
            out.st.frsize = @intCast(st.frsize);
            out.st.namelen = @intCast(st.namemax);
            out.st.blocks = st.blocks;
            out.st.bfree = st.bfree;
            out.st.bavail = st.bavail;
            out.st.files = st.files;
            out.st.ffree = st.ffree;
            replyStruct(fd, u, out);
        },
        c.FUSE_GETXATTR => {
            if (body.len < @sizeOf(c.struct_fuse_getxattr_in) + 1) return replyErr(fd, u, c.EINVAL);
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const in: *const c.struct_fuse_getxattr_in = @ptrCast(@alignCast(body.ptr));
            const name = std.mem.sliceTo(body[@sizeOf(c.struct_fuse_getxattr_in)..], 0);
            const cache_ref = cacheEntry(m, path) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            const entry = cache_ref.entry;
            if (std.mem.eql(u8, name, cache_state_xattr))
                return replyXattr(fd, u, in.size, fscache.stateName(entry.state()));
            if (std.mem.eql(u8, name, cache_pin_xattr))
                return replyXattr(fd, u, in.size, if (entry.pinned) "1" else "0");
            if (std.mem.eql(u8, name, cache_evict_xattr))
                return replyXattr(fd, u, in.size, "0");
            replyErr(fd, u, c.ENODATA);
        },
        c.FUSE_LISTXATTR => {
            if (body.len < @sizeOf(c.struct_fuse_getxattr_in)) return replyErr(fd, u, c.EINVAL);
            const in: *const c.struct_fuse_getxattr_in = @ptrCast(@alignCast(body.ptr));
            replyXattr(fd, u, in.size, cache_xattrs);
        },
        c.FUSE_SETXATTR => {
            const compat_size: usize = @intCast(c.FUSE_COMPAT_SETXATTR_IN_SIZE);
            if (body.len < compat_size + 1) return replyErr(fd, u, c.EINVAL);
            const path = m.pathOf(hdr.nodeid) orelse return replyErr(fd, u, c.ENOENT);
            const in: *const c.struct_fuse_setxattr_in = @ptrCast(@alignCast(body.ptr));
            const rest = body[compat_size..];
            const name = std.mem.sliceTo(rest, 0);
            const value_start = name.len + 1;
            if (value_start + in.size > rest.len) return replyErr(fd, u, c.EINVAL);
            const value = rest[value_start..][0..in.size];
            const supported_name = std.mem.eql(u8, name, cache_pin_xattr) or
                std.mem.eql(u8, name, cache_evict_xattr);
            if (!supported_name) return replyErr(fd, u, c.EOPNOTSUPP);
            const allowed_flags: u32 = @intCast(c.XATTR_CREATE | c.XATTR_REPLACE);
            if (in.flags & ~allowed_flags != 0 or
                in.flags & c.XATTR_CREATE != 0 and in.flags & c.XATTR_REPLACE != 0)
                return replyErr(fd, u, c.EINVAL);
            if (in.flags & c.XATTR_CREATE != 0) return replyErr(fd, u, c.EEXIST);
            const cache_ref = cacheEntry(m, path) catch |err|
                return replyErr(fd, u, errnoOf(err, m.fs.lastErr()));
            if (!cache_ref.regular) return replyErr(fd, u, c.EINVAL);
            const entry = cache_ref.entry;
            if (std.mem.eql(u8, name, cache_pin_xattr)) {
                const pinned = std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
                if (!pinned and !std.mem.eql(u8, value, "0") and !std.ascii.eqlIgnoreCase(value, "false"))
                    return replyErr(fd, u, c.EINVAL);
                if (!m.cache.setPinned(entry, pinned)) return replyErr(fd, u, c.EIO);
                if (pinned) m.queuePin(path);
                replyBytes(fd, u, "");
            } else if (std.mem.eql(u8, name, cache_evict_xattr)) {
                if (!std.mem.eql(u8, value, "1")) return replyErr(fd, u, c.EINVAL);
                if (!m.cache.evict(entry)) return replyErr(fd, u, c.EBUSY);
                notifyInvalInode(fd, hdr.nodeid);
                replyBytes(fd, u, "");
            } else {
                replyErr(fd, u, c.EOPNOTSUPP);
            }
        },
        c.FUSE_REMOVEXATTR => {
            const name = std.mem.sliceTo(body, 0);
            _ = name;
            replyErr(fd, u, c.EOPNOTSUPP);
        },
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
    serveNamespaced(allocator, &fs, root, spec, fuse_fd) catch |err| {
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
    const m = try Mount.init(t.allocator, &fs_dummy, "/root", "test-root", -1);
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
    const m = try Mount.init(t.allocator, &fs_dummy, "/", "test-rename", -1);
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
