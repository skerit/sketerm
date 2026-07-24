//! GTK-free file-browser identity and persisted view state.

const std = @import("std");

pub const FileRef = struct {
    /// Empty means the local mux daemon; otherwise the mux host string.
    host: []const u8 = "",
    path: []const u8 = "/",

    pub fn local(path: []const u8) FileRef {
        return .{ .path = path };
    }

    pub fn eql(a: FileRef, b: FileRef) bool {
        return std.mem.eql(u8, a.host, b.host) and std.mem.eql(u8, a.path, b.path);
    }

    pub fn format(self: FileRef, out: []u8) ![]const u8 {
        if (self.host.len == 0) return std.fmt.bufPrint(out, "{s}", .{self.path});
        return std.fmt.bufPrint(out, "{s}:{s}", .{ self.host, self.path });
    }
};

pub const ParsedSpec = struct {
    ref: FileRef,
    inherits_host: bool = false,
};

/// Parse a location; a bare path inherits `current_host`.
pub fn parseSpec(spec: []const u8, current_host: []const u8) ParsedSpec {
    if (spec.len == 0) return .{ .ref = .{ .host = current_host, .path = "/" }, .inherits_host = true };
    if (spec[0] == '/') return .{ .ref = .{ .host = current_host, .path = spec }, .inherits_host = true };
    if (std.mem.indexOf(u8, spec, ":/")) |i| {
        const host = spec[0..i];
        return .{ .ref = .{
            .host = if (host.len == 0 or std.mem.eql(u8, host, "local")) "" else host,
            .path = spec[i + 1 ..],
        } };
    }
    return .{ .ref = .{ .host = current_host, .path = spec }, .inherits_host = true };
}

pub const LocationKind = enum { directory, search, collection, panel };
pub const ViewMode = enum { details, icons, compact, miller };
pub const SortKey = enum { name, size, kind, mtime, ctime, owner, group, permissions };

pub const TabState = struct {
    kind: LocationKind = .directory,
    location: FileRef = .{},
    back: []const FileRef = &.{},
    forward: []const FileRef = &.{},
    expanded: []const FileRef = &.{},
    selected: []const FileRef = &.{},
    view: ViewMode = .details,
    sort: SortKey = .name,
    descending: bool = false,
    dirs_first: bool = true,
    show_hidden: bool = false,
    filter: []const u8 = "",
    scroll: f64 = 0,
    /// Search predicate, collection name, or panel command.
    virtual_spec: []const u8 = "",
};

pub const PaneState = struct {
    version: u32 = 1,
    active_tab: u32 = 0,
    browser_visible: bool = true,
    tabs: []const TabState = &.{},
};

pub fn dupeRef(a: std.mem.Allocator, ref: FileRef) !FileRef {
    return .{ .host = try a.dupe(u8, ref.host), .path = try a.dupe(u8, ref.path) };
}

pub fn dupeRefs(a: std.mem.Allocator, refs: []const FileRef) ![]const FileRef {
    const out = try a.alloc(FileRef, refs.len);
    for (refs, 0..) |ref, i| out[i] = try dupeRef(a, ref);
    return out;
}

test "FileRef parses, formats, and keeps host identity explicit" {
    const local = parseSpec("local:/tmp", "remote").ref;
    try std.testing.expectEqualStrings("", local.host);
    try std.testing.expectEqualStrings("/tmp", local.path);
    const inherited = parseSpec("/srv", "user@box");
    try std.testing.expect(inherited.inherits_host);
    try std.testing.expectEqualStrings("user@box", inherited.ref.host);
    const remote = parseSpec("udp:box:/var", "").ref;
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("udp:box:/var", try remote.format(&buf));
}

test "PaneState JSON round-trip preserves future browser state" {
    const refs = [_]FileRef{.{ .host = "box", .path = "/src" }};
    const tabs = [_]TabState{.{
        .location = .{ .host = "box", .path = "/work" },
        .back = &refs,
        .expanded = &refs,
        .selected = &refs,
        .view = .miller,
        .sort = .mtime,
        .descending = true,
        .show_hidden = true,
        .filter = "*.zig",
    }};
    const state = PaneState{ .active_tab = 0, .tabs = &tabs };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(state, .{}, &out.writer);
    const parsed = try std.json.parseFromSlice(PaneState, std.testing.allocator, out.written(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(ViewMode.miller, parsed.value.tabs[0].view);
    try std.testing.expectEqualStrings("box", parsed.value.tabs[0].selected[0].host);
    try std.testing.expectEqualStrings("*.zig", parsed.value.tabs[0].filter);
}
