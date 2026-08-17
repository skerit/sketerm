//! Asciicast v2 + v3 reader (the asciinema file format), the counterpart
//! to `cast.zig`'s writer. Push-based and incremental: the caller feeds
//! arbitrary byte chunks and pulls whole events back out, so a poll loop
//! can drive it without ever blocking on a file. All event times are
//! normalized to ABSOLUTE milliseconds (v2's absolute seconds converted,
//! v3's per-event intervals accumulated) with `idle_time_limit` already
//! applied, so a consumer only ever sees a monotonic ms timeline. A cast
//! is untrusted input: lines are capped at 4 MiB, dimensions are bounded by
//! the one grid limit every entry point shares (`wire.validateTerminalSize`),
//! and every malformed line is a returned error rather than a crash.
//! musl-clean (pure std, no libc/GTK/GLib).

const std = @import("std");
const wire = @import("wire.zig");

/// Longest accepted line, header or event. A longer one is a hard error:
/// silently truncating would hand the terminal a torn escape sequence.
pub const max_line = 4 * 1024 * 1024;

pub const Error = error{
    LineTooLong,
    BadHeader,
    UnsupportedVersion,
    BadDimensions,
    BadEvent,
    OutOfMemory,
};

/// Raw theme strings as recorded; colors are left unparsed on purpose so
/// a consumer can apply whatever palette semantics it already has.
pub const Theme = struct {
    fg: ?[]u8 = null,
    bg: ?[]u8 = null,
    /// Colon-separated `#rrggbb` list, exactly as it appeared.
    palette: ?[]u8 = null,
};

pub const Header = struct {
    version: u8,
    cols: u16,
    rows: u16,
    /// Idle cap in ms, already validated to be > 0 when present.
    idle_time_limit_ms: ?u64 = null,
    /// Unix seconds when recording started.
    timestamp: ?i64 = null,
    title: ?[]u8 = null,
    /// v3 `term.type` (v2 recorders put this in `env.TERM`, which is not read).
    term_type: ?[]u8 = null,
    theme: Theme = .{},
};

pub const Event = union(enum) {
    /// Decoded terminal bytes; valid only until the next `next` call.
    output: []const u8,
    resize: struct { cols: u16, rows: u16 },
    /// Marker label, possibly empty; same lifetime as `output`.
    marker: []const u8,
    /// v3 exit event. Also accepted in v2 files, which cost nothing.
    exit: i32,
    /// User input. The data is discarded, the event is kept so callers
    /// can count or step over it.
    input,
};

pub const TimedEvent = struct {
    time_ms: u64,
    event: Event,
};

