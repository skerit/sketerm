//! Screen snapshot (de)serialization for mux attach.
//!
//! Lossless binary dump of the terminal state a reattaching client
//! needs: grid (active + alt + scrollback), style pool, hyperlinks,
//! grapheme clusters, cursor, modes, palette, title. Versioned and
//! little-endian like wire.zig.
//!
//! v2: image placements retained by the daemon's Screen
//! (`retain_images`) ride along, so reattach restores images.
//! v4: OSC 133 command state (open C marker, last zone, exit code,
//! completion sequence), so command waits survive resyncs.
//! v6: a format byte per glossary entry (glyf vs colrv0). A v5 peer
//! gets glyf entries only — its tail has no format field, so colrv0
//! payloads would be misread as glyf records.
//! v7: no field changes — it marks colrv1 support. A v6 peer's
//! `Format` enum has no tag 2, so its restore would reject the whole
//! snapshot; colrv1 entries are withheld from v6 bodies instead.
//! v9: a second trailing block carries the rest of the persistent,
//! app-driven state: the completed OSC 133 zone ring, the Kitty
//! placeholder assembly + auto-increment context, virtual placements,
//! OSC 17/19 selection colors and the OSC 1337 user variables. v1-v8
//! bodies restore those to Screen.init defaults: no completed zones, no
//! placeholder context, no virtual placements, unset selection colors
//! and an empty variable store.
//! v8: a trailing interpreter-state block carries DECSC/DECRC state,
//! charsets, single shift, tab stops, UTF-8/REP context, title stack,
//! omitted terminal modes, keyboard stacks, and the prompt-ring head.
//! v1-v7 bodies restore those fields to Screen.init defaults: cursor
//! save at 0,0 with default style/modes/charsets and no link; ASCII G0,
//! no single shift, default 8-column tabs, empty decoder/REP/title and
//! keyboard stacks, normal video, DECCOLM disabled, and a prompt head
//! derived from the serialized mark count (zero when the ring is full).

const std = @import("std");
const grid = @import("../grid/screen.zig");
const Screen = grid.Screen;
const Line = @import("../grid/line.zig").Line;
const Cell = @import("../grid/cell.zig").Cell;
const style_pool = @import("../grid/style_pool.zig");
const wire = @import("wire.zig");
const Pool = style_pool.Pool;

pub const SNAPSHOT_VERSION = 9;
pub const LEGACY_SNAPSHOT_VERSION = 3;

/// What a `Screen` field means to a snapshot.
const FieldClass = enum {
    /// Written by `serializeVersion` and read back by `restoreStaged`.
    carried,
    /// Off the wire on purpose, because restore reconstructs it from
    /// carried data or the restoring process owns it outright.
    derived,
    /// Off the wire on purpose, because it belongs to one viewer, one
    /// process or one frame and would be wrong if it crossed the socket.
    transient,
};

/// The declaring home for "which `Screen` fields survive a reattach".
///
/// `serializeVersion`, `restoreStaged` and the test comparator each
/// hand-enumerate a subset of a 130-field struct, and twice now
/// persistent app-driven state was added to `Screen` and silently
/// dropped on every attach because nothing tied those three lists to
/// the struct.
///
/// What the comptime gate below actually proves is NAME membership in
/// both directions: a new `Screen` field with no entry here fails the
/// build, and an entry naming a field that no longer exists fails too.
/// It does NOT prove that a `.carried` field is serialized — nothing
/// checks that `serializeVersion`/`restoreStaged` touch it, so a field
/// classified `.carried` and then forgotten in those two functions
/// still compiles and still drops on every attach. The gate forces the
/// AUTHOR to make the call; the round trip is on the tests.
const field_policy = [_]struct { name: []const u8, class: FieldClass }{
    // Grid geometry and contents.
    .{ .name = "cols", .class = .carried },
    .{ .name = "rows", .class = .carried },
    .{ .name = "active", .class = .carried },
    .{ .name = "alt", .class = .carried },
    .{ .name = "use_alt", .class = .carried },
    .{ .name = "scrollback", .class = .carried },
    // Scrollback is re-linearized on restore; its cap and the viewport
    // are the viewer's own policy, not the session's state.
    .{ .name = "scrollback_head", .class = .derived },
    .{ .name = "scrollback_capacity", .class = .transient },
    .{ .name = "view_offset", .class = .transient },
    .{ .name = "scroll_on_output", .class = .transient },
    .{ .name = "track_activity", .class = .transient },
    .{ .name = "word_chars", .class = .transient },
    // Child lifetime is reported by wire frames, never by a snapshot.
    .{ .name = "child_exited", .class = .transient },
    .{ .name = "child_exit_status", .class = .transient },

    // Cursor, saved cursor, scroll region.
    .{ .name = "row", .class = .carried },
    .{ .name = "col", .class = .carried },
    .{ .name = "saved_row", .class = .carried },
    .{ .name = "saved_col", .class = .carried },
    .{ .name = "saved_style", .class = .carried },
    .{ .name = "saved_origin", .class = .carried },
    .{ .name = "saved_autowrap", .class = .carried },
    .{ .name = "saved_charset_g0", .class = .carried },
    .{ .name = "saved_charset_g1", .class = .carried },
    .{ .name = "saved_active_charset", .class = .carried },
    .{ .name = "saved_link_id", .class = .carried },
    .{ .name = "cur_style", .class = .carried },
    .{ .name = "scroll_top", .class = .carried },
    .{ .name = "scroll_bot", .class = .carried },

    // Modes.
    .{ .name = "autowrap", .class = .carried },
    .{ .name = "origin_mode", .class = .carried },
    .{ .name = "insert_mode", .class = .carried },
    .{ .name = "bracketed_paste", .class = .carried },
    // Config policy and per-process role flags: the daemon's answer is
    // not the viewer's answer.
    .{ .name = "allow_clipboard_read", .class = .transient },
    .{ .name = "mode_2031", .class = .carried },
    .{ .name = "in_band_resize", .class = .carried },
    .{ .name = "color_scheme_dark", .class = .transient },
    .{ .name = "mute_responses", .class = .transient },
    .{ .name = "defer_gui_queries", .class = .transient },
    .{ .name = "line_feed_mode", .class = .carried },

    // Titles.
    .{ .name = "title_stack", .class = .carried },
    .{ .name = "title_stack_depth", .class = .carried },
    .{ .name = "last_title", .class = .carried },
    // Font identity and cell metrics come from the viewer's renderer.
    .{ .name = "font_name", .class = .transient },
    .{ .name = "cell_pixel_w", .class = .transient },
    .{ .name = "cell_pixel_h", .class = .transient },

    .{ .name = "focus_reports", .class = .carried },
    .{ .name = "app_cursor_keys", .class = .carried },
    .{ .name = "app_keypad", .class = .carried },
    .{ .name = "cursor_visible", .class = .carried },
    .{ .name = "cursor_shape", .class = .carried },
    // Blink phase and the trail epoch are render state; restore bumps
    // the epoch itself so the trail teleports instead of smearing.
    .{ .name = "cursor_blink_on", .class = .transient },
    .{ .name = "viewport_epoch", .class = .derived },
    .{ .name = "mouse_mode", .class = .carried },
    .{ .name = "mouse_sgr", .class = .carried },
    .{ .name = "mouse_enc", .class = .carried },
    .{ .name = "pending_single_shift", .class = .carried },
    .{ .name = "sync_output", .class = .carried },
    .{ .name = "pending_wrap", .class = .carried },
    .{ .name = "decoder", .class = .carried },
    .{ .name = "dirty", .class = .derived },

    // Overlays owned by the viewer's Window / Terminal.
    .{ .name = "selection", .class = .transient },
    .{ .name = "copy_cursor", .class = .transient },
    .{ .name = "search_highlights", .class = .transient },
    .{ .name = "search_active_idx", .class = .transient },
    .{ .name = "hints_overlay", .class = .transient },
    .{ .name = "predictions_overlay", .class = .transient },

    // Image retention: the flag is the daemon's role, the list is the
    // payload, the byte count is recomputed while restoring it.
    .{ .name = "retain_images", .class = .transient },
    .{ .name = "retained_images", .class = .carried },
    .{ .name = "retained_image_bytes", .class = .derived },

    .{ .name = "pool", .class = .derived },
    .{ .name = "allocator", .class = .derived },

    .{ .name = "current_link_id", .class = .carried },
    .{ .name = "next_link_id", .class = .carried },
    .{ .name = "links", .class = .carried },
    // IME preedit and the bell timestamp belong to the local frame.
    .{ .name = "preedit_text", .class = .transient },
    .{ .name = "bell_at_us", .class = .transient },

    .{ .name = "last_print_cp", .class = .carried },
    .{ .name = "last_print_key", .class = .carried },
    .{ .name = "clusters", .class = .carried },
    // The image store is deliberately not carried: the pixels dwarf the
    // rest of the body. Post-attach transmissions repopulate it, and
    // pre-attach placements ride `retained_images` instead.
    .{ .name = "kitty_images", .class = .transient },
    .{ .name = "glyphs", .class = .carried },
    .{ .name = "virtual_placements", .class = .carried },
    .{ .name = "ph_pending", .class = .carried },
    .{ .name = "ph_last", .class = .carried },

    .{ .name = "default_fg", .class = .carried },
    .{ .name = "default_bg", .class = .carried },
    .{ .name = "cursor_color", .class = .carried },
    // OSC 110/111 reset to the VIEWER's configured colors; carrying the
    // daemon's would overwrite the user's theme on every attach.
    .{ .name = "configured_fg", .class = .transient },
    .{ .name = "configured_bg", .class = .transient },
    .{ .name = "selection_bg", .class = .carried },
    .{ .name = "selection_fg", .class = .carried },
    .{ .name = "user_vars", .class = .carried },
    .{ .name = "palette", .class = .carried },

    .{ .name = "next_line_id", .class = .carried },
    .{ .name = "prompt_marks", .class = .carried },
    .{ .name = "prompt_marks_len", .class = .carried },
    .{ .name = "prompt_marks_head", .class = .carried },
    .{ .name = "pending_output_start_id", .class = .carried },
    .{ .name = "pending_output_awaits_nl", .class = .carried },
    .{ .name = "last_output_start_id", .class = .carried },
    .{ .name = "last_output_end_id", .class = .carried },
    .{ .name = "last_cmd_exit", .class = .carried },
    .{ .name = "cmd_completion_seq", .class = .carried },
    .{ .name = "cmd_zones", .class = .carried },
    .{ .name = "cmd_zones_len", .class = .carried },
    .{ .name = "cmd_zones_head", .class = .carried },

    // OSC 99 accumulator: a half-received notification is dropped by
    // design, exactly as a different identifier drops it live.
    .{ .name = "notify_id", .class = .transient },
    .{ .name = "notify_id_len", .class = .transient },
    .{ .name = "notify_title", .class = .transient },
    .{ .name = "notify_body", .class = .transient },
    .{ .name = "notify_buttons", .class = .transient },
    .{ .name = "notify_icon_data", .class = .transient },
    .{ .name = "notify_icon_name", .class = .transient },
    .{ .name = "notify_urgency", .class = .transient },
    .{ .name = "notify_report", .class = .transient },
    .{ .name = "notify_focus", .class = .transient },
    .{ .name = "notify_occasion", .class = .transient },

    .{ .name = "modify_other_keys", .class = .carried },
    .{ .name = "reverse_screen", .class = .carried },
    .{ .name = "allow_decolm", .class = .carried },
    .{ .name = "kitty_kbd_flags", .class = .carried },
    .{ .name = "kitty_kbd_stack", .class = .carried },
    .{ .name = "kitty_kbd_depth", .class = .carried },
    .{ .name = "kitty_kbd_other_flags", .class = .carried },
    .{ .name = "kitty_kbd_other_stack", .class = .carried },
    .{ .name = "kitty_kbd_other_depth", .class = .carried },
    .{ .name = "tab_stops", .class = .carried },
    .{ .name = "charset_g0", .class = .carried },
    .{ .name = "charset_g1", .class = .carried },
    .{ .name = "active_charset", .class = .carried },

    // Callbacks into the hosting process.
    .{ .name = "sink", .class = .transient },
};

comptime {
    @setEvalBranchQuota(200_000);
    for (std.meta.fields(Screen)) |f| {
        var classified = false;
        for (field_policy) |p| {
            if (std.mem.eql(u8, p.name, f.name)) classified = true;
        }
        if (!classified) @compileError("Screen." ++ f.name ++ " is not classified in snapshot.zig field_policy:" ++
            " add it as .carried (and extend serializeVersion, restoreStaged and expectScreensEqual)," ++
            " .derived, or .transient");
    }
    for (field_policy) |p| {
        var exists = false;
        for (std.meta.fields(Screen)) |f| {
            if (std.mem.eql(u8, p.name, f.name)) exists = true;
        }
        if (!exists) @compileError("snapshot.zig field_policy classifies Screen." ++ p.name ++ ", which no longer exists");
    }
}

/// v5: byte budget for the Glyph Protocol glossary tail. Newest
/// registrations win when the lot would overflow (same policy as
/// `RETAIN_IMAGE_BUDGET` for image payloads). Worst case is 1024
/// slots x 64 KiB = 64 MiB, which no attach frame should carry.
pub const GLYPH_SNAPSHOT_BUDGET: usize = 8 * 1024 * 1024;

/// Select a snapshot body for a negotiated or historical core profile.
pub fn negotiateVersion(proto: u32, advertised_max: u8, negotiated: bool) u8 {
    if (proto == 0) return 0;
    if (negotiated) return @min(advertised_max, SNAPSHOT_VERSION);
    return if (proto >= 6) SNAPSHOT_VERSION else LEGACY_SNAPSHOT_VERSION;
}

/// Fixed-size OSC 133 state appended to every v4 snapshot.
const V4_COMMAND_TAIL_LEN: usize = 8 + 1 + 8 + 8 + 4 + 8;

