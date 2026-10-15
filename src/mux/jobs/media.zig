//! The batched media metadata job.

const std = @import("std");
const c = @import("../../c.zig").c;
const atomicwrite = @import("../../util/atomicwrite.zig");
const pathz = @import("../../util/pathz.zig");
const fsdrive = @import("../../ipc/fsdrive.zig");
const mediameta = @import("../mediameta.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;
const encodeEvent = fsjob.encodeEvent;
const common = @import("common.zig");
const extIs = common.extIs;
const ffprobeEntries = common.ffprobeEntries;
const pdfinfoText = common.pdfinfoText;

/// Richer selection for media_meta: everything the key namespace maps.
const FFPROBE_META_ENTRIES = "format=duration,bit_rate:format_tags=title,artist,album,album_artist,date,track,genre,composer,comment:stream=codec_type,codec_name,width,height,sample_rate,channels";

// ── media metadata (batched, cached, bounded) ────────────────────
//
// One request names MANY files; one reply carries one match event per
// name. Extraction always runs on the host that owns the file, so only
// the extracted key/value pairs cross the wire - never file bytes and
// never one round trip per row (the inventory's number one complaint
// about remote listings).
//
// Results are cached on the daemon host under the state dir, keyed on
// path + mtime + size, so a re-listed directory costs one fork and no
// re-parsing. Nothing is ever written into the tree being browsed.

/// Wire shape of a batch (separator, cap) is the client library's:
/// one definition, used by both ends.
const MEDIA_SEP = fsdrive.MEDIA_SEP;
const MEDIA_BATCH_MAX = fsdrive.MEDIA_BATCH_MAX;
const MEDIA_HEAD_BYTES: usize = 256 * 1024;
const MEDIA_TAIL_BYTES: usize = 128 * 1024;
/// Total bytes read across one request: a batch of very large files
/// stops early rather than turning a listing into a disk sweep.
const MEDIA_READ_BUDGET: u64 = 64 << 20;
/// Cache file caps. Drop-oldest, rewritten atomically when exceeded.
const MEDIA_CACHE_MAX_BYTES: usize = 4 << 20;
const MEDIA_CACHE_KEEP_LINES: usize = 3000;

const MediaKV = struct { k: []const u8 = "", v: []const u8 = "" };
const MediaRecord = struct {
    key: []const u8 = "",
    kind: []const u8 = "",
    meta: []MediaKV = &.{},
};

/// Where the extraction cache lives on the daemon host.
/// `SKETERM_MEDIA_CACHE_DIR` overrides it (the smokes use that to stay
/// out of the real user state dir).
fn mediaCacheDir(buf: []u8) ?[]const u8 {
    if (c.getenv("SKETERM_MEDIA_CACHE_DIR")) |p| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (s.len > 0) return std.fmt.bufPrint(buf, "{s}", .{s}) catch null;
    }
    if (c.getenv("XDG_STATE_HOME")) |p| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (s.len > 0) return std.fmt.bufPrint(buf, "{s}/sketerm/mediameta", .{s}) catch null;
    }
    if (c.getenv("HOME")) |p| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (s.len > 0) return std.fmt.bufPrint(buf, "{s}/.local/state/sketerm/mediameta", .{s}) catch null;
    }
    return std.fmt.bufPrint(buf, "/tmp/sketerm-mediameta-{d}", .{c.getuid()}) catch null;
}

