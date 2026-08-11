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
//! The server runs NEAR THE FILES: for a `host:/path` spec the daemon
//! on `host` spawns it (`lsp_open`) and bridges its stdio as a byte
//! channel; this file relays the raw JSON-RPC bytes over a dedicated
//! per-host mux connection (`RemoteLink`, watched with `g_unix_fd_add`
//! like every other socket — the connect itself happens on a worker
//! thread because the ssh bootstrap blocks). The `Session`, staleness
//! discipline, position-encoding negotiation and every feature are the
//! LOCAL client unchanged: only `pumpWrite` and the link's frame
//! router know the transport is not a pipe. Discovery is the daemon's:
//! the client ships its ordered candidate list and the daemon answers
//! which server is installed THERE and where the root markers resolve
//! on ITS filesystem. A host whose daemon predates `lsp:true`, has no
//! server installed, or drops the connection degrades silently — the
//! same contract as a missing local server. See docs/lsp.md.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const clock = @import("../util/clock.zig");
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
const semantic = @import("../lsp/semantic.zig");
const inlay = @import("../lsp/inlay.zig");
const layout_mod = @import("../render/editor_layout.zig");
const syntax = @import("../editor/syntax.zig");
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");

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
/// Signature help re-request debounce as the caret walks the argument
/// list. Same reasoning as COMPLETION_DEBOUNCE_MS: the active parameter
/// has to keep up with the typing.
const SIGNATURE_DEBOUNCE_MS: c_uint = 120;
/// Delay before an inlay-hint / semantic-token request goes out after a
/// document or viewport change. Longer than the completion debounce
/// because neither is something the user is waiting on keystroke by
/// keystroke, and both are whole-viewport / whole-document work.
const DECOR_DEBOUNCE_MS: c_uint = 220;
/// Extra lines requested above and below the viewport, so scrolling by
/// a few rows costs no `inlayHint` round trip at all.
const HINT_MARGIN_LINES: u32 = 80;
/// Popup geometry.
const POPUP_W: c_int = 460;
const POPUP_H: c_int = 260;
const HOVER_W: c_int = 520;
/// Signature-help popover width. Fixed, and every label inside it is
/// ellipsized to a fixed character count, because a popover that grows
/// its MINIMUM while mapped is popped down by GTK rather than resized
/// (see the invariant on `ensurePopup`).
const SIG_W: c_int = 560;
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
    /// Debounced signature-help re-request; 0 = idle.
    signature_timer: c_uint = 0,
    /// Debounced inlay-hint / semantic-token refresh; 0 = idle.
    decor_timer: c_uint = 0,

    // ---- display-only decorations ------------------------------------
    //
    // Both are revision-stamped and simply NOT SHOWN when the document
    // has moved on (`Manager.applyDecorations`), which is the same
    // discipline every other request answer follows. Neither is ever
    // carried through an edit the way diagnostics are: a hint or a token
    // span pointing at moved bytes is worse than none.

    /// Inlay hints for the viewport window, owned.
    hints: inlay.Set,
    /// The packed semantic-token array as the server last sent it, kept
    /// so `semanticTokens/full/delta` has something to splice into.
    sem_data: semantic.Data,
    /// …decoded and mapped to document byte ranges + highlight kinds.
    sem_spans: std.ArrayList(layout_mod.SemSpan) = .empty,
    /// Document revision `sem_spans` is exact for, and the render-side
    /// cache key (bumped on every replace).
    sem_revision: u64 = 0,
    sem_generation: u64 = 0,
    /// A semantic-token request is worth making again (the document
    /// changed since the last answer).
    sem_stale: bool = true,
    /// Line window `sem_spans` covers when the server answers only
    /// `semanticTokens/range`. `sem_ranged` says which regime we are in;
    /// in FULL regime the spans cover the document and the window is
    /// meaningless. Scrolling out of the window is what re-asks, exactly
    /// as it is for inlay hints.
    sem_ranged: bool = false,
    sem_from: u32 = 0,
    sem_to: u32 = 0,

    /// True when the current range-mode spans already cover
    /// `[from_line, to_line]`, so a scroll inside them costs no request.
    pub fn semRangeCovers(self: *const TabState, from_line: u32, to_line: u32) bool {
        return self.sem_ranged and from_line >= self.sem_from and to_line <= self.sem_to;
    }

    pub fn create(alloc: std.mem.Allocator, tab: *ETab) ?*TabState {
        const self = alloc.create(TabState) catch return null;
        self.* = .{
            .alloc = alloc,
            .tab = tab,
            .sync = docsync.DocSync.init(alloc),
            .diags = diagnostics.Store.init(alloc),
            .hints = inlay.Set.init(alloc),
            .sem_data = semantic.Data.init(alloc),
        };
        return self;
    }

    pub fn destroy(self: *TabState) void {
        self.stopTimers();
        self.sync.deinit();
        self.diags.deinit();
        self.hints.deinit();
        self.sem_data.deinit();
        self.sem_spans.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn stopTimers(self: *TabState) void {
        for ([_]*c_uint{
            &self.change_timer,
            &self.completion_timer,
            &self.signature_timer,
            &self.decor_timer,
        }) |t| {
            if (t.* != 0) _ = c.g_source_remove(t.*);
            t.* = 0;
        }
    }

    /// Every decoration the server produced is void: the document moved
    /// under it, or the connection went away.
    pub fn dropDecorations(self: *TabState) void {
        self.hints.clear();
        self.sem_data.reset();
        self.sem_spans.clearRetainingCapacity();
        self.sem_generation +%= 1;
        self.sem_revision = 0;
        self.sem_stale = true;
        self.sem_ranged = false;
        self.sem_from = 0;
        self.sem_to = 0;
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
    /// Remote transport: the server runs on the daemon's host and its
    /// stdio rides `link` as chan_data frames for channel `chan`.
    /// Null = local child process. Everything except `pumpWrite` and
    /// teardown is transport-blind.
    remote: ?Remote = null,
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
            .on_apply_edit = onApplyEdit,
        };
    }

    /// The server asked us to write a `WorkspaceEdit` — how a code
    /// action that carries only a `command` gets its work done.
    fn onApplyEdit(ctx: *anyopaque, params: std.json.Value) bool {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        if (self.closing) return false;
        const edit = switch (params) {
            .object => |o| o.get("edit") orelse std.json.Value.null,
            else => std.json.Value.null,
        };
        const r = self.mgr.applyWorkspaceEdit(self, edit);
        self.mgr.reportEditOutcome(r);
        // An edit whose files all had to be OPENED has applied nothing
        // yet but is not a refusal — `applied:false` would make the
        // server think its command failed.
        return r.touched + r.opened > 0;
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

    pub const Remote = struct {
        link: *RemoteLink,
        chan: u32,
        /// False once chan_close went out (or came in) — nothing may
        /// be queued for the channel after that.
        open: bool = true,
    };

    /// Push whatever the session queued into the server's stdin.
    /// Installs a writable watch only when the pipe is full, so the
    /// common case costs one write() and no GLib source.
    ///
    /// Remote transport: the bytes become chan_data frames on the
    /// link's mux connection instead — the link owns the partial-write
    /// buffering (its own G_IO_OUT watch), so the whole queue moves at
    /// once.
    fn pumpWrite(self: *Conn) void {
        if (self.remote) |*rm| {
            if (self.sess.out.items.len == 0) return;
            defer {
                self.sess.out.clearRetainingCapacity();
                self.out_pos = 0;
            }
            if (!rm.open or rm.link.state != .up) return;
            const CHUNK: usize = 1 << 20;
            var off: usize = 0;
            const bytes = self.sess.out.items;
            while (off < bytes.len) {
                const end = @min(off + CHUNK, bytes.len);
                const payload = self.mgr.alloc.alloc(u8, 4 + (end - off)) catch {
                    self.sess.markDead();
                    return;
                };
                defer self.mgr.alloc.free(payload);
                std.mem.writeInt(u32, payload[0..4], rm.chan, .little);
                @memcpy(payload[4..], bytes[off..end]);
                rm.link.conn.queueFrame(.chan_data, payload) catch {
                    rm.link.markDead();
                    return;
                };
                off = end;
            }
            rm.link.armWriteWatch();
            return;
        }
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
        const self = cast.userData(Conn, user);
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
        const self = cast.userData(Conn, user);
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
        const self = cast.userData(Conn, user);
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
        const mgr = self.mgr;
        var drop_link: ?*RemoteLink = null;
        if (self.remote) |*rm| {
            // Tell the daemon to take the server down (SIGTERM its
            // group). A dropped link needs nothing: client death kills
            // the channel and its child daemon-side.
            if (rm.open and rm.link.state == .up) {
                var hdr: [4]u8 = undefined;
                rm.link.conn.queueFrame(.chan_close, wire.putChanHeader(&hdr, rm.chan)) catch {};
                rm.link.armWriteWatch();
            }
            rm.open = false;
            drop_link = rm.link;
            self.remote = null;
        }
        self.child.killHard();
        self.child.closePipes();
        _ = self.child.reap();
        self.sess.deinit();
        const a = mgr.alloc;
        a.free(self.name);
        a.free(self.root);
        a.free(self.root_uri);
        a.destroy(self);
        // After the free: the idle-link scan must not see this Conn.
        if (drop_link) |link| mgr.maybeDropLink(link);
    }
};

// ======================================================================
// Remote links: one mux connection per host, carrying LSP byte channels
// ======================================================================

