//! The command catalogue — every palette row as DATA, with no widget
//! anywhere in sight.
//!
//! This used to be built inside `palette.zig`'s `open()`, interleaved
//! with AdwActionRow construction, which meant the command set could
//! not be queried unless a dialog was on screen. That was the concrete
//! blocker on "the omnibox and the palette become ONE system"
//! (docs/proposal-browser.md): a source you can only run from inside a
//! dialog cannot be installed in another surface. Here the rows are a
//! plain slice and `source()` hands them to `suggest.merge` from
//! anywhere — a palette, an omnibox, or a test.
//!
//! GTK-free, so it lives in BOTH test roots. Icon names are carried as
//! strings and resolved by whichever view renders them.

const std = @import("std");
const Action = @import("action.zig").Action;
const ecmd = @import("../editor/commands.zig");
const suggest = @import("../util/suggest.zig");

pub const Kind = enum {
    /// Dispatched through `Window.dispatchAction`.
    action,
    /// Run against the focused pane's editor view.
    editor,
    /// Opens a durable tab on a configured `[domain.<name>]` host.
    domain,
};

pub const Row = struct {
    icon: [:0]const u8,
    title: [:0]const u8,
    desc: [:0]const u8,
    kind: Kind = .action,
    /// Meaningful for `.action` (and left at a harmless default for
    /// the other kinds, which dispatch through their own field).
    action: Action = .command_palette,
    /// `.domain`: the transport-prefixed host spec `newDurableTab`
    /// takes. Borrowed from the caller's arena.
    host: []const u8 = "",
    /// `.editor`: the command to run on the focused editor view.
    editor_cmd: ?ecmd.Command = null,
};

/// What varies between two palette openings. Everything else about the
/// catalogue is static.
pub const Context = struct {
    /// The focused pane wears an editor face, so the editor-command
    /// rows are worth offering.
    editor: bool = false,
    domains: []const DomainRow = &.{},
};

/// A configured `[domain.<name>]`, flattened by the caller so this
/// module needs no `config.zig` import (and no allocator to resolve
/// `hostSpec`).
pub const DomainRow = struct {
    name: []const u8,
    /// Transport-prefixed, as `Config.Domain.hostSpec` renders it.
    host_spec: []const u8,
    /// Title and subtitle, pre-formatted by the caller because they
    /// need an allocator and this module takes none.
    title: [:0]const u8,
    desc: [:0]const u8,
};

