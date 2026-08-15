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
//! text input, slider value, progress fraction, image file, compare sides — the
//! compare keeps its zoom/pan/split across an image swap, which is
//! useful across repeated comparisons). Structural
//! changes (flow/scene children, root swap, removals, kind or class
//! changes) rebuild the affected tree wholesale — correctness first,
//! and a panel is bounded at 512 components.

const std = @import("std");
const c = @import("../../c.zig").c;
const Doc = @import("doc.zig");
const assets = @import("assets.zig");
const events = @import("events.zig");
const canary = @import("canary.zig");

const COMPARE_QDATA = "sketerm-panel-compare";
const PICTURE_LEASE_QDATA = "sketerm-panel-picture-lease";

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
    asset_resolver: assets.Resolver,
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

    const PreservedInput = struct {
        id: []u8,
        declared_value: []u8,
        draft: ?[]u8,
        focused: bool,
    };

    // ---- lifecycle ---------------------------------------------------

    pub fn create(allocator: std.mem.Allocator) !*PanelView {
        const self = try allocator.create(PanelView);
        errdefer allocator.destroy(self);
        const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0) orelse return error.OutOfMemory;
        const scroller = c.gtk_scrolled_window_new() orelse return error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .asset_resolver = assets.Resolver.init(allocator, null),
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
        self.asset_resolver.deinit();
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
        var resolver = assets.Resolver.init(self.allocator, null);
        defer resolver.deinit();
        return self.setDocumentResolved(json_text, &resolver, diag);
    }

    /// Replace the document and logical-path resolver as one visible commit.
    pub fn setDocumentResolved(
        self: *PanelView,
        json_text: []const u8,
        resolver: *assets.Resolver,
        diag: ?*Doc.Diag,
    ) Doc.Error!void {
        var fresh = try Doc.Document.parse(self.allocator, json_text, diag);
        errdefer fresh.deinit();
        var preserved = try self.captureInputs(&fresh);
        defer self.freePreservedInputs(&preserved);
        if (self.doc) |*old| {
            fresh.revision = old.revision + 1;
            old.deinit();
        }
        self.doc = fresh;
        self.asset_resolver.replaceFrom(resolver);
        if (!self.widgets_dead) {
            self.applying = true;
            defer self.applying = false;
            self.rebuildAll();
            self.restoreInputs(preserved.items);
        }
        self.notifyChanged();
    }

    /// Apply a patch (doc.zig op array). Transactional at the document
    /// level; widget updates are in-place where the change is a leaf
    /// property, wholesale otherwise.
    pub fn applyPatch(self: *PanelView, json_text: []const u8, diag: ?*Doc.Diag) Doc.Error!void {
        return self.applyPatchInternal(json_text, null, diag);
    }

    /// Commit a validated remote resolver only after the patch itself succeeds.
    pub fn applyPatchResolved(
        self: *PanelView,
        json_text: []const u8,
        resolver: *assets.Resolver,
        diag: ?*Doc.Diag,
    ) Doc.Error!void {
        return self.applyPatchInternal(json_text, resolver, diag);
    }

    fn applyPatchInternal(
        self: *PanelView,
        json_text: []const u8,
        resolver: ?*assets.Resolver,
        diag: ?*Doc.Diag,
    ) Doc.Error!void {
        if (self.doc == null) {
            if (diag) |d| d.set("no document to patch (setDocument first)", .{});
            return Doc.Error.Malformed;
        }
        var preserved = try self.captureInputs(null);
        defer self.freePreservedInputs(&preserved);
        var applied = try self.doc.?.applyPatch(json_text, diag);
        defer applied.deinit();
        if (resolver) |prepared| self.asset_resolver.replaceFrom(prepared);
        if (!self.widgets_dead) {
            self.applying = true;
            defer self.applying = false;
            var rebuild = self.patchNeedsStructuralRebuild(&applied);
            if (!rebuild) {
                for (applied.set) |id| {
                    if (!self.updateOne(id)) {
                        rebuild = true;
                        break;
                    }
                }
            }
            if (rebuild) {
                self.rebuildAll();
            } else if (resolver != null) {
                self.refreshImages();
            }
            self.restoreInputs(preserved.items);
        }
        if (applied.title_changed) self.notifyChanged();
    }

    /// Decide structural rebuilds before touching any live leaf. The document
    /// already contains the whole multi-op result, while `built` still mirrors
    /// the old GTK tree; updating a leaf first can therefore see it as
    /// unmounted even though its live parent is still a GtkFixed.
    fn patchNeedsStructuralRebuild(self: *const PanelView, applied: *const Doc.Document.Applied) bool {
        if (applied.root_changed or applied.removed.len > 0) return true;
        const document = &(self.doc orelse return true);
        for (applied.set) |id| {
            const old = self.built.get(id) orelse continue;
            const new = document.get(id) orelse continue;
            if (old.kind.isContainer() or new.kind().isContainer()) return true;
        }
        return false;
    }

    fn captureInputs(self: *const PanelView, fresh: ?*const Doc.Document) Doc.Error!std.ArrayList(PreservedInput) {
        var preserved: std.ArrayList(PreservedInput) = .empty;
        errdefer self.freePreservedInputs(&preserved);
        if (self.widgets_dead) return preserved;
        const old = &(self.doc orelse return preserved);
        var it = old.components.iterator();
        while (it.next()) |entry| {
            const old_input = switch (entry.value_ptr.props) {
                .text_input => |input| input,
                else => continue,
            };
            const next_input = if (fresh) |document| blk: {
                const component = document.get(entry.key_ptr.*) orelse continue;
                break :blk switch (component.props) {
                    .text_input => |input| input,
                    else => continue,
                };
            } else old_input;
            const built = self.built.get(entry.key_ptr.*) orelse continue;
            if (built.kind != .text_input) continue;
            const focused = (c.gtk_widget_get_state_flags(built.widget) & c.GTK_STATE_FLAG_FOCUS_WITHIN) != 0;
            const keep_draft = std.mem.eql(u8, old_input.value, next_input.value);
            if (!focused and !keep_draft) continue;
            const id = self.allocator.dupe(u8, entry.key_ptr.*) catch return Doc.Error.OutOfMemory;
            errdefer self.allocator.free(id);
            const declared_value = self.allocator.dupe(u8, old_input.value) catch return Doc.Error.OutOfMemory;
            errdefer self.allocator.free(declared_value);
            var draft: ?[]u8 = null;
            if (keep_draft) {
                const raw = c.gtk_editable_get_text(@ptrCast(built.widget));
                const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
                const n = utf8Prefix(text, Doc.MAX_TEXT);
                draft = self.allocator.dupe(u8, text[0..n]) catch return Doc.Error.OutOfMemory;
            }
            errdefer if (draft) |text| self.allocator.free(text);
            preserved.append(self.allocator, .{
                .id = id,
                .declared_value = declared_value,
                .draft = draft,
                .focused = focused,
            }) catch
                return Doc.Error.OutOfMemory;
        }
        return preserved;
    }

    fn freePreservedInputs(self: *const PanelView, preserved: *std.ArrayList(PreservedInput)) void {
        for (preserved.items) |input| {
            self.allocator.free(input.id);
            self.allocator.free(input.declared_value);
            if (input.draft) |draft| self.allocator.free(draft);
        }
        preserved.deinit(self.allocator);
    }

    fn restoreInputs(self: *PanelView, preserved: []const PreservedInput) void {
        for (preserved) |input| {
            const built = self.built.get(input.id) orelse continue;
            if (built.kind != .text_input) continue;
            const document = &(self.doc orelse continue);
            const component = document.get(input.id) orelse continue;
            if (component.kind() != .text_input) continue;
            if (std.mem.eql(u8, input.declared_value, component.props.text_input.value)) {
                if (input.draft) |draft| setEntryValue(built.widget, draft);
            }
            if (input.focused) _ = c.gtk_widget_grab_focus(built.widget);
        }
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

    /// Clone one live asset mapping into a transactional candidate resolver.
    pub fn copyAssetResolution(self: *const PanelView, target: *assets.Resolver, logical: []const u8) !bool {
        return target.copyFrom(&self.asset_resolver, logical);
    }

    pub fn assetCache(self: *const PanelView) ?*assets.Cache {
        return self.asset_resolver.cache;
    }

    /// Install a worker-prepared resolver as the live mapping set.
    pub fn installAssetResolver(self: *PanelView, resolver: *assets.Resolver) void {
        self.asset_resolver.replaceFrom(resolver);
        if (!self.widgets_dead) {
            self.applying = true;
            defer self.applying = false;
            self.refreshImages();
        }
    }

    /// Merge completed path refreshes into the latest document, preserving
    /// later non-image edits and every untouched live mapping.
    pub fn mergeAssetResolver(self: *PanelView, updates: *const assets.Resolver) !void {
        const document = &(self.doc orelse return);
        var paths = try assets.collectPaths(self.allocator, document);
        defer paths.deinit();
        var candidate = try assets.composeResolver(
            self.allocator,
            updates.cache orelse self.asset_resolver.cache,
            paths.items,
            &self.asset_resolver,
            updates,
        );
        self.asset_resolver.replaceFrom(&candidate);
        if (!self.widgets_dead) {
            self.applying = true;
            defer self.applying = false;
            self.refreshImages();
        }
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

    fn parkContentFocus(self: *PanelView) void {
        const root = c.gtk_widget_get_root(self.scroller) orelse return;
        const focused = c.gtk_root_get_focus(@ptrCast(root)) orelse return;
        if (focused == self.scroller or
            c.gtk_widget_is_ancestor(focused, self.scroller) != 0)
        {
            _ = c.gtk_widget_grab_focus(self.scroller);
        }
    }

    fn rebuildAll(self: *PanelView) void {
        // Keep GTK's focus pointer out of the subtree that set_child replaces.
        // Full document replacement may restore a preserved input afterwards.
        self.parkContentFocus();
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
            .scene => |scene| blk: {
                const fixed = c.gtk_fixed_new().?;
                setMinimumRequest(fixed, scene.width, scene.height);
                for (scene.children) |placement| {
                    const child = self.buildComponent(placement.id, depth + 1, true);
                    // GtkFixed positions the child, but GTK size requests are
                    // minima: natural sizing may allocate more than this box.
                    setMinimumRequest(child, placement.width, placement.height);
                    c.gtk_fixed_put(
                        @ptrCast(fixed),
                        child,
                        @floatFromInt(placement.x),
                        @floatFromInt(placement.y),
                    );
                }
                break :blk fixed;
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
                const cmp = Compare.create(self.allocator, area, ic, &self.asset_resolver) catch
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
            .text_input => |input| blk: {
                const entry = c.gtk_entry_new().?;
                c.gtk_entry_set_max_length(@ptrCast(entry), @intCast(Doc.MAX_TEXT));
                setTextInput(entry, input);
                self.connectComp(entry, "changed", @ptrCast(&onTextInputChanged), id);
                self.connectComp(entry, "activate", @ptrCast(&onTextInputActivate), id);
                break :blk entry;
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
        const resolution = self.asset_resolver.get(img.src);
        if (resolution) |resolved| if (resolved.failure) |why| {
            setPicturePrepared(pic, null);
            var buf: [Doc.MAX_PATH + 256]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "remote asset unavailable: {s}: {s}", .{ img.src, why }) catch
                "remote asset unavailable";
            c.gtk_label_set_text(@ptrCast(cap), msg.ptr);
            c.gtk_widget_add_css_class(cap, "error");
            c.gtk_widget_set_visible(cap, 1);
            return;
        };
        if (resolution) |resolved| if (resolved.prepared_lease) |lease| {
            setPicturePrepared(pic, lease);
            c.gtk_widget_remove_css_class(cap, "error");
            if (img.caption.len > 0) {
                setLabelText(cap, img.caption);
                c.gtk_widget_set_visible(cap, 1);
            } else {
                c.gtk_widget_set_visible(cap, 0);
            }
            return;
        };
        // Every image is prepared off the GTK thread before commit — remote
        // entries by the relay pipeline, path-backed ones by panelhost's
        // bounded local workers. Never fall back to GtkPicture filename
        // loading (filesystem + decoder work on GTK) if that invariant fails.
        setPicturePrepared(pic, null);
        c.gtk_label_set_text(@ptrCast(cap), if (resolution != null)
            "remote asset was not prepared"
        else
            "panel asset was not prepared");
        c.gtk_widget_add_css_class(cap, "error");
        c.gtk_widget_set_visible(cap, 1);
    }

    fn refreshImages(self: *PanelView) void {
        const d = &(self.doc orelse return);
        var it = d.components.iterator();
        while (it.next()) |entry| switch (entry.value_ptr.kind()) {
            .image, .image_compare => _ = self.updateOne(entry.key_ptr.*),
            else => {},
        };
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
                cmp.setSides(ic, &self.asset_resolver);
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
            .scene => unreachable,
            .text_input => |input| setTextInput(entry.widget, input),
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
        // The live widget tree still reflects the pre-patch document. Never
        // infer its parent type from the already-updated model: a multi-op
        // patch may have removed this leaf from an old GtkFixed scene.
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(parent)),
            c.gtk_box_get_type(),
        ) == 0) return false;
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
            .scene => |scene| for (scene.children) |placement| {
                if (reachFrom(d, placement.id, id, depth + 1)) return true;
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

    fn onTextInputChanged(editable: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
        const ctx = canary.live(CompCtx, user) orelse return;
        const view = ctx.view orelse return;
        if (view.widgets_dead or view.applying) return;
        const raw = c.gtk_editable_get_text(editable) orelse return;
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        if (text.len <= Doc.MAX_TEXT) return;
        const n = utf8Prefix(text, Doc.MAX_TEXT);
        var zbuf: [Doc.MAX_TEXT + 1]u8 = undefined;
        @memcpy(zbuf[0..n], text[0..n]);
        zbuf[n] = 0;
        view.applying = true;
        defer view.applying = false;
        c.gtk_editable_set_text(editable, @ptrCast(&zbuf));
        c.gtk_editable_set_position(editable, -1);
    }

    fn onTextInputActivate(entry: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const ctx = canary.live(CompCtx, user) orelse return;
        const view = ctx.view orelse return;
        if (view.widgets_dead or view.applying) return;
        const d = &(view.doc orelse return);
        const comp = d.get(ctx.id) orelse return;
        if (comp.kind() != .text_input) return;
        const raw = c.gtk_editable_get_text(@ptrCast(entry)) orelse return;
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        const n = utf8Prefix(text, Doc.MAX_TEXT);
        view.queue.push(events.Event.init(ctx.id, .submit, events.Value.fromText(text[0..n])));
        if (comp.props.text_input.clear_on_submit) {
            view.applying = true;
            defer view.applying = false;
            c.gtk_editable_set_text(@ptrCast(entry), "");
        }
    }
};

/// Pair GtkPicture's internal pixbuf ref with the same residency lease.
fn setPicturePrepared(pic: *c.GtkWidget, lease: ?*assets.PreparedLease) void {
    if (lease) |prepared| {
        c.gtk_picture_set_pixbuf(
            @ptrCast(pic),
            @ptrCast(@alignCast(prepared.prepared)),
        );
        setPreparedLeaseData(@ptrCast(@alignCast(pic)), prepared);
    } else {
        // Drop the pixbuf first; only then may the paired process charge go.
        c.gtk_picture_set_pixbuf(@ptrCast(pic), null);
        setPreparedLeaseData(@ptrCast(@alignCast(pic)), null);
    }
}

fn setPreparedLeaseData(object: *c.GObject, lease: ?*assets.PreparedLease) void {
    if (lease) |prepared| prepared.retain();
    c.g_object_set_data_full(
        @ptrCast(object),
        PICTURE_LEASE_QDATA,
        if (lease) |prepared| @ptrCast(prepared) else null,
        if (lease != null) @ptrCast(&releasePreparedLease) else null,
    );
}

fn releasePreparedLease(user: ?*anyopaque) callconv(.c) void {
    const lease = canary.live(assets.PreparedLease, user) orelse return;
    lease.release();
}

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

fn setTextInput(entry: *c.GtkWidget, input: Doc.Props.TextInput) void {
    setEntryValue(entry, input.value);
    var placeholder_buf: [Doc.MAX_TEXT + 1]u8 = undefined;
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), zOf(&placeholder_buf, input.placeholder));
}

