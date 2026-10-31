//! Block cache and read-ahead policy for reading a remote file like a player does.
//!
//! The kernel's page cache shape, which is why sshfs feels fast: a jump costs one
//! small read, and only reads that keep going sequentially earn more read-ahead. A
//! demuxer opens a file by hopping head, tail, head and then alternates between
//! tracks, so one window thrown away on every miss paid megabytes per hop.
//! Pure policy: no locks, no transport, no clock.

const std = @import("std");

/// Unit of fetching. Small enough that a queued read-ahead reply delays a jump only
/// briefly on a slow link, since a connection answers strictly in order.
pub const BLOCK: usize = 256 << 10;

/// Memory bound: 128 MiB, about two minutes of an 8 Mbit/s film.
pub const MAX_BLOCKS: usize = 512;

/// Blocks a new sequential run reads ahead, doubling as it keeps going.
const START_AHEAD: u32 = 2;
const MAX_AHEAD: u32 = 256;

/// Concurrent sequential runs followed: one per track of a badly interleaved file, plus a stray.
const MAX_RUNS = 4;

/// Block changes after which a run nobody reads stops being fed, so the index a demuxer read once does not read on for ever.
const ACTIVE_TICKS: u64 = 64;

/// How far behind a run's position a read still belongs to it: demuxers re-read a little.
const BACK_SLACK: u64 = 2;

const Block = struct {
    /// Empty while `loading`. Shorter than BLOCK only at the end of the file.
    data: []u8 = &.{},
    loading: bool = true,
    last_use: u64 = 0,
};

const Run = struct {
    valid: bool = false,
    /// The block after the last one read.
    next: u64 = 0,
    ahead: u32 = START_AHEAD,
    tick: u64 = 0,
};

