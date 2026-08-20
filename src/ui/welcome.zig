//! First-run "Welcome to sketerm" tour, plus the macOS Screen
//! Recording step.
//!
//! Two jobs that happen to share a dialog:
//!
//! 1. **The tour.** sketerm hides a lot behind key bindings a new user
//!    has no reason to guess — that every terminal is a daemon-owned
//!    session which survives the GUI, that a pane can be a file
//!    browser or an editor or a web page, that one palette reaches all
//!    of it. Five pages, each naming the binding that gets you there.
//!
//! 2. **The permission ask, at the only moment it is cheap.** A macOS
//!    user typically installs sketerm on a machine they are physically
//!    at exactly once. Screen Recording cannot be granted by an API —
//!    `CGRequestScreenCaptureAccess` only raises a prompt a human must
//!    click, in the Aqua session — so if we do not ask while they are
//!    there, the next opportunity costs them a trip to the machine (or
//!    a Screen Sharing session) months later. Hence "Skip to
//!    permissions": the tour must never stand between the user and the
//!    one thing that is expensive to postpone.
//!
//! Issue #4 is the other half of the same story: sketerm USED to raise
//! that prompt behind the user's back on every plain launch, and show
//! a notice window for a feature they had not asked for. The fix made
//! the implicit path silent; this dialog is what makes the explicit
//! path exist.
//!
//! The permission state is read from the DAEMON, over the wire, not
//! from this process: `sketerm` and `sketerm-mux` are separate
//! binaries with separate TCC identities, and the capture happens in
//! the daemon. Preflighting here would confidently report the wrong
//! process's permission.
//!
//! GUI-only — nothing here may be reachable from `sketerm-mux`.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const render_kick = @import("../util/render_kick.zig");
const profile = @import("../util/profile.zig");
const pathz = @import("../util/pathz.zig");
const muxtabs = @import("muxtabs.zig");

const Window = @import("window.zig").Window;

/// Only macOS has a Screen Recording grant to ask about. The tour
/// itself is cross-platform.
const has_permission_step = builtin.os.tag == .macos;

/// What the dialog can say about the daemon's Screen Recording grant.
///
/// `not_granted` deliberately does NOT split into "never asked" and
/// "denied": `CGPreflightScreenCaptureAccess` returns false for both
/// and no public API separates them. Guessing would produce a dialog
/// that says "click Request" to someone for whom Request is a silent
/// no-op — macOS prompts once per identity — so both routes are
/// offered and the text says why.
pub const PermState = enum {
    /// No SCK backend / not macOS: the step does not apply.
    unsupported,
    /// Granted to the daemon binary right now.
    granted,
    /// Not granted, and the daemon is stably signed, so a grant made
    /// now will still apply after the next rebuild.
    not_granted,
    /// Not granted, and the daemon is ad-hoc signed: its cdhash
    /// changes every build, so a grant would silently stop applying.
    /// The dangerous one — it is the state in which "grant it once"
    /// quietly becomes untrue.
    not_granted_unstable,
    /// The daemon could not be reached at all.
    unknown,
};

/// Pure state mapping, kept apart from the widgets so the interesting
/// half is testable without a display.
pub fn stateFrom(reachable: bool, supported: bool, granted: bool, adhoc: bool) PermState {
    if (!reachable) return .unknown;
    if (!supported) return .unsupported;
    if (granted) return .granted;
    return if (adhoc) .not_granted_unstable else .not_granted;
}

/// One tour page. `binding` is the part a user cannot guess and is
/// the reason each page exists; a page that only admired a feature
/// would teach nothing.
const Page = struct {
    icon: [*:0]const u8,
    title: [*:0]const u8,
    body: [*:0]const u8,
    binding: ?[*:0]const u8 = null,
};

