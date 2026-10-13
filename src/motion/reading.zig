//! Reading material for the motion trainer's scrolling page: public-domain
//! stories (US) in `reading.txt`, so wheel bursts are recorded while
//! someone actually reads. Format: `# Title`, `by Author`, then one
//! paragraph per line with blank lines between them.

const std = @import("std");

const TEXT = @embedFile("reading.txt");

pub const Story = struct {
    title: []const u8,
    author: []const u8,
    body: []const u8,

    pub fn paragraphs(self: Story) std.mem.TokenIterator(u8, .sequence) {
        return std.mem.tokenizeSequence(u8, self.body, "\n\n");
    }
};

pub fn count() usize {
    var n: usize = 0;
    var it = chunks();
    while (it.next() != null) n += 1;
    return n;
}

/// Story `i` in file order, or null past the last.
pub fn get(i: usize) ?Story {
    var it = chunks();
    var k: usize = 0;
    while (it.next()) |chunk| : (k += 1) {
        if (k != i) continue;
        const title_end = std.mem.indexOfScalar(u8, chunk, '\n') orelse return .{ .title = chunk, .author = "", .body = "" };
        const rest = chunk[title_end + 1 ..];
        const by_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const by = rest[0..by_end];
        return .{
            .title = chunk[0..title_end],
            .author = if (std.mem.startsWith(u8, by, "by ")) by[3..] else by,
            .body = std.mem.trim(u8, rest[by_end..], "\n"),
        };
    }
    return null;
}

fn chunks() std.mem.SplitIterator(u8, .sequence) {
    return std.mem.splitSequence(u8, TEXT["# ".len..], "\n# ");
}

test "the embedded stories are titled, attributed, plain ASCII paragraphs" {
    const t = std.testing;
    try t.expect(std.mem.startsWith(u8, TEXT, "# "));
    try t.expect(TEXT.len > 100 << 10 and TEXT.len < 300 << 10);
    for (TEXT) |ch| try t.expect(ch == '\n' or (ch >= 0x20 and ch < 0x7f));
    try t.expect(std.ascii.indexOfIgnoreCase(TEXT, "gutenberg") == null);
    try t.expect(count() >= 5);
    try t.expect(get(count()) == null);
    for (0..count()) |i| {
        const s = get(i).?;
        try t.expect(s.title.len > 0 and s.author.len > 0);
        var n: usize = 0;
        var it = s.paragraphs();
        while (it.next()) |p| : (n += 1) try t.expect(std.mem.indexOfScalar(u8, p, '\n') == null);
        try t.expect(n >= 10);
    }
}
