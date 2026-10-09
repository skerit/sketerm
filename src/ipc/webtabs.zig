//! What the `web_*` tools remember about each browser tab beside the
//! backend that hosts it: the caller's LABEL, when the tab was last
//! TOUCHED (addressed by a tool, opened, or watched), and the tabs the
//! idle sweep closed, so a late call on one is told why it is gone.
//!
//! Several assistants (sub-agents) can share one server's browser, so
//! these are the facts that keep them off each other's tabs. Pure data,
//! std-only; `mcp_web.zig` is the one consumer and decides policy.

const std = @import("std");

/// Longest label `web_open` takes, in bytes.
pub const LABEL_MAX: usize = 64;

/// Built-in idle time after which an unwatched assistant tab closes
/// itself (`web_idle_close_secs` overrides it; 0 turns it off).
pub const DEFAULT_IDLE_CLOSE_SECS: u32 = 1800;
/// Upper bound for `web_idle_close_secs`: one week.
pub const MAX_IDLE_CLOSE_SECS: u32 = 7 * 24 * 3600;

/// How many idle-closed tabs are remembered for the not-found message.
pub const CLOSED_KEEP: usize = 16;

/// Which tab ids the answering backend hands out: headless view ids are
/// random and never reused by the server; GUI pane ids are the GUI's own
/// (the ids list_terminals reports). The `web_tab_rules.ids` vocabulary.
pub const TabIds = enum { random, gui_pane };

/// A label is one short line a person can read: 1-64 bytes of UTF-8,
/// no control characters.
pub fn validLabel(s: []const u8) bool {
    if (s.len == 0 or s.len > LABEL_MAX) return false;
    if (!std.unicode.utf8ValidateSlice(s)) return false;
    for (s) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

/// One tab: the handle a tool takes plus, with a GUI, the page inside
/// that pane (a pane holds several pages; 0 headless, where the handle
/// is the page).
pub const Key = struct {
    handle: u32,
    page: u32 = 0,

    fn eql(a: Key, b: Key) bool {
        return a.handle == b.handle and a.page == b.page;
    }
};

const Entry = struct {
    key: Key,
    /// Owned; null when the tab was opened without one.
    label: ?[]u8 = null,
    touched_ms: i64,
};

/// A tab the idle sweep closed.
pub const Closed = struct {
    handle: u32,
    idle_ms: i64,
    closed_ms: i64,
    label_buf: [LABEL_MAX]u8 = undefined,
    label_len: usize = 0,
    url_buf: [256]u8 = undefined,
    url_len: usize = 0,

    pub fn label(self: *const Closed) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    pub fn url(self: *const Closed) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

pub const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    closed: [CLOSED_KEEP]?Closed = @splat(null),
    closed_next: usize = 0,

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| if (e.label) |l| gpa.free(l);
        self.entries.deinit(gpa);
        self.* = .{};
    }

    fn find(self: *Table, key: Key) ?*Entry {
        for (self.entries.items) |*e| if (e.key.eql(key)) return e;
        return null;
    }

    fn ensure(self: *Table, gpa: std.mem.Allocator, key: Key, now_ms: i64) !*Entry {
        if (self.find(key)) |e| return e;
        try self.entries.append(gpa, .{ .key = key, .touched_ms = now_ms });
        return &self.entries.items[self.entries.items.len - 1];
    }

    /// The tab was used now: by a tool, by being opened, or by a person
    /// watching it.
    pub fn touch(self: *Table, gpa: std.mem.Allocator, key: Key, now_ms: i64) !void {
        (try self.ensure(gpa, key, now_ms)).touched_ms = now_ms;
    }

    /// When the tab was last used. A tab first seen here (a popup the
    /// page opened, a tab from before this server knew it) starts now.
    pub fn touchedMs(self: *Table, gpa: std.mem.Allocator, key: Key, now_ms: i64) !i64 {
        return (try self.ensure(gpa, key, now_ms)).touched_ms;
    }

    pub fn setLabel(self: *Table, gpa: std.mem.Allocator, key: Key, label: []const u8, now_ms: i64) !void {
        const owned = try gpa.dupe(u8, label);
        errdefer gpa.free(owned);
        const e = try self.ensure(gpa, key, now_ms);
        if (e.label) |old| gpa.free(old);
        e.label = owned;
    }

    pub fn labelOf(self: *Table, key: Key) []const u8 {
        const e = self.find(key) orelse return "";
        return e.label orelse "";
    }

    /// Drop every tab not in `live`: closed by a tool, by the page, or
    /// lost with its browser.
    pub fn retain(self: *Table, gpa: std.mem.Allocator, live: []const Key) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            var keep = false;
            for (live) |k| if (k.eql(e.key)) {
                keep = true;
                break;
            };
            if (keep) {
                i += 1;
                continue;
            }
            if (e.label) |l| gpa.free(l);
            _ = self.entries.swapRemove(i);
        }
    }

    pub fn noteClosed(self: *Table, handle: u32, label: []const u8, url: []const u8, idle_ms: i64, now_ms: i64) void {
        var rec = Closed{ .handle = handle, .idle_ms = idle_ms, .closed_ms = now_ms };
        rec.label_len = @min(label.len, rec.label_buf.len);
        @memcpy(rec.label_buf[0..rec.label_len], label[0..rec.label_len]);
        rec.url_len = @min(url.len, rec.url_buf.len);
        @memcpy(rec.url_buf[0..rec.url_len], url[0..rec.url_len]);
        self.closed[self.closed_next] = rec;
        self.closed_next = (self.closed_next + 1) % CLOSED_KEEP;
    }

    pub fn closedRecord(self: *const Table, handle: u32) ?Closed {
        for (self.closed) |rec| if (rec) |r| if (r.handle == handle) return r;
        return null;
    }
};

