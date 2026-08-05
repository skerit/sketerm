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

// ── Keyboard hints (quick-select) ───────────────────────────

/// Enter hint mode on the focused pane: scan the visible screen
/// for URLs / paths / hashes, overlay labels, route keys to
/// `onHintKey` until a label is completed or Esc.
pub fn openHints(self: *Window) void {
    if (self.hints_pane != null) {
        self.exitHints();
        return;
    }
    // Modes are mutually exclusive — both intercept all keys.
    if (self.copymode_pane != null) self.exitCopyMode();
    const pane = self.focusedPane() orelse return;
    const hints_mod = @import("hints.zig");
    const matches = hints_mod.collectVisible(self.allocator, pane.terminal.screen) catch return;
    if (matches.len == 0) {
        self.allocator.free(matches);
        return;
    }
    self.hint_matches = matches;
    self.hints_pane = pane;
    self.hints_typed_len = 0;
    if (pane.input_ctx) |ictx| {
        ictx.hint_sink = onHintKey;
        ictx.hint_ctx = @ptrCast(self);
    }
    imBypass(pane, true);
    refreshHintOverlay(self);
}

pub fn exitHints(self: *Window) void {
    const pane = self.hints_pane orelse return;
    self.hints_pane = null;
    if (pane.input_ctx) |ictx| {
        ictx.hint_sink = null;
        ictx.hint_ctx = null;
    }
    imBypass(pane, false);
    pane.terminal.screen.hints_overlay = &.{};
    pane.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(pane.area));
    @import("hints.zig").freeMatches(self.allocator, self.hint_matches);
    self.allocator.free(self.hint_matches);
    self.hint_matches = &.{};
    self.hints_overlay_buf.clearRetainingCapacity();
}

/// Rebuild the overlay slice from matches whose label starts with
/// the typed prefix, then queue a redraw.
pub fn refreshHintOverlay(self: *Window) void {
    const pane = self.hints_pane orelse return;
    self.hints_overlay_buf.clearRetainingCapacity();
    const typed = self.hints_typed[0..self.hints_typed_len];
    for (self.hint_matches) |m| {
        if (!std.mem.startsWith(u8, m.label[0..m.label_len], typed)) continue;
        self.hints_overlay_buf.append(self.allocator, .{
            .row = m.row,
            .col_start = m.col_start,
            .col_end = m.col_end,
            .label = m.label,
            .label_len = m.label_len,
            .typed = self.hints_typed_len,
        }) catch break;
    }
    pane.terminal.screen.hints_overlay = self.hints_overlay_buf.items;
    pane.terminal.screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(pane.area));
}

