//! Search jobs: find, grep, tag find, panelize and live find.

const std = @import("std");
const c = @import("../../c.zig").c;
const pathz = @import("../../util/pathz.zig");
const fsserve = @import("../fsserve.zig");
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;
const Spec = fsjob.Spec;
const common = @import("common.zig");
const MAX_MATCHES = common.MAX_MATCHES;
const statOf = common.statOf;

/// Search caps beyond the shared match cap: a runaway query costs a
/// bounded stream, never a flooded daemon pipe.
const MAX_MATCHES_PER_FILE: usize = 200;
const MAX_GREP_FILE: u64 = 8 << 20;
const MAX_MATCH_LINE: usize = 300;

/// Hard ceiling a caller's `max_matches` is clamped to.
const MAX_MATCHES_CEILING: u64 = 200_000;

fn matchCapOf(spec: Spec) usize {
    if (spec.max_matches == 0) return MAX_MATCHES;
    return @intCast(@min(spec.max_matches, MAX_MATCHES_CEILING));
}

const wallMs = @import("../../util/clock.zig").wallMs;

// ── find / grep ─────────────────────────────────────────────────

/// Case-insensitive glob: `*` and `?` wildcards; a pattern without
/// wildcards matches as a SUBSTRING (what a search box means).
pub fn nameMatches(pattern: []const u8, name: []const u8) bool {
    if (std.mem.indexOfAny(u8, pattern, "*?") == null)
        return std.ascii.findIgnoreCase(name, pattern) != null;
    return globMatch(pattern, name);
}

/// Iterative *-backtracking matcher, ASCII case-folded, `?` a wildcard.
const globMatch = @import("../../util/glob.zig").matchName;

const SearchState = struct {
    job: *const Job,
    matches: usize = 0,
    scanned: u64 = 0,
    truncated: bool = false,
    lower_pat: []u8,
    /// Relative-time filter: entries older than this are skipped.
    min_mtime_ms: i64 = 0,
    max_matches: usize = MAX_MATCHES,
};

pub fn runSearch(job: *const Job, content: bool) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    if (spec.pattern.len == 0) return job.emitError("empty pattern");
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, true)) return job.emitErrno("stat root");
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return job.emitError("search root is not a directory");
    const lower = allocator.dupe(u8, spec.pattern) catch return job.emitError("out of memory");
    defer allocator.free(lower);
    for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
    var state = SearchState{ .job = job, .lower_pat = lower, .max_matches = matchCapOf(spec) };
    if (spec.within_ms > 0)
        state.min_mtime_ms = wallMs() - @as(i64, @intCast(@min(spec.within_ms, 1 << 50)));
    searchDir(allocator, spec.src, spec.pattern, content, &state);
    job.emit(.{
        .ev = "done",
        .done = state.scanned,
        .total = state.scanned,
        .matches = state.matches,
        .truncated = state.truncated,
    });
    return 0;
}

pub fn runTagFind(job: *const Job) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    const tag = std.mem.trim(u8, spec.pattern, " #");
    if (tag.len == 0) return job.emitError("empty tag");
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, true)) return job.emitErrno("stat root");
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return job.emitError("search root is not a directory");
    var state = SearchState{ .job = job, .lower_pat = &.{}, .max_matches = matchCapOf(spec) };
    if (spec.within_ms > 0)
        state.min_mtime_ms = wallMs() - @as(i64, @intCast(@min(spec.within_ms, 1 << 50)));
    tagSearchDir(allocator, spec.src, tag, &state);
    job.emit(.{
        .ev = "done",
        .done = state.scanned,
        .total = state.scanned,
        .matches = state.matches,
        .truncated = state.truncated,
    });
    return 0;
}

