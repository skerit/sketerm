//! Balanced rope over UTF-8 bytes with per-node byte/newline/character
//! aggregates.
//!
//! AVL-balanced binary tree of fixed-capacity leaves (MAX_LEAF bytes).
//! All edits are expressed as split/join, which keeps the height
//! invariant provable and the code small: insert = split + build + join,
//! delete = two splits + free + join. Every operation is O(log n) in
//! leaf count. The rope is strictly byte-oriented; CRLF and grapheme
//! concerns live in higher layers (document.zig, unicode.zig).
//!
//! Slices handed out by `RangeIter` point into leaf storage and are
//! invalidated by ANY subsequent mutation of the rope.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum payload of one leaf node.
pub const MAX_LEAF: usize = 2048;

pub const Rope = struct {
    alloc: Allocator,
    root: ?*Node,

    pub const LineCol = struct {
        /// 0-based line index.
        line: usize,
        /// Byte offset from the start of the line.
        col: usize,
    };

    const Node = struct {
        bytes: usize,
        newlines: usize,
        /// Non-continuation bytes, i.e. codepoints when the content is
        /// valid UTF-8. Counted per byte, so splitting a sequence
        /// across nodes still totals correctly: the lead byte is
        /// counted wherever it lands and continuations never are.
        chars: usize,
        height: u16,
        kind: Kind,

        const Kind = union(enum) {
            leaf: LeafData,
            inner: InnerData,
        };
        const LeafData = struct {
            /// Always MAX_LEAF capacity.
            data: [*]u8,
            len: u32,
        };
        const InnerData = struct {
            left: *Node,
            right: *Node,
        };
    };

    pub fn init(alloc: Allocator) Rope {
        return .{ .alloc = alloc, .root = null };
    }

    /// Builds a rope from `bytes` in O(n) with a perfectly balanced tree.
    pub fn initFromBytes(alloc: Allocator, bytes: []const u8) !Rope {
        var r = Rope.init(alloc);
        errdefer r.deinit();
        r.root = try r.buildBalanced(bytes);
        return r;
    }

    pub fn deinit(self: *Rope) void {
        if (self.root) |n| self.freeTree(n);
        self.root = null;
    }

    pub fn len(self: *const Rope) usize {
        return if (self.root) |n| n.bytes else 0;
    }

    /// Total '\n' bytes in the rope.
    pub fn newlineCount(self: *const Rope) usize {
        return if (self.root) |n| n.newlines else 0;
    }

    /// Number of lines; an empty rope has one (empty) line.
    pub fn lineCount(self: *const Rope) usize {
        return self.newlineCount() + 1;
    }

    /// Total non-continuation bytes (codepoints for valid UTF-8). O(1).
    pub fn charCount(self: *const Rope) usize {
        return if (self.root) |n| n.chars else 0;
    }

    // ---- node helpers -------------------------------------------------

    fn newLeaf(self: *Rope, content: []const u8) !*Node {
        std.debug.assert(content.len <= MAX_LEAF);
        const node = try self.alloc.create(Node);
        errdefer self.alloc.destroy(node);
        const buf = try self.alloc.alloc(u8, MAX_LEAF);
        @memcpy(buf[0..content.len], content);
        node.* = .{
            .bytes = content.len,
            .newlines = countNewlines(content),
            .chars = countChars(content),
            .height = 1,
            .kind = .{ .leaf = .{ .data = buf.ptr, .len = @intCast(content.len) } },
        };
        return node;
    }

    fn newInner(self: *Rope, left: *Node, right: *Node) !*Node {
        const node = try self.alloc.create(Node);
        node.* = .{
            .bytes = 0,
            .newlines = 0,
            .chars = 0,
            .height = 0,
            .kind = .{ .inner = .{ .left = left, .right = right } },
        };
        recompute(node);
        return node;
    }

    fn freeNode(self: *Rope, node: *Node) void {
        switch (node.kind) {
            .leaf => |l| self.alloc.free(@as([]u8, l.data[0..MAX_LEAF])),
            .inner => {},
        }
        self.alloc.destroy(node);
    }

    fn freeTree(self: *Rope, node: *Node) void {
        switch (node.kind) {
            .leaf => {},
            .inner => |in| {
                self.freeTree(in.left);
                self.freeTree(in.right);
            },
        }
        self.freeNode(node);
    }

    fn leafSlice(node: *const Node) []const u8 {
        const l = node.kind.leaf;
        return l.data[0..l.len];
    }

    fn recompute(node: *Node) void {
        const in = node.kind.inner;
        node.bytes = in.left.bytes + in.right.bytes;
        node.newlines = in.left.newlines + in.right.newlines;
        node.chars = in.left.chars + in.right.chars;
        node.height = 1 + @max(in.left.height, in.right.height);
    }

    fn countNewlines(bytes: []const u8) usize {
        var n: usize = 0;
        for (bytes) |b| {
            if (b == '\n') n += 1;
        }
        return n;
    }

    fn isCont(b: u8) bool {
        return (b & 0xC0) == 0x80;
    }

    /// Non-continuation bytes in `bytes`.
    pub fn countChars(bytes: []const u8) usize {
        var n: usize = 0;
        for (bytes) |b| {
            if (!isCont(b)) n += 1;
        }
        return n;
    }

    // ---- balancing ----------------------------------------------------

    fn rotateRight(node: *Node) *Node {
        const l = node.kind.inner.left;
        node.kind.inner.left = l.kind.inner.right;
        recompute(node);
        l.kind.inner.right = node;
        recompute(l);
        return l;
    }

    fn rotateLeft(node: *Node) *Node {
        const r = node.kind.inner.right;
        node.kind.inner.right = r.kind.inner.left;
        recompute(node);
        r.kind.inner.left = node;
        recompute(r);
        return r;
    }

    /// Restores the AVL invariant at `node` assuming its balance factor
    /// is at most 2 in magnitude (guaranteed by the join recursion).
    fn rebalance(node: *Node) *Node {
        const in = node.kind.inner;
        const hl: i32 = in.left.height;
        const hr: i32 = in.right.height;
        if (hl - hr > 1) {
            const l = in.left;
            const lin = l.kind.inner;
            if (lin.right.height > lin.left.height) {
                node.kind.inner.left = rotateLeft(l);
            }
            return rotateRight(node);
        } else if (hr - hl > 1) {
            const r = in.right;
            const rin = r.kind.inner;
            if (rin.left.height > rin.right.height) {
                node.kind.inner.right = rotateRight(r);
            }
            return rotateLeft(node);
        }
        recompute(node);
        return node;
    }

    /// AVL join of two subtrees preserving order (all of `l` before `r`).
    fn joinNodes(self: *Rope, l: *Node, r: *Node) Allocator.Error!*Node {
        const hl: i32 = l.height;
        const hr: i32 = r.height;
        if (@abs(hl - hr) <= 1) return self.newInner(l, r);
        if (hl > hr) {
            l.kind.inner.right = try self.joinNodes(l.kind.inner.right, r);
            return rebalance(l);
        } else {
            r.kind.inner.left = try self.joinNodes(l, r.kind.inner.left);
            return rebalance(r);
        }
    }

    fn join(self: *Rope, l: ?*Node, r: ?*Node) Allocator.Error!?*Node {
        if (l == null) return r;
        if (r == null) return l;
        return try self.joinNodes(l.?, r.?);
    }

    fn leftmostLeaf(node: *Node) *Node {
        var n = node;
        while (true) switch (n.kind) {
            .leaf => return n,
            .inner => |in| n = in.left,
        };
    }

    fn rightmostLeaf(node: *Node) *Node {
        var n = node;
        while (true) switch (n.kind) {
            .leaf => return n,
            .inner => |in| n = in.right,
        };
    }

    /// Appends `text` to the rightmost leaf, fixing aggregates down the
    /// right spine. Caller guarantees the leaf has capacity.
    fn appendToRightmost(node: *Node, text: []const u8) void {
        const added_nl = countNewlines(text);
        const added_ch = countChars(text);
        var n = node;
        while (true) {
            n.bytes += text.len;
            n.newlines += added_nl;
            n.chars += added_ch;
            switch (n.kind) {
                .leaf => |l| {
                    std.debug.assert(@as(usize, l.len) + text.len <= MAX_LEAF);
                    @memcpy(l.data[l.len .. l.len + text.len], text);
                    n.kind.leaf.len = @intCast(@as(usize, l.len) + text.len);
                    return;
                },
                .inner => |in| n = in.right,
            }
        }
    }

    /// `join`, additionally fusing the two leaves that meet at the seam
    /// when they fit in one.
    ///
    /// Without this, every edit that cuts a leaf leaves the two halves
    /// behind forever: a session of scattered single-byte deletes grows
    /// one leaf per edit and the tree's leaf storage (MAX_LEAF per leaf
    /// regardless of fill) drifts toward 2048x the document size. Only
    /// the SEAM needs checking — that is the one place an edit can
    /// create undersized neighbours.
    fn joinCompact(self: *Rope, l: ?*Node, r: ?*Node) Allocator.Error!?*Node {
        const ln = l orelse return r;
        const rn = r orelse return l;
        const last = rightmostLeaf(ln);
        const first = leftmostLeaf(rn);
        const donor_len: usize = first.kind.leaf.len;
        if (@as(usize, last.kind.leaf.len) + donor_len <= MAX_LEAF) {
            // Splitting at the first leaf's own length is a split on a
            // leaf boundary, so `s.left` IS that leaf, unsplit.
            const s = try self.split(rn, donor_len);
            const donor = s.left.?;
            appendToRightmost(ln, leafSlice(donor));
            self.freeNode(donor);
            return try self.join(ln, s.right);
        }
        return try self.joinNodes(ln, rn);
    }

    const SplitResult = struct { left: ?*Node, right: ?*Node };

    /// Splits `node` at byte position `k` (0 <= k <= node.bytes),
    /// consuming it. Inner shells along the path are freed and rebuilt
    /// by joins, so both results are valid AVL trees.
    fn split(self: *Rope, node: *Node, k: usize) Allocator.Error!SplitResult {
        std.debug.assert(k <= node.bytes);
        switch (node.kind) {
            .leaf => {
                if (k == 0) return .{ .left = null, .right = node };
                if (k == node.bytes) return .{ .left = node, .right = null };
                const content = leafSlice(node);
                const right = try self.newLeaf(content[k..]);
                // Shrink the existing leaf in place.
                node.kind.leaf.len = @intCast(k);
                node.bytes = k;
                node.newlines = countNewlines(content[0..k]);
                node.chars = countChars(content[0..k]);
                return .{ .left = node, .right = right };
            },
            .inner => |in| {
                const left = in.left;
                const right = in.right;
                self.alloc.destroy(node);
                if (k <= left.bytes) {
                    const s = try self.split(left, k);
                    const new_right = try self.join(s.right, right);
                    return .{ .left = s.left, .right = new_right };
                } else {
                    const s = try self.split(right, k - left.bytes);
                    const new_left = try self.join(left, s.left);
                    return .{ .left = new_left, .right = s.right };
                }
            },
        }
    }

    /// Builds a balanced subtree from raw bytes; null for empty input.
    fn buildBalanced(self: *Rope, bytes: []const u8) Allocator.Error!?*Node {
        if (bytes.len == 0) return null;
        if (bytes.len <= MAX_LEAF) return try self.newLeaf(bytes);
        // Split into the minimal number of chunks, sized as evenly as
        // possible so no leaf is pathologically small.
        const nchunks = (bytes.len + MAX_LEAF - 1) / MAX_LEAF;
        const half_chunks = nchunks / 2;
        const mid = half_chunks * (bytes.len / nchunks);
        const l = try self.buildBalanced(bytes[0..mid]);
        errdefer if (l) |n| self.freeTree(n);
        const r = try self.buildBalanced(bytes[mid..]);
        errdefer if (r) |n| self.freeTree(n);
        return try self.join(l, r);
    }

    // ---- edits --------------------------------------------------------

    /// Inserts `text` at byte `offset` (0 <= offset <= len).
    pub fn insert(self: *Rope, offset: usize, text: []const u8) Allocator.Error!void {
        std.debug.assert(offset <= self.len());
        if (text.len == 0) return;
        if (self.root == null) {
            self.root = try self.buildBalanced(text);
            return;
        }
        // Fast path: the edit lands inside a single leaf with room.
        if (self.insertIntoLeaf(offset, text)) return;
        const root = self.root.?;
        self.root = null;
        const s = try self.split(root, offset);
        const mid = try self.buildBalanced(text);
        const lm = try self.joinCompact(s.left, mid);
        self.root = try self.joinCompact(lm, s.right);
    }

    /// In-place leaf insertion when the target leaf has capacity.
    /// Returns false when the general split/join path is needed.
    fn insertIntoLeaf(self: *Rope, offset: usize, text: []const u8) bool {
        if (text.len > MAX_LEAF) return false;
        var node = self.root orelse return false;
        var off = offset;
        // Descend, remembering the path to fix aggregates afterward.
        var path_buf: [64]*Node = undefined;
        var depth: usize = 0;
        while (true) {
            switch (node.kind) {
                .leaf => |l| {
                    if (@as(usize, l.len) + text.len > MAX_LEAF) return false;
                    const buf = l.data[0..MAX_LEAF];
                    std.mem.copyBackwards(u8, buf[off + text.len .. l.len + text.len], buf[off..l.len]);
                    @memcpy(buf[off .. off + text.len], text);
                    node.kind.leaf.len = @intCast(@as(usize, l.len) + text.len);
                    const added_nl = countNewlines(text);
                    const added_ch = countChars(text);
                    node.bytes += text.len;
                    node.newlines += added_nl;
                    node.chars += added_ch;
                    for (path_buf[0..depth]) |p| {
                        p.bytes += text.len;
                        p.newlines += added_nl;
                        p.chars += added_ch;
                    }
                    return true;
                },
                .inner => |in| {
                    if (depth == path_buf.len) return false;
                    path_buf[depth] = node;
                    depth += 1;
                    if (off <= in.left.bytes) {
                        node = in.left;
                    } else {
                        off -= in.left.bytes;
                        node = in.right;
                    }
                },
            }
        }
    }

    /// Deletes bytes in [start, end).
    pub fn delete(self: *Rope, start: usize, end: usize) Allocator.Error!void {
        std.debug.assert(start <= end and end <= self.len());
        if (start == end) return;
        const root = self.root.?;
        self.root = null;
        const s1 = try self.split(root, start);
        const s2 = try self.split(s1.right.?, end - start);
        if (s2.left) |mid| self.freeTree(mid);
        self.root = try self.joinCompact(s1.left, s2.right);
    }

    // ---- queries ------------------------------------------------------

    /// Number of '\n' bytes in [0, offset) — i.e. the 0-based line the
    /// offset sits on.
    pub fn newlinesBefore(self: *const Rope, offset: usize) usize {
        std.debug.assert(offset <= self.len());
        var node = self.root orelse return 0;
        var k = offset;
        var acc: usize = 0;
        while (true) {
            if (k >= node.bytes) return acc + node.newlines;
            switch (node.kind) {
                .leaf => return acc + countNewlines(leafSlice(node)[0..k]),
                .inner => |in| {
                    if (k <= in.left.bytes) {
                        node = in.left;
                    } else {
                        acc += in.left.newlines;
                        k -= in.left.bytes;
                        node = in.right;
                    }
                },
            }
        }
    }

    /// Byte offset where 0-based `line` starts. `line` must be < lineCount().
    pub fn lineToOffset(self: *const Rope, line: usize) usize {
        std.debug.assert(line < self.lineCount());
        if (line == 0) return 0;
        // Offset just past newline number `line` (1-based).
        var node = self.root.?;
        var target = line;
        var off: usize = 0;
        while (true) {
            switch (node.kind) {
                .leaf => {
                    for (leafSlice(node), 0..) |b, i| {
                        if (b == '\n') {
                            target -= 1;
                            if (target == 0) return off + i + 1;
                        }
                    }
                    unreachable;
                },
                .inner => |in| {
                    if (in.left.newlines >= target) {
                        node = in.left;
                    } else {
                        target -= in.left.newlines;
                        off += in.left.bytes;
                        node = in.right;
                    }
                },
            }
        }
    }

    /// Non-continuation bytes in [0, offset) — the character offset of
    /// byte `offset`. O(log n) descent plus at most one leaf scan.
    pub fn charsBefore(self: *const Rope, offset: usize) usize {
        std.debug.assert(offset <= self.len());
        var node = self.root orelse return 0;
        var k = offset;
        var acc: usize = 0;
        while (true) {
            if (k >= node.bytes) return acc + node.chars;
            switch (node.kind) {
                .leaf => return acc + countChars(leafSlice(node)[0..k]),
                .inner => |in| {
                    if (k <= in.left.bytes) {
                        node = in.left;
                    } else {
                        acc += in.left.chars;
                        k -= in.left.bytes;
                        node = in.right;
                    }
                },
            }
        }
    }

    /// Byte offset of the lead byte of 0-based character `ch`; the
    /// rope length when `ch` is at or past `charCount()`. O(log n)
    /// descent plus at most one leaf scan.
    pub fn charToOffset(self: *const Rope, ch: usize) usize {
        if (ch >= self.charCount()) return self.len();
        var node = self.root.?;
        var target = ch;
        var off: usize = 0;
        while (true) {
            switch (node.kind) {
                .leaf => {
                    var seen: usize = 0;
                    for (leafSlice(node), 0..) |b, i| {
                        if (!isCont(b)) {
                            if (seen == target) return off + i;
                            seen += 1;
                        }
                    }
                    unreachable;
                },
                .inner => |in| {
                    if (target < in.left.chars) {
                        node = in.left;
                    } else {
                        target -= in.left.chars;
                        off += in.left.bytes;
                        node = in.right;
                    }
                },
            }
        }
    }

    /// Maps a byte offset to 0-based line and byte column.
    pub fn offsetToLineCol(self: *const Rope, offset: usize) LineCol {
        const line = self.newlinesBefore(offset);
        const start = self.lineToOffset(line);
        return .{ .line = line, .col = offset - start };
    }

    /// Copies [start, end) into a caller-owned buffer.
    pub fn sliceAlloc(self: *const Rope, alloc: Allocator, start: usize, end: usize) ![]u8 {
        const out = try alloc.alloc(u8, end - start);
        errdefer alloc.free(out);
        var it = self.iterateRange(start, end);
        var pos: usize = 0;
        while (it.next()) |chunk| {
            @memcpy(out[pos .. pos + chunk.len], chunk);
            pos += chunk.len;
        }
        std.debug.assert(pos == out.len);
        return out;
    }

    /// Zero-copy chunk iterator over [start, end). Slices are only
    /// valid until the next rope mutation.
    pub fn iterateRange(self: *const Rope, start: usize, end: usize) RangeIter {
        std.debug.assert(start <= end and end <= self.len());
        var it = RangeIter{ .remaining = end - start };
        if (start == end) return it;
        // Descend to the leaf containing `start`, pushing right siblings.
        var node = self.root.?;
        var k = start;
        while (true) {
            switch (node.kind) {
                .leaf => {
                    it.first = leafSlice(node)[k..];
                    return it;
                },
                .inner => |in| {
                    if (k < in.left.bytes) {
                        it.push(in.right);
                        node = in.left;
                    } else {
                        k -= in.left.bytes;
                        node = in.right;
                    }
                },
            }
        }
    }

    pub const RangeIter = struct {
        remaining: usize,
        first: ?[]const u8 = null,
        stack: [MAX_DEPTH]*Node = undefined,
        depth: usize = 0,

        // AVL height for 2^52 leaves is < 80; 100MB/2KB leaves is ~23.
        const MAX_DEPTH = 88;

        fn push(self: *RangeIter, node: *Node) void {
            self.stack[self.depth] = node;
            self.depth += 1;
        }

        pub fn next(self: *RangeIter) ?[]const u8 {
            if (self.remaining == 0) return null;
            var chunk: []const u8 = undefined;
            if (self.first) |f| {
                chunk = f;
                self.first = null;
            } else {
                if (self.depth == 0) return null;
                self.depth -= 1;
                var node = self.stack[self.depth];
                while (true) {
                    switch (node.kind) {
                        .leaf => break,
                        .inner => |in| {
                            self.push(in.right);
                            node = in.left;
                        },
                    }
                }
                chunk = leafSlice(node);
            }
            if (chunk.len >= self.remaining) {
                chunk = chunk[0..self.remaining];
                self.remaining = 0;
            } else {
                self.remaining -= chunk.len;
            }
            return chunk;
        }
    };

    // ---- test support -------------------------------------------------

    /// Recursively validates aggregates and the AVL height invariant.
    fn checkNode(node: *const Node) void {
        switch (node.kind) {
            .leaf => |l| {
                std.debug.assert(l.len > 0);
                std.debug.assert(l.len <= MAX_LEAF);
                std.debug.assert(node.bytes == l.len);
                std.debug.assert(node.newlines == countNewlines(leafSlice(node)));
                std.debug.assert(node.chars == countChars(leafSlice(node)));
                std.debug.assert(node.height == 1);
            },
            .inner => |in| {
                checkNode(in.left);
                checkNode(in.right);
                std.debug.assert(node.bytes == in.left.bytes + in.right.bytes);
                std.debug.assert(node.newlines == in.left.newlines + in.right.newlines);
                std.debug.assert(node.chars == in.left.chars + in.right.chars);
                std.debug.assert(node.height == 1 + @max(in.left.height, in.right.height));
                const diff = @as(i32, in.left.height) - @as(i32, in.right.height);
                std.debug.assert(diff >= -1 and diff <= 1);
            },
        }
    }

    pub fn checkInvariants(self: *const Rope) void {
        if (self.root) |n| checkNode(n);
    }

    pub const Stats = struct {
        leaves: usize = 0,
        inners: usize = 0,
        height: u16 = 0,
        /// Bytes actually stored.
        used: usize = 0,
        /// Bytes of leaf storage held (leaves * MAX_LEAF), i.e. what the
        /// tree costs regardless of fill.
        capacity: usize = 0,

        /// capacity/used — 1.0 is a perfectly packed tree. A rope whose
        /// leaves never merge drifts toward MAX_LEAF here.
        pub fn amplification(self: Stats) f64 {
            if (self.used == 0) return 1.0;
            return @as(f64, @floatFromInt(self.capacity)) / @as(f64, @floatFromInt(self.used));
        }
    };

    fn walkStats(node: *const Node, out: *Stats) void {
        switch (node.kind) {
            .leaf => |l| {
                out.leaves += 1;
                out.used += l.len;
                out.capacity += MAX_LEAF;
            },
            .inner => |in| {
                out.inners += 1;
                walkStats(in.left, out);
                walkStats(in.right, out);
            },
        }
    }

    /// Shape of the tree. O(n) in node count — for tests and benchmarks.
    pub fn stats(self: *const Rope) Stats {
        var s = Stats{};
        if (self.root) |n| {
            walkStats(n, &s);
            s.height = n.height;
        }
        return s;
    }

    pub fn leafCount(self: *const Rope) usize {
        return self.stats().leaves;
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn expectContent(r: *const Rope, expected: []const u8) !void {
    const got = try r.sliceAlloc(testing.allocator, 0, r.len());
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "rope basic insert and delete" {
    var r = Rope.init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.len());
    try testing.expectEqual(@as(usize, 1), r.lineCount());

    try r.insert(0, "hello world");
    try r.insert(5, ",");
    try expectContent(&r, "hello, world");
    try r.delete(0, 7);
    try expectContent(&r, "world");
    try r.delete(0, 5);
    try testing.expectEqual(@as(usize, 0), r.len());
    try expectContent(&r, "");
}

test "rope line queries" {
    var r = try Rope.initFromBytes(testing.allocator, "one\ntwo\nthree");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.lineCount());
    try testing.expectEqual(@as(usize, 0), r.lineToOffset(0));
    try testing.expectEqual(@as(usize, 4), r.lineToOffset(1));
    try testing.expectEqual(@as(usize, 8), r.lineToOffset(2));

    var lc = r.offsetToLineCol(0);
    try testing.expectEqual(@as(usize, 0), lc.line);
    try testing.expectEqual(@as(usize, 0), lc.col);
    lc = r.offsetToLineCol(3); // the '\n' itself belongs to line 0
    try testing.expectEqual(@as(usize, 0), lc.line);
    try testing.expectEqual(@as(usize, 3), lc.col);
    lc = r.offsetToLineCol(4);
    try testing.expectEqual(@as(usize, 1), lc.line);
    try testing.expectEqual(@as(usize, 0), lc.col);
    lc = r.offsetToLineCol(10);
    try testing.expectEqual(@as(usize, 2), lc.line);
    try testing.expectEqual(@as(usize, 2), lc.col);
}

test "rope trailing newline makes an empty last line" {
    var r = try Rope.initFromBytes(testing.allocator, "a\nb\n");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.lineCount());
    try testing.expectEqual(@as(usize, 4), r.lineToOffset(2));
    const lc = r.offsetToLineCol(4);
    try testing.expectEqual(@as(usize, 2), lc.line);
    try testing.expectEqual(@as(usize, 0), lc.col);
}

