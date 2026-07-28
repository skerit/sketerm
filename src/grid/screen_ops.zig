//! Screen control-sequence operations — CSI dispatch, cursor
//! primitives, erase/scroll, modes and SGR — split out of screen.zig.
//! Functions take the owning *Screen and are aliased back into Screen;
//! the split boundary follows screen.zig's own section banners.

const std = @import("std");
const Screen = @import("screen.zig").Screen;
const Event = @import("../parser/event.zig").Event;
const Cell = @import("cell.zig").Cell;
const Line = @import("line.zig").Line;
const Pool = @import("style_pool.zig").Pool;
const Charset = Screen.Charset;
const Entry = @import("style_pool.zig").Entry;

// ── CSI dispatch ─────────────────────────────────────────────

pub fn csi(self: *Screen, params: Event.Csi) void {
    // Top-level dispatch by private-prefix byte ('?', '>', '=', '<')
    // or no prefix. Each branch delegates to a focused handler that
    // knows the inner switch shape for that prefix.
    switch (params.private) {
        '?' => csiPrivate(self, params),
        '>' => csiAux(self, params),
        '=', '<' => csiKittyKbd(self, params),
        else => csiPublic(self, params),
    }
}

pub fn csiPrivate(self: *Screen, params: Event.Csi) void {
    // DECRQM — `CSI ? Pa $ p`, query a DEC private mode.
    if (params.n_intermediates == 1 and params.intermediates[0] == '$' and params.final == 'p') {
        decrqm(self, params.paramOrDefault(0, 0));
        return;
    }
    switch (params.final) {
        'h' => modeSet(self, params, true),
        'l' => modeSet(self, params, false),
        // DECSED/DECSEL — selective erase. We don't model the
        // protection bit, so treat as plain ED/EL.
        'J' => eraseDisplay(self, params.paramOrDefault(0, 0)),
        'K' => eraseLine(self, params.paramOrDefault(0, 0)),
        'u' => {
            // Kitty kbd: CSI ? u — query flags.
            var kbuf: [16]u8 = undefined;
            const out = std.fmt.bufPrint(&kbuf, "\x1b[?{d}u", .{self.kitty_kbd_flags}) catch return;
            respond(self, out);
        },
        'n' => {
            // DSR ?996 — dark/light color-scheme query (contour,
            // kitty 0.38+). GUI-owned: only the GUI knows the
            // theme, so daemon screens defer to the mirror.
            if (params.paramOrDefault(0, 0) == 996) {
                if (self.defer_gui_queries) return;
                respondForce(self, if (self.color_scheme_dark) "\x1b[?997;1n" else "\x1b[?997;2n");
            }
        },
        else => {},
    }
}

pub fn csiAux(self: *Screen, params: Event.Csi) void {
    switch (params.final) {
        'c' => respond(self, "\x1b[>42;1;0c"), // DA2: vendor 42 (sketerm), version 1
        'q' => respond(self, "\x1bP>|sketerm 0.1.0\x1b\\"), // XTVERSION
        'm' => {
            // XTMODKEYS — `CSI > Pn ; Pp m`. Pn=4 sets
            // modifyOtherKeys level. We accept the level but
            // don't yet apply it to key encoding.
            if (params.n_params >= 1 and params.params[0] == 4) {
                self.modify_other_keys = if (params.n_params >= 2)
                    @intCast(@min(params.params[1], 2))
                else
                    0;
            }
        },
        'u' => {
            // Kitty kbd: CSI > flags u — set flags directly.
            self.kitty_kbd_flags = @intCast(@min(params.paramOrDefault(0, 0), 0xFF));
        },
        else => {},
    }
}

pub fn csiKittyKbd(self: *Screen, params: Event.Csi) void {
    if (params.private == '=') {
        // Kitty kbd: CSI = flags ; mode u
        //   mode 1 = set, 2 = push+set, 3 = pop
        if (params.final == 'u') {
            const flags: u8 = @intCast(@min(params.paramOrDefault(0, 0), 0xFF));
            const mode: u32 = params.paramOrDefault(1, 1);
            switch (mode) {
                1 => self.kitty_kbd_flags = flags,
                2 => {
                    if (self.kitty_kbd_depth < self.kitty_kbd_stack.len) {
                        self.kitty_kbd_stack[self.kitty_kbd_depth] = self.kitty_kbd_flags;
                        self.kitty_kbd_depth += 1;
                    }
                    self.kitty_kbd_flags = flags;
                },
                3 => {
                    if (self.kitty_kbd_depth > 0) {
                        self.kitty_kbd_depth -= 1;
                        self.kitty_kbd_flags = self.kitty_kbd_stack[self.kitty_kbd_depth];
                    } else {
                        self.kitty_kbd_flags = 0;
                    }
                },
                else => {},
            }
        }
        return;
    }
    if (params.private == '<') {
        // Kitty kbd: CSI < N u — pop N levels.
        if (params.final == 'u') {
            const n = params.paramOrDefault(0, 1);
            var k: u32 = 0;
            while (k < n and self.kitty_kbd_depth > 0) : (k += 1) {
                self.kitty_kbd_depth -= 1;
                self.kitty_kbd_flags = self.kitty_kbd_stack[self.kitty_kbd_depth];
            }
            if (self.kitty_kbd_depth == 0 and k < n) self.kitty_kbd_flags = 0;
        }
        return;
    }
}

