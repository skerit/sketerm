//! GTK4 renderer for panel documents (`doc.zig`): the "panel face".
//!
//! Host contract (editorview.zig precedent — the face is the unit,
//! the host is a parameter):
//! - `PanelView.create` builds the widget tree; the HOST parents
//!   `root_box` (pane wrapper box, or a window's toolbar content) and
//!   owns when it is unparented/destroyed. The view OWNS a reference
//!   to `root_box` (g_object_ref_sink), so the pointer stays valid
//!   through any teardown order; `deinit` drops it.
//! - Pane hosting: a future `Pane.attachPanel` should mirror
//!   `Pane.attachEditor` exactly — pass `root_box`, `@ptrCast(view)`,
//!   and the exported `prepareDestroyCb`/`destroyCb`/`focusCb`
//!   trampolines, and add the panel face to `Pane.severFaces()`.
//! - Standalone hosting: parent `root_box` under the window content,
//!   call `prepareDestroy(true-ish)` from the window's ::destroy
//!   handler and `deinit` from a deferred finalize (editorwin.zig
//!   shows the shape). `on_changed` fires when the document title
//!   changes so the host can sync its title bar.
//! - `prepareDestroy` is IDEMPOTENT and safe from every teardown
//!   path; it closes the event queue (unblocking a pending
//!   ui_wait_event) and fences all further widget access. As a last
//!   resort the view also watches `root_box`'s ::destroy.
//! - Threading: everything here runs on the GTK main thread. The ONLY
//!   field other threads may touch is `queue` (see events.zig for the
//!   wait contract).
//!
//! Patching: `applyPatch` updates leaf widgets IN PLACE (label text,
//! slider value, progress fraction, image file, compare sides — the
//! compare keeps its zoom/pan/split across an image swap, which is
//! the epoch-by-epoch training loop working as intended). Structural
//! changes (children lists, root swap, removals, kind or class
//! changes) rebuild the affected tree wholesale — correctness first,
//! and a panel is bounded at 512 components.

const std = @import("std");
const c = @import("../../c.zig").c;
const Doc = @import("doc.zig");
const events = @import("events.zig");
const canary = @import("canary.zig");

const COMPARE_QDATA = "sketerm-panel-compare";

/// Per-class rendering: CSS class to add (null = handled as an
/// alignment/expansion flag in applyClasses). Order mirrors
/// Doc.CLASSES; classMask bit i corresponds to Doc.CLASSES[i].
const CLASS_CSS = [Doc.CLASSES.len]?[*:0]const u8{
    "dim-label", // dim
    "accent", // accent
    "success", // success
    "warning", // warning
    "error", // error
    "card", // card
    "monospace", // monospace
    null, // center
    null, // end
    null, // expand
};

fn classMask(classes: []const []u8) u16 {
    var mask: u16 = 0;
    for (classes) |cl| {
        for (Doc.CLASSES, 0..) |name, i| {
            if (std.mem.eql(u8, cl, name)) mask |= @as(u16, 1) << @intCast(i);
        }
    }
    return mask;
}

fn optionsHash(options: []const []u8) u64 {
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    for (options) |o| {
        h.update(o);
        h.update(&[_]u8{0});
    }
    return h.final();
}

