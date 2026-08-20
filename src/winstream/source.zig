//! Frame source behind the window-stream agent (daemon side).
//!
//! Two backends behind one `poll`/`handleInput` surface:
//!
//! - `Stub` runs on ANY OS and streams an animated test pattern —
//!   it exists so the entire transport + render pipeline is
//!   testable without a Mac (SKETERM_WINSTREAM=stub/all).
//! - `Sck` is the real ScreenCaptureKit capture + CGEvent input
//!   backend (sck.zig + sck_shim.m), compiled only when
//!   build_options.winstream_sck is set (native macOS builds).
//!
//! `Source` is the tagged dispatch the daemon holds; the SCK arm
//! collapses to `void` on builds without the backend so nothing
//! Darwin ever reaches Linux or musl-cross targets.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const proto = @import("proto.zig");
const zpool = @import("../wlhost/zpool.zig");
const pixcodec = @import("../wlhost/pixcodec.zig");

pub const have_sck = builtin.os.tag == .macos and build_options.winstream_sck;
const SckImpl = if (have_sck) @import("sck.zig").Source else void;

/// How an SCK source behaves when the Screen Recording grant is
/// missing. Split out because the two cases are genuinely different
/// users: one asked to stream, the other never did.
pub const SckOpts = struct {
    /// This session ASKED to stream (`sketerm app`, an explicit
    /// winstream request, or an explicit SKETERM_WINSTREAM value), so a
    /// missing grant is a visible failure it must report as a notice
    /// window. False for a session the macOS auto gate armed on its
    /// own: capture is still attempted (that registers the binary in
    /// System Settings, the only route to a grant), but the refusal
    /// goes to the daemon log rather than opening a window nobody
    /// asked for.
    notice_on_denied: bool = false,
};

pub const Source = union(enum) {
    stub: Stub,
    sck: SckImpl,

    pub fn initStub(allocator: std.mem.Allocator) Source {
        return .{ .stub = Stub.init(allocator) };
    }

    /// Real capture of the app rooted at `app_pid` (the session's
    /// PTY child) — windows of that process and its descendants.
    pub fn initSck(allocator: std.mem.Allocator, app_pid: i32, opts: SckOpts) !Source {
        if (comptime have_sck) {
            return .{ .sck = try SckImpl.init(allocator, app_pid, opts.notice_on_denied) };
        }
        return error.Unsupported;
    }

    pub fn deinit(self: *Source) void {
        switch (self.*) {
            .stub => |*s| s.deinit(),
            .sck => |*s| if (comptime have_sck) s.deinit(),
        }
    }

    /// Called from the daemon poll loop: append any pending units
    /// (window lifecycle + frames) for the attached client.
    pub fn poll(self: *Source, out: *std.ArrayList(u8), out_allocator: std.mem.Allocator, now_ms: u64) !void {
        switch (self.*) {
            .stub => |*s| try s.poll(out, out_allocator, now_ms),
            .sck => |*s| if (comptime have_sck) try s.poll(out, out_allocator, now_ms),
        }
    }

    /// One unit from the client (input_* / close_req).
    pub fn handleInput(self: *Source, unit: proto.Unit) void {
        switch (self.*) {
            .stub => |*s| s.handleInput(unit),
            .sck => |*s| if (comptime have_sck) s.handleInput(unit),
        }
    }

    /// fd the daemon adds to its poll set so out-of-band frame
    /// arrival (SCK delivers on its own dispatch queues) ends the
    /// poll wait early. -1 = none (the stub paces itself off the
    /// tick cadence).
    pub fn pollFd(self: *const Source) c_int {
        return switch (self.*) {
            .stub => -1,
            .sck => |*s| if (comptime have_sck) s.pollFd() else -1,
        };
    }

    /// A client (re)attached its winstream channel: replay window
    /// lifecycle so it doesn't start from frames-without-windows.
    pub fn reannounce(self: *Source) void {
        switch (self.*) {
            .stub => |*s| s.opened = false, // re-opens on next poll
            .sck => |*s| if (comptime have_sck) s.reannounce(),
        }
    }

    /// The attached client's H.264 decode capability — gates the lossy
    /// video route (hot + photographic windows → win_vtile). The stub
    /// never encodes video, so it just records the flag.
    pub fn setWantsVideo(self: *Source, wants: bool) void {
        switch (self.*) {
            .stub => |*s| s.wants_video = wants,
            .sck => |*s| if (comptime have_sck) s.setWantsVideo(wants),
        }
    }
};

pub const Stub = struct {
    allocator: std.mem.Allocator,
    opened: bool = false,
    tick: u32 = 0,
    /// Stub reacts to input by tinting the pattern (proof the
    /// input path works end to end).
    tint: u8 = 0,
    /// Recorded for parity with the SCK source; the stub always streams
    /// lossless (it has no encoder).
    wants_video: bool = false,
    last_frame_ms: u64 = 0,
    w: i32 = 320,
    h: i32 = 240,
    frame_buf: std.ArrayList(u8) = .empty,
    zbuf: std.ArrayList(u8) = .empty,
    sc: pixcodec.Scratch = .{},

    pub fn init(allocator: std.mem.Allocator) Stub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Stub) void {
        self.frame_buf.deinit(self.allocator);
        self.zbuf.deinit(self.allocator);
        self.sc.deinit(self.allocator);
    }

    /// `now_ms`: caller's monotonic clock — frames are limited to
    /// ~10 fps regardless of poll cadence.
    pub fn poll(self: *Stub, out: *std.ArrayList(u8), out_allocator: std.mem.Allocator, now_ms: u64) !void {
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
        const enc = pixcodec.encodeRegion(&self.sc, self.allocator, self.frame_buf.items, @intCast(self.w * 4)) catch
            pixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = self.frame_buf.items };
        try proto.appendWinFrameC(out, out_allocator, 1, self.w, self.h, enc);
    }

    pub fn handleInput(self: *Stub, unit: proto.Unit) void {
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

test "stub source: open, frames, input feedback (via Source dispatch)" {
    var src = Source.initStub(t.allocator);
    defer src.deinit();
    try t.expectEqual(@as(c_int, -1), src.pollFd());
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
    try t.expectEqual(proto.Tag.win_frame_c, u3_.unit.tag); // no re-open
    try t.expect(frameRed(u3_.unit, &raw) != r_before);
}

/// Red byte of pixel 0, reconstructing the shared-codec body.
fn frameRed(u: proto.Unit, scratch: []u8) u8 {
    const fc = proto.decodeWinFrameC(u.payload).?;
    pixcodec.decodeBody(fc.body, scratch[0..fc.body.raw_len]) catch unreachable;
    return scratch[2];
}
