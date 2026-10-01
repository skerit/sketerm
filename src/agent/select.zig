//! What the read side hands back of a sub-agent's work, and when a
//! finished stretch of it wakes the caller: the ONE home of both rules.
//!
//! The unit is the JOB: one user prompt (whoever typed it) and everything
//! the agent does until the next one, turns it starts on its own (a
//! background task waking it) included. A job's SEGMENT is a stretch of
//! activity that ends with the agent going idle, the moment a source
//! pushes `done`; its last assistant message then is the segment's FINAL
//! (`Record.segment_final`), every other one is intermediate.
//!
//! A job's selection: its last assistant message always, every other
//! segment final of at least `FINAL_MIN_CHARS`, any message of at least
//! `LONG_MIN_CHARS`, every notice, tool records only on request, never a
//! user prompt (the caller sent it). The rest is counted, never listed.

const std = @import("std");
const vocab = @import("vocab.zig");
const output = @import("output.zig");

const Record = output.Record;

/// Calibrated over 489 real Claude Code sessions: intermediate messages
/// have a median of 137 chars (15.8% reach 300, 3.1% reach 1500), finals
/// that answer a prompt a median of 2016 (86.5% reach 300), wake-segment
/// finals a median of 351, and in 162 of 860 multi-segment jobs the last
/// final was under 300 after an earlier final of 300 or more. The long
/// intermediates sampled were summaries written right before a trailing
/// tool call (a memory save, scheduling), hence `LONG_MIN_CHARS`.
pub const FINAL_MIN_CHARS: usize = 300;
pub const LONG_MIN_CHARS: usize = 1500;
/// Characters of record text one selected read returns at most; the
/// newest job's last message is returned whole even beyond it.
pub const READ_CAP_CHARS: usize = 12_000;

pub const Detail = enum {
    /// Per job: the selection, the rest counted.
    selected,
    /// Every assistant message and notice (tools on request).
    all,
};

