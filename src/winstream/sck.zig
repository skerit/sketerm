//! ScreenCaptureKit window-stream source (Darwin only) — the real
//! backend behind winstream/source.zig's `Source.sck` arm, built
//! when build_options.winstream_sck is set (native macOS builds).
//!
//! All Darwin API work lives in sck_shim.m behind a C ABI; this
//! file translates shim events into proto units (deflating frames
//! like the stub does) and wire input into shim injection calls
//! (evdev → CGKeyCode via keymap.zig). The shim's wakeup pipe is
//! exposed as pollFd() so the daemon's poll loop reacts to frames
//! that arrive between ticks.

const std = @import("std");
const proto = @import("proto.zig");
const keymap = @import("keymap.zig");
const zpool = @import("../wlhost/zpool.zig");

const CEvent = extern struct {
    kind: u32, // 0 open, 1 frame, 2 title, 3 close
    win: u32,
    w: i32,
    h: i32,
    data: ?[*]const u8,
    len: usize,
};

extern fn sketerm_sck_create(root_pid: i32) ?*anyopaque;
extern fn sketerm_sck_destroy(ctx: *anyopaque) void;
extern fn sketerm_sck_wakeup_fd(ctx: *anyopaque) c_int;
extern fn sketerm_sck_status(ctx: *anyopaque) u32;
extern fn sketerm_sck_last_error(ctx: *anyopaque, buf: [*]u8, cap: usize) usize;
extern fn sketerm_sck_drain(ctx: *anyopaque, out_n: *usize) ?[*]const CEvent;
extern fn sketerm_sck_key(ctx: *anyopaque, win: u32, keycode: u16, down: bool, flags: u64) void;
extern fn sketerm_sck_ptr(ctx: *anyopaque, win: u32, kind: u8, x: f64, y: f64, detail: u32) void;
extern fn sketerm_sck_scroll(ctx: *anyopaque, win: u32, dx: f64, dy: f64) void;
extern fn sketerm_sck_close_win(ctx: *anyopaque, win: u32) void;
extern fn sketerm_sck_reannounce(ctx: *anyopaque) void;

const status_screen: u32 = 1;

/// Synthetic window that tells the user WHY nothing is streaming
/// when the Screen Recording grant is missing — a silent hang is
/// the one failure mode this backend must not have.
const notice_win: u32 = 0xfffffffe;
const notice_w: i32 = 520;
const notice_h: i32 = 80;
const notice_title = "sketerm: grant Screen Recording to sketerm-mux on the Mac, then restart the daemon";

