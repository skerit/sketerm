//! Per-extension browser-action state, including tab-specific overrides.

const std = @import("std");
const manifest = @import("manifest.zig");
const tabs = @import("tabs.zig");
const envelope = @import("reply.zig");

pub const Values = struct {
    title: []const u8 = "",
    icon: []const u8 = "",
    popup: []const u8 = "",
    badge: []const u8 = "",
    badge_text_color: Color = .white,
    badge_background_color: Color = .red,
    enabled: bool = true,
    visible: bool = true,
};

const Field = enum { title, icon, popup, badge };

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const red: Color = .{ .r = 204, .g = 34, .b = 51, .a = 255 };
};

const Override = struct {
    tab: u32,
    title: ?[]u8 = null,
    icon: ?[]u8 = null,
    popup: ?[]u8 = null,
    badge: ?[]u8 = null,
    badge_text_color: ?Color = null,
    badge_background_color: ?Color = null,
    enabled: ?bool = null,
    visible: ?bool = null,

    fn deinit(self: *Override, gpa: std.mem.Allocator) void {
        if (self.title) |s| gpa.free(s);
        if (self.icon) |s| gpa.free(s);
        if (self.popup) |s| gpa.free(s);
        if (self.badge) |s| gpa.free(s);
    }
};

pub const State = struct {
    present: bool = false,
    kind: manifest.ActionKind = .browser,
    defaults: struct {
        title: []u8 = &.{},
        icon: []u8 = &.{},
        popup: []u8 = &.{},
        badge: []u8 = &.{},
        badge_text_color: Color = .white,
        badge_background_color: Color = .red,
        enabled: bool = true,
        visible: bool = true,
    } = .{},
    overrides: std.ArrayList(Override) = .empty,

    pub fn init(gpa: std.mem.Allocator, kind: manifest.ActionKind, act: ?manifest.BrowserAction) !State {
        const a = act orelse return .{};
        const title = a.default_title orelse "";
        const icon = a.default_icon orelse "";
        const popup = a.default_popup orelse "";
        var out = State{ .present = true, .kind = kind };
        out.defaults.visible = kind == .browser;
        errdefer out.deinit(gpa);
        if (title.len != 0) out.defaults.title = try gpa.dupe(u8, title);
        if (icon.len != 0) out.defaults.icon = try gpa.dupe(u8, icon);
        if (popup.len != 0) out.defaults.popup = try gpa.dupe(u8, popup);
        return out;
    }

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.defaults.title.len != 0) gpa.free(self.defaults.title);
        if (self.defaults.icon.len != 0) gpa.free(self.defaults.icon);
        if (self.defaults.popup.len != 0) gpa.free(self.defaults.popup);
        if (self.defaults.badge.len != 0) gpa.free(self.defaults.badge);
        for (self.overrides.items) |*o| o.deinit(gpa);
        self.overrides.deinit(gpa);
        self.* = .{};
    }

    pub fn effective(self: *const State, tab: u32) Values {
        var out = Values{
            .title = self.defaults.title,
            .icon = self.defaults.icon,
            .popup = self.defaults.popup,
            .badge = self.defaults.badge,
            .badge_text_color = self.defaults.badge_text_color,
            .badge_background_color = self.defaults.badge_background_color,
            .enabled = self.defaults.enabled,
            .visible = self.defaults.visible,
        };
        for (self.overrides.items) |o| {
            if (o.tab != tab) continue;
            if (o.title) |v| out.title = v;
            if (o.icon) |v| out.icon = v;
            if (o.popup) |v| out.popup = v;
            if (o.badge) |v| out.badge = v;
            if (o.badge_text_color) |v| out.badge_text_color = v;
            if (o.badge_background_color) |v| out.badge_background_color = v;
            if (o.enabled) |v| out.enabled = v;
            if (o.visible) |v| out.visible = v;
            break;
        }
        return out;
    }

    pub fn removeTab(self: *State, gpa: std.mem.Allocator, tab: u32) void {
        for (self.overrides.items, 0..) |*o, i| {
            if (o.tab != tab) continue;
            o.deinit(gpa);
            _ = self.overrides.orderedRemove(i);
            return;
        }
    }

    /// Apply one `browserAction` call and return an owned JSON result.
    ///
    /// Kind is enforced HERE, not only in the JS surface: a raw ext-call
    /// can name any method, and a page action must not grow the badge or
    /// enablement state MV2 reserves for browser actions.
    pub fn dispatch(self: *State, gpa: std.mem.Allocator, method: []const u8, args_json: []const u8) []u8 {
        if (!self.present) return result(gpa, false, "extension has no action");
        if (self.kind == .page and browserActionOnly(method))
            return result(gpa, false, "method requires browserAction");
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, args_json, .{}) catch
            return result(gpa, false, "bad args");
        defer parsed.deinit();
        const args = if (parsed.value == .array) parsed.value.array.items else &[_]std.json.Value{};

        if (std.mem.eql(u8, method, "enable") or std.mem.eql(u8, method, "disable")) {
            const tab = optionalTab(args, 0) catch return result(gpa, false, "bad tab id");
            self.setBool(gpa, tab, std.mem.eql(u8, method, "enable")) catch
                return result(gpa, false, "oom");
            return result(gpa, true, "null");
        }
        if (std.mem.eql(u8, method, "isEnabled")) {
            const tab = (optionalTab(args, 0) catch return result(gpa, false, "bad tab id")) orelse 0;
            return result(gpa, true, if (self.effective(tab).enabled) "true" else "false");
        }
        if (std.mem.eql(u8, method, "openPopup"))
            return result(gpa, false, "openPopup is handled by the browser host");
        if (std.mem.eql(u8, method, "show") or std.mem.eql(u8, method, "hide")) {
            if (self.kind != .page) return result(gpa, false, "show/hide require pageAction");
            const tab = optionalTab(args, 0) catch return result(gpa, false, "bad tab id");
            if (tab == null) return result(gpa, false, "pageAction show/hide require a tab id");
            self.setVisible(gpa, tab.?, std.mem.eql(u8, method, "show")) catch
                return result(gpa, false, "oom");
            return result(gpa, true, "null");
        }

        const details = if (args.len != 0 and args[0] == .object) args[0].object else
            return result(gpa, false, "bad details");
        const tab = if (details.get("tabId")) |v|
            tabs.u32Of(v) orelse return result(gpa, false, "bad tab id")
        else
            null;

        const field: Field = if (std.mem.eql(u8, method, "setTitle"))
            .title
        else if (std.mem.eql(u8, method, "setIcon"))
            .icon
        else if (std.mem.eql(u8, method, "setPopup"))
            .popup
        else if (std.mem.eql(u8, method, "setBadgeText"))
            .badge
        else if (std.mem.eql(u8, method, "getTitle"))
            return jsonStringResult(gpa, self.effective(tab orelse 0).title)
        else if (std.mem.eql(u8, method, "getPopup"))
            return jsonStringResult(gpa, self.effective(tab orelse 0).popup)
        else if (std.mem.eql(u8, method, "getBadgeText"))
            return jsonStringResult(gpa, self.effective(tab orelse 0).badge)
        else if (std.mem.eql(u8, method, "setBadgeTextColor") or
            std.mem.eql(u8, method, "setBadgeBackgroundColor")) {
            const color = colorValue(details.get("color") orelse return result(gpa, false, "missing color")) orelse
                return result(gpa, false, "bad color");
            self.setColor(gpa, tab, std.mem.eql(u8, method, "setBadgeTextColor"), color) catch
                return result(gpa, false, "oom");
            return result(gpa, true, "null");
        }
        else
            return result(gpa, false, "unknown browserAction method");

        const key = switch (field) {
            .title => "title",
            .icon => "path",
            .popup => "popup",
            .badge => "text",
        };
        const value = details.get(key) orelse return result(gpa, false, "missing value");
        const text = if (field == .icon) iconPath(value) else if (value == .string) value.string else null;
        self.setString(gpa, tab, field, text orelse return result(gpa, false, "bad value")) catch
            return result(gpa, false, "oom");
        return result(gpa, true, "null");
    }

    fn findOverride(self: *State, tab: u32) ?*Override {
        for (self.overrides.items) |*o| if (o.tab == tab) return o;
        return null;
    }

    fn ensureOverride(self: *State, gpa: std.mem.Allocator, tab: u32) ?*Override {
        if (self.findOverride(tab)) |o| return o;
        self.overrides.append(gpa, .{ .tab = tab }) catch return null;
        return &self.overrides.items[self.overrides.items.len - 1];
    }

    fn setBool(self: *State, gpa: std.mem.Allocator, tab: ?u32, value: bool) !void {
        if (tab) |id| {
            const o = self.ensureOverride(gpa, id) orelse return error.OutOfMemory;
            o.enabled = value;
        } else self.defaults.enabled = value;
    }

    fn setVisible(self: *State, gpa: std.mem.Allocator, tab: u32, value: bool) !void {
        const o = self.ensureOverride(gpa, tab) orelse return error.OutOfMemory;
        o.visible = value;
    }

    fn setColor(self: *State, gpa: std.mem.Allocator, tab: ?u32, text: bool, value: Color) !void {
        if (tab) |id| {
            const o = self.ensureOverride(gpa, id) orelse return error.OutOfMemory;
            if (text) o.badge_text_color = value else o.badge_background_color = value;
        } else if (text) {
            self.defaults.badge_text_color = value;
        } else self.defaults.badge_background_color = value;
    }

    fn setString(
        self: *State,
        gpa: std.mem.Allocator,
        tab: ?u32,
        field: Field,
        value: []const u8,
    ) !void {
        const copy = try gpa.dupe(u8, value);
        if (tab) |id| {
            const o = self.ensureOverride(gpa, id) orelse {
                gpa.free(copy);
                return error.OutOfMemory;
            };
            const slot: *?[]u8 = switch (field) {
                .title => &o.title,
                .icon => &o.icon,
                .popup => &o.popup,
                .badge => &o.badge,
            };
            if (slot.*) |old| gpa.free(old);
            slot.* = copy;
            return;
        }
        const slot: *[]u8 = switch (field) {
            .title => &self.defaults.title,
            .icon => &self.defaults.icon,
            .popup => &self.defaults.popup,
            .badge => &self.defaults.badge,
        };
        if (slot.*.len != 0) gpa.free(slot.*);
        slot.* = copy;
    }
};

