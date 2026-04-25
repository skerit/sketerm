//! Default 256-color palette. Standard xterm-style: 16 ANSI + 6³
//! cube + 24-level grayscale. Comptime-built; renderer and OSC 4
//! query both consume this table.

pub const default_256: [256][3]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var p: [256][3]u8 = undefined;
    const ansi = [_][3]u8{
        .{ 0x00, 0x00, 0x00 }, .{ 0xCC, 0x00, 0x00 }, .{ 0x4E, 0x9A, 0x06 }, .{ 0xC4, 0xA0, 0x00 },
        .{ 0x34, 0x65, 0xA4 }, .{ 0x75, 0x50, 0x7B }, .{ 0x06, 0x98, 0x9A }, .{ 0xD3, 0xD7, 0xCF },
        .{ 0x55, 0x57, 0x53 }, .{ 0xEF, 0x29, 0x29 }, .{ 0x8A, 0xE2, 0x34 }, .{ 0xFC, 0xE9, 0x4F },
        .{ 0x72, 0x9F, 0xCF }, .{ 0xAD, 0x7F, 0xA8 }, .{ 0x34, 0xE2, 0xE2 }, .{ 0xEE, 0xEE, 0xEC },
    };
    for (ansi, 0..) |col, i| p[i] = col;
    var i: usize = 0;
    while (i < 216) : (i += 1) {
        const r = i / 36;
        const g = (i / 6) % 6;
        const b = i % 6;
        const ramp = [_]u8{ 0, 0x5F, 0x87, 0xAF, 0xD7, 0xFF };
        p[16 + i] = .{ ramp[r], ramp[g], ramp[b] };
    }
    var k: usize = 0;
    while (k < 24) : (k += 1) {
        const v: u8 = @intCast(8 + k * 10);
        p[232 + k] = .{ v, v, v };
    }
    break :blk p;
};