/// Characters as a reader counts them: code points, bytes when not UTF-8.
pub fn chars(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Rules 2 and 3: an assistant message returned (and woken for) besides
/// the job's last one.
pub fn substantive(r: Record) bool {
    if (r.kind != .assistant) return false;
    const n = chars(r.text);
    return n >= LONG_MIN_CHARS or (r.segment_final and n >= FINAL_MIN_CHARS);
}

/// Whether a record of `kind` is ever returned.
pub fn visible(kind: vocab.RecordKind, include_tools: bool) bool {
    return switch (kind) {
        .user => false,
        .assistant, .notice => true,
        .tool => include_tools,
    };
}

fn lastMessage(records: []const Record, job: u32) ?usize {
    var i = records.len;
    while (i > 0) {
        i -= 1;
        if (records[i].job == job and records[i].kind == .assistant) return i;
    }
    return null;
}

/// The job's answer: its most recent selected message of at least
/// `FINAL_MIN_CHARS`, else its last message ("" when it has none).
pub fn answer(records: []const Record, job: u32) []const u8 {
    const last = lastMessage(records, job) orelse return "";
    var i = last + 1;
    while (i > 0) {
        i -= 1;
        const r = records[i];
        if (r.job != job or r.kind != .assistant) continue;
        if ((i == last or substantive(r)) and chars(r.text) >= FINAL_MIN_CHARS) return r.text;
    }
    return records[last].text;
}

pub const SegmentEnd = struct {
    /// Push the `done` (the first of a job, or one that brought a new
    /// substantive message).
    wake: bool,
    /// The done's text: `answer` of the job. Borrowed from the records.
    answer: []const u8,
};

/// A source's memory of its latest segment end, for the re-wake rule.
pub const Waker = struct {
    job: ?u32 = null,
    /// The highest record id at that segment end.
    mark: u64 = 0,

    /// `job`'s segment ended: flag its last message as the segment final
    /// and decide whether the done wakes the caller.
    /// @param records the source's records, chronological.
    pub fn segmentEnd(self: *Waker, records: []Record, job: u32) SegmentEnd {
        if (lastMessage(records, job)) |i| records[i].segment_final = true;
        var wake = self.job == null or self.job.? != job;
        var high = self.mark;
        for (records) |r| {
            high = @max(high, r.id);
            if (!wake and r.job == job and r.id > self.mark and substantive(r)) wake = true;
        }
        self.job = job;
        self.mark = high;
        return .{ .wake = wake, .answer = answer(records, job) };
    }
};

/// Which jobs one read covers.
pub const Jobs = struct {
    /// Ascending.
    list: []u32,
    /// Nothing was newer than the cursor: `list` is the latest job alone.
    fallback: bool,
};

/// The jobs holding a record above `since`, or the latest job when none
/// does (no jobs without records).
pub fn jobsAfter(alloc: std.mem.Allocator, records: []const Record, since: u64) !Jobs {
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(alloc);
    var latest: ?u32 = null;
    for (records) |r| {
        latest = if (latest) |l| @max(l, r.job) else r.job;
        if (r.id <= since) continue;
        if (std.mem.indexOfScalar(u32, list.items, r.job) == null) try list.append(alloc, r.job);
    }
    const fallback = list.items.len == 0;
    if (fallback) if (latest) |l| try list.append(alloc, l);
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    return .{ .list = try list.toOwnedSlice(alloc), .fallback = fallback };
}

pub const Options = struct {
    detail: Detail = .selected,
    include_tools: bool = false,
    /// `selected` only.
    cap: usize = READ_CAP_CHARS,
    /// `all` only: records returned at most.
    limit: usize = std.math.maxInt(usize),
    /// `all` only: records at or below it are not returned (unless the
    /// jobs are a fallback).
    since: u64 = 0,
};

/// What a job had that the selection does not list.
pub const JobSummary = struct {
    job: u32,
    omitted_messages: u32 = 0,
    omitted_tools: u32 = 0,
};

pub const Selection = struct {
    /// Indices into the records: chronological for `selected`, by id for
    /// `all`.
    picked: []usize,
    /// One per job, ascending.
    jobs: []JobSummary,
    /// Ids of selected records the cap left out, by id.
    cut: []u64,
    /// `all`: records beyond `limit` remain.
    more: bool = false,

    pub fn deinit(self: Selection, alloc: std.mem.Allocator) void {
        alloc.free(self.picked);
        alloc.free(self.jobs);
        alloc.free(self.cut);
    }
};

/// What one read returns of `jobs` (from `jobsAfter`).
/// @param records the source's records, chronological.
pub fn select(alloc: std.mem.Allocator, records: []const Record, jobs: Jobs, opts: Options) !Selection {
    const summaries = try alloc.alloc(JobSummary, jobs.list.len);
    errdefer alloc.free(summaries);
    for (jobs.list, summaries) |j, *s| s.* = .{ .job = j };
    var picked: std.ArrayList(usize) = .empty;
    errdefer picked.deinit(alloc);
    var cut: std.ArrayList(u64) = .empty;
    errdefer cut.deinit(alloc);
    var more = false;

    for (summaries) |*s| {
        const last = lastMessage(records, s.job);
        for (records, 0..) |r, i| {
            if (r.job != s.job) continue;
            // `all` pages by id: what is at or below `since` was read.
            if (opts.detail == .all and !jobs.fallback and r.id <= opts.since) continue;
            const take = visible(r.kind, opts.include_tools) and switch (opts.detail) {
                .selected => r.kind != .assistant or i == last or substantive(r),
                .all => true,
            };
            if (take) {
                try picked.append(alloc, i);
            } else if (r.kind == .assistant) {
                s.omitted_messages += 1;
            } else if (r.kind == .tool and !opts.include_tools) {
                s.omitted_tools += 1;
            }
        }
    }

    switch (opts.detail) {
        .selected => try applyCap(alloc, records, &picked, &cut, if (summaries.len > 0) lastMessage(records, summaries[summaries.len - 1].job) else null, opts.cap),
        .all => {
            std.mem.sort(usize, picked.items, records, struct {
                fn lt(rs: []const Record, a: usize, b: usize) bool {
                    return rs[a].id < rs[b].id;
                }
            }.lt);
            if (picked.items.len > opts.limit) {
                more = true;
                picked.shrinkRetainingCapacity(opts.limit);
            }
        },
    }
    return .{
        .picked = try picked.toOwnedSlice(alloc),
        .jobs = summaries,
        .cut = try cut.toOwnedSlice(alloc),
        .more = more,
    };
}

/// Keep `keep` whole, then the longest other picks that still fit `cap`;
/// what does not fit moves to `cut`.
fn applyCap(alloc: std.mem.Allocator, records: []const Record, picked: *std.ArrayList(usize), cut: *std.ArrayList(u64), keep: ?usize, cap: usize) !void {
    var budget: usize = cap;
    if (keep) |k| budget -|= chars(records[k].text);
    const order = try alloc.dupe(usize, picked.items);
    defer alloc.free(order);
    std.mem.sort(usize, order, records, struct {
        fn longer(rs: []const Record, a: usize, b: usize) bool {
            const ca = chars(rs[a].text);
            const cb = chars(rs[b].text);
            return if (ca != cb) ca > cb else a < b;
        }
    }.longer);
    var dropped: std.ArrayList(usize) = .empty;
    defer dropped.deinit(alloc);
    for (order) |i| {
        if (keep != null and i == keep.?) continue;
        const n = chars(records[i].text);
        if (n <= budget) {
            budget -= n;
        } else try dropped.append(alloc, i);
    }
    if (dropped.items.len == 0) return;
    var w: usize = 0;
    for (picked.items) |i| {
        if (std.mem.indexOfScalar(usize, dropped.items, i) != null) {
            try cut.append(alloc, records[i].id);
        } else {
            picked.items[w] = i;
            w += 1;
        }
    }
    picked.shrinkRetainingCapacity(w);
    std.mem.sort(u64, cut.items, {}, std.sort.asc(u64));
}

// -- tests --

const t = std.testing;

/// Test records: `text` borrowed (never freed here).
fn rec(id: u64, job: u32, kind: vocab.RecordKind, text: []const u8) Record {
    return .{ .id = id, .kind = kind, .text = @constCast(text), .job = job };
}

fn filled(comptime n: usize, comptime ch: u8) []const u8 {
    return &([_]u8{ch} ** n);
}

fn pickedIds(records: []const Record, sel: Selection) ![]u64 {
    const out = try t.allocator.alloc(u64, sel.picked.len);
    for (sel.picked, out) |i, *o| o.* = records[i].id;
    return out;
}

test "the motivating job: a long summary, then a trivial wake reply; both kept, no prompt echoed, the rest counted" {
    const summary = filled(900, 's');
    var records = [_]Record{
        rec(1, 0, .user, "summarize vocab.zig, ignore wakeups"),
        rec(2, 0, .tool, "Bash (sleep 20)"),
        rec(3, 0, .assistant, "Let me read the file first."),
        rec(4, 0, .tool, "Read 1 file"),
        rec(5, 0, .assistant, summary),
        rec(6, 0, .notice, "Background command completed (exit code 0)"),
        rec(7, 0, .assistant, "ignoring wakeup."),
    };
    var w: Waker = .{};
    const first = w.segmentEnd(records[0..5], 0);
    try t.expect(first.wake);
    try t.expectEqualStrings(summary, first.answer);
    try t.expect(records[4].segment_final);
    // The wake segment: a trivial reply does not wake the caller again,
    // and the job's answer stays the summary.
    const later = w.segmentEnd(&records, 0);
    try t.expect(!later.wake);
    try t.expectEqualStrings(summary, later.answer);
    try t.expect(records[6].segment_final);

    const jobs = try jobsAfter(t.allocator, &records, 0);
    defer t.allocator.free(jobs.list);
    const sel = try select(t.allocator, &records, jobs, .{});
    defer sel.deinit(t.allocator);
    const ids = try pickedIds(&records, sel);
    defer t.allocator.free(ids);
    try t.expectEqualSlices(u64, &.{ 5, 6, 7 }, ids);
    try t.expectEqual(@as(usize, 1), sel.jobs.len);
    try t.expectEqual(@as(u32, 1), sel.jobs[0].omitted_messages);
    try t.expectEqual(@as(u32, 2), sel.jobs[0].omitted_tools);
    try t.expectEqual(@as(usize, 0), sel.cut.len);
}

test "rule 3: a long intermediate is kept, a short one is not, a short earlier final is not" {
    var records = [_]Record{
        rec(1, 0, .assistant, filled(1600, 'a')),
        rec(2, 0, .tool, "memory save"),
        rec(3, 0, .assistant, "short thought"),
        rec(4, 0, .assistant, "Done."),
    };
    records[2].segment_final = true;
    const jobs = try jobsAfter(t.allocator, &records, 0);
    defer t.allocator.free(jobs.list);
    const sel = try select(t.allocator, &records, jobs, .{});
    defer sel.deinit(t.allocator);
    const ids = try pickedIds(&records, sel);
    defer t.allocator.free(ids);
    try t.expectEqualSlices(u64, &.{ 1, 4 }, ids);
    // The answer is the long summary, not the trailing "Done.".
    try t.expectEqualStrings(records[0].text, answer(&records, 0));
}

test "re-wake: the first done always wakes, a substantive later one does, a trivial one does not" {
    var records = [_]Record{
        rec(1, 0, .assistant, "ok"),
        rec(2, 0, .assistant, "fine"),
        rec(3, 0, .assistant, filled(400, 'b')),
        rec(4, 1, .assistant, "x"),
    };
    var w: Waker = .{};
    // A trivial first done still wakes.
    try t.expect(w.segmentEnd(records[0..1], 0).wake);
    try t.expect(!w.segmentEnd(records[0..2], 0).wake);
    const s = w.segmentEnd(records[0..3], 0);
    try t.expect(s.wake);
    try t.expectEqualStrings(records[2].text, s.answer);
    // A new job's first done wakes whatever it says.
    try t.expect(w.segmentEnd(&records, 1).wake);
    // A long message that is not the final wakes too (rule 3).
    var w2: Waker = .{};
    var more = [_]Record{ rec(1, 0, .assistant, "a"), rec(2, 0, .assistant, filled(1500, 'c')), rec(3, 0, .assistant, "b") };
    _ = w2.segmentEnd(more[0..1], 0);
    try t.expect(w2.segmentEnd(&more, 0).wake);
}

test "the cap keeps the newest job's last message whole, then the longest that fit, and reports the cut" {
    var records = [_]Record{
        rec(1, 0, .assistant, filled(5000, 'a')),
        rec(2, 0, .assistant, filled(4000, 'b')),
        rec(3, 0, .notice, "compacted"),
        rec(4, 1, .assistant, filled(2000, 'c')),
        rec(5, 1, .assistant, filled(13000, 'd')),
    };
    records[0].segment_final = true;
    records[1].segment_final = true;
    const jobs = try jobsAfter(t.allocator, &records, 0);
    defer t.allocator.free(jobs.list);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, jobs.list);
    const sel = try select(t.allocator, &records, jobs, .{});
    defer sel.deinit(t.allocator);
    const ids = try pickedIds(&records, sel);
    defer t.allocator.free(ids);
    // 13000 alone exceeds the cap: kept whole, nothing else fits.
    try t.expectEqualSlices(u64, &.{5}, ids);
    try t.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, sel.cut);

    const roomy = try select(t.allocator, &records, jobs, .{ .cap = 13000 + 5000 + 2000 + 9 });
    defer roomy.deinit(t.allocator);
    const ids2 = try pickedIds(&records, roomy);
    defer t.allocator.free(ids2);
    // Longest first: 5000 fits, 4000 does not, 2000 and the notice do.
    try t.expectEqualSlices(u64, &.{ 1, 3, 4, 5 }, ids2);
    try t.expectEqualSlices(u64, &.{2}, roomy.cut);
}

