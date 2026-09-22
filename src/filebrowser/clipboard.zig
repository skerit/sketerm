//! The file-manager clipboard: ONE store for every browser pane in
//! the process.
//!
//! It used to live on `BrowserView`, which made it PER PANE: a copy in
//! one pane left the other pane's clipboard empty, so Ctrl+V did
//! nothing there and the context menu hid Paste entirely (that menu
//! item is gated on the clipboard being non-empty). The asymmetry read
//! as "remote folders cannot be pasted into", but the host never
//! mattered -- only which pane held the copy.
//!
//! A cut/copy therefore names a `host` (null = local) and the paths on
//! it; where the paste lands is the destination tab's business, and
//! `ops.pasteOne` already routes same-host and cross-host through the
//! daemon identically.

const std = @import("std");

pub const GNOME = "x-special/gnome-copied-files";
pub const URI = "text/uri-list";
pub const KDE_CUT = "application/x-kde-cutselection";
pub const MAX_EXTERNAL_BYTES = 1024 * 1024;
pub const MAX_EXTERNAL_FILES = 4096;

pub const Board = struct {
    allocator: std.mem.Allocator,
    /// Host the sources live on; null = the local daemon.
    host: ?[]u8 = null,
    paths: std.ArrayList([]u8) = .empty,
    /// Paste MOVES and then clears the board.
    cut: bool = false,
    /// Filesystem the sources live on (0 = unknown). Decides whether a
    /// hard link into a given directory could work at all, without a
    /// round trip per menu.
    dev: u64 = 0,

    pub fn deinit(self: *Board) void {
        self.clear();
        self.paths.deinit(self.allocator);
    }

    pub fn clear(self: *Board) void {
        if (self.host) |h| self.allocator.free(h);
        self.host = null;
        for (self.paths.items) |p| self.allocator.free(p);
        self.paths.clearRetainingCapacity();
        self.cut = false;
        self.dev = 0;
    }

    /// Replace the contents atomically. Allocation failure returns false
    /// and clears the board, never leaving a partial or falsely local copy.
    pub fn set(self: *Board, host: ?[]const u8, srcs: []const []const u8, cut: bool, dev: u64) bool {
        var next = Board{ .allocator = self.allocator, .cut = cut, .dev = dev };
        var success = false;
        defer {
            next.deinit();
            if (!success) self.clear();
        }
        if (host) |h| next.host = self.allocator.dupe(u8, h) catch return false;
        next.paths.ensureTotalCapacity(self.allocator, srcs.len) catch return false;
        for (srcs) |sp| {
            const owned = self.allocator.dupe(u8, sp) catch return false;
            next.paths.appendAssumeCapacity(owned);
        }
        std.mem.swap(Board, self, &next);
        success = true;
        return true;
    }

    pub fn items(self: *const Board) []const []u8 {
        return self.paths.items;
    }

    pub fn isEmpty(self: *const Board) bool {
        return self.paths.items.len == 0;
    }

    /// The first source: the single-source verbs (Sync Here, Compare,
    /// paste-as-link) act on it.
    pub fn first(self: *const Board) ?[]const u8 {
        if (self.paths.items.len == 0) return null;
        return self.paths.items[0];
    }

    /// The host as an optional slice, the shape `paths.hostEq` wants.
    pub fn hostOpt(self: *const Board) ?[]const u8 {
        return if (self.host) |h| @as(?[]const u8, h) else null;
    }
};

