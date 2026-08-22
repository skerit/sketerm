//! OSC 52 clipboard conformance tests. Inspired by
//! kitty/kitty_tests/clipboard.py — Kitty has a streaming base64
//! decoder (StreamingBase64Decoder) for very large clipboard
//! payloads; we use std.base64 in one shot and cap the payload at
//! 1 MB. These tests exercise the OSC 52 round-trip end-to-end:
//! raw text → base64 → OSC 52 sequence → captured `on_clipboard_set`.

const std = @import("std");
const Harness = @import("test_harness.zig").Harness;

test "OSC 52: small base64 round-trip ('title')" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    try h.feedOsc52("title");
    try std.testing.expectEqualStrings("title", h.clipboard.items);
}

test "OSC 52: 'light work'" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    try h.feedOsc52("light work");
    try std.testing.expectEqualStrings("light work", h.clipboard.items);
}

test "OSC 52: 'light work.' (period forces full padding)" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    try h.feedOsc52("light work.");
    try std.testing.expectEqualStrings("light work.", h.clipboard.items);
}

test "OSC 52: roundtrip with binary bytes" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    const raw: []const u8 = &.{ 0x00, 0x01, 0x02, 0xFE, 0xFF };
    try h.feedOsc52(raw);
    try std.testing.expectEqualSlices(u8, raw, h.clipboard.items);
}

test "OSC 52: read query (data='?') is gated, no clipboard set" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b]52;c;?\x07");
    try std.testing.expectEqual(@as(usize, 0), h.clipboard.items.len);
}

test "OSC 52: empty data is a no-op" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b]52;c;\x07");
    try std.testing.expectEqual(@as(usize, 0), h.clipboard.items.len);
}

test "OSC 52: invalid base64 silently dropped" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b]52;c;@@@@@\x07");
    try std.testing.expectEqual(@as(usize, 0), h.clipboard.items.len);
}

test "OSC 52: payload split across two feed() calls assembles" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    // 'hello' = aGVsbG8=
    h.feed("\x1b]52;c;aGVs");
    h.feed("bG8=\x07");
    try std.testing.expectEqualStrings("hello", h.clipboard.items);
}
