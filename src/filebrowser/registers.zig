//! Named persistent selection registers: sets of (host, path) marks
//! that survive changing directory, closing the tab and restarting
//! the GUI.
//!
//! One register is the whole model behind BOTH the vim-style marks
//! (nnn/lf/vifm) and the collection shelf: the shelf is simply the
//! register named `COLLECTION`, so there is one store, one file and
//! one set of verbs rather than two parallel mechanisms.
//!
//! Client-side ONLY, like viewmem: nothing is ever written into the
//! tree being browsed. A missing, truncated, corrupt or
//! future-versioned file loads as an EMPTY store rather than failing
//! the browser, and both the register count and each register's size
//! are bounded so a lifetime of marking cannot grow the file without
//! limit.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const model = @import("model.zig");
const pathz = @import("../util/pathz.zig");
const profile = @import("../util/profile.zig");

/// Named registers kept at once. A new register past this is REFUSED
/// (never silently evicted): a curated mark set is user work, so
/// losing one to an unrelated new name would be a data loss.
pub const MAX_REGISTERS = 32;

/// Entries kept in one register. Adding past this is refused too.
pub const MAX_ENTRIES = 4096;

/// Bumped only for a format change older records cannot survive
/// (a mismatch loads as empty, never as a parse error).
pub const VERSION: u32 = 1;

/// Read cap for the on-disk file; a larger file is treated as corrupt.
pub const FILE_CAP = 2 * 1024 * 1024;

/// The register the "Add to Collection" shelf marks into.
pub const COLLECTION = "collection";

/// Longest register name accepted (a name is a menu label, not a
/// document).
pub const MAX_NAME = 48;

/// One marked file. `dir` rides along because a register is acted on
/// without its listing in view -- a recursive delete or copy has to
/// know before it can pick the right verb.
pub const Entry = struct {
    /// Empty = the local daemon (same convention as model.FileRef).
    host: []const u8 = "",
    path: []const u8 = "",
    /// Browsable as a directory — a real directory OR a symlink to one.
    /// Chooses the delete verb (`delete_tree` vs `delete`).
    dir: bool = false,
    /// A REAL directory, so an operation on it carries everything
    /// beneath it. A symlinked directory is `dir` but not `real_dir`:
    /// moving the link leaves the target's children where they are.
    real_dir: bool = false,

    pub fn ref(self: Entry) model.FileRef {
        return .{ .host = self.host, .path = self.path };
    }
};

pub const Register = struct {
    name: []const u8 = "",
    entries: []const Entry = &.{},
    /// Use counter; only meaningful for a stable listing order.
    seq: u64 = 0,
};

pub const File = struct {
    version: u32 = VERSION,
    next_seq: u64 = 1,
    registers: []const Register = &.{},
};

/// What `add`/`toggle` did, so the caller can say so.
pub const Change = enum { added, removed, already, full };

/// A register whose strings this store owns.
const Owned = struct {
    name: []u8,
    entries: std.ArrayList(Entry) = .empty,
    seq: u64 = 0,
};

/// Split a host-qualified spec ("host:/path", "local:/path", "/path")
/// into a register entry. Bare paths are LOCAL: a register entry that
/// inherited "the current host" would mean something different after
/// the tab moved, and the model rule is that nothing holds a bare path.
pub fn entryFromSpec(spec: []const u8, dir: bool) Entry {
    const parsed = model.parseSpec(spec, "");
    return .{ .host = parsed.ref.host, .path = parsed.ref.path, .dir = dir };
}

