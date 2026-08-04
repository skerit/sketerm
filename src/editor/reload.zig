//! External-modification detection + position-preserving reload maths.
//!
//! GTK-free and dependency-free on purpose: the editor face polls the
//! daemon for a file's stat identity and feeds the result here, and the
//! same predicate runs in unit tests and in the fs smoke.
//!
//! The identity is (present, mtime, size, ino, mode). `ino` is what
//! catches the common atomic writer (write temp + rename): the mtime of
//! the NEW inode can legitimately be older than the baseline, so an
//! mtime-only comparison misses it and a "newer than" comparison is
//! wrong in both directions.

const std = @import("std");
const SelectionSet = @import("selection.zig").SelectionSet;

/// One observation of a path on disk. `mtime_ns` is 0 on daemons/
/// filesystems that cannot report nanoseconds — `mtime_ms` is then the
/// only usable clock, so both are kept.
pub const DiskState = struct {
    /// False until an observation was actually recorded — the "we have
    /// no baseline" state, which is NOT the same as "known missing".
    known: bool = false,
    present: bool = false,
    mtime_ns: i64 = 0,
    mtime_ms: i64 = 0,
    size: u64 = 0,
    ino: u64 = 0,
    mode: u32 = 0,

    /// No baseline recorded yet (a never-loaded or Untitled buffer).
    pub fn isUnknown(self: DiskState) bool {
        return !self.known;
    }

    /// The file is known to be gone (a recorded absence).
    pub fn isMissing(self: DiskState) bool {
        return self.known and !self.present;
    }
};

pub const Verdict = enum {
    /// Same bytes, same identity, same permissions.
    unchanged,
    /// Content changed in place (same inode, new mtime/size).
    modified,
    /// A different file now sits at this path (new inode) — the
    /// temp-file+rename that every atomic writer performs.
    replaced,
    /// Content identical, permission bits differ.
    permissions,
    /// The path is gone (deleted, or renamed out from under us).
    deleted,
    /// It came back after having been observed missing.
    reappeared,
};

/// Compare a fresh observation against the baseline recorded at the
/// last load/save. A baseline that was never recorded answers
/// `unchanged`: nothing is known to have changed.
pub fn compare(base: DiskState, obs: DiskState) Verdict {
    if (base.isUnknown()) return .unchanged;
    if (!obs.present) return if (base.present) .deleted else .unchanged;
    if (!base.present) return .reappeared;
    if (base.ino != 0 and obs.ino != 0 and base.ino != obs.ino) return .replaced;
    if (obs.size != base.size) return .modified;
    if (base.mtime_ns != 0 and obs.mtime_ns != 0) {
        if (obs.mtime_ns != base.mtime_ns) return .modified;
    } else if (obs.mtime_ms != base.mtime_ms) return .modified;
    if (obs.mode != base.mode) return .permissions;
    return .unchanged;
}

/// True when the two observations describe the same file in the same
/// state — used to keep a dismissed banner dismissed until the file
/// changes AGAIN.
pub fn sameState(a: DiskState, b: DiskState) bool {
    return a.known == b.known and a.present == b.present and a.ino == b.ino and a.size == b.size and
        a.mtime_ns == b.mtime_ns and a.mtime_ms == b.mtime_ms and a.mode == b.mode;
}

/// Whether a verdict is one the user must be told about (as opposed to
/// silently re-baselined).
pub fn needsAttention(v: Verdict) bool {
    return switch (v) {
        .unchanged, .permissions => false,
        .modified, .replaced, .deleted, .reappeared => true,
    };
}

// ---- position preservation across a reload ---------------------------

pub fn clampOffset(offset: usize, new_len: usize) usize {
    return @min(offset, new_len);
}

pub fn clampLine(line: usize, new_line_count: usize) usize {
    if (new_line_count == 0) return 0;
    return @min(line, new_line_count - 1);
}

