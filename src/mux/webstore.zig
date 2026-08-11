//! Daemon-side web store: browsing history, bookmarks, per-site settings.
//!
//! Lives with the daemon under `$XDG_STATE_HOME/sketerm/web/` so browsing
//! state follows the daemon host, not the GUI: a client attached to a
//! remote daemon sees that host's history/bookmarks/site settings.
//!
//! History is an append-only JSONL log replayed into an in-memory index
//! (per-URL visit count + last-visit time for omnibox ranking) and
//! compacted in place once the log grows past ~2x the live entry count.
//! Bookmarks and site settings are small whole-file JSON documents
//! written atomically (tmp + rename). Pure libc file IO — no GTK, no
//! sockets; unit-tested headless in BOTH test roots.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");

/// Hard cap on live history entries; compaction prunes oldest-by-visit.
pub const MAX_HISTORY: usize = 50_000;
/// Compact when the log holds this many lines beyond 2x the index size.
const COMPACT_SLACK: usize = 512;
/// Longest URL the store accepts; longer ones are silently ignored.
pub const MAX_URL: usize = 4096;
/// Titles are capped (at a UTF-8 boundary) before storing.
pub const MAX_TITLE: usize = 512;

/// The `scheme://host[:port]` prefix of `url`, lowercased into `buf`.
/// Null for URLs with no authority (about:, data:, mailto:) or when
/// the origin does not fit `buf`.
pub fn originOf(buf: []u8, url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    if (sep == 0) return null;
    var end = sep + 3;
    while (end < url.len) : (end += 1) {
        switch (url[end]) {
            '/', '?', '#' => break,
            else => {},
        }
    }
    if (end == sep + 3) return null; // empty host
    if (end > buf.len) return null;
    for (url[0..end], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..end];
}

/// Truncate to `max` bytes without splitting a UTF-8 sequence.
fn capUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn ensureDir(dir: []const u8) bool {
    var z: [4096]u8 = undefined;
    pathz.makeParentDirs(dir) catch return false;
    const p = pathz.pathZ(&z, dir) catch return false;
    if (c.mkdir(p, 0o700) == 0) return true;
    return std.posix.errno(@as(c_int, -1)) == .EXIST;
}

/// `$XDG_STATE_HOME/sketerm/web` (or the ~/.local/state fallback).
pub fn defaultDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |sh| {
        const s = std.mem.span(sh);
        if (s.len > 0) return std.fmt.allocPrint(allocator, "{s}/sketerm/web", .{s});
    }
    if (std.c.getenv("HOME")) |home|
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/web", .{std.mem.span(home)});
    return allocator.dupe(u8, "/tmp/sketerm-web");
}

/// Whole small file into memory; null when absent/unreadable.
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, cap: usize) ?[]u8 {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return null;
    const fp = c.fopen(p, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        list.appendSlice(allocator, buf[0..n]) catch {
            list.deinit(allocator);
            return null;
        };
        if (list.items.len > cap) {
            list.deinit(allocator);
            return null;
        }
    }
    return list.toOwnedSlice(allocator) catch {
        list.deinit(allocator);
        return null;
    };
}

/// Atomic whole-file replace: tmp sibling, fsync, rename.
fn writeFileAtomic(dir: []const u8, path: []const u8, bytes: []const u8) !void {
    if (!ensureDir(dir)) return error.CreateFailed;
    var tmp_buf: [4096:0]u8 = undefined;
    var final_buf: [4096]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp.{d}", .{ path, c.getpid() }) catch return error.BadPath;
    const final = pathz.pathZ(&final_buf, path) catch return error.BadPath;
    const fp = c.fopen(tmp.ptr, "wb") orelse return error.WriteFailed;
    var ok = bytes.len == 0 or c.fwrite(bytes.ptr, 1, bytes.len, fp) == bytes.len;
    ok = ok and c.fflush(fp) == 0;
    if (ok) {
        const fd = c.fileno(fp);
        ok = fd >= 0 and c.fsync(fd) == 0;
    }
    if (c.fclose(fp) != 0) ok = false;
    if (!ok or c.rename(tmp.ptr, final) != 0) {
        _ = c.unlink(tmp.ptr);
        return error.WriteFailed;
    }
}

/// One history log line. A visit carries url/t/title (n defaults to 1);
/// compaction writes the summed n; n=0 is a title-only update; `del`
/// tombstones a URL.
const HistRec = struct {
    url: []const u8 = "",
    title: []const u8 = "",
    t: i64 = 0,
    n: u32 = 1,
    del: []const u8 = "",
};

