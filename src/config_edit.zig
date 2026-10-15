//! Line-preserving edits of config.conf text: set or remove a key at the
//! top level or in one `[section]`, every other line kept byte for byte.
//! The line grammar is `config.ConfLine`. `Config.save` is the other
//! writer: it regenerates the whole file from a parsed Config (the
//! Preferences dialog), so it is wrong for a command that must keep the
//! user's comments and layout.

const std = @import("std");
const ConfLine = @import("config.zig").ConfLine;

pub const Error = error{ OutOfMemory, BadValue };

pub const Doc = struct {
    arena: std.mem.Allocator,
    /// Lines without their '\n'.
    lines: std.ArrayList([]const u8) = .empty,
    /// What each edit did, for the caller to print: "peer_hub = true",
    /// "[domain.x] removed peer_link".
    changes: std.ArrayList([]const u8) = .empty,

    /// `text` is borrowed and must outlive the Doc.
    pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Doc {
        var d: Doc = .{ .arena = arena };
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| try d.lines.append(arena, l);
        // The split yields an empty tail after a final '\n'.
        if (d.lines.items.len > 0 and d.lines.items[d.lines.items.len - 1].len == 0) _ = d.lines.pop();
        return d;
    }

    /// The text, each line ended by '\n'.
    pub fn render(self: *const Doc) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.lines.items) |l| {
            try out.appendSlice(self.arena, l);
            try out.append(self.arena, '\n');
        }
        return out.items;
    }

    /// The value of `key` in `section` (null: the top level) as the
    /// parser reads it: its last occurrence.
    pub fn get(self: *const Doc, section: ?[]const u8, key: []const u8) ?[]const u8 {
        const i = self.lastEntry(section, key) orelse return null;
        return ConfLine.of(self.lines.items[i]).entry.value;
    }

    pub fn hasSection(self: *const Doc, section: []const u8) bool {
        for (self.lines.items) |l| switch (ConfLine.of(l)) {
            .section => |s| if (std.mem.eql(u8, s, section)) return true,
            else => {},
        };
        return false;
    }

    /// Set `key = value`: the last occurrence is rewritten, else the line
    /// is added after the section's last entry, else a new section is
    /// appended at the end.
    /// @return error.BadValue when the key or value holds a control character.
    pub fn set(self: *Doc, section: ?[]const u8, key: []const u8, value: []const u8) Error!void {
        try checkText(key);
        try checkText(value);
        const line = try std.fmt.allocPrint(self.arena, "{s} = {s}", .{ key, value });
        if (self.lastEntry(section, key)) |i| {
            if (std.mem.eql(u8, ConfLine.of(self.lines.items[i]).entry.value, value)) return;
            self.lines.items[i] = line;
        } else if (self.insertionPoint(section)) |at| {
            try self.lines.insert(self.arena, at, line);
            // A key added right above a header keeps the blank line between.
            if (at + 1 < self.lines.items.len and ConfLine.of(self.lines.items[at + 1]) == .section)
                try self.lines.insert(self.arena, at + 1, "");
        } else {
            const n = self.lines.items.len;
            if (n > 0 and !empty(self.lines.items[n - 1])) try self.lines.append(self.arena, "");
            try self.lines.append(self.arena, try std.fmt.allocPrint(self.arena, "[{s}]", .{section.?}));
            try self.lines.append(self.arena, line);
        }
        try self.note(section, "{s} = {s}", .{ key, value });
    }

    /// Remove every `key` line of `section`; the section itself stays. A
    /// blank line left doubled (or leading the file) goes with it.
    pub fn remove(self: *Doc, section: ?[]const u8, key: []const u8) Error!void {
        var removed = false;
        while (self.lastEntry(section, key)) |i| {
            _ = self.lines.orderedRemove(i);
            removed = true;
            const items = self.lines.items;
            if ((i == 0 or empty(items[i - 1])) and i < items.len and empty(items[i])) _ = self.lines.orderedRemove(i);
        }
        if (removed) try self.note(section, "removed {s}", .{key});
    }

    fn note(self: *Doc, section: ?[]const u8, comptime fmt: []const u8, args: anytype) Error!void {
        const what = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.changes.append(self.arena, if (section) |s| try std.fmt.allocPrint(self.arena, "[{s}] {s}", .{ s, what }) else what);
    }

    /// Calls `f(ctx, index, line)` for each line of `section` (all of its
    /// occurrences; null: before the first header).
    fn inSection(self: *const Doc, section: ?[]const u8, ctx: anytype, f: fn (@TypeOf(ctx), usize, ConfLine) void) void {
        var inside = section == null;
        for (self.lines.items, 0..) |l, i| {
            const cl = ConfLine.of(l);
            switch (cl) {
                .section => |s| inside = if (section) |want| std.mem.eql(u8, s, want) else false,
                else => if (inside) f(ctx, i, cl),
            }
        }
    }

    fn lastEntry(self: *const Doc, section: ?[]const u8, key: []const u8) ?usize {
        const Ctx = struct {
            key: []const u8,
            found: ?usize = null,
            fn visit(c: *@This(), i: usize, cl: ConfLine) void {
                if (cl == .entry and std.mem.eql(u8, cl.entry.key, c.key)) c.found = i;
            }
        };
        var ctx: Ctx = .{ .key = key };
        self.inSection(section, &ctx, Ctx.visit);
        return ctx.found;
    }

    /// Where a new key of `section` goes: after its last entry, else
    /// right after its (last) header; at the top level, after the
    /// leading comment block. Null when the section does not exist.
    fn insertionPoint(self: *const Doc, section: ?[]const u8) ?usize {
        const Ctx = struct {
            last: ?usize = null,
            fn visit(c: *@This(), i: usize, cl: ConfLine) void {
                if (cl == .entry or cl == .malformed) c.last = i;
            }
        };
        var ctx: Ctx = .{};
        self.inSection(section, &ctx, Ctx.visit);
        if (ctx.last) |i| return i + 1;
        if (section) |want| {
            var header: ?usize = null;
            for (self.lines.items, 0..) |l, i| switch (ConfLine.of(l)) {
                .section => |s| if (std.mem.eql(u8, s, want)) {
                    header = i;
                },
                else => {},
            };
            return if (header) |h| h + 1 else null;
        }
        var i: usize = 0;
        while (i < self.lines.items.len and ConfLine.of(self.lines.items[i]) == .blank and !empty(self.lines.items[i])) : (i += 1)
        {}
        return i;
    }
};

