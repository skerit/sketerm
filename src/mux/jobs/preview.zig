//! Preview jobs: thumbnails, previews, transport transcodes and streamed video previews.

const std = @import("std");
const c = @import("../../c.zig").c;
const atomicwrite = @import("../../util/atomicwrite.zig");
const png = @import("../../util/png.zig");
const imagecodec = @import("../../util/imagecodec.zig");
const pathz = @import("../../util/pathz.zig");
const thumbs = @import("../../filebrowser/thumbs.zig");
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;
const common = @import("common.zig");
const runArgv = common.runArgv;
const extIs = common.extIs;
const binaryExists = common.binaryExists;
const ffprobeEntries = common.ffprobeEntries;
const pdfinfoText = common.pdfinfoText;

/// `runArgv` with the child's stdout/stderr discarded: for probes whose
/// expected failure output is noise in the daemon log.
fn runArgvQuiet(argv: []const ?[*:0]const u8) bool {
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        const null_fd = c.open("/dev/null", c.O_RDWR);
        if (null_fd >= 0) {
            _ = c.dup2(null_fd, 1);
            _ = c.dup2(null_fd, 2);
            _ = c.close(null_fd);
        }
        _ = c.execvp(argv[0].?, @ptrCast(@constCast(argv.ptr)));
        c._exit(127);
    }
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
    return c.WIFEXITED(st) and c.WEXITSTATUS(st) == 0;
}

/// ffprobe entry selection used by the properties dialog's media info.
const FFPROBE_PREVIEW_ENTRIES = "format=duration:format_tags=title,artist,album";

fn rasterThumbnail(allocator: std.mem.Allocator, source: [:0]const u8, output: [:0]const u8, bound: c_int) bool {
    const img = loadScaledRgba(allocator, source, @intCast(bound)) orelse return false;
    defer img.deinit(allocator);
    const w: c_int = @intCast(img.w);
    return c.stbi_write_png(output.ptr, w, @intCast(img.h), 4, img.rgba.ptr, w * 4) != 0;
}

/// Must match the GUI's PREVIEW_IMAGE_CAP: reads refuse larger assets.
const TRANSPORT_BYTE_CAP: usize = 2 << 20;

const PngSink = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    failed: bool = false,
};

fn pngSinkWrite(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const sink: *PngSink = @ptrCast(@alignCast(ctx.?));
    if (sink.failed or size <= 0) return;
    const chunk = @as([*]const u8, @ptrCast(data.?))[0..@intCast(size)];
    sink.buf.appendSlice(sink.allocator, chunk) catch {
        sink.failed = true;
    };
}

/// A decoded, bound-scaled RGBA image with its backing storage.
const ScaledRgba = struct {
    rgba: []const u8,
    w: u32,
    h: u32,
    pixels: ?*anyopaque,
    scaled: ?[]u8,

    fn deinit(self: *const ScaledRgba, allocator: std.mem.Allocator) void {
        if (self.scaled) |b| allocator.free(b);
        if (self.pixels) |p| c.stbi_image_free(p);
    }
};

/// Decode `source_path` and scale it down to fit `bound` px; the longest side lands exactly on `bound`.
fn loadScaledRgba(allocator: std.mem.Allocator, source_path: []const u8, bound: u32) ?ScaledRgba {
    var pz: [4096:0]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pz, "{s}", .{source_path}, 0) catch return null;
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = c.stbi_load(path.ptr, &width, &height, &channels, 4) orelse return null;
    var owned = true;
    defer if (owned) c.stbi_image_free(pixels);
    if (width <= 0 or height <= 0) return null;
    const max_dim = @max(width, height);
    const out_w: u32 = if (max_dim > bound)
        @intFromFloat(@max(1.0, @as(f64, @floatFromInt(width)) * @as(f64, @floatFromInt(bound)) / @as(f64, @floatFromInt(max_dim))))
    else
        @intCast(width);
    const out_h: u32 = if (max_dim > bound)
        @intFromFloat(@max(1.0, @as(f64, @floatFromInt(height)) * @as(f64, @floatFromInt(bound)) / @as(f64, @floatFromInt(max_dim))))
    else
        @intCast(height);
    const pixels_len = std.math.mul(usize, @intCast(width), @intCast(height)) catch return null;
    const src_len = std.math.mul(usize, pixels_len, 4) catch return null;
    const src = @as([*]const u8, @ptrCast(pixels))[0..src_len];
    const scaled: ?[]u8 = if (out_w != width or out_h != height)
        png.downscaleRgba(allocator, src, @intCast(width), @intCast(height), out_w, out_h) catch return null
    else
        null;
    owned = false;
    return .{
        .rgba = scaled orelse src,
        .w = out_w,
        .h = out_h,
        .pixels = pixels,
        .scaled = scaled,
    };
}

