//! The sub-agent glance widgets: the pane titlebar chip, the tab badge
//! (strip and sidebar) and the state glyph they share with the agents
//! popover. Words, counts and colours come from `ipc/agentglance.zig`;
//! this file only builds and paints.
//!
//! Glyphs are drawn (cairo, in the widget's CSS `color`), so no icon theme
//! can lose them. A tab's badge state lives as qdata on its `AdwTabPage`,
//! like the tab effects: tab widgets are rebuilt on every structure change
//! while the page persists, and the qdata travels with a dragged tab.

const std = @import("std");
const c = @import("../c.zig").c;
const cssutil = @import("cssutil.zig");
const strz = @import("../util/strz.zig");
const glance = @import("../ipc/agentglance.zig");
const agentsline = @import("../ipc/agentsline.zig");
const vocab = @import("../agent/vocab.zig");
const Attention = vocab.Attention;
const Tally = glance.Tally;

/// Glyph edge in px; drawn on a 12-unit grid like the mockup.
const GLYPH_PX: c_int = 12;

/// The CSS class naming an attention's colours (`unknown` = an older
/// server's agent), for badges, pills and glyphs.
pub fn attentionClass(a: ?Attention) [*:0]const u8 {
    const at = a orelse return "sketerm-att-unknown";
    return switch (at) {
        inline else => |tag| "sketerm-att-" ++ @tagName(tag),
    };
}

fn hex(rgb: glance.Rgb) [7]u8 {
    var out: [7]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable;
    return out;
}

