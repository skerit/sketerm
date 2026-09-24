//! File operations: clipboard copy/cut/paste with its conflict flow,
//! new folder / rename / batch rename, delete, trash and restore, the
//! undo/redo stacks, tags, and archive browsing.

const std = @import("std");
const c = @import("../../c.zig").c;
const platform = @import("../../util/platform.zig");
const wire = @import("../../mux/wire.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Dir = @import("types.zig").Dir;
const HistoryDirection = @import("types.zig").HistoryDirection;
const HostConn = @import("types.zig").HostConn;
const MenuCtx = @import("menu.zig").MenuCtx;
const PendingJob = @import("types.zig").PendingJob;
const colview = @import("colview.zig");
const UndoOp = @import("types.zig").UndoOp;
const WireJobEv = @import("types.zig").WireJobEv;
const WireReply = @import("types.zig").WireReply;
const appendQuoted = @import("../../filebrowser/desktop.zig").appendQuoted;
const clipboard = @import("../../filebrowser/clipboard.zig");
const confirm = @import("../confirm.zig");
const conflict = @import("conflict.zig");
const dnd = @import("dnd.zig");
const oproots = @import("oproots.zig");
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const hostEq = @import("../../filebrowser/paths.zig").hostEq;
const menuDone = @import("menu.zig").menuDone;
const parseSpec = @import("../../filebrowser/paths.zig").parseSpec;
const dirWithin = @import("../../filebrowser/paths.zig").dirWithin;
const uniqueName = @import("../../filebrowser/paths.zig").uniqueName;
const urlUnescape = @import("../../filebrowser/paths.zig").urlUnescape;
const cast = @import("../../util/cast.zig");
const batchrename = @import("../../filebrowser/batchrename.zig");
const shellverb = @import("../../filebrowser/shellverb.zig");
const errorPhrase = @import("../../filebrowser/format.zig").errorPhrase;
const RenameRun = @import("types.zig").RenameRun;

/// One in-flight .trashinfo fetch for Restore from Trash.
pub const RestoreRead = struct {
    req: u32,
    hc: *HostConn,
    /// The trashed entry (…/Trash/files/<name>).
    trashed: []u8,
    /// Its metadata file (…/Trash/info/<name>.trashinfo).
    info: []u8,
    buf: std.ArrayList(u8) = .empty,

    pub fn destroy(self: *RestoreRead, allocator: std.mem.Allocator) void {
        allocator.free(self.trashed);
        allocator.free(self.info);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
};

/// One destination-existence check fencing a drag from overwrite-capable
/// copy/rename verbs.
pub const DropProbe = struct {
    req: u32,
    tab: *BTab,
    dst_hc: *HostConn,
    src_hc: *HostConn,
    src_host: ?[]u8,
    src: []u8,
    dst: []u8,
    cut: bool,
    batch_id: u64 = 0,
    batch_total: usize = 0,
    manifest_token: ?[]u8 = null,
    manifest_index: ?usize = null,

    pub fn destroy(self: *DropProbe, allocator: std.mem.Allocator) void {
        if (self.src_host) |host| allocator.free(host);
        allocator.free(self.src);
        allocator.free(self.dst);
        if (self.manifest_token) |token| allocator.free(token);
        allocator.destroy(self);
    }
};

const PasteItem = struct {
    src: []u8,
    dst: []u8,
    collision_is_dir: ?bool = null,
    manifest_index: ?usize = null,

    fn deinit(self: PasteItem, allocator: std.mem.Allocator) void {
        allocator.free(self.src);
        allocator.free(self.dst);
    }
};

/// One paste command being admitted incrementally from GTK's idle
/// queue. The expensive durable fsync remains per item, but no command
/// callback performs hundreds of them before returning to the UI.
pub const PasteRun = struct {
    tab: ?*BTab,
    src_hc: *HostConn,
    dst_hc: *HostConn,
    src_host: ?[]u8,
    dst_dir: []u8,
    items: std.ArrayList(PasteItem) = .empty,
    next: usize = 0,
    admitted: usize = 0,
    conflicts: usize = 0,
    rejected: usize = 0,
    cut: bool,
    no_replace: bool = true,
    batch_id: u64,
    total: usize,
    manifest_token: ?[]u8 = null,
    failure: [256]u8 = undefined,
    failure_len: usize = 0,

    pub fn destroy(self: *PasteRun, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| item.deinit(allocator);
        self.items.deinit(allocator);
        if (self.src_host) |host| allocator.free(host);
        if (self.manifest_token) |token| allocator.free(token);
        allocator.free(self.dst_dir);
        allocator.destroy(self);
    }
};

fn newBatchId() u64 {
    var raw: [8]u8 = undefined;
    if (c.getentropy(&raw, raw.len) == 0) {
        const id = std.mem.readInt(u64, &raw, .little);
        if (id != 0) return id;
    }
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const fallback = (@as(u64, @intCast(c.getpid())) << 32) ^ @as(u64, @intCast(ts.tv_nsec));
    return if (fallback == 0) 1 else fallback;
}

pub fn copyToClip(ctx: *MenuCtx, cut: bool) void {
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    // A multi-selection that includes the clicked row copies the
    // whole selection; otherwise just the clicked entry.
    if (ctx.tab.selected.actsOnAll(path)) {
        clipStore(self, ctx.tab, ctx.tab.selected.items, cut);
    } else {
        clipStore(self, ctx.tab, (&[_][]u8{path})[0..], cut);
    }
    menuDone(ctx);
}

/// Chord-driven cut/copy (Ctrl+X / Ctrl+C): the tab's selection, no
/// menu context and no clicked row.
pub fn clipSelection(self: *BrowserView, cut: bool) void {
    const tab = self.currentTab() orelse return;
    if (tab.selected.items.len == 0) {
        self.setStatus("nothing selected");
        return;
    }
    clipStore(self, tab, tab.selected.items, cut);
}

fn clipStore(self: *BrowserView, tab: *BTab, srcs: []const []u8, cut: bool) void {
    const roots = oproots.collect(self.allocator, tab, srcs) catch {
        self.setStatus("file operation not started: out of memory");
        return;
    };
    defer self.allocator.free(roots);
    // The source directory's filesystem rides along: it decides later
    // whether a hard link into another directory could work at all.
    const clip = c.gtk_widget_get_clipboard(@ptrCast(@alignCast(tab.colview))) orelse {
        self.setStatus("file clipboard is unavailable");
        return;
    };
    const board = self.clipboard();
    if (!board.set(tab.hc.host, roots, cut, tab.root.dev)) {
        _ = c.gdk_clipboard_set_content(clip, null);
        self.setStatus("file copy/cut canceled: out of memory");
        return;
    }
    if (!exportClipToGdk(board, clip)) {
        self.setStatus("file clipboard export failed; copy/cut canceled");
        return;
    }
    const verb: []const u8 = if (cut) "cut" else "copied";
    if (board.items().len > 1) {
        self.setStatusFmt("{s} {d} items", .{ verb, board.items().len });
    } else if (board.first()) |only| {
        self.setStatusFmt("{s}: {s}", .{ verb, only });
    }
}

// Like the board, this ownership is process-wide, not attached to a pane.
// Own the provider reference so pointer identity cannot be recycled.
const FileClipboardOwner = struct {
    clip: ?*c.GdkClipboard = null,
    provider: ?*c.GdkContentProvider = null,
    changed: c.gulong = 0,

    fn release(self: *FileClipboardOwner) void {
        const clip = self.clip orelse return;
        const provider = self.provider;
        const changed = self.changed;
        self.* = .{};
        if (changed != 0) c.g_signal_handler_disconnect(clip, changed);
        if (provider) |p| c.g_object_unref(p);
        c.g_object_unref(clip);
    }
};

var file_clipboard_owner: FileClipboardOwner = .{};

fn onFileClipboardChanged(clip: *c.GdkClipboard, _: ?*anyopaque) callconv(.c) void {
    if (file_clipboard_owner.clip != clip or c.gdk_clipboard_get_content(clip) == file_clipboard_owner.provider) return;
    file_clipboard_owner.release();
    clipboard.clearShared();
}

/// Mirror the internal clipboard onto the GDK clipboard so other apps
/// can paste it: text/plain is newline-delimited absolute paths (a
/// text-editor paste gives usable paths, Nemo-style, no file://) and
/// GNOME and URI-list/KDE formats carry file:// URIs and the cut flag.
///
/// Paste-into-self uses the internal board only while GDK still owns
/// this export; external offers use a separate bounded read. Remote
/// entries export their TEXT form only (the path on that host, which
/// is what a paste into a terminal or editor wants); the file:// list
/// is skipped because a local file manager would use this disk.
fn exportClipToGdk(board: *clipboard.Board, clip: *c.GdkClipboard) bool {
    // Disconnect before replacing content: set_content emits changed
    // synchronously, and the old owner must not clear the new board.
    file_clipboard_owner.release();
    var exported = false;
    defer if (!exported) {
        board.clear();
        // Do not leave a previous cut export available for re-import.
        _ = c.gdk_clipboard_set_content(clip, null);
    };
    if (board.isEmpty()) return false;
    const local = board.host == null;
    const a = board.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var gnome: std.ArrayList(u8) = .empty;
    defer gnome.deinit(a);
    gnome.appendSlice(a, if (board.cut) "cut" else "copy") catch return false;
    for (board.items(), 0..) |p, i| {
        if (i > 0) text.append(a, '\n') catch return false;
        text.appendSlice(a, p) catch return false;
        if (!local) continue;
        const pz = a.dupeZ(u8, p) catch return false;
        defer a.free(pz);
        const uri = c.g_filename_to_uri(pz.ptr, null, null) orelse return false;
        defer c.g_free(uri);
        gnome.append(a, '\n') catch return false;
        gnome.appendSlice(a, std.mem.span(@as([*:0]const u8, @ptrCast(uri)))) catch return false;
    }
    text.append(a, 0) catch return false;
    // The typed provider copies the string into its GValue; the union
    // takes ownership of its providers; set_content refs the union,
    // so our own ref is dropped afterwards.
    const text_provider = c.gdk_content_provider_new_typed(c.G_TYPE_STRING, text.items.ptr);
    const provider = if (local) blk: {
        const bytes = c.g_bytes_new(gnome.items.ptr, gnome.items.len);
        defer c.g_bytes_unref(bytes);
        const gnome_provider = c.gdk_content_provider_new_for_bytes(clipboard.GNOME, bytes);
        const uris = gnome.items[if (board.cut) @as(usize, 4) else 5..];
        const uri_bytes = c.g_bytes_new(uris.ptr, uris.len);
        defer c.g_bytes_unref(uri_bytes);
        const uri_provider = c.gdk_content_provider_new_for_bytes(clipboard.URI, uri_bytes);
        const cut_bytes = c.g_bytes_new(if (board.cut) "1" else "0", 1);
        defer c.g_bytes_unref(cut_bytes);
        const cut_provider = c.gdk_content_provider_new_for_bytes(clipboard.KDE_CUT, cut_bytes);
        var providers = [_]?*c.GdkContentProvider{ gnome_provider, uri_provider, cut_provider, text_provider };
        break :blk c.gdk_content_provider_new_union(&providers, providers.len);
    } else text_provider;
    defer c.g_object_unref(@as(?*anyopaque, @ptrCast(provider)));
    if (c.gdk_clipboard_set_content(clip, provider) == 0) return false;
    _ = c.g_object_ref(clip);
    _ = c.g_object_ref(provider);
    file_clipboard_owner = .{
        .clip = clip,
        .provider = provider,
        .changed = c.g_signal_connect_data(clip, "changed", @ptrCast(&onFileClipboardChanged), null, null, c.G_CONNECT_DEFAULT),
    };
    if (file_clipboard_owner.changed == 0 or c.gdk_clipboard_get_content(clip) != provider) {
        file_clipboard_owner.release();
        return false;
    }
    exported = true;
    return true;
}

/// Chord-driven paste (Ctrl+V): the clipboard into the current tab.
/// The board is process-wide, so the copy may well have been made in
/// another pane, on another host.
pub fn pasteIntoCurrent(self: *BrowserView) void {
    const tab = self.currentTab() orelse return;
    pasteIntoTab(self, tab);
}

pub fn canPaste(self: *BrowserView, tab: *BTab) bool {
    if (!self.clipboard().isEmpty()) return true;
    const clip = c.gtk_widget_get_clipboard(@ptrCast(@alignCast(tab.colview))) orelse return false;
    if (file_clipboard_owner.clip == clip and c.gdk_clipboard_get_content(clip) == file_clipboard_owner.provider) return false;
    const formats = c.gdk_clipboard_get_formats(clip);
    return c.gdk_content_formats_contain_mime_type(formats, clipboard.GNOME) != 0 or
        c.gdk_content_formats_contain_mime_type(formats, clipboard.URI) != 0;
}

pub fn pasteIntoTab(self: *BrowserView, tab: *BTab) void {
    if (self.widgets_dead) return;
    if (self.picker) |picker| if (picker.suppress_ops) return;
    cancelExternalPaste(self, null);
    const board = self.clipboard();
    if (!board.isEmpty()) {
        _ = self.beginPaste(tab, board.hostOpt(), board.items(), board.cut, true);
        return;
    }
    if (!canPaste(self, tab)) {
        self.setStatus("clipboard contains no supported files");
        return;
    }
    const clip = c.gtk_widget_get_clipboard(@ptrCast(@alignCast(tab.colview))) orelse return;
    const formats = c.gdk_clipboard_get_formats(clip);
    const gnome = c.gdk_content_formats_contain_mime_type(formats, clipboard.GNOME) != 0;
    if (!gnome and c.gdk_content_formats_contain_mime_type(formats, clipboard.URI) == 0) {
        self.setStatus("clipboard contains no supported files");
        return;
    }
    const read = self.allocator.create(ExternalPaste) catch {
        self.setStatus("paste not started: out of memory");
        return;
    };
    read.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = tab,
        .generation = tab.navigation_generation,
        .view_id = tab.root.view_id,
        .clip = clip,
        .cancel = c.g_cancellable_new().?,
        .kind = if (gnome) .gnome else .uri,
        .kde_hint = !gnome and c.gdk_content_formats_contain_mime_type(formats, clipboard.KDE_CUT) != 0,
    };
    _ = c.g_object_ref(clip);
    self.external_paste = read;
    read.changed = c.g_signal_connect_data(clip, "changed", @ptrCast(&ExternalPaste.clipChanged), read, null, c.G_CONNECT_DEFAULT);
    read.timeout = c.g_timeout_add(10_000, &ExternalPaste.timedOut, read);
    self.setStatus("reading files from clipboard...");
    read.open();
}

/// The async callbacks own this allocation. Teardown severs `view` and
/// cancels IO; only the final callback releases the request's storage.
pub const ExternalPaste = struct {
    allocator: std.mem.Allocator,
    view: ?*BrowserView,
    tab: *BTab,
    generation: u64,
    view_id: u32,
    clip: *c.GdkClipboard,
    cancel: *c.GCancellable,
    stream: ?*c.GInputStream = null,
    kind: enum { gnome, uri, kde_cut },
    kde_hint: bool,
    data: std.ArrayList(u8) = .empty,
    board: ?clipboard.Board = null,
    failure: ?[]const u8 = null,
    changed: c.gulong = 0,
    timeout: c.guint = 0,

    fn open(self: *ExternalPaste) void {
        const mime: [*:0]const u8 = switch (self.kind) {
            .gnome => clipboard.GNOME,
            .uri => clipboard.URI,
            .kde_cut => clipboard.KDE_CUT,
        };
        var mimes = [_:null]?[*:0]const u8{mime};
        c.gdk_clipboard_read_async(self.clip, @ptrCast(&mimes), c.G_PRIORITY_DEFAULT, self.cancel, &opened, self);
    }

    fn clipChanged(_: *c.GdkClipboard, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(ExternalPaste, user);
        self.failure = "clipboard changed; paste canceled";
        c.g_cancellable_cancel(self.cancel);
    }

    fn timedOut(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(ExternalPaste, user);
        self.timeout = 0;
        self.failure = "clipboard did not respond; paste canceled";
        c.g_cancellable_cancel(self.cancel);
        return 0;
    }

    fn opened(source: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(ExternalPaste, user);
        self.stream = c.gdk_clipboard_read_finish(@ptrCast(source), result, null, null);
        if (self.stream == null or self.view == null or self.failure != null) {
            self.finish("could not read files from clipboard");
            return;
        }
        self.readMore();
    }

    fn readMore(self: *ExternalPaste) void {
        c.g_input_stream_read_bytes_async(self.stream.?, 16 * 1024, c.G_PRIORITY_DEFAULT, self.cancel, &chunk, self);
    }

    fn chunk(source: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(ExternalPaste, user);
        const bytes = c.g_input_stream_read_bytes_finish(@ptrCast(source), result, null);
        defer if (bytes) |b| c.g_bytes_unref(b);
        if (bytes == null or self.view == null or self.failure != null) {
            self.finish("could not read files from clipboard");
            return;
        }
        var size: c.gsize = 0;
        const raw = c.g_bytes_get_data(bytes, &size);
        if (size > 0) {
            const limit: usize = if (self.kind == .kde_cut) 16 else clipboard.MAX_EXTERNAL_BYTES;
            if (size > limit - self.data.items.len) {
                self.finish("file clipboard is too large; paste canceled");
                return;
            }
            const data: [*]const u8 = @ptrCast(raw.?);
            self.data.appendSlice(self.allocator, data[0..size]) catch {
                self.finish("paste canceled: out of memory");
                return;
            };
            self.readMore();
            return;
        }
        if (self.kind == .kde_cut) {
            const hint = std.mem.trim(u8, self.data.items, "\r\n");
            if (!std.mem.eql(u8, hint, "0") and !std.mem.eql(u8, hint, "1")) {
                self.finish("invalid clipboard cut flag; paste canceled");
                return;
            }
            self.board.?.cut = std.mem.eql(u8, hint, "1");
        } else {
            self.board = clipboard.parseExternal(self.allocator, self.data.items, self.kind == .gnome) catch |err| {
                self.finish(switch (err) {
                    error.OutOfMemory => "paste canceled: out of memory",
                    error.PayloadTooLarge, error.TooManyFiles => "file clipboard is too large; paste canceled",
                    else => "clipboard must contain valid local file URIs; paste canceled",
                });
                return;
            };
            if (self.kde_hint) {
                self.kind = .kde_cut;
                self.data.clearRetainingCapacity();
                c.g_object_unref(self.stream.?);
                self.stream = null;
                self.open();
                return;
            }
        }
        self.finish(null);
    }

    fn finish(self: *ExternalPaste, failure: ?[]const u8) void {
        if (self.changed != 0) c.g_signal_handler_disconnect(self.clip, self.changed);
        if (self.timeout != 0) _ = c.g_source_remove(self.timeout);
        defer {
            if (self.stream) |stream| c.g_object_unref(stream);
            c.g_object_unref(self.clip);
            c.g_object_unref(self.cancel);
            self.data.deinit(self.allocator);
            if (self.board) |*board| board.deinit();
            self.allocator.destroy(self);
        }
        const view = self.view orelse return;
        view.external_paste = null;
        if (view.widgets_dead) return;
        if (self.failure orelse failure) |message| {
            view.setStatus(message);
            return;
        }
        if (!view.tabAlive(self.tab) or self.tab.navigation_generation != self.generation or self.tab.root.view_id != self.view_id) {
            view.setStatus("destination changed; paste canceled");
            return;
        }
        const board = &self.board.?;
        // file: URIs always name this machine, even in a remote tab.
        if (view.beginPaste(self.tab, null, board.items(), board.cut, false) and board.cut)
            _ = c.gdk_clipboard_set_content(self.clip, null);
    }
};

pub fn cancelExternalPaste(self: *BrowserView, tab: ?*BTab) void {
    const read = self.external_paste orelse return;
    if (tab != null and read.tab != tab.?) return;
    self.external_paste = null;
    read.view = null;
    c.g_cancellable_cancel(read.cancel);
}

/// Is `tab` still one of this view's tabs? Anything that parks work
/// against a tab and acts on it LATER (the conflict queue, the
/// template menu) must ask, because the user can close the tab in
/// between and the pointer would be stale.
pub fn tabAlive(self: *BrowserView, tab: *BTab) bool {
    for (self.tabs.items) |t| {
        if (t == tab) return true;
    }
    return false;
}

pub fn cancelDropStateForTab(self: *BrowserView, tab: *BTab) void {
    cancelExternalPaste(self, tab);
    var i: usize = 0;
    while (i < self.drop_probes.items.len) {
        const probe = self.drop_probes.items[i];
        if (probe.tab != tab) {
            i += 1;
            continue;
        }
        _ = self.drop_probes.orderedRemove(i);
        if (probe.manifest_token) |token| if (self.transfer_service) |service|
            service.unclaimUserBatch(token);
        probe.destroy(self.allocator);
    }
    // Non-conflicting items already carry their exact destination and
    // can continue without the tab. A later conflict needs a live page
    // for its decision UI, so null the pointer before the tab dies.
    for (self.paste_runs.items) |run| {
        if (run.tab == tab) run.tab = null;
    }
    conflict.cancelTab(self, tab);
}

/// Pick a destination name that does not collide with the live
/// target listing: "name (copy).ext", then "name (copy 2).ext"… The
/// entry's own row (when the listing has it) says whether it is a
/// directory, whose dots are never mistaken for an extension.
pub fn uniqueDstName(tab: *BTab, base: []const u8, buf: []u8) ?[]const u8 {
    const is_dir = if (tab.root.find(base)) |i| tab.root.entries.items[i].tdir else false;
    return uniqueDstNameIn(tab, tab.root.path, base, is_dir, buf);
}

pub fn uniqueDstNameIn(tab: *BTab, dir_path: []const u8, base: []const u8, is_dir: bool, buf: []u8) ?[]const u8 {
    const dir = if (std.mem.eql(u8, dir_path, tab.root.path)) tab.root else tab.subdirByPath(dir_path) orelse return null;
    const Listing = struct {
        dir: *Dir,
        pub fn contains(self: @This(), name: []const u8) bool {
            return self.dir.find(name) != null;
        }
    };
    return uniqueName(base, is_dir, buf, Listing{ .dir = dir });
}

/// Per-item paste modifiers. `dir_mode` reaches the daemon copy verb
/// verbatim; `undoable` is false for merge and replace, which cannot
/// be reversed by deleting what was created (a merge leaves the
/// destination's own files in place, a replace destroyed them).
pub const PasteOpts = struct {
    dir_mode: []const u8 = "",
    undoable: bool = true,
    no_replace: bool = false,
    batch_id: u64 = 0,
    batch_total: usize = 0,
};

const PasteBatchAction = enum { preserve_failure, rejected, conflicts, nothing, queued };

fn pasteBatchAction(admitted: usize, conflicts: usize, rejected: usize, concrete_failure: bool) PasteBatchAction {
    if (rejected > 0) return if (concrete_failure) .preserve_failure else .rejected;
    if (conflicts > 0) return .conflicts;
    if (admitted == 0) return .nothing;
    return .queued;
}

fn statusSnapshot(self: *BrowserView, buf: *[256]u8) []const u8 {
    const raw = c.gtk_label_get_text(self.status_label) orelse return buf[0..0];
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

fn rememberFailureStatus(self: *BrowserView, saved: *[256]u8, saved_len: *usize) void {
    var status_buf: [256]u8 = undefined;
    const status = statusSnapshot(self, &status_buf);
    @memcpy(saved[0..status.len], status);
    saved_len.* = status.len;
}

/// Copy/move `sources` (living on `src_host`) into `tab`'s directory.
/// Names that are free start IMMEDIATELY; names that collide are
/// parked in conflict.zig's queue and decided while the rest of the
/// batch is already copying. The clipboard is only consulted by the
/// caller, so a dual-pane send uses the same path as Paste Here.
/// True means every actionable item was admitted or journaled. A partial
/// admission keeps the original cut clipboard available for retry.
pub fn beginPaste(
    self: *BrowserView,
    tab: *BTab,
    src_host: ?[]const u8,
    srcs: []const []u8,
    cut: bool,
    clear_clipboard: bool,
) bool {
    const src_hc = self.hostConnFor(src_host) orelse {
        self.setStatus("paste not started: cannot allocate a host connection");
        return false;
    };
    if (tab.hc.state == .ready and !tab.hc.io().caps.copy_no_replace) {
        self.setStatusFmt("paste not queued: {s} lacks safe no-replace support", .{tab.hc.label()});
        return false;
    }
    const run = self.allocator.create(PasteRun) catch {
        self.setStatus("paste not started: out of memory");
        return false;
    };
    const dst_dir = self.allocator.dupe(u8, tab.root.path) catch {
        self.allocator.destroy(run);
        self.setStatus("paste not started: out of memory");
        return false;
    };
    const src_host_owned = if (src_host) |host| self.allocator.dupe(u8, host) catch {
        self.allocator.free(dst_dir);
        self.allocator.destroy(run);
        self.setStatus("paste not started: out of memory");
        return false;
    } else null;
    run.* = .{
        .tab = tab,
        .src_hc = src_hc,
        .dst_hc = tab.hc,
        .src_host = src_host_owned,
        .dst_dir = dst_dir,
        .cut = cut,
        .batch_id = 0,
        .total = 0,
    };
    var existing: std.StringHashMapUnmanaged(bool) = .empty;
    defer existing.deinit(self.allocator);
    for (tab.root.entries.items) |entry|
        existing.put(self.allocator, entry.name, entry.tdir) catch {};
    var duplicated: usize = 0;
    var refused_self: usize = 0;
    for (srcs) |src| {
        const base = std.fs.path.basename(src);
        var dst_buf: [4096]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
            if (dst_dir.len == 1) "" else dst_dir, base,
        }) catch {
            rejectPasteItem(self, run, "paste not queued: destination path is too long");
            continue;
        };
        // Pasting an entry into its own folder: a move is a no-op, a
        // copy lands beside the original under a free name ("x (copy)"),
        // the way every file manager answers Ctrl+C, Ctrl+V in place.
        // It used to be a silent "nothing to paste here" for both.
        if (hostEq(src_host, tab.hc.host) and std.mem.eql(u8, src, dst)) {
            if (!cut) {
                if (duplicateEntry(self, tab, src)) {
                    duplicated += 1;
                } else {
                    run.rejected += 1;
                    rememberFailureStatus(self, &run.failure, &run.failure_len);
                }
            }
            continue;
        }
        // Copy a folder, walk into it, paste: the names differ, so the
        // equality above admits it and the copy job recurses into the
        // copy it is making. Same rule as the drop path.
        if (hostEq(src_host, tab.hc.host) and dirWithin(dst_dir, src)) {
            refused_self += 1;
            self.setStatusFmt("paste refused: {s} cannot go inside itself", .{base});
            run.rejected += 1;
            rememberFailureStatus(self, &run.failure, &run.failure_len);
            continue;
        }
        const src_owned = self.allocator.dupe(u8, src) catch {
            rejectPasteItem(self, run, "paste not queued: out of memory");
            continue;
        };
        const dst_owned = self.allocator.dupe(u8, dst) catch {
            self.allocator.free(src_owned);
            rejectPasteItem(self, run, "paste not queued: out of memory");
            continue;
        };
        run.items.append(self.allocator, .{
            .src = src_owned,
            .dst = dst_owned,
            .collision_is_dir = existing.get(base),
        }) catch {
            self.allocator.free(src_owned);
            self.allocator.free(dst_owned);
            rejectPasteItem(self, run, "paste not queued: out of memory");
        };
    }
    if (run.items.items.len == 0) {
        defer run.destroy(self.allocator);
        // The refusal has to survive: "nothing to paste here" reads as
        // an empty clipboard, which is the one thing it is not.
        if (run.rejected > 0)
            finishPasteRun(self, run)
        else if (refused_self > 0)
            self.setStatus("paste refused: a folder cannot go inside itself")
        else if (duplicated > 0)
            self.setStatusFmt("duplicating {d} item(s) in place", .{duplicated})
        else
            self.setStatus("nothing to paste here");
        return duplicated > 0 and run.rejected == 0;
    }
    run.total = run.items.items.len;
    if (run.total > 1) run.batch_id = newBatchId();

    if (hostEq(src_host, tab.hc.host)) {
        // Same-host admission does not need the client-side manifest.
        // Park conflicts first and submit every free name directly.
        var item_index: usize = 0;
        while (item_index < run.items.items.len) {
            const item = run.items.items[item_index];
            if (item.collision_is_dir == null) {
                item_index += 1;
                continue;
            }
            queuePasteConflict(self, run, item, item.collision_is_dir.?);
            _ = run.items.orderedRemove(item_index);
            item.deinit(self.allocator);
        }
        // Same-host admission has no client-side fsync and completed in
        // one short callback even for hundreds of files. Keep it
        // synchronous so every daemon request exists before return.
        while (run.next < run.items.items.len) {
            admitPasteItem(self, run, run.items.items[run.next]);
            run.next += 1;
        }
        const complete = run.rejected == 0 and (run.admitted > 0 or run.conflicts > 0 or duplicated > 0);
        if (cut and clear_clipboard and complete) self.clipboard().clear();
        finishPasteRun(self, run);
        run.destroy(self.allocator);
        self.renderJobs();
        return complete;
    }

    const service = self.transfer_service orelse {
        conflict.cancelBatch(self, run.batch_id);
        run.destroy(self.allocator);
        self.setStatus("paste not started because durable recovery is unavailable");
        return false;
    };
    if (run.batch_id == 0) run.batch_id = newBatchId();
    const specs = self.allocator.alloc(@import("../file_transfers.zig").BatchSpec, run.items.items.len) catch {
        conflict.cancelBatch(self, run.batch_id);
        run.destroy(self.allocator);
        self.setStatus("paste not started: out of memory");
        return false;
    };
    defer self.allocator.free(specs);
    for (run.items.items, 0..) |item, i| specs[i] = .{
        .src_path = item.src,
        .dst_path = item.dst,
        .conflict_is_dir = item.collision_is_dir,
    };
    const manifest = service.newUserBatch(
        src_host orelse "",
        tab.hc.host orelse "",
        cut,
        run.batch_id,
        run.total,
        specs,
        @ptrCast(self),
    ) orelse {
        conflict.cancelBatch(self, run.batch_id);
        run.destroy(self.allocator);
        self.setStatus("paste not started because its batch recovery record could not be saved");
        return false;
    };
    const complete = run.rejected == 0;
    if (cut and clear_clipboard and complete) self.clipboard().clear();
    run.manifest_token = self.allocator.dupe(u8, manifest) catch {
        service.redispatchUserBatch(manifest);
        run.destroy(self.allocator);
        self.setStatus("paste recovery was saved but could not be attached to this pane");
        return complete;
    };
    for (run.items.items, 0..) |*item, i| item.manifest_index = i;
    self.paste_runs.append(self.allocator, run) catch {
        service.redispatchUserBatch(manifest);
        run.destroy(self.allocator);
        self.setStatus("paste recovery was saved but could not be attached to this pane");
        return complete;
    };
    self.setStatusFmt("queuing 0 of {d} transfer(s)", .{run.total});
    self.renderJobs();
    if (self.paste_idle == 0)
        self.paste_idle = c.g_idle_add(@ptrCast(&onPasteIdle), @ptrCast(self));
    return complete;
}

