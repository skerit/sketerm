//! Terminal-to-Window sink callbacks — bell, titles, cwd, command
//! status, notifications, progress, transfers, activity, broadcast —
//! split out of window.zig. These are the functions wirePaneSinks
//! installs on every pane terminal.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Terminal = @import("../terminal.zig").Terminal;
const Pane = @import("pane.zig").Pane;
const winmod = @import("window.zig");
const Window = winmod.Window;
const logActionError = winmod.logActionError;
const tabPageForPane = winmod.tabPageForPane;
const showToast = winmod.showToast;
const tab_effects = @import("tab_effects.zig");
const remotectl = @import("remotectl.zig");
const titlefmt = @import("../util/titlefmt.zig");

/// A pane's file transfer (upload or download) changed state: drive
/// the tab progress ring and, on completion/failure, a toast. Mirrors
/// onTermProgress' ownership.
pub fn onTermTransfer(ctx: ?*anyopaque, pane: *Pane, ev: Terminal.TransferEvent) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane);
    const host = if (pane.terminal.remote) |r| (if (r.host) |h| h else "local") else "remote";
    switch (ev.phase) {
        .started => if (page) |p| self.setTabProgress(p, 3, 0), // indeterminate
        .progress => if (page) |p| {
            const pct: u8 = if (ev.total > 0)
                @intCast(@min(@as(u64, 100), ev.sent * 100 / ev.total))
            else
                0;
            self.setTabProgress(p, if (ev.total > 0) @as(u8, 1) else @as(u8, 3), pct);
        },
        .done => {
            if (page) |p| self.setTabProgress(p, 0, 0);
            var buf: [768]u8 = undefined;
            // Upload dest is a remote path (show host); download dest is
            // the local file it saved to.
            const msg = switch (ev.dir) {
                .upload => std.fmt.bufPrint(&buf, "Uploaded {s} → {s}:{s}", .{ ev.name, host, ev.dest }) catch return,
                .download => std.fmt.bufPrint(&buf, "Downloaded {s} → {s}", .{ ev.name, ev.dest }) catch return,
            };
            showToast(self, msg);
        },
        .failed => {
            if (page) |p| self.setTabProgress(p, 0, 0);
            var buf: [768]u8 = undefined;
            const verb = switch (ev.dir) {
                .upload => "Upload",
                .download => "Download",
            };
            const msg = std.fmt.bufPrint(&buf, "{s} of {s} failed: {s}", .{ verb, ev.name, ev.message }) catch return;
            showToast(self, msg);
        },
    }
}

/// Wired from `Pane.win_on_session_renamed` — the daemon confirmed a
/// session rename; rebuild the "⌁ name [@ host]" tab title.
pub fn onTermSessionRenamed(ctx: ?*anyopaque, pane: *Pane, name: []const u8) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane) orelse return;
    const remote = pane.terminal.remote orelse return;
    var title_buf: [160:0]u8 = undefined;
    const title_z = if (remote.host) |h|
        std.fmt.bufPrintZ(&title_buf, "⌁ {s} @ {s}", .{ name, h }) catch return
    else
        std.fmt.bufPrintZ(&title_buf, "⌁ {s}", .{name}) catch return;
    c.adw_tab_page_set_title(page, title_z.ptr);
    c.adw_tab_page_set_tooltip(page, title_z.ptr);
}

pub fn onTermClipboardSet(ctx: ?*anyopaque, text: []const u8) void {
    const self = cast.userData(Window, ctx);
    const display = c.gtk_widget_get_display(self.app_window);
    const clip = c.gdk_display_get_clipboard(display);
    const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return;
    defer self.allocator.free(cstr);
    @memcpy(cstr, text);
    c.gdk_clipboard_set_text(clip, cstr.ptr);
}

