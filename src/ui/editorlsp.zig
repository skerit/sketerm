//! The GUI half of the LSP client: process lifetime, non-blocking fd
//! watches on the GLib main loop, and every user-facing feature
//! (diagnostics, completion, hover, navigation, symbols, rename,
//! formatting).
//!
//! Everything protocol-shaped lives in src/lsp/ and is GTK-free; this
//! file owns only what needs GTK. There is exactly ONE editor
//! implementation, so a pane's editor face and the standalone editor
//! window get all of this by construction — both are an `EditorView`.
//!
//! ## Threading
//!
//! None. The GUI is single-threaded (CLAUDE.md): the server's stdout
//! and stderr are non-blocking pipes watched with `g_unix_fd_add`,
//! exactly like the mux socket, and stdin gets a G_IO_OUT watch only
//! while a write is short. Nothing here ever blocks the main loop and
//! there is no worker thread to fence against.
//!
//! ## Connection sharing
//!
//! One `Conn` per (server, workspace root). Two Zig files in the same
//! project share one `zls`; a file in a different project gets its own.
//! `refs` counts the tabs using it and the last tab out shuts it down.
//!
//! ## Remote documents
//!
//! NOT in this change. A server must run near the files, so a document
//! opened from a remote host needs the daemon to spawn it and tunnel
//! its stdio — a new `sketerm-mux` frame plus process management in the
//! poll loop. The structure is ready for it (`Conn` owns a `Child` and
//! a `Session`; only the transport under `pumpWrite`/`onReadable` is
//! local-specific), and `attachTab` refuses a host-qualified spec today
//! rather than silently running the server on the wrong machine. See
//! docs/lsp.md.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const editorview = @import("editorview.zig");
const EditorView = editorview.EditorView;
const ETab = editorview.ETab;
const Document = @import("../editor/document.zig").Document;
const tr = @import("../editor/transaction.zig");
const sel_mod = @import("../editor/selection.zig");
const Selection = sel_mod.Selection;
const vm = @import("../editor/view_model.zig");
const paths = @import("../filebrowser/paths.zig");
const editoroutline = @import("editoroutline.zig");
const Config = @import("../config.zig").Config;

const rpc = @import("../lsp/rpc.zig");
const session = @import("../lsp/session.zig");
const pos = @import("../lsp/position.zig");
const servers = @import("../lsp/servers.zig");
const proc = @import("../lsp/proc.zig");
const diagnostics = @import("../lsp/diagnostics.zig");
const docsync = @import("../lsp/docsync.zig");

/// `SKETERM_LSP_DEBUG=1` traces attach decisions, server lifecycle and
/// published diagnostics to stderr. There is no other way to see why a
/// server did not attach: every failure on that path is deliberately
/// silent for the user.
fn dbg(comptime fmt: []const u8, args: anytype) void {
    const on = @import("../util/profile.zig").getenv("SKETERM_LSP_DEBUG") != null;
    if (!on) return;
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "sketerm: lsp: " ++ fmt ++ "\n", args) catch return;
    _ = c.fprintf(@import("../util/platform.zig").stderr(), "%s", s.ptr);
}

/// Completion re-request debounce while the popup is open. Short: the
/// list must feel attached to the keystrokes.
const COMPLETION_DEBOUNCE_MS: c_uint = 120;
/// How long a server gets to exit after `shutdown` before SIGKILL.
const SHUTDOWN_GRACE_MS: c_uint = 1500;
/// Popup geometry.
const POPUP_W: c_int = 460;
const POPUP_H: c_int = 260;
const HOVER_W: c_int = 520;
/// Hard cap on rows built into a popup — a `references` answer on a
/// popular symbol can be tens of thousands, and building that many
/// GtkLabels locks the UI for seconds.
const MAX_ROWS: usize = 300;

// ======================================================================
// Per-tab state
// ======================================================================

pub const TabState = struct {
    alloc: std.mem.Allocator,
    tab: *ETab,
    conn: ?*Conn = null,
    sync: docsync.DocSync,
    diags: diagnostics.Store,
    /// Debounced didChange flush; 0 = idle.
    change_timer: c_uint = 0,
    /// Debounced completion re-request; 0 = idle.
    completion_timer: c_uint = 0,

    pub fn create(alloc: std.mem.Allocator, tab: *ETab) ?*TabState {
        const self = alloc.create(TabState) catch return null;
        self.* = .{
            .alloc = alloc,
            .tab = tab,
            .sync = docsync.DocSync.init(alloc),
            .diags = diagnostics.Store.init(alloc),
        };
        return self;
    }

    pub fn destroy(self: *TabState) void {
        self.stopTimers();
        self.sync.deinit();
        self.diags.deinit();
        self.alloc.destroy(self);
    }

    fn stopTimers(self: *TabState) void {
        if (self.change_timer != 0) {
            _ = c.g_source_remove(self.change_timer);
            self.change_timer = 0;
        }
        if (self.completion_timer != 0) {
            _ = c.g_source_remove(self.completion_timer);
            self.completion_timer = 0;
        }
    }

    /// Document observer slot 2: queue the change for didChange AND
    /// carry the diagnostics' anchors through the edit, both against
    /// the pre-edit text. See docsync.zig for why this must be a
    /// before-apply hook.
    pub fn observeEdits(ctx: *anyopaque, doc: *const Document, edits: []const tr.Edit) void {
        const self: *TabState = @ptrCast(@alignCast(ctx));
        const enc: pos.Encoding = if (self.conn) |cn| cn.sess.caps.encoding else .utf16;
        self.sync.noteEdits(doc, edits, enc);
        self.diags.mapThrough(edits);
    }
};

// ======================================================================
// One server process
// ======================================================================

pub const Conn = struct {
    mgr: *Manager,
    /// Registry name ("zls"), owned.
    name: []u8,
    /// Workspace root path, owned.
    root: []u8,
    /// `file://` root URI, owned.
    root_uri: []u8,
    child: proc.Child = .{},
    sess: session.Session,
    watch_out: c_uint = 0,
    watch_err: c_uint = 0,
    watch_in: c_uint = 0,
    /// Bytes of `sess.out` already handed to the pipe.
    out_pos: usize = 0,
    /// Tabs currently attached.
    refs: usize = 0,
    /// Set once teardown has begun; every callback becomes a no-op.
    closing: bool = false,
    /// Grace timer between `shutdown` and SIGKILL; 0 = none.
    kill_timer: c_uint = 0,
    /// Last line the server wrote to stderr, for the status line.
    last_stderr: [160]u8 = undefined,
    last_stderr_len: usize = 0,

    fn handler(self: *Conn) session.Handler {
        return .{
            .ctx = self,
            .on_response = onResponse,
            .on_notification = onNotification,
            .on_state = onState,
        };
    }

    fn onResponse(ctx: *anyopaque, req: session.Request, env: rpc.Envelope) void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        if (self.closing) return;
        self.mgr.handleResponse(self, req, env);
    }

    fn onNotification(ctx: *anyopaque, method: []const u8, params: std.json.Value) void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        if (self.closing) return;
        self.mgr.handleNotification(self, method, params);
    }

    fn onState(ctx: *anyopaque, state: session.State) void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        if (state == .ready) self.mgr.onServerReady(self);
        if (state == .dead) self.mgr.onServerDead(self);
    }

    /// Push whatever the session queued into the server's stdin.
    /// Installs a writable watch only when the pipe is full, so the
    /// common case costs one write() and no GLib source.
    fn pumpWrite(self: *Conn) void {
        if (self.child.stdin < 0) return;
        while (self.out_pos < self.sess.out.items.len) {
            const rest = self.sess.out.items[self.out_pos..];
            const n = c.write(self.child.stdin, rest.ptr, rest.len);
            if (n > 0) {
                self.out_pos += @intCast(n);
                continue;
            }
            const err = std.posix.errno(@as(isize, @intCast(n)));
            if (err == .AGAIN or err == .INTR) {
                if (self.watch_in == 0) {
                    self.watch_in = c.g_unix_fd_add(
                        self.child.stdin,
                        c.G_IO_OUT | c.G_IO_ERR | c.G_IO_HUP,
                        @ptrCast(&onWritable),
                        @ptrCast(self),
                    );
                }
                return;
            }
            // A broken pipe means the server is gone.
            self.sess.markDead();
            return;
        }
        self.sess.out.clearRetainingCapacity();
        self.out_pos = 0;
        if (self.watch_in != 0) {
            _ = c.g_source_remove(self.watch_in);
            self.watch_in = 0;
        }
    }

    fn onWritable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Conn = @ptrCast(@alignCast(user.?));
        if (self.closing) {
            self.watch_in = 0;
            return 0;
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_in = 0;
            self.sess.markDead();
            return 0;
        }
        const had = self.watch_in;
        self.watch_in = 0;
        self.pumpWrite();
        // pumpWrite reinstalls the watch when it is still short; if it
        // did, keep THIS source (same fd, same callback) rather than
        // leaving two behind.
        if (self.watch_in != 0) {
            _ = c.g_source_remove(self.watch_in);
            self.watch_in = had;
            return 1;
        }
        return 0;
    }

    fn onReadable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Conn = @ptrCast(@alignCast(user.?));
        if (self.closing) {
            self.watch_out = 0;
            return 0;
        }
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n > 0) {
                self.sess.feed(buf[0..@intCast(n)]);
                if (self.sess.state == .dead) break;
                continue;
            }
            if (n == 0) {
                // EOF: the server exited (or never exec'd).
                self.watch_out = 0;
                self.sess.markDead();
                return 0;
            }
            const err = std.posix.errno(@as(isize, @intCast(n)));
            if (err == .AGAIN) break;
            if (err == .INTR) continue;
            self.watch_out = 0;
            self.sess.markDead();
            return 0;
        }
        self.pumpWrite();
        if (self.sess.state == .dead) {
            self.watch_out = 0;
            return 0;
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_out = 0;
            self.sess.markDead();
            return 0;
        }
        return 1;
    }

    /// Drain stderr so the pipe never fills (a server whose stderr
    /// blocks stops serving), keeping the last line for the status bar.
    fn onStderr(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Conn = @ptrCast(@alignCast(user.?));
        if (self.closing) {
            self.watch_err = 0;
            return 0;
        }
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n > 0) {
                const chunk = buf[0..@intCast(n)];
                var it = std.mem.tokenizeScalar(u8, chunk, '\n');
                while (it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len == 0) continue;
                    const take = @min(trimmed.len, self.last_stderr.len);
                    @memcpy(self.last_stderr[0..take], trimmed[0..take]);
                    self.last_stderr_len = take;
                }
                continue;
            }
            break;
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_err = 0;
            return 0;
        }
        return 1;
    }

    fn stderrText(self: *const Conn) []const u8 {
        return self.last_stderr[0..self.last_stderr_len];
    }

    fn dropWatches(self: *Conn) void {
        for ([_]*c_uint{ &self.watch_out, &self.watch_err, &self.watch_in }) |w| {
            if (w.* != 0) _ = c.g_source_remove(w.*);
            w.* = 0;
        }
        if (self.kill_timer != 0) {
            _ = c.g_source_remove(self.kill_timer);
            self.kill_timer = 0;
        }
    }

    fn destroy(self: *Conn) void {
        self.closing = true;
        self.dropWatches();
        self.child.killHard();
        self.child.closePipes();
        _ = self.child.reap();
        self.sess.deinit();
        const a = self.mgr.alloc;
        a.free(self.name);
        a.free(self.root);
        a.free(self.root_uri);
        a.destroy(self);
    }
};

