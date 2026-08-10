//! Cast-playback sessions: a daemon session whose "child" is an
//! asciicast v2/v3 file (`SpawnReq.cast_path`) replayed on the poll
//! loop's monotonic clock instead of a PTY. No child process, no
//! keeper, no Wayland/audio hubs; output bytes flow through the SAME
//! parser/broadcast path PTY bytes use (`Daemon.ingestBegin/Finish`),
//! so the wire stays parsed-events-only. A cast is UNTRUSTED input:
//! the shared ingest path drops kitty file/tempfile/shm APCs before
//! they can touch the daemon host's filesystem, and every Screen
//! response is discarded (there is no PTY to answer).

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const cast_play = @import("cast_play.zig");
const logring = @import("logring.zig");
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Session = dmod.Session;
const SpawnReq = dmod.SpawnReq;
const nowMs = dmod.nowMs;
const pathZ = @import("../util/pathz.zig").pathZ;
const Pool = @import("../grid/style_pool.zig").Pool;
const Screen = @import("../grid/screen.zig").Screen;
const Parser = @import("../parser/vt.zig").Parser;

/// Output bytes fed to the parser per catch-up batch before an
/// immediate re-tick is scheduled instead (never dropped).
const OUT_BATCH: usize = 256 * 1024;
/// Events dispatched per catch-up batch.
const EV_BATCH: u32 = 500;
/// File bytes read into the reader per playback service.
const READ_BATCH: usize = 512 * 1024;
/// File bytes replayed per seek tick — a 1 GB cast seeks across many
/// ticks instead of blocking the poll loop.
const SEEK_BATCH: usize = 1024 * 1024;
/// Minimum gap between throttled play_state pushes while playing.
const STATE_PUSH_MS: i64 = 500;
/// Markers carried in a play_state payload (newest kept).
const MAX_STATE_MARKERS: usize = 256;

/// Per-session playback state, heap-owned by `Session.source.cast`.
pub const CastPlayback = struct {
    allocator: std.mem.Allocator,
    /// Owned daemon-host path, re-opened on every seek.
    path: []u8,
    file: ?*c.FILE,
    player: cast_play.Player,
    header_cols: u16,
    header_rows: u16,
    state: State = .paused,
    /// Cast-time position in ms; advances only while playing.
    position_ms: u64 = 0,
    /// Fractional-ms carry so speed-scaled advances never drift.
    frac_ms: f64 = 0,
    /// Monotonic stamp of the last clock advance while playing.
    last_wall_ms: i64 = 0,
    speed: f64 = 1.0,
    /// Next event, already decoded but not yet due (owned copy).
    pending: ?PendingEvent = null,
    /// Highest event time seen so far — becomes duration_ms at EOF.
    max_time_ms: u64 = 0,
    duration_ms: ?u64 = null,
    exit_code: ?i32 = null,
    markers: std.ArrayList(Mark) = .empty,
    ever_attached: bool = false,
    seek: ?SeekState = null,
    last_push_ms: i64 = 0,
    /// A bounded batch stopped early; the next tick must not sleep.
    want_immediate: bool = false,

    pub const State = enum { paused, playing, finished };
    pub const Mark = struct { ms: u64, label: []u8 };
    pub const SeekState = struct { target_ms: u64, resume_play: bool };

    pub const PendingEvent = struct {
        time_ms: u64,
        data: union(enum) {
            output: []u8,
            resize: struct { cols: u16, rows: u16 },
            marker: []u8,
            exit: i32,
            input,
        },

        fn copy(allocator: std.mem.Allocator, ev: cast_play.TimedEvent) !PendingEvent {
            return .{
                .time_ms = ev.time_ms,
                .data = switch (ev.event) {
                    .output => |b| .{ .output = try allocator.dupe(u8, b) },
                    .resize => |r| .{ .resize = .{ .cols = r.cols, .rows = r.rows } },
                    .marker => |b| .{ .marker = try allocator.dupe(u8, b) },
                    .exit => |code| .{ .exit = code },
                    .input => .input,
                },
            };
        }

        fn deinit(self: *PendingEvent, allocator: std.mem.Allocator) void {
            switch (self.data) {
                .output => |b| allocator.free(b),
                .marker => |b| allocator.free(b),
                else => {},
            }
        }
    };

    fn noteTime(self: *CastPlayback, t: u64) void {
        if (t > self.max_time_ms) self.max_time_ms = t;
    }

    pub fn destroy(self: *CastPlayback) void {
        const allocator = self.allocator;
        if (self.file) |f| _ = c.fclose(f);
        self.player.deinit();
        if (self.pending) |*p| p.deinit(allocator);
        for (self.markers.items) |m| allocator.free(m.label);
        self.markers.deinit(allocator);
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

/// "~/..." expanded against $HOME; anything else must be absolute.
fn resolveCastPath(buf: []u8, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '/') return path;
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.c.getenv("HOME") orelse return error.CastPathNotAbsolute;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.span(home), path[2..] }) catch
            return error.CastPathTooLong;
    }
    return error.CastPathNotAbsolute;
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// Spawn a cast-playback session: validate the header EAGERLY (a bad
/// file is a spawn error back to the client, never a dead session),
/// size the Screen from the recorded dims, start PAUSED at 0.
pub fn spawnCastSessionWithOrigin(self: *Daemon, req: SpawnReq, origin_id: dmod.SessionOriginId) !*Session {
    const allocator = self.allocator;
    if (req.display) return error.CastSessionCannotBeDisplay;

    var path_buf: [4096]u8 = undefined;
    const path = try resolveCastPath(&path_buf, req.cast_path);
    var z_buf: [4096]u8 = undefined;
    const file = c.fopen(try pathZ(&z_buf, path), "rb") orelse return error.CastFileUnreadable;
    var file_owned: ?*c.FILE = file;
    errdefer if (file_owned) |f| {
        _ = c.fclose(f);
    };

    var player = cast_play.Player.init(allocator);
    var player_owned = true;
    errdefer if (player_owned) player.deinit();

    // Header probe. `next` may hand back the first event; keep it.
    var first: ?CastPlayback.PendingEvent = null;
    errdefer if (first) |*p| p.deinit(allocator);
    while (player.header == null) {
        if (try player.next()) |ev| {
            first = try CastPlayback.PendingEvent.copy(allocator, ev);
            break;
        }
        if (player.header != null) break;
        if (player.eof) return error.BadCastFile;
        var chunk: [32768]u8 = undefined;
        const n = c.fread(&chunk, 1, chunk.len, file);
        if (n == 0) player.feedEof() else try player.feed(chunk[0..n]);
    }
    const h = player.header orelse return error.BadCastFile;

    const cp = try allocator.create(CastPlayback);
    errdefer allocator.destroy(cp);
    const path_owned = try allocator.dupe(u8, path);
    errdefer allocator.free(path_owned);
    cp.* = .{
        .allocator = allocator,
        .path = path_owned,
        .file = file,
        .player = player,
        .header_cols = h.cols,
        .header_rows = h.rows,
        .pending = first,
    };
    if (first) |p| cp.noteTime(p.time_ms);
    // Ownership of file/player/first/path moved into cp; from here a
    // failure tears down through cp.destroy via the session errdefers.
    player_owned = false;
    file_owned = null;
    first = null;
    var cp_owned: ?*CastPlayback = cp;
    errdefer if (cp_owned) |p| p.destroy();

    const pool = try allocator.create(Pool);
    errdefer allocator.destroy(pool);
    pool.* = try Pool.init(allocator);
    errdefer pool.deinit();
    const screen = try Screen.init(allocator, pool, h.cols, h.rows);
    errdefer screen.deinit();
    screen.retain_images = true;
    screen.defer_gui_queries = true;
    // Title from the cast filename (the recording's own OSC titles
    // may overwrite it during playback, exactly like a live app).
    screen.last_title = allocator.dupe(u8, baseName(path)) catch null;

    const s = try allocator.create(Session);
    errdefer allocator.destroy(s);
    const session_name = try allocator.dupe(u8, req.name);
    errdefer allocator.free(session_name);
    const origin_name = try allocator.dupe(u8, req.name);
    errdefer allocator.free(origin_name);
    s.* = .{
        .allocator = allocator,
        .name = session_name,
        .origin_name = origin_name,
        .origin_id = origin_id,
        .source = .{ .cast = cp },
        .parser = Parser.init(allocator),
        .pool = pool,
        .screen = screen,
        .ttl_ms = @as(i64, req.ttl_secs) * 1000,
        .no_viewer_since_ms = nowMs(),
        .last_activity_ms = nowMs(),
        .log = logring.LogRing.init(allocator),
    };
    cp_owned = null; // session deinit owns it now
    screen.sink = .{ .ctx = @ptrCast(s), .on_write_pty = Session.sinkWritePty };
    log.info("session '{s}' spawned kind=cast {d}x{d} file={s}", .{
        req.name, h.cols, h.rows, path,
    });
    return s;
}

