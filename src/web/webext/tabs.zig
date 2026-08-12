//! `browser.tabs` — the tab table and the event diff.
//!
//! **The GUI owns the real tab set; the helper only mirrors it.** A
//! browser helper hosts VIEWS, which are not tabs: one GUI tab may show
//! a view, a pane in a split shows another, and a background page is a
//! view that is no tab at all. Inventing tab identity here would make
//! every extension's per-tab state quietly wrong (uBO's `PageStore` is
//! keyed on tab ids), so the identity comes from the side that has it.
//!
//! The seam is deliberately REPLACE-ALL, like `us_script_set`: the
//! client posts the whole tab list whenever it changes, and this module
//! DIFFS it against what it held to synthesise MV2's
//! `onCreated`/`onUpdated`/`onRemoved`/`onActivated`. One frame on the
//! wire, no incremental-update protocol to get out of sync, and the
//! events an extension sees are derived from state rather than from a
//! sequence a dropped frame could break.
//!
//! Pure std, no CEF, no GTK: in both test roots.

const std = @import("std");
const match = @import("match.zig");

/// A JSON integer narrowed to u32, or null when it is negative or does
/// not fit.
///
/// Extension-supplied values are untrusted and this tree builds
/// ReleaseFast, where an out-of-range `@intCast` TRUNCATES silently
/// rather than trapping — so `@intCast(@max(v, 0))` turned a large id
/// into a small valid one instead of rejecting it. Callers decide what
/// out-of-range means; none of them may narrow it themselves.
pub fn u32Of(v: std.json.Value) ?u32 {
    if (v != .integer) return null;
    if (v.integer < 0 or v.integer > std.math.maxInt(u32)) return null;
    return @intCast(v.integer);
}

/// One tab as the client describes it. Slices are borrowed for the
/// duration of a `replace` call; the table copies what it keeps.
pub const Incoming = struct {
    id: u32,
    /// The helper view rendering this tab, 0 when the tab shows no web
    /// view at all (a terminal tab, a file-browser tab).
    view: u32 = 0,
    window_id: u32 = 0,
    index: u32 = 0,
    active: bool = false,
    /// The window this tab is in has the focus.
    focused_window: bool = false,
    url: []const u8 = "",
    title: []const u8 = "",
    /// `loading` / `complete`, MV2's `Tab.status`.
    loading: bool = false,
};

pub const Tab = struct {
    id: u32,
    view: u32,
    window_id: u32,
    index: u32,
    active: bool,
    focused_window: bool,
    url: []u8,
    title: []u8,
    loading: bool,

    fn deinit(self: *Tab, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        gpa.free(self.title);
    }
};

/// What changed about one tab. `url`/`title`/`status` mirror the
/// `changeInfo` keys MV2 delivers with `onUpdated`.
pub const Change = struct {
    id: u32,
    url: bool = false,
    title: bool = false,
    status: bool = false,

    pub fn any(self: Change) bool {
        return self.url or self.title or self.status;
    }
};

pub const Diff = struct {
    created: []u32 = &.{},
    removed: []u32 = &.{},
    updated: []Change = &.{},
    /// The tab that BECAME active, when activation moved.
    activated: ?u32 = null,
    activated_window: u32 = 0,

    pub fn deinit(self: *Diff, gpa: std.mem.Allocator) void {
        gpa.free(self.created);
        gpa.free(self.removed);
        gpa.free(self.updated);
    }

    pub fn empty(self: *const Diff) bool {
        return self.created.len == 0 and self.removed.len == 0 and
            self.updated.len == 0 and self.activated == null;
    }
};