pub const PanelView = struct {
    pub const MAGIC: u32 = 0x504E4C56; // "PNLV"
    /// Use-after-free DETECTOR, not a lifetime mechanism — see
    /// canary.zig. The disconnect in `deinit` is what makes the root
    /// ::destroy handler safe; this only makes a future regression in
    /// that reasoning fail loudly at the first stale callback.
    magic: u32 = MAGIC,
    allocator: std.mem.Allocator,
    doc: ?Doc.Document = null,
    queue: events.Queue,
    /// The widget the host parents. Vertical box holding the scroller.
    root_box: *c.GtkWidget,
    scroller: *c.GtkWidget,
    /// id -> live widget bookkeeping for in-place patching. Keys owned.
    built: std.StringHashMapUnmanaged(Built) = .empty,
    widgets_dead: bool = false,
    /// Set while the renderer itself writes widget values, so the
    /// resulting GTK signals do not echo back into the event queue.
    applying: bool = false,
    /// Title-changed hook for a standalone host's title bar.
    on_changed: ?*const fn (ctx: *anyopaque) void = null,
    changed_ctx: ?*anyopaque = null,
    /// Every live per-component signal context, so `deinit` can sever
    /// their back-pointer to this view. They are owned by GTK closures
    /// on widgets that can outlive the view (same reason as the root
    /// ::destroy fence in `deinit`), and a widget emits notifies while
    /// it is being disposed.
    contexts: std.ArrayListUnmanaged(*CompCtx) = .empty,

    const Built = struct {
        widget: *c.GtkWidget,
        kind: Doc.Kind,
        class_mask: u16 = 0,
        opt_hash: u64 = 0,
        picture: ?*c.GtkWidget = null,
        caption: ?*c.GtkWidget = null,
        compare: ?*Compare = null,
    };

    // ---- lifecycle ---------------------------------------------------

    pub fn create(allocator: std.mem.Allocator) !*PanelView {
        const self = try allocator.create(PanelView);
        errdefer allocator.destroy(self);
        const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0) orelse return error.OutOfMemory;
        const scroller = c.gtk_scrolled_window_new() orelse return error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .queue = events.Queue.init(),
            .root_box = root,
            .scroller = scroller,
        };
        // Own the face widget: whatever order the host tears down in,
        // this pointer stays a valid object until deinit's unref.
        _ = c.g_object_ref_sink(@ptrCast(root));
        c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_set_hexpand(scroller, 1);
        c.gtk_widget_set_vexpand(scroller, 1);
        c.gtk_box_append(@ptrCast(root), scroller);
        self.setPlaceholder();
        // Last-resort fence: a host that destroys the tree without
        // calling prepareDestroy first still may not leave callbacks
        // pointing at dead widgets. `self` is passed raw and unfenced,
        // which is only sound because `deinit` DISCONNECTS this handler
        // before freeing — see the note there; the widget can outlive
        // us, so the connection must not.
        _ = c.g_signal_connect_data(root, "destroy", @ptrCast(&onRootDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        return self;
    }

    /// Phase 1 of teardown (severFaces shape). Idempotent; safe from
    /// every path. `dead` is the host's verdict on whether the widget
    /// subtree is ALREADY gone, which is not what the fence keys on:
    /// every caller (panelhost's face trampoline, panelwin's ::destroy)
    /// is about to destroy the subtree, so the widgets are unusable
    /// either way and the fence goes up unconditionally. `dead` is kept
    /// in the signature because the host face contract passes it.
    pub fn prepareDestroy(self: *PanelView, dead: bool) void {
        _ = dead;
        self.widgets_dead = true;
        self.queue.close();
        self.on_changed = null;
    }

    /// Phase 2: free everything. Call after the destroy storm has
    /// unwound (idle-deferred in a standalone host; from the pane's
    /// deinit_cb in a pane host).
    pub fn deinit(self: *PanelView) void {
        self.queue.close();
        self.clearBuilt();
        if (self.doc) |*d| d.deinit();
        self.doc = null;
        // Sever the last-resort fence BEFORE dropping the reference.
        // Our ref keeps the widget alive, but it is not necessarily the
        // LAST one: on a pane face the host unparents the widget and GTK
        // (or, with an accessibility bus up, the AT context) can still
        // hold a reference, so the unref below need not dispose the
        // widget at all — its ::destroy then fires frames later, against
        // this freed struct. A GDestroyNotify would NOT fix that: it
        // runs when the closure dies, which is that same too-late
        // moment, and it cannot stop `onRootDestroy` from running first.
        // Disconnecting is the only thing that makes "no callback
        // outlives the struct" true. Nothing else connects with `self`
        // as data on this widget, so by-data is unambiguous.
        // The per-component contexts sit on DESCENDANT widgets and are
        // owned by their own GDestroyNotify, so they need not (and
        // cannot) be disconnected from here — but their `view` pointer
        // is about to dangle for exactly as long as those widgets
        // outlive us, and a GtkDropDown emits notify::selected from its
        // own dispose. Sever the back-pointer; the handlers then bail.
        for (self.contexts.items) |ctx| ctx.view = null;
        self.contexts.deinit(self.allocator);
        // (g_signal_handlers_disconnect_by_data is a macro the C-import
        // cannot type; this is its body, as in remotectl.zig.)
        _ = c.g_signal_handlers_disconnect_matched(
            @as(c.gpointer, @ptrCast(self.root_box)),
            c.G_SIGNAL_MATCH_DATA,
            0,
            0,
            null,
            null,
            @as(c.gpointer, @ptrCast(self)),
        );
        // Drops our owned reference; if the host already destroyed the
        // tree this finalizes the (destroyed) widget, otherwise it
        // destroys it now — or leaves it to whoever holds the last ref.
        c.g_object_unref(@ptrCast(self.root_box));
        canary.poison(self);
        self.allocator.destroy(self);
    }

    fn onRootDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = canary.live(PanelView, user) orelse return;
        self.widgets_dead = true;
        self.queue.close();
    }

    // ---- pane-face trampolines (signatures match Pane.attachEditor) --
    //
    // The host holds these as an opaque pointer across its own
    // teardown ordering, so they are exactly where a lifetime mistake
    // would land: check the canary before dereferencing.

    pub fn prepareDestroyCb(ctx: *anyopaque, widgets_dead: bool) void {
        const self = canary.live(PanelView, ctx) orelse return;
        self.prepareDestroy(widgets_dead);
    }

    pub fn destroyCb(ctx: *anyopaque) void {
        const self = canary.live(PanelView, ctx) orelse return;
        self.deinit();
    }

    pub fn focusCb(ctx: *anyopaque) void {
        const self = canary.live(PanelView, ctx) orelse return;
        self.focusFace();
    }

    pub fn focusFace(self: *PanelView) void {
        if (self.widgets_dead) return;
        _ = c.gtk_widget_grab_focus(self.scroller);
    }

    // ---- document API ------------------------------------------------

    /// Replace the whole document (full widget rebuild). On error the
    /// previous document and widgets stay untouched.
    pub fn setDocument(self: *PanelView, json_text: []const u8, diag: ?*Doc.Diag) Doc.Error!void {
        var fresh = try Doc.Document.parse(self.allocator, json_text, diag);
        if (self.doc) |*old| {
            fresh.revision = old.revision + 1;
            old.deinit();
        }
        self.doc = fresh;
        if (!self.widgets_dead) {
            self.applying = true;
            defer self.applying = false;
            self.rebuildAll();
        }
        self.notifyChanged();
    }

    /// Apply a patch (doc.zig op array). Transactional at the document
    /// level; widget updates are in-place where the change is a leaf
    /// property, wholesale otherwise.
    pub fn applyPatch(self: *PanelView, json_text: []const u8, diag: ?*Doc.Diag) Doc.Error!void {
        if (self.doc == null) {
            if (diag) |d| d.set("no document to patch (setDocument first)", .{});
            return Doc.Error.Malformed;
        }
        var applied = try self.doc.?.applyPatch(json_text, diag);
        defer applied.deinit();
        if (!self.widgets_dead) {
            self.applying = true;
            defer self.applying = false;
            var rebuild = applied.root_changed or applied.removed.len > 0;
            if (!rebuild) {
                for (applied.set) |id| {
                    if (!self.updateOne(id)) {
                        rebuild = true;
                        break;
                    }
                }
            }
            if (rebuild) self.rebuildAll();
        }
        if (applied.title_changed) self.notifyChanged();
    }

    /// The live document in `Document.toJson`'s canonical form (sorted
    /// keys, fixed field order), or null when none was ever set. Caller
    /// frees. This is the read-back `panel-get` serves, so a panel is
    /// persistable by any process, not only the one that showed it.
    pub fn documentJson(self: *const PanelView, allocator: std.mem.Allocator) Doc.Error!?[]u8 {
        if (self.doc) |*d| return try d.toJson(allocator);
        return null;
    }

    pub fn title(self: *const PanelView) []const u8 {
        const d = &(self.doc orelse return "");
        return d.title;
    }

    fn notifyChanged(self: *PanelView) void {
        if (self.on_changed) |cb| {
            if (self.changed_ctx) |ctx| cb(ctx);
        }
    }

    // ---- building ----------------------------------------------------

    fn setPlaceholder(self: *PanelView) void {
        const label = c.gtk_label_new("No panel content yet").?;
        c.gtk_widget_add_css_class(label, "dim-label");
        c.gtk_widget_set_halign(label, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_valign(label, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_vexpand(label, 1);
        c.gtk_scrolled_window_set_child(@ptrCast(self.scroller), label);
    }

    fn clearBuilt(self: *PanelView) void {
        var it = self.built.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.built.deinit(self.allocator);
        self.built = .empty;
    }

    fn rebuildAll(self: *PanelView) void {
        self.clearBuilt();
        if (self.widgets_dead) return;
        const d = &(self.doc orelse {
            self.setPlaceholder();
            return;
        });
        const content = self.buildComponent(d.root, 0, true);
        c.gtk_widget_set_margin_start(content, 12);
        c.gtk_widget_set_margin_end(content, 12);
        c.gtk_widget_set_margin_top(content, 12);
        c.gtk_widget_set_margin_bottom(content, 12);
        // Replaces (and thereby destroys) the previous content tree.
        c.gtk_scrolled_window_set_child(@ptrCast(self.scroller), content);
    }

    fn errorLabel(text: [*:0]const u8) *c.GtkWidget {
        const label = c.gtk_label_new(text).?;
        c.gtk_widget_add_css_class(label, "error");
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        return label;
    }

    /// Build the widget for `id` and register it (recursively for
    /// containers). `vertical` is the parent container's orientation —
    /// separators and spacers orient against it.
    fn buildComponent(self: *PanelView, id: []const u8, depth: usize, vertical: bool) *c.GtkWidget {
        if (depth > Doc.MAX_DEPTH) return errorLabel("panel: tree too deep");
        const d = &self.doc.?;
        const comp = d.get(id) orelse return errorLabel("panel: missing component");
        var built = Built{ .widget = undefined, .kind = comp.kind(), .class_mask = classMask(comp.classes) };

        const widget: *c.GtkWidget = switch (comp.props) {
            .column, .row => |cont| blk: {
                const is_col = comp.kind() == .column;
                const box = c.gtk_box_new(if (is_col) c.GTK_ORIENTATION_VERTICAL else c.GTK_ORIENTATION_HORIZONTAL, 8).?;
                for (cont.children) |child| {
                    c.gtk_box_append(@ptrCast(box), self.buildComponent(child, depth + 1, is_col));
                }
                break :blk box;
            },
            .heading => |h| blk: {
                const label = self.textLabel(h.text);
                c.gtk_widget_add_css_class(label, headingClass(h.level));
                break :blk label;
            },
            .text => |txt| blk: {
                const label = self.textLabel(txt.text);
                c.gtk_label_set_selectable(@ptrCast(label), 1);
                break :blk label;
            },
            .image => |img| blk: {
                const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4).?;
                const pic = c.gtk_picture_new().?;
                c.gtk_picture_set_content_fit(@ptrCast(pic), c.GTK_CONTENT_FIT_CONTAIN);
                c.gtk_picture_set_can_shrink(@ptrCast(pic), 1);
                c.gtk_widget_set_size_request(pic, -1, 120);
                c.gtk_widget_set_hexpand(pic, 1);
                const cap = c.gtk_label_new(null).?;
                c.gtk_widget_add_css_class(cap, "dim-label");
                c.gtk_widget_add_css_class(cap, "caption");
                c.gtk_label_set_wrap(@ptrCast(cap), 1);
                c.gtk_box_append(@ptrCast(box), pic);
                c.gtk_box_append(@ptrCast(box), cap);
                built.picture = pic;
                built.caption = cap;
                self.setImageWidgets(pic, cap, img);
                break :blk box;
            },
            .image_compare => |ic| blk: {
                const area = c.gtk_drawing_area_new().?;
                c.gtk_widget_set_hexpand(area, 1);
                c.gtk_widget_set_vexpand(area, 1);
                c.gtk_widget_set_size_request(area, -1, 280);
                const cmp = Compare.create(self.allocator, area, ic) catch
                    break :blk errorLabel("panel: out of memory");
                built.compare = cmp;
                break :blk area;
            },
            .button => |b| blk: {
                var zbuf: [Doc.MAX_TEXT + 1]u8 = undefined;
                const button = c.gtk_button_new_with_label(zOf(&zbuf, b.text)).?;
                c.gtk_widget_set_halign(button, c.GTK_ALIGN_START);
                self.connectComp(button, "clicked", @ptrCast(&onButtonClicked), id);
                break :blk button;
            },
            .slider => |s| blk: {
                const scale = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, s.min, s.max, s.step).?;
                c.gtk_range_set_value(@ptrCast(scale), s.value);
                c.gtk_scale_set_draw_value(@ptrCast(scale), 1);
                c.gtk_widget_set_hexpand(scale, 1);
                c.gtk_widget_set_size_request(scale, 160, -1);
                self.connectComp(scale, "value-changed", @ptrCast(&onSliderChanged), id);
                break :blk scale;
            },
            .select => |s| blk: {
                built.opt_hash = optionsHash(s.options);
                const dd = self.buildDropDown(s) orelse break :blk errorLabel("panel: out of memory");
                self.connectComp(dd, "notify::selected", @ptrCast(&onSelectChanged), id);
                break :blk dd;
            },
            .progress => |p| blk: {
                const bar = c.gtk_progress_bar_new().?;
                c.gtk_widget_set_hexpand(bar, 1);
                c.gtk_widget_set_valign(bar, c.GTK_ALIGN_CENTER);
                setProgress(bar, p);
                break :blk bar;
            },
            .separator => c.gtk_separator_new(if (vertical) c.GTK_ORIENTATION_HORIZONTAL else c.GTK_ORIENTATION_VERTICAL).?,
            .spacer => |sp| blk: {
                const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0).?;
                if (sp.size > 0) {
                    if (vertical)
                        c.gtk_widget_set_size_request(box, -1, sp.size)
                    else
                        c.gtk_widget_set_size_request(box, sp.size, -1);
                } else {
                    if (vertical) c.gtk_widget_set_vexpand(box, 1) else c.gtk_widget_set_hexpand(box, 1);
                }
                break :blk box;
            },
        };

        built.widget = widget;
        applyClasses(widget, comp.classes);
        self.registerBuilt(id, built);
        return widget;
    }

    fn textLabel(self: *PanelView, text: []const u8) *c.GtkWidget {
        _ = self;
        const label = c.gtk_label_new(null).?;
        setLabelText(label, text);
        c.gtk_label_set_wrap(@ptrCast(label), 1);
        c.gtk_label_set_wrap_mode(@ptrCast(label), c.PANGO_WRAP_WORD_CHAR);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_widget_set_halign(label, c.GTK_ALIGN_FILL);
        c.gtk_widget_set_hexpand(label, 1);
        return label;
    }

    fn buildDropDown(self: *PanelView, s: Doc.Props.Select) ?*c.GtkWidget {
        const a = self.allocator;
        const n = s.options.len;
        const arr = a.alloc([*c]const u8, n + 1) catch return null;
        defer a.free(arr);
        var owned: usize = 0;
        defer for (arr[0..owned]) |p| a.free(std.mem.span(@as([*:0]const u8, @ptrCast(p))));
        for (s.options, 0..) |o, i| {
            const z = a.dupeZ(u8, o) catch return null;
            arr[i] = z.ptr;
            owned += 1;
        }
        arr[n] = null;
        const dd = c.gtk_drop_down_new_from_strings(arr.ptr) orelse return null;
        c.gtk_widget_set_halign(dd, c.GTK_ALIGN_START);
        c.gtk_drop_down_set_selected(@ptrCast(dd), selectedIndex(s));
        return dd;
    }

    fn registerBuilt(self: *PanelView, id: []const u8, built: Built) void {
        if (self.built.getPtr(id)) |existing| {
            existing.* = built;
            return;
        }
        const key = self.allocator.dupe(u8, id) catch return;
        self.built.put(self.allocator, key, built) catch {
            self.allocator.free(key);
        };
    }

    fn setImageWidgets(self: *PanelView, pic: *c.GtkWidget, cap: *c.GtkWidget, img: Doc.Props.Image) void {
        const a = self.allocator;
        const pathz = a.dupeZ(u8, img.src) catch return;
        defer a.free(pathz);
        const readable = c.access(pathz.ptr, c.R_OK) == 0;
        c.gtk_picture_set_filename(@ptrCast(pic), if (readable) pathz.ptr else null);
        if (!readable) {
            var buf: [Doc.MAX_PATH + 32]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "cannot read: {s}", .{img.src}) catch "cannot read image";
            c.gtk_label_set_text(@ptrCast(cap), msg.ptr);
            c.gtk_widget_add_css_class(cap, "error");
            c.gtk_widget_set_visible(cap, 1);
            return;
        }
        c.gtk_widget_remove_css_class(cap, "error");
        if (img.caption.len > 0) {
            setLabelText(cap, img.caption);
            c.gtk_widget_set_visible(cap, 1);
        } else {
            c.gtk_widget_set_visible(cap, 0);
        }
    }

    // ---- incremental patching ----------------------------------------

    /// @return false when this change needs the full rebuild.
    fn updateOne(self: *PanelView, id: []const u8) bool {
        const d = &self.doc.?;
        const comp = d.get(id) orelse return true; // set then removed in one patch
        const entry = self.built.getPtr(id) orelse {
            // Newly added component: no widget yet. Only a problem if
            // it is now reachable (some container must also have been
            // set to mount it, which forces the rebuild by itself) —
            // a staged orphan needs nothing.
            return !self.isReachable(id);
        };
        if (entry.kind != comp.kind()) return self.swapOne(id, entry.*);
        if (comp.kind().isContainer()) return false;
        if (entry.class_mask != classMask(comp.classes)) return self.swapOne(id, entry.*);
        switch (comp.props) {
            .column, .row => unreachable,
            .heading => |h| {
                setLabelText(entry.widget, h.text);
                for (1..5) |lvl| c.gtk_widget_remove_css_class(entry.widget, headingClass(@intCast(lvl)));
                c.gtk_widget_add_css_class(entry.widget, headingClass(h.level));
            },
            .text => |txt| setLabelText(entry.widget, txt.text),
            .image => |img| {
                const pic = entry.picture orelse return false;
                const cap = entry.caption orelse return false;
                self.setImageWidgets(pic, cap, img);
            },
            .image_compare => |ic| {
                const cmp = entry.compare orelse return false;
                cmp.setSides(ic);
            },
            .button => |b| {
                var zbuf: [Doc.MAX_TEXT + 1]u8 = undefined;
                c.gtk_button_set_label(@ptrCast(entry.widget), zOf(&zbuf, b.text));
            },
            .slider => |s| {
                c.gtk_range_set_range(@ptrCast(entry.widget), s.min, s.max);
                c.gtk_range_set_increments(@ptrCast(entry.widget), s.step, s.step * 10);
                c.gtk_range_set_value(@ptrCast(entry.widget), s.value);
            },
            .select => |s| {
                if (entry.opt_hash != optionsHash(s.options)) return self.swapOne(id, entry.*);
                c.gtk_drop_down_set_selected(@ptrCast(entry.widget), selectedIndex(s));
            },
            .progress => |p| setProgress(entry.widget, p),
            .separator => {},
            .spacer => return self.swapOne(id, entry.*),
        }
        return true;
    }

    /// Rebuild one leaf's widget subtree and splice it in place.
    /// @return false when splicing is not possible (root, or the
    /// parent is not a plain box) and the caller must rebuild.
    fn swapOne(self: *PanelView, id: []const u8, entry: Built) bool {
        const d = &self.doc.?;
        if (std.mem.eql(u8, id, d.root)) return false;
        const comp = d.get(id) orelse return false;
        if (comp.kind().isContainer() or entry.kind.isContainer()) return false;
        const old = entry.widget;
        const parent = c.gtk_widget_get_parent(old) orelse return false;
        // By construction every non-root component widget lives in a
        // container's GtkBox.
        const vertical = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(parent))) == c.GTK_ORIENTATION_VERTICAL;
        const fresh = self.buildComponent(id, 1, vertical);
        c.gtk_box_insert_child_after(@ptrCast(parent), fresh, old);
        c.gtk_box_remove(@ptrCast(parent), old);
        return true;
    }

    fn isReachable(self: *PanelView, id: []const u8) bool {
        const d = &self.doc.?;
        return reachFrom(d, d.root, id, 0);
    }

    fn reachFrom(d: *const Doc.Document, cur: []const u8, id: []const u8, depth: usize) bool {
        if (depth > Doc.MAX_DEPTH) return false;
        if (std.mem.eql(u8, cur, id)) return true;
        const comp = d.get(cur) orelse return false;
        switch (comp.props) {
            .column, .row => |cont| for (cont.children) |child| {
                if (reachFrom(d, child, id, depth + 1)) return true;
            },
            else => {},
        }
        return false;
    }

    // ---- signal plumbing ---------------------------------------------

    /// Heap context + owning-allocator + GDestroyNotify, per the
    /// memory-ownership rule (menu.zig/prefs.zig pattern). `view` is
    /// null once the view has been freed under a widget that outlived
    /// it — the context itself lives on until GTK drops the closure.
    const CompCtx = struct {
        pub const MAGIC: u32 = 0x434D5043; // "CMPC"
        /// Detector only (canary.zig): the GDestroyNotify below is
        /// what actually owns this allocation.
        magic: u32 = @This().MAGIC,
        allocator: std.mem.Allocator,
        view: ?*PanelView,
        id: []u8,
    };

    fn connectComp(
        self: *PanelView,
        widget: *c.GtkWidget,
        signal: [*:0]const u8,
        handler: c.GCallback,
        id: []const u8,
    ) void {
        const ctx = self.allocator.create(CompCtx) catch return;
        ctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .id = self.allocator.dupe(u8, id) catch {
                self.allocator.destroy(ctx);
                return;
            },
        };
        // Registered BEFORE connecting: a context the view cannot reach
        // is a context whose back-pointer it cannot sever.
        self.contexts.append(self.allocator, ctx) catch {
            self.allocator.free(ctx.id);
            self.allocator.destroy(ctx);
            return;
        };
        _ = c.g_signal_connect_data(widget, signal, handler, @ptrCast(ctx), @ptrCast(&freeCompCtx), c.G_CONNECT_DEFAULT);
    }

    /// Drop a context from the registry (its widget died first, which
    /// is the ordinary case: every rebuild destroys the old tree).
    fn forgetCtx(self: *PanelView, ctx: *CompCtx) void {
        for (self.contexts.items, 0..) |other, i| {
            if (other == ctx) {
                _ = self.contexts.swapRemove(i);
                return;
            }
        }
    }

    fn freeCompCtx(user: ?*anyopaque) callconv(.c) void {
        // Guarded like the handlers: a second closure destruction on
        // the same context leaks it instead of double-freeing.
        const ctx = canary.live(CompCtx, user) orelse return;
        // A null view means the view is already gone and took the
        // registry with it.
        if (ctx.view) |view| view.forgetCtx(ctx);
        ctx.allocator.free(ctx.id);
        canary.poison(ctx);
        ctx.allocator.destroy(ctx);
    }

    fn onButtonClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx = canary.live(CompCtx, user) orelse return;
        const view = ctx.view orelse return;
        if (view.widgets_dead or view.applying) return;
        const d = &(view.doc orelse return);
        const comp = d.get(ctx.id) orelse return;
        if (comp.kind() != .button) return;
        const action = comp.props.button.action;
        const value: events.Value = if (action.len > 0) events.Value.fromText(action) else .none;
        view.queue.push(events.Event.init(ctx.id, .click, value));
    }

    fn onSliderChanged(range: *c.GtkRange, user: ?*anyopaque) callconv(.c) void {
        const ctx = canary.live(CompCtx, user) orelse return;
        const view = ctx.view orelse return;
        if (view.widgets_dead or view.applying) return;
        const v = c.gtk_range_get_value(range);
        view.queue.push(events.Event.init(ctx.id, .change, .{ .number = v }));
    }

    fn onSelectChanged(obj: [*c]c.GObject, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const ctx = canary.live(CompCtx, user) orelse return;
        const view = ctx.view orelse return;
        if (view.widgets_dead or view.applying) return;
        const d = &(view.doc orelse return);
        const comp = d.get(ctx.id) orelse return;
        if (comp.kind() != .select) return;
        const idx = c.gtk_drop_down_get_selected(@ptrCast(@alignCast(obj)));
        const options = comp.props.select.options;
        if (idx == c.GTK_INVALID_LIST_POSITION or idx >= options.len) return;
        view.queue.push(events.Event.init(ctx.id, .change, events.Value.fromText(options[idx])));
    }
};

