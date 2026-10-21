//! The tree's environment-variable reader.
//!
//! Zig 0.16 removed `std.posix.getenv`; we link libc everywhere, so
//! this is a thin `getenv(3)` wrapper. Two readings exist because
//! callers disagree about what an EMPTY variable means: `get` reports
//! it as a set-but-empty value, `nonEmpty` folds it into "unset",
//! which is what every path that treats a variable as a socket path,
//! directory or asset root wants.

const std = @import("std");
// `cbindings` directly, as pathz.zig does: modules rooted inside src/util
// (the atomicwrite test roots) cannot reach `../c.zig`.
const c = @import("cbindings");
const platform = @import("platform.zig");

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

/// `nonEmpty` for a name that is not NUL-terminated (null when it is too long).
pub fn nonEmptyName(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return null;
    return nonEmpty(z.ptr);
}

var detached: std.atomic.Value(bool) = .init(false);

/// Point libc's `environ` at a heap copy of its pointer array, once, so libc never edits the startup array again.
/// Zig's std scans a fixed-length view of the startup array lazily (first stderr print, each `std.testing` Io
/// rebuild), and `unsetenv` compacting it in place leaves a NULL inside that view which std dereferences.
/// The strings are shared, not copied; a thread that loses the compare-and-swap frees its copy.
pub fn detachEnviron() void {
    if (detached.load(.acquire)) return;
    const slot = platform.environSlot();
    const cur = @atomicLoad([*c][*c]u8, slot, .acquire);
    if (cur != null) {
        var n: usize = 0;
        while (cur[n] != null) n += 1;
        // Out of memory leaves the startup array in place; nothing better exists.
        const copy = std.heap.c_allocator.alloc([*c]u8, n + 1) catch return;
        @memcpy(copy, cur[0 .. n + 1]);
        if (@cmpxchgStrong([*c][*c]u8, slot, cur, copy.ptr, .acq_rel, .acquire) != null)
            std.heap.c_allocator.free(copy);
    }
    detached.store(true, .release);
}

/// `unsetenv(3)` that never edits the startup environment array (see `detachEnviron`); the only removal path in the tree.
/// @return false when libc refuses the name (empty, or containing '=').
pub fn unset(name: [*:0]const u8) bool {
    detachEnviron();
    return c.unsetenv(name) == 0;
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
        _ = unset(name);
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
            _ = unset(self.name);
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
    _ = unset("SKETERM_TEST_ENV_MISSING");

    try t.expectEqualStrings("value", get("SKETERM_TEST_ENV_SET").?);
    try t.expectEqualStrings("value", nonEmpty("SKETERM_TEST_ENV_SET").?);

    try t.expectEqual(@as(usize, 0), get("SKETERM_TEST_ENV_EMPTY").?.len);
    try t.expectEqual(@as(?[]const u8, null), nonEmpty("SKETERM_TEST_ENV_EMPTY"));

    try t.expectEqual(@as(?[]const u8, null), get("SKETERM_TEST_ENV_MISSING"));
    try t.expectEqual(@as(?[]const u8, null), nonEmpty("SKETERM_TEST_ENV_MISSING"));

    _ = unset("SKETERM_TEST_ENV_SET");
    _ = unset("SKETERM_TEST_ENV_EMPTY");
}

test "Saved puts back a set variable and unsets one that was unset" {
    const t = std.testing;
    _ = c.setenv("SKETERM_TEST_ENV_SAVED", "before", 1);
    _ = unset("SKETERM_TEST_ENV_SAVED_NONE");
    var a: Saved = .{};
    try a.override("SKETERM_TEST_ENV_SAVED", "during");
    var b: Saved = .{};
    try b.override("SKETERM_TEST_ENV_SAVED_NONE", "during");
    try t.expectEqualStrings("during", get("SKETERM_TEST_ENV_SAVED").?);
    b.restore();
    a.restore();
    try t.expectEqualStrings("before", get("SKETERM_TEST_ENV_SAVED").?);
    try t.expectEqual(@as(?[]const u8, null), get("SKETERM_TEST_ENV_SAVED_NONE"));
    _ = unset("SKETERM_TEST_ENV_SAVED");
}

test "a refused take leaves the variable alone and makes restore a no-op" {
    const t = std.testing;
    const long = &@as([5000:0]u8, @splat('v'));
    _ = c.setenv("SKETERM_TEST_ENV_LONG", long, 1);
    defer _ = unset("SKETERM_TEST_ENV_LONG");
    var s: Saved = .{};
    try t.expectError(error.EnvValueTooLong, s.take("SKETERM_TEST_ENV_LONG"));
    s.restore();
    try t.expectEqualStrings(long, get("SKETERM_TEST_ENV_LONG").?);
}

test "SavedSet puts back every variable, and a refused take undoes the earlier ones" {
    const t = std.testing;
    _ = c.setenv("SKETERM_TEST_ENV_SET_A", "a", 1);
    _ = unset("SKETERM_TEST_ENV_SET_B");
    _ = c.setenv("SKETERM_TEST_ENV_SET_LONG", &@as([5000:0]u8, @splat('v')), 1);
    defer _ = unset("SKETERM_TEST_ENV_SET_A");
    defer _ = unset("SKETERM_TEST_ENV_SET_LONG");

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

test "unset leaves the startup environment block std holds intact" {
    const t = std.testing;
    const block = t.environ.block.slice;
    var name_buf: [256:0]u8 = undefined;
    const name: [*:0]const u8 = for (block) |opt| {
        const entry = std.mem.span(opt orelse continue);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0 or eq >= name_buf.len) continue;
        @memcpy(name_buf[0..eq], entry[0..eq]);
        name_buf[eq] = 0;
        break &name_buf;
    } else return error.SkipZigTest;
    var saved: Saved = .{};
    try saved.take(name);
    defer saved.restore();
    try t.expect(unset(name));
    try t.expect(get(name) == null);
    try t.expect(@intFromPtr(platform.environSlot().*) != @intFromPtr(block.ptr));
    for (block) |opt| try t.expect(opt != null);
}
