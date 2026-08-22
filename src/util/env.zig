//! The tree's environment-variable reader.
//!
//! Zig 0.16 removed `std.posix.getenv`; we link libc everywhere, so
//! this is a thin `getenv(3)` wrapper. Two readings exist because
//! callers disagree about what an EMPTY variable means: `get` reports
//! it as a set-but-empty value, `nonEmpty` folds it into "unset",
//! which is what every path that treats a variable as a socket path,
//! directory or asset root wants.

const std = @import("std");
const c = @import("../c.zig").c;

/// @return null only when the variable is unset; an empty variable
/// comes back as an empty slice.
pub fn get(name: [*:0]const u8) ?[]const u8 {
    const raw = c.getenv(name);
    if (raw == null) return null;
    return std.mem.span(raw);
}

/// `get` with an empty value folded into null.
pub fn nonEmpty(name: [*:0]const u8) ?[]const u8 {
    const v = get(name) orelse return null;
    return if (v.len == 0) null else v;
}

test "get and nonEmpty disagree only on an empty variable" {
    const t = std.testing;
    _ = c.setenv("SKETERM_TEST_ENV_SET", "value", 1);
    _ = c.setenv("SKETERM_TEST_ENV_EMPTY", "", 1);
    _ = c.unsetenv("SKETERM_TEST_ENV_MISSING");

    try t.expectEqualStrings("value", get("SKETERM_TEST_ENV_SET").?);
    try t.expectEqualStrings("value", nonEmpty("SKETERM_TEST_ENV_SET").?);

    try t.expectEqual(@as(usize, 0), get("SKETERM_TEST_ENV_EMPTY").?.len);
    try t.expectEqual(@as(?[]const u8, null), nonEmpty("SKETERM_TEST_ENV_EMPTY"));

    try t.expectEqual(@as(?[]const u8, null), get("SKETERM_TEST_ENV_MISSING"));
    try t.expectEqual(@as(?[]const u8, null), nonEmpty("SKETERM_TEST_ENV_MISSING"));

    _ = c.unsetenv("SKETERM_TEST_ENV_SET");
    _ = c.unsetenv("SKETERM_TEST_ENV_EMPTY");
}
