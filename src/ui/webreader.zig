//! Reader mode's presentation half: a parsed Markdown `Doc`
//! (`src/util/markdown.zig`) rendered into a `GtkTextView`.
//!
//! The article text comes from the same `sem_read` extraction the
//! `web_read` MCP tool uses, so a human and an assistant read exactly
//! the same thing. It is rendered with GTK text tags rather than loaded
//! back into the engine as a `data:` URL, because a reader that
//! navigates would throw away the live page's state and write junk into
//! its history — the page must stay untouched underneath so that
//! leaving reader mode is a widget-visibility flip and nothing else.
//!
//! Lifetimes: the reader owns no signal on a widget it does not own,
//! and the controllers it does add carry it as user-data with NO
//! GDestroyNotify. `sever` (mechanism 2 in CLAUDE.md) is the single
//! choke point that disconnects them, called from the face's own
//! prepare-destroy; `destroy` then frees the struct.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const cssutil = @import("cssutil.zig");
const markdown = @import("../util/markdown.zig");

/// Reading measure: the width the article text is clamped to, in
/// logical px. Wider than this and the eye loses the line start.
const MEASURE: c_int = 700;

/// A link's extent in the buffer, in CHARACTER offsets (what
/// `gtk_text_iter_get_offset` reports), plus its resolved absolute URL.
const LinkRange = struct {
    start: c_int,
    end: c_int,
    url: []u8,
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    /// The scrolled window the face puts in its widget tree.
    root: *c.GtkWidget,
    view: *c.GtkWidget,
    links: std.ArrayList(LinkRange) = .empty,
    /// Objects whose signals carry this reader as user-data.
    signal_objs: [4]?*c.GObject = .{null} ** 4,
    signal_count: usize = 0,
    widgets_dead: bool = false,

    /// A link the user activated, already resolved against the page's
    /// address. The face navigates and leaves reader mode.
    on_link: *const fn (ctx: ?*anyopaque, url: []const u8) void,
    /// A key the reader did not consume. True = handled; the face uses
    /// it for Escape and for the window/pane bindings, so a reader with
    /// focus never becomes a keyboard trap.
    on_key: *const fn (ctx: ?*anyopaque, keyval: c.guint, state: c.GdkModifierType) bool,
    ctx: ?*anyopaque,

    pub fn create(
        allocator: std.mem.Allocator,
        ctx: ?*anyopaque,
        on_link: *const fn (ctx: ?*anyopaque, url: []const u8) void,
        on_key: *const fn (ctx: ?*anyopaque, keyval: c.guint, state: c.GdkModifierType) bool,
    ) ?*Reader {
        const self = allocator.create(Reader) catch return null;

        const scroller = c.gtk_scrolled_window_new() orelse {
            allocator.destroy(self);
            return null;
        };
        c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_set_hexpand(scroller, 1);
        c.gtk_widget_set_vexpand(scroller, 1);

        const view = c.gtk_text_view_new() orelse {
            allocator.destroy(self);
            return null;
        };
        c.gtk_text_view_set_editable(@ptrCast(view), 0);
        c.gtk_text_view_set_cursor_visible(@ptrCast(view), 0);
        c.gtk_text_view_set_wrap_mode(@ptrCast(view), c.GTK_WRAP_WORD_CHAR);
        c.gtk_text_view_set_left_margin(@ptrCast(view), 16);
        c.gtk_text_view_set_right_margin(@ptrCast(view), 16);
        c.gtk_text_view_set_top_margin(@ptrCast(view), 28);
        c.gtk_text_view_set_bottom_margin(@ptrCast(view), 48);
        c.gtk_text_view_set_pixels_below_lines(@ptrCast(view), 4);
        c.gtk_widget_set_cursor_from_name(view, "text");

        // AdwClamp is what holds the reading measure: a text view in a
        // scroller would otherwise grow to the pane's full width.
        const clamp = c.adw_clamp_new();
        c.adw_clamp_set_maximum_size(@ptrCast(clamp), MEASURE);
        c.adw_clamp_set_child(@ptrCast(clamp), view);
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), clamp);

        installCss(view);
        c.gtk_widget_add_css_class(scroller, "sketerm-reader");
        c.gtk_widget_add_css_class(view, "sketerm-reader");

        self.* = .{
            .allocator = allocator,
            .root = scroller,
            .view = view,
            .on_link = on_link,
            .on_key = on_key,
            .ctx = ctx,
        };
        self.buildTags();
        self.wire();
        return self;
    }

    /// Disconnect everything carrying this reader as user-data. Safe
    /// from any teardown path; `widgets_dead` says the widgets are
    /// already finalized and must not be touched at all.
    pub fn sever(self: *Reader, widgets_dead: bool) void {
        self.widgets_dead = self.widgets_dead or widgets_dead;
        if (!self.widgets_dead) {
            for (self.signal_objs[0..self.signal_count]) |obj| {
                if (obj) |o| _ = c.g_signal_handlers_disconnect_matched(
                    o,
                    c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    null,
                    @ptrCast(self),
                );
            }
        }
        self.signal_count = 0;
        self.widgets_dead = true;
    }

    pub fn destroy(self: *Reader) void {
        self.sever(self.widgets_dead);
        self.clearLinks();
        self.links.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn widget(self: *Reader) *c.GtkWidget {
        return self.root;
    }

    pub fn focus(self: *Reader) void {
        if (self.widgets_dead) return;
        _ = c.gtk_widget_grab_focus(self.view);
    }

    // ---- content ----------------------------------------------------

    /// Replace the article with `md`, whose relative links resolve
    /// against `base` (the page's own address). Returns false when the
    /// extraction had no readable text in it, so the caller can say so
    /// instead of showing an empty page.
    pub fn setMarkdown(self: *Reader, md: []const u8, base: []const u8) bool {
        if (self.widgets_dead) return false;
        const buffer = c.gtk_text_view_get_buffer(@ptrCast(self.view)) orelse return false;
        self.clearLinks();
        c.gtk_text_buffer_set_text(buffer, "", 0);

        var doc = markdown.parse(self.allocator, md) catch return false;
        defer doc.deinit();
        if (doc.blocks.len == 0) return false;

        var any_text = false;
        for (doc.blocks) |block| {
            const start = c.gtk_text_buffer_get_char_count(buffer);
            switch (block.kind) {
                .bullet => insertPlain(buffer, "\u{2022}  "),
                .ordered => {
                    var buf: [16]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}.  ", .{block.level}) catch "-  ";
                    insertPlain(buffer, s);
                },
                .rule => insertPlain(buffer, "\u{2500}" ** 24),
                else => {},
            }
            for (block.spans) |span| {
                if (span.text.len != 0) any_text = true;
                self.insertSpan(buffer, span, base);
            }
            const end = c.gtk_text_buffer_get_char_count(buffer);
            if (blockTag(block)) |tag| applyTag(buffer, tag, start, end);
            // One newline per block: the block tags carry the spacing,
            // so a blank line here would double every gap.
            insertPlain(buffer, "\n");
        }
        if (!any_text) return false;

        // A re-entered reader must start at the top of the new article.
        var top: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_start_iter(buffer, &top);
        c.gtk_text_buffer_place_cursor(buffer, &top);
        return true;
    }

    fn insertSpan(self: *Reader, buffer: *c.GtkTextBuffer, span: markdown.Span, base: []const u8) void {
        const start = c.gtk_text_buffer_get_char_count(buffer);
        if (span.image) {
            // No image fetch in reader mode: the alt text IS the
            // content the extraction kept, and a reader that reloads
            // assets is a second network client on the page.
            var buf: [512]u8 = undefined;
            const alt = clampUtf8(span.text, 400);
            const label = if (alt.len != 0)
                std.fmt.bufPrint(&buf, "[image: {s}]", .{alt}) catch "[image]"
            else
                "[image]";
            insertPlain(buffer, label);
        } else {
            insertPlain(buffer, span.text);
        }
        const end = c.gtk_text_buffer_get_char_count(buffer);
        if (end == start) return;

        if (span.bold) applyTag(buffer, "bold", start, end);
        if (span.italic or span.image) applyTag(buffer, "italic", start, end);
        if (span.code) applyTag(buffer, "code", start, end);
        if (span.image) applyTag(buffer, "dim", start, end);
        if (span.href) |href| {
            if (span.image) return;
            var buf: [4096]u8 = undefined;
            const url = resolveUrl(&buf, base, href) orelse return;
            const owned = self.allocator.dupe(u8, url) catch return;
            self.links.append(self.allocator, .{ .start = start, .end = end, .url = owned }) catch {
                self.allocator.free(owned);
                return;
            };
            applyTag(buffer, "link", start, end);
        }
    }

    fn clearLinks(self: *Reader) void {
        for (self.links.items) |l| self.allocator.free(l.url);
        self.links.clearRetainingCapacity();
    }

    fn linkAt(self: *Reader, offset: c_int) ?[]const u8 {
        for (self.links.items) |l| {
            if (offset >= l.start and offset < l.end) return l.url;
        }
        return null;
    }

    /// Character offset under a widget-space point, or null when the
    /// point is not ON a character. GTK answers a click past the end of
    /// a line with that line's LAST iter, which would make the whole
    /// right margin of a line ending in a link clickable — so the hit
    /// is confirmed against the iter's own rectangle.
    fn offsetAt(self: *Reader, x: f64, y: f64) ?c_int {
        var bx: c_int = 0;
        var by: c_int = 0;
        c.gtk_text_view_window_to_buffer_coords(
            @ptrCast(self.view),
            c.GTK_TEXT_WINDOW_WIDGET,
            @intFromFloat(x),
            @intFromFloat(y),
            &bx,
            &by,
        );
        var iter: c.GtkTextIter = undefined;
        if (c.gtk_text_view_get_iter_at_location(@ptrCast(self.view), &iter, bx, by) == 0) return null;
        var rect: c.GdkRectangle = undefined;
        c.gtk_text_view_get_iter_location(@ptrCast(self.view), &iter, &rect);
        if (bx < rect.x or bx > rect.x + rect.width) return null;
        if (by < rect.y or by > rect.y + rect.height) return null;
        return c.gtk_text_iter_get_offset(&iter);
    }

    // ---- tags and style ---------------------------------------------

    fn buildTags(self: *Reader) void {
        const buffer = c.gtk_text_view_get_buffer(@ptrCast(self.view)) orelse return;
        const nul: [*c]const u8 = null;
        _ = c.gtk_text_buffer_create_tag(buffer, "h1", "weight", @as(c_int, c.PANGO_WEIGHT_BOLD), "scale", @as(f64, 1.7), "pixels-above-lines", @as(c_int, 10), "pixels-below-lines", @as(c_int, 10), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "h2", "weight", @as(c_int, c.PANGO_WEIGHT_BOLD), "scale", @as(f64, 1.4), "pixels-above-lines", @as(c_int, 16), "pixels-below-lines", @as(c_int, 8), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "h3", "weight", @as(c_int, c.PANGO_WEIGHT_BOLD), "scale", @as(f64, 1.2), "pixels-above-lines", @as(c_int, 14), "pixels-below-lines", @as(c_int, 6), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "h4", "weight", @as(c_int, c.PANGO_WEIGHT_BOLD), "scale", @as(f64, 1.05), "pixels-above-lines", @as(c_int, 12), "pixels-below-lines", @as(c_int, 4), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "para", "pixels-below-lines", @as(c_int, 14), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "item", "left-margin", @as(c_int, 40), "indent", @as(c_int, -22), "pixels-below-lines", @as(c_int, 6), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "quote", "left-margin", @as(c_int, 40), "right-margin", @as(c_int, 40), "style", @as(c_int, c.PANGO_STYLE_ITALIC), "pixels-below-lines", @as(c_int, 14), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "codeblock", "family", "monospace", "scale", @as(f64, 0.92), "left-margin", @as(c_int, 40), "pixels-below-lines", @as(c_int, 14), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "rule", "justification", @as(c_int, c.GTK_JUSTIFY_CENTER), "pixels-above-lines", @as(c_int, 10), "pixels-below-lines", @as(c_int, 18), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "bold", "weight", @as(c_int, c.PANGO_WEIGHT_BOLD), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "italic", "style", @as(c_int, c.PANGO_STYLE_ITALIC), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "code", "family", "monospace", "scale", @as(f64, 0.92), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "dim", "foreground", linkColor(false), nul);
        _ = c.gtk_text_buffer_create_tag(buffer, "link", "foreground", linkColor(true), "underline", @as(c_int, c.PANGO_UNDERLINE_SINGLE), nul);
    }

    fn blockTag(block: markdown.Block) ?[*:0]const u8 {
        return switch (block.kind) {
            .heading => switch (block.level) {
                1 => "h1",
                2 => "h2",
                3 => "h3",
                else => "h4",
            },
            .paragraph => "para",
            .code => "codeblock",
            .quote => "quote",
            .bullet, .ordered => "item",
            .rule => "rule",
        };
    }

    fn insertPlain(buffer: *c.GtkTextBuffer, text: []const u8) void {
        if (text.len == 0) return;
        var iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_end_iter(buffer, &iter);
        c.gtk_text_buffer_insert(buffer, &iter, text.ptr, @intCast(text.len));
    }

    fn applyTag(buffer: *c.GtkTextBuffer, name: [*:0]const u8, start: c_int, end: c_int) void {
        if (end <= start) return;
        var a: c.GtkTextIter = undefined;
        var b: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(buffer, &a, start);
        c.gtk_text_buffer_get_iter_at_offset(buffer, &b, end);
        c.gtk_text_buffer_apply_tag_by_name(buffer, name, &a, &b);
    }

    /// A text tag needs a literal colour, so the two theme variants are
    /// resolved once here rather than left to CSS. Picked for contrast
    /// on the view background each theme actually paints; a theme change
    /// while the reader is open is not tracked, and re-opening it fixes
    /// the colour.
    fn linkColor(strong: bool) [*:0]const u8 {
        const dark = blk: {
            const mgr = c.adw_style_manager_get_default() orelse break :blk false;
            break :blk c.adw_style_manager_get_dark(mgr) != 0;
        };
        if (dark) return if (strong) "#78aeed" else "#a0a0a0";
        return if (strong) "#1a5fb4" else "#6a6a6a";
    }

    /// Serif body text at a comfortable size, on the theme's own view
    /// colours so the reader matches light and dark without asking.
    fn installCss(any: *c.GtkWidget) void {
        cssutil.install("webreader", any,
            \\.sketerm-reader { background: @view_bg_color; color: @view_fg_color; }
            \\textview.sketerm-reader, textview.sketerm-reader text {
            \\  background: @view_bg_color;
            \\  color: @view_fg_color;
            \\  font-family: serif;
            \\  font-size: 1.15em;
            \\}
        );
    }

    // ---- input -------------------------------------------------------

    fn track(self: *Reader, obj: anytype) void {
        if (self.signal_count >= self.signal_objs.len) return;
        self.signal_objs[self.signal_count] = @ptrCast(@alignCast(obj));
        self.signal_count += 1;
    }

    fn wire(self: *Reader) void {
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 1);
        _ = c.g_signal_connect_data(@ptrCast(click), "released", @ptrCast(&onReleased), self, null, 0);
        c.gtk_widget_add_controller(self.view, @ptrCast(click));
        self.track(click);

        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(@ptrCast(motion), "motion", @ptrCast(&onMotion), self, null, 0);
        c.gtk_widget_add_controller(self.view, motion);
        self.track(motion);

        const key = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(@ptrCast(key), "key-pressed", @ptrCast(&onKeyPressed), self, null, 0);
        c.gtk_widget_add_controller(self.view, key);
        self.track(key);
    }

    fn onReleased(_: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Reader, user);
        if (self.widgets_dead or n_press != 1) return;
        const off = self.offsetAt(x, y) orelse return;
        const url = self.linkAt(off) orelse return;
        self.on_link(self.ctx, url);
    }

    fn onMotion(_: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Reader, user);
        if (self.widgets_dead) return;
        const over = if (self.offsetAt(x, y)) |off| self.linkAt(off) != null else false;
        c.gtk_widget_set_cursor_from_name(self.view, if (over) "pointer" else "text");
    }

    fn onKeyPressed(
        _: *c.GtkEventControllerKey,
        keyval: c.guint,
        _: c.guint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self = cast.userData(Reader, user);
        if (self.widgets_dead) return 0;
        return if (self.on_key(self.ctx, keyval, state)) 1 else 0;
    }
};

