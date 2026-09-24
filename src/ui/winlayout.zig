//! Layout persistence and tab-tree building — collect/save/load of
//! window layouts, closed-tab capture/restore, tree-model verification,
//! and the paned-ratio plumbing — split out of window.zig. Functions
//! keep the owning *Window receiver and are aliased back into Window.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const readfile = @import("../util/readfile.zig");
const logActionError = winmod.logActionError;
const layout_mod = @import("../layout.zig");
const Pane = @import("pane.zig").Pane;
const winmod = @import("window.zig");
const Window = winmod.Window;
const PaneTree = winmod.PaneTree;
const tab_effects = @import("tab_effects.zig");
const muxtabs = @import("muxtabs.zig");
const picker = @import("picker.zig");
const fpicker = @import("../filebrowser/picker.zig");

/// Owned ratio holder for `applyPanedRatio` / `applyPanedRatioMap`,
/// released by a `cast.destroyCtx(PanedRatioCtx)` notify. Carries its own
/// allocator so that notify can free without needing a Window pointer.
/// Live ratio tracker for a GtkPaned. `ratio` is updated whenever the
/// user drags (via notify::position) and re-applied on every map (via
/// the map signal). Tab switches unmap+remap the paged subtree; without
/// re-apply, GtkPaned reverts to natural sizes on remap.
///
/// `setting` guards against the feedback loop: our own gtk_paned_set_
/// position triggers notify::position, which would re-read total (which
/// may be transient during allocation) and corrupt ratio. We bracket
/// every set_position with setting=true so the notify handler ignores
/// our own writes.
pub const PanedRatioCtx = struct {
    allocator: std.mem.Allocator,
    ratio: f32,
    setting: bool = false,
};


/// Spawn a new tab from a layout TabSpec (used on --restore). `at_end`
/// forces an append so a multi-tab restore keeps its saved order.
pub fn newTabFromSpec(self: *Window, spec: @import("../layout.zig").TabSpec, at_end: bool) !void {
    try validateTree(spec.tree);
    const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_vexpand(wrapper, 1);
    c.gtk_widget_set_hexpand(wrapper, 1);

    var model_root: PaneTree.Node = undefined;
    const root_widget = try buildTreeWidget(self, spec.tree, &model_root);
    c.gtk_box_append(@ptrCast(wrapper), root_widget);

    const title_z = try self.allocator.allocSentinel(u8, spec.title.len, 0);
    defer self.allocator.free(title_z);
    @memcpy(title_z, spec.title);

    const page = self.appendOrInsertTab(wrapper, model_root, at_end);
    c.adw_tab_page_set_title(page, title_z.ptr);
    c.adw_tab_page_set_tooltip(page, title_z.ptr);
    // Re-arm the user-rename lock so OSC titles can't stomp a
    // deliberately named tab.
    if (restoresTitleLocked(spec.title_locked)) {
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-title-locked", @ptrCast(page));
    }
    if (spec.pinned) c.adw_tab_view_set_page_pinned(self.tab_view, page, 1);
    if (spec.color) |col_str| {
        if (Window.parseHexRGB(col_str)) |col| self.setTabColor(page, col);
    }
    tab_effects.setTabSettings(page, .{
        .show_activity = spec.show_activity,
        .warn_inactive = spec.warn_inactive,
    });
    // A restored/duplicated warn-tab starts clean: the warning is edge-
    // triggered on activity→silence, so it stays quiet until the tab
    // actually produces output and then falls silent. Nothing to anchor.
}

/// Re-apply a PaneSpec's saved shader state: preset by name
/// first, then the explicit path pick, then a sticky clear.
pub fn restorePaneShader(self: *Window, pane: *Pane, p: @import("../layout.zig").PaneSpec) void {
    if (p.shader_preset.len > 0) {
        if (self.applyShaderPresetByName(pane, p.shader_preset)) return;
    }
    if (p.custom_shader.len > 0)
        _ = pane.setCustomShader(p.custom_shader, self.config.custom_shader_animation, true)
    else if (p.shader_cleared)
        pane.clearShader();
}

