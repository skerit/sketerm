//! Version-control overlay state for the file browser: porcelain-v2
//! record parsing, directory rollup, the display decision and the
//! per-root refresh cache.
//!
//! GTK-free on purpose — the daemon's `git_status` job (`mux/fsjob.zig`)
//! scans `git status --porcelain=v2 --branch --ignored -z` with the
//! `Scanner` below, and the UI side (`src/ui/browser/gitstat.zig`) only
//! ships records in and reads badges out. Every rule is therefore
//! unit-testable from both test roots, and producer and consumer agree
//! on the record shape by construction.

const std = @import("std");

// ── porcelain v2 scanning ────────────────────────────────────────

/// Which porcelain-v2 line produced a record.
pub const Kind = enum {
    /// `1 <XY> …` — a tracked path changed in the index, the
    /// worktree, or both.
    ordinary,
    /// `2 <XY> … <path><NUL><origPath>` — rename or copy.
    rename,
    /// `u <XY> …` — an unmerged path; XY is the conflict pair.
    unmerged,
    /// `? <path>`
    untracked,
    /// `! <path>` — with `--ignored=traditional` a wholly ignored
    /// DIRECTORY collapses to one record with a trailing slash.
    ignored,
};

/// One porcelain-v2 entry. Every slice borrows the scanned buffer.
pub const Record = struct {
    kind: Kind,
    /// Index (staged) column; `.` = unmodified. `?`/`!` for the
    /// untracked and ignored records, which have no columns of their
    /// own — giving them the same two-column shape keeps every
    /// downstream decision uniform.
    x: u8,
    /// Worktree (unstaged) column.
    y: u8,
    /// Repository-root relative, unquoted (that is what `-z` buys).
    path: []const u8,
    /// Rename/copy source, repository-root relative; empty otherwise.
    orig: []const u8 = "",
    /// `R100` / `C75`, verbatim; empty for non-rename records.
    score: []const u8 = "",
    /// The `<sub>` field said `S…`: this entry is a submodule, so its
    /// "modification" is a commit pointer, not file content.
    submodule: bool = false,

    /// The single character the pre-v2 wire carried, so a new daemon
    /// keeps answering old clients exactly as before.
    ///
    /// Mirrors the old collapse `if (X != ' ' and X != '?') X else Y`
    /// applied to `git status --porcelain`'s two columns.
    pub fn legacyChar(self: Record) u8 {
        const x = if (self.x == '.') ' ' else self.x;
        const y = if (self.y == '.') ' ' else self.y;
        return if (x != ' ' and x != '?') x else y;
    }
};

/// The `# branch.*` headers. `is_repo` is the only reliable "this is a
/// repository" signal: `git status` prints nothing at all outside one.
pub const Header = struct {
    is_repo: bool = false,
    /// `# branch.head (detached)`.
    detached: bool = false,
    /// `# branch.oid (initial)` — a repository with no commit yet.
    initial: bool = false,
    /// Commit hash; empty when `initial`.
    oid: []const u8 = "",
    /// Branch name; empty when `detached`.
    branch: []const u8 = "",
    /// Upstream ref, empty when the branch tracks nothing.
    upstream: []const u8 = "",
    ahead: i64 = 0,
    behind: i64 = 0,
    /// `# branch.ab` was present (it only is when an upstream is).
    have_ab: bool = false,
};

/// Streaming scanner over one `--porcelain=v2 --branch -z` buffer.
///
/// Headers are folded into `header` as they go by; `next` yields only
/// entries, so a caller may read `header` once the scan is done (git
/// emits every header before the first entry).
pub const Scanner = struct {
    rest: []const u8,
    header: Header = .{},

    pub fn init(buf: []const u8) Scanner {
        return .{ .rest = buf };
    }

    /// One NUL-terminated field. A trailing unterminated remainder is
    /// returned too — callers that care about truncation trim the
    /// buffer to its last NUL before scanning.
    fn token(self: *Scanner) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const nul = std.mem.indexOfScalar(u8, self.rest, 0) orelse {
            const all = self.rest;
            self.rest = self.rest[self.rest.len..];
            return all;
        };
        const t = self.rest[0..nul];
        self.rest = self.rest[nul + 1 ..];
        return t;
    }

    pub fn next(self: *Scanner) ?Record {
        while (self.token()) |tok| {
            if (tok.len == 0) continue;
            if (tok[0] == '#') {
                self.applyHeader(tok);
                continue;
            }
            if (tok.len < 3 or tok[1] != ' ') continue;
            switch (tok[0]) {
                // `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
                '1' => if (parseEntry(tok, .ordinary, 8)) |r| return r,
                // `2 … <X><score> <path>` + a second field: the source.
                '2' => {
                    var r = parseEntry(tok, .rename, 9) orelse continue;
                    r.score = field(tok, 8);
                    r.orig = self.token() orelse "";
                    return r;
                },
                // `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
                'u' => if (parseEntry(tok, .unmerged, 10)) |r| return r,
                '?' => return .{ .kind = .untracked, .x = '?', .y = '?', .path = tok[2..] },
                '!' => return .{ .kind = .ignored, .x = '!', .y = '!', .path = tok[2..] },
                else => continue,
            }
        }
        return null;
    }

    fn applyHeader(self: *Scanner, tok: []const u8) void {
        if (!std.mem.startsWith(u8, tok, "# ")) return;
        const body = tok[2..];
        if (headerValue(body, "branch.oid ")) |v| {
            self.header.is_repo = true;
            if (std.mem.eql(u8, v, "(initial)")) self.header.initial = true else self.header.oid = v;
        } else if (headerValue(body, "branch.head ")) |v| {
            self.header.is_repo = true;
            if (std.mem.eql(u8, v, "(detached)")) self.header.detached = true else self.header.branch = v;
        } else if (headerValue(body, "branch.upstream ")) |v| {
            self.header.is_repo = true;
            self.header.upstream = v;
        } else if (headerValue(body, "branch.ab ")) |v| {
            // "+3 -1"; either sign may be absent on malformed input.
            var it = std.mem.tokenizeScalar(u8, v, ' ');
            var seen = false;
            while (it.next()) |part| {
                if (part.len < 2) continue;
                const n = std.fmt.parseInt(i64, part[1..], 10) catch continue;
                switch (part[0]) {
                    '+' => {
                        self.header.ahead = n;
                        seen = true;
                    },
                    '-' => {
                        self.header.behind = n;
                        seen = true;
                    },
                    else => {},
                }
            }
            if (seen) self.header.have_ab = true;
        }
    }
};

fn headerValue(body: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, body, key)) return null;
    return body[key.len..];
}