pub fn csiPublic(self: *Screen, params: Event.Csi) void {
    // Intermediate-distinguished: e.g. `CSI Ps SP q` = DECSCUSR.
    if (params.n_intermediates == 1 and params.intermediates[0] == ' ') {
        switch (params.final) {
            'q' => decscusr(self, params.paramOrDefault(0, 0)),
            else => {},
        }
        return;
    }
    if (params.n_intermediates == 1 and params.intermediates[0] == '!') {
        switch (params.final) {
            'p' => decstr(self, ),
            else => {},
        }
        return;
    }
    if (params.n_intermediates == 1 and params.intermediates[0] == '"') {
        // DECSCA (`CSI Ps " q`) — selective character protection.
        // We don't model protection; accept silently to keep the
        // parser quiet for terminfo entries that send it.
        return;
    }
    // Public DECRQM — `CSI Pa $ p`. Reports state of an ANSI mode
    // (IRM=4, LNM=20). xterm spec: reply `CSI Pa ; Ps $ y`.
    if (params.n_intermediates == 1 and params.intermediates[0] == '$' and params.final == 'p') {
        const mode = params.paramOrDefault(0, 0);
        const known: ?bool = switch (mode) {
            4 => self.insert_mode,
            20 => self.line_feed_mode,
            else => null,
        };
        const ps: u8 = if (known) |on| (if (on) 1 else 2) else 0;
        var out: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&out, "\x1b[{d};{d}$y", .{ mode, ps }) catch return;
        respond(self, s);
        return;
    }

    switch (params.final) {
        // Cursor movement.
        'A' => cursorUp(self, params.paramOrDefault(0, 1)),
        'B', 'e' => cursorDown(self, params.paramOrDefault(0, 1)),
        'C', 'a' => cursorRight(self, params.paramOrDefault(0, 1)),
        'D' => cursorLeft(self, params.paramOrDefault(0, 1)),
        'E' => {
            cursorDown(self, params.paramOrDefault(0, 1));
            self.col = 0;
            self.pending_wrap = false;
        },
        'F' => {
            cursorUp(self, params.paramOrDefault(0, 1));
            self.col = 0;
            self.pending_wrap = false;
        },
        'G', '`' => {
            const c = params.paramOrDefault(0, 1);
            self.col = if (c == 0) 0 else @min(@as(u16, @intCast(@min(c, 0xFFFF))) - 1, self.cols - 1);
            self.pending_wrap = false;
        },
        'H', 'f' => cursorPos(self, params.paramOrDefault(0, 1), params.paramOrDefault(1, 1)),
        'd' => {
            const r = params.paramOrDefault(0, 1);
            self.row = if (r == 0) 0 else @min(@as(u16, @intCast(@min(r, 0xFFFF))) - 1, self.rows - 1);
            self.pending_wrap = false;
        },
        's' => saveCursor(self, ),
        'u' => restoreCursor(self, ),

        // Erase.
        'J' => eraseDisplay(self, params.paramOrDefault(0, 0)),
        'K' => eraseLine(self, params.paramOrDefault(0, 0)),
        'X' => {
            const n = params.paramOrDefault(0, 1);
            // Clamp in u32: col + n can exceed u16 for large params.
            const hi: u16 = @intCast(@min(@as(u32, self.col) + n, @as(u32, self.cols)));
            if (self.clusters.count() > 0) self.clearClustersRange(self.row, self.col, hi);
            self.splitWidePair(self.line(self.row), self.col);
            if (hi > 0) self.splitWidePair(self.line(self.row), hi - 1);
            self.line(self.row).eraseRangeStyled(self.col, hi, self.cur_style);
        },
        '@' => insertChars(self, params.paramOrDefault(0, 1)),
        'P' => deleteChars(self, params.paramOrDefault(0, 1)),

        // Scroll.
        'S' => scrollUp(self, params.paramOrDefault(0, 1)),
        'T' => scrollDown(self, params.paramOrDefault(0, 1)),
        'L' => insertLines(self, params.paramOrDefault(0, 1)),
        'M' => deleteLines(self, params.paramOrDefault(0, 1)),

        // Scroll region (DECSTBM).
        'r' => setScrollRegion(self, params),

        // SGR.
        'm' => sgr(self, params),

        // REP — repeat preceding char Pn times.
        'b' => rep(self, params.paramOrDefault(0, 1)),

        // CHT / CBT — forward / backward tab Pn times.
        'I' => {
            var n = params.paramOrDefault(0, 1);
            if (n == 0) n = 1;
            var i: u32 = 0;
            while (i < n) : (i += 1) self.col = self.nextTabStop(self.col);
            self.pending_wrap = false;
        },
        'Z' => {
            var n = params.paramOrDefault(0, 1);
            if (n == 0) n = 1;
            var i: u32 = 0;
            while (i < n) : (i += 1) self.col = self.prevTabStop(self.col);
            self.pending_wrap = false;
        },

        // TBC — clear tab stop(s).
        'g' => {
            const arg = params.paramOrDefault(0, 0);
            switch (arg) {
                0 => if (self.col < self.tab_stops.items.len) {
                    self.tab_stops.items[self.col] = false;
                },
                3 => for (self.tab_stops.items) |*s| {
                    s.* = false;
                },
                else => {},
            }
        },

        // Device status report.
        'n' => dsr(self, params),
        // Primary device attributes.
        'c' => respondDa(self, ),
        // Window manipulation reports.
        't' => windowOps(self, params),

        // Public-mode SM / RM. Common one is IRM (4) = insert.
        'h' => publicModeSet(self, params, true),
        'l' => publicModeSet(self, params, false),

        else => {},
    }
}

pub fn publicModeSet(self: *Screen, params: Event.Csi, set: bool) void {
    var i: usize = 0;
    while (i < params.n_params) : (i += 1) {
        switch (params.params[i]) {
            4 => self.insert_mode = set, // IRM
            20 => self.line_feed_mode = set, // LNM
            else => {},
        }
    }
}

/// DECRQM — reply to a private-mode query.
/// Reply: CSI ? Pa ; Ps $ y where Ps =
///   0 not recognized, 1 set, 2 reset, 3 permanently set, 4 permanently reset.
pub fn decrqm(self: *Screen, mode: u32) void {
    // Mode 2027 (grapheme clustering) is always on and can't be
    // disabled — DECRPM 3 = "permanently set".
    if (mode == 2027) {
        var out27: [32]u8 = undefined;
        const s27 = std.fmt.bufPrint(&out27, "\x1b[?{d};3$y", .{mode}) catch return;
        respond(self, s27);
        return;
    }
    const known: ?bool = switch (mode) {
        1 => self.app_cursor_keys,
        // DECANM — VT52 vs ANSI. We have on_decanm but don't
        // mirror the parser's vt52 flag here; report ANSI (set)
        // since it's the steady-state for any sane app.
        2 => true,
        3 => false, // DECCOLM is rarely set; default reset
        5 => self.reverse_screen, // DECSCNM
        6 => self.origin_mode,
        7 => self.autowrap,
        // 8 (DECARM auto-repeat): always on (controlled by OS).
        8 => true,
        // 12 (cursor blink): track via cursor_shape
        12 => switch (self.cursor_shape) {
            .block_blink, .underline_blink, .bar_blink => true,
            else => false,
        },
        25 => self.cursor_visible,
        40 => self.allow_decolm,
        // DECTCEM-bound mouse modes
        1000 => self.mouse_mode == 1000,
        1002 => self.mouse_mode == 1002,
        1003 => self.mouse_mode == 1003,
        1004 => self.focus_reports,
        1005 => self.mouse_enc == .utf8,
        1006 => self.mouse_enc == .sgr,
        1015 => self.mouse_enc == .urxvt,
        1016 => self.mouse_enc == .sgr_pixel,
        2026 => self.sync_output,
        2031 => self.mode_2031,
        2048 => self.in_band_resize,
        // 1007 (alt-screen scroll): we don't, treat as off.
        1007 => false,
        47, 1047, 1049 => self.use_alt,
        2004 => self.bracketed_paste,
        else => null,
    };
    const ps: u8 = if (known) |on| (if (on) 1 else 2) else 0;
    var out: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&out, "\x1b[?{d};{d}$y", .{ mode, ps }) catch return;
    respond(self, s);
}

pub fn rep(self: *Screen, n: u32) void {
    if (self.last_print_cp == 0) return;
    const cp = self.last_print_cp;
    const limit = @min(n, @as(u32, self.cols) * @as(u32, self.rows));
    var i: u32 = 0;
    while (i < limit) : (i += 1) self.printCp(cp);
}

pub fn dsr(self: *Screen, params: Event.Csi) void {
    const arg = params.paramOrDefault(0, 0);
    switch (arg) {
        5 => respond(self, "\x1b[0n"), // OK
        6 => {
            var resp_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&resp_buf, "\x1b[{d};{d}R", .{ self.row + 1, self.col + 1 }) catch return;
            respond(self, s);
        },
        else => {},
    }
}

