//! Hosting and addressing for panel documents: the `panel-*` half of
//! the GUI control socket.
//!
//! A panel is a declarative document (src/ui/panel/doc.zig) rendered by
//! a `PanelView` and hosted either as a PANE FACE (on the requesting
//! pane, or on a fresh tab's pane) or in a STANDALONE WINDOW
//! (ui/panelwin.zig). Which of the three a caller gets is the `target`
//! parameter; everything else about a panel is identical across them.
//!
//! **Panels are keyed by (session, name).** Several assistants drive
//! one sketerm at once, and their panels must neither collide nor be
//! visible to each other, so every panel is scoped to the daemon
//! session of the pane that asked for it (`$SKETERM_SESSION`, exported
//! into every pane — see src/pty.zig). Showing a name that already
//! exists in that session REPLACES that panel's document in place
//! rather than opening a second window: "here is epoch 42" is then a
//! cheap, repeatable call, which is the whole point of the feature.
//!
//! Liveness: the registry entry IS the pane face's context pointer, so
//! there is exactly one place a panel can die — the face's destroy
//! trampoline (reached from `Pane.severFaces` for every pane teardown
//! path) and, for a window panel, the window's ::destroy. Both
//! unregister before anything is freed, so a `panel_id` never outlives
//! the widgets behind it.
//!
//! Threading: everything here runs on the GTK main thread.
//! `panel-events` therefore NEVER blocks — it drains whatever the queue
//! holds and answers immediately, even with nothing. Blocking
//! `ui_wait_event` semantics belong to the MCP layer polling this
//! command; `events.Queue.waitAny` is for a thread that may sleep and
//! must not be called from here.

const std = @import("std");
const c = @import("../c.zig").c;
const protocol = @import("../ipc/protocol.zig");
const panelstore = @import("../ipc/panelstore.zig");
const Pane = @import("pane.zig").Pane;
const winmod = @import("window.zig");
const Window = winmod.Window;
const remotectl = @import("remotectl.zig");
const Doc = @import("panel/doc.zig");
const events = @import("panel/events.zig");
const PanelView = @import("panel/view.zig").PanelView;
const PanelWindow = @import("panelwin.zig").PanelWindow;

pub const Target = enum {
    /// The requesting pane itself wears the panel face.
    pane,
    /// A new tab in the requesting pane's window, whose pane wears it.
    tab,
    /// A standalone panel window.
    window,

    pub fn fromName(s: ?[]const u8) ?Target {
        const want = s orelse return .tab;
        if (want.len == 0) return .tab;
        return std.meta.stringToEnum(Target, want);
    }

    pub fn name(self: Target) []const u8 {
        return @tagName(self);
    }
};

/// How "no session at all" travels: a caller with no session identity
/// (a script talking to the socket from outside any pane) sends
/// `"session":""`, and gets `""` back in every reply that echoes one.
///
/// It is not a session NAME — the daemon never issues an empty one,
/// and nothing here or in the store ever treats it as one: in code the
/// scope is `?[]const u8` and this is only its wire spelling, which is
/// what keeps a sessionless panel and its saved document (a directory
/// of its own, `panelstore.NO_SESSION_DIR`) under the same key.
/// Distinct from an ABSENT `session` field, which means "scope me to
/// the requesting pane".
pub const NO_SESSION_WIRE: []const u8 = "";

/// One live panel. Heap-allocated and pointer-stable: it doubles as
/// the pane face's context, so its address is handed to GTK.
pub const Entry = struct {
    allocator: std.mem.Allocator,
    panel_id: u32,
    /// Owned.
    name: []u8,
    /// Owned. `null` = the caller had no session identity.
    session: ?[]u8,
    target: Target,
    view: *PanelView,
    /// Pane hosting the face (.pane / .tab targets). Valid for as long
    /// as the entry is registered.
    pane: ?*Pane = null,
    /// Window hosting it (.window target).
    win: ?*PanelWindow = null,

    fn destroy(self: *Entry) void {
        const a = self.allocator;
        a.free(self.name);
        if (self.session) |sess| a.free(sess);
        a.destroy(self);
    }
};

