//! The tail every hamburger menu in the suite ends with: Keyboard
//! Shortcuts and About.
//!
//! Five surfaces grow a primary menu (terminal window, file manager,
//! web face, standalone editor, standalone viewer) and each used to
//! answer "what version is this?" differently or not at all. The two
//! informational surfaces live here once, and `appendHelp` puts them
//! at the bottom of any `classicmenu` in two lines.
//!
//! Both surfaces are separate transient NON-MODAL toplevels, never
//! attached `AdwDialog` sheets — the same rule the file browser's
//! Preferences and About already follow (`src/ui/browser/CLAUDE.md`).
//! That is why this builds an `AdwAboutWindow` and not the newer
//! `AdwAboutDialog`.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const classicmenu = @import("browser/classicmenu.zig");
const cssutil = @import("cssutil.zig");
const input = @import("input.zig");
const version = @import("../version.zig");
const build_options = @import("build_options");
const Config = @import("../config.zig").Config;

/// Which application the About window should name itself after. Each
/// mode is its own application identity (own desktop entry, own icon),
/// so the About window follows the identity rather than the binary.
pub const Identity = enum {
    terminal,
    files,
    web,
    editor,
    viewer,

    fn appName(self: Identity) [*:0]const u8 {
        return switch (self) {
            .terminal => "Sketerm",
            .files => "Sketerm Files",
            .web => "Sketerm Web",
            .editor => "Sketerm Editor",
            .viewer => "Sketerm Viewer",
        };
    }

    /// Only three app icons ship; the editor and the viewer are hosted
    /// by the terminal identity and use its icon.
    fn iconName(self: Identity) [*:0]const u8 {
        return switch (self) {
            .files => "dev.sker.sketerm.files",
            .web => "dev.sker.sketerm.web",
            else => "dev.sker.sketerm",
        };
    }
};

/// Version, commit and commit date, all from build time.
pub fn showAbout(parent: ?*c.GtkWindow, identity: Identity) void {
    const about = c.adw_about_window_new() orelse return;
    c.adw_about_window_set_application_name(@ptrCast(about), identity.appName());
    c.adw_about_window_set_application_icon(@ptrCast(about), identity.iconName());
    c.adw_about_window_set_developer_name(@ptrCast(about), "Jelle De Loecker");
    c.adw_about_window_set_license_type(@ptrCast(about), c.GTK_LICENSE_GPL_3_0);
    var vz: [192:0]u8 = undefined;
    const ver = std.fmt.bufPrintZ(&vz, "{s} ({s}, {s})", .{
        version.string,
        build_options.commit,
        build_options.commit_date,
    }) catch "0";
    c.adw_about_window_set_version(@ptrCast(about), ver.ptr);
    var cz: [256:0]u8 = undefined;
    const info = std.fmt.bufPrintZ(&cz, "Commit {s}, built from source dated {s}.", .{
        build_options.commit,
        build_options.commit_date,
    }) catch "";
    c.adw_about_window_set_comments(@ptrCast(about), info.ptr);
    if (parent) |p| c.gtk_window_set_transient_for(@ptrCast(about), p);
    c.gtk_window_present(@ptrCast(about));
}