const Sink = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn int(self: Sink, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try self.out.appendSlice(self.allocator, &tmp);
    }

    fn byte(self: Sink, b: u8) !void {
        try self.out.append(self.allocator, b);
    }

    fn boolean(self: Sink, b: bool) !void {
        try self.byte(if (b) 1 else 0);
    }

    fn bytes(self: Sink, b: []const u8) !void {
        try self.int(u32, @intCast(b.len));
        try self.out.appendSlice(self.allocator, b);
    }

    fn color(self: Sink, col: style_pool.Color) !void {
        switch (col) {
            .default => try self.byte(0),
            .palette => |p| {
                try self.byte(1);
                try self.byte(p);
            },
            .rgb => |r| {
                try self.byte(2);
                try self.byte(r.r);
                try self.byte(r.g);
                try self.byte(r.b);
            },
        }
    }

    fn f32x4(self: Sink, v: [4]f32) !void {
        for (v) |x| try self.int(u32, @bitCast(x));
    }

    fn line(self: Sink, ln: *const Line) !void {
        try self.int(u64, ln.id);
        try self.boolean(ln.continues_above);
        try self.byte(@intFromEnum(ln.scaling));
        try self.int(u16, @intCast(ln.cells.len));
        try self.out.appendSlice(self.allocator, std.mem.sliceAsBytes(ln.cells));
    }
};

/// Serialize `screen` (+ its pool) into `out`.
pub fn serialize(screen: *const Screen, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    return serializeVersion(screen, out, allocator, SNAPSHOT_VERSION);
}

/// Serialize a retained historical snapshot body for an older peer.
pub fn serializeVersion(screen: *const Screen, out: *std.ArrayList(u8), allocator: std.mem.Allocator, version: u32) !void {
    if (version < 1 or version > SNAPSHOT_VERSION)
        return error.UnsupportedSnapshotVersion;
    const s = Sink{ .out = out, .allocator = allocator };

    try s.int(u32, version);
    try s.int(u16, screen.cols);
    try s.int(u16, screen.rows);

    // Style pool. Cell.style_ref indexes this; must come first.
    const pool = screen.pool;
    try s.int(u16, @intCast(pool.entries.items.len));
    for (pool.entries.items) |e| {
        try s.color(e.fg);
        try s.color(e.bg);
        try s.color(e.underline_color);
        try s.int(u16, @bitCast(e.attrs));
    }

    // Grid: active, alt (optional), scrollback in logical order.
    for (screen.active) |*ln| try s.line(ln);
    try s.boolean(screen.alt != null);
    if (screen.alt) |alt| for (alt) |*ln| try s.line(ln);
    try s.boolean(screen.use_alt);
    const sb_count = screen.scrollbackCount();
    try s.int(u32, sb_count);
    var i: u32 = 0;
    while (i < sb_count) : (i += 1) try s.line(screen.scrollbackLine(i));

    // Cursor + per-screen state.
    try s.int(u16, screen.row);
    try s.int(u16, screen.col);
    try s.int(u16, screen.cur_style);
    try s.int(u16, screen.scroll_top);
    try s.int(u16, screen.scroll_bot);
    try s.boolean(screen.pending_wrap);
    try s.int(u64, screen.next_line_id);

    // Modes a client must agree on to interpret input correctly.
    try s.boolean(screen.autowrap);
    try s.boolean(screen.origin_mode);
    try s.boolean(screen.insert_mode);
    try s.boolean(screen.bracketed_paste);
    try s.boolean(screen.line_feed_mode);
    try s.boolean(screen.app_cursor_keys);
    try s.boolean(screen.app_keypad);
    try s.boolean(screen.cursor_visible);
    try s.byte(@intFromEnum(screen.cursor_shape));
    try s.int(u16, screen.mouse_mode);
    try s.boolean(screen.mouse_sgr);
    try s.byte(@intFromEnum(screen.mouse_enc));
    try s.boolean(screen.focus_reports);
    try s.boolean(screen.sync_output);
    // v3: a reattaching mirror must know these to emit the GUI-owned
    // reports (mode 2031 color-scheme) and agree on mode state.
    if (version >= 3) {
        try s.boolean(screen.mode_2031);
        try s.boolean(screen.in_band_resize);
    }

    // Colors + title.
    try s.f32x4(screen.default_fg);
    try s.f32x4(screen.default_bg);
    try s.f32x4(screen.cursor_color);
    try s.out.appendSlice(allocator, std.mem.sliceAsBytes(&screen.palette));
    try s.bytes(if (screen.last_title) |t| t else "");

    // Hyperlinks (OSC 8 side table).
    try s.int(u16, @intCast(screen.links.count()));
    var link_it = screen.links.iterator();
    while (link_it.next()) |kv| {
        try s.byte(kv.key_ptr.*);
        try s.bytes(kv.value_ptr.*);
    }
    try s.byte(screen.current_link_id);
    try s.byte(screen.next_link_id);

    // Grapheme clusters (combining marks on active rows).
    try s.int(u32, @intCast(screen.clusters.count()));
    var cl_it = screen.clusters.iterator();
    while (cl_it.next()) |kv| {
        try s.int(u32, kv.key_ptr.*);
        try s.int(u16, @intCast(kv.value_ptr.items.len));
        for (kv.value_ptr.items) |cp| try s.int(u32, cp);
    }

    // Prompt marks (OSC 133 navigation).
    try s.int(u16, screen.prompt_marks_len);
    for (screen.prompt_marks[0..screen.prompt_marks_len]) |m| try s.int(u64, m);

    // Image placements retained by the daemon (`retain_images`).
    // Newest-first budget pass keeps the freshest placements when
    // the lot would overflow the wire frame; emitted in original
    // order so z-equal stacking stays stable.
    if (version >= 2) {
        const items = screen.retained_images.items;
        var budget: usize = Screen.RETAIN_IMAGE_BUDGET;
        var first_kept: usize = items.len;
        while (first_kept > 0) {
            const need = items[first_kept - 1].owned.len;
            if (need > budget) break;
            budget -= need;
            first_kept -= 1;
        }
        try s.int(u32, @intCast(items.len - first_kept));
        for (items[first_kept..]) |ri| {
            const ev = ri.ev;
            try s.int(u32, ev.width);
            try s.int(u32, ev.height);
            try s.int(u16, ev.row);
            try s.int(u16, ev.col);
            try s.int(u32, ev.image_id);
            try s.int(u32, ev.placement_id);
            try s.int(i32, ev.z_index);
            try s.int(u32, ev.cells_wide);
            try s.int(u32, ev.cells_high);
            try s.int(u32, ev.src_x);
            try s.int(u32, ev.src_y);
            try s.int(u32, ev.src_w);
            try s.int(u32, ev.src_h);
            try s.bytes(ri.owned);
        }
    }

    // v4: OSC 133 command state, LAST in the stream so a v3 payload is
    // exactly a v4 one without this tail. Keeping an open C marker and
    // the completion sequence makes command waits survive mux resyncs.
    if (version >= 4) {
        try s.int(u64, screen.pending_output_start_id);
        try s.boolean(screen.pending_output_awaits_nl);
        try s.int(u64, screen.last_output_start_id);
        try s.int(u64, screen.last_output_end_id);
        try s.int(i32, screen.last_cmd_exit);
        try s.int(u64, screen.cmd_completion_seq);
    }

    // v5 tail: the Glyph Protocol glossary, so a client attaching
    // LATER still renders glyphs registered before it connected. An
    // empty glossary costs 4 bytes. Entries are budgeted newest-first
    // by insertion stamp; the stamps ride along so FIFO eviction
    // order survives the round-trip.
    if (version >= 5) {
        const GlyphEntry = struct { cp: u32, e: @import("../grid/glyph_glossary.zig").Entry };
        var entries: std.ArrayList(GlyphEntry) = .empty;
        defer entries.deinit(allocator);
        var git = screen.glyphs.map.iterator();
        while (git.next()) |kv| {
            // A v5 tail has no format field; a colrv0 payload written
            // there would restore as a glyf record and misrender. A
            // v6 peer knows format tags 0/1 only and rejects a body
            // carrying tag 2 outright — withhold colrv1 entries.
            if (version < 6 and kv.value_ptr.fmt != .glyf) continue;
            if (version < 7 and kv.value_ptr.fmt == .colrv1) continue;
            try entries.append(allocator, .{ .cp = kv.key_ptr.*, .e = kv.value_ptr.* });
        }
        std.mem.sort(GlyphEntry, entries.items, {}, struct {
            fn lt(_: void, a: GlyphEntry, b: GlyphEntry) bool {
                return a.e.insertion < b.e.insertion;
            }
        }.lt);
        var budget: usize = GLYPH_SNAPSHOT_BUDGET;
        var first_kept: usize = entries.items.len;
        while (first_kept > 0) {
            const need = entries.items[first_kept - 1].e.payload.len;
            if (need > budget) break;
            budget -= need;
            first_kept -= 1;
        }
        try s.int(u32, @intCast(entries.items.len - first_kept));
        for (entries.items[first_kept..]) |ge| {
            try s.int(u32, ge.cp);
            try s.int(u16, ge.e.upm);
            try s.byte(ge.e.width);
            if (version >= 6) try s.byte(@intFromEnum(ge.e.fmt));
            try s.int(u64, ge.e.insertion);
            try s.bytes(ge.e.payload);
        }
    }

    // v8 tail: state consulted while applying later parser events. It
    // stays last so every historical body remains byte-for-byte stable.
    if (version >= 8) {
        try s.int(u16, screen.saved_row);
        try s.int(u16, screen.saved_col);
        try s.int(u16, screen.saved_style);
        try s.boolean(screen.saved_origin);
        try s.boolean(screen.saved_autowrap);
        try s.byte(@intFromEnum(screen.saved_charset_g0));
        try s.byte(@intFromEnum(screen.saved_charset_g1));
        try s.byte(@intFromEnum(screen.saved_active_charset));
        try s.byte(screen.saved_link_id);

        try s.byte(@intFromEnum(screen.charset_g0));
        try s.byte(@intFromEnum(screen.charset_g1));
        try s.byte(@intFromEnum(screen.active_charset));
        try s.byte(@intFromEnum(screen.pending_single_shift));
        // The wire shape is exactly `cols` stops, but a Screen whose
        // tab_stops fell out of sync (an allocation failure during a
        // resize used to leave it short) must still serialize: refusing
        // here froze every viewer of that session permanently. Normalize
        // to the grid width instead, padding with the default 8-column
        // rule — the same values `resizeTabStops` would have written.
        try s.int(u16, screen.cols);
        for (0..screen.cols) |col| {
            const stop = if (col < screen.tab_stops.items.len)
                screen.tab_stops.items[col]
            else
                (col % 8 == 0 and col != 0);
            try s.boolean(stop);
        }

        try s.int(u32, screen.last_print_cp);
        try s.int(u32, screen.last_print_key);
        try s.byte(screen.decoder.expected);
        try s.byte(screen.decoder.have);
        try s.int(u32, screen.decoder.buf);

        try s.byte(screen.modify_other_keys);
        try s.boolean(screen.reverse_screen);
        try s.boolean(screen.allow_decolm);
        try s.byte(screen.kitty_kbd_flags);
        try s.byte(screen.kitty_kbd_depth);
        try s.out.appendSlice(allocator, screen.kitty_kbd_stack[0..]);
        try s.byte(screen.kitty_kbd_other_flags);
        try s.byte(screen.kitty_kbd_other_depth);
        try s.out.appendSlice(allocator, screen.kitty_kbd_other_stack[0..]);

        try s.int(u16, screen.prompt_marks_head);
        if (screen.title_stack_depth > screen.title_stack.len) return error.BadScreenState;
        try s.byte(screen.title_stack_depth);
        for (screen.title_stack[0..screen.title_stack_depth]) |entry| {
            // An unset slot below the depth is a lost title, not a
            // reason to withhold the whole screen from every viewer.
            try s.bytes(entry orelse "");
        }
    }

    // v9 tail: the remaining persistent app-driven state. Every field
    // here decides how POST-attach input is interpreted or drawn, so a
    // client without it diverges from the daemon on the next event.
    if (version >= 9) {
        // The completed-zone ring goes out whole, head included, so a
        // later OSC 133 D lands in the same slot on both sides.
        if (screen.cmd_zones_len > screen.cmd_zones.len or
            screen.cmd_zones_head >= screen.cmd_zones.len) return error.BadScreenState;
        try s.int(u16, screen.cmd_zones_len);
        try s.int(u16, screen.cmd_zones_head);
        try s.out.appendSlice(allocator, std.mem.asBytes(&screen.cmd_zones));

        // Kitty placeholder assembly + auto-increment context: this is
        // what the NEXT printed cell is resolved against.
        if (screen.ph_pending) |pp| {
            try s.byte(1);
            try s.int(u16, pp.screen_row);
            try s.int(u16, pp.screen_col);
            try s.int(u32, pp.image_id);
            for (pp.diac) |d| try s.int(u32, d);
            try s.byte(pp.n_diac);
        } else {
            try s.byte(0);
        }
        if (screen.ph_last) |pl| {
            try s.byte(1);
            try s.int(u16, pl.screen_row);
            try s.int(u16, pl.screen_col);
            try s.int(u32, pl.image_id);
            try s.int(u32, pl.img_row);
            try s.int(u32, pl.img_col);
        } else {
            try s.byte(0);
        }

        try s.int(u32, @intCast(screen.virtual_placements.count()));
        var vp_it = screen.virtual_placements.iterator();
        while (vp_it.next()) |kv| {
            try s.int(u32, kv.key_ptr.*);
            try s.int(u32, kv.value_ptr.rows);
            try s.int(u32, kv.value_ptr.cols);
            try s.int(u32, kv.value_ptr.placement_id);
        }

        try s.f32x4(screen.selection_bg);
        try s.f32x4(screen.selection_fg);

        try s.int(u16, @intCast(screen.user_vars.items.len));
        for (screen.user_vars.items) |uv| {
            try s.bytes(uv.name);
            try s.bytes(uv.value);
        }
    }
}