/// Transcode a host-local image into the receiver's best transport codec.
fn transportPreview(
    job: *const Job,
    source_path: []const u8,
    codecs: []const u8,
    bound: u32,
    out_path: *[4096:0]u8,
) ?[]const u8 {
    const allocator = job.allocator;
    if (codecs.len == 0) return null;
    const img = loadScaledRgba(allocator, source_path, bound) orelse return null;
    defer img.deinit(allocator);
    const rgba = img.rgba;
    const out_w = img.w;
    const out_h = img.h;
    // Prefer the compact codecs; PNG is the always-available last
    // resort (stb encoder is compiled in — a host without
    // libjxl/libwebp, or a static mux-portable whose dlopen can never
    // load them, still previews). A local receiver lists only "png",
    // so local previews keep skipping the transcode entirely.
    var png_sink = PngSink{ .allocator = allocator };
    defer png_sink.buf.deinit(allocator);
    var jx_bytes: ?[]u8 = null;
    defer if (jx_bytes) |b| allocator.free(b);
    var bytes: []const u8 = undefined;
    var ext: []const u8 = undefined;
    if (imagecodec.encodePreferred(allocator, rgba, out_w, out_h, codecs, TRANSPORT_BYTE_CAP)) |encoded| {
        jx_bytes = encoded.bytes;
        bytes = encoded.bytes;
        ext = switch (encoded.codec) {
            .jxl => "jxl",
            .webp => "webp",
        };
    } else |_| {
        if (!imagecodec.wanted(codecs, "png")) return null;
        if (c.stbi_write_png_to_func(&pngSinkWrite, @ptrCast(&png_sink), @intCast(out_w), @intCast(out_h), 4, rgba.ptr, @intCast(out_w * 4)) == 0 or
            png_sink.failed or png_sink.buf.items.len > TRANSPORT_BYTE_CAP) return null;
        bytes = png_sink.buf.items;
        ext = "png";
    }
    var random: [8]u8 = undefined;
    if (c.getentropy(&random, random.len) != 0) {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        std.mem.writeInt(u64, &random, (@as(u64, @intCast(c.getpid())) << 32) ^ @as(u32, @intCast(ts.tv_nsec)), .little);
    }
    const nonce = std.mem.readInt(u64, &random, .little);
    // Under /tmp (not next to the source): a daemon killed between
    // asset and cleanup would otherwise orphan sidecars permanently
    // inside the freedesktop thumbnail cache; /tmp dies at boot.
    const out = std.fmt.bufPrintSentinel(out_path, "/tmp/.sketerm-preview-{x}.{s}", .{ nonce, ext }, 0) catch return null;
    const fd = c.open(out.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return null;
    var open = true;
    defer {
        if (open) {
            _ = c.close(fd);
            _ = c.unlink(out.ptr);
        }
    }
    // Register the exclusive pathname before writing so cancellation
    // cannot leave a partial sidecar once the daemon has seen it.
    job.emit(.{ .ev = "asset", .path = out });
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return null;
        off += @intCast(n);
    }
    if (c.fsync(fd) != 0 or c.close(fd) != 0) return null;
    open = false;
    return out;
}

/// Resize/transcode a previewer-owned image without installing a cache entry.
pub fn runPreviewTransport(job: *const Job) u8 {
    const spec = job.spec;
    var source_z: [4096:0]u8 = undefined;
    const source = std.fmt.bufPrintSentinel(&source_z, "{s}", .{spec.src}, 0) catch return job.emitError("preview path too long");
    defer {
        if (spec.delete_source) _ = c.unlink(source.ptr);
    }
    var transport_buf: [4096:0]u8 = undefined;
    const transport = transportPreview(job, spec.src, spec.image_codecs, 512, &transport_buf) orelse
        return job.emitError("no accepted preview codec (jxl/webp/png) or output over the 2 MiB cap");
    job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = transport });
    return 0;
}

/// Where preview spools live; the daemon recognises reads of them by
/// this prefix to throttle the encoder behind the reader.
pub const SPOOL_PREFIX = "/tmp/.sketerm-preview-";

/// Bytes a spool must hold before it is announced to the client: past
/// the fragmented-MP4 header (a few hundred bytes of ftyp + empty
/// moov) and into the first fragment, so a hardware encoder that fails
/// before producing one can be replaced by software into the SAME
/// spool without the client having read a header that no longer
/// matches.
const SPOOL_ANNOUNCE_BYTES: u64 = 16 * 1024;

/// Preview keyframe cadence in seconds. `frag_keyframe` closes a
/// fragment at every keyframe, and the player cannot start before the
/// first fragment lands, so this is the start-up latency of a
/// transcode (x264's default 250-frame GOP made it ten seconds).
const PREVIEW_GOP_SECONDS = "2";

pub const PreviewEncoder = enum {
    x264,
    vaapi,

    pub fn name(self: PreviewEncoder) []const u8 {
        return @tagName(self);
    }
};

const VAAPI_DEVICE = "/dev/dri/renderD128";

/// The host can encode H.264 on its GPU: the render node is usable AND
/// a one-frame test encode goes through (a present-but-broken driver
/// is common; `-encoders` listing h264_vaapi proves nothing).
fn vaapiUsable() bool {
    if (c.access(VAAPI_DEVICE, c.R_OK | c.W_OK) != 0) return false;
    const argv = [_:null]?[*:0]const u8{
        "ffmpeg", "-nostdin",             "-v",   "error",                     "-vaapi_device", VAAPI_DEVICE,
        "-f",     "lavfi",                "-i",   "color=c=black:s=64x64:r=1", "-frames:v",     "1",
        "-vf",    "format=nv12,hwupload", "-c:v", "h264_vaapi",                "-f",            "null",
        "-",      null,
    };
    return runArgvQuiet(&argv);
}