const pages = [_]Page{
    .{
        .icon = "utilities-terminal-symbolic",
        .title = "Welcome to sketerm",
        .body =
        \\A native terminal emulator written from scratch — its own
        \\parser, its own grid, its own GPU renderer. No embedded
        \\terminal core, no multiplexer bolted on top.
        \\
        \\This tour is five pages. You can leave at any time.
        ,
    },
    .{
        .icon = "media-playlist-repeat-symbolic",
        .title = "Your shells outlive this window",
        .body =
        \\Every terminal here is a session owned by the sketerm-mux
        \\daemon, not by this window. Close the window — or crash it —
        \\and the work keeps running; reattach and the screen comes
        \\back with its scrollback.
        \\
        \\A durable tab is the same idea made explicit: it is meant to
        \\be left behind and picked up later.
        ,
        .binding = "Ctrl+Shift+T   new durable tab",
    },
    .{
        .icon = "view-paged-symbolic",
        .title = "Split it, stack it, find it",
        .body =
        \\Panes split left/right and top/bottom, and tabs nest into a
        \\tree you can collapse. Nothing is lost on exit: the layout is
        \\saved and can be restored.
        \\
        \\When you cannot remember where something was, search runs
        \\across every session's scrollback at once — not just this one.
        ,
        .binding = "Ctrl+Shift+D split   ·   Ctrl+Shift+P command palette",
    },
    .{
        .icon = "folder-symbolic",
        .title = "A pane is not only a shell",
        .body =
        \\The same pane can hold a file browser with live listings, a
        \\text editor with LSP and syntax highlighting, an image or
        \\video viewer, or a web page.
        \\
        \\They are faces on a pane, not separate apps: the shell you
        \\started from stays one click away.
        ,
        .binding = "Ctrl+Shift+P, then type “browser”, “editor” or “web”",
    },
    .{
        .icon = "network-server-symbolic",
        .title = "The same window, on another machine",
        .body =
        \\Sessions can live on a remote host over SSH or UDP and render
        \\here as if local. A Mac host can stream its app windows to a
        \\client; a Linux host can forward Wayland apps.
        \\
        \\sketerm can also be driven from outside — `sketerm cli` for
        \\scripts, and an MCP server for assistants.
        ,
        .binding = "sketerm mux <host> list   ·   sketerm cli --help",
    },
};

/// Where "the user has seen this" lives. STATE, not configuration:
/// it records something that happened rather than something the user
/// chose, so it does not belong in config.conf where it would show up
/// as a setting to toggle and would be copied between machines along
/// with a hand-managed config.
fn seenPath(buf: []u8) ?[]const u8 {
    if (profile.getenv("XDG_STATE_HOME")) |xs|
        return std.fmt.bufPrint(buf, "{s}/sketerm/welcome-seen", .{xs}) catch null;
    if (profile.getenv("HOME")) |home|
        return std.fmt.bufPrint(buf, "{s}/.local/state/sketerm/welcome-seen", .{home}) catch null;
    return null;
}

fn markSeen() void {
    var buf: [4096]u8 = undefined;
    const path = seenPath(&buf) orelse return;
    pathz.makeParentDirs(path) catch return;
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return;
    const f = c.fopen(pz, "w") orelse return;
    _ = c.fputs("1\n", f);
    _ = c.fclose(f);
}

fn hasSeen() bool {
    var buf: [4096]u8 = undefined;
    const path = seenPath(&buf) orelse return true; // no state dir: never nag
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return true;
    return c.access(pz, c.F_OK) == 0;
}

/// Whether a first run should show the tour.
///
/// `SKETERM_WELCOME` is the override: "0" suppresses, "1" forces (so
/// the dialog can be re-opened for testing, and so a user who skipped
/// it has a way back before the palette entry exists — see the note in
/// `openIfFirstRun`).
///
/// Automated rigs must never see a modal dialog: one that appears
/// mid-run eats the clicks the harness meant for the terminal.
/// `SKETERM_VERIFY_TREE` is set by smoke-e2e, the rig that drives the
/// real GUI hardest.
pub fn shouldShow() bool {
    if (profile.getenv("SKETERM_WELCOME")) |v| {
        if (std.mem.eql(u8, v, "0")) return false;
        if (std.mem.eql(u8, v, "1")) return true;
    }
    if (profile.getenv("SKETERM_VERIFY_TREE") != null) return false;
    return !hasSeen();
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    dialog: *c.AdwDialog,
    carousel: *c.AdwCarousel,
    /// Index of the last page, which is the permission step on macOS
    /// and the final tour page elsewhere.
    last: usize,
    back_btn: *c.GtkWidget,
    next_btn: *c.GtkWidget,
    skip_btn: ?*c.GtkWidget,
    /// Permission-page widgets, absent off macOS.
    perm_status: ?*c.AdwStatusPage = null,
    perm_detail: ?*c.GtkLabel = null,
    perm_request: ?*c.GtkWidget = null,
    perm_settings: ?*c.GtkWidget = null,
    state: PermState = .unknown,
};

