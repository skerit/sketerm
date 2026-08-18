//! `registry.json`: the durable record of which extensions are
//! installed, and the cross-process lock that keeps two sketerm
//! processes from losing each other's entries.
//!
//! ## Why a lock at all
//!
//! The file is rewritten WHOLE through `atomicwrite`, so an atomic
//! write alone only guarantees a reader never sees half a file. Two
//! processes installing DIFFERENT extensions still both read the old
//! array, both append their own entry and both write: the second write
//! wins and one extension's entry is simply gone, while its package
//! tree stays on disk. The per-extension `flock` in `install.zig`
//! cannot help — it guards one extension's TREE, and the two processes
//! hold locks on different extensions.
//!
//! The lock therefore covers the READ as well as the write: the whole
//! read-modify-write is one critical section, and the modification is
//! applied to what is on DISK rather than to a caller's in-memory copy,
//! which may predate another process's install.
//!
//! It is the same `flock` shape `install.zig` uses, for the same
//! reasons: the kernel drops it when the holder dies, so a crash cannot
//! wedge every future install, and the lock FILE is deliberately never
//! unlinked (unlinking it lets two processes hold locks on two
//! different inodes of the same path).

const std = @import("std");
const c = @import("cbindings");
const manifest = @import("manifest.zig");
const atomicwrite = @import("../../util/atomicwrite.zig");
const pathz = @import("../../util/pathz.zig");

pub const Error = error{
    OutOfMemory,
    PathTooLong,
    LockFailed,
    WriteFailed,
};

const MAX_PATH = 4096;
/// A registry rewrite is a few kilobytes under a lock; a file bigger
/// than this is not one we wrote.
const MAX_REGISTRY = 4 * 1024 * 1024;

/// One persisted extension. Slices are borrowed in a `Change` and owned
/// by the `List` that parsed them.
pub const Entry = struct {
    id: []const u8,
    dir: []const u8,
    enabled: bool,
    owned: bool,
};

/// What a commit does to the persisted set, keyed by id — never by an
/// index into a caller's list, which describes a different array than
/// the one on disk.
pub const Change = union(enum) {
    /// Replace the entry with this id, or append it when absent.
    upsert: Entry,
    remove: []const u8,
    /// Rewrite the file with no change of our own (used by tests).
    none,
};

pub const List = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *List) void {
        for (self.items.items) |e| {
            self.gpa.free(@constCast(e.id));
            self.gpa.free(@constCast(e.dir));
        }
        self.items.deinit(self.gpa);
    }

    fn indexOf(self: *const List, id: []const u8) ?usize {
        for (self.items.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.id, id)) return i;
        }
        return null;
    }

    fn appendOwned(self: *List, e: Entry) Error!void {
        const id = self.gpa.dupe(u8, e.id) catch return error.OutOfMemory;
        errdefer self.gpa.free(id);
        const dir = self.gpa.dupe(u8, e.dir) catch return error.OutOfMemory;
        errdefer self.gpa.free(dir);
        self.items.append(self.gpa, .{
            .id = id,
            .dir = dir,
            .enabled = e.enabled,
            .owned = e.owned,
        }) catch return error.OutOfMemory;
    }

    fn removeAt(self: *List, i: usize) void {
        const e = self.items.orderedRemove(i);
        self.gpa.free(@constCast(e.id));
        self.gpa.free(@constCast(e.dir));
    }

    /// Apply one change in place.
    pub fn apply(self: *List, change: Change) Error!void {
        switch (change) {
            .none => {},
            .remove => |id| if (self.indexOf(id)) |i| self.removeAt(i),
            .upsert => |incoming| {
                if (self.indexOf(incoming.id)) |i| {
                    const dir = self.gpa.dupe(u8, incoming.dir) catch return error.OutOfMemory;
                    const slot = &self.items.items[i];
                    self.gpa.free(@constCast(slot.dir));
                    slot.dir = dir;
                    slot.enabled = incoming.enabled;
                    slot.owned = incoming.owned;
                    return;
                }
                try self.appendOwned(incoming);
            },
        }
    }
};

/// `<base>/registry.json`, owned by the caller.
pub fn filePath(gpa: std.mem.Allocator, base: []const u8) Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/registry.json", .{base}) catch error.OutOfMemory;
}

