//! fsdrive: mux file-service client (fs_op / fs_write frames).
//!
//! The client half of the phase-1 file browser (docs/
//! filebrowser-roadmap.md): rich listings, live directory views with
//! pushed deltas, ranged read/write, and the small mutation verbs —
//! all over one mux connection (local socket, SSH, or UDP; the
//! transport is Conn's business). GTK-free and libc-only so it serves
//! the GUI browser pane, MCP tools, and headless smokes alike.
//!
//! No-hang invariant: every wait is deadline-bounded (recvFrameFor);
//! replies are matched by the `req` nonce in the fs_reply HEADER,
//! never by arrival order, and fs_delta pushes arriving mid-wait are
//! stashed, not dropped.

const std = @import("std");
const c = @import("../c.zig").c;
const client = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
pub const fsserve = @import("../mux/fsserve.zig");
/// The gutter's model, shared with the daemon that fills it: the
/// `git_diff` job parses on the host and ships `gitdiff.Run`s, so
/// producer and consumer cannot drift.
pub const gitdiff = @import("../editor/gitdiff.zig");

const nowMs = @import("../util/clock.zig").nowMs;

pub const Entry = fsserve.Entry;

/// Inactivity bound on any single fs round trip: the wait dies only
/// after this long with NO bytes arriving. A slow link that is still
/// moving data is alive, not timed out (the old flat completion
/// deadline tore down healthy connections mid-chunk).
pub const OP_TIMEOUT_MS: i64 = 10_000;
/// Hard cap on one op wait however slowly bytes trickle in — keeps
/// the no-hang invariant under the 150s MCP watchdog.
pub const OP_CAP_MS: i64 = 120_000;
/// Assumed worst-case honest uplink for sizing write waits: a bulk
/// fs_write's ack cannot arrive before the payload has left, so the
/// wait budget grows with the payload (flat 10s misread a working
/// slow uplink as a dead link).
const WRITE_MIN_RATE: u64 = 32 * 1024; // bytes/sec

/// Bytes per staged fs_write in writeFileAtomic — the same 1 MiB
/// fstransfer moves, comfortably inside wire.MAX_FRAME.
pub const SAVE_CHUNK: usize = 1 << 20;

pub const Error = error{
    NotConnected,
    Timeout,
    /// Daemon answered ok:false — message in `lastErr()`.
    FsOpFailed,
    BadReply,
    /// Caller-side argument the client library refuses to send.
    BadRequest,
    /// install: the destination changed underneath the caller. The
    /// destination's fresh identity is in `lastConflict()`.
    Conflict,
    OutOfMemory,
};

/// A collected listing (open_view or one-shot list). Entry strings
/// live in the listing's own arena.
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8 = "",
    entries: []Entry = &.{},
    truncated: bool = false,
    /// Device id of the listed directory: what decides whether a hard
    /// link INTO it could work, without a per-entry cost.
    dev: u64 = 0,

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
    }
};

/// One pushed view delta. Owned by its arena; free via deinit.
pub const Delta = struct {
    arena: std.heap.ArenaAllocator,
    view: u32 = 0,
    gone: bool = false,
    resync: bool = false,
    changes: []Change = &.{},

    pub const Change = struct {
        op: []const u8 = "",
        name: []const u8 = "",
        entry: ?Entry = null,
    };

    pub fn deinit(self: *Delta) void {
        self.arena.deinit();
    }
};

pub const WriteFlags = struct {
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,

    fn byte(self: WriteFlags) u8 {
        var b: u8 = 0;
        if (self.create) b |= 1;
        if (self.truncate) b |= 2;
        if (self.append) b |= 4;
        if (self.exclusive) b |= 8;
        return b;
    }
};

/// Result of a ranged read. `mtime_ns`/`ino` come from the fd the
/// bytes were read through, so they are a race-free baseline for a
/// later conflict-checked save (0 from a daemon that predates them).
pub const ReadInfo = struct {
    size: u64,
    eof: bool,
    mtime_ns: i64 = 0,
    ino: u64 = 0,
};

/// The destination's stat identity after an install — the caller's
/// next conflict baseline, and what a refused install reports about
/// the file that changed. Scalars only: no arena to outlive the call.
pub const InstallResult = struct {
    mtime_ns: i64 = 0,
    mtime_ms: i64 = 0,
    size: u64 = 0,
    mode: u32 = 0,
    ino: u64 = 0,

    fn of(e: Entry) InstallResult {
        return .{
            .mtime_ns = e.mtime_ns,
            .mtime_ms = e.mtime_ms,
            .size = e.size,
            .mode = e.mode,
            .ino = e.ino,
        };
    }
};

pub const StatFs = struct {
    bsize: u64 = 0,
    frsize: u64 = 0,
    blocks: u64 = 0,
    bfree: u64 = 0,
    bavail: u64 = 0,
    files: u64 = 0,
    ffree: u64 = 0,
    namemax: u64 = 255,
};

/// One row of a job_list reply.
pub const JobRow = struct {
    job: u64 = 0,
    op: []const u8 = "",
    state: []const u8 = "",
    done: u64 = 0,
    total: u64 = 0,
    src: []const u8 = "",
    dst: []const u8 = "",
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    client_token: []const u8 = "",
    message: []const u8 = "",
};

/// Superset JSON shape of every fs_reply; absent fields keep their
/// defaults, unknown (future) fields are ignored.
const Reply = struct {
    req: u32 = 0,
    ok: bool = false,
    @"error": []const u8 = "",
    path: []const u8 = "",
    entries: []Entry = &.{},
    more: bool = false,
    truncated: bool = false,
    entry: ?Entry = null,
    size: u64 = 0,
    eof: bool = false,
    written: u64 = 0,
    job: u64 = 0,
    jobs: []JobRow = &.{},
    bsize: u64 = 0,
    frsize: u64 = 0,
    blocks: u64 = 0,
    bfree: u64 = 0,
    bavail: u64 = 0,
    files: u64 = 0,
    ffree: u64 = 0,
    namemax: u64 = 255,
    home: []const u8 = "",
    cache: []const u8 = "",
    templates: []const u8 = "",
    dev: u64 = 0,
    mtime_ns: i64 = 0,
    ino: u64 = 0,
};

/// The host's own directory identities. Resolved by the daemon that
/// owns the files, so a remote host answers with ITS paths.
pub const HostDirs = struct {
    home: []const u8 = "",
    cache: []const u8 = "",
    templates: []const u8 = "",
};

// ── batched media metadata ──────────────────────────────────────
//
// One request names many files; the daemon answers with one match
// event per name, each carrying a flat key/value list (the namespace
// is documented in src/mux/mediameta.zig). Extraction and caching
// happen on the host that owns the files: no per-row round trip and
// no file bytes on the wire.

/// Separator inside a media_meta name list. ASCII US survives JSON
/// transport and is not something real filenames usefully carry.
pub const MEDIA_SEP: u8 = 0x1F;
/// Names per request; the daemon rejects a larger batch outright, so
/// callers must chunk (the browser asks for the VISIBLE rows).
pub const MEDIA_BATCH_MAX: usize = 128;