/// Build the widget subtree for a layout spec, producing the
/// matching model node in `node_out` (valid only on success).
pub fn buildTreeWidget(self: *Window, tree: @import("../layout.zig").Tree, node_out: *PaneTree.Node) !*c.GtkWidget {
    switch (tree) {
        .pane => |p| {
            // Durable LOCAL mux pane: reattach (or recreate under
            // the same name) instead of spawning a local PTY. A
            // failed daemon falls through to the plain spawn below
            // so startup never wedges on a layout. REMOTE mux panes
            // never connect here — ssh/udp to a dead host would
            // freeze the whole GUI (this runs on the main loop);
            // they spawn the local placeholder below and reattach
            // asynchronously (startMuxRestoreJob).
            if (p.mux_session.len > 0 and p.mux_host.len == 0) {
                if (muxtabs.restoreMuxPane(self, p)) |pane| {
                    restorePaneShader(self, pane, p);
                    node_out.* = .{ .leaf = pane };
                    return pane.widget();
                } else |err| {
                    std.debug.print(
                        "sketerm: mux restore '{s}' failed ({s}) — spawning local shell\n",
                        .{ p.mux_session, @errorName(err) },
                    );
                }
            }

            if (p.command.len == 0) return error.EmptyCommand;

            // Resolve profile (if any) so we can honour profile.shell
            // override before constructing argv.
            const profile: ?*const @import("../config.zig").Profile = if (p.profile.len > 0)
                self.findProfile(p.profile)
            else
                null;
            const profile_shell: ?[]const u8 = if (profile) |pr| pr.settings.shell else null;

            var argv_buf = try self.allocator.alloc([*:0]const u8, p.command.len);
            defer self.allocator.free(argv_buf);
            var arg_owners: std.ArrayList([:0]u8) = .empty;
            defer {
                for (arg_owners.items) |s| self.allocator.free(s);
                arg_owners.deinit(self.allocator);
            }
            for (p.command, 0..) |cmd, i| {
                const eff_cmd = restoredArg(i, cmd, profile_shell);
                const z = try self.allocator.allocSentinel(u8, eff_cmd.len, 0);
                try arg_owners.append(self.allocator, z);
                @memcpy(z, eff_cmd);
                argv_buf[i] = z.ptr;
            }

            // Convert argv to slices for the wire spawn. The restored
            // local pane becomes a daemon-backed session (the unified
            // model) — the factory tracks it in panes/terminals.
            var argv_slices: std.ArrayList([]const u8) = .empty;
            defer argv_slices.deinit(self.allocator);
            for (argv_buf) |a| try argv_slices.append(self.allocator, std.mem.span(a));

            const pane = try self.daemonSpawnPane(.{
                .argv = argv_slices.items,
                .cwd = p.cwd,
                .si = self.shellIntegrationFor(argv_buf[0]),
                .profile = profile,
            });
            pane.setSpawnArgv(argv_buf);
            // Restore extras the base factory doesn't cover: per-pane
            // font-size override + explicit shader preset/clear.
            if (p.font_size != null)
                self.applyPaneConfig(pane, .{ .profile = profile, .font_size_override = p.font_size });
            restorePaneShader(self, pane, p);

            // Remote durable pane: the local shell above is a live
            // placeholder; the reattach runs off the main loop and
            // swaps in when (if) the host answers.
            if (p.mux_session.len > 0 and p.mux_host.len > 0)
                muxtabs.startMuxRestoreJob(self, pane, p);

            // Browser face: reattach with the saved internal tabs.
            if (p.browser != null or p.browser_tabs.len > 0) {
                const browser_mod = @import("browser.zig");
                const restored = if (p.browser) |state|
                    browser_mod.BrowserView.attachState(self.allocator, pane, state)
                else
                    browser_mod.BrowserView.attach(self.allocator, pane, p.browser_tabs[0]);
                if (restored) |bv| {
                    self.installBrowserHooks(bv);
                    if (p.browser == null) {
                        for (p.browser_tabs[1..]) |tp| _ = bv.newTabSpec(tp);
                    }
                } else |err| {
                    std.debug.print("sketerm: browser restore failed: {s}\n", .{@errorName(err)});
                }
            }

            // Web face: reopen the saved address. A blank tab (no url)
            // still gets the face back, with its address bar focused.
            if (p.web) |wstate| {
                const webface = @import("webface.zig");
                // A browser can hold several pages; page 0 is attached
                // the ordinary way and the group rebuilds the rest with
                // their nesting.
                const first = firstWebPage(wstate);
                if (webface.WebFace.attachContainer(self.allocator, pane, first.url, first.container)) |wf| {
                    wf.applyRestoredZoom(first.zoom_level_x100);
                    if (first.scroll) |s| wf.applyRestoredScroll(s.x, s.y);
                    if (@import("webgroup.zig").Group.fromPane(pane)) |g|
                        g.restorePages(wstate);
                } else |err| {
                    std.debug.print("sketerm: web restore failed: {s}\n", .{@errorName(err)});
                }
            }

            // Editor face: reopen the saved files (async loads).
            if (p.editor) |estate| {
                if (estate.files.len > 0) {
                    _ = @import("editorview.zig").EditorView.attachState(self.allocator, pane, estate) catch |err| {
                        std.debug.print("sketerm: editor restore failed: {s}\n", .{@errorName(err)});
                    };
                }
            }

            node_out.* = .{ .leaf = pane };
            return pane.widget();
        },
        .split => |s| {
            if (s.children.len < 2) return error.InvalidLayout;
            const orientation: c_uint = if (s.orientation == .horizontal)
                @intCast(c.GTK_ORIENTATION_HORIZONTAL)
            else
                @intCast(c.GTK_ORIENTATION_VERTICAL);
            const paned = c.gtk_paned_new(orientation);
            c.gtk_paned_set_resize_start_child(@ptrCast(paned), 1);
            c.gtk_paned_set_resize_end_child(@ptrCast(paned), 1);
            c.gtk_paned_set_shrink_start_child(@ptrCast(paned), 0);
            c.gtk_paned_set_shrink_end_child(@ptrCast(paned), 0);
            // Wide handle so GtkPaned honours CSS min-width on
            // the separator (gives us the gutter around the line).
            c.gtk_paned_set_wide_handle(@ptrCast(paned), 1);
            var first_node: PaneTree.Node = undefined;
            var second_node: PaneTree.Node = undefined;
            const first = try buildTreeWidget(self, s.children[0], &first_node);
            const second = try buildTreeWidget(self, s.children[1], &second_node);
            c.gtk_paned_set_start_child(@ptrCast(paned), first);
            c.gtk_paned_set_end_child(@ptrCast(paned), second);
            const split_node = try self.allocator.create(PaneTree.Split);
            split_node.* = .{
                .orientation = if (s.orientation == .horizontal) .horizontal else .vertical,
                .ratio = splitRatio(s.ratio),
                .children = .{ first_node, second_node },
                .view = paned,
            };
            node_out.* = .{ .split = split_node };

            // Apply saved ratio after the widget gets its first
            // allocation. Until then we don't know the total
            // size in pixels.
            const ratio_holder = try self.allocator.create(PanedRatioCtx);
            ratio_holder.* = .{
                .allocator = self.allocator,
                .ratio = splitRatio(s.ratio),
            };
            _ = c.g_signal_connect_data(
                paned,
                "notify::position",
                @ptrCast(&onPanedPositionChanged),
                @ptrCast(ratio_holder),
                @ptrCast(cast.destroyCtx(PanedRatioCtx)),
                c.G_CONNECT_DEFAULT,
            );
            _ = c.g_signal_connect_data(
                paned,
                "map",
                @ptrCast(&applyPanedRatioMap),
                @ptrCast(ratio_holder),
                null,
                c.G_CONNECT_DEFAULT,
            );
            return paned;
        },
    }
}

/// Recently-closed tab ring: newest entry at the end, capped at
/// `MAX_CLOSED_TABS`. The entries' strings live in `arena`.
pub const ClosedTabs = struct {
    ring: std.ArrayList(winmod.ClosedTab) = .empty,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *ClosedTabs, gpa: std.mem.Allocator) void {
        self.ring.deinit(gpa);
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }
};

/// Snapshot a tab into the recently-closed ring before its panes
/// are torn down. Stores title + first-pane cwd + active profile.
/// Splits aren't preserved — the restore spawns a single shell.
pub fn captureClosedTab(self: *Window, page: *c.AdwTabPage, root: *c.GtkWidget) void {
    if (self.closed.arena == null) {
        self.closed.arena = std.heap.ArenaAllocator.init(self.allocator);
    }
    const arena = self.closed.arena.?.allocator();

    // Title (AdwTabPage owns the string; dup into our arena).
    const title_c = c.adw_tab_page_get_title(page);
    const title_dup: []const u8 = if (title_c == null) "Tab" else blk: {
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(title_c)));
        break :blk arena.dupe(u8, span) catch "Tab";
    };

    // Find the first pane in this page's tree → snapshot its cwd
    // + profile.
    var snap_cwd: ?[]const u8 = null;
    var snap_profile: ?[]const u8 = null;
    for (self.panes.items) |p| {
        if (winmod.widgetIsAncestor(root, p.widget())) {
            if (p.terminal.cwd) |c2| snap_cwd = arena.dupe(u8, c2) catch null;
            if (p.active_profile) |pn| snap_profile = arena.dupe(u8, pn) catch null;
            break;
        }
    }

    const entry: winmod.ClosedTab = .{
        .title = title_dup,
        .cwd = snap_cwd,
        .profile_name = snap_profile,
    };
    pushClosed(&self.closed.ring, self.allocator, entry);
}

/// How many closed tabs the restore ring remembers.
pub const MAX_CLOSED_TABS: usize = 16;

/// Append to the closed-tab ring, dropping the oldest entry once it
/// holds `MAX_CLOSED_TABS`.
pub fn pushClosed(ring: *std.ArrayList(winmod.ClosedTab), gpa: std.mem.Allocator, entry: winmod.ClosedTab) void {
    if (ring.items.len >= MAX_CLOSED_TABS) _ = ring.orderedRemove(0);
    ring.append(gpa, entry) catch {};
}

/// Pop the most-recently-closed tab and respawn it with its
/// captured title / cwd / profile. No-op when the ring is empty.
pub fn restoreLastClosed(self: *Window) void {
    if (self.closed.ring.items.len == 0) return;
    const entry = self.closed.ring.pop().?;
    // newShellTabWithProfile takes a NUL-terminated title.
    var title_buf: [256:0]u8 = undefined;
    const n = @min(entry.title.len, title_buf.len);
    @memcpy(title_buf[0..n], entry.title[0..n]);
    title_buf[n] = 0;
    const title_z: ?[*:0]const u8 = if (entry.title.len > 0) @ptrCast(&title_buf) else null;
    // The captured cwd is owned by closed.arena; the spawn path
    // dups it into the child PTY's env briefly so it's safe.
    const pane = self.spawnShellPaneOpts(entry.cwd, entry.profile_name) catch |err| {
        std.debug.print("sketerm: restore-closed-tab spawn failed: {s}\n", .{@errorName(err)});
        return;
    };
    // Wrap pane.widget() in a Box so layout reparenting works the
    // same as addTabWithProfile does.
    const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(wrapper, 1);
    c.gtk_widget_set_vexpand(wrapper, 1);
    c.gtk_box_append(@ptrCast(wrapper), pane.widget());
    const adw_page = self.appendOrInsertTab(wrapper, .{ .leaf = pane }, false);
    const title_for_page: [*:0]const u8 = title_z orelse "Tab";
    c.adw_tab_page_set_title(adw_page, title_for_page);
    c.adw_tab_page_set_tooltip(adw_page, title_for_page);
    _ = c.gtk_widget_grab_focus(@ptrCast(pane.surface.area));
}

