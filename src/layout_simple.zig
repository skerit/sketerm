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

const std = @import("std");
const layout = @import("layout.zig");

/// Ceiling for a `.layout` file on load. The format is hand-written, so
/// a file this size is already far past anything a person types.
pub const MAX_FILE_BYTES: usize = 1024 * 1024;

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
    UnclosedQuote,
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
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(allocator);

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        var indent: usize = 0;
        var i: usize = 0;
        while (i < raw.len and raw[i] == ' ') : (i += 1) indent += 1;
        const tail = raw[i..];
        const trimmed = std.mem.trimEnd(u8, tail, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (indent % 2 != 0) return ParseError.BadIndent;
        try lines.append(allocator, .{
            .indent = indent / 2,
            .text = trimmed,
            .line_no = line_no,
        });
    }

    var tabs: std.ArrayList(layout.TabSpec) = .empty;

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

    // hsplit / vsplit, optionally with `@ <ratio>` (0.0..1.0).
    if (nodeWord(head.text, "hsplit") or nodeWord(head.text, "vsplit")) {
        const word = head.text[0..6];
        const orient: layout.Orient = if (word[0] == 'h') .horizontal else .vertical;
        const rest = std.mem.trimStart(u8, head.text[6..], " \t");
        var ratio: f32 = 0.5;
        if (rest.len > 0) {
            if (rest[0] != '@') return ParseError.UnknownNode;
            const after = std.mem.trimStart(u8, rest[1..], " \t");
            ratio = std.fmt.parseFloat(f32, after) catch 0.5;
            if (!std.math.isFinite(ratio) or ratio <= 0.0 or ratio >= 1.0) ratio = 0.5;
        }
        const inner = lines[1..];
        const children = try collectTwo(a, inner, expected_indent + 1);
        const slots = try a.alloc(layout.Tree, 2);
        slots[0] = children.first;
        slots[1] = children.second;
        return .{ .split = .{ .orientation = orient, .ratio = ratio, .children = slots } };
    }

    if (nodeWord(head.text, "pane")) {
        if (lines.len != 1) return ParseError.BadIndent;
        return .{ .pane = try parsePane(a, head.text) };
    }

    return ParseError.UnknownNode;
}

fn nodeWord(text: []const u8, word: []const u8) bool {
    return std.mem.startsWith(u8, text, word) and
        (text.len == word.len or text[word.len] == ' ' or text[word.len] == '\t');
}

fn collectTwo(a: std.mem.Allocator, body: []const Line, child_indent: usize) ParseError!struct {
    first: layout.Tree,
    second: layout.Tree,
} {
    // Find the two top-level children at `child_indent`.
    var first_start: ?usize = null;
    var second_start: ?usize = null;
    for (body, 0..) |ln, i| {
        if (ln.indent < child_indent or (i == 0 and ln.indent != child_indent)) return ParseError.BadIndent;
        if (ln.indent == child_indent) {
            if (first_start == null) {
                first_start = i;
            } else if (second_start == null) {
                second_start = i;
            } else {
                return ParseError.SplitNeedsTwoChildren;
            }
        }
    }
    if (first_start == null or second_start == null) return ParseError.SplitNeedsTwoChildren;
    const first_lines = body[first_start.?..second_start.?];
    const second_lines = body[second_start.?..];
    return .{
        .first = try parseTree(a, first_lines, child_indent),
        .second = try parseTree(a, second_lines, child_indent),
    };
}

fn parsePane(a: std.mem.Allocator, text: []const u8) ParseError!layout.PaneSpec {
    // text begins with "pane "; parse: pane <command...> [@ <cwd>]
    const after = std.mem.trimStart(u8, text["pane".len..], " \t");
    var cmd: []const u8 = after;
    var cwd: []const u8 = "";
    if (try cwdSeparator(after)) |at| {
        cmd = std.mem.trimEnd(u8, after[0..at], " \t");
        cwd = std.mem.trimStart(u8, after[at + 3 ..], " \t");
    }
    if (cmd.len == 0) cmd = @import("util/profile.zig").getenv("SHELL") orelse "/bin/bash";

    // Tokenise with rudimentary quoting: `"..."` and `'...'` are taken
    // verbatim (no escape sequences inside), runs of spaces split.
    var parts: std.ArrayList([]const u8) = .empty;
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(a);
    var i: usize = 0;
    while (i < cmd.len) {
        if (cmd[i] == ' ' or cmd[i] == '\t') {
            i += 1;
            continue;
        }
        token.clearRetainingCapacity();
        while (i < cmd.len and cmd[i] != ' ' and cmd[i] != '\t') {
            if (cmd[i] == '"' or cmd[i] == '\'') {
                const quote = cmd[i];
                i += 1;
                const start = i;
                while (i < cmd.len and cmd[i] != quote) i += 1;
                if (i == cmd.len) return ParseError.UnclosedQuote;
                try token.appendSlice(a, cmd[start..i]);
                i += 1;
            } else {
                try token.append(a, cmd[i]);
                i += 1;
            }
        }
        try parts.append(a, try a.dupe(u8, token.items));
    }
    return .{
        .cwd = try a.dupe(u8, if (cwd.len > 0) cwd else "/"),
        .command = try parts.toOwnedSlice(a),
    };
}