/// Append-only JSON-lines cache. Later records shadow earlier ones
/// (lookup scans backwards), so a re-extraction after a file change
/// needs no read-modify-write and concurrent job helpers can append
/// with a single write(2) each.
const MediaCache = struct {
    /// Stored as buffer+length, never as a slice: the struct is
    /// returned by value, and a slice into its own buffer would dangle
    /// the moment it moved.
    path_buf: [4096]u8 = undefined,
    path_len: usize = 0,
    data: []u8 = &.{},
    appended: usize = 0,

    fn path(self: *const MediaCache) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn init(allocator: std.mem.Allocator) MediaCache {
        var self = MediaCache{};
        var dir_buf: [4096]u8 = undefined;
        const dir = mediaCacheDir(&dir_buf) orelse return self;
        var path_buf: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/media.jsonl", .{dir}) catch return self;
        pathz.makeParentDirs(p) catch return self;
        @memcpy(self.path_buf[0..p.len], p);
        self.path_len = p.len;
        self.data = readCapped(allocator, p, MEDIA_CACHE_MAX_BYTES) orelse &.{};
        return self;
    }

    fn deinit(self: *MediaCache, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
    }

    /// The newest record line for `key`, or null.
    fn lookup(self: *const MediaCache, key: []const u8) ?[]const u8 {
        var needle_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"key\":\"{s}\"", .{key}) catch return null;
        var rest = self.data;
        var found: ?[]const u8 = null;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const line = rest[0..nl];
            if (std.mem.indexOf(u8, line, needle) != null) found = line;
            rest = if (nl == rest.len) rest[nl..] else rest[nl + 1 ..];
        }
        return found;
    }

    fn appendRecoverable(self: *MediaCache, line: []const u8) void {
        if (self.path_len == 0) return;
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, self.path()) catch return;
        const fd = c.open(p, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c.mode_t, 0o600));
        if (fd < 0) return;
        // One write(2) per record: an interleaved append from another
        // job helper can then never split a line.
        // Failure only drops a cache entry; the next request re-extracts it.
        if (c.write(fd, line.ptr, line.len) != @as(isize, @intCast(line.len))) {
            _ = c.close(fd);
            return;
        }
        _ = c.close(fd);
        self.appended += 1;
    }

    /// Trim the cache back under its cap. A lost race with another
    /// helper's compaction only costs re-extraction, never correctness.
    fn finishRecoverable(self: *MediaCache, allocator: std.mem.Allocator) void {
        if (self.path_len == 0 or self.appended == 0) return;
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, self.path()) catch return;
        var st: c.struct_stat = undefined;
        if (c.stat(p, &st) != 0 or st.st_size <= MEDIA_CACHE_MAX_BYTES) return;
        const all = readCapped(allocator, self.path(), 16 << 20) orelse return;
        defer allocator.free(all);
        var starts: [MEDIA_CACHE_KEEP_LINES]usize = undefined;
        var count: usize = 0;
        var oldest: usize = 0;
        var off: usize = 0;
        while (off < all.len) {
            const nl = std.mem.indexOfScalar(u8, all[off..], '\n') orelse break;
            starts[(oldest + count) % MEDIA_CACHE_KEEP_LINES] = off;
            if (count < MEDIA_CACHE_KEEP_LINES) count += 1 else oldest = (oldest + 1) % MEDIA_CACHE_KEEP_LINES;
            off += nl + 1;
        }
        var compacted: std.ArrayList(u8) = .empty;
        defer compacted.deinit(allocator);
        for (0..count) |i| {
            const start = starts[(oldest + i) % MEDIA_CACHE_KEEP_LINES];
            const nl = std.mem.indexOfScalar(u8, all[start..], '\n') orelse break;
            compacted.appendSlice(allocator, all[start .. start + nl + 1]) catch return;
        }
        atomicwrite.writeCacheFile(self.path(), compacted.items, 0o600) catch return;
    }
};