pub const HistEntry = struct {
    title: []u8,
    visits: u32,
    last_ms: i64,
};

/// A ranked history query match; slices borrow from the store and stay
/// valid until the next mutation.
pub const Hit = struct {
    url: []const u8,
    title: []const u8,
    visits: u32,
    last_ms: i64,
    score: u64,
};

pub const Bookmark = struct {
    id: u64,
    url: []u8,
    title: []u8,
    /// Plain folder name; empty = top level. No nesting hierarchy.
    folder: []u8,
};

pub const Perm = struct {
    name: []u8,
    /// "allow" | "deny" | "ask".
    decision: []u8,
};

pub const Site = struct {
    /// Engine log-scale zoom x100; 0 = default (not stored).
    zoom_x100: i32 = 0,
    /// "" default / "allow" / "block".
    popup: []u8 = &.{},
    /// Content-blocking toggle; null = follow the global default.
    block: ?bool = null,
    perms: std.ArrayList(Perm) = .empty,

    fn isDefault(self: *const Site) bool {
        return self.zoom_x100 == 0 and self.popup.len == 0 and
            self.block == null and self.perms.items.len == 0;
    }

    fn deinit(self: *Site, allocator: std.mem.Allocator) void {
        if (self.popup.len > 0) allocator.free(self.popup);
        for (self.perms.items) |p| {
            allocator.free(p.name);
            allocator.free(p.decision);
        }
        self.perms.deinit(allocator);
    }
};

/// Fields to change on a site; null = leave as is. zoom 0 / popup "" /
/// perm decision "" (or "default") clear their field. `block_clear`
/// resets the content-blocking override.
pub const SitePatch = struct {
    zoom_x100: ?i32 = null,
    popup: ?[]const u8 = null,
    block: ?bool = null,
    block_clear: bool = false,
    perm: []const u8 = "",
    decision: []const u8 = "",
};

