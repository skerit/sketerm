//! Password fill from the Secret Service (`secrets.zig`). Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const classicmenu = @import("../browser/classicmenu.zig");
const secrets = @import("../secrets.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;

// ---- password fill (Secret Service) ------------------------------

/// Picker state for one "Fill Password…" popup, owned by the menu
/// Root exactly like `MenuCtx`. It holds candidate LOGINS, never a
/// secret: the secret is fetched only for the row the user picks
/// and is wiped the moment it has been typed.
pub const FillCtx = struct {
    allocator: std.mem.Allocator,
    face: *WebFace,
    matches: secrets.Matches,
    rows: []FillRow,
};

/// One row's user-data. Borrowed from the FillCtx that owns it.
pub const FillRow = struct { ctx: *FillCtx, index: usize };

pub fn freeFillCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(FillCtx, user);
    ctx.allocator.free(ctx.rows);
    ctx.matches.deinit();
    ctx.allocator.destroy(ctx);
}

/// Offer the keyring logins saved for this page's host, and type
/// the picked one into the page as `username`, Tab, `password`.
///
/// FILL ONLY, deliberately: sketerm never offers to save a
/// password, never writes to the keyring, and never fills on load.
/// The keyring is read once, when the user asks for it.
///
/// FOCUS IS THE USER'S JOB. The characters go through the same
/// trusted-input path as the keyboard (`sendKey` -> `input_key` ->
/// CEF char events), so they land in whatever the page has
/// focused — click the username field first. A page cannot tell
/// this apart from typing, which is the point: no field-detection
/// heuristic to be fooled, and no bridge into the page's DOM.
pub fn fillPassword(self: *WebFace) void {
    if (self.widgets_dead) return;
    if (!self.view_live) {
        self.toast("This pane has no live web page.");
        return;
    }
    const addr: []const u8 = self.url orelse self.pending_url orelse "";
    const host = secrets.hostOf(addr);
    if (host.len == 0) {
        self.toast("This page has no address to match a saved login against.");
        return;
    }

    var matches = secrets.findForHost(self.allocator, host) catch |err| {
        self.toast(switch (err) {
            error.NoBus, error.NoService => "No password manager answered on the session bus (org.freedesktop.secrets).",
            else => "Could not read the keyring.",
        });
        return;
    };
    if (matches.items.len == 0) {
        matches.deinit();
        var buf: [320]u8 = undefined;
        self.toast(std.fmt.bufPrint(&buf, "No saved login for {s}.", .{host}) catch
            "No saved login for this site.");
        return;
    }

    var ok = false;
    defer if (!ok) matches.deinit();
    const root = classicmenu.Root.create(self.allocator) orelse return;
    var built = false;
    defer if (!built) root.destroy();

    const ctx = self.allocator.create(FillCtx) catch return;
    const rows = self.allocator.alloc(FillRow, matches.items.len) catch {
        self.allocator.destroy(ctx);
        return;
    };
    ctx.* = .{
        .allocator = self.allocator,
        .face = self,
        .matches = matches,
        .rows = rows,
    };
    ok = true;
    root.own(freeFillCtx, ctx);

    const menu = root.top();
    var text: [512]u8 = undefined;
    var label: [512]u8 = undefined;
    for (ctx.rows, 0..) |*row, i| {
        row.* = .{ .ctx = ctx, .index = i };
        menu.itemIcon(
            classicmenu.escapeLabel(fillRowLabel(&text, ctx.matches.items[i]), &label),
            .{ .name = "dialog-password-symbolic" },
            &onFillPick,
            row,
        );
    }
    built = true;
    const w: f64 = @floatFromInt(c.gtk_widget_get_width(self.view_area));
    _ = root.popup(self.view_area, w / 2, 24);
}

/// "user (label)", or the label alone for an entry with no login
/// name. A locked entry says so — picking it may still fail.
pub fn fillRowLabel(buf: []u8, m: secrets.Match) []const u8 {
    const lock: []const u8 = if (m.locked) " [locked]" else "";
    if (m.username.len != 0 and m.label.len != 0)
        return std.fmt.bufPrint(buf, "{s} ({s}){s}", .{ m.username, m.label, lock }) catch m.username;
    if (m.username.len != 0)
        return std.fmt.bufPrint(buf, "{s}{s}", .{ m.username, lock }) catch m.username;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ m.label, lock }) catch m.label;
}

pub fn onFillPick(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const row = cast.userData(FillRow, user);
    row.ctx.face.fillFrom(row.ctx.matches.items[row.index]);
}

/// Fetch one entry's secret and type it. The buffer is wiped by
/// `zeroFree` on every path, and the secret is never formatted
/// into a toast, a title or a log line.
pub fn fillFrom(self: *WebFace, m: secrets.Match) void {
    if (self.widgets_dead or !self.view_live) return;
    const secret = secrets.fetchSecret(self.allocator, m.path, m.locked) catch |err| {
        self.toast(switch (err) {
            error.Locked => "That entry is locked. Unlock the keyring, then try again.",
            error.NoBus, error.NoService => "The password manager stopped answering.",
            else => "Could not read that entry's password.",
        });
        return;
    };
    defer secrets.zeroFree(self.allocator, secret);
    // Typing walks codepoints, so a non-text secret (a key blob)
    // has to be refused rather than decoded.
    if (!std.unicode.utf8ValidateSlice(secret)) {
        self.toast("That entry's secret is not text.");
        return;
    }
    if (m.username.len != 0 and std.unicode.utf8ValidateSlice(m.username)) {
        self.typeIntoPage(m.username);
        self.tapKeyval(c.GDK_KEY_Tab);
    }
    self.typeIntoPage(secret);
}

/// Type `text` as ordinary key presses. `gdk_unicode_to_keyval`
/// round-trips through the helper's `gdk_keyval_to_unicode`, so
/// non-Latin1 characters survive.
pub fn typeIntoPage(self: *WebFace, text: []const u8) void {
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| self.tapKeyval(c.gdk_unicode_to_keyval(cp));
}

pub fn tapKeyval(self: *WebFace, keyval: c.guint) void {
    _ = self.sendKey(.down, keyval, 0, 0);
    _ = self.sendKey(.up, keyval, 0, 0);
}
