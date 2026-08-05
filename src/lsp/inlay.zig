//! Inlay hints: the parsed, display-only decorations a server returns
//! for a RANGE of the document.
//!
//! Two properties this module exists to guarantee:
//!
//! * A hint is `(byte offset, text)` and nothing else. It is never part
//!   of the document, the rope, or any byte-offset arithmetic — the
//!   renderer draws it between clusters and the caret cannot enter it.
//! * The offset comes out of `position.zig` like every other server
//!   position, so a hint on a line containing an emoji lands where the
//!   server meant it to.
//!
//! `label` is either a string or an array of `InlayHintLabelPart`s;
//! both flatten to plain text here because the editor has no rich-text
//! run to hang a part's tooltip or command off.
//!
//! GTK-free and in both test roots (src/lsp/CLAUDE.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rope = @import("../editor/rope.zig").Rope;
const pos = @import("position.zig");

/// LSP `InlayHintKind`. Only used to decide the padding a server did
/// not ask for explicitly, and to let the theme tell the two apart.
pub const Kind = enum(u8) {
    other = 0,
    type_hint = 1,
    parameter = 2,

    pub fn fromInt(i: i64) Kind {
        return switch (i) {
            1 => .type_hint,
            2 => .parameter,
            else => .other,
        };
    }
};

pub const Hint = struct {
    /// Document byte offset the hint is drawn BEFORE. Never a position
    /// inside the hint's own text — hints have no byte space.
    offset: usize,
    /// Flattened label, owned by the `Set`, already carrying whatever
    /// `paddingLeft` / `paddingRight` asked for.
    text: []u8,
    kind: Kind = .other,
};

/// An owned, offset-sorted hint set for one document revision.
pub const Set = struct {
    alloc: Allocator,
    items: std.ArrayList(Hint) = .empty,
    /// Document revision `items` offsets are exact for.
    revision: u64 = 0,
    /// Bumped on every replace — the render-side cache key (a layout
    /// that shaped hints at generation N must re-shape at N+1).
    generation: u64 = 0,
    /// Line range the current set was requested for, so scrolling
    /// inside it costs no request at all.
    from_line: u32 = 0,
    to_line: u32 = 0,
    valid: bool = false,

    pub fn init(alloc: Allocator) Set {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Set) void {
        self.clear();
        self.items.deinit(self.alloc);
    }

    pub fn clear(self: *Set) void {
        for (self.items.items) |h| self.alloc.free(h.text);
        self.items.clearRetainingCapacity();
        self.valid = false;
    }

    /// Replace the set from an `InlayHint[]` payload. Anything that
    /// fails to parse is skipped; a wholly unusable payload leaves an
    /// empty (but valid) set, which renders as "no hints here".
    pub fn absorb(
        self: *Set,
        result: std.json.Value,
        rope: *const Rope,
        enc: pos.Encoding,
        revision: u64,
        from_line: u32,
        to_line: u32,
    ) Allocator.Error!void {
        self.clear();
        self.revision = revision;
        self.from_line = from_line;
        self.to_line = to_line;
        self.generation +%= 1;
        self.valid = true;
        const arr = switch (result) {
            .array => |a| a,
            else => return,
        };
        for (arr.items) |v| {
            if (v != .object) continue;
            const o = v.object;
            const p = pos.parsePosition(o.get("position") orelse .null);
            const kind = switch (o.get("kind") orelse std.json.Value.null) {
                .integer => |i| Kind.fromInt(i),
                else => Kind.other,
            };
            var text: std.ArrayList(u8) = .empty;
            errdefer text.deinit(self.alloc);
            if (boolOf(o.get("paddingLeft"))) try text.append(self.alloc, ' ');
            try appendLabel(self.alloc, &text, o.get("label") orelse .null);
            if (text.items.len == 0) {
                text.deinit(self.alloc);
                continue;
            }
            if (boolOf(o.get("paddingRight"))) try text.append(self.alloc, ' ');
            const owned = try text.toOwnedSlice(self.alloc);
            self.items.append(self.alloc, .{
                .offset = pos.positionToOffset(rope, p, enc),
                .text = owned,
                .kind = kind,
            }) catch {
                self.alloc.free(owned);
                return;
            };
        }
        std.mem.sort(Hint, self.items.items, {}, lessByOffset);
    }

    fn lessByOffset(_: void, a: Hint, b: Hint) bool {
        return a.offset < b.offset;
    }

    /// True when `line` is inside the range the current set covers, so
    /// scrolling within it needs no new request.
    pub fn covers(self: *const Set, from_line: u32, to_line: u32) bool {
        return self.valid and from_line >= self.from_line and to_line <= self.to_line;
    }
};

fn boolOf(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return switch (val) {
        .bool => |b| b,
        else => false,
    };
}