fn checkText(s: []const u8) Error!void {
    for (s) |ch| if (ch < 0x20 or ch == 0x7f) return error.BadValue;
}

/// Nothing but whitespace (a comment is not empty).
fn empty(line: []const u8) bool {
    return std.mem.trim(u8, line, &std.ascii.whitespace).len == 0;
}

const t = std.testing;

fn edited(text: []const u8, comptime f: fn (*Doc) anyerror!void) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var doc = try Doc.parse(arena.allocator(), text);
    try f(&doc);
    return t.allocator.dupe(u8, try doc.render());
}

test "set rewrites in place, adds after the section's last entry, or appends a section; remove drops every occurrence" {
    const src =
        \\# my config
        \\font_size = 14
        \\
        \\# the lab box
        \\[domain.lab]
        \\  host = lab
        \\
        \\[profile.x]
        \\font_size = 9
        \\[domain.lab]
        \\peers = false
    ;
    const out = try edited(src, struct {
        fn f(d: *Doc) anyerror!void {
            try d.set(null, "peer_hub", "true");
            try d.set("domain.lab", "peers", "true");
            try d.set("domain.lab", "peer_link", "inbound");
            try d.set("domain.new", "host", "new");
            try d.remove("profile.x", "font_size");
            try t.expectEqualStrings("lab", d.get("domain.lab", "host").?);
            try t.expect(d.get(null, "host") == null);
            try t.expectError(error.BadValue, d.set(null, "k", "a\nb = c"));
        }
    }.f);
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        \\# my config
        \\font_size = 14
        \\peer_hub = true
        \\
        \\# the lab box
        \\[domain.lab]
        \\  host = lab
        \\
        \\[profile.x]
        \\[domain.lab]
        \\peers = true
        \\peer_link = inbound
        \\
        \\[domain.new]
        \\host = new
        \\
    , out);
}

test "a top-level key goes after the leading comments, and above a first header with a blank line" {
    const out = try edited("# header\n[domain.a]\nhost = a\n", struct {
        fn f(d: *Doc) anyerror!void {
            try d.set(null, "peer_hub", "true");
        }
    }.f);
    defer t.allocator.free(out);
    try t.expectEqualStrings("# header\npeer_hub = true\n\n[domain.a]\nhost = a\n", out);
    const fresh = try edited("", struct {
        fn f(d: *Doc) anyerror!void {
            try d.set(null, "a", "1");
            try d.set("s", "b", "2");
        }
    }.f);
    defer t.allocator.free(fresh);
    try t.expectEqualStrings("a = 1\n\n[s]\nb = 2\n", fresh);
    // Removing it again takes the blank line it left leading the file.
    const back = try edited(fresh, struct {
        fn f(d: *Doc) anyerror!void {
            try d.remove(null, "a");
        }
    }.f);
    defer t.allocator.free(back);
    try t.expectEqualStrings("[s]\nb = 2\n", back);
}
