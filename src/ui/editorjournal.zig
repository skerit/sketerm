//! Crash recovery for the editor face: the debounced journal writer and
//! the once-per-process recovery offer. editor/journal.zig owns the
//! record format and the flock-based crash predicate.
//!
//! ## The write never runs on the main thread
//!
//! A dirty buffer is snapshotted every `DEBOUNCE_MS`, and a snapshot is
//! up to 64 MiB of hashing, JSON framing and an fsync'd atomic replace.
//! The main thread only takes the owned copy (`Handle.snapshot`); a
//! detached worker writes it and hands back through `g_idle_add`. The
//! worker touches nothing but its `Snapshot` and the slot's `abandon`
//! flag. Unchanged content is skipped cheaply: a tick compares the
//! document's history STATE with the last one written, so an idle
//! buffer, or one undone and redone back to the same text, costs nothing.
//!
//! ## A slot outlives its tab while a write is in flight
//!
//! Closing a tab (or saving it clean) while its snapshot is on a worker
//! must not race the worker's rename: the record would be recreated
//! after the discard and offered as unsaved work next launch. So the
//! slot is heap memory the in-flight job co-owns: `release` and `onClean`
//! only MARK it, set `abandon` (the worker then unlinks what it just
//! wrote), and the handback finishes the discard or the clear.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const clock = @import("../util/clock.zig");
const ev = @import("editorview.zig");
const EditorView = ev.EditorView;
const ETab = ev.ETab;
const Document = @import("../editor/document.zig").Document;
const journal = @import("../editor/journal.zig");
const sel_mod = @import("../editor/selection.zig");
const Selection = sel_mod.Selection;
const paths = @import("../filebrowser/paths.zig");
const confirm = @import("confirm.zig");
const pathz = @import("../util/pathz.zig");

/// Debounce between snapshots of a dirty buffer. Long enough that typing
/// never pays for it, short enough that a crash costs a second.
const DEBOUNCE_MS: c_uint = 1500;
/// Records nobody claimed in a week are dropped.
const MAX_AGE_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// The recovery offer is per PROCESS, not per face: several editor faces
/// must not each open the same records.
var recovery_offered: bool = false;

/// One tab's journal record, co-owned by an in-flight write.
pub const Slot = struct {
    handle: journal.Handle,
    /// A write is on a worker; the handback finishes what is pending.
    in_flight: bool = false,
    /// The tab went away (or recovery was switched off) mid-write.
    discard_pending: bool = false,
    /// The buffer went clean mid-write.
    clear_pending: bool = false,
    /// Read by the worker after its rename: the snapshot it wrote is no
    /// longer wanted, so it unlinks it itself.
    abandon: std.atomic.Value(bool) = .init(false),

    fn destroy(self: *Slot) void {
        std.heap.c_allocator.destroy(self);
    }
};

const WriteJob = struct {
    slot: *Slot,
    snap: journal.Snapshot,
    /// History state the snapshot holds.
    state: u64,
    ok: bool = false,

    fn destroy(self: *WriteJob) void {
        self.snap.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

fn writeThread(job: *WriteJob) void {
    if (job.snap.write()) |_| {
        job.ok = true;
        if (job.slot.abandon.load(.acquire)) pathz.unlinkPath(job.snap.rec_path);
    } else |_| {}
    _ = c.g_idle_add(@ptrCast(&writeIdle), @ptrCast(job));
}

/// Main thread: finish whatever was marked while the write was out.
fn writeIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(WriteJob, user);
    defer job.destroy();
    const slot = job.slot;
    slot.in_flight = false;
    if (slot.discard_pending) {
        slot.handle.discard();
        slot.destroy();
        return 0;
    }
    if (slot.clear_pending) {
        slot.clear_pending = false;
        slot.abandon.store(false, .release);
        slot.handle.clear();
        return 0;
    }
    if (job.ok) slot.handle.noteWritten(job.state);
    return 0;
}

/// Arm the debounce after any edit. No-op when it is already running or
/// the feature is off.
pub fn arm(view: *EditorView) void {
    if (!view.crash_recovery or view.journal_timer != 0) return;
    view.journal_timer = c.g_timeout_add(DEBOUNCE_MS, @ptrCast(&onTimer), @ptrCast(view));
}

pub fn stopTimer(view: *EditorView) void {
    if (view.journal_timer != 0) {
        _ = c.g_source_remove(view.journal_timer);
        view.journal_timer = 0;
    }
}

fn onTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const view = cast.userData(EditorView, user);
    var any = false;
    for (view.tabs.items) |t| {
        if (tick(view, t)) any = true;
    }
    if (!any) {
        view.journal_timer = 0;
        return 0;
    }
    return 1;
}

