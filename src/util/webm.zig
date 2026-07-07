//! Minimal live WebM (Matroska/EBML) muxer for a single VP9 video
//! track — the container half of the video recorder (videorec.zig
//! feeds it compressed VP9 frames). Writes an unknown-size Segment
//! (standard for streaming; every player handles it) with known-size
//! Clusters. Pure Zig, no libwebm/libavformat.

const std = @import("std");

// EBML element IDs (kept with their length-descriptor bits, as spec'd).
const ID_EBML = 0x1A45DFA3;
const ID_EBML_VERSION = 0x4286;
const ID_EBML_READ_VERSION = 0x42F7;
const ID_EBML_MAX_ID_LEN = 0x42F2;
const ID_EBML_MAX_SIZE_LEN = 0x42F3;
const ID_DOCTYPE = 0x4282;
const ID_DOCTYPE_VERSION = 0x4287;
const ID_DOCTYPE_READ_VERSION = 0x4285;
const ID_SEGMENT = 0x18538067;
const ID_INFO = 0x1549A966;
const ID_TIMECODE_SCALE = 0x2AD7B1;
const ID_MUXING_APP = 0x4D80;
const ID_WRITING_APP = 0x5741;
const ID_TRACKS = 0x1654AE6B;
const ID_TRACK_ENTRY = 0xAE;
const ID_TRACK_NUMBER = 0xD7;
const ID_TRACK_UID = 0x73C5;
const ID_TRACK_TYPE = 0x83;
const ID_FLAG_LACING = 0x9C;
const ID_CODEC_ID = 0x86;
const ID_VIDEO = 0xE0;
const ID_PIXEL_WIDTH = 0xB0;
const ID_PIXEL_HEIGHT = 0xBA;
const ID_CLUSTER = 0x1F43B675;
const ID_TIMECODE = 0xE7;
const ID_SIMPLE_BLOCK = 0xA3;

const TRACK_NUMBER = 1;
/// Blocks carry a signed 16-bit timecode relative to the cluster, so a
/// cluster spans at most ~32s; start a new one before overflow.
const CLUSTER_MAX_MS = 30_000;

pub const Muxer = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Current cluster content (Timecode + SimpleBlocks), flushed as one
    /// known-size Cluster element when it rolls over or on finish.
    cluster: std.ArrayList(u8) = .empty,
    cluster_base_ms: i64 = 0,
    cluster_open: bool = false,

    pub fn init(allocator: std.mem.Allocator) Muxer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Muxer) void {
        self.buf.deinit(self.allocator);
        self.cluster.deinit(self.allocator);
    }

    /// Write the EBML header, Segment (unknown size), Info and Tracks.
    pub fn writeHeader(self: *Muxer, width: u32, height: u32) !void {
        const a = self.allocator;
        // EBML header.
        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(a);
        try elemUint(a, &hdr, ID_EBML_VERSION, 1);
        try elemUint(a, &hdr, ID_EBML_READ_VERSION, 1);
        try elemUint(a, &hdr, ID_EBML_MAX_ID_LEN, 4);
        try elemUint(a, &hdr, ID_EBML_MAX_SIZE_LEN, 8);
        try elemStr(a, &hdr, ID_DOCTYPE, "webm");
        try elemUint(a, &hdr, ID_DOCTYPE_VERSION, 2);
        try elemUint(a, &hdr, ID_DOCTYPE_READ_VERSION, 2);
        try elemBytes(a, &self.buf, ID_EBML, hdr.items);

        // Segment with unknown (streaming) size: id + 0x01FFFFFFFFFFFFFF.
        try writeId(a, &self.buf, ID_SEGMENT);
        try self.buf.appendSlice(a, &.{ 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

        // Info.
        var info: std.ArrayList(u8) = .empty;
        defer info.deinit(a);
        try elemUint(a, &info, ID_TIMECODE_SCALE, 1_000_000); // 1 ms tick
        try elemStr(a, &info, ID_MUXING_APP, "sketerm");
        try elemStr(a, &info, ID_WRITING_APP, "sketerm");
        try elemBytes(a, &self.buf, ID_INFO, info.items);

        // Tracks → one VP9 video track.
        var vid: std.ArrayList(u8) = .empty;
        defer vid.deinit(a);
        try elemUint(a, &vid, ID_PIXEL_WIDTH, width);
        try elemUint(a, &vid, ID_PIXEL_HEIGHT, height);
        var entry: std.ArrayList(u8) = .empty;
        defer entry.deinit(a);
        try elemUint(a, &entry, ID_TRACK_NUMBER, TRACK_NUMBER);
        try elemUint(a, &entry, ID_TRACK_UID, TRACK_NUMBER);
        try elemUint(a, &entry, ID_TRACK_TYPE, 1); // 1 = video
        try elemUint(a, &entry, ID_FLAG_LACING, 0);
        try elemStr(a, &entry, ID_CODEC_ID, "V_VP9");
        try elemBytes(a, &entry, ID_VIDEO, vid.items);
        var tracks: std.ArrayList(u8) = .empty;
        defer tracks.deinit(a);
        try elemBytes(a, &tracks, ID_TRACK_ENTRY, entry.items);
        try elemBytes(a, &self.buf, ID_TRACKS, tracks.items);
    }

    /// Append one compressed VP9 frame at absolute `timecode_ms`.
    pub fn addFrame(self: *Muxer, data: []const u8, timecode_ms: i64, keyframe: bool) !void {
        const a = self.allocator;
        if (!self.cluster_open or timecode_ms - self.cluster_base_ms >= CLUSTER_MAX_MS or
            (keyframe and self.cluster.items.len > 0))
        {
            try self.flushCluster();
            self.cluster_base_ms = timecode_ms;
            self.cluster_open = true;
            try elemUint(a, &self.cluster, ID_TIMECODE, @intCast(@max(0, timecode_ms)));
        }
        const rel: i64 = timecode_ms - self.cluster_base_ms;
        const rel16: i16 = @intCast(std.math.clamp(rel, -32768, 32767));

        // SimpleBlock body: track VINT, int16 BE rel timecode, flags, data.
        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(a);
        try writeVint(a, &block, TRACK_NUMBER); // track number as VINT
        try block.append(a, @intCast((@as(u16, @bitCast(rel16)) >> 8) & 0xFF));
        try block.append(a, @intCast(@as(u16, @bitCast(rel16)) & 0xFF));
        try block.append(a, if (keyframe) 0x80 else 0x00); // keyframe flag
        try block.appendSlice(a, data);
        try elemBytes(a, &self.cluster, ID_SIMPLE_BLOCK, block.items);
    }

    fn flushCluster(self: *Muxer) !void {
        if (!self.cluster_open or self.cluster.items.len == 0) {
            self.cluster.clearRetainingCapacity();
            return;
        }
        try elemBytes(self.allocator, &self.buf, ID_CLUSTER, self.cluster.items);
        self.cluster.clearRetainingCapacity();
    }

    /// Flush the final cluster and hand back the WebM bytes (caller owns).
    pub fn finish(self: *Muxer) ![]u8 {
        try self.flushCluster();
        return self.buf.toOwnedSlice(self.allocator);
    }
};

// ── EBML primitives ─────────────────────────────────────────────

fn idLen(id: u32) usize {
    if (id <= 0xFF) return 1;
    if (id <= 0xFFFF) return 2;
    if (id <= 0xFFFFFF) return 3;
    return 4;
}

fn writeId(a: std.mem.Allocator, out: *std.ArrayList(u8), id: u32) !void {
    const n = idLen(id);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        try out.append(a, @intCast((id >> @intCast(i * 8)) & 0xFF));
    }
}

