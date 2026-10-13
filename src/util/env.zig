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

/// One environment variable saved, cleared and put back, without an
/// allocator (a test helper must not perturb `std.testing.allocator`'s
/// leak accounting). A value longer than the buffer is refused rather
/// than truncated: silently restoring a different value is worse than
/// failing the test that clobbered it.
pub const Saved = struct {
    name: [*:0]const u8 = "",
    buf: [4096]u8 = undefined,
    had: bool = false,

    /// @throws error.EnvValueTooLong leaving the variable untouched and `restore` a no-op.
    pub fn take(self: *Saved, name: [*:0]const u8) !void {
        self.* = .{};
        if (get(name)) |value| {
            if (value.len >= self.buf.len) return error.EnvValueTooLong;
            @memcpy(self.buf[0..value.len], value);
            self.buf[value.len] = 0;
            self.had = true;
        }
        self.name = name;
        _ = c.unsetenv(name);
    }

    /// `take`, then set the variable to `value`.
    pub fn override(self: *Saved, name: [*:0]const u8, value: [*:0]const u8) !void {
        try self.take(name);
        _ = c.setenv(name, value, 1);
    }

    pub fn restore(self: *Saved) void {
        if (self.name[0] == 0) return;
        if (self.had) {
            _ = c.setenv(self.name, @ptrCast(&self.buf), 1);
        } else {
            _ = c.unsetenv(self.name);
        }
    }
};

/// `Saved` for a fixed group of variables, taken together and restored
/// in reverse order.
pub fn SavedSet(comptime names: []const [*:0]const u8) type {
    return struct {
        slots: [names.len]Saved = @splat(.{}),

        /// @throws error.EnvValueTooLong having put back the ones already taken.
        pub fn take(self: *@This()) !void {
            errdefer self.restore();
            for (&self.slots, names) |*slot, name| try slot.take(name);
        }

        pub fn restore(self: *@This()) void {
            var i = self.slots.len;
            while (i > 0) {
                i -= 1;
                self.slots[i].restore();
            }
        }
    };
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

test "Saved puts back a set variable and unsets one that was unset" {
    const t = std.testing;
    _ = c.setenv("SKETERM_TEST_ENV_SAVED", "before", 1);
    _ = c.unsetenv("SKETERM_TEST_ENV_SAVED_NONE");
    var a: Saved = .{};
    try a.override("SKETERM_TEST_ENV_SAVED", "during");
    var b: Saved = .{};
    try b.override("SKETERM_TEST_ENV_SAVED_NONE", "during");
    try t.expectEqualStrings("during", get("SKETERM_TEST_ENV_SAVED").?);
    b.restore();
    a.restore();
    try t.expectEqualStrings("before", get("SKETERM_TEST_ENV_SAVED").?);
    try t.expectEqual(@as(?[]const u8, null), get("SKETERM_TEST_ENV_SAVED_NONE"));
    _ = c.unsetenv("SKETERM_TEST_ENV_SAVED");
}

test "a refused take leaves the variable alone and makes restore a no-op" {
    const t = std.testing;
    const long = "v" ** 5000;
    _ = c.setenv("SKETERM_TEST_ENV_LONG", long, 1);
    defer _ = c.unsetenv("SKETERM_TEST_ENV_LONG");
    var s: Saved = .{};
    try t.expectError(error.EnvValueTooLong, s.take("SKETERM_TEST_ENV_LONG"));
    s.restore();
    try t.expectEqualStrings(long, get("SKETERM_TEST_ENV_LONG").?);
}

test "SavedSet puts back every variable, and a refused take undoes the earlier ones" {
    const t = std.testing;
    _ = c.setenv("SKETERM_TEST_ENV_SET_A", "a", 1);
    _ = c.unsetenv("SKETERM_TEST_ENV_SET_B");
    _ = c.setenv("SKETERM_TEST_ENV_SET_LONG", "v" ** 5000, 1);
    defer _ = c.unsetenv("SKETERM_TEST_ENV_SET_A");
    defer _ = c.unsetenv("SKETERM_TEST_ENV_SET_LONG");

    var ok: SavedSet(&.{ "SKETERM_TEST_ENV_SET_A", "SKETERM_TEST_ENV_SET_B" }) = .{};
    try ok.take();
    try t.expectEqual(@as(?[]const u8, null), get("SKETERM_TEST_ENV_SET_A"));
    _ = c.setenv("SKETERM_TEST_ENV_SET_B", "during", 1);
    ok.restore();
    try t.expectEqualStrings("a", get("SKETERM_TEST_ENV_SET_A").?);
    try t.expectEqual(@as(?[]const u8, null), get("SKETERM_TEST_ENV_SET_B"));

    var refused: SavedSet(&.{ "SKETERM_TEST_ENV_SET_A", "SKETERM_TEST_ENV_SET_LONG" }) = .{};
    try t.expectError(error.EnvValueTooLong, refused.take());
    try t.expectEqualStrings("a", get("SKETERM_TEST_ENV_SET_A").?);
    try t.expectEqual(@as(usize, 5000), get("SKETERM_TEST_ENV_SET_LONG").?.len);
}
