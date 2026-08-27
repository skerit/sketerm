//! A `GFileInputStream` over the daemon, so GtkMediaFile can play a REMOTE
//! file: `giostreamsrc` reads, seeks and sizes it from the GStreamer
//! streaming thread. Two routes, the Jellyfin ladder minus remux. `.direct`
//! is seekable range reads of the ORIGINAL with a read-ahead window (a
//! demuxer's small reads do not each cost a round trip); the local
//! GStreamer decodes, the host serves bytes and nothing else. `.transcode`
//! asks the remote daemon for a `preview_stream` job -- a capped-width,
//! low-bitrate fragmented MP4 spool that grows while ffmpeg encodes -- and
//! reads that sequentially (non-seekable, size unknown: push mode), so a
//! 4K original never crosses a link that cannot carry it. Which route a
//! `.auto` policy takes is DECIDED HERE, on the streaming thread, from two
//! measurements: the file's bitrate (the host's ffprobe, via media_meta)
//! and the link's throughput (the first megabyte, timed). A host without
//! ffmpeg falls back to `.direct` transparently. The connection is made
//! lazily on the streaming thread (never the GUI's -- a remote connect can
//! block on SSH), and every failure surfaces as a `G_IO_ERROR` the media
//! stream reports instead of a hang.

const std = @import("std");
const c = @import("../c.zig").c;
const fsdrive = @import("../ipc/fsdrive.zig");
const viewer = @import("viewer.zig");
const t = std.testing;

const nowMs = @import("../util/clock.zig").nowMs;
const nowUs = @import("../util/clock.zig").nowUs;

/// Bytes fetched per window; two `MAX_READ` requests, so a demuxer that
/// walks a file linearly costs one round trip per megabyte pair.
pub const READ_AHEAD: usize = 4 << 20;

/// What the caller asks for. `.auto` measures; the others force a rung.
/// The config key `files_remote_video` IS this vocabulary (declared
/// core-side, since config compiles into the daemon).
pub const Policy = @import("../config.zig").RemoteVideo;

/// What the stream settled on.
pub const Route = enum { direct, transcode };

/// The link must carry the file's bitrate with this much to spare
/// before the original is played over it: a link exactly at the
/// bitrate stalls on every burst.
const LINK_HEADROOM_PCT: u64 = 150;

/// How much of the original the `.auto` measurement reads (and keeps,
/// as the first window, when the decision is direct). Half a `MAX_READ`:
/// enough to average out per-request latency on a LAN, cheap enough to
/// throw away on a 20 Mbit/s link (400ms).
const LINK_SAMPLE_BYTES: usize = 1 << 20;

/// How long a transcoded read waits for the spool to grow before it is
/// a failure rather than a stall (progress events arrive every 250ms
/// while the encoder runs; a stopped encoder is woken by our reads).
const SPOOL_WAIT_MS: i64 = 30_000;

/// Direct play needs a link with headroom over the bitrate; an unknown
/// bitrate (no ffprobe on the host) or an unmeasurable link gets the
/// original, since a host that cannot probe cannot transcode either and
/// the local decoder is the one that can say no.
pub fn chooseRoute(bitrate_kbps: ?u64, link_kbps: ?u64) Route {
    const bitrate = bitrate_kbps orelse return .direct;
    const link = link_kbps orelse return .direct;
    if (bitrate == 0) return .direct;
    const need = std.math.mulWide(u64, bitrate, LINK_HEADROOM_PCT) / 100;
    return if (link >= need) .direct else .transcode;
}

/// Throughput of `bytes` moved in `elapsed_us`, in kbit/s; a sub-
/// millisecond sample counts as one millisecond so a tiny file over a
/// LAN cannot divide by zero into infinity.
pub fn throughputKbps(bytes: u64, elapsed_us: i64) u64 {
    const us: u64 = @intCast(@max(elapsed_us, 1000));
    return @intCast(std.math.mulWide(u64, bytes, 8 * 1000) / us);
}

