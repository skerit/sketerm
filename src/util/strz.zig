//! Small pure-value helpers over byte slices, shared by the GUI, the
//! daemon and the editor. Nothing here allocates or touches libc.

const std = @import("std");

/// Optional-slice equality: two unset values are equal, one unset is not.
pub fn eqOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Membership of `needle` in an unsorted list of strings.
pub fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// Truncating copy into a sentinel buffer of any size (`*[N:0]u8`).
///
/// `buf` stays `anytype` because the result is `@ptrCast(buf)`: a
/// `[]u8` parameter would force that cast through `.ptr` and lose the
/// array length the copy is bounded by.
/// @return pointer into `buf`, valid only while `buf` lives.
pub fn copyZ(buf: anytype, text: []const u8) [*:0]const u8 {
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return @ptrCast(buf);
}

/// Word-constituent byte: `[A-Za-z0-9_]` plus every non-ASCII byte, so
/// a UTF-8 continuation never splits a word.
pub fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or b == '_' or b >= 0x80;
}

const t = std.testing;

test "eqOpt treats unset as a value of its own" {
    try t.expect(eqOpt(null, null));
    try t.expect(!eqOpt(null, ""));
    try t.expect(!eqOpt("", null));
    try t.expect(eqOpt("", ""));
    try t.expect(eqOpt("host", "host"));
    try t.expect(!eqOpt("host", "hosts"));
    try t.expect(!eqOpt("host", "other"));
}

test "contains over an empty and a populated list" {
    const empty: []const []const u8 = &.{};
    try t.expect(!contains(empty, "a"));
    const list: []const []const u8 = &.{ "a", "bb", "" };
    try t.expect(contains(list, "a"));
    try t.expect(contains(list, "bb"));
    try t.expect(contains(list, ""));
    try t.expect(!contains(list, "b"));
}

test "copyZ truncates and always terminates" {
    var buf: [8:0]u8 = undefined;
    try t.expectEqualStrings("", std.mem.span(copyZ(&buf, "")));
    try t.expectEqualStrings("1234567", std.mem.span(copyZ(&buf, "1234567")));
    try t.expectEqualStrings("1234567", std.mem.span(copyZ(&buf, "12345678")));
    try t.expectEqualStrings("1234567", std.mem.span(copyZ(&buf, "123456789abc")));
    var one: [1:0]u8 = undefined;
    try t.expectEqualStrings("", std.mem.span(copyZ(&one, "x")));
}

test "isWordByte at the ASCII boundary" {
    try t.expect(isWordByte('a') and isWordByte('Z') and isWordByte('0'));
    try t.expect(isWordByte('_'));
    try t.expect(!isWordByte('-') and !isWordByte(' ') and !isWordByte('.'));
    try t.expect(!isWordByte(0x7f));
    try t.expect(isWordByte(0x80));
    try t.expect(isWordByte(0xff));
}
