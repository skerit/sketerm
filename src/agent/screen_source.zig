//! The screen engine: turns a terminal `Screen` running a screen-source
//! app (Claude Code in ax mode) into turn records, a state, the pending
//! interaction, errors and events.
//!
//! Driven by `feed(screen, now_ms)` after each applied batch of events and
//! `tick(now_ms)` for time-based settling. Everything is decided from
//! CONTENT (OSC 133 counters, the footer line, line ids), never from the
//! wall-clock gaps between feeds, so a backlog applied late in one burst
//! yields the same records and events as a live stream.
//!
//! History is collected by line id; a scrollback wipe (every line new, or
//! all of it gone) drops what was collected, because the app reprints it
//! (possibly partially). A captured turn is never shrunk and an older turn
//! is never re-added: a turn is identified by its user line's id, and after
//! a wipe by its prompt text.

const std = @import("std");
const vocab = @import("vocab.zig");
const adapter = @import("adapter.zig");
const events = @import("events.zig");
const grammar = @import("grammar.zig");
const output = @import("output.zig");
const select = @import("select.zig");
const Screen = @import("../grid/screen.zig").Screen;
const cell_mod = @import("../grid/cell.zig");

pub const Line = grammar.Line;
pub const Interaction = grammar.Interaction;

/// `job` indexes `Engine.turns` (a turn the app starts on its own prints
/// no user record, so it extends the job); a `synthetic` record came through
/// `Engine.addNotice` and is kept when its turn is re-captured. Screen
/// records never carry a `tool` call.
pub const Record = output.Record;

pub const Turn = struct {
    user_line_id: u64,
    /// `Engine.wipe_seq` when `user_line_id` was last seen.
    wipe_seq: u32,
    /// `grammar.promptKey` of the prompt; owned.
    key: []u8,
    /// First index into `Engine.records`.
    first: usize,
    /// Alphanumerics of its screen records (`Engine.keptAlnum`): a copy
    /// showing more replaces them.
    alnum: usize,
    /// The prompt is an adapter command (`Engine.beginCommand`): the turn
    /// keeps only synthetic records and raises no events.
    hidden: bool = false,
};

