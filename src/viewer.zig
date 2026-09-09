//! GTK-free resource, invocation and viewport state for Sketerm Viewer.

const std = @import("std");
const c = @import("c.zig").c;
const entry = @import("filebrowser/entry.zig");
const paths = @import("filebrowser/paths.zig");
const platform = @import("util/platform.zig");
const invocation = @import("util/invocation.zig");
const format = @import("filebrowser/format.zig");
const clock = @import("util/clock.zig");

pub const ID_SUFFIX = ".viewer";
pub const APP_NAME = "Sketerm Viewer";
pub const BINARY_NAME = "sketerm-viewer";
pub const MANIFEST_OPTION = "--consume-batch=";
const MANIFEST_MAGIC = "SKVIEW1\x00";
const MANIFEST_HEADER = MANIFEST_MAGIC.len + @sizeOf(u64);
const MANIFEST_MAX_BYTES: usize = 64 << 20;
pub const MANIFEST_PREFIX = "viewer-batch-";

/// What the Viewer shows for a resource, decided by file name alone.
/// Anything the daemon's preview codecs can rasterize (images, pdf,
/// video, audio art) stays on the image pipeline; `.text` is the
/// universal fallback (bounded UTF-8 head or hex dump), so any file
/// opens instead of erroring.
pub const ContentKind = enum { image, cast, text };

pub fn contentKind(name: []const u8) ContentKind {
    return switch (paths.classify(name)) {
        .cast => .cast,
        .media => .image,
        .text => .text,
    };
}

pub const Resource = struct {
    spec: []const u8,
    host: ?[]const u8,
    path: []const u8,

    pub fn parse(spec: []const u8) Resource {
        const loc = paths.parseSpec(spec);
        return .{ .spec = spec, .host = loc.host, .path = loc.path };
    }

    pub fn name(self: Resource) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

pub const Batch = struct {
    allocator: std.mem.Allocator,
    specs: [][]u8,
    initial_index: usize = 0,

    pub fn deinit(self: *Batch) void {
        for (self.specs) |spec| self.allocator.free(spec);
        if (self.specs.len > 0) self.allocator.free(self.specs);
        self.specs = &.{};
    }

    pub fn empty(allocator: std.mem.Allocator) Batch {
        return .{ .allocator = allocator, .specs = &.{} };
    }
};

/// Encode an ordered batch for bounded handoff between Files and Viewer.
pub fn encodeManifest(allocator: std.mem.Allocator, specs: anytype, initial_index: usize) ![]u8 {
    var total: usize = MANIFEST_HEADER;
    for (specs) |spec| {
        total = std.math.add(usize, total, spec.len + 1) catch return error.ManifestTooLarge;
        if (total > MANIFEST_MAX_BYTES) return error.ManifestTooLarge;
    }
    const bytes = try allocator.alloc(u8, total);
    @memcpy(bytes[0..MANIFEST_MAGIC.len], MANIFEST_MAGIC);
    std.mem.writeInt(u64, bytes[MANIFEST_MAGIC.len..MANIFEST_HEADER], @intCast(initial_index), .little);
    var at: usize = MANIFEST_HEADER;
    for (specs) |spec| {
        @memcpy(bytes[at..][0..spec.len], spec);
        at += spec.len;
        bytes[at] = 0;
        at += 1;
    }
    return bytes;
}

/// Decode a Viewer batch manifest into independently owned specs.
pub fn decodeManifest(allocator: std.mem.Allocator, bytes: []const u8) !Batch {
    if (bytes.len < MANIFEST_HEADER or bytes.len > MANIFEST_MAX_BYTES or
        !std.mem.eql(u8, bytes[0..MANIFEST_MAGIC.len], MANIFEST_MAGIC)) return error.InvalidManifest;
    const body = bytes[MANIFEST_HEADER..];
    if (body.len > 0 and body[body.len - 1] != 0) return error.InvalidManifest;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, body, 0);
    while (it.next()) |spec| if (spec.len > 0) {
        count += 1;
    };
    const specs: [][]u8 = if (count == 0) &.{} else try allocator.alloc([]u8, count);
    errdefer if (count > 0) allocator.free(specs);
    var filled: usize = 0;
    errdefer for (specs[0..filled]) |spec| allocator.free(spec);
    it = std.mem.splitScalar(u8, body, 0);
    while (it.next()) |spec| {
        if (spec.len == 0) continue;
        specs[filled] = try allocator.dupe(u8, spec);
        filled += 1;
    }
    const raw_initial = std.mem.readInt(u64, bytes[MANIFEST_MAGIC.len..MANIFEST_HEADER], .little);
    const initial_index: usize = if (count == 0)
        0
    else if (raw_initial >= @as(u64, @intCast(count)))
        count - 1
    else
        @intCast(raw_initial);
    return .{
        .allocator = allocator,
        .specs = specs,
        .initial_index = initial_index,
    };
}