/// Load the default last.json and rebuild tabs from it.
pub fn loadLayoutDefault(self: *Window) !bool {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try layout_mod.defaultSavePath(arena);
    var parsed = layout_mod.load(self.allocator, path) catch |err| {
        std.debug.print("sketerm: cannot load layout from {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer parsed.deinit();

    restoreTabsWithTree(self, parsed.value.tabs);
    return true;
}

pub fn loadLayoutFromPath(self: *Window, path: []const u8) !bool {
    if (std.mem.endsWith(u8, path, ".layout")) {
        return loadLayoutSimple(self, path);
    }
    var parsed = layout_mod.load(self.allocator, path) catch |err| {
        std.debug.print("sketerm: cannot load layout from {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer parsed.deinit();
    restoreTabsWithTree(self, parsed.value.tabs);
    return true;
}

/// Spawn every TabSpec, then re-apply the saved tab-tree nesting +
/// collapse state (tree-style tabs). Nesting is applied AFTER all
/// tabs exist so a parent index can point anywhere in the batch;
/// indexes are batch-relative, which also keeps `--layout` appends
/// (load into a window that already has tabs) correct.
fn restoreTabsWithTree(self: *Window, specs: []const layout_mod.TabSpec) void {
    var pages: std.ArrayList(?*c.AdwTabPage) = .empty;
    defer pages.deinit(self.allocator);
    for (specs) |tab| {
        self.last_created_page = null;
        self.newTabFromSpec(tab, true) catch |err| {
            std.debug.print("sketerm: load tab '{s}' failed: {s}\n", .{ tab.title, @errorName(err) });
        };
        pages.append(self.allocator, self.last_created_page) catch return;
    }
    if (applySavedNesting(&self.tab_forest, specs, pages.items)) self.forestChanged();
}

/// Re-apply a restored batch's saved nesting and collapse state;
/// `pages[i]` is tab i's page, or null when it failed to spawn. A
/// parent index that is out of range, names a failed tab or would
/// close a cycle leaves that tab a root. @return whether the forest
/// changed.
pub fn applySavedNesting(forest: anytype, specs: []const layout_mod.TabSpec, pages: anytype) bool {
    var changed = false;
    for (specs, 0..) |tab, i| {
        if (i >= pages.len) break;
        const page = pages[i] orelse continue;
        if (tab.tree_parent) |pi| {
            if (pi < pages.len) {
                if (pages[pi]) |parent| {
                    forest.reparent(page, parent, .last) catch {};
                    changed = true;
                }
            }
        }
        if (tab.collapsed) {
            forest.setCollapsed(page, true);
            changed = true;
        }
    }
    return changed;
}

pub fn loadLayoutSimple(self: *Window, path: []const u8) !bool {
    const layout_simple = @import("../layout_simple.zig");
    const bytes = (try readfile.sized(self.allocator, path, layout_simple.MAX_FILE_BYTES)) orelse {
        std.debug.print("sketerm: cannot read {s} (missing, empty or over {d} bytes)\n", .{ path, layout_simple.MAX_FILE_BYTES });
        return false;
    };
    defer self.allocator.free(bytes);
    var parsed = layout_simple.parse(self.allocator, bytes) catch |err| {
        std.debug.print("sketerm: parse {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer parsed.deinit();
    for (parsed.value.tabs) |tab| {
        self.newTabFromSpec(tab, true) catch |err| {
            std.debug.print("sketerm: load tab '{s}' failed: {s}\n", .{ tab.title, @errorName(err) });
        };
    }
    return true;
}

/// Build a Layout snapshot of the current window state.
/// Caller must arena-free or otherwise track strings.
pub fn collectLayout(self: *Window, arena: std.mem.Allocator) !layout_mod.Layout {
    var tabs: std.ArrayList(layout_mod.TabSpec) = .empty;
    // Pages in the order they were SERIALIZED, which is what
    // `tree_parent` indexes — the loop below skips tabs (no root
    // widget, or a tab whose every pane is transient), so a view
    // position is NOT a saved-array index. Writing one where the other
    // is read nested restored children under the wrong parent.
    var kept: std.ArrayList(*c.AdwTabPage) = .empty;
    defer kept.deinit(arena);
    const n_pages = c.adw_tab_view_get_n_pages(self.tab_view);
    var i: c_int = 0;
    while (i < n_pages) : (i += 1) {
        const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
        const wrapper = c.adw_tab_page_get_child(page);
        const root = c.gtk_widget_get_first_child(@ptrCast(wrapper));
        if (root == null) continue;

        const title_cstr = c.adw_tab_page_get_title(page);
        const title = if (title_cstr != null) std.mem.span(@as([*:0]const u8, @ptrCast(title_cstr))) else "";

        verifyTreeModel(self, page.?, root.?);
        // Model-based serialization (correct even while zoomed);
        // widget walk only as fallback for a missing model.
        // A tab whose every pane is transient (a DevTools view and
        // nothing else) serializes to nothing and is skipped, the same
        // way a tab with no root widget is.
        const tree = if (Window.tabTreeOf(page.?)) |t|
            (modelTreeToLayout(self, arena, t.root) catch continue) orelse continue
        else
            (collectTree(self, arena, root.?) catch continue) orelse continue;
        try tabs.append(arena, .{
            .title = try arena.dupe(u8, title),
            .tree = tree,
            .pinned = c.adw_tab_page_get_pinned(page) != 0,
            .color = if (Window.tabColorOf(page.?)) |col| try tabColorHex(arena, col) else null,
            .title_locked = c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-title-locked") != null,
            .show_activity = tab_effects.tabSettings(page.?).show_activity,
            .warn_inactive = tab_effects.tabSettings(page.?).warn_inactive,
            // Tree-style tabs: `tree_parent` is patched in below, once
            // every kept tab has an index; a parent can sit AFTER its
            // child in view order, so it cannot be resolved here.
            .tree_parent = null,
            .collapsed = self.tab_forest.isCollapsed(page.?),
        });
        try kept.append(arena, page.?);
    }
    // Second pass: parent pointers become indices into `tabs` (see
    // Forest.parentIndices for why a view position will not do).
    const parents = try arena.alloc(?u32, kept.items.len);
    self.tab_forest.parentIndices(kept.items, parents);
    for (parents, 0..) |p, idx| tabs.items[idx].tree_parent = p;
    return .{ .version = 2, .tabs = try tabs.toOwnedSlice(arena) };
}

/// A pane that PRESENTS a view it did not create — today only a
/// DevTools inspector, minted by the helper's `devtools_show` — has no
/// restorable state at all: `WebFace.paneState` would answer with an
/// empty address (the face has no url of its own), so the pane would
/// come back as a blank web pane. The inspector's own page is already
/// serialized by the pane that owns it, and a next-launch helper knows
/// nothing about the old view id, so the honest snapshot omits the
/// pane entirely and lets its split collapse onto the sibling.
fn isTransientFace(p: *Pane) bool {
    const wf = @import("webface.zig").WebFace.fromPane(p) orelse return false;
    return wf.attached;
}

/// Null when the subtree holds nothing worth restoring (see
/// `isTransientFace`); a split with one surviving child collapses to
/// that child.
pub fn collectTree(self: *Window, arena: std.mem.Allocator, w: *c.GtkWidget) !?layout_mod.Tree {
    const is_paned = c.g_type_check_instance_is_a(
        @ptrCast(@alignCast(w)),
        c.gtk_paned_get_type(),
    ) != 0;
    if (is_paned) {
        const start = c.gtk_paned_get_start_child(@ptrCast(w)) orelse return error.MissingChild;
        const end = c.gtk_paned_get_end_child(@ptrCast(w)) orelse return error.MissingChild;
        const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(w)));
        const total: c_int = if (orientation == c.GTK_ORIENTATION_HORIZONTAL)
            c.gtk_widget_get_width(w)
        else
            c.gtk_widget_get_height(w);
        const pos = c.gtk_paned_get_position(@ptrCast(w));
        const ratio = positionRatio(pos, total) orelse 0.5;
        const first = try collectTree(self, arena, start);
        const second = try collectTree(self, arena, end);
        return joinSplit(
            arena,
            if (orientation == c.GTK_ORIENTATION_HORIZONTAL) .horizontal else .vertical,
            ratio,
            first,
            second,
        );
    }

    // Leaf — find the Pane that owns this widget.
    for (self.panes.items) |p| {
        if (@intFromPtr(p.widget()) == @intFromPtr(w)) {
            if (isTransientFace(p)) return null;
            return .{ .pane = try paneSpec(self, arena, p) };
        }
    }
    return error.PaneNotFound;
}

/// Serialize one pane's restore state (cwd, command, profile,
/// shader, mux session) — shared by the model- and widget-based
/// layout walkers.
pub fn paneSpec(self: *Window, arena: std.mem.Allocator, p: *Pane) !layout_mod.PaneSpec {
    {
        {
            // OSC 7 cwd if the shell reported it, else "/". (The shell
            // runs under the mux daemon now — there's no local pid to
            // resolve /proc against; the daemon-side cwd rides `list`.)
            const cwd: []const u8 = if (p.terminal.cwd) |reported|
                try arena.dupe(u8, reported)
            else
                try arena.dupe(u8, "/");
            // Serialize the command the pane was actually spawned
            // with; fall back to $SHELL for panes without a record.
            const cmd: [][]const u8 = if (p.spawn_argv) |av| blk: {
                const out = try arena.alloc([]const u8, av.len);
                for (av, 0..) |a, i| out[i] = try arena.dupe(u8, a);
                break :blk out;
            } else blk: {
                const out = try arena.alloc([]const u8, 1);
                out[0] = try arena.dupe(u8, @import("../util/profile.zig").getenv("SHELL") orelse "/bin/bash");
                break :blk out;
            };
            // Save font_size only if it diverges from the pane's
            // profile settings — keeps layout files terse.
            const base_fs = self.config.profileSettings(p.active_profile orelse "").font_size;
            const fs: ?u16 = if (p.surface.font_size != base_fs) p.surface.font_size else null;
            // Carry profile name so split-tree restore / duplicate
            // can reapply per-pane profile overrides.
            const prof: []const u8 = if (p.active_profile) |pn|
                try arena.dupe(u8, pn)
            else
                "";
            // Explicit shader pick travels with the layout;
            // profile/global shaders re-resolve on restore.
            const shader: []const u8 = if (p.surface.custom_shader_user)
                (if (p.surface.custom_shader_path) |sp| try arena.dupe(u8, sp) else "")
            else
                "";
            const preset: []const u8 = if (p.surface.preset_name) |pn|
                try arena.dupe(u8, pn)
            else
                "";
            // Durable mux panes: session + transport so restore can
            // reattach (or recreate under the same name). Skip EPHEMERAL
            // (GUI-owned local) sessions — they're killed on quit, so
            // saving their name would make restore recreate a non-ephemeral
            // session (leaking it + losing env parity). They restore as a
            // plain command/cwd local pane instead, re-routed through
            // daemonSpawnPane (which re-marks them ephemeral).
            var mux_session: []const u8 = "";
            var mux_host: []const u8 = "";
            if (p.terminal.remote) |r| {
                if (!r.ephemeral) {
                    mux_session = try arena.dupe(u8, r.session);
                    if (r.host) |h| mux_host = try arena.dupe(u8, h);
                }
            }
            // Placeholder for an async remote reattach still in
            // flight: keep the saved mux identity so quitting
            // mid-connect doesn't demote the pane to a plain shell.
            if (mux_session.len == 0) {
                if (muxtabs.muxRestoreJobFor(self, p.id)) |job| {
                    mux_session = try arena.dupe(u8, job.session);
                    mux_host = try arena.dupe(u8, job.host);
                }
            }
            // Browser face: persist the internal tab paths so a
            // restore reopens the same locations.
            const browser_tabs: []const []const u8 = blk: {
                const bv = @import("browser.zig").BrowserView.fromPane(p) orelse
                    break :blk &[_][]const u8{};
                break :blk try bv.tabPaths(arena);
            };
            const browser_state = blk: {
                const bv = @import("browser.zig").BrowserView.fromPane(p) orelse break :blk null;
                break :blk try bv.paneState(arena);
            };
            // Editor face: open file specs + cursors (dirty buffers
            // are not persisted).
            // Web face: address + zoom (no scroll offset — the helper
            // protocol reports none).
            const web_state = blk: {
                const g = @import("webgroup.zig").Group.fromPane(p) orelse break :blk null;
                const st = try g.paneState(arena);
                // Every page was transient (a lone DevTools inspector):
                // nothing to restore, same as having no web face.
                if (st.pages.len == 0) break :blk null;
                break :blk st;
            };
            const editor_state = blk: {
                const ev = @import("editorview.zig").EditorView.fromPane(p) orelse break :blk null;
                const state = try ev.paneState(arena);
                if (state.files.len == 0) break :blk null;
                break :blk state;
            };
            return .{
                .cwd = cwd,
                .command = cmd,
                .font_size = fs,
                .profile = prof,
                .custom_shader = shader,
                .shader_preset = preset,
                .shader_cleared = p.surface.shader_cleared,
                .mux_session = mux_session,
                .mux_host = mux_host,
                .browser_tabs = browser_tabs,
                .browser = browser_state,
                .editor = editor_state,
                .web = web_state,
            };
        }
    }
}

/// Serialize a model node to a layout tree. Split ratios are
/// read live from the view handle (the GtkPaned) at save time. Null
/// when the subtree holds nothing worth restoring — see
/// `isTransientFace`.
pub fn modelTreeToLayout(self: *Window, arena: std.mem.Allocator, node: PaneTree.Node) !?layout_mod.Tree {
    switch (node) {
        .leaf => |p| {
            if (isTransientFace(p)) return null;
            return .{ .pane = try paneSpec(self, arena, p) };
        },
        .split => |sp| {
            var ratio: f32 = splitRatio(sp.ratio);
            if (sp.view) |v| {
                const paned: *c.GtkWidget = @ptrCast(@alignCast(v));
                const total: c_int = if (sp.orientation == .horizontal)
                    c.gtk_widget_get_width(paned)
                else
                    c.gtk_widget_get_height(paned);
                const pos = c.gtk_paned_get_position(@ptrCast(paned));
                if (positionRatio(pos, total)) |r| ratio = r;
            }
            const first = try modelTreeToLayout(self, arena, sp.children[0]);
            const second = try modelTreeToLayout(self, arena, sp.children[1]);
            return joinSplit(
                arena,
                if (sp.orientation == .horizontal) .horizontal else .vertical,
                ratio,
                first,
                second,
            );
        },
    }
}

/// SKETERM_VERIFY_TREE=1: structural cross-check of the tree
/// model against the live widget tree. Skipped while a pane is
/// zoomed (zoom reparents widgets; the model is authoritative).
pub fn verifyTreeModel(self: *Window, page: *c.AdwTabPage, root_widget: *c.GtkWidget) void {
    const S = struct {
        var enabled: ?bool = null;
    };
    if (S.enabled == null) S.enabled = c.getenv("SKETERM_VERIFY_TREE") != null;
    if (!S.enabled.?) return;
    if (self.zoom_pane != null) return;
    const t = Window.tabTreeOf(page) orelse {
        std.debug.print("sketerm: VERIFY: page has no tree model\n", .{});
        return;
    };
    if (!widgetMatchesNode(self, root_widget, t.root)) {
        std.debug.print("sketerm: VERIFY FAILED: tree model diverges from widget tree\n", .{});
        // Test-only env var: die loudly so the e2e harness fails.
        c.abort();
    }
}

/// Verify every tab's model (SKETERM_VERIFY_TREE only; no-op
/// otherwise). Called after each tree mutation.
pub fn verifyAllTabs(self: *Window) void {
    if (c.getenv("SKETERM_VERIFY_TREE") == null) return;
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
        const wrapper = c.adw_tab_page_get_child(page) orelse continue;
        const root = c.gtk_widget_get_first_child(@ptrCast(wrapper)) orelse continue;
        verifyTreeModel(self, page, root);
    }
    verifyTabForest(self);
}

/// SKETERM_VERIFY_TREE=1: cross-check the tab FOREST (tree-style
/// tabs) against the AdwTabView page set — every live page has
/// exactly one node, no orphan nodes, links consistent/acyclic.
/// Aborts on divergence, like verifyTreeModel.
pub fn verifyTabForest(self: *Window) void {
    if (c.getenv("SKETERM_VERIFY_TREE") == null) return;
    if (self.destroying) return;
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    var fail: ?[]const u8 = null;
    if (!self.tab_forest.validate()) {
        fail = "forest links inconsistent";
    } else if (self.tab_forest.count() != @as(usize, @intCast(n))) {
        fail = "forest node count != page count";
    } else {
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, i) orelse continue;
            if (self.tab_forest.find(page) == null) {
                fail = "page missing from forest";
                break;
            }
        }
    }
    if (fail) |msg| {
        std.debug.print("sketerm: VERIFY FAILED: tab forest diverges: {s}\n", .{msg});
        c.abort();
    }
}

pub fn widgetMatchesNode(self: *Window, w: *c.GtkWidget, node: PaneTree.Node) bool {
    const is_paned = c.g_type_check_instance_is_a(
        @ptrCast(@alignCast(w)),
        c.gtk_paned_get_type(),
    ) != 0;
    switch (node) {
        .leaf => |p| return !is_paned and @intFromPtr(p.widget()) == @intFromPtr(w),
        .split => |sp| {
            if (!is_paned) return false;
            const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(w)));
            const want_horiz = sp.orientation == .horizontal;
            if ((orientation == c.GTK_ORIENTATION_HORIZONTAL) != want_horiz) return false;
            const start = c.gtk_paned_get_start_child(@ptrCast(w)) orelse return false;
            const end = c.gtk_paned_get_end_child(@ptrCast(w)) orelse return false;
            return widgetMatchesNode(self, start, sp.children[0]) and
                widgetMatchesNode(self, end, sp.children[1]);
        },
    }
}

