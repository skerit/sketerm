//! Remote-control surface (sketerm cli / IPC): request dispatch,
//! pane/tab lookup across windows, and notification slots — split out
//! of window.zig. Every function takes the owning *Window and is
//! aliased back into Window, so call sites read identically on both
//! sides of the split.

const std = @import("std");
const c = @import("../c.zig").c;
const crashlog = @import("../util/crashlog.zig");
const clipboard = @import("clipboard.zig");
const ipc_protocol = @import("../ipc/protocol.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Pane = @import("pane.zig").Pane;
const winmod = @import("window.zig");
const muxtabs = @import("muxtabs.zig");
const Window = winmod.Window;

// ── Remote control (sketerm cli) ─────────────────────────────

/// Process-global pane-id counter (ids are global across windows).
var next_pane_id: u32 = 1;

pub fn allocPaneId(_: *Window) u32 {
    const id = next_pane_id;
    next_pane_id += 1;
    return id;
}

/// Park an interactive OSC 99 notification so its desktop
/// activation can find the pane + identifier later. Bounded:
/// the oldest slot is evicted at 32. Returns the slot token.
pub fn registerNotifySlot(self: *Window, pane: *Pane, ev: Screen.NotificationEvent) ?u32 {
    const id_copy = self.allocator.dupe(u8, ev.id) catch return null;
    if (self.notify_slots.items.len >= 32) {
        const old = self.notify_slots.orderedRemove(0);
        self.allocator.free(old.id);
    }
    const token = self.next_notify_token;
    self.next_notify_token +%= 1;
    if (self.next_notify_token == 0) self.next_notify_token = 1;
    self.notify_slots.append(self.allocator, .{
        .token = token,
        .pane = pane,
        .id = id_copy,
        .want_report = ev.want_report,
        .want_focus = ev.want_focus,
    }) catch {
        self.allocator.free(id_copy);
        return null;
    };
    return token;
}

pub fn dropNotifySlotsForPane(self: *Window, pane: *Pane) void {
    var i: usize = 0;
    while (i < self.notify_slots.items.len) {
        if (self.notify_slots.items[i].pane == pane) {
            const slot = self.notify_slots.orderedRemove(i);
            self.allocator.free(slot.id);
        } else {
            i += 1;
        }
    }
}

pub fn tabPageId(page: *c.AdwTabPage) u32 {
    return @intCast(@intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-tab-id")));
}

/// Resolve a pane address: explicit id, else the focused pane,
/// else the selected tab's first pane, else the first pane.
pub fn paneById(self: *Window, id_opt: ?u32) ?*Pane {
    if (id_opt) |id| {
        for (self.panes.items) |p| if (p.id == id) return p;
        return null;
    }
    if (self.focusedPane()) |p| return p;
    const sel = c.adw_tab_view_get_selected_page(self.tab_view);
    if (sel != null) {
        if (c.adw_tab_page_get_child(sel)) |child| {
            for (self.panes.items) |p| {
                if (winmod.widgetIsAncestor(@ptrCast(child), p.widget())) return p;
            }
        }
    }
    if (self.panes.items.len > 0) return self.panes.items[0];
    return null;
}

pub const WINDOW_QDATA = "sketerm-window";

/// The Zig Window behind a GtkWindow (set as qdata at init), or null
/// for a window we don't own.
pub fn windowFromGtk(gw: ?*c.GtkWindow) ?*Window {
    const g = gw orelse return null;
    const d = c.g_object_get_data(@ptrCast(@alignCast(g)), WINDOW_QDATA) orelse return null;
    return @ptrCast(@alignCast(d));
}

/// Every live Window of `app`, in GTK's own order. Caller frees.
/// GTK's window list mutates while windows are torn down, so any
/// caller that DESTROYS windows must iterate this copy.
///
/// This plus `windowForPane` is the window registry: there is no
/// separate list to keep in sync, because the GtkWindow already
/// carries its Zig Window as qdata.
pub fn liveWindows(allocator: std.mem.Allocator, app: ?*c.GtkApplication) ![]*Window {
    var out: std.ArrayList(*Window) = .empty;
    errdefer out.deinit(allocator);
    const a = app orelse return out.toOwnedSlice(allocator);
    var node = c.gtk_application_get_windows(a);
    while (node != null) : (node = node.*.next) {
        const gw: ?*c.GtkWindow = @ptrCast(@alignCast(node.*.data));
        if (windowFromGtk(gw)) |w| try out.append(allocator, w);
    }
    return out.toOwnedSlice(allocator);
}

/// The pane with id `pane_id` and the Window that owns it, across
/// every window of `app`. Pane ids are process-global, so the answer
/// is unambiguous. This is how `sketerm files --here` finds the pane
/// it was typed in.
pub fn windowForPane(app: ?*c.GtkApplication, pane_id: u32) ?PaneRef {
    const a = app orelse return null;
    var node = c.gtk_application_get_windows(a);
    while (node != null) : (node = node.*.next) {
        const gw: ?*c.GtkWindow = @ptrCast(@alignCast(node.*.data));
        const w = windowFromGtk(gw) orelse continue;
        for (w.panes.items) |p| if (p.id == pane_id) return .{ .win = w, .pane = p };
    }
    return null;
}

pub const PaneRef = struct { win: *Window, pane: *Pane };

/// The window a request that names no pane acts on: the one the user
/// is actually looking at, else `self` (the socket owner).
pub fn activeOrSelf(self: *Window) *Window {
    const app = c.gtk_window_get_application(@ptrCast(self.app_window)) orelse return self;
    const aw = c.gtk_application_get_active_window(app) orelse return self;
    return windowFromGtk(@ptrCast(aw)) orelse self;
}

/// Detach every GTK signal handler carrying this Window as user
/// data. Only safe while the GtkWindow is alive (app shutdown, where
/// GTK destroys windows AFTER our handler runs): without it the
/// destroy that follows would call onWindowDestroyed on freed state.
pub fn detachWindowSignals(self: *Window) void {
    // g_signal_handlers_disconnect_by_data is a macro the C-import
    // cannot type (its NULL closure argument); this is its body.
    _ = c.g_signal_handlers_disconnect_matched(
        @as(c.gpointer, @ptrCast(@alignCast(self.app_window))),
        c.G_SIGNAL_MATCH_DATA,
        0,
        0,
        null,
        null,
        @as(c.gpointer, @ptrCast(self)),
    );
}

/// Run `f(win)` for every Window in this application until it returns
/// a pane; the first non-null wins. The IPC server lives on the
/// primary window, but panes can sit in secondary windows (tab
/// drag-out), so pane resolution MUST span them all.
pub fn findPaneAcrossWindows(self: *Window, ctx: anytype, f: *const fn (@TypeOf(ctx), *Window) ?*Pane) ?*Pane {
    const app = c.gtk_window_get_application(@ptrCast(self.app_window)) orelse return f(ctx, self);
    var node = c.gtk_application_get_windows(app);
    while (node != null) : (node = node.*.next) {
        const gw: ?*c.GtkWindow = @ptrCast(@alignCast(node.*.data));
        if (windowFromGtk(gw)) |w| {
            if (f(ctx, w)) |p| return p;
        }
    }
    return null;
}

/// The pane rendering daemon session `name` — the stable identity
/// behind `$SKETERM_SESSION`. Searched across all windows.
pub fn paneBySession(self: *Window, name: []const u8) ?*Pane {
    if (name.len == 0) return null;
    return self.findPaneAcrossWindows(name, struct {
        fn f(n: []const u8, w: *Window) ?*Pane {
            for (w.panes.items) |p| {
                const r = p.terminal.remote orelse continue;
                if (std.mem.eql(u8, r.session, n)) return p;
            }
            return null;
        }
    }.f);
}

/// The pane with `id`, across all windows.
pub fn paneByIdGlobal(self: *Window, id: u32) ?*Pane {
    return self.findPaneAcrossWindows(id, struct {
        fn f(want: u32, w: *Window) ?*Pane {
            for (w.panes.items) |p| if (p.id == want) return p;
            return null;
        }
    }.f);
}

// ── UDP connection-ticket brokering ──────────────────────────
//
// A live UDP terminal connection can ask its daemon to mint a
// single-use sibling listener (wire `udp_ticket_req`/`udp_ticket`),
// so a NEW process — the spawned files app, a browser pane's host
// connection — reaches the same daemon over UDP with no ssh
// bootstrap of its own. This is the GUI-side broker: find an
// eligible connection, request asynchronously, resolve the caller
// exactly once (ticket, refusal, transport loss, or timeout).

const mux_client = @import("../mux/client.zig");
const term_mod = @import("../terminal.zig");

pub const UdpTicketFn = *const fn (ctx: ?*anyopaque, ticket: ?mux_client.UdpTicket) void;

const TicketWait = struct {
    allocator: std.mem.Allocator,
    ctx: ?*anyopaque,
    cb: UdpTicketFn,
    /// Liveness fence for the terminal holding our pending slot: the
    /// timeout must clear that slot through it, never through a
    /// possibly-freed Terminal pointer.
    drain: *term_mod.DrainHandle,
    timeout_id: c_uint = 0,
};

/// A live, ticket-capable UDP connection to `bare_host` (no
/// udp:/ssh: prefix), across every window.
fn findUdpTicketTerminal(self: *Window, bare_host: []const u8) ?*term_mod.Terminal {
    const pane = self.findPaneAcrossWindows(bare_host, struct {
        fn f(host: []const u8, w: *Window) ?*Pane {
            for (w.panes.items) |p| {
                const r = p.terminal.remote orelse continue;
                if (!r.canSend() or r.destroying) continue;
                if (r.conn.transport != .udp or !r.conn.udp_tickets) continue;
                if (r.pending_ticket_cb != null) continue;
                const h = r.host orelse continue;
                if (std.mem.eql(u8, mux_client.RemoteSpec.parse(h).host, host)) return p;
            }
            return null;
        }
    }.f) orelse return null;
    return pane.terminal;
}

/// Whether `mintUdpTicket` for `bare_host` could find a connection to
/// broker over right now. Lets callers skip heap setup entirely.
pub fn canMintUdpTicket(self: *Window, bare_host: []const u8) bool {
    if (bare_host.len == 0) return false;
    return findUdpTicketTerminal(self, bare_host) != null;
}

/// Mint a UDP connection ticket for `bare_host` over any live UDP
/// terminal connection in this application. Returns false — the
/// callback never fires — when no eligible connection exists; on true
/// the callback fires exactly once on the main loop: the ticket, or
/// null on refusal, transport loss, or the 3s timeout.
pub fn mintUdpTicket(self: *Window, bare_host: []const u8, ctx: ?*anyopaque, cb: UdpTicketFn) bool {
    if (bare_host.len == 0) return false;
    const term = findUdpTicketTerminal(self, bare_host) orelse return false;
    const wait = self.allocator.create(TicketWait) catch return false;
    wait.* = .{ .allocator = self.allocator, .ctx = ctx, .cb = cb, .drain = term.drain };
    // Timeout armed BEFORE the request: a write failure inside
    // requestUdpTicket resolves the slot synchronously (transportLost
    // → callback → wait freed), so `wait` must already be complete.
    wait.timeout_id = c.g_timeout_add(3_000, @ptrCast(&onTicketTimeout), @ptrCast(wait));
    if (!term.requestUdpTicket(@ptrCast(wait), onTicketResolved)) {
        _ = c.g_source_remove(wait.timeout_id);
        self.allocator.destroy(wait);
        return false;
    }
    return true;
}

/// Exactly-once resolution from the Terminal's pending slot (frame,
/// refusal, transport loss, teardown fence).
fn onTicketResolved(ctx: ?*anyopaque, ticket: ?mux_client.UdpTicket) void {
    const wait: *TicketWait = @ptrCast(@alignCast(ctx.?));
    if (wait.timeout_id != 0) _ = c.g_source_remove(wait.timeout_id);
    const cb = wait.cb;
    const uctx = wait.ctx;
    const allocator = wait.allocator;
    allocator.destroy(wait);
    cb(uctx, ticket);
}

fn onTicketTimeout(user: ?*anyopaque) callconv(.c) c.gboolean {
    const wait: *TicketWait = @ptrCast(@alignCast(user.?));
    wait.timeout_id = 0;
    // Empty the pending slot so a late frame cannot fire into the
    // memory freed below; the DrainHandle fences terminal teardown.
    if (wait.drain.alive.load(.acquire)) {
        if (wait.drain.terminal) |t| t.cancelUdpTicket(@ptrCast(wait));
    }
    const cb = wait.cb;
    const uctx = wait.ctx;
    const allocator = wait.allocator;
    allocator.destroy(wait);
    cb(uctx, null);
    return 0; // G_SOURCE_REMOVE
}

/// The pane that currently has keyboard focus anywhere — the active
/// window's focused pane, else any focused pane, else the first pane
/// in any window. The guaranteed floor for "the pane I'm in": as long
/// as a single pane exists, this returns one.
pub fn globallyFocusedPane(self: *Window) ?*Pane {
    const app = c.gtk_window_get_application(@ptrCast(self.app_window));
    if (app != null) {
        if (c.gtk_application_get_active_window(app)) |aw| {
            if (windowFromGtk(@ptrCast(aw))) |w| if (w.focusedPane()) |p| return p;
        }
        if (self.findPaneAcrossWindows({}, struct {
            fn f(_: void, w: *Window) ?*Pane {
                return w.focusedPane();
            }
        }.f)) |p| return p;
        if (self.findPaneAcrossWindows({}, struct {
            fn f(_: void, w: *Window) ?*Pane {
                return if (w.panes.items.len > 0) w.panes.items[0] else null;
            }
        }.f)) |p| return p;
    }
    return self.paneById(null);
}

/// Resolve a request's target pane for an EXPLICIT command (send-text,
/// split, …): stable session name first, then the pane id, both across
/// all windows. No current-pane fallback — an explicit bad id should
/// error, not silently hit some other pane. Use `takeoverPane` for the
/// "the pane I'm in" commands.
pub fn reqPane(self: *Window, req: ipc_protocol.Request) ?*Pane {
    if (req.session) |s| {
        if (self.paneBySession(s)) |p| return p;
    }
    if (req.pane) |id| return paneByIdGlobal(self, id);
    // No address at all = the focused pane (default for omitted --pane).
    return globallyFocusedPane(self);
}

/// Pane resolution for commands that must act on the named pane or
/// nothing: an address that does not resolve is an error, where
/// `reqPane` would quietly fall back to the focused pane. Turning
/// a pane the caller never named into a file browser is exactly the
/// bug `sketerm files --here` exists to avoid, and a $SKETERM_SESSION
/// from ANOTHER sketerm instance makes that a real case.
pub fn reqPaneExact(self: *Window, req: ipc_protocol.Request) ?*Pane {
    if (req.session) |s| {
        if (self.paneBySession(s)) |p| return p;
    }
    if (req.pane) |id| return paneByIdGlobal(self, id);
    return null;
}

/// Resolve the pane for a "take over the pane I'm in" command
/// (`sketerm mux` attach / new-durable). This MUST NOT fail when run
/// from inside a pane: session name -> pane id -> the globally-focused
/// pane. Returns null only when no pane exists anywhere (then the
/// caller opens a fresh tab, which is correct).
pub fn takeoverPane(self: *Window, req: ipc_protocol.Request) ?*Pane {
    if (req.session) |s| {
        if (self.paneBySession(s)) |p| return p;
    }
    if (req.pane) |id| {
        if (paneByIdGlobal(self, id)) |p| return p;
    }
    return globallyFocusedPane(self);
}

/// The Window that owns `pane` (set as `win_clip_ctx` when the pane is
/// listed). Falls back to `self` if somehow unset.
pub fn ownerWindow(self: *Window, pane: *Pane) *Window {
    if (pane.win_clip_ctx) |w| return @ptrCast(@alignCast(w));
    return self;
}

pub fn tabPageById(self: *Window, id_opt: ?u32) ?*c.AdwTabPage {
    if (id_opt) |id| {
        const n = c.adw_tab_view_get_n_pages(self.tab_view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
            if (tabPageId(page) == id) return page;
        }
        return null;
    }
    return c.adw_tab_view_get_selected_page(self.tab_view);
}

pub const TabRef = struct { win: *Window, page: *c.AdwTabPage };

/// A tab by id across EVERY window (tab ids are process-global), or
/// the selected tab of the default window when `id_opt` is null.
/// Acting on a page through the wrong window's AdwTabView is a GTK
/// critical, so the owning window travels with the page.
pub fn tabRefById(self: *Window, id_opt: ?u32) ?TabRef {
    const id = id_opt orelse {
        const win = activeOrSelf(self);
        const page = c.adw_tab_view_get_selected_page(win.tab_view) orelse return null;
        return .{ .win = win, .page = page };
    };
    const app = c.gtk_window_get_application(@ptrCast(self.app_window));
    if (app == null) {
        const page = tabPageById(self, id) orelse return null;
        return .{ .win = self, .page = page };
    }
    var node = c.gtk_application_get_windows(app);
    while (node != null) : (node = node.*.next) {
        const gw: ?*c.GtkWindow = @ptrCast(@alignCast(node.*.data));
        const w = windowFromGtk(gw) orelse continue;
        if (tabPageById(w, id)) |page| return .{ .win = w, .page = page };
    }
    return null;
}

pub fn ipcDispatchTrampoline(ctx: *anyopaque, req: ipc_protocol.Request, out: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    // Post-mortem breadcrumb: a crash while servicing a remote-control
    // command is otherwise invisible (the process just vanishes and only
    // the far-side daemon logs its clients going away).
    crashlog.set("ipc {s} data={s} host={s} pane={?d} session={s}", .{
        req.cmd,
        req.data orelse "-",
        req.host orelse "-",
        req.pane,
        req.session orelse "-",
    });
    defer crashlog.clear();
    ipcDispatch(self, req, out, allocator) catch |err| {
        // Name the error. A bare "internal error" tells the caller
        // nothing about WHICH way a command went wrong, and this is the
        // reply every scripted client and smoke rig sees when a handler
        // fails — the breadcrumb above is only written on a crash.
        out.clearRetainingCapacity();
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "internal error: {s}", .{@errorName(err)}) catch "internal error";
        ipc_protocol.writeErr(out, allocator, msg) catch {};
    };
}

/// WINDOW RESOLUTION RULE for every command below. `self` is the
/// window that owns the socket (the primary), which is NOT always
/// the window a request means:
///
///   - names a pane (--pane / --session, `--pane self` included):
///     acts on THAT pane's own window, via `ownerWindow`.
///   - names only a tab: the tab is looked up across every window
///     (`tabRefById`) and acted on in the window holding it.
///   - names neither (new-tab, new-browser-tab, attach-all, bare
///     action): the ACTIVE window, else the socket owner
///     (`activeOrSelf`): "the window I am looking at".
///   - `list` reports every window, each tab tagged with its
///     window id.
pub fn ipcDispatch(self: *Window, req: ipc_protocol.Request, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const eql = std.mem.eql;
    if (eql(u8, req.cmd, "list")) {
        try ipcList(self, out, allocator);
    } else if (eql(u8, req.cmd, "send-text")) {
        const data = req.data orelse return ipc_protocol.writeErr(out, allocator, "send-text requires data");
        const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        // An editor-visible pane receives text into its document (at
        // every caret), not into the hidden shell underneath.
        if (pane.editorFaceVisible()) {
            if (@import("editorview.zig").EditorView.fromPane(pane)) |ev| {
                if (!ev.ipcInsertText(data))
                    return ipc_protocol.writeErr(out, allocator, "editor has no open document");
                return ipc_protocol.writeOk(out, allocator, null, {});
            }
        }
        if (req.paste)
            clipboard.pasteText(pane.terminal, data)
        else
            pane.terminal.writeUserInput(data);
        try ipc_protocol.writeOk(out, allocator, null, {});
    } else if (eql(u8, req.cmd, "send-keys")) {
        const data = req.data orelse return ipc_protocol.writeErr(out, allocator, "send-keys requires data (chords like \"ctrl+c up enter\")");
        const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        // Editor-visible pane: a small editor chord set (enter, tab,
        // backspace, delete, escape, ctrl+s, ctrl+z, ctrl+y) instead
        // of PTY byte encoding.
        if (pane.editorFaceVisible()) {
            if (@import("editorview.zig").EditorView.fromPane(pane)) |ev| {
                if (!ev.ipcSendKeys(data))
                    return ipc_protocol.writeErr(out, allocator, "unsupported editor chord (supported: enter tab backspace delete escape ctrl+s ctrl+z ctrl+y)");
                return ipc_protocol.writeOk(out, allocator, null, {});
            }
        }
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        @import("../ipc/keys.zig").encode(&bytes, allocator, data, pane.terminal.screen.app_cursor_keys) catch |err| switch (err) {
            error.UnknownKey => return ipc_protocol.writeErr(out, allocator, "unknown key chord"),
            error.OutOfMemory => return err,
        };
        pane.terminal.writeUserInput(bytes.items);
        try ipc_protocol.writeOk(out, allocator, null, {});
    } else if (eql(u8, req.cmd, "screen-info")) {
        const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        const scr = pane.terminal.screen;
        try ipc_protocol.writeOk(out, allocator, "screen", .{
            .rows = scr.rows,
            .cols = scr.cols,
            .cursor_row = scr.row,
            .cursor_col = scr.col,
            .alt_screen = scr.use_alt,
            .view_offset = scr.view_offset,
            .app_cursor_keys = scr.app_cursor_keys,
            .sync_output = scr.sync_output,
            .title = scr.last_title orelse "",
            .seq = pane.terminal.activity_seq,
        });
    } else if (eql(u8, req.cmd, "im-probe")) {
        // Debug hook: push hardware keycodes (GDK code = evdev + 8,
        // comma-separated in `data`) through the FOCUSED face's IM
        // context exactly the way GtkEventControllerKey does, and
        // report what it committed. This is the repeatable form of
        // "does this face still compose dead keys?" — the answer
        // differs per face and per compositor, and it is invisible to
        // send-text/send-keys, which bypass the IM entirely.
        const data = req.data orelse return ipc_protocol.writeErr(out, allocator, "im-probe requires data (comma-separated hardware keycodes)");
        const im = @import("imhost.zig").focusedHost(null) orelse
            return ipc_protocol.writeErr(out, allocator, "no focused face with an IM context");
        im.probeReset();
        var consumed_all = true;
        var it = std.mem.splitScalar(u8, data, ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len == 0) continue;
            const hw = std.fmt.parseInt(u32, t, 10) catch
                return ipc_protocol.writeErr(out, allocator, "im-probe keycodes must be decimal");
            if (!im.probeFeed(hw)) consumed_all = false;
        }
        try ipc_protocol.writeOk(out, allocator, "im", .{
            .face = @tagName(im.face),
            .strategy = @tagName(im.strategy),
            .committed = im.probeText(),
            .all_consumed = consumed_all,
        });
        im.probeReset();
    } else if (eql(u8, req.cmd, "screenshot")) {
        const path = req.data orelse return ipc_protocol.writeErr(out, allocator, "screenshot requires data (output .png path)");
        const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        // A pane showing a web page must be photographed as the PAGE:
        // the terminal surface underneath it is the hidden shell.
        const bytes = blk: {
            if (pane.webFaceVisible()) {
                if (@import("webface.zig").WebFace.fromPane(pane)) |wf| {
                    if (wf.screenshotPng()) |png| break :blk png;
                }
            }
            break :blk pane.screenshotPng() orelse
                return ipc_protocol.writeErr(out, allocator, "screenshot failed (pane not mapped/realized yet)");
        };
        defer c.g_bytes_unref(bytes);
        var sz: c.gsize = 0;
        const ptr = c.g_bytes_get_data(bytes, &sz);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const f = c.fopen(path_z.ptr, "wb") orelse
            return ipc_protocol.writeErr(out, allocator, "cannot open output path for writing");
        const wrote = c.fwrite(ptr, 1, sz, f);
        _ = c.fclose(f);
        if (wrote != sz) return ipc_protocol.writeErr(out, allocator, "short write to output path");
        try ipc_protocol.writeOk(out, allocator, "screenshot", .{ .path = path, .bytes = @as(u64, sz) });
    } else if (eql(u8, req.cmd, "record-start")) {
        // The daemon writes the file (on ITS host); the OK here
        // acknowledges the request, not the daemon's ack.
        const path = req.data orelse return ipc_protocol.writeErr(out, allocator, "record-start requires data (output .cast path)");
        if (path.len == 0 or path[0] != '/') return ipc_protocol.writeErr(out, allocator, "record-start path must be absolute");
        const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        if (pane.terminal.remote == null) return ipc_protocol.writeErr(out, allocator, "pane has no daemon session");
        pane.terminal.requestRecordStart(path);
        try ipc_protocol.writeOk(out, allocator, "record", .{ .path = path, .recording = true });
    } else if (eql(u8, req.cmd, "record-stop")) {
        const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        if (pane.terminal.remote == null) return ipc_protocol.writeErr(out, allocator, "pane has no daemon session");
        pane.terminal.requestRecordStop();
        try ipc_protocol.writeOk(out, allocator, "record", .{ .recording = false });
    } else if (eql(u8, req.cmd, "get-text")) {
        const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        // An editor-visible pane answers with its DOCUMENT: the shell
        // grid underneath is not what the caller is looking at.
        if (pane.editorFaceVisible()) {
            if (@import("editorview.zig").EditorView.fromPane(pane)) |ev| {
                const doc_text = ev.ipcGetText(allocator) orelse
                    return ipc_protocol.writeErr(out, allocator, "editor has no open document");
                defer allocator.free(doc_text);
                return ipc_protocol.writeOk(out, allocator, "text", doc_text);
            }
        }
        const screen = pane.terminal.screen;
        if (req.last_command) {
            // A completed zone with no output (e.g. `true`) is
            // still an answer — its exit code matters.
            if (screen.last_output_start_id == 0 or screen.last_output_end_id == 0)
                return ipc_protocol.writeErr(out, allocator, "no completed command zone (shell integration not active?)");
            const text = (try screen.extractLastCommandOutput(allocator)) orelse
                try allocator.dupe(u8, "");
            defer allocator.free(text);
            try ipc_protocol.writeOk(out, allocator, "last", .{
                .text = text,
                .exit = screen.last_cmd_exit,
            });
            return;
        }
        const text = if (req.scrollback > 0)
            try screen.extractScrollback(allocator)
        else
            try screen.extractScreen(allocator);
        defer allocator.free(text);
        try ipc_protocol.writeOk(out, allocator, "text", text);
    } else if (eql(u8, req.cmd, "new-tab")) {
        const target = activeOrSelf(self);
        var title_buf: [256:0]u8 = undefined;
        const title_z: ?[*:0]const u8 = if (req.title) |t| blk: {
            const s = std.fmt.bufPrintZ(&title_buf, "{s}", .{t}) catch break :blk null;
            break :blk s.ptr;
        } else null;
        if (req.cwd) |cwd| {
            var num_buf: [32]u8 = undefined;
            const t: [*:0]const u8 = title_z orelse tdef: {
                target.tab_counter += 1;
                const s = std.fmt.bufPrintZ(&num_buf, "Tab {d}", .{target.tab_counter}) catch "shell";
                break :tdef s.ptr;
            };
            try target.addTabWithProfile(t, cwd, null);
        } else {
            try target.newShellTab(title_z);
        }
        try ipc_protocol.writeOk(out, allocator, "created", .{
            .tab = winmod.next_tab_id - 1,
            .pane = next_pane_id - 1,
        });
    } else if (eql(u8, req.cmd, "new-browser-tab")) {
        // A pane address means "a browser tab next to THIS pane"
        // (`sketerm files --tab`): the tab lands in that pane's own
        // window and starts at its host-qualified location. No
        // address = the window in front, like new-tab.
        const origin: ?*Pane = if (req.pane != null or req.session != null)
            reqPaneExact(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane")
        else
            null;
        const target = if (origin) |p| ownerWindow(self, p) else activeOrSelf(self);
        try target.newBrowserTabFrom(origin orelse target.focusedPane(), req.data);
        // Asked for from inside a pane (`sketerm files --tab`): show
        // what was asked for. Scripted use (no address) keeps the
        // non-stealing behaviour of new-tab.
        if (origin != null) {
            if (target.last_created_page) |page| c.adw_tab_view_set_selected_page(target.tab_view, page);
            c.gtk_window_present(@ptrCast(target.app_window));
        }
        try ipc_protocol.writeOk(out, allocator, "created", .{
            .tab = winmod.next_tab_id - 1,
            .pane = next_pane_id - 1,
        });
    } else if (eql(u8, req.cmd, "new-editor-tab")) {
        // Same addressing as new-browser-tab: a pane address means "an
        // editor tab in THAT pane's window"; no address = the window
        // in front. `data` is an optional file spec to open.
        const origin: ?*Pane = if (req.pane != null or req.session != null)
            reqPaneExact(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane")
        else
            null;
        const target = if (origin) |p| ownerWindow(self, p) else activeOrSelf(self);
        try target.newEditorTabAt(req.data);
        if (origin != null) {
            if (target.last_created_page) |page| c.adw_tab_view_set_selected_page(target.tab_view, page);
            c.gtk_window_present(@ptrCast(target.app_window));
        }
        try ipc_protocol.writeOk(out, allocator, "created", .{
            .tab = winmod.next_tab_id - 1,
            .pane = next_pane_id - 1,
        });
    } else if (eql(u8, req.cmd, "editor-here")) {
        // `sketerm edit --here`: the addressed pane itself wears the
        // editor face (its shell stays one toolbar click away). Same
        // explicit-address rule as browser-here — converting some other
        // pane is exactly the surprise this guards against. A pane
        // already wearing the face gains a document tab.
        if (req.pane == null and req.session == null)
            return ipc_protocol.writeErr(out, allocator, "editor-here requires a pane (--pane N or a session name)");
        const pane = reqPaneExact(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        const win = ownerWindow(self, pane);
        win.openEditorOn(pane, req.data) catch |err| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "editor attach failed: {s}", .{@errorName(err)}) catch "editor attach failed";
            return ipc_protocol.writeErr(out, allocator, msg);
        };
        if (winmod.tabPageForPane(win, pane)) |page| c.adw_tab_view_set_selected_page(win.tab_view, page);
        c.gtk_window_present(@ptrCast(win.app_window));
        try ipc_protocol.writeOk(out, allocator, "pane", pane.id);
    } else if (eql(u8, req.cmd, "browser-here")) {
        // `sketerm files --here`: the addressed pane itself wears the
        // browser face, in its own window. Explicit address only:
        // silently converting some other pane is the bug this
        // command exists to avoid.
        if (req.pane == null and req.session == null)
            return ipc_protocol.writeErr(out, allocator, "browser-here requires a pane (--pane N or a session name)");
        const pane = reqPaneExact(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        const win = ownerWindow(self, pane);
        win.openBrowserHere(pane, req.data) catch |err| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "browser attach failed: {s}", .{@errorName(err)}) catch "browser attach failed";
            return ipc_protocol.writeErr(out, allocator, msg);
        };
        if (winmod.tabPageForPane(win, pane)) |page| c.adw_tab_view_set_selected_page(win.tab_view, page);
        c.gtk_window_present(@ptrCast(win.app_window));
        try ipc_protocol.writeOk(out, allocator, "pane", pane.id);
    } else if (eql(u8, req.cmd, "split")) {
        const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        const win = ownerWindow(self, pane);
        const dir = req.direction orelse "h";
        const orient: c_uint = if (eql(u8, dir, "v"))
            @intCast(c.GTK_ORIENTATION_VERTICAL)
        else
            @intCast(c.GTK_ORIENTATION_HORIZONTAL);
        // Split the pane that was ASKED for. This used to grab focus and
        // then split "the focused pane", which only agreed with the
        // request while that pane's tab happened to be selected —
        // anything that selects another tab first (an app session
        // materializing its log tab, say) made this split the wrong pane
        // or silently nothing.
        try win.splitPane(pane, orient);
        try ipc_protocol.writeOk(out, allocator, "created", .{
            .pane = next_pane_id - 1,
        });
    } else if (eql(u8, req.cmd, "focus")) {
        if (req.pane != null or req.session != null) {
            const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
            const win = ownerWindow(self, pane);
            if (winmod.tabPageForPane(win, pane)) |page| c.adw_tab_view_set_selected_page(win.tab_view, page);
            c.gtk_window_present(@ptrCast(win.app_window));
            // Focusing an editor-visible pane must land on the document
            // canvas, not on the hidden shell's GLArea.
            if (pane.editorFaceVisible()) {
                if (@import("editorview.zig").EditorView.fromPane(pane)) |ev| {
                    ev.focusFace();
                } else _ = c.gtk_widget_grab_focus(@ptrCast(pane.surface.area));
            } else _ = c.gtk_widget_grab_focus(@ptrCast(pane.surface.area));
            try ipc_protocol.writeOk(out, allocator, null, {});
        } else if (req.tab != null) {
            const ref = tabRefById(self, req.tab) orelse return ipc_protocol.writeErr(out, allocator, "no such tab");
            c.adw_tab_view_set_selected_page(ref.win.tab_view, ref.page);
            c.gtk_window_present(@ptrCast(ref.win.app_window));
            try ipc_protocol.writeOk(out, allocator, null, {});
        } else {
            try ipc_protocol.writeErr(out, allocator, "focus requires pane or tab");
        }
    } else if (eql(u8, req.cmd, "close-pane")) {
        const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
        ownerWindow(self, pane).closePane(pane);
        try ipc_protocol.writeOk(out, allocator, null, {});
    } else if (eql(u8, req.cmd, "set-title")) {
        const text = req.title orelse req.data orelse return ipc_protocol.writeErr(out, allocator, "set-title requires title");
        var z_buf: [512:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&z_buf, "{s}", .{text}) catch return ipc_protocol.writeErr(out, allocator, "title too long");
        const page = if (req.pane != null or req.session != null) pg: {
            const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
            break :pg winmod.tabPageForPane(ownerWindow(self, pane), pane) orelse return ipc_protocol.writeErr(out, allocator, "pane has no tab");
        } else (tabRefById(self, req.tab) orelse return ipc_protocol.writeErr(out, allocator, "no such tab")).page;
        c.adw_tab_page_set_title(page, z.ptr);
        c.adw_tab_page_set_tooltip(page, z.ptr);
        try ipc_protocol.writeOk(out, allocator, null, {});
    } else if (eql(u8, req.cmd, "new-durable-tab")) {
        // Invoked from inside a pane (it carried a self-identity) =
        // take THAT pane over, tmux-style. takeoverPane never fails to
        // find a pane when one exists (session name -> pane id ->
        // globally-focused), so this can't silently spill into a new
        // tab/window. Run it in the pane's OWN window. No identity at
        // all (run from outside any pane) = open a fresh tab here.
        const takeover: ?*Pane = if (req.session != null or req.pane != null)
            takeoverPane(self, req)
        else
            null;
        const win = if (takeover) |p| ownerWindow(self, p) else self;
        win.newDurableSession(req.host, takeover) catch {
            return ipc_protocol.writeErr(out, allocator, "durable spawn failed (ssh/key auth?)");
        };
        try ipc_protocol.writeOk(out, allocator, "pane", next_pane_id - 1);
    } else if (eql(u8, req.cmd, "attach-session")) {
        const name = req.data orelse return ipc_protocol.writeErr(out, allocator, "attach-session requires data (session name)");
        // Take over the pane it ran in (never fails to a new tab when a
        // pane exists), in that pane's own window. See new-durable-tab.
        const takeover: ?*Pane = if (req.session != null or req.pane != null)
            takeoverPane(self, req)
        else
            null;
        const win = if (takeover) |p| ownerWindow(self, p) else self;
        const conn = muxtabs.muxConnect(win, req.host) catch {
            return ipc_protocol.writeErr(out, allocator, "mux daemon unreachable");
        };
        const lease: Window.Lease = if (req.read_only) .read_only else if (req.control) .control else .default;
        muxtabs.attachMuxLease(win, conn, name, req.host, takeover, null, lease) catch |err| {
            // Prefer the daemon's own reason ("no such session", …)
            // over the bare error name.
            const detail = if (win.mux_attach_err_len > 0)
                win.mux_attach_err[0..win.mux_attach_err_len]
            else
                @errorName(err);
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "attach failed: {s}", .{detail}) catch "attach failed";
            return ipc_protocol.writeErr(out, allocator, msg);
        };
        try ipc_protocol.writeOk(out, allocator, null, {});
    } else if (eql(u8, req.cmd, "attach-all")) {
        // Bulk handoff: attach every session on the daemon that
        // this window isn't already showing.
        const n = activeOrSelf(self).attachAllSessions(req.host);
        try ipc_protocol.writeOk(out, allocator, "attached", n);
    } else if (eql(u8, req.cmd, "set-tab-color")) {
        const ref = tabRefById(self, req.tab) orelse return ipc_protocol.writeErr(out, allocator, "no such tab");
        const page = ref.page;
        const spec = req.data orelse return ipc_protocol.writeErr(out, allocator, "set-tab-color requires data (#RRGGBB or none)");
        if (eql(u8, spec, "none")) {
            ref.win.setTabColor(page, null);
        } else if (Window.parseHexRGB(spec)) |col| {
            ref.win.setTabColor(page, col);
        } else {
            return ipc_protocol.writeErr(out, allocator, "bad color (want #RRGGBB or none)");
        }
        try ipc_protocol.writeOk(out, allocator, null, {});
    } else if (std.mem.startsWith(u8, req.cmd, "panel-")) {
        // Declarative UI panels (src/ui/panel): show / patch / get /
        // events / list / close. Kept in ui/panelhost.zig — the
        // registry, the (session, name) scoping and the three host
        // shapes are a subsystem of their own, not six more branches
        // here.
        try @import("panelhost.zig").dispatch(self, req, out, allocator);
    } else if (eql(u8, req.cmd, "action")) {
        // Dispatch any bindable action by name — the scripting
        // equivalent of pressing its keybind ("zoom_pane",
        // "copy_mode", "split_h", …; names as in `keybind.*`).
        const name = req.data orelse return ipc_protocol.writeErr(out, allocator, "action needs data=<name>");
        const action = @import("input.zig").actionFromName(name) orelse
            return ipc_protocol.writeErr(out, allocator, "unknown action");
        var target: *Window = activeOrSelf(self);
        if (req.pane != null or req.session != null) {
            const pane = reqPane(self, req) orelse return ipc_protocol.writeErr(out, allocator, "no such pane");
            target = ownerWindow(self, pane);
            _ = c.gtk_widget_grab_focus(@ptrCast(pane.surface.area));
        }
        winmod.dispatchAction(target, action);
        try ipc_protocol.writeOk(out, allocator, null, {});
    } else if (std.mem.startsWith(u8, req.cmd, "web-")) {
        try webCmd(self, req, out, allocator);
    } else {
        try ipc_protocol.writeErr(out, allocator, "unknown command");
    }
}

