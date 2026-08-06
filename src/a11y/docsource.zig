//! Editor-document `atspi.Source`: the rope through `docview.zig`.
//!
//! Resolves the ACTIVE document through a callback, so this file never
//! imports the editor (which imports the pane, which imports the
//! bridge). Byte<->character conversion is the rope's own O(log n)
//! aggregate descent (docview.byteToChar / charToByte), so no
//! conversion state lives here.
//!
//! Everything here reads `Document.rope`. Inlay hints, diagnostics
//! decorations, the caret's own glyph and every other display-only
//! overlay live in the layout/LSP layers and append no bytes to the
//! rope, so they are absent from the accessible text and shift no
//! accessible offset by construction — the accessible text is the
//! document, not the rendering.

const std = @import("std");
const c = @import("../c.zig").c;
const atspi = @import("atspi.zig");
const docview = @import("docview.zig");
const docmod = @import("../editor/document.zig");
const Document = docmod.Document;
const tr = @import("../editor/transaction.zig");

/// Per-canvas document source. Lives as a field of the editor face
/// (it must outlive the GL area) and is severed with it.
/// The zero value is inert (`get == null` answers every query with
/// "no document") and safe to `deinit`, so a face that dies before it
/// builds its widgets needs no separate guard.
pub const DocSource = struct {
    ctx: ?*anyopaque = null,
    /// Resolve the active document + selections; null when there is
    /// none (no tab open, or one still loading asynchronously).
    get: ?*const fn (ctx: *anyopaque) ?docview.Target = null,
    /// Exact edit ranges captured via Document observer slot 3 — what
    /// lets a change OUTSIDE the caret's diff region (reload,
    /// replace-all, format-on-save) still be announced precisely.
    /// Attach `editObserver()` to every document this canvas shows.
    log: docview.ChangeLog = .{},
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *anyopaque,
        get: *const fn (ctx: *anyopaque) ?docview.Target,
    ) DocSource {
        return .{
            .ctx = ctx,
            .get = get,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DocSource) void {
        _ = self;
    }

    /// The Document edit-observer hook feeding `log` (slot 3; see
    /// document.zig). Keyed on `ctx == self`, so re-attaching after a
    /// document swap replaces rather than double-registers.
    pub fn editObserver(self: *DocSource) docmod.EditObserver {
        return .{ .ctx = @ptrCast(self), .before_apply = onDocEdits };
    }

    /// Pending exact changes of the ACTIVE document, in character
    /// offsets, consumed on read. Null = nothing pending or the log
    /// cannot answer honestly (several transactions since the last
    /// take) — the caller must fall back to its region diff, never
    /// fabricate a range.
    pub fn takeChanges(self: *DocSource, out: []docview.CharChange) ?[]docview.CharChange {
        const get = self.get orelse return null;
        const t = get(self.ctx orelse return null) orelse return null;
        return self.log.take(t.doc, out);
    }

    pub fn source(self: *DocSource) atspi.Source {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }
};

/// Create an editor canvas: a SketermEditArea (role TEXT_BOX, editable,
/// multi-line) bound to `ds`.
pub fn newArea(ds: *DocSource, label: [*:0]const u8) *c.GtkWidget {
    return atspi.newArea(.text_box, ds.source(), label, ds.allocator);
}

const vtable: atspi.VTable = .{
    .contents = contents,
    .contentsAt = contentsAt,
    .caret = caret,
    .selections = selections,
    .region = region,
};

fn onDocEdits(ctx: *anyopaque, doc: *const Document, edits: []const tr.Edit) void {
    const ds: *DocSource = @ptrCast(@alignCast(ctx));
    ds.log.observe(doc, edits);
}

fn resolve(ctx: *anyopaque) ?struct { ds: *DocSource, t: docview.Target } {
    const ds: *DocSource = @ptrCast(@alignCast(ctx));
    const get = ds.get orelse return null;
    const t = get(ds.ctx orelse return null) orelse return null;
    return .{ .ds = ds, .t = t };
}

fn contents(ctx: *anyopaque, alloc: std.mem.Allocator, c0: u32, c1: u32) ?[]u8 {
    const r = resolve(ctx) orelse return null;
    return docview.contents(r.t, alloc, c0, c1) catch null;
}

fn contentsAt(ctx: *anyopaque, alloc: std.mem.Allocator, off: u32, gran: atspi.Gran) ?atspi.Chunk {
    const r = resolve(ctx) orelse return null;
    const range = switch (gran) {
        .character => docview.charRange(r.t, off),
        .word => docview.wordRange(r.t, alloc, off),
        .line => docview.lineRange(r.t, off),
    };
    const text = docview.contents(r.t, alloc, range.start, range.end) catch return null;
    return .{ .text = text, .start = range.start, .end = range.end };
}

fn caret(ctx: *anyopaque) u32 {
    const r = resolve(ctx) orelse return 0;
    return docview.caret(r.t);
}

fn selections(ctx: *anyopaque, alloc: std.mem.Allocator) []atspi.Range {
    const r = resolve(ctx) orelse return &.{};
    const ranges = docview.selections(r.t, alloc) catch return &.{};
    // docview.Range and atspi.Range are the same two u32 fields; the
    // duplication is the price of docview staying GTK-free.
    if (ranges.len == 0) return &.{};
    const out = alloc.alloc(atspi.Range, ranges.len) catch {
        alloc.free(ranges);
        return &.{};
    };
    for (ranges, 0..) |x, i| out[i] = .{ .start = x.start, .end = x.end };
    alloc.free(ranges);
    return out;
}

fn region(ctx: *anyopaque, alloc: std.mem.Allocator) ?atspi.Region {
    const r = resolve(ctx) orelse return null;
    const reg = (docview.region(r.t, alloc) catch return null) orelse return null;
    return .{ .text = reg.text, .char0 = reg.char0, .key = reg.key };
}
