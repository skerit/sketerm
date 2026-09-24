//! Interactive overlay modes — keyboard hints (quick-select), scrollback
//! search, and copy mode — split out of window.zig. Functions keep the
//! owning *Window receiver and are aliased back into Window.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const clipboard = @import("clipboard.zig");
const Pane = @import("pane.zig").Pane;
const winmod = @import("window.zig");
const Window = winmod.Window;
const wm = @import("../grid/word_motion.zig");
const bracket = @import("../grid/bracket.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Selection = @import("../grid/selection.zig").Selection;
const hints = @import("hints.zig");

/// Scrollback search (Ctrl+F): the bottom bar's widgets and the live
/// query against `pane`.
pub const Search = struct {
    bar: ?*c.GtkWidget = null,
    entry: ?*c.GtkWidget = null,
    label: ?*c.GtkWidget = null,
    pane: ?*Pane = null,
    matches: std.ArrayList(Screen.SearchMatch) = .empty,
    idx: usize = 0,
    /// Case-insensitive search toggle. Defaults to smart-case
    /// (lower-only needle implies CI; mixed-case implies CS).
    case_insensitive: bool = false,
    case_button: ?*c.GtkWidget = null,
    /// When set, skip the smart-case heuristic — every search is
    /// case-sensitive by default. Mirrors Config.search_case_sensitive.
    /// Ctrl+I still toggles per-search override.
    force_cs: bool = false,
    /// Regex-mode toggle (Ctrl+R inside the search bar). When on,
    /// the entry text is treated as POSIX Extended Regular Expression.
    regex: bool = false,
};

/// Keyboard-hints (quick-select) mode. `pane` non-null = mode active on
/// that pane; its input Ctx then routes keys to `onHintKey`. `matches`
/// owns the extracted texts.
pub const Hints = struct {
    pane: ?*Pane = null,
    matches: []hints.Match = &.{},
    typed: [2]u8 = .{ 0, 0 },
    typed_len: u8 = 0,
    overlay_buf: std.ArrayList(Screen.HintOverlay) = .empty,
    /// Hint mode keeps going after each pick, collecting matches
    /// instead of activating them; Enter copies the lot. Seeded from
    /// `Config.hint_multiple`, toggled in-mode with Tab.
    multi: bool = false,
    /// Newline-joined text collected in multi-select mode.
    collected: std.ArrayList(u8) = .empty,
};

/// Copy mode (keyboard-driven selection). Raw pane pointer — MUST be
/// cleared on pane close, same rule as `Search.pane`. Cursor uses
/// display-buffer coords (negative row = scrollback), the
/// Screen.SearchMatch / Selection convention.
pub const CopyMode = struct {
    pane: ?*Pane = null,
    row: i32 = 0,
    col: u16 = 0,
    /// Active selection kind + the cell where the anchor was dropped.
    sel: winmod.CopyModeSel = .none,
    anchor_row: i32 = 0,
    anchor_col: u16 = 0,
    /// f/F/t/T have eaten their key and are waiting for the character
    /// to search for. 0 when no motion is pending.
    find_pending: u8 = 0,
    /// The last f/F/t/T, for `;` and `,` to repeat and reverse.
    find_kind: u8 = 0,
    find_char: u32 = 0,
};

// ── Keyboard hints (quick-select) ───────────────────────────

/// Enter hint mode on the focused pane: scan the visible screen
/// for URLs / paths / hashes, overlay labels, route keys to
/// `onHintKey` until a label is completed or Esc.
pub fn openHints(self: *Window) void {
    if (self.hints.pane != null) {
        self.exitHints();
        return;
    }
    // Modes are mutually exclusive — both intercept all keys.
    if (self.copymode.pane != null) self.exitCopyMode();
    const pane = self.focusedPane() orelse return;
    const hints_mod = @import("hints.zig");

    // Translate the config's rules into the scanner's own type. The
    // strings are borrowed for the length of the scan only; matches
    // keep their own copies, so replacing the config arena while hint
    // mode is open cannot dangle them.
    var rules: std.ArrayList(hints_mod.Rule) = .empty;
    defer rules.deinit(self.allocator);
    for (self.config.hint_rules.items) |hr| {
        if (hr.pattern.len == 0) continue;
        rules.append(self.allocator, .{
            .pattern = hr.pattern,
            .action = switch (hr.action) {
                .open => .open,
                .copy => .copy,
                .paste => .paste,
                .select => .select,
                .command => .command,
            },
            .command = hr.command,
        }) catch return;
    }

    const matches = hints_mod.collectVisibleWith(
        self.allocator,
        pane.terminal.screen,
        rules.items,
        self.config.hint_alphabet,
    ) catch return;
    if (matches.len == 0) {
        self.allocator.free(matches);
        return;
    }
    self.hints.matches = matches;
    self.hints.pane = pane;
    self.hints.typed_len = 0;
    self.hints.multi = self.config.hint_multiple;
    self.hints.collected.clearRetainingCapacity();
    if (pane.input_ctx) |ictx| {
        ictx.hint_sink = onHintKey;
        ictx.hint_ctx = @ptrCast(self);
    }
    imBypass(pane, true);
    refreshHintOverlay(self);
}

pub fn exitHints(self: *Window) void {
    const pane = self.hints.pane orelse return;
    self.hints.pane = null;
    if (pane.input_ctx) |ictx| {
        ictx.hint_sink = null;
        ictx.hint_ctx = null;
    }
    imBypass(pane, false);
    pane.terminal.screen.hints_overlay = &.{};
    pane.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(pane.surface.area));
    @import("hints.zig").freeMatches(self.allocator, self.hints.matches);
    self.allocator.free(self.hints.matches);
    self.hints.matches = &.{};
    self.hints.overlay_buf.clearRetainingCapacity();
}

/// Rebuild the overlay slice from matches whose label starts with
/// the typed prefix, then queue a redraw.
pub fn refreshHintOverlay(self: *Window) void {
    const pane = self.hints.pane orelse return;
    self.hints.overlay_buf.clearRetainingCapacity();
    const typed = self.hints.typed[0..self.hints.typed_len];
    for (self.hints.matches) |m| {
        if (!labelHasPrefix(m, typed)) continue;
        self.hints.overlay_buf.append(self.allocator, .{
            .row = m.row,
            .col_start = m.col_start,
            .col_end = m.col_end,
            .label = m.label,
            .label_len = m.label_len,
            .typed = self.hints.typed_len,
        }) catch break;
    }
    pane.terminal.screen.hints_overlay = self.hints.overlay_buf.items;
    pane.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(pane.surface.area));
}

/// A label was completed: open URLs with the default handler;
/// copy paths / hashes to both clipboards.
pub fn activateHint(self: *Window, m: @import("hints.zig").Match) void {
    activateHintAs(self, m, m.action);
}

/// Run one hint match under an explicit action, which is how the
/// modifier overrides reach the same code path as the default.
pub fn activateHintAs(self: *Window, m: @import("hints.zig").Match, action: @import("hints.zig").Action) void {
    const pane = self.hints.pane orelse return;
    if (m.text.len == 0) return;
    switch (action) {
        .open => switch (m.kind) {
            .path => {
                // A path hint whose file exists locally opens in the
                // editor; anything else (remote pane paths, deleted
                // files, no editor configured) copies as before.
                if (openPathInEditor(self, pane, m.text)) return;
                copyHintText(self, pane, m.text);
            },
            else => {
                // Anything else opens as a URI. A custom rule that
                // matched a bare path gets the same editor treatment
                // first, so `open` means the same thing everywhere.
                if (std.mem.indexOf(u8, m.text, "://") == null and openPathInEditor(self, pane, m.text)) return;
                var buf: [4096]u8 = undefined;
                const n = @min(m.text.len, buf.len - 1);
                @memcpy(buf[0..n], m.text[0..n]);
                buf[n] = 0;
                _ = c.g_app_info_launch_default_for_uri(&buf, null, null);
            },
        },
        .copy => copyHintText(self, pane, m.text),
        .paste => pane.terminal.writeUserInput(m.text),
        .select => {
            const screen = pane.terminal.screen;
            const view_off: i32 = @intCast(@min(screen.view_offset, screen.scrollbackCount()));
            const row: i32 = @as(i32, m.row) - view_off;
            screen.selection.start(row, m.col_start, .normal);
            screen.selection.extend(row, m.col_end);
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(pane.surface.area));
        },
        .command => runHintCommand(self, pane, m),
    }
}

fn copyHintText(self: *Window, pane: *Pane, text: []const u8) void {
    const z = self.allocator.allocSentinel(u8, text.len, 0) catch return;
    defer self.allocator.free(z);
    @memcpy(z, text);
    clipboard.copyToClipboard(@ptrCast(pane.surface.area), z);
    clipboard.copyToPrimary(@ptrCast(pane.surface.area), z);
}