/// Import local file URIs without filesystem IO. The returned board owns
/// every path independently of data; the caller must deinit it. GNOME needs
/// an exact cut/copy first line; URI lists default to copy and allow comments.
/// Limits count URI records before deduplication. Empty lists and ANY invalid
/// entry fail the whole import (EmptyClipboard / InvalidClipboard), as do
/// PayloadTooLarge, TooManyFiles and OutOfMemory. KDE's cut hint is separate.
pub fn parseExternal(allocator: std.mem.Allocator, data: []const u8, gnome: bool) !Board {
    if (data.len > MAX_EXTERNAL_BYTES) return error.PayloadTooLarge;
    if (std.mem.indexOfScalar(u8, data, 0) != null) return error.InvalidClipboard;
    var board = Board{ .allocator = allocator };
    errdefer board.deinit();
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var lines = std.mem.splitScalar(u8, data, '\n');
    if (gnome) {
        const first = lines.next() orelse return error.InvalidClipboard;
        const verb = if (std.mem.endsWith(u8, first, "\r")) first[0 .. first.len - 1] else first;
        if (std.mem.eql(u8, verb, "cut")) {
            board.cut = true;
        } else if (!std.mem.eql(u8, verb, "copy")) return error.InvalidClipboard;
    }
    var records: usize = 0;
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len == 0 or (!gnome and line[0] == '#')) continue;
        records += 1;
        if (records > MAX_EXTERNAL_FILES) return error.TooManyFiles;
        const uri = std.Uri.parse(line) catch return error.InvalidClipboard;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "file") or
            uri.user != null or uri.password != null or uri.port != null or
            uri.query != null or uri.fragment != null) return error.InvalidClipboard;
        if (uri.host) |host| {
            if (!std.ascii.eqlIgnoreCase(host.percent_encoded, "localhost")) return error.InvalidClipboard;
        }
        const encoded = uri.path.percent_encoded;
        if (encoded.len == 0 or encoded[0] != '/') return error.InvalidClipboard;
        // std.Uri's percent decoder preserves malformed escapes. Validate
        // first and size the owned buffer exactly, including decoded slashes.
        var decoded_len = encoded.len;
        var i: usize = 0;
        while (i < encoded.len) : (i += 1) {
            const byte = encoded[i];
            if (byte == '%') {
                if (encoded.len - i < 3 or !std.ascii.isHex(encoded[i + 1]) or
                    !std.ascii.isHex(encoded[i + 2])) return error.InvalidClipboard;
                decoded_len -= 2;
                i += 2;
            } else if (byte < 0x80 and !std.ascii.isAlphanumeric(byte) and
                std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@/", byte) == null)
                return error.InvalidClipboard;
        }
        const path = try allocator.alloc(u8, decoded_len);
        // Ownership transfers only after append; duplicates are freed here.
        var retained = false;
        defer if (!retained) allocator.free(path);
        _ = std.Uri.percentDecodeBackwards(path, encoded);
        if (std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path) or
            std.mem.startsWith(u8, path, "//")) return error.InvalidClipboard;
        var segments = std.mem.splitScalar(u8, path, '/');
        var has_name = false;
        while (segments.next()) |segment| {
            if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidClipboard;
            has_name = has_name or segment.len != 0;
        }
        if (!has_name) return error.InvalidClipboard;
        const entry = try seen.getOrPut(path);
        if (entry.found_existing) continue;
        try board.paths.append(allocator, path);
        retained = true;
    }
    if (board.isEmpty()) return error.EmptyClipboard;
    return board;
}

var g_board: ?Board = null;

/// The process-wide board. Every browser face resolves it through
/// here, so there is exactly one clipboard however many panes, tabs
/// or windows exist.
pub fn shared(allocator: std.mem.Allocator) *Board {
    if (g_board == null) g_board = .{ .allocator = allocator };
    return &g_board.?;
}

/// Ownership loss must not recreate a board that has already shut down.
pub fn clearShared() void {
    if (g_board) |*b| b.clear();
}

/// Release the singleton (process teardown / test isolation).
pub fn resetShared() void {
    if (g_board) |*b| b.deinit();
    g_board = null;
}

test "board holds a multi-path remote copy and clears on demand" {
    const t = std.testing;
    var b = Board{ .allocator = t.allocator };
    defer b.deinit();

    try t.expect(b.isEmpty());
    try t.expect(b.first() == null);

    try t.expect(b.set("user@box", &.{ "/a/one", "/a/two" }, false, 66));
    try t.expect(!b.isEmpty());
    try t.expectEqualStrings("user@box", b.host.?);
    try t.expectEqualStrings("/a/one", b.first().?);
    try t.expectEqual(@as(usize, 2), b.items().len);
    try t.expectEqual(@as(u64, 66), b.dev);
    try t.expect(!b.cut);

    // A second copy replaces, never appends.
    try t.expect(b.set(null, &.{"/local/only"}, true, 0));
    try t.expectEqual(@as(usize, 1), b.items().len);
    try t.expect(b.host == null);
    try t.expect(b.hostOpt() == null);
    try t.expect(b.cut);

    b.clear();
    try t.expect(b.isEmpty());
    try t.expect(!b.cut);
}

test "shared() is one board for every caller" {
    const t = std.testing;
    defer resetShared();
    const a = shared(t.allocator);
    try t.expect(a.set("dalaran", &.{"/home/x/f.mkv"}, false, 1));
    // A different pane asking for the clipboard sees the same copy --
    // this is exactly what per-view state got wrong.
    const b = shared(t.allocator);
    try t.expectEqual(@intFromPtr(a), @intFromPtr(b));
    try t.expectEqualStrings("/home/x/f.mkv", b.first().?);
    try t.expectEqualStrings("dalaran", b.host.?);
}

