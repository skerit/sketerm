//! Persistent sparse-range cache for mux-backed filesystem mounts.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");

pub const Range = struct { start: u64, end: u64 };
pub const State = enum { placeholder, partial, hydrated, pinned };

pub fn stateName(state: State) []const u8 {
    return switch (state) {
        .placeholder => "placeholder",
        .partial => "partial",
        .hydrated => "hydrated",
        .pinned => "pinned",
    };
}

pub const RangeSet = struct {
    items: std.ArrayList(Range) = .empty,

    pub fn deinit(self: *RangeSet, a: std.mem.Allocator) void { self.items.deinit(a); }

    pub fn contains(self: *const RangeSet, start: u64, end: u64) bool {
        if (start == end) return true;
        for (self.items.items) |r| if (r.start <= start and r.end >= end) return true;
        return false;
    }

    pub fn add(self: *RangeSet, a: std.mem.Allocator, start: u64, end: u64) !void {
        if (start >= end) return;
        var merged = Range{ .start = start, .end = end };
        var i: usize = 0;
        while (i < self.items.items.len) {
            const r = self.items.items[i];
            if (r.end < merged.start or r.start > merged.end) {
                i += 1;
                continue;
            }
            merged.start = @min(merged.start, r.start);
            merged.end = @max(merged.end, r.end);
            _ = self.items.orderedRemove(i);
        }
        try self.items.append(a, merged);
        std.mem.sort(Range, self.items.items, {}, struct {
            fn lt(_: void, x: Range, y: Range) bool { return x.start < y.start; }
        }.lt);
    }

    pub fn firstMissing(self: *const RangeSet, size: u64) ?u64 {
        var covered: u64 = 0;
        for (self.items.items) |r| {
            if (r.start > covered) return covered;
            covered = @max(covered, r.end);
            if (covered >= size) return null;
        }
        return if (covered < size) covered else null;
    }
};

const DiskMeta = struct {
    version: u64,
    size: u64,
    pinned: bool = false,
    key: []const u8 = "",
    ranges: []const Range = &.{},
};