/// Read at most `cap` bytes of a line-oriented file, keeping the END
/// when it is larger (newest records shadow older ones, so the tail is
/// the half worth having) and dropping the leading partial line.
/// Null on any failure: a broken cache file must degrade to "no cache",
/// never to a failed job.
fn readCapped(allocator: std.mem.Allocator, path: []const u8, cap: usize) ?[]u8 {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return null;
    const fd = c.open(p, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_size <= 0) return null;
    const size: u64 = @intCast(st.st_size);
    const want: usize = @intCast(@min(size, @as(u64, cap)));
    const buf = allocator.alloc(u8, want) catch return null;
    defer allocator.free(buf);
    const got = preadAll(fd, buf, size - want);
    if (got == 0) return null;
    // A window that starts mid-file also starts mid-record.
    const body = if (want < size)
        buf[(std.mem.indexOfScalar(u8, buf[0..got], '\n') orelse return null) + 1 .. got]
    else
        buf[0..got];
    if (body.len == 0) return null;
    // Hand back an exactly-sized allocation: the caller frees the slice
    // it holds, and a short read must not leave that length lying.
    const out = allocator.alloc(u8, body.len) catch return null;
    @memcpy(out, body);
    return out;
}

/// Reusable per-request buffers: allocated once, not once per file.
const MediaBufs = struct {
    head: []u8,
    tail: []u8,
    scratch: []u8,

    fn init(allocator: std.mem.Allocator) !MediaBufs {
        const head = try allocator.alloc(u8, MEDIA_HEAD_BYTES);
        errdefer allocator.free(head);
        const tail = try allocator.alloc(u8, MEDIA_TAIL_BYTES);
        errdefer allocator.free(tail);
        const scratch = try allocator.alloc(u8, MEDIA_HEAD_BYTES);
        return .{ .head = head, .tail = tail, .scratch = scratch };
    }

    fn deinit(self: *MediaBufs, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
        allocator.free(self.tail);
        allocator.free(self.scratch);
    }
};

fn emitMediaSkip(job: *const Job, path: []const u8, reason: []const u8) void {
    job.emit(.{
        .ev = "match",
        .path = path,
        .kind = "unknown",
        .cached = false,
        .text = reason,
        .meta = &[_]MediaKV{},
    });
}

pub fn runMediaMeta(job: *const Job) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    if (spec.pattern.len == 0) return job.emitError("media_meta needs at least one name");
    var bufs = MediaBufs.init(allocator) catch return job.emitError("out of memory");
    defer bufs.deinit(allocator);
    var cache = MediaCache.init(allocator);
    defer cache.deinit(allocator);

    var budget: u64 = MEDIA_READ_BUDGET;
    var done: u64 = 0;
    var truncated = false;
    var it = std.mem.splitScalar(u8, spec.pattern, MEDIA_SEP);
    while (it.next()) |name| {
        if (name.len == 0) continue;
        if (done >= MEDIA_BATCH_MAX or budget == 0) {
            truncated = true;
            break;
        }
        var path_buf: [4096]u8 = undefined;
        const full = if (name[0] == '/')
            name
        else if (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ if (spec.src.len == 1) "" else spec.src, name })) |joined|
            joined
        else |_| {
            emitMediaSkip(job, name, "path too long");
            done += 1;
            continue;
        };
        mediaOne(job, &bufs, &cache, full, &budget);
        done += 1;
    }
    cache.finishRecoverable(allocator);
    job.emit(.{ .ev = "done", .done = done, .total = done, .matches = done, .truncated = truncated });
    return 0;
}

