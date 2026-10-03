//! The screen-source line grammar: what one adapter's rules make of a list
//! of screen lines. Pure functions over `Line`s (no Screen, no clock), so
//! every rule is testable with hand-written lines; `screen_source.zig`
//! turns a Screen into lines and decides WHEN to call these.

const std = @import("std");
const vocab = @import("vocab.zig");
const adapter = @import("adapter.zig");
const output = @import("output.zig");

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

/// Record rules win over chrome; footer, subagent, background,
/// choice-prompt and permission lines are chrome without being listed as
/// such. A side question's echo wins over the records: it looks exactly
/// like a prompt and never is one.
pub fn classify(sc: *const adapter.Screen, line: Line) Class {
    if (line.live) return .chrome;
    if (sc.side) |s| if (s.echo) |m| if (m.matches(line.text)) return .chrome;
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
    inline for (.{ "footer", "subagent", "background", "background_agent", "permission", "queued" }) |f| {
        if (@field(sc, f)) |m| {
            if (m.matches(text)) return true;
        }
    }
    // The side panel's footer, so the panel is never counted as status rows.
    if (sc.side) |s| if (s.footer.matches(text)) return true;
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

/// A record's alphanumerics that make it worth comparing by content (a few
/// words two different records may well share are compared exactly).
pub const CONTENT_ALNUM = 20;

/// What `alnumRelated` texts of one kind share when both are long enough to
/// compare by content: a hash of the kind and the first `CONTENT_ALNUM`
/// lowercase alphanumerics. Null for a user prompt or a shorter text.
pub fn contentKey(kind: vocab.RecordKind, text: []const u8) ?u64 {
    if (kind == .user) return null;
    var h = std.hash.Wyhash.init(@intFromEnum(kind));
    var n: usize = 0;
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) continue;
        h.update(&.{std.ascii.toLower(ch)});
        n += 1;
        if (n == CONTENT_ALNUM) return h.final();
    }
    return null;
}

/// The same record drawn twice: one copy cut short or extended, or, when
/// short, the very same text.
pub fn sameRecord(a: Rec, b: Rec) bool {
    if (a.kind != b.kind) return false;
    if (alnumLen(a.text) < CONTENT_ALNUM and alnumLen(b.text) < CONTENT_ALNUM) return std.mem.eql(u8, a.text, b.text);
    return alnumRelated(a.text, b.text);
}

