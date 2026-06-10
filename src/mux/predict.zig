//! Predictive local echo for remote (mux) panes — mosh-style.
//!
//! When the user types a printable key on a high-latency link, the
//! GUI renders the glyph speculatively (underlined) before the real
//! echo arrives, then reconciles against the event stream. Pure
//! state machine: no GLib, no Screen dependency — the caller feeds
//! cursor state in and reads cells out, so everything unit-tests
//! headless with a fake clock.
//!
//! Safety model (mosh's "adaptive" mode): predictions are only
//! DISPLAYED while `confident` — i.e. after a previous prediction
//! was confirmed by a real echo. A password prompt (echo off) never
//! confirms, so nothing is ever shown there; the pending list times
//! out, flushes, and pauses prediction entirely for a while.

const std = @import("std");

/// One speculatively-rendered cell. `row`/`col` are active-screen
/// coordinates. This is also the renderer-facing overlay type.
pub const Cell = struct {
    row: u16,
    col: u16,
    cp: u21,
};

const Pending = struct {
    cell: Cell,
    sent_ms: i64,
};

/// Reads the authoritative screen during reconcile. `cpAt` returns
/// the base codepoint at (row, col) on the ACTIVE screen, 0 if blank.
pub const CellReader = struct {
    ctx: ?*anyopaque,
    cpAt: *const fn (ctx: ?*anyopaque, row: u16, col: u16) u21,
};

pub const Tuning = struct {
    /// Don't display predictions below this smoothed RTT — on a fast
    /// link the real echo beats the next frame anyway.
    display_threshold_ms: f64 = 60,
    /// Pending predictions older than max(this, 3*srtt) flush the
    /// whole list and pause prediction (echo is probably off).
    timeout_floor_ms: i64 = 1000,
    /// How long a timeout flush pauses new predictions.
    pause_ms: i64 = 5000,
};