/// Wait this long after a retrying error first shows before surfacing it.
pub const RETRY_SURFACE_MS: i64 = vocab.ErrorClass.retrying.surfaceAfterMs();
/// Consecutive records an earlier job holds that make a stretch of a turn
/// a redraw of that job rather than a repeat (`Engine.knownRuns`).
const KNOWN_RUN = 3;
/// Substantial records a parsed turn must open with, as a captured turn
/// with its prompt did, to be that turn drawn again (`turnReprintedBy`).
const REPRINT_OPENING = 3;
/// Bottom rows searched for the input box.
const INPUT_SEARCH_ROWS = 8;
const MAX_STATUS_ROWS = 10;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    loaded: *const adapter.Loaded,
    sc: *const adapter.Screen,
    queue: events.Queue,

    records: std.ArrayList(Record) = .empty,
    turns: std.ArrayList(Turn) = .empty,
    next_record_id: u64 = 1,

    // What was read off the screen.
    hist: std.ArrayList(Line) = .empty,
    rows: std.ArrayList(Line) = .empty,
    newest_hist_id: u64 = 0,
    /// Bumped by every wipe or full erase: a line id identifies a turn only
    /// among turns seen since the same wipe.
    wipe_seq: u32 = 0,
    epoch: u32 = 0,
    rows_hash: u64 = 0,
    last_change_ms: i64 = 0,
    title_busy: bool = false,
    input_row: ?usize = null,
    /// The input box's text ("" when empty or not showing); owned.
    input_text: []u8 = &.{},
    status_rows: usize = 0,
    subagent_visible: bool = false,
    /// Background tasks the screen says still run (0: none shown).
    background_tasks: u32 = 0,
    /// When the agent went idle with its turn unsettled by them.
    background_since_ms: ?i64 = null,
    /// Prompts the app shows queued for its next turn (`screen.queued`).
    queued_visible: u32 = 0,

    // Counters from the Screen, relative to the first feed.
    primed: bool = false,
    cmd_seq: u64 = 0,
    bell_seq: u64 = 0,
    marks_len: u16 = 0,
    marks_head: u16 = 0,
    starts: u64 = 0,
    ends: u64 = 0,
    turn_open: bool = false,
    end_pending: bool = false,
    end_at_ms: i64 = 0,
    bells: u64 = 0,
    /// Bells beyond turn ends already answered by a needs_input.
    bells_acked: u64 = 0,
    lone_bell: bool = false,
    lone_bell_at_ms: i64 = 0,
    /// Segment ends so far, for the re-wake rule.
    waker: select.Waker = .{},

    // Derived state.
    ready: bool = false,
    state: vocab.State = .starting,
    done_armed: bool = false,
    captured_since_end: bool = false,
    interaction_arena: std.heap.ArenaAllocator,
    interaction: ?Interaction = null,
    /// Identity of the interaction a needs_input was pushed for.
    announced_interaction: ?u64 = null,
    /// The `now_ms` of the evaluation in progress.
    clock_ms: i64 = 0,
    /// `class \x00 text` of errors already pushed this turn; owned.
    turn_errors: std.ArrayList([]u8) = .empty,
    retry_since_ms: ?i64 = null,
    retrying_visible: bool = false,
    exited: bool = false,
    disconnected: bool = false,
    /// Prompts the adapter typed as its own commands; owned.
    commands: std.ArrayList([]u8) = .empty,
    /// A command recipe is running: a new interaction is the recipe's to
    /// answer and raises no needs_input.
    adopting: bool = false,

    /// @param loaded must be a screen-source adapter and outlive the engine.
    pub fn init(allocator: std.mem.Allocator, loaded: *const adapter.Loaded, limits: events.Limits) !Engine {
        const sc = if (loaded.screen) |*s| s else return error.NotAScreenAdapter;
        return .{
            .allocator = allocator,
            .loaded = loaded,
            .sc = sc,
            .queue = events.Queue.init(allocator, limits),
            .interaction_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        for (self.records.items) |r| self.allocator.free(r.text);
        self.records.deinit(self.allocator);
        for (self.turns.items) |tn| self.allocator.free(tn.key);
        self.turns.deinit(self.allocator);
        freeLines(self.allocator, &self.hist);
        self.hist.deinit(self.allocator);
        freeLines(self.allocator, &self.rows);
        self.rows.deinit(self.allocator);
        self.allocator.free(self.input_text);
        for (self.turn_errors.items) |e| self.allocator.free(e);
        self.turn_errors.deinit(self.allocator);
        for (self.commands.items) |x| self.allocator.free(x);
        self.commands.deinit(self.allocator);
        self.interaction_arena.deinit();
        self.queue.deinit();
    }

    // ── inputs ───────────────────────────────────────────────────

    /// Observe the screen after a batch of events was applied to it.
    pub fn feed(self: *Engine, screen: *const Screen, now_ms: i64) !void {
        if (self.exited) return;
        // Inside a synchronized-output update the app has not finished
        // drawing; the batch that closes it feeds again.
        if (screen.sync_output) return;
        if (self.disconnected) {
            self.disconnected = false;
            _ = try self.queue.push(now_ms, .connection_restored, null, "the connection to the agent's session is back", "");
        }
        try self.readCounters(screen, now_ms);
        try self.readHistory(screen);
        try self.readRows(screen, now_ms);
        self.title_busy = titleBusy(self.sc, screen.last_title);
        try self.evaluate(now_ms);
    }

    /// Time passed without new output.
    pub fn tick(self: *Engine, now_ms: i64) !void {
        if (self.exited) return;
        try self.evaluate(now_ms);
    }

    /// The Screen was replaced wholesale (snapshot resync): counters restart
    /// and the history is a new one, exactly like a wipe.
    pub fn noteResync(self: *Engine) void {
        self.primed = false;
        self.markWipe();
    }

    /// The app process ended.
    pub fn noteExited(self: *Engine, now_ms: i64, status: ?i32) !void {
        if (self.exited) return;
        if (status) |s| {
            if (s != 0) {
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "exited with status {d}", .{s}) catch "exited abnormally";
                _ = try self.queue.push(now_ms, .@"error", .crashed, text, "");
            }
        }
        _ = try self.queue.push(now_ms, .exited, null, "", "");
        self.exited = true;
        self.state = .exited;
    }

    /// The session is gone from its daemon (a lost link that came back to
    /// find nothing): `exited`, saying why.
    pub fn noteGone(self: *Engine, now_ms: i64, why: []const u8) !void {
        if (self.exited) return;
        _ = try self.queue.push(now_ms, .exited, null, why, "");
        self.exited = true;
        self.state = .exited;
    }

    /// The connection to the terminal session was lost.
    pub fn noteDisconnected(self: *Engine, now_ms: i64, reason: []const u8) !void {
        if (self.disconnected) return;
        _ = try self.queue.push(now_ms, .connection_lost, null, reason, "");
        self.disconnected = true;
        self.state = .disconnected;
    }

    /// Record something the adapter did that the app leaves no trace of (a
    /// permission it denied). Attached to the latest turn and kept when
    /// that turn is re-captured.
    pub fn addNotice(self: *Engine, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        const turn: u32 = if (self.turns.items.len > 0) @intCast(self.turns.items.len - 1) else 0;
        try self.records.append(self.allocator, .{ .id = self.nextId(), .kind = .notice, .text = owned, .job = turn, .synthetic = true });
    }

    /// The adapter is about to type `text` as its own command: the turn it
    /// starts is hidden from the transcript and the events, and an
    /// interaction it opens is adopted (no needs_input) until `endCommand`.
    pub fn beginCommand(self: *Engine, text: []const u8) !void {
        self.adopting = true;
        for (self.commands.items) |x| if (std.mem.eql(u8, x, text)) return;
        try self.commands.append(self.allocator, try self.allocator.dupe(u8, text));
    }

    /// The command recipe is over. An interaction it adopted that is still
    /// showing is announced now: nobody else would ever answer it.
    pub fn endCommand(self: *Engine, now_ms: i64) !void {
        self.adopting = false;
        if (self.interaction) |it| {
            if (self.announced_interaction == it.hash()) {
                self.announced_interaction = null;
                try self.evaluate(now_ms);
            }
        }
    }

    /// The text of the first line below the latest `command` prompt that
    /// matches `rule` (borrowed until the next feed), or null.
    pub fn confirmLine(self: *const Engine, rule: adapter.Matcher, command: []const u8) ?[]const u8 {
        const lists = [2][]const Line{ self.hist.items, self.rows.items };
        var anchor: ?[2]usize = null;
        for (lists, 0..) |list, li| {
            for (list, 0..) |l, i| {
                const ri = recordRule(self.sc, l.text) orelse continue;
                if (self.sc.records[ri].kind != .user) continue;
                if (std.mem.eql(u8, std.mem.trim(u8, stripRecordPrefix(self.sc, l.text), " "), command)) anchor = .{ li, i };
            }
        }
        const at = anchor orelse return null;
        var li = at[0];
        var start = at[1] + 1;
        while (li < lists.len) : (li += 1) {
            for (lists[li][start..]) |l| {
                if (l.live) continue;
                if (rule.matches(l.text)) return l.text;
            }
            start = 0;
        }
        return null;
    }

    /// The app was restarted in place (a relaunch): a new screen that must
    /// show its input box again before anything is typed. No event: the
    /// adapter did it, and the conversation goes on.
    pub fn noteRestart(self: *Engine) void {
        self.noteResync();
        self.ready = false;
        self.state = .starting;
        self.turn_open = false;
        self.end_pending = false;
        self.done_armed = false;
        self.lone_bell = false;
        self.interaction = null;
        self.announced_interaction = null;
        self.disconnected = false;
    }

    fn isCommand(self: *const Engine, prompt: []const u8) bool {
        const p = std.mem.trim(u8, prompt, " ");
        for (self.commands.items) |x| if (std.mem.eql(u8, x, p)) return true;
        return false;
    }

    /// Records with an id above `since`, oldest first.
    pub fn recordsSince(self: *const Engine, since: u64, out: *std.ArrayList(Record), alloc: std.mem.Allocator) !void {
        for (self.records.items) |r| {
            if (r.id > since) try out.append(alloc, r);
        }
        std.mem.sort(Record, out.items, {}, struct {
            fn lt(_: void, a: Record, b: Record) bool {
                return a.id < b.id;
            }
        }.lt);
    }

    // ── screen reading ───────────────────────────────────────────

    fn readCounters(self: *Engine, screen: *const Screen, now_ms: i64) !void {
        const backwards = screen.cmd_completion_seq < self.cmd_seq or screen.bell_seq < self.bell_seq;
        if (!self.primed or backwards) {
            if (self.primed) self.markWipe();
            self.primed = true;
            self.epoch = screen.viewport_epoch;
            self.cmd_seq = screen.cmd_completion_seq;
            self.bell_seq = screen.bell_seq;
            self.marks_len = screen.prompt_marks_len;
            self.marks_head = screen.prompt_marks_head;
            return;
        }
        // A full erase, resize or buffer swap: rows keep their ids for new
        // content, so line ids stop being an identity across it.
        if (screen.viewport_epoch != self.epoch) {
            self.epoch = screen.viewport_epoch;
            self.wipe_seq +%= 1;
        }
        const cap: u16 = @intCast(screen.prompt_marks.len);
        const a_delta: u64 = if (screen.prompt_marks_len < cap)
            screen.prompt_marks_len -| self.marks_len
        else
            @as(u64, (screen.prompt_marks_head +% cap -% self.marks_head) % cap);
        const d_delta = screen.cmd_completion_seq - self.cmd_seq;
        const b_delta = screen.bell_seq - self.bell_seq;
        self.cmd_seq = screen.cmd_completion_seq;
        self.bell_seq = screen.bell_seq;
        self.marks_len = screen.prompt_marks_len;
        self.marks_head = screen.prompt_marks_head;

        if (a_delta > 0 or d_delta > 0) {
            self.starts += a_delta;
            self.ends += d_delta;
            // Attached mid-turn: an end without a start we saw.
            if (self.ends > self.starts) self.starts = self.ends;
            self.turn_open = self.starts > self.ends;
            if (a_delta > 0) {
                self.done_armed = true;
                self.clearTurnErrors();
            }
            if (self.turn_open) {
                self.end_pending = false;
            } else if (d_delta > 0) {
                self.end_pending = true;
                self.end_at_ms = now_ms;
                self.captured_since_end = false;
            }
        }
        // Every turn end rings once; a bell beyond those is a lone one. The
        // two can land in different batches, so count, don't compare deltas.
        self.bells += b_delta;
        const excess = self.bells -| self.ends;
        if (excess < self.bells_acked) self.bells_acked = excess;
        if (self.sc.spec.bell_needs_input and excess > self.bells_acked) {
            if (!self.lone_bell) self.lone_bell_at_ms = now_ms;
            self.lone_bell = true;
        } else self.lone_bell = false;
    }

    /// The collected history is gone (the app cleared it and reprints).
    fn markWipe(self: *Engine) void {
        freeLines(self.allocator, &self.hist);
        self.newest_hist_id = 0;
        self.wipe_seq +%= 1;
    }

    fn readHistory(self: *Engine, screen: *const Screen) !void {
        const history = screen.scrollbackCount();
        if (history == 0) {
            if (self.newest_hist_id != 0) self.markWipe();
            return;
        }
        var added: u32 = 0;
        while (added < history) : (added += 1) {
            const id = screen.lineIdAt(-@as(i32, @intCast(added + 1))) orelse break;
            if (id <= self.newest_hist_id) break;
        }
        if (self.newest_hist_id != 0 and added == history) self.markWipe();
        var row: i32 = -@as(i32, @intCast(added));
        while (row < 0) : (row += 1) try self.hist.append(self.allocator, try readLine(self.allocator, screen, row));
        if (added > 0) self.newest_hist_id = screen.lineIdAt(-1) orelse self.newest_hist_id;
    }

    fn readRows(self: *Engine, screen: *const Screen, now_ms: i64) !void {
        freeLines(self.allocator, &self.rows);
        var h = std.hash.Wyhash.init(0);
        var r: i32 = 0;
        while (r < screen.rows) : (r += 1) {
            const l = try readLine(self.allocator, screen, r);
            h.update(l.text);
            h.update(std.mem.asBytes(&l.id));
            try self.rows.append(self.allocator, l);
        }
        // Trailing blank rows are no content.
        while (self.rows.items.len > 0 and self.rows.items[self.rows.items.len - 1].text.len == 0) {
            const l = self.rows.pop().?;
            self.allocator.free(l.text);
        }
        const hash = h.final();
        if (hash != self.rows_hash) {
            self.rows_hash = hash;
            self.last_change_ms = now_ms;
        }
        const sc = self.sc;
        self.input_row = grammar.findInput(sc, self.rows.items, INPUT_SEARCH_ROWS);
        self.allocator.free(self.input_text);
        self.input_text = &.{};
        self.queued_visible = 0;
        if (self.input_row) |in| {
            if (grammar.measureStatusRows(sc, self.rows.items, in, MAX_STATUS_ROWS)) |n| self.status_rows = n;
            grammar.markLive(sc, self.rows.items, in, self.status_rows);
            self.queued_visible = grammar.markQueued(sc, self.rows.items, in);
            self.input_text = try grammar.inputText(self.allocator, sc, self.rows.items, in);
        }
        self.subagent_visible = self.subagentInTail();
        self.background_tasks = self.backgroundInTail();

        _ = self.interaction_arena.reset(.retain_capacity);
        self.interaction = try grammar.parseInteraction(self.interaction_arena.allocator(), sc, self.rows.items);
        // A prompt is live state, never transcript.
        if (self.interaction) |it| {
            for (self.rows.items[it.rows_start..it.rows_end]) |*l| l.live = true;
        }
    }

    /// A subagent line after the last record start: a finished wait stays
    /// on screen above the records that follow it.
    fn subagentInTail(self: *const Engine) bool {
        const m = self.sc.subagent orelse return false;
        var i = self.rows.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.rows.items[i];
            if (m.matches(l.text)) return true;
            if (grammar.classify(self.sc, l) == .record) return false;
        }
        return false;
    }

    /// The background tasks shown after the last record start: the numbers
    /// on the background line summed (1 without one), plus one per
    /// background agent row; 0 when none shows.
    fn backgroundInTail(self: *const Engine) u32 {
        var n: u32 = 0;
        var seen_line = false;
        var i = self.rows.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.rows.items[i];
            if (self.sc.background_agent) |m| if (m.matches(l.text)) {
                n += 1;
                continue;
            };
            // A turn's footer says what still ran when it ended, and keeps
            // saying it after they ended: never the live count.
            if (self.sc.footer) |m| if (m.matches(l.text)) continue;
            if (self.sc.background) |m| if (!seen_line and m.matches(l.text)) {
                seen_line = true;
                n += @max(1, sumNumbers(l.text));
                continue;
            };
            if (grammar.classify(self.sc, l) == .record) break;
        }
        return n;
    }

    /// Milliseconds until the background cap fires a `done`, or null.
    pub fn backgroundDueIn(self: *const Engine, now_ms: i64) ?i64 {
        const since = self.background_since_ms orelse return null;
        return @max(0, since + select.BACKGROUND_DONE_CAP_MS - now_ms);
    }

    // ── evaluation ───────────────────────────────────────────────

    fn evaluate(self: *Engine, now_ms: i64) !void {
        if (self.exited or self.disconnected) return;
        self.clock_ms = now_ms;
        const settle: i64 = self.sc.spec.settle_ms;
        if (!self.ready and self.input_row != null and now_ms - self.last_change_ms >= self.sc.spec.ready_settle_ms) self.ready = true;

        try self.scanErrors(now_ms);

        // A turn end is captured once the footer shows below its last record
        // (all text drawn), or after the settle guard. An adapter command's
        // turn has no answer still to draw: it is captured at once.
        if (self.end_pending and (self.adopting or self.footerBelowRecords() or now_ms - self.end_at_ms >= settle)) {
            try self.capture(true);
            self.end_pending = false;
            self.captured_since_end = true;
        }

        if (self.interaction) |it| {
            const id = it.hash();
            if (self.announced_interaction != id) {
                // What led to the prompt belongs to the transcript now.
                try self.capture(false);
                // A command recipe's own picker is the recipe's to answer.
                if (!self.adopting) _ = try it.announce(&self.queue, now_ms);
                self.announced_interaction = id;
                self.ackBells();
            }
        } else {
            self.announced_interaction = null;
            if (self.lone_bell and self.turn_open and !self.title_busy and
                now_ms - self.lone_bell_at_ms >= settle and now_ms - self.last_change_ms >= settle)
            {
                // The app rang for input mid-turn but shows nothing this
                // adapter parses.
                _ = try self.queue.push(now_ms, .needs_input, null, "question: the app is waiting for input", self.lastText());
                self.ackBells();
            }
        }

        // A prompt shown before the app is ready (a trust dialog) is still
        // the user's to answer.
        self.state = if (self.interaction != null)
            .waiting_user
        else if (!self.ready)
            .starting
        else if (self.retrying_visible)
            .retrying
        else if (self.title_busy or self.turn_open or self.end_pending)
            (if (self.subagent_visible) .waiting_subagent else .working)
        else if (self.subagent_visible)
            .waiting_subagent
        else if (self.queued_visible > 0)
            // The app takes its queued prompt next: not settled, no done.
            .working
        else if (self.background_tasks > 0)
            .waiting_background
        else
            .idle;

        const ended = self.done_armed and self.captured_since_end;
        if (self.state == .waiting_background and ended) {
            // Idle but unsettled: the segment's final is known now, the
            // done waits for the background tasks (or the cap).
            if (self.visibleJob()) |job| select.markFinal(self.records.items, job);
            const since = self.background_since_ms orelse now_ms;
            self.background_since_ms = since;
            if (now_ms - since >= select.BACKGROUND_DONE_CAP_MS) try self.segmentDone(now_ms, self.background_tasks);
        } else self.background_since_ms = null;
        if (self.state == .idle and ended) try self.segmentDone(now_ms, null);
    }

    /// The latest job, unless it is an adapter command's hidden turn.
    fn visibleJob(self: *const Engine) ?u32 {
        const n = self.turns.items.len;
        if (n == 0 or self.turns.items[n - 1].hidden) return null;
        return @intCast(n - 1);
    }

    /// The turn settled (or the background cap ran out): push its done
    /// when the re-wake rule says so.
    fn segmentDone(self: *Engine, now_ms: i64, background: ?u32) !void {
        self.done_armed = false;
        self.background_since_ms = null;
        // An adapter command's turn is not a turn the assistant asked for.
        const job = self.visibleJob() orelse return;
        const end = self.waker.segmentEnd(self.records.items, job);
        if (end.wake) _ = try self.queue.pushDone(now_ms, job, end.first_job, end.answer, end.answer_id, background);
    }

    fn ackBells(self: *Engine) void {
        self.bells_acked = self.bells -| self.ends;
        self.lone_bell = false;
    }

    /// The footer is the newest content: a record or text line below it
    /// means it is an earlier turn's (a turn the app starts on its own
    /// prints below the previous footer before it answers).
    fn footerBelowRecords(self: *const Engine) bool {
        const m = self.sc.footer orelse return false;
        var i = self.rows.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.rows.items[i];
            if (l.live or l.text.len == 0) continue;
            if (m.matches(l.text)) return true;
            if (grammar.classify(self.sc, l) != .chrome) return false;
        }
        return false;
    }

    fn lastText(self: *const Engine) []const u8 {
        var i = self.rows.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.rows.items[i];
            if (!l.live and l.text.len > 0) return l.text;
        }
        return "";
    }

    /// Error lines of the current turn (everything after the last user
    /// record on screen, live rows included).
    fn scanErrors(self: *Engine, now_ms: i64) !void {
        var retrying = false;
        var start: usize = 0;
        for (self.rows.items, 0..) |l, i| {
            if (recordRule(self.sc, l.text)) |ri| {
                if (self.sc.records[ri].kind == .user) start = i + 1;
            }
        }
        for (self.rows.items[start..]) |l| {
            const text = stripRecordPrefix(self.sc, l.text);
            const hit = grammar.matchError(self.loaded.errors, text) orelse continue;
            if (hit.class == .retrying) {
                retrying = true;
                const since = self.retry_since_ms orelse now_ms;
                self.retry_since_ms = since;
                if (now_ms - since < RETRY_SURFACE_MS) continue;
            }
            const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ @tagName(hit.class), hit.text });
            var dup = false;
            for (self.turn_errors.items) |e| {
                if (std.mem.eql(u8, e, key)) dup = true;
            }
            if (dup) {
                self.allocator.free(key);
                continue;
            }
            self.turn_errors.append(self.allocator, key) catch |err| {
                self.allocator.free(key);
                return err;
            };
            _ = try self.queue.push(now_ms, .@"error", hit.class, hit.text, hit.detail);
        }
        self.retrying_visible = retrying;
        if (!retrying) self.retry_since_ms = null;
    }

    fn clearTurnErrors(self: *Engine) void {
        for (self.turn_errors.items) |e| self.allocator.free(e);
        self.turn_errors.clearRetainingCapacity();
    }

    // ── capture ──────────────────────────────────────────────────

    /// Fold the screen's turns into records now, announcing nothing.
    pub fn syncHistory(self: *Engine) !void {
        try self.capture(false);
    }

    /// Parse history + screen and fold the turns into `records`.
    /// @param complete the latest turn has ended (announce its messages).
    fn capture(self: *Engine, complete: bool) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var lines: std.ArrayList(Line) = .empty;
        try lines.appendSlice(arena, self.hist.items);
        try lines.appendSlice(arena, self.rows.items);
        const recs = try grammar.parseRecords(arena, self.sc, lines.items);

        var parsed: std.ArrayList(Parsed) = .empty;
        var start: ?usize = null;
        for (recs, 0..) |r, i| {
            if (r.kind != .user) continue;
            if (start) |s| try parsed.append(arena, try Parsed.init(arena, recs[s..i]));
            start = i;
        }
        if (start) |s| try parsed.append(arena, try Parsed.init(arena, recs[s..]));

        // The app can print a turn twice without clearing anything (claude
        // reprints the whole transcript on a resize, below the reflowed old
        // copy). An earlier copy of a later turn is dropped; the fuller of
        // the two copies' content is kept at the later one's position.
        var i = parsed.items.len;
        while (i > 0) {
            i -= 1;
            const p = &parsed.items[i];
            for (parsed.items[i + 1 ..]) |*later| {
                if (later.skip or !later.copyOf(p.*)) continue;
                if (p.alnum > later.alnum) {
                    later.recs = p.recs;
                    later.alnum = p.alnum;
                    later.sig = p.sig;
                }
                p.skip = true;
                break;
            }
        }
        for (parsed.items, 0..) |p, n| {
            if (p.skip) continue;
            try self.foldTurn(p, complete or n + 1 < parsed.items.len);
        }
        self.trimHistory();
    }

    /// One turn as parsed off the screen: its user record and what follows.
    const Parsed = struct {
        recs: []const grammar.Rec,
        line_id: u64,
        key: []u8,
        /// Lowercase alphanumerics of every record: a copy's is a prefix.
        sig: []u8,
        alnum: usize,
        skip: bool = false,

        fn init(arena: std.mem.Allocator, all: []const grammar.Rec) !Parsed {
            const recs = try grammar.dropStaleCopies(arena, all);
            var sig: std.ArrayList(u8) = .empty;
            for (recs) |r| {
                for (r.text) |ch| {
                    if (std.ascii.isAlphanumeric(ch)) try sig.append(arena, std.ascii.toLower(ch));
                }
            }
            return .{
                .recs = recs,
                .line_id = recs[0].line_id,
                .key = try grammar.promptKey(arena, recs[0].text),
                .sig = sig.items,
                .alnum = sig.items.len,
            };
        }

        /// Same prompt, and one's content a prefix of the other's.
        fn copyOf(self: Parsed, other: Parsed) bool {
            if (!grammar.samePrompt(self.key, other.key)) return false;
            return std.mem.startsWith(u8, self.sig, other.sig) or std.mem.startsWith(u8, other.sig, self.sig);
        }
    };

    fn foldTurn(self: *Engine, p: Parsed, complete: bool) !void {
        const recs = p.recs;
        const key = p.key;

        const cur = self.wipe_seq;
        const n_turns = self.turns.items.len;
        if (n_turns > 0) {
            const last = &self.turns.items[n_turns - 1];
            // Already captured, by identity (line ids are only an identity
            // between wipes: an erase keeps row ids for new content). Only
            // the latest turn can still grow.
            for (self.turns.items, 0..) |tn, ti| {
                if (tn.wipe_seq != cur or tn.user_line_id != p.line_id or !grammar.samePrompt(tn.key, key)) continue;
                if (ti == n_turns - 1 and try self.keptAlnum(recs, last.first) >= last.alnum) try self.replaceLast(recs, complete);
                return;
            }
            // The latest turn printed again without an erase (claude does
            // that too): same prompt and one's content a prefix of the
            // other's. It keeps its identity, so a same-prompt turn whose
            // answer then diverges is still a new turn.
            if (last.wipe_seq == cur and grammar.samePrompt(last.key, key) and self.turnCopiedBy(n_turns - 1, p)) {
                if (try self.keptAlnum(recs, last.first) > last.alnum) try self.replaceLast(recs, complete);
                return;
            }
            // An EARLIER turn printed again below the transcript without an
            // erase (claude reprints its whole transcript, e.g. after a
            // resume): its old copy may be trimmed from the parse already,
            // and its new copy has higher line ids, so it is recognised by
            // content against what was captured of every earlier turn with
            // the same prompt, and folded into that turn, never appended.
            var ri = n_turns;
            while (ri > 0) {
                ri -= 1;
                const tn = self.turns.items[ri];
                if (tn.hidden or tn.wipe_seq != cur or !grammar.samePrompt(tn.key, key) or !self.turnReprintedBy(ri, p)) continue;
                if (ri == n_turns - 1 and try self.keptAlnum(recs, last.first) > last.alnum) try self.replaceLast(recs, complete);
                return;
            }
            // A reprint of a turn captured before a wipe, by prompt.
            var ti = n_turns;
            while (ti > 0) {
                ti -= 1;
                const tn = self.turns.items[ti];
                if (tn.wipe_seq == cur or !grammar.samePrompt(tn.key, key)) continue;
                if (ti == n_turns - 1) {
                    last.user_line_id = p.line_id;
                    last.wipe_seq = cur;
                    if (try self.keptAlnum(recs, last.first) >= last.alnum) try self.replaceLast(recs, complete);
                }
                return;
            }
            // Older than the latest turn: old content.
            if (last.wipe_seq == cur and p.line_id < last.user_line_id) return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.turns.append(self.allocator, .{
            .user_line_id = p.line_id,
            .wipe_seq = cur,
            .key = owned_key,
            .first = self.records.items.len,
            .alnum = 0,
            .hidden = self.isCommand(recs[0].text),
        });
        try self.replaceLast(recs, complete);
    }

    /// The captured records of turn `ti`.
    fn turnRecords(self: *const Engine, ti: usize) []const Record {
        const end = if (ti + 1 < self.turns.items.len) self.turns.items[ti + 1].first else self.records.items.len;
        return self.records.items[self.turns.items[ti].first..end];
    }

    /// Whether `p` is a reprint of captured turn `ti`: a copy of it
    /// (`turnCopiedBy`), or one whose content differs only in how the app
    /// drew it this time (a tool's output collapsed or expanded, a queued
    /// prompt placed elsewhere): most substantial records of the smaller
    /// side are found, by kind and alphanumerics, on the other side.
    fn turnReprintedBy(self: *const Engine, ti: usize, p: Parsed) bool {
        if (self.turnCopiedBy(ti, p)) return true;
        const captured = self.turnRecords(ti);
        // The same opening: a turn typed again with the same prompt does not
        // start with the same `REPRINT_OPENING` substantial records.
        var a: usize = 0;
        var b: usize = 0;
        var same: usize = 0;
        while (same < REPRINT_OPENING) : (same += 1) {
            while (a < captured.len and (captured[a].synthetic or !evidence(captured[a].kind, captured[a].text))) a += 1;
            while (b < p.recs.len and !evidence(p.recs[b].kind, p.recs[b].text)) b += 1;
            if (a == captured.len or b == p.recs.len) break;
            if (captured[a].kind != p.recs[b].kind or !grammar.alnumRelated(captured[a].text, p.recs[b].text)) break;
            a += 1;
            b += 1;
        }
        if (same == REPRINT_OPENING) return true;
        var mine: usize = 0;
        for (captured) |r| {
            if (evidence(r.kind, r.text) and !r.synthetic) mine += 1;
        }
        var theirs: usize = 0;
        for (p.recs) |r| {
            if (evidence(r.kind, r.text)) theirs += 1;
        }
        if (mine == 0 or theirs == 0) return false;
        var found: usize = 0;
        if (theirs <= mine) {
            for (p.recs) |r| {
                if (!evidence(r.kind, r.text)) continue;
                for (captured) |o| if (!o.synthetic and o.kind == r.kind and grammar.alnumRelated(o.text, r.text)) {
                    found += 1;
                    break;
                };
            }
            return found * 2 > theirs;
        }
        for (captured) |o| {
            if (o.synthetic or !evidence(o.kind, o.text)) continue;
            for (p.recs) |r| if (r.kind == o.kind and grammar.alnumRelated(o.text, r.text)) {
                found += 1;
                break;
            };
        }
        return found * 2 > mine;
    }

    /// Whether a record says enough to identify its turn: not the prompt
    /// (`samePrompt` compares that), and not a few words two different
    /// turns may well share.
    fn evidence(kind: vocab.RecordKind, text: []const u8) bool {
        return kind != .user and grammar.alnumLen(text) >= grammar.CONTENT_ALNUM;
    }

    /// Whether turn `ti`'s screen records and `p` are copies (one's
    /// alphanumerics a prefix of the other's).
    fn turnCopiedBy(self: *const Engine, ti: usize, p: Parsed) bool {
        var pos: usize = 0;
        var diverged = false;
        outer: for (self.turnRecords(ti)) |r| {
            if (r.synthetic) continue;
            for (r.text) |ch| {
                if (!std.ascii.isAlphanumeric(ch)) continue;
                if (pos == p.sig.len) break :outer;
                if (std.ascii.toLower(ch) != p.sig[pos]) {
                    diverged = true;
                    break :outer;
                }
                pos += 1;
            }
        }
        return !diverged;
    }

    /// Alphanumerics of the records of `recs` that `knownRuns` keeps: how
    /// much of a turn a copy shows, compared with `Turn.alnum`.
    fn keptAlnum(self: *const Engine, recs: []const grammar.Rec, limit: usize) !usize {
        const known = try self.knownRuns(recs, limit);
        defer self.allocator.free(known);
        var n: usize = 0;
        for (recs, known) |r, skip| {
            if (!skip) n += grammar.alnumLen(r.text);
        }
        return n;
    }

    /// Replace the latest turn's screen records with `recs`, keeping the id
    /// of every record whose text did not change and its synthetic notices.
    fn replaceLast(self: *Engine, all_recs: []const grammar.Rec, complete: bool) !void {
        const ti = self.turns.items.len - 1;
        const turn = &self.turns.items[ti];
        // An adapter command leaves only what the adapter recorded of it.
        const recs = if (turn.hidden) all_recs[0..0] else all_recs;
        const old = self.records.items[turn.first..];

        // Records an earlier job already holds keep their id there.
        const known = try self.knownRuns(recs, turn.first);
        defer self.allocator.free(known);

        var fresh: std.ArrayList(Record) = .empty;
        errdefer {
            for (fresh.items) |r| self.allocator.free(r.text);
            fresh.deinit(self.allocator);
        }
        var old_screen: usize = 0;
        turn.alnum = 0;
        for (recs, known) |r, skip| {
            if (skip) continue;
            turn.alnum += grammar.alnumLen(r.text);
            // Match against the old screen records in order.
            while (old_screen < old.len and old[old_screen].synthetic) old_screen += 1;
            var kept: ?Record = null;
            if (old_screen < old.len) {
                const o = old[old_screen];
                if (o.kind == r.kind and std.mem.eql(u8, o.text, r.text)) kept = o;
                old_screen += 1;
            }
            const text = try self.allocator.dupe(u8, r.text);
            fresh.append(self.allocator, .{
                .id = if (kept) |k| k.id else self.nextId(),
                .kind = r.kind,
                .text = text,
                .job = @intCast(ti),
                .announced = if (kept) |k| k.announced else false,
                .segment_final = if (kept) |k| k.segment_final else false,
            }) catch |err| {
                self.allocator.free(text);
                return err;
            };
        }
        for (old) |o| {
            if (!o.synthetic) continue;
            const text = try self.allocator.dupe(u8, o.text);
            var copy = o;
            copy.text = text;
            fresh.append(self.allocator, copy) catch |err| {
                self.allocator.free(text);
                return err;
            };
        }
        for (old) |o| self.allocator.free(o.text);
        self.records.shrinkRetainingCapacity(turn.first);
        try self.records.appendSlice(self.allocator, fresh.items);
        fresh.deinit(self.allocator);

        if (!complete) return;
        for (self.records.items[turn.first..]) |*r| {
            if (r.kind != .assistant or r.announced) continue;
            r.announced = true;
            _ = try self.queue.pushMessage(self.clock_ms, r.text, r.id);
        }
    }

    /// Which of `recs` are records an earlier job captured already
    /// (`self.records[0..limit]`), drawn again in this turn: claude places a
    /// prompt it took mid-turn at different points of different renderings,
    /// so one rendering's earlier job ends with what another's next job
    /// starts with. Only runs of `KNOWN_RUN` or more such records count, so
    /// a job that repeats a message or a tool call of an earlier one keeps
    /// it. The caller frees the result.
    fn knownRuns(self: *const Engine, recs: []const grammar.Rec, limit: usize) ![]bool {
        const a = self.allocator;
        const drop = try a.alloc(bool, recs.len);
        @memset(drop, false);
        if (limit == 0) return drop;
        const earlier = self.records.items[0..limit];
        const keys = try a.alloc(?u64, earlier.len);
        defer a.free(keys);
        for (earlier, keys) |r, *k| k.* = if (r.synthetic) null else grammar.contentKey(r.kind, r.text);
        var run_start: ?usize = null;
        var run_end: usize = 0;
        var run_len: usize = 0;
        for (recs, 0..) |r, i| {
            const key = grammar.contentKey(r.kind, r.text);
            var known = false;
            if (key) |k| for (earlier, keys) |o, ok| if (ok == k and grammar.alnumRelated(o.text, r.text)) {
                known = true;
                break;
            };
            if (known) {
                if (run_start == null) run_start = i;
                run_end = i;
                run_len += 1;
                continue;
            }
            // A short record neither ends nor counts toward a run.
            if (key == null and r.kind != .user) continue;
            if (run_start) |s| if (run_len >= KNOWN_RUN) @memset(drop[s .. run_end + 1], true);
            run_start = null;
            run_len = 0;
        }
        if (run_start) |s| if (run_len >= KNOWN_RUN) @memset(drop[s .. run_end + 1], true);
        return drop;
    }

    fn nextId(self: *Engine) u64 {
        const id = self.next_record_id;
        self.next_record_id += 1;
        return id;
    }

    /// History before the latest captured prompt is never parsed again.
    fn trimHistory(self: *Engine) void {
        if (self.turns.items.len == 0) return;
        const keep_from = self.turns.items[self.turns.items.len - 1].user_line_id;
        var drop: usize = 0;
        while (drop < self.hist.items.len and self.hist.items[drop].id < keep_from) : (drop += 1) {
            self.allocator.free(self.hist.items[drop].text);
        }
        if (drop == 0) return;
        const rest = self.hist.items.len - drop;
        std.mem.copyForwards(Line, self.hist.items[0..rest], self.hist.items[drop..]);
        self.hist.shrinkRetainingCapacity(rest);
    }
};

