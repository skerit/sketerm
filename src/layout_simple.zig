//! `.layout` text format — a plain alternative to the JSON layout
//! save file. Indent-based, one node per line:
//!
//!   Dev
//!     hsplit
//!       pane bash @ /tmp
//!       pane fish @ /home
//!
//!   Build
//!     pane cargo build --release @ /home/skerit/foo
//!
//!   Logs
//!     pane less /var/log/syslog
//!
//! Rules:
//!   - lines starting with `#` are comments
//!   - blank lines are ignored
//!   - 2 spaces per indent level
//!   - column 0 (no indent): tab title
//!   - the next indent level: a tree node, one of:
//!       pane <command...> [@ <cwd>]
//!       hsplit / vsplit       (followed by 2 indented children)
//!   - a tab with one pane skips the wrapping `pane` keyword (an
//!     hsplit/vsplit at level 1 with two children does the same)

const std = @import("std");
const layout = @import("layout.zig");

/// A parsed simple-format layout. Owns its memory via the arena.
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    value: layout.Layout,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    BadIndent,
    UnknownNode,
    SplitNeedsTwoChildren,
    EmptyTab,
    OutOfMemory,
};

const Line = struct {
    indent: usize,
    text: []const u8, // trimmed of leading indent only
    line_no: usize,
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Tokenize into trimmed lines with indent counts.
    var lines: std.ArrayList(Line) = .{};
    defer lines.deinit(allocator);

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        var indent: usize = 0;
        var i: usize = 0;
        while (i < raw.len and raw[i] == ' ') : (i += 1) indent += 1;
        if (indent % 2 != 0) return ParseError.BadIndent;
        const tail = raw[i..];
        const trimmed = std.mem.trimRight(u8, tail, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try lines.append(allocator, .{
            .indent = indent / 2,
            .text = trimmed,
            .line_no = line_no,
        });
    }

    var tabs: std.ArrayList(layout.TabSpec) = .{};

    var idx: usize = 0;
    while (idx < lines.items.len) {
        const head = lines.items[idx];
        if (head.indent != 0) return ParseError.BadIndent;
        idx += 1;

        // Collect indented body lines for this tab.
        const body_start = idx;
        while (idx < lines.items.len and lines.items[idx].indent > 0) : (idx += 1) {}
        const body = lines.items[body_start..idx];
        if (body.len == 0) return ParseError.EmptyTab;

        const tree = try parseTree(a, body, 1);
        try tabs.append(a, .{
            .title = try a.dupe(u8, head.text),
            .tree = tree,
        });
    }

    return .{
        .arena = arena,
        .value = .{ .version = 2, .tabs = try tabs.toOwnedSlice(a) },
    };
}

fn parseTree(a: std.mem.Allocator, lines: []const Line, expected_indent: usize) ParseError!layout.Tree {
    if (lines.len == 0) return ParseError.EmptyTab;
    const head = lines[0];
    if (head.indent != expected_indent) return ParseError.BadIndent;

    if (std.mem.eql(u8, head.text, "hsplit") or std.mem.eql(u8, head.text, "vsplit")) {
        const orient: layout.Orient = if (head.text[0] == 'h') .horizontal else .vertical;
        // Two children expected, each at indent+1, possibly each
        // followed by their own subtree.
        const inner = lines[1..];
        const children = try collectTwo(a, inner, expected_indent + 1);
        const slots = try a.alloc(layout.Tree, 2);
        slots[0] = children.first;
        slots[1] = children.second;
        return .{ .split = .{ .orientation = orient, .ratio = 0.5, .children = slots } };
    }

    if (std.mem.startsWith(u8, head.text, "pane")) {
        return .{ .pane = try parsePane(a, head.text) };
    }

    // Bare title — assume single pane with that text as the command.
    return ParseError.UnknownNode;
}