fn setEntryValue(entry: *c.GtkWidget, value: []const u8) void {
    var value_buf: [Doc.MAX_TEXT + 1]u8 = undefined;
    c.gtk_editable_set_text(@ptrCast(entry), zOf(&value_buf, value));
}

const MinimumRequest = struct { width: c_int, height: c_int };

fn minimumRequest(width: u16, height: u16) MinimumRequest {
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

fn setMinimumRequest(widget: *c.GtkWidget, width: u16, height: u16) void {
    const request = minimumRequest(width, height);
    c.gtk_widget_set_size_request(widget, request.width, request.height);
}

fn utf8Prefix(text: []const u8, max: usize) usize {
    if (text.len <= max and std.unicode.utf8ValidateSlice(text)) return text.len;
    var end = @min(text.len, max);
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return end;
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

fn replaceZ(allocator: std.mem.Allocator, target: *[:0]u8, text: []const u8) ?void {
    if (allocator.dupeZ(u8, text)) |copy| {
        allocator.free(target.*);
        target.* = copy;
        return {};
    } else |_| return null;
}

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
    left_lease: ?*assets.PreparedLease = null,
    right_lease: ?*assets.PreparedLease = null,
    left_path: [:0]u8,
    right_path: [:0]u8,
    left_error: [:0]u8,
    right_error: [:0]u8,
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

    fn create(
        allocator: std.mem.Allocator,
        area: *c.GtkWidget,
        ic: Doc.Props.ImageCompare,
        resolver: *const assets.Resolver,
    ) !*Compare {
        const self = try allocator.create(Compare);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .area = area,
            .left_path = try allocator.dupeZ(u8, ""),
            .right_path = try allocator.dupeZ(u8, ""),
            .left_error = try allocator.dupeZ(u8, ""),
            .right_error = try allocator.dupeZ(u8, ""),
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

        self.setSides(ic, resolver);
        return self;
    }

    fn freeCompare(user: ?*anyopaque) callconv(.c) void {
        if (canary.live(Compare, user)) |self| {
            if (self.left_lease) |lease| lease.release();
            if (self.right_lease) |lease| lease.release();
            self.allocator.free(self.left_path);
            self.allocator.free(self.right_path);
            self.allocator.free(self.left_error);
            self.allocator.free(self.right_error);
            self.allocator.free(self.left_label);
            self.allocator.free(self.right_label);
            canary.poison(self);
            self.allocator.destroy(self);
        }
    }

    /// (Re)load both sides. Zoom/pan/split are deliberately KEPT: a
    /// replacing compared media while the user is inspecting a detail
    /// must not reset the viewport.
    fn setSides(self: *Compare, ic: Doc.Props.ImageCompare, resolver: *const assets.Resolver) void {
        self.loadSide(&self.left_lease, &self.left_path, &self.left_error, &self.left_label, ic.left, resolver);
        self.loadSide(&self.right_lease, &self.right_path, &self.right_error, &self.right_label, ic.right, resolver);
        c.gtk_widget_queue_draw(self.area);
    }

    fn loadSide(
        self: *Compare,
        retained: *?*assets.PreparedLease,
        path: *[:0]u8,
        error_text: *[:0]u8,
        label: *[:0]u8,
        side: Doc.Side,
        resolver: *const assets.Resolver,
    ) void {
        const a = self.allocator;
        if (a.dupeZ(u8, side.label)) |lz| {
            a.free(label.*);
            label.* = lz;
        } else |_| {}
        replaceZ(a, path, side.src) orelse return;
        const resolved = resolver.get(side.src);
        const failure = if (resolved) |entry| entry.failure orelse "" else "";
        replaceZ(a, error_text, failure) orelse return;
        // ALWAYS refresh even for an unchanged logical path so a reset adopts
        // the newly prepared worker result.
        var next: ?*assets.PreparedLease = null;
        if (resolved) |entry| {
            next = entry.prepared_lease;
            if (next) |lease| lease.retain();
            if (next == null and error_text.*.len == 0)
                replaceZ(a, error_text, "remote asset was not prepared") orelse {};
        } else if (error_text.*.len == 0) {
            replaceZ(a, error_text, "panel asset was not prepared") orelse {};
        }
        if (retained.*) |old| old.release();
        retained.* = next;
    }

    fn pixbuf(lease: ?*assets.PreparedLease) ?*c.GdkPixbuf {
        const retained = lease orelse return null;
        return @ptrCast(@alignCast(retained.prepared));
    }

    // ---- drawing -----------------------------------------------------

    fn baseScale(self: *const Compare, w: f64, h: f64) ?struct { iw: f64, ih: f64, es: f64 } {
        const pix = pixbuf(self.right_lease) orelse pixbuf(self.left_lease) orelse return null;
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

        const split_x = std.math.clamp(self.split, 0, 1) * w;
        const base = self.baseScale(w, h) orelse {
            // Render each side's path-specific failure even when neither side
            // decoded; the old generic message discarded both diagnostics.
            self.drawSide(ctx, null, 1, w, h, 0, split_x, self.left_path, self.left_error);
            self.drawSide(ctx, null, 1, w, h, split_x, w - split_x, self.right_path, self.right_error);
            return;
        };

        self.drawSide(ctx, pixbuf(self.left_lease), base.es, w, h, 0, split_x, self.left_path, self.left_error);
        self.drawSide(ctx, pixbuf(self.right_lease), base.es, w, h, split_x, w - split_x, self.right_path, self.right_error);

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
        error_text: [:0]const u8,
    ) void {
        if (clip_w <= 0) return;
        c.cairo_save(ctx);
        defer c.cairo_restore(ctx);
        c.cairo_rectangle(ctx, clip_x, 0, clip_w, h);
        c.cairo_clip(ctx);
        const pix = pix_o orelse {
            c.cairo_set_source_rgb(ctx, 0.2, 0.12, 0.12);
            c.cairo_paint(ctx);
            c.cairo_select_font_face(ctx, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
            c.cairo_set_font_size(ctx, 12);
            c.cairo_set_source_rgba(ctx, 1, 0.75, 0.75, 0.9);
            var path_buf: [Doc.MAX_PATH + 32]u8 = undefined;
            const path_msg = sidePathErrorText(&path_buf, path);
            c.cairo_move_to(ctx, clip_x + 10, h / 2 - 8);
            c.cairo_show_text(ctx, path_msg.ptr);
            var reason_buf: [280]u8 = undefined;
            const reason_msg = sideReasonErrorText(&reason_buf, error_text);
            c.cairo_move_to(ctx, clip_x + 10, h / 2 + 12);
            c.cairo_show_text(ctx, reason_msg.ptr);
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

fn sidePathErrorText(buf: []u8, path: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "cannot load {s}", .{path}) catch "cannot load image";
}

fn sideReasonErrorText(buf: []u8, error_text: []const u8) [:0]const u8 {
    const reason = if (error_text.len > 0) error_text else "cannot decode or read image";
    return std.fmt.bufPrintZ(buf, "{s}", .{reason}) catch "cannot decode or read image";
}

// ─── tests (no GTK widget initialization) ───────────────────────

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
        .asset_resolver = assets.Resolver.init(std.testing.allocator, null),
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

test "text input byte limiting preserves UTF-8 boundaries" {
    try std.testing.expectEqual(@as(usize, 4096), utf8Prefix("x" ** 5000, 4096));
    try std.testing.expectEqual(@as(usize, 1), utf8Prefix("A\xe2\x82\xacB", 3));
    try std.testing.expectEqual(@as(usize, 4), utf8Prefix("A\xe2\x82\xacB", 4));
}

test "scene geometry maps declared sizes to GTK minimum requests" {
    try std.testing.expectEqual(MinimumRequest{ .width = 4096, .height = 1 }, minimumRequest(4096, 1));
}

test "multi-op leaf replacement before scene unmount preflights a rebuild" {
    const a = std.testing.allocator;
    const document = try Doc.Document.parse(a,
        \\{"root":"canvas","components":{
        \\ "canvas":{"type":"scene","width":100,"height":100,"children":[{"id":"leaf","x":0,"y":0,"width":20,"height":20}]},
        \\ "leaf":{"type":"text","text":"old"}}}
    , null);
    var view = PanelView{
        .allocator = a,
        .doc = document,
        .asset_resolver = assets.Resolver.init(a, null),
        .queue = events.Queue.init(),
        .root_box = undefined,
        .scroller = undefined,
    };
    defer {
        view.clearBuilt();
        view.doc.?.deinit();
        view.asset_resolver.deinit();
    }
    try view.built.put(a, try a.dupe(u8, "canvas"), .{ .widget = undefined, .kind = .scene });
    try view.built.put(a, try a.dupe(u8, "leaf"), .{ .widget = undefined, .kind = .text });

    // Operation order is the regression: the leaf changes kind before the
    // scene unmounts it. Without preflight, swapOne sees the NEW graph, misses
    // the scene parent, and invokes GtkBox APIs on the OLD live GtkFixed.
    var applied = try view.doc.?.applyPatch(
        \\[
        \\ {"op":"set","id":"leaf","component":{"type":"button","text":"new"}},
        \\ {"op":"set","id":"canvas","component":{"type":"scene","width":100,"height":100,"children":[]}}
        \\]
    , null);
    defer applied.deinit();
    try std.testing.expect(view.patchNeedsStructuralRebuild(&applied));
}

test "image compare preserves both path-specific decode failures" {
    var left_buf: [256]u8 = undefined;
    var right_buf: [256]u8 = undefined;
    var left_reason_buf: [256]u8 = undefined;
    var right_reason_buf: [256]u8 = undefined;
    const left = sidePathErrorText(&left_buf, "/remote/left.png");
    const right = sidePathErrorText(&right_buf, "/remote/right.png");
    const left_reason = sideReasonErrorText(&left_reason_buf, "left decoder error");
    const right_reason = sideReasonErrorText(&right_reason_buf, "right decoder error");
    try std.testing.expect(std.mem.indexOf(u8, left, "/remote/left.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, right, "/remote/right.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, left_reason, "left decoder error") != null);
    try std.testing.expect(std.mem.indexOf(u8, right_reason, "right decoder error") != null);
    try std.testing.expect(!std.mem.eql(u8, left, right));
    try std.testing.expect(!std.mem.eql(u8, left_reason, right_reason));
}

test "deferred GObject finalization keeps prepared residency charged" {
    const a = std.testing.allocator;
    const before = assets.processPreparedUsage();
    const image = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 2, 2) orelse
        return error.OutOfMemory;
    const info = assets.PreparedInfo{
        .pixels = 4,
        .bytes = @intCast(c.gdk_pixbuf_get_rowstride(image) * c.gdk_pixbuf_get_height(image)),
    };
    var reservation = assets.ProcessPreparedReservation.reserve(info) catch |err| {
        c.g_object_unref(@ptrCast(image));
        return err;
    };
    const lease = assets.PreparedLease.adoptReserved(a, @ptrCast(image), &reservation) catch |err| {
        reservation.release();
        c.g_object_unref(@ptrCast(image));
        return err;
    };

    // This plain GObject models a widget's lease qdata without requiring GTK
    // initialization. Its extra ref is the deferred toolkit/finalizer owner.
    const holder = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 1, 1) orelse {
        lease.release();
        return error.OutOfMemory;
    };
    _ = c.g_object_ref(@ptrCast(holder));
    setPreparedLeaseData(@ptrCast(@alignCast(holder)), lease);
    lease.release();
    try std.testing.expectEqual(before.pixels + info.pixels, assets.processPreparedUsage().pixels);
    try std.testing.expectEqual(before.bytes + info.bytes, assets.processPreparedUsage().bytes);

    // Dropping the panel/widget-tree owner is not finalization: the process
    // charge remains paired with the holder's last GObject reference.
    c.g_object_unref(@ptrCast(holder));
    try std.testing.expectEqual(before.pixels + info.pixels, assets.processPreparedUsage().pixels);
    try std.testing.expectEqual(before.bytes + info.bytes, assets.processPreparedUsage().bytes);
    c.g_object_unref(@ptrCast(holder));
    try std.testing.expectEqual(before, assets.processPreparedUsage());
}