test "rope character aggregate counts codepoints, not bytes" {
    var r = try Rope.initFromBytes(testing.allocator, "ab\u{e9}c\n\u{1F600}xy\n");
    defer r.deinit();
    // 9 characters, 13 bytes.
    try testing.expectEqual(@as(usize, 13), r.len());
    try testing.expectEqual(@as(usize, 9), r.charCount());
    try testing.expectEqual(@as(usize, 2), r.charsBefore(2)); // before é
    try testing.expectEqual(@as(usize, 3), r.charsBefore(4)); // after é
    try testing.expectEqual(@as(usize, 2), r.charToOffset(2));
    try testing.expectEqual(@as(usize, 4), r.charToOffset(3));
    // The emoji is one character, four bytes.
    try testing.expectEqual(@as(usize, 6), r.charToOffset(5));
    try testing.expectEqual(@as(usize, 10), r.charToOffset(6));
    // At/past the end clamps to the rope length.
    try testing.expectEqual(@as(usize, 13), r.charToOffset(9));
    try testing.expectEqual(@as(usize, 13), r.charToOffset(999));

    // Edits keep the aggregate exact, including a delete that cuts a
    // multi-byte sequence in half.
    try r.insert(2, "\u{4e2d}\u{6587}");
    try testing.expectEqual(@as(usize, 11), r.charCount());
    try r.delete(3, 8); // mid-sequence on both ends of the range
    r.checkInvariants();
    const got = try r.sliceAlloc(testing.allocator, 0, r.len());
    defer testing.allocator.free(got);
    try testing.expectEqual(Rope.countChars(got), r.charCount());
}