/// Incremental asciicast reader. Feed bytes, then drain with `next` until
/// it returns null; `next` returning null means "need more bytes" (or, once
/// `feedEof` was called and the buffer ran dry, `finished` is set).
pub const Player = struct {
    allocator: std.mem.Allocator,
    /// Unconsumed input.
    buf: std.ArrayList(u8) = .empty,
    /// Offset already searched for a line terminator.
    scanned: usize = 0,
    /// Position of the first pending newline, when one has been seen.
    nl: ?usize = null,
    /// Scratch for the current line and its JSON tree; reset per line.
    line_arena: std.heap.ArenaAllocator,
    /// Backing store for the slice handed out by the current event.
    data: std.ArrayList(u8) = .empty,
    header: ?Header = null,
    /// Emitted time of the previous event.
    prev_out_ms: u64 = 0,
    /// Source time of the previous event (v2 only; v3 carries intervals).
    prev_src_ms: u64 = 0,
    have_event: bool = false,
    eof: bool = false,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator) Player {
        return .{
            .allocator = allocator,
            .line_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Player) void {
        if (self.header) |*h| freeHeader(self.allocator, h);
        self.buf.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.line_arena.deinit();
    }

    /// Accumulate input. Fails immediately once an unterminated line grows
    /// past `max_line`, so a hostile file cannot be used to exhaust memory.
    pub fn feed(self: *Player, bytes: []const u8) Error!void {
        try self.buf.appendSlice(self.allocator, bytes);
        try self.rescan();
    }

    /// Declare the end of input; a final line without a trailing newline
    /// is parsed by the next `next` call.
    pub fn feedEof(self: *Player) void {
        self.eof = true;
    }

    fn rescan(self: *Player) Error!void {
        if (self.nl != null) return;
        if (std.mem.indexOfScalarPos(u8, self.buf.items, self.scanned, '\n')) |p| {
            self.nl = p;
        } else {
            self.scanned = self.buf.items.len;
            if (self.buf.items.len > max_line) return error.LineTooLong;
        }
    }

    fn consume(self: *Player, n: usize) Error!void {
        const rest = self.buf.items[n..];
        std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
        self.buf.shrinkRetainingCapacity(rest.len);
        self.nl = null;
        self.scanned = 0;
        try self.rescan();
    }

    /// Take the next complete line as an arena copy (CR and LF stripped),
    /// or null when more input is needed.
    fn takeLine(self: *Player) Error!?[]const u8 {
        _ = self.line_arena.reset(.retain_capacity);
        var raw: []const u8 = undefined;
        var take: usize = undefined;
        if (self.nl) |p| {
            if (p > max_line) return error.LineTooLong;
            raw = self.buf.items[0..p];
            take = p + 1;
        } else if (self.eof and self.buf.items.len > 0) {
            if (self.buf.items.len > max_line) return error.LineTooLong;
            raw = self.buf.items;
            take = raw.len;
        } else {
            if (self.eof) self.finished = true;
            return null;
        }
        const line = try self.line_arena.allocator().dupe(u8, std.mem.trimEnd(u8, raw, "\r"));
        try self.consume(take);
        return line;
    }

    /// Next event, or null when more input is needed. The header is parsed
    /// transparently from the first non-blank line and never surfaces here.
    pub fn next(self: *Player) Error!?TimedEvent {
        while (true) {
            const line = (try self.takeLine()) orelse return null;
            if (self.header == null) {
                if (line.len == 0) continue;
                self.header = try parseHeader(self.allocator, line);
                continue;
            }
            // v3 allows comments and blank lines anywhere after the header;
            // accepting them in v2 too costs nothing and no v2 file has them.
            if (line.len == 0 or line[0] == '#') continue;
            if (try self.parseEvent(line)) |ev| return ev;
        }
    }

    fn parseEvent(self: *Player, line: []const u8) Error!?TimedEvent {
        const v = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.line_arena.allocator(),
            line,
            .{},
        ) catch return error.BadEvent;
        const arr = switch (v) {
            .array => |a| a.items,
            else => return error.BadEvent,
        };
        if (arr.len < 2) return error.BadEvent;

        const secs = numberOf(arr[0]) orelse return error.BadEvent;
        const kind = switch (arr[1]) {
            .string => |s| s,
            else => return error.BadEvent,
        };
        if (kind.len != 1) return error.BadEvent;
        const data: []const u8 = if (arr.len >= 3) switch (arr[2]) {
            .string => |s| s,
            else => return error.BadEvent,
        } else "";

        const t_ms = try self.timeOf(secs);

        switch (kind[0]) {
            'o' => {
                self.data.clearRetainingCapacity();
                try self.data.appendSlice(self.allocator, data);
                return .{ .time_ms = t_ms, .event = .{ .output = self.data.items } };
            },
            'i' => return .{ .time_ms = t_ms, .event = .input },
            'm' => {
                self.data.clearRetainingCapacity();
                try self.data.appendSlice(self.allocator, data);
                return .{ .time_ms = t_ms, .event = .{ .marker = self.data.items } };
            },
            'r' => {
                const dim = parseDims(data) orelse return error.BadDimensions;
                return .{ .time_ms = t_ms, .event = .{ .resize = .{ .cols = dim[0], .rows = dim[1] } } };
            },
            'x' => {
                const s = std.mem.trim(u8, data, " \t");
                const code: i32 = if (s.len == 0) 0 else std.fmt.parseInt(i32, s, 10) catch
                    return error.BadEvent;
                return .{ .time_ms = t_ms, .event = .{ .exit = code } };
            },
            // Forward compat: an unknown single-letter type is skipped, but
            // its time still advances the clock.
            else => return null,
        }
    }

    /// Normalize one raw event time to an absolute, idle-clamped ms value.
    fn timeOf(self: *Player, secs: f64) Error!u64 {
        const h = self.header.?;
        const raw_ms = try msFromSeconds(secs);
        var delta: u64 = undefined;
        if (h.version >= 3) {
            // v3 times are intervals; a negative one is recorder jitter.
            delta = if (secs < 0) 0 else raw_ms;
        } else {
            if (secs < 0 and !self.have_event) return error.BadEvent;
            // Backwards jitter clamps to the previous time instead of erroring.
            delta = if (raw_ms <= self.prev_src_ms) 0 else raw_ms - self.prev_src_ms;
            self.prev_src_ms = @max(raw_ms, self.prev_src_ms);
        }
        if (h.idle_time_limit_ms) |cap| delta = @min(delta, cap);
        self.prev_out_ms += delta;
        self.have_event = true;
        return self.prev_out_ms;
    }
};

