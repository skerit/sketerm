//! Agent facts (context-window use, rate limits, cost): the vocabulary in
//! `data/agents/facts.json`, and reading the values an adapter declares as
//! JSON paths into a document its source supplies. Nothing here knows an
//! app: adding a fact is a line in facts.json plus a mapping in an adapter.
//!
//! A null, an absent key or a non-number is unknown, never 0. A module that
//! calls `shipped` must get the `agent_adapters` import (build.zig's
//! `addAgentAdapters`).

const std = @import("std");
const shellquote = @import("../util/shellquote.zig");

/// How a fact's number reads; the integer types never carry a fraction.
pub const FactType = enum {
    int,
    percent,
    tokens,
    usd,
    unix_time,

    pub fn integral(self: FactType) bool {
        return switch (self) {
            .int, .tokens, .unix_time => true,
            .percent, .usd => false,
        };
    }
};

/// A fact computed from two others when no adapter path gives it:
/// `100 * ratio[0] / ratio[1]`.
pub const Derive = struct {
    ratio: [2][]const u8,
};

pub const Decl = struct {
    type: FactType,
    meaning: []const u8,
    derive: ?Derive = null,
    /// Its label in one-line summaries (`compactLine`); absent = not shown there.
    compact: ?[]const u8 = null,
};

const File = struct {
    facts: std.json.ArrayHashMap(Decl),
};

/// The parsed, validated vocabulary.
pub const Vocab = struct {
    arena: std.heap.ArenaAllocator,
    names: []const []const u8,
    decls: []const Decl,
    /// Per fact: the indexes `derive.ratio` names (null when it has none).
    ratio: []const ?[2]usize,

    pub fn index(self: *const Vocab, name: []const u8) ?usize {
        for (self.names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
        return null;
    }

    pub fn destroy(self: *Vocab, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// A fact name: 1-48 chars of [a-z0-9_], starting with a letter.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 48 or !std.ascii.isLower(name[0])) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

/// Parse and validate a vocabulary file.
/// @param problem receives a one-line reason (allocated from `allocator`) on error.InvalidFacts.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, problem: *?[]u8) !*Vocab {
    const self = try allocator.create(Vocab);
    self.arena = std.heap.ArenaAllocator.init(allocator);
    errdefer self.destroy(allocator);
    const a = self.arena.allocator();
    const file = std.json.parseFromSliceLeaky(File, a, bytes, .{ .allocate = .alloc_always }) catch |err| {
        problem.* = try std.fmt.allocPrint(allocator, "facts.json: {s}", .{@errorName(err)});
        return error.InvalidFacts;
    };
    self.names = file.facts.map.keys();
    self.decls = file.facts.map.values();
    const ratio = try a.alloc(?[2]usize, self.names.len);
    self.ratio = ratio;
    for (self.names, self.decls, ratio) |n, d, *r| {
        if (!validName(n)) {
            problem.* = try std.fmt.allocPrint(allocator, "facts.json: fact name \"{s}\" must be 1-48 chars of [a-z0-9_], starting with a letter", .{n});
            return error.InvalidFacts;
        }
        if (d.meaning.len == 0) {
            problem.* = try std.fmt.allocPrint(allocator, "facts.json: {s} has no meaning", .{n});
            return error.InvalidFacts;
        }
        r.* = null;
        const dv = d.derive orelse continue;
        if (d.type != .percent) {
            problem.* = try std.fmt.allocPrint(allocator, "facts.json: {s}: a ratio derives a percent, not {s}", .{ n, @tagName(d.type) });
            return error.InvalidFacts;
        }
        var idx: [2]usize = undefined;
        for (dv.ratio, &idx) |ref, *out| {
            out.* = self.index(ref) orelse {
                problem.* = try std.fmt.allocPrint(allocator, "facts.json: {s} derives from unknown fact \"{s}\"", .{ n, ref });
                return error.InvalidFacts;
            };
            // One level only: a derived input would need an evaluation order.
            if (self.decls[out.*].derive != null) {
                problem.* = try std.fmt.allocPrint(allocator, "facts.json: {s} derives from {s}, which is derived itself", .{ n, ref });
                return error.InvalidFacts;
            }
        }
        r.* = idx;
    }
    return self;
}

var shipped_vocab: ?*Vocab = null;

/// The shipped vocabulary, parsed on first use and kept for the process.
/// @throws InvalidFacts when facts.json does not validate (a build bug a test catches).
pub fn shipped() error{ InvalidFacts, OutOfMemory }!*const Vocab {
    if (shipped_vocab) |v| return v;
    var problem: ?[]u8 = null;
    const v = parse(std.heap.page_allocator, @import("agent_adapters").facts_json, &problem) catch |err| {
        if (problem) |p| std.heap.page_allocator.free(p);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidFacts,
        };
    };
    shipped_vocab = v;
    return v;
}

/// Where in a source document one fact is: one dotted path, or several
/// whose numbers are summed (unknown only when none is a number).
pub const Paths = struct {
    list: []const []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Paths {
        switch (try source.peekNextTokenType()) {
            .string => return .{ .list = try allocator.dupe([]const u8, &.{try std.json.innerParse([]const u8, allocator, source, options)}) },
            .array_begin => return .{ .list = try std.json.innerParse([]const []const u8, allocator, source, options) },
            else => return error.UnexpectedToken,
        }
    }
};

/// An adapter's mapping: fact name to its paths.
pub const Map = std.json.ArrayHashMap(Paths);

/// Why `map` cannot be an adapter's mapping under `vocab`, or null.
pub fn mapProblem(arena: std.mem.Allocator, vocab: *const Vocab, map: Map) !?[]const u8 {
    for (map.map.keys(), map.map.values()) |name, paths| {
        if (vocab.index(name) == null)
            return try std.fmt.allocPrint(arena, "facts.map: \"{s}\" is not a fact facts.json declares (it declares {s})", .{ name, try std.mem.join(arena, ", ", vocab.names) });
        if (paths.list.len == 0) return try std.fmt.allocPrint(arena, "facts.map.{s}: no path", .{name});
        for (paths.list) |p| {
            if (p.len == 0 or p[0] == '.' or p[p.len - 1] == '.' or std.mem.indexOf(u8, p, "..") != null)
                return try std.fmt.allocPrint(arena, "facts.map.{s}: \"{s}\" is not a dotted path", .{ name, p });
        }
    }
    return null;
}

/// The facts `map` provides, derived ones whose inputs it provides included.
pub fn provided(arena: std.mem.Allocator, vocab: *const Vocab, map: Map) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (vocab.names, vocab.ratio) |n, r| {
        const direct = map.map.contains(n);
        const derived = if (r) |idx| map.map.contains(vocab.names[idx[0]]) and map.map.contains(vocab.names[idx[1]]) else false;
        if (direct or derived) try out.append(arena, n);
    }
    return out.items;
}

