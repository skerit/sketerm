//! Selection-extraction conformance tests inspired by
//! kitty/kitty_tests/screen.py::test_selection_as_text. We don't
//! support Kitty's word-/line-select-with-modifiers semantics yet,
//! so this focuses on the primitive: select a rectangle of cells
//! and extract the text.

const std = @import("std");
const Harness = @import("../parser/test_harness.zig").Harness;

test "selection_as_text: linear forward selection" {
    var h = try Harness.init(std.testing.allocator, 5, 3);
    defer h.deinit();
    h.arm();
    h.feed("01234\r\n56789\r\nabcde");
    h.screen.selection.start(0, 0, .normal);
    h.screen.selection.extend(2, 5);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("01234\n56789\nabcde", out);
}

test "selection_as_text: backward selection (start > end) normalizes" {
    var h = try Harness.init(std.testing.allocator, 5, 3);
    defer h.deinit();
    h.arm();
    h.feed("01234\r\n56789\r\nabcde");
    h.screen.selection.start(2, 5, .normal);
    h.screen.selection.extend(0, 0);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("01234\n56789\nabcde", out);
}

test "selection_as_text: partial first row + partial last row" {
    var h = try Harness.init(std.testing.allocator, 10, 2);
    defer h.deinit();
    h.arm();
    h.feed("0123456789\r\nabcdefghij");
    h.screen.selection.start(0, 5, .normal);
    h.screen.selection.extend(1, 5);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    // Cols [5..end] from row 0 = "56789", cols [0..5) from row 1 = "abcde".
    try std.testing.expectEqualStrings("56789\nabcde", out);
}

test "selection_as_text: empty selection returns empty string" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("hello");
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "selection_as_text: spans wrapped (soft-wrap) row, no spurious newline" {
    var h = try Harness.init(std.testing.allocator, 5, 2);
    defer h.deinit();
    h.arm();
    h.feed("hellowor"); // wraps: row0='hello', row1='wor'
    h.screen.selection.start(0, 0, .normal);
    h.screen.selection.extend(1, 4);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hellowor", out);
}

test "selection_as_text: skips wide-char continuation cells" {
    var h = try Harness.init(std.testing.allocator, 6, 1);
    defer h.deinit();
    h.arm();
    // 'a' + '中' (wide, takes 2 cols) + 'b'
    h.feed("a\xe4\xb8\xadb");
    h.screen.selection.start(0, 0, .normal);
    h.screen.selection.extend(0, 4);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\xe4\xb8\xadb", out);
}

test "selection_as_text: trailing blanks trimmed within row" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("abc"); // remaining 7 cells empty
    h.screen.selection.start(0, 0, .normal);
    h.screen.selection.extend(0, 10);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "selection rect single cell" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("hello");
    h.screen.selection.start(0, 2, .normal);
    h.screen.selection.extend(0, 3);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("l", out);
}

test "selection: combining mark stays attached to base" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    // 'a' + U+0301 (combining acute accent)
    h.feed("a\xcc\x81b");
    h.screen.selection.start(0, 0, .normal);
    h.screen.selection.extend(0, 2);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\xcc\x81b", out);
}

test "selection: variation selector + emoji round-trips" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    // '*' + VS-16 (U+FE0F)
    h.feed("*\xef\xb8\x8f");
    h.screen.selection.start(0, 0, .normal);
    h.screen.selection.extend(0, 1);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("*\xef\xb8\x8f", out);
}

test "selection: ZWJ sequence preserved (man + ZWJ)" {
    var h = try Harness.init(std.testing.allocator, 8, 1);
    defer h.deinit();
    h.arm();
    // 👨 (U+1F468, wide) + ZWJ (U+200D — extending, attaches)
    h.feed("\xf0\x9f\x91\xa8\xe2\x80\x8d");
    h.screen.selection.start(0, 0, .normal);
    h.screen.selection.extend(0, 2);
    const out = try h.screen.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    // Cluster contains the man emoji plus the ZWJ as an extension.
    try std.testing.expectEqualStrings("\xf0\x9f\x91\xa8\xe2\x80\x8d", out);
}