/// A label was completed: open URLs with the default handler;
/// copy paths / hashes to both clipboards.
pub fn activateHint(self: *Window, m: @import("hints.zig").Match) void {
    const pane = self.hints_pane orelse return;
    if (m.text.len == 0) return;
    switch (m.kind) {
        .url => {
            var buf: [4096]u8 = undefined;
            const n = @min(m.text.len, buf.len - 1);
            @memcpy(buf[0..n], m.text[0..n]);
            buf[n] = 0;
            _ = c.g_app_info_launch_default_for_uri(&buf, null, null);
        },
        .path => {
            // A path hint whose file exists locally opens in the
            // editor; anything else (remote pane paths, deleted
            // files, no editor configured) copies as before.
            if (openPathInEditor(self, pane, m.text)) return;
            const z = self.allocator.allocSentinel(u8, m.text.len, 0) catch return;
            defer self.allocator.free(z);
            @memcpy(z, m.text);
            clipboard.copyToClipboard(@ptrCast(pane.area), z);
            clipboard.copyToPrimary(@ptrCast(pane.area), z);
        },
        .hash => {
            const z = self.allocator.allocSentinel(u8, m.text.len, 0) catch return;
            defer self.allocator.free(z);
            @memcpy(z, m.text);
            clipboard.copyToClipboard(@ptrCast(pane.area), z);
            clipboard.copyToPrimary(@ptrCast(pane.area), z);
        },
    }
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

    // Resolve to an absolute path: ~ → $HOME, relative → pane cwd.
    var abs_buf: [4096]u8 = undefined;
    const cwd: ?[]const u8 = if (pane.terminal.cwd) |d| d else null;
    const abs: []const u8 = blk: {
        if (fl.path[0] == '/') break :blk fl.path;
        if (fl.path.len >= 2 and fl.path[0] == '~' and fl.path[1] == '/') {
            const home = @import("../util/profile.zig").getenv("HOME") orelse return false;
            break :blk std.fmt.bufPrint(&abs_buf, "{s}{s}", .{ home, fl.path[1..] }) catch return false;
        }
        const base = cwd orelse return false;
        break :blk std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ base, fl.path }) catch return false;
    };
    var z_buf: [4096]u8 = undefined;
    const abs_z = std.fmt.bufPrintZ(&z_buf, "{s}", .{abs}) catch return false;
    if (c.access(abs_z.ptr, c.F_OK) != 0) return false;

    const editor: []const u8 = blk: {
        if (self.config.hint_editor.len > 0) break :blk self.config.hint_editor;
        const profile_util = @import("../util/profile.zig");
        if (profile_util.getenv("EDITOR")) |e| {
            if (e.len > 0) break :blk e;
        }
        if (profile_util.getenv("VISUAL")) |v| {
            if (v.len > 0) break :blk v;
        }
        return false;
    };

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
    self.search_pane = pane;
    if (self.search_bar) |w| c.gtk_widget_set_visible(w, 1);
    if (self.search_entry) |w| {
        c.gtk_editable_set_text(@ptrCast(w), "");
        _ = c.gtk_widget_grab_focus(w);
    }
    self.search_matches.clearRetainingCapacity();
    self.search_idx = 0;
    // Stale highlights from a previous open should not bleed into
    // this fresh session.
    pane.terminal.screen.search_highlights = &.{};
    pane.terminal.screen.search_active_idx = -1;
    if (self.search_label) |l| c.gtk_label_set_text(@ptrCast(l), "");
}

/// Close the search bar and clear any selection used as highlight.
pub fn closeSearch(self: *Window) void {
    if (self.search_bar) |w| c.gtk_widget_set_visible(w, 0);
    if (self.search_pane) |p| {
        p.terminal.screen.selection.clear();
        // Clear borrowed highlight slice BEFORE freeing the
        // backing storage — otherwise renderer reads dangling.
        p.terminal.screen.search_highlights = &.{};
        p.terminal.screen.search_active_idx = -1;
        p.terminal.screen.dirty = true;
        _ = c.gtk_widget_grab_focus(@ptrCast(p.area));
    }
    self.search_pane = null;
    self.search_matches.clearRetainingCapacity();
    self.search_idx = 0;
}