/// The value at dotted `path` in `doc` (a numeric segment indexes an array).
fn at(doc: std.json.Value, path: []const u8) ?std.json.Value {
    var v = doc;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        v = switch (v) {
            .object => |o| o.get(seg) orelse return null,
            .array => |arr| blk: {
                const i = std.fmt.parseInt(usize, seg, 10) catch return null;
                if (i >= arr.items.len) return null;
                break :blk arr.items[i];
            },
            else => return null,
        };
    }
    return v;
}

fn number(v: std.json.Value) ?f64 {
    const x: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(x)) x else null;
}

/// One value per vocabulary fact; null = unknown.
pub const Values = []const ?f64;

/// Read `map` out of `doc`: each fact's paths, then each derivation still
/// unknown whose inputs are known. A value of the wrong kind for its type
/// (a fraction for an integer type, a negative count) is unknown.
pub fn read(arena: std.mem.Allocator, vocab: *const Vocab, map: Map, doc: std.json.Value) !Values {
    const out = try arena.alloc(?f64, vocab.names.len);
    @memset(out, null);
    for (map.map.keys(), map.map.values()) |name, paths| {
        const i = vocab.index(name) orelse continue;
        var sum: ?f64 = null;
        for (paths.list) |p| if (at(doc, p)) |v| if (number(v)) |x| {
            sum = (sum orelse 0) + x;
        };
        out[i] = fit(vocab.decls[i].type, sum);
    }
    for (vocab.ratio, 0..) |r, i| {
        const idx = r orelse continue;
        if (out[i] != null) continue;
        const num = out[idx[0]] orelse continue;
        const den = out[idx[1]] orelse continue;
        if (den <= 0) continue;
        out[i] = fit(vocab.decls[i].type, @round(1000 * num / den) / 10);
    }
    return out;
}