pub fn respondDa(self: *Screen) void {
    // VT220 + sixel + ANSI color (62=VT220, 4=sixel, 22=color).
    respond(self, "\x1b[?62;4;22c");
}

pub fn decscusr(self: *Screen, ps: u32) void {
    self.cursor_shape = switch (ps) {
        0, 1 => .block_blink,
        2 => .block_steady,
        3 => .underline_blink,
        4 => .underline_steady,
        5 => .bar_blink,
        6 => .bar_steady,
        else => self.cursor_shape,
    };
}

pub fn windowOps(self: *Screen, params: Event.Csi) void {
    const arg = params.paramOrDefault(0, 0);
    var resp_buf: [32]u8 = undefined;
    switch (arg) {
        11 => respond(self, "\x1b[1t"), // window state: not iconified
        13 => respond(self, "\x1b[3;0;0t"), // window position: 0,0 (we don't know)
        14 => {
            // Pixels — accurate when Pane has reported cell
            // metrics; falls back to the legacy 8x16 approximation
            // when uninitialised (e.g. tests).
            const cw: u32 = if (self.cell_pixel_w > 0) self.cell_pixel_w else 8;
            const ch: u32 = if (self.cell_pixel_h > 0) self.cell_pixel_h else 16;
            const w: u32 = @as(u32, self.cols) * cw;
            const h: u32 = @as(u32, self.rows) * ch;
            const s = std.fmt.bufPrint(&resp_buf, "\x1b[4;{d};{d}t", .{ h, w }) catch return;
            respond(self, s);
        },
        16 => {
            // CSI 16 t — report cell pixel size as `\x1b[6;<h>;<w>t`.
            const cw: u32 = if (self.cell_pixel_w > 0) self.cell_pixel_w else 8;
            const ch: u32 = if (self.cell_pixel_h > 0) self.cell_pixel_h else 16;
            const s = std.fmt.bufPrint(&resp_buf, "\x1b[6;{d};{d}t", .{ ch, cw }) catch return;
            respond(self, s);
        },
        18 => {
            const s = std.fmt.bufPrint(&resp_buf, "\x1b[8;{d};{d}t", .{ self.rows, self.cols }) catch return;
            respond(self, s);
        },
        19 => {
            const s = std.fmt.bufPrint(&resp_buf, "\x1b[9;{d};{d}t", .{ self.rows, self.cols }) catch return;
            respond(self, s);
        },
        20, 21 => {
            // 20 = report icon label, 21 = report window title.
            // We don't model an icon label distinct from the title.
            // Format per xterm: ESC ] <L|l> <title> ESC \.
            const title = self.last_title orelse "";
            const code: u8 = if (arg == 20) 'L' else 'l';
            var out_buf: [512]u8 = undefined;
            const max_t = @min(title.len, out_buf.len - 5);
            var off: usize = 0;
            out_buf[off] = 0x1B;
            off += 1;
            out_buf[off] = ']';
            off += 1;
            out_buf[off] = code;
            off += 1;
            @memcpy(out_buf[off .. off + max_t], title[0..max_t]);
            off += max_t;
            out_buf[off] = 0x1B;
            off += 1;
            out_buf[off] = '\\';
            off += 1;
            respond(self, out_buf[0..off]);
        },
        // 22 — save title onto stack. Param 0/2 = window title;
        // we treat both identically (no separate icon name).
        22 => titleStackPush(self, ),
        // 23 — restore title from stack.
        23 => titleStackPop(self, ),
        else => {},
    }
}

pub fn titleStackPush(self: *Screen) void {
    const cur = self.last_title orelse return;
    // Drop oldest if full.
    if (self.title_stack_depth == self.title_stack.len) {
        if (self.title_stack[0]) |old| self.allocator.free(old);
        // Shift left.
        var i: usize = 1;
        while (i < self.title_stack.len) : (i += 1) {
            self.title_stack[i - 1] = self.title_stack[i];
        }
        self.title_stack_depth -= 1;
    }
    const dup = self.allocator.dupe(u8, cur) catch return;
    self.title_stack[self.title_stack_depth] = dup;
    self.title_stack_depth += 1;
}

pub fn titleStackPop(self: *Screen) void {
    if (self.title_stack_depth == 0) return;
    self.title_stack_depth -= 1;
    const restored = self.title_stack[self.title_stack_depth] orelse return;
    self.title_stack[self.title_stack_depth] = null;
    // Replace last_title.
    if (self.last_title) |old| self.allocator.free(old);
    self.last_title = restored;
    // Push down to UI.
    if (self.sink.on_title) |f| f(self.sink.ctx, restored);
}

pub fn respond(self: *Screen, bytes: []const u8) void {
    if (self.mute_responses) return;
    if (self.sink.on_write_pty) |f| f(self.sink.ctx, bytes);
}

/// For replies that are GUI-owned (the daemon defers them): a
/// mux mirror IS the designated responder, so the mute doesn't
/// apply. Identical to respond() on local screens.
pub fn respondForce(self: *Screen, bytes: []const u8) void {
    if (self.sink.on_write_pty) |f| f(self.sink.ctx, bytes);
}

pub fn escFinal(self: *Screen, ef: Event.EscFinal) void {
    // SCS — character-set designation. `ESC ( X` for G0, `ESC ) X`
    // for G1, where X selects ASCII (B) or DEC graphics (0).
    if (ef.n_intermediates == 1 and (ef.intermediates[0] == '(' or ef.intermediates[0] == ')')) {
        const slot: *Charset = if (ef.intermediates[0] == '(') &self.charset_g0 else &self.charset_g1;
        slot.* = switch (ef.final) {
            '0' => .dec_graphics,
            'B' => .ascii,
            else => slot.*,
        };
        return;
    }
    // DECALN — `ESC # 8` fills the screen with 'E' for an
    // alignment pattern. Used by `vttest`.
    if (ef.n_intermediates == 1 and ef.intermediates[0] == '#' and ef.final == '8') {
        for (self.buf()) |*ln| {
            for (ln.cells) |*cell| cell.* = .{ .rune = 'E', .style_ref = 0, .flags = 0, .reserved = 0 };
            ln.dirty = true;
        }
        self.row = 0;
        self.col = 0;
        self.pending_wrap = false;
        return;
    }
    // DECDHL / DECDWL / DECSWL — per-line scaling.
    //   #3 = double-height top half
    //   #4 = double-height bottom half
    //   #5 = single width / single height (default)
    //   #6 = double-width single height
    if (ef.n_intermediates == 1 and ef.intermediates[0] == '#') {
        const ln = self.line(self.row);
        switch (ef.final) {
            '3' => ln.scaling = .dhl_top,
            '4' => ln.scaling = .dhl_bot,
            '5' => ln.scaling = .single,
            '6' => ln.scaling = .dwl,
            else => {},
        }
        ln.dirty = true;
        return;
    }
    switch (ef.final) {
        '7' => saveCursor(self, ),
        '8' => restoreCursor(self, ),
        'D' => self.lineFeed(),
        'E' => {
            self.lineFeed();
            self.col = 0;
        },
        'H' => {
            // HTS — set tab stop at cursor column.
            if (self.col < self.tab_stops.items.len) self.tab_stops.items[self.col] = true;
        },
        'M' => reverseLineFeed(self, ),
        // SS2 (ESC N) / SS3 (ESC O) — single-shift designate G2/G3
        // for the next printed character. We don't model G2/G3
        // charsets, so the next codepoint passes through as ASCII.
        // Recognising the escape prevents the parser from leaking
        // it into the screen as a print, and `pending_single_shift`
        // is consumed (no-op'd) by the next printCp.
        'N' => self.pending_single_shift = .ss2,
        'O' => self.pending_single_shift = .ss3,
        'Z' => respondDa(self, ), // DECID — identify, same payload as DA1
        'c' => fullReset(self, ),
        '=' => self.app_keypad = true, // DECPAM — application keypad on
        '>' => self.app_keypad = false, // DECPNM — application keypad off
        else => {},
    }
}

