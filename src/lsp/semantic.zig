//! Semantic tokens: the legend, the packed `data` array, and the delta
//! edits a server may send instead of a fresh array.
//!
//! The wire format is five `uint`s per token —
//! `deltaLine, deltaStartChar, length, tokenType, tokenModifiers` —
//! where `deltaStartChar` restarts at the beginning of every new line
//! and `startChar`/`length` count units of the NEGOTIATED position
//! encoding, not bytes. Decoding therefore produces LSP coordinates and
//! the caller maps them through `position.zig`, never by hand.
//!
//! `Data` keeps the raw array precisely because of `semanticTokens/
//! full/delta`: a delta response is a splice list against the array the
//! server last sent, so the client has to hold that array verbatim. It
//! also holds the `resultId`, which is what makes the next request a
//! delta request at all — no resultId, no delta, and the client asks
//! for a full set instead.
//!
//! GTK-free and in both test roots (src/lsp/CLAUDE.md).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One decoded token, in LSP coordinates.
pub const Token = struct {
    line: u32,
    start_char: u32,
    length: u32,
    type_index: u32,
    modifiers: u32,
};

/// The server's `tokenTypes` and `tokenModifiers` lists, owned. A
/// token's `tokenType` field indexes the first; its `tokenModifiers`
/// field is a BITSET whose bit N means `modifiers[N]`. An empty legend
/// makes every token untyped, which the caller renders as "leave the
/// Tree-sitter colour". Deliberately allocator-free (the allocator is
/// passed in), so it can be a plain field of `session.Caps`, which is
/// default-constructed before any allocator is in scope.
pub const Legend = struct {
    types: std.ArrayList([]u8) = .empty,
    modifiers: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Legend, alloc: Allocator) void {
        self.clear(alloc);
        self.types.deinit(alloc);
        self.modifiers.deinit(alloc);
    }

    pub fn clear(self: *Legend, alloc: Allocator) void {
        for (self.types.items) |t| alloc.free(t);
        self.types.clearRetainingCapacity();
        for (self.modifiers.items) |m| alloc.free(m);
        self.modifiers.clearRetainingCapacity();
    }

    /// Read `legend.tokenTypes` / `legend.tokenModifiers` out of a
    /// `semanticTokensProvider` options object. Anything malformed
    /// leaves that list empty rather than failing the session.
    pub fn absorb(self: *Legend, alloc: Allocator, provider: std.json.Value) void {
        self.clear(alloc);
        const po = switch (provider) {
            .object => |o| o,
            else => return,
        };
        const legend = switch (po.get("legend") orelse std.json.Value.null) {
            .object => |o| o,
            else => return,
        };
        absorbList(alloc, &self.types, legend.get("tokenTypes") orelse .null);
        absorbList(alloc, &self.modifiers, legend.get("tokenModifiers") orelse .null);
    }

    fn absorbList(alloc: Allocator, out: *std.ArrayList([]u8), v: std.json.Value) void {
        const arr = switch (v) {
            .array => |a| a,
            else => return,
        };
        for (arr.items) |t| {
            if (t != .string) continue;
            const dup = alloc.dupe(u8, t.string) catch return;
            out.append(alloc, dup) catch {
                alloc.free(dup);
                return;
            };
        }
    }

    /// Name of token type `idx`, or "" when the legend does not cover
    /// it (a server sending an out-of-range type is not an error we can
    /// do anything about).
    pub fn name(self: *const Legend, idx: u32) []const u8 {
        if (idx >= self.types.items.len) return "";
        return self.types.items[idx];
    }

    /// Name of modifier BIT `idx`, or "" when out of range.
    pub fn modName(self: *const Legend, idx: u32) []const u8 {
        if (idx >= self.modifiers.items.len) return "";
        return self.modifiers.items[idx];
    }

    /// Fold a token's `tokenModifiers` bitset into whatever `map` makes
    /// of each set bit's NAME, OR-ed together. Keeps the wire-order
    /// bit -> name resolution in one place: the same bit means different
    /// things to different servers, so a numeric shortcut is always a
    /// bug waiting for the next server.
    pub fn foldMods(
        self: *const Legend,
        bits: u32,
        comptime T: type,
        map: *const fn ([]const u8) T,
    ) T {
        var out: T = 0;
        var i: u5 = 0;
        while (true) : (i += 1) {
            if (bits & (@as(u32, 1) << i) != 0) out |= map(self.modName(i));
            if (i == 31) break;
        }
        return out;
    }
};

