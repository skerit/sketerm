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
pub const SortKey = enum {
    name,
    size,
    kind,
    mtime,
    ctime,
    owner,
    group,
    permissions,
    atime,
    btime,
    extension,
    allocated,
    nlink,
};

/// Optional details-view columns; the name column is always present.
/// Render order is declaration order.
pub const Column = enum {
    kind,
    detailed_type,
    mime,
    extension,
    permissions,
    octal,
    owner,
    group,
    nlink,
    size,
    allocated,
    mtime,
    ctime,
    atime,
    btime,
    where,
    target,

    pub fn sortKey(self: Column) SortKey {
        return switch (self) {
            .kind => .kind,
            // Type strings derive from the extension, so that IS
            // their natural order.
            .detailed_type, .mime, .extension => .extension,
            .permissions, .octal => .permissions,
            .owner => .owner,
            .group => .group,
            .nlink => .nlink,
            .size => .size,
            .allocated => .allocated,
            .mtime => .mtime,
            .ctime => .ctime,
            .atime => .atime,
            .btime => .btime,
            // Symlink targets / locations have no order of their own.
            .where, .target => .name,
        };
    }

    pub fn title(self: Column) [*:0]const u8 {
        return switch (self) {
            .kind => "Type",
            .detailed_type => "Detailed type",
            .mime => "MIME type",
            .extension => "Extension",
            .permissions => "Permissions",
            .octal => "Octal",
            .owner => "Owner",
            .group => "Group",
            .nlink => "Links",
            .size => "Size",
            .allocated => "On disk",
            .mtime => "Modified",
            .ctime => "Changed",
            .atime => "Accessed",
            .btime => "Created",
            .where => "Location",
            .target => "Target",
        };
    }

    /// Default pixel width of the WHOLE column slot -- the cell's
    /// horizontal insets and the resize grip come out of it, so the
    /// header button and the data cell can be budgeted from one
    /// number and cannot drift apart. A user drag overrides it
    /// (TabState.col_widths).
    pub fn width(self: Column) i32 {
        return switch (self) {
            .kind => 96,
            .detailed_type => 160,
            .mime => 150,
            .extension => 76,
            .permissions => 104,
            .octal => 64,
            .owner, .group => 92,
            .nlink => 60,
            .size => 100,
            .allocated => 100,
            .mtime, .ctime, .atime, .btime => 160,
            .where => 200,
            .target => 212,
        };
    }

    /// Cell/header text alignment; numeric columns read best ragged-left.
    pub fn xalign(self: Column) f32 {
        return switch (self) {
            .size, .allocated, .nlink, .octal => 1.0,
            else => 0.0,
        };
    }
};

/// Default width of an extra (key-named) column. Its values are
/// free-form text, so it gets one generous ellipsized slot.
pub const ATTR_COLUMN_WIDTH: i32 = 172;

/// Narrowest a column may be dragged: below this the header title is
/// nothing but an ellipsis.
pub const MIN_COLUMN_WIDTH: i32 = 40;

pub const default_columns = [_]Column{ .permissions, .size, .mtime };

