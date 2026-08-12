//! `browser.i18n` — the message-catalogue rules: locale negotiation and
//! placeholder substitution.
//!
//! Pure std, no CEF, no GTK, in both test roots. Both halves used to be
//! missing, and both are visible to a user rather than internal: without
//! negotiation every extension renders in `default_locale` whatever the
//! session language is, and without substitution every `$1`-bearing
//! string renders with the literal `$1` still in it ("Blocked $1
//! requests" is uBO's own).

const std = @import("std");

/// Pick the best available locale.
///
/// Firefox's order, and the one extensions are written against: an exact
/// tag first (`pt_BR`), then the LANGUAGE alone (`pt`), then anything
/// sharing the language (`pt_PT` for a wanted `pt_BR`), then the
/// manifest's `default_locale`. Tags are compared case-insensitively
/// with `-` and `_` treated as the same separator, because `_locales`
/// directory names use `_` while a BCP-47 tag uses `-`.
pub fn pickLocale(available: []const []const u8, wanted: []const u8, default_locale: []const u8) []const u8 {
    if (wanted.len != 0) {
        for (available) |a| {
            if (tagEql(a, wanted)) return a;
        }
        const lang = languageOf(wanted);
        for (available) |a| {
            if (tagEql(a, lang)) return a;
        }
        for (available) |a| {
            if (tagEql(languageOf(a), lang)) return a;
        }
    }
    for (available) |a| {
        if (tagEql(a, default_locale)) return a;
    }
    return default_locale;
}

fn languageOf(tag: []const u8) []const u8 {
    const i = std.mem.indexOfAny(u8, tag, "-_") orelse return tag;
    return tag[0..i];
}

fn tagEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '-') '_' else std.ascii.toLower(x);
        const ny = if (y == '-') '_' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

/// The `placeholders` object of one catalogue entry: name -> content,
/// where content is itself a template that may reference `$1`..`$9`.
pub const Placeholders = ?std.json.ObjectMap;

/// Expand one catalogue message.
///
/// Order matters and is the spec's: NAMED placeholders (`$name$`) resolve
/// to their `content` first, then every `$1`..`$9` — in the message and
/// in the content that was just spliced in — resolves to a substitution,
/// then `$$` collapses to a literal `$`. Doing it the other way round
/// would let a substitution's own text be re-read as a placeholder.
///
/// An unknown named placeholder and an out-of-range index both expand to
/// EMPTY, which is what Firefox does; leaving the marker in place is the
/// bug this function exists to fix.
pub fn expand(
    gpa: std.mem.Allocator,
    message: []const u8,
    placeholders: Placeholders,
    subs: []const []const u8,
) ![]u8 {
    var stage1: std.Io.Writer.Allocating = .init(gpa);
    defer stage1.deinit();
    try expandNamed(&stage1.writer, message, placeholders);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try expandNumbered(&out.writer, stage1.written(), subs);
    return out.toOwnedSlice();
}

fn expandNamed(w: *std.Io.Writer, message: []const u8, placeholders: Placeholders) !void {
    var i: usize = 0;
    while (i < message.len) {
        if (message[i] != '$') {
            try w.writeByte(message[i]);
            i += 1;
            continue;
        }
        if (i + 1 < message.len and message[i + 1] == '$') {
            // Preserve the escape for the numbered pass to collapse.
            try w.writeAll("$$");
            i += 2;
            continue;
        }
        // A named placeholder is `$name$` where name is [A-Za-z0-9_@].
        var j = i + 1;
        while (j < message.len and isNameByte(message[j])) j += 1;
        if (j < message.len and message[j] == '$' and j > i + 1) {
            const name = message[i + 1 .. j];
            if (lookupContent(placeholders, name)) |content| {
                try w.writeAll(content);
            }
            // An unknown name expands to nothing, marker included.
            i = j + 1;
            continue;
        }
        try w.writeByte('$');
        i += 1;
    }
}

fn expandNumbered(w: *std.Io.Writer, message: []const u8, subs: []const []const u8) !void {
    var i: usize = 0;
    while (i < message.len) {
        if (message[i] != '$') {
            try w.writeByte(message[i]);
            i += 1;
            continue;
        }
        if (i + 1 < message.len and message[i + 1] == '$') {
            try w.writeByte('$');
            i += 2;
            continue;
        }
        if (i + 1 < message.len and message[i + 1] >= '1' and message[i + 1] <= '9') {
            const idx: usize = message[i + 1] - '1';
            if (idx < subs.len) try w.writeAll(subs[idx]);
            i += 2;
            continue;
        }
        try w.writeByte('$');
        i += 1;
    }
}

fn isNameByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '@';
}