/// The packed token array as the server last sent it, plus the
/// `resultId` a delta request quotes.
pub const Data = struct {
    alloc: Allocator,
    raw: std.ArrayList(u32) = .empty,
    result_id: []u8 = &.{},
    /// A full/delta answer has landed at least once.
    valid: bool = false,

    pub fn init(alloc: Allocator) Data {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Data) void {
        self.raw.deinit(self.alloc);
        if (self.result_id.len > 0) self.alloc.free(self.result_id);
        self.result_id = &.{};
    }

    pub fn reset(self: *Data) void {
        self.raw.clearRetainingCapacity();
        if (self.result_id.len > 0) self.alloc.free(self.result_id);
        self.result_id = &.{};
        self.valid = false;
    }

    fn setResultId(self: *Data, v: std.json.Value) void {
        if (self.result_id.len > 0) self.alloc.free(self.result_id);
        self.result_id = &.{};
        if (v == .string and v.string.len > 0) {
            self.result_id = self.alloc.dupe(u8, v.string) catch &.{};
        }
    }

    /// Absorb a `SemanticTokens` (`{resultId?, data}`) reply.
    /// @return false when the payload was not a token array at all.
    pub fn absorbFull(self: *Data, result: std.json.Value) bool {
        const o = switch (result) {
            .object => |o| o,
            else => return false,
        };
        const arr = switch (o.get("data") orelse std.json.Value.null) {
            .array => |a| a,
            else => return false,
        };
        self.raw.clearRetainingCapacity();
        self.raw.ensureTotalCapacity(self.alloc, arr.items.len) catch return false;
        for (arr.items) |v| self.raw.appendAssumeCapacity(uintOf(v));
        self.setResultId(o.get("resultId") orelse .null);
        self.valid = true;
        return true;
    }

    /// Absorb a `SemanticTokensDelta` (`{resultId?, edits}`). Edits are
    /// splices into the CURRENT array and the spec sends them in
    /// ascending `start` order, so they are applied back-to-front —
    /// otherwise the first splice moves every later one's offset.
    ///
    /// @return false when the payload carries no `edits` array (i.e. it
    /// was a full answer, or garbage).
    pub fn absorbDelta(self: *Data, result: std.json.Value) bool {
        const o = switch (result) {
            .object => |o| o,
            else => return false,
        };
        const edits = switch (o.get("edits") orelse std.json.Value.null) {
            .array => |a| a,
            else => return false,
        };
        // Collect first: a malformed entry in the middle must not leave
        // the array half-spliced (which would silently mis-colour the
        // rest of the session).
        const Splice = struct { start: usize, del: usize, data: ?[]const std.json.Value };
        var list: std.ArrayList(Splice) = .empty;
        defer list.deinit(self.alloc);
        for (edits.items) |e| {
            if (e != .object) return false;
            const start: usize = @intCast(uintOf(e.object.get("start") orelse .null));
            const del: usize = @intCast(uintOf(e.object.get("deleteCount") orelse .null));
            if (start > self.raw.items.len or start + del > self.raw.items.len) return false;
            const data: ?[]const std.json.Value = switch (e.object.get("data") orelse std.json.Value.null) {
                .array => |a| a.items,
                else => null,
            };
            list.append(self.alloc, .{ .start = start, .del = del, .data = data }) catch return false;
        }
        std.mem.sort(Splice, list.items, {}, struct {
            fn less(_: void, a: Splice, b: Splice) bool {
                return a.start < b.start;
            }
        }.less);
        var i = list.items.len;
        while (i > 0) {
            i -= 1;
            const s = list.items[i];
            const src = s.data orelse &.{};
            const buf = self.alloc.alloc(u32, src.len) catch return false;
            defer self.alloc.free(buf);
            for (src, 0..) |v, k| buf[k] = uintOf(v);
            self.raw.replaceRange(self.alloc, s.start, s.del, buf) catch return false;
        }
        self.setResultId(o.get("resultId") orelse .null);
        self.valid = true;
        return true;
    }

    /// Decode the packed array into absolute-position tokens. Caller
    /// frees. A trailing partial tuple is ignored rather than treated
    /// as an error — the rest of the array is still usable.
    pub fn decode(self: *const Data, alloc: Allocator) Allocator.Error![]Token {
        var out: std.ArrayList(Token) = .empty;
        errdefer out.deinit(alloc);
        var line: u32 = 0;
        var ch: u32 = 0;
        var i: usize = 0;
        while (i + 5 <= self.raw.items.len) : (i += 5) {
            const dl = self.raw.items[i];
            const dc = self.raw.items[i + 1];
            if (dl != 0) {
                line +%= dl;
                ch = dc;
            } else {
                ch +%= dc;
            }
            try out.append(alloc, .{
                .line = line,
                .start_char = ch,
                .length = self.raw.items[i + 2],
                .type_index = self.raw.items[i + 3],
                .modifiers = self.raw.items[i + 4],
            });
        }
        return out.toOwnedSlice(alloc);
    }
};