/// The space-separated field at `idx`, or empty when there is none.
fn field(tok: []const u8, idx: usize) []const u8 {
    const rest = restAfter(tok, idx) orelse return "";
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return rest;
    return rest[0..sp];
}

/// Everything past `n` spaces — the path field, which may itself
/// contain spaces and is therefore never re-split.
fn restAfter(tok: []const u8, n: usize) ?[]const u8 {
    var i: usize = 0;
    var seen: usize = 0;
    while (seen < n) : (seen += 1) {
        const sp = std.mem.indexOfScalarPos(u8, tok, i, ' ') orelse return null;
        i = sp + 1;
    }
    if (i >= tok.len) return null;
    return tok[i..];
}

fn parseEntry(tok: []const u8, kind: Kind, path_field: usize) ?Record {
    // "<t> <XY> <sub> …": XY at 2..4, the <sub> field opens at 5.
    if (tok.len < 6 or tok[4] != ' ') return null;
    const path = restAfter(tok, path_field) orelse return null;
    if (path.len == 0) return null;
    return .{
        .kind = kind,
        .x = tok[2],
        .y = tok[3],
        .path = path,
        .submodule = tok[5] == 'S',
    };
}

/// One entry's version-control state, ordered by PRECEDENCE: a higher
/// tag wins when several records fold onto the same path (a directory
/// rollup, or an index record plus a worktree record).
pub const State = enum(u8) {
    none = 0,
    ignored,
    untracked,
    added,
    typechange,
    modified,
    renamed,
    deleted,
    conflicted,

    pub fn rank(self: State) u8 {
        return @intFromEnum(self);
    }
};

/// Map one porcelain status character to a state.
///
/// `C` (copied) is reported as `added`: for a listing the copy is a
/// new file and the source is untouched.
pub fn fromChar(ch: u8) State {
    return switch (ch) {
        '?' => .untracked,
        '!' => .ignored,
        'A', 'C' => .added,
        'T' => .typechange,
        'M' => .modified,
        'R' => .renamed,
        'D' => .deleted,
        'U' => .conflicted,
        else => .none,
    };
}

pub fn merge(a: State, b: State) State {
    return if (b.rank() > a.rank()) b else a;
}

/// The state one porcelain column carries. `.` (v2's "unmodified")
/// and a space (v1's) both mean nothing happened on that side.
pub fn sideState(ch: u8) State {
    return switch (ch) {
        '.', ' ', 0 => .none,
        else => fromChar(ch),
    };
}

/// The seven column pairs porcelain-v2 uses for unmerged (`u`)
/// records. None of them is producible by an ordinary record — the
/// index and the worktree cannot both add or both delete the same
/// path — so the pair alone identifies a conflict, and the wire needs
/// no extra flag to say so.
pub fn isUnmergedPair(x: u8, y: u8) bool {
    const pairs = [_][2]u8{
        .{ 'D', 'D' }, .{ 'A', 'U' }, .{ 'U', 'D' }, .{ 'U', 'A' },
        .{ 'D', 'U' }, .{ 'A', 'A' }, .{ 'U', 'U' },
    };
    for (pairs) |p| if (p[0] == x and p[1] == y) return true;
    return false;
}

/// Index-side and worktree-side states of one record.
///
/// An unmerged record's columns are a CONFLICT PAIR (`AA`, `DU`, `UU`,
/// …), not two independent statuses, so both sides read as conflicted
/// rather than as "added twice".
pub fn sidesFor(r: Record) struct { index: State, work: State } {
    return switch (r.kind) {
        .unmerged => .{ .index = .conflicted, .work = .conflicted },
        .untracked => .{ .index = .none, .work = .untracked },
        .ignored => .{ .index = .none, .work = .ignored },
        .ordinary, .rename => .{ .index = sideState(r.x), .work = sideState(r.y) },
    };
}

/// What a child state contributes to its ANCESTOR directories.
///
/// Ignored content never propagates: a directory full of build output
/// would otherwise wear a permanent badge, which is the opposite of
/// what an ignore rule asked for.
pub fn propagates(self: State) State {
    return if (self == .ignored) .none else self;
}

/// The chip letter of a state, for rows whose two columns are not
/// known (a pre-v2 daemon reported one collapsed character).
pub fn letterFor(state: State) u8 {
    return switch (state) {
        .untracked => '?',
        .ignored => '!',
        .added => 'A',
        .typechange => 'T',
        .modified => 'M',
        .renamed => 'R',
        .deleted => 'D',
        .conflicted => 'U',
        .none => ' ',
    };
}

/// How one row is drawn.
///
/// `code` is what the chip prints: git's own two-column pair for an
/// exact row whose columns are known (`M.` staged, `.M` unstaged,
/// `MM` both, `??`, `UU`), a single letter when only a collapsed
/// character arrived, and `*` for "something inside changed". `css` is
/// a libadwaita status class so both themes stay readable without
/// hardcoded colours; `dim_name` fades the whole name instead of
/// adding a chip.
pub const Badge = struct {
    code: [2]u8 = .{ 0, 0 },
    code_len: u8 = 0,
    /// NUL-terminated so the UI can hand it straight to GTK.
    css: [:0]const u8,
    dim_name: bool = false,
    /// The index side carries a change (the row is at least partly
    /// staged) / the worktree side does.
    staged: bool = false,
    unstaged: bool = false,
    rollup: bool = false,

    pub fn text(self: *const Badge) []const u8 {
        return self.code[0..self.code_len];
    }
};

fn cssFor(state: State) [:0]const u8 {
    return switch (state) {
        .untracked, .added => "success",
        .modified, .typechange => "warning",
        .renamed => "accent",
        .deleted, .conflicted => "error",
        else => "dim-label",
    };
}

/// The chip for a folded row, or null when it must stay unmarked.
///
/// A rollup (`!row.exact`) means the state came from something BELOW
/// this row, never from a record naming it: those get one neutral `*`
/// so a directory cannot be mistaken for a changed file.
pub fn badgeForRow(row: Row) ?Badge {
    if (row.state == .none) return null;
    if (row.state == .ignored) {
        // Ignored is information, not an alarm: no chip at all, just
        // a faded name. Nothing propagates it, so a rollup cannot be
        // ignored in the first place.
        return if (!row.exact) null else Badge{ .css = "dim-label", .dim_name = true };
    }
    const css = cssFor(row.state);
    if (!row.exact) return .{ .code = .{ '*', 0 }, .code_len = 1, .css = css, .rollup = true };
    if (row.x == 0) {
        // Pre-v2 daemon: one collapsed character is all there is.
        return .{ .code = .{ letterFor(row.state), 0 }, .code_len = 1, .css = css };
    }
    return .{
        .code = .{ row.x, row.y },
        .code_len = 2,
        .css = css,
        .staged = row.index != .none,
        .unstaged = row.work != .none,
    };
}

