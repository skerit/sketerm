//! What a line of query text means, and the panelize presets.
//!
//! Pure and allocation-free: the search bar, the saved-query list and
//! the Places sidebar all read a query through this one parser, so a
//! saved query can never be re-run as something other than what its
//! label says it is.
//!
//! A query is one of three things, decided by the text itself rather
//! than by any stored mode flag:
//!   `!cmd`     a host-side command whose output IS the listing
//!   `pattern`  a recursive filename query, which runs LIVE
//!   ...with the content toggle on, a one-shot recursive grep.
//! A leading `@7d` / `@12h` / `@30m` adds a relative-time predicate.
//! In a live query that predicate keeps being re-evaluated host-side,
//! so a row leaves the view as it ages out.

const std = @import("std");

pub const Kind = enum {
    /// Recursive filename query, served by the daemon's live_find:
    /// rows appear and disappear as files start and stop matching.
    live_name,
    /// Recursive content grep. One-shot by nature: there is no cheap
    /// way to know a write changed whether a file contains a string
    /// without reading it again.
    content,
    /// Panelize: an arbitrary command run on the session's host.
    command,

    /// One word for what this kind of query is, for labels and status
    /// lines.
    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .live_name => "live",
            .content => "content",
            .command => "command",
        };
    }
};

pub const Query = struct {
    kind: Kind,
    /// The name/content pattern, or the command with its `!` stripped.
    pattern: []const u8,
    /// Relative-time predicate in milliseconds (0 = none).
    within_ms: u64 = 0,

    /// Whether opening this query subscribes rather than scans.
    pub fn live(self: Query) bool {
        return self.kind == .live_name;
    }

    /// The daemon job verb that serves it.
    pub fn op(self: Query) []const u8 {
        return switch (self.kind) {
            .live_name => "live_find",
            .content => "grep",
            .command => "panelize",
        };
    }

    /// One word for what this query is, for labels and status lines.
    pub fn kindLabel(self: Query) []const u8 {
        return self.kind.label();
    }
};

/// Parse one relative-time token ("7d", "12h", "30m").
/// @return 0 when it is not a duration.
pub fn durationMs(token: []const u8) u64 {
    if (token.len < 2) return 0;
    const unit: u64 = switch (token[token.len - 1]) {
        'd' => 24 * 3600 * 1000,
        'h' => 3600 * 1000,
        'm' => 60 * 1000,
        's' => 1000,
        else => return 0,
    };
    const num = std.fmt.parseInt(u64, token[0 .. token.len - 1], 10) catch return 0;
    if (num == 0) return 0;
    // A window longer than a century is a typo, not a predicate, and
    // the daemon clamps anyway.
    return std.math.mul(u64, num, unit) catch 0;
}

/// Read `text` (as typed in the search bar) as a query.
/// @return null when there is nothing to run.
pub fn parse(text_in: []const u8, content: bool) ?Query {
    const text = std.mem.trim(u8, text_in, " \t");
    if (text.len == 0) return null;
    // A command is a command whatever the content toggle says: the
    // toggle applies to a pattern, and `!` means there is none.
    if (text[0] == '!') {
        const cmd = std.mem.trimStart(u8, text[1..], " ");
        if (cmd.len == 0) return null;
        return .{ .kind = .command, .pattern = cmd };
    }
    var rest = text;
    var within: u64 = 0;
    if (rest[0] == '@') {
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
            const ms = durationMs(rest[1..sp]);
            if (ms != 0) {
                within = ms;
                rest = std.mem.trimStart(u8, rest[sp + 1 ..], " ");
            }
        }
    }
    if (rest.len == 0) return null;
    return .{
        .kind = if (content) .content else .live_name,
        .pattern = rest,
        .within_ms = within,
    };
}

/// A ready-made panelize command. The text is what lands in the search
/// bar, so a preset is editable before it runs. Both strings are
/// NUL-terminated: they go straight into GTK labels and entries.
pub const Preset = struct {
    label: [:0]const u8,
    text: [:0]const u8,
};