pub const MediaField = struct { k: []const u8 = "", v: []const u8 = "" };

/// One file's metadata. `note` is set instead of `fields` when the
/// daemon skipped the file (not a regular file, unreadable, empty).
pub const MediaResult = struct {
    path: []const u8 = "",
    kind: []const u8 = "",
    cached: bool = false,
    note: []const u8 = "",
    fields: []const MediaField = &.{},

    pub fn get(self: MediaResult, key: []const u8) ?[]const u8 {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.k, key)) return f.v;
        }
        return null;
    }
};

/// One pushed fs_job event, arena-owned.
pub const JobEvent = struct {
    arena: std.heap.ArenaAllocator,
    job: u64 = 0,
    ev: []const u8 = "",
    state: []const u8 = "",
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    hash: []const u8 = "",
    message: []const u8 = "",
    /// find/grep match payload (ev == "match").
    path: []const u8 = "",
    line: u64 = 0,
    text: []const u8 = "",
    kind: []const u8 = "",
    size: u64 = 0,
    mtime_ms: i64 = 0,
    matches: u64 = 0,
    truncated: bool = false,
    /// Live-query status detail (ev == "ready"): how many directories
    /// the query watches, and whether the watch cap stopped it.
    watches: u64 = 0,
    watch_limit: bool = false,
    /// panelize: output lines that named nothing on disk, plus the
    /// command's exit status (both on the done event).
    rejected: u64 = 0,
    exit_status: i64 = 0,
    /// Progress detail: the entry in flight (sticky daemon-side, so
    /// present on every event once the job has named one) plus the
    /// entry counters of a tree operation.
    file: []const u8 = "",
    files_done: u64 = 0,
    files_total: u64 = 0,
    /// media_meta match payload: extracted fields plus whether the
    /// daemon served them from its cache.
    meta: []const MediaField = &.{},
    cached: bool = false,
    /// done: `path` is a persistent host-side cache file.
    keep: bool = false,
    /// git_status match detail: the two porcelain-v2 columns (`M.`,
    /// `.M`, `??`, `UU`, …) and a rename/copy source path.
    xy: []const u8 = "",
    orig: []const u8 = "",
    /// git_status `repo` event: the branch header of the browsed
    /// root. Absent entirely from a daemon too old to report it.
    /// git_diff sends the same event for its own three states, of
    /// which only `repo`, `tracked`, `initial` and `truncated` mean
    /// anything.
    repo: bool = false,
    /// git_diff `repo` event: git tracks the file.
    tracked: bool = false,
    branch: []const u8 = "",
    upstream: []const u8 = "",
    ahead: i64 = 0,
    behind: i64 = 0,
    have_ab: bool = false,
    detached: bool = false,
    initial: bool = false,
    root: bool = false,

    pub fn deinit(self: *JobEvent) void {
        self.arena.deinit();
    }

    pub fn terminal(self: *const JobEvent) bool {
        return std.mem.eql(u8, self.ev, "done") or std.mem.eql(u8, self.ev, "error") or
            std.mem.eql(u8, self.ev, "canceled");
    }
};

