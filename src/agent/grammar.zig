//! The screen-source line grammar: what one adapter's rules make of a list
//! of screen lines. Pure functions over `Line`s (no Screen, no clock), so
//! every rule is testable with hand-written lines; `screen_source.zig`
//! turns a Screen into lines and decides WHEN to call these.

const std = @import("std");
const vocab = @import("vocab.zig");
const adapter = @import("adapter.zig");

pub const Line = struct {
    text: []const u8,
    /// Screen line id of the row (monotonic in birth order; a reprint
    /// mints new ids).
    id: u64,
    /// The row ran to the last column or soft-wraps: the next line
    /// continues it with no separator.
    joins_next: bool = false,
    /// Part of the app's live region (input box, status block): chrome
    /// whatever its text.
    live: bool = false,
};

pub const Class = union(enum) {
    /// Starts a record by `sc.records[rule]`.
    record: usize,
    chrome,
    text,
};

/// Record rules win over chrome; footer, subagent, choice-prompt and
/// permission lines are chrome without being listed as such.
pub fn classify(sc: *const adapter.Screen, line: Line) Class {
    if (line.live) return .chrome;
    for (sc.records, 0..) |r, i| {
        if (r.matcher.matches(line.text)) return .{ .record = i };
    }
    if (isChrome(sc, line.text)) return .chrome;
    return .text;
}

pub fn isChrome(sc: *const adapter.Screen, text: []const u8) bool {
    for (sc.chrome) |m| {
        if (m.matches(text)) return true;
    }
    inline for (.{ "footer", "subagent", "permission" }) |f| {
        if (@field(sc, f)) |m| {
            if (m.matches(text)) return true;
        }
    }
    return sc.choice_prompt.matches(text);
}

pub const Rec = struct {
    kind: vocab.RecordKind,
    /// Index of the record's first line in the parsed slice.
    first: usize,
    /// Screen line id of the first line.
    line_id: u64,
    /// Allocated from the parse allocator.
    text: []u8,
};

/// Split lines into records. Chrome ends the open record and the text
/// after it is dropped until the next record starts.
pub fn parseRecords(alloc: std.mem.Allocator, sc: *const adapter.Screen, lines: []const Line) ![]Rec {
    var out: std.ArrayList(Rec) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var open: ?struct { kind: vocab.RecordKind, first: usize, line_id: u64, then: ?vocab.RecordKind } = null;
    var prev_joins = false;

    for (lines, 0..) |line, i| {
        switch (classify(sc, line)) {
            .record => |ri| {
                if (open) |o| try out.append(alloc, try finish(alloc, o.kind, o.first, o.line_id, &buf));
                const r = sc.records[ri];
                const body = line.text[@min(r.strip, line.text.len)..];
                try buf.appendSlice(alloc, body);
                const then_applies = r.then != null and (r.then_when == null or std.mem.startsWith(u8, body, r.then_when.?));
                open = .{ .kind = r.kind, .first = i, .line_id = line.id, .then = if (then_applies) r.then else null };
            },
            .chrome => {
                if (open) |o| try out.append(alloc, try finish(alloc, o.kind, o.first, o.line_id, &buf));
                open = null;
            },
            .text => if (open) |*o| {
                if (o.then) |next_kind| {
                    // A one-line record: what follows is a record of its own.
                    try out.append(alloc, try finish(alloc, o.kind, o.first, o.line_id, &buf));
                    open = .{ .kind = next_kind, .first = i, .line_id = line.id, .then = null };
                    try buf.appendSlice(alloc, line.text);
                } else {
                    if (!prev_joins) try buf.append(alloc, '\n');
                    try buf.appendSlice(alloc, line.text);
                }
            },
        }
        prev_joins = line.joins_next;
    }
    if (open) |o| try out.append(alloc, try finish(alloc, o.kind, o.first, o.line_id, &buf));
    return out.toOwnedSlice(alloc);
}

