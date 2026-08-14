//! The one `{"result":…}` / `{"error":…}` envelope every `browser.*`
//! dispatch answers with.
//!
//! Every message goes through `std.json` rather than a `{s}` format
//! hole: an error text is frequently an extension-supplied id, method
//! name or url, and a single double quote in one of those used to emit
//! malformed JSON that the bridge then dropped, turning a clean
//! rejection into a Promise that never settled.

const std = @import("std");

/// `{"result":<value_json>}`. `value_json` must already BE JSON.
pub fn ok(gpa: std.mem.Allocator, value_json: []const u8) []u8 {
    return std.fmt.allocPrint(gpa, "{{\"result\":{s}}}", .{value_json}) catch err(gpa, "oom");
}

/// `{"result":"<value>"}` — the same envelope for a plain string result.
pub fn okString(gpa: std.mem.Allocator, value: []const u8) []u8 {
    return wrap(gpa, "result", value) orelse err(gpa, "oom");
}

/// `{"error":"<message>"}`. Every dispatch result is heap-owned so the
/// caller frees uniformly; a short print cannot realistically OOM.
pub fn err(gpa: std.mem.Allocator, message: []const u8) []u8 {
    return wrap(gpa, "error", message) orelse
        (gpa.dupe(u8, "{\"error\":\"oom\"}") catch unreachable);
}

fn wrap(gpa: std.mem.Allocator, key: []const u8, value: []const u8) ?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    aw.writer.print("{{\"{s}\":", .{key}) catch return null;
    std.json.Stringify.value(value, .{}, &aw.writer) catch return null;
    aw.writer.writeByte('}') catch return null;
    return aw.toOwnedSlice() catch null;
}

test "error messages are escaped rather than emitted raw" {
    const gpa = std.testing.allocator;
    const quoted = err(gpa, "no such method: \"a\\b\"");
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings(
        "{\"error\":\"no such method: \\\"a\\\\b\\\"\"}",
        quoted,
    );
    // And the result stays parseable, which is the property that broke.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, quoted, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("no such method: \"a\\b\"", parsed.value.object.get("error").?.string);
}

test "result envelopes keep raw JSON and escape strings" {
    const gpa = std.testing.allocator;
    const raw = ok(gpa, "[1,2]");
    defer gpa.free(raw);
    try std.testing.expectEqualStrings("{\"result\":[1,2]}", raw);
    const str = okString(gpa, "he said \"hi\"");
    defer gpa.free(str);
    try std.testing.expectEqualStrings("{\"result\":\"he said \\\"hi\\\"\"}", str);
}