/// `action = command`: run the rule's command line with `{match}`
/// replaced by the shell-quoted matched text. Spawned detached
/// through `sh -c` in the pane's cwd, so a command can be a one-liner
/// with pipes; its output goes nowhere, like any launcher.
fn runHintCommand(self: *Window, pane: *Pane, m: @import("hints.zig").Match) void {
    if (m.command.len == 0) return;
    const line_z = hintCommandLine(self.allocator, m.command, m.text) catch return;
    defer self.allocator.free(line_z);

    const pid = c.fork();
    if (pid != 0) {
        // Reap immediately: the intermediate child exits at once and
        // its own child is reparented to init.
        if (pid > 0) _ = c.waitpid(pid, null, 0);
        return;
    }
    // Double-fork so nothing is left for the GUI to reap.
    if (c.fork() != 0) c._exit(0);
    if (pane.terminal.cwd) |dir| {
        var dz: [4096]u8 = undefined;
        if (std.fmt.bufPrintZ(&dz, "{s}", .{dir})) |z| {
            _ = c.chdir(z.ptr);
        } else |_| {}
    }
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", line_z.ptr, null };
    _ = c.execvp("sh", @ptrCast(@constCast(&argv)));
    c._exit(127);
}

/// A rule's command with every `{match}` replaced by the shell-quoted
/// match text, as the C string `sh -c` runs. Caller frees.
pub fn hintCommandLine(gpa: std.mem.Allocator, command: []const u8, text: []const u8) ![:0]u8 {
    const shellquote = @import("../util/shellquote.zig");
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(gpa);
    var i: usize = 0;
    while (i < command.len) {
        if (std.mem.startsWith(u8, command[i..], "{match}")) {
            try shellquote.appendQuoted(&line, gpa, text);
            i += "{match}".len;
        } else {
            try line.append(gpa, command[i]);
            i += 1;
        }
    }
    return line.toOwnedSliceSentinel(gpa, 0);
}

/// Absolute form of a hint's path: `~/` joins `home`, anything
/// relative joins `cwd`; null when the base it needs is unknown or
/// the result does not fit `buf`.
pub fn resolveHintPath(buf: []u8, path: []const u8, home: ?[]const u8, cwd: ?[]const u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '/') return path;
    if (path.len >= 2 and path[0] == '~' and path[1] == '/') {
        const h = home orelse return null;
        return std.fmt.bufPrint(buf, "{s}{s}", .{ h, path[1..] }) catch null;
    }
    const base = cwd orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, path }) catch null;
}

/// The editor a path hint opens in: the configured one, else $EDITOR,
/// else $VISUAL, where an empty value counts as unset.
pub fn hintEditor(configured: []const u8, editor_env: ?[]const u8, visual_env: ?[]const u8) ?[]const u8 {
    if (configured.len > 0) return configured;
    if (editor_env) |e| if (e.len > 0) return e;
    if (visual_env) |v| if (v.len > 0) return v;
    return null;
}

/// Try to open a path-hint's target in the configured editor, in
/// a new tab whose cwd matches the originating pane (compiler
/// output is usually cwd-relative). Returns false when the file
/// doesn't exist locally or no editor is available — the caller
/// falls back to copying.
pub fn openPathInEditor(self: *Window, pane: *Pane, text: []const u8) bool {
    const hints_mod = @import("hints.zig");
    const fl = hints_mod.parseFileLine(text);
    if (fl.path.len == 0) return false;

    // Resolve to an absolute path: ~ -> $HOME, relative -> pane cwd.
    const profile_util = @import("../util/profile.zig");
    var abs_buf: [4096]u8 = undefined;
    const cwd: ?[]const u8 = if (pane.terminal.cwd) |d| d else null;
    const abs = resolveHintPath(&abs_buf, fl.path, profile_util.getenv("HOME"), cwd) orelse return false;
    var z_buf: [4096]u8 = undefined;
    const abs_z = std.fmt.bufPrintZ(&z_buf, "{s}", .{abs}) catch return false;
    if (c.access(abs_z.ptr, c.F_OK) != 0) return false;

    const editor = hintEditor(self.config.hint_editor, profile_util.getenv("EDITOR"), profile_util.getenv("VISUAL")) orelse return false;

    // The file path is shell-quoted by buildEditorCommand — it
    // came off the screen and may contain metacharacters.
    const cmd = hints_mod.buildEditorCommand(self.allocator, editor, abs, fl.line, fl.col) catch return false;
    defer self.allocator.free(cmd);
    var sh_buf: [5200:0]u8 = undefined;
    const sh_cmd = std.fmt.bufPrintZ(&sh_buf, "{s}", .{cmd}) catch return false;
    const argv = [_][*:0]const u8{ "/bin/sh", "-c", sh_cmd.ptr };
    self.addTabInternal("Editor", &argv, cwd) catch return false;
    return true;
}

/// Open the scrollback search bar against the focused pane.
pub fn openSearch(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    self.search.pane = pane;
    if (self.search.bar) |w| c.gtk_widget_set_visible(w, 1);
    if (self.search.entry) |w| {
        c.gtk_editable_set_text(@ptrCast(w), "");
        _ = c.gtk_widget_grab_focus(w);
    }
    self.search.matches.clearRetainingCapacity();
    self.search.idx = 0;
    // Stale highlights from a previous open should not bleed into
    // this fresh session.
    pane.terminal.screen.search_highlights = &.{};
    pane.terminal.screen.search_active_idx = -1;
    if (self.search.label) |l| c.gtk_label_set_text(@ptrCast(l), "");
}

/// Close the search bar and clear any selection used as highlight.
pub fn closeSearch(self: *Window) void {
    if (self.search.bar) |w| c.gtk_widget_set_visible(w, 0);
    if (self.search.pane) |p| {
        p.terminal.screen.selection.clear();
        // Clear borrowed highlight slice BEFORE freeing the
        // backing storage — otherwise renderer reads dangling.
        p.terminal.screen.search_highlights = &.{};
        p.terminal.screen.search_active_idx = -1;
        p.terminal.screen.dirty = true;
        _ = c.gtk_widget_grab_focus(@ptrCast(p.surface.area));
    }
    self.search.pane = null;
    self.search.matches.clearRetainingCapacity();
    self.search.idx = 0;
}

pub fn updateSearch(self: *Window, query: []const u8) void {
    const pane = self.search.pane orelse return;
    self.search.matches.deinit(self.allocator);
    self.search.matches = .empty;
    self.search.idx = 0;
    if (query.len > 0) {
        const ci = searchIgnoresCase(query, self.search.case_insensitive, self.search.force_cs);
        const matches = if (self.search.regex)
            pane.terminal.screen.searchOptsRegex(self.allocator, query, ci) catch return
        else
            pane.terminal.screen.searchOpts(self.allocator, query, ci) catch return;
        defer self.allocator.free(matches);
        self.search.matches.appendSlice(self.allocator, matches) catch return;
    }
    // Publish to the renderer — every match gets a translucent
    // overlay; the active one is brighter.
    pane.terminal.screen.search_highlights = self.search.matches.items;
    refreshSearchLabel(self);
    if (self.search.matches.items.len > 0) {
        // Jump to the last (most-recent) match — usually what users want.
        self.search.idx = self.search.matches.items.len - 1;
        pane.terminal.screen.search_active_idx = @intCast(self.search.idx);
        applyCurrentMatch(self);
    } else {
        pane.terminal.screen.selection.clear();
        pane.terminal.screen.search_active_idx = -1;
        pane.terminal.screen.dirty = true;
        // Pane is unfocused (search bar has focus); explicit
        // render needed to clear the previous highlight overlay.
        c.gtk_gl_area_queue_render(@ptrCast(pane.surface.area));
    }
}

pub fn refreshSearchLabel(self: *Window) void {
    const lab = self.search.label orelse return;
    var buf: [64]u8 = undefined;
    c.gtk_label_set_text(@ptrCast(lab), matchCountLabel(&buf, self.search.idx, self.search.matches.items.len).ptr);
}

/// Smart case: a needle without an ASCII capital searches
/// case-insensitively, unless the per-search Ctrl+I override forces
/// that anyway or `search_case_sensitive` turns the heuristic off.
pub fn searchIgnoresCase(query: []const u8, ci_override: bool, force_cs: bool) bool {
    if (ci_override) return true;
    if (force_cs) return false;
    for (query) |b| {
        if (b >= 'A' and b <= 'Z') return false;
    }
    return true;
}

/// The search bar's "current/total" counter, 1-based.
pub fn matchCountLabel(buf: []u8, idx: usize, len: usize) [:0]const u8 {
    if (len == 0) return "0/0";
    return std.fmt.bufPrintZ(buf, "{d}/{d}", .{ idx + 1, len }) catch "?/?";
}