// ─── shared widget helpers ──────────────────────────────────────

fn headingClass(level: u8) [*:0]const u8 {
    return switch (level) {
        1 => "title-1",
        2 => "title-2",
        3 => "title-3",
        else => "title-4",
    };
}

fn setLabelText(label: *c.GtkWidget, text: []const u8) void {
    var zbuf: [Doc.MAX_TEXT + 1]u8 = undefined;
    c.gtk_label_set_text(@ptrCast(label), zOf(&zbuf, text));
}

/// Bounded stack null-termination (doc.zig caps every text at
/// MAX_TEXT, so the buffer always fits).
fn zOf(buf: *[Doc.MAX_TEXT + 1]u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, Doc.MAX_TEXT);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf);
}

fn setProgress(bar: *c.GtkWidget, p: Doc.Props.Progress) void {
    if (p.indeterminate) {
        // One pulse per update: the moving block advances with each
        // patch. (A self-running animation would need a timer this
        // component does not carry; agents that want motion patch the
        // bar, which is also what keeps it honest.)
        c.gtk_progress_bar_pulse(@ptrCast(bar));
    } else {
        c.gtk_progress_bar_set_fraction(@ptrCast(bar), p.value);
    }
    if (p.label.len > 0) {
        var zbuf: [Doc.MAX_TEXT + 1]u8 = undefined;
        c.gtk_progress_bar_set_text(@ptrCast(bar), zOf(&zbuf, p.label));
        c.gtk_progress_bar_set_show_text(@ptrCast(bar), 1);
    } else {
        c.gtk_progress_bar_set_show_text(@ptrCast(bar), 0);
    }
}