pub const Table = struct {
    tabs: std.ArrayList(Tab) = .empty,

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (self.tabs.items) |*t_| t_.deinit(gpa);
        self.tabs.deinit(gpa);
    }

    pub fn find(self: *Table, id: u32) ?*Tab {
        for (self.tabs.items) |*t_| {
            if (t_.id == id) return t_;
        }
        return null;
    }

    /// The tab a helper VIEW belongs to, which is how a message from a
    /// content frame learns its `sender.tab`.
    pub fn findByView(self: *Table, view: u32) ?*Tab {
        if (view == 0) return null;
        for (self.tabs.items) |*t_| {
            if (t_.view == view) return t_;
        }
        return null;
    }

    /// Replace the whole table and report what changed. The returned
    /// diff owns its slices.
    pub fn replace(self: *Table, gpa: std.mem.Allocator, incoming: []const Incoming) !Diff {
        var created: std.ArrayList(u32) = .empty;
        errdefer created.deinit(gpa);
        var removed: std.ArrayList(u32) = .empty;
        errdefer removed.deinit(gpa);
        var updated: std.ArrayList(Change) = .empty;
        errdefer updated.deinit(gpa);
        var activated: ?u32 = null;
        var activated_window: u32 = 0;

        for (incoming) |in| {
            if (self.find(in.id)) |old| {
                var ch = Change{ .id = in.id };
                ch.url = !std.mem.eql(u8, old.url, in.url);
                ch.title = !std.mem.eql(u8, old.title, in.title);
                ch.status = old.loading != in.loading;
                if (ch.any()) try updated.append(gpa, ch);
                if (in.active and !old.active) {
                    activated = in.id;
                    activated_window = in.window_id;
                }
            } else {
                try created.append(gpa, in.id);
                // A tab that arrives already active counts as an
                // activation: an extension that only listens for
                // onActivated would otherwise never see the first tab.
                if (in.active) {
                    activated = in.id;
                    activated_window = in.window_id;
                }
            }
        }
        for (self.tabs.items) |*old| {
            var still = false;
            for (incoming) |in| {
                if (in.id == old.id) {
                    still = true;
                    break;
                }
            }
            if (!still) try removed.append(gpa, old.id);
        }

        // Swap in the new contents only once every allocation above
        // succeeded, so a failure leaves the table untouched.
        var fresh: std.ArrayList(Tab) = .empty;
        errdefer {
            for (fresh.items) |*t_| t_.deinit(gpa);
            fresh.deinit(gpa);
        }
        try fresh.ensureTotalCapacity(gpa, incoming.len);
        for (incoming) |in| {
            fresh.appendAssumeCapacity(.{
                .id = in.id,
                .view = in.view,
                .window_id = in.window_id,
                .index = in.index,
                .active = in.active,
                .focused_window = in.focused_window,
                .url = try gpa.dupe(u8, in.url),
                .title = try gpa.dupe(u8, in.title),
                .loading = in.loading,
            });
        }
        for (self.tabs.items) |*t_| t_.deinit(gpa);
        self.tabs.deinit(gpa);
        self.tabs = fresh;

        return .{
            .created = try created.toOwnedSlice(gpa),
            .removed = try removed.toOwnedSlice(gpa),
            .updated = try updated.toOwnedSlice(gpa),
            .activated = activated,
            .activated_window = activated_window,
        };
    }

    /// MV2 `tabs.query`. Writes matching tab ids into `out` in table
    /// order and returns the used prefix.
    pub fn query(self: *Table, gpa: std.mem.Allocator, filter: std.json.Value, out: []u32) []u32 {
        const obj = if (filter == .object) filter.object else null;
        var n: usize = 0;
        for (self.tabs.items) |*t_| {
            if (n == out.len) break;
            if (!self.matches(gpa, t_, obj)) continue;
            out[n] = t_.id;
            n += 1;
        }
        return out[0..n];
    }

    fn matches(self: *Table, gpa: std.mem.Allocator, t_: *const Tab, obj: ?std.json.ObjectMap) bool {
        _ = self;
        const o = obj orelse return true;
        if (boolOf(o, "active")) |want| {
            if (t_.active != want) return false;
        }
        if (boolOf(o, "currentWindow") orelse boolOf(o, "lastFocusedWindow")) |want| {
            if (t_.focused_window != want) return false;
        }
        if (o.get("windowId")) |v| {
            if (v == .integer) {
                // Out of range matches NOTHING. Narrowing it instead
                // wrapped: `windowId: 2**32 + 1` answered with window
                // 1's tabs — a window the extension never named.
                const want = u32Of(v) orelse return false;
                if (t_.window_id != want) return false;
            }
        }
        if (o.get("index")) |v| {
            if (v == .integer) {
                const want = u32Of(v) orelse return false;
                if (t_.index != want) return false;
            }
        }
        if (o.get("status")) |v| {
            if (v == .string) {
                const want_loading = std.mem.eql(u8, v.string, "loading");
                if (t_.loading != want_loading) return false;
            }
        }
        if (o.get("title")) |v| {
            if (v == .string and !std.mem.eql(u8, v.string, t_.title)) return false;
        }
        if (o.get("url")) |v| {
            var set = match.PatternSet{};
            defer set.deinit(gpa);
            switch (v) {
                .string => |s| set.addInclude(gpa, s) catch return false,
                .array => |a| for (a.items) |it| {
                    if (it == .string) set.addInclude(gpa, it.string) catch {};
                },
                else => return true,
            }
            if (set.include.items.len == 0) return false;
            if (!set.matchesUrl(t_.url)) return false;
        }
        return true;
    }

    /// Serialise one tab as MV2's `Tab` object.
    pub fn writeTab(t_: *const Tab, w: *std.Io.Writer) !void {
        try w.print("{{\"id\":{d},\"windowId\":{d},\"index\":{d},\"active\":{s},\"highlighted\":{s},\"pinned\":false,\"incognito\":false,\"status\":\"{s}\",\"url\":", .{
            t_.id,
            t_.window_id,
            t_.index,
            if (t_.active) "true" else "false",
            if (t_.active) "true" else "false",
            if (t_.loading) "loading" else "complete",
        });
        try std.json.Stringify.value(t_.url, .{}, w);
        try w.writeAll(",\"title\":");
        try std.json.Stringify.value(t_.title, .{}, w);
        try w.writeByte('}');
    }
};

