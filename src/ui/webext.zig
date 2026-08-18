//! GUI side of the WebExtensions host: a process-wide registry of
//! installed extensions, their on-disk install/removal, publishing them
//! to the browser helper on connect, and the management surface reached
//! from a web pane's context menu.
//!
//! The helper does the actual loading, background hosting and content
//! scripts; this module owns what the USER sees — which extensions are
//! installed, whether each is enabled, and the Load/Remove actions.
//! Installed extensions live under `$XDG_DATA_HOME/sketerm/webext/`, the
//! same tree the helper reads; a small `registry.json` there records the
//! id/dir/enabled of each so the set survives a GUI restart.
//!
//! Reuses the pure `web/webext/{manifest,zip}` modules for parsing and
//! XPI unpacking, and the shared GTK helpers for chrome.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const confirm = @import("confirm.zig");
const webface = @import("webface.zig");
const proto = @import("../web/protocol.zig");
const manifest = @import("../web/webext/manifest.zig");
const zip = @import("../web/webext/zip.zig");
const extinstall = @import("../web/webext/install.zig");
const extregistry = @import("../web/webext/registry.zig");
const pathz = @import("../util/pathz.zig");
const atomicwrite = @import("../util/atomicwrite.zig");

/// One installed extension as the GUI tracks it.
pub const Ext = struct {
    id: []u8 = &.{},
    /// Absolute unpacked directory the helper loads.
    dir: []u8 = &.{},
    name: []u8 = &.{},
    version: []u8 = &.{},
    enabled: bool,
    /// The helper's last report (`ev_webext_state`): whether it loaded.
    ok: bool = false,
    err: []u8 = &.{},
    /// True when the files live under our data dir (an XPI we unpacked),
    /// so Remove may delete them; a "load unpacked" points in place and
    /// is only unregistered.
    owned_files: bool = false,
};

var g_gpa: ?std.mem.Allocator = null;
var g_exts: std.ArrayList(Ext) = .empty;
var g_loaded = false;

pub fn extensions() []Ext {
    return g_exts.items;
}

/// Resolve one declared extension asset for GTK. The returned path is
/// owned; traversal is refused and a disabled/uninstalled id has none.
pub fn assetPath(gpa: std.mem.Allocator, id: []const u8, rel: []const u8) ?[]u8 {
    const e = find(id) orelse return null;
    if (!e.enabled or !e.ok or rel.len == 0) return null;
    if (std.mem.indexOf(u8, rel, "..") != null or std.mem.indexOfScalar(u8, rel, 0) != null) return null;
    const clean = std.mem.trimStart(u8, rel, "/");
    if (clean.len == 0) return null;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ e.dir, clean }) catch null;
}

fn dupeOwned(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    return if (s.len == 0) &.{} else try gpa.dupe(u8, s);
}

fn freeOwned(gpa: std.mem.Allocator, value: []u8) void {
    if (value.len != 0) gpa.free(value);
}

fn freeExtWith(gpa: std.mem.Allocator, e: *Ext) void {
    freeOwned(gpa, e.id);
    freeOwned(gpa, e.dir);
    freeOwned(gpa, e.name);
    freeOwned(gpa, e.version);
    freeOwned(gpa, e.err);
    e.* = undefined;
}

fn freeExt(e: *Ext) void {
    freeExtWith(g_gpa orelse return, e);
}

fn initExt(
    gpa: std.mem.Allocator,
    id: []const u8,
    dir: []const u8,
    name: []const u8,
    version: []const u8,
    enabled: bool,
    owned_files: bool,
) !Ext {
    var e = Ext{ .enabled = enabled, .owned_files = owned_files };
    errdefer freeExtWith(gpa, &e);
    e.id = try dupeOwned(gpa, id);
    e.dir = try dupeOwned(gpa, dir);
    e.name = try dupeOwned(gpa, name);
    e.version = try dupeOwned(gpa, version);
    return e;
}

fn find(id: []const u8) ?*Ext {
    for (g_exts.items) |*e| {
        if (std.mem.eql(u8, e.id, id)) return e;
    }
    return null;
}

/// Data dir (`$XDG_DATA_HOME/sketerm/webext`), owned by the caller.
fn dataDir(gpa: std.mem.Allocator) InstallError![]u8 {
    if (c.getenv("XDG_DATA_HOME")) |xdg| {
        const base = std.mem.span(xdg);
        if (base.len != 0) return std.fmt.allocPrint(gpa, "{s}/sketerm/webext", .{base}) catch error.OutOfMemory;
    }
    if (c.getenv("HOME")) |home| {
        return std.fmt.allocPrint(gpa, "{s}/.local/share/sketerm/webext", .{std.mem.span(home)}) catch error.OutOfMemory;
    }
    return error.WriteFailed;
}

// -- registry persistence --------------------------------------------

/// Load the persisted registry once. Safe to call repeatedly.
pub fn ensureLoaded(gpa: std.mem.Allocator) void {
    if (g_loaded) return;
    if (g_gpa == null) g_gpa = gpa;
    const owner = g_gpa.?;
    const loaded = loadRegistry(owner) catch return;
    for (g_exts.items) |*e| freeExtWith(owner, e);
    g_exts.deinit(owner);
    g_exts = loaded;
    g_loaded = true;
}

fn loadRegistry(gpa: std.mem.Allocator) InstallError!std.ArrayList(Ext) {
    var loaded: std.ArrayList(Ext) = .empty;
    errdefer {
        for (loaded.items) |*e| freeExtWith(gpa, e);
        loaded.deinit(gpa);
    }
    const dir = try dataDir(gpa);
    defer gpa.free(dir);
    var persisted = extregistry.read(gpa, dir) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => loaded,
    };
    defer persisted.deinit();
    for (persisted.items.items) |rec| {
        // Fill name/version from the manifest if it still parses.
        var name: []const u8 = "";
        var version: []const u8 = "";
        var man = readManifest(gpa, rec.dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        defer if (man) |*m| m.deinit();
        if (man) |*m| {
            name = m.name;
            version = m.version;
        }
        var fresh = initExt(gpa, rec.id, rec.dir, name, version, rec.enabled, rec.owned) catch return error.OutOfMemory;
        loaded.append(gpa, fresh) catch {
            freeExtWith(gpa, &fresh);
            return error.OutOfMemory;
        };
    }
    return loaded;
}