/// Process-global panel registry. The GUI is single-threaded, and a
/// panel is addressed by id from any window's socket, so the registry
/// is module-level exactly like `remotectl.next_pane_id`.
var panels: std.ArrayListUnmanaged(*Entry) = .empty;
var next_panel_id: u32 = 1;

fn register(allocator: std.mem.Allocator, entry: *Entry) !void {
    try panels.append(allocator, entry);
}

fn unregister(entry: *Entry) void {
    for (panels.items, 0..) |e, i| {
        if (e == entry) {
            _ = panels.orderedRemove(i);
            return;
        }
    }
}

fn byId(id: u32) ?*Entry {
    for (panels.items) |e| {
        if (e.panel_id == id) return e;
    }
    return null;
}

fn byKey(session: ?[]const u8, name: []const u8) ?*Entry {
    for (panels.items) |e| {
        if (sameSession(e.session, session) and std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// Two scopes are the same panel key. Sessionless matches ONLY
/// sessionless: it is a different shape, not a name.
fn sameSession(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The daemon session a pane renders — the identity behind
/// `$SKETERM_SESSION`.
fn paneSession(pane: ?*Pane) ?[]const u8 {
    const p = pane orelse return null;
    const r = p.terminal.remote orelse return null;
    return r.session;
}

/// The session a request is scoped to: the explicit `session` field
/// (which is also how a pane names itself), else the resolved pane's
/// own session — and `null` when there is none, which is a scope of
/// its own rather than a name. An EMPTY explicit session is a caller
/// stating it has no session identity (`NO_SESSION_WIRE`), so it does
/// not fall through to the pane.
fn scopeOf(req: protocol.Request, pane: ?*Pane) ?[]const u8 {
    if (req.session) |s| return if (s.len == 0) null else s;
    return paneSession(pane);
}

/// The wire spelling of a scope, for a reply that echoes one.
fn wireSession(session: ?[]const u8) []const u8 {
    return session orelse NO_SESSION_WIRE;
}

// ─── dispatch ───────────────────────────────────────────────────

/// Handle any `panel-*` command. Called from remotectl's dispatcher;
/// always writes exactly one response line.
pub fn dispatch(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const eql = std.mem.eql;
    if (eql(u8, req.cmd, "panel-show")) {
        try panelShow(self, req, out, allocator);
    } else if (eql(u8, req.cmd, "panel-patch")) {
        try panelPatch(req, out, allocator);
    } else if (eql(u8, req.cmd, "panel-get")) {
        try panelGet(req, out, allocator);
    } else if (eql(u8, req.cmd, "panel-events")) {
        try panelEvents(req, out, allocator);
    } else if (eql(u8, req.cmd, "panel-list")) {
        try panelList(self, req, out, allocator);
    } else if (eql(u8, req.cmd, "panel-close")) {
        try panelClose(self, req, out, allocator);
    } else {
        try protocol.writeErr(out, allocator, "unknown panel command");
    }
}

/// A document/patch failure answers with doc.Diag's own message,
/// VERBATIM: it names the offending component id, and the assistant
/// that wrote the document needs that text to fix it. The error name
/// is only the fallback for a failure that set no diagnostic.
fn diagErr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diag: *const Doc.Diag,
    err: anyerror,
) !void {
    const msg = diag.msg();
    if (msg.len > 0) return protocol.writeErr(out, allocator, msg);
    var buf: [64]u8 = undefined;
    const fallback = std.fmt.bufPrint(&buf, "panel rejected: {s}", .{@errorName(err)}) catch "panel rejected";
    return protocol.writeErr(out, allocator, fallback);
}

/// Give up on a half-built panel: free the entry and the view it
/// carries (nothing else can be holding either yet) and fail with
/// `msg` in the diagnostic.
fn abortNew(
    entry: *Entry,
    diag: *Doc.Diag,
    err: ShowError,
    msg: []const u8,
) ShowError {
    const view = entry.view;
    entry.destroy();
    view.deinit();
    diag.set("{s}", .{msg});
    return err;
}

fn panelShow(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const name = req.name orelse
        return protocol.writeErr(out, allocator, "panel-show requires a name");
    if (name.len == 0 or name.len > 128)
        return protocol.writeErr(out, allocator, "panel name must be 1..128 bytes");
    const document = req.document orelse
        return protocol.writeErr(out, allocator, "panel-show requires a document (JSON string)");
    const target = Target.fromName(req.target) orelse
        return protocol.writeErr(out, allocator, "target must be \"pane\", \"tab\" or \"window\"");

    // The pane the request came FROM: its session scopes the panel, and
    // for target "pane" it is also the pane that wears the face.
    const origin = remotectl.reqPane(self, req);
    const session = scopeOf(req, origin);

    var diag = Doc.Diag{};
    const entry = showDocument(self, origin, session, name, document, target, &diag) catch |err|
        return diagErr(out, allocator, &diag, err);
    presentEntry(self, entry);
    try protocol.writeOkFlat(out, allocator, .{
        .panel_id = entry.panel_id,
        .session = wireSession(entry.session),
    });
}

pub const ShowError = error{
    /// The document was rejected; `diag` carries the parser's message.
    BadDocument,
    OutOfMemory,
    /// `target = .pane` with no pane to wear the face.
    NoPane,
    /// The panel's own tab or window could not be created.
    NoHost,
};

/// Mount `document` as the panel `(session, name)`. THE mounting path:
/// the control socket and the GUI's own palette both go through it, so
/// the keying and the replace-in-place rule cannot diverge between
/// them. Does NOT raise the panel — callers that want it in front call
/// `presentEntry` (panel-patch deliberately does not).
///
/// Every failure sets `diag`, so one message source explains all of
/// them. On failure nothing is registered and nothing is left on screen.
pub fn showDocument(
    self: *Window,
    origin: ?*Pane,
    session: ?[]const u8,
    name: []const u8,
    document: []const u8,
    target: Target,
    diag: *Doc.Diag,
) ShowError!*Entry {
    const allocator = self.allocator;

    // Same (session, name) as a live panel: replace its document in
    // place. That is what makes a training loop's repeated "here is
    // epoch N" cheap — and what keeps one assistant to one panel per
    // name.
    if (byKey(session, name)) |existing| {
        existing.view.setDocument(document, diag) catch return ShowError.BadDocument;
        return existing;
    }

    const view = PanelView.create(allocator) catch return oom(diag);
    // Validate BEFORE hosting: a malformed document must not leave a
    // blank tab or window behind.
    view.setDocument(document, diag) catch {
        view.deinit();
        return ShowError.BadDocument;
    };

    const entry = allocator.create(Entry) catch {
        view.deinit();
        return oom(diag);
    };
    entry.* = .{
        .allocator = allocator,
        .panel_id = next_panel_id,
        .name = allocator.dupe(u8, name) catch {
            allocator.destroy(entry);
            view.deinit();
            return oom(diag);
        },
        .session = if (session) |sess| allocator.dupe(u8, sess) catch {
            allocator.free(entry.name);
            allocator.destroy(entry);
            view.deinit();
            return oom(diag);
        } else null,
        .target = target,
        .view = view,
    };
    // From here on every failure goes through `abortNew`: the entry is
    // not registered yet, so nothing else can be holding either half.
    switch (target) {
        .pane => {
            const pane = origin orelse
                return abortNew(entry, diag, ShowError.NoPane, "no pane to put the panel on");
            entry.pane = pane;
            register(allocator, entry) catch
                return abortNew(entry, diag, ShowError.OutOfMemory, "panel: out of memory");
            pane.attachPanel(view.root_box, @ptrCast(entry), paneFacePrepare, paneFaceDestroy, paneFaceFocus);
        },
        .tab => {
            const host_win = if (origin) |p| remotectl.ownerWindow(self, p) else remotectl.activeOrSelf(self);
            const before = host_win.panes.items.len;
            host_win.newShellTab("Panel") catch
                return abortNew(entry, diag, ShowError.NoHost, "panel: could not open a tab");
            if (host_win.panes.items.len <= before)
                return abortNew(entry, diag, ShowError.NoHost, "panel: tab spawn produced no pane");
            const pane = host_win.panes.items[host_win.panes.items.len - 1];
            entry.pane = pane;
            register(allocator, entry) catch
                return abortNew(entry, diag, ShowError.OutOfMemory, "panel: out of memory");
            pane.attachPanel(view.root_box, @ptrCast(entry), paneFacePrepare, paneFaceDestroy, paneFaceFocus);
        },
        .window => {
            const app = c.gtk_window_get_application(@ptrCast(self.app_window));
            const pw = PanelWindow.open(allocator, app, view) catch
                return abortNew(entry, diag, ShowError.NoHost, "panel: could not open a window");
            entry.win = pw;
            register(allocator, entry) catch {
                // The window owns the view now; closing it frees both
                // halves through the ordinary destroy/finalize path.
                pw.close();
                entry.destroy();
                diag.set("panel: out of memory", .{});
                return ShowError.OutOfMemory;
            };
            pw.on_closed = &onWindowClosed;
            pw.closed_ctx = @ptrCast(entry);
        },
    }

    next_panel_id += 1;
    return entry;
}

fn oom(diag: *Doc.Diag) ShowError {
    diag.set("panel: out of memory", .{});
    return ShowError.OutOfMemory;
}

/// The scope a panel opened from `pane` gets — the identity behind
/// `$SKETERM_SESSION`, or `null` when the pane has none. THE typed
/// answer; `sessionForPane` is its string rendering.
pub fn sessionScopeForPane(pane: ?*Pane) ?[]const u8 {
    return paneSession(pane);
}

/// `sessionScopeForPane` as a plain string, for GUI callers that both
/// display it and hand it to the store (the saved-panel picker). The
/// empty string is the store's sessionless bucket, never a session.
pub fn sessionForPane(pane: ?*Pane) []const u8 {
    return paneSession(pane) orelse NO_SESSION_WIRE;
}

/// Open the SAVED panel `name` (disk store) scoped to `pane`'s session
/// and bring it to the front — the GUI-side half of retrieval, used by
/// the command palette. Goes through `showDocument` exactly as
/// `panel-show` does, so a name that is already live is replaced in
/// place instead of being mounted twice.
pub fn openSaved(
    self: *Window,
    pane: ?*Pane,
    name: []const u8,
    target: Target,
    diag: *Doc.Diag,
) !*Entry {
    const allocator = self.allocator;
    const session = sessionScopeForPane(pane);
    const json = try panelstore.loadJson(allocator, session, name, diag);
    defer allocator.free(json);
    const entry = try showDocument(self, pane, session, name, json, target, diag);
    presentEntry(self, entry);
    return entry;
}

/// Bring a panel to the front: select its tab and raise its window, or
/// present its standalone window. Never steals focus from a panel the
/// caller is only patching (panel-patch does not call this).
fn presentEntry(self: *Window, entry: *Entry) void {
    if (entry.win) |pw| {
        pw.present();
        return;
    }
    const pane = entry.pane orelse return;
    const win = remotectl.ownerWindow(self, pane);
    pane.setPanelVisible(true);
    if (winmod.tabPageForPane(win, pane)) |page| c.adw_tab_view_set_selected_page(win.tab_view, page);
    c.gtk_window_present(@ptrCast(win.app_window));
}

fn panelPatch(
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const id = req.panel_id orelse
        return protocol.writeErr(out, allocator, "panel-patch requires panel_id");
    const patch = req.patch orelse
        return protocol.writeErr(out, allocator, "panel-patch requires patch (JSON array of ops)");
    const entry = byId(id) orelse
        return protocol.writeErr(out, allocator, "no such panel");
    var diag = Doc.Diag{};
    entry.view.applyPatch(patch, &diag) catch |err|
        return diagErr(out, allocator, &diag, err);
    try protocol.writeOkFlat(out, allocator, .{});
}

/// Read a live panel's document back, canonically serialized. The
/// registry entry is the only copy that matters, so a panel is
/// readable by any client regardless of which process showed it —
/// which is what lets `ui_save` persist what is on screen without any
/// process keeping a mirror of its own.
fn panelGet(
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const id = req.panel_id orelse
        return protocol.writeErr(out, allocator, "panel-get requires panel_id");
    const entry = byId(id) orelse
        return protocol.writeErr(out, allocator, "no such panel");
    const json = (entry.view.documentJson(allocator) catch null) orelse
        return protocol.writeErr(out, allocator, "panel has no document");
    defer allocator.free(json);
    try protocol.writeOkFlat(out, allocator, .{
        .document = json,
        .name = entry.name,
        .session = wireSession(entry.session),
        .title = entry.view.title(),
    });
}

/// Drain and answer IMMEDIATELY — this runs on the GLib main loop and
/// must never block (see the module docs).
fn panelEvents(
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const id = req.panel_id orelse
        return protocol.writeErr(out, allocator, "panel-events requires panel_id");
    const entry = byId(id) orelse
        return protocol.writeErr(out, allocator, "no such panel");

    var buf: [events.CAP]events.Event = undefined;
    const n = entry.view.queue.drainInto(&buf);
    const dropped = entry.view.queue.takeDropped();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: std.ArrayList(protocol.PanelEvent) = .empty;
    try list.ensureTotalCapacity(arena, n);
    for (buf[0..n]) |ev| {
        list.appendAssumeCapacity(.{
            .component = try arena.dupe(u8, ev.id()),
            .kind = @tagName(ev.kind),
            .value = switch (ev.value) {
                .none => .null,
                .number => |num| .{ .float = num },
                .boolean => |b| .{ .bool = b },
                .text => |txt| .{ .string = try arena.dupe(u8, txt.slice()) },
            },
            .ts = ev.ts_ms,
        });
    }
    try protocol.writeOkFlat(out, allocator, .{
        .events = list.items,
        .dropped = @as(u32, @intCast(@min(dropped, std.math.maxInt(u32)))),
    });
}

/// Which live panels a `panel-list` is asking for. `none` and a named
/// session are DIFFERENT scopes — a sessionless caller sees sessionless
/// panels, not everyone's.
const Filter = union(enum) {
    /// No session identity anywhere in the request: show everything.
    all,
    /// Explicitly sessionless (`"session":""`).
    none,
    session: []const u8,
};

fn panelList(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    // Scoping is the point: an assistant lists ITS panels. An explicit
    // session filters to that session and an explicitly EMPTY one to
    // the sessionless panels; otherwise the requesting pane's session
    // filters, and only a caller with no session identity at all — no
    // field, no pane — sees everything.
    const origin = remotectl.reqPane(self, req);
    const filter: Filter = if (req.session) |s|
        (if (s.len == 0) .none else .{ .session = s })
    else if (paneSession(origin)) |s|
        .{ .session = s }
    else
        .all;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: std.ArrayList(protocol.PanelInfo) = .empty;
    for (panels.items) |e| {
        switch (filter) {
            .all => {},
            .none => if (e.session != null) continue,
            .session => |want| if (!sameSession(e.session, want)) continue,
        }
        try list.append(arena, .{
            .panel_id = e.panel_id,
            .name = e.name,
            .session = wireSession(e.session),
            .title = e.view.title(),
            .target = e.target.name(),
        });
    }
    try protocol.writeOkFlat(out, allocator, .{ .panels = list.items });
}

fn panelClose(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const id = req.panel_id orelse
        return protocol.writeErr(out, allocator, "panel-close requires panel_id");
    const entry = byId(id) orelse
        return protocol.writeErr(out, allocator, "no such panel");
    closeEntry(self, entry);
    try protocol.writeOkFlat(out, allocator, .{});
}

/// Take a panel off the screen. Every branch reaches an unregister +
/// free of `entry` (through the face/window teardown trampolines), so
/// nothing may touch it afterwards.
fn closeEntry(self: *Window, entry: *Entry) void {
    const target = entry.target;
    const pane = entry.pane;
    if (entry.win) |pw| {
        pw.close();
    } else if (pane) |p| switch (target) {
        // The panel was put ON an existing pane: give the pane back to
        // its shell rather than closing the user's terminal.
        .pane => p.detachPanel(),
        // The panel got a tab of its own: closing the panel closes it.
        .tab => remotectl.ownerWindow(self, p).closePane(p),
        .window => unreachable,
    };
}

/// Close the panel the user means — the GUI's own close path (the
/// palette's "Close Panel"), with the same teardown as `panel-close`.
/// @return whether one was closed.
///
/// The ladder — the pane itself, then its tab, then the window when it
/// hosts exactly one panel — is not generosity: a panel face has no key
/// controller of its own, so the command palette can only be opened
/// from a pane that is NOT the panel, and "the focused pane's panel"
/// alone would be an action nobody could ever reach. Standalone panel
/// windows are excluded: they have a titlebar close button.
pub fn closeNearest(self: *Window, pane: ?*Pane) bool {
    if (pane) |p| {
        for (panels.items) |e| {
            if (e.pane == p) {
                closeEntry(self, e);
                return true;
            }
        }
        if (winmod.tabPageForPane(self, p)) |page| {
            if (Window.tabTreeOf(page)) |t| {
                for (panels.items) |e| {
                    const ep = e.pane orelse continue;
                    if (t.contains(ep)) {
                        closeEntry(self, e);
                        return true;
                    }
                }
            }
        }
    }
    var only: ?*Entry = null;
    for (panels.items) |e| {
        const ep = e.pane orelse continue;
        if (!ownsPane(self, ep)) continue;
        if (only != null) return false; // ambiguous: say nothing, do nothing
        only = e;
    }
    if (only) |e| {
        closeEntry(self, e);
        return true;
    }
    return false;
}

fn ownsPane(self: *Window, pane: *Pane) bool {
    for (self.panes.items) |p| {
        if (p == pane) return true;
    }
    return false;
}

// ─── face trampolines ───────────────────────────────────────────
//
// The registry entry IS the pane face's context, so teardown from any
// pane path (severFaces, close, tab sweep) drops the panel from the
// registry before the view is freed.

fn paneFacePrepare(ctx: *anyopaque, widgets_dead: bool) void {
    const entry: *Entry = @ptrCast(@alignCast(ctx));
    entry.view.prepareDestroy(widgets_dead);
}

fn paneFaceDestroy(ctx: *anyopaque) void {
    const entry: *Entry = @ptrCast(@alignCast(ctx));
    unregister(entry);
    entry.view.deinit();
    entry.destroy();
}

fn paneFaceFocus(ctx: *anyopaque) void {
    const entry: *Entry = @ptrCast(@alignCast(ctx));
    entry.view.focusFace();
}

/// A panel window's ::destroy. The window still owns (and later frees)
/// the view at its finalize; the entry only stops being addressable.
fn onWindowClosed(ctx: *anyopaque) void {
    const entry: *Entry = @ptrCast(@alignCast(ctx));
    unregister(entry);
    entry.destroy();
}

// ─── tests ──────────────────────────────────────────────────────

test "every panel-host decl type-checks" {
    // Lazy analysis: a signature error in a trampoline no test calls
    // would otherwise slip through `zig build test`.
    std.testing.refAllDecls(@This());
}

test "target names round-trip, and default to a tab" {
    try std.testing.expectEqual(Target.tab, Target.fromName(null).?);
    try std.testing.expectEqual(Target.tab, Target.fromName("").?);
    try std.testing.expectEqual(Target.pane, Target.fromName("pane").?);
    try std.testing.expectEqual(Target.window, Target.fromName("window").?);
    try std.testing.expectEqual(@as(?Target, null), Target.fromName("popover"));
    try std.testing.expectEqualStrings("window", Target.window.name());
}

test "a sessionless panel-show and a sessionless store operation agree on the key" {
    // `resolveSession` consults the environment, and this test may well
    // be run from inside a sketerm pane.
    _ = c.unsetenv("SKETERM_SESSION");

    // What panel-show scopes to with neither an explicit session nor a
    // pane to inherit one from...
    const scoped = scopeOf(.{ .cmd = "panel-show", .name = "p" }, null);
    try std.testing.expectEqual(@as(?[]const u8, null), scoped);
    // ...is exactly what the store resolves to for the same caller: no
    // session, expressed as an absence on both sides rather than as a
    // name the two halves could spell differently.
    try std.testing.expectEqual(@as(?[]const u8, null), panelstore.resolveSession(null));

    // An explicitly empty `session` field says the same thing, and does
    // NOT fall through to a pane's session.
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        scopeOf(.{ .cmd = "panel-show", .name = "p", .session = NO_SESSION_WIRE }, null),
    );
    try std.testing.expectEqualStrings(NO_SESSION_WIRE, wireSession(scoped));

    // And the store files it apart from every session, including one
    // named like the bucket's own directory or like the old sentinel.
    const a = std.testing.allocator;
    const none_dir = try panelstore.sessionDir(a, scoped);
    defer a.free(none_dir);
    try std.testing.expect(std.mem.endsWith(u8, none_dir, panelstore.NO_SESSION_DIR));
    for ([_][]const u8{ "_no-session", panelstore.NO_SESSION_DIR, "default" }) |name| {
        const dir = try panelstore.sessionDir(a, name);
        defer a.free(dir);
        try std.testing.expect(!std.mem.eql(u8, dir, none_dir));
    }
}

test "registry keys by (session, name)" {
    const a = std.testing.allocator;
    defer panels.deinit(a);
    var fake_view: PanelView = undefined;
    var e1 = Entry{
        .allocator = a,
        .panel_id = 1,
        .name = @constCast("train"),
        .session = @constCast("s1"),
        .target = .tab,
        .view = &fake_view,
    };
    var e2 = Entry{
        .allocator = a,
        .panel_id = 2,
        .name = @constCast("train"),
        .session = @constCast("s2"),
        .target = .window,
        .view = &fake_view,
    };
    var e3 = Entry{
        .allocator = a,
        .panel_id = 3,
        .name = @constCast("train"),
        .session = null,
        .target = .tab,
        .view = &fake_view,
    };
    try register(a, &e1);
    try register(a, &e2);
    try register(a, &e3);
    // Same name, different sessions: two distinct panels.
    try std.testing.expectEqual(@as(u32, 1), byKey("s1", "train").?.panel_id);
    try std.testing.expectEqual(@as(u32, 2), byKey("s2", "train").?.panel_id);
    try std.testing.expectEqual(@as(?*Entry, null), byKey("s3", "train"));
    try std.testing.expectEqual(@as(u32, 2), byId(2).?.panel_id);
    // Sessionless is a THIRD key, not a session named anything: no
    // session name reaches it, and it reaches no session's panel.
    try std.testing.expectEqual(@as(u32, 3), byKey(null, "train").?.panel_id);
    try std.testing.expectEqual(@as(?*Entry, null), byKey("_no-session", "train"));
    unregister(&e3);
    try std.testing.expectEqual(@as(?*Entry, null), byKey(null, "train"));
    unregister(&e1);
    try std.testing.expectEqual(@as(?*Entry, null), byKey("s1", "train"));
    try std.testing.expectEqual(@as(usize, 1), panels.items.len);
    unregister(&e2);
    try std.testing.expectEqual(@as(usize, 0), panels.items.len);
}
