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
//!
//! Delivery is per RECORD (`Handed`): a default read and every `done`
//! result return only selected records the assistant was not handed
//! before; a selected one it was handed is never repeated, a job says so
//! in one pointer (`JobSummary.earlier`). An explicit `since` or `all`
//! re-reads regardless. Record ids restart when a durable instance
//! reattaches (the app's transcript is read again), so the handed-out
//! state is not persisted: the first read after a reattach returns the
//! selection again.

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
/// A `done` waits while the agent sits idle with background tasks still
/// running, at most this long; then it fires with their count, so a
/// server left running on purpose never means silence forever.
pub const BACKGROUND_DONE_CAP_MS: i64 = 30 * 60_000;

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
    const i = answerIndex(records, job) orelse return "";
    return records[i].text;
}

/// The index of `answer`'s record, or null when the job has no message.
pub fn answerIndex(records: []const Record, job: u32) ?usize {
    const last = lastMessage(records, job) orelse return null;
    var i = last + 1;
    while (i > 0) {
        i -= 1;
        const r = records[i];
        if (r.job != job or r.kind != .assistant) continue;
        if ((i == last or substantive(r)) and chars(r.text) >= FINAL_MIN_CHARS) return i;
    }
    return last;
}

/// The record ids handed to the assistant, per agent.
pub const Handed = struct {
    ids: std.DynamicBitSetUnmanaged = .{},
    /// Content keys of handed-out records: a screen source can re-capture
    /// an unchanged record under a NEW id (Claude Code reprints its
    /// transcript below the old copy), and that must not be a new delivery.
    texts: std.AutoHashMapUnmanaged(u64, void) = .empty,

    /// Shorter texts are not deduplicated by content: two jobs may well
    /// both answer "Done.".
    pub const CONTENT_MIN_CHARS: usize = 80;

    pub fn deinit(self: *Handed, alloc: std.mem.Allocator) void {
        self.ids.deinit(alloc);
        self.texts.deinit(alloc);
    }

    /// A hash of the kind and the text with every whitespace run (spaces,
    /// tabs, newlines, NBSP) one space and both ends trimmed: Claude Code
    /// re-wraps a message when it reprints it at another width.
    fn contentKey(r: Record) ?u64 {
        if (r.kind == .user or r.text.len < CONTENT_MIN_CHARS) return null;
        var h = std.hash.Wyhash.init(@intFromEnum(r.kind));
        var gap = false;
        var started = false;
        var i: usize = 0;
        while (i < r.text.len) {
            const ch = r.text[i];
            const ws: usize = if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r')
                1
            else if (ch == 0xC2 and i + 1 < r.text.len and r.text[i + 1] == 0xA0)
                2
            else
                0;
            if (ws > 0) {
                gap = started;
                i += ws;
                continue;
            }
            if (gap) h.update(" ");
            gap = false;
            started = true;
            h.update(r.text[i .. i + 1]);
            i += 1;
        }
        return h.final();
    }

    /// Whether `r` was handed out, by id or by identical content.
    pub fn has(self: *const Handed, r: Record) bool {
        if (r.id < self.ids.bit_length and self.ids.isSet(@intCast(r.id))) return true;
        const k = contentKey(r) orelse return false;
        return self.texts.contains(k);
    }

    /// Mark `r` handed out, by id and by content.
    pub fn markRecord(self: *Handed, alloc: std.mem.Allocator, r: Record) !void {
        try self.mark(alloc, r.id);
        if (contentKey(r)) |k| try self.texts.put(alloc, k, {});
    }

    pub fn mark(self: *Handed, alloc: std.mem.Allocator, id: u64) !void {
        if (id >= self.ids.bit_length) try self.ids.resize(alloc, @max(@as(usize, @intCast(id)) + 1, self.ids.bit_length * 2), false);
        self.ids.set(@intCast(id));
    }

    /// Mark every record `sel` returns.
    pub fn markSelection(self: *Handed, alloc: std.mem.Allocator, records: []const Record, sel: Selection) !void {
        for (sel.picked) |i| try self.markRecord(alloc, records[i]);
    }
};

