//! Accessibility (0x70 block, capability "a11y"), split out of
//! `cefhost.zig`: the engine's AX tree and location callbacks, decoded
//! from `cef_value_t` dictionaries into the wire's engine-agnostic frames.

const std = @import("std");
const c = @import("cbindings");
const cef = @import("cef");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const Host = host_mod.Host;
const Utf8 = host_mod.Utf8;
const View = host_mod.View;
const browserHost = host_mod.browserHost;
const release = host_mod.release;
const releaseArg = host_mod.releaseArg;
const setStr = host_mod.setStr;

// ── accessibility (0x70 block, capability "a11y") ────────────────────
//
// The engine serializes AX updates as `cef_value_t` dictionaries; this
// section translates them into the wire's engine-agnostic frames.
// PAYLOAD SHAPE (verified empirically on CEF 151 with
// SKETERM_WEB_AX_DEBUG=1, which dumps the raw value as JSON):
//   tree change: { "ax_tree_id": "<token>",
//                  "updates": [ { "root_id": int, "node_id_to_clear": int,
//                                 "tree_data": {...}, "nodes": [ {...} ] } ],
//                  "events":  [ { "event_type": "...", "id": int } ] }
//   node:        { "id": int, "role": "camelCaseToken",
//                  "child_ids": [int], "location": {x,y,width,height},
//                  "offset_container_id": int, "attributes": {...},
//                  "state": {...} }
//   location:    [ { "id": int, "ax_tree_id": "...",
//                    "new_location": {x,y,width,height} } ]
// Anything absent decodes as a default, and anything extra is ignored,
// so a Chromium that grows its serializer cannot break the helper.
//
// ATTRIBUTION: the accessibility callbacks carry NO browser pointer —
// only the tree-id token inside the payload. `axResolveView` therefore
// joins on the token a view was last seen with, and rebinds an unknown
// token to the SINGLE a11y-enabled view when there is exactly one
// (navigation mints a fresh token per document). With several enabled
// views an unknown token that matches no view is dropped: wrong
// attribution would read one page's tree to another page's reader.

pub fn getAccessibilityHandler(_: [*c]cef.cef_render_handler_t) callconv(.c) [*c]cef.cef_accessibility_handler_t {
    return &host_mod.accessibility_handler;
}

/// Push the view's a11y flag into the engine. STATE_DISABLED (not
/// STATE_DEFAULT) on the off edge: default would leave it steerable by
/// command-line switches.
pub fn applyA11yState(v: *View) void {
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    if (host.set_accessibility_state) |set|
        set(host, if (v.a11y) cef.STATE_ENABLED else cef.STATE_DISABLED);
}

/// The view an AX payload belongs to (see the section header).
pub fn axResolveView(host: *Host, tree_id: []const u8) ?*View {
    if (tree_id.len != 0) {
        for (host.views.items) |v| {
            if (v.a11y and std.mem.eql(u8, v.ax_tree, tree_id)) return v;
        }
    }
    var only: ?*View = null;
    for (host.views.items) |v| {
        if (!v.a11y or v.browser == null) continue;
        // A background page is never a client view, so its tree must
        // never be adoptable as one. `spawnBackground` disables its AX
        // explicitly, which already prevents this; the skip is here so
        // a future path that forgets cannot silently hand a reader a
        // hidden 1x1 page in place of the page it is reading.
        if (v.webext_bg) continue;
        if (only != null) return null; // ambiguous — drop, never guess
        only = v;
    }
    const v = only orelse return null;
    if (tree_id.len != 0) {
        const dup = host.gpa.dupe(u8, tree_id) catch return null;
        if (v.ax_tree.len != 0) host.gpa.free(v.ax_tree);
        v.ax_tree = dup;
    }
    return v;
}

/// A UTF-16 CEF string key, for the dictionary getters.
pub const KeyStr = struct {
    s: cef.cef_string_t,

    pub fn init(key: []const u8) KeyStr {
        var out = std.mem.zeroes(cef.cef_string_t);
        setStr(key, &out);
        return .{ .s = out };
    }

    pub fn deinit(self: *KeyStr) void {
        cef.cef_string_utf16_clear(&self.s);
    }
};

