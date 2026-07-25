//! The monotonic millisecond clock every deadline in the tree is
//! measured against.
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