pub const RangeCache = struct {
    allocator: std.mem.Allocator,
    size: u64,
    blocks: std.AutoHashMapUnmanaged(u64, Block) = .empty,
    runs: [MAX_RUNS]Run = @splat(.{}),
    tick: u64 = 0,
    last_block: ?u64 = null,
    /// The block a blocked reader needs; it goes before all read-ahead.
    demand: ?u64 = null,
    inflight: u32 = 0,
    max_blocks: usize = MAX_BLOCKS,

    pub fn init(allocator: std.mem.Allocator, size: u64) RangeCache {
        return .{ .allocator = allocator, .size = size };
    }

    pub fn deinit(self: *RangeCache) void {
        var it = self.blocks.valueIterator();
        while (it.next()) |b| self.allocator.free(b.data);
        self.blocks.deinit(self.allocator);
    }

    fn blockCount(self: *const RangeCache) u64 {
        return std.math.divCeil(u64, self.size, BLOCK) catch unreachable;
    }

    /// Bytes at `off` copied to `out`, 0 at the end of the file, or null with the block demanded.
    pub fn read(self: *RangeCache, off: u64, out: []u8) ?usize {
        if (off >= self.size) return 0;
        const idx = off / BLOCK;
        self.noteAccess(idx);
        const block = self.blocks.getPtr(idx) orelse {
            self.demand = idx;
            return null;
        };
        block.last_use = self.tick;
        if (block.loading) {
            self.demand = idx;
            return null;
        }
        const inner: usize = @intCast(off - idx * BLOCK);
        // A block shorter than it should be: the file shrank under us.
        if (inner >= block.data.len) return 0;
        const n = @min(out.len, block.data.len - inner);
        @memcpy(out[0..n], block.data[inner..][0..n]);
        return n;
    }

    fn noteAccess(self: *RangeCache, idx: u64) void {
        if (self.last_block == idx) return;
        self.last_block = idx;
        self.tick += 1;
        var best: ?*Run = null;
        for (&self.runs) |*run| {
            if (!run.valid) continue;
            if (idx + BACK_SLACK < run.next or idx > run.next + run.ahead) continue;
            if (best == null or run.tick > best.?.tick) best = run;
        }
        if (best) |run| {
            if (idx >= run.next) {
                run.next = idx + 1;
                run.ahead = @min(run.ahead * 2, MAX_AHEAD);
            }
            run.tick = self.tick;
            return;
        }
        var oldest = &self.runs[0];
        for (&self.runs) |*run| {
            if (!run.valid) {
                oldest = run;
                break;
            }
            if (run.tick < oldest.tick) oldest = run;
        }
        oldest.* = .{ .valid = true, .next = idx + 1, .tick = self.tick };
    }

    fn runActive(self: *const RangeCache, run: *const Run) bool {
        return run.valid and self.tick - run.tick <= ACTIVE_TICKS;
    }

    /// Whether a block is what a live run is inside or about to need, which keeps it from eviction.
    fn wanted(self: *const RangeCache, idx: u64) bool {
        for (&self.runs) |*run| {
            if (self.runActive(run) and idx + BACK_SLACK >= run.next and idx < run.next + run.ahead) return true;
        }
        return false;
    }

    /// Frees the least recently used block; `force` also takes blocks read-ahead fetched for a live run.
    fn evictOne(self: *RangeCache, force: bool) bool {
        var victim: ?u64 = null;
        var victim_use: u64 = std.math.maxInt(u64);
        var it = self.blocks.iterator();
        while (it.next()) |kv| {
            const block = kv.value_ptr;
            if (block.loading or block.last_use >= victim_use) continue;
            if (!force and self.wanted(kv.key_ptr.*)) continue;
            victim = kv.key_ptr.*;
            victim_use = block.last_use;
        }
        const idx = victim orelse return false;
        const removed = self.blocks.fetchRemove(idx).?;
        self.allocator.free(removed.value.data);
        return true;
    }

    fn claim(self: *RangeCache, idx: u64, force: bool) !bool {
        while (self.blocks.count() >= self.max_blocks) {
            if (!self.evictOne(force)) {
                // A blocked reader outranks the bound; read-ahead just waits.
                if (force) break;
                return false;
            }
        }
        try self.blocks.put(self.allocator, idx, .{ .last_use = self.tick });
        self.inflight += 1;
        return true;
    }

    /// The next block to request and marks it loading: the demanded one, then each live run's read-ahead, newest run first.
    pub fn nextFetch(self: *RangeCache) !?u64 {
        if (self.demand) |idx| {
            self.demand = null;
            if (!self.blocks.contains(idx)) {
                _ = try self.claim(idx, true);
                return idx;
            }
        }
        const count = self.blockCount();
        var order: [MAX_RUNS]*const Run = undefined;
        var n: usize = 0;
        for (&self.runs) |*run| {
            if (!self.runActive(run)) continue;
            var at = n;
            while (at > 0 and order[at - 1].tick < run.tick) : (at -= 1) order[at] = order[at - 1];
            order[at] = run;
            n += 1;
        }
        for (order[0..n]) |run| {
            var idx = run.next;
            const end = @min(count, run.next + run.ahead);
            while (idx < end) : (idx += 1) {
                if (self.blocks.contains(idx)) continue;
                return if (try self.claim(idx, false)) idx else null;
            }
        }
        return null;
    }

    /// Stores a claimed block's bytes.
    pub fn complete(self: *RangeCache, idx: u64, bytes: []const u8) !void {
        const block = self.blocks.getPtr(idx) orelse return;
        if (!block.loading) return;
        self.inflight -= 1;
        block.data = try self.allocator.dupe(u8, bytes);
        block.loading = false;
    }

    /// Stores a block nothing claimed, for bytes the caller already fetched.
    pub fn insert(self: *RangeCache, idx: u64, bytes: []const u8) !void {
        if (!try self.claim(idx, true)) return;
        try self.complete(idx, bytes);
    }

    /// Forgets every claim, for a connection that died with them on the wire.
    pub fn abandonLoading(self: *RangeCache) void {
        var doomed: [64]u64 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.blocks.iterator();
            while (it.next()) |kv| {
                if (!kv.value_ptr.loading) continue;
                doomed[n] = kv.key_ptr.*;
                n += 1;
                if (n == doomed.len) break;
            }
            if (n == 0) break;
            for (doomed[0..n]) |idx| _ = self.blocks.remove(idx);
        }
        self.inflight = 0;
    }
};

/// Requests to keep in flight so a `bytes_per_ms` link with this round trip stays full.
///
/// Fewer starve the link one round trip per block; more delay a jump behind replies nobody needs any more.
pub fn pipelineDepth(bytes_per_ms: u64, rtt_ms: u64) u32 {
    const in_flight = bytes_per_ms * rtt_ms / BLOCK;
    return @intCast(std.math.clamp(in_flight + 1, 2, 16));
}