/// Whether `name` is usable as a register name (also what a
/// hand-edited file is filtered by on load).
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME) return false;
    for (name) |ch| {
        if (ch < 0x21 or ch > 0x7e) return false;
    }
    return true;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    regs: std.ArrayList(Owned) = .empty,
    next_seq: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.regs.items) |*r| self.freeReg(r);
        self.regs.deinit(self.allocator);
        self.regs = .empty;
    }

    fn freeReg(self: *Store, r: *Owned) void {
        for (r.entries.items) |e| {
            self.allocator.free(e.host);
            self.allocator.free(e.path);
        }
        r.entries.deinit(self.allocator);
        self.allocator.free(r.name);
    }

    fn takeSeq(self: *Store) u64 {
        const s = self.next_seq;
        self.next_seq +%= 1;
        if (self.next_seq == 0) self.next_seq = 1;
        return s;
    }

    fn indexOf(self: *const Store, name: []const u8) ?usize {
        for (self.regs.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.name, name)) return i;
        }
        return null;
    }

    /// Registers in creation order; index with `nameAt`.
    pub fn count(self: *const Store) usize {
        return self.regs.items.len;
    }

    pub fn nameAt(self: *const Store, i: usize) []const u8 {
        return self.regs.items[i].name;
    }

    pub fn entriesOf(self: *const Store, name: []const u8) []const Entry {
        const i = self.indexOf(name) orelse return &.{};
        return self.regs.items[i].entries.items;
    }

    pub fn sizeOf(self: *const Store, name: []const u8) usize {
        return self.entriesOf(name).len;
    }

    pub fn contains(self: *const Store, name: []const u8, host: []const u8, path: []const u8) bool {
        for (self.entriesOf(name)) |e| {
            if (std.mem.eql(u8, e.host, host) and std.mem.eql(u8, e.path, path)) return true;
        }
        return false;
    }

    /// Total marks across every register (what the UI reports).
    pub fn totalEntries(self: *const Store) usize {
        var n: usize = 0;
        for (self.regs.items) |r| n += r.entries.items.len;
        return n;
    }

    fn ensureReg(self: *Store, name: []const u8) ?*Owned {
        if (self.indexOf(name)) |i| return &self.regs.items[i];
        if (!validName(name)) return null;
        if (self.regs.items.len >= MAX_REGISTERS) return null;
        const owned_name = self.allocator.dupe(u8, name) catch return null;
        self.regs.append(self.allocator, .{ .name = owned_name, .seq = self.takeSeq() }) catch {
            self.allocator.free(owned_name);
            return null;
        };
        return &self.regs.items[self.regs.items.len - 1];
    }

    /// True when `path` names something strictly beneath `dir`, on a
    /// path-component boundary so `/dir` never covers `/directory`.
    fn beneath(path: []const u8, dir: []const u8) bool {
        if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir)) return false;
        return (dir.len == 1 and dir[0] == '/') or path[dir.len] == '/';
    }

    /// Mark (host, path) in `name`, creating the register if needed.
    ///
    /// A register is kept in OPERATION-ROOT form: a real directory and
    /// something beneath it can never both be members, in either order.
    /// Without that, `deleteRegister` deletes the parent tree and then
    /// fails on the child with NOENT, and `copyRegisterHere` copies the
    /// child twice. The rule lives here because marks arrive one at a
    /// time from several places, so collapsing at any single call site
    /// would only hold for that call.
    pub fn add(self: *Store, name: []const u8, entry: Entry) Change {
        if (entry.path.len == 0) return .full;
        if (self.contains(name, entry.host, entry.path)) return .already;
        const reg = self.ensureReg(name) orelse return .full;
        // Already carried by a marked real directory: nothing to add.
        for (reg.entries.items) |e| {
            if (!e.real_dir or !std.mem.eql(u8, e.host, entry.host)) continue;
            if (beneath(entry.path, e.path)) return .already;
        }
        if (reg.entries.items.len >= MAX_ENTRIES) return .full;
        const host = self.allocator.dupe(u8, entry.host) catch return .full;
        const path = self.allocator.dupe(u8, entry.path) catch {
            self.allocator.free(host);
            return .full;
        };
        reg.entries.append(self.allocator, .{
            .host = host,
            .path = path,
            .dir = entry.dir,
            .real_dir = entry.real_dir,
        }) catch {
            self.allocator.free(host);
            self.allocator.free(path);
            return .full;
        };
        // A real directory subsumes members marked earlier.
        if (entry.real_dir) {
            var j: usize = 0;
            while (j < reg.entries.items.len) {
                const e = reg.entries.items[j];
                if (std.mem.eql(u8, e.host, entry.host) and beneath(e.path, entry.path)) {
                    self.allocator.free(e.host);
                    self.allocator.free(e.path);
                    _ = reg.entries.orderedRemove(j);
                    continue;
                }
                j += 1;
            }
        }
        return .added;
    }

    /// Unmark (host, path). A register left empty is dropped, so the
    /// menu never lists a register with nothing in it.
    pub fn remove(self: *Store, name: []const u8, host: []const u8, path: []const u8) bool {
        const i = self.indexOf(name) orelse return false;
        const reg = &self.regs.items[i];
        var hit = false;
        var j: usize = 0;
        while (j < reg.entries.items.len) {
            const e = reg.entries.items[j];
            if (std.mem.eql(u8, e.host, host) and std.mem.eql(u8, e.path, path)) {
                self.allocator.free(e.host);
                self.allocator.free(e.path);
                _ = reg.entries.orderedRemove(j);
                hit = true;
            } else j += 1;
        }
        if (hit and reg.entries.items.len == 0) _ = self.drop(name);
        return hit;
    }

    pub fn toggle(self: *Store, name: []const u8, entry: Entry) Change {
        if (self.contains(name, entry.host, entry.path)) {
            _ = self.remove(name, entry.host, entry.path);
            return .removed;
        }
        return self.add(name, entry);
    }

    /// Forget the whole register. @return true when it existed.
    pub fn drop(self: *Store, name: []const u8) bool {
        const i = self.indexOf(name) orelse return false;
        var reg = self.regs.orderedRemove(i);
        self.freeReg(&reg);
        return true;
    }

    /// Parse a stored file. Anything unreadable -- truncated JSON, a
    /// version this build does not know, a name a hand edit invented
    /// -- yields an empty store or a filtered one, never an error.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Store {
        var store = Store.init(allocator);
        const parsed = std.json.parseFromSlice(File, allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return store;
        defer parsed.deinit();
        if (parsed.value.version != VERSION) return store;
        store.next_seq = if (parsed.value.next_seq == 0) 1 else parsed.value.next_seq;
        for (parsed.value.registers) |r| {
            if (!validName(r.name)) continue;
            if (r.entries.len == 0) continue;
            for (r.entries) |e| {
                if (e.path.len == 0) continue;
                _ = store.add(r.name, e);
            }
            if (store.indexOf(r.name)) |i| {
                if (r.seq != 0) store.regs.items[i].seq = r.seq;
                if (r.seq >= store.next_seq) store.next_seq = r.seq + 1;
            }
        }
        return store;
    }

    pub fn encode(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        const view = try allocator.alloc(Register, self.regs.items.len);
        defer allocator.free(view);
        for (self.regs.items, 0..) |r, i| {
            view[i] = .{ .name = r.name, .entries = r.entries.items, .seq = r.seq };
        }
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(File{
            .next_seq = self.next_seq,
            .registers = view,
        }, .{}, &out.writer);
        return out.toOwnedSlice();
    }

    pub fn load(allocator: std.mem.Allocator) Store {
        const path = filePath(allocator) catch return Store.init(allocator);
        defer allocator.free(path);
        return loadFromPath(allocator, path);
    }

    fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) Store {
        var pbuf: [4096]u8 = undefined;
        const fp = c.fopen(pathz.pathZ(&pbuf, path) catch return Store.init(allocator), "rb") orelse
            return Store.init(allocator);
        defer _ = c.fclose(fp);
        const bytes = allocator.alloc(u8, FILE_CAP) catch return Store.init(allocator);
        defer allocator.free(bytes);
        const n = c.fread(bytes.ptr, 1, bytes.len, fp);
        if (n == 0) return Store.init(allocator);
        return decode(allocator, bytes[0..n]);
    }

    pub fn save(self: *const Store) !void {
        const path = try filePath(self.allocator);
        defer self.allocator.free(path);
        try self.saveToPath(path);
    }

    /// The app owns this file, so its mode is FORCED: a copy an older
    /// build created 0644 must be narrowed, not preserved forever.
    fn saveToPath(self: *const Store, path: []const u8) !void {
        const json = try self.encode(self.allocator);
        defer self.allocator.free(json);
        try pathz.makeParentDirs(path);
        try atomicwrite.writeFileExact(path, json, 0o600);
    }
};