/// Sketerm's own picker for save-as; user picks a path, we serialize
/// the current layout to it. Defaults to .json (the authoritative
/// format) — pick `.layout` if you want the simple DSL but only JSON
/// is implemented for save right now.
pub fn saveLayoutAs(self: *Window) void {
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .save_file,
            .title = "Save Layout",
            .suggested_name = "layout.json",
            .filters = &.{.{ .label = "Layouts", .patterns = &.{"*.json"} }},
        },
        &onSaveLayoutAsDone,
        @ptrCast(self),
    ) catch |err| {
        reportLayoutSaveError(self, err);
        return;
    };
}

/// Pick a saved layout (.json/.layout) and append its tabs to the
/// current window — same semantics as the `--layout` CLI flag
/// (existing tabs are kept).
pub fn loadLayoutAs(self: *Window) void {
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .open_file,
            .title = "Load Layout",
            .filters = &.{.{ .label = "Layouts", .patterns = &.{ "*.json", "*.layout" } }},
        },
        &onLoadLayoutDone,
        @ptrCast(self),
    ) catch return;
}

/// Save current state to the default path.
pub fn saveLayoutToDefault(self: *Window) !void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try layout_mod.defaultSavePath(arena);
    const layout = try self.collectLayout(arena);
    try layout_mod.save(self.allocator, layout, path);
}

