//! `sketerm portal` — an OPT-IN xdg-desktop-portal FileChooser
//! backend serving the native sketerm picker to any portal-using
//! application. A hold()-ed GApplication (id dev.sker.sketerm.portal,
//! no window at startup) owns org.freedesktop.impl.portal.desktop.sketerm
//! on the session bus and implements org.freedesktop.impl.portal.FileChooser
//! at /org/freedesktop/portal/desktop via GIO's GDBus. Pure policy
//! (option mapping, filter conversion, URI encoding) is GTK-free in
//! src/portal.zig; selection happens through docs/portal.md's opt-in
//! portals.conf line, never automatically.
//!
//! Portal-specific picker behaviour (all of it opt-in per call, so
//! the plain picker keeps its own rules):
//! - parent_window handles ARE imported: the dialog is a transient
//!   child of the caller's window (xdg_foreign on Wayland,
//!   XSetTransientForHint on X11 -- src/ui/picker.zig).
//! - filters carry both globs and mimetypes; `current_filter` picks
//!   the entry selected on open, and the accepted filter is echoed
//!   back in the results.
//! - the active filter governs TYPED names too (enforce_filter): an
//!   app that asked for *.png must not be handed notes.txt.
//! - REMOTE picks cannot mean anything to a portal consumer, so the
//!   picker refuses them in the dialog (local_only) instead of
//!   dropping them silently on the way out.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const platform = @import("../util/platform.zig");
const policy = @import("../portal.zig");
const fpicker = @import("../filebrowser/picker.zig");
const PickerWindow = @import("picker.zig").PickerWindow;

const APP_ID: [*:0]const u8 = "dev.sker.sketerm.portal";
const BUS_NAME: [*:0]const u8 = "org.freedesktop.impl.portal.desktop.sketerm";
const OBJECT_PATH: [*:0]const u8 = "/org/freedesktop/portal/desktop";

/// Advertised impl version. 2 covers OpenFile/SaveFile/SaveFiles with
/// the options handled here; newer frontends simply skip features the
/// backend does not announce.
const IMPL_VERSION: u32 = 2;

const FILECHOOSER_XML: [*:0]const u8 =
    \\<node>
    \\  <interface name="org.freedesktop.impl.portal.FileChooser">
    \\    <method name="OpenFile">
    \\      <arg type="o" name="handle" direction="in"/>
    \\      <arg type="s" name="app_id" direction="in"/>
    \\      <arg type="s" name="parent_window" direction="in"/>
    \\      <arg type="s" name="title" direction="in"/>
    \\      <arg type="a{sv}" name="options" direction="in"/>
    \\      <arg type="u" name="response" direction="out"/>
    \\      <arg type="a{sv}" name="results" direction="out"/>
    \\    </method>
    \\    <method name="SaveFile">
    \\      <arg type="o" name="handle" direction="in"/>
    \\      <arg type="s" name="app_id" direction="in"/>
    \\      <arg type="s" name="parent_window" direction="in"/>
    \\      <arg type="s" name="title" direction="in"/>
    \\      <arg type="a{sv}" name="options" direction="in"/>
    \\      <arg type="u" name="response" direction="out"/>
    \\      <arg type="a{sv}" name="results" direction="out"/>
    \\    </method>
    \\    <method name="SaveFiles">
    \\      <arg type="o" name="handle" direction="in"/>
    \\      <arg type="s" name="app_id" direction="in"/>
    \\      <arg type="s" name="parent_window" direction="in"/>
    \\      <arg type="s" name="title" direction="in"/>
    \\      <arg type="a{sv}" name="options" direction="in"/>
    \\      <arg type="u" name="response" direction="out"/>
    \\      <arg type="a{sv}" name="results" direction="out"/>
    \\    </method>
    \\    <property name="version" type="u" access="read"/>
    \\  </interface>
    \\</node>
;

const REQUEST_XML: [*:0]const u8 =
    \\<node>
    \\  <interface name="org.freedesktop.impl.portal.Request">
    \\    <method name="Close"/>
    \\  </interface>
    \\</node>
;

const Portal = struct {
    allocator: std.mem.Allocator,
    conn: ?*c.GDBusConnection = null,
    owner_id: c.guint = 0,
    fc_reg: c.guint = 0,
    fc_info: [*c]c.GDBusInterfaceInfo = null,
    req_info: [*c]c.GDBusInterfaceInfo = null,
};