pub const Entry = struct {
    allocator: std.mem.Allocator,
    key: []u8,
    data_path: []u8,
    meta_path: []u8,
    version: u64,
    size: u64,
    pinned: bool = false,
    ranges: RangeSet = .{},

    fn deinit(self: *Entry) void {
        self.ranges.deinit(self.allocator);
        self.allocator.free(self.key);
        self.allocator.free(self.data_path);
        self.allocator.free(self.meta_path);
        self.allocator.destroy(self);
    }

    pub fn state(self: *const Entry) State {
        if (self.pinned) return .pinned;
        if (self.ranges.contains(0, self.size)) return .hydrated;
        if (self.ranges.items.items.len > 0) return .partial;
        return .placeholder;
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    entries: std.StringHashMap(*Entry),

    pub fn init(allocator: std.mem.Allocator, namespace: []const u8) !Cache {
        const base = if (c.getenv("XDG_CACHE_HOME")) |p|
            std.mem.span(@as([*:0]const u8, @ptrCast(p)))
        else if (c.getenv("HOME")) |p|
            std.mem.span(@as([*:0]const u8, @ptrCast(p)))
        else
            "/tmp";
        var h = std.hash.Wyhash.init(0);
        h.update(namespace);
        const root = if (std.mem.endsWith(u8, base, "/.cache"))
            try std.fmt.allocPrint(allocator, "{s}/sketerm/fscache/{x:0>16}", .{ base, h.final() })
        else if (c.getenv("XDG_CACHE_HOME") == null and c.getenv("HOME") != null)
            try std.fmt.allocPrint(allocator, "{s}/.cache/sketerm/fscache/{x:0>16}", .{ base, h.final() })
        else
            try std.fmt.allocPrint(allocator, "{s}/sketerm/fscache/{x:0>16}", .{ base, h.final() });
        const marker = try std.fmt.allocPrint(allocator, "{s}/x", .{root});
        defer allocator.free(marker);
        pathz.makeParentDirs(marker) catch {};
        var z: [4096]u8 = undefined;
        _ = c.mkdir(try pathz.pathZ(&z, root), 0o700);
        return .{ .allocator = allocator, .root = root, .entries = std.StringHashMap(*Entry).init(allocator) };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| entry.*.deinit();
        self.entries.deinit();
        self.allocator.free(self.root);
    }

    fn persist(self: *Cache, e: *Entry) bool {
        const tmp_path = std.fmt.allocPrint(self.allocator, "{s}.tmp.{d}", .{ e.meta_path, c.getpid() }) catch return false;
        defer self.allocator.free(tmp_path);
        var z: [4096]u8 = undefined;
        const fp = c.fopen(pathz.pathZ(&z, tmp_path) catch return false, "wb") orelse return false;
        var w: std.Io.Writer.Allocating = .init(self.allocator);
        defer w.deinit();
        std.json.Stringify.value(DiskMeta{
            .version = e.version,
            .size = e.size,
            .pinned = e.pinned,
            .key = e.key,
            .ranges = e.ranges.items.items,
        }, .{}, &w.writer) catch {
            _ = c.fclose(fp);
            _ = c.unlink(pathz.pathZ(&z, tmp_path) catch return false);
            return false;
        };
        const bytes = w.written();
        const written = c.fwrite(bytes.ptr, 1, bytes.len, fp);
        const flushed = written == bytes.len and c.fflush(fp) == 0;
        const closed = c.fclose(fp) == 0;
        if (!flushed or !closed) {
            _ = c.unlink(pathz.pathZ(&z, tmp_path) catch return false);
            return false;
        }
        var z2: [4096]u8 = undefined;
        if (c.rename(pathz.pathZ(&z, tmp_path) catch return false, pathz.pathZ(&z2, e.meta_path) catch return false) != 0) {
            _ = c.unlink(pathz.pathZ(&z, tmp_path) catch return false);
            return false;
        }
        return true;
    }

    pub fn get(self: *Cache, key: []const u8, version: u64, size: u64) !*Entry {
        if (self.entries.get(key)) |e| {
            if (e.version != version or e.size != size) self.reset(e, version, size);
            return e;
        }
        var h = std.hash.Wyhash.init(0);
        h.update(key);
        const id = h.final();
        const key_owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_owned);
        const data_path = try std.fmt.allocPrint(self.allocator, "{s}/{x:0>16}.data", .{ self.root, id });
        errdefer self.allocator.free(data_path);
        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/{x:0>16}.json", .{ self.root, id });
        errdefer self.allocator.free(meta_path);
        const e = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(e);
        e.* = .{
            .allocator = self.allocator,
            .key = key_owned,
            .data_path = data_path,
            .meta_path = meta_path,
            .version = version,
            .size = size,
        };
        errdefer e.ranges.deinit(self.allocator);
        // Recover ranges only when the remote version still matches.
        if (fsMetaLoad(self.allocator, e.meta_path)) |parsed| {
            defer parsed.deinit();
            e.pinned = parsed.value.pinned;
            if (parsed.value.version == version and parsed.value.size == size) {
                var z: [4096]u8 = undefined;
                var st: c.struct_stat = undefined;
                const data_size: u64 = blk: {
                    const data_z = pathz.pathZ(&z, e.data_path) catch break :blk 0;
                    if (c.stat(data_z, &st) != 0 or st.st_size < 0) break :blk 0;
                    break :blk @intCast(st.st_size);
                };
                for (parsed.value.ranges) |r| {
                    if (r.start > r.end or r.end > size or r.end > data_size) continue;
                    try e.ranges.add(self.allocator, r.start, r.end);
                }
            }
        } else |_| {}
        try self.entries.put(e.key, e);
        return e;
    }

    fn reset(self: *Cache, e: *Entry, version: u64, size: u64) void {
        e.version = version;
        e.size = size;
        e.ranges.items.clearRetainingCapacity();
        var z: [4096]u8 = undefined;
        const fd = c.open(pathz.pathZ(&z, e.data_path) catch return, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c.mode_t, 0o600));
        if (fd >= 0) _ = c.close(fd);
        _ = self.persist(e);
    }

    pub fn read(self: *Cache, e: *Entry, off: u64, len: usize, out: *std.ArrayList(u8)) bool {
        if (off >= e.size) return off == e.size;
        const end = @min(e.size, off +| @as(u64, @intCast(len)));
        if (!e.ranges.contains(off, end)) return false;
        var z: [4096]u8 = undefined;
        const fd = c.open(pathz.pathZ(&z, e.data_path) catch return false, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return false;
        defer _ = c.close(fd);
        const start_len = out.items.len;
        out.resize(self.allocator, start_len + @as(usize, @intCast(end - off))) catch return false;
        var got: usize = 0;
        while (got < end - off) {
            const n = c.pread(fd, out.items[start_len + got ..].ptr, @as(usize, @intCast(end - off)) - got, @intCast(off + got));
            if (n <= 0) { out.shrinkRetainingCapacity(start_len); return false; }
            got += @intCast(n);
        }
        return true;
    }

    pub fn store(self: *Cache, e: *Entry, off: u64, bytes: []const u8) bool {
        var z: [4096]u8 = undefined;
        const fd = c.open(pathz.pathZ(&z, e.data_path) catch return false, c.O_WRONLY | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
        if (fd < 0) return false;
        defer _ = c.close(fd);
        var done: usize = 0;
        while (done < bytes.len) {
            const n = c.pwrite(fd, bytes.ptr + done, bytes.len - done, @intCast(off + done));
            if (n <= 0) return false;
            done += @intCast(n);
        }
        e.ranges.add(self.allocator, off, off +| @as(u64, @intCast(bytes.len))) catch return false;
        return self.persist(e);
    }

    pub fn setPinned(self: *Cache, e: *Entry, pinned: bool) bool {
        const old = e.pinned;
        e.pinned = pinned;
        if (self.persist(e)) return true;
        e.pinned = old;
        return false;
    }

    pub fn invalidate(self: *Cache, key: []const u8) bool {
        const e = self.entries.get(key) orelse return false;
        self.reset(e, e.version +% 1, e.size);
        return e.pinned;
    }

    pub fn has(self: *Cache, key: []const u8) bool {
        if (self.entries.contains(key)) return true;
        var h = std.hash.Wyhash.init(0);
        h.update(key);
        const meta = std.fmt.allocPrint(self.allocator, "{s}/{x:0>16}.json", .{ self.root, h.final() }) catch return false;
        defer self.allocator.free(meta);
        var parsed = fsMetaLoad(self.allocator, meta) catch return false;
        defer parsed.deinit();
        return std.mem.eql(u8, parsed.value.key, key);
    }

    pub fn rename(self: *Cache, old: []const u8, new: []const u8) bool {
        const e = self.entries.get(old) orelse blk: {
            var old_h = std.hash.Wyhash.init(0);
            old_h.update(old);
            const old_meta = std.fmt.allocPrint(self.allocator, "{s}/{x:0>16}.json", .{ self.root, old_h.final() }) catch {
                self.remove(new);
                return false;
            };
            defer self.allocator.free(old_meta);
            var parsed = fsMetaLoad(self.allocator, old_meta) catch {
                self.remove(new);
                return false;
            };
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.key, old)) {
                self.remove(new);
                return false;
            }
            break :blk self.get(old, parsed.value.version, parsed.value.size) catch {
                self.remove(new);
                return false;
            };
        };
        const owned = self.allocator.dupe(u8, new) catch return e.pinned;
        var new_h = std.hash.Wyhash.init(0);
        new_h.update(new);
        const new_id = new_h.final();
        const new_data = std.fmt.allocPrint(self.allocator, "{s}/{x:0>16}.data", .{ self.root, new_id }) catch {
            self.allocator.free(owned);
            return e.pinned;
        };
        const new_meta = std.fmt.allocPrint(self.allocator, "{s}/{x:0>16}.json", .{ self.root, new_id }) catch {
            self.allocator.free(new_data);
            self.allocator.free(owned);
            return e.pinned;
        };
        if (self.entries.fetchRemove(new)) |removed| {
            if (removed.value != e) {
                var z: [4096]u8 = undefined;
                _ = c.unlink(pathz.pathZ(&z, removed.value.data_path) catch "");
                _ = c.unlink(pathz.pathZ(&z, removed.value.meta_path) catch "");
                removed.value.deinit();
            }
        }
        var staged = e.*;
        staged.key = owned;
        staged.data_path = new_data;
        staged.meta_path = new_meta;
        if (!self.persist(&staged)) {
            self.allocator.free(new_meta);
            self.allocator.free(new_data);
            self.allocator.free(owned);
            return e.pinned;
        }
        var z1: [4096]u8 = undefined;
        var z2: [4096]u8 = undefined;
        if (!std.mem.eql(u8, e.data_path, new_data)) {
            _ = c.unlink(pathz.pathZ(&z1, new_data) catch "");
            if (c.rename(pathz.pathZ(&z1, e.data_path) catch "", pathz.pathZ(&z2, new_data) catch "") != 0)
                e.ranges.items.clearRetainingCapacity();
        }
        if (!std.mem.eql(u8, e.meta_path, new_meta)) {
            _ = c.unlink(pathz.pathZ(&z1, e.meta_path) catch "");
        }
        _ = self.entries.remove(old);
        self.allocator.free(e.key);
        self.allocator.free(e.data_path);
        self.allocator.free(e.meta_path);
        e.key = owned;
        e.data_path = new_data;
        e.meta_path = new_meta;
        self.entries.put(e.key, e) catch return e.pinned;
        return e.pinned;
    }

    pub fn remove(self: *Cache, key: []const u8) void {
        if (self.entries.fetchRemove(key)) |removed| {
            var z: [4096]u8 = undefined;
            _ = c.unlink(pathz.pathZ(&z, removed.value.data_path) catch "");
            _ = c.unlink(pathz.pathZ(&z, removed.value.meta_path) catch "");
            removed.value.deinit();
            return;
        }
        var h = std.hash.Wyhash.init(0);
        h.update(key);
        const id = h.final();
        var z: [4096]u8 = undefined;
        const data = std.fmt.allocPrint(self.allocator, "{s}/{x:0>16}.data", .{ self.root, id }) catch return;
        defer self.allocator.free(data);
        const meta = std.fmt.allocPrint(self.allocator, "{s}/{x:0>16}.json", .{ self.root, id }) catch return;
        defer self.allocator.free(meta);
        _ = c.unlink(pathz.pathZ(&z, data) catch "");
        _ = c.unlink(pathz.pathZ(&z, meta) catch "");
    }

    pub fn pinnedKeys(self: *Cache, a: std.mem.Allocator) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |key| a.free(key);
            out.deinit(a);
        }
        var z: [4096]u8 = undefined;
        const dir = c.opendir(try pathz.pathZ(&z, self.root)) orelse return out.toOwnedSlice(a);
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |de| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            const meta_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.root, name });
            defer a.free(meta_path);
            var parsed = fsMetaLoad(a, meta_path) catch continue;
            defer parsed.deinit();
            if (!parsed.value.pinned or parsed.value.key.len == 0) continue;
            try out.append(a, try a.dupe(u8, parsed.value.key));
        }
        return out.toOwnedSlice(a);
    }

    pub fn evict(self: *Cache, e: *Entry) bool {
        if (e.pinned) return false;
        e.ranges.items.clearRetainingCapacity();
        var z: [4096]u8 = undefined;
        if (c.unlink(pathz.pathZ(&z, e.data_path) catch return false) != 0 and std.posix.errno(-1) != .NOENT)
            return false;
        return self.persist(e);
    }
};

