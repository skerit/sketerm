//! Daemon-side web store: browsing history, bookmarks, per-site settings.
//!
//! Lives with the daemon under `$XDG_STATE_HOME/sketerm/web/` so browsing
//! state follows the daemon host, not the GUI: a client attached to a
//! remote daemon sees that host's history/bookmarks/site settings.
//!
//! History is an append-only JSONL log replayed into an in-memory index
//! (per-URL visit count + last-visit time for omnibox ranking) and
//! compacted in place once the log grows past ~2x the live entry count.
//! Bookmarks, site settings, userscripts and userstyles are small
//! whole-file JSON documents written through the shared durable atomic
//! writer. Pure
//! libc file IO — no GTK, no sockets; unit-tested headless in BOTH
//! test roots.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const pathz = @import("../util/pathz.zig");

/// Hard cap on live history entries; compaction prunes oldest-by-visit.
pub const MAX_HISTORY: usize = 50_000;
/// Compact when the log holds this many lines beyond 2x the index size.
const COMPACT_SLACK: usize = 512;
/// Longest URL the store accepts; longer ones are silently ignored.
pub const MAX_URL: usize = 4096;
/// Titles are capped (at a UTF-8 boundary) before storing.
pub const MAX_TITLE: usize = 512;
/// Largest userscript source / userstyle CSS the store accepts.
pub const MAX_SOURCE: usize = 2 << 20;
pub const MAX_CONTAINER_NAME: usize = 128;
/// Bound on an egress / remote-helper host and on a site-rule host.
pub const MAX_HOST: usize = 256;

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
    return readFileAllocE(allocator, path, cap) catch null;
}

/// Error-returning so the `errdefer` runs; as a `?[]u8` body it did not.
fn readFileAllocE(allocator: std.mem.Allocator, path: []const u8, cap: usize) ![]u8 {
    var z: [4096]u8 = undefined;
    const p = try pathz.pathZ(&z, path);
    const fp = c.fopen(p, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(fp);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
        if (list.items.len > cap) return error.StreamTooLong;
    }
    return list.toOwnedSlice(allocator);
}

