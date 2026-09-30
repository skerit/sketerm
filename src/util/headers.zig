//! Lookup in an RFC 822-style header block (`Name: value` lines split by
//! CRLF), shared by the LSP base protocol (`lsp/rpc.zig`) and the HTTP
//! client (`agent/http.zig`), which had each grown the same loop.
//!
//! Pure std, no allocation: usable from every dependency set.

const std = @import("std");

/// The value of the first header named `name` (case-insensitive), trimmed
/// of spaces and tabs, or null. Lines without a colon (an HTTP status line)
/// are skipped.
pub fn value(block: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, block, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// Whether the comma-separated list in header `name` holds `token`
/// (case-insensitive): `Connection: keep-alive, Upgrade` holds `upgrade`.
pub fn hasToken(block: []const u8, name: []const u8, token: []const u8) bool {
    const v = value(block, name) orelse return false;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}

test "value is case-insensitive, trims, and skips the status line" {
    const t = std.testing;
    const block = "HTTP/1.1 200 OK\r\ncontent-TYPE:  text/event-stream \r\nContent-Length: 12";
    try t.expectEqualStrings("text/event-stream", value(block, "Content-Type").?);
    try t.expectEqualStrings("12", value(block, "content-length").?);
    try t.expect(value(block, "Transfer-Encoding") == null);
}

test "hasToken splits comma lists" {
    const t = std.testing;
    const block = "Transfer-Encoding: gzip, Chunked\r\nConnection: close";
    try t.expect(hasToken(block, "transfer-encoding", "chunked"));
    try t.expect(!hasToken(block, "transfer-encoding", "identity"));
    try t.expect(hasToken(block, "connection", "close"));
}
