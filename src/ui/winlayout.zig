//! Layout persistence and tab-tree building — collect/save/load of
//! window layouts, closed-tab capture/restore, tree-model verification,
//! and the paned-ratio plumbing — split out of window.zig. Functions
//! keep the owning *Window receiver and are aliased back into Window.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
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


/// Spawn a new tab from a layout TabSpec (used on --restore).
/// Handles both v2 (tree) and v1-compat (cwd/command) fields. `at_end`
/// forces an append so a multi-tab restore keeps its saved order.
pub fn newTabFromSpec(self: *Window, spec: @import("../layout.zig").TabSpec, at_end: bool) !void {
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
    // deliberately named tab. Files predating the flag (null)
    // count as renamed — restored titles never followed OSC then.
    if (spec.title_locked orelse true) {
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

            var argv_buf = try self.allocator.alloc([*:0]const u8, p.command.len);
            defer self.allocator.free(argv_buf);
            var arg_owners: std.ArrayList([:0]u8) = .empty;
            defer {
                for (arg_owners.items) |s| self.allocator.free(s);
                arg_owners.deinit(self.allocator);
            }
            for (p.command, 0..) |cmd, i| {
                // The profile's shell overrides command[0] if
                // set, so duplicating an "ssh" profile keeps
                // using ssh even after a layout round-trip
                // captured the current $SHELL.
                const eff_cmd: []const u8 = if (i == 0 and profile != null and profile.?.settings.shell != null)
                    profile.?.settings.shell.?
                else
                    cmd;
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
                // their nesting. A layout from before pages existed has
                // an empty list and falls back to the single address.
                const first: ?[]const u8 = if (wstate.pages.len > 0)
                    (if (wstate.pages[0].url.len > 0) wstate.pages[0].url else null)
                else if (wstate.url.len > 0) wstate.url else null;
                // Page 0's identity container, saved with the layout. A
                // plain `attach` would put it in the default jar, so a
                // "Work" tab came back looking right (the tab colour is
                // restored separately) while actually browsing as
                // nobody — the failure this restores.
                const first_container: u32 = if (wstate.pages.len > 0)
                    wstate.pages[0].container
                else
                    wstate.container;
                if (webface.WebFace.attachContainer(self.allocator, pane, first, first_container)) |wf| {
                    wf.applyRestoredZoom(if (wstate.pages.len > 0)
                        wstate.pages[0].zoom_level_x100
                    else
                        wstate.zoom_level_x100);
                    if (wstate.pages.len > 0)
                        wf.applyRestoredScroll(wstate.pages[0].scroll_x, wstate.pages[0].scroll_y);
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
                .ratio = if (s.ratio > 0 and s.ratio < 1) s.ratio else 0.5,
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
                .ratio = if (s.ratio > 0 and s.ratio < 1) s.ratio else 0.5,
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

/// Snapshot a tab into the recently-closed ring before its panes
/// are torn down. Stores title + first-pane cwd + active profile.
/// Splits aren't preserved — the restore spawns a single shell.
pub fn captureClosedTab(self: *Window, page: *c.AdwTabPage, root: *c.GtkWidget) void {
    if (self.closed_arena == null) {
        self.closed_arena = std.heap.ArenaAllocator.init(self.allocator);
    }
    const arena = self.closed_arena.?.allocator();

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

    // Cap at 16; drop the oldest when full.
    const max_closed: usize = 16;
    if (self.closed_tabs.items.len >= max_closed) {
        _ = self.closed_tabs.orderedRemove(0);
    }
    self.closed_tabs.append(self.allocator, entry) catch {};
}

/// Pop the most-recently-closed tab and respawn it with its
/// captured title / cwd / profile. No-op when the ring is empty.
pub fn restoreLastClosed(self: *Window) void {
    if (self.closed_tabs.items.len == 0) return;
    const entry = self.closed_tabs.pop().?;
    // newShellTabWithProfile takes a NUL-terminated title.
    var title_buf: [256:0]u8 = undefined;
    const n = @min(entry.title.len, title_buf.len);
    @memcpy(title_buf[0..n], entry.title[0..n]);
    title_buf[n] = 0;
    const title_z: ?[*:0]const u8 = if (entry.title.len > 0) @ptrCast(&title_buf) else null;
    // The captured cwd is owned by closed_arena; the spawn path
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
    var changed = false;
    for (specs, 0..) |tab, i| {
        const page = pages.items[i] orelse continue;
        if (tab.tree_parent) |pi| {
            if (pi < pages.items.len) {
                if (pages.items[pi]) |parent| {
                    self.tab_forest.reparent(page, parent, .last) catch {};
                    changed = true;
                }
            }
        }
        if (tab.collapsed) {
            self.tab_forest.setCollapsed(page, true);
            changed = true;
        }
    }
    if (changed) self.forestChanged();
}

pub fn loadLayoutSimple(self: *Window, path: []const u8) !bool {
    const layout_simple = @import("../layout_simple.zig");
    // Zig 0.16's `std.fs.cwd().openFile` requires an `Io`. Use libc.
    var path_z: [4096]u8 = undefined;
    const p = pathZ(&path_z, path) catch {
        std.debug.print("sketerm: path too long: {s}\n", .{path});
        return false;
    };
    const fp = c.fopen(p, "rb") orelse {
        std.debug.print("sketerm: cannot open {s}\n", .{path});
        return false;
    };
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return false;
    const size_long = c.ftell(fp);
    if (size_long <= 0 or size_long > 1024 * 1024) return false;
    if (c.fseek(fp, 0, c.SEEK_SET) != 0) return false;
    const size: usize = @intCast(size_long);
    const bytes = self.allocator.alloc(u8, size) catch return false;
    defer self.allocator.free(bytes);
    if (c.fread(bytes.ptr, 1, size, fp) != size) {
        std.debug.print("sketerm: short read on {s}\n", .{path});
        return false;
    }
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
            .color = if (Window.tabColorOf(page.?)) |col|
                try std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}", .{ col[0], col[1], col[2] })
            else
                null,
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
        const ratio: f32 = if (total > 0)
            @as(f32, @floatFromInt(pos)) / @as(f32, @floatFromInt(total))
        else
            0.5;
        const first = try collectTree(self, arena, start);
        const second = try collectTree(self, arena, end);
        const a = first orelse return second;
        const b = second orelse return a;
        const children = try arena.alloc(layout_mod.Tree, 2);
        children[0] = a;
        children[1] = b;
        return .{ .split = .{
            .orientation = if (orientation == c.GTK_ORIENTATION_HORIZONTAL) .horizontal else .vertical,
            .ratio = ratio,
            .children = children,
        } };
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
            var ratio: f32 = if (sp.ratio > 0 and sp.ratio < 1) sp.ratio else 0.5;
            if (sp.view) |v| {
                const paned: *c.GtkWidget = @ptrCast(@alignCast(v));
                const total: c_int = if (sp.orientation == .horizontal)
                    c.gtk_widget_get_width(paned)
                else
                    c.gtk_widget_get_height(paned);
                const pos = c.gtk_paned_get_position(@ptrCast(paned));
                if (total > 0) ratio = @as(f32, @floatFromInt(pos)) / @as(f32, @floatFromInt(total));
            }
            const first = try modelTreeToLayout(self, arena, sp.children[0]);
            const second = try modelTreeToLayout(self, arena, sp.children[1]);
            const a = first orelse return second;
            const b = second orelse return a;
            const children = try arena.alloc(layout_mod.Tree, 2);
            children[0] = a;
            children[1] = b;
            return .{ .split = .{
                .orientation = if (sp.orientation == .horizontal) .horizontal else .vertical,
                .ratio = ratio,
                .children = children,
            } };
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