pub const WebStore = struct {
    allocator: std.mem.Allocator,
    dir: []u8,
    history: std.StringHashMapUnmanaged(HistEntry) = .empty,
    /// Lines currently in history.jsonl (compaction trigger).
    log_lines: usize = 0,
    bookmarks: std.ArrayList(Bookmark) = .empty,
    next_bookmark_id: u64 = 1,
    sites: std.StringHashMapUnmanaged(Site) = .empty,

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !WebStore {
        var self: WebStore = .{
            .allocator = allocator,
            .dir = try allocator.dupe(u8, dir),
        };
        errdefer allocator.free(self.dir);
        self.loadHistory();
        self.loadBookmarks();
        self.loadSites();
        return self;
    }

    pub fn deinit(self: *WebStore) void {
        var it = self.history.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.title);
        }
        self.history.deinit(self.allocator);
        for (self.bookmarks.items) |b| self.freeBookmark(b);
        self.bookmarks.deinit(self.allocator);
        var sit = self.sites.iterator();
        while (sit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(self.allocator);
        }
        self.sites.deinit(self.allocator);
        self.allocator.free(self.dir);
    }

    fn freeBookmark(self: *WebStore, b: Bookmark) void {
        self.allocator.free(b.url);
        self.allocator.free(b.title);
        self.allocator.free(b.folder);
    }

    fn filePath(self: *const WebStore, buf: *[4096]u8, name: []const u8) ![]const u8 {
        const s = std.fmt.bufPrint(buf, "{s}/{s}", .{ self.dir, name }) catch return error.BadPath;
        return s;
    }

    // ── history ─────────────────────────────────────────────────

    fn loadHistory(self: *WebStore) void {
        var pb: [4096]u8 = undefined;
        const path = self.filePath(&pb, "history.jsonl") catch return;
        // ~50k compacted entries fit far below this; a corrupt or
        // runaway file must not balloon the daemon.
        const bytes = readFileAlloc(self.allocator, path, 64 << 20) orelse return;
        defer self.allocator.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            self.log_lines += 1;
            const parsed = std.json.parseFromSlice(HistRec, self.allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            self.replay(parsed.value);
        }
    }

    fn replay(self: *WebStore, rec: HistRec) void {
        if (rec.del.len > 0) {
            if (self.history.fetchRemove(rec.del)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.title);
            }
            return;
        }
        if (rec.url.len == 0 or rec.url.len > MAX_URL) return;
        self.indexVisit(rec.url, rec.title, rec.t, rec.n) catch {};
    }

    /// Upsert the in-memory index only (no log write).
    fn indexVisit(self: *WebStore, url: []const u8, title: []const u8, t: i64, n: u32) !void {
        const capped = capUtf8(title, MAX_TITLE);
        if (self.history.getPtr(url)) |e| {
            e.visits +|= n;
            if (t > e.last_ms) e.last_ms = t;
            if (capped.len > 0 and !std.mem.eql(u8, e.title, capped)) {
                const nt = try self.allocator.dupe(u8, capped);
                self.allocator.free(e.title);
                e.title = nt;
            }
            return;
        }
        if (n == 0) return; // title update for an unknown URL: nothing to attach it to
        const key = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(key);
        const tdup = try self.allocator.dupe(u8, capped);
        errdefer self.allocator.free(tdup);
        try self.history.put(self.allocator, key, .{
            .title = tdup,
            .visits = n,
            .last_ms = t,
        });
    }

    fn appendLog(self: *WebStore, rec: anytype) !void {
        if (!ensureDir(self.dir)) return error.CreateFailed;
        var pb: [4096]u8 = undefined;
        const path = try self.filePath(&pb, "history.jsonl");
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, path) catch return error.BadPath;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(rec, .{}, &aw.writer) catch return error.WriteFailed;
        aw.writer.writeByte('\n') catch return error.WriteFailed;
        const line = aw.writer.buffered();
        const fp = c.fopen(p, "ab") orelse return error.WriteFailed;
        const wrote = c.fwrite(line.ptr, 1, line.len, fp) == line.len;
        const closed = c.fclose(fp) == 0;
        if (!wrote or !closed) return error.WriteFailed;
        self.log_lines += 1;
    }

    /// Record one committed navigation. Empty title keeps any known one.
    pub fn addVisit(self: *WebStore, url: []const u8, title: []const u8, now_ms: i64) !void {
        if (url.len == 0 or url.len > MAX_URL) return;
        try self.indexVisit(url, title, now_ms, 1);
        try self.appendLog(HistRec{ .url = url, .title = capUtf8(title, MAX_TITLE), .t = now_ms });
        self.maybeCompact();
    }

    /// Attach a late-arriving title to an already-recorded visit
    /// without counting another visit (n=0 on the log).
    pub fn setTitle(self: *WebStore, url: []const u8, title: []const u8) !void {
        if (url.len == 0 or url.len > MAX_URL or title.len == 0) return;
        const e = self.history.getPtr(url) orelse return;
        const capped = capUtf8(title, MAX_TITLE);
        if (std.mem.eql(u8, e.title, capped)) return;
        try self.indexVisit(url, capped, 0, 0);
        try self.appendLog(HistRec{ .url = url, .title = capped, .t = 0, .n = 0 });
        self.maybeCompact();
    }

    /// Remove one URL from history. True when it existed.
    pub fn deleteUrl(self: *WebStore, url: []const u8) !bool {
        const kv = self.history.fetchRemove(url) orelse return false;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value.title);
        try self.appendLog(HistRec{ .del = url });
        self.maybeCompact();
        return true;
    }

    pub fn clearHistory(self: *WebStore) !void {
        var it = self.history.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.title);
        }
        self.history.clearRetainingCapacity();
        var pb: [4096]u8 = undefined;
        const path = try self.filePath(&pb, "history.jsonl");
        try writeFileAtomic(self.dir, path, "");
        self.log_lines = 0;
    }

    fn maybeCompact(self: *WebStore) void {
        const live = self.history.count();
        if (self.log_lines <= 2 * live + COMPACT_SLACK and live <= MAX_HISTORY) return;
        self.compact() catch {};
    }

    /// Rewrite the log as one summed record per URL (atomic), pruning
    /// the least-recently-visited entries beyond MAX_HISTORY.
    fn compact(self: *WebStore) !void {
        if (self.history.count() > MAX_HISTORY) try self.pruneOldest();
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var lines: usize = 0;
        var it = self.history.iterator();
        while (it.next()) |e| {
            std.json.Stringify.value(HistRec{
                .url = e.key_ptr.*,
                .title = e.value_ptr.title,
                .t = e.value_ptr.last_ms,
                .n = e.value_ptr.visits,
            }, .{}, &aw.writer) catch return error.WriteFailed;
            aw.writer.writeByte('\n') catch return error.WriteFailed;
            lines += 1;
        }
        var pb: [4096]u8 = undefined;
        const path = try self.filePath(&pb, "history.jsonl");
        try writeFileAtomic(self.dir, path, aw.writer.buffered());
        self.log_lines = lines;
    }

    fn pruneOldest(self: *WebStore) !void {
        const excess = self.history.count() - MAX_HISTORY;
        var doomed = try self.allocator.alloc([]const u8, excess);
        defer self.allocator.free(doomed);
        // Selection by repeated min scan is fine at compaction cadence.
        var i: usize = 0;
        while (i < excess) : (i += 1) {
            var oldest: ?[]const u8 = null;
            var oldest_ms: i64 = std.math.maxInt(i64);
            var it = self.history.iterator();
            outer: while (it.next()) |e| {
                for (doomed[0..i]) |d| if (d.ptr == e.key_ptr.*.ptr) continue :outer;
                if (e.value_ptr.last_ms < oldest_ms) {
                    oldest_ms = e.value_ptr.last_ms;
                    oldest = e.key_ptr.*;
                }
            }
            doomed[i] = oldest orelse break;
        }
        for (doomed[0..i]) |url| {
            if (self.history.fetchRemove(url)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.title);
            }
        }
    }

    /// Frecency: visit count weighted by recency of the last visit.
    fn frecency(visits: u32, last_ms: i64, now_ms: i64) u64 {
        const age_ms: u64 = @abs(now_ms -| last_ms);
        const day_ms: u64 = 24 * 60 * 60 * 1000;
        const weight: u64 = if (age_ms <= 4 * day_ms)
            100
        else if (age_ms <= 14 * day_ms)
            70
        else if (age_ms <= 31 * day_ms)
            50
        else if (age_ms <= 90 * day_ms)
            30
        else
            10;
        return @as(u64, visits) * weight;
    }

    /// Ranked case-insensitive substring query over URL + title; an
    /// empty query returns the overall top entries (omnibox default).
    /// Prefix matches (with or without scheme / www.) rank higher.
    /// Caller frees the returned slice; hits borrow store memory.
    pub fn query(self: *WebStore, allocator: std.mem.Allocator, q: []const u8, max: usize, now_ms: i64) ![]Hit {
        var hits: std.ArrayList(Hit) = .empty;
        errdefer hits.deinit(allocator);
        var it = self.history.iterator();
        while (it.next()) |e| {
            const url = e.key_ptr.*;
            const title = e.value_ptr.title;
            var prefix = false;
            if (q.len > 0) {
                const in_url = std.ascii.indexOfIgnoreCase(url, q);
                const in_title = std.ascii.indexOfIgnoreCase(title, q);
                if (in_url == null and in_title == null) continue;
                prefix = std.ascii.startsWithIgnoreCase(url, q) or
                    std.ascii.startsWithIgnoreCase(hostPart(url), q);
            }
            var score = frecency(e.value_ptr.visits, e.value_ptr.last_ms, now_ms);
            if (prefix) score *|= 4;
            try hits.append(allocator, .{
                .url = url,
                .title = title,
                .visits = e.value_ptr.visits,
                .last_ms = e.value_ptr.last_ms,
                .score = score,
            });
        }
        std.mem.sort(Hit, hits.items, {}, hitBefore);
        if (hits.items.len > max) hits.shrinkRetainingCapacity(max);
        return hits.toOwnedSlice(allocator);
    }

    fn hitBefore(_: void, a: Hit, b: Hit) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.last_ms > b.last_ms;
    }

    /// URL past its scheme and any leading "www." — the part users type.
    fn hostPart(url: []const u8) []const u8 {
        var s = url;
        if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
        if (std.ascii.startsWithIgnoreCase(s, "www.")) s = s[4..];
        return s;
    }

    // ── bookmarks ───────────────────────────────────────────────

    const BookmarksDoc = struct {
        next_id: u64 = 1,
        bookmarks: []const BookmarkDto = &.{},
    };
    const BookmarkDto = struct {
        id: u64 = 0,
        url: []const u8 = "",
        title: []const u8 = "",
        folder: []const u8 = "",
    };

    fn loadBookmarks(self: *WebStore) void {
        var pb: [4096]u8 = undefined;
        const path = self.filePath(&pb, "bookmarks.json") catch return;
        const bytes = readFileAlloc(self.allocator, path, 16 << 20) orelse return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(BookmarksDoc, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        self.next_bookmark_id = @max(parsed.value.next_id, 1);
        for (parsed.value.bookmarks) |b| {
            if (b.url.len == 0 or b.url.len > MAX_URL) continue;
            const url = self.allocator.dupe(u8, b.url) catch continue;
            const title = self.allocator.dupe(u8, capUtf8(b.title, MAX_TITLE)) catch {
                self.allocator.free(url);
                continue;
            };
            const folder = self.allocator.dupe(u8, b.folder) catch {
                self.allocator.free(url);
                self.allocator.free(title);
                continue;
            };
            const id = if (b.id > 0) b.id else self.next_bookmark_id;
            if (id >= self.next_bookmark_id) self.next_bookmark_id = id + 1;
            self.bookmarks.append(self.allocator, .{
                .id = id,
                .url = url,
                .title = title,
                .folder = folder,
            }) catch {
                self.allocator.free(url);
                self.allocator.free(title);
                self.allocator.free(folder);
            };
        }
    }

    fn saveBookmarks(self: *WebStore) !void {
        var dtos = try self.allocator.alloc(BookmarkDto, self.bookmarks.items.len);
        defer self.allocator.free(dtos);
        for (self.bookmarks.items, 0..) |b, i| dtos[i] = .{
            .id = b.id,
            .url = b.url,
            .title = b.title,
            .folder = b.folder,
        };
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(BookmarksDoc{
            .next_id = self.next_bookmark_id,
            .bookmarks = dtos,
        }, .{}, &aw.writer) catch return error.WriteFailed;
        var pb: [4096]u8 = undefined;
        const path = try self.filePath(&pb, "bookmarks.json");
        try writeFileAtomic(self.dir, path, aw.writer.buffered());
    }

    /// Append a bookmark; returns its id.
    pub fn bookmarkAdd(self: *WebStore, url: []const u8, title: []const u8, folder: []const u8) !u64 {
        if (url.len == 0 or url.len > MAX_URL) return error.BadUrl;
        const u = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(u);
        const t = try self.allocator.dupe(u8, capUtf8(title, MAX_TITLE));
        errdefer self.allocator.free(t);
        const f = try self.allocator.dupe(u8, folder);
        errdefer self.allocator.free(f);
        const id = self.next_bookmark_id;
        self.next_bookmark_id += 1;
        try self.bookmarks.append(self.allocator, .{ .id = id, .url = u, .title = t, .folder = f });
        try self.saveBookmarks();
        return id;
    }

    pub fn bookmarkRemove(self: *WebStore, id: u64) !bool {
        for (self.bookmarks.items, 0..) |b, i| {
            if (b.id != id) continue;
            self.freeBookmark(self.bookmarks.orderedRemove(i));
            try self.saveBookmarks();
            return true;
        }
        return false;
    }

    pub const BookmarkUpdate = struct {
        url: ?[]const u8 = null,
        title: ?[]const u8 = null,
        folder: ?[]const u8 = null,
        /// Reorder to this position (clamped).
        index: ?usize = null,
    };

    pub fn bookmarkUpdate(self: *WebStore, id: u64, upd: BookmarkUpdate) !bool {
        const at = for (self.bookmarks.items, 0..) |b, i| {
            if (b.id == id) break i;
        } else return false;
        const b = &self.bookmarks.items[at];
        if (upd.url) |u| {
            if (u.len == 0 or u.len > MAX_URL) return error.BadUrl;
            const nu = try self.allocator.dupe(u8, u);
            self.allocator.free(b.url);
            b.url = nu;
        }
        if (upd.title) |t| {
            const nt = try self.allocator.dupe(u8, capUtf8(t, MAX_TITLE));
            self.allocator.free(b.title);
            b.title = nt;
        }
        if (upd.folder) |f| {
            const nf = try self.allocator.dupe(u8, f);
            self.allocator.free(b.folder);
            b.folder = nf;
        }
        if (upd.index) |want| {
            const moved = self.bookmarks.orderedRemove(at);
            const dest = @min(want, self.bookmarks.items.len);
            self.bookmarks.insert(self.allocator, dest, moved) catch {
                // Never drop the bookmark on an OOM re-insert.
                self.bookmarks.append(self.allocator, moved) catch {
                    self.freeBookmark(moved);
                    return error.OutOfMemory;
                };
            };
        }
        try self.saveBookmarks();
        return true;
    }

    // ── site settings ───────────────────────────────────────────

    const SitesDoc = struct {
        sites: []const SiteDto = &.{},
    };
    const PermDto = struct {
        name: []const u8 = "",
        decision: []const u8 = "",
    };
    const SiteDto = struct {
        origin: []const u8 = "",
        zoom_x100: i32 = 0,
        popup: []const u8 = "",
        block: ?bool = null,
        perms: []const PermDto = &.{},
    };

    fn loadSites(self: *WebStore) void {
        var pb: [4096]u8 = undefined;
        const path = self.filePath(&pb, "sites.json") catch return;
        const bytes = readFileAlloc(self.allocator, path, 16 << 20) orelse return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(SitesDoc, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        for (parsed.value.sites) |s| {
            if (s.origin.len == 0 or s.origin.len > MAX_URL) continue;
            var site: Site = .{
                .zoom_x100 = s.zoom_x100,
                .block = s.block,
            };
            if (s.popup.len > 0)
                site.popup = self.allocator.dupe(u8, s.popup) catch continue;
            var bad = false;
            for (s.perms) |p| {
                if (p.name.len == 0 or p.decision.len == 0) continue;
                const name = self.allocator.dupe(u8, p.name) catch {
                    bad = true;
                    break;
                };
                const decision = self.allocator.dupe(u8, p.decision) catch {
                    self.allocator.free(name);
                    bad = true;
                    break;
                };
                site.perms.append(self.allocator, .{ .name = name, .decision = decision }) catch {
                    self.allocator.free(name);
                    self.allocator.free(decision);
                    bad = true;
                    break;
                };
            }
            if (bad or site.isDefault()) {
                site.deinit(self.allocator);
                continue;
            }
            const key = self.allocator.dupe(u8, s.origin) catch {
                site.deinit(self.allocator);
                continue;
            };
            self.sites.put(self.allocator, key, site) catch {
                self.allocator.free(key);
                site.deinit(self.allocator);
            };
        }
    }

    fn saveSites(self: *WebStore) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var dtos: std.ArrayList(SiteDto) = .empty;
        var it = self.sites.iterator();
        while (it.next()) |e| {
            var perms = try aa.alloc(PermDto, e.value_ptr.perms.items.len);
            for (e.value_ptr.perms.items, 0..) |p, i|
                perms[i] = .{ .name = p.name, .decision = p.decision };
            try dtos.append(aa, .{
                .origin = e.key_ptr.*,
                .zoom_x100 = e.value_ptr.zoom_x100,
                .popup = e.value_ptr.popup,
                .block = e.value_ptr.block,
                .perms = perms,
            });
        }
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(SitesDoc{ .sites = dtos.items }, .{}, &aw.writer) catch return error.WriteFailed;
        var pb: [4096]u8 = undefined;
        const path = try self.filePath(&pb, "sites.json");
        try writeFileAtomic(self.dir, path, aw.writer.buffered());
    }

    /// Case-normalized lookup. The returned pointer is invalidated by
    /// the next siteSet.
    pub fn siteGet(self: *WebStore, origin: []const u8) ?*const Site {
        var buf: [512]u8 = undefined;
        const key = normOrigin(&buf, origin) orelse return null;
        return self.sites.getPtr(key);
    }

    /// Merge a patch into (or out of) one origin's settings; a site
    /// left all-default is removed entirely.
    pub fn siteSet(self: *WebStore, origin: []const u8, patch: SitePatch) !void {
        var buf: [512]u8 = undefined;
        const key = normOrigin(&buf, origin) orelse return error.BadOrigin;
        var entry = self.sites.getPtr(key);
        if (entry == null) {
            const owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned);
            try self.sites.put(self.allocator, owned, .{});
            entry = self.sites.getPtr(key);
        }
        const site = entry.?;
        if (patch.zoom_x100) |z| site.zoom_x100 = z;
        if (patch.popup) |p| {
            if (site.popup.len > 0) self.allocator.free(site.popup);
            site.popup = if (p.len > 0) try self.allocator.dupe(u8, p) else &.{};
        }
        if (patch.block_clear) {
            site.block = null;
        } else if (patch.block) |bval| {
            site.block = bval;
        }
        if (patch.perm.len > 0) {
            const clear = patch.decision.len == 0 or std.mem.eql(u8, patch.decision, "default");
            var found = false;
            for (site.perms.items, 0..) |p, i| {
                if (!std.mem.eql(u8, p.name, patch.perm)) continue;
                found = true;
                if (clear) {
                    self.allocator.free(p.name);
                    self.allocator.free(p.decision);
                    _ = site.perms.swapRemove(i);
                } else {
                    const nd = try self.allocator.dupe(u8, patch.decision);
                    self.allocator.free(p.decision);
                    site.perms.items[i].decision = nd;
                }
                break;
            }
            if (!found and !clear) {
                const name = try self.allocator.dupe(u8, patch.perm);
                errdefer self.allocator.free(name);
                const decision = try self.allocator.dupe(u8, patch.decision);
                errdefer self.allocator.free(decision);
                try site.perms.append(self.allocator, .{ .name = name, .decision = decision });
            }
        }
        if (site.isDefault()) {
            if (self.sites.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                var dead = kv.value;
                dead.deinit(self.allocator);
            }
        }
        try self.saveSites();
    }

    fn normOrigin(buf: []u8, origin: []const u8) ?[]const u8 {
        if (origin.len == 0 or origin.len > buf.len) return null;
        for (origin, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        return buf[0..origin.len];
    }
};