var g_portal: Portal = undefined;

/// One in-flight chooser call: the pending invocation, its exported
/// Request object and the open picker. Freed when the reply is sent.
const ActiveCall = struct {
    allocator: std.mem.Allocator,
    invocation: ?*c.GDBusMethodInvocation,
    method: policy.Method,
    handle_path: [:0]u8,
    request_reg: c.guint = 0,
    picker: ?*PickerWindow = null,
    /// SaveFiles: leaf names to append to the chosen directory (owned).
    names: [][]u8 = &.{},
    /// Close() arrived: the pending reply becomes response 2.
    closed: bool = false,
    done: bool = false,
    /// The caller's `filters` array and (when it sent one that was
    /// not in that array) its `current_filter`, kept referenced so
    /// the reply can echo the ORIGINAL variant rather than rebuild
    /// one. Unreffed in finish().
    filters_v: ?*c.GVariant = null,
    current_v: ?*c.GVariant = null,
    /// Source index in the caller's filter list per picker filter;
    /// SRC_CURRENT means "the appended current_filter" (owned).
    filter_srcs: []usize = &.{},
    /// Defaults echoed for the `choices` option (owned, "id\x00value").
    choices: [][]u8 = &.{},
    /// Picker filter index the user accepted under (null = All files).
    chosen_filter: ?usize = null,
    /// Watch on the calling bus name: a frontend that dies takes its
    /// dialog with it.
    watch_id: c.guint = 0,
};

const SRC_CURRENT = std.math.maxInt(usize);

pub fn run(allocator: std.mem.Allocator) u8 {
    g_portal = .{ .allocator = allocator };
    const app = c.adw_application_new(APP_ID, c.G_APPLICATION_DEFAULT_FLAGS);
    defer c.g_object_unref(app);
    _ = c.g_signal_connect_data(app, "startup", @ptrCast(&onStartup), null, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&onActivate), null, null, c.G_CONNECT_DEFAULT);
    const status = c.g_application_run(@ptrCast(app), 0, null);
    if (g_portal.owner_id != 0) c.g_bus_unown_name(g_portal.owner_id);
    return @intCast(status & 0xff);
}

fn onStartup(app: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    // No window at startup; the hold keeps the service alive until the
    // session bus (or the user) kills it.
    c.g_application_hold(app);

    const fc_node = c.g_dbus_node_info_new_for_xml(FILECHOOSER_XML, null);
    const req_node = c.g_dbus_node_info_new_for_xml(REQUEST_XML, null);
    if (fc_node == null or req_node == null) {
        _ = c.fputs("sketerm portal: introspection XML failed to parse\n", platform.stderr());
        c.g_application_quit(app);
        return;
    }
    // Node infos live for the process; never freed by design.
    g_portal.fc_info = c.g_dbus_node_info_lookup_interface(fc_node, "org.freedesktop.impl.portal.FileChooser");
    g_portal.req_info = c.g_dbus_node_info_lookup_interface(req_node, "org.freedesktop.impl.portal.Request");

    // ALLOW_REPLACEMENT + REPLACE: a restarted backend takes over from
    // a lingering older instance instead of failing to own the name.
    g_portal.owner_id = c.g_bus_own_name(
        c.G_BUS_TYPE_SESSION,
        BUS_NAME,
        c.G_BUS_NAME_OWNER_FLAGS_ALLOW_REPLACEMENT | c.G_BUS_NAME_OWNER_FLAGS_REPLACE,
        @ptrCast(&onBusAcquired),
        null,
        @ptrCast(&onNameLost),
        @ptrCast(app),
        null,
    );
}

fn onActivate(_: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    // Deliberately empty: the service has no window until a chooser
    // call opens a picker.
}

const FC_VTABLE = c.GDBusInterfaceVTable{
    .method_call = @ptrCast(&onFcMethodCall),
    .get_property = @ptrCast(&onFcGetProperty),
    .set_property = null,
};

const REQ_VTABLE = c.GDBusInterfaceVTable{
    .method_call = @ptrCast(&onReqMethodCall),
    .get_property = null,
    .set_property = null,
};