pub const TabState = struct {
    kind: LocationKind = .directory,
    location: FileRef = .{},
    back: []const FileRef = &.{},
    forward: []const FileRef = &.{},
    expanded: []const FileRef = &.{},
    selected: []const FileRef = &.{},
    view: ViewMode = .details,
    /// Empty = the built-in default set (also what pre-column state
    /// files deserialize to).
    columns: []const Column = &.{},
    /// Extended-attribute columns (full `user.*` names).
    attr_columns: []const []const u8 = &.{},
    /// Dragged column widths, parallel to `columns`; 0 (or a short /
    /// absent list) means that column keeps its default width.
    col_widths: []const i32 = &.{},
    /// Dragged widths of the extra columns, parallel to
    /// `attr_columns`, same 0-means-default convention.
    attr_col_widths: []const i32 = &.{},
    /// Dragged Name-column width; 0 = auto (take the leftover).
    name_width: i32 = 0,
    sort: SortKey = .name,
    descending: bool = false,
    dirs_first: bool = true,
    show_hidden: bool = false,
    /// Group the listing by the active sort key, with one collapsible
    /// header per bucket. Off by default (and for pre-grouping state
    /// files, which have no key at all).
    grouped: bool = false,
    /// Zoom step index (see ui/browser/views.zig ZOOM_STEPS). The
    /// default IS the step a pre-zoom state file deserializes to.
    zoom: u8 = 1,
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

test "column choices survive a round-trip and old state keeps the defaults" {
    const cols = [_]Column{ .kind, .owner, .mtime };
    const tabs = [_]TabState{.{ .columns = &cols }};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(PaneState{ .tabs = &tabs }, .{}, &out.writer);
    const parsed = try std.json.parseFromSlice(PaneState, std.testing.allocator, out.written(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualSlices(Column, &cols, parsed.value.tabs[0].columns);

    // A pre-column state file has no "columns" key at all.
    const old = try std.json.parseFromSlice(PaneState, std.testing.allocator,
        \\{"version":1,"active_tab":0,"browser_visible":true,"tabs":[{"view":"details"}]}
    , .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer old.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.value.tabs[0].columns.len);
}

test "grouping and zoom round-trip and old state files keep their defaults" {
    const tabs = [_]TabState{.{ .grouped = true, .zoom = 4 }};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(PaneState{ .tabs = &tabs }, .{}, &out.writer);
    const parsed = try std.json.parseFromSlice(PaneState, std.testing.allocator, out.written(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.tabs[0].grouped);
    try std.testing.expectEqual(@as(u8, 4), parsed.value.tabs[0].zoom);

    // A state file written before grouping/zoom existed still loads,
    // with grouping off and the default zoom step.
    const old = try std.json.parseFromSlice(PaneState, std.testing.allocator,
        \\{"version":1,"active_tab":1,"browser_visible":true,"tabs":[
        \\{"kind":"directory","location":{"host":"box","path":"/work"},"view":"compact",
        \\ "columns":["size"],"sort":"size","descending":true,"dirs_first":false,
        \\ "show_hidden":true,"filter":"log","scroll":0,"virtual_spec":""}]}
    , .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer old.deinit();
    try std.testing.expect(!old.value.tabs[0].grouped);
    try std.testing.expectEqual(@as(u8, 1), old.value.tabs[0].zoom);
    try std.testing.expectEqual(ViewMode.compact, old.value.tabs[0].view);
    try std.testing.expectEqualStrings("log", old.value.tabs[0].filter);
    try std.testing.expectEqualStrings("box", old.value.tabs[0].location.host);
}

test "dragged column widths round-trip and old state files keep the defaults" {
    const cols = [_]Column{ .permissions, .size };
    const widths = [_]i32{ 0, 210 };
    const attrs = [_][]const u8{"user.note"};
    const attr_widths = [_]i32{240};
    const tabs = [_]TabState{.{
        .columns = &cols,
        .col_widths = &widths,
        .attr_columns = &attrs,
        .attr_col_widths = &attr_widths,
    }};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(PaneState{ .tabs = &tabs }, .{}, &out.writer);
    const parsed = try std.json.parseFromSlice(PaneState, std.testing.allocator, out.written(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualSlices(i32, &widths, parsed.value.tabs[0].col_widths);
    try std.testing.expectEqualSlices(i32, &attr_widths, parsed.value.tabs[0].attr_col_widths);

    // A state file written before resizable columns existed still
    // loads, with every column back at its default width.
    const old = try std.json.parseFromSlice(PaneState, std.testing.allocator,
        \\{"version":1,"active_tab":0,"browser_visible":true,"tabs":[
        \\{"view":"details","columns":["size","mtime"],"attr_columns":["user.note"]}]}
    , .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer old.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.value.tabs[0].col_widths.len);
    try std.testing.expectEqual(@as(usize, 0), old.value.tabs[0].attr_col_widths.len);
    // A width list SHORTER than the column list is legal: the
    // remaining columns fall back to their defaults.
    const short = try std.json.parseFromSlice(PaneState, std.testing.allocator,
        \\{"tabs":[{"columns":["size","mtime"],"col_widths":[120]}]}
    , .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer short.deinit();
    try std.testing.expectEqual(@as(usize, 1), short.value.tabs[0].col_widths.len);
    try std.testing.expectEqual(@as(i32, 120), short.value.tabs[0].col_widths[0]);
}

test "column sort keys and widths stay in the header/row contract" {
    // Every column must map to a sort key the Dir comparator knows,
    // and target must not claim a bogus ordering of its own.
    try std.testing.expectEqual(SortKey.permissions, Column.permissions.sortKey());
    try std.testing.expectEqual(SortKey.name, Column.target.sortKey());
    for (std.enums.values(Column)) |col| try std.testing.expect(col.width() > 0);
}