/// The match after (or before) `idx` among `len`, wrapping at both
/// ends. `len` must be non-zero.
pub fn stepMatch(idx: usize, len: usize, forward: bool) usize {
    if (forward) return (idx + 1) % len;
    return if (idx == 0) len - 1 else idx - 1;
}

/// View offset that shows a match at display `row`: scrollback rows
/// scroll back far enough to be on screen, live rows need none.
pub fn matchViewOffset(row: i32, scrollback: u32) u32 {
    if (row >= 0) return 0;
    const dist: u32 = @intCast(-row);
    return @min(scrollback, dist);
}

pub fn applyCurrentMatch(self: *Window) void {
    const pane = self.search.pane orelse return;
    if (self.search.matches.items.len == 0) return;
    const m = self.search.matches.items[self.search.idx];
    const screen = pane.terminal.screen;
    screen.search_active_idx = @intCast(self.search.idx);
    screen.view_offset = matchViewOffset(m.row, screen.scrollbackCount());
    screen.dirty = true;
    // Search interactions happen with the search bar focused,
    // not the pane — the pane's tick may be paused (no blink /
    // bell / animation). Without an explicit queue_render the
    // view-offset change wouldn't repaint until something else
    // wakes the GLArea.
    c.gtk_gl_area_queue_render(@ptrCast(pane.surface.area));
    refreshSearchLabel(self);
}

pub fn nextMatch(self: *Window) void {
    if (self.search.matches.items.len == 0) return;
    self.search.idx = stepMatch(self.search.idx, self.search.matches.items.len, true);
    applyCurrentMatch(self);
}

pub fn prevMatch(self: *Window) void {
    if (self.search.matches.items.len == 0) return;
    self.search.idx = stepMatch(self.search.idx, self.search.matches.items.len, false);
    applyCurrentMatch(self);
}

/// Route a pane's keys around its input method for the duration of an
/// overlay mode, and back through it afterwards.
///
/// A mode's key sink lives in `key-pressed`, which GTK only emits for
/// keys the IM did not claim first — and an IM claims exactly the
/// plain printable keys the vi-style motions and the hint labels are
/// made of. Without this, every `w`, `y` or hint letter is committed
/// as text and typed into the shell instead of driving the mode. The
/// context itself stays alive, so a half-finished compose sequence is
/// still there when the mode exits.
fn imBypass(pane: *Pane, active: bool) void {
    const ictx = pane.input_ctx orelse return;
    const im = ictx.im orelse return;
    im.setEnabled(!active);
}

/// Keys that only change modifier state, which every overlay mode's
/// key sink lets through unconsumed so chords can still assemble.
pub fn isBareModifier(keyval: c_uint) bool {
    return switch (keyval) {
        c.GDK_KEY_Shift_L,
        c.GDK_KEY_Shift_R,
        c.GDK_KEY_Control_L,
        c.GDK_KEY_Control_R,
        c.GDK_KEY_Alt_L,
        c.GDK_KEY_Alt_R,
        c.GDK_KEY_Super_L,
        c.GDK_KEY_Super_R,
        c.GDK_KEY_Hyper_L,
        c.GDK_KEY_Hyper_R,
        c.GDK_KEY_Meta_L,
        c.GDK_KEY_Meta_R,
        c.GDK_KEY_Caps_Lock,
        c.GDK_KEY_Num_Lock,
        => true,
        else => false,
    };
}

// ── Copy mode (keyboard-driven selection) ─────────────────────

/// Enter copy mode on the focused pane. The copy cursor starts at
/// the terminal cursor; every key press is routed through the
/// pane input ctx's `copymode_sink` until exit (Esc/q/y/Enter).
pub fn openCopyMode(self: *Window) void {
    if (self.copymode.pane != null) self.exitCopyMode();
    // Modes are mutually exclusive — both intercept all keys.
    if (self.hints.pane != null) self.exitHints();
    const pane = self.focusedPane() orelse return;
    const ictx = pane.input_ctx orelse return;
    const screen = pane.terminal.screen;
    self.copymode.pane = pane;
    self.copymode.sel = .none;
    self.copymode.find_pending = 0;
    self.copymode.find_kind = 0;
    self.copymode.row = @intCast(@min(screen.row, screen.rows -| 1));
    self.copymode.col = @min(screen.col, screen.cols -| 1);
    ictx.copymode_sink = onCopyModeKey;
    ictx.copymode_ctx = @ptrCast(self);
    imBypass(pane, true);
    copyModeRefresh(self);
}

/// Leave copy mode: uninstall the key sink, drop the overlay
/// cursor and any in-progress selection, repaint.
pub fn exitCopyMode(self: *Window) void {
    const pane = self.copymode.pane orelse return;
    self.copymode.pane = null;
    self.copymode.sel = .none;
    self.copymode.find_pending = 0;
    if (pane.input_ctx) |ictx| {
        ictx.copymode_sink = null;
        ictx.copymode_ctx = null;
    }
    imBypass(pane, false);
    const screen = pane.terminal.screen;
    screen.copy_cursor = null;
    screen.selection.clear();
    screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(pane.surface.area));
}

/// Copy-mode key dispatch. Returns true when the key is
/// consumed; bare modifier presses return false so chords (e.g.
/// Ctrl+v) can still assemble in GTK's modifier tracking.
pub fn handleCopyModeKey(self: *Window, keyval: c_uint, state: c.GdkModifierType) bool {
    const pane = self.copymode.pane orelse return false;
    const screen = pane.terminal.screen;
    const ctrl = (state & c.GDK_CONTROL_MASK) != 0;
    const row = self.copymode.row;
    const col: i32 = self.copymode.col;
    if (isBareModifier(keyval)) return false;

    // f/F/t/T ate the previous key and this one names the target.
    if (self.copymode.find_pending != 0) {
        const kind = self.copymode.find_pending;
        self.copymode.find_pending = 0;
        if (keyval == c.GDK_KEY_Escape) return true;
        const ch = c.gdk_keyval_to_unicode(keyval);
        if (ch == 0) return true;
        self.copymode.find_kind = kind;
        self.copymode.find_char = ch;
        copyModeFind(self, kind, ch);
        return true;
    }

    switch (keyval) {
        c.GDK_KEY_Escape, c.GDK_KEY_q => self.exitCopyMode(),
        c.GDK_KEY_y, c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => copyModeYank(self),
        c.GDK_KEY_h, c.GDK_KEY_Left => copyModeMoveTo(self, row, col - 1),
        c.GDK_KEY_l, c.GDK_KEY_Right => copyModeMoveTo(self, row, col + 1),
        c.GDK_KEY_k, c.GDK_KEY_Up => copyModeMoveTo(self, row - 1, col),
        c.GDK_KEY_j, c.GDK_KEY_Down => copyModeMoveTo(self, row + 1, col),
        c.GDK_KEY_0, c.GDK_KEY_Home => copyModeMoveTo(self, row, 0),
        c.GDK_KEY_dollar, c.GDK_KEY_End => copyModeMoveTo(self, row, copyModeLineEnd(screen, row)),
        // ^ and _ — first non-blank cell on the line.
        c.GDK_KEY_asciicircum, c.GDK_KEY_underscore => copyModeMoveTo(self, row, copyModeLineStart(screen, row)),
        // g / G — scrollback top / live bottom (cursor keeps its
        // column, mirroring scrollback_top/bottom actions).
        c.GDK_KEY_g => copyModeMoveTo(self, extentOf(screen).top, col),
        c.GDK_KEY_G => copyModeMoveTo(self, extentOf(screen).bottom, col),
        // H / M / L — high, middle and low row of what is on screen,
        // which is not the same as the buffer once scrolled back.
        c.GDK_KEY_H => copyModeMoveTo(self, viewTopOf(screen), col),
        c.GDK_KEY_M => copyModeMoveTo(self, viewTopOf(screen) + @divTrunc(@as(i32, @intCast(screen.rows)) - 1, 2), col),
        c.GDK_KEY_L => copyModeMoveTo(self, viewTopOf(screen) + @as(i32, @intCast(screen.rows)) - 1, col),
        // Page and half-page scrolling.
        c.GDK_KEY_Page_Down => copyModeMoveTo(self, row + @as(i32, @intCast(screen.rows)), col),
        c.GDK_KEY_Page_Up => copyModeMoveTo(self, row - @as(i32, @intCast(screen.rows)), col),
        c.GDK_KEY_f => {
            if (ctrl) {
                copyModeMoveTo(self, row + @as(i32, @intCast(screen.rows)), col);
            } else {
                self.copymode.find_pending = 'f';
            }
        },
        c.GDK_KEY_b => {
            if (ctrl) {
                copyModeMoveTo(self, row - @as(i32, @intCast(screen.rows)), col);
            } else {
                copyModeWord(self, .prev, .word);
            }
        },
        c.GDK_KEY_d => {
            if (ctrl) copyModeMoveTo(self, row + @divTrunc(@as(i32, @intCast(screen.rows)), 2), col);
        },
        c.GDK_KEY_u => {
            if (ctrl) copyModeMoveTo(self, row - @divTrunc(@as(i32, @intCast(screen.rows)), 2), col);
        },
        // Word motions. Lower case respects the word_chars set; upper
        // case is vim's WORD, delimited by blanks alone.
        c.GDK_KEY_w => copyModeWord(self, .next, .word),
        c.GDK_KEY_W => copyModeWord(self, .next, .big),
        c.GDK_KEY_B => copyModeWord(self, .prev, .big),
        c.GDK_KEY_e => copyModeWord(self, .next_end, .word),
        c.GDK_KEY_E => copyModeWord(self, .next_end, .big),
        // { / } — paragraph motion, i.e. the next blank line.
        c.GDK_KEY_braceright => copyModeParagraph(self, 1),
        c.GDK_KEY_braceleft => copyModeParagraph(self, -1),
        // % — the bracket matching the one under the cursor.
        c.GDK_KEY_percent => copyModeMatchBracket(self),
        // F / T and their repeats.
        c.GDK_KEY_F => self.copymode.find_pending = 'F',
        c.GDK_KEY_t => self.copymode.find_pending = 't',
        c.GDK_KEY_T => self.copymode.find_pending = 'T',
        c.GDK_KEY_semicolon => {
            if (self.copymode.find_kind != 0) copyModeFind(self, self.copymode.find_kind, self.copymode.find_char);
        },
        c.GDK_KEY_comma => {
            if (self.copymode.find_kind != 0) copyModeFind(self, findReverse(self.copymode.find_kind), self.copymode.find_char);
        },
        // n / N — walk the search bar's matches without leaving copy
        // mode, so a search can be refined into a selection.
        c.GDK_KEY_n => copyModeSearchStep(self, 1),
        c.GDK_KEY_N => copyModeSearchStep(self, -1),
        // v = cell-wise anchor toggle; Ctrl+v (or r) = rectangular;
        // V = line-wise.
        c.GDK_KEY_v => copyModeToggleSel(self, if (ctrl) .rect else .cell),
        c.GDK_KEY_V => copyModeToggleSel(self, .line),
        c.GDK_KEY_r => copyModeToggleSel(self, .rect),
        // Everything else is swallowed while copy mode is active.
        else => {},
    }
    return true;
}

