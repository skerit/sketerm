//! Uploads and file choosers (capability "upload", frames 0x7D-0x7F):
//! files a client armed with `upload_arm` are put into the file input
//! whose chooser the page opens next, the outcome is reported as
//! `ev_upload`, and a client that asked for it (`upload_watch`) is told
//! of every chooser nobody armed. The `Host` methods are free functions
//! taking `*Host`, re-exported from `Host`.
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
//! That stall is why a client driving pages nobody else operates keeps
//! the interception on for a view's whole life (`upload_watch`).
//!
//! The interception is on only while a client wants it: a watch, or an
//! armed upload. A view of a client that asks for neither (a GUI pane,
//! whose user answers the engine's own dialog) attaches no agent for it.
//! Every armed upload is ANSWERED: by its chooser, by a disarm, by the
//! browser going away, or by the client's own deadline when no chooser
//! opens (the client then disarms).

const std = @import("std");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const devtools = @import("devtools_session.zig");
const Host = host_mod.Host;
const View = host_mod.View;

const method_timeout_ms: i64 = 10_000;

/// One view's chooser interception and armed upload.
pub const State = struct {
    /// The client wants every chooser intercepted and reported.
    watch: bool = false,
    /// The armed request; 0 = nothing armed.
    req: u32 = 0,
    /// NUL-joined absolute paths, owned.
    paths: []u8 = &.{},
    phase: enum {
        idle,
        /// Waiting for the page to open a chooser.
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
    /// The session the interception is enabled on, with its detach count
    /// then: a new browser or a detached agent has none of it.
    on: ?*devtools.Session = null,
    detaches_seen: u32 = 0,
    /// The enabling methods, kept only to be forgotten.
    on_ids: [2]c_int = .{ 0, 0 },

    fn count(self: State) u32 {
        var n: u32 = 0;
        var it = std.mem.splitScalar(u8, self.paths, 0);
        while (it.next()) |p| {
            if (p.len != 0) n += 1;
        }
        return n;
    }

    fn wanted(self: State) bool {
        return self.watch or self.phase != .idle;
    }

    /// Free what is owned; the view is going away with its session.
    pub fn clear(self: *State, gpa: std.mem.Allocator) void {
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

/// Bring the interception in line with what the client wants.
/// @return whether it is on (false also while the view has no browser yet; `pump` retries).
fn sync(host: *Host, v: *View) bool {
    const st = &v.upload;
    if (!st.wanted()) {
        const session = st.on orelse return false;
        st.on = null;
        if (v.devtools != session) return false;
        session.chooser = null;
        for (st.on_ids) |id| if (id != 0) session.forget(id);
        st.on_ids = .{ 0, 0 };
        if (v.browser) |browser| _ = devtools.execute(browser, "Page.setInterceptFileChooserDialog", "{\"enabled\":false}");
        return false;
    }
    const browser = v.browser orelse return false;
    const session = host.devtoolsFor(v) catch return false;
    if (st.on == session and st.detaches_seen == session.detaches) return true;
    if (st.on == session) for (st.on_ids) |id| if (id != 0) session.forget(id);
    // Not awaited: these and the click that follows are handled in order
    // on the engine's UI thread, and a refusal shows as a chooser that is
    // never reported. The chooser event needs the Page domain enabled.
    const enable_id = session.send(browser, "Page.enable", null, method_timeout_ms, .memory, "") catch 0;
    const intercept_id = session.send(browser, "Page.setInterceptFileChooserDialog", "{\"enabled\":true}", method_timeout_ms, .memory, "") catch {
        if (enable_id != 0) session.forget(enable_id);
        st.on = null;
        return false;
    };
    session.chooser = .{ .ctx = v, .on_event = onChooser };
    st.on = session;
    st.detaches_seen = session.detaches;
    st.on_ids = .{ enable_id, intercept_id };
    return true;
}

/// Drop the armed files and what was learnt about their chooser.
fn dropFiles(host: *Host, v: *View) void {
    const st = &v.upload;
    if (st.set_id != 0) if (v.devtools) |session| session.forget(st.set_id);
    if (st.paths.len != 0) host.gpa.free(st.paths);
    st.paths = &.{};
    st.req = 0;
    st.phase = .idle;
    st.node = 0;
    st.multiple = false;
    st.set_id = 0;
}

/// `upload_watch`: keep every chooser of the view intercepted, or stop.
pub fn uploadWatch(self: *Host, req: proto.UploadWatch) void {
    const v = self.find(req.view) orelse return;
    v.upload.watch = req.enabled != 0;
    _ = sync(self, v);
}

/// `upload_arm`: replace what is armed for the view; empty paths disarm.
pub fn uploadArm(self: *Host, req: proto.UploadArm) void {
    const v = self.find(req.view) orelse return;
    dropFiles(self, v);
    if (req.paths.len == 0 or req.req == 0) {
        _ = sync(self, v);
        return;
    }
    const owned = self.gpa.dupe(u8, req.paths) catch return post(self, v, req.req, proto.upload_failed, 0);
    v.upload.req = req.req;
    v.upload.paths = owned;
    v.upload.phase = .armed;
    if (!sync(self, v)) finish(self, v, proto.upload_failed);
}

/// The view's browser is gone, and its session with it: an armed upload
/// can no longer be answered, and a revived browser is intercepted anew.
pub fn browserGone(host: *Host, v: *View) void {
    v.upload.on = null;
    v.upload.on_ids = .{ 0, 0 };
    if (v.upload.phase != .idle) {
        v.upload.set_id = 0;
        finish(host, v, proto.upload_failed);
    }
}

/// `Page.fileChooserOpened`. An armed chooser is only recorded here
/// (its answer is a DevTools method, sent from `pump`); an unarmed one
/// is reported at once, while the act that opened it is still settling.
fn onChooser(ctx: *anyopaque, _: []const u8, params: []const u8) void {
    const v: *View = @ptrCast(@alignCast(ctx));
    const host = host_mod.g_host orelse return;
    const Opened = struct { mode: []const u8 = "", backendNodeId: i64 = 0 };
    const parsed = std.json.parseFromSlice(Opened, host.gpa, params, .{ .ignore_unknown_fields = true }) catch null;
    defer if (parsed) |p| p.deinit();
    const multiple = if (parsed) |p| std.mem.eql(u8, p.value.mode, "selectMultiple") else false;
    switch (v.upload.phase) {
        .armed => {
            v.upload.node = if (parsed) |p| p.value.backendNodeId else 0;
            v.upload.multiple = multiple;
            v.upload.phase = .opened;
        },
        .idle => host.post(proto.EvUpload{
            .view = v.id,
            .req = 0,
            .outcome = proto.upload_unanswered,
            .multiple = @intFromBool(multiple),
            .count = 0,
        }),
        // A second chooser while the first is being answered: the page's own queue.
        .opened, .setting => {},
    }
}

/// `{"files":[...],"backendNodeId":N}` for the armed paths.
fn setFilesParams(gpa: std.mem.Allocator, st: State) ![]u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var it = std.mem.splitScalar(u8, st.paths, 0);
    while (it.next()) |p| {
        if (p.len != 0) try files.append(gpa, p);
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.json.Stringify.value(.{ .files = files.items, .backendNodeId = st.node }, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Advance every view: (re)enable a wanted interception, answer an
/// opened chooser, report a finished set. Called from the host watchdog.
pub fn pump(host: *Host) void {
    for (host.views.items) |v| {
        if (v.upload.wanted()) _ = sync(host, v);
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
    dropFiles(host, v);
    _ = sync(host, v);
}