pub const Predictor = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(Pending) = .empty,
    /// Renderer-facing mirror of `pending`, rebuilt on every change.
    overlay: std.ArrayList(Cell) = .empty,
    tuning: Tuning = .{},

    srtt_ms: f64 = 0,
    have_rtt: bool = false,
    /// Set when input goes out with no probe in flight; the next
    /// reconcile turns it into an RTT sample.
    rtt_probe_at: ?i64 = null,
    /// True once a prediction has been confirmed by a real echo;
    /// cleared on mispredict or timeout. Gates display.
    confident: bool = false,
    paused_until_ms: i64 = 0,
    /// Env override (SKETERM_PREDICT): show always / never.
    force: enum { auto, always, never } = .auto,

    pub fn init(allocator: std.mem.Allocator) Predictor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Predictor) void {
        self.pending.deinit(self.allocator);
        self.overlay.deinit(self.allocator);
    }

    /// User input went out. Predicts a single printable narrow
    /// codepoint; anything else (control keys, escape sequences,
    /// pastes) clears all outstanding predictions — cursor effects
    /// of those are not worth speculating about.
    pub fn onInput(
        self: *Predictor,
        bytes: []const u8,
        cursor_row: u16,
        cursor_col: u16,
        cols: u16,
        alt_screen: bool,
        now_ms: i64,
    ) void {
        if (self.rtt_probe_at == null) self.rtt_probe_at = now_ms;
        if (alt_screen or now_ms < self.paused_until_ms) {
            self.clearPending();
            return;
        }
        const cp = decodeSinglePrintable(bytes) orelse {
            // Enter usually hands the terminal to a new program state
            // (command output, password prompt, …): drop confidence so
            // the next prediction must re-confirm before displaying.
            if (std.mem.indexOfAny(u8, bytes, "\r\n") != null) self.confident = false;
            self.clearPending();
            return;
        };
        // Position: one past the previous outstanding prediction, or
        // the live cursor. No wrap prediction at the last column.
        var row = cursor_row;
        var col = cursor_col;
        if (self.pending.items.len > 0) {
            const last = self.pending.items[self.pending.items.len - 1].cell;
            row = last.row;
            col = last.col + 1;
        }
        if (col >= cols) return;
        self.pending.append(self.allocator, .{
            .cell = .{ .row = row, .col = col, .cp = cp },
            .sent_ms = now_ms,
        }) catch return;
        self.rebuildOverlay();
    }

    /// Server events were applied to the screen — confirm or kill
    /// predictions and fold the input→echo delay into the RTT.
    pub fn reconcile(self: *Predictor, reader: CellReader, now_ms: i64) void {
        if (self.rtt_probe_at) |t0| {
            const sample: f64 = @floatFromInt(now_ms - t0);
            self.srtt_ms = if (self.have_rtt)
                0.875 * self.srtt_ms + 0.125 * sample
            else
                sample;
            self.have_rtt = true;
            self.rtt_probe_at = null;
        }
        var changed = false;
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const p = self.pending.items[i];
            const actual = reader.cpAt(reader.ctx, p.cell.row, p.cell.col);
            if (actual == p.cell.cp) {
                self.confident = true;
                _ = self.pending.orderedRemove(i);
                changed = true;
                continue;
            }
            if (actual != 0 and actual != ' ') {
                // The cell got something else: mispredicted. Kill
                // everything and stop displaying until re-confirmed.
                self.confident = false;
                self.pending.clearRetainingCapacity();
                changed = true;
                break;
            }
            i += 1;
        }
        if (self.expire(now_ms)) changed = true;
        if (changed) self.rebuildOverlay();
    }

    /// Time-based flush — call from a timer as well as reconcile, so
    /// echo-less input (password prompts) can't leave stale glyphs.
    /// @return true if anything was dropped.
    pub fn expire(self: *Predictor, now_ms: i64) bool {
        if (self.pending.items.len == 0) return false;
        const timeout: i64 = @max(
            self.tuning.timeout_floor_ms,
            @as(i64, @intFromFloat(3 * self.srtt_ms)),
        );
        const oldest = self.pending.items[0].sent_ms;
        if (now_ms - oldest <= timeout) return false;
        self.pending.clearRetainingCapacity();
        self.confident = false;
        self.paused_until_ms = now_ms + self.tuning.pause_ms;
        self.rebuildOverlay();
        return true;
    }

    /// Whether the overlay should be drawn at all.
    pub fn shouldDisplay(self: *const Predictor) bool {
        switch (self.force) {
            .always => return true,
            .never => return false,
            .auto => {},
        }
        return self.confident and self.have_rtt and
            self.srtt_ms >= self.tuning.display_threshold_ms;
    }

    /// Renderer-facing slice — empty unless display is warranted.
    pub fn visibleCells(self: *const Predictor) []const Cell {
        if (!self.shouldDisplay()) return &.{};
        return self.overlay.items;
    }

    fn clearPending(self: *Predictor) void {
        if (self.pending.items.len == 0) return;
        self.pending.clearRetainingCapacity();
        self.rebuildOverlay();
    }

    fn rebuildOverlay(self: *Predictor) void {
        self.overlay.clearRetainingCapacity();
        self.overlay.ensureTotalCapacity(self.allocator, self.pending.items.len) catch return;
        for (self.pending.items) |p| self.overlay.appendAssumeCapacity(p.cell);
    }
};

/// Decode `bytes` as exactly one printable codepoint, or null.
/// Narrow only: anything >= U+1100 might be double-width and is not
/// worth a width-table dependency here.
fn decodeSinglePrintable(bytes: []const u8) ?u21 {
    if (bytes.len == 0 or bytes.len > 4) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (len != bytes.len) return null;
    const cp = std.unicode.utf8Decode(bytes) catch return null;
    if (cp < 0x20 or cp == 0x7f) return null;
    if (cp >= 0x80 and cp < 0xa0) return null; // C1
    if (cp >= 0x1100) return null;
    return cp;
}

// ---------------------------------------------------------------- tests

const FakeScreen = struct {
    cells: [4][80]u21 = @splat(@splat(0)),

    fn reader(self: *FakeScreen) CellReader {
        return .{ .ctx = @ptrCast(self), .cpAt = cpAt };
    }
    fn cpAt(ctx: ?*anyopaque, row: u16, col: u16) u21 {
        const self: *FakeScreen = @ptrCast(@alignCast(ctx.?));
        return self.cells[row][col];
    }
};