/// Display row of the topmost line currently on screen.
pub fn viewTopOf(screen: *const Screen) i32 {
    return -@as(i32, @intCast(@min(screen.view_offset, screen.scrollbackCount())));
}

/// The display rows and columns copy mode can visit.
pub const Extent = struct {
    /// Oldest row: the top of scrollback, or 0 on the alternate
    /// screen, which keeps none.
    top: i32,
    bottom: i32,
    last_col: i32,
};

pub fn extentOf(screen: *const Screen) Extent {
    const sb: i32 = if (screen.use_alt) 0 else @intCast(screen.scrollbackCount());
    return .{
        .top = -sb,
        .bottom = @as(i32, @intCast(screen.rows)) - 1,
        .last_col = @as(i32, @intCast(screen.cols)) - 1,
    };
}

fn findReverse(kind: u8) u8 {
    return switch (kind) {
        'f' => 'F',
        'F' => 'f',
        't' => 'T',
        'T' => 't',
        else => kind,
    };
}

/// f/F/t/T — jump to `ch` on the cursor's own line. Line-local, like
/// vim: running off the end is a no-op rather than a wrap.
pub fn copyModeFind(self: *Window, kind: u8, ch: u32) void {
    const pane = self.copymode.pane orelse return;
    const hit = findTarget(pane.terminal.screen, self.copymode.row, self.copymode.col, kind, ch) orelse return;
    copyModeMoveTo(self, self.copymode.row, hit);
}

/// Column an f/F/t/T motion for `ch` lands on, or null when `ch` is
/// not on that side of `col` in `row`.
pub fn findTarget(screen: *const Screen, row: i32, col: u16, kind: u8, ch: u32) ?u16 {
    const cells = screen.lineCellsAtPub(row) orelse return null;
    const hit = switch (kind) {
        'f' => wm.findForward(cells, col, ch, false),
        't' => wm.findForward(cells, col, ch, true),
        'F' => wm.findBackward(cells, col, ch, false),
        'T' => wm.findBackward(cells, col, ch, true),
        else => null,
    } orelse return null;
    return @intCast(hit);
}

/// { / } — the next blank line in `dir`, or the buffer edge.
pub fn copyModeParagraph(self: *Window, dir: i32) void {
    const pane = self.copymode.pane orelse return;
    copyModeMoveTo(self, paragraphTarget(pane.terminal.screen, self.copymode.row, dir), 0);
}

/// Row a { / } motion from `from` lands on: the first blank row in
/// `dir`, or the last row before the buffer edge.
pub fn paragraphTarget(screen: *const Screen, from: i32, dir: i32) i32 {
    const ext = extentOf(screen);
    var r = from;
    var last = r;
    while (true) {
        r += dir;
        if (r < ext.top or r > ext.bottom) break;
        last = r;
        if (copyModeRowBlank(screen, r)) break;
    }
    return last;
}

fn copyModeRowBlank(screen: *const Screen, row: i32) bool {
    const cells = screen.lineCellsAtPub(row) orelse return true;
    for (cells) |cell| {
        if (cell.rune != 0 and cell.rune != ' ') return false;
    }
    return true;
}

/// The bracket pairing with the one under the cursor. The row budget
/// is a screenful in each direction, so a stray bracket in a long
/// scrollback cannot turn one keystroke into a full-buffer scan on
/// the main loop.
pub fn copyModeMatchBracket(self: *Window) void {
    const pane = self.copymode.pane orelse return;
    const screen = pane.terminal.screen;
    const hit = bracket.matchAt(screen, self.copymode.row, self.copymode.col, @intCast(screen.rows)) orelse return;
    copyModeMoveTo(self, hit.row, hit.col);
}

/// n / N — move the copy cursor onto the next search match. Needs the
/// search bar to have been used; without matches it does nothing.
pub fn copyModeSearchStep(self: *Window, dir: i32) void {
    const pane = self.copymode.pane orelse return;
    if (self.search.pane != pane) return;
    const matches = self.search.matches.items;
    if (matches.len == 0) return;
    const i = nearestMatch(matches, self.copymode.row, self.copymode.col, dir > 0);
    self.search.idx = i;
    copyModeMoveTo(self, matches[i].row, @intCast(matches[i].col));
}

/// Index of the match strictly after (or before) the cursor in
/// reading order, wrapping at the ends. `matches` must be non-empty
/// and ordered oldest row first, as `Screen.searchOpts` returns them.
pub fn nearestMatch(matches: []const Screen.SearchMatch, row: i32, col: u16, forward: bool) usize {
    const cc: i64 = col;
    if (forward) {
        for (matches, 0..) |m, i| {
            if (m.row > row or (m.row == row and @as(i64, m.col) > cc)) return i;
        }
        return 0;
    }
    var i = matches.len;
    while (i > 0) {
        i -= 1;
        const m = matches[i];
        if (m.row < row or (m.row == row and @as(i64, m.col) < cc)) return i;
    }
    return matches.len - 1;
}

/// Toggle the selection anchor. Re-pressing the active kind drops
/// the anchor; switching kinds keeps the existing anchor cell.
pub fn copyModeToggleSel(self: *Window, kind: winmod.CopyModeSel) void {
    const next = toggledSel(.{
        .kind = self.copymode.sel,
        .anchor_row = self.copymode.anchor_row,
        .anchor_col = self.copymode.anchor_col,
    }, kind, self.copymode.row, self.copymode.col);
    self.copymode.sel = next.kind;
    self.copymode.anchor_row = next.anchor_row;
    self.copymode.anchor_col = next.anchor_col;
    copyModeRefresh(self);
}

/// Copy mode's selection kind plus the cell its anchor was dropped on.
pub const SelState = struct {
    kind: winmod.CopyModeSel,
    anchor_row: i32,
    anchor_col: u16,
};

/// State after pressing the key for `kind` with the cursor at
/// (`row`, `col`): the anchor is dropped only when leaving `.none`.
pub fn toggledSel(state: SelState, kind: winmod.CopyModeSel, row: i32, col: u16) SelState {
    if (state.kind == kind) return .{ .kind = .none, .anchor_row = state.anchor_row, .anchor_col = state.anchor_col };
    if (state.kind == .none) return .{ .kind = kind, .anchor_row = row, .anchor_col = col };
    return .{ .kind = kind, .anchor_row = state.anchor_row, .anchor_col = state.anchor_col };
}