pub fn onTermChildExit(ctx: ?*anyopaque, pane: *Pane, status: i32) void {
    const self = cast.userData(Window, ctx);
    // A remote pane "exiting" means the mux session ended or the
    // connection dropped — normally land in a local shell so the tab
    // survives (exit_action governs local children only). Exception: a
    // forwarded app (`sketerm app`) that exited before ever showing a
    // window has failed to launch, and its log is the only useful
    // output — hold the pane with that log visible instead of wiping it.
    if (pane.terminal.remote) |remote| {
        if (remote.is_app and !remote.app_window_opened) {
            self.holdExitedAppPane(pane, status);
            return;
        }
        self.detachPaneToShell(pane);
        return;
    }
    const action = if (self.hold_override) .hold else self.config.exit_action;
    switch (action) {
        .close => self.closePane(pane),
        .restart => {
            // Spawn a fresh shell in a new pane and replace the
            // exited one. v1 implementation: just close the dead
            // pane and spawn a new tab. Truly in-place restart
            // would need PTY-level surgery in Terminal.
            self.closePane(pane);
            self.newShellTab(null) catch |err| logActionError("exit_restart_new_tab", err);
        },
        .hold => {
            // Already showed the "[process exited]" banner; do
            // nothing further. User can close the pane manually.
        },
    }
}

pub fn onTermBell(ctx: ?*anyopaque, pane: *Pane) void {
    const self = cast.userData(Window, ctx);

    // Audible bell — system beep through GdkDisplay (DE/portal aware).
    if (self.config.bell_audible) {
        const display = c.gtk_widget_get_display(self.app_window);
        if (display != null) c.gdk_display_beep(display);
    }

    // Visible flash — Pane.onBellEvent already records bell_at_us
    // and the renderer paints a brief tint. Just disable that path
    // when the user opted out.
    if (!self.config.bell_visible) {
        pane.terminal.screen.bell_at_us = 0;
    }

    if (!self.config.bell_urgent) return;

    // Mark the containing tab needs-attention (unless it's the
    // currently selected one).
    const page = tabPageForPane(self, pane) orelse return;
    if (page == c.adw_tab_view_get_selected_page(self.tab_view)) return;
    c.adw_tab_page_set_needs_attention(page, 1);
}

/// OSC 133 command lifecycle → tab status dot, plus needs-attention
/// and a desktop notification when a long-running command finishes
/// in a pane the user isn't watching.
pub fn onTermCmdStatus(ctx: ?*anyopaque, pane: *Pane, running: bool, exit: i32, duration_ms: i64) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane) orelse return;
    if (running) {
        self.setTabCmdStatus(page, 1);
        return;
    }
    const selected = page == c.adw_tab_view_get_selected_page(self.tab_view);
    const win_active = c.gtk_window_is_active(@ptrCast(self.app_window)) != 0;
    if (selected and win_active) {
        // The user watched it finish — the prompt already tells the
        // story; a lingering dot would be noise.
        self.setTabCmdStatus(page, 0);
        return;
    }
    self.setTabCmdStatus(page, if (exit == 0) 2 else 3);

    const min_s = self.config.notify_command_secs;
    if (min_s == 0 or duration_ms < @as(i64, min_s) * 1000) return;
    c.adw_tab_page_set_needs_attention(page, 1);

    const app = c.gtk_window_get_application(@ptrCast(self.app_window));
    if (app == null) return;
    var title_buf: [64]u8 = undefined;
    const title_z = if (exit == 0)
        std.fmt.bufPrintZ(&title_buf, "Command finished", .{}) catch return
    else
        std.fmt.bufPrintZ(&title_buf, "Command failed (exit {d})", .{exit}) catch return;
    const notif = c.g_notification_new(title_z.ptr);
    if (notif == null) return;
    defer c.g_object_unref(notif);
    const tab_title = c.adw_tab_page_get_title(page);
    const secs = @divTrunc(duration_ms, 1000);
    var body_buf: [256]u8 = undefined;
    if (std.fmt.bufPrintZ(&body_buf, "{s} ({d}m {d}s)", .{
        if (tab_title != null) std.mem.span(tab_title) else "sketerm",
        @divTrunc(secs, 60),
        @mod(secs, 60),
    })) |body_z| {
        c.g_notification_set_body(notif, body_z.ptr);
    } else |_| {}
    if (exit != 0) c.g_notification_set_priority(notif, c.G_NOTIFICATION_PRIORITY_HIGH);
    c.g_application_send_notification(@ptrCast(app), null, notif);
}

