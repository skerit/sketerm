//! Per-folder view memory: (host, path) -> the view settings that
//! folder was last browsed with.
//!
//! Client-side ONLY. sketerm never writes state into the tree it is
//! browsing (no .DS_Store analog), so this lives in one JSON file
//! under the state dir. The store is bounded and evicts the least
//! recently used folder, so a lifetime of browsing cannot grow it
//! without limit; a missing, truncated, corrupt or future-versioned
//! file loads as an EMPTY store rather than failing the browser.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const model = @import("model.zig");
const pathz = @import("../util/pathz.zig");
const profile = @import("../util/profile.zig");

/// Remembered folders kept; the lowest `seq` is evicted first.
pub const MAX_FOLDERS = 256;

/// Bumped only for a format change that older records cannot survive
/// (a mismatch loads as empty, never as a parse error).
pub const VERSION: u32 = 1;

/// Read cap for the on-disk file; a larger file is treated as corrupt.
pub const FILE_CAP = 512 * 1024;

pub const Record = struct {
    /// Empty = the local daemon (same convention as FileRef).
    host: []const u8 = "",
    path: []const u8 = "",
    view: model.ViewMode = .details,
    sort: model.SortKey = .name,
    descending: bool = false,
    dirs_first: bool = true,
    grouped: bool = false,
    /// Index into the renderer's zoom steps.
    zoom: u8 = 1,
    /// Empty = the built-in default column set.
    columns: []const model.Column = &.{},
    /// Dragged column widths, positional against `columns`; 0 (or a
    /// short/absent list, e.g. a pre-resize file) = default width.
    col_widths: []const i32 = &.{},
    /// Dragged Name-column width; 0 (incl. pre-name-resize files) =
    /// auto, the name takes the leftover width.
    name_width: i32 = 0,
    /// Use counter, assigned on every write and read. Deterministic
    /// LRU: eviction always drops the smallest one.
    seq: u64 = 0,
};

pub const File = struct {
    version: u32 = VERSION,
    next_seq: u64 = 1,
    folders: []const Record = &.{},
};