/// Legacy entry point kept for callers that only have a merged state.
pub fn badgeFor(state: State, rollup: bool) ?Badge {
    return badgeForRow(.{ .state = state, .exact = !rollup });
}

/// Human word for a state, for tooltips and the status summary.
pub fn label(state: State) []const u8 {
    return switch (state) {
        .none => "unchanged",
        .ignored => "ignored",
        .untracked => "untracked",
        .added => "added",
        .typechange => "type changed",
        .modified => "modified",
        .renamed => "renamed",
        .deleted => "deleted",
        .conflicted => "conflicted",
    };
}

/// Folded state of one path in the overlay.
pub const Row = struct {
    state: State = .none,
    /// The porcelain columns of the record that produced `state`, or
    /// 0 when only a collapsed character arrived (an old daemon).
    x: u8 = 0,
    y: u8 = 0,
    index: State = .none,
    work: State = .none,
    /// A record named this exact path (as opposed to something under
    /// it): decides letter-vs-rollup rendering.
    exact: bool = false,
    submodule: bool = false,
    /// Rename/copy source, owned by the overlay; empty when none.
    orig: []const u8 = &.{},

    /// One line of prose for a tooltip.
    pub fn describe(self: Row, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        if (!self.exact) {
            w.writeAll("contains changes") catch {};
            return w.buffered();
        }
        if (self.state == .ignored) {
            w.writeAll("ignored by git") catch {};
            return w.buffered();
        }
        if (self.index == .conflicted and self.work == .conflicted) {
            w.print("conflicted ({c}{c})", .{ self.x, self.y }) catch {};
        } else if (self.x == 0) {
            w.writeAll(label(self.state)) catch {};
        } else {
            var wrote = false;
            if (self.index != .none) {
                w.print("staged {s}", .{label(self.index)}) catch {};
                wrote = true;
            }
            if (self.work != .none) {
                if (wrote) w.writeAll(", ") catch {};
                w.print("unstaged {s}", .{label(self.work)}) catch {};
            }
        }
        if (self.orig.len > 0) w.print(" (from {s})", .{self.orig}) catch {};
        if (self.submodule) w.writeAll(" [submodule]") catch {};
        return w.buffered();
    }
};

/// Hard ceiling on folded entries. The daemon caps its record stream
/// (see `mux/fsjob.zig`); times a path depth this is the memory the
/// overlay can ever hold, and a pathological tree stops growing it
/// rather than the browser growing without bound.
pub const MAX_ENTRIES: usize = 20000;

/// Every changed path under one browsed directory, folded so that a
/// row lookup is one hash probe.
///
/// Keys are relative to the BROWSED directory (the daemon already
/// stripped the repo prefix). Each record also folds into every
/// ancestor segment, which is what makes a directory row show that
/// something inside it changed without a second job.
pub const Overlay = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Row) = .empty,
    /// Per-state counts of EXACT records only — rollup entries would
    /// count the same change once per directory level.
    counts: [std.enums.values(State).len]u32 = @splat(0),
    /// The fold hit MAX_ENTRIES and stopped storing.
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator) Overlay {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Overlay) void {
        self.clear();
        self.map.deinit(self.allocator);
    }

    pub fn clear(self: *Overlay) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            if (kv.value_ptr.orig.len > 0) self.allocator.free(kv.value_ptr.orig);
        }
        self.map.clearRetainingCapacity();
        self.counts = @splat(0);
        self.truncated = false;
    }

    pub fn isEmpty(self: *const Overlay) bool {
        return self.map.count() == 0;
    }

    /// Total number of records that named a path (not rollups).
    pub fn changedCount(self: *const Overlay) u32 {
        var n: u32 = 0;
        // Ignored files are not "changes"; counting them would make a
        // clean tree with a build dir look dirty.
        for (self.counts[@intFromEnum(State.untracked)..]) |v| n += v;
        return n;
    }

    /// One record as it arrives from the daemon, already relative to
    /// the browsed directory.
    ///
    /// `x`/`y` are the porcelain-v2 columns; a pre-v2 daemon sends
    /// neither and `legacy` (the single collapsed character) is then
    /// the only information there is.
    pub const Input = struct {
        path: []const u8,
        x: u8 = 0,
        y: u8 = 0,
        legacy: u8 = 0,
        orig: []const u8 = "",
        submodule: bool = false,
    };

    /// Fold one collapsed-character record (the pre-v2 wire shape).
    pub fn apply(self: *Overlay, path: []const u8, ch: u8) void {
        self.applyInput(.{ .path = path, .legacy = ch });
    }

    /// Fold one record. A trailing slash (git's collapsed untracked or
    /// ignored directory form) is tolerated.
    pub fn applyInput(self: *Overlay, in: Input) void {
        var row = Row{ .exact = true, .submodule = in.submodule };
        if (in.x != 0) {
            row.x = in.x;
            row.y = in.y;
            if (in.x == '?' or in.x == '!') {
                // Untracked and ignored records have no index side at
                // all; their doubled column is git's own placeholder.
                row.work = sideState(in.x);
            } else if (isUnmergedPair(in.x, in.y)) {
                // A `u` record's columns are one conflict PAIR, not
                // two independent sides: `AA` is "both added", not a
                // staged-plus-unstaged add.
                row.index = .conflicted;
                row.work = .conflicted;
            } else {
                row.index = sideState(in.x);
                row.work = sideState(in.y);
            }
            row.state = merge(row.index, row.work);
        } else {
            row.state = fromChar(in.legacy);
        }
        if (row.state == .none) return;
        const rel = std.mem.trim(u8, in.path, "/");
        if (rel.len == 0) return;
        self.put(rel, row, in.orig);
        const up = propagates(row.state);
        if (up == .none) return;
        // Every ancestor segment carries the rollup.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| {
            self.put(rel[0..slash], .{ .state = up }, "");
            i = slash + 1;
        }
    }

    fn put(self: *Overlay, key: []const u8, new: Row, orig: []const u8) void {
        if (new.exact) self.counts[@intFromEnum(new.state)] +|= 1;
        if (self.map.getPtr(key)) |row| {
            // Strongest wins, and its columns travel with it: a weaker
            // record must not repaint a stronger one's chip.
            if (new.state.rank() > row.state.rank()) {
                const keep_exact = row.exact or new.exact;
                const keep_orig = row.orig;
                row.* = new;
                row.exact = keep_exact;
                row.orig = keep_orig;
            } else if (new.exact) {
                row.exact = true;
                row.submodule = row.submodule or new.submodule;
            }
            if (orig.len > 0 and row.orig.len == 0)
                row.orig = self.allocator.dupe(u8, orig) catch &.{};
            return;
        }
        if (self.map.count() >= MAX_ENTRIES) {
            self.truncated = true;
            return;
        }
        const owned = self.allocator.dupe(u8, key) catch {
            self.truncated = true;
            return;
        };
        var stored = new;
        if (orig.len > 0) stored.orig = self.allocator.dupe(u8, orig) catch &.{};
        self.map.put(self.allocator, owned, stored) catch {
            self.allocator.free(owned);
            if (stored.orig.len > 0) self.allocator.free(stored.orig);
            self.truncated = true;
        };
    }

    pub fn get(self: *const Overlay, rel: []const u8) ?Row {
        return self.map.get(rel);
    }

    /// The chip for a row, given its path relative to the browsed dir.
    pub fn badge(self: *const Overlay, rel: []const u8) ?Badge {
        const row = self.map.get(rel) orelse return null;
        return badgeForRow(row);
    }

    /// How many records carry a staged side, and how many an unstaged
    /// one. Rollups are excluded; a row changed on both sides counts
    /// in both.
    pub fn stagedSplit(self: *const Overlay) struct { staged: u32, unstaged: u32 } {
        var staged: u32 = 0;
        var unstaged: u32 = 0;
        var it = self.map.iterator();
        while (it.next()) |kv| {
            const row = kv.value_ptr.*;
            if (!row.exact or row.state == .ignored) continue;
            if (row.index != .none) staged += 1;
            if (row.work != .none) unstaged += 1;
        }
        return .{ .staged = staged, .unstaged = unstaged };
    }

    /// A short ", 3 modified, 1 untracked" phrase for the status line,
    /// or an empty slice when there is nothing to say.
    pub fn summary(self: *const Overlay, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        if (!self.writeSummary(&w)) return buf[0..0];
        if (self.truncated) w.writeAll(", partial") catch {};
        return w.buffered();
    }

    /// @return whether anything was written.
    fn writeSummary(self: *const Overlay, w: *std.Io.Writer) bool {
        var wrote = false;
        // Loudest first: a conflict is what the user must see.
        const order = [_]State{ .conflicted, .deleted, .renamed, .modified, .typechange, .added, .untracked };
        for (order) |st| {
            const n = self.counts[@intFromEnum(st)];
            if (n == 0) continue;
            w.print(", {d} {s}", .{ n, label(st) }) catch break;
            wrote = true;
        }
        return wrote;
    }
};