test "clipboard ownership loss clears the shared cut without recreating a retired board" {
    const t = std.testing;
    defer resetShared();
    const b = shared(t.allocator);
    try t.expect(b.set("remote", &.{"/cut/file"}, true, 1));
    clearShared();
    try t.expect(b.isEmpty());
    try t.expect(!b.cut);
    try t.expect(b.host == null);

    resetShared();
    clearShared();
    try t.expect(g_board == null);
}

test "external URI list owns decoded local paths and deduplicates in stable order" {
    const t = std.testing;
    var payload = ("# desktop clipboard\r\n\r\n" ++
        "FILE://LoCaLhOsT/tmp/a%20space%25+name\r\n" ++
        "file:/tmp/line%0Abreak%0D%09\r\n" ++
        "file:///tmp/caf%C3%A9\r\n" ++
        "file:///tmp/caf\xc3\xa9\r\n" ++
        "file:///tmp/%23%3F%40%3A%5C\r\n" ++
        "file:///tmp/a%20space%25+name\r\n" ++
        "file:///tmp/sub%2ffile\r\n").*;
    var board = try parseExternal(t.allocator, &payload, false);
    defer board.deinit();
    @memset(&payload, 'x');
    try t.expect(board.host == null);
    try t.expectEqual(@as(u64, 0), board.dev);
    try t.expect(!board.cut);
    const expected = [_][]const u8{
        "/tmp/a space%+name", "/tmp/line\nbreak\r\t", "/tmp/caf\xc3\xa9", "/tmp/#?@:\\", "/tmp/sub/file",
    };
    try t.expectEqual(expected.len, board.items().len);
    for (expected, board.items()) |want, got| try t.expectEqualStrings(want, got);
}

test "external GNOME requires an exact cut or copy header" {
    const t = std.testing;
    for ([_][]const u8{ "cut\r\n", "copy\n" }, [_]bool{ true, false }) |header, cut| {
        const payload = try std.fmt.allocPrint(t.allocator, "{s}file:///one\r\nfile:///two\r\nfile:/one\r\n", .{header});
        defer t.allocator.free(payload);
        var board = try parseExternal(t.allocator, payload, true);
        defer board.deinit();
        try t.expectEqual(cut, board.cut);
        try t.expectEqual(@as(usize, 2), board.items().len);
        try t.expectEqualStrings("/one", board.items()[0]);
        try t.expectEqualStrings("/two", board.items()[1]);
    }
    for ([_][]const u8{ "CUT", "Copy", " cut", "cut ", "", "move", "# comment", "file:///one" }) |header| {
        const payload = try std.fmt.allocPrint(t.allocator, "{s}\nfile:///two", .{header});
        defer t.allocator.free(payload);
        try t.expectError(error.InvalidClipboard, parseExternal(t.allocator, payload, true));
    }
    try t.expectError(error.InvalidClipboard, parseExternal(t.allocator, "cut\nfile:///one", false));
    try t.expectError(error.InvalidClipboard, parseExternal(t.allocator, "copy\n# comment\nfile:///one", true));
    try t.expectError(error.EmptyClipboard, parseExternal(t.allocator, "copy\n", true));
    try t.expectError(error.EmptyClipboard, parseExternal(t.allocator, "cut", true));
    try t.expectError(error.EmptyClipboard, parseExternal(t.allocator, "# comment\r\n\r\n", false));
    try t.expectError(error.EmptyClipboard, parseExternal(t.allocator, "", false));
}