/// Move the copy cursor, clamping into the buffer (scrollback top
/// .. live bottom) and scrolling the view so it stays visible.
pub fn copyModeMoveTo(self: *Window, row: i32, col: i32) void {
    const pane = self.copymode.pane orelse return;
    const screen = pane.terminal.screen;
    const to = clampMove(screen, row, col);
    self.copymode.row = to.row;
    self.copymode.col = to.col;
    if (to.view_offset) |vo| screen.view_offset = vo;
    copyModeRefresh(self);
}

pub const Move = struct {
    row: i32,
    col: u16,
    /// The view offset that keeps the cursor on screen, or null when
    /// it already is.
    view_offset: ?u32,
};

/// Where a copy-mode move to (`row`, `col`) lands once clamped into
/// the buffer; moving past the top scrolls back and past the bottom
/// scrolls forward, the same clamping as scrollback_page_*.
pub fn clampMove(screen: *const Screen, row: i32, col: i32) Move {
    const ext = extentOf(screen);
    const r = std.math.clamp(row, ext.top, ext.bottom);
    const cc: u16 = @intCast(std.math.clamp(col, 0, ext.last_col));
    // The cursor's visible row is row + view_offset.
    const view_off: i32 = @intCast(@min(screen.view_offset, screen.scrollbackCount()));
    const vo: ?u32 = if (r + view_off < 0)
        @intCast(-r)
    else if (r + view_off > ext.bottom)
        @intCast(ext.bottom - r)
    else
        null;
    return .{ .row = r, .col = cc, .view_offset = vo };
}

pub const WordDir = enum { next, prev, next_end, prev_end };

/// w / b / e — jump to the next or previous word boundary, wrapping to
/// adjacent lines when the current one runs out of words. `kind`
/// picks the alphabet: the word_chars set, or vim's blank-delimited
/// WORD for the upper-case motions.
pub fn copyModeWord(self: *Window, dir: WordDir, kind: wm.Kind) void {
    const pane = self.copymode.pane orelse return;
    const to = wordTarget(pane.terminal.screen, self.copymode.row, self.copymode.col, dir, kind) orelse return;
    copyModeMoveTo(self, to.row, to.col);
}

/// Cell a word motion from (`row`, `col`) lands on, or null at the
/// buffer edge, where the cursor stays put.
pub fn wordTarget(screen: *const Screen, row: i32, col: u16, dir: WordDir, kind: wm.Kind) ?Screen.CopyCursor {
    const chars = screen.word_chars;
    if (screen.lineCellsAtPub(row)) |cells| {
        const hit = switch (dir) {
            .next => wm.nextStart(cells, chars, col, kind),
            .prev => wm.prevStart(cells, chars, col, kind),
            .next_end => wm.nextEnd(cells, chars, col, kind),
            .prev_end => wm.prevEnd(cells, chars, col, kind),
        };
        if (hit) |c2| return .{ .row = row, .col = @intCast(c2) };
    }
    const forward = dir == .next or dir == .next_end;
    const ext = extentOf(screen);
    var r = row;
    while (true) {
        r = if (forward) r + 1 else r - 1;
        if (r < ext.top or r > ext.bottom) return null;
        const cells = screen.lineCellsAtPub(r) orelse continue;
        const hit = switch (dir) {
            .next => wm.firstStart(cells, chars, kind),
            .prev => wm.lastStart(cells, chars, kind),
            .next_end => wm.firstEnd(cells, chars, kind),
            .prev_end => wm.lastEnd(cells, chars, kind),
        };
        if (hit) |c2| return .{ .row = r, .col = @intCast(c2) };
    }
}

/// y / Enter — copy the active selection to CLIPBOARD + PRIMARY
/// and leave copy mode. No selection → just exits.
pub fn copyModeYank(self: *Window) void {
    const pane = self.copymode.pane orelse return;
    const screen = pane.terminal.screen;
    if (screen.selection.isActive()) blk: {
        const text = screen.extractSelection(self.allocator) catch break :blk;
        defer self.allocator.free(text);
        if (text.len == 0) break :blk;
        const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch break :blk;
        defer self.allocator.free(cstr);
        @memcpy(cstr, text);
        clipboard.copyToClipboard(@ptrCast(pane.surface.area), cstr);
        clipboard.copyToPrimary(@ptrCast(pane.surface.area), cstr);
    }
    self.exitCopyMode();
}

/// Re-derive `screen.selection` from anchor + cursor, publish the
/// overlay cursor, repaint. Called after every copy-mode change.
pub fn copyModeRefresh(self: *Window) void {
    const pane = self.copymode.pane orelse return;
    const screen = pane.terminal.screen;
    const row = self.copymode.row;
    const col = self.copymode.col;
    applyCopySelection(&screen.selection, .{
        .kind = self.copymode.sel,
        .anchor_row = self.copymode.anchor_row,
        .anchor_col = self.copymode.anchor_col,
    }, row, col, screen.cols);
    screen.copy_cursor = .{ .row = row, .col = col };
    screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(pane.surface.area));
}

/// Re-derive `sel` from copy mode's anchor and cursor; a cell-wise
/// selection includes both end cells although Selection's bottom
/// column is exclusive.
pub fn applyCopySelection(sel: *Selection, state: SelState, row: i32, col: u16, cols: u16) void {
    const a_row = state.anchor_row;
    const a_col = state.anchor_col;
    switch (state.kind) {
        .none => sel.clear(),
        .cell => {
            // Bump whichever endpoint is later.
            if (row > a_row or (row == a_row and col >= a_col)) {
                sel.start(a_row, a_col, .normal);
                sel.extend(row, @as(i32, col) + 1);
            } else {
                sel.start(a_row, @as(i32, a_col) + 1, .normal);
                sel.extend(row, col);
            }
        },
        .line => {
            // Whole lines, anchor row through cursor row.
            sel.start(@min(a_row, row), 0, .normal);
            sel.extend(@max(a_row, row), cols);
        },
        .rect => {
            const lo: i32 = @min(a_col, col);
            const hi: i32 = @as(i32, @max(a_col, col)) + 1;
            sel.start(a_row, lo, .rectangular);
            sel.extend(row, hi);
        },
    }
}

/// input.Ctx copy-mode sink — forwards into the Window method.
pub fn onCopyModeKey(ctx: ?*anyopaque, keyval: c_uint, state: c.GdkModifierType) bool {
    const self = cast.userData(Window, ctx);
    return handleCopyModeKey(self, keyval, state);
}

/// Column of the last non-blank cell on a display row ($ motion).
/// Blank line → column 0.
pub fn copyModeLineEnd(screen: *const Screen, row: i32) i32 {
    const cells = screen.lineCellsAtPub(row) orelse return 0;
    var i: usize = cells.len;
    while (i > 0 and cells[i - 1].rune == 0) i -= 1;
    if (i == 0) return 0;
    return @intCast(i - 1);
}

/// Column of the first non-blank cell on a display row (^ motion).
pub fn copyModeLineStart(screen: *const Screen, row: i32) i32 {
    const cells = screen.lineCellsAtPub(row) orelse return 0;
    for (cells, 0..) |cell, i| {
        if (cell.rune != 0 and cell.rune != ' ') return @intCast(i);
    }
    return 0;
}


pub fn onSearchChanged(entry: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    const text_ptr = c.gtk_editable_get_text(@ptrCast(entry));
    if (text_ptr == null) return;
    const cstr: [*:0]const u8 = @ptrCast(text_ptr);
    const len = std.mem.len(cstr);
    updateSearch(self, cstr[0..len]);
}

pub fn onSearchActivate(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    nextMatch(self);
}

pub fn onSearchStop(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    self.closeSearch();
}

pub fn onSearchClose(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    self.closeSearch();
}

pub fn onSearchNext(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    nextMatch(self);
}

pub fn onSearchPrev(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    prevMatch(self);
}