/// Repository-level answer for the browsed root.
///
/// `known` is the SKEW flag and the reason this type exists: a daemon
/// too old to answer the repository question sends no repo event at
/// all, and the browser must then keep its pre-branch behaviour rather
/// than claim "not a repository". `known and !is_repo` is a real
/// negative; `known and is_repo` with an empty overlay is a clean
/// repository, which used to be indistinguishable from a non-repo.
pub const Repo = struct {
    allocator: std.mem.Allocator,
    known: bool = false,
    is_repo: bool = false,
    detached: bool = false,
    /// No commit yet: there is a branch name but nothing to be ahead
    /// or behind of.
    initial: bool = false,
    /// The browsed directory IS the repository root, so an empty
    /// overlay means the whole repository is clean.
    at_root: bool = false,
    /// The daemon hit its record cap; counts are a floor.
    truncated: bool = false,
    branch: []u8 = &.{},
    upstream: []u8 = &.{},
    /// Abbreviated commit, for a detached HEAD.
    oid: []u8 = &.{},
    ahead: i64 = 0,
    behind: i64 = 0,
    have_ab: bool = false,

    pub fn init(allocator: std.mem.Allocator) Repo {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Repo) void {
        self.clear();
    }

    pub fn clear(self: *Repo) void {
        const a = self.allocator;
        if (self.branch.len > 0) a.free(self.branch);
        if (self.upstream.len > 0) a.free(self.upstream);
        if (self.oid.len > 0) a.free(self.oid);
        self.* = .{ .allocator = a };
    }

    /// Adopt one repo answer. Strings are copied; a failed copy leaves
    /// the field empty rather than failing the whole answer.
    pub fn set(self: *Repo, in: struct {
        is_repo: bool,
        detached: bool = false,
        initial: bool = false,
        at_root: bool = false,
        truncated: bool = false,
        branch: []const u8 = "",
        upstream: []const u8 = "",
        oid: []const u8 = "",
        ahead: i64 = 0,
        behind: i64 = 0,
        have_ab: bool = false,
    }) void {
        const a = self.allocator;
        self.clear();
        self.known = true;
        self.is_repo = in.is_repo;
        self.detached = in.detached;
        self.initial = in.initial;
        self.at_root = in.at_root;
        self.truncated = in.truncated;
        self.ahead = in.ahead;
        self.behind = in.behind;
        self.have_ab = in.have_ab;
        if (in.branch.len > 0) self.branch = a.dupe(u8, in.branch) catch &.{};
        if (in.upstream.len > 0) self.upstream = a.dupe(u8, in.upstream) catch &.{};
        if (in.oid.len > 0) self.oid = a.dupe(u8, in.oid) catch &.{};
    }
};

/// The version-control phrase appended to the browser's status line.
///
/// Three cases, in the order they matter:
/// - the daemon never answered the repository question (old build):
///   the pre-branch phrase, empty when nothing changed;
/// - a real "not a repository": nothing at all;
/// - a repository: `, on main +2 -1, 3 modified` — and `, clean` (or
///   `, no changes here` below the root) when there is nothing, which
///   is what makes a clean repository visible at all.
pub fn statusNote(repo: *const Repo, ov: *const Overlay, buf: []u8) []const u8 {
    if (!repo.known) return ov.summary(buf);
    if (!repo.is_repo) return buf[0..0];
    var w = std.Io.Writer.fixed(buf);
    if (repo.detached) {
        if (repo.oid.len > 0)
            w.print(", detached at {s}", .{repo.oid}) catch return w.buffered()
        else
            w.writeAll(", detached HEAD") catch return w.buffered();
    } else if (repo.branch.len > 0) {
        w.print(", on {s}", .{repo.branch}) catch return w.buffered();
    } else {
        w.writeAll(", git") catch return w.buffered();
    }
    if (repo.initial) {
        w.writeAll(" (no commits yet)") catch {};
    } else if (repo.have_ab and (repo.ahead != 0 or repo.behind != 0)) {
        if (repo.ahead != 0) w.print(" +{d}", .{repo.ahead}) catch {};
        if (repo.behind != 0) w.print(" -{d}", .{repo.behind}) catch {};
    }
    if (!ov.writeSummary(&w))
        w.writeAll(if (repo.at_root) ", clean" else ", no changes here") catch {};
    if (repo.truncated or ov.truncated) w.writeAll(", partial") catch {};
    return w.buffered();
}

