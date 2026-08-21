//! The length-prefixed tag framing shared by every byte stream in the
//! tree: u32 little-endian length (COUNTING the tag byte), one tag
//! byte, then the payload.
//!
//! Four protocols had grown their own byte-identical copy of it --
//! the mux wire (`mux/wire.zig`), the Wayland app pipe
//! (`wlhost/pipe.zig`), the pixel-streaming pipe
//! (`winstream/proto.zig`) and the audio units (`mux/pulse.zig`) --
//! including a comment in one of them asserting its bound "matches
//! mux MAX_FRAME" with nothing enforcing the agreement. This module
//! is the declaring home for the header layout and for that bound.
//!
//! It owns the BYTES only. Each protocol keeps its own tag enum, its
//! own public wrapper name and its own result field names, because
//! those are its compatibility surface.
//!
//! Pure std: no GTK, no libc, no allocator of its own -- usable from
//! `sketerm-mux` and from the GUI alike.

const std = @import("std");

/// u32 length + u8 tag.
pub const header_size = 5;

/// The default sanity bound on one framed unit, shared by the mux
/// wire, the Wayland pipe and the audio units. Images and pool
/// updates can be chunky, so it is generous; it exists to stop a
/// corrupt length allocating or waiting for gigabytes.
///
/// `winstream/proto.zig` deliberately picks a larger one -- see there.
pub const max_frame = 16 << 20;

/// Framing bound to one tag enum and one size bound.
///
/// `Tag` must be a non-exhaustive `enum(u8)`: an unknown tag byte
/// decodes to an unnamed value that the reader skips, which is what
/// makes every one of these protocols append-only.
pub fn Framing(comptime Tag: type, comptime max: usize) type {
    comptime {
        const info = @typeInfo(Tag);
        if (info != .@"enum" or info.@"enum".tag_type != u8)
            @compileError("framing tags must be enum(u8)");
        if (max == 0 or max > std.math.maxInt(u32) - 1)
            @compileError("framing bound must fit the u32 length prefix");
    }
    return struct {
        pub const Peeled = struct {
            tag: Tag,
            payload: []const u8,
            consumed: usize,
        };

        /// Write a header for a unit whose payload is `payload_len`
        /// bytes. Split out so a helper that fuses the header with a
        /// fixed payload prefix into one buffer does not restate the
        /// layout.
        pub fn writeHeader(dst: *[header_size]u8, tag: Tag, payload_len: usize) void {
            std.mem.writeInt(u32, dst[0..4], @intCast(payload_len + 1), .little);
            dst[4] = @intFromEnum(tag);
        }

        /// Append one framed unit. All-or-nothing: a failed payload
        /// append rolls the header back, because half a unit is a
        /// corrupted stream rather than a short one.
        pub fn append(
            out: *std.ArrayList(u8),
            allocator: std.mem.Allocator,
            tag: Tag,
            payload: []const u8,
        ) error{OutOfMemory}!void {
            const start = out.items.len;
            errdefer out.shrinkRetainingCapacity(start);
            var hdr: [header_size]u8 = undefined;
            writeHeader(&hdr, tag, payload.len);
            try out.appendSlice(allocator, &hdr);
            try out.appendSlice(allocator, payload);
        }

        /// Split one unit off the front of `bytes`. Null means "need
        /// more bytes"; the payload is a VIEW into `bytes`, and
        /// `consumed` is what to drop from the stream.
        pub fn peel(bytes: []const u8) error{ Malformed, TooLong }!?Peeled {
            if (bytes.len < header_size) return null;
            const len = std.mem.readInt(u32, bytes[0..4], .little);
            if (len == 0) return error.Malformed;
            if (len > max) return error.TooLong;
            const total = 4 + @as(usize, len);
            if (bytes.len < total) return null;
            return .{
                .tag = @enumFromInt(bytes[4]),
                .payload = bytes[header_size..total],
                .consumed = total,
            };
        }
    };
}

