//! Source map v3 decoder: VLQ `mappings` plus `sources`/`names`, looked up by generated position.
//!
//! Index maps (`sections`) are refused as `error.IndexMapUnsupported`. A map
//! without `names` (TeaVM emits none) still resolves source and line.

const std = @import("std");

pub const Segment = struct {
    gen_col: u32,
    /// -1 when the segment maps to no source.
    src: i32 = -1,
    src_line: u32 = 0,
    src_col: u32 = 0,
    name: i32 = -1,
};

pub const Origin = struct {
    source: []const u8,
    /// 1-based.
    line: u32,
    /// 1-based.
    column: u32,
    name: ?[]const u8,
};

pub const Map = struct {
    sources: []const []const u8,
    names: []const []const u8,
    segments: []const Segment,
    /// `segments[line_starts[l]..line_starts[l+1]]` are generated line l's, sorted by column.
    line_starts: []const u32,

    /// The original position of generated (0-based) `line`, `column`: the last segment at or before the column.
    pub fn lookup(self: Map, line: u32, column: u32) ?Origin {
        if (line + 1 >= self.line_starts.len) return null;
        const segs = self.segments[self.line_starts[line]..self.line_starts[line + 1]];
        var best: ?Segment = null;
        for (segs) |s| {
            if (s.gen_col > column) break;
            if (s.src >= 0) best = s;
        }
        const s = best orelse return null;
        if (@as(usize, @intCast(s.src)) >= self.sources.len) return null;
        return .{
            .source = self.sources[@intCast(s.src)],
            .line = s.src_line + 1,
            .column = s.src_col + 1,
            .name = if (s.name >= 0 and @as(usize, @intCast(s.name)) < self.names.len) self.names[@intCast(s.name)] else null,
        };
    }
};

const Raw = struct {
    version: i64 = 3,
    sources: []const ?[]const u8 = &.{},
    sourceRoot: ?[]const u8 = null,
    names: []const []const u8 = &.{},
    mappings: []const u8 = "",
    sections: ?std.json.Value = null,
};

/// Parse a map; all memory comes from `arena`.
pub fn parse(arena: std.mem.Allocator, json: []const u8) !Map {
    const raw = std.json.parseFromSliceLeaky(Raw, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.NotASourceMap;
    if (raw.sections != null) return error.IndexMapUnsupported;
    if (raw.version != 3) return error.NotASourceMap;
    const sources = try arena.alloc([]const u8, raw.sources.len);
    for (raw.sources, 0..) |s, i| {
        const name = s orelse "";
        const root = raw.sourceRoot orelse "";
        sources[i] = if (root.len == 0 or name.len == 0 or std.mem.indexOf(u8, name, "://") != null or name[0] == '/')
            name
        else
            try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ root, if (root[root.len - 1] == '/') "" else "/", name });
    }
    var segments: std.ArrayList(Segment) = .empty;
    var line_starts: std.ArrayList(u32) = .empty;
    try line_starts.append(arena, 0);
    // Every field but the generated column is relative to the previous segment across lines.
    var src: i64 = 0;
    var src_line: i64 = 0;
    var src_col: i64 = 0;
    var name: i64 = 0;
    var gen_col: i64 = 0;
    var i: usize = 0;
    const m = raw.mappings;
    var line_first: usize = 0;
    while (i <= m.len) {
        if (i == m.len or m[i] == ';') {
            sortLine(segments.items[line_first..]);
            try line_starts.append(arena, @intCast(segments.items.len));
            line_first = segments.items.len;
            gen_col = 0;
            i += 1;
            continue;
        }
        if (m[i] == ',') {
            i += 1;
            continue;
        }
        var fields: [5]i64 = undefined;
        var n: usize = 0;
        while (i < m.len and m[i] != ',' and m[i] != ';') {
            if (n == 5) return error.BadMappings;
            fields[n] = try vlq(m, &i);
            n += 1;
        }
        if (n != 1 and n != 4 and n != 5) return error.BadMappings;
        gen_col += fields[0];
        var seg: Segment = .{ .gen_col = @intCast(@max(gen_col, 0)) };
        if (n >= 4) {
            src += fields[1];
            src_line += fields[2];
            src_col += fields[3];
            if (src < 0 or src_line < 0 or src_col < 0) return error.BadMappings;
            seg.src = @intCast(src);
            seg.src_line = @intCast(src_line);
            seg.src_col = @intCast(src_col);
        }
        if (n == 5) {
            name += fields[4];
            seg.name = @intCast(name);
        }
        try segments.append(arena, seg);
    }
    return .{ .sources = sources, .names = raw.names, .segments = segments.items, .line_starts = line_starts.items };
}

fn sortLine(segs: []Segment) void {
    std.mem.sort(Segment, segs, {}, struct {
        fn lt(_: void, a: Segment, b: Segment) bool {
            return a.gen_col < b.gen_col;
        }
    }.lt);
}

/// Decode one base64 VLQ value at `i.*`, advancing past it.
pub fn vlq(s: []const u8, i: *usize) !i64 {
    var result: i64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (i.* >= s.len) return error.BadMappings;
        const d = digit(s[i.*]) orelse return error.BadMappings;
        i.* += 1;
        result |= @as(i64, d & 31) << shift;
        if (d & 32 == 0) break;
        if (shift > 55) return error.BadMappings;
        shift += 5;
    }
    const neg = result & 1 != 0;
    result >>= 1;
    return if (neg) -result else result;
}

