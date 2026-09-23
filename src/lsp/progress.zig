//! Work-done progress a server reports (`$/progress` with begin /
//! report / end), reduced to the one line the editor's status bar shows:
//! "Indexing 45% (12/27 files)". GTK-free, in both test roots.
//!
//! Tokens are kept as their JSON text (a server may use a number or a
//! string), and only the NEWEST active entry is shown: servers run
//! several at once (clangd indexes while it parses) and a status line
//! that cycles through them is unreadable.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MAX_ACTIVE: usize = 8;

pub const Entry = struct {
    token: [64]u8 = undefined,
    token_len: usize = 0,
    title: [80]u8 = undefined,
    title_len: usize = 0,
    message: [120]u8 = undefined,
    message_len: usize = 0,
    percentage: ?u32 = null,

    fn tokenText(self: *const Entry) []const u8 {
        return self.token[0..self.token_len];
    }
};

pub const Table = struct {
    entries: [MAX_ACTIVE]Entry = undefined,
    len: usize = 0,

    pub fn clear(self: *Table) void {
        self.len = 0;
    }

    pub fn isEmpty(self: *const Table) bool {
        return self.len == 0;
    }

    /// Fold one `$/progress` params object in. @return whether what the
    /// status line shows may have changed.
    pub fn absorb(self: *Table, params: std.json.Value) bool {
        if (params != .object) return false;
        const o = params.object;
        var tok_buf: [64]u8 = undefined;
        const token = tokenOf(o.get("token") orelse return false, &tok_buf) orelse return false;
        const value = o.get("value") orelse return false;
        if (value != .object) return false;
        const v = value.object;
        const kind = strOf(v.get("kind")) orelse return false;
        if (std.mem.eql(u8, kind, "end")) {
            const i = self.find(token) orelse return false;
            self.entries[i] = self.entries[self.len - 1];
            self.len -= 1;
            return true;
        }
        const idx = self.find(token) orelse blk: {
            if (!std.mem.eql(u8, kind, "begin")) return false;
            if (self.len == MAX_ACTIVE) {
                // The oldest one gives way; it is the least likely to
                // still be what the user wants to read.
                std.mem.copyForwards(Entry, self.entries[0 .. MAX_ACTIVE - 1], self.entries[1..MAX_ACTIVE]);
                self.len -= 1;
            }
            self.entries[self.len] = .{};
            copyInto(&self.entries[self.len].token, &self.entries[self.len].token_len, token);
            self.len += 1;
            break :blk self.len - 1;
        };
        const e = &self.entries[idx];
        if (strOf(v.get("title"))) |t| copyInto(&e.title, &e.title_len, t);
        if (strOf(v.get("message"))) |m| copyInto(&e.message, &e.message_len, m);
        if (v.get("percentage")) |p| {
            switch (p) {
                .integer => |n| e.percentage = @intCast(std.math.clamp(n, 0, 100)),
                .float => |f| e.percentage = @intFromFloat(std.math.clamp(f, 0, 100)),
                else => {},
            }
        }
        return true;
    }

    fn find(self: *const Table, token: []const u8) ?usize {
        for (self.entries[0..self.len], 0..) |*e, i| {
            if (std.mem.eql(u8, e.tokenText(), token)) return i;
        }
        return null;
    }

    /// "Title 45% message" for the newest active entry, or "" when idle.
    pub fn summary(self: *const Table, out: []u8) []const u8 {
        if (self.len == 0) return "";
        const e = &self.entries[self.len - 1];
        var w: std.Io.Writer = .fixed(out);
        w.writeAll(e.title[0..e.title_len]) catch {};
        if (e.percentage) |p| w.print("{s}{d}%", .{ if (w.end > 0) " " else "", p }) catch {};
        if (e.message_len > 0) w.print("{s}{s}", .{ if (w.end > 0) " " else "", e.message[0..e.message_len] }) catch {};
        return out[0..w.end];
    }
};

fn copyInto(dst: anytype, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// A progress token as text: strings verbatim, integers in decimal.
fn tokenOf(v: std.json.Value, buf: []u8) ?[]const u8 {
    return switch (v) {
        .string => |s| s[0..@min(s.len, buf.len)],
        .integer => |n| std.fmt.bufPrint(buf, "#{d}", .{n}) catch null,
        else => null,
    };
}

const testing = std.testing;

fn feedJson(t: *Table, text: []const u8) !bool {
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer p.deinit();
    return t.absorb(p.value);
}

test "progress: begin, report and end drive one status line" {
    var t = Table{};
    var out: [200]u8 = undefined;
    try testing.expectEqualStrings("", t.summary(&out));
    try testing.expect(try feedJson(&t, "{\"token\":\"idx\",\"value\":{\"kind\":\"begin\",\"title\":\"Indexing\",\"percentage\":0}}"));
    try testing.expectEqualStrings("Indexing 0%", t.summary(&out));
    try testing.expect(try feedJson(&t, "{\"token\":\"idx\",\"value\":{\"kind\":\"report\",\"message\":\"12/27 files\",\"percentage\":45}}"));
    try testing.expectEqualStrings("Indexing 45% 12/27 files", t.summary(&out));
    try testing.expect(try feedJson(&t, "{\"token\":\"idx\",\"value\":{\"kind\":\"end\"}}"));
    try testing.expectEqualStrings("", t.summary(&out));
}

test "progress: numeric tokens, the newest entry wins, unknown reports are ignored" {
    var t = Table{};
    var out: [200]u8 = undefined;
    try testing.expect(try feedJson(&t, "{\"token\":7,\"value\":{\"kind\":\"begin\",\"title\":\"Parsing\"}}"));
    try testing.expect(try feedJson(&t, "{\"token\":\"b\",\"value\":{\"kind\":\"begin\",\"title\":\"Building\"}}"));
    try testing.expectEqualStrings("Building", t.summary(&out));
    // A report for a token that never began changes nothing.
    try testing.expect(!try feedJson(&t, "{\"token\":\"zz\",\"value\":{\"kind\":\"report\",\"message\":\"x\"}}"));
    try testing.expect(try feedJson(&t, "{\"token\":\"b\",\"value\":{\"kind\":\"end\"}}"));
    try testing.expectEqualStrings("Parsing", t.summary(&out));
    try testing.expect(try feedJson(&t, "{\"token\":7,\"value\":{\"kind\":\"end\"}}"));
    try testing.expect(t.isEmpty());
}
