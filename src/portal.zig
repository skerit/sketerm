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

/// A mapped filter plus the index it came from in the caller's
/// filter list, so the reply's `current_filter` can echo the ORIGINAL
/// variant rather than a reconstruction.
pub const MappedFilter = struct {
    filter: fpicker.Filter,
    src: usize,
};

/// Map portal filters onto picker filters: glob entries become name
/// patterns, mimetype entries become mime patterns (the picker asks
/// GIO for the name's type and matches those). A filter left with NO
/// usable entries at all is dropped entirely -- an empty pattern list
/// means "all files" to the picker, which would invert the filter's
/// meaning. Output slices alias the input; allocate from an arena.
pub fn mapFilters(allocator: std.mem.Allocator, raw: []const RawFilter) ![]MappedFilter {
    var out: std.ArrayList(MappedFilter) = .empty;
    for (raw, 0..) |rf, i| {
        var pats: std.ArrayList([]const u8) = .empty;
        var mimes: std.ArrayList([]const u8) = .empty;
        for (rf.entries) |e| {
            if (e.pattern.len == 0) continue;
            switch (e.kind) {
                ENTRY_GLOB => try pats.append(allocator, e.pattern),
                ENTRY_MIME => try mimes.append(allocator, e.pattern),
                else => {},
            }
        }
        if (pats.items.len == 0 and mimes.items.len == 0) {
            pats.deinit(allocator);
            mimes.deinit(allocator);
            continue;
        }
        try out.append(allocator, .{
            .src = i,
            .filter = .{
                .label = rf.label,
                .patterns = try pats.toOwnedSlice(allocator),
                .mimes = try mimes.toOwnedSlice(allocator),
            },
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Just the picker-facing halves of a mapped list.
pub fn pickerFilters(allocator: std.mem.Allocator, mapped: []const MappedFilter) ![]fpicker.Filter {
    const out = try allocator.alloc(fpicker.Filter, mapped.len);
    for (mapped, 0..) |m, i| out[i] = m.filter;
    return out;
}

fn rawEntryEql(a: RawEntry, b: RawEntry) bool {
    return a.kind == b.kind and std.mem.eql(u8, a.pattern, b.pattern);
}

/// Whether two wire filters are the same filter (label + entries in
/// order), which is how `current_filter` is matched to `filters`.
pub fn rawFilterEql(a: RawFilter, b: RawFilter) bool {
    if (!std.mem.eql(u8, a.label, b.label)) return false;
    if (a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |x, y| if (!rawEntryEql(x, y)) return false;
    return true;
}

/// Index of `target` in `raw`, for honouring `current_filter`.
pub fn findRawFilter(raw: []const RawFilter, target: RawFilter) ?usize {
    for (raw, 0..) |rf, i| if (rawFilterEql(rf, target)) return i;
    return null;
}

/// The mapped-list index whose source is `src` (a caller filter that
/// mapped to nothing has no index).
pub fn mappedIndexOfSrc(mapped: []const MappedFilter, src: usize) ?usize {
    for (mapped, 0..) |m, i| if (m.src == src) return i;
    return null;
}

// -- parent_window handles ---------------------------------------

/// A portal caller's `parent_window` handle: "wayland:<xdg_foreign
/// exported handle>" or "x11:<hex window id>". Anything else (empty,
/// unknown prefix, unparsable id) is `none`.
pub const ParentHandle = union(enum) {
    none,
    wayland: []const u8,
    x11: u64,
};

pub fn parseParentHandle(s: []const u8) ParentHandle {
    if (std.mem.startsWith(u8, s, "wayland:")) {
        const h = s["wayland:".len..];
        return if (h.len == 0) .none else .{ .wayland = h };
    }
    if (std.mem.startsWith(u8, s, "x11:")) {
        var hex = s["x11:".len..];
        if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X"))
            hex = hex[2..];
        if (hex.len == 0) return .none;
        const xid = std.fmt.parseInt(u64, hex, 16) catch return .none;
        return if (xid == 0) .none else .{ .x11 = xid };
    }
    return .none;
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

test "mapFilters keeps globs and mimetypes, drops empty filters" {
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
            .{ .kind = 7, .pattern = "unknown-entry-kind" },
        } },
        .{ .label = "Text", .entries = &.{
            .{ .kind = ENTRY_GLOB, .pattern = "*.txt" },
        } },
    };
    const mapped = try mapFilters(a, &raw);
    try t.expectEqual(@as(usize, 3), mapped.len);
    try t.expectEqualStrings("Images", mapped[0].filter.label);
    try t.expectEqual(@as(usize, 0), mapped[0].src);
    try t.expectEqual(@as(usize, 2), mapped[0].filter.patterns.len);
    try t.expectEqualStrings("*.png", mapped[0].filter.patterns[0]);
    try t.expectEqualStrings("*.jpg", mapped[0].filter.patterns[1]);
    try t.expectEqualStrings("image/jpeg", mapped[0].filter.mimes[0]);
    // A mimetype-only filter is now a real filter, not a dropped one.
    try t.expectEqualStrings("Any image", mapped[1].filter.label);
    try t.expectEqual(@as(usize, 1), mapped[1].src);
    try t.expectEqual(@as(usize, 0), mapped[1].filter.patterns.len);
    try t.expectEqualStrings("image/*", mapped[1].filter.mimes[0]);
    // "Weird" had nothing usable; "Text" keeps its original index.
    try t.expectEqualStrings("Text", mapped[2].filter.label);
    try t.expectEqual(@as(usize, 3), mapped[2].src);
    try t.expectEqual(@as(?usize, 2), mappedIndexOfSrc(mapped, 3));
    try t.expectEqual(@as(?usize, null), mappedIndexOfSrc(mapped, 2));

    const plain = try pickerFilters(a, mapped);
    try t.expectEqual(@as(usize, 3), plain.len);
    try t.expectEqualStrings("Any image", plain[1].label);
}

test "rawFilterEql and findRawFilter locate current_filter" {
    const t = std.testing;
    const raw = [_]RawFilter{
        .{ .label = "Images", .entries = &.{.{ .kind = ENTRY_MIME, .pattern = "image/*" }} },
        .{ .label = "Text", .entries = &.{.{ .kind = ENTRY_GLOB, .pattern = "*.txt" }} },
    };
    try t.expectEqual(@as(?usize, 1), findRawFilter(&raw, raw[1]));
    // Same label, different entries: not the same filter.
    try t.expectEqual(@as(?usize, null), findRawFilter(&raw, .{
        .label = "Text",
        .entries = &.{.{ .kind = ENTRY_GLOB, .pattern = "*.md" }},
    }));
    try t.expectEqual(@as(?usize, null), findRawFilter(&raw, .{ .label = "Nope", .entries = &.{} }));
    try t.expect(!rawFilterEql(raw[0], raw[1]));
}

test "parseParentHandle" {
    const t = std.testing;
    switch (parseParentHandle("wayland:handle-42")) {
        .wayland => |h| try t.expectEqualStrings("handle-42", h),
        else => return error.WrongVariant,
    }
    switch (parseParentHandle("x11:0x1a00003")) {
        .x11 => |x| try t.expectEqual(@as(u64, 0x1a00003), x),
        else => return error.WrongVariant,
    }
    // Bare hex (no 0x) is what some callers send.
    switch (parseParentHandle("x11:1A00003")) {
        .x11 => |x| try t.expectEqual(@as(u64, 0x1a00003), x),
        else => return error.WrongVariant,
    }
    try t.expectEqual(ParentHandle.none, parseParentHandle(""));
    try t.expectEqual(ParentHandle.none, parseParentHandle("wayland:"));
    try t.expectEqual(ParentHandle.none, parseParentHandle("x11:"));
    try t.expectEqual(ParentHandle.none, parseParentHandle("x11:0x0"));
    try t.expectEqual(ParentHandle.none, parseParentHandle("x11:zzz"));
    try t.expectEqual(ParentHandle.none, parseParentHandle("mir:3"));
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