/// The bitrate media_meta reports, or one derived from size and
/// duration when the container carries no bit_rate; null with neither.
pub fn bitrateFromMeta(bitrate_kbps: ?[]const u8, duration_ms: ?[]const u8, size: u64) ?u64 {
    if (bitrate_kbps) |text| {
        if (std.fmt.parseInt(u64, text, 10)) |kbps| {
            if (kbps > 0) return kbps;
        } else |_| {}
    }
    const dur_text = duration_ms orelse return null;
    const dur = std.fmt.parseInt(u64, dur_text, 10) catch return null;
    if (dur == 0) return null;
    return @intCast(std.math.mulWide(u64, size, 8) / dur);
}

/// What the stream decided, for the GUI's status line and its menu.
pub const Decision = struct {
    route: Route,
    /// Measured link throughput (0 = not measured: a forced policy).
    link_kbps: u64,
    /// The source bitrate the host reported (0 = unknown).
    bitrate_kbps: u64,
    /// `.transcode`: the host's encoder name ("x264" / "vaapi").
    encoder: [16]u8,
    encoder_len: usize,

    pub fn encoderName(self: *const Decision) []const u8 {
        return self.encoder[0..self.encoder_len];
    }
};

/// The transport-free core: a position, a window of bytes and the read
/// policy, testable without a daemon.
pub const Window = struct {
    size: u64,
    pos: u64 = 0,
    start: u64 = 0,
    bytes: []const u8 = &.{},

    /// Bytes at `pos` still inside the window, or empty if it must move.
    pub fn cached(self: *const Window) []const u8 {
        if (self.pos < self.start) return &.{};
        const off = self.pos - self.start;
        if (off >= self.bytes.len) return &.{};
        return self.bytes[@intCast(off)..];
    }

    pub const Fetch = struct { off: u64, len: usize };

    /// The next fetch: `[pos, pos + len)` clamped to the file.
    pub fn nextFetch(self: *const Window) Fetch {
        const remaining = self.size -| self.pos;
        return .{ .off = self.pos, .len = @intCast(@min(remaining, READ_AHEAD)) };
    }

    pub fn resolveSeek(self: *const Window, offset: i64, kind: c_int) ?u64 {
        const base: i64 = switch (kind) {
            c.G_SEEK_SET => 0,
            c.G_SEEK_CUR => @intCast(self.pos),
            c.G_SEEK_END => @intCast(self.size),
            else => return null,
        };
        const target = std.math.add(i64, base, offset) catch return null;
        if (target < 0) return null;
        return @intCast(target);
    }
};

