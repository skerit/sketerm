//! Completion list rules that are protocol, not presentation: the
//! request's `CompletionContext`, the server's ranking (`sortText`), the
//! client-side filter (`filterText`) and the one transaction an accepted
//! item becomes, `additionalTextEdits` included.
//!
//! The GUI half (popup, keys, resolve plumbing) is `ui/editorlsp.zig`.
//! GTK-free, in both test roots.
//!
//! ## Filtering is local unless the server says otherwise
//!
//! A `CompletionList` with `isIncomplete: false` is the COMPLETE answer
//! for the word being typed: typing more of the word only narrows it, so
//! the client filters what it has and asks nothing. `isIncomplete: true`
//! means the server cut the list short (a big project, a fuzzy index),
//! so the client filters locally for the keystroke AND re-asks, with
//! `triggerKind: 3` (TriggerForIncompleteCompletions).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rope = @import("../editor/rope.zig").Rope;
const tr = @import("../editor/transaction.zig");
const pos = @import("position.zig");
const suggest = @import("../util/suggest.zig");

/// Why a completion request is sent (`CompletionTriggerKind`).
pub const Trigger = union(enum) {
    /// The user asked (Ctrl+Space): kind 1.
    invoked,
    /// A server-declared trigger character was typed: kind 2.
    character: u8,
    /// Typing continued on an `isIncomplete` list: kind 3.
    incomplete,
};

/// The `,"context":{...}` fragment for `trigger`, appended to the
/// position params. A non-printable or quote/backslash trigger character
/// is sent without `triggerCharacter` rather than as broken JSON.
pub fn contextJson(buf: []u8, trigger: Trigger) []const u8 {
    return switch (trigger) {
        .invoked => std.fmt.bufPrint(buf, ",\"context\":{{\"triggerKind\":1}}", .{}) catch "",
        .incomplete => std.fmt.bufPrint(buf, ",\"context\":{{\"triggerKind\":3}}", .{}) catch "",
        .character => |ch| if (ch >= 0x20 and ch < 0x7f and ch != '"' and ch != '\\')
            std.fmt.bufPrint(buf, ",\"context\":{{\"triggerKind\":2,\"triggerCharacter\":\"{c}\"}}", .{ch}) catch ""
        else
            std.fmt.bufPrint(buf, ",\"context\":{{\"triggerKind\":2}}", .{}) catch "",
    };
}

/// The key the server ranks an item by: `sortText`, else its label.
pub fn sortKey(item: std.json.ObjectMap, label: []const u8) []const u8 {
    return strOf(item.get("sortText")) orelse label;
}

/// The text the typed prefix is matched against: `filterText`, else its
/// label.
pub fn filterKey(item: std.json.ObjectMap, label: []const u8) []const u8 {
    return strOf(item.get("filterText")) orelse label;
}

/// `isIncomplete` of a completion answer; a bare item array is complete.
pub fn isIncomplete(result: std.json.Value) bool {
    return switch (result) {
        .object => |o| switch (o.get("isIncomplete") orelse .null) {
            .bool => |b| b,
            else => false,
        },
        else => false,
    };
}

/// Indices of `keys` in the server's ranking order: ascending byte order
/// of the sort key, stable, so equal keys keep the server's own order.
pub fn rankOrder(alloc: Allocator, keys: []const []const u8) ![]usize {
    const idx = try alloc.alloc(usize, keys.len);
    for (idx, 0..) |*v, i| v.* = i;
    std.sort.insertion(usize, idx, keys, struct {
        fn lt(k: []const []const u8, a: usize, b: usize) bool {
            return std.mem.order(u8, k[a], k[b]) == .lt;
        }
    }.lt);
    return idx;
}

/// Does an item whose filter key is `key` survive the typed `prefix`?
/// Case-insensitive subsequence, the matcher every fuzzy list here uses.
pub fn matches(key: []const u8, prefix: []const u8) bool {
    return suggest.subsequenceMatch(key, prefix);
}

/// One `additionalTextEdits` entry in document bytes.
pub const Extra = struct {
    start: usize,
    end: usize,
    /// Owned.
    text: []u8,
};

pub fn freeExtras(alloc: Allocator, extras: []Extra) void {
    for (extras) |e| alloc.free(e.text);
    alloc.free(extras);
}

/// `additionalTextEdits` of an item (or a resolve answer), converted
/// against `rope`. Missing or malformed = none.
pub fn parseExtras(alloc: Allocator, item: std.json.Value, rope: *const Rope, enc: pos.Encoding) ![]Extra {
    const o = switch (item) {
        .object => |o| o,
        else => return &.{},
    };
    const arr = switch (o.get("additionalTextEdits") orelse .null) {
        .array => |a| a.items,
        else => return &.{},
    };
    var out: std.ArrayList(Extra) = .empty;
    errdefer {
        for (out.items) |e| alloc.free(e.text);
        out.deinit(alloc);
    }
    for (arr) |te| {
        if (te != .object) continue;
        const text = strOf(te.object.get("newText")) orelse continue;
        const offs = pos.rangeToOffsets(rope, pos.parseRange(te.object.get("range") orelse .null), enc);
        const owned = try alloc.dupe(u8, text);
        out.append(alloc, .{ .start = offs.start, .end = offs.end, .text = owned }) catch |err| {
            alloc.free(owned);
            return err;
        };
    }
    return out.toOwnedSlice(alloc);
}