/// The encode command for one spool. Both encoders share the input
/// seek, the stream maps, the width cap, the keyframe cadence, the
/// audio and the fragmented-MP4 muxing; they differ in the video
/// filter tail and the codec block.
fn previewStreamArgv(buf: *[64]?[*:0]const u8, encoder: PreviewEncoder, ss: [*:0]const u8, source: [*:0]const u8, out: [*:0]const u8) [:null]?[*:0]const u8 {
    var n: usize = 0;
    const push = struct {
        fn f(b: *[64]?[*:0]const u8, i: *usize, args: []const [*:0]const u8) void {
            for (args) |a| {
                b[i.*] = a;
                i.* += 1;
            }
        }
    }.f;
    push(buf, &n, &.{ "ffmpeg", "-nostdin", "-y", "-v", "error" });
    if (encoder == .vaapi) push(buf, &n, &.{ "-vaapi_device", VAAPI_DEVICE });
    push(buf, &n, &.{ "-ss", ss, "-i", source, "-map", "0:v:0", "-map", "0:a:0?" });
    switch (encoder) {
        .x264 => push(buf, &n, &.{
            "-vf",      PREVIEW_STREAM_VF, "-c:v",     "libx264", "-preset",       "ultrafast",
            "-tune",    "zerolatency",     "-crf",     "28",      "-maxrate",      "2500k",
            "-bufsize", "5000k",           "-pix_fmt", "yuv420p", "-sc_threshold", "0",
        }),
        .vaapi => push(buf, &n, &.{
            "-vf", PREVIEW_STREAM_VF ++ ",format=nv12,hwupload", "-c:v", "h264_vaapi", "-qp", "26", "-bf", "0",
        }),
    }
    push(buf, &n, &.{
        "-force_key_frames", "expr:gte(t,n_forced*" ++ PREVIEW_GOP_SECONDS ++ ")",
        "-c:a",              "aac",
        "-b:a",              "128k",
        "-ac",               "2",
        "-movflags",         "frag_keyframe+empty_moov+default_base_moof",
        "-f",                "mp4",
        out,
    });
    buf[n] = null;
    return buf[0..n :null];
}

fn spawnArgv(argv: [:null]?[*:0]const u8) c.pid_t {
    const pid = c.fork();
    if (pid == 0) {
        _ = c.execvp(argv[0].?, @ptrCast(@constCast(argv.ptr)));
        c._exit(127);
    }
    return pid;
}

fn fileSize(path: [*:0]const u8) u64 {
    var st: c.struct_stat = undefined;
    return if (c.stat(path, &st) == 0 and st.st_size > 0) @intCast(st.st_size) else 0;
}

/// Cheap remote playback: transcode a video into a low-bitrate,
/// capped-width fragmented MP4 spool under /tmp, growing while the
/// viewer plays it. Registered as an `asset` (the daemon unlinks it once
/// the job dies or the client goes), and its path rides the first
/// progress event -- sent once the first fragment exists -- so the viewer
/// starts reading as soon as there is something playable. ffmpeg runs in
/// this helper's process group, so a client that disconnects kills the
/// encode with the helper, and the daemon SIGSTOPs the group when the
/// spool runs far ahead of the reader.
pub fn runPreviewStream(job: *const Job) u8 {
    const spec = job.spec;
    var source_z: [4096:0]u8 = undefined;
    const source = std.fmt.bufPrintSentinel(&source_z, "{s}", .{spec.src}, 0) catch return job.emitError("preview path too long");
    var st: c.struct_stat = undefined;
    if (c.stat(source.ptr, &st) != 0) return job.emitErrno("preview stat");
    if (!binaryExists("ffmpeg")) return job.emitErrorKind("no_encoder", "ffmpeg is not installed on this host");
    var random: [8]u8 = undefined;
    if (c.getentropy(&random, random.len) != 0) {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        std.mem.writeInt(u64, &random, (@as(u64, @intCast(c.getpid())) << 32) ^ @as(u32, @intCast(ts.tv_nsec)), .little);
    }
    var out_z: [4096:0]u8 = undefined;
    const out = std.fmt.bufPrintSentinel(&out_z, SPOOL_PREFIX ++ "{x}.mp4", .{std.mem.readInt(u64, &random, .little)}, 0) catch
        return job.emitError("spool path too long");
    // Create it ourselves (exclusive, private) so the name is claimed
    // and registered before ffmpeg starts writing.
    const fd = c.open(out.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return job.emitErrno("spool create");
    _ = c.close(fd);
    job.emit(.{ .ev = "asset", .path = out });
    // Duration up front (ffprobe, when present) so the viewer can show a
    // seekable timeline before the encode is anywhere near done.
    const duration_ms = probeDurationMs(source.ptr);
    // A time seek is a fresh job from `start_ms`: input seeking (-ss
    // before -i) lands on the keyframe at or before it, cheaply.
    var ss_buf: [32:0]u8 = undefined;
    const ss = std.fmt.bufPrintSentinel(&ss_buf, "{d}.{d:0>3}", .{ spec.start_ms / 1000, spec.start_ms % 1000 }, 0) catch unreachable;
    const total: u64 = @intCast(st.st_size);
    var encoder: PreviewEncoder = if (vaapiUsable()) .vaapi else .x264;
    var argv_buf: [64]?[*:0]const u8 = undefined;
    var pid = spawnArgv(previewStreamArgv(&argv_buf, encoder, ss.ptr, source.ptr, out.ptr));
    if (pid < 0) {
        _ = c.unlink(out.ptr);
        return job.emitErrno("fork");
    }
    var announced = false;
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, c.WNOHANG);
        if (rc < 0 and std.posix.errno(rc) != .INTR) {
            _ = c.kill(pid, c.SIGKILL);
            return job.emitErrno("waitpid");
        }
        const exited = rc == pid;
        const ok = exited and c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0;
        const written = fileSize(out.ptr);
        if (!announced) {
            if (exited and !ok and encoder == .vaapi) {
                // The GPU path refused this file before the client saw
                // a byte: redo it in software into the same spool.
                encoder = .x264;
                const tfd = c.open(out.ptr, c.O_WRONLY | c.O_TRUNC | c.O_CLOEXEC);
                if (tfd >= 0) _ = c.close(tfd);
                pid = spawnArgv(previewStreamArgv(&argv_buf, encoder, ss.ptr, source.ptr, out.ptr));
                if (pid < 0) return job.emitErrno("fork");
                continue;
            }
            if (!exited and written <= SPOOL_ANNOUNCE_BYTES) {
                var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 50 * std.time.ns_per_ms };
                _ = c.nanosleep(&ts, null);
                continue;
            }
            announced = true;
        }
        // The viewer starts reading at the first of these; every later
        // one repeats the path and reports the spool's growth.
        job.emit(.{ .ev = "progress", .path = out, .done = written, .total = total, .duration_ms = duration_ms, .encoder = encoder.name() });
        if (exited) {
            if (!ok) return job.emitError("ffmpeg could not transcode this file");
            break;
        }
        var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 250 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
    const written = fileSize(out.ptr);
    job.emit(.{ .ev = "done", .path = out, .done = written, .total = written, .encoder = encoder.name() });
    return 0;
}