fn freeLines(allocator: std.mem.Allocator, list: *std.ArrayList(Line)) void {
    for (list.items) |l| allocator.free(l.text);
    if (list.capacity > 4096) list.clearAndFree(allocator) else list.clearRetainingCapacity();
}

/// Every decimal number in `text`, summed (0 without one).
fn sumNumbers(text: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isDigit(text[i])) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        sum +|= std.fmt.parseInt(u32, text[i..end], 10) catch 0;
        i = end;
    }
    return sum;
}

fn titleBusy(sc: *const adapter.Screen, title: ?[]const u8) bool {
    const text = title orelse return false;
    for (sc.spec.busy_title) |p| {
        if (std.mem.startsWith(u8, text, p)) return true;
    }
    return false;
}

fn recordRule(sc: *const adapter.Screen, text: []const u8) ?usize {
    for (sc.records, 0..) |r, i| {
        if (r.matcher.matches(text)) return i;
    }
    return null;
}

fn stripRecordPrefix(sc: *const adapter.Screen, text: []const u8) []const u8 {
    const i = recordRule(sc, text) orelse return text;
    return text[@min(sc.records[i].strip, text.len)..];
}

/// One display row as a `Line` (negative rows index scrollback). The row
/// joins the next when it soft-wraps or its last column is written (the app
/// broke a token at the edge).
fn readLine(allocator: std.mem.Allocator, screen: *const Screen, row: i32) !Line {
    const raw = try screen.extractRowRange(allocator, row, row + 1);
    const text = std.mem.trimEnd(u8, raw, "\n");
    const owned = if (text.len == raw.len) raw else blk: {
        const d = try allocator.dupe(u8, text);
        allocator.free(raw);
        break :blk d;
    };
    var full = false;
    if (screen.lineCellsAtPub(row)) |cells| {
        if (cells.len > 0) {
            const last = cells[cells.len - 1];
            full = last.rune != 0 or last.flags & cell_mod.FLAG_WIDE_CONT != 0;
        }
    }
    return .{
        .text = owned,
        .id = screen.lineIdAt(row) orelse 0,
        .joins_next = full or screen.nextRowContinues(row),
    };
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;
const Parser = @import("../parser/vt.zig").Parser;
const Event = @import("../parser/event.zig").Event;
const StylePool = @import("../grid/style_pool.zig").Pool;

/// A Screen + parser the tests write ax-mode bytes into.
const Rig = struct {
    pool: StylePool,
    screen: *Screen,
    parser: Parser,
    loaded: *adapter.Loaded,
    engine: Engine,

    fn init(self: *Rig, cols: u16, rows: u16) !void {
        self.pool = try StylePool.init(t.allocator);
        self.screen = try Screen.init(t.allocator, &self.pool, cols, rows);
        self.parser = Parser.init(t.allocator);
        self.loaded = try grammar.testAdapter();
        self.engine = try Engine.init(t.allocator, self.loaded, .{});
    }

    fn deinit(self: *Rig) void {
        self.engine.deinit();
        self.loaded.destroy(t.allocator);
        self.parser.deinit();
        self.screen.deinit();
        self.pool.deinit();
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *Rig = @ptrCast(@alignCast(user.?));
        var e = ev;
        self.screen.apply(ev);
        e.deinit(t.allocator);
    }

    fn write(self: *Rig, bytes: []const u8) void {
        self.parser.advance(bytes, emit, @ptrCast(self));
    }

    fn feed(self: *Rig, now: i64) !void {
        try self.engine.feed(self.screen, now);
    }

    fn kinds(self: *Rig, buf: []vocab.EventKind) []vocab.EventKind {
        var n: usize = 0;
        for (self.engine.queue.events.items) |ev| {
            buf[n] = ev.kind;
            n += 1;
        }
        return buf[0..n];
    }
};

/// The live region claude redraws under its output: status block, mode line, input.
const live = "[Haiku 4.5] repo:master\r\n[\xe2\x96\xa0\xe2\x96\xa1] 21%\r\nmanual mode on\r\n$";
/// Erase the live region (4 rows) before a redraw, as claude does.
const erase = "\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[G";

fn countKind(e: *const Engine, k: vocab.EventKind) usize {
    var n: usize = 0;
    for (e.queue.events.items) |ev| {
        if (ev.kind == k) n += 1;
    }
    return n;
}

test "a turn: prompt, streamed answer, OSC 133 end, footer; done once with the final message" {
    var rig: Rig = undefined;
    try rig.init(80, 24);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 Claude Code\x07banner\r\n" ++ live);
    try rig.feed(0);
    try t.expectEqual(vocab.State.starting, rig.engine.state);
    try rig.engine.tick(1000);
    try t.expectEqual(vocab.State.idle, rig.engine.state);

    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 Working\x07" ++ erase ++ "you: say hi\r\nPuttering\xe2\x80\xa6\r\n" ++ live);
    try rig.feed(1100);
    try t.expectEqual(vocab.State.working, rig.engine.state);
    rig.write("\x1b[2K\x1b[1A" ++ erase ++ "claude: Hello\r\n" ++ live);
    try rig.feed(1200);
    // The end mark arrives before the last text is drawn.
    rig.write("\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 Working\x07");
    try rig.feed(1300);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    rig.write(erase ++ "there, friend.\r\nCogitated for 1s \xc2\xb7 done 9:23 PM\r\n" ++ live);
    try rig.feed(1350);
    try t.expectEqual(vocab.State.idle, rig.engine.state);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .message));
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .needs_input));
    const recs = rig.engine.records.items;
    try t.expectEqual(@as(usize, 2), recs.len);
    try t.expectEqualStrings("say hi", recs[0].text);
    try t.expectEqualStrings("Hello\nthere, friend.", recs[1].text);
    const done = rig.engine.queue.events.items[rig.engine.queue.events.items.len - 1];
    try t.expectEqualStrings("Hello\nthere, friend.", done.text);
    try rig.engine.tick(9000);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
}