pub fn filePath(allocator: std.mem.Allocator) ![]u8 {
    if (profile.getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/registers.json", .{xs});
    }
    if (profile.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/registers.json", .{home});
    }
    return std.fmt.allocPrint(allocator, "/tmp/sketerm-registers.json", .{});
}

test "a register keeps operation-root form in either marking order" {
    const t = std.testing;
    var store = Store.init(t.allocator);
    defer store.deinit();

    // Child first, then its real directory: the parent evicts it.
    try t.expectEqual(Change.added, store.add("r", .{ .path = "/srv/dir/child.txt" }));
    try t.expectEqual(Change.added, store.add("r", .{ .path = "/srv/dir", .dir = true, .real_dir = true }));
    try t.expectEqual(@as(usize, 1), store.entriesOf("r").len);
    try t.expectEqualStrings("/srv/dir", store.entriesOf("r")[0].path);

    // Directory first, then a child: the child is already carried.
    try t.expectEqual(Change.already, store.add("r", .{ .path = "/srv/dir/other.txt" }));
    try t.expectEqual(@as(usize, 1), store.entriesOf("r").len);

    // A byte prefix is not a path prefix.
    try t.expectEqual(Change.added, store.add("r", .{ .path = "/srv/dir2" }));
    try t.expectEqual(@as(usize, 2), store.entriesOf("r").len);

    // A different host is a different tree.
    try t.expectEqual(Change.added, store.add("r", .{ .host = "box", .path = "/srv/dir/child.txt" }));
    try t.expectEqual(@as(usize, 3), store.entriesOf("r").len);

    // A SYMLINKED directory carries nothing: moving the link leaves the
    // target's children where they are, so they stay independent marks.
    try t.expectEqual(Change.added, store.add("r", .{ .path = "/srv/link", .dir = true, .real_dir = false }));
    try t.expectEqual(Change.added, store.add("r", .{ .path = "/srv/link/child.txt" }));
    try t.expectEqual(@as(usize, 5), store.entriesOf("r").len);
}