const Backend = struct {
    allocator: std.mem.Allocator,
    host: ?[]u8,
    path: []u8,
    policy: Policy,
    /// `.transcode`: encode from this offset (the viewer's time seek).
    start_ms: u64 = 0,
    /// `.transcode`: the source duration the host probed (0 = unknown),
    /// written on the streaming thread, read by the GUI's transport bar.
    duration_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// The decision, published for the GUI thread: `route_state` is 0
    /// until decided, else 1 + @intFromEnum(route), stored with release
    /// AFTER the other fields so an acquire load of it sees them whole.
    route_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    link_kbps: u64 = 0,
    bitrate_kbps: u64 = 0,
    encoder: [16]u8 = undefined,
    encoder_len: usize = 0,
    fs: ?fsdrive.Fs = null,
    /// `.transcode`: the job and its spool; `spool_done` once the encode
    /// finished, after which a short read is a real EOF.
    job: u64 = 0,
    spool: ?[]u8 = null,
    spool_done: bool = false,
    win: Window = .{ .size = 0 },
    buf: std.ArrayList(u8) = .empty,
    /// A failed connect is permanent for this stream: retrying on every
    /// 4KB read would turn one dead host into a stall.
    failed: bool = false,
    err: [200]u8 = undefined,
    err_len: usize = 0,

    fn errText(self: *const Backend) []const u8 {
        return if (self.err_len > 0) self.err[0..self.err_len] else "file service unavailable";
    }

    fn fail(self: *Backend, comptime fmt: []const u8, args: anytype) error{Failed} {
        self.failed = true;
        const msg = std.fmt.bufPrint(&self.err, fmt, args) catch &self.err;
        self.err_len = msg.len;
        return error.Failed;
    }

    fn ensureOpen(self: *Backend) error{Failed}!void {
        if (self.fs != null) return;
        if (self.failed) return error.Failed;
        var fs = viewer.connectFs(self.host) catch |e| return self.fail("cannot connect to {s}: {s}", .{ self.host orelse "local", @errorName(e) });
        var probe: std.ArrayList(u8) = .empty;
        defer probe.deinit(std.heap.c_allocator);
        const info = fs.read(self.path, 0, 0, &probe) catch |e| {
            fs.deinit();
            return self.fail("cannot open {s}: {s}", .{ self.path, @errorName(e) });
        };
        self.fs = fs;
        self.win.size = info.size;
        try self.decide();
    }

    /// Settle the route. A forced policy skips the measurements; `.auto`
    /// probes the bitrate on the host and times the first megabyte over
    /// the link, which stays as the first window when the answer is
    /// direct. A transcode the host refuses becomes direct.
    fn decide(self: *Backend) error{Failed}!void {
        var route: Route = switch (self.policy) {
            .direct => .direct,
            .transcode => .transcode,
            .auto => blk: {
                self.bitrate_kbps = self.probeBitrate() orelse 0;
                self.link_kbps = try self.measureLink() orelse 0;
                break :blk chooseRoute(
                    if (self.bitrate_kbps > 0) self.bitrate_kbps else null,
                    if (self.link_kbps > 0) self.link_kbps else null,
                );
            },
        };
        if (route == .transcode and !self.startTranscode()) route = .direct;
        self.route_state.store(1 + @as(u8, @intFromEnum(route)), .release);
    }

    /// The host's ffprobe via media_meta (daemon-cached per file), so a
    /// re-open of the same video costs no second probe.
    fn probeBitrate(self: *Backend) ?u64 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const dir = std.fs.path.dirname(self.path) orelse "/";
        const names = [_][]const u8{std.fs.path.basename(self.path)};
        const results = self.fs.?.mediaMeta(arena.allocator(), dir, &names, 15_000) catch return null;
        if (results.len == 0) return null;
        return bitrateFromMeta(results[0].get("media.bitrate_kbps"), results[0].get("media.duration_ms"), self.win.size);
    }

    /// Time the first sample of the original; it becomes the window at
    /// offset 0 so a direct decision has already read its first bytes.
    fn measureLink(self: *Backend) error{Failed}!?u64 {
        const want: usize = @intCast(@min(self.win.size, LINK_SAMPLE_BYTES));
        if (want == 0) return null;
        const started = nowUs();
        try self.fetchInto(self.path, 0, want);
        const elapsed = nowUs() - started;
        return throughputKbps(self.buf.items.len, elapsed);
    }

    /// Ask the host to transcode; false on any refusal before the spool
    /// is named (no ffmpeg there, unsupported file), so the caller can
    /// degrade to the original rather than fail playback outright.
    fn startTranscode(self: *Backend) bool {
        const fs = &self.fs.?;
        const job = fs.startPreviewStream(self.path, self.start_ms) catch return false;
        var deadline_tries: usize = 0;
        while (deadline_tries < 4) : (deadline_tries += 1) {
            var ev = (fs.waitJobEvent(job, 15_000) catch null) orelse continue;
            defer ev.deinit();
            if (std.mem.eql(u8, ev.ev, "progress") and ev.path.len > 0) {
                self.spool = self.allocator.dupe(u8, ev.path) catch return false;
                self.job = job;
                self.duration_ms.store(ev.duration_ms, .release);
                self.encoder_len = @min(ev.encoder.len, self.encoder.len);
                @memcpy(self.encoder[0..self.encoder_len], ev.encoder[0..self.encoder_len]);
                // Whatever the measurement read of the original is not
                // the spool: the window restarts at the spool's byte 0.
                self.win = .{ .size = 0 };
                self.buf.clearRetainingCapacity();
                return true;
            }
            if (ev.terminal()) return false;
        }
        return false;
    }

    /// Wait for the encode to add bytes past `pos`; false once the
    /// spool is complete or the job died.
    fn awaitSpoolGrowth(self: *Backend) error{Failed}!bool {
        if (self.spool_done) return false;
        const fs = &self.fs.?;
        const deadline = nowMs() + SPOOL_WAIT_MS;
        while (nowMs() < deadline) {
            var ev = (fs.waitJobEvent(self.job, 1_000) catch |e|
                return self.fail("lost the host while streaming: {s}", .{@errorName(e)})) orelse continue;
            defer ev.deinit();
            if (std.mem.eql(u8, ev.ev, "done")) {
                self.spool_done = true;
                return true;
            }
            if (ev.terminal()) return self.fail("host transcode failed: {s}", .{ev.message});
            if (ev.done > self.win.pos) return true;
        }
        return self.fail("host transcode stalled", .{});
    }

    /// Fetch `[off, off + len)` of `source` into the window (a short
    /// result is EOF or, for a spool, the encoder's current edge).
    fn fetchInto(self: *Backend, source: []const u8, off: u64, len: usize) error{Failed}!void {
        self.win.bytes = &.{};
        self.buf.clearRetainingCapacity();
        var got: usize = 0;
        while (got < len) {
            const before = self.buf.items.len;
            const want: u32 = @intCast(@min(len - got, fsdrive.fsserve.MAX_READ));
            const info = self.fs.?.read(source, off + got, want, &self.buf) catch |e|
                return self.fail("read failed at {d}: {s}", .{ off + got, @errorName(e) });
            const received = self.buf.items.len - before;
            if (received == 0) break;
            got += received;
            if (info.eof) break;
        }
        self.win.start = off;
        self.win.bytes = self.buf.items;
    }

    /// Fill the window from `pos`; false at EOF. A transcoded spool
    /// has no known size: read what is there, and when that is nothing
    /// wait for the encoder to add more.
    fn refill(self: *Backend) error{Failed}!bool {
        while (true) {
            const source: []const u8 = self.spool orelse self.path;
            const fetch: Window.Fetch = if (self.spool != null)
                .{ .off = self.win.pos, .len = READ_AHEAD }
            else
                self.win.nextFetch();
            if (fetch.len == 0) return false;
            try self.fetchInto(source, fetch.off, fetch.len);
            if (self.buf.items.len > 0) return true;
            if (self.spool == null) return false;
            if (!try self.awaitSpoolGrowth()) return false;
        }
    }

    fn read(self: *Backend, out: []u8) error{Failed}!usize {
        try self.ensureOpen();
        var cached = self.win.cached();
        if (cached.len == 0) {
            if (!try self.refill()) return 0;
            cached = self.win.cached();
        }
        const n = @min(out.len, cached.len);
        @memcpy(out[0..n], cached[0..n]);
        self.win.pos += n;
        return n;
    }

    fn deinit(self: *Backend) void {
        // Closing the connection is what stops the host encode: the job
        // is ephemeral and dies (process group and spool) with its client.
        if (self.fs) |*fs| fs.deinit();
        if (self.spool) |sp| self.allocator.free(sp);
        self.buf.deinit(self.allocator);
        if (self.host) |h| self.allocator.free(h);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

const Instance = extern struct {
    parent: c.GFileInputStream,
    backend: ?*Backend,
};

var gtype: c.GType = 0;
var parent_class: ?*c.GObjectClass = null;

fn ensureType() c.GType {
    if (gtype != 0) return gtype;
    gtype = c.g_type_register_static_simple(
        c.g_file_input_stream_get_type(),
        "SketermRemoteInputStream",
        @sizeOf(c.GFileInputStreamClass),
        @ptrCast(&classInit),
        @sizeOf(Instance),
        null,
        c.G_TYPE_FLAG_NONE,
    );
    return gtype;
}

fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const object_class: *c.GObjectClass = @ptrCast(@alignCast(klass));
    object_class.finalize = &finalize;
    const input_class: *c.GInputStreamClass = @ptrCast(@alignCast(klass));
    input_class.read_fn = &readFn;
    input_class.close_fn = &closeFn;
    const file_class: *c.GFileInputStreamClass = @ptrCast(@alignCast(klass));
    file_class.tell = &tell;
    file_class.can_seek = &canSeek;
    file_class.seek = &seek;
    file_class.query_info = &queryInfo;
}