/// Curated action set — every row that "makes sense" in a discoverable
/// list. Actions reachable only via context-menu / per-pane chords
/// are intentionally excluded; keybind-only actions where the chord
/// is the entire UX (Alt+digit goto-tab) are excluded too.
pub const curated = [_]Row{
    // Clipboard
    .{ .icon = "edit-copy-symbolic", .title = "Copy",
       .desc = "Copy the selected text to the clipboard.", .action = .copy_selection },
    .{ .icon = "edit-paste-symbolic", .title = "Paste",
       .desc = "Paste clipboard contents at the cursor.", .action = .paste_clipboard },
    .{ .icon = "edit-select-all-symbolic", .title = "Select All",
       .desc = "Select the whole buffer: scrollback ring plus the visible screen.", .action = .select_all },
    .{ .icon = "open-menu-symbolic", .title = "Context Menu",
       .desc = "Open the pane's right-click menu at the text cursor (Menu key / Shift+F10).", .action = .context_menu },
    .{ .icon = "view-fullscreen-symbolic", .title = "Copy Screen",
       .desc = "Copy the entire visible terminal area.", .action = .copy_screen },
    .{ .icon = "document-save-symbolic", .title = "Copy Scrollback",
       .desc = "Copy the full scrollback buffer plus the visible screen.", .action = .copy_scrollback },
    .{ .icon = "utilities-terminal-symbolic", .title = "Copy Command Output",
       .desc = "Copy the output of the last command (needs OSC 133 shell integration).", .action = .copy_command_output },
    .{ .icon = "find-location-symbolic", .title = "Keyboard Hints",
       .desc = "Label matches on screen; type a label to act on one. Shift copies, Alt pastes, Tab collects several.", .action = .hints_open },
    .{ .icon = "edit-select-all-symbolic", .title = "Copy Mode",
       .desc = "Keyboard-driven selection: vi motions (w/e/b, H/M/L, %, f), select with v, copy with y.", .action = .copy_mode },
    .{ .icon = "view-fullscreen-symbolic", .title = "Zoom Pane",
       .desc = "Toggle the focused pane to fill the whole tab (tmux z).", .action = .zoom_pane },

    // Tabs
    .{ .icon = "tab-new-symbolic", .title = "New Tab",
       .desc = "Open a new tab in the current window.", .action = .new_tab },
    .{ .icon = "edit-copy-symbolic", .title = "Duplicate Tab",
       .desc = "Open a new tab inheriting this tab's working directory and profile.", .action = .duplicate_tab },
    .{ .icon = "window-close-symbolic", .title = "Close Tab",
       .desc = "Close the active tab.", .action = .close_tab },
    .{ .icon = "view-pin-symbolic", .title = "Pin / Unpin Tab",
       .desc = "Toggle pinning. Pinned tabs sit at the start of the tab bar.", .action = .toggle_pin_tab },
    .{ .icon = "edit-undo-symbolic", .title = "Restore Closed Tab",
       .desc = "Reopen the most recently closed tab.", .action = .restore_closed_tab },
    .{ .icon = "view-grid-symbolic", .title = "Toggle Tab Bar",
       .desc = "Show or hide the tab bar at the top of the window.", .action = .toggle_tab_bar },
    .{ .icon = "go-next-symbolic", .title = "Next Tab",
       .desc = "Switch focus to the next tab.", .action = .next_tab },
    .{ .icon = "go-previous-symbolic", .title = "Previous Tab",
       .desc = "Switch focus to the previous tab.", .action = .prev_tab },
    .{ .icon = "sidebar-show-symbolic", .title = "Toggle Tab Tree Sidebar",
       .desc = "Show or hide the vertical tree-style tab sidebar.", .action = .toggle_tab_sidebar },
    .{ .icon = "pan-end-symbolic", .title = "Collapse Tab Subtree",
       .desc = "Hide the current tab's child tabs (tree-style tabs).", .action = .tab_collapse },
    .{ .icon = "pan-down-symbolic", .title = "Expand Tab Subtree",
       .desc = "Show the current tab's child tabs again.", .action = .tab_expand },
    .{ .icon = "go-next-symbolic", .title = "Next Tab (Tree Order)",
       .desc = "Switch to the next tab in tree order, skipping collapsed subtrees.", .action = .tab_tree_next },
    .{ .icon = "go-previous-symbolic", .title = "Previous Tab (Tree Order)",
       .desc = "Switch to the previous tab in tree order, skipping collapsed subtrees.", .action = .tab_tree_prev },

    // Panes
    .{ .icon = "view-dual-symbolic", .title = "Split Horizontal",
       .desc = "Split the active pane left and right.", .action = .split_h },
    .{ .icon = "view-paged-symbolic", .title = "Split Vertical",
       .desc = "Split the active pane top and bottom.", .action = .split_v },
    .{ .icon = "go-next-symbolic", .title = "Next Pane",
       .desc = "Move focus to the next pane within this tab.", .action = .pane_next },
    .{ .icon = "go-previous-symbolic", .title = "Previous Pane",
       .desc = "Move focus to the previous pane within this tab.", .action = .pane_prev },

    // Search & scrollback
    .{ .icon = "edit-find-symbolic", .title = "Search",
       .desc = "Search the scrollback for a string.", .action = .search_open },
    .{ .icon = "system-search-symbolic", .title = "Search All Sessions",
       .desc = "Search every mux session's scrollback (local daemon).", .action = .cross_search },
    .{ .icon = "view-restore-symbolic", .title = "Attach All Sessions",
       .desc = "Open every durable session not already shown (bulk handoff).", .action = .attach_all },
    .{ .icon = "go-up-symbolic", .title = "Previous Prompt",
       .desc = "Jump to the previous shell prompt (uses OSC 133 marks).", .action = .prompt_prev },
    .{ .icon = "go-down-symbolic", .title = "Next Prompt",
       .desc = "Jump to the next shell prompt.", .action = .prompt_next },
    .{ .icon = "go-top-symbolic", .title = "Scroll to Top",
       .desc = "Jump to the oldest line in the scrollback.", .action = .scrollback_top },
    .{ .icon = "go-bottom-symbolic", .title = "Scroll to Bottom",
       .desc = "Return to the live screen position.", .action = .scrollback_bottom },
    .{ .icon = "go-up-symbolic", .title = "Page Up",
       .desc = "Scroll back one screenful.", .action = .scrollback_page_up },
    .{ .icon = "go-down-symbolic", .title = "Page Down",
       .desc = "Scroll forward one screenful.", .action = .scrollback_page_down },
    .{ .icon = "edit-clear-all-symbolic", .title = "Clear Scrollback",
       .desc = "Wipe the scrollback ring. The visible screen stays.", .action = .clear_scrollback },
    .{ .icon = "view-list-symbolic", .title = "Show Scrollback in Pager",
       .desc = "Open the scrollback buffer plus visible screen in a pager tab.", .action = .show_scrollback },
    .{ .icon = "network-server-symbolic", .title = "New Durable Tab (mux)",
       .desc = "Shell in the sketerm-mux daemon; survives GUI restarts.", .action = .new_durable_tab },
    .{ .icon = "folder-symbolic", .title = "New File Browser Tab",
       .desc = "Browse files with live listings; the pane's shell is one click away.", .action = .new_browser_tab },
    .{ .icon = "view-dual-symbolic", .title = "New Browser Pane (Split)",
       .desc = "Add a browser pane beside this one. Dual-pane source/target: F5 copies to the other pane, F6 moves.", .action = .new_browser_split },
    .{ .icon = "web-browser-symbolic", .title = "New Web Tab",
       .desc = "Open a web page in a pane (needs the opt-in browser helper: zig build fetch-cef && zig build web).", .action = .new_web_tab },
    .{ .icon = "web-browser-symbolic", .title = "New Web Pane (Split)",
       .desc = "Add a web pane beside this one; the pane's shell stays one click away.", .action = .new_web_split },
    .{ .icon = "view-private-symbolic", .title = "New Incognito Web Tab",
       .desc = "Open a web tab in a private, throwaway container: its own cookie jar and cache, wiped when it closes.", .action = .new_incognito_web_tab },
    .{ .icon = "network-vpn-symbolic", .title = "New Tor Web Tab",
       .desc = "Open a web tab whose traffic leaves through Tor (the SOCKS5 endpoint in mux_tor_socks_endpoint). The page is never loaded directly first.", .action = .new_tor_web_tab },
    .{ .icon = "network-wired-symbolic", .title = "Route (Web Tab)…",
       .desc = "Choose where this web tab's traffic leaves: Direct, Tor, via a mux/SSH server, or a browser running on a server. The toolbar's route button.", .action = .web_route_menu },
    .{ .icon = "network-vpn-symbolic", .title = "Route Web Tab Through Tor",
       .desc = "Move this web tab onto the Tor route: it reloads inside the Tor browser instance and stays there for its lifetime.", .action = .web_route_tor },
    .{ .icon = "network-wired-symbolic", .title = "Route Web Tab Directly",
       .desc = "Move this web tab back onto the direct route (this machine's own network).", .action = .web_route_direct },
    .{ .icon = "input-keyboard-symbolic", .title = "Link Hints (Web Page)",
       .desc = "Label every link and control on the page; type a label to click it (Shift opens links in a new tab).", .action = .web_hints },
    .{ .icon = "sketerm-reader-symbolic", .title = "Reader View / Show Page",
       .desc = "Swap this pane's web page for its article as plain text, and back. The page keeps running underneath.", .action = .web_reader },
    .{ .icon = "web-browser-symbolic", .title = "Discard Background Web Tabs",
       .desc = "Let go of every web page that is not on screen. Each pane keeps its last frame, dimmed, and reloads when you look at it again.", .action = .web_discard_background },
    .{ .icon = "applications-engineering-symbolic", .title = "Open DevTools (Web Pane)",
       .desc = "Open the browser engine's inspector for this web pane, in a split beside it. No remote debugging port is opened.", .action = .web_devtools },
    .{ .icon = "document-print-symbolic", .title = "Print Web Page to PDF…",
       .desc = "Save this web pane's page as a PDF file; the browser engine renders it.", .action = .web_print_pdf },
    .{ .icon = "dialog-password-symbolic", .title = "Fill Password (Web Pane)…",
       .desc = "Pick a login saved in your keyring for this page's site and type it in as username, Tab, password. Focus the username field first; nothing is ever saved back.", .action = .web_fill_password },
    .{ .icon = "channel-secure-symbolic", .title = "Site Information (Web Pane)",
       .desc = "What this site is, what it was allowed to do, and what it has stored — with the way to undo each.", .action = .web_site_info },
    .{ .icon = "document-open-recent-symbolic", .title = "History (Web)",
       .desc = "Search the pages this daemon remembers visiting; open, or forget, any of them.", .action = .web_history },
    .{ .icon = "sketerm-starred-symbolic", .title = "Bookmarks (Web)",
       .desc = "Open, rename, re-folder and reorder bookmarks; the web toolbar's star adds them.", .action = .web_bookmarks },
    .{ .icon = "window-close-symbolic", .title = "Close Pane",
       .desc = "Close the focused pane and give its space back (un-split).", .action = .close_pane },
    .{ .icon = "sketerm-terminal-symbolic", .title = "Show File Browser / Show Shell",
       .desc = "Swap this pane between its file browser and its shell. Both stay alive; neither is closed.", .action = .toggle_browser_face },
    .{ .icon = "document-edit-symbolic", .title = "New Editor Tab",
       .desc = "Edit text files (local or remote) with multi-caret editing; the pane's shell is one click away.", .action = .new_editor_tab },
    .{ .icon = "document-edit-symbolic", .title = "New Editor Pane (Split)",
       .desc = "Add a text editor pane beside this one; the pane's shell stays one click away.", .action = .new_editor_split },
    .{ .icon = "document-edit-symbolic", .title = "Show Editor / Show Shell",
       .desc = "Swap this pane between its text editor and its shell. Both stay alive; neither is closed.", .action = .toggle_editor_face },
    .{ .icon = "web-browser-symbolic", .title = "Show Browser / Show Shell",
       .desc = "Swap this pane between its web browser and its shell. Both stay alive; neither is closed.", .action = .toggle_web_face },
    .{ .icon = "view-paged-symbolic", .title = "Open Saved Panel…",
       .desc = "Reopen a declarative UI panel saved for this pane's session. Broken documents are listed with the reason; each row can be deleted.", .action = .panel_open },
    .{ .icon = "window-close-symbolic", .title = "Close Panel",
       .desc = "Take the panel off this pane, or off this tab. A panel that replaced a shell gives the shell back.", .action = .panel_close },

    // Font
    .{ .icon = "zoom-in-symbolic", .title = "Increase Font Size",
       .desc = "Bump the cell font up by one point.", .action = .font_inc },
    .{ .icon = "zoom-out-symbolic", .title = "Decrease Font Size",
       .desc = "Drop the cell font down by one point.", .action = .font_dec },
    .{ .icon = "zoom-original-symbolic", .title = "Reset Font Size",
       .desc = "Restore the configured default size.", .action = .font_reset },

    // Layout & config
    .{ .icon = "document-save-symbolic", .title = "Save Layout",
       .desc = "Write the current tabs and panes to last.json.", .action = .save_layout },
    .{ .icon = "document-save-as-symbolic", .title = "Save Layout As…",
       .desc = "Pick a path and save the current layout there.", .action = .save_layout_as },
    .{ .icon = "sketerm-starred-symbolic", .title = "Save Default Layout",
       .desc = "Save current tabs and panes as the default for every new launch.", .action = .save_default_layout },
    .{ .icon = "document-open-symbolic", .title = "Load Layout…",
       .desc = "Pick a saved layout file and open its tabs in a new window.", .action = .load_layout },
    .{ .icon = "view-refresh-symbolic", .title = "Reload Config",
       .desc = "Re-read config.conf from disk and apply live.", .action = .reload_config },
    .{ .icon = "application-x-executable-symbolic", .title = "Launch App…",
       .desc = "Pick an installed GUI app on this pane's host and run it as a forwarded app.", .action = .launch_app },
    .{ .icon = "view-grid-symbolic", .title = "Session Overview…",
       .desc = "Every session and app window, local and remote: raise, attach, or kill; shows which one is playing audio.", .action = .app_windows },
    .{ .icon = "preferences-other-symbolic", .title = "Apply Profile to Pane…",
       .desc = "Re-style the focused pane with a profile's font/colors/scrollback.", .action = .apply_profile },

    // Shaders
    .{ .icon = "sketerm-starred-symbolic", .title = "Shader Preset…",
       .desc = "Apply or delete a saved shader preset on the focused pane.", .action = .shader_preset_pick },

    // Misc
    .{ .icon = "input-keyboard-symbolic", .title = "Broadcast Mode",
       .desc = "Cycle broadcast typing across panes: off → group → all → off.", .action = .broadcast_cycle },
    .{ .icon = "preferences-system-symbolic", .title = "Preferences",
       .desc = "Open the preferences dialog.", .action = .prefs_open },
    .{ .icon = "help-about-symbolic", .title = "Welcome Tour",
       .desc = "Re-open the first-run tour of what sketerm can do.", .action = .welcome_open },
};

