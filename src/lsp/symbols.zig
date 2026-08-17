//! `textDocument/documentSymbol` -> the editor's `Outline`.
//!
//! The reply is line/column against the document AS THE SERVER SAW IT.
//! Mapping it onto a rope that has moved on produces entries that point
//! at the wrong lines and — because filling an outline stamps it with
//! the CURRENT revision — declares them authoritative, so the panel
//! keeps them until the next edit: exactly the type-pause-look case.
//! Hence `error.Stale`, the same refusal `outline.fromTree` gives for a
//! lagging Tree-sitter parse.
//!
//! GTK-free and in both test roots.

const std = @import("std");
const Document = @import("../editor/document.zig").Document;
const outline_mod = @import("../editor/outline.zig");
const Outline = outline_mod.Outline;
const pos = @import("position.zig");

pub const Error = error{Stale} || std.mem.Allocator.Error;

/// Replace `out` with the symbols in `result`.
///
/// `reply_revision` is the document revision the REQUEST was built
/// against; anything else is refused without touching `out`.
pub fn fromLsp(
    out: *Outline,
    doc: *const Document,
    result: std.json.Value,
    enc: pos.Encoding,
    reply_revision: u64,
) Error!void {
    if (doc.revision != reply_revision) return error.Stale;
    out.clear();
    try walk(out, doc, result, enc, 0);
    out.source = .lsp;
    out.revision = doc.revision;
}

/// Both reply shapes: hierarchical `DocumentSymbol[]` with `children`,
/// and the flat `SymbolInformation[]` with `location`.
fn walk(
    out: *Outline,
    doc: *const Document,
    v: std.json.Value,
    enc: pos.Encoding,
    depth: u16,
) std.mem.Allocator.Error!void {
    const arr = switch (v) {
        .array => |a| a,
        else => return,
    };
    for (arr.items) |x| {
        if (x != .object) continue;
        const o = x.object;
        const name = strOf(o.get("name")) orelse continue;
        const kind = outline_mod.fromLsp(intOf(o.get("kind")) orelse 0);
        const detail = strOf(o.get("detail")) orelse "";
        var full = o.get("range") orelse std.json.Value.null;
        var sel = o.get("selectionRange") orelse std.json.Value.null;
        if (o.get("location")) |loc| {
            if (loc == .object) {
                full = loc.object.get("range") orelse std.json.Value.null;
                sel = full;
            }
        }
        if (sel == .null) sel = full;
        const fr = pos.rangeToOffsets(&doc.rope, pos.parseRange(full), enc);
        const sr = pos.rangeToOffsets(&doc.rope, pos.parseRange(sel), enc);
        try out.push(.{
            .kind = kind,
            .depth = depth,
            .start = fr.start,
            .end = fr.end,
            .sel = sr.start,
            .name = name,
            .detail = detail,
        });
        if (o.get("children")) |kids| try walk(out, doc, kids, enc, depth + 1);
    }
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn intOf(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

const testing = std.testing;
const tr = @import("../editor/transaction.zig");

const SRC =
    \\fn alpha() void {}
    \\
    \\fn beta() void {}
    \\
;

/// `beta` on line 2, as a server that saw SRC would report it.
const REPLY =
    \\[{"name":"beta","kind":12,
    \\  "range":{"start":{"line":2,"character":0},"end":{"line":2,"character":17}},
    \\  "selectionRange":{"start":{"line":2,"character":3},"end":{"line":2,"character":7}}}]
;

fn parseReply(alloc: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, REPLY, .{});
}

test "lsp symbols: a reply for the current revision maps exactly" {
    var doc = try Document.initFromBytes(testing.allocator, SRC);
    defer doc.deinit();
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    var parsed = try parseReply(testing.allocator);
    defer parsed.deinit();

    try fromLsp(&o, &doc, parsed.value, .utf16, doc.revision);
    try testing.expectEqual(@as(usize, 1), o.nodes.items.len);
    try testing.expectEqualStrings("beta", o.name(0));
    const line2 = doc.rope.lineToOffset(2);
    try testing.expectEqual(line2, o.nodes.items[0].start);
    try testing.expectEqual(line2 + 3, o.nodes.items[0].sel);
    try testing.expectEqual(outline_mod.Source.lsp, o.source);
}

test "lsp symbols: a reply from before an edit is refused, not mis-mapped" {
    var doc = try Document.initFromBytes(testing.allocator, SRC);
    defer doc.deinit();
    var o = Outline.init(testing.allocator);
    defer o.deinit();
    var parsed = try parseReply(testing.allocator);
    defer parsed.deinit();

    const sent_revision = doc.revision;
    // The user types two lines at the top while the answer is in
    // flight: every line number in it now names other text.
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(testing.allocator);
    try tx.addInsert(testing.allocator, 0, "// one\n// two\n");
    _ = try doc.applyTransaction(&tx);
    try testing.expect(doc.revision != sent_revision);

    try testing.expectError(error.Stale, fromLsp(&o, &doc, parsed.value, .utf16, sent_revision));
    // Refused means UNTOUCHED: the panel keeps whatever it had.
    try testing.expectEqual(outline_mod.Source.none, o.source);
    try testing.expectEqual(@as(usize, 0), o.nodes.items.len);

    // The re-request, answered against the text as it is now, lands on
    // the line the symbol actually moved to.
    try fromLsp(&o, &doc, parsed.value, .utf16, doc.revision);
    // Line 2 is now the SECOND inserted comment, not `fn beta` — the
    // offsets a stale fill would have kept.
    try testing.expectEqual(doc.rope.lineToOffset(2), o.nodes.items[0].start);
    const moved = try doc.rope.sliceAlloc(testing.allocator, doc.rope.lineToOffset(2), doc.rope.lineToOffset(2) + 6);
    defer testing.allocator.free(moved);
    try testing.expectEqualStrings("fn alp", moved);
}