// ── web-* : the browser views the `web_*` MCP tools drive ──────────
//
// The semantic layer is a round trip to the helper and back, so these
// commands NEVER wait: `web-request` starts one and answers with a
// token, `web-result` reports whether it landed. The GLib main loop
// keeps running between the two, which is the only way a reply can
// arrive at all.

const webface = @import("webface.zig");
const web_proto = @import("../web/protocol.zig");

/// One web view, as `web-list` reports it. The handle is the PANE id,
/// so it addresses the same thing `list` does.
const WebViewInfo = struct {
    pane: u32,
    view: u32,
    url: []const u8,
    title: []const u8,
    loading: bool,
    can_back: bool,
    can_fwd: bool,
    focused: bool,
    visible: bool,
    /// Finished main-frame loads on this view. A caller settling a
    /// navigation needs it: `loading:false` is also true in the gap
    /// between asking for a page and the engine starting it.
    load_seq: u32,
};

fn webFaceOf(self: *Window, req: ipc_protocol.Request) ?*webface.WebFace {
    const pane = reqPaneExact(self, req) orelse return null;
    return webface.WebFace.fromPane(pane);
}

fn webCmd(self: *Window, req: ipc_protocol.Request, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const eql = std.mem.eql;

    if (eql(u8, req.cmd, "web-list")) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var views: std.ArrayList(WebViewInfo) = .empty;
        const focused = activeOrSelf(self).focusedPane();
        const wins = try liveWindows(arena, c.gtk_window_get_application(@ptrCast(self.app_window)));
        const all: []const *Window = if (wins.len > 0) wins else &[_]*Window{self};
        for (all) |win| {
            for (win.panes.items) |p| {
                const face = webface.WebFace.fromPane(p) orelse continue;
                try views.append(arena, .{
                    .pane = p.id,
                    .view = face.view,
                    .url = if (face.url) |u| try arena.dupe(u8, u) else "",
                    .title = if (face.title) |t| try arena.dupe(u8, t) else "",
                    .loading = face.loading,
                    .can_back = face.can_back,
                    .can_fwd = face.can_fwd,
                    .focused = focused == p,
                    .visible = p.webFaceVisible(),
                    .load_seq = face.load_seq,
                });
            }
        }
        const cl = webface.client();
        return ipc_protocol.writeOkFlat(out, allocator, .{
            .views = views.items,
            .helper = @tagName(cl.state),
            .helper_reason = cl.reason,
        });
    }

    if (eql(u8, req.cmd, "web-open")) {
        const where = req.target orelse "tab";
        const win = activeOrSelf(self);
        var host = win;
        const before = win.panes.items.len;
        if (eql(u8, where, "split")) {
            try win.newWebSplit(c.GTK_ORIENTATION_HORIZONTAL);
        } else if (eql(u8, where, "window")) {
            host = try win.openWebWindow(&.{});
        } else {
            try win.newWebTabAt(null);
        }
        if (host == win and win.panes.items.len <= before)
            return ipc_protocol.writeErr(out, allocator, "could not open a web view");
        if (host.panes.items.len == 0)
            return ipc_protocol.writeErr(out, allocator, "could not open a web view");
        const pane = host.panes.items[host.panes.items.len - 1];
        const face = webface.WebFace.fromPane(pane) orelse
            return ipc_protocol.writeErr(out, allocator, "the new pane has no web face");
        // SELECT the new tab. The point of these tools is that the
        // assistant drives what the user is looking at; an unselected
        // tab is also never allocated, so the view would lay out at
        // its 800x600 default and could not be screenshotted at all.
        if (host.last_created_page) |page| c.adw_tab_view_set_selected_page(host.tab_view, page);
        c.gtk_window_present(@ptrCast(host.app_window));
        _ = c.gtk_widget_grab_focus(@ptrCast(pane.surface.area));
        pane.setWebVisible(true);
        if (req.data) |url| {
            if (url.len > 0) face.navigate(url);
        }
        return ipc_protocol.writeOkFlat(out, allocator, .{ .pane = pane.id, .view = face.view });
    }

    const face = webFaceOf(self, req) orelse
        return ipc_protocol.writeErr(out, allocator, "no web view on that pane (web_tabs lists them; web_open makes one)");

    if (eql(u8, req.cmd, "web-navigate")) {
        if (req.data) |url| {
            if (url.len > 0) {
                face.navigate(url);
                return ipc_protocol.writeOkFlat(out, allocator, .{});
            }
        }
        const act = req.action orelse
            return ipc_protocol.writeErr(out, allocator, "web-navigate needs data=<url> or action=back|forward|reload|stop");
        const nav: web_proto.NavAct = if (eql(u8, act, "back"))
            .back
        else if (eql(u8, act, "forward"))
            .forward
        else if (eql(u8, act, "reload"))
            .reload
        else if (eql(u8, act, "stop"))
            .stop
        else
            return ipc_protocol.writeErr(out, allocator, "unknown navigation action");
        face.navAction(nav);
        return ipc_protocol.writeOkFlat(out, allocator, .{});
    }

    if (eql(u8, req.cmd, "web-scroll")) {
        if (!face.autoScroll(req.dx orelse 0, req.dy orelse 0))
            return ipc_protocol.writeErr(out, allocator, "the web view is not live yet");
        return ipc_protocol.writeOkFlat(out, allocator, .{});
    }

    // A truncated eval result is paged from the GUI's copy: re-running
    // the code to see the rest would run it twice.
    if (eql(u8, req.cmd, "web-eval-text")) {
        const text = face.lastEval() orelse
            return ipc_protocol.writeErr(out, allocator, "no eval result to expand on this pane");
        const off: usize = @min(req.offset orelse 0, text.len);
        const len: usize = @min(req.length orelse 60_000, text.len - off);
        return ipc_protocol.writeOkFlat(out, allocator, .{
            .payload = text[off .. off + len],
            .offset = off,
            .total = text.len,
        });
    }

    if (eql(u8, req.cmd, "web-result")) {
        const token = req.token orelse
            return ipc_protocol.writeErr(out, allocator, "web-result needs token");
        if (face.autoTake(token)) |res| {
            defer allocator.free(res.text);
            return ipc_protocol.writeOkFlat(out, allocator, .{
                .done = true,
                .result_ok = res.ok,
                .payload = res.text,
                .doc_gen = res.meta.doc_gen,
                .rev = res.meta.rev,
                .snapshot_kind = if (res.meta.snap_kind == @intFromEnum(web_proto.SnapKind.delta))
                    @as([]const u8, "delta")
                else
                    @as([]const u8, "full"),
            });
        }
        if (face.autoPending(token))
            return ipc_protocol.writeOkFlat(out, allocator, .{ .done = false });
        return ipc_protocol.writeErr(out, allocator, "unknown token (already collected, or dropped when the helper restarted)");
    }

    if (!eql(u8, req.cmd, "web-request"))
        return ipc_protocol.writeErr(out, allocator, "unknown command");

    const op = req.op orelse
        return ipc_protocol.writeErr(out, allocator, "web-request needs op");
    const token: ?u32 = blk: {
        if (eql(u8, op, "snapshot")) {
            const mode: web_proto.SnapMode = if (req.mode) |m|
                (if (eql(u8, m, "full")) .full else if (eql(u8, m, "history")) .history else .auto)
            else
                .auto;
            const detail: u8 = @intCast(@min(req.detail orelse 1, 2));
            break :blk face.autoSnapshot(@intFromEnum(mode), detail, req.node orelse 0);
        }
        if (eql(u8, op, "act")) {
            const id = req.node orelse
                return ipc_protocol.writeErr(out, allocator, "act needs node=<snapshot id>");
            const act = req.action orelse "click";
            const semact: web_proto.SemAct = if (eql(u8, act, "click"))
                .click
            else if (eql(u8, act, "focus"))
                .focus
            else if (eql(u8, act, "set_value"))
                .set_value
            else if (eql(u8, act, "scroll_into_view"))
                .scroll_into_view
            else if (eql(u8, act, "hover"))
                .hover
            else
                return ipc_protocol.writeErr(out, allocator, "unknown act action");
            break :blk face.autoAct(id, @intFromEnum(semact), req.data orelse "");
        }
        if (eql(u8, op, "expand")) {
            const id = req.node orelse
                return ipc_protocol.writeErr(out, allocator, "expand needs node=<snapshot id>");
            break :blk face.autoExpand(id, req.offset orelse 0, req.length orelse 4096);
        }
        if (eql(u8, op, "query")) {
            const kind = req.action orelse "find_text";
            const qk: web_proto.SemQuery = if (eql(u8, kind, "find_text"))
                .find_text
            else if (eql(u8, kind, "subtree"))
                .subtree
            else if (eql(u8, kind, "focused"))
                .focused
            else
                return ipc_protocol.writeErr(out, allocator, "unknown query kind");
            break :blk face.autoQuery(@intFromEnum(qk), req.data orelse "");
        }
        if (eql(u8, op, "read")) break :blk face.autoRead();
        if (eql(u8, op, "eval")) {
            const code = req.data orelse
                return ipc_protocol.writeErr(out, allocator, "eval needs data=<javascript>");
            break :blk face.autoEval(code, req.await_promise, req.timeout_ms orelse 10_000);
        }
        return ipc_protocol.writeErr(out, allocator, "unknown web-request op");
    };
    const t = token orelse return ipc_protocol.writeErr(
        out,
        allocator,
        "the web view cannot take that request now (helper not connected, or one of the same kind is still in flight)",
    );
    return ipc_protocol.writeOkFlat(out, allocator, .{ .token = t });
}