/// Every row for `ctx`, in catalogue order: the curated set, then the
/// editor commands when an editor face is focused, then one per
/// configured domain. `out` is cleared first.
pub fn build(gpa: std.mem.Allocator, ctx: Context, out: *std.ArrayList(Row)) error{OutOfMemory}!void {
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, &curated);
    if (ctx.editor) {
        inline for (@typeInfo(ecmd.Command).@"enum".fields) |field| {
            const cmd: ecmd.Command = @enumFromInt(field.value);
            try out.append(gpa, .{
                .icon = "document-edit-symbolic",
                .title = ecmd.label(cmd),
                .desc = ecmd.describe(cmd),
                .kind = .editor,
                .editor_cmd = cmd,
            });
        }
    }
    for (ctx.domains) |dom| {
        try out.append(gpa, .{
            .icon = "network-server-symbolic",
            .title = dom.title,
            .desc = dom.desc,
            .kind = .domain,
            .action = .new_durable_tab,
            .host = dom.host_spec,
        });
    }
}

// ── recency ──────────────────────────────────────────────────────

/// A row's identity ACROSS palette openings. Row indices change with
/// the focused pane (editor rows appear and vanish), so recency has to
/// key on what the row does, not on where it sat.
pub const Key = struct {
    kind: Kind,
    id: u32,

    pub fn eql(a: Key, b: Key) bool {
        return a.kind == b.kind and a.id == b.id;
    }
};