fn mediaOne(job: *const Job, bufs: *MediaBufs, cache: *MediaCache, full: []const u8, budget: *u64) void {
    const allocator = job.allocator;
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{full}) catch return emitMediaSkip(job, full, "path too long");
    var st: c.struct_stat = undefined;
    if (c.stat(p.ptr, &st) != 0) return emitMediaSkip(job, full, "cannot stat");
    if ((st.st_mode & c.S_IFMT) != c.S_IFREG) return emitMediaSkip(job, full, "not a regular file");
    const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;
    if (size == 0) return emitMediaSkip(job, full, "empty file");

    // Identity that changes whenever the bytes could have: a cache hit
    // on a modified file is the bug this key exists to prevent.
    const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
    var hasher = Sha256.init(.{});
    hasher.update(full);
    var idbuf: [64]u8 = undefined;
    hasher.update(std.fmt.bufPrint(&idbuf, "\x00{d}.{d}\x00{d}", .{ @as(i64, ts.tv_sec), @as(i64, @intCast(ts.tv_nsec)), size }) catch return emitMediaSkip(job, full, "identity"));
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    var key: [16]u8 = undefined;
    for (digest[0..8], 0..) |b, i| {
        _ = std.fmt.bufPrint(key[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    }

    if (cache.lookup(&key)) |line| {
        const parsed = std.json.parseFromSlice(MediaRecord, allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch null;
        if (parsed) |rec| {
            defer rec.deinit();
            job.emit(.{ .ev = "match", .path = full, .kind = rec.value.kind, .cached = true, .text = "", .meta = rec.value.meta });
            return;
        }
    }

    const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return emitMediaSkip(job, full, "cannot open");
    defer _ = c.close(fd);
    const head_want: usize = @intCast(@min(size, @as(u64, MEDIA_HEAD_BYTES)));
    const tail_want: usize = @intCast(@min(size, @as(u64, MEDIA_TAIL_BYTES)));
    const head_n = preadAll(fd, bufs.head[0..head_want], 0);
    const tail_n = preadAll(fd, bufs.tail[0..tail_want], size - tail_want);
    budget.* -|= @as(u64, head_n) + tail_n;

    var m = mediameta.extract(.{
        .head = bufs.head[0..head_n],
        .tail = bufs.tail[0..tail_n],
        .size = size,
        .name = std.fs.path.basename(full),
        .scratch = bufs.scratch,
    });
    mediaExternal(&m, p.ptr, full);

    var kvs: [mediameta.MAX_FIELDS]MediaKV = undefined;
    for (0..m.count) |i| kvs[i] = .{ .k = m.keyAt(i), .v = m.value(i) };
    const fields = kvs[0..m.count];
    job.emit(.{ .ev = "match", .path = full, .kind = m.kind.name(), .cached = false, .text = "", .meta = fields });

    var line_buf: [8192]u8 = undefined;
    if (encodeEvent(&line_buf, MediaRecord{ .key = &key, .kind = m.kind.name(), .meta = fields })) |line|
        cache.appendRecoverable(line);
}

fn preadAll(fd: c_int, buf: []u8, off: u64) usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.pread(fd, buf.ptr + got, buf.len - got, @intCast(off + got));
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        got += @intCast(n);
    }
    return got;
}

const MEDIA_PROBE_EXTS = [_][]const u8{
    ".mp4", ".m4v",  ".mkv", ".webm", ".avi", ".mov", ".mpeg", ".mpg", ".wmv",  ".flv",
    ".ts",  ".m2ts", ".3gp", ".mp3",  ".m4a", ".aac", ".ogg",  ".oga", ".opus", ".flac",
    ".wav", ".wma",  ".ape", ".aiff", ".aif", ".mka",
};

/// Fill what the pure-Zig parsers could not from an external probe,
/// when the host actually has one. `Meta.put` is first-wins, so a
/// parsed value is never overwritten by a probed one.
fn mediaExternal(m: *mediameta.Meta, source: [*:0]const u8, name: []const u8) void {
    if (std.mem.eql(u8, m.get("media.format") orelse "", "pdf")) {
        var out: [4096]u8 = undefined;
        const n = pdfinfoText(source, &out);
        if (n > 0) applyPdfinfo(m, out[0..n]);
        return;
    }
    const wanted = switch (m.kind) {
        .video => !m.has("media.duration_ms") or !m.has("media.width"),
        .audio => !m.has("media.duration_ms"),
        .unknown => extIs(name, &MEDIA_PROBE_EXTS),
        else => false,
    };
    if (!wanted) return;
    var out: [8192]u8 = undefined;
    const n = ffprobeEntries(source, FFPROBE_META_ENTRIES, &out);
    if (n > 0) applyFfprobe(m, out[0..n]);
}