fn tagSearchDir(allocator: std.mem.Allocator, dir_path: []const u8, tag: []const u8, state: *SearchState) void {
    if (state.matches >= state.max_matches) {
        state.truncated = true;
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES) catch return;
    for (l.entries) |e| {
        if (state.matches >= state.max_matches) {
            state.truncated = true;
            return;
        }
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{s}/{s}", .{ if (dir_path.len == 1) "" else dir_path, e.name }) catch continue;
        const full = w.buffered();
        const fresh = state.min_mtime_ms == 0 or e.mtime_ms >= state.min_mtime_ms;
        if (fresh and fsserve.hasTag(e.tags, tag)) {
            state.matches += 1;
            state.job.emit(.{ .ev = "match", .path = full, .kind = e.kind, .size = e.size, .mtime_ms = e.mtime_ms, .mode = e.mode });
        }
        state.scanned += 1;
        if (state.scanned % 512 == 0)
            state.job.emit(.{ .ev = "progress", .done = state.scanned, .total = @as(u64, 0) });
        if (std.mem.eql(u8, e.kind, "dir"))
            tagSearchDir(allocator, full, tag, state);
    }
}

fn searchDir(allocator: std.mem.Allocator, dir_path: []const u8, pattern: []const u8, content: bool, state: *SearchState) void {
    if (state.matches >= state.max_matches) {
        state.truncated = true;
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES) catch return;
    for (l.entries) |e| {
        if (state.matches >= state.max_matches) {
            state.truncated = true;
            return;
        }
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{s}/{s}", .{ if (dir_path.len == 1) "" else dir_path, e.name }) catch continue;
        const full = w.buffered();
        if (!content) {
            const fresh = state.min_mtime_ms == 0 or e.mtime_ms >= state.min_mtime_ms;
            if (fresh and nameMatches(pattern, e.name)) {
                state.matches += 1;
                state.job.emit(.{ .ev = "match", .path = full, .kind = e.kind, .size = e.size, .mtime_ms = e.mtime_ms, .mode = e.mode });
            }
        } else if (std.mem.eql(u8, e.kind, "file") and e.size <= MAX_GREP_FILE) {
            grepFile(full, state);
        }
        state.scanned += 1;
        if (state.scanned % 512 == 0)
            state.job.emit(.{ .ev = "progress", .done = state.scanned, .total = @as(u64, 0) });
        if (std.mem.eql(u8, e.kind, "dir"))
            searchDir(allocator, full, pattern, content, state);
    }
}

/// Output lines quoted back when they are not usable paths. The
/// COUNT on the done event is exact; this only bounds how many of
/// them travel as text.
const MAX_PANEL_REJECTS: usize = 20;

/// Turns a panelize command's output stream into rows. A line that
/// does not resolve to something on disk is REJECTED, never dropped:
/// commands print diagnostics, totals and "fatal: ..." on stdout too,
/// and a listing that silently swallows them is a listing you cannot
/// trust.
const PanelOut = struct {
    job: *const Job,
    root: []const u8,
    max_matches: usize = MAX_MATCHES,
    matches: usize = 0,
    rejected: u64 = 0,
    quoted: usize = 0,
    truncated: bool = false,

    /// One delimited output item. Blank items are separator noise and
    /// count as nothing at all.
    fn take(self: *PanelOut, raw: []const u8) void {
        const value = std.mem.trim(u8, raw, " \t\r");
        if (value.len == 0) return;
        if (self.matches >= self.max_matches) {
            self.truncated = true;
            return;
        }
        if (panelizeOne(self.job, self.root, value)) {
            self.matches += 1;
            return;
        }
        self.rejected += 1;
        if (self.quoted < MAX_PANEL_REJECTS) {
            self.quoted += 1;
            self.job.emit(.{ .ev = "reject", .text = value[0..@min(value.len, MAX_MATCH_LINE)] });
        }
    }
};