/// Save current state to the default path. Non-fatal: a failure is
/// logged, never raised. Runs at shutdown too, where a toast could
/// not be seen and a dialog would block teardown - so stderr (the
/// GUI's log channel) is the only report.
pub fn saveLayoutQuietly(self: *Window) void {
    saveLayoutToDefault(self) catch |err| logActionError("save_layout", err);
}

/// Duplicate the focused tab — spawn a new tab inheriting the
/// focused pane's cwd and profile. Splits in the source tab are
/// NOT replicated (the new tab gets one shell pane); cloning a
/// full split tree would duplicate the layout snapshot/restore
/// path, which is a bigger feature. Most user value is "open
/// another shell here in this dir as this profile."
pub fn duplicateCurrentTab(self: *Window) void {
    const pane = self.focusedPane() orelse return;

    // Detect single-pane vs split-tree by inspecting the tab page's
    // root widget. Single-pane case wins by preserving the profile
    // (which TabSpec doesn't carry today). Split-tree case loses
    // profile-per-pane but keeps the layout — picked over the
    // alternative of flattening to one pane and dropping the
    // splits the user spent time arranging.
    const sel = c.adw_tab_view_get_selected_page(self.tab_view) orelse {
        self.newShellTabWithProfile(null, pane.active_profile) catch |err| logActionError("duplicate_tab", err);
        return;
    };
    const wrapper = c.adw_tab_page_get_child(sel);
    const root = if (wrapper != null) c.gtk_widget_get_first_child(@ptrCast(wrapper)) else null;
    const is_paned = root != null and c.g_type_check_instance_is_a(
        @ptrCast(@alignCast(root.?)),
        c.gtk_paned_get_type(),
    ) != 0;

    if (!is_paned) {
        // Single pane — use the profile-aware fast path.
        self.newShellTabWithProfile(null, pane.active_profile) catch |err| {
            std.debug.print("sketerm: duplicate tab failed: {s}\n", .{@errorName(err)});
        };
        return;
    }

    // Split tree — round-trip via the tree model → newTabFromSpec
    // (widget walk only as fallback for a missing model).
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tree_opt = (if (Window.tabTreeOf(sel)) |t|
        modelTreeToLayout(self, arena, t.root)
    else
        collectTree(self, arena, root.?)) catch |err| {
        std.debug.print("sketerm: duplicate split tree failed: {s}\n", .{@errorName(err)});
        return;
    };
    // Everything in the tab was transient (a lone DevTools pane): fall
    // back to a plain shell tab rather than duplicating nothing.
    const tree = tree_opt orelse {
        self.newShellTabWithProfile(null, pane.active_profile) catch |err| {
            std.debug.print("sketerm: duplicate tab failed: {s}\n", .{@errorName(err)});
        };
        return;
    };

    const title_cstr = c.adw_tab_page_get_title(sel);
    const title = if (title_cstr != null)
        std.mem.span(@as([*:0]const u8, @ptrCast(title_cstr)))
    else
        "shell";

    const spec = layout_mod.TabSpec{
        .title = arena.dupe(u8, title) catch return,
        .tree = tree,
        .pinned = false, // duplicates start unpinned
    };
    self.newTabFromSpec(spec, false) catch |err| {
        std.debug.print("sketerm: duplicate split tree failed: {s}\n", .{@errorName(err)});
    };
}