/// A quoted ` @ ` belongs to the command, not the working-directory suffix.
fn cwdSeparator(text: []const u8) ParseError!?usize {
    var quote: ?u8 = null;
    for (text, 0..) |ch, i| {
        if (quote) |q| {
            if (ch == q) quote = null;
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
        } else if (std.mem.startsWith(u8, text[i..], " @ ")) {
            return i;
        }
    }
    if (quote != null) return ParseError.UnclosedQuote;
    return null;
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

test "split with custom ratio" {
    const src =
        \\Stack
        \\  hsplit @ 0.7
        \\    pane bash @ /tmp
        \\    pane htop @ /
    ;
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f32, 0.7), parsed.value.tabs[0].tree.split.ratio);
}

test "quoted command preserves spaces" {
    const src =
        \\Run
        \\  pane bash -c "echo hello world" @ /
    ;
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();
    const cmd = parsed.value.tabs[0].tree.pane.command;
    try std.testing.expectEqual(@as(usize, 3), cmd.len);
    try std.testing.expectEqualStrings("bash", cmd[0]);
    try std.testing.expectEqualStrings("-c", cmd[1]);
    try std.testing.expectEqualStrings("echo hello world", cmd[2]);
}

test "single-quoted args preserved" {
    const src =
        \\R
        \\  pane sh -c 'while true; do echo x; sleep 1; done'
    ;
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();
    const cmd = parsed.value.tabs[0].tree.pane.command;
    try std.testing.expectEqual(@as(usize, 3), cmd.len);
    try std.testing.expectEqualStrings("while true; do echo x; sleep 1; done", cmd[2]);
}

test "layout tree rejects extra roots, split children, and nested leaf nodes" {
    const cases = [_]struct { src: []const u8, err: ParseError }{
        .{ .src = "Tab\n  pane a\n  pane b", .err = error.BadIndent },
        .{ .src = "Tab\n  pane a\n    pane b", .err = error.BadIndent },
        .{ .src = "Tab\n  hsplit\n    pane a\n    pane b\n    pane c", .err = error.SplitNeedsTwoChildren },
        .{ .src = "Tab\n  hsplit\n      pane lost\n    pane a\n    pane b", .err = error.BadIndent },
        .{ .src = "Tab\n  panel sh", .err = error.UnknownNode },
        .{ .src = "Tab\n  hsplitter\n    pane a\n    pane b", .err = error.UnknownNode },
    };
    for (cases) |case| try std.testing.expectError(case.err, parse(std.testing.allocator, case.src));
}

test "comments and blanks do not impose indentation and nonfinite ratios use the default" {
    var parsed = try parse(std.testing.allocator, " # comment\n \nTab\n  hsplit @ nan\n    pane a\n    pane b");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), parsed.value.tabs[0].tree.split.ratio);
}

test "quoted cwd separators stay in the command and unclosed quotes are refused" {
    var parsed = try parse(std.testing.allocator, "Tab\n  pane sh -c 'echo a @ b' @ /tmp");
    defer parsed.deinit();
    const pane = parsed.value.tabs[0].tree.pane;
    try std.testing.expectEqualStrings("echo a @ b", pane.command[2]);
    try std.testing.expectEqualStrings("/tmp", pane.cwd);
    try std.testing.expectError(error.UnclosedQuote, parse(std.testing.allocator, "Tab\n  pane sh -c 'echo a @ b"));
}

test "quoted fragments join their argument and preserve empty arguments" {
    var parsed = try parse(std.testing.allocator, "Tab\n  pane cmd --name=\"a @ b\"'!' \"\" @ /tmp");
    defer parsed.deinit();
    const pane = parsed.value.tabs[0].tree.pane;
    try std.testing.expectEqual(@as(usize, 3), pane.command.len);
    try std.testing.expectEqualStrings("--name=a @ b!", pane.command[1]);
    try std.testing.expectEqualStrings("", pane.command[2]);
    try std.testing.expectEqualStrings("/tmp", pane.cwd);
}