pub fn decstr(self: *Screen) void {
    // Soft reset (CSI ! p) — reset modes / scroll region /
    // attributes but keep screen contents.
    self.row = 0;
    self.col = 0;
    self.cur_style = 0;
    self.scroll_top = 0;
    self.scroll_bot = if (self.rows > 0) self.rows - 1 else 0;
    self.autowrap = true;
    self.origin_mode = false;
    self.insert_mode = false;
    self.line_feed_mode = false;
    self.cursor_visible = true;
    self.cursor_shape = .block_blink;
    self.bracketed_paste = false;
    self.focus_reports = false;
    self.app_cursor_keys = false;
    self.app_keypad = false;
    self.mouse_mode = 0;
    self.mouse_sgr = false;
    self.mouse_enc = .legacy;
    self.pending_wrap = false;
    self.pending_single_shift = .none;
    self.charset_g0 = .ascii;
    self.charset_g1 = .ascii;
    self.active_charset = .g0;
    // Per VT520 Programmer Reference, DECSTR resets DECSCNM too.
    // DECCOLM stays as-is (the "allow" flag is sticky per xterm).
    self.reverse_screen = false;
    // Kitty kbd flag stack — clear the active flags but leave the
    // saved stack alone (apps that DECSTR mid-session still expect
    // their previous push state on subsequent CSI <N u).
    self.kitty_kbd_flags = 0;
    if (self.use_alt) toggleAltScreen(self, false);
}

pub fn fullReset(self: *Screen) void {
    for (self.buf()) |*l| l.clear();
    self.row = 0;
    self.col = 0;
    self.cur_style = 0;
    self.scroll_top = 0;
    self.scroll_bot = if (self.rows > 0) self.rows - 1 else 0;
    self.autowrap = true;
    self.origin_mode = false;
    self.pending_wrap = false;
    self.pending_single_shift = .none;
    self.charset_g0 = .ascii;
    self.charset_g1 = .ascii;
    self.active_charset = .g0;
    self.app_cursor_keys = false;
    self.app_keypad = false;
    self.mouse_mode = 0;
    self.mouse_sgr = false;
    self.mouse_enc = .legacy;
    self.bracketed_paste = false;
    self.focus_reports = false;
    self.cursor_visible = true;
    self.cursor_shape = .block_blink;
    self.reverse_screen = false;
    self.kitty_kbd_flags = 0;
    self.kitty_kbd_depth = 0;
    self.last_print_cp = 0;
    self.bell_at_us = 0;
    // OSC 8 link table — drop every URI string. Cells holding
    // link references were just zeroed by `l.clear()` above, so
    // nothing dangles after this drain.
    var link_it = self.links.iterator();
    while (link_it.next()) |entry| self.allocator.free(entry.value_ptr.*);
    self.links.clearRetainingCapacity();
    // Title stack — free each saved title before zeroing the
    // depth. RIS is "factory reset" so the saved-title chain
    // shouldn't survive it.
    for (&self.title_stack) |*entry| {
        if (entry.*) |t| self.allocator.free(t);
        entry.* = null;
    }
    self.title_stack_depth = 0;
    // Active IME preedit — release the buffer; the next IM
    // commit / preedit-changed will allocate fresh.
    if (self.preedit_text) |t| self.allocator.free(t);
    self.preedit_text = null;
    self.clearAllClusters();
    self.resetTabStops() catch |e| std.debug.print("sketerm: resetTabStops failed: {s}\n", .{@errorName(e)});
    // Bring the parser back to ANSI mode if it's in VT52.
    if (self.sink.on_decanm) |f| f(self.sink.ctx, true);
}

// ── Cursor primitives ────────────────────────────────────────

pub fn cursorUp(self: *Screen, n: u32) void {
    // If cursor is inside the scroll region, clamp to scroll_top.
    // Otherwise to absolute row 0 (per xterm/DEC behavior).
    const inside = self.row >= self.scroll_top and self.row <= self.scroll_bot;
    const limit: u16 = if (inside) self.scroll_top else 0;
    const max_dec: u32 = self.row - limit;
    const dec: u16 = @intCast(@min(n, max_dec));
    self.row -= dec;
    self.pending_wrap = false;
}

pub fn cursorDown(self: *Screen, n: u32) void {
    const inside = self.row >= self.scroll_top and self.row <= self.scroll_bot;
    const limit: u16 = if (inside) self.scroll_bot else self.rows - 1;
    const max_dec: u32 = limit - self.row;
    const dec: u16 = @intCast(@min(n, max_dec));
    self.row += dec;
    self.pending_wrap = false;
}

pub fn cursorRight(self: *Screen, n: u32) void {
    const max_dec: u32 = @intCast(self.cols - 1 - self.col);
    const dec: u16 = @intCast(@min(n, max_dec));
    self.col += dec;
    self.pending_wrap = false;
}

pub fn cursorLeft(self: *Screen, n: u32) void {
    const dec: u16 = @intCast(@min(n, @as(u32, self.col)));
    self.col -= dec;
    self.pending_wrap = false;
}

pub fn cursorPos(self: *Screen, r: u32, c: u32) void {
    const r_idx: u16 = if (r == 0) 0 else @intCast(@min(r - 1, @as(u32, self.rows - 1)));
    const c_idx: u16 = if (c == 0) 0 else @intCast(@min(c - 1, @as(u32, self.cols - 1)));
    // Origin-mode constrains within scroll region.
    if (self.origin_mode) {
        self.row = self.scroll_top + r_idx;
        if (self.row > self.scroll_bot) self.row = self.scroll_bot;
    } else {
        self.row = r_idx;
    }
    self.col = c_idx;
    self.pending_wrap = false;
}

pub fn saveCursor(self: *Screen) void {
    self.saved_row = self.row;
    self.saved_col = self.col;
    self.saved_style = self.cur_style;
    self.saved_origin = self.origin_mode;
    self.saved_autowrap = self.autowrap;
    self.saved_charset_g0 = self.charset_g0;
    self.saved_charset_g1 = self.charset_g1;
    self.saved_active_charset = self.active_charset;
    self.saved_link_id = self.current_link_id;
}

pub fn restoreCursor(self: *Screen) void {
    self.row = @min(self.saved_row, if (self.rows > 0) self.rows - 1 else 0);
    self.col = @min(self.saved_col, if (self.cols > 0) self.cols - 1 else 0);
    self.cur_style = self.saved_style;
    self.origin_mode = self.saved_origin;
    self.autowrap = self.saved_autowrap;
    self.charset_g0 = self.saved_charset_g0;
    self.charset_g1 = self.saved_charset_g1;
    self.active_charset = self.saved_active_charset;
    self.current_link_id = self.saved_link_id;
    self.pending_wrap = false;
}