fn fit(ty: FactType, v: ?f64) ?f64 {
    const x = v orelse return null;
    if (ty != .int and x < 0) return null;
    if (ty.integral() and @floor(x) != x) return null;
    return x;
}

/// The known values as a JSON object (integer types as integers).
pub fn toJson(arena: std.mem.Allocator, vocab: *const Vocab, values: Values) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (vocab.names, vocab.decls, values) |n, d, v| {
        const x = v orelse continue;
        try obj.put(arena, n, if (d.type.integral() and @abs(x) < 9e15) .{ .integer = @intFromFloat(x) } else .{ .float = x });
    }
    return .{ .object = obj };
}

/// The known facts that carry a `compact` label, as `label 14%, label 98%`
/// in vocabulary order; null when none is known.
pub fn compactLine(arena: std.mem.Allocator, vocab: *const Vocab, values: Values) !?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var any = false;
    for (vocab.decls, values) |d, v| {
        const label = d.compact orelse continue;
        const x = v orelse continue;
        if (any) try w.writeAll(", ");
        any = true;
        try w.print("{s} ", .{label});
        switch (d.type) {
            .percent => if (@floor(x) == x) try w.print("{d}%", .{x}) else try w.print("{d:.1}%", .{x}),
            .usd => try w.print("${d:.2}", .{x}),
            .int, .tokens, .unix_time => try w.print("{d}", .{x}),
        }
    }
    return if (any) aw.written() else null;
}

/// `doc` (a source's JSON text) read through `map`; null when it is not JSON.
pub fn readText(arena: std.mem.Allocator, vocab: *const Vocab, map: Map, text: []const u8) !?Values {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    return try read(arena, vocab, map, doc);
}

// ── files read over a host probe ─────────────────────────────────

/// Marker of one facts file in a host probe's output.
const PROBE_MARK = "SKFACT ";

/// One facts file a host probe prints, for agent `id` (plain id chars).
pub const ProbeFile = struct { id: []const u8, path: []const u8 };

/// POSIX sh printing each file as `SKFACT <id> <content on one line>`
/// (line breaks dropped, which JSON allows; nothing after the id when the
/// file is missing).
pub fn probeScript(arena: std.mem.Allocator, files: []const ProbeFile) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (files) |f| {
        try s.print(arena, "printf '%s ' '" ++ PROBE_MARK ++ "{s}'; tr -d '\\r\\n' 2>/dev/null < ", .{f.id});
        try shellquote.appendQuoted(&s, arena, f.path);
        try s.appendSlice(arena, "; echo\n");
    }
    return s.items;
}

/// The content the probe printed for `id`: null when no line names it, ""
/// when the file was missing.
pub fn probeContent(output: []const u8, id: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const mark = std.mem.indexOf(u8, line, PROBE_MARK) orelse continue;
        const rest = line[mark + PROBE_MARK.len ..];
        if (!std.mem.startsWith(u8, rest, id)) continue;
        const after = rest[id.len..];
        if (after.len == 0) return "";
        if (after[0] != ' ') continue;
        return std.mem.trim(u8, after[1..], " ");
    }
    return null;
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

/// A Claude Code status line document after one answer (2.1.288, paths anonymised).
pub const CLAUDE_SAMPLE = @embedFile("testdata/claude-statusline.json");
/// The same before the first prompt: usage and percentages null, no rate limits.
pub const CLAUDE_SAMPLE_FRESH =
    \\{"session_id":"s","cwd":"/w","model":{"id":"claude-haiku-4-5","display_name":"Haiku 4.5"},"version":"2.1.288","cost":{"total_cost_usd":0,"total_duration_ms":5},"context_window":{"total_input_tokens":0,"total_output_tokens":0,"context_window_size":200000,"current_usage":null,"used_percentage":null,"remaining_percentage":null},"exceeds_200k_tokens":false}
;

fn testMap(a: std.mem.Allocator, json: []const u8) !Map {
    return std.json.parseFromSliceLeaky(Map, a, json, .{ .allocate = .alloc_always });
}

test "the shipped vocabulary validates" {
    const v = try shipped();
    try t.expect(v.index("context_used_percent") != null);
    try t.expect(v.ratio[v.index("context_used_percent").?] != null);
    try t.expectEqual(FactType.tokens, v.decls[v.index("context_window_tokens").?].type);
}

