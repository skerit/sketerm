//! Keyboard input → xterm byte encoding → PTY write.
//!
//! Subset implemented in M4. Full xterm spec + modifyOtherKeys=1
//! and CSI u progressive enhancement come later.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Terminal = @import("../terminal.zig").Terminal;
const clipboard = @import("clipboard.zig");
const imhost = @import("imhost.zig");

pub const Ctx = struct {
    widget: *c.GtkWidget,
    terminal: *Terminal,
    /// Opaque back-pointer to the owning Pane, set by Pane.init right
    /// after attach. Every callback below takes it; input.zig must not
    /// import pane.zig.
    pane_ctx: ?*anyopaque = null,
    /// Flip Pane's `cursor_hidden` flag (mouse_autohide).
    autohide_set: ?*const fn (ctx: ?*anyopaque, hidden: bool) void = null,
    /// Swap the pane's file-browser and terminal faces. @return false
    /// when the pane has no browser face, so the key falls through.
    browser_toggle: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// Swap the pane's editor and terminal faces. @return false when
    /// the pane has no editor face, so the key falls through.
    editor_toggle: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// Start link hints on the pane's VISIBLE web face. @return false
    /// when the pane shows no web page, so `hints_open` falls through
    /// to the terminal quick-select. Installed by WebFace.attach; the
    /// fn is stateless (it resolves the face from the Pane), so a
    /// detached face just answers false and nothing dangles.
    web_hints: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// Pop the pane's context menu at the text cursor (keyboard path:
    /// Menu / Shift+F10). @return false when the pane has no menu
    /// attached yet, so the key falls through to the child.
    context_menu: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// Optional shortcut sink for tab/split/etc actions. May be null
    /// for top-level shortcuts handled elsewhere.
    shortcut_sink: ?*const fn (ctx: ?*anyopaque, action: Action) void = null,
    shortcut_ctx: ?*anyopaque = null,
    /// Shared IM plumbing (compose / dead keys / IME). Owned here;
    /// severed by Pane.detachIm before the GLArea dies.
    im: ?*imhost.ImHost = null,
    /// Last keyval seen on key-pressed (for repeat detection — kitty
    /// kbd flag 0x02 emits event=2 on repeats vs event=1 on first
    /// press). Cleared on key-released so the next press is "fresh".
    last_press_keyval: c_uint = 0,
    last_press_time_us: i64 = 0,
    /// Smart-copy mode: if true and Ctrl+Shift+C is pressed with no
    /// selection, send Ctrl+C (0x03) to the child instead of being
    /// a no-op. Set from Config.smart_copy at attach time and on
    /// every applyConfigChange.
    smart_copy: bool = true,
    /// Drop the active selection after a Ctrl+Shift+C copy. Mirrors
    /// Config.clear_select_on_copy.
    clear_select_on_copy: bool = false,
    /// Hide the pointer over the widget while typing. Mirrors
    /// Config.mouse_autohide. The Pane's onMotion handler restores it.
    mouse_autohide: bool = true,
    /// Active keybinding table. Empty slice = use `default_bindings`.
    /// Window owns the storage (parsed from Config); Ctx just borrows.
    bindings: []const Binding = &.{},
    /// Hint-mode key interceptor. While set, every key press is fed
    /// here FIRST; a true return consumes the event. Window installs
    /// it on the focused pane when hint mode opens and clears it on
    /// exit.
    hint_sink: ?*const fn (ctx: ?*anyopaque, keyval: c_uint, state: c.GdkModifierType) bool = null,
    hint_ctx: ?*anyopaque = null,
    /// Copy-mode key sink. While set, every key press is routed here
    /// before bindings / PTY encoding. Returns true = consumed; false
    /// (bare modifiers) falls through to GTK so modifier state stays
    /// intact. Window installs/clears this in open/exitCopyMode.
    copymode_sink: ?*const fn (ctx: ?*anyopaque, keyval: c_uint, state: c.GdkModifierType) bool = null,
    copymode_ctx: ?*anyopaque = null,
};

/// Maximum gap between consecutive presses of the same keyval that
/// we still consider a hardware repeat (microseconds). Tuned higher
/// than typical OS auto-repeat (33–50 ms) but well below the time a
/// user takes to deliberately re-press a key. 120 ms.
const REPEAT_WINDOW_US: i64 = 120_000;

pub const Action = enum {
    // Window-level (dispatched via shortcut_sink to Window).
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    copy,
    paste,
    split_h,
    split_v,
    font_inc,
    font_dec,
    font_reset,
    search_open,
    /// Search across every mux session's scrollback (local daemon).
    cross_search,
    /// Attach every local mux session not already shown (bulk handoff).
    attach_all,
    save_layout,
    save_layout_as,
    /// Save the current tab/split layout as the user's default,
    /// auto-loaded on every subsequent cold start.
    save_default_layout,
    /// Pick a saved layout file (.json/.layout) and load its tabs
    /// into the current window — appends, mirroring the `--layout`
    /// CLI flag's semantics (existing tabs are left in place).
    load_layout,
    prompt_prev,
    prompt_next,
    pane_next,
    pane_prev,
    prefs_open,
    /// Cycle broadcast typing mode: off → group → all → off.
    broadcast_cycle,
    /// Re-open the most-recently-closed tab (browser convention).
    restore_closed_tab,
    /// Pin / unpin the current tab — pinned tabs sit in their own
    /// section at the start of the tab bar (AdwTabView native).
    toggle_pin_tab,
    /// Show / hide the entire tab bar — useful when working in
    /// single-tab mode where the bar is wasted vertical space.
    toggle_tab_bar,
    /// Show / hide the vertical tree-style tab sidebar.
    toggle_tab_sidebar,
    /// Collapse the current tab's subtree (tree-style tabs) — its
    /// child tabs hide from the strip and sidebar.
    tab_collapse,
    /// Expand the current tab's subtree.
    tab_expand,
    /// Next tab in TREE order, skipping collapsed subtrees.
    tab_tree_next,
    /// Previous tab in TREE order, skipping collapsed subtrees.
    tab_tree_prev,
    /// Re-load config.conf from disk + apply live (no restart).
    /// Re-reads the file the process started from: an active
    /// `--config <path>` override, else the XDG search path.
    reload_config,
    /// Open the app launcher (installed GUI apps on the focused
    /// pane's host — local daemon or SSH remote).
    launch_app,
    /// Open the searchable task overview for applications, audio and
    /// attached or available mux sessions.
    app_windows,
    /// Jump to a specific tab by 1-based index. Defaults: Alt+1
    /// through Alt+9 — gnome-terminal / Firefox / most multi-tab
    /// apps use this. Out-of-range index is a no-op.
    goto_tab_1,
    goto_tab_2,
    goto_tab_3,
    goto_tab_4,
    goto_tab_5,
    goto_tab_6,
    goto_tab_7,
    goto_tab_8,
    goto_tab_9,
    /// Spawn a new tab inheriting the focused pane's cwd + profile.
    /// Subtly different from `new_tab` which uses the focused pane's
    /// cwd already but defaults the profile to none.
    duplicate_tab,
    /// Move the current tab into its own new window (also available
    /// by dragging the tab out of the tab bar).
    detach_tab,
    /// Open the dynamic shader-config dialog (sliders/colors from
    /// the focused pane's shader parameter declarations).
    configure_shader,
    /// Open the shader-preset picker (apply/delete saved presets).
    shader_preset_pick,
    /// Apply a profile's settings bundle to the focused LIVE pane
    /// (popover picker; "default" restores the Default settings).
    apply_profile,
    /// Dump scrollback + visible screen to a temp file and open it
    /// in a pager (`less -R +G`, or `$PAGER`) in a new tab. Kitty's
    /// show_scrollback equivalent.
    show_scrollback,
    /// Spawn a shell inside the sketerm-mux daemon and attach it as
    /// a tab — survives GUI restarts (reattach via `sketerm mux`).
    new_durable_tab,
    /// Open a file-browser tab (src/ui/browser.zig): a shell pane
    /// wearing the browser face.
    new_browser_tab,
    /// Split the focused pane and give the new pane a browser face:
    /// how a dual-pane source/target layout is created.
    new_browser_split,
    /// Open a web tab (src/ui/webface.zig): a shell pane wearing the
    /// browser-engine face served by the `sketerm-webengine` helper.
    new_web_tab,
    /// Split the focused pane and give the new pane a web face.
    new_web_split,
    /// Open a web tab in a fresh throwaway incognito container (a
    /// private, ephemeral cookie jar / cache).
    new_incognito_web_tab,
    /// Link hints on the focused pane's web face (Vimium-style): label
    /// every visible interactive element of the page, type a label to
    /// click it through the trusted-input path (Shift/Ctrl on the last
    /// letter opens a link in a new tab). Dispatched locally; a pane
    /// not showing a web page leaves the chord to whatever is next.
    /// `hints_open` also lands here first when the web face is showing,
    /// so the one hints chord always hints what is on screen.
    web_hints,
    /// Flip the focused pane's web face between the live page and
    /// reader mode: the page's article, extracted by the same
    /// `sem_read` the `web_read` tool uses, laid out as text.
    web_reader,
    /// Discard every web pane that is not on screen: the browser
    /// engine lets each page go and the pane keeps its last frame,
    /// dimmed, until it is looked at again. What
    /// `web_discard_minutes` does on a timer, on demand.
    web_discard_background,
    /// Open the browser engine's DevTools for the focused web pane,
    /// in a split beside it (src/ui/webface.zig). No debugging port
    /// is involved: the inspector is another helper-side view.
    web_devtools,
    /// Save the focused web pane's page as a PDF, through a save
    /// dialog; the browser helper writes the file.
    web_print_pdf,
    /// Offer the Secret Service logins saved for the focused web
    /// pane's host and type the picked one into the page as
    /// username-Tab-password (src/ui/secrets.zig). Fill only: nothing
    /// is ever saved to the keyring, and nothing fills on its own.
    web_fill_password,
    /// Open the browsing-history window (src/ui/webhistory.zig): the
    /// daemon web store's pages, searchable through the same ranking
    /// the address bar uses.
    web_history,
    /// Open the bookmarks window (src/ui/webhistory.zig).
    web_bookmarks,
    /// Close the focused pane, giving its space back to its sibling.
    /// The last pane in a tab closes the tab.
    close_pane,
    /// Flip the focused pane between its file-browser face and its
    /// terminal face. Dispatched locally (the Pane owns both faces);
    /// a pane with no browser face leaves the key to the terminal.
    toggle_browser_face,
    /// Open a text-editor tab (src/ui/editorview.zig): a shell pane
    /// wearing the editor face.
    new_editor_tab,
    /// Split the focused pane and give the new pane an editor face.
    new_editor_split,
    /// Flip the focused pane between its editor face and its
    /// terminal face. Dispatched locally like toggle_browser_face.
    toggle_editor_face,
    /// Open the saved-panel picker: every declarative panel document
    /// stored for the focused pane's session, opened in a tab of its
    /// own (src/ui/panelpicker.zig). The user's own way back to a
    /// panel an assistant saved for him.
    panel_open,
    /// Close the panel the focused pane is hosting. A panel put ON a
    /// pane hides that pane's shell, and this is how the shell comes
    /// back without an assistant.
    panel_close,
    /// Detach the focused mux pane: the session keeps running on the
    /// daemon; the pane lands in a fresh local shell. No-op on
    /// non-mux panes.
    mux_detach,
    // Per-pane (dispatched locally inside input.zig).
    paste_clipboard,
    copy_selection,
    /// Copy the entire visible screen to the system clipboard.
    /// Useful when an app paints output without leaving it
    /// selectable (TUI dashboards, mosh+tmux mouse-mode, etc.).
    copy_screen,
    /// Copy the full scrollback ring + active screen. Soft-wraps
    /// preserved as logical lines (no extra newlines mid-output).
    copy_scrollback,
    copy_command_output,
    /// Line-wise select the last command's output zone (OSC 133).
    select_command_output,
    interrupt_or_copy,
    clear_and_scrollback,
    /// Wipe the scrollback ring only — visible screen untouched.
    clear_scrollback,
    scrollback_page_up,
    scrollback_page_down,
    /// Jump to the oldest scrollback line (top of buffer).
    scrollback_top,
    /// Jump to the live screen position (view_offset = 0).
    scrollback_bottom,
    /// Open the command palette — modal popover with every
    /// user-facing action, searchable by title/description.
    command_palette,
    /// Keyboard hints / quick-select: label every URL / path / hash
    /// on screen; typing a label opens (URLs) or copies it.
    hints_open,
    /// Enter copy mode — keyboard-driven cursor + selection over
    /// screen and scrollback (WezTerm/tmux convention).
    copy_mode,
    /// Toggle zooming the focused pane to fill its tab (tmux z).
    zoom_pane,
    /// Select the whole buffer (scrollback ring + visible screen) in
    /// the terminal's own line-select mode, so Copy / the selection
    /// highlight behave exactly as they do for a mouse drag.
    select_all,
    /// Open the pane's right-click context menu from the keyboard,
    /// anchored at the text cursor. Bound to the Menu key and
    /// Shift+F10 (the two cross-desktop conventions).
    context_menu,
};