/// One tab's snapshot decision. True while the tab still wants the timer
/// running.
pub fn tick(view: *EditorView, tab: *ETab) bool {
    if (!view.crash_recovery) {
        release(tab);
        return false;
    }
    if (!tab.isDirty()) {
        onClean(view, tab);
        return false;
    }
    // Given up on (too large): nothing more to do for this tab, so it
    // must not keep the timer spinning either.
    if (tab.journal_off) return false;
    if (tab.loading) return true;
    const slot = tab.journal orelse blk: {
        const s = std.heap.c_allocator.create(Slot) catch return true;
        s.* = .{ .handle = journal.open(view.allocator, tab.spec orelse "") catch {
            std.heap.c_allocator.destroy(s);
            tab.journal_off = true;
            return false;
        } };
        tab.journal = s;
        break :blk s;
    };
    // One write at a time per slot; the next tick takes the newest state.
    if (slot.in_flight) return true;
    const state = tab.doc.state();
    if (!slot.handle.shouldWrite(state)) return true;

    var hdr = journal.Header{
        .spec = tab.spec orelse "",
        .remote = if (tab.spec) |s| paths.parseSpec(s).host != null else false,
        .cursor = @intCast(tab.sels.primary().head),
    };
    hdr.setBaseline(tab.disk);
    const snap = slot.handle.snapshot(std.heap.c_allocator, &tab.doc, hdr) catch |e| {
        if (e == journal.Error.BufferTooLarge) {
            tab.journal_off = true;
            view.setStatusText("Buffer too large for crash recovery \u{2014} save often.");
            return false;
        }
        return true;
    };
    const job = std.heap.c_allocator.create(WriteJob) catch {
        var s = snap;
        s.deinit();
        return true;
    };
    job.* = .{ .slot = slot, .snap = snap, .state = state };
    slot.in_flight = true;
    const thread = std.Thread.spawn(.{}, writeThread, .{job}) catch {
        slot.in_flight = false;
        job.destroy();
        return true;
    };
    thread.detach();
    return true;
}

/// The buffer is clean (saved, reloaded, undone back to the saved text):
/// the record goes, the lock stays so the slot is still ours when the
/// buffer goes dirty again.
pub fn onClean(view: *EditorView, tab: *ETab) void {
    _ = view;
    if (tab.isDirty()) return;
    const slot = tab.journal orelse return;
    if (slot.in_flight) {
        slot.clear_pending = true;
        slot.abandon.store(true, .release);
        return;
    }
    slot.handle.clear();
}

/// The tab is going away (a close, a clean quit, recovery switched off):
/// the record and the lock go. Closing is exactly the "no crash
/// happened" case.
pub fn release(tab: *ETab) void {
    const slot = tab.journal orelse return;
    tab.journal = null;
    if (slot.in_flight) {
        slot.discard_pending = true;
        slot.abandon.store(true, .release);
        return;
    }
    slot.handle.discard();
    slot.destroy();
}

// ======================================================================
// The startup offer
// ======================================================================

/// The crash-recovery offer. Same shape as the external-change banner
/// (inline, dismissible, never modal) because it is the same kind of
/// news: something happened to your files while you were not looking,
/// and only you can decide what to do about it.
pub fn buildBanner(view: *EditorView) void {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_add_css_class(row, "toolbar");
    c.gtk_widget_add_css_class(row, "accent");
    c.gtk_widget_set_margin_start(row, 6);
    c.gtk_widget_set_margin_end(row, 6);
    c.gtk_widget_set_margin_top(row, 2);
    c.gtk_widget_set_margin_bottom(row, 2);
    c.gtk_widget_set_visible(row, 0);

    const icon = c.gtk_image_new_from_icon_name("document-revert-symbolic");
    c.gtk_box_append(@ptrCast(row), icon);

    const label = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_label_set_wrap(@ptrCast(label), 1);
    c.gtk_widget_set_hexpand(label, 1);
    c.gtk_box_append(@ptrCast(row), label);
    view.recover_label = @ptrCast(@alignCast(label));

    const recover_btn = c.gtk_button_new_with_label("Recover");
    c.gtk_widget_add_css_class(recover_btn, "suggested-action");
    c.gtk_widget_set_tooltip_text(recover_btn, "Open each unsaved buffer in a tab, still unsaved");
    _ = c.g_signal_connect_data(recover_btn, "clicked", @ptrCast(&onRecoverClicked), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), recover_btn);

    const discard_btn = c.gtk_button_new_with_label("Discard");
    c.gtk_widget_add_css_class(discard_btn, "destructive-action");
    c.gtk_widget_set_tooltip_text(discard_btn, "Delete these snapshots for good");
    _ = c.g_signal_connect_data(discard_btn, "clicked", @ptrCast(&onDiscardClicked), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), discard_btn);

    const later = c.gtk_button_new_from_icon_name("window-close-symbolic");
    c.gtk_button_set_has_frame(@ptrCast(later), 0);
    c.gtk_widget_set_tooltip_text(later, "Not now \u{2014} the snapshots are kept");
    _ = c.g_signal_connect_data(later, "clicked", @ptrCast(&onLaterClicked), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), later);

    view.recover_box = row.?;
}