/// The edits an accept applies, sorted and non-overlapping, borrowing
/// the texts. `main` replaces [main_start, main_end).
///
/// An extra is measured against the text it was converted at. Typing
/// only ever happens at or after `stable_before` (the word start) while
/// a list is open, so an extra that ENDS there is still exact; one that
/// reaches past it is applied only while `extras_current` (the document
/// has not moved since its conversion). Extras overlapping the main
/// edit or each other are dropped: the spec forbids them, and one bad
/// server item must not take the accepted text down with it.
pub fn assemble(
    alloc: Allocator,
    main_start: usize,
    main_end: usize,
    main_text: []const u8,
    extras: []const Extra,
    stable_before: usize,
    extras_current: bool,
    doc_len: usize,
) !std.ArrayList(tr.Edit) {
    var edits: std.ArrayList(tr.Edit) = .empty;
    errdefer edits.deinit(alloc);
    try edits.append(alloc, .{ .offset = main_start, .deleted_len = main_end - main_start, .inserted = main_text });
    for (extras) |e| {
        if (e.end > doc_len or e.start > e.end) continue;
        if (e.end > stable_before and !extras_current) continue;
        // Touching the main range from inside or across it: dropped. An
        // insert exactly at either end of it is fine.
        const crosses = e.start < main_end and e.end > main_start;
        const inside = e.start > main_start and e.start < main_end;
        if (crosses or inside) continue;
        try edits.append(alloc, .{ .offset = e.start, .deleted_len = e.end - e.start, .inserted = e.text });
    }
    // Stable, so an insert sharing the main edit's start stays after it.
    std.sort.insertion(tr.Edit, edits.items, {}, struct {
        fn lt(_: void, x: tr.Edit, y: tr.Edit) bool {
            return x.offset < y.offset;
        }
    }.lt);
    // Extras overlapping each other: the later one goes.
    var w: usize = 0;
    var prev_end: usize = 0;
    for (edits.items) |e| {
        const is_main = e.inserted.ptr == main_text.ptr and e.offset == main_start;
        if (w > 0 and e.offset < prev_end and !is_main) continue;
        edits.items[w] = e;
        w += 1;
        prev_end = e.offset + e.deleted_len;
    }
    edits.shrinkRetainingCapacity(w);
    return edits;
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "completion: context carries the trigger kind and character" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings(",\"context\":{\"triggerKind\":1}", contextJson(&buf, .invoked));
    try testing.expectEqualStrings(",\"context\":{\"triggerKind\":3}", contextJson(&buf, .incomplete));
    try testing.expectEqualStrings(",\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}", contextJson(&buf, .{ .character = '.' }));
    // A quote would break the JSON: the kind still goes out.
    try testing.expectEqualStrings(",\"context\":{\"triggerKind\":2}", contextJson(&buf, .{ .character = '"' }));
}

test "completion: rank by sortText, stable on ties, label as fallback" {
    const keys = [_][]const u8{ "b", "a", "b", "0" };
    const order = try rankOrder(testing.allocator, &keys);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, &.{ 3, 1, 0, 2 }, order);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"label":"zeta","sortText":"01","filterText":"z_eta"},{"label":"alpha"}]
    , .{});
    defer parsed.deinit();
    const items = parsed.value.array.items;
    try testing.expectEqualStrings("01", sortKey(items[0].object, "zeta"));
    try testing.expectEqualStrings("alpha", sortKey(items[1].object, "alpha"));
    try testing.expectEqualStrings("z_eta", filterKey(items[0].object, "zeta"));
    try testing.expect(matches("z_eta", "ZE"));
    try testing.expect(!matches("alpha", "ax"));
}

test "completion: isIncomplete only from a CompletionList that says so" {
    var a = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"isIncomplete\":true,\"items\":[]}", .{});
    defer a.deinit();
    try testing.expect(isIncomplete(a.value));
    var b = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[]", .{});
    defer b.deinit();
    try testing.expect(!isIncomplete(b.value));
}

test "completion: additionalTextEdits join the accept as one sorted edit list" {
    var rope = try Rope.initFromBytes(testing.allocator, "line0\nfoo(ba\n");
    defer rope.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"label":"bar","additionalTextEdits":[
        \\ {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"import x;\n"},
        \\ {"range":{"start":{"line":1,"character":4},"end":{"line":1,"character":6}},"newText":"CLASH"}]}
    , .{});
    defer parsed.deinit();
    const extras = try parseExtras(testing.allocator, parsed.value, &rope, .utf16);
    defer freeExtras(testing.allocator, extras);
    try testing.expectEqual(@as(usize, 2), extras.len);
    try testing.expectEqual(@as(usize, 0), extras[0].start);

    // Main edit: "ba" at 10..12 -> "bar". The second extra overlaps it
    // and is dropped; the import lands first.
    var edits = try assemble(testing.allocator, 10, 12, "bar", extras, 10, true, rope.len());
    defer edits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), edits.items.len);
    try testing.expectEqual(@as(usize, 0), edits.items[0].offset);
    try testing.expectEqualStrings("import x;\n", edits.items[0].inserted);
    try testing.expectEqualStrings("bar", edits.items[1].inserted);
    try tr.validateEdits(edits.items, rope.len());
}

test "completion: a stale extra past the word start is not applied" {
    var text = [_]u8{ 'x', 'y' };
    const extras = [_]Extra{
        .{ .start = 0, .end = 0, .text = text[0..1] },
        .{ .start = 20, .end = 21, .text = text[1..2] },
    };
    var edits = try assemble(testing.allocator, 10, 12, "bar", &extras, 10, false, 30);
    defer edits.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), edits.items.len);
    try testing.expectEqualStrings("x", edits.items[0].inserted);
    try testing.expectEqualStrings("bar", edits.items[1].inserted);
}