/// NUL-delimited output wherever the tool offers it: a path containing
/// a newline is indistinguishable from two paths under LF framing, and
/// the daemon splits on NUL as readily as on LF.
pub const presets = [_]Preset{
    .{ .label = "Tracked files (git ls-files)", .text = "!git ls-files -z" },
    .{ .label = "Modified vs HEAD (git diff)", .text = "!git diff --name-only -z HEAD" },
    .{ .label = "Files containing text (rg -l)", .text = "!rg -l --null TEXT" },
    .{ .label = "All files (fd)", .text = "!fd --print0 --type f" },
};

test "a bare pattern is a live name query" {
    const t = std.testing;
    const q = parse("report", false).?;
    try t.expectEqual(Kind.live_name, q.kind);
    try t.expect(q.live());
    try t.expectEqualStrings("report", q.pattern);
    try t.expectEqual(@as(u64, 0), q.within_ms);
    try t.expectEqualStrings("live_find", q.op());
}

test "the content toggle makes the same text a one-shot grep" {
    const t = std.testing;
    const q = parse("report", true).?;
    try t.expectEqual(Kind.content, q.kind);
    try t.expect(!q.live());
    try t.expectEqualStrings("grep", q.op());
}

test "a relative-time prefix is stripped into within_ms" {
    const t = std.testing;
    const d = parse("@7d *.zig", false).?;
    try t.expectEqual(@as(u64, 7 * 24 * 3600 * 1000), d.within_ms);
    try t.expectEqualStrings("*.zig", d.pattern);
    try t.expectEqual(@as(u64, 12 * 3600 * 1000), parse("@12h a", false).?.within_ms);
    try t.expectEqual(@as(u64, 30 * 60 * 1000), parse("@30m a", false).?.within_ms);
    try t.expectEqual(@as(u64, 5000), parse("@5s a", false).?.within_ms);
    // A time predicate rides a content query too; only its LIVENESS
    // differs, and the daemon applies the same mtime filter.
    try t.expectEqual(@as(u64, 24 * 3600 * 1000), parse("@1d needle", true).?.within_ms);
}

test "an unparsable @token stays part of the pattern" {
    const t = std.testing;
    // No unit, no number, no space: each of these is a filename that
    // happens to start with @, not a broken predicate.
    for ([_][]const u8{ "@zz pat", "@0d pat", "@d pat", "@7d" }) |text| {
        const q = parse(text, false).?;
        try t.expectEqual(@as(u64, 0), q.within_ms);
        try t.expectEqualStrings(text, q.pattern);
    }
}

test "a bang makes it a command, whatever the content toggle says" {
    const t = std.testing;
    const q = parse("!git ls-files -z", true).?;
    try t.expectEqual(Kind.command, q.kind);
    try t.expectEqualStrings("git ls-files -z", q.pattern);
    try t.expectEqualStrings("panelize", q.op());
    // A time prefix inside a command is the command's own text.
    try t.expectEqualStrings("@7d foo", parse("!@7d foo", false).?.pattern);
}

test "nothing to run parses as nothing" {
    const t = std.testing;
    try t.expect(parse("", false) == null);
    try t.expect(parse("   ", false) == null);
    try t.expect(parse("!", false) == null);
    try t.expect(parse("!   ", false) == null);
    // A predicate with nothing after it is not a predicate: the text
    // is trimmed first, so "@7d " is the pattern "@7d" -- a filename
    // query, not a window over everything.
    const bare = parse("@7d  ", false).?;
    try t.expectEqual(@as(u64, 0), bare.within_ms);
    try t.expectEqualStrings("@7d", bare.pattern);
}

test "every preset is a command query" {
    const t = std.testing;
    for (presets) |p| {
        const q = parse(p.text, false) orelse return error.TestUnexpectedResult;
        try t.expectEqual(Kind.command, q.kind);
        try t.expect(p.label.len > 0);
    }
}
