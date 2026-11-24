//! Uploads (capability "upload", frames 0x7D/0x7E): files a client armed
//! with `upload_arm` are put into the file input whose chooser the page
//! opens next, and the outcome is reported as `ev_upload`. The `Host`
//! method is a free function taking `*Host`, re-exported from `Host`.
//!
//! The mechanism is the view's DevTools session, the way browser
//! automation does it: `Page.setInterceptFileChooserDialog` makes the
//! engine report a chooser (`Page.fileChooserOpened`, naming the input's
//! backend node) instead of showing one, and `DOM.setFileInputFiles` sets
//! the files on that node, which fires the page's input and change events
//! as a user selection does. `cef_dialog_handler_t` is NOT the mechanism:
//! measured on CEF 151, a windowless view's chooser never reaches
//! `get_dialog_handler`, and an un-intercepted chooser leaves the page's
//! main thread stalled (timers stop, navigation and eval never answer).
//!
//! The interception is on only while an upload is armed, so a view that
//! never uploads never attaches a DevTools agent for it. Every armed
//! upload is ANSWERED: by its chooser, by a disarm, or by the client's
//! own deadline when no chooser opens (the client then disarms).

const std = @import("std");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const devtools = @import("devtools_session.zig");
const Host = host_mod.Host;
const View = host_mod.View;

const method_timeout_ms: i64 = 10_000;

/// One view's armed upload.
pub const Armed = struct {
    /// 0 = nothing armed.
    req: u32 = 0,
    /// NUL-joined absolute paths, owned.
    paths: []u8 = &.{},
    phase: enum {
        idle,
        /// Intercepting; waiting for the page to open a chooser.
        armed,
        /// The chooser opened; the answer is sent from `pump`.
        opened,
        /// `DOM.setFileInputFiles` is in flight.
        setting,
    } = .idle,
    /// The file input the chooser belongs to (`backendNodeId`).
    node: i64 = 0,
    multiple: bool = false,
    set_id: c_int = 0,
    /// The arming methods, kept only to be forgotten.
    arm_ids: [2]c_int = .{ 0, 0 },

    fn count(self: Armed) u32 {
        var n: u32 = 0;
        var it = std.mem.splitScalar(u8, self.paths, 0);
        while (it.next()) |p| {
            if (p.len != 0) n += 1;
        }
        return n;
    }

    /// Free what is owned; the DevTools side is `disarm`'s.
    pub fn clear(self: *Armed, gpa: std.mem.Allocator) void {
        if (self.paths.len != 0) gpa.free(self.paths);
        self.* = .{};
    }
};

fn post(host: *Host, v: *View, req: u32, outcome: u8, count: u32) void {
    host.post(proto.EvUpload{
        .view = v.id,
        .req = req,
        .outcome = outcome,
        .multiple = @intFromBool(v.upload.multiple),
        .count = count,
    });
}

/// Stop intercepting and forget the armed files. Idempotent.
fn disarm(host: *Host, v: *View) void {
    if (v.upload.phase != .idle) {
        if (v.devtools) |session| {
            // Only this module's sink is removed: a trace owns its own.
            if (session.events) |sink| {
                if (sink.ctx == @as(*anyopaque, @ptrCast(v)) and sink.on_event == &onEvent) session.events = null;
            }
            if (v.upload.set_id != 0) session.forget(v.upload.set_id);
            for (v.upload.arm_ids) |id| if (id != 0) session.forget(id);
            if (v.browser) |browser| _ = devtools.execute(browser, "Page.setInterceptFileChooserDialog", "{\"enabled\":false}");
        }
    }
    v.upload.clear(host.gpa);
}