test "prediction confirmed by echo builds confidence" {
    var p = Predictor.init(std.testing.allocator);
    defer p.deinit();
    var fs = FakeScreen{};

    p.onInput("a", 0, 5, 80, false, 1000);
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
    try std.testing.expect(!p.shouldDisplay()); // not confident yet

    fs.cells[0][5] = 'a';
    p.reconcile(fs.reader(), 1200);
    try std.testing.expectEqual(@as(usize, 0), p.pending.items.len);
    try std.testing.expect(p.confident);
    try std.testing.expect(p.have_rtt);
    try std.testing.expectEqual(@as(f64, 200), p.srtt_ms);

    // Next keystroke displays (confident + 200ms RTT).
    p.onInput("b", 0, 6, 80, false, 1300);
    try std.testing.expect(p.shouldDisplay());
    try std.testing.expectEqual(@as(usize, 1), p.visibleCells().len);
    try std.testing.expectEqual(@as(u21, 'b'), p.visibleCells()[0].cp);
}

test "consecutive keystrokes predict at successive columns" {
    var p = Predictor.init(std.testing.allocator);
    defer p.deinit();
    p.onInput("h", 1, 10, 80, false, 0);
    p.onInput("i", 1, 10, 80, false, 50); // cursor not advanced yet
    try std.testing.expectEqual(@as(usize, 2), p.pending.items.len);
    try std.testing.expectEqual(@as(u16, 11), p.pending.items[1].cell.col);
}

test "mispredict kills all predictions and confidence" {
    var p = Predictor.init(std.testing.allocator);
    defer p.deinit();
    var fs = FakeScreen{};
    p.confident = true;
    p.onInput("x", 0, 0, 80, false, 0);
    fs.cells[0][0] = 'y'; // server echoed something else
    p.reconcile(fs.reader(), 100);
    try std.testing.expectEqual(@as(usize, 0), p.pending.items.len);
    try std.testing.expect(!p.confident);
}

test "echo-off input times out, flushes, and pauses prediction" {
    var p = Predictor.init(std.testing.allocator);
    defer p.deinit();
    var fs = FakeScreen{};
    p.onInput("s", 0, 0, 80, false, 0);
    p.reconcile(fs.reader(), 100); // no echo, not timed out yet
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
    try std.testing.expect(p.expire(2000)); // > timeout floor
    try std.testing.expectEqual(@as(usize, 0), p.pending.items.len);
    // Paused: new input is not predicted.
    p.onInput("e", 0, 1, 80, false, 2500);
    try std.testing.expectEqual(@as(usize, 0), p.pending.items.len);
    // Pause lapses.
    p.onInput("e", 0, 1, 80, false, 8000);
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
}

test "Enter drops confidence so password prompts never display" {
    var p = Predictor.init(std.testing.allocator);
    defer p.deinit();
    p.confident = true;
    p.have_rtt = true;
    p.srtt_ms = 300;
    p.onInput("\r", 0, 0, 80, false, 0);
    try std.testing.expect(!p.confident);
    // Secret chars after Enter are pending but never displayed.
    p.onInput("s", 1, 10, 80, false, 100);
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.visibleCells().len);
}

test "control bytes and alt screen clear predictions" {
    var p = Predictor.init(std.testing.allocator);
    defer p.deinit();
    p.onInput("a", 0, 0, 80, false, 0);
    p.onInput("\r", 0, 1, 80, false, 10);
    try std.testing.expectEqual(@as(usize, 0), p.pending.items.len);
    p.onInput("b", 0, 0, 80, false, 20);
    p.onInput("c", 0, 0, 80, true, 30); // alt screen
    try std.testing.expectEqual(@as(usize, 0), p.pending.items.len);
}

test "no prediction past the last column" {
    var p = Predictor.init(std.testing.allocator);
    defer p.deinit();
    p.onInput("z", 0, 79, 80, false, 0);
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
    p.onInput("w", 0, 79, 80, false, 10); // would be col 80
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
}

test "blank cell keeps prediction pending" {
    var p = Predictor.init(std.testing.allocator);
    defer p.deinit();
    var fs = FakeScreen{};
    p.onInput("q", 0, 3, 80, false, 0);
    p.reconcile(fs.reader(), 50);
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
}
