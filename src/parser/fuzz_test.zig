//! Randomised parser → Screen fuzzing.
//!
//! Feeds pseudo-random byte streams through `Parser.advance` into a
//! small `Screen` and asserts the structural invariants every other
//! module indexes on: the cursor is inside the grid, the scroll region
//! is inside the grid, and every line — active, alternate and
//! scrollback — is exactly `cols` cells wide. `cellAt` and the render
//! passes index those unchecked, so a violation is an out-of-bounds
//! write on the next print rather than a cosmetic glitch.
//!
//! Seeds are fixed so a failure is reproducible; the byte alphabet is
//! weighted towards ESC/CSI structure because uniform random bytes
//! almost never reach a dispatch path.

const std = @import("std");
const Harness = @import("test_harness.zig").Harness;

/// Bytes that make a random stream actually reach dispatch: control
/// characters, the CSI introducers, parameter bytes and the final
/// bytes of the sequences that move or delete cells.
const alphabet = [_]u8{
    0x1b, 0x1b, '[',  '[',  ']',  'P',  '_',  '#',  '?',  '>',
    '=',  '<',  '!',  '$',  '"',  ' ',  ';',  ':',  '0',  '1',
    '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',  'A',  'B',
    'C',  'D',  'E',  'F',  'G',  'H',  'J',  'K',  'L',  'M',
    'P',  'S',  'T',  'X',  'Z',  'b',  'c',  'd',  'g',  'h',
    'l',  'm',  'n',  'p',  'q',  'r',  's',  't',  'u',  'x',
    '\n', '\r', '\t', 0x08, 0x07, 0x0b, 0x0c, 0x0e, 0x0f, 0x00,
    'a',  'z',  '/',  '\\', 0xc3, 0xa9, 0xe4, 0xb8, 0xad, 0xf0,
    0x9f, 0x98, 0x80, 0xcc, 0x81, 0x9c, 0x7f, 0x18, 0x1a, 0x90,
};

fn checkInvariants(h: *Harness) !void {
    const s = h.screen;
    try std.testing.expect(s.rows > 0 and s.cols > 0);
    try std.testing.expect(s.row < s.rows);
    try std.testing.expect(s.col < s.cols);
    try std.testing.expect(s.scroll_top <= s.scroll_bot);
    try std.testing.expect(s.scroll_bot < s.rows);
    try std.testing.expectEqual(@as(usize, s.rows), s.active.len);
    for (s.active) |ln| try std.testing.expectEqual(@as(usize, s.cols), ln.cells.len);
    if (s.alt) |alt| {
        try std.testing.expectEqual(@as(usize, s.rows), alt.len);
        for (alt) |ln| try std.testing.expectEqual(@as(usize, s.cols), ln.cells.len);
    }
    for (s.scrollback.items) |ln| try std.testing.expectEqual(@as(usize, s.cols), ln.cells.len);
    try std.testing.expectEqual(@as(usize, s.cols), s.tab_stops.items.len);
}

fn fuzzRound(a: std.mem.Allocator, seed: u64, cols: u16, rows: u16, resizes: bool) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var h = try Harness.init(a, cols, rows);
    defer h.deinit();
    h.arm();
    // Replies would otherwise accumulate unbounded in the capture list.
    h.screen.mute_responses = true;

    var chunk: [96]u8 = undefined;
    var step: usize = 0;
    while (step < 40) : (step += 1) {
        const n = rnd.intRangeAtMost(usize, 1, chunk.len);
        for (chunk[0..n]) |*b| {
            b.* = if (rnd.uintLessThan(u8, 8) == 0)
                rnd.int(u8)
            else
                alphabet[rnd.uintLessThan(usize, alphabet.len)];
        }
        h.feed(chunk[0..n]);
        try checkInvariants(&h);

        if (resizes and rnd.uintLessThan(u8, 4) == 0) {
            const nc = rnd.intRangeAtMost(u16, 1, 12);
            const nr = rnd.intRangeAtMost(u16, 1, 6);
            h.screen.resize(nc, nr) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return err,
            };
            try checkInvariants(&h);
        }
    }
}

test "fuzz: random escape streams keep Screen invariants" {
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        try fuzzRound(std.testing.allocator, seed *% 0x9E3779B97F4A7C15, 8, 4, false);
    }
}

test "fuzz: one-column and one-row grids keep Screen invariants" {
    var seed: u64 = 0;
    while (seed < 32) : (seed += 1) {
        const s = seed *% 0xD1B54A32D192ED03;
        try fuzzRound(std.testing.allocator, s, 1, 4, false);
        try fuzzRound(std.testing.allocator, s, 6, 1, false);
        try fuzzRound(std.testing.allocator, s, 1, 1, false);
    }
}

test "fuzz: random streams interleaved with resizes keep Screen invariants" {
    var seed: u64 = 0;
    while (seed < 48) : (seed += 1) {
        try fuzzRound(std.testing.allocator, seed *% 0xBF58476D1CE4E5B9, 6, 3, true);
    }
}