/// Clamp every selection to a (possibly shorter) document and merge
/// whatever collapsed onto the same offset. The reload path's
/// "preserve the cursor as closely as possible" rule.
pub fn clampSet(sels: *SelectionSet, new_len: usize) void {
    for (sels.sels.items) |*s| {
        s.anchor = clampOffset(s.anchor, new_len);
        s.head = clampOffset(s.head, new_len);
    }
    sels.normalize();
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

const base_state: DiskState = .{
    .known = true,
    .present = true,
    .mtime_ns = 1_000,
    .mtime_ms = 1,
    .size = 10,
    .ino = 42,
    .mode = 0o644,
};

test "reload compare: unchanged, modified, permissions" {
    try testing.expectEqual(Verdict.unchanged, compare(base_state, base_state));

    var obs = base_state;
    obs.mtime_ns = 2_000;
    try testing.expectEqual(Verdict.modified, compare(base_state, obs));

    obs = base_state;
    obs.size = 11;
    try testing.expectEqual(Verdict.modified, compare(base_state, obs));

    obs = base_state;
    obs.mode = 0o600;
    try testing.expectEqual(Verdict.permissions, compare(base_state, obs));
}

test "reload compare: a new inode is detected even with an OLDER mtime" {
    // The atomic-writer case: temp file created earlier, then renamed
    // over ours. Same size, same permissions, mtime goes BACKWARDS.
    var obs = base_state;
    obs.ino = 43;
    obs.mtime_ns = 500;
    try testing.expectEqual(Verdict.replaced, compare(base_state, obs));

    // Same content, same mtime, different inode (hard-link swap).
    obs = base_state;
    obs.ino = 44;
    try testing.expectEqual(Verdict.replaced, compare(base_state, obs));
}

test "reload compare: deletion, reappearance and no-baseline" {
    const gone: DiskState = .{ .known = true, .present = false };
    try testing.expectEqual(Verdict.deleted, compare(base_state, gone));
    try testing.expectEqual(Verdict.reappeared, compare(gone, base_state));
    // A never-recorded baseline never accuses anyone.
    try testing.expectEqual(Verdict.unchanged, compare(.{}, base_state));
    // Still missing: not news.
    try testing.expectEqual(Verdict.unchanged, compare(gone, gone));
}

test "reload compare falls back to millisecond mtimes" {
    var no_ns = base_state;
    no_ns.mtime_ns = 0;
    var obs = no_ns;
    obs.mtime_ms = 2;
    try testing.expectEqual(Verdict.modified, compare(no_ns, obs));
    try testing.expectEqual(Verdict.unchanged, compare(no_ns, no_ns));
}

test "reload sameState and needsAttention" {
    var other = base_state;
    other.mtime_ns = 3;
    try testing.expect(sameState(base_state, base_state));
    try testing.expect(!sameState(base_state, other));
    try testing.expect(needsAttention(.modified));
    try testing.expect(needsAttention(.replaced));
    try testing.expect(needsAttention(.deleted));
    try testing.expect(!needsAttention(.unchanged));
    try testing.expect(!needsAttention(.permissions));
}

test "reload clamping keeps positions inside the new document" {
    try testing.expectEqual(@as(usize, 5), clampOffset(5, 10));
    try testing.expectEqual(@as(usize, 10), clampOffset(50, 10));
    try testing.expectEqual(@as(usize, 0), clampOffset(3, 0));
    try testing.expectEqual(@as(usize, 4), clampLine(9, 5));
    try testing.expectEqual(@as(usize, 2), clampLine(2, 5));
    try testing.expectEqual(@as(usize, 0), clampLine(7, 0));
}

test "reload clampSet clamps and merges collapsed selections" {
    const Selection = @import("selection.zig").Selection;
    var set = SelectionSet.init();
    defer set.deinit(testing.allocator);
    try set.sels.append(testing.allocator, .{ .anchor = 2, .head = 6 });
    try set.sels.append(testing.allocator, .{ .anchor = 30, .head = 40 });
    try set.sels.append(testing.allocator, Selection.caret(35));
    set.primary_index = 1;

    clampSet(&set, 8);
    // The two tail selections both collapse onto offset 8 and merge.
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expectEqual(@as(usize, 2), set.sels.items[0].anchor);
    try testing.expectEqual(@as(usize, 6), set.sels.items[0].head);
    try testing.expect(set.sels.items[1].isCaret());
    try testing.expectEqual(@as(usize, 8), set.sels.items[1].head);
}