/// Absolute ms of a seconds value, rejecting anything that cannot be a
/// sane recording time (NaN, infinity, more than ~317 years).
fn msFromSeconds(secs: f64) Error!u64 {
    if (std.math.isNan(secs)) return error.BadEvent;
    const ms = @round(secs * 1000.0);
    if (!std.math.isFinite(ms)) return error.BadEvent;
    if (ms >= 1.0e16) return error.BadEvent;
    if (ms <= 0) return 0;
    return @intFromFloat(ms);
}

/// A JSON number as f64. `number_string` (what std.json falls back to for
/// values it cannot represent) is deliberately rejected.
fn numberOf(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn parseDims(s: []const u8) ?[2]u16 {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse return null;
    const cols = std.fmt.parseInt(u16, s[0..x], 10) catch return null;
    const rows = std.fmt.parseInt(u16, s[x + 1 ..], 10) catch return null;
    wire.validateTerminalSize(rows, cols) catch return null;
    return .{ cols, rows };
}

pub fn freeHeader(allocator: std.mem.Allocator, h: *Header) void {
    if (h.title) |s| allocator.free(s);
    if (h.term_type) |s| allocator.free(s);
    if (h.theme.fg) |s| allocator.free(s);
    if (h.theme.bg) |s| allocator.free(s);
    if (h.theme.palette) |s| allocator.free(s);
}

fn dupString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) Error!?[]u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    };
}

/// A JSON number as i64. The range guard is load-bearing: `@intFromFloat`
/// of an out-of-range value is undefined behaviour in ReleaseFast.
fn intOf(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and f >= -9.0e18 and f <= 9.0e18)
            @as(i64, @intFromFloat(f))
        else
            null,
        else => null,
    };
}

fn dimOf(obj: std.json.ObjectMap, key: []const u8) Error!u16 {
    const v = obj.get(key) orelse return error.BadHeader;
    const n = intOf(v) orelse return error.BadHeader;
    if (n < 1 or n > wire.MAX_TERMINAL_AXIS) return error.BadDimensions;
    return @intCast(n);
}

/// Per-axis bounds alone let a 4096x4096 header through; the total-cell
/// bound is the one that caps what the grid costs.
fn checkHeaderDims(h: Header) Error!void {
    wire.validateTerminalSize(h.rows, h.cols) catch return error.BadDimensions;
}

fn parseTheme(allocator: std.mem.Allocator, obj: std.json.ObjectMap) Error!Theme {
    const t = switch (obj.get("theme") orelse return .{}) {
        .object => |o| o,
        else => return .{},
    };
    var theme: Theme = .{};
    errdefer {
        if (theme.fg) |s| allocator.free(s);
        if (theme.bg) |s| allocator.free(s);
    }
    theme.fg = try dupString(allocator, t, "fg");
    theme.bg = try dupString(allocator, t, "bg");
    theme.palette = try dupString(allocator, t, "palette");
    return theme;
}

