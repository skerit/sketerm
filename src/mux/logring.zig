//! Per-session indexed log ring: the child's PTY output as clean,
//! escape-free LINES, each with a monotonically increasing id, so an
//! MCP assistant can tail the log compactly and re-read specific
//! lines in full later. Fed from parser events (print/execute) in the
//! daemon's drainSession — never from raw bytes, so escape sequences
//! never land here. Bounded: per-line byte cap, line-count cap and a
//! total-byte cap; evictions bump `dropped` instead of failing.
//!
//! Pure std code (no libc, no sockets) — unit-tested headless and
//! musl-clean for the portable daemon.

const std = @import("std");

pub const LogRing = struct {
    pub const Line = struct {
        id: u64,
        /// Wall-clock epoch ms on the ingesting host (caller-supplied).
        t_ms: i64,
        /// Scrubbed to valid UTF-8, control bytes (except \t) removed.
        bytes: []u8,
        /// The source line exceeded MAX_LINE_BYTES and was cut at ingest.
        truncated: bool = false,
        /// An OSC 5522 marker; `bytes` is the label.
        marker: bool = false,
    };

    pub const MAX_LINE_BYTES: usize = 4096;
    pub const MAX_LINES: usize = 1000;
    pub const MAX_TOTAL_BYTES: usize = 2 << 20;

    /// Marker admission (token bucket): an accidentally `cat`ed log
    /// full of OSC 5522 escapes must not evict real lines from the
    /// ring or flood viewers with pushes (each push costs the client
    /// a PNG encode).
    pub const MARKER_BURST: f64 = 8.0;
    pub const MARKER_PER_SEC: f64 = 2.0;

    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    next_id: u64 = 1,
    /// Lines evicted by the caps (oldest-first), ever.
    dropped: u64 = 0,
    total_bytes: usize = 0,
    /// Current (uncommitted) line accumulator.
    cur: std.ArrayList(u8) = .empty,
    cur_truncated: bool = false,
    /// A CR was seen and not yet resolved: CR+LF is a plain line
    /// ending (commit as-is), CR+text is an in-place rewrite (reset,
    /// keep the new segment). Resolving eagerly on CR would wipe
    /// every CRLF-terminated line — which is ALL PTY output.
    cur_cr: bool = false,
    /// Marker token bucket state.
    marker_tokens: f64 = MARKER_BURST,
    marker_refill_ms: i64 = 0,
    /// Markers rejected by the bucket, ever (surfaced in log_get).
    markers_dropped: u64 = 0,
    /// A drop-run is in progress (one note line per run, not per drop).
    marker_limiting: bool = false,

    pub fn init(allocator: std.mem.Allocator) LogRing {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LogRing) void {
        for (self.lines.items) |l| self.allocator.free(l.bytes);
        self.lines.deinit(self.allocator);
        self.cur.deinit(self.allocator);
    }

    /// Printable bytes (a UTF-8 run straight off the parser).
    pub fn feedBytes(self: *LogRing, bytes: []const u8) void {
        if (self.cur_cr) {
            // Text after a bare CR = progress-bar rewrite: keep the
            // new segment only.
            self.cur.clearRetainingCapacity();
            self.cur_truncated = false;
            self.cur_cr = false;
        }
        const room = MAX_LINE_BYTES -| self.cur.items.len;
        if (room == 0) {
            self.cur_truncated = true;
            return;
        }
        const take = @min(bytes.len, room);
        if (take < bytes.len) self.cur_truncated = true;
        self.cur.appendSlice(self.allocator, bytes[0..take]) catch {};
    }

    pub fn feedCodepoint(self: *LogRing, cp: u32) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(@min(cp, 0x10FFFF)), &buf) catch return;
        self.feedBytes(buf[0..n]);
    }

    /// C0 control byte: LF commits the line; a bare CR only marks a
    /// PENDING rewrite (CRLF must commit the line, not wipe it).
    pub fn feedControl(self: *LogRing, b: u8, t_ms: i64) void {
        switch (b) {
            '\n' => {
                self.cur_cr = false;
                self.commit(false, t_ms);
            },
            '\r' => self.cur_cr = true,
            '\t' => self.feedBytes("\t"),
            else => {},
        }
    }

    /// Admit or reject a marker at `t_ms` (token bucket). Rejected
    /// markers vanish entirely — no ring line (a flood would evict
    /// real output) and no viewer push (each costs a PNG encode) —
    /// except ONE note line at the start of each drop-run.
    pub fn admitMarker(self: *LogRing, t_ms: i64) bool {
        if (self.marker_refill_ms == 0) self.marker_refill_ms = t_ms;
        const elapsed = t_ms - self.marker_refill_ms;
        if (elapsed > 0) {
            self.marker_tokens = @min(
                MARKER_BURST,
                self.marker_tokens + @as(f64, @floatFromInt(elapsed)) * MARKER_PER_SEC / 1000.0,
            );
            self.marker_refill_ms = t_ms;
        }
        if (self.marker_tokens >= 1.0) {
            self.marker_tokens -= 1.0;
            self.marker_limiting = false;
            return true;
        }
        self.markers_dropped += 1;
        if (!self.marker_limiting) {
            self.marker_limiting = true;
            _ = self.commitStandalone("[marker rate limit hit: dropping excess markers]", false, t_ms);
        }
        return false;
    }

    /// Commit an OSC-marker line (its own line; a partial normal line
    /// stays pending). Returns the marker's line id.
    pub fn addMarker(self: *LogRing, label: []const u8, t_ms: i64) u64 {
        return self.commitStandalone(label, true, t_ms);
    }

    /// Commit `text` as its own line without disturbing the pending
    /// partial-line accumulator. Returns the new line's id.
    fn commitStandalone(self: *LogRing, text: []const u8, marker: bool, t_ms: i64) u64 {
        const save = self.cur;
        const save_trunc = self.cur_truncated;
        const save_cr = self.cur_cr;
        self.cur = .empty;
        self.cur_truncated = false;
        self.cur_cr = false;
        self.feedBytes(text);
        const id = self.next_id;
        self.commit(marker, t_ms);
        self.cur.deinit(self.allocator);
        self.cur = save;
        self.cur_truncated = save_trunc;
        self.cur_cr = save_cr;
        return id;
    }

    /// Flush a pending partial line (child exited mid-line).
    pub fn flush(self: *LogRing, t_ms: i64) void {
        if (self.cur.items.len > 0) self.commit(false, t_ms);
    }

    fn commit(self: *LogRing, marker: bool, t_ms: i64) void {
        // Empty non-marker lines still commit (blank output lines keep
        // ids aligned with what the app printed).
        const scrubbed = scrub(self.allocator, self.cur.items) catch {
            self.cur.clearRetainingCapacity();
            self.cur_truncated = false;
            return;
        };
        self.lines.append(self.allocator, .{
            .id = self.next_id,
            .t_ms = t_ms,
            .bytes = scrubbed,
            .truncated = self.cur_truncated,
            .marker = marker,
        }) catch {
            self.allocator.free(scrubbed);
            self.cur.clearRetainingCapacity();
            self.cur_truncated = false;
            return;
        };
        self.next_id += 1;
        self.total_bytes += scrubbed.len;
        self.cur.clearRetainingCapacity();
        self.cur_truncated = false;
        while (self.lines.items.len > MAX_LINES or self.total_bytes > MAX_TOTAL_BYTES) {
            const old = self.lines.orderedRemove(0);
            self.total_bytes -= old.bytes.len;
            self.allocator.free(old.bytes);
            self.dropped += 1;
        }
    }

    /// Copy with control bytes removed (except \t) and invalid UTF-8
    /// replaced by '?', so the result is always JSON-stringify-safe.
    fn scrub(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b < 0x20 and b != '\t') {
                i += 1;
                continue;
            }
            if (b == 0x7F) {
                i += 1;
                continue;
            }
            if (b < 0x80) {
                try out.append(allocator, b);
                i += 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(b) catch {
                try out.append(allocator, '?');
                i += 1;
                continue;
            };
            if (i + len > bytes.len) {
                try out.append(allocator, '?');
                i += 1;
                continue;
            }
            if (std.unicode.utf8Decode(bytes[i..][0..len])) |_| {
                try out.appendSlice(allocator, bytes[i..][0..len]);
                i += len;
            } else |_| {
                try out.append(allocator, '?');
                i += 1;
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// First stored line with id >= `id` (binary search — ids are
    /// strictly increasing), or null when everything newer was dropped.
    pub fn indexOfId(self: *const LogRing, id: u64) ?usize {
        const items = self.lines.items;
        if (items.len == 0 or items[items.len - 1].id < id) return null;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].id < id) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn byId(self: *const LogRing, id: u64) ?*const Line {
        const i = self.indexOfId(id) orelse return null;
        const l = &self.lines.items[i];
        return if (l.id == id) l else null;
    }
};

