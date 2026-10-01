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
    alnum: usize,
    /// The prompt is an adapter command (`Engine.beginCommand`): the turn
    /// keeps only synthetic records and raises no events.
    hidden: bool = false,
};

/// Wait this long after a retrying error first shows before surfacing it.
pub const RETRY_SURFACE_MS: i64 = vocab.ErrorClass.retrying.surfaceAfterMs();
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
        self.disconnected = false;
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
        if (self.input_row) |in| {
            if (grammar.measureStatusRows(sc, self.rows.items, in, MAX_STATUS_ROWS)) |n| self.status_rows = n;
            grammar.markLive(sc, self.rows.items, in, self.status_rows);
            self.input_text = try grammar.inputText(self.allocator, sc, self.rows.items, in);
        }
        self.subagent_visible = self.subagentInTail();

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

        self.state = if (!self.ready)
            .starting
        else if (self.interaction != null)
            .waiting_user
        else if (self.retrying_visible)
            .retrying
        else if (self.title_busy or self.turn_open or self.end_pending)
            (if (self.subagent_visible) .waiting_subagent else .working)
        else if (self.subagent_visible)
            .waiting_subagent
        else
            .idle;

        if (self.state == .idle and self.done_armed and self.captured_since_end) {
            self.done_armed = false;
            // An adapter command's turn is not a turn the assistant asked for.
            const n = self.turns.items.len;
            if (n > 0 and !self.turns.items[n - 1].hidden) {
                const job: u32 = @intCast(n - 1);
                const end = self.waker.segmentEnd(self.records.items, job);
                if (end.wake) _ = try self.queue.pushDone(now_ms, job, end.answer);
            }
        }
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

        fn init(arena: std.mem.Allocator, recs: []const grammar.Rec) !Parsed {
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
        const alnum = p.alnum;

        const cur = self.wipe_seq;
        const n_turns = self.turns.items.len;
        if (n_turns > 0) {
            const last = &self.turns.items[n_turns - 1];
            // Already captured, by identity (line ids are only an identity
            // between wipes: an erase keeps row ids for new content). Only
            // the latest turn can still grow.
            for (self.turns.items, 0..) |tn, ti| {
                if (tn.wipe_seq != cur or tn.user_line_id != p.line_id or !grammar.samePrompt(tn.key, key)) continue;
                if (ti == n_turns - 1 and alnum >= last.alnum) try self.replaceLast(recs, alnum, complete);
                return;
            }
            // The latest turn printed again without an erase (claude does
            // that too): same prompt and one's content a prefix of the
            // other's. It keeps its identity, so a same-prompt turn whose
            // answer then diverges is still a new turn.
            if (last.wipe_seq == cur and grammar.samePrompt(last.key, key) and self.lastTurnCopiedBy(p)) {
                if (alnum > last.alnum) try self.replaceLast(recs, alnum, complete);
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
                    if (alnum >= last.alnum) try self.replaceLast(recs, alnum, complete);
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
        try self.replaceLast(recs, alnum, complete);
    }

    /// Whether the latest turn's screen records and `p` are copies (one's
    /// alphanumerics a prefix of the other's).
    fn lastTurnCopiedBy(self: *const Engine, p: Parsed) bool {
        const turn = self.turns.items[self.turns.items.len - 1];
        var pos: usize = 0;
        var diverged = false;
        outer: for (self.records.items[turn.first..]) |r| {
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

    /// Replace the latest turn's screen records with `recs`, keeping the id
    /// of every record whose text did not change and its synthetic notices.
    fn replaceLast(self: *Engine, all_recs: []const grammar.Rec, alnum: usize, complete: bool) !void {
        const ti = self.turns.items.len - 1;
        const turn = &self.turns.items[ti];
        turn.alnum = alnum;
        // An adapter command leaves only what the adapter recorded of it.
        const recs = if (turn.hidden) all_recs[0..0] else all_recs;
        const old = self.records.items[turn.first..];

        var fresh: std.ArrayList(Record) = .empty;
        errdefer {
            for (fresh.items) |r| self.allocator.free(r.text);
            fresh.deinit(self.allocator);
        }
        var old_screen: usize = 0;
        for (recs) |r| {
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
            _ = try self.queue.push(self.clock_ms, .message, null, r.text, "");
        }
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
