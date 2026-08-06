//! Title templates: `{{ NAME }}` substitution for tab labels and the
//! window title. Rio-compatible syntax (`{{ TITLE || RELATIVE_PATH }}`),
//! a CLOSED placeholder set so `validate` can reject typos at config
//! parse time, and no allocation — `render` writes into a caller buffer,
//! because titles re-render on every OSC 0/2 and every cwd change.
//!
//! GTK-free and libc-free on purpose: `config.zig` calls `validate`, and
//! `config.zig` compiles into the libc-only `sketerm-mux`.
//!
//! The interesting part is separator collapsing. A template like
//! `"{{ PROGRAM }} - {{ RELATIVE_PATH }}"` must not render `"nvim - "`
//! when the path is unknown, so an empty placeholder CONSUMES one
//! adjacent punctuation-only literal: the one that FOLLOWS it, or, if
//! nothing follows, the one that PRECEDES it. See `render` for the
//! worked cases.

const std = @import("std");

/// Longest title we will ever produce. Tab labels ellipsize far below
/// this; the window title is the only consumer that gets near it.
pub const MAX = 512;

pub const Field = enum {
    /// OSC 0/2 title, exactly as the application set it.
    title,
    /// Foreground process name on the pane's pty (daemon-sampled).
    program,
    /// Working directory, absolute.
    absolute_path,
    /// Working directory with `$HOME` folded to `~`.
    relative_path,
    columns,
    lines,
    /// 1-based tab position.
    index,
    /// Mux session name (empty for a plain local pane).
    session,
    /// Active profile name (empty on the Default profile).
    profile,
    /// `"zoom"` while the pane is zoomed, else empty.
    zoom,
};

/// Bit per `Field`, so a caller can skip a re-render for a fact its
/// template never mentions (a resize must not churn every tab label
/// when no template uses COLUMNS).
pub const Mask = std.EnumSet(Field);

pub const Facts = struct {
    title: []const u8 = "",
    program: []const u8 = "",
    absolute_path: []const u8 = "",
    relative_path: []const u8 = "",
    /// 0 means "unknown" and renders empty, which lets the separator
    /// rule collapse around it.
    columns: u16 = 0,
    lines: u16 = 0,
    index: u32 = 0,
    session: []const u8 = "",
    profile: []const u8 = "",
    zoomed: bool = false,
};

pub const Error = error{
    /// A `{{ ... }}` naming something outside `Field`.
    UnknownPlaceholder,
    /// A `{{` with no closing `}}`.
    UnterminatedPlaceholder,
};

/// Details for a diagnostic: which name was rejected, and where.
pub const Diag = struct {
    name: []const u8 = "",
    offset: usize = 0,
};

/// Comma-separated list of every accepted placeholder, lowercase — for
/// the warning `config.zig` prints when `validate` rejects a template.
pub const field_list = blk: {
    var s: []const u8 = "";
    for (std.meta.fields(Field), 0..) |f, i| {
        s = s ++ (if (i == 0) "" else ", ") ++ f.name;
    }
    break :blk s;
};

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and isSpace(s[a])) a += 1;
    while (b > a and isSpace(s[b - 1])) b -= 1;
    return s[a..b];
}

/// Placeholder names are case-insensitive (Rio accepts `{{ program }}`
/// and `{{ PROGRAM }}` alike), and `_` is the only word separator.
fn fieldFromName(name: []const u8) ?Field {
    inline for (std.meta.fields(Field)) |f| {
        if (name.len == f.name.len) {
            var same = true;
            for (name, f.name) |a, b| {
                if (std.ascii.toLower(a) != b) {
                    same = false;
                    break;
                }
            }
            if (same) return @field(Field, f.name);
        }
    }
    return null;
}

/// A literal made only of punctuation/space is a SEPARATOR: it exists
/// to join two values and is dropped when one of them is missing. A
/// literal carrying letters or digits is a word the user typed on
/// purpose and is always kept.
fn isSeparator(lit: []const u8) bool {
    for (lit) |ch| {
        if (std.ascii.isAlphanumeric(ch)) return false;
    }
    return true;
}