/// A restored Screen together with the private style Pool its cells index.
///
/// Every mux CLIENT that mirrors a session needs exactly this triple, and
/// the two that do (appdrive, termdrive) had hand-rolled it four times
/// between them. The pool must be replaced together with the screen — a
/// screen restored against a pool that is later reset indexes a dead table.
pub const OwnedRestore = struct {
    seq: u64,
    pool: *Pool,
    screen: *Screen,

    pub fn deinit(self: OwnedRestore, allocator: std.mem.Allocator) void {
        self.screen.deinit();
        self.pool.deinit();
        allocator.destroy(self.pool);
    }
};

/// Peel a snapshot frame's envelope and restore its body into a fresh pool.
/// Failure-atomic: nothing is allocated to the caller unless it all worked.
pub fn restoreOwned(allocator: std.mem.Allocator, payload: []const u8) !OwnedRestore {
    const envelope = try peelEnvelope(payload);
    const pool = try allocator.create(Pool);
    errdefer allocator.destroy(pool);
    pool.* = try Pool.init(allocator);
    errdefer pool.deinit();
    const screen = try restore(allocator, pool, envelope.body);
    return .{ .seq = envelope.seq, .pool = pool, .screen = screen };
}

pub const Envelope = struct {
    seq: u64,
    app: bool,
    body: []const u8,
};

/// Decode both the protocol 1-3 and protocol 4+ snapshot envelopes.
pub fn peelEnvelope(payload: []const u8) !Envelope {
    if (payload.len < 12) return error.Truncated;
    const seq = std.mem.readInt(u64, payload[0..8], .little);
    if (payload.len >= 13) {
        const version = std.mem.readInt(u32, payload[9..13], .little);
        if (version >= 1 and version <= SNAPSHOT_VERSION and payload[8] <= 1) {
            return .{ .seq = seq, .app = payload[8] != 0, .body = payload[9..] };
        }
    }
    const version = std.mem.readInt(u32, payload[8..12], .little);
    if (version < 1 or version > SNAPSHOT_VERSION) return error.SnapshotVersionMismatch;
    return .{ .seq = seq, .app = false, .body = payload[8..] };
}

const Src = struct {
    bytes: []const u8,
    pos: usize = 0,

    const Error = error{ Truncated, BadSnapshot, OutOfMemory };

    fn take(self: *Src, n: usize) Error![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn int(self: *Src, comptime T: type) Error!T {
        const s = try self.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    fn byte(self: *Src) Error!u8 {
        return (try self.take(1))[0];
    }

    fn boolean(self: *Src) Error!bool {
        return (try self.byte()) != 0;
    }

    fn strictBoolean(self: *Src) Error!bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.BadSnapshot,
        };
    }

    fn color(self: *Src) Error!style_pool.Color {
        return switch (try self.byte()) {
            0 => .default,
            1 => .{ .palette = try self.byte() },
            2 => .{ .rgb = .{ .r = try self.byte(), .g = try self.byte(), .b = try self.byte() } },
            else => error.BadSnapshot,
        };
    }

    fn f32x4(self: *Src) Error![4]f32 {
        var v: [4]f32 = undefined;
        for (&v) |*x| x.* = @bitCast(try self.int(u32));
        return v;
    }

    /// Read a line into a fresh allocation owned by `allocator`, padded or
    /// truncated to exactly `cols` cells. Width normalization (rather than
    /// rejection) keeps snapshots from pre-normalization daemons — whose
    /// scrollback widths legitimately diverge after an alt-screen resize —
    /// attachable, while preserving the every-line-has-cols-cells invariant
    /// the scroll hot path relies on when recycling scrollback buffers.
    fn line(self: *Src, allocator: std.mem.Allocator, cols: u16, n_styles: u16) Error!Line {
        const id = try self.int(u64);
        const cont = try self.boolean();
        const scaling_raw = try self.byte();
        if (scaling_raw > 3) return error.BadSnapshot;
        const n_cells = try self.int(u16);
        const raw = try self.take(@as(usize, n_cells) * @sizeOf(Cell));
        const cells = allocator.alloc(Cell, cols) catch return error.OutOfMemory;
        errdefer allocator.free(cells);
        @memset(cells, .{});
        const keep = @min(n_cells, cols);
        @memcpy(std.mem.sliceAsBytes(cells[0..keep]), raw[0 .. @as(usize, keep) * @sizeOf(Cell)]);
        for (cells) |cell| {
            if (cell.style_ref >= n_styles) return error.BadSnapshot;
        }
        return .{
            .cells = cells,
            .dirty = true,
            .continues_above = cont,
            .id = id,
            .scaling = @enumFromInt(scaling_raw),
        };
    }
};

fn validateLinkState(screen: *const Screen) !void {
    if (screen.current_link_id != 0 and !screen.links.contains(screen.current_link_id))
        return error.BadSnapshot;
    if (screen.saved_link_id != 0 and !screen.links.contains(screen.saved_link_id))
        return error.BadSnapshot;
}

pub const StagedRestore = struct {
    screen: *Screen,
    replacement_pool: *Pool,
    target_pool: *Pool,
    pool_allocator: std.mem.Allocator,

    pub fn deinit(self: *StagedRestore) void {
        self.screen.deinit();
        self.replacement_pool.deinit();
        self.pool_allocator.destroy(self.replacement_pool);
    }

    /// Commits the staged pool and returns ownership of the restored screen.
    pub fn commit(self: *StagedRestore) *Screen {
        const old_pool = self.target_pool.*;
        self.target_pool.* = self.replacement_pool.*;
        self.replacement_pool.* = old_pool;
        self.screen.pool = self.target_pool;
        self.replacement_pool.deinit();
        self.pool_allocator.destroy(self.replacement_pool);
        return self.screen;
    }

    /// Swaps the restored screen and pool into a live caller-owned slot.
    pub fn commitReplacing(self: *StagedRestore, current: **Screen) void {
        std.debug.assert(current.*.pool == self.target_pool);
        const old_screen = current.*;
        const old_pool = self.target_pool.*;
        self.target_pool.* = self.replacement_pool.*;
        self.replacement_pool.* = old_pool;
        self.screen.pool = self.target_pool;
        old_screen.pool = self.replacement_pool;
        current.* = self.screen;
        self.screen = old_screen;
    }
};