fn finish(alloc: std.mem.Allocator, kind: vocab.RecordKind, first: usize, line_id: u64, buf: *std.ArrayList(u8)) !Rec {
    const trimmed = std.mem.trimEnd(u8, buf.items, " \n");
    const text = try alloc.dupe(u8, trimmed);
    buf.clearRetainingCapacity();
    return .{ .kind = kind, .first = first, .line_id = line_id, .text = text };
}

/// Wrap- and truncation-insensitive identity of a prompt: lowercase
/// alphanumerics up to the first ellipsis.
pub fn promptKey(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const cut = if (std.mem.indexOf(u8, text, "…")) |i| text[0..i] else text;
    var out: std.ArrayList(u8) = .empty;
    for (cut) |ch| {
        if (std.ascii.isAlphanumeric(ch)) try out.append(alloc, std.ascii.toLower(ch));
    }
    return out.toOwnedSlice(alloc);
}

/// Two prompt keys name the same prompt when one is a prefix of the other
/// (a reprint can cut a prompt short).
pub fn samePrompt(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return std.mem.startsWith(u8, a, b) or std.mem.startsWith(u8, b, a);
}

pub fn alnumLen(text: []const u8) usize {
    var n: usize = 0;
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch)) n += 1;
    }
    return n;
}

// ── live region ──────────────────────────────────────────────────

/// Index of the input box's first row: the last line starting with the
/// input prefix among the bottom `max_rows` non-blank lines.
pub fn findInput(sc: *const adapter.Screen, lines: []const Line, max_rows: usize) ?usize {
    var seen: usize = 0;
    var i = lines.len;
    while (i > 0 and seen < max_rows) {
        i -= 1;
        if (lines[i].text.len == 0) continue;
        seen += 1;
        if (std.mem.startsWith(u8, lines[i].text, sc.spec.input_prefix)) return i;
    }
    return null;
}

/// The input box's text (prefix, NBSPs and spaces trimmed).
pub fn inputText(alloc: std.mem.Allocator, sc: *const adapter.Screen, lines: []const Line, input: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines[input..], input..) |l, i| {
        const body = if (i == input) l.text[sc.spec.input_prefix.len..] else l.text;
        if (i > input and body.len > 0 and !lines[i - 1].joins_next) try out.append(alloc, '\n');
        try out.appendSlice(alloc, body);
    }
    const owned = try out.toOwnedSlice(alloc);
    defer alloc.free(owned);
    return alloc.dupe(u8, trimSpace(owned));
}

fn trimSpace(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (true) {
        if (a < b and (s[a] == ' ' or s[a] == '\n')) {
            a += 1;
        } else if (a + 1 < b and s[a] == 0xC2 and s[a + 1] == 0xA0) {
            a += 2;
        } else break;
    }
    while (true) {
        if (b > a and (s[b - 1] == ' ' or s[b - 1] == '\n')) {
            b -= 1;
        } else if (b >= a + 2 and s[b - 2] == 0xC2 and s[b - 1] == 0xA0) {
            b -= 2;
        } else break;
    }
    return s[a..b];
}

/// Rows of the app's own status block above the input box: the unlisted
/// rows between the chrome directly above the input and the next chrome
/// line up. Null when a record start (or the top) comes first, i.e. when
/// answer text could be among them, and when no record starts above that
/// chrome line (a startup banner is chrome too, but far from the block).
pub fn measureStatusRows(sc: *const adapter.Screen, lines: []const Line, input: usize, max: usize) ?usize {
    var i = input;
    // The chrome glued to the input box (mode line, subagent rows).
    while (i > 0 and classify(sc, lines[i - 1]) == .chrome) i -= 1;
    var n: usize = 0;
    while (i > 0) {
        i -= 1;
        switch (classify(sc, lines[i])) {
            .chrome => {
                for (lines[0..i]) |l| {
                    if (classify(sc, l) == .record) return n;
                }
                return null;
            },
            .record => return null,
            .text => {
                n += 1;
                if (n > max) return null;
            },
        }
    }
    return null;
}