/// A dedicated mux connection to one remote host, used ONLY for LSP
/// traffic (fs jobs make their own short-lived connections; sharing
/// one would tangle this link's frame stream with request/reply
/// pumps). Established on a worker thread — the ssh bootstrap blocks —
/// then watched on the GLib loop like every other socket. Owned by the
/// Manager; dropped when the last remote Conn on it goes away. A link
/// that failed to connect, or whose daemon does not advertise
/// `lsp:true`, stays recorded as `.dead` so repeated attaches on that
/// host cost nothing (and stay silent).
pub const RemoteLink = struct {
    mgr: *Manager,
    /// Host part of the spec ("box", "user@box", "udp:box"), owned.
    host: []u8,
    state: enum { connecting, up, dead } = .connecting,
    /// Valid only while `.up`.
    conn: muxclient.Conn = undefined,
    watch_in: c_uint = 0,
    watch_out: c_uint = 0,
    next_req: u32 = 1,
    /// lsp_open requests in flight.
    pending: std.ArrayList(Pending) = .empty,
    /// Tabs parked here until the connect worker hands the socket back.
    waiting: std.ArrayList(u64) = .empty,

    const Pending = struct { req: u32, tab_id: u64 };

    fn destroyLink(self: *RemoteLink) void {
        self.dropLinkWatches();
        if (self.state == .up) self.conn.deinit();
        self.state = .dead;
        const a = self.mgr.alloc;
        self.pending.deinit(a);
        self.waiting.deinit(a);
        a.free(self.host);
        a.destroy(self);
    }

    fn dropLinkWatches(self: *RemoteLink) void {
        for ([_]*c_uint{ &self.watch_in, &self.watch_out }) |w| {
            if (w.* != 0) _ = c.g_source_remove(w.*);
            w.* = 0;
        }
    }

    /// The transport failed (EOF, write error, hangup): every server
    /// on it is gone. The record stays `.dead` in the Manager's list
    /// so later attaches on this host degrade silently instead of
    /// redialing per document.
    fn markDead(self: *RemoteLink) void {
        if (self.state == .dead) return;
        const was_up = self.state == .up;
        self.state = .dead;
        dbg("link {s}: dead", .{self.host});
        self.dropLinkWatches();
        if (was_up) self.conn.deinit();
        self.pending.clearRetainingCapacity();
        self.waiting.clearRetainingCapacity();
        // markDead on each session routes through onServerDead, which
        // detaches tabs and clears decorations — the same path a local
        // server crash takes.
        for (self.mgr.conns.items) |cn| {
            if (cn.remote) |*rm| {
                if (rm.link == self) {
                    rm.open = false;
                    cn.sess.markDead();
                }
            }
        }
    }

    /// Non-blocking flush; a short write leaves the rest in the mux
    /// Conn's wbuf and a G_IO_OUT watch drains it.
    fn armWriteWatch(self: *RemoteLink) void {
        if (self.state != .up) return;
        self.conn.flushQueued() catch {
            self.markDead();
            return;
        };
        if (self.conn.wbuf.items.len > 0 and self.watch_out == 0) {
            self.watch_out = c.g_unix_fd_add(
                self.conn.fd,
                c.G_IO_OUT | c.G_IO_ERR | c.G_IO_HUP,
                @ptrCast(&onLinkWritable),
                @ptrCast(self),
            );
        }
    }

    fn onLinkWritable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(RemoteLink, user);
        if (self.state != .up) {
            self.watch_out = 0;
            return 0;
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_out = 0;
            self.markDead();
            return 0;
        }
        self.conn.flushQueued() catch {
            self.watch_out = 0;
            self.markDead();
            return 0;
        };
        if (self.conn.wbuf.items.len == 0) {
            self.watch_out = 0;
            return 0;
        }
        return 1;
    }

    fn onLinkReadable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(RemoteLink, user);
        if (self.state != .up) {
            self.watch_in = 0;
            return 0;
        }
        if (!self.conn.fillAvailable()) {
            self.watch_in = 0;
            self.markDead();
            return 0;
        }
        while (true) {
            const maybe = self.conn.takeFrame() catch {
                self.watch_in = 0;
                self.markDead();
                return 0;
            };
            const f = maybe orelse break;
            defer f.deinit(self.conn.allocator);
            self.handleFrame(f);
            if (self.state != .up) {
                self.watch_in = 0;
                return 0;
            }
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_in = 0;
            self.markDead();
            return 0;
        }
        // Handlers may have queued replies (didOpen after ready, …).
        self.armWriteWatch();
        return 1;
    }

    fn connByChan(self: *RemoteLink, chan: u32) ?*Conn {
        for (self.mgr.conns.items) |cn| {
            if (cn.closing) continue;
            if (cn.remote) |*rm| {
                if (rm.link == self and rm.chan == chan) return cn;
            }
        }
        return null;
    }

    fn handleFrame(self: *RemoteLink, f: muxclient.Conn.OwnedFrame) void {
        switch (f.ftype) {
            .lsp_reply => self.mgr.onLspReply(self, f.payload),
            .chan_data => {
                const id = wire.decodeChanId(f.payload) orelse return;
                const cn = self.connByChan(id) orelse return;
                cn.sess.feed(f.payload[4..]);
                if (cn.sess.state != .dead) cn.pumpWrite();
            },
            .chan_close => {
                const id = wire.decodeChanId(f.payload) orelse return;
                const cn = self.connByChan(id) orelse return;
                if (cn.remote) |*rm| rm.open = false;
                // Same as a local server's stdout EOF.
                cn.sess.markDead();
            },
            // Anything else on this dedicated connection (peer_info,
            // marker pushes, …) is not for us.
            else => {},
        }
    }

    /// Queue an lsp_open for `tab`'s document, once. The candidate
    /// list is the CLIENT's config; which of them is installed — and
    /// where the root markers resolve — only the remote host can say.
    fn sendOpen(self: *RemoteLink, tab: *ETab) void {
        if (self.state != .up) return;
        for (self.pending.items) |p| {
            if (p.tab_id == tab.id) return;
        }
        const mgr = self.mgr;
        const conf = mgr.cfg() orelse return;
        const spec = tab.spec orelse return;
        const loc = paths.parseSpec(spec);
        const lang = servers.languageId(loc.path);
        if (lang.len == 0) return;
        const candidates = conf.lspServerCandidates(lang, mgr.alloc) catch return;
        defer mgr.alloc.free(candidates);
        if (candidates.len == 0) return;
        const req = self.next_req;
        self.next_req += 1;
        self.pending.append(mgr.alloc, .{ .req = req, .tab_id = tab.id }) catch return;
        dbg("link {s}: lsp_open req={d} dir={s} ({d} candidates)", .{ self.host, req, servers.dirnameOf(loc.path), candidates.len });
        self.conn.queueJson(.lsp_open, .{
            .req = req,
            .dir = servers.dirnameOf(loc.path),
            .servers = candidates,
        }) catch {
            self.markDead();
            return;
        };
        self.armWriteWatch();
    }

    fn takePending(self: *RemoteLink, req: u32) ?u64 {
        for (self.pending.items, 0..) |p, i| {
            if (p.req == req) {
                _ = self.pending.swapRemove(i);
                return p.tab_id;
            }
        }
        return null;
    }

    /// Ask the daemon to close (and thereby kill) a channel we ended
    /// up not using — a reply for a tab that closed meanwhile, or a
    /// duplicate spawn that lost the (name, root) dedupe race.
    fn discardChannel(self: *RemoteLink, chan: u32) void {
        if (self.state != .up) return;
        var hdr: [4]u8 = undefined;
        self.conn.queueFrame(.chan_close, wire.putChanHeader(&hdr, chan)) catch {
            self.markDead();
            return;
        };
        self.armWriteWatch();
    }
};

/// The blocking half of a link connect: ssh bootstrap + hello/welcome
/// on a g_thread, handed back to the GLib loop via idle. The fence
/// carries "is the EditorView still alive" across the gap.
const LinkJob = struct {
    fence: *editorview.Fence,
    /// Owned by the job (the link's copy may be freed while we run).
    host: []u8,
    conn: muxclient.Conn = undefined,
    ok: bool = false,
    lsp: bool = false,

    fn destroy(self: *LinkJob) void {
        const a = std.heap.c_allocator;
        a.free(self.host);
        self.fence.unref();
        a.destroy(self);
    }
};

fn linkThread(data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const job = cast.userData(LinkJob, data);
    const a = std.heap.c_allocator;
    run: {
        var config = Config.load(a);
        defer config.deinit();
        const conn = muxclient.Conn.connectRemote(a, job.host, config.udpRange()) catch break :run;
        job.conn = conn;
        job.ok = true;
        job.lsp = conn.lsp_support;
    }
    _ = c.g_idle_add(@ptrCast(&linkIdle), @ptrCast(job));
    return null;
}

fn linkIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(LinkJob, user);
    defer job.destroy();
    const view = job.fence.viewIfAlive() orelse {
        if (job.ok) job.conn.deinit();
        return 0;
    };
    const mgr = view.lsp orelse {
        if (job.ok) job.conn.deinit();
        return 0;
    };
    mgr.onLinkConnected(job);
    return 0;
}

// ======================================================================
// Popup list (completion / locations / symbols)
// ======================================================================

const Mode = enum { none, completion, locations, symbols, actions };

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
    /// Point the popover HERE instead of at the caret — a dwell hover
    /// describes what is under the pointer, so anchoring it to the
    /// caret would put the answer next to unrelated text.
    at: ?c.GdkRectangle = null,
};

/// Signature help. Its own popover rather than a mode of the list,
/// because it coexists with the completion list (VS Code shows both)
/// and must therefore be able to be open at the same time.
///
/// Every label in it is single-line and ellipsized with a fixed
/// `max_width_chars`, and the whole popover carries a fixed width
/// request. That is not cosmetic: a MAPPED popover whose minimum grows
/// is popped down by GTK, and this widget's content changes on nearly
/// every keystroke (see the invariant on `ensurePopup`).
const SigPopup = struct {
    mgr: *Manager,
    popover: ?*c.GtkWidget = null,
    /// "1/2  foo(a: int, b: int)".
    label: ?*c.GtkLabel = null,
    /// The active parameter's documentation, or the signature's.
    doc_label: ?*c.GtkLabel = null,
    open: bool = false,
    /// Byte offset the current help was requested at; the caret moving
    /// BEFORE it means the call being described is gone.
    anchor: usize = 0,
};

// ======================================================================
// Manager: one per EditorView
// ======================================================================

/// A `WorkspaceEdit` entry for a file that was not open. The tab is
/// opened and the edits ride here until its bytes arrive; the encoding
/// is captured now because the connection that produced them may be
/// gone by then, and it is the only thing `applyTextEdits` needs from it.
const PendingEdit = struct {
    /// Tab spec (`local:/path` or `host:/path`), owned.
    spec: []u8,
    /// The `TextEdit[]` re-serialized, owned — a `std.json.Value`
    /// borrows its parse arena, which dies with the response.
    edits: []u8,
    enc: pos.Encoding,
};