/// Parse the header line. Owns every string it returns (release with
/// `freeHeader`).
pub fn parseHeader(allocator: std.mem.Allocator, line: []const u8) Error!Header {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch
        return error.BadHeader;
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadHeader,
    };
    const ver = intOf(obj.get("version") orelse return error.BadHeader) orelse
        return error.BadHeader;
    if (ver != 2 and ver != 3) return error.UnsupportedVersion;

    var h: Header = .{ .version = @intCast(ver), .cols = 0, .rows = 0 };
    errdefer freeHeader(allocator, &h);

    if (ver == 3) {
        const term = switch (obj.get("term") orelse return error.BadHeader) {
            .object => |o| o,
            else => return error.BadHeader,
        };
        h.cols = try dimOf(term, "cols");
        h.rows = try dimOf(term, "rows");
        h.term_type = try dupString(allocator, term, "type");
        h.theme = try parseTheme(allocator, term);
    } else {
        h.cols = try dimOf(obj, "width");
        h.rows = try dimOf(obj, "height");
        h.theme = try parseTheme(allocator, obj);
    }
    try checkHeaderDims(h);
    h.title = try dupString(allocator, obj, "title");
    if (obj.get("timestamp")) |t| h.timestamp = intOf(t);
    if (obj.get("idle_time_limit")) |t| {
        if (numberOf(t)) |secs| {
            if (secs > 0) h.idle_time_limit_ms = try msFromSeconds(secs);
        }
    }
    return h;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const v2_sample =
    \\{"version": 2, "width": 80, "height": 24, "timestamp": 1700000000, "title": "demo", "env": {"TERM": "xterm-256color"}}
    \\[0.100000, "o", "hello\r\n"]
    \\[0.250000, "i", "q"]
    \\[1.500000, "r", "120x40"]
    \\[2.000000, "m", "chapter 1"]
    \\
;

const v3_sample =
    \\{"version": 3, "term": {"cols": 100, "rows": 30, "type": "xterm-256color"}}
    \\# a comment line
    \\[0.5, "o", "a"]
    \\
    \\[0.25, "o", "b"]
    \\[1.0, "r", "80x24"]
    \\[0.0, "x", "0"]
    \\
;

/// Drive a whole cast through a fresh player in one feed.
fn playAll(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList(TimedEvent)) !Player {
    var p = Player.init(allocator);
    errdefer p.deinit();
    try p.feed(text);
    p.feedEof();
    while (try p.next()) |ev| {
        // Slices point at the player's scratch, so copy any we keep.
        var copy = ev;
        switch (ev.event) {
            .output => |s| copy.event = .{ .output = try allocator.dupe(u8, s) },
            .marker => |s| copy.event = .{ .marker = try allocator.dupe(u8, s) },
            else => {},
        }
        try out.append(allocator, copy);
    }
    return p;
}

fn freeEvents(allocator: std.mem.Allocator, list: *std.ArrayList(TimedEvent)) void {
    for (list.items) |ev| switch (ev.event) {
        .output => |s| allocator.free(s),
        .marker => |s| allocator.free(s),
        else => {},
    };
    list.deinit(allocator);
}

test "v2: header fields and o/i/r/m events" {
    const a = testing.allocator;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, v2_sample, &evs);
    defer p.deinit();

    const h = p.header.?;
    try testing.expectEqual(@as(u8, 2), h.version);
    try testing.expectEqual(@as(u16, 80), h.cols);
    try testing.expectEqual(@as(u16, 24), h.rows);
    try testing.expectEqual(@as(i64, 1700000000), h.timestamp.?);
    try testing.expectEqualStrings("demo", h.title.?);
    try testing.expect(h.idle_time_limit_ms == null);
    try testing.expect(p.finished);

    try testing.expectEqual(@as(usize, 4), evs.items.len);
    try testing.expectEqual(@as(u64, 100), evs.items[0].time_ms);
    try testing.expectEqualStrings("hello\r\n", evs.items[0].event.output);
    try testing.expectEqual(@as(u64, 250), evs.items[1].time_ms);
    try testing.expect(evs.items[1].event == .input);
    try testing.expectEqual(@as(u64, 1500), evs.items[2].time_ms);
    try testing.expectEqual(@as(u16, 120), evs.items[2].event.resize.cols);
    try testing.expectEqual(@as(u16, 40), evs.items[2].event.resize.rows);
    try testing.expectEqual(@as(u64, 2000), evs.items[3].time_ms);
    try testing.expectEqualStrings("chapter 1", evs.items[3].event.marker);
}