test "a backlog applied in one burst yields the same records and one done" {
    var rig: Rig = undefined;
    try rig.init(80, 24);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 Claude Code\x07banner\r\n" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    // Two whole turns, one feed.
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: first\r\nclaude: one\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07" ++
        "\x1b]133;A\x07" ++ erase ++ "you: second\r\nclaude: two\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07" ++ erase ++ "Baked for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(1100);
    const recs = rig.engine.records.items;
    try t.expectEqual(@as(usize, 4), recs.len);
    try t.expectEqualStrings("first", recs[0].text);
    try t.expectEqualStrings("one", recs[1].text);
    try t.expectEqualStrings("two", recs[3].text);
    try t.expectEqual(@as(usize, 2), countKind(&rig.engine, .message));
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    try t.expectEqual(vocab.State.idle, rig.engine.state);
}

test "a permission prompt is a pending interaction with one needs_input" {
    var rig: Rig = undefined;
    try rig.init(80, 24);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: delete it\r\n" ++ live);
    try rig.feed(1100);
    rig.write(erase ++ "tool: Bash (rm notes.md)\r\nPermission Required: Bash command\r\n> rm notes.md\r\n" ++
        "Do you want to proceed?\r\n1. Yes\r\n2. No\r\nSelect with numbers [1-2]. Then Enter to submit or Escape to cancel:\r\n" ++
        "Esc to cancel \xc2\xb7 Tab to amend\x07");
    try rig.feed(1200);
    try t.expectEqual(vocab.State.waiting_user, rig.engine.state);
    const it = rig.engine.interaction.?;
    try t.expectEqual(vocab.InteractionKind.permission, it.kind);
    try t.expectEqualStrings("Do you want to proceed?", it.title);
    try t.expectEqual(@as(usize, 2), it.options.len);
    try rig.feed(1300);
    try rig.engine.tick(5000);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .needs_input));
    // The tool call that asked is already in the transcript.
    try t.expectEqual(vocab.RecordKind.tool, rig.engine.records.items[1].kind);
    try t.expectEqualStrings("Bash (rm notes.md)", rig.engine.records.items[1].text);
}

