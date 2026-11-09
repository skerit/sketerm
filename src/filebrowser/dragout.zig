//! Pure rules for handing browser entries to drop targets: the
//! in-sketerm specs flavor, and the local staging of remote entries
//! that other applications receive as file:// URIs.

const std = @import("std");
const appendAlwaysQuoted = @import("../util/shellquote.zig").appendAlwaysQuoted;

/// MIME type of the in-sketerm drag flavor. Sketerm's own drop targets
/// prefer it over text/uri-list, so a drag between sketerm surfaces
/// (even across processes) keeps host-qualified specs and never makes
/// the source fetch remote files.
pub const SPECS_MIME = "application/x-sketerm-drag-specs";

pub const Kind = enum(u8) { file = 'f', dir = 'd' };

/// One entry of the specs flavor.
pub const Record = struct {
    kind: Kind,
    /// `host:/path` for a remote entry, a bare absolute path for a local one.
    spec: []const u8,
};

/// Encode one record as its kind byte followed by the spec, NUL-terminated.
pub fn encodeRecord(allocator: std.mem.Allocator, kind: Kind, spec: []const u8) ![:0]u8 {
    const out = try allocator.allocSentinel(u8, spec.len + 1, 0);
    out[0] = @intFromEnum(kind);
    @memcpy(out[1..], spec);
    return out;
}

/// @return null for an empty record or an unknown kind byte.
pub fn decodeRecord(raw: []const u8) ?Record {
    if (raw.len < 2) return null;
    const kind = std.enums.fromInt(Kind, raw[0]) orelse return null;
    return .{ .kind = kind, .spec = raw[1..] };
}

/// Iterate the serialized flavor: records each terminated by NUL. A
/// trailing record without its NUL still counts; malformed ones are skipped.
pub const Records = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(self: *Records) ?Record {
        while (self.pos < self.bytes.len) {
            const rest = self.bytes[self.pos..];
            const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
            self.pos += end + 1;
            if (decodeRecord(rest[0..end])) |rec| return rec;
        }
        return null;
    }
};

/// Append `specs` as the plain-text flavor carries them: each spec one
/// single-quoted shell word, words separated by one space.
pub fn appendQuotedSpecs(list: *std.ArrayList(u8), allocator: std.mem.Allocator, specs: anytype) !void {
    for (specs, 0..) |spec, i| {
        if (i > 0) try list.append(allocator, ' ');
        try appendAlwaysQuoted(list, allocator, spec);
    }
}

/// Prefix of every staging directory under the drag cache root; the
/// sweep matches only names carrying it.
pub const STAGE_PREFIX = "drag-";

/// Staged copies older than this are swept. Long on purpose: a chat
/// client uploads the dropped file asynchronously, after the drop.
pub const STAGE_TTL_SECS: i64 = 24 * 3600;

/// A finished fetch is handed to a later drag of the same unchanged
/// file for this long (a receiver that timed out the first time gets
/// the file instantly on the retry).
pub const REUSE_MS: i64 = 3600 * 1000;

/// The name a staged copy carries: the source's own basename, so the
/// receiver uploads `report.pdf`, not a cache name.
pub fn stagedName(path: []const u8, host: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (base.len > 0 and !std.mem.eql(u8, base, ".") and !std.mem.eql(u8, base, "..")) return base;
    // A host root has no basename; name it after the host when that is
    // a usable file name.
    if (host.len > 0 and std.mem.indexOfScalar(u8, host, '/') == null and
        !std.mem.eql(u8, host, ".") and !std.mem.eql(u8, host, "..")) return host;
    return "item";
}

/// One fetch's staging directory name, unique per process and call.
pub fn stageDirName(buf: []u8, pid: i64, stamp_us: i64, seq: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, STAGE_PREFIX ++ "{d}-{d}-{d}", .{ pid, stamp_us, seq });
}

/// What a listing said about a remote entry when it was dragged.
pub const Fingerprint = struct {
    size: u64,
    mtime_ms: i64,
    is_dir: bool,

    pub fn eql(a: Fingerprint, b: Fingerprint) bool {
        return a.size == b.size and a.mtime_ms == b.mtime_ms and a.is_dir == b.is_dir;
    }
};

/// Whether a finished fetch may serve a new drag instead of a re-fetch.
/// Directories never qualify: their mtime does not cover changes deeper
/// in the tree, so a reused copy could be silently stale.
pub fn reusable(staged: Fingerprint, dragged: Fingerprint, finished_ms: i64, now_ms: i64) bool {
    if (staged.is_dir or dragged.is_dir) return false;
    if (!staged.eql(dragged)) return false;
    if (dragged.mtime_ms == 0) return false;
    return now_ms >= finished_ms and now_ms - finished_ms < REUSE_MS;
}

