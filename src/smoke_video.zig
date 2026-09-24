//! Forwarded-app VIDEO smoke (headless): a real app (mpv, software
//! `wlshm` output) plays a busy, photographic test pattern on a session's
//! Wayland display; a mux viewer that runs a REAL replica Compositor (the
//! exact decode path the GUI's wlapp uses) negotiates one codec per stage
//! and must receive `pool_vtile` tiles in THAT codec whose decoded pixels
//! look like the lossless reference. `zig build smoke-video`.
//!
//! Stages, each a fresh session and a fresh viewer connection:
//!   1. lossless  — hello offers no codec: no tile may arrive; the
//!      lossless frames give the reference colour statistics.
//!   2. legacy    — an OLD GUI's hello (`video: true`, no list) must be
//!      answered with H.264, never AV1 (compatibility contract).
//!   3. h264      — `video_codecs: ["h264"]`.
//!   4. av1       — `video_codecs: ["av1"]` (SVT-AV1 -> libavcodec/dav1d).
//! "Look right" = the decoded surface's mean colour is within a small
//! distance of the lossless mean (a channel swap, range error or garbage
//! decode is far outside it) and it still carries the pattern's noise.
//!
//! A stage whose codec this host cannot encode AND decode reports SKIP;
//! `SKETERM_SMOKE_VIDEO_REQUIRE=1` turns that into a failure.

const std = @import("std");
const c = @import("c.zig").c;
const client_mod = @import("mux/client.zig");
const muxrig = @import("smoke/muxrig.zig");
const lifetime = @import("util/lifetime.zig");
const wire = @import("mux/wire.zig");
const wlpipe = @import("wlhost/pipe.zig");
const wlcomp = @import("wlhost/compositor.zig");
const vcodec = @import("wlhost/vcodec.zig");
const build_options = @import("build_options");
const clock = @import("util/clock.zig");