test "vocabulary problems: bad names, a derivation from nothing or from a derived fact" {
    const cases = [_]struct { json: []const u8, needle: []const u8 }{
        .{ .json = "{\"facts\":{\"Bad\":{\"type\":\"int\",\"meaning\":\"x\"}}}", .needle = "fact name \"Bad\"" },
        .{ .json = "{\"facts\":{\"a\":{\"type\":\"bytes\",\"meaning\":\"x\"}}}", .needle = "InvalidEnumTag" },
        .{ .json = "{\"facts\":{\"a\":{\"type\":\"percent\",\"meaning\":\"x\",\"derive\":{\"ratio\":[\"b\",\"c\"]}}}}", .needle = "unknown fact \"b\"" },
        .{ .json = "{\"facts\":{\"a\":{\"type\":\"int\",\"meaning\":\"x\",\"derive\":{\"ratio\":[\"a\",\"a\"]}}}}", .needle = "a ratio derives a percent" },
        .{ .json = "{\"facts\":{\"b\":{\"type\":\"int\",\"meaning\":\"x\"},\"a\":{\"type\":\"percent\",\"meaning\":\"x\",\"derive\":{\"ratio\":[\"b\",\"c\"]}},\"c\":{\"type\":\"percent\",\"meaning\":\"x\",\"derive\":{\"ratio\":[\"b\",\"b\"]}}}}", .needle = "which is derived itself" },
        .{ .json = "{\"facts\":{\"a\":{\"type\":\"int\",\"meaning\":\"x\",\"extra\":1}}}", .needle = "UnknownField" },
    };
    for (cases) |cs| {
        var problem: ?[]u8 = null;
        try t.expectError(error.InvalidFacts, parse(t.allocator, cs.json, &problem));
        defer t.allocator.free(problem.?);
        if (std.mem.indexOf(u8, problem.?, cs.needle) == null) {
            std.debug.print("problem: {s}\n", .{problem.?});
            return error.TestUnexpectedProblem;
        }
    }
}

test "an unknown fact name in a mapping is refused; provided includes derivations" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try shipped();
    const bad = try testMap(a, "{\"context_percent\":\"x.y\"}");
    try t.expect(std.mem.indexOf(u8, (try mapProblem(a, v, bad)).?, "\"context_percent\" is not a fact") != null);
    try t.expect((try mapProblem(a, v, try testMap(a, "{\"cost_usd\":\"a..b\"}"))) != null);
    try t.expect((try mapProblem(a, v, try testMap(a, "{\"cost_usd\":[]}"))) != null);
    const tokens_only = try testMap(a, "{\"context_used_tokens\":[\"a\",\"b\"],\"context_window_tokens\":\"c\"}");
    try t.expect((try mapProblem(a, v, tokens_only)) == null);
    const names = try provided(a, v, tokens_only);
    try t.expectEqual(@as(usize, 3), names.len);
    try t.expectEqualStrings("context_used_percent", names[0]);
}