fn colorValue(v: std.json.Value) ?Color {
    if (v == .string) {
        const s = v.string;
        if (s.len != 7 and s.len != 9) return null;
        if (s[0] != '#') return null;
        return .{
            .r = std.fmt.parseInt(u8, s[1..3], 16) catch return null,
            .g = std.fmt.parseInt(u8, s[3..5], 16) catch return null,
            .b = std.fmt.parseInt(u8, s[5..7], 16) catch return null,
            .a = if (s.len == 9) std.fmt.parseInt(u8, s[7..9], 16) catch return null else 255,
        };
    }
    if (v != .array or (v.array.items.len != 3 and v.array.items.len != 4)) return null;
    var channels: [4]u8 = .{ 0, 0, 0, 255 };
    for (v.array.items, 0..) |item, i| {
        if (item != .integer or item.integer < 0 or item.integer > 255) return null;
        channels[i] = @intCast(item.integer);
    }
    return .{ .r = channels[0], .g = channels[1], .b = channels[2], .a = channels[3] };
}

/// Badge and enablement methods MV2 defines on browserAction only.
fn browserActionOnly(method: []const u8) bool {
    const names = [_][]const u8{
        "enable",             "disable",           "isEnabled",
        "setBadgeText",       "getBadgeText",      "setBadgeTextColor",
        "setBadgeBackgroundColor",
    };
    for (names) |n| {
        if (std.mem.eql(u8, method, n)) return true;
    }
    return false;
}

