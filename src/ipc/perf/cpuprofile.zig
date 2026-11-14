//! Summary of a V8 `.cpuprofile` (CDP `Profiler.Profile`): time buckets and the top functions by self and total time.
//!
//! A sample lasts until the next one (DevTools' convention: sample i is
//! charged `timeDeltas[i+1]`, the last one `endTime` minus its timestamp).
//! Total time counts a function once per stack, so recursion is not double-counted.
//! Lines and columns in `Fn` are 1-based; CDP and source maps are 0-based.

const std = @import("std");

pub const Fn = struct {
    function: []const u8,
    url: []const u8,
    /// 1-based; 0 when the engine reported none.
    line: u32,
    column: u32,
    self_us: u64 = 0,
    total_us: u64 = 0,
};

pub const Summary = struct {
    duration_us: u64,
    sample_count: usize,
    /// Mean sampling interval actually observed.
    interval_us: u64,
    idle_us: u64,
    program_us: u64,
    gc_us: u64,
    script_us: u64,
    /// Every function with samples, self time descending.
    by_self: []Fn,
    /// The same functions, total time descending.
    by_total: []Fn,

    /// Busy (non-idle) time, the base of the percentages.
    pub fn busyUs(self: Summary) u64 {
        return self.program_us + self.gc_us + self.script_us;
    }
};

const CallFrame = struct {
    functionName: []const u8 = "",
    url: []const u8 = "",
    lineNumber: i64 = -1,
    columnNumber: i64 = -1,
};

const Node = struct {
    id: i64,
    callFrame: CallFrame = .{},
    children: []const i64 = &.{},
};

const Profile = struct {
    nodes: []const Node,
    startTime: i64 = 0,
    endTime: i64 = 0,
    samples: []const i64 = &.{},
    timeDeltas: []const i64 = &.{},
};

const Special = enum { none, root, idle, program, gc };

fn special(name: []const u8, url: []const u8) Special {
    if (url.len != 0) return .none;
    if (std.mem.eql(u8, name, "(root)")) return .root;
    if (std.mem.eql(u8, name, "(idle)")) return .idle;
    if (std.mem.eql(u8, name, "(program)")) return .program;
    if (std.mem.eql(u8, name, "(garbage collector)")) return .gc;
    return .none;
}

/// Summarize `json`, a `.cpuprofile` or a `{"profile":...}` wrapper; all memory comes from `arena`.
pub fn summarize(arena: std.mem.Allocator, json: []const u8) !Summary {
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    const profile = std.json.parseFromSliceLeaky(Profile, arena, json, opts) catch blk: {
        const Wrapped = struct { profile: Profile };
        const w = std.json.parseFromSliceLeaky(Wrapped, arena, json, opts) catch return error.NotAProfile;
        break :blk w.profile;
    };
    if (profile.nodes.len == 0) return error.NotAProfile;

    // Dense node index and parent links.
    var index: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    try index.ensureTotalCapacity(arena, @intCast(profile.nodes.len));
    for (profile.nodes, 0..) |n, i| index.putAssumeCapacity(n.id, @intCast(i));
    const parent = try arena.alloc(i32, profile.nodes.len);
    @memset(parent, -1);
    for (profile.nodes, 0..) |n, i| for (n.children) |child| {
        if (index.get(child)) |ci| parent[ci] = @intCast(i);
    };

    // Self time per node.
    const node_self = try arena.alloc(u64, profile.nodes.len);
    @memset(node_self, 0);
    const n_samples = @min(profile.samples.len, profile.timeDeltas.len);
    var ts: i64 = profile.startTime;
    var last_ts: i64 = profile.startTime;
    for (0..n_samples) |i| {
        ts += profile.timeDeltas[i];
        if (i == n_samples - 1) last_ts = ts;
    }
    for (0..n_samples) |i| {
        const dur: i64 = if (i + 1 < n_samples) profile.timeDeltas[i + 1] else profile.endTime - last_ts;
        const ni = index.get(profile.samples[i]) orelse continue;
        node_self[ni] += @intCast(@max(dur, 0));
    }

    // One aggregate per (function, url, line, column).
    var keys: std.StringHashMapUnmanaged(u32) = .empty;
    var fns: std.ArrayList(Fn) = .empty;
    const node_fn = try arena.alloc(i32, profile.nodes.len);
    var sum: Summary = .{ .duration_us = 0, .sample_count = n_samples, .interval_us = 0, .idle_us = 0, .program_us = 0, .gc_us = 0, .script_us = 0, .by_self = &.{}, .by_total = &.{} };
    for (profile.nodes, 0..) |n, i| {
        const cf = n.callFrame;
        switch (special(cf.functionName, cf.url)) {
            .root => {
                node_fn[i] = -1;
                continue;
            },
            .idle => sum.idle_us += node_self[i],
            .program => sum.program_us += node_self[i],
            .gc => sum.gc_us += node_self[i],
            .none => sum.script_us += node_self[i],
        }
        if (special(cf.functionName, cf.url) != .none) {
            node_fn[i] = -1;
            continue;
        }
        const line: u32 = if (cf.lineNumber >= 0) @intCast(cf.lineNumber + 1) else 0;
        const column: u32 = if (cf.columnNumber >= 0) @intCast(cf.columnNumber + 1) else 0;
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{d}\x00{d}", .{ cf.functionName, cf.url, line, column });
        const gop = try keys.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(fns.items.len);
            try fns.append(arena, .{ .function = cf.functionName, .url = cf.url, .line = line, .column = column });
        }
        node_fn[i] = @intCast(gop.value_ptr.*);
        fns.items[gop.value_ptr.*].self_us += node_self[i];
    }

    // Total: each node's self time reaches every DISTINCT function on its stack once.
    const seen = try arena.alloc(u32, fns.items.len);
    @memset(seen, 0);
    var stamp: u32 = 0;
    for (node_self, 0..) |self_us, i| {
        if (self_us == 0) continue;
        stamp += 1;
        var at: i32 = @intCast(i);
        var guard: usize = 0;
        while (at >= 0 and guard <= profile.nodes.len) : (guard += 1) {
            const f = node_fn[@intCast(at)];
            if (f >= 0 and seen[@intCast(f)] != stamp) {
                seen[@intCast(f)] = stamp;
                fns.items[@intCast(f)].total_us += self_us;
            }
            at = parent[@intCast(at)];
        }
    }

    sum.duration_us = @intCast(@max(profile.endTime - profile.startTime, 0));
    sum.interval_us = if (n_samples > 0) sum.duration_us / n_samples else 0;
    var sampled: std.ArrayList(Fn) = .empty;
    for (fns.items) |f| if (f.total_us > 0) try sampled.append(arena, f);
    sum.by_self = sampled.items;
    std.mem.sort(Fn, sum.by_self, {}, struct {
        fn lt(_: void, a: Fn, b: Fn) bool {
            return if (a.self_us != b.self_us) a.self_us > b.self_us else a.total_us > b.total_us;
        }
    }.lt);
    sum.by_total = try arena.dupe(Fn, sum.by_self);
    std.mem.sort(Fn, sum.by_total, {}, struct {
        fn lt(_: void, a: Fn, b: Fn) bool {
            return if (a.total_us != b.total_us) a.total_us > b.total_us else a.self_us > b.self_us;
        }
    }.lt);
    return sum;
}