fn boolOf(o: std.json.ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

// ─── tests ──────────────────────────────────────────────────────────

const t = std.testing;

fn tab(id: u32, url: []const u8, active: bool) Incoming {
    return .{ .id = id, .view = id * 10, .url = url, .title = "T", .active = active, .focused_window = true };
}

test "replace: first fill reports creations and the initial activation" {
    const gpa = t.allocator;
    var tb = Table{};
    defer tb.deinit(gpa);
    const in = [_]Incoming{ tab(1, "https://a.test/", true), tab(2, "https://b.test/", false) };
    var d = try tb.replace(gpa, &in);
    defer d.deinit(gpa);
    try t.expectEqual(@as(usize, 2), d.created.len);
    try t.expectEqual(@as(usize, 0), d.removed.len);
    try t.expectEqual(@as(u32, 1), d.activated.?);
}

test "replace: url and title changes become onUpdated, nothing else does" {
    const gpa = t.allocator;
    var tb = Table{};
    defer tb.deinit(gpa);
    var d0 = try tb.replace(gpa, &[_]Incoming{tab(1, "https://a.test/", true)});
    d0.deinit(gpa);

    // Identical input: no events at all.
    var d1 = try tb.replace(gpa, &[_]Incoming{tab(1, "https://a.test/", true)});
    defer d1.deinit(gpa);
    try t.expect(d1.empty());

    var moved = tab(1, "https://a.test/two", true);
    moved.loading = true;
    var d2 = try tb.replace(gpa, &[_]Incoming{moved});
    defer d2.deinit(gpa);
    try t.expectEqual(@as(usize, 1), d2.updated.len);
    try t.expect(d2.updated[0].url);
    try t.expect(d2.updated[0].status);
    try t.expect(!d2.updated[0].title);
    try t.expect(d2.activated == null);
}

test "replace: a vanished tab is onRemoved and activation moves" {
    const gpa = t.allocator;
    var tb = Table{};
    defer tb.deinit(gpa);
    var d0 = try tb.replace(gpa, &[_]Incoming{ tab(1, "https://a.test/", true), tab(2, "https://b.test/", false) });
    d0.deinit(gpa);
    var d1 = try tb.replace(gpa, &[_]Incoming{tab(2, "https://b.test/", true)});
    defer d1.deinit(gpa);
    try t.expectEqual(@as(usize, 1), d1.removed.len);
    try t.expectEqual(@as(u32, 1), d1.removed[0]);
    try t.expectEqual(@as(u32, 2), d1.activated.?);
    try t.expect(tb.find(1) == null);
}

test "findByView is how a content frame learns its sender.tab" {
    const gpa = t.allocator;
    var tb = Table{};
    defer tb.deinit(gpa);
    var d = try tb.replace(gpa, &[_]Incoming{ tab(1, "https://a.test/", true), tab(7, "https://b.test/", false) });
    d.deinit(gpa);
    try t.expectEqual(@as(u32, 7), tb.findByView(70).?.id);
    try t.expect(tb.findByView(0) == null);
    try t.expect(tb.findByView(999) == null);
}

test "query filters on active, window and url patterns" {
    const gpa = t.allocator;
    var tb = Table{};
    defer tb.deinit(gpa);
    var a = tab(1, "https://a.test/x", true);
    var b = tab(2, "https://b.test/y", false);
    b.window_id = 5;
    b.focused_window = false;
    var d = try tb.replace(gpa, &[_]Incoming{ a, b });
    d.deinit(gpa);
    _ = &a;

    var out: [8]u32 = undefined;
    var p = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer p.deinit();
    try t.expectEqual(@as(usize, 2), tb.query(gpa, p.value, &out).len);

    var p2 = try std.json.parseFromSlice(std.json.Value, gpa, "{\"active\":true}", .{});
    defer p2.deinit();
    const r2 = tb.query(gpa, p2.value, &out);
    try t.expectEqual(@as(usize, 1), r2.len);
    try t.expectEqual(@as(u32, 1), r2[0]);

    var p3 = try std.json.parseFromSlice(std.json.Value, gpa, "{\"windowId\":5}", .{});
    defer p3.deinit();
    const r3 = tb.query(gpa, p3.value, &out);
    try t.expectEqual(@as(usize, 1), r3.len);
    try t.expectEqual(@as(u32, 2), r3[0]);

    var p4 = try std.json.parseFromSlice(std.json.Value, gpa, "{\"url\":\"https://b.test/*\"}", .{});
    defer p4.deinit();
    const r4 = tb.query(gpa, p4.value, &out);
    try t.expectEqual(@as(usize, 1), r4.len);
    try t.expectEqual(@as(u32, 2), r4[0]);

    var p5 = try std.json.parseFromSlice(std.json.Value, gpa, "{\"currentWindow\":true}", .{});
    defer p5.deinit();
    const r5 = tb.query(gpa, p5.value, &out);
    try t.expectEqual(@as(usize, 1), r5.len);
    try t.expectEqual(@as(u32, 1), r5[0]);
}

test "writeTab emits the MV2 Tab shape" {
    const gpa = t.allocator;
    var tb = Table{};
    defer tb.deinit(gpa);
    var d = try tb.replace(gpa, &[_]Incoming{tab(3, "https://a.test/\"q\"", true)});
    d.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try Table.writeTab(tb.find(3).?, &aw.writer);
    const out = aw.written();
    try t.expect(std.mem.indexOf(u8, out, "\"id\":3") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"status\":\"complete\"") != null);
    // The url is JSON-escaped, not concatenated raw.
    try t.expect(std.mem.indexOf(u8, out, "\\\"q\\\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    try t.expectEqual(@as(i64, 3), parsed.value.object.get("id").?.integer);
}