fn instanceOf(stream: ?*anyopaque) *Instance {
    return @ptrCast(@alignCast(stream.?));
}

fn setError(err: [*c][*c]c.GError, backend: *const Backend) void {
    var z: [256:0]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&z, "{s}", .{backend.errText()}) catch "file service error";
    c.g_set_error_literal(err, c.g_io_error_quark(), c.G_IO_ERROR_FAILED, msg.ptr);
}

fn readFn(stream: [*c]c.GInputStream, buffer: ?*anyopaque, count: c.gsize, _: [*c]c.GCancellable, err: [*c][*c]c.GError) callconv(.c) c.gssize {
    const backend = instanceOf(stream).backend orelse return 0;
    const out: [*]u8 = @ptrCast(buffer orelse return 0);
    const n = backend.read(out[0..count]) catch {
        setError(err, backend);
        return -1;
    };
    return @intCast(n);
}

fn closeFn(stream: [*c]c.GInputStream, _: [*c]c.GCancellable, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const inst = instanceOf(stream);
    if (inst.backend) |backend| {
        if (backend.fs) |*fs| fs.deinit();
        backend.fs = null;
        backend.failed = true;
        _ = backend.fail("stream closed", .{}) catch {};
    }
    return 1;
}

fn tell(stream: [*c]c.GFileInputStream) callconv(.c) c.goffset {
    const backend = instanceOf(stream).backend orelse return 0;
    return @intCast(backend.win.pos);
}