test "lines get increasing ids and LF commits" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    r.feedBytes("hello");
    r.feedControl('\n', 100);
    r.feedBytes("world");
    r.feedControl('\n', 200);
    try std.testing.expectEqual(@as(usize, 2), r.lines.items.len);
    try std.testing.expectEqual(@as(u64, 1), r.lines.items[0].id);
    try std.testing.expectEqualStrings("hello", r.lines.items[0].bytes);
    try std.testing.expectEqual(@as(u64, 2), r.lines.items[1].id);
    try std.testing.expectEqual(@as(i64, 200), r.lines.items[1].t_ms);
}

test "CRLF commits the line intact (PTY line endings)" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    r.feedBytes("alpha");
    r.feedControl('\r', 0);
    r.feedControl('\n', 0);
    try std.testing.expectEqual(@as(usize, 1), r.lines.items.len);
    try std.testing.expectEqualStrings("alpha", r.lines.items[0].bytes);
}

test "CR resets the pending line (progress bar keeps last segment)" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    r.feedBytes("10%");
    r.feedControl('\r', 0);
    r.feedBytes("100%");
    r.feedControl('\n', 0);
    try std.testing.expectEqualStrings("100%", r.lines.items[0].bytes);
}

test "per-line cap truncates and flags" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    var chunk: [512]u8 = @splat('x');
    var fed: usize = 0;
    while (fed < LogRing.MAX_LINE_BYTES + 1000) : (fed += chunk.len) r.feedBytes(&chunk);
    r.feedControl('\n', 0);
    try std.testing.expectEqual(LogRing.MAX_LINE_BYTES, r.lines.items[0].bytes.len);
    try std.testing.expect(r.lines.items[0].truncated);
}

