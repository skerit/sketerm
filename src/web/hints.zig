//! Link-hint labels and the hints-payload parser for the web face.
//!
//! Pure std, GTK-free and engine-free: the payload format is produced
//! by `semantic.View.renderHints` in the helper and consumed by the
//! GUI overlay in `src/ui/webface.zig`; the labels are Vimium-style
//! shortest prefix-free strings over a home-row-first alphabet.

const std = @import("std");

/// Home-row-first label alphabet, same set the terminal quick-select
/// hints use (`src/ui/hints.zig`).
pub const ALPHABET = "asdfghjklqwertyuiopzxcvbnm";

/// Generate `n` prefix-free labels, shortest first: single characters
/// while they last, then the earliest label is traded for its
/// `alphabet.len` extensions until enough exist (the Vimium scheme).
/// Prefix-freedom is what lets typing a full label activate without an
/// Enter. Caller frees with `freeLabels`.
pub fn generateLabels(gpa: std.mem.Allocator, n: usize, alphabet: []const u8) ![][]u8 {
    std.debug.assert(alphabet.len >= 2);
    var pool: std.ArrayList([]u8) = .empty;
    errdefer {
        for (pool.items) |l| gpa.free(l);
        pool.deinit(gpa);
    }
    for (alphabet) |ch| {
        const l = try gpa.alloc(u8, 1);
        l[0] = ch;
        try pool.append(gpa, l);
    }
    // `head` walks forward instead of removing: everything before it
    // has been replaced by its extensions further down the list.
    var head: usize = 0;
    while (pool.items.len - head < n) {
        const parent = pool.items[head];
        head += 1;
        for (alphabet) |ch| {
            const l = try gpa.alloc(u8, parent.len + 1);
            @memcpy(l[0..parent.len], parent);
            l[parent.len] = ch;
            try pool.append(gpa, l);
        }
    }
    const out = try gpa.alloc([]u8, n);
    errdefer gpa.free(out);
    for (out, 0..) |*slot, i| slot.* = pool.items[head + i];
    // Consumed parents (before `head`) and the unused tail both go.
    for (pool.items[0..head]) |l| gpa.free(l);
    for (pool.items[head + n ..]) |l| gpa.free(l);
    pool.deinit(gpa);
    return out;
}

pub fn freeLabels(gpa: std.mem.Allocator, labels: [][]u8) void {
    for (labels) |l| gpa.free(l);
    gpa.free(labels);
}

/// One parsed hint. Slices borrow from the payload text handed to
/// `parse` — the caller keeps that buffer alive.
pub const Hint = struct {
    sid: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    role: []const u8,
    url: []const u8,
    name: []const u8,
};

/// Parse a `renderHints` payload ("hints <n> vw <w> vh <h>" header
/// plus TSV lines). Null when the text is not a hints payload at all
/// (an old helper answered the query kind as a text search). Malformed
/// lines are skipped rather than failing the batch. Caller frees the
/// returned slice; hint strings borrow from `text`.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !?[]Hint {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, header, "hints ")) return null;
    var out: std.ArrayList(Hint) = .empty;
    errdefer out.deinit(gpa);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const sid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const x = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
        const y = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
        const w = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
        const h = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
        const role = f.next() orelse continue;
        const url = f.next() orelse continue;
        const name = f.next() orelse "";
        try out.append(gpa, .{ .sid = sid, .x = x, .y = y, .w = w, .h = h, .role = role, .url = url, .name = name });
    }
    return try out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "few hints get single-character home-row labels" {
    const gpa = std.testing.allocator;
    const labels = try generateLabels(gpa, 5, ALPHABET);
    defer freeLabels(gpa, labels);
    try std.testing.expectEqual(@as(usize, 5), labels.len);
    try std.testing.expectEqualStrings("a", labels[0]);
    try std.testing.expectEqualStrings("s", labels[1]);
    try std.testing.expectEqualStrings("g", labels[4]);
}

test "many labels stay unique, prefix-free and as short as possible" {
    const gpa = std.testing.allocator;
    const n = 80;
    const labels = try generateLabels(gpa, n, ALPHABET);
    defer freeLabels(gpa, labels);
    try std.testing.expectEqual(@as(usize, n), labels.len);
    for (labels, 0..) |a, i| {
        try std.testing.expect(a.len <= 2); // 26 + expansions cover 80 within 2 chars
        for (labels[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
            try std.testing.expect(!std.mem.startsWith(u8, b, a));
            try std.testing.expect(!std.mem.startsWith(u8, a, b));
        }
    }
    // Shortest first: the remaining singles precede every double.
    try std.testing.expectEqual(@as(usize, 1), labels[0].len);
    var seen_double = false;
    for (labels) |l| {
        if (l.len == 2) seen_double = true else try std.testing.expect(!seen_double);
    }
}

test "a tiny alphabet still labels a page full of hints" {
    const gpa = std.testing.allocator;
    const labels = try generateLabels(gpa, 30, "ab");
    defer freeLabels(gpa, labels);
    try std.testing.expectEqual(@as(usize, 30), labels.len);
    for (labels, 0..) |a, i| {
        for (labels[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.startsWith(u8, b, a));
        }
    }
}

test "parse reads the renderHints format and skips junk lines" {
    const gpa = std.testing.allocator;
    const payload =
        "hints 2 vw 800 vh 600\n" ++
        "4\t10\t20\t60\t16\tlink\thttps://x/docs\tDocs\n" ++
        "not a hint line\n" ++
        "9\t10\t40\t40\t20\tbutton\t\tGo\n";
    const hints = (try parse(gpa, payload)).?;
    defer gpa.free(hints);
    try std.testing.expectEqual(@as(usize, 2), hints.len);
    try std.testing.expectEqual(@as(u32, 4), hints[0].sid);
    try std.testing.expectEqualStrings("https://x/docs", hints[0].url);
    try std.testing.expectEqualStrings("Docs", hints[0].name);
    try std.testing.expectEqual(@as(i32, 40), hints[1].y);
    try std.testing.expectEqualStrings("button", hints[1].role);
    try std.testing.expectEqualStrings("", hints[1].url);
}

test "parse refuses a non-hints payload" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]Hint, null), try parse(gpa, "query find \"800 600\" 0 matches\n"));
}