/// The owned, bounded set of remembered folders.
pub const Store = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    next_seq: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.records.items) |r| self.freeRecord(r);
        self.records.deinit(self.allocator);
        self.records = .empty;
    }

    fn freeRecord(self: *Store, r: Record) void {
        self.allocator.free(r.host);
        self.allocator.free(r.path);
        if (r.columns.len > 0) self.allocator.free(r.columns);
        if (r.col_widths.len > 0) self.allocator.free(r.col_widths);
    }

    fn indexOf(self: *Store, host: []const u8, path: []const u8) ?usize {
        for (self.records.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.host, host) and std.mem.eql(u8, r.path, path)) return i;
        }
        return null;
    }

    /// The folder's record, marked as freshly used (so eviction keeps
    /// the folders actually being browsed).
    pub fn use(self: *Store, host: []const u8, path: []const u8) ?Record {
        const i = self.indexOf(host, path) orelse return null;
        self.records.items[i].seq = self.takeSeq();
        return self.records.items[i];
    }

    /// The folder's record without touching its use counter.
    pub fn peek(self: *Store, host: []const u8, path: []const u8) ?Record {
        const i = self.indexOf(host, path) orelse return null;
        return self.records.items[i];
    }

    fn takeSeq(self: *Store) u64 {
        const s = self.next_seq;
        self.next_seq +%= 1;
        if (self.next_seq == 0) self.next_seq = 1;
        return s;
    }

    /// Insert or replace the record for (host, path). Strings are
    /// copied; the caller keeps its own.
    pub fn remember(self: *Store, rec: Record) void {
        const host = self.allocator.dupe(u8, rec.host) catch return;
        const path = self.allocator.dupe(u8, rec.path) catch {
            self.allocator.free(host);
            return;
        };
        var columns: []model.Column = &.{};
        if (rec.columns.len > 0) {
            columns = self.allocator.dupe(model.Column, rec.columns) catch {
                self.allocator.free(host);
                self.allocator.free(path);
                return;
            };
        }
        var col_widths: []i32 = &.{};
        if (rec.col_widths.len > 0) {
            col_widths = self.allocator.dupe(i32, rec.col_widths) catch {
                self.allocator.free(host);
                self.allocator.free(path);
                if (columns.len > 0) self.allocator.free(columns);
                return;
            };
        }
        var owned = rec;
        owned.host = host;
        owned.path = path;
        owned.columns = columns;
        owned.col_widths = col_widths;
        owned.seq = self.takeSeq();
        if (self.indexOf(rec.host, rec.path)) |i| {
            self.freeRecord(self.records.items[i]);
            self.records.items[i] = owned;
            return;
        }
        self.records.append(self.allocator, owned) catch {
            self.freeRecord(owned);
            return;
        };
        self.evict();
    }

    /// Drop the least recently used records until the bound holds.
    fn evict(self: *Store) void {
        while (self.records.items.len > MAX_FOLDERS) {
            var oldest: usize = 0;
            for (self.records.items, 0..) |r, i| {
                if (r.seq < self.records.items[oldest].seq) oldest = i;
            }
            self.freeRecord(self.records.orderedRemove(oldest));
        }
    }

    /// @return true when a record was actually forgotten.
    pub fn forget(self: *Store, host: []const u8, path: []const u8) bool {
        const i = self.indexOf(host, path) orelse return false;
        self.freeRecord(self.records.orderedRemove(i));
        return true;
    }

    pub fn forgetAll(self: *Store) void {
        for (self.records.items) |r| self.freeRecord(r);
        self.records.clearRetainingCapacity();
    }

    pub fn count(self: *const Store) usize {
        return self.records.items.len;
    }

    /// Parse a stored file. Anything unreadable -- truncated JSON, a
    /// version this build does not know, a file from a future format
    /// -- yields an empty store, never an error.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Store {
        var store = Store.init(allocator);
        const parsed = std.json.parseFromSlice(File, allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return store;
        defer parsed.deinit();
        if (parsed.value.version != VERSION) return store;
        store.next_seq = if (parsed.value.next_seq == 0) 1 else parsed.value.next_seq;
        for (parsed.value.folders) |r| {
            if (r.path.len == 0) continue;
            const host = allocator.dupe(u8, r.host) catch continue;
            const path = allocator.dupe(u8, r.path) catch {
                allocator.free(host);
                continue;
            };
            var columns: []model.Column = &.{};
            if (r.columns.len > 0) {
                columns = allocator.dupe(model.Column, r.columns) catch {
                    allocator.free(host);
                    allocator.free(path);
                    continue;
                };
            }
            var col_widths: []i32 = &.{};
            if (r.col_widths.len > 0) {
                col_widths = allocator.dupe(i32, r.col_widths) catch {
                    allocator.free(host);
                    allocator.free(path);
                    if (columns.len > 0) allocator.free(columns);
                    continue;
                };
            }
            var owned = r;
            owned.host = host;
            owned.path = path;
            owned.columns = columns;
            owned.col_widths = col_widths;
            if (owned.seq >= store.next_seq) store.next_seq = owned.seq + 1;
            store.records.append(allocator, owned) catch {
                store.freeRecord(owned);
                continue;
            };
        }
        // A hand-edited or older-bound file can carry more folders
        // than this build keeps.
        store.evict();
        return store;
    }

    pub fn encode(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(File{
            .next_seq = self.next_seq,
            .folders = self.records.items,
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
        return std.fmt.allocPrint(allocator, "{s}/sketerm/viewmem.json", .{xs});
    }
    if (profile.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/viewmem.json", .{home});
    }
    return std.fmt.allocPrint(allocator, "/tmp/sketerm-viewmem.json", .{});
}

test "a folder's settings survive an encode/decode round trip" {
    const t = std.testing;
    var store = Store.init(t.allocator);
    defer store.deinit();
    const cols = [_]model.Column{ .kind, .size };
    const widths = [_]i32{ 0, 130 };
    store.remember(.{
        .host = "box",
        .path = "/srv/data",
        .view = .icons,
        .sort = .mtime,
        .descending = true,
        .dirs_first = false,
        .grouped = true,
        .zoom = 3,
        .columns = &cols,
        .col_widths = &widths,
    });
    store.remember(.{ .path = "/home/me" });
    const json = try store.encode(t.allocator);
    defer t.allocator.free(json);

    var back = Store.decode(t.allocator, json);
    defer back.deinit();
    try t.expectEqual(@as(usize, 2), back.count());
    const rec = back.peek("box", "/srv/data").?;
    try t.expectEqual(model.ViewMode.icons, rec.view);
    try t.expectEqual(model.SortKey.mtime, rec.sort);
    try t.expect(rec.descending);
    try t.expect(!rec.dirs_first);
    try t.expect(rec.grouped);
    try t.expectEqual(@as(u8, 3), rec.zoom);
    try t.expectEqualSlices(model.Column, &cols, rec.columns);
    try t.expectEqualSlices(i32, &widths, rec.col_widths);
    // A record without widths (a pre-resize file) reads as empty,
    // which every consumer treats as all-defaults.
    try t.expectEqual(@as(usize, 0), back.peek("", "/home/me").?.col_widths.len);
    // The local folder is a different key, not an overwrite.
    try t.expect(back.peek("", "/home/me") != null);
    try t.expect(back.peek("box", "/home/me") == null);
}

test "view memory save replaces and loads the complete store" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-viewmem-save-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/viewmem.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    var store = Store.init(t.allocator);
    defer store.deinit();
    store.remember(.{ .path = "/one", .view = .compact });
    try store.saveToPath(path);
    store.remember(.{ .host = "box", .path = "/two", .view = .icons });
    try store.saveToPath(path);

    var loaded = Store.loadFromPath(t.allocator, path);
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 2), loaded.count());
    try t.expectEqual(model.ViewMode.compact, loaded.peek("", "/one").?.view);
    try t.expectEqual(model.ViewMode.icons, loaded.peek("box", "/two").?.view);
}