pub fn dType(d: *cef.cef_dictionary_value_t, key: []const u8) cef.cef_value_type_t {
    var k = KeyStr.init(key);
    defer k.deinit();
    const gt = d.get_type orelse return cef.VTYPE_INVALID;
    return gt(d, &k.s);
}

pub fn dInt(d: *cef.cef_dictionary_value_t, key: []const u8) ?i32 {
    switch (dType(d, key)) {
        cef.VTYPE_INT => {},
        cef.VTYPE_DOUBLE => {
            var k = KeyStr.init(key);
            defer k.deinit();
            const gd = d.get_double orelse return null;
            return @intFromFloat(std.math.clamp(gd(d, &k.s), -2147483648.0, 2147483647.0));
        },
        else => return null,
    }
    var k = KeyStr.init(key);
    defer k.deinit();
    const gi = d.get_int orelse return null;
    return gi(d, &k.s);
}

/// UTF-8 copy of a string entry, allocated from `alloc` (an arena in
/// every caller). Null when absent or not a string.
pub fn dStr(alloc: std.mem.Allocator, d: *cef.cef_dictionary_value_t, key: []const u8) ?[]u8 {
    if (dType(d, key) != cef.VTYPE_STRING) return null;
    var k = KeyStr.init(key);
    defer k.deinit();
    const gs = d.get_string orelse return null;
    const raw = gs(d, &k.s);
    if (raw == null) return null;
    defer cef.cef_string_userfree_utf16_free(raw);
    var s = Utf8.init(raw);
    defer s.free();
    return alloc.dupe(u8, s.slice()) catch null;
}

/// Referenced; caller releases.
pub fn dDict(d: *cef.cef_dictionary_value_t, key: []const u8) ?*cef.cef_dictionary_value_t {
    if (dType(d, key) != cef.VTYPE_DICTIONARY) return null;
    var k = KeyStr.init(key);
    defer k.deinit();
    const gd = d.get_dictionary orelse return null;
    return gd(d, &k.s);
}

/// Referenced; caller releases.
pub fn dList(d: *cef.cef_dictionary_value_t, key: []const u8) ?*cef.cef_list_value_t {
    if (dType(d, key) != cef.VTYPE_LIST) return null;
    var k = KeyStr.init(key);
    defer k.deinit();
    const gl = d.get_list orelse return null;
    return gl(d, &k.s);
}

pub fn listLen(l: *cef.cef_list_value_t) usize {
    const gs = l.get_size orelse return 0;
    return gs(l);
}

/// Referenced; caller releases.
pub fn listDict(l: *cef.cef_list_value_t, i: usize) ?*cef.cef_dictionary_value_t {
    const gt = l.get_type orelse return null;
    if (gt(l, i) != cef.VTYPE_DICTIONARY) return null;
    const gd = l.get_dictionary orelse return null;
    return gd(l, i);
}