/// One configured keybind: a (keyval, modifier-mask) → Action mapping.
pub const Binding = struct {
    keyval: c_uint,
    mods: c_uint,
    action: Action,
};

/// Default bindings table. Mirrors the prior hardcoded
/// `dispatchShortcut` switch. Config can override / add to these via
/// `keybind.<action>` entries; missing entries fall through here.
pub const default_bindings = [_]Binding{
    // Ctrl+Shift+...
    .{ .keyval = c.GDK_KEY_t, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .new_tab },
    .{ .keyval = c.GDK_KEY_w, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .close_tab },
    .{ .keyval = c.GDK_KEY_d, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .split_h },
    .{ .keyval = c.GDK_KEY_r, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .split_v },
    .{ .keyval = c.GDK_KEY_f, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .search_open },
    .{ .keyval = c.GDK_KEY_v, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .paste_clipboard },
    .{ .keyval = c.GDK_KEY_c, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .interrupt_or_copy },
    .{ .keyval = c.GDK_KEY_k, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .clear_and_scrollback },
    .{ .keyval = c.GDK_KEY_s, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .save_layout },
    .{ .keyval = c.GDK_KEY_s, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK, .action = .save_layout_as },
    .{ .keyval = c.GDK_KEY_Up, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .prompt_prev },
    .{ .keyval = c.GDK_KEY_Down, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .prompt_next },
    .{ .keyval = c.GDK_KEY_Left, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .pane_prev },
    .{ .keyval = c.GDK_KEY_Right, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .pane_next },
    .{ .keyval = c.GDK_KEY_ISO_Left_Tab, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .prev_tab },
    .{ .keyval = c.GDK_KEY_plus, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .font_inc },
    .{ .keyval = c.GDK_KEY_g, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .broadcast_cycle },
    .{ .keyval = c.GDK_KEY_e, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .hints_open },
    .{ .keyval = c.GDK_KEY_z, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .restore_closed_tab },
    .{ .keyval = c.GDK_KEY_o, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .launch_app },
    .{ .keyval = c.GDK_KEY_a, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .copy_screen },
    // Ctrl+Shift+B → swap the focused pane's browser and terminal
    // faces. Works from BOTH faces (the browser forwards unclaimed
    // chords to this table), which is what makes the browser
    // reachable again after flipping away from it.
    .{ .keyval = c.GDK_KEY_b, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .toggle_browser_face },
    // Kitty's default for show_scrollback.
    .{ .keyval = c.GDK_KEY_h, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .show_scrollback },
    // Ctrl+Shift+P is the cross-app convention for "command palette"
    // (VSCode, Sublime, JetBrains, GNOME Builder, …) so it takes
    // precedence here. Pin/unpin tab moves to Ctrl+Shift+I — pick
    // any new chord in your config if you don't like it.
    .{ .keyval = c.GDK_KEY_p, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .command_palette },
    .{ .keyval = c.GDK_KEY_i, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .toggle_pin_tab },
    // Ctrl+Shift+X → copy mode (WezTerm's default chord).
    .{ .keyval = c.GDK_KEY_x, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .copy_mode },
    // Ctrl+Shift+M → zoom ("maximize") the focused pane.
    .{ .keyval = c.GDK_KEY_m, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .zoom_pane },
    // Alt+1..9 → jump to specific tab. Standard across browsers,
    // gnome-terminal, kitty, etc. Doesn't collide with shell C-x
    // chords or Ctrl+Shift+digit (which terminator uses for splits).
    .{ .keyval = c.GDK_KEY_1, .mods = c.GDK_ALT_MASK, .action = .goto_tab_1 },
    .{ .keyval = c.GDK_KEY_2, .mods = c.GDK_ALT_MASK, .action = .goto_tab_2 },
    .{ .keyval = c.GDK_KEY_3, .mods = c.GDK_ALT_MASK, .action = .goto_tab_3 },
    .{ .keyval = c.GDK_KEY_4, .mods = c.GDK_ALT_MASK, .action = .goto_tab_4 },
    .{ .keyval = c.GDK_KEY_5, .mods = c.GDK_ALT_MASK, .action = .goto_tab_5 },
    .{ .keyval = c.GDK_KEY_6, .mods = c.GDK_ALT_MASK, .action = .goto_tab_6 },
    .{ .keyval = c.GDK_KEY_7, .mods = c.GDK_ALT_MASK, .action = .goto_tab_7 },
    .{ .keyval = c.GDK_KEY_8, .mods = c.GDK_ALT_MASK, .action = .goto_tab_8 },
    .{ .keyval = c.GDK_KEY_9, .mods = c.GDK_ALT_MASK, .action = .goto_tab_9 },
    // Ctrl+...
    .{ .keyval = c.GDK_KEY_Tab, .mods = c.GDK_CONTROL_MASK, .action = .next_tab },
    .{ .keyval = c.GDK_KEY_minus, .mods = c.GDK_CONTROL_MASK, .action = .font_dec },
    .{ .keyval = c.GDK_KEY_KP_Subtract, .mods = c.GDK_CONTROL_MASK, .action = .font_dec },
    .{ .keyval = c.GDK_KEY_equal, .mods = c.GDK_CONTROL_MASK, .action = .font_inc },
    .{ .keyval = c.GDK_KEY_plus, .mods = c.GDK_CONTROL_MASK, .action = .font_inc },
    .{ .keyval = c.GDK_KEY_KP_Add, .mods = c.GDK_CONTROL_MASK, .action = .font_inc },
    .{ .keyval = c.GDK_KEY_0, .mods = c.GDK_CONTROL_MASK, .action = .font_reset },
    .{ .keyval = c.GDK_KEY_KP_0, .mods = c.GDK_CONTROL_MASK, .action = .font_reset },
    .{ .keyval = c.GDK_KEY_comma, .mods = c.GDK_CONTROL_MASK, .action = .prefs_open },
    // Shift+...
    .{ .keyval = c.GDK_KEY_Page_Up, .mods = c.GDK_SHIFT_MASK, .action = .scrollback_page_up },
    .{ .keyval = c.GDK_KEY_Page_Down, .mods = c.GDK_SHIFT_MASK, .action = .scrollback_page_down },
    .{ .keyval = c.GDK_KEY_Home, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .scrollback_top },
    .{ .keyval = c.GDK_KEY_End, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .scrollback_bottom },
    // Keyboard access to the context menu. Both conventions are bound:
    // the dedicated Menu key (which has no terminal encoding of its
    // own, so nothing is lost) and Shift+F10 (which DOES have one —
    // CSI 21;2~ — and is shadowed here; rebind or clear
    // `keybind.context_menu` if an app needs it).
    .{ .keyval = c.GDK_KEY_Menu, .mods = 0, .action = .context_menu },
    .{ .keyval = c.GDK_KEY_F10, .mods = c.GDK_SHIFT_MASK, .action = .context_menu },
};

/// Match a (keyval, modifier_state) against the binding table. Returns
/// the first match, or null. The caller pre-masks `state` to only the
/// modifier bits we care about (Ctrl/Shift/Alt/Super) — Lock + group
/// bits are noise and must be filtered.
pub fn matchBinding(bindings: []const Binding, keyval: c_uint, mods: c_uint) ?Action {
    const significant: c_uint =
        c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK | c.GDK_SUPER_MASK;
    const m = mods & significant;
    for (bindings) |b| {
        if (b.keyval == keyval and (b.mods & significant) == m) return b.action;
    }
    return null;
}