/// Restores a snapshot without mutating `pool` until the stage is committed.
pub fn restoreStaged(allocator: std.mem.Allocator, pool: *Pool, bytes: []const u8) !StagedRestore {
    var src = Src{ .bytes = bytes };

    const version = try src.int(u32);
    // Historical bodies stay readable so a newer client can attach without
    // replacing the daemon that owns its durable sessions.
    if (version < 1 or version > SNAPSHOT_VERSION) return error.SnapshotVersionMismatch;
    const cols = try src.int(u16);
    const rows = try src.int(u16);
    // The same grid bound every other entry point uses: a snapshot body is
    // as untrusted as a spawn request, and it names the grid we allocate.
    wire.validateTerminalSize(rows, cols) catch return error.BadSnapshot;

    // The replacement pool stays private until every field below has parsed.
    // A live Screen may still be interpreting cells through `pool` on error.
    const n_styles = try src.int(u16);
    if (n_styles == 0) return error.BadSnapshot; // index 0 = default always exists
    var new_entries: std.ArrayList(style_pool.Entry) = .empty;
    errdefer new_entries.deinit(pool.allocator);
    try new_entries.ensureTotalCapacity(pool.allocator, n_styles);
    for (0..n_styles) |_| {
        const fg = try src.color();
        const bg = try src.color();
        const ul = try src.color();
        const attrs_raw = try src.int(u16);
        new_entries.appendAssumeCapacity(.{
            .fg = fg,
            .bg = bg,
            .underline_color = ul,
            .attrs = @bitCast(attrs_raw),
        });
    }

    const replacement_pool = try pool.allocator.create(Pool);
    errdefer pool.allocator.destroy(replacement_pool);
    replacement_pool.* = try Pool.initReplacement(pool.allocator, new_entries);
    new_entries = .empty;
    errdefer replacement_pool.deinit();

    const screen = try Screen.init(allocator, replacement_pool, cols, rows);
    errdefer screen.deinit();

    // Active rows: swap each freshly-built line for the snapshot one.
    for (screen.active) |*ln| {
        const loaded = try src.line(allocator, cols, n_styles);
        ln.deinit(allocator);
        ln.* = loaded;
    }
    if (try src.boolean()) {
        const alt = try allocator.alloc(Line, rows);
        var done: usize = 0;
        errdefer {
            for (alt[0..done]) |*l| l.deinit(allocator);
            allocator.free(alt);
        }
        for (alt) |*ln| {
            ln.* = try src.line(allocator, cols, n_styles);
            done += 1;
        }
        screen.alt = alt;
    }
    const use_alt = try src.boolean();
    if (use_alt and screen.alt == null) return error.BadSnapshot;
    screen.use_alt = use_alt;
    // The whole grid was just replaced under the cursor; anything
    // interpolating from its old position (the cursor trail) must
    // teleport rather than smear across content it never saw.
    screen.viewport_epoch +%= 1;

    const sb_count = try src.int(u32);
    try screen.scrollback.ensureTotalCapacity(allocator, sb_count);
    for (0..sb_count) |_| {
        const ln = try src.line(allocator, cols, n_styles);
        screen.scrollback.appendAssumeCapacity(ln);
    }
    screen.scrollback_head = 0;

    screen.row = @min(try src.int(u16), rows - 1);
    screen.col = @min(try src.int(u16), cols - 1);
    screen.cur_style = try src.int(u16);
    if (screen.cur_style >= n_styles) return error.BadSnapshot;
    screen.scroll_top = @min(try src.int(u16), rows - 1);
    screen.scroll_bot = @min(try src.int(u16), rows - 1);
    screen.pending_wrap = try src.boolean();
    screen.next_line_id = try src.int(u64);

    screen.autowrap = try src.boolean();
    screen.origin_mode = try src.boolean();
    screen.insert_mode = try src.boolean();
    screen.bracketed_paste = try src.boolean();
    screen.line_feed_mode = try src.boolean();
    screen.app_cursor_keys = try src.boolean();
    screen.app_keypad = try src.boolean();
    screen.cursor_visible = try src.boolean();
    screen.cursor_shape = std.enums.fromInt(@TypeOf(screen.cursor_shape), try src.byte()) orelse return error.BadSnapshot;
    screen.mouse_mode = try src.int(u16);
    screen.mouse_sgr = try src.boolean();
    screen.mouse_enc = std.enums.fromInt(@TypeOf(screen.mouse_enc), try src.byte()) orelse return error.BadSnapshot;
    screen.focus_reports = try src.boolean();
    screen.sync_output = try src.boolean();
    if (version >= 3) {
        screen.mode_2031 = try src.boolean();
        screen.in_band_resize = try src.boolean();
    }

    screen.default_fg = try src.f32x4();
    screen.default_bg = try src.f32x4();
    screen.cursor_color = try src.f32x4();
    const pal_raw = try src.take(@sizeOf(@TypeOf(screen.palette)));
    @memcpy(std.mem.asBytes(&screen.palette), pal_raw);
    const title_len = try src.int(u32);
    if (title_len > 0) {
        const t = try src.take(title_len);
        screen.last_title = try allocator.dupe(u8, t);
    }

    const n_links = try src.int(u16);
    if (n_links > 255) return error.BadSnapshot;
    for (0..n_links) |_| {
        const key = try src.byte();
        if (key == 0 or screen.links.contains(key)) return error.BadSnapshot;
        const uri_len = try src.int(u32);
        const uri = try src.take(uri_len);
        const copy = try allocator.dupe(u8, uri);
        errdefer allocator.free(copy);
        try screen.links.put(key, copy);
    }
    screen.current_link_id = try src.byte();
    screen.next_link_id = try src.byte();

    const n_clusters = try src.int(u32);
    for (0..n_clusters) |_| {
        const key = try src.int(u32);
        const n_cps = try src.int(u16);
        var list: std.ArrayList(u32) = .empty;
        errdefer list.deinit(allocator);
        try list.ensureTotalCapacity(allocator, n_cps);
        for (0..n_cps) |_| list.appendAssumeCapacity(try src.int(u32));
        try screen.clusters.put(key, list);
    }

    const prompt_marks_len = try src.int(u16);
    if (prompt_marks_len > screen.prompt_marks.len) return error.BadSnapshot;
    screen.prompt_marks_len = prompt_marks_len;
    for (0..screen.prompt_marks_len) |idx| screen.prompt_marks[idx] = try src.int(u64);
    screen.prompt_marks_head = if (screen.prompt_marks_len < screen.prompt_marks.len)
        screen.prompt_marks_len
    else
        0;

    // Retained image placements — parked on the screen; the client
    // replays them into its image sink once a pane is wired
    // (Terminal.replayRetainedImages) and then frees them.
    var n_images: u32 = if (version >= 2) try src.int(u32) else 0;
    // A transitional v4 writer shipped before the command-state format was
    // finalized. Its legacy u32 occupies the slot now used by n_images and is
    // followed immediately by the fixed 37-byte command tail. When non-zero,
    // current readers mistake it for an image count and run off the end of the
    // snapshot with Truncated. The shape is unambiguous: even one legitimate
    // image needs metadata beyond the tail, so a non-zero count with exactly
    // the tail remaining can only be that legacy v4 form. A zero legacy value
    // already decodes normally as zero images.
    if (version == 4 and n_images != 0 and src.bytes.len - src.pos == V4_COMMAND_TAIL_LEN)
        n_images = 0;
    for (0..n_images) |_| {
        var ev = Screen.ImageEvent{
            .width = try src.int(u32),
            .height = try src.int(u32),
            .rgba = &.{},
            .row = try src.int(u16),
            .col = try src.int(u16),
            .image_id = try src.int(u32),
            .placement_id = try src.int(u32),
            .z_index = try src.int(i32),
            .cells_wide = try src.int(u32),
            .cells_high = try src.int(u32),
            .src_x = try src.int(u32),
            .src_y = try src.int(u32),
            .src_w = try src.int(u32),
            .src_h = try src.int(u32),
        };
        const data_len = try src.int(u32);
        const data = try src.take(data_len);
        const owned = try allocator.dupe(u8, data);
        errdefer allocator.free(owned);
        ev.rgba = owned;
        try screen.retained_images.append(allocator, .{ .ev = ev, .owned = owned });
        screen.retained_image_bytes += owned.len;
    }

    // v4 tail: OSC 133 command state. A v3 payload simply ends here;
    // the fields keep their zero defaults (no completed zone known).
    if (version >= 4) {
        screen.pending_output_start_id = try src.int(u64);
        screen.pending_output_awaits_nl = try src.boolean();
        screen.last_output_start_id = try src.int(u64);
        screen.last_output_end_id = try src.int(u64);
        screen.last_cmd_exit = try src.int(i32);
        screen.cmd_completion_seq = try src.int(u64);
    }

    // v5 tail: Glyph Protocol glossary. `registerRestored` re-mints
    // render keys locally (foreign keys are meaningless in this
    // process) while keeping the FIFO insertion stamps. v6 adds the
    // per-entry format byte; a v5 body is glyf-only by construction.
    if (version >= 5) {
        const gp = @import("../parser/glyph_protocol.zig");
        const n_glyphs = try src.int(u32);
        for (0..n_glyphs) |_| {
            const cp = try src.int(u32);
            const upm = try src.int(u16);
            const width = try src.byte();
            const fmt: gp.Format = if (version >= 6)
                std.enums.fromInt(gp.Format, try src.byte()) orelse return error.BadSnapshot
            else
                .glyf;
            const insertion = try src.int(u64);
            const plen = try src.int(u32);
            const pdata = try src.take(plen);
            if (upm == 0 or (width != 1 and width != 2) or plen == 0) return error.BadSnapshot;
            const owned = allocator.dupe(u8, pdata) catch return error.OutOfMemory;
            screen.glyphs.registerRestored(cp, owned, fmt, upm, width, insertion) catch return error.BadSnapshot;
        }
    }

    // v8 tail: older snapshots intentionally keep Screen.init defaults
    // (and the derived prompt-ring head above).
    if (version >= 8) {
        screen.saved_row = try src.int(u16);
        screen.saved_col = try src.int(u16);
        screen.saved_style = try src.int(u16);
        if (screen.saved_style >= n_styles) return error.BadSnapshot;
        screen.saved_origin = try src.strictBoolean();
        screen.saved_autowrap = try src.strictBoolean();
        screen.saved_charset_g0 = std.enums.fromInt(Screen.Charset, try src.byte()) orelse return error.BadSnapshot;
        screen.saved_charset_g1 = std.enums.fromInt(Screen.Charset, try src.byte()) orelse return error.BadSnapshot;
        screen.saved_active_charset = std.enums.fromInt(Screen.ActiveCharset, try src.byte()) orelse return error.BadSnapshot;
        screen.saved_link_id = try src.byte();

        screen.charset_g0 = std.enums.fromInt(Screen.Charset, try src.byte()) orelse return error.BadSnapshot;
        screen.charset_g1 = std.enums.fromInt(Screen.Charset, try src.byte()) orelse return error.BadSnapshot;
        screen.active_charset = std.enums.fromInt(Screen.ActiveCharset, try src.byte()) orelse return error.BadSnapshot;
        screen.pending_single_shift = std.enums.fromInt(Screen.PendingSingleShift, try src.byte()) orelse return error.BadSnapshot;
        const n_tab_stops = try src.int(u16);
        if (n_tab_stops != cols or screen.tab_stops.items.len != cols) return error.BadSnapshot;
        for (screen.tab_stops.items) |*stop| stop.* = try src.strictBoolean();

        screen.last_print_cp = try src.int(u32);
        screen.last_print_key = try src.int(u32);
        const decoder_expected = try src.byte();
        const decoder_have = try src.byte();
        const decoder_buf = try src.int(u32);
        const decoder_valid = if (decoder_expected == 0)
            decoder_have == 0 and decoder_buf == 0
        else
            decoder_expected >= 2 and decoder_expected <= 4 and
                decoder_have >= 1 and decoder_have < decoder_expected;
        if (!decoder_valid) return error.BadSnapshot;
        screen.decoder.expected = @intCast(decoder_expected);
        screen.decoder.have = @intCast(decoder_have);
        screen.decoder.buf = decoder_buf;

        screen.modify_other_keys = try src.byte();
        if (screen.modify_other_keys > 2) return error.BadSnapshot;
        screen.reverse_screen = try src.strictBoolean();
        screen.allow_decolm = try src.strictBoolean();
        screen.kitty_kbd_flags = try src.byte();
        screen.kitty_kbd_depth = try src.byte();
        if (screen.kitty_kbd_depth > screen.kitty_kbd_stack.len) return error.BadSnapshot;
        @memcpy(screen.kitty_kbd_stack[0..], try src.take(screen.kitty_kbd_stack.len));
        screen.kitty_kbd_other_flags = try src.byte();
        screen.kitty_kbd_other_depth = try src.byte();
        if (screen.kitty_kbd_other_depth > screen.kitty_kbd_other_stack.len) return error.BadSnapshot;
        @memcpy(screen.kitty_kbd_other_stack[0..], try src.take(screen.kitty_kbd_other_stack.len));

        screen.prompt_marks_head = try src.int(u16);
        if (screen.prompt_marks_head >= screen.prompt_marks.len or
            (screen.prompt_marks_len < screen.prompt_marks.len and
                screen.prompt_marks_head != screen.prompt_marks_len))
        {
            return error.BadSnapshot;
        }
        screen.title_stack_depth = try src.byte();
        if (screen.title_stack_depth > screen.title_stack.len) return error.BadSnapshot;
        for (0..screen.title_stack_depth) |idx| {
            const stack_title_len = try src.int(u32);
            const title = try src.take(stack_title_len);
            screen.title_stack[idx] = try allocator.dupe(u8, title);
        }
    }

    // v9 tail: older snapshots keep Screen.init defaults here (no
    // completed zones, no placeholder context, no virtual placements,
    // unset selection colors, no user variables).
    if (version >= 9) {
        const zones_len = try src.int(u16);
        const zones_head = try src.int(u16);
        if (zones_len > screen.cmd_zones.len or zones_head >= screen.cmd_zones.len)
            return error.BadSnapshot;
        const zone_bytes = try src.take(@sizeOf(@TypeOf(screen.cmd_zones)));
        @memcpy(std.mem.asBytes(&screen.cmd_zones), zone_bytes);
        screen.cmd_zones_len = zones_len;
        screen.cmd_zones_head = zones_head;

        if (try src.strictBoolean()) {
            const ph_row = try src.int(u16);
            const ph_col = try src.int(u16);
            const ph_image_id = try src.int(u32);
            var diac: [3]u32 = undefined;
            for (&diac) |*d| d.* = try src.int(u32);
            const n_diac = try src.byte();
            if (n_diac > diac.len or ph_row >= rows or ph_col >= cols) return error.BadSnapshot;
            screen.ph_pending = .{
                .screen_row = ph_row,
                .screen_col = ph_col,
                .image_id = ph_image_id,
                .diac = diac,
                .n_diac = n_diac,
            };
        }
        if (try src.strictBoolean()) {
            screen.ph_last = .{
                .screen_row = try src.int(u16),
                .screen_col = try src.int(u16),
                .image_id = try src.int(u32),
                .img_row = try src.int(u32),
                .img_col = try src.int(u32),
            };
        }

        const n_placements = try src.int(u32);
        if (n_placements > grid.VIRTUAL_PLACEMENT_CAP) return error.BadSnapshot;
        for (0..n_placements) |_| {
            const key = try src.int(u32);
            const placement = grid.VirtualPlacement{
                .rows = try src.int(u32),
                .cols = try src.int(u32),
                .placement_id = try src.int(u32),
            };
            if (key == 0 or screen.virtual_placements.contains(key)) return error.BadSnapshot;
            try screen.virtual_placements.put(key, placement);
        }

        screen.selection_bg = try src.f32x4();
        screen.selection_fg = try src.f32x4();

        const n_user_vars = try src.int(u16);
        if (n_user_vars > grid.USER_VAR_CAP) return error.BadSnapshot;
        try screen.user_vars.ensureTotalCapacity(allocator, n_user_vars);
        for (0..n_user_vars) |_| {
            const name_len = try src.int(u32);
            const name = try src.take(name_len);
            const value_len = try src.int(u32);
            const value = try src.take(value_len);
            // `setUserVar` never stores an empty value or a duplicate
            // name: a body that does is malformed, not merely odd.
            if (name.len == 0 or value.len == 0 or screen.userVar(name) != null)
                return error.BadSnapshot;
            const name_copy = try allocator.dupe(u8, name);
            errdefer allocator.free(name_copy);
            const value_copy = try allocator.dupe(u8, value);
            screen.user_vars.appendAssumeCapacity(.{ .name = name_copy, .value = value_copy });
        }
    }

    if (version >= 8) try validateLinkState(screen);
    if (version >= 8 and src.pos != src.bytes.len) return error.BadSnapshot;

    screen.dirty = true;
    return .{
        .screen = screen,
        .replacement_pool = replacement_pool,
        .target_pool = pool,
        .pool_allocator = pool.allocator,
    };
}

/// Restores a snapshot into a new Screen and replaces `pool` on success.
pub fn restore(allocator: std.mem.Allocator, pool: *Pool, bytes: []const u8) !*Screen {
    var staged = try restoreStaged(allocator, pool, bytes);
    errdefer staged.deinit();
    return staged.commit();
}

// ── tests ───────────────────────────────────────────────────────

const testing = std.testing;
const Harness = @import("../parser/test_harness.zig").Harness;
const Parser = @import("../parser/vt.zig").Parser;
const Event = @import("../parser/event.zig").Event;

const PairFeeder = struct {
    parser: Parser,
    allocator: std.mem.Allocator,
    daemon: *Screen,
    client: *Screen,

    fn init(allocator: std.mem.Allocator, daemon: *Screen, client: *Screen) PairFeeder {
        return .{
            .parser = Parser.init(allocator),
            .allocator = allocator,
            .daemon = daemon,
            .client = client,
        };
    }

    fn deinit(self: *PairFeeder) void {
        self.parser.deinit();
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *PairFeeder = @ptrCast(@alignCast(user.?));
        var owned = ev;
        self.daemon.apply(ev);
        self.client.apply(ev);
        owned.deinit(self.allocator);
    }

    fn feed(self: *PairFeeder, bytes: []const u8) void {
        self.parser.advance(bytes, emit, @ptrCast(self));
    }
};

fn expectLineEqual(expected: *const Line, actual: *const Line) !void {
    try testing.expectEqual(expected.id, actual.id);
    try testing.expectEqual(expected.continues_above, actual.continues_above);
    try testing.expectEqual(expected.scaling, actual.scaling);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.cells), std.mem.sliceAsBytes(actual.cells));
}

fn expectOptionalStringEqual(expected: ?[]u8, actual: ?[]u8) !void {
    try testing.expectEqual(expected != null, actual != null);
    if (expected) |value| try testing.expectEqualStrings(value, actual.?);
}