// ── playback engine ─────────────────────────────────────────────

/// Poll-timeout clamp + due-work service, the pulseTick shape.
pub fn castTick(self: *Daemon, timeout_ms: i32) i32 {
    var to = timeout_ms;
    const now = nowMs();
    if (castServiceAll(self, now)) |d| {
        const rel: i32 = @intCast(std.math.clamp(d - now, 0, 1000));
        if (to < 0 or rel < to) to = rel;
    }
    return to;
}

/// Service every cast session; returns the nearest absolute deadline.
pub fn castServiceAll(self: *Daemon, now: i64) ?i64 {
    var deadline: ?i64 = null;
    for (self.sessions.items) |s| {
        if (castService(self, s, now)) |d| {
            if (deadline == null or d < deadline.?) deadline = d;
        }
    }
    return deadline;
}

fn advanceClock(cp: *CastPlayback, now: i64) void {
    const dw = now - cp.last_wall_ms;
    cp.last_wall_ms = now;
    if (dw <= 0) return;
    const adv = @as(f64, @floatFromInt(dw)) * cp.speed + cp.frac_ms;
    const whole = @floor(adv);
    cp.position_ms += @intFromFloat(whole);
    cp.frac_ms = adv - whole;
}

/// Wall-ms until a cast-time gap elapses at the current speed.
fn relMs(gap_ms: u64, speed: f64) i64 {
    const w = @ceil(@as(f64, @floatFromInt(gap_ms)) / speed);
    if (w < 1) return 1;
    if (w > 1.0e12) return 1_000_000_000_000;
    return @intFromFloat(w);
}

fn finishPlayback(self: *Daemon, s: *Session, cp: *CastPlayback, now: i64) void {
    cp.duration_ms = cp.max_time_ms;
    cp.position_ms = cp.max_time_ms;
    cp.state = .finished;
    broadcastPlayState(self, s, cp, now);
}