pub const SegmentEnd = struct {
    /// Push the `done` (the first of a job, or one that brought a new
    /// substantive message).
    wake: bool,
    /// The done's text: `answer` of the job. Borrowed from the records.
    answer: []const u8,
    /// The answer's record id, null when the job has no message.
    answer_id: ?u64,
    /// The oldest job the done covers: every job since the previous done
    /// that woke, so a job a queued prompt superseded before it settled
    /// (it never had a done of its own) is not lost.
    first_job: u32,
};

/// The agent went idle but its turn is not settled (background tasks
/// still run): flag the segment final without deciding a wake.
pub fn markFinal(records: []Record, job: u32) void {
    if (lastMessage(records, job)) |i| records[i].segment_final = true;
}

/// A source's memory of its latest segment end, for the re-wake rule.
pub const Waker = struct {
    job: ?u32 = null,
    /// The highest record id at that segment end.
    mark: u64 = 0,
    /// The job of the latest done that woke the caller.
    woke: ?u32 = null,

    /// `job`'s segment ended: flag its last message as the segment final
    /// and decide whether the done wakes the caller.
    /// @param records the source's records, chronological.
    pub fn segmentEnd(self: *Waker, records: []Record, job: u32) SegmentEnd {
        markFinal(records, job);
        var wake = self.job == null or self.job.? != job;
        var high = self.mark;
        for (records) |r| {
            high = @max(high, r.id);
            if (!wake and r.job == job and r.id > self.mark and substantive(r)) wake = true;
        }
        self.job = job;
        self.mark = high;
        const first: u32 = if (self.woke) |w| @min(w + 1, job) else 0;
        if (wake) self.woke = job;
        const i = answerIndex(records, job);
        return .{ .wake = wake, .answer = if (i) |x| records[x].text else "", .answer_id = if (i) |x| records[x].id else null, .first_job = first };
    }
};

/// The jobs holding a record above `since` (0: every job), ascending.
pub fn jobsAfter(alloc: std.mem.Allocator, records: []const Record, since: u64) ![]u32 {
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(alloc);
    for (records) |r| {
        if (r.id <= since) continue;
        if (std.mem.indexOfScalar(u32, list.items, r.job) == null) try list.append(alloc, r.job);
    }
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    return list.toOwnedSlice(alloc);
}

pub const Options = struct {
    detail: Detail = .selected,
    include_tools: bool = false,
    /// `selected` only.
    cap: usize = READ_CAP_CHARS,
    /// `all` only: records returned at most.
    limit: usize = std.math.maxInt(usize),
    /// `all` only: records at or below it are not returned.
    since: u64 = 0,
    /// `selected` only: records handed out before are not returned again,
    /// and a job left with nothing new is dropped, except the last of
    /// `jobs` with `keep_empty` (a done's own job, to point at it).
    handed: ?*const Handed = null,
    keep_empty: bool = false,
};

/// A selected record not returned because it was handed out before.
pub const Earlier = struct {
    id: u64,
    kind: vocab.RecordKind,
    chars: usize,
};

/// What a job had that the selection does not list.
pub const JobSummary = struct {
    job: u32,
    omitted_messages: u32 = 0,
    omitted_tools: u32 = 0,
    /// Selected records left out because they were handed out before.
    returned_before: u32 = 0,
    /// The one of them to point at: the job's answer, else the latest.
    earlier: ?Earlier = null,
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
    /// `selected`: jobs left out whole because the cap kept every record
    /// of theirs out (not listed in `jobs` or `cut`).
    jobs_pending: u32 = 0,

    pub fn deinit(self: Selection, alloc: std.mem.Allocator) void {
        alloc.free(self.picked);
        alloc.free(self.jobs);
        alloc.free(self.cut);
    }
};