fn expectScreensEqual(expected: *const Screen, actual: *const Screen) !void {
    try testing.expectEqual(expected.cols, actual.cols);
    try testing.expectEqual(expected.rows, actual.rows);
    try testing.expectEqual(expected.use_alt, actual.use_alt);
    for (expected.active, actual.active) |*left, *right| try expectLineEqual(left, right);
    try testing.expectEqual(expected.alt != null, actual.alt != null);
    if (expected.alt) |left_alt| {
        for (left_alt, actual.alt.?) |*left, *right| try expectLineEqual(left, right);
    }
    try testing.expectEqual(expected.scrollbackCount(), actual.scrollbackCount());
    var sb: u32 = 0;
    while (sb < expected.scrollbackCount()) : (sb += 1) {
        try expectLineEqual(expected.scrollbackLine(sb), actual.scrollbackLine(sb));
    }

    try testing.expectEqual(expected.row, actual.row);
    try testing.expectEqual(expected.col, actual.col);
    try testing.expectEqual(expected.saved_row, actual.saved_row);
    try testing.expectEqual(expected.saved_col, actual.saved_col);
    try testing.expectEqual(expected.saved_style, actual.saved_style);
    try testing.expectEqual(expected.saved_origin, actual.saved_origin);
    try testing.expectEqual(expected.saved_autowrap, actual.saved_autowrap);
    try testing.expectEqual(expected.saved_charset_g0, actual.saved_charset_g0);
    try testing.expectEqual(expected.saved_charset_g1, actual.saved_charset_g1);
    try testing.expectEqual(expected.saved_active_charset, actual.saved_active_charset);
    try testing.expectEqual(expected.saved_link_id, actual.saved_link_id);
    try testing.expectEqual(expected.cur_style, actual.cur_style);
    try testing.expectEqual(expected.scroll_top, actual.scroll_top);
    try testing.expectEqual(expected.scroll_bot, actual.scroll_bot);
    try testing.expectEqual(expected.pending_wrap, actual.pending_wrap);
    try testing.expectEqual(expected.next_line_id, actual.next_line_id);

    try testing.expectEqual(expected.autowrap, actual.autowrap);
    try testing.expectEqual(expected.origin_mode, actual.origin_mode);
    try testing.expectEqual(expected.insert_mode, actual.insert_mode);
    try testing.expectEqual(expected.bracketed_paste, actual.bracketed_paste);
    try testing.expectEqual(expected.line_feed_mode, actual.line_feed_mode);
    try testing.expectEqual(expected.app_cursor_keys, actual.app_cursor_keys);
    try testing.expectEqual(expected.app_keypad, actual.app_keypad);
    try testing.expectEqual(expected.cursor_visible, actual.cursor_visible);
    try testing.expectEqual(expected.cursor_shape, actual.cursor_shape);
    try testing.expectEqual(expected.mouse_mode, actual.mouse_mode);
    try testing.expectEqual(expected.mouse_sgr, actual.mouse_sgr);
    try testing.expectEqual(expected.mouse_enc, actual.mouse_enc);
    try testing.expectEqual(expected.focus_reports, actual.focus_reports);
    try testing.expectEqual(expected.sync_output, actual.sync_output);
    try testing.expectEqual(expected.mode_2031, actual.mode_2031);
    try testing.expectEqual(expected.in_band_resize, actual.in_band_resize);
    try testing.expectEqual(expected.reverse_screen, actual.reverse_screen);
    try testing.expectEqual(expected.allow_decolm, actual.allow_decolm);
    try testing.expectEqual(expected.modify_other_keys, actual.modify_other_keys);

    try testing.expectEqual(expected.charset_g0, actual.charset_g0);
    try testing.expectEqual(expected.charset_g1, actual.charset_g1);
    try testing.expectEqual(expected.active_charset, actual.active_charset);
    try testing.expectEqual(expected.pending_single_shift, actual.pending_single_shift);
    try testing.expectEqualSlices(bool, expected.tab_stops.items, actual.tab_stops.items);
    try testing.expectEqual(expected.last_print_cp, actual.last_print_cp);
    try testing.expectEqual(expected.last_print_key, actual.last_print_key);
    try testing.expectEqual(expected.decoder.expected, actual.decoder.expected);
    try testing.expectEqual(expected.decoder.have, actual.decoder.have);
    try testing.expectEqual(expected.decoder.buf, actual.decoder.buf);

    try testing.expectEqual(expected.kitty_kbd_flags, actual.kitty_kbd_flags);
    try testing.expectEqual(expected.kitty_kbd_depth, actual.kitty_kbd_depth);
    try testing.expectEqualSlices(u8, &expected.kitty_kbd_stack, &actual.kitty_kbd_stack);
    try testing.expectEqual(expected.kitty_kbd_other_flags, actual.kitty_kbd_other_flags);
    try testing.expectEqual(expected.kitty_kbd_other_depth, actual.kitty_kbd_other_depth);
    try testing.expectEqualSlices(u8, &expected.kitty_kbd_other_stack, &actual.kitty_kbd_other_stack);

    try testing.expectEqual(expected.current_link_id, actual.current_link_id);
    try testing.expectEqual(expected.next_link_id, actual.next_link_id);
    try testing.expectEqual(expected.links.count(), actual.links.count());
    var links = expected.links.iterator();
    while (links.next()) |entry| {
        try testing.expectEqualStrings(entry.value_ptr.*, actual.links.get(entry.key_ptr.*) orelse return error.TestExpectedEqual);
    }

    try expectOptionalStringEqual(expected.last_title, actual.last_title);
    try testing.expectEqual(expected.title_stack_depth, actual.title_stack_depth);
    for (0..expected.title_stack_depth) |idx| {
        try testing.expectEqualStrings(expected.title_stack[idx].?, actual.title_stack[idx].?);
    }
    try testing.expectEqual(expected.cmd_zones_len, actual.cmd_zones_len);
    try testing.expectEqual(expected.cmd_zones_head, actual.cmd_zones_head);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&expected.cmd_zones), std.mem.asBytes(&actual.cmd_zones));
    try testing.expectEqual(expected.ph_pending, actual.ph_pending);
    try testing.expectEqual(expected.ph_last, actual.ph_last);
    try testing.expectEqual(expected.virtual_placements.count(), actual.virtual_placements.count());
    var placements = expected.virtual_placements.iterator();
    while (placements.next()) |entry| {
        try testing.expectEqual(entry.value_ptr.*, actual.virtual_placements.get(entry.key_ptr.*) orelse
            return error.TestExpectedEqual);
    }
    try testing.expectEqual(expected.selection_bg, actual.selection_bg);
    try testing.expectEqual(expected.selection_fg, actual.selection_fg);
    try testing.expectEqual(expected.user_vars.items.len, actual.user_vars.items.len);
    for (expected.user_vars.items) |uv| {
        try testing.expectEqualStrings(uv.value, actual.userVar(uv.name) orelse return error.TestExpectedEqual);
    }
    try testing.expectEqual(expected.prompt_marks_len, actual.prompt_marks_len);
    try testing.expectEqual(expected.prompt_marks_head, actual.prompt_marks_head);
    try testing.expectEqualSlices(u64, &expected.prompt_marks, &actual.prompt_marks);

    try testing.expectEqual(expected.pool.entries.items.len, actual.pool.entries.items.len);
    for (expected.pool.entries.items, actual.pool.entries.items) |left, right| {
        try testing.expect(style_pool.Entry.equal(left, right));
    }
}

const LiveRestoreState = struct {
    bytes: []u8,
    entries: []style_pool.Entry,
    entries_ptr: [*]style_pool.Entry,
    entries_capacity: usize,
    index_count: usize,
    last_idx: u16,
    active_cells_ptr: [*]Cell,
    title_ptr: [*]u8,

    fn capture(allocator: std.mem.Allocator, screen: *const Screen, pool: *const Pool) !LiveRestoreState {
        const entries = try allocator.dupe(style_pool.Entry, pool.entries.items);
        errdefer allocator.free(entries);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try serialize(screen, &out, allocator);
        return .{
            .bytes = try out.toOwnedSlice(allocator),
            .entries = entries,
            .entries_ptr = pool.entries.items.ptr,
            .entries_capacity = pool.entries.capacity,
            .index_count = pool.index.count(),
            .last_idx = pool.last_idx,
            .active_cells_ptr = screen.active[0].cells.ptr,
            .title_ptr = screen.last_title.?.ptr,
        };
    }

    fn deinit(self: *LiveRestoreState, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.entries);
    }

    fn expectUnchanged(self: *const LiveRestoreState, screen: *const Screen, pool: *const Pool) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try serialize(screen, &out, testing.allocator);
        try testing.expectEqualSlices(u8, self.bytes, out.items);
        try testing.expectEqual(self.entries_ptr, pool.entries.items.ptr);
        try testing.expectEqual(self.entries_capacity, pool.entries.capacity);
        try testing.expectEqual(self.index_count, pool.index.count());
        try testing.expectEqual(self.last_idx, pool.last_idx);
        try testing.expectEqual(self.active_cells_ptr, screen.active[0].cells.ptr);
        try testing.expectEqual(self.title_ptr, screen.last_title.?.ptr);
        try testing.expectEqual(self.entries.len, pool.entries.items.len);
        for (self.entries, pool.entries.items) |before, after| {
            try testing.expect(style_pool.Entry.equal(before, after));
        }
    }
};

fn initPopulatedLiveScreen(allocator: std.mem.Allocator, pool: *Pool) !*Screen {
    const red = style_pool.Entry{ .fg = .{ .palette = 1 } };
    const green = style_pool.Entry{ .fg = .{ .palette = 2 } };
    const red_idx = try pool.intern(red);
    const green_idx = try pool.intern(green);
    const screen = try Screen.init(allocator, pool, 9, 3);
    errdefer screen.deinit();
    screen.active[0].cells[0].rune = 'L';
    screen.active[0].cells[0].style_ref = red_idx;
    screen.active[1].cells[2].rune = 'V';
    screen.active[1].cells[2].style_ref = green_idx;
    screen.row = 1;
    screen.col = 2;
    screen.scrollback_capacity = 2;
    screen.last_title = try allocator.dupe(u8, "live screen");
    const uri = try allocator.dupe(u8, "https://live.invalid");
    errdefer allocator.free(uri);
    try screen.links.put(7, uri);
    screen.current_link_id = 7;
    screen.next_link_id = 8;
    return screen;
}

fn expectLivePoolLookup(pool: *Pool) !void {
    const before_len = pool.entries.items.len;
    const red = style_pool.Entry{ .fg = .{ .palette = 1 } };
    try testing.expectEqual(@as(u16, 1), try pool.intern(red));
    try testing.expectEqual(before_len, pool.entries.items.len);
}

fn makeFailureSnapshot(allocator: std.mem.Allocator) ![]u8 {
    const gp = @import("../parser/glyph_protocol.zig");
    var h = try Harness.init(allocator, 12, 4);
    defer h.deinit();
    h.screen.retain_images = true;
    h.feed("\x1b[31mred\x1b[0m\r\n");
    h.feed("\x1b[1;4;38:2::10:20:30mfancy\x1b[0m\r\n");
    for (0..10) |_| h.feed("scroll line\r\n");
    h.feed("\x1b]0;replacement title\x07");
    h.feed("\x1b[?1049halt e\xcc\x81 ");
    h.feed("\x1b]8;;https://replacement.invalid\x07link\x1b]8;;\x07");
    h.feed("\x1b_Gf=32,s=1,v=1,t=d,a=T,i=9,p=2,z=5;/wAA/w==\x1b\\");
    const triangle = try gp.triangleBytes(allocator);
    defer allocator.free(triangle);
    const glyph = try allocator.dupe(u8, triangle);
    try h.screen.glyphs.registerAdopt(0xE100, glyph, .glyf, 1000, 1);
    try testing.expect(h.pool.entries.items.len > 1);
    try testing.expect(h.screen.alt != null);
    try testing.expect(h.screen.scrollbackCount() > 2);
    try testing.expect(h.screen.last_title != null);
    try testing.expect(h.screen.links.count() > 0);
    try testing.expect(h.screen.clusters.count() > 0);
    try testing.expect(h.screen.retained_images.items.len > 0);
    try testing.expect(h.screen.glyphs.count() > 0);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try serialize(h.screen, &out, allocator);
    return out.toOwnedSlice(allocator);
}

const FirstLineOffsets = struct {
    n_styles: u16,
    scaling: usize,
    first_cell: usize,
};

const AlternateStateOffsets = struct {
    has_alt: usize,
    use_alt: usize,
};

fn skipSerializedLine(src: *Src) !void {
    _ = try src.int(u64);
    _ = try src.boolean();
    _ = try src.byte();
    const n_cells = try src.int(u16);
    _ = try src.take(@as(usize, n_cells) * @sizeOf(Cell));
}

fn alternateStateOffsets(bytes: []const u8) !AlternateStateOffsets {
    var src = Src{ .bytes = bytes };
    _ = try src.int(u32);
    _ = try src.int(u16);
    const rows = try src.int(u16);
    const n_styles = try src.int(u16);
    for (0..n_styles) |_| {
        _ = try src.color();
        _ = try src.color();
        _ = try src.color();
        _ = try src.int(u16);
    }
    for (0..rows) |_| try skipSerializedLine(&src);
    const has_alt = src.pos;
    if (try src.boolean()) {
        for (0..rows) |_| try skipSerializedLine(&src);
    }
    const use_alt = src.pos;
    _ = try src.boolean();
    return .{ .has_alt = has_alt, .use_alt = use_alt };
}

fn firstLineOffsets(bytes: []const u8) !FirstLineOffsets {
    var src = Src{ .bytes = bytes };
    _ = try src.int(u32);
    _ = try src.int(u16);
    _ = try src.int(u16);
    const n_styles = try src.int(u16);
    for (0..n_styles) |_| {
        _ = try src.color();
        _ = try src.color();
        _ = try src.color();
        _ = try src.int(u16);
    }
    _ = try src.int(u64);
    _ = try src.boolean();
    const scaling = src.pos;
    _ = try src.byte();
    _ = try src.int(u16);
    return .{ .n_styles = n_styles, .scaling = scaling, .first_cell = src.pos };
}

const RestoreAllocationRange = struct {
    first: usize,
    restore_end: usize,
    end: usize,
};

fn runRestoreAllocationFailure(snapshot_bytes: []const u8, fail_index: ?usize) !RestoreAllocationRange {
    var config: testing.FailingAllocator.Config = .{};
    if (fail_index) |index| config.fail_index = index;
    var failing = testing.FailingAllocator.init(testing.allocator, config);
    const allocator = failing.allocator();

    var pool = try Pool.init(allocator);
    defer pool.deinit();
    var live = try initPopulatedLiveScreen(allocator, &pool);
    defer live.deinit();
    var before = try LiveRestoreState.capture(testing.allocator, live, &pool);
    defer before.deinit(testing.allocator);

    const first = failing.alloc_index;
    var restore_end = first;
    var failure: ?anyerror = null;
    restore_attempt: {
        var staged = restoreStaged(allocator, &pool, snapshot_bytes) catch |err| {
            failure = err;
            break :restore_attempt;
        };
        defer staged.deinit();
        restore_end = failing.alloc_index;
        staged.screen.setScrollbackCapacity(live.scrollback_capacity) catch |err| {
            failure = err;
            break :restore_attempt;
        };
    }
    const end = failing.alloc_index;

    if (fail_index != null) {
        try testing.expect(failing.has_induced_failure);
        try testing.expect(failure != null);
    } else {
        try testing.expect(!failing.has_induced_failure);
        try testing.expectEqual(@as(?anyerror, null), failure);
    }
    try before.expectUnchanged(live, &pool);
    try expectLivePoolLookup(&pool);
    return .{ .first = first, .restore_end = restore_end, .end = end };
}

test "snapshot: failed staged restores preserve a populated live screen and pool" {
    const a = testing.allocator;
    const snapshot_bytes = try makeFailureSnapshot(a);
    defer a.free(snapshot_bytes);
    const offsets = try firstLineOffsets(snapshot_bytes);

    var pool = try Pool.init(a);
    defer pool.deinit();
    const live = try initPopulatedLiveScreen(a, &pool);
    defer live.deinit();
    var before = try LiveRestoreState.capture(a, live, &pool);
    defer before.deinit(a);

    try testing.expectError(
        error.Truncated,
        restoreStaged(a, &pool, snapshot_bytes[0 .. offsets.first_cell + @sizeOf(Cell) - 1]),
    );
    try before.expectUnchanged(live, &pool);

    const old_scaling = snapshot_bytes[offsets.scaling];
    snapshot_bytes[offsets.scaling] = 4;
    try testing.expectError(error.BadSnapshot, restoreStaged(a, &pool, snapshot_bytes));
    snapshot_bytes[offsets.scaling] = old_scaling;
    try before.expectUnchanged(live, &pool);

    const style_offset = offsets.first_cell + @offsetOf(Cell, "style_ref");
    const old_style = std.mem.readInt(u16, snapshot_bytes[style_offset..][0..2], .little);
    std.mem.writeInt(u16, snapshot_bytes[style_offset..][0..2], offsets.n_styles, .little);
    try testing.expectError(error.BadSnapshot, restoreStaged(a, &pool, snapshot_bytes));
    std.mem.writeInt(u16, snapshot_bytes[style_offset..][0..2], old_style, .little);
    try before.expectUnchanged(live, &pool);
    try expectLivePoolLookup(&pool);
}

