//! JSON string literals appended to a growing byte list, encoded by std.json.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Append `s` as a quoted JSON string literal; UTF-8 passes through unescaped.
pub fn append(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, out);
    defer out.* = aw.toArrayList();
    std.json.Stringify.encodeJsonString(s, .{}, &aw.writer) catch return error.OutOfMemory;
}

test "append escapes quotes, backslashes and control bytes, keeps UTF-8 and prior content" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, "x:");
    try append(a, &out, "a\"b\\c\n\r\t\x08\x0c\x01\x1f\u{e9}");
    try std.testing.expectEqualStrings("x:\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\u{e9}\"", out.items);
    const parsed = try std.json.parseFromSlice([]const u8, a, out.items[2..], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b\\c\n\r\t\x08\x0c\x01\x1f\u{e9}", parsed.value);
}