/// Run a pane's binding table for a key a face did not claim: the
/// pane's own table when it has one, the defaults otherwise, tried
/// against both the lowercased and the raw keyval (GTK4 emits
/// uppercase keysyms under Shift; the tables are lowercase).
///
/// @return null when no binding matched, so the caller can fall
///         through to its own handling; otherwise `runAction`'s
///         verdict, which is 0 for an action that declined to run.
pub fn fallbackToPaneBindings(ictx: *Ctx, keyval: c_uint, state: c.GdkModifierType) ?c.gboolean {
    const bindings: []const Binding =
        if (ictx.bindings.len > 0) ictx.bindings else &default_bindings;
    const lower: c_uint = c.gdk_keyval_to_lower(keyval);
    const action = matchBinding(bindings, lower, state) orelse
        matchBinding(bindings, keyval, state) orelse return null;
    return runAction(ictx, action);
}

/// Modifier mask the binding matcher cares about. Lock and group
/// bits are filtered before comparison.
pub const SIGNIFICANT_MODS: c_uint =
    c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK | c.GDK_SUPER_MASK;

/// Rebuild `list` as `default_bindings` overlaid with config
/// (action-name, accel) overrides. An override replaces EVERY default
/// entry for its action; an empty accel unbinds the action. Duplicate
/// accelerators warn on stderr but stand. `keybinds` is any slice
/// whose elements expose `.name`/`.accel` byte slices, so callers
/// without a Window (the viewer) can feed `Config.keybinds` directly
/// without input.zig importing config.zig.
pub fn rebuildBindings(list: *std.ArrayList(Binding), ally: std.mem.Allocator, keybinds: anytype) void {
    list.clearRetainingCapacity();
    for (default_bindings) |b| list.append(ally, b) catch return;
    for (keybinds) |kb| {
        const action = actionFromName(kb.name) orelse {
            std.debug.print("sketerm: keybind: unknown action '{s}'\n", .{kb.name});
            continue;
        };
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].action == action) {
                _ = list.orderedRemove(i);
            } else i += 1;
        }
        if (kb.accel.len == 0) continue; // unbound
        const parsed = parseAccel(kb.accel) orelse {
            std.debug.print("sketerm: keybind: bad accelerator '{s}' for '{s}'\n", .{ kb.accel, kb.name });
            continue;
        };
        for (list.items) |existing| {
            if (existing.keyval == parsed.keyval and (existing.mods & SIGNIFICANT_MODS) == (parsed.mods & SIGNIFICANT_MODS)) {
                std.debug.print(
                    "sketerm: keybind: '{s}' shadows '{s}' (same accelerator)\n",
                    .{ actionName(action), actionName(existing.action) },
                );
                break;
            }
        }
        list.append(ally, .{
            .keyval = parsed.keyval,
            .mods = parsed.mods,
            .action = action,
        }) catch {};
    }
}

/// Convert an Action to its config-key string form. Stable across
/// versions — config files reference these names. Inverse: `actionFromName`.
pub fn actionName(a: Action) []const u8 {
    return switch (a) {
        .new_tab => "new_tab",
        .close_tab => "close_tab",
        .next_tab => "next_tab",
        .prev_tab => "prev_tab",
        .copy => "copy",
        .paste => "paste",
        .split_h => "split_h",
        .split_v => "split_v",
        .font_inc => "font_inc",
        .font_dec => "font_dec",
        .font_reset => "font_reset",
        .search_open => "search_open",
        .cross_search => "cross_search",
        .attach_all => "attach_all",
        .save_layout => "save_layout",
        .save_layout_as => "save_layout_as",
        .save_default_layout => "save_default_layout",
        .load_layout => "load_layout",
        .prompt_prev => "prompt_prev",
        .prompt_next => "prompt_next",
        .pane_next => "pane_next",
        .pane_prev => "pane_prev",
        .prefs_open => "prefs_open",
        .broadcast_cycle => "broadcast_cycle",
        .restore_closed_tab => "restore_closed_tab",
        .toggle_pin_tab => "toggle_pin_tab",
        .toggle_tab_bar => "toggle_tab_bar",
        .toggle_tab_sidebar => "toggle_tab_sidebar",
        .tab_collapse => "tab_collapse",
        .tab_expand => "tab_expand",
        .tab_tree_next => "tab_tree_next",
        .tab_tree_prev => "tab_tree_prev",
        .reload_config => "reload_config",
        .launch_app => "launch_app",
        .app_windows => "app_windows",
        .goto_tab_1 => "goto_tab_1",
        .goto_tab_2 => "goto_tab_2",
        .goto_tab_3 => "goto_tab_3",
        .goto_tab_4 => "goto_tab_4",
        .goto_tab_5 => "goto_tab_5",
        .goto_tab_6 => "goto_tab_6",
        .goto_tab_7 => "goto_tab_7",
        .goto_tab_8 => "goto_tab_8",
        .goto_tab_9 => "goto_tab_9",
        .duplicate_tab => "duplicate_tab",
        .detach_tab => "detach_tab",
        .configure_shader => "configure_shader",
        .shader_preset_pick => "shader_preset_pick",
        .apply_profile => "apply_profile",
        .show_scrollback => "show_scrollback",
        .new_durable_tab => "new_durable_tab",
        .new_browser_tab => "new_browser_tab",
        .new_browser_split => "new_browser_split",
        .new_web_tab => "new_web_tab",
        .new_web_split => "new_web_split",
        .new_incognito_web_tab => "new_incognito_web_tab",
        .web_hints => "web_hints",
        .web_reader => "web_reader",
        .web_discard_background => "web_discard_background",
        .web_devtools => "web_devtools",
        .web_print_pdf => "web_print_pdf",
        .web_fill_password => "web_fill_password",
        .web_history => "web_history",
        .web_bookmarks => "web_bookmarks",
        .close_pane => "close_pane",
        .toggle_browser_face => "toggle_browser_face",
        .new_editor_tab => "new_editor_tab",
        .new_editor_split => "new_editor_split",
        .toggle_editor_face => "toggle_editor_face",
        .panel_open => "panel_open",
        .panel_close => "panel_close",
        .mux_detach => "mux_detach",
        .paste_clipboard => "paste_clipboard",
        .copy_selection => "copy_selection",
        .copy_screen => "copy_screen",
        .copy_scrollback => "copy_scrollback",
        .copy_command_output => "copy_command_output",
        .select_command_output => "select_command_output",
        .interrupt_or_copy => "interrupt_or_copy",
        .clear_and_scrollback => "clear_and_scrollback",
        .clear_scrollback => "clear_scrollback",
        .scrollback_page_up => "scrollback_page_up",
        .scrollback_page_down => "scrollback_page_down",
        .scrollback_top => "scrollback_top",
        .scrollback_bottom => "scrollback_bottom",
        .command_palette => "command_palette",
        .hints_open => "hints_open",
        .copy_mode => "copy_mode",
        .zoom_pane => "zoom_pane",
        .select_all => "select_all",
        .context_menu => "context_menu",
    };
}

