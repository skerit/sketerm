//! A `GFileInputStream` over the daemon, so GtkMediaFile can play a REMOTE
//! file: `giostreamsrc` reads, seeks and sizes it from the GStreamer
//! streaming thread. Two routes, the Jellyfin ladder minus remux. `.direct`
//! is seekable range reads of the ORIGINAL through a `RangeCache` a background
//! thread keeps filled, so a demuxer's jumps cost one small read and its sequential
//! reads run ahead of the link; the local GStreamer decodes, the host serves
//! bytes and nothing else. `.transcode` asks the remote daemon for a
//! `preview_stream` job -- a capped-width, low-bitrate fragmented MP4 spool
//! that grows while ffmpeg encodes -- and reads that sequentially
//! (non-seekable, size unknown: push mode), so a 4K original never crosses a
//! link that cannot carry it. Which route a `.auto` policy takes is DECIDED
//! HERE: the original, unless the file's bitrate (the host's ffprobe, via
//! media_meta) hopelessly exceeds the link's throughput (the first blocks, timed).
//! The viewer moves a stream to a transcode later if playback proves the link too
//! slow (`wantsTranscode`). A host without ffmpeg falls back to `.direct`
//! transparently. A bare host streams over ssh (`bulkSpec`). The connection is made
//! lazily on the streaming thread (never the GUI's -- a remote connect can
//! block on SSH), and every failure surfaces as a `G_IO_ERROR` the media
//! stream reports instead of a hang.

const std = @import("std");
const c = @import("../c.zig").c;
const fsdrive = @import("../ipc/fsdrive.zig");
const viewer = @import("viewer.zig");
const rangecache = @import("../filebrowser/rangecache.zig");
const muxclient = @import("../mux/client.zig");
const t = std.testing;

const nowMs = @import("../util/clock.zig").nowMs;
const nowUs = @import("../util/clock.zig").nowUs;

/// Bytes fetched per refill of a transcoded spool, read while it grows.
pub const READ_AHEAD: usize = 4 << 20;

/// What the caller asks for. `.auto` measures; the others force a rung.
/// The config key `files_remote_video` IS this vocabulary (declared
/// core-side, since config compiles into the daemon).
pub const Policy = @import("../config.zig").RemoteVideo;

/// What the stream settled on.
pub const Route = enum { direct, transcode };

/// A sample this far under the bitrate cannot be the link's noise, so the original is
/// not even tried. Anything closer plays it: one look at a Wi-Fi VPN read from 4 to
/// 29 Mbit/s here, and judging on that sent a 6.6 Mbit/s film to the host encoder
/// on a link averaging 15. `RangeCache` rides out the dips, `StarveMeter` catches
/// what it cannot.
const LINK_HOPELESS_FACTOR: u64 = 4;

/// Blocks the `.auto` measurement reads, kept as the first of the cache when
/// the decision is direct. The first only opens the transport's window, so it is
/// not timed: it would make every fresh ssh connection read as a slow link.
const LINK_SAMPLE_BLOCKS: u64 = 5;

/// How long a host's ffprobe may hold up the start of playback. Unknown bitrate plays the original.
const PROBE_LIMIT_MS: i64 = 4_000;

/// No byte for this long is a dead connection, whatever the socket says.
const FETCH_IDLE_LIMIT_MS: i64 = 20_000;

/// Reconnects after a lost connection before playback reports the failure.
const FETCH_RECONNECTS: u32 = 3;

/// How long a transcoded read waits for the spool to grow before it is
/// a failure rather than a stall (progress events arrive every 250ms
/// while the encoder runs; a stopped encoder is woken by our reads).
const SPOOL_WAIT_MS: i64 = 30_000;