/// What one read returns of `jobs` (ascending, from `jobsAfter`).
/// @param records the source's records, chronological.
pub fn select(alloc: std.mem.Allocator, records: []const Record, jobs: []const u32, opts: Options) !Selection {
    var summaries: std.ArrayList(JobSummary) = .empty;
    errdefer summaries.deinit(alloc);
    var picked: std.ArrayList(usize) = .empty;
    errdefer picked.deinit(alloc);
    var cut: std.ArrayList(u64) = .empty;
    errdefer cut.deinit(alloc);
    var more = false;
    var jobs_pending: u32 = 0;
    const handed = if (opts.detail == .selected) opts.handed else null;

    for (jobs) |job| {
        var s: JobSummary = .{ .job = job };
        const last = lastMessage(records, job);
        const ans = answerIndex(records, job);
        const before = picked.items.len;
        var earlier: ?usize = null;
        for (records, 0..) |r, i| {
            if (r.job != job) continue;
            // `all` pages by id: what is at or below `since` was read.
            if (opts.detail == .all and r.id <= opts.since) continue;
            const take = visible(r.kind, opts.include_tools) and switch (opts.detail) {
                .selected => r.kind != .assistant or i == last or substantive(r),
                .all => true,
            };
            if (take and handed != null and handed.?.has(r)) {
                s.returned_before += 1;
                if (earlier == null or earlier.? != ans) earlier = i;
            } else if (take) {
                try picked.append(alloc, i);
            } else if (r.kind == .assistant) {
                s.omitted_messages += 1;
            } else if (r.kind == .tool and !opts.include_tools) {
                s.omitted_tools += 1;
            }
        }
        if (earlier) |i| s.earlier = .{ .id = records[i].id, .kind = records[i].kind, .chars = chars(records[i].text) };
        const kept = opts.keep_empty and job == jobs[jobs.len - 1];
        if (picked.items.len == before and handed != null and !kept) continue;
        try summaries.append(alloc, s);
    }

    switch (opts.detail) {
        .selected => {
            // The newest job's last message stays whole, when it is returned.
            var keep: ?usize = null;
            if (summaries.items.len > 0) {
                if (lastMessage(records, summaries.items[summaries.items.len - 1].job)) |k| {
                    if (std.mem.indexOfScalar(usize, picked.items, k) != null) keep = k;
                }
            }
            try applyCap(alloc, records, &picked, &cut, keep, opts.cap);
            if (!opts.keep_empty) jobs_pending = narrowToReturned(records, picked.items, &summaries, &cut);
        },
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
        .jobs = try summaries.toOwnedSlice(alloc),
        .cut = try cut.toOwnedSlice(alloc),
        .more = more,
        .jobs_pending = jobs_pending,
    };
}

fn jobOf(records: []const Record, id: u64) ?u32 {
    for (records) |r| if (r.id == id) return r.job;
    return null;
}