fn onBusAcquired(connection: ?*c.GDBusConnection, _: [*c]const c.gchar, user: ?*anyopaque) callconv(.c) void {
    g_portal.conn = connection;
    var err: [*c]c.GError = null;
    g_portal.fc_reg = c.g_dbus_connection_register_object(
        connection,
        OBJECT_PATH,
        g_portal.fc_info,
        &FC_VTABLE,
        null,
        null,
        &err,
    );
    if (g_portal.fc_reg == 0) {
        const msg: [*c]const u8 = if (err != null and err.*.message != null) err.*.message else "unknown";
        _ = c.fprintf(platform.stderr(), "sketerm portal: object registration failed: %s\n", msg);
        if (err != null) c.g_error_free(err);
        c.g_application_quit(@ptrCast(@alignCast(user)));
    }
}

fn onNameLost(_: ?*c.GDBusConnection, _: [*c]const c.gchar, user: ?*anyopaque) callconv(.c) void {
    // Lost to a replacing instance, or no session bus at all. Either
    // way this process is no longer the backend.
    _ = c.fputs("sketerm portal: lost org.freedesktop.impl.portal.desktop.sketerm; exiting\n", platform.stderr());
    c.g_application_quit(@ptrCast(@alignCast(user)));
}

// -- FileChooser method dispatch ---------------------------------