fn rejectPasteItem(self: *BrowserView, run: *PasteRun, message: []const u8) void {
    run.rejected += 1;
    self.setStatus(message);
    rememberFailureStatus(self, &run.failure, &run.failure_len);
}

fn queuePasteConflict(self: *BrowserView, run: *PasteRun, item: PasteItem, is_dir: bool) void {
    if (run.tab) |tab| {
        const queued_before = self.conflicts.queue.items.len;
        conflict.enqueue(self, tab, run.src_hc, run.src_host, item.src, item.dst, is_dir, run.cut, run.batch_id, run.total, if (run.manifest_token) |token| .{
            .token = token,
            .index = item.manifest_index.?,
        } else null);
        if (self.conflicts.queue.items.len > queued_before) {
            run.conflicts += 1;
            return;
        }
    }
    run.rejected += 1;
    self.setStatusFmt("paste conflict could not be queued: {s}", .{std.fs.path.basename(item.src)});
    rememberFailureStatus(self, &run.failure, &run.failure_len);
}

fn admitPasteItem(self: *BrowserView, run: *PasteRun, item: PasteItem) void {
    const opts = @import("jobs.zig").TransferOpts{
        .delete_src_after = run.cut,
        .no_replace = run.no_replace,
        .batch_id = run.batch_id,
        .batch_total = run.total,
    };
    const admitted = if (run.manifest_token) |manifest|
        self.startBatchTransfer(run.src_hc, item.src, run.dst_hc, item.dst, opts, manifest, item.manifest_index.?)
    else
        pasteOneAdmittedOn(self, run.dst_hc, run.src_host, item.src, item.dst, run.cut, .{
            .no_replace = run.no_replace,
            .batch_id = run.batch_id,
            .batch_total = run.total,
        });
    if (admitted) {
        run.admitted += 1;
    } else {
        run.rejected += 1;
        rememberFailureStatus(self, &run.failure, &run.failure_len);
    }
}

fn finishPasteRun(self: *BrowserView, run: *PasteRun) void {
    if (run.rejected > 0 and (run.admitted > 0 or run.conflicts > 0)) {
        self.setStatusFmt("{d} queued; {d} conflicts; {d} not queued: {s}", .{
            run.admitted, run.conflicts, run.rejected, run.failure[0..run.failure_len],
        });
        return;
    }
    switch (pasteBatchAction(run.admitted, run.conflicts, run.rejected, run.failure_len > 0)) {
        .preserve_failure => self.setStatus(run.failure[0..run.failure_len]),
        .rejected => self.setStatusFmt("{d} item(s) could not be queued", .{run.rejected}),
        .conflicts => self.setStatusFmt("{d} item(s) queued; {d} name conflict(s) waiting for a decision", .{ run.admitted, run.conflicts }),
        .nothing => self.setStatus("nothing to paste here"),
        .queued => self.setStatusFmt("{d} transfer(s) queued", .{run.admitted}),
    }
}

fn onPasteIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(BrowserView, user);
    if (self.widgets_dead or self.paste_runs.items.len == 0) {
        self.paste_idle = 0;
        return 0;
    }
    const run = self.paste_runs.items[0];
    if (run.next < run.items.items.len) {
        const item = run.items.items[run.next];
        run.next += 1;
        if (item.collision_is_dir) |is_dir| {
            queuePasteConflict(self, run, item, is_dir);
        } else {
            admitPasteItem(self, run, item);
        }
        if (run.next < run.items.items.len)
            self.setStatusFmt("queuing {d} of {d} transfer(s)", .{ run.next, run.total });
        self.renderJobs();
    }
    if (run.next < run.items.items.len) return 1;
    finishPasteRun(self, run);
    const manifest = run.manifest_token;
    run.manifest_token = null;
    _ = self.paste_runs.orderedRemove(0);
    run.destroy(self.allocator);
    if (manifest) |token| {
        self.settleUserBatch(token);
        self.allocator.free(token);
    }
    self.renderJobs();
    if (self.paste_runs.items.len > 0) return 1;
    self.paste_idle = 0;
    return 0;
}