pub fn onSearchKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);
    const shift = (state & c.GDK_SHIFT_MASK) != 0;
    if (keyval == c.GDK_KEY_Return or keyval == c.GDK_KEY_KP_Enter) {
        if (shift) prevMatch(self) else nextMatch(self);
        return 1;
    }
    if (keyval == c.GDK_KEY_Escape) {
        self.closeSearch();
        return 1;
    }
    // Ctrl+I — toggle case-insensitive override and re-search the
    // current needle. Without the override, smart-case applies
    // (lower-only needle → CI, uppercase → CS).
    if ((keyval == c.GDK_KEY_i or keyval == c.GDK_KEY_I) and
        (state & c.GDK_CONTROL_MASK) != 0)
    {
        self.search.case_insensitive = !self.search.case_insensitive;
        if (self.search.entry) |w| {
            const txt = c.gtk_editable_get_text(@ptrCast(w));
            if (txt != null) {
                const slice = std.mem.span(txt);
                updateSearch(self, slice);
            }
        }
        return 1;
    }
    // Ctrl+R — toggle regex mode. The entry text is then treated
    // as a POSIX ERE pattern. Placeholder text flips to signal the
    // mode change.
    if ((keyval == c.GDK_KEY_r or keyval == c.GDK_KEY_R) and
        (state & c.GDK_CONTROL_MASK) != 0)
    {
        self.search.regex = !self.search.regex;
        if (self.search.entry) |w| {
            const placeholder: [*:0]const u8 = if (self.search.regex)
                "Search regex (Ctrl+R)"
            else
                "Search (Ctrl+R for regex)";
            c.gtk_entry_set_placeholder_text(@ptrCast(w), placeholder);
            const txt = c.gtk_editable_get_text(@ptrCast(w));
            if (txt != null) {
                const slice = std.mem.span(txt);
                updateSearch(self, slice);
            }
        }
        return 1;
    }
    return 0;
}

/// Hint-mode key interceptor, installed on the focused pane's input
/// Ctx while hint mode is active. Returns true when the key was
/// consumed; bare modifiers fall through so autohide/IM bookkeeping
/// stays sane.
pub fn onHintKey(ctx: ?*anyopaque, keyval: c_uint, state: c.GdkModifierType) bool {
    const self = cast.userData(Window, ctx);
    if (self.hints.pane == null) return false;
    const hints_mod = @import("hints.zig");
    const shift = (state & c.GDK_SHIFT_MASK) != 0;
    const alt = (state & c.GDK_ALT_MASK) != 0;
    switch (keyval) {
        c.GDK_KEY_Escape => {
            self.exitHints();
            return true;
        },
        // Tab toggles multi-select; Enter finishes it.
        c.GDK_KEY_Tab, c.GDK_KEY_ISO_Left_Tab => {
            self.hints.multi = !self.hints.multi;
            return true;
        },
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
            finishHintCollection(self);
            self.exitHints();
            return true;
        },
        c.GDK_KEY_BackSpace => {
            if (self.hints.typed_len > 0) {
                self.hints.typed_len -= 1;
                refreshHintOverlay(self);
            }
            return true;
        },
        else => if (isBareModifier(keyval)) return false,
    }
    const alphabet = hints_mod.validAlphabet(self.config.hint_alphabet) orelse hints_mod.ALPHABET;
    const ch = labelChar(c.gdk_keyval_to_unicode(keyval), alphabet) orelse return true;
    if (self.hints.typed_len >= self.hints.typed.len) return true;
    const candidate_len = self.hints.typed_len + 1;
    self.hints.typed[self.hints.typed_len] = ch;
    switch (pickHint(self.hints.matches, self.hints.typed[0..candidate_len])) {
        // A stray key: the typed prefix stays what it was.
        .none => return true,
        .partial => {
            self.hints.typed_len = candidate_len;
            refreshHintOverlay(self);
            return true;
        },
        .full => |m| {
            if (self.hints.multi) {
                collectHint(self, m);
                self.hints.typed_len = 0;
                refreshHintOverlay(self);
                return true;
            }
            activateHintAs(self, m, hintAction(m.action, shift, alt));
            self.exitHints();
            return true;
        },
    }
}

/// Whether `m`'s label starts with what has been typed so far.
fn labelHasPrefix(m: hints.Match, typed: []const u8) bool {
    return std.mem.startsWith(u8, m.label[0..m.label_len], typed);
}

/// The label character a key with codepoint `u` types, folded to
/// lower case so a Shift-held pick (which asks for "copy instead")
/// still finds its label; null for anything outside `alphabet`.
pub fn labelChar(u: u32, alphabet: []const u8) ?u8 {
    const folded = if (u >= 'A' and u <= 'Z') u + 0x20 else u;
    if (folded == 0 or folded >= 128) return null;
    const b: u8 = @intCast(folded);
    if (std.mem.indexOfScalar(u8, alphabet, b) == null) return null;
    return b;
}

pub const HintPick = union(enum) {
    /// No label starts with the typed prefix.
    none,
    /// Some labels start with it; keep typing.
    partial,
    /// A label equals it.
    full: hints.Match,
};

pub fn pickHint(matches: []const hints.Match, typed: []const u8) HintPick {
    var any = false;
    var full: ?hints.Match = null;
    for (matches) |m| {
        if (!labelHasPrefix(m, typed)) continue;
        any = true;
        if (m.label_len == typed.len) full = m;
    }
    if (full) |m| return .{ .full = m };
    return if (any) .partial else .none;
}

/// The action a completed label runs: Shift picks copy and Alt picks
/// paste whatever the rule's own action is, so both are reachable for
/// every match, the built-in kinds included.
pub fn hintAction(rule: hints.Action, shift: bool, alt: bool) hints.Action {
    if (shift) return .copy;
    if (alt) return .paste;
    return rule;
}

/// Multi-select: append a picked match to the collection instead of
/// acting on it.
fn collectHint(self: *Window, m: @import("hints.zig").Match) void {
    appendCollected(&self.hints.collected, self.allocator, m.text) catch return;
}

/// Add one pick to the multi-select collection, newline-separated.
pub fn appendCollected(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    if (out.items.len > 0) try out.append(gpa, '\n');
    try out.appendSlice(gpa, text);
}

/// Enter in multi-select mode: copy everything collected, as one
/// newline-separated block. Nothing collected = nothing copied.
fn finishHintCollection(self: *Window) void {
    const pane = self.hints.pane orelse return;
    if (self.hints.collected.items.len == 0) return;
    copyHintText(self, pane, self.hints.collected.items);
}

// -- tests --------------------------------------------------------------

const t = std.testing;

test "bare modifiers pass through every overlay mode, printable keys do not" {
    // Hyper and Meta were missing from hint mode's own copy of this list,
    // so a bare press was swallowed there but let through in copy mode.
    for ([_]c_uint{
        c.GDK_KEY_Shift_L,   c.GDK_KEY_Control_R, c.GDK_KEY_Alt_L,  c.GDK_KEY_Super_R,
        c.GDK_KEY_Hyper_L,   c.GDK_KEY_Hyper_R,   c.GDK_KEY_Meta_L, c.GDK_KEY_Meta_R,
        c.GDK_KEY_Caps_Lock, c.GDK_KEY_Num_Lock,
    }) |k| try t.expect(isBareModifier(k));
    for ([_]c_uint{ c.GDK_KEY_a, c.GDK_KEY_y, c.GDK_KEY_Escape, c.GDK_KEY_Return, c.GDK_KEY_Tab }) |k|
        try t.expect(!isBareModifier(k));
}

const Pool = @import("../grid/style_pool.zig").Pool;

/// A real Screen with `lines` printed from the top; lines past the
/// last row scroll the oldest ones into scrollback, exactly as output
/// does. Initialised in place: the Screen keeps a pointer to `pool`.
const TestScreen = struct {
    pool: Pool,
    screen: *Screen,

    fn init(self: *TestScreen, cols: u16, rows: u16, lines: []const []const u8) !void {
        self.pool = try Pool.init(t.allocator);
        errdefer self.pool.deinit();
        self.screen = try Screen.init(t.allocator, &self.pool, cols, rows);
        for (lines, 0..) |line, i| {
            if (i > 0) {
                self.screen.apply(.{ .execute = '\r' });
                self.screen.apply(.{ .execute = '\n' });
            }
            for (line) |ch| self.screen.printCp(ch);
        }
    }

    fn deinit(self: *TestScreen) void {
        self.screen.deinit();
        self.pool.deinit();
    }
};

test "smart case searches case-insensitively until the needle has a capital" {
    try t.expect(searchIgnoresCase("foo", false, false));
    try t.expect(!searchIgnoresCase("Foo", false, false));
    try t.expect(!searchIgnoresCase("fOO bar", false, false));
    // Ctrl+I forces insensitive whatever the needle; the config switch
    // forces sensitive, but the per-search toggle still wins over it.
    try t.expect(searchIgnoresCase("Foo", true, false));
    try t.expect(!searchIgnoresCase("foo", false, true));
    try t.expect(searchIgnoresCase("Foo", true, true));
    // Only ASCII capitals count: a non-ASCII capital does not flip it.
    try t.expect(searchIgnoresCase("\u{c9}t\u{e9}", false, false));
}

