//! Response-body capture: the per-view filter, and the bounded store the
//! helper records matching exchanges into (the 0x8B block, capability
//! "capture").
//!
//! Pure: std and util only, no CEF, in both test roots. CEF's IO thread
//! writes into a `Store` from resource callbacks while the helper's main
//! thread reads it for the client, so every method takes the store's own
//! spinlock for a short section that never allocates; memory is taken
//! before the section and given back after it (`util/spinlock.zig`
//! forbids an allocation under a spinlock). Entries and body chunks are
//! freed ONLY on the main thread (clear, install, the last release), which
//! is what lets the main thread read an entry's immutable parts outside
//! the lock while it holds a reference.
//!
//! Two sequence numbers, on purpose. `seq` is the view's network-log
//! seq for the same request, so a captured exchange joins its
//! `web_network` row. `cursor` is the LIST position, assigned when the
//! exchange finishes: responses finish out of request order, and paging
//! by seq would skip a slow response whose seq sits below one already
//! listed.

const std = @import("std");
const SpinLock = @import("../util/spinlock.zig").SpinLock;
const pattern = @import("../util/pattern.zig");
const filter = @import("filter.zig");
const netpolicy = @import("netpolicy.zig");
const proto = @import("protocol.zig");

pub const DEFAULT_MAX_BODY: u32 = 16 * 1024 * 1024;
pub const DEFAULT_MAX_TOTAL: u64 = 128 * 1024 * 1024;
/// Ceilings a client may ask for; a larger value is refused, not clamped.
pub const MAX_BODY_LIMIT: u32 = 256 * 1024 * 1024;
pub const MAX_TOTAL_LIMIT: u64 = 1024 * 1024 * 1024;
/// Exchanges one view can hold at once, finished or not.
pub const MAX_ENTRIES = 4096;
/// Matching requests that may await their response at once.
pub const MAX_PENDING = 256;
pub const MAX_METHODS = 16;
pub const MAX_MIMES = 16;
pub const MAX_HOSTS = netpolicy.MAX_HOSTS;
/// fetch() and XMLHttpRequest: the engine reports both as one class.
pub const DEFAULT_TYPES: u16 = filter.RType.xhr.bit();
/// A pending request older than this is presumed abandoned by the
/// engine and may be evicted when the table is full.
const PENDING_STALE_MS: i64 = 10 * 60 * 1000;

// ---------------------------------------------------------------------
// Filter
// ---------------------------------------------------------------------

/// A compiled capture filter. Immutable once built, so the IO thread
/// matches against it without the lock.
pub const Filter = struct {
    arena_state: std.heap.ArenaAllocator,
    /// `filter.RType` bits; 0 = every class.
    types: u16,
    /// `filter.hostWithin` bases; empty = every host.
    hosts: []const []const u8,
    /// Upper-case; empty = every method.
    methods: []const []const u8,
    /// Lower-case prefixes of the response mime type; empty = every type.
    mimes: []const []const u8,
    url_contains: []const u8,
    regex: ?pattern.Matcher,
    max_body: u32,
    max_total: u64,

    pub const BuildError = error{ OutOfMemory, BadPattern };

    /// Deep-copy a decoded `capture_set`. The regex is case-SENSITIVE:
    /// a url's path and query are.
    pub fn build(gpa: std.mem.Allocator, req: proto.CaptureSet) BuildError!Filter {
        var f = Filter{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .types = req.types,
            .hosts = &.{},
            .methods = &.{},
            .mimes = &.{},
            .url_contains = "",
            .regex = null,
            .max_body = req.max_body,
            .max_total = req.max_total,
        };
        errdefer f.arena_state.deinit();
        const a = f.arena_state.allocator();
        f.hosts = try dupeFolded(a, req.hosts[0..@min(req.hosts.len, MAX_HOSTS)], .lower);
        f.methods = try dupeFolded(a, req.methods[0..@min(req.methods.len, MAX_METHODS)], .upper);
        f.mimes = try dupeFolded(a, req.mime_prefixes[0..@min(req.mime_prefixes.len, MAX_MIMES)], .lower);
        f.url_contains = try a.dupe(u8, req.url_contains);
        if (req.url_regex.len > 0) f.regex = try pattern.compile(a, req.url_regex, false);
        return f;
    }

    pub fn deinit(self: *Filter) void {
        self.arena_state.deinit();
    }

    /// The request-side test: everything knowable before a response.
    /// `host` is the lower-cased host of `url`.
    pub fn matchRequest(self: *const Filter, url: []const u8, host: []const u8, rtype: filter.RType, method: []const u8) bool {
        if (self.types != 0 and self.types & rtype.bit() == 0) return false;
        if (self.methods.len > 0) {
            var ok = false;
            for (self.methods) |m| {
                if (std.ascii.eqlIgnoreCase(m, method)) ok = true;
            }
            if (!ok) return false;
        }
        if (self.hosts.len > 0) {
            var ok = false;
            for (self.hosts) |h| {
                if (filter.hostWithin(host, h)) ok = true;
            }
            if (!ok) return false;
        }
        if (self.url_contains.len > 0 and std.mem.indexOf(u8, url, self.url_contains) == null) return false;
        if (self.regex) |re| {
            if (!re.matches(url)) return false;
        }
        return true;
    }

    /// The response-side test, ASCII case-insensitive.
    pub fn matchMime(self: *const Filter, mime: []const u8) bool {
        if (self.mimes.len == 0) return true;
        for (self.mimes) |p| {
            if (mime.len >= p.len and std.ascii.eqlIgnoreCase(mime[0..p.len], p)) return true;
        }
        return false;
    }
};

fn dupeFolded(a: std.mem.Allocator, src: []const []const u8, comptime case: enum { lower, upper }) ![]const []const u8 {
    const out = try a.alloc([]const u8, src.len);
    for (out, src) |*d, s| d.* = switch (case) {
        .lower => try std.ascii.allocLowerString(a, s),
        .upper => try std.ascii.allocUpperString(a, s),
    };
    return out;
}

// ---------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------