/// Rebuild an interrupted admission run from its durable manifest.
pub fn adoptPasteBatch(ctx: *anyopaque, rec: @import("../file_transfers.zig").BatchRec) void {
    const self: *BrowserView = @ptrCast(@alignCast(ctx));
    for (self.paste_runs.items) |run| {
        if (run.manifest_token) |token| {
            if (std.mem.eql(u8, token, rec.token)) return;
        }
    }
    const service = self.transfer_service orelse return;
    const src_hc = self.hostConnFor(if (rec.src_host.len == 0) null else rec.src_host) orelse {
        service.unclaimUserBatch(rec.token);
        return;
    };
    const dst_hc = self.hostConnFor(if (rec.dst_host.len == 0) null else rec.dst_host) orelse {
        service.unclaimUserBatch(rec.token);
        return;
    };
    if (rec.items.len == 0) {
        _ = service.finishUserBatch(rec.token);
        return;
    }
    var target_tab: ?*BTab = null;
    for (rec.items, 0..) |item, i| {
        if (item.conflict_is_dir == null or service.userBatchItemMaterialized(rec.token, i)) continue;
        const dir = std.fs.path.dirname(item.dst_path) orelse "/";
        for (self.tabs.items) |tab| {
            if (tab.hc != dst_hc) continue;
            if (std.mem.eql(u8, tab.root.path, dir) or tab.subdirByPath(dir) != null) {
                target_tab = tab;
                break;
            }
        }
        if (target_tab == null) {
            service.unclaimUserBatch(rec.token);
            return;
        }
        break;
    }
    const run = self.allocator.create(PasteRun) catch {
        service.unclaimUserBatch(rec.token);
        return;
    };
    const first_dir = std.fs.path.dirname(rec.items[0].dst_path) orelse "/";
    const dst_dir = self.allocator.dupe(u8, first_dir) catch {
        self.allocator.destroy(run);
        service.unclaimUserBatch(rec.token);
        return;
    };
    const src_host = if (rec.src_host.len > 0) self.allocator.dupe(u8, rec.src_host) catch {
        self.allocator.free(dst_dir);
        self.allocator.destroy(run);
        service.unclaimUserBatch(rec.token);
        return;
    } else null;
    const manifest = self.allocator.dupe(u8, rec.token) catch {
        if (src_host) |host| self.allocator.free(host);
        self.allocator.free(dst_dir);
        self.allocator.destroy(run);
        service.unclaimUserBatch(rec.token);
        return;
    };
    run.* = .{
        .tab = target_tab,
        .src_hc = src_hc,
        .dst_hc = dst_hc,
        .src_host = src_host,
        .dst_dir = dst_dir,
        .cut = rec.move,
        .no_replace = rec.no_replace,
        .batch_id = rec.batch_id,
        .total = @intCast(rec.batch_total),
        .manifest_token = manifest,
    };
    for (rec.items, 0..) |item, i| {
        if (service.userBatchItemMaterialized(rec.token, i)) continue;
        const src = self.allocator.dupe(u8, item.src_path) catch break;
        const dst = self.allocator.dupe(u8, item.dst_path) catch {
            self.allocator.free(src);
            break;
        };
        run.items.append(self.allocator, .{
            .src = src,
            .dst = dst,
            .collision_is_dir = item.conflict_is_dir,
            .manifest_index = i,
        }) catch {
            self.allocator.free(src);
            self.allocator.free(dst);
            break;
        };
    }
    const remaining = for (rec.items, 0..) |_, i| {
        if (!service.userBatchItemMaterialized(rec.token, i)) break false;
    } else true;
    if (remaining) {
        run.destroy(self.allocator);
        _ = service.finishUserBatch(rec.token);
        return;
    }
    var expected_remaining: usize = 0;
    for (rec.items, 0..) |_, i| if (!service.userBatchItemMaterialized(rec.token, i)) {
        expected_remaining += 1;
    };
    if (run.items.items.len != expected_remaining) {
        run.destroy(self.allocator);
        service.unclaimUserBatch(rec.token);
        return;
    }
    self.paste_runs.append(self.allocator, run) catch {
        run.destroy(self.allocator);
        service.unclaimUserBatch(rec.token);
        return;
    };
    self.setStatusFmt("recovering transfer batch: {d} item(s)", .{run.total});
    self.renderJobs();
    if (self.paste_idle == 0)
        self.paste_idle = c.g_idle_add(@ptrCast(&onPasteIdle), @ptrCast(self));
}

/// Resolve an interactive conflict through its deterministic manifest
/// child when this command was persisted as a cross-host batch.
pub fn resolvePasteConflict(
    self: *BrowserView,
    tab: *BTab,
    src_host: ?[]const u8,
    src: []const u8,
    dst: []const u8,
    cut: bool,
    opts: PasteOpts,
    manifest_token: ?[]const u8,
    manifest_index: ?usize,
    skip: bool,
) bool {
    const manifest = manifest_token orelse {
        if (skip) return true;
        return pasteOneAdmitted(self, tab, src_host, src, dst, cut, opts);
    };
    const index = manifest_index orelse return false;
    const service = self.transfer_service orelse return false;
    const admitted = if (skip)
        service.skipUserBatchItem(manifest, index, @ptrCast(self))
    else blk: {
        const src_hc = self.hostConnFor(src_host) orelse break :blk false;
        break :blk self.startBatchTransfer(src_hc, src, tab.hc, dst, .{
            .delete_src_after = cut,
            .no_replace = opts.no_replace,
            .batch_id = opts.batch_id,
            .batch_total = opts.batch_total,
        }, manifest, index);
    };
    if (!admitted) return false;
    self.settleUserBatch(manifest);
    return true;
}

/// Retire a fully materialized manifest, or release an incomplete one
/// only when no live probe/conflict still owns its missing children.
pub fn settleUserBatch(self: *BrowserView, token: []const u8) void {
    const service = self.transfer_service orelse return;
    if (service.finishUserBatch(token)) return;
    for (self.paste_runs.items) |run| if (run.manifest_token) |active| {
        if (std.mem.eql(u8, active, token)) return;
    };
    for (self.drop_probes.items) |probe| if (probe.manifest_token) |active| {
        if (std.mem.eql(u8, active, token)) return;
    };
    for (self.conflicts.queue.items) |item| if (item.manifest_token) |active| {
        if (std.mem.eql(u8, active, token)) return;
    };
    service.unclaimUserBatch(token);
}

/// Start ONE source's copy (or move) to an exact destination path.
/// Every paste path funnels through here, so same-host vs cross-host
/// and the undo bookkeeping are decided in one place.
pub fn pasteOne(
    self: *BrowserView,
    tab: *BTab,
    src_host: ?[]const u8,
    src: []const u8,
    dst: []const u8,
    cut: bool,
    opts: PasteOpts,
) void {
    _ = pasteOneAdmitted(self, tab, src_host, src, dst, cut, opts);
}

fn transferAdmissionCount(self: *BrowserView) usize {
    return self.pending_jobs.items.len +
        self.copy_queue.items.items.len +
        self.deferred_transfers.items.len +
        self.transfers.items.len;
}

/// Start one paste and report whether it reached an owned queue.
fn pasteOneAdmitted(
    self: *BrowserView,
    tab: *BTab,
    src_host: ?[]const u8,
    src: []const u8,
    dst: []const u8,
    cut: bool,
    opts: PasteOpts,
) bool {
    return pasteOneAdmittedOn(self, tab.hc, src_host, src, dst, cut, opts);
}

fn pasteOneAdmittedOn(
    self: *BrowserView,
    dst_hc: *HostConn,
    src_host: ?[]const u8,
    src: []const u8,
    dst: []const u8,
    cut: bool,
    opts: PasteOpts,
) bool {
    const base = std.fs.path.basename(src);
    if (opts.no_replace and dst_hc.state == .ready and !dst_hc.io().caps.copy_no_replace) {
        self.setStatusFmt("operation not queued: {s} lacks safe no-replace support", .{dst_hc.label()});
        return false;
    }
    if (hostEq(src_host, dst_hc.host)) {
        if (dst_hc.state != .ready) {
            self.setStatusFmt("not connected to {s}", .{dst_hc.label()});
            return false;
        }
        if (cut) {
            // Same-host move = one rename, undoable.
            const req = self.nextReq();
            const undo = self.makeUndo(dst_hc.host, .rename_back, dst, src, "");
            if (!self.sendOpOk(dst_hc, .{ .req = req, .op = "rename", .path = src, .to = dst, .no_replace = opts.no_replace })) {
                if (undo) |op| op.destroy(self.allocator);
                return false;
            }
            self.deferUndoMode(req, undo, opts.no_replace);
            return true;
        }
        var lbl: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&lbl, "copy {s}", .{base}) catch base;
        const undo = if (opts.undoable)
            self.makeUndo(dst_hc.host, .delete_created, dst, src, "")
        else
            null;
        const admitted = self.startDaemonJobUndo(dst_hc, "copy", src, dst, label, undo, .{
            .dir_mode = opts.dir_mode,
            .no_replace = opts.no_replace,
            .batch_id = opts.batch_id,
            .batch_total = opts.batch_total,
        });
        if (!admitted) self.setStatusFmt("copy not queued: {s}", .{base});
        return admitted;
    }
    const src_hc = self.hostConnFor(src_host) orelse {
        self.setStatus("transfer not queued: cannot allocate a host connection");
        return false;
    };
    const before = transferAdmissionCount(self);
    var status_before_buf: [256]u8 = undefined;
    const status_before = statusSnapshot(self, &status_before_buf);
    self.startTransfer(src_hc, src, dst_hc, dst, .{
        .delete_src_after = cut,
        .no_replace = opts.no_replace,
        .batch_id = opts.batch_id,
        .batch_total = opts.batch_total,
    });
    const admitted = transferAdmissionCount(self) > before;
    if (!admitted) {
        var status_after_buf: [256]u8 = undefined;
        const status_after = statusSnapshot(self, &status_after_buf);
        if (std.mem.eql(u8, status_before, status_after))
            self.setStatusFmt("transfer not queued: {s}", .{base});
    }
    return admitted;
}

/// Copy an entry beside itself under a free name ("x.txt" -> "x (copy).txt").
/// Undoable like any other copy: the created path is what undo drops.
pub fn duplicateEntry(self: *BrowserView, tab: *BTab, path: []const u8) bool {
    const base = std.fs.path.basename(path);
    var name_buf: [512]u8 = undefined;
    const unique = uniqueDstName(tab, base, &name_buf) orelse {
        self.setStatusFmt("no free name beside {s}", .{base});
        return false;
    };
    const dir = std.fs.path.dirname(path) orelse "/";
    var dst_buf: [4096]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
        if (dir.len == 1) "" else dir, unique,
    }) catch {
        self.setStatus("duplicate not queued: destination path is too long");
        return false;
    };
    var lbl: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&lbl, "duplicate {s}", .{base}) catch "duplicate";
    if (!self.startDaemonJobUndo(tab.hc, "copy", path, dst, label, self.makeUndo(tab.hc.host, .delete_created, dst, path, ""), .{ .no_replace = true })) return false;
    self.setStatusFmt("duplicating {s} -> {s}", .{ base, unique });
    return true;
}

/// Create a link to `target` in `tab`'s directory. Both kinds go
/// through one path: only the wire verb and the undo payload differ.
pub fn linkHere(self: *BrowserView, tab: *BTab, target: []const u8, hard: bool) void {
    const base = std.fs.path.basename(target);
    var name_buf: [512]u8 = undefined;
    // A link beside its own target needs a free name; a link in
    // another directory keeps the original one.
    const dir = tab.root.path;
    var name: []const u8 = base;
    if (tab.root.find(base) != null) {
        name = uniqueDstName(tab, base, &name_buf) orelse {
            self.setStatusFmt("no free name for a link to {s}", .{base});
            return;
        };
    }
    var link_buf: [4096]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buf, "{s}/{s}", .{
        if (dir.len == 1) "" else dir, name,
    }) catch return;
    const req = self.nextReq();
    self.deferUndo(req, self.makeUndo(
        tab.hc.host,
        .link_created,
        link,
        target,
        if (hard) "hardlink" else "symlink",
    ));
    self.sendOp(tab.hc, .{
        .req = req,
        .op = if (hard) "hardlink" else "symlink",
        .path = link,
        .to = target,
    });
    self.setStatusFmt("{s} link: {s} -> {s}", .{ if (hard) "hard" else "symbolic", name, target });
}

/// Can a hard link from `tab`'s directory to the clipboard source
/// possibly work? Same host and same filesystem, decided from the
/// device id the daemon ships with each listing -- the verb is only
/// offered where it can succeed, never offered and then failed.
pub fn hardlinkPossible(self: *BrowserView, tab: *BTab) bool {
    const board = self.clipboard();
    if (board.isEmpty()) return false;
    if (!hostEq(board.hostOpt(), tab.hc.host)) return false;
    return board.dev != 0 and board.dev == tab.root.dev;
}

pub fn findEntryTags(tab: *BTab, path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse return "";
    const dir: *Dir = if (std.mem.eql(u8, tab.root.path, parent))
        tab.root
    else
        tab.subdirByPath(parent) orelse return "";
    const i = dir.find(base) orelse return "";
    return dir.entries.items[i].tags;
}

/// Why the pane's shell cannot take typed text for `tab` right now
/// (`filebrowser/shellverb.zig` decides), or .ok.
pub fn shellVerdict(self: *BrowserView, tab: *BTab) shellverb.Verdict {
    const pane = self.pane orelse return .no_shell;
    const remote = pane.terminal.remote orelse return .no_shell;
    return shellverb.verdict(
        remote.canSend(),
        @import("../../filebrowser/paths.zig").browserHost(remote.host),
        tab.hc.host,
        pane.terminal.screen.use_alt,
    );
}

/// THE way a browser verb types into the pane's shell: refused (with
/// the reason on the status line) unless that shell runs on the tab's
/// host and is at a prompt, then typed and the shell face raised.
pub fn typeIntoShell(self: *BrowserView, tab: *BTab, line: []const u8) bool {
    const v = shellVerdict(self, tab);
    if (v != .ok) {
        self.setStatusFmt("not typed into the shell: {s}", .{v.phrase()});
        return false;
    }
    const pane = self.pane.?;
    pane.terminal.writeRaw(line);
    pane.setBrowserVisible(false);
    return true;
}

pub fn onMenuExportSel(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const self = ctx.view;
    const tab = ctx.tab;
    const paths: []const []const u8 = if (tab.selected.items.len > 0)
        tab.selected.items
    else if (ctx.path) |pp|
        (&[_][]const u8{pp})[0..]
    else
        return menuDone(ctx);
    const line = shellverb.exportLine(self.allocator, paths) catch return menuDone(ctx);
    defer self.allocator.free(line);
    if (typeIntoShell(self, tab, line))
        self.setStatusFmt("exported {d} path(s) as $SK_SEL / $SK_SEL_ALL", .{paths.len});
    menuDone(ctx);
}

/// Editor-buffer rename: selection names go to a temp file, the
/// pane's SHELL runs $EDITOR on it, and a sentinel "done" file
/// (watched with GFileMonitor) triggers applying the renames.
pub const EditorRename = struct {
    view: *BrowserView,
    host: ?[]u8,
    paths: std.ArrayList([]u8) = .empty,
    tmp: []u8,
    done: []u8,
    monitor: ?*c.GFileMonitor = null,

    pub fn destroy(self: *EditorRename, allocator: std.mem.Allocator) void {
        if (self.monitor) |m| {
            _ = c.g_file_monitor_cancel(m);
            c.g_object_unref(m);
        }
        var zb: [4300]u8 = undefined;
        if (std.fmt.bufPrintZ(&zb, "{s}", .{self.tmp})) |z| {
            _ = c.unlink(z.ptr);
        } else |_| {}
        if (std.fmt.bufPrintZ(&zb, "{s}", .{self.done})) |z| {
            _ = c.unlink(z.ptr);
        } else |_| {}
        for (self.paths.items) |sp| allocator.free(sp);
        self.paths.deinit(allocator);
        if (self.host) |h| allocator.free(h);
        allocator.free(self.tmp);
        allocator.free(self.done);
        allocator.destroy(self);
    }
};

