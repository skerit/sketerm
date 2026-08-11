//! One AdwAlertDialog builder for every confirm/prompt in the GUI.
//!
//! Every call site used to hand-write the same six lines (new,
//! add_response per button, set_response_appearance, default, close,
//! choose) plus a heap context whose only job was to carry the
//! caller's pointer through the async reply. Only the LAST part is
//! interesting, so it is the only part that stays at the call site:
//! `present` owns a small wrapper allocation and frees it in the
//! response handler, right after invoking `cb`.
//!
//! GUI-only — nothing here may be reachable from `sketerm-mux`.

const std = @import("std");
const c = @import("../c.zig").c;
const render_kick = @import("../util/render_kick.zig");

pub const Appearance = enum { default, suggested, destructive };

/// One button. `id` is what the callback compares against, so it is
/// the stable name; `label` is the user-visible text.
pub const Response = struct {
    id: [*:0]const u8,
    label: [*:0]const u8,
    appearance: Appearance = .default,
    /// Activated by Enter.
    is_default: bool = false,
    /// Reported when the dialog is dismissed (Escape, click-away).
    is_close: bool = false,
};

/// @param response the chosen response `id`, borrowed for the call.
pub const Cb = *const fn (ctx: ?*anyopaque, response: []const u8) void;

pub const Options = struct {
    heading: ?[*:0]const u8,
    body: ?[*:0]const u8 = null,
    responses: []const Response,
    /// Packed under the body (an entry, ...).
    extra_child: ?*c.GtkWidget = null,
    /// AdwAlertDialog focuses no extra child by itself, so a prompt
    /// that wants typing to land must name the widget here.
    focus: ?*c.GtkWidget = null,
    /// Toplevel whose GtkGraphicsOffload'd GL panes would otherwise
    /// composite over the dialog; see util/render_kick.zig.
    kick_root: ?*c.GtkWidget = null,
};

/// Who to tell about the answer. A dialog without one is a message
/// with nothing to decide, and needs no allocation at all.
pub const Action = struct {
    allocator: std.mem.Allocator,
    cb: Cb,
    ctx: ?*anyopaque = null,
};

const Pending = struct {
    allocator: std.mem.Allocator,
    cb: Cb,
    ctx: ?*anyopaque,
};

/// Build and show an alert dialog. With an `action` it is `choose`n and
/// the callback runs exactly once with the chosen response id; without
/// one it is merely presented.
///
/// @return the dialog, so a caller can hang its own qdata on it, or
/// null when the wrapper allocation failed and nothing was shown — a
/// caller that already allocated its own ctx must free it on null.
pub fn present(
    parent: ?*c.GtkWidget,
    opts: Options,
    action: ?Action,
) ?*c.AdwAlertDialog {
    // Allocated before the widget exists: a failure here must not
    // leave a floating dialog behind to dispose of.
    var pending: ?*Pending = null;
    if (action) |a| {
        const p = a.allocator.create(Pending) catch return null;
        p.* = .{ .allocator = a.allocator, .cb = a.cb, .ctx = a.ctx };
        pending = p;
    }

    const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(c.adw_alert_dialog_new(opts.heading, opts.body)));
    // Two passes: naming the default/close response before it has been
    // added is a libadwaita warning, and a caller is free to mark the
    // last button as either.
    for (opts.responses) |r| {
        c.adw_alert_dialog_add_response(dialog, r.id, r.label);
        switch (r.appearance) {
            .default => {},
            .suggested => c.adw_alert_dialog_set_response_appearance(dialog, r.id, c.ADW_RESPONSE_SUGGESTED),
            .destructive => c.adw_alert_dialog_set_response_appearance(dialog, r.id, c.ADW_RESPONSE_DESTRUCTIVE),
        }
    }
    for (opts.responses) |r| {
        if (r.is_default) c.adw_alert_dialog_set_default_response(dialog, r.id);
        if (r.is_close) c.adw_alert_dialog_set_close_response(dialog, r.id);
    }
    if (opts.extra_child) |child| c.adw_alert_dialog_set_extra_child(dialog, child);
    if (opts.focus) |w| c.adw_dialog_set_focus(@ptrCast(dialog), w);

    if (opts.kick_root) |root| {
        _ = c.g_signal_connect_data(dialog, "closed", @ptrCast(&render_kick.onDialogClosed), root, null, c.G_CONNECT_DEFAULT);
    }

    if (pending) |p| {
        c.adw_alert_dialog_choose(dialog, parent, null, onResponse, @ptrCast(p));
    } else {
        c.adw_dialog_present(@ptrCast(dialog), parent);
    }
    if (opts.kick_root) |root| render_kick.dialogPresented(root);
    return dialog;
}

fn onResponse(source: [*c]c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const pending: *Pending = @ptrCast(@alignCast(user.?));
    defer pending.allocator.destroy(pending);
    const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(source));
    const raw = c.adw_alert_dialog_choose_finish(dialog, result);
    const resp = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    pending.cb(pending.ctx, resp);
}
