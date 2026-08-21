//! The one gate on user-facing diagnostics (config warnings, daemon
//! warnings, wlhost protocol errors, webengine storage failures).
//!
//! Unit tests deliberately feed malformed input to those parsers, so a
//! fully green suite still wrote dozens of warning lines to stderr. Zig
//! 0.16's build runner prints ANY step that produced stderr through
//! `printErrorMessages`, which ends with the step's
//! `result_failed_command` — so `zig build test-core` closed a passing
//! run with `failed command: .../test ...` while exiting 0. Silencing
//! the diagnostics at their source is the fix; suppressing the step's
//! stderr would hide real failures too.

const std = @import("std");
const builtin = @import("builtin");

/// False in test builds; the declaring home for that policy, so a
/// diagnostic sink that formats its own bytes can gate on it directly.
pub const enabled = !builtin.is_test;

/// Single-line diagnostic to stderr, dropped in test builds.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;
    std.debug.print(fmt, args);
}