/// Width capped at 1280 (never upscaled), height follows the aspect and
/// stays even for yuv420p.
const PREVIEW_STREAM_VF = "scale=w='min(1280,iw)':h=-2";

test "previewStreamArgv: both encoders share the cadence, the audio and the fragmented muxing" {
    const t = std.testing;
    var buf: [64]?[*:0]const u8 = undefined;
    inline for (.{ PreviewEncoder.x264, PreviewEncoder.vaapi }) |enc| {
        const argv = previewStreamArgv(&buf, enc, "1.500", "/v/in.mkv", "/tmp/out.mp4");
        var joined: [2048]u8 = undefined;
        var w = std.Io.Writer.fixed(&joined);
        for (argv) |a| w.print("{s} ", .{a.?}) catch unreachable;
        const line = w.buffered();
        try t.expect(std.mem.indexOf(u8, line, "-ss 1.500 -i /v/in.mkv ") != null);
        try t.expect(std.mem.indexOf(u8, line, "-force_key_frames expr:gte(t,n_forced*2) ") != null);
        try t.expect(std.mem.indexOf(u8, line, "frag_keyframe+empty_moov+default_base_moof") != null);
        try t.expect(std.mem.indexOf(u8, line, "-c:a aac ") != null);
        try t.expect(std.mem.endsWith(u8, line, "-f mp4 /tmp/out.mp4 "));
        try t.expectEqual(enc == .vaapi, std.mem.indexOf(u8, line, "h264_vaapi") != null);
        try t.expectEqual(enc == .vaapi, std.mem.indexOf(u8, line, "-vaapi_device") != null);
        try t.expectEqual(enc == .x264, std.mem.indexOf(u8, line, "libx264") != null);
        try t.expectEqual(argv.len, std.mem.count(u8, line, " "));
    }
}

/// The container duration in ms via ffprobe; 0 when unknown (no
/// ffprobe, or a stream without one), which the viewer shows as an
/// unseekable timeline.
fn probeDurationMs(source: [*:0]const u8) u64 {
    var out: [512]u8 = undefined;
    const n = ffprobeEntries(source, "format=duration", &out);
    return parseDurationMs(out[0..n]);
}

/// "duration=83.456\n" -> 83456. Tolerates ffprobe's N/A and noise.
fn parseDurationMs(text: []const u8) u64 {
    const key = "duration=";
    const at = std.mem.indexOf(u8, text, key) orelse return 0;
    var rest = text[at + key.len ..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| rest = rest[0..nl];
    rest = std.mem.trim(u8, rest, " \t\r");
    const secs = std.fmt.parseFloat(f64, rest) catch return 0;
    if (!(secs > 0) or secs > 1e9) return 0;
    return @intFromFloat(secs * 1000.0);
}

test "parseDurationMs reads ffprobe output and rejects N/A" {
    try std.testing.expectEqual(@as(u64, 83456), parseDurationMs("duration=83.456\n"));
    try std.testing.expectEqual(@as(u64, 0), parseDurationMs("duration=N/A\n"));
    try std.testing.expectEqual(@as(u64, 0), parseDurationMs(""));
}

const image_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".jxl", ".bmp", ".tif", ".tiff", ".ico", ".svg", ".avif", ".heic", ".heif" };
const pdf_exts = [_][]const u8{".pdf"};
const video_exts = @import("../../filebrowser/paths.zig").video_exts;
const audio_exts = @import("../../filebrowser/paths.zig").audio_exts;

/// This host's XDG cache root ("/tmp" as the last resort).
fn cacheRootDir(buf: []u8) []const u8 {
    if (c.getenv("XDG_CACHE_HOME")) |p|
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    if (c.getenv("HOME")) |p|
        return std.fmt.bufPrint(buf, "{s}/.cache", .{std.mem.span(@as([*:0]const u8, @ptrCast(p)))}) catch "/tmp";
    return "/tmp";
}

/// True when `path` is a file with bytes in it.
fn fileHasBytes(path: [*:0]const u8) bool {
    var st: c.struct_stat = undefined;
    if (c.stat(path, &st) != 0) return false;
    return st.st_size > 0;
}