/// One session's playback service. Returns the absolute wake deadline
/// (null = nothing scheduled).
pub fn castService(self: *Daemon, s: *Session, now: i64) ?i64 {
    const cp = s.castPtr() orelse return null;
    if (s.exited) return null;
    if (cp.seek != null) return seekStep(self, s, cp, now);
    if (cp.state != .playing) return null;

    advanceClock(cp, now);

    var deadline: ?i64 = null;
    var out_budget: usize = OUT_BATCH;
    var ev_budget: u32 = EV_BATCH;
    var read_budget: usize = READ_BATCH;
    // Deferred so the "finished" play_state is queued AFTER the last
    // EVENTS frame — clients see the final output before the state.
    var finish = false;
    var col = self.ingestBegin(s);

    loop: while (true) {
        if (ev_budget == 0 or out_budget == 0) {
            cp.want_immediate = true;
            break;
        }
        // A stashed future event always goes first.
        if (cp.pending) |*p| {
            if (p.time_ms > cp.position_ms) {
                deadline = now + relMs(p.time_ms - cp.position_ms, cp.speed);
                break;
            }
            ev_budget -= 1;
            switch (p.data) {
                .output => |b| {
                    out_budget -|= b.len;
                    dmod.ingestBytes(s, &col, b);
                },
                .resize => |r| applyResize(self, s, &col, r.cols, r.rows),
                .marker => |b| addMarker(self, s, cp, p.time_ms, b, now),
                .exit => |code| cp.exit_code = code,
                .input => {},
            }
            p.deinit(self.allocator);
            cp.pending = null;
            continue;
        }
        const got = cp.player.next() catch |err| {
            // Corrupt tail of an untrusted file: retain what played.
            log.warn("cast '{s}': parse error {s}; ending playback", .{ s.name, @errorName(err) });
            finish = true;
            break;
        };
        const ev = got orelse {
            if (cp.player.finished) {
                finish = true;
                break;
            }
            if (read_budget == 0) {
                cp.want_immediate = true;
                break;
            }
            const file = cp.file orelse {
                finish = true;
                break;
            };
            var chunk: [32768]u8 = undefined;
            const want = @min(chunk.len, read_budget);
            const n = c.fread(&chunk, 1, want, file);
            read_budget -= n;
            if (n == 0) {
                cp.player.feedEof();
            } else cp.player.feed(chunk[0..n]) catch |err| {
                log.warn("cast '{s}': {s}; ending playback", .{ s.name, @errorName(err) });
                finishPlayback(self, s, cp, now);
                break;
            };
            continue;
        };
        cp.noteTime(ev.time_ms);
        if (ev.time_ms > cp.position_ms) {
            // Not due yet: stash an owned copy (the player scratch is
            // invalidated by the next `next` call).
            cp.pending = CastPlayback.PendingEvent.copy(self.allocator, ev) catch {
                finish = true;
                break;
            };
            deadline = now + relMs(ev.time_ms - cp.position_ms, cp.speed);
            break :loop;
        }
        ev_budget -= 1;
        switch (ev.event) {
            .output => |b| {
                out_budget -|= b.len;
                dmod.ingestBytes(s, &col, b);
            },
            .resize => |r| applyResize(self, s, &col, r.cols, r.rows),
            .marker => |b| addMarker(self, s, cp, ev.time_ms, b, now),
            .exit => |code| cp.exit_code = code,
            .input => {},
        }
    }
    self.ingestFinish(s, &col, true);
    if (finish) finishPlayback(self, s, cp, now);

    if (cp.state == .playing) {
        if (now - cp.last_push_ms >= STATE_PUSH_MS) broadcastPlayState(self, s, cp, now);
        const push_at = cp.last_push_ms + STATE_PUSH_MS;
        if (deadline == null or push_at < deadline.?) deadline = push_at;
    }
    if (cp.want_immediate) {
        cp.want_immediate = false;
        deadline = now;
    }
    return deadline;
}

/// Recorded resize: flush pending output events first (an event
/// stream assumes a fixed grid), resize, snapshot every client, then
/// continue collecting into a fresh batch. No PTY to setSize.
fn applyResize(self: *Daemon, s: *Session, col: *dmod.EventCollector, cols: u16, rows: u16) void {
    const silent = col.ring == null; // seek replay: no broadcasts
    self.ingestFinish(s, col, !silent);
    s.screen.resize(cols, rows) catch {};
    if (!silent) self.broadcastSnapshot(s);
    col.* = self.ingestBegin(s);
    if (silent) col.ring = null;
}

fn addMarker(self: *Daemon, s: *Session, cp: *CastPlayback, t: u64, label: []const u8, now: i64) void {
    const copy = cp.allocator.dupe(u8, label) catch return;
    cp.markers.append(cp.allocator, .{ .ms = t, .label = copy }) catch {
        cp.allocator.free(copy);
        return;
    };
    // Only live playback announces; seek replay ends in one push.
    if (cp.seek == null) broadcastPlayState(self, s, cp, now);
}

// ── seek ────────────────────────────────────────────────────────

/// Terminal state is cumulative: reset parser + Screen + reader and
/// replay from the start, bounded per tick, silent until the final
/// SNAPSHOT. Fails soft — an unopenable file aborts the seek and
/// leaves current playback state untouched.
fn startSeek(self: *Daemon, s: *Session, cp: *CastPlayback, target_ms: u64, resume_play: bool, now: i64) void {
    const allocator = self.allocator;
    var z_buf: [4096]u8 = undefined;
    const zpath = pathZ(&z_buf, cp.path) catch return;
    const file = c.fopen(zpath, "rb") orelse {
        log.warn("cast '{s}': reopen for seek failed", .{s.name});
        return;
    };
    // Fresh Screen (style pool and images reset with it) + parser.
    const pool = allocator.create(Pool) catch {
        _ = c.fclose(file);
        return;
    };
    pool.* = Pool.init(allocator) catch {
        allocator.destroy(pool);
        _ = c.fclose(file);
        return;
    };
    const screen = Screen.init(allocator, pool, cp.header_cols, cp.header_rows) catch {
        pool.deinit();
        allocator.destroy(pool);
        _ = c.fclose(file);
        return;
    };
    screen.retain_images = true;
    screen.defer_gui_queries = true;
    screen.sink = .{ .ctx = @ptrCast(s), .on_write_pty = Session.sinkWritePty };
    if (s.screen.last_title) |t| screen.last_title = allocator.dupe(u8, t) catch null;
    s.screen.deinit();
    s.pool.deinit();
    allocator.destroy(s.pool);
    s.screen = screen;
    s.pool = pool;
    s.parser.deinit();
    s.parser = Parser.init(allocator);

    if (cp.file) |old| _ = c.fclose(old);
    cp.file = file;
    cp.player.deinit();
    cp.player = cast_play.Player.init(allocator);
    if (cp.pending) |*p| p.deinit(allocator);
    cp.pending = null;
    for (cp.markers.items) |m| allocator.free(m.label);
    cp.markers.clearRetainingCapacity();
    cp.exit_code = null;
    cp.frac_ms = 0;
    cp.position_ms = target_ms;
    cp.seek = .{ .target_ms = target_ms, .resume_play = resume_play };
    broadcastPlayState(self, s, cp, now);
}

