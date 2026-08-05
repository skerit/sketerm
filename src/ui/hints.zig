//! Keyboard hints / quick-select mode (kitty "hints kitten", WezTerm
//! QuickSelect). Scans the visible screen for URLs, file paths, and
//! hex hashes, overlays a short label on each, and lets the user pick
//! one by typing its label — open (URLs) or copy (everything else)
//! without touching the mouse.
//!
//! This module is pure logic: scanning, label assignment, text
//! extraction. Window owns the mode state + key handling; GridPass
//! draws the overlays from `Screen.hints_overlay`.

const std = @import("std");
const c = @import("../c.zig").c;
const Screen = @import("../grid/screen.zig").Screen;
const Cell = @import("../grid/cell.zig").Cell;
const url_scan = @import("../grid/url_scan.zig");

pub const Kind = enum { url, path, hash, custom };

/// What activating a match does. Mirrors `config.HintAction`; kept
/// separate so this module stays independent of the config type.
pub const Action = enum { open, copy, paste, select, command };

/// A user-defined rule: a POSIX extended regular expression plus what
/// to do with what it matches. Scanned before the built-in scanners,
/// in the order the config file lists them.
pub const Rule = struct {
    pattern: []const u8,
    action: Action = .copy,
    /// Shell command for `action = .command`, with `{match}` replaced
    /// by the matched text, shell-quoted.
    command: []const u8 = "",
};

pub const Match = struct {
    /// Display row (0..rows-1) at collect time.
    row: u16,
    /// Inclusive start / exclusive end columns.
    col_start: u16,
    col_end: u16,
    kind: Kind,
    /// Extracted text, owned by the caller's allocator. Captured at
    /// collect time so scrolling can't change what gets activated.
    text: []u8,
    /// What this match does when picked.
    action: Action = .copy,
    /// Command template for `.command` matches. Owned like `text`,
    /// because the config arena it came from can be replaced while
    /// the mode is open.
    command: []u8 = &.{},
    /// Assigned label ("a", "fj", ...). All labels in one batch share
    /// the same length, so no label is a prefix of another.
    label: [2]u8 = .{ 0, 0 },
    label_len: u8 = 0,
};

/// Home-row-first label alphabet.
pub const ALPHABET = "asdfghjklqwertyuiopzxcvbnm";

/// A configured alphabet is only used when it can actually label
/// things: at least two distinct printable ASCII characters, no
/// duplicates (a repeated character would give two matches the same
/// label). Anything else falls back to the built-in set.
pub fn validAlphabet(alphabet: []const u8) ?[]const u8 {
    return @import("../config.zig").validHintAlphabet(alphabet);
}

/// Hard cap: 26 single-char + first rows of 2-char labels is far more
/// than ever fits on screen anyway.
pub const MAX_MATCHES = 26 * 26;

pub fn freeMatches(allocator: std.mem.Allocator, matches: []Match) void {
    for (matches) |m| {
        allocator.free(m.text);
        if (m.command.len > 0) allocator.free(m.command);
    }
}

/// Scan the visible rows of `screen` for hintable items, in reading
/// order. Caller owns the returned slice AND each match's `text`
/// (use `freeMatches`). Labels are already assigned.
pub fn collectVisible(allocator: std.mem.Allocator, screen: *const Screen) ![]Match {
    return collectVisibleWith(allocator, screen, &.{}, ALPHABET);
}

/// `collectVisible` with user-defined rules and a label alphabet.
/// Rules are tried first on every row, so one can claim text a
/// built-in scanner would otherwise have taken.
pub fn collectVisibleWith(
    allocator: std.mem.Allocator,
    screen: *const Screen,
    rules: []const Rule,
    alphabet: []const u8,
) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer {
        freeMatches(allocator, out.items);
        out.deinit(allocator);
    }

    var compiled = try CompiledRules.init(allocator, rules);
    defer compiled.deinit(allocator);

    const view_off: i32 = @intCast(@min(screen.view_offset, screen.scrollbackCount()));
    var d: u16 = 0;
    while (d < screen.rows) : (d += 1) {
        const buf_row: i32 = @as(i32, d) - view_off;
        const cells = screen.lineCellsAtPub(buf_row) orelse continue;
        // Both scanners dedupe against everything already found on
        // THIS row, rules included — a rule that claimed a path must
        // stop the built-in path scanner finding it again.
        const row_first = out.items.len;
        try scanRowRules(allocator, cells, d, compiled, row_first, &out);
        try scanRowAll(allocator, screen, cells, d, row_first, &out);
        if (out.items.len >= MAX_MATCHES) break;
    }

    assignLabels2(out.items, alphabet);
    return try out.toOwnedSlice(allocator);
}