/// Engine role token -> wire role token: the ARIA name where one
/// exists, a small extension set otherwise, kebab-cased pass-through
/// (into `buf`) as the self-describing escape for the long tail.
pub fn axRole(buf: []u8, engine: []const u8) []const u8 {
    const Map = struct { from: []const u8, to: []const u8 };
    const map = [_]Map{
        .{ .from = "rootWebArea", .to = "document" },
        .{ .from = "genericContainer", .to = "generic" },
        .{ .from = "staticText", .to = "text" },
        .{ .from = "textField", .to = "textbox" },
        .{ .from = "textFieldWithComboBox", .to = "combobox" },
        .{ .from = "checkBox", .to = "checkbox" },
        .{ .from = "radioButton", .to = "radio" },
        .{ .from = "listBox", .to = "listbox" },
        .{ .from = "listBoxOption", .to = "option" },
        .{ .from = "menuListPopup", .to = "listbox" },
        .{ .from = "menuListOption", .to = "option" },
        .{ .from = "listItem", .to = "listitem" },
        .{ .from = "listMarker", .to = "generic" },
        .{ .from = "menuBar", .to = "menubar" },
        .{ .from = "menuItem", .to = "menuitem" },
        .{ .from = "tabList", .to = "tablist" },
        .{ .from = "tabPanel", .to = "tabpanel" },
        .{ .from = "treeItem", .to = "treeitem" },
        .{ .from = "columnHeader", .to = "columnheader" },
        .{ .from = "rowHeader", .to = "rowheader" },
        .{ .from = "contentInfo", .to = "contentinfo" },
        .{ .from = "alertDialog", .to = "alertdialog" },
        .{ .from = "progressIndicator", .to = "progressbar" },
        .{ .from = "spinButton", .to = "spinbutton" },
        .{ .from = "disclosureTriangle", .to = "button" },
        .{ .from = "iframePresentational", .to = "iframe" },
        .{ .from = "splitter", .to = "separator" },
        .{ .from = "figcaption", .to = "caption" },
        .{ .from = "cell", .to = "cell" },
        .{ .from = "docAbstract", .to = "section" },
    };
    for (map) |m| {
        if (std.mem.eql(u8, engine, m.from)) return m.to;
    }
    // Kebab-case camelCase into buf; anything that does not fit is
    // truncated rather than dropped (a long unknown token beats none).
    var n: usize = 0;
    for (engine) |ch| {
        if (n + 2 > buf.len) break;
        if (ch >= 'A' and ch <= 'Z') {
            buf[n] = '-';
            buf[n + 1] = ch - 'A' + 'a';
            n += 2;
        } else {
            buf[n] = ch;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Fold the engine's per-node "state" dictionary (name -> bool) into
/// the wire's `ax_*` bits.
pub fn axStateBits(state: *cef.cef_dictionary_value_t) u64 {
    const Map = struct { name: []const u8, bit: u64 };
    const map = [_]Map{
        .{ .name = "focusable", .bit = proto.ax_focusable },
        .{ .name = "focused", .bit = proto.ax_focused },
        .{ .name = "editable", .bit = proto.ax_editable },
        .{ .name = "richlyEditable", .bit = proto.ax_editable },
        .{ .name = "protected", .bit = proto.ax_protected },
        .{ .name = "required", .bit = proto.ax_required },
        .{ .name = "invisible", .bit = proto.ax_invisible },
        .{ .name = "ignored", .bit = proto.ax_ignored },
        .{ .name = "multiline", .bit = proto.ax_multiline },
        .{ .name = "default", .bit = proto.ax_default },
        .{ .name = "hovered", .bit = proto.ax_hovered },
        .{ .name = "visited", .bit = proto.ax_visited },
        .{ .name = "collapsed", .bit = proto.ax_collapsed },
        .{ .name = "expanded", .bit = proto.ax_expanded },
        .{ .name = "busy", .bit = proto.ax_busy },
        .{ .name = "modal", .bit = proto.ax_modal },
        .{ .name = "multiselectable", .bit = proto.ax_multiselectable },
        .{ .name = "selected", .bit = proto.ax_selected },
        .{ .name = "autofillAvailable", .bit = proto.ax_autofill_available },
    };
    var bits: u64 = 0;
    for (map) |m| {
        var k = KeyStr.init(m.name);
        defer k.deinit();
        const hk = state.has_key orelse break;
        if (hk(state, &k.s) == 0) continue;
        // Presence alone is the signal on a bool dict, but read the
        // value when it is one, so an explicit false stays false.
        const gt = state.get_type orelse break;
        if (gt(state, &k.s) == cef.VTYPE_BOOL) {
            const gb = state.get_bool orelse break;
            if (gb(state, &k.s) == 0) continue;
        }
        bits |= m.bit;
    }
    return bits;
}

/// Curated attribute forwarding: engine attribute -> wire attr key.
/// Everything else is dropped on purpose — the wire carries meaning,
/// not the engine's whole serializer.
pub const ax_attr_map = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "htmlTag", .to = "tag" },
    .{ .from = "url", .to = "url" },
    .{ .from = "placeholder", .to = "placeholder" },
    .{ .from = "language", .to = "lang" },
    .{ .from = "roleDescription", .to = "role-description" },
    .{ .from = "hierarchicalLevel", .to = "level" },
    .{ .from = "liveStatus", .to = "live" },
    .{ .from = "invalidState", .to = "invalid" },
    .{ .from = "valueForRange", .to = "value-now" },
    .{ .from = "minValueForRange", .to = "value-min" },
    .{ .from = "maxValueForRange", .to = "value-max" },
    .{ .from = "autoComplete", .to = "autocomplete" },
    .{ .from = "accessKey", .to = "access-key" },
    .{ .from = "keyShortcuts", .to = "key-shortcuts" },
    // The engine's OWN verb for a node's default action ("press",
    // "check", "uncheck", "jump", "open", ...). A projection announces
    // this to the user, so taking Chromium's word beats guessing from
    // the role. "clickAncestor" marks a node whose click belongs to an
    // ancestor (static text inside a button) and must NOT read as
    // actionable; the consumer filters it.
    .{ .from = "defaultActionVerb", .to = "default-action" },
};

/// Any attribute value as its wire string, arena-allocated.
pub fn axAttrString(alloc: std.mem.Allocator, d: *cef.cef_dictionary_value_t, key: []const u8) ?[]const u8 {
    switch (dType(d, key)) {
        cef.VTYPE_STRING => return dStr(alloc, d, key),
        cef.VTYPE_INT => {
            const v = dInt(d, key) orelse return null;
            return std.fmt.allocPrint(alloc, "{d}", .{v}) catch null;
        },
        cef.VTYPE_DOUBLE => {
            var k = KeyStr.init(key);
            defer k.deinit();
            const gd = d.get_double orelse return null;
            return std.fmt.allocPrint(alloc, "{d}", .{gd(d, &k.s)}) catch null;
        },
        cef.VTYPE_BOOL => {
            var k = KeyStr.init(key);
            defer k.deinit();
            const gb = d.get_bool orelse return null;
            return if (gb(d, &k.s) != 0) "true" else "false";
        },
        else => return null,
    }
}

pub var g_ax_debug: enum { unknown, off, on } = .unknown;

pub fn axDebug() bool {
    if (g_ax_debug == .unknown)
        g_ax_debug = if (c.getenv("SKETERM_WEB_AX_DEBUG") != null) .on else .off;
    return g_ax_debug == .on;
}

/// Print one serialized accessibility payload as JSON.
///
/// `value` is a NON-SELF argument of `cef_write_json`, so the wrapper
/// releases one reference on receipt, before writing anything. The caller
/// holds the only reference to the callback parameter it passes here and
/// keeps reading it afterwards, so the debug dump pays for its own
/// consumption with an add_ref rather than donating the caller's.
pub fn axDump(label: []const u8, value: *cef.cef_value_t) void {
    // `cef_write_json` consumes one reference; without a way to pay for
    // it the caller's only reference would be donated, so dump nothing.
    const add = value.base.add_ref orelse return;
    add(&value.base);
    const raw = cef.cef_write_json(value, cef.JSON_WRITER_DEFAULT);
    if (raw == null) return;
    defer cef.cef_string_userfree_utf16_free(raw);
    var s = Utf8.init(raw);
    defer s.free();
    std.debug.print("sketerm-web ax {s}: {s}\n", .{ label, s.slice() });
}

/// One serialized tree update -> one `ev_a11y_tree` frame.
pub fn axEmitUpdate(
    host: *Host,
    v: *View,
    upd: *cef.cef_dictionary_value_t,
    alloc: std.mem.Allocator,
) void {
    var focus_id: u32 = 0;
    var caret: ?proto.EvA11yCaret = null;
    if (dDict(upd, "tree_data")) |td| {
        defer release(@ptrCast(&td.base));
        if (dInt(td, "focus_id")) |f| focus_id = @bitCast(f);
        // The caret/selection lives in tree_data, NOT on any node: it
        // is a pair of (node, offset) endpoints that may straddle
        // nodes. Absent keys mean this engine build does not report
        // it, which degrades to "no caret" rather than to a wrong one.
        if (dInt(td, "sel_focus_object_id")) |fo| {
            const fid: u32 = @bitCast(fo);
            if (fid != 0) {
                const aid: u32 = if (dInt(td, "sel_anchor_object_id")) |ao|
                    @bitCast(ao)
                else
                    fid;
                caret = .{
                    .view = v.id,
                    .anchor_id = aid,
                    .anchor_offset = @intCast(dInt(td, "sel_anchor_offset") orelse 0),
                    .focus_id = fid,
                    .focus_offset = @intCast(dInt(td, "sel_focus_offset") orelse 0),
                };
            }
        }
    }

    var field_sel: ?[2]i32 = null;
    var nodes_buf: std.ArrayList(u8) = .empty;
    defer nodes_buf.deinit(host.gpa);
    var w = proto.A11yNodeWriter{ .gpa = host.gpa, .buf = &nodes_buf };

    if (dList(upd, "nodes")) |nodes| {
        defer release(@ptrCast(&nodes.base));
        var i: usize = 0;
        const n = listLen(nodes);
        while (i < n) : (i += 1) {
            const nd = listDict(nodes, i) orelse continue;
            defer release(@ptrCast(&nd.base));
            axPutNode(&w, nd, alloc) catch return; // OOM: drop frame
            // A text form control's selection is NOT in tree_data:
            // MEASURED on CEF 151, setSelectionRange(2,6) in an
            // <input> arrives there as a COLLAPSED caret at 2. The
            // real range is on the node, so prefer it for the focused
            // field. Absent keys change nothing.
            if (focus_id != 0 and field_sel == null) {
                if (dInt(nd, "id")) |nid| {
                    if (@as(u32, @bitCast(nid)) == focus_id) {
                        if (dDict(nd, "attributes")) |at| {
                            defer release(@ptrCast(&at.base));
                            const ss = dInt(at, "textSelStart");
                            const se = dInt(at, "textSelEnd");
                            if (ss != null and se != null and ss.? >= 0 and se.? >= 0)
                                field_sel = .{ ss.?, se.? };
                        }
                    }
                }
            }
        }
    }
    if (field_sel) |fs| caret = .{
        .view = v.id,
        .anchor_id = focus_id,
        .anchor_offset = fs[0],
        .focus_id = focus_id,
        .focus_offset = fs[1],
    };

    host.post(proto.EvA11yTree{
        .view = v.id,
        .root_id = @bitCast(dInt(upd, "root_id") orelse 0),
        .node_id_to_clear = @bitCast(dInt(upd, "node_id_to_clear") orelse 0),
        .focus_id = focus_id,
        .nodes = .{ .s = nodes_buf.items },
    });
    // AFTER the tree: the caret names a node, and a client that has
    // not seen that node yet can only clamp the offset to nothing.
    if (caret) |cr| {
        if (!v.ax_caret_sent or !axCaretEql(v.ax_caret, cr)) {
            v.ax_caret = cr;
            v.ax_caret_sent = true;
            host.post(cr);
        }
    }
}

/// Two caret frames describing the same state. Coalescing matters:
/// Chromium repeats tree_data on every update, so an uncoalesced
/// caret would post a frame per keystroke-sized tree change even when
/// the caret never moved.
pub fn axCaretEql(a: proto.EvA11yCaret, b: proto.EvA11yCaret) bool {
    return a.anchor_id == b.anchor_id and a.anchor_offset == b.anchor_offset and
        a.focus_id == b.focus_id and a.focus_offset == b.focus_offset;
}

/// Translate one engine node dict into a wire record. Inline text
/// boxes (pure layout fragments of their static-text parent) are
/// skipped: they double the tree for no reader-visible content, and a
/// child id with no node is defined as an absent child.
pub fn axPutNode(
    w: *proto.A11yNodeWriter,
    nd: *cef.cef_dictionary_value_t,
    alloc: std.mem.Allocator,
) !void {
    const id = dInt(nd, "id") orelse return;

    var role_buf: [64]u8 = undefined;
    var role: []const u8 = "generic";
    if (dStr(alloc, nd, "role")) |r| {
        if (std.mem.eql(u8, r, "inlineTextBox")) return;
        role = axRole(&role_buf, r);
    }

    var spec = proto.A11yNodeSpec{ .id = @bitCast(id), .role = role };

    if (dDict(nd, "state")) |st| {
        defer release(@ptrCast(&st.base));
        spec.state = axStateBits(st);
    }

    if (dDict(nd, "location")) |loc| {
        defer release(@ptrCast(&loc.base));
        spec.x = dInt(loc, "x") orelse 0;
        spec.y = dInt(loc, "y") orelse 0;
        spec.w = dInt(loc, "width") orelse 0;
        spec.h = dInt(loc, "height") orelse 0;
    }
    if (dInt(nd, "offset_container_id")) |oc| spec.offset_container = @bitCast(oc);

    var children: std.ArrayList(u32) = .empty;
    defer children.deinit(alloc);
    if (dList(nd, "child_ids")) |ids| {
        defer release(@ptrCast(&ids.base));
        var i: usize = 0;
        const n = listLen(ids);
        while (i < n) : (i += 1) {
            const gi = ids.get_int orelse break;
            try children.append(alloc, @bitCast(gi(ids, i)));
        }
    }
    spec.children = children.items;

    var attrs: std.ArrayList(proto.A11yAttr) = .empty;
    defer attrs.deinit(alloc);
    if (dDict(nd, "attributes")) |at| {
        defer release(@ptrCast(&at.base));
        if (dStr(alloc, at, "name")) |s| spec.name = s;
        if (dStr(alloc, at, "value")) |s| spec.value = s;
        if (dStr(alloc, at, "description")) |s| spec.description = s;
        for (ax_attr_map) |m| {
            if (axAttrString(alloc, at, m.from)) |val|
                try attrs.append(alloc, .{ .key = m.to, .value = val });
        }
        // checkedState / restriction fold into state bits rather than
        // travelling as attrs (CheckedState: 2 true, 3 mixed;
        // Restriction: 1 readOnly, 2 disabled — verified via the
        // debug dump, and a string-valued serializer is handled too).
        if (dInt(at, "checkedState")) |cs| {
            if (cs == 2) spec.state |= proto.ax_checked;
            if (cs == 3) spec.state |= proto.ax_checked_mixed;
        } else if (dStr(alloc, at, "checkedState")) |cs| {
            if (std.mem.eql(u8, cs, "true")) spec.state |= proto.ax_checked;
            if (std.mem.eql(u8, cs, "mixed")) spec.state |= proto.ax_checked_mixed;
        }
        if (dInt(at, "restriction")) |r| {
            if (r == 1) spec.state |= proto.ax_readonly;
            if (r == 2) spec.state |= proto.ax_disabled;
        } else if (dStr(alloc, at, "restriction")) |r| {
            if (std.mem.eql(u8, r, "readOnly")) spec.state |= proto.ax_readonly;
            if (std.mem.eql(u8, r, "disabled")) spec.state |= proto.ax_disabled;
        }
    }
    spec.attributes = attrs.items;
    try w.put(spec);
}

pub fn onAxTreeChange(
    _: [*c]cef.cef_accessibility_handler_t,
    value: [*c]cef.cef_value_t,
) callconv(.c) void {
    defer releaseArg(value);
    const host = host_mod.g_host orelse return;
    const val: *cef.cef_value_t = value orelse return;
    if (axDebug()) axDump("tree", val);
    const gt = val.get_type orelse return;
    if (gt(val) != cef.VTYPE_DICTIONARY) return;
    const gd = val.get_dictionary orelse return;
    const dict: *cef.cef_dictionary_value_t = gd(val) orelse return;
    defer release(@ptrCast(&dict.base));

    var arena_inst = std.heap.ArenaAllocator.init(host.gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const tree_id = dStr(arena, dict, "ax_tree_id") orelse "";
    const v = axResolveView(host, tree_id) orelse return;

    if (dList(dict, "updates")) |updates| {
        defer release(@ptrCast(&updates.base));
        var i: usize = 0;
        const n = listLen(updates);
        while (i < n) : (i += 1) {
            const upd = listDict(updates, i) orelse continue;
            defer release(@ptrCast(&upd.base));
            axEmitUpdate(host, v, upd, arena);
        }
    }

    if (dList(dict, "events")) |events| {
        defer release(@ptrCast(&events.base));
        var i: usize = 0;
        const n = listLen(events);
        while (i < n) : (i += 1) {
            const ev = listDict(events, i) orelse continue;
            defer release(@ptrCast(&ev.base));
            const etype = dStr(arena, ev, "event_type") orelse continue;
            const id: u32 = @bitCast(dInt(ev, "id") orelse 0);
            // Deliberately small vocabulary; everything else is noise
            // to a read-only projection and is dropped.
            const token: []const u8 = if (std.mem.eql(u8, etype, "focus"))
                "focus"
            else if (std.mem.eql(u8, etype, "loadComplete"))
                "load-complete"
            else
                continue;
            host.post(proto.EvA11yEvent{ .view = v.id, .id = id, .event = token });
        }
    }
}

pub fn onAxLocationChange(
    _: [*c]cef.cef_accessibility_handler_t,
    value: [*c]cef.cef_value_t,
) callconv(.c) void {
    defer releaseArg(value);
    const host = host_mod.g_host orelse return;
    const val: *cef.cef_value_t = value orelse return;
    if (axDebug()) axDump("loc", val);
    const gt = val.get_type orelse return;
    if (gt(val) != cef.VTYPE_LIST) return;
    const gl = val.get_list orelse return;
    const list: *cef.cef_list_value_t = gl(val) orelse return;
    defer release(@ptrCast(&list.base));

    var arena_inst = std.heap.ArenaAllocator.init(host.gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Group per view lazily: entries in one callback share a tree in
    // practice, so one frame per callback covers the real shape.
    var locs_buf: std.ArrayList(u8) = .empty;
    defer locs_buf.deinit(host.gpa);
    var view: ?*View = null;

    var i: usize = 0;
    const n = listLen(list);
    while (i < n) : (i += 1) {
        const e = listDict(list, i) orelse continue;
        defer release(@ptrCast(&e.base));
        const tree_id = dStr(arena, e, "ax_tree_id") orelse "";
        const v = axResolveView(host, tree_id) orelse continue;
        if (view != null and view.? != v) continue; // one view per frame
        view = v;
        var l = proto.A11yLoc{
            .id = @bitCast(dInt(e, "id") orelse 0),
            .offset_container = 0,
            .x = 0,
            .y = 0,
            .w = 0,
            .h = 0,
        };
        if (dInt(e, "offset_container_id")) |oc| l.offset_container = @bitCast(oc);
        if (dDict(e, "new_location")) |loc| {
            defer release(@ptrCast(&loc.base));
            l.x = dInt(loc, "x") orelse 0;
            l.y = dInt(loc, "y") orelse 0;
            l.w = dInt(loc, "width") orelse 0;
            l.h = dInt(loc, "height") orelse 0;
        }
        proto.putA11yLoc(host.gpa, &locs_buf, l) catch return;
    }
    const v = view orelse return;
    if (locs_buf.items.len == 0) return;
    host.post(proto.EvA11yLoc{ .view = v.id, .locs = .{ .s = locs_buf.items } });
}