/// An unknown bitrate (no ffprobe on the host) or an unmeasurable link gets
/// the original, since a host that cannot probe cannot transcode either and
/// the local decoder is the one that can say no.
pub fn chooseRoute(bitrate_kbps: ?u64, link_kbps: ?u64) Route {
    const bitrate = bitrate_kbps orelse return .direct;
    const link = link_kbps orelse return .direct;
    if (bitrate == 0) return .direct;
    return if (std.math.mulWide(u64, link, LINK_HOPELESS_FACTOR) < bitrate) .transcode else .direct;
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

/// What the fetch thread and the stream share. Refcounted so a stream can go
/// (`gtk_media_file_clear` on the GUI thread) without waiting out a blocked socket:
/// the thread notices `stop`, and the last of the two to leave frees it.
const Fetch = struct {
    allocator: std.mem.Allocator,
    host: ?[]u8,
    path: []u8,
    mutex: c.GMutex = undefined,
    /// Wakes the thread: a new demand, or `stop`.
    work: c.GCond = undefined,
    /// Wakes the reader: a block landed, or `stop`/`failed`.
    ready: c.GCond = undefined,
    refs: std.atomic.Value(u8) = std.atomic.Value(u8).init(1),
    cache: rangecache.RangeCache,
    stop: bool = false,
    failed: bool = false,
    err: [200]u8 = undefined,
    err_len: usize = 0,
    /// Link estimate for the pipeline depth: smoothed rate between replies, fastest reply seen.
    bytes_per_ms: u64 = 0,
    rtt_ms: u64 = std.math.maxInt(u64),
    last_landed_ms: i64 = 0,
    /// Null when the policy is not `.auto`: nothing may then be switched.
    meter: ?rangecache.StarveMeter = null,
    /// Set on the reader's thread, read there after `read` returns.
    starved: bool = false,
    /// Counters for bench-stream and smoke-stream.
    fetched_bytes: u64 = 0,
    reconnects: u32 = 0,

    fn create(allocator: std.mem.Allocator, host: ?[]const u8, path: []const u8, size: u64) ?*Fetch {
        const self = allocator.create(Fetch) catch return null;
        const host_copy = if (host) |h| (allocator.dupe(u8, h) catch {
            allocator.destroy(self);
            return null;
        }) else null;
        const path_copy = allocator.dupe(u8, path) catch {
            if (host_copy) |h| allocator.free(h);
            allocator.destroy(self);
            return null;
        };
        self.* = .{
            .allocator = allocator,
            .host = host_copy,
            .path = path_copy,
            .cache = rangecache.RangeCache.init(allocator, size),
        };
        c.g_mutex_init(&self.mutex);
        c.g_cond_init(&self.work);
        c.g_cond_init(&self.ready);
        return self;
    }

    fn release(self: *Fetch) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.cache.deinit();
        c.g_mutex_clear(&self.mutex);
        c.g_cond_clear(&self.work);
        c.g_cond_clear(&self.ready);
        if (self.host) |h| self.allocator.free(h);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Tells the thread to leave; a reader blocked on it gets an error.
    fn requestStop(self: *Fetch) void {
        c.g_mutex_lock(&self.mutex);
        self.stop = true;
        c.g_cond_broadcast(&self.work);
        c.g_cond_broadcast(&self.ready);
        c.g_mutex_unlock(&self.mutex);
    }

    fn fail(self: *Fetch, comptime fmt: []const u8, args: anytype) void {
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        self.failLocked(fmt, args);
    }

    fn failLocked(self: *Fetch, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.err, fmt, args) catch self.err[0..];
        self.err_len = msg.len;
        self.failed = true;
        c.g_cond_broadcast(&self.ready);
    }

    /// Blocks only until the block holding `off` has landed.
    fn read(self: *Fetch, off: u64, out: []u8) error{Failed}!usize {
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        while (true) {
            if (self.failed or self.stop) return error.Failed;
            const got = self.cache.read(off, out);
            // Moving through a file is also what opens more read-ahead.
            c.g_cond_signal(&self.work);
            if (got) |n| {
                if (self.meter) |*meter| {
                    if (meter.check(nowMs())) self.starved = true;
                }
                return n;
            }
            const blocked_at = nowMs();
            c.g_cond_wait(&self.ready, &self.mutex);
            if (self.meter) |*meter| meter.blocked_ms += nowMs() - blocked_at;
        }
    }

    const Queued = struct { req: u32, block: u64, sent_ms: i64 };

    /// The thread's body: requests as deep as the link rewards, oldest reply first.
    fn main(self: *Fetch, fs_in: fsdrive.Fs) void {
        defer self.release();
        var fs = fs_in;
        var queue: [16]Queued = undefined;
        var queued: usize = 0;
        var last_progress = nowMs();
        var reconnects_left = FETCH_RECONNECTS;
        while (true) {
            var batch: [16]u64 = undefined;
            var batch_n: usize = 0;
            c.g_mutex_lock(&self.mutex);
            self.pickRequests(&batch, &batch_n, queued);
            while (!self.stop and !self.failed and queued == 0 and batch_n == 0) {
                c.g_cond_wait(&self.work, &self.mutex);
                last_progress = nowMs();
                self.pickRequests(&batch, &batch_n, queued);
            }
            const stopping = self.stop or self.failed;
            c.g_mutex_unlock(&self.mutex);
            if (stopping) break;

            var lost = false;
            for (batch[0..batch_n]) |block| {
                const off = block * rangecache.BLOCK;
                const req = fs.readSubmit(self.path, off, @intCast(rangecache.BLOCK)) catch {
                    lost = true;
                    break;
                };
                queue[queued] = .{ .req = req, .block = block, .sent_ms = nowMs() };
                queued += 1;
            }
            if (!lost and queued > 0) {
                // A short wait, so new demands and `stop` are seen while a slow reply crawls.
                if (fs.awaitSubmitted(queue[0].req, 100)) |op_in| {
                    var op = op_in;
                    defer op.data.deinit(fs.allocator);
                    self.landed(queue[0], op.data.items, queued >= 2);
                    std.mem.copyForwards(Queued, queue[0 .. queued - 1], queue[1..queued]);
                    queued -= 1;
                    last_progress = nowMs();
                    reconnects_left = FETCH_RECONNECTS;
                } else |e| switch (e) {
                    error.Timeout => lost = nowMs() - last_progress >= FETCH_IDLE_LIMIT_MS,
                    error.FsOpFailed => {
                        // The host answered and said no: reconnecting cannot help.
                        self.fail("{s}", .{fs.lastErr()});
                        break;
                    },
                    else => lost = true,
                }
            }
            if (!lost) continue;

            // Every request is a stateless range, so a new connection resumes exactly.
            queued = 0;
            c.g_mutex_lock(&self.mutex);
            self.cache.abandonLoading();
            self.reconnects += 1;
            c.g_mutex_unlock(&self.mutex);
            fs.deinit();
            var replacement: ?fsdrive.Fs = null;
            while (reconnects_left > 0 and replacement == null and !self.stopRequested()) : (reconnects_left -= 1) {
                replacement = viewer.connectFs(self.host) catch null;
            }
            fs = replacement orelse {
                if (!self.stopRequested()) self.fail("lost the connection to {s}", .{self.host orelse "local"});
                return;
            };
            last_progress = nowMs();
        }
        fs.deinit();
    }

    fn stopRequested(self: *Fetch) bool {
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        return self.stop;
    }

    /// Claims blocks up to the link's pipeline depth; call with the mutex held.
    fn pickRequests(self: *Fetch, batch: *[16]u64, batch_n: *usize, queued: usize) void {
        const rtt = if (self.rtt_ms == std.math.maxInt(u64)) 0 else self.rtt_ms;
        const depth: usize = rangecache.pipelineDepth(self.bytes_per_ms, rtt);
        while (queued + batch_n.* < depth) {
            const next = self.cache.nextFetch() catch return;
            batch[batch_n.*] = next orelse return;
            batch_n.* += 1;
        }
    }

    /// @param busy another reply was on the wire, so the gap since the last one measures the link rather than an idle reader.
    fn landed(self: *Fetch, q: Queued, bytes: []const u8, busy: bool) void {
        const now = nowMs();
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        self.cache.complete(q.block, bytes) catch {
            self.failLocked("out of memory buffering", .{});
        };
        self.fetched_bytes += bytes.len;
        if (self.meter) |*meter| meter.bytes += bytes.len;
        self.rtt_ms = @min(self.rtt_ms, @as(u64, @intCast(@max(now - q.sent_ms, 1))));
        if (busy and self.last_landed_ms != 0) {
            const rate = bytes.len / @as(u64, @intCast(@max(now - self.last_landed_ms, 1)));
            self.bytes_per_ms = if (self.bytes_per_ms == 0) rate else (self.bytes_per_ms * 7 + rate) / 8;
        }
        self.last_landed_ms = now;
        c.g_cond_broadcast(&self.ready);
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
    /// `.auto` playback proved the link too slow; the viewer polls it.
    wants_transcode: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    link_kbps: u64 = 0,
    bitrate_kbps: u64 = 0,
    encoder: [16]u8 = undefined,
    encoder_len: usize = 0,
    fs: ?fsdrive.Fs = null,
    /// `.transcode`: the job and its spool; `spool_done` once the encode
    /// finished, after which a short read is a real EOF.
    job: u64 = 0,
    spool: ?[]u8 = null,
    /// `.direct`: where bytes come from once the route is settled; it owns the connection then.
    fetch: ?*Fetch = null,
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
        if (self.failed) return error.Failed;
        if (self.fs != null or self.fetch != null) return;
        var fs = viewer.connectFs(self.host) catch |e| return self.fail("cannot connect to {s}: {s}", .{ self.host orelse "local", @errorName(e) });
        var probe: std.ArrayList(u8) = .empty;
        defer probe.deinit(std.heap.c_allocator);
        const info = fs.read(self.path, 0, 0, &probe) catch |e| {
            fs.deinit();
            return self.fail("cannot open {s}: {s}", .{ self.path, @errorName(e) });
        };
        self.fs = fs;
        self.win.size = info.size;
        self.fetch = Fetch.create(self.allocator, self.host, self.path, info.size) orelse return self.fail("out of memory", .{});
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
        switch (route) {
            .direct => try self.startFetch(),
            // Whatever the sample cached is the original, not the spool.
            .transcode => self.stopFetch(),
        }
        self.route_state.store(1 + @as(u8, @intFromEnum(route)), .release);
    }

    /// Hands the connection to the fetch thread, which owns it from here on.
    fn startFetch(self: *Backend) error{Failed}!void {
        const fetch = self.fetch.?;
        _ = fetch.refs.fetchAdd(1, .acq_rel);
        if (self.policy == .auto and self.bitrate_kbps > 0) fetch.meter = .{ .bitrate_kbps = self.bitrate_kbps };
        const thread = std.Thread.spawn(.{}, Fetch.main, .{ fetch, self.fs.? }) catch {
            fetch.release();
            return self.fail("cannot start the read-ahead thread", .{});
        };
        thread.detach();
        self.fs = null;
    }

    /// The host's ffprobe via media_meta (daemon-cached per file), so a
    /// re-open of the same video costs no second probe.
    fn probeBitrate(self: *Backend) ?u64 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const dir = std.fs.path.dirname(self.path) orelse "/";
        const names = [_][]const u8{std.fs.path.basename(self.path)};
        const results = self.fs.?.mediaMeta(arena.allocator(), dir, &names, PROBE_LIMIT_MS) catch return null;
        if (results.len == 0) return null;
        return bitrateFromMeta(results[0].get("media.bitrate_kbps"), results[0].get("media.duration_ms"), self.win.size);
    }

    /// Time the first blocks of the original, read as the fetch thread will; they
    /// stay in the cache, so a direct decision has already read its first bytes.
    fn measureLink(self: *Backend) error{Failed}!?u64 {
        const fs = &self.fs.?;
        const cache = &self.fetch.?.cache;
        const blocks: usize = @intCast(@min(LINK_SAMPLE_BLOCKS, std.math.divCeil(u64, self.win.size, rangecache.BLOCK) catch unreachable));
        if (blocks == 0) return null;
        var reqs: [LINK_SAMPLE_BLOCKS]u32 = undefined;
        for (reqs[0..blocks], 0..) |*req, i| {
            req.* = fs.readSubmit(self.path, i * rangecache.BLOCK, @intCast(rangecache.BLOCK)) catch |e|
                return self.fail("read failed at {d}: {s}", .{ i * rangecache.BLOCK, @errorName(e) });
        }
        // A file of one block has nothing else to time.
        var timed_from: i64 = nowUs();
        var timed_bytes: u64 = 0;
        for (reqs[0..blocks], 0..) |req, i| {
            var op = fs.awaitSubmitted(req, fsdrive.OP_TIMEOUT_MS) catch |e|
                return self.fail("read failed at {d}: {s}", .{ i * rangecache.BLOCK, @errorName(e) });
            defer op.data.deinit(fs.allocator);
            cache.insert(i, op.data.items) catch return self.fail("out of memory", .{});
            if (i == 0 and blocks > 1) timed_from = nowUs() else timed_bytes += op.data.items.len;
        }
        if (timed_bytes == 0) return null;
        return throughputKbps(timed_bytes, nowUs() - timed_from);
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
                // The window restarts at the spool's byte 0.
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

    /// Fill the window from the spool at `pos`; false at EOF. A transcoded
    /// spool has no known size: read what is there, and when that is nothing
    /// wait for the encoder to add more.
    fn refill(self: *Backend) error{Failed}!bool {
        while (true) {
            try self.fetchInto(self.spool.?, self.win.pos, READ_AHEAD);
            if (self.buf.items.len > 0) return true;
            if (!try self.awaitSpoolGrowth()) return false;
        }
    }

    fn read(self: *Backend, out: []u8) error{Failed}!usize {
        try self.ensureOpen();
        if (self.fetch) |fetch| {
            const n = fetch.read(self.win.pos, out) catch {
                const n = @min(self.err.len, fetch.err_len);
                @memcpy(self.err[0..n], fetch.err[0..n]);
                self.err_len = n;
                self.failed = true;
                return error.Failed;
            };
            if (fetch.starved) self.wants_transcode.store(true, .release);
            self.win.pos += n;
            return n;
        }
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

    /// Lets go of the fetch thread without waiting for it, which also closes its connection.
    fn stopFetch(self: *Backend) void {
        const fetch = self.fetch orelse return;
        self.fetch = null;
        fetch.requestStop();
        fetch.release();
    }

    fn deinit(self: *Backend) void {
        self.stopFetch();
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
    const msg = std.fmt.bufPrintSentinel(&z, "{s}", .{backend.errText()}, 0) catch "file service error";
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
        backend.stopFetch();
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

/// Whether a `.auto` stream's playback proved the link cannot carry the original; safe from any thread.
pub fn wantsTranscode(stream: *c.GInputStream) bool {
    const backend = instanceOf(stream).backend orelse return false;
    return backend.wants_transcode.load(.acquire);
}

/// Bytes the stream fetched and connections it had to replace, for the thread reading it.
pub const Stats = struct { fetched_bytes: u64 = 0, reconnects: u32 = 0 };

pub fn stats(stream: *c.GInputStream) Stats {
    const backend = instanceOf(stream).backend orelse return .{};
    const fetch = backend.fetch orelse return .{};
    c.g_mutex_lock(&fetch.mutex);
    defer c.g_mutex_unlock(&fetch.mutex);
    return .{ .fetched_bytes = fetch.fetched_bytes, .reconnects = fetch.reconnects };
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

/// A bare host's bytes go over ssh: bulk throughput is what TCP is for, and the UDP
/// transport's fixed window caps it at about 150 KB per round trip. An explicit
/// `udp:`, a route or a socket is what the user asked for and stays as it is.
fn bulkSpec(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    const asked = muxclient.RouteSpec.isRoute(host) or std.mem.startsWith(u8, host, "sock:") or
        muxclient.RemoteSpec.parse(host).mode != .auto;
    return if (asked) allocator.dupe(u8, host) else std.fmt.allocPrint(allocator, "ssh:{s}", .{host});
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
        .host = if (host) |h| (bulkSpec(allocator, h) catch {
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

test "bulkSpec moves only a bare host onto ssh" {
    const cases = [_][2][]const u8{
        .{ "archdev", "ssh:archdev" },
        .{ "me@archdev", "ssh:me@archdev" },
        .{ "udp:archdev", "udp:archdev" },
        .{ "ssh:archdev", "ssh:archdev" },
        .{ "tor:archdev", "tor:archdev" },
        .{ "sock:/tmp/x/mux.sock", "sock:/tmp/x/mux.sock" },
        .{ "route:archdev,gateway", "route:archdev,gateway" },
    };
    for (cases) |case| {
        const spec = try bulkSpec(t.allocator, case[0]);
        defer t.allocator.free(spec);
        try t.expectEqualStrings(case[1], spec);
    }
}

test "chooseRoute: the original unless the link is hopeless, and when nothing is known" {
    // 20 Mbit/s file on a gigabit LAN, and on a link that merely dipped under it: direct.
    try t.expectEqual(Route.direct, chooseRoute(20_000, 900_000));
    try t.expectEqual(Route.direct, chooseRoute(20_000, 5_000));
    try t.expectEqual(Route.direct, chooseRoute(6_600, 4_000));
    // 80 Mbit/s 4K on 10 Mbit/s: no buffer helps.
    try t.expectEqual(Route.transcode, chooseRoute(80_000, 10_000));
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

test "Window serves cached bytes, and reports a miss" {
    const data = "0123456789";
    var w = Window{ .size = 100, .start = 20, .bytes = data };
    w.pos = 25;
    try t.expectEqualStrings("56789", w.cached());
    w.pos = 30;
    try t.expectEqual(@as(usize, 0), w.cached().len);
    w.pos = 19;
    try t.expectEqual(@as(usize, 0), w.cached().len);
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