/// Bounded seek-replay work; completes with one SNAPSHOT broadcast.
fn seekStep(self: *Daemon, s: *Session, cp: *CastPlayback, now: i64) ?i64 {
    const sk = cp.seek.?;
    var read_budget: usize = SEEK_BATCH;
    var col = self.ingestBegin(s);
    col.ring = null; // silent: don't re-feed the log ring
    var hit_eof = false;
    while (true) {
        const got = cp.player.next() catch |err| {
            log.warn("cast '{s}': parse error {s} during seek", .{ s.name, @errorName(err) });
            hit_eof = true;
            break;
        };
        const ev = got orelse {
            if (cp.player.finished) {
                hit_eof = true;
                break;
            }
            if (read_budget == 0) {
                // More work next tick; keep the "seeking" state.
                self.ingestFinish(s, &col, false);
                return now;
            }
            const file = cp.file orelse {
                hit_eof = true;
                break;
            };
            var chunk: [32768]u8 = undefined;
            const want = @min(chunk.len, read_budget);
            const n = c.fread(&chunk, 1, want, file);
            read_budget -= n;
            if (n == 0) {
                cp.player.feedEof();
            } else cp.player.feed(chunk[0..n]) catch {
                hit_eof = true;
                break;
            };
            continue;
        };
        cp.noteTime(ev.time_ms);
        if (ev.time_ms > sk.target_ms) {
            cp.pending = CastPlayback.PendingEvent.copy(self.allocator, ev) catch null;
            break;
        }
        switch (ev.event) {
            .output => |b| dmod.ingestBytes(s, &col, b),
            .resize => |r| applyResize(self, s, &col, r.cols, r.rows),
            .marker => |b| addMarker(self, s, cp, ev.time_ms, b, now),
            .exit => |code| cp.exit_code = code,
            .input => {},
        }
    }
    self.ingestFinish(s, &col, false);
    cp.seek = null;
    cp.frac_ms = 0;
    cp.last_wall_ms = now;
    if (hit_eof) {
        // Target at/past the end of the recording.
        cp.duration_ms = cp.max_time_ms;
        cp.position_ms = cp.max_time_ms;
        cp.state = .finished;
    } else {
        cp.position_ms = sk.target_ms;
        cp.state = if (sk.resume_play) .playing else .paused;
    }
    self.broadcastSnapshot(s);
    broadcastPlayState(self, s, cp, now);
    return if (cp.state == .playing) now else null;
}

// ── controls / state ────────────────────────────────────────────

/// First-attach hook: playback auto-starts once someone is watching.
pub fn castOnAttach(self: *Daemon, s: *Session, now: i64) void {
    const cp = s.castPtr() orelse return;
    if (cp.ever_attached) return;
    cp.ever_attached = true;
    if (cp.state == .paused and cp.seek == null) {
        cp.state = .playing;
        cp.last_wall_ms = now;
        broadcastPlayState(self, s, cp, now);
    }
}

pub fn handlePlayControl(self: *Daemon, cl: *Client, payload: []const u8) void {
    playControl(self, cl, payload, nowMs());
}

/// `play_control` dispatch. PTY sessions ignore the frame silently.
pub fn playControl(self: *Daemon, cl: *Client, payload: []const u8, now: i64) void {
    const s = cl.attached orelse {
        cl.queueErr("not attached");
        return;
    };
    const cp = s.castPtr() orelse return;
    const Req = struct { op: []const u8 = "", ms: u64 = 0, speed: f64 = 1.0 };
    var parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad play_control request");
        return;
    };
    defer parsed.deinit();
    const req = parsed.value;
    if (std.mem.eql(u8, req.op, "play")) {
        if (cp.seek != null) {
            cp.seek.?.resume_play = true;
        } else if (cp.state == .paused) {
            cp.state = .playing;
            cp.last_wall_ms = now;
        }
        broadcastPlayState(self, s, cp, now);
    } else if (std.mem.eql(u8, req.op, "pause")) {
        if (cp.seek != null) {
            cp.seek.?.resume_play = false;
        } else if (cp.state == .playing) {
            advanceClock(cp, now);
            cp.state = .paused;
        }
        broadcastPlayState(self, s, cp, now);
    } else if (std.mem.eql(u8, req.op, "restart")) {
        startSeek(self, s, cp, 0, true, now);
    } else if (std.mem.eql(u8, req.op, "seek")) {
        var target = req.ms;
        if (cp.duration_ms) |d| target = @min(target, d);
        const resume_play = if (cp.seek) |sk| sk.resume_play else cp.state == .playing;
        startSeek(self, s, cp, target, resume_play, now);
    } else if (std.mem.eql(u8, req.op, "speed")) {
        const clamped = std.math.clamp(req.speed, 0.1, 10.0);
        if (cp.state == .playing) advanceClock(cp, now);
        cp.speed = clamped;
        broadcastPlayState(self, s, cp, now);
    }
    // Unknown ops are ignored (append-only).
}

fn stateName(cp: *const CastPlayback) []const u8 {
    if (cp.seek != null) return "seeking";
    return switch (cp.state) {
        .paused => "paused",
        .playing => "playing",
        .finished => "finished",
    };
}

const MarkerTuple = struct { u64, []const u8 };

fn markerTuples(cp: *const CastPlayback, buf: []MarkerTuple) []const MarkerTuple {
    const items = cp.markers.items;
    const n = @min(items.len, buf.len);
    const start = items.len - n;
    for (items[start..], 0..) |m, i| buf[i] = .{ m.ms, m.label };
    return buf[0..n];
}