/// Keep only the jobs this read returns a record of, and the cut ids of
/// those: the metadata never lists old history.
/// @return the jobs dropped with records the cap kept out (the next read returns them).
fn narrowToReturned(records: []const Record, picked: []const usize, summaries: *std.ArrayList(JobSummary), cut: *std.ArrayList(u64)) u32 {
    var pending: u32 = 0;
    var w: usize = 0;
    for (summaries.items) |s| {
        var returned = false;
        for (picked) |i| if (records[i].job == s.job) {
            returned = true;
            break;
        };
        if (returned) {
            summaries.items[w] = s;
            w += 1;
            continue;
        }
        for (cut.items) |id| if (jobOf(records, id) == s.job) {
            pending += 1;
            break;
        };
    }
    summaries.shrinkRetainingCapacity(w);
    var cw: usize = 0;
    for (cut.items) |id| {
        const job = jobOf(records, id) orelse continue;
        for (summaries.items) |s| if (s.job == job) {
            cut.items[cw] = id;
            cw += 1;
            break;
        };
    }
    cut.shrinkRetainingCapacity(cw);
    return pending;
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
    defer t.allocator.free(jobs);
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
    defer t.allocator.free(jobs);
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

test "a done covers every job since the previous one that woke: a superseded job is not lost" {
    var records = [_]Record{
        rec(1, 0, .assistant, "a"),
        rec(2, 1, .assistant, filled(500, 'e')),
        rec(3, 2, .assistant, "PINEAPPLE"),
    };
    var w: Waker = .{};
    try t.expectEqual(@as(u32, 0), w.segmentEnd(records[0..1], 0).first_job);
    // Job 1 never settled: a prompt queued behind it took over. Job 2's
    // done covers it.
    const s = w.segmentEnd(&records, 2);
    try t.expect(s.wake);
    try t.expectEqual(@as(u32, 1), s.first_job);
    // A later segment of the same job covers only that job.
    try t.expectEqual(@as(u32, 2), w.segmentEnd(&records, 2).first_job);
    // A done result selects the covered jobs; the done's own job is kept
    // even with nothing new, an earlier one only with something new.
    var handed: Handed = .{};
    defer handed.deinit(t.allocator);
    try handed.mark(t.allocator, 3);
    const sel = try select(t.allocator, &records, &.{ 1, 2 }, .{ .handed = &handed, .keep_empty = true });
    defer sel.deinit(t.allocator);
    const ids = try pickedIds(&records, sel);
    defer t.allocator.free(ids);
    try t.expectEqualSlices(u64, &.{2}, ids);
    try t.expectEqual(@as(usize, 2), sel.jobs.len);
    try handed.mark(t.allocator, 2);
    const again = try select(t.allocator, &records, &.{ 1, 2 }, .{ .handed = &handed, .keep_empty = true });
    defer again.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), again.jobs.len);
    try t.expectEqual(@as(u32, 2), again.jobs[0].job);
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
    defer t.allocator.free(jobs);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, jobs);
    const sel = try select(t.allocator, &records, jobs, .{});
    defer sel.deinit(t.allocator);
    const ids = try pickedIds(&records, sel);
    defer t.allocator.free(ids);
    // 13000 alone exceeds the cap: kept whole, nothing else fits. Job 0
    // returns nothing this read, so it is neither listed nor in cut: one
    // count says it waits for the next read.
    try t.expectEqualSlices(u64, &.{5}, ids);
    try t.expectEqualSlices(u64, &.{4}, sel.cut);
    try t.expectEqual(@as(usize, 1), sel.jobs.len);
    try t.expectEqual(@as(u32, 1), sel.jobs[0].job);
    try t.expectEqual(@as(u32, 1), sel.jobs_pending);

    const roomy = try select(t.allocator, &records, jobs, .{ .cap = 13000 + 5000 + 2000 + 9 });
    defer roomy.deinit(t.allocator);
    const ids2 = try pickedIds(&records, roomy);
    defer t.allocator.free(ids2);
    // Longest first: 5000 fits, 4000 does not, 2000 and the notice do.
    try t.expectEqualSlices(u64, &.{ 1, 3, 4, 5 }, ids2);
    try t.expectEqualSlices(u64, &.{2}, roomy.cut);
    try t.expectEqual(@as(u32, 0), roomy.jobs_pending);
}

test "tools only on request, notices always, user prompts never" {
    var records = [_]Record{
        rec(1, 0, .user, "do it"),
        rec(2, 0, .tool, "Bash (ls)"),
        rec(3, 0, .notice, "model set"),
        rec(4, 0, .assistant, "done"),
    };
    const jobs = try jobsAfter(t.allocator, &records, 0);
    defer t.allocator.free(jobs);
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

test "jobs after a since; all honours since and limit" {
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
    defer t.allocator.free(unread);
    try t.expectEqualSlices(u32, &.{ 1, 2 }, unread);
    const none = try jobsAfter(t.allocator, &records, 7);
    defer t.allocator.free(none);
    try t.expectEqual(@as(usize, 0), none.len);
    const empty = try jobsAfter(t.allocator, records[0..0], 0);
    defer t.allocator.free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);

    // `all` returns only what is above `since`, by id, paged by `limit`.
    const all = try select(t.allocator, &records, unread, .{ .detail = .all, .since = 4, .limit = 1 });
    defer all.deinit(t.allocator);
    const a = try pickedIds(&records, all);
    defer t.allocator.free(a);
    try t.expectEqualSlices(u64, &.{5}, a);
    try t.expect(all.more);
}