const RIG = "smoke-video";

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print(RIG ++ ": FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

fn failf(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(RIG ++ ": FAIL: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const RECV_TIMEOUT = c.struct_timeval{ .tv_sec = 20, .tv_usec = 0 };

/// Test pattern: a mid-range colour (every channel far from both clip
/// points, and R != B so a BGRA/RGBA swap is visible) under strong
/// TEMPORAL noise, so every frame changes (churn: hot) and has thousands
/// of distinct colours (content: photographic).
const W = 320;
const H = 240;
const SOURCE = std.fmt.comptimePrint("av://lavfi:color=c=0x4080b0:s={d}x{d}:r=30,noise=alls=40:allf=t,format=yuv420p", .{ W, H });

const Stage = enum { lossless, legacy, h264, av1 };

const Stats = struct {
    mean: [3]f64 = .{ 0, 0, 0 },
    /// Mean absolute deviation of the green channel from its mean: the
    /// noise survived (a flat or black decode has ~0).
    spread: f64 = 0,
};

/// Viewer-side observer: every chan_data frame of the app channel goes
/// through a REAL replica compositor; the raw units are peeled on the
/// side to count tiles per codec.
const Watch = struct {
    allocator: std.mem.Allocator,
    replica: wlcomp.Compositor,
    pending: std.ArrayList(u8) = .empty,
    chan: u32 = 0,
    tiles: [3]usize = .{ 0, 0, 0 }, // indexed by Codec int (stub/h264/av1)
    other_tiles: usize = 0,
    first_tile_keyframe: ?bool = null,
    lossless_updates: usize = 0,
    last_tile: ?struct { pool: u32, offset: i32, stride: i32, w: i32, h: i32 } = null,
    /// Stats of the region the LAST tile decoded into, sampled right
    /// after the replica applied it.
    last_tile_stats: ?Stats = null,

    fn init(allocator: std.mem.Allocator) Watch {
        return .{ .allocator = allocator, .replica = newReplica(allocator) };
    }

    fn newReplica(allocator: std.mem.Allocator) wlcomp.Compositor {
        var replica = wlcomp.Compositor.init(allocator, .{}) catch fail("replica init");
        replica.lenient = true;
        return replica;
    }

    fn deinit(self: *Watch) void {
        self.replica.deinit();
        self.pending.deinit(self.allocator);
    }

    /// mpv opens a short-lived probe connection before the one that
    /// maps its window; follow the NEWEST app channel with a fresh
    /// replica (a replica serves exactly one connection, like wlapp's).
    fn follow(self: *Watch, allocator: std.mem.Allocator, id: u32) void {
        if (self.chan != 0) {
            self.replica.deinit();
            self.replica = newReplica(allocator);
            self.pending.clearRetainingCapacity();
        }
        self.chan = id;
        self.replica.conn_id = id;
    }

    fn feedFrame(self: *Watch, payload: []const u8) void {
        if (payload.len < 4) return;
        const id = wire.decodeChanId(payload) orelse return;
        if (id != self.chan) return;
        const units = payload[4..];
        // chan_data may split a unit; reassemble for the side count
        // (the replica keeps its own reassembly buffer).
        self.pending.appendSlice(self.allocator, units) catch fail("oom");
        var pos: usize = 0;
        var tile_seen = false;
        defer {
            const rem = self.pending.items.len - pos;
            std.mem.copyForwards(u8, self.pending.items[0..rem], self.pending.items[pos..]);
            self.pending.shrinkRetainingCapacity(rem);
        }
        while (true) {
            const p = (wlpipe.peelUnit(self.pending.items[pos..]) catch fail("bad pipe unit")) orelse break;
            switch (p.unit.tag) {
                .pool_vtile => {
                    const vt = wlpipe.decodePoolVtile(p.unit.payload) orelse fail("bad pool_vtile");
                    const tile = ((vcodec.peelTile(vt.blob) catch fail("bad tile")) orelse fail("truncated tile")).tile;
                    const ci: usize = @intFromEnum(tile.codec);
                    if (ci < self.tiles.len) self.tiles[ci] += 1 else self.other_tiles += 1;
                    if (self.first_tile_keyframe == null) self.first_tile_keyframe = tile.keyframe;
                    self.last_tile = .{ .pool = vt.pool, .offset = @intCast(vt.offset), .stride = @intCast(vt.row_stride), .w = tile.w, .h = tile.h };
                    tile_seen = true;
                },
                .pool_update_c, .pool_update_s => self.lossless_updates += 1,
                else => {},
            }
            pos += p.consumed;
        }
        // The real GUI decode path: pool_vtile -> vcodec decoder -> pool
        // mirror, exactly as wlapp's replica does it.
        self.replica.feed(units) catch fail("replica rejected the app stream");
        self.replica.clearOut();
        // Sample the pixels a tile just DECODED into (not whatever the
        // surface shows later, which a lossless update may have written).
        if (tile_seen) {
            const lt = self.last_tile.?;
            if (self.regionStats(lt.pool, lt.offset, lt.stride, lt.w, lt.h)) |st| self.last_tile_stats = st;
        }
    }

    fn totalTiles(self: *const Watch) usize {
        return self.tiles[0] + self.tiles[1] + self.tiles[2] + self.other_tiles;
    }

    /// Colour statistics of the largest committed surface buffer (mpv's
    /// video surface), centre half only (no edge effects).
    fn stats(self: *Watch) ?Stats {
        var best: ?wlcomp.Buffer = null;
        var it = self.replica.surfaces.valueIterator();
        while (it.next()) |s| {
            if (s.committed_buffer == 0) continue;
            const b = self.replica.buffers.get(s.committed_buffer) orelse continue;
            if (best == null or b.width * b.height > best.?.width * best.?.height) best = b;
        }
        const b = best orelse return null;
        return self.regionStats(b.pool, b.offset, b.stride, b.width, b.height);
    }

    /// Colour statistics of a w x h BGRA region of a replica pool.
    fn regionStats(self: *Watch, pool_id: u32, offset: i32, stride_: i32, w: i32, h: i32) ?Stats {
        if (w < 16 or h < 16) return null;
        const pool = self.replica.pools.getPtr(pool_id) orelse return null;
        const bytes = pool.bytes.items;
        const x0: usize = @intCast(@divTrunc(w, 4));
        const x1: usize = @intCast(@divTrunc(w * 3, 4));
        const y0: usize = @intCast(@divTrunc(h, 4));
        const y1: usize = @intCast(@divTrunc(h * 3, 4));
        const stride: usize = @intCast(stride_);
        const off: usize = @intCast(offset);
        if (off + (y1 - 1) * stride + x1 * 4 > bytes.len) return null;
        var sum = [3]f64{ 0, 0, 0 };
        var n: f64 = 0;
        for (y0..y1) |y| for (x0..x1) |x| {
            const px = bytes[off + y * stride + x * 4 ..][0..4]; // BGRA/BGRX
            sum[0] += @floatFromInt(px[2]);
            sum[1] += @floatFromInt(px[1]);
            sum[2] += @floatFromInt(px[0]);
            n += 1;
        };
        var st: Stats = .{ .mean = .{ sum[0] / n, sum[1] / n, sum[2] / n } };
        var dev: f64 = 0;
        for (y0..y1) |y| for (x0..x1) |x| {
            const g: f64 = @floatFromInt(bytes[off + y * stride + x * 4 + 1]);
            dev += @abs(g - st.mean[1]);
        };
        st.spread = dev / n;
        return st;
    }
};

fn hello(allocator: std.mem.Allocator, conn: *client_mod.Conn, stage: Stage) void {
    switch (stage) {
        .lossless => conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION, .video = false, .video_codecs = [_][]const u8{} }) catch fail("hello"),
        // Exactly what a pre-negotiation GUI sent: the bool, no list.
        .legacy => conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION, .video = true }) catch fail("hello"),
        .h264 => conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION, .video = true, .video_codecs = [_][]const u8{"h264"} }) catch fail("hello"),
        // video:false — an AV1-only viewer; the list must carry it alone.
        .av1 => conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION, .video = false, .video_codecs = [_][]const u8{"av1"} }) catch fail("hello"),
    }
    (conn.recvExpect(&.{.welcome}) catch fail("welcome")).deinit(allocator);
}

