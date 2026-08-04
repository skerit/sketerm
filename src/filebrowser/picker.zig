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

// -- typed name/location resolution -------------------------------

/// What the typed path turned out to BE on the host that owns it.
pub const TypedKind = enum { dir, file, missing };

/// What the picker does with a typed path of that kind.
pub const TypedAction = enum { navigate, accept, reject };

pub const Typed = struct {
    /// Absolute, normalized path ("." / ".." / repeated and trailing
    /// slashes resolved away; "/" stays "/").
    path: []const u8,
    /// The user wrote a trailing '/', i.e. "this is a folder".
    trailing_slash: bool,
};

/// Append one path segment run to `buf`, resolving "." and ".."
/// against what is already there. Returns the new write offset, or
/// null when the result would not fit.
fn pushSegments(buf: []u8, start: usize, src: []const u8) ?usize {
    var w = start;
    var it = std.mem.splitScalar(u8, src, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            while (w > 0 and buf[w - 1] != '/') w -= 1;
            if (w > 0) w -= 1;
            continue;
        }
        if (w + 1 + seg.len > buf.len) return null;
        buf[w] = '/';
        @memcpy(buf[w + 1 ..][0..seg.len], seg);
        w += 1 + seg.len;
    }
    return w;
}

/// Resolve what the user typed in the picker's name/location entry to
/// an absolute path on the CURRENT host. `cwd` is the directory on
/// show, `home` that host's home directory (null disables `~`).
/// Returns null for empty text, embedded NULs, or a result too long
/// for `buf`. Host-qualified specs are deliberately NOT parsed here:
/// a ':' is a literal filename byte, so changing host stays the
/// location bar's job.
pub fn resolveTyped(buf: []u8, cwd: []const u8, home: ?[]const u8, text: []const u8) ?Typed {
    if (text.len == 0) return null;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return null;
    var w: usize = 0;
    var rest = text;
    if (text[0] == '/') {
        // Absolute: cwd plays no part.
    } else if (text[0] == '~' and (text.len == 1 or text[1] == '/')) {
        const h = home orelse return null;
        w = pushSegments(buf, 0, h) orelse return null;
        rest = text[1..];
    } else {
        w = pushSegments(buf, 0, cwd) orelse return null;
    }
    w = pushSegments(buf, w, rest) orelse return null;
    return .{
        .path = if (w == 0) "/" else buf[0..w],
        .trailing_slash = text[text.len - 1] == '/',
    };
}

/// The picker's verdict on a resolved typed path. A directory is
/// browsed into unless the mode PICKS directories (or the user asked
/// for one with a trailing slash, which always browses); a file is
/// accepted by every file mode, including save_file, whose caller
/// then runs the overwrite confirmation; a name that does not exist
/// is only meaningful in save_file.
pub fn typedAction(mode: Mode, kind: TypedKind, trailing_slash: bool) TypedAction {
    return switch (kind) {
        .dir => if (trailing_slash) .navigate else if (acceptsDirs(mode)) .accept else .navigate,
        .file => if (trailing_slash or acceptsDirs(mode)) .reject else .accept,
        .missing => if (mode == .save_file and !trailing_slash) .accept else .reject,
    };
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

test "resolveTyped joins bare names against the shown directory" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    const r = resolveTyped(&buf, "/home/j/docs", null, "notes.txt") orelse return error.Unresolved;
    try t.expectEqualStrings("/home/j/docs/notes.txt", r.path);
    try t.expect(!r.trailing_slash);

    const sub = resolveTyped(&buf, "/home/j", null, "docs/notes.txt") orelse return error.Unresolved;
    try t.expectEqualStrings("/home/j/docs/notes.txt", sub.path);

    const root = resolveTyped(&buf, "/", null, "etc") orelse return error.Unresolved;
    try t.expectEqualStrings("/etc", root.path);
}