/// EBML variable-length integer (size descriptor): shortest length whose
/// 7*L data bits hold `value`, with the leading marker bit set.
fn writeVint(a: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var len: usize = 1;
    while (len < 8) : (len += 1) {
        const cap = (@as(u64, 1) << @intCast(7 * len)) - 1;
        if (value < cap) break;
    }
    var v = value;
    v |= @as(u64, 1) << @intCast(7 * len); // marker bit
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        try out.append(a, @intCast((v >> @intCast(i * 8)) & 0xFF));
    }
}

fn elemBytes(a: std.mem.Allocator, out: *std.ArrayList(u8), id: u32, data: []const u8) !void {
    try writeId(a, out, id);
    try writeVint(a, out, data.len);
    try out.appendSlice(a, data);
}

fn elemStr(a: std.mem.Allocator, out: *std.ArrayList(u8), id: u32, s: []const u8) !void {
    try elemBytes(a, out, id, s);
}

fn elemUint(a: std.mem.Allocator, out: *std.ArrayList(u8), id: u32, value: u64) !void {
    // Big-endian minimal-length unsigned.
    var tmp: [8]u8 = undefined;
    var n: usize = if (value == 0) 1 else 0;
    var v = value;
    while (v > 0) : (v >>= 8) n += 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        tmp[n - 1 - i] = @intCast((value >> @intCast(i * 8)) & 0xFF);
    }
    try elemBytes(a, out, id, tmp[0..n]);
}

// ── tests ───────────────────────────────────────────────────────

test "vint encodes with marker bit and minimal length" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeVint(a, &out, 1); // fits 1 byte: 0x81
    try std.testing.expectEqual(@as(u8, 0x81), out.items[0]);
    out.clearRetainingCapacity();
    try writeVint(a, &out, 127); // 127 needs 2 bytes (1-byte cap is 127, not < )
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}

test "muxer emits a webm header with EBML magic" {
    const a = std.testing.allocator;
    var m = Muxer.init(a);
    defer m.deinit();
    try m.writeHeader(64, 48);
    try m.addFrame(&.{ 0xDE, 0xAD }, 0, true);
    try m.addFrame(&.{ 0xBE, 0xEF }, 33, false);
    const webm = try m.finish();
    defer a.free(webm);
    try std.testing.expect(webm.len > 4);
    // EBML magic 0x1A45DFA3.
    try std.testing.expectEqualSlices(u8, &.{ 0x1A, 0x45, 0xDF, 0xA3 }, webm[0..4]);
}