/// Every tab of every window, each tagged with its window id. A
/// single-global `list` reported only the socket owner's tabs, so a
/// pane dragged into another window read as gone while `send-text`
/// still reached it.
pub fn ipcList(self: *Window, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tabs: std.ArrayList(ipc_protocol.TabInfo) = .empty;
    // "focused" means "where a keystroke would land": every window
    // remembers a focus widget, so only the ACTIVE window's counts.
    const focused = activeOrSelf(self).focusedPane();
    const wins = try liveWindows(arena, c.gtk_window_get_application(@ptrCast(self.app_window)));
    for (wins) |win| try appendTabInfos(win, arena, &tabs, focused);
    // No application (unit/headless edge): still answer for self.
    if (wins.len == 0) try appendTabInfos(self, arena, &tabs, focused);
    try ipc_protocol.writeOk(out, allocator, "tabs", tabs.items);
}

pub fn appendTabInfos(
    self: *Window,
    arena: std.mem.Allocator,
    tabs: *std.ArrayList(ipc_protocol.TabInfo),
    focused: ?*Pane,
) !void {
    const sel = c.adw_tab_view_get_selected_page(self.tab_view);
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
        const child = c.adw_tab_page_get_child(page);
        var pane_infos: std.ArrayList(ipc_protocol.PaneInfo) = .empty;
        for (self.panes.items) |p| {
            if (child == null) continue;
            if (!winmod.widgetIsAncestor(@ptrCast(child), p.widget())) continue;
            const scr = p.terminal.screen;
            try pane_infos.append(arena, .{
                .id = p.id,
                .title = if (scr.last_title) |t| try arena.dupe(u8, t) else "",
                .cwd = if (p.terminal.cwd) |cw| try arena.dupe(u8, cw) else "",
                // Daemon-backed panes have no local child pid; the shell
                // runs under the mux daemon. 0 = "not a local process".
                .pid = 0,
                .rows = scr.rows,
                .cols = scr.cols,
                .focused = (p == focused),
                .zoomed = (p == self.zoom_pane),
            });
        }
        const title_c = c.adw_tab_page_get_title(page);
        try tabs.append(arena, .{
            .id = tabPageId(page),
            .window = self.id,
            .title = if (title_c != null) try arena.dupe(u8, std.mem.span(title_c)) else "",
            .selected = (page == sel),
            .color = if (Window.tabColorOf(page)) |col|
                try std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}", .{ col[0], col[1], col[2] })
            else
                null,
            .panes = pane_infos.items,
        });
    }
}