fn selectedIndex(s: Doc.Props.Select) c_uint {
    for (s.options, 0..) |o, i| {
        if (std.mem.eql(u8, o, s.value)) return @intCast(i);
    }
    return 0;
}

fn applyClasses(widget: *c.GtkWidget, classes: []const []u8) void {
    for (classes) |cl| {
        for (Doc.CLASSES, 0..) |name, i| {
            if (!std.mem.eql(u8, cl, name)) continue;
            if (CLASS_CSS[i]) |css| {
                c.gtk_widget_add_css_class(widget, css);
            } else if (std.mem.eql(u8, name, "center")) {
                c.gtk_widget_set_halign(widget, c.GTK_ALIGN_CENTER);
            } else if (std.mem.eql(u8, name, "end")) {
                c.gtk_widget_set_halign(widget, c.GTK_ALIGN_END);
            } else if (std.mem.eql(u8, name, "expand")) {
                c.gtk_widget_set_halign(widget, c.GTK_ALIGN_FILL);
                c.gtk_widget_set_hexpand(widget, 1);
                c.gtk_widget_set_vexpand(widget, 1);
            }
        }
    }
}

// ─── image_compare ──────────────────────────────────────────────
//
// One drawing area, both images drawn through the SAME transform
// (contain-fit * zoom, plus pan), left clipped to the split. Drag on
// the split line moves it; drag elsewhere pans when zoomed (or jumps
// the split when not); scroll zooms about the pointer; double-click
// resets zoom/pan. NEAREST filtering kicks in past 3x effective
// scale so pixel-peeping shows pixels, not mush.