test "v3: term object, intervals, comments, blanks, exit" {
    const a = testing.allocator;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, v3_sample, &evs);
    defer p.deinit();

    const h = p.header.?;
    try testing.expectEqual(@as(u8, 3), h.version);
    try testing.expectEqual(@as(u16, 100), h.cols);
    try testing.expectEqual(@as(u16, 30), h.rows);
    try testing.expectEqualStrings("xterm-256color", h.term_type.?);

    try testing.expectEqual(@as(usize, 4), evs.items.len);
    try testing.expectEqual(@as(u64, 500), evs.items[0].time_ms);
    try testing.expectEqualStrings("a", evs.items[0].event.output);
    try testing.expectEqual(@as(u64, 750), evs.items[1].time_ms);
    try testing.expectEqualStrings("b", evs.items[1].event.output);
    try testing.expectEqual(@as(u64, 1750), evs.items[2].time_ms);
    try testing.expectEqual(@as(u16, 80), evs.items[2].event.resize.cols);
    try testing.expectEqual(@as(u64, 1750), evs.items[3].time_ms);
    try testing.expectEqual(@as(i32, 0), evs.items[3].event.exit);
}

test "v2 theme strings are captured raw" {
    const a = testing.allocator;
    const text =
        \\{"version": 2, "width": 80, "height": 24, "theme": {"fg": "#d0d0d0", "bg": "#212121", "palette": "#000000:#ff0000"}}
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    const th = p.header.?.theme;
    try testing.expectEqualStrings("#d0d0d0", th.fg.?);
    try testing.expectEqualStrings("#212121", th.bg.?);
    try testing.expectEqualStrings("#000000:#ff0000", th.palette.?);
    try testing.expectEqual(@as(usize, 0), evs.items.len);
}

test "v3 theme lives under term" {
    const a = testing.allocator;
    const text =
        \\{"version": 3, "term": {"cols": 80, "rows": 24, "theme": {"fg": "#ffffff"}}}
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqualStrings("#ffffff", p.header.?.theme.fg.?);
}

test "idle_time_limit clamps the gap between events (v2)" {
    const a = testing.allocator;
    const text =
        \\{"version": 2, "width": 80, "height": 24, "idle_time_limit": 0.5}
        \\[1.0, "o", "a"]
        \\[10.0, "o", "b"]
        \\[10.2, "o", "c"]
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqual(@as(u64, 500), p.header.?.idle_time_limit_ms.?);
    try testing.expectEqual(@as(u64, 500), evs.items[0].time_ms); // 1.0s -> capped
    try testing.expectEqual(@as(u64, 1000), evs.items[1].time_ms); // +9s -> capped
    try testing.expectEqual(@as(u64, 1200), evs.items[2].time_ms); // +0.2s kept
}

test "idle_time_limit clamps intervals (v3)" {
    const a = testing.allocator;
    const text =
        \\{"version": 3, "term": {"cols": 80, "rows": 24}, "idle_time_limit": 2}
        \\[0.5, "o", "a"]
        \\[30.0, "o", "b"]
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqual(@as(u64, 2000), p.header.?.idle_time_limit_ms.?);
    try testing.expectEqual(@as(u64, 500), evs.items[0].time_ms);
    try testing.expectEqual(@as(u64, 2500), evs.items[1].time_ms);
}

test "non-positive idle_time_limit is ignored" {
    const a = testing.allocator;
    const text =
        \\{"version": 2, "width": 80, "height": 24, "idle_time_limit": 0}
        \\[3.0, "o", "a"]
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expect(p.header.?.idle_time_limit_ms == null);
    try testing.expectEqual(@as(u64, 3000), evs.items[0].time_ms);
}