/// Persist ONE change to `registry.json`.
///
/// The change is keyed by id and applied to what is on DISK, inside the
/// registry's cross-process lock: `g_exts` is this process's view and
/// may predate another sketerm's install, so rewriting the file from it
/// is exactly how the other install's entry used to vanish.
fn saveChange(change: extregistry.Change) InstallError!void {
    const gpa = g_gpa orelse return error.WriteFailed;
    const dir = try dataDir(gpa);
    defer gpa.free(dir);
    extregistry.commit(gpa, dir, change) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.WriteFailed,
    };
}

fn saveEntry(e: *const Ext) InstallError!void {
    return saveChange(.{ .upsert = .{
        .id = e.id,
        .dir = e.dir,
        .enabled = e.enabled,
        .owned = e.owned_files,
    } });
}

fn saveRemoval(id: []const u8) InstallError!void {
    return saveChange(.{ .remove = id });
}

// -- publish / helper state ------------------------------------------

/// Push every installed extension to a (possibly fresh) helper on
/// connect, then ask it to report state back.
pub fn publish(cl: *webface.Client) void {
    if (cl.state != .ready or cl.isRemote() or !cl.cap_webext) return;
    for (g_exts.items) |*e| {
        cl.post(proto.WebextSet{ .id = e.id, .dir = e.dir, .enabled = if (e.enabled) 1 else 0 });
    }
    cl.post(proto.WebextListReq{});
}

/// Fold one `ev_webext_state` into the registry (name/version/ok/err).
pub fn onState(st: proto.EvWebextState) void {
    const gpa = g_gpa orelse return;
    if (!manifest.idValid(st.id)) return;
    // A correlated install owns this id until commit or rollback. The
    // helper also emits the legacy state frame while loading the candidate;
    // folding that into the old registry would make a later refusal partial.
    if (pendingById(st.id) != null) return;
    const e = find(st.id) orelse return;
    const new_name = if (st.name.len != 0) dupeOwned(gpa, st.name) catch return else null;
    var committed = false;
    defer if (!committed) if (new_name) |value| freeOwned(gpa, value);
    const new_version = if (st.version.len != 0) dupeOwned(gpa, st.version) catch return else null;
    defer if (!committed) if (new_version) |value| freeOwned(gpa, value);
    const new_err = dupeOwned(gpa, st.err) catch return;
    defer if (!committed) freeOwned(gpa, new_err);

    if (new_name) |value| {
        freeOwned(gpa, e.name);
        e.name = value;
    }
    if (new_version) |value| {
        freeOwned(gpa, e.version);
        e.version = value;
    }
    e.ok = st.ok != 0;
    freeOwned(gpa, e.err);
    e.err = new_err;
    committed = true;
    refreshOpenManager();
}

// -- install / remove / toggle ---------------------------------------

pub const InstallError = error{
    BadManifest,
    NoManifest,
    WriteFailed,
    BadArchive,
    /// Zip64 records: a valid archive we do not read, distinct from a
    /// corrupt one so the user is not sent to re-download a good file.
    UnsupportedZip64,
    /// A manifest-referenced asset exists but exceeds the size ceiling.
    AssetTooLarge,
    InstallBusy,
    HelperRefused,
    /// An MV3 package. Its own error because it is the ONE failure a
    /// user hits by accident (every Chrome Web Store download is MV3)
    /// and the only one where the fix is "get the Firefox build".
    UnsupportedManifestVersion,
    OutOfMemory,
};

/// A human sentence for the install failure, for the error dialog.
pub fn installErrorText(e: InstallError) [*:0]const u8 {
    return switch (e) {
        error.NoManifest => "No manifest.json was found in that folder or package.",
        error.BadManifest => "The manifest.json could not be parsed.",
        error.UnsupportedManifestVersion => "This is a Manifest V3 extension. sketerm hosts the Firefox MV2 surface, " ++
            "where blocking webRequest still exists; install the Firefox build instead.",
        error.BadArchive => "That file is not a readable .xpi/.zip archive.",
        error.UnsupportedZip64 => "That archive uses Zip64 records, which sketerm cannot read yet.",
        error.AssetTooLarge => "A file the manifest references is larger than sketerm allows for one extension asset.",
        error.InstallBusy => "This extension is already being installed by another sketerm process.",
        error.HelperRefused => "The browser helper refused the staged extension; the previous version was restored.",
        error.WriteFailed => "The extension could not be written to the data directory.",
        error.OutOfMemory => "Out of memory.",
    };
}

/// Install a "load unpacked" directory: the helper loads it in place, so
/// nothing is copied. Returns the id.
pub fn installUnpacked(gpa: std.mem.Allocator, dir: []const u8) InstallError![]const u8 {
    ensureLoaded(gpa);
    var man = try readManifest(gpa, dir);
    defer man.deinit();
    return register(gpa, dir, &man, false);
}

/// Where an archive install is decided: staged through the helper, or
/// unpacked and registered locally the way it always was.
const ArchiveRoute = enum { helper_transaction, local };

/// A REMOTE helper is `.ready` with every `webext` capability zeroed --
/// extensions are local-browser only, and no package ever crosses the
/// mux wire -- so readiness alone does not mean there is a helper that
/// will answer a staged transaction. Asking one anyway refused the
/// install with "the previous version was restored" while nothing had
/// been sent anywhere and nothing restored, and left the two install
/// buttons disagreeing (`installUnpacked` kept working).
fn archiveRoute(ready: bool, cap_webext: bool, cap_transaction: bool) ArchiveRoute {
    if (ready and cap_webext and cap_transaction) return .helper_transaction;
    return .local;
}