/// One stored run of body bytes. Immutable once linked; freed only on
/// the main thread.
const Chunk = struct {
    next: ?*Chunk = null,
    len: usize,

    fn bytes(self: *Chunk) []u8 {
        const base: [*]u8 = @ptrCast(self);
        return (base + @sizeOf(Chunk))[0..self.len];
    }

    fn alloc(gpa: std.mem.Allocator, data: []const u8) ?*Chunk {
        const raw = gpa.alignedAlloc(u8, .of(Chunk), @sizeOf(Chunk) + data.len) catch return null;
        const ch: *Chunk = @ptrCast(raw.ptr);
        ch.* = .{ .len = data.len };
        @memcpy(ch.bytes(), data);
        return ch;
    }

    fn free(self: *Chunk, gpa: std.mem.Allocator) void {
        const base: [*]align(@alignOf(Chunk)) u8 = @ptrCast(self);
        gpa.free(base[0 .. @sizeOf(Chunk) + self.len]);
    }
};

/// What the response callback knows about an exchange when it begins.
pub const Meta = struct {
    url: []const u8,
    method: []const u8,
    mime: []const u8,
    charset: []const u8,
    status: u16,
    /// `[{"name":..,"value":..}]`.
    headers: []const u8,
    headers_truncated: bool = false,
    /// The request's byte parts, concatenated (possibly already cut).
    req_body: []const u8 = "",
    /// The byte parts' full length; 0 = `req_body.len`.
    req_total: u64 = 0,
    req_nonbytes: bool = false,
};

pub const Entry = struct {
    /// Store-unique, never reused: what a response filter addresses its
    /// entry by, since `seq` is only unique per view and wraps.
    uid: u64,
    seq: u32,
    req_id: u64,
    /// 0 until the exchange finishes: the engine reported the load
    /// complete AND the body stream ended (`streamDone`). Both, because
    /// they are separate callbacks and neither ordering is promised, so
    /// "complete" can never be reported for a body still growing.
    cursor: u32 = 0,
    load_done: bool = false,
    stream_done: bool = false,
    rtype: u8,
    status: u16,
    err: i32 = 0,
    complete: bool = false,
    failed: bool = false,
    started_wall_ms: i64,
    started_ms: i64,
    dur_ms: u32 = 0,
    trunc: proto.CaptureTrunc = .none,
    req_trunc: proto.CaptureTrunc = .none,
    req_nonbytes: bool,
    headers_truncated: bool,
    body_len: u64 = 0,
    body_seen: u64 = 0,
    head: ?*Chunk = null,
    tail: ?*Chunk = null,
    req_total: u32,
    /// Owns the strings below and the stored request body.
    blob: []u8,
    url: []const u8,
    method: []const u8,
    mime: []const u8,
    charset: []const u8,
    headers: []const u8,
    req_body: []const u8,

    fn finished(self: *const Entry) bool {
        return self.cursor != 0;
    }

    fn stored(self: *const Entry) u64 {
        return self.body_len + self.req_body.len;
    }

    fn free(self: *Entry, gpa: std.mem.Allocator) void {
        var c = self.head;
        while (c) |ch| {
            c = ch.next;
            ch.free(gpa);
        }
        gpa.free(self.blob);
        gpa.destroy(self);
    }
};

const Pending = struct {
    used: bool = false,
    req_id: u64 = 0,
    seq: u32 = 0,
    rtype: u8 = 0,
    at_ms: i64 = 0,
};

/// A snapshot of one finished entry, for the main thread's reply. The
/// strings borrow from the entry, which the caller keeps alive by
/// holding its store reference and not clearing.
pub const Listed = proto.CaptureEntry;

pub const ListOut = struct {
    entries: []Listed,
    more: bool,
    next_cursor: u32,
    head_cursor: u32,
    in_flight: u32,
    stored: u64,
    dropped: [proto.NCAPTURE_DROPS]u32,
    state: proto.CaptureState,
};

pub const BodyOut = struct {
    found: bool = false,
    complete: bool = false,
    trunc: proto.CaptureTrunc = .none,
    total: u64 = 0,
    seen: u64 = 0,
    status: u16 = 0,
    mime: []const u8 = "",
    charset: []const u8 = "",
    headers: []const u8 = "",
    /// Filled into the caller's buffer.
    len: usize = 0,
};

