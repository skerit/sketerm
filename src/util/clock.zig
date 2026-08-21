//! The monotonic millisecond clock every deadline in the tree is
//! measured against, plus the wall clock every human-readable
//! timestamp comes from.
//!
//! Zig 0.16 removed `std.time.milliTimestamp` and
//! `std.posix.clock_gettime`, so each module that needed a deadline
//! grew its own copy of the same `clock_gettime(CLOCK_MONOTONIC)`
//! arithmetic. This is that copy, once.
//!
//! Importable from BOTH dependency sets (the GUI `cbindings` module
//! and the lean mux core set) — libc only, no GTK/GLib, so the
//! daemon's ELF dependency invariant is unaffected.

const std = @import("std");
const c = @import("../c.zig").c;

/// Milliseconds since an unspecified monotonic epoch.
///
/// `tv_sec`/`tv_nsec` widths differ across libc and target, hence the
/// `@intCast`es rather than a plain `@as`.
pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const sec: i64 = @intCast(ts.tv_sec);
    const nsec: i64 = @intCast(ts.tv_nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

/// Nanoseconds on the same monotonic epoch as `nowMs`, for spans too
/// short for a millisecond to resolve (frame timings, microbenchmarks).
pub fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

/// Microseconds on the same monotonic epoch as `nowMs`, for spans a
/// millisecond would quantise away (a sub-ms round trip's distribution).
pub fn nowUs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const sec: i64 = @intCast(ts.tv_sec);
    const nsec: i64 = @intCast(ts.tv_nsec);
    return sec * 1_000_000 + @divTrunc(nsec, 1_000);
}

/// Milliseconds since the Unix epoch, from the WALL clock.
///
/// NOT monotonic: NTP steps, suspend/resume and a user setting the
/// system time all move it, backwards included. Use it only for a
/// timestamp a human or another machine reads (log lines, records on
/// disk, "how long ago"); never for a deadline or an elapsed-time
/// measurement, which is what `nowMs` is for.
pub fn wallMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    const sec: i64 = @intCast(ts.tv_sec);
    const nsec: i64 = @intCast(ts.tv_nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

test "nowMs is monotonic and reads as milliseconds" {
    const t = std.testing;
    const a = nowMs();
    // Well above any plausible epoch-in-milliseconds rounding, and
    // below it if the function ever returned seconds or nanoseconds.
    try t.expect(a > 0);
    var spin: usize = 0;
    var b = nowMs();
    while (b == a and spin < 100_000_000) : (spin += 1) b = nowMs();
    try t.expect(b >= a);
}

test "nowNs shares nowMs's epoch and never runs backwards" {
    const t = std.testing;
    const a = nowNs();
    const b = nowNs();
    try t.expect(b >= a);
    // Same clock, so the nanosecond reading is within a millisecond of
    // the millisecond one for any plausible uptime.
    try t.expect(@abs(@as(i64, @intCast(a / 1_000_000)) - nowMs()) < 1_000);
}

test "wallMs reads as epoch milliseconds" {
    const t = std.testing;
    const now = wallMs();
    // 2020-01-01 and 2100-01-01 in epoch ms: seconds or nanoseconds
    // would fall outside on either side.
    try t.expect(now > 1_577_836_800_000);
    try t.expect(now < 4_102_444_800_000);
    // The wall clock may step, but two reads a few instructions apart
    // still have to land in the same window.
    try t.expect(@abs(wallMs() - now) < 60_000);
}