// ======================================================================
// Popup list (completion / locations / symbols)
// ======================================================================

const Mode = enum { none, completion, locations, symbols };

const Item = struct {
    /// Row label, owned.
    label: []u8,
    /// Right-hand detail (type, path), owned.
    detail: []u8,
    /// Completion: the text to insert. Locations/symbols: the target
    /// spec. Owned.
    payload: []u8,
    /// Locations/symbols: byte offset (0 when unknown, resolved from
    /// `target` after the document loads).
    line: u32 = 0,
    col: u32 = 0,
    /// Completion: the raw item JSON, so `completionItem/resolve` can
    /// send it back verbatim. Owned; empty when resolve is unsupported.
    raw: []u8 = &.{},
    /// Completion: a server-supplied textEdit range, in document bytes.
    edit_start: usize = 0,
    edit_end: usize = 0,
    has_edit: bool = false,
    /// Documentation, filled in lazily by resolve. Owned.
    doc: []u8 = &.{},
};

const ListPopup = struct {
    mgr: *Manager,
    popover: ?*c.GtkWidget = null,
    listbox: ?*c.GtkListBox = null,
    scroll: ?*c.GtkWidget = null,
    header: ?*c.GtkLabel = null,
    doc_label: ?*c.GtkLabel = null,
    items: std.ArrayList(Item) = .empty,
    /// Indices of `items` currently shown (the filter's output).
    shown: std.ArrayList(usize) = .empty,
    sel: usize = 0,
    mode: Mode = .none,
    tab_id: u64 = 0,
    /// Document revision the list was computed for; a moved revision
    /// makes an ACCEPT unsafe (offsets would be wrong).
    revision: u64 = 0,
    /// Completion: byte range the accepted text replaces.
    range_start: usize = 0,
    range_end: usize = 0,
    /// Symbols: incremental filter typed since the popup opened.
    filter: std.ArrayList(u8) = .empty,
    open: bool = false,

    fn clearItems(self: *ListPopup) void {
        const a = self.mgr.alloc;
        for (self.items.items) |it| {
            a.free(it.label);
            a.free(it.detail);
            a.free(it.payload);
            if (it.raw.len > 0) a.free(it.raw);
            if (it.doc.len > 0) a.free(it.doc);
        }
        self.items.clearRetainingCapacity();
        self.shown.clearRetainingCapacity();
    }

    fn deinit(self: *ListPopup) void {
        self.clearItems();
        const a = self.mgr.alloc;
        self.items.deinit(a);
        self.shown.deinit(a);
        self.filter.deinit(a);
    }
};

const HoverPopup = struct {
    mgr: *Manager,
    popover: ?*c.GtkWidget = null,
    label: ?*c.GtkLabel = null,
    open: bool = false,
};

// ======================================================================
// Manager: one per EditorView
// ======================================================================

