//! Per-extension browser-action state, including tab-specific overrides.

const std = @import("std");
const manifest = @import("manifest.zig");
const tabs = @import("tabs.zig");

pub const Values = struct {
    title: []const u8 = "",
    icon: []const u8 = "",
    popup: []const u8 = "",
    badge: []const u8 = "",
    enabled: bool = true,
};

const Field = enum { title, icon, popup, badge };

const Override = struct {
    tab: u32,
    title: ?[]u8 = null,
    icon: ?[]u8 = null,
    popup: ?[]u8 = null,
    badge: ?[]u8 = null,
    enabled: ?bool = null,

    fn deinit(self: *Override, gpa: std.mem.Allocator) void {
        if (self.title) |s| gpa.free(s);
        if (self.icon) |s| gpa.free(s);
        if (self.popup) |s| gpa.free(s);
        if (self.badge) |s| gpa.free(s);
    }
};

pub const State = struct {
    present: bool = false,
    defaults: struct {
        title: []u8 = &.{},
        icon: []u8 = &.{},
        popup: []u8 = &.{},
        badge: []u8 = &.{},
        enabled: bool = true,
    } = .{},
    overrides: std.ArrayList(Override) = .empty,

    pub fn init(gpa: std.mem.Allocator, act: ?manifest.BrowserAction) !State {
        const a = act orelse return .{};
        const title = a.default_title orelse "";
        const icon = a.default_icon orelse "";
        const popup = a.default_popup orelse "";
        var out = State{ .present = true };
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
            .enabled = self.defaults.enabled,
        };
        for (self.overrides.items) |o| {
            if (o.tab != tab) continue;
            if (o.title) |v| out.title = v;
            if (o.icon) |v| out.icon = v;
            if (o.popup) |v| out.popup = v;
            if (o.badge) |v| out.badge = v;
            if (o.enabled) |v| out.enabled = v;
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
    pub fn dispatch(self: *State, gpa: std.mem.Allocator, method: []const u8, args_json: []const u8) []u8 {
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
            std.mem.eql(u8, method, "setBadgeBackgroundColor"))
            return result(gpa, true, "null")
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

fn optionalTab(args: []const std.json.Value, index: usize) !?u32 {
    if (args.len <= index) return null;
    return tabs.u32Of(args[index]) orelse error.BadTabId;
}

fn iconPath(v: std.json.Value) ?[]const u8 {
    if (v == .string) return v.string;
    if (v != .object) return null;
    var best: ?[]const u8 = null;
    var best_size: u32 = 0;
    var best_fits = false;
    var it = v.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .string) continue;
        const size = std.fmt.parseInt(u32, kv.key_ptr.*, 10) catch 0;
        const fits = size <= 64;
        if (best == null or (fits and (!best_fits or size > best_size))) {
            best = kv.value_ptr.string;
            best_size = size;
            best_fits = fits;
        }
    }
    return best;
}

fn result(gpa: std.mem.Allocator, ok: bool, value: []const u8) []u8 {
    return if (ok)
        std.fmt.allocPrint(gpa, "{{\"result\":{s}}}", .{value}) catch unreachable
    else
        std.fmt.allocPrint(gpa, "{{\"error\":\"{s}\"}}", .{value}) catch unreachable;
}

fn jsonStringResult(gpa: std.mem.Allocator, value: []const u8) []u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    aw.writer.writeAll("{\"result\":") catch return result(gpa, false, "oom");
    std.json.Stringify.value(value, .{}, &aw.writer) catch return result(gpa, false, "oom");
    aw.writer.writeByte('}') catch return result(gpa, false, "oom");
    return aw.toOwnedSlice() catch result(gpa, false, "oom");
}

test "browser action keeps global and tab-specific state separate" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .{ .default_title = "Default", .default_popup = "popup.html" });
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
    var st = try State.init(gpa, .{});
    defer st.deinit(gpa);
    gpa.free(st.dispatch(gpa, "setIcon", "[{\"path\":{\"128\":\"large.png\",\"16\":\"small.png\",\"32\":\"icon.png\"}}]"));
    try std.testing.expectEqualStrings("icon.png", st.effective(1).icon);
    gpa.free(st.dispatch(gpa, "setPopup", "[{\"popup\":\"\"}]"));
    try std.testing.expectEqualStrings("", st.effective(1).popup);
}

test "browser action forgets overrides with their tab" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .{ .default_title = "Default" });
    defer st.deinit(gpa);
    gpa.free(st.dispatch(gpa, "setTitle", "[{\"title\":\"Tab\",\"tabId\":7}]"));
    st.removeTab(gpa, 7);
    try std.testing.expectEqualStrings("Default", st.effective(7).title);
}

test "browser action rejects invalid tab ids without changing global state" {
    const gpa = std.testing.allocator;
    var st = try State.init(gpa, .{ .default_title = "Default" });
    defer st.deinit(gpa);
    const reply = st.dispatch(gpa, "disable", "[-1]");
    defer gpa.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "bad tab id") != null);
    try std.testing.expect(st.effective(1).enabled);
}