const Compare = struct {
    pub const MAGIC: u32 = 0x434D5052; // "CMPR"
    /// Detector only (canary.zig): the qdata destroy-notify owns this
    /// allocation, and the four gesture controllers below borrow the
    /// pointer with no notify of their own — which is precisely the
    /// arrangement that goes wrong if the qdata ever stops being the
    /// single free path.
    magic: u32 = MAGIC,
    allocator: std.mem.Allocator,
    area: *c.GtkWidget,
    left_pix: ?*c.GdkPixbuf = null,
    right_pix: ?*c.GdkPixbuf = null,
    left_path: [:0]u8,
    right_path: [:0]u8,
    left_label: [:0]u8,
    right_label: [:0]u8,
    split: f64 = 0.5,
    zoom: f64 = 1.0,
    pan_x: f64 = 0,
    pan_y: f64 = 0,
    // Interaction state.
    drag: enum { none, split, pan } = .none,
    split0: f64 = 0.5,
    pan_x0: f64 = 0,
    pan_y0: f64 = 0,
    mouse_x: f64 = 0,
    mouse_y: f64 = 0,

    const SPLIT_GRAB_PX: f64 = 16;
    const MAX_ZOOM: f64 = 32;

    fn create(allocator: std.mem.Allocator, area: *c.GtkWidget, ic: Doc.Props.ImageCompare) !*Compare {
        const self = try allocator.create(Compare);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .area = area,
            .left_path = try allocator.dupeZ(u8, ""),
            .right_path = try allocator.dupeZ(u8, ""),
            .left_label = try allocator.dupeZ(u8, ""),
            .right_label = try allocator.dupeZ(u8, ""),
        };
        // Ownership: the qdata destroy-notify is the single free path,
        // running at widget dispose; the gestures below borrow the
        // pointer without their own notify.
        c.g_object_set_data_full(@ptrCast(area), COMPARE_QDATA, @ptrCast(self), @ptrCast(&freeCompare));
        c.gtk_drawing_area_set_draw_func(@ptrCast(area), @ptrCast(&drawCb), @ptrCast(self), null);

        const drag = c.gtk_gesture_drag_new().?;
        _ = c.g_signal_connect_data(drag, "drag-begin", @ptrCast(&onDragBegin), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drag, "drag-update", @ptrCast(&onDragUpdate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drag, "drag-end", @ptrCast(&onDragEnd), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area, @ptrCast(@alignCast(drag)));

        const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_VERTICAL).?;
        _ = c.g_signal_connect_data(scroll, "scroll", @ptrCast(&onScroll), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area, @ptrCast(@alignCast(scroll)));

        const motion = c.gtk_event_controller_motion_new().?;
        _ = c.g_signal_connect_data(motion, "motion", @ptrCast(&onMotion), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area, @ptrCast(@alignCast(motion)));

        const click = c.gtk_gesture_click_new().?;
        _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area, @ptrCast(@alignCast(click)));

        self.setSides(ic);
        return self;
    }

    fn freeCompare(user: ?*anyopaque) callconv(.c) void {
        if (canary.live(Compare, user)) |self| {
            if (self.left_pix) |p| c.g_object_unref(@ptrCast(p));
            if (self.right_pix) |p| c.g_object_unref(@ptrCast(p));
            self.allocator.free(self.left_path);
            self.allocator.free(self.right_path);
            self.allocator.free(self.left_label);
            self.allocator.free(self.right_label);
            canary.poison(self);
            self.allocator.destroy(self);
        }
    }

    /// (Re)load both sides. Zoom/pan/split are deliberately KEPT: a
    /// training loop patching in the next epoch's frames while the
    /// user is zoomed onto an artifact must not reset the viewport.
    fn setSides(self: *Compare, ic: Doc.Props.ImageCompare) void {
        self.loadSide(&self.left_pix, &self.left_path, &self.left_label, ic.left);
        self.loadSide(&self.right_pix, &self.right_path, &self.right_label, ic.right);
        c.gtk_widget_queue_draw(self.area);
    }

    fn loadSide(self: *Compare, pix: *?*c.GdkPixbuf, path: *[:0]u8, label: *[:0]u8, side: Doc.Side) void {
        const a = self.allocator;
        if (a.dupeZ(u8, side.label)) |lz| {
            a.free(label.*);
            label.* = lz;
        } else |_| {}
        if (!std.mem.eql(u8, path.*, side.src)) {
            if (a.dupeZ(u8, side.src)) |pz| {
                a.free(path.*);
                path.* = pz;
            } else |_| return;
        }
        // ALWAYS reload, even for an unchanged path: the training-loop
        // pattern overwrites the same file each epoch and re-sets the
        // component to say "look again".
        if (pix.*) |old| c.g_object_unref(@ptrCast(old));
        pix.* = c.gdk_pixbuf_new_from_file(path.*.ptr, null);
    }

    // ---- drawing -----------------------------------------------------

    fn baseScale(self: *const Compare, w: f64, h: f64) ?struct { iw: f64, ih: f64, es: f64 } {
        const pix = self.right_pix orelse self.left_pix orelse return null;
        const iw: f64 = @floatFromInt(c.gdk_pixbuf_get_width(pix));
        const ih: f64 = @floatFromInt(c.gdk_pixbuf_get_height(pix));
        if (iw <= 0 or ih <= 0) return null;
        const s0 = @min(w / iw, h / ih);
        return .{ .iw = iw, .ih = ih, .es = s0 * self.zoom };
    }

    fn drawCb(_: ?*c.GtkDrawingArea, cr: ?*c.cairo_t, wi: c_int, hi: c_int, user: ?*anyopaque) callconv(.c) void {
        const self = canary.live(Compare, user) orelse return;
        const ctx = cr orelse return;
        const w: f64 = @floatFromInt(wi);
        const h: f64 = @floatFromInt(hi);
        c.cairo_set_source_rgb(ctx, 0.10, 0.10, 0.11);
        c.cairo_paint(ctx);

        const base = self.baseScale(w, h) orelse {
            self.drawMessage(ctx, w, h, "no image could be loaded");
            return;
        };
        const split_x = std.math.clamp(self.split, 0, 1) * w;

        self.drawSide(ctx, self.left_pix, base.es, w, h, 0, split_x, self.left_path);
        self.drawSide(ctx, self.right_pix, base.es, w, h, split_x, w - split_x, self.right_path);

        // Split line + handle.
        c.cairo_set_source_rgba(ctx, 0, 0, 0, 0.5);
        c.cairo_set_line_width(ctx, 3);
        c.cairo_move_to(ctx, split_x, 0);
        c.cairo_line_to(ctx, split_x, h);
        c.cairo_stroke(ctx);
        c.cairo_set_source_rgba(ctx, 1, 1, 1, 0.9);
        c.cairo_set_line_width(ctx, 1);
        c.cairo_move_to(ctx, split_x, 0);
        c.cairo_line_to(ctx, split_x, h);
        c.cairo_stroke(ctx);
        c.cairo_arc(ctx, split_x, h / 2, 11, 0, std.math.tau);
        c.cairo_set_source_rgba(ctx, 1, 1, 1, 0.9);
        c.cairo_fill(ctx);
        c.cairo_set_source_rgba(ctx, 0, 0, 0, 0.8);
        // Two small arrows in the handle.
        c.cairo_move_to(ctx, split_x - 3, h / 2 - 4);
        c.cairo_line_to(ctx, split_x - 7, h / 2);
        c.cairo_line_to(ctx, split_x - 3, h / 2 + 4);
        c.cairo_fill(ctx);
        c.cairo_move_to(ctx, split_x + 3, h / 2 - 4);
        c.cairo_line_to(ctx, split_x + 7, h / 2);
        c.cairo_line_to(ctx, split_x + 3, h / 2 + 4);
        c.cairo_fill(ctx);

        // Corner labels.
        if (self.left_label.len > 0) self.drawLabel(ctx, self.left_label, 8, false, w);
        if (self.right_label.len > 0) self.drawLabel(ctx, self.right_label, 8, true, w);

        // Zoom badge (only when zoomed).
        if (self.zoom > 1.001) {
            var zb: [24]u8 = undefined;
            const zs = std.fmt.bufPrintZ(&zb, "{d:.1}x", .{self.zoom}) catch return;
            self.drawBadge(ctx, zs, w / 2, 8);
        }
    }

    fn drawSide(
        self: *const Compare,
        ctx: *c.cairo_t,
        pix_o: ?*c.GdkPixbuf,
        es: f64,
        w: f64,
        h: f64,
        clip_x: f64,
        clip_w: f64,
        path: [:0]const u8,
    ) void {
        if (clip_w <= 0) return;
        c.cairo_save(ctx);
        defer c.cairo_restore(ctx);
        c.cairo_rectangle(ctx, clip_x, 0, clip_w, h);
        c.cairo_clip(ctx);
        const pix = pix_o orelse {
            c.cairo_set_source_rgb(ctx, 0.2, 0.12, 0.12);
            c.cairo_paint(ctx);
            var buf: [Doc.MAX_PATH + 24]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "cannot load {s}", .{path}) catch "cannot load image";
            c.cairo_select_font_face(ctx, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
            c.cairo_set_font_size(ctx, 12);
            c.cairo_set_source_rgba(ctx, 1, 0.75, 0.75, 0.9);
            c.cairo_move_to(ctx, clip_x + 10, h / 2);
            c.cairo_show_text(ctx, msg.ptr);
            return;
        };
        const iw: f64 = @floatFromInt(c.gdk_pixbuf_get_width(pix));
        const ih: f64 = @floatFromInt(c.gdk_pixbuf_get_height(pix));
        c.cairo_translate(ctx, w / 2 + self.pan_x, h / 2 + self.pan_y);
        c.cairo_scale(ctx, es, es);
        c.gdk_cairo_set_source_pixbuf(ctx, pix, -iw / 2, -ih / 2);
        c.cairo_pattern_set_filter(
            c.cairo_get_source(ctx),
            if (es >= 3.0) c.CAIRO_FILTER_NEAREST else c.CAIRO_FILTER_GOOD,
        );
        c.cairo_paint(ctx);
    }

    fn drawMessage(_: *const Compare, ctx: *c.cairo_t, w: f64, h: f64, msg: [*:0]const u8) void {
        c.cairo_select_font_face(ctx, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(ctx, 13);
        var ext: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(ctx, msg, &ext);
        c.cairo_set_source_rgba(ctx, 1, 1, 1, 0.6);
        c.cairo_move_to(ctx, (w - ext.width) / 2, h / 2);
        c.cairo_show_text(ctx, msg);
    }

    fn drawLabel(_: *const Compare, ctx: *c.cairo_t, label: [:0]const u8, y: f64, right: bool, w: f64) void {
        c.cairo_select_font_face(ctx, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(ctx, 12);
        var ext: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(ctx, label.ptr, &ext);
        const pad: f64 = 6;
        const bw = ext.width + pad * 2;
        const bh = ext.height + pad * 2;
        const x: f64 = if (right) w - 8 - bw else 8;
        c.cairo_set_source_rgba(ctx, 0, 0, 0, 0.55);
        c.cairo_rectangle(ctx, x, y, bw, bh);
        c.cairo_fill(ctx);
        c.cairo_set_source_rgba(ctx, 1, 1, 1, 0.95);
        c.cairo_move_to(ctx, x + pad - ext.x_bearing, y + pad - ext.y_bearing);
        c.cairo_show_text(ctx, label.ptr);
    }

    fn drawBadge(self: *const Compare, ctx: *c.cairo_t, text: [:0]const u8, cx: f64, y: f64) void {
        _ = self;
        c.cairo_select_font_face(ctx, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(ctx, 11);
        var ext: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(ctx, text.ptr, &ext);
        const pad: f64 = 5;
        const bw = ext.width + pad * 2;
        const bh = ext.height + pad * 2;
        const x = cx - bw / 2;
        c.cairo_set_source_rgba(ctx, 0, 0, 0, 0.55);
        c.cairo_rectangle(ctx, x, y, bw, bh);
        c.cairo_fill(ctx);
        c.cairo_set_source_rgba(ctx, 1, 1, 1, 0.95);
        c.cairo_move_to(ctx, x + pad - ext.x_bearing, y + pad - ext.y_bearing);
        c.cairo_show_text(ctx, text.ptr);
    }

    // ---- interaction -------------------------------------------------

    fn widgetW(self: *const Compare) f64 {
        return @floatFromInt(@max(1, c.gtk_widget_get_width(self.area)));
    }

    fn widgetH(self: *const Compare) f64 {
        return @floatFromInt(@max(1, c.gtk_widget_get_height(self.area)));
    }

    fn onDragBegin(_: *c.GtkGestureDrag, x: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const self = canary.live(Compare, user) orelse return;
        const w = self.widgetW();
        const split_x = self.split * w;
        if (@abs(x - split_x) <= SPLIT_GRAB_PX) {
            self.drag = .split;
        } else if (self.zoom > 1.001) {
            self.drag = .pan;
        } else {
            // Not zoomed: the whole surface is a compare slider —
            // jump the split to the pointer and keep dragging it.
            self.split = std.math.clamp(x / w, 0, 1);
            self.drag = .split;
            c.gtk_widget_queue_draw(self.area);
        }
        self.split0 = self.split;
        self.pan_x0 = self.pan_x;
        self.pan_y0 = self.pan_y;
    }

    fn onDragUpdate(_: *c.GtkGestureDrag, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) void {
        const self = canary.live(Compare, user) orelse return;
        switch (self.drag) {
            .none => return,
            .split => self.split = std.math.clamp(self.split0 + dx / self.widgetW(), 0, 1),
            .pan => {
                self.pan_x = self.pan_x0 + dx;
                self.pan_y = self.pan_y0 + dy;
                self.clampPan();
            },
        }
        c.gtk_widget_queue_draw(self.area);
    }

    fn onDragEnd(_: *c.GtkGestureDrag, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const self = canary.live(Compare, user) orelse return;
        self.drag = .none;
    }

    fn onMotion(_: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self = canary.live(Compare, user) orelse return;
        self.mouse_x = x;
        self.mouse_y = y;
    }

    fn onScroll(_: *c.GtkEventControllerScroll, _: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        // Claim the event either way: a stale context must not let the
        // scroll fall through to the scroller behind it.
        const self = canary.live(Compare, user) orelse return 1;
        const w = self.widgetW();
        const h = self.widgetH();
        const base = self.baseScale(w, h) orelse return 1;
        const old_zoom = self.zoom;
        const factor = std.math.pow(f64, 1.15, -dy);
        self.zoom = std.math.clamp(self.zoom * factor, 1.0, MAX_ZOOM);
        if (self.zoom == old_zoom) return 1;
        if (self.zoom <= 1.001) {
            self.zoom = 1;
            self.pan_x = 0;
            self.pan_y = 0;
        } else {
            // Keep the image point under the pointer stationary:
            // p = center + pan + q*es  =>  pan' = p - center - q*es'.
            const es_old = base.es;
            const es_new = es_old / old_zoom * self.zoom;
            const qx = (self.mouse_x - w / 2 - self.pan_x) / es_old;
            const qy = (self.mouse_y - h / 2 - self.pan_y) / es_old;
            self.pan_x = self.mouse_x - w / 2 - qx * es_new;
            self.pan_y = self.mouse_y - h / 2 - qy * es_new;
            self.clampPan();
        }
        c.gtk_widget_queue_draw(self.area);
        return 1;
    }

    fn onPressed(_: *c.GtkGestureClick, n_press: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const self = canary.live(Compare, user) orelse return;
        if (n_press < 2) return;
        self.zoom = 1;
        self.pan_x = 0;
        self.pan_y = 0;
        c.gtk_widget_queue_draw(self.area);
    }

    /// Keep at least a sliver of image on screen.
    fn clampPan(self: *Compare) void {
        const w = self.widgetW();
        const h = self.widgetH();
        const base = self.baseScale(w, h) orelse return;
        const half_w = base.iw * base.es / 2;
        const half_h = base.ih * base.es / 2;
        self.pan_x = std.math.clamp(self.pan_x, -(half_w + w / 2 - 24), half_w + w / 2 - 24);
        self.pan_y = std.math.clamp(self.pan_y, -(half_h + h / 2 - 24), half_h + h / 2 - 24);
    }
};

// ─── tests (pure helpers only — no GTK init in unit tests) ──────

test "every renderer decl type-checks" {
    // Zig analyzes lazily: without this, a signature error in a
    // function no test calls would slip through `zig build test`.
    // All private helpers (including the whole Compare widget) hang
    // off PanelView's pub entry points, so referencing those analyzes
    // everything transitively.
    std.testing.refAllDecls(PanelView);
}

test "classMask maps names to Doc.CLASSES bit positions" {
    const a = std.testing.allocator;
    var one = [_][]u8{
        try a.dupe(u8, "dim"),
        try a.dupe(u8, "expand"),
    };
    defer for (one) |s| a.free(s);
    const mask = classMask(&one);
    try std.testing.expectEqual(@as(u16, 0b1000000001), mask);
    var none = [_][]u8{};
    try std.testing.expectEqual(@as(u16, 0), classMask(&none));
}

test "a poisoned PanelView makes the face trampolines bail" {
    // No GTK: prepareDestroyCb only touches plain fields, and the
    // poisoned call must not even get that far.
    var view = PanelView{
        .allocator = std.testing.allocator,
        .queue = events.Queue.init(),
        .root_box = undefined,
        .scroller = undefined,
    };
    const before = canary.trips;
    PanelView.prepareDestroyCb(@ptrCast(&view), true);
    try std.testing.expect(view.widgets_dead);
    try std.testing.expectEqual(before, canary.trips);

    // Simulate the freed-but-still-referenced case: poison, then let a
    // stale callback in. It must bail without writing anything.
    canary.poison(&view);
    view.widgets_dead = false;
    PanelView.prepareDestroyCb(@ptrCast(&view), true);
    try std.testing.expect(!view.widgets_dead);
    try std.testing.expectEqual(before + 1, canary.trips);
}

test "a poisoned CompCtx makes freeCompCtx bail instead of double-freeing" {
    const a = std.testing.allocator;
    const ctx = try a.create(PanelView.CompCtx);
    ctx.* = .{ .allocator = a, .view = null, .id = try a.dupe(u8, "btn") };
    // Stand in for "this closure was destroyed once already".
    canary.poison(ctx);

    const before = canary.trips;
    PanelView.freeCompCtx(@ptrCast(ctx));
    try std.testing.expectEqual(before + 1, canary.trips);

    // If the guard had not fired, these two would be a double free and
    // the testing allocator would say so.
    a.free(ctx.id);
    a.destroy(ctx);
}

test "optionsHash tracks option-list identity" {
    const a = std.testing.allocator;
    var opts1 = [_][]u8{ try a.dupe(u8, "one"), try a.dupe(u8, "two") };
    defer for (opts1) |s| a.free(s);
    var opts2 = [_][]u8{ try a.dupe(u8, "one"), try a.dupe(u8, "two") };
    defer for (opts2) |s| a.free(s);
    var opts3 = [_][]u8{ try a.dupe(u8, "onet"), try a.dupe(u8, "wo") };
    defer for (opts3) |s| a.free(s);
    try std.testing.expectEqual(optionsHash(&opts1), optionsHash(&opts2));
    // The separator keeps "one","two" distinct from "onet","wo".
    try std.testing.expect(optionsHash(&opts1) != optionsHash(&opts3));
}