fn uintOf(v: std.json.Value) u32 {
    return switch (v) {
        .integer => |i| if (i < 0) 0 else if (i > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(@min(f, @as(f64, std.math.maxInt(u32)))),
        else => 0,
    };
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn parse(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

test "semantic: legend absorbs tokenTypes and clamps unknown indices" {
    var p = try parse(
        \\{"legend":{"tokenTypes":["namespace","type","function"],"tokenModifiers":["static"]},"full":true}
    );
    defer p.deinit();
    var legend = Legend{};
    defer legend.deinit(testing.allocator);
    legend.absorb(testing.allocator, p.value);
    try testing.expectEqual(@as(usize, 3), legend.types.items.len);
    try testing.expectEqualStrings("type", legend.name(1));
    try testing.expectEqualStrings("", legend.name(99));
}

test "semantic: legend absorbs tokenModifiers and folds a bitset by NAME" {
    var p = try parse(
        \\{"legend":{"tokenTypes":["variable"],
        \\           "tokenModifiers":["declaration","readonly","static","deprecated"]},"full":true}
    );
    defer p.deinit();
    var legend = Legend{};
    defer legend.deinit(testing.allocator);
    legend.absorb(testing.allocator, p.value);
    try testing.expectEqual(@as(usize, 4), legend.modifiers.items.len);
    try testing.expectEqualStrings("readonly", legend.modName(1));
    try testing.expectEqualStrings("", legend.modName(9));

    const map = struct {
        fn f(name: []const u8) u8 {
            if (std.mem.eql(u8, name, "readonly")) return 1;
            if (std.mem.eql(u8, name, "deprecated")) return 2;
            return 0;
        }
    }.f;
    // bit 1 = readonly, bit 3 = deprecated; bits 0 and 2 map to nothing.
    try testing.expectEqual(@as(u8, 3), legend.foldMods(0b1111, u8, &map));
    try testing.expectEqual(@as(u8, 1), legend.foldMods(0b0010, u8, &map));
    try testing.expectEqual(@as(u8, 0), legend.foldMods(0b0101, u8, &map));
    // A bit past the legend names nothing and folds to nothing.
    try testing.expectEqual(@as(u8, 0), legend.foldMods(1 << 31, u8, &map));
}

test "semantic: legend survives a provider with no legend at all" {
    var p = try parse("true");
    defer p.deinit();
    var legend = Legend{};
    defer legend.deinit(testing.allocator);
    legend.absorb(testing.allocator, p.value);
    try testing.expectEqual(@as(usize, 0), legend.types.items.len);
}

test "semantic: full data decodes relative deltas to absolute positions" {
    // Two tokens on line 2 then one on line 5: the second token's
    // deltaStartChar is relative to the first, the third's restarts.
    var p = try parse(
        \\{"resultId":"7","data":[2,5,3,1,0, 0,6,4,2,1, 3,0,2,0,0]}
    );
    defer p.deinit();
    var d = Data.init(testing.allocator);
    defer d.deinit();
    try testing.expect(d.absorbFull(p.value));
    try testing.expectEqualStrings("7", d.result_id);
    const toks = try d.decode(testing.allocator);
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expectEqual(@as(u32, 2), toks[0].line);
    try testing.expectEqual(@as(u32, 5), toks[0].start_char);
    try testing.expectEqual(@as(u32, 1), toks[0].type_index);
    // Same line: char accumulates.
    try testing.expectEqual(@as(u32, 2), toks[1].line);
    try testing.expectEqual(@as(u32, 11), toks[1].start_char);
    try testing.expectEqual(@as(u32, 1), toks[1].modifiers);
    // New line: char restarts from the delta.
    try testing.expectEqual(@as(u32, 5), toks[2].line);
    try testing.expectEqual(@as(u32, 0), toks[2].start_char);
}

test "semantic: a trailing partial tuple is ignored, not decoded" {
    var p = try parse("{\"data\":[0,0,1,0,0, 1,2]}");
    defer p.deinit();
    var d = Data.init(testing.allocator);
    defer d.deinit();
    try testing.expect(d.absorbFull(p.value));
    const toks = try d.decode(testing.allocator);
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 1), toks.len);
}

test "semantic: delta edits splice the stored array" {
    var full = try parse("{\"resultId\":\"1\",\"data\":[0,0,3,0,0, 1,0,4,1,0]}");
    defer full.deinit();
    var d = Data.init(testing.allocator);
    defer d.deinit();
    try testing.expect(d.absorbFull(full.value));

    // Replace the SECOND tuple (index 5..10) with two new tuples.
    var delta = try parse(
        \\{"resultId":"2","edits":[{"start":5,"deleteCount":5,"data":[1,0,2,2,0, 0,4,1,3,0]}]}
    );
    defer delta.deinit();
    try testing.expect(d.absorbDelta(delta.value));
    try testing.expectEqualStrings("2", d.result_id);
    try testing.expectEqual(@as(usize, 15), d.raw.items.len);
    const toks = try d.decode(testing.allocator);
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expectEqual(@as(u32, 2), toks[1].type_index);
    try testing.expectEqual(@as(u32, 1), toks[2].line);
    try testing.expectEqual(@as(u32, 4), toks[2].start_char);
}

test "semantic: several delta edits apply back-to-front" {
    var full = try parse("{\"data\":[0,0,1,0,0, 0,2,1,0,0, 0,2,1,0,0]}");
    defer full.deinit();
    var d = Data.init(testing.allocator);
    defer d.deinit();
    try testing.expect(d.absorbFull(full.value));
    // Delete the first tuple AND the last one in a single answer.
    var delta = try parse(
        \\{"edits":[{"start":0,"deleteCount":5},{"start":10,"deleteCount":5}]}
    );
    defer delta.deinit();
    try testing.expect(d.absorbDelta(delta.value));
    try testing.expectEqual(@as(usize, 5), d.raw.items.len);
    try testing.expectEqual(@as(u32, 2), d.raw.items[1]);
}

test "semantic: an out-of-range delta is refused wholesale" {
    var full = try parse("{\"data\":[0,0,1,0,0]}");
    defer full.deinit();
    var d = Data.init(testing.allocator);
    defer d.deinit();
    try testing.expect(d.absorbFull(full.value));
    var delta = try parse("{\"edits\":[{\"start\":99,\"deleteCount\":1}]}");
    defer delta.deinit();
    try testing.expect(!d.absorbDelta(delta.value));
    // Untouched: a refused delta must leave the last good array intact.
    try testing.expectEqual(@as(usize, 5), d.raw.items.len);
}

test "semantic: reset drops the resultId so the next request is full" {
    var p = try parse("{\"resultId\":\"abc\",\"data\":[]}");
    defer p.deinit();
    var d = Data.init(testing.allocator);
    defer d.deinit();
    try testing.expect(d.absorbFull(p.value));
    try testing.expectEqualStrings("abc", d.result_id);
    d.reset();
    try testing.expectEqual(@as(usize, 0), d.result_id.len);
    try testing.expect(!d.valid);
}