/// `s` cut to at most `max` bytes WITHOUT splitting a codepoint: a
/// GtkTextBuffer rejects invalid UTF-8 outright, so a naive slice of a
/// page's alt text would silently drop the whole label.
fn clampUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
    return s[0..n];
}

/// Resolve `href` against the page address `base`, writing into `buf`.
/// Null means "not something to navigate to" — an in-page anchor, a
/// `javascript:` URL, or an address longer than the buffer.
pub fn resolveUrl(buf: []u8, base: []const u8, href: []const u8) ?[]const u8 {
    const h = std.mem.trim(u8, href, " \t\r\n");
    if (h.len == 0 or h[0] == '#') return null;
    if (std.ascii.startsWithIgnoreCase(h, "javascript:")) return null;
    if (hasScheme(h)) return copyInto(buf, h);

    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return null;
    const scheme = base[0..scheme_end];
    const after = base[scheme_end + 3 ..];
    const host_len = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    const origin = base[0 .. scheme_end + 3 + host_len];

    if (std.mem.startsWith(u8, h, "//"))
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ scheme, h }) catch null;
    if (h[0] == '/')
        return std.fmt.bufPrint(buf, "{s}{s}", .{ origin, h }) catch null;

    // Relative to the base's directory, with the query and fragment of
    // the base dropped — they belong to the document, not the path.
    // A base with no path at all (`https://host`) still has the root
    // as its directory, or the join would produce `https://hosta.html`.
    const path = after[host_len..];
    const stop = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    const dir = if (std.mem.lastIndexOfScalar(u8, path[0..stop], '/')) |i| path[0 .. i + 1] else "/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ origin, dir, h }) catch null;
}

