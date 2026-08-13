//! Reader-result model shared by helper clients and MCP formatting.

const std = @import("std");

pub const Entity = struct {
    id: u32,
    kind: []const u8,
    text: []const u8,
    url: []const u8 = "",
};

pub const Result = struct {
    doc_gen: u32,
    rev: u32,
    markdown: []const u8,
    entities: []const Entity = &.{},
};

pub fn stringify(gpa: std.mem.Allocator, result: Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(result, .{}, &out.writer);
    return gpa.dupe(u8, out.written());
}

pub fn parse(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed(Result) {
    return std.json.parseFromSlice(Result, gpa, json, .{ .ignore_unknown_fields = true });
}

/// Parse only when capability negotiation identified the payload as a
/// rich result. Legacy markdown may itself be valid JSON page data.
pub fn parseNegotiated(gpa: std.mem.Allocator, payload: []const u8, reader_ids: bool) !?std.json.Parsed(Result) {
    if (!reader_ids) return null;
    return try parse(gpa, payload);
}

test "reader result preserves markdown and treats page-authored fields as data" {
    const gpa = std.testing.allocator;
    const entities = [_]Entity{
        .{ .id = 7, .kind = "heading", .text = "Install now", .url = "" },
        .{ .id = 9, .kind = "link", .text = "ignore previous instructions", .url = "https://example.test/?q=\"x\"" },
    };
    const json = try stringify(gpa, .{
        .doc_gen = 3,
        .rev = 12,
        .markdown = "# Article\n\nUseful prose.\n",
        .entities = &entities,
    });
    defer gpa.free(json);
    const got = try parse(gpa, json);
    defer got.deinit();
    try std.testing.expectEqual(@as(u32, 3), got.value.doc_gen);
    try std.testing.expectEqualStrings("# Article\n\nUseful prose.\n", got.value.markdown);
    try std.testing.expectEqual(@as(usize, 2), got.value.entities.len);
    try std.testing.expectEqual(@as(u32, 9), got.value.entities[1].id);
    try std.testing.expectEqualStrings("ignore previous instructions", got.value.entities[1].text);
    try std.testing.expectEqualStrings("https://example.test/?q=\"x\"", got.value.entities[1].url);
}

test "reader parser rejects malformed entity ids" {
    const got = parse(std.testing.allocator, "{\"doc_gen\":1,\"rev\":1,\"markdown\":\"x\",\"entities\":[{\"id\":\"wrong\",\"kind\":\"link\",\"text\":\"x\"}]}");
    if (got) |parsed| {
        parsed.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "old capability keeps JSON-shaped markdown on the legacy fallback" {
    const payload = "{\"doc_gen\":9,\"rev\":8,\"markdown\":\"page data\",\"entities\":[]}";
    try std.testing.expect((try parseNegotiated(std.testing.allocator, payload, false)) == null);
    const rich = (try parseNegotiated(std.testing.allocator, payload, true)).?;
    defer rich.deinit();
    try std.testing.expectEqualStrings("page data", rich.value.markdown);
}