fn collectTwo(a: std.mem.Allocator, body: []const Line, child_indent: usize) ParseError!struct {
    first: layout.Tree,
    second: layout.Tree,
} {
    // Find the two top-level children at `child_indent`.
    var first_start: ?usize = null;
    var second_start: ?usize = null;
    for (body, 0..) |ln, i| {
        if (ln.indent == child_indent) {
            if (first_start == null) {
                first_start = i;
            } else if (second_start == null) {
                second_start = i;
                break;
            }
        }
    }
    if (first_start == null or second_start == null) return ParseError.SplitNeedsTwoChildren;
    const first_lines = body[first_start.? .. second_start.?];
    const second_lines = body[second_start.?..];
    return .{
        .first = try parseTree(a, first_lines, child_indent),
        .second = try parseTree(a, second_lines, child_indent),
    };
}

fn parsePane(a: std.mem.Allocator, text: []const u8) ParseError!layout.PaneSpec {
    // text begins with "pane "; parse: pane <command...> [@ <cwd>]
    const after = std.mem.trimLeft(u8, text["pane".len..], " \t");
    var cmd: []const u8 = after;
    var cwd: []const u8 = "";
    if (std.mem.indexOf(u8, after, " @ ")) |at| {
        cmd = std.mem.trimRight(u8, after[0..at], " \t");
        cwd = std.mem.trimLeft(u8, after[at + 3 ..], " \t");
    }
    if (cmd.len == 0) cmd = std.posix.getenv("SHELL") orelse "/bin/bash";

    // Split command on spaces — naive (no quote handling). For
    // commands that need quoting users still have JSON.
    var parts: std.ArrayList([]const u8) = .{};
    var ti = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (ti.next()) |tok| {
        try parts.append(a, try a.dupe(u8, tok));
    }
    return .{
        .cwd = try a.dupe(u8, if (cwd.len > 0) cwd else "/"),
        .command = try parts.toOwnedSlice(a),
    };
}

test "parses single-pane tabs" {
    const src =
        \\Dev
        \\  pane bash @ /tmp
        \\
        \\Logs
        \\  pane less /var/log
    ;
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tabs.len);
    try std.testing.expectEqualStrings("Dev", parsed.value.tabs[0].title);
    try std.testing.expectEqualStrings("/tmp", parsed.value.tabs[0].tree.pane.cwd);
    try std.testing.expectEqualStrings("bash", parsed.value.tabs[0].tree.pane.command[0]);
    try std.testing.expectEqualStrings("less", parsed.value.tabs[1].tree.pane.command[0]);
    try std.testing.expectEqualStrings("/var/log", parsed.value.tabs[1].tree.pane.command[1]);
}

test "parses hsplit" {
    const src =
        \\Stack
        \\  hsplit
        \\    pane bash @ /tmp
        \\    pane fish @ /home
    ;
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
    const tree = parsed.value.tabs[0].tree;
    try std.testing.expectEqual(layout.Orient.horizontal, tree.split.orientation);
    try std.testing.expectEqual(@as(usize, 2), tree.split.children.len);
    try std.testing.expectEqualStrings("/tmp", tree.split.children[0].pane.cwd);
    try std.testing.expectEqualStrings("/home", tree.split.children[1].pane.cwd);
}

test "ignores comments and blanks" {
    const src =
        \\# A comment
        \\
        \\Dev
        \\  # nested comment
        \\  pane bash @ /
    ;
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
}

test "nested splits" {
    const src =
        \\Big
        \\  hsplit
        \\    pane bash @ /tmp
        \\    vsplit
        \\      pane fish @ /home
        \\      pane htop @ /
    ;
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();
    const tree = parsed.value.tabs[0].tree;
    try std.testing.expectEqual(layout.Orient.horizontal, tree.split.orientation);
    const right = tree.split.children[1].split;
    try std.testing.expectEqual(layout.Orient.vertical, right.orientation);
    try std.testing.expectEqualStrings("htop", right.children[1].pane.command[0]);
}