/// OSC 7 cwd updated for `pane`. Find its AdwTabPage and rewrite
/// the tooltip to include the live cwd, so hovering tells the user
/// where each tab actually is. Format: "<title>\n<cwd>".
/// OSC 1337 ; SetProfile=<name> — an app asked to restyle its pane.
/// Untrusted input: applyProfileToPane maps unknown/empty names to the
/// Default profile, so a hostile sequence can only swap between the
/// user's own configured profiles, never inject arbitrary settings.
pub fn onTermSetProfile(ctx: ?*anyopaque, pane: *Pane, name: []const u8) void {
    const self = cast.userData(Window, ctx);
    self.applyProfileToPane(pane, name);
}

pub fn onTermCwdChanged(ctx: ?*anyopaque, pane: *Pane, cwd: []const u8) void {
    const self = cast.userData(Window, ctx);
    {
        const page = tabPageForPane(self, pane) orelse return;

        // A cwd-bearing template must re-render before we read the
        // title back for the tooltip, or the tooltip lags one change.
        if (titlefmt.uses(self.config.tab_title_template).contains(.absolute_path) or
            titlefmt.uses(self.config.tab_title_template).contains(.relative_path))
            refreshTabTitle(self, pane);
        if (pane == self.focusedPane()) {
            const wm = titlefmt.uses(self.config.window_title_template);
            if (wm.contains(.absolute_path) or wm.contains(.relative_path))
                refreshWindowTitleTemplate(self);
        }

        // Abbreviate $HOME → ~ so the tooltip stays compact for the
        // common case of working under your home directory.
        var abbrev_buf: [512]u8 = undefined;
        const display_cwd = abbreviateHome(cwd, &abbrev_buf);

        const title_c = c.adw_tab_page_get_title(page);
        const title_str: []const u8 = if (title_c != null)
            std.mem.span(@as([*:0]const u8, @ptrCast(title_c)))
        else
            "";
        const total_len = if (title_str.len > 0) title_str.len + 1 + display_cwd.len else display_cwd.len;
        const tip = self.allocator.allocSentinel(u8, total_len, 0) catch return;
        defer self.allocator.free(tip);
        if (title_str.len > 0) {
            @memcpy(tip[0..title_str.len], title_str);
            tip[title_str.len] = '\n';
            @memcpy(tip[title_str.len + 1 .. total_len], display_cwd);
        } else {
            @memcpy(tip[0..display_cwd.len], display_cwd);
        }
        c.adw_tab_page_set_tooltip(page, tip.ptr);
        return;
    }
}

/// Fold `$HOME` to `~` for `{{ RELATIVE_PATH }}` and the tab tooltip.
/// Falls through to the raw path when HOME isn't set, doesn't prefix
/// it, or the result wouldn't fit. `HOMEextra` is a different
/// directory, so only an exact match or a `HOME/` prefix folds.
pub fn abbreviateHome(cwd: []const u8, buf: []u8) []const u8 {
    const home = @import("../util/profile.zig").getenv("HOME") orelse return cwd;
    if (home.len == 0 or !std.mem.startsWith(u8, cwd, home)) return cwd;
    const after = cwd[home.len..];
    if (after.len != 0 and after[0] != '/') return cwd;
    const total = 1 + after.len;
    if (total > buf.len) return cwd;
    buf[0] = '~';
    @memcpy(buf[1..total], after);
    return buf[0..total];
}