test "remembering the same folder replaces instead of duplicating" {
    const t = std.testing;
    var store = Store.init(t.allocator);
    defer store.deinit();
    store.remember(.{ .path = "/a", .view = .details });
    store.remember(.{ .path = "/a", .view = .compact });
    try t.expectEqual(@as(usize, 1), store.count());
    try t.expectEqual(model.ViewMode.compact, store.peek("", "/a").?.view);
    try t.expect(store.forget("", "/a"));
    try t.expect(!store.forget("", "/a"));
    try t.expectEqual(@as(usize, 0), store.count());
}

test "the store is bounded and evicts the least recently used folder" {
    const t = std.testing;
    var store = Store.init(t.allocator);
    defer store.deinit();
    var buf: [32]u8 = undefined;
    for (0..MAX_FOLDERS) |i| {
        store.remember(.{ .path = try std.fmt.bufPrint(&buf, "/dir/{d}", .{i}) });
    }
    try t.expectEqual(@as(usize, MAX_FOLDERS), store.count());
    // Touch the oldest so a NEWER one becomes the eviction victim.
    try t.expect(store.use("", "/dir/0") != null);
    store.remember(.{ .path = "/dir/new" });
    try t.expectEqual(@as(usize, MAX_FOLDERS), store.count());
    try t.expect(store.peek("", "/dir/0") != null);
    try t.expect(store.peek("", "/dir/1") == null);
    try t.expect(store.peek("", "/dir/new") != null);

    store.forgetAll();
    try t.expectEqual(@as(usize, 0), store.count());
}

test "a corrupt or foreign state file loads as empty" {
    const t = std.testing;
    var truncated = Store.decode(t.allocator, "{\"version\":1,\"folders\":[{\"path\":\"/a\"");
    defer truncated.deinit();
    try t.expectEqual(@as(usize, 0), truncated.count());

    var garbage = Store.decode(t.allocator, "not json at all");
    defer garbage.deinit();
    try t.expectEqual(@as(usize, 0), garbage.count());

    var empty = Store.decode(t.allocator, "");
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.count());

    // A file written by a future format is ignored, not half-read.
    var future = Store.decode(t.allocator,
        \\{"version":99,"next_seq":5,"folders":[{"path":"/a","view":"details"}]}
    );
    defer future.deinit();
    try t.expectEqual(@as(usize, 0), future.count());

    // An older file that predates a field still loads: unknown keys
    // are ignored and missing ones take their defaults.
    var old = Store.decode(t.allocator,
        \\{"version":1,"folders":[{"host":"","path":"/a","view":"compact","nonsense":7}]}
    );
    defer old.deinit();
    try t.expectEqual(@as(usize, 1), old.count());
    const rec = old.peek("", "/a").?;
    try t.expectEqual(model.ViewMode.compact, rec.view);
    try t.expectEqual(model.SortKey.name, rec.sort);
    try t.expectEqual(@as(u8, 1), rec.zoom);
    try t.expect(rec.dirs_first);
}