test "external invalid URI anywhere refuses the whole import" {
    const t = std.testing;
    const invalid = [_][]const u8{
        "https://localhost/tmp/file",     "smb://server/share/file",                 "file://remote/tmp/file",
        "file://127.0.0.1/tmp/file",      "file://[::1]/tmp/file",                   "file://localhost./tmp/file",
        "file://user@localhost/tmp/file", "file://user:password@localhost/tmp/file", "file://@localhost/tmp/file",
        "file://localhost:80/tmp/file",   "file://localhost:/tmp/file",              "file://local%68ost/tmp/file",
        "file:///tmp/file?query",         "file:///tmp/file?",                       "file:///tmp/file#fragment",
        "file:///tmp/file#",              "file:///tmp/zero%00byte",                 "file:///tmp/zero\x00byte",
        "file:///tmp/truncated%",         "file:///tmp/truncated%2",                 "file:///tmp/bad%GG",
        "file:///tmp/bad%+1",             "file:///tmp/bad%-1",                      "file:///tmp/raw space",
        "file:///tmp/raw\tcontrol",       "file:///tmp/raw\rcontrol",                "file:///tmp/raw\\backslash",
        "file:///tmp/bad%FF",             "file:///tmp/bad\xff",                     "file:///tmp/overlong%C0%AF",
        "file:///tmp/surrogate%ED%A0%80", "/tmp/file",                               "relative",
        "file:relative",                  "file:%2Ftmp/file",                        "file:",
        "file://localhost",               "file:///",                                "file:/",
        "file://localhost/",              "file:////",                               "file:///%2F",
        "file:////remote/share",          "file:///%2Fremote/share",                 "file:///tmp/./file",
        "file:///tmp/../file",            "file:///tmp/.",                           "file:///tmp/..",
        "file:///%2e/file",               "file:///tmp/.%2E/file",                   "file:///tmp%2f..%2ffile",
        "file:///tmp/%2E%2e",             "file:///tmp/%2e%2fmore",
    };
    for (invalid) |bad| {
        for ([_]bool{ false, true }) |gnome| {
            const payload = try std.fmt.allocPrint(t.allocator, "{s}file:///valid\n{s}\nfile:///after", .{
                if (gnome) "cut\n" else "", bad,
            });
            defer t.allocator.free(payload);
            try t.expectError(error.InvalidClipboard, parseExternal(t.allocator, payload, gnome));
        }
    }
    try t.expectError(error.InvalidClipboard, parseExternal(t.allocator, "# nul\x00comment\nfile:///one", false));
}

test "external payload and record limits are inclusive and precede deduplication" {
    const t = std.testing;
    const payload = try t.allocator.alloc(u8, MAX_EXTERNAL_BYTES + 1);
    defer t.allocator.free(payload);
    @memset(payload, 'x');
    const prefix = "file:///one\n#";
    @memcpy(payload[0..prefix.len], prefix);
    var board = try parseExternal(t.allocator, payload[0..MAX_EXTERNAL_BYTES], false);
    defer board.deinit();
    try t.expectEqualStrings("/one", board.first().?);
    try t.expectError(error.PayloadTooLarge, parseExternal(t.allocator, payload, false));

    const record = "file:///one\n";
    const records = try t.allocator.alloc(u8, record.len * (MAX_EXTERNAL_FILES + 1));
    defer t.allocator.free(records);
    for (0..MAX_EXTERNAL_FILES + 1) |i| @memcpy(records[i * record.len ..][0..record.len], record);
    var repeated = try parseExternal(t.allocator, records[0 .. record.len * MAX_EXTERNAL_FILES], false);
    defer repeated.deinit();
    try t.expectEqual(@as(usize, 1), repeated.items().len);
    try t.expectError(error.TooManyFiles, parseExternal(t.allocator, records, false));
}

test "external parsing unwinds every allocation failure and invalid suffix" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const payload = "cut\nfile:///a\nfile:///b%20c\nfile:/a\nfile:///d\nfile:///e\n" ++
                "file:///f\nfile:///g\nfile:///h\nfile:///i\nfile:///j\nfile:///k\nfile:///l\n";
            var board = try parseExternal(allocator, payload, true);
            defer board.deinit();
            try std.testing.expectEqual(@as(usize, 11), board.items().len);
            var invalid = parseExternal(allocator, payload ++ "file:///bad%\n", true) catch |err| switch (err) {
                error.InvalidClipboard => return,
                else => return err,
            };
            defer invalid.deinit();
            return error.TestExpectedError;
        }
    }.run, .{});
}

test "board set clears rather than keeping a partial or falsely local selection on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const t = std.testing;
            var board = Board{ .allocator = allocator };
            defer board.deinit();
            if (!board.set("old-host", &.{"/old/file"}, true, 17)) return error.OutOfMemory;
            if (!board.set("new-host", &.{ "/new/one", "/new/two", "/new/three" }, true, 42)) {
                try t.expect(board.isEmpty());
                try t.expect(board.host == null);
                try t.expect(!board.cut);
                try t.expectEqual(@as(u64, 0), board.dev);
                return error.OutOfMemory;
            }
            try t.expectEqualStrings("new-host", board.host.?);
            try t.expectEqual(@as(usize, 3), board.items().len);
            try t.expectEqualStrings("/new/three", board.items()[2]);
            try t.expect(board.cut);
            try t.expectEqual(@as(u64, 42), board.dev);
        }
    }.run, .{});
}