/// Return a verified private directory for Viewer handoff manifests.
pub fn ensureManifestDirectory(out: *[4096:0]u8) ?[:0]const u8 {
    const dir = std.fmt.bufPrintZ(out, "{s}/sketerm-viewer-batches-{d}", .{ platform.runtimeDir(), c.geteuid() }) catch return null;
    const mkdir_rc = c.mkdir(dir.ptr, @as(c.mode_t, 0o700));
    if (mkdir_rc != 0 and std.posix.errno(mkdir_rc) != .EXIST) return null;
    if (mkdir_rc == 0) _ = c.chmod(dir.ptr, @as(c.mode_t, 0o700));
    var st: c.struct_stat = undefined;
    if (c.lstat(dir.ptr, &st) != 0 or
        st.st_uid != c.geteuid() or
        (st.st_mode & c.S_IFMT) != c.S_IFDIR or
        (st.st_mode & 0o777) != 0o700) return null;
    return dir;
}

fn manifestPathAllowed(path: []const u8, directory: []const u8) bool {
    const dirname = std.fs.path.dirname(path) orelse return false;
    const basename = std.fs.path.basename(path);
    return std.mem.eql(u8, dirname, directory) and
        std.mem.startsWith(u8, basename, MANIFEST_PREFIX) and
        std.mem.indexOfScalar(u8, basename, '/') == null;
}

fn consumeManifest(allocator: std.mem.Allocator, path: []const u8) !Batch {
    if (path.len == 0 or path.len >= 4096) return error.InvalidManifest;
    var directory_buf: [4096:0]u8 = undefined;
    const directory = ensureManifestDirectory(&directory_buf) orelse return error.InvalidManifest;
    if (!manifestPathAllowed(path, directory)) return error.InvalidManifest;
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    const nofollow = if (comptime @hasDecl(c, "O_NOFOLLOW")) c.O_NOFOLLOW else 0;
    const nonblock = if (comptime @hasDecl(c, "O_NONBLOCK")) c.O_NONBLOCK else 0;
    const fd = c.open(path_z.ptr, c.O_RDONLY | c.O_CLOEXEC | nofollow | nonblock);
    if (fd < 0) return error.ManifestOpenFailed;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or
        st.st_uid != c.geteuid() or
        (st.st_mode & c.S_IFMT) != c.S_IFREG or
        (st.st_mode & 0o777) != 0o600 or
        st.st_nlink != 1 or
        st.st_size < 0) return error.InvalidManifest;
    // The path and opened inode are now known to be the private regular
    // file our producer creates, so unlink before parsing for crash safety.
    _ = c.unlink(path_z.ptr);
    const size: usize = @intCast(st.st_size);
    if (size > MANIFEST_MAX_BYTES) return error.InvalidManifest;
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.read(fd, bytes.ptr + at, bytes.len - at);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.InvalidManifest;
        at += @intCast(n);
    }
    return decodeManifest(allocator, bytes);
}

