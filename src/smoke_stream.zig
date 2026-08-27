//! Remote-playback smoke -- `zig build smoke-stream` (headless, no display).
//! A private daemon thread plays the "remote host"; the viewer's
//! `remotestream` GObject is driven the way GStreamer's `giostreamsrc`
//! drives it (GIO read / seek / query_info from a non-GUI thread), for
//! every route: `.transcode` (the daemon's `preview_stream` job encodes a
//! cheap fragmented MP4 spool that is read while it grows, non-seekable,
//! fragments every two seconds, and must decode cleanly), `.direct`
//! (seekable range reads that must equal the original byte for byte),
//! and `.auto` over a local socket (a measured link that dwarfs the
//! bitrate, so the original). Plus the daemon's spool throttle: with the
//! lead shrunk to test size, an idle reader stops the encoder and a
//! resumed one finishes the stream. SKIPs without ffmpeg.

const std = @import("std");
const c = @import("c.zig").c;
const daemon_mod = @import("mux/daemon.zig");
const daemon_fsjobs = @import("mux/daemon_fsjobs.zig");
const fsjob = @import("mux/fsjob.zig");
const remotestream = @import("ui/remotestream.zig");

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke-stream: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

fn daemonMain(d: *daemon_mod.Daemon) void {
    d.run() catch |err| std.debug.print("smoke-stream: daemon error: {s}\n", .{@errorName(err)});
}

fn sigNoop(_: c_int) callconv(.c) void {}

fn run(argv: []const ?[*:0]const u8) bool {
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = c.execvp(argv[0].?, @ptrCast(@constCast(argv.ptr)));
        c._exit(127);
    }
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
    return c.WIFEXITED(st) and c.WEXITSTATUS(st) == 0;
}

fn readAllStream(allocator: std.mem.Allocator, stream: *c.GInputStream) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        var err: [*c]c.GError = null;
        const n = c.g_input_stream_read(stream, &chunk, chunk.len, null, &err);
        if (n < 0) {
            std.debug.print("smoke-stream: read error: {s}\n", .{if (err != null) std.mem.span(err.*.message) else "?"});
            return error.ReadFailed;
        }
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

/// Spool files under /tmp (other sketerm instances may own some, so
/// the check is before-vs-after, not zero).
fn countSpools() usize {
    var n: usize = 0;
    const dp = c.opendir("/tmp") orelse fail("opendir /tmp");
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (std.mem.startsWith(u8, name, ".sketerm-preview-") and std.mem.endsWith(u8, name, ".mp4")) n += 1;
    }
    return n;
}

fn fileSize(path: []const u8) u64 {
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return 0;
    var st: c.struct_stat = undefined;
    return if (c.stat(p.ptr, &st) == 0 and st.st_size > 0) @intCast(st.st_size) else 0;
}

fn sleepMs(ms: i64) void {
    var ts: c.struct_timespec = .{ .tv_sec = @intCast(@divTrunc(ms, 1000)), .tv_nsec = @intCast(@rem(ms, 1000) * std.time.ns_per_ms) };
    _ = c.nanosleep(&ts, null);
}

/// The newest preview spool under /tmp once more than `before` exist
/// (other sketerm instances may own older ones).
fn spoolPath(allocator: std.mem.Allocator, before: usize) ?[]u8 {
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (countSpools() > before) break;
        sleepMs(50);
    }
    const dp = c.opendir("/tmp") orelse return null;
    defer _ = c.closedir(dp);
    var newest: ?[]u8 = null;
    var newest_mtime: i64 = 0;
    while (c.readdir(dp)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.startsWith(u8, name, ".sketerm-preview-") or !std.mem.endsWith(u8, name, ".mp4")) continue;
        var z: [4096:0]u8 = undefined;
        const full = std.fmt.bufPrintZ(&z, "/tmp/{s}", .{name}) catch continue;
        var st: c.struct_stat = undefined;
        if (c.stat(full.ptr, &st) != 0) continue;
        const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
        const mtime: i64 = @as(i64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(i64, @intCast(ts.tv_nsec));
        if (newest == null or mtime > newest_mtime) {
            if (newest) |old| allocator.free(old);
            newest = allocator.dupe(u8, full) catch return null;
            newest_mtime = mtime;
        }
    }
    return newest;
}