pub const Manager = struct {
    view: *EditorView,
    alloc: std.mem.Allocator,
    conns: std.ArrayList(*Conn) = .empty,
    /// One per remote host with (past or present) LSP traffic. Dead
    /// entries stay recorded so a host that failed once degrades
    /// silently instead of redialing per document.
    links: std.ArrayList(*RemoteLink) = .empty,
    list: ListPopup = undefined,
    hover: HoverPopup = undefined,
    sig: SigPopup = undefined,
    /// Scratch for building JSON params.
    scratch: std.ArrayList(u8) = .empty,
    /// Render-side view of the active tab's inlay hints. The layout
    /// takes plain `(offset, text)` pairs and deliberately knows nothing
    /// about `src/lsp/`, so this is where the two shapes meet. Rebuilt
    /// once per frame for ONE tab, so it is a viewport's worth of
    /// entries, not a document's.
    hint_view: std.ArrayList(layout_mod.InlayHint) = .empty,
    /// Mouse-dwell hover: the pointer's last position and the timer
    /// that fires if it stops moving. A request is issued from the
    /// TIMER, never from a motion event.
    dwell_timer: c_uint = 0,
    dwell_x: f64 = 0,
    dwell_y: f64 = 0,
    /// Byte offset the last dwell request was made for — a pointer
    /// wandering within one word must not re-ask.
    dwell_offset: usize = std.math.maxInt(usize),
    /// `TextEdit[]`s from a `WorkspaceEdit` whose file had no tab yet.
    /// The tab has been asked to open; the edits apply when its async
    /// load lands (`onDocumentReplaced`). See `applyWorkspaceEdit`.
    pending_edits: std.ArrayList(PendingEdit) = .empty,
    /// How many of the current WorkspaceEdit's files have been written
    /// so far, for the "…and here is the final count" status line the
    /// deferred half owes the user.
    pending_touched: usize = 0,

    pub fn create(view: *EditorView) ?*Manager {
        const self = view.allocator.create(Manager) catch return null;
        self.* = .{ .view = view, .alloc = view.allocator };
        self.list = .{ .mgr = self };
        self.hover = .{ .mgr = self };
        self.sig = .{ .mgr = self };
        return self;
    }

    pub fn destroy(self: *Manager) void {
        self.cancelDwell();
        self.closePopup();
        self.closeHover();
        self.closeSignature();
        self.unparentPopups();
        // Pop-based: Conn.destroy scans the live conns (and can drop
        // an idle link), so neither list may hold freed pointers
        // mid-loop.
        while (self.conns.pop()) |cn| cn.destroy();
        self.conns.deinit(self.alloc);
        while (self.links.pop()) |link| link.destroyLink();
        self.links.deinit(self.alloc);
        self.list.deinit();
        self.dropPendingEdits();
        self.pending_edits.deinit(self.alloc);
        self.hint_view.deinit(self.alloc);
        self.scratch.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Popovers are parented to the GL area with `gtk_widget_set_parent`
    /// and MUST be unparented before it finalizes, or GTK warns
    /// "Finalizing GtkGLArea, but it still has children left" (the same
    /// rule menu.zig documents).
    pub fn unparentPopups(self: *Manager) void {
        for ([_]?*c.GtkWidget{ self.list.popover, self.hover.popover, self.sig.popover }) |maybe| {
            const w = maybe orelse continue;
            if (c.gtk_widget_get_parent(w) != null) c.gtk_widget_unparent(w);
        }
        self.list.popover = null;
        self.hover.popover = null;
        self.sig.popover = null;
        self.list.listbox = null;
        self.list.scroll = null;
        self.list.header = null;
        self.list.doc_label = null;
        self.hover.label = null;
        self.sig.label = null;
        self.sig.doc_label = null;
    }

    fn cfg(self: *Manager) ?*const Config {
        if (self.view.ownerWindow()) |win| return &win.config;
        return self.view.standalone_config;
    }

    // ---- connections --------------------------------------------------

    fn findConn(self: *Manager, name: []const u8, root: []const u8) ?*Conn {
        for (self.conns.items) |cn| {
            if (cn.closing) continue;
            if (cn.remote != null) continue;
            if (std.mem.eql(u8, cn.name, name) and std.mem.eql(u8, cn.root, root)) return cn;
        }
        return null;
    }

    /// A live remote server for (host, name, root). Dead sessions are
    /// skipped: reusing one would attach the tab to a server that will
    /// never answer, where a fresh lsp_open might succeed.
    fn findRemoteConn(self: *Manager, link: *RemoteLink, name: []const u8, root: []const u8) ?*Conn {
        for (self.conns.items) |cn| {
            if (cn.closing or cn.sess.state == .dead) continue;
            const rm = cn.remote orelse continue;
            if (rm.link != link) continue;
            if (std.mem.eql(u8, cn.name, name) and std.mem.eql(u8, cn.root, root)) return cn;
        }
        return null;
    }

    fn findLink(self: *Manager, host: []const u8) ?*RemoteLink {
        for (self.links.items) |link| {
            if (std.mem.eql(u8, link.host, host)) return link;
        }
        return null;
    }

    /// Start connecting to `host`'s daemon on a worker thread (the ssh
    /// bootstrap blocks). The link is listed immediately in
    /// `.connecting` state so attaches can park on it.
    fn startLink(self: *Manager, host: []const u8) ?*RemoteLink {
        const link = self.alloc.create(RemoteLink) catch return null;
        const host_dup = self.alloc.dupe(u8, host) catch {
            self.alloc.destroy(link);
            return null;
        };
        link.* = .{ .mgr = self, .host = host_dup };
        self.links.append(self.alloc, link) catch {
            self.alloc.free(host_dup);
            self.alloc.destroy(link);
            return null;
        };
        const job = std.heap.c_allocator.create(LinkJob) catch {
            link.state = .dead;
            return link;
        };
        const job_host = std.heap.c_allocator.dupe(u8, host) catch {
            std.heap.c_allocator.destroy(job);
            link.state = .dead;
            return link;
        };
        self.view.fence.ref();
        job.* = .{ .fence = self.view.fence, .host = job_host };
        const th = c.g_thread_new("sketerm-lsplink", @ptrCast(&linkThread), @ptrCast(job));
        if (th == null) {
            job.destroy();
            link.state = .dead;
            return link;
        }
        c.g_thread_unref(th);
        dbg("link {s}: connecting", .{host});
        return link;
    }

    /// The connect worker handed the socket back (or failed).
    fn onLinkConnected(self: *Manager, job: *LinkJob) void {
        const link = self.findLink(job.host) orelse {
            if (job.ok) job.conn.deinit();
            return;
        };
        if (link.state != .connecting) {
            if (job.ok) job.conn.deinit();
            return;
        }
        if (!job.ok or !job.lsp) {
            dbg("link {s}: {s}", .{ link.host, if (!job.ok) "connect failed" else "daemon has no lsp support" });
            link.state = .dead;
            link.waiting.clearRetainingCapacity();
            return;
        }
        link.conn = job.conn;
        link.conn.setNonBlocking();
        link.state = .up;
        link.watch_in = c.g_unix_fd_add(
            link.conn.fd,
            c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP,
            @ptrCast(&RemoteLink.onLinkReadable),
            @ptrCast(link),
        );
        dbg("link {s}: up", .{link.host});
        // Everything that parked while we dialed.
        var i: usize = 0;
        while (i < link.waiting.items.len) : (i += 1) {
            const tab = self.view.findTabByIdPublic(link.waiting.items[i]) orelse continue;
            link.sendOpen(tab);
        }
        link.waiting.clearRetainingCapacity();
    }

    /// Drop `link` when nothing references it any more — the remote
    /// mirror of "the last tab out shuts the server down". Called
    /// after a remote Conn is destroyed.
    fn maybeDropLink(self: *Manager, link: *RemoteLink) void {
        if (link.state == .connecting) return;
        if (link.pending.items.len > 0 or link.waiting.items.len > 0) return;
        for (self.conns.items) |cn| {
            if (cn.remote) |*rm| {
                if (rm.link == link) return;
            }
        }
        for (self.links.items, 0..) |x, i| {
            if (x != link) continue;
            _ = self.links.orderedRemove(i);
            break;
        }
        dbg("link {s}: dropped (idle)", .{link.host});
        link.destroyLink();
    }

    /// `lsp_reply` from a host's daemon: it picked a server, resolved
    /// the root on ITS filesystem, and spawned — or found nothing, in
    /// which case the tab silently stays serverless.
    fn onLspReply(self: *Manager, link: *RemoteLink, payload: []const u8) void {
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            chan: u32 = 0,
            name: []const u8 = "",
            root: []const u8 = "",
        };
        var parsed = std.json.parseFromSlice(Reply, self.alloc, payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        const rep = parsed.value;
        const tab_id = link.takePending(rep.req) orelse {
            if (rep.ok) link.discardChannel(rep.chan);
            return;
        };
        if (!rep.ok) {
            dbg("link {s}: no server for req {d} (remote host has none installed)", .{ link.host, rep.req });
            return;
        }
        const tab = self.view.findTabByIdPublic(tab_id) orelse {
            // Closed while the request was in flight; the channel's
            // server was spawned for nothing — take it down.
            link.discardChannel(rep.chan);
            return;
        };
        dbg("link {s}: {s} root={s} chan={d}", .{ link.host, rep.name, rep.root, rep.chan });
        if (self.findRemoteConn(link, rep.name, rep.root)) |existing| {
            // Two documents of one project raced their lsp_opens: keep
            // the first server, kill the duplicate.
            link.discardChannel(rep.chan);
            self.bindTabToConn(tab, existing);
            return;
        }
        const cn = self.createRemoteConn(link, rep.name, rep.root, rep.chan) orelse {
            link.discardChannel(rep.chan);
            return;
        };
        self.bindTabToConn(tab, cn);
    }

    fn createRemoteConn(self: *Manager, link: *RemoteLink, name: []const u8, root: []const u8, chan: u32) ?*Conn {
        const cn = self.alloc.create(Conn) catch return null;
        const name_dup = self.alloc.dupe(u8, name) catch {
            self.alloc.destroy(cn);
            return null;
        };
        const root_dup = self.alloc.dupe(u8, root) catch {
            self.alloc.free(name_dup);
            self.alloc.destroy(cn);
            return null;
        };
        const root_uri = servers.pathToUri(self.alloc, root) catch {
            self.alloc.free(name_dup);
            self.alloc.free(root_dup);
            self.alloc.destroy(cn);
            return null;
        };
        cn.* = .{
            .mgr = self,
            .name = name_dup,
            .root = root_dup,
            .root_uri = root_uri,
            .remote = .{ .link = link, .chan = chan },
            .sess = undefined,
        };
        cn.sess = session.Session.init(self.alloc, cn.handler());
        self.conns.append(self.alloc, cn) catch {
            cn.sess.deinit();
            self.alloc.free(cn.name);
            self.alloc.free(cn.root);
            self.alloc.free(cn.root_uri);
            self.alloc.destroy(cn);
            return null;
        };
        // init_options stays a CLIENT concern (it travels inside
        // `initialize`); find the config record the daemon's pick
        // corresponds to. pid 0 = "no processId": ours means nothing
        // on the server's host, and clangd exits when the advertised
        // pid does not exist.
        var init_options: []const u8 = "";
        if (self.cfg()) |conf| {
            const list = conf.lspServerList(self.alloc) catch &.{};
            defer self.alloc.free(list);
            for (list) |srv| {
                if (std.mem.eql(u8, srv.name, name)) {
                    init_options = srv.init_options;
                    break;
                }
            }
            cn.sess.start(cn.root_uri, 0, init_options);
        } else cn.sess.start(cn.root_uri, 0, "");
        cn.pumpWrite();
        return cn;
    }

    /// The transport-blind bottom half of an attach: point the tab's
    /// state at `cn` and open the document once both sides are ready.
    /// Shared by the local spawn path and the remote reply path.
    fn bindTabToConn(self: *Manager, tab: *ETab, cn: *Conn) void {
        const spec = tab.spec orelse return;
        const loc = paths.parseSpec(spec);
        const lang = servers.languageId(loc.path);
        if (lang.len == 0) return;
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
        const uri = servers.pathToUri(self.alloc, loc.path) catch return;
        defer self.alloc.free(uri);
        st.sync.setUri(uri) catch return;
        tab.doc.addObserver(.{ .ctx = st, .before_apply = TabState.observeEdits });
        if (cn.sess.state == .ready) self.openDocument(tab, st);
    }

    /// Attach a REMOTE document: park it on (or dial) the host's link;
    /// the daemon answers which server exists there. Every failure on
    /// this path is silent, like the local one.
    fn attachRemote(self: *Manager, tab: *ETab, host: []const u8, path: []const u8) void {
        const conf = self.cfg() orelse return;
        const lang = servers.languageId(path);
        if (lang.len == 0) return;
        // No candidate even claims the language: never dial a host
        // for a document nothing could serve.
        const candidates = conf.lspServerCandidates(lang, self.alloc) catch return;
        const any = candidates.len > 0;
        self.alloc.free(candidates);
        if (!any) return;
        if (tab.lsp) |st| {
            if (st.conn != null) return; // already served
        }
        const link = self.findLink(host) orelse self.startLink(host) orelse return;
        switch (link.state) {
            .dead => {},
            .up => link.sendOpen(tab),
            .connecting => {
                for (link.waiting.items) |id| {
                    if (id == tab.id) return;
                }
                link.waiting.append(self.alloc, tab.id) catch {};
            },
        }
    }

    fn commandInstalled(ctx: ?*anyopaque, command: []const u8) bool {
        const self = cast.userData(Manager, ctx);
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
            st.dropDecorations();
        }
        if (self.list.open and self.list.mode != .none) self.closePopup();
        self.closeSignature();
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
        // Remote documents: the server must run near the files, so the
        // HOST's daemon spawns it and relays its stdio (a local server
        // would resolve every import against the wrong filesystem).
        // Async by nature — the reply lands in `onLspReply`.
        if (loc.host) |host| {
            self.attachRemote(tab, host, loc.path);
            return;
        }
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
        self.bindTabToConn(tab, cn);
    }

    /// Send `didOpen`, but only once the document actually HAS its
    /// content.
    ///
    /// A tab is created and attached to a server the moment the user
    /// asks for a file; its bytes arrive later, on the async load
    /// (`EditorView.newTab` -> attach, load lands -> onDocumentReplaced).
    /// Opening here regardless is what used to make every session start
    /// with a zero-byte `didOpen` followed by a full-replace
    /// `didChange` — provably equivalent, and wrong: `languageId` and
    /// the first parse are what a server does its one-time indexing
    /// work from, and an empty file is a bad thing to hand it.
    ///
    /// So a LOADING tab is skipped and the load's own
    /// `onDocumentReplaced` opens it. Nothing is stranded: that path
    /// calls back in here, and so does `onServerReady` for a document
    /// that finished loading before the server finished starting.
    fn openDocument(self: *Manager, tab: *ETab, st: *TabState) void {
        const cn = st.conn orelse return;
        if (st.sync.open) return;
        // Before `.ready` the session refuses notifications, so marking
        // the document open here would strand it: `onServerReady` skips
        // documents it believes are already open, and the server would
        // never see this one at all.
        if (cn.sess.state != .ready) return;
        if (tab.loading) {
            dbg("didOpen deferred for {s}: still loading", .{st.sync.uri});
            return;
        }
        const text = tab.doc.textAlloc(self.alloc) catch return;
        defer self.alloc.free(text);
        st.sync.version = 1;
        dbg("didOpen {s} ({s}, {d} bytes)", .{ st.sync.uri, st.sync.language_id, text.len });
        cn.sess.didOpen(st.sync.uri, st.sync.language_id, st.sync.version, text);
        st.sync.open = true;
        st.sync.clearQueue();
        st.sync.needs_full = false;
        st.dropDecorations();
        cn.pumpWrite();
        self.armDecorations(tab);
    }

    /// The async load finished with nothing to load (a new file): there
    /// is no document-replace to ride on, so open it from here.
    pub fn ensureOpen(self: *Manager, tab: *ETab) void {
        const st = tab.lsp orelse {
            self.attachTab(tab);
            return;
        };
        if (st.conn == null) {
            self.attachTab(tab);
            return;
        }
        self.openDocument(tab, st);
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
        const cn = cast.userData(Conn, user);
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
        self.closeSignature();
        self.cancelDwell();
        // The layout borrows the decoration arrays this state owns.
        tab.layout.sem = &.{};
        tab.layout.sem_gen = 0;
        tab.layout.hints = &.{};
        tab.layout.hints_gen = 0;
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
        // Hints and token spans describe bytes that just moved. They
        // are dropped rather than mapped: a decoration in the wrong
        // place is worse than none, and the refresh is one round trip.
        st.sem_stale = true;
        st.hints.valid = false;
        self.armDecorations(tab);
        if (!st.sync.hasPendingChanges()) return;
        if (st.change_timer != 0) return;
        const ms: c_uint = if (self.cfg()) |conf| @max(10, conf.editor_lsp_debounce_ms) else 250;
        const ctx = TabCtx.create(self, tab) orelse return;
        st.change_timer = c.g_timeout_add(ms, @ptrCast(&onChangeTimer), @ptrCast(ctx));
    }

    fn onChangeTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const ctx = cast.userData(TabCtx, user);
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
        // A WorkspaceEdit for a file that had no tab opened one; its
        // bytes have just arrived, so its edits apply now. Done BEFORE
        // the sync bookkeeping below so the server is told about the
        // final text in one didChange rather than two.
        const drained = self.drainPendingEdits(tab);
        if (drained > 0) {
            self.pending_touched += drained;
            self.reportDeferredEdits();
        }
        const st = tab.lsp orelse {
            self.attachTab(tab);
            return;
        };
        st.diags.clear();
        st.diags.published = false;
        st.sync.clearQueue();
        st.sync.needs_full = false;
        st.dropDecorations();
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
        self.armDecorations(tab);
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
        // The raw JSON is owned HERE until `Store.replace` dupes it.
        defer {
            for (list.items) |d| {
                if (d.raw.len > 0) self.alloc.free(d.raw);
            }
            list.deinit(self.alloc);
        }
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
            // Kept verbatim so `codeAction`'s context can hand the
            // server back its OWN diagnostic objects (`data` included),
            // which is what a fixit provider matches on.
            const raw: []u8 = serializeValue(self.alloc, d) catch &.{};
            list.append(self.alloc, .{
                .start = offs.start,
                .end = offs.end,
                .severity = sev,
                .message = @constCast(msg),
                .source = @constCast(src),
                .raw = raw,
            }) catch {
                if (raw.len > 0) self.alloc.free(raw);
                break;
            };
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
            .rename => self.onRenameEdit(cn, req, env),
            .formatting, .range_formatting => self.onFormatting(req, env, tab),
            .signature_help => self.onSignatureHelp(req, env, tab),
            .code_action => self.onCodeActions(req, env, tab),
            .code_action_resolve => self.onCodeActionResolved(cn, req, env),
            .execute_command => self.onCommandDone(env),
            .inlay_hint => self.onInlayHints(cn, req, env, tab),
            .inlay_hint_resolve => self.onInlayHintResolved(req, env, tab),
            .semantic_tokens_full,
            .semantic_tokens_delta,
            .semantic_tokens_range,
            => self.onSemanticTokens(cn, req, env, tab),
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
        self.hover.at = null;
        const params = self.docPosParams(r, r.tab.sels.primary().head, "") orelse return;
        self.issue(r, .hover, "textDocument/hover", params, 0);
    }

    fn onHover(self: *Manager, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        const tab = maybe_tab orelse return;
        const dwell = req.aux == HOVER_DWELL_AUX;
        if (env.has_error or tab.doc.revision != req.revision) return;
        const text = hoverText(self.alloc, env.result) catch return;
        defer self.alloc.free(text);
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(self.alloc);
        // A dwell describes what is under the POINTER; the caret's
        // diagnostic has nothing to do with it.
        const diag = if (dwell)
            self.diagnosticTextAt(tab, self.dwell_offset)
        else
            self.diagnosticTextAtCaret(tab);
        if (diag) |d| {
            defer self.alloc.free(d);
            combined.appendSlice(self.alloc, d) catch {};
            if (text.len > 0) combined.appendSlice(self.alloc, "\n\n") catch {};
        }
        combined.appendSlice(self.alloc, text) catch {};
        if (combined.items.len == 0) {
            // A dwell that found nothing must say nothing at all: the
            // user did not ask, they just moved the mouse.
            if (!dwell) self.view.setStatusText("Nothing to show here.");
            return;
        }
        if (!dwell) self.hover.at = null;
        self.showHover(combined.items);
    }

    /// "severity: message [source]" for the diagnostic under the caret.
    fn diagnosticTextAtCaret(self: *Manager, tab: *ETab) ?[]u8 {
        return self.diagnosticTextAt(tab, tab.sels.primary().head);
    }

    fn diagnosticTextAt(self: *Manager, tab: *ETab, offset: usize) ?[]u8 {
        const st = tab.lsp orelse return null;
        const d = st.diags.at(offset) orelse return null;
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
        self.collectLocations(cn, env.result);
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

    /// Spec for a path in one of `cn`'s answers. The path lives on the
    /// host the SERVER runs on: a remote conn's locations must open as
    /// `host:/path` or F12 on a remote document would open a same-named
    /// LOCAL file (or nothing).
    fn specForConnPath(self: *Manager, cn: *Conn, path: []const u8) ?[]u8 {
        if (cn.remote) |rm|
            return std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ rm.link.host, path }) catch null;
        return std.fmt.allocPrint(self.alloc, "local:{s}", .{path}) catch null;
    }

    /// Accepts Location, Location[], LocationLink[] and null.
    fn collectLocations(self: *Manager, cn: *Conn, v: std.json.Value) void {
        switch (v) {
            .array => |a| {
                for (a.items) |x| {
                    if (self.list.items.items.len >= MAX_ROWS) break;
                    self.collectOneLocation(cn, x);
                }
            },
            .object => self.collectOneLocation(cn, v),
            else => {},
        }
    }

    fn collectOneLocation(self: *Manager, cn: *Conn, v: std.json.Value) void {
        if (v != .object) return;
        const o = v.object;
        // LocationLink uses targetUri/targetSelectionRange.
        const uri = strOf(o.get("uri")) orelse strOf(o.get("targetUri")) orelse return;
        const rng_val = o.get("range") orelse o.get("targetSelectionRange") orelse o.get("targetRange") orelse .null;
        const rng = pos.parseRange(rng_val);
        const path = (servers.uriToPath(self.alloc, uri) catch return) orelse return;
        defer self.alloc.free(path);
        const spec = self.specForConnPath(cn, path) orelse return;
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
        self.collectSymbols(cn, env.result, own_spec, 0);
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
    fn collectSymbols(self: *Manager, cn: *Conn, v: std.json.Value, own_spec: []const u8, depth: usize) void {
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
                        spec = self.specForConnPath(cn, p) orelse continue;
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
            if (o.get("children")) |kids| self.collectSymbols(cn, kids, own_spec, depth + 1);
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

    fn onRenameEdit(self: *Manager, cn: *Conn, req: session.Request, env: rpc.Envelope) void {
        _ = req;
        if (env.has_error) {
            self.view.setStatusText("Rename failed.");
            return;
        }
        if (env.result != .object) {
            self.view.setStatusText("Rename produced no changes.");
            return;
        }
        self.reportOutcome("Renamed", self.applyWorkspaceEdit(cn, env.result));
    }

    pub const EditOutcome = struct {
        /// Files edited synchronously, because they already had a tab.
        touched: usize = 0,
        /// Files that had no tab: opened, edits queued, applied when the
        /// async load lands.
        opened: usize = 0,
        /// `create` / `rename` / `delete` file operations, counted and
        /// reported but deliberately NOT performed (see the doc comment
        /// on `applyWorkspaceEdit`).
        file_ops: usize = 0,
        /// Entries that could not be applied at all (malformed, or the
        /// tab could not be opened).
        skipped: usize = 0,
    };

    /// Apply a `WorkspaceEdit`. THE cross-file applier: rename, code
    /// actions and the server-initiated `workspace/applyEdit` all come
    /// through here, so the one-transaction-per-document rule (and its
    /// documented one-undo-unit-per-FILE consequence) holds for every
    /// one of them rather than being re-derived per feature.
    ///
    /// Two things it deliberately does NOT do, both reported rather than
    /// silent (see `reportEditOutcome`):
    ///
    /// * a single cross-DOCUMENT undo unit — the editor's history lives
    ///   on `Document` and the group would be silently invalidated by a
    ///   reload, a tab close, or the user simply typing in one of the
    ///   files afterwards (docs/lsp.md records the full argument);
    /// * `create` / `rename` / `delete` file operations — a filesystem
    ///   mutation has no `Document` to hang an undo entry off, so
    ///   performing one would produce a change Ctrl+Z genuinely cannot
    ///   reach. Counted and named instead.
    fn applyWorkspaceEdit(self: *Manager, cn: *Conn, edit: std.json.Value) EditOutcome {
        const obj = switch (edit) {
            .object => |o| o,
            else => return .{},
        };
        self.pending_touched = 0;
        var out = EditOutcome{};
        // `documentChanges` (ordered, versioned) wins over `changes`
        // when both are present, per the spec.
        if (obj.get("documentChanges")) |dc| {
            if (dc == .array) {
                for (dc.array.items) |entry| {
                    if (entry != .object) continue;
                    // create/rename/delete file operations carry a
                    // `kind` instead of edits.
                    if (entry.object.get("kind") != null) {
                        out.file_ops += 1;
                        continue;
                    }
                    const td = entry.object.get("textDocument") orelse continue;
                    const uri = strOf(if (td == .object) td.object.get("uri") else null) orelse continue;
                    const edits = entry.object.get("edits") orelse continue;
                    self.applyEditsToUri(cn, uri, edits, &out);
                }
            }
        } else if (obj.get("changes")) |ch| {
            if (ch == .object) {
                var it = ch.object.iterator();
                while (it.next()) |kv| {
                    self.applyEditsToUri(cn, kv.key_ptr.*, kv.value_ptr.*, &out);
                }
            }
        }
        self.pending_touched = out.touched;
        return out;
    }

    /// Apply a `TextEdit[]` to the tab holding `uri`, as ONE
    /// transaction — one undo unit per document.
    ///
    /// A file with NO tab is opened rather than reported as skipped:
    /// leaving three of a rename's four files untouched is the surprise
    /// this used to be, and the editor already opens files on its own
    /// for every navigation result. The load is async, so the edits are
    /// queued against the tab's spec and drained by
    /// `onDocumentReplaced`.
    ///
    /// Limitation, deliberate and documented: the editor's history is
    /// per Document, so a rename touching three files is three undo
    /// units, one per file — and `reportEditOutcome` says so out loud.
    fn applyEditsToUri(self: *Manager, cn: *Conn, uri: []const u8, edits: std.json.Value, out: *EditOutcome) void {
        if (self.tabForUri(cn, uri)) |tab| {
            if (self.applyTextEdits(tab, edits, cn.sess.caps.encoding)) out.touched += 1 else out.skipped += 1;
            return;
        }
        const path = (servers.uriToPath(self.alloc, uri) catch null) orelse {
            out.skipped += 1;
            return;
        };
        defer self.alloc.free(path);
        const spec = self.specForConnPath(cn, path) orelse {
            out.skipped += 1;
            return;
        };
        // The file may already be open under a differently-spelled spec
        // (`local:/x` vs `/x`) or attached to another connection —
        // tabForSpec normalizes, tabForUri does not.
        if (self.view.tabForSpec(spec)) |tab| {
            defer self.alloc.free(spec);
            if (self.applyTextEdits(tab, edits, cn.sess.caps.encoding)) out.touched += 1 else out.skipped += 1;
            return;
        }
        const blob = serializeValue(self.alloc, edits) catch {
            self.alloc.free(spec);
            out.skipped += 1;
            return;
        };
        self.pending_edits.append(self.alloc, .{
            .spec = spec,
            .edits = blob,
            .enc = cn.sess.caps.encoding,
        }) catch {
            self.alloc.free(spec);
            self.alloc.free(blob);
            out.skipped += 1;
            return;
        };
        self.view.openSpecAtLineCol(spec, 0, 0);
        out.opened += 1;
    }

    /// Apply (and drop) every queued edit for `tab`, now that it has its
    /// bytes. @return how many were applied.
    fn drainPendingEdits(self: *Manager, tab: *ETab) usize {
        if (self.pending_edits.items.len == 0) return 0;
        var applied: usize = 0;
        var i: usize = 0;
        while (i < self.pending_edits.items.len) {
            const p = self.pending_edits.items[i];
            // tabForSpec normalizes the spelling (`local:/x` vs `/x`),
            // which a byte compare against `tab.spec` would not.
            if (self.view.tabForSpec(p.spec) != tab) {
                i += 1;
                continue;
            }
            _ = self.pending_edits.orderedRemove(i);
            defer {
                self.alloc.free(p.spec);
                self.alloc.free(p.edits);
            }
            var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, p.edits, .{}) catch continue;
            defer parsed.deinit();
            if (self.applyTextEdits(tab, parsed.value, p.enc)) applied += 1;
        }
        return applied;
    }

    fn dropPendingEdits(self: *Manager) void {
        for (self.pending_edits.items) |p| {
            self.alloc.free(p.spec);
            self.alloc.free(p.edits);
        }
        self.pending_edits.clearRetainingCapacity();
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

    // ---- signature help --------------------------------------------------------

    /// Ask for signature help at the caret.
    ///
    /// `trigger` is 1 (invoked by the user), 2 (a trigger character was
    /// typed) or 3 (the popup was already open and is being refreshed).
    /// Servers use it: clangd will not offer help for kind 2 unless the
    /// character it saw is really one of its triggers.
    pub fn requestSignatureHelp(self: *Manager, explicit: bool, trigger: u8, ch: u8) void {
        if (!self.signatureEnabled()) return;
        const r = if (explicit) self.ready("signature help") orelse return else blk: {
            break :blk self.quietReady() orelse return;
        };
        if (!r.cn.sess.caps.signature_help) {
            if (explicit) self.view.setStatusText("Server offers no signature help.");
            return;
        }
        const caret = r.tab.sels.primary().head;
        var extra: [160]u8 = undefined;
        const ctx = if (trigger == 2 and ch >= 0x20 and ch < 0x7F)
            std.fmt.bufPrint(
                &extra,
                ",\"context\":{{\"triggerKind\":2,\"triggerCharacter\":\"{c}\",\"isRetrigger\":{s}}}",
                .{ ch, if (self.sig.open) "true" else "false" },
            ) catch ""
        else
            std.fmt.bufPrint(
                &extra,
                ",\"context\":{{\"triggerKind\":{d},\"isRetrigger\":{s}}}",
                .{ trigger, if (self.sig.open) "true" else "false" },
            ) catch "";
        const params = self.docPosParams(r, caret, ctx) orelse return;
        self.sig.anchor = caret;
        self.issue(r, .signature_help, "textDocument/signatureHelp", params, 0);
    }

    fn onSignatureHelp(self: *Manager, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        const tab = maybe_tab orelse return;
        if (env.has_error or tab.doc.revision != req.revision) {
            // A stale answer must not leave a signature on screen that
            // describes text the user has already replaced.
            self.closeSignature();
            return;
        }
        const obj = switch (env.result) {
            .object => |o| o,
            else => return self.closeSignature(),
        };
        const sigs = switch (obj.get("signatures") orelse std.json.Value.null) {
            .array => |a| a.items,
            else => &.{},
        };
        if (sigs.len == 0) return self.closeSignature();
        const active_sig: usize = @min(intOf(obj.get("activeSignature")), sigs.len - 1);
        const sig = sigs[active_sig];
        if (sig != .object) return self.closeSignature();
        const label = strOf(sig.object.get("label")) orelse return self.closeSignature();

        // The active parameter is per-signature in 3.17 and falls back
        // to the top-level one, which is what every 3.16 server sends.
        const params_arr = switch (sig.object.get("parameters") orelse std.json.Value.null) {
            .array => |a| a.items,
            else => &.{},
        };
        const active_param: usize = if (sig.object.get("activeParameter")) |ap|
            intOf(ap)
        else
            intOf(obj.get("activeParameter"));

        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(self.alloc);
        if (sigs.len > 1) head.print(self.alloc, "{d}/{d}  ", .{ active_sig + 1, sigs.len }) catch {};
        head.appendSlice(self.alloc, label) catch {};

        // The parameter's own text, so the popup says WHICH argument the
        // caret is on even though the label cannot be styled inline.
        var detail: std.ArrayList(u8) = .empty;
        defer detail.deinit(self.alloc);
        if (active_param < params_arr.len and params_arr[active_param] == .object) {
            const po = params_arr[active_param].object;
            if (parameterLabel(label, po.get("label") orelse .null)) |pl| {
                detail.print(self.alloc, "{s}", .{pl}) catch {};
            }
            if (po.get("documentation")) |d| {
                const txt = hoverText(self.alloc, d) catch &.{};
                defer if (txt.len > 0) self.alloc.free(txt);
                if (txt.len > 0) {
                    if (detail.items.len > 0) detail.appendSlice(self.alloc, " — ") catch {};
                    detail.appendSlice(self.alloc, firstLine(txt)) catch {};
                }
            }
        }
        if (detail.items.len == 0) {
            if (sig.object.get("documentation")) |d| {
                const txt = hoverText(self.alloc, d) catch &.{};
                defer if (txt.len > 0) self.alloc.free(txt);
                detail.appendSlice(self.alloc, firstLine(txt)) catch {};
            }
        }
        self.showSignature(head.items, detail.items);
    }

    fn signatureEnabled(self: *Manager) bool {
        const conf = self.cfg() orelse return false;
        return conf.editor_lsp_signature_help;
    }

    /// The active tab's live server WITHOUT the "no server" report — for
    /// the paths a user did not explicitly ask for (typing a trigger
    /// character, a dwell, a viewport refresh).
    fn quietReady(self: *Manager) ?Ready {
        const tab = self.view.activeTab() orelse return null;
        const st = tab.lsp orelse return null;
        const cn = st.conn orelse return null;
        if (cn.sess.state != .ready) return null;
        self.flushChanges(tab);
        return .{ .tab = tab, .st = st, .cn = cn };
    }

    // ---- code actions ----------------------------------------------------------

    /// Quick fixes and refactorings for the selection, or for the caret
    /// when there is none.
    pub fn requestCodeActions(self: *Manager) void {
        const r = self.ready("code actions") orelse return;
        if (!r.cn.sess.caps.code_action) {
            self.view.setStatusText("Server offers no code actions.");
            return;
        }
        const sel = r.tab.sels.primary();
        const enc = r.cn.sess.caps.encoding;
        const s = pos.offsetToPosition(&r.tab.doc.rope, sel.start(), enc);
        const e = pos.offsetToPosition(&r.tab.doc.rope, sel.end(), enc);
        self.scratch.clearRetainingCapacity();
        self.scratch.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return;
        session.appendJsonString(self.alloc, &self.scratch, r.st.sync.uri) catch return;
        self.scratch.print(
            self.alloc,
            "}},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"context\":{{\"diagnostics\":[",
            .{ s.line, s.character, e.line, e.character },
        ) catch return;
        // Only the diagnostics OVERLAPPING the range, handed back
        // verbatim — a server matches its fixits on its own objects.
        var n: usize = 0;
        const lo = sel.start();
        const hi = @max(sel.end(), sel.start() + 1);
        for (r.st.diags.items.items) |d| {
            if (d.raw.len == 0) continue;
            const d_end = @max(d.end, d.start + 1);
            if (d_end <= lo or d.start >= hi) continue;
            if (n > 0) self.scratch.append(self.alloc, ',') catch return;
            self.scratch.appendSlice(self.alloc, d.raw) catch return;
            n += 1;
        }
        self.scratch.appendSlice(self.alloc, "]}}") catch return;
        dbg("codeAction at {d}..{d} with {d} diagnostic(s)", .{ sel.start(), sel.end(), n });
        self.issue(r, .code_action, "textDocument/codeAction", self.scratch.items, 0);
    }

    fn onCodeActions(self: *Manager, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        const tab = maybe_tab orelse return;
        if (env.has_error) {
            self.view.setStatusText("The server could not answer that.");
            return;
        }
        // The actions' edits are in this revision's coordinates.
        if (tab.doc.revision != req.revision) {
            self.view.setStatusText("Document changed; ask again.");
            return;
        }
        const arr = switch (env.result) {
            .array => |a| a.items,
            else => &.{},
        };
        self.list.clearItems();
        self.list.mode = .actions;
        self.list.tab_id = req.tab_id;
        self.list.revision = req.revision;
        self.list.filter.clearRetainingCapacity();
        self.list.sel = 0;
        for (arr) |a| {
            if (self.list.items.items.len >= MAX_ROWS) break;
            if (a != .object) continue;
            // A bare Command (no `title` at the action level is
            // impossible; a Command has one too) and a CodeAction both
            // land here — `applyCodeAction` tells them apart.
            const title = strOf(a.object.get("title")) orelse continue;
            const kind = strOf(a.object.get("kind")) orelse "";
            const raw = serializeValue(self.alloc, a) catch continue;
            const label = self.alloc.dupe(u8, title) catch {
                self.alloc.free(raw);
                continue;
            };
            const detail = self.alloc.dupe(u8, kind) catch {
                self.alloc.free(raw);
                self.alloc.free(label);
                continue;
            };
            self.list.items.append(self.alloc, .{
                .label = label,
                .detail = detail,
                .payload = &.{},
                .raw = raw,
            }) catch {
                self.alloc.free(raw);
                self.alloc.free(label);
                self.alloc.free(detail);
                break;
            };
        }
        if (self.list.items.items.len == 0) {
            self.list.mode = .none;
            self.view.setStatusText("No code actions here.");
            return;
        }
        self.applyFilter();
        self.showPopup();
    }

    /// Run the selected action. Three shapes exist and all three occur
    /// in the wild:
    ///   * an inline `edit` — applied straight away;
    ///   * a `command` — sent to `workspace/executeCommand`, and the
    ///     server usually answers by asking US to apply an edit
    ///     (`workspace/applyEdit`, see `Conn.onApplyEdit`);
    ///   * neither, because the server computes the edit lazily — then
    ///     `codeAction/resolve` fills it in first.
    fn acceptCodeAction(self: *Manager) void {
        if (self.list.shown.items.len == 0) return self.closePopup();
        const idx = self.list.shown.items[self.list.sel];
        const raw = self.alloc.dupe(u8, self.list.items.items[idx].raw) catch return self.closePopup();
        defer self.alloc.free(raw);
        self.closePopup();
        const r = self.quietReady() orelse return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, raw, .{}) catch return;
        defer parsed.deinit();
        self.runCodeAction(r.cn, parsed.value, raw);
    }

    fn runCodeAction(self: *Manager, cn: *Conn, action: std.json.Value, raw: []const u8) void {
        if (action != .object) return;
        const o = action.object;
        var did_something = false;
        if (o.get("edit")) |edit| {
            const res = self.applyWorkspaceEdit(cn, edit);
            did_something = res.touched > 0 or res.skipped > 0;
            self.reportEditOutcome(res);
        }
        if (o.get("command")) |cmd| {
            self.executeCommand(cn, cmd);
            return;
        }
        if (did_something) return;
        // Neither: the server owes us a resolve. Anything without a
        // `title` is not a CodeAction and cannot be resolved.
        if (!cn.sess.caps.code_action_resolve) {
            self.view.setStatusText("The server offered an action with nothing to apply.");
            return;
        }
        const tab = self.view.activeTab() orelse return;
        _ = cn.sess.sendRequest(.code_action_resolve, "codeAction/resolve", raw, .{
            .id = 0,
            .kind = .code_action_resolve,
            .tab_id = tab.id,
            .revision = tab.doc.revision,
        });
        cn.pumpWrite();
    }

    fn onCodeActionResolved(self: *Manager, cn: *Conn, req: session.Request, env: rpc.Envelope) void {
        _ = req;
        if (env.has_error) {
            self.view.setStatusText("The server could not resolve that action.");
            return;
        }
        const o = switch (env.result) {
            .object => |obj| obj,
            else => return,
        };
        if (o.get("edit")) |edit| {
            self.reportEditOutcome(self.applyWorkspaceEdit(cn, edit));
            return;
        }
        if (o.get("command")) |cmd| {
            self.executeCommand(cn, cmd);
            return;
        }
        self.view.setStatusText("The resolved action had nothing to apply.");
    }

    fn executeCommand(self: *Manager, cn: *Conn, cmd: std.json.Value) void {
        // A `command` is either a Command object or (on a bare Command
        // action) the action itself with `command` as a string.
        const name = switch (cmd) {
            .string => |s| s,
            .object => |o| strOf(o.get("command")) orelse return,
            else => return,
        };
        const args: ?std.json.Value = if (cmd == .object) cmd.object.get("arguments") else null;
        self.scratch.clearRetainingCapacity();
        self.scratch.appendSlice(self.alloc, "{\"command\":") catch return;
        session.appendJsonString(self.alloc, &self.scratch, name) catch return;
        if (args) |a| {
            const txt = serializeValue(self.alloc, a) catch return;
            defer self.alloc.free(txt);
            self.scratch.appendSlice(self.alloc, ",\"arguments\":") catch return;
            self.scratch.appendSlice(self.alloc, txt) catch return;
        }
        self.scratch.appendSlice(self.alloc, "}") catch return;
        const tab = self.view.activeTab() orelse return;
        dbg("executeCommand {s}", .{name});
        _ = cn.sess.sendRequest(.execute_command, "workspace/executeCommand", self.scratch.items, .{
            .id = 0,
            .kind = .execute_command,
            .tab_id = tab.id,
            .revision = tab.doc.revision,
        });
        cn.pumpWrite();
    }

    /// A command's own result is almost always null; the work arrived as
    /// a `workspace/applyEdit` before this landed.
    fn onCommandDone(self: *Manager, env: rpc.Envelope) void {
        if (env.has_error) self.view.setStatusText("The command failed.");
    }

    fn reportEditOutcome(self: *Manager, r: EditOutcome) void {
        self.reportOutcome("Applied", r);
    }

    /// Say exactly what a WorkspaceEdit did — including the two things
    /// it did NOT do, which is the point of the wording.
    ///
    /// The undo sentence is not decoration. The editor's history lives
    /// on `Document`, so an action touching N files leaves N separate
    /// undo entries, and a user who presses Ctrl+Z once after a
    /// three-file rename gets one third of it back. Reporting the file
    /// count without reporting the undo shape is what made that a
    /// surprise; saying it in the same breath is the whole fix.
    fn reportOutcome(self: *Manager, comptime verb: []const u8, r: EditOutcome) void {
        var buf: [320:0]u8 = undefined;
        var w: std.ArrayList(u8) = .empty;
        defer w.deinit(self.alloc);
        const total = r.touched + r.opened;
        w.print(self.alloc, verb ++ " in {d} file(s)", .{total}) catch return self.view.setStatusText(verb ++ ".");
        if (total > 1) {
            w.print(self.alloc, " — {d} separate undo steps, one per file", .{total}) catch {};
        }
        if (r.opened > 0) {
            w.print(self.alloc, "; {d} opened for it", .{r.opened}) catch {};
        }
        if (r.file_ops > 0) {
            w.print(
                self.alloc,
                "; {d} file create/rename/delete NOT performed (no undo for those)",
                .{r.file_ops},
            ) catch {};
        }
        if (r.skipped > 0) {
            w.print(self.alloc, "; {d} could not be applied", .{r.skipped}) catch {};
        }
        w.append(self.alloc, '.') catch {};
        // `postStatus`, via setStatusText: the sentence has to survive
        // the burst of updateStatus rebuilds a cross-file edit causes,
        // which is exactly what EditorView's sticky note is for.
        const msg = std.fmt.bufPrintZ(&buf, "{s}", .{w.items}) catch return self.view.setStatusText(verb ++ ".");
        self.view.setStatusText(msg);
    }

    /// The deferred half of a WorkspaceEdit landed (a file that had to
    /// be opened first). Restates the running total so the user is not
    /// left with a count that was only a promise.
    fn reportDeferredEdits(self: *Manager) void {
        var buf: [200:0]u8 = undefined;
        const remaining = self.pending_edits.items.len;
        const msg = if (remaining > 0)
            std.fmt.bufPrintZ(
                &buf,
                "Edited {d} file(s) so far; {d} still opening.",
                .{ self.pending_touched, remaining },
            ) catch "Edited."
        else
            std.fmt.bufPrintZ(
                &buf,
                "Edited {d} file(s) — {d} separate undo steps, one per file.",
                .{ self.pending_touched, self.pending_touched },
            ) catch "Edited.";
        self.view.setStatusText(msg);
    }

    // ---- inlay hints -----------------------------------------------------------

    /// Arm the debounced viewport refresh for hints and tokens. Every
    /// path that invalidates either (an edit, a scroll, an open) calls
    /// this rather than requesting directly, so a burst of keystrokes or
    /// a flung scrollbar costs ONE round trip.
    pub fn armDecorations(self: *Manager, tab: *ETab) void {
        const st = tab.lsp orelse return;
        if (st.conn == null) return;
        if (st.decor_timer != 0) return;
        const ctx = TabCtx.create(self, tab) orelse return;
        st.decor_timer = c.g_timeout_add(DECOR_DEBOUNCE_MS, @ptrCast(&onDecorTimer), @ptrCast(ctx));
    }

    fn onDecorTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const ctx = cast.userData(TabCtx, user);
        defer ctx.destroy();
        const r = ctx.resolve() orelse return 0;
        const st = r.tab.lsp orelse return 0;
        st.decor_timer = 0;
        r.mgr.refreshDecorations(r.tab);
        return 0;
    }

    /// The viewport moved. Only re-asks when the visible lines have left
    /// the window a viewport-scoped decoration was fetched for — which
    /// is inlay hints always, and semantic tokens when the server offers
    /// `range` but not `full`.
    pub fn onViewportMoved(self: *Manager) void {
        const tab = self.view.activeTab() orelse return;
        const st = tab.lsp orelse return;
        const cn = st.conn orelse return;
        const span = self.view.visibleLineSpanPublic(tab);
        const from: u32 = @intCast(span.from);
        const to: u32 = @intCast(span.to);

        if (self.hintsEnabled() and cn.sess.caps.inlay_hint) {
            const covered = st.hints.valid and st.hints.revision == tab.doc.revision and
                st.hints.covers(from, to);
            if (!covered) return self.armDecorations(tab);
        }
        if (self.semanticRangeOnly(cn)) {
            const covered = st.sem_revision == tab.doc.revision and st.semRangeCovers(from, to);
            if (!covered) return self.armDecorations(tab);
        }
    }

    /// The server answers `semanticTokens/range` and NOT
    /// `semanticTokens/full`, so every request is viewport-scoped.
    fn semanticRangeOnly(self: *Manager, cn: *Conn) bool {
        return self.semanticEnabled() and cn.sess.caps.semantic_tokens_range and
            !cn.sess.caps.semantic_tokens;
    }

    fn hintsEnabled(self: *Manager) bool {
        const conf = self.cfg() orelse return false;
        return conf.editor_lsp_inlay_hints;
    }

    fn semanticEnabled(self: *Manager) bool {
        const conf = self.cfg() orelse return false;
        return conf.editor_lsp_semantic_tokens;
    }

    /// Build `{textDocument:{uri}, range:{start,end}}` into `scratch`
    /// for a whole-line window. Shared by `inlayHint` and
    /// `semanticTokens/range`, which take the identical param shape.
    /// @return false when the buffer could not be built (out of memory).
    fn rangeParams(self: *Manager, uri: []const u8, from: u32, to: u32) bool {
        self.scratch.clearRetainingCapacity();
        self.scratch.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return false;
        session.appendJsonString(self.alloc, &self.scratch, uri) catch return false;
        self.scratch.print(
            self.alloc,
            "}},\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}}}",
            .{ from, to },
        ) catch return false;
        return true;
    }

    fn refreshDecorations(self: *Manager, tab: *ETab) void {
        const st = tab.lsp orelse return;
        const cn = st.conn orelse return;
        if (cn.sess.state != .ready or !st.sync.open) return;
        self.flushChanges(tab);
        const r = Ready{ .tab = tab, .st = st, .cn = cn };

        // The window both viewport-scoped requests use: the visible
        // lines widened by HINT_MARGIN_LINES, so scrolling a few rows
        // costs no round trip at all.
        const span = self.view.visibleLineSpanPublic(tab);
        const n_lines: u32 = @intCast(tab.doc.rope.lineCount());
        const win_from: u32 = @as(u32, @intCast(span.from)) -| HINT_MARGIN_LINES;
        const win_to: u32 = @min(n_lines, @as(u32, @intCast(span.to)) +| HINT_MARGIN_LINES);

        if (self.hintsEnabled() and cn.sess.caps.inlay_hint) {
            if (self.rangeParams(st.sync.uri, win_from, win_to)) {
                // aux carries the window back so the answer can record
                // what it covers without a second lookup.
                self.issue(
                    r,
                    .inlay_hint,
                    "textDocument/inlayHint",
                    self.scratch.items,
                    packWindow(win_from, win_to),
                );
            }
        }

        // Range-only servers: the same viewport-scoped shape as inlay
        // hints, deliberately — `range` exists precisely so a client can
        // colour what is on screen without paying for the document, and
        // inventing a second scoping rule for it would give two answers
        // to "why did this re-ask?".
        if (self.semanticRangeOnly(cn)) {
            const covered = st.sem_revision == tab.doc.revision and
                st.semRangeCovers(@intCast(span.from), @intCast(span.to));
            if ((st.sem_stale or !covered) and self.rangeParams(st.sync.uri, win_from, win_to)) {
                st.sem_stale = false;
                self.issue(
                    r,
                    .semantic_tokens_range,
                    "textDocument/semanticTokens/range",
                    self.scratch.items,
                    packWindow(win_from, win_to),
                );
            }
            return;
        }

        if (self.semanticEnabled() and cn.sess.caps.semantic_tokens and st.sem_stale) {
            st.sem_stale = false;
            self.scratch.clearRetainingCapacity();
            self.scratch.appendSlice(self.alloc, "{\"textDocument\":{\"uri\":") catch return;
            session.appendJsonString(self.alloc, &self.scratch, st.sync.uri) catch return;
            self.scratch.appendSlice(self.alloc, "}") catch return;
            // A delta is only possible when the server gave us a
            // resultId for the array we are still holding.
            const delta = cn.sess.caps.semantic_tokens_delta and
                st.sem_data.valid and st.sem_data.result_id.len > 0;
            if (delta) {
                self.scratch.appendSlice(self.alloc, ",\"previousResultId\":") catch return;
                session.appendJsonString(self.alloc, &self.scratch, st.sem_data.result_id) catch return;
            }
            self.scratch.appendSlice(self.alloc, "}") catch return;
            self.issue(
                r,
                if (delta) .semantic_tokens_delta else .semantic_tokens_full,
                if (delta) "textDocument/semanticTokens/full/delta" else "textDocument/semanticTokens/full",
                self.scratch.items,
                0,
            );
        }
    }

    fn onInlayHints(self: *Manager, cn: *Conn, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        const tab = maybe_tab orelse return;
        const st = tab.lsp orelse return;
        if (env.has_error) return;
        // Hints describe byte positions; a moved document invalidates
        // every one of them.
        if (tab.doc.revision != req.revision) return;
        const win = unpackWindow(req.aux);
        st.hints.absorb(
            env.result,
            &tab.doc.rope,
            cn.sess.caps.encoding,
            req.revision,
            win.from,
            win.to,
        ) catch return;
        dbg("inlayHint: {d} hints for lines {d}..{d}", .{ st.hints.items.items.len, win.from, win.to });
        self.view.queueRenderExternal();
    }

    /// Show hint `idx`'s tooltip at the pointer, resolving it first when
    /// the server offers `inlayHint/resolve` and has not told us yet.
    /// @return whether the dwell was consumed (so no `textDocument/hover`
    /// goes out for the same pointer rest).
    fn dwellOnHint(self: *Manager, r: Ready, idx: usize) bool {
        const st = r.st;
        const h = &st.hints.items.items[idx];
        if (h.tooltip.len > 0) {
            self.hover.at = self.view.pointRectPx(self.dwell_x, self.dwell_y);
            self.showHover(h.tooltip);
            return true;
        }
        if (!r.cn.sess.caps.inlay_hint_resolve) return false;
        if (h.resolve_asked or h.raw.len == 0) return false;
        h.resolve_asked = true;
        // aux ties the answer to the exact set it was asked against: a
        // set is REPLACED wholesale on every refresh, so an index alone
        // would let a late answer write a tooltip onto a different hint.
        self.issue(
            r,
            .inlay_hint_resolve,
            "inlayHint/resolve",
            h.raw,
            packHintRef(st.hints.generation, idx),
        );
        // The answer re-anchors the popup itself; nothing to show yet,
        // and nothing else should claim this dwell either.
        return true;
    }

    fn onInlayHintResolved(self: *Manager, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        const tab = maybe_tab orelse return;
        const st = tab.lsp orelse return;
        if (env.has_error) return;
        if (tab.doc.revision != req.revision) return;
        const ref = unpackHintRef(req.aux);
        // The set was replaced (scroll, edit) while the answer was in
        // flight: the index means nothing now. Silently drop it, the
        // same rule every other stale answer follows.
        if (@as(u32, @truncate(st.hints.generation)) != ref.generation) return;
        if (!st.hints.absorbResolved(ref.index, env.result)) return;
        // Only pop the tooltip if the pointer is still resting where it
        // was asked from — a resolve that lands after the user moved on
        // must not throw a popup at them.
        if (self.dwell_timer != 0 or self.list.open) return;
        const off = self.view.offsetAtPointPublic(tab, self.dwell_x, self.dwell_y) orelse return;
        if (st.hints.items.items[ref.index].offset != off) return;
        self.hover.at = self.view.pointRectPx(self.dwell_x, self.dwell_y);
        self.showHover(st.hints.items.items[ref.index].tooltip);
    }

    // ---- semantic tokens -------------------------------------------------------

    fn onSemanticTokens(self: *Manager, cn: *Conn, req: session.Request, env: rpc.Envelope, maybe_tab: ?*ETab) void {
        const tab = maybe_tab orelse return;
        const st = tab.lsp orelse return;
        if (env.has_error) {
            // A refused delta (the server dropped our resultId) is
            // normal; drop the cached array so the next request is full.
            st.sem_data.reset();
            st.sem_stale = true;
            return;
        }
        if (tab.doc.revision != req.revision) {
            // The array we would have spliced is no longer what the
            // server holds either; start over rather than keep a
            // resultId that describes text nobody has.
            st.sem_data.reset();
            st.sem_stale = true;
            return;
        }
        const ok = if (req.kind == .semantic_tokens_delta and env.result == .object and
            env.result.object.get("edits") != null)
            st.sem_data.absorbDelta(env.result)
        else
            st.sem_data.absorbFull(env.result);
        if (!ok) {
            st.sem_data.reset();
            return;
        }
        if (req.kind == .semantic_tokens_range) {
            // A range answer describes ONLY the window it was asked
            // for, and its resultId (if any) refers to that window, so
            // it must never seed a `full/delta` splice. `refreshDecorations`
            // never asks for a delta in this regime, and dropping the id
            // here keeps that true even if a server volunteers one.
            const win = unpackWindow(req.aux);
            st.sem_ranged = true;
            st.sem_from = win.from;
            st.sem_to = win.to;
            dbg("semanticTokens/range: lines {d}..{d}", .{ win.from, win.to });
        } else {
            st.sem_ranged = false;
        }
        self.rebuildSemanticSpans(tab, st, cn);
        self.view.queueRenderExternal();
    }

    /// Decode the packed array into document byte ranges tagged with a
    /// highlight kind. Tokens whose type this editor has no colour for
    /// are DROPPED rather than emitted as `.none`: `.none` would blank
    /// out the Tree-sitter kind underneath, which is a regression, not
    /// extra information.
    fn rebuildSemanticSpans(self: *Manager, tab: *ETab, st: *TabState, cn: *Conn) void {
        st.sem_spans.clearRetainingCapacity();
        st.sem_generation +%= 1;
        st.sem_revision = tab.doc.revision;
        const toks = st.sem_data.decode(self.alloc) catch return;
        defer self.alloc.free(toks);
        const enc = cn.sess.caps.encoding;
        const legend = &cn.sess.caps.token_types;
        for (toks) |t| {
            const kind = semanticKind(legend.name(t.type_index));
            if (kind == .none) continue;
            const start = pos.positionToOffset(&tab.doc.rope, .{ .line = t.line, .character = t.start_char }, enc);
            const end = pos.positionToOffset(
                &tab.doc.rope,
                .{ .line = t.line, .character = t.start_char +| t.length },
                enc,
            );
            if (end <= start) continue;
            // The modifier bits ride in the SAME byte as the kind (see
            // the band in syntax.zig): `editor_layout` memsets that byte
            // across the span and `theme.style` splits it again, so no
            // second channel has to be threaded through the renderer.
            const mods = legend.foldMods(t.modifiers, u8, &semanticModBit);
            st.sem_spans.append(self.alloc, .{
                .start = start,
                .end = end,
                .kind = @intFromEnum(syntax.withMods(kind, mods)),
            }) catch break;
        }
        // The layout binary-searches these, and a server is free to send
        // them out of order across lines.
        std.mem.sort(layout_mod.SemSpan, st.sem_spans.items, {}, struct {
            fn less(_: void, a: layout_mod.SemSpan, b: layout_mod.SemSpan) bool {
                return a.start < b.start;
            }
        }.less);
        dbg("semanticTokens: {d} tokens -> {d} spans", .{ toks.len, st.sem_spans.items.len });
    }

    /// Point the layout at this tab's decorations, or at nothing when
    /// they are stale / switched off. Called once per frame, before the
    /// frame is built: this is the ONLY place the borrow is established,
    /// so a stale set can never be painted.
    pub fn applyDecorations(self: *Manager, tab: *ETab) void {
        tab.layout.sem = &.{};
        tab.layout.sem_gen = 0;
        tab.layout.hints = &.{};
        tab.layout.hints_gen = 0;
        const st = tab.lsp orelse return;
        if (st.conn == null) return;
        if (self.semanticEnabled() and st.sem_revision == tab.doc.revision and st.sem_spans.items.len > 0) {
            tab.layout.sem = st.sem_spans.items;
            tab.layout.sem_gen = st.sem_generation;
        }
        if (self.hintsEnabled() and st.hints.valid and st.hints.revision == tab.doc.revision and
            st.hints.items.items.len > 0)
        {
            // inlay.Hint and layout.InlayHint are the same two fields;
            // the render side deliberately does not import lsp/, so the
            // handful of hints is copied into the view's scratch list.
            self.hint_view.clearRetainingCapacity();
            for (st.hints.items.items) |h| {
                self.hint_view.append(self.alloc, .{ .offset = h.offset, .text = h.text }) catch break;
            }
            tab.layout.hints = self.hint_view.items;
            tab.layout.hints_gen = st.hints.generation;
        }
    }

    // ---- mouse-dwell hover -----------------------------------------------------

    /// The pointer moved. Restarts the dwell timer; NEVER issues a
    /// request — a motion event stream is hundreds of events per second
    /// and one request each would flood the server.
    pub fn onPointerMoved(self: *Manager, x: f64, y: f64) void {
        self.dwell_x = x;
        self.dwell_y = y;
        if (self.hover.open and self.hover.at != null) self.closeHover();
        const ms = self.dwellMs();
        if (ms == 0) return;
        if (self.dwell_timer != 0) {
            _ = c.g_source_remove(self.dwell_timer);
            self.dwell_timer = 0;
        }
        // A dwell is only interesting where a server could answer.
        const tab = self.view.activeTab() orelse return;
        const st = tab.lsp orelse return;
        const cn = st.conn orelse return;
        if (cn.sess.state != .ready) return;
        // Hover is the usual answer, but a dwell can also land on an
        // inlay hint's tooltip, so a server with hints and no hover
        // still gets a timer.
        if (!cn.sess.caps.hover and !(cn.sess.caps.inlay_hint and self.hintsEnabled())) return;
        self.dwell_timer = c.g_timeout_add(ms, @ptrCast(&onDwellTimer), @ptrCast(self));
    }

    fn dwellMs(self: *Manager) c_uint {
        const conf = self.cfg() orelse return 0;
        if (!conf.editor_lsp) return 0;
        return conf.editor_lsp_hover_delay_ms;
    }

    /// Any key, scroll, click or teardown kills a pending dwell.
    pub fn cancelDwell(self: *Manager) void {
        if (self.dwell_timer != 0) {
            _ = c.g_source_remove(self.dwell_timer);
            self.dwell_timer = 0;
        }
        self.dwell_offset = std.math.maxInt(usize);
        if (self.hover.open and self.hover.at != null) self.closeHover();
    }

    fn onDwellTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Manager, user);
        self.dwell_timer = 0;
        if (self.view.widgets_dead) return 0;
        // Not while a list is up: the popup would be under the pointer
        // and the two would fight for the same screen corner.
        if (self.list.open) return 0;
        const tab = self.view.activeTab() orelse return 0;
        const r = self.quietReady() orelse return 0;
        const off = self.view.offsetAtPointPublic(tab, self.dwell_x, self.dwell_y) orelse return 0;
        if (off == self.dwell_offset) return 0;
        self.dwell_offset = off;

        // An inlay hint anchored exactly here wins the dwell. A hint has
        // no clusters — that is the invariant keeping the caret out of
        // text the document does not contain — so it has no hit region
        // of its own either, and the pointer resolving to the hint's
        // ANCHOR byte is the whole hit test there is. Good enough:
        // a hint is drawn immediately before that byte, so resting on
        // the hint or on the token it annotates both land here.
        if (self.hintsEnabled() and r.st.hints.valid and r.st.hints.revision == tab.doc.revision) {
            if (r.st.hints.indexAtOffset(off)) |idx| {
                if (self.dwellOnHint(r, idx)) return 0;
            }
        }

        if (!r.cn.sess.caps.hover) return 0;
        const params = self.docPosParams(r, off, "") orelse return 0;
        self.hover.at = self.view.pointRectPx(self.dwell_x, self.dwell_y);
        self.issue(r, .hover, "textDocument/hover", params, HOVER_DWELL_AUX);
        return 0;
    }

    /// `Request.aux` marking a hover that came from the pointer rather
    /// than from Ctrl+I — it is anchored at the pointer, and it stays
    /// silent when there is nothing to say.
    pub const HOVER_DWELL_AUX: u64 = 1;

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
    ///
    /// This is the document's STANDING state only. Transient sentences
    /// (a WorkspaceEdit outcome, "Formatted.", "No results.") used to
    /// ride this fragment too, because it was the only thing
    /// `updateStatus` re-emitted on every rebuild; they now go through
    /// `EditorView.postStatus`, which does that for any message.
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
            .actions => "Code actions",
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
        if (self.hover.at) |rect| {
            var r = rect;
            c.gtk_popover_set_pointing_to(@ptrCast(self.hover.popover.?), &r);
        } else {
            self.positionAtCaret(self.hover.popover.?);
        }
        c.gtk_popover_popup(@ptrCast(self.hover.popover.?));
        self.hover.open = true;
    }

    // ---- signature popup -------------------------------------------------------

    /// Same minimum-size invariant as `ensurePopup`: both labels are
    /// single-line, ellipsized, capped in characters, and start with a
    /// space placeholder so their height is reserved from the first
    /// present. Signature help updates on nearly every keystroke, so a
    /// growable label here would pop the widget down mid-typing.
    fn ensureSignature(self: *Manager) bool {
        if (self.sig.popover != null) return true;
        const pop = c.gtk_popover_new() orelse return false;
        c.gtk_widget_set_parent(pop, @ptrCast(self.view.area));
        c.gtk_popover_set_has_arrow(@ptrCast(pop), 0);
        c.gtk_popover_set_autohide(@ptrCast(pop), 0);
        // ABOVE the caret: the completion list lives below it, and the
        // two are routinely open at the same time.
        c.gtk_popover_set_position(@ptrCast(pop), c.GTK_POS_TOP);
        c.gtk_widget_set_can_focus(pop, 0);

        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
        c.gtk_widget_set_size_request(box, SIG_W, -1);
        const label = c.gtk_label_new(" ");
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(label), 72);
        c.gtk_box_append(@ptrCast(box), label);
        const doc = c.gtk_label_new(" ");
        c.gtk_label_set_xalign(@ptrCast(doc), 0);
        c.gtk_label_set_ellipsize(@ptrCast(doc), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(doc), 72);
        c.gtk_widget_add_css_class(doc, "dim-label");
        c.gtk_box_append(@ptrCast(box), doc);
        c.gtk_popover_set_child(@ptrCast(pop), box);

        self.sig.popover = pop;
        self.sig.label = @ptrCast(label);
        self.sig.doc_label = @ptrCast(doc);
        return true;
    }

    fn showSignature(self: *Manager, label: []const u8, detail: []const u8) void {
        if (self.view.widgets_dead) return;
        if (!self.ensureSignature()) return;
        var lbuf: [1024:0]u8 = undefined;
        const lz = std.fmt.bufPrintZ(&lbuf, "{s}", .{label[0..@min(label.len, 900)]}) catch return;
        c.gtk_label_set_text(self.sig.label.?, if (lz.len > 0) lz.ptr else " ");
        var dbuf: [1024:0]u8 = undefined;
        const dz = std.fmt.bufPrintZ(&dbuf, "{s}", .{detail[0..@min(detail.len, 900)]}) catch return;
        c.gtk_label_set_text(self.sig.doc_label.?, if (dz.len > 0) dz.ptr else " ");
        self.positionAtCaret(self.sig.popover.?);
        if (!self.sig.open) c.gtk_popover_popup(@ptrCast(self.sig.popover.?));
        self.sig.open = true;
    }

    pub fn closeSignature(self: *Manager) void {
        if (!self.sig.open) return;
        self.sig.open = false;
        if (self.sig.popover) |p| c.gtk_popover_popdown(@ptrCast(p));
    }

    pub fn signatureOpen(self: *const Manager) bool {
        return self.sig.open;
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
        // Any key is deliberate pointer-free activity: a dwell hover
        // must not appear over text the user is typing.
        self.cancelDwell();
        if (keyval == c.GDK_KEY_Escape and self.sig.open and !self.list.open and !self.hover.open) {
            self.closeSignature();
            return true;
        }
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
                if (self.list.mode != .completion and self.list.mode != .none) {
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
            .actions => self.acceptCodeAction(),
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
        self.cancelDwell();
        self.trackSignature();
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
        const ctx = cast.userData(TabCtx, user);
        defer ctx.destroy();
        const r = ctx.resolve() orelse return 0;
        const st = r.tab.lsp orelse return 0;
        st.completion_timer = 0;
        if (!r.mgr.list.open or r.mgr.list.mode != .completion) return 0;
        r.mgr.requestCompletion(false);
        return 0;
    }

    /// Follow the caret while signature help is open.
    ///
    /// The re-entrancy here is the hard part: the answer that updates
    /// the active parameter arrives WHILE the user keeps typing, so
    /// every re-request is debounced, supersedes its predecessor
    /// (`issue` cancels the in-flight one of the same kind) and is
    /// dropped on arrival if the revision moved. The popup is closed
    /// outright as soon as the caret walks back past the offset the
    /// current help was requested at, because that call is gone.
    fn trackSignature(self: *Manager) void {
        if (!self.sig.open) return;
        const tab = self.view.activeTab() orelse return self.closeSignature();
        const st = tab.lsp orelse return self.closeSignature();
        if (tab.sels.primary().head < self.sig.anchor -| 1) return self.closeSignature();
        if (st.signature_timer != 0) return;
        const ctx = TabCtx.create(self, tab) orelse return;
        st.signature_timer = c.g_timeout_add(SIGNATURE_DEBOUNCE_MS, @ptrCast(&onSignatureTimer), @ptrCast(ctx));
    }

    fn onSignatureTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const ctx = cast.userData(TabCtx, user);
        defer ctx.destroy();
        const r = ctx.resolve() orelse return 0;
        const st = r.tab.lsp orelse return 0;
        st.signature_timer = 0;
        if (!r.mgr.sig.open) return 0;
        r.mgr.requestSignatureHelp(false, 3, 0);
        return 0;
    }

    /// A character was just committed. A completion trigger pops the
    /// list; a signature trigger (or a retrigger while help is up) asks
    /// for signature help. They are independent: `(` opens both in
    /// every editor that has both.
    pub fn maybeTrigger(self: *Manager, text: []const u8) void {
        if (text.len != 1) return;
        const tab = self.view.activeTab() orelse return;
        const st = tab.lsp orelse return;
        const cn = st.conn orelse return;
        if (cn.sess.state != .ready) return;
        const ch = text[0];
        if (cn.sess.caps.signature_help and self.signatureEnabled()) {
            if (cn.sess.caps.isSignatureTrigger(ch) or
                (self.sig.open and cn.sess.caps.isSignatureRetrigger(ch)))
            {
                self.requestSignatureHelp(false, 2, ch);
            }
        }
        if (cn.sess.caps.isTrigger(ch)) self.requestCompletion(false);
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

/// Two u32 line numbers in one `Request.aux` slot, so an `inlayHint`
/// answer knows the window it was asked for without a second lookup.
fn packWindow(from: u32, to: u32) u64 {
    return (@as(u64, from) << 32) | @as(u64, to);
}

fn unpackWindow(v: u64) struct { from: u32, to: u32 } {
    return .{ .from = @intCast(v >> 32), .to = @truncate(v) };
}

/// `Request.aux` for an `inlayHint/resolve`: which hint, in which
/// generation of the tab's hint set. The generation half is what makes a
/// late answer safe — the set is replaced wholesale on every refresh.
fn packHintRef(generation: u64, index: usize) u64 {
    return (@as(u64, @as(u32, @truncate(generation))) << 32) | @as(u64, @as(u32, @truncate(index)));
}

fn unpackHintRef(v: u64) struct { generation: u32, index: usize } {
    return .{ .generation = @intCast(v >> 32), .index = @as(u32, @truncate(v)) };
}

/// LSP semantic token type name -> the editor's highlight kind.
///
/// `.none` means "we have no colour for this", and the caller DROPS
/// such a token rather than emitting it: painting `.none` would erase
/// the Tree-sitter kind underneath, which is the opposite of the
/// documented precedence (semantic tokens augment the grammar's work,
/// they do not replace it).
fn semanticKind(name: []const u8) syntax.Kind {
    const table = .{
        .{ "namespace", syntax.Kind.namespace },
        .{ "type", syntax.Kind.type },
        .{ "class", syntax.Kind.type },
        .{ "enum", syntax.Kind.type },
        .{ "interface", syntax.Kind.type },
        .{ "struct", syntax.Kind.type },
        .{ "typeParameter", syntax.Kind.type },
        .{ "parameter", syntax.Kind.variable },
        .{ "variable", syntax.Kind.variable },
        .{ "property", syntax.Kind.property },
        .{ "event", syntax.Kind.property },
        .{ "enumMember", syntax.Kind.constant },
        .{ "function", syntax.Kind.function },
        .{ "method", syntax.Kind.function },
        .{ "macro", syntax.Kind.attribute },
        .{ "decorator", syntax.Kind.attribute },
        .{ "keyword", syntax.Kind.keyword },
        .{ "modifier", syntax.Kind.keyword },
        .{ "comment", syntax.Kind.comment },
        .{ "string", syntax.Kind.string },
        .{ "regexp", syntax.Kind.string },
        .{ "number", syntax.Kind.number },
        .{ "operator", syntax.Kind.operator },
        .{ "label", syntax.Kind.label },
        // clangd's non-standard additions.
        .{ "concept", syntax.Kind.type },
        .{ "bracket", syntax.Kind.punctuation },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, name, row[0])) return row[1];
    }
    return .none;
}

