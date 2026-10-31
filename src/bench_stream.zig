//! Remote-playback behaviour over a REAL link -- `zig build bench-stream -- <host-spec>
//! <path> [mebibytes] [auto|direct|transcode] [play-kbit/s] [mp4|mkv]`. Reads through the
//! viewer's own `remotestream` GObject, optionally at a film's bitrate after the jumps
//! GStreamer's demuxer makes opening that container. Needs a host; nothing runs it unattended.

const std = @import("std");
const c = @import("c.zig").c;
const remotestream = @import("ui/remotestream.zig");
const nowUs = @import("util/clock.zig").nowUs;

/// A read taking this long is a stall a player could show as one.
const STALL_US: i64 = 250_000;

/// One read of the demuxer's open sequence; `from_end` counts back from the end of the file.
const Hop = struct { off: u64, len: usize, from_end: bool = false };

// Traced with strace under `gst-launch-1.0 playbin3` on real files of both layouts.
const OPEN_MP4 = [_]Hop{
    .{ .off = 0, .len = 8192 },
    .{ .off = 300 << 10, .len = 300 << 10, .from_end = true },
    .{ .off = 0, .len = 111 << 10 },
};
const OPEN_MKV = [_]Hop{
    .{ .off = 0, .len = 8192 },
    .{ .off = 330 << 10, .len = 330 << 10, .from_end = true },
    .{ .off = 0, .len = 65536 },
    .{ .off = 5 << 20, .len = 65536 },
    .{ .off = 0, .len = 111 << 10 },
};

fn report(err: [*c]c.GError) bool {
    std.debug.print("{s}\n", .{if (err != null) std.mem.span(err.*.message) else "unknown error"});
    return false;
}

/// Runs the open sequence.
/// @return false when a read or seek failed.
fn replayOpen(stream: *c.GInputStream, hops: []const Hop, chunk: []u8) bool {
    var err: [*c]c.GError = null;
    const info = c.g_file_input_stream_query_info(@ptrCast(stream), "standard::size", null, &err) orelse return report(err);
    defer c.g_object_unref(info);
    const size: u64 = @intCast(c.g_file_info_get_size(info));
    for (hops) |hop| {
        const off = if (hop.from_end) size -| hop.off else hop.off;
        if (c.g_seekable_seek(@ptrCast(stream), @intCast(off), c.G_SEEK_SET, null, &err) == 0) return report(err);
        var left = hop.len;
        while (left > 0) {
            const n = c.g_input_stream_read(stream, chunk.ptr, @min(left, chunk.len), null, &err);
            if (n < 0) return report(err);
            if (n == 0) return true;
            left -= @intCast(n);
        }
    }
    return c.g_seekable_seek(@ptrCast(stream), 0, c.G_SEEK_SET, null, &err) != 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len < 3) {
        std.debug.print("usage: bench-stream <host-spec> <path> [mebibytes] [auto|direct|transcode] [play-kbit/s] [mp4|mkv]\n", .{});
        return 2;
    }
    const host = std.mem.span(argv[1]);
    const path = std.mem.span(argv[2]);
    const mib: u64 = if (argv.len > 3) std.fmt.parseInt(u64, std.mem.span(argv[3]), 10) catch 64 else 64;
    const policy: remotestream.Policy = if (argv.len > 4)
        std.meta.stringToEnum(remotestream.Policy, std.mem.span(argv[4])) orelse .direct
    else
        .direct;
    // Reading at a film's bitrate instead of flat out: what a player would see.
    const play_kbps: u64 = if (argv.len > 5) std.fmt.parseInt(u64, std.mem.span(argv[5]), 10) catch 0 else 0;
    var worst_late_us: i64 = 0;

    const stream = remotestream.new(host, path, policy, 0) orelse return 1;
    defer c.g_object_unref(@ptrCast(stream));

    var chunk: [64 * 1024]u8 = undefined;
    var err: [*c]c.GError = null;
    const open_started = nowUs();
    if (argv.len > 6) {
        const hops: []const Hop = if (std.mem.eql(u8, std.mem.span(argv[6]), "mkv")) &OPEN_MKV else &OPEN_MP4;
        if (!replayOpen(stream, hops, &chunk)) {
            std.debug.print("open sequence failed\n", .{});
            return 1;
        }
        std.debug.print("demuxer open sequence: {d} ms\n", .{@divTrunc(nowUs() - open_started, 1000)});
    }
    const started = nowUs();
    var first_us: i64 = 0;
    var total: u64 = 0;
    var worst_us: i64 = 0;
    var stalls: u32 = 0;
    var stalled_us: i64 = 0;
    var mark_us = started;
    var mark_bytes: u64 = 0;
    while (total < mib << 20) {
        const before = nowUs();
        const n = c.g_input_stream_read(stream, &chunk, chunk.len, null, &err);
        const took = nowUs() - before;
        defer if (play_kbps > 0 and first_us != 0) {
            const due = started + first_us + @as(i64, @intCast(total * 8000 / play_kbps));
            const early = due - nowUs();
            if (early > 0) {
                const ts: c.struct_timespec = .{ .tv_sec = @divTrunc(early, 1_000_000), .tv_nsec = @rem(early, 1_000_000) * 1000 };
                _ = c.nanosleep(&ts, null);
            } else worst_late_us = @max(worst_late_us, -early);
        };
        if (n < 0) {
            std.debug.print("read failed after {d} bytes: {s}\n", .{ total, if (err != null) std.mem.span(err.*.message) else "?" });
            return 1;
        }
        if (n == 0) break;
        if (first_us == 0) first_us = nowUs() - started else {
            worst_us = @max(worst_us, took);
            if (took >= STALL_US) {
                stalls += 1;
                stalled_us += took;
            }
        }
        total += @intCast(n);
        const now = nowUs();
        if (now - mark_us >= 1_000_000) {
            std.debug.print("  {d:>4}s {d:>7.2} MiB/s\n", .{ @divTrunc(now - started, 1_000_000), mbps(total - mark_bytes, now - mark_us) });
            mark_us = now;
            mark_bytes = total;
        }
    }
    const elapsed = nowUs() - started - first_us;
    const d = remotestream.decision(stream);
    const s = remotestream.stats(stream);
    std.debug.print("fetched {d} MiB for {d} MiB read, {d} reconnects\n", .{ s.fetched_bytes >> 20, total >> 20, s.reconnects });
    if (play_kbps > 0) std.debug.print("played at {d} kbit/s: fell behind by {d} ms at worst\n", .{ play_kbps, @divTrunc(worst_late_us, 1000) });
    std.debug.print("{s}: first byte {d} ms, {d} MiB at {d:.2} MiB/s ({d:.0} Mbit/s), worst read {d} ms, {d} stalls totalling {d} ms, route {s}, link {d} kbit/s, file {d} kbit/s\n", .{
        host,
        @divTrunc(first_us, 1000),
        total >> 20,
        mbps(total, elapsed),
        mbps(total, elapsed) * 8.388608,
        @divTrunc(worst_us, 1000),
        stalls,
        @divTrunc(stalled_us, 1000),
        if (d) |v| @tagName(v.route) else "?",
        if (d) |v| v.link_kbps else 0,
        if (d) |v| v.bitrate_kbps else 0,
    });
    return 0;
}

fn mbps(bytes: u64, us: i64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1048576.0 / (@as(f64, @floatFromInt(@max(us, 1))) / 1e6);
}