pub fn keyOf(row: Row) Key {
    return switch (row.kind) {
        .action => .{ .kind = .action, .id = @intFromEnum(row.action) },
        .editor => .{ .kind = .editor, .id = if (row.editor_cmd) |cmd| @intFromEnum(cmd) else 0 },
        // Domains have no enum to key on; the host spec is what makes
        // one distinct from another.
        .domain => .{ .kind = .domain, .id = hash32(row.host) },
    };
}

fn hash32(s: []const u8) u32 {
    var h: u32 = 0x811c9dc5; // FNV-1a
    for (s) |ch| {
        h ^= ch;
        h *%= 0x01000193;
    }
    return h;
}

/// How many recently-run commands are remembered.
pub const mru_cap = 8;

/// The largest bonus a recently-run row can earn.
///
/// `matchScore` grades a clear step apart — 1.0 prefix, 0.8 word
/// boundary, 0.7 detail prefix, 0.6 substring — so a bonus below 0.05
/// reorders rows WITHIN a grade and can never lift one across a grade
/// boundary. That is the safety property the whole feature rests on:
/// recency breaks ties between equally good matches, it never
/// overrules what the user actually typed. The
/// "never promotes a row across a match grade" test pins it, and any
/// future re-grading of `matchScore` has to keep the gaps wider than
/// this constant.
pub const mru_max_boost: f32 = 0.04;