// ── tests ───────────────────────────────────────────────────────

fn testDir(buf: *[64]u8) ?[]const u8 {
    const template = "/tmp/sk-webstore-XXXXXX";
    @memcpy(buf[0..template.len], template);
    buf[template.len] = 0;
    const p = c.mkdtemp(@ptrCast(buf)) orelse return null;
    return std.mem.span(@as([*:0]u8, @ptrCast(p)));
}

fn rmTree(dir: []const u8) void {
    var pb: [4096:0]u8 = undefined;
    for ([_][]const u8{ "history.jsonl", "bookmarks.json", "sites.json" }) |f| {
        const p = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, f }) catch continue;
        _ = c.unlink(p.ptr);
    }
    const d = std.fmt.bufPrintZ(&pb, "{s}", .{dir}) catch return;
    _ = c.rmdir(d.ptr);
}

test "webstore: originOf extracts and lowercases scheme+host" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com", originOf(&buf, "HTTPS://Example.COM/path?q=1").?);
    try std.testing.expectEqualStrings("http://a.b:8080", originOf(&buf, "http://a.b:8080").?);
    try std.testing.expectEqual(@as(?[]const u8, null), originOf(&buf, "about:blank"));
    try std.testing.expectEqual(@as(?[]const u8, null), originOf(&buf, "data:text/html,hi"));
    try std.testing.expectEqual(@as(?[]const u8, null), originOf(&buf, "://nohost"));
}

