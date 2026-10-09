//! The page-reading query (`SemQuery.page`, capability `page-read`) as
//! both ends speak it: the options a client sends, the vocabulary of the
//! answer semantic.js builds, and the one parser for that answer.
//! Engine-free and std-only, so both test roots import it; semantic.js
//! spells the same names and a test here holds the two together.

const std = @import("std");

/// What one page query reads. Mirrored by semantic.js `PAGE_WHAT`.
pub const What = enum {
    /// Reader-mode markdown of the scope.
    text,
    /// The scope's serialized markup (outerHTML).
    html,
    /// Every link in the scope with its absolute url and page area.
    links,
    /// Every script and iframe in the scope.
    resources,
};

/// Where on the page an element sits: its nearest landmark ancestor.
/// Mirrored by semantic.js `LINK_AREAS`; `other` = under none.
pub const Area = enum { nav, header, main, footer, aside, other };

/// Why the page refused a query. Mirrored by semantic.js `PAGE_ERRORS`.
pub const ErrorCode = enum {
    /// `selector` is not valid CSS.
    invalid_selector,
    /// `selector` matched no element.
    no_match,
    /// Anything else the page threw.
    failed,
};

pub const Options = struct {
    what: What,
    /// CSS selector; every match (outermost only) is the scope. Null =
    /// the reader's main region for text, the whole document otherwise.
    selector: ?[]const u8 = null,
    /// Text: keep navigation, banner, footer and aside landmarks (the
    /// whole body when there is no selector) instead of dropping them.
    chrome: bool = false,
};

pub const Link = struct {
    text: []const u8 = "",
    /// Absolute: resolved against the document's base url.
    href: []const u8 = "",
    area: Area = .other,
    /// The element has a layout box (it is not display:none, nor inside
    /// something that is).
    visible: bool = false,
};

pub const Script = struct {
    /// Absolute url; null for an inline script.
    src: ?[]const u8 = null,
    @"inline": bool = false,
    /// Characters of an inline script's source; null for an external one.
    size: ?u64 = null,
    type: []const u8 = "",
    @"async": bool = false,
    @"defer": bool = false,
};

pub const Frame = struct {
    src: []const u8 = "",
    name: []const u8 = "",
    title: []const u8 = "",
    visible: bool = false,
};

pub const Result = struct {
    what: What,
    url: []const u8 = "",
    /// Outermost elements the selector matched (0 without one).
    selector_matches: u64 = 0,
    /// Text or markup (`text`/`html`).
    text: ?[]const u8 = null,
    /// Characters before the page's own cap.
    total_chars: u64 = 0,
    /// The page cut text, markup or a list at its own cap.
    truncated: bool = false,
    links: []const Link = &.{},
    links_total: u64 = 0,
    scripts: []const Script = &.{},
    scripts_total: u64 = 0,
    iframes: []const Frame = &.{},
    iframes_total: u64 = 0,
};

const Wire = struct {
    result: ?Result = null,
    @"error": ?[]const u8 = null,
    code: ?ErrorCode = null,
};

pub const Answer = union(enum) {
    ok: Result,
    refused: struct { code: ErrorCode, msg: []const u8 },
    /// Not JSON: an older helper answered the unknown kind from its
    /// find_text arm ("query find ..."), or a plain refusal sentence.
    legacy: []const u8,
    /// JSON, but not this shape (an unknown area or kind included):
    /// fails closed rather than guessing.
    malformed,
};

/// The one reader of a page-query reply.
pub fn parse(arena: std.mem.Allocator, payload: []const u8) Answer {
    const trimmed = std.mem.trimStart(u8, payload, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return .{ .legacy = payload };
    const w = std.json.parseFromSliceLeaky(Wire, arena, trimmed, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .malformed;
    if (w.result) |r| return .{ .ok = r };
    if (w.@"error") |msg| return .{ .refused = .{ .code = w.code orelse .failed, .msg = msg } };
    return .malformed;
}

/// The options as the JSON argument the query carries.
pub fn encode(arena: std.mem.Allocator, o: Options) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(o, .{ .emit_null_optional_fields = false }, &aw.writer);
    return aw.written();
}

const t = std.testing;

/// The names inside `var <name> = [...]` in semantic.js.
fn jsList(comptime name: []const u8) []const u8 {
    const js = @embedFile("semantic.js");
    const head = "var " ++ name ++ " = [";
    const at = std.mem.indexOf(u8, js, head) orelse @panic("semantic.js lost " ++ name);
    const rest = js[at + head.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, ']') orelse @panic("unterminated " ++ name)];
}

fn expectMirrors(comptime E: type, comptime name: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, jsList(name), "\", \n");
    for (std.enums.values(E)) |v| try t.expectEqualStrings(@tagName(v), it.next() orelse return error.TestUnexpectedResult);
    try t.expect(it.next() == null);
}

test "semantic.js spells the page-read vocabulary exactly as declared here" {
    try expectMirrors(What, "PAGE_WHAT");
    try expectMirrors(Area, "LINK_AREAS");
    try expectMirrors(ErrorCode, "PAGE_ERRORS");
}

test "a page reply parses, refuses, or fails closed" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const ok = parse(ar, "{\"op\":\"page\",\"req\":3,\"result\":{\"what\":\"links\",\"links\":[{\"text\":\"Home\",\"href\":\"https://x/\",\"area\":\"nav\",\"visible\":true}],\"links_total\":1}}");
    try t.expectEqual(What.links, ok.ok.what);
    try t.expectEqual(Area.nav, ok.ok.links[0].area);
    const bad = parse(ar, "{\"error\":\"'[[' is not a valid selector\",\"code\":\"invalid_selector\"}");
    try t.expectEqual(ErrorCode.invalid_selector, bad.refused.code);
    // An area this build does not know is never mapped onto one it does.
    try t.expect(parse(ar, "{\"result\":{\"what\":\"links\",\"links\":[{\"area\":\"sidebar\"}]}}") == .malformed);
    try t.expect(parse(ar, "query find \"{}\" 0 matches\n") == .legacy);
    try t.expect(parse(ar, "{}") == .malformed);
    const enc = try encode(ar, .{ .what = .text, .selector = "main p", .chrome = true });
    try t.expectEqualStrings("{\"what\":\"text\",\"selector\":\"main p\",\"chrome\":true}", enc);
    try t.expectEqualStrings("{\"what\":\"links\",\"chrome\":false}", try encode(ar, .{ .what = .links }));
}