/// Every colour rule, generated from the one palette.
const CSS: [:0]const u8 = blk: {
    @setEvalBranchQuota(20_000);
    var s: []const u8 =
        \\.sketerm-agents-chip { margin: 0px 2px; padding: 0px; min-height: 0px; }
        \\.sketerm-agents-chip > button {
        \\    min-height: 16px;
        \\    padding: 0px 3px 0px 6px;
        \\    border-radius: 9px;
        \\    font-size: 11px;
        \\    font-weight: bold;
        \\    box-shadow: none;
        \\    border: none;
        \\
    // `background-image: none`: GTK's built-in theme (GTK_THEME set,
    // libadwaita's stylesheet off) paints buttons with an image, which
    // covered this white and left the dark text on a dark button.
    ++ "    background-image: none;\n" ++
        "    background-color: " ++ hex(glance.CHIP_BG) ++ ";\n" ++
        "    color: " ++ hex(glance.CHIP_FG) ++ ";\n}\n" ++
        ".sketerm-agents-chip > button:hover { background-image: none; background-color: #ececec; }\n" ++
        ".sketerm-agents-chip.sketerm-agents-idle > button { color: " ++ hex(glance.CHIP_FG_IDLE) ++ "; }\n" ++
        \\.sketerm-agents-pill { border-radius: 7px; padding: 0px 5px; margin-left: 2px; }
        \\.sketerm-agents-badge {
        \\    border-radius: 8px;
        \\    padding: 0px 6px 0px 4px;
        \\    margin: 0px 2px;
        \\    font-size: 11px;
        \\    font-weight: bold;
        \\}
        \\
    ;
    const atts = [_]?Attention{ null, .needs_input, .lost, .working, .idle };
    for (atts) |a| {
        const sw = glance.swatch(a);
        const cls = std.mem.span(attentionClass(a));
        s = s ++ "." ++ cls ++ ".sketerm-agents-pill, ." ++ cls ++ ".sketerm-agents-badge { background-color: " ++
            hex(sw.bg) ++ "; color: " ++ hex(sw.fg) ++ "; }\n";
        s = s ++ ".sketerm-glyph-chip." ++ cls ++ " { color: " ++ hex(glance.glyphOnChip(a)) ++ "; }\n";
    }
    const final = s ++ "\x00";
    break :blk final[0..s.len :0];
};

pub fn installCss(widget: ?*c.GtkWidget) void {
    cssutil.install("agentbadge", widget, CSS);
}

// ── the glyph ──────────────────────────────────────────────────────

/// Where a glyph takes its colour from: the white chip, the theme's
/// semantic colours (a popover row, light or dark), or its parent (a
/// badge's text colour).
pub const GlyphOn = enum { chip, theme, inherit };

/// The libadwaita style class carrying an attention's semantic colour,
/// for surfaces that follow the theme (the agents popover).
pub fn themeClass(a: ?Attention) [*:0]const u8 {
    const at = a orelse return "dim-label";
    return switch (at) {
        .working => "accent",
        .needs_input => "warning",
        .lost => "error",
        .idle => "dim-label",
    };
}

/// A drawn state glyph: dashed ring (working), circled `!` (needs input),
/// cross (disconnected), check (idle), dot (unknown).
pub fn newGlyph(a: ?Attention, on: GlyphOn) *c.GtkWidget {
    const area = c.gtk_drawing_area_new().?;
    c.gtk_drawing_area_set_content_width(@ptrCast(area), GLYPH_PX);
    c.gtk_drawing_area_set_content_height(@ptrCast(area), GLYPH_PX);
    c.gtk_widget_set_valign(area, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_can_target(area, 0);
    switch (on) {
        .chip => c.gtk_widget_add_css_class(area, "sketerm-glyph-chip"),
        .theme => c.gtk_widget_add_css_class(area, themeClass(a)),
        .inherit => {},
    }
    c.gtk_widget_add_css_class(area, attentionClass(a));
    // The kind rides in the user-data pointer itself: nothing to own.
    c.gtk_drawing_area_set_draw_func(@ptrCast(area), &drawGlyph, glyphData(a), null);
    return area;
}

pub fn setGlyph(area: *c.GtkWidget, old: ?Attention, a: ?Attention) void {
    if (old == a) return;
    c.gtk_widget_remove_css_class(area, attentionClass(old));
    c.gtk_widget_add_css_class(area, attentionClass(a));
    c.gtk_drawing_area_set_draw_func(@ptrCast(area), &drawGlyph, glyphData(a), null);
    c.gtk_widget_queue_draw(area);
}

fn glyphData(a: ?Attention) ?*anyopaque {
    const code: usize = if (a) |at| @as(usize, @intFromEnum(at)) + 1 else 0;
    // Offset so code 0 is still a non-null pointer.
    return @ptrFromInt(code + 0x10);
}

fn drawGlyph(area: [*c]c.GtkDrawingArea, cr: ?*c.cairo_t, w: c_int, h: c_int, user: ?*anyopaque) callconv(.c) void {
    const code = @intFromPtr(user) - 0x10;
    var rgba: c.GdkRGBA = undefined;
    c.gtk_widget_get_color(@ptrCast(area), &rgba);
    c.cairo_set_source_rgba(cr, rgba.red, rgba.green, rgba.blue, rgba.alpha);
    // A 12-unit grid centred in the allocation.
    const side = @as(f64, @floatFromInt(@min(w, h)));
    const ox = (@as(f64, @floatFromInt(w)) - side) / 2;
    const oy = (@as(f64, @floatFromInt(h)) - side) / 2;
    const u = side / 12.0;
    const P = struct {
        fn at(cx: ?*c.cairo_t, x0: f64, y0: f64, unit: f64, x: f64, y: f64, line: bool) void {
            if (line) c.cairo_line_to(cx, x0 + x * unit, y0 + y * unit) else c.cairo_move_to(cx, x0 + x * unit, y0 + y * unit);
        }
    };
    c.cairo_set_line_width(cr, 1.6 * u);
    c.cairo_set_line_cap(cr, @intCast(c.CAIRO_LINE_CAP_ROUND));
    if (code == 0) {
        c.cairo_arc(cr, ox + 6 * u, oy + 6 * u, 2.5 * u, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
        return;
    }
    const a: Attention = @enumFromInt(code - 1);
    switch (a) {
        .working => {
            const dash = [_]f64{ 6 * u, 3 * u };
            c.cairo_set_dash(cr, &dash, dash.len, 0);
            c.cairo_arc(cr, ox + 6 * u, oy + 6 * u, 4.2 * u, 0, 2 * std.math.pi);
            c.cairo_stroke(cr);
        },
        .needs_input => {
            c.cairo_arc(cr, ox + 6 * u, oy + 6 * u, 4.6 * u, 0, 2 * std.math.pi);
            c.cairo_stroke(cr);
            P.at(cr, ox, oy, u, 6, 3.6, false);
            P.at(cr, ox, oy, u, 6, 6.4, true);
            P.at(cr, ox, oy, u, 6, 8.3, false);
            P.at(cr, ox, oy, u, 6, 8.4, true);
            c.cairo_stroke(cr);
        },
        .lost => {
            P.at(cr, ox, oy, u, 3.5, 3.5, false);
            P.at(cr, ox, oy, u, 8.5, 8.5, true);
            P.at(cr, ox, oy, u, 8.5, 3.5, false);
            P.at(cr, ox, oy, u, 3.5, 8.5, true);
            c.cairo_stroke(cr);
        },
        .idle => {
            P.at(cr, ox, oy, u, 2.5, 6.2, false);
            P.at(cr, ox, oy, u, 4.8, 8.5, true);
            P.at(cr, ox, oy, u, 9.5, 3.5, true);
            c.cairo_stroke(cr);
        },
    }
}

// ── the pane titlebar chip ─────────────────────────────────────────

/// White pill: glyph, "N agents ...", and an attention pill. A menu
/// button, so the popover it opens is parented and torn down by GTK.
pub const Chip = struct {
    button: *c.GtkWidget,
    glyph: *c.GtkWidget,
    label: *c.GtkWidget,
    pill: *c.GtkWidget,
    popover: *c.GtkWidget,
    /// What is painted now; an equal tally touches no widget.
    shown: Tally = .{},
    glyph_att: ?Attention = null,
    pill_att: ?Attention = null,

    pub fn build() Chip {
        const button = c.gtk_menu_button_new().?;
        c.gtk_widget_add_css_class(button, "sketerm-agents-chip");
        c.gtk_widget_set_valign(button, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_visible(button, 0);
        c.gtk_widget_set_can_focus(button, 0);
        installCss(button);
        const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4).?;
        const glyph = newGlyph(null, .chip);
        c.gtk_box_append(@ptrCast(box), glyph);
        const label = c.gtk_label_new("").?;
        c.gtk_box_append(@ptrCast(box), label);
        const pill = c.gtk_label_new("").?;
        c.gtk_widget_add_css_class(pill, "sketerm-agents-pill");
        c.gtk_widget_add_css_class(pill, attentionClass(null));
        c.gtk_widget_set_visible(pill, 0);
        c.gtk_box_append(@ptrCast(box), pill);
        c.gtk_menu_button_set_child(@ptrCast(button), box);
        const popover = c.gtk_popover_new().?;
        c.gtk_popover_set_position(@ptrCast(popover), c.GTK_POS_BOTTOM);
        c.gtk_menu_button_set_popover(@ptrCast(button), popover);
        return .{ .button = button, .glyph = glyph, .label = label, .pill = pill, .popover = popover };
    }

    /// Paint `t`; hidden at zero. @return whether anything changed.
    pub fn set(self: *Chip, t: Tally) bool {
        if (self.shown.eql(t)) return false;
        self.shown = t;
        var buf: [64]u8 = undefined;
        const parts = glance.chip(t, &buf) orelse {
            c.gtk_widget_set_visible(self.button, 0);
            if (c.gtk_widget_get_visible(self.popover) != 0) c.gtk_popover_popdown(@ptrCast(self.popover));
            return true;
        };
        var z: [72:0]u8 = undefined;
        c.gtk_label_set_text(@ptrCast(self.label), strz.copyZ(&z, parts.text));
        setGlyph(self.glyph, self.glyph_att, parts.glyph);
        self.glyph_att = parts.glyph;
        const all_idle = t.count(.idle) == t.total;
        if (all_idle) c.gtk_widget_add_css_class(self.button, "sketerm-agents-idle") else c.gtk_widget_remove_css_class(self.button, "sketerm-agents-idle");
        if (parts.pill) |p| {
            var pbuf: [32]u8 = undefined;
            var pz: [40:0]u8 = undefined;
            c.gtk_label_set_text(@ptrCast(self.pill), strz.copyZ(&pz, p.text(&pbuf)));
            c.gtk_widget_remove_css_class(self.pill, attentionClass(self.pill_att));
            c.gtk_widget_add_css_class(self.pill, attentionClass(p.attention));
            self.pill_att = p.attention;
            c.gtk_widget_set_visible(self.pill, 1);
        } else c.gtk_widget_set_visible(self.pill, 0);
        // The tooltip is `sketerm mcp agents`'s line: one wording.
        var tip: [160:0]u8 = undefined;
        var w: std.Io.Writer = .fixed(tip[0 .. tip.len - 1]);
        const summary: agentsline.Summary = .{ .tally = t };
        agentsline.renderText(&w, &summary, .line, false, false) catch {};
        const line = std.mem.trimEnd(u8, w.buffered(), "\n");
        tip[line.len] = 0;
        c.gtk_widget_set_tooltip_text(self.button, tip[0..line.len :0].ptr);
        c.gtk_widget_set_visible(self.button, 1);
        return true;
    }
};

// ── the tab badge ──────────────────────────────────────────────────

const PAGE_KEY = "sketerm-tab-agents";
const STORED: usize = 1 << 40;

/// What a tab's badge shows: the total over its panes and the most
/// urgent attention among them.
pub const PageGlance = struct {
    total: u32 = 0,
    urgent: ?Attention = null,

    pub fn of(t: Tally) PageGlance {
        return .{ .total = t.total, .urgent = t.mostUrgent() };
    }
};

pub fn pageGlance(page: *c.AdwTabPage) PageGlance {
    const d = c.g_object_get_data(@ptrCast(@alignCast(page)), PAGE_KEY) orelse return .{};
    const bits = @intFromPtr(d);
    const code = (bits >> 32) & 0xff;
    return .{
        .total = @truncate(bits),
        .urgent = if (code == 0) null else @as(Attention, @enumFromInt(code - 1)),
    };
}

/// @return whether it changed (the caller repaints the tab's badges).
pub fn setPageGlance(page: *c.AdwTabPage, g: PageGlance) bool {
    if (std.meta.eql(pageGlance(page), g)) return false;
    const code: usize = if (g.urgent) |a| @as(usize, @intFromEnum(a)) + 1 else 0;
    const bits = STORED | (code << 32) | g.total;
    c.g_object_set_data(@ptrCast(@alignCast(page)), PAGE_KEY, @ptrFromInt(bits));
    return true;
}

/// A pill with the most urgent attention's colours and the total.
pub const Badge = struct {
    box: *c.GtkWidget,
    glyph: *c.GtkWidget,
    label: *c.GtkWidget,
    shown: PageGlance = .{},
    /// The attention its colours and glyph show now.
    att: ?Attention = null,

    pub fn build(g: PageGlance) Badge {
        const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 3).?;
        c.gtk_widget_add_css_class(box, "sketerm-agents-badge");
        c.gtk_widget_add_css_class(box, attentionClass(null));
        c.gtk_widget_set_valign(box, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_can_target(box, 0);
        c.gtk_widget_set_visible(box, 0);
        installCss(box);
        const glyph = newGlyph(null, .inherit);
        c.gtk_box_append(@ptrCast(box), glyph);
        const label = c.gtk_label_new("").?;
        c.gtk_box_append(@ptrCast(box), label);
        var b: Badge = .{ .box = box, .glyph = glyph, .label = label };
        b.paint(g);
        return b;
    }

    pub fn set(self: *Badge, g: PageGlance) void {
        if (std.meta.eql(self.shown, g)) return;
        self.paint(g);
    }

    fn paint(self: *Badge, g: PageGlance) void {
        self.shown = g;
        if (g.total == 0) {
            c.gtk_widget_set_visible(self.box, 0);
            return;
        }
        var z: [16:0]u8 = undefined;
        var num: [16]u8 = undefined;
        c.gtk_label_set_text(@ptrCast(self.label), strz.copyZ(&z, std.fmt.bufPrint(&num, "{d}", .{g.total}) catch "?"));
        if (self.att != g.urgent) {
            c.gtk_widget_remove_css_class(self.box, attentionClass(self.att));
            c.gtk_widget_add_css_class(self.box, attentionClass(g.urgent));
            setGlyph(self.glyph, self.att, g.urgent);
            self.att = g.urgent;
        }
        var tip: [96:0]u8 = undefined;
        const tz = if (g.urgent) |a|
            std.fmt.bufPrintZ(&tip, "{d} agent(s); most urgent: {s}", .{ g.total, a.label() }) catch null
        else
            std.fmt.bufPrintZ(&tip, "{d} agent(s)", .{g.total}) catch null;
        if (tz) |t| c.gtk_widget_set_tooltip_text(self.box, t.ptr);
        c.gtk_widget_set_visible(self.box, 1);
    }
};