/// Rule patterns compiled once per hint-mode entry rather than once
/// per row. A pattern that does not compile is dropped with its rule,
/// so one bad line in the config cannot disable the others.
const CompiledRules = struct {
    res: []?*c.regex_t = &.{},
    rules: []const Rule = &.{},

    fn init(allocator: std.mem.Allocator, rules: []const Rule) !CompiledRules {
        if (rules.len == 0) return .{};
        const res = try allocator.alloc(?*c.regex_t, rules.len);
        errdefer allocator.free(res);
        for (res, rules) |*slot, rule| {
            slot.* = null;
            if (rule.pattern.len == 0) continue;
            const pat_z = allocator.allocSentinel(u8, rule.pattern.len, 0) catch continue;
            defer allocator.free(pat_z);
            @memcpy(pat_z, rule.pattern);
            // glibc's regex_t has bitfields translate-c cannot model,
            // so it is opaque to Zig and cannot live on the stack.
            const buf = std.c.malloc(256) orelse continue;
            const re: *c.regex_t = @ptrCast(@alignCast(buf));
            if (c.regcomp(re, pat_z.ptr, c.REG_EXTENDED) != 0) {
                std.c.free(buf);
                continue;
            }
            slot.* = re;
        }
        return .{ .res = res, .rules = rules };
    }

    fn deinit(self: *CompiledRules, allocator: std.mem.Allocator) void {
        for (self.res) |maybe| {
            if (maybe) |re| {
                c.regfree(re);
                std.c.free(@ptrCast(re));
            }
        }
        if (self.res.len > 0) allocator.free(self.res);
    }
};

/// Run every compiled rule over one row's text. Column mapping is by
/// cell index, so a row containing wide or combining characters maps
/// back through the same byte→column table the extractor builds.
fn scanRowRules(
    allocator: std.mem.Allocator,
    cells: []const Cell,
    row: u16,
    compiled: CompiledRules,
    row_first: usize,
    out: *std.ArrayList(Match),
) !void {
    if (compiled.rules.len == 0) return;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    var col_of: std.ArrayList(u16) = .empty;
    defer col_of.deinit(allocator);
    for (cells, 0..) |cl, i| {
        if (cl.flags & 0b0000_0010 != 0) continue; // wide continuation
        const cp: u32 = if (cl.rune == 0) ' ' else cl.rune;
        var ub: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &ub) catch continue;
        for (ub[0..n]) |b| {
            try line.append(allocator, b);
            try col_of.append(allocator, @intCast(i));
        }
    }
    if (line.items.len == 0) return;
    const line_z = try allocator.allocSentinel(u8, line.items.len, 0);
    defer allocator.free(line_z);
    @memcpy(line_z, line.items);

    for (compiled.res, compiled.rules) |maybe, rule| {
        const re = maybe orelse continue;
        var pos: usize = 0;
        while (pos < line_z.len) {
            var m: c.regmatch_t = undefined;
            // REG_NOTBOL past the start: `^` must anchor to the row,
            // not to wherever the previous match ended.
            const flags: c_int = if (pos == 0) 0 else c.REG_NOTBOL;
            if (c.regexec(re, line_z.ptr + pos, 1, &m, flags) != 0) break;
            const so: usize = pos + @as(usize, @intCast(m.rm_so));
            const eo: usize = pos + @as(usize, @intCast(m.rm_eo));
            if (eo == so) {
                pos = so + 1;
                continue;
            }
            const col_start = col_of.items[so];
            const col_end: u16 = if (eo < col_of.items.len) col_of.items[eo] else @intCast(cells.len);
            if (!overlaps(out.items[row_first..], col_start, col_end)) {
                try out.append(allocator, .{
                    .row = row,
                    .col_start = col_start,
                    .col_end = col_end,
                    .kind = .custom,
                    .text = try allocator.dupe(u8, line_z[so..eo]),
                    .action = rule.action,
                    .command = if (rule.command.len > 0) try allocator.dupe(u8, rule.command) else &.{},
                });
            }
            pos = eo;
        }
    }
}