/// Durable whole-file replacement for daemon-owned browser state.
fn writeDurableFile(dir: []const u8, path: []const u8, bytes: []const u8) !void {
    if (!ensureDir(dir)) return error.CreateFailed;
    try atomicwrite.writeFileExact(path, bytes, 0o600);
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

pub const UserScript = struct {
    id: u64,
    enabled: bool,
    /// Display name (from the metadata block at add time).
    name: []u8,
    /// Raw source including the `==UserScript==` block.
    source: []u8,
};

pub const UserStyle = struct {
    /// Lowercased host the style is scoped to ("" = every page).
    host: []u8,
    enabled: bool,
    css: []u8,
};

/// A browser identity context (Firefox Multi-Account Containers shape).
///
/// EPHEMERAL containers are deliberately absent: incognito is a
/// throwaway in-memory jar, and persisting one would resurrect it as a
/// named identity the user never asked to keep.
pub const Container = struct {
    /// Stable across restarts, and the SAME number the engine receives
    /// as `context_create.id` — the helper derives its on-disk jar path
    /// from it, so re-minting ids would silently empty every container.
    id: u32,
    /// Display name; freely renameable.
    name: []u8,
    /// Immutable cache key handed to the engine as the context name.
    /// Split from `name` precisely so a rename keeps the cookies.
    jar: []u8,
    color: [3]u8,
    /// Egress host ("" = direct); mutually exclusive with `remote_host`.
    egress_host: []u8,
    /// Remote-helper host ("" = local); see `webface.Container`.
    remote_host: []u8,
};

/// "Always open this host in container X".
pub const ContainerSite = struct {
    /// Lowercased, matched exactly.
    host: []u8,
    container: u32,
};

/// Fields to change on a container; null = leave as is. The jar key and
/// the id are absent on purpose — neither may ever change.
pub const ContainerUpdate = struct {
    name: ?[]const u8 = null,
    color: ?[3]u8 = null,
    egress_host: ?[]const u8 = null,
    remote_host: ?[]const u8 = null,
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
    userscripts: std.ArrayList(UserScript) = .empty,
    next_userscript_id: u64 = 1,
    userstyles: std.ArrayList(UserStyle) = .empty,
    containers: std.ArrayList(Container) = .empty,
    next_container_id: u32 = 1,
    container_sites: std.ArrayList(ContainerSite) = .empty,
    /// Compaction follows an already-committed append, so failure is logged
    /// once and retried later rather than turning a successful visit into an
    /// ambiguous client error.
    compaction_error_reported: bool = false,

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !WebStore {
        var self: WebStore = .{
            .allocator = allocator,
            .dir = try allocator.dupe(u8, dir),
        };
        errdefer allocator.free(self.dir);
        self.loadHistory();
        self.loadBookmarks();
        self.loadSites();
        self.loadUserScripts();
        self.loadUserStyles();
        self.loadContainers();
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
        for (self.userscripts.items) |s| {
            self.allocator.free(s.name);
            self.allocator.free(s.source);
        }
        self.userscripts.deinit(self.allocator);
        for (self.userstyles.items) |s| {
            self.allocator.free(s.host);
            self.allocator.free(s.css);
        }
        self.userstyles.deinit(self.allocator);
        for (self.containers.items) |ctn| self.freeContainer(ctn);
        self.containers.deinit(self.allocator);
        for (self.container_sites.items) |s| self.allocator.free(s.host);
        self.container_sites.deinit(self.allocator);
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
        // This is an append-only journal, not a whole-file state snapshot.
        // Closing checks delivery to the kernel; syncing every navigation
        // would stall browsing, so a power cut may lose only the newest line.
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
        try writeDurableFile(self.dir, path, "");
        self.log_lines = 0;
    }

    fn maybeCompact(self: *WebStore) void {
        const live = self.history.count();
        if (self.log_lines <= 2 * live + COMPACT_SLACK and live <= MAX_HISTORY) return;
        self.compact() catch |err| {
            if (!self.compaction_error_reported) {
                std.debug.print("sketerm: web history compaction failed: {s}\n", .{@errorName(err)});
                self.compaction_error_reported = true;
            }
            return;
        };
        self.compaction_error_reported = false;
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
        try writeDurableFile(self.dir, path, aw.writer.buffered());
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
        try writeDurableFile(self.dir, path, aw.writer.buffered());
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
        try writeDurableFile(self.dir, path, aw.writer.buffered());
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

    // ── userscripts ─────────────────────────────────────────────

    const UserScriptsDoc = struct {
        next_id: u64 = 1,
        scripts: []const UserScriptDto = &.{},
    };
    const UserScriptDto = struct {
        id: u64 = 0,
        enabled: bool = true,
        name: []const u8 = "",
        source: []const u8 = "",
    };

    fn loadUserScripts(self: *WebStore) void {
        var pb: [4096]u8 = undefined;
        const path = self.filePath(&pb, "userscripts.json") catch return;
        const bytes = readFileAlloc(self.allocator, path, 64 << 20) orelse return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(UserScriptsDoc, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        self.next_userscript_id = @max(parsed.value.next_id, 1);
        for (parsed.value.scripts) |s| {
            if (s.source.len == 0 or s.source.len > MAX_SOURCE) continue;
            const name = self.allocator.dupe(u8, capUtf8(s.name, MAX_TITLE)) catch continue;
            const source = self.allocator.dupe(u8, s.source) catch {
                self.allocator.free(name);
                continue;
            };
            const id = if (s.id > 0) s.id else self.next_userscript_id;
            if (id >= self.next_userscript_id) self.next_userscript_id = id + 1;
            self.userscripts.append(self.allocator, .{
                .id = id,
                .enabled = s.enabled,
                .name = name,
                .source = source,
            }) catch {
                self.allocator.free(name);
                self.allocator.free(source);
            };
        }
    }

    fn saveUserScripts(self: *WebStore) !void {
        var dtos = try self.allocator.alloc(UserScriptDto, self.userscripts.items.len);
        defer self.allocator.free(dtos);
        for (self.userscripts.items, 0..) |s, i| dtos[i] = .{
            .id = s.id,
            .enabled = s.enabled,
            .name = s.name,
            .source = s.source,
        };
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(UserScriptsDoc{
            .next_id = self.next_userscript_id,
            .scripts = dtos,
        }, .{}, &aw.writer) catch return error.WriteFailed;
        var pb: [4096]u8 = undefined;
        const path = try self.filePath(&pb, "userscripts.json");
        try writeDurableFile(self.dir, path, aw.writer.buffered());
    }

    /// Store one userscript (enabled); returns its id. The daemon does
    /// not parse the source — the NAME is the caller's business (the
    /// GUI parses the metadata block), the source is opaque bytes.
    pub fn userscriptAdd(self: *WebStore, name: []const u8, source: []const u8) !u64 {
        if (source.len == 0 or source.len > MAX_SOURCE) return error.BadSource;
        const n = try self.allocator.dupe(u8, capUtf8(name, MAX_TITLE));
        errdefer self.allocator.free(n);
        const s = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(s);
        const id = self.next_userscript_id;
        self.next_userscript_id += 1;
        try self.userscripts.append(self.allocator, .{
            .id = id,
            .enabled = true,
            .name = n,
            .source = s,
        });
        try self.saveUserScripts();
        return id;
    }

    pub fn userscriptRemove(self: *WebStore, id: u64) !bool {
        for (self.userscripts.items, 0..) |s, i| {
            if (s.id != id) continue;
            const dead = self.userscripts.orderedRemove(i);
            self.allocator.free(dead.name);
            self.allocator.free(dead.source);
            try self.saveUserScripts();
            return true;
        }
        return false;
    }

    pub fn userscriptEnable(self: *WebStore, id: u64, enabled: bool) !bool {
        for (self.userscripts.items) |*s| {
            if (s.id != id) continue;
            if (s.enabled != enabled) {
                s.enabled = enabled;
                try self.saveUserScripts();
            }
            return true;
        }
        return false;
    }

    // ── userstyles ──────────────────────────────────────────────

    const UserStylesDoc = struct {
        styles: []const UserStyleDto = &.{},
    };
    const UserStyleDto = struct {
        host: []const u8 = "",
        enabled: bool = true,
        css: []const u8 = "",
    };

    fn loadUserStyles(self: *WebStore) void {
        var pb: [4096]u8 = undefined;
        const path = self.filePath(&pb, "userstyles.json") catch return;
        const bytes = readFileAlloc(self.allocator, path, 64 << 20) orelse return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(UserStylesDoc, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        for (parsed.value.styles) |s| {
            if (s.css.len == 0 or s.css.len > MAX_SOURCE or s.host.len > MAX_URL) continue;
            const host = self.allocator.dupe(u8, s.host) catch continue;
            for (host) |*ch| ch.* = std.ascii.toLower(ch.*);
            const css = self.allocator.dupe(u8, s.css) catch {
                self.allocator.free(host);
                continue;
            };
            self.userstyles.append(self.allocator, .{
                .host = host,
                .enabled = s.enabled,
                .css = css,
            }) catch {
                self.allocator.free(host);
                self.allocator.free(css);
            };
        }
    }

    fn saveUserStyles(self: *WebStore) !void {
        var dtos = try self.allocator.alloc(UserStyleDto, self.userstyles.items.len);
        defer self.allocator.free(dtos);
        for (self.userstyles.items, 0..) |s, i| dtos[i] = .{
            .host = s.host,
            .enabled = s.enabled,
            .css = s.css,
        };
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(UserStylesDoc{ .styles = dtos }, .{}, &aw.writer) catch
            return error.WriteFailed;
        var pb: [4096]u8 = undefined;
        const path = try self.filePath(&pb, "userstyles.json");
        try writeDurableFile(self.dir, path, aw.writer.buffered());
    }

    /// One style per host: set replaces, empty css deletes. The host
    /// key is case-normalized; "" scopes the style to every page.
    pub fn userstyleSet(self: *WebStore, host: []const u8, css: []const u8, enabled: bool) !void {
        if (css.len > MAX_SOURCE or host.len > 512) return error.BadStyle;
        var hbuf: [512]u8 = undefined;
        for (host, 0..) |ch, i| hbuf[i] = std.ascii.toLower(ch);
        const key = hbuf[0..host.len];
        for (self.userstyles.items, 0..) |*s, i| {
            if (!std.mem.eql(u8, s.host, key)) continue;
            if (css.len == 0) {
                const dead = self.userstyles.orderedRemove(i);
                self.allocator.free(dead.host);
                self.allocator.free(dead.css);
            } else {
                const nc = try self.allocator.dupe(u8, css);
                self.allocator.free(s.css);
                s.css = nc;
                s.enabled = enabled;
            }
            try self.saveUserStyles();
            return;
        }
        if (css.len == 0) return; // deleting what is not there
        const h = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(h);
        const nc = try self.allocator.dupe(u8, css);
        errdefer self.allocator.free(nc);
        try self.userstyles.append(self.allocator, .{ .host = h, .enabled = enabled, .css = nc });
        try self.saveUserStyles();
    }

    /// The style stored for exactly this host key, if any. The pointer
    /// is invalidated by the next `userstyleSet`.
    pub fn userstyleGet(self: *WebStore, host: []const u8) ?*const UserStyle {
        var hbuf: [512]u8 = undefined;
        if (host.len > hbuf.len) return null;
        for (host, 0..) |ch, i| hbuf[i] = std.ascii.toLower(ch);
        const key = hbuf[0..host.len];
        for (self.userstyles.items) |*s| {
            if (std.mem.eql(u8, s.host, key)) return s;
        }
        return null;
    }

    // ── containers ──────────────────────────────────────────────

    const ContainersDoc = struct {
        next_id: u32 = 1,
        containers: []const ContainerDto = &.{},
        sites: []const ContainerSiteDto = &.{},
    };
    const ContainerDto = struct {
        id: u32 = 0,
        name: []const u8 = "",
        jar: []const u8 = "",
        /// 0xRRGGBB. A u32 rather than a 3-element array so a truncated
        /// or over-long array in a hand-edited file cannot half-parse.
        color: u32 = 0,
        egress_host: []const u8 = "",
        remote_host: []const u8 = "",
    };
    const ContainerSiteDto = struct {
        host: []const u8 = "",
        container: u32 = 0,
    };

    fn loadContainers(self: *WebStore) void {
        var pb: [4096]u8 = undefined;
        const path = self.filePath(&pb, "containers.json") catch return;
        const bytes = readFileAlloc(self.allocator, path, 16 << 20) orelse return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(ContainersDoc, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        self.next_container_id = @max(parsed.value.next_id, 1);
        for (parsed.value.containers) |ctn| {
            if (ctn.name.len == 0 or ctn.name.len > MAX_CONTAINER_NAME) continue;
            if (ctn.jar.len > MAX_CONTAINER_NAME) continue;
            if (ctn.egress_host.len > MAX_HOST or ctn.remote_host.len > MAX_HOST) continue;
            // Egress and remote-helper are mutually exclusive (see
            // `Container.remote_host`); a file claiming both is refused
            // rather than silently resolved one way.
            if (ctn.egress_host.len != 0 and ctn.remote_host.len != 0) continue;
            const rec = self.dupeContainer(ctn) orelse continue;
            if (rec.id >= self.next_container_id) self.next_container_id = rec.id + 1;
            self.containers.append(self.allocator, rec) catch {
                self.freeContainer(rec);
                continue;
            };
        }
        for (parsed.value.sites) |s| {
            if (s.host.len == 0 or s.host.len > MAX_HOST or s.container == 0) continue;
            const host = self.allocator.dupe(u8, s.host) catch continue;
            for (host) |*ch| ch.* = std.ascii.toLower(ch.*);
            self.container_sites.append(self.allocator, .{
                .host = host,
                .container = s.container,
            }) catch self.allocator.free(host);
        }
    }

    /// Owned copy of a parsed record, or null if any dupe failed (the
    /// partial allocations are released, never a half-built container).
    fn dupeContainer(self: *WebStore, dto: ContainerDto) ?Container {
        const name = self.allocator.dupe(u8, dto.name) catch return null;
        const jar = self.allocator.dupe(u8, if (dto.jar.len != 0) dto.jar else dto.name) catch {
            self.allocator.free(name);
            return null;
        };
        const eg = self.allocator.dupe(u8, dto.egress_host) catch {
            self.allocator.free(name);
            self.allocator.free(jar);
            return null;
        };
        const rh = self.allocator.dupe(u8, dto.remote_host) catch {
            self.allocator.free(name);
            self.allocator.free(jar);
            self.allocator.free(eg);
            return null;
        };
        return .{
            .id = if (dto.id != 0) dto.id else self.next_container_id,
            .name = name,
            .jar = jar,
            .color = .{
                @truncate(dto.color >> 16),
                @truncate(dto.color >> 8),
                @truncate(dto.color),
            },
            .egress_host = eg,
            .remote_host = rh,
        };
    }

    fn freeContainer(self: *WebStore, ctn: Container) void {
        self.allocator.free(ctn.name);
        self.allocator.free(ctn.jar);
        self.allocator.free(ctn.egress_host);
        self.allocator.free(ctn.remote_host);
    }

    fn saveContainers(self: *WebStore) !void {
        var cdtos = try self.allocator.alloc(ContainerDto, self.containers.items.len);
        defer self.allocator.free(cdtos);
        for (self.containers.items, 0..) |ctn, i| cdtos[i] = .{
            .id = ctn.id,
            .name = ctn.name,
            .jar = ctn.jar,
            .color = (@as(u32, ctn.color[0]) << 16) |
                (@as(u32, ctn.color[1]) << 8) | @as(u32, ctn.color[2]),
            .egress_host = ctn.egress_host,
            .remote_host = ctn.remote_host,
        };
        var sdtos = try self.allocator.alloc(ContainerSiteDto, self.container_sites.items.len);
        defer self.allocator.free(sdtos);
        for (self.container_sites.items, 0..) |s, i| sdtos[i] = .{
            .host = s.host,
            .container = s.container,
        };
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(ContainersDoc{
            .next_id = self.next_container_id,
            .containers = cdtos,
            .sites = sdtos,
        }, .{}, &aw.writer) catch return error.WriteFailed;
        var pb: [4096]u8 = undefined;
        const path = try self.filePath(&pb, "containers.json");
        try writeDurableFile(self.dir, path, aw.writer.buffered());
    }

    pub fn containerFind(self: *WebStore, id: u32) ?*Container {
        for (self.containers.items) |*ctn| {
            if (ctn.id == id) return ctn;
        }
        return null;
    }

    /// Create a container and return its id. `jar` is the stable cache
    /// key handed to the engine; pass "" to seed it from `name`. It is
    /// deliberately NOT derived from the display name at publish time —
    /// the helper's on-disk jar path embeds it, so a rename would
    /// otherwise point a container at a fresh, empty cookie jar.
    pub fn containerAdd(
        self: *WebStore,
        name: []const u8,
        jar: []const u8,
        color: [3]u8,
        egress_host: []const u8,
        remote_host: []const u8,
    ) !u32 {
        if (name.len == 0 or name.len > MAX_CONTAINER_NAME) return error.BadContainer;
        if (jar.len > MAX_CONTAINER_NAME) return error.BadContainer;
        if (egress_host.len > MAX_HOST or remote_host.len > MAX_HOST) return error.BadContainer;
        if (egress_host.len != 0 and remote_host.len != 0) return error.BadContainer;
        const rec = self.dupeContainer(.{
            .id = self.next_container_id,
            .name = name,
            .jar = if (jar.len != 0) jar else name,
            .color = (@as(u32, color[0]) << 16) |
                (@as(u32, color[1]) << 8) | @as(u32, color[2]),
            .egress_host = egress_host,
            .remote_host = remote_host,
        }) orelse return error.OutOfMemory;
        errdefer self.freeContainer(rec);
        try self.containers.append(self.allocator, rec);
        // The append TRANSFERRED ownership, so the errdefer above is no
        // longer allowed to fire while the list still holds `rec`: a
        // failing write (read-only or full state dir) would free the
        // strings the list keeps serving, so the next container_list
        // stringified freed memory onto the wire and `deinit` freed it a
        // second time. Undo the append first, then let the errdefer run.
        self.saveContainers() catch |err| {
            _ = self.containers.pop();
            return err;
        };
        self.next_container_id = rec.id + 1;
        return rec.id;
    }

    /// Rename / recolour / re-route an existing container. The jar key
    /// is immutable, so a rename keeps the cookies.
    pub fn containerUpdate(self: *WebStore, id: u32, upd: ContainerUpdate) !bool {
        const ctn = self.containerFind(id) orelse return false;
        if (upd.name) |n| {
            if (n.len == 0 or n.len > MAX_CONTAINER_NAME) return error.BadContainer;
        }
        if (upd.egress_host) |h| {
            if (h.len > MAX_HOST) return error.BadContainer;
        }
        if (upd.remote_host) |h| {
            if (h.len > MAX_HOST) return error.BadContainer;
        }
        const next_eg = upd.egress_host orelse ctn.egress_host;
        const next_rh = upd.remote_host orelse ctn.remote_host;
        if (next_eg.len != 0 and next_rh.len != 0) return error.BadContainer;

        if (upd.name) |n| {
            const dup = try self.allocator.dupe(u8, n);
            self.allocator.free(ctn.name);
            ctn.name = dup;
        }
        if (upd.color) |rgb| ctn.color = rgb;
        if (upd.egress_host) |h| {
            const dup = try self.allocator.dupe(u8, h);
            self.allocator.free(ctn.egress_host);
            ctn.egress_host = dup;
        }
        if (upd.remote_host) |h| {
            const dup = try self.allocator.dupe(u8, h);
            self.allocator.free(ctn.remote_host);
            ctn.remote_host = dup;
        }
        try self.saveContainers();
        return true;
    }

    /// Forget a container and every site assigned to it. The engine's
    /// on-disk jar is NOT removed here: the daemon does not own the
    /// helper's profile directory (it may be on another host entirely).
    pub fn containerRemove(self: *WebStore, id: u32) !bool {
        for (self.containers.items, 0..) |ctn, i| {
            if (ctn.id != id) continue;
            self.freeContainer(self.containers.orderedRemove(i));
            var k: usize = 0;
            while (k < self.container_sites.items.len) {
                if (self.container_sites.items[k].container == id) {
                    self.allocator.free(self.container_sites.orderedRemove(k).host);
                } else k += 1;
            }
            try self.saveContainers();
            return true;
        }
        return false;
    }

    /// "Always open this host in container X". `container` 0 clears the
    /// assignment; an unknown container id is refused so a stale rule
    /// cannot silently send a site to the default jar.
    pub fn containerSiteSet(self: *WebStore, host: []const u8, container: u32) !void {
        if (host.len == 0 or host.len > MAX_HOST) return error.BadContainer;
        if (container != 0 and self.containerFind(container) == null) return error.NoSuchContainer;
        var hbuf: [MAX_HOST]u8 = undefined;
        for (host, 0..) |ch, i| hbuf[i] = std.ascii.toLower(ch);
        const key = hbuf[0..host.len];
        for (self.container_sites.items, 0..) |*s, i| {
            if (!std.mem.eql(u8, s.host, key)) continue;
            if (container == 0) {
                self.allocator.free(self.container_sites.orderedRemove(i).host);
            } else s.container = container;
            try self.saveContainers();
            return;
        }
        if (container == 0) return; // clearing what is not there
        const h = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(h);
        try self.container_sites.append(self.allocator, .{ .host = h, .container = container });
        // Same ownership handover as `containerAdd`: undo the append
        // before the errdefer is allowed to free `h`.
        self.saveContainers() catch |err| {
            _ = self.container_sites.pop();
            return err;
        };
    }

    /// Container assigned to exactly this host, or null. Matching is
    /// exact on the lowercased host — no parent-domain fallback, so
    /// "mail.example.com" is not governed by an "example.com" rule.
    pub fn containerSiteFor(self: *WebStore, host: []const u8) ?u32 {
        if (host.len == 0 or host.len > MAX_HOST) return null;
        var hbuf: [MAX_HOST]u8 = undefined;
        for (host, 0..) |ch, i| hbuf[i] = std.ascii.toLower(ch);
        const key = hbuf[0..host.len];
        for (self.container_sites.items) |s| {
            if (std.mem.eql(u8, s.host, key)) return s.container;
        }
        return null;
    }
};

// ── tests ───────────────────────────────────────────────────────

test "webstore durable files preserve mode, old bytes, concurrency, and cleanup" {
    const t = std.testing;
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();
    var path_buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/bookmarks.json", .{dir});
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try pathz.pathZ(&path_z_buf, path);

    try writeDurableFile(dir, path, "old-valid");
    var st: c.struct_stat = undefined;
    try t.expect(c.stat(path_z, &st) == 0);
    try t.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(st.st_mode & 0o777)));

    var dir_z_buf: [4096]u8 = undefined;
    const dir_z = try pathz.pathZ(&dir_z_buf, dir);
    try t.expect(c.chmod(dir_z, 0o500) == 0);
    const failed = writeDurableFile(dir, path, "must-not-land");
    try t.expect(c.chmod(dir_z, 0o700) == 0);
    try t.expectError(error.PermissionDenied, failed);
    const retained = readFileAlloc(t.allocator, path, 64) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(retained);
    try t.expectEqualStrings("old-valid", retained);

    const Ctx = struct {
        dir: []const u8,
        path: []const u8,
        bytes: []const u8,
        failed: bool = false,

        fn run(self: *@This()) void {
            writeDurableFile(self.dir, self.path, self.bytes) catch {
                self.failed = true;
            };
        }
    };
    var one = Ctx{ .dir = dir, .path = path, .bytes = "complete-writer-one" };
    var two = Ctx{ .dir = dir, .path = path, .bytes = "complete-writer-two" };
    const first = try std.Thread.spawn(.{}, Ctx.run, .{&one});
    const second = try std.Thread.spawn(.{}, Ctx.run, .{&two});
    first.join();
    second.join();
    try t.expect(!one.failed and !two.failed);
    const final = readFileAlloc(t.allocator, path, 64) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(final);
    try t.expect(std.mem.eql(u8, final, one.bytes) or std.mem.eql(u8, final, two.bytes));

    const dp = c.opendir(dir_z) orelse return error.TestUnexpectedResult;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        try t.expect(std.mem.indexOf(u8, name, ".sketerm-tmp-") == null);
    }
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
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

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
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();
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
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

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
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

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
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

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

test "webstore: userscripts add/enable/remove survive reload" {
    const t = std.testing;
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

    const src = "// ==UserScript==\n// @name A\n// ==/UserScript==\nx();";
    var first: u64 = 0;
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        first = try store.userscriptAdd("A", src);
        _ = try store.userscriptAdd("B", "// ==UserScript==\n// ==/UserScript==\ny();");
        try t.expect(try store.userscriptEnable(first, false));
        try t.expect(!(try store.userscriptEnable(9999, true)));
        try t.expectError(error.BadSource, store.userscriptAdd("empty", ""));
    }
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        try t.expectEqual(@as(usize, 2), store.userscripts.items.len);
        try t.expectEqualStrings("A", store.userscripts.items[0].name);
        try t.expectEqualStrings(src, store.userscripts.items[0].source);
        try t.expect(!store.userscripts.items[0].enabled);
        try t.expect(store.userscripts.items[1].enabled);
        try t.expect(try store.userscriptRemove(first));
        try t.expect(!(try store.userscriptRemove(first)));
    }
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();
    try t.expectEqual(@as(usize, 1), store.userscripts.items.len);
    // Ids never recycle after reload.
    const id = try store.userscriptAdd("C", "z();");
    try t.expect(id > first);
}

test "webstore: userstyles set/replace/delete survive reload" {
    const t = std.testing;
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        try store.userstyleSet("Example.COM", "body{color:red}", true);
        try store.userstyleSet("", "*{cursor:default}", true);
        // Replace + disable in one set.
        try store.userstyleSet("example.com", "body{color:blue}", false);
        // Deleting the absent is a no-op.
        try store.userstyleSet("nobody.test", "", true);
    }
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        try t.expectEqual(@as(usize, 2), store.userstyles.items.len);
        const ex = store.userstyleGet("EXAMPLE.com").?;
        try t.expectEqualStrings("body{color:blue}", ex.css);
        try t.expect(!ex.enabled);
        const glob = store.userstyleGet("").?;
        try t.expectEqualStrings("*{cursor:default}", glob.css);
        // Empty css deletes.
        try store.userstyleSet("example.com", "", true);
        try t.expectEqual(@as(?*const UserStyle, null), store.userstyleGet("example.com"));
    }
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();
    try t.expectEqual(@as(usize, 1), store.userstyles.items.len);
}

