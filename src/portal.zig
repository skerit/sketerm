//! GTK-free policy for the xdg-desktop-portal FileChooser backend
//! (`sketerm portal`): impl-method -> picker-mode mapping, portal
//! filter-list conversion, local-spec extraction and file:// URI
//! encoding. The GDBus service lives in src/ui/portal.zig.

const std = @import("std");
const fpicker = @import("filebrowser/picker.zig");

/// Portal response codes (org.freedesktop.impl.portal.Request).
pub const RESPONSE_OK: u32 = 0;
pub const RESPONSE_CANCELLED: u32 = 1;
pub const RESPONSE_OTHER: u32 = 2;

/// The three org.freedesktop.impl.portal.FileChooser methods.
pub const Method = enum { open_file, save_file, save_files };

pub fn methodFromName(name: []const u8) ?Method {
    if (std.mem.eql(u8, name, "OpenFile")) return .open_file;
    if (std.mem.eql(u8, name, "SaveFile")) return .save_file;
    if (std.mem.eql(u8, name, "SaveFiles")) return .save_files;
    return null;
}

/// Portal options -> picker mode. OpenFile's `directory` wins over
/// `multiple` (the spec's folder chooser is single-pick); SaveFiles
/// picks ONE destination directory and the names ride separately.
pub fn modeFor(method: Method, multiple: bool, directory: bool) fpicker.Mode {
    return switch (method) {
        .open_file => if (directory)
            .select_dir
        else if (multiple)
            fpicker.Mode.open_files
        else
            .open_file,
        .save_file => .save_file,
        .save_files => .select_destination,
    };
}

// -- filter mapping ----------------------------------------------

/// The portal wire filter format is a(sa(us)): label + typed entries.
pub const ENTRY_GLOB: u32 = 0;
pub const ENTRY_MIME: u32 = 1;

pub const RawEntry = struct {
    kind: u32,
    pattern: []const u8,
};

pub const RawFilter = struct {
    label: []const u8,
    entries: []const RawEntry,
};