/// Whether a link is failing a film over time, which one short sample cannot tell: a
/// Wi-Fi VPN swings sevenfold within seconds and buffering rides that out. Only a reader
/// starved through a whole window by a link that averaged under the bitrate counts.
pub const StarveMeter = struct {
    bitrate_kbps: u64,
    start_ms: i64 = 0,
    blocked_ms: i64 = 0,
    bytes: u64 = 0,

    const WINDOW_MS: i64 = 30_000;
    const BLOCKED_PCT: i64 = 25;

    /// @return true when the window that just closed proved the link too slow.
    pub fn check(self: *StarveMeter, now_ms: i64) bool {
        if (self.start_ms == 0) self.start_ms = now_ms;
        const elapsed = now_ms - self.start_ms;
        if (elapsed < WINDOW_MS) return false;
        const starved = self.blocked_ms * 100 >= elapsed * BLOCKED_PCT and
            self.bytes * 8 / @as(u64, @intCast(elapsed)) < self.bitrate_kbps;
        self.start_ms = now_ms;
        self.blocked_ms = 0;
        self.bytes = 0;
        return starved;
    }
};

const t = std.testing;

fn fill(cache: *RangeCache) !void {
    var block: [BLOCK]u8 = undefined;
    @memset(&block, 0x5A);
    while (try cache.nextFetch()) |idx| try cache.complete(idx, &block);
}

/// Serves a read like the fetcher does, returning how many blocks it had to fetch.
fn demandRead(cache: *RangeCache, off: u64) !u64 {
    var fetched: u64 = 0;
    var out: [4096]u8 = undefined;
    var block: [BLOCK]u8 = undefined;
    while (cache.read(off, &out) == null) {
        const idx = (try cache.nextFetch()).?;
        try cache.complete(idx, &block);
        fetched += 1;
    }
    return fetched;
}

test "a jump fetches one block plus a small read-ahead, not megabytes" {
    var cache = RangeCache.init(t.allocator, 4 << 30);
    defer cache.deinit();
    try t.expectEqual(@as(u64, 1), try demandRead(&cache, 3 << 30));
    var extra: u64 = 0;
    while (try cache.nextFetch()) |idx| {
        try cache.complete(idx, "x");
        extra += 1;
    }
    try t.expectEqual(@as(u64, START_AHEAD), extra);
}

test "a demuxer's open costs little: head, tail, head again is served from cache" {
    var cache = RangeCache.init(t.allocator, 4 << 30);
    defer cache.deinit();
    try t.expectEqual(@as(u64, 1), try demandRead(&cache, 0));
    try t.expectEqual(@as(u64, 1), try demandRead(&cache, (4 << 30) - 4096));
    try t.expectEqual(@as(u64, 0), try demandRead(&cache, 16));
}

test "sequential reading earns read-ahead up to the cap" {
    var cache = RangeCache.init(t.allocator, 4 << 30);
    defer cache.deinit();
    var off: u64 = 0;
    while (off < 64 * BLOCK) : (off += BLOCK) {
        _ = try demandRead(&cache, off);
        try fill(&cache);
    }
    const run = cache.runs[0];
    try t.expectEqual(MAX_AHEAD, run.ahead);
    // Filled to the far edge, so the reader runs ahead of the link.
    try t.expect(cache.blocks.contains(run.next + MAX_AHEAD - 1));
}

test "two tracks far apart each keep their own run instead of thrashing" {
    var cache = RangeCache.init(t.allocator, 4 << 30);
    defer cache.deinit();
    const video: u64 = 0;
    const audio: u64 = 2 << 30;
    var i: u64 = 0;
    var fetched_late: u64 = 0;
    while (i < 40) : (i += 1) {
        const fetched = try demandRead(&cache, video + i * BLOCK) + try demandRead(&cache, audio + i * BLOCK);
        try fill(&cache);
        if (i >= 8) fetched_late += fetched;
    }
    try t.expectEqual(@as(u64, 0), fetched_late);
}

