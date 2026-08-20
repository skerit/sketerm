//! GUI-side player for `audio` channels: PCM units from the daemon's
//! PulseAudio server (mux/pulse.zig) play through the LOCAL audio
//! stack via async libpulse on the GLib main loop (pa_glib_mainloop —
//! no threads, no GTK in callbacks).
//!
//! The local stack is also the CLOCK: bytes accepted by the local
//! pa_stream are reported upstream as `consumed` units, which the
//! daemon converts into PA REQUESTs toward the app — so a remote
//! mpv paces itself to the pixels actually leaving THIS speaker.
//! Local sink latency rides up as `latency` units for lip-sync.
//!
//! If the local context fails (no audio stack), PCM is discarded but
//! consumption is still reported: remote apps keep running silently
//! instead of blocking on a full server buffer.
//!
//! macOS is exactly that "no audio stack" case, permanently: libpulse
//! is Linux-only here (<pulse/*.h> sits inside the __linux__ branch of
//! vendor/cimport_root.h), so `create` reports the context failed and
//! every voice takes the discard-and-report path above. Remote apps
//! still run; they just play to nothing. A local CoreAudio backend is
//! the fix if playback is ever wanted -- not a stub that pretends.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const pulse = @import("mux/pulse.zig");
const opuscodec = @import("mux/opuscodec.zig");
const cast = @import("util/cast.zig");

/// libpulse exists only in the Linux arm of the GUI cimport set.
const have_pulse = builtin.os.tag == .linux;
/// The three libpulse handles this file keeps. Off Linux they are
/// uninhabited stand-ins so the struct still has fields and the
/// callbacks still have signatures; every one of them stays null.
const PaMainloop = if (have_pulse) c.pa_glib_mainloop else opaque {};
const PaContext = if (have_pulse) c.pa_context else opaque {};
const PaStream = if (have_pulse) c.pa_stream else opaque {};

