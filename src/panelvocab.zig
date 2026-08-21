//! The panel wire vocabulary: the one home for component-id validity,
//! the payload bounds and the interaction-kind set.
//!
//! These are a CONTRACT between two dependency sets, which is why they
//! cannot live under `src/ui/`: the GUI presents panels
//! (`src/ui/panel/doc.zig`, `src/ui/panel/events.zig`) while the daemon
//! validates presenter traffic (`src/mux/panelrpc.zig`), and each used
//! to carry its own copy of the same rule with its own bound. A raised
//! `MAX_ID` on one side then silently accepts ids the other rejects.
//!
//! Pure `std`: no libc, no GTK, importable from every dependency set.

const std = @import("std");

/// Longest component id. Both sides of the wire read this constant.
pub const MAX_ID: usize = 64;

/// Longest text payload an event or a text-ish property carries.
pub const MAX_TEXT: usize = 4096;

/// Bound on the short interaction values (button actions, select
/// options), kept separate from `MAX_TEXT` so a submitted text_input
/// can be long without widening every other string.
pub const MAX_SHORT_TEXT: usize = 128;

/// What a component interaction was. The wire spells these lowercase,
/// exactly as `@tagName` renders them.
pub const Kind = enum { click, change, submit };

/// Decode a wire kind token, or null when it names none of them.
pub fn kindFromName(name: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, name);
}

/// Non-empty, at most `MAX_ID` bytes, starting alphanumeric or `_`, and
/// otherwise only alphanumerics and `_` `-` `.`.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_ID) return false;
    switch (id[0]) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    }
    for (id) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

const t = std.testing;

test "validId table" {
    const max_id = "a" ** MAX_ID;
    const too_long = "a" ** (MAX_ID + 1);
    const cases = [_]struct { id: []const u8, ok: bool }{
        .{ .id = "", .ok = false },
        .{ .id = "a", .ok = true },
        .{ .id = "_", .ok = true },
        .{ .id = "9", .ok = true },
        .{ .id = "ok.button-2", .ok = true },
        .{ .id = "A_b.c-D9", .ok = true },
        .{ .id = max_id, .ok = true },
        .{ .id = too_long, .ok = false },
        // Leading byte is stricter than the rest.
        .{ .id = "-lead", .ok = false },
        .{ .id = ".lead", .ok = false },
        .{ .id = "9lead", .ok = true },
        // Bytes no id may carry anywhere.
        .{ .id = "a/b", .ok = false },
        .{ .id = "a b", .ok = false },
        .{ .id = "a:b", .ok = false },
        .{ .id = "a\x00b", .ok = false },
        .{ .id = "a\nb", .ok = false },
        .{ .id = "caf\xc3\xa9", .ok = false },
        .{ .id = "\xff", .ok = false },
    };
    for (cases) |cs| {
        if (validId(cs.id) != cs.ok) {
            std.debug.print("validId(\"{s}\") should be {}\n", .{ cs.id, cs.ok });
            return error.TestUnexpectedResult;
        }
    }
}

test "kindFromName covers the wire tokens and nothing else" {
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        try t.expectEqual(@field(Kind, f.name), kindFromName(f.name).?);
    }
    try t.expect(kindFromName("") == null);
    try t.expect(kindFromName("Click") == null);
    try t.expect(kindFromName("hover") == null);
}