pub fn actionFromName(name: []const u8) ?Action {
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

/// Human-friendly label for the prefs UI.
pub fn actionLabel(a: Action) []const u8 {
    return switch (a) {
        .new_tab => "New tab",
        .close_tab => "Close tab",
        .next_tab => "Next tab",
        .prev_tab => "Previous tab",
        .copy => "Copy",
        .paste => "Paste",
        .split_h => "Split horizontal",
        .split_v => "Split vertical",
        .font_inc => "Increase font size",
        .font_dec => "Decrease font size",
        .font_reset => "Reset font size",
        .search_open => "Open search",
        .cross_search => "Search all sessions",
        .attach_all => "Attach all sessions",
        .save_layout => "Save layout",
        .save_layout_as => "Save layout as…",
        .save_default_layout => "Save layout as default",
        .load_layout => "Load layout…",
        .prompt_prev => "Jump to previous prompt",
        .prompt_next => "Jump to next prompt",
        .pane_next => "Next pane",
        .pane_prev => "Previous pane",
        .prefs_open => "Open Preferences",
        .broadcast_cycle => "Broadcast typing (cycle)",
        .restore_closed_tab => "Re-open closed tab",
        .toggle_pin_tab => "Pin / unpin current tab",
        .toggle_tab_bar => "Show / hide tab bar",
        .toggle_tab_sidebar => "Show / hide tab tree sidebar",
        .tab_collapse => "Collapse tab subtree",
        .tab_expand => "Expand tab subtree",
        .tab_tree_next => "Next tab (tree order)",
        .tab_tree_prev => "Previous tab (tree order)",
        .reload_config => "Reload config from disk",
        .launch_app => "Launch app on this host…",
        .app_windows => "Session overview (applications, audio and sessions)…",
        .goto_tab_1 => "Jump to tab 1",
        .goto_tab_2 => "Jump to tab 2",
        .goto_tab_3 => "Jump to tab 3",
        .goto_tab_4 => "Jump to tab 4",
        .goto_tab_5 => "Jump to tab 5",
        .goto_tab_6 => "Jump to tab 6",
        .goto_tab_7 => "Jump to tab 7",
        .goto_tab_8 => "Jump to tab 8",
        .goto_tab_9 => "Jump to tab 9",
        .duplicate_tab => "Duplicate tab (cwd + profile)",
        .detach_tab => "Detach tab into a new window",
        .configure_shader => "Configure shader (sliders for the pane's shader params)",
        .shader_preset_pick => "Shader preset (apply or delete a saved shader preset)",
        .apply_profile => "Apply profile to pane (colors, font, scrollback…)",
        .show_scrollback => "Show scrollback in pager",
        .new_durable_tab => "New durable tab (mux)",
        .new_browser_tab => "New file browser tab",
        .new_browser_split => "Split into a second file browser pane",
        .new_web_tab => "New web tab (browser engine)",
        .new_web_split => "Split into a web pane (browser engine)",
        .new_incognito_web_tab => "New incognito web tab (private, ephemeral)",
        .web_hints => "Link hints on the web page (type a label to click)",
        .web_reader => "Reader view on/off (this pane's web page)",
        .web_discard_background => "Discard background web tabs (free their memory)",
        .web_devtools => "Open DevTools for this web pane (in a split)",
        .web_print_pdf => "Print this web page to a PDF file",
        .web_fill_password => "Fill a saved login from the keyring into this web page",
        .web_history => "Browsing history (search, open, forget pages)",
        .web_bookmarks => "Bookmarks (open, rename, reorder)",
        .close_pane => "Close the focused pane (un-split)",
        .toggle_browser_face => "Show the file browser / show the shell (this pane)",
        .new_editor_tab => "New text editor tab",
        .new_editor_split => "Split into a text editor pane",
        .toggle_editor_face => "Show the text editor / show the shell (this pane)",
        .panel_open => "Open a saved panel (this session's stored documents)…",
        .panel_close => "Close the panel on this pane, its tab, or the window's only one",
        .mux_detach => "Detach mux session (pane drops to a local shell)",
        .paste_clipboard => "Paste clipboard",
        .copy_selection => "Copy selection",
        .copy_screen => "Copy whole screen",
        .copy_scrollback => "Copy entire scrollback",
        .copy_command_output => "Copy last command output (needs shell integration)",
        .select_command_output => "Select last command output (needs shell integration)",
        .interrupt_or_copy => "Copy / interrupt (smart)",
        .clear_and_scrollback => "Clear screen + scrollback",
        .clear_scrollback => "Clear scrollback only",
        .scrollback_page_up => "Scroll back one page",
        .scrollback_page_down => "Scroll forward one page",
        .scrollback_top => "Jump to scrollback top",
        .scrollback_bottom => "Jump to scrollback bottom",
        .command_palette => "Open command palette",
        .hints_open => "Keyboard hints (open/copy URLs, paths, hashes)",
        .copy_mode => "Copy mode (keyboard selection)",
        .zoom_pane => "Zoom pane (fill the tab; toggle)",
        .select_all => "Select all (scrollback + screen)",
        .context_menu => "Open the context menu at the cursor",
    };
}

/// Format a (keyval, mods) pair as a GTK accelerator string —
/// "<Control><Shift>t" — for prefs display + config persistence.
/// Caller-owned slice via `allocator`. Returns "" when keyval is 0
/// (= unbound).
pub fn accelToString(allocator: std.mem.Allocator, keyval: c_uint, mods: c_uint) ![]u8 {
    if (keyval == 0) return try allocator.dupe(u8, "");
    const ptr = c.gtk_accelerator_name(keyval, mods);
    if (ptr == null) return try allocator.dupe(u8, "");
    defer c.g_free(ptr);
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
    return try allocator.dupe(u8, s);
}

/// Parse a GTK accelerator string. Returns null on failure (e.g. the
/// user typed garbage in their config). Caller filters.
pub fn parseAccel(accel: []const u8) ?struct { keyval: c_uint, mods: c_uint } {
    if (accel.len == 0) return null;
    var z_buf: [256:0]u8 = undefined;
    if (accel.len >= z_buf.len) return null;
    @memcpy(z_buf[0..accel.len], accel);
    z_buf[accel.len] = 0;

    var kv: c_uint = 0;
    var m: c_uint = 0;
    if (c.gtk_accelerator_parse(&z_buf, &kv, &m) == 0) return null;
    if (kv == 0) return null;
    return .{ .keyval = c.gdk_keyval_to_lower(kv), .mods = m };
}

pub fn attach(widget: *c.GtkWidget, terminal: *Terminal, allocator: std.mem.Allocator) !*Ctx {
    const ctx = try allocator.create(Ctx);
    ctx.* = .{ .widget = widget, .terminal = terminal };

    const ctrl = c.gtk_event_controller_key_new();

    // IM plumbing lives in imhost.zig (shared with the editor canvas
    // and the forwarded-app host). The terminal face resolves to
    // GtkIMContextSimple under `input_method = auto`, unconditionally:
    // dead keys in a shell are load-bearing and `auto` must not be
    // able to trade them away. See imhost.Strategy for the tradeoff.
    ctx.im = imhost.ImHost.attach(
        allocator,
        widget,
        @ptrCast(ctrl),
        .terminal,
        .{
            .ctx = @ptrCast(ctx),
            .on_commit = onImCommit,
            .on_preedit = onImPreedit,
            .on_preedit_end = onImPreeditEnd,
        },
    ) catch null;

    _ = c.g_signal_connect_data(
        ctrl,
        "key-pressed",
        @ptrCast(&onKeyPressed),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    // Key-released — only emits to PTY when kitty kbd report-events
    // (flag 0x02) is enabled. Otherwise it's a no-op.
    _ = c.g_signal_connect_data(
        ctrl,
        "key-released",
        @ptrCast(&onKeyReleased),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(widget, @ptrCast(ctrl));

    c.gtk_widget_set_focusable(widget, 1);
    _ = c.gtk_widget_grab_focus(widget);
    return ctx;
}

/// Assemble the encoder's view of a key event: the modifier set, plus
/// the layout-derived facts only GDK can answer — what this physical
/// key produces unmodified and with Shift, and the true lock states
/// (GdkModifierType has a bit for Caps Lock but none for Num Lock).
fn keyInputFor(
    ctx: *Ctx,
    kctrl: *c.GtkEventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    state: c.GdkModifierType,
    event: KeyEventType,
) KeyInput {
    const screen = ctx.terminal.screen;
    var in = KeyInput{
        .keyval = keyval,
        .keycode = keycode,
        .mods = Mods.fromState(state),
        .event = event,
        .app_cursor = screen.app_cursor_keys,
        .app_keypad = screen.app_keypad,
        .modify_other_keys = screen.modify_other_keys,
        .kitty_flags = screen.kitty_kbd_flags,
    };

    var group: c_int = 0;
    if (c.gtk_event_controller_get_current_event(@ptrCast(kctrl))) |ev| {
        group = @intCast(c.gdk_key_event_get_layout(ev));
        if (c.gdk_event_get_device(ev)) |dev| {
            in.mods.caps_lock = c.gdk_device_get_caps_lock_state(dev) != 0;
            in.mods.num_lock = c.gdk_device_get_num_lock_state(dev) != 0;
        }
    }
    if (keycode != 0) {
        const display = c.gtk_widget_get_display(ctx.widget);
        var kv: c_uint = 0;
        var eff_group: c_int = 0;
        var level: c_int = 0;
        var consumed: c.GdkModifierType = 0;
        if (c.gdk_display_translate_key(display, keycode, 0, group, &kv, &eff_group, &level, &consumed) != 0)
            in.base_keyval = kv;
        if (c.gdk_display_translate_key(display, keycode, c.GDK_SHIFT_MASK, group, &kv, &eff_group, &level, &consumed) != 0)
            in.shifted_keyval = kv;
    }
    return in;
}

/// Key-released handler. Silent unless the application enabled kitty
/// keyboard event reporting (flag 0x02) — and even then `encode` drops
/// releases of keys whose press is a plain control byte, which have no
/// release encoding.
fn onKeyReleased(
    kctrl: *c.GtkEventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    // Clear the repeat-detection memory so the next press is treated
    // as fresh. Tracked regardless of whether kitty reports are on so
    // a later toggle starts from clean state.
    if (ctx.last_press_keyval == keyval) {
        ctx.last_press_keyval = 0;
        ctx.last_press_time_us = 0;
    }

    var buf: [64]u8 = undefined;
    const n = encode(&buf, keyInputFor(ctx, kctrl, keyval, keycode, state, .release));
    if (n > 0) ctx.terminal.writeUserInput(buf[0..n]);
}

fn onImCommit(user: ?*anyopaque, text: []const u8) void {
    const ctx = cast.userData(Ctx, user);
    if (text.len > 0) {
        if (!commitAsKeyReport(ctx, text)) ctx.terminal.writeUserInput(text);
    }
    // Clear any preedit on commit (preedit-end also fires, but not
    // every IM emits it before the commit).
    setPreedit(ctx, "");
}

/// Report an input-method commit as the protocol's text-only key
/// event, `CSI 0 ; ; <codepoints> u`. Only applies when the
/// application asked for every key as an escape code AND for the text
/// alongside it; with report-all alone we still send the raw bytes
/// rather than let a composed character vanish. @return false when the
/// caller should write the text itself.
fn commitAsKeyReport(ctx: *Ctx, text: []const u8) bool {
    const flags = ctx.terminal.screen.kitty_kbd_flags;
    if ((flags & FLAG_REPORT_ALL) == 0 or (flags & FLAG_ASSOCIATED_TEXT) == 0) return false;

    var cps: [16]u32 = undefined;
    var n: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (n == cps.len) return false;
        cps[n] = cp;
        n += 1;
    }
    if (n == 0) return false;

    var buf: [256]u8 = undefined;
    const len = emitCsi(&buf, .{ .num = 0, .text = cps[0..n] });
    if (len == 0) return false;
    ctx.terminal.writeUserInput(buf[0..len]);
    return true;
}

/// Composition text is rendered as grid cells by GridPass — the
/// character cursor is unused here, cells are laid out from the byte
/// string starting at the terminal cursor.
fn onImPreedit(user: ?*anyopaque, text: []const u8, _: usize) void {
    setPreedit(cast.userData(Ctx, user), text);
}

fn onImPreeditEnd(user: ?*anyopaque) void {
    setPreedit(cast.userData(Ctx, user), "");
}

fn setPreedit(ctx: *Ctx, text: []const u8) void {
    const screen = ctx.terminal.screen;
    if (screen.preedit_text == null and text.len == 0) return;
    if (screen.preedit_text) |old| screen.allocator.free(old);
    screen.preedit_text = if (text.len > 0) screen.allocator.dupe(u8, text) catch null else null;
    screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
}

fn onKeyPressed(
    kctrl: *c.GtkEventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const ctx = cast.userData(Ctx, user);

    // Hint mode owns the keyboard while active — feed it everything
    // before shortcuts / PTY encoding. A false return (unconsumed)
    // only happens for keys hint mode ignores, e.g. bare modifiers.
    if (ctx.hint_sink) |hs| {
        if (hs(ctx.hint_ctx, keyval, state)) return 1;
    }

    // Copy mode owns the keyboard while active — nothing below
    // (bindings, IME, PTY encoding) sees the key. Bare modifier
    // presses return false from the sink and fall through so GTK's
    // modifier tracking stays coherent.
    if (ctx.copymode_sink) |sink| {
        if (sink(ctx.copymode_ctx, keyval, state)) return 1;
        return 0;
    }

    // mouse_autohide: hide the pointer over the widget while typing.
    // The Pane's onMotion handler clears it again on next pointer
    // motion. Pure modifier keys (Shift/Ctrl/Alt/Super alone) are
    // skipped — those don't represent actual typing.
    if (ctx.mouse_autohide) switch (keyval) {
        c.GDK_KEY_Shift_L, c.GDK_KEY_Shift_R,
        c.GDK_KEY_Control_L, c.GDK_KEY_Control_R,
        c.GDK_KEY_Alt_L, c.GDK_KEY_Alt_R,
        c.GDK_KEY_Super_L, c.GDK_KEY_Super_R,
        c.GDK_KEY_Hyper_L, c.GDK_KEY_Hyper_R,
        c.GDK_KEY_Meta_L, c.GDK_KEY_Meta_R,
        c.GDK_KEY_Caps_Lock, c.GDK_KEY_Num_Lock,
        => {},
        else => {
            c.gtk_widget_set_cursor_from_name(ctx.widget, "none");
            if (ctx.autohide_set) |f| f(ctx.pane_ctx, true);
        },
    };

    // Detect auto-repeat by comparing against the last press of the
    // same keyval within REPEAT_WINDOW_US. Used by the kitty kbd
    // protocol when flag 0x02 (report-events) is enabled.
    const press_now = @import("../util/profile.zig").microTimestamp();
    const is_repeat = ctx.last_press_keyval == keyval and
        ctx.last_press_time_us != 0 and
        (press_now - ctx.last_press_time_us) < REPEAT_WINDOW_US;
    ctx.last_press_keyval = keyval;
    ctx.last_press_time_us = press_now;

    // IME filtering happens automatically — gtk_event_controller_key_
    // set_im_context (in attach()) routes events through the IM context
    // before this handler runs, so key-pressed only fires for keys the
    // IM did not consume. Re-submitting via filter_keypress here would
    // double-process the event.

    // Keybinding match — see fallbackToPaneBindings.
    if (fallbackToPaneBindings(ctx, keyval, state)) |handled| return handled;

    var buf: [64]u8 = undefined;
    const screen = ctx.terminal.screen;
    const event: KeyEventType = if (is_repeat) .repeat else .press;
    const n = encode(&buf, keyInputFor(ctx, kctrl, keyval, keycode, state, event));
    if (n == 0) return 0;
    // A bare modifier is reported (under flag 0x08) but never
    // consumed, and never counts as typing: GTK's own modifier
    // bookkeeping runs off these same events.
    if (isModifierKey(keyval)) {
        ctx.terminal.writeUserInput(buf[0..n]);
        return 0;
    }
    // Snap to bottom on keypress (matches xterm/iterm2/etc behavior).
    if (screen.view_offset != 0) {
        screen.view_offset = 0;
        screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
    }
    ctx.terminal.writeUserInput(buf[0..n]);
    return 1;
}

/// Execute a bound action. Returns 1 if handled (the input event
/// is consumed) so the caller doesn't fall through to byte encoding.
/// Per-pane actions handle themselves; Window-level actions go via
/// `shortcut_sink`.
///
/// Public so the command palette can dispatch the per-pane half of
/// the same action set (copy/paste/scrollback/...) against the
/// focused pane's input context — same code path as the keybind
/// version, no divergence.
pub fn runAction(ctx: *Ctx, action: Action) c.gboolean {
    switch (action) {
        // Per-pane (local).
        .toggle_browser_face => {
            // A pane with no browser face has nothing to swap to; the
            // key belongs to whatever is listening next (the shell).
            const flip = ctx.browser_toggle orelse return 0;
            return if (flip(ctx.pane_ctx)) 1 else 0;
        },
        .toggle_editor_face => {
            const flip = ctx.editor_toggle orelse return 0;
            return if (flip(ctx.pane_ctx)) 1 else 0;
        },
        // One hints chord, face decides: a pane wearing the web face
        // gets LINK hints (the terminal quick-select would scan the
        // hidden shell under it); otherwise the window-level sink runs
        // the terminal hints for `hints_open`, or explains itself for
        // an explicit `web_hints` on a non-web pane.
        .web_hints, .hints_open => {
            if (ctx.web_hints) |start| {
                if (start(ctx.pane_ctx)) return 1;
            }
            if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, action);
            return 1;
        },
        .context_menu => {
            const show = ctx.context_menu orelse return 0;
            return if (show(ctx.pane_ctx)) 1 else 0;
        },
        .select_all => {
            const screen = ctx.terminal.screen;
            // line_select over [-scrollbackCount .. rows-1] is exactly
            // what a full-height mouse drag in line mode produces, so
            // extractSelection / the highlight need no special case.
            const back: i32 = @intCast(screen.scrollbackCount());
            const last_row: i32 = @as(i32, @intCast(screen.rows)) - 1;
            screen.selection.start(-back, 0, .line_select);
            screen.selection.extend(last_row, @intCast(screen.cols));
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
            return 1;
        },
        .paste_clipboard => {
            clipboard.pasteFromClipboard(ctx.widget, ctx.terminal);
            return 1;
        },
        .copy_selection => {
            copySelection(ctx);
            return 1;
        },
        .copy_screen => {
            copyScreen(ctx);
            return 1;
        },
        .copy_scrollback => {
            copyScrollback(ctx);
            return 1;
        },
        .copy_command_output => {
            copyCommandOutput(ctx);
            return 1;
        },
        .select_command_output => {
            const screen = ctx.terminal.screen;
            const z = screen.cmdZone(0) orelse return 1;
            const row = screen.rowForLineIdFast(z.start_id) orelse return 1;
            if (screen.selectCmdZoneAt(row)) {
                c.gtk_widget_queue_draw(ctx.widget);
            }
            return 1;
        },
        .interrupt_or_copy => {
            // smart_copy: no selection AND smart_copy on → forward
            // Ctrl+C (interrupt). Off → noop. Selection present →
            // copy. Matches the previous Ctrl+Shift+C behaviour.
            if (!ctx.terminal.screen.selection.isActive() and ctx.smart_copy) {
                ctx.terminal.writeUserInput(&[_]u8{0x03});
                return 1;
            }
            copySelection(ctx);
            return 1;
        },
        .clear_and_scrollback => {
            ctx.terminal.screen.clearAndScrollback();
            return 1;
        },
        .clear_scrollback => {
            ctx.terminal.screen.clearScrollbackOnly();
            return 1;
        },
        .scrollback_page_up => {
            const screen = ctx.terminal.screen;
            const sb: u32 = @intCast(screen.scrollbackCount());
            const want = screen.view_offset + screen.rows;
            screen.view_offset = if (want > sb) sb else want;
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
            return 1;
        },
        .scrollback_page_down => {
            const screen = ctx.terminal.screen;
            screen.view_offset = if (screen.view_offset >= screen.rows)
                screen.view_offset - screen.rows
            else
                0;
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
            return 1;
        },
        .scrollback_top => {
            const screen = ctx.terminal.screen;
            screen.view_offset = @intCast(screen.scrollbackCount());
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
            return 1;
        },
        .scrollback_bottom => {
            const screen = ctx.terminal.screen;
            screen.view_offset = 0;
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
            return 1;
        },
        // Window-level: forward to the sink.
        else => {
            if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, action);
            return 1;
        },
    }
}