pub fn reverseLineFeed(self: *Screen) void {
    if (self.row == self.scroll_top) {
        scrollDown(self, 1);
    } else if (self.row > 0) {
        self.row -= 1;
    }
    self.pending_wrap = false;
}

// ── Erase ────────────────────────────────────────────────────

pub fn eraseDisplay(self: *Screen, mode: u32) void {
    const lines = self.buf();
    const fill = self.cur_style;
    switch (mode) {
        0 => {
            if (self.clusters.count() > 0) {
                self.clearClustersRange(self.row, self.col, self.cols);
                var r: u16 = self.row + 1;
                while (r < self.rows) : (r += 1) self.clearClustersRange(r, 0, self.cols);
            }
            self.splitWidePair(self.line(self.row), self.col);
            self.line(self.row).eraseRangeStyled(self.col, self.cols, fill);
            var i: u16 = self.row + 1;
            while (i < self.rows) : (i += 1) lines[i].clearStyled(fill);
        },
        1 => {
            if (self.clusters.count() > 0) {
                var r: u16 = 0;
                while (r < self.row) : (r += 1) self.clearClustersRange(r, 0, self.cols);
                self.clearClustersRange(self.row, 0, self.col + 1);
            }
            var i: u16 = 0;
            while (i < self.row) : (i += 1) lines[i].clearStyled(fill);
            self.splitWidePair(self.line(self.row), self.col);
            self.line(self.row).eraseRangeStyled(0, self.col + 1, fill);
        },
        2 => {
            self.clearAllClusters();
            for (lines) |*l| l.clearStyled(fill);
        },
        3 => {
            // Mode 3 (xterm extension): clear screen + scrollback.
            self.clearAllClusters();
            for (lines) |*l| l.clear();
            for (self.scrollback.items) |*l| l.deinit(self.allocator);
            self.scrollback.clearRetainingCapacity();
            // Reset ring head — without this, post-clear pushes
            // wrap from a stale offset and eviction order goes
            // wrong once the ring fills again.
            self.scrollback_head = 0;
            self.view_offset = 0;
        },
        else => {},
    }
}

pub fn eraseLine(self: *Screen, mode: u32) void {
    var ln = self.line(self.row);
    const fill = self.cur_style;
    switch (mode) {
        0 => {
            if (self.clusters.count() > 0) self.clearClustersRange(self.row, self.col, self.cols);
            self.splitWidePair(ln, self.col);
            ln.eraseRangeStyled(self.col, self.cols, fill);
        },
        1 => {
            if (self.clusters.count() > 0) self.clearClustersRange(self.row, 0, self.col + 1);
            self.splitWidePair(ln, self.col);
            ln.eraseRangeStyled(0, self.col + 1, fill);
        },
        2 => {
            if (self.clusters.count() > 0) self.clearClustersRange(self.row, 0, self.cols);
            ln.clearStyled(fill);
        },
        else => {},
    }
}

// ── Scroll ───────────────────────────────────────────────────

pub fn scrollUp(self: *Screen, n: u32) void {
    self.clearAllClusters();
    if (self.scroll_top >= self.scroll_bot) return;
    const region: u16 = self.scroll_bot - self.scroll_top + 1;
    const move: u16 = @intCast(@min(n, @as(u32, region)));
    const lines = self.buf();

    const push_to_sb = !self.use_alt and self.scroll_top == 0;

    if (move < region) {
        // Stash cells, ids, AND continues_above of the rows about
        // to scroll out — they belong to the content, not the
        // array slot. Common case is move=1; use stack scratch
        // up to 8 to avoid the steady-state allocator hit.
        var stash_stack: [8][]Cell = undefined;
        var ids_stack: [8]u64 = undefined;
        var ca_stack: [8]bool = undefined;
        var stash_heap: ?[][]Cell = null;
        var ids_heap: ?[]u64 = null;
        var ca_heap: ?[]bool = null;
        defer if (stash_heap) |h| self.allocator.free(h);
        defer if (ids_heap) |h| self.allocator.free(h);
        defer if (ca_heap) |h| self.allocator.free(h);
        const stash: [][]Cell = if (move <= stash_stack.len) stash_stack[0..move] else blk: {
            const h = self.allocator.alloc([]Cell, move) catch return;
            stash_heap = h;
            break :blk h;
        };
        const stash_ids: []u64 = if (move <= ids_stack.len) ids_stack[0..move] else blk: {
            const h = self.allocator.alloc(u64, move) catch return;
            ids_heap = h;
            break :blk h;
        };
        const stash_ca: []bool = if (move <= ca_stack.len) ca_stack[0..move] else blk: {
            const h = self.allocator.alloc(bool, move) catch return;
            ca_heap = h;
            break :blk h;
        };
        var i: u16 = 0;
        while (i < move) : (i += 1) {
            stash[i] = lines[self.scroll_top + i].cells;
            stash_ids[i] = lines[self.scroll_top + i].id;
            stash_ca[i] = lines[self.scroll_top + i].continues_above;
        }

        if (push_to_sb) {
            // Hand the top-row cells DIRECTLY to scrollback (no
            // dupe). When the ring is full, the evicted oldest
            // cells come back — reuse them as the new bottom-row
            // buffer. Net 0 allocations per scroll in steady state.
            var k: u16 = 0;
            while (k < move) : (k += 1) {
                const top_cells = stash[k];
                if (self.pushScrollbackTakeOld(top_cells, stash_ids[k], stash_ca[k])) |reused| {
                    stash[k] = reused;
                } else {
                    // Pre-cap: scrollback took ownership, alloc
                    // fresh for the new bottom row.
                    const new_buf = self.allocator.alloc(Cell, self.cols) catch break;
                    stash[k] = new_buf;
                }
            }
        }

        // Shift cells + ids up by `move`.
        i = 0;
        while (i + move <= self.scroll_bot - self.scroll_top) : (i += 1) {
            lines[self.scroll_top + i].cells = lines[self.scroll_top + i + move].cells;
            lines[self.scroll_top + i].continues_above = lines[self.scroll_top + i + move].continues_above;
            lines[self.scroll_top + i].id = lines[self.scroll_top + i + move].id;
            lines[self.scroll_top + i].scaling = lines[self.scroll_top + i + move].scaling;
        }
        // The newly-bottom rows get fresh IDs (new content arriving).
        i = 0;
        while (i < move) : (i += 1) {
            const dst = self.scroll_bot - move + 1 + i;
            lines[dst].cells = stash[i];
            @memset(lines[dst].cells, .{});
            lines[dst].continues_above = false;
            lines[dst].id = self.nextLineId();
            lines[dst].scaling = .single;
        }
    } else {
        // Whole region scrolled; everything goes to scrollback (or
        // is dropped, on alt screen).
        if (push_to_sb) {
            // Same swap-buffer trick: hand cells to scrollback,
            // reuse evicted (or alloc fresh) for the now-blank row.
            var k: u16 = 0;
            while (k < region) : (k += 1) {
                const idx = self.scroll_top + k;
                const old_cells = lines[idx].cells;
                const old_id = lines[idx].id;
                const old_ca = lines[idx].continues_above;
                if (self.pushScrollbackTakeOld(old_cells, old_id, old_ca)) |reused| {
                    lines[idx].cells = reused;
                } else {
                    const new_buf = self.allocator.alloc(Cell, self.cols) catch break;
                    lines[idx].cells = new_buf;
                }
            }
        }
        var i: u16 = self.scroll_top;
        while (i <= self.scroll_bot) : (i += 1) {
            @memset(lines[i].cells, .{});
            lines[i].continues_above = false;
            lines[i].id = self.nextLineId();
            lines[i].scaling = .single;
        }
    }
    var i: u16 = self.scroll_top;
    while (i <= self.scroll_bot) : (i += 1) lines[i].dirty = true;
}