test "a register spans hosts and survives an encode/decode round trip" {
    const t = std.testing;
    var store = Store.init(t.allocator);
    defer store.deinit();
    try t.expectEqual(Change.added, store.add("work", .{ .path = "/home/me/a.txt" }));
    try t.expectEqual(Change.added, store.add("work", .{ .host = "box", .path = "/srv/b", .dir = true }));
    try t.expectEqual(Change.already, store.add("work", .{ .path = "/home/me/a.txt" }));
    try t.expectEqual(Change.added, store.add(COLLECTION, .{ .path = "/tmp/shelf" }));

    const json = try store.encode(t.allocator);
    defer t.allocator.free(json);
    var back = Store.decode(t.allocator, json);
    defer back.deinit();
    try t.expectEqual(@as(usize, 2), back.count());
    try t.expectEqual(@as(usize, 2), back.sizeOf("work"));
    // The same path on two hosts is two distinct marks.
    try t.expect(back.contains("work", "box", "/srv/b"));
    try t.expect(!back.contains("work", "", "/srv/b"));
    try t.expect(back.entriesOf("work")[1].dir);
    try t.expectEqual(@as(usize, 3), back.totalEntries());
}

test "register save replaces and loads the complete store" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-registers-save-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/registers.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    var store = Store.init(t.allocator);
    defer store.deinit();
    try t.expectEqual(Change.added, store.add("work", .{ .path = "/one" }));
    try store.saveToPath(path);
    try t.expectEqual(Change.added, store.add("work", .{ .host = "box", .path = "/two" }));
    try store.saveToPath(path);

    var loaded = Store.loadFromPath(t.allocator, path);
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 2), loaded.sizeOf("work"));
    try t.expect(loaded.contains("work", "", "/one"));
    try t.expect(loaded.contains("work", "box", "/two"));
}