/// Index of the first viewer argument, or null for another entry point.
pub fn invocationStart(args: []const []const u8) ?usize {
    return invocation.start(args, BINARY_NAME, &.{ "view", "viewer" });
}

/// Canonicalize all positional viewer arguments into host-qualified specs.
pub fn collect(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !Batch {
    const start = invocationStart(args) orelse return error.NotViewerInvocation;
    var parse_options = true;
    for (args[start..]) |arg| {
        if (parse_options and std.mem.eql(u8, arg, "--")) {
            parse_options = false;
            continue;
        }
        if (parse_options and std.mem.startsWith(u8, arg, MANIFEST_OPTION))
            return consumeManifest(allocator, arg[MANIFEST_OPTION.len..]);
    }
    var out: std.ArrayList([]u8) = .empty;
    var initial_index: usize = 0;
    errdefer {
        for (out.items) |spec| allocator.free(spec);
        out.deinit(allocator);
    }
    var positional = false;
    for (args[start..]) |arg| {
        if (!positional and std.mem.eql(u8, arg, "--")) {
            positional = true;
            continue;
        }
        if (!positional and std.mem.startsWith(u8, arg, "--initial=")) {
            initial_index = std.fmt.parseInt(usize, arg["--initial=".len..], 10) catch 0;
            continue;
        }
        if (!positional and arg.len > 0 and arg[0] == '-') continue;

        const normalized = try entry.normalizeArgAlloc(allocator, arg);
        defer allocator.free(normalized);
        const loc = paths.parseSpec(normalized);
        const owned = if (loc.current_host and (loc.path.len == 0 or loc.path[0] != '/')) blk: {
            const base = cwd orelse ".";
            const joined = if (std.mem.eql(u8, base, "/"))
                try std.fmt.allocPrint(allocator, "/{s}", .{loc.path})
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, loc.path });
            defer allocator.free(joined);
            break :blk try paths.formatSpecAlloc(allocator, null, joined);
        } else try paths.formatSpecAlloc(allocator, loc.host, loc.path);
        try out.append(allocator, owned);
    }
    const specs = try out.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .specs = specs,
        .initial_index = if (specs.len == 0) 0 else @min(initial_index, specs.len - 1),
    };
}

pub const Viewport = struct {
    pub const Mode = enum { fit, fill, actual, manual };
    pub const min_zoom: f64 = 0.05;
    pub const max_zoom: f64 = 16.0;

    zoom: f64 = 1.0,
    mode: Mode = .fit,

    pub fn actual(self: *Viewport) void {
        self.mode = .actual;
        self.zoom = 1.0;
    }

    pub fn useFit(self: *Viewport) void {
        self.mode = .fit;
    }

    pub fn useFill(self: *Viewport) void {
        self.mode = .fill;
    }

    pub fn setManual(self: *Viewport, zoom: f64) void {
        self.mode = .manual;
        self.zoom = std.math.clamp(zoom, min_zoom, max_zoom);
    }

    pub fn scaleBy(self: *Viewport, factor: f64) void {
        self.setManual(self.zoom * factor);
    }

    /// Scale used by the current mode for an image inside a viewport.
    pub fn effectiveScale(self: Viewport, viewport_width: f64, viewport_height: f64, image_width: f64, image_height: f64) f64 {
        if (image_width <= 0 or image_height <= 0 or viewport_width <= 0 or viewport_height <= 0)
            return self.zoom;
        return switch (self.mode) {
            .fit => @min(viewport_width / image_width, viewport_height / image_height),
            .fill => @max(viewport_width / image_width, viewport_height / image_height),
            .actual => 1.0,
            .manual => self.zoom,
        };
    }

    /// Scroll adjustment preserving the image point under `anchor`.
    pub fn anchoredScroll(old_scroll: f64, anchor: f64, old_zoom: f64, new_zoom: f64) f64 {
        if (old_zoom <= 0 or new_zoom <= 0) return @max(old_scroll, 0);
        return @max((old_scroll + anchor) * (new_zoom / old_zoom) - anchor, 0);
    }
};