// -- tests -------------------------------------------------------

const TestTag = enum(u8) {
    hello = 1,
    world = 7,
    _,
};

const TestFraming = Framing(TestTag, 64);

test "framing: append produces the documented header bytes" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);

    try TestFraming.append(&out, t.allocator, .world, "abc");
    // len = 4 (3 payload + tag), little-endian, then tag 7.
    try t.expectEqualSlices(u8, &.{ 0x04, 0x00, 0x00, 0x00, 0x07, 'a', 'b', 'c' }, out.items);
}

test "framing: round-trips through peel" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);

    try TestFraming.append(&out, t.allocator, .hello, "one");
    try TestFraming.append(&out, t.allocator, .world, "");
    try TestFraming.append(&out, t.allocator, @enumFromInt(200), "two");

    const a = (try TestFraming.peel(out.items)).?;
    try t.expectEqual(TestTag.hello, a.tag);
    try t.expectEqualStrings("one", a.payload);
    try t.expectEqual(@as(usize, 8), a.consumed);

    const b = (try TestFraming.peel(out.items[a.consumed..])).?;
    try t.expectEqual(TestTag.world, b.tag);
    try t.expectEqualStrings("", b.payload);
    try t.expectEqual(@as(usize, 5), b.consumed);

    const c = (try TestFraming.peel(out.items[a.consumed + b.consumed ..])).?;
    // An unknown tag decodes rather than erroring: that is what makes
    // the tag vocabularies append-only.
    try t.expectEqual(@as(u8, 200), @intFromEnum(c.tag));
    try t.expectEqualStrings("two", c.payload);

    try t.expectEqual(
        @as(?TestFraming.Peeled, null),
        try TestFraming.peel(out.items[a.consumed + b.consumed + c.consumed ..]),
    );
}

test "framing: zero length is malformed" {
    const t = std.testing;
    const bytes = [_]u8{ 0, 0, 0, 0, 1, 'x' };
    try t.expectError(error.Malformed, TestFraming.peel(&bytes));
}

test "framing: over-bound length is TooLong, not incomplete" {
    const t = std.testing;
    var bytes = [_]u8{ 0, 0, 0, 0, 1 };
    std.mem.writeInt(u32, bytes[0..4], 65, .little); // bound is 64
    try t.expectError(error.TooLong, TestFraming.peel(&bytes));

    // Exactly at the bound is legal (just incomplete here).
    std.mem.writeInt(u32, bytes[0..4], 64, .little);
    try t.expectEqual(@as(?TestFraming.Peeled, null), try TestFraming.peel(&bytes));
}

test "framing: incomplete buffers return null at every prefix length" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try TestFraming.append(&out, t.allocator, .hello, "payload");

    var n: usize = 0;
    while (n < out.items.len) : (n += 1) {
        try t.expectEqual(
            @as(?TestFraming.Peeled, null),
            try TestFraming.peel(out.items[0..n]),
        );
    }
    try t.expect((try TestFraming.peel(out.items)) != null);
}

test "framing: one whole unit plus a stray byte peels exactly one" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try TestFraming.append(&out, t.allocator, .hello, "abc");
    try out.append(t.allocator, 0xff);

    const p = (try TestFraming.peel(out.items)).?;
    try t.expectEqualStrings("abc", p.payload);
    try t.expectEqual(out.items.len - 1, p.consumed);
    // The tail alone is a truncated header, not an error.
    try t.expectEqual(
        @as(?TestFraming.Peeled, null),
        try TestFraming.peel(out.items[p.consumed..]),
    );
}

test "framing: writeHeader matches what append writes" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try TestFraming.append(&out, t.allocator, .world, "1234");

    var hdr: [header_size]u8 = undefined;
    TestFraming.writeHeader(&hdr, .world, 4);
    try t.expectEqualSlices(u8, out.items[0..header_size], &hdr);
}