/// Save current state as the "default" layout that's auto-loaded
/// on subsequent cold starts (no --layout / --restore needed).
/// Best-effort; user gets stderr feedback on failure.
pub fn saveDefaultLayout(self: *Window) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = layout_mod.defaultLayoutPath(arena) catch |err| {
        std.debug.print("sketerm: default layout path failed: {s}\n", .{@errorName(err)});
        reportLayoutSaveError(self, err);
        return;
    };
    const layout = self.collectLayout(arena) catch |err| {
        std.debug.print("sketerm: collect layout failed: {s}\n", .{@errorName(err)});
        reportLayoutSaveError(self, err);
        return;
    };
    layout_mod.save(self.allocator, layout, path) catch |err| {
        std.debug.print("sketerm: save default layout to {s} failed: {s}\n", .{ path, @errorName(err) });
        reportLayoutSaveError(self, err);
        return;
    };
    std.debug.print("sketerm: saved default layout to {s}\n", .{path});
    winmod.showToast(self, "Default layout saved");
}

/// Load $XDG_STATE_HOME/sketerm/default.json if it exists. Returns
/// false silently when the file isn't there (the common case on a
/// fresh install). Distinct from loadLayoutDefault, which targets
/// last.json under --restore.
pub fn loadDefaultLayoutIfPresent(self: *Window) !bool {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try layout_mod.defaultLayoutPath(arena);
    // Existence check via libc. F_OK = 0 in POSIX; Aro translates
    // the F_OK macro fine but it's only accessible inside `c.`.
    var path_z: [4096]u8 = undefined;
    const p = pathZ(&path_z, path) catch return false;
    if (c.access(p, c.F_OK) != 0) return false;

    var parsed = layout_mod.load(self.allocator, path) catch |err| {
        std.debug.print("sketerm: cannot load default layout {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer parsed.deinit();

    for (parsed.value.tabs) |tab| {
        self.newTabFromSpec(tab, true) catch |err| {
            std.debug.print("sketerm: load tab '{s}' failed: {s}\n", .{ tab.title, @errorName(err) });
        };
    }
    return true;
}

/// A null result (cancel, or the parent window tearing the picker
/// down) must not touch `self` — the Window may already be gone.
pub fn onSaveLayoutAsDone(user: ?*anyopaque, result: ?fpicker.Result) void {
    const res = result orelse return;
    if (res.specs.len == 0) return;
    const self = cast.userData(Window, user);
    // layout_mod.save writes with local libc; a remote pick cannot be
    // honoured, and silence would read as a broken dialog.
    const path = picker.localPathOrRefuse(@ptrCast(self.app_window), res.specs[0], "Sketerm writes layout files with local file access — pick a location on this machine.") orelse return;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layout = self.collectLayout(arena) catch |err| {
        reportLayoutSaveError(self, err);
        return;
    };
    layout_mod.save(self.allocator, layout, path) catch |err| {
        std.debug.print("sketerm: save layout to {s} failed: {s}\n", .{ path, @errorName(err) });
        reportLayoutSaveError(self, err);
        return;
    };
    winmod.showToast(self, "Layout saved");
}

fn reportLayoutSaveError(self: *Window, err: anyerror) void {
    logActionError("save_layout", err);
    var msg: [192]u8 = undefined;
    winmod.showToast(
        self,
        std.fmt.bufPrint(&msg, "Could not save layout: {s}", .{@errorName(err)}) catch "Could not save layout",
    );
}

pub fn onLoadLayoutDone(user: ?*anyopaque, result: ?fpicker.Result) void {
    const res = result orelse return;
    if (res.specs.len == 0) return;
    const self = cast.userData(Window, user);
    // layout_mod.load reads with local libc — remote picks are refused.
    const path = picker.localPathOrRefuse(@ptrCast(self.app_window), res.specs[0], "Sketerm reads layout files with local file access — pick a file on this machine.") orelse return;
    // Load into a fresh window so the current window's tabs are left intact
    // (and the restored tabs keep their saved order). Fall back to this
    // window if spawning one fails.
    const target = self.spawnSecondaryWindow() orelse self;
    const ok = target.loadLayoutFromPath(path) catch |err| blk: {
        std.debug.print("sketerm: load layout failed: {s}\n", .{@errorName(err)});
        break :blk false;
    };
    // Nothing loaded into the brand-new window — don't leave it empty.
    if (!ok and target != self) c.gtk_window_close(@ptrCast(target.app_window));
}

pub fn applyPanedRatioMap(paned: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    applyPanedRatioImpl(paned, user);
}

/// notify::position fires when the user drags the divider AND when the
/// paned itself re-allocates on window resize. We re-snap to the
/// device-pixel grid (see `alignmentForScale`) so GtkGraphicsOffload
/// keeps engaging at fractional scale, and update ratio so the next
/// remap and layout save reflect the snapped position.
pub fn onPanedPositionChanged(paned: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(PanedRatioCtx, user);
    if (ctx.setting) return;
    const w: *c.GtkWidget = @ptrCast(paned);
    const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(w)));
    const total: c_int = if (orientation == c.GTK_ORIENTATION_HORIZONTAL)
        c.gtk_widget_get_width(w)
    else
        c.gtk_widget_get_height(w);
    if (total <= 0) return;
    const pos = c.gtk_paned_get_position(@ptrCast(w));
    if (pos <= 0) return;

    const m = winmod.alignmentForScale(winmod.widgetSurfaceScale(w));
    const snapped = winmod.snapDown(pos, m);
    if (snapped != pos) {
        ctx.setting = true;
        c.gtk_paned_set_position(@ptrCast(w), snapped);
        ctx.setting = false;
    }
    ctx.ratio = @as(f32, @floatFromInt(snapped)) / @as(f32, @floatFromInt(total));
}

pub fn applyPanedRatioImpl(paned: *c.GtkWidget, user: ?*anyopaque) void {
    const ctx = cast.userData(PanedRatioCtx, user);
    const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(paned)));
    const total: c_int = if (orientation == c.GTK_ORIENTATION_HORIZONTAL)
        c.gtk_widget_get_width(paned)
    else
        c.gtk_widget_get_height(paned);
    if (total <= 0) return;
    const raw_pos: c_int = @intFromFloat(@as(f32, @floatFromInt(total)) * ctx.ratio);
    const m = winmod.alignmentForScale(winmod.widgetSurfaceScale(paned));
    const pos = winmod.snapDown(raw_pos, m);
    ctx.setting = true;
    c.gtk_paned_set_position(@ptrCast(paned), pos);
    ctx.setting = false;
}

// -- layout <-> tree decisions, free of widgets ---------------------------

const web_model = @import("../web/model.zig");

/// Refuse a spec that `buildTreeWidget` would reject halfway, before
/// any of it is built: by then the panes it had spawned for earlier
/// subtrees were left running with no tab. A split needs two children;
/// a pane needs a command unless it reattaches a local durable session.
pub fn validateTree(tree: layout_mod.Tree) error{ InvalidLayout, EmptyCommand }!void {
    switch (tree) {
        .pane => |p| {
            const local_reattach = p.mux_session.len > 0 and p.mux_host.len == 0;
            if (p.command.len == 0 and !local_reattach) return error.EmptyCommand;
        },
        .split => |s| {
            if (s.children.len < 2) return error.InvalidLayout;
            try validateTree(s.children[0]);
            try validateTree(s.children[1]);
        },
    }
}