fn lookupContent(placeholders: Placeholders, name: []const u8) ?[]const u8 {
    const obj = placeholders orelse return null;
    // Placeholder names are case-insensitive.
    var it = obj.iterator();
    while (it.next()) |kv| {
        if (!std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) continue;
        if (kv.value_ptr.* != .object) return null;
        const content = kv.value_ptr.object.get("content") orelse return null;
        if (content != .string) return null;
        return content.string;
    }
    return null;
}

/// Parse the `substitutions` argument of `getMessage`: absent, a single
/// string, or an array of strings. Returns borrowed slices of `value`.
pub fn substitutionsFrom(gpa: std.mem.Allocator, value: std.json.Value) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    switch (value) {
        .string => |s| try list.append(gpa, s),
        .array => |a| for (a.items) |it| {
            if (it == .string) try list.append(gpa, it.string) else try list.append(gpa, "");
        },
        else => {},
    }
    return list.toOwnedSlice(gpa);
}

// ─── tests ──────────────────────────────────────────────────────────

const t = std.testing;

test "pickLocale: exact, then language, then sibling, then default" {
    const avail = [_][]const u8{ "en", "pt_BR", "nl", "fr_CA" };
    try t.expectEqualStrings("pt_BR", pickLocale(&avail, "pt-BR", "en"));
    try t.expectEqualStrings("nl", pickLocale(&avail, "nl-BE", "en"));
    try t.expectEqualStrings("fr_CA", pickLocale(&avail, "fr-FR", "en"));
    try t.expectEqualStrings("en", pickLocale(&avail, "de", "en"));
    try t.expectEqualStrings("en", pickLocale(&avail, "", "en"));
    // A default that is not on disk is still what we name.
    try t.expectEqualStrings("xx", pickLocale(&avail, "de", "xx"));
}

test "expand: numbered substitutions and the $$ escape" {
    const gpa = t.allocator;
    const subs = [_][]const u8{ "12", "example.com" };
    const a = try expand(gpa, "Blocked $1 requests on $2", null, &subs);
    defer gpa.free(a);
    try t.expectEqualStrings("Blocked 12 requests on example.com", a);

    const b = try expand(gpa, "100$$ sure", null, &.{});
    defer gpa.free(b);
    try t.expectEqualStrings("100$ sure", b);

    // Out of range expands to empty rather than leaving the marker.
    const c = try expand(gpa, "a$3b", null, &subs);
    defer gpa.free(c);
    try t.expectEqualStrings("ab", c);

    // A lone `$` is literal.
    const d = try expand(gpa, "cost: $", null, &.{});
    defer gpa.free(d);
    try t.expectEqualStrings("cost: $", d);
}

test "expand: named placeholders resolve through their content" {
    const gpa = t.allocator;
    const json =
        \\{"count":{"content":"$1","example":"3"},"site":{"content":"[$2]"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const subs = [_][]const u8{ "7", "example.com" };
    const out = try expand(gpa, "Blocked $count$ on $site$", parsed.value.object, &subs);
    defer gpa.free(out);
    try t.expectEqualStrings("Blocked 7 on [example.com]", out);
}

test "expand: named lookup is case-insensitive, unknown names vanish" {
    const gpa = t.allocator;
    const json =
        \\{"COUNT":{"content":"$1"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const subs = [_][]const u8{"9"};
    const out = try expand(gpa, "n=$count$ m=$nope$", parsed.value.object, &subs);
    defer gpa.free(out);
    try t.expectEqualStrings("n=9 m=", out);
}

test "expand: a substitution containing $1 is not re-expanded" {
    const gpa = t.allocator;
    // THE ordering property: the numbered pass runs once, over the
    // message plus spliced content, never over its own output.
    const subs = [_][]const u8{ "$2", "boom" };
    const out = try expand(gpa, "x=$1", null, &subs);
    defer gpa.free(out);
    try t.expectEqualStrings("x=$2", out);
}

test "substitutionsFrom accepts a string, an array or nothing" {
    const gpa = t.allocator;
    var p1 = try std.json.parseFromSlice(std.json.Value, gpa, "\"solo\"", .{});
    defer p1.deinit();
    const a = try substitutionsFrom(gpa, p1.value);
    defer gpa.free(a);
    try t.expectEqual(@as(usize, 1), a.len);
    try t.expectEqualStrings("solo", a[0]);

    var p2 = try std.json.parseFromSlice(std.json.Value, gpa, "[\"a\",\"b\"]", .{});
    defer p2.deinit();
    const b = try substitutionsFrom(gpa, p2.value);
    defer gpa.free(b);
    try t.expectEqual(@as(usize, 2), b.len);
    try t.expectEqualStrings("b", b[1]);

    const c = try substitutionsFrom(gpa, .null);
    defer gpa.free(c);
    try t.expectEqual(@as(usize, 0), c.len);
}