test "byte-at-a-time feeding yields the same events" {
    const a = testing.allocator;
    var whole: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &whole);
    var p1 = try playAll(a, v2_sample, &whole);
    defer p1.deinit();

    var p2 = Player.init(a);
    defer p2.deinit();
    var got: usize = 0;
    for (v2_sample) |b| {
        try p2.feed(&[_]u8{b});
        while (try p2.next()) |ev| {
            try testing.expect(got < whole.items.len);
            const want = whole.items[got];
            try testing.expectEqual(want.time_ms, ev.time_ms);
            try testing.expectEqual(std.meta.activeTag(want.event), std.meta.activeTag(ev.event));
            switch (ev.event) {
                .output => |s| try testing.expectEqualStrings(want.event.output, s),
                .marker => |s| try testing.expectEqualStrings(want.event.marker, s),
                else => {},
            }
            got += 1;
        }
    }
    p2.feedEof();
    try testing.expect((try p2.next()) == null);
    try testing.expectEqual(whole.items.len, got);
    try testing.expect(p2.finished);
}

test "final line without a trailing newline still parses" {
    const a = testing.allocator;
    const text =
        "{\"version\": 2, \"width\": 80, \"height\": 24}\n" ++
        "[0.5, \"o\", \"tail\"]";
    var p = Player.init(a);
    defer p.deinit();
    try p.feed(text);
    // Without EOF the unterminated line must not be parsed yet.
    try testing.expect((try p.next()) == null);
    p.feedEof();
    const ev = (try p.next()).?;
    try testing.expectEqualStrings("tail", ev.event.output);
    try testing.expect((try p.next()) == null);
    try testing.expect(p.finished);
}

test "CRLF line endings are tolerated" {
    const a = testing.allocator;
    const text = "{\"version\": 2, \"width\": 80, \"height\": 24}\r\n[0.1, \"o\", \"x\"]\r\n";
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expectEqualStrings("x", evs.items[0].event.output);
}

test "unknown event types are skipped silently" {
    const a = testing.allocator;
    const text =
        \\{"version": 2, "width": 80, "height": 24}
        \\[0.1, "z", "who knows"]
        \\[0.2, "o", "a"]
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expectEqual(@as(u64, 200), evs.items[0].time_ms);
}

test "line longer than max_line is a hard error" {
    const a = testing.allocator;
    var p = Player.init(a);
    defer p.deinit();
    try p.feed("{\"version\": 2, \"width\": 80, \"height\": 24}\n");
    _ = try p.next();
    const chunk = try a.alloc(u8, 64 * 1024);
    defer a.free(chunk);
    @memset(chunk, 'a');
    var fed: usize = 0;
    while (fed <= max_line) : (fed += chunk.len) {
        p.feed(chunk) catch |e| {
            try testing.expectEqual(Error.LineTooLong, e);
            return;
        };
    }
    return error.TestExpectedLineTooLong;
}

test "an over-long but terminated line is also rejected" {
    const a = testing.allocator;
    var p = Player.init(a);
    defer p.deinit();
    const big = try a.alloc(u8, max_line + 8);
    defer a.free(big);
    @memset(big, 'a');
    big[big.len - 1] = '\n';
    // feed must not fault (the newline is present), next must reject.
    try p.feed(big);
    try testing.expectError(Error.LineTooLong, p.next());
}

test "bad header dimensions are rejected" {
    const a = testing.allocator;
    inline for (.{
        "{\"version\": 2, \"width\": 0, \"height\": 24}\n",
        "{\"version\": 2, \"width\": 80, \"height\": 5000}\n",
        "{\"version\": 3, \"term\": {\"cols\": 99999, \"rows\": 24}}\n",
    }) |text| {
        var p = Player.init(a);
        defer p.deinit();
        try p.feed(text);
        try testing.expectError(Error.BadDimensions, p.next());
    }
}