/// Install an `.xpi`/`.zip` through a staged helper-coordinated transaction.
pub fn installArchive(gpa: std.mem.Allocator, xpi_path: []const u8) InstallError!void {
    ensureLoaded(gpa);
    const bytes = readFile(gpa, xpi_path) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => error.NoManifest,
    };
    defer gpa.free(bytes);
    var arc = zip.read(gpa, bytes) catch |err| return switch (err) {
        error.UnsupportedZip64 => error.UnsupportedZip64,
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadArchive,
    };
    defer arc.deinit();
    const man_entry = arc.find("manifest.json") orelse return error.NoManifest;
    var man = manifest.parse(gpa, man_entry.data) catch |err| return mapParseError(err);
    defer man.deinit();

    const base = try dataDir(gpa);
    defer gpa.free(base);
    var tx = extinstall.begin(gpa, base, &arc, &man) catch |err| return mapInstallError(err);
    var tx_owned = true;
    defer if (tx_owned) tx.deinit();

    const cl = webface.client();
    if (archiveRoute(cl.state == .ready, cl.cap_webext, cl.cap_webext_transaction) == .helper_transaction) {
        const pending = gpa.create(PendingInstall) catch return error.OutOfMemory;
        var pending_owned = true;
        errdefer if (pending_owned) gpa.destroy(pending);
        pending.* = .{
            .gpa = gpa,
            .req = next_install_req,
            .tx = tx,
        };
        next_install_req +%= 1;
        if (next_install_req == 0) next_install_req = 1;
        g_pending.append(gpa, pending) catch return error.OutOfMemory;
        tx_owned = false;
        pending_owned = false;
        pending.timer = c.g_timeout_add(INSTALL_TIMEOUT_MS, @ptrCast(&onInstallTimeout), pending);
        const req = pending.req;
        if (!cl.postChecked(proto.WebextInstallPrepare{
            .req = req,
            .id = pending.tx.id,
            .dir = pending.tx.stage,
            .version = pending.tx.version,
        })) {
            if (pendingByReq(req)) |live| discardPending(live, false);
            return error.HelperRefused;
        }
        return;
    }

    tx.commit() catch |err| return mapInstallError(err);
    _ = try updateRegistry(gpa, tx.dest, tx.id, tx.name, tx.version, true);
    tx.finish() catch |err| std.debug.print("webext: obsolete extension cleanup failed: {s}\n", .{@errorName(err)});
    refreshOpenManager();
}

fn mapInstallError(err: extinstall.Error) InstallError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedManifestVersion => error.UnsupportedManifestVersion,
        error.BadManifest, error.IdentityMismatch, error.VersionMismatch, error.MissingAsset, error.UnsafeAsset => error.BadManifest,
        error.AssetTooLarge => error.AssetTooLarge,
        error.ConcurrentInstall => error.InstallBusy,
        else => error.WriteFailed,
    };
}

const INSTALL_TIMEOUT_MS = 15_000;

const PendingInstall = struct {
    gpa: std.mem.Allocator,
    req: u32,
    tx: extinstall.Transaction,
    timer: c.guint = 0,
    enabled: bool = true,
    phase: enum { waiting_prepare, waiting_commit } = .waiting_prepare,
};

var g_pending: std.ArrayList(*PendingInstall) = .empty;
var next_install_req: u32 = 1;

fn pendingByReq(req: u32) ?*PendingInstall {
    for (g_pending.items) |pending| {
        if (pending.req == req) return pending;
    }
    return null;
}

fn pendingById(id: []const u8) ?*PendingInstall {
    for (g_pending.items) |pending| {
        if (std.mem.eql(u8, pending.tx.id, id)) return pending;
    }
    return null;
}

fn destroyPending(pending: *PendingInstall) void {
    if (pending.timer != 0) {
        _ = c.g_source_remove(pending.timer);
        pending.timer = 0;
    }
    for (g_pending.items, 0..) |item, i| {
        if (item == pending) {
            _ = g_pending.orderedRemove(i);
            break;
        }
    }
    pending.tx.deinit();
    pending.gpa.destroy(pending);
}

fn restoreHelper(pending: *PendingInstall) void {
    const cl = webface.client();
    if (cl.state != .ready or !cl.cap_webext) return;
    if (find(pending.tx.id)) |old| {
        _ = cl.postChecked(proto.WebextSet{
            .id = old.id,
            .dir = old.dir,
            .enabled = @intFromBool(old.enabled),
        });
    } else {
        _ = cl.postChecked(proto.WebextRemove{ .id = pending.tx.id });
    }
}

fn discardPending(pending: *PendingInstall, restore_helper: bool) void {
    pending.tx.rollback() catch |rollback_err| {
        std.debug.print("webext: install rollback failed: {s}\n", .{@errorName(rollback_err)});
    };
    if (restore_helper) restoreHelper(pending);
    destroyPending(pending);
}

fn failPending(pending: *PendingInstall, err: InstallError, restore_helper: bool) void {
    discardPending(pending, restore_helper);
    reportInstallError(err);
}

fn onInstallTimeout(user: ?*anyopaque) callconv(.c) c.gboolean {
    const pending = cast.userData(PendingInstall, user);
    pending.timer = 0;
    failPending(pending, error.HelperRefused, true);
    return 0;
}

/// Continue an install only after the helper validated and quiesced the old instance.
pub fn onInstallPrepared(ev: proto.EvWebextInstallPrepared) void {
    const pending = pendingByReq(ev.req) orelse return;
    if (!std.mem.eql(u8, pending.tx.id, ev.id) or pending.phase != .waiting_prepare) return;
    if (ev.ok == 0) {
        std.debug.print("webext: staged extension refused: {s}\n", .{ev.err});
        failPending(pending, error.HelperRefused, false);
        return;
    }
    pending.phase = .waiting_commit;
    pending.enabled = if (find(pending.tx.id)) |old| old.enabled else true;
    pending.tx.commit() catch |err| {
        std.debug.print("webext: atomic extension swap failed: {s}\n", .{@errorName(err)});
        failPending(pending, mapInstallError(err), true);
        return;
    };
    const req = pending.req;
    const cl = webface.client();
    if (!cl.postChecked(proto.WebextInstallCommit{
        .req = req,
        .id = pending.tx.id,
        .dir = pending.tx.dest,
        .version = pending.tx.version,
        .enabled = @intFromBool(pending.enabled),
    })) {
        if (pendingByReq(req)) |live| failPending(live, error.HelperRefused, false);
    }
}