pub const AudioSink = struct {
    allocator: std.mem.Allocator,
    ml: ?*PaMainloop = null,
    ctx: ?*PaContext = null,
    ctx_ready: bool = false,
    ctx_failed: bool = false,
    voices: std.AutoHashMapUnmanaged(u32, *Voice) = .empty,
    /// Outgoing units toward the daemon (consumed/latency reports).
    intents: std.ArrayList(u8) = .empty,
    on_flush: ?*const fn (ctx: ?*anyopaque) void = null,
    flush_ctx: ?*anyopaque = null,
    dead: bool = false,

    const Voice = struct {
        sink: *AudioSink,
        id: u32,
        stream: ?*PaStream = null,
        /// PCM not yet accepted by the local stream.
        pending: std.ArrayList(u8) = .empty,
        format: u8 = 3,
        channels: u8 = 2,
        rate: u32 = 44100,
        corked: bool = false,
        application: []u8 = &.{},
        binary: []u8 = &.{},
        media: []u8 = &.{},
        icon: []u8 = &.{},
        pid: u32 = 0,
        last_latency_us: u64 = 0,
        /// Lazily-created Opus decoder for pcm_opus units.
        dec: ?opuscodec.Decoder = null,
        dec_failed: bool = false,
    };

    /// Whether any remote voice is uncorked, even if local playback failed.
    pub fn playing(self: *const AudioSink) bool {
        var it = self.voices.valueIterator();
        while (it.next()) |v| {
            if (!v.*.corked) return true;
        }
        return false;
    }

    /// Snapshot of the remote playback streams; caller frees only the slice.
    pub fn audioInfos(self: *const AudioSink, allocator: std.mem.Allocator) []pulse.AudioInfo {
        var out: std.ArrayList(pulse.AudioInfo) = .empty;
        var it = self.voices.valueIterator();
        while (it.next()) |v| {
            out.append(allocator, .{
                .application = v.*.application,
                .binary = v.*.binary,
                .media = v.*.media,
                .icon = v.*.icon,
                .pid = v.*.pid,
                .running = !v.*.corked,
            }) catch break;
        }
        return out.toOwnedSlice(allocator) catch {
            out.deinit(allocator);
            return &.{};
        };
    }

    pub fn create(allocator: std.mem.Allocator) !*AudioSink {
        const self = try allocator.create(AudioSink);
        self.* = .{ .allocator = allocator };
        if (!have_pulse) {
            // No local audio stack to connect to; the discard-and-report
            // path keeps remote apps running.
            self.ctx_failed = true;
            return self;
        }
        self.ml = c.pa_glib_mainloop_new(c.g_main_context_default());
        if (self.ml == null) {
            self.ctx_failed = true;
            return self;
        }
        const api = c.pa_glib_mainloop_get_api(self.ml);
        self.ctx = c.pa_context_new(api, "sketerm");
        if (self.ctx == null) {
            self.ctx_failed = true;
            return self;
        }
        c.pa_context_set_state_callback(self.ctx, onCtxState, self);
        if (c.pa_context_connect(self.ctx, null, c.PA_CONTEXT_NOFLAGS, null) < 0)
            self.ctx_failed = true;
        return self;
    }

    pub fn destroy(self: *AudioSink) void {
        self.dead = true;
        var it = self.voices.valueIterator();
        while (it.next()) |v| self.freeVoice(v.*);
        self.voices.deinit(self.allocator);
        if (have_pulse) {
            if (self.ctx) |ctx| {
                c.pa_context_set_state_callback(ctx, null, null);
                c.pa_context_disconnect(ctx);
                c.pa_context_unref(ctx);
            }
            if (self.ml) |ml| c.pa_glib_mainloop_free(ml);
        }
        self.intents.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn freeVoice(self: *AudioSink, v: *Voice) void {
        if (v.dec) |*d| d.deinit();
        if (have_pulse) {
            if (v.stream) |s| {
                c.pa_stream_set_write_callback(s, null, null);
                c.pa_stream_set_state_callback(s, null, null);
                _ = c.pa_stream_disconnect(s);
                c.pa_stream_unref(s);
            }
        }
        if (v.application.len > 0) self.allocator.free(v.application);
        if (v.binary.len > 0) self.allocator.free(v.binary);
        if (v.media.len > 0) self.allocator.free(v.media);
        if (v.icon.len > 0) self.allocator.free(v.icon);
        v.pending.deinit(self.allocator);
        self.allocator.destroy(v);
    }

    fn replaceMeta(self: *AudioSink, slot: *[]u8, value: []const u8) void {
        const fresh: []u8 = if (value.len > 0) self.allocator.dupe(u8, value) catch return else &.{};
        if (slot.*.len > 0) self.allocator.free(slot.*);
        slot.* = fresh;
    }

    /// One chan_data payload from the daemon.
    pub fn feed(self: *AudioSink, bytes: []const u8) void {
        var pos: usize = 0;
        while (pulse.peelUnit(bytes[pos..])) |p| {
            self.unit(p.tag, p.payload);
            pos += p.consumed;
        }
    }

    fn unit(self: *AudioSink, tag: pulse.UnitTag, payload: []const u8) void {
        switch (tag) {
            .open => {
                if (payload.len < 10) return;
                const id = std.mem.readInt(u32, payload[0..4], .little);
                if (self.voices.contains(id)) return;
                const v = self.allocator.create(Voice) catch return;
                v.* = .{
                    .sink = self,
                    .id = id,
                    .format = payload[4],
                    .channels = payload[5],
                    .rate = std.mem.readInt(u32, payload[6..10], .little),
                };
                self.voices.put(self.allocator, id, v) catch {
                    self.allocator.destroy(v);
                    return;
                };
                if (self.ctx_ready) self.connectVoice(v);
            },
            .pcm => {
                if (payload.len < 4) return;
                const id = std.mem.readInt(u32, payload[0..4], .little);
                const v = self.voices.get(id) orelse return;
                v.pending.appendSlice(self.allocator, payload[4..]) catch return;
                self.pump(v);
            },
            .pcm_opus => {
                if (payload.len < 8) return;
                const id = std.mem.readInt(u32, payload[0..4], .little);
                const raw_len = std.mem.readInt(u32, payload[4..8], .little);
                const v = self.voices.get(id) orelse return;
                if (v.dec == null and !v.dec_failed) {
                    v.dec = opuscodec.Decoder.init(v.rate, v.channels);
                    if (v.dec == null) v.dec_failed = true;
                }
                if (v.dec) |*d| {
                    var out: [opuscodec.MAX_DECODE_SAMPLES]i16 = undefined;
                    if (d.decode(payload[8..], &out)) |decoded| {
                        v.pending.appendSlice(self.allocator, decoded) catch return;
                        self.pump(v);
                        return;
                    }
                }
                // Can't decode: substitute silence so the consumed
                // clock (raw bytes) keeps the remote app flowing.
                const zeros = [_]u8{0} ** 512;
                var left: usize = raw_len;
                while (left > 0) {
                    const n = @min(left, zeros.len);
                    v.pending.appendSlice(self.allocator, zeros[0..n]) catch return;
                    left -= n;
                }
                self.pump(v);
            },
            .close => {
                if (payload.len < 4) return;
                const id = std.mem.readInt(u32, payload[0..4], .little);
                if (self.voices.fetchRemove(id)) |kv| self.freeVoice(kv.value);
            },
            .cork => {
                if (payload.len < 5) return;
                const id = std.mem.readInt(u32, payload[0..4], .little);
                const v = self.voices.get(id) orelse return;
                v.corked = payload[4] != 0;
                if (have_pulse) {
                    if (v.stream) |s| {
                        if (c.pa_stream_get_state(s) == c.PA_STREAM_READY) {
                            const op = c.pa_stream_cork(s, @intFromBool(v.corked), null, null);
                            if (op != null) c.pa_operation_unref(op);
                        }
                    }
                }
            },
            .metadata => {
                const decoded = pulse.decodeMetadata(payload) orelse return;
                const v = self.voices.get(decoded.stream) orelse return;
                self.replaceMeta(&v.application, decoded.info.application);
                self.replaceMeta(&v.binary, decoded.info.binary);
                self.replaceMeta(&v.media, decoded.info.media);
                self.replaceMeta(&v.icon, decoded.info.icon);
                v.pid = decoded.info.pid;
            },
            else => {},
        }
    }

    fn connectVoice(self: *AudioSink, v: *Voice) void {
        if (v.stream != null or self.ctx_failed) return;
        // Off Linux this is already unreachable -- create() sets
        // ctx_failed -- but the body must not be analyzed either.
        if (have_pulse) {
            var spec = c.pa_sample_spec{
                .format = @intCast(v.format), // PA codes pass through
                .rate = v.rate,
                .channels = v.channels,
            };
            if (c.pa_sample_spec_valid(&spec) == 0) {
                self.ctxFailVoice(v);
                return;
            }
            const s = c.pa_stream_new(self.ctx, "sketerm remote", &spec, null) orelse {
                self.ctxFailVoice(v);
                return;
            };
            v.stream = s;
            c.pa_stream_set_state_callback(s, onStreamState, v);
            c.pa_stream_set_write_callback(s, onStreamWritable, v);
            if (c.pa_stream_connect_playback(s, null, null, c.PA_STREAM_INTERPOLATE_TIMING | c.PA_STREAM_AUTO_TIMING_UPDATE | c.PA_STREAM_ADJUST_LATENCY, null, null) < 0) {
                self.ctxFailVoice(v);
            }
        }
    }

    /// Local playback is unavailable for this voice: consume silently
    /// so the remote app never stalls.
    fn ctxFailVoice(self: *AudioSink, v: *Voice) void {
        if (have_pulse) {
            if (v.stream) |s| {
                c.pa_stream_set_write_callback(s, null, null);
                c.pa_stream_set_state_callback(s, null, null);
                c.pa_stream_unref(s);
                v.stream = null;
            }
        }
        if (v.pending.items.len > 0) {
            self.reportConsumed(v.id, v.pending.items.len);
            v.pending.clearRetainingCapacity();
            self.flush();
        }
    }

    /// Move pending PCM into the local stream as far as it will go;
    /// report what it accepted (the playback clock).
    fn pump(self: *AudioSink, v: *Voice) void {
        if (self.ctx_failed or (self.ctx_ready and v.stream == null)) {
            // No local audio: swallow, keep the app flowing.
            if (self.ctx_failed and v.pending.items.len > 0) {
                self.reportConsumed(v.id, v.pending.items.len);
                v.pending.clearRetainingCapacity();
                self.flush();
            }
            return;
        }
        // Off Linux ctx_failed above already took the exit.
        if (have_pulse) {
            const s = v.stream orelse return; // waits for ctx ready
            if (c.pa_stream_get_state(s) != c.PA_STREAM_READY) return;
            var consumed: usize = 0;
            while (v.pending.items.len > 0) {
                const writable = c.pa_stream_writable_size(s);
                if (writable == 0 or writable == std.math.maxInt(usize)) break;
                const n = @min(writable, v.pending.items.len);
                if (c.pa_stream_write(s, v.pending.items.ptr, n, null, 0, c.PA_SEEK_RELATIVE) < 0) break;
                consumed += n;
                const rem = v.pending.items.len - n;
                std.mem.copyForwards(u8, v.pending.items[0..rem], v.pending.items[n..]);
                v.pending.shrinkRetainingCapacity(rem);
            }
            if (consumed > 0) {
                self.reportConsumed(v.id, consumed);
                self.reportLatency(v);
                self.flush();
            }
        }
    }

    fn reportConsumed(self: *AudioSink, id: u32, n: usize) void {
        var pl: [12]u8 = undefined;
        std.mem.writeInt(u32, pl[0..4], id, .little);
        std.mem.writeInt(u64, pl[4..12], @intCast(n), .little);
        pulse.appendUnit(&self.intents, self.allocator, .consumed, &pl) catch {};
    }

    fn reportLatency(self: *AudioSink, v: *Voice) void {
        if (have_pulse) {
            const s = v.stream orelse return;
            var usec: c.pa_usec_t = 0;
            var negative: c_int = 0;
            if (c.pa_stream_get_latency(s, &usec, &negative) < 0) return;
            if (negative != 0) usec = 0;
            // Only ship meaningful changes (>5 ms) — this rides the mux wire.
            const diff = if (usec > v.last_latency_us) usec - v.last_latency_us else v.last_latency_us - usec;
            if (diff < 5_000) return;
            v.last_latency_us = usec;
            var pl: [12]u8 = undefined;
            std.mem.writeInt(u32, pl[0..4], v.id, .little);
            std.mem.writeInt(u64, pl[4..12], usec, .little);
            pulse.appendUnit(&self.intents, self.allocator, .latency, &pl) catch {};
        }
    }

    pub fn takeOut(self: *AudioSink) []const u8 {
        return self.intents.items;
    }
    pub fn clearOut(self: *AudioSink) void {
        self.intents.clearRetainingCapacity();
    }

    fn flush(self: *AudioSink) void {
        if (self.intents.items.len == 0) return;
        if (self.on_flush) |f| f(self.flush_ctx);
    }

    // ── libpulse callbacks (GLib main loop — main thread) ────────

    fn onCtxState(ctx: ?*PaContext, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(AudioSink, user);
        if (self.dead) return;
        if (have_pulse) switch (c.pa_context_get_state(ctx)) {
            c.PA_CONTEXT_READY => {
                self.ctx_ready = true;
                var it = self.voices.valueIterator();
                while (it.next()) |v| self.connectVoice(v.*);
            },
            c.PA_CONTEXT_FAILED, c.PA_CONTEXT_TERMINATED => {
                self.ctx_failed = true;
                // Drain everything silently so remote apps don't stall.
                var it = self.voices.valueIterator();
                while (it.next()) |v| self.ctxFailVoice(v.*);
            },
            else => {},
        };
    }

    fn onStreamState(stream: ?*PaStream, user: ?*anyopaque) callconv(.c) void {
        const v = cast.userData(Voice, user);
        if (v.sink.dead) return;
        if (have_pulse) switch (c.pa_stream_get_state(stream)) {
            c.PA_STREAM_READY => v.sink.pump(v),
            c.PA_STREAM_FAILED => v.sink.ctxFailVoice(v),
            else => {},
        };
    }

    fn onStreamWritable(_: ?*PaStream, _: usize, user: ?*anyopaque) callconv(.c) void {
        const v = cast.userData(Voice, user);
        if (v.sink.dead) return;
        v.sink.pump(v);
    }
};

test "audio metadata and initial cork state follow stream descriptors" {
    const a = std.testing.allocator;
    const sink = try a.create(AudioSink);
    sink.* = .{ .allocator = a };
    defer sink.destroy();

    var units: std.ArrayList(u8) = .empty;
    defer units.deinit(a);
    var open: [10]u8 = undefined;
    std.mem.writeInt(u32, open[0..4], 7, .little);
    open[4] = 3;
    open[5] = 2;
    std.mem.writeInt(u32, open[6..10], 48_000, .little);
    try pulse.appendUnit(&units, a, .open, &open);
    try pulse.appendMetadataUnit(&units, a, 7, .{
        .application = "Firefox",
        .binary = "firefox",
        .media = "Conference call",
        .icon = "firefox",
        .pid = 1234,
    });
    var cork: [5]u8 = undefined;
    std.mem.writeInt(u32, cork[0..4], 7, .little);
    cork[4] = 1;
    try pulse.appendUnit(&units, a, .cork, &cork);
    sink.feed(units.items);

    try std.testing.expect(!sink.playing());
    const infos = sink.audioInfos(a);
    defer a.free(infos);
    try std.testing.expectEqual(@as(usize, 1), infos.len);
    try std.testing.expectEqualStrings("Firefox", infos[0].application);
    try std.testing.expectEqualStrings("Conference call", infos[0].media);
    try std.testing.expectEqual(@as(u32, 1234), infos[0].pid);
    try std.testing.expect(!infos[0].running);
}