/// `string | InlayHintLabelPart[]`, flattened.
fn appendLabel(alloc: Allocator, out: *std.ArrayList(u8), v: std.json.Value) Allocator.Error!void {
    switch (v) {
        .string => |s| try out.appendSlice(alloc, s),
        .array => |a| for (a.items) |part| {
            if (part == .string) {
                try out.appendSlice(alloc, part.string);
            } else if (part == .object) {
                if (part.object.get("value")) |val| {
                    if (val == .string) try out.appendSlice(alloc, val.string);
                }
            }
        },
        else => {},
    }
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "inlay: a string label lands on the right byte offset" {
    var rope = try Rope.initFromBytes(testing.allocator, "let x = f();\nlet y = g();\n");
    defer rope.deinit();
    var p = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\[{"position":{"line":1,"character":5},"label":": i32","kind":1}]
    ,
        .{},
    );
    defer p.deinit();
    var set = Set.init(testing.allocator);
    defer set.deinit();
    try set.absorb(p.value, &rope, .utf16, 3, 0, 40);
    try testing.expectEqual(@as(usize, 1), set.items.items.len);
    try testing.expectEqual(@as(usize, 18), set.items.items[0].offset);
    try testing.expectEqualStrings(": i32", set.items.items[0].text);
    try testing.expectEqual(Kind.type_hint, set.items.items[0].kind);
    try testing.expectEqual(@as(u64, 3), set.revision);
    try testing.expect(set.generation != 0);
}

test "inlay: label parts flatten and padding becomes real spaces" {
    var rope = try Rope.initFromBytes(testing.allocator, "f(1)\n");
    defer rope.deinit();
    var p = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\[{"position":{"line":0,"character":2},
        \\  "label":[{"value":"count"},{"value":":"}],
        \\  "paddingRight":true,"kind":2}]
    ,
        .{},
    );
    defer p.deinit();
    var set = Set.init(testing.allocator);
    defer set.deinit();
    try set.absorb(p.value, &rope, .utf16, 1, 0, 1);
    try testing.expectEqualStrings("count: ", set.items.items[0].text);
    try testing.expectEqual(Kind.parameter, set.items.items[0].kind);
}

test "inlay: an emoji line maps through the position encoding" {
    // The emoji is 4 bytes and TWO utf-16 units; character 3 is the 'x'
    // right after it, i.e. byte 5.
    var rope = try Rope.initFromBytes(testing.allocator, "a\u{1F600}x = 1\n");
    defer rope.deinit();
    var p = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "[{\"position\":{\"line\":0,\"character\":3},\"label\":\"h\"}]",
        .{},
    );
    defer p.deinit();
    var set = Set.init(testing.allocator);
    defer set.deinit();
    try set.absorb(p.value, &rope, .utf16, 1, 0, 1);
    try testing.expectEqual(@as(usize, 5), set.items.items[0].offset);
    // In utf-8 the same character index means byte 3.
    try set.absorb(p.value, &rope, .utf8, 1, 0, 1);
    try testing.expectEqual(@as(usize, 3), set.items.items[0].offset);
}

test "inlay: an empty label is dropped and the set stays sorted" {
    var rope = try Rope.initFromBytes(testing.allocator, "abcdefghij\n");
    defer rope.deinit();
    var p = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\[{"position":{"line":0,"character":8},"label":"z"},
        \\ {"position":{"line":0,"character":2},"label":""},
        \\ {"position":{"line":0,"character":4},"label":"a"}]
    ,
        .{},
    );
    defer p.deinit();
    var set = Set.init(testing.allocator);
    defer set.deinit();
    try set.absorb(p.value, &rope, .utf16, 1, 0, 1);
    try testing.expectEqual(@as(usize, 2), set.items.items.len);
    try testing.expectEqual(@as(usize, 4), set.items.items[0].offset);
    try testing.expectEqual(@as(usize, 8), set.items.items[1].offset);
}

test "inlay: covers only claims the requested line window" {
    var rope = try Rope.initFromBytes(testing.allocator, "x\n");
    defer rope.deinit();
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[]", .{});
    defer p.deinit();
    var set = Set.init(testing.allocator);
    defer set.deinit();
    try testing.expect(!set.covers(0, 1));
    try set.absorb(p.value, &rope, .utf16, 1, 10, 60);
    try testing.expect(set.covers(20, 30));
    try testing.expect(!set.covers(5, 30));
    try testing.expect(!set.covers(20, 90));
}

test "inlay: a non-array payload leaves an empty but valid set" {
    var rope = try Rope.initFromBytes(testing.allocator, "x\n");
    defer rope.deinit();
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "null", .{});
    defer p.deinit();
    var set = Set.init(testing.allocator);
    defer set.deinit();
    try set.absorb(p.value, &rope, .utf16, 1, 0, 1);
    try testing.expect(set.valid);
    try testing.expectEqual(@as(usize, 0), set.items.items.len);
}
