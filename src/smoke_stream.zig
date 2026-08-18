//! Remote-playback smoke -- `zig build smoke-stream` (headless, no display).
//! A private daemon thread plays the "remote host"; the viewer's
//! `remotestream` GObject is driven the way GStreamer's `giostreamsrc`
//! drives it (GIO read / seek / query_info from a non-GUI thread), for
//! BOTH modes: `.transcode` (the daemon's `preview_stream` job encodes a
//! cheap fragmented MP4 spool that is read while it grows, non-seekable,
//! and must decode cleanly) and `.raw` (seekable range reads that must
//! equal the original byte for byte). SKIPs without ffmpeg.

const std = @import("std");
const c = @import("c.zig").c;
const daemon_mod = @import("mux/daemon.zig");
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
        const stream = remotestream.new(host, std.mem.span(clip.ptr), .transcode) orelse fail("new transcode stream");
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
        if (std.mem.indexOf(u8, bytes, "moof") == null) fail("spool is not fragmented (no moof)");
        // Decodable end to end: what the viewer will hand GStreamer.
        var spool_copy_buf: [160:0]u8 = undefined;
        const spool_copy = std.fmt.bufPrintZ(&spool_copy_buf, "{s}/spool.mp4", .{dir}) catch unreachable;
        writeFile(spool_copy.ptr, bytes);
        if (!run(&[_:null]?[*:0]const u8{ "ffmpeg", "-nostdin", "-v", "error", "-i", spool_copy.ptr, "-f", "null", "-", null })) fail("spool does not decode");
        std.debug.print("smoke-stream: PASS transcode ({d} -> {d} bytes, fragmented MP4, decodes)\n", .{ clip_size, bytes.len });
    }

    // ── raw mode: seekable, sized, byte-identical ────────────────
    {
        const stream = remotestream.new(host, std.mem.span(clip.ptr), .raw) orelse fail("new raw stream");
        defer c.g_object_unref(@ptrCast(stream));
        const file_stream: *c.GFileInputStream = @ptrCast(stream);
        if (c.g_seekable_can_seek(@ptrCast(stream)) == 0) fail("raw stream must be seekable");
        var err: [*c]c.GError = null;
        const info = c.g_file_input_stream_query_info(file_stream, "standard::size", null, &err) orelse fail("raw query_info");
        defer c.g_object_unref(info);
        if (@as(u64, @intCast(c.g_file_info_get_size(info))) != clip_size) fail("raw size mismatch");
        const original = blk: {
            const f = c.fopen(clip.ptr, "rb") orelse fail("open fixture");
            defer _ = c.fclose(f);
            const buf = allocator.alloc(u8, clip_size) catch fail("alloc");
            if (c.fread(buf.ptr, 1, buf.len, f) != buf.len) fail("read fixture");
            break :blk buf;
        };
        defer allocator.free(original);
        const bytes = readAllStream(allocator, stream) catch fail("raw read");
        defer allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, original)) fail("raw stream differs from the file");
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
        std.debug.print("smoke-stream: PASS raw (sized, seekable, byte-identical)\n", .{});
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