/// `upload_arm`: replace what is armed for the view; empty paths disarm.
pub fn uploadArm(self: *Host, req: proto.UploadArm) void {
    const v = self.find(req.view) orelse return;
    disarm(self, v);
    if (req.paths.len == 0 or req.req == 0) return;
    const refused = struct {
        fn f(host: *Host, view: *View, id: u32) void {
            view.upload.multiple = false;
            post(host, view, id, proto.upload_failed, 0);
        }
    }.f;
    const browser = v.browser orelse return refused(self, v, req.req);
    const session = self.devtoolsFor(v) catch return refused(self, v, req.req);
    // One event sink per session: a running trace has it.
    if (session.events != null) return refused(self, v, req.req);
    const owned = self.gpa.dupe(u8, req.paths) catch return refused(self, v, req.req);
    // Not awaited: the methods and the click that follows are handled in
    // order on the engine's UI thread, and a refusal shows as a chooser
    // that is never reported. The Page domain carries the chooser event.
    const enable_id = session.send(browser, "Page.enable", null, method_timeout_ms, .memory, "") catch 0;
    const intercept_id = session.send(browser, "Page.setInterceptFileChooserDialog", "{\"enabled\":true}", method_timeout_ms, .memory, "") catch {
        if (enable_id != 0) session.forget(enable_id);
        self.gpa.free(owned);
        return refused(self, v, req.req);
    };
    session.events = .{ .ctx = v, .on_event = onEvent };
    v.upload = .{ .req = req.req, .paths = owned, .phase = .armed, .arm_ids = .{ enable_id, intercept_id } };
}

/// Records the chooser; nothing is sent from inside an event callback.
fn onEvent(ctx: *anyopaque, method: []const u8, params: []const u8) void {
    const v: *View = @ptrCast(@alignCast(ctx));
    if (v.upload.phase != .armed or !std.mem.eql(u8, method, "Page.fileChooserOpened")) return;
    const host = host_mod.g_host orelse return;
    const Opened = struct { mode: []const u8 = "", backendNodeId: i64 = 0 };
    const parsed = std.json.parseFromSlice(Opened, host.gpa, params, .{ .ignore_unknown_fields = true }) catch {
        v.upload.phase = .opened;
        return;
    };
    defer parsed.deinit();
    v.upload.node = parsed.value.backendNodeId;
    v.upload.multiple = std.mem.eql(u8, parsed.value.mode, "selectMultiple");
    v.upload.phase = .opened;
}

/// `{"files":[...],"backendNodeId":N}` for the armed paths.
fn setFilesParams(gpa: std.mem.Allocator, armed: Armed) ![]u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var it = std.mem.splitScalar(u8, armed.paths, 0);
    while (it.next()) |p| {
        if (p.len != 0) try files.append(gpa, p);
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.json.Stringify.value(.{ .files = files.items, .backendNodeId = armed.node }, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Advance every view's upload: answer an opened chooser, report a set.
pub fn pump(host: *Host) void {
    for (host.views.items) |v| {
        switch (v.upload.phase) {
            .idle, .armed => {},
            .opened => answer(host, v),
            .setting => {
                const session = v.devtools orelse {
                    finish(host, v, proto.upload_failed);
                    continue;
                };
                switch (session.outcome(v.upload.set_id)) {
                    .pending => {},
                    .ok => finish(host, v, proto.upload_answered),
                    .failed => finish(host, v, proto.upload_failed),
                }
            },
        }
    }
}

fn answer(host: *Host, v: *View) void {
    const n = v.upload.count();
    if (v.upload.node == 0) return finish(host, v, proto.upload_failed);
    if (n > 1 and !v.upload.multiple) return finish(host, v, proto.upload_too_many);
    const session = v.devtools orelse return finish(host, v, proto.upload_failed);
    const browser = v.browser orelse return finish(host, v, proto.upload_failed);
    const params = setFilesParams(host.gpa, v.upload) catch return finish(host, v, proto.upload_failed);
    defer host.gpa.free(params);
    v.upload.set_id = session.send(browser, "DOM.setFileInputFiles", params, method_timeout_ms, .memory, "") catch
        return finish(host, v, proto.upload_failed);
    v.upload.phase = .setting;
}

fn finish(host: *Host, v: *View, outcome: u8) void {
    const req = v.upload.req;
    const count: u32 = if (outcome == proto.upload_answered) v.upload.count() else 0;
    post(host, v, req, outcome, count);
    disarm(host, v);
}