/// One view's capture: its filter and the exchanges recorded under it.
/// Reference-counted, because a response filter still streaming a body
/// can outlive the slot's own reference (a reinstall, the view going).
pub const Store = struct {
    gpa: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    lock: SpinLock = .{},
    serial: u32,
    filter: Filter,
    state: proto.CaptureState = .active,
    pending: [MAX_PENDING]Pending = @splat(.{}),
    entries: *[MAX_ENTRIES]?*Entry,
    next_uid: u64 = 1,
    next_cursor: u32 = 1,
    stored: u64 = 0,
    in_flight: u32 = 0,
    dropped: [proto.NCAPTURE_DROPS]u32 = @splat(0),

    /// `gpa` must be thread-safe: the IO thread allocates from it.
    pub fn create(gpa: std.mem.Allocator, req: proto.CaptureSet) Filter.BuildError!*Store {
        var f = try Filter.build(gpa, req);
        errdefer f.deinit();
        const entries = try gpa.create([MAX_ENTRIES]?*Entry);
        errdefer gpa.destroy(entries);
        entries.* = @splat(null);
        const s = try gpa.create(Store);
        s.* = .{ .gpa = gpa, .serial = req.serial, .filter = f, .entries = entries };
        return s;
    }

    pub fn retain(self: *Store) *Store {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    /// Frees everything once the last reference goes. Whichever thread
    /// drops it last frees it, which is safe: nobody else can reach it.
    pub fn release(self: *Store) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.entries) |slot| {
            if (slot) |e| e.free(self.gpa);
        }
        self.gpa.destroy(self.entries);
        self.filter.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    // -- IO thread: the request side ----------------------------------

    /// A request left the page. Remember it when it matches, so its
    /// response can be recognised; a redirect hop (same `req_id`)
    /// re-registers under the hop's seq, or forgets a hop that no longer
    /// matches.
    pub fn admitRequest(self: *Store, req_id: u64, seq: u32, url: []const u8, host: []const u8, rtype: filter.RType, method: []const u8, now_ms: i64) void {
        const matched = self.filter.matchRequest(url, host, rtype, method);
        self.lock.lock();
        defer self.lock.unlock();
        if (self.state != .active) return;
        var free_slot: ?*Pending = null;
        var stale_slot: ?*Pending = null;
        for (&self.pending) |*p| {
            if (p.used and p.req_id == req_id) {
                if (matched) {
                    p.seq = seq;
                    p.rtype = @intFromEnum(rtype);
                } else p.* = .{};
                return;
            }
            if (!p.used and free_slot == null) free_slot = p;
            if (p.used and now_ms - p.at_ms > PENDING_STALE_MS and stale_slot == null) stale_slot = p;
        }
        if (!matched) return;
        const slot = free_slot orelse stale_slot orelse {
            self.dropped[@intFromEnum(proto.CaptureDrop.pending_full)] +|= 1;
            return;
        };
        slot.* = .{ .used = true, .req_id = req_id, .seq = seq, .rtype = @intFromEnum(rtype), .at_ms = now_ms };
    }

    /// The response to a remembered request began and its mime type is
    /// known: record the exchange when it passes the mime test. Returns
    /// the entry's uid, which the body stream appends under, or null
    /// when nothing is recorded (not remembered, mime mismatch, a cap).
    /// `meta` is copied; its request body is kept up to the caps.
    pub fn beginResponse(self: *Store, req_id: u64, meta: Meta, wall_ms: i64, now_ms: i64) ?u64 {
        var pend: Pending = .{};
        {
            self.lock.lock();
            defer self.lock.unlock();
            for (&self.pending) |*p| {
                if (!p.used or p.req_id != req_id) continue;
                pend = p.*;
                p.* = .{};
                break;
            }
            if (!pend.used or self.state != .active) return null;
        }
        if (!self.filter.matchMime(meta.mime)) return null;

        // Everything allocated before the lock; the caps are applied
        // inside it and the unused tail of the blob is simply idle.
        const req_keep = @min(meta.req_body.len, self.filter.max_body);
        const blob_len = meta.url.len + meta.method.len + meta.mime.len + meta.charset.len + meta.headers.len + req_keep;
        const blob = self.gpa.alloc(u8, blob_len) catch return self.dropNoMem();
        const e = self.gpa.create(Entry) catch {
            self.gpa.free(blob);
            return self.dropNoMem();
        };
        var off: usize = 0;
        const put = struct {
            fn f(dst: []u8, o: *usize, s: []const u8) []const u8 {
                @memcpy(dst[o.*..][0..s.len], s);
                defer o.* += s.len;
                return dst[o.*..][0..s.len];
            }
        }.f;
        e.* = .{
            .uid = 0,
            .seq = pend.seq,
            .req_id = req_id,
            .rtype = pend.rtype,
            .status = meta.status,
            .started_wall_ms = wall_ms,
            .started_ms = now_ms,
            .req_nonbytes = meta.req_nonbytes,
            .headers_truncated = meta.headers_truncated,
            .req_total = @intCast(@min(@max(meta.req_total, meta.req_body.len), std.math.maxInt(u32))),
            .blob = blob,
            .url = put(blob, &off, meta.url),
            .method = put(blob, &off, meta.method),
            .mime = put(blob, &off, meta.mime),
            .charset = put(blob, &off, meta.charset),
            .headers = put(blob, &off, meta.headers),
            .req_body = "",
        };
        const req_region = blob[off..][0..req_keep];
        // Copied before the lock: it can be megabytes.
        @memcpy(req_region, meta.req_body[0..req_keep]);

        self.lock.lock();
        var why: ?proto.CaptureDrop = null;
        var slot: ?*?*Entry = null;
        if (self.state != .active) {
            why = null;
        } else if (self.stored >= self.filter.max_total) {
            why = .total_full;
        } else {
            for (self.entries) |*sl| {
                if (sl.* == null) {
                    slot = sl;
                    break;
                }
            }
            if (slot == null) why = .entries_full;
        }
        if (slot) |sl| {
            const room = self.filter.max_total - self.stored;
            const keep: usize = @intCast(@min(req_keep, room));
            e.req_body = req_region[0..keep];
            if (keep < e.req_total)
                e.req_trunc = if (keep < req_keep) .total_cap else .body_cap;
            self.stored += keep;
            e.uid = self.next_uid;
            self.next_uid += 1;
            sl.* = e;
            self.in_flight += 1;
            self.lock.unlock();
            return e.uid;
        }
        if (why) |w| self.dropped[@intFromEnum(w)] +|= 1;
        self.lock.unlock();
        self.gpa.free(blob);
        self.gpa.destroy(e);
        return null;
    }

    /// Drop a remembered request whose response will not be recorded.
    pub fn forget(self: *Store, req_id: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.pending) |*p| {
            if (p.used and p.req_id == req_id) p.* = .{};
        }
    }

    fn dropNoMem(self: *Store) ?u64 {
        self.lock.lock();
        defer self.lock.unlock();
        self.dropped[@intFromEnum(proto.CaptureDrop.no_memory)] +|= 1;
        return null;
    }

    fn findUid(self: *Store, uid: u64, hint: *usize) ?*Entry {
        if (hint.* < MAX_ENTRIES) {
            if (self.entries[hint.*]) |e| {
                if (e.uid == uid) return e;
            }
        }
        for (self.entries, 0..) |slot, i| {
            const e = slot orelse continue;
            if (e.uid != uid) continue;
            hint.* = i;
            return e;
        }
        return null;
    }

    /// Body bytes the engine delivered for entry `uid`. Kept up to the
    /// per-body and total caps; anything past them is counted and the
    /// entry marked truncated, never silently cut. `hint` is the
    /// caller's lookup cache (start it at `MAX_ENTRIES`).
    pub fn appendBody(self: *Store, uid: u64, hint: *usize, data: []const u8) void {
        if (data.len == 0) return;
        var keep: usize = 0;
        {
            self.lock.lock();
            defer self.lock.unlock();
            const e = self.findUid(uid, hint) orelse return;
            e.body_seen += data.len;
            const body_room = self.filter.max_body -| e.body_len;
            const total_room = self.filter.max_total -| self.stored;
            keep = @intCast(@min(data.len, @min(body_room, total_room)));
            if (keep < data.len and e.trunc == .none)
                e.trunc = if (body_room <= total_room) .body_cap else .total_cap;
            // Reserved now, so a concurrent append cannot overrun the cap.
            self.stored += keep;
            e.body_len += keep;
        }
        if (keep == 0) return;
        const ch = Chunk.alloc(self.gpa, data[0..keep]);
        self.lock.lock();
        const e = self.findUid(uid, hint);
        if (ch == null or e == null) {
            // Give the reservation back: the bytes never landed.
            self.stored -|= keep;
            if (e) |ent| {
                ent.body_len -|= keep;
                if (ch == null) ent.trunc = .no_memory;
            }
            self.lock.unlock();
            if (ch) |c| c.free(self.gpa);
            return;
        }
        const ent = e.?;
        if (ent.tail) |t| t.next = ch else ent.head = ch;
        ent.tail = ch;
        self.lock.unlock();
    }

    /// The engine finished request `req_id`, successfully or not.
    pub fn finish(self: *Store, req_id: u64, ok: bool, err: i32, status: u16, now_ms: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.pending) |*p| {
            if (p.used and p.req_id == req_id) p.* = .{};
        }
        for (self.entries) |slot| {
            const e = slot orelse continue;
            if (e.req_id != req_id or e.load_done) continue;
            e.load_done = true;
            e.complete = ok;
            e.failed = !ok;
            e.err = err;
            if (status != 0) e.status = status;
            self.settle(e, now_ms);
            return;
        }
    }

    /// The body stream of entry `uid` ended (its response filter was
    /// released): no more bytes will arrive for it.
    pub fn streamDone(self: *Store, uid: u64, hint: *usize, now_ms: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
        const e = self.findUid(uid, hint) orelse return;
        e.stream_done = true;
        self.settle(e, now_ms);
    }

    /// Under the lock: list the entry once both halves are in.
    fn settle(self: *Store, e: *Entry, now_ms: i64) void {
        if (!e.load_done or !e.stream_done or e.finished()) return;
        e.dur_ms = @intCast(std.math.clamp(now_ms - e.started_ms, 0, std.math.maxInt(u32)));
        e.cursor = self.next_cursor;
        self.next_cursor +%= 1;
        if (self.next_cursor == 0) self.next_cursor = 1;
        self.in_flight -|= 1;
    }

    // -- main thread ---------------------------------------------------

    /// Finished exchanges with a cursor above `since`, oldest first, at
    /// most `max`; with `in_flight`, the unfinished ones after them
    /// (cursor 0, oldest request first, at most `max` more). `scratch`
    /// must hold `MAX_ENTRIES` items; the returned entries live in it,
    /// their strings in the entries themselves.
    ///
    /// MEASURED (CEF 151): a body the page never reads keeps its load
    /// open. The response filter has seen every byte and been released,
    /// but `on_resource_load_complete` does not fire until the renderer
    /// drains the body, so such an exchange stays in flight until the
    /// page reads it or navigates away. Listing it in flight is the
    /// truth; calling it complete would claim what the engine did not.
    pub fn list(self: *Store, scratch: []Listed, since: u32, max: usize) ListOut {
        return self.listWith(scratch, since, max, false);
    }

    pub fn listWith(self: *Store, scratch: []Listed, since: u32, max: usize, in_flight: bool) ListOut {
        std.debug.assert(scratch.len >= MAX_ENTRIES);
        var n: usize = 0;
        var out: ListOut = undefined;
        {
            self.lock.lock();
            defer self.lock.unlock();
            for (self.entries) |slot| {
                const e = slot orelse continue;
                if (!e.finished() or e.cursor <= since) continue;
                scratch[n] = listed(e);
                n += 1;
            }
            if (in_flight) {
                for (self.entries) |slot| {
                    const e = slot orelse continue;
                    if (e.finished()) continue;
                    scratch[n] = listed(e);
                    n += 1;
                }
            }
            out = .{
                .entries = &.{},
                .more = false,
                .next_cursor = since,
                .head_cursor = if (self.next_cursor == 1) 0 else self.next_cursor -% 1,
                .in_flight = self.in_flight,
                .stored = self.stored,
                .dropped = self.dropped,
                .state = self.state,
            };
        }
        // Finished first by cursor, then the unfinished (cursor 0) by
        // request seq.
        const all = scratch[0..n];
        std.mem.sort(Listed, all, {}, struct {
            fn lt(_: void, a: Listed, b: Listed) bool {
                if ((a.cursor == 0) != (b.cursor == 0)) return a.cursor != 0;
                if (a.cursor == 0) return a.seq < b.seq;
                return a.cursor < b.cursor;
            }
        }.lt);
        var done: usize = 0;
        while (done < n and all[done].cursor != 0) done += 1;
        const take = @min(done, max);
        out.more = take < done;
        if (take > 0) out.next_cursor = all[take - 1].cursor;
        const pending = @min(n - done, max);
        // Compact: the finished page, then the unfinished ones.
        std.mem.copyForwards(Listed, all[take..][0..pending], all[done..][0..pending]);
        out.entries = all[0 .. take + pending];
        return out;
    }

    fn listed(e: *const Entry) Listed {
        var flags: u8 = 0;
        if (e.complete) flags |= proto.CaptureEntry.flag_complete;
        if (e.failed) flags |= proto.CaptureEntry.flag_failed;
        if (e.req_nonbytes) flags |= proto.CaptureEntry.flag_req_nonbytes;
        if (e.headers_truncated) flags |= proto.CaptureEntry.flag_headers_truncated;
        return .{
            .seq = e.seq,
            .cursor = e.cursor,
            .rtype = e.rtype,
            .flags = flags,
            .status = e.status,
            .err = e.err,
            .trunc = @intFromEnum(e.trunc),
            .req_trunc = @intFromEnum(e.req_trunc),
            .body_len = e.body_len,
            .body_seen = e.body_seen,
            .req_len = @intCast(e.req_body.len),
            .req_total = e.req_total,
            .started_ms = @intCast(@max(e.started_wall_ms, 0)),
            .dur_ms = e.dur_ms,
            .method = e.method,
            .mime = e.mime,
            .charset = e.charset,
            .url = .{ .s = e.url },
        };
    }

    /// Copy up to `out.len` bytes of one body, from `offset`. Several
    /// exchanges can share a seq only across a seq wrap; the newest
    /// wins.
    pub fn readBody(self: *Store, seq: u32, part: proto.CapturePart, offset: u64, out: []u8) BodyOut {
        var r = BodyOut{};
        var head: ?*Chunk = null;
        var len: u64 = 0;
        var e_found: ?*Entry = null;
        {
            self.lock.lock();
            defer self.lock.unlock();
            for (self.entries) |slot| {
                const e = slot orelse continue;
                if (e.seq != seq) continue;
                if (e_found) |prev| {
                    if (prev.uid > e.uid) continue;
                }
                e_found = e;
            }
            const e = e_found orelse return r;
            r.found = true;
            r.complete = e.finished();
            r.status = e.status;
            r.mime = e.mime;
            r.charset = e.charset;
            switch (part) {
                .request => {
                    r.trunc = e.req_trunc;
                    r.seen = e.req_total;
                    len = e.req_body.len;
                },
                else => {
                    r.trunc = e.trunc;
                    r.seen = e.body_seen;
                    r.headers = e.headers;
                    head = e.head;
                    len = e.body_len;
                },
            }
        }
        // Outside the lock: linked chunks and the blob never change and
        // are freed only on this thread.
        r.total = len;
        if (offset >= len) return r;
        const want: usize = @intCast(@min(out.len, len - offset));
        if (part == .request) {
            const e = e_found.?;
            @memcpy(out[0..want], e.req_body[@intCast(offset)..][0..want]);
            r.len = want;
            return r;
        }
        var skip = offset;
        var got: usize = 0;
        var c = head;
        while (c) |ch| : (c = ch.next) {
            if (got == want) break;
            const b = ch.bytes();
            if (skip >= b.len) {
                skip -= b.len;
                continue;
            }
            const from: usize = @intCast(skip);
            skip = 0;
            const n = @min(b.len - from, want - got);
            @memcpy(out[got..][0..n], b[from..][0..n]);
            got += n;
        }
        r.len = got;
        return r;
    }

    /// Free finished exchanges with a cursor at or below `upto`, or
    /// every exchange (in-flight ones too) when `upto` is 0. A body
    /// still streaming into a cleared exchange is passed through to the
    /// page and not kept.
    pub fn clear(self: *Store, upto: u32) usize {
        var victims: [MAX_ENTRIES]*Entry = undefined;
        var n: usize = 0;
        {
            self.lock.lock();
            defer self.lock.unlock();
            for (self.entries) |*slot| {
                const e = slot.* orelse continue;
                if (upto != 0 and (!e.finished() or e.cursor > upto)) continue;
                if (!e.finished()) self.in_flight -|= 1;
                self.stored -|= e.stored();
                victims[n] = e;
                n += 1;
                slot.* = null;
            }
            if (upto == 0) {
                for (&self.pending) |*p| p.* = .{};
            }
        }
        for (victims[0..n]) |e| e.free(self.gpa);
        return n;
    }

    /// Stop recording new exchanges. What is held stays readable and a
    /// body already streaming still completes.
    pub fn disable(self: *Store) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.state = .disabled;
        for (&self.pending) |*p| p.* = .{};
    }
};