pub fn onMenuEditorRename(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const self = ctx.view;
    const tab = ctx.tab;
    if (tab.selected.items.len < 2) return menuDone(ctx);
    // The list file and its "done" sentinel live on THIS machine, so
    // the shell that edits them must too (and be at a prompt).
    if (tab.hc.host != null) {
        self.setStatus("Batch Rename in $EDITOR works on this computer's files; use Batch Rename Selected on a remote tab");
        return menuDone(ctx);
    }
    if (shellVerdict(self, tab) != .ok) {
        self.setStatusFmt("not typed into the shell: {s}", .{shellVerdict(self, tab).phrase()});
        return menuDone(ctx);
    }
    if (self.editor_rename) |er| {
        er.destroy(self.allocator);
        self.editor_rename = null;
    }
    var stamp: [32]u8 = undefined;
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
    const tag = std.fmt.bufPrint(&stamp, "{d}", .{@as(u64, @intCast(t.tv_nsec)) ^ @as(u64, @intCast(t.tv_sec))}) catch return menuDone(ctx);
    const cache_root = c.g_get_user_cache_dir();
    var tb: [4200]u8 = undefined;
    var db: [4200]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}/sketerm-rename-{s}.txt", .{ cache_root, tag }) catch return menuDone(ctx);
    const done = std.fmt.bufPrint(&db, "{s}/sketerm-rename-{s}.done", .{ cache_root, tag }) catch return menuDone(ctx);

    const er = self.allocator.create(EditorRename) catch return menuDone(ctx);
    er.* = .{
        .view = self,
        .host = if (tab.hc.host) |h| (self.allocator.dupe(u8, h) catch null) else null,
        .tmp = self.allocator.dupe(u8, tmp) catch {
            self.allocator.destroy(er);
            return menuDone(ctx);
        },
        .done = self.allocator.dupe(u8, done) catch {
            self.allocator.free(er.tmp);
            self.allocator.destroy(er);
            return menuDone(ctx);
        },
    };
    // Write one basename per line; remember the full paths.
    var zb: [4300:0]u8 = undefined;
    const tz = std.fmt.bufPrintZ(&zb, "{s}", .{tmp}) catch {
        er.destroy(self.allocator);
        return menuDone(ctx);
    };
    const f = c.fopen(tz.ptr, "wb") orelse {
        er.destroy(self.allocator);
        return menuDone(ctx);
    };
    for (tab.selected.items) |sp| {
        const owned = self.allocator.dupe(u8, sp) catch continue;
        er.paths.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            continue;
        };
        const base = std.fs.path.basename(sp);
        _ = c.fwrite(base.ptr, 1, base.len, f);
        _ = c.fwrite("\n", 1, 1, f);
    }
    _ = c.fclose(f);

    var dzb: [4300:0]u8 = undefined;
    const dz = std.fmt.bufPrintZ(&dzb, "{s}", .{done}) catch {
        er.destroy(self.allocator);
        return menuDone(ctx);
    };
    const gfile = c.g_file_new_for_path(dz.ptr);
    er.monitor = c.g_file_monitor_file(gfile, c.G_FILE_MONITOR_NONE, null, null);
    c.g_object_unref(gfile);
    if (er.monitor == null) {
        er.destroy(self.allocator);
        return menuDone(ctx);
    }
    _ = c.g_signal_connect_data(er.monitor, "changed", @ptrCast(&onEditorRenameDone), @ptrCast(er), null, c.G_CONNECT_DEFAULT);
    self.editor_rename = er;

    // Run $EDITOR in the pane's shell; touching the done file
    // fires the monitor.
    const line = shellverb.editorLine(self.allocator, tmp, done) catch return menuDone(ctx);
    defer self.allocator.free(line);
    if (typeIntoShell(self, tab, line))
        self.setStatus("edit the names, save, and quit the editor to apply");
    menuDone(ctx);
}

pub fn onEditorRenameDone(
    _: *c.GFileMonitor,
    _: ?*c.GFile,
    _: ?*c.GFile,
    event: c.GFileMonitorEvent,
    user: ?*anyopaque,
) callconv(.c) void {
    if (event != c.G_FILE_MONITOR_EVENT_CREATED and event != c.G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT) return;
    const er = cast.userData(EditorRename, user);
    const self = er.view;
    if (self.editor_rename != er) return;
    defer {
        self.editor_rename = null;
        er.destroy(self.allocator);
    }
    var zb: [4300:0]u8 = undefined;
    const tz = std.fmt.bufPrintZ(&zb, "{s}", .{er.tmp}) catch return;
    const f = c.fopen(tz.ptr, "rb") orelse return;
    var content: [64 * 1024]u8 = undefined;
    const n = c.fread(&content, 1, content.len, f);
    _ = c.fclose(f);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var it = std.mem.splitScalar(u8, content[0..n], '\n');
    while (it.next()) |line| {
        const nm = std.mem.trim(u8, line, " \t\r");
        if (nm.len > 0) names.append(self.allocator, nm) catch return;
    }
    if (names.items.len != er.paths.items.len) {
        self.setStatusFmt("rename aborted: {d} line(s) for {d} file(s) — line count must match", .{
            names.items.len, er.paths.items.len,
        });
        return;
    }
    const hc = self.hostConnFor(if (er.host) |h| @as(?[]const u8, h) else null) orelse return;
    if (!hc.io().caps.copy_no_replace) {
        self.setStatusFmt("rename not started: {s} lacks safe no-replace support", .{hc.label()});
        return;
    }
    var renamed: usize = 0;
    // Deepest first, for the same reason as the popover batch: a parent
    // renamed ahead of its child invalidates the child's queued path.
    const order = oproots.deepestFirst(self.allocator, er.paths.items) catch {
        self.setStatus("editor rename not started: out of memory");
        return;
    };
    defer self.allocator.free(order);
    for (order) |i| {
        const old = er.paths.items[i];
        const new_name = names.items[i];
        const base = std.fs.path.basename(old);
        if (std.mem.eql(u8, base, new_name)) continue;
        if (std.mem.indexOfScalar(u8, new_name, '/') != null) continue;
        const dir = std.fs.path.dirname(old) orelse continue;
        var nb: [4300]u8 = undefined;
        const np = std.fmt.bufPrint(&nb, "{s}/{s}", .{ if (dir.len == 1) "" else dir, new_name }) catch continue;
        const req = self.nextReq();
        const undo = self.makeUndo(hc.host, .rename_back, np, old, "");
        if (!self.sendOpOk(hc, .{ .req = req, .op = "rename", .path = old, .to = np, .no_replace = true })) {
            if (undo) |op| op.destroy(self.allocator);
            continue;
        }
        self.deferUndoMode(req, undo, true);
        renamed += 1;
    }
    self.setStatusFmt("editor rename: {d} file(s) renamed", .{renamed});
}

pub fn setMountXattr(ctx: *MenuCtx, comptime attr: [:0]const u8, comptime okmsg: []const u8) void {
    const self = ctx.view;
    const path = ctx.path orelse return menuDone(ctx);
    // The pin/evict control channel is a sketerm FUSE mount's xattr, and
    // fsmount is a Linux /dev/fuse client — there is no such mount to
    // poke on macOS (whose setxattr(2) takes a different argument list
    // anyway, so the call must not even be analysed there).
    if (comptime !platform.is_linux) {
        self.setStatusFmt("{s}: sketerm mounts are Linux-only", .{attr});
        return menuDone(ctx);
    }
    var z: [4300:0]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return menuDone(ctx);
    if (c.setxattr(pz.ptr, attr.ptr, "1", 1, 0) != 0) {
        self.setStatusFmt("{s} failed (is this really a sketerm mount?)", .{attr});
    } else {
        self.setStatusFmt("{s}: {s}", .{ std.fs.path.basename(path), okmsg });
    }
    menuDone(ctx);
}

/// The paths a danger verb applies to: the whole selection when the
/// clicked row is part of a multi-selection, else just the clicked
/// row (same rule as copyToClip). `one` is the caller's storage for
/// the single-target case.
fn menuTargets(ctx: *MenuCtx, one: *[1][]u8) []const []u8 {
    const path = ctx.path orelse return &.{};
    if (ctx.tab.selected.actsOnAll(path)) return ctx.tab.selected.items;
    one[0] = path;
    return one;
}

/// Whether the listing knows `path` as a directory (symlink targets
/// count, matching activation). Unknown paths read as files.
fn pathIsDir(tab: *BTab, path: []const u8) bool {
    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse return false;
    const dir: *Dir = if (std.mem.eql(u8, tab.root.path, parent))
        tab.root
    else
        tab.subdirByPath(parent) orelse return false;
    const i = dir.find(base) orelse return false;
    return dir.entries.items[i].tdir;
}

fn trashOne(self: *BrowserView, hc: *HostConn, path: []const u8) void {
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch return;
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, "move to trash") catch {
            self.allocator.destroy(pj);
            return;
        },
        .op = .trash,
        .undo_trash_orig = self.allocator.dupe(u8, path) catch null,
    };
    self.pending_jobs.append(self.allocator, pj) catch {
        if (pj.undo_trash_orig) |o| self.allocator.free(o);
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return;
    };
    self.sendOp(hc, .{ .req = req, .op = "trash", .path = path });
}

pub fn onMenuTrash(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    const self = ctx.view;
    var one: [1][]u8 = undefined;
    const targets = menuTargets(ctx, &one);
    if (targets.len == 0) return menuDone(ctx);
    const roots = oproots.collect(self.allocator, ctx.tab, targets) catch return menuDone(ctx);
    defer self.allocator.free(roots);
    const hc = ctx.tab.hc;
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return menuDone(ctx);
    }
    trashPaths(self, hc, roots);
    menuDone(ctx);
}

/// Chord-driven trash (Delete): the tab's selection.
pub fn trashSelection(self: *BrowserView) void {
    const tab = self.currentTab() orelse return;
    if (tab.selected.items.len == 0) {
        self.setStatus("nothing selected");
        return;
    }
    if (tab.hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{tab.hc.label()});
        return;
    }
    const roots = oproots.collect(self.allocator, tab, tab.selected.items) catch {
        self.setStatus("trash not started: out of memory");
        return;
    };
    defer self.allocator.free(roots);
    trashPaths(self, tab.hc, roots);
}

fn trashPaths(self: *BrowserView, hc: *HostConn, targets: []const []u8) void {
    for (targets) |p| trashOne(self, hc, p);
    if (targets.len > 1) self.setStatusFmt("moving {d} items to trash", .{targets.len});
}

/// Pending permanent-delete confirmation: paths are owned copies —
/// the selection and the listing can change while the dialog is up.
const DeleteReq = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    paths: [][]u8,
    dirs: []bool,
    /// Overwrite-then-unlink instead of a plain delete (files only).
    secure: bool = false,

    fn destroy(self: *DeleteReq) void {
        for (self.paths) |p| self.allocator.free(p);
        self.allocator.free(self.paths);
        self.allocator.free(self.dirs);
        self.allocator.destroy(self);
    }
};

pub fn onMenuDelete(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    var one: [1][]u8 = undefined;
    const targets = menuTargets(ctx, &one);
    const roots = oproots.collect(ctx.view.allocator, ctx.tab, targets) catch return menuDone(ctx);
    defer ctx.view.allocator.free(roots);
    confirmDeletePaths(ctx.view, ctx.tab, roots);
    menuDone(ctx);
}

pub fn onMenuSecureDelete(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(MenuCtx, user);
    var one: [1][]u8 = undefined;
    const targets = menuTargets(ctx, &one);
    const roots = oproots.collect(ctx.view.allocator, ctx.tab, targets) catch return menuDone(ctx);
    defer ctx.view.allocator.free(roots);
    confirmDeletePathsMode(ctx.view, ctx.tab, roots, true);
    menuDone(ctx);
}

/// Chord-driven permanent delete (Shift+Delete): the tab's selection.
pub fn deleteSelection(self: *BrowserView) void {
    const tab = self.currentTab() orelse return;
    if (tab.selected.items.len == 0) {
        self.setStatus("nothing selected");
        return;
    }
    const roots = oproots.collect(self.allocator, tab, tab.selected.items) catch {
        self.setStatus("delete not started: out of memory");
        return;
    };
    defer self.allocator.free(roots);
    confirmDeletePaths(self, tab, roots);
}

/// Modal confirmation, Nemo's shape: names one item, counts many.
/// The dialog is window-modal, so the tab cannot be closed under it.
/// `files_confirm_delete = false` skips straight to the delete.
pub fn confirmDeletePaths(self: *BrowserView, tab: *BTab, targets: []const []u8) void {
    confirmDeletePathsMode(self, tab, targets, false);
}

pub fn confirmDeletePathsMode(self: *BrowserView, tab: *BTab, targets: []const []u8, secure: bool) void {
    if (targets.len == 0) return;
    // Secure delete always confirms: it is unrecoverable by design.
    if (!secure) if (self.ownerWindow()) |win| {
        if (!win.config.files_confirm_delete) {
            for (targets) |path| deleteOne(self, tab, path, pathIsDir(tab, path));
            if (targets.len > 1) self.setStatusFmt("deleting {d} items", .{targets.len});
            return;
        }
    };
    const a = self.allocator;
    const req = a.create(DeleteReq) catch return;
    const paths = a.alloc([]u8, targets.len) catch {
        a.destroy(req);
        return;
    };
    const dirs = a.alloc(bool, targets.len) catch {
        a.free(paths);
        a.destroy(req);
        return;
    };
    // All-or-nothing: `DeleteReq.destroy` frees `paths`/`dirs` as
    // whole allocations, so a partially filled array must never
    // become a shorter sub-slice — freeing that is a length mismatch,
    // and the untouched tail slots would leak their dupes anyway.
    for (targets, 0..) |p, i| {
        paths[i] = a.dupe(u8, p) catch {
            for (paths[0..i]) |owned| a.free(owned);
            a.free(paths);
            a.free(dirs);
            a.destroy(req);
            return;
        };
        dirs[i] = pathIsDir(tab, p);
    }
    const n = targets.len;
    var msg: [340:0]u8 = undefined;
    const verb: []const u8 = if (secure) "securely delete" else "permanently delete";
    const txt = if (n == 1)
        std.fmt.bufPrintZ(&msg, "Are you sure you want to {s} \"{s}\"?", .{ verb, std.fs.path.basename(paths[0]) }) catch "Permanently delete this item?"
    else
        std.fmt.bufPrintZ(&msg, "Are you sure you want to {s} the {d} selected items?", .{ verb, n }) catch "Permanently delete the selected items?";
    req.* = .{
        .allocator = a,
        .view = self,
        .tab = tab,
        .paths = paths,
        .dirs = dirs,
        .secure = secure,
    };
    const root = c.gtk_widget_get_root(self.root_box);
    if (confirm.present(@ptrCast(@alignCast(root)), .{
        .heading = txt.ptr,
        .body = if (secure)
            "Overwrites file contents once before deletion. This cannot guarantee removal from SSDs, snapshots, backups, or copy-on-write filesystems. Folders are skipped."
        else
            "If you delete an item, it will be permanently lost.",
        .responses = &.{
            .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
            .{ .id = "delete", .label = "Delete", .appearance = .destructive },
        },
    }, .{ .allocator = a, .cb = &onDeleteChosen, .ctx = @ptrCast(req) }) == null) req.destroy();
}

fn secureDeleteOne(self: *BrowserView, tab: *BTab, path: []const u8, is_dir: bool) void {
    if (is_dir) {
        self.setStatusFmt("skipped folder {s} (secure delete is per-file)", .{std.fs.path.basename(path)});
        return;
    }
    var lbl: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&lbl, "secure delete {s}", .{std.fs.path.basename(path)}) catch "secure delete";
    self.startDaemonJob(tab.hc, "secure_delete", path, "", label);
}

fn deleteOne(self: *BrowserView, tab: *BTab, path: []const u8, is_dir: bool) void {
    if (is_dir) {
        var lbl: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&lbl, "delete {s}", .{std.fs.path.basename(path)}) catch "delete";
        self.startDaemonJob(tab.hc, "delete_tree", path, "", label);
    } else {
        self.sendOp(tab.hc, .{ .req = self.nextReq(), .op = "delete", .path = path });
    }
}

fn onDeleteChosen(user: ?*anyopaque, resp: []const u8) void {
    const req: *DeleteReq = @ptrCast(@alignCast(user.?));
    defer req.destroy();
    if (!std.mem.eql(u8, resp, "delete")) return;
    const self = req.view;
    if (self.widgets_dead) return;
    if (req.secure) {
        for (req.paths, req.dirs) |path, is_dir| secureDeleteOne(self, req.tab, path, is_dir);
    } else {
        for (req.paths, req.dirs) |path, is_dir| deleteOne(self, req.tab, path, is_dir);
    }
    if (req.paths.len > 1) self.setStatusFmt("deleting {d} items", .{req.paths.len});
}

pub const NewEntryKind = enum { directory, file };

/// Create `name` in the tab's directory, with its undo record queued
/// against the reply.
pub fn createEntry(self: *BrowserView, tab: *BTab, kind: NewEntryKind, name: []const u8) void {
    var buf: [4096]u8 = undefined;
    const dir = tab.root.path;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ if (dir.len == 1) "" else dir, name }) catch return;
    const req = self.nextReq();
    switch (kind) {
        .directory => {
            self.deferUndo(req, self.makeUndo(tab.hc.host, .rmdir_created, path, "", ""));
            self.sendOp(tab.hc, .{ .req = req, .op = "mkdir", .path = path });
        },
        .file => {
            self.deferUndo(req, self.makeUndo(tab.hc.host, .delete_created, path, "", ""));
            self.sendOp(tab.hc, .{ .req = req, .op = "create", .path = path });
        },
    }
}

/// Replace the entry's tag list (comma-separated; empty clears).
pub fn setTags(self: *BrowserView, hc: *HostConn, path: []const u8, tags: []const u8) void {
    self.sendOp(hc, .{ .req = self.nextReq(), .op = "tag_set", .path = path, .to = tags });
}

/// Ask the host's daemon which tags are in use (its tag index). The
/// answer lands in `hc.known_tags`; a daemon without the verb answers
/// an error and the cache simply stays empty.
pub fn refreshKnownTags(self: *BrowserView, hc: *HostConn) void {
    if (hc.tag_list_req != 0 or hc.state != .ready) return;
    const req = self.nextReq();
    if (self.sendOpOk(hc, .{ .req = req, .op = "tag_list", .path = "/" })) hc.tag_list_req = req;
}