test "webstore: history visits round-trip across a reload" {
    const t = std.testing;
    var db: [64]u8 = undefined;
    const dir = testDir(&db) orelse return error.SkipZigTest;
    defer rmTree(dir);

    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        try store.addVisit("https://ziglang.org/", "Zig", 1000);
        try store.addVisit("https://ziglang.org/", "", 2000);
        try store.addVisit("https://example.com/a", "Example A", 1500);
        try store.setTitle("https://example.com/a", "Example Alpha");
    }
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();
    try t.expectEqual(@as(usize, 2), store.history.count());
    const zig = store.history.get("https://ziglang.org/").?;
    try t.expectEqual(@as(u32, 2), zig.visits);
    try t.expectEqual(@as(i64, 2000), zig.last_ms);
    try t.expectEqualStrings("Zig", zig.title);
    const ex = store.history.get("https://example.com/a").?;
    try t.expectEqual(@as(u32, 1), ex.visits);
    try t.expectEqualStrings("Example Alpha", ex.title);
}

test "webstore: query ranks prefix and frecency, bounds results" {
    const t = std.testing;
    var db: [64]u8 = undefined;
    const dir = testDir(&db) orelse return error.SkipZigTest;
    defer rmTree(dir);
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();

    const now: i64 = 100 * 24 * 60 * 60 * 1000;
    // Old but heavily visited; matches "zig" as a substring only.
    var i: usize = 0;
    while (i < 5) : (i += 1) try store.addVisit("https://news.site/zig-thread", "zig discussion", 1000);
    // Fresh, fewer visits, and a host-prefix match for "zig".
    try store.addVisit("https://ziglang.org/", "Zig", now - 1000);

    const hits = try store.query(t.allocator, "zig", 10, now);
    defer t.allocator.free(hits);
    try t.expectEqual(@as(usize, 2), hits.len);
    // Host-prefix + recency beats old substring bulk.
    try t.expectEqualStrings("https://ziglang.org/", hits[0].url);

    // Case-insensitive; title matches count.
    const hits2 = try store.query(t.allocator, "DISCUSSION", 10, now);
    defer t.allocator.free(hits2);
    try t.expectEqual(@as(usize, 1), hits2.len);

    // Bounded.
    const hits3 = try store.query(t.allocator, "", 1, now);
    defer t.allocator.free(hits3);
    try t.expectEqual(@as(usize, 1), hits3.len);

    // No match.
    const hits4 = try store.query(t.allocator, "nosuchthing", 10, now);
    defer t.allocator.free(hits4);
    try t.expectEqual(@as(usize, 0), hits4.len);
}

