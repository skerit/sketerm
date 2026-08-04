//! GTK-free file-picker policy: request/result types, mode
//! predicates, glob-ish filter matching and save-name validation.
//! The GTK presentation lives in src/ui/picker.zig; results carry
//! host-qualified specs (paths.formatSpec), so a picker opened at
//! user@box:/path needs no special casing anywhere.

const std = @import("std");

pub const Mode = enum {
    /// Pick exactly one existing file.
    open_file,
    /// Pick one or more existing files.
    open_files,
    /// Pick a directory (the current one when nothing is selected).
    select_dir,
    /// Name a file to write; an existing name asks before overwrite.
    save_file,
    /// Pick a destination directory for a transfer.
    select_destination,
};

/// One selectable name filter ("Images" -> "*.png", "*.jpg").
/// Matching is case-insensitive on the basename; an empty pattern
/// list matches everything.
pub const Filter = struct {
    label: []const u8,
    patterns: []const []const u8,
};

pub const Request = struct {
    mode: Mode,
    /// Starting location: a path or host-qualified spec (null = $HOME).
    initial_spec: ?[]const u8 = null,
    filters: []const Filter = &.{},
    /// Prefill for the save_file name entry.
    suggested_name: ?[]const u8 = null,
    /// Window title override (null = a mode-derived default).
    title: ?[]const u8 = null,
    /// Primary-button label override (null = primaryLabel(mode));
    /// used by the portal backend's accept_label option.
    accept_label: ?[]const u8 = null,
};

/// Host-qualified specs chosen by the user. `name` repeats the leaf
/// name for save_file (the spec already ends in it). Slices are only
/// valid during the result callback.
pub const Result = struct {
    specs: []const []const u8,
    name: ?[]const u8 = null,
};

// -- mode predicates ---------------------------------------------

pub fn needsNameEntry(mode: Mode) bool {
    return mode == .save_file;
}

pub fn allowsMulti(mode: Mode) bool {
    return mode == .open_files;
}

/// Whether the PICKED objects are directories.
pub fn acceptsDirs(mode: Mode) bool {
    return mode == .select_dir or mode == .select_destination;
}

/// Directory-picking modes hide plain files entirely (the GTK folder
/// chooser's shape); every other mode lists them.
pub fn showsFiles(mode: Mode) bool {
    return !acceptsDirs(mode);
}

pub fn primaryLabel(mode: Mode) [:0]const u8 {
    return switch (mode) {
        .open_file, .open_files => "Open",
        .select_dir, .select_destination => "Select",
        .save_file => "Save",
    };
}

pub fn defaultTitle(mode: Mode) [:0]const u8 {
    return switch (mode) {
        .open_file => "Open File",
        .open_files => "Open Files",
        .select_dir => "Select Folder",
        .save_file => "Save File",
        .select_destination => "Select Destination",
    };
}

// -- save-name validation ----------------------------------------

/// A usable leaf name: nonempty, no path separator, not "." or "..".
pub fn validSaveName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

// -- filter matching ---------------------------------------------

/// Case-insensitive glob match with `*` (any run) and `?` (any one
/// byte); every other byte is literal. Iterative single-star
/// backtracking, so a pattern full of stars stays linear.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_n = n;
            p += 1;
        } else if (p < pattern.len and (pattern[p] == '?' or
            std.ascii.toLower(pattern[p]) == std.ascii.toLower(name[n])))
        {
            p += 1;
            n += 1;
        } else if (star_p) |sp| {
            // Backtrack: let the last '*' swallow one more byte.
            star_n += 1;
            p = sp + 1;
            n = star_n;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Whether `name` (a basename) passes `filter`. An empty pattern
/// list is "All files".
pub fn filterMatches(filter: Filter, name: []const u8) bool {
    if (filter.patterns.len == 0) return true;
    for (filter.patterns) |pat| if (globMatch(pat, name)) return true;
    return false;
}

// -- tests -------------------------------------------------------

test "mode predicates" {
    const t = std.testing;
    try t.expect(needsNameEntry(.save_file));
    try t.expect(!needsNameEntry(.open_file));
    try t.expect(!needsNameEntry(.select_dir));
    try t.expect(allowsMulti(.open_files));
    try t.expect(!allowsMulti(.open_file));
    try t.expect(!allowsMulti(.save_file));
    try t.expect(acceptsDirs(.select_dir));
    try t.expect(acceptsDirs(.select_destination));
    try t.expect(!acceptsDirs(.open_files));
    try t.expect(!showsFiles(.select_dir));
    try t.expect(showsFiles(.save_file));
    try t.expect(showsFiles(.open_file));
}

test "primary label and title per mode" {
    const t = std.testing;
    try t.expectEqualStrings("Open", primaryLabel(.open_files));
    try t.expectEqualStrings("Select", primaryLabel(.select_destination));
    try t.expectEqualStrings("Save", primaryLabel(.save_file));
    try t.expectEqualStrings("Select Folder", defaultTitle(.select_dir));
}

test "validSaveName rejects empties, separators and dot names" {
    const t = std.testing;
    try t.expect(validSaveName("notes.txt"));
    try t.expect(validSaveName(".hidden"));
    try t.expect(validSaveName("..twodots.ok"));
    try t.expect(!validSaveName(""));
    try t.expect(!validSaveName("a/b"));
    try t.expect(!validSaveName("/"));
    try t.expect(!validSaveName("."));
    try t.expect(!validSaveName(".."));
    try t.expect(!validSaveName("a\x00b"));
}

test "globMatch literals and case folding" {
    const t = std.testing;
    try t.expect(globMatch("readme", "README"));
    try t.expect(globMatch("README", "readme"));
    try t.expect(!globMatch("readme", "readme.md"));
    try t.expect(!globMatch("readme.md", "readme"));
    try t.expect(globMatch("", ""));
    try t.expect(!globMatch("", "x"));
}

test "globMatch star" {
    const t = std.testing;
    try t.expect(globMatch("*.png", "shot.PNG"));
    try t.expect(globMatch("*.png", ".png"));
    try t.expect(!globMatch("*.png", "shot.png.bak"));
    try t.expect(globMatch("*", ""));
    try t.expect(globMatch("*", "anything"));
    try t.expect(globMatch("a*b*c", "aXXbYYc"));
    try t.expect(globMatch("a*b*c", "abc"));
    try t.expect(!globMatch("a*b*c", "acb"));
    try t.expect(globMatch("**.tar.*", "x.tar.gz"));
    // Backtracking: the first '*' must be able to swallow a 'b'.
    try t.expect(globMatch("*b", "abab"));
    try t.expect(globMatch("*.tar.gz", "a.tar.tar.gz"));
}

test "globMatch question mark" {
    const t = std.testing;
    try t.expect(globMatch("a?c", "abc"));
    try t.expect(globMatch("a?c", "aXc"));
    try t.expect(!globMatch("a?c", "ac"));
    try t.expect(!globMatch("a?c", "abbc"));
    try t.expect(globMatch("?*", "x"));
    try t.expect(!globMatch("?*", ""));
}

test "filterMatches any-pattern semantics and the all-files filter" {
    const t = std.testing;
    const images = Filter{ .label = "Images", .patterns = &.{ "*.png", "*.jpg" } };
    try t.expect(filterMatches(images, "cat.png"));
    try t.expect(filterMatches(images, "CAT.JPG"));
    try t.expect(!filterMatches(images, "cat.gif"));
    const all = Filter{ .label = "All files", .patterns = &.{} };
    try t.expect(filterMatches(all, "anything.xyz"));
    try t.expect(filterMatches(all, ""));
}