test "bad resize dimensions are rejected" {
    const a = testing.allocator;
    const text =
        \\{"version": 2, "width": 80, "height": 24}
        \\[0.1, "r", "0x24"]
        \\
    ;
    var p = Player.init(a);
    defer p.deinit();
    try p.feed(text);
    try testing.expectError(Error.BadDimensions, p.next());
}

test "malformed resize payload is rejected" {
    const a = testing.allocator;
    const text =
        \\{"version": 2, "width": 80, "height": 24}
        \\[0.1, "r", "wide"]
        \\
    ;
    var p = Player.init(a);
    defer p.deinit();
    try p.feed(text);
    try testing.expectError(Error.BadDimensions, p.next());
}

test "version 4 and missing version are rejected" {
    const a = testing.allocator;
    {
        var p = Player.init(a);
        defer p.deinit();
        try p.feed("{\"version\": 4, \"width\": 80, \"height\": 24}\n");
        try testing.expectError(Error.UnsupportedVersion, p.next());
    }
    {
        var p = Player.init(a);
        defer p.deinit();
        try p.feed("{\"width\": 80, \"height\": 24}\n");
        try testing.expectError(Error.BadHeader, p.next());
    }
}

test "non-object and non-JSON header lines are rejected" {
    const a = testing.allocator;
    inline for (.{ "[1, 2, 3]\n", "not json at all\n", "\"just a string\"\n" }) |text| {
        var p = Player.init(a);
        defer p.deinit();
        try p.feed(text);
        try testing.expectError(Error.BadHeader, p.next());
    }
}

test "malformed event lines are rejected without crashing" {
    const a = testing.allocator;
    inline for (.{
        "[0.1, \"o\"\n", // truncated JSON
        "{\"t\": 1}\n", // object, not array
        "[0.1]\n", // too few elements
        "[\"x\", \"o\", \"a\"]\n", // time is not a number
        "[0.1, 5, \"a\"]\n", // type is not a string
        "[0.1, \"oo\", \"a\"]\n", // type is not one letter
        "[0.1, \"o\", 5]\n", // data is not a string
    }) |text| {
        var p = Player.init(a);
        defer p.deinit();
        try p.feed("{\"version\": 2, \"width\": 80, \"height\": 24}\n");
        try p.feed(text);
        try testing.expectError(Error.BadEvent, p.next());
    }
}

test "v2 backwards timestamps clamp to the previous time" {
    const a = testing.allocator;
    const text =
        \\{"version": 2, "width": 80, "height": 24}
        \\[1.0, "o", "a"]
        \\[0.4, "o", "b"]
        \\[1.5, "o", "c"]
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqual(@as(u64, 1000), evs.items[0].time_ms);
    try testing.expectEqual(@as(u64, 1000), evs.items[1].time_ms);
    try testing.expectEqual(@as(u64, 1500), evs.items[2].time_ms);
}

test "a negative first v2 time is rejected, a later one clamps" {
    const a = testing.allocator;
    {
        var p = Player.init(a);
        defer p.deinit();
        try p.feed("{\"version\": 2, \"width\": 80, \"height\": 24}\n[-0.5, \"o\", \"a\"]\n");
        try testing.expectError(Error.BadEvent, p.next());
    }
    {
        var evs: std.ArrayList(TimedEvent) = .empty;
        defer freeEvents(a, &evs);
        var p = try playAll(
            a,
            "{\"version\": 2, \"width\": 80, \"height\": 24}\n[0.5, \"o\", \"a\"]\n[-1.0, \"o\", \"b\"]\n",
            &evs,
        );
        defer p.deinit();
        try testing.expectEqual(@as(u64, 500), evs.items[1].time_ms);
    }
}

test "a negative v3 interval counts as zero" {
    const a = testing.allocator;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(
        a,
        "{\"version\": 3, \"term\": {\"cols\": 80, \"rows\": 24}}\n[-1.0, \"o\", \"a\"]\n[0.25, \"o\", \"b\"]\n",
        &evs,
    );
    defer p.deinit();
    try testing.expectEqual(@as(u64, 0), evs.items[0].time_ms);
    try testing.expectEqual(@as(u64, 250), evs.items[1].time_ms);
}