/// Map portal filters onto picker filters: glob entries pass through,
/// mimetype entries are dropped. A filter left with NO globs is
/// dropped entirely -- an empty pattern list means "all files" to the
/// picker, which would invert a mimetype-only filter's meaning.
/// Output slices alias the input; allocate from an arena.
pub fn mapFilters(allocator: std.mem.Allocator, raw: []const RawFilter) ![]fpicker.Filter {
    var out: std.ArrayList(fpicker.Filter) = .empty;
    for (raw) |rf| {
        var pats: std.ArrayList([]const u8) = .empty;
        for (rf.entries) |e| {
            if (e.kind != ENTRY_GLOB) continue;
            if (e.pattern.len == 0) continue;
            try pats.append(allocator, e.pattern);
        }
        if (pats.items.len == 0) {
            pats.deinit(allocator);
            continue;
        }
        try out.append(allocator, .{
            .label = rf.label,
            .patterns = try pats.toOwnedSlice(allocator),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Portal accept_label values carry GTK mnemonics ("_Open"); the
/// picker button takes plain text. A single '_' is dropped, "__"
/// collapses to a literal '_'.
pub fn stripMnemonicAlloc(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        if (label[i] == '_') {
            if (i + 1 < label.len and label[i + 1] == '_') {
                try out.append(allocator, '_');
                i += 1;
            }
            continue;
        }
        try out.append(allocator, label[i]);
    }
    return out.toOwnedSlice(allocator);
}

// -- local-spec extraction ---------------------------------------

/// Picker results are host-qualified specs ("local:/x", "box:/x").
/// A portal consumer can only use LOCAL absolute paths; anything
/// else (SSH/UDP hosts) returns null.
pub fn localPath(spec: []const u8) ?[]const u8 {
    if (spec.len == 0) return null;
    if (spec[0] == '/') return spec;
    if (std.mem.startsWith(u8, spec, "local:/")) return spec["local:".len..];
    return null;
}

// -- file:// URI encoding ----------------------------------------

fn uriByteOk(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or switch (b) {
        '-', '.', '_', '~', '/' => true,
        else => false,
    };
}

/// Percent-encode an absolute local path as a file:// URI (RFC 3986
/// unreserved + '/' kept literal; everything else, UTF-8 bytes
/// included, is %XX-escaped).
pub fn fileUriAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    for (path) |b| {
        if (uriByteOk(b)) {
            try out.append(allocator, b);
        } else {
            var esc: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&esc, "%{X:0>2}", .{b}) catch unreachable;
            try out.appendSlice(allocator, &esc);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// SaveFiles: the chosen directory + one requested leaf name as a
/// file:// URI. Rejects names that would escape the directory.
pub fn joinedUriAlloc(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (!fpicker.validSaveName(name)) return error.BadName;
    const base = if (std.mem.eql(u8, dir, "/")) "" else std.mem.trimEnd(u8, dir, "/");
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
    defer allocator.free(full);
    return fileUriAlloc(allocator, full);
}

// -- tests -------------------------------------------------------

test "methodFromName" {
    const t = std.testing;
    try t.expectEqual(@as(?Method, .open_file), methodFromName("OpenFile"));
    try t.expectEqual(@as(?Method, .save_file), methodFromName("SaveFile"));
    try t.expectEqual(@as(?Method, .save_files), methodFromName("SaveFiles"));
    try t.expectEqual(@as(?Method, null), methodFromName("openfile"));
    try t.expectEqual(@as(?Method, null), methodFromName(""));
}

test "modeFor matrix" {
    const t = std.testing;
    try t.expectEqual(fpicker.Mode.open_file, modeFor(.open_file, false, false));
    try t.expectEqual(fpicker.Mode.open_files, modeFor(.open_file, true, false));
    try t.expectEqual(fpicker.Mode.select_dir, modeFor(.open_file, false, true));
    // directory beats multiple: the folder chooser is single-pick.
    try t.expectEqual(fpicker.Mode.select_dir, modeFor(.open_file, true, true));
    try t.expectEqual(fpicker.Mode.save_file, modeFor(.save_file, false, false));
    try t.expectEqual(fpicker.Mode.select_destination, modeFor(.save_files, true, false));
}

test "mapFilters keeps globs, drops mimetypes and empty filters" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = [_]RawFilter{
        .{ .label = "Images", .entries = &.{
            .{ .kind = ENTRY_GLOB, .pattern = "*.png" },
            .{ .kind = ENTRY_MIME, .pattern = "image/jpeg" },
            .{ .kind = ENTRY_GLOB, .pattern = "*.jpg" },
        } },
        .{ .label = "Any image", .entries = &.{
            .{ .kind = ENTRY_MIME, .pattern = "image/*" },
        } },
        .{ .label = "Weird", .entries = &.{
            .{ .kind = ENTRY_GLOB, .pattern = "" },
        } },
        .{ .label = "Text", .entries = &.{
            .{ .kind = ENTRY_GLOB, .pattern = "*.txt" },
        } },
    };
    const mapped = try mapFilters(a, &raw);
    try t.expectEqual(@as(usize, 2), mapped.len);
    try t.expectEqualStrings("Images", mapped[0].label);
    try t.expectEqual(@as(usize, 2), mapped[0].patterns.len);
    try t.expectEqualStrings("*.png", mapped[0].patterns[0]);
    try t.expectEqualStrings("*.jpg", mapped[0].patterns[1]);
    try t.expectEqualStrings("Text", mapped[1].label);
    try t.expectEqualStrings("*.txt", mapped[1].patterns[0]);
}

test "mapFilters empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mapped = try mapFilters(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 0), mapped.len);
}

test "stripMnemonicAlloc" {
    const t = std.testing;
    const a = t.allocator;
    {
        const s = try stripMnemonicAlloc(a, "_Open");
        defer a.free(s);
        try t.expectEqualStrings("Open", s);
    }
    {
        const s = try stripMnemonicAlloc(a, "Save __as_");
        defer a.free(s);
        try t.expectEqualStrings("Save _as", s);
    }
    {
        const s = try stripMnemonicAlloc(a, "Pick");
        defer a.free(s);
        try t.expectEqualStrings("Pick", s);
    }
}

test "localPath" {
    const t = std.testing;
    try t.expectEqualStrings("/home/u/f.txt", localPath("local:/home/u/f.txt").?);
    try t.expectEqualStrings("/x", localPath("/x").?);
    try t.expect(localPath("box:/home/u/f.txt") == null);
    try t.expect(localPath("user@box:/f") == null);
    try t.expect(localPath("udp:box:/f") == null);
    try t.expect(localPath("") == null);
    // A host literally named "local" is what "local:" means; only the
    // exact prefix passes.
    try t.expect(localPath("localhost:/f") == null);
}

test "fileUriAlloc encoding" {
    const t = std.testing;
    const a = t.allocator;
    {
        const u = try fileUriAlloc(a, "/home/user/file.txt");
        defer a.free(u);
        try t.expectEqualStrings("file:///home/user/file.txt", u);
    }
    {
        const u = try fileUriAlloc(a, "/tmp/a b#c?.txt");
        defer a.free(u);
        try t.expectEqualStrings("file:///tmp/a%20b%23c%3F.txt", u);
    }
    {
        // UTF-8 bytes escape byte-wise.
        const u = try fileUriAlloc(a, "/tmp/\xc3\xa9");
        defer a.free(u);
        try t.expectEqualStrings("file:///tmp/%C3%A9", u);
    }
    {
        const u = try fileUriAlloc(a, "/tmp/100%.txt");
        defer a.free(u);
        try t.expectEqualStrings("file:///tmp/100%25.txt", u);
    }
}

test "joinedUriAlloc" {
    const t = std.testing;
    const a = t.allocator;
    {
        const u = try joinedUriAlloc(a, "/home/u", "out.pdf");
        defer a.free(u);
        try t.expectEqualStrings("file:///home/u/out.pdf", u);
    }
    {
        const u = try joinedUriAlloc(a, "/", "root.txt");
        defer a.free(u);
        try t.expectEqualStrings("file:///root.txt", u);
    }
    {
        const u = try joinedUriAlloc(a, "/home/u/", "x");
        defer a.free(u);
        try t.expectEqualStrings("file:///home/u/x", u);
    }
    try t.expectError(error.BadName, joinedUriAlloc(a, "/home", "a/b"));
    try t.expectError(error.BadName, joinedUriAlloc(a, "/home", ".."));
    try t.expectError(error.BadName, joinedUriAlloc(a, "/home", ""));
}