/// One turn's records without the stale copies a redraw leaves behind: an
/// app that redraws a live region taller than the screen erases only the
/// rows still on screen, so the part that scrolled into history stays and
/// the redraw prints it again below (its last line cut where the screen
/// began). A run whose next two records repeat an earlier run's is that
/// redraw; the earlier copy goes, the later one stays.
/// @param recs one turn's records, its user record first.
pub fn dropStaleCopies(alloc: std.mem.Allocator, recs: []const Rec) ![]const Rec {
    var out: std.ArrayList(Rec) = .empty;
    try out.appendSlice(alloc, recs);
    var j: usize = 2;
    while (j + 1 < out.items.len) : (j += 1) {
        const items = out.items;
        var i = j - 1;
        while (i > 0) : (i -= 1) {
            if (i + 1 >= j or items[i].kind == .user) continue;
            if (!sameRecord(items[i], items[j]) or !sameRecord(items[i + 1], items[j + 1])) continue;
            if (alnumLen(items[j].text) < CONTENT_ALNUM and alnumLen(items[j + 1].text) < CONTENT_ALNUM) continue;
            out.replaceRangeAssumeCapacity(i, j - i, &.{});
            j = i;
            break;
        }
    }
    return out.toOwnedSlice(alloc);
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

/// Whether one text's lowercase alphanumerics are a prefix of the other's
/// (the same record drawn twice, one copy cut short or extended).
pub fn alnumRelated(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and !std.ascii.isAlphanumeric(a[i])) i += 1;
        while (j < b.len and !std.ascii.isAlphanumeric(b[j])) j += 1;
        if (i == a.len or j == b.len) return true;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
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

/// Mark the app's queued-prompt previews live: the `queued` line right
/// above the live region and the user records directly above it.
/// @return the previews showing (0 when none).
pub fn markQueued(sc: *const adapter.Screen, lines: []Line, input: usize) u32 {
    const m = sc.queued orelse return 0;
    var i = input;
    while (i > 0 and lines[i - 1].live) i -= 1;
    if (i == 0 or !m.matches(lines[i - 1].text)) return 0;
    var top = i - 1;
    var n: u32 = 0;
    var k = top;
    // A preview is a user record and its continuation lines; whatever is
    // above the topmost one (an answer still streaming) is transcript.
    while (k > 0) {
        k -= 1;
        switch (classify(sc, lines[k])) {
            .record => |ri| {
                if (sc.records[ri].kind != .user) break;
                n += 1;
                top = k;
            },
            .text => {},
            .chrome => break,
        }
    }
    for (lines[top..i]) |*l| l.live = true;
    return n;
}

// ── side questions ───────────────────────────────────────────────

/// The side panel's rows: its topmost question line to its footer.
pub const SidePanel = struct {
    top: usize,
    footer: usize,

    pub fn contains(self: SidePanel, row: usize) bool {
        return row >= self.top and row <= self.footer;
    }
};

/// The side panel showing, or null: its footer is the last non-blank line
/// that is not live (a busy app keeps its status block and input below
/// it), with a question line above it. Earlier questions and their wrapped
/// lines are part of it; text above the topmost question is not.
pub fn findSidePanel(sc: *const adapter.Screen, lines: []const Line) ?SidePanel {
    const s = sc.side orelse return null;
    var f = lines.len;
    while (f > 0) {
        f -= 1;
        if (lines[f].live or lines[f].text.len == 0) continue;
        break;
    } else return null;
    if (!s.footer.matches(lines[f].text)) return null;
    // The nearest question above the footer; the answer between them may
    // look like anything (a blank line, a spinner-shaped word).
    var q = f;
    while (q > 0) {
        q -= 1;
        if (s.question.matches(lines[q].text)) break;
    } else return null;
    var top = q;
    var k = q;
    while (k > 0) {
        k -= 1;
        if (s.question.matches(lines[k].text)) {
            top = k;
            continue;
        }
        if (lines[k].text.len == 0 or classify(sc, lines[k]) != .text) break;
    }
    return .{ .top = top, .footer = f };
}

pub const SideAnswer = struct {
    /// Allocated from the caller's allocator; "" while nothing is drawn.
    text: []u8,
    /// The panel still says the answer is coming.
    pending: bool,
};

/// The answer to `asked` (the typed line, `/btw ...`) in `panel`: the rows
/// after the LAST question line(s) spelling it (compared by alphanumerics,
/// so a wrapped question matches) up to the footer. Null when the panel
/// names no such question.
pub fn sideAnswer(alloc: std.mem.Allocator, sc: *const adapter.Screen, lines: []const Line, panel: SidePanel, asked: []const u8) !?SideAnswer {
    const s = sc.side orelse return null;
    var after: ?usize = null;
    var i = panel.top;
    while (i < panel.footer) : (i += 1) {
        if (!s.question.matches(lines[i].text)) continue;
        if (spells(lines[i..panel.footer], asked)) |n| after = i + n;
    }
    const first = after orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var pending = false;
    for (lines[first..panel.footer], first..) |l, row| {
        if (s.pending.matches(l.text)) {
            pending = true;
            continue;
        }
        if (row > first and !lines[row - 1].joins_next) try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, l.text);
    }
    return .{ .text = try alloc.dupe(u8, std.mem.trim(u8, buf.items, " \n")), .pending = pending };
}

