//! SGR conformance: the `4:N` underline styles and the DECRQSS `m`
//! report, both driven through the parser/apply path.
//!
//! The report is `screen_ops.sgrParams`, the inverse of `screen_ops.sgr`.
//! The two share no table, so the proof that they agree is the
//! round trip below: feed a sequence, ask DECRQSS, feed the answer to
//! a fresh screen, and expect the same style entry back.

const std = @import("std");
const Harness = @import("test_harness.zig").Harness;
const screen_ops = @import("../grid/screen_ops.zig");
const style_pool = @import("../grid/style_pool.zig");
const Entry = style_pool.Entry;
const Attrs = style_pool.Attrs;

const DECRQSS_SGR = "\x1bP$qm\x1b\\";

fn currentEntry(h: *Harness) Entry {
    return h.pool.get(h.screen.cur_style);
}

/// Feed `sgr_seq`, ask DECRQSS for the SGR state and return the whole
/// reply (`h.wtc`).
fn queryAfter(h: *Harness, sgr_seq: []const u8) []const u8 {
    h.arm();
    h.feed(sgr_seq);
    h.wtc.clearRetainingCapacity();
    h.feed(DECRQSS_SGR);
    return h.wtc.items;
}

fn expectReport(sgr_seq: []const u8, expected_params: []const u8) !void {
    var h = try Harness.init(std.testing.allocator, 10, 2);
    defer h.deinit();
    const reply = queryAfter(&h, sgr_seq);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "\x1bP1$r{s}m\x1b\\", .{expected_params});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, reply);
}

test "DECRQSS m: a reset style reports a bare 0" {
    try expectReport("\x1b[0m", "0");
}

test "DECRQSS m: every attribute is reported in xterm order" {
    try expectReport("\x1b[1;2;3;4;5;6;7;8;9;53m", "0;1;2;3;4;5;6;7;8;9;53");
}

test "DECRQSS m: underline styles report in the 4:N form, single as 4" {
    try expectReport("\x1b[4m", "0;4");
    try expectReport("\x1b[4:1m", "0;4");
    try expectReport("\x1b[4:2m", "0;4:2");
    try expectReport("\x1b[21m", "0;4:2");
    try expectReport("\x1b[4:3m", "0;4:3");
    try expectReport("\x1b[4:4m", "0;4:4");
    try expectReport("\x1b[4:5m", "0;4:5");
    try expectReport("\x1b[4:9m", "0;4");
}

test "DECRQSS m: colours use the short palette forms, 38/48/58 otherwise" {
    try expectReport("\x1b[31m", "0;31");
    try expectReport("\x1b[91m", "0;91");
    try expectReport("\x1b[38;5;7m", "0;37");
    try expectReport("\x1b[38;5;15m", "0;97");
    try expectReport("\x1b[38;5;200m", "0;38;5;200");
    try expectReport("\x1b[38;2;1;2;3m", "0;38;2;1;2;3");
    try expectReport("\x1b[38:2::1:2:3m", "0;38;2;1;2;3");
    try expectReport("\x1b[42m", "0;42");
    try expectReport("\x1b[102m", "0;102");
    try expectReport("\x1b[48;5;16m", "0;48;5;16");
    try expectReport("\x1b[48;2;4;5;6m", "0;48;2;4;5;6");
    // SGR 58 has no short palette form, so 0-15 stay `58;5;n`.
    try expectReport("\x1b[58;5;1m", "0;58;5;1");
    try expectReport("\x1b[58;5;9m", "0;58;5;9");
    try expectReport("\x1b[58;2;7;8;9m", "0;58;2;7;8;9");
    try expectReport("\x1b[31;42;58;5;9m", "0;31;42;58;5;9");
}

test "DECRQSS m: the reply is the longest in the worst case and fits its buffer" {
    var h = try Harness.init(std.testing.allocator, 10, 2);
    defer h.deinit();
    // Every attribute, then every colour as truecolor (three SGRs so
    // no single one exceeds the parser's 16 parameters).
    h.feed("\x1b[1;2;3;4:3;5;6;7;8;9;53m\x1b[38;2;255;255;255;48;2;255;255;255m\x1b[58;2;255;255;255m");
    var buf: [screen_ops.sgr_params_max_len]u8 = undefined;
    const params = try screen_ops.sgrParams(currentEntry(&h), &buf);
    try std.testing.expectEqualStrings(
        "0;1;2;3;4:3;5;6;7;8;9;53;38;2;255;255;255;48;2;255;255;255;58;2;255;255;255",
        params,
    );
    try std.testing.expectEqual(screen_ops.sgr_params_max_len, params.len);
    // And the DECRQSS path itself does not truncate it.
    h.arm();
    h.wtc.clearRetainingCapacity();
    h.feed(DECRQSS_SGR);
    try std.testing.expectEqualStrings("\x1bP1$r" ++
        "0;1;2;3;4:3;5;6;7;8;9;53;38;2;255;255;255;48;2;255;255;255;58;2;255;255;255" ++
        "m\x1b\\", h.wtc.items);
}