/// All scanners for one row, deduplicated: OSC 8 link runs win over
/// plain URLs win over paths win over hashes (checked via overlap
/// against matches already collected for this row).
fn scanRowAll(
    allocator: std.mem.Allocator,
    screen: *const Screen,
    cells: []const Cell,
    row: u16,
    row_first: usize,
    out: *std.ArrayList(Match),
) !void {

    // 1. OSC 8 hyperlink runs (consecutive cells with the link flag
    //    and the same link id).
    {
        var col: usize = 0;
        while (col < cells.len) {
            if ((cells[col].flags & 0b0000_0100) == 0 or cells[col].reserved == 0) {
                col += 1;
                continue;
            }
            const id = cells[col].reserved;
            const start = col;
            while (col < cells.len and (cells[col].flags & 0b0000_0100) != 0 and cells[col].reserved == id) : (col += 1) {}
            if (screen.linkUri(id)) |uri| {
                try out.append(allocator, .{
                    .row = row,
                    .col_start = @intCast(start),
                    .col_end = @intCast(col),
                    .kind = .url,
                    .action = .open,
                    .text = try allocator.dupe(u8, uri),
                });
            }
        }
    }

    // 2. Plain-text URLs.
    {
        var buf: [16]url_scan.Match = undefined;
        const n = url_scan.scanRow(cells, &buf);
        for (buf[0..n]) |m| {
            if (overlaps(out.items[row_first..], m.col_start, m.col_end)) continue;
            try out.append(allocator, .{
                .row = row,
                .col_start = m.col_start,
                .col_end = m.col_end,
                .kind = .url,
                .action = .open,
                .text = try extractCells(allocator, cells[m.col_start..m.col_end]),
            });
        }
    }

    // 3. File paths: a token containing '/' made of path characters,
    //    anchored at a word boundary. Catches `/abs/path`, `~/x`,
    //    `./rel`, and `src/ui/pane.zig:123` alike.
    {
        var col: usize = 0;
        while (col < cells.len) {
            if (!isPathChar(cells[col].rune) or (col > 0 and isPathChar(cells[col - 1].rune))) {
                col += 1;
                continue;
            }
            const start = col;
            var has_slash = false;
            while (col < cells.len and isPathChar(cells[col].rune)) : (col += 1) {
                if (cells[col].rune == '/') has_slash = true;
            }
            var end = col;
            // Trim trailing sentence punctuation (`.`, `,`, `:`, …).
            while (end > start and isTrailingPunct(cells[end - 1].rune)) end -= 1;
            if (!has_slash or end - start < 3) continue;
            // A lone slash-and-punct run ("///", "/.") isn't a path.
            var alnum: usize = 0;
            for (cells[start..end]) |cl| {
                if (isAlnum(cl.rune)) alnum += 1;
            }
            if (alnum < 2) continue;
            if (overlaps(out.items[row_first..], @intCast(start), @intCast(end))) continue;
            try out.append(allocator, .{
                .row = row,
                .col_start = @intCast(start),
                .col_end = @intCast(end),
                .kind = .path,
                .action = .open,
                .text = try extractCells(allocator, cells[start..end]),
            });
        }
    }

    // 4. Hex hashes (git SHAs etc.): 7-64 hex digits at word
    //    boundaries, requiring at least one letter so plain numbers
    //    ("12345678") don't light up.
    {
        var col: usize = 0;
        while (col < cells.len) {
            if (!isHexChar(cells[col].rune) or (col > 0 and isWordChar(cells[col - 1].rune))) {
                col += 1;
                continue;
            }
            const start = col;
            while (col < cells.len and isHexChar(cells[col].rune)) : (col += 1) {}
            const end = col;
            const len = end - start;
            // Reject when the run continues with word chars (it's an
            // identifier, not a hash).
            if (end < cells.len and isWordChar(cells[end].rune)) continue;
            if (len < 7 or len > 64) continue;
            var has_alpha = false;
            for (cells[start..end]) |cl| {
                if (cl.rune >= 'a' and cl.rune <= 'f') has_alpha = true;
            }
            if (!has_alpha) continue;
            if (overlaps(out.items[row_first..], @intCast(start), @intCast(end))) continue;
            try out.append(allocator, .{
                .row = row,
                .col_start = @intCast(start),
                .col_end = @intCast(end),
                .kind = .hash,
                .action = .copy,
                .text = try extractCells(allocator, cells[start..end]),
            });
        }
    }
}