test "resolveTyped keeps absolute paths and normalizes them" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    const abs = resolveTyped(&buf, "/home/j", null, "/etc/fstab") orelse return error.Unresolved;
    try t.expectEqualStrings("/etc/fstab", abs.path);

    const messy = resolveTyped(&buf, "/home/j", null, "//usr//./local///bin") orelse return error.Unresolved;
    try t.expectEqualStrings("/usr/local/bin", messy.path);

    const up = resolveTyped(&buf, "/home/j/docs", null, "../pics/cat.png") orelse return error.Unresolved;
    try t.expectEqualStrings("/home/j/pics/cat.png", up.path);

    // Walking past the root clamps there rather than underflowing.
    const past = resolveTyped(&buf, "/home", null, "../../../..") orelse return error.Unresolved;
    try t.expectEqualStrings("/", past.path);

    const dot = resolveTyped(&buf, "/home/j", null, ".") orelse return error.Unresolved;
    try t.expectEqualStrings("/home/j", dot.path);
}

test "resolveTyped reports the trailing slash and expands ~" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    const slash = resolveTyped(&buf, "/home/j", null, "docs/") orelse return error.Unresolved;
    try t.expectEqualStrings("/home/j/docs", slash.path);
    try t.expect(slash.trailing_slash);

    const home = resolveTyped(&buf, "/etc", "/home/j", "~/docs") orelse return error.Unresolved;
    try t.expectEqualStrings("/home/j/docs", home.path);
    const bare = resolveTyped(&buf, "/etc", "/home/j", "~") orelse return error.Unresolved;
    try t.expectEqualStrings("/home/j", bare.path);
    // No home known: `~` is not silently treated as a filename.
    try t.expect(resolveTyped(&buf, "/etc", null, "~/docs") == null);
    // A '~' that does not start a home reference is a plain name.
    const literal = resolveTyped(&buf, "/etc", "/home/j", "~file") orelse return error.Unresolved;
    try t.expectEqualStrings("/etc/~file", literal.path);
}

test "resolveTyped refuses empty, NUL-bearing and oversized input" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expect(resolveTyped(&buf, "/home/j", null, "") == null);
    try t.expect(resolveTyped(&buf, "/home/j", null, "a\x00b") == null);
    var tiny: [8]u8 = undefined;
    try t.expect(resolveTyped(&tiny, "/home/j", null, "some/long/name") == null);
    // A colon stays a filename byte: host switching is the location
    // bar's job, not this entry's.
    const colon = resolveTyped(&buf, "/home/j", null, "box:/etc") orelse return error.Unresolved;
    try t.expectEqualStrings("/home/j/box:/etc", colon.path);
}

test "typedAction routes directories, files and new names per mode" {
    const t = std.testing;
    // Directories: browsed into, except where the mode picks them.
    try t.expectEqual(TypedAction.navigate, typedAction(.open_file, .dir, false));
    try t.expectEqual(TypedAction.navigate, typedAction(.save_file, .dir, false));
    try t.expectEqual(TypedAction.accept, typedAction(.select_dir, .dir, false));
    try t.expectEqual(TypedAction.accept, typedAction(.select_destination, .dir, false));
    // A trailing slash always means "browse", never "pick".
    try t.expectEqual(TypedAction.navigate, typedAction(.select_dir, .dir, true));

    // Files: every file mode takes them, directory modes cannot.
    try t.expectEqual(TypedAction.accept, typedAction(.open_file, .file, false));
    try t.expectEqual(TypedAction.accept, typedAction(.open_files, .file, false));
    try t.expectEqual(TypedAction.accept, typedAction(.save_file, .file, false));
    try t.expectEqual(TypedAction.reject, typedAction(.select_dir, .file, false));
    try t.expectEqual(TypedAction.reject, typedAction(.open_file, .file, true));

    // A name that does not exist is only a save target.
    try t.expectEqual(TypedAction.accept, typedAction(.save_file, .missing, false));
    try t.expectEqual(TypedAction.reject, typedAction(.save_file, .missing, true));
    try t.expectEqual(TypedAction.reject, typedAction(.open_file, .missing, false));
    try t.expectEqual(TypedAction.reject, typedAction(.open_files, .missing, false));
    try t.expectEqual(TypedAction.reject, typedAction(.select_dir, .missing, false));
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