/// Remembers which (host, root) pairs were asked recently, so that
/// walking back and forth between two folders does not respawn a
/// `git status` per step.
///
/// Deliberately tiny and time-bounded: the entry says only "asked at
/// T", never what the answer was, so a stale hit costs at most
/// `ttl_ms` of staleness and an explicit refresh always bypasses it.
pub const Cache = struct {
    pub const CAPACITY = 16;

    const Slot = struct {
        host: []u8 = &.{},
        path: []u8 = &.{},
        at_ms: i64 = 0,
        used: bool = false,
    };

    allocator: std.mem.Allocator,
    ttl_ms: i64 = 30_000,
    slots: [CAPACITY]Slot = @splat(.{}),
    /// Round-robin eviction cursor.
    next: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
    }

    pub fn clear(self: *Cache) void {
        for (&self.slots) |*s| self.release(s);
    }

    fn release(self: *Cache, s: *Slot) void {
        if (s.host.len > 0) self.allocator.free(s.host);
        if (s.path.len > 0) self.allocator.free(s.path);
        s.* = .{};
    }

    fn find(self: *Cache, host: []const u8, path: []const u8) ?*Slot {
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (std.mem.eql(u8, s.host, host) and std.mem.eql(u8, s.path, path)) return s;
        }
        return null;
    }

    /// True when this root was asked recently enough to skip.
    pub fn fresh(self: *Cache, host: []const u8, path: []const u8, now_ms: i64) bool {
        const s = self.find(host, path) orelse return false;
        if (now_ms -% s.at_ms > self.ttl_ms) {
            self.release(s);
            return false;
        }
        return true;
    }

    pub fn note(self: *Cache, host: []const u8, path: []const u8, now_ms: i64) void {
        if (self.find(host, path)) |s| {
            s.at_ms = now_ms;
            return;
        }
        const slot = &self.slots[self.next];
        self.next = (self.next + 1) % CAPACITY;
        self.release(slot);
        slot.host = self.allocator.dupe(u8, host) catch return;
        slot.path = self.allocator.dupe(u8, path) catch {
            self.allocator.free(slot.host);
            slot.* = .{};
            return;
        };
        slot.at_ms = now_ms;
        slot.used = true;
    }

    pub fn invalidate(self: *Cache, host: []const u8, path: []const u8) void {
        if (self.find(host, path)) |s| self.release(s);
    }
};

/// The overlay key for an entry: its path relative to the browsed
/// root, or null when the row lives outside that root (a miller
/// ancestor column) and the overlay says nothing about it.
pub fn relativeKey(root: []const u8, dir_path: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.eql(u8, root, dir_path)) {
        if (name.len > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const base = if (root.len == 1 and root[0] == '/') root.len - 1 else root.len;
    if (dir_path.len <= base + 1) return null;
    if (!std.mem.startsWith(u8, dir_path, root[0..base])) return null;
    if (dir_path[base] != '/') return null;
    const under = dir_path[base + 1 ..];
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ under, name }) catch null;
}

// ── tests ────────────────────────────────────────────────────────

test "porcelain characters map to states" {
    try std.testing.expectEqual(State.modified, fromChar('M'));
    try std.testing.expectEqual(State.untracked, fromChar('?'));
    try std.testing.expectEqual(State.ignored, fromChar('!'));
    try std.testing.expectEqual(State.deleted, fromChar('D'));
    try std.testing.expectEqual(State.renamed, fromChar('R'));
    try std.testing.expectEqual(State.conflicted, fromChar('U'));
    try std.testing.expectEqual(State.added, fromChar('A'));
    try std.testing.expectEqual(State.added, fromChar('C'));
    try std.testing.expectEqual(State.none, fromChar(' '));
    try std.testing.expectEqual(State.none, fromChar('x'));
}

test "precedence: a real change outranks untracked, which outranks ignored" {
    try std.testing.expectEqual(State.modified, merge(.untracked, .modified));
    try std.testing.expectEqual(State.modified, merge(.modified, .untracked));
    try std.testing.expectEqual(State.untracked, merge(.ignored, .untracked));
    try std.testing.expectEqual(State.conflicted, merge(.deleted, .conflicted));
    try std.testing.expectEqual(State.ignored, merge(.none, .ignored));
}

test "ignored never propagates to a parent directory" {
    try std.testing.expectEqual(State.none, propagates(.ignored));
    try std.testing.expectEqual(State.untracked, propagates(.untracked));
    try std.testing.expectEqual(State.modified, propagates(.modified));
}

test "badges: letters for exact records, a neutral star for rollups" {
    try std.testing.expectEqual(@as(?Badge, null), badgeFor(.none, false));
    const m = badgeFor(.modified, false).?;
    try std.testing.expectEqualStrings("M", m.text());
    try std.testing.expectEqualStrings("warning", m.css);
    try std.testing.expect(!m.dim_name);

    const roll = badgeFor(.modified, true).?;
    try std.testing.expectEqualStrings("*", roll.text());
    try std.testing.expect(roll.rollup);
    try std.testing.expectEqualStrings("warning", roll.css);

    // Ignored is a faded name, never a chip, and never a rollup.
    const ig = badgeFor(.ignored, false).?;
    try std.testing.expect(ig.dim_name);
    try std.testing.expectEqual(@as(u8, 0), ig.code_len);
    try std.testing.expectEqual(@as(?Badge, null), badgeFor(.ignored, true));

    try std.testing.expectEqualStrings("error", badgeFor(.conflicted, false).?.css);
    try std.testing.expectEqualStrings("success", badgeFor(.untracked, false).?.css);
    try std.testing.expectEqualStrings("accent", badgeFor(.renamed, false).?.css);
}

