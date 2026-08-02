//! Shared file-browser drag payloads and COPY/MOVE negotiation.

const std = @import("std");
const c = @import("../../c.zig").c;
const appendQuoted = @import("../../filebrowser/desktop.zig").appendQuoted;
const hostEq = @import("../../filebrowser/paths.zig").hostEq;
const parseSpec = @import("../../filebrowser/paths.zig").parseSpec;
const BTab = @import("types.zig").BTab;

const Origin = struct {
    active: bool = false,
    local: bool = true,
    mixed: bool = false,
    host_len: usize = 0,
    host: [512]u8 = undefined,
};

var origin: Origin = .{};

fn strvType() c.GType {
    return c.g_strv_get_type();
}

pub fn useSelection(selected: []const []u8, dragged: []const u8) bool {
    if (selected.len <= 1) return false;
    for (selected) |path| if (std.mem.eql(u8, path, dragged)) return true;
    return false;
}

pub fn clearDragSelection(tab: *BTab) void {
    for (tab.drag_selected.items) |path| tab.view.allocator.free(path);
    tab.drag_selected.clearRetainingCapacity();
}

/// Snapshot a selected row before GtkMultiSelection handles the press.
pub fn armSelection(tab: *BTab, dragged: []const u8) void {
    clearDragSelection(tab);
    if (!useSelection(tab.selected.items, dragged)) return;
    for (tab.selected.items) |path| {
        const copy = tab.view.allocator.dupe(u8, path) catch {
            clearDragSelection(tab);
            return;
        };
        tab.drag_selected.append(tab.view.allocator, copy) catch {
            tab.view.allocator.free(copy);
            clearDragSelection(tab);
            return;
        };
    }
}

fn setOrigin(specs: []const [:0]u8) void {
    origin = .{};
    origin.active = true;
    var first = true;
    for (specs) |spec| {
        const loc = parseSpec(spec);
        const host: ?[]const u8 = if (loc.current_host) null else loc.host;
        if (first) {
            first = false;
            if (host == null) continue;
            const remote = host.?;
            if (remote.len > origin.host.len) {
                origin.active = false;
                return;
            }
            origin.local = false;
            origin.host_len = remote.len;
            @memcpy(origin.host[0..remote.len], remote);
            continue;
        }
        if (!hostEq(sourceHost(), host)) origin.mixed = true;
    }
}

fn normalizedSpec(allocator: std.mem.Allocator, tab: *BTab, raw: []const u8) ![:0]u8 {
    const loc = parseSpec(raw);
    const path = loc.path;
    const host: ?[]const u8 = if (loc.current_host) tab.hc.host else loc.host;
    if (host) |remote| {
        return std.fmt.allocPrintSentinel(allocator, "{s}:{s}", .{ remote, path }, 0);
    }
    return allocator.dupeZ(u8, path);
}

pub fn clearOrigin() void {
    origin.active = false;
}

fn sourceHost() ?[]const u8 {
    if (origin.local) return null;
    return origin.host[0..origin.host_len];
}

pub fn preferredAction(internal: bool, same_host: bool, mods: c.GdkModifierType) c.GdkDragAction {
    if (mods & c.GDK_CONTROL_MASK != 0) return c.GDK_ACTION_COPY;
    if (mods & c.GDK_SHIFT_MASK != 0) return c.GDK_ACTION_MOVE;
    return if (internal and same_host) c.GDK_ACTION_MOVE else c.GDK_ACTION_COPY;
}

fn targetAction(target: *c.GtkDropTarget, tab: *BTab) c.GdkDragAction {
    const mods = c.gtk_event_controller_get_current_event_state(@ptrCast(target));
    return preferredAction(origin.active, origin.active and !origin.mixed and hostEq(sourceHost(), tab.hc.host), mods);
}