/// One client's play_state (attach path; does not reset the throttle).
pub fn queuePlayState(cl: *Client, cp: *const CastPlayback) void {
    var tuples: [MAX_STATE_MARKERS]MarkerTuple = undefined;
    cl.queueJson(.play_state, .{
        .state = stateName(cp),
        .position_ms = cp.position_ms,
        .duration_ms = cp.duration_ms,
        .speed = cp.speed,
        .markers = markerTuples(cp, &tuples),
    });
}

pub fn broadcastPlayState(self: *Daemon, s: *Session, cp: *CastPlayback, now: i64) void {
    cp.last_push_ms = now;
    for (self.clients.items) |cl| {
        if (Daemon.terminalViewer(cl, s)) queuePlayState(cl, cp);
    }
}

// ---------------------------------------------------------------------------
// Tests (GTK-free; drive the engine on a synthetic clock)
// ---------------------------------------------------------------------------

const testing = std.testing;
const wire = @import("wire.zig");
const daemon_serve = @import("daemon_serve.zig");

/// A daemon shell with no sockets — the same shape a broker worker
/// uses (listen_fd -1), enough for spawn/ingest/broadcast logic.
fn newTestDaemon(a: std.mem.Allocator) !*Daemon {
    const d = try a.create(Daemon);
    d.* = .{ .allocator = a, .listen_fd = -1, .sock_path = try a.dupe(u8, "") };
    return d;
}

fn newTestClient(d: *Daemon, s: *Session) !*Client {
    const cl = try d.allocator.create(Client);
    cl.* = .{ .allocator = d.allocator, .fd = -1 };
    try d.clients.append(d.allocator, cl);
    cl.attached = s;
    return cl;
}

fn writeTempCast(a: std.mem.Allocator, contents: []const u8) ![]u8 {
    var tmpl = "/tmp/sketerm-castplay-XXXXXX".*;
    const fd = c.mkstemp(&tmpl);
    if (fd < 0) return error.TempFailed;
    defer _ = c.close(fd);
    if (c.write(fd, contents.ptr, contents.len) != @as(isize, @intCast(contents.len)))
        return error.TempFailed;
    return a.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(&tmpl))));
}

fn unlinkPath(path: []const u8) void {
    var z: [4096]u8 = undefined;
    if (pathZ(&z, path)) |p| {
        _ = c.unlink(p);
    } else |_| {}
}

fn spawnCast(d: *Daemon, path: []const u8, name: []const u8) !*Session {
    const s = try d.spawnSession(.{ .name = name, .cast_path = path });
    try d.sessions.append(d.allocator, s);
    return s;
}

const TFrame = struct { ftype: wire.FrameType, payload: []u8 };

/// Drain a test client's queued frames into owned copies.
fn takeFrames(a: std.mem.Allocator, cl: *Client, out: *std.ArrayList(TFrame)) !void {
    var pos: usize = 0;
    while (try wire.peelFrame(cl.wbuf.items[pos..])) |p| {
        try out.append(a, .{
            .ftype = p.frame.ftype,
            .payload = try a.dupe(u8, p.frame.payload),
        });
        pos += p.consumed;
    }
    cl.wbuf.clearRetainingCapacity();
}

fn freeFrames(a: std.mem.Allocator, list: *std.ArrayList(TFrame)) void {
    for (list.items) |f| a.free(f.payload);
    list.deinit(a);
}

/// Printable text carried by one EVENTS frame payload, plus a count
/// of APC events (kitty filter assertions).
fn decodeEvents(a: std.mem.Allocator, payload: []const u8, text: *std.ArrayList(u8), apc_count: *usize) !void {
    try testing.expect(payload.len >= 12);
    var r = wire.Reader.init(payload[12..]);
    while (!r.atEnd()) {
        var ev = try r.getEvent(a);
        defer ev.deinit(a);
        switch (ev) {
            .print => |cp| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch 0;
                try text.appendSlice(a, buf[0..n]);
            },
            .print_byte => |b| try text.append(a, b),
            .print_run => |run| try text.appendSlice(a, run.bytes[0..run.len]),
            .apc => apc_count.* += 1,
            else => {},
        }
    }
}

/// All EVENTS-frame text a client received, in order.
fn eventsText(a: std.mem.Allocator, frames: []const TFrame, apc_count: *usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    for (frames) |f| {
        if (f.ftype == .events) try decodeEvents(a, f.payload, &text, apc_count);
    }
    return text.toOwnedSlice(a);
}

fn countFrames(frames: []const TFrame, ftype: wire.FrameType) usize {
    var n: usize = 0;
    for (frames) |f| {
        if (f.ftype == ftype) n += 1;
    }
    return n;
}

/// Drive playback with a synthetic clock until finished (bounded).
fn playToEnd(d: *Daemon, s: *Session, from: i64) !void {
    const cp = s.castPtr().?;
    var now = from;
    var guard: u32 = 0;
    while (cp.state != .finished) : (guard += 1) {
        try testing.expect(guard < 10_000);
        _ = castServiceAll(d, now);
        now += 1000;
    }
}

/// Drive a pending seek to completion (bounded).
fn seekSettle(d: *Daemon, s: *Session, now: i64) !void {
    const cp = s.castPtr().?;
    var guard: u32 = 0;
    while (cp.seek != null) : (guard += 1) {
        try testing.expect(guard < 10_000);
        _ = castServiceAll(d, now);
    }
}

const simple_cast =
    \\{"version": 2, "width": 20, "height": 5}
    \\[0.1, "o", "hello"]
    \\[0.3, "o", " world"]
    \\
;