/// Decided at open (which giostreamsrc does before its first read):
/// range reads seek, a growing spool does not.
fn canSeek(stream: [*c]c.GFileInputStream) callconv(.c) c.gboolean {
    const backend = instanceOf(stream).backend orelse return 0;
    backend.ensureOpen() catch return 0;
    return @intFromBool(backend.spool == null);
}

fn seek(stream: [*c]c.GFileInputStream, offset: c.goffset, kind: c.GSeekType, _: [*c]c.GCancellable, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const backend = instanceOf(stream).backend orelse return 0;
    backend.ensureOpen() catch {
        setError(err, backend);
        return 0;
    };
    if (backend.spool != null) {
        c.g_set_error_literal(err, c.g_io_error_quark(), c.G_IO_ERROR_NOT_SUPPORTED, "a transcoded stream is not seekable");
        return 0;
    }
    const target = backend.win.resolveSeek(@intCast(offset), @intCast(kind)) orelse {
        c.g_set_error_literal(err, c.g_io_error_quark(), c.G_IO_ERROR_INVALID_ARGUMENT, "seek out of range");
        return 0;
    };
    backend.win.pos = target;
    return 1;
}

fn queryInfo(stream: [*c]c.GFileInputStream, _: [*c]const u8, _: [*c]c.GCancellable, err: [*c][*c]c.GError) callconv(.c) ?*c.GFileInfo {
    const backend = instanceOf(stream).backend orelse return null;
    backend.ensureOpen() catch {
        setError(err, backend);
        return null;
    };
    // A spool's final size is unknown; "not supported" leaves the
    // source in push mode instead of a size of 0 (= instant EOS).
    if (backend.spool != null) {
        c.g_set_error_literal(err, c.g_io_error_quark(), c.G_IO_ERROR_NOT_SUPPORTED, "size unknown while transcoding");
        return null;
    }
    const info = c.g_file_info_new();
    c.g_file_info_set_size(info, @intCast(backend.win.size));
    return info;
}

fn finalize(object: [*c]c.GObject) callconv(.c) void {
    const inst = instanceOf(object);
    if (inst.backend) |backend| backend.deinit();
    inst.backend = null;
    if (parent_class) |pc| if (pc.finalize) |f| f(object);
}

/// The transcoded source's duration in ms (0 = not known yet, or a
/// direct stream), safe from any thread.
pub fn durationMs(stream: *c.GInputStream) u64 {
    const backend = instanceOf(stream).backend orelse return 0;
    return backend.duration_ms.load(.acquire);
}

/// What the stream settled on, null until its first touch decided it.
/// Safe from any thread: `route_state` is the release fence over the
/// other fields.
pub fn decision(stream: *c.GInputStream) ?Decision {
    const backend = instanceOf(stream).backend orelse return null;
    const state = backend.route_state.load(.acquire);
    if (state == 0) return null;
    return .{
        .route = @enumFromInt(state - 1),
        .link_kbps = backend.link_kbps,
        .bitrate_kbps = backend.bitrate_kbps,
        .encoder = backend.encoder,
        .encoder_len = backend.encoder_len,
    };
}