fn copySelection(ctx: *Ctx) void {
    const screen = ctx.terminal.screen;
    if (!screen.selection.isActive()) return;
    const text = screen.extractSelection(ctx.terminal.allocator) catch return;
    defer ctx.terminal.allocator.free(text);
    if (text.len == 0) return;

    // Copy to system clipboard.
    clipboard.copyText(ctx.widget, text);

    if (ctx.clear_select_on_copy) {
        screen.selection.clear();
        screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
    }
}

fn copyScreen(ctx: *Ctx) void {
    const screen = ctx.terminal.screen;
    const text = screen.extractScreen(ctx.terminal.allocator) catch return;
    defer ctx.terminal.allocator.free(text);
    if (text.len == 0) return;

    clipboard.copyText(ctx.widget, text);
}

fn copyScrollback(ctx: *Ctx) void {
    const screen = ctx.terminal.screen;
    const text = screen.extractScrollback(ctx.terminal.allocator) catch return;
    defer ctx.terminal.allocator.free(text);
    if (text.len == 0) return;

    clipboard.copyText(ctx.widget, text);
}

fn copyCommandOutput(ctx: *Ctx) void {
    const screen = ctx.terminal.screen;
    const maybe = screen.extractLastCommandOutput(ctx.terminal.allocator) catch return;
    const text = maybe orelse return;
    defer ctx.terminal.allocator.free(text);
    if (text.len == 0) return;

    clipboard.copyText(ctx.widget, text);
}

/// xterm modifier encoding: 1 + shift(1) + alt(2) + ctrl(4).
pub fn modCode(shift: bool, alt: bool, ctrl: bool) u8 {
    return 1 + (if (shift) @as(u8, 1) else 0) + (if (alt) @as(u8, 2) else 0) + (if (ctrl) @as(u8, 4) else 0);
}

/// Cursor-key emit. Without modifiers: ESC [/O X. With modifiers:
/// always ESC [ 1 ; M X (no DECCKM swap, per xterm).
pub fn cursorKey(buf: []u8, ck: u8, final: u8, shift: bool, alt: bool, ctrl: bool) usize {
    const m = modCode(shift, alt, ctrl);
    if (m == 1) {
        buf[0] = 0x1B;
        buf[1] = ck;
        buf[2] = final;
        return 3;
    }
    const out = std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ m, final }) catch return 0;
    return out.len;
}

/// "Tilde" key emit (PgUp/PgDn/Ins/Del, F5+). Plain: ESC [ N ~.
/// Modified: ESC [ N ; M ~.
pub fn tildeKey(buf: []u8, n: u8, shift: bool, alt: bool, ctrl: bool) usize {
    const m = modCode(shift, alt, ctrl);
    if (m == 1) {
        const out = std.fmt.bufPrint(buf, "\x1b[{d}~", .{n}) catch return 0;
        return out.len;
    }
    const out = std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ n, m }) catch return 0;
    return out.len;
}

/// SS3 key emit (F1-F4). Plain: ESC O X. Modified: ESC [ 1 ; M X.
pub fn ssoKey(buf: []u8, final: u8, shift: bool, alt: bool, ctrl: bool) usize {
    const m = modCode(shift, alt, ctrl);
    if (m == 1) {
        buf[0] = 0x1B;
        buf[1] = 'O';
        buf[2] = final;
        return 3;
    }
    const out = std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ m, final }) catch return 0;
    return out.len;
}

// ── Kitty keyboard protocol ──────────────────────────────────────
//
// https://sw.kovidgoyal.net/kitty/keyboard-protocol/
// Progressive-enhancement flags, all independently settable:

pub const FLAG_DISAMBIGUATE: u8 = 0x01;
pub const FLAG_EVENT_TYPES: u8 = 0x02;
pub const FLAG_ALTERNATE_KEYS: u8 = 0x04;
pub const FLAG_REPORT_ALL: u8 = 0x08;
pub const FLAG_ASSOCIATED_TEXT: u8 = 0x10;