/// Mark the input box, the chrome glued to it and `status_rows` rows above
/// that as live.
pub fn markLive(sc: *const adapter.Screen, lines: []Line, input: usize, status_rows: usize) void {
    var i = input;
    while (i > 0 and classify(sc, lines[i - 1]) == .chrome) i -= 1;
    var n: usize = 0;
    while (n < status_rows and i > 0) : (n += 1) {
        if (classify(sc, lines[i - 1]) != .text) break;
        i -= 1;
    }
    for (lines[i..]) |*l| l.live = true;
}

// ── interactions ─────────────────────────────────────────────────

pub const Option = struct {
    label: []const u8,
    selected: bool,
};

pub const Interaction = struct {
    kind: vocab.InteractionKind,
    title: []const u8,
    detail: []const u8,
    /// The prompt line and what follows it ("Enter to set as default · s
    /// to use this session only").
    hint: []const u8,
    options: []const Option,
    /// The lines it occupies, header to hint: [rows_start, rows_end).
    rows_start: usize,
    rows_end: usize,

    /// Identity for "is this the prompt already announced": kind, title,
    /// detail and options (the hint, which echoes typed digits, is not part).
    pub fn hash(self: Interaction) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(self.kind));
        h.update(self.title);
        h.update("\x00");
        h.update(self.detail);
        for (self.options) |o| {
            h.update("\x00");
            h.update(o.label);
            h.update(if (o.selected) "+" else "-");
        }
        return h.final();
    }
};

/// `N. label` (leading spaces allowed): the number and the label.
pub fn numbered(text: []const u8) ?struct { n: u32, label: []const u8 } {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') i += 1;
    const start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    if (i == start or i - start > 3) return null;
    if (i + 1 >= text.len or text[i] != '.' or text[i + 1] != ' ') return null;
    const n = std.fmt.parseInt(u32, text[start..i], 10) catch return null;
    return .{ .n = n, .label = text[i + 2 ..] };
}

/// The numbered option list above the last choice-prompt line, or null
/// when none is showing (or an input box below it says it is stale).
/// Everything returned is allocated from `alloc` (an arena).
pub fn parseInteraction(alloc: std.mem.Allocator, sc: *const adapter.Screen, lines: []const Line) !?Interaction {
    var prompt: ?usize = null;
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        if (sc.choice_prompt.matches(lines[i].text)) {
            prompt = i;
            break;
        }
    }
    const p = prompt orelse return null;
    if (findInput(sc, lines[p..], 8)) |_| return null;

    // Option 1 is the nearest "1. " above the prompt.
    var first: ?usize = null;
    var k = p;
    while (k > 0 and p - k < 80) {
        k -= 1;
        if (numbered(lines[k].text)) |nb| {
            if (nb.n == 1) {
                first = k;
                break;
            }
        }
    }
    const f = first orelse return null;

    var options: std.ArrayList(Option) = .empty;
    var label: std.ArrayList(u8) = .empty;
    var expected: u32 = 1;
    for (lines[f..p], f..) |l, row| {
        if (numbered(l.text)) |nb| {
            if (nb.n == expected) {
                if (expected > 1) try options.append(alloc, try makeOption(alloc, sc, label.items));
                label.clearRetainingCapacity();
                try label.appendSlice(alloc, nb.label);
                expected += 1;
                continue;
            }
        }
        if (l.text.len == 0) continue;
        if (!lines[row - 1].joins_next) try label.append(alloc, ' ');
        try label.appendSlice(alloc, l.text);
    }
    try options.append(alloc, try makeOption(alloc, sc, label.items));

    // Header: up from option 1 to a record start or chrome line.
    var h = f;
    var permission_row: ?usize = null;
    while (h > 0 and f - h < 40) {
        const prev = lines[h - 1];
        if (sc.permission) |m| {
            if (m.matches(prev.text)) {
                permission_row = h - 1;
                h -= 1;
                break;
            }
        }
        if (classify(sc, prev) != .text) break;
        h -= 1;
    }
    var header: std.ArrayList([]const u8) = .empty;
    for (lines[h..f]) |l| {
        if (l.text.len > 0) try header.append(alloc, l.text);
    }
    var title: []const u8 = "";
    var detail: []const u8 = "";
    const kind: vocab.InteractionKind = if (permission_row != null) .permission else .choice;
    if (header.items.len > 0) {
        if (kind == .permission) {
            title = header.items[header.items.len - 1];
            detail = try std.mem.join(alloc, "\n", header.items[0 .. header.items.len - 1]);
        } else {
            title = header.items[0];
            detail = try std.mem.join(alloc, "\n", header.items[1..]);
        }
    }

    var hint: std.ArrayList([]const u8) = .empty;
    var end = p;
    for (lines[p..], p..) |l, row| {
        if (l.text.len == 0) break;
        if (row > p and classify(sc, l) != .text) break;
        try hint.append(alloc, l.text);
        end = row + 1;
    }
    return .{
        .kind = kind,
        .title = title,
        .detail = detail,
        .hint = try std.mem.join(alloc, "\n", hint.items),
        .options = try options.toOwnedSlice(alloc),
        .rows_start = h,
        .rows_end = end,
    };
}