/// Prune stale records and offer whatever a previous run left behind.
/// Runs ONCE per process, from the first editor face.
pub fn offerRecovery(view: *EditorView) void {
    if (recovery_offered or !view.crash_recovery) return;
    recovery_offered = true;
    _ = journal.prune(view.allocator, MAX_AGE_MS) catch {};
    const entries = journal.list(view.allocator) catch return;
    if (entries.len == 0) {
        journal.freeEntries(view.allocator, entries);
        return;
    }
    view.recovery = entries;
    updateBanner(view);
}

pub fn dropRecovery(view: *EditorView) void {
    if (view.recovery.len == 0) return;
    journal.freeEntries(view.allocator, view.recovery);
    view.recovery = &.{};
}

/// The offer's sentence: how many buffers, how long ago, and which.
pub fn bannerText(buf: *[320:0]u8, entries: []const journal.Entry, now_ms: i64) [:0]const u8 {
    var names: [180]u8 = undefined;
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        const name = recoveryName(e.header.spec);
        const sep: []const u8 = if (i == 0) "" else ", ";
        if (n + sep.len + name.len + 4 > names.len) {
            const more = std.fmt.bufPrint(names[n..], ", ...", .{}) catch break;
            n += more.len;
            break;
        }
        @memcpy(names[n .. n + sep.len], sep);
        n += sep.len;
        @memcpy(names[n .. n + name.len], name);
        n += name.len;
    }
    return std.fmt.bufPrintZ(
        buf,
        "{d} unsaved buffer(s) from a previous session ({s}), last changed {s}: {s}",
        .{
            entries.len,
            if (entries.len == 1) "one editor" else "earlier editors",
            agoText(now_ms, if (entries.len > 0) entries[0].header.updated_ms else now_ms),
            names[0..n],
        },
    ) catch "Unsaved buffers from a previous session are recoverable.";
}

fn updateBanner(view: *EditorView) void {
    if (view.widgets_dead) return;
    if (view.recovery.len == 0) {
        c.gtk_widget_set_visible(view.recover_box, 0);
        return;
    }
    var buf: [320:0]u8 = undefined;
    const text = bannerText(&buf, view.recovery, clock.wallMs());
    c.gtk_label_set_text(view.recover_label, text.ptr);
    c.gtk_widget_set_visible(view.recover_box, 1);
}

fn recoveryName(spec: []const u8) []const u8 {
    if (spec.len == 0) return "Untitled";
    const loc = paths.parseSpec(spec);
    const base = std.fs.path.basename(loc.path);
    return if (base.len == 0) spec else base;
}

/// "in the last hour" for the banner. Wall clock, because that is what
/// the record carries and what the user recognises.
fn agoText(now_ms: i64, updated_ms: i64) []const u8 {
    const delta = @max(0, now_ms - updated_ms);
    const mins = @divTrunc(delta, 60_000);
    if (mins < 1) return "moments ago";
    if (mins < 60) return "in the last hour";
    const hours = @divTrunc(mins, 60);
    if (hours < 24) return "earlier today";
    return "over a day ago";
}

fn onRecoverClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    recoverAll(cast.userData(EditorView, user));
}

/// Take the offer: open every offered buffer, still unsaved.
pub fn recoverAll(view: *EditorView) void {
    const entries = view.recovery;
    view.recovery = &.{};
    defer journal.freeEntries(view.allocator, entries);
    var opened: usize = 0;
    for (entries) |e| {
        if (recoverOne(view, e)) {
            opened += 1;
            // Its content now lives in a tab with its own fresh slot.
            journal.remove(view.allocator, e.key) catch {};
        }
        // A record we FAILED to open stays on disk: the failure may be a
        // transient one (fd exhaustion, a permission blip) and deleting
        // it would throw the work away for good. `prune` ages genuinely
        // abandoned records out.
    }
    updateBanner(view);
    var buf: [80:0]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Recovered {d} unsaved buffer(s).", .{opened}) catch "Recovered.";
    view.setStatusText(msg.ptr);
    // Show whether each file moved on since the crash, rather than
    // writing anything back: the ordinary probe compares the recovered
    // baseline and raises the ordinary banner.
    view.last_probe_ms = 0;
    view.checkDisk();
}