test "cast spawn: header validated eagerly, screen sized from it, paused at 0" {
    const a = testing.allocator;
    const d = try newTestDaemon(a);
    defer d.deinit();
    const path = try writeTempCast(a, simple_cast);
    defer {
        unlinkPath(path);
        a.free(path);
    }
    const s = try spawnCast(d, path, "c1");
    const cp = s.castPtr().?;
    try testing.expectEqual(@as(u16, 20), s.screen.cols);
    try testing.expectEqual(@as(u16, 5), s.screen.rows);
    try testing.expectEqual(CastPlayback.State.paused, cp.state);
    try testing.expectEqual(@as(u64, 0), cp.position_ms);
    try testing.expectEqual(@as(c_int, -1), s.masterFd());
    try testing.expectEqual(@as(c.pid_t, -1), s.childPid());
    try testing.expect(s.screen.last_title != null);

    // Bad files are SPAWN errors, not dead sessions.
    const bad = try writeTempCast(a, "not a cast at all\n");
    defer {
        unlinkPath(bad);
        a.free(bad);
    }
    try testing.expectError(error.BadHeader, d.spawnSession(.{ .name = "b", .cast_path = bad }));
    try testing.expectError(
        error.CastFileUnreadable,
        d.spawnSession(.{ .name = "b", .cast_path = "/nonexistent/sketerm.cast" }),
    );
    try testing.expectError(
        error.CastPathNotAbsolute,
        d.spawnSession(.{ .name = "b", .cast_path = "relative.cast" }),
    );
}