pub const Manager = struct {
    view: *EditorView,
    alloc: std.mem.Allocator,
    conns: std.ArrayList(*Conn) = .empty,
    list: ListPopup = undefined,
    hover: HoverPopup = undefined,
    /// Scratch for building JSON params.
    scratch: std.ArrayList(u8) = .empty,

    pub fn create(view: *EditorView) ?*Manager {
        const self = view.allocator.create(Manager) catch return null;
        self.* = .{ .view = view, .alloc = view.allocator };
        self.list = .{ .mgr = self };
        self.hover = .{ .mgr = self };
        return self;
    }

    pub fn destroy(self: *Manager) void {
        self.closePopup();
        self.closeHover();
        self.unparentPopups();
        for (self.conns.items) |cn| cn.destroy();
        self.conns.deinit(self.alloc);
        self.list.deinit();
        self.scratch.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Popovers are parented to the GL area with `gtk_widget_set_parent`
    /// and MUST be unparented before it finalizes, or GTK warns
    /// "Finalizing GtkGLArea, but it still has children left" (the same
    /// rule menu.zig documents).
    pub fn unparentPopups(self: *Manager) void {
        for ([_]?*c.GtkWidget{ self.list.popover, self.hover.popover }) |maybe| {
            const w = maybe orelse continue;
            if (c.gtk_widget_get_parent(w) != null) c.gtk_widget_unparent(w);
        }
        self.list.popover = null;
        self.hover.popover = null;
        self.list.listbox = null;
        self.list.scroll = null;
        self.list.header = null;
        self.list.doc_label = null;
        self.hover.label = null;
    }

    fn cfg(self: *Manager) ?*const Config {
        if (self.view.ownerWindow()) |win| return &win.config;
        return self.view.standalone_config;
    }

    // ---- connections --------------------------------------------------

    fn findConn(self: *Manager, name: []const u8, root: []const u8) ?*Conn {
        for (self.conns.items) |cn| {
            if (cn.closing) continue;
            if (std.mem.eql(u8, cn.name, name) and std.mem.eql(u8, cn.root, root)) return cn;
        }
        return null;
    }

    fn commandInstalled(ctx: ?*anyopaque, command: []const u8) bool {
        const self: *Manager = @ptrCast(@alignCast(ctx.?));
        return proc.onPath(self.alloc, command);
    }

    fn dirExists(_: ?*anyopaque, dir: []const u8, name: []const u8) bool {
        var buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return false;
        return c.access(full.ptr, c.F_OK) == 0;
    }

    fn spawnConn(self: *Manager, srv: *const @import("../config.zig").LspServer, root: []const u8) ?*Conn {
        const cn = self.alloc.create(Conn) catch return null;
        const name = self.alloc.dupe(u8, srv.name) catch {
            self.alloc.destroy(cn);
            return null;
        };
        const root_dup = self.alloc.dupe(u8, root) catch {
            self.alloc.free(name);
            self.alloc.destroy(cn);
            return null;
        };
        const root_uri = servers.pathToUri(self.alloc, root) catch {
            self.alloc.free(name);
            self.alloc.free(root_dup);
            self.alloc.destroy(cn);
            return null;
        };
        cn.* = .{
            .mgr = self,
            .name = name,
            .root = root_dup,
            .root_uri = root_uri,
            .sess = undefined,
        };
        cn.sess = session.Session.init(self.alloc, cn.handler());

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        proc.splitArgs(self.alloc, srv.args, &argv) catch {};
        cn.child = proc.spawn(self.alloc, srv.command, argv.items, root) catch {
            // Nothing was watched or listed yet, so tear down by hand
            // rather than through `destroy` (which would kill a pid we
            // never got).
            cn.sess.deinit();
            self.alloc.free(cn.name);
            self.alloc.free(cn.root);
            self.alloc.free(cn.root_uri);
            self.alloc.destroy(cn);
            return null;
        };
        cn.watch_out = c.g_unix_fd_add(
            cn.child.stdout,
            c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP,
            @ptrCast(&Conn.onReadable),
            @ptrCast(cn),
        );
        cn.watch_err = c.g_unix_fd_add(
            cn.child.stderr,
            c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP,
            @ptrCast(&Conn.onStderr),
            @ptrCast(cn),
        );
        self.conns.append(self.alloc, cn) catch {
            cn.destroy();
            return null;
        };
        cn.sess.start(cn.root_uri, c.getpid(), srv.init_options);
        cn.pumpWrite();
        return cn;
    }

    fn onServerReady(self: *Manager, cn: *Conn) void {
        dbg("{s} ready (sync={s} completion={} hover={} definition={})", .{ cn.name, @tagName(cn.sess.caps.sync), cn.sess.caps.completion, cn.sess.caps.hover, cn.sess.caps.definition });
        // Open every already-attached document now that the server has
        // told us what it can do (didOpen is refused before `.ready`).
        for (self.view.tabs.items) |tab| {
            const st = tab.lsp orelse continue;
            if (st.conn != cn) continue;
            self.openDocument(tab, st);
        }
        cn.pumpWrite();
        self.view.updateStatusExternal();
    }

    fn onServerDead(self: *Manager, cn: *Conn) void {
        dbg("{s} dead: {s} / stderr: {s}", .{ cn.name, cn.sess.errText(), cn.stderrText() });
        for (self.view.tabs.items) |tab| {
            const st = tab.lsp orelse continue;
            if (st.conn != cn) continue;
            st.conn = null;
            st.sync.open = false;
            st.diags.clear();
            st.diags.published = false;
        }
        if (self.list.open and self.list.mode != .none) self.closePopup();
        cn.dropWatches();
        self.view.queueRenderExternal();
    }

    // ---- tab lifecycle -------------------------------------------------

    /// Attach a server to `tab` if one is configured for its language
    /// and actually installed. Silent when there is none — a missing
    /// server must never produce a dialog or an error line.
    pub fn attachTab(self: *Manager, tab: *ETab) void {
        const conf = self.cfg() orelse return;
        if (!conf.editor_lsp) return;
        const spec = tab.spec orelse return;
        const loc = paths.parseSpec(spec);
        // Remote documents: a server must run near the files, and this
        // change spawns only local processes. Running a LOCAL server
        // against a remote path would resolve every import against the
        // wrong filesystem, so we do nothing at all.
        if (loc.host != null) return;
        const lang = servers.languageId(loc.path);
        if (lang.len == 0) return;
        // Skip servers whose binary is not present rather than
        // stopping at the first configured one: a machine with only
        // some of the configured servers installed should still get
        // the ones it has.
        const srv = conf.lspServerForInstalled(lang, self, commandInstalled) orelse return;

        const dir = servers.dirnameOf(loc.path);
        const root = servers.findRoot(dir, srv.root_files, dirExists, null);
        dbg("{s} -> {s} ({s}) root={s}", .{ spec, srv.name, srv.command, root });
        const cn = self.findConn(srv.name, root) orelse self.spawnConn(srv, root) orelse {
            dbg("could not spawn {s}", .{srv.command});
            return;
        };

        const st = tab.lsp orelse blk: {
            const fresh = TabState.create(self.alloc, tab) orelse return;
            tab.lsp = fresh;
            break :blk fresh;
        };
        if (st.conn == cn) return;
        if (st.conn) |old| self.detachFromConn(tab, st, old);
        st.conn = cn;
        cn.refs += 1;
        st.sync.language_id = lang;
        var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
        const uri_path = std.fmt.bufPrint(&buf, "{s}", .{loc.path}) catch return;
        const uri = servers.pathToUri(self.alloc, uri_path) catch return;
        defer self.alloc.free(uri);
        st.sync.setUri(uri) catch return;
        tab.doc.addObserver(.{ .ctx = st, .before_apply = TabState.observeEdits });
        if (cn.sess.state == .ready) self.openDocument(tab, st);
    }

    fn openDocument(self: *Manager, tab: *ETab, st: *TabState) void {
        const cn = st.conn orelse return;
        if (st.sync.open) return;
        // Before `.ready` the session refuses notifications, so marking
        // the document open here would strand it: `onServerReady` skips
        // documents it believes are already open, and the server would
        // never see this one at all.
        if (cn.sess.state != .ready) return;
        const text = tab.doc.textAlloc(self.alloc) catch return;
        defer self.alloc.free(text);
        st.sync.version = 1;
        dbg("didOpen {s} ({s}, {d} bytes)", .{ st.sync.uri, st.sync.language_id, text.len });
        cn.sess.didOpen(st.sync.uri, st.sync.language_id, st.sync.version, text);
        st.sync.open = true;
        st.sync.clearQueue();
        st.sync.needs_full = false;
        cn.pumpWrite();
    }

    fn detachFromConn(self: *Manager, tab: *ETab, st: *TabState, cn: *Conn) void {
        if (st.sync.open and !cn.closing) {
            cn.sess.didClose(st.sync.uri);
            cn.pumpWrite();
        }
        st.sync.open = false;
        cn.sess.forgetTab(tab.id);
        if (cn.refs > 0) cn.refs -= 1;
        st.conn = null;
        if (cn.refs == 0) self.shutdownConn(cn);
    }

    /// Ask a server to stop, and SIGKILL it if it does not.
    fn shutdownConn(self: *Manager, cn: *Conn) void {
        _ = self;
        if (cn.closing) return;
        cn.sess.stop();
        cn.pumpWrite();
        cn.child.terminate();
        if (cn.kill_timer == 0)
            cn.kill_timer = c.g_timeout_add(SHUTDOWN_GRACE_MS, @ptrCast(&onKillTimer), @ptrCast(cn));
    }

    fn onKillTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const cn: *Conn = @ptrCast(@alignCast(user.?));
        cn.kill_timer = 0;
        if (cn.closing) return 0;
        cn.mgr.removeConn(cn);
        return 0;
    }

    fn removeConn(self: *Manager, cn: *Conn) void {
        for (self.conns.items, 0..) |x, i| {
            if (x != cn) continue;
            _ = self.conns.orderedRemove(i);
            break;
        }
        cn.destroy();
    }

    /// The tab is closing (or its document was replaced by a reload).
    pub fn detachTab(self: *Manager, tab: *ETab) void {
        const st = tab.lsp orelse return;
        if (self.list.open and self.list.tab_id == tab.id) self.closePopup();
        if (self.hover.open) self.closeHover();
        if (st.conn) |cn| self.detachFromConn(tab, st, cn);
        st.destroy();
        tab.lsp = null;
    }

    // ---- document sync -------------------------------------------------

    /// Called after every document mutation. Arms the didChange
    /// debounce; the flush itself is what the server sees.
    pub fn onEdited(self: *Manager, tab: *ETab) void {
        const st = tab.lsp orelse return;
        if (st.conn == null or !st.sync.open) return;
        if (!st.sync.hasPendingChanges()) return;
        if (st.change_timer != 0) return;
        const ms: c_uint = if (self.cfg()) |conf| @max(10, conf.editor_lsp_debounce_ms) else 250;
        const ctx = TabCtx.create(self, tab) orelse return;
        st.change_timer = c.g_timeout_add(ms, @ptrCast(&onChangeTimer), @ptrCast(ctx));
    }

    fn onChangeTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const ctx: *TabCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const r = ctx.resolve() orelse return 0;
        const st = r.tab.lsp orelse return 0;
        st.change_timer = 0;
        r.mgr.flushChanges(r.tab);
        return 0;
    }

    /// Send the queued changes NOW. Every feature request calls this
    /// first: LSP notifications and requests are processed in order, so
    /// flushing immediately before a request is what makes the answer
    /// describe the text the user is looking at.
    pub fn flushChanges(self: *Manager, tab: *ETab) void {
        const st = tab.lsp orelse return;
        const cn = st.conn orelse return;
        if (!st.sync.hasPendingChanges()) return;
        const text = tab.doc.textAlloc(self.alloc) catch return;
        defer self.alloc.free(text);
        st.sync.flush(&cn.sess, text);
        cn.pumpWrite();
    }

    pub fn onSaved(self: *Manager, tab: *ETab) void {
        const st = tab.lsp orelse return;
        const cn = st.conn orelse return;
        self.flushChanges(tab);
        const text = tab.doc.textAlloc(self.alloc) catch return;
        defer self.alloc.free(text);
        cn.sess.didSave(st.sync.uri, text);
        cn.pumpWrite();
    }

    /// The document object was replaced (a load/reload): the old
    /// observer died with it and the server must be told the content
    /// changed wholesale.
    pub fn onDocumentReplaced(self: *Manager, tab: *ETab) void {
        const st = tab.lsp orelse {
            self.attachTab(tab);
            return;
        };
        st.diags.clear();
        st.diags.published = false;
        st.sync.clearQueue();
        st.sync.needs_full = false;
        tab.doc.addObserver(.{ .ctx = st, .before_apply = TabState.observeEdits });
        const cn = st.conn orelse {
            self.attachTab(tab);
            return;
        };
        if (!st.sync.open) {
            self.openDocument(tab, st);
            return;
        }
        const text = tab.doc.textAlloc(self.alloc) catch return;
        defer self.alloc.free(text);
        st.sync.version += 1;
        cn.sess.didChange(st.sync.uri, st.sync.version, &.{}, text);
        cn.pumpWrite();
    }

    // ---- inbound -------------------------------------------------------

    fn tabForUri(self: *Manager, cn: *Conn, uri: []const u8) ?*ETab {
        for (self.view.tabs.items) |tab| {
            const st = tab.lsp orelse continue;
            if (st.conn != cn) continue;
            if (std.mem.eql(u8, st.sync.uri, uri)) return tab;
        }
        return null;
    }

    fn handleNotification(self: *Manager, cn: *Conn, method: []const u8, params: std.json.Value) void {
        if (!std.mem.eql(u8, method, "textDocument/publishDiagnostics")) return;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const uri = switch (obj.get("uri") orelse std.json.Value.null) {
            .string => |s| s,
            else => return,
        };
        const tab = self.tabForUri(cn, uri) orelse {
            dbg("diagnostics for an unknown uri: {s}", .{uri});
            return;
        };
        const st = tab.lsp orelse return;
        const arr = switch (obj.get("diagnostics") orelse std.json.Value.null) {
            .array => |a| a,
            else => return,
        };
        var list: std.ArrayList(diagnostics.Diagnostic) = .empty;
        defer list.deinit(self.alloc);
        const enc = cn.sess.caps.encoding;
        for (arr.items) |d| {
            if (d != .object) continue;
            const dr = pos.parseRange(d.object.get("range") orelse .null);
            const offs = pos.rangeToOffsets(&tab.doc.rope, dr, enc);
            const msg = switch (d.object.get("message") orelse std.json.Value.null) {
                .string => |s| s,
                else => "",
            };
            const src = switch (d.object.get("source") orelse std.json.Value.null) {
                .string => |s| s,
                else => "",
            };
            const sev = switch (d.object.get("severity") orelse std.json.Value.null) {
                .integer => |i| diagnostics.Severity.fromInt(i),
                else => .err,
            };
            list.append(self.alloc, .{
                .start = offs.start,
                .end = offs.end,
                .severity = sev,
                .message = @constCast(msg),
                .source = @constCast(src),
            }) catch break;
        }
        dbg("diagnostics for {s}: {d}", .{ uri, list.items.len });
        st.diags.replace(tab.doc.revision, list.items) catch {};
        self.view.queueRenderExternal();
        self.view.updateStatusExternal();
    }

    fn handleResponse(self: *Manager, cn: *Conn, req: session.Request, env: rpc.Envelope) void {
        const tab = self.view.findTabByIdPublic(req.tab_id);
        switch (req.kind) {
            .completion => self.onCompletion(cn, req, env, tab),
            .completion_resolve => self.onCompletionResolve(req, env),
            .hover => self.onHover(req, env, tab),
            .definition, .declaration, .type_definition, .references => self.onLocations(cn, req, env, tab),
            .document_symbol, .workspace_symbol => self.onSymbols(cn, req, env, tab),
            .rename => self.onWorkspaceEdit(cn, req, env),
            .formatting, .range_formatting => self.onFormatting(req, env, tab),
            else => {},
        }
    }

    // ---- feature entry points -------------------------------------------

    const Ready = struct { tab: *ETab, st: *TabState, cn: *Conn };

    /// Resolve "the active tab has a live server", flushing pending
    /// changes on the way. Reports to the status line when the user
    /// asked for a feature and there is nothing behind it — the one
    /// place a missing server is allowed to be visible.
    fn ready(self: *Manager, what: []const u8) ?Ready {
        const tab = self.view.activeTab() orelse return null;
        const st = tab.lsp orelse {
            dbg("{s}: no tab state", .{what});
            self.reportNoServer(what);
            return null;
        };
        const cn = st.conn orelse {
            self.reportNoServer(what);
            return null;
        };
        if (cn.sess.state != .ready) {
            self.view.setStatusText("Language server is still starting…");
            return null;
        }
        self.flushChanges(tab);
        return .{ .tab = tab, .st = st, .cn = cn };
    }

    fn reportNoServer(self: *Manager, what: []const u8) void {
        var buf: [160:0]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "No language server for {s}.", .{what}) catch "No language server.";
        self.view.setStatusText(msg);
    }

    /// `{"textDocument":{"uri":…},"position":{…}}` for `offset`.
    fn docPosParams(self: *Manager, r: Ready, offset: usize, extra: []const u8) ?[]const u8 {
        const p = pos.offsetToPosition(&r.tab.doc.rope, offset, r.cn.sess.caps.encoding);
        self.scratch.clearRetainingCapacity();
        self.scratch.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return null;
        session.appendJsonString(self.alloc, &self.scratch, r.st.sync.uri) catch return null;
        self.scratch.print(
            self.alloc,
            "}},\"position\":{{\"line\":{d},\"character\":{d}}}{s}}}",
            .{ p.line, p.character, extra },
        ) catch return null;
        return self.scratch.items;
    }

    fn issue(self: *Manager, r: Ready, kind: session.Kind, method: []const u8, params: []const u8, aux: u64) void {
        r.cn.sess.cancelKind(kind, r.tab.id);
        _ = r.cn.sess.sendRequest(kind, method, params, .{
            .id = 0,
            .kind = kind,
            .tab_id = r.tab.id,
            .revision = r.tab.doc.revision,
            .aux = aux,
        });
        r.cn.pumpWrite();
        _ = self;
    }

    // ---- completion ------------------------------------------------------

    pub fn requestCompletion(self: *Manager, explicit: bool) void {
        const r = self.ready("completion") orelse return;
        if (!r.cn.sess.caps.completion) {
            if (explicit) self.view.setStatusText("Server offers no completion.");
            return;
        }
        const caret = r.tab.sels.primary().head;
        const word_start = wordStart(&r.tab.doc, caret);
        dbg("completion at {d} (prefix from {d}), explicit={}", .{ caret, word_start, explicit });
        const trigger_kind: u8 = if (explicit) 1 else 2;
        var extra: [64]u8 = undefined;
        const ex = std.fmt.bufPrint(&extra, ",\"context\":{{\"triggerKind\":{d}}}", .{trigger_kind}) catch "";
        const params = self.docPosParams(r, caret, ex) orelse return;
        self.list.range_start = word_start;
        self.list.range_end = caret;
        self.issue(r, .completion, "textDocument/completion", params, word_start);
    }

    fn onCompletion(self: *Manager, cn: *Conn, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        const tab = maybe_tab orelse return;
        if (env.has_error) {
            dbg("completion error: {s}", .{env.err_message});
            return;
        }
        // Staleness: the document moved on, so every range in this
        // answer is measured against text that no longer exists.
        if (tab.doc.revision != req.revision) {
            dbg("completion dropped: stale (req {d}, doc {d})", .{ req.revision, tab.doc.revision });
            return;
        }
        const items = completionItems(env.result) orelse {
            dbg("completion: no items array in the answer", .{});
            return;
        };
        dbg("completion: {d} raw items (rev {d} vs {d})", .{ items.len, req.revision, tab.doc.revision });
        self.list.clearItems();
        self.list.mode = .completion;
        self.list.tab_id = tab.id;
        self.list.revision = req.revision;
        self.list.range_start = @min(req.aux, tab.doc.rope.len());
        self.list.range_end = tab.sels.primary().head;
        self.list.filter.clearRetainingCapacity();

        const enc = cn.sess.caps.encoding;
        var n: usize = 0;
        for (items) |raw| {
            if (n >= MAX_ROWS) break;
            if (raw != .object) continue;
            const o = raw.object;
            const label = strOf(o.get("label")) orelse continue;
            // NOT sortText as a fallback: servers put ranking keys
            // there ("11", "15"), which reads as noise in the list.
            const detail = strOf(o.get("detail")) orelse completionKindName(o.get("kind"));
            var insert = strOf(o.get("insertText")) orelse label;
            var item = Item{
                .label = self.alloc.dupe(u8, label) catch continue,
                .detail = self.alloc.dupe(u8, detail) catch continue,
                .payload = &.{},
            };
            // A server-supplied textEdit is authoritative about WHAT it
            // replaces — the client-side word scan is only a fallback.
            if (o.get("textEdit")) |te| {
                if (te == .object) {
                    const rng = te.object.get("range") orelse te.object.get("replace") orelse .null;
                    const offs = pos.rangeToOffsets(&tab.doc.rope, pos.parseRange(rng), enc);
                    item.edit_start = offs.start;
                    item.edit_end = offs.end;
                    item.has_edit = true;
                    if (strOf(te.object.get("newText"))) |nt| insert = nt;
                }
            }
            item.payload = self.alloc.dupe(u8, insert) catch continue;
            if (cn.sess.caps.completion_resolve) {
                item.raw = serializeValue(self.alloc, raw) catch &.{};
            }
            self.list.items.append(self.alloc, item) catch break;
            n += 1;
        }
        if (self.list.items.items.len == 0) {
            self.closePopup();
            return;
        }
        self.applyFilter();
        self.showPopup();
    }

    fn onCompletionResolve(self: *Manager, req: session.Request, env: rpc.Envelope) void {
        if (env.has_error or !self.list.open or self.list.mode != .completion) return;
        const idx = req.aux;
        if (idx >= self.list.items.items.len) return;
        const doc_text = hoverText(self.alloc, env.result) catch return;
        if (doc_text.len == 0) {
            self.alloc.free(doc_text);
            return;
        }
        const item = &self.list.items.items[idx];
        if (item.doc.len > 0) self.alloc.free(item.doc);
        item.doc = doc_text;
        self.refreshPopupHeader();
    }

    /// Ask for the selected item's documentation, once.
    fn resolveSelected(self: *Manager) void {
        if (self.list.mode != .completion or self.list.shown.items.len == 0) return;
        const idx = self.list.shown.items[self.list.sel];
        const item = &self.list.items.items[idx];
        if (item.doc.len > 0 or item.raw.len == 0) return;
        const tab = self.view.activeTab() orelse return;
        const st = tab.lsp orelse return;
        const cn = st.conn orelse return;
        if (!cn.sess.caps.completion_resolve) return;
        cn.sess.cancelKind(.completion_resolve, tab.id);
        _ = cn.sess.sendRequest(.completion_resolve, "completionItem/resolve", item.raw, .{
            .id = 0,
            .kind = .completion_resolve,
            .tab_id = tab.id,
            .revision = tab.doc.revision,
            .aux = idx,
        });
        cn.pumpWrite();
    }

    fn acceptCompletion(self: *Manager) void {
        if (self.list.shown.items.len == 0) {
            self.closePopup();
            return;
        }
        const tab = self.view.activeTab() orelse return self.closePopup();
        if (tab.id != self.list.tab_id) return self.closePopup();
        const idx = self.list.shown.items[self.list.sel];
        const item = self.list.items.items[idx];
        const caret = tab.sels.primary().head;
        var start = if (item.has_edit) item.edit_start else self.list.range_start;
        var end = if (item.has_edit) @max(item.edit_end, caret) else caret;
        start = @min(start, tab.doc.rope.len());
        end = @min(@max(end, start), tab.doc.rope.len());
        const text = self.alloc.dupe(u8, item.payload) catch return;
        defer self.alloc.free(text);
        self.closePopup();

        var tx = tr.Transaction.init(tab.doc.revision);
        defer tx.deinit(self.alloc);
        tx.addReplace(self.alloc, start, end - start, text) catch return;
        const before = vm.snapshotOf(&tab.sels);
        _ = tab.doc.applyTransactionSel(&tx, before) catch return;
        tab.sels.mapThrough(tx.edits.items, .editor);
        vm.clampSelections(&tab.doc, &tab.sels);
        self.view.afterExternalEdit(tab);
    }

    // ---- hover ------------------------------------------------------------

    pub fn requestHover(self: *Manager) void {
        // A diagnostic under the caret is shown even when the server
        // has no hover provider: it is the message the user is most
        // likely reaching for.
        const r = self.ready("hover") orelse return;
        if (!r.cn.sess.caps.hover) {
            if (self.diagnosticTextAtCaret(r.tab)) |txt| {
                defer self.alloc.free(txt);
                self.showHover(txt);
                return;
            }
            self.view.setStatusText("Server offers no hover.");
            return;
        }
        const params = self.docPosParams(r, r.tab.sels.primary().head, "") orelse return;
        self.issue(r, .hover, "textDocument/hover", params, 0);
    }

    fn onHover(self: *Manager, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        const tab = maybe_tab orelse return;
        if (env.has_error or tab.doc.revision != req.revision) return;
        const text = hoverText(self.alloc, env.result) catch return;
        defer self.alloc.free(text);
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(self.alloc);
        if (self.diagnosticTextAtCaret(tab)) |d| {
            defer self.alloc.free(d);
            combined.appendSlice(self.alloc, d) catch {};
            if (text.len > 0) combined.appendSlice(self.alloc, "\n\n") catch {};
        }
        combined.appendSlice(self.alloc, text) catch {};
        if (combined.items.len == 0) {
            self.view.setStatusText("Nothing to show here.");
            return;
        }
        self.showHover(combined.items);
    }

    /// "severity: message [source]" for the diagnostic under the caret.
    fn diagnosticTextAtCaret(self: *Manager, tab: *ETab) ?[]u8 {
        const st = tab.lsp orelse return null;
        const d = st.diags.at(tab.sels.primary().head) orelse return null;
        return std.fmt.allocPrint(self.alloc, "{s}: {s}{s}{s}", .{
            d.severity.label(),
            d.message,
            if (d.source.len > 0) "  —  " else "",
            d.source,
        }) catch null;
    }

    // ---- navigation --------------------------------------------------------

    pub fn requestDefinition(self: *Manager, kind: session.Kind) void {
        const what = switch (kind) {
            .declaration => "go to declaration",
            .type_definition => "go to type definition",
            .references => "find references",
            else => "go to definition",
        };
        const r = self.ready(what) orelse return;
        const supported = switch (kind) {
            .declaration => r.cn.sess.caps.declaration,
            .type_definition => r.cn.sess.caps.type_definition,
            .references => r.cn.sess.caps.references,
            else => r.cn.sess.caps.definition,
        };
        if (!supported) {
            var buf: [160:0]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "Server does not support {s}.", .{what}) catch "Unsupported.";
            self.view.setStatusText(msg);
            return;
        }
        const method = switch (kind) {
            .declaration => "textDocument/declaration",
            .type_definition => "textDocument/typeDefinition",
            .references => "textDocument/references",
            else => "textDocument/definition",
        };
        const extra: []const u8 = if (kind == .references)
            ",\"context\":{\"includeDeclaration\":true}"
        else
            "";
        const params = self.docPosParams(r, r.tab.sels.primary().head, extra) orelse return;
        self.issue(r, kind, method, params, 0);
    }

    fn onLocations(self: *Manager, cn: *Conn, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        _ = cn;
        const tab = maybe_tab orelse return;
        _ = tab;
        if (env.has_error) {
            self.view.setStatusText("The server could not answer that.");
            return;
        }
        self.list.clearItems();
        self.list.mode = .locations;
        self.list.tab_id = req.tab_id;
        self.list.revision = req.revision;
        self.list.filter.clearRetainingCapacity();
        self.collectLocations(env.result);
        if (self.list.items.items.len == 0) {
            self.list.mode = .none;
            self.view.setStatusText("No results.");
            return;
        }
        if (self.list.items.items.len == 1) {
            // One hit is not a choice: jump straight there, the way
            // every editor does.
            const it = self.list.items.items[0];
            self.openLocation(it.payload, it.line, it.col);
            self.list.clearItems();
            self.list.mode = .none;
            return;
        }
        self.applyFilter();
        self.showPopup();
    }

    /// Accepts Location, Location[], LocationLink[] and null.
    fn collectLocations(self: *Manager, v: std.json.Value) void {
        switch (v) {
            .array => |a| {
                for (a.items) |x| {
                    if (self.list.items.items.len >= MAX_ROWS) break;
                    self.collectOneLocation(x);
                }
            },
            .object => self.collectOneLocation(v),
            else => {},
        }
    }

    fn collectOneLocation(self: *Manager, v: std.json.Value) void {
        if (v != .object) return;
        const o = v.object;
        // LocationLink uses targetUri/targetSelectionRange.
        const uri = strOf(o.get("uri")) orelse strOf(o.get("targetUri")) orelse return;
        const rng_val = o.get("range") orelse o.get("targetSelectionRange") orelse o.get("targetRange") orelse .null;
        const rng = pos.parseRange(rng_val);
        const path = (servers.uriToPath(self.alloc, uri) catch return) orelse return;
        defer self.alloc.free(path);
        const spec = std.fmt.allocPrint(self.alloc, "local:{s}", .{path}) catch return;
        const base = servers.basenameOf(path);
        const label = std.fmt.allocPrint(self.alloc, "{s}:{d}", .{ base, rng.start.line + 1 }) catch {
            self.alloc.free(spec);
            return;
        };
        const detail = self.alloc.dupe(u8, path) catch {
            self.alloc.free(spec);
            self.alloc.free(label);
            return;
        };
        self.list.items.append(self.alloc, .{
            .label = label,
            .detail = detail,
            .payload = spec,
            .line = rng.start.line,
            .col = rng.start.character,
        }) catch {};
    }

    /// Open a result. Results land in the SAME editor face, as a tab —
    /// reusing `EditorView.openSpec`, which already focuses an existing
    /// tab for the file instead of opening a second one, and already
    /// carries the "restore this caret once the async load lands"
    /// machinery a jump needs.
    fn openLocation(self: *Manager, spec: []const u8, line: u32, col: u32) void {
        self.view.openSpecAtLineCol(spec, line, col);
    }

    // ---- symbols -----------------------------------------------------------

    /// `documentSymbol` for the OUTLINE PANEL rather than the popup.
    /// Silent (a missing server is not an error the user asked about),
    /// and marked with `aux = OUTLINE_AUX` so the reply is routed to the
    /// panel. @return whether a request actually went out.
    pub fn requestOutlineSymbols(self: *Manager) bool {
        const tab = self.view.activeTab() orelse return false;
        const st = tab.lsp orelse return false;
        const cn = st.conn orelse return false;
        if (cn.sess.state != .ready) return false;
        if (!cn.sess.caps.document_symbol) return false;
        self.flushChanges(tab);
        const r = Ready{ .tab = tab, .st = st, .cn = cn };
        self.scratch.clearRetainingCapacity();
        self.scratch.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return false;
        session.appendJsonString(self.alloc, &self.scratch, st.sync.uri) catch return false;
        self.scratch.appendSlice(self.alloc, "}}") catch return false;
        self.issue(r, .document_symbol, "textDocument/documentSymbol", self.scratch.items, OUTLINE_AUX);
        return true;
    }

    /// `Request.aux` value that means "this documentSymbol reply belongs
    /// to the outline panel".
    pub const OUTLINE_AUX: u64 = 1;

    pub fn requestWorkspaceSymbols(self: *Manager) void {
        const r = self.ready("workspace symbols") orelse return;
        if (!r.cn.sess.caps.workspace_symbol) {
            self.view.setStatusText("Server offers no workspace symbols.");
            return;
        }
        // The query is the word at the caret (or the selection): the
        // popup filters incrementally after that, so there is no second
        // focus-stealing entry to manage.
        const query = self.wordOrSelection(r.tab) orelse "";
        defer if (query.len > 0) self.alloc.free(query);
        self.scratch.clearRetainingCapacity();
        self.scratch.appendSlice(self.alloc, "{\"query\":") catch return;
        session.appendJsonString(self.alloc, &self.scratch, query) catch return;
        self.scratch.appendSlice(self.alloc, "}") catch return;
        self.issue(r, .workspace_symbol, "workspace/symbol", self.scratch.items, 0);
    }

    fn wordOrSelection(self: *Manager, tab: *ETab) ?[]u8 {
        const p = tab.sels.primary();
        if (!p.isCaret()) {
            return vm.selectedText(self.alloc, &tab.doc, &tab.sels) catch null;
        }
        const w = vm.wordRangeAt(self.alloc, &tab.doc, p.head);
        if (w.end() <= w.start()) return null;
        return tab.doc.rope.sliceAlloc(self.alloc, w.start(), w.end()) catch null;
    }

    fn onSymbols(self: *Manager, cn: *Conn, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        // The outline panel asked for this one: it owns the reply, and
        // a failure there is silent (the tree fallback covers it).
        if (req.kind == .document_symbol and req.aux == OUTLINE_AUX) {
            const tab = maybe_tab orelse return;
            if (env.has_error) {
                editoroutline.lspFailed(self.view, tab);
                return;
            }
            const enc = if (tab.lsp) |st| blk: {
                const conn = st.conn orelse break :blk pos.Encoding.utf16;
                break :blk conn.sess.caps.encoding;
            } else pos.Encoding.utf16;
            editoroutline.fillFromLsp(self.view, tab, env.result, enc);
            return;
        }
        if (env.has_error) {
            self.view.setStatusText("The server could not answer that.");
            return;
        }
        self.list.clearItems();
        self.list.mode = .symbols;
        self.list.tab_id = req.tab_id;
        self.list.revision = req.revision;
        self.list.filter.clearRetainingCapacity();
        const own_spec: []const u8 = blk: {
            const tab = maybe_tab orelse break :blk "";
            break :blk tab.spec orelse "";
        };
        _ = cn;
        self.collectSymbols(env.result, own_spec, 0);
        if (self.list.items.items.len == 0) {
            self.list.mode = .none;
            self.view.setStatusText("No symbols.");
            return;
        }
        self.applyFilter();
        self.showPopup();
    }

    /// DocumentSymbol (hierarchical, `selectionRange` + `children`) and
    /// SymbolInformation (flat, `location`) both land here.
    fn collectSymbols(self: *Manager, v: std.json.Value, own_spec: []const u8, depth: usize) void {
        const arr = switch (v) {
            .array => |a| a,
            else => return,
        };
        for (arr.items) |x| {
            if (self.list.items.items.len >= MAX_ROWS) return;
            if (x != .object) continue;
            const o = x.object;
            const name = strOf(o.get("name")) orelse continue;
            var spec: []u8 = &.{};
            var line: u32 = 0;
            var col: u32 = 0;
            if (o.get("location")) |loc| {
                if (loc == .object) {
                    const uri = strOf(loc.object.get("uri")) orelse "";
                    const path = (servers.uriToPath(self.alloc, uri) catch null) orelse null;
                    if (path) |p| {
                        defer self.alloc.free(p);
                        spec = std.fmt.allocPrint(self.alloc, "local:{s}", .{p}) catch continue;
                    }
                    const rng = pos.parseRange(loc.object.get("range") orelse .null);
                    line = rng.start.line;
                    col = rng.start.character;
                }
            } else {
                const rng = pos.parseRange(o.get("selectionRange") orelse o.get("range") orelse .null);
                line = rng.start.line;
                col = rng.start.character;
                spec = self.alloc.dupe(u8, own_spec) catch continue;
            }
            if (spec.len == 0) spec = self.alloc.dupe(u8, own_spec) catch continue;
            // Nesting shows as indentation; a tree widget would add a
            // second navigation model for no extra information.
            var lbuf: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < @min(depth, 6)) : (i += 1) lbuf.appendSlice(self.alloc, "  ") catch {};
            lbuf.appendSlice(self.alloc, name) catch {};
            const label = lbuf.toOwnedSlice(self.alloc) catch {
                self.alloc.free(spec);
                continue;
            };
            const detail = self.alloc.dupe(u8, strOf(o.get("detail")) orelse symbolKindName(o.get("kind"))) catch {
                self.alloc.free(spec);
                self.alloc.free(label);
                continue;
            };
            self.list.items.append(self.alloc, .{
                .label = label,
                .detail = detail,
                .payload = spec,
                .line = line,
                .col = col,
            }) catch {};
            if (o.get("children")) |kids| self.collectSymbols(kids, own_spec, depth + 1);
        }
    }

    // ---- rename ------------------------------------------------------------

    pub fn startRename(self: *Manager) void {
        const r = self.ready("rename") orelse return;
        if (!r.cn.sess.caps.rename) {
            self.view.setStatusText("Server does not support rename.");
            return;
        }
        const current = self.wordOrSelection(r.tab) orelse {
            self.view.setStatusText("Put the caret on a symbol first.");
            return;
        };
        defer self.alloc.free(current);
        self.view.promptRename(current);
    }

    /// Called by EditorView once the user confirmed a new name.
    pub fn submitRename(self: *Manager, new_name: []const u8) void {
        if (new_name.len == 0) return;
        const r = self.ready("rename") orelse return;
        var extra: std.ArrayList(u8) = .empty;
        defer extra.deinit(self.alloc);
        extra.appendSlice(self.alloc, ",\"newName\":") catch return;
        session.appendJsonString(self.alloc, &extra, new_name) catch return;
        const params = self.docPosParams(r, r.tab.sels.primary().head, extra.items) orelse return;
        self.issue(r, .rename, "textDocument/rename", params, 0);
    }

    fn onWorkspaceEdit(self: *Manager, cn: *Conn, req: session.Request, env: rpc.Envelope) void {
        _ = req;
        if (env.has_error) {
            self.view.setStatusText("Rename failed.");
            return;
        }
        const obj = switch (env.result) {
            .object => |o| o,
            else => {
                self.view.setStatusText("Rename produced no changes.");
                return;
            },
        };
        var touched: usize = 0;
        var skipped: usize = 0;
        // `documentChanges` (ordered, versioned) wins over `changes`
        // when both are present, per the spec.
        if (obj.get("documentChanges")) |dc| {
            if (dc == .array) {
                for (dc.array.items) |entry| {
                    if (entry != .object) continue;
                    const td = entry.object.get("textDocument") orelse continue;
                    const uri = strOf(if (td == .object) td.object.get("uri") else null) orelse continue;
                    const edits = entry.object.get("edits") orelse continue;
                    if (self.applyEditsToUri(cn, uri, edits)) touched += 1 else skipped += 1;
                }
            }
        } else if (obj.get("changes")) |ch| {
            if (ch == .object) {
                var it = ch.object.iterator();
                while (it.next()) |kv| {
                    if (self.applyEditsToUri(cn, kv.key_ptr.*, kv.value_ptr.*)) touched += 1 else skipped += 1;
                }
            }
        }
        var buf: [200:0]u8 = undefined;
        const msg = if (skipped > 0)
            std.fmt.bufPrintZ(&buf, "Renamed in {d} file(s); {d} not open (open them and retry).", .{ touched, skipped }) catch "Renamed."
        else
            std.fmt.bufPrintZ(&buf, "Renamed in {d} file(s).", .{touched}) catch "Renamed.";
        self.view.setStatusText(msg);
    }

    /// Apply a `TextEdit[]` to the tab holding `uri`, as ONE
    /// transaction — one undo unit per document.
    ///
    /// Limitation, deliberate and documented: the editor's history is
    /// per Document, so a rename touching three files is three undo
    /// units, one per file. Making it a single unit would need a
    /// cross-document history object that nothing else in the editor
    /// wants. Files that are NOT open are reported rather than edited
    /// behind the user's back.
    fn applyEditsToUri(self: *Manager, cn: *Conn, uri: []const u8, edits: std.json.Value) bool {
        const tab = self.tabForUri(cn, uri) orelse return false;
        return self.applyTextEdits(tab, edits, cn.sess.caps.encoding);
    }

    fn applyTextEdits(self: *Manager, tab: *ETab, edits_val: std.json.Value, enc: pos.Encoding) bool {
        const arr = switch (edits_val) {
            .array => |a| a,
            else => return false,
        };
        if (arr.items.len == 0) return true;

        const Pending = struct { start: usize, end: usize, text: []const u8 };
        var list: std.ArrayList(Pending) = .empty;
        defer list.deinit(self.alloc);
        for (arr.items) |e| {
            if (e != .object) continue;
            const rng = pos.parseRange(e.object.get("range") orelse .null);
            const offs = pos.rangeToOffsets(&tab.doc.rope, rng, enc);
            const text = strOf(e.object.get("newText")) orelse "";
            list.append(self.alloc, .{ .start = offs.start, .end = offs.end, .text = text }) catch return false;
        }
        // LSP TextEdits are all in the ORIGINAL document's coordinates
        // and must not overlap; a Transaction wants them ascending.
        std.mem.sort(Pending, list.items, {}, struct {
            fn less(_: void, a: Pending, b: Pending) bool {
                return a.start < b.start;
            }
        }.less);
        var tx = tr.Transaction.init(tab.doc.revision);
        defer tx.deinit(self.alloc);
        var prev_end: usize = 0;
        for (list.items, 0..) |p, i| {
            // An overlapping pair would make the whole transaction
            // invalid; dropping the later edit is better than applying
            // none, and servers do not produce these in practice.
            if (i > 0 and p.start < prev_end) continue;
            tx.addReplace(self.alloc, p.start, p.end - p.start, p.text) catch return false;
            prev_end = p.end;
        }
        if (tx.edits.items.len == 0) return true;
        const before = vm.snapshotOf(&tab.sels);
        _ = tab.doc.applyTransactionSel(&tx, before) catch return false;
        tab.sels.mapThrough(tx.edits.items, .other);
        vm.clampSelections(&tab.doc, &tab.sels);
        self.view.afterExternalEdit(tab);
        return true;
    }

    // ---- formatting ---------------------------------------------------------

    pub fn requestFormatting(self: *Manager) void {
        const r = self.ready("formatting") orelse return;
        const sel = r.tab.sels.primary();
        const want_range = !sel.isCaret() and r.cn.sess.caps.range_formatting;
        if (!want_range and !r.cn.sess.caps.formatting) {
            self.view.setStatusText("Server offers no formatting.");
            return;
        }
        const enc = r.cn.sess.caps.encoding;
        self.scratch.clearRetainingCapacity();
        self.scratch.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return;
        session.appendJsonString(self.alloc, &self.scratch, r.st.sync.uri) catch return;
        self.scratch.appendSlice(self.alloc, "}") catch return;
        if (want_range) {
            const s = pos.offsetToPosition(&r.tab.doc.rope, sel.start(), enc);
            const e = pos.offsetToPosition(&r.tab.doc.rope, sel.end(), enc);
            self.scratch.print(
                self.alloc,
                ",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
                .{ s.line, s.character, e.line, e.character },
            ) catch return;
        }
        self.scratch.print(
            self.alloc,
            ",\"options\":{{\"tabSize\":{d},\"insertSpaces\":{s}}}}}",
            .{ self.view.tab_width, if (self.view.insert_spaces) "true" else "false" },
        ) catch return;
        self.issue(
            r,
            if (want_range) .range_formatting else .formatting,
            if (want_range) "textDocument/rangeFormatting" else "textDocument/formatting",
            self.scratch.items,
            0,
        );
    }

    fn onFormatting(self: *Manager, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        const tab = maybe_tab orelse return;
        if (env.has_error) {
            self.view.setStatusText("Formatting failed.");
            return;
        }
        // Formatting edits describe the text as it was; applying them
        // to a moved document would scramble it.
        if (tab.doc.revision != req.revision) {
            self.view.setStatusText("Document changed while formatting; try again.");
            return;
        }
        const st = tab.lsp orelse return;
        const cn = st.conn orelse return;
        if (env.result == .null) {
            self.view.setStatusText("Already formatted.");
            return;
        }
        if (self.applyTextEdits(tab, env.result, cn.sess.caps.encoding)) {
            self.view.setStatusText("Formatted.");
        }
    }

    // ---- diagnostics navigation ----------------------------------------------

    pub fn stepDiagnostic(self: *Manager, forward: bool) void {
        const tab = self.view.activeTab() orelse return;
        const st = tab.lsp orelse {
            self.view.setStatusText("No diagnostics.");
            return;
        };
        const next = st.diags.step(tab.sels.primary().head, forward) orelse {
            self.view.setStatusText("No diagnostics.");
            return;
        };
        tab.sels.keepPrimaryOnly();
        tab.sels.sels.items[0] = Selection.caret(@min(next, tab.doc.rope.len()));
        self.view.afterExternalMove(tab);
        if (self.diagnosticTextAtCaret(tab)) |txt| {
            defer self.alloc.free(txt);
            var buf: [220:0]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "{s}", .{txt}) catch return;
            self.view.setStatusText(msg);
        }
    }

    /// Diagnostics for the render pass, or an empty slice when they are
    /// switched off.
    pub fn diagnosticsFor(self: *Manager, tab: *ETab) []const diagnostics.Diagnostic {
        const conf = self.cfg() orelse return &.{};
        if (!conf.editor_lsp_diagnostics) return &.{};
        const st = tab.lsp orelse return &.{};
        return st.diags.items.items;
    }

    /// "3 errors, 1 warning" for the status line; empty when quiet.
    pub fn statusSummary(self: *Manager, tab: *ETab, buf: []u8) []const u8 {
        const st = tab.lsp orelse return "";
        if (st.conn == null) return "";
        if (self.diagnosticTextAtCaret(tab)) |txt| {
            defer self.alloc.free(txt);
            return std.fmt.bufPrint(buf, "  —  {s}", .{txt}) catch "";
        }
        const cnts = st.diags.counts();
        if (cnts.errors == 0 and cnts.warnings == 0) return "";
        return std.fmt.bufPrint(buf, "  —  {d} error(s), {d} warning(s)", .{ cnts.errors, cnts.warnings }) catch "";
    }

    // ---- popup widgets --------------------------------------------------------

    /// HARD INVARIANT for everything inside this popover: its MINIMUM
    /// size must never grow while the popup is open. GTK lays a mapped
    /// popover out at the size of the last xdg_popup configure, and
    /// `gtk_popover_native_layout` POPDOWNS the popover outright when
    /// its minimum no longer fits that size (`is_acceptable_size`).
    /// A same-tick `completionItem/resolve` reply growing the header
    /// used to land exactly between `gdk_popup_present` and the
    /// configure round-trip and silently closed the list — which is
    /// why every label in here is single-line and ellipsized, never
    /// wrapped or unbounded.
    fn ensurePopup(self: *Manager) bool {
        if (self.list.popover != null) return true;
        const pop = c.gtk_popover_new() orelse return false;
        c.gtk_widget_set_parent(pop, @ptrCast(self.view.area));
        c.gtk_popover_set_has_arrow(@ptrCast(pop), 0);
        // NOT autohide: the completion list must not take the keyboard
        // away from the canvas, or every keystroke would have to be
        // forwarded back. The editor's own key handler drives it.
        c.gtk_popover_set_autohide(@ptrCast(pop), 0);
        c.gtk_popover_set_position(@ptrCast(pop), c.GTK_POS_BOTTOM);
        c.gtk_widget_set_can_focus(pop, 0);

        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
        const header = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(header), 0);
        c.gtk_label_set_ellipsize(@ptrCast(header), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(header), 56);
        c.gtk_widget_add_css_class(header, "dim-label");
        c.gtk_box_append(@ptrCast(box), header);
        // The lazily-resolved documentation line. A single-space
        // placeholder keeps the line's height reserved from the first
        // present on (empty -> non-empty would grow the minimum).
        const docl = c.gtk_label_new(" ");
        c.gtk_label_set_xalign(@ptrCast(docl), 0);
        c.gtk_label_set_ellipsize(@ptrCast(docl), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(docl), 56);
        c.gtk_widget_add_css_class(docl, "dim-label");
        c.gtk_box_append(@ptrCast(box), docl);

        const list = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_SINGLE);
        const scroll = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_child(@ptrCast(scroll), list);
        c.gtk_widget_set_size_request(scroll, POPUP_W, POPUP_H);
        c.gtk_box_append(@ptrCast(box), scroll);
        c.gtk_popover_set_child(@ptrCast(pop), box);

        self.list.popover = pop;
        self.list.listbox = @ptrCast(list);
        self.list.scroll = scroll;
        self.list.header = @ptrCast(header);
        self.list.doc_label = @ptrCast(docl);
        return true;
    }

    fn showPopup(self: *Manager) void {
        if (self.view.widgets_dead) return;
        if (!self.ensurePopup()) return;
        dbg("popup: {d} rows ({s})", .{ self.list.shown.items.len, @tagName(self.list.mode) });
        self.rebuildRows();
        self.positionAtCaret(self.list.popover.?);
        c.gtk_popover_popup(@ptrCast(self.list.popover.?));
        self.list.open = true;
        self.resolveSelected();
    }

    pub fn closePopup(self: *Manager) void {
        if (!self.list.open) return;
        self.list.open = false;
        self.list.mode = .none;
        self.list.clearItems();
        self.list.filter.clearRetainingCapacity();
        if (self.list.popover) |p| c.gtk_popover_popdown(@ptrCast(p));
    }

    pub fn popupOpen(self: *const Manager) bool {
        return self.list.open;
    }

    pub fn hoverOpen(self: *const Manager) bool {
        return self.hover.open;
    }

    fn applyFilter(self: *Manager) void {
        self.list.shown.clearRetainingCapacity();
        const f = self.list.filter.items;
        for (self.list.items.items, 0..) |it, i| {
            if (f.len == 0 or subsequenceFold(it.label, f)) {
                self.list.shown.append(self.alloc, i) catch break;
            }
        }
        if (self.list.sel >= self.list.shown.items.len) {
            self.list.sel = if (self.list.shown.items.len == 0) 0 else self.list.shown.items.len - 1;
        }
    }

    fn rebuildRows(self: *Manager) void {
        const lb = self.list.listbox orelse return;
        c.gtk_list_box_remove_all(lb);
        for (self.list.shown.items) |idx| {
            const it = self.list.items.items[idx];
            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
            const name = c.gtk_label_new(null);
            var nbuf: [256:0]u8 = undefined;
            const ntext = std.fmt.bufPrintZ(&nbuf, "{s}", .{it.label}) catch "";
            c.gtk_label_set_text(@ptrCast(name), ntext.ptr);
            c.gtk_label_set_xalign(@ptrCast(name), 0);
            // Ellipsized, or a long symbol would raise the popover's
            // minimum width mid-flight (see ensurePopup's invariant;
            // the scroll's horizontal policy is NEVER, so row minima
            // propagate straight to the popover).
            c.gtk_label_set_ellipsize(@ptrCast(name), c.PANGO_ELLIPSIZE_END);
            c.gtk_label_set_max_width_chars(@ptrCast(name), 40);
            c.gtk_widget_set_hexpand(name, 1);
            c.gtk_box_append(@ptrCast(row), name);
            if (it.detail.len > 0) {
                const det = c.gtk_label_new(null);
                var dbuf: [256:0]u8 = undefined;
                const dtext = std.fmt.bufPrintZ(&dbuf, "{s}", .{it.detail}) catch "";
                c.gtk_label_set_text(@ptrCast(det), dtext.ptr);
                c.gtk_label_set_xalign(@ptrCast(det), 1);
                c.gtk_label_set_ellipsize(@ptrCast(det), c.PANGO_ELLIPSIZE_END);
                c.gtk_label_set_max_width_chars(@ptrCast(det), 24);
                c.gtk_widget_add_css_class(det, "dim-label");
                c.gtk_box_append(@ptrCast(row), det);
            }
            c.gtk_list_box_append(lb, row);
        }
        self.selectRow();
        self.refreshPopupHeader();
    }

    fn selectRow(self: *Manager) void {
        const lb = self.list.listbox orelse return;
        if (self.list.shown.items.len == 0) return;
        const row = c.gtk_list_box_get_row_at_index(lb, @intCast(self.list.sel));
        if (row != null) {
            c.gtk_list_box_select_row(lb, row);
            _ = c.gtk_widget_grab_focus(@ptrCast(row));
            // Keep the canvas focused: grabbing focus above only scrolls
            // the row into view inside a non-autohide popover.
            _ = c.gtk_widget_grab_focus(@ptrCast(self.view.area));
        }
    }

    fn refreshPopupHeader(self: *Manager) void {
        const hdr = self.list.header orelse return;
        const title: []const u8 = switch (self.list.mode) {
            .completion => "Completion",
            .locations => "Results",
            .symbols => "Symbols",
            .none => "",
        };
        var full: [512:0]u8 = undefined;
        const all = std.fmt.bufPrintZ(&full, "{s}  ({d}){s}{s}", .{
            title,
            self.list.shown.items.len,
            if (self.list.filter.items.len > 0) "  filter: " else "",
            if (self.list.filter.items.len > 0) self.list.filter.items else "",
        }) catch return;
        c.gtk_label_set_text(hdr, all.ptr);
        // The selected item's documentation, on its own ellipsized
        // single line (see the invariant on ensurePopup: this label
        // must never change the popover's minimum size).
        var docline: []const u8 = " ";
        if (self.list.mode == .completion and self.list.shown.items.len > 0) {
            const d = self.list.items.items[self.list.shown.items[self.list.sel]].doc;
            if (d.len > 0) docline = d[0 .. std.mem.indexOfScalar(u8, d, '\n') orelse d.len];
        }
        if (self.list.doc_label) |dl| {
            var dbuf: [512:0]u8 = undefined;
            const dz = std.fmt.bufPrintZ(&dbuf, "{s}", .{docline[0..@min(docline.len, 400)]}) catch return;
            c.gtk_label_set_text(dl, if (dz.len > 0) dz.ptr else " ");
        }
    }

    /// Point a popover at the caret, using the SAME geometry the IME
    /// cursor-location call uses — so a completion list and an input
    /// method never disagree about where the caret is.
    fn positionAtCaret(self: *Manager, popover: *c.GtkWidget) void {
        const rect = self.view.caretRectPx() orelse return;
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    }

    // ---- hover popup -----------------------------------------------------------

    fn ensureHover(self: *Manager) bool {
        if (self.hover.popover != null) return true;
        const pop = c.gtk_popover_new() orelse return false;
        c.gtk_widget_set_parent(pop, @ptrCast(self.view.area));
        c.gtk_popover_set_has_arrow(@ptrCast(pop), 1);
        c.gtk_popover_set_autohide(@ptrCast(pop), 0);
        c.gtk_popover_set_position(@ptrCast(pop), c.GTK_POS_BOTTOM);
        c.gtk_widget_set_can_focus(pop, 0);
        const label = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_wrap(@ptrCast(label), 1);
        c.gtk_label_set_selectable(@ptrCast(label), 0);
        c.gtk_widget_set_size_request(label, HOVER_W, -1);
        c.gtk_popover_set_child(@ptrCast(pop), label);
        self.hover.popover = pop;
        self.hover.label = @ptrCast(label);
        return true;
    }

    fn showHover(self: *Manager, text: []const u8) void {
        if (self.view.widgets_dead) return;
        if (!self.ensureHover()) return;
        // Same minimum-size rule as ensurePopup: growing a MAPPED
        // popover's wrap-label while its configure is in flight makes
        // GTK popdown it. Remap instead of mutating in place.
        if (self.hover.open) {
            if (self.hover.popover) |p| c.gtk_popover_popdown(@ptrCast(p));
        }
        const z = self.alloc.dupeZ(u8, text[0..@min(text.len, 4000)]) catch return;
        defer self.alloc.free(z);
        c.gtk_label_set_text(self.hover.label.?, z.ptr);
        self.positionAtCaret(self.hover.popover.?);
        c.gtk_popover_popup(@ptrCast(self.hover.popover.?));
        self.hover.open = true;
    }

    pub fn closeHover(self: *Manager) void {
        if (!self.hover.open) return;
        self.hover.open = false;
        if (self.hover.popover) |p| c.gtk_popover_popdown(@ptrCast(p));
    }

    // ---- key handling -----------------------------------------------------------

    /// Keys the popup claims while it is open. Returns true when the
    /// editor must NOT see the key.
    pub fn handleKey(self: *Manager, keyval: c_uint, ctrl: bool) bool {
        if (self.hover.open) {
            // Any key dismisses hover, and only Escape is swallowed.
            self.closeHover();
            if (keyval == c.GDK_KEY_Escape) return true;
        }
        if (!self.list.open) return false;
        switch (keyval) {
            c.GDK_KEY_Escape => {
                self.closePopup();
                return true;
            },
            c.GDK_KEY_Up, c.GDK_KEY_KP_Up => {
                self.moveSel(-1);
                return true;
            },
            c.GDK_KEY_Down, c.GDK_KEY_KP_Down => {
                self.moveSel(1);
                return true;
            },
            c.GDK_KEY_Page_Up, c.GDK_KEY_KP_Page_Up => {
                self.moveSel(-8);
                return true;
            },
            c.GDK_KEY_Page_Down, c.GDK_KEY_KP_Page_Down => {
                self.moveSel(8);
                return true;
            },
            c.GDK_KEY_Return, c.GDK_KEY_KP_Enter, c.GDK_KEY_Tab => {
                self.accept();
                return true;
            },
            c.GDK_KEY_BackSpace => {
                if (self.list.mode == .symbols or self.list.mode == .locations) {
                    if (self.list.filter.items.len > 0) {
                        _ = self.list.filter.pop();
                        self.applyFilter();
                        self.rebuildRows();
                        return true;
                    }
                    self.closePopup();
                    return true;
                }
                // Completion: the backspace edits the document, and the
                // list re-requests from the new prefix.
                return false;
            },
            else => {},
        }
        if (ctrl) {
            // A chord that is not ours ends the popup rather than being
            // silently eaten.
            self.closePopup();
        }
        return false;
    }

    /// A committed character while a filterable popup is open. Returns
    /// true when the popup consumed it (symbols/locations filter);
    /// completion lets it through so the document keeps up.
    pub fn handleText(self: *Manager, text: []const u8) bool {
        if (!self.list.open) return false;
        if (self.list.mode == .completion) return false;
        for (text) |ch| {
            if (ch < 0x20) continue;
            self.list.filter.append(self.alloc, ch) catch break;
        }
        self.applyFilter();
        self.rebuildRows();
        return true;
    }

    fn moveSel(self: *Manager, delta: isize) void {
        const n = self.list.shown.items.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.list.sel);
        var next = cur + delta;
        if (next < 0) next = @intCast(n - 1);
        if (next >= @as(isize, @intCast(n))) next = 0;
        self.list.sel = @intCast(next);
        self.selectRow();
        self.refreshPopupHeader();
        self.resolveSelected();
    }

    fn accept(self: *Manager) void {
        switch (self.list.mode) {
            .completion => self.acceptCompletion(),
            .locations, .symbols => {
                if (self.list.shown.items.len == 0) return self.closePopup();
                const it = self.list.items.items[self.list.shown.items[self.list.sel]];
                const spec = self.alloc.dupe(u8, it.payload) catch return;
                defer self.alloc.free(spec);
                const line = it.line;
                const col = it.col;
                self.closePopup();
                if (spec.len > 0) self.openLocation(spec, line, col);
            },
            .none => {},
        }
    }

    /// The caret moved or the document changed under an open popup.
    pub fn onCaretMoved(self: *Manager) void {
        self.closeHover();
        if (!self.list.open) return;
        if (self.list.mode != .completion) return;
        const tab = self.view.activeTab() orelse return self.closePopup();
        const caret = tab.sels.primary().head;
        if (caret < self.list.range_start) return self.closePopup();
        self.list.range_end = caret;
        // Re-request against the new prefix, debounced.
        const st = tab.lsp orelse return;
        if (st.completion_timer != 0) return;
        const ctx = TabCtx.create(self, tab) orelse return;
        st.completion_timer = c.g_timeout_add(COMPLETION_DEBOUNCE_MS, @ptrCast(&onCompletionTimer), @ptrCast(ctx));
    }

    fn onCompletionTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const ctx: *TabCtx = @ptrCast(@alignCast(user.?));
        defer ctx.destroy();
        const r = ctx.resolve() orelse return 0;
        const st = r.tab.lsp orelse return 0;
        st.completion_timer = 0;
        if (!r.mgr.list.open or r.mgr.list.mode != .completion) return 0;
        r.mgr.requestCompletion(false);
        return 0;
    }

    /// A trigger character was just typed: pop the list open.
    pub fn maybeTrigger(self: *Manager, text: []const u8) void {
        if (text.len != 1) return;
        const tab = self.view.activeTab() orelse return;
        const st = tab.lsp orelse return;
        const cn = st.conn orelse return;
        if (cn.sess.state != .ready) return;
        if (!cn.sess.caps.isTrigger(text[0])) return;
        self.requestCompletion(false);
    }
};