/// The registry-wide `flock`. Blocking on purpose: the critical section
/// is one small read-modify-write, and refusing an install because
/// another process is mid-rewrite would be a worse answer than waiting.
pub const Lock = struct {
    fd: c_int = -1,

    pub fn acquire(base: []const u8) Error!Lock {
        var path_buf: [MAX_PATH]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/.registry.lock", .{base}) catch
            return error.PathTooLong;
        const fd = c.open(path.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (fd < 0) return error.LockFailed;
        if (c.flock(fd, c.LOCK_EX) != 0) {
            _ = c.close(fd);
            return error.LockFailed;
        }
        return .{ .fd = fd };
    }

    /// Unlock and close. The lock FILE stays: unlinking it would let a
    /// later process lock a fresh inode at the same path.
    pub fn release(self: *Lock) void {
        if (self.fd < 0) return;
        _ = c.flock(self.fd, c.LOCK_UN);
        _ = c.close(self.fd);
        self.fd = -1;
    }
};

/// Parse the persisted array. Malformed bytes are an EMPTY registry,
/// never an error: this is on-disk data and a user with a corrupt file
/// still has to be able to install.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!List {
    var out = List{ .gpa = gpa };
    errdefer out.deinit();
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return out,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return out;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const id = strField(o, "id") orelse continue;
        if (!manifest.idValid(id) or out.indexOf(id) != null) continue;
        const dir = strField(o, "dir") orelse continue;
        try out.appendOwned(.{
            .id = id,
            .dir = dir,
            .enabled = boolField(o, "enabled"),
            .owned = boolField(o, "owned"),
        });
    }
    return out;
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolField(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

/// Read the registry as it is on disk. Callers that intend to write it
/// back MUST be holding the lock across this read.
pub fn read(gpa: std.mem.Allocator, base: []const u8) Error!List {
    const path = try filePath(gpa, base);
    defer gpa.free(path);
    var path_buf: [MAX_PATH]u8 = undefined;
    const path_z = pathz.pathZ(&path_buf, path) catch return error.PathTooLong;
    const f = c.fopen(path_z, "rb") orelse return .{ .gpa = gpa };
    defer _ = c.fclose(f);
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        if (acc.items.len + n > MAX_REGISTRY) return .{ .gpa = gpa };
        acc.appendSlice(gpa, chunk[0..n]) catch return error.OutOfMemory;
    }
    return parse(gpa, acc.items);
}

/// Serialize the set as the persisted JSON array.
pub fn serialize(gpa: std.mem.Allocator, entries: []const Entry) Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch return error.OutOfMemory;
    for (entries, 0..) |e, i| {
        if (i != 0) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll("{\"id\":") catch return error.OutOfMemory;
        std.json.Stringify.value(e.id, .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"dir\":") catch return error.OutOfMemory;
        std.json.Stringify.value(e.dir, .{}, w) catch return error.OutOfMemory;
        w.print(",\"enabled\":{s},\"owned\":{s}}}", .{
            if (e.enabled) "true" else "false",
            if (e.owned) "true" else "false",
        }) catch return error.OutOfMemory;
    }
    w.writeByte(']') catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

/// Read-modify-write the registry under the cross-process lock.
pub fn commit(gpa: std.mem.Allocator, base: []const u8, change: Change) Error!void {
    var hook = NoHook{};
    return commitWith(gpa, base, change, &hook);
}

/// A test seam only: `hook.afterRead()` runs INSIDE the critical
/// section, right after the read, which is where a second writer's
/// whole commit has to be able to interleave for the race to be
/// reproducible at all.
const NoHook = struct {
    fn afterRead(_: *NoHook) void {}
};

fn commitWith(gpa: std.mem.Allocator, base: []const u8, change: Change, hook: anytype) Error!void {
    pathz.makeDirs(base, 0o700) catch return error.WriteFailed;
    var lock = try Lock.acquire(base);
    defer lock.release();

    var list = try read(gpa, base);
    defer list.deinit();
    hook.afterRead();
    try list.apply(change);

    const bytes = try serialize(gpa, list.items.items);
    defer gpa.free(bytes);
    const path = try filePath(gpa, base);
    defer gpa.free(path);
    atomicwrite.writeFile(path, bytes, 0o600) catch return error.WriteFailed;
}

// ======================================================================
// Tests
// ======================================================================

const t = std.testing;

const TestDir = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn init() !TestDir {
        var self = TestDir{};
        var tmpl = "/tmp/sketerm-webext-registry-XXXXXX".*;
        const made = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
        const s = std.mem.span(@as([*:0]u8, @ptrCast(made)));
        @memcpy(self.buf[0..s.len], s);
        self.len = s.len;
        return self;
    }

    fn path(self: *const TestDir) []const u8 {
        return self.buf[0..self.len];
    }

    fn deinit(self: *TestDir) void {
        var buf: [MAX_PATH]u8 = undefined;
        const reg = std.fmt.bufPrintZ(&buf, "{s}/registry.json", .{self.path()}) catch return;
        _ = c.unlink(reg.ptr);
        var lbuf: [MAX_PATH]u8 = undefined;
        const lock = std.fmt.bufPrintZ(&lbuf, "{s}/.registry.lock", .{self.path()}) catch return;
        _ = c.unlink(lock.ptr);
        var dbuf: [MAX_PATH]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dbuf, "{s}", .{self.path()}) catch return;
        _ = c.rmdir(dir.ptr);
    }
};