pub fn scrollDown(self: *Screen, n: u32) void {
    self.clearAllClusters();
    if (self.scroll_top >= self.scroll_bot) return;
    const region: u16 = self.scroll_bot - self.scroll_top + 1;
    const move: u16 = @intCast(@min(n, @as(u32, region)));
    const lines = self.buf();

    if (move < region) {
        // move=1 is the steady-state RI path; stack scratch up to
        // 8 covers ~all real moves. Heap fallback for larger.
        var stash_stack: [8][]Cell = undefined;
        var stash_heap: ?[][]Cell = null;
        defer if (stash_heap) |h| self.allocator.free(h);
        const stash: [][]Cell = if (move <= stash_stack.len) stash_stack[0..move] else blk: {
            const h = self.allocator.alloc([]Cell, move) catch return;
            stash_heap = h;
            break :blk h;
        };
        var i: u16 = 0;
        while (i < move) : (i += 1) stash[i] = lines[self.scroll_bot - move + 1 + i].cells;
        // Shift cells + ids down (iterate top-to-bottom in reverse
        // to avoid overwriting before reading).
        var j: u16 = 0;
        const inner_count: u16 = self.scroll_bot - self.scroll_top + 1 - move;
        while (j < inner_count) : (j += 1) {
            const src = self.scroll_bot - move - j;
            const dst = self.scroll_bot - j;
            lines[dst].cells = lines[src].cells;
            lines[dst].continues_above = lines[src].continues_above;
            lines[dst].id = lines[src].id;
            lines[dst].scaling = lines[src].scaling;
        }
        i = 0;
        while (i < move) : (i += 1) {
            lines[self.scroll_top + i].cells = stash[i];
            @memset(lines[self.scroll_top + i].cells, .{});
            lines[self.scroll_top + i].continues_above = false;
            lines[self.scroll_top + i].id = self.nextLineId();
            lines[self.scroll_top + i].scaling = .single;
        }
    } else {
        var i: u16 = self.scroll_top;
        while (i <= self.scroll_bot) : (i += 1) {
            @memset(lines[i].cells, .{});
            lines[i].continues_above = false;
            lines[i].id = self.nextLineId();
            lines[i].scaling = .single;
        }
    }
    var i: u16 = self.scroll_top;
    while (i <= self.scroll_bot) : (i += 1) lines[i].dirty = true;
}

pub fn insertChars(self: *Screen, n: u32) void {
    var ln = self.line(self.row);
    const cells = ln.cells;
    const col = self.col;
    if (col >= cells.len) return;
    const max_n: u32 = @intCast(cells.len - col);
    const move: u16 = @intCast(@min(n, max_n));
    if (move == 0) return;
    // Shifted cells change column; clusters are keyed by (row, col)
    // and would point at the wrong cells afterwards.
    if (self.clusters.count() > 0) self.clearClustersRange(self.row, col, self.cols);
    // A wide pair straddling the insertion point gets torn apart.
    self.splitWidePair(ln, col);
    // Shift cells right from col by `move`. Last cells fall off.
    var i: usize = cells.len;
    while (i > col + move) : (i -= 1) {
        cells[i - 1] = cells[i - 1 - move];
    }
    // Clear the inserted cells.
    var k: u16 = 0;
    while (k < move) : (k += 1) cells[col + k] = .{};
    ln.dirty = true;
}

pub fn deleteChars(self: *Screen, n: u32) void {
    var ln = self.line(self.row);
    const cells = ln.cells;
    const col = self.col;
    if (col >= cells.len) return;
    const max_n: u32 = @intCast(cells.len - col);
    const move: u16 = @intCast(@min(n, max_n));
    if (move == 0) return;
    // Shifted cells change column; clusters are keyed by (row, col)
    // and would point at the wrong cells afterwards.
    if (self.clusters.count() > 0) self.clearClustersRange(self.row, col, self.cols);
    // Wide pairs straddling either edge of the deleted range get
    // torn apart — blank both halves before shifting.
    self.splitWidePair(ln, col);
    self.splitWidePair(ln, col + move - 1);
    // Shift cells left from col+move into col. Last cells become blank.
    var i: usize = col;
    while (i + move < cells.len) : (i += 1) {
        cells[i] = cells[i + move];
    }
    while (i < cells.len) : (i += 1) cells[i] = .{};
    ln.dirty = true;
}

pub fn insertLines(self: *Screen, n: u32) void {
    if (self.row < self.scroll_top or self.row > self.scroll_bot) return;
    const old_top = self.scroll_top;
    self.scroll_top = self.row;
    defer self.scroll_top = old_top;
    scrollDown(self, n);
}

pub fn deleteLines(self: *Screen, n: u32) void {
    if (self.row < self.scroll_top or self.row > self.scroll_bot) return;
    const old_top = self.scroll_top;
    self.scroll_top = self.row;
    defer self.scroll_top = old_top;
    scrollUp(self, n);
}

pub fn setScrollRegion(self: *Screen, params: Event.Csi) void {
    const top = params.paramOrDefault(0, 1);
    const bot = params.paramOrDefault(1, self.rows);
    const t: u16 = if (top == 0) 0 else @intCast(@min(top - 1, @as(u32, self.rows - 1)));
    const b: u16 = if (bot == 0) self.rows - 1 else @intCast(@min(bot - 1, @as(u32, self.rows - 1)));
    if (t < b) {
        self.scroll_top = t;
        self.scroll_bot = b;
        // After DECSTBM, cursor goes to top-left (or origin if set).
        if (self.origin_mode) {
            self.row = self.scroll_top;
        } else {
            self.row = 0;
        }
        self.col = 0;
        self.pending_wrap = false;
    }
}

// ── Modes ────────────────────────────────────────────────────