/// Accept or roll back the swapped tree from the helper's correlated load result.
pub fn onInstallCommitted(ev: proto.EvWebextInstallCommitted) void {
    const pending = pendingByReq(ev.req) orelse return;
    if (!std.mem.eql(u8, pending.tx.id, ev.id) or pending.phase != .waiting_commit) return;
    if (ev.ok == 0) {
        std.debug.print("webext: committed extension refused: {s}\n", .{ev.err});
        failPending(pending, error.HelperRefused, true);
        return;
    }
    _ = updateRegistry(
        pending.gpa,
        pending.tx.dest,
        pending.tx.id,
        pending.tx.name,
        pending.tx.version,
        true,
    ) catch |err| {
        failPending(pending, err, true);
        return;
    };
    if (find(pending.tx.id)) |installed| {
        installed.enabled = pending.enabled;
        installed.ok = true;
        freeOwned(pending.gpa, installed.err);
        installed.err = &.{};
    }
    pending.tx.finish() catch |err| {
        std.debug.print("webext: obsolete extension cleanup failed: {s}\n", .{@errorName(err)});
    };
    refreshOpenManager();
    destroyPending(pending);
}

/// A helper disconnect makes every in-flight prepare/commit untrustworthy.
pub fn onHelperUnavailable() void {
    while (g_pending.items.len != 0) failPending(g_pending.items[0], error.HelperRefused, false);
}

fn mapParseError(err: manifest.ParseError) InstallError {
    return switch (err) {
        error.UnsupportedManifestVersion => error.UnsupportedManifestVersion,
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
}

/// Register (or REPLACE) one extension in the registry.
///
/// Replacement in place is the whole point: the id no longer moves with
/// the version, so installing v2 of an installed extension updates the
/// one row instead of minting a second id — which used to leave both
/// versions enabled and injecting, with v2 on a fresh empty
/// `storage.local` and v1's files never deleted.
fn register(gpa: std.mem.Allocator, dir: []const u8, man: *manifest.Manifest, owned: bool) InstallError![]const u8 {
    var idbuf: [manifest.MAX_ID_LEN]u8 = undefined;
    const id = manifest.extensionId(man, &idbuf);
    const result = try updateRegistry(gpa, dir, id, man.name, man.version, owned);
    const e = find(id) orelse return error.WriteFailed;
    webface.client().post(proto.WebextSet{ .id = e.id, .dir = e.dir, .enabled = 0 });
    webface.client().post(proto.WebextSet{ .id = e.id, .dir = e.dir, .enabled = if (e.enabled) 1 else 0 });
    refreshOpenManager();
    return result;
}

/// Apply one already-accepted install to memory and durable registry as one unit.
fn updateRegistry(
    gpa: std.mem.Allocator,
    dir: []const u8,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    owned: bool,
) InstallError![]const u8 {
    if (find(id)) |e| {
        const new_dir = dupeOwned(gpa, dir) catch return error.OutOfMemory;
        const new_name = dupeOwned(gpa, name) catch {
            freeOwned(gpa, new_dir);
            return error.OutOfMemory;
        };
        const new_version = dupeOwned(gpa, version) catch {
            freeOwned(gpa, new_dir);
            freeOwned(gpa, new_name);
            return error.OutOfMemory;
        };
        const old_dir = e.dir;
        const old_name = e.name;
        const old_version = e.version;
        const old_owned = e.owned_files;
        var candidate = e.*;
        candidate.dir = new_dir;
        candidate.name = new_name;
        candidate.version = new_version;
        candidate.owned_files = owned;
        saveEntry(&candidate) catch |err| {
            freeOwned(gpa, new_dir);
            freeOwned(gpa, new_name);
            freeOwned(gpa, new_version);
            return err;
        };
        e.dir = new_dir;
        e.name = new_name;
        e.version = new_version;
        e.owned_files = owned;
        freeOwned(gpa, old_name);
        freeOwned(gpa, old_version);
        if (old_owned and !std.mem.eql(u8, old_dir, dir)) removeTree(gpa, old_dir);
        freeOwned(gpa, old_dir);
    } else {
        var fresh = initExt(gpa, id, dir, name, version, true, owned) catch return error.OutOfMemory;
        g_exts.ensureUnusedCapacity(gpa, 1) catch {
            freeExtWith(gpa, &fresh);
            return error.OutOfMemory;
        };
        saveEntry(&fresh) catch |err| {
            freeExtWith(gpa, &fresh);
            return err;
        };
        g_exts.appendAssumeCapacity(fresh);
    }
    const e = find(id) orelse return error.WriteFailed;
    return e.id;
}

pub fn setEnabled(id: []const u8, on: bool) void {
    if (!manifest.idValid(id)) return;
    const e = find(id) orelse return;
    if (pendingById(id) != null) return;
    var candidate = e.*;
    candidate.enabled = on;
    saveEntry(&candidate) catch return;
    e.enabled = on;
    webface.client().post(proto.WebextSet{ .id = e.id, .dir = e.dir, .enabled = if (on) 1 else 0 });
    refreshOpenManager();
}

pub fn remove(id: []const u8) void {
    if (!manifest.idValid(id)) return;
    if (pendingById(id) != null) return;
    const gpa = g_gpa orelse return;
    for (g_exts.items, 0..) |*e, i| {
        if (!std.mem.eql(u8, e.id, id)) continue;
        saveRemoval(e.id) catch return;
        webface.client().post(proto.WebextRemove{ .id = e.id });
        // Files under our data dir may be deleted; an in-place unpacked
        // dir is left alone.
        if (e.owned_files) removeTree(gpa, e.dir);
        freeExt(e);
        _ = g_exts.orderedRemove(i);
        refreshOpenManager();
        return;
    }
}

// -- management window -----------------------------------------------

const Manager = struct {
    gpa: std.mem.Allocator,
    window: *c.GtkWidget,
    group: *c.AdwPreferencesGroup,
    parent: ?*c.GtkWindow,
};

var g_manager: ?*Manager = null;

/// Open (or focus) the extensions manager, parented to `parent_window`.
pub fn openManager(gpa: std.mem.Allocator, parent_window: *c.GtkWindow) void {
    ensureLoaded(gpa);
    if (g_manager) |m| {
        c.gtk_window_present(@ptrCast(m.window));
        return;
    }
    const win = c.adw_preferences_window_new();
    c.gtk_window_set_title(@ptrCast(win), "Browser Extensions");
    c.gtk_window_set_transient_for(@ptrCast(win), parent_window);
    c.gtk_window_set_default_size(@ptrCast(win), 560, 520);

    const page = c.adw_preferences_page_new();

    const add_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(add_group)), "Add");
    addActionRow(add_group, "Load Unpacked…", "Pick an unpacked extension directory (contains manifest.json)", &onLoadUnpacked);
    addActionRow(add_group, "Load Extension File…", "Pick an .xpi or .zip package", &onLoadArchive);
    c.adw_preferences_page_add(@ptrCast(@alignCast(page)), @ptrCast(@alignCast(add_group)));

    const list_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(list_group)), "Installed");
    c.adw_preferences_page_add(@ptrCast(@alignCast(page)), @ptrCast(@alignCast(list_group)));

    c.adw_preferences_window_add(@ptrCast(win), @ptrCast(@alignCast(page)));

    const m = gpa.create(Manager) catch return;
    m.* = .{ .gpa = gpa, .window = @ptrCast(win), .group = @ptrCast(@alignCast(list_group)), .parent = parent_window };
    g_manager = m;
    _ = c.g_signal_connect_data(win, "destroy", @ptrCast(&onManagerDestroy), @ptrCast(m), null, c.G_CONNECT_DEFAULT);

    rebuildList(m);
    c.gtk_window_present(@ptrCast(win));
}

