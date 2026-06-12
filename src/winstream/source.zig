//! Frame source behind the window-stream agent (daemon side).
//!
//! Backends are comptime-selected: `stub` runs on ANY OS and
//! streams an animated test pattern — it exists so the entire
//! transport + render pipeline is testable without a Mac. The real
//! ScreenCaptureKit backend lands on Darwin hardware and replaces
//! it behind the same poll/handleInput surface.

const std = @import("std");
const proto = @import("proto.zig");
const zpool = @import("../wlhost/zpool.zig");

pub const Source = struct {
    allocator: std.mem.Allocator,
    opened: bool = false,
    tick: u32 = 0,
    /// Stub reacts to input by tinting the pattern (proof the
    /// input path works end to end).
    tint: u8 = 0,
    last_frame_ms: u64 = 0,
    w: i32 = 320,
    h: i32 = 240,
    frame_buf: std.ArrayList(u8) = .empty,
    zbuf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Source {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Source) void {
        self.frame_buf.deinit(self.allocator);
        self.zbuf.deinit(self.allocator);
    }

    /// Called from the daemon poll loop: append any pending units
    /// (window lifecycle + frames) for the attached client.
    /// `now_ms`: caller's monotonic clock — frames are limited to
    /// ~10 fps regardless of poll cadence.
    pub fn poll(self: *Source, out: *std.ArrayList(u8), out_allocator: std.mem.Allocator, now_ms: u64) !void {
        if (self.opened and now_ms -| self.last_frame_ms < 100) return;
        self.last_frame_ms = now_ms;
        if (!self.opened) {
            self.opened = true;
            try proto.appendWinOpen(out, out_allocator, .{
                .win = 1,
                .w = self.w,
                .h = self.h,
                .title = "winstream stub",
            });
        }
        self.tick +%= 1;
        const w: usize = @intCast(self.w);
        const h: usize = @intCast(self.h);
        try self.frame_buf.resize(self.allocator, w * h * 4);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const i = (y * w + x) * 4;
                self.frame_buf.items[i + 0] = @truncate(x + self.tick); // B
                self.frame_buf.items[i + 1] = @truncate(y + self.tick); // G
                self.frame_buf.items[i + 2] = self.tint; // R
                self.frame_buf.items[i + 3] = 0xff;
            }
        }
        // Deflate when it shrinks (the same trade as pool updates);
        // the receiver accepts both forms.
        try self.zbuf.resize(self.allocator, self.frame_buf.items.len);
        if (zpool.compress(self.frame_buf.items, self.zbuf.items)) |z| {
            try proto.appendFrameZ(out, out_allocator, .{
                .win = 1,
                .w = self.w,
                .h = self.h,
                .raw_len = @intCast(self.frame_buf.items.len),
                .z = z,
            });
        } else {
            try proto.appendFrame(out, out_allocator, .{
                .win = 1,
                .w = self.w,
                .h = self.h,
                .pixels = self.frame_buf.items,
            });
        }
    }

    /// One unit from the client (input_* / close_req).
    pub fn handleInput(self: *Source, unit: proto.Unit) void {
        switch (unit.tag) {
            .input_key => {
                const k = proto.decodeInputKey(unit.payload) orelse return;
                if (k.pressed) self.tint +%= @truncate(k.key);
            },
            .input_ptr => {
                const p = proto.decodeInputPtr(unit.payload) orelse return;
                if (p.kind == 1) self.tint +%= 16; // button down
            },
            .close_req => self.opened = false, // stub: reopen next poll
            else => {},
        }
    }
};

// ── tests ───────────────────────────────────────────────────────

const t = std.testing;

test "stub source: open, frames, input feedback" {
    var src = Source.init(t.allocator);
    defer src.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);

    try src.poll(&out, t.allocator, 0);
    var pos: usize = 0;
    const u1_ = (try proto.peelUnit(out.items[pos..])).?;
    try t.expectEqual(proto.Tag.win_open, u1_.unit.tag);
    pos += u1_.consumed;
    const u2_ = (try proto.peelUnit(out.items[pos..])).?;
    var raw: [320 * 240 * 4]u8 = undefined;
    const r_before = frameRed(u2_.unit, &raw);

    // Key press tints the next frame.
    var inp: std.ArrayList(u8) = .empty;
    defer inp.deinit(t.allocator);
    try proto.appendInputKey(&inp, t.allocator, .{ .win = 1, .key = 30, .pressed = true, .mods = 0 });
    const iu = (try proto.peelUnit(inp.items)).?;
    src.handleInput(iu.unit);

    // Rate limit: a poll 10ms later emits nothing.
    out.clearRetainingCapacity();
    try src.poll(&out, t.allocator, 10);
    try t.expectEqual(@as(usize, 0), out.items.len);

    try src.poll(&out, t.allocator, 200);
    const u3_ = (try proto.peelUnit(out.items)).?;
    try t.expect(u3_.unit.tag == .win_frame or u3_.unit.tag == .win_frame_z); // no re-open
    try t.expect(frameRed(u3_.unit, &raw) != r_before);
}

/// Red byte of pixel 0, inflating frame_z when needed.
fn frameRed(u: proto.Unit, scratch: []u8) u8 {
    if (u.tag == .win_frame) return proto.decodeFrame(u.payload).?.pixels[2];
    const fz = proto.decodeFrameZ(u.payload).?;
    const raw = zpool.decompress(fz.z, scratch[0..fz.raw_len]) catch unreachable;
    return raw[2];
}