pub fn modeSet(self: *Screen, params: Event.Csi, set: bool) void {
    var i: usize = 0;
    while (i < params.n_params) : (i += 1) {
        switch (params.params[i]) {
            1 => self.app_cursor_keys = set,
            2 => {
                // DECANM — set=ANSI/VT100, reset=VT52. Forward
                // to the parser via the sink so the byte stream
                // following this sequence is parsed correctly.
                if (self.sink.on_decanm) |f| f(self.sink.ctx, set);
            },
            3 => {
                // DECCOLM — switch column count when explicitly
                // enabled via DECSET 40. Side effects per spec:
                // clear screen, home cursor, reset margins.
                if (self.allow_decolm) {
                    const new_cols: u16 = if (set) 132 else 80;
                    if (new_cols != self.cols) {
                        self.resize(new_cols, self.rows) catch return;
                    }
                    self.scroll_top = 0;
                    self.scroll_bot = if (self.rows > 0) self.rows - 1 else 0;
                    self.row = 0;
                    self.col = 0;
                    self.pending_wrap = false;
                    for (self.buf()) |*l| l.clear();
                    self.dirty = true;
                }
            },
            5 => {
                // DECSCNM — reverse video mode (whole screen).
                self.reverse_screen = set;
                self.dirty = true;
            },
            6 => {
                self.origin_mode = set;
                self.row = if (set and self.origin_mode) self.scroll_top else 0;
                self.col = 0;
                self.pending_wrap = false;
            },
            7 => self.autowrap = set,
            40 => self.allow_decolm = set,
            25 => self.cursor_visible = set,
            1000 => self.mouse_mode = if (set) 1000 else 0,
            1002 => self.mouse_mode = if (set) 1002 else 0,
            1003 => self.mouse_mode = if (set) 1003 else 0,
            1004 => self.focus_reports = set,
            2026 => {
                // Synchronized output mode (kitty/wezterm/iTerm2).
                // Setting on: app begins a multi-step update that
                // shouldn't be displayed mid-state. Reset: flush.
                self.sync_output = set;
                if (!set) self.dirty = true;
            },
            1005 => self.mouse_enc = if (set) .utf8 else .legacy,
            1006 => {
                self.mouse_sgr = set;
                self.mouse_enc = if (set) .sgr else .legacy;
            },
            1015 => self.mouse_enc = if (set) .urxvt else .legacy,
            1016 => self.mouse_enc = if (set) .sgr_pixel else .legacy,
            47, 1047 => toggleAltScreen(self, set),
            1049 => {
                // 1049 = save cursor + switch alt + clear alt on
                // set; restore cursor + switch main on reset.
                if (set and !self.use_alt) saveCursor(self, );
                toggleAltScreen(self, set);
                if (set) {
                    self.row = 0;
                    self.col = 0;
                    self.pending_wrap = false;
                } else {
                    restoreCursor(self, );
                }
            },
            2004 => self.bracketed_paste = set,
            // Mode 2027 (grapheme clustering): our cluster
            // handling is always on and not disableable — accept
            // silently; DECRQM reports "permanently set".
            2027 => {},
            2031 => self.mode_2031 = set,
            2048 => {
                // In-band resize: spec requires an immediate
                // report on enabling so the app learns the
                // current geometry without a race.
                self.in_band_resize = set;
                if (set) sendResizeReport(self, );
            },
            else => {},
        }
    }
}

/// Mode 2048 report: `CSI 48 ; rows ; cols ; height_px ; width_px t`.
/// Pixel fields are 0 when cell metrics are unknown (spec allows
/// it; lying with a fake cell size would mislead image layout).
pub fn sendResizeReport(self: *Screen) void {
    var out_buf: [48]u8 = undefined;
    const hpx: u32 = @as(u32, self.rows) * self.cell_pixel_h;
    const wpx: u32 = @as(u32, self.cols) * self.cell_pixel_w;
    const s = std.fmt.bufPrint(&out_buf, "\x1b[48;{d};{d};{d};{d}t", .{ self.rows, self.cols, hpx, wpx }) catch return;
    respond(self, s);
}

/// Push a color-scheme update from the GUI (bg luminance). Emits
/// the mode-2031 report when the scheme actually flipped and the
/// app subscribed. GUI-owned — bypasses the mirror mute.
pub fn notifyColorScheme(self: *Screen, dark: bool) void {
    const changed = self.color_scheme_dark != dark;
    self.color_scheme_dark = dark;
    if (!changed or !self.mode_2031) return;
    respondForce(self, if (dark) "\x1b[?997;1n" else "\x1b[?997;2n");
}

pub fn toggleAltScreen(self: *Screen, on: bool) void {
    if (on == self.use_alt) return;
    // Clusters are keyed by (row, col) in the ACTIVE buffer; after
    // the swap every key points at the other buffer's content.
    // Same for the last-print cell used for cluster attachment.
    self.clearAllClusters();
    self.last_print_cp = 0;
    if (on and self.alt == null) {
        const alt = self.allocator.alloc(Line, self.rows) catch return;
        var i: u16 = 0;
        errdefer {
            for (alt[0..i]) |*l| l.deinit(self.allocator);
            self.allocator.free(alt);
        }
        while (i < self.rows) : (i += 1) {
            alt[i] = Line.init(self.allocator, self.cols) catch return;
            alt[i].id = self.nextLineId();
        }
        self.alt = alt;
    }
    if (on) {
        self.use_alt = true;
        for (self.alt.?) |*l| {
            l.clear();
            l.id = self.nextLineId();
        }
    } else {
        self.use_alt = false;
    }
    // Selection coordinates reference the previous buffer — they
    // make no sense after the swap, so wipe them.
    self.selection.clear();
    // Always mark all lines dirty when switching.
    for (self.buf()) |*l| l.dirty = true;
    self.dirty = true;
}

// ── SGR ──────────────────────────────────────────────────────

/// Read three consecutive params starting at `start` as a 0-255-clamped
/// RGB triple. Returns null if the params slice doesn't have enough
/// entries (i.e. `start + 2 >= n_params`).
pub fn sgrReadRgb(params: *const Event.Csi, start: usize) ?struct { r: u8, g: u8, b: u8 } {
    if (start + 2 >= params.n_params) return null;
    return .{
        .r = @intCast(@min(params.params[start], 255)),
        .g = @intCast(@min(params.params[start + 1], 255)),
        .b = @intCast(@min(params.params[start + 2], 255)),
    };
}

/// Parse the extended-colour payload following SGR 38/48/58 at
/// index `i`. Handles `;5;n` / `:5:n` (palette), `;2;r;g;b` /
/// `:2:r:g:b` (truecolor) AND the ITU colon form with a colorspace
/// slot `:2::r:g:b` (what neovim/kitty emit). Returns the colour
/// plus how many params past `i` were consumed.
pub fn sgrReadExtColor(params: *const Event.Csi, i: usize) ?struct { color: @import("style_pool.zig").Color, skip: usize } {
    if (i + 1 >= params.n_params) return null;
    switch (params.params[i + 1]) {
        5 => {
            if (i + 2 >= params.n_params) return null;
            return .{
                .color = .{ .palette = @intCast(@min(params.params[i + 2], 255)) },
                .skip = 2,
            };
        },
        2 => {
            // Colon form with colorspace: detect by the colour
            // payload extending to a 4th trailing SUB param
            // (38:2::r:g:b → i+1..i+5 all sub). Legacy semicolon
            // and bare colon forms put r at i+2.
            const base: usize = if (params.isSub(i + 1) and i + 5 < params.n_params and params.isSub(i + 5))
                i + 3
            else
                i + 2;
            const rgb = sgrReadRgb(params, base) orelse return null;
            return .{
                .color = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
                .skip = base + 2 - i,
            };
        },
        else => return null,
    }
}