fn fsMetaLoad(a: std.mem.Allocator, path: []const u8) !std.json.Parsed(DiskMeta) {
    var z: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&z, path), "rb") orelse return error.NotFound;
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return error.BadMeta;
    const size = c.ftell(fp);
    if (size <= 0 or size > 4 * 1024 * 1024) return error.BadMeta;
    if (c.fseek(fp, 0, c.SEEK_SET) != 0) return error.BadMeta;
    const buf = try a.alloc(u8, @intCast(size));
    defer a.free(buf);
    const n = c.fread(buf.ptr, 1, buf.len, fp);
    if (n != buf.len) return error.BadMeta;
    return std.json.parseFromSlice(DiskMeta, a, buf, .{ .allocate = .alloc_always });
}

test "RangeSet merges overlap and reports hydrated spans" {
    var rs: RangeSet = .{};
    defer rs.deinit(std.testing.allocator);
    try rs.add(std.testing.allocator, 10, 20);
    try rs.add(std.testing.allocator, 0, 12);
    try rs.add(std.testing.allocator, 20, 30);
    try std.testing.expectEqual(@as(usize, 1), rs.items.items.len);
    try std.testing.expect(rs.contains(0, 30));
    try std.testing.expect(!rs.contains(0, 31));
    try std.testing.expectEqual(@as(?u64, null), rs.firstMissing(30));
    try std.testing.expectEqual(@as(?u64, 30), rs.firstMissing(31));
}

test "cache state distinguishes placeholder partial hydrated and pinned" {
    var e = Entry{
        .allocator = std.testing.allocator,
        .key = &.{}, .data_path = &.{}, .meta_path = &.{}, .version = 1, .size = 100,
    };
    defer e.ranges.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.placeholder, e.state());
    try e.ranges.add(std.testing.allocator, 0, 10);
    try std.testing.expectEqual(State.partial, e.state());
    try e.ranges.add(std.testing.allocator, 10, 100);
    try std.testing.expectEqual(State.hydrated, e.state());
    e.pinned = true;
    try std.testing.expectEqual(State.pinned, e.state());
}