fn spanZ(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn onFcMethodCall(
    _: ?*c.GDBusConnection,
    _: [*c]const c.gchar,
    _: [*c]const c.gchar,
    _: [*c]const c.gchar,
    method_name: [*c]const c.gchar,
    parameters: ?*c.GVariant,
    invocation: ?*c.GDBusMethodInvocation,
    _: c.gpointer,
) callconv(.c) void {
    const method = policy.methodFromName(spanZ(method_name)) orelse {
        c.g_dbus_method_invocation_return_dbus_error(
            invocation,
            "org.freedesktop.DBus.Error.UnknownMethod",
            "unknown FileChooser method",
        );
        return;
    };
    handleChooser(method, parameters, invocation) catch {
        replyEmpty(invocation, policy.RESPONSE_OTHER);
    };
}

fn onFcGetProperty(
    _: ?*c.GDBusConnection,
    _: [*c]const c.gchar,
    _: [*c]const c.gchar,
    _: [*c]const c.gchar,
    property_name: [*c]const c.gchar,
    _: [*c][*c]c.GError,
    _: c.gpointer,
) callconv(.c) ?*c.GVariant {
    if (std.mem.eql(u8, spanZ(property_name), "version"))
        return c.g_variant_new_uint32(IMPL_VERSION);
    return null;
}

fn lookupBool(opts: ?*c.GVariant, key: [*:0]const u8) bool {
    const v = c.g_variant_lookup_value(opts, key, c.G_VARIANT_TYPE("b")) orelse return false;
    defer c.g_variant_unref(v);
    return c.g_variant_get_boolean(v) != 0;
}

/// Reply (u response, a{sv} results) with an empty results dict.
fn replyEmpty(invocation: ?*c.GDBusMethodInvocation, response: u32) void {
    var results: c.GVariantBuilder = undefined;
    c.g_variant_builder_init(&results, c.G_VARIANT_TYPE("a{sv}"));
    c.g_dbus_method_invocation_return_value(
        invocation,
        c.g_variant_new("(u@a{sv})", response, c.g_variant_builder_end(&results)),
    );
}

/// Parse one OpenFile/SaveFile/SaveFiles call, open the picker, and
/// leave the invocation pending until the picker delivers.
fn handleChooser(
    method: policy.Method,
    parameters: ?*c.GVariant,
    invocation: ?*c.GDBusMethodInvocation,
) !void {
    const alloc = g_portal.allocator;

    var handle_c: [*c]const u8 = null;
    var appid_c: [*c]const u8 = null;
    var parent_c: [*c]const u8 = null;
    var title_c: [*c]const u8 = null;
    var opts: ?*c.GVariant = null;
    c.g_variant_get(parameters, "(&o&s&s&s@a{sv})", &handle_c, &appid_c, &parent_c, &title_c, &opts);
    defer if (opts) |o| c.g_variant_unref(o);

    const multiple = lookupBool(opts, "multiple");
    const directory = lookupBool(opts, "directory");
    const accept_v = c.g_variant_lookup_value(opts, "accept_label", c.G_VARIANT_TYPE("s"));
    defer if (accept_v) |v| c.g_variant_unref(v);
    const accept_c: [*c]const u8 = if (accept_v) |v| c.g_variant_get_string(v, null) else null;
    const name_v = c.g_variant_lookup_value(opts, "current_name", c.G_VARIANT_TYPE("s"));
    defer if (name_v) |v| c.g_variant_unref(v);
    const name_c: [*c]const u8 = if (name_v) |v| c.g_variant_get_string(v, null) else null;
    // Bytestrings via lookup_value + get_bytestring: the "^&ay"
    // varargs conversion returned CORRUPT borrows through the
    // translated bindings (live-verified), so never use it here.
    const folder_v = c.g_variant_lookup_value(opts, "current_folder", c.G_VARIANT_TYPE("ay"));
    defer if (folder_v) |v| c.g_variant_unref(v);
    const folder_c: [*c]const u8 = if (folder_v) |v| c.g_variant_get_bytestring(v) else null;
    const file_v = c.g_variant_lookup_value(opts, "current_file", c.G_VARIANT_TYPE("ay"));
    defer if (file_v) |v| c.g_variant_unref(v);
    const file_c: [*c]const u8 = if (file_v) |v| c.g_variant_get_bytestring(v) else null;

    // Everything the picker copies at open() can live in this arena.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var fset = try collectFilters(alloc, a, opts);
    errdefer fset.release(alloc);

    var initial: ?[]const u8 = if (folder_c != null and folder_c.* != 0) spanZ(folder_c) else null;
    var suggested: ?[]const u8 = if (name_c != null and name_c.* != 0) spanZ(name_c) else null;
    if (method == .save_file and file_c != null and file_c.* != 0) {
        // current_file wins over current_folder/current_name: it names
        // the exact file being re-saved.
        const full = spanZ(file_c);
        if (std.fs.path.dirname(full)) |d| initial = try a.dupe(u8, d);
        suggested = std.fs.path.basename(full);
    }

    // SaveFiles: validate the requested leaf names up front; a bad
    // name is the caller's error and refuses the whole call.
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    if (method == .save_files) {
        const files_v = c.g_variant_lookup_value(opts, "files", c.G_VARIANT_TYPE("aay")) orelse
            return error.MissingFiles;
        defer c.g_variant_unref(files_v);
        var it: c.GVariantIter = undefined;
        _ = c.g_variant_iter_init(&it, files_v);
        while (c.g_variant_iter_next_value(&it)) |child| {
            defer c.g_variant_unref(child);
            const nslice = spanZ(c.g_variant_get_bytestring(child));
            if (!fpicker.validSaveName(nslice)) return error.BadFileName;
            const owned = try alloc.dupe(u8, nslice);
            errdefer alloc.free(owned);
            try names.append(alloc, owned);
        }
        if (names.items.len == 0) return error.MissingFiles;
    }

    const accept: ?[]const u8 = if (accept_c != null and accept_c.* != 0)
        try policy.stripMnemonicAlloc(a, spanZ(accept_c))
    else
        null;
    const title: ?[]const u8 = if (title_c != null and title_c.* != 0) spanZ(title_c) else null;

    const choices = try collectChoiceDefaults(alloc, opts);
    errdefer {
        for (choices) |ch| alloc.free(ch);
        alloc.free(choices);
    }

    const call = try alloc.create(ActiveCall);
    errdefer alloc.destroy(call);
    const handle_owned = try alloc.dupeZ(u8, spanZ(handle_c));
    call.* = .{
        .allocator = alloc,
        .invocation = invocation,
        .method = method,
        .handle_path = handle_owned,
        .filters_v = fset.filters_v,
        .current_v = fset.current_v,
        .filter_srcs = fset.srcs,
        .choices = choices,
    };
    // Ownership of the filter refs/indices has moved into `call`;
    // disarm the errdefer above so nothing is released twice.
    fset.filters_v = null;
    fset.current_v = null;
    fset.srcs = &.{};
    call.names = names.toOwnedSlice(alloc) catch blk: {
        break :blk &.{};
    };

    // Export the portal Request object at the caller's handle path so
    // Close() can cancel the open picker. A failed registration only
    // costs cancellation-from-the-app; the chooser still works.
    call.request_reg = c.g_dbus_connection_register_object(
        g_portal.conn,
        call.handle_path.ptr,
        g_portal.req_info,
        &REQ_VTABLE,
        @ptrCast(call),
        null,
        null,
    );

    // A frontend that dies mid-call leaves an orphan dialog on the
    // user's screen otherwise; the watch cancels it.
    const sender = c.g_dbus_method_invocation_get_sender(invocation);
    if (sender != null) {
        call.watch_id = c.g_bus_watch_name_on_connection(
            g_portal.conn,
            sender,
            c.G_BUS_NAME_WATCHER_FLAGS_NONE,
            null,
            @ptrCast(&onCallerVanished),
            @ptrCast(call),
            null,
        );
    }

    const parent_handle: ?[]const u8 = if (parent_c != null and parent_c.* != 0) spanZ(parent_c) else null;
    const req = fpicker.Request{
        .mode = policy.modeFor(method, multiple, directory),
        .initial_spec = initial,
        .filters = fset.filters,
        .active_filter = fset.active,
        .suggested_name = suggested,
        .title = title,
        .accept_label = accept,
        .enforce_filter = true,
        .local_only = true,
        .foreign_parent = parent_handle,
    };
    call.picker = PickerWindow.open(alloc, null, req, &onPickerResult, @ptrCast(call)) catch {
        finish(call, policy.RESPONSE_OTHER, &.{});
        return;
    };
}

fn onCallerVanished(_: ?*c.GDBusConnection, _: [*c]const c.gchar, user: ?*anyopaque) callconv(.c) void {
    const call = cast.userData(ActiveCall, user);
    if (call.done) return;
    call.closed = true;
    if (call.picker) |p| p.cancel();
}

/// The `choices` option (a(ssa(ss)s)) has no widgets in this picker
/// yet; echoing each choice's declared default keeps callers that
/// read the results dict from seeing a missing key. Returns
/// "id\x00value" pairs (owned by `alloc`).
fn collectChoiceDefaults(alloc: std.mem.Allocator, opts: ?*c.GVariant) ![][]u8 {
    const v = c.g_variant_lookup_value(opts, "choices", c.G_VARIANT_TYPE("a(ssa(ss)s)")) orelse
        return &.{};
    defer c.g_variant_unref(v);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |o| alloc.free(o);
        out.deinit(alloc);
    }
    var it: c.GVariantIter = undefined;
    _ = c.g_variant_iter_init(&it, v);
    while (c.g_variant_iter_next_value(&it)) |child| {
        defer c.g_variant_unref(child);
        const id_v = c.g_variant_get_child_value(child, 0);
        defer c.g_variant_unref(id_v);
        const def_v = c.g_variant_get_child_value(child, 3);
        defer c.g_variant_unref(def_v);
        const id = spanZ(c.g_variant_get_string(id_v, null));
        const def = spanZ(c.g_variant_get_string(def_v, null));
        if (id.len == 0 or def.len == 0) continue;
        const pair = try std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ id, def });
        try out.append(alloc, pair);
    }
    return out.toOwnedSlice(alloc);
}