/// One LSP token-modifier NAME -> the `syntax.MOD_*` bit it renders as,
/// or 0 for one this editor's themes cannot say anything about.
///
/// The band is three bits wide (syntax.zig), so this is a deliberate
/// short list rather than a complete one. The seven standard modifiers
/// that map to 0 — `declaration`, `definition`, `static`, `abstract`,
/// `async`, `modification`, `documentation` — plus every vendor
/// extension are parsed off the wire and then dropped, exactly as an
/// unmapped token TYPE is: a modifier with no rendering is not a reason
/// to change how the token is coloured.
fn semanticModBit(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "readonly")) return syntax.MOD_READONLY;
    if (std.mem.eql(u8, name, "deprecated")) return syntax.MOD_DEPRECATED;
    if (std.mem.eql(u8, name, "defaultLibrary")) return syntax.MOD_DEFAULT_LIBRARY;
    return 0;
}

/// A `ParameterInformation.label`: a string, or a `[start, end]` pair of
/// UTF-16 offsets INTO THE SIGNATURE LABEL (not into the document, so
/// no rope is involved — but they are still utf-16 units, so the slice
/// is taken by counting code units, not bytes).
fn parameterLabel(sig_label: []const u8, v: std.json.Value) ?[]const u8 {
    switch (v) {
        .string => |s| return s,
        .array => |a| {
            if (a.items.len < 2) return null;
            const s = utf16ToByte(sig_label, jsonUsize(a.items[0]));
            const e = utf16ToByte(sig_label, jsonUsize(a.items[1]));
            if (e <= s or e > sig_label.len) return null;
            return sig_label[s..e];
        },
        else => return null,
    }
}

/// Byte index of UTF-16 code unit `units` within `s`, clamped.
fn utf16ToByte(s: []const u8, units: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < units) {
        const b = s[i];
        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        n += if (b >= 0xF0) 2 else 1;
        i += @min(len, s.len - i);
    }
    return i;
}

fn jsonUsize(v: std.json.Value) usize {
    return switch (v) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

fn intOf(v: ?std.json.Value) usize {
    const val = v orelse return 0;
    return jsonUsize(val);
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

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