fn onTargetMotion(target: *c.GtkDropTarget, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.GdkDragAction {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const action = targetAction(target, tab);
    c.g_object_set_data(@ptrCast(@alignCast(target)), "sketerm-drop-action", @ptrFromInt(@as(usize, @intCast(action))));
    return action;
}

pub fn newTarget(tab: *BTab) *c.GtkDropTarget {
    const target = c.gtk_drop_target_new(c.G_TYPE_INVALID, c.GDK_ACTION_COPY | c.GDK_ACTION_MOVE);
    var types = [_]c.GType{ c.G_TYPE_STRING, strvType() };
    c.gtk_drop_target_set_gtypes(target, &types, types.len);
    _ = c.g_signal_connect_data(target, "enter", @ptrCast(&onTargetMotion), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(target, "motion", @ptrCast(&onTargetMotion), @ptrCast(tab), null, c.G_CONNECT_DEFAULT);
    return target.?;
}

pub fn dropAction(target: *c.GtkDropTarget, tab: *BTab) c.GdkDragAction {
    if (c.gtk_drop_target_get_current_drop(target)) |drop| {
        if (c.gdk_drop_get_drag(drop)) |drag| {
            const selected = c.gdk_drag_get_selected_action(drag);
            if (selected & c.GDK_ACTION_MOVE != 0) return c.GDK_ACTION_MOVE;
            if (selected & c.GDK_ACTION_COPY != 0) return c.GDK_ACTION_COPY;
        }
    }
    if (c.g_object_get_data(@ptrCast(@alignCast(target)), "sketerm-drop-action")) |raw|
        return @intCast(@intFromPtr(raw));
    return targetAction(target, tab);
}

pub fn configureSource(source: *c.GtkDragSource) void {
    c.gtk_drag_source_set_actions(source, c.GDK_ACTION_COPY | c.GDK_ACTION_MOVE);
    _ = c.g_signal_connect_data(source, "drag-end", @ptrCast(&onDragEnd), null, null, c.G_CONNECT_DEFAULT);
}

fn onDragEnd(_: *c.GtkDragSource, _: ?*c.GdkDrag, _: c.gboolean, _: ?*anyopaque) callconv(.c) void {
    clearOrigin();
}

pub fn provider(tab: *BTab, dragged: []const u8) ?*c.GdkContentProvider {
    const allocator = tab.view.allocator;
    const paths = if (useSelection(tab.drag_selected.items, dragged))
        tab.drag_selected.items
    else
        tab.selected.items;
    const selected = useSelection(paths, dragged);
    const count: usize = if (selected) paths.len else 1;
    const specs = allocator.alloc([:0]u8, count) catch return null;
    defer allocator.free(specs);
    var made: usize = 0;
    defer for (specs[0..made]) |spec| allocator.free(spec);

    for (0..count) |i| {
        const path = if (selected) paths[i] else dragged;
        specs[i] = normalizedSpec(allocator, tab, path) catch return null;
        made += 1;
    }

    var value: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&value, strvType());
    defer c.g_value_unset(&value);
    const builder = c.g_strv_builder_new() orelse return null;
    defer c.g_strv_builder_unref(builder);
    for (specs) |spec| c.g_strv_builder_add(builder, spec.ptr);
    c.g_value_take_boxed(&value, @ptrCast(c.g_strv_builder_end(builder)));
    const vector_provider = c.gdk_content_provider_new_for_value(&value);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    if (count == 1) {
        text.appendSlice(allocator, specs[0]) catch {
            c.g_object_unref(vector_provider);
            return null;
        };
    } else {
        for (specs, 0..) |spec, i| {
            if (i > 0) text.append(allocator, ' ') catch {
                c.g_object_unref(vector_provider);
                return null;
            };
            appendQuoted(&text, allocator, spec) catch {
                c.g_object_unref(vector_provider);
                return null;
            };
        }
    }
    text.append(allocator, 0) catch {
        c.g_object_unref(vector_provider);
        return null;
    };
    const text_provider = c.gdk_content_provider_new_typed(c.G_TYPE_STRING, text.items.ptr);
    // Prefer the quoted string inside GTK: unlike GStrv it also crosses
    // process boundaries, and the same decoder now handles both cases.
    var providers = [_]?*c.GdkContentProvider{ text_provider, vector_provider };
    const combined = c.gdk_content_provider_new_union(&providers, providers.len);
    setOrigin(specs);
    clearDragSelection(tab);
    return combined;
}

pub const ValueIter = struct {
    allocator: std.mem.Allocator,
    strv: c.GStrv = null,
    single: ?[]const u8 = null,
    index: usize = 0,
    quoted_pos: usize = 0,
    decoded: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, value: *c.GValue) ValueIter {
        if (c.g_type_check_value_holds(value, strvType()) != 0) {
            const boxed = c.g_value_get_boxed(value) orelse return .{ .allocator = allocator };
            const strv: c.GStrv = @ptrCast(@alignCast(boxed));
            return .{ .allocator = allocator, .strv = strv };
        }
        const raw = c.g_value_get_string(value) orelse return .{ .allocator = allocator };
        return .{ .allocator = allocator, .single = std.mem.span(@as([*:0]const u8, @ptrCast(raw))) };
    }

    pub fn deinit(self: *ValueIter) void {
        self.decoded.deinit(self.allocator);
    }

    pub fn next(self: *ValueIter) ?[]const u8 {
        if (self.single) |single| {
            if (single.len == 0 or single[0] != '\'') {
                if (self.index != 0) return null;
                self.index = 1;
                return single;
            }
            while (self.quoted_pos < single.len and single[self.quoted_pos] == ' ') self.quoted_pos += 1;
            if (self.quoted_pos >= single.len or single[self.quoted_pos] != '\'') return null;
            self.quoted_pos += 1;
            self.decoded.clearRetainingCapacity();
            while (self.quoted_pos < single.len) {
                if (std.mem.startsWith(u8, single[self.quoted_pos..], "'\\''")) {
                    self.decoded.append(self.allocator, '\'') catch return null;
                    self.quoted_pos += 4;
                    continue;
                }
                if (single[self.quoted_pos] == '\'') {
                    self.quoted_pos += 1;
                    return self.decoded.items;
                }
                self.decoded.append(self.allocator, single[self.quoted_pos]) catch return null;
                self.quoted_pos += 1;
            }
            return null;
        }
        if (self.strv == null) return null;
        const raw = self.strv[self.index];
        if (raw == null) return null;
        self.index += 1;
        return std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    }
};