pub fn updateSearch(self: *Window, query: []const u8) void {
    const pane = self.search_pane orelse return;
    self.search_matches.deinit(self.allocator);
    self.search_matches = .empty;
    self.search_idx = 0;
    if (query.len > 0) {
        // Smart-case: lowercase-only needle implies CI; any
        // uppercase letter forces CS. The explicit per-search
        // toggle (Ctrl+I) and the config-level `search_case_sensitive`
        // both override.
        var ci = self.search_case_insensitive;
        if (!ci and !self.search_force_cs) {
            var has_upper = false;
            for (query) |b| {
                if (b >= 'A' and b <= 'Z') {
                    has_upper = true;
                    break;
                }
            }
            ci = !has_upper;
        }
        const matches = if (self.search_regex)
            pane.terminal.screen.searchOptsRegex(self.allocator, query, ci) catch return
        else
            pane.terminal.screen.searchOpts(self.allocator, query, ci) catch return;
        defer self.allocator.free(matches);
        self.search_matches.appendSlice(self.allocator, matches) catch return;
    }
    // Publish to the renderer — every match gets a translucent
    // overlay; the active one is brighter.
    pane.terminal.screen.search_highlights = self.search_matches.items;
    refreshSearchLabel(self);
    if (self.search_matches.items.len > 0) {
        // Jump to the last (most-recent) match — usually what users want.
        self.search_idx = self.search_matches.items.len - 1;
        pane.terminal.screen.search_active_idx = @intCast(self.search_idx);
        applyCurrentMatch(self);
    } else {
        pane.terminal.screen.selection.clear();
        pane.terminal.screen.search_active_idx = -1;
        pane.terminal.screen.dirty = true;
        // Pane is unfocused (search bar has focus); explicit
        // render needed to clear the previous highlight overlay.
        c.gtk_gl_area_queue_render(@ptrCast(pane.area));
    }
}

pub fn refreshSearchLabel(self: *Window) void {
    const lab = self.search_label orelse return;
    var buf: [64:0]u8 = undefined;
    if (self.search_matches.items.len == 0) {
        const s = std.fmt.bufPrintZ(&buf, "0/0", .{}) catch "0/0";
        c.gtk_label_set_text(@ptrCast(lab), s.ptr);
    } else {
        const s = std.fmt.bufPrintZ(&buf, "{d}/{d}", .{
            self.search_idx + 1,
            self.search_matches.items.len,
        }) catch "?/?";
        c.gtk_label_set_text(@ptrCast(lab), s.ptr);
    }
}

pub fn applyCurrentMatch(self: *Window) void {
    const pane = self.search_pane orelse return;
    if (self.search_matches.items.len == 0) return;
    const m = self.search_matches.items[self.search_idx];
    const screen = pane.terminal.screen;
    screen.search_active_idx = @intCast(self.search_idx);
    // Scroll into view.
    if (m.row < 0) {
        const dist: u32 = @intCast(-m.row);
        screen.view_offset = @min(screen.scrollbackCount(), dist);
    } else {
        screen.view_offset = 0;
    }
    screen.dirty = true;
    // Search interactions happen with the search bar focused,
    // not the pane — the pane's tick may be paused (no blink /
    // bell / animation). Without an explicit queue_render the
    // view-offset change wouldn't repaint until something else
    // wakes the GLArea.
    c.gtk_gl_area_queue_render(@ptrCast(pane.area));
    refreshSearchLabel(self);
}

pub fn nextMatch(self: *Window) void {
    if (self.search_matches.items.len == 0) return;
    self.search_idx = (self.search_idx + 1) % self.search_matches.items.len;
    applyCurrentMatch(self);
}

pub fn prevMatch(self: *Window) void {
    if (self.search_matches.items.len == 0) return;
    if (self.search_idx == 0) {
        self.search_idx = self.search_matches.items.len - 1;
    } else {
        self.search_idx -= 1;
    }
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

// ── Copy mode (keyboard-driven selection) ─────────────────────

/// Enter copy mode on the focused pane. The copy cursor starts at
/// the terminal cursor; every key press is routed through the
/// pane input ctx's `copymode_sink` until exit (Esc/q/y/Enter).
pub fn openCopyMode(self: *Window) void {
    if (self.copymode_pane != null) self.exitCopyMode();
    // Modes are mutually exclusive — both intercept all keys.
    if (self.hints_pane != null) self.exitHints();
    const pane = self.focusedPane() orelse return;
    const ictx = pane.input_ctx orelse return;
    const screen = pane.terminal.screen;
    self.copymode_pane = pane;
    self.copymode_sel = .none;
    self.copymode_find_pending = 0;
    self.copymode_find_kind = 0;
    self.copymode_row = @intCast(@min(screen.row, screen.rows -| 1));
    self.copymode_col = @min(screen.col, screen.cols -| 1);
    ictx.copymode_sink = onCopyModeKey;
    ictx.copymode_ctx = @ptrCast(self);
    imBypass(pane, true);
    copyModeRefresh(self);
}

/// Leave copy mode: uninstall the key sink, drop the overlay
/// cursor and any in-progress selection, repaint.
pub fn exitCopyMode(self: *Window) void {
    const pane = self.copymode_pane orelse return;
    self.copymode_pane = null;
    self.copymode_sel = .none;
    self.copymode_find_pending = 0;
    if (pane.input_ctx) |ictx| {
        ictx.copymode_sink = null;
        ictx.copymode_ctx = null;
    }
    imBypass(pane, false);
    const screen = pane.terminal.screen;
    screen.copy_cursor = null;
    screen.selection.clear();
    screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(pane.area));
}