fn overlaps(row_matches: []const Match, lo: u16, hi: u16) bool {
    for (row_matches) |m| {
        if (lo < m.col_end and m.col_start < hi) return true;
    }
    return false;
}

fn extractCells(allocator: std.mem.Allocator, cells: []const Cell) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (cells) |cl| {
        if (cl.flags & 0b0000_0010 != 0) continue; // wide continuation
        if (cl.rune == 0) continue;
        var ub: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cl.rune), &ub) catch continue;
        try out.appendSlice(allocator, ub[0..n]);
    }
    return try out.toOwnedSlice(allocator);
}

/// Assign labels in reading order. ≤26 matches get single-char
/// labels; more get uniform two-char labels (uniform length keeps the
/// set prefix-free).
pub fn assignLabels(matches: []Match) void {
    assignLabels2(matches, ALPHABET);
}

pub fn assignLabels2(matches: []Match, alphabet_in: []const u8) void {
    const alphabet = validAlphabet(alphabet_in) orelse ALPHABET;
    if (matches.len <= alphabet.len) {
        for (matches, 0..) |*m, i| {
            m.label[0] = alphabet[i];
            m.label_len = 1;
        }
    } else {
        for (matches, 0..) |*m, i| {
            m.label[0] = alphabet[(i / alphabet.len) % alphabet.len];
            m.label[1] = alphabet[i % alphabet.len];
            m.label_len = 2;
        }
    }
}

/// `path[:line[:col]]` split of a path match's text. Compiler/grep
/// output styles `file.zig:12`, `file.zig:12:5`, and bare paths all
/// parse; a non-numeric suffix leaves the text untouched.
pub const FileLine = struct {
    path: []const u8,
    line: ?u32 = null,
    col: ?u32 = null,
};

pub fn parseFileLine(text: []const u8) FileLine {
    var path = text;
    var line: ?u32 = null;
    var col: ?u32 = null;
    var rounds: u8 = 0;
    while (rounds < 2) : (rounds += 1) {
        const colon = std.mem.lastIndexOfScalar(u8, path, ':') orelse break;
        const seg = path[colon + 1 ..];
        if (seg.len == 0 or seg.len > 9) break;
        const v = std.fmt.parseInt(u32, seg, 10) catch break;
        // Second numeric suffix found: what we took for the line was
        // actually the column.
        if (line) |prev| {
            col = prev;
        }
        line = v;
        path = path[0..colon];
    }
    return .{ .path = path, .line = line, .col = col };
}

/// Build the `sh -c` command line that opens `abs_path` in `editor`.
/// Template form substitutes {file} (shell-quoted), {line}, {col};
/// bare form appends the near-universal `+line file`
/// (vim/nvim/emacs/nano/micro/kak). Caller frees.
pub fn buildEditorCommand(
    allocator: std.mem.Allocator,
    editor: []const u8,
    abs_path: []const u8,
    line: ?u32,
    col: ?u32,
) ![]u8 {
    const shellquote = @import("../util/shellquote.zig");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (std.mem.indexOf(u8, editor, "{file}") != null) {
        var i: usize = 0;
        while (i < editor.len) {
            const rest = editor[i..];
            if (std.mem.startsWith(u8, rest, "{file}")) {
                try shellquote.appendQuoted(&out, allocator, abs_path);
                i += "{file}".len;
            } else if (std.mem.startsWith(u8, rest, "{line}")) {
                try out.print(allocator, "{d}", .{line orelse 1});
                i += "{line}".len;
            } else if (std.mem.startsWith(u8, rest, "{col}")) {
                try out.print(allocator, "{d}", .{col orelse 1});
                i += "{col}".len;
            } else {
                try out.append(allocator, editor[i]);
                i += 1;
            }
        }
    } else {
        try out.appendSlice(allocator, editor);
        if (line) |ln| try out.print(allocator, " +{d}", .{ln});
        try out.append(allocator, ' ');
        try shellquote.appendQuoted(&out, allocator, abs_path);
    }
    return try out.toOwnedSlice(allocator);
}