test "viewer content routing: media to image, cast to cast, rest to text" {
    const t = std.testing;
    try t.expectEqual(ContentKind.image, contentKind("photo.PNG"));
    try t.expectEqual(ContentKind.image, contentKind("scan.pdf"));
    try t.expectEqual(ContentKind.image, contentKind("clip.mkv"));
    try t.expectEqual(ContentKind.cast, contentKind("session.cast"));
    try t.expectEqual(ContentKind.text, contentKind("notes.txt"));
    try t.expectEqual(ContentKind.text, contentKind("a.out"));
    try t.expectEqual(ContentKind.text, contentKind("Makefile"));
    try t.expectEqual(ContentKind.text, contentKind("a.cast.gz"));
}

test "viewer invocation recognizes subcommand and installed alias" {
    try std.testing.expectEqual(@as(?usize, 2), invocationStart(&.{ "sketerm", "view", "a.png" }));
    try std.testing.expectEqual(@as(?usize, 2), invocationStart(&.{ "sketerm", "viewer" }));
    try std.testing.expectEqual(@as(?usize, 1), invocationStart(&.{ "/usr/bin/sketerm-viewer", "a.png" }));
    try std.testing.expect(invocationStart(&.{ "sketerm", "files" }) == null);
}

test "viewer batch canonicalizes local URI relative and remote resources" {
    const a = std.testing.allocator;
    var batch = try collect(a, &.{
        "sketerm",
        "view",
        "--initial=1",
        "file:///tmp/a%20b.png",
        "relative.jpg",
        "user@box:/photos/c.webp",
    }, "/work");
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 3), batch.specs.len);
    try std.testing.expectEqual(@as(usize, 1), batch.initial_index);
    try std.testing.expectEqualStrings("local:/tmp/a b.png", batch.specs[0]);
    try std.testing.expectEqualStrings("local:/work/relative.jpg", batch.specs[1]);
    try std.testing.expectEqualStrings("user@box:/photos/c.webp", batch.specs[2]);
}

test "viewer batch preserves a long remote resource" {
    const a = std.testing.allocator;
    const path = try a.alloc(u8, paths.SPEC_BUF_LEN + 32);
    defer a.free(path);
    path[0] = '/';
    @memset(path[1..], 'r');
    const arg = try std.fmt.allocPrint(a, "user@host:{s}", .{path});
    defer a.free(arg);
    var batch = try collect(a, &.{ "sketerm-viewer", arg }, null);
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 1), batch.specs.len);
    try std.testing.expectEqualStrings(arg, batch.specs[0]);
}

test "viewer viewport clamps and preserves an anchored image point" {
    var viewport: Viewport = .{};
    viewport.scaleBy(2);
    try std.testing.expectEqual(Viewport.Mode.manual, viewport.mode);
    try std.testing.expectEqual(@as(f64, 2), viewport.zoom);
    try std.testing.expectEqual(@as(f64, 250), Viewport.anchoredScroll(100, 50, 1, 2));
    viewport.zoom = Viewport.max_zoom;
    viewport.scaleBy(2);
    try std.testing.expectEqual(Viewport.max_zoom, viewport.zoom);
    viewport.actual();
    try std.testing.expectEqual(Viewport.Mode.actual, viewport.mode);
    try std.testing.expectEqual(@as(f64, 1), viewport.zoom);
}

test "viewer viewport computes fit and fill scales" {
    var viewport: Viewport = .{};
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), viewport.effectiveScale(500, 500, 1000, 500), 0.0001);
    viewport.useFill();
    try std.testing.expectApproxEqAbs(@as(f64, 1), viewport.effectiveScale(500, 500, 1000, 500), 0.0001);
    viewport.setManual(2.5);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), viewport.effectiveScale(500, 500, 1000, 500), 0.0001);
}