fn expectedCodec(stage: Stage) ?vcodec.Codec {
    return switch (stage) {
        .lossless => null,
        .legacy, .h264 => .h264,
        .av1 => .av1,
    };
}

/// Run one stage; returns the stats of the final frame (null = skipped).
fn runStage(allocator: std.mem.Allocator, sock_path: []const u8, stage: Stage, mpv: []const u8, reference: ?Stats) ?Stats {
    const want = expectedCodec(stage);
    if (want) |cd| {
        if (!vcodec.canEncode(cd) or !vcodec.canDecode(cd)) {
            if (c.getenv("SKETERM_SMOKE_VIDEO_REQUIRE") != null)
                failf("stage {s}: this host cannot encode+decode {s}", .{ @tagName(stage), vcodec.codecName(cd) });
            std.debug.print(RIG ++ ": SKIP stage {s}: {s} encode/decode unavailable on this host\n", .{ @tagName(stage), vcodec.codecName(cd) });
            return null;
        }
    }

    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("viewer connect");
    defer conn.deinit();
    _ = c.setsockopt(conn.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &RECV_TIMEOUT, @sizeOf(c.struct_timeval));
    hello(allocator, &conn, stage);

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "video-{s}", .{@tagName(stage)}) catch unreachable;
    const geometry = std.fmt.comptimePrint("--geometry={d}x{d}", .{ W, H });
    conn.sendJson(.spawn, .{
        .name = name,
        .argv = [_][]const u8{
            mpv,           "--no-config",   "--vo=wlshm",        "--no-audio",   "--hwdec=no",
            "--loop=inf",  "--really-quiet", "--osd-level=0",    "--no-osc",     "--border=no",
            "--no-input-default-bindings", geometry, "--keepaspect-window=no", SOURCE,
        },
        .rows = @as(u16, 10),
        .cols = @as(u16, 60),
        .app = true,
        .no_audio = true,
    }) catch fail("spawn send");
    (conn.recvExpect(&.{.ok}) catch fail("spawn ok (is mpv runnable?)")).deinit(allocator);
    conn.sendJson(.attach, .{ .name = name }) catch fail("attach send");
    (conn.recvExpect(&.{.snapshot}) catch fail("attach snapshot")).deinit(allocator);

    var watch = Watch.init(allocator);
    defer watch.deinit();

    // Pump until enough frames arrived in the expected form, or a
    // deadline. Video: >= 20 tiles (well past the churn warm-up and the
    // first keyframe); lossless: >= 60 lossless updates and 3 s.
    const start = clock.nowMs();
    const deadline_ms: i64 = 25_000;
    var have_frame = false;
    while (true) {
        const elapsed = clock.nowMs() - start;
        if (elapsed > deadline_ms) break;
        if (want != null and watch.totalTiles() >= 20) break;
        if (want == null and watch.lossless_updates >= 60 and elapsed > 3_000) break;
        const f = conn.recvFrame() catch |err| failf("stage {s}: viewer read: {s} (tiles={d} lossless={d})", .{ @tagName(stage), @errorName(err), watch.totalTiles(), watch.lossless_updates });
        defer f.deinit(allocator);
        switch (f.ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(f.payload) orelse fail("bad chan_open");
                if (open.kind == .wayland_native) watch.follow(allocator, open.id);
            },
            .chan_data => {
                watch.feedFrame(f.payload);
                have_frame = true;
            },
            .exit, .gone => failf("stage {s}: the app session ended (mpv exited?)", .{@tagName(stage)}),
            else => {},
        }
    }
    if (!have_frame) failf("stage {s}: no app channel data ever arrived", .{@tagName(stage)});

    std.debug.print(RIG ++ ": stage {s}: tiles h264={d} av1={d} other={d}, lossless updates={d}\n", .{
        @tagName(stage), watch.tiles[1], watch.tiles[2], watch.tiles[0] + watch.other_tiles, watch.lossless_updates,
    });
    if (want) |cd| {
        const got = watch.tiles[@intFromEnum(cd)];
        if (got < 20) failf("stage {s}: only {d} {s} tiles arrived (the surface never went video?)", .{ @tagName(stage), got, vcodec.codecName(cd) });
        if (watch.totalTiles() != got) failf("stage {s}: tiles in a codec the viewer did not negotiate", .{@tagName(stage)});
        if (watch.first_tile_keyframe != true) failf("stage {s}: the first tile was not a keyframe", .{@tagName(stage)});
        if (watch.replica.video_decode_errors != 0) failf("stage {s}: the viewer failed to decode {d} tile(s)", .{ @tagName(stage), watch.replica.video_decode_errors });
    } else if (watch.totalTiles() != 0) {
        fail("stage lossless: a viewer that offered no codec received video tiles");
    }

    const st = (if (want != null) watch.last_tile_stats else watch.stats()) orelse failf("stage {s}: no decoded frame to inspect", .{@tagName(stage)});
    std.debug.print(RIG ++ ": stage {s}: mean RGB ({d:.1}, {d:.1}, {d:.1}) spread {d:.1}\n", .{ @tagName(stage), st.mean[0], st.mean[1], st.mean[2], st.spread });
    if (reference) |ref| {
        var dist: f64 = 0;
        for (0..3) |i| dist = @max(dist, @abs(st.mean[i] - ref.mean[i]));
        if (dist > 12) failf("stage {s}: decoded colour is {d:.1} off the lossless reference (channel swap / range / garbage)", .{ @tagName(stage), dist });
        // Lossy coding smooths noise but must not erase it.
        if (st.spread < ref.spread * 0.25) failf("stage {s}: decoded frame lost the pattern (spread {d:.1} vs {d:.1})", .{ @tagName(stage), st.spread, ref.spread });
    } else {
        // The reference itself must be the pattern, not black or flat.
        if (st.spread < 5 or st.mean[2] < st.mean[0] + 40) fail("stage lossless: the reference frame is not the test pattern");
    }

    conn.sendJson(.kill, .{ .name = name }) catch fail("kill send");
    var rounds: usize = 0;
    while (rounds < 2000) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("read awaiting kill ok");
        defer f.deinit(allocator);
        if (f.ftype == .ok or f.ftype == .gone) break;
    }
    return st;
}