/// Everything a title template can substitute, gathered for one pane.
///
/// `title` comes from `Screen.last_title` — the RAW OSC 0/2 string —
/// never from `adw_tab_page_get_title`. Reading back the rendered
/// label would make a template like `"{{ TITLE }} !"` append a `!` on
/// every render and grow without bound; sourcing the fact upstream of
/// the label is what makes re-rendering idempotent.
///
/// `rel_buf` must outlive the returned Facts: `relative_path` borrows
/// it.
pub fn paneFacts(self: *Window, pane: *Pane, rel_buf: []u8) titlefmt.Facts {
    const term = pane.terminal;
    const cwd: []const u8 = if (term.cwd) |p| p else "";
    var facts = titlefmt.Facts{
        .title = if (term.screen.last_title) |t| t else "",
        .program = term.program(),
        .absolute_path = cwd,
        .relative_path = if (cwd.len > 0) abbreviateHome(cwd, rel_buf) else "",
        .columns = term.screen.cols,
        .lines = term.screen.rows,
        .profile = if (pane.active_profile) |p| p else "",
        .zoomed = self.zoom_pane == pane,
    };
    if (term.remote) |r| facts.session = r.session;
    if (tabPageForPane(self, pane)) |page| {
        const pos = c.adw_tab_view_get_page_position(self.tab_view, page);
        if (pos >= 0) facts.index = @intCast(pos + 1);
    }
    return facts;
}