test "badges print both porcelain columns when the daemon reported them" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.applyInput(.{ .path = "staged.txt", .x = 'M', .y = '.' });
    ov.applyInput(.{ .path = "dirty.txt", .x = '.', .y = 'M' });
    ov.applyInput(.{ .path = "both.txt", .x = 'M', .y = 'M' });
    ov.applyInput(.{ .path = "new.txt", .x = '?', .y = '?' });
    ov.applyInput(.{ .path = "clash.txt", .x = 'A', .y = 'A' });
    ov.applyInput(.{ .path = "moved.txt", .x = 'R', .y = '.', .orig = "old.txt" });

    const staged = ov.badge("staged.txt").?;
    try std.testing.expectEqualStrings("M.", staged.text());
    try std.testing.expect(staged.staged and !staged.unstaged);

    const dirty = ov.badge("dirty.txt").?;
    try std.testing.expectEqualStrings(".M", dirty.text());
    try std.testing.expect(!dirty.staged and dirty.unstaged);

    const both = ov.badge("both.txt").?;
    try std.testing.expectEqualStrings("MM", both.text());
    try std.testing.expect(both.staged and both.unstaged);

    try std.testing.expectEqualStrings("??", ov.badge("new.txt").?.text());
    // AA is a conflict pair, not a double add.
    try std.testing.expectEqualStrings("AA", ov.badge("clash.txt").?.text());
    try std.testing.expectEqual(State.conflicted, ov.get("clash.txt").?.state);
    try std.testing.expectEqualStrings("error", ov.badge("clash.txt").?.css);

    const moved = ov.get("moved.txt").?;
    try std.testing.expectEqual(State.renamed, moved.state);
    try std.testing.expectEqualStrings("old.txt", moved.orig);
    try std.testing.expectEqualStrings("R.", ov.badge("moved.txt").?.text());

    const split = ov.stagedSplit();
    try std.testing.expectEqual(@as(u32, 4), split.staged);
    try std.testing.expectEqual(@as(u32, 4), split.unstaged);
}

test "row descriptions name the side, the rename source and the submodule" {
    var buf: [160]u8 = undefined;
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.applyInput(.{ .path = "a/b.txt", .x = 'M', .y = 'M' });
    ov.applyInput(.{ .path = "moved.txt", .x = 'R', .y = 'M', .orig = "old.txt" });
    ov.applyInput(.{ .path = "conf.txt", .x = 'U', .y = 'D' });
    ov.applyInput(.{ .path = "vendor/lib", .x = '.', .y = 'M', .submodule = true });
    ov.applyInput(.{ .path = "build/x.o", .x = '!', .y = '!' });

    try std.testing.expectEqualStrings("staged modified, unstaged modified", ov.get("a/b.txt").?.describe(&buf));
    try std.testing.expectEqualStrings("contains changes", ov.get("a").?.describe(&buf));
    try std.testing.expectEqualStrings("staged renamed, unstaged modified (from old.txt)", ov.get("moved.txt").?.describe(&buf));
    try std.testing.expectEqualStrings("conflicted (UD)", ov.get("conf.txt").?.describe(&buf));
    try std.testing.expectEqualStrings("unstaged modified [submodule]", ov.get("vendor/lib").?.describe(&buf));
    try std.testing.expectEqualStrings("ignored by git", ov.get("build/x.o").?.describe(&buf));
    // A legacy collapsed record has no sides to name.
    ov.apply("legacy.txt", 'M');
    try std.testing.expectEqualStrings("modified", ov.get("legacy.txt").?.describe(&buf));
    try std.testing.expectEqualStrings("M", ov.badge("legacy.txt").?.text());
}

test "overlay folds records into ancestor rollups" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("src/ui/main.zig", 'M');
    ov.apply("README.md", '?');

    const exact = ov.get("src/ui/main.zig").?;
    try std.testing.expectEqual(State.modified, exact.state);
    try std.testing.expect(exact.exact);

    const mid = ov.get("src/ui").?;
    try std.testing.expectEqual(State.modified, mid.state);
    try std.testing.expect(!mid.exact);

    const top = ov.get("src").?;
    try std.testing.expectEqual(State.modified, top.state);
    try std.testing.expect(!top.exact);

    try std.testing.expectEqualStrings("*", ov.badge("src").?.text());
    try std.testing.expectEqualStrings("M", ov.badge("src/ui/main.zig").?.text());
    try std.testing.expectEqualStrings("?", ov.badge("README.md").?.text());
    try std.testing.expectEqual(@as(?Badge, null), ov.badge("nothing"));
}

test "overlay rollup keeps the strongest state and ignores ignored children" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("a/x", '?');
    ov.apply("a/y", 'M');
    ov.apply("b/build.o", '!');
    ov.apply("c/z", 'U');
    ov.apply("c/w", 'M');

    try std.testing.expectEqual(State.modified, ov.get("a").?.state);
    // The ignored child left no mark on its directory.
    try std.testing.expectEqual(@as(?Row, null), ov.get("b"));
    try std.testing.expectEqual(State.ignored, ov.get("b/build.o").?.state);
    try std.testing.expectEqual(State.conflicted, ov.get("c").?.state);
}

test "overlay tolerates git's collapsed directory form" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("newdir/", '?');
    try std.testing.expectEqual(State.untracked, ov.get("newdir").?.state);
    try std.testing.expect(ov.get("newdir").?.exact);
}

test "summary counts exact records only, ignored excluded" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("src/a.zig", 'M');
    ov.apply("src/b.zig", 'M');
    ov.apply("new.txt", '?');
    ov.apply("target/x.o", '!');
    ov.apply("gone.txt", 'D');

    try std.testing.expectEqual(@as(u32, 4), ov.changedCount());
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings(", 1 deleted, 2 modified, 1 untracked", ov.summary(&buf));

    var empty = Overlay.init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqualStrings("", empty.summary(&buf));

    var only_ignored = Overlay.init(std.testing.allocator);
    defer only_ignored.deinit();
    only_ignored.apply("build/x", '!');
    try std.testing.expectEqual(@as(u32, 0), only_ignored.changedCount());
    try std.testing.expectEqualStrings("", only_ignored.summary(&buf));
}

test "overlay clear frees keys and resets counts" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("a/b/c", 'M');
    try std.testing.expect(!ov.isEmpty());
    ov.clear();
    try std.testing.expect(ov.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), ov.changedCount());
}

test "refresh cache is per host+path and expires" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    try std.testing.expect(!cache.fresh("", "/repo", 1000));
    cache.note("", "/repo", 1000);
    try std.testing.expect(cache.fresh("", "/repo", 1000));
    try std.testing.expect(cache.fresh("", "/repo", 30_000));
    // Same path on another host is a different repository.
    try std.testing.expect(!cache.fresh("box", "/repo", 1000));
    // Past the TTL it is gone.
    try std.testing.expect(!cache.fresh("", "/repo", 40_000));
    cache.note("", "/repo", 40_000);
    try std.testing.expect(cache.fresh("", "/repo", 40_000));
    cache.invalidate("", "/repo");
    try std.testing.expect(!cache.fresh("", "/repo", 40_000));
}

test "refresh cache evicts without leaking" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var i: usize = 0;
    while (i < Cache.CAPACITY * 3) : (i += 1) {
        var buf: [32]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "/repo/{d}", .{i});
        cache.note("", p, 1);
    }
    // The most recent one survived; the oldest did not.
    try std.testing.expect(cache.fresh("", "/repo/47", 1));
    try std.testing.expect(!cache.fresh("", "/repo/0", 1));
}