test "webstore: site settings merge, clear and survive reload" {
    const t = std.testing;
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

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

test "webstore: containers keep ids, jar keys and colours across reload" {
    const t = std.testing;
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

    var work: u32 = 0;
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        work = try store.containerAdd("Work", "", .{ 0x3b, 0x82, 0xf6 }, "", "");
        _ = try store.containerAdd("Shopping", "", .{ 0x22, 0xc5, 0x5e }, "gate.example", "");
        try t.expect(work != 0);
    }
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        try t.expectEqual(@as(usize, 2), store.containers.items.len);
        // The id is the engine's jar path component: it MUST come back
        // unchanged or the container reopens on an empty cookie jar.
        const c0 = store.containerFind(work) orelse return error.TestUnexpectedResult;
        try t.expectEqualStrings("Work", c0.name);
        try t.expectEqualStrings("Work", c0.jar);
        try t.expectEqual(@as(u8, 0x3b), c0.color[0]);
        try t.expectEqualStrings("gate.example", store.containers.items[1].egress_host);

        // Renaming keeps the jar key, which is what keeps the cookies.
        try t.expect(try store.containerUpdate(work, .{ .name = "Employer", .color = .{ 1, 2, 3 } }));
    }
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();
    const c0 = store.containerFind(work) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("Employer", c0.name);
    try t.expectEqualStrings("Work", c0.jar);
    try t.expectEqual(@as(u8, 2), c0.color[1]);
    // Ids never recycle, even after a removal.
    try t.expect(try store.containerRemove(work));
    try t.expect(store.containerFind(work) == null);
    const fresh = try store.containerAdd("Later", "", .{ 0, 0, 0 }, "", "");
    try t.expect(fresh > work);
}

