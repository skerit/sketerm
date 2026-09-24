//! Userscript `GM_setValue` storage: one JSON object per script under
//! `$XDG_DATA_HOME/sketerm/userscripts/<key>.json`, keyed by a hash of
//! the script's `@namespace` + `@name` so an edited script keeps its
//! values (Violentmonkey's rule).
//!
//! The helper owns it (it is where the calls arrive), and every browser
//! route runs its own helper against the SAME files, so a write is a
//! MERGE exactly like `storage.local`'s (`webext/storage.zig`): the
//! store journals the keys this process touched and a flush rebases
//! them onto the file under a per-script `flock`. Writes are coalesced
//! (`flush` from the helper's pump), and teardown flushes.
//!
//! No CEF, no GTK: libc for the file IO and lock.

const std = @import("std");
const c = @import("cbindings");
const storage = @import("webext/storage.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const pathz = @import("../util/pathz.zig");
const clock = @import("../util/clock.zig");

const coalesce_ms: i64 = 300;
const max_file: usize = 16 * 1024 * 1024;

/// The storage key for a script: 16 hex digits of its identity.
pub fn keyFor(namespace: []const u8, name: []const u8, out: *[16]u8) []const u8 {
    var h = std.hash.Fnv1a_64.init();
    h.update(namespace);
    h.update("\x00");
    h.update(name);
    out.* = std.fmt.bytesToHex(std.mem.toBytes(std.mem.nativeToBig(u64, h.final())), .lower);
    return out;
}

const Entry = struct {
    key: [16]u8,
    store: storage.Store,
    ino: u64 = 0,
    size: i64 = 0,
    mtime_ns: i128 = 0,
    dirty: bool = false,
    due_ms: i64 = 0,
};

pub const Values = struct {
    gpa: std.mem.Allocator,
    /// Resolved on first use, so a Host that never runs a userscript
    /// allocates nothing here.
    dir: []u8 = @constCast(""),
    dir_resolved: bool = false,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) Values {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Values) void {
        self.flush(std.math.maxInt(i64));
        for (self.entries.items) |*e| e.store.deinit();
        self.entries.deinit(self.gpa);
        if (self.dir.len != 0) self.gpa.free(self.dir);
    }

    fn resolve(self: *Values) void {
        if (self.dir_resolved) return;
        self.dir_resolved = true;
        self.dir = resolveDir(self.gpa);
    }

    fn path(self: *Values, key: []const u8, suffix: []const u8, buf: []u8) ?[:0]const u8 {
        self.resolve();
        if (self.dir.len == 0) return null;
        return std.fmt.bufPrintZ(buf, "{s}/{s}{s}", .{ self.dir, key, suffix }) catch null;
    }

    fn stamp(self: *Values, e: *Entry) void {
        var buf: [4200]u8 = undefined;
        const p = self.path(&e.key, ".json", &buf) orelse return;
        var st: c.struct_stat = undefined;
        if (c.stat(p.ptr, &st) != 0) {
            e.ino = 0;
            e.size = 0;
            e.mtime_ns = 0;
            return;
        }
        const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
        e.ino = @intCast(st.st_ino);
        e.size = @intCast(st.st_size);
        e.mtime_ns = @as(i128, ts.tv_sec) * std.time.ns_per_s + ts.tv_nsec;
    }

    fn readFile(self: *Values, key: []const u8) ?[]u8 {
        var buf: [4200]u8 = undefined;
        const p = self.path(key, ".json", &buf) orelse return null;
        const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC, @as(c_uint, 0));
        if (fd < 0) return null;
        defer _ = c.close(fd);
        var out: std.ArrayList(u8) = .empty;
        var chunk: [65536]u8 = undefined;
        while (true) {
            const n = c.read(fd, &chunk, chunk.len);
            if (n <= 0) break;
            out.appendSlice(self.gpa, chunk[0..@intCast(n)]) catch {
                out.deinit(self.gpa);
                return null;
            };
            if (out.items.len > max_file) break;
        }
        return out.toOwnedSlice(self.gpa) catch null;
    }

    /// The live store for `key`, reloaded (or merged) when another
    /// helper instance rewrote the file.
    pub fn get(self: *Values, key: []const u8) ?*storage.Store {
        if (key.len != 16) return null;
        for (self.entries.items) |*e| {
            if (!std.mem.eql(u8, &e.key, key)) continue;
            var probe = Entry{ .key = e.key, .store = undefined };
            self.stamp(&probe);
            if (probe.ino != e.ino or probe.size != e.size or probe.mtime_ns != e.mtime_ns) {
                const bytes = self.readFile(key);
                defer if (bytes) |b| self.gpa.free(b);
                if (e.store.hasJournal()) {
                    e.store.rebase(self.gpa, bytes orelse "", true) catch {};
                } else {
                    e.store.deinit();
                    e.store = storage.Store.load(self.gpa, bytes orelse "");
                }
                e.ino = probe.ino;
                e.size = probe.size;
                e.mtime_ns = probe.mtime_ns;
            }
            return &e.store;
        }
        const bytes = self.readFile(key);
        defer if (bytes) |b| self.gpa.free(b);
        var e = Entry{ .key = undefined, .store = storage.Store.load(self.gpa, bytes orelse "") };
        @memcpy(&e.key, key[0..16]);
        self.stamp(&e);
        self.entries.append(self.gpa, e) catch {
            e.store.deinit();
            return null;
        };
        return &self.entries.items[self.entries.items.len - 1].store;
    }

    /// Record that `key`'s store changed; the file follows on `flush`.
    pub fn touch(self: *Values, key: []const u8) void {
        for (self.entries.items) |*e| {
            if (!std.mem.eql(u8, &e.key, key)) continue;
            if (!e.dirty) {
                e.dirty = true;
                e.due_ms = clock.nowMs() +| coalesce_ms;
            }
            return;
        }
    }

    /// Write every store whose window passed (`maxInt` = all, now).
    pub fn flush(self: *Values, now_ms: i64) void {
        for (self.entries.items) |*e| {
            if (!e.dirty or now_ms < e.due_ms) continue;
            self.persist(e) catch {
                e.due_ms = now_ms +| coalesce_ms;
                continue;
            };
            e.dirty = false;
        }
    }

    fn persist(self: *Values, e: *Entry) !void {
        self.resolve();
        if (self.dir.len == 0) return error.NoDataDir;
        try pathz.makeDirs(self.dir, 0o700);
        var lbuf: [4200]u8 = undefined;
        const lp = self.path(&e.key, ".lock", &lbuf) orelse return error.PathTooLong;
        const fd = c.open(lp.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (fd < 0) return error.LockFailed;
        defer _ = c.close(fd);
        if (c.flock(fd, c.LOCK_EX) != 0) return error.LockFailed;
        defer _ = c.flock(fd, c.LOCK_UN);
        const disk = self.readFile(&e.key);
        defer if (disk) |b| self.gpa.free(b);
        try e.store.rebase(self.gpa, disk orelse "", true);
        const bytes = try e.store.serialize(self.gpa);
        defer self.gpa.free(bytes);
        var pbuf: [4200]u8 = undefined;
        const p = self.path(&e.key, ".json", &pbuf) orelse return error.PathTooLong;
        try atomicwrite.writeFileExact(p, bytes, 0o600);
        e.store.settle();
        self.stamp(e);
    }
};

fn resolveDir(gpa: std.mem.Allocator) []u8 {
    if (c.getenv("XDG_DATA_HOME")) |xdg| {
        const base = std.mem.span(xdg);
        if (base.len != 0) return std.fmt.allocPrint(gpa, "{s}/sketerm/userscripts", .{base}) catch @constCast("");
    }
    if (c.getenv("HOME")) |home| {
        return std.fmt.allocPrint(gpa, "{s}/.local/share/sketerm/userscripts", .{std.mem.span(home)}) catch @constCast("");
    }
    return @constCast("");
}