pub fn storeKnownTags(self: *BrowserView, hc: *HostConn, rep: WireReply) void {
    if (!rep.ok) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    for (rep.tags, 0..) |tg, i| {
        if (i > 0) out.appendSlice(self.allocator, ", ") catch return;
        out.print(self.allocator, "{s} ({d})", .{ tg.name, tg.count }) catch return;
    }
    const owned = out.toOwnedSlice(self.allocator) catch return;
    if (hc.known_tags) |old| self.allocator.free(old);
    hc.known_tags = owned;
}

/// Replace every occurrence of `find_txt` in each selected entry's
/// basename, as planned by `filebrowser/batchrename.zig` (deepest
/// first; a plan that collides or empties a name is refused before
/// anything is sent). The count and the ONE undo record come from the
/// replies (`noteRenameRunReply`), never from what was sent.
pub fn batchRenameSelected(self: *BrowserView, tab: *BTab, find_txt: []const u8, repl_txt: []const u8) void {
    if (!tab.hc.io().caps.copy_no_replace) {
        self.setStatusFmt("batch rename not started: {s} lacks safe no-replace support", .{tab.hc.label()});
        return;
    }
    var plan = batchrename.plan(self.allocator, tab.selected.items, find_txt, repl_txt) catch {
        self.setStatus("batch rename not started: out of memory");
        return;
    };
    defer plan.deinit(self.allocator);
    if (!plan.ok()) {
        var buf: [512]u8 = undefined;
        self.setStatusFmt("batch rename not started: {s}", .{batchrename.describe(&plan, &buf)});
        return;
    }
    const run = self.allocator.create(RenameRun) catch return;
    run.* = .{ .hc = tab.hc };
    for (plan.items) |it| {
        if (!addRenameToRun(self, run, it.from, it.to)) break;
    }
    finishRunStart(self, run, "batch rename");
}

/// Queue one no-replace rename on `run`. False when the op could not
/// be sent (the run keeps what it already has).
fn addRenameToRun(self: *BrowserView, run: *RenameRun, from: []const u8, to: []const u8) bool {
    const f = self.allocator.dupe(u8, from) catch return false;
    const t2 = self.allocator.dupe(u8, to) catch {
        self.allocator.free(f);
        return false;
    };
    const req = self.nextReq();
    run.pairs.append(self.allocator, .{ f, t2 }) catch {
        self.allocator.free(f);
        self.allocator.free(t2);
        return false;
    };
    run.reqs.append(self.allocator, req) catch {
        _ = run.pairs.pop();
        self.allocator.free(f);
        self.allocator.free(t2);
        return false;
    };
    run.outcome.append(self.allocator, 0) catch {
        _ = run.reqs.pop();
        _ = run.pairs.pop();
        self.allocator.free(f);
        self.allocator.free(t2);
        return false;
    };
    if (!self.sendOpOk(run.hc, .{ .req = req, .op = "rename", .path = from, .to = to, .no_replace = true })) {
        run.outcome.items[run.outcome.items.len - 1] = 2;
        return false;
    }
    return true;
}

fn finishRunStart(self: *BrowserView, run: *RenameRun, what: []const u8) void {
    run.select_batch = @intFromPtr(run);
    if (run.waiting() == 0) {
        completeRenameRun(self, run);
        return;
    }
    self.rename_runs.append(self.allocator, run) catch {
        // No tracking means no undo record: say so rather than guess.
        self.setStatusFmt("{s}: {d} rename(s) sent, outcome untracked", .{ what, run.waiting() });
        if (run.history_op) |op| {
            run.history_op = null;
            self.restoreHistory(op, run.history_direction);
        }
        run.destroy(self.allocator);
        return;
    };
    self.setStatusFmt("{s}: renaming {d} entr{s}\u{2026}", .{ what, run.waiting(), if (run.waiting() == 1) "y" else "ies" });
}

/// A reply for one of a run's renames. True when `req` belonged to a
/// run (consumed).
pub fn noteRenameRunReply(self: *BrowserView, req: u32, ok: bool, err: []const u8) bool {
    for (self.rename_runs.items, 0..) |run, ri| {
        for (run.reqs.items, 0..) |r, i| {
            if (r != req or run.outcome.items[i] != 0) continue;
            run.outcome.items[i] = if (ok) 1 else 2;
            if (ok) {
                self.queueSelectOnHost(run.hc, run.pairs.items[i][1], run.select_batch);
            } else if (run.first_error == null) {
                run.first_error = self.allocator.dupe(u8, err) catch null;
            }
            if (run.waiting() == 0) {
                _ = self.rename_runs.orderedRemove(ri);
                completeRenameRun(self, run);
            }
            return true;
        }
    }
    return false;
}

/// The host of a run went away: its unanswered renames have an
/// unknown outcome, so the run settles on what it knows.
pub fn abandonRenameRuns(self: *BrowserView, hc: *HostConn) void {
    var i: usize = 0;
    while (i < self.rename_runs.items.len) {
        const run = self.rename_runs.items[i];
        if (run.hc != hc) {
            i += 1;
            continue;
        }
        _ = self.rename_runs.orderedRemove(i);
        for (run.outcome.items) |*o| {
            if (o.* == 0) o.* = 2;
        }
        if (run.first_error == null) run.first_error = self.allocator.dupe(u8, "connection lost") catch null;
        completeRenameRun(self, run);
    }
}

/// Every reply is in: report the real count and record the undo (a
/// forward batch) or settle the history step (an undo/redo replay).
fn completeRenameRun(self: *BrowserView, run: *RenameRun) void {
    defer run.destroy(self.allocator);
    const landed = run.landed();
    const total = run.outcome.items.len;
    const err = run.first_error orelse "not sent";
    if (run.history_op) |op| {
        run.history_op = null;
        const direction = run.history_direction;
        if (landed == total) {
            self.finishHistory(op, direction);
        } else {
            // Partial: what landed stays landed; the record goes back
            // so the rest can be retried.
            self.restoreHistory(op, direction);
            self.setStatusFmt("{s} batch rename: {d} of {d} renamed; {s}", .{ @tagName(direction), landed, total, errorPhrase(err) });
        }
        return;
    }
    if (landed > 0) {
        if (self.allocator.alloc([2][]const u8, landed)) |ps| {
            defer self.allocator.free(ps);
            var n: usize = 0;
            for (run.pairs.items, run.outcome.items) |pair, o| {
                if (o != 1) continue;
                ps[n] = .{ pair[0], pair[1] };
                n += 1;
            }
            if (batchrename.encodePairs(self.allocator, ps)) |enc| {
                defer self.allocator.free(enc.current);
                defer self.allocator.free(enc.original);
                if (self.makeUndo(run.hc.host, .rename_batch, enc.current, enc.original, "")) |op| self.pushUndo(op);
            } else |_| {}
        } else |_| {}
    }
    // The status line alone is not enough: the renames' own listing
    // deltas repaint it with the folder's item count in the same drain.
    // The count is the answer to the verb, so it is also a toast.
    var buf: [256]u8 = undefined;
    const msg = if (landed == total)
        std.fmt.bufPrint(&buf, "batch rename: {d} renamed", .{landed}) catch "batch rename done"
    else
        std.fmt.bufPrint(&buf, "batch rename: {d} of {d} renamed; {s}", .{ landed, total, errorPhrase(err) }) catch "batch rename incomplete";
    self.setStatus(msg);
    if (!self.widgets_dead) {
        if (self.ownerWindow()) |window| @import("../window.zig").showToast(window, msg);
    }
}

/// Undo (reverse order, current -> original) or redo (execution
/// order, original -> current) a whole `rename_batch` record.
fn replayRenameBatch(self: *BrowserView, hc: *HostConn, op: *UndoOp, direction: HistoryDirection) void {
    const run = self.allocator.create(RenameRun) catch return self.restoreHistory(op, direction);
    run.* = .{ .hc = hc, .history_op = op, .history_direction = direction };
    const n = batchrename.count(op.a);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const i = if (direction == .undo) n - 1 - k else k;
        const cur = batchrename.nth(op.a, i) orelse continue;
        const orig = batchrename.nth(op.b, i) orelse continue;
        const sent = if (direction == .undo) addRenameToRun(self, run, cur, orig) else addRenameToRun(self, run, orig, cur);
        if (!sent) break;
    }
    finishRunStart(self, run, if (direction == .undo) "undo batch rename" else "redo batch rename");
}

/// Send the rename wire op for `old` → same directory, `name`; with
/// the undo record. Shared by the popover dialog and inline rename.
pub fn commitRename(self: *BrowserView, tab: *BTab, old: []const u8, name: []const u8) void {
    if (!tab.hc.io().caps.copy_no_replace) {
        self.setStatusFmt("rename not started: {s} lacks safe no-replace support", .{tab.hc.label()});
        return;
    }
    const dir = std.fs.path.dirname(old) orelse return;
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{s}/{s}", .{ if (dir.len == 1) "" else dir, name }) catch return;
    const req = self.nextReq();
    const undo = self.makeUndo(tab.hc.host, .rename_back, w.buffered(), old, "");
    if (!self.sendOpOk(tab.hc, .{ .req = req, .op = "rename", .path = old, .to = w.buffered(), .no_replace = true })) {
        if (undo) |op| op.destroy(self.allocator);
        return;
    }
    self.deferUndoMode(req, undo, true);
}

/// The live inline-rename editor; at most one per view.
///
/// The row/label/text widgets are REF'd: a listing rebuild or a tab
/// close can orphan the row while the editor is up, and the deferred
/// teardown must never touch freed widgets.
pub const InlineRename = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    /// Old full path of the entry being renamed.
    path: []u8,
    row: *c.GtkWidget,
    label: *c.GtkWidget,
    text: *c.GtkWidget,
    keys: ?*c.GtkEventController,
    focus: ?*c.GtkEventController,
    /// The deferred finish callback, owned and canceled with this edit.
    idle_source: c.guint = 0,
    /// Guards re-entry: focus-leave fires again during teardown.
    done: bool = false,
    commit: bool = false,
};

/// Rename `path` in place: the row's name label is swapped for a
/// GtkText right in the cell. Enter commits, Escape or focus loss
/// cancels. Views without a bound row for the entry (grid, a
/// scrolled-away or filtered-out row) fall back to the popover
/// dialog. The entry is scrolled into view first so its cell is
/// bound by the time the label is looked up.
pub fn startInlineRename(self: *BrowserView, tab: *BTab, path: []const u8) void {
    cancelInlineRename(self, null);
    const base = std.fs.path.basename(path);
    if (base.len == 0 or base.len > 511) return self.entryDialog(tab, .rename, path);
    const row = colview.nameCellForPath(tab, path) orelse return self.entryDialog(tab, .rename, path);
    const label = colview.labelOfNameCellRoot(row) orelse
        return self.entryDialog(tab, .rename, path);
    const box = c.gtk_widget_get_parent(label) orelse
        return self.entryDialog(tab, .rename, path);

    const ctx = self.allocator.create(InlineRename) catch return;
    const owned = self.allocator.dupe(u8, path) catch {
        self.allocator.destroy(ctx);
        return;
    };

    const text = c.gtk_text_new();
    var z: [512:0]u8 = undefined;
    @memcpy(z[0..base.len], base);
    z[base.len] = 0;
    c.gtk_editable_set_text(@ptrCast(text), &z);
    c.gtk_widget_set_hexpand(text, 1);
    c.gtk_widget_add_css_class(text, "sketerm-fb-rename");

    // The editor takes the label's spot; the hidden label keeps its
    // place in the box so teardown restores the exact layout.
    c.gtk_widget_set_visible(label, 0);
    c.gtk_box_insert_child_after(@ptrCast(@alignCast(box)), text, label);

    const keys = c.gtk_event_controller_key_new();
    const focus = c.gtk_event_controller_focus_new();

    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = tab,
        .path = owned,
        .row = @ptrCast(@alignCast(row)),
        .label = label,
        .text = text,
        .keys = keys,
        .focus = focus,
    };
    _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(ctx.row)));
    _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(ctx.label)));
    _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(ctx.text)));
    self.inline_rename = ctx;

    _ = c.g_signal_connect_data(text, "activate", @ptrCast(&onInlineRenameActivate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onInlineRenameKey), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(text, keys);
    _ = c.g_signal_connect_data(focus, "leave", @ptrCast(&onInlineRenameFocusOut), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(text, focus);

    _ = c.gtk_widget_grab_focus(text);
    // Preselect the stem only (Nemo-style): typing replaces the name,
    // the extension survives. select_region takes CHARACTER offsets.
    const stem_end: c_int = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse break :blk -1;
        if (dot == 0) break :blk -1;
        const n = std.unicode.utf8CountCodepoints(base[0..dot]) catch break :blk -1;
        break :blk @intCast(n);
    };
    c.gtk_editable_select_region(@ptrCast(text), 0, stem_end);
}

fn onInlineRenameActivate(_: *c.GtkText, user: ?*anyopaque) callconv(.c) void {
    finishInlineRenameDeferred(@ptrCast(@alignCast(user.?)), true);
}

fn onInlineRenameKey(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    if (keyval != c.GDK_KEY_Escape) return 0;
    finishInlineRenameDeferred(@ptrCast(@alignCast(user.?)), false);
    return 1;
}

fn onInlineRenameFocusOut(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
    finishInlineRenameDeferred(@ptrCast(@alignCast(user.?)), false);
}

/// End the edit on the next idle: the callers are the editor's own
/// signal handlers, and removing the widget from inside them is not
/// safe. `done` makes the first verdict (commit vs cancel) stick.
pub fn finishInlineRenameDeferred(ctx: *InlineRename, commit: bool) void {
    if (ctx.done) return;
    ctx.done = true;
    ctx.commit = commit;
    // The focused lifetime smoke holds a cancel verdict pending until
    // the close path proves it removed this exact source. Commits keep
    // normal idle timing so the same run covers successful rename too.
    ctx.idle_source = if (!commit and c.getenv("SKETERM_VERIFY_INLINE_RENAME_TEARDOWN") != null)
        c.g_timeout_add(60_000, @ptrCast(&inlineRenameIdle), @ptrCast(ctx))
    else
        c.g_idle_add(@ptrCast(&inlineRenameIdle), @ptrCast(ctx));
}

fn inlineRenameIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx = cast.userData(InlineRename, user);
    ctx.idle_source = 0;
    const self = ctx.view;
    const tab = ctx.tab;
    if (ctx.commit) {
        const txt = c.gtk_editable_get_text(@ptrCast(ctx.text));
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        const base = std.fs.path.basename(ctx.path);
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
            self.setStatus("invalid name");
        } else if (!std.mem.eql(u8, name, base) and tabAlive(self, tab)) {
            commitRename(self, tab, ctx.path, name);
        }
    }
    disposeInlineRename(ctx, true);
    return 0;
}

/// Cancel and synchronously dispose the active edit, optionally only for `tab`.
pub fn cancelInlineRename(self: *BrowserView, tab: ?*BTab) void {
    const ctx = self.inline_rename orelse return;
    if (tab) |target| {
        if (ctx.tab != target) return;
    }
    ctx.done = true;
    ctx.commit = false;
    disposeInlineRename(ctx, false);
}

/// Abort the focused smoke unless `scope` is closing an edit with a pending source.
pub fn verifyInlineRenameTeardown(self: *BrowserView, tab: ?*BTab, scope: []const u8) void {
    const raw = c.getenv("SKETERM_VERIFY_INLINE_RENAME_TEARDOWN") orelse return;
    const expected = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    if (!std.mem.eql(u8, expected, scope)) {
        // Closing the whole view is the final backstop for the focused
        // tab smoke: if its middle-click missed, do not pass by merely
        // disposing the still-live edit through the broader owner.
        if (std.mem.eql(u8, scope, "view")) {
            std.debug.print("sketerm: inline rename expected {s} teardown before view close\n", .{expected});
            c.abort();
        }
        return;
    }
    const ctx = self.inline_rename orelse {
        std.debug.print("sketerm: inline rename teardown had no active edit ({s})\n", .{scope});
        c.abort();
    };
    if (ctx.idle_source == 0 or (tab != null and ctx.tab != tab.?)) {
        std.debug.print("sketerm: inline rename teardown missed its pending source ({s})\n", .{scope});
        c.abort();
    }
    // A split close can leave another BrowserView alive in the same
    // process; only the close this smoke armed is expected to assert.
    _ = c.unsetenv("SKETERM_VERIFY_INLINE_RENAME_TEARDOWN");
}

fn disposeInlineRename(ctx: *InlineRename, refocus: bool) void {
    const self = ctx.view;
    const tab = ctx.tab;
    if (ctx.idle_source != 0) {
        const source = ctx.idle_source;
        ctx.idle_source = 0;
        _ = c.g_source_remove(source);
    }

    // The context is shared by three signal closures. Disconnect them
    // before releasing the text widget so no external widget reference
    // can keep a callback pointing at the freed context.
    _ = c.g_signal_handlers_disconnect_matched(
        @ptrCast(ctx.text),
        c.G_SIGNAL_MATCH_DATA,
        0,
        0,
        null,
        null,
        @ptrCast(ctx),
    );
    if (ctx.keys) |keys| {
        _ = c.g_signal_handlers_disconnect_matched(
            @ptrCast(keys),
            c.G_SIGNAL_MATCH_DATA,
            0,
            0,
            null,
            null,
            @ptrCast(ctx),
        );
    }
    if (ctx.focus) |focus| {
        _ = c.g_signal_handlers_disconnect_matched(
            @ptrCast(focus),
            c.G_SIGNAL_MATCH_DATA,
            0,
            0,
            null,
            null,
            @ptrCast(ctx),
        );
    }

    if (!self.widgets_dead) {
        c.gtk_widget_set_visible(ctx.label, 1);
        if (c.gtk_widget_get_parent(ctx.text)) |parent|
            c.gtk_box_remove(@ptrCast(@alignCast(parent)), ctx.text);
    }
    if (self.inline_rename == ctx) self.inline_rename = null;

    c.g_object_unref(@as(?*anyopaque, @ptrCast(ctx.text)));
    c.g_object_unref(@as(?*anyopaque, @ptrCast(ctx.label)));
    c.g_object_unref(@as(?*anyopaque, @ptrCast(ctx.row)));
    self.allocator.free(ctx.path);
    self.allocator.destroy(ctx);

    // Focus back into the listing so the browser's chords keep
    // working after the edit (the cell root itself is not focusable).
    if (refocus and !self.widgets_dead and tabAlive(self, tab))
        _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(tab.colview)));
}

