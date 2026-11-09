//! External drag-and-drop onto a view (`input_drag`, capability
//! "drag-drop"): the client is the system drop target, and each step is
//! played into the engine's windowless drag-target API, so the page gets
//! the same `dragenter`/`dragover`/`drop` events (and `File` objects) as
//! in a desktop browser. What the page leaves unhandled the engine
//! handles itself: Blink opens a dropped file or link
//! (`navigate_on_drag_drop`), and the drop grants the renderer read
//! access to exactly the dropped paths.

const std = @import("std");
const cef = @import("cef");
const proto = @import("../protocol.zig");
const keymap = @import("../keymap.zig");
const host_mod = @import("../cefhost.zig");
const Host = host_mod.Host;
const View = host_mod.View;
const browserHost = host_mod.browserHost;
const release = host_mod.release;
const setStr = host_mod.setStr;
const viewPoint = host_mod.viewPoint;

/// One engine call of a drag step.
pub const Step = enum { enter, over, leave, drop };

/// The engine calls one `input_drag` frame becomes. A drop carrying data
/// re-enters first: the engine drops what its LAST enter carried.
pub fn steps(kind: proto.DragKind, has_data: bool) []const Step {
    return switch (kind) {
        .enter => if (has_data) &.{.enter} else &.{},
        .over => &.{.over},
        .leave => &.{.leave},
        .drop => if (has_data) &.{ .leave, .enter, .over, .drop } else &.{.drop},
        _ => &.{},
    };
}

/// The engine's operation mask for the wire's `ops` bits.
pub fn engineOps(ops: u8) cef.cef_drag_operations_mask_t {
    var m: c_uint = 0;
    if (ops & proto.drag_op_copy != 0) m |= cef.DRAG_OPERATION_COPY;
    if (ops & proto.drag_op_link != 0) m |= cef.DRAG_OPERATION_LINK;
    if (ops & proto.drag_op_move != 0) m |= cef.DRAG_OPERATION_MOVE;
    return @intCast(m);
}

pub fn drag(self: *Host, req: proto.InputDrag) void {
    const v = self.findWake(req.view) orelse return;
    self.motionDriftYield(v);
    const kind: proto.DragKind = @enumFromInt(req.kind);
    const has_data = req.flags & proto.InputDrag.FLAG_DATA != 0 or kind == .enter;
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    const pt = viewPoint(v, req.x, req.y);
    var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = keymap.eventFlags(req.mods) };
    const ops = engineOps(req.ops);
    for (steps(kind, has_data)) |step| switch (step) {
        .enter => {
            const f = host.drag_target_drag_enter orelse return;
            // A non-self argument is a reference transfer: the engine
            // owns `data` from here on.
            const data = buildData(req) orelse return;
            f(host, data, &ev, ops);
        },
        .over => if (host.drag_target_drag_over) |f| f(host, &ev, ops),
        .leave => if (host.drag_target_drag_leave) |f| f(host),
        .drop => if (host.drag_target_drop) |f| f(host, &ev),
    };
}

/// A fresh drag-data object holding `req`'s files, link and text, with
/// its one reference owned by the caller.
fn buildData(req: proto.InputDrag) ?*cef.cef_drag_data_t {
    const data: *cef.cef_drag_data_t = cef.cef_drag_data_create() orelse return null;
    var s = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&s);
    // An empty display name makes the engine use the path's basename,
    // which a staged remote copy keeps.
    const empty = std.mem.zeroes(cef.cef_string_t);
    if (data.add_file) |add| for (req.files) |path| {
        if (path.len == 0) continue;
        put(&s, path);
        add(data, &s, &empty);
    };
    if (req.url.len != 0) if (data.set_link_url) |f| {
        put(&s, req.url);
        f(data, &s);
    };
    if (req.text.s.len != 0) if (data.set_fragment_text) |f| {
        put(&s, req.text.s);
        f(data, &s);
    };
    return data;
}

fn put(s: *cef.cef_string_t, utf8: []const u8) void {
    cef.cef_string_utf16_clear(s);
    setStr(utf8, s);
}

test "a drop that carries data re-enters before dropping; the rest map one to one" {
    const t = std.testing;
    try t.expectEqualSlices(Step, &.{ .leave, .enter, .over, .drop }, steps(.drop, true));
    try t.expectEqualSlices(Step, &.{.drop}, steps(.drop, false));
    try t.expectEqualSlices(Step, &.{.enter}, steps(.enter, true));
    try t.expectEqualSlices(Step, &.{.over}, steps(.over, false));
    try t.expectEqualSlices(Step, &.{.leave}, steps(.leave, false));
    try t.expectEqual(@as(usize, 0), steps(@enumFromInt(9), true).len);
}

test "wire drag ops map onto the engine's mask" {
    const t = std.testing;
    try t.expectEqual(@as(cef.cef_drag_operations_mask_t, cef.DRAG_OPERATION_COPY), engineOps(proto.drag_op_copy));
    try t.expectEqual(@as(cef.cef_drag_operations_mask_t, cef.DRAG_OPERATION_COPY | cef.DRAG_OPERATION_LINK | cef.DRAG_OPERATION_MOVE), engineOps(proto.drag_op_copy | proto.drag_op_link | proto.drag_op_move));
    try t.expectEqual(@as(cef.cef_drag_operations_mask_t, 0), engineOps(0));
}