/// Run an arbitrary host-side command and turn each LF- or NUL-delimited
/// output path into an operable result entry. Relative paths use `src` as cwd.
///
/// A nonzero exit is REPORTED (`exit_status` on the done event), not
/// treated as failure: `rg -l` exits 1 when nothing matched and `find`
/// exits 1 on an unreadable subdirectory, and in both cases the rows
/// that did arrive are the listing the user asked for.
pub fn runPanelize(job: *const Job) u8 {
    const spec = job.spec;
    if (spec.pattern.len == 0) return job.emitError("panelize needs command");
    var cwdz: [4096]u8 = undefined;
    const cwd = pathz.pathZ(&cwdz, spec.src) catch return job.emitError("cwd too long");
    var cmdz: [16 * 1024:0]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&cmdz, "{s}", .{spec.pattern}, 0) catch return job.emitError("command too long");
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return job.emitErrno("pipe");
    const pid = c.fork();
    if (pid < 0) return job.emitErrno("fork");
    if (pid == 0) {
        _ = c.chdir(cwd);
        _ = c.dup2(pipefd[1], 1);
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-lc", cmd.ptr, null };
        _ = c.execv("/bin/sh", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(pipefd[1]);
    var out = PanelOut{ .job = job, .root = spec.src, .max_matches = matchCapOf(spec) };
    var item: [4096]u8 = undefined;
    var item_len: usize = 0;
    var overlong = false;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(pipefd[0], &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |ch| {
            if (ch == '\n' or ch == 0) {
                // A truncated item would resolve to the WRONG file, so
                // the whole item is rejected rather than shortened.
                if (overlong) {
                    out.rejected += 1;
                    if (out.quoted < MAX_PANEL_REJECTS) {
                        out.quoted += 1;
                        job.emit(.{ .ev = "reject", .text = "output item longer than 4096 bytes" });
                    }
                } else out.take(item[0..item_len]);
                item_len = 0;
                overlong = false;
            } else if (item_len < item.len) {
                item[item_len] = ch;
                item_len += 1;
            } else overlong = true;
        }
    }
    if (item_len > 0 and !overlong) out.take(item[0..item_len]);
    _ = c.close(pipefd[0]);
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
    const status: i64 = if (c.WIFEXITED(st)) c.WEXITSTATUS(st) else -1;
    job.emit(.{
        .ev = "done",
        .done = out.matches,
        .total = out.matches,
        .matches = out.matches,
        .truncated = out.truncated,
        .rejected = out.rejected,
        .exit_status = status,
    });
    return 0;
}

/// Resolve one output item against the panel root and stream it as a
/// row. @return false when it does not name anything on disk.
fn panelizeOne(job: *const Job, root: []const u8, value: []const u8) bool {
    var full_buf: [4096]u8 = undefined;
    const full = if (value[0] == '/')
        value
    else
        std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ if (root.len == 1) "" else root, value }) catch return false;
    var st: c.struct_stat = undefined;
    if (!statOf(full, &st, false)) return false;
    job.emit(.{
        .ev = "match",
        .path = full,
        .kind = fsserve.kindOf(st.st_mode),
        .size = if (st.st_size > 0) @as(u64, @intCast(st.st_size)) else 0,
        .mtime_ms = fsserve.mtimeMs(&st),
        .mode = @as(u32, @intCast(st.st_mode & 0o7777)),
    });
    return true;
}

// ── live queries ────────────────────────────────────────────────

/// Directories watched at once. A recursive watch costs kernel memory
/// per directory, so a query over a huge tree stops adding watches --
/// and SAYS so on its status event rather than silently going deaf.
const MAX_LIVE_WATCHES: usize = 8192;

/// Longest a query with a relative-time predicate sleeps between
/// deadline checks. The sleep normally runs to the nearest expiry;
/// this only bounds how stale a wall-clock jump (NTP step, suspend,
/// DST) can leave the view.
const MAX_LIVE_SLEEP_MS: i64 = 5 * 60 * 1000;

const LiveWatch = struct { wd: c_int, path: []u8 };