test "rope char queries straddle leaf boundaries" {
    // A multi-byte sequence sitting exactly on a leaf seam: build from
    // two inserts so the 4-byte emoji is cut across leaves.
    var r = Rope.init(testing.allocator);
    defer r.deinit();
    const big = try testing.allocator.alloc(u8, MAX_LEAF);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try r.insert(0, big);
    try r.insert(MAX_LEAF, big);
    try r.insert(MAX_LEAF, "\u{1F600}"); // may land on the seam
    r.checkInvariants();
    try testing.expectEqual(@as(usize, 2 * MAX_LEAF + 1), r.charCount());
    try testing.expectEqual(@as(usize, MAX_LEAF), r.charsBefore(MAX_LEAF));
    try testing.expectEqual(@as(usize, MAX_LEAF + 1), r.charsBefore(MAX_LEAF + 4));
    try testing.expectEqual(@as(usize, MAX_LEAF), r.charToOffset(MAX_LEAF));
    try testing.expectEqual(@as(usize, MAX_LEAF + 4), r.charToOffset(MAX_LEAF + 1));
}

test "rope initFromBytes crosses leaf boundaries" {
    // Big enough to force a multi-leaf tree.
    const n = MAX_LEAF * 7 + 123;
    const buf = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(buf);
    for (buf, 0..) |*b, i| b.* = if (i % 53 == 0) '\n' else 'x';
    var r = try Rope.initFromBytes(testing.allocator, buf);
    defer r.deinit();
    r.checkInvariants();
    try testing.expectEqual(n, r.len());
    try expectContent(&r, buf);
    try testing.expectEqual(Rope.countNewlines(buf), r.newlineCount());
}