test "paths read numbers; null, absent and wrong kinds are unknown, never 0" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try shipped();
    const map = try testMap(a,
        \\{"context_used_percent":"context_window.used_percentage","context_window_tokens":"context_window.context_window_size",
        \\ "context_used_tokens":["context_window.current_usage.input_tokens","context_window.current_usage.cache_creation_input_tokens","context_window.current_usage.cache_read_input_tokens"],
        \\ "rate_5h_used_percent":"rate_limits.five_hour.used_percentage","rate_5h_resets_at":"rate_limits.five_hour.resets_at",
        \\ "rate_7d_used_percent":"rate_limits.seven_day.used_percentage","rate_7d_resets_at":"rate_limits.seven_day.resets_at","cost_usd":"cost.total_cost_usd"}
    );
    try t.expect((try mapProblem(a, v, map)) == null);
    const after = (try readText(a, v, map, CLAUDE_SAMPLE)).?;
    try t.expectEqual(@as(f64, 14), after[v.index("context_used_percent").?].?);
    try t.expectEqual(@as(f64, 200000), after[v.index("context_window_tokens").?].?);
    try t.expectEqual(@as(f64, 27656), after[v.index("context_used_tokens").?].?);
    try t.expectEqual(@as(f64, 98), after[v.index("rate_7d_used_percent").?].?);
    try t.expectEqual(@as(f64, 0), after[v.index("rate_5h_used_percent").?].?);
    try t.expectEqual(@as(f64, 1791169200), after[v.index("rate_7d_resets_at").?].?);
    try t.expectEqual(@as(f64, 0.056479), after[v.index("cost_usd").?].?);
    const json = try std.json.Stringify.valueAlloc(a, try toJson(a, v, after), .{});
    try t.expect(std.mem.indexOf(u8, json, "\"context_used_percent\":14") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"rate_7d_resets_at\":1791169200") != null);

    // Before the first prompt: no usage, no rate limits, but a window size.
    // The percent is null and its derivation has no used tokens: unknown.
    const fresh = (try readText(a, v, map, CLAUDE_SAMPLE_FRESH)).?;
    try t.expect(fresh[v.index("context_used_percent").?] == null);
    try t.expect(fresh[v.index("context_used_tokens").?] == null);
    try t.expect(fresh[v.index("rate_7d_used_percent").?] == null);
    try t.expectEqual(@as(f64, 200000), fresh[v.index("context_window_tokens").?].?);
    try t.expectEqual(@as(f64, 0), fresh[v.index("cost_usd").?].?);
    try t.expectEqualStrings("context 14%, 7d limit 98%", (try compactLine(a, v, after)).?);
    try t.expect((try compactLine(a, v, fresh)) == null);
    const fjson = try std.json.Stringify.valueAlloc(a, try toJson(a, v, fresh), .{});
    try t.expect(std.mem.indexOf(u8, fjson, "context_used_percent") == null);
    try t.expect(std.mem.indexOf(u8, fjson, "rate_") == null);

    // A fraction where tokens go, a string, a negative count: unknown.
    const odd = (try readText(a, v, map, "{\"context_window\":{\"context_window_size\":1.5,\"used_percentage\":\"14\",\"current_usage\":{\"input_tokens\":-3}}}")).?;
    try t.expect(odd[v.index("context_window_tokens").?] == null);
    try t.expect(odd[v.index("context_used_percent").?] == null);
    try t.expect(odd[v.index("context_used_tokens").?] == null);
    try t.expect((try readText(a, v, map, "not json")) == null);
}

test "a percent no path gives is derived from used and window tokens" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try shipped();
    const map = try testMap(a, "{\"context_used_tokens\":[\"m.tokens.input\",\"m.tokens.cache.read\",\"m.tokens.cache.write\"],\"context_window_tokens\":\"model.limit.context\"}");
    const vals = (try readText(a, v, map, "{\"m\":{\"tokens\":{\"input\":1000,\"cache\":{\"read\":40000}}},\"model\":{\"limit\":{\"context\":128000}}}")).?;
    try t.expectEqual(@as(f64, 41000), vals[v.index("context_used_tokens").?].?);
    try t.expectEqual(@as(f64, 32.0), vals[v.index("context_used_percent").?].?);
    // Without the window size there is nothing to derive from.
    const no_limit = (try readText(a, v, map, "{\"m\":{\"tokens\":{\"input\":1000}}}")).?;
    try t.expect(no_limit[v.index("context_used_percent").?] == null);
}

test "probe lines carry each file's content, a missing file reads empty" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&tmp_buf, "/tmp/.sk_facts_test_{d}", .{@import("../c.zig").c.getpid()});
    const pathz = @import("../util/pathz.zig");
    defer pathz.removeTree(dir);
    const file = try std.fmt.allocPrint(a, "{s}/it's here.json", .{dir});
    try pathz.makeParentDirs(file);
    try @import("../util/atomicwrite.zig").writeFile(file, "{\"a\":\n1}\r\n", 0o600);
    const script = try probeScript(a, &.{ .{ .id = "claude-ab12", .path = file }, .{ .id = "claude-cd34", .path = "/nonexistent/x.json" } });
    const out = try @import("launch.zig").runSh(a, "", script);
    try t.expectEqualStrings("{\"a\":1}", probeContent(out, "claude-ab12").?);
    try t.expectEqualStrings("", probeContent(out, "claude-cd34").?);
    try t.expect(probeContent(out, "claude-ab1") == null);
    try t.expect(probeContent("noise SKFACT claude-x {}\r\n", "claude-x") != null);
}