/// A live filename query: the watch set, the paths currently matching,
/// and -- for a relative-time predicate -- when each of those stops
/// matching.
///
/// Time predicates are re-evaluated by DEADLINE, never by rescanning.
/// Every match knows the wall-clock instant its mtime leaves the
/// window; the poll sleeps until the nearest one, and the wakeup is an
/// integer scan of the tracked set with no readdir and no stat. A tree
/// is walked exactly once, at startup.
const LiveState = struct {
    job: *const Job,
    allocator: std.mem.Allocator,
    watcher: *fsserve.Watcher,
    pattern: []const u8,
    /// 0 = no time predicate; matches then never expire.
    within_ms: u64 = 0,
    max_matches: usize = MAX_MATCHES,
    watches: std.ArrayList(LiveWatch) = .empty,
    /// Matching path -> expiry instant (0 = never). Owns its keys, and
    /// IS the row set the client is showing: the caps below are about
    /// this set, not about a cumulative count, so a query that runs
    /// for a week never truncates itself over churn.
    matched: std.StringHashMapUnmanaged(i64) = .empty,
    truncated: bool = false,
    watch_limit: bool = false,
    /// A bound was newly hit; the status event needs re-sending.
    status_dirty: bool = false,

    fn deinit(self: *LiveState) void {
        for (self.watches.items) |w| self.allocator.free(w.path);
        self.watches.deinit(self.allocator);
        var it = self.matched.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.matched.deinit(self.allocator);
    }

    /// The instant a file with this mtime leaves the query window
    /// (0 = there is no window).
    fn expiryOf(self: *const LiveState, mtime_ms: i64) i64 {
        if (self.within_ms == 0) return 0;
        return mtime_ms +| @as(i64, @intCast(@min(self.within_ms, 1 << 50)));
    }

    fn fresh(self: *const LiveState, mtime_ms: i64, now: i64) bool {
        return self.within_ms == 0 or self.expiryOf(mtime_ms) > now;
    }

    fn pathOf(self: *const LiveState, wd: c_int) ?[]const u8 {
        for (self.watches.items) |w| {
            if (w.wd == wd) return w.path;
        }
        return null;
    }

    /// Stream one match, or refresh a row already on screen. Repeating
    /// a match is deliberate: the client upserts by path, so a write
    /// that changed size or mtime updates the row in place.
    fn add(self: *LiveState, path: []const u8, kind: []const u8, size: u64, mtime_ms: i64, mode: u32) void {
        const expiry = self.expiryOf(mtime_ms);
        if (self.matched.getPtr(path)) |slot| {
            slot.* = expiry;
        } else {
            if (self.matched.count() >= self.max_matches) {
                if (!self.truncated) {
                    self.truncated = true;
                    self.status_dirty = true;
                }
                return;
            }
            const owned = self.allocator.dupe(u8, path) catch return;
            self.matched.put(self.allocator, owned, expiry) catch {
                self.allocator.free(owned);
                return;
            };
        }
        self.job.emit(.{ .ev = "match", .path = path, .kind = kind, .size = size, .mtime_ms = mtime_ms, .mode = mode });
    }

    /// Drop exactly `path`. Silent when it was not a match: an unmatch
    /// for a row the client never had is pure noise.
    fn removeOne(self: *LiveState, path: []const u8) void {
        const kv = self.matched.fetchRemove(path) orelse return;
        self.job.emit(.{ .ev = "unmatch", .path = kv.key });
        self.allocator.free(kv.key);
    }

    /// Drop `path` AND everything under it. A directory moved out of
    /// the tree delivers no per-child event, so its rows would
    /// otherwise linger forever under a name that no longer exists.
    fn removeTree(self: *LiveState, path: []const u8) void {
        self.removeOne(path);
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.allocator);
        var it = self.matched.keyIterator();
        while (it.next()) |k| {
            const key = k.*;
            if (key.len > path.len and std.mem.startsWith(u8, key, path) and key[path.len] == '/')
                doomed.append(self.allocator, key) catch {};
        }
        for (doomed.items) |key| self.removeOne(key);
        self.dropWatchesUnder(path);
    }

    fn dropWatchesUnder(self: *LiveState, path: []const u8) void {
        var i: usize = 0;
        while (i < self.watches.items.len) {
            const w = self.watches.items[i];
            const under = std.mem.eql(u8, w.path, path) or
                (w.path.len > path.len and std.mem.startsWith(u8, w.path, path) and w.path[path.len] == '/');
            if (!under) {
                i += 1;
                continue;
            }
            self.watcher.remove(w.wd);
            self.allocator.free(w.path);
            _ = self.watches.swapRemove(i);
        }
    }

    /// Drop every match whose time predicate has run out.
    fn expire(self: *LiveState, now: i64) void {
        if (self.within_ms == 0) return;
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.allocator);
        var it = self.matched.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != 0 and kv.value_ptr.* <= now)
                doomed.append(self.allocator, kv.key_ptr.*) catch {};
        }
        for (doomed.items) |key| self.removeOne(key);
    }

    /// Poll timeout: milliseconds until the earliest match ages out.
    /// -1 (sleep forever) whenever there is no time predicate at all.
    fn sleepMs(self: *const LiveState, now: i64) c_int {
        if (self.within_ms == 0) return -1;
        var soonest: i64 = 0;
        var it = self.matched.valueIterator();
        while (it.next()) |v| {
            if (v.* == 0) continue;
            if (soonest == 0 or v.* < soonest) soonest = v.*;
        }
        if (soonest == 0) return @intCast(MAX_LIVE_SLEEP_MS);
        const delta = soonest - now;
        if (delta <= 0) return 0;
        return @intCast(@min(delta, MAX_LIVE_SLEEP_MS));
    }

    /// The query's status line: rows streamed, directories watched, and
    /// whether either bound was hit. Sent once the initial scan is done
    /// and again whenever a bound is newly reached.
    fn emitStatus(self: *LiveState) void {
        self.status_dirty = false;
        self.job.emit(.{
            .ev = "ready",
            .matches = self.matched.count(),
            .watches = self.watches.items.len,
            .truncated = self.truncated,
            .watch_limit = self.watch_limit,
        });
    }
};