// ======================================================================
// Fenced timer context
// ======================================================================

/// A deferred callback must survive the tab (and the whole view) being
/// destroyed between queue and dispatch — the same liveness problem
/// `DrainHandle` solves for the terminal, resolved here by re-looking
/// the tab up by id through a manager that the view owns and clears.
const TabCtx = struct {
    mgr: *Manager,
    tab_id: u64,

    fn create(mgr: *Manager, tab: *ETab) ?*TabCtx {
        const self = mgr.alloc.create(TabCtx) catch return null;
        self.* = .{ .mgr = mgr, .tab_id = tab.id };
        return self;
    }

    fn destroy(self: *TabCtx) void {
        self.mgr.alloc.destroy(self);
    }

    fn resolve(self: *TabCtx) ?struct { mgr: *Manager, tab: *ETab } {
        const tab = self.mgr.view.findTabByIdPublic(self.tab_id) orelse return null;
        return .{ .mgr = self.mgr, .tab = tab };
    }
};

// ======================================================================
// Helpers
// ======================================================================

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// `CompletionList` (`{isIncomplete, items}`) and a bare array both
/// occur in the wild.
fn completionItems(v: std.json.Value) ?[]const std.json.Value {
    return switch (v) {
        .array => |a| a.items,
        .object => |o| blk: {
            const items = o.get("items") orelse break :blk null;
            break :blk switch (items) {
                .array => |a| a.items,
                else => null,
            };
        },
        else => null,
    };
}