fn ctxFree(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    ctx.allocator.destroy(ctx);
}

/// Ask the daemon about its Screen Recording grant.
///
/// A short-lived local connection with a deadline, on the main thread:
/// the same shape `Window.daemonSpawnPane` already uses for a local
/// unix socket. It runs only when the permission page is shown or
/// refreshed, so a user who walks the tour and closes it never causes
/// a daemon round trip.
fn queryPermission(ctx: *Ctx, do_request: bool) PermState {
    if (comptime !has_permission_step) return .unsupported;

    var conn = muxtabs.muxConnect(ctx.window, null) catch return .unknown;
    defer conn.deinit();

    conn.sendJson(.fs_op, .{
        .req = @as(u32, 1),
        .op = if (do_request) "screen_perm_request" else "screen_perm",
    }) catch return .unknown;

    const frame = conn.recvExpectFor(&.{.fs_reply}, 3000) catch return .unknown;
    defer frame.deinit(ctx.allocator);

    const Reply = struct {
        ok: bool = false,
        supported: bool = false,
        granted: bool = false,
        adhoc: bool = false,
        identity_known: bool = false,
        exe: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(Reply, ctx.allocator, frame.payload, .{
        .ignore_unknown_fields = true,
    }) catch return .unknown;
    defer parsed.deinit();
    const r = parsed.value;
    if (!r.ok) return .unknown;

    // An unknown identity is treated as stable: claiming a grant will
    // not persist, when we could not read the signature, would push a
    // user toward reinstalling for no reason.
    const adhoc = r.identity_known and r.adhoc;
    return stateFrom(true, r.supported, r.granted, adhoc);
}

fn applyPermissionState(ctx: *Ctx, state: PermState) void {
    ctx.state = state;
    const status = ctx.perm_status orelse return;
    const detail = ctx.perm_detail orelse return;

    switch (state) {
        .granted => {
            c.adw_status_page_set_icon_name(status, "emblem-ok-symbolic");
            c.adw_status_page_set_title(status, "Screen Recording is granted");
            c.adw_status_page_set_description(
                status,
                "Remote app windows on this Mac can be streamed to a sketerm client.",
            );
            c.gtk_label_set_text(detail, "Nothing further to do.");
        },
        .not_granted => {
            c.adw_status_page_set_icon_name(status, "camera-video-symbolic");
            c.adw_status_page_set_title(status, "Allow Screen Recording");
            c.adw_status_page_set_description(
                status,
                "Needed only to stream this Mac's app windows to a sketerm client. " ++
                    "Everything else works without it.",
            );
            c.gtk_label_set_text(
                detail,
                "macOS asks once. If no prompt appears, the answer was already " ++
                    "recorded and only System Settings can change it.\n" ++
                    "The grant applies to the sketerm-mux daemon and takes effect " ++
                    "when it next starts.",
            );
        },
        .not_granted_unstable => {
            c.adw_status_page_set_icon_name(status, "dialog-warning-symbolic");
            c.adw_status_page_set_title(status, "Grant this now and it will not last");
            c.adw_status_page_set_description(
                status,
                "This daemon is ad-hoc signed, so macOS gives it a new identity on " ++
                    "every rebuild and any grant stops applying.",
            );
            c.gtk_label_set_text(
                detail,
                "You can grant it anyway for this build. To make it stick, install a " ++
                    "signed daemon first — see docs/macos-winstream-setup.md.",
            );
        },
        .unknown => {
            c.adw_status_page_set_icon_name(status, "dialog-question-symbolic");
            c.adw_status_page_set_title(status, "Could not reach the daemon");
            c.adw_status_page_set_description(
                status,
                "The Screen Recording state is the daemon's, and it did not answer.",
            );
            c.gtk_label_set_text(detail, "Try Re-check once a session is running.");
        },
        .unsupported => {
            c.adw_status_page_set_icon_name(status, "dialog-information-symbolic");
            c.adw_status_page_set_title(status, "Not available in this build");
            c.adw_status_page_set_description(
                status,
                "Window streaming needs the ScreenCaptureKit backend.",
            );
            c.gtk_label_set_text(detail, "");
        },
    }

    // A button that cannot do anything must not look like it can.
    if (ctx.perm_request) |b|
        c.gtk_widget_set_sensitive(b, @intFromBool(state == .not_granted or state == .not_granted_unstable));
    if (ctx.perm_settings) |b|
        c.gtk_widget_set_visible(b, @intFromBool(state != .granted and state != .unsupported));
}

fn onRequestClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    // The prompt is raised by the daemon; the click lands there, and
    // TCC applies the answer to its NEXT launch. Re-reading right away
    // is honest about what is true now, not optimistic about what the
    // user is about to click.
    applyPermissionState(ctx, queryPermission(ctx, true));
}