const Node = union(enum) {
    literal: []const u8,
    /// Fallback chain: first non-empty wins (`{{ A || B }}`).
    placeholder: struct { buf: [4]Field, len: u8 },
};

/// Streaming tokenizer shared by validate/uses/render, so all three
/// agree on what a template means.
const Parser = struct {
    tmpl: []const u8,
    pos: usize = 0,

    fn next(self: *Parser, diag: *Diag) Error!?Node {
        if (self.pos >= self.tmpl.len) return null;
        const rest = self.tmpl[self.pos..];

        if (std.mem.startsWith(u8, rest, "{{")) {
            const open_at = self.pos;
            const close = std.mem.indexOf(u8, rest, "}}") orelse {
                diag.offset = open_at;
                return Error.UnterminatedPlaceholder;
            };
            const inner = rest[2..close];
            self.pos += close + 2;

            var ph: @FieldType(Node, "placeholder") = .{ .buf = undefined, .len = 0 };
            var it = std.mem.splitSequence(u8, inner, "||");
            while (it.next()) |raw| {
                const name = trim(raw);
                const f = fieldFromName(name) orelse {
                    diag.name = name;
                    diag.offset = open_at;
                    return Error.UnknownPlaceholder;
                };
                // More than four fallbacks is beyond any sane title;
                // silently keeping the first four is friendlier than
                // failing a config on it.
                if (ph.len < ph.buf.len) {
                    ph.buf[ph.len] = f;
                    ph.len += 1;
                }
            }
            if (ph.len == 0) {
                diag.name = "";
                diag.offset = open_at;
                return Error.UnknownPlaceholder;
            }
            return Node{ .placeholder = ph };
        }

        // Literal run up to the next `{{`.
        const end = std.mem.indexOf(u8, rest, "{{") orelse rest.len;
        self.pos += end;
        return Node{ .literal = rest[0..end] };
    }
};

/// Reject unknown placeholders and unterminated `{{`. Called by
/// `config.zig` at parse time: the placeholder set is closed, so a typo
/// like `{{ TITEL }}` is always a mistake and telling the user about it
/// beats silently rendering nothing forever.
pub fn validate(tmpl: []const u8, diag: *Diag) Error!void {
    var p = Parser{ .tmpl = tmpl };
    while (try p.next(diag)) |_| {}
}

/// Which facts this template actually reads. Invalid templates report
/// whatever they parsed before the error; callers only use this on
/// templates that already passed `validate`.
pub fn uses(tmpl: []const u8) Mask {
    var m = Mask.initEmpty();
    var diag: Diag = .{};
    var p = Parser{ .tmpl = tmpl };
    while (p.next(&diag) catch null) |node| {
        switch (node) {
            .literal => {},
            .placeholder => |ph| {
                for (ph.buf[0..ph.len]) |f| m.insert(f);
            },
        }
    }
    return m;
}

fn resolve(f: Field, facts: Facts, scratch: []u8) []const u8 {
    return switch (f) {
        .title => facts.title,
        .program => facts.program,
        .absolute_path => facts.absolute_path,
        .relative_path => facts.relative_path,
        .columns => if (facts.columns == 0) "" else std.fmt.bufPrint(scratch, "{d}", .{facts.columns}) catch "",
        .lines => if (facts.lines == 0) "" else std.fmt.bufPrint(scratch, "{d}", .{facts.lines}) catch "",
        .index => if (facts.index == 0) "" else std.fmt.bufPrint(scratch, "{d}", .{facts.index}) catch "",
        .session => facts.session,
        .profile => facts.profile,
        .zoom => if (facts.zoomed) "zoom" else "",
    };
}

/// Upper bound on template pieces. A template is chrome a human types;
/// anything past this renders truncated rather than allocating.
const MAX_NODES = 64;