test "next and previous match wrap around both ends" {
    try t.expectEqual(@as(usize, 1), stepMatch(0, 3, true));
    try t.expectEqual(@as(usize, 0), stepMatch(2, 3, true));
    try t.expectEqual(@as(usize, 2), stepMatch(0, 3, false));
    try t.expectEqual(@as(usize, 1), stepMatch(2, 3, false));
    // A single match is its own neighbour in both directions.
    try t.expectEqual(@as(usize, 0), stepMatch(0, 1, true));
    try t.expectEqual(@as(usize, 0), stepMatch(0, 1, false));
}

test "the match counter is 1-based and reads 0/0 without matches" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("0/0", matchCountLabel(&buf, 0, 0));
    try t.expectEqualStrings("1/4", matchCountLabel(&buf, 0, 4));
    try t.expectEqualStrings("4/4", matchCountLabel(&buf, 3, 4));
}

test "a scrollback match scrolls just far enough, a live one resets the view" {
    try t.expectEqual(@as(u32, 0), matchViewOffset(3, 10));
    try t.expectEqual(@as(u32, 0), matchViewOffset(0, 10));
    try t.expectEqual(@as(u32, 4), matchViewOffset(-4, 10));
    // Never past the oldest line.
    try t.expectEqual(@as(u32, 10), matchViewOffset(-40, 10));
}

test "copy-mode n/N step to the nearest match strictly past the cursor, wrapping" {
    const M = Screen.SearchMatch;
    const ms = [_]M{
        .{ .row = -3, .col = 5, .len = 1 },
        .{ .row = 0, .col = 2, .len = 1 },
        .{ .row = 0, .col = 9, .len = 1 },
        .{ .row = 2, .col = 0, .len = 1 },
    };
    // Sitting ON a match moves off it, in both directions.
    try t.expectEqual(@as(usize, 2), nearestMatch(&ms, 0, 2, true));
    try t.expectEqual(@as(usize, 0), nearestMatch(&ms, 0, 2, false));
    // Between matches, including across rows and into scrollback.
    try t.expectEqual(@as(usize, 3), nearestMatch(&ms, 1, 40, true));
    try t.expectEqual(@as(usize, 2), nearestMatch(&ms, 1, 0, false));
    try t.expectEqual(@as(usize, 1), nearestMatch(&ms, -3, 6, true));
    // Past the last / before the first wraps to the other end.
    try t.expectEqual(@as(usize, 0), nearestMatch(&ms, 2, 0, true));
    try t.expectEqual(@as(usize, 3), nearestMatch(&ms, -3, 5, false));
}

test "a hint key folds to lower case and must be in the label alphabet" {
    try t.expectEqual(@as(?u8, 'a'), labelChar('a', hints.ALPHABET));
    try t.expectEqual(@as(?u8, 'a'), labelChar('A', hints.ALPHABET));
    try t.expectEqual(@as(?u8, null), labelChar('1', hints.ALPHABET));
    try t.expectEqual(@as(?u8, null), labelChar(0, hints.ALPHABET));
    try t.expectEqual(@as(?u8, null), labelChar(0xE9, hints.ALPHABET));
    // A configured alphabet replaces the built-in one entirely.
    try t.expectEqual(@as(?u8, '1'), labelChar('1', "123"));
    try t.expectEqual(@as(?u8, null), labelChar('a', "123"));
}

fn hintMatch(label: []const u8, text: []u8) hints.Match {
    var m = hints.Match{ .row = 0, .col_start = 0, .col_end = 1, .kind = .url, .text = text };
    @memcpy(m.label[0..label.len], label);
    m.label_len = @intCast(label.len);
    return m;
}

test "typing a label prefix narrows, a full label picks, a stray key is ignored" {
    var a_text = "alpha".*;
    var b_text = "bravo".*;
    var c_text = "charlie".*;
    const two = [_]hints.Match{
        hintMatch("aa", &a_text),
        hintMatch("as", &b_text),
        hintMatch("sa", &c_text),
    };
    try t.expect(pickHint(&two, "a") == .partial);
    try t.expect(pickHint(&two, "") == .partial);
    try t.expect(pickHint(&two, "d") == .none);
    try t.expect(pickHint(&two, "ad") == .none);
    const picked = pickHint(&two, "as");
    try t.expectEqualStrings("bravo", picked.full.text);

    // A batch of single-character labels completes on the first key.
    const one = [_]hints.Match{ hintMatch("a", &a_text), hintMatch("s", &b_text) };
    try t.expectEqualStrings("bravo", pickHint(&one, "s").full.text);
}

test "Shift copies and Alt pastes whatever the rule's own action is" {
    try t.expectEqual(hints.Action.open, hintAction(.open, false, false));
    try t.expectEqual(hints.Action.command, hintAction(.command, false, false));
    try t.expectEqual(hints.Action.copy, hintAction(.open, true, false));
    try t.expectEqual(hints.Action.paste, hintAction(.select, false, true));
    try t.expectEqual(hints.Action.copy, hintAction(.paste, true, true));
}

test "multi-select collects picks newline-separated, without a leading newline" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try appendCollected(&out, t.allocator, "one");
    try t.expectEqualStrings("one", out.items);
    try appendCollected(&out, t.allocator, "two");
    try appendCollected(&out, t.allocator, "three");
    try t.expectEqualStrings("one\ntwo\nthree", out.items);
}

test "a command rule gets every {match} replaced by the shell-quoted text" {
    const line = try hintCommandLine(t.allocator, "notify-send {match} && echo {match}", "it's a b");
    defer t.allocator.free(line);
    try t.expectEqualStrings("notify-send 'it'\\''s a b' && echo 'it'\\''s a b'", line);

    // Safe text goes bare; near-misses of the placeholder stay literal.
    const bare = try hintCommandLine(t.allocator, "open {match} {mat} {MATCH}", "/tmp/x.txt");
    defer t.allocator.free(bare);
    try t.expectEqualStrings("open /tmp/x.txt {mat} {MATCH}", bare);

    // Empty text still yields an argument rather than vanishing.
    const empty = try hintCommandLine(t.allocator, "echo {match}", "");
    defer t.allocator.free(empty);
    try t.expectEqualStrings("echo ''", empty);
}

test "a path hint resolves against HOME or the pane cwd, or not at all" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("/etc/hosts", resolveHintPath(&buf, "/etc/hosts", null, null).?);
    try t.expectEqualStrings("/home/u/src/a.zig", resolveHintPath(&buf, "~/src/a.zig", "/home/u", null).?);
    try t.expectEqualStrings("/work/src/a.zig", resolveHintPath(&buf, "src/a.zig", null, "/work").?);
    // A tilde path needs HOME and a relative one needs a cwd.
    try t.expect(resolveHintPath(&buf, "~/a", null, "/work") == null);
    try t.expect(resolveHintPath(&buf, "a", "/home/u", null) == null);
    // Only "~/" means home: "~user" is an ordinary relative name.
    try t.expectEqualStrings("/work/~user/a", resolveHintPath(&buf, "~user/a", "/home/u", "/work").?);
    try t.expect(resolveHintPath(&buf, "", "/home/u", "/work") == null);
    // Too long for the buffer is a refusal, not a truncated path.
    var tiny: [8]u8 = undefined;
    try t.expect(resolveHintPath(&tiny, "src/a.zig", null, "/work") == null);
}

test "the hint editor is the configured one, then EDITOR, then VISUAL" {
    try t.expectEqualStrings("hx", hintEditor("hx", "vim", "code").?);
    try t.expectEqualStrings("vim", hintEditor("", "vim", "code").?);
    try t.expectEqualStrings("code", hintEditor("", "", "code").?);
    try t.expectEqualStrings("code", hintEditor("", null, "code").?);
    try t.expect(hintEditor("", "", "") == null);
    try t.expect(hintEditor("", null, null) == null);
}

test "comma reverses the direction of the last f/F/t/T" {
    try t.expectEqual(@as(u8, 'F'), findReverse('f'));
    try t.expectEqual(@as(u8, 'f'), findReverse('F'));
    try t.expectEqual(@as(u8, 'T'), findReverse('t'));
    try t.expectEqual(@as(u8, 't'), findReverse('T'));
}

test "v/V/r toggle the selection kind and drop the anchor only from none" {
    const none = SelState{ .kind = .none, .anchor_row = 0, .anchor_col = 0 };
    const cell = toggledSel(none, .cell, -2, 7);
    try t.expectEqual(SelState{ .kind = .cell, .anchor_row = -2, .anchor_col = 7 }, cell);
    // Switching kind keeps the anchor where it was dropped.
    const line = toggledSel(cell, .line, 4, 1);
    try t.expectEqual(SelState{ .kind = .line, .anchor_row = -2, .anchor_col = 7 }, line);
    // Re-pressing the active kind clears the selection.
    try t.expectEqual(winmod.CopyModeSel.none, toggledSel(line, .line, 4, 1).kind);
    // A fresh selection after that anchors at the new cursor.
    const rect = toggledSel(toggledSel(line, .line, 4, 1), .rect, 4, 1);
    try t.expectEqual(SelState{ .kind = .rect, .anchor_row = 4, .anchor_col = 1 }, rect);
}