test "a record re-captured under a new id with unchanged text is not delivered again" {
    const long = "Both review defects are fixed and pushed: the address-class fact moved into AddressScope and the tests cover both databases.";
    const recs = [_]Record{
        .{ .id = 5, .kind = .assistant, .text = @constCast(long), .job = 0, .segment_final = true },
        .{ .id = 9, .kind = .assistant, .text = @constCast(long), .job = 2, .segment_final = true },
        .{ .id = 10, .kind = .assistant, .text = @constCast("Done."), .job = 2 },
    };
    var handed: Handed = .{};
    defer handed.deinit(t.allocator);
    try handed.markRecord(t.allocator, recs[0]);
    try t.expect(handed.has(recs[1]));
    try t.expect(!handed.has(recs[2]));
    // The same report re-wrapped at another width (seen over mux: ids 1611
    // and 1722) is the same record; different words are not.
    const wrapped = [_]Record{
        .{ .id = 20, .kind = .assistant, .text = @constCast("Both review defects are fixed and pushed:\nthe address-class fact moved into AddressScope and\nthe tests cover both databases."), .job = 3 },
        .{ .id = 21, .kind = .assistant, .text = @constCast("  Both review defects are fixed and pushed: the address-class fact moved into AddressScope and the tests cover both databases.\n"), .job = 3 },
        .{ .id = 22, .kind = .assistant, .text = @constCast("Both review defects are fixed and pushed: the address-class fact moved into\xc2\xa0AddressScope and the tests cover both\tdatabases."), .job = 3 },
        .{ .id = 23, .kind = .assistant, .text = @constCast("Both review defects are fixed and pushed: the address-class fact moved into AddressScope and the tests cover one database."), .job = 3 },
    };
    try t.expect(handed.has(wrapped[0]));
    try t.expect(handed.has(wrapped[1]));
    try t.expect(handed.has(wrapped[2]));
    try t.expect(!handed.has(wrapped[3]));
    // A short text is never matched by content.
    var short = recs[2];
    short.id = 11;
    try handed.markRecord(t.allocator, recs[2]);
    try t.expect(!handed.has(short));
}

/// One default read as agent_read makes it: every job, nothing handed out
/// before, then what it returned marked handed.
fn readNew(records: []const Record, handed: *Handed) !Selection {
    const jobs = try jobsAfter(t.allocator, records, 0);
    defer t.allocator.free(jobs);
    const sel = try select(t.allocator, records, jobs, .{ .handed = handed });
    try handed.markSelection(t.allocator, records, sel);
    return sel;
}

