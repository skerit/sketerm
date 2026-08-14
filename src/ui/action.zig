//! The user-facing action vocabulary — every command a keybind, menu
//! item or palette row can dispatch.
//!
//! GTK-free on purpose. This enum used to live in `input.zig`, which
//! imports `c.zig` and so dragged GTK in with it; that made the command
//! catalogue (`commandcat.zig`) impossible to compile into the
//! `test-core` root and unusable from any non-GTK frontend. Splitting
//! the vocabulary out from the key handling that consumes it is one
//! more step of the de-GTK-ing CLAUDE.md describes, alongside
//! `tree.zig` and `tabforest.zig`.
//!
//! `input.zig` re-exports this as `input.Action`, so every existing
//! reference keeps working against a single definition.

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
    /// Open the focused web pane's site-info popover
    /// (src/ui/websiteinfo.zig): this site's identity, the decisions it
    /// was given, and the cookies and storage it holds — with the way
    /// to undo each. The padlock button's keyboard equivalent.
    web_site_info,
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
    /// Flip the focused pane between its WEB face and its terminal
    /// face — the way back after "Show this pane's shell". Dispatched
    /// locally like toggle_browser_face; a pane without a web face
    /// leaves the key to the terminal.
    toggle_web_face,
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