test "identity-first attach is capability-gated and preserves legacy snapshot order" {
    const a = testing.allocator;
    const d = try newTestDaemon(a);
    defer d.deinit();
    const path = try writeTempCast(a, simple_cast);
    defer {
        unlinkPath(path);
        a.free(path);
    }
    const s = try spawnCast(d, path, "identity-order");
    const legacy = try newTestClient(d, s);
    legacy.attached = null;
    legacy.kind = .unknown;
    legacy.panel_rpc_support = wire.PANEL_RPC_VERSION;
    daemon_serve.handleFrame(d, legacy, .{
        .ftype = .attach,
        .payload = "{\"name\":\"identity-order\",\"kind\":\"gui\",\"panel_rpc\":1}",
    });
    var first = (try wire.peelFrame(legacy.wbuf.items)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(wire.FrameType.snapshot, first.frame.ftype);

    const current = try newTestClient(d, s);
    current.attached = null;
    current.kind = .unknown;
    current.panel_rpc_support = wire.PANEL_RPC_VERSION;
    daemon_serve.handleFrame(d, current, .{
        .ftype = .attach,
        .payload = "{\"name\":\"identity-order\",\"kind\":\"gui\",\"panel_rpc\":1,\"identity_first\":true}",
    });
    first = (try wire.peelFrame(current.wbuf.items)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(wire.FrameType.session_meta, first.frame.ftype);
    const second = (try wire.peelFrame(current.wbuf.items[first.consumed..])) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(wire.FrameType.snapshot, second.frame.ftype);
    try testing.expect(std.mem.indexOf(u8, first.frame.payload, "\"origin_id\"") != null);
}

test "playback: timed events reach a subscribed client in order; EOF retains screen" {
    const a = testing.allocator;
    const d = try newTestDaemon(a);
    defer d.deinit();
    const path = try writeTempCast(a, simple_cast);
    defer {
        unlinkPath(path);
        a.free(path);
    }
    const s = try spawnCast(d, path, "c1");
    const cl = try newTestClient(d, s);
    const cp = s.castPtr().?;

    // Attach through the real path: auto-play on first attach.
    cl.attached = null;
    daemon_serve.handleFrame(d, cl, .{ .ftype = .attach, .payload = "{\"name\":\"c1\",\"kind\":\"cli\"}" });
    try testing.expectEqual(CastPlayback.State.playing, cp.state);
    {
        var frames: std.ArrayList(TFrame) = .empty;
        defer freeFrames(a, &frames);
        try takeFrames(a, cl, &frames);
        try testing.expect(countFrames(frames.items, .snapshot) == 1);
        try testing.expect(countFrames(frames.items, .play_state) >= 1);
    }
    // Re-pin the clock so the test is deterministic.
    const t0: i64 = 100_000;
    cp.last_wall_ms = t0;
    cp.last_push_ms = t0;

    // Before the first event is due: nothing but a scheduled wake.
    const dl = castServiceAll(d, t0 + 50);
    try testing.expectEqual(@as(?i64, t0 + 100), dl);
    try testing.expectEqual(@as(usize, 0), cl.wbuf.items.len);

    // First event due.
    _ = castServiceAll(d, t0 + 150);
    {
        var frames: std.ArrayList(TFrame) = .empty;
        defer freeFrames(a, &frames);
        try takeFrames(a, cl, &frames);
        var apcs: usize = 0;
        const text = try eventsText(a, frames.items, &apcs);
        defer a.free(text);
        try testing.expectEqualStrings("hello", text);
    }

    // Rest of the cast + EOF.
    _ = castServiceAll(d, t0 + 1000);
    {
        var frames: std.ArrayList(TFrame) = .empty;
        defer freeFrames(a, &frames);
        try takeFrames(a, cl, &frames);
        var apcs: usize = 0;
        const text = try eventsText(a, frames.items, &apcs);
        defer a.free(text);
        try testing.expectEqualStrings(" world", text);
        try testing.expect(countFrames(frames.items, .play_state) >= 1);
    }
    try testing.expectEqual(CastPlayback.State.finished, cp.state);
    try testing.expectEqual(@as(?u64, 300), cp.duration_ms);
    try testing.expect(!s.exited);
    const sb = try s.screen.extractScrollback(a);
    defer a.free(sb);
    try testing.expect(std.mem.indexOf(u8, sb, "hello world") != null);
}

test "recorded resize flushes output, resizes the grid and snapshots clients" {
    const a = testing.allocator;
    const d = try newTestDaemon(a);
    defer d.deinit();
    const text =
        \\{"version": 2, "width": 20, "height": 5}
        \\[0.1, "o", "before"]
        \\[0.2, "r", "30x10"]
        \\[0.3, "o", "after"]
        \\
    ;
    const path = try writeTempCast(a, text);
    defer {
        unlinkPath(path);
        a.free(path);
    }
    const s = try spawnCast(d, path, "c1");
    const cl = try newTestClient(d, s);
    const cp = s.castPtr().?;
    const t0: i64 = 50_000;
    castOnAttach(d, s, t0);
    cl.wbuf.clearRetainingCapacity();

    _ = castServiceAll(d, t0 + 5000);
    try testing.expectEqual(@as(u16, 30), s.screen.cols);
    try testing.expectEqual(@as(u16, 10), s.screen.rows);
    var frames: std.ArrayList(TFrame) = .empty;
    defer freeFrames(a, &frames);
    try takeFrames(a, cl, &frames);
    try testing.expect(countFrames(frames.items, .snapshot) >= 1);
    var apcs: usize = 0;
    const all = try eventsText(a, frames.items, &apcs);
    defer a.free(all);
    try testing.expectEqualStrings("beforeafter", all);
    // Events around the resize stay ordered across the snapshot.
    var seen_snapshot = false;
    var before_snapshot: usize = 0;
    for (frames.items) |f| {
        if (f.ftype == .snapshot) seen_snapshot = true;
        if (f.ftype == .events and !seen_snapshot) before_snapshot += 1;
    }
    try testing.expect(before_snapshot >= 1);
    _ = cp;
}

test "client input and resize frames are rejected on cast sessions" {
    const a = testing.allocator;
    const d = try newTestDaemon(a);
    defer d.deinit();
    const path = try writeTempCast(a, simple_cast);
    defer {
        unlinkPath(path);
        a.free(path);
    }
    const s = try spawnCast(d, path, "c1");
    const cl = try newTestClient(d, s);

    // Input: silently dropped (no crash, no error frame).
    daemon_serve.handleFrame(d, cl, .{ .ftype = .input, .payload = "rm -rf /\n" });
    try testing.expectEqual(@as(usize, 0), cl.wbuf.items.len);

    // Resize: recorded dimensions win; the request is ignored.
    var rz: [4]u8 = undefined;
    std.mem.writeInt(u16, rz[0..2], 40, .little);
    std.mem.writeInt(u16, rz[2..4], 90, .little);
    daemon_serve.handleFrame(d, cl, .{ .ftype = .resize, .payload = &rz });
    try testing.expectEqual(@as(u16, 20), s.screen.cols);
    try testing.expectEqual(@as(u16, 5), s.screen.rows);
    try testing.expectEqual(@as(usize, 0), cl.wbuf.items.len);

    // rec_start: recording a playback is refused.
    daemon_serve.handleFrame(d, cl, .{ .ftype = .rec_start, .payload = "{\"path\":\"/tmp/x.cast\"}" });
    var frames: std.ArrayList(TFrame) = .empty;
    defer freeFrames(a, &frames);
    try takeFrames(a, cl, &frames);
    try testing.expectEqual(@as(usize, 1), countFrames(frames.items, .err));
}

test "kitty file/tempfile/shm APCs are neutralized; direct passes" {
    const a = testing.allocator;
    const d = try newTestDaemon(a);
    defer d.deinit();

    // A real file the hostile cast points at (t=t would DELETE it).
    const victim = try writeTempCast(a, "SECRET");
    defer {
        unlinkPath(victim);
        a.free(victim);
    }
    const enc = std.base64.standard.Encoder;
    const vb64 = try a.alloc(u8, enc.calcSize(victim.len));
    defer a.free(vb64);
    _ = enc.encode(vb64, victim);

    var cast_text: std.ArrayList(u8) = .empty;
    defer cast_text.deinit(a);
    try cast_text.appendSlice(a, "{\"version\": 2, \"width\": 20, \"height\": 5}\n");
    const cast_mod = @import("cast.zig");
    {
        var apc_t: std.ArrayList(u8) = .empty;
        defer apc_t.deinit(a);
        try apc_t.appendSlice(a, "\x1b_Gf=100,t=t,a=T;");
        try apc_t.appendSlice(a, vb64);
        try apc_t.appendSlice(a, "\x1b\\");
        try cast_mod.appendEvent(a, &cast_text, 100, 'o', apc_t.items);
    }
    {
        var apc_f: std.ArrayList(u8) = .empty;
        defer apc_f.deinit(a);
        try apc_f.appendSlice(a, "\x1b_Gf=100,t=f,a=T;");
        try apc_f.appendSlice(a, vb64);
        try apc_f.appendSlice(a, "\x1b\\");
        try cast_mod.appendEvent(a, &cast_text, 150, 'o', apc_f.items);
    }
    // A direct (t=d) transmission must survive the filter.
    try cast_mod.appendEvent(a, &cast_text, 200, 'o', "\x1b_Gf=100,t=d,a=T;QUJD\x1b\\");

    const path = try writeTempCast(a, cast_text.items);
    defer {
        unlinkPath(path);
        a.free(path);
    }
    const s = try spawnCast(d, path, "c1");
    const cl = try newTestClient(d, s);
    const t0: i64 = 50_000;
    castOnAttach(d, s, t0);
    cl.wbuf.clearRetainingCapacity();
    try playToEnd(d, s, t0 + 5000);

    var frames: std.ArrayList(TFrame) = .empty;
    defer freeFrames(a, &frames);
    try takeFrames(a, cl, &frames);
    var apcs: usize = 0;
    const text = try eventsText(a, frames.items, &apcs);
    defer a.free(text);
    // Only the t=d APC came through; t=t / t=f were dropped.
    try testing.expectEqual(@as(usize, 1), apcs);
    // The tempfile was neither read nor deleted.
    var z: [4096]u8 = undefined;
    try testing.expect(c.access(try pathZ(&z, victim), c.F_OK) == 0);
}

test "play_control: pause/play/speed clamp on a synthetic clock" {
    const a = testing.allocator;
    const d = try newTestDaemon(a);
    defer d.deinit();
    const text =
        \\{"version": 2, "width": 20, "height": 5}
        \\[1.0, "o", "A"]
        \\[2.0, "o", "B"]
        \\
    ;
    const path = try writeTempCast(a, text);
    defer {
        unlinkPath(path);
        a.free(path);
    }
    const s = try spawnCast(d, path, "c1");
    const cl = try newTestClient(d, s);
    const cp = s.castPtr().?;
    const t0: i64 = 10_000;
    castOnAttach(d, s, t0);
    try testing.expectEqual(CastPlayback.State.playing, cp.state);

    // Pause at +500: the clock stops there.
    playControl(d, cl, "{\"op\":\"pause\"}", t0 + 500);
    try testing.expectEqual(CastPlayback.State.paused, cp.state);
    try testing.expectEqual(@as(u64, 500), cp.position_ms);
    _ = castServiceAll(d, t0 + 60_000);
    try testing.expectEqual(@as(u64, 500), cp.position_ms);

    // Resume much later: no cast time was lost while paused.
    const t1: i64 = t0 + 100_000;
    playControl(d, cl, "{\"op\":\"play\"}", t1);
    cl.wbuf.clearRetainingCapacity();
    _ = castServiceAll(d, t1 + 600); // position 1100: "A" due, "B" not
    {
        var frames: std.ArrayList(TFrame) = .empty;
        defer freeFrames(a, &frames);
        try takeFrames(a, cl, &frames);
        var apcs: usize = 0;
        const got = try eventsText(a, frames.items, &apcs);
        defer a.free(got);
        try testing.expectEqualStrings("A", got);
    }

    // 4x speed: 250 wall ms covers the remaining 900 cast ms.
    playControl(d, cl, "{\"op\":\"speed\",\"speed\":4.0}", t1 + 600);
    _ = castServiceAll(d, t1 + 850);
    {
        var frames: std.ArrayList(TFrame) = .empty;
        defer freeFrames(a, &frames);
        try takeFrames(a, cl, &frames);
        var apcs: usize = 0;
        const got = try eventsText(a, frames.items, &apcs);
        defer a.free(got);
        try testing.expectEqualStrings("B", got);
    }

    // Speed clamps to [0.1, 10].
    playControl(d, cl, "{\"op\":\"speed\",\"speed\":100}", t1 + 900);
    try testing.expectEqual(@as(f64, 10.0), cp.speed);
    playControl(d, cl, "{\"op\":\"speed\",\"speed\":0.001}", t1 + 900);
    try testing.expectEqual(@as(f64, 0.1), cp.speed);
}

const rich_cast =
    \\{"version": 2, "width": 20, "height": 5}
    \\[0.1, "o", "one "]
    \\[0.5, "r", "30x8"]
    \\[1.0, "o", "two"]
    \\[1.5, "m", "half"]
    \\[2.0, "o", " three"]
    \\
;

test "seek replays deterministically: same grid as linear play" {
    const a = testing.allocator;
    const d = try newTestDaemon(a);
    defer d.deinit();
    const path = try writeTempCast(a, rich_cast);
    defer {
        unlinkPath(path);
        a.free(path);
    }
    const t0: i64 = 10_000;

    // Linear reference: play to a mid position, capture the grid.
    const s1 = try spawnCast(d, path, "lin");
    {
        const cp = s1.castPtr().?;
        cp.state = .playing;
        cp.last_wall_ms = t0;
        _ = castServiceAll(d, t0 + 1200);
        try testing.expectEqual(@as(u64, 1200), cp.position_ms);
    }
    const lin_mid = try s1.screen.extractScrollback(a);
    defer a.free(lin_mid);
    const lin_mid_cols = s1.screen.cols;

    // Seek session: jump straight to 1200.
    const s2 = try spawnCast(d, path, "seek");
    const cl2 = try newTestClient(d, s2);
    playControl(d, cl2, "{\"op\":\"seek\",\"ms\":1200}", t0);
    try seekSettle(d, s2, t0);
    {
        const cp = s2.castPtr().?;
        try testing.expectEqual(@as(u64, 1200), cp.position_ms);
        try testing.expectEqual(CastPlayback.State.paused, cp.state);
        // The marker at 1500ms is beyond the target: not seen yet.
        try testing.expectEqual(@as(usize, 0), cp.markers.items.len);
    }
    const seek_mid = try s2.screen.extractScrollback(a);
    defer a.free(seek_mid);
    try testing.expectEqualStrings(lin_mid, seek_mid);
    try testing.expectEqual(lin_mid_cols, s2.screen.cols);

    // And the full-length comparison: linear EOF vs seek-past-EOF.
    try playToEnd(d, s1, t0 + 2000);
    const lin_end = try s1.screen.extractScrollback(a);
    defer a.free(lin_end);

    playControl(d, cl2, "{\"op\":\"seek\",\"ms\":99999}", t0);
    try seekSettle(d, s2, t0);
    {
        const cp = s2.castPtr().?;
        try testing.expectEqual(CastPlayback.State.finished, cp.state);
        try testing.expectEqual(@as(?u64, 2000), cp.duration_ms);
        try testing.expectEqual(@as(u64, 2000), cp.position_ms);
        try testing.expectEqual(@as(usize, 1), cp.markers.items.len);
        try testing.expectEqual(@as(u64, 1500), cp.markers.items[0].ms);
    }
    const seek_end = try s2.screen.extractScrollback(a);
    defer a.free(seek_end);
    try testing.expectEqualStrings(lin_end, seek_end);

    // Restart = seek 0 and play from the top.
    cl2.wbuf.clearRetainingCapacity();
    playControl(d, cl2, "{\"op\":\"restart\"}", t0);
    try seekSettle(d, s2, t0);
    {
        const cp = s2.castPtr().?;
        try testing.expectEqual(@as(u64, 0), cp.position_ms);
        try testing.expectEqual(CastPlayback.State.playing, cp.state);
        try testing.expectEqual(@as(u16, 20), s2.screen.cols); // header dims again
        var frames: std.ArrayList(TFrame) = .empty;
        defer freeFrames(a, &frames);
        try takeFrames(a, cl2, &frames);
        try testing.expect(countFrames(frames.items, .snapshot) >= 1);
        try testing.expect(countFrames(frames.items, .play_state) >= 1);
    }
}