test "webstore: a container refuses both egress and remote host" {
    const t = std.testing;
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();

    try t.expectError(error.BadContainer, store.containerAdd("Both", "", .{ 0, 0, 0 }, "a.example", "b.example"));
    const id = try store.containerAdd("Egress", "", .{ 0, 0, 0 }, "a.example", "");
    // The exclusion also holds against an UPDATE that would create the
    // combination one field at a time.
    try t.expectError(error.BadContainer, store.containerUpdate(id, .{ .remote_host = "b.example" }));
    try t.expect(try store.containerUpdate(id, .{ .egress_host = "" }));
    try t.expect(try store.containerUpdate(id, .{ .remote_host = "b.example" }));
}

test "webstore: site assignment is exact, clears, and dies with its container" {
    const t = std.testing;
    const td = pathz.TempDir.make("webstore") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

    var work: u32 = 0;
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        work = try store.containerAdd("Work", "", .{ 0, 0, 0 }, "", "");
        try store.containerSiteSet("Example.COM", work);
        // An unknown container must not become a silent default-jar rule.
        try t.expectError(error.NoSuchContainer, store.containerSiteSet("other.example", 4242));
    }
    {
        var store = try WebStore.init(t.allocator, dir);
        defer store.deinit();
        // Host keys are case-normalized on both write and read.
        try t.expectEqual(@as(?u32, work), store.containerSiteFor("example.com"));
        try t.expectEqual(@as(?u32, work), store.containerSiteFor("EXAMPLE.com"));
        // Exact match only: no parent-domain fallback.
        try t.expect(store.containerSiteFor("mail.example.com") == null);
        try store.containerSiteSet("example.com", 0);
        try t.expect(store.containerSiteFor("example.com") == null);

        try store.containerSiteSet("example.com", work);
        try t.expect(try store.containerRemove(work));
        // Removing the container removes its rules, so nothing points at
        // an id that no longer resolves.
        try t.expect(store.containerSiteFor("example.com") == null);
    }
    var store = try WebStore.init(t.allocator, dir);
    defer store.deinit();
    try t.expectEqual(@as(usize, 0), store.container_sites.items.len);
}