// ── porcelain v2 scanner ─────────────────────────────────────────

/// Build a NUL-separated porcelain-v2 buffer from its records.
fn z(comptime parts: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (parts) |p| out = out ++ p ++ "\x00";
    return out;
}

const OID = "35ff7e7e16f6d465d1b522c2b6756ebdaca6b634";
const H1 = "78981922613b2afb6025042ff6bd878ac1994e85";

test "scanner reads the branch header, including detached and no-upstream" {
    {
        var s = Scanner.init(z(.{
            "# branch.oid " ++ OID,
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +3 -1",
        }));
        try std.testing.expectEqual(@as(?Record, null), s.next());
        try std.testing.expect(s.header.is_repo);
        try std.testing.expect(!s.header.detached);
        try std.testing.expectEqualStrings("main", s.header.branch);
        try std.testing.expectEqualStrings("origin/main", s.header.upstream);
        try std.testing.expectEqualStrings(OID, s.header.oid);
        try std.testing.expect(s.header.have_ab);
        try std.testing.expectEqual(@as(i64, 3), s.header.ahead);
        try std.testing.expectEqual(@as(i64, 1), s.header.behind);
    }
    {
        // Detached HEAD: a commit, no branch, no upstream, no ab.
        var s = Scanner.init(z(.{ "# branch.oid " ++ OID, "# branch.head (detached)" }));
        try std.testing.expectEqual(@as(?Record, null), s.next());
        try std.testing.expect(s.header.is_repo);
        try std.testing.expect(s.header.detached);
        try std.testing.expectEqualStrings("", s.header.branch);
        try std.testing.expectEqualStrings("", s.header.upstream);
        try std.testing.expect(!s.header.have_ab);
    }
    {
        // A repository with no commit yet.
        var s = Scanner.init(z(.{ "# branch.oid (initial)", "# branch.head main" }));
        try std.testing.expectEqual(@as(?Record, null), s.next());
        try std.testing.expect(s.header.is_repo and s.header.initial);
        try std.testing.expectEqualStrings("", s.header.oid);
    }
    {
        // Not a repository: git printed nothing.
        var s = Scanner.init("");
        try std.testing.expectEqual(@as(?Record, null), s.next());
        try std.testing.expect(!s.header.is_repo);
    }
}

test "scanner reads every record type" {
    var s = Scanner.init(z(.{
        "# branch.oid " ++ OID,
        "# branch.head main",
        "1 .M N... 100644 100644 100644 " ++ H1 ++ " " ++ H1 ++ " sub/b.txt",
        "1 A. N... 000000 100644 100644 0000000 " ++ H1 ++ " added.txt",
        "1 .M S.M. 160000 160000 160000 " ++ H1 ++ " " ++ H1 ++ " vendor/mod",
        "u UU N... 100644 100644 100644 100644 " ++ H1 ++ " " ++ H1 ++ " " ++ H1 ++ " conflict.txt",
        "? new file.txt",
        "! build/",
    }));

    const ord = s.next().?;
    try std.testing.expectEqual(Kind.ordinary, ord.kind);
    try std.testing.expectEqual(@as(u8, '.'), ord.x);
    try std.testing.expectEqual(@as(u8, 'M'), ord.y);
    try std.testing.expectEqualStrings("sub/b.txt", ord.path);
    try std.testing.expect(!ord.submodule);
    try std.testing.expectEqual(@as(u8, 'M'), ord.legacyChar());

    const add = s.next().?;
    try std.testing.expectEqual(@as(u8, 'A'), add.x);
    try std.testing.expectEqualStrings("added.txt", add.path);
    try std.testing.expectEqual(@as(u8, 'A'), add.legacyChar());

    const sub = s.next().?;
    try std.testing.expect(sub.submodule);
    try std.testing.expectEqualStrings("vendor/mod", sub.path);

    const un = s.next().?;
    try std.testing.expectEqual(Kind.unmerged, un.kind);
    try std.testing.expectEqual(@as(u8, 'U'), un.x);
    try std.testing.expectEqual(@as(u8, 'U'), un.y);
    try std.testing.expectEqualStrings("conflict.txt", un.path);

    const unt = s.next().?;
    try std.testing.expectEqual(Kind.untracked, unt.kind);
    // A space in an untracked path is not a field separator.
    try std.testing.expectEqualStrings("new file.txt", unt.path);
    try std.testing.expectEqual(@as(u8, '?'), unt.legacyChar());

    const ign = s.next().?;
    try std.testing.expectEqual(Kind.ignored, ign.kind);
    try std.testing.expectEqualStrings("build/", ign.path);
    try std.testing.expectEqual(@as(u8, '!'), ign.legacyChar());

    try std.testing.expectEqual(@as(?Record, null), s.next());
    try std.testing.expectEqualStrings("main", s.header.branch);
}

test "scanner reads renames, including quoted, spaced and non-UTF-8 paths" {
    // -z means paths are NEVER quoted, so a double quote and a space
    // are literal bytes and a non-UTF-8 name passes through as-is.
    const weird_new = "dir with space/say \"hi\".txt";
    const weird_old = "old \xff\xfe name.txt";
    var s = Scanner.init(z(.{
        "2 R. N... 100644 100644 100644 " ++ H1 ++ " " ++ H1 ++ " R100 " ++ weird_new,
        weird_old,
        "2 CM N... 100644 100644 100644 " ++ H1 ++ " " ++ H1 ++ " C75 copy.txt",
        "src/orig.txt",
        "1 .M N... 100644 100644 100644 " ++ H1 ++ " " ++ H1 ++ " after.txt",
    }));

    const ren = s.next().?;
    try std.testing.expectEqual(Kind.rename, ren.kind);
    try std.testing.expectEqual(@as(u8, 'R'), ren.x);
    try std.testing.expectEqual(@as(u8, '.'), ren.y);
    try std.testing.expectEqualStrings(weird_new, ren.path);
    try std.testing.expectEqualStrings(weird_old, ren.orig);
    try std.testing.expectEqualStrings("R100", ren.score);
    try std.testing.expectEqual(@as(u8, 'R'), ren.legacyChar());

    const cp = s.next().?;
    try std.testing.expectEqualStrings("copy.txt", cp.path);
    try std.testing.expectEqualStrings("src/orig.txt", cp.orig);
    try std.testing.expectEqualStrings("C75", cp.score);

    // The record after a rename resumes on the right field boundary.
    try std.testing.expectEqualStrings("after.txt", s.next().?.path);
    try std.testing.expectEqual(@as(?Record, null), s.next());
}

