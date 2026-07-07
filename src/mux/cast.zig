//! Asciicast v2 writer (the asciinema file format) — records a
//! session's raw PTY output with timestamps, daemon-side, so any
//! session can be recorded live with no wrapper process around the
//! shell. One JSON header line, then one `[t, "o"|"r", data]` event
//! line per output chunk / resize. musl-clean (libc FILE only).

const std = @import("std");
const c = @import("../c.zig").c;

/// JSON-escape arbitrary PTY bytes into `out`. Valid UTF-8 passes
/// through (with the usual `"`, `\`, control escapes); invalid bytes
/// become U+FFFD so the file stays valid JSON no matter what the
/// child wrote.
pub fn escapeBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b < 0x20) {
            switch (b) {
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                0x08 => try out.appendSlice(allocator, "\\b"),
                0x0c => try out.appendSlice(allocator, "\\f"),
                else => {
                    var buf: [6]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{b}) catch unreachable;
                    try out.appendSlice(allocator, s);
                },
            }
            i += 1;
        } else if (b == '"') {
            try out.appendSlice(allocator, "\\\"");
            i += 1;
        } else if (b == '\\') {
            try out.appendSlice(allocator, "\\\\");
            i += 1;
        } else if (b < 0x80) {
            try out.append(allocator, b);
            i += 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(b) catch {
                try out.appendSlice(allocator, "\u{fffd}");
                i += 1;
                continue;
            };
            if (i + len > bytes.len) {
                // Truncated tail (chunk split mid-sequence would have
                // been healed by the caller's carry; a real truncation
                // is invalid input).
                try out.appendSlice(allocator, "\u{fffd}");
                i += 1;
                continue;
            }
            if (std.unicode.utf8Decode(bytes[i .. i + len])) |_| {
                try out.appendSlice(allocator, bytes[i .. i + len]);
                i += len;
            } else |_| {
                try out.appendSlice(allocator, "\u{fffd}");
                i += 1;
            }
        }
    }
}

/// Format one event line `[1.234567, "o", "..."]\n` into `out`.
pub fn appendEvent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    t_ms: i64,
    code: u8,
    data: []const u8,
) !void {
    const secs = @as(f64, @floatFromInt(@max(t_ms, 0))) / 1000.0;
    var head: [48]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "[{d:.6}, \"{c}\", \"", .{ secs, code }) catch unreachable;
    try out.appendSlice(allocator, h);
    try escapeBytes(allocator, out, data);
    try out.appendSlice(allocator, "\"]\n");
}

pub const Rec = struct {
    allocator: std.mem.Allocator,
    file: *c.FILE,
    /// Monotonic-ms base; event times are relative to it.
    start_ms: i64,
    /// UTF-8 continuation bytes split across PTY read chunks are
    /// carried here so multi-byte characters never straddle events.
    carry: [4]u8 = undefined,
    carry_len: usize = 0,

    /// Open `path` (truncating) and write the asciicast v2 header.
    pub fn start(
        allocator: std.mem.Allocator,
        path: []const u8,
        cols: u16,
        rows: u16,
        title: []const u8,
        now_ms: i64,
    ) !Rec {
        var z_buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintZ(&z_buf, "{s}", .{path}) catch return error.BadPath;
        const f = c.fopen(z.ptr, "w") orelse return error.OpenFailed;
        errdefer _ = c.fclose(f);

        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(allocator);
        var head: [128]u8 = undefined;
        const h = std.fmt.bufPrint(
            &head,
            "{{\"version\": 2, \"width\": {d}, \"height\": {d}, \"timestamp\": {d}, \"title\": \"",
            .{ cols, rows, c.time(null) },
        ) catch return error.BadPath;
        try hdr.appendSlice(allocator, h);
        try escapeBytes(allocator, &hdr, title);
        try hdr.appendSlice(allocator, "\"}\n");
        if (c.fwrite(hdr.items.ptr, 1, hdr.items.len, f) != hdr.items.len) return error.WriteFailed;
        _ = c.fflush(f);
        return .{ .allocator = allocator, .file = f, .start_ms = now_ms };
    }

    /// Record one chunk of raw PTY output.
    pub fn output(self: *Rec, now_ms: i64, bytes: []const u8) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        // Re-assemble a leading fragment from the previous chunk, and
        // hold back a trailing incomplete UTF-8 sequence for the next.
        var work: std.ArrayList(u8) = .empty;
        defer work.deinit(self.allocator);
        if (self.carry_len > 0) {
            work.appendSlice(self.allocator, self.carry[0..self.carry_len]) catch return;
            self.carry_len = 0;
        }
        work.appendSlice(self.allocator, bytes) catch return;
        var emit: []const u8 = work.items;
        const tail = incompleteTail(emit);
        if (tail > 0 and tail <= 4) {
            @memcpy(self.carry[0..tail], emit[emit.len - tail ..]);
            self.carry_len = tail;
            emit = emit[0 .. emit.len - tail];
        }
        if (emit.len == 0) return;

        appendEvent(self.allocator, &buf, now_ms - self.start_ms, 'o', emit) catch return;
        _ = c.fwrite(buf.items.ptr, 1, buf.items.len, self.file);
        _ = c.fflush(self.file);
    }

    /// Record a terminal resize.
    pub fn resize(self: *Rec, now_ms: i64, cols: u16, rows: u16) void {
        var data: [16]u8 = undefined;
        const d = std.fmt.bufPrint(&data, "{d}x{d}", .{ cols, rows }) catch return;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        appendEvent(self.allocator, &buf, now_ms - self.start_ms, 'r', d) catch return;
        _ = c.fwrite(buf.items.ptr, 1, buf.items.len, self.file);
        _ = c.fflush(self.file);
    }

    pub fn finish(self: *Rec) void {
        if (self.carry_len > 0) self.carry_len = 0; // drop a dangling fragment
        _ = c.fclose(self.file);
    }
};

/// Length of an incomplete UTF-8 sequence at the very end of `bytes`
/// (0 when the buffer ends on a complete character or ASCII).
fn incompleteTail(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var back: usize = 1;
    while (back <= 4 and back <= bytes.len) : (back += 1) {
        const b = bytes[bytes.len - back];
        if (b < 0x80) return 0; // ASCII: complete
        if (b >= 0xc0) {
            // Lead byte: incomplete if the sequence needs more bytes
            // than are present after it.
            const need = std.unicode.utf8ByteSequenceLength(b) catch return 0;
            return if (need > back) back else 0;
        }
        // 0x80..0xBF continuation byte: keep walking back.
    }
    return 0;
}

test "escapeBytes: controls, quotes, utf-8, invalid" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try escapeBytes(a, &out, "hi\x1b[1m\"q\\\" \xc3\xa9 \xff!");
    try std.testing.expectEqualStrings("hi\\u001b[1m\\\"q\\\\\\\" \xc3\xa9 \u{fffd}!", out.items);
}

test "appendEvent formats an asciicast line" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendEvent(a, &out, 1234, 'o', "x\n");
    try std.testing.expectEqualStrings("[1.234000, \"o\", \"x\\n\"]\n", out.items);
}

test "incompleteTail detects split sequences" {
    try std.testing.expectEqual(@as(usize, 0), incompleteTail("abc"));
    try std.testing.expectEqual(@as(usize, 0), incompleteTail("ab\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 1), incompleteTail("ab\xc3"));
    try std.testing.expectEqual(@as(usize, 2), incompleteTail("a\xe2\x82")); // euro sign minus last byte
    try std.testing.expectEqual(@as(usize, 0), incompleteTail("\xff")); // invalid lead: emit as-is
}