/// Copy-mode key dispatch. Returns true when the key is
/// consumed; bare modifier presses return false so chords (e.g.
/// Ctrl+v) can still assemble in GTK's modifier tracking.
pub fn handleCopyModeKey(self: *Window, keyval: c_uint, state: c.GdkModifierType) bool {
    const pane = self.copymode_pane orelse return false;
    const screen = pane.terminal.screen;
    const ctrl = (state & c.GDK_CONTROL_MASK) != 0;
    const row = self.copymode_row;
    const col: i32 = self.copymode_col;
    switch (keyval) {
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
        => return false,
        else => {},
    }

    // f/F/t/T ate the previous key and this one names the target.
    if (self.copymode_find_pending != 0) {
        const kind = self.copymode_find_pending;
        self.copymode_find_pending = 0;
        if (keyval == c.GDK_KEY_Escape) return true;
        const ch = c.gdk_keyval_to_unicode(keyval);
        if (ch == 0) return true;
        self.copymode_find_kind = kind;
        self.copymode_find_char = ch;
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
        c.GDK_KEY_g => {
            const sb: i32 = if (screen.use_alt) 0 else @intCast(screen.scrollbackCount());
            copyModeMoveTo(self, -sb, col);
        },
        c.GDK_KEY_G => copyModeMoveTo(self, @as(i32, @intCast(screen.rows)) - 1, col),
        // H / M / L — high, middle and low row of what is on screen,
        // which is not the same as the buffer once scrolled back.
        c.GDK_KEY_H => copyModeMoveTo(self, copyModeViewTop(self), col),
        c.GDK_KEY_M => copyModeMoveTo(self, copyModeViewTop(self) + @divTrunc(@as(i32, @intCast(screen.rows)) - 1, 2), col),
        c.GDK_KEY_L => copyModeMoveTo(self, copyModeViewTop(self) + @as(i32, @intCast(screen.rows)) - 1, col),
        // Page and half-page scrolling.
        c.GDK_KEY_Page_Down => copyModeMoveTo(self, row + @as(i32, @intCast(screen.rows)), col),
        c.GDK_KEY_Page_Up => copyModeMoveTo(self, row - @as(i32, @intCast(screen.rows)), col),
        c.GDK_KEY_f => {
            if (ctrl) {
                copyModeMoveTo(self, row + @as(i32, @intCast(screen.rows)), col);
            } else {
                self.copymode_find_pending = 'f';
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
        c.GDK_KEY_F => self.copymode_find_pending = 'F',
        c.GDK_KEY_t => self.copymode_find_pending = 't',
        c.GDK_KEY_T => self.copymode_find_pending = 'T',
        c.GDK_KEY_semicolon => {
            if (self.copymode_find_kind != 0) copyModeFind(self, self.copymode_find_kind, self.copymode_find_char);
        },
        c.GDK_KEY_comma => {
            if (self.copymode_find_kind != 0) copyModeFind(self, findReverse(self.copymode_find_kind), self.copymode_find_char);
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
fn copyModeViewTop(self: *Window) i32 {
    const pane = self.copymode_pane orelse return 0;
    const screen = pane.terminal.screen;
    return -@as(i32, @intCast(@min(screen.view_offset, screen.scrollbackCount())));
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
    const pane = self.copymode_pane orelse return;
    const screen = pane.terminal.screen;
    const cells = screen.lineCellsAtPub(self.copymode_row) orelse return;
    const col: usize = self.copymode_col;
    const hit = switch (kind) {
        'f' => wm.findForward(cells, col, ch, false),
        't' => wm.findForward(cells, col, ch, true),
        'F' => wm.findBackward(cells, col, ch, false),
        'T' => wm.findBackward(cells, col, ch, true),
        else => null,
    };
    if (hit) |c2| copyModeMoveTo(self, self.copymode_row, @intCast(c2));
}

/// { / } — the next blank line in `dir`, or the buffer edge.
pub fn copyModeParagraph(self: *Window, dir: i32) void {
    const pane = self.copymode_pane orelse return;
    const screen = pane.terminal.screen;
    const sb: i32 = if (screen.use_alt) 0 else @intCast(screen.scrollbackCount());
    const max_row: i32 = @as(i32, @intCast(screen.rows)) - 1;
    var r = self.copymode_row;
    var last = r;
    while (true) {
        r += dir;
        if (r < -sb or r > max_row) break;
        last = r;
        if (copyModeRowBlank(screen, r)) break;
    }
    copyModeMoveTo(self, last, 0);
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
    const pane = self.copymode_pane orelse return;
    const screen = pane.terminal.screen;
    const hit = bracket.matchAt(screen, self.copymode_row, self.copymode_col, @intCast(screen.rows)) orelse return;
    copyModeMoveTo(self, hit.row, hit.col);
}

/// n / N — move the copy cursor onto the next search match. Needs the
/// search bar to have been used; without matches it does nothing.
pub fn copyModeSearchStep(self: *Window, dir: i32) void {
    const pane = self.copymode_pane orelse return;
    if (self.search_pane != pane) return;
    const matches = self.search_matches.items;
    if (matches.len == 0) return;

    const row = self.copymode_row;
    const col: i32 = self.copymode_col;
    // Nearest match strictly after (or before) the cursor, in reading
    // order. The list is already ordered oldest row first.
    if (dir > 0) {
        for (matches, 0..) |m, i| {
            if (m.row > row or (m.row == row and @as(i32, @intCast(m.col)) > col)) {
                self.search_idx = i;
                copyModeMoveTo(self, m.row, @intCast(m.col));
                return;
            }
        }
        self.search_idx = 0;
        copyModeMoveTo(self, matches[0].row, @intCast(matches[0].col));
    } else {
        var i = matches.len;
        while (i > 0) {
            i -= 1;
            const m = matches[i];
            if (m.row < row or (m.row == row and @as(i32, @intCast(m.col)) < col)) {
                self.search_idx = i;
                copyModeMoveTo(self, m.row, @intCast(m.col));
                return;
            }
        }
        self.search_idx = matches.len - 1;
        const m = matches[matches.len - 1];
        copyModeMoveTo(self, m.row, @intCast(m.col));
    }
}

/// Toggle the selection anchor. Re-pressing the active kind drops
/// the anchor; switching kinds keeps the existing anchor cell.
pub fn copyModeToggleSel(self: *Window, kind: winmod.CopyModeSel) void {
    if (self.copymode_sel == kind) {
        self.copymode_sel = .none;
    } else {
        if (self.copymode_sel == .none) {
            self.copymode_anchor_row = self.copymode_row;
            self.copymode_anchor_col = self.copymode_col;
        }
        self.copymode_sel = kind;
    }
    copyModeRefresh(self);
}

/// Move the copy cursor, clamping into the buffer (scrollback top
/// .. live bottom) and scrolling the view so it stays visible.
pub fn copyModeMoveTo(self: *Window, row: i32, col: i32) void {
    const pane = self.copymode_pane orelse return;
    const screen = pane.terminal.screen;
    const sb: i32 = if (screen.use_alt) 0 else @intCast(screen.scrollbackCount());
    const max_row: i32 = @as(i32, @intCast(screen.rows)) - 1;
    const max_col: i32 = @as(i32, @intCast(screen.cols)) - 1;
    self.copymode_row = std.math.clamp(row, -sb, max_row);
    self.copymode_col = @intCast(std.math.clamp(col, 0, max_col));
    // Keep the cursor on-screen: its visible row is row +
    // view_offset. Moving past the top scrolls back; past the
    // bottom scrolls forward (same clamping as scrollback_page_*).
    const view_off: i32 = @intCast(@min(screen.view_offset, screen.scrollbackCount()));
    if (self.copymode_row + view_off < 0) {
        screen.view_offset = @intCast(-self.copymode_row);
    } else if (self.copymode_row + view_off > max_row) {
        screen.view_offset = @intCast(max_row - self.copymode_row);
    }
    copyModeRefresh(self);
}

pub const WordDir = enum { next, prev, next_end, prev_end };

/// w / b / e — jump to the next or previous word boundary, wrapping to
/// adjacent lines when the current one runs out of words. `kind`
/// picks the alphabet: the word_chars set, or vim's blank-delimited
/// WORD for the upper-case motions.
pub fn copyModeWord(self: *Window, dir: WordDir, kind: wm.Kind) void {
    const pane = self.copymode_pane orelse return;
    const screen = pane.terminal.screen;
    const chars = screen.word_chars;
    if (screen.lineCellsAtPub(self.copymode_row)) |cells| {
        const hit = switch (dir) {
            .next => wm.nextStart(cells, chars, self.copymode_col, kind),
            .prev => wm.prevStart(cells, chars, self.copymode_col, kind),
            .next_end => wm.nextEnd(cells, chars, self.copymode_col, kind),
            .prev_end => wm.prevEnd(cells, chars, self.copymode_col, kind),
        };
        if (hit) |c2| {
            copyModeMoveTo(self, self.copymode_row, @intCast(c2));
            return;
        }
    }
    const forward = dir == .next or dir == .next_end;
    const sb: i32 = if (screen.use_alt) 0 else @intCast(screen.scrollbackCount());
    const max_row: i32 = @as(i32, @intCast(screen.rows)) - 1;
    var row = self.copymode_row;
    while (true) {
        row = if (forward) row + 1 else row - 1;
        if (row < -sb or row > max_row) return; // buffer edge — stay put
        const cells = screen.lineCellsAtPub(row) orelse continue;
        const hit = switch (dir) {
            .next => wm.firstStart(cells, chars, kind),
            .prev => wm.lastStart(cells, chars, kind),
            .next_end => wm.firstEnd(cells, chars, kind),
            .prev_end => wm.lastEnd(cells, chars, kind),
        };
        if (hit) |c2| {
            copyModeMoveTo(self, row, @intCast(c2));
            return;
        }
    }
}

/// y / Enter — copy the active selection to CLIPBOARD + PRIMARY
/// and leave copy mode. No selection → just exits.
pub fn copyModeYank(self: *Window) void {
    const pane = self.copymode_pane orelse return;
    const screen = pane.terminal.screen;
    if (screen.selection.isActive()) blk: {
        const text = screen.extractSelection(self.allocator) catch break :blk;
        defer self.allocator.free(text);
        if (text.len == 0) break :blk;
        const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch break :blk;
        defer self.allocator.free(cstr);
        @memcpy(cstr, text);
        clipboard.copyToClipboard(@ptrCast(pane.area), cstr);
        clipboard.copyToPrimary(@ptrCast(pane.area), cstr);
    }
    self.exitCopyMode();
}

/// Re-derive `screen.selection` from anchor + cursor, publish the
/// overlay cursor, repaint. Called after every copy-mode change.
pub fn copyModeRefresh(self: *Window) void {
    const pane = self.copymode_pane orelse return;
    const screen = pane.terminal.screen;
    const row = self.copymode_row;
    const col = self.copymode_col;
    const a_row = self.copymode_anchor_row;
    const a_col = self.copymode_anchor_col;
    switch (self.copymode_sel) {
        .none => screen.selection.clear(),
        .cell => {
            // Inclusive both ways: Selection's bottom column is
            // exclusive, so bump whichever endpoint is later.
            if (row > a_row or (row == a_row and col >= a_col)) {
                screen.selection.start(a_row, a_col, .normal);
                screen.selection.extend(row, @as(i32, col) + 1);
            } else {
                screen.selection.start(a_row, @as(i32, a_col) + 1, .normal);
                screen.selection.extend(row, col);
            }
        },
        .line => {
            // Whole lines, anchor row through cursor row.
            screen.selection.start(@min(a_row, row), 0, .normal);
            screen.selection.extend(@max(a_row, row), @intCast(screen.cols));
        },
        .rect => {
            const lo: i32 = @min(a_col, col);
            const hi: i32 = @as(i32, @max(a_col, col)) + 1;
            screen.selection.start(a_row, lo, .rectangular);
            screen.selection.extend(row, hi);
        },
    }
    screen.copy_cursor = .{ .row = row, .col = col };
    screen.dirty = true;
    c.gtk_gl_area_queue_render(@ptrCast(pane.area));
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
        self.search_case_insensitive = !self.search_case_insensitive;
        if (self.search_entry) |w| {
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
        self.search_regex = !self.search_regex;
        if (self.search_entry) |w| {
            const placeholder: [*:0]const u8 = if (self.search_regex)
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
pub fn onHintKey(ctx: ?*anyopaque, keyval: c_uint) bool {
    const self = cast.userData(Window, ctx);
    if (self.hints_pane == null) return false;
    switch (keyval) {
        c.GDK_KEY_Escape => {
            self.exitHints();
            return true;
        },
        c.GDK_KEY_BackSpace => {
            if (self.hints_typed_len > 0) {
                self.hints_typed_len -= 1;
                refreshHintOverlay(self);
            }
            return true;
        },
        c.GDK_KEY_Shift_L,
        c.GDK_KEY_Shift_R,
        c.GDK_KEY_Control_L,
        c.GDK_KEY_Control_R,
        c.GDK_KEY_Alt_L,
        c.GDK_KEY_Alt_R,
        c.GDK_KEY_Super_L,
        c.GDK_KEY_Super_R,
        c.GDK_KEY_Caps_Lock,
        c.GDK_KEY_Num_Lock,
        => return false,
        else => {},
    }
    const u = c.gdk_keyval_to_unicode(keyval);
    if (u >= 'a' and u <= 'z' and self.hints_typed_len < 2) {
        const candidate_len = self.hints_typed_len + 1;
        self.hints_typed[self.hints_typed_len] = @intCast(u);
        // Count matches under the new prefix; activate on a unique
        // FULL match, revert the keystroke when nothing matches.
        var matching: usize = 0;
        var full: ?@import("hints.zig").Match = null;
        for (self.hint_matches) |m| {
            if (!std.mem.startsWith(u8, m.label[0..m.label_len], self.hints_typed[0..candidate_len])) continue;
            matching += 1;
            if (m.label_len == candidate_len) full = m;
        }
        if (matching == 0) return true; // ignore stray key
        if (full) |m| {
            activateHint(self, m);
            self.exitHints();
            return true;
        }
        self.hints_typed_len = candidate_len;
        refreshHintOverlay(self);
        return true;
    }
    // Swallow everything else — hint mode owns the keyboard.
    return true;
}
