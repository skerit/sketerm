//! The session names sketerm mints for a session nobody named, and the
//! test that recognises one: the ONE home of their shapes. A minted name
//! is never taken for a title the user gave (a peer alias and a default
//! subject come only from the latter, `daemon_peers.sessionTitle`).

const std = @import("std");
const reflect = @import("../util/reflect.zig");

/// Who mints a name, which fixes its prefix: `<prefix><pid>-<seq>`.
pub const Minter = enum {
    /// A GUI pane, or `sketerm mux` run without a name.
    shell,
    /// A `term_open` headless terminal.
    mcpterm,
    /// A `launch_app` headless app session.
    mcpapp,

    pub fn prefix(self: Minter) []const u8 {
        return switch (self) {
            .shell => "s",
            .mcpterm => "mcpterm-",
            .mcpapp => "mcpapp-",
        };
    }
};

/// The name `minter` gives the `seq`th session of process `pid`, into `buf`.
pub fn print(buf: []u8, minter: Minter, pid: i64, seq: u64) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}-{d}", .{ minter.prefix(), pid, seq });
}

/// As `print`, allocated.
pub fn alloc(allocator: std.mem.Allocator, minter: Minter, pid: i64, seq: u64) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{d}-{d}", .{ minter.prefix(), pid, seq });
}

/// Whether `name` has the shape some `Minter` gives.
pub fn isMinted(name: []const u8) bool {
    inline for (reflect.fields(Minter)) |f| {
        const p = @as(Minter, @enumFromInt(f.value)).prefix();
        if (std.mem.startsWith(u8, name, p) and pidSeq(name[p.len..])) return true;
    }
    return false;
}

/// `<digits>-<digits>`.
fn pidSeq(rest: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return false;
    return allDigits(rest[0..dash]) and allDigits(rest[dash + 1 ..]);
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

const t = std.testing;

test "every minted shape is recognised; names a user gives are not" {
    var buf: [48]u8 = undefined;
    inline for (reflect.fields(Minter)) |f| {
        const m: Minter = @enumFromInt(f.value);
        try t.expect(isMinted(try print(&buf, m, 85382, 27)));
        const owned = try alloc(t.allocator, m, 7, 1);
        defer t.allocator.free(owned);
        try t.expect(isMinted(owned));
    }
    try t.expectEqualStrings("s85382-27", try print(&buf, .shell, 85382, 27));
    for ([_][]const u8{ "zenit", "Qq", "s85382", "s-1-2", "mcpterm-a-1", "agent-claude-k3f9", "build-2024", "s1-", "" }) |n| {
        try t.expect(!isMinted(n));
    }
}