/// Fetch the .trashinfo for a trashed entry, then restore it to
/// the Path= recorded inside.
pub fn startTrashRestore(self: *BrowserView, tab: *BTab, trashed: []const u8) void {
    if (self.restore_read) |rr| {
        rr.destroy(self.allocator);
        self.restore_read = null;
    }
    const name = std.fs.path.basename(trashed);
    const files_dir = std.fs.path.dirname(trashed) orelse return;
    const trash_root = std.fs.path.dirname(files_dir) orelse return;
    var info_buf: [4300]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "{s}/info/{s}.trashinfo", .{ trash_root, name }) catch return;
    const rr = self.allocator.create(RestoreRead) catch return;
    rr.* = .{
        .req = self.nextReq(),
        .hc = tab.hc,
        .trashed = self.allocator.dupe(u8, trashed) catch {
            self.allocator.destroy(rr);
            return;
        },
        .info = self.allocator.dupe(u8, info) catch {
            self.allocator.free(rr.trashed);
            self.allocator.destroy(rr);
            return;
        },
    };
    self.restore_read = rr;
    self.sendOp(tab.hc, .{ .req = rr.req, .op = "read", .path = rr.info, .off = @as(u64, 0), .len = @as(u64, 8192) });
}

pub fn feedRestore(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    const rr = self.restore_read orelse return false;
    if (rr.hc != hc) return false;
    switch (ftype) {
        .fs_data => {
            if (payload.len < 12) return false;
            if (std.mem.readInt(u32, payload[0..4], .little) != rr.req) return false;
            rr.buf.appendSlice(self.allocator, payload[12..]) catch {};
            return true;
        },
        .fs_reply => {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            if (rep.req != rr.req) return false;
            defer {
                rr.destroy(self.allocator);
                self.restore_read = null;
            }
            if (!rep.ok) {
                self.setStatus("cannot read trash metadata");
                return true;
            }
            // Parse Path= (URL-escaped) from the .trashinfo.
            var orig_buf: [4096]u8 = undefined;
            var orig: ?[]const u8 = null;
            var it = std.mem.tokenizeScalar(u8, rr.buf.items, '\n');
            while (it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (std.mem.startsWith(u8, line, "Path=")) {
                    orig = urlUnescape(line[5..], &orig_buf);
                    break;
                }
            }
            const dst = orig orelse {
                self.setStatus("trash metadata has no Path entry");
                return true;
            };
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "restore {s}", .{std.fs.path.basename(dst)}) catch "restore";
            self.startDaemonJobTo(rr.hc, "trash_restore", rr.trashed, dst, rr.info, label);
            return true;
        },
        else => return false,
    }
}

pub const UNDO_CAP = 20;

pub fn clearRedo(self: *BrowserView) void {
    for (self.redo_stack.items) |op| op.destroy(self.allocator);
    self.redo_stack.clearRetainingCapacity();
}

pub fn pushUndo(self: *BrowserView, op: *UndoOp) void {
    self.clearRedo();
    self.pushHistoryStack(&self.undo_stack, op);
}

pub fn pushHistoryStack(self: *BrowserView, stack: *std.ArrayList(*UndoOp), op: *UndoOp) void {
    stack.append(self.allocator, op) catch {
        op.destroy(self.allocator);
        return;
    };
    while (stack.items.len > UNDO_CAP) {
        const old = stack.orderedRemove(0);
        old.destroy(self.allocator);
    }
}

pub fn makeUndo(
    self: *BrowserView,
    host: ?[]const u8,
    kind: @FieldType(UndoOp, "kind"),
    a: []const u8,
    b: []const u8,
    p: []const u8,
) ?*UndoOp {
    const op = self.allocator.create(UndoOp) catch return null;
    const host_owned = if (host) |h| self.allocator.dupe(u8, h) catch {
        self.allocator.destroy(op);
        return null;
    } else null;
    const a_owned = self.allocator.dupe(u8, a) catch {
        self.allocator.destroy(op);
        return null;
    };
    const b_owned: []u8 = if (b.len > 0) self.allocator.dupe(u8, b) catch {
        self.allocator.free(a_owned);
        if (host_owned) |h| self.allocator.free(h);
        self.allocator.destroy(op);
        return null;
    } else @constCast(&[_]u8{});
    const p_owned: []u8 = if (p.len > 0) self.allocator.dupe(u8, p) catch {
        if (b_owned.len > 0) self.allocator.free(b_owned);
        self.allocator.free(a_owned);
        if (host_owned) |h| self.allocator.free(h);
        self.allocator.destroy(op);
        return null;
    } else @constCast(&[_]u8{});
    op.* = .{ .host = host_owned, .kind = kind, .a = a_owned, .b = b_owned, .p = p_owned };
    return op;
}

/// Register an undo that becomes real when req's reply is ok.
pub fn deferUndo(self: *BrowserView, req: u32, op: ?*UndoOp) void {
    self.deferUndoMode(req, op, false);
}

pub fn deferUndoMode(self: *BrowserView, req: u32, op: ?*UndoOp, no_replace: bool) void {
    const u = op orelse return;
    self.pending_undo.append(self.allocator, .{ .req = req, .op = u, .no_replace = no_replace }) catch u.destroy(self.allocator);
}

pub fn recordTrashUndo(self: *BrowserView, hc: *HostConn, orig: []const u8, trashed: []const u8, info: []const u8) void {
    if (self.makeUndo(hc.host, .trash_restore, trashed, orig, info)) |op| self.pushUndo(op);
}

pub fn performUndo(self: *BrowserView) void {
    self.beginHistory(.undo);
}

pub fn performRedo(self: *BrowserView) void {
    self.beginHistory(.redo);
}

pub fn beginHistory(self: *BrowserView, direction: HistoryDirection) void {
    if (self.history_busy) {
        self.setStatus("a history operation is still running");
        return;
    }
    const source = if (direction == .undo) &self.undo_stack else &self.redo_stack;
    const op = source.pop() orelse {
        self.setStatus(if (direction == .undo) "nothing to undo" else "nothing to redo");
        return;
    };
    const hc = self.hostConnFor(if (op.host) |h| @as(?[]const u8, h) else null) orelse {
        self.pushHistoryStack(source, op);
        return;
    };
    if (hc.state != .ready) {
        self.setStatus("host not connected; history operation retained");
        self.pushHistoryStack(source, op);
        return;
    }
    self.history_busy = true;
    switch (op.kind) {
        .rename_back => {
            if (!hc.io().caps.copy_no_replace) {
                self.setStatusFmt("history operation retained: {s} lacks safe no-replace support", .{hc.label()});
                return self.restoreHistory(op, direction);
            }
            const req = self.nextReq();
            if (!self.deferHistory(req, hc, op, direction)) return;
            self.sendOp(hc, .{ .req = req, .op = "rename", .path = if (direction == .undo) op.a else op.b, .to = if (direction == .undo) op.b else op.a, .no_replace = true });
        },
        .delete_created => {
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "{s} copy {s}", .{ @tagName(direction), std.fs.path.basename(op.a) }) catch "copy history";
            if (direction == .undo)
                self.startHistoryJob(hc, "delete_tree", op.a, "", "", label, op, direction, false)
            else if (op.b.len > 0)
                self.startHistoryJob(hc, "copy", op.b, op.a, "", label, op, direction, true)
            else
                self.restoreHistory(op, direction);
        },
        .trash_restore => {
            var lbl: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&lbl, "{s} trash {s}", .{ @tagName(direction), std.fs.path.basename(op.b) }) catch "trash history";
            if (direction == .undo)
                self.startHistoryJob(hc, "trash_restore", op.a, op.b, op.p, label, op, direction, false)
            else
                self.startHistoryJob(hc, "trash", op.b, "", "", label, op, direction, false);
        },
        .rmdir_created => {
            const req = self.nextReq();
            if (!self.deferHistory(req, hc, op, direction)) return;
            self.sendOp(hc, .{ .req = req, .op = if (direction == .undo) "delete" else "mkdir", .path = op.a });
        },
        .rename_batch => {
            if (!hc.io().caps.copy_no_replace) {
                self.setStatusFmt("history operation retained: {s} lacks safe no-replace support", .{hc.label()});
                return self.restoreHistory(op, direction);
            }
            replayRenameBatch(self, hc, op, direction);
        },
        .link_created => {
            // Undo unlinks the link (never its target); redo recreates
            // it with the verb recorded in `p`.
            const req = self.nextReq();
            if (!self.deferHistory(req, hc, op, direction)) return;
            if (direction == .undo) {
                self.sendOp(hc, .{ .req = req, .op = "delete", .path = op.a });
            } else {
                self.sendOp(hc, .{ .req = req, .op = op.p, .path = op.a, .to = op.b });
            }
        },
    }
}

pub fn deferHistory(self: *BrowserView, req: u32, hc: *HostConn, op: *UndoOp, direction: HistoryDirection) bool {
    self.pending_history.append(self.allocator, .{ .req = req, .hc = hc, .op = op, .direction = direction }) catch {
        self.restoreHistory(op, direction);
        return false;
    };
    return true;
}

pub fn finishHistory(self: *BrowserView, op: *UndoOp, direction: HistoryDirection) void {
    self.history_busy = false;
    // The restored/recreated entry is selected, so the next verb (a
    // Ctrl+C right after Ctrl+Z) acts on it instead of on nothing.
    if (op.produced(direction == .undo)) |path| {
        if (self.hostConnFor(if (op.host) |h| @as(?[]const u8, h) else null)) |hc|
            self.queueSelectOnHost(hc, path, @intFromPtr(op));
    }
    self.pushHistoryStack(if (direction == .undo) &self.redo_stack else &self.undo_stack, op);
    self.setStatus(if (direction == .undo) "undo complete" else "redo complete");
}

pub fn restoreHistory(self: *BrowserView, op: *UndoOp, direction: HistoryDirection) void {
    self.history_busy = false;
    self.pushHistoryStack(if (direction == .undo) &self.undo_stack else &self.redo_stack, op);
}

pub fn updateTrashResult(self: *BrowserView, op: *UndoOp, trashed: []const u8, info: []const u8) void {
    const a = self.allocator.dupe(u8, trashed) catch return;
    const p = self.allocator.dupe(u8, info) catch {
        self.allocator.free(a);
        return;
    };
    self.allocator.free(op.a);
    if (op.p.len > 0) self.allocator.free(op.p);
    op.a = a;
    op.p = p;
}

/// Open a flat results tab listing an archive's members (host-
/// side bsdtar; only the member table crosses the wire).
pub fn startArchiveBrowse(self: *BrowserView, tab: *BTab, archive: []const u8) void {
    var rbuf: [4096]u8 = undefined;
    const parent = std.fs.path.dirname(archive) orelse "/";
    if (parent.len >= rbuf.len) return;
    @memcpy(rbuf[0..parent.len], parent);
    var hbuf: [256]u8 = undefined;
    var host: ?[]const u8 = null;
    if (tab.hc.host) |h| {
        if (h.len >= hbuf.len) return;
        @memcpy(hbuf[0..h.len], h);
        host = hbuf[0..h.len];
    }
    const rtab = self.newTab(host, rbuf[0..parent.len]) orelse return;
    self.closeViewOf(rtab.hc, rtab.root);
    var i: usize = 0;
    while (i < self.pending.items.len) {
        if (self.pending.items[i].tab == rtab) self.dropPending(i) else i += 1;
    }
    rtab.root.flat = true;
    rtab.root.loaded = true;
    rtab.root.view_id = 0;
    rtab.root.archive = self.allocator.dupe(u8, archive) catch &.{};
    var lbl: [96:0]u8 = undefined;
    const l = std.fmt.bufPrintZ(&lbl, "{s}", .{std.fs.path.basename(archive)}) catch "archive";
    c.gtk_label_set_text(rtab.tab_label, l.ptr);
    self.arch_tab = rtab;
    self.startDaemonJobKind(rtab.hc, "archive_list", archive, "", "", "list archive", .{ .kind = .archive_list });
}

pub fn onArchiveMember(self: *BrowserView, e: WireJobEv) void {
    const rtab = self.arch_tab orelse return;
    if (e.path.len == 0) return;
    const dir = rtab.root;
    if (dir.find(e.path) != null) return;
    const a = self.allocator;
    const name = a.dupe(u8, e.path) catch return;
    const kind = a.dupe(u8, if (e.kind.len > 0) e.kind else "file") catch {
        a.free(name);
        return;
    };
    const tgt = a.dupe(u8, e.path) catch {
        a.free(name);
        a.free(kind);
        return;
    };
    // Members stream in one event at a time with a render BETWEEN them,
    // so bound rows really are pointing into `dir.entries` when the next
    // append moves it: fence first, the same ordering the streaming
    // listing chunk uses. The fence latches per render cycle, so the
    // thousands of members of a big archive cost one sweep per render
    // rather than one per event.
    colview.invalidateBackingRefs(rtab);
    dir.entries.append(a, .{
        .name = name,
        .kind = kind,
        .size = e.size,
        .mode = 0,
        .mtime_ms = 0,
        .target = tgt,
        .tdir = false,
    }) catch {
        a.free(name);
        a.free(kind);
        a.free(tgt);
        return;
    };
    // Coalesced, never per event: a large archive streams thousands of
    // members, and a render each would be the full-rebuild storm the
    // subsystem doc warns about. The 120ms one-shot renders the current
    // tab, which this branch has already established is `rtab`; the
    // search stream collapses its own match events the same way.
    if (self.currentTab() == rtab) self.scheduleCoalescedRender();
}

/// Extract one member on the archive's host, then open it.
pub fn extractAndOpenMember(self: *BrowserView, tab: *BTab, member: []const u8) void {
    const archive = tab.root.archive;
    if (archive.len == 0) return;
    const hc = tab.hc;
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch return;
    var lbl: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&lbl, "extract {s}", .{std.fs.path.basename(member)}) catch "extract member";
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, label) catch {
            self.allocator.destroy(pj);
            return;
        },
        .op = .other,
        .open_on_done = true,
    };
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return;
    };
    self.sendOp(hc, .{ .req = req, .op = "archive_extract", .path = archive, .pattern = member });
    self.setStatusFmt("extracting {s} on {s}…", .{ member, hc.label() });
}

/// Drop of an entry spec onto the listing: target dir = the row
/// under the pointer when it's a directory, else the tab root.
pub fn onListDrop(
    target: *c.GtkDropTarget,
    value: *c.GValue,
    x: f64,
    y: f64,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const tab: *BTab = @ptrCast(@alignCast(user.?));
    const self = tab.view;
    var dst_dir: []const u8 = tab.root.path;
    var dbuf: [4096]u8 = undefined;
    if (colview.pickItem(tab, x, y)) |p| {
        if (p.data.kind == .entry and p.data.is_dir and p.data.path.len < dbuf.len) {
            @memcpy(dbuf[0..p.data.path.len], p.data.path);
            dst_dir = dbuf[0..p.data.path.len];
        }
    }
    return @intFromBool(dropValueIntoAction(self, tab, value, dst_dir, dnd.dropAction(target, tab)));
}

pub const DropAction = enum { auto, copy, move };

fn fromGdkAction(action: c.GdkDragAction) DropAction {
    if (action & c.GDK_ACTION_MOVE != 0) return .move;
    if (action & c.GDK_ACTION_COPY != 0) return .copy;
    return .auto;
}

