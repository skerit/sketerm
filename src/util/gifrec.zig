//! Animated-GIF session recorder on vendored msf_gif: feed committed
//! wl_shm frames, get a viewable .gif of what happened. Frame delays
//! come from real inter-frame arrival times (one frame is buffered,
//! since GIF stores each frame's display duration up front).

const std = @import("std");
const c = @import("../c.zig").c;
const png = @import("png.zig");

pub const Error = error{ SizeMismatch, EncodeFailed, OutOfMemory };

pub const Rec = struct {
    allocator: std.mem.Allocator,
    state: c.MsfGifState,
    /// Recording dimensions, fixed by the first frame (after any
    /// downscale). Later frames of a different size are skipped.
    w: u32 = 0,
    h: u32 = 0,
    /// Source dims the first frame had (mismatch detector).
    src_w: u32 = 0,
    src_h: u32 = 0,
    /// Longest-dimension bound applied to every frame (0 = none).
    max_dim: u32 = 0,
    /// Buffered previous frame (tightly packed RGBA) + its arrival.
    pend: ?[]u8 = null,
    pend_ms: i64 = 0,
    frames: usize = 0,
    dropped: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_dim: u32) Rec {
        return .{ .allocator = allocator, .state = std.mem.zeroes(c.MsfGifState), .max_dim = max_dim };
    }

    /// Feed one committed wl_shm frame (BGRA, stride = w*4).
    pub fn addShmFrame(self: *Rec, pixels: []const u8, w: u32, h: u32, format: u32, now_ms: i64) Error!void {
        if (w == 0 or h == 0) return;
        if (self.frames == 0 and self.pend == null) {
            self.src_w = w;
            self.src_h = h;
        } else if (w != self.src_w or h != self.src_h) {
            // Window resized mid-recording: GIF frames must share one
            // size. Skip (counted) rather than abort the recording.
            self.dropped += 1;
            return;
        }
        var rgba = png.shmToRgba(self.allocator, pixels, w, h, w * 4, format) catch
            return Error.OutOfMemory;
        var fw = w;
        var fh = h;
        const longest = @max(w, h);
        if (self.max_dim != 0 and longest > self.max_dim) {
            fw = @max(1, w * self.max_dim / longest);
            fh = @max(1, h * self.max_dim / longest);
            const small = png.downscaleRgba(self.allocator, rgba, w, h, fw, fh) catch {
                self.allocator.free(rgba);
                return Error.OutOfMemory;
            };
            self.allocator.free(rgba);
            rgba = small;
        }
        if (self.frames == 0 and self.pend == null) {
            self.w = fw;
            self.h = fh;
            if (c.msf_gif_begin(&self.state, @intCast(fw), @intCast(fh)) == 0) {
                self.allocator.free(rgba);
                return Error.EncodeFailed;
            }
        }
        try self.flushPending(now_ms);
        self.pend = rgba;
        self.pend_ms = now_ms;
    }

    fn flushPending(self: *Rec, now_ms: i64) Error!void {
        const prev = self.pend orelse return;
        defer self.allocator.free(prev);
        self.pend = null;
        // Display duration = time until the frame that replaced it,
        // in centiseconds (>=2 so fast bursts stay visible).
        const cs: c_int = @intCast(std.math.clamp(@divTrunc(now_ms - self.pend_ms, 10), 2, 500));
        if (c.msf_gif_frame(&self.state, prev.ptr, cs, 16, @intCast(self.w * 4)) == 0)
            return Error.EncodeFailed;
        self.frames += 1;
    }

    /// Emit the buffered last frame and return the finished GIF
    /// bytes (caller owns). The Rec is consumed either way.
    pub fn finish(self: *Rec, now_ms: i64) Error![]u8 {
        self.flushPending(now_ms + 500) catch {};
        const result = c.msf_gif_end(&self.state);
        defer c.msf_gif_free(result);
        if (result.data == null or self.frames == 0) return Error.EncodeFailed;
        const bytes: [*]const u8 = @ptrCast(result.data.?);
        return self.allocator.dupe(u8, bytes[0..result.dataSize]) catch Error.OutOfMemory;
    }

    /// Drop everything without producing output.
    pub fn abort(self: *Rec) void {
        if (self.pend) |p| self.allocator.free(p);
        self.pend = null;
        const result = c.msf_gif_end(&self.state);
        c.msf_gif_free(result);
    }
};

// ─── tests ──────────────────────────────────────────────────────

test "records shm frames into a valid GIF" {
    const a = std.testing.allocator;
    var rec = Rec.init(a, 0);
    var frame = [_]u8{0} ** (8 * 6 * 4);
    // Two distinct frames (solid red, then solid green in BGRA).
    for (0..48) |i| {
        frame[i * 4 + 2] = 255; // R (BGRA layout)
        frame[i * 4 + 3] = 255;
    }
    try rec.addShmFrame(&frame, 8, 6, 0, 1000);
    for (0..48) |i| {
        frame[i * 4 + 2] = 0;
        frame[i * 4 + 1] = 255; // G
    }
    try rec.addShmFrame(&frame, 8, 6, 0, 1100);
    const gif = try rec.finish(1200);
    defer a.free(gif);
    try std.testing.expect(gif.len > 6);
    try std.testing.expectEqualSlices(u8, "GIF89a", gif[0..6]);
    try std.testing.expectEqual(@as(usize, 2), rec.frames);
}

test "downscales and skips resized frames" {
    const a = std.testing.allocator;
    var rec = Rec.init(a, 4);
    var big = [_]u8{128} ** (16 * 8 * 4);
    try rec.addShmFrame(&big, 16, 8, 1, 0);
    try std.testing.expectEqual(@as(u32, 4), rec.w);
    try std.testing.expectEqual(@as(u32, 2), rec.h);
    // A frame with different source dims is dropped, not fatal.
    try rec.addShmFrame(big[0 .. 8 * 8 * 4], 8, 8, 1, 50);
    try std.testing.expectEqual(@as(usize, 1), rec.dropped);
    try rec.addShmFrame(&big, 16, 8, 1, 100);
    const gif = try rec.finish(200);
    defer a.free(gif);
    try std.testing.expectEqualSlices(u8, "GIF89a", gif[0..6]);
}