/// Largest total size of remote files a clipboard copy hands other
/// applications as files. Clipboard managers (KDE's Klipper among them)
/// read text/uri-list on EVERY clipboard change, and a remote entry is
/// fetched when its URI is read, so this caps the download a plain
/// Ctrl+C can cause without anyone pasting. A drag has no cap: only a
/// drop asks for its files.
pub const CLIP_STAGE_MAX_BYTES: u64 = 64 * 1024 * 1024;

/// What a clipboard copy offers other applications.
pub const ClipOffer = enum {
    /// Files (text/uri-list, GNOME copied-files, the portal types).
    files,
    /// Path text only: a remote directory's size is unknown.
    text_remote_dir,
    /// Path text only: the remote files exceed `CLIP_STAGE_MAX_BYTES`.
    text_too_large,
    /// Path text only: no listing facts say how big an entry is.
    text_unknown_size,
};

/// The offer for a copy of `remote` entries described by `fps`; a local
/// copy always offers files, since nothing is fetched for it.
pub fn clipOffer(remote: bool, fps: []const Fingerprint) ClipOffer {
    if (!remote) return .files;
    var total: u64 = 0;
    for (fps) |fp| {
        if (fp.is_dir) return .text_remote_dir;
        if (fp.mtime_ms == 0) return .text_unknown_size;
        total +|= fp.size;
    }
    return if (total > CLIP_STAGE_MAX_BYTES) .text_too_large else .files;
}

/// Whether other applications are told a copy is a cut. Never for remote
/// entries: they receive a staged copy, and a receiver moving that copy
/// must not read as the original having moved.
pub fn externalCut(cut: bool, remote: bool) bool {
    return cut and !remote;
}

/// A specs-flavor record marking a clipboard cut. Its first byte is no
/// `Kind`, so `Records` (and every older reader) skips it.
pub const CUT_RECORD = "~cut";

/// Whether the serialized specs flavor carries `CUT_RECORD`.
pub fn hasCutRecord(bytes: []const u8) bool {
    var it = std.mem.splitScalar(u8, bytes, 0);
    while (it.next()) |raw| if (std.mem.eql(u8, raw, CUT_RECORD)) return true;
    return false;
}

/// Append the x-special/gnome-copied-files payload: the verb line, then
/// one URI per line, no trailing newline (Nautilus's own spelling).
pub fn appendGnomeCopied(list: *std.ArrayList(u8), allocator: std.mem.Allocator, cut: bool, uris: anytype) !void {
    try list.appendSlice(allocator, if (cut) "cut" else "copy");
    for (uris) |uri| {
        try list.append(allocator, '\n');
        try list.appendSlice(allocator, uri);
    }
}

test "spec records round-trip through the serialized flavor" {
    const t = std.testing;
    const a = t.allocator;
    const one = try encodeRecord(a, .file, "box:/srv/it's here.txt");
    defer a.free(one);
    const two = try encodeRecord(a, .dir, "/home/me/dir");
    defer a.free(two);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, one);
    try wire.append(a, 0);
    // An unknown kind byte and an empty record are skipped, not fatal.
    try wire.appendSlice(a, "xjunk\x00\x00");
    try wire.appendSlice(a, two);
    var it: Records = .{ .bytes = wire.items };
    const r1 = it.next().?;
    try t.expectEqual(Kind.file, r1.kind);
    try t.expectEqualStrings("box:/srv/it's here.txt", r1.spec);
    const r2 = it.next().?;
    try t.expectEqual(Kind.dir, r2.kind);
    try t.expectEqualStrings("/home/me/dir", r2.spec);
    try t.expect(it.next() == null);
}

test "quoted specs match the plain-text drag flavor" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const specs = [_][]const u8{ "/a b", "box:/it's" };
    try appendQuotedSpecs(&out, a, &specs);
    try std.testing.expectEqualStrings("'/a b' 'box:/it'\\''s'", out.items);
}

test "staged copies keep the source's basename" {
    const t = std.testing;
    try t.expectEqualStrings("report.pdf", stagedName("/srv/x/report.pdf", "box"));
    try t.expectEqualStrings("dir", stagedName("/srv/dir/", "box"));
    try t.expectEqualStrings("box", stagedName("/", "box"));
    try t.expectEqualStrings("item", stagedName("/", "a/b"));
    try t.expectEqualStrings("item", stagedName("/", ""));
    var buf: [64]u8 = undefined;
    const name = try stageDirName(&buf, 42, 1000, 3);
    try t.expectEqualStrings("drag-42-1000-3", name);
    try t.expect(std.mem.startsWith(u8, name, STAGE_PREFIX));
}