/// True for `scheme:` at the head of `s` (RFC 3986's scheme charset),
/// which is what makes an address absolute.
fn hasScheme(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s, 0..) |ch, i| {
        if (ch == ':') return i > 0;
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    return false;
}

fn copyInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

test "webreader: relative links resolve against the page address" {
    var buf: [1024]u8 = undefined;
    const base = "https://example.com/docs/guide/intro.html?x=1#frag";
    try std.testing.expectEqualStrings(
        "https://example.com/docs/guide/next.html",
        resolveUrl(&buf, base, "next.html").?,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/top",
        resolveUrl(&buf, base, "/top").?,
    );
    try std.testing.expectEqualStrings(
        "https://cdn.example.net/x.png",
        resolveUrl(&buf, base, "//cdn.example.net/x.png").?,
    );
    try std.testing.expectEqualStrings(
        "http://other.example/a",
        resolveUrl(&buf, base, "http://other.example/a").?,
    );
    try std.testing.expectEqualStrings(
        "mailto:someone@example.com",
        resolveUrl(&buf, base, "mailto:someone@example.com").?,
    );
    try std.testing.expect(resolveUrl(&buf, base, "#section") == null);
    try std.testing.expect(resolveUrl(&buf, base, "javascript:void(0)") == null);
    try std.testing.expect(resolveUrl(&buf, "about:blank", "next.html") == null);
}

test "webreader: a byte cap never splits a codepoint" {
    // Four 3-byte codepoints; every cap lands back on a boundary.
    const s = "\u{4e00}\u{4e8c}\u{4e09}\u{56db}";
    try std.testing.expectEqual(@as(usize, 12), clampUtf8(s, 99).len);
    try std.testing.expectEqual(@as(usize, 9), clampUtf8(s, 11).len);
    try std.testing.expectEqual(@as(usize, 9), clampUtf8(s, 9).len);
    try std.testing.expectEqual(@as(usize, 0), clampUtf8(s, 2).len);
}

test "webreader: a bare-origin base still joins" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://example.com/a.html",
        resolveUrl(&buf, "https://example.com", "a.html").?,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/a.html",
        resolveUrl(&buf, "https://example.com/", "a.html").?,
    );
}
