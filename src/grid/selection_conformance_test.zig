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
    h.select(0, 0, 2, 5);
    try h.expectSelection("01234\n56789\nabcde");
}

test "selection_as_text: backward selection (start > end) normalizes" {
    var h = try Harness.init(std.testing.allocator, 5, 3);
    defer h.deinit();
    h.arm();
    h.feed("01234\r\n56789\r\nabcde");
    h.select(2, 5, 0, 0);
    try h.expectSelection("01234\n56789\nabcde");
}

test "selection_as_text: partial first row + partial last row" {
    var h = try Harness.init(std.testing.allocator, 10, 2);
    defer h.deinit();
    h.arm();
    h.feed("0123456789\r\nabcdefghij");
    h.select(0, 5, 1, 5);
    // Cols [5..end] from row 0 = "56789", cols [0..5) from row 1 = "abcde".
    try h.expectSelection("56789\nabcde");
}

test "selection_as_text: empty selection returns empty string" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("hello");
    try h.expectSelection("");
}

test "selection_as_text: spans wrapped (soft-wrap) row, no spurious newline" {
    var h = try Harness.init(std.testing.allocator, 5, 2);
    defer h.deinit();
    h.arm();
    h.feed("hellowor"); // wraps: row0='hello', row1='wor'
    h.select(0, 0, 1, 4);
    try h.expectSelection("hellowor");
}

test "selection_as_text: skips wide-char continuation cells" {
    var h = try Harness.init(std.testing.allocator, 6, 1);
    defer h.deinit();
    h.arm();
    // 'a' + '中' (wide, takes 2 cols) + 'b'
    h.feed("a\xe4\xb8\xadb");
    h.select(0, 0, 0, 4);
    try h.expectSelection("a\xe4\xb8\xadb");
}

test "selection_as_text: trailing blanks trimmed within row" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("abc"); // remaining 7 cells empty
    h.select(0, 0, 0, 10);
    try h.expectSelection("abc");
}

test "selection rect single cell" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("hello");
    h.select(0, 2, 0, 3);
    try h.expectSelection("l");
}

test "selection: combining mark stays attached to base" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    // 'a' + U+0301 (combining acute accent)
    h.feed("a\xcc\x81b");
    h.select(0, 0, 0, 2);
    try h.expectSelection("a\xcc\x81b");
}

test "selection: variation selector + emoji round-trips" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    // '*' + VS-16 (U+FE0F)
    h.feed("*\xef\xb8\x8f");
    h.select(0, 0, 0, 1);
    try h.expectSelection("*\xef\xb8\x8f");
}

test "selection: ZWJ sequence preserved (man + ZWJ)" {
    var h = try Harness.init(std.testing.allocator, 8, 1);
    defer h.deinit();
    h.arm();
    // 👨 (U+1F468, wide) + ZWJ (U+200D — extending, attaches)
    h.feed("\xf0\x9f\x91\xa8\xe2\x80\x8d");
    h.select(0, 0, 0, 2);
    // Cluster contains the man emoji plus the ZWJ as an extension.
    try h.expectSelection("\xf0\x9f\x91\xa8\xe2\x80\x8d");
}