/// Render `tmpl` into `out`, returning the used slice. Never fails and
/// never allocates; a template that overflows `out` is truncated.
///
/// Separator handling, by worked case (`-` standing for any
/// punctuation-only literal, `A B C` for placeholders):
///   `A - B`,     B empty        -> `A`       (retracts the opened `-`)
///   `A - B`,     A empty        -> `B`       (empty A eats the next `-`)
///   `A - B - C`, B empty        -> `A - C`   (B eats ONE separator)
///   `A (B x C)`, B and C empty  -> `A`       (the whole group retracts)
///   `A (B x C)`, all present    -> `A (b x c)`
///   `sketerm`                   -> `sketerm` (word literals are kept)
///
/// A word literal (one carrying letters or digits) is normally the
/// user's own text and is kept, EXCEPT when it sits between two
/// placeholders that both resolved empty — that is the `x` in
/// `"{{ COLUMNS }}x{{ LINES }}"`, which is a join, not a word.
///
/// KNOWN LIMITATION: a literal the user typed with nothing after it,
/// e.g. `"{{ PROGRAM }} - "`, keeps its `-`. Only separators orphaned
/// by an EMPTY PLACEHOLDER are removed; we do not second-guess text
/// the template itself ends with.
pub fn render(out: []u8, tmpl: []const u8, facts: Facts) []const u8 {
    // Pass 1: tokenize into a fixed node array and resolve every
    // placeholder, so pass 2 can look at a literal's right-hand
    // neighbour (the `{{ COLUMNS }}x{{ LINES }}` case needs it).
    var nodes: [MAX_NODES]Node = undefined;
    var values: [MAX_NODES][]const u8 = undefined;
    var scratch: [MAX_NODES][12]u8 = undefined;
    var n: usize = 0;

    var diag: Diag = .{};
    var p = Parser{ .tmpl = tmpl };
    while (n < MAX_NODES) {
        const start = p.pos;
        const node = p.next(&diag) catch {
            // Malformed tail (unterminated `{{`). `validate` is what
            // rejects these; `render` stays total by treating the
            // remainder as literal text.
            nodes[n] = .{ .literal = tmpl[start..] };
            values[n] = "";
            n += 1;
            break;
        } orelse break;
        nodes[n] = node;
        values[n] = switch (node) {
            .literal => "",
            .placeholder => |ph| blk: {
                for (ph.buf[0..ph.len]) |f| {
                    const v = resolve(f, facts, &scratch[n]);
                    if (v.len > 0) break :blk v;
                }
                break :blk "";
            },
        };
        n += 1;
    }

    var len: usize = 0;
    const append = struct {
        fn f(dst: []u8, cur: *usize, s: []const u8) void {
            const take = @min(dst.len - cur.*, s.len);
            @memcpy(dst[cur.*..][0..take], s[0..take]);
            cur.* += take;
        }
    }.f;

    // Offset where the current run of separator bytes began, while no
    // value has yet confirmed it. Null once a value lands.
    var pending_sep: ?usize = null;
    // An empty placeholder is "owed" one separator: it eats the next
    // punctuation-only literal, or — if it never gets one — retracts
    // the separator that was opened ahead of it.
    var owed = false;

    for (nodes[0..n], values[0..n], 0..) |node, value, i| {
        switch (node) {
            .literal => |lit| {
                if (lit.len == 0) continue;
                const sep = isSeparator(lit);
                // A word literal wedged between two empty placeholders
                // is a join with nothing left to join.
                const wedged = !sep and i > 0 and i + 1 < n and
                    nodes[i - 1] == .placeholder and values[i - 1].len == 0 and
                    nodes[i + 1] == .placeholder and values[i + 1].len == 0;
                if (wedged) continue;
                if (sep and owed) {
                    // Eaten by the empty placeholder before it. The
                    // debt only clears if we are NOT inside a group
                    // that is still unconfirmed — otherwise the opened
                    // separator must still be retracted at the end.
                    if (pending_sep == null) owed = false;
                    continue;
                }
                if (sep) {
                    if (pending_sep == null) pending_sep = len;
                    append(out, &len, lit);
                } else {
                    append(out, &len, lit);
                    pending_sep = null;
                    owed = false;
                }
            },
            .placeholder => {
                if (value.len == 0) {
                    owed = true;
                    continue;
                }
                append(out, &len, value);
                pending_sep = null;
                owed = false;
            },
        }
    }

    // An unpaid debt at the end means the separator we opened leads
    // nowhere — drop it (`"nvim - "` with an empty path, `"nvim ("`
    // with empty dimensions).
    if (owed) {
        if (pending_sep) |start| len = start;
    }

    return trim(out[0..len]);
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

const full = Facts{
    .title = "vim README.md",
    .program = "nvim",
    .absolute_path = "/home/jelle/src/sketerm",
    .relative_path = "~/src/sketerm",
    .columns = 120,
    .lines = 40,
    .index = 3,
    .session = "work",
    .profile = "dark",
    .zoomed = true,
};

fn r(tmpl: []const u8, facts: Facts) []const u8 {
    const S = struct {
        var buf: [MAX]u8 = undefined;
    };
    return render(&S.buf, tmpl, facts);
}

test "titlefmt: every placeholder resolves" {
    try t.expectEqualStrings("vim README.md", r("{{ TITLE }}", full));
    try t.expectEqualStrings("nvim", r("{{ PROGRAM }}", full));
    try t.expectEqualStrings("/home/jelle/src/sketerm", r("{{ ABSOLUTE_PATH }}", full));
    try t.expectEqualStrings("~/src/sketerm", r("{{ RELATIVE_PATH }}", full));
    try t.expectEqualStrings("120", r("{{ COLUMNS }}", full));
    try t.expectEqualStrings("40", r("{{ LINES }}", full));
    try t.expectEqualStrings("3", r("{{ INDEX }}", full));
    try t.expectEqualStrings("work", r("{{ SESSION }}", full));
    try t.expectEqualStrings("dark", r("{{ PROFILE }}", full));
    try t.expectEqualStrings("zoom", r("{{ ZOOM }}", full));
}

test "titlefmt: placeholder names are case-insensitive and space-tolerant" {
    try t.expectEqualStrings("nvim", r("{{program}}", full));
    try t.expectEqualStrings("nvim", r("{{ Program }}", full));
    try t.expectEqualStrings("nvim", r("{{   PROGRAM   }}", full));
}

test "titlefmt: the brief's example renders" {
    try t.expectEqualStrings(
        "3: nvim - ~/src/sketerm",
        r("{{ INDEX }}: {{ PROGRAM }} - {{ RELATIVE_PATH }}", full),
    );
}

test "titlefmt: fallback chain takes the first non-empty" {
    var f = full;
    f.title = "";
    try t.expectEqualStrings("nvim", r("{{ TITLE || PROGRAM }}", f));
    f.program = "";
    try t.expectEqualStrings("~/src/sketerm", r("{{ TITLE || PROGRAM || RELATIVE_PATH }}", f));
    f.relative_path = "";
    try t.expectEqualStrings("", r("{{ TITLE || PROGRAM || RELATIVE_PATH }}", f));
}

test "titlefmt: pure literal template passes through" {
    try t.expectEqualStrings("sketerm", r("sketerm", full));
    // Punctuation-only template has no value to collapse against, so
    // it survives rather than rendering blank.
    try t.expectEqualStrings("*", r("*", full));
}

test "titlefmt: empty value eats the preceding separator" {
    var f = full;
    f.relative_path = "";
    try t.expectEqualStrings("nvim", r("{{ PROGRAM }} - {{ RELATIVE_PATH }}", f));
}

test "titlefmt: empty value eats the following separator" {
    var f = full;
    f.program = "";
    try t.expectEqualStrings("~/src/sketerm", r("{{ PROGRAM }} - {{ RELATIVE_PATH }}", f));
}

test "titlefmt: an empty middle value leaves ONE separator, not zero or two" {
    var f = full;
    f.program = "";
    try t.expectEqualStrings("3 - ~/src/sketerm", r("{{ INDEX }} - {{ PROGRAM }} - {{ RELATIVE_PATH }}", f));
}

test "titlefmt: every value empty renders empty" {
    const none = Facts{};
    try t.expectEqualStrings("", r("{{ TITLE }} - {{ PROGRAM }} - {{ RELATIVE_PATH }}", none));
    try t.expectEqualStrings("", r("{{ COLUMNS }}x{{ LINES }}", none));
}

test "titlefmt: surrounding whitespace is trimmed" {
    try t.expectEqualStrings("nvim", r("  {{ PROGRAM }}  ", full));
    // Text the template itself ends with is the user's own and is
    // kept — only separators orphaned by an empty value are dropped.
    try t.expectEqualStrings("nvim -", r("{{ PROGRAM }} - ", full));
}

test "titlefmt: an empty group retracts the punctuation that opened it" {
    var f = full;
    f.columns = 0;
    f.lines = 0;
    try t.expectEqualStrings("nvim", r("{{ PROGRAM }} ({{ COLUMNS }}x{{ LINES }})", f));
    // ...and keeps it when the group has content.
    try t.expectEqualStrings("nvim (120x40)", r("{{ PROGRAM }} ({{ COLUMNS }}x{{ LINES }})", full));
}

test "titlefmt: word literals are kept even next to an empty value" {
    var f = full;
    f.program = "";
    // "tab " carries letters, so it is the user's own text, not a
    // separator, and survives.
    try t.expectEqualStrings("tab 3", r("tab {{ INDEX }}{{ PROGRAM }}", f));
}

test "titlefmt: zoom collapses when the pane is not zoomed" {
    var f = full;
    f.zoomed = false;
    try t.expectEqualStrings("vim README.md", r("{{ ZOOM }} {{ TITLE }}", f));
    f.zoomed = true;
    try t.expectEqualStrings("zoom vim README.md", r("{{ ZOOM }} {{ TITLE }}", f));
}

test "titlefmt: dimensions render as a pair" {
    try t.expectEqualStrings("nvim (120x40)", r("{{ PROGRAM }} ({{ COLUMNS }}x{{ LINES }})", full));
}

test "titlefmt: validate accepts the whole placeholder set" {
    var diag: Diag = .{};
    inline for (std.meta.fields(Field)) |f| {
        try validate("{{ " ++ f.name ++ " }}", &diag);
    }
    try validate("plain text", &diag);
    try validate("{{ TITLE || PROGRAM }} - {{ LINES }}", &diag);
}

test "titlefmt: validate rejects an unknown placeholder and names it" {
    var diag: Diag = .{};
    try t.expectError(Error.UnknownPlaceholder, validate("{{ TITEL }}", &diag));
    try t.expectEqualStrings("TITEL", diag.name);
    try t.expectError(Error.UnknownPlaceholder, validate("ok {{ TITLE }} {{ nope }}", &diag));
    try t.expectEqualStrings("nope", diag.name);
    // An unknown name anywhere in a fallback chain is still a typo.
    try t.expectError(Error.UnknownPlaceholder, validate("{{ TITLE || bogus }}", &diag));
}

test "titlefmt: validate rejects an unterminated placeholder" {
    var diag: Diag = .{};
    try t.expectError(Error.UnterminatedPlaceholder, validate("{{ TITLE", &diag));
    try t.expectError(Error.UnterminatedPlaceholder, validate("a {{ b", &diag));
}

test "titlefmt: uses reports exactly the referenced fields" {
    const m = uses("{{ TITLE || PROGRAM }} ({{ COLUMNS }})");
    try t.expect(m.contains(.title));
    try t.expect(m.contains(.program));
    try t.expect(m.contains(.columns));
    try t.expect(!m.contains(.lines));
    try t.expect(!m.contains(.relative_path));
    try t.expect(uses("no placeholders here").eql(Mask.initEmpty()));
}

test "titlefmt: render truncates instead of overflowing a short buffer" {
    var small: [4]u8 = undefined;
    try t.expectEqualStrings("nvim", render(&small, "{{ PROGRAM }}{{ TITLE }}", full));
}

test "titlefmt: an unterminated placeholder renders as literal text" {
    // validate() is what rejects these; render must still be total.
    try t.expectEqualStrings("{{ TITLE", r("{{ TITLE", full));
}

test "titlefmt: field_list names every field for diagnostics" {
    try t.expect(std.mem.indexOf(u8, field_list, "title") != null);
    try t.expect(std.mem.indexOf(u8, field_list, "relative_path") != null);
    try t.expect(std.mem.indexOf(u8, field_list, "zoom") != null);
}