/// Grab a video's poster frame into `raw`, one second in.
///
/// ffmpeg exits 0 when a seek lands past the end of a short clip and
/// writes no output file at all, so success is decided by the OUTPUT,
/// not by the exit status; a missing frame retries from the start.
/// Retrying is cheaper than clamping the seek to a probed duration:
/// it costs a second ffmpeg only for the rare sub-second clip, where
/// a clamp would cost an ffprobe on every single video preview.
fn videoPosterPng(source: [:0]const u8, raw: [:0]const u8, vf: [:0]const u8) bool {
    const seek = [_:null]?[*:0]const u8{ "ffmpeg", "-y", "-v", "error", "-ss", "1", "-i", source.ptr, "-frames:v", "1", "-vf", vf.ptr, raw.ptr, null };
    if (runArgv(&seek) and fileHasBytes(raw.ptr)) return true;
    const start = [_:null]?[*:0]const u8{ "ffmpeg", "-y", "-v", "error", "-i", source.ptr, "-frames:v", "1", "-vf", vf.ptr, raw.ptr, null };
    return runArgv(&start) and fileHasBytes(raw.ptr);
}

/// Generate a raw (uninstalled) thumbnail PNG for `src_path` at
/// `raw`, bounded to `bound` px. @return false when no generator on
/// this host could produce it.
fn generateThumbPng(allocator: std.mem.Allocator, src_path: []const u8, source: [:0]const u8, raw: [:0]const u8, bound: c_int) bool {
    var generated = false;
    if (extIs(src_path, &image_exts)) {
        if (extIs(src_path, &[_][]const u8{".svg"})) {
            var size_buf: [16:0]u8 = undefined;
            const size = std.fmt.bufPrintSentinel(&size_buf, "{d}", .{bound}, 0) catch unreachable;
            const argv = [_:null]?[*:0]const u8{ "rsvg-convert", "--keep-aspect-ratio", "-w", size.ptr, "-h", size.ptr, "-o", raw.ptr, source.ptr, null };
            generated = runArgv(&argv);
        } else {
            generated = rasterThumbnail(allocator, source, raw, bound);
            if (!generated) {
                var vf_buf: [64:0]u8 = undefined;
                const vf = std.fmt.bufPrintSentinel(&vf_buf, "scale={d}:{d}:force_original_aspect_ratio=decrease", .{ bound, bound }, 0) catch return false;
                const argv = [_:null]?[*:0]const u8{ "ffmpeg", "-y", "-v", "error", "-i", source.ptr, "-frames:v", "1", "-vf", vf.ptr, raw.ptr, null };
                generated = runArgv(&argv);
            }
        }
    } else if (extIs(src_path, &pdf_exts)) {
        var prefix_buf: [4096:0]u8 = undefined;
        const prefix = std.fmt.bufPrintSentinel(&prefix_buf, "{s}.page", .{raw[0 .. raw.len - 4]}, 0) catch return false;
        var scale_buf: [16:0]u8 = undefined;
        const scale = std.fmt.bufPrintSentinel(&scale_buf, "{d}", .{bound}, 0) catch unreachable;
        const argv = [_:null]?[*:0]const u8{ "pdftoppm", "-f", "1", "-singlefile", "-scale-to", scale.ptr, "-png", source.ptr, prefix.ptr, null };
        generated = runArgv(&argv);
        if (generated) {
            var made: [4096:0]u8 = undefined;
            const mp = std.fmt.bufPrintSentinel(&made, "{s}.png", .{prefix}, 0) catch return false;
            generated = c.rename(mp.ptr, raw.ptr) == 0;
        }
    } else {
        var vf_buf: [64:0]u8 = undefined;
        const vf = if (extIs(src_path, &video_exts))
            std.fmt.bufPrintSentinel(&vf_buf, "scale={d}:{d}:force_original_aspect_ratio=decrease", .{ bound, bound }, 0) catch return false
        else
            std.fmt.bufPrintSentinel(&vf_buf, "showwavespic=s={d}x{d}", .{ bound, bound }, 0) catch return false;
        if (extIs(src_path, &video_exts)) {
            generated = videoPosterPng(source, raw, vf);
        } else {
            const argv = [_:null]?[*:0]const u8{ "ffmpeg", "-y", "-v", "error", "-i", source.ptr, "-filter_complex", vf.ptr, "-frames:v", "1", raw.ptr, null };
            generated = runArgv(&argv);
        }
    }
    // Every generator above writes `raw`; a zero exit that produced no
    // file is a failure, and reporting it as success hands the caller a
    // path it cannot read.
    return generated and fileHasBytes(raw.ptr);
}

/// Encode a host-local image into the receiver's best NON-PNG codec.
/// Null = no codec library available (or unreadable source).
fn encodeWire(allocator: std.mem.Allocator, source_path: []const u8, codecs: []const u8, bound: u32) ?struct { bytes: []u8, ext: []const u8 } {
    const img = loadScaledRgba(allocator, source_path, bound) orelse return null;
    defer img.deinit(allocator);
    const encoded = imagecodec.encodePreferred(allocator, img.rgba, img.w, img.h, codecs, TRANSPORT_BYTE_CAP) catch return null;
    return .{ .bytes = encoded.bytes, .ext = switch (encoded.codec) {
        .jxl => "jxl",
        .webp => "webp",
    } };
}