/// Watch `path`, stream the entries in it that match, and recurse.
fn liveScanDir(st: *LiveState, path: []const u8) void {
    if (st.watches.items.len >= MAX_LIVE_WATCHES) {
        if (!st.watch_limit) {
            st.watch_limit = true;
            st.status_dirty = true;
        }
        return;
    }
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return;
    const wd = st.watcher.add(pz);
    if (wd < 0) {
        // A refused watch is not the same as an empty one. When the
        // backend is out of capacity (kqueue's fd budget, inotify's
        // max_user_watches) this directory AND everything below it go
        // unwatched, and the query keeps streaming as if it were live.
        // A partial live view that says it is partial is usable; one
        // that stays quiet is a wrong answer with no symptom.
        if (st.watcher.exhausted and !st.watch_limit) {
            st.watch_limit = true;
            st.status_dirty = true;
        }
        return;
    }
    // inotify hands back the SAME descriptor for a directory already
    // watched, which is how re-entering a known subtree costs nothing.
    for (st.watches.items) |w| {
        if (w.wd == wd) return;
    }
    const owned = st.allocator.dupe(u8, path) catch return;
    st.watches.append(st.allocator, .{ .wd = wd, .path = owned }) catch {
        st.allocator.free(owned);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(st.allocator);
    defer arena.deinit();
    const listing = fsserve.listDir(arena.allocator(), path, fsserve.MAX_ENTRIES) catch return;
    const now = wallMs();
    for (listing.entries) |e| {
        var full_buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ if (path.len == 1) "" else path, e.name }) catch continue;
        if (nameMatches(st.pattern, e.name) and st.fresh(e.mtime_ms, now))
            st.add(full, e.kind, e.size, e.mtime_ms, e.mode);
        if (std.mem.eql(u8, e.kind, "dir")) liveScanDir(st, full);
    }
}