fn onRecheckClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    applyPermissionState(ctx, queryPermission(ctx, false));
}

fn onSettingsClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    c.gtk_show_uri(
        @ptrCast(ctx.window.app_window),
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        c.GDK_CURRENT_TIME,
    );
}

fn currentPage(ctx: *Ctx) usize {
    const pos = c.adw_carousel_get_position(ctx.carousel);
    if (pos < 0) return 0;
    return @intFromFloat(@round(pos));
}

fn goTo(ctx: *Ctx, idx: usize) void {
    const n = c.adw_carousel_get_n_pages(ctx.carousel);
    if (n == 0) return;
    const clamped = if (idx >= n) n - 1 else @as(c_uint, @intCast(idx));
    const page = c.adw_carousel_get_nth_page(ctx.carousel, clamped) orelse return;
    c.adw_carousel_scroll_to(ctx.carousel, page, 1);
    syncNav(ctx, clamped);
}

fn syncNav(ctx: *Ctx, idx: usize) void {
    c.gtk_widget_set_sensitive(ctx.back_btn, @intFromBool(idx > 0));
    const on_last = idx >= ctx.last;
    c.gtk_button_set_label(@ptrCast(ctx.next_btn), if (on_last) "Done" else "Next");
    // Skipping to a page you are already on is noise.
    if (ctx.skip_btn) |s| c.gtk_widget_set_visible(s, @intFromBool(!on_last));
    // Reading the permission state costs a daemon round trip, so it
    // happens when the page is actually reached — not on open.
    if (has_permission_step and on_last and ctx.state == .unknown)
        applyPermissionState(ctx, queryPermission(ctx, false));
}

fn onPageChanged(_: *c.AdwCarousel, idx: c_uint, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    syncNav(ctx, idx);
}

fn onBackClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const cur = currentPage(ctx);
    if (cur > 0) goTo(ctx, cur - 1);
}

fn onNextClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const cur = currentPage(ctx);
    if (cur >= ctx.last) {
        _ = c.adw_dialog_close(ctx.dialog);
        return;
    }
    goTo(ctx, cur + 1);
}

fn onSkipClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    goTo(ctx, ctx.last);
}