/// Modifier set in the protocol's own bit order, so `bits()` is the
/// value the wire format wants minus its +1 bias.
pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    pub fn bits(self: Mods) u8 {
        return @bitCast(self);
    }

    /// Kitty's modifier parameter: 1 + the whole bit field, lock keys
    /// included.
    pub fn kittyParam(self: Mods) u32 {
        return 1 + @as(u32, self.bits());
    }

    /// xterm's modifier parameter. Deliberately narrower than
    /// `kittyParam`: only Shift/Alt/Ctrl exist in the legacy encoding,
    /// so holding Super or turning Caps Lock on must not perturb a
    /// sequence a non-kitty application is reading.
    pub fn legacyParam(self: Mods) u8 {
        return modCode(self.shift, self.alt, self.ctrl);
    }

    pub fn fromState(state: c.GdkModifierType) Mods {
        return .{
            .shift = (state & c.GDK_SHIFT_MASK) != 0,
            .alt = (state & c.GDK_ALT_MASK) != 0,
            .ctrl = (state & c.GDK_CONTROL_MASK) != 0,
            .super = (state & c.GDK_SUPER_MASK) != 0,
            .hyper = (state & c.GDK_HYPER_MASK) != 0,
            .meta = (state & c.GDK_META_MASK) != 0,
            .caps_lock = (state & c.GDK_LOCK_MASK) != 0,
        };
    }

    /// Any modifier that changes which bytes a key produces. Caps and
    /// Num Lock are excluded: they change the keyval, not the encoding.
    pub fn anyEncoding(self: Mods) bool {
        return self.shift or self.alt or self.ctrl or self.super or self.hyper or self.meta;
    }

    /// Any modifier other than Shift. Shift is excluded because on a
    /// text key it only selects a different glyph, which the legacy
    /// encoding already expresses by sending that glyph.
    pub fn beyondShift(self: Mods) bool {
        return self.alt or self.ctrl or self.super or self.hyper or self.meta;
    }
};

pub const KeyEventType = enum(u8) { press = 1, repeat = 2, release = 3 };

/// One key report. Field order and every omission rule below mirror
/// kitty's reference encoder:
///   `CSI <num>[:<shifted>[:<base>]][;<mods>[:<event>]][;<text>] <trailer>`
pub const CsiKey = struct {
    num: u32 = 1,
    /// Shifted variant of `num`; only ever set when Shift is held.
    shifted: u32 = 0,
    /// The same physical key on a US PC-101 layout, when it differs
    /// from `num` — this is what lets an application's Ctrl+C binding
    /// keep working on a Cyrillic or Greek layout.
    base_layout: u32 = 0,
    mods: Mods = .{},
    /// Override for the modifier parameter. The legacy VT encodings
    /// use a narrower set than the protocol's, so the caller supplies
    /// the value rather than the emitter assuming kitty's.
    mods_param: ?u32 = null,
    event: KeyEventType = .press,
    /// Codepoints the keystroke produces as text (flag 0x10).
    text: []const u32 = &.{},
    /// Final byte: 'u' for CSI-u keys, '~' or a letter for the
    /// functional keys that have a legacy encoding.
    trailer: u8 = 'u',
};

fn appendf(buf: []u8, w: *usize, comptime fmt: []const u8, args: anytype) bool {
    const out = std.fmt.bufPrint(buf[w.*..], fmt, args) catch return false;
    w.* += out.len;
    return true;
}

/// Emit a key report. Returns 0 if it does not fit in `buf` (64 bytes
/// is always enough).
pub fn emitCsi(buf: []u8, k: CsiKey) usize {
    var w: usize = 0;
    if (!appendf(buf, &w, "\x1b[", .{})) return 0;

    const param: u32 = k.mods_param orelse k.mods.kittyParam();
    const has_alts = k.shifted != 0 or k.base_layout != 0;
    // `num` is omitted only in the shortest possible form, where the
    // default of 1 is unambiguous — `CSI A` for a bare Up arrow. We
    // also spell it out whenever an event type follows, so nothing
    // has to parse `CSI ;1:3A` with an empty leading parameter.
    if (k.num != 1 or param != 1 or has_alts or k.text.len > 0 or k.event != .press) {
        if (!appendf(buf, &w, "{d}", .{k.num})) return 0;
    }
    if (has_alts) {
        if (!appendf(buf, &w, ":", .{})) return 0;
        if (k.shifted != 0 and !appendf(buf, &w, "{d}", .{k.shifted})) return 0;
        if (k.base_layout != 0 and !appendf(buf, &w, ":{d}", .{k.base_layout})) return 0;
    }
    if (param != 1 or k.event != .press) {
        if (!appendf(buf, &w, ";{d}", .{param})) return 0;
        if (k.event != .press and !appendf(buf, &w, ":{d}", .{@intFromEnum(k.event)})) return 0;
    } else if (k.text.len > 0) {
        // The text section is positional, so an absent mods section
        // still needs its separator.
        if (!appendf(buf, &w, ";", .{})) return 0;
    }
    for (k.text, 0..) |cp, i| {
        if (!appendf(buf, &w, "{c}{d}", .{ @as(u8, if (i == 0) ';' else ':'), cp })) return 0;
    }
    if (!appendf(buf, &w, "{c}", .{k.trailer})) return 0;
    return w;
}

/// A key's protocol encoding: the CSI parameter and final byte kitty
/// assigns it. Keys with a legacy VT sequence keep it (`Up` stays
/// `CSI A`); only keys that never had one use a Private Use Area
/// codepoint with a `u` final.
pub const Functional = struct {
    num: u32,
    trailer: u8,
    /// Cursor keys swap `CSI` for `SS3` under DECCKM.
    cursor: bool = false,
    /// F1-F4 emit SS3 in their unmodified form.
    ss3: bool = false,
};