test "snapshot: inconsistent alternate state is rejected without touching live state" {
    const a = testing.allocator;
    var source = try Harness.init(a, 8, 3);
    defer source.deinit();
    source.feed("main only");

    for ([_]u32{ LEGACY_SNAPSHOT_VERSION, SNAPSHOT_VERSION }) |version| {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        try serializeVersion(source.screen, &body, a, version);
        const offsets = try alternateStateOffsets(body.items);
        try testing.expectEqual(@as(u8, 0), body.items[offsets.has_alt]);
        try testing.expectEqual(@as(u8, 0), body.items[offsets.use_alt]);
        body.items[offsets.use_alt] = 1;

        var pool = try Pool.init(a);
        defer pool.deinit();
        const live = try initPopulatedLiveScreen(a, &pool);
        defer live.deinit();
        var before = try LiveRestoreState.capture(a, live, &pool);
        defer before.deinit(a);

        try testing.expectError(error.BadSnapshot, restoreStaged(a, &pool, body.items));
        try before.expectUnchanged(live, &pool);
        try expectLivePoolLookup(&pool);
    }
}

test "snapshot: every staged restore allocation failure preserves live state" {
    const a = testing.allocator;
    const snapshot_bytes = try makeFailureSnapshot(a);
    defer a.free(snapshot_bytes);

    const baseline = try runRestoreAllocationFailure(snapshot_bytes, null);
    try testing.expect(baseline.restore_end > baseline.first);
    try testing.expect(baseline.end > baseline.restore_end);
    for (baseline.first..baseline.end) |fail_index| {
        _ = try runRestoreAllocationFailure(snapshot_bytes, fail_index);
    }
}

test "restore rebuilds the pool index: colours don't swap after a resize" {
    const a = testing.allocator;
    const Entry = style_pool.Entry;

    // Source screen: green THEN red, so its pool orders green at a lower
    // slot than red. The snapshot serializes that order.
    var h = try Harness.init(a, 10, 2);
    defer h.deinit();
    h.feed("\x1b[32mG\x1b[0m\x1b[31mR\x1b[0m");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(h.screen, &buf, a);

    const green = h.pool.get(h.screen.active[0].cells[0].style_ref);
    const red = h.pool.get(h.screen.active[0].cells[1].style_ref);
    try testing.expect(!Entry.equal(green, red));

    // Target pool pre-populated in the OPPOSITE order (red before green),
    // exactly like a GUI pool reused across a resize: its dedup index now
    // disagrees with the snapshot's slot ordering.
    var p = try Pool.init(a);
    defer p.deinit();
    _ = try p.intern(red);
    _ = try p.intern(green);

    const back = try restore(a, &p, buf.items);
    defer back.deinit();

    // The bug: a stale index made the next intern of a colour return the
    // wrong slot (green -> red). After restore, interning a colour must
    // land on a slot that actually holds it, with no duplicate appended.
    try testing.expect(Entry.equal(p.get(try p.intern(green)), green));
    try testing.expect(Entry.equal(p.get(try p.intern(red)), red));
    try testing.expectEqual(h.pool.entries.items.len, p.entries.items.len);
}

test "snapshot: populated screen round-trips" {
    const a = testing.allocator;
    var h = try Harness.init(a, 20, 6);
    defer h.deinit();
    const screen = h.screen;

    // Content with styles, a title, scrollback spill, and modes.
    h.feed("\x1b[31mred\x1b[0m plain\r\n");
    h.feed("\x1b[1;4:3;58:2::10:20:30mfancy\x1b[0m\r\n");
    var i: usize = 0;
    while (i < 10) : (i += 1) h.feed("scroll line\r\n");
    h.feed("\x1b]0;snap title\x07");
    h.feed("\x1b[?2004h");
    h.feed("\x1b]8;;https://sker.dev\x07link\x1b]8;;\x07");
    h.feed("\r\x1b]133;A\x07\x1b]133;C\x07command output\r\n\x1b]133;D;7\x07");
    h.feed("\x1b]133;C\x07");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(screen, &buf, a);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();

    try testing.expectEqual(screen.cols, back.cols);
    try testing.expectEqual(screen.rows, back.rows);
    try testing.expectEqual(screen.row, back.row);
    try testing.expectEqual(screen.col, back.col);
    try testing.expectEqual(screen.scrollbackCount(), back.scrollbackCount());
    try testing.expectEqual(screen.bracketed_paste, back.bracketed_paste);
    try testing.expectEqual(screen.pending_output_start_id, back.pending_output_start_id);
    try testing.expectEqual(screen.pending_output_awaits_nl, back.pending_output_awaits_nl);
    try testing.expectEqual(screen.last_output_start_id, back.last_output_start_id);
    try testing.expectEqual(screen.last_output_end_id, back.last_output_end_id);
    try testing.expectEqual(screen.last_cmd_exit, back.last_cmd_exit);
    try testing.expectEqual(screen.cmd_completion_seq, back.cmd_completion_seq);
    try testing.expectEqualStrings("snap title", back.last_title.?);
    try testing.expectEqual(h.pool.entries.items.len, pool2.entries.items.len);

    // Cell-exact grid equality, active + scrollback.
    for (screen.active, back.active) |*orig, *got| {
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(orig.cells), std.mem.sliceAsBytes(got.cells));
        try testing.expectEqual(orig.id, got.id);
        try testing.expectEqual(orig.continues_above, got.continues_above);
    }
    var sb: u32 = 0;
    while (sb < screen.scrollbackCount()) : (sb += 1) {
        const orig = screen.scrollbackLine(sb);
        const got = back.scrollbackLine(sb);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(orig.cells), std.mem.sliceAsBytes(got.cells));
    }

    // Link table survived.
    try testing.expectEqual(screen.links.count(), back.links.count());

    // Extracted text identical (belt + suspenders over the cell dump).
    const txt_a = try screen.extractScreen(a);
    defer a.free(txt_a);
    const txt_b = try back.extractScreen(a);
    defer a.free(txt_b);
    try testing.expectEqualStrings(txt_a, txt_b);
}

test "snapshot: v8 interpreter state stays aligned after attach" {
    const a = testing.allocator;
    var h = try Harness.init(a, 16, 6);
    defer h.deinit();

    h.feed("\x1b]0;base title\x07\x1b[22t\x1b]0;inner title\x07");
    h.feed("\x1b]8;;https://main.invalid\x07\x1b[31m\x1b(0\x1b[?7l\x1b[?6h\x1b[3;4H");
    h.feed("\x1b[>5u\x1b[?1049h");
    h.feed("\x1b]8;;https://alt.invalid\x07\x1b[32m\x1b)0\x0e\x1b[?7h\x1b[?6l");
    h.feed("\x1b[3g\x1b[6G\x1bH\x1b[1G\x1b[>3u\x1b[?5h\x1b[?40h\x1b[>4;2mR\r");
    h.feed("\x1b]133;A\x07");

    try testing.expect(h.screen.use_alt);
    try testing.expectEqual(@as(u8, 3), h.screen.kitty_kbd_flags);
    try testing.expectEqual(@as(u8, 5), h.screen.kitty_kbd_other_flags);
    try testing.expectEqual(@as(u16, 1), h.screen.prompt_marks_head);
    const main_row = h.screen.saved_row;
    const main_col = h.screen.saved_col;
    const main_style = h.screen.saved_style;
    const main_link = h.screen.saved_link_id;
    const alt_style = h.screen.cur_style;
    const alt_link = h.screen.current_link_id;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try serialize(h.screen, &body, a);
    var client_pool = try Pool.init(a);
    defer client_pool.deinit();
    const client = try restore(a, &client_pool, body.items);
    defer client.deinit();
    try expectScreensEqual(h.screen, client);

    var pair = PairFeeder.init(a, h.screen, client);
    defer pair.deinit();

    // Current G1 graphics and OSC 8 state affect the first post-attach
    // glyph before any restore operation runs.
    pair.feed("q");
    try expectScreensEqual(h.screen, client);
    try testing.expectEqual(@as(u32, 0x2500), client.alt.?[0].cells[0].rune);
    try testing.expectEqual(alt_style, client.alt.?[0].cells[0].style_ref);
    try testing.expectEqual(alt_link, client.alt.?[0].cells[0].reserved);

    // Explicit DECRC must restore every saved field, not merely row/col.
    pair.feed("\x1b8");
    try expectScreensEqual(h.screen, client);
    try testing.expectEqual(main_row, client.row);
    try testing.expectEqual(main_col, client.col);
    try testing.expectEqual(main_style, client.cur_style);
    try testing.expectEqual(main_link, client.current_link_id);
    try testing.expect(client.origin_mode);
    try testing.expect(!client.autowrap);
    try testing.expectEqual(Screen.Charset.dec_graphics, client.charset_g0);

    // Restore a stacked title, then REP the carried last-glyph context.
    pair.feed("\x1b[23t\x1b[2b");
    try expectScreensEqual(h.screen, client);
    try testing.expectEqualStrings("base title", client.last_title.?);

    // HT must use the custom stop at zero-based column 5.
    pair.feed("\r\t");
    try expectScreensEqual(h.screen, client);
    try testing.expectEqual(@as(u16, 5), client.col);

    // Pop the alt-screen keyboard stack, then leave via 1049. The
    // parked main keyboard state and DECSC state must both return.
    pair.feed("\x1b[<1u\x1b[?1049l");
    try expectScreensEqual(h.screen, client);
    try testing.expect(!client.use_alt);
    try testing.expectEqual(@as(u8, 5), client.kitty_kbd_flags);
    try testing.expectEqual(main_row, client.row);
    try testing.expectEqual(main_col, client.col);
    try testing.expectEqual(main_style, client.cur_style);
    try testing.expectEqual(main_link, client.current_link_id);
    try testing.expect(client.origin_mode);
    try testing.expect(!client.autowrap);
    try testing.expectEqual(Screen.Charset.dec_graphics, client.charset_g0);
    try testing.expectEqual(Screen.ActiveCharset.g0, client.active_charset);

    // The restored style, DEC graphics designation, and OSC 8 link all
    // affect the first main-screen glyph emitted after leaving the alt.
    pair.feed("q");
    try expectScreensEqual(h.screen, client);
    const restored_cell = client.active[main_row].cells[main_col];
    try testing.expectEqual(@as(u32, 0x2500), restored_cell.rune);
    try testing.expectEqual(main_style, restored_cell.style_ref);
    try testing.expectEqual(main_link, restored_cell.reserved);
}

fn runSingleShiftSnapshotCase(shift: []const u8) !void {
    const a = testing.allocator;
    var h = try Harness.init(a, 8, 2);
    defer h.deinit();
    h.feed("\x1b(0");
    h.feed(shift);
    try testing.expect(h.screen.pending_single_shift != .none);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try serialize(h.screen, &body, a);
    var client_pool = try Pool.init(a);
    defer client_pool.deinit();
    const client = try restore(a, &client_pool, body.items);
    defer client.deinit();
    try expectScreensEqual(h.screen, client);

    var pair = PairFeeder.init(a, h.screen, client);
    defer pair.deinit();
    pair.feed("q");
    try expectScreensEqual(h.screen, client);
    try testing.expectEqual(Screen.PendingSingleShift.none, client.pending_single_shift);
    try testing.expectEqual(@as(u32, 'q'), client.active[0].cells[0].rune);
}

test "snapshot: SS2 and SS3 survive until the next printable event" {
    try runSingleShiftSnapshotCase("\x1bN");
    try runSingleShiftSnapshotCase("\x1bO");
}

test "snapshot: partial UTF-8 decode resumes after attach" {
    const a = testing.allocator;
    var h = try Harness.init(a, 8, 2);
    defer h.deinit();
    h.feed("A\xe2");
    try testing.expectEqual(@as(u3, 3), h.screen.decoder.expected);
    try testing.expectEqual(@as(u3, 1), h.screen.decoder.have);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try serialize(h.screen, &body, a);
    var client_pool = try Pool.init(a);
    defer client_pool.deinit();
    const client = try restore(a, &client_pool, body.items);
    defer client.deinit();
    try expectScreensEqual(h.screen, client);

    var pair = PairFeeder.init(a, h.screen, client);
    defer pair.deinit();
    pair.feed("\x82\xac");
    try expectScreensEqual(h.screen, client);
    try testing.expectEqual(@as(u32, 0x20ac), client.active[0].cells[1].rune);
    try testing.expectEqual(@as(u3, 0), client.decoder.expected);
}

test "snapshot: v3 payload (no command tail) restores with defaults" {
    const a = testing.allocator;
    var h = try Harness.init(a, 20, 6);
    defer h.deinit();
    h.feed("\x1b]133;A\x07\x1b]133;C\x07out\r\n\x1b]133;D;7\x07");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, 4);

    // A v3 payload is exactly a v4 one without the 37-byte command
    // tail — chop it off and stamp version 3.
    const tail = V4_COMMAND_TAIL_LEN;
    const legacy = try a.dupe(u8, buf.items[0 .. buf.items.len - tail]);
    defer a.free(legacy);
    std.mem.writeInt(u32, legacy[0..4], 3, .little);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, legacy);
    defer back.deinit();
    try testing.expectEqual(@as(u64, 0), back.cmd_completion_seq);
    try testing.expectEqual(@as(i32, 0), back.last_cmd_exit);
    try testing.expectEqual(@as(u64, 0), back.last_output_start_id);

    // And a v4 payload with the tail MISSING is corrupt, not v3.
    var pool3 = try Pool.init(a);
    defer pool3.deinit();
    try testing.expectError(error.Truncated, restore(a, &pool3, buf.items[0 .. buf.items.len - tail]));
}