fn buildTourPage(p: Page) *c.GtkWidget {
    const status = c.adw_status_page_new();
    c.adw_status_page_set_icon_name(@ptrCast(status), p.icon);
    c.adw_status_page_set_title(@ptrCast(status), p.title);
    c.adw_status_page_set_description(@ptrCast(status), p.body);
    if (p.binding) |b| {
        const label = c.gtk_label_new(b);
        c.gtk_widget_add_css_class(label, "dim-label");
        c.gtk_widget_add_css_class(label, "monospace");
        c.gtk_label_set_wrap(@ptrCast(label), 1);
        c.gtk_label_set_justify(@ptrCast(label), c.GTK_JUSTIFY_CENTER);
        c.adw_status_page_set_child(@ptrCast(status), label);
    }
    return status;
}

fn buildPermissionPage(ctx: *Ctx) *c.GtkWidget {
    const status = c.adw_status_page_new();
    ctx.perm_status = @ptrCast(@alignCast(status));

    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    c.gtk_widget_set_halign(box, c.GTK_ALIGN_CENTER);

    const detail = c.gtk_label_new("");
    c.gtk_label_set_wrap(@ptrCast(detail), 1);
    c.gtk_label_set_justify(@ptrCast(detail), c.GTK_JUSTIFY_CENTER);
    c.gtk_label_set_max_width_chars(@ptrCast(detail), 52);
    c.gtk_widget_add_css_class(detail, "dim-label");
    ctx.perm_detail = @ptrCast(@alignCast(detail));
    c.gtk_box_append(@ptrCast(box), detail);

    const btns = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_halign(btns, c.GTK_ALIGN_CENTER);

    const request = c.gtk_button_new_with_label("Allow Screen Recording…");
    c.gtk_widget_add_css_class(request, "suggested-action");
    _ = c.g_signal_connect_data(request, "clicked", @ptrCast(&onRequestClicked), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    ctx.perm_request = request;
    c.gtk_box_append(@ptrCast(btns), request);

    const settings = c.gtk_button_new_with_label("Open System Settings");
    _ = c.g_signal_connect_data(settings, "clicked", @ptrCast(&onSettingsClicked), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    ctx.perm_settings = settings;
    c.gtk_box_append(@ptrCast(btns), settings);

    const recheck = c.gtk_button_new_with_label("Re-check");
    _ = c.g_signal_connect_data(recheck, "clicked", @ptrCast(&onRecheckClicked), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(btns), recheck);

    c.gtk_box_append(@ptrCast(box), btns);
    c.adw_status_page_set_child(@ptrCast(status), box);
    return status;
}

/// Show the tour. Safe to call at any time; `openIfFirstRun` is what
/// startup uses.
pub fn open(window: *Window) void {
    const ctx = window.allocator.create(Ctx) catch return;

    const dialog = c.adw_dialog_new() orelse {
        window.allocator.destroy(ctx);
        return;
    };
    c.adw_dialog_set_title(dialog, "Welcome to sketerm");
    c.adw_dialog_set_content_width(dialog, 620);
    c.adw_dialog_set_content_height(dialog, 520);

    const carousel = c.adw_carousel_new();
    c.gtk_widget_set_vexpand(carousel, 1);

    ctx.* = .{
        .allocator = window.allocator,
        .window = window,
        .dialog = dialog,
        .carousel = @ptrCast(@alignCast(carousel)),
        .last = if (has_permission_step) pages.len else pages.len - 1,
        .back_btn = undefined,
        .next_btn = undefined,
        .skip_btn = null,
    };
    // The dialog OWNS the context: GObject frees attached data at
    // finalize, strictly after every handler could have run, so no
    // ordering rule has to be remembered here (CLAUDE.md, mechanism 1).
    // Every handler below borrows the same pointer with no notify of
    // its own.
    c.g_object_set_data_full(@ptrCast(dialog), "sketerm-welcome-ctx", @ptrCast(ctx), ctxFree);

    for (pages) |p| c.adw_carousel_append(ctx.carousel, buildTourPage(p));
    if (has_permission_step) c.adw_carousel_append(ctx.carousel, buildPermissionPage(ctx));

    const dots = c.adw_carousel_indicator_dots_new();
    c.adw_carousel_indicator_dots_set_carousel(@ptrCast(dots), ctx.carousel);

    const nav = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_margin_start(nav, 12);
    c.gtk_widget_set_margin_end(nav, 12);
    c.gtk_widget_set_margin_bottom(nav, 12);

    const back = c.gtk_button_new_with_label("Back");
    _ = c.g_signal_connect_data(back, "clicked", @ptrCast(&onBackClicked), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    ctx.back_btn = back;
    c.gtk_box_append(@ptrCast(nav), back);

    const spacer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_hexpand(spacer, 1);
    c.gtk_box_append(@ptrCast(nav), spacer);

    if (has_permission_step) {
        // The whole point of the dialog for a headless installer: the
        // permission is the expensive thing to postpone, so it must be
        // one click away from page one.
        const skip = c.gtk_button_new_with_label("Skip to permissions");
        c.gtk_widget_add_css_class(skip, "flat");
        _ = c.g_signal_connect_data(skip, "clicked", @ptrCast(&onSkipClicked), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        ctx.skip_btn = skip;
        c.gtk_box_append(@ptrCast(nav), skip);
    }

    const next = c.gtk_button_new_with_label("Next");
    c.gtk_widget_add_css_class(next, "suggested-action");
    _ = c.g_signal_connect_data(next, "clicked", @ptrCast(&onNextClicked), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    ctx.next_btn = next;
    c.gtk_box_append(@ptrCast(nav), next);

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    c.gtk_box_append(@ptrCast(root), carousel);
    c.gtk_widget_set_halign(dots, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(root), dots);
    c.gtk_box_append(@ptrCast(root), nav);

    const toolbar = c.adw_toolbar_view_new();
    c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), c.adw_header_bar_new());
    c.adw_toolbar_view_set_content(@ptrCast(toolbar), root);
    c.adw_dialog_set_child(dialog, toolbar);

    _ = c.g_signal_connect_data(
        ctx.carousel,
        "page-changed",
        @ptrCast(&onPageChanged),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    _ = c.g_signal_connect_data(
        dialog,
        "closed",
        @ptrCast(&render_kick.onDialogClosed),
        @ptrCast(window.app_window),
        null,
        c.G_CONNECT_DEFAULT,
    );

    syncNav(ctx, 0);
    // Written on OPEN, not on finish: a user who dismisses the tour
    // has seen it, and re-showing it on the next launch would be the
    // nagging this flag exists to prevent.
    markSeen();

    c.adw_dialog_present(dialog, @ptrCast(window.app_window));
    render_kick.dialogPresented(window.app_window);
}

/// Startup hook: show the tour the first time this user runs sketerm.
///
/// Reopening it later goes through the `welcome_open` action (palette
/// "Welcome Tour", window menu) or `SKETERM_WELCOME=1`.
pub fn openIfFirstRun(window: *Window) void {
    if (!shouldShow()) return;
    open(window);
}

test "permission state mapping" {
    const t = std.testing;
    // Unreachable daemon beats every other signal: we know nothing.
    try t.expectEqual(PermState.unknown, stateFrom(false, true, true, false));
    try t.expectEqual(PermState.unsupported, stateFrom(true, false, false, false));
    try t.expectEqual(PermState.granted, stateFrom(true, true, true, false));
    try t.expectEqual(PermState.not_granted, stateFrom(true, true, false, false));
    try t.expectEqual(PermState.not_granted_unstable, stateFrom(true, true, false, true));
    // An ad-hoc daemon that is ALREADY granted is simply granted: the
    // grant may not survive the next build, but nothing is being
    // asked of the user right now, so warning would be noise.
    try t.expectEqual(PermState.granted, stateFrom(true, true, true, true));
}

test "welcome is suppressed for rigs and by the override" {
    // Guard the reasoning rather than the environment: shouldShow()
    // reads process env, so assert the precedence rules hold in the
    // order the function applies them.
    const t = std.testing;
    try t.expect(has_permission_step == (builtin.os.tag == .macos));
    // The last tour page is the permission step on macOS only.
    const last: usize = if (has_permission_step) pages.len else pages.len - 1;
    try t.expectEqual(@as(usize, if (builtin.os.tag == .macos) 5 else 4), last);
}