/// Re-render `pane`'s tab label from `tab_title_template`.
///
/// Safe to call as often as facts move: it allocates nothing beyond
/// the NUL-terminated copy GTK needs, and it cannot feed itself —
/// every fact is read from Terminal/Screen/the pane tree, never from
/// the label being written. `adw_tab_page_set_title` emits
/// `notify::title`, which `tabbar.zig` handles by copying the string
/// into a GtkLabel; that path never re-enters rendering.
pub fn refreshTabTitle(self: *Window, pane: *Pane) void {
    const page = tabPageForPane(self, pane) orelse return;
    if (c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-title-locked") != null) return;
    var rel_buf: [512]u8 = undefined;
    var out: [titlefmt.MAX]u8 = undefined;
    const facts = paneFacts(self, pane, &rel_buf);
    const rendered = titlefmt.render(&out, self.config.tab_title_template, facts);
    // A template with nothing to say must not WIPE a label somebody
    // else set. Mux session tabs ("⌁ work @ host") and the initial
    // "Tab N" carry no OSC title, so the default `{{ TITLE }}` renders
    // empty for them — before templates existed, only a real OSC title
    // could overwrite those, and that must stay true.
    if (rendered.len == 0) return;
    setTabPageTitleFromUtf8(self.allocator, page, rendered);
}

/// Re-render the window title from `window_title_template`, using the
/// focused pane's facts. No-op when the key is unset, which is the
/// default and keeps sketerm's historical fixed window title.
pub fn refreshWindowTitleTemplate(self: *Window) void {
    if (self.config.window_title_template.len == 0) return;
    const pane = self.focusedPane() orelse return;
    var rel_buf: [512]u8 = undefined;
    var out: [titlefmt.MAX]u8 = undefined;
    const facts = paneFacts(self, pane, &rel_buf);
    const rendered = titlefmt.render(&out, self.config.window_title_template, facts);
    self.setWindowTitleText(rendered);
}

/// One fact moved for `pane`; refresh the titles that depend on it.
/// `field` is what changed, so a template that never mentions it costs
/// a bitmask test rather than a re-render.
pub fn titleFactChanged(self: *Window, pane: *Pane, field: titlefmt.Field) void {
    if (titlefmt.uses(self.config.tab_title_template).contains(field))
        refreshTabTitle(self, pane);
    if (pane == self.focusedPane() and
        titlefmt.uses(self.config.window_title_template).contains(field))
        refreshWindowTitleTemplate(self);
}

/// True when either configured template reads `field`.
pub fn titlefmtUses(self: *Window, field: titlefmt.Field) bool {
    return titlefmt.uses(self.config.tab_title_template).contains(field) or
        titlefmt.uses(self.config.window_title_template).contains(field);
}

/// Re-render every pane's tab label and the window title. For changes
/// that move facts for all panes at once: a config reload, or a tab
/// reorder (which shifts `{{ INDEX }}`).
pub fn refreshAllTitles(self: *Window) void {
    for (self.panes.items) |p| refreshTabTitle(self, p);
    refreshWindowTitleTemplate(self);
}

/// Wired from `Pane.win_on_title`. Updates the AdwTabPage's title from
/// OSC 0/1/2 events emitted by the shell, but only while the page
/// hasn't been user-renamed. The "user-locked" flag lives on the
/// page as `g_object_set_data(page, "sketerm-title-locked")`.
pub fn onTermTitleChanged(ctx: ?*anyopaque, pane: *Pane, _: []const u8) void {
    const self = cast.userData(Window, ctx);
    // The raw title is ignored: `paneFacts` reads it back from
    // `screen.last_title`, which the Screen has already stored by the
    // time this fires, so both paths agree on one source.
    titleFactChanged(self, pane, .title);
}

/// Wired from `Pane.win_on_program`.
pub fn onTermProgramChanged(ctx: ?*anyopaque, pane: *Pane, _: []const u8) void {
    const self = cast.userData(Window, ctx);
    titleFactChanged(self, pane, .program);
}

/// Wired from `Pane.win_on_geometry` — the pane's column/row count
/// changed.
pub fn onPaneGeometryChanged(ctx: ?*anyopaque, pane: *Pane) void {
    const self = cast.userData(Window, ctx);
    titleFactChanged(self, pane, .columns);
    titleFactChanged(self, pane, .lines);
}

pub fn setTabPageTitleFromUtf8(allocator: std.mem.Allocator, page: *c.AdwTabPage, title: []const u8) void {
    // Tabs render single-line — drop empty titles to a fallback so a
    // tab never goes blank.
    const effective = if (title.len > 0) title else "sketerm";
    const z = allocator.allocSentinel(u8, effective.len, 0) catch return;
    defer allocator.free(z);
    @memcpy(z, effective);
    c.adw_tab_page_set_title(page, z.ptr);
    c.adw_tab_page_set_tooltip(page, z.ptr);
}

/// Stable GNotification tag for an OSC 99 identifier, so a repeated
/// id replaces the previous notification and p=close can withdraw
/// it. Null (untagged) when the app supplied no id.
pub fn notifyTag(buf: []u8, id: []const u8) ?[*:0]const u8 {
    if (id.len == 0) return null;
    const z = std.fmt.bufPrintZ(buf, "sketerm-osc99-{s}", .{id}) catch return null;
    return z.ptr;
}

pub fn onTermNotification(ctx: ?*anyopaque, pane: *Pane, ev: Screen.NotificationEvent) void {
    const self = cast.userData(Window, ctx);
    const app = c.gtk_window_get_application(@ptrCast(self.app_window));
    if (app == null) return;
    var tag_buf: [96]u8 = undefined;

    if (ev.close) {
        if (notifyTag(&tag_buf, ev.id)) |tag| {
            c.g_application_withdraw_notification(@ptrCast(app), tag);
        }
        return;
    }

    // Occasion gate: `unfocused` = skip while this window is active;
    // `invisible` additionally requires the pane's tab to be the
    // selected one (i.e. the pane is actually on screen).
    const win_active = c.gtk_window_is_active(@ptrCast(self.app_window)) != 0;
    switch (ev.occasion) {
        .always => {},
        .unfocused => if (win_active) return,
        .invisible => if (win_active) {
            const page = tabPageForPane(self, pane);
            if (page != null and page == c.adw_tab_view_get_selected_page(self.tab_view)) return;
        },
    }

    const effective_title = if (ev.title.len > 0) ev.title else "sketerm";
    const title_z = self.allocator.allocSentinel(u8, effective_title.len, 0) catch return;
    defer self.allocator.free(title_z);
    @memcpy(title_z, effective_title);
    const notif = c.g_notification_new(title_z.ptr);
    if (notif == null) return;
    defer c.g_object_unref(notif);

    if (ev.body.len > 0) {
        const body_z = self.allocator.allocSentinel(u8, ev.body.len, 0) catch return;
        defer self.allocator.free(body_z);
        @memcpy(body_z, ev.body);
        c.g_notification_set_body(notif, body_z.ptr);
    }

    // Icon: themed name wins when the theme has it; otherwise the
    // transmitted image bytes (PNG/JPEG/GIF — the notification daemon
    // decodes them from the serialized GBytesIcon).
    if (ev.icon_name.len > 0) {
        var name_buf: [128]u8 = undefined;
        if (std.fmt.bufPrintZ(&name_buf, "{s}", .{ev.icon_name})) |name_z| {
            const icon = c.g_themed_icon_new(name_z.ptr);
            c.g_notification_set_icon(notif, @ptrCast(icon));
            c.g_object_unref(icon);
        } else |_| {}
    } else if (ev.icon_data.len > 0) {
        const bytes = c.g_bytes_new(ev.icon_data.ptr, ev.icon_data.len);
        const icon = c.g_bytes_icon_new(bytes);
        c.g_bytes_unref(bytes);
        c.g_notification_set_icon(notif, @ptrCast(icon));
        c.g_object_unref(icon);
    }

    if (ev.urgency) |u| {
        c.g_notification_set_priority(notif, switch (u) {
            0 => c.G_NOTIFICATION_PRIORITY_LOW,
            2 => c.G_NOTIFICATION_PRIORITY_URGENT,
            else => c.G_NOTIFICATION_PRIORITY_NORMAL,
        });
    }

    // Activation slot — needed for reports AND for focusing the
    // originating pane. Plain notifications skip the bookkeeping.
    const interactive = ev.want_report or ev.buttons_raw.len > 0 or ev.want_focus;
    var token: u32 = 0;
    if (interactive) {
        token = remotectl.registerNotifySlot(self, pane, ev) orelse 0;
    }
    if (token != 0) {
        c.g_notification_set_default_action_and_target(
            notif,
            "app.notify-act",
            "(uu)",
            token,
            @as(c_uint, 0),
        );
        // Buttons: U+2028-separated labels, numbered from 1 in
        // activation reports. Cap at 8 — desktop daemons show 2-3.
        var n_btn: c_uint = 0;
        var bit = std.mem.splitSequence(u8, ev.buttons_raw, "\xe2\x80\xa8");
        while (bit.next()) |label| {
            if (label.len == 0) continue;
            if (n_btn >= 8) break;
            n_btn += 1;
            const label_z = self.allocator.allocSentinel(u8, label.len, 0) catch break;
            defer self.allocator.free(label_z);
            @memcpy(label_z, label);
            c.g_notification_add_button_with_target(
                notif,
                label_z.ptr,
                "app.notify-act",
                "(uu)",
                token,
                n_btn,
            );
        }
    }

    c.g_application_send_notification(@ptrCast(app), notifyTag(&tag_buf, ev.id), notif);
}

/// Activation report / focus dispatch for "app.notify-act". Fired by
/// the desktop when the user clicks an OSC 99 notification (button 0)
/// or one of its buttons (1-based).
pub fn onNotifyActivate(_: *c.GSimpleAction, param: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    if (param == null) return;
    var token: c_uint = 0;
    var button: c_uint = 0;
    c.g_variant_get(param, "(uu)", &token, &button);

    const slot = blk: {
        for (self.notify_slots.items) |s| {
            if (s.token == token) break :blk s;
        }
        return; // pane closed, or slot evicted — nothing to do
    };

    if (slot.want_focus) {
        c.gtk_window_present(@ptrCast(self.app_window));
        if (tabPageForPane(self, slot.pane)) |page| {
            c.adw_tab_view_set_selected_page(self.tab_view, page);
        }
        _ = c.gtk_widget_grab_focus(@ptrCast(slot.pane.surface.area));
    }
    if (slot.want_report) {
        // Spec: OSC 99 ; i=<id> ; <button-or-empty>. id was sanitized
        // at parse time, so it can't smuggle escape bytes.
        var buf: [96]u8 = undefined;
        const id: []const u8 = if (slot.id.len > 0) slot.id else "0";
        const out = if (button == 0)
            std.fmt.bufPrint(&buf, "\x1b]99;i={s};\x1b\\", .{id}) catch return
        else
            std.fmt.bufPrint(&buf, "\x1b]99;i={s};{d}\x1b\\", .{ id, button }) catch return;
        slot.pane.terminal.writeRaw(out);
    }
}

/// OSC 9;4 progress from `pane`: drive the tab's indicator ring and
/// re-aggregate the window-level taskbar progress.
pub fn onTermProgress(ctx: ?*anyopaque, pane: *Pane, state: u8, percent: u8) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane) orelse return;

    // One pane owns the tab's progress slot at a time: two builds in
    // split panes would otherwise overwrite each other's ring (and
    // wobble the taskbar aggregate) on every OSC update. The owner
    // releases by clearing (state 0) or by going quiet for 3s.
    const now_ms: usize = @intCast(@divTrunc(c.g_get_monotonic_time(), 1000));
    const owner: u32 = @truncate(@intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-progress-owner")));
    const stamp: usize = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-progress-stamp"));
    if (owner != 0 and owner != pane.id and now_ms -% stamp < 3000) return;
    if (state == 0) {
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-progress-owner", null);
    } else {
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-progress-owner", @ptrFromInt(@as(usize, pane.id)));
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-progress-stamp", @ptrFromInt(now_ms));
    }

    self.setTabProgress(page, state, percent);
    self.updateTaskbarProgress();
}