/// How many of `rows` (from the first) spell exactly `text`'s lowercase
/// alphanumerics, the last of them ending with it; null when they do not.
fn spells(rows: []const Line, text: []const u8) ?usize {
    var at: usize = 0;
    for (rows, 1..) |r, n| {
        for (r.text) |ch| {
            if (!std.ascii.isAlphanumeric(ch)) continue;
            while (at < text.len and !std.ascii.isAlphanumeric(text[at])) at += 1;
            if (at == text.len or std.ascii.toLower(ch) != std.ascii.toLower(text[at])) return null;
            at += 1;
        }
        while (at < text.len and !std.ascii.isAlphanumeric(text[at])) at += 1;
        if (at == text.len) return n;
    }
    return null;
}

// ── interactions ─────────────────────────────────────────────────

pub const Option = output.Option;
/// A parsed interaction's `hint` is the prompt line and what follows it;
/// `rows_start`/`rows_end` are always set.
pub const Interaction = output.Interaction;

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

/// `k. label` with a single lowercase letter key (leading spaces allowed).
pub fn lettered(text: []const u8) ?struct { key: []const u8, label: []const u8 } {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') i += 1;
    if (i + 2 >= text.len or !std.ascii.isLower(text[i]) or text[i + 1] != '.' or text[i + 2] != ' ') return null;
    return .{ .key = text[i .. i + 1], .label = text[i + 3 ..] };
}

/// The first row of the run of lettered option lines right above `p`, when
/// there are at least two.
fn letteredRun(lines: []const Line, p: usize) ?usize {
    var k = p;
    while (k > 0 and lettered(lines[k - 1].text) != null) k -= 1;
    return if (p - k >= 2) k else null;
}