test "per-record delivery: one long job's final is returned exactly once, later reads only what is new plus a pointer" {
    // The motivating shape: one job, a long report, then wake segments
    // (background builds) each ending with a short message.
    const report = filled(3100, 'r');
    var records = [_]Record{
        rec(1, 0, .user, "build it, report"),
        rec(2, 0, .assistant, "starting the build"),
        rec(3, 0, .tool, "Bash (make)"),
        rec(4, 0, .assistant, report),
        rec(5, 0, .notice, "Background command \"make\" completed"),
        rec(6, 0, .assistant, "build 1 green"),
        rec(7, 0, .notice, "Background command \"test\" completed"),
        rec(8, 0, .assistant, "tests green"),
    };
    var handed: Handed = .{};
    defer handed.deinit(t.allocator);
    var w: Waker = .{};

    // First segment ends: the done result carries the report.
    _ = w.segmentEnd(records[0..4], 0);
    const first = try readNew(records[0..4], &handed);
    defer first.deinit(t.allocator);
    const a = try pickedIds(&records, first);
    defer t.allocator.free(a);
    try t.expectEqualSlices(u64, &.{4}, a);
    try t.expectEqual(@as(u32, 0), first.jobs[0].returned_before);

    // A wake segment: only the notice and the new last message, and one
    // pointer at the report.
    _ = w.segmentEnd(records[0..6], 0);
    const second = try readNew(records[0..6], &handed);
    defer second.deinit(t.allocator);
    const b = try pickedIds(&records, second);
    defer t.allocator.free(b);
    try t.expectEqualSlices(u64, &.{ 5, 6 }, b);
    try t.expectEqual(@as(u32, 1), second.jobs[0].returned_before);
    try t.expectEqual(@as(u64, 4), second.jobs[0].earlier.?.id);
    try t.expectEqual(@as(usize, 3100), second.jobs[0].earlier.?.chars);

    // Nothing new: nothing at all, not the latest job again.
    const idle = try readNew(records[0..6], &handed);
    defer idle.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), idle.picked.len);
    try t.expectEqual(@as(usize, 0), idle.jobs.len);

    // The next segment: the earlier short final is no longer the last
    // message, so it is not selected; the report is still never repeated.
    _ = w.segmentEnd(&records, 0);
    const third = try readNew(&records, &handed);
    defer third.deinit(t.allocator);
    const c = try pickedIds(&records, third);
    defer t.allocator.free(c);
    try t.expectEqualSlices(u64, &.{ 7, 8 }, c);
    try t.expectEqual(@as(u64, 4), third.jobs[0].earlier.?.id);

    // Across all reads the report went out exactly once.
    var times: usize = 0;
    for ([_][]const u64{ a, b, c }) |ids| {
        for (ids) |id| if (id == 4) {
            times += 1;
        };
    }
    try t.expectEqual(@as(usize, 1), times);

    // A done result keeps its job even with nothing new, to point at it.
    const one = [1]u32{0};
    const done = try select(t.allocator, &records, &one, .{ .handed = &handed, .keep_empty = true });
    defer done.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), done.picked.len);
    try t.expectEqual(@as(usize, 1), done.jobs.len);

    // A deliberate re-read (no handed state: an explicit since, or all)
    // returns what it asks for.
    const again = try select(t.allocator, &records, &one, .{});
    defer again.deinit(t.allocator);
    const d = try pickedIds(&records, again);
    defer t.allocator.free(d);
    try t.expectEqualSlices(u64, &.{ 4, 5, 7, 8 }, d);
    const all = try select(t.allocator, &records, &one, .{ .detail = .all, .handed = &handed });
    defer all.deinit(t.allocator);
    try t.expectEqual(@as(usize, 6), all.picked.len);
}

test "a read's metadata covers only the jobs it returns something of" {
    var records = [_]Record{
        rec(1, 0, .assistant, filled(400, 'a')),
        rec(2, 1, .assistant, filled(400, 'b')),
        rec(3, 2, .assistant, "c"),
        rec(4, 2, .notice, "Background command completed"),
    };
    var handed: Handed = .{};
    defer handed.deinit(t.allocator);
    // Old history, handed out by earlier results.
    for (records[0..3]) |r| try handed.mark(t.allocator, r.id);
    const sel = try readNew(&records, &handed);
    defer sel.deinit(t.allocator);
    const ids = try pickedIds(&records, sel);
    defer t.allocator.free(ids);
    try t.expectEqualSlices(u64, &.{4}, ids);
    // Jobs 0 and 1 had nothing new: no entry, no cut ids, no pointer line.
    try t.expectEqual(@as(usize, 1), sel.jobs.len);
    try t.expectEqual(@as(u32, 2), sel.jobs[0].job);
    try t.expectEqual(@as(usize, 0), sel.cut.len);
    try t.expectEqual(@as(u32, 0), sel.jobs_pending);
}

test "the cap's cut records are not handed out: the next read returns them" {
    var records = [_]Record{
        rec(1, 0, .assistant, filled(9000, 'a')),
        rec(2, 0, .assistant, filled(5000, 'b')),
    };
    records[0].segment_final = true;
    var handed: Handed = .{};
    defer handed.deinit(t.allocator);
    const first = try readNew(&records, &handed);
    defer first.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), first.picked.len);
    try t.expectEqualSlices(u64, &.{1}, first.cut);
    const second = try readNew(&records, &handed);
    defer second.deinit(t.allocator);
    const ids = try pickedIds(&records, second);
    defer t.allocator.free(ids);
    try t.expectEqualSlices(u64, &.{1}, ids);
}

test "chars counts code points" {
    try t.expectEqual(@as(usize, 3), chars("a\xe2\x80\x94b"));
    try t.expectEqual(@as(usize, 2), chars("\xff\xfe"));
}