test "snapshot: serializer targets v3 for legacy peers" {
    const a = testing.allocator;
    var h = try Harness.init(a, 8, 2);
    defer h.deinit();
    h.feed("legacy");
    h.screen.cmd_completion_seq = 42;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, LEGACY_SNAPSHOT_VERSION);
    try testing.expectEqual(LEGACY_SNAPSHOT_VERSION, std.mem.readInt(u32, buf.items[0..4], .little));

    var pool = try Pool.init(a);
    defer pool.deinit();
    const restored = try restore(a, &pool, buf.items);
    defer restored.deinit();
    try testing.expectEqual(@as(u64, 0), restored.cmd_completion_seq);
}

test "snapshot: v1 and v2 bodies remain readable" {
    const a = testing.allocator;
    var h = try Harness.init(a, 8, 2);
    defer h.deinit();
    h.feed("old");
    h.screen.mode_2031 = true;

    for ([_]u32{ 1, 2 }) |version| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try serializeVersion(h.screen, &buf, a, version);
        var pool = try Pool.init(a);
        defer pool.deinit();
        const restored = try restore(a, &pool, buf.items);
        defer restored.deinit();
        try testing.expect(!restored.mode_2031);
    }
}

test "snapshot: v7 interpreter omissions restore documented defaults" {
    const a = testing.allocator;
    var h = try Harness.init(a, 12, 3);
    defer h.deinit();
    h.feed("\x1b[31mX\x1b]8;;https://saved.invalid\x07");
    h.feed("\x1b]0;outer\x07\x1b[22t\x1b]0;inner\x07\x1b]133;A\x07");

    h.screen.saved_row = 2;
    h.screen.saved_col = 10;
    h.screen.saved_style = h.screen.cur_style;
    h.screen.saved_origin = true;
    h.screen.saved_autowrap = false;
    h.screen.saved_charset_g0 = .dec_graphics;
    h.screen.saved_charset_g1 = .dec_graphics;
    h.screen.saved_active_charset = .g1;
    h.screen.saved_link_id = h.screen.current_link_id;
    h.screen.charset_g0 = .dec_graphics;
    h.screen.charset_g1 = .dec_graphics;
    h.screen.active_charset = .g1;
    h.screen.pending_single_shift = .ss3;
    @memset(h.screen.tab_stops.items, false);
    h.screen.tab_stops.items[5] = true;
    h.screen.last_print_cp = 'Z';
    h.screen.last_print_key = 7;
    h.screen.decoder.expected = 3;
    h.screen.decoder.have = 1;
    h.screen.decoder.buf = 2;
    h.screen.modify_other_keys = 2;
    h.screen.reverse_screen = true;
    h.screen.allow_decolm = true;
    h.screen.kitty_kbd_flags = 7;
    h.screen.kitty_kbd_depth = 2;
    h.screen.kitty_kbd_stack = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    h.screen.kitty_kbd_other_flags = 9;
    h.screen.kitty_kbd_other_depth = 1;
    h.screen.kitty_kbd_other_stack = .{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try serializeVersion(h.screen, &body, a, 7);
    var pool = try Pool.init(a);
    defer pool.deinit();
    const restored = try restore(a, &pool, body.items);
    defer restored.deinit();

    try testing.expectEqual(@as(u16, 0), restored.saved_row);
    try testing.expectEqual(@as(u16, 0), restored.saved_col);
    try testing.expectEqual(@as(u16, 0), restored.saved_style);
    try testing.expect(!restored.saved_origin);
    try testing.expect(restored.saved_autowrap);
    try testing.expectEqual(Screen.Charset.ascii, restored.saved_charset_g0);
    try testing.expectEqual(Screen.Charset.ascii, restored.saved_charset_g1);
    try testing.expectEqual(Screen.ActiveCharset.g0, restored.saved_active_charset);
    try testing.expectEqual(@as(u8, 0), restored.saved_link_id);
    try testing.expectEqual(Screen.Charset.ascii, restored.charset_g0);
    try testing.expectEqual(Screen.Charset.ascii, restored.charset_g1);
    try testing.expectEqual(Screen.ActiveCharset.g0, restored.active_charset);
    try testing.expectEqual(Screen.PendingSingleShift.none, restored.pending_single_shift);
    for (restored.tab_stops.items, 0..) |stop, idx| {
        try testing.expectEqual(idx != 0 and idx % 8 == 0, stop);
    }
    try testing.expectEqual(@as(u32, 0), restored.last_print_cp);
    try testing.expectEqual(@as(u32, 0), restored.last_print_key);
    try testing.expectEqual(@as(u3, 0), restored.decoder.expected);
    try testing.expectEqual(@as(u3, 0), restored.decoder.have);
    try testing.expectEqual(@as(u32, 0), restored.decoder.buf);
    try testing.expectEqual(@as(u8, 0), restored.modify_other_keys);
    try testing.expect(!restored.reverse_screen);
    try testing.expect(!restored.allow_decolm);
    try testing.expectEqual(@as(u8, 0), restored.kitty_kbd_flags);
    try testing.expectEqual(@as(u8, 0), restored.kitty_kbd_depth);
    try testing.expectEqual(@as(u8, 0), restored.kitty_kbd_other_flags);
    try testing.expectEqual(@as(u8, 0), restored.kitty_kbd_other_depth);
    try testing.expectEqual(@as(u8, 0), restored.title_stack_depth);
    try testing.expectEqual(restored.prompt_marks_len, restored.prompt_marks_head);
}

test "snapshot: a short tab_stops array normalizes instead of failing" {
    const a = testing.allocator;
    var h = try Harness.init(a, 80, 24);
    defer h.deinit();

    // Exactly the state a swallowed allocation failure in Screen.resize
    // used to leave behind. Refusing to encode it froze every viewer of
    // the session permanently, because events stay withheld until a
    // snapshot succeeds.
    h.screen.tab_stops.items[16] = true;
    h.screen.tab_stops.shrinkRetainingCapacity(20);
    try testing.expect(h.screen.tab_stops.items.len != h.screen.cols);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try serializeVersion(h.screen, &body, a, SNAPSHOT_VERSION);
    var pool = try Pool.init(a);
    defer pool.deinit();
    const restored = try restore(a, &pool, body.items);
    defer restored.deinit();

    try testing.expectEqual(h.screen.cols, @as(u16, @intCast(restored.tab_stops.items.len)));
    for (restored.tab_stops.items, 0..) |stop, idx| {
        const expected = if (idx < 20) (idx == 16 or (idx != 0 and idx % 8 == 0)) else (idx != 0 and idx % 8 == 0);
        try testing.expectEqual(expected, stop);
    }
}

test "snapshot: an unset title stack slot encodes as empty" {
    const a = testing.allocator;
    var h = try Harness.init(a, 80, 24);
    defer h.deinit();

    h.screen.title_stack_depth = 1;
    h.screen.title_stack[0] = null;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try serializeVersion(h.screen, &body, a, SNAPSHOT_VERSION);
    var pool = try Pool.init(a);
    defer pool.deinit();
    const restored = try restore(a, &pool, body.items);
    defer restored.deinit();

    try testing.expectEqual(@as(u8, 1), restored.title_stack_depth);
    try testing.expectEqualStrings("", restored.title_stack[0].?);
}

test "snapshot: envelope detects pre-v4 and current headers" {
    var legacy: [12]u8 = @splat(0);
    std.mem.writeInt(u64, legacy[0..8], 17, .little);
    std.mem.writeInt(u32, legacy[8..12], LEGACY_SNAPSHOT_VERSION, .little);
    const old = try peelEnvelope(&legacy);
    try testing.expectEqual(@as(u64, 17), old.seq);
    try testing.expect(!old.app);
    try testing.expectEqualSlices(u8, legacy[8..], old.body);

    var current: [13]u8 = @splat(0);
    std.mem.writeInt(u64, current[0..8], 23, .little);
    current[8] = 1;
    std.mem.writeInt(u32, current[9..13], SNAPSHOT_VERSION, .little);
    const modern = try peelEnvelope(&current);
    try testing.expectEqual(@as(u64, 23), modern.seq);
    try testing.expect(modern.app);
    try testing.expectEqualSlices(u8, current[9..], modern.body);
}

test "snapshot: negotiation honors the peer maximum" {
    try testing.expectEqual(@as(u8, 3), negotiateVersion(6, 3, true));
    try testing.expectEqual(@as(u8, 4), negotiateVersion(6, 4, true));
    try testing.expectEqual(SNAPSHOT_VERSION, negotiateVersion(6, 255, true));
    try testing.expectEqual(@as(u8, 3), negotiateVersion(5, 0, false));
    try testing.expectEqual(@as(u8, 0), negotiateVersion(0, 4, true));
}

test "snapshot: transitional v4 legacy field is not an image count" {
    const a = testing.allocator;
    var h = try Harness.init(a, 20, 6);
    defer h.deinit();
    h.feed("legacy v4 screen\r\n");
    h.screen.pending_output_start_id = 111;
    h.screen.pending_output_awaits_nl = true;
    h.screen.last_output_start_id = 222;
    h.screen.last_output_end_id = 333;
    h.screen.last_cmd_exit = 7;
    h.screen.cmd_completion_seq = 444;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, 4);
    try testing.expectEqual(@as(usize, 0), h.screen.retained_images.items.len);

    // The transitional writer put a legacy non-zero u32 immediately before
    // the same 37-byte command tail. Reproduce a value observed in a live,
    // still-running daemon; the finalized writer has zero here (n_images).
    const legacy_field_pos = buf.items.len - V4_COMMAND_TAIL_LEN - @sizeOf(u32);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf.items[legacy_field_pos..][0..4], .little));
    std.mem.writeInt(u32, buf.items[legacy_field_pos..][0..4], 208, .little);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 0), back.retained_images.items.len);
    try testing.expectEqual(@as(u64, 111), back.pending_output_start_id);
    try testing.expect(back.pending_output_awaits_nl);
    try testing.expectEqual(@as(u64, 222), back.last_output_start_id);
    try testing.expectEqual(@as(u64, 333), back.last_output_end_id);
    try testing.expectEqual(@as(i32, 7), back.last_cmd_exit);
    try testing.expectEqual(@as(u64, 444), back.cmd_completion_seq);
}

test "snapshot: retained image placements round-trip" {
    const a = testing.allocator;
    var h = try Harness.init(a, 20, 6);
    defer h.deinit();
    h.screen.retain_images = true;

    // 1x1 RGBA kitty transmit+place (t=d, base64 of 4 bytes).
    h.feed("\x1b[3;4H"); // place at row 2, col 3 (0-based)
    h.feed("\x1b_Gf=32,s=1,v=1,t=d,a=T,i=9,p=2,z=5;/wAA/w==\x1b\\");
    try testing.expectEqual(@as(usize, 1), h.screen.retained_images.items.len);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(h.screen, &buf, a);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 1), back.retained_images.items.len);
    const ri = back.retained_images.items[0];
    try testing.expectEqual(@as(u32, 9), ri.ev.image_id);
    try testing.expectEqual(@as(u32, 2), ri.ev.placement_id);
    try testing.expectEqual(@as(i32, 5), ri.ev.z_index);
    try testing.expectEqual(@as(u16, 2), ri.ev.row);
    try testing.expectEqual(@as(u16, 3), ri.ev.col);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0, 0, 0xff }, ri.owned);

    // Delete prunes the retained copy too.
    h.feed("\x1b_Ga=d,d=I,i=9\x1b\\");
    try testing.expectEqual(@as(usize, 0), h.screen.retained_images.items.len);
}

test "snapshot: alt screen state survives" {
    const a = testing.allocator;
    var h = try Harness.init(a, 10, 4);
    defer h.deinit();
    const screen = h.screen;

    h.feed("main\r\n");
    h.feed("\x1b[?1049h"); // enter alt
    h.feed("altscreen");

    for ([_]u32{ LEGACY_SNAPSHOT_VERSION, SNAPSHOT_VERSION }) |version| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try serializeVersion(screen, &buf, a, version);

        var pool2 = try Pool.init(a);
        defer pool2.deinit();
        const back = try restore(a, &pool2, buf.items);
        defer back.deinit();

        try testing.expect(back.use_alt);
        try testing.expect(back.alt != null);
        const txt = try back.extractScreen(a);
        defer a.free(txt);
        try testing.expect(std.mem.indexOf(u8, txt, "altscreen") != null);
    }
}

test "snapshot: corrupt input errors cleanly" {
    const a = testing.allocator;
    var pool = try Pool.init(a);
    defer pool.deinit();
    // Empty.
    try testing.expectError(error.Truncated, restore(a, &pool, &.{}));
    // Bad version.
    var bad: [8]u8 = .{ 9, 9, 9, 9, 1, 0, 1, 0 };
    try testing.expectError(error.SnapshotVersionMismatch, restore(a, &pool, &bad));
    // Truncated mid-grid: serialize real state then chop it.
    var h = try Harness.init(a, 8, 3);
    defer h.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(h.screen, &buf, a);
    var pool3 = try Pool.init(a);
    defer pool3.deinit();
    try testing.expectError(error.Truncated, restore(a, &pool3, buf.items[0 .. buf.items.len / 2]));

    // Locate the first serialized cell and give it a style reference beyond
    // the advertised pool. Restore must reject it before render-side Pool.get.
    var src = Src{ .bytes = buf.items };
    _ = try src.int(u32); // version
    _ = try src.int(u16); // cols
    _ = try src.int(u16); // rows
    const n_styles = try src.int(u16);
    for (0..n_styles) |_| {
        _ = try src.color();
        _ = try src.color();
        _ = try src.color();
        _ = try src.int(u16);
    }
    _ = try src.int(u64);
    _ = try src.boolean();
    _ = try src.byte();
    _ = try src.int(u16);
    const style_off = src.pos + @offsetOf(Cell, "style_ref");
    std.mem.writeInt(u16, buf.items[style_off..][0..2], n_styles, .little);
    var pool4 = try Pool.init(a);
    defer pool4.deinit();
    try testing.expectError(error.BadSnapshot, restore(a, &pool4, buf.items));
}