test "a finished fetch is reused only for the same unchanged file within the window" {
    const t = std.testing;
    const f: Fingerprint = .{ .size = 10, .mtime_ms = 5000, .is_dir = false };
    try t.expect(reusable(f, f, 1000, 1000 + REUSE_MS - 1));
    try t.expect(!reusable(f, f, 1000, 1000 + REUSE_MS));
    try t.expect(!reusable(f, .{ .size = 11, .mtime_ms = 5000, .is_dir = false }, 1000, 2000));
    try t.expect(!reusable(f, .{ .size = 10, .mtime_ms = 5001, .is_dir = false }, 1000, 2000));
    const d: Fingerprint = .{ .size = 0, .mtime_ms = 5000, .is_dir = true };
    try t.expect(!reusable(d, d, 1000, 2000));
    // No listing facts (a search hit without metadata): never reuse.
    const unknown: Fingerprint = .{ .size = 0, .mtime_ms = 0, .is_dir = false };
    try t.expect(!reusable(unknown, unknown, 1000, 2000));
}

test "clipboard offers files only for remote copies a manager may read cheaply" {
    const t = std.testing;
    const small: Fingerprint = .{ .size = 10, .mtime_ms = 5000, .is_dir = false };
    const dir: Fingerprint = .{ .size = 0, .mtime_ms = 5000, .is_dir = true };
    const unknown: Fingerprint = .{ .size = 0, .mtime_ms = 0, .is_dir = false };
    // Local copies are never fetched, so size does not matter.
    try t.expectEqual(ClipOffer.files, clipOffer(false, &.{ dir, unknown, .{ .size = std.math.maxInt(u64), .mtime_ms = 1, .is_dir = false } }));
    try t.expectEqual(ClipOffer.files, clipOffer(true, &.{ small, small }));
    try t.expectEqual(ClipOffer.text_remote_dir, clipOffer(true, &.{ small, dir }));
    try t.expectEqual(ClipOffer.text_unknown_size, clipOffer(true, &.{unknown}));
    // The cap is inclusive and counts the whole selection.
    const half: Fingerprint = .{ .size = CLIP_STAGE_MAX_BYTES / 2, .mtime_ms = 1, .is_dir = false };
    try t.expectEqual(ClipOffer.files, clipOffer(true, &.{ half, half }));
    try t.expectEqual(ClipOffer.text_too_large, clipOffer(true, &.{ half, half, small }));
    // Saturating: sizes near the top of u64 cannot wrap back under the cap.
    const huge: Fingerprint = .{ .size = std.math.maxInt(u64), .mtime_ms = 1, .is_dir = false };
    try t.expectEqual(ClipOffer.text_too_large, clipOffer(true, &.{ huge, huge }));
}

test "remote cuts reach other applications as copies" {
    const t = std.testing;
    try t.expect(externalCut(true, false));
    try t.expect(!externalCut(true, true));
    try t.expect(!externalCut(false, false));
    try t.expect(!externalCut(false, true));
}

test "the cut record rides the specs flavor without disturbing its records" {
    const t = std.testing;
    const a = t.allocator;
    const rec = try encodeRecord(a, .file, "box:/srv/a");
    defer a.free(rec);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, rec);
    try wire.append(a, 0);
    try t.expect(!hasCutRecord(wire.items));
    try wire.appendSlice(a, CUT_RECORD ++ "\x00");
    try t.expect(hasCutRecord(wire.items));
    var it: Records = .{ .bytes = wire.items };
    try t.expectEqualStrings("box:/srv/a", it.next().?.spec);
    try t.expect(it.next() == null);
    // A spec that merely contains the marker text is not a cut.
    try t.expect(!hasCutRecord("f/x/~cut\x00"));
}

test "GNOME copied-files payload spells the verb and LF-separated URIs" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendGnomeCopied(&out, a, false, &[_][]const u8{ "file:///a%20b", "file:///c" });
    try std.testing.expectEqualStrings("copy\nfile:///a%20b\nfile:///c", out.items);
    out.clearRetainingCapacity();
    try appendGnomeCopied(&out, a, true, &[_][]const u8{"file:///x"});
    try std.testing.expectEqualStrings("cut\nfile:///x", out.items);
}