fn optionalTab(args: []const std.json.Value, index: usize) !?u32 {
    if (args.len <= index) return null;
    return tabs.u32Of(args[index]) orelse error.BadTabId;
}

fn iconPath(v: std.json.Value) ?[]const u8 {
    return manifest.iconFromValue(v);
}

/// `ok` selects the envelope; `value` is raw JSON for a result and a
/// plain (escaped on the way out) message for an error.
fn result(gpa: std.mem.Allocator, ok: bool, value: []const u8) []u8 {
    return if (ok) envelope.ok(gpa, value) else envelope.err(gpa, value);
}

fn jsonStringResult(gpa: std.mem.Allocator, value: []const u8) []u8 {
    return envelope.okString(gpa, value);
}

test "browser action keeps global and tab-specific state separate" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .browser, .{ .default_title = "Default", .default_popup = "popup.html" });
    defer st.deinit(gpa);
    gpa.free(st.dispatch(gpa, "setTitle", "[{\"title\":\"Tab\",\"tabId\":7}]"));
    gpa.free(st.dispatch(gpa, "disable", "[7]"));
    try std.testing.expectEqualStrings("Default", st.effective(3).title);
    try std.testing.expect(st.effective(3).enabled);
    try std.testing.expectEqualStrings("Tab", st.effective(7).title);
    try std.testing.expect(!st.effective(7).enabled);
    try std.testing.expectEqualStrings("popup.html", st.effective(7).popup);
}