/// Most-recently-activated commands, newest first.
///
/// Deliberately in-process and session-scoped rather than persisted.
/// `app_launcher.zig` does persist its recents (recent-apps.json), so
/// the precedent exists and this could follow it later; the reason it
/// does not today is that writing state files from a module that
/// compiles into `sketerm-mux`'s test root means dragging path
/// resolution and file IO in behind it, for a feature whose value is
/// almost entirely within one sitting.
/// The process-wide recency store, shared by every surface that offers
/// commands. "Recently used" is a property of the user, not of the
/// window they happened to reach for: running a command from the
/// omnibox should float it in the palette too. Surfaces are built and
/// destroyed constantly, so this cannot live in any of them.
///
/// Main-loop state, mutated only from the GTK thread. Tests construct
/// their own `Mru` rather than touching this.
pub var recent: Mru = .{};

pub const Mru = struct {
    keys: [mru_cap]Key = @splat(.{ .kind = .action, .id = 0 }),
    /// Occupied prefix of `keys`.
    n: usize = 0,

    /// Move-to-front. A repeat does not grow the list.
    pub fn note(self: *Mru, key: Key) void {
        var at: usize = self.n;
        for (self.keys[0..self.n], 0..) |k, i| {
            if (k.eql(key)) {
                at = i;
                break;
            }
        }
        if (at == self.n and self.n < mru_cap) self.n += 1;
        // Shift everything above the hit (or the whole list when the
        // key is new and the list is full) down one slot.
        var i: usize = @min(at, self.n - 1);
        while (i > 0) : (i -= 1) self.keys[i] = self.keys[i - 1];
        self.keys[0] = key;
    }

    /// 0 = most recent. Null when the key was never activated.
    pub fn rank(self: *const Mru, key: Key) ?usize {
        for (self.keys[0..self.n], 0..) |k, i| {
            if (k.eql(key)) return i;
        }
        return null;
    }

    /// Score bonus for `key`, decaying with age and always below
    /// `mru_max_boost`.
    pub fn boost(self: *const Mru, key: Key) f32 {
        const r = self.rank(key) orelse return 0.0;
        const frac = 1.0 - (@as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(mru_cap)));
        return mru_max_boost * frac;
    }
};