/// Final outcome of a job wait — fixed buffers, no ownership.
pub const JobEnd = struct {
    ok: bool = false,
    canceled: bool = false,
    bytes_done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    hash: [64]u8 = undefined,
    has_hash: bool = false,
    message: [192]u8 = undefined,
    message_len: usize = 0,

    pub fn messageText(self: *const JobEnd) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub const Fs = struct {
    allocator: std.mem.Allocator,
    conn: client.Conn,
    next_req: u32 = 1,
    /// fs_delta frames that arrived while awaiting a reply; consumed
    /// via takeDelta(). Bounded by consumption — a caller that opens
    /// views must drain deltas.
    deltas: std.ArrayList(Delta) = .empty,
    /// fs_job frames stashed the same way; consumed via takeJobEvent
    /// / waitJobEnd.
    job_events: std.ArrayList(JobEvent) = .empty,
    last_err: [192]u8 = undefined,
    last_err_len: usize = 0,
    /// Set by the last install refused as `conflict`.
    conflict: ?InstallResult = null,
    /// Distinguishes concurrent atomic saves from one connection.
    save_seq: u32 = 0,

    /// Adopt an already hello-probed connection (ownership moves).
    pub fn initConn(allocator: std.mem.Allocator, conn: client.Conn) Fs {
        return .{ .allocator = allocator, .conn = conn };
    }

    /// Connect to a daemon socket and complete the hello probe.
    pub fn connect(allocator: std.mem.Allocator, sock_path: []const u8) !Fs {
        const conn = try client.Conn.connectProbed(allocator, sock_path);
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn deinit(self: *Fs) void {
        for (self.deltas.items) |*d| d.deinit();
        self.deltas.deinit(self.allocator);
        for (self.job_events.items) |*e| e.deinit();
        self.job_events.deinit(self.allocator);
        self.conn.deinit();
    }

    pub fn lastErr(self: *const Fs) []const u8 {
        return self.last_err[0..self.last_err_len];
    }

    /// The destination identity reported by the last Error.Conflict.
    pub fn lastConflict(self: *const Fs) ?InstallResult {
        return self.conflict;
    }

    /// Exposes the transport for integration into an external poll loop.
    pub fn pollFd(self: *const Fs) c_int {
        return self.conn.fd;
    }

    fn setErr(self: *Fs, msg: []const u8) void {
        const n = @min(msg.len, self.last_err.len);
        @memcpy(self.last_err[0..n], msg[0..n]);
        self.last_err_len = n;
    }

    fn nextReq(self: *Fs) u32 {
        const r = self.next_req;
        self.next_req +%= 1;
        if (self.next_req == 0) self.next_req = 1;
        return r;
    }

    fn stashDelta(self: *Fs, payload: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const a = arena.allocator();
        const Wire = struct {
            view: u32 = 0,
            gone: bool = false,
            resync: bool = false,
            changes: []Delta.Change = &.{},
        };
        // alloc_always: the frame payload dies with the caller's scope —
        // parsed strings must never alias it.
        const parsed = std.json.parseFromSliceLeaky(Wire, a, payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            arena.deinit();
            return;
        };
        self.deltas.append(self.allocator, .{
            .arena = arena,
            .view = parsed.view,
            .gone = parsed.gone,
            .resync = parsed.resync,
            .changes = parsed.changes,
        }) catch arena.deinit();
    }

    fn stashJobEvent(self: *Fs, payload: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const Wire = struct {
            job: u64 = 0,
            ev: []const u8 = "",
            state: []const u8 = "",
            done: u64 = 0,
            total: u64 = 0,
            resumed_from: u64 = 0,
            hash: []const u8 = "",
            message: []const u8 = "",
            path: []const u8 = "",
            line: u64 = 0,
            text: []const u8 = "",
            kind: []const u8 = "",
            size: u64 = 0,
            mtime_ms: i64 = 0,
            matches: u64 = 0,
            truncated: bool = false,
            watches: u64 = 0,
            watch_limit: bool = false,
            rejected: u64 = 0,
            exit_status: i64 = 0,
            file: []const u8 = "",
            files_done: u64 = 0,
            files_total: u64 = 0,
            meta: []const MediaField = &.{},
            cached: bool = false,
            keep: bool = false,
            xy: []const u8 = "",
            orig: []const u8 = "",
            repo: bool = false,
            tracked: bool = false,
            branch: []const u8 = "",
            upstream: []const u8 = "",
            ahead: i64 = 0,
            behind: i64 = 0,
            have_ab: bool = false,
            detached: bool = false,
            initial: bool = false,
            root: bool = false,
        };
        const parsed = std.json.parseFromSliceLeaky(Wire, arena.allocator(), payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            arena.deinit();
            return;
        };
        self.job_events.append(self.allocator, .{
            .arena = arena,
            .job = parsed.job,
            .ev = parsed.ev,
            .state = parsed.state,
            .done = parsed.done,
            .total = parsed.total,
            .resumed_from = parsed.resumed_from,
            .hash = parsed.hash,
            .message = parsed.message,
            .path = parsed.path,
            .line = parsed.line,
            .text = parsed.text,
            .kind = parsed.kind,
            .size = parsed.size,
            .mtime_ms = parsed.mtime_ms,
            .matches = parsed.matches,
            .truncated = parsed.truncated,
            .watches = parsed.watches,
            .watch_limit = parsed.watch_limit,
            .rejected = parsed.rejected,
            .exit_status = parsed.exit_status,
            .file = parsed.file,
            .files_done = parsed.files_done,
            .files_total = parsed.files_total,
            .meta = parsed.meta,
            .cached = parsed.cached,
            .keep = parsed.keep,
            .xy = parsed.xy,
            .orig = parsed.orig,
            .repo = parsed.repo,
            .tracked = parsed.tracked,
            .branch = parsed.branch,
            .upstream = parsed.upstream,
            .ahead = parsed.ahead,
            .behind = parsed.behind,
            .have_ab = parsed.have_ab,
            .detached = parsed.detached,
            .initial = parsed.initial,
            .root = parsed.root,
        }) catch arena.deinit();
    }

    /// Route any pushed frame to its stash. Every receive loop calls
    /// this for non-reply frames so pushes are never dropped.
    fn stashPush(self: *Fs, ftype: wire.FrameType, payload: []const u8) void {
        switch (ftype) {
            .fs_delta => self.stashDelta(payload),
            .fs_job => self.stashJobEvent(payload),
            else => {},
        }
    }

    /// Pop the oldest pending delta (caller deinits), draining any
    /// bytes already on the socket first — never blocks.
    pub fn takeDelta(self: *Fs) ?Delta {
        _ = self.conn.fillAvailable();
        while (self.conn.takeFrame() catch null) |f| {
            defer f.deinit(self.allocator);
            self.stashPush(f.ftype, f.payload);
        }
        if (self.deltas.items.len == 0) return null;
        return self.deltas.orderedRemove(0);
    }

    /// Pop the oldest pending job event (caller deinits); non-blocking.
    pub fn takeJobEvent(self: *Fs) ?JobEvent {
        _ = self.conn.fillAvailable();
        while (self.conn.takeFrame() catch null) |f| {
            defer f.deinit(self.allocator);
            self.stashPush(f.ftype, f.payload);
        }
        if (self.job_events.items.len == 0) return null;
        return self.job_events.orderedRemove(0);
    }

    /// Wait for one job's terminal event while preserving events for other jobs.
    pub fn waitJobTerminal(self: *Fs, job: u64, timeout_ms: i64) Error!JobEvent {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            var i: usize = 0;
            while (i < self.job_events.items.len) {
                const event = &self.job_events.items[i];
                if (event.job != job or !event.terminal()) {
                    i += 1;
                    continue;
                }
                return self.job_events.orderedRemove(i);
            }
            const remain = deadline - nowMs();
            if (remain <= 0) return Error.Timeout;
            const frame = self.conn.recvFrameFor(remain) catch |err| switch (err) {
                error.Timeout => return Error.Timeout,
                else => return Error.NotConnected,
            };
            defer frame.deinit(self.allocator);
            self.stashPush(frame.ftype, frame.payload);
        }
    }

    /// Block (bounded) until at least one delta is pending or the
    /// timeout passes. Returns the number of pending deltas.
    pub fn waitDelta(self: *Fs, timeout_ms: i64) usize {
        const deadline = nowMs() + timeout_ms;
        while (self.deltas.items.len == 0) {
            const remain = deadline - nowMs();
            if (remain <= 0) break;
            const f = self.conn.recvFrameFor(remain) catch break;
            defer f.deinit(self.allocator);
            self.stashPush(f.ftype, f.payload);
        }
        return self.deltas.items.len;
    }

    /// Await the fs_reply matching `req`, stashing deltas and dropping
    /// stale replies meanwhile. On success the parsed Reply is arena-
    /// allocated into `arena`.
    fn awaitReply(self: *Fs, arena: std.mem.Allocator, req: u32, timeout_ms: i64) Error!Reply {
        const rep = try self.awaitReplyRaw(arena, req, timeout_ms);
        if (!rep.ok) {
            self.setErr(rep.@"error");
            return Error.FsOpFailed;
        }
        return rep;
    }

    /// awaitReply without the ok check: for verbs whose FAILURE reply
    /// carries payload the caller needs (install's conflict entry).
    fn awaitReplyRaw(self: *Fs, arena: std.mem.Allocator, req: u32, timeout_ms: i64) Error!Reply {
        const cap_deadline = nowMs() + @max(timeout_ms, OP_CAP_MS);
        while (true) {
            const cap_remain = cap_deadline - nowMs();
            if (cap_remain <= 0) return Error.Timeout;
            const f = self.conn.recvFrameProgressive(timeout_ms, cap_remain) catch |err| switch (err) {
                error.Timeout => return Error.Timeout,
                else => return Error.NotConnected,
            };
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .fs_delta, .fs_job => self.stashPush(f.ftype, f.payload),
                .fs_reply => {
                    // alloc_always: f.payload is freed on return; the
                    // reply must own its strings (use-after-free bug
                    // class — flaky SEGV in the smoke, once).
                    const rep = std.json.parseFromSliceLeaky(Reply, arena, f.payload, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    }) catch return Error.BadReply;
                    if (rep.req != req) continue; // stale (abandoned request)
                    return rep;
                },
                .err => {
                    self.setErr(f.payload);
                    return Error.FsOpFailed;
                },
                else => {},
            }
        }
    }

    fn sendOp(self: *Fs, op: []const u8, req: u32, args: anytype) Error!void {
        const Base = struct {
            req: u32,
            op: []const u8,
            path: []const u8 = "",
            to: []const u8 = "",
            view: u32 = 0,
            off: u64 = 0,
            len: u32 = 0,
            @"resume": bool = false,
            no_replace: bool = false,
            conflict: []const u8 = "",
            dir_mode: []const u8 = "",
            job: u64 = 0,
            pattern: []const u8 = "",
            /// find/live_find: only entries modified inside this
            /// window (0 = all), and a raised match cap.
            within_ms: u64 = 0,
            max_matches: u64 = 0,
            mode: u32 = 0,
            uid: ?u32 = null,
            gid: ?u32 = null,
            size: u64 = 0,
            atime_ms: ?i64 = null,
            mtime_ms: ?i64 = null,
            src_host: []const u8 = "",
            dst_host: []const u8 = "",
            client_token: []const u8 = "",
            /// cross_copy move + dial cap (see CrossOpts).
            delete_src: bool = false,
            dial_tries: u32 = 0,
            attrs: []const u8 = "",
            image_codecs: []const u8 = "",
            /// install: the destination mtime the caller last saw.
            expected_mtime_ns: ?i64 = null,
        };
        var b: Base = .{ .req = req, .op = op };
        inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |fld| {
            @field(b, fld.name) = @field(args, fld.name);
        }
        self.conn.sendJson(.fs_op, b) catch return Error.NotConnected;
    }

    /// Collect a chunked listing reply run into one Listing.
    fn collectListing(self: *Fs, req: u32) Error!Listing {
        var out: Listing = .{ .arena = std.heap.ArenaAllocator.init(self.allocator) };
        errdefer out.deinit();
        const a = out.arena.allocator();
        var entries: std.ArrayList(Entry) = .empty;

        while (true) {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const rep = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
            if (out.path.len == 0 and rep.path.len > 0)
                out.path = a.dupe(u8, rep.path) catch return Error.OutOfMemory;
            if (rep.dev != 0) out.dev = rep.dev;
            if (rep.truncated) out.truncated = true;
            for (rep.entries) |e| {
                entries.append(a, dupeEntry(a, e) catch return Error.OutOfMemory) catch
                    return Error.OutOfMemory;
            }
            if (!rep.more) break;
        }
        out.entries = entries.items;
        return out;
    }

    fn dupeMediaResult(a: std.mem.Allocator, ev: *const JobEvent) !MediaResult {
        const fields = try a.alloc(MediaField, ev.meta.len);
        for (ev.meta, 0..) |f, i|
            fields[i] = .{ .k = try a.dupe(u8, f.k), .v = try a.dupe(u8, f.v) };
        return .{
            .path = try a.dupe(u8, ev.path),
            .kind = try a.dupe(u8, ev.kind),
            .cached = ev.cached,
            .note = try a.dupe(u8, ev.text),
            .fields = fields,
        };
    }

    fn dupeEntry(a: std.mem.Allocator, e: Entry) !Entry {
        var d = e;
        d.name = try a.dupe(u8, e.name);
        d.kind = try a.dupe(u8, e.kind);
        if (e.target) |t| d.target = try a.dupe(u8, t);
        d.tags = try a.dupe(u8, e.tags);
        if (e.attrs.len > 0) {
            const values = try a.alloc([]const u8, e.attrs.len);
            for (e.attrs, 0..) |v, i| values[i] = try a.dupe(u8, v);
            d.attrs = values;
        }
        return d;
    }

    /// Open a live directory view: full listing now, fs_delta pushes
    /// until closeView. `view_id` is caller-chosen and client-scoped.
    pub fn openView(self: *Fs, view_id: u32, path: []const u8) Error!Listing {
        const req = self.nextReq();
        try self.sendOp("open_view", req, .{ .path = path, .view = view_id });
        return self.collectListing(req);
    }

    /// One-shot listing whose entries also carry the values of
    /// `attrs` (comma-separated user.* names), in request order.
    pub fn listAttrs(self: *Fs, path: []const u8, attrs: []const u8) Error!Listing {
        const req = self.nextReq();
        try self.sendOp("list", req, .{ .path = path, .attrs = attrs });
        return self.collectListing(req);
    }

    /// Set (or remove, with an empty value) one extended attribute.
    pub fn attrSet(self: *Fs, path: []const u8, name: []const u8, value: []const u8) Error!void {
        try self.simpleOp("attr_set", .{ .path = path, .pattern = name, .to = value });
    }

    /// One-shot listing, no subscription.
    pub fn list(self: *Fs, path: []const u8) Error!Listing {
        const req = self.nextReq();
        try self.sendOp("list", req, .{ .path = path });
        return self.collectListing(req);
    }

    pub fn closeView(self: *Fs, view_id: u32) Error!void {
        const req = self.nextReq();
        try self.sendOp("close_view", req, .{ .view = view_id });
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        _ = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
    }

    /// Stat one path. Returned entry strings live in `arena` (caller-
    /// provided so the result can outlive the call).
    pub fn statPath(self: *Fs, arena: std.mem.Allocator, path: []const u8) Error!Entry {
        const req = self.nextReq();
        try self.sendOp("stat", req, .{ .path = path });
        const rep = try self.awaitReply(arena, req, OP_TIMEOUT_MS);
        return rep.entry orelse Error.BadReply;
    }

    /// statPath, following symlinks to the file a read/write would
    /// actually land on. The daemon's `stat` is an LSTAT, so a
    /// symlinked document otherwise reports the LINK's identity —
    /// which never moves when the target is rewritten, and is exactly
    /// what an external-modification check must not compare against.
    /// Bounded hop count: symlink loops exist.
    pub fn statFollow(self: *Fs, arena: std.mem.Allocator, path: []const u8) Error!Entry {
        var cur_buf: [4096]u8 = undefined;
        if (path.len == 0 or path.len >= cur_buf.len) return Error.BadRequest;
        @memcpy(cur_buf[0..path.len], path);
        var cur_len = path.len;

        var hops: usize = 0;
        while (hops < 8) : (hops += 1) {
            const e = try self.statPath(arena, cur_buf[0..cur_len]);
            if (!std.mem.eql(u8, e.kind, "link")) return e;
            const target = e.target orelse return Error.FsOpFailed;
            if (target.len == 0) return Error.FsOpFailed;
            var next_buf: [4096]u8 = undefined;
            const next: []const u8 = if (target[0] == '/')
                target
            else blk: {
                const dir = std.fs.path.dirname(cur_buf[0..cur_len]) orelse "/";
                break :blk std.fmt.bufPrint(&next_buf, "{s}/{s}", .{ dir, target }) catch
                    return Error.BadRequest;
            };
            if (next.len >= cur_buf.len) return Error.BadRequest;
            // `next` may alias arena memory or next_buf: copy through a
            // scratch buffer before overwriting cur_buf.
            var tmp: [4096]u8 = undefined;
            @memcpy(tmp[0..next.len], next);
            @memcpy(cur_buf[0..next.len], tmp[0..next.len]);
            cur_len = next.len;
        }
        return Error.FsOpFailed;
    }

    pub fn mkdir(self: *Fs, path: []const u8) Error!void {
        try self.simpleOp("mkdir", .{ .path = path });
    }

    pub fn rename(self: *Fs, from: []const u8, to: []const u8) Error!void {
        try self.simpleOp("rename", .{ .path = from, .to = to });
    }

    pub fn renameNoReplace(self: *Fs, from: []const u8, to: []const u8) Error!void {
        if (!self.conn.copy_no_replace) return Error.BadRequest;
        try self.simpleOp("rename", .{ .path = from, .to = to, .no_replace = true });
    }

    /// Delete ONE entry (file/link/empty dir) — recursive delete is a
    /// phase-2 job.
    pub fn deletePath(self: *Fs, path: []const u8) Error!void {
        try self.simpleOp("delete", .{ .path = path });
    }

    pub fn unlink(self: *Fs, path: []const u8) Error!void {
        try self.simpleOp("unlink", .{ .path = path });
    }

    pub fn rmdir(self: *Fs, path: []const u8) Error!void {
        try self.simpleOp("rmdir", .{ .path = path });
    }

    /// Create a symlink at `path` pointing to `target`.
    pub fn symlink(self: *Fs, target: []const u8, path: []const u8) Error!void {
        try self.simpleOp("symlink", .{ .path = path, .to = target });
    }

    /// Create a hard link at `path` for the existing file `target`.
    /// Fails with a described error across filesystems or on a
    /// directory — both are impossible, not merely unusual.
    pub fn hardlink(self: *Fs, target: []const u8, path: []const u8) Error!void {
        try self.simpleOp("hardlink", .{ .path = path, .to = target });
    }

    /// This host's home / cache / template directories, arena-owned.
    pub fn hostDirs(self: *Fs, arena: std.mem.Allocator) Error!HostDirs {
        const req = self.nextReq();
        try self.sendOp("homedir", req, .{ .path = "/" });
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const rep = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
        return .{
            .home = arena.dupe(u8, rep.home) catch return Error.OutOfMemory,
            .cache = arena.dupe(u8, rep.cache) catch return Error.OutOfMemory,
            .templates = arena.dupe(u8, rep.templates) catch return Error.OutOfMemory,
        };
    }

    pub fn chmod(self: *Fs, path: []const u8, mode: u32) Error!void {
        try self.simpleOp("chmod", .{ .path = path, .mode = mode });
    }

    pub fn chown(self: *Fs, path: []const u8, uid: ?u32, gid: ?u32) Error!void {
        try self.simpleOp("chown", .{ .path = path, .uid = uid, .gid = gid });
    }

    pub fn truncate(self: *Fs, path: []const u8, size: u64) Error!void {
        try self.simpleOp("truncate", .{ .path = path, .size = size });
    }

    pub fn utimens(self: *Fs, path: []const u8, atime_ms: ?i64, mtime_ms: ?i64) Error!void {
        try self.simpleOp("utimens", .{ .path = path, .atime_ms = atime_ms, .mtime_ms = mtime_ms });
    }

    pub fn access(self: *Fs, path: []const u8, mode: u32) Error!void {
        try self.simpleOp("access", .{ .path = path, .mode = mode });
    }

    pub fn fsync(self: *Fs, path: []const u8) Error!void {
        try self.simpleOp("fsync", .{ .path = path });
    }

    pub fn statFs(self: *Fs, path: []const u8) Error!StatFs {
        const req = self.nextReq();
        try self.sendOp("statfs", req, .{ .path = path });
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const rep = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
        return .{
            .bsize = rep.bsize,
            .frsize = rep.frsize,
            .blocks = rep.blocks,
            .bfree = rep.bfree,
            .bavail = rep.bavail,
            .files = rep.files,
            .ffree = rep.ffree,
            .namemax = rep.namemax,
        };
    }

    fn simpleOp(self: *Fs, op: []const u8, args: anytype) Error!void {
        const req = self.nextReq();
        try self.sendOp(op, req, args);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        _ = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
    }

    /// Ranged read appended to `out`. One call fetches at most
    /// fsserve.MAX_READ bytes; loop while !eof for more.
    pub fn read(self: *Fs, path: []const u8, off: u64, len: u32, out: *std.ArrayList(u8)) Error!ReadInfo {
        const req = self.nextReq();
        try self.sendOp("read", req, .{ .path = path, .off = off, .len = len });
        const cap_deadline = nowMs() + OP_CAP_MS;
        while (true) {
            const cap_remain = cap_deadline - nowMs();
            if (cap_remain <= 0) return Error.Timeout;
            const f = self.conn.recvFrameProgressive(OP_TIMEOUT_MS, cap_remain) catch |err| switch (err) {
                error.Timeout => return Error.Timeout,
                else => return Error.NotConnected,
            };
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .fs_delta, .fs_job => self.stashPush(f.ftype, f.payload),
                .fs_data => {
                    if (f.payload.len < 12) continue;
                    if (std.mem.readInt(u32, f.payload[0..4], .little) != req) continue;
                    out.appendSlice(self.allocator, f.payload[12..]) catch
                        return Error.OutOfMemory;
                },
                .fs_reply => {
                    var scratch = std.heap.ArenaAllocator.init(self.allocator);
                    defer scratch.deinit();
                    const rep = std.json.parseFromSliceLeaky(Reply, scratch.allocator(), f.payload, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    }) catch return Error.BadReply;
                    if (rep.req != req) continue;
                    if (!rep.ok) {
                        self.setErr(rep.@"error");
                        return Error.FsOpFailed;
                    }
                    return .{
                        .size = rep.size,
                        .eof = rep.eof,
                        .mtime_ns = rep.mtime_ns,
                        .ino = rep.ino,
                    };
                },
                .err => {
                    self.setErr(f.payload);
                    return Error.FsOpFailed;
                },
                else => {},
            }
        }
    }

    /// Write `data` at `off` (or append). Returns bytes written.
    pub fn write(self: *Fs, path: []const u8, off: u64, data: []const u8, flags: WriteFlags) Error!u64 {
        if (path.len > std.math.maxInt(u16)) return Error.BadReply;
        const req = self.nextReq();
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var hdr: [15]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], req, .little);
        std.mem.writeInt(u64, hdr[4..12], off, .little);
        hdr[12] = flags.byte();
        std.mem.writeInt(u16, hdr[13..15], @intCast(path.len), .little);
        payload.appendSlice(self.allocator, &hdr) catch return Error.OutOfMemory;
        payload.appendSlice(self.allocator, path) catch return Error.OutOfMemory;
        payload.appendSlice(self.allocator, data) catch return Error.OutOfMemory;
        self.conn.sendFrame(.fs_write, payload.items) catch return Error.NotConnected;

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        // The ack cannot beat the payload up a slow link: budget the
        // wait for the upload itself, not just the round trip.
        const upload_ms: i64 = @intCast(@min(@as(u64, @intCast(OP_CAP_MS - OP_TIMEOUT_MS)), data.len / (WRITE_MIN_RATE / 1000)));
        const rep = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS + upload_ms);
        return rep.written;
    }

    // ── atomic save ─────────────────────────────────────────────

    /// Install the staged file `path_tmp` over `dest`: the daemon
    /// inherits the destination's mode/owner, fsyncs, renames, and
    /// fsyncs the destination's parent.
    ///
    /// @return the destination's post-install identity — the caller's
    /// next `expected_mtime_ns` without a second round trip.
    /// @throws Conflict when the destination's mtime_ns no longer
    /// matches `expected_mtime_ns` (see lastConflict); the temp is
    /// left in place for the caller to clean up.
    pub fn install(self: *Fs, path_tmp: []const u8, dest: []const u8, expected_mtime_ns: ?i64) Error!InstallResult {
        const req = self.nextReq();
        try self.sendOp("install", req, .{
            .path = path_tmp,
            .to = dest,
            .expected_mtime_ns = expected_mtime_ns,
        });
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const rep = try self.awaitReplyRaw(scratch.allocator(), req, OP_TIMEOUT_MS);
        if (!rep.ok) {
            self.setErr(rep.@"error");
            if (std.mem.eql(u8, rep.@"error", "conflict")) {
                self.conflict = if (rep.entry) |e| InstallResult.of(e) else .{};
                return Error.Conflict;
            }
            return Error.FsOpFailed;
        }
        const e = rep.entry orelse return Error.BadReply;
        self.conflict = null;
        return InstallResult.of(e);
    }

    /// Write `bytes` to `dest` atomically: stage into a hidden
    /// sibling temp, chunk it up, then install. `dest` is never
    /// observed half-written, and a failed save never truncates it.
    ///
    /// The temp is a SIBLING so the install is a same-filesystem
    /// rename; it is removed on every failure path, including a
    /// refused (conflicting) install.
    pub fn writeFileAtomic(self: *Fs, dest: []const u8, bytes: []const u8, expected_mtime_ns: ?i64) Error!InstallResult {
        if (dest.len == 0 or dest[0] != '/') return Error.BadRequest;
        const base = std.fs.path.basename(dest);
        if (base.len == 0) return Error.BadRequest;
        const dir = std.fs.path.dirname(dest) orelse "/";

        var tmp_buf: [4096]u8 = undefined;
        self.save_seq +%= 1;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/.{s}.sketerm-save.{x}{x}", .{
            if (std.mem.eql(u8, dir, "/")) "" else dir,
            base,
            @as(u32, @bitCast(c.getpid())),
            self.save_seq,
        }) catch return Error.BadRequest;

        // Every failure below owns the temp: a save that dies halfway
        // must not leave staged litter next to the user's file.
        errdefer self.unlink(tmp) catch {};

        var off: usize = 0;
        var first = true;
        while (first or off < bytes.len) {
            first = false;
            const end = @min(bytes.len, off + SAVE_CHUNK);
            const n = try self.write(tmp, off, bytes[off..end], .{
                .create = off == 0,
                .exclusive = off == 0,
            });
            if (n == 0 and end > off) return Error.BadReply;
            off += @intCast(n);
        }

        return self.install(tmp, dest, expected_mtime_ns);
    }

    // ── jobs (subprocess verbs) ─────────────────────────────────

    fn startJob(self: *Fs, op: []const u8, args: anytype) Error!u64 {
        const req = self.nextReq();
        try self.sendOp(op, req, args);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const rep = try self.awaitReply(scratch.allocator(), req, OP_TIMEOUT_MS);
        if (rep.job == 0) return Error.BadReply;
        return rep.job;
    }

    /// Start a copy job (file or tree). `resumable` allows continuing
    /// a previous interrupted copy's hash-verified partial.
    pub fn startCopy(self: *Fs, src: []const u8, dst: []const u8, resumable: bool) Error!u64 {
        return self.startJob("copy", .{ .path = src, .to = dst, .@"resume" = resumable });
    }

    pub fn startCopyToken(self: *Fs, src: []const u8, dst: []const u8, resumable: bool, client_token: []const u8) Error!u64 {
        return self.startJob("copy", .{ .path = src, .to = dst, .@"resume" = resumable, .client_token = client_token });
    }

    pub fn startCopyTokenMode(self: *Fs, src: []const u8, dst: []const u8, resumable: bool, client_token: []const u8, mode: CopyMode) Error!u64 {
        if (mode.no_replace and !self.conn.copy_no_replace) return Error.BadRequest;
        return self.startJob("copy", .{
            .path = src,
            .to = dst,
            .@"resume" = resumable,
            .client_token = client_token,
            .conflict = mode.conflict,
            .dir_mode = mode.dir_mode,
            .no_replace = mode.no_replace,
        });
    }

    /// How a copy resolves names that already exist at the
    /// destination. `dir_mode` applies to the top-level directory
    /// only; `conflict` governs every entry inside the tree.
    pub const CopyMode = struct {
        conflict: []const u8 = "",
        dir_mode: []const u8 = "",
        no_replace: bool = false,
    };

    pub fn startCopyMode(self: *Fs, src: []const u8, dst: []const u8, mode: CopyMode) Error!u64 {
        if (mode.no_replace and !self.conn.copy_no_replace) return Error.BadRequest;
        return self.startJob("copy", .{ .path = src, .to = dst, .conflict = mode.conflict, .dir_mode = mode.dir_mode, .no_replace = mode.no_replace });
    }

    pub fn startDeleteTree(self: *Fs, path: []const u8) Error!u64 {
        return self.startJob("delete_tree", .{ .path = path });
    }

    pub fn startHash(self: *Fs, path: []const u8) Error!u64 {
        return self.startJob("hash", .{ .path = path });
    }

    /// `git status` overlay for `root`; one "match" event per record
    /// (`text` = the collapsed single-letter status, `xy` = the two
    /// porcelain-v2 columns, `orig` = a rename source), then one
    /// "repo" event with the branch header. A non-repo (or a host
    /// without git) completes with zero matches, not an error.
    pub fn startGitStatus(self: *Fs, root: []const u8) Error!u64 {
        return self.startJob("git_status", .{ .path = root });
    }

    /// Unified diff of two host-side files; one "line" event per line.
    pub fn startDiff(self: *Fs, a: []const u8, b: []const u8) Error!u64 {
        return self.startJob("diff", .{ .path = a, .to = b });
    }

    /// Per-line change marks for ONE file against HEAD, computed on
    /// the file's own host. One "line" event per RUN of consecutive
    /// same-kind lines (`line` = 0-based start, `size` = count,
    /// `kind` = added/modified/deleted), then a "repo" event carrying
    /// repo / tracked / initial. `gitDiff` below is the collected
    /// form; this is for a caller that wants the stream.
    ///
    /// Refused against a daemon that predates the verb — the caller
    /// must say it does not know rather than draw a clean gutter.
    pub fn startGitDiff(self: *Fs, path: []const u8) Error!u64 {
        if (!self.conn.git_diff) return Error.BadRequest;
        return self.startJob("git_diff", .{ .path = path });
    }

    /// Everything a gutter needs about one file. `repo == false` means
    /// UNKNOWN (no repository, or no git on that host) — not "clean".
    pub const GitDiffResult = struct {
        /// The file lives inside a git repository.
        repo: bool = false,
        /// git tracks the file. An untracked file inside a repo has
        /// no diff at all; every one of its lines is new.
        tracked: bool = false,
        /// The repository has no HEAD commit yet, so nothing is
        /// committed to compare against.
        initial: bool = false,
        /// The diff (or the run list) hit a cap; what came back is a
        /// prefix, not the whole answer.
        truncated: bool = false,
        /// Caller-allocated; free with the same allocator.
        runs: []gitdiff.Run = &.{},
    };

    /// Run one `git_diff` to completion (bounded) and collect it.
    /// Runs are allocated from `alloc`; nothing else is owned.
    pub fn gitDiff(self: *Fs, alloc: std.mem.Allocator, path: []const u8, timeout_ms: i64) Error!GitDiffResult {
        const job = try self.startGitDiff(path);
        var out = GitDiffResult{};
        var runs: std.ArrayList(gitdiff.Run) = .empty;
        errdefer runs.deinit(alloc);
        const deadline = nowMs() + timeout_ms;
        while (true) {
            var i: usize = 0;
            var terminal: ?[]const u8 = null;
            while (i < self.job_events.items.len) {
                const e = &self.job_events.items[i];
                if (e.job != job) {
                    i += 1;
                    continue;
                }
                var ev = self.job_events.orderedRemove(i);
                defer ev.deinit();
                if (std.mem.eql(u8, ev.ev, "line")) {
                    const kind = gitdiff.kindFromName(ev.kind) orelse continue;
                    if (ev.size == 0) continue;
                    runs.append(alloc, .{
                        .line = std.math.cast(u32, ev.line) orelse continue,
                        .count = std.math.cast(u32, ev.size) orelse continue,
                        .kind = kind,
                    }) catch return Error.OutOfMemory;
                    continue;
                }
                if (std.mem.eql(u8, ev.ev, "repo")) {
                    out.repo = ev.repo;
                    out.tracked = ev.tracked;
                    out.initial = ev.initial;
                    if (ev.truncated) out.truncated = true;
                    continue;
                }
                if (ev.terminal()) {
                    terminal = if (std.mem.eql(u8, ev.ev, "done")) "done" else "";
                    break;
                }
            }
            if (terminal) |t| {
                if (t.len == 0) {
                    runs.deinit(alloc);
                    return Error.FsOpFailed;
                }
                out.runs = runs.toOwnedSlice(alloc) catch return Error.OutOfMemory;
                return out;
            }
            const remain = deadline - nowMs();
            if (remain <= 0) {
                runs.deinit(alloc);
                return Error.Timeout;
            }
            const f = self.conn.recvFrameFor(remain) catch |err| switch (err) {
                error.Timeout => {
                    runs.deinit(alloc);
                    return Error.Timeout;
                },
                else => {
                    runs.deinit(alloc);
                    return Error.NotConnected;
                },
            };
            defer f.deinit(self.allocator);
            self.stashPush(f.ftype, f.payload);
        }
    }

    /// Split `path` into `<path>.001`, `.002`, … of `part_size` each
    /// ("10M"/"512k"/plain bytes). Existing parts refuse the job.
    pub fn startSplit(self: *Fs, path: []const u8, part_size: []const u8) Error!u64 {
        return self.startJob("split", .{ .path = path, .pattern = part_size });
    }

    /// Rebuild the base file from a `.NNN` part series (any part path).
    pub fn startCombine(self: *Fs, part_path: []const u8) Error!u64 {
        return self.startJob("combine", .{ .path = part_path });
    }

    /// Best-effort shred: one random overwrite pass, then unlink.
    pub fn startSecureDelete(self: *Fs, path: []const u8) Error!u64 {
        return self.startJob("secure_delete", .{ .path = path });
    }

    /// Recursive name search under `root` (ci substring, or glob when
    /// the pattern has wildcards). Matches arrive as job events with
    /// ev == "match".
    pub fn startFind(self: *Fs, root: []const u8, pattern: []const u8) Error!u64 {
        return self.startJob("find", .{ .path = root, .pattern = pattern });
    }

    /// Extra predicates a name query can carry. `within_ms` stays LIVE
    /// in a live_find: the helper drops a row when its mtime ages past
    /// the window, without the caller re-running anything.
    pub const FindOpts = struct {
        within_ms: u64 = 0,
        /// 0 = the daemon default cap.
        max_matches: u64 = 0,
    };

    pub fn startLiveFind(self: *Fs, root: []const u8, pattern: []const u8) Error!u64 {
        return self.startLiveFindOpts(root, pattern, .{});
    }

    pub fn startLiveFindOpts(self: *Fs, root: []const u8, pattern: []const u8, opts: FindOpts) Error!u64 {
        return self.startJob("live_find", .{
            .path = root,
            .pattern = pattern,
            .within_ms = opts.within_ms,
            .max_matches = opts.max_matches,
        });
    }

    /// Recursive ci content search; matches carry path + line + text.
    pub fn startGrep(self: *Fs, root: []const u8, pattern: []const u8) Error!u64 {
        return self.startJob("grep", .{ .path = root, .pattern = pattern });
    }

    /// Start a batched media-metadata extraction: `names` are resolved
    /// against `dir` (absolute names are taken as-is). Results arrive
    /// as job events with ev == "match", one per name, so a caller can
    /// render rows as they land; the terminal event ends the batch.
    pub fn startMediaMeta(self: *Fs, dir: []const u8, names: []const []const u8) Error!u64 {
        if (names.len == 0 or names.len > MEDIA_BATCH_MAX) return Error.BadRequest;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(self.allocator);
        for (names, 0..) |name, i| {
            if (i > 0) joined.append(self.allocator, MEDIA_SEP) catch return Error.OutOfMemory;
            joined.appendSlice(self.allocator, name) catch return Error.OutOfMemory;
        }
        return self.startJob("media_meta", .{ .path = dir, .pattern = joined.items });
    }

    /// Run one media_meta batch to completion (bounded) and collect the
    /// results into `arena`. The streaming form above is what a live
    /// view wants; this is the one-call form for tools and tests.
    pub fn mediaMeta(
        self: *Fs,
        arena: std.mem.Allocator,
        dir: []const u8,
        names: []const []const u8,
        timeout_ms: i64,
    ) Error![]MediaResult {
        const job = try self.startMediaMeta(dir, names);
        var out: std.ArrayList(MediaResult) = .empty;
        const deadline = nowMs() + timeout_ms;
        while (true) {
            var i: usize = 0;
            var terminal = false;
            while (i < self.job_events.items.len) {
                if (self.job_events.items[i].job != job) {
                    i += 1;
                    continue;
                }
                var ev = self.job_events.orderedRemove(i);
                defer ev.deinit();
                if (std.mem.eql(u8, ev.ev, "match")) {
                    out.append(arena, dupeMediaResult(arena, &ev) catch return Error.OutOfMemory) catch
                        return Error.OutOfMemory;
                } else if (ev.terminal()) {
                    if (!std.mem.eql(u8, ev.ev, "done")) {
                        self.setErr(ev.message);
                        return Error.FsOpFailed;
                    }
                    terminal = true;
                }
            }
            if (terminal) return out.items;
            const remain = deadline - nowMs();
            if (remain <= 0) return Error.Timeout;
            const f = self.conn.recvFrameFor(remain) catch |err| switch (err) {
                error.Timeout => return Error.Timeout,
                else => return Error.NotConnected,
            };
            defer f.deinit(self.allocator);
            self.stashPush(f.ftype, f.payload);
        }
    }

    pub fn startThumbnail(self: *Fs, path: []const u8) Error!u64 {
        return self.startJob("thumbnail", .{ .path = path });
    }

    pub fn startPreview(self: *Fs, path: []const u8) Error!u64 {
        return self.startJob("preview", .{ .path = path });
    }

    /// Image preview with an explicit transport-codec advertisement
    /// ("png" | "jxl,webp" | ...); the done event's path is the
    /// bounded sidecar the receiver reads and then unlinks.
    pub fn startPreviewCodecs(self: *Fs, path: []const u8, image_codecs: []const u8) Error!u64 {
        return self.startJob("preview", .{ .path = path, .image_codecs = image_codecs });
    }

    /// Recursive size; the done event carries bytes in `done` and the
    /// entry count in `total`.
    pub fn startDirSize(self: *Fs, path: []const u8) Error!u64 {
        return self.startJob("dir_size", .{ .path = path });
    }

    /// Recursive chmod/chown. mode 0 keeps modes; null uid/gid keep
    /// the current owner/group.
    pub fn startPermTree(self: *Fs, path: []const u8, mode: u32, uid: ?u32, gid: ?u32) Error!u64 {
        return self.startJob("perm_tree", .{ .path = path, .mode = mode, .uid = uid, .gid = gid });
    }

    pub fn startPanelize(self: *Fs, root: []const u8, command: []const u8) Error!u64 {
        return self.startJob("panelize", .{ .path = root, .pattern = command });
    }

    pub fn startExtract(self: *Fs, archive: []const u8, destination: []const u8) Error!u64 {
        return self.startJob("extract", .{ .path = archive, .to = destination });
    }

    pub fn startArchiveCreate(self: *Fs, source: []const u8, archive: []const u8) Error!u64 {
        return self.startJob("archive_create", .{ .path = source, .to = archive });
    }

    pub fn startTrash(self: *Fs, path: []const u8) Error!u64 {
        return self.startJob("trash", .{ .path = path });
    }

    pub fn startTrashRestore(self: *Fs, trashed: []const u8, original: []const u8, info_path: []const u8) Error!u64 {
        return self.startJob("trash_restore", .{ .path = trashed, .to = original, .pattern = info_path });
    }

    pub fn startCrossCopy(
        self: *Fs,
        src_host: []const u8,
        src: []const u8,
        dst_host: []const u8,
        dst: []const u8,
        resumable: bool,
    ) Error!u64 {
        return self.startCrossCopyOpts(src_host, src, dst_host, dst, resumable, .{});
    }

    pub const CrossOpts = struct {
        /// Delete the verified source afterwards — a move.
        delete_src: bool = false,
        no_replace: bool = false,
        /// Cap the initial dial attempts per side (0 = full budget).
        dial_tries: u32 = 0,
    };

    pub fn startCrossCopyOpts(
        self: *Fs,
        src_host: []const u8,
        src: []const u8,
        dst_host: []const u8,
        dst: []const u8,
        resumable: bool,
        opts: CrossOpts,
    ) Error!u64 {
        if (opts.no_replace and !self.conn.copy_no_replace) return Error.BadRequest;
        return self.startJob("cross_copy", .{
            .path = src,
            .to = dst,
            .src_host = src_host,
            .dst_host = dst_host,
            .@"resume" = resumable,
            .delete_src = opts.delete_src,
            .no_replace = opts.no_replace,
            .dial_tries = opts.dial_tries,
        });
    }

    /// Idempotent durable copy. Reusing `client_token` returns and
    /// claims the original job instead of starting a duplicate.
    pub fn startCrossCopyToken(
        self: *Fs,
        src_host: []const u8,
        src: []const u8,
        dst_host: []const u8,
        dst: []const u8,
        resumable: bool,
        client_token: []const u8,
    ) Error!u64 {
        return self.startJob("cross_copy", .{
            .path = src,
            .to = dst,
            .src_host = src_host,
            .dst_host = dst_host,
            .@"resume" = resumable,
            .client_token = client_token,
        });
    }

    pub fn startCrossCopyTokenOpts(
        self: *Fs,
        src_host: []const u8,
        src: []const u8,
        dst_host: []const u8,
        dst: []const u8,
        resumable: bool,
        client_token: []const u8,
        opts: CrossOpts,
    ) Error!u64 {
        if (opts.no_replace and !self.conn.copy_no_replace) return Error.BadRequest;
        return self.startJob("cross_copy", .{
            .path = src,
            .to = dst,
            .src_host = src_host,
            .dst_host = dst_host,
            .@"resume" = resumable,
            .client_token = client_token,
            .delete_src = opts.delete_src,
            .no_replace = opts.no_replace,
            .dial_tries = opts.dial_tries,
        });
    }

    pub fn jobCancel(self: *Fs, job: u64) Error!void {
        try self.simpleOp("job_cancel", .{ .job = job });
    }

    pub fn jobPause(self: *Fs, job: u64) Error!void {
        try self.simpleOp("job_pause", .{ .job = job });
    }

    pub fn jobResume(self: *Fs, job: u64) Error!void {
        try self.simpleOp("job_resume", .{ .job = job });
    }

    /// All jobs the daemon knows (running + retained finished), into
    /// caller's arena.
    pub fn jobList(self: *Fs, arena: std.mem.Allocator) Error![]JobRow {
        const req = self.nextReq();
        try self.sendOp("job_list", req, .{});
        const rep = try self.awaitReply(arena, req, OP_TIMEOUT_MS);
        return rep.jobs;
    }

    /// Wait (bounded) for the job's terminal event, consuming its
    /// progress events along the way. Progress events for OTHER jobs
    /// stay stashed.
    pub fn waitJobEnd(self: *Fs, job: u64, timeout_ms: i64) Error!JobEnd {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            // Scan the stash for this job; keep other jobs' events.
            var i: usize = 0;
            while (i < self.job_events.items.len) {
                const e = &self.job_events.items[i];
                if (e.job != job) {
                    i += 1;
                    continue;
                }
                var ev = self.job_events.orderedRemove(i);
                defer ev.deinit();
                if (!ev.terminal()) continue; // progress: consumed
                var end = JobEnd{
                    .ok = std.mem.eql(u8, ev.ev, "done"),
                    .canceled = std.mem.eql(u8, ev.ev, "canceled"),
                    .bytes_done = ev.done,
                    .total = ev.total,
                    .resumed_from = ev.resumed_from,
                };
                if (ev.hash.len == 64) {
                    @memcpy(&end.hash, ev.hash[0..64]);
                    end.has_hash = true;
                }
                const n = @min(ev.message.len, end.message.len);
                @memcpy(end.message[0..n], ev.message[0..n]);
                end.message_len = n;
                return end;
            }
            const remain = deadline - nowMs();
            if (remain <= 0) return Error.Timeout;
            const f = self.conn.recvFrameFor(remain) catch |err| switch (err) {
                error.Timeout => return Error.Timeout,
                else => return Error.NotConnected,
            };
            defer f.deinit(self.allocator);
            self.stashPush(f.ftype, f.payload);
        }
    }
};