test "snapshot: v8 validates saved indexes and tab-stop dimensions" {
    const a = testing.allocator;
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();
    h.feed("\x1b[31m\x1b]8;;https://saved.invalid\x07\x1b7");

    var v7: std.ArrayList(u8) = .empty;
    defer v7.deinit(a);
    try serializeVersion(h.screen, &v7, a, 7);
    var v8: std.ArrayList(u8) = .empty;
    defer v8.deinit(a);
    try serialize(h.screen, &v8, a);
    const tail = v7.items.len;
    try testing.expect(v8.items.len > tail + 18 + h.screen.cols);

    var pool = try Pool.init(a);
    defer pool.deinit();

    // saved_style is a pool index.
    const saved_style_offset = tail + 4;
    const saved_style = std.mem.readInt(u16, v8.items[saved_style_offset..][0..2], .little);
    std.mem.writeInt(u16, v8.items[saved_style_offset..][0..2], @intCast(h.pool.entries.items.len), .little);
    try testing.expectError(error.BadSnapshot, restore(a, &pool, v8.items));
    std.mem.writeInt(u16, v8.items[saved_style_offset..][0..2], saved_style, .little);

    // saved_link_id must be zero or resolve in the serialized link table.
    const saved_link_offset = tail + 11;
    const saved_link = v8.items[saved_link_offset];
    v8.items[saved_link_offset] = 254;
    try testing.expectError(error.BadSnapshot, restore(a, &pool, v8.items));
    v8.items[saved_link_offset] = saved_link;

    // The already-active link index is validated by the same rule.
    h.screen.current_link_id = 254;
    var bad_current_link: std.ArrayList(u8) = .empty;
    defer bad_current_link.deinit(a);
    try serialize(h.screen, &bad_current_link, a);
    try testing.expectError(error.BadSnapshot, restore(a, &pool, bad_current_link.items));
    h.screen.current_link_id = saved_link;

    // The tab array is dimensioned exactly to the restored grid.
    const tab_count_offset = tail + 16;
    std.mem.writeInt(u16, v8.items[tab_count_offset..][0..2], h.screen.cols - 1, .little);
    try testing.expectError(error.BadSnapshot, restore(a, &pool, v8.items));
    std.mem.writeInt(u16, v8.items[tab_count_offset..][0..2], h.screen.cols, .little);
    v8.items[tail + 18] = 2;
    try testing.expectError(error.BadSnapshot, restore(a, &pool, v8.items));
}

test "restore normalizes lines whose serialized width diverges from cols" {
    const a = testing.allocator;
    var wide: Cell = .{};
    wide.rune = 'W';
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    try w.writer.writeInt(u64, 7, .little); // id
    try w.writer.writeByte(0); // continues_above
    try w.writer.writeByte(0); // scaling
    try w.writer.writeInt(u16, 5, .little); // n_cells: wider than cols
    for (0..5) |_| try w.writer.writeAll(std.mem.asBytes(&wide));
    var src = Src{ .bytes = w.writer.buffered() };
    var narrow = try src.line(a, 3, 1);
    defer narrow.deinit(a);
    try testing.expectEqual(@as(usize, 3), narrow.cells.len);
    try testing.expectEqual(@as(u32, 'W'), narrow.cells[0].rune);

    var src2 = Src{ .bytes = w.writer.buffered() };
    var padded = try src2.line(a, 8, 1);
    defer padded.deinit(a);
    try testing.expectEqual(@as(usize, 8), padded.cells.len);
    try testing.expectEqual(@as(u32, 'W'), padded.cells[4].rune);
    try testing.expectEqual(@as(u32, 0), padded.cells[5].rune);
}

test "snapshot: glyph glossary round-trips with FIFO stamps" {
    const a = testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();

    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    const p1 = try a.dupe(u8, tri);
    try h.screen.glyphs.registerAdopt(0xE100, p1, .glyf, 1000, 1);
    const container = try gp.colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = gp.PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(container);
    const p2 = try a.dupe(u8, container);
    try h.screen.glyphs.registerAdopt(0xF0100, p2, .colrv0, 2048, 2);
    const solid = gp.V1Node{ .solid = .{ .palette = gp.PALETTE_FOREGROUND } };
    const v1_container = try gp.colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &solid },
    }, &.{}, null);
    defer a.free(v1_container);
    const p3 = try a.dupe(u8, v1_container);
    try h.screen.glyphs.registerAdopt(0x100100, p3, .colrv1, 1024, 1);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(h.screen, &buf, a);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 3), back.glyphs.count());
    const e3 = back.glyphs.get(0x100100).?;
    try testing.expectEqual(gp.Format.colrv1, e3.fmt);
    try testing.expectEqual(@as(u16, 1024), e3.upm);
    try testing.expectEqualSlices(u8, v1_container, e3.payload);
    const e1 = back.glyphs.get(0xE100).?;
    try testing.expectEqualSlices(u8, tri, e1.payload);
    try testing.expectEqual(@as(u16, 1000), e1.upm);
    try testing.expectEqual(@as(u8, 1), e1.width);
    try testing.expectEqual(gp.Format.glyf, e1.fmt);
    const e2 = back.glyphs.get(0xF0100).?;
    try testing.expectEqual(@as(u16, 2048), e2.upm);
    try testing.expectEqual(@as(u8, 2), e2.width);
    try testing.expectEqual(gp.Format.colrv0, e2.fmt);
    try testing.expectEqualSlices(u8, container, e2.payload);
    // FIFO order preserved across the round-trip.
    try testing.expect(e1.insertion < e2.insertion);
    // Render keys are freshly minted locally, never zero.
    try testing.expect(e1.render_key != 0 and e2.render_key != 0);
    try testing.expect(e1.render_key != e2.render_key);
}

test "snapshot: a v5 body carries only glyf entries (no format field to ride)" {
    const a = testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();

    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    const p1 = try a.dupe(u8, tri);
    try h.screen.glyphs.registerAdopt(0xE100, p1, .glyf, 1000, 1);
    const container = try gp.colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = gp.PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(container);
    const p2 = try a.dupe(u8, container);
    try h.screen.glyphs.registerAdopt(0xF0100, p2, .colrv0, 1000, 1);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, 5);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.glyphs.count());
    try testing.expect(back.glyphs.contains(0xE100));
    try testing.expect(!back.glyphs.contains(0xF0100));
}

test "snapshot: a v6 body withholds colrv1 entries (v6 peers reject tag 2)" {
    const a = testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();

    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    const p1 = try a.dupe(u8, tri);
    try h.screen.glyphs.registerAdopt(0xE100, p1, .glyf, 1000, 1);
    const container = try gp.colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = gp.PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(container);
    const p2 = try a.dupe(u8, container);
    try h.screen.glyphs.registerAdopt(0xF0100, p2, .colrv0, 1000, 1);
    const solid = gp.V1Node{ .solid = .{ .palette = gp.PALETTE_FOREGROUND } };
    const v1_container = try gp.colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &solid },
    }, &.{}, null);
    defer a.free(v1_container);
    const p3 = try a.dupe(u8, v1_container);
    try h.screen.glyphs.registerAdopt(0x100100, p3, .colrv1, 1000, 1);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, 6);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.glyphs.count());
    try testing.expect(back.glyphs.contains(0xE100));
    try testing.expect(back.glyphs.contains(0xF0100));
    try testing.expect(!back.glyphs.contains(0x100100));
}

test "snapshot: empty glossary costs 4 bytes; v4 bodies restore empty" {
    const a = testing.allocator;
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();

    var v4buf: std.ArrayList(u8) = .empty;
    defer v4buf.deinit(a);
    try serializeVersion(h.screen, &v4buf, a, 4);
    var v5buf: std.ArrayList(u8) = .empty;
    defer v5buf.deinit(a);
    try serializeVersion(h.screen, &v5buf, a, 5);
    // Only the u32 count separates an empty-glossary v5 from a v4.
    try testing.expectEqual(v4buf.items.len + 4, v5buf.items.len);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, v4buf.items);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 0), back.glyphs.count());
}

/// Append a codepoint's UTF-8 -- Kitty placeholder + diacritic helper.
fn appendCp(list: *std.ArrayList(u8), a: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try list.appendSlice(a, buf[0..n]);
}

test "snapshot: v9 zones, placeholder context and OSC state stay aligned after attach" {
    const a = testing.allocator;
    var h = try Harness.init(a, 20, 6);
    defer h.deinit();

    // Two completed OSC 133 zones, so the ring carries content AND a head.
    h.feed("\x1b]133;A\x07\x1b]133;C\x07one\r\n\x1b]133;D;0\x07");
    h.feed("\x1b]133;A\x07\x1b]133;C\x07two\r\n\x1b]133;D;3\x07");
    try testing.expectEqual(@as(u16, 2), h.screen.cmd_zones_len);

    // OSC 17/19 selection colors and two OSC 1337 user variables.
    h.feed("\x1b]17;rgb:ffff/0000/0000\x07\x1b]19;#00ff00\x07");
    h.feed("\x1b]1337;SetUserVar=branch=bWFpbg==\x07"); // "main"
    h.feed("\x1b]1337;SetUserVar=host=Ym94\x07"); // "box"
    try testing.expectEqual(@as(usize, 2), h.screen.user_vars.items.len);

    // A Kitty virtual placement, then a placeholder cell left MID-
    // ASSEMBLY: the base is printed and only its row diacritic has
    // arrived, so the next event decides which tile the cell shows.
    const rgba = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    };
    var b64_buf: [32]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &rgba);
    var tx_buf: [128]u8 = undefined;
    h.feed(try std.fmt.bufPrint(&tx_buf, "\x1b_Gi=5,a=T,U=1,f=32,s=2,v=2,c=2,r=2;{s}\x1b\\", .{b64}));
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(a);
    try seq.appendSlice(a, "\r\x1b[38;5;5m");
    try appendCp(&seq, a, 0x10EEEE);
    try appendCp(&seq, a, 0x0305); // image row 0
    h.feed(seq.items);
    try testing.expectEqual(@as(u32, 1), h.screen.virtual_placements.count());
    try testing.expect(h.screen.ph_pending != null);
    try testing.expectEqual(@as(u8, 1), h.screen.ph_pending.?.n_diac);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try serialize(h.screen, &body, a);
    var client_pool = try Pool.init(a);
    defer client_pool.deinit();
    const client = try restore(a, &client_pool, body.items);
    defer client.deinit();
    try expectScreensEqual(h.screen, client);

    var pair = PairFeeder.init(a, h.screen, client);
    defer pair.deinit();

    // The pending placeholder's column diacritic lands after attach.
    var post: std.ArrayList(u8) = .empty;
    defer post.deinit(a);
    try appendCp(&post, a, 0x030D); // image column 1
    try post.append(a, '\n');
    pair.feed(post.items);
    try expectScreensEqual(h.screen, client);
    try testing.expect(client.ph_pending == null);
    try testing.expectEqual(@as(u32, 5), client.ph_last.?.image_id);
    try testing.expectEqual(@as(u32, 1), client.ph_last.?.img_col);

    // A third command completes: it must land in the same ring slot on
    // both sides, which only works if the ring and head crossed.
    pair.feed("\x1b]133;A\x07\x1b]133;C\x07three\r\n\x1b]133;D;7\x07");
    try expectScreensEqual(h.screen, client);
    try testing.expectEqual(@as(u16, 3), client.cmd_zones_len);
    try testing.expectEqual(@as(i32, 7), client.cmdZone(0).?.exit);
    try testing.expectEqual(@as(i32, 3), client.cmdZone(1).?.exit);

    // Setting an EXISTING user variable overwrites; on a client that
    // never received it, the same bytes append a second entry instead.
    pair.feed("\x1b]1337;SetUserVar=branch=ZGV2\x07"); // "dev"
    try expectScreensEqual(h.screen, client);
    try testing.expectEqual(@as(usize, 2), client.user_vars.items.len);
    try testing.expectEqualStrings("dev", client.userVar("branch").?);

    // A second virtual placement merges with the carried one.
    var tx2_buf: [128]u8 = undefined;
    pair.feed(try std.fmt.bufPrint(&tx2_buf, "\x1b_Gi=6,a=T,U=1,f=32,s=2,v=2,c=2,r=2;{s}\x1b\\", .{b64}));
    try expectScreensEqual(h.screen, client);
    try testing.expectEqual(@as(u32, 2), client.virtual_placements.count());

    // OSC 117/119 reset to the unset sentinel from the CARRIED colors.
    try testing.expectEqual(@as(f32, 1.0), client.selection_bg[0]);
    try testing.expectEqual(@as(f32, 1.0), client.selection_fg[1]);
    pair.feed("\x1b]117\x07\x1b]119\x07");
    try expectScreensEqual(h.screen, client);
    try testing.expectEqual(@as(f32, 0.0), client.selection_bg[3]);
}

test "snapshot: a v9 body is refused by a v8 reader and truncation is Truncated" {
    const a = testing.allocator;
    var h = try Harness.init(a, 8, 2);
    defer h.deinit();
    h.feed("\x1b]133;A\x07\x1b]133;C\x07x\r\n\x1b]133;D;1\x07");

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try serialize(h.screen, &body, a);

    // A truncated tail is a short read, never garbage.
    var pool_short = try Pool.init(a);
    defer pool_short.deinit();
    try testing.expectError(error.Truncated, restore(a, &pool_short, body.items[0 .. body.items.len - 4]));

    // Restamping a v9 body as v8 must fail loudly: the v8 reader's
    // end-of-body check is what makes the version bump mandatory.
    const restamped = try a.dupe(u8, body.items);
    defer a.free(restamped);
    std.mem.writeInt(u32, restamped[0..4], 8, .little);
    var pool_v8 = try Pool.init(a);
    defer pool_v8.deinit();
    try testing.expectError(error.BadSnapshot, restore(a, &pool_v8, restamped));

    // And a genuine v8 body still restores through the v9 reader.
    var v8_body: std.ArrayList(u8) = .empty;
    defer v8_body.deinit(a);
    try serializeVersion(h.screen, &v8_body, a, 8);
    var pool_old = try Pool.init(a);
    defer pool_old.deinit();
    const old = try restore(a, &pool_old, v8_body.items);
    defer old.deinit();
    try testing.expectEqual(@as(u16, 0), old.cmd_zones_len);
}