/// Everything the filter options amount to: what the picker shows,
/// which entry starts selected, and how to get back to the caller's
/// own filter variants when the reply echoes `current_filter`.
const FilterSet = struct {
    filters: []const fpicker.Filter = &.{},
    active: usize = 0,
    /// Owned by the LONG-LIVED allocator (moves into the ActiveCall).
    srcs: []usize = &.{},
    filters_v: ?*c.GVariant = null,
    current_v: ?*c.GVariant = null,

    fn release(self: *FilterSet, alloc: std.mem.Allocator) void {
        if (self.srcs.len > 0) alloc.free(self.srcs);
        self.srcs = &.{};
        if (self.filters_v) |v| c.g_variant_unref(v);
        if (self.current_v) |v| c.g_variant_unref(v);
        self.filters_v = null;
        self.current_v = null;
    }
};

/// One a(us) entry list off a (sa(us)) filter variant.
/// Structural child_value/get_string access only: the varargs
/// conversion paths (iter_loop "&s", lookup "^&ay") returned corrupt
/// borrows through the translated bindings.
fn readRawFilter(a: std.mem.Allocator, fv: *c.GVariant) !policy.RawFilter {
    const label_v = c.g_variant_get_child_value(fv, 0);
    defer c.g_variant_unref(label_v);
    const entries_v = c.g_variant_get_child_value(fv, 1);
    defer c.g_variant_unref(entries_v);

    var entries: std.ArrayList(policy.RawEntry) = .empty;
    var it: c.GVariantIter = undefined;
    _ = c.g_variant_iter_init(&it, entries_v);
    while (c.g_variant_iter_next_value(&it)) |ev| {
        defer c.g_variant_unref(ev);
        const kind_v = c.g_variant_get_child_value(ev, 0);
        defer c.g_variant_unref(kind_v);
        const pat_v = c.g_variant_get_child_value(ev, 1);
        defer c.g_variant_unref(pat_v);
        try entries.append(a, .{
            .kind = c.g_variant_get_uint32(kind_v),
            .pattern = try a.dupe(u8, spanZ(c.g_variant_get_string(pat_v, null))),
        });
    }
    return .{
        .label = try a.dupe(u8, spanZ(c.g_variant_get_string(label_v, null))),
        .entries = try entries.toOwnedSlice(a),
    };
}

