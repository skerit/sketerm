//! Rig helper: find nodes in an `A11yHub.treeJson` dump by accessible
//! name and role, the way a screen reader finds a control. Shared by
//! smoke-atspi and smoke-e2e, so neither hand-parses the dump.
//!
//! The dump is `{"id":"..","role":N,"name":"..",["desc":..,]"states":[lo,hi],...}`
//! per node in tree order. Names are compared as they appear in the JSON,
//! so a needle must not contain a quote or a backslash.

const std = @import("std");

/// AT-SPI role numbers (`AtspiRole`) the rigs ask for.
pub const ROLE_LABEL: u32 = 29;
pub const ROLE_PUSH_BUTTON: u32 = 43;
pub const ROLE_HEADING: u32 = 83;

/// Low-word `AtspiStateType` bits.
pub const STATE_EXPANDED_BIT: u32 = 1 << 10;
pub const STATE_SENSITIVE_BIT: u32 = 1 << 24;
pub const STATE_SHOWING_BIT: u32 = 1 << 25;

pub const Match = enum { exact, prefix };

/// One node; `id` and `name` are slices of the dump.
pub const Hit = struct { id: []const u8, role: u32, name: []const u8, states_lo: u32 };

/// Every node whose name matches `needle` and whose role is `role` (null
/// = any), in tree order, into `out`. @return how many matched, which
/// may exceed `out.len` (the extra ones are counted, not stored).
pub fn scan(json: []const u8, needle: []const u8, match: Match, role: ?u32, out: []Hit) usize {
    var n: usize = 0;
    var from: usize = 0;
    const id_key = "{\"id\":\"";
    while (std.mem.indexOfPos(u8, json, from, id_key)) |at| {
        from = at + id_key.len;
        const hit = parseNode(json, from) orelse continue;
        const named = switch (match) {
            .exact => std.mem.eql(u8, hit.name, needle),
            .prefix => std.mem.startsWith(u8, hit.name, needle),
        };
        if (!named) continue;
        if (role) |r| if (hit.role != r) continue;
        if (n < out.len) out[n] = hit;
        n += 1;
    }
    return n;
}

/// The first node `scan` would return, if any.
pub fn first(json: []const u8, needle: []const u8, match: Match, role: ?u32) ?Hit {
    var one: [1]Hit = undefined;
    return if (scan(json, needle, match, role, &one) > 0) one[0] else null;
}

fn parseNode(json: []const u8, id_start: usize) ?Hit {
    const id_end = std.mem.indexOfScalarPos(u8, json, id_start, '"') orelse return null;
    var i = id_end;
    const role_key = "\",\"role\":";
    if (!std.mem.startsWith(u8, json[i..], role_key)) return null;
    i += role_key.len;
    const role = readNum(json, &i);
    const name_key = ",\"name\":\"";
    if (!std.mem.startsWith(u8, json[i..], name_key)) return null;
    i += name_key.len;
    const name_start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {
        if (json[i] == '\\') i += 1;
    }
    if (i >= json.len) return null;
    const name = json[name_start..i];
    var states_lo: u32 = 0;
    const st_key = ",\"states\":[";
    // The states follow the name (and an optional description) before
    // the next node starts.
    const next = std.mem.indexOfPos(u8, json, i, "{\"id\":\"") orelse json.len;
    if (std.mem.indexOfPos(u8, json[0..next], i, st_key)) |sk| {
        var j = sk + st_key.len;
        states_lo = readNum(json, &j);
    }
    return .{ .id = json[id_start..id_end], .role = role, .name = name, .states_lo = states_lo };
}

fn readNum(json: []const u8, i: *usize) u32 {
    var v: u32 = 0;
    while (i.* < json.len and json[i.*] >= '0' and json[i.*] <= '9') : (i.* += 1) v = v *% 10 +% (json[i.*] - '0');
    return v;
}

test "nodes are found by exact or prefix name and role, with their states" {
    const dump =
        \\{"id":":1.2/a","role":43,"name":"Watch claude-1 (claude)","states":[16777216,0],"children":[
        \\{"id":":1.2/b","role":29,"name":"claudehere","desc":"x","states":[33554432,0]},
        \\{"id":":1.2/c","role":43,"name":"Watch claude-2 (claude)","states":[0,0]}]}
    ;
    var hits: [4]Hit = undefined;
    try std.testing.expectEqual(@as(usize, 2), scan(dump, "Watch ", .prefix, ROLE_PUSH_BUTTON, &hits));
    try std.testing.expectEqualStrings(":1.2/a", hits[0].id);
    try std.testing.expect(hits[0].states_lo & STATE_SENSITIVE_BIT != 0);
    try std.testing.expect(hits[1].states_lo & STATE_SENSITIVE_BIT == 0);
    const label = first(dump, "claudehere", .exact, ROLE_LABEL).?;
    try std.testing.expect(label.states_lo & STATE_SHOWING_BIT != 0);
    try std.testing.expect(first(dump, "claudehere", .exact, ROLE_PUSH_BUTTON) == null);
}