fn applyFfprobe(m: *mediameta.Meta, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (value.len == 0 or std.mem.eql(u8, value, "N/A") or std.mem.eql(u8, value, "unknown")) continue;
        if (std.mem.eql(u8, key, "duration")) {
            const secs = std.fmt.parseFloat(f64, value) catch continue;
            if (secs > 0 and secs < 30.0 * 24 * 3600) m.putInt("media.duration_ms", @intFromFloat(secs * 1000));
        } else if (std.mem.eql(u8, key, "bit_rate")) {
            const bps = std.fmt.parseInt(u64, value, 10) catch continue;
            m.putInt("media.bitrate_kbps", bps / 1000);
        } else if (std.mem.eql(u8, key, "width")) {
            mediaPutNumber(m, "media.width", value, 1 << 20);
        } else if (std.mem.eql(u8, key, "height")) {
            mediaPutNumber(m, "media.height", value, 1 << 20);
        } else if (std.mem.eql(u8, key, "sample_rate")) {
            mediaPutNumber(m, "media.sample_rate", value, 3_000_000);
        } else if (std.mem.eql(u8, key, "channels")) {
            mediaPutNumber(m, "media.channels", value, 64);
        } else if (std.mem.eql(u8, key, "codec_name")) {
            m.put("media.codec", value);
        } else if (std.mem.eql(u8, key, "codec_type")) {
            if (m.kind == .unknown) {
                if (std.mem.eql(u8, value, "video")) m.kind = .video;
                if (std.mem.eql(u8, value, "audio")) m.kind = .audio;
            }
        } else if (std.mem.startsWith(u8, key, "TAG:")) {
            applyProbeTag(m, key[4..], value);
        }
    }
    if (m.kind != .unknown) m.put("media.kind", m.kind.name());
}

fn mediaPutNumber(m: *mediameta.Meta, key: []const u8, value: []const u8, max: u64) void {
    const n = std.fmt.parseInt(u64, value, 10) catch return;
    if (n == 0 or n > max) return;
    m.putInt(key, n);
}

fn applyProbeTag(m: *mediameta.Meta, name: []const u8, value: []const u8) void {
    var lower_buf: [32]u8 = undefined;
    if (name.len > lower_buf.len) return;
    for (name, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const lower = lower_buf[0..name.len];
    const table = [_]struct { name: []const u8, key: []const u8 }{
        .{ .name = "title", .key = "tag.title" },
        .{ .name = "artist", .key = "tag.artist" },
        .{ .name = "album", .key = "tag.album" },
        .{ .name = "album_artist", .key = "tag.album_artist" },
        .{ .name = "composer", .key = "tag.composer" },
        .{ .name = "genre", .key = "tag.genre" },
        .{ .name = "track", .key = "tag.track" },
        .{ .name = "comment", .key = "tag.comment" },
    };
    for (table) |row| {
        if (!std.mem.eql(u8, row.name, lower)) continue;
        if (std.mem.eql(u8, row.key, "tag.track")) {
            const slash = std.mem.indexOfScalar(u8, value, '/');
            m.put(row.key, if (slash) |s| value[0..s] else value);
        } else {
            m.put(row.key, value);
        }
        return;
    }
    if (std.mem.eql(u8, lower, "date") and value.len >= 4) m.put("tag.year", value[0..4]);
}

fn applyPdfinfo(m: *mediameta.Meta, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const key = std.mem.trim(u8, raw[0..colon], " \t\r");
        const value = std.mem.trim(u8, raw[colon + 1 ..], " \t\r");
        if (value.len == 0) continue;
        if (std.mem.eql(u8, key, "Pages")) {
            mediaPutNumber(m, "doc.pages", value, 1 << 24);
        } else if (std.mem.eql(u8, key, "Title")) {
            m.put("doc.title", value);
        } else if (std.mem.eql(u8, key, "Author")) {
            m.put("doc.author", value);
        } else if (std.mem.eql(u8, key, "Producer")) {
            m.put("doc.producer", value);
        } else if (std.mem.eql(u8, key, "Page size")) {
            m.put("doc.page_size", value);
        }
    }
}