/// Durable Haiku-style live filename query, watching the tree
/// recursively: inotify on Linux, kqueue on macOS (see fsserve.Watcher
/// for the one event the latter cannot see). A host with neither
/// reports the missing watcher honestly instead of polling.
pub fn runLiveFind(job: *const Job) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    if (spec.pattern.len == 0) return job.emitError("live_find needs pattern");
    var watcher: fsserve.Watcher = .{};
    defer watcher.deinit();
    if (!watcher.ensure()) return job.emitError("cannot create filesystem watcher");
    var st = LiveState{
        .job = job,
        .allocator = allocator,
        .watcher = &watcher,
        .pattern = spec.pattern,
        .within_ms = spec.within_ms,
        .max_matches = matchCapOf(spec),
    };
    defer st.deinit();
    liveScanDir(&st, spec.src);
    st.emitStatus();
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        // stdout rides the poll set purely for its hangup: a copy keeps
        // running when the daemon dies (durability), but a live query
        // with no one left to stream to is a recursive watcher held
        // open forever for nobody.
        var pfds = [_]c.struct_pollfd{
            .{ .fd = watcher.fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = 1, .events = 0, .revents = 0 },
        };
        const pr = c.poll(&pfds, 2, st.sleepMs(wallMs()));
        if (pr < 0) {
            if (std.posix.errno(pr) == .INTR) continue;
            return job.emitError("watcher poll failed");
        }
        if (pfds[1].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return 0;
        if (pfds[0].revents != 0) {
            const n = watcher.readInto(&buf);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n <= 0) return job.emitError("watcher read failed");
            var it = fsserve.EventIter{ .buf = buf[0..@intCast(n)] };
            while (it.next()) |ev| liveEvent(&st, ev);
        }
        // Checked after an event batch too, not just after a timeout:
        // a busy tree can keep the poll returning readable straight
        // through a deadline.
        st.expire(wallMs());
        if (st.status_dirty) st.emitStatus();
    }
}

fn liveEvent(st: *LiveState, ev: fsserve.InoEvent) void {
    if (ev.isOverflow()) return st.job.emit(.{ .ev = "resync" });
    const parent = st.pathOf(ev.wd) orelse return;
    // removeTree frees the watch paths, so the parent has to be copied
    // out before anything can invalidate it.
    var parent_buf: [4096]u8 = undefined;
    if (parent.len > parent_buf.len) return;
    @memcpy(parent_buf[0..parent.len], parent);
    const dir = parent_buf[0..parent.len];
    if (ev.isSelfGone()) return st.removeTree(dir);
    if (ev.name.len == 0) return;

    var full_buf: [4096]u8 = undefined;
    const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ if (dir.len == 1) "" else dir, ev.name }) catch return;
    var z: [4096]u8 = undefined;
    const fz = pathz.pathZ(&z, full) catch return;
    var stt: c.struct_stat = undefined;
    if (c.lstat(fz, &stt) != 0) return st.removeTree(full);
    const kind = fsserve.kindOf(stt.st_mode);
    const mtime_ms = fsserve.mtimeMs(&stt);
    if (nameMatches(st.pattern, ev.name) and st.fresh(mtime_ms, wallMs())) {
        st.add(full, kind, if (stt.st_size > 0) @as(u64, @intCast(stt.st_size)) else 0, mtime_ms, @as(u32, @intCast(stt.st_mode & 0o7777)));
    } else {
        // Only this entry stopped matching. Its children (a directory
        // that never matched the pattern still holds matching files)
        // are untouched.
        st.removeOne(full);
    }
    // A directory that appeared -- or that was moved in under a new
    // name -- has to be watched and listed, matching or not.
    if (std.mem.eql(u8, kind, "dir")) liveScanDir(st, full);
}