/// Apply every internal drag spec in one payload to the same target.
pub fn dropValueIntoAction(self: *BrowserView, tab: *BTab, value: *c.GValue, dst_dir: []const u8, action: c.GdkDragAction) bool {
    if (self.picker) |pk| if (pk.suppress_ops) return false;
    var specs = dnd.ValueIter.init(self.allocator, value);
    defer specs.deinit();
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |spec| self.allocator.free(spec);
        owned.deinit(self.allocator);
    }
    while (specs.next()) |spec| {
        const copy = self.allocator.dupe(u8, spec) catch return false;
        for (owned.items) |previous| {
            if (std.mem.eql(u8, std.fs.path.basename(previous), std.fs.path.basename(copy))) {
                self.allocator.free(copy);
                self.setStatusFmt("drop refused: more than one item is named {s}", .{std.fs.path.basename(spec)});
                return false;
            }
        }
        owned.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return false;
        };
    }
    if (owned.items.len == 0) return false;
    const drop_action = fromGdkAction(action);
    var manifest_specs: std.ArrayList(@import("../file_transfers.zig").BatchSpec) = .empty;
    var planned: std.ArrayList([]u8) = .empty;
    defer {
        for (manifest_specs.items) |item| self.allocator.free(item.dst_path);
        manifest_specs.deinit(self.allocator);
        planned.deinit(self.allocator);
    }
    var common_host: ?[]const u8 = null;
    var common_host_set = false;
    var cross_host = false;
    var move = false;
    for (owned.items) |spec| {
        const loc = parseSpec(spec);
        const src_host: ?[]const u8 = if (loc.current_host) null else loc.host;
        if (loc.path.len == 0 or loc.path[0] != '/') return false;
        if (!common_host_set) {
            common_host = src_host;
            common_host_set = true;
            cross_host = !hostEq(src_host, tab.hc.host);
            move = drop_action == .move or (drop_action == .auto and !cross_host);
        } else if (!hostEq(common_host, src_host)) {
            self.setStatus("drop refused: all items must come from one host");
            return false;
        }
        var dst_buf: [4200]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
            if (dst_dir.len == 1) "" else dst_dir,
            std.fs.path.basename(loc.path),
        }) catch return false;
        if (hostEq(src_host, tab.hc.host) and std.mem.eql(u8, loc.path, dst)) continue;
        // A folder dropped into itself or into one of its own
        // descendants. The paths differ (/a/b -> /a/b/b), so equality
        // admitted it: as a move that is a raw EINVAL, and as a copy
        // the daemon mkdirs the destination before it lists the
        // source, so the fresh copy joins the walk and the job
        // recurses until the path overflows -- with the disk filling
        // the whole way.
        if (hostEq(src_host, tab.hc.host) and dirWithin(dst_dir, loc.path)) {
            self.setStatusFmt("drop refused: {s} cannot go inside itself", .{std.fs.path.basename(loc.path)});
            return false;
        }
        const dst_owned = self.allocator.dupe(u8, dst) catch return false;
        manifest_specs.append(self.allocator, .{
            .src_path = loc.path,
            .dst_path = dst_owned,
        }) catch {
            self.allocator.free(dst_owned);
            return false;
        };
        planned.append(self.allocator, spec) catch return false;
    }
    if (manifest_specs.items.len == 0) return false;
    var batch_id = if (planned.items.len > 1) newBatchId() else 0;
    if (cross_host and batch_id == 0) batch_id = newBatchId();
    var manifest: ?[]const u8 = null;
    if (cross_host) {
        const service = self.transfer_service orelse {
            self.setStatus("drop not started because durable recovery is unavailable");
            return false;
        };
        manifest = service.newUserBatch(
            common_host orelse "",
            tab.hc.host orelse "",
            move,
            batch_id,
            manifest_specs.items.len,
            manifest_specs.items,
            @ptrCast(self),
        ) orelse {
            self.setStatus("drop not started because its recovery record could not be saved");
            return false;
        };
    }
    var admitted = false;
    for (planned.items, 0..) |spec, item_index| {
        if (dropSpecIntoActionBatch(self, tab, spec, dst_dir, drop_action, batch_id, planned.items.len, manifest, if (manifest != null) item_index else null)) admitted = true;
    }
    if (!admitted) if (manifest) |token| if (self.transfer_service) |service| service.unclaimUserBatch(token);
    if (admitted) self.setStatusFmt("checking {d} dropped item(s) for conflicts", .{planned.items.len});
    return admitted;
}

/// Land a dragged entry spec in `dst_dir` on `tab`'s host. `.auto`
/// keeps the topology default (same host = MOVE via undoable rename,
/// cross-host = copy); modifiers override it. Shared by the listing,
/// the breadcrumb segments and the tab labels.
/// @return false when the spec is unusable or the drop is a no-op.
pub fn dropSpecIntoAction(self: *BrowserView, tab: *BTab, spec: []const u8, dst_dir: []const u8, action: DropAction) bool {
    return dropSpecIntoActionBatch(self, tab, spec, dst_dir, action, 0, 0, null, null);
}

fn dropSpecIntoActionBatch(self: *BrowserView, tab: *BTab, spec: []const u8, dst_dir: []const u8, action: DropAction, batch_id: u64, batch_total: usize, manifest_token: ?[]const u8, manifest_index: ?usize) bool {
    if (self.picker) |pk| if (pk.suppress_ops) return false;
    if (spec.len == 0) return false;
    const loc = parseSpec(spec);
    const src_host: ?[]const u8 = if (loc.current_host) null else loc.host;
    const src = loc.path;
    if (src.len == 0 or src[0] != '/') return false;
    const base = std.fs.path.basename(src);
    var dst_buf: [4200]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
        if (dst_dir.len == 1) "" else dst_dir, base,
    }) catch return false;

    const same_host = hostEq(src_host, tab.hc.host);
    if (same_host and std.mem.eql(u8, src, dst)) return false;
    // See dropValueIntoAction: equality alone admits a folder dropped
    // into its own descendant, which copies until the path overflows.
    if (same_host and dirWithin(dst_dir, src)) {
        self.setStatusFmt("drop refused: {s} cannot go inside itself", .{base});
        return false;
    }
    if (tab.hc.state != .ready) {
        self.setStatusFmt("drop not queued: not connected to {s}", .{tab.hc.label()});
        return false;
    }
    const src_hc = self.hostConnFor(src_host) orelse return false;
    const probe = self.allocator.create(DropProbe) catch return false;
    const src_owned = self.allocator.dupe(u8, src) catch {
        self.allocator.destroy(probe);
        return false;
    };
    const dst_owned = self.allocator.dupe(u8, dst) catch {
        self.allocator.free(src_owned);
        self.allocator.destroy(probe);
        return false;
    };
    const host_owned = if (src_host) |host| self.allocator.dupe(u8, host) catch {
        self.allocator.free(src_owned);
        self.allocator.free(dst_owned);
        self.allocator.destroy(probe);
        return false;
    } else null;
    const manifest_owned = if (manifest_token) |token| self.allocator.dupe(u8, token) catch {
        if (host_owned) |host| self.allocator.free(host);
        self.allocator.free(src_owned);
        self.allocator.free(dst_owned);
        self.allocator.destroy(probe);
        return false;
    } else null;
    const move = action == .move or (action == .auto and same_host);
    probe.* = .{
        .req = self.nextReq(),
        .tab = tab,
        .dst_hc = tab.hc,
        .src_hc = src_hc,
        .src_host = host_owned,
        .src = src_owned,
        .dst = dst_owned,
        .cut = move,
        .batch_id = batch_id,
        .batch_total = batch_total,
        .manifest_token = manifest_owned,
        .manifest_index = manifest_index,
    };
    self.drop_probes.append(self.allocator, probe) catch {
        probe.destroy(self.allocator);
        return false;
    };
    if (!self.sendOpOk(tab.hc, .{ .req = probe.req, .op = "stat", .path = probe.dst })) {
        _ = self.drop_probes.pop();
        probe.destroy(self.allocator);
        return false;
    }
    return true;
}

pub fn feedDropProbe(self: *BrowserView, hc: *HostConn, rep: WireReply) bool {
    for (self.drop_probes.items, 0..) |probe, i| {
        if (probe.req != rep.req or probe.dst_hc != hc) continue;
        _ = self.drop_probes.orderedRemove(i);
        defer probe.destroy(self.allocator);
        defer if (probe.manifest_token) |token| self.settleUserBatch(token);
        if (!self.tabAlive(probe.tab)) return true;
        if (probe.tab.hc != probe.dst_hc) {
            self.setStatus("drop canceled because the target tab moved to another host");
            return true;
        }
        if (rep.ok and rep.entry != null) {
            if (probe.manifest_token) |token| {
                const service = self.transfer_service orelse return true;
                if (!service.markUserBatchConflict(token, probe.manifest_index.?, rep.entry.?.tdir)) {
                    self.setStatusFmt("drop conflict recovery could not be updated: {s}", .{std.fs.path.basename(probe.src)});
                    return true;
                }
            }
            const before = self.conflicts.queue.items.len;
            conflict.enqueue(self, probe.tab, probe.src_hc, probe.src_host, probe.src, probe.dst, rep.entry.?.tdir, probe.cut, probe.batch_id, probe.batch_total, if (probe.manifest_token) |token| .{
                .token = token,
                .index = probe.manifest_index.?,
            } else null);
            if (self.conflicts.queue.items.len == before)
                self.setStatusFmt("drop conflict could not be queued: {s}", .{std.fs.path.basename(probe.src)});
            return true;
        }
        if (std.mem.eql(u8, rep.@"error", "NOENT")) {
            if (!probe.dst_hc.io().caps.copy_no_replace) {
                self.setStatusFmt("drop not queued: {s} runs an older daemon without safe no-replace support", .{probe.dst_hc.label()});
                return true;
            }
            const opts = PasteOpts{ .no_replace = true, .batch_id = probe.batch_id, .batch_total = probe.batch_total };
            if (probe.manifest_token) |token| {
                const admitted = self.startBatchTransfer(probe.src_hc, probe.src, probe.dst_hc, probe.dst, .{
                    .delete_src_after = probe.cut,
                    .no_replace = true,
                    .batch_id = probe.batch_id,
                    .batch_total = probe.batch_total,
                }, token, probe.manifest_index.?);
                if (admitted) {
                    self.settleUserBatch(token);
                }
            } else {
                _ = pasteOneAdmitted(self, probe.tab, probe.src_host, probe.src, probe.dst, probe.cut, opts);
            }
            return true;
        }
        if (probe.manifest_token) |token| self.settleUserBatch(token);
        self.setStatusFmt("drop not started: cannot inspect {s} ({s})", .{ probe.dst, rep.@"error" });
        return true;
    }
    return false;
}

/// The other browser face in this sketerm tab, if any: the
/// orthodox implicit destination.
pub fn peerView(self: *BrowserView) ?*BrowserView {
    const lookup = self.on_peer orelse return null;
    const ctx = self.hooks_ctx orelse return null;
    const pane = self.pane orelse return null;
    const peer = lookup(ctx, pane) orelse return null;
    return if (peer == self) null else peer;
}

/// Copy (or move) the current selection into the other pane's
/// current directory, conflict dialog included.
pub fn sendToPeer(self: *BrowserView, move: bool, clicked: ?[]const u8) void {
    const tab = self.currentTab() orelse return;
    const peer = self.peerView() orelse {
        self.setStatus("no second browser pane in this tab");
        return;
    };
    const peer_tab = peer.currentTab() orelse return;
    // Same rule as Copy: a clicked row outside the selection acts
    // on itself, not on the selection.
    var one: [1][]u8 = undefined;
    var sources: []const []u8 = tab.selected.items;
    if (clicked) |path| {
        if (!tab.selected.actsOnAll(path)) {
            one[0] = @constCast(path);
            sources = one[0..];
        }
    }
    if (sources.len == 0) {
        self.setStatus("select something to send to the other pane");
        return;
    }
    const roots = oproots.collect(self.allocator, tab, sources) catch {
        self.setStatus("file operation not started: out of memory");
        return;
    };
    defer self.allocator.free(roots);
    if (hostEq(tab.hc.host, peer_tab.hc.host) and std.mem.eql(u8, tab.root.path, peer_tab.root.path)) {
        self.setStatus("both panes show the same directory");
        return;
    }
    _ = peer.beginPaste(peer_tab, tab.hc.host, roots, move, false);
    var buf: [4300]u8 = undefined;
    self.setStatusFmt("{s} {d} item(s) to {s}", .{
        if (move) "moving" else "copying",
        roots.len,
        peer_tab.spec(&buf),
    });
}

test "paste batch status preserves failures and counts only admissions" {
    const t = std.testing;
    try t.expectEqual(PasteBatchAction.preserve_failure, pasteBatchAction(2, 0, 1, true));
    try t.expectEqual(PasteBatchAction.rejected, pasteBatchAction(0, 0, 1, false));
    try t.expectEqual(PasteBatchAction.conflicts, pasteBatchAction(1, 2, 0, false));
    try t.expectEqual(PasteBatchAction.nothing, pasteBatchAction(0, 0, 0, false));
    try t.expectEqual(PasteBatchAction.queued, pasteBatchAction(3, 0, 0, false));
}

test "file clipboard ownership follows local and remote GDK providers" {
    // Opt in only on an isolated display: never overwrite the user's clipboard.
    if (c.getenv("SKETERM_TEST_FILE_CLIPBOARD") == null) return error.SkipZigTest;
    const t = std.testing;
    try t.expect(c.gtk_init_check() != 0);
    const display = c.gdk_display_get_default() orelse return error.TestUnexpectedResult;
    const clip = c.gdk_display_get_clipboard(display) orelse return error.TestUnexpectedResult;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const board = clipboard.shared(failing.allocator());
    defer {
        file_clipboard_owner.release();
        clipboard.resetShared();
        _ = c.gdk_clipboard_set_content(clip, null);
    }
    for ([_]?[]const u8{ null, "remote" }) |host| {
        try t.expect(board.set(host, &.{"/first"}, true, 1));
        try t.expect(exportClipToGdk(board, clip));
        const formats = c.gdk_clipboard_get_formats(clip);
        try t.expectEqual(host == null, c.gdk_content_formats_contain_mime_type(formats, "x-special/gnome-copied-files") != 0);
        try t.expectEqual(host == null, c.gdk_content_formats_contain_mime_type(formats, clipboard.URI) != 0);
        try t.expectEqual(host == null, c.gdk_content_formats_contain_mime_type(formats, clipboard.KDE_CUT) != 0);
        c.g_signal_emit_by_name(clip, "changed");
        try t.expect(board.cut);
        try t.expectEqualStrings("/first", board.first().?);

        // A new Files export synchronously replaces the previous provider.
        try t.expect(board.set(host, &.{"/second"}, true, 1));
        try t.expect(exportClipToGdk(board, clip));
        try t.expect(board.cut);
        try t.expectEqualStrings("/second", board.first().?);

        // The same clipboard API used by Files' Copy Path action.
        @import("../clipboard.zig").copyTextTo(t.allocator, clip, "/copied/path");
        try t.expect(board.isEmpty());
        try t.expect(!board.cut);
        try t.expect(file_clipboard_owner.clip == null);

        try t.expect(board.set(host, &.{"/third"}, true, 1));
        try t.expect(exportClipToGdk(board, clip));
        // External ownership has no local content provider.
        try t.expect(c.gdk_clipboard_set_content(clip, null) != 0);
        try t.expect(board.isEmpty());
        try t.expect(!board.cut);

        try t.expect(board.set(host, &.{"/fourth"}, true, 1));
        try t.expect(exportClipToGdk(board, clip));
        try t.expect(board.set(host, &.{"/failed-export"}, true, 1));
        failing.fail_index = failing.alloc_index;
        try t.expect(!exportClipToGdk(board, clip));
        failing.fail_index = std.math.maxInt(usize);
        try t.expect(board.isEmpty());
        try t.expect(!board.cut);
        try t.expect(file_clipboard_owner.clip == null);
    }
    try t.expect(board.set(null, &.{"relative-path-cannot-be-a-file-uri"}, true, 1));
    try t.expect(!exportClipToGdk(board, clip));
    try t.expect(board.isEmpty());

    try t.expect(board.set("remote", &.{"/last"}, true, 1));
    try t.expect(exportClipToGdk(board, clip));
    clipboard.resetShared();
    c.gdk_clipboard_set_text(clip, "ownership changed after board teardown");
    try t.expect(file_clipboard_owner.clip == null);
}