test "scanner survives malformed input" {
    const junk = comptime z(.{
        "",
        "#",
        "# branch.ab nonsense",
        "# branch.unknown whatever",
        "1",
        "1 M",
        // Too few fields for a path.
        "1 .M N... 100644 100644",
        "x weird line",
        "? ",
        "1 .M N... 100644 100644 100644 h h ok.txt",
    });
    // ...plus a record with no trailing NUL.
    var s = Scanner.init(junk ++ "1 .M N... 100644 100644 100644 h h trunc");
    try std.testing.expectEqualStrings("ok.txt", s.next().?.path);
    // The unterminated tail is still a complete-looking record; the
    // daemon trims to the last NUL before scanning, which is the
    // truncation rule the caller owns.
    try std.testing.expectEqualStrings("trunc", s.next().?.path);
    try std.testing.expectEqual(@as(?Record, null), s.next());
    // A malformed ab header leaves the counters untouched.
    try std.testing.expect(!s.header.have_ab);

    // A rename whose source field is missing entirely.
    var t = Scanner.init("2 R. N... 1 2 3 h h R100 only.txt\x00");
    const r = t.next().?;
    try std.testing.expectEqualStrings("only.txt", r.path);
    try std.testing.expectEqualStrings("", r.orig);
    try std.testing.expectEqual(@as(?Record, null), t.next());
}

test "unmerged pairs are exactly git's seven" {
    for ([_][2]u8{ .{ 'D', 'D' }, .{ 'A', 'U' }, .{ 'U', 'D' }, .{ 'U', 'A' }, .{ 'D', 'U' }, .{ 'A', 'A' }, .{ 'U', 'U' } }) |p|
        try std.testing.expect(isUnmergedPair(p[0], p[1]));
    for ([_][2]u8{ .{ 'M', 'M' }, .{ 'A', 'D' }, .{ 'A', '.' }, .{ 'R', 'M' }, .{ '?', '?' } }) |p|
        try std.testing.expect(!isUnmergedPair(p[0], p[1]));
}

test "status note distinguishes an old daemon, a non-repo and a clean repo" {
    var buf: [200]u8 = undefined;
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    var repo = Repo.init(std.testing.allocator);
    defer repo.deinit();

    // Old daemon: no repo answer at all, so the pre-branch phrase.
    try std.testing.expectEqualStrings("", statusNote(&repo, &ov, &buf));
    ov.applyInput(.{ .path = "a.txt", .x = '.', .y = 'M' });
    try std.testing.expectEqualStrings(", 1 modified", statusNote(&repo, &ov, &buf));

    // A real "not a repository" says nothing at all.
    repo.set(.{ .is_repo = false });
    try std.testing.expectEqualStrings("", statusNote(&repo, &ov, &buf));

    repo.set(.{ .is_repo = true, .at_root = true, .branch = "main" });
    try std.testing.expectEqualStrings(", on main, 1 modified", statusNote(&repo, &ov, &buf));

    // A clean repository is now visible, which it never used to be.
    ov.clear();
    try std.testing.expectEqualStrings(", on main, clean", statusNote(&repo, &ov, &buf));
    repo.set(.{ .is_repo = true, .at_root = false, .branch = "main" });
    try std.testing.expectEqualStrings(", on main, no changes here", statusNote(&repo, &ov, &buf));

    repo.set(.{ .is_repo = true, .at_root = true, .branch = "main", .upstream = "origin/main", .ahead = 2, .behind = 3, .have_ab = true });
    try std.testing.expectEqualStrings(", on main +2 -3, clean", statusNote(&repo, &ov, &buf));

    repo.set(.{ .is_repo = true, .at_root = true, .detached = true, .oid = "abc1234" });
    try std.testing.expectEqualStrings(", detached at abc1234, clean", statusNote(&repo, &ov, &buf));

    repo.set(.{ .is_repo = true, .at_root = true, .initial = true, .branch = "main" });
    try std.testing.expectEqualStrings(", on main (no commits yet), clean", statusNote(&repo, &ov, &buf));

    repo.set(.{ .is_repo = true, .at_root = true, .branch = "main", .truncated = true });
    try std.testing.expectEqualStrings(", on main, clean, partial", statusNote(&repo, &ov, &buf));
}

test "a scanned tree folds into the overlay the browser renders" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    var s = Scanner.init(z(.{
        "# branch.oid " ++ OID,
        "# branch.head main",
        "2 R. N... 100644 100644 100644 " ++ H1 ++ " " ++ H1 ++ " R100 src/new.zig",
        "src/old.zig",
        "1 MM N... 100644 100644 100644 " ++ H1 ++ " " ++ H1 ++ " src/edit.zig",
        "! zig-out/",
        "? notes.md",
    }));
    while (s.next()) |rec| {
        ov.applyInput(.{
            .path = rec.path,
            .x = rec.x,
            .y = rec.y,
            .legacy = rec.legacyChar(),
            .orig = rec.orig,
            .submodule = rec.submodule,
        });
    }
    try std.testing.expectEqualStrings("R.", ov.badge("src/new.zig").?.text());
    try std.testing.expectEqualStrings("src/old.zig", ov.get("src/new.zig").?.orig);
    try std.testing.expectEqualStrings("MM", ov.badge("src/edit.zig").?.text());
    // The rename outranks the modification on the parent rollup.
    try std.testing.expectEqual(State.renamed, ov.get("src").?.state);
    try std.testing.expectEqualStrings("*", ov.badge("src").?.text());
    // The ignored build tree fades its own row and marks nothing else.
    try std.testing.expect(ov.badge("zig-out").?.dim_name);
    try std.testing.expectEqualStrings("??", ov.badge("notes.md").?.text());

    var buf: [200]u8 = undefined;
    try std.testing.expectEqualStrings(", 1 renamed, 1 modified, 1 untracked", ov.summary(&buf));
}

test "relativeKey resolves rows in the root and in expanded subdirs" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("a.txt", relativeKey("/repo", "/repo", "a.txt", &buf).?);
    try std.testing.expectEqualStrings("src/a.txt", relativeKey("/repo", "/repo/src", "a.txt", &buf).?);
    try std.testing.expectEqualStrings("x/y/a.txt", relativeKey("/repo", "/repo/x/y", "a.txt", &buf).?);
    // Root "/" is not doubled.
    try std.testing.expectEqualStrings("etc/hosts", relativeKey("/", "/etc", "hosts", &buf).?);
    try std.testing.expectEqualStrings("hosts", relativeKey("/", "/", "hosts", &buf).?);
    // Outside the root: no answer rather than a wrong one.
    try std.testing.expectEqual(@as(?[]const u8, null), relativeKey("/repo", "/other", "a.txt", &buf));
    try std.testing.expectEqual(@as(?[]const u8, null), relativeKey("/repo/src", "/repo", "a.txt", &buf));
}