test "browser action accepts sized icon maps and popup clearing" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .browser, .{});
    defer st.deinit(gpa);
    gpa.free(st.dispatch(gpa, "setIcon", "[{\"path\":{\"128\":\"large.png\",\"16\":\"small.png\",\"32\":\"icon.png\"}}]"));
    try std.testing.expectEqualStrings("icon.png", st.effective(1).icon);
    gpa.free(st.dispatch(gpa, "setPopup", "[{\"popup\":\"\"}]"));
    try std.testing.expectEqualStrings("", st.effective(1).popup);
}

test "browser action forgets overrides with their tab" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .browser, .{ .default_title = "Default" });
    defer st.deinit(gpa);
    gpa.free(st.dispatch(gpa, "setTitle", "[{\"title\":\"Tab\",\"tabId\":7}]"));
    st.removeTab(gpa, 7);
    try std.testing.expectEqualStrings("Default", st.effective(7).title);
}

test "browser action rejects invalid tab ids without changing global state" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .browser, .{ .default_title = "Default" });
    defer st.deinit(gpa);
    const reply = st.dispatch(gpa, "disable", "[-1]");
    defer gpa.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "bad tab id") != null);
    try std.testing.expect(st.effective(1).enabled);
}

test "page action is hidden until shown for one tab" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .page, .{ .default_title = "Page" });
    defer st.deinit(gpa);
    try std.testing.expect(!st.effective(7).visible);
    gpa.free(st.dispatch(gpa, "show", "[7]"));
    try std.testing.expect(st.effective(7).visible);
    try std.testing.expect(!st.effective(8).visible);
    gpa.free(st.dispatch(gpa, "hide", "[7]"));
    try std.testing.expect(!st.effective(7).visible);
}

test "badge colors keep global and tab values separate" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .browser, .{});
    defer st.deinit(gpa);
    gpa.free(st.dispatch(gpa, "setBadgeBackgroundColor", "[{\"color\":[1,2,3,4]}]"));
    gpa.free(st.dispatch(gpa, "setBadgeTextColor", "[{\"tabId\":7,\"color\":\"#aabbcc\"}]"));
    try std.testing.expectEqual(Color{ .r = 1, .g = 2, .b = 3, .a = 4 }, st.effective(8).badge_background_color);
    try std.testing.expectEqual(Color{ .r = 0xaa, .g = 0xbb, .b = 0xcc, .a = 255 }, st.effective(7).badge_text_color);
    try std.testing.expectEqual(Color.white, st.effective(8).badge_text_color);
}

test "page action rejects browser-action-only methods" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .page, .{ .default_title = "Page" });
    defer st.deinit(gpa);
    for ([_][]const u8{ "enable", "disable", "isEnabled", "setBadgeText", "getBadgeText", "setBadgeTextColor", "setBadgeBackgroundColor" }) |method| {
        const reply = st.dispatch(gpa, method, "[{\"text\":\"1\",\"color\":[1,2,3]}]");
        defer gpa.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "requires browserAction") != null);
    }
    try std.testing.expect(st.effective(1).enabled);
    // The shared surface stays available to a page action.
    gpa.free(st.dispatch(gpa, "setTitle", "[{\"title\":\"Still fine\"}]"));
    try std.testing.expectEqualStrings("Still fine", st.effective(1).title);
}

test "unsupported action methods reject instead of succeeding silently" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .browser, .{});
    defer st.deinit(gpa);
    const reply = st.dispatch(gpa, "notImplemented", "[]");
    defer gpa.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "error") != null);
}