test "copy-mode selections cover the anchor and cursor cells inclusively" {
    var sel: Selection = .{};

    // Cell-wise, cursor after the anchor.
    applyCopySelection(&sel, .{ .kind = .cell, .anchor_row = 0, .anchor_col = 2 }, 1, 3, 10);
    try t.expect(sel.contains(0, 2));
    try t.expect(!sel.contains(0, 1));
    try t.expect(sel.contains(1, 3));
    try t.expect(!sel.contains(1, 4));

    // Cell-wise, cursor before the anchor: still both ends.
    applyCopySelection(&sel, .{ .kind = .cell, .anchor_row = 1, .anchor_col = 3 }, 0, 2, 10);
    try t.expect(sel.contains(1, 3));
    try t.expect(!sel.contains(1, 4));
    try t.expect(sel.contains(0, 2));
    try t.expect(!sel.contains(0, 1));

    // Anchor and cursor on one cell select exactly that cell.
    applyCopySelection(&sel, .{ .kind = .cell, .anchor_row = -1, .anchor_col = 5 }, -1, 5, 10);
    try t.expect(sel.hasContent());
    try t.expect(sel.contains(-1, 5));
    try t.expect(!sel.contains(-1, 4));
    try t.expect(!sel.contains(-1, 6));

    // Line-wise: whole rows between the two, whichever is higher.
    applyCopySelection(&sel, .{ .kind = .line, .anchor_row = 2, .anchor_col = 7 }, 0, 1, 10);
    try t.expect(sel.contains(0, 0));
    try t.expect(sel.contains(2, 9));
    try t.expect(!sel.contains(3, 0));
    try t.expect(!sel.contains(-1, 9));

    // Rectangular: the column span of both, inclusive, on every row.
    applyCopySelection(&sel, .{ .kind = .rect, .anchor_row = 0, .anchor_col = 5 }, 2, 2, 10);
    try t.expect(sel.contains(1, 2));
    try t.expect(sel.contains(1, 5));
    try t.expect(!sel.contains(1, 6));
    try t.expect(!sel.contains(1, 1));
    try t.expect(!sel.contains(3, 3));

    applyCopySelection(&sel, .{ .kind = .none, .anchor_row = 0, .anchor_col = 5 }, 2, 2, 10);
    try t.expect(!sel.isActive());
}

test "the copy cursor clamps into the buffer and drags the view along" {
    var ts: TestScreen = undefined;
    try ts.init(10, 3, &.{ "l1", "l2", "l3", "l4", "l5", "l6" });
    defer ts.deinit();
    const s = ts.screen;
    try t.expectEqual(@as(u32, 3), s.scrollbackCount());
    const ext = extentOf(s);
    try t.expectEqual(Extent{ .top = -3, .bottom = 2, .last_col = 9 }, ext);

    // Past the edges: clamped, never out of the buffer.
    const below = clampMove(s, 9, 99);
    try t.expectEqual(@as(i32, 2), below.row);
    try t.expectEqual(@as(u16, 9), below.col);
    try t.expectEqual(@as(?u32, null), below.view_offset);
    const above = clampMove(s, -9, -4);
    try t.expectEqual(@as(i32, -3), above.row);
    try t.expectEqual(@as(u16, 0), above.col);
    // Moving above the view scrolls back exactly to the cursor.
    try t.expectEqual(@as(?u32, 3), above.view_offset);
    try t.expectEqual(@as(?u32, 1), clampMove(s, -1, 0).view_offset);

    // Scrolled back three rows, the live bottom row is off screen:
    // moving there scrolls forward to the live view.
    s.view_offset = 3;
    try t.expectEqual(@as(i32, -3), viewTopOf(s));
    try t.expectEqual(@as(?u32, 0), clampMove(s, 2, 0).view_offset);
    // A row already on screen leaves the view alone.
    try t.expectEqual(@as(?u32, null), clampMove(s, -2, 0).view_offset);
    // The view top never reaches past the oldest line.
    s.view_offset = 50;
    try t.expectEqual(@as(i32, -3), viewTopOf(s));
}

test "the alternate screen has no scrollback for copy mode to enter" {
    var ts: TestScreen = undefined;
    try ts.init(10, 3, &.{ "l1", "l2", "l3", "l4", "l5" });
    defer ts.deinit();
    var csi = @import("../parser/event.zig").Event.Csi{};
    csi.private = '?';
    csi.params[0] = 1049;
    csi.n_params = 1;
    csi.final = 'h';
    ts.screen.apply(.{ .csi = csi });
    try t.expect(ts.screen.use_alt);
    try t.expectEqual(@as(i32, 0), extentOf(ts.screen).top);
    try t.expectEqual(@as(i32, 0), clampMove(ts.screen, -2, 0).row);
}

test "{ and } stop on the next blank row or at the buffer edge" {
    var ts: TestScreen = undefined;
    try ts.init(10, 5, &.{ "a", "b", "", "c", "d" });
    defer ts.deinit();
    const s = ts.screen;
    try t.expectEqual(@as(i32, 2), paragraphTarget(s, 0, 1));
    try t.expectEqual(@as(i32, 2), paragraphTarget(s, 4, -1));
    // No blank row before the edge: the last row there.
    try t.expectEqual(@as(i32, 4), paragraphTarget(s, 3, 1));
    try t.expectEqual(@as(i32, 0), paragraphTarget(s, 1, -1));
    // Already at the edge: stays put.
    try t.expectEqual(@as(i32, 4), paragraphTarget(s, 4, 1));
}

test "word motions wrap to adjacent lines and stop at the buffer edge" {
    var ts: TestScreen = undefined;
    try ts.init(12, 3, &.{ "old line", "foo bar", "", "baz" });
    defer ts.deinit();
    const s = ts.screen;
    // "old line" is in scrollback now (row -1).
    try t.expectEqual(@as(u32, 1), s.scrollbackCount());
    const C = Screen.CopyCursor;

    try t.expectEqual(C{ .row = 0, .col = 4 }, wordTarget(s, 0, 0, .next, .word).?);
    // Out of words on this line: the blank row is skipped.
    try t.expectEqual(C{ .row = 2, .col = 0 }, wordTarget(s, 0, 4, .next, .word).?);
    try t.expectEqual(C{ .row = 0, .col = 2 }, wordTarget(s, 0, 0, .next_end, .word).?);
    try t.expectEqual(C{ .row = 0, .col = 4 }, wordTarget(s, 2, 0, .prev, .word).?);
    // Backwards off the top of the screen, into scrollback.
    try t.expectEqual(C{ .row = -1, .col = 4 }, wordTarget(s, 0, 0, .prev, .word).?);
    // Nothing further in either direction.
    try t.expect(wordTarget(s, -1, 0, .prev, .word) == null);
    try t.expect(wordTarget(s, 2, 0, .next, .word) == null);
}

test "f/F/t/T find a character on the cursor's own line only" {
    var ts: TestScreen = undefined;
    try ts.init(12, 2, &.{ "a,b,c", "x,y" });
    defer ts.deinit();
    const s = ts.screen;
    try t.expectEqual(@as(?u16, 1), findTarget(s, 0, 0, 'f', ','));
    try t.expectEqual(@as(?u16, 3), findTarget(s, 0, 1, 'f', ','));
    try t.expectEqual(@as(?u16, 2), findTarget(s, 0, 0, 't', ','));
    try t.expectEqual(@as(?u16, 3), findTarget(s, 0, 4, 'F', ','));
    try t.expectEqual(@as(?u16, 2), findTarget(s, 0, 4, 'T', ','));
    // Line-local: the comma on the next row is not a target, and a
    // miss is a no-op rather than a wrap.
    try t.expect(findTarget(s, 0, 4, 'f', ',') == null);
    try t.expect(findTarget(s, 0, 0, 'f', 'y') == null);
    try t.expect(findTarget(s, 0, 0, 'x', ',') == null);
}

test "^ and $ find the first and last written cell of a row" {
    var ts: TestScreen = undefined;
    try ts.init(12, 3, &.{ "  hi there", "" });
    defer ts.deinit();
    const s = ts.screen;
    try t.expectEqual(@as(i32, 2), copyModeLineStart(s, 0));
    try t.expectEqual(@as(i32, 9), copyModeLineEnd(s, 0));
    try t.expectEqual(@as(i32, 0), copyModeLineStart(s, 1));
    try t.expectEqual(@as(i32, 0), copyModeLineEnd(s, 1));
    // Rows outside the buffer answer column 0 rather than failing.
    try t.expectEqual(@as(i32, 0), copyModeLineEnd(s, -5));
}