test "the block budget holds and spares what a live run still needs" {
    var cache = RangeCache.init(t.allocator, 4 << 30);
    defer cache.deinit();
    cache.max_blocks = 32;
    var off: u64 = 0;
    while (off < 256 * BLOCK) : (off += BLOCK) {
        _ = try demandRead(&cache, off);
        try fill(&cache);
        try t.expect(cache.blocks.count() <= cache.max_blocks);
        // A paused reader fills the budget, then read-ahead stops rather than evicting itself.
        try t.expect(cache.blocks.contains(off / BLOCK));
    }
    try t.expectEqual(@as(?u64, null), try cache.nextFetch());
}

test "a run nobody reads any more stops being fed" {
    var cache = RangeCache.init(t.allocator, 4 << 30);
    defer cache.deinit();
    _ = try demandRead(&cache, 3 << 30);
    var off: u64 = 0;
    while (off < (ACTIVE_TICKS + 2) * BLOCK) : (off += BLOCK) _ = try demandRead(&cache, off);
    try t.expect(!cache.runActive(&cache.runs[0]));
}

test "reads end at the file's end, also inside a short last block" {
    var cache = RangeCache.init(t.allocator, BLOCK + 10);
    defer cache.deinit();
    var out: [64]u8 = undefined;
    try cache.insert(1, "0123456789");
    try t.expectEqual(@as(?usize, 10), cache.read(BLOCK, &out));
    try t.expectEqual(@as(?usize, 3), cache.read(BLOCK + 7, &out));
    try t.expectEqual(@as(?usize, 0), cache.read(BLOCK + 10, &out));
    // Read-ahead never asks past the last block.
    while (try cache.nextFetch()) |idx| {
        try t.expect(idx <= 1);
        try cache.complete(idx, "");
    }
}

test "a dead connection's claims are forgotten so they can be asked again" {
    var cache = RangeCache.init(t.allocator, 4 << 30);
    defer cache.deinit();
    var out: [64]u8 = undefined;
    try t.expectEqual(@as(?usize, null), cache.read(0, &out));
    try t.expectEqual(@as(?u64, 0), try cache.nextFetch());
    try t.expectEqual(@as(u32, 1), cache.inflight);
    cache.abandonLoading();
    try t.expectEqual(@as(u32, 0), cache.inflight);
    try t.expectEqual(@as(?usize, null), cache.read(0, &out));
    try t.expectEqual(@as(?u64, 0), try cache.nextFetch());
    try cache.complete(0, "abc");
    try t.expectEqual(@as(?usize, 3), cache.read(0, &out));
}

test "StarveMeter trips only on a starved reader and a link under the bitrate, over a whole window" {
    const window = StarveMeter.WINDOW_MS;
    // 8 Mbit/s film, link averaging 4: 15 MiB in 30s, reader blocked half the time.
    var slow = StarveMeter{ .bitrate_kbps = 8_000 };
    try t.expect(!slow.check(1));
    slow.bytes = 15 << 20;
    slow.blocked_ms = window / 2;
    try t.expect(!slow.check(window / 2));
    try t.expect(slow.check(window + 1));
    // The window closed: the next one starts clean.
    try t.expect(!slow.check(2 * window + 2));

    // Same stalls on a link with the capacity: a seek or a blip, not a slow link.
    var fast = StarveMeter{ .bitrate_kbps = 8_000 };
    _ = fast.check(1);
    fast.bytes = 60 << 20;
    fast.blocked_ms = window / 2;
    try t.expect(!fast.check(window + 1));

    // Slow link but a reader that never waited: paused, or the buffer is doing its job.
    var paused = StarveMeter{ .bitrate_kbps = 8_000 };
    _ = paused.check(1);
    paused.bytes = 1 << 20;
    try t.expect(!paused.check(10 * window));

    // Unknown bitrate never trips.
    var unknown = StarveMeter{ .bitrate_kbps = 0 };
    _ = unknown.check(1);
    unknown.blocked_ms = window;
    try t.expect(!unknown.check(window + 1));
}

test "pipelineDepth keeps the link full without queueing past what is useful" {
    // 2 MiB/s at 150ms: under one block in flight, the floor of 2 keeps one spare.
    try t.expectEqual(@as(u32, 2), pipelineDepth(2_097, 150));
    // 100 MiB/s at 30ms: about 3 MiB in flight.
    try t.expectEqual(@as(u32, 12), pipelineDepth(104_857, 30));
    try t.expectEqual(@as(u32, 16), pipelineDepth(1 << 30, 500));
    try t.expectEqual(@as(u32, 2), pipelineDepth(0, 0));
}