/// Hover / documentation payloads: `MarkupContent`, `MarkedString`, or
/// an array of either. Flattened to plain text — the editor has no
/// markdown renderer and a popup full of backticks reads worse than
/// the raw source.
fn hoverText(alloc: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendHover(alloc, &out, v);
    return out.toOwnedSlice(alloc);
}

fn appendHover(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: std.json.Value) !void {
    switch (v) {
        .string => |s| try out.appendSlice(alloc, s),
        .array => |a| for (a.items) |x| {
            if (out.items.len > 0) try out.appendSlice(alloc, "\n");
            try appendHover(alloc, out, x);
        },
        .object => |o| {
            if (o.get("contents")) |cts| {
                try appendHover(alloc, out, cts);
                return;
            }
            if (o.get("documentation")) |d| {
                try appendHover(alloc, out, d);
                return;
            }
            if (o.get("value")) |val| {
                try appendHover(alloc, out, val);
                return;
            }
        },
        else => {},
    }
}

fn serializeValue(alloc: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    try std.json.Stringify.value(v, .{}, &w.writer);
    return alloc.dupe(u8, w.written());
}

/// Start of the identifier the caret is inside — the fallback prefix
/// range when a server sends no `textEdit`.
fn wordStart(doc: *const Document, caret: usize) usize {
    // One window read rather than a slice per byte: this runs on every
    // completion request, i.e. potentially every keystroke. An
    // identifier longer than the window simply starts at the window's
    // edge, which only widens the replaced range harmlessly.
    const WINDOW: usize = 256;
    const from = caret -| WINDOW;
    const buf = doc.rope.sliceAlloc(doc.alloc, from, caret) catch return caret;
    defer doc.alloc.free(buf);
    var i: usize = buf.len;
    while (i > 0) {
        const ch = buf[i - 1];
        const wordy = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_' or ch >= 0x80;
        if (!wordy) break;
        i -= 1;
    }
    return from + i;
}

