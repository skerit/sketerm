//! Use-after-free DETECTOR for the panel subsystem's heap signal
//! contexts. Not a lifetime mechanism — the three mechanisms are in
//! the root CLAUDE.md and exactly one of them still has to be right
//! for every allocation. What this adds is that a future mistake in
//! that choice surfaces as a deterministic bail plus a stderr line at
//! the FIRST stale callback, instead of as random memory corruption
//! diagnosed hours later from a core dump.
//!
//! A context carries `magic: u32` initialised to its type's `MAGIC`,
//! and every free path calls `poison` BEFORE releasing the memory.
//! Callbacks resolve their user-data through `live`, which returns
//! null when the word does not match; the callback then returns
//! without touching anything.
//!
//! Limits, so this is not mistaken for a fix: the check only sees the
//! freed allocation while its pages are still mapped and the magic
//! word is still intact. A reused-and-overwritten block reads as
//! garbage (caught), but a block re-handed to a NEW context of the
//! same type reads as live (not caught). It narrows the failure
//! window; it does not close it.
//!
//! Cost: one load and one compare against a constant, on paths that
//! run a handful of times per user interaction (a click, a drag tick,
//! a draw). It is not measurable and must not be "optimised" away —
//! `std.debug.assert` is NOT an option here because this project
//! builds ReleaseFast only (Debug fails to link on Arch + gcc 15),
//! where assertions compile to nothing. The branch is explicit on
//! purpose.

const std = @import("std");

/// Written over a context's magic word at free time. Deliberately not
/// a plausible pointer, length or ASCII run.
pub const DEAD: u32 = 0xDEADFACE;

/// True only while a test is DELIBERATELY poisoning a context to
/// prove the guard fires. It suppresses the stderr line alone —
/// `trips` still counts and the tests assert on it — so a green
/// `zig build test` run prints zero "canary tripped" lines. Before
/// this flag, the ten expected test trips were indistinguishable
/// from a live use-after-free and got investigated as one
/// (2026-08-20). Production code must never set it.
pub var expected_by_test: bool = false;

/// How many stale contexts have been caught this process. Bumped only
/// from the GTK main thread (every guarded callback is a GTK
/// callback), so a plain global is enough; tests read it to prove the
/// guard fired.
pub var trips: u32 = 0;

/// Resolve a callback's user-data, or null when it is not a live `T`.
/// `T` must declare `pub const MAGIC: u32` and carry `magic: u32`.
pub fn live(comptime T: type, user: ?*anyopaque) ?*T {
    const p: *T = @ptrCast(@alignCast(user orelse return null));
    if (p.magic != T.MAGIC) {
        trip(@typeName(T), p.magic);
        return null;
    }
    return p;
}

/// Same check for a context reached through a typed pointer rather
/// than a callback's `?*anyopaque`.
pub fn alive(p: anytype) bool {
    const T = @typeInfo(@TypeOf(p)).pointer.child;
    if (p.magic != T.MAGIC) {
        trip(@typeName(T), p.magic);
        return false;
    }
    return true;
}

/// Call immediately before the allocator releases `p`. A free path
/// that is itself guarded will then BAIL on a second call — leaking
/// the block rather than double-freeing it, which is the trade this
/// whole module is making.
pub fn poison(p: anytype) void {
    p.magic = DEAD;
}

fn trip(name: []const u8, got: u32) void {
    trips +%= 1;
    if (expected_by_test) return;
    std.debug.print(
        "sketerm: panel canary tripped: stale {s} context (magic 0x{X:0>8}) — callback bailed. " ++
            "Its owner freed it while a widget still had it as signal user-data.\n",
        .{ name, got },
    );
}

// ─── tests ──────────────────────────────────────────────────────

const Probe = struct {
    pub const MAGIC: u32 = 0x50524F42; // "PROB"
    magic: u32 = MAGIC,
    hits: u32 = 0,
};

test "live() accepts a live context and rejects a poisoned one" {
    expected_by_test = true;
    defer expected_by_test = false;
    var p = Probe{};
    const before = trips;
    try std.testing.expect(live(Probe, @ptrCast(&p)) == &p);
    try std.testing.expectEqual(before, trips);

    poison(&p);
    try std.testing.expect(live(Probe, @ptrCast(&p)) == null);
    try std.testing.expectEqual(before + 1, trips);
    try std.testing.expectEqual(DEAD, p.magic);
}

test "live() rejects null user-data without counting a trip" {
    const before = trips;
    try std.testing.expect(live(Probe, null) == null);
    try std.testing.expectEqual(before, trips);
}

test "alive() mirrors live() for typed pointers" {
    expected_by_test = true;
    defer expected_by_test = false;
    var p = Probe{};
    try std.testing.expect(alive(&p));
    poison(&p);
    try std.testing.expect(!alive(&p));
}

test "a garbage magic word is caught too" {
    expected_by_test = true;
    defer expected_by_test = false;
    // The realistic case: the block was reused and overwritten by
    // something unrelated, so it is neither MAGIC nor DEAD.
    var p = Probe{};
    p.magic = 0x0000_0001;
    const before = trips;
    try std.testing.expect(live(Probe, @ptrCast(&p)) == null);
    try std.testing.expectEqual(before + 1, trips);
}