pub fn functionalKey(keyval: c_uint) ?Functional {
    return switch (keyval) {
        // Keys with a legacy control byte.
        c.GDK_KEY_Escape => .{ .num = 27, .trailer = 'u' },
        c.GDK_KEY_Return => .{ .num = 13, .trailer = 'u' },
        c.GDK_KEY_Tab, c.GDK_KEY_ISO_Left_Tab => .{ .num = 9, .trailer = 'u' },
        c.GDK_KEY_BackSpace => .{ .num = 127, .trailer = 'u' },
        // Editing / navigation.
        c.GDK_KEY_Insert => .{ .num = 2, .trailer = '~' },
        c.GDK_KEY_Delete => .{ .num = 3, .trailer = '~' },
        c.GDK_KEY_Page_Up => .{ .num = 5, .trailer = '~' },
        c.GDK_KEY_Page_Down => .{ .num = 6, .trailer = '~' },
        c.GDK_KEY_Up => .{ .num = 1, .trailer = 'A', .cursor = true },
        c.GDK_KEY_Down => .{ .num = 1, .trailer = 'B', .cursor = true },
        c.GDK_KEY_Right => .{ .num = 1, .trailer = 'C', .cursor = true },
        c.GDK_KEY_Left => .{ .num = 1, .trailer = 'D', .cursor = true },
        c.GDK_KEY_Begin => .{ .num = 1, .trailer = 'E', .cursor = true },
        c.GDK_KEY_End => .{ .num = 1, .trailer = 'F', .cursor = true },
        c.GDK_KEY_Home => .{ .num = 1, .trailer = 'H', .cursor = true },
        // Lock and system keys — no legacy encoding.
        c.GDK_KEY_Caps_Lock => .{ .num = 57358, .trailer = 'u' },
        c.GDK_KEY_Scroll_Lock => .{ .num = 57359, .trailer = 'u' },
        c.GDK_KEY_Num_Lock => .{ .num = 57360, .trailer = 'u' },
        c.GDK_KEY_Print => .{ .num = 57361, .trailer = 'u' },
        c.GDK_KEY_Pause => .{ .num = 57362, .trailer = 'u' },
        c.GDK_KEY_Menu => .{ .num = 57363, .trailer = 'u' },
        // Function keys. F1-F12 keep their VT encodings.
        c.GDK_KEY_F1 => .{ .num = 1, .trailer = 'P', .ss3 = true },
        c.GDK_KEY_F2 => .{ .num = 1, .trailer = 'Q', .ss3 = true },
        c.GDK_KEY_F3 => .{ .num = 13, .trailer = '~' },
        c.GDK_KEY_F4 => .{ .num = 1, .trailer = 'S', .ss3 = true },
        c.GDK_KEY_F5 => .{ .num = 15, .trailer = '~' },
        c.GDK_KEY_F6 => .{ .num = 17, .trailer = '~' },
        c.GDK_KEY_F7 => .{ .num = 18, .trailer = '~' },
        c.GDK_KEY_F8 => .{ .num = 19, .trailer = '~' },
        c.GDK_KEY_F9 => .{ .num = 20, .trailer = '~' },
        c.GDK_KEY_F10 => .{ .num = 21, .trailer = '~' },
        c.GDK_KEY_F11 => .{ .num = 23, .trailer = '~' },
        c.GDK_KEY_F12 => .{ .num = 24, .trailer = '~' },
        c.GDK_KEY_F13 => .{ .num = 57376, .trailer = 'u' },
        c.GDK_KEY_F14 => .{ .num = 57377, .trailer = 'u' },
        c.GDK_KEY_F15 => .{ .num = 57378, .trailer = 'u' },
        c.GDK_KEY_F16 => .{ .num = 57379, .trailer = 'u' },
        c.GDK_KEY_F17 => .{ .num = 57380, .trailer = 'u' },
        c.GDK_KEY_F18 => .{ .num = 57381, .trailer = 'u' },
        c.GDK_KEY_F19 => .{ .num = 57382, .trailer = 'u' },
        c.GDK_KEY_F20 => .{ .num = 57383, .trailer = 'u' },
        c.GDK_KEY_F21 => .{ .num = 57384, .trailer = 'u' },
        c.GDK_KEY_F22 => .{ .num = 57385, .trailer = 'u' },
        c.GDK_KEY_F23 => .{ .num = 57386, .trailer = 'u' },
        c.GDK_KEY_F24 => .{ .num = 57387, .trailer = 'u' },
        c.GDK_KEY_F25 => .{ .num = 57388, .trailer = 'u' },
        c.GDK_KEY_F26 => .{ .num = 57389, .trailer = 'u' },
        c.GDK_KEY_F27 => .{ .num = 57390, .trailer = 'u' },
        c.GDK_KEY_F28 => .{ .num = 57391, .trailer = 'u' },
        c.GDK_KEY_F29 => .{ .num = 57392, .trailer = 'u' },
        c.GDK_KEY_F30 => .{ .num = 57393, .trailer = 'u' },
        c.GDK_KEY_F31 => .{ .num = 57394, .trailer = 'u' },
        c.GDK_KEY_F32 => .{ .num = 57395, .trailer = 'u' },
        c.GDK_KEY_F33 => .{ .num = 57396, .trailer = 'u' },
        c.GDK_KEY_F34 => .{ .num = 57397, .trailer = 'u' },
        c.GDK_KEY_F35 => .{ .num = 57398, .trailer = 'u' },
        // Keypad. GTK reports the digit keysyms only while Num Lock
        // is on and the navigation ones while it is off, so both
        // halves of the table are reachable.
        c.GDK_KEY_KP_0 => .{ .num = 57399, .trailer = 'u' },
        c.GDK_KEY_KP_1 => .{ .num = 57400, .trailer = 'u' },
        c.GDK_KEY_KP_2 => .{ .num = 57401, .trailer = 'u' },
        c.GDK_KEY_KP_3 => .{ .num = 57402, .trailer = 'u' },
        c.GDK_KEY_KP_4 => .{ .num = 57403, .trailer = 'u' },
        c.GDK_KEY_KP_5 => .{ .num = 57404, .trailer = 'u' },
        c.GDK_KEY_KP_6 => .{ .num = 57405, .trailer = 'u' },
        c.GDK_KEY_KP_7 => .{ .num = 57406, .trailer = 'u' },
        c.GDK_KEY_KP_8 => .{ .num = 57407, .trailer = 'u' },
        c.GDK_KEY_KP_9 => .{ .num = 57408, .trailer = 'u' },
        c.GDK_KEY_KP_Decimal => .{ .num = 57409, .trailer = 'u' },
        c.GDK_KEY_KP_Divide => .{ .num = 57410, .trailer = 'u' },
        c.GDK_KEY_KP_Multiply => .{ .num = 57411, .trailer = 'u' },
        c.GDK_KEY_KP_Subtract => .{ .num = 57412, .trailer = 'u' },
        c.GDK_KEY_KP_Add => .{ .num = 57413, .trailer = 'u' },
        c.GDK_KEY_KP_Enter => .{ .num = 57414, .trailer = 'u' },
        c.GDK_KEY_KP_Equal => .{ .num = 57415, .trailer = 'u' },
        c.GDK_KEY_KP_Separator => .{ .num = 57416, .trailer = 'u' },
        c.GDK_KEY_KP_Left => .{ .num = 57417, .trailer = 'u' },
        c.GDK_KEY_KP_Right => .{ .num = 57418, .trailer = 'u' },
        c.GDK_KEY_KP_Up => .{ .num = 57419, .trailer = 'u' },
        c.GDK_KEY_KP_Down => .{ .num = 57420, .trailer = 'u' },
        c.GDK_KEY_KP_Page_Up => .{ .num = 57421, .trailer = 'u' },
        c.GDK_KEY_KP_Page_Down => .{ .num = 57422, .trailer = 'u' },
        c.GDK_KEY_KP_Home => .{ .num = 57423, .trailer = 'u' },
        c.GDK_KEY_KP_End => .{ .num = 57424, .trailer = 'u' },
        c.GDK_KEY_KP_Insert => .{ .num = 57425, .trailer = 'u' },
        c.GDK_KEY_KP_Delete => .{ .num = 57426, .trailer = 'u' },
        c.GDK_KEY_KP_Begin => .{ .num = 1, .trailer = 'E', .cursor = true },
        // Media keys.
        c.GDK_KEY_AudioPlay => .{ .num = 57428, .trailer = 'u' },
        c.GDK_KEY_AudioPause => .{ .num = 57429, .trailer = 'u' },
        c.GDK_KEY_AudioStop => .{ .num = 57432, .trailer = 'u' },
        c.GDK_KEY_AudioForward => .{ .num = 57433, .trailer = 'u' },
        c.GDK_KEY_AudioRewind => .{ .num = 57434, .trailer = 'u' },
        c.GDK_KEY_AudioNext => .{ .num = 57435, .trailer = 'u' },
        c.GDK_KEY_AudioPrev => .{ .num = 57436, .trailer = 'u' },
        c.GDK_KEY_AudioRecord => .{ .num = 57437, .trailer = 'u' },
        c.GDK_KEY_AudioLowerVolume => .{ .num = 57438, .trailer = 'u' },
        c.GDK_KEY_AudioRaiseVolume => .{ .num = 57439, .trailer = 'u' },
        c.GDK_KEY_AudioMute => .{ .num = 57440, .trailer = 'u' },
        // The modifier keys themselves — reported only under 0x08.
        c.GDK_KEY_Shift_L => .{ .num = 57441, .trailer = 'u' },
        c.GDK_KEY_Control_L => .{ .num = 57442, .trailer = 'u' },
        c.GDK_KEY_Alt_L => .{ .num = 57443, .trailer = 'u' },
        c.GDK_KEY_Super_L => .{ .num = 57444, .trailer = 'u' },
        c.GDK_KEY_Hyper_L => .{ .num = 57445, .trailer = 'u' },
        c.GDK_KEY_Meta_L => .{ .num = 57446, .trailer = 'u' },
        c.GDK_KEY_Shift_R => .{ .num = 57447, .trailer = 'u' },
        c.GDK_KEY_Control_R => .{ .num = 57448, .trailer = 'u' },
        c.GDK_KEY_Alt_R => .{ .num = 57449, .trailer = 'u' },
        c.GDK_KEY_Super_R => .{ .num = 57450, .trailer = 'u' },
        c.GDK_KEY_Hyper_R => .{ .num = 57451, .trailer = 'u' },
        c.GDK_KEY_Meta_R => .{ .num = 57452, .trailer = 'u' },
        c.GDK_KEY_ISO_Level3_Shift => .{ .num = 57453, .trailer = 'u' },
        c.GDK_KEY_ISO_Level5_Shift => .{ .num = 57454, .trailer = 'u' },
        else => null,
    };
}

/// True for keys that only ever act as modifiers. They are silent
/// unless the application asked for every key (0x08), and even then
/// the event is not consumed — GTK's own modifier bookkeeping runs on
/// the same events.
pub fn isModifierKey(keyval: c_uint) bool {
    return switch (keyval) {
        c.GDK_KEY_Shift_L, c.GDK_KEY_Shift_R,
        c.GDK_KEY_Control_L, c.GDK_KEY_Control_R,
        c.GDK_KEY_Alt_L, c.GDK_KEY_Alt_R,
        c.GDK_KEY_Super_L, c.GDK_KEY_Super_R,
        c.GDK_KEY_Hyper_L, c.GDK_KEY_Hyper_R,
        c.GDK_KEY_Meta_L, c.GDK_KEY_Meta_R,
        c.GDK_KEY_ISO_Level3_Shift, c.GDK_KEY_ISO_Level5_Shift,
        c.GDK_KEY_Caps_Lock, c.GDK_KEY_Num_Lock, c.GDK_KEY_Scroll_Lock,
        => true,
        else => false,
    };
}

/// Codepoint of the key at this hardware position on a US PC-101
/// layout, for the protocol's base-layout alternate (flag 0x04).
/// Only the alphanumeric block is mapped — those are the keys whose
/// application shortcuts break under a non-Latin layout. 0 = unknown.
///
/// GDK hardware keycodes are evdev codes + 8 on both X11 and Wayland;
/// on any other platform the caller gets 0 and the field is omitted.
pub fn baseLayoutCodepoint(keycode: c_uint) u32 {
    if (builtin.os.tag != .linux) return 0;
    return switch (keycode) {
        49 => '`',
        10 => '1', 11 => '2', 12 => '3', 13 => '4', 14 => '5', 15 => '6',
        16 => '7', 17 => '8', 18 => '9', 19 => '0', 20 => '-', 21 => '=',
        24 => 'q', 25 => 'w', 26 => 'e', 27 => 'r', 28 => 't', 29 => 'y',
        30 => 'u', 31 => 'i', 32 => 'o', 33 => 'p', 34 => '[', 35 => ']',
        38 => 'a', 39 => 's', 40 => 'd', 41 => 'f', 42 => 'g', 43 => 'h',
        44 => 'j', 45 => 'k', 46 => 'l', 47 => ';', 48 => '\'',
        51 => '\\',
        52 => 'z', 53 => 'x', 54 => 'c', 55 => 'v', 56 => 'b', 57 => 'n',
        58 => 'm', 59 => ',', 60 => '.', 61 => '/',
        65 => ' ',
        else => 0,
    };
}

/// Everything the encoder needs about one key event. The GTK layer
/// fills the layout-derived fields; a test can leave them at zero and
/// the encoder falls back to case-folding the keyval.
pub const KeyInput = struct {
    keyval: c_uint,
    mods: Mods = .{},
    event: KeyEventType = .press,
    /// Hardware keycode, for the base-layout alternate key. 0 = unknown.
    keycode: c_uint = 0,
    /// The keyval this physical key produces with no modifiers, and
    /// with Shift, in the active group. 0 = unknown.
    base_keyval: c_uint = 0,
    shifted_keyval: c_uint = 0,
    // Terminal modes.
    app_cursor: bool = false,
    app_keypad: bool = false,
    modify_other_keys: u8 = 0,
    kitty_flags: u8 = 0,
};

const Flags = struct {
    disamb: bool,
    events: bool,
    alt_keys: bool,
    report_all: bool,
    assoc: bool,

    fn from(bits: u8) Flags {
        return .{
            // Reporting every key as an escape code implies
            // disambiguating them.
            .disamb = (bits & (FLAG_DISAMBIGUATE | FLAG_REPORT_ALL)) != 0,
            .events = (bits & FLAG_EVENT_TYPES) != 0,
            .alt_keys = (bits & FLAG_ALTERNATE_KEYS) != 0,
            .report_all = (bits & FLAG_REPORT_ALL) != 0,
            .assoc = (bits & FLAG_ASSOCIATED_TEXT) != 0,
        };
    }

    /// True once the application has opted into the protocol at all,
    /// which is what licenses the wider modifier encoding.
    fn any(self: Flags) bool {
        return self.disamb or self.events or self.alt_keys or self.report_all or self.assoc;
    }
};