/// The option list above the last choice-prompt line, or null when none is
/// showing (or an input box below it says it is stale): numbered options
/// (`1. Yes`), or a run of lettered ones right above the prompt (`y. Yes`,
/// chosen by typing their letter), whose prompt leads with its question.
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

    var options: std.ArrayList(Option) = .empty;
    const letter_run = letteredRun(lines, p);
    const f = if (letter_run) |run| blk: {
        for (lines[run..p]) |l| {
            const lt = lettered(l.text).?;
            var o = try makeOption(alloc, sc, lt.label);
            o.key = try alloc.dupe(u8, lt.key);
            try options.append(alloc, o);
        }
        break :blk run;
    } else blk: {
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
        const one = first orelse return null;
        var label: std.ArrayList(u8) = .empty;
        var expected: u32 = 1;
        for (lines[one..p], one..) |l, row| {
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
        break :blk one;
    };

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
        if (kind == .permission and letter_run == null) {
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
    const opts = try options.toOwnedSlice(alloc);
    return .{
        .kind = kind,
        .title = title,
        .detail = detail,
        .hint = try std.mem.join(alloc, "\n", hint.items),
        .options = opts,
        .free_text = textOption(sc, kind, opts) != null,
        .rows_start = h,
        .rows_end = end,
    };
}

/// The option a free-text answer goes through: the first one a
/// `text_options` rule for `kind` matches, or null.
pub fn textOption(sc: *const adapter.Screen, kind: vocab.InteractionKind, options: []const Option) ?usize {
    for (sc.text_options) |r| {
        if (r.kind) |k| if (k != kind) continue;
        for (options, 0..) |o, i| if (r.matcher.matches(o.label)) return i;
    }
    return null;
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
    \\    "background": { "pattern": "· +[0-9]+ shell|· +[0-9]+ monitor" },
    \\    "background_agent": { "pattern": "^ +◯ " },
    \\    "choice_prompt": { "prefix": "Select with numbers [" },
    \\    "permission": { "prefix": "Permission Required:" },
    \\    "bell_needs_input": true,
    \\    "queued": { "prefix": "ctrl+enter to send now" },
    \\    "text_options": [ { "kind": "permission", "pattern": "^No$" } ]
    \\  },
    \\  "actions": { "answer_text": [ { "pick": "{choice}" }, { "key": "enter" }, { "wait": "idle" }, { "text": "{text}" }, { "key": "enter" } ] },
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

test "a redraw's stale copy is dropped, the redraw kept; a repeated single record is not a redraw" {
    const R = struct {
        fn r(kind: vocab.RecordKind, text: []const u8) Rec {
            return .{ .kind = kind, .first = 0, .line_id = 0, .text = @constCast(text) };
        }
    };
    const a = R.r(.assistant, "Reading the screen engine to find where turns are folded.");
    const b = R.r(.tool, "Bash (zig test src/agent/screen_source.zig)\n12 passed");
    const c = R.r(.assistant, "The fold rule misses reprinted older turns; fixing it.");
    const recs = [_]Rec{
        R.r(.user, "fix it"),
        a,
        b,
        // The stale copy's last line, cut where the screen began.
        R.r(.assistant, "The fold rule misses"),
        a,
        b,
        c,
    };
    const out = try dropStaleCopies(t.allocator, &recs);
    defer t.allocator.free(out);
    try t.expectEqual(@as(usize, 4), out.len);
    try t.expectEqualStrings("fix it", out[0].text);
    try t.expectEqualStrings(c.text, out[3].text);
    // A job that runs one command twice keeps both runs.
    const twice = [_]Rec{ R.r(.user, "again"), b, a, b, c };
    const kept = try dropStaleCopies(t.allocator, &twice);
    defer t.allocator.free(kept);
    try t.expectEqual(@as(usize, 5), kept.len);
    try t.expect(alnumRelated("Hello, wor", "hello world!"));
    try t.expect(!alnumRelated("hello there", "hello world"));
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

test "interactions: Claude Code's trust dialog is a lettered permission prompt" {
    var set = adapter.Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    const sc = &set.get("claude").?.screen.?;
    // Measured, Claude Code 2.1.287 --ax-screen-reader in a new directory.
    const lines = try mk(&.{
        "[Screen Reader Mode: on via flag]",
        "Permission Required: Accessing workspace:",
        "/tmp/scratch/untrusted-probe",
        "Quick safety check: Is this a project you created or one you trust? (Like your",
        "own code, a well-known open source project, or work from your team). If not,",
        "take a moment to review what's in this folder first.",
        "Claude Code'll be able to read, edit, and execute files here.",
        "Security guide",
        "y. Yes, I trust this folder",
        "n. No, exit",
        "Enter y/n:",
        "Enter to confirm · Esc to cancel",
    });
    defer t.allocator.free(lines);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const it = (try parseInteraction(arena.allocator(), sc, lines)).?;
    try t.expectEqual(vocab.InteractionKind.permission, it.kind);
    try t.expectEqualStrings("Permission Required: Accessing workspace:", it.title);
    try t.expectEqual(@as(usize, 2), it.options.len);
    try t.expectEqualStrings("Yes, I trust this folder", it.options[0].label);
    try t.expectEqualStrings("y", it.options[0].key);
    try t.expectEqualStrings("n", it.options[1].key);
    // Chosen by label, part of one, number or the letter itself.
    try t.expectEqual(@as(?usize, 0), it.pick("yes"));
    try t.expectEqual(@as(?usize, 1), it.pick("2"));
    try t.expectEqual(@as(?usize, 1), it.pick("n"));
    try t.expectEqual(@as(?usize, 0), it.pick("trust"));
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

test "queued previews are live, never records; the streaming answer above them is not" {
    const l = try testAdapter();
    defer l.destroy(t.allocator);
    const sc = &l.screen.?;
    // As Claude Code 2.1.287 draws a prompt typed while it works.
    const lines = try mk(&.{
        "you: write an essay",
        "claude: The essay begins",
        "and goes on",
        "you: after the essay, say",
        "PINEAPPLE",
        "ctrl+enter to send now",
        "[Haiku 4.5]",
        "[■■□□] 21%",
        "manual mode on",
        "$",
    });
    defer t.allocator.free(lines);
    const input = findInput(sc, lines, 8).?;
    markLive(sc, lines, input, 2);
    try t.expectEqual(@as(u32, 1), markQueued(sc, lines, input));
    try t.expect(lines[3].live and lines[4].live and lines[5].live);
    try t.expect(!lines[2].live);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const recs = try parseRecords(arena.allocator(), sc, lines);
    try t.expectEqual(@as(usize, 2), recs.len);
    try t.expectEqualStrings("The essay begins\nand goes on", recs[1].text);
    // Without the line, nothing is a preview.
    const plain = try mk(&.{ "you: a", "claude: b", "[Haiku 4.5]", "[■■□□] 21%", "manual mode on", "$" });
    defer t.allocator.free(plain);
    markLive(sc, plain, 5, 2);
    try t.expectEqual(@as(u32, 0), markQueued(sc, plain, 5));
    try t.expect(!plain[1].live);
}

test "a text option is matched per interaction kind" {
    const l = try testAdapter();
    defer l.destroy(t.allocator);
    const sc = &l.screen.?;
    const opts = [_]Option{ .{ .label = "Yes", .selected = false }, .{ .label = "No", .selected = false } };
    try t.expectEqual(@as(?usize, 1), textOption(sc, .permission, &opts));
    try t.expectEqual(@as(?usize, null), textOption(sc, .choice, &opts));
    const lines = try mk(&.{
        "tool: Bash (touch x)",
        "Permission Required: Bash command",
        "Do you want to proceed?",
        "1. Yes",
        "2. No",
        "Select with numbers [1-2]. Then Enter to submit or Escape to cancel:",
    });
    defer t.allocator.free(lines);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expect((try parseInteraction(arena.allocator(), sc, lines)).?.free_text);
    lines[4].text = "2. Not now";
    try t.expect(!(try parseInteraction(arena.allocator(), sc, lines)).?.free_text);
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

// Claude Code 2.1.288 `--ax-screen-reader`, `/btw` measured on 2026-10-03
// (term-6.cast): busy below a running foreground command, then idle.
const BTW_BUSY = "/btw what are you doing right now?";
const BTW_IDLE = "/btw which command did you just run?";

test "side panel: a busy agent's answered panel below its turn, never status rows or records" {
    var set = adapter.Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    const sc = &set.get("claude").?.screen.?;
    const lines = try mk(&.{
        "you: Run this exact command with Bash in the FOREGROUND (not in the background), wait for it, then reply with the word",
        "finished: python3 -c \"import time; time.sleep(40)\"",
        "tool: Bash (python3 -c \"import time; time.sleep(40)\")",
        "Running…  (13s)",
        "(ctrl+b to run in background)",
        "Grooving…",
        BTW_BUSY,
        "I'm answering your side question. The main agent is running the python3 -c \"import time; time.sleep(40)\" command in the",
        "foreground and waiting for it to complete.",
        "↑/↓ to scroll · c to copy · f to fork · Esc to close",
        "[Haiku 4.5]",
        "[■■■■■□□□□□] 14% | 172k free | 0h 0m | $0.02 | 5h:0% 7d:98%",
        "manual mode on",
        "$",
    });
    defer t.allocator.free(lines);
    const input = findInput(sc, lines, 8).?;
    // The footer is chrome: the status block is its two rows, not the panel.
    try t.expectEqual(@as(?usize, 2), measureStatusRows(sc, lines, input, 10));
    markLive(sc, lines, input, 2);
    const p = findSidePanel(sc, lines).?;
    try t.expectEqual(@as(usize, 6), p.top);
    try t.expectEqual(@as(usize, 9), p.footer);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ans = (try sideAnswer(a, sc, lines, p, BTW_BUSY)).?;
    try t.expect(!ans.pending);
    try t.expectEqualStrings("I'm answering your side question. The main agent is running the python3 -c \"import time; time.sleep(40)\" command in the\nforeground and waiting for it to complete.", ans.text);
    // A question the panel does not name has no answer there.
    try t.expect((try sideAnswer(a, sc, lines, p, "/btw how far are you?")) == null);
    // The panel rows marked live, as the engine does: the turn's records only.
    for (lines[p.top .. p.footer + 1]) |*l| l.live = true;
    const recs = try parseRecords(a, sc, lines);
    try t.expectEqual(@as(usize, 2), recs.len);
    try t.expectEqual(vocab.RecordKind.tool, recs[1].kind);
    for (recs) |r| try t.expect(std.mem.indexOf(u8, r.text, "side question") == null);

    // Before the answer: "Answering…" over the bare footer.
    const asking = try mk(&.{ "Grooving…", BTW_BUSY, "Answering…", "Esc to close", "[Haiku 4.5]", "[■■□□] 14%", "manual mode on", "$" });
    defer t.allocator.free(asking);
    markLive(sc, asking, 7, 2);
    const pa = findSidePanel(sc, asking).?;
    const pending = (try sideAnswer(a, sc, asking, pa, BTW_BUSY)).?;
    try t.expect(pending.pending);
    try t.expectEqualStrings("", pending.text);
    // No panel: a footer-shaped line that is not last, or no question above it.
    const none = try mk(&.{ "claude: press Esc to close", "manual mode on", "$" });
    defer t.allocator.free(none);
    try t.expect(findSidePanel(sc, none) == null);
}

test "side panel: an idle agent's panel lists earlier questions; its echo is never a prompt" {
    var set = adapter.Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    const sc = &set.get("claude").?.screen.?;
    const lines = try mk(&.{
        "you: Run this exact command, then reply with the word finished",
        "tool: Bash (python3 -c \"import time; time.sleep(40)\")",
        "claude: finished",
        "Baked for 43s · done 4:31 PM",
        "you: " ++ BTW_IDLE,
        BTW_BUSY,
        BTW_IDLE,
        "I ran: python3 -c \"import time; time.sleep(40)\"",
        "",
        "It's a Python command that sleeps for 40 seconds.",
        "⇧←/→ to browse · c to copy · f to fork · x to clear history · Esc to close",
    });
    defer t.allocator.free(lines);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Even unmarked, the echo is chrome and the panel text after it is
    // dropped: the transcript is the turn, never `/btw`.
    const raw = try parseRecords(a, sc, lines);
    try t.expectEqual(@as(usize, 3), raw.len);
    try t.expectEqualStrings("finished", raw[2].text);
    // The panel replaced the input box.
    try t.expect(findInput(sc, lines, 8) == null);
    const p = findSidePanel(sc, lines).?;
    try t.expectEqual(@as(usize, 5), p.top);
    try t.expectEqual(@as(usize, 10), p.footer);
    // Ours is the last question: its answer keeps its blank line.
    const ans = (try sideAnswer(a, sc, lines, p, BTW_IDLE)).?;
    try t.expect(!ans.pending);
    try t.expectEqualStrings("I ran: python3 -c \"import time; time.sleep(40)\"\n\nIt's a Python command that sleeps for 40 seconds.", ans.text);
    // The same question asked again: the newest copy answers.
    const twice = try mk(&.{ BTW_IDLE, "old answer", BTW_IDLE, "new answer", "Esc to close" });
    defer t.allocator.free(twice);
    try t.expectEqualStrings("new answer", (try sideAnswer(a, sc, twice, findSidePanel(sc, twice).?, BTW_IDLE)).?.text);
    // A question the panel wrapped onto a second row still matches.
    const wrapped = try mk(&.{ "Grooving…", "/btw how far along are you with the", "screen engine refactor?", "About halfway.", "Esc to close" });
    defer t.allocator.free(wrapped);
    const pw = findSidePanel(sc, wrapped).?;
    try t.expectEqual(@as(usize, 1), pw.top);
    try t.expectEqualStrings("About halfway.", (try sideAnswer(a, sc, wrapped, pw, "/btw how far along are you with the screen engine refactor?")).?.text);
    // An earlier, longer question that merely starts like ours is not ours.
    try t.expect((try sideAnswer(a, sc, wrapped, pw, "/btw how far along are you")) == null);
}