test "a subagent wait is not done; the continuation turn extends the same turn" {
    var rig: Rig = undefined;
    try rig.init(80, 24);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07" ++ erase ++ "you: use a subagent\r\ntool: Explore (find it)\r\nclaude: searching\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07" ++ erase ++ "Waiting for 1 background agent to finish\r\n" ++ live);
    try rig.feed(1100);
    try rig.engine.tick(3000);
    try t.expectEqual(vocab.State.waiting_subagent, rig.engine.state);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    try t.expectEqual(@as(usize, 3), rig.engine.records.items.len);
    // The subagent finishes: the title blips idle before the new turn starts.
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07");
    try rig.feed(3100);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    rig.write("\x1b]0;\xe2\x97\x90 C\x07\x1b]133;A\x07" ++ erase ++ " Agent \"find it\" finished \xc2\xb7 6s\r\nclaude: found it in screen.zig\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "Baked for 9s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(3200);
    try t.expectEqual(vocab.State.idle, rig.engine.state);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    const recs = rig.engine.records.items;
    try t.expectEqual(@as(usize, 5), recs.len);
    try t.expectEqual(@as(u32, 0), recs[4].job);
    try t.expectEqual(vocab.RecordKind.notice, recs[3].kind);
    try t.expectEqualStrings("found it in screen.zig", recs[4].text);
    try t.expectEqual(@as(usize, 1), rig.engine.turns.items.len);
}

test "a turn the app starts on its own extends the job; only a substantive reply wakes again" {
    var rig: Rig = undefined;
    try rig.init(100, 30);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    const line = "s" ** 90;
    const summary = line ++ "\n" ++ line ++ "\n" ++ line ++ "\n" ++ line;
    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07" ++ erase ++ "you: summarize, ignore wakeups\r\ntool: Bash (sleep 20)\r\nclaude: " ++
        line ++ "\r\n" ++ line ++ "\r\n" ++ line ++ "\r\n" ++ line ++ "\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "Crunched for 10s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(1100);
    try rig.engine.tick(3000);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    try t.expectEqualStrings(summary, rig.engine.queue.events.items[rig.engine.queue.events.items.len - 1].text);
    try t.expect(rig.engine.records.items[2].segment_final);

    // The wake, as claude draws it (observed, 2.1.286): no user line, a
    // notification below the previous footer, the end mark before the
    // answer. The old footer must not pass for this turn's.
    rig.write("\x1b]0;\xe2\x97\x90 C\x07\x1b]133;A\x07" ++ erase ++ " Background command \"Sleep\" completed (exit code 0)\r\nIonizing\xe2\x80\xa6\r\n" ++ live);
    try rig.feed(28_000);
    rig.write("\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07");
    try rig.feed(29_000);
    try t.expectEqual(vocab.State.working, rig.engine.state);
    rig.write("\x1b[2K\x1b[1A" ++ erase ++ "claude: ignoring wakeup.\r\nCogitated for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(29_100);
    try rig.engine.tick(40_000);
    try t.expectEqual(vocab.State.idle, rig.engine.state);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    try t.expectEqual(@as(usize, 1), rig.engine.turns.items.len);
    const recs = rig.engine.records.items;
    try t.expectEqual(@as(usize, 4), recs.len);
    try t.expectEqualStrings("ignoring wakeup.", recs[3].text);
    try t.expectEqual(@as(u32, 0), recs[3].job);
    try t.expect(recs[3].segment_final);
    // The summary kept its id and flag through the re-capture.
    try t.expect(recs[2].segment_final);
    try t.expectEqual(@as(usize, 2), countKind(&rig.engine, .message));

    // A later wake with something to say wakes the caller again.
    const more = "m" ** 80 ++ "\r\n" ++ "m" ** 80 ++ "\r\n" ++ "m" ** 80 ++ "\r\n" ++ "m" ** 80;
    rig.write("\x1b]0;\xe2\x97\x90 C\x07\x1b]133;A\x07" ++ erase ++ " Background command \"Build\" completed (exit code 0)\r\nIonizing\xe2\x80\xa6\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++
        "\x1b[2K\x1b[1A" ++ erase ++ "claude: " ++ more ++ "\r\nBaked for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(50_000);
    try rig.engine.tick(60_000);
    try t.expectEqual(@as(usize, 2), countKind(&rig.engine, .done));
    const done = rig.engine.queue.events.items[rig.engine.queue.events.items.len - 1];
    try t.expectEqual(vocab.EventKind.done, done.kind);
    try t.expectEqual(@as(?u32, 0), done.job);
    try t.expectEqual(@as(usize, 323), done.text.len);
}

test "a prompt queued while the app works: a preview until taken, then its own job; one done covers both" {
    var rig: Rig = undefined;
    try rig.init(100, 30);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07" ++ erase ++ "you: write an essay\r\nclaude: The essay begins\r\n" ++ live);
    try rig.feed(1100);
    // As Claude Code 2.1.287 draws a prompt queued while it works: the
    // preview and its hint between the streaming answer and the status block.
    rig.write(erase ++ "and goes on.\r\nyou: then say PINEAPPLE\r\nctrl+enter to send now\r\n" ++ live);
    try rig.feed(1200);
    try t.expectEqual(@as(u32, 1), rig.engine.queued_visible);
    // The turn ends with the preview still showing; the app has not taken
    // it yet when the settle guard runs out: not idle, no done.
    rig.write("\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07");
    try rig.feed(1300);
    try rig.engine.tick(5000);
    try t.expectEqual(vocab.State.working, rig.engine.state);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    try t.expectEqual(@as(usize, 2), rig.engine.records.items.len);
    // Taken: the prompt is printed below the footer as transcript, then
    // the turn mark (observed order), then the answer.
    const erase6 = "\x1b[2K\x1b[1A" ** 5 ++ "\x1b[2K\x1b[G";
    rig.write(erase6 ++ "Churned for 2s \xc2\xb7 done\r\nyou: then say PINEAPPLE\r\n" ++ live ++ "\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07");
    try rig.feed(5100);
    try t.expectEqual(@as(u32, 0), rig.engine.queued_visible);
    try t.expectEqual(vocab.State.working, rig.engine.state);
    rig.write(erase ++ "claude: PINEAPPLE\r\n" ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "Crunched for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(5200);
    try rig.engine.tick(9000);
    try t.expectEqual(vocab.State.idle, rig.engine.state);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    const done = rig.engine.queue.events.items[rig.engine.queue.events.items.len - 1];
    try t.expectEqual(@as(?u32, 1), done.job);
    try t.expectEqual(@as(?u32, 0), done.first_job);
    try t.expectEqualStrings("PINEAPPLE", done.text);
    const recs = rig.engine.records.items;
    try t.expectEqual(@as(usize, 4), recs.len);
    try t.expectEqualStrings("The essay begins\nand goes on.", recs[1].text);
    try t.expectEqual(@as(u32, 0), recs[1].job);
    try t.expectEqualStrings("then say PINEAPPLE", recs[2].text);
    try t.expectEqual(@as(u32, 1), recs[2].job);
    try t.expectEqual(@as(usize, 2), rig.engine.turns.items.len);
}

/// The live block while a background shell runs (observed, 2.1.286: the
/// mode line gains `·  N shell`, and loses it when the task ends).
const live_bg = "[Haiku 4.5] repo:master\r\n[\xe2\x96\xa0\xe2\x96\xa1] 21%\r\nmanual mode on  \xc2\xb7  1 shell\r\n$";
const summary_lines = ("s" ** 90 ++ "\r\n") ** 3 ++ "s" ** 90;

/// A turn that started a background shell and answered with a summary,
/// as claude draws it: idle again while the shell still runs.
fn backgroundTurn(rig: *Rig) !void {
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07" ++ erase ++ "you: run it in the background, summarize\r\n" ++ live);
    try rig.feed(1100);
    rig.write(erase ++ "tool: Bash (sleep 40; echo BG-DONE)\r\nRunning in the background (\xe2\x86\x93 to manage)\r\nclaude: " ++ summary_lines ++ "\r\n" ++ live_bg);
    try rig.feed(1200);
    rig.write("\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "Cogitated for 10s \xc2\xb7 done\r\n" ++ live_bg);
    try rig.feed(1300);
    try rig.engine.tick(5000);
}

test "done means settled: idle with a background shell is waiting_background, the done comes after it" {
    var rig: Rig = undefined;
    try rig.init(100, 30);
    defer rig.deinit();
    try backgroundTurn(&rig);
    try t.expectEqual(vocab.State.waiting_background, rig.engine.state);
    try t.expectEqual(@as(u32, 1), rig.engine.background_tasks);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    // The segment's final is known already (it is selected by length).
    try t.expect(rig.engine.records.items[2].segment_final);
    try rig.engine.tick(40_000);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));

    // The shell ends: claude starts the wake turn in the same frame that
    // drops the count, then answers below the previous footer.
    rig.write("\x1b]0;\xe2\x97\x90 C\x07\x1b]133;A\x07" ++ erase ++ " Background command \"sleep\" completed (exit code 0)\r\nCreating\xe2\x80\xa6\r\n" ++ live);
    try rig.feed(54_400);
    try t.expectEqual(vocab.State.working, rig.engine.state);
    rig.write("\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "claude: It printed BG-DONE.\r\nCrunched for 3s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(57_700);
    try rig.engine.tick(60_000);
    try t.expectEqual(vocab.State.idle, rig.engine.state);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    const done = rig.engine.queue.events.items[rig.engine.queue.events.items.len - 1];
    try t.expectEqual(vocab.EventKind.done, done.kind);
    try t.expect(done.background_tasks == null);
    // The answer is the summary; the closing sentence is the job's last.
    try t.expectEqual(@as(usize, 363), done.text.len);
    const recs = rig.engine.records.items;
    try t.expectEqualStrings("It printed BG-DONE.", recs[recs.len - 1].text);
    try t.expectEqual(@as(usize, 1), rig.engine.turns.items.len);
}

test "a background task that never ends: done fires at the cap with the count" {
    var rig: Rig = undefined;
    try rig.init(100, 30);
    defer rig.deinit();
    try backgroundTurn(&rig);
    const since = rig.engine.background_since_ms.?;
    try t.expectEqual(select.BACKGROUND_DONE_CAP_MS, rig.engine.backgroundDueIn(since).?);
    try rig.engine.tick(since + select.BACKGROUND_DONE_CAP_MS - 1);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    try rig.engine.tick(since + select.BACKGROUND_DONE_CAP_MS);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    const done = rig.engine.queue.events.items[rig.engine.queue.events.items.len - 1];
    try t.expectEqual(@as(?u32, 1), done.background_tasks);
    try t.expect(rig.engine.backgroundDueIn(since) == null);
    // Once: still waiting_background, no second done.
    try rig.engine.tick(since + 2 * select.BACKGROUND_DONE_CAP_MS);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    try t.expectEqual(vocab.State.waiting_background, rig.engine.state);
}

/// Erase `n` live rows before a redraw, as claude does.
fn eraseRows(comptime n: usize) []const u8 {
    return "\x1b[2K\x1b[1A" ** (n - 1) ++ "\x1b[2K\x1b[G";
}
const erase_6 = eraseRows(6);
const erase_7 = eraseRows(7);
const status_rows = "[Haiku 4.5] repo:master\r\n[\xe2\x96\xa0\xe2\x96\xa1] 21%\r\n";
/// The live blocks claude 2.1.287 draws while background work runs
/// (measured with Haiku at 120 and 48 columns): shells and monitors on the
/// mode line, one `◯` row per background subagent under `● main`.
const live_all = status_rows ++ "manual mode on  \xc2\xb7  2 shells, 1 monitor\r\n  \xe2\x97\x8f main\r\n   \xe2\x97\xaf  general-purpose Subagent sleep 60 then answer 6s \xc2\xb7 \xe2\x86\x93 32.7k tokens\r\n$";
const live_shell_monitor = status_rows ++ "manual mode on  \xc2\xb7  1 shell, 1 monitor\r\n$";
const live_monitor = status_rows ++ "manual mode on  \xc2\xb7  1 monitor\r\n$";
const live_agent_only = status_rows ++ "manual mode on\r\n  \xe2\x97\x8f main\r\n   \xe2\x97\xaf  claude Run sleep 60 then report\r\nSUB-DONE 7s \xc2\xb7 \xe2\x86\x93 32.9k tokens\r\n$";

test "every kind of background work holds the done: shells, a monitor, a background subagent" {
    var rig: Rig = undefined;
    try rig.init(120, 40);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07" ++ erase ++ "you: start them, do not wait\r\n" ++ live);
    try rig.feed(1100);
    rig.write(erase ++ "tool: Bash (sleep 75; echo BG-SHELL-DONE)\r\nclaude: Started a shell, a monitor and a subagent.\r\n" ++ live_all);
    try rig.feed(1200);
    rig.write("\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase_6 ++
        "Brewed for 44s \xc2\xb7 done 10:29 AM \xc2\xb7 2 shells still running\r\n" ++ live_all);
    try rig.feed(1300);
    try rig.engine.tick(5000);
    try t.expectEqual(vocab.State.waiting_background, rig.engine.state);
    try t.expectEqual(@as(u32, 4), rig.engine.background_tasks);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));

    // The subagent finishes first and wakes the agent; the shell and the
    // monitor still run, so its wake turn is not settled either (this is
    // the done that fired early in the field, on a 48-column terminal).
    rig.write("\x1b]0;\xe2\x97\x90 C\x07\x1b]133;A\x07" ++ erase_6 ++ " Agent \"sleep 60\" finished \xc2\xb7 60s\r\nclaude: Subagent task complete; the shell and the monitor still run.\r\n" ++ live_shell_monitor ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "Baked for 2s \xc2\xb7 done 10:30 AM \xc2\xb7 1 shell, 1 monitor still running\r\n" ++ live_shell_monitor);
    try rig.feed(61_000);
    try rig.engine.tick(65_000);
    try t.expectEqual(vocab.State.waiting_background, rig.engine.state);
    try t.expectEqual(@as(u32, 2), rig.engine.background_tasks);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    // Only the monitor left.
    rig.write(erase ++ live_monitor);
    try rig.feed(76_000);
    try rig.engine.tick(80_000);
    try t.expectEqual(vocab.State.waiting_background, rig.engine.state);
    try t.expectEqual(@as(u32, 1), rig.engine.background_tasks);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));

    // All done: the wake turn settles, and the footer that still says
    // what ran when the earlier turn ended is no live count.
    rig.write("\x1b]0;\xe2\x97\x90 C\x07\x1b]133;A\x07" ++ erase ++ " Background command \"sleep 75\" completed (exit code 0)\r\nclaude: All three finished.\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "Crunched for 1s \xc2\xb7 done 10:31 AM\r\n" ++ live);
    try rig.feed(90_000);
    try rig.engine.tick(95_000);
    try t.expectEqual(vocab.State.idle, rig.engine.state);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
}

test "the background count does not depend on the terminal's width" {
    // A session another client resized: the mode line wraps on a narrow
    // terminal, or carries more after the count on a wide one.
    for ([_]struct { cols: u16, line: []const u8, n: u32 }{
        .{ .cols = 30, .line = "manual mode on  \xc2\xb7  1 shell, 1 monitor", .n = 2 },
        .{ .cols = 200, .line = "manual mode on  \xc2\xb7  2 shells  \xc2\xb7  \xe2\x86\x93 to manage", .n = 2 },
    }) |c| {
        var rig: Rig = undefined;
        try rig.init(c.cols, 30);
        defer rig.deinit();
        rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
        try rig.feed(0);
        try rig.engine.tick(1000);
        rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07" ++ erase ++ "you: run them in the background\r\nclaude: Both started.\r\n" ++ live ++
            "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "Brewed for 3s \xc2\xb7 done\r\n" ++ status_rows);
        rig.write(c.line);
        rig.write("\r\n$");
        try rig.feed(1100);
        try rig.engine.tick(5000);
        try t.expectEqual(vocab.State.waiting_background, rig.engine.state);
        try t.expectEqual(c.n, rig.engine.background_tasks);
        try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    }
}

test "a background subagent alone holds the done, its row wrapped on a narrow terminal" {
    var rig: Rig = undefined;
    try rig.init(48, 30);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07" ++ erase ++ "you: start a subagent\r\nclaude: Started.\r\n" ++ live_agent_only ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase_7 ++ "Brewed for 3s \xc2\xb7 done\r\n" ++ live_agent_only);
    try rig.feed(1100);
    try rig.engine.tick(5000);
    try t.expectEqual(vocab.State.waiting_background, rig.engine.state);
    try t.expectEqual(@as(u32, 1), rig.engine.background_tasks);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    // Its row goes with the wake turn that reports it.
    rig.write("\x1b]0;\xe2\x97\x90 C\x07\x1b]133;A\x07" ++ erase_7 ++ " Agent \"sleep 60\" finished \xc2\xb7 60s\r\nclaude: SUB-DONE arrived.\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "Baked for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(61_000);
    try rig.engine.tick(65_000);
    try t.expectEqual(vocab.State.idle, rig.engine.state);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
}

test "claude /compact: a notice, never the summary, and only the command's own done" {
    var rig: Rig = undefined;
    try rig.init(100, 30);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07" ++ erase ++ "you: summarize it\r\nclaude: " ++ summary_lines ++ "\r\nclaude: and that is all.\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07" ++ erase ++ "Cogitated for 10s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(1100);
    try rig.engine.tick(5000);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
    const before = rig.engine.records.items.len;

    // Observed (2.1.286): the turn below the first prompt is erased and
    // reprinted shorter with a compaction line; the summary is never drawn.
    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x91 C\x07" ++ erase ++ "you: /compact\r\n" ++ live);
    try rig.feed(6000);
    rig.write("\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07\x1b[10A\x1b[J" ++
        "Conversation compacted (ctrl+o for history)\r\nclaude: and that is all.\r\nCogitated for 10s \xc2\xb7 done\r\n" ++
        "you: /compact\r\nCompacted (ctrl+o to see full summary)\r\nRead vocab.zig (158 lines)\r\n" ++ live);
    try rig.feed(30_000);
    try rig.engine.tick(40_000);
    try t.expectEqual(vocab.State.idle, rig.engine.state);
    const recs = rig.engine.records.items;
    // The first job is kept as captured; the command's job has its prompt
    // and the compaction notice, and no assistant message.
    try t.expectEqual(before + 2, recs.len);
    try t.expectEqual(vocab.RecordKind.notice, recs[recs.len - 1].kind);
    try t.expect(std.mem.startsWith(u8, recs[recs.len - 1].text, "Compacted ("));
    for (recs[before..]) |r| try t.expect(r.kind != .assistant);
    // Its own done (a new job), and no other.
    try t.expectEqual(@as(usize, 2), countKind(&rig.engine, .done));
    const done = rig.engine.queue.events.items[rig.engine.queue.events.items.len - 1];
    try t.expectEqual(@as(?u32, 1), done.job);
    try t.expectEqualStrings("", done.text);
}

test "a clear-and-reprint never duplicates, shrinks or re-adds a turn" {
    var rig: Rig = undefined;
    try rig.init(60, 6);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: old question\r\nclaude: old answer\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(1100);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: new question\r\nclaude: new answer line one\r\nline two\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(1200);
    try t.expectEqual(@as(usize, 4), rig.engine.records.items.len);
    const ids_before = [_]u64{ rig.engine.records.items[2].id, rig.engine.records.items[3].id };
    // Resize-style wipe: scrollback and screen cleared, a PARTIAL reprint
    // (the latest answer is cut short), then the next turn runs.
    rig.write("\x1b[3J\x1b[H\x1b[2Jyou: old question\r\nclaude: old answer\r\nyou: new question\r\nclaude: new answer line one\r\n" ++ live);
    try rig.feed(1300);
    try rig.engine.tick(4000);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: third question\r\nclaude: third answer\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(4100);
    // A full reprint later changes nothing either.
    rig.write("\x1b[3J\x1b[H\x1b[2Jyou: old question\r\nclaude: old answer\r\nBrewed for 1s \xc2\xb7 done\r\nyou: new question\r\nclaude: new answer line one\r\nline two\r\nBrewed for 1s \xc2\xb7 done\r\nyou: third question\r\nclaude: third answer\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(5000);
    rig.write("\x1b]133;A\x07\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(5100);
    try rig.engine.tick(9000);
    const recs = rig.engine.records.items;
    try t.expectEqual(@as(usize, 6), recs.len);
    try t.expectEqualStrings("new answer line one\nline two", recs[3].text);
    try t.expectEqual(ids_before[0], recs[2].id);
    try t.expectEqual(ids_before[1], recs[3].id);
    try t.expectEqualStrings("third question", recs[4].text);
    try t.expectEqualStrings("third answer", recs[5].text);
    try t.expectEqual(@as(usize, 3), rig.engine.turns.items.len);
    try t.expectEqual(@as(usize, 3), countKind(&rig.engine, .message));
}

test "same prompt: a new answer is a new turn, a reprint without an erase is not" {
    var rig: Rig = undefined;
    try rig.init(80, 40);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: continue\r\nclaude: step one\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(2000);
    // The app prints the whole transcript again below itself (no erase).
    rig.write(erase ++ "banner again\r\nyou: continue\r\nclaude: step one\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(2500);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: continue\r\nclaude: step two\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(3000);
    try t.expectEqual(@as(usize, 2), rig.engine.turns.items.len);
    try t.expectEqual(@as(usize, 4), rig.engine.records.items.len);
    try t.expectEqualStrings("step two", rig.engine.records.items[3].text);
    try t.expectEqual(@as(usize, 2), countKind(&rig.engine, .done));
    try t.expectEqual(@as(usize, 2), countKind(&rig.engine, .message));
}

test "a reprint of older turns below the transcript folds into them: no new job, no record under a second id" {
    // Modelled on a resumed claude agent that reprints its whole transcript
    // (no erase) whenever it redraws: the reprinted older turns have new,
    // higher line ids, and the first one's old copy is trimmed from history.
    var rig: Rig = undefined;
    try rig.init(80, 12);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    const a1 = "claude: The parser module splits records at every user prompt line.";
    const a2 = "claude: The screen engine folds each parsed turn into the captured jobs.";
    const t1 = "you: explain the parser\r\n" ++ a1 ++ "\r\nBrewed for 1s \xc2\xb7 done\r\n";
    const t2 = "you: explain the engine\r\n" ++ a2 ++ "\r\nBrewed for 1s \xc2\xb7 done\r\n";
    rig.write("\x1b]133;A\x07" ++ erase ++ t1 ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(1100);
    rig.write("\x1b]133;A\x07" ++ erase ++ t2 ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(1200);
    try rig.engine.tick(5000);
    try t.expectEqual(@as(usize, 2), rig.engine.turns.items.len);
    const ids = [_]u64{ rig.engine.records.items[1].id, rig.engine.records.items[3].id };
    // The whole transcript again, below the old copy, then a new turn.
    rig.write(erase ++ t1 ++ t2 ++ live);
    try rig.feed(6000);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: now the selection\r\nclaude: Selection picks the records a read returns per job.\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(7000);
    // Once more, with the new turn in it.
    rig.write(erase ++ t1 ++ t2 ++ "you: now the selection\r\nclaude: Selection picks the records a read returns per job.\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++ "\x1b]133;A\x07\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(8000);
    try rig.engine.tick(12_000);
    const recs = rig.engine.records.items;
    try t.expectEqual(@as(usize, 3), rig.engine.turns.items.len);
    try t.expectEqual(@as(usize, 6), recs.len);
    // A record already captured keeps its id.
    try t.expectEqual(ids[0], recs[1].id);
    try t.expectEqual(ids[1], recs[3].id);
    try t.expectEqualStrings("now the selection", recs[4].text);
    try t.expectEqual(@as(u32, 2), recs[5].job);
    // A same-prompt turn whose answer differs is still a new one.
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: explain the engine\r\nclaude: The engine now also drops what a redraw left in the scrollback.\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(13_000);
    try rig.engine.tick(20_000);
    try t.expectEqual(@as(usize, 4), rig.engine.turns.items.len);
}

test "a rendering that opens like a captured turn is that turn, whatever it draws after" {
    var rig: Rig = undefined;
    try rig.init(100, 40);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    const opening = "claude: Reading the screen engine to see where turns fold.\r\n" ++
        "tool: Bash (zig build test-core --summary all, filtered to the agent)\r\n" ++
        "claude: The fold misses reprints of older turns; writing a test first.\r\n";
    // Most of what follows differs between the two renderings (outputs
    // collapsed or expanded, notes placed elsewhere): only the opening holds.
    const captured_tail = "tool: Bash (zig test src/agent/screen_source.zig, first run)\r\n" ++
        "tool: Bash (zig test src/agent/grammar.zig, first run)\r\n" ++
        "tool: Bash (zig test src/agent/select.zig, first run)\r\n" ++
        "tool: Bash (zig test src/agent/launch.zig, first run)\r\n";
    const redrawn_tail = "tool: Edit (src/agent/screen_source.zig, the fold rule)\r\n" ++
        "tool: Edit (src/agent/grammar.zig, the stale copy rule)\r\n" ++
        "tool: Edit (docs/mcp.md, the sub-agent reference)\r\n" ++
        "tool: Edit (src/ipc/CLAUDE.md, the invariants)\r\n" ++
        "tool: Edit (docs/SESSION.md, the session log)\r\n";
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: fix the fold\r\n" ++ opening ++ captured_tail ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07" ++ erase ++ "Brewed for 9s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(1100);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: and the docs\r\nclaude: The docs now describe how a reprinted turn is folded.\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07" ++ erase ++ "Brewed for 2s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(1200);
    // The first turn drawn again below, its tool output collapsed this time.
    rig.write(erase ++ "you: fix the fold\r\n" ++ opening ++ redrawn_tail ++
        "you: and the docs\r\nclaude: The docs now describe how a reprinted turn is folded.\r\nBrewed for 2s \xc2\xb7 done\r\n" ++ live ++
        "\x1b]133;A\x07\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(2000);
    try rig.engine.tick(9000);
    try t.expectEqual(@as(usize, 2), rig.engine.turns.items.len);
    try t.expectEqual(@as(usize, 10), rig.engine.records.items.len);
}

test "a job's rendering that repeats the previous job's records leaves them there" {
    var rig: Rig = undefined;
    try rig.init(100, 40);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    const work = "tool: Bash (zig build test --summary all in the worktree)\r\n" ++
        "claude: The first test run shows two failures in the screen engine.\r\n" ++
        "tool: Bash (zig test src/agent/screen_source.zig with the filter)\r\n" ++
        "claude: Both failures come from the reprint rule; fixing it now.\r\n";
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: fix the tests\r\n" ++ work ++ live);
    try rig.feed(1100);
    // A prompt taken mid-turn, drawn ABOVE the turn's last records in this
    // rendering (claude places it differently in different renderings).
    rig.write(erase ++ "you: also report the timings\r\n" ++ work ++ "claude: Timings: the suite takes four seconds on this machine.\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(2000);
    try rig.engine.tick(9000);
    const recs = rig.engine.records.items;
    try t.expectEqual(@as(usize, 2), rig.engine.turns.items.len);
    // Job 1 holds its prompt and its own answer; job 0's records stay job 0's.
    var job1: usize = 0;
    for (recs) |r| {
        if (r.job == 1) job1 += 1;
    }
    try t.expectEqual(@as(usize, 2), job1);
    try t.expectEqualStrings("Timings: the suite takes four seconds on this machine.", recs[recs.len - 1].text);
}

test "a picker is live state: it never lands in the transcript" {
    var rig: Rig = undefined;
    try rig.init(80, 24);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    // A chrome line right below a record, above the status block, teaches
    // the block's height.
    rig.write("\x1b]133;A\x07\x1b]0;\xe2\x97\x90 C\x07" ++ erase ++ "you: hi\r\nclaude: hello\r\nBrewed for 1s \xc2\xb7 done\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07\x1b]0;\xe2\x9c\xb3 C\x07");
    try rig.feed(1050);
    try t.expectEqual(@as(usize, 2), rig.engine.status_rows);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: /effort\r\nEffort\r\n1. low\r\n2. (selected) high\r\n" ++
        "Select with numbers [1-2]. Then Enter to submit or Escape to cancel:");
    try rig.feed(1100);
    const it = rig.engine.interaction.?;
    try t.expectEqual(vocab.InteractionKind.choice, it.kind);
    try t.expectEqualStrings("Effort", it.title);
    try t.expect(it.options[1].selected);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .needs_input));
    try t.expectEqual(@as(usize, 3), rig.engine.records.items.len);
    try t.expectEqualStrings("/effort", rig.engine.records.items[2].text);
    // Answered: the picker is replaced by the command's output.
    rig.write("\r\x1b[3A\x1b[J" ++ "Set effort level to low\r\n" ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(1200);
    try rig.engine.tick(5000);
    try t.expect(rig.engine.interaction == null);
    try t.expectEqual(@as(usize, 4), rig.engine.records.items.len);
    try t.expectEqual(vocab.RecordKind.notice, rig.engine.records.items[3].kind);
    try t.expectEqualStrings("Set effort level to low", rig.engine.records.items[3].text);
    try t.expectEqual(vocab.State.idle, rig.engine.state);
}

test "errors, exit and synthetic notices" {
    var rig: Rig = undefined;
    try rig.init(80, 24);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: hi\r\nclaude: Usage limit reached \xc2\xb7 resets 5pm\r\n" ++ live);
    try rig.feed(1100);
    try rig.feed(1200);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .@"error"));
    const ev = rig.engine.queue.events.items[0];
    try t.expectEqual(vocab.ErrorClass.limit, ev.class.?);
    try t.expectEqualStrings("resets 5pm", ev.detail);

    rig.write("\x1b]133;C\x07\x1b]133;D\x07\x07" ++ erase ++ "Brewed for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(1300);
    try rig.engine.addNotice("denied: Bash (rm notes.md)");
    // A continuation of the same turn re-captures it and keeps the notice.
    rig.write("\x1b]133;A\x07" ++ erase ++ "claude: more\r\n" ++ live ++ "\x1b]133;C\x07\x1b]133;D\x07\x07" ++ erase ++ "Baked for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(1400);
    try rig.engine.tick(5000);
    const recs = rig.engine.records.items;
    try t.expectEqual(@as(usize, 4), recs.len);
    try t.expectEqualStrings("more", recs[2].text);
    try t.expect(recs[3].synthetic);
    try t.expectEqualStrings("denied: Bash (rm notes.md)", recs[3].text);
    // The continuation shows the same limit line again: folded, not repeated.
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .@"error"));

    try rig.engine.noteExited(6000, 1);
    try t.expectEqual(vocab.State.exited, rig.engine.state);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .exited));
    try t.expectEqual(@as(usize, 2), countKind(&rig.engine, .@"error"));
}

test "an adapter command: hidden turn, adopted picker, confirmation below it, no events" {
    var rig: Rig = undefined;
    try rig.init(80, 24);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    // An earlier confirmation must not count for this command.
    rig.write(erase ++ "Set model to Sonnet for this session only\r\n" ++ live);
    try rig.feed(1050);
    try rig.engine.beginCommand("/model");
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: /model\r\nSelect model\r\n1. Sonnet\r\n2. Haiku (selected)\r\n" ++
        "Select with numbers [1-2]. Then Enter to submit or Escape to cancel:");
    try rig.feed(1100);
    try t.expectEqual(vocab.State.waiting_user, rig.engine.state);
    try t.expect(rig.engine.interaction != null);
    // The recipe's own picker raises nothing.
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .needs_input));
    const rule = adapter.Matcher{ .prefix = "Set model to " };
    try t.expect(rig.engine.confirmLine(rule, "/model") == null);
    // Picked: the picker goes, the app confirms below the command.
    rig.write("\r\x1b[3A\x1b[JSet model to Haiku for this session only\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07");
    try rig.feed(1200);
    try t.expect(rig.engine.interaction == null);
    try t.expectEqualStrings("Set model to Haiku for this session only", rig.engine.confirmLine(rule, "/model").?);
    try rig.engine.addNotice("model set: Set model to Haiku for this session only");
    try rig.engine.endCommand(1250);
    try rig.engine.tick(9000);
    // Neither the command nor the app's echo of it is transcript; no turn
    // the assistant asked for ended, so no done and no message.
    var recs: std.ArrayList(Record) = .empty;
    defer recs.deinit(t.allocator);
    try rig.engine.recordsSince(0, &recs, t.allocator);
    try t.expectEqual(@as(usize, 1), recs.items.len);
    try t.expect(recs.items[0].synthetic);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .done));
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .needs_input));
    try t.expectEqual(vocab.State.idle, rig.engine.state);

    // The next real turn is transcript and ends with a done as always.
    rig.write("\x1b]133;A\x07" ++ erase ++ "you: hi\r\nclaude: hello\r\n" ++ live ++
        "\x1b]133;C\x07\x1b]133;D\x07\x07" ++ erase ++ "Brewed for 1s \xc2\xb7 done\r\n" ++ live);
    try rig.feed(10_000);
    try rig.engine.tick(20_000);
    recs.clearRetainingCapacity();
    try rig.engine.recordsSince(0, &recs, t.allocator);
    try t.expectEqual(@as(usize, 3), recs.items.len);
    try t.expectEqualStrings("hi", recs.items[1].text);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .done));
}

