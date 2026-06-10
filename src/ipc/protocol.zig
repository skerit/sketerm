//! Remote-control wire protocol: one JSON object per line, request
//! in, response out. Pure data + (de)serialization — no GTK, no
//! sockets — so it unit-tests headless.
//!
//! Requests: {"cmd":"send-text","pane":3,"data":"ls\n"}
//! Responses: {"ok":true,...} or {"ok":false,"error":"..."}

const std = @import("std");

/// Maximum accepted request line. Generous for send-text payloads,
/// small enough that a garbage client can't balloon memory.
pub const MAX_LINE = 1 << 20;

pub const Request = struct {
    cmd: []const u8 = "",
    /// Pane address. null = focused pane.
    pane: ?u32 = null,
    /// Tab address. null = selected tab.
    tab: ?u32 = null,
    /// send-text payload / set-title text.
    data: ?[]const u8 = null,
    /// send-text: wrap in bracketed-paste markers when the app
    /// enabled mode 2004 (mirrors interactive paste). Default raw.
    paste: bool = false,
    /// get-text: also include the last N scrollback lines. 0 = just
    /// the visible screen.
    scrollback: u32 = 0,
    /// split: "h" (side by side) or "v" (stacked).
    direction: ?[]const u8 = null,
    /// new-tab: working directory and title.
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub fn parseRequest(allocator: std.mem.Allocator, line: []const u8) !std.json.Parsed(Request) {
    if (line.len > MAX_LINE) return error.LineTooLong;
    return std.json.parseFromSlice(Request, allocator, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub const PaneInfo = struct {
    id: u32,
    title: []const u8,
    cwd: []const u8,
    pid: i32,
    rows: u16,
    cols: u16,
    focused: bool,
};

pub const TabInfo = struct {
    id: u32,
    title: []const u8,
    selected: bool,
    panes: []const PaneInfo,
};

/// Append a JSON response line (including trailing '\n') to `out`.
/// `payload` is any Stringify-able value merged in as a field.
pub fn writeOk(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime field: ?[]const u8, payload: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    if (field) |f| {
        try w.writeAll("{\"ok\":true,\"");
        try w.writeAll(f);
        try w.writeAll("\":");
        try std.json.Stringify.value(payload, .{}, w);
        try w.writeAll("}\n");
    } else {
        try w.writeAll("{\"ok\":true}\n");
    }
    try out.appendSlice(allocator, aw.written());
}

pub fn writeErr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, msg: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"ok\":false,\"error\":");
    try std.json.Stringify.value(msg, .{}, w);
    try w.writeAll("}\n");
    try out.appendSlice(allocator, aw.written());
}

test "parseRequest: minimal + addressed" {
    const a = std.testing.allocator;
    var p1 = try parseRequest(a, "{\"cmd\":\"list\"}");
    defer p1.deinit();
    try std.testing.expectEqualStrings("list", p1.value.cmd);
    try std.testing.expectEqual(@as(?u32, null), p1.value.pane);

    var p2 = try parseRequest(a, "{\"cmd\":\"send-text\",\"pane\":7,\"data\":\"ls\\n\",\"paste\":true}");
    defer p2.deinit();
    try std.testing.expectEqual(@as(?u32, 7), p2.value.pane);
    try std.testing.expectEqualStrings("ls\n", p2.value.data.?);
    try std.testing.expect(p2.value.paste);
}

test "parseRequest: unknown fields ignored, junk rejected" {
    const a = std.testing.allocator;
    var p = try parseRequest(a, "{\"cmd\":\"list\",\"future_field\":42}");
    defer p.deinit();
    try std.testing.expectEqualStrings("list", p.value.cmd);

    try std.testing.expectError(error.SyntaxError, parseRequest(a, "not json"));
}

test "writeOk / writeErr shapes" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    try writeOk(&out, a, null, {});
    try std.testing.expectEqualStrings("{\"ok\":true}\n", out.items);

    out.clearRetainingCapacity();
    try writeOk(&out, a, "text", "hi\n");
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"hi\\n\"}\n", out.items);

    out.clearRetainingCapacity();
    try writeErr(&out, a, "no such pane");
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":\"no such pane\"}\n", out.items);

    // Round-trip a TabInfo tree through Stringify.
    out.clearRetainingCapacity();
    const panes = [_]PaneInfo{.{ .id = 1, .title = "sh", .cwd = "/", .pid = 42, .rows = 24, .cols = 80, .focused = true }};
    const tabs = [_]TabInfo{.{ .id = 1, .title = "Tab", .selected = true, .panes = &panes }};
    try writeOk(&out, a, "tabs", tabs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"pid\":42") != null);
}