/// Whether a restored tab's title stays locked against OSC updates; a
/// file written before the flag existed counts as renamed, because
/// restored titles never followed OSC then.
pub fn restoresTitleLocked(saved: ?bool) bool {
    return saved orelse true;
}

/// A saved split ratio, or an even split when it is missing or would
/// hide one side (anything outside the open interval 0..1, NaN too).
pub fn splitRatio(r: f32) f32 {
    return if (r > 0 and r < 1) r else 0.5;
}

/// A divider position as a fraction of the paned's size; null before
/// the paned has been allocated.
pub fn positionRatio(pos: c_int, total: c_int) ?f32 {
    if (total <= 0) return null;
    return @as(f32, @floatFromInt(pos)) / @as(f32, @floatFromInt(total));
}

/// A saved split, collapsed onto the surviving child when the other
/// serialized to nothing; null when neither did.
pub fn joinSplit(
    arena: std.mem.Allocator,
    orientation: layout_mod.Orient,
    ratio: f32,
    first: ?layout_mod.Tree,
    second: ?layout_mod.Tree,
) !?layout_mod.Tree {
    const a = first orelse return second;
    const b = second orelse return a;
    const children = try arena.alloc(layout_mod.Tree, 2);
    children[0] = a;
    children[1] = b;
    return .{ .split = .{ .orientation = orientation, .ratio = ratio, .children = children } };
}

/// Argument `i` a restored pane spawns with: the profile's shell
/// replaces command[0], so duplicating an "ssh" profile keeps using
/// ssh even after a layout round-trip captured the current $SHELL.
pub fn restoredArg(i: usize, cmd: []const u8, profile_shell: ?[]const u8) []const u8 {
    if (i == 0) {
        if (profile_shell) |sh| return sh;
    }
    return cmd;
}

/// A tab colour as the "#rrggbb" a layout stores.
pub fn tabColorHex(arena: std.mem.Allocator, col: [3]u8) ![]u8 {
    return std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}", .{ col[0], col[1], col[2] });
}

/// What page 0 of a saved web face restores as.
pub const FirstWebPage = struct {
    /// Null for a blank page, which comes back with its address bar
    /// focused.
    url: ?[]const u8,
    /// The saved identity container. A plain attach would put the page
    /// in the default jar, so a "Work" tab came back looking right
    /// (the tab colour is restored separately) while browsing as nobody.
    container: u32,
    zoom_level_x100: i16,
    /// Null for a layout written before pages existed, which saved no
    /// scroll position.
    scroll: ?struct { x: i32, y: i32 },
};

/// Page 0, not the active page: the group rebuilds the others with
/// their nesting and re-selects the active one. A layout from before
/// pages existed has an empty list and falls back to its single
/// address.
pub fn firstWebPage(w: web_model.PaneState) FirstWebPage {
    if (w.pages.len > 0) {
        const p = w.pages[0];
        return .{
            .url = if (p.url.len > 0) p.url else null,
            .container = p.container,
            .zoom_level_x100 = p.zoom_level_x100,
            .scroll = .{ .x = p.scroll_x, .y = p.scroll_y },
        };
    }
    return .{
        .url = if (w.url.len > 0) w.url else null,
        .container = w.container,
        .zoom_level_x100 = w.zoom_level_x100,
        .scroll = null,
    };
}

// -- tests --------------------------------------------------------------

const testing = std.testing;

test "a split ratio that would hide a side restores as an even split" {
    try testing.expectEqual(@as(f32, 0.3), splitRatio(0.3));
    try testing.expectEqual(@as(f32, 0.5), splitRatio(0));
    try testing.expectEqual(@as(f32, 0.5), splitRatio(1));
    try testing.expectEqual(@as(f32, 0.5), splitRatio(-0.2));
    try testing.expectEqual(@as(f32, 0.5), splitRatio(7.5));
    try testing.expectEqual(@as(f32, 0.5), splitRatio(std.math.nan(f32)));
}

test "a divider position becomes a fraction only once the paned has a size" {
    try testing.expectEqual(@as(?f32, 0.25), positionRatio(300, 1200));
    try testing.expectEqual(@as(?f32, null), positionRatio(300, 0));
    try testing.expectEqual(@as(?f32, null), positionRatio(0, -1));
}

test "a split whose child saved nothing collapses onto the survivor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left: layout_mod.Tree = .{ .pane = .{ .cwd = "/left", .command = &.{"sh"} } };
    const right: layout_mod.Tree = .{ .pane = .{ .cwd = "/right", .command = &.{"sh"} } };

    const both = (try joinSplit(a, .vertical, 0.25, left, right)).?;
    try testing.expectEqual(layout_mod.Orient.vertical, both.split.orientation);
    try testing.expectEqual(@as(f32, 0.25), both.split.ratio);
    try testing.expectEqual(@as(usize, 2), both.split.children.len);
    try testing.expectEqualStrings("/left", both.split.children[0].pane.cwd);
    try testing.expectEqualStrings("/right", both.split.children[1].pane.cwd);

    try testing.expectEqualStrings("/right", (try joinSplit(a, .horizontal, 0.5, null, right)).?.pane.cwd);
    try testing.expectEqualStrings("/left", (try joinSplit(a, .horizontal, 0.5, left, null)).?.pane.cwd);
    try testing.expect((try joinSplit(a, .horizontal, 0.5, null, null)) == null);
}

test "a profile's shell replaces only the first saved argument" {
    try testing.expectEqualStrings("ssh", restoredArg(0, "/bin/zsh", "ssh"));
    try testing.expectEqualStrings("-l", restoredArg(1, "-l", "ssh"));
    try testing.expectEqualStrings("/bin/zsh", restoredArg(0, "/bin/zsh", null));
}

test "a title restores locked unless the file says it was not renamed" {
    try testing.expect(restoresTitleLocked(null));
    try testing.expect(restoresTitleLocked(true));
    try testing.expect(!restoresTitleLocked(false));
}

test "a saved tab colour parses back to the same colour" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parse = @import("tabchrome.zig").parseHexRGB;
    for ([_][3]u8{ .{ 0x0a, 0x0b, 0xff }, .{ 0, 0, 0 }, .{ 255, 128, 1 } }) |col| {
        const hex = try tabColorHex(arena.allocator(), col);
        try testing.expectEqual(@as(usize, 7), hex.len);
        try testing.expectEqual(col, parse(hex).?);
    }
    try testing.expectEqualStrings("#0a0bff", try tabColorHex(arena.allocator(), .{ 0x0a, 0x0b, 0xff }));
}

test "a web face restores page 0 of its pages, or the single address of an old file" {
    const pages = [_]web_model.PageState{
        .{ .url = "", .container = 7, .zoom_level_x100 = -100, .scroll_x = 4, .scroll_y = 90 },
        .{ .url = "https://b.example", .container = 2, .parent = 0 },
    };
    // `url`/`container` at the top describe the ACTIVE page (page 1
    // here); restore still starts from page 0.
    const multi = firstWebPage(.{ .url = "https://b.example", .container = 2, .pages = &pages, .active_page = 1 });
    try testing.expectEqual(@as(?[]const u8, null), multi.url);
    try testing.expectEqual(@as(u32, 7), multi.container);
    try testing.expectEqual(@as(i16, -100), multi.zoom_level_x100);
    try testing.expectEqual(@as(i32, 4), multi.scroll.?.x);
    try testing.expectEqual(@as(i32, 90), multi.scroll.?.y);

    const old = firstWebPage(.{ .url = "https://a.example", .zoom_level_x100 = 200, .container = 3 });
    try testing.expectEqualStrings("https://a.example", old.url.?);
    try testing.expectEqual(@as(u32, 3), old.container);
    try testing.expectEqual(@as(i16, 200), old.zoom_level_x100);
    try testing.expect(old.scroll == null);

    try testing.expect(firstWebPage(.{}).url == null);
}