/// Line-based case-insensitive content scan; binary files (NUL in
/// the first 4KB) are skipped.
fn grepFile(path: []const u8, state: *SearchState) void {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return;
    const fd = c.open(p, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return;
    defer _ = c.close(fd);

    var buf: [64 * 1024]u8 = undefined;
    var carry: [MAX_MATCH_LINE]u8 = undefined;
    var carry_len: usize = 0;
    var line_no: u64 = 1;
    var file_matches: usize = 0;
    var first = true;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        const chunk = buf[0..@intCast(n)];
        if (first) {
            first = false;
            const probe = chunk[0..@min(chunk.len, 4096)];
            if (std.mem.indexOfScalar(u8, probe, 0) != null) return; // binary
        }
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, chunk, start, '\n')) |nl| {
            const tail = chunk[start..nl];
            if (matchLine(state, path, line_no, carry[0..carry_len], tail)) {
                file_matches += 1;
                if (file_matches >= MAX_MATCHES_PER_FILE or state.matches >= state.max_matches) return;
            }
            carry_len = 0;
            line_no += 1;
            start = nl + 1;
        }
        const rest = chunk[start..];
        const room = carry.len - carry_len;
        const take = @min(rest.len, room);
        @memcpy(carry[carry_len .. carry_len + take], rest[0..take]);
        carry_len += take;
        // A line longer than the carry buffer: the head is enough for
        // matching/preview; the overflow is dropped by design.
    }
    if (carry_len > 0)
        _ = matchLine(state, path, line_no, carry[0..carry_len], "");
}

fn matchLine(state: *SearchState, path: []const u8, line_no: u64, head: []const u8, tail: []const u8) bool {
    var line_buf: [MAX_MATCH_LINE]u8 = undefined;
    const hn = @min(head.len, line_buf.len);
    @memcpy(line_buf[0..hn], head[0..hn]);
    const tn = @min(tail.len, line_buf.len - hn);
    @memcpy(line_buf[hn .. hn + tn], tail[0..tn]);
    const line = line_buf[0 .. hn + tn];
    for (line) |*ch| {
        if (ch.* == '\r' or ch.* == '\t') ch.* = ' ';
    }
    var lower_buf: [MAX_MATCH_LINE]u8 = undefined;
    for (line, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    if (std.mem.indexOf(u8, lower_buf[0..line.len], state.lower_pat) == null) return false;
    // Strip non-printable control bytes for the preview.
    for (line) |*ch| {
        if (ch.* < 0x20) ch.* = ' ';
    }
    state.matches += 1;
    state.job.emit(.{ .ev = "match", .path = path, .line = line_no, .text = line });
    return true;
}

test "nameMatches: substring default, glob with wildcards, ci" {
    const t = std.testing;
    try t.expect(nameMatches("read", "README.md"));
    try t.expect(nameMatches("ME.md", "README.md"));
    try t.expect(!nameMatches("xyz", "README.md"));
    try t.expect(nameMatches("*.md", "README.md"));
    try t.expect(nameMatches("re*me.??", "README.md"));
    try t.expect(!nameMatches("*.txt", "README.md"));
    try t.expect(nameMatches("*", "anything"));
    try t.expect(nameMatches("a?c", "AbC"));
    try t.expect(!nameMatches("a?c", "abbc"));
    try t.expect(nameMatches("*b*b*", "abxbx"));
    try t.expect(!nameMatches("*b*b*", "abxx"));
}

test "grep stops at the job's own match cap, not the default one" {
    const t = std.testing;
    const td = pathz.TempDir.make("fsjob-grepcap") orelse return error.SkipZigTest;
    defer td.remove();
    var pb: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/hits.txt", .{td.path()});
    var z: [4096]u8 = undefined;
    const f = c.fopen(try pathz.pathZ(&z, path), "wb") orelse return error.SkipZigTest;
    for (0..50) |_| _ = c.fwrite("hit\n", 1, 4, f);
    _ = c.fclose(f);
    const job = Job{ .allocator = t.allocator, .spec = .{} };
    var pat = "hit".*;

    // 1. A raised cap: past the default, every matching line of the file still counts.
    var raised = SearchState{ .job = &job, .lower_pat = &pat, .matches = MAX_MATCHES, .max_matches = MAX_MATCHES + 100 };
    grepFile(path, &raised);
    try t.expectEqual(MAX_MATCHES + 50, raised.matches);

    // 2. A lowered cap: the scan stops inside the file, exactly at the cap.
    var lowered = SearchState{ .job = &job, .lower_pat = &pat, .max_matches = 10 };
    grepFile(path, &lowered);
    try t.expectEqual(@as(usize, 10), lowered.matches);
}