test "viewer manifest preserves ordering initial index and path bytes" {
    const a = std.testing.allocator;
    const original = [_][]const u8{ "local:/tmp/a\nline.png", "box:/photos/b.jxl" };
    const encoded = try encodeManifest(a, &original, 1);
    defer a.free(encoded);
    var decoded = try decodeManifest(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.initial_index);
    try std.testing.expectEqual(@as(usize, 2), decoded.specs.len);
    try std.testing.expectEqualStrings(original[0], decoded.specs[0]);
    try std.testing.expectEqualStrings(original[1], decoded.specs[1]);
    try std.testing.expectError(error.InvalidManifest, decodeManifest(a, encoded[0 .. encoded.len - 1]));
}

test "viewer manifest paths stay inside the private handoff directory" {
    const dir = "/run/user/1000/sketerm-viewer-batches-1000";
    var good_buf: [4096]u8 = undefined;
    const good = try std.fmt.bufPrint(&good_buf, "{s}/{s}123", .{ dir, MANIFEST_PREFIX });
    try std.testing.expect(manifestPathAllowed(good, dir));
    try std.testing.expect(!manifestPathAllowed("/tmp/viewer-batch-123", dir));
    try std.testing.expect(!manifestPathAllowed(dir, dir));
}

test "viewer treats manifest-shaped names after option terminator as resources" {
    const a = std.testing.allocator;
    var batch = try collect(a, &.{ "sketerm-viewer", "--", "--consume-batch=/tmp/not-a-manifest" }, "/work");
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 1), batch.specs.len);
    try std.testing.expectEqualStrings("local:/work/--consume-batch=/tmp/not-a-manifest", batch.specs[0]);
}

// ── directory and archive listings ───────────────────────────────

/// One row of a directory shown as text: the shape the UI hands over
/// after the daemon listing, decoupled from the wire entry.
pub const DirRow = struct {
    name: []const u8,
    is_dir: bool,
    size: u64 = 0,
    mtime_ms: i64 = 0,
};

/// One archive member as the daemon's `archive_list` job reports it.
pub const ArchiveRow = struct {
    path: []const u8,
    is_dir: bool,
};

/// Column width of the name column, bounded so one long name cannot
/// push every size off the right edge.
const NAME_COL_MAX: usize = 48;

fn rowLess(_: void, a: DirRow, b: DirRow) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return format.naturalLess(a.name, b.name);
}

fn padName(w: *std.Io.Writer, name: []const u8, is_dir: bool, width: usize) !void {
    try w.writeAll(name);
    if (is_dir) try w.writeByte('/');
    const used = name.len + @intFromBool(is_dir);
    if (used < width) try w.splatByteAll(' ', width - used);
}

/// Render a directory as an aligned text table: folders first, then
/// files, each with size and local modification time. `rows` is
/// sorted in place. Hidden entries are included: the viewer is a
/// window on what is there, not on what a listing chooses to show.
pub fn renderDirectoryListing(allocator: std.mem.Allocator, rows: []DirRow) ![]u8 {
    std.mem.sort(DirRow, rows, {}, rowLess);
    var width: usize = 0;
    for (rows) |r| width = @max(width, r.name.len + @intFromBool(r.is_dir));
    width = @min(width, NAME_COL_MAX) + 2;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    for (rows) |r| {
        var stamp_buf: [40]u8 = undefined;
        const stamp: ?[]const u8 = if (r.mtime_ms != 0) clock.localStamp(&stamp_buf, r.mtime_ms) else null;
        // A folder with nothing after its name is not padded: trailing
        // blanks are invisible and still show up in a copy.
        try padName(w, r.name, r.is_dir, if (r.is_dir and stamp == null) 0 else width);
        if (r.is_dir) {
            if (stamp != null) try w.splatByteAll(' ', 10);
        } else {
            var size_buf: [48:0]u8 = undefined;
            const size = format.fmtSize(&size_buf, r.size);
            if (size.len < 10) try w.splatByteAll(' ', 10 - size.len);
            try w.writeAll(size);
        }
        if (stamp) |s| {
            try w.writeAll("  ");
            try w.writeAll(s);
        }
        try w.writeByte('\n');
    }
    if (rows.len == 0) try w.writeAll("(empty folder)\n");
    return out.toOwnedSlice();
}

