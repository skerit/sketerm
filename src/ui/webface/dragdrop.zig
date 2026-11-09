//! External drag-and-drop onto the page, the face half: the view's
//! drop target reads what the drag carries, plays it into the helper as
//! `input_drag` (enter, over, leave, drop) so the page gets a real DOM
//! drop with `File` objects, and lets the engine open what the page
//! leaves unhandled, as a browser does.
//!
//! A sketerm file-browser drag is read through its specs flavor while it
//! hovers, so nothing is fetched for a drag that is only passing by;
//! its remote entries are staged at the DROP, by reading the drag's file
//! list (`ui/browser/dragout.zig` fetches into the drag cache), and the
//! staged paths replace the stand-ins the hover carried. The GdkDrop is
//! finished only when that read settles.
//!
//! Lifetime: the session is a liveness fence (CLAUDE.md mechanism 3).
//! GTK's async reads complete whenever they like, so each holds the
//! session, whose `face` back-pointer `sever` clears at the face's
//! teardown; the session frees itself once it has ended and no read is
//! pending, finishing an accepted drop as refused if nobody else did.

const std = @import("std");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const proto = @import("../../web/protocol.zig");
const dragspecs = @import("../dragspecs.zig");
const dropdata = @import("dropdata.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;

pub const Session = struct {
    allocator: std.mem.Allocator,
    face: ?*WebFace,
    drop: *c.GdkDrop,
    data: dropdata.Data,
    x: i32 = 0,
    y: i32 = 0,
    /// Async reads holding this session.
    reads: u8 = 0,
    have_data: bool = false,
    /// The helper was sent `enter` (and so owes a `leave` or `drop`).
    entered: bool = false,
    dropped: bool = false,
    finished: bool = false,
    ended: bool = false,
    /// Files were left out because the helper runs on another host.
    files_refused: bool = false,
};

/// The target's formats: the specs flavor first (sketerm drags), then
/// files, then text, each with the MIME types that deserialize to it so
/// a drag from another process matches too.
pub fn targetFormats() ?*c.GdkContentFormats {
    const b = c.gdk_content_formats_builder_new() orelse return null;
    for (offerOrder()) |t| c.gdk_content_formats_builder_add_gtype(b, t);
    return c.gdk_content_formats_union_deserialize_mime_types(c.gdk_content_formats_builder_free_to_formats(b));
}

fn offerOrder() [3]c.GType {
    return .{ dragspecs.gtype(), c.gdk_file_list_get_type(), c.G_TYPE_STRING };
}

/// The type to read while the drag hovers, or G_TYPE_INVALID.
fn hoverType(drop: *c.GdkDrop) c.GType {
    const offered = c.gdk_content_formats_union_deserialize_gtypes(c.gdk_content_formats_ref(c.gdk_drop_get_formats(drop)));
    defer c.gdk_content_formats_unref(offered);
    for (offerOrder()) |t| if (c.gdk_content_formats_contain_gtype(offered, t) != 0) return t;
    return c.G_TYPE_INVALID;
}

/// Copy when the source allows it, else link; never move, so a drop on
/// a page can never make the source delete its file.
fn finishAction(drop: *c.GdkDrop) c.GdkDragAction {
    const offered = c.gdk_drop_get_actions(drop);
    if (offered & c.GDK_ACTION_COPY != 0) return c.GDK_ACTION_COPY;
    if (offered & c.GDK_ACTION_LINK != 0) return c.GDK_ACTION_LINK;
    return 0;
}

fn wireOps(drop: *c.GdkDrop) u8 {
    const offered = c.gdk_drop_get_actions(drop);
    var ops: u8 = 0;
    if (offered & c.GDK_ACTION_COPY != 0) ops |= proto.drag_op_copy;
    if (offered & c.GDK_ACTION_LINK != 0) ops |= proto.drag_op_link;
    if (offered & c.GDK_ACTION_MOVE != 0) ops |= proto.drag_op_move;
    return ops;
}

/// Whether the page itself takes this drop (else the face opens it).
fn engineTakes(face: *const WebFace) bool {
    return face.view_live and face.cl.has(.drag_drop);
}

pub fn onDragEnter(_: ?*c.GtkDropTargetAsync, drop: ?*c.GdkDrop, x: f64, y: f64, user: ?*anyopaque) callconv(.c) c.GdkDragAction {
    const self = cast.userData(WebFace, user);
    const d = drop orelse return 0;
    if (self.widgets_dead) return 0;
    if (self.drag) |old| {
        // A drop still being fetched owns the session; a new drag waits.
        if (old.dropped) return 0;
        // A drag that re-enters without a leave in between.
        if (old.entered and self.view_live) self.cl.post(old.data.frame(self.view, .leave, old.x, old.y, 0, false));
    }
    endSession(self);
    const action = finishAction(d);
    if (action == 0) return 0;
    const ty = hoverType(d);
    if (ty == c.G_TYPE_INVALID) return 0;
    const s = self.allocator.create(Session) catch return 0;
    s.* = .{
        .allocator = self.allocator,
        .face = self,
        .drop = @ptrCast(@alignCast(c.g_object_ref(d))),
        .data = dropdata.Data.init(self.allocator),
    };
    self.drag = s;
    setPos(s, self, x, y);
    s.reads += 1;
    c.gdk_drop_read_value_async(d, ty, c.G_PRIORITY_DEFAULT, null, @ptrCast(&onHoverRead), s);
    return action;
}

pub fn onDragMotion(_: ?*c.GtkDropTargetAsync, drop: ?*c.GdkDrop, x: f64, y: f64, user: ?*anyopaque) callconv(.c) c.GdkDragAction {
    const self = cast.userData(WebFace, user);
    const s = self.drag orelse return 0;
    if (s.drop != drop) return 0;
    setPos(s, self, x, y);
    if (s.entered) self.cl.post(s.data.frame(self.view, .over, s.x, s.y, wireOps(s.drop), false));
    return finishAction(s.drop);
}

pub fn onDragLeave(_: ?*c.GtkDropTargetAsync, drop: ?*c.GdkDrop, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(WebFace, user);
    const s = self.drag orelse return;
    // GTK also leaves after a drop; that drop is still being delivered.
    if (s.drop != drop or s.dropped) return;
    if (s.entered and self.view_live) self.cl.post(s.data.frame(self.view, .leave, s.x, s.y, 0, false));
    endSession(self);
}

pub fn onDrop(_: ?*c.GtkDropTargetAsync, drop: ?*c.GdkDrop, x: f64, y: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(WebFace, user);
    const s = self.drag orelse return 0;
    if (s.drop != drop or s.dropped) return 0;
    setPos(s, self, x, y);
    s.dropped = true;
    // A drop that beat its own hover read is delivered when it lands.
    if (s.have_data) deliver(s, self);
    return 1;
}

/// The face's teardown: its pending reads find no face and refuse.
pub fn sever(self: *WebFace) void {
    const s = self.drag orelse return;
    s.face = null;
    endSession(self);
}

fn setPos(s: *Session, face: *WebFace, x: f64, y: f64) void {
    const pt = face.pagePoint(x, y);
    s.x = pt[0];
    s.y = pt[1];
}

fn endSession(face: *WebFace) void {
    const s = face.drag orelse return;
    face.drag = null;
    s.ended = true;
    release(s);
}

fn finish(s: *Session, action: c.GdkDragAction) void {
    if (s.finished or !s.dropped) return;
    s.finished = true;
    c.gdk_drop_finish(s.drop, action);
}

fn release(s: *Session) void {
    if (!s.ended or s.reads > 0) return;
    finish(s, 0);
    s.data.deinit();
    c.g_object_unref(s.drop);
    s.allocator.destroy(s);
}

/// Read back a finished async read; null on failure (`err` set).
fn readValue(source: ?*c.GObject, result: ?*c.GAsyncResult, err: *?*c.GError) ?*const c.GValue {
    const v = c.gdk_drop_read_value_finish(@ptrCast(@alignCast(source)), result, @ptrCast(err));
    return @ptrCast(v);
}

fn onHoverRead(source: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const s: *Session = @ptrCast(@alignCast(user.?));
    s.reads -= 1;
    var err: ?*c.GError = null;
    const value = readValue(source, result, &err);
    defer if (err) |e| c.g_error_free(e);
    if (s.ended) return release(s);
    const face = s.face orelse return release(s);
    if (value) |v| fill(&s.data, v) catch s.data.clearFiles();
    if (face.cl.isRemote() and s.data.files.items.len != 0) {
        // Paths of this host mean nothing to a helper on another one.
        s.data.clearFiles();
        s.files_refused = true;
    }
    s.have_data = true;
    if (s.dropped) return deliver(s, face);
    if (!engineTakes(face) or s.data.empty()) return;
    face.cl.post(s.data.frame(face.view, .enter, s.x, s.y, wireOps(s.drop), true));
    face.cl.post(s.data.frame(face.view, .over, s.x, s.y, wireOps(s.drop), false));
    s.entered = true;
}

fn fill(data: *dropdata.Data, v: *const c.GValue) !void {
    if (dragspecs.holds(v)) {
        var it = dragspecs.Iter.init(v);
        while (it.next()) |rec| try data.addSpec(rec.spec);
        return;
    }
    if (c.g_type_check_value_holds(v, c.gdk_file_list_get_type()) != 0) return fillFiles(data, v);
    if (c.g_type_check_value_holds(v, c.G_TYPE_STRING) != 0) {
        const s = c.g_value_get_string(v) orelse return;
        try data.setText(std.mem.span(@as([*:0]const u8, @ptrCast(s))));
    }
}

/// Files with a local path become files; anything else (an http link
/// dragged out of another browser) is the drop's link.
fn fillFiles(data: *dropdata.Data, v: *const c.GValue) !void {
    const flist: ?*c.GdkFileList = @ptrCast(c.g_value_get_boxed(v));
    // get_files is transfer-container: free the list, not the GFiles.
    const files = c.gdk_file_list_get_files(flist);
    defer c.g_slist_free(files);
    var node = files;
    while (node != null) : (node = node.*.next) {
        const gfile: ?*c.GFile = @ptrCast(@alignCast(node.*.data));
        if (c.g_file_get_path(gfile)) |p| {
            defer c.g_free(p);
            try data.addPath(std.mem.span(@as([*:0]const u8, @ptrCast(p))));
            continue;
        }
        const uri = c.g_file_get_uri(gfile) orelse continue;
        defer c.g_free(uri);
        try data.addUrl(std.mem.span(@as([*:0]const u8, @ptrCast(uri))));
    }
}

/// The drop landed and its hover data is known: stage remote entries
/// first, then hand it over.
fn deliver(s: *Session, face: *WebFace) void {
    if (s.data.remote) {
        s.reads += 1;
        c.gdk_drop_read_value_async(s.drop, c.gdk_file_list_get_type(), c.G_PRIORITY_DEFAULT, null, @ptrCast(&onStaged), s);
        return;
    }
    complete(s, face, false);
}

fn onStaged(source: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const s: *Session = @ptrCast(@alignCast(user.?));
    s.reads -= 1;
    var err: ?*c.GError = null;
    const value = readValue(source, result, &err);
    defer if (err) |e| c.g_error_free(e);
    if (s.ended) return release(s);
    const face = s.face orelse return release(s);
    const v = value orelse {
        const msg: []const u8 = if (err) |e| std.mem.span(@as([*:0]const u8, @ptrCast(e.*.message))) else "unknown error";
        var buf: [384]u8 = undefined;
        face.toast(std.fmt.bufPrint(&buf, "Could not fetch the dropped file: {s}", .{msg}) catch "Could not fetch the dropped file.");
        if (s.entered and face.view_live) face.cl.post(s.data.frame(face.view, .leave, s.x, s.y, 0, false));
        return endSession(face);
    };
    s.data.clearFiles();
    fillFiles(&s.data, v) catch s.data.clearFiles();
    complete(s, face, true);
}

/// Hand the drop to the page (or open it here) and end the session.
fn complete(s: *Session, face: *WebFace, replaced: bool) void {
    defer endSession(face);
    if (s.data.empty()) {
        if (s.entered and face.view_live) face.cl.post(s.data.frame(face.view, .leave, s.x, s.y, 0, false));
        if (s.files_refused) face.toast("Files cannot be dropped onto a page whose browser runs on another host.");
        return;
    }
    if (engineTakes(face)) {
        // Data rides the drop when the hover never entered or carried
        // stand-ins; the helper then re-enters with it.
        face.cl.post(s.data.frame(face.view, .drop, s.x, s.y, wireOps(s.drop), replaced or !s.entered));
        finish(s, finishAction(s.drop));
        return;
    }
    switch (dropdata.fallback(&s.data)) {
        .none => return,
        .url, .address => |u| face.navigate(u),
        .file => |path| {
            const z = s.allocator.dupeSentinel(u8, path, 0) catch return;
            defer s.allocator.free(z);
            const uri = c.g_filename_to_uri(z.ptr, null, null) orelse return;
            defer c.g_free(uri);
            face.navigate(std.mem.span(@as([*:0]const u8, @ptrCast(uri))));
        },
    }
    finish(s, finishAction(s.drop));
}