// ── the source ───────────────────────────────────────────────────

/// The catalogue wired up as a `suggest.Source`: rows plus the recency
/// that ranks them. Embed one in whatever context owns the surface.
pub const Feed = struct {
    rows: []const Row = &.{},
    /// BORROWED, never owned: recency has to outlive the surface that
    /// records it. The palette's feed dies with its dialog, and a
    /// per-dialog MRU would forget everything the moment you ran a
    /// command — so the consumer keeps the store and lends it here.
    mru: *Mru,

    /// `act` is the consumer's dispatch and `act_ctx` the object it
    /// needs (a Window, say) — the feed itself is only the row store,
    /// which is why `suggest.Source.activate_ctx` exists.
    pub fn source(self: *Feed, act: ?suggest.ActivateFn, act_ctx: ?*anyopaque, weight: f32) suggest.Source {
        return .{
            .ctx = self,
            .query = query,
            .activate = act,
            .activate_ctx = act_ctx,
            .weight = weight,
        };
    }

    fn query(ctx: ?*anyopaque, q: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(suggest.Candidate)) void {
        const self: *Feed = @ptrCast(@alignCast(ctx.?));
        for (self.rows, 0..) |row, i| {
            const score = suggest.fieldsScore(q, row.title, row.desc);
            if (score <= 0) continue;
            out.append(gpa, .{
                .title = row.title,
                .detail = row.desc,
                .kind = .command,
                .score = score + self.mru.boost(keyOf(row)),
                .payload = i,
            }) catch {};
        }
    }
};

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "the curated set carries the panel actions" {
    // The saved-panel picker is reachable ONLY from the palette (no
    // default chord, no menu item), so a missing row is the whole
    // feature missing.
    var open_row = false;
    var close_row = false;
    for (curated) |e| {
        if (e.action == .panel_open) open_row = true;
        if (e.action == .panel_close) close_row = true;
    }
    try t.expect(open_row);
    try t.expect(close_row);
}

