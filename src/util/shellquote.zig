//! Shared POSIX-shell quoting (drag&drop paste, hint editor spawn).

const std = @import("std");

pub fn shellSafeChar(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '/', '-', '+', ':', '@', '%', '=', ',' => true,
        else => false,
    };
}

/// Single-quote `s` for the shell unless every byte is safe bare.
/// Embedded single quotes become the standard '\'' dance.
pub fn appendQuoted(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    var safe = s.len > 0;
    for (s) |b| {
        if (!shellSafeChar(b)) {
            safe = false;
            break;
        }
    }
    if (safe) {
        try list.appendSlice(allocator, s);
        return;
    }
    try list.append(allocator, '\'');
    for (s) |b| {
        if (b == '\'') {
            try list.appendSlice(allocator, "'\\''");
        } else {
            try list.append(allocator, b);
        }
    }
    try list.append(allocator, '\'');
}

test "appendQuoted: bare when safe, quoted + escaped otherwise" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    try appendQuoted(&out, a, "/safe/path.txt");
    try std.testing.expectEqualStrings("/safe/path.txt", out.items);

    out.clearRetainingCapacity();
    try appendQuoted(&out, a, "has space");
    try std.testing.expectEqualStrings("'has space'", out.items);

    out.clearRetainingCapacity();
    try appendQuoted(&out, a, "o'brien");
    try std.testing.expectEqualStrings("'o'\\''brien'", out.items);

    out.clearRetainingCapacity();
    try appendQuoted(&out, a, "");
    try std.testing.expectEqualStrings("''", out.items);
}