test "webstore: delete and clear persist across reload" {
    const t = std.testing;
    var db: [64]u8 = undefined;
    const dir = testDir(&db) orelse return error.SkipZigTest;
    defer rmTree(dir);

    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        try store.addVisit("https://a.com/", "A", 1);
        try store.addVisit("https://b.com/", "B", 2);
        try t.expect(try store.deleteUrl("https://a.com/"));
        try t.expect(!(try store.deleteUrl("https://a.com/")));
    }
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        try t.expectEqual(@as(usize, 1), store.history.count());
        try t.expect(store.history.get("https://b.com/") != null);
        try store.clearHistory();
    }
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();
    try t.expectEqual(@as(usize, 0), store.history.count());
}

test "webstore: compaction rewrites the log without losing counts" {
    const t = std.testing;
    var db: [64]u8 = undefined;
    const dir = testDir(&db) orelse return error.SkipZigTest;
    defer rmTree(dir);

    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        // 2 URLs, enough lines to cross 2*live + COMPACT_SLACK.
        var i: usize = 0;
        while (i < COMPACT_SLACK + 10) : (i += 1) {
            try store.addVisit("https://hot.com/", "Hot", @intCast(i));
            try store.addVisit("https://cold.com/", "Cold", @intCast(i));
        }
        // Compaction must have fired: the log is near the live count.
        try t.expect(store.log_lines <= 2 * store.history.count() + COMPACT_SLACK);
    }
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();
    try t.expectEqual(@as(usize, 2), store.history.count());
    try t.expectEqual(@as(u32, COMPACT_SLACK + 10), store.history.get("https://hot.com/").?.visits);
}

