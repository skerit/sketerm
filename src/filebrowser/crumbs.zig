//! GTK-free breadcrumb segmentation: a location (host, path) becomes
//! the ordered clickable segments of the path bar.

const std = @import("std");

/// One breadcrumb segment. `label` and `path` are slices of the
/// caller's inputs (or static literals), so splitting allocates
/// nothing.
pub const Segment = struct {
    /// Display text: the host string for a remote root, "/" for a
    /// local root, otherwise the path component.
    label: []const u8,
    /// Absolute directory this segment navigates to.
    path: []const u8,
    /// The location root: it has no parent, so its dropdown lists
    /// its CHILDREN where the others list siblings.
    root: bool = false,
    /// Segments were dropped between the root and this one because
    /// `out` had no room; the bar renders an ellipsis marker here.
    elided: bool = false,
};

/// Split `path` into breadcrumb segments, `out[0]` always being the
/// root (labelled with `host` when the location is remote, so a
/// remote breadcrumb names its host). A path deeper than `out` keeps
/// the root plus the DEEPEST segments and marks the first survivor
/// elided.
/// @return the filled prefix of `out`.
pub fn split(host: []const u8, path: []const u8, out: []Segment) []Segment {
    if (out.len == 0) return out[0..0];
    out[0] = .{
        .label = if (host.len > 0) host else "/",
        .path = "/",
        .root = true,
    };
    var n: usize = 1;
    if (out.len == 1) return out[0..1];

    const total = count(path);
    const room = out.len - 1;
    const skip = if (total > room) total - room else 0;

    var i: usize = 0;
    var idx: usize = 0;
    while (i < path.len) : (idx += 1) {
        while (i < path.len and path[i] == '/') i += 1;
        const start = i;
        while (i < path.len and path[i] != '/') i += 1;
        if (i == start) break;
        if (idx < skip) continue;
        out[n] = .{
            .label = path[start..i],
            .path = path[0..i],
            .elided = skip > 0 and idx == skip,
        };
        n += 1;
    }
    return out[0..n];
}

/// Path components in `path` (empty components ignored).
pub fn count(path: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |_| n += 1;
    return n;
}

/// Longest segment label rendered in full. A wider one is cut so a
/// single absurd component cannot own the whole bar; the segment's
/// tooltip still carries the full path.
pub const MAX_LABEL_CHARS = 24;

/// Shorten `label` to MAX_LABEL_CHARS bytes with a trailing marker,
/// never splitting a UTF-8 sequence. The bar deliberately does NOT
/// use Pango ellipsizing here: an ellipsizing label shrinks to
/// nothing under pressure, which collapsed every segment to "..."
/// instead of letting the oldest ones scroll out of view.
/// @return a slice of `label` or of `buf`.
pub fn shortLabel(label: []const u8, buf: []u8) []const u8 {
    if (label.len <= MAX_LABEL_CHARS or buf.len < MAX_LABEL_CHARS) return label;
    var keep: usize = MAX_LABEL_CHARS - 3;
    while (keep > 0 and label[keep] & 0xc0 == 0x80) keep -= 1;
    @memcpy(buf[0..keep], label[0..keep]);
    @memcpy(buf[keep .. keep + 3], "...");
    return buf[0 .. keep + 3];
}

/// The directory whose listing fills `seg`'s dropdown: its parent
/// (so the dropdown offers lateral jumps), or the root itself, which
/// offers its children instead.
pub fn dropdownSource(seg: Segment) []const u8 {
    if (seg.root) return seg.path;
    return std.fs.path.dirname(seg.path) orelse "/";
}

test "split names the root and every component" {
    var buf: [8]Segment = undefined;
    const local = split("", "/home/x", &buf);
    try std.testing.expectEqual(@as(usize, 3), local.len);
    try std.testing.expectEqualStrings("/", local[0].label);
    try std.testing.expectEqualStrings("/", local[0].path);
    try std.testing.expect(local[0].root);
    try std.testing.expectEqualStrings("home", local[1].label);
    try std.testing.expectEqualStrings("/home", local[1].path);
    try std.testing.expectEqualStrings("x", local[2].label);
    try std.testing.expectEqualStrings("/home/x", local[2].path);
}

test "split labels a remote root with its host" {
    var buf: [8]Segment = undefined;
    const remote = split("user@box", "/srv/data", &buf);
    try std.testing.expectEqualStrings("user@box", remote[0].label);
    try std.testing.expectEqualStrings("/", remote[0].path);
    try std.testing.expectEqualStrings("srv", remote[1].label);
    try std.testing.expectEqualStrings("/srv/data", remote[2].path);
}

test "split tolerates roots trailing and doubled slashes" {
    var buf: [8]Segment = undefined;
    try std.testing.expectEqual(@as(usize, 1), split("", "/", &buf).len);
    try std.testing.expectEqual(@as(usize, 1), split("", "", &buf).len);
    const trailing = split("", "/a/b/", &buf);
    try std.testing.expectEqual(@as(usize, 3), trailing.len);
    try std.testing.expectEqualStrings("/a/b", trailing[2].path);
    const doubled = split("", "/a//b", &buf);
    try std.testing.expectEqual(@as(usize, 3), doubled.len);
    try std.testing.expectEqualStrings("b", doubled[2].label);
}

test "a path deeper than the buffer keeps the root and the tail" {
    var buf: [3]Segment = undefined;
    const deep = split("", "/a/b/c/d", &buf);
    try std.testing.expectEqual(@as(usize, 3), deep.len);
    try std.testing.expectEqualStrings("/", deep[0].label);
    try std.testing.expectEqualStrings("c", deep[1].label);
    try std.testing.expect(deep[1].elided);
    try std.testing.expectEqualStrings("d", deep[2].label);
    try std.testing.expect(!deep[2].elided);
    // A one-slot buffer still answers something navigable, and a
    // zero-slot one never writes.
    var one: [1]Segment = undefined;
    try std.testing.expectEqual(@as(usize, 1), split("", "/a/b", &one).len);
    var none: [0]Segment = undefined;
    try std.testing.expectEqual(@as(usize, 0), split("", "/a/b", &none).len);
}

test "shortLabel cuts only over-long names, on a UTF-8 boundary" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("docs", shortLabel("docs", &buf));
    const exact = "a" ** MAX_LABEL_CHARS;
    try std.testing.expectEqualStrings(exact, shortLabel(exact, &buf));
    const long = "a" ** 40;
    const cut = shortLabel(long, &buf);
    try std.testing.expectEqual(@as(usize, MAX_LABEL_CHARS), cut.len);
    try std.testing.expectEqualStrings("...", cut[cut.len - 3 ..]);
    // A multi-byte codepoint straddling the cut is dropped whole.
    const wide = "aaaaaaaaaaaaaaaaaaaa\u{00e9}\u{00e9}\u{00e9}\u{00e9}";
    const wcut = shortLabel(wide, &buf);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wcut[0 .. wcut.len - 3]));
    try std.testing.expect(wcut.len <= MAX_LABEL_CHARS);
}

test "dropdownSource lists siblings, and children at the root" {
    var buf: [8]Segment = undefined;
    const segs = split("", "/a/b", &buf);
    try std.testing.expectEqualStrings("/", dropdownSource(segs[0]));
    try std.testing.expectEqualStrings("/", dropdownSource(segs[1]));
    try std.testing.expectEqualStrings("/a", dropdownSource(segs[2]));
}