fn onManagerDestroy(_: ?*c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const m = cast.userData(Manager, user);
    if (g_manager == m) g_manager = null;
    m.gpa.destroy(m);
}

fn refreshOpenManager() void {
    if (g_manager) |m| rebuildList(m);
}

const ManagerLabels = struct {
    title: [:0]const u8,
    subtitle: [:0]const u8,
};

fn managerLabels(e: *const Ext, title_buf: *[160:0]u8, subtitle_buf: *[256:0]u8) ManagerLabels {
    const title = std.fmt.bufPrintZ(title_buf, "{s}", .{if (e.name.len != 0) e.name else e.id}) catch "extension";
    const subtitle = if (!e.ok and e.err.len != 0)
        std.fmt.bufPrintZ(subtitle_buf, "v{s} — error: {s}", .{ e.version, e.err }) catch ""
    else
        std.fmt.bufPrintZ(subtitle_buf, "v{s}", .{e.version}) catch "";
    return .{ .title = title, .subtitle = subtitle };
}

/// Rebuild the installed-list group from the registry. A row per
/// extension: name/version + a switch and a Remove button.
fn rebuildList(m: *Manager) void {
    // Clear existing rows.
    while (c.gtk_widget_get_first_child(@ptrCast(@alignCast(m.group)))) |_| {
        // AdwPreferencesGroup wraps its rows; remove via its list box is
        // awkward, so rebuild by removing rows we added (tracked below).
        break;
    }
    // Simpler: remove every child row we track on the group via a
    // GtkListBox lookup is fragile across Adw versions; instead we drop
    // and recreate the whole group's rows by clearing tracked rows.
    clearGroupRows(m.group);

    if (g_exts.items.len == 0) {
        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "No extensions installed");
        c.adw_preferences_group_add(m.group, @ptrCast(@alignCast(row)));
        return;
    }

    for (g_exts.items) |*e| {
        const row = c.adw_action_row_new();
        var tbuf: [160:0]u8 = undefined;
        var sbuf: [256:0]u8 = undefined;
        const labels = managerLabels(e, &tbuf, &sbuf);
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), labels.title.ptr);
        if (labels.subtitle.len != 0) c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), labels.subtitle.ptr);

        // Enabled switch. A context that cannot be built (invalid
        // registry id, OOM) leaves the row without controls rather than
        // wiring a callback to nothing.
        if (rowCtx(m, e.id)) |rc| {
            const sw = c.gtk_switch_new();
            c.gtk_switch_set_active(@ptrCast(sw), if (e.enabled) 1 else 0);
            c.gtk_widget_set_valign(sw, c.GTK_ALIGN_CENTER);
            _ = c.g_signal_connect_data(sw, "state-set", @ptrCast(&onToggle), @ptrCast(rc), @ptrCast(&freeRowCtx), c.G_CONNECT_DEFAULT);
            c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), sw);
        }

        // Remove button.
        if (rowCtx(m, e.id)) |rc2| {
            const btn = c.gtk_button_new_from_icon_name("user-trash-symbolic");
            c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
            c.gtk_widget_add_css_class(btn, "flat");
            _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onRemoveClicked), @ptrCast(rc2), @ptrCast(&freeRowCtx), c.G_CONNECT_DEFAULT);
            c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
        }

        c.adw_preferences_group_add(m.group, @ptrCast(@alignCast(row)));
        trackRow(m.group, @ptrCast(@alignCast(row)));
    }
}

// A tiny per-group list of the rows we added, so a rebuild can remove
// exactly them (AdwPreferencesGroup has no "clear").
var g_rows: std.ArrayList(struct { group: *c.AdwPreferencesGroup, row: *c.GtkWidget }) = .empty;

fn trackRow(group: *c.AdwPreferencesGroup, row: *c.GtkWidget) void {
    const gpa = g_gpa orelse return;
    g_rows.append(gpa, .{ .group = group, .row = row }) catch {};
}

fn clearGroupRows(group: *c.AdwPreferencesGroup) void {
    var i: usize = 0;
    while (i < g_rows.items.len) {
        if (g_rows.items[i].group == group) {
            c.adw_preferences_group_remove(group, @ptrCast(@alignCast(g_rows.items[i].row)));
            _ = g_rows.orderedRemove(i);
        } else i += 1;
    }
}

const RowCtx = struct { gpa: std.mem.Allocator, id: [manifest.MAX_ID_LEN]u8, id_len: usize };