test "webstore: bookmarks keep order, folders and updates across reload" {
    const t = std.testing;
    var db: [64]u8 = undefined;
    const dir = testDir(&db) orelse return error.SkipZigTest;
    defer rmTree(dir);

    var first: u64 = 0;
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        first = try store.bookmarkAdd("https://a.com/", "A", "");
        _ = try store.bookmarkAdd("https://b.com/", "B", "work");
        const third = try store.bookmarkAdd("https://c.com/", "C", "");
        // Retitle + move C to the front.
        try t.expect(try store.bookmarkUpdate(third, .{ .title = "Sea", .index = 0 }));
        try t.expect(!(try store.bookmarkUpdate(9999, .{ .title = "x" })));
    }
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        try t.expectEqual(@as(usize, 3), store.bookmarks.items.len);
        try t.expectEqualStrings("Sea", store.bookmarks.items[0].title);
        try t.expectEqualStrings("https://a.com/", store.bookmarks.items[1].url);
        try t.expectEqualStrings("work", store.bookmarks.items[2].folder);
        try t.expect(try store.bookmarkRemove(first));
    }
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();
    try t.expectEqual(@as(usize, 2), store.bookmarks.items.len);
    // Ids never recycle after reload.
    const id = try store.bookmarkAdd("https://d.com/", "D", "");
    try t.expect(id > first);
}