/// A new stream for `path` on `host` (null = the local daemon). Nothing
/// connects until GStreamer first touches it. `start_ms` is where a
/// transcode encode begins. Caller owns one reference.
pub fn new(host: ?[]const u8, path: []const u8, policy: Policy, start_ms: u64) ?*c.GInputStream {
    const allocator = std.heap.c_allocator;
    const backend = allocator.create(Backend) catch return null;
    backend.* = .{
        .allocator = allocator,
        .policy = policy,
        .start_ms = start_ms,
        .host = if (host) |h| (allocator.dupe(u8, h) catch {
            allocator.destroy(backend);
            return null;
        }) else null,
        .path = allocator.dupe(u8, path) catch {
            if (backend.host) |h| allocator.free(h);
            allocator.destroy(backend);
            return null;
        },
    };
    const obj = c.g_object_new(ensureType(), @as([*c]const u8, null)) orelse {
        backend.deinit();
        return null;
    };
    const inst: *Instance = @ptrCast(@alignCast(obj));
    inst.backend = backend;
    return @ptrCast(@alignCast(obj));
}

test "chooseRoute: direct with headroom, transcode without, direct when nothing is known" {
    // 20 Mbit/s file on a gigabit LAN: direct. Same file on 25 Mbit/s: not 1.5x, transcode.
    try t.expectEqual(Route.direct, chooseRoute(20_000, 900_000));
    try t.expectEqual(Route.transcode, chooseRoute(20_000, 25_000));
    try t.expectEqual(Route.direct, chooseRoute(20_000, 30_000));
    try t.expectEqual(Route.direct, chooseRoute(null, 1_000));
    try t.expectEqual(Route.direct, chooseRoute(20_000, null));
    try t.expectEqual(Route.direct, chooseRoute(0, 1));
}

test "throughputKbps: bits per millisecond, floored at one millisecond" {
    try t.expectEqual(@as(u64, 8_000), throughputKbps(1_000_000, 1_000_000));
    try t.expectEqual(@as(u64, 8_000_000), throughputKbps(1_000_000, 10));
    try t.expectEqual(@as(u64, 0), throughputKbps(0, 5_000));
}

test "bitrateFromMeta: reported bitrate wins, else size over duration, else nothing" {
    try t.expectEqual(@as(?u64, 4_500), bitrateFromMeta("4500", "1000", 999));
    try t.expectEqual(@as(?u64, 8_000), bitrateFromMeta(null, "1000", 1_000_000));
    try t.expectEqual(@as(?u64, 8_000), bitrateFromMeta("N/A", "1000", 1_000_000));
    try t.expectEqual(@as(?u64, null), bitrateFromMeta(null, null, 1_000_000));
    try t.expectEqual(@as(?u64, null), bitrateFromMeta("0", "0", 1_000_000));
}

test "Window serves cached bytes, moves on a miss and clamps the fetch to the file" {
    const data = "0123456789";
    var w = Window{ .size = 100, .start = 20, .bytes = data };
    w.pos = 25;
    try t.expectEqualStrings("56789", w.cached());
    w.pos = 30;
    try t.expectEqual(@as(usize, 0), w.cached().len);
    w.pos = 19;
    try t.expectEqual(@as(usize, 0), w.cached().len);
    w.pos = 98;
    const f = w.nextFetch();
    try t.expectEqual(@as(u64, 98), f.off);
    try t.expectEqual(@as(usize, 2), f.len);
    w.pos = 100;
    try t.expectEqual(@as(usize, 0), w.nextFetch().len);
}

test "Window resolves seeks from start, current and end and rejects negatives" {
    var w = Window{ .size = 100 };
    w.pos = 40;
    try t.expectEqual(@as(?u64, 10), w.resolveSeek(10, c.G_SEEK_SET));
    try t.expectEqual(@as(?u64, 45), w.resolveSeek(5, c.G_SEEK_CUR));
    try t.expectEqual(@as(?u64, 90), w.resolveSeek(-10, c.G_SEEK_END));
    try t.expectEqual(@as(?u64, null), w.resolveSeek(-50, c.G_SEEK_CUR));
    try t.expectEqual(@as(?u64, null), w.resolveSeek(0, 99));
}