fn findMpv(buf: *[512]u8) ?[]const u8 {
    const path = std.mem.span(c.getenv("PATH") orelse return null);
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const p = std.fmt.bufPrintZ(buf, "{s}/mpv", .{dir}) catch continue;
        if (c.access(p.ptr, c.X_OK) == 0) return p;
    }
    return null;
}

pub fn main() u8 {
    if (comptime !build_options.video) {
        std.debug.print(RIG ++ ": SKIP: built without -Dvideo (codec headers were absent)\n", .{});
        return 0;
    }
    if (!lifetime.arm()) fail("lifetime fence");
    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print(RIG ++ ": FAIL — the rig leaked memory (see GPA report above)\n", .{});
        std.process.exit(1);
    };
    const allocator = gpa_state.allocator();

    var mpv_buf: [512]u8 = undefined;
    const mpv = findMpv(&mpv_buf) orelse {
        if (c.getenv("SKETERM_SMOKE_VIDEO_REQUIRE") != null) fail("mpv not found in PATH");
        std.debug.print(RIG ++ ": SKIP: mpv (the real app this rig forwards) is not installed\n", .{});
        return 0;
    };

    // The app may only reach the session's own display; the rig's
    // shell must not leak an X server or a host compositor into it.
    _ = c.unsetenv("DISPLAY");
    _ = c.setenv("SKETERM_WINSTREAM", "off", 1);

    var path_buf: [128]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&path_buf, "/tmp/skv-{d}/mux.sock", .{c.getpid()}) catch unreachable;
    const bpid = muxrig.forkBroker(RIG, sock_path);

    const reference = runStage(allocator, sock_path, .lossless, mpv, null) orelse unreachable;
    var ran: usize = 0;
    for ([_]Stage{ .legacy, .h264, .av1 }) |stage| {
        if (runStage(allocator, sock_path, stage, mpv, reference) != null) ran += 1;
    }

    {
        var ctl = client_mod.Conn.connect(allocator, sock_path) catch fail("ctl connect");
        _ = c.setsockopt(ctl.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &RECV_TIMEOUT, @sizeOf(c.struct_timeval));
        ctl.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("ctl hello");
        (ctl.recvExpect(&.{.welcome}) catch fail("ctl welcome")).deinit(allocator);
        ctl.sendFrame(.shutdown, "") catch fail("shutdown send");
        ctl.deinit();
    }
    muxrig.waitBroker(RIG, bpid, 10_000);
    std.debug.print(RIG ++ ": PASS ({d} video stage(s) + lossless reference)\n", .{ran});
    return 0;
}