/// Wire-cache file cap; at the typical 2-20KB per sidecar this is
/// tens of MB. Pruned oldest-install-first (ctime), only when over.
const WIRE_THUMB_CACHE_MAX = 4096;
const WIRE_THUMB_CACHE_SWEEP = 1024;

/// Serve (or build) the wire-cache thumbnail (128px) or preview
/// (512px, its own xl/ cache dir) for `spec.src`. Freshness = the
/// cache file's mtime equals the source's, stamped at install. Null
/// = no codec library — caller falls back to the legacy spec-PNG
/// path. Media metadata (ffprobe/pdfinfo) is computed per fetch,
/// exactly as the spec-PNG path always did on its cache hits.
fn runWireThumb(job: *const Job, thumbnail_only: bool, mtime_sec: i64, cache_root: []const u8) ?u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    const tier: thumbs.Tier = if (thumbnail_only) .normal else .x_large;
    var source_z: [4096:0]u8 = undefined;
    const source = std.fmt.bufPrintSentinel(&source_z, "{s}", .{spec.src}, 0) catch return job.emitError("preview path too long");
    var metadata: [2048]u8 = undefined;
    var metadata_len: usize = 0;
    if (!thumbnail_only) {
        if (extIs(spec.src, &video_exts) or extIs(spec.src, &audio_exts)) {
            metadata_len = ffprobeEntries(source.ptr, FFPROBE_PREVIEW_ENTRIES, &metadata);
        } else if (extIs(spec.src, &pdf_exts)) {
            metadata_len = pdfinfoText(source.ptr, &metadata);
        }
    }

    // Already cached in a codec the receiver decodes?
    var it = std.mem.splitScalar(u8, spec.image_codecs, ',');
    while (it.next()) |raw_codec| {
        const codec = std.mem.trim(u8, raw_codec, " ");
        if (codec.len == 0 or std.mem.eql(u8, codec, "png")) continue;
        var pbuf: [4096]u8 = undefined;
        const p = thumbs.wireThumbPath(cache_root, spec.src, tier, codec, &pbuf) orelse continue;
        var pz: [4096:0]u8 = undefined;
        const path = pathz.pathZ(&pz, p) catch continue;
        var st: c.struct_stat = undefined;
        if (c.stat(path, &st) != 0 or st.st_size <= 0) continue;
        const fts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
        if (@as(i64, fts.tv_sec) != mtime_sec) continue;
        job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = p, .keep = true, .text = metadata[0..metadata_len] });
        return 0;
    }

    // Encode source: a valid freedesktop PNG (this host's own cache,
    // or another file manager's) is read through; otherwise generate
    // a raw thumb that never gets installed as PNG.
    var final_buf: [4096]u8 = undefined;
    const final = thumbs.thumbPathTier(cache_root, spec.src, tier, &final_buf) orelse return job.emitError("thumbnail path too long");
    var uri_buf: [4096 * 3 + 8]u8 = undefined;
    const uri = thumbs.fileUri(spec.src, &uri_buf) orelse return job.emitError("thumbnail URI too long");
    var raw_buf: [4096:0]u8 = undefined;
    var raw: ?[:0]const u8 = null;
    defer if (raw) |r| {
        _ = c.unlink(r.ptr);
    };
    const enc_src: []const u8 = if (thumbs.validatePng(final, uri, mtime_sec)) final else blk: {
        const r = std.fmt.bufPrintSentinel(&raw_buf, "/tmp/.sketerm-thumbgen-{d}.png", .{c.getpid()}, 0) catch return job.emitError("thumbnail path too long");
        if (!generateThumbPng(allocator, spec.src, source, r, if (thumbnail_only) 128 else 512))
            return job.emitError("preview generator unavailable or failed");
        raw = r;
        break :blk r;
    };
    const enc = encodeWire(allocator, enc_src, spec.image_codecs, 512) orelse return null;
    defer allocator.free(enc.bytes);

    // Install through the explicitly non-durable cache writer, then stamp
    // mtime with the SOURCE's so the hit check above is a plain stat compare.
    var dbuf: [4096]u8 = undefined;
    const dest = thumbs.wireThumbPath(cache_root, spec.src, tier, enc.ext, &dbuf) orelse return job.emitError("thumbnail path too long");
    pathz.makeParentDirs(dest) catch return job.emitError("cannot create wire thumb cache");
    if (std.fs.path.dirname(dest)) |dir| sweepWireThumbs(dir);
    atomicwrite.writeCacheFile(dest, enc.bytes, 0o600) catch |err|
        return job.emitError(@errorName(err));
    var dz: [4096:0]u8 = undefined;
    const destz = pathz.pathZ(&dz, dest) catch return job.emitError("thumbnail path too long");
    const tv = [2]c.struct_timeval{
        .{ .tv_sec = @intCast(mtime_sec), .tv_usec = 0 },
        .{ .tv_sec = @intCast(mtime_sec), .tv_usec = 0 },
    };
    _ = c.utimes(destz, &tv);
    job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = dest, .keep = true, .text = metadata[0..metadata_len] });
    return 0;
}