pub const Source = struct {
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    zbuf: std.ArrayList(u8) = .empty,
    notice_open: bool = false,
    /// Dedupe for shim error reporting — refresh retries reproduce
    /// the same failure string every few seconds.
    last_err: [512]u8 = undefined,
    last_err_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, app_pid: i32) !Source {
        const ctx = sketerm_sck_create(app_pid) orelse return error.SckInitFailed;
        return .{ .allocator = allocator, .ctx = ctx };
    }

    pub fn deinit(self: *Source) void {
        sketerm_sck_destroy(self.ctx);
        self.zbuf.deinit(self.allocator);
    }

    pub fn pollFd(self: *const Source) c_int {
        return sketerm_sck_wakeup_fd(self.ctx);
    }

    /// A client (re)attached: replay win_open + current frame for
    /// every live window — it missed the originals.
    pub fn reannounce(self: *Source) void {
        sketerm_sck_reannounce(self.ctx);
    }

    pub fn poll(self: *Source, out: *std.ArrayList(u8), out_allocator: std.mem.Allocator, now_ms: u64) !void {
        _ = now_ms; // SCK paces frames itself (minimumFrameInterval)

        // Drain FIRST, unconditionally: it reads the wakeup pipe dry
        // (a stale readable byte would spin the daemon poll loop hot)
        // and kicks the throttled window refresh.
        var n: usize = 0;
        const evs = sketerm_sck_drain(self.ctx, &n);

        // Shim-side problems (TCC, fetch failures, stream errors)
        // land in the daemon log — once per distinct message.
        var err_buf: [512]u8 = undefined;
        const elen = sketerm_sck_last_error(self.ctx, &err_buf, err_buf.len);
        if (elen > 0 and !std.mem.eql(u8, err_buf[0..elen], self.last_err[0..self.last_err_len])) {
            std.debug.print("sketerm-mux winstream: {s}\n", .{err_buf[0..elen]});
            @memcpy(self.last_err[0..elen], err_buf[0..elen]);
            self.last_err_len = elen;
        }

        if (sketerm_sck_status(self.ctx) & status_screen == 0) {
            if (!self.notice_open) {
                self.notice_open = true;
                try proto.appendWinOpen(out, out_allocator, .{
                    .win = notice_win,
                    .w = notice_w,
                    .h = notice_h,
                    .title = notice_title,
                });
                const px = try self.allocator.alloc(u8, @intCast(notice_w * 4 * notice_h));
                defer self.allocator.free(px);
                for (0..@intCast(notice_h)) |y| {
                    for (0..@intCast(notice_w)) |x| {
                        const i = (y * @as(usize, @intCast(notice_w)) + x) * 4;
                        // Warning-yellow band on dark gray.
                        const band = y < 8 or y >= @as(usize, @intCast(notice_h)) - 8;
                        px[i + 0] = if (band) 0x00 else 0x30; // B
                        px[i + 1] = if (band) 0xc8 else 0x30; // G
                        px[i + 2] = if (band) 0xe8 else 0x30; // R
                        px[i + 3] = 0xff;
                    }
                }
                try proto.appendFrame(out, out_allocator, .{
                    .win = notice_win,
                    .w = notice_w,
                    .h = notice_h,
                    .pixels = px,
                });
            }
            return;
        }

        const list = evs orelse return;
        for (list[0..n]) |ev| {
            switch (ev.kind) {
                0 => try proto.appendWinOpen(out, out_allocator, .{
                    .win = ev.win,
                    .w = ev.w,
                    .h = ev.h,
                    .title = if (ev.data) |d| d[0..ev.len] else "remote app",
                }),
                1 => {
                    const d = ev.data orelse continue;
                    if (ev.w <= 0 or ev.h <= 0) continue;
                    const pixels = d[0..ev.len];
                    try self.zbuf.resize(self.allocator, pixels.len);
                    if (zpool.compress(pixels, self.zbuf.items)) |z| {
                        try proto.appendFrameZ(out, out_allocator, .{
                            .win = ev.win,
                            .w = ev.w,
                            .h = ev.h,
                            .raw_len = @intCast(pixels.len),
                            .z = z,
                        });
                    } else {
                        try proto.appendFrame(out, out_allocator, .{
                            .win = ev.win,
                            .w = ev.w,
                            .h = ev.h,
                            .pixels = pixels,
                        });
                    }
                },
                2 => {
                    var pbuf: [4 + 512]u8 = undefined;
                    std.mem.writeInt(u32, pbuf[0..4], ev.win, .little);
                    const tlen = @min(ev.len, 512);
                    if (ev.data) |d| @memcpy(pbuf[4 .. 4 + tlen], d[0..tlen]);
                    try proto.appendUnit(out, out_allocator, .win_title, pbuf[0 .. 4 + tlen]);
                },
                3 => {
                    var pbuf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &pbuf, ev.win, .little);
                    try proto.appendUnit(out, out_allocator, .win_close, &pbuf);
                },
                else => {},
            }
        }
    }

    pub fn handleInput(self: *Source, unit: proto.Unit) void {
        switch (unit.tag) {
            .input_key => {
                const k = proto.decodeInputKey(unit.payload) orelse return;
                const vk = keymap.evdevToCgKeycode(k.key) orelse return;
                sketerm_sck_key(self.ctx, k.win, vk, k.pressed, keymap.modsToCgFlags(k.mods));
            },
            .input_ptr => {
                const p = proto.decodeInputPtr(unit.payload) orelse return;
                if (p.win == notice_win) return;
                if (p.kind == 3) {
                    // Scroll: x/y carry the wheel deltas (lines).
                    sketerm_sck_scroll(self.ctx, p.win, p.x, p.y);
                } else {
                    sketerm_sck_ptr(self.ctx, p.win, p.kind, p.x, p.y, p.detail);
                }
            },
            .close_req => {
                if (unit.payload.len < 4) return;
                const win = std.mem.readInt(u32, unit.payload[0..4], .little);
                if (win == notice_win) return; // nothing to close on this side
                sketerm_sck_close_win(self.ctx, win);
            },
            else => {},
        }
    }
};
