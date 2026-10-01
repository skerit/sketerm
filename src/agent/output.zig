//! What every agent source produces for the read side: transcript records
//! and the pending interaction. The screen engine (`screen_source.zig`)
//! and the opencode API source (`opencode.zig`) fill these same types, so
//! the MCP layer reads one shape whichever source runs the agent.

const std = @import("std");
const vocab = @import("vocab.zig");
const events = @import("events.zig");

/// A tool call as an API source reports it (a screen source only has the
/// record's text line).
pub const ToolCall = struct {
    name: []u8,
    /// The call's input as compact JSON ("{}" while unknown).
    input: []u8,
    status: vocab.ToolStatus,
    /// The tool's output, or its error text when `status` is `error`.
    output: []u8,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.input);
        allocator.free(self.output);
    }
};

pub const Record = struct {
    /// Stable while the record's content is unchanged; a changed record gets
    /// a new id (an `agent_read` cursor then returns it again).
    id: u64,
    kind: vocab.RecordKind,
    /// Owned by the source. A tool record's text is a one-line summary.
    text: []u8,
    /// The job it belongs to (0-based, in prompt order; see `select.zig`).
    job: u32,
    /// Added by the adapter, not read from the app (a denial it answered).
    synthetic: bool = false,
    /// A `message` event was pushed for it.
    announced: bool = false,
    /// It was the job's last assistant message when the agent went idle
    /// (`select.Waker.segmentEnd`); kept across re-captures like `announced`.
    segment_final: bool = false,
    /// Owned by the source; null for records without a structured call.
    tool: ?ToolCall = null,

    /// Frees the text and the tool call.
    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.tool) |tc| tc.deinit(allocator);
    }
};

pub const Option = struct {
    label: []const u8,
    selected: bool,
};

pub const Interaction = struct {
    kind: vocab.InteractionKind,
    title: []const u8,
    detail: []const u8,
    /// How to answer, as the app words it ("Enter to set as default · s to
    /// use this session only"); "" when the app gives none.
    hint: []const u8,
    options: []const Option,
    /// A free-text answer is accepted (agent_answer `text`); derived, so
    /// not part of `hash`.
    free_text: bool = false,
    /// The screen lines it occupies, header to hint: [rows_start, rows_end)
    /// (screen sources only).
    rows_start: usize = 0,
    rows_end: usize = 0,

    /// Identity for "is this the prompt already announced": kind, title,
    /// detail and options (the hint, which echoes typed digits, is not part).
    pub fn hash(self: Interaction) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(self.kind));
        h.update(self.title);
        h.update("\x00");
        h.update(self.detail);
        for (self.options) |o| {
            h.update("\x00");
            h.update(o.label);
            h.update(if (o.selected) "+" else "-");
        }
        return h.final();
    }

    /// The option `choice` names: an exact label (case-insensitive), a
    /// 1-based index, or a case-insensitive substring of exactly one label.
    /// @return its 0-based index, or null.
    pub fn pick(self: Interaction, choice: []const u8) ?usize {
        const want = std.mem.trim(u8, choice, " \t\r\n");
        if (want.len == 0) return null;
        for (self.options, 0..) |o, i| {
            if (std.ascii.eqlIgnoreCase(o.label, want)) return i;
        }
        if (std.fmt.parseInt(usize, want, 10)) |n| {
            return if (n >= 1 and n <= self.options.len) n - 1 else null;
        } else |_| {}
        var found: ?usize = null;
        for (self.options, 0..) |o, i| {
            if (std.ascii.indexOfIgnoreCase(o.label, want) == null) continue;
            if (found != null) return null;
            found = i;
        }
        return found;
    }

    /// Push the `needs_input` event announcing it: "<kind>: <title>" with
    /// the numbered options as the detail.
    pub fn announce(self: Interaction, queue: *events.Queue, now_ms: i64) !u64 {
        const allocator = queue.allocator;
        var opts: std.ArrayList(u8) = .empty;
        defer opts.deinit(allocator);
        for (self.options, 0..) |o, i| {
            if (i > 0) try opts.append(allocator, '\n');
            try opts.print(allocator, "{d}. {s}{s}", .{ i + 1, o.label, if (o.selected) " (selected)" else "" });
        }
        const text = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ @tagName(self.kind), self.title });
        defer allocator.free(text);
        return queue.push(now_ms, .needs_input, null, text, opts.items);
    }
};

const t = std.testing;

test "pick: label, index, unique substring; ambiguity and misses are null" {
    const it = Interaction{
        .kind = .permission,
        .title = "bash: rm x",
        .detail = "",
        .hint = "",
        .options = &.{
            .{ .label = "Allow once", .selected = false },
            .{ .label = "Allow always", .selected = false },
            .{ .label = "Reject", .selected = false },
        },
    };
    try t.expectEqual(@as(?usize, 2), it.pick("reject"));
    try t.expectEqual(@as(?usize, 1), it.pick(" 2 "));
    try t.expectEqual(@as(?usize, 0), it.pick("once"));
    try t.expectEqual(@as(?usize, null), it.pick("allow"));
    try t.expectEqual(@as(?usize, null), it.pick("4"));
    try t.expectEqual(@as(?usize, null), it.pick("maybe"));
}

test "announce pushes one needs_input with numbered options" {
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    const it = Interaction{
        .kind = .choice,
        .title = "Effort",
        .detail = "",
        .hint = "",
        .options = &.{ .{ .label = "low", .selected = false }, .{ .label = "high", .selected = true } },
    };
    _ = try it.announce(&q, 5);
    const ev = q.events.items[0];
    try t.expectEqual(vocab.EventKind.needs_input, ev.kind);
    try t.expectEqualStrings("choice: Effort", ev.text);
    try t.expectEqualStrings("1. low\n2. high (selected)", ev.detail);
}