test "line-count cap evicts oldest and counts drops" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    var i: usize = 0;
    while (i < LogRing.MAX_LINES + 50) : (i += 1) {
        r.feedBytes("line");
        r.feedControl('\n', 0);
    }
    try std.testing.expectEqual(LogRing.MAX_LINES, r.lines.items.len);
    try std.testing.expectEqual(@as(u64, 50), r.dropped);
    // Oldest surviving id reflects the drops.
    try std.testing.expectEqual(@as(u64, 51), r.lines.items[0].id);
}

test "marker commits its own line without disturbing a partial" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    r.feedBytes("partial");
    const id = r.addMarker("checkpoint", 42);
    r.feedBytes(" line");
    r.feedControl('\n', 0);
    try std.testing.expectEqual(@as(u64, 1), id);
    try std.testing.expect(r.lines.items[0].marker);
    try std.testing.expectEqualStrings("checkpoint", r.lines.items[0].bytes);
    try std.testing.expectEqualStrings("partial line", r.lines.items[1].bytes);
}

test "scrub strips controls and invalid utf8" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    r.feedBytes("a\x01b\xffc\xc3\xa9");
    r.feedControl('\n', 0);
    try std.testing.expectEqualStrings("ab?c\xc3\xa9", r.lines.items[0].bytes);
}

test "marker bucket: burst admits, flood drops with one note line" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    var admitted: usize = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (r.admitMarker(5000)) {
            _ = r.addMarker("m", 5000);
            admitted += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 8), admitted); // MARKER_BURST
    try std.testing.expectEqual(@as(u64, 92), r.markers_dropped);
    // Exactly one rate-limit note line, after the admitted markers.
    var notes: usize = 0;
    for (r.lines.items) |l| {
        if (!l.marker and std.mem.indexOf(u8, l.bytes, "rate limit") != null) notes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), notes);
}

test "marker bucket refills over time and starts a new drop-run note" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    var i: usize = 0;
    while (i < 20) : (i += 1) _ = r.admitMarker(1000); // exhaust + drop-run 1
    try std.testing.expect(!r.admitMarker(1000));
    // 1s later: 2 tokens refilled.
    try std.testing.expect(r.admitMarker(2000));
    try std.testing.expect(r.admitMarker(2000));
    try std.testing.expect(!r.admitMarker(2000)); // drop-run 2
    var notes: usize = 0;
    for (r.lines.items) |l| {
        if (std.mem.indexOf(u8, l.bytes, "rate limit") != null) notes += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), notes);
}

test "byId finds lines and reports dropped ones as null" {
    var r = LogRing.init(std.testing.allocator);
    defer r.deinit();
    var i: usize = 0;
    while (i < LogRing.MAX_LINES + 10) : (i += 1) {
        r.feedBytes("x");
        r.feedControl('\n', 0);
    }
    try std.testing.expect(r.byId(5) == null); // dropped
    try std.testing.expect(r.byId(LogRing.MAX_LINES + 10) != null); // newest
    try std.testing.expect(r.byId(999999) == null);
}