pub fn encode(buf: []u8, input: KeyInput) usize {
    var in = input;
    // ISO_Left_Tab is what X11 calls Shift+Tab; every layer below is
    // simpler if it never has to know that.
    if (in.keyval == c.GDK_KEY_ISO_Left_Tab) {
        in.keyval = c.GDK_KEY_Tab;
        in.mods.shift = true;
    }
    const fl = Flags.from(in.kitty_flags);
    // Without the event-types flag there is nowhere to put the event
    // type, so only presses (and auto-repeats, which look like
    // presses) produce anything at all.
    if (in.event == .release and !fl.events) return 0;
    const evt: KeyEventType = if (fl.events) in.event else .press;

    // Modifier keys report only when the application asked for every
    // key; otherwise they are silent, as they have been since VT100.
    if (isModifierKey(in.keyval)) {
        if (!fl.report_all) return 0;
        const f = functionalKey(in.keyval) orelse return 0;
        return emitCsi(buf, .{ .num = f.num, .mods = in.mods, .event = evt });
    }

    if (functionalKey(in.keyval)) |f| return encodeFunctional(buf, in, fl, evt, f);
    return encodeText(buf, in, fl, evt);
}

/// Keys that have a name in the protocol's functional table.
fn encodeFunctional(buf: []u8, in: KeyInput, fl: Flags, evt: KeyEventType, f: Functional) usize {
    // Application keypad mode (DECPAM): numpad keys emit `ESC O X`
    // sequences instead of plain digits / operators. Superseded by
    // report-all, which gives every keypad key its own codepoint.
    if (in.app_keypad and !fl.report_all) {
        const final: u8 = switch (in.keyval) {
            c.GDK_KEY_KP_0 => 'p',
            c.GDK_KEY_KP_1 => 'q',
            c.GDK_KEY_KP_2 => 'r',
            c.GDK_KEY_KP_3 => 's',
            c.GDK_KEY_KP_4 => 't',
            c.GDK_KEY_KP_5 => 'u',
            c.GDK_KEY_KP_6 => 'v',
            c.GDK_KEY_KP_7 => 'w',
            c.GDK_KEY_KP_8 => 'x',
            c.GDK_KEY_KP_9 => 'y',
            c.GDK_KEY_KP_Multiply => 'j',
            c.GDK_KEY_KP_Add => 'k',
            c.GDK_KEY_KP_Separator => 'l',
            c.GDK_KEY_KP_Subtract => 'm',
            c.GDK_KEY_KP_Decimal => 'n',
            c.GDK_KEY_KP_Divide => 'o',
            c.GDK_KEY_KP_Equal => 'X',
            c.GDK_KEY_KP_Enter => 'M',
            else => 0,
        };
        if (final != 0) {
            buf[0] = 0x1B;
            buf[1] = 'O';
            buf[2] = final;
            return 3;
        }
    }
    // Escape, Enter, Tab and Backspace are the four keys whose
    // "functional" encoding is a plain control byte. They keep it
    // unless the application has asked to have them disambiguated
    // (and then only when a modifier is involved, except for Escape,
    // which is ambiguous with the start of every other sequence) or
    // has asked for every key as an escape code.
    const legacy_byte: u8 = switch (in.keyval) {
        c.GDK_KEY_Escape => 0x1B,
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => '\r',
        c.GDK_KEY_BackSpace => 0x7F,
        c.GDK_KEY_Tab => '\t',
        else => 0,
    };
    if (legacy_byte != 0) {
        const force_csi = fl.report_all or
            (fl.disamb and (in.keyval == c.GDK_KEY_Escape or in.mods.anyEncoding()));
        if (force_csi) {
            return emitCsi(buf, .{ .num = f.num, .mods = in.mods, .event = evt });
        }
        // A control byte has nowhere to carry an event type, so a
        // release of one of these keys is simply not reportable —
        // kitty drops it too rather than inventing an encoding.
        if (evt == .release) return 0;
        if (in.keyval == c.GDK_KEY_Tab and in.mods.shift) {
            @memcpy(buf[0..3], "\x1b[Z");
            return 3;
        }
        // Ctrl+Backspace is ^H, the one legacy modifier combination
        // these keys encode themselves.
        const byte: u8 = if (in.keyval == c.GDK_KEY_BackSpace and in.mods.ctrl) 0x08 else legacy_byte;
        if (in.mods.alt) {
            buf[0] = 0x1B;
            buf[1] = byte;
            return 2;
        }
        buf[0] = byte;
        return 1;
    }

    // Everything else in the functional table: arrows, editing keys,
    // F-keys, keypad, media. The modifier parameter widens to the
    // protocol's only once the application has opted in, so a plain
    // VT app never sees a Super or lock bit it cannot interpret.
    const param: u32 = if (fl.any()) in.mods.kittyParam() else in.mods.legacyParam();
    if (param == 1 and evt == .press) {
        if (f.trailer == '~' or f.trailer == 'u') {
            const out = std.fmt.bufPrint(buf, "\x1b[{d}{c}", .{ f.num, f.trailer }) catch return 0;
            return out.len;
        }
        // Letter finals: SS3 for F1-F4 always, and for the cursor
        // keys under DECCKM.
        buf[0] = 0x1B;
        buf[1] = if (f.ss3 or (f.cursor and in.app_cursor)) 'O' else '[';
        buf[2] = f.trailer;
        return 3;
    }
    return emitCsi(buf, .{
        .num = f.num,
        .mods = in.mods,
        .mods_param = param,
        .event = evt,
        .trailer = f.trailer,
    });
}

/// Keys that produce text. `num` is always the key as it is with no
/// modifiers at all, with the shifted and base-layout variants
/// carried alongside it, so an application can bind the physical key
/// rather than whatever glyph the layout puts on it.
fn encodeText(buf: []u8, in: KeyInput, fl: Flags, evt: KeyEventType) usize {
    const ctrl = in.mods.ctrl;
    const alt = in.mods.alt;
    const shift = in.mods.shift;
    const mok = in.modify_other_keys;

    // Printable codepoint via gdk's keyval-to-unicode.
    const cp = c.gdk_keyval_to_unicode(in.keyval);
    if (cp == 0 or cp >= 0x110000) return 0;

    // The unmodified form of the same physical key. Falling back to
    // case-folding the keyval is only right for Latin letters, which
    // is why the GTK layer translates the keycode when it can.
    var base: u32 = if (in.base_keyval != 0) c.gdk_keyval_to_unicode(in.base_keyval) else 0;
    if (base == 0 or base >= 0x110000) {
        base = cp;
        if (base >= 'A' and base <= 'Z') base += 0x20;
    }

    const csi_form = fl.report_all or
        (fl.disamb and in.mods.beyondShift()) or
        (fl.events and evt != .press);
    if (csi_form) {
        var shifted: u32 = 0;
        var base_layout: u32 = 0;
        if (fl.alt_keys) {
            if (shift) {
                const s = if (in.shifted_keyval != 0) c.gdk_keyval_to_unicode(in.shifted_keyval) else cp;
                if (s != 0 and s < 0x110000 and s != base) shifted = s;
            }
            const bl = baseLayoutCodepoint(in.keycode);
            if (bl != 0 and bl != base) base_layout = bl;
        }
        // Associated text is what the keystroke would have produced
        // had it not been reported as an escape code; a control
        // modifier means it would have produced none.
        var text_storage: [1]u32 = .{0};
        var text: []const u32 = &.{};
        if (fl.assoc and evt != .release and !ctrl and !alt and !in.mods.super and !in.mods.hyper and !in.mods.meta) {
            text_storage[0] = cp;
            text = text_storage[0..1];
        }
        return emitCsi(buf, .{
            .num = base,
            .shifted = shifted,
            .base_layout = base_layout,
            .mods = in.mods,
            .event = evt,
            .text = text,
        });
    }
    // Legacy text encoding below — no way to express a release.
    if (evt == .release) return 0;

    // Ctrl + 0x40..0x7E → C0 control (Ctrl-A = 0x01, etc).
    if (ctrl and cp >= 0x40 and cp <= 0x7E) {
        // modifyOtherKeys: emit `CSI 27 ; M ; cp ~` so apps can
        // distinguish e.g. Ctrl+i from TAB. Level 2 = always; level
        // 1 = only ambiguous (i, m, [, h, @).
        const ambiguous = (cp == 'I' or cp == 'i' or
            cp == 'M' or cp == 'm' or
            cp == '[' or
            cp == 'H' or cp == 'h' or
            cp == '@');
        if (mok == 2 or (mok == 1 and ambiguous)) {
            const m = modCode(shift, alt, ctrl);
            const out = std.fmt.bufPrint(buf, "\x1b[27;{d};{d}~", .{ m, cp }) catch return 0;
            return out.len;
        }
        const code: u8 = @intCast(cp & 0x1F);
        if (alt) {
            buf[0] = 0x1B;
            buf[1] = code;
            return 2;
        }
        buf[0] = code;
        return 1;
    }

    // Ctrl-Space → NUL.
    if (ctrl and cp == ' ') {
        buf[0] = 0;
        return 1;
    }

    // Alt + ASCII → ESC + char.
    if (alt and cp < 0x80) {
        buf[0] = 0x1B;
        buf[1] = @intCast(cp);
        return 2;
    }

    // Plain UTF-8.
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return 1;
    }
    return std.unicode.utf8Encode(@intCast(cp), buf) catch 0;
}

test "cursorKey plain emits ESC [ X" {
    var buf: [16]u8 = undefined;
    const n = cursorKey(&buf, '[', 'A', false, false, false);
    try std.testing.expectEqualStrings("\x1b[A", buf[0..n]);
}

test "cursorKey app-mode emits ESC O X" {
    var buf: [16]u8 = undefined;
    const n = cursorKey(&buf, 'O', 'A', false, false, false);
    try std.testing.expectEqualStrings("\x1bOA", buf[0..n]);
}

test "cursorKey shift+ctrl modifier code 6" {
    var buf: [16]u8 = undefined;
    const n = cursorKey(&buf, '[', 'D', true, false, true);
    try std.testing.expectEqualStrings("\x1b[1;6D", buf[0..n]);
}

test "tildeKey alt modifier code 3" {
    var buf: [16]u8 = undefined;
    const n = tildeKey(&buf, 5, false, true, false);
    try std.testing.expectEqualStrings("\x1b[5;3~", buf[0..n]);
}

test "ssoKey plain F1 emits ESC O P" {
    var buf: [16]u8 = undefined;
    const n = ssoKey(&buf, 'P', false, false, false);
    try std.testing.expectEqualStrings("\x1bOP", buf[0..n]);
}

test "modCode encoding" {
    try std.testing.expectEqual(@as(u8, 1), modCode(false, false, false));
    try std.testing.expectEqual(@as(u8, 2), modCode(true, false, false));
    try std.testing.expectEqual(@as(u8, 3), modCode(false, true, false));
    try std.testing.expectEqual(@as(u8, 5), modCode(false, false, true));
    try std.testing.expectEqual(@as(u8, 8), modCode(true, true, true));
}