// Test-only fixture: no socket is initialized, and both host connections
// are prelisted so importing local URIs cannot autostart a real daemon.
const ExternalPasteTest = struct {
    view: BrowserView = .{ .allocator = std.testing.allocator },
    root: Dir = .{ .allocator = std.testing.allocator, .path = @constCast("/destination"), .view_id = 1 },
    local: HostConn = undefined,
    remote: HostConn = undefined,
    tab: BTab = undefined,
    column: ?*c.GtkWidget = null,
    status: ?*c.GtkWidget = null,
    clip: ?*c.GdkClipboard = null,
    window: ?*c.GtkWidget = null,
    /// The process-wide request counter when the test began.
    req_mark: u32 = 0,

    fn init(self: *ExternalPasteTest) !void {
        if (c.getenv("SKETERM_TEST_FILE_CLIPBOARD") == null) return error.SkipZigTest;
        try std.testing.expect(c.gtk_init_check() != 0);
        self.* = .{ .req_mark = @import("conn.zig").shared_next_req };
        errdefer self.deinit();
        self.column = c.gtk_column_view_new(null).?;
        _ = c.g_object_ref_sink(self.column);
        self.status = c.gtk_label_new(null).?;
        _ = c.g_object_ref_sink(self.status);
        self.view.status_label = @ptrCast(self.status.?);
        self.clip = c.gtk_widget_get_clipboard(self.column).?;
        self.local = .{ .view = &self.view, .host = null };
        self.remote = .{ .view = &self.view, .host = @constCast("test-remote") };
        self.tab = .{
            .view = &self.view,
            .hc = &self.remote,
            .root = &self.root,
            .page = self.column.?,
            .listing_box = self.column.?,
            .colview = @ptrCast(self.column.?),
            .tab_label = self.view.status_label,
        };
        try self.view.conns.appendSlice(self.view.allocator, &.{ &self.local, &self.remote });
        try self.view.tabs.append(self.view.allocator, &self.tab);
    }

    fn enableConflicts(self: *ExternalPasteTest) !void {
        self.tab.hc = &self.local;
        try std.testing.expect(self.local.state == .connecting);
        self.window = c.gtk_window_new().?;
        _ = c.g_object_ref(self.window);
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        self.view.root_box = box;
        self.view.jobs_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        self.tab.page = box;
        c.gtk_box_append(@ptrCast(box), self.column);
        c.gtk_box_append(@ptrCast(box), self.status);
        c.gtk_box_append(@ptrCast(box), self.view.jobs_box);
        c.gtk_window_set_child(@ptrCast(self.window), box);
        c.gtk_window_set_default_size(@ptrCast(self.window), 800, 600);
        c.gtk_window_present(@ptrCast(self.window));
        const clock = @import("../../util/clock.zig");
        const deadline = clock.nowMs() + 5000;
        while (c.gtk_widget_get_mapped(self.window) == 0 and clock.nowMs() < deadline) {
            _ = c.g_main_context_iteration(null, 0);
            c.g_usleep(1000);
        }
        try std.testing.expect(c.gtk_widget_get_mapped(self.window) != 0);
        var entry = try @import("types.zig").testEntry(self.view.allocator, "one", null);
        errdefer entry.deinit(self.view.allocator);
        try self.root.entries.append(self.view.allocator, entry);
    }

    fn deinit(self: *ExternalPasteTest) void {
        if (self.view.external_paste) |read| {
            var done = false;
            c.g_object_weak_ref(@ptrCast(read.cancel), &retired, &done);
            cancelExternalPaste(&self.view, null);
            waitRetired(&done) catch @panic("clipboard callback did not retire");
        }
        file_clipboard_owner.release();
        clipboard.resetShared();
        if (self.clip) |clip| _ = c.gdk_clipboard_set_content(clip, null);
        conflict.cancelTab(&self.view, &self.tab);
        self.view.conflicts.deinit(self.view.allocator);
        self.view.jobs_panel.cancelTick();
        if (self.window) |window| {
            c.gtk_window_destroy(@ptrCast(window));
            c.g_object_unref(window);
        }
        self.view.jobs_panel.deinit(self.view.allocator);
        for (self.root.entries.items) |*entry| entry.deinit(self.view.allocator);
        self.root.entries.deinit(self.view.allocator);
        if (self.column) |widget| c.g_object_unref(widget);
        if (self.status) |widget| c.g_object_unref(widget);
        self.view.tabs.deinit(self.view.allocator);
        self.view.conns.deinit(self.view.allocator);
    }

    const Payload = struct { mime: [*:0]const u8, data: []const u8 };

    fn offer(self: *ExternalPasteTest, payloads: []const Payload) !void {
        var providers: [3]?*c.GdkContentProvider = undefined;
        try std.testing.expect(payloads.len > 0 and payloads.len <= providers.len);
        for (payloads, 0..) |payload, i| {
            const bytes = c.g_bytes_new(payload.data.ptr, payload.data.len).?;
            defer c.g_bytes_unref(bytes);
            providers[i] = c.gdk_content_provider_new_for_bytes(payload.mime, bytes).?;
        }
        const provider = c.gdk_content_provider_new_union(&providers, payloads.len).?;
        defer c.g_object_unref(provider); // union owns its children
        try std.testing.expect(c.gdk_clipboard_set_content(self.clip.?, provider) != 0);
    }

    fn retired(user: ?*anyopaque, _: [*c]c.GObject) callconv(.c) void {
        cast.userData(bool, user).* = true;
    }

    fn waitRetired(done: *bool) !void {
        const clock = @import("../../util/clock.zig");
        const deadline = clock.nowMs() + 5000;
        while (!done.* and clock.nowMs() < deadline) {
            _ = c.g_main_context_iteration(null, 0);
            c.g_usleep(1000);
        }
        try std.testing.expect(done.*);
    }

    fn paste(self: *ExternalPasteTest) !void {
        try self.pasteWithConflicts();
        try self.noJobs();
    }

    fn pasteWithConflicts(self: *ExternalPasteTest) !void {
        pasteIntoTab(&self.view, &self.tab);
        const read = self.view.external_paste orelse return error.TestUnexpectedResult;
        var done = false;
        const cancel = read.cancel;
        c.g_object_weak_ref(@ptrCast(cancel), &retired, &done);
        defer if (!done) c.g_object_weak_unref(@ptrCast(cancel), &retired, &done);
        try waitRetired(&done);
        try std.testing.expect(self.view.external_paste == null);
    }

    fn expectStatus(self: *ExternalPasteTest, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, std.mem.span(c.gtk_label_get_text(self.view.status_label)));
    }

    fn noJobs(self: *ExternalPasteTest) !void {
        try self.noTransfers();
        try std.testing.expectEqual(@as(usize, 0), self.view.conflicts.queue.items.len);
    }

    fn noTransfers(self: *ExternalPasteTest) !void {
        const t = std.testing;
        try t.expectEqual(self.req_mark, @import("conn.zig").shared_next_req);
        try t.expectEqual(@as(usize, 2), self.view.conns.items.len);
        try t.expect(self.view.transfer_service == null);
        try t.expectEqual(@as(usize, 0), self.view.pending.items.len);
        try t.expectEqual(@as(usize, 0), self.view.pending_jobs.items.len);
        try t.expectEqual(@as(usize, 0), self.view.jobs.items.len);
        try t.expectEqual(@as(usize, 0), self.view.transfers.items.len);
        try t.expectEqual(@as(usize, 0), self.view.deferred_transfers.items.len);
        try t.expectEqual(@as(usize, 0), self.view.paste_runs.items.len);
        try t.expectEqual(@as(c.guint, 0), self.view.paste_idle);
    }

    fn expectOneConflict(self: *ExternalPasteTest, cut: bool) !void {
        const t = std.testing;
        try self.noTransfers();
        try t.expectEqual(@as(usize, 1), self.view.conflicts.queue.items.len);
        const item = self.view.conflicts.queue.items[0];
        try t.expectEqualStrings("/source/one", item.src);
        try t.expectEqualStrings("/destination/one", item.dst);
        try t.expectEqual(cut, item.cut);
        try t.expect(item.src_hc == &self.local and item.dst_hc == &self.local);
        try t.expect(item.manifest_token == null);
        try t.expect(self.view.conflicts.popover != null);
        try t.expect(c.gtk_widget_get_root(self.view.conflicts.popover.?) != null);
        try t.expect(c.gtk_widget_get_root(self.view.jobs_box) != null);
    }
};

test "external paste reads real GNOME and URI providers and refuses malformed payloads" {
    const t = std.testing;
    var f: ExternalPasteTest = .{};
    try f.init();
    defer f.deinit();
    const refusal = "paste not started because durable recovery is unavailable";
    for ([_]struct { mime: [*:0]const u8, data: []const u8, status: []const u8 }{
        .{ .mime = clipboard.GNOME, .data = "copy\nfile:///source/one%20file", .status = refusal },
        .{ .mime = clipboard.GNOME, .data = "cut\nfile:///source/one", .status = refusal },
        .{ .mime = clipboard.URI, .data = "# comment\r\nfile:///source/one\r\n", .status = refusal },
        .{ .mime = clipboard.GNOME, .data = "move\nfile:///source/one", .status = "clipboard must contain valid local file URIs; paste canceled" },
        .{ .mime = clipboard.URI, .data = "file:///source/one\nhttps://example.invalid/two", .status = "clipboard must contain valid local file URIs; paste canceled" },
    }) |case| {
        try f.offer(&.{.{ .mime = case.mime, .data = case.data }});
        try t.expect(canPaste(&f.view, &f.tab));
        const provider = c.gdk_clipboard_get_content(f.clip.?);
        try f.paste();
        try f.expectStatus(case.status);
        // A refused external cut is neither consumed nor imported globally.
        try t.expect(c.gdk_clipboard_get_content(f.clip.?) == provider);
        try t.expect(f.view.clipboard().isEmpty());
    }
    // Prefer GNOME when both formats are offered, not the malformed URI list.
    try f.offer(&.{
        .{ .mime = clipboard.URI, .data = "not a URI" },
        .{ .mime = clipboard.GNOME, .data = "copy\nfile:///source/one" },
    });
    try f.paste();
    try f.expectStatus(refusal);
    c.gdk_clipboard_set_text(f.clip.?, "/source/one");
    try t.expect(!canPaste(&f.view, &f.tab));
    pasteIntoTab(&f.view, &f.tab);
    try t.expect(f.view.external_paste == null);
    try f.expectStatus("clipboard contains no supported files");
}

test "external paste reads KDE cut metadata rather than guessing from its presence" {
    var f: ExternalPasteTest = .{};
    try f.init();
    defer f.deinit();
    f.tab.hc = &f.local;
    f.root.path = @constCast("/source");
    // Same-folder moves are no-ops. Copies reach duplicateEntry, whose
    // startDaemonJobUndo refuses our disconnected host before minting a req.
    // These different outcomes expose the parsed cut flag without a seam.
    for ([_]struct { hint: []const u8, status: []const u8 }{
        .{ .hint = "0", .status = "not connected to local" },
        .{ .hint = "1", .status = "nothing to paste here" },
        .{ .hint = "1\r\n", .status = "nothing to paste here" },
        .{ .hint = "2", .status = "invalid clipboard cut flag; paste canceled" },
        .{ .hint = "", .status = "invalid clipboard cut flag; paste canceled" },
        .{ .hint = "12345678901234567", .status = "file clipboard is too large; paste canceled" },
    }) |case| {
        try f.offer(&.{
            .{ .mime = clipboard.URI, .data = "file:///source/one" },
            .{ .mime = clipboard.KDE_CUT, .data = case.hint },
        });
        try f.paste();
        try f.expectStatus(case.status);
    }
    // GNOME owns the verb when present; KDE metadata is only a URI-list hint.
    try f.offer(&.{
        .{ .mime = clipboard.GNOME, .data = "cut\nfile:///source/one" },
        .{ .mime = clipboard.KDE_CUT, .data = "invalid" },
    });
    try f.paste();
    try f.expectStatus("nothing to paste here");
}

test "external paste pending reads respect ownership navigation and teardown fences" {
    const t = std.testing;
    const Change = enum { owner, timeout, generation, view_id, removed_tab, cancel, tab_teardown, view_fence, widgets_dead };
    for (std.enums.values(Change)) |change| {
        var f: ExternalPasteTest = .{};
        try f.init();
        defer f.deinit();
        try f.offer(&.{.{ .mime = clipboard.URI, .data = "file:///source/one" }});
        const tab = try t.allocator.create(BTab);
        tab.* = f.tab;
        var tab_live = true;
        defer if (tab_live) t.allocator.destroy(tab);
        f.view.tabs.items[0] = tab;
        pasteIntoTab(&f.view, tab);
        const read = f.view.external_paste orelse return error.TestUnexpectedResult;
        var done = false;
        const cancel = read.cancel;
        c.g_object_weak_ref(@ptrCast(cancel), &ExternalPasteTest.retired, &done);
        defer if (!done) c.g_object_weak_unref(@ptrCast(cancel), &ExternalPasteTest.retired, &done);
        switch (change) {
            .owner => c.gdk_clipboard_set_text(f.clip.?, "replacement clipboard"),
            .timeout => {
                _ = c.g_source_remove(read.timeout);
                _ = ExternalPaste.timedOut(read);
            },
            .generation => tab.navigation_generation += 1,
            .view_id => f.root.view_id += 1,
            .removed_tab => {
                f.view.tabs.clearRetainingCapacity();
                t.allocator.destroy(tab);
                tab_live = false;
            },
            .cancel, .view_fence => {
                // Cancellation for a different tab must leave this request alone.
                cancelExternalPaste(&f.view, &f.tab);
                try t.expect(f.view.external_paste == read);
                if (change == .view_fence) f.view.widgets_dead = true;
                cancelExternalPaste(&f.view, null);
                try t.expect(read.view == null);
            },
            .tab_teardown => {
                cancelDropStateForTab(&f.view, tab);
                try t.expect(read.view == null);
                f.view.tabs.clearRetainingCapacity();
                t.allocator.destroy(tab);
                tab_live = false;
            },
            .widgets_dead => f.view.widgets_dead = true,
        }
        // Direct GTK write also works after the simulated widget fence.
        c.gtk_label_set_text(f.view.status_label, "sentinel");
        try ExternalPasteTest.waitRetired(&done);
        try t.expect(f.view.external_paste == null);
        try f.noJobs();
        try f.expectStatus(switch (change) {
            .owner => "clipboard changed; paste canceled",
            .timeout => "clipboard did not respond; paste canceled",
            .generation, .view_id, .removed_tab => "destination changed; paste canceled",
            else => "sentinel",
        });
    }
}

test "external paste does not reimport a consumed internal cut export" {
    const t = std.testing;
    var f: ExternalPasteTest = .{};
    try f.init();
    defer f.deinit();
    const board = f.view.clipboard();
    try t.expect(board.set(null, &.{"/source/one"}, true, 0));
    try t.expect(exportClipToGdk(board, f.clip.?));
    const provider = c.gdk_clipboard_get_content(f.clip.?);
    try t.expect(canPaste(&f.view, &f.tab));
    board.clear(); // successful internal cut consumption leaves the MIME export
    try t.expect(!canPaste(&f.view, &f.tab));
    pasteIntoTab(&f.view, &f.tab);
    try t.expect(f.view.external_paste == null);
    try t.expect(c.gdk_clipboard_get_content(f.clip.?) == provider);
    try f.expectStatus("clipboard contains no supported files");
    try f.noJobs();
    // A genuinely new provider offering the same file is not suppressed.
    try f.offer(&.{.{ .mime = clipboard.GNOME, .data = "copy\nfile:///source/one" }});
    try t.expect(canPaste(&f.view, &f.tab));
    try f.paste();
    try f.expectStatus("paste not started because durable recovery is unavailable");
}

test "paste complete admission retains the whole internal cut on partial admission" {
    const t = std.testing;
    for ([_]bool{ true, false }) |partial| {
        var f: ExternalPasteTest = .{};
        try f.init();
        defer f.deinit();
        try f.enableConflicts();
        const board = f.view.clipboard();
        const sources: []const []const u8 = if (partial) &.{ "/source/one", "/source/two" } else &.{"/source/one"};
        try t.expect(board.set(null, sources, true, 0));
        try t.expect(exportClipToGdk(board, f.clip.?));
        const provider = c.gdk_clipboard_get_content(f.clip.?);
        const original_items = board.items().ptr;
        try t.expectEqual(!partial, beginPaste(&f.view, &f.tab, board.hostOpt(), board.items(), board.cut, true));
        try f.expectOneConflict(true);
        try t.expect(c.gdk_clipboard_get_content(f.clip.?) == provider);
        if (partial) {
            try t.expect(board.cut);
            try t.expectEqual(@as(usize, 2), board.items().len);
            try t.expect(board.items().ptr == original_items);
            try t.expectEqualStrings("/source/one", board.items()[0]);
            try t.expectEqualStrings("/source/two", board.items()[1]);
            try t.expect(canPaste(&f.view, &f.tab));
            try f.expectStatus("0 queued; 1 conflicts; 1 not queued: not connected to local");
        } else {
            try t.expect(board.isEmpty());
            try t.expect(!canPaste(&f.view, &f.tab));
            try f.expectStatus("0 item(s) queued; 1 name conflict(s) waiting for a decision");
        }
    }
}

test "paste complete admission retains external GNOME cut unless every item is admitted" {
    const t = std.testing;
    for ([_]bool{ true, false }) |partial| {
        var f: ExternalPasteTest = .{};
        try f.init();
        defer f.deinit();
        try f.enableConflicts();
        try f.offer(&.{.{
            .mime = clipboard.GNOME,
            .data = if (partial) "cut\nfile:///source/one\nfile:///source/two" else "cut\nfile:///source/one",
        }});
        const provider = c.gdk_clipboard_get_content(f.clip.?).?;
        _ = c.g_object_ref(provider);
        defer c.g_object_unref(provider);
        try f.pasteWithConflicts();
        try f.expectOneConflict(true);
        try t.expect(f.view.clipboard().isEmpty());
        if (partial) {
            try t.expect(c.gdk_clipboard_get_content(f.clip.?) == provider);
            try t.expect(c.gdk_content_formats_contain_mime_type(c.gdk_clipboard_get_formats(f.clip.?), clipboard.GNOME) != 0);
            try t.expect(canPaste(&f.view, &f.tab));
            try f.expectStatus("0 queued; 1 conflicts; 1 not queued: not connected to local");
        } else {
            try t.expect(c.gdk_clipboard_get_content(f.clip.?) == null);
            try t.expect(!canPaste(&f.view, &f.tab));
            try f.expectStatus("0 item(s) queued; 1 name conflict(s) waiting for a decision");
        }
    }
}

test "paste complete admission counts self-copy refusal and overlong destination construction" {
    const t = std.testing;
    const long_base = [_]u8{'x'} ** 4090;
    const long_source = try std.fmt.allocPrint(t.allocator, "/{s}", .{&long_base});
    defer t.allocator.free(long_source);
    for ([_]bool{ true, false }) |self_copy| {
        var f: ExternalPasteTest = .{};
        try f.init();
        defer f.deinit();
        try f.enableConflicts();
        const board = f.view.clipboard();
        const refused = if (self_copy) "/destination" else long_source;
        const cut = !self_copy;
        try t.expect(board.set(null, &.{ "/source/one", refused }, cut, 0));
        try t.expect(exportClipToGdk(board, f.clip.?));
        const provider = c.gdk_clipboard_get_content(f.clip.?);
        try t.expect(!beginPaste(&f.view, &f.tab, board.hostOpt(), board.items(), board.cut, true));
        try f.expectOneConflict(cut);
        try t.expectEqual(cut, board.cut);
        try t.expectEqual(@as(usize, 2), board.items().len);
        try t.expectEqualStrings("/source/one", board.items()[0]);
        try t.expectEqualStrings(refused, board.items()[1]);
        try t.expect(c.gdk_clipboard_get_content(f.clip.?) == provider);
        try f.expectStatus(if (self_copy)
            "0 queued; 1 conflicts; 1 not queued: paste refused: destination cannot go inside itself"
        else
            "0 queued; 1 conflicts; 1 not queued: paste not queued: destination path is too long");
    }
}