/// The ACTIVE keybinding table, laid out as one scrolling list of
/// chord + description rows.
///
/// Built from `input.default_bindings` overlaid with the user's
/// `keybind.*` config, i.e. exactly what `input.zig` dispatches — a
/// hardcoded cheat sheet would drift from the config the first time
/// somebody rebinds something.
pub fn showShortcuts(allocator: std.mem.Allocator, parent: ?*c.GtkWindow) void {
    // Nothing built here outlives this function: the rows become GTK
    // widgets, and the table is only read while they are built.
    var config = Config.load(allocator);
    defer config.deinit();
    var list: std.ArrayList(input.Binding) = .empty;
    defer list.deinit(allocator);
    input.rebuildBindings(&list, allocator, config.keybinds.items);

    const window = c.adw_window_new() orelse return;
    c.gtk_window_set_title(@ptrCast(window), "Keyboard Shortcuts");
    c.gtk_window_set_default_size(@ptrCast(window), 620, 720);
    if (parent) |p| c.gtk_window_set_transient_for(@ptrCast(window), p);

    const toolbar = c.adw_toolbar_view_new().?;
    c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), c.adw_header_bar_new().?);

    const scroll = c.gtk_scrolled_window_new().?;
    c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_vexpand(scroll, 1);
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
    c.gtk_widget_set_margin_start(box, 18);
    c.gtk_widget_set_margin_end(box, 18);
    c.gtk_widget_set_margin_top(box, 12);
    c.gtk_widget_set_margin_bottom(box, 18);
    installCss(box);

    for (list.items) |b| {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12).?;
        const accel_ptr = c.gtk_accelerator_get_label(b.keyval, b.mods);
        const accel = c.gtk_label_new(accel_ptr).?;
        if (accel_ptr != null) c.g_free(accel_ptr);
        c.gtk_label_set_xalign(@ptrCast(accel), 1);
        c.gtk_widget_set_size_request(accel, 190, -1);
        c.gtk_widget_add_css_class(accel, "sketerm-shortcut-accel");
        c.gtk_box_append(@ptrCast(row), accel);
        var zbuf: [160:0]u8 = undefined;
        const label = input.actionLabel(b.action);
        const n = @min(label.len, zbuf.len - 1);
        @memcpy(zbuf[0..n], label[0..n]);
        zbuf[n] = 0;
        const desc = c.gtk_label_new(&zbuf).?;
        c.gtk_label_set_xalign(@ptrCast(desc), 0);
        c.gtk_widget_set_hexpand(desc, 1);
        c.gtk_box_append(@ptrCast(row), desc);
        c.gtk_box_append(@ptrCast(box), row);
    }

    c.gtk_scrolled_window_set_child(@ptrCast(scroll), box);
    c.adw_toolbar_view_set_content(@ptrCast(toolbar), scroll);
    c.adw_window_set_content(@ptrCast(window), toolbar);
    c.gtk_window_present(@ptrCast(window));
}

fn installCss(any_widget: *c.GtkWidget) void {
    const css =
        \\label.sketerm-shortcut-accel {
        \\  font-family: monospace;
        \\  opacity: 0.75;
        \\}
    ;
    cssutil.install("appmenu", any_widget, css);
}

/// Per-row state for the two rows below. One allocation serves both
/// rows and is owned by the menu Root (mechanism 1: the popover frees
/// it), exactly like every other classicmenu per-item context.
const HelpCtx = struct {
    allocator: std.mem.Allocator,
    /// Transient parent for the windows the rows open. Borrowed: it is
    /// only read while the popover is up, and the popover dies with
    /// its parent widget.
    parent: ?*c.GtkWindow,
    identity: Identity,
};

fn onShortcuts(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(HelpCtx, user);
    showShortcuts(ctx.allocator, ctx.parent);
}

fn onAbout(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(HelpCtx, user);
    showAbout(ctx.parent, ctx.identity);
}

/// Append the shared Help section (its own separator, then Keyboard
/// Shortcuts and About) to a hamburger menu under construction.
pub fn appendHelp(
    m: classicmenu.Menu,
    allocator: std.mem.Allocator,
    parent: ?*c.GtkWindow,
    identity: Identity,
) void {
    const ctx = allocator.create(HelpCtx) catch return;
    ctx.* = .{ .allocator = allocator, .parent = parent, .identity = identity };
    m.root.own(cast.destroyCtx(HelpCtx), @ptrCast(ctx));
    const help = m.section();
    help.itemIcon("Keyboard Shortcuts", .{ .name = "preferences-desktop-keyboard-shortcuts-symbolic" }, &onShortcuts, @ptrCast(ctx));
    var zbuf: [64:0]u8 = undefined;
    const about = std.fmt.bufPrintZ(&zbuf, "About {s}", .{identity.appName()}) catch "About";
    help.itemIcon(about.ptr, .{ .name = "help-about-symbolic" }, &onAbout, @ptrCast(ctx));
}

test "appmenu: every identity names an app and an icon" {
    // A missing arm here is an About window titled after the wrong
    // application, which nobody notices until a bug report shows it.
    inline for (@typeInfo(Identity).@"enum".fields) |field| {
        const id: Identity = @enumFromInt(field.value);
        try std.testing.expect(std.mem.span(id.appName()).len != 0);
        try std.testing.expect(std.mem.startsWith(u8, std.mem.span(id.iconName()), "dev.sker.sketerm"));
    }
}