test "build adds editor rows only for an editor pane, and one row per domain" {
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(t.allocator);

    try build(t.allocator, .{}, &rows);
    try t.expectEqual(curated.len, rows.items.len);

    try build(t.allocator, .{ .editor = true }, &rows);
    try t.expectEqual(curated.len + ecmd.COMMAND_COUNT, rows.items.len);
    try t.expectEqual(Kind.editor, rows.items[curated.len].kind);

    const domains = [_]DomainRow{.{
        .name = "box",
        .host_spec = "ssh:box.example",
        .title = "New Tab on box",
        .desc = "Durable remote shell on box.example (ssh).",
    }};
    try build(t.allocator, .{ .domains = &domains }, &rows);
    try t.expectEqual(curated.len + 1, rows.items.len);
    const last = rows.items[rows.items.len - 1];
    try t.expectEqual(Kind.domain, last.kind);
    try t.expectEqualStrings("ssh:box.example", last.host);
}

/// Rank the catalogue exactly as a surface would.
fn rankQuery(feed: *Feed, q: []const u8, out: *std.ArrayList(suggest.Candidate)) !void {
    const sources = [_]suggest.Source{feed.source(null, null, 1.0)};
    try suggest.merge(t.allocator, &sources, q, 32, out);
}

test "typing 'tab' ranks New Tab above every description-only hit" {
    // This is the ranking `commandPaletteStage` asserts end to end in
    // smoke-e2e: a filter-only palette would offer "Keyboard Hints"
    // (whose description mentions Tab) because it is earlier in the
    // curated order. Pinning it here means a ranking regression fails
    // in CI without a GUI.
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(t.allocator);
    try build(t.allocator, .{}, &rows);
    var mru = Mru{};
    var feed = Feed{ .rows = rows.items, .mru = &mru };

    var out: std.ArrayList(suggest.Candidate) = .empty;
    defer out.deinit(t.allocator);
    try rankQuery(&feed, "tab", &out);
    try t.expect(out.items.len > 1);
    try t.expectEqualStrings("New Tab", out.items[0].title);

    // And the decoy really is in the result set, just below.
    var saw_hints = false;
    for (out.items) |cand| {
        if (std.mem.eql(u8, cand.title, "Keyboard Hints")) saw_hints = true;
    }
    try t.expect(saw_hints);
}

test "a bare query keeps the curated order" {
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(t.allocator);
    try build(t.allocator, .{}, &rows);
    var mru = Mru{};
    var feed = Feed{ .rows = rows.items, .mru = &mru };

    var out: std.ArrayList(suggest.Candidate) = .empty;
    defer out.deinit(t.allocator);
    try rankQuery(&feed, "", &out);
    try t.expectEqualStrings(curated[0].title, out.items[0].title);
    try t.expectEqualStrings(curated[1].title, out.items[1].title);
}