/// Prune the wire cache oldest-install-first (ctime — mtime carries
/// the SOURCE's stamp). Only counts when called, only prunes when
/// over the cap; generation is already the expensive path.
fn sweepWireThumbs(dir: []const u8) void {
    var dz: [4096:0]u8 = undefined;
    const dirz = pathz.pathZ(&dz, dir) catch return;
    const Item = struct { ctime: i64, name: [44]u8, name_len: usize };
    const a = std.heap.c_allocator;
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(a);
    const d = c.opendir(dirz) orelse return;
    defer _ = c.closedir(d);
    while (true) {
        const ent = c.readdir(d) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name.len < 5 or name.len > 44 or name[0] == '.') continue;
        var pz: [4200:0]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&pz, "{s}/{s}", .{ dir, name }, 0) catch continue;
        var st: c.struct_stat = undefined;
        if (c.stat(p.ptr, &st) != 0) continue;
        const cts = if (@hasField(c.struct_stat, "st_ctim")) st.st_ctim else st.st_ctimespec;
        var item = Item{ .ctime = cts.tv_sec, .name = undefined, .name_len = name.len };
        @memcpy(item.name[0..name.len], name);
        items.append(a, item) catch break;
        if (items.items.len >= WIRE_THUMB_CACHE_MAX * 2) break;
    }
    if (items.items.len <= WIRE_THUMB_CACHE_MAX) return;
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return x.ctime < y.ctime;
        }
    }.lt);
    const doomed = @min(items.items.len - WIRE_THUMB_CACHE_MAX + WIRE_THUMB_CACHE_SWEEP, items.items.len);
    for (items.items[0..doomed]) |item| {
        var pz: [4200:0]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&pz, "{s}/{s}", .{ dir, item.name[0..item.name_len] }, 0) catch continue;
        _ = c.unlink(p.ptr);
    }
}

pub fn runPreview(job: *const Job, thumbnail_only: bool) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    var source_z: [4096:0]u8 = undefined;
    const source = std.fmt.bufPrintSentinel(&source_z, "{s}", .{spec.src}, 0) catch return job.emitError("preview path too long");
    var st: c.struct_stat = undefined;
    if (c.stat(source.ptr, &st) != 0) return job.emitErrno("preview stat");
    const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
    const mtime_sec: i64 = ts.tv_sec;
    const media = extIs(spec.src, &image_exts) or extIs(spec.src, &pdf_exts) or extIs(spec.src, &video_exts) or extIs(spec.src, &audio_exts);

    if (!media and !thumbnail_only) {
        const fp = c.fopen(source.ptr, "rb") orelse return job.emitErrno("preview open");
        var text: [4096]u8 = undefined;
        const n = c.fread(&text, 1, text.len, fp);
        _ = c.fclose(fp);
        if (std.mem.indexOfScalar(u8, text[0..n], 0) != null)
            job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .text = "(binary file)" })
        else
            job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .text = text[0..n] });
        return 0;
    }
    if (!media) return job.emitError("no thumbnailer for this file type");

    var cache_buf: [4096]u8 = undefined;
    const cache_root = cacheRootDir(&cache_buf);

    // Remote-serving wire cache (both tiers: 128px thumbnails and
    // 512px previews): the codec bytes themselves are the cache, no
    // freedesktop PNG is installed and no per-fetch re-encode
    // happens. Null = no codec library on this host — degrade to the
    // legacy spec-PNG path below.
    if (spec.wire_cache and spec.image_codecs.len > 0) {
        if (runWireThumb(job, thumbnail_only, mtime_sec, cache_root)) |rc| return rc;
    }
    // Tier directories are size contracts other applications rely on:
    // normal is 128px, x-large is 512px. Writing a 512px image into
    // `large` (256px) would hand every other file manager an
    // out-of-spec entry it is entitled to trust.
    const tier: thumbs.Tier = if (thumbnail_only) .normal else .x_large;
    var final_buf: [4096]u8 = undefined;
    const final = thumbs.thumbPathTier(cache_root, spec.src, tier, &final_buf) orelse return job.emitError("thumbnail path too long");
    var uri_buf: [4096 * 3 + 8]u8 = undefined;
    const uri = thumbs.fileUri(spec.src, &uri_buf) orelse return job.emitError("thumbnail URI too long");
    const cached = thumbs.validatePng(final, uri, mtime_sec);
    if (!cached) {
        pathz.makeParentDirs(final) catch return job.emitError("cannot create thumbnail cache");
        var mode_buf: [4096]u8 = undefined;
        const thumb_dir = std.fmt.bufPrint(&mode_buf, "{s}/thumbnails", .{cache_root}) catch return job.emitError("cache path too long");
        var mode_z: [4096]u8 = undefined;
        _ = c.chmod(pathz.pathZ(&mode_z, thumb_dir) catch return job.emitError("cache path too long"), 0o700);
        const tier_dir = std.fs.path.dirname(final) orelse return job.emitError("bad thumbnail path");
        _ = c.chmod(pathz.pathZ(&mode_z, tier_dir) catch return job.emitError("cache path too long"), 0o700);
        var raw_buf: [4096:0]u8 = undefined;
        const raw = std.fmt.bufPrintSentinel(&raw_buf, "{s}.generated-{d}.png", .{ final, c.getpid() }, 0) catch return job.emitError("thumbnail path too long");
        defer _ = c.unlink(raw.ptr);
        const bound: c_int = if (thumbnail_only) 128 else 512;
        if (!generateThumbPng(allocator, spec.src, source, raw, bound))
            return job.emitError("preview generator unavailable or failed");
        thumbs.installPng(allocator, raw, final, uri, mtime_sec) catch return job.emitError("cannot install thumbnail cache entry");
    }

    var metadata: [2048]u8 = undefined;
    var metadata_len: usize = 0;
    if (!thumbnail_only and (extIs(spec.src, &video_exts) or extIs(spec.src, &audio_exts))) {
        metadata_len = ffprobeEntries(source.ptr, FFPROBE_PREVIEW_ENTRIES, &metadata);
    } else if (!thumbnail_only and extIs(spec.src, &pdf_exts)) {
        metadata_len = pdfinfoText(source.ptr, &metadata);
    }
    var transport_buf: [4096:0]u8 = undefined;
    const transport = transportPreview(job, final, spec.image_codecs, 512, &transport_buf) orelse
        return job.emitError("no accepted preview codec (jxl/webp/png) or output over the 2 MiB cap");
    job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = transport, .text = metadata[0..metadata_len] });
    return 0;
}