/// Feed `seq` to one screen, replay its DECRQSS answer as a CSI m
/// into another, and expect both to hold the same style entry and to
/// give the same answer again (the report is a fixed point).
fn expectRoundTrip(seq: []const u8) !void {
    var a = try Harness.init(std.testing.allocator, 10, 2);
    defer a.deinit();
    const reply = queryAfter(&a, seq);
    const prefix = "\x1bP1$r";
    const suffix = "m\x1b\\";
    try std.testing.expect(std.mem.startsWith(u8, reply, prefix));
    try std.testing.expect(std.mem.endsWith(u8, reply, suffix));
    const params = reply[prefix.len .. reply.len - suffix.len];
    const csi = try std.fmt.allocPrint(std.testing.allocator, "\x1b[{s}m", .{params});
    defer std.testing.allocator.free(csi);

    var b = try Harness.init(std.testing.allocator, 10, 2);
    defer b.deinit();
    const reply_b = queryAfter(&b, csi);
    try std.testing.expect(Entry.equal(currentEntry(&a), currentEntry(&b)));
    try std.testing.expectEqualStrings(reply, reply_b);
}

test "DECRQSS m round-trips every attribute through sgr" {
    try expectRoundTrip("\x1b[0m");
    try expectRoundTrip("\x1b[1;2;3;5;6;7;8;9;53m");
    // Each attribute alone, so a bit that the report drops or the
    // parser misreads cannot hide behind the others.
    inline for (.{ "1", "2", "3", "4", "4:2", "4:3", "4:4", "4:5", "5", "6", "7", "8", "9", "21", "53" }) |p| {
        try expectRoundTrip("\x1b[" ++ p ++ "m");
    }
}

test "DECRQSS m round-trips every colour form through sgr" {
    inline for (.{
        "31",                        "37",               "91",            "97",
        "38;5;0",                    "38;5;15",          "38;5;16",       "38;5;255",
        "38;2;0;0;0",                "38;2;255;255;255", "38;2;12;34;56", "42",
        "47",                        "102",              "107",           "48;5;3",
        "48;5;231",                  "48;2;9;8;7",       "58;5;1",        "58;5;9",
        "58;5;200",                  "58;2;1;2;3",       "31;42;58;5;4",  "38;5;100;48;5;200",
        "1;7;38;2;1;2;3;48;2;4;5;6",
    }) |p| {
        try expectRoundTrip("\x1b[" ++ p ++ "m");
    }
}

test "underline styles are exclusive: the last 4:N wins" {
    var h = try Harness.init(std.testing.allocator, 10, 2);
    defer h.deinit();
    h.feed("\x1b[4:2m\x1b[4:3m");
    try std.testing.expectEqual(Attrs.UnderlineStyle.curly, currentEntry(&h).attrs.underlineStyle());
    try std.testing.expect(!currentEntry(&h).attrs.double_underline);
    h.feed("\x1b[4:4m");
    try std.testing.expectEqual(Attrs.UnderlineStyle.dotted, currentEntry(&h).attrs.underlineStyle());
    h.feed("\x1b[4:5m");
    try std.testing.expectEqual(Attrs.UnderlineStyle.dashed, currentEntry(&h).attrs.underlineStyle());
    try std.testing.expect(!currentEntry(&h).attrs.dotted_underline);
    h.feed("\x1b[4m");
    try std.testing.expectEqual(Attrs.UnderlineStyle.single, currentEntry(&h).attrs.underlineStyle());
    try std.testing.expect(!currentEntry(&h).attrs.dashed_underline);
    h.feed("\x1b[21m");
    try std.testing.expectEqual(Attrs.UnderlineStyle.double, currentEntry(&h).attrs.underlineStyle());
    try std.testing.expect(!currentEntry(&h).attrs.underline);
}

test "SGR 24 and 4:0 clear every underline style" {
    inline for (.{ "4", "4:2", "4:3", "4:4", "4:5", "21" }) |set| {
        inline for (.{ "24", "4:0" }) |clear| {
            var h = try Harness.init(std.testing.allocator, 10, 2);
            defer h.deinit();
            h.feed("\x1b[" ++ set ++ "m\x1b[" ++ clear ++ "m");
            try std.testing.expectEqual(Attrs.UnderlineStyle.none, currentEntry(&h).attrs.underlineStyle());
            try std.testing.expectEqual(@as(u16, 0), @as(u16, @bitCast(currentEntry(&h).attrs)));
        }
    }
}

test "SGR 4:4 and 4:5 are dotted and dashed, not curly" {
    var h = try Harness.init(std.testing.allocator, 10, 2);
    defer h.deinit();
    h.feed("\x1b[4:4mx\x1b[0m\x1b[4:5my\x1b[0m");
    const dotted = h.pool.get(h.screen.cellAt(0, 0).style_ref).attrs;
    const dashed = h.pool.get(h.screen.cellAt(0, 1).style_ref).attrs;
    try std.testing.expectEqual(Attrs.UnderlineStyle.dotted, dotted.underlineStyle());
    try std.testing.expectEqual(Attrs.UnderlineStyle.dashed, dashed.underlineStyle());
    try std.testing.expect(!dotted.underline and !dashed.underline);
    try std.testing.expect(!dotted.dashed_underline and !dashed.dotted_underline);
}