/// Null on OOM or a registry entry whose id would not fit the fixed
/// buffer — registry.json is on-disk data, so it never gets to abort a
/// ReleaseFast build.
fn rowCtx(m: *Manager, id: []const u8) ?*RowCtx {
    if (!manifest.idValid(id)) return null;
    const rc = m.gpa.create(RowCtx) catch return null;
    rc.* = .{ .gpa = m.gpa, .id = undefined, .id_len = id.len };
    @memcpy(rc.id[0..rc.id_len], id[0..rc.id_len]);
    return rc;
}

fn freeRowCtx(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const rc = cast.userData(RowCtx, user);
    rc.gpa.destroy(rc);
}

fn onToggle(_: ?*c.GtkWidget, state: c.gboolean, user: ?*anyopaque) callconv(.c) c.gboolean {
    const rc = cast.userData(RowCtx, user);
    setEnabled(rc.id[0..rc.id_len], state != 0);
    return 0; // let the switch update its visual state
}

fn onRemoveClicked(_: ?*c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const rc = cast.userData(RowCtx, user);
    remove(rc.id[0..rc.id_len]);
}

fn addActionRow(group: ?*anyopaque, title: [*:0]const u8, subtitle: [*:0]const u8, cb: *const fn (?*c.GtkWidget, ?*anyopaque) callconv(.c) void) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    c.adw_action_row_set_activatable_widget(@ptrCast(@alignCast(row)), row);
    _ = c.g_signal_connect_data(row, "activated", @ptrCast(cb), null, null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_css_class(row, "activatable");
    c.adw_preferences_group_add(@ptrCast(@alignCast(group)), @ptrCast(@alignCast(row)));
}

// -- file dialogs ----------------------------------------------------

fn onLoadUnpacked(_: ?*c.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    const m = g_manager orelse return;
    const dialog = c.gtk_file_dialog_new();
    c.gtk_file_dialog_set_title(dialog, "Select an unpacked extension folder");
    c.gtk_file_dialog_select_folder(dialog, @ptrCast(m.window), null, @ptrCast(&onFolderChosen), null);
}

fn onFolderChosen(source: ?*c.GObject, res: ?*c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const m = g_manager orelse return;
    const file = c.gtk_file_dialog_select_folder_finish(@ptrCast(source), res, null) orelse return;
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(file) orelse return;
    defer c.g_free(path);
    _ = installUnpacked(m.gpa, std.mem.span(path)) catch |err| reportInstallError(err);
}

fn onLoadArchive(_: ?*c.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    const m = g_manager orelse return;
    const dialog = c.gtk_file_dialog_new();
    c.gtk_file_dialog_set_title(dialog, "Select an extension package (.xpi / .zip)");
    c.gtk_file_dialog_open(dialog, @ptrCast(m.window), null, @ptrCast(&onArchiveChosen), null);
}

fn onArchiveChosen(source: ?*c.GObject, res: ?*c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const m = g_manager orelse return;
    const file = c.gtk_file_dialog_open_finish(@ptrCast(source), res, null) orelse return;
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(file) orelse return;
    defer c.g_free(path);
    _ = installArchive(m.gpa, std.mem.span(path)) catch |err| reportInstallError(err);
}

/// Tell the user an install failed, and why.
///
/// It used to be `catch {}`: picking an MV3 package — which is what
/// every Chrome Web Store download and most "download extension" links
/// give you — did nothing at all, with no row, no message and no log
/// line. A failure the user CAUSED must be a failure the user SEES.
fn reportInstallError(err: InstallError) void {
    std.debug.print("webext: install failed: {s}\n", .{@errorName(err)});
    const m = g_manager orelse return;
    _ = confirm.present(m.window, .{
        .heading = "Could not install extension",
        .body = installErrorText(err),
        .responses = &.{.{ .id = "close", .label = "Close", .is_default = true, .is_close = true }},
    }, null);
}

// -- filesystem helpers ----------------------------------------------

fn readManifest(gpa: std.mem.Allocator, dir: []const u8) InstallError!manifest.Manifest {
    const path = std.fmt.allocPrint(gpa, "{s}/manifest.json", .{dir}) catch return error.OutOfMemory;
    defer gpa.free(path);
    const bytes = readFile(gpa, path) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => error.NoManifest,
    };
    defer gpa.free(bytes);
    return manifest.parse(gpa, bytes) catch |err| mapParseError(err);
}

const ReadError = error{ OutOfMemory, ReadFailed };

fn readFile(gpa: std.mem.Allocator, path: []const u8) ReadError![]u8 {
    var zbuf: [4096]u8 = undefined;
    if (path.len + 1 > zbuf.len) return error.ReadFailed;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&zbuf), c.O_RDONLY);
    if (fd < 0) return error.ReadFailed;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.ReadFailed;
    const size: usize = @intCast(@max(st.st_size, 0));
    if (size == 0 or size > 64 * 1024 * 1024) return error.ReadFailed;
    const buf = gpa.alloc(u8, size) catch return error.OutOfMemory;
    var got: usize = 0;
    while (got < size) {
        const n = c.read(fd, buf.ptr + got, size - got);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != size) {
        gpa.free(buf);
        return error.ReadFailed;
    }
    return buf;
}

/// Best-effort recursive delete of an owned extension directory.
fn removeTree(gpa: std.mem.Allocator, path: []const u8) void {
    var zbuf: [4096]u8 = undefined;
    if (path.len + 1 > zbuf.len) return;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const dir = c.opendir(@ptrCast(&zbuf)) orelse {
        _ = c.unlink(@ptrCast(&zbuf));
        return;
    };
    while (c.readdir(dir)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = std.fmt.allocPrint(gpa, "{s}/{s}", .{ path, name }) catch continue;
        defer gpa.free(child);
        var cst: c.struct_stat = undefined;
        var cz: [4096]u8 = undefined;
        if (child.len + 1 > cz.len) continue;
        @memcpy(cz[0..child.len], child);
        cz[child.len] = 0;
        if (c.lstat(@ptrCast(&cz), &cst) == 0 and (cst.st_mode & c.S_IFMT) == c.S_IFDIR) {
            removeTree(gpa, child);
        } else {
            _ = c.unlink(@ptrCast(&cz));
        }
    }
    _ = c.closedir(dir);
    _ = c.rmdir(@ptrCast(&zbuf));
}