test "transportPreview serves PNG when jxl/webp cannot, refuses without any accepted codec" {
    const t = std.testing;
    var src_z: [128:0]u8 = undefined;
    const src = std.fmt.bufPrintSentinel(&src_z, "/tmp/.sketerm-test-tp-{d}.png", .{c.getpid()}, 0) catch unreachable;
    var rgba: [8 * 8 * 4]u8 = undefined;
    @memset(&rgba, 0x80);
    try t.expect(c.stbi_write_png(src.ptr, 8, 8, 4, &rgba, 8 * 4) != 0);
    defer _ = c.unlink(src.ptr);
    const job = Job{ .allocator = t.allocator, .spec = .{} };
    var out_buf: [4096:0]u8 = undefined;
    // "png" as last resort: a host without libjxl/libwebp still serves.
    const out = transportPreview(&job, src, "png", 512, &out_buf) orelse return error.TestUnexpectedResult;
    defer _ = c.unlink(out_buf[0..out.len :0].ptr);
    try t.expect(std.mem.endsWith(u8, out, ".png"));
    // A receiver accepting nothing usable gets a refusal, not a PNG.
    var out2: [4096:0]u8 = undefined;
    try t.expect(transportPreview(&job, src, "", 512, &out2) == null);
}

test "rasterThumbnail puts the longest side exactly on the bound and keeps small images as-is" {
    const t = std.testing;
    var src_z: [128:0]u8 = undefined;
    const src = std.fmt.bufPrintSentinel(&src_z, "/tmp/.sketerm-test-rt-{d}.png", .{c.getpid()}, 0) catch unreachable;
    var out_z: [128:0]u8 = undefined;
    const out = std.fmt.bufPrintSentinel(&out_z, "/tmp/.sketerm-test-rt-{d}-out.png", .{c.getpid()}, 0) catch unreachable;
    // 289 / (289 / 35) truncates to 34 in floating point; the bound must still be met.
    var rgba: [289 * 10 * 4]u8 = undefined;
    @memset(&rgba, 0x40);
    try t.expect(c.stbi_write_png(src.ptr, 289, 10, 4, &rgba, 289 * 4) != 0);
    defer _ = c.unlink(src.ptr);
    defer _ = c.unlink(out.ptr);
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    try t.expect(rasterThumbnail(t.allocator, src, out, 35));
    try t.expect(c.stbi_info(out.ptr, &w, &h, &n) != 0);
    try t.expectEqual(@as(c_int, 35), w);
    try t.expectEqual(@as(c_int, 1), h);
    try t.expect(rasterThumbnail(t.allocator, src, out, 512));
    try t.expect(c.stbi_info(out.ptr, &w, &h, &n) != 0);
    try t.expectEqual(@as(c_int, 289), w);
    try t.expectEqual(@as(c_int, 10), h);
}

test "fileHasBytes: absent and empty both read as no output" {
    const t = std.testing;
    var z: [128:0]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&z, "/tmp/.sketerm-test-fhb-{d}", .{c.getpid()}, 0) catch unreachable;
    _ = c.unlink(p.ptr);
    try t.expect(!fileHasBytes(p.ptr));
    const fd = c.open(p.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    try t.expect(fd >= 0);
    defer _ = c.unlink(p.ptr);
    try t.expect(!fileHasBytes(p.ptr));
    try t.expect(c.write(fd, "x", 1) == 1);
    _ = c.close(fd);
    try t.expect(fileHasBytes(p.ptr));
}

test "video poster: a clip shorter than the 1s seek still yields a frame" {
    const t = std.testing;
    if (!binaryExists("ffmpeg")) return;
    var src_z: [128:0]u8 = undefined;
    const src = std.fmt.bufPrintSentinel(&src_z, "/tmp/.sketerm-test-poster-{d}.mp4", .{c.getpid()}, 0) catch unreachable;
    defer _ = c.unlink(src.ptr);
    const make = [_:null]?[*:0]const u8{
        "ffmpeg", "-y",                                      "-v", "error", "-f", "lavfi",
        "-i",     "testsrc=duration=0.5:size=64x48:rate=30", src,  null,
    };
    // No lavfi/x264 on this host: nothing to assert about.
    if (!runArgv(&make) or !fileHasBytes(src.ptr)) return;
    var raw_z: [128:0]u8 = undefined;
    const raw = std.fmt.bufPrintSentinel(&raw_z, "/tmp/.sketerm-test-poster-{d}.png", .{c.getpid()}, 0) catch unreachable;
    defer _ = c.unlink(raw.ptr);
    var vf_z: [64:0]u8 = undefined;
    const vf = std.fmt.bufPrintSentinel(&vf_z, "scale=128:128:force_original_aspect_ratio=decrease", .{}, 0) catch unreachable;
    try t.expect(videoPosterPng(src, raw, vf));
    try t.expect(fileHasBytes(raw.ptr));
}