fn makeOption(alloc: std.mem.Allocator, sc: *const adapter.Screen, raw: []const u8) !Option {
    const marker = sc.spec.selected_marker;
    if (marker.len > 0) {
        if (std.mem.indexOf(u8, raw, marker)) |at| {
            const joined = try std.mem.concat(alloc, u8, &.{ raw[0..at], raw[at + marker.len ..] });
            return .{ .label = try collapse(alloc, joined), .selected = true };
        }
    }
    return .{ .label = try collapse(alloc, raw), .selected = false };
}

/// Trim and collapse runs of spaces (a removed marker leaves two).
fn collapse(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (std.mem.trim(u8, s, " ")) |ch| {
        if (ch == ' ') {
            if (space) continue;
            space = true;
        } else space = false;
        try out.append(alloc, ch);
    }
    return out.toOwnedSlice(alloc);
}

// ── errors ───────────────────────────────────────────────────────

pub const ErrorHit = struct {
    class: vocab.ErrorClass,
    /// The matching line.
    text: []const u8,
    /// Text after the rule's reset marker, "" without one.
    detail: []const u8,
};

/// The first error rule matching `text`, or null.
pub fn matchError(rules: []const adapter.ErrorMatcher, text: []const u8) ?ErrorHit {
    for (rules) |r| {
        if (!r.matcher.matches(text)) continue;
        var detail: []const u8 = "";
        if (r.reset_marker) |m| {
            if (std.mem.indexOf(u8, text, m)) |at| detail = std.mem.trim(u8, text[at..], " ");
        }
        return .{ .class = r.class, .text = std.mem.trim(u8, text, " "), .detail = detail };
    }
    return null;
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

pub const test_adapter_json =
    \\{
    \\  "id": "fake", "name": "Fake", "source": "screen",
    \\  "launch": { "binary": "fake", "candidates": ["$PATH"] },
    \\  "screen": {
    \\    "input_prefix": "$",
    \\    "busy_title": ["◐", "◑"],
    \\    "footer": { "pattern": "^\\S+ for [0-9][0-9hms ]* · done" },
    \\    "settle_ms": 1500,
    \\    "records": [
    \\      { "kind": "user", "prefix": "you: ", "then": "notice", "then_when": "/" },
    \\      { "kind": "assistant", "prefix": "claude: " },
    \\      { "kind": "tool", "prefix": "tool: " },
    \\      { "kind": "notice", "pattern": "^Interrupted .*What should" },
    \\      { "kind": "notice", "pattern": "^ *Agent \".*\" finished" }
    \\    ],
    \\    "chrome": [ { "pattern": "^[A-Z]\\S*…$" }, { "prefix": "manual mode on" }, { "pattern": "^\\$$" }, { "prefix": "$ " }, { "prefix": "✔ " } ],
    \\    "subagent": { "pattern": "^Waiting for [0-9]+ background agents? to finish" },
    \\    "choice_prompt": { "prefix": "Select with numbers [" },
    \\    "permission": { "prefix": "Permission Required:" },
    \\    "bell_needs_input": true
    \\  },
    \\  "errors": [ { "class": "limit", "pattern": "Usage limit reached", "reset_marker": "resets " } ]
    \\}
;

pub fn testAdapter() !*adapter.Loaded {
    var problem: ?[]u8 = null;
    return adapter.load(t.allocator, "fake.json", test_adapter_json, .user, &problem) catch |err| {
        if (problem) |p| {
            std.debug.print("{s}\n", .{p});
            t.allocator.free(p);
        }
        return err;
    };
}

fn mk(texts: []const []const u8) ![]Line {
    const out = try t.allocator.alloc(Line, texts.len);
    for (texts, out, 0..) |s, *l, i| l.* = .{ .text = s, .id = i + 1 };
    return out;
}

test "records: prefixes start records, chrome ends them, text continues" {
    const l = try testAdapter();
    defer l.destroy(t.allocator);
    const sc = &l.screen.?;
    const lines = try mk(&.{
        "banner text",
        "you: Reply with a Zig",
        "code block please",
        "Puttering…",
        "claude: fn add() i32 {",
        "    return a + b;",
        "}",
        "",
        "Cogitated for 1s · done 9:23 PM",
        "status line that is not chrome",
        "manual mode on",
        "$",
    });
    defer t.allocator.free(lines);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const recs = try parseRecords(arena.allocator(), sc, lines);
    try t.expectEqual(@as(usize, 2), recs.len);
    try t.expectEqual(vocab.RecordKind.user, recs[0].kind);
    try t.expectEqualStrings("Reply with a Zig\ncode block please", recs[0].text);
    try t.expectEqual(@as(u64, 2), recs[0].line_id);
    try t.expectEqualStrings("fn add() i32 {\n    return a + b;\n}", recs[1].text);
}

test "records: a full row joins the next without a separator; slash commands split" {
    const l = try testAdapter();
    defer l.destroy(t.allocator);
    const sc = &l.screen.?;
    const lines = try mk(&.{ "you: In /tmp/scratchp", "ad/notes.md, change it", "you: /model", "Kept model as Haiku 4.5" });
    defer t.allocator.free(lines);
    lines[0].joins_next = true;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const recs = try parseRecords(arena.allocator(), sc, lines);
    try t.expectEqual(@as(usize, 3), recs.len);
    try t.expectEqualStrings("In /tmp/scratchpad/notes.md, change it", recs[0].text);
    try t.expectEqualStrings("/model", recs[1].text);
    try t.expectEqual(vocab.RecordKind.notice, recs[2].kind);
    try t.expectEqualStrings("Kept model as Haiku 4.5", recs[2].text);
}

test "live region: status rows are learned from a chrome anchor and cut" {
    const l = try testAdapter();
    defer l.destroy(t.allocator);
    const sc = &l.screen.?;
    const banner = try mk(&.{ "Starting…", "[Haiku] repo:master", "manual mode on", "$" });
    defer t.allocator.free(banner);
    try t.expect(measureStatusRows(sc, banner, 3, 10) == null);
    const lines = try mk(&.{
        "claude: answer",
        "Cogitated for 1s · done 9:23 PM",
        "[Haiku] repo:master",
        "[■■□□] 21%",
        "manual mode on",
        "$\u{a0} typed text",
    });
    defer t.allocator.free(lines);
    const input = findInput(sc, lines, 8).?;
    try t.expectEqual(@as(usize, 5), input);
    try t.expectEqual(@as(?usize, 2), measureStatusRows(sc, lines, input, 10));
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("typed text", try inputText(arena.allocator(), sc, lines, input));

    // Streaming: answer text sits right above the status block; not measurable.
    const streaming = try mk(&.{ "claude: partial", "more text", "[Haiku] repo:master", "[■■□□] 21%", "manual mode on", "$" });
    defer t.allocator.free(streaming);
    try t.expect(measureStatusRows(sc, streaming, 5, 10) == null);
    markLive(sc, streaming, 5, 2);
    const recs = try parseRecords(arena.allocator(), sc, streaming);
    try t.expectEqual(@as(usize, 1), recs.len);
    try t.expectEqualStrings("partial\nmore text", recs[0].text);
}

test "interactions: a permission prompt with wrapped options" {
    const l = try testAdapter();
    defer l.destroy(t.allocator);
    const sc = &l.screen.?;
    const lines = try mk(&.{
        "tool: Bash (rm notes.md)",
        "Permission Required: Bash command",
        "> rm notes.md",
        "Do you want to proceed?",
        "1. Yes",
        "2. Yes, and always allow access to",
        "/tmp/scratch from this project",
        "3. No",
        "Select with numbers [1-3]. Then Enter to submit or Escape to cancel:",
        "Esc to cancel · Tab to amend",
        "✔  Review view.zig",
    });
    defer t.allocator.free(lines);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const it = (try parseInteraction(arena.allocator(), sc, lines)).?;
    try t.expectEqual(vocab.InteractionKind.permission, it.kind);
    try t.expectEqualStrings("Do you want to proceed?", it.title);
    try t.expectEqualStrings("Permission Required: Bash command\n> rm notes.md", it.detail);
    try t.expectEqual(@as(usize, 3), it.options.len);
    try t.expectEqualStrings("Yes, and always allow access to /tmp/scratch from this project", it.options[1].label);
    try t.expect(!it.options[0].selected);
    try t.expectEqualStrings("Select with numbers [1-3]. Then Enter to submit or Escape to cancel:\nEsc to cancel · Tab to amend", it.hint);
}

test "interactions: a picker with the selected option, and a stale one" {
    const l = try testAdapter();
    defer l.destroy(t.allocator);
    const sc = &l.screen.?;
    const lines = try mk(&.{
        "you: /model",
        "Select model",
        "Switch between Claude models.",
        "1. Default (recommended)",
        "2. (selected) Haiku 4.5 — Fastest",
        "Select with numbers [1-2]. Then Enter to submit or Escape to cancel:",
        "Enter to set as default · s to use this session only · Esc to cancel",
    });
    defer t.allocator.free(lines);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const it = (try parseInteraction(arena.allocator(), sc, lines)).?;
    try t.expectEqual(vocab.InteractionKind.choice, it.kind);
    try t.expectEqualStrings("Select model", it.title);
    try t.expectEqualStrings("Switch between Claude models.", it.detail);
    try t.expectEqualStrings("Haiku 4.5 — Fastest", it.options[1].label);
    try t.expect(it.options[1].selected);
    try t.expectEqual(@as(usize, 1), it.rows_start);
    try t.expectEqual(@as(usize, 7), it.rows_end);

    const stale = try mk(&.{ "1. a", "2. b", "Select with numbers [1-2].", "manual mode on", "$" });
    defer t.allocator.free(stale);
    try t.expect((try parseInteraction(arena.allocator(), sc, stale)) == null);
}

test "errors carry the reset text" {
    const l = try testAdapter();
    defer l.destroy(t.allocator);
    const hit = matchError(l.errors, "Usage limit reached · resets 5pm (Europe/Brussels)").?;
    try t.expectEqual(vocab.ErrorClass.limit, hit.class);
    try t.expectEqualStrings("resets 5pm (Europe/Brussels)", hit.detail);
    try t.expect(matchError(l.errors, "all good") == null);
}

test "prompt keys ignore wrapping and truncation" {
    const a = try promptKey(t.allocator, "In /tmp/scratchp ad/notes.md, change");
    defer t.allocator.free(a);
    const b = try promptKey(t.allocator, "In /tmp/scratchpad/no…");
    defer t.allocator.free(b);
    try t.expect(samePrompt(a, b));
    try t.expect(!samePrompt(a, ""));
}