fn isPathChar(cp: u32) bool {
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '/', '.', '_', '-', '~', '+', '@', '%', ':', '#' => true,
        else => false,
    };
}

fn isTrailingPunct(cp: u32) bool {
    return switch (cp) {
        '.', ',', ':', ';', '!', '?', ')', ']', '}', '\'', '"' => true,
        else => false,
    };
}

fn isAlnum(cp: u32) bool {
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        else => false,
    };
}

fn isHexChar(cp: u32) bool {
    return switch (cp) {
        '0'...'9', 'a'...'f' => true,
        else => false,
    };
}

fn isWordChar(cp: u32) bool {
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/' => true,
        else => false,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const StylePool = @import("../grid/style_pool.zig").Pool;

fn feedStr(s: *Screen, text: []const u8) void {
    for (text) |b| s.apply(.{ .print_byte = b });
}

test "collectVisible finds URL, path, and hash with labels" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 6);
    defer s.deinit();
    feedStr(s, "see https://example.com/x and /etc/passwd plus deadbeef123");

    const matches = try collectVisible(std.testing.allocator, s);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqual(Kind.url, matches[0].kind);
    try std.testing.expectEqualStrings("https://example.com/x", matches[0].text);
    try std.testing.expectEqual(Kind.path, matches[1].kind);
    try std.testing.expectEqualStrings("/etc/passwd", matches[1].text);
    try std.testing.expectEqual(Kind.hash, matches[2].kind);
    try std.testing.expectEqualStrings("deadbeef123", matches[2].text);
    // Labels: single char, home-row order.
    try std.testing.expectEqual(@as(u8, 'a'), matches[0].label[0]);
    try std.testing.expectEqual(@as(u8, 's'), matches[1].label[0]);
    try std.testing.expectEqual(@as(u8, 'd'), matches[2].label[0]);
}

test "path with line suffix and relative path detected; identifiers not hashed" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 4);
    defer s.deinit();
    feedStr(s, "src/ui/pane.zig:123 abcdef12345ghi");

    const matches = try collectVisible(std.testing.allocator, s);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(Kind.path, matches[0].kind);
    try std.testing.expectEqualStrings("src/ui/pane.zig:123", matches[0].text);
}

test "URL is not double-reported as path" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 4);
    defer s.deinit();
    feedStr(s, "https://host/a/b.html");

    const matches = try collectVisible(std.testing.allocator, s);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(Kind.url, matches[0].kind);
}

test "parseFileLine splits path / line / col" {
    const fl1 = parseFileLine("src/ui/pane.zig:123");
    try std.testing.expectEqualStrings("src/ui/pane.zig", fl1.path);
    try std.testing.expectEqual(@as(?u32, 123), fl1.line);
    try std.testing.expectEqual(@as(?u32, null), fl1.col);

    const fl2 = parseFileLine("/abs/x.c:12:5");
    try std.testing.expectEqualStrings("/abs/x.c", fl2.path);
    try std.testing.expectEqual(@as(?u32, 12), fl2.line);
    try std.testing.expectEqual(@as(?u32, 5), fl2.col);

    const fl3 = parseFileLine("./plain/path");
    try std.testing.expectEqualStrings("./plain/path", fl3.path);
    try std.testing.expectEqual(@as(?u32, null), fl3.line);

    // Non-numeric suffix stays in the path (C++ scope, URLs-as-paths).
    const fl4 = parseFileLine("ns::func");
    try std.testing.expectEqualStrings("ns::func", fl4.path);
}

test "buildEditorCommand: bare editor, +line, template" {
    const a = std.testing.allocator;

    const c1 = try buildEditorCommand(a, "nvim", "/tmp/x.zig", 12, null);
    defer a.free(c1);
    try std.testing.expectEqualStrings("nvim +12 /tmp/x.zig", c1);

    const c2 = try buildEditorCommand(a, "nvim", "/tmp/has space.txt", null, null);
    defer a.free(c2);
    try std.testing.expectEqualStrings("nvim '/tmp/has space.txt'", c2);

    const c3 = try buildEditorCommand(a, "code -g {file}:{line}:{col}", "/tmp/x.zig", 12, 5);
    defer a.free(c3);
    try std.testing.expectEqualStrings("code -g /tmp/x.zig:12:5", c3);

    // Missing line/col default to 1 in templates.
    const c4 = try buildEditorCommand(a, "hx {file}:{line}", "/a/b", null, null);
    defer a.free(c4);
    try std.testing.expectEqualStrings("hx /a/b:1", c4);
}