fn entry(id: []const u8, dir: []const u8) Entry {
    return .{ .id = id, .dir = dir, .enabled = true, .owned = true };
}

test "registry: entries round-trip through serialize and parse" {
    const bytes = try serialize(t.allocator, &.{
        entry("a@sketerm.test", "/tmp/a"),
        .{ .id = "b@sketerm.test", .dir = "/tmp/b", .enabled = false, .owned = false },
    });
    defer t.allocator.free(bytes);
    var list = try parse(t.allocator, bytes);
    defer list.deinit();
    try t.expectEqual(@as(usize, 2), list.items.items.len);
    try t.expectEqualStrings("a@sketerm.test", list.items.items[0].id);
    try t.expect(list.items.items[0].enabled and list.items.items[0].owned);
    try t.expectEqualStrings("/tmp/b", list.items.items[1].dir);
    try t.expect(!list.items.items[1].enabled and !list.items.items[1].owned);
}

test "registry: an unreadable file is an empty registry, not an error" {
    var list = try parse(t.allocator, "{not json");
    defer list.deinit();
    try t.expectEqual(@as(usize, 0), list.items.items.len);
}

test "registry: an upsert replaces by id and a remove drops by id" {
    var dir = try TestDir.init();
    defer dir.deinit();
    try commit(t.allocator, dir.path(), .{ .upsert = entry("a@sketerm.test", "/tmp/a") });
    try commit(t.allocator, dir.path(), .{ .upsert = entry("b@sketerm.test", "/tmp/b") });
    try commit(t.allocator, dir.path(), .{ .upsert = .{
        .id = "a@sketerm.test",
        .dir = "/tmp/a2",
        .enabled = false,
        .owned = false,
    } });
    var list = try read(t.allocator, dir.path());
    defer list.deinit();
    try t.expectEqual(@as(usize, 2), list.items.items.len);
    try t.expectEqualStrings("/tmp/a2", list.items.items[0].dir);
    try t.expect(!list.items.items[0].enabled);

    try commit(t.allocator, dir.path(), .{ .remove = "a@sketerm.test" });
    var after = try read(t.allocator, dir.path());
    defer after.deinit();
    try t.expectEqual(@as(usize, 1), after.items.items.len);
    try t.expectEqualStrings("b@sketerm.test", after.items.items[0].id);
}

test "registry: a concurrent install of another extension is not lost" {
    // The failure this pins: both writers read the old array, both
    // rewrite the whole file, and the loser's extension vanishes from
    // the registry while its package tree stays on disk.
    //
    // `flock` is per open file description, so two threads each opening
    // the lock file genuinely contend, exactly as two processes do.
    var dir = try TestDir.init();
    defer dir.deinit();

    var race = Race{ .base = dir.path() };
    const thread = try std.Thread.spawn(.{}, Race.second, .{&race});
    var hook = RaceHook{ .race = &race };
    try commitWith(t.allocator, dir.path(), .{ .upsert = entry("first@sketerm.test", "/tmp/first") }, &hook);
    thread.join();
    try t.expect(!race.second_failed);

    var list = try read(t.allocator, dir.path());
    defer list.deinit();
    try t.expectEqual(@as(usize, 2), list.items.items.len);
    try t.expect(list.indexOf("first@sketerm.test") != null);
    try t.expect(list.indexOf("second@sketerm.test") != null);
}

const Race = struct {
    base: []const u8,
    second_done: std.atomic.Value(bool) = .init(false),
    second_failed: bool = false,

    fn second(self: *Race) void {
        commit(t.allocator, self.base, .{ .upsert = entry("second@sketerm.test", "/tmp/second") }) catch {
            self.second_failed = true;
        };
        self.second_done.store(true, .release);
    }
};

/// Runs inside the first writer's critical section: gives the second
/// writer every chance to complete a WHOLE commit before the first one
/// writes. Bounded, because while the lock works the second writer is
/// blocked and can never finish — so this must time out, not deadlock.
const RaceHook = struct {
    race: *Race,

    fn afterRead(self: *RaceHook) void {
        var waited: usize = 0;
        while (!self.race.second_done.load(.acquire) and waited < 40) : (waited += 1) {
            _ = c.usleep(10_000);
        }
    }
};