const allocation_test_id = "gui-allocation@sketerm.test";
const allocation_old_registry =
    "[{\"id\":\"gui-allocation@sketerm.test\",\"dir\":\"/old\",\"enabled\":true,\"owned\":false}]";
const allocation_manifest =
    \\{"manifest_version":2,"name":"Reloaded Name","version":"3",
    \\ "browser_specific_settings":{"gecko":{"id":"gui-allocation@sketerm.test"}}}
;

const AllocationTestDir = struct {
    storage: [96:0]u8,
    old_xdg: ?[]u8,

    fn init() !AllocationTestDir {
        var self = AllocationTestDir{ .storage = undefined, .old_xdg = null };
        const template = "/tmp/sketerm-ui-webext-XXXXXX";
        @memcpy(self.storage[0..template.len], template);
        self.storage[template.len] = 0;
        _ = c.mkdtemp(@ptrCast(&self.storage)) orelse return error.SkipZigTest;
        if (c.getenv("XDG_DATA_HOME")) |old| self.old_xdg = try std.testing.allocator.dupe(u8, std.mem.span(old));
        if (c.setenv("XDG_DATA_HOME", @ptrCast(&self.storage), 1) != 0) return error.SkipZigTest;

        var package_buf: [256]u8 = undefined;
        const package = self.packageDir(&package_buf);
        pathz.makeDirs(package, 0o700) catch return error.SkipZigTest;
        var manifest_buf: [320]u8 = undefined;
        const manifest_path = std.fmt.bufPrint(&manifest_buf, "{s}/manifest.json", .{package}) catch unreachable;
        try writeAllocationFile(manifest_path, allocation_manifest);
        return self;
    }

    fn path(self: *const AllocationTestDir) []const u8 {
        return std.mem.sliceTo(&self.storage, 0);
    }

    fn packageDir(self: *const AllocationTestDir, out: []u8) []const u8 {
        return std.fmt.bufPrint(out, "{s}/package", .{self.path()}) catch unreachable;
    }

    fn registryPath(self: *const AllocationTestDir, out: []u8) []const u8 {
        return std.fmt.bufPrint(out, "{s}/sketerm/webext/registry.json", .{self.path()}) catch unreachable;
    }

    fn writeRegistry(self: *const AllocationTestDir, bytes: []const u8) !void {
        var dir_buf: [256]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/sketerm/webext", .{self.path()}) catch unreachable;
        try pathz.makeDirs(dir, 0o700);
        var path_buf: [320]u8 = undefined;
        try writeAllocationFile(self.registryPath(&path_buf), bytes);
    }

    fn expectRegistry(self: *const AllocationTestDir, expected: []const u8) !void {
        var path_buf: [320]u8 = undefined;
        const bytes = try readFile(std.testing.allocator, self.registryPath(&path_buf));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }

    fn deinit(self: *AllocationTestDir) void {
        if (self.old_xdg) |old| {
            var old_z: [4096:0]u8 = undefined;
            const value = std.fmt.bufPrintZ(&old_z, "{s}", .{old}) catch "";
            _ = c.setenv("XDG_DATA_HOME", value.ptr, 1);
            std.testing.allocator.free(old);
        } else {
            _ = c.unsetenv("XDG_DATA_HOME");
        }
        removeTree(std.testing.allocator, self.path());
    }
};