test "self, total, buckets and recursion of a fixture profile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // root -> main -> hot -> hot (recursion); main -> cold; root -> (idle), (program), (garbage collector)
    const fixture =
        \\{"nodes":[
        \\{"id":1,"callFrame":{"functionName":"(root)","scriptId":"0","url":"","lineNumber":-1,"columnNumber":-1},"children":[2,6,7,8]},
        \\{"id":2,"callFrame":{"functionName":"main","scriptId":"3","url":"https://x.test/a.js","lineNumber":0,"columnNumber":10},"children":[3,5]},
        \\{"id":3,"callFrame":{"functionName":"hot","scriptId":"3","url":"https://x.test/a.js","lineNumber":4,"columnNumber":0},"children":[4]},
        \\{"id":4,"callFrame":{"functionName":"hot","scriptId":"3","url":"https://x.test/a.js","lineNumber":4,"columnNumber":0}},
        \\{"id":5,"callFrame":{"functionName":"cold","scriptId":"3","url":"https://x.test/a.js","lineNumber":9,"columnNumber":2}},
        \\{"id":6,"callFrame":{"functionName":"(idle)","scriptId":"0","url":"","lineNumber":-1,"columnNumber":-1}},
        \\{"id":7,"callFrame":{"functionName":"(program)","scriptId":"0","url":"","lineNumber":-1,"columnNumber":-1}},
        \\{"id":8,"callFrame":{"functionName":"(garbage collector)","scriptId":"0","url":"","lineNumber":-1,"columnNumber":-1}}],
        \\"startTime":1000,"endTime":1800,
        \\"samples":[3,4,4,5,6,7,8,2],
        \\"timeDeltas":[0,100,100,100,100,100,100,100]}
    ;
    const s = try summarize(arena, fixture);
    // Sample i lasts timeDeltas[i+1]; the last one runs to endTime (1700 -> 1800).
    try std.testing.expectEqual(@as(usize, 8), s.sample_count);
    try std.testing.expectEqual(@as(u64, 800), s.duration_us);
    try std.testing.expectEqual(@as(u64, 100), s.idle_us);
    try std.testing.expectEqual(@as(u64, 100), s.program_us);
    try std.testing.expectEqual(@as(u64, 100), s.gc_us);
    try std.testing.expectEqual(@as(u64, 500), s.script_us);
    try std.testing.expectEqualStrings("hot", s.by_self[0].function);
    try std.testing.expectEqual(@as(u64, 300), s.by_self[0].self_us);
    // Recursion: hot's total is its own 300, never 300 + the inner frames again.
    try std.testing.expectEqual(@as(u64, 300), s.by_self[0].total_us);
    try std.testing.expectEqual(@as(u32, 5), s.by_self[0].line);
    try std.testing.expectEqual(@as(u32, 1), s.by_self[0].column);
    try std.testing.expectEqualStrings("main", s.by_total[0].function);
    try std.testing.expectEqual(@as(u64, 500), s.by_total[0].total_us);
    try std.testing.expectEqual(@as(u64, 100), s.by_total[0].self_us);
    try std.testing.expectEqual(@as(usize, 3), s.by_self.len);
    // The CDP wrapper is accepted too; anything else is refused.
    const wrapped = try std.fmt.allocPrint(arena, "{{\"profile\":{s}}}", .{fixture});
    try std.testing.expectEqual(@as(u64, 300), (try summarize(arena, wrapped)).by_self[0].self_us);
    try std.testing.expectError(error.NotAProfile, summarize(arena, "{\"nodes\":[]}"));
    try std.testing.expectError(error.NotAProfile, summarize(arena, "not json"));
}