test "a command picker still showing when the recipe ends is announced then" {
    var rig: Rig = undefined;
    try rig.init(80, 24);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    try rig.engine.beginCommand("/model");
    rig.write(erase ++ "you: /model\r\nSelect model\r\n1. Sonnet\r\n2. Haiku (selected)\r\n" ++
        "Select with numbers [1-2]. Then Enter to submit or Escape to cancel:");
    try rig.feed(1100);
    try t.expectEqual(@as(usize, 0), countKind(&rig.engine, .needs_input));
    // The recipe failed and left it open: nobody else would answer it.
    try rig.engine.endCommand(1200);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .needs_input));
    try rig.feed(1300);
    try t.expectEqual(@as(usize, 1), countKind(&rig.engine, .needs_input));
}

test "a restart in place re-arms readiness without an event" {
    var rig: Rig = undefined;
    try rig.init(80, 24);
    defer rig.deinit();
    rig.write("\x1b]0;\xe2\x9c\xb3 C\x07" ++ live);
    try rig.feed(0);
    try rig.engine.tick(1000);
    try t.expect(rig.engine.ready);
    rig.engine.noteRestart();
    try t.expect(!rig.engine.ready);
    try t.expectEqual(vocab.State.starting, rig.engine.state);
    try rig.feed(1100);
    try rig.engine.tick(3000);
    try t.expect(rig.engine.ready);
    try t.expectEqual(@as(usize, 0), rig.engine.queue.events.items.len);
}