test "dragging a selected member carries the whole selection" {
    const selected = [_][]u8{ @constCast("/a"), @constCast("/b") };
    try std.testing.expect(useSelection(&selected, "/a"));
    try std.testing.expect(!useSelection(&selected, "/c"));
    try std.testing.expect(!useSelection(selected[0..1], "/a"));
}

test "drag action follows modifiers and host topology" {
    try std.testing.expectEqual(@as(c.GdkDragAction, @intCast(c.GDK_ACTION_MOVE)), preferredAction(true, true, 0));
    try std.testing.expectEqual(@as(c.GdkDragAction, @intCast(c.GDK_ACTION_COPY)), preferredAction(true, false, 0));
    try std.testing.expectEqual(@as(c.GdkDragAction, @intCast(c.GDK_ACTION_COPY)), preferredAction(true, true, c.GDK_CONTROL_MASK));
    try std.testing.expectEqual(@as(c.GdkDragAction, @intCast(c.GDK_ACTION_MOVE)), preferredAction(true, false, c.GDK_SHIFT_MASK));
    try std.testing.expectEqual(@as(c.GdkDragAction, @intCast(c.GDK_ACTION_COPY)), preferredAction(false, false, 0));
}

test "quoted fallback preserves multiple specs and apostrophes" {
    const t = std.testing;
    var value: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&value, c.G_TYPE_STRING);
    defer c.g_value_unset(&value);
    c.g_value_set_string(&value, "'/a one' 'box:/b'\\''two'");
    var it = ValueIter.init(t.allocator, &value);
    defer it.deinit();
    try t.expectEqualStrings("/a one", it.next().?);
    try t.expectEqualStrings("box:/b'two", it.next().?);
    try t.expect(it.next() == null);
}

test "strv payload preserves every selected spec" {
    const t = std.testing;
    var value: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&value, strvType());
    defer c.g_value_unset(&value);
    const builder = c.g_strv_builder_new() orelse return error.OutOfMemory;
    defer c.g_strv_builder_unref(builder);
    c.g_strv_builder_add(builder, "/a one");
    c.g_strv_builder_add(builder, "box:/b");
    c.g_value_take_boxed(&value, @ptrCast(c.g_strv_builder_end(builder)));
    var it = ValueIter.init(t.allocator, &value);
    defer it.deinit();
    try t.expectEqualStrings("/a one", it.next().?);
    try t.expectEqualStrings("box:/b", it.next().?);
    try t.expect(it.next() == null);
}