test "media cache: newest record for a key wins" {
    const t = std.testing;
    var cache = MediaCache{};
    const lines =
        "{\"key\":\"aaaa\",\"kind\":\"image\",\"meta\":[{\"k\":\"media.width\",\"v\":\"1\"}]}\n" ++
        "{\"key\":\"bbbb\",\"kind\":\"audio\",\"meta\":[]}\n" ++
        "{\"key\":\"aaaa\",\"kind\":\"image\",\"meta\":[{\"k\":\"media.width\",\"v\":\"2\"}]}\n";
    const buf = try t.allocator.dupe(u8, lines);
    defer t.allocator.free(buf);
    cache.data = buf;
    const hit = cache.lookup("aaaa") orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, hit, "\"v\":\"2\"") != null);
    try t.expect(cache.lookup("cccc") == null);
}

test "media cache read keeps the newest lines and drops a partial record" {
    const t = std.testing;
    const td = pathz.TempDir.make("fsjob-mm") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();
    var pbuf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/lines", .{dir});
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, path), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        const body = "AAAAAAAAAA\nBBBBBBBBBB\nCCCCCCCCCC\n";
        try t.expect(c.fwrite(body, 1, body.len, f) == body.len);
    }
    // A 16-byte window lands mid-record; the fragment must be dropped.
    const capped = readCapped(t.allocator, path, 16) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(capped);
    try t.expectEqualStrings("CCCCCCCCCC\n", capped);
    const whole = readCapped(t.allocator, path, 4096) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(whole);
    try t.expectEqualStrings("AAAAAAAAAA\nBBBBBBBBBB\nCCCCCCCCCC\n", whole);
}

test "ffprobe fallback fills only what the parsers left empty" {
    const t = std.testing;
    var m = mediameta.Meta{};
    m.kind = .video;
    m.put("media.width", "1920"); // already known: must survive
    applyFfprobe(&m,
        \\codec_type=video
        \\codec_name=h264
        \\width=640
        \\height=360
        \\duration=12.500000
        \\bit_rate=800000
        \\TAG:title=Probe Title
        \\TAG:date=2020-04-05
        \\TAG:track=3/9
        \\TAG:album=N/A
        \\
    );
    try t.expectEqualStrings("1920", m.get("media.width").?);
    try t.expectEqualStrings("360", m.get("media.height").?);
    try t.expectEqualStrings("12500", m.get("media.duration_ms").?);
    try t.expectEqualStrings("800", m.get("media.bitrate_kbps").?);
    try t.expectEqualStrings("h264", m.get("media.codec").?);
    try t.expectEqualStrings("Probe Title", m.get("tag.title").?);
    try t.expectEqualStrings("2020", m.get("tag.year").?);
    try t.expectEqualStrings("3", m.get("tag.track").?);
    // "N/A" is ffprobe for "absent", not a value.
    try t.expect(!m.has("tag.album"));
}

test "pdfinfo fallback maps the document keys" {
    const t = std.testing;
    var m = mediameta.Meta{};
    m.kind = .document;
    applyPdfinfo(&m,
        \\Title:          Handbook
        \\Author:         A. Writer
        \\Producer:       pdfTeX
        \\Pages:          42
        \\Page size:      595 x 842 pts (A4)
        \\Encrypted:      no
        \\
    );
    try t.expectEqualStrings("42", m.get("doc.pages").?);
    try t.expectEqualStrings("Handbook", m.get("doc.title").?);
    try t.expectEqualStrings("A. Writer", m.get("doc.author").?);
    try t.expectEqualStrings("pdfTeX", m.get("doc.producer").?);
    try t.expectEqualStrings("595 x 842 pts (A4)", m.get("doc.page_size").?);
}