pub fn sgr(self: *Screen, params: Event.Csi) void {
    var entry = self.pool.get(self.cur_style);
    var i: usize = 0;
    while (i < params.n_params or (params.n_params == 0 and i == 0)) : (i += 1) {
        const p = if (params.n_params == 0) 0 else params.params[i];
        switch (p) {
            0 => entry = .{},
            1 => entry.attrs.bold = true,
            2 => entry.attrs.dim = true,
            3 => entry.attrs.italic = true,
            4 => {
                // `4` alone or `4;N` → plain underline.
                // `4:0` → no underline; `4:1` → straight; `4:2`
                // → double; `4:3` → curly; `4:4` → dotted; `4:5`
                // → dashed. Sub-param-aware, kitty/iTerm2 spec.
                if (i + 1 < params.n_params and params.isSub(i + 1)) {
                    const style = params.params[i + 1];
                    switch (style) {
                        0 => {
                            entry.attrs.underline = false;
                            entry.attrs.double_underline = false;
                            entry.attrs.curly_underline = false;
                        },
                        1 => entry.attrs.underline = true,
                        2 => entry.attrs.double_underline = true,
                        3 => entry.attrs.curly_underline = true,
                        // 4/5 (dotted/dashed) — fold into curly for now;
                        // we have no separate flag.
                        4, 5 => entry.attrs.curly_underline = true,
                        else => entry.attrs.underline = true,
                    }
                    i += 1;
                } else {
                    entry.attrs.underline = true;
                }
            },
            5 => entry.attrs.blink = true,
            6 => entry.attrs.fast_blink = true,
            7 => entry.attrs.reverse = true,
            8 => entry.attrs.invisible = true,
            9 => entry.attrs.strikethrough = true,
            21 => entry.attrs.double_underline = true,
            22 => {
                entry.attrs.bold = false;
                entry.attrs.dim = false;
            },
            23 => entry.attrs.italic = false,
            24 => {
                entry.attrs.underline = false;
                entry.attrs.double_underline = false;
                entry.attrs.curly_underline = false;
            },
            25 => {
                entry.attrs.blink = false;
                entry.attrs.fast_blink = false;
            },
            27 => entry.attrs.reverse = false,
            28 => entry.attrs.invisible = false,
            29 => entry.attrs.strikethrough = false,
            30...37 => entry.fg = .{ .palette = @intCast(p - 30) },
            38 => {
                if (sgrReadExtColor(&params, i)) |ext| {
                    entry.fg = ext.color;
                    i += ext.skip;
                }
            },
            39 => entry.fg = .default,
            40...47 => entry.bg = .{ .palette = @intCast(p - 40) },
            48 => {
                if (sgrReadExtColor(&params, i)) |ext| {
                    entry.bg = ext.color;
                    i += ext.skip;
                }
            },
            49 => entry.bg = .default,
            53 => entry.attrs.overline = true,
            55 => entry.attrs.overline = false,
            // SGR 58/59 — underline (decoration) colour, used by
            // editors for spell/diagnostic squiggles.
            58 => {
                if (sgrReadExtColor(&params, i)) |ext| {
                    entry.underline_color = ext.color;
                    i += ext.skip;
                }
            },
            59 => entry.underline_color = .default,
            90...97 => entry.fg = .{ .palette = @intCast(p - 90 + 8) },
            100...107 => entry.bg = .{ .palette = @intCast(p - 100 + 8) },
            else => {},
        }
        if (params.n_params == 0) break; // CSI m alone = reset
    }
    self.cur_style = self.pool.intern(entry) catch blk: {
        // Pool exhausted (65535 distinct styles). Without this,
        // intern silently returns the OLD cur_style, so a fresh
        // `\e[2m` (or any new SGR combo) renders with the wrong
        // (often brighter, non-dim) style and stale styling
        // persists — the "ghost text too bright / remains" bug in
        // long truecolor TUI sessions. Garbage-collect the styles
        // no live cell references, then retry once.
        compactStylePool(self, );
        break :blk self.pool.intern(entry) catch self.cur_style;
    };
}

/// Garbage-collect the interned style pool. Walks every live cell
/// (active + alt + scrollback) plus `cur_style` / `saved_style`,
/// keeps only the referenced entries (entry 0 / default always
/// survives at slot 0), and rewrites every `style_ref` to the
/// compacted indices. No-op if it can't allocate scratch or if
/// every entry is still live (genuinely 64K distinct styles on
/// screen — pathological, nothing to reclaim).
pub fn compactStylePool(self: *Screen) void {
    const pool = self.pool;
    const old_len = pool.entries.items.len;
    if (old_len == 0) return;

    const used = self.allocator.alloc(bool, old_len) catch return;
    defer self.allocator.free(used);
    @memset(used, false);
    used[0] = true; // default entry must survive

    const markRef = struct {
        fn f(u: []bool, ref: u16) void {
            if (ref < u.len) u[ref] = true;
        }
    }.f;

    markRef(used, self.cur_style);
    markRef(used, self.saved_style);
    for (self.active) |ln| {
        for (ln.cells) |cell| markRef(used, cell.style_ref);
    }
    if (self.alt) |alt| {
        for (alt) |ln| {
            for (ln.cells) |cell| markRef(used, cell.style_ref);
        }
    }
    for (self.scrollback.items) |ln| {
        for (ln.cells) |cell| markRef(used, cell.style_ref);
    }

    const remap = self.allocator.alloc(u16, old_len) catch return;
    defer self.allocator.free(remap);
    @memset(remap, Pool.unused_index);

    var new_entries: std.ArrayList(Entry) = .empty;
    errdefer new_entries.deinit(self.allocator);
    var i: usize = 0;
    while (i < old_len) : (i += 1) {
        if (!used[i]) continue;
        remap[i] = @intCast(new_entries.items.len);
        new_entries.append(self.allocator, pool.entries.items[i]) catch {
            new_entries.deinit(self.allocator);
            return;
        };
    }

    // Everything still referenced — compaction reclaims nothing,
    // so don't churn the buffers (and don't leak new_entries).
    if (new_entries.items.len == old_len) {
        new_entries.deinit(self.allocator);
        return;
    }

    const remapRef = struct {
        fn f(r: []const u16, ref: u16) u16 {
            if (ref >= r.len) return 0;
            const n = r[ref];
            return if (n == Pool.unused_index) 0 else n;
        }
    }.f;

    self.cur_style = remapRef(remap, self.cur_style);
    self.saved_style = remapRef(remap, self.saved_style);
    for (self.active) |ln| {
        for (ln.cells) |*cell| cell.style_ref = remapRef(remap, cell.style_ref);
    }
    if (self.alt) |alt| {
        for (alt) |ln| {
            for (ln.cells) |*cell| cell.style_ref = remapRef(remap, cell.style_ref);
        }
    }
    for (self.scrollback.items) |ln| {
        for (ln.cells) |*cell| cell.style_ref = remapRef(remap, cell.style_ref);
    }

    pool.replaceEntries(new_entries);

    // Cell contents shifted style indices — force a full redraw.
    for (self.active) |*l| l.dirty = true;
    if (self.alt) |alt| for (alt) |*l| {
        l.dirty = true;
    };
    self.dirty = true;
}