// ---------------------------------------------------------------------
// Presenting a body
// ---------------------------------------------------------------------

/// How a captured body is handed to a reader: as UTF-8 text (possibly
/// transcoded from a single-byte charset) or as binary.
pub const Encoding = enum { utf8, latin1, windows1252, binary };

/// Whether a mime type names text.
pub fn isTextMime(mime_raw: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, mime_raw, ';') orelse mime_raw.len;
    const mime = std.mem.trim(u8, mime_raw[0..end], " \t");
    if (mime.len == 0) return false;
    if (std.ascii.startsWithIgnoreCase(mime, "text/")) return true;
    const exact = [_][]const u8{
        "application/json",               "application/javascript",
        "application/ecmascript",         "application/xml",
        "application/x-www-form-urlencoded", "application/graphql",
        "application/x-ndjson",           "image/svg+xml",
    };
    for (exact) |m| {
        if (std.ascii.eqlIgnoreCase(mime, m)) return true;
    }
    return std.ascii.endsWithIgnoreCase(mime, "+json") or std.ascii.endsWithIgnoreCase(mime, "+xml");
}

/// The encoding a body is presented in. Text-typed bodies (and untyped
/// ones) that are valid UTF-8 are text; a declared single-byte charset
/// is transcoded; anything else is binary.
pub fn classify(mime: []const u8, charset: []const u8, body: []const u8) Encoding {
    const text = mime.len == 0 or isTextMime(mime);
    if (!text) return .binary;
    const cs = std.mem.trim(u8, charset, " \t\"");
    if (std.ascii.eqlIgnoreCase(cs, "iso-8859-1") or std.ascii.eqlIgnoreCase(cs, "latin1") or
        std.ascii.eqlIgnoreCase(cs, "iso8859-1"))
        return .latin1;
    if (std.ascii.eqlIgnoreCase(cs, "windows-1252") or std.ascii.eqlIgnoreCase(cs, "cp1252"))
        return .windows1252;
    if (std.unicode.utf8ValidateSlice(body)) return .utf8;
    // A declared UTF-8 body that does not validate is not text.
    return .binary;
}