/// Move keyboard focus into the newly selected tab's pane so
/// typing immediately reaches that PTY.
/// Record the pane that just gained focus as its tab's last-focused, so
/// re-selecting the tab restores it (instead of the first pane).
pub fn onPaneFocused(ctx: ?*anyopaque, pane: *Pane) void {
    const self = cast.userData(Window, ctx);
    // The window title follows the FOCUSED pane, so moving focus is
    // itself a fact change. Cheap: a no-op unless the key is set.
    refreshWindowTitleTemplate(self);
    const page = tabPageForPane(self, pane) orelse return;
    if (Window.tabTreeOf(page)) |t| t.last_focused = pane;
}

/// A pane's visible grid changed (true content change, not just bytes).
/// Stamp the tab with a monotonic-us timestamp; the tab bar reads it to
/// drive the activity glow and decays it once output stops. The tab
/// you're already looking at is trivially "active", so skip it.
pub fn onTermActivity(ctx: ?*anyopaque, pane: *Pane) void {
    const self = cast.userData(Window, ctx);
    const page = tabPageForPane(self, pane) orelse return;
    if (page == c.adw_tab_view_get_selected_page(self.tab_view)) return;
    tab_effects.recordActivity(page);
    self.tabbar.ensureTick();
    // Reset the silence timer that drives this tab's inactive-warning.
    self.tabbar.armWarn(page);
}

/// Wired into Terminal.broadcast_sink. Routes back to the Window
/// `broadcastBytes` for the actual fan-out logic.
pub fn broadcastSinkFn(ctx: ?*anyopaque, source: *Terminal, bytes: []const u8) void {
    const self = cast.userData(Window, ctx);
    self.broadcastBytes(source, bytes);
}
