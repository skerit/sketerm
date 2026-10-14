//! Short random ids for things a person reads and types back: the ONE
//! home of the alphabet (agent ids `claude-k3f9`, peer message ids
//! `m-k3f9x2qa`). Lowercase Crockford base32: no i, l, o or u to misread.

const std = @import("std");
const c = @import("../c.zig").c;

pub const ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz";

/// Fill `out` with random alphabet characters.
pub fn fill(out: []u8) error{NoEntropy}!void {
    var off: usize = 0;
    // getentropy refuses more than 256 bytes per call.
    while (off < out.len) {
        const n = @min(out.len - off, 256);
        if (c.getentropy(out[off..].ptr, n) != 0) return error.NoEntropy;
        off += n;
    }
    // 256 is a multiple of 32, so the modulo carries no bias.
    for (out) |*b| b.* = ALPHABET[b.* % ALPHABET.len];
}

/// `prefix` followed by `n` random alphabet characters, written into `buf`.
pub fn mint(buf: []u8, prefix: []const u8, n: usize) error{ NoEntropy, NoSpaceLeft }![]u8 {
    if (buf.len < prefix.len + n) return error.NoSpaceLeft;
    @memcpy(buf[0..prefix.len], prefix);
    try fill(buf[prefix.len..][0..n]);
    return buf[0 .. prefix.len + n];
}

/// Whether every character of `s` is in the alphabet.
pub fn isAlphabet(s: []const u8) bool {
    for (s) |ch| if (std.mem.indexOfScalar(u8, ALPHABET, ch) == null) return false;
    return true;
}

test "a minted id is the prefix plus n alphabet characters, and ids differ" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 32), ALPHABET.len);
    var a_buf: [16]u8 = undefined;
    var b_buf: [16]u8 = undefined;
    const a = try mint(&a_buf, "m-", 8);
    const b = try mint(&b_buf, "m-", 8);
    try t.expectEqual(@as(usize, 10), a.len);
    try t.expect(std.mem.startsWith(u8, a, "m-"));
    try t.expect(isAlphabet(a[2..]));
    try t.expect(!std.mem.eql(u8, a, b));
    try t.expectError(error.NoSpaceLeft, mint(a_buf[0..4], "m-", 8));
    var big: [600]u8 = undefined;
    try fill(&big);
    try t.expect(isAlphabet(&big));
}