/// Case-insensitive subsequence match — the filtering every fuzzy
/// picker in this codebase already uses.
fn subsequenceFold(haystack: []const u8, needle: []const u8) bool {
    var hi: usize = 0;
    for (needle) |nc| {
        const want = std.ascii.toLower(nc);
        while (hi < haystack.len and std.ascii.toLower(haystack[hi]) != want) hi += 1;
        if (hi == haystack.len) return false;
        hi += 1;
    }
    return true;
}

/// LSP `CompletionItemKind` -> a word for the list's right column.
fn completionKindName(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    const k = switch (val) {
        .integer => |i| i,
        else => return "",
    };
    return switch (k) {
        1 => "text",       2 => "method",    3 => "function",  4 => "constructor",
        5 => "field",      6 => "variable",  7 => "class",     8 => "interface",
        9 => "module",     10 => "property", 11 => "unit",     12 => "value",
        13 => "enum",      14 => "keyword",  15 => "snippet",  16 => "color",
        17 => "file",      18 => "reference", 19 => "folder",  20 => "enum member",
        21 => "constant",  22 => "struct",   23 => "event",    24 => "operator",
        25 => "type parameter",
        else => "",
    };
}

fn symbolKindName(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    const k = switch (val) {
        .integer => |i| i,
        else => return "",
    };
    return switch (k) {
        1 => "file",         2 => "module",   3 => "namespace", 4 => "package",
        5 => "class",        6 => "method",   7 => "property",  8 => "field",
        9 => "constructor",  10 => "enum",    11 => "interface", 12 => "function",
        13 => "variable",    14 => "constant", 15 => "string",   16 => "number",
        17 => "boolean",     18 => "array",   19 => "object",    20 => "key",
        21 => "null",        22 => "enum member", 23 => "struct", 24 => "event",
        25 => "operator",    26 => "type parameter",
        else => "",
    };
}