fn digit(ch: u8) ?u8 {
    return switch (ch) {
        'A'...'Z' => ch - 'A',
        'a'...'z' => ch - 'a' + 26,
        '0'...'9' => ch - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

/// The `sourceMappingURL` named by a script's trailing comment, or null.
pub fn commentUrl(script: []const u8) ?[]const u8 {
    var rest = script;
    var found: ?[]const u8 = null;
    while (std.mem.indexOf(u8, rest, "sourceMappingURL=")) |at| {
        const before = rest[0..at];
        const lead = std.mem.trimEnd(u8, before, " \t");
        if (std.mem.endsWith(u8, lead, "//#") or std.mem.endsWith(u8, lead, "//@") or
            std.mem.endsWith(u8, lead, "/*#") or std.mem.endsWith(u8, lead, "/*@"))
        {
            const tail = rest[at + "sourceMappingURL=".len ..];
            var end: usize = 0;
            while (end < tail.len and !std.ascii.isWhitespace(tail[end]) and !(tail[end] == '*' and end + 1 < tail.len and tail[end + 1] == '/')) end += 1;
            if (end > 0) found = tail[0..end];
        }
        rest = rest[at + 1 ..];
    }
    return found;
}

/// The map JSON of a `data:` url (base64 or percent-free plain); null when it is not one.
pub fn dataUrl(arena: std.mem.Allocator, url: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, url, "data:")) return null;
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return error.BadDataUrl;
    const meta = url[5..comma];
    const body = url[comma + 1 ..];
    if (!std.mem.endsWith(u8, meta, ";base64")) return body;
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(body) catch return error.BadDataUrl;
    const out = try arena.alloc(u8, n);
    dec.decode(out, body) catch return error.BadDataUrl;
    return out;
}

test "VLQ digits decode signs and continuations" {
    var i: usize = 0;
    try std.testing.expectEqual(@as(i64, 0), try vlq("A", &i));
    i = 0;
    try std.testing.expectEqual(@as(i64, 1), try vlq("C", &i));
    i = 0;
    try std.testing.expectEqual(@as(i64, -1), try vlq("D", &i));
    i = 0;
    try std.testing.expectEqual(@as(i64, 16), try vlq("gB", &i));
    try std.testing.expectEqual(@as(usize, 2), i);
    i = 0;
    try std.testing.expectEqual(@as(i64, -1000), try vlq("x+B", &i));
    i = 0;
    try std.testing.expectError(error.BadMappings, vlq("g", &i));
}

test "a hand-made map resolves generated positions to source, line and name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Line 0: col 0 -> a.js 0:0 name 0 ("hot"); col 9 -> a.js 4:2 name 1 ("cold").
    // Line 2 (after an empty line 1): col 4 -> b.java 9:0, no name.
    const map = try parse(arena,
        \\{"version":3,"sourceRoot":"src","sources":["a.js","b.java"],"names":["hot","cold"],"mappings":"AAAAA,SAIEC;;ICKF"}
    );
    const a = map.lookup(0, 3).?;
    try std.testing.expectEqualStrings("src/a.js", a.source);
    try std.testing.expectEqual(@as(u32, 1), a.line);
    try std.testing.expectEqualStrings("hot", a.name.?);
    const b = map.lookup(0, 20).?;
    try std.testing.expectEqual(@as(u32, 5), b.line);
    try std.testing.expectEqual(@as(u32, 3), b.column);
    try std.testing.expectEqualStrings("cold", b.name.?);
    try std.testing.expect(map.lookup(1, 0) == null);
    try std.testing.expect(map.lookup(2, 0) == null);
    const c = map.lookup(2, 4).?;
    try std.testing.expectEqualStrings("src/b.java", c.source);
    try std.testing.expectEqual(@as(u32, 10), c.line);
    try std.testing.expect(c.name == null);
    try std.testing.expect(map.lookup(9, 0) == null);
    try std.testing.expectError(error.IndexMapUnsupported, parse(arena, "{\"version\":3,\"sections\":[]}"));
    try std.testing.expectError(error.BadMappings, parse(arena, "{\"version\":3,\"sources\":[],\"mappings\":\"AA\"}"));
}

test "the trailing comment and data urls name the map" {
    try std.testing.expectEqualStrings("app.js.map", commentUrl("var a=1;\n//# sourceMappingURL=app.js.map\n").?);
    try std.testing.expectEqualStrings("x.map", commentUrl("/*# sourceMappingURL=x.map */").?);
    try std.testing.expect(commentUrl("var s = 'sourceMappingURL=nope';") == null);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("{\"version\":3}", (try dataUrl(arena_state.allocator(), "data:application/json;base64,eyJ2ZXJzaW9uIjozfQ==")).?);
    try std.testing.expectEqualStrings("{}", (try dataUrl(arena_state.allocator(), "data:application/json,{}")).?);
    try std.testing.expect((try dataUrl(arena_state.allocator(), "https://x/y.map")) == null);
}