fn writeAllocationFile(path: []const u8, bytes: []const u8) !void {
    var path_buf: [4096:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const fd = c.open(path_z.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return error.WriteFailed;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn resetAllocationRegistry() void {
    const gpa = g_gpa orelse return;
    for (g_exts.items) |*e| freeExtWith(gpa, e);
    g_exts.deinit(gpa);
    g_exts = .empty;
    g_gpa = null;
    g_loaded = false;
}

fn seedAllocationEntry(gpa: std.mem.Allocator) !*Ext {
    var fresh = try initExt(gpa, allocation_test_id, "/old", "Old Name", "1", true, false);
    errdefer freeExtWith(gpa, &fresh);
    fresh.ok = true;
    fresh.err = try dupeOwned(gpa, "old error");
    try g_exts.append(gpa, fresh);
    return &g_exts.items[g_exts.items.len - 1];
}

fn expectAllocationEntry(
    dir: []const u8,
    name: []const u8,
    version: []const u8,
    ok: bool,
    err: []const u8,
    title: []const u8,
    subtitle: []const u8,
) !void {
    const t = std.testing;
    try t.expectEqual(@as(usize, 1), extensions().len);
    const e = find(allocation_test_id).?;
    try t.expectEqualStrings(dir, e.dir);
    try t.expectEqualStrings(name, e.name);
    try t.expectEqualStrings(version, e.version);
    try t.expectEqual(ok, e.ok);
    try t.expectEqualStrings(err, e.err);
    var title_buf: [160:0]u8 = undefined;
    var subtitle_buf: [256:0]u8 = undefined;
    const labels = managerLabels(e, &title_buf, &subtitle_buf);
    try t.expectEqualStrings(title, labels.title);
    try t.expectEqualStrings(subtitle, labels.subtitle);
    if (ok) {
        const asset = assetPath(t.allocator, allocation_test_id, "icons/icon.svg").?;
        defer t.allocator.free(asset);
        var expected_buf: [256]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "{s}/icons/icon.svg", .{dir});
        try t.expectEqualStrings(expected, asset);
    }
}

const AllocationRange = struct { first: usize, end: usize };

fn stateUpdateAllocationCase(fail_index: ?usize) !AllocationRange {
    const t = std.testing;
    var config: t.FailingAllocator.Config = .{};
    if (fail_index) |index| config.fail_index = index;
    var failing = t.FailingAllocator.init(t.allocator, config);
    g_gpa = failing.allocator();
    defer resetAllocationRegistry();
    _ = try seedAllocationEntry(failing.allocator());
    const first = failing.alloc_index;

    onState(.{
        .id = allocation_test_id,
        .name = "New Name",
        .version = "2",
        .enabled = 1,
        .ok = 0,
        .err = "new error",
    });
    if (fail_index != null) {
        try t.expect(failing.has_induced_failure);
        try expectAllocationEntry("/old", "Old Name", "1", true, "old error", "Old Name", "v1");
    } else {
        try expectAllocationEntry("/old", "New Name", "2", false, "new error", "New Name", "v2 — error: new error");
    }
    return .{ .first = first, .end = failing.alloc_index };
}

fn registryUpdateAllocationCase(env: *const AllocationTestDir, existing: bool, fail_index: ?usize) !AllocationRange {
    const t = std.testing;
    try env.writeRegistry(if (existing) allocation_old_registry else "[]");
    var config: t.FailingAllocator.Config = .{};
    if (fail_index) |index| config.fail_index = index;
    var failing = t.FailingAllocator.init(t.allocator, config);
    g_gpa = failing.allocator();
    defer resetAllocationRegistry();
    if (existing) _ = try seedAllocationEntry(failing.allocator());
    const first = failing.alloc_index;

    const result = updateRegistry(failing.allocator(), "/new", allocation_test_id, "Registered Name", "2", false);
    if (fail_index != null) {
        try t.expectError(error.OutOfMemory, result);
        try t.expect(failing.has_induced_failure);
        if (existing) {
            try expectAllocationEntry("/old", "Old Name", "1", true, "old error", "Old Name", "v1");
            try env.expectRegistry(allocation_old_registry);
        } else {
            try t.expectEqual(@as(usize, 0), extensions().len);
            try env.expectRegistry("[]");
        }
    } else {
        _ = try result;
        try expectAllocationEntry("/new", "Registered Name", "2", if (existing) true else false, if (existing) "old error" else "", "Registered Name", "v2");
    }
    return .{ .first = first, .end = failing.alloc_index };
}

fn removalAllocationCase(env: *const AllocationTestDir, fail_index: ?usize) !AllocationRange {
    const t = std.testing;
    try env.writeRegistry(allocation_old_registry);
    var config: t.FailingAllocator.Config = .{};
    if (fail_index) |index| config.fail_index = index;
    var failing = t.FailingAllocator.init(t.allocator, config);
    g_gpa = failing.allocator();
    defer resetAllocationRegistry();
    _ = try seedAllocationEntry(failing.allocator());
    const first = failing.alloc_index;

    remove(allocation_test_id);
    if (fail_index != null) {
        try t.expect(failing.has_induced_failure);
        try expectAllocationEntry("/old", "Old Name", "1", true, "old error", "Old Name", "v1");
        try env.expectRegistry(allocation_old_registry);
    } else {
        try t.expectEqual(@as(usize, 0), extensions().len);
        try env.expectRegistry("[]");
    }
    return .{ .first = first, .end = failing.alloc_index };
}

fn reloadAllocationCase(env: *const AllocationTestDir, fail_index: ?usize) !AllocationRange {
    const t = std.testing;
    var package_buf: [256]u8 = undefined;
    const package = env.packageDir(&package_buf);
    var json_buf: [768]u8 = undefined;
    const registry = try std.fmt.bufPrint(
        &json_buf,
        "[{{\"id\":\"{s}\",\"dir\":\"{s}\",\"enabled\":true,\"owned\":false}}]",
        .{ allocation_test_id, package },
    );
    try env.writeRegistry(registry);

    var config: t.FailingAllocator.Config = .{};
    if (fail_index) |index| config.fail_index = index;
    var failing = t.FailingAllocator.init(t.allocator, config);
    g_gpa = failing.allocator();
    defer resetAllocationRegistry();
    _ = try seedAllocationEntry(failing.allocator());
    const first = failing.alloc_index;

    ensureLoaded(failing.allocator());
    if (fail_index != null) {
        try t.expect(failing.has_induced_failure);
        try t.expect(!g_loaded);
        try expectAllocationEntry("/old", "Old Name", "1", true, "old error", "Old Name", "v1");
    } else {
        try t.expect(g_loaded);
        try expectAllocationEntry(package, "Reloaded Name", "3", false, "", "Reloaded Name", "v3");
    }
    return .{ .first = first, .end = failing.alloc_index };
}

test "GUI web extension state stays renderable across every allocation failure" {
    const t = std.testing;
    const state = try stateUpdateAllocationCase(null);
    try t.expectEqual(@as(usize, 3), state.end - state.first);
    for (state.first..state.end) |fail_index| _ = try stateUpdateAllocationCase(fail_index);

    var env = try AllocationTestDir.init();
    defer env.deinit();

    const registration = try registryUpdateAllocationCase(&env, false, null);
    try t.expect(registration.end > registration.first + 4);
    for (registration.first..registration.end) |fail_index| {
        _ = try registryUpdateAllocationCase(&env, false, fail_index);
    }

    const update = try registryUpdateAllocationCase(&env, true, null);
    try t.expect(update.end > update.first + 3);
    for (update.first..update.end) |fail_index| {
        _ = try registryUpdateAllocationCase(&env, true, fail_index);
    }

    const removal = try removalAllocationCase(&env, null);
    try t.expect(removal.end > removal.first);
    for (removal.first..removal.end) |fail_index| {
        _ = try removalAllocationCase(&env, fail_index);
    }

    const reload = try reloadAllocationCase(&env, null);
    try t.expect(reload.end > reload.first + 8);
    for (reload.first..reload.end) |fail_index| {
        _ = try reloadAllocationCase(&env, fail_index);
    }
}

test "an archive install routes locally unless a helper can stage it" {
    const t = std.testing;
    // A remote browser pane: ready, but every webext capability zeroed.
    try t.expectEqual(ArchiveRoute.local, archiveRoute(true, false, false));
    // A local helper too old for the transaction keeps the legacy path.
    try t.expectEqual(ArchiveRoute.local, archiveRoute(true, true, false));
    try t.expectEqual(ArchiveRoute.local, archiveRoute(false, false, false));
    try t.expectEqual(ArchiveRoute.helper_transaction, archiveRoute(true, true, true));
}