/// Decode `filters` (a(sa(us))) and `current_filter` ((sa(us))) into
/// picker filters via the pure mapper. `a` is the call arena (picker
/// copies everything at open); `alloc` owns what outlives the call.
fn collectFilters(alloc: std.mem.Allocator, a: std.mem.Allocator, opts: ?*c.GVariant) !FilterSet {
    var set = FilterSet{};
    errdefer set.release(alloc);
    set.filters_v = c.g_variant_lookup_value(opts, "filters", c.G_VARIANT_TYPE("a(sa(us))"));
    set.current_v = c.g_variant_lookup_value(opts, "current_filter", c.G_VARIANT_TYPE("(sa(us))"));

    var raw: std.ArrayList(policy.RawFilter) = .empty;
    if (set.filters_v) |fv| {
        var outer: c.GVariantIter = undefined;
        _ = c.g_variant_iter_init(&outer, fv);
        while (c.g_variant_iter_next_value(&outer)) |child| {
            defer c.g_variant_unref(child);
            try raw.append(a, try readRawFilter(a, child));
        }
    }
    const listed = raw.items.len;

    // current_filter need not be a member of `filters` (GTK's own
    // backend tolerates that too); an outsider is appended so the
    // user can still see and leave the selection.
    var current_src: ?usize = null;
    if (set.current_v) |cv| {
        const cur = try readRawFilter(a, cv);
        if (policy.findRawFilter(raw.items, cur)) |i| {
            current_src = i;
        } else if (cur.entries.len > 0) {
            try raw.append(a, cur);
            current_src = raw.items.len - 1;
        }
    }

    const mapped = try policy.mapFilters(a, raw.items);
    set.filters = try policy.pickerFilters(a, mapped);
    set.active = if (current_src) |src|
        (policy.mappedIndexOfSrc(mapped, src) orelse mapped.len)
    else
        0;

    const srcs = try alloc.alloc(usize, mapped.len);
    for (mapped, 0..) |m, i| srcs[i] = if (m.src >= listed) SRC_CURRENT else m.src;
    set.srcs = srcs;
    return set;
}

// -- Request object (Close) --------------------------------------

fn onReqMethodCall(
    _: ?*c.GDBusConnection,
    _: [*c]const c.gchar,
    _: [*c]const c.gchar,
    _: [*c]const c.gchar,
    method_name: [*c]const c.gchar,
    _: ?*c.GVariant,
    invocation: ?*c.GDBusMethodInvocation,
    user: c.gpointer,
) callconv(.c) void {
    if (!std.mem.eql(u8, spanZ(method_name), "Close")) {
        c.g_dbus_method_invocation_return_dbus_error(
            invocation,
            "org.freedesktop.DBus.Error.UnknownMethod",
            "unknown Request method",
        );
        return;
    }
    const call = cast.userData(ActiveCall, user);
    call.closed = true;
    // Cancelling drives the picker's null delivery, which lands in
    // onPickerResult below and answers response 2.
    if (call.picker) |p| p.cancel();
    c.g_dbus_method_invocation_return_value(invocation, null);
}

// -- picker delivery ---------------------------------------------