test "Mru moves a repeat to the front and forgets past the cap" {
    var mru = Mru{};
    const a = Key{ .kind = .action, .id = 1 };
    const b = Key{ .kind = .action, .id = 2 };
    try t.expect(mru.rank(a) == null);

    mru.note(a);
    mru.note(b);
    try t.expectEqual(@as(?usize, 0), mru.rank(b));
    try t.expectEqual(@as(?usize, 1), mru.rank(a));

    // A repeat re-fronts without growing the list.
    mru.note(a);
    try t.expectEqual(@as(?usize, 0), mru.rank(a));
    try t.expectEqual(@as(?usize, 1), mru.rank(b));
    try t.expectEqual(@as(usize, 2), mru.n);

    // Overflow drops the oldest.
    var i: u32 = 10;
    while (i < 10 + mru_cap) : (i += 1) mru.note(.{ .kind = .action, .id = i });
    try t.expectEqual(@as(usize, mru_cap), mru.n);
    try t.expect(mru.rank(a) == null);
    try t.expect(mru.rank(b) == null);

    // Kinds are part of the identity: same id, different kind.
    var k = Mru{};
    k.note(.{ .kind = .action, .id = 3 });
    try t.expect(k.rank(.{ .kind = .editor, .id = 3 }) == null);
}

test "the MRU boost re-orders within a grade but never across one" {
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(t.allocator);
    try build(t.allocator, .{}, &rows);
    var mru = Mru{};
    var feed = Feed{ .rows = rows.items, .mru = &mru };

    var out: std.ArrayList(suggest.Candidate) = .empty;
    defer out.deinit(t.allocator);

    // "Zoom Pane" scores a word-boundary 0.8 on "pane"; "Close Pane"
    // scores the same and sits later in the curated order, so it is
    // normally below.
    try rankQuery(&feed, "pane", &out);
    var zoom_first: usize = 0;
    var close_first: usize = 0;
    for (out.items, 0..) |cand, i| {
        if (std.mem.eql(u8, cand.title, "Zoom Pane")) zoom_first = i;
        if (std.mem.eql(u8, cand.title, "Close Pane")) close_first = i;
    }
    try t.expect(zoom_first < close_first);

    // Running Close Pane lifts it above its equal-scoring peer...
    feed.mru.note(.{ .kind = .action, .id = @intFromEnum(@import("action.zig").Action.close_pane) });
    try rankQuery(&feed, "pane", &out);
    var zoom_after: usize = 0;
    var close_after: usize = 0;
    for (out.items, 0..) |cand, i| {
        if (std.mem.eql(u8, cand.title, "Zoom Pane")) zoom_after = i;
        if (std.mem.eql(u8, cand.title, "Close Pane")) close_after = i;
    }
    try t.expect(close_after < zoom_after);

    // ...but a prefix match still wins outright. "New Tab" is a 1.0 on
    // "new tab"; boosting a mere substring holder must not overtake it.
    feed.mru.note(.{ .kind = .action, .id = @intFromEnum(@import("action.zig").Action.new_incognito_web_tab) });
    try rankQuery(&feed, "new tab", &out);
    try t.expectEqualStrings("New Tab", out.items[0].title);
}

test "the boost stays under the grade gap for every rank" {
    var mru = Mru{};
    var i: u32 = 0;
    while (i < mru_cap) : (i += 1) mru.note(.{ .kind = .action, .id = i });
    i = 0;
    while (i < mru_cap) : (i += 1) {
        const b = mru.boost(.{ .kind = .action, .id = i });
        try t.expect(b > 0.0);
        try t.expect(b <= mru_max_boost);
    }
    // The gap between adjacent match grades is 0.1; the bonus must
    // stay well inside it or ranking stops meaning what it says.
    try t.expect(mru_max_boost < 0.05);
}