test "webstore: site settings merge, clear and survive reload" {
    const t = std.testing;
    var db: [64]u8 = undefined;
    const dir = testDir(&db) orelse return error.SkipZigTest;
    defer rmTree(dir);

    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        try store.siteSet("https://Example.COM", .{ .zoom_x100 = 200 });
        try store.siteSet("https://example.com", .{ .perm = "geolocation", .decision = "deny" });
        try store.siteSet("https://other.net", .{ .popup = "block", .block = true });
    }
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        // Lookup is case-normalized; both fields merged into one origin.
        const ex = store.siteGet("HTTPS://EXAMPLE.COM").?;
        try t.expectEqual(@as(i32, 200), ex.zoom_x100);
        try t.expectEqual(@as(usize, 1), ex.perms.items.len);
        try t.expectEqualStrings("deny", ex.perms.items[0].decision);
        const oth = store.siteGet("https://other.net").?;
        try t.expectEqualStrings("block", oth.popup);
        try t.expectEqual(@as(?bool, true), oth.block);
        // Clearing every field removes the origin entirely.
        try store.siteSet("https://example.com", .{ .zoom_x100 = 0, .perm = "geolocation", .decision = "default" });
        try t.expectEqual(@as(?*const Site, null), store.siteGet("https://example.com"));
        try store.siteSet("https://other.net", .{ .popup = "", .block_clear = true });
    }
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();
    try t.expectEqual(@as(usize, 0), store.sites.count());
}