fn onPickerResult(ctx: ?*anyopaque, result: ?fpicker.Result) void {
    const call = cast.userData(ActiveCall, ctx);
    call.picker = null;
    if (call.done) return;
    if (result == null) {
        finish(call, if (call.closed) policy.RESPONSE_OTHER else policy.RESPONSE_CANCELLED, &.{});
        return;
    }
    call.chosen_filter = result.?.filter_index;

    var arena = std.heap.ArenaAllocator.init(call.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var uris: std.ArrayList([:0]const u8) = .empty;

    switch (call.method) {
        .open_file, .save_file => {
            // Remote picks are dropped: a portal consumer cannot open
            // host-qualified specs. All-remote = response 2.
            for (result.?.specs) |spec| {
                const local = policy.localPath(spec) orelse continue;
                const uri = policy.fileUriAlloc(a, local) catch continue;
                uris.append(a, a.dupeZ(u8, uri) catch continue) catch continue;
            }
        },
        .save_files => {
            const dir = if (result.?.specs.len == 1) policy.localPath(result.?.specs[0]) else null;
            if (dir) |d| {
                for (call.names) |nm| {
                    const uri = policy.joinedUriAlloc(a, d, nm) catch continue;
                    uris.append(a, a.dupeZ(u8, uri) catch continue) catch continue;
                }
            }
        },
    }

    if (uris.items.len == 0) {
        finish(call, policy.RESPONSE_OTHER, &.{});
        return;
    }
    finish(call, policy.RESPONSE_OK, uris.items);
}

/// Send the pending reply exactly once and tear the call down.
fn finish(call: *ActiveCall, response: u32, uris: []const [:0]const u8) void {
    if (call.done) return;
    call.done = true;

    var results: c.GVariantBuilder = undefined;
    c.g_variant_builder_init(&results, c.G_VARIANT_TYPE("a{sv}"));
    if (uris.len > 0) {
        var ub: c.GVariantBuilder = undefined;
        c.g_variant_builder_init(&ub, c.G_VARIANT_TYPE("as"));
        for (uris) |u| c.g_variant_builder_add(&ub, "s", u.ptr);
        c.g_variant_builder_add(&results, "{sv}", "uris", c.g_variant_builder_end(&ub));
    }
    if (response == policy.RESPONSE_OK) {
        if (currentFilterVariant(call)) |cf| {
            // Our own ref: the "v" format sinks/refs it, so drop ours.
            c.g_variant_builder_add(&results, "{sv}", "current_filter", cf);
            c.g_variant_unref(cf);
        }
        if (call.choices.len > 0) {
            var cb: c.GVariantBuilder = undefined;
            c.g_variant_builder_init(&cb, c.G_VARIANT_TYPE("a(ss)"));
            for (call.choices) |pair| {
                const sep = std.mem.indexOfScalar(u8, pair, 0) orelse continue;
                // Both halves are NUL-terminated in place: the
                // separator ends the id, the allocation's own
                // terminator is not guaranteed, so copy out.
                var idz: [128:0]u8 = undefined;
                var valz: [128:0]u8 = undefined;
                const id = std.fmt.bufPrintZ(&idz, "{s}", .{pair[0..sep]}) catch continue;
                const val = std.fmt.bufPrintZ(&valz, "{s}", .{pair[sep + 1 ..]}) catch continue;
                c.g_variant_builder_add(&cb, "(ss)", id.ptr, val.ptr);
            }
            c.g_variant_builder_add(&results, "{sv}", "choices", c.g_variant_builder_end(&cb));
        }
    }
    c.g_dbus_method_invocation_return_value(
        call.invocation,
        c.g_variant_new("(u@a{sv})", response, c.g_variant_builder_end(&results)),
    );

    if (call.request_reg != 0) {
        _ = c.g_dbus_connection_unregister_object(g_portal.conn, call.request_reg);
        call.request_reg = 0;
    }
    if (call.watch_id != 0) {
        c.g_bus_unwatch_name(call.watch_id);
        call.watch_id = 0;
    }
    const alloc = call.allocator;
    for (call.names) |n| alloc.free(n);
    if (call.names.len > 0) alloc.free(call.names);
    for (call.choices) |ch| alloc.free(ch);
    if (call.choices.len > 0) alloc.free(call.choices);
    if (call.filter_srcs.len > 0) alloc.free(call.filter_srcs);
    if (call.filters_v) |v| c.g_variant_unref(v);
    if (call.current_v) |v| c.g_variant_unref(v);
    alloc.free(call.handle_path);
    alloc.destroy(call);
}

/// The caller's own (sa(us)) variant for the filter the user accepted
/// under -- a floating reference the results builder consumes.
fn currentFilterVariant(call: *ActiveCall) ?*c.GVariant {
    const idx = call.chosen_filter orelse return null;
    if (idx >= call.filter_srcs.len) return null;
    const src = call.filter_srcs[idx];
    if (src == SRC_CURRENT) {
        const cv = call.current_v orelse return null;
        return c.g_variant_ref(cv);
    }
    const fv = call.filters_v orelse return null;
    if (src >= c.g_variant_n_children(fv)) return null;
    return c.g_variant_get_child_value(fv, src);
}