/// Where one tab stands against the idle rule.
pub const Idle = union(enum) {
    /// Idle closing is turned off (`web_idle_close_secs = 0`) or does
    /// not apply to this backend.
    off,
    /// A person is watching or driving it; it never closes meanwhile.
    watched,
    /// The browser cannot say whether anyone watches, so it is kept.
    unknown,
    /// Milliseconds until it closes itself; 0 = due now.
    closes_in_ms: i64,
};

/// The idle verdict from the facts: `watched` null = not knowable.
pub fn idleOf(idle_ms: i64, touched_ms: i64, now_ms: i64, watched: ?bool) Idle {
    if (idle_ms <= 0) return .off;
    const w = watched orelse return .unknown;
    if (w) return .watched;
    return .{ .closes_in_ms = @max(touched_ms + idle_ms - now_ms, 0) };
}

/// Whether a call naming no tab must be refused: more than one tab is
/// open, so "the current one" would be a guess another caller may just
/// have changed. Counts distinct handles (a GUI pane with several pages
/// is one handle).
pub fn targetRequired(handles: []const u32) bool {
    if (handles.len < 2) return false;
    for (handles[1..]) |h| if (h != handles[0]) return true;
    return false;
}

const t = std.testing;

test "labels are short single lines of UTF-8" {
    try t.expect(validLabel("scan-a"));
    try t.expect(validLabel("caf\xc3\xa9 tab"));
    try t.expect(!validLabel(""));
    try t.expect(!validLabel("a" ** (LABEL_MAX + 1)));
    try t.expect(validLabel("a" ** LABEL_MAX));
    try t.expect(!validLabel("two\nlines"));
    try t.expect(!validLabel("\xff"));
}

test "a table keeps labels and touches per tab and forgets closed tabs" {
    const gpa = t.allocator;
    var tab: Table = .{};
    defer tab.deinit(gpa);
    const a = Key{ .handle = 7 };
    const b = Key{ .handle = 9, .page = 2 };
    try tab.setLabel(gpa, a, "scan-a", 100);
    try tab.setLabel(gpa, a, "scan-b", 100);
    try t.expectEqualStrings("scan-b", tab.labelOf(a));
    try t.expectEqual(@as(i64, 100), try tab.touchedMs(gpa, a, 500));
    // First sighting starts the clock now.
    try t.expectEqual(@as(i64, 500), try tab.touchedMs(gpa, b, 500));
    try tab.touch(gpa, a, 900);
    try t.expectEqual(@as(i64, 900), try tab.touchedMs(gpa, a, 1000));
    tab.retain(gpa, &.{b});
    try t.expectEqualStrings("", tab.labelOf(a));
    try t.expectEqual(@as(usize, 1), tab.entries.items.len);
}

test "the closed ring remembers the newest idle closes" {
    var tab: Table = .{};
    defer tab.deinit(t.allocator);
    var i: u32 = 0;
    while (i < CLOSED_KEEP + 3) : (i += 1) tab.noteClosed(i + 1, "l", "https://x/", 60_000, 5);
    try t.expect(tab.closedRecord(1) == null);
    const r = tab.closedRecord(CLOSED_KEEP + 3).?;
    try t.expectEqualStrings("l", r.label());
    try t.expectEqualStrings("https://x/", r.url());
}

test "idle verdicts: off, watched, unknown, countdown" {
    try t.expectEqual(Idle.off, idleOf(0, 0, 10, false));
    try t.expectEqual(Idle.watched, idleOf(1000, 0, 5000, true));
    try t.expectEqual(Idle.unknown, idleOf(1000, 0, 5000, null));
    try t.expectEqual(Idle{ .closes_in_ms = 400 }, idleOf(1000, 0, 600, false));
    try t.expectEqual(Idle{ .closes_in_ms = 0 }, idleOf(1000, 0, 5000, false));
}

test "a target is required only with two distinct handles" {
    try t.expect(!targetRequired(&.{}));
    try t.expect(!targetRequired(&.{4}));
    try t.expect(!targetRequired(&.{ 4, 4 }));
    try t.expect(targetRequired(&.{ 4, 5 }));
}