/// windows-1252's 0x80-0x9F (the rest is ISO-8859-1); 0 = undefined.
const CP1252_HIGH = [32]u21{
    0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
    0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
};

/// A single-byte body as UTF-8. Caller frees. An undefined windows-1252
/// byte becomes U+FFFD.
pub fn toUtf8(gpa: std.mem.Allocator, enc: Encoding, body: []const u8) ![]u8 {
    std.debug.assert(enc == .latin1 or enc == .windows1252);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, body.len);
    for (body) |b| {
        var cp: u21 = b;
        if (enc == .windows1252 and b >= 0x80 and b <= 0x9F) {
            cp = CP1252_HIGH[b - 0x80];
            if (cp == 0) cp = 0xFFFD;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// The charset parameter of a Content-Type value, "" when absent.
pub fn charsetOf(content_type: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, content_type, ';');
    _ = it.next();
    while (it.next()) |param| {
        const p = std.mem.trim(u8, param, " \t");
        if (p.len > 8 and std.ascii.eqlIgnoreCase(p[0..8], "charset=")) return std.mem.trim(u8, p[8..], "\"");
    }
    return "";
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn testSet(extra: struct {
    types: u16 = DEFAULT_TYPES,
    hosts: []const []const u8 = &.{},
    methods: []const []const u8 = &.{},
    mimes: []const []const u8 = &.{},
    contains: []const u8 = "",
    regex: []const u8 = "",
    max_body: u32 = DEFAULT_MAX_BODY,
    max_total: u64 = DEFAULT_MAX_TOTAL,
}) proto.CaptureSet {
    return .{
        .view = 1,
        .serial = 1,
        .op = @intFromEnum(proto.CaptureOp.install),
        .upto = 0,
        .types = extra.types,
        .max_body = extra.max_body,
        .max_total = extra.max_total,
        .url_contains = extra.contains,
        .url_regex = extra.regex,
        .hosts = extra.hosts,
        .methods = extra.methods,
        .mime_prefixes = extra.mimes,
    };
}

/// The body stream of `uid` ended (its filter was released).
fn endStream(s: *Store, uid: u64) void {
    var hint: usize = MAX_ENTRIES;
    s.streamDone(uid, &hint, 0);
}

const json_meta = Meta{
    .url = "https://api.example/v1/items",
    .method = "POST",
    .mime = "application/json",
    .charset = "utf-8",
    .status = 200,
    .headers = "[{\"name\":\"content-type\",\"value\":\"application/json\"}]",
    .req_body = "{\"operationName\":\"fetchPlaylist\"}",
};

test "filter: types, methods, hosts, url substring and regex all have to hold" {
    var f = try Filter.build(testing.allocator, testSet(.{
        .hosts = &.{"Example.com"},
        .methods = &.{"post"},
        .contains = "/pathfinder/",
        .regex = "operationName=fetch[A-Z]",
    }));
    defer f.deinit();
    const url = "https://api.example.com/pathfinder/v1/query?operationName=fetchPlaylist";
    try testing.expect(f.matchRequest(url, "api.example.com", .xhr, "POST"));
    // Each clause alone can refuse.
    try testing.expect(!f.matchRequest(url, "api.example.com", .script, "POST"));
    try testing.expect(!f.matchRequest(url, "api.example.com", .xhr, "GET"));
    try testing.expect(!f.matchRequest(url, "notexample.com", .xhr, "POST"));
    try testing.expect(!f.matchRequest("https://api.example.com/other?operationName=fetchPlaylist", "api.example.com", .xhr, "POST"));
    try testing.expect(!f.matchRequest("https://api.example.com/pathfinder/v1/query?operationName=fetchplaylist", "api.example.com", .xhr, "POST"));
}

test "filter: an empty clause is no restriction, a bad regex is refused at build" {
    var f = try Filter.build(testing.allocator, testSet(.{ .types = 0 }));
    defer f.deinit();
    try testing.expect(f.matchRequest("https://x.test/a.png", "x.test", .image, "GET"));
    try testing.expect(f.matchMime("image/png"));
    try testing.expectError(error.BadPattern, Filter.build(testing.allocator, testSet(.{ .regex = "[unclosed" })));
}

test "filter: mime prefixes compare case-insensitively" {
    var f = try Filter.build(testing.allocator, testSet(.{ .mimes = &.{"application/json"} }));
    defer f.deinit();
    try testing.expect(f.matchMime("application/json"));
    try testing.expect(f.matchMime("Application/JSON"));
    try testing.expect(!f.matchMime("text/html"));
    try testing.expect(!f.matchMime("application/js"));
}

test "store: a request, its response and body, then the finish; listed by cursor" {
    const s = try Store.create(testing.allocator, testSet(.{ .mimes = &.{"application/json"} }));
    defer s.release();
    s.admitRequest(10, 41, json_meta.url, "api.example", .xhr, "POST", 0);
    const uid = s.beginResponse(10, json_meta, 1_700_000_000_000, 5).?;
    var hint: usize = MAX_ENTRIES;
    s.appendBody(uid, &hint, "{\"items\":");
    s.appendBody(uid, &hint, "[1,2,3]}");

    var scratch: [MAX_ENTRIES]Listed = undefined;
    // Still streaming: counted as in flight, not listed.
    var l = s.list(&scratch, 0, 50);
    try testing.expectEqual(@as(usize, 0), l.entries.len);
    try testing.expectEqual(@as(u32, 1), l.in_flight);

    // The load finished but the stream has not: still in flight, so a
    // body can never be listed complete while it may still grow.
    s.finish(10, true, 0, 200, 20);
    l = s.list(&scratch, 0, 50);
    try testing.expectEqual(@as(usize, 0), l.entries.len);
    try testing.expectEqual(@as(u32, 1), l.in_flight);
    s.streamDone(uid, &hint, 25);
    l = s.list(&scratch, 0, 50);
    try testing.expectEqual(@as(usize, 1), l.entries.len);
    const e = l.entries[0];
    try testing.expectEqual(@as(u32, 41), e.seq);
    try testing.expectEqual(@as(u32, 1), e.cursor);
    try testing.expectEqual(@as(u32, 20), e.dur_ms);
    try testing.expect(e.flags & proto.CaptureEntry.flag_complete != 0);
    try testing.expectEqual(@as(u64, 17), e.body_len);
    try testing.expectEqual(@as(u32, 0), l.in_flight);
    try testing.expectEqual(@as(u64, 17 + json_meta.req_body.len), l.stored);

    var buf: [64]u8 = undefined;
    const body = s.readBody(41, .response, 0, &buf);
    try testing.expect(body.found and body.complete);
    try testing.expectEqualStrings("{\"items\":[1,2,3]}", buf[0..body.len]);
    try testing.expectEqualStrings(json_meta.headers, body.headers);
    // Paged reads cross chunk boundaries.
    const mid = s.readBody(41, .response, 5, buf[0..6]);
    try testing.expectEqualStrings("ms\":[1", buf[0..mid.len]);
    const req = s.readBody(41, .request, 0, &buf);
    try testing.expectEqualStrings(json_meta.req_body, buf[0..req.len]);
    try testing.expect(!s.readBody(99, .response, 0, &buf).found);
}

test "store: the cursor follows finish order, so a slow early request is not skipped" {
    const s = try Store.create(testing.allocator, testSet(.{}));
    defer s.release();
    s.admitRequest(1, 10, json_meta.url, "api.example", .xhr, "GET", 0);
    s.admitRequest(2, 11, json_meta.url, "api.example", .xhr, "GET", 0);
    const uid_a = s.beginResponse(1, json_meta, 0, 0).?;
    const uid_b = s.beginResponse(2, json_meta, 0, 0).?;
    endStream(s, uid_b);
    s.finish(2, true, 0, 200, 1);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    var l = s.list(&scratch, 0, 50);
    try testing.expectEqual(@as(usize, 1), l.entries.len);
    try testing.expectEqual(@as(u32, 11), l.entries[0].seq);
    const since = l.next_cursor;
    // seq 10 finishes AFTER seq 11 was listed; a seq cursor would lose it.
    s.finish(1, true, 0, 200, 2);
    endStream(s, uid_a);
    l = s.list(&scratch, since, 50);
    try testing.expectEqual(@as(usize, 1), l.entries.len);
    try testing.expectEqual(@as(u32, 10), l.entries[0].seq);
}

test "store: non-matching traffic is never buffered" {
    const s = try Store.create(testing.allocator, testSet(.{ .mimes = &.{"application/json"}, .hosts = &.{"api.example"} }));
    defer s.release();
    // Wrong host: not even remembered.
    s.admitRequest(1, 1, "https://cdn.test/x", "cdn.test", .xhr, "GET", 0);
    try testing.expect(s.beginResponse(1, json_meta, 0, 0) == null);
    // Right request, wrong mime: remembered, then refused at the response.
    s.admitRequest(2, 2, json_meta.url, "api.example", .xhr, "GET", 0);
    var html = json_meta;
    html.mime = "text/html";
    try testing.expect(s.beginResponse(2, html, 0, 0) == null);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    const l = s.list(&scratch, 0, 50);
    try testing.expectEqual(@as(u64, 0), l.stored);
    try testing.expectEqual(@as(u32, 0), l.in_flight);
}

test "store: a redirect hop re-registers under the hop's seq, or forgets a hop that left the filter" {
    const s = try Store.create(testing.allocator, testSet(.{ .hosts = &.{"api.example"} }));
    defer s.release();
    s.admitRequest(7, 1, json_meta.url, "api.example", .xhr, "GET", 0);
    s.admitRequest(7, 2, "https://api.example/v2/items", "api.example", .xhr, "GET", 0);
    endStream(s, s.beginResponse(7, json_meta, 0, 0).?);
    s.finish(7, true, 0, 200, 1);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    try testing.expectEqual(@as(u32, 2), s.list(&scratch, 0, 50).entries[0].seq);

    s.admitRequest(8, 3, json_meta.url, "api.example", .xhr, "GET", 0);
    s.admitRequest(8, 4, "https://elsewhere.test/", "elsewhere.test", .xhr, "GET", 0);
    try testing.expect(s.beginResponse(8, json_meta, 0, 0) == null);
}

test "store: the per-body cap truncates with a reason, and counts what was delivered" {
    const s = try Store.create(testing.allocator, testSet(.{ .max_body = 8 }));
    defer s.release();
    var meta = json_meta;
    meta.req_body = "0123456789AB";
    s.admitRequest(1, 1, json_meta.url, "api.example", .xhr, "POST", 0);
    const uid = s.beginResponse(1, meta, 0, 0).?;
    var hint: usize = MAX_ENTRIES;
    s.appendBody(uid, &hint, "abcdef");
    s.appendBody(uid, &hint, "ghijkl");
    endStream(s, uid);
    s.finish(1, true, 0, 200, 1);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    const e = s.list(&scratch, 0, 50).entries[0];
    try testing.expectEqual(@as(u64, 8), e.body_len);
    try testing.expectEqual(@as(u64, 12), e.body_seen);
    try testing.expectEqual(@as(u8, @intFromEnum(proto.CaptureTrunc.body_cap)), e.trunc);
    try testing.expectEqual(@as(u32, 8), e.req_len);
    try testing.expectEqual(@as(u32, 12), e.req_total);
    try testing.expectEqual(@as(u8, @intFromEnum(proto.CaptureTrunc.body_cap)), e.req_trunc);
    var buf: [16]u8 = undefined;
    const b = s.readBody(1, .response, 0, &buf);
    try testing.expectEqualStrings("abcdefgh", buf[0..b.len]);
    try testing.expectEqual(proto.CaptureTrunc.body_cap, b.trunc);
}

test "store: the total cap truncates, then drops whole exchanges and counts them" {
    const s = try Store.create(testing.allocator, testSet(.{ .max_total = 10 }));
    defer s.release();
    var meta = json_meta;
    meta.req_body = "";
    s.admitRequest(1, 1, json_meta.url, "api.example", .xhr, "GET", 0);
    const uid = s.beginResponse(1, meta, 0, 0).?;
    var hint: usize = MAX_ENTRIES;
    s.appendBody(uid, &hint, "0123456789ABCDEF");
    endStream(s, uid);
    s.finish(1, true, 0, 200, 1);
    s.admitRequest(2, 2, json_meta.url, "api.example", .xhr, "GET", 0);
    try testing.expect(s.beginResponse(2, meta, 0, 0) == null);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    const l = s.list(&scratch, 0, 50);
    try testing.expectEqual(@as(u8, @intFromEnum(proto.CaptureTrunc.total_cap)), l.entries[0].trunc);
    try testing.expectEqual(@as(u32, 1), l.dropped[@intFromEnum(proto.CaptureDrop.total_full)]);
    try testing.expectEqual(@as(u64, 10), l.stored);

    // Clearing what was read makes room again.
    try testing.expectEqual(@as(usize, 1), s.clear(l.next_cursor));
    s.admitRequest(3, 3, json_meta.url, "api.example", .xhr, "GET", 0);
    try testing.expect(s.beginResponse(3, meta, 0, 0) != null);
}

test "store: a full pending table drops and counts, never evicts a live request" {
    const s = try Store.create(testing.allocator, testSet(.{}));
    defer s.release();
    for (0..MAX_PENDING) |i| s.admitRequest(i + 1, @intCast(i + 1), json_meta.url, "api.example", .xhr, "GET", 0);
    s.admitRequest(9999, 9999, json_meta.url, "api.example", .xhr, "GET", 0);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    try testing.expectEqual(@as(u32, 1), s.list(&scratch, 0, 50).dropped[@intFromEnum(proto.CaptureDrop.pending_full)]);
    // A stale one (abandoned by the engine) may be reused.
    s.admitRequest(10000, 10000, json_meta.url, "api.example", .xhr, "GET", PENDING_STALE_MS + 1);
    try testing.expect(s.beginResponse(10000, json_meta, 0, 0) != null);
}

test "store: clear drops in-flight bodies too, and later chunks for them are not kept" {
    const s = try Store.create(testing.allocator, testSet(.{}));
    defer s.release();
    s.admitRequest(1, 1, json_meta.url, "api.example", .xhr, "GET", 0);
    const uid = s.beginResponse(1, json_meta, 0, 0).?;
    var hint: usize = MAX_ENTRIES;
    s.appendBody(uid, &hint, "abc");
    try testing.expectEqual(@as(usize, 1), s.clear(0));
    s.appendBody(uid, &hint, "def");
    s.finish(1, true, 0, 200, 1);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    const l = s.list(&scratch, 0, 50);
    try testing.expectEqual(@as(usize, 0), l.entries.len);
    try testing.expectEqual(@as(u64, 0), l.stored);
    try testing.expectEqual(@as(u32, 0), l.in_flight);
}

test "store: disable stops new exchanges, keeps the held ones and lets a stream finish" {
    const s = try Store.create(testing.allocator, testSet(.{}));
    defer s.release();
    s.admitRequest(1, 1, json_meta.url, "api.example", .xhr, "GET", 0);
    const uid = s.beginResponse(1, json_meta, 0, 0).?;
    s.admitRequest(2, 2, json_meta.url, "api.example", .xhr, "GET", 0);
    s.disable();
    var hint: usize = MAX_ENTRIES;
    s.appendBody(uid, &hint, "x");
    endStream(s, uid);
    s.finish(1, true, 0, 200, 1);
    try testing.expect(s.beginResponse(2, json_meta, 0, 0) == null);
    s.admitRequest(3, 3, json_meta.url, "api.example", .xhr, "GET", 0);
    try testing.expect(s.beginResponse(3, json_meta, 0, 0) == null);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    const l = s.list(&scratch, 0, 50);
    try testing.expectEqual(proto.CaptureState.disabled, l.state);
    try testing.expectEqual(@as(usize, 1), l.entries.len);
    try testing.expectEqual(@as(u64, 1), l.entries[0].body_len);
}

test "store: a failed exchange is listed with its error" {
    const s = try Store.create(testing.allocator, testSet(.{}));
    defer s.release();
    s.admitRequest(1, 1, json_meta.url, "api.example", .xhr, "GET", 0);
    endStream(s, s.beginResponse(1, json_meta, 0, 0).?);
    s.finish(1, false, -3, 0, 1);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    const e = s.list(&scratch, 0, 50).entries[0];
    try testing.expect(e.flags & proto.CaptureEntry.flag_failed != 0);
    try testing.expect(e.flags & proto.CaptureEntry.flag_complete == 0);
    try testing.expectEqual(@as(i32, -3), e.err);
    try testing.expectEqual(@as(u16, 200), e.status);
}

test "store: a reference held elsewhere keeps entries alive past the owner's release" {
    const s = try Store.create(testing.allocator, testSet(.{}));
    const streaming = s.retain();
    s.admitRequest(1, 1, json_meta.url, "api.example", .xhr, "GET", 0);
    const uid = s.beginResponse(1, json_meta, 0, 0).?;
    s.release();
    var hint: usize = MAX_ENTRIES;
    streaming.appendBody(uid, &hint, "still fine");
    streaming.release();
}

test "list pages with more and next_cursor" {
    const s = try Store.create(testing.allocator, testSet(.{}));
    defer s.release();
    for (1..6) |i| {
        s.admitRequest(i, @intCast(i), json_meta.url, "api.example", .xhr, "GET", 0);
        endStream(s, s.beginResponse(i, json_meta, 0, 0).?);
        s.finish(i, true, 0, 200, 1);
    }
    var scratch: [MAX_ENTRIES]Listed = undefined;
    var l = s.list(&scratch, 0, 2);
    try testing.expect(l.more);
    try testing.expectEqual(@as(u32, 2), l.next_cursor);
    l = s.list(&scratch, l.next_cursor, 10);
    try testing.expect(!l.more);
    try testing.expectEqual(@as(usize, 3), l.entries.len);
    try testing.expectEqual(@as(u32, 5), l.next_cursor);
    l = s.list(&scratch, l.next_cursor, 10);
    try testing.expectEqual(@as(usize, 0), l.entries.len);
    try testing.expectEqual(@as(u32, 5), l.next_cursor);
    // "After now" for a waiter: the newest cursor, whatever `since` was.
    try testing.expectEqual(@as(u32, 5), s.list(&scratch, std.math.maxInt(u32), 1).head_cursor);
}

test "list: in-flight exchanges follow the finished page and never move the cursor" {
    const s = try Store.create(testing.allocator, testSet(.{}));
    defer s.release();
    s.admitRequest(1, 10, json_meta.url, "api.example", .xhr, "GET", 0);
    s.admitRequest(2, 11, json_meta.url, "api.example", .xhr, "GET", 0);
    const done = s.beginResponse(1, json_meta, 0, 0).?;
    const open = s.beginResponse(2, json_meta, 0, 0).?;
    var hint: usize = MAX_ENTRIES;
    s.appendBody(open, &hint, "all of it");
    // Its stream ended but the engine never completed the load (a body
    // the page does not read): in flight, yet its bytes are readable.
    endStream(s, open);
    endStream(s, done);
    s.finish(1, true, 0, 200, 1);
    var scratch: [MAX_ENTRIES]Listed = undefined;
    const plain = s.list(&scratch, 0, 50);
    try testing.expectEqual(@as(usize, 1), plain.entries.len);
    const with = s.listWith(&scratch, 0, 50, true);
    try testing.expectEqual(@as(usize, 2), with.entries.len);
    try testing.expectEqual(@as(u32, 10), with.entries[0].seq);
    try testing.expectEqual(@as(u32, 11), with.entries[1].seq);
    try testing.expectEqual(@as(u32, 0), with.entries[1].cursor);
    try testing.expect(with.entries[1].flags & proto.CaptureEntry.flag_complete == 0);
    try testing.expectEqual(@as(u32, 1), with.next_cursor);
    var buf: [32]u8 = undefined;
    const b = s.readBody(11, .response, 0, &buf);
    try testing.expect(!b.complete);
    try testing.expectEqualStrings("all of it", buf[0..b.len]);
}

test "classify: text is UTF-8 or transcoded, everything else is binary" {
    try testing.expectEqual(Encoding.utf8, classify("application/json", "", "{\"a\":\"\u{00e9}\"}"));
    try testing.expectEqual(Encoding.utf8, classify("application/vnd.api+json", "utf-8", "{}"));
    try testing.expectEqual(Encoding.latin1, classify("text/plain", "ISO-8859-1", "caf\xe9"));
    try testing.expectEqual(Encoding.binary, classify("text/plain", "utf-8", "caf\xe9"));
    try testing.expectEqual(Encoding.binary, classify("image/png", "", "\x89PNG"));
    try testing.expectEqual(Encoding.binary, classify("application/x-protobuf", "", "abc"));
    try testing.expectEqual(Encoding.utf8, classify("", "", "plain"));

    const latin = try toUtf8(testing.allocator, .latin1, "caf\xe9");
    defer testing.allocator.free(latin);
    try testing.expectEqualStrings("caf\u{00e9}", latin);
    const cp = try toUtf8(testing.allocator, .windows1252, "\x80 \x81");
    defer testing.allocator.free(cp);
    try testing.expectEqualStrings("\u{20ac} \u{fffd}", cp);
}

test "charsetOf reads the parameter, quoted or not" {
    try testing.expectEqualStrings("utf-8", charsetOf("application/json; charset=utf-8"));
    try testing.expectEqualStrings("ISO-8859-1", charsetOf("text/html;Charset=\"ISO-8859-1\""));
    try testing.expectEqualStrings("", charsetOf("text/html"));
}