/// Build one tab from a record: the snapshot's bytes, its caret, its
/// line-ending style, still DIRTY, and the disk identity it was taken
/// against as the buffer's baseline.
fn recoverOne(view: *EditorView, entry: journal.Entry) bool {
    var rec = journal.read(view.allocator, entry.key) catch return false;
    defer rec.deinit(view.allocator);

    // Restore-vs-recover: the layout decides WHICH files are open, the
    // journal decides their CONTENT. A tab already holding this spec is
    // ADOPTED (its in-flight load orphaned) rather than duplicated, so
    // the two can never produce two tabs for one file whichever order
    // they run in — and the unsaved bytes win over the on-disk copy.
    const existing = if (rec.header.spec.len > 0) view.tabForSpec(rec.header.spec) else null;
    const tab = existing orelse view.newTab(null) orelse return false;
    if (existing != null and tab.io_gen != 0) {
        // The load it was waiting for will never be delivered to it now.
        tab.io_gen = 0;
        tab.loading = false;
        view.failDeferredEdits(tab.id, "the document was replaced by a recovered buffer");
    }
    if (existing == null and rec.header.spec.len > 0) {
        if (view.allocator.dupe(u8, rec.header.spec)) |s| {
            if (tab.spec) |old| view.allocator.free(old);
            tab.spec = s;
        } else |_| {}
    }
    // The snapshot is in-memory text and the header already carries its
    // style: sniffing it again would classify an LF buffer that holds
    // pasted CRLF lines as CRLF and strip every one of those CRs out of
    // the work being recovered.
    var new_doc = Document.initVerbatim(
        view.allocator,
        rec.content,
        if (rec.header.crlf) .crlf else .lf,
    ) catch return false;
    new_doc.markUnsaved();
    view.replaceDocument(tab, new_doc);
    if (view.lsp) |m| m.onDocumentReplaced(tab) else view.attachLsp(tab);
    tab.layout.invalidateAll();
    tab.rows_lines = 0;
    tab.anchor = .{};
    view.applyWrapWidth(tab);
    tab.disk = rec.header.baseline();
    tab.seen = tab.disk;
    const caret = @min(@as(usize, @intCast(rec.header.cursor)), tab.doc.rope.len());
    tab.sels.keepPrimaryOnly();
    tab.sels.sels.items[0] = Selection.caret(caret);
    view.refresh(tab);
    view.ensureCaretVisible(tab);
    // Immediately re-journal: a recovered buffer that is never touched
    // must survive a SECOND crash.
    _ = tick(view, tab);
    arm(view);
    return true;
}

fn onLaterClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    // Only the offer goes away. The records stay on disk and are offered
    // again next launch — declining must never destroy work.
    dropRecovery(view);
    updateBanner(view);
}

fn onDiscardClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    if (view.recovery.len == 0) return;
    var body: [160:0]u8 = undefined;
    const b = std.fmt.bufPrintZ(
        &body,
        "{d} unsaved buffer(s) from a previous session will be deleted. This cannot be undone.",
        .{view.recovery.len},
    ) catch "These unsaved buffers will be deleted.";
    const ctx = std.heap.c_allocator.create(ev.DlgCtx) catch return;
    view.fence.ref();
    ctx.* = .{ .fence = view.fence, .tab_id = 0 };
    if (confirm.present(view.dialogParent(), .{
        .heading = "Discard recovered work?",
        .body = b.ptr,
        .responses = &.{
            .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
            .{ .id = "discard", .label = "Discard", .appearance = .destructive },
        },
    }, .{ .allocator = view.allocator, .cb = &onDiscardResponse, .ctx = @ptrCast(ctx) }) == null) ctx.destroy();
}

fn onDiscardResponse(user: ?*anyopaque, resp: []const u8) void {
    const ctx: *ev.DlgCtx = @ptrCast(@alignCast(user.?));
    defer ctx.destroy();
    // tab_id 0 never resolves to a tab, so this one uses the fence
    // directly: the records are the view's, not a tab's.
    const view = ctx.fence.viewIfAlive() orelse return;
    if (!std.mem.eql(u8, resp, "discard")) return;
    for (view.recovery) |e| journal.remove(view.allocator, e.key) catch {};
    dropRecovery(view);
    updateBanner(view);
    view.setStatusText("Discarded the recovered snapshots.");
}

// ======================================================================
// Tests
// ======================================================================

test "editorjournal: the offer names buffers and says roughly when" {
    const t = std.testing;
    try t.expectEqualStrings("moments ago", agoText(100_000, 90_000));
    try t.expectEqualStrings("in the last hour", agoText(10 * 60_000, 0));
    try t.expectEqualStrings("earlier today", agoText(5 * 3_600_000, 0));
    try t.expectEqualStrings("over a day ago", agoText(30 * 3_600_000, 0));
    try t.expectEqualStrings("Untitled", recoveryName(""));
    try t.expectEqualStrings("main.zig", recoveryName("box:/src/main.zig"));
}