fn writeFile(path: [*:0]const u8, bytes: []const u8) void {
    const f = c.fopen(path, "wb") orelse fail("write fixture");
    defer _ = c.fclose(f);
    if (c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) fail("write fixture bytes");
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len > 1 and std.mem.eql(u8, std.mem.span(argv[1]), "--job")) {
        var helper_gpa: std.heap.DebugAllocator(.{}) = .{};
        defer _ = helper_gpa.deinit();
        return fsjob.serve(helper_gpa.allocator());
    }
    _ = c.signal(c.SIGPIPE, &sigNoop);
    // ffmpeg is the transcoder under test AND the fixture generator.
    if (!run(&[_:null]?[*:0]const u8{ "ffmpeg", "-version", null })) {
        std.debug.print("smoke-stream: SKIP (no ffmpeg on this host)\n", .{});
        return 0;
    }
    var state_buf: [128:0]u8 = undefined;
    const state_dir = std.fmt.bufPrintZ(&state_buf, "/tmp/sketerm-smoke-stream-state-{d}", .{c.getpid()}) catch unreachable;
    _ = c.setenv("XDG_STATE_HOME", state_dir.ptr, 1);
    var cache_buf: [128:0]u8 = undefined;
    const cache_dir = std.fmt.bufPrintZ(&cache_buf, "/tmp/sketerm-smoke-stream-cache-{d}", .{c.getpid()}) catch unreachable;
    _ = c.setenv("XDG_CACHE_HOME", cache_dir.ptr, 1);

    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print("smoke-stream: FAIL -- leaked memory\n", .{});
        std.process.exit(1);
    };
    const allocator = gpa_state.allocator();

    var dir_buf: [128:0]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/sketerm-smoke-stream-{d}", .{c.getpid()}) catch unreachable;
    if (c.mkdir(dir.ptr, 0o700) != 0) fail("mkdir");
    defer {
        var cmd: [256:0]u8 = undefined;
        const rm = std.fmt.bufPrintZ(&cmd, "rm -rf {s} {s} {s}", .{ dir, state_dir, cache_dir }) catch unreachable;
        _ = c.system(rm.ptr);
    }
    // A 3-second synthetic clip with audio, big enough that the spool
    // is still growing when the first bytes are read.
    var clip_buf: [160:0]u8 = undefined;
    const clip = std.fmt.bufPrintZ(&clip_buf, "{s}/clip.mp4", .{dir}) catch unreachable;
    if (!run(&[_:null]?[*:0]const u8{
        "ffmpeg", "-nostdin", "-y",       "-v",       "error", "-f",   "lavfi", "-i", "testsrc=size=1920x1080:rate=30:duration=3",
        "-f",     "lavfi",    "-i",       "sine=frequency=440:duration=3", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-c:a",   "aac",      "-shortest", clip.ptr, null,
    })) fail("fixture ffmpeg");
    var st: c.struct_stat = undefined;
    if (c.stat(clip.ptr, &st) != 0 or st.st_size <= 0) fail("fixture stat");
    const clip_size: u64 = @intCast(st.st_size);

    var sock_buf: [160]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&sock_buf, "{s}/mux.sock", .{dir}) catch unreachable;
    const d = daemon_mod.Daemon.init(allocator, sock_path) catch fail("daemon init");
    const th = std.Thread.spawn(.{}, daemonMain, .{d}) catch fail("thread spawn");
    var host_buf: [200]u8 = undefined;
    const host = std.fmt.bufPrint(&host_buf, "sock:{s}", .{sock_path}) catch unreachable;
    const spools_before = countSpools();

    // ── transcode mode: growing spool, push-mode contract ────────
    {
        const stream = remotestream.new(host, std.mem.span(clip.ptr), .transcode, 0) orelse fail("new transcode stream");
        defer c.g_object_unref(@ptrCast(stream));
        const file_stream: *c.GFileInputStream = @ptrCast(stream);
        // Same order giostreamsrc uses at start: seekability, then size.
        if (c.g_seekable_can_seek(@ptrCast(stream)) != 0) fail("transcode stream must not be seekable");
        var err: [*c]c.GError = null;
        if (c.g_file_input_stream_query_info(file_stream, "standard::size", null, &err) != null) fail("transcode stream must not report a size");
        if (err == null) fail("transcode query_info must set an error");
        c.g_error_free(err);
        const bytes = readAllStream(allocator, stream) catch fail("transcode read");
        defer allocator.free(bytes);
        if (bytes.len < 1024) fail("transcode spool too small");
        if (!std.mem.eql(u8, bytes[4..8], "ftyp")) fail("spool is not an MP4");
        // Two-second keyframe cadence: a 3s clip yields fragments at 0
        // and 2s, so the player can start after two seconds of encode
        // rather than x264's default ten.
        if (std.mem.count(u8, bytes, "moof") < 2) fail("spool has fewer than two fragments (keyframe cadence)");
        // Decodable end to end: what the viewer will hand GStreamer.
        var spool_copy_buf: [160:0]u8 = undefined;
        const spool_copy = std.fmt.bufPrintZ(&spool_copy_buf, "{s}/spool.mp4", .{dir}) catch unreachable;
        writeFile(spool_copy.ptr, bytes);
        if (!run(&[_:null]?[*:0]const u8{ "ffmpeg", "-nostdin", "-v", "error", "-i", spool_copy.ptr, "-f", "null", "-", null })) fail("spool does not decode");
        std.debug.print("smoke-stream: PASS transcode ({d} -> {d} bytes, fragmented MP4, decodes)\n", .{ clip_size, bytes.len });
        const full_len = bytes.len;
        const dur = remotestream.durationMs(stream);
        if (dur < 2_500 or dur > 3_500) fail("transcode stream did not report the source duration (~3000ms)");
        const td = remotestream.decision(stream) orelse fail("transcode stream must publish its decision");
        if (td.route != .transcode) fail("transcode stream must report the transcode route");
        if (td.encoderName().len == 0) fail("transcode stream must name the host encoder");
        std.debug.print("smoke-stream: host encoder is {s}\n", .{td.encoderName()});

        // A time seek is a fresh encode from the offset: shorter output,
        // still a decodable fragmented MP4, same duration report.
        const seeked = remotestream.new(host, std.mem.span(clip.ptr), .transcode, 2_000) orelse fail("new seeked stream");
        defer c.g_object_unref(@ptrCast(seeked));
        const tail_bytes = readAllStream(allocator, seeked) catch fail("seeked read");
        defer allocator.free(tail_bytes);
        if (tail_bytes.len < 512 or tail_bytes.len >= full_len) fail("seeked encode is not shorter than the full one");
        if (!std.mem.eql(u8, tail_bytes[4..8], "ftyp")) fail("seeked spool is not an MP4");
        writeFile(spool_copy.ptr, tail_bytes);
        if (!run(&[_:null]?[*:0]const u8{ "ffmpeg", "-nostdin", "-v", "error", "-i", spool_copy.ptr, "-f", "null", "-", null })) fail("seeked spool does not decode");
        if (remotestream.durationMs(seeked) != dur) fail("seeked stream reports a different duration");
        std.debug.print("smoke-stream: PASS seek (encode from 2000ms: {d} bytes, decodes, duration {d}ms)\n", .{ tail_bytes.len, dur });
    }

    // ── direct route: seekable, sized, byte-identical ────────────
    {
        const stream = remotestream.new(host, std.mem.span(clip.ptr), .direct, 0) orelse fail("new direct stream");
        defer c.g_object_unref(@ptrCast(stream));
        const file_stream: *c.GFileInputStream = @ptrCast(stream);
        if (c.g_seekable_can_seek(@ptrCast(stream)) == 0) fail("direct stream must be seekable");
        var err: [*c]c.GError = null;
        const info = c.g_file_input_stream_query_info(file_stream, "standard::size", null, &err) orelse fail("raw query_info");
        defer c.g_object_unref(info);
        if (@as(u64, @intCast(c.g_file_info_get_size(info))) != clip_size) fail("direct size mismatch");
        const original = blk: {
            const f = c.fopen(clip.ptr, "rb") orelse fail("open fixture");
            defer _ = c.fclose(f);
            const buf = allocator.alloc(u8, clip_size) catch fail("alloc");
            if (c.fread(buf.ptr, 1, buf.len, f) != buf.len) fail("read fixture");
            break :blk buf;
        };
        defer allocator.free(original);
        const bytes = readAllStream(allocator, stream) catch fail("direct read");
        defer allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, original)) fail("direct stream differs from the file");
        // Seek from the end (how qtdemux finds a trailing moov), then re-read.
        if (c.g_seekable_seek(@ptrCast(stream), -100, c.G_SEEK_END, null, &err) == 0) fail("seek end");
        if (@as(u64, @intCast(c.g_seekable_tell(@ptrCast(stream)))) != clip_size - 100) fail("tell after seek");
        const tail = readAllStream(allocator, stream) catch fail("tail read");
        defer allocator.free(tail);
        if (!std.mem.eql(u8, tail, original[original.len - 100 ..])) fail("tail differs after seek");
        // Backwards inside the read-ahead window is served without a fetch.
        if (c.g_seekable_seek(@ptrCast(stream), 10, c.G_SEEK_SET, null, &err) == 0) fail("seek set");
        var head: [64]u8 = undefined;
        const n = c.g_input_stream_read(stream, &head, head.len, null, &err);
        if (n != 64 or !std.mem.eql(u8, head[0..64], original[10..74])) fail("read after seek set");
        std.debug.print("smoke-stream: PASS direct (sized, seekable, byte-identical)\n", .{});

        // ── auto route over a local socket: measured, and the original ──
        const auto = remotestream.new(host, std.mem.span(clip.ptr), .auto, 0) orelse fail("new auto stream");
        defer c.g_object_unref(@ptrCast(auto));
        if (c.g_seekable_can_seek(@ptrCast(auto)) == 0) fail("auto stream over a local socket must be seekable (direct)");
        const ad = remotestream.decision(auto) orelse fail("auto stream must publish its decision");
        if (ad.route != .direct) fail("auto route over a local socket must be direct");
        if (ad.link_kbps == 0) fail("auto route must have measured the link");
        if (ad.bitrate_kbps == 0) fail("auto route must know the source bitrate (ffprobe on the host)");
        const auto_bytes = readAllStream(allocator, auto) catch fail("auto read");
        defer allocator.free(auto_bytes);
        if (!std.mem.eql(u8, auto_bytes, original)) fail("auto (direct) stream differs from the file");
        std.debug.print("smoke-stream: PASS auto (link {d} Mbit/s vs file {d} kbit/s -> direct)\n", .{ ad.link_kbps / 1000, ad.bitrate_kbps });
    }

    // ── spool throttle: an idle reader stops the encoder ─────────
    {
        // A longer clip, so the encode outlives the check; lead shrunk to
        // what its spool reaches within the first progress events.
        var long_buf: [160:0]u8 = undefined;
        const long_clip = std.fmt.bufPrintZ(&long_buf, "{s}/long.mp4", .{dir}) catch unreachable;
        if (!run(&[_:null]?[*:0]const u8{
            "ffmpeg", "-nostdin", "-y",       "-v",       "error", "-f",   "lavfi", "-i", "testsrc=size=1920x1080:rate=30:duration=40",
            "-c:v",   "libx264",  "-preset",  "ultrafast", "-pix_fmt", "yuv420p", long_clip.ptr, null,
        })) fail("long fixture ffmpeg");
        daemon_fsjobs.spool_lead = .{ .stop = 256 * 1024, .cont = 64 * 1024 };
        defer daemon_fsjobs.spool_lead = .{ .stop = 12 << 20, .cont = 4 << 20 };
        const stream = remotestream.new(host, std.mem.span(long_clip.ptr), .transcode, 0) orelse fail("new throttled stream");
        defer c.g_object_unref(@ptrCast(stream));
        var head: [4096]u8 = undefined;
        var err: [*c]c.GError = null;
        if (c.g_input_stream_read(stream, &head, head.len, null, &err) <= 0) fail("throttled head read");
        const spool = spoolPath(allocator, spools_before) orelse fail("cannot find the throttled spool");
        defer allocator.free(spool);
        // Idle reader: the encoder runs past the lead and is stopped;
        // the spool then stops growing while the encode is far from done.
        var frozen = false;
        var attempt: usize = 0;
        while (attempt < 20 and !frozen) : (attempt += 1) {
            const a = fileSize(spool);
            sleepMs(500);
            const b = fileSize(spool);
            frozen = a == b and a > 0;
        }
        if (!frozen) fail("encoder kept writing with an idle reader (throttle did not stop it)");
        const frozen_at = fileSize(spool);
        // Resumed reader: reads advance the daemon's reader position,
        // the encoder continues and the stream completes.
        const rest = readAllStream(allocator, stream) catch fail("throttled tail read");
        defer allocator.free(rest);
        if (rest.len + head.len <= frozen_at) fail("throttled stream ended at the frozen size (encoder never resumed)");
        std.debug.print("smoke-stream: PASS throttle (frozen at {d} bytes with an idle reader, {d} bytes after resume)\n", .{ frozen_at, rest.len + head.len });
    }

    // Dropping the streams closed their connections; the daemon must
    // have killed the ephemeral encode and removed its spool.
    var tries: usize = 0;
    var spools_left: usize = countSpools();
    while (tries < 40 and spools_left > spools_before) : (tries += 1) {
        var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 100 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
        spools_left = countSpools();
    }
    if (spools_left > spools_before) fail("spool file was not cleaned up after the client went away");
    std.debug.print("smoke-stream: PASS spool cleanup\n", .{});

    {
        var conn = @import("mux/client.zig").Conn.connect(allocator, sock_path) catch fail("shutdown connect");
        defer conn.deinit();
        conn.sendFrame(.shutdown, "") catch fail("shutdown send");
    }
    th.join();
    d.deinit();
    std.debug.print("smoke-stream: PASS\n", .{});
    return 0;
}