test "the closed-tab ring keeps the newest sixteen" {
    var ring: std.ArrayList(winmod.ClosedTab) = .empty;
    defer ring.deinit(testing.allocator);
    const titles = [_][]const u8{ "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15", "t16", "t17" };
    for (titles) |title| pushClosed(&ring, testing.allocator, .{ .title = title });
    try testing.expectEqual(MAX_CLOSED_TABS, ring.items.len);
    try testing.expectEqualStrings("t2", ring.items[0].title);
    try testing.expectEqualStrings("t17", ring.items[ring.items.len - 1].title);
}

const TF = @import("tabforest.zig").Forest(u32);

fn nestedSpec(parent: ?u32, collapsed: bool) layout_mod.TabSpec {
    return .{
        .title = "",
        .tree = .{ .pane = .{ .cwd = "/", .command = &.{"sh"} } },
        .tree_parent = parent,
        .collapsed = collapsed,
    };
}

fn flatForest(refs: []const u32) !TF {
    var f = TF.init(testing.allocator);
    errdefer f.deinit();
    for (refs) |r| _ = try f.add(r);
    return f;
}

test "saved nesting restores even when a parent comes after its child" {
    var f = try flatForest(&.{ 1, 2, 3, 4 });
    defer f.deinit();
    const specs = [_]layout_mod.TabSpec{
        nestedSpec(null, false),
        nestedSpec(0, false),
        // Points FORWARD: nesting is applied once every tab exists.
        nestedSpec(3, false),
        nestedSpec(0, true),
    };
    const pages = [_]?u32{ 1, 2, 3, 4 };
    try testing.expect(applySavedNesting(&f, &specs, &pages));
    try testing.expectEqual(@as(?u32, 1), f.parentOf(2));
    try testing.expectEqual(@as(?u32, 4), f.parentOf(3));
    try testing.expectEqual(@as(?u32, 1), f.parentOf(4));
    try testing.expect(f.isCollapsed(4));
    try testing.expect(f.isHidden(3));
    try testing.expect(f.validate());
}

test "nesting that cannot attach leaves the tab a root" {
    var f = try flatForest(&.{ 10, 30, 40, 50 });
    defer f.deinit();
    const specs = [_]layout_mod.TabSpec{
        nestedSpec(null, false),
        // Its own page failed to spawn: nothing to nest.
        nestedSpec(0, true),
        // Parent is the failed tab.
        nestedSpec(1, false),
        // Parent index past the end of the batch.
        nestedSpec(9, false),
        // Its own index: a cycle.
        nestedSpec(4, false),
    };
    const pages = [_]?u32{ 10, null, 30, 40, 50 };
    _ = applySavedNesting(&f, &specs, &pages);
    for ([_]u32{ 10, 30, 40, 50 }) |r| try testing.expectEqual(@as(?u32, null), f.parentOf(r));
    try testing.expect(f.validate());

    // Two tabs naming each other: the second link would close a cycle
    // and is refused, the first stands.
    var g = try flatForest(&.{ 1, 2 });
    defer g.deinit();
    const loop = [_]layout_mod.TabSpec{ nestedSpec(1, false), nestedSpec(0, false) };
    const both = [_]?u32{ 1, 2 };
    _ = applySavedNesting(&g, &loop, &both);
    try testing.expectEqual(@as(?u32, 2), g.parentOf(1));
    try testing.expectEqual(@as(?u32, null), g.parentOf(2));
    try testing.expect(g.validate());
}

test "a layout without nesting restores flat and reports no change" {
    var f = try flatForest(&.{ 1, 2 });
    defer f.deinit();
    const specs = [_]layout_mod.TabSpec{ nestedSpec(null, false), nestedSpec(null, false) };
    const pages = [_]?u32{ 1, 2 };
    try testing.expect(!applySavedNesting(&f, &specs, &pages));
    try testing.expectEqual(@as(?u32, null), f.parentOf(2));
}

test "nesting saved by index restores the same tree" {
    // The live tree: 1 > (2 > 3), 4 > 5, with 4 collapsed.
    var live = try flatForest(&.{ 1, 4 });
    defer live.deinit();
    _ = try live.addChild(2, 1, .last);
    _ = try live.addChild(3, 2, .last);
    _ = try live.addChild(5, 4, .last);
    live.setCollapsed(4, true);

    // Saved in strip order, as collectLayout does.
    const kept = [_]u32{ 1, 2, 3, 4, 5 };
    var parents: [kept.len]?u32 = undefined;
    live.parentIndices(&kept, &parents);
    var specs: [kept.len]layout_mod.TabSpec = undefined;
    for (kept, 0..) |ref, i| specs[i] = nestedSpec(parents[i], live.isCollapsed(ref));

    // Restored into a fresh, flat forest under new identities.
    var restored = try flatForest(&.{ 101, 102, 103, 104, 105 });
    defer restored.deinit();
    const pages = [_]?u32{ 101, 102, 103, 104, 105 };
    try testing.expect(applySavedNesting(&restored, &specs, &pages));
    for (kept, 0..) |ref, i| {
        const want: ?u32 = if (live.parentOf(ref)) |p| p + 100 else null;
        try testing.expectEqual(want, restored.parentOf(pages[i].?));
        try testing.expectEqual(live.isCollapsed(ref), restored.isCollapsed(pages[i].?));
    }
}

test "a malformed tree is refused whole, before any pane of it is built" {
    const ok_pane: layout_mod.Tree = .{ .pane = .{ .cwd = "/", .command = &.{"sh"} } };
    try validateTree(ok_pane);
    // A local durable session reattaches by name and needs no command...
    try validateTree(.{ .pane = .{ .cwd = "/", .command = &.{}, .mux_session = "work" } });
    // ...a remote one first spawns a local placeholder shell, which does.
    try testing.expectError(error.EmptyCommand, validateTree(.{ .pane = .{
        .cwd = "/",
        .command = &.{},
        .mux_session = "work",
        .mux_host = "ssh:box",
    } }));
    try testing.expectError(error.EmptyCommand, validateTree(.{ .pane = .{ .cwd = "/", .command = &.{} } }));

    // The fault sits in the SECOND child, after a valid first one that
    // building would already have spawned.
    const lonely = [_]layout_mod.Tree{ok_pane};
    const inner: layout_mod.Tree = .{ .split = .{ .orientation = .horizontal, .ratio = 0.5, .children = &lonely } };
    const outer_kids = [_]layout_mod.Tree{ ok_pane, inner };
    try testing.expectError(error.InvalidLayout, validateTree(.{ .split = .{
        .orientation = .vertical,
        .ratio = 0.5,
        .children = &outer_kids,
    } }));
    const bad_pane_kids = [_]layout_mod.Tree{ ok_pane, .{ .pane = .{ .cwd = "/", .command = &.{} } } };
    try testing.expectError(error.EmptyCommand, validateTree(.{ .split = .{
        .orientation = .vertical,
        .ratio = 0.5,
        .children = &bad_pane_kids,
    } }));
}

test "a hand-edited layout file with a one-child split is refused" {
    const json =
        \\{"version":2,"tabs":[{"title":"x","tree":{"split":{"orientation":"horizontal","ratio":0.5,
        \\"children":[{"pane":{"cwd":"/","command":["sh"]}}]}}}]}
    ;
    const parsed = try std.json.parseFromSlice(layout_mod.Layout, testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try testing.expectError(error.InvalidLayout, validateTree(parsed.value.tabs[0].tree));
}