test "tools only on request, notices always, user prompts never" {
    var records = [_]Record{
        rec(1, 0, .user, "do it"),
        rec(2, 0, .tool, "Bash (ls)"),
        rec(3, 0, .notice, "model set"),
        rec(4, 0, .assistant, "done"),
    };
    const jobs = try jobsAfter(t.allocator, &records, 0);
    defer t.allocator.free(jobs.list);
    for ([_]Detail{ .selected, .all }) |d| {
        const plain = try select(t.allocator, &records, jobs, .{ .detail = d });
        defer plain.deinit(t.allocator);
        const a = try pickedIds(&records, plain);
        defer t.allocator.free(a);
        try t.expectEqualSlices(u64, &.{ 3, 4 }, a);
        try t.expectEqual(@as(u32, 1), plain.jobs[0].omitted_tools);
        const tools = try select(t.allocator, &records, jobs, .{ .detail = d, .include_tools = true });
        defer tools.deinit(t.allocator);
        const b = try pickedIds(&records, tools);
        defer t.allocator.free(b);
        try t.expectEqualSlices(u64, &.{ 2, 3, 4 }, b);
        try t.expectEqual(@as(u32, 0), tools.jobs[0].omitted_tools);
    }
}

test "the read cursor: unread jobs, else the latest job; all honours since and limit" {
    var records = [_]Record{
        rec(1, 0, .user, "one"),
        rec(2, 0, .assistant, "first"),
        rec(3, 1, .user, "two"),
        rec(4, 1, .assistant, "second"),
        rec(5, 1, .assistant, "third"),
        rec(6, 2, .user, "three"),
        rec(7, 2, .assistant, "fourth"),
    };
    const unread = try jobsAfter(t.allocator, &records, 4);
    defer t.allocator.free(unread.list);
    try t.expectEqualSlices(u32, &.{ 1, 2 }, unread.list);
    try t.expect(!unread.fallback);
    const none = try jobsAfter(t.allocator, &records, 7);
    defer t.allocator.free(none.list);
    try t.expectEqualSlices(u32, &.{2}, none.list);
    try t.expect(none.fallback);
    const empty = try jobsAfter(t.allocator, records[0..0], 0);
    defer t.allocator.free(empty.list);
    try t.expectEqual(@as(usize, 0), empty.list.len);

    // `all` returns only what is above `since`, by id, paged by `limit`.
    const all = try select(t.allocator, &records, unread, .{ .detail = .all, .since = 4, .limit = 1 });
    defer all.deinit(t.allocator);
    const a = try pickedIds(&records, all);
    defer t.allocator.free(a);
    try t.expectEqualSlices(u64, &.{5}, a);
    try t.expect(all.more);
    // The fallback job is returned whole.
    const again = try select(t.allocator, &records, none, .{ .detail = .all, .since = 7 });
    defer again.deinit(t.allocator);
    const b = try pickedIds(&records, again);
    defer t.allocator.free(b);
    try t.expectEqualSlices(u64, &.{7}, b);
}

test "chars counts code points" {
    try t.expectEqual(@as(usize, 3), chars("a\xe2\x80\x94b"));
    try t.expectEqual(@as(usize, 2), chars("\xff\xfe"));
}