fn collectRules(s: *Screen, rules: []const Rule) ![]Match {
    return collectVisibleWith(std.testing.allocator, s, rules, ALPHABET);
}

test "a custom rule matches, carries its action, and wins over the built-ins" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 4);
    defer s.deinit();
    feedStr(s, "fix PROJ-1234 in /etc/hosts");

    const rules = [_]Rule{.{ .pattern = "[A-Z]+-[0-9]+", .action = .command, .command = "open {match}" }};
    const matches = try collectRules(s, &rules);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(Kind.custom, matches[0].kind);
    try std.testing.expectEqualStrings("PROJ-1234", matches[0].text);
    try std.testing.expectEqual(Action.command, matches[0].action);
    try std.testing.expectEqualStrings("open {match}", matches[0].command);
    // The built-in path scanner still runs for what the rule left.
    try std.testing.expectEqual(Kind.path, matches[1].kind);
    try std.testing.expectEqualStrings("/etc/hosts", matches[1].text);
}

test "a rule claims text a built-in scanner would have taken" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 4);
    defer s.deinit();
    feedStr(s, "see /etc/hosts now");

    const rules = [_]Rule{.{ .pattern = "/etc/[a-z]+", .action = .paste }};
    const matches = try collectRules(s, &rules);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    // One match, not two: the path scanner sees the columns taken.
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(Kind.custom, matches[0].kind);
    try std.testing.expectEqual(Action.paste, matches[0].action);
}

test "a rule matches repeatedly on one row without looping forever" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 4);
    defer s.deinit();
    feedStr(s, "10.0.0.1 10.0.0.2 10.0.0.3");

    // A pattern that can also match empty would spin on a naive
    // advance; the scanner steps past a zero-length match.
    const rules = [_]Rule{.{ .pattern = "[0-9.]*", .action = .copy }};
    const matches = try collectRules(s, &rules);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("10.0.0.1", matches[0].text);
    try std.testing.expectEqualStrings("10.0.0.3", matches[2].text);
}

test "an uncompilable pattern disables only its own rule" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 4);
    defer s.deinit();
    feedStr(s, "abc 42");

    const rules = [_]Rule{
        .{ .pattern = "[unterminated", .action = .copy },
        .{ .pattern = "[0-9]+", .action = .select },
    };
    const matches = try collectRules(s, &rules);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("42", matches[0].text);
    try std.testing.expectEqual(Action.select, matches[0].action);
}

test "custom label alphabet is used, and a broken one falls back" {
    var ms: [3]Match = undefined;
    for (&ms) |*m| m.* = .{ .row = 0, .col_start = 0, .col_end = 1, .kind = .hash, .text = &.{} };

    assignLabels2(&ms, "xyz");
    try std.testing.expectEqual(@as(u8, 'x'), ms[0].label[0]);
    try std.testing.expectEqual(@as(u8, 'z'), ms[2].label[0]);

    // A repeated character would give two matches the same label.
    assignLabels2(&ms, "xxz");
    try std.testing.expectEqual(@as(u8, 'a'), ms[0].label[0]);
    // As would one character, or whitespace in the set.
    try std.testing.expectEqual(@as(?[]const u8, null), validAlphabet("a"));
    try std.testing.expectEqual(@as(?[]const u8, null), validAlphabet("a b"));
    try std.testing.expect(validAlphabet("asdf") != null);
}

test "two-char labels are uniform when >26 matches" {
    var ms: [30]Match = undefined;
    for (&ms) |*m| m.* = .{ .row = 0, .col_start = 0, .col_end = 1, .kind = .hash, .text = &.{} };
    assignLabels(&ms);
    for (ms) |m| try std.testing.expectEqual(@as(u8, 2), m.label_len);
    try std.testing.expectEqual(@as(u8, 'a'), ms[0].label[0]);
    try std.testing.expectEqual(@as(u8, 'a'), ms[0].label[1]);
    try std.testing.expectEqual(@as(u8, 's'), ms[27].label[1]);
}