test "toggling unmarks, and an emptied register is forgotten" {
    const t = std.testing;
    var store = Store.init(t.allocator);
    defer store.deinit();
    try t.expectEqual(Change.added, store.toggle("m", .{ .path = "/a" }));
    try t.expectEqual(Change.added, store.toggle("m", .{ .path = "/b" }));
    try t.expectEqual(Change.removed, store.toggle("m", .{ .path = "/a" }));
    try t.expectEqual(@as(usize, 1), store.sizeOf("m"));
    try t.expectEqual(Change.removed, store.toggle("m", .{ .path = "/b" }));
    // The last unmark takes the register with it.
    try t.expectEqual(@as(usize, 0), store.count());
    try t.expect(!store.drop("m"));
}

test "the store bounds both the register count and each register" {
    const t = std.testing;
    var store = Store.init(t.allocator);
    defer store.deinit();
    var buf: [32]u8 = undefined;
    for (0..MAX_REGISTERS) |i| {
        const name = try std.fmt.bufPrint(&buf, "r{d}", .{i});
        try t.expectEqual(Change.added, store.add(name, .{ .path = "/x" }));
    }
    try t.expectEqual(@as(usize, MAX_REGISTERS), store.count());
    // A new NAME is refused rather than evicting curated marks.
    try t.expectEqual(Change.full, store.add("one-too-many", .{ .path = "/x" }));
    try t.expect(store.contains("r0", "", "/x"));
    // An existing register still accepts marks up to its own bound.
    var pbuf: [32]u8 = undefined;
    for (1..MAX_ENTRIES) |i| {
        const p = try std.fmt.bufPrint(&pbuf, "/x/{d}", .{i});
        try t.expectEqual(Change.added, store.add("r0", .{ .path = p }));
    }
    try t.expectEqual(@as(usize, MAX_ENTRIES), store.sizeOf("r0"));
    try t.expectEqual(Change.full, store.add("r0", .{ .path = "/x/overflow" }));
    // Bad names never make it in.
    try t.expectEqual(Change.full, store.add("", .{ .path = "/x" }));
    try t.expectEqual(Change.full, store.add("has space", .{ .path = "/x" }));
}

test "a corrupt, foreign or hand-edited register file loads safely" {
    const t = std.testing;
    var truncated = Store.decode(t.allocator, "{\"version\":1,\"registers\":[{\"name\":\"a\"");
    defer truncated.deinit();
    try t.expectEqual(@as(usize, 0), truncated.count());

    var garbage = Store.decode(t.allocator, "not json at all");
    defer garbage.deinit();
    try t.expectEqual(@as(usize, 0), garbage.count());

    var empty = Store.decode(t.allocator, "");
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.count());

    var future = Store.decode(t.allocator,
        \\{"version":99,"registers":[{"name":"a","entries":[{"path":"/a"}]}]}
    );
    defer future.deinit();
    try t.expectEqual(@as(usize, 0), future.count());

    // Hand-edited junk is filtered per record, not fatal: the bad
    // name and the empty path drop out, the good register survives.
    var edited = Store.decode(t.allocator,
        \\{"version":1,"registers":[
        \\{"name":"bad name","entries":[{"path":"/x"}]},
        \\{"name":"ok","entries":[{"path":""},{"host":"box","path":"/y","dir":true}]},
        \\{"name":"empty","entries":[]}]}
    );
    defer edited.deinit();
    try t.expectEqual(@as(usize, 1), edited.count());
    try t.expectEqual(@as(usize, 1), edited.sizeOf("ok"));
    try t.expect(edited.contains("ok", "box", "/y"));
}

test "specs become host-qualified entries, and a bare path is local" {
    const t = std.testing;
    const local = entryFromSpec("/home/me/x", false);
    try t.expectEqualStrings("", local.host);
    try t.expectEqualStrings("/home/me/x", local.path);
    const remote = entryFromSpec("user@box:/srv/y", true);
    try t.expectEqualStrings("user@box", remote.host);
    try t.expectEqualStrings("/srv/y", remote.path);
    try t.expect(remote.dir);
    // "local:" is an explicit way to say the same thing.
    try t.expectEqualStrings("", entryFromSpec("local:/tmp", false).host);
}
