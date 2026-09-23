//! The last few lines a language server wrote to stderr, kept so a
//! server that fails can say why on the status line.
//!
//! Fixed-size and allocation-free: the GUI feeds it from a local
//! server's stderr pipe, and the daemon feeds one per remote server
//! channel and ships `bytes()` with the channel's close, so it has to be
//! libc-only and cheap per chunk. A server that logs megabytes keeps only
//! the tail; a partial final line is kept until its newline arrives.

const std = @import("std");

/// Bytes of history kept. Enough for a few long lines (a clang error with
/// a path in it), small enough to ride one `chan_close` frame.
pub const CAPACITY: usize = 1024;

pub const Tail = struct {
    buf: [CAPACITY]u8 = undefined,
    len: usize = 0,

    /// Append a chunk, keeping only the newest `CAPACITY` bytes. A cut
    /// lands on a line boundary when the kept window has one, so the
    /// first kept line is never a fragment of a longer one.
    pub fn feed(self: *Tail, chunk: []const u8) void {
        if (chunk.len >= CAPACITY) {
            self.len = 0;
            self.append(chunk[chunk.len - CAPACITY ..]);
            self.trimToLine();
            return;
        }
        if (self.len + chunk.len > CAPACITY) {
            const drop = self.len + chunk.len - CAPACITY;
            std.mem.copyForwards(u8, self.buf[0 .. self.len - drop], self.buf[drop..self.len]);
            self.len -= drop;
            self.append(chunk);
            self.trimToLine();
            return;
        }
        self.append(chunk);
    }

    fn append(self: *Tail, data: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + data.len], data);
        self.len += data.len;
    }

    /// Drop a leading partial line left by a cut, when a later line
    /// exists to show instead.
    fn trimToLine(self: *Tail) void {
        const nl = std.mem.indexOfScalar(u8, self.buf[0..self.len], '\n') orelse return;
        if (nl + 1 >= self.len) return;
        std.mem.copyForwards(u8, self.buf[0 .. self.len - nl - 1], self.buf[nl + 1 .. self.len]);
        self.len -= nl + 1;
    }

    /// Everything kept, verbatim (what the daemon ships).
    pub fn bytes(self: *const Tail) []const u8 {
        return self.buf[0..self.len];
    }

    /// The last `n` non-blank lines, trimmed and joined with " | ", into
    /// `out`, for the status line.
    pub fn lastLines(self: *const Tail, n: usize, out: []u8) []const u8 {
        var starts: [16]usize = undefined;
        var ends: [16]usize = undefined;
        var found: usize = 0;
        const want = @min(n, starts.len);
        var end: usize = self.len;
        while (found < want and end > 0) {
            const start = if (std.mem.lastIndexOfScalar(u8, self.buf[0..end], '\n')) |nl| nl + 1 else 0;
            const line = std.mem.trim(u8, self.buf[start..end], " \t\r\n");
            if (line.len > 0) {
                const off = @intFromPtr(line.ptr) - @intFromPtr(&self.buf);
                starts[found] = off;
                ends[found] = off + line.len;
                found += 1;
            }
            if (start == 0) break;
            end = start - 1;
        }
        var w: usize = 0;
        var i = found;
        while (i > 0) {
            i -= 1;
            const line = self.buf[starts[i]..ends[i]];
            const sep: []const u8 = if (w == 0) "" else " | ";
            if (w + sep.len >= out.len) break;
            @memcpy(out[w .. w + sep.len], sep);
            w += sep.len;
            const take = @min(line.len, out.len - w);
            @memcpy(out[w .. w + take], line[0..take]);
            w += take;
        }
        return out[0..w];
    }
};

const testing = std.testing;

test "stderrtail: the last lines survive, joined for the status line" {
    var t = Tail{};
    t.feed("starting up\nindexing 12 files\n");
    t.feed("error: cannot open compile_commands.json\n\n");
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "indexing 12 files | error: cannot open compile_commands.json",
        t.lastLines(2, &out),
    );
    try testing.expectEqualStrings("error: cannot open compile_commands.json", t.lastLines(1, &out));
}

test "stderrtail: a flood keeps only the newest bytes, starting on a line" {
    var t = Tail{};
    var line_buf: [40]u8 = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const line = try std.fmt.bufPrint(&line_buf, "log line {d}\n", .{i});
        t.feed(line);
    }
    try testing.expect(t.bytes().len <= CAPACITY);
    try testing.expect(std.mem.startsWith(u8, t.bytes(), "log line "));
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("log line 499", t.lastLines(1, &out));
}

test "stderrtail: one chunk bigger than the window" {
    var t = Tail{};
    var big: [CAPACITY * 2]u8 = undefined;
    @memset(&big, 'x');
    big[big.len - 10] = '\n';
    t.feed(&big);
    try testing.expectEqual(@as(usize, 9), t.bytes().len);
}

test "stderrtail: a partial line waits for more" {
    var t = Tail{};
    t.feed("pan");
    t.feed("ic: boom\n");
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("panic: boom", t.lastLines(3, &out));
}