test "rope range iterator" {
    const n = MAX_LEAF * 3 + 17;
    const buf = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(buf);
    for (buf, 0..) |*b, i| b.* = @intCast('a' + (i % 26));
    var r = try Rope.initFromBytes(testing.allocator, buf);
    defer r.deinit();

    const start = MAX_LEAF - 5;
    const end = 2 * MAX_LEAF + 9;
    const got = try r.sliceAlloc(testing.allocator, start, end);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(buf[start..end], got);
}

test "rope re-merges the leaves an edit cut apart" {
    const alloc = testing.allocator;
    const n = MAX_LEAF * 4;
    const buf = try alloc.alloc(u8, n);
    defer alloc.free(buf);
    for (buf, 0..) |*b, i| b.* = if (i % 37 == 0) '\n' else 'z';

    var r = try Rope.initFromBytes(alloc, buf);
    defer r.deinit();
    const before = r.stats().leaves;

    // Cutting a leaf in half and dropping one byte leaves two halves
    // that fit in one leaf: they must fuse back, not accumulate.
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const pos = MAX_LEAF + 1 + (i % 97);
        try r.delete(pos, pos + 1);
        try r.insert(pos, "y");
    }
    r.checkInvariants();
    try testing.expectEqual(before, r.stats().leaves);
    try testing.expectEqual(n, r.len());
}