test "absurd times are rejected rather than wrapping" {
    const a = testing.allocator;
    inline for (.{ "[1e300, \"o\", \"a\"]\n", "[1e999, \"o\", \"a\"]\n" }) |text| {
        var p = Player.init(a);
        defer p.deinit();
        try p.feed("{\"version\": 2, \"width\": 80, \"height\": 24}\n");
        try p.feed(text);
        try testing.expectError(Error.BadEvent, p.next());
    }
}

test "unicode escapes including a surrogate pair decode" {
    const a = testing.allocator;
    const text = "{\"version\": 2, \"width\": 80, \"height\": 24}\n" ++
        "[0.1, \"o\", \"\\u00e9 \\u001b[1m \\ud83d\\ude00 \\\\ \\\" \\t\"]\n";
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqualStrings("\u{e9} \x1b[1m \u{1f600} \\ \" \t", evs.items[0].event.output);
}

test "empty data strings and a missing data element" {
    const a = testing.allocator;
    const text =
        \\{"version": 2, "width": 80, "height": 24}
        \\[0.1, "o", ""]
        \\[0.2, "m", ""]
        \\[0.3, "m"]
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), evs.items.len);
    try testing.expectEqualStrings("", evs.items[0].event.output);
    try testing.expectEqualStrings("", evs.items[1].event.marker);
    try testing.expectEqualStrings("", evs.items[2].event.marker);
}

test "equal timestamps keep their order" {
    const a = testing.allocator;
    const text =
        \\{"version": 2, "width": 80, "height": 24}
        \\[0.5, "o", "one"]
        \\[0.5, "o", "two"]
        \\[0.5, "o", "three"]
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), evs.items.len);
    for (evs.items) |ev| try testing.expectEqual(@as(u64, 500), ev.time_ms);
    try testing.expectEqualStrings("one", evs.items[0].event.output);
    try testing.expectEqualStrings("two", evs.items[1].event.output);
    try testing.expectEqualStrings("three", evs.items[2].event.output);
}

test "exit status values" {
    const a = testing.allocator;
    const text =
        \\{"version": 3, "term": {"cols": 80, "rows": 24}}
        \\[0.1, "x", "130"]
        \\[0.1, "x", ""]
        \\
    ;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, text, &evs);
    defer p.deinit();
    try testing.expectEqual(@as(i32, 130), evs.items[0].event.exit);
    try testing.expectEqual(@as(i32, 0), evs.items[1].event.exit);
}

test "a non-numeric exit status is rejected" {
    const a = testing.allocator;
    var p = Player.init(a);
    defer p.deinit();
    try p.feed("{\"version\": 3, \"term\": {\"cols\": 80, \"rows\": 24}}\n[0.1, \"x\", \"boom\"]\n");
    try testing.expectError(Error.BadEvent, p.next());
}

test "leading blank lines before the header are skipped" {
    const a = testing.allocator;
    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, "\n\n{\"version\": 2, \"width\": 80, \"height\": 24}\n[0.1, \"o\", \"a\"]\n", &evs);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), evs.items.len);
}

test "empty input finishes without a header" {
    const a = testing.allocator;
    var p = Player.init(a);
    defer p.deinit();
    p.feedEof();
    try testing.expect((try p.next()) == null);
    try testing.expect(p.finished);
    try testing.expect(p.header == null);
}

test "output data written by cast.zig round-trips" {
    const a = testing.allocator;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    try line.appendSlice(a, "{\"version\": 2, \"width\": 80, \"height\": 24}\n");
    const payload = "esc:\x1b[31m tab:\t quote:\" back:\\ utf8:\u{e9}\u{1f600}";
    try @import("cast.zig").appendEvent(a, &line, 1234, 'o', payload);

    var evs: std.ArrayList(TimedEvent) = .empty;
    defer freeEvents(a, &evs);
    var p = try playAll(a, line.items, &evs);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expectEqual(@as(u64, 1234), evs.items[0].time_ms);
    try testing.expectEqualStrings(payload, evs.items[0].event.output);
}