/// Summary line for a directory listing: "3 folders, 12 files".
pub fn directorySummary(buf: []u8, rows: []const DirRow) []const u8 {
    var dirs: usize = 0;
    for (rows) |r| dirs += @intFromBool(r.is_dir);
    const files = rows.len - dirs;
    return std.fmt.bufPrint(buf, "{d} folder{s}, {d} file{s}", .{
        dirs,  if (dirs == 1) "" else "s",
        files, if (files == 1) "" else "s",
    }) catch "";
}

/// Render an archive's member table one path per line, folders with a
/// trailing slash, in the order bsdtar reported them (archive order is
/// meaningful: it is how the archive was written).
pub fn renderArchiveListing(allocator: std.mem.Allocator, rows: []const ArchiveRow, truncated: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    for (rows) |r| {
        try w.writeAll(r.path);
        if (r.is_dir and !std.mem.endsWith(u8, r.path, "/")) try w.writeByte('/');
        try w.writeByte('\n');
    }
    if (truncated) try w.writeAll("... (member list truncated)\n");
    if (rows.len == 0) try w.writeAll("(no members listed)\n");
    return out.toOwnedSlice();
}

/// Summary line for an archive listing: "1 folder, 40 files".
pub fn archiveSummary(buf: []u8, rows: []const ArchiveRow, truncated: bool) []const u8 {
    var dirs: usize = 0;
    for (rows) |r| dirs += @intFromBool(r.is_dir);
    const files = rows.len - dirs;
    return std.fmt.bufPrint(buf, "{d} folder{s}, {d} file{s}{s}", .{
        dirs,  if (dirs == 1) "" else "s",
        files, if (files == 1) "" else "s",
        if (truncated) " (truncated)" else "",
    }) catch "";
}

test "directory listing sorts folders first and aligns sizes" {
    const a = std.testing.allocator;
    var rows = [_]DirRow{
        .{ .name = "zeta.txt", .is_dir = false, .size = 2048 },
        .{ .name = "alpha", .is_dir = true },
        .{ .name = "beta.bin", .is_dir = false, .size = 5 },
    };
    const text = try renderDirectoryListing(a, &rows);
    defer a.free(text);
    try std.testing.expectEqualStrings(
        "alpha/\nbeta.bin         5 B\nzeta.txt      2.0 KB\n",
        text,
    );
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1 folder, 2 files", directorySummary(&buf, &rows));
    const empty = try renderDirectoryListing(a, &.{});
    defer a.free(empty);
    try std.testing.expectEqualStrings("(empty folder)\n", empty);
}

test "archive listing keeps archive order and marks folders" {
    const a = std.testing.allocator;
    const rows = [_]ArchiveRow{
        .{ .path = "pkg", .is_dir = true },
        .{ .path = "pkg/README", .is_dir = false },
        .{ .path = "pkg/src/", .is_dir = true },
    };
    const text = try renderArchiveListing(a, &rows, true);
    defer a.free(text);
    try std.testing.expectEqualStrings("pkg/\npkg/README\npkg/src/\n... (member list truncated)\n", text);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2 folders, 1 file (truncated)", archiveSummary(&buf, &rows, true));
    try std.testing.expectEqualStrings("0 folders, 0 files", archiveSummary(&buf, &.{}, false));
}