test "rope fuzz vs byte-array oracle" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed_cafe);
    const rand = prng.random();

    var r = Rope.init(alloc);
    defer r.deinit();
    var oracle: std.ArrayList(u8) = .empty;
    defer oracle.deinit(alloc);

    var text_buf: [80]u8 = undefined;
    var op: usize = 0;
    while (op < 4000) : (op += 1) {
        const doing_insert = oracle.items.len == 0 or rand.intRangeAtMost(u8, 0, 2) != 0;
        if (doing_insert) {
            const tlen = rand.intRangeAtMost(usize, 1, text_buf.len);
            for (text_buf[0..tlen]) |*b| {
                b.* = if (rand.intRangeAtMost(u8, 0, 7) == 0) '\n' else rand.intRangeAtMost(u8, 'a', 'z');
            }
            const pos = rand.intRangeAtMost(usize, 0, oracle.items.len);
            try r.insert(pos, text_buf[0..tlen]);
            try oracle.insertSlice(alloc, pos, text_buf[0..tlen]);
        } else {
            const start = rand.intRangeAtMost(usize, 0, oracle.items.len);
            const max_del = @min(oracle.items.len - start, 120);
            const dlen = rand.intRangeAtMost(usize, 0, max_del);
            try r.delete(start, start + dlen);
            try oracle.replaceRange(alloc, start, dlen, "");
        }

        try testing.expectEqual(oracle.items.len, r.len());
        if (op % 61 == 0) {
            r.checkInvariants();
            try expectContent(&r, oracle.items);
            try testing.expectEqual(Rope.countNewlines(oracle.items), r.newlineCount());
            try testing.expectEqual(Rope.countChars(oracle.items), r.charCount());
        }
        if (op % 37 == 0 and oracle.items.len > 0) {
            // Random line/offset queries vs oracle.
            const off = rand.intRangeAtMost(usize, 0, oracle.items.len);
            const expect_line = Rope.countNewlines(oracle.items[0..off]);
            try testing.expectEqual(expect_line, r.newlinesBefore(off));
            const lc = r.offsetToLineCol(off);
            try testing.expectEqual(expect_line, lc.line);
            // Recompute line start naively.
            var line_start: usize = off;
            while (line_start > 0 and oracle.items[line_start - 1] != '\n') line_start -= 1;
            try testing.expectEqual(line_start, r.lineToOffset(lc.line));
            try testing.expectEqual(off - line_start, lc.col);
            // Character queries vs oracle (content is 'a'..'z' + '\n',
            // so lead-byte counting equals byte counting here; the
            // multibyte cases live in the dedicated tests and the
            // document fuzzer).
            try testing.expectEqual(Rope.countChars(oracle.items[0..off]), r.charsBefore(off));
        }
    }
    r.checkInvariants();
    try expectContent(&r, oracle.items);
}

test "rope large document edits stay fast" {
    // 16MB build + scattered edits; the timing bound is deliberately
    // loose (CI-safe) — locally a single edit is in the microseconds.
    const alloc = testing.allocator;
    const n: usize = 16 * 1024 * 1024;
    const buf = try alloc.alloc(u8, n);
    defer alloc.free(buf);
    @memset(buf, 'q');
    var i: usize = 80;
    while (i < n) : (i += 81) buf[i] = '\n';

    var r = try Rope.initFromBytes(alloc, buf);
    defer r.deinit();
    r.checkInvariants();

    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();
    var op: usize = 0;
    while (op < 1000) : (op += 1) {
        const pos = rand.intRangeAtMost(usize, 0, r.len());
        if (op % 2 == 0) {
            try r.insert(pos, "inserted text\n");
        } else {
            const dend = @min(r.len(), pos + 10);
            try r.delete(pos, dend);
        }
    }
    r.checkInvariants();
}
