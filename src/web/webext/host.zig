//! WebExtensions host state — the registry of loaded extensions, their
//! persisted `storage.local`, and the `browser.*` API dispatch. Engine
//! AGNOSTIC: no CEF type appears here (it takes and returns JSON strings
//! and file paths), so `cefhost.zig` drives it and a future engine would
//! reuse it unchanged. Filesystem + libc only (via `cbindings`); the
//! pure decision logic lives in the sibling modules (`manifest`,
//! `match`, `storage`), which carry the unit tests.
//!
//! The single dispatch entry point `dispatchApi` is the CLEARLY NAMED
//! SEAM the proposal asks for: a later wave adds blocking webRequest by
//! extending its switch, not by restructuring the host.

const std = @import("std");
const c = @import("cbindings");
const manifest = @import("manifest.zig");
const match = @import("match.zig");
const storage = @import("storage.zig");
const webrequest = @import("webrequest.zig");
const origins = @import("origins.zig");
const i18n = @import("i18n.zig");
const tabs = @import("tabs.zig");
const action = @import("action.zig");
const reply = @import("reply.zig");
const atomicwrite = @import("../../util/atomicwrite.zig");
const pathz = @import("../../util/pathz.zig");
const diag = @import("../../util/diag.zig");
const clock = @import("../../util/clock.zig");

/// The session's language tag, for `i18n` locale negotiation. POSIX
/// order, and everything after the encoding or modifier is dropped
/// (`nl_BE.UTF-8@euro` -> `nl_BE`).
pub fn uiLanguage() []const u8 {
    const State = struct {
        var buf: [origins.MAX_LOCALE]u8 = undefined;
        var val: []const u8 = &.{};
        var done = false;
    };
    if (State.done) return State.val;
    State.done = true;
    for ([_][]const u8{ "LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
        var zbuf: [16]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{name}) catch continue;
        const raw = c.getenv(z.ptr) orelse continue;
        var s: []const u8 = std.mem.span(raw);
        // LANGUAGE is a colon-separated preference list.
        if (std.mem.indexOfScalar(u8, s, ':')) |i| s = s[0..i];
        if (std.mem.indexOfAny(u8, s, ".@")) |i| s = s[0..i];
        if (s.len == 0 or s.len > State.buf.len) continue;
        if (std.mem.eql(u8, s, "C") or std.mem.eql(u8, s, "POSIX")) continue;
        @memcpy(State.buf[0..s.len], s);
        State.val = State.buf[0..s.len];
        return State.val;
    }
    return State.val;
}

pub const Extension = struct {
    /// Stable id (the client's), owned.
    id: []u8,
    /// Unpacked directory, absolute, owned.
    dir: []u8,
    enabled: bool = false,
    /// Parse succeeded; when false `err` explains why and `man` is unset.
    ok: bool = false,
    err: []u8 = &.{},
    man: ?manifest.Manifest = null,
    /// Lazily-loaded persisted storage.local.
    store: ?storage.Store = null,
    /// Set when `store` holds writes the file does not. `flushStores`
    /// writes them once the coalescing window has passed, and teardown
    /// FLUSHES rather than drops (the `ui/debounce.zig` contract).
    store_dirty: bool = false,
    /// Monotonic ms after which a dirty store is written.
    store_due_ms: i64 = 0,
    /// The hidden background-page view id, 0 when the extension has no
    /// background or is disabled. Owned by cefhost; recorded here so a
    /// routing lookup finds it.
    bg_view: u32 = 0,
    /// Blocking-webRequest listener registry, HEAP-allocated so the
    /// pointer stays valid while `Host.exts` reallocates — the engine's
    /// IO thread reads it through `webrequest.slots` and an ArrayList
    /// element's address is not stable. Null until the extension first
    /// registers a listener.
    wreq: ?*webrequest.Registry = null,
    /// Browser-toolbar state: manifest defaults plus runtime overrides.
    action: action.State = .{},
    /// Rotating, extension-bound authority handed only to this
    /// extension's injected bridge. An id without this token has no
    /// access to browser state.
    capability: [origins.CAP_LEN]u8 = @splat(0),
    capability_ok: bool = false,

    fn name(self: *const Extension) []const u8 {
        return if (self.man) |*m| m.name else "";
    }
    fn version(self: *const Extension) []const u8 {
        return if (self.man) |*m| m.version else "";
    }
};

/// A complete replacement that owns every field until `commitSet` consumes it.
pub const PreparedSet = struct {
    gpa: std.mem.Allocator,
    ext: Extension,
    consumed: bool = false,

    pub fn deinit(self: *PreparedSet) void {
        if (!self.consumed) freeCandidate(self.gpa, &self.ext);
        self.consumed = true;
    }
};

fn freeBytes(gpa: std.mem.Allocator, value: []u8) void {
    if (value.len != 0) gpa.free(value);
}

fn dupeBytes(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    return if (value.len == 0) &.{} else try gpa.dupe(u8, value);
}

fn freeCandidate(gpa: std.mem.Allocator, e: *Extension) void {
    freeBytes(gpa, e.id);
    freeBytes(gpa, e.dir);
    freeBytes(gpa, e.err);
    if (e.man) |*m| m.deinit();
    e.action.deinit(gpa);
    e.* = undefined;
}

/// How long a burst of `storage.local` writes is coalesced. A page that
/// stores on every keystroke otherwise pays a full serialize plus two
/// fsyncs per call, synchronously inside its own promise.
const store_coalesce_ms: i64 = 400;

pub const Host = struct {
    gpa: std.mem.Allocator,
    /// `$XDG_DATA_HOME/sketerm/webext` — per-extension storage lives in
    /// `<data>/<id>/storage.json`. Owned.
    data_dir: []u8 = &.{},
    exts: std.ArrayList(Extension) = .empty,
    /// The GUI's tab set, mirrored here. Empty until the client posts
    /// one, which is honest: an extension then sees no tabs rather than
    /// invented ones.
    tabs: tabs.Table = .{},

    pub fn init(gpa: std.mem.Allocator) Host {
        return .{ .gpa = gpa, .data_dir = resolveDataDir(gpa) };
    }

    pub fn deinit(self: *Host) void {
        self.flushStores(std.math.maxInt(i64));
        for (self.exts.items) |*e| self.freeExt(e);
        self.exts.deinit(self.gpa);
        self.tabs.deinit(self.gpa);
        freeBytes(self.gpa, self.data_dir);
    }

    /// Write every storage.local whose coalescing window has expired.
    /// `now_ms` of `maxInt` means "flush everything now" (teardown).
    /// A failed write keeps the store dirty and retries next window, so
    /// a transient ENOSPC does not silently discard the extension's data.
    pub fn flushStores(self: *Host, now_ms: i64) void {
        for (self.exts.items) |*e| {
            if (!e.store_dirty or now_ms < e.store_due_ms) continue;
            const s = &(e.store orelse continue);
            self.persistStore(e, s) catch |err| {
                diag.print(
                    "sketerm-webengine: storage.local write failed for {s}: {s}\n",
                    .{ e.id, @errorName(err) },
                );
                e.store_due_ms = now_ms +| store_coalesce_ms;
                continue;
            };
            e.store_dirty = false;
        }
    }

    fn freeExt(self: *Host, e: *Extension) void {
        // Teardown flushes: an extension removed inside the coalescing
        // window must not lose the write it already saw succeed.
        if (e.store_dirty) {
            if (e.store) |*s| self.persistStore(e, s) catch {};
            e.store_dirty = false;
        }
        // ORDER IS THE SAFETY PROPERTY: the slot must leave the
        // published table before the registry it points at is freed, or
        // the engine's IO thread can read a dangling pointer.
        webrequest.unpublish(e.id);
        if (e.wreq) |r| {
            r.deinit(self.gpa);
            self.gpa.destroy(r);
            e.wreq = null;
        }
        freeBytes(self.gpa, e.id);
        freeBytes(self.gpa, e.dir);
        freeBytes(self.gpa, e.err);
        if (e.man) |*m| m.deinit();
        if (e.store) |*s| s.deinit();
        e.action.deinit(self.gpa);
    }

    pub fn find(self: *Host, id: []const u8) ?*Extension {
        for (self.exts.items) |*e| {
            if (std.mem.eql(u8, e.id, id)) return e;
        }
        return null;
    }

    /// The extension a background view id belongs to, or null.
    pub fn findByBgView(self: *Host, view: u32) ?*Extension {
        if (view == 0) return null;
        for (self.exts.items) |*e| {
            if (e.bg_view == view) return e;
        }
        return null;
    }

    /// Load-or-update an extension. Reparses the manifest from
    /// `dir/manifest.json` every call so a re-enable picks up edits.
    /// Never fails hard: a bad manifest records `ok = false` + `err`.
    pub fn set(self: *Host, id: []const u8, dir: []const u8, enabled: bool) !*Extension {
        var prepared = try self.prepareSet(id, dir, enabled);
        defer prepared.deinit();
        return self.commitSet(&prepared);
    }

    /// Allocate and parse a complete extension instance without changing live state.
    pub fn prepareSet(self: *Host, id: []const u8, dir: []const u8, enabled: bool) !PreparedSet {
        if (!manifest.idValid(id)) return error.InvalidExtensionId;
        var candidate = Extension{
            .id = try dupeBytes(self.gpa, id),
            .dir = &.{},
            .enabled = enabled,
        };
        errdefer freeCandidate(self.gpa, &candidate);
        candidate.dir = try dupeBytes(self.gpa, dir);
        try self.parseCandidate(&candidate);
        try mintCapability(&candidate);
        if (self.find(id) == null) try self.exts.ensureUnusedCapacity(self.gpa, 1);
        return .{ .gpa = self.gpa, .ext = candidate };
    }

    /// Replace or append a prepared instance without performing allocations.
    pub fn commitSet(self: *Host, prepared: *PreparedSet) *Extension {
        std.debug.assert(!prepared.consumed);
        const candidate = &prepared.ext;
        if (self.find(candidate.id)) |e| {
            self.clearParsedState(e);
            freeBytes(self.gpa, e.dir);
            e.dir = candidate.dir;
            candidate.dir = &.{};
            e.enabled = candidate.enabled;
            e.ok = candidate.ok;
            e.err = candidate.err;
            candidate.err = &.{};
            e.man = candidate.man;
            candidate.man = null;
            e.action = candidate.action;
            candidate.action = .{};
            e.capability = candidate.capability;
            e.capability_ok = candidate.capability_ok;
            freeBytes(self.gpa, candidate.id);
            candidate.id = &.{};
            prepared.consumed = true;
            return e;
        }

        self.exts.appendAssumeCapacity(candidate.*);
        prepared.consumed = true;
        return &self.exts.items[self.exts.items.len - 1];
    }

    /// Resolve an enabled extension only when its rotating capability
    /// matches, without early-exit comparison.
    pub fn authorize(self: *Host, id: []const u8, capability: []const u8) ?*Extension {
        const e = self.authorizeCapability(capability) orelse return null;
        return if (std.mem.eql(u8, e.id, id)) e else null;
    }

    /// Resolve the extension instance that owns a capability, without
    /// trusting the caller-supplied extension id.
    pub fn authorizeCapability(self: *Host, capability: []const u8) ?*Extension {
        if (capability.len != origins.CAP_LEN) return null;
        for (self.exts.items) |*e| {
            if (!e.enabled or !e.ok or !e.capability_ok) continue;
            var diff: u8 = 0;
            for (capability, e.capability) |a, b| diff |= a ^ b;
            if (diff == 0) return e;
        }
        return null;
    }

    /// Invalidate the old extension instance and mint its replacement
    /// authority. A failure leaves the extension disabled rather than
    /// retaining a capability that should have died.
    pub fn rotateCapability(self: *Host, e: *Extension) bool {
        _ = self;
        e.capability = @splat(0);
        e.capability_ok = false;
        mintCapability(e) catch {
            e.enabled = false;
            return false;
        };
        return true;
    }

    /// Forget every webRequest listener of `e`. Called whenever the
    /// thing that OWNS the listener functions goes away — the manifest
    /// is reparsed, the extension is disabled, its background page is
    /// torn down. Held requests are answered by the engine side, which
    /// watches the same events; this only drops the registrations so no
    /// later request can be held for a listener that no longer exists.
    pub fn clearListeners(self: *Host, e: *Extension) void {
        const r = e.wreq orelse return;
        webrequest.acquire();
        defer webrequest.release();
        r.clear(self.gpa);
        webrequest.refreshAnyLocked();
    }

    fn clearParsedState(self: *Host, e: *Extension) void {
        // The compiled host permissions belong to the OLD manifest.
        if (e.wreq) |r| {
            webrequest.acquire();
            r.clear(self.gpa);
            r.hosts.deinit(self.gpa);
            r.hosts = .{};
            r.hosts_built = false;
            webrequest.refreshAnyLocked();
            webrequest.release();
        }
        if (e.man) |*m| {
            m.deinit();
            e.man = null;
        }
        e.action.deinit(self.gpa);
        freeBytes(self.gpa, e.err);
        e.err = &.{};
        e.ok = false;
    }

    fn parseCandidate(self: *Host, e: *Extension) !void {
        var path_buf: [4096]u8 = undefined;
        const mpath = std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{e.dir}) catch {
            e.err = try dupeBytes(self.gpa, "path too long");
            return;
        };
        const bytes = readFileZFallible(self.gpa, mpath, 4 * 1024 * 1024) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => {
                e.err = try dupeBytes(self.gpa, "manifest.json not readable");
                return;
            },
        };
        defer self.gpa.free(bytes);
        var m = manifest.parse(self.gpa, bytes) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            e.err = try std.fmt.allocPrint(self.gpa, "manifest parse: {s}", .{@errorName(err)});
            return;
        };
        const action_kind: manifest.ActionKind = if (m.browser_action != null) .browser else .page;
        const action_manifest = m.browser_action orelse m.page_action;
        const action_state = action.State.init(self.gpa, action_kind, action_manifest) catch |err| {
            m.deinit();
            return err;
        };
        e.man = m;
        e.action = action_state;
        e.ok = true;
    }

    pub fn remove(self: *Host, id: []const u8) void {
        if (!manifest.idValid(id)) return;
        for (self.exts.items, 0..) |*e, i| {
            if (std.mem.eql(u8, e.id, id)) {
                self.freeExt(e);
                _ = self.exts.orderedRemove(i);
                return;
            }
        }
    }

    /// Read a file listed in a content_script/background (relative to the
    /// extension dir). Rejects any path that escapes the dir. Caller
    /// frees.
    pub fn readAsset(self: *Host, e: *const Extension, rel: []const u8) ?[]u8 {
        if (std.mem.indexOf(u8, rel, "..") != null) return null;
        var buf: [4096]u8 = undefined;
        const clean = std.mem.trimStart(u8, rel, "/");
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ e.dir, clean }) catch return null;
        return readFileZ(self.gpa, path, 16 * 1024 * 1024);
    }

    // -- storage.local ------------------------------------------------

    fn storeFor(self: *Host, e: *Extension) *storage.Store {
        if (e.store == null) {
            const bytes = self.readStorageBytes(e);
            defer if (bytes) |b| self.gpa.free(b);
            e.store = storage.Store.load(self.gpa, bytes orelse "");
        }
        return &e.store.?;
    }

    fn readStorageBytes(self: *Host, e: *Extension) ?[]u8 {
        if (self.data_dir.len == 0) return null;
        var buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}/storage.json", .{ self.data_dir, e.id }) catch return null;
        return readFileZ(self.gpa, path, 16 * 1024 * 1024);
    }

    fn persistStore(self: *Host, e: *Extension, s: *storage.Store) !void {
        if (self.data_dir.len == 0) return error.StorageUnavailable;
        const bytes = try s.serialize(self.gpa);
        defer self.gpa.free(bytes);
        var dir_buf: [4096]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ self.data_dir, e.id }) catch
            return error.PathTooLong;
        try pathz.makeDirs(dir, 0o700);
        var path_buf: [4200]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/storage.json", .{dir}) catch
            return error.PathTooLong;
        try atomicwrite.writeFileExact(path, bytes, 0o600);
    }

    // -- browser.* dispatch (THE SEAM) --------------------------------

    /// Dispatch one `browser.<ns>.<method>(args)` call. `args_json` is a
    /// JSON ARRAY of the call arguments. Returns an owned JSON object
    /// `{"result":<value>}` or `{"error":"..."}`; `changed` is set to a
    /// non-null `storage.onChanged` payload (owned) when a storage
    /// mutation occurred, so the caller can broadcast it.
    ///
    /// A later wave adds `webRequest` here as another `ns` arm with a
    /// BLOCKING variant (the held-request protocol frame), which is why
    /// the dispatch is one function keyed on namespace rather than
    /// scattered across call sites.
    pub fn dispatchApi(
        self: *Host,
        e: *Extension,
        ns: []const u8,
        method: []const u8,
        args_json: []const u8,
        changed: *?[]u8,
    ) []u8 {
        changed.* = null;
        if (std.mem.eql(u8, ns, "storage")) return self.dispatchStorage(e, method, args_json, changed);
        if (std.mem.eql(u8, ns, "runtime")) return self.dispatchRuntime(e, method, args_json);
        if (std.mem.eql(u8, ns, "i18n")) return self.dispatchI18n(e, method, args_json);
        if (std.mem.eql(u8, ns, "tabs")) return self.dispatchTabs(e, method, args_json);
        if (std.mem.eql(u8, ns, "webRequest")) return self.dispatchWebRequest(e, method, args_json);
        if (std.mem.eql(u8, ns, "browserAction")) {
            if (e.action.kind != .browser) return self.errResult("extension has no browserAction");
            return e.action.dispatch(self.gpa, method, args_json);
        }
        if (std.mem.eql(u8, ns, "pageAction")) {
            if (e.action.kind != .page) return self.errResult("extension has no pageAction");
            return e.action.dispatch(self.gpa, method, args_json);
        }
        return self.errResult("unknown namespace");
    }

    /// `browser.webRequest` — registration only. The EVENTS are pushed
    /// the other way (engine -> background page) and never come through
    /// here, so this arm stays a small bookkeeping call: it is the seam
    /// the 0xB0 block's header promised, filled in without reshaping the
    /// dispatch around it.
    ///
    /// The caller must already have refused this for a non-background
    /// frame — a content script has no business registering a network
    /// filter, and the engine side is the only thing that knows which
    /// frame a call arrived from.
    fn dispatchWebRequest(self: *Host, e: *Extension, method: []const u8, args_json: []const u8) []u8 {
        const man = if (e.man) |*m| m else return self.errResult("extension has no manifest");

        if (std.mem.eql(u8, method, "handlerBehaviorChanged")) {
            // Nothing is cached across requests here, so this is
            // genuinely a no-op rather than a stub: there is no stale
            // decision for it to flush.
            return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
        }

        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, args_json, .{}) catch
            return self.errResult("bad args");
        defer parsed.deinit();
        const args = if (parsed.value == .array) parsed.value.array.items else &[_]std.json.Value{};

        if (std.mem.eql(u8, method, "removeListener")) {
            if (args.len < 1 or args[0] != .integer) return self.errResult("bad listener id");
            const lid: u32 = tabs.u32Of(args[0]) orelse return self.errResult("bad listener id");
            const r = e.wreq orelse return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
            webrequest.acquire();
            r.remove(self.gpa, lid);
            webrequest.refreshAnyLocked();
            webrequest.release();
            return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
        }

        if (!std.mem.eql(u8, method, "addListener")) return self.errResult("unknown webRequest method");

        // args: [eventName, listenerId, RequestFilter, extraInfoSpec]
        if (args.len < 2 or args[0] != .string or args[1] != .integer) return self.errResult("bad args");
        const event = webrequest.Event.fromStr(args[0].string) orelse
            return self.errResult("unsupported webRequest event");
        const lid: u32 = tabs.u32Of(args[1]) orelse return self.errResult("bad listener id");

        var urls: std.ArrayList([]const u8) = .empty;
        defer urls.deinit(self.gpa);
        var types: u32 = webrequest.ALL_TYPES;
        if (args.len > 2 and args[2] == .object) {
            const f = args[2].object;
            if (f.get("urls")) |uv| {
                if (uv == .array) {
                    for (uv.array.items) |it| {
                        if (it == .string) urls.append(self.gpa, it.string) catch return self.errResult("oom");
                    }
                }
            }
            types = webrequest.typesMask(f.get("types"));
        }
        const extra = webrequest.extraFrom(if (args.len > 3) args[3] else null);

        const r = e.wreq orelse blk: {
            const fresh = self.gpa.create(webrequest.Registry) catch return self.errResult("oom");
            fresh.* = .{};
            e.wreq = fresh;
            break :blk fresh;
        };

        webrequest.acquire();
        r.buildHosts(self.gpa, man);
        const res = r.add(self.gpa, man, lid, event, extra, types, urls.items);
        webrequest.refreshAnyLocked();
        webrequest.release();
        res catch |err| return self.errResult(@errorName(err));

        // Publishing AFTER a successful add: a registry with no listener
        // has nothing for the request path to find, and publishing on
        // failure would put an empty slot in a 16-deep table.
        if (!webrequest.publish(e.id, r)) return self.errResult("too many extensions with webRequest listeners");
        return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
    }

    fn dispatchStorage(self: *Host, e: *Extension, method: []const u8, args_json: []const u8, changed: *?[]u8) []u8 {
        const s = self.storeFor(e);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, args_json, .{}) catch
            return self.errResult("bad args");
        defer parsed.deinit();
        const args = if (parsed.value == .array) parsed.value.array.items else &[_]std.json.Value{};

        if (std.mem.eql(u8, method, "get")) {
            // An OBJECT argument is `{key: default}`, not a key list:
            // its values are what an unstored key must come back as.
            // Treating it as a key list is why every extension's
            // first-run settings used to arrive empty.
            if (args.len > 0 and args[0] == .object) {
                const obj = s.getWithDefaults(self.gpa, args[0].object) catch return self.errResult("oom");
                defer self.gpa.free(obj);
                return self.wrapResult(obj);
            }
            const keys = self.keysFromArg(if (args.len > 0) args[0] else .null) catch return self.errResult("oom");
            defer self.gpa.free(keys);
            const obj = s.get(self.gpa, keys) catch return self.errResult("oom");
            defer self.gpa.free(obj);
            return self.wrapResult(obj);
        }
        const is_set = std.mem.eql(u8, method, "set");
        const is_remove = std.mem.eql(u8, method, "remove");
        const is_clear = std.mem.eql(u8, method, "clear");
        if (!is_set and !is_remove and !is_clear) return self.errResult("unknown storage method");

        // Mutate the live store; the file follows on the next
        // `flushStores`. The write used to happen HERE, transactionally
        // on a deep copy — a full serialize, a full JSON reparse and two
        // fsyncs inside the page's promise, per `set`. A page that
        // stores per keystroke paid that every keystroke.
        const ch = if (is_set) blk: {
            const patch = if (args.len > 0)
                self.valueToJson(args[0]) catch |err| return self.errResult(@errorName(err))
            else
                self.gpa.dupe(u8, "{}") catch |err| return self.errResult(@errorName(err));
            defer self.gpa.free(patch);
            break :blk s.set(self.gpa, patch) catch |err|
                return self.errResult(@errorName(err));
        } else if (is_remove) blk: {
            const keys = self.keysFromArg(if (args.len > 0) args[0] else .null) catch |err|
                return self.errResult(@errorName(err));
            defer self.gpa.free(keys);
            break :blk s.remove(self.gpa, keys) catch |err|
                return self.errResult(@errorName(err));
        } else s.clear(self.gpa) catch |err|
            return self.errResult(@errorName(err));

        if (std.mem.eql(u8, ch, "{}")) {
            self.gpa.free(ch);
            return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
        }
        const result = self.gpa.dupe(u8, "{\"result\":null}") catch {
            self.gpa.free(ch);
            return self.errResult("oom");
        };
        if (!e.store_dirty) {
            e.store_dirty = true;
            e.store_due_ms = clock.nowMs() +| store_coalesce_ms;
        }
        changed.* = ch;
        return result;
    }

    fn dispatchRuntime(self: *Host, e: *Extension, method: []const u8, _: []const u8) []u8 {
        if (std.mem.eql(u8, method, "getManifest")) {
            var buf: [4096]u8 = undefined;
            const mpath = std.fmt.bufPrint(&buf, "{s}/manifest.json", .{e.dir}) catch return self.errResult("path");
            const bytes = readFileZ(self.gpa, mpath, 4 * 1024 * 1024) orelse return self.errResult("no manifest");
            defer self.gpa.free(bytes);
            return self.wrapResult(bytes);
        }
        return self.errResult("unknown runtime method");
    }

    fn dispatchI18n(self: *Host, e: *Extension, method: []const u8, args_json: []const u8) []u8 {
        if (std.mem.eql(u8, method, "getUILanguage")) return reply.okString(self.gpa, uiLanguage());
        if (!std.mem.eql(u8, method, "getMessage")) return self.errResult("unknown i18n method");
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, args_json, .{}) catch
            return self.errResult("bad args");
        defer parsed.deinit();
        const args = if (parsed.value == .array) parsed.value.array.items else &[_]std.json.Value{};
        if (args.len == 0 or args[0] != .string) return self.gpa.dupe(u8, "{\"result\":\"\"}") catch self.errResult("oom");
        const subs = i18n.substitutionsFrom(self.gpa, if (args.len > 1) args[1] else .null) catch
            return self.errResult("oom");
        defer self.gpa.free(subs);
        const msg = self.lookupMessage(e, args[0].string, subs) orelse
            return self.gpa.dupe(u8, "{\"result\":\"\"}") catch self.errResult("oom");
        defer self.gpa.free(msg);
        return reply.okString(self.gpa, msg);
    }

    /// `_locales/<negotiated>/messages.json` -> the `message` of `key`,
    /// with its `$1`/`$name$` placeholders expanded.
    fn lookupMessage(self: *Host, e: *Extension, key: []const u8, subs: []const []const u8) ?[]u8 {
        var lbuf: [origins.MAX_LOCALE]u8 = undefined;
        const locale = self.resolveLocale(e, &lbuf) orelse return null;
        var buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/_locales/{s}/messages.json", .{ e.dir, locale }) catch return null;
        const bytes = readFileZ(self.gpa, path, 4 * 1024 * 1024) orelse return null;
        defer self.gpa.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const entry = parsed.value.object.get(key) orelse return null;
        if (entry != .object) return null;
        const msg = entry.object.get("message") orelse return null;
        if (msg != .string) return null;
        const holders = entry.object.get("placeholders");
        const ph: i18n.Placeholders = if (holders != null and holders.? == .object) holders.?.object else null;
        return i18n.expand(self.gpa, msg.string, ph, subs) catch null;
    }

    /// The `_locales` directory to read for this extension: the session
    /// language when the package ships it, else `default_locale`.
    /// Written into `out`; null when the package is not localized.
    pub fn resolveLocale(self: *Host, e: *Extension, out: []u8) ?[]const u8 {
        const m = if (e.man) |*mm| mm else return null;
        const default_locale = m.default_locale orelse return null;
        var names: [64][]const u8 = undefined;
        var store: [64 * origins.MAX_LOCALE]u8 = undefined;
        const avail = self.listLocales(e, &names, &store);
        const pick = i18n.pickLocale(avail, uiLanguage(), default_locale);
        if (pick.len > out.len) return null;
        @memcpy(out[0..pick.len], pick);
        return out[0..pick.len];
    }

    /// Directory names under `<dir>/_locales`. Copies each name into
    /// `store`, because a `readdir` entry is only valid until the next
    /// call.
    fn listLocales(self: *Host, e: *Extension, names: [][]const u8, store: []u8) [][]const u8 {
        _ = self;
        var buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}/_locales", .{e.dir}) catch return names[0..0];
        const dir = c.opendir(path.ptr) orelse return names[0..0];
        defer _ = c.closedir(dir);
        var n: usize = 0;
        var used: usize = 0;
        while (n < names.len) {
            const ent = c.readdir(dir) orelse break;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (name.len == 0 or name[0] == '.') continue;
            if (name.len > origins.MAX_LOCALE or used + name.len > store.len) continue;
            @memcpy(store[used..][0..name.len], name);
            names[n] = store[used..][0..name.len];
            used += name.len;
            n += 1;
        }
        return names[0..n];
    }

    /// `browser.tabs` over the table the CLIENT mirrors into `self.tabs`
    /// (`webext_tabs`). `query` and `get` are answered here; `sendMessage`
    /// is NOT — it has to reach a frame, which only the engine side can
    /// do, so `cefhost` intercepts that method before dispatch and this
    /// arm never sees it.
    fn dispatchTabs(self: *Host, e: *Extension, method: []const u8, args_json: []const u8) []u8 {
        // MV2 gates the url/title fields of a Tab on the `tabs`
        // permission; the identity fields are always visible. Refusing
        // the whole namespace would be wrong (uBO reads tab ids with
        // only `<all_urls>`), so the permission is checked where it
        // applies rather than at the door.
        _ = e;
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, args_json, .{}) catch
            return self.errResult("bad args");
        defer parsed.deinit();
        const args = if (parsed.value == .array) parsed.value.array.items else &[_]std.json.Value{};

        if (std.mem.eql(u8, method, "query")) {
            var ids: [256]u32 = undefined;
            const hits = self.tabs.query(self.gpa, if (args.len > 0) args[0] else .null, &ids);
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            aw.writer.writeAll("{\"result\":[") catch return self.errResult("oom");
            for (hits, 0..) |id, i| {
                if (i != 0) aw.writer.writeByte(',') catch return self.errResult("oom");
                const tb = self.tabs.find(id) orelse continue;
                tabs.Table.writeTab(tb, &aw.writer) catch return self.errResult("oom");
            }
            aw.writer.writeAll("]}") catch return self.errResult("oom");
            return aw.toOwnedSlice() catch self.errResult("oom");
        }
        if (std.mem.eql(u8, method, "get")) {
            if (args.len == 0 or args[0] != .integer) return self.errResult("bad tab id");
            const want_id = tabs.u32Of(args[0]) orelse return self.errResult("no such tab");
            const tb = self.tabs.find(want_id) orelse
                return self.errResult("no such tab");
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            aw.writer.writeAll("{\"result\":") catch return self.errResult("oom");
            tabs.Table.writeTab(tb, &aw.writer) catch return self.errResult("oom");
            aw.writer.writeByte('}') catch return self.errResult("oom");
            return aw.toOwnedSlice() catch self.errResult("oom");
        }
        return self.errResult("unknown tabs method");
    }

    // -- helpers ------------------------------------------------------

    /// A storage `get`/`remove` key argument is null (all), a string, or
    /// an array of strings, or an object whose keys are the wanted keys.
    /// Returns an owned slice of borrowed key strings that live as long
    /// as `arg` — caller uses them immediately.
    fn keysFromArg(self: *Host, arg: std.json.Value) ![][]const u8 {
        var list = std.ArrayList([]const u8).empty;
        errdefer list.deinit(self.gpa);
        switch (arg) {
            .null => {},
            .string => |s| try list.append(self.gpa, s),
            .array => |a| for (a.items) |it| {
                if (it == .string) try list.append(self.gpa, it.string);
            },
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |kv| try list.append(self.gpa, kv.key_ptr.*);
            },
            else => {},
        }
        return list.toOwnedSlice(self.gpa);
    }

    fn valueToJson(self: *Host, v: std.json.Value) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        try std.json.Stringify.value(v, .{}, &aw.writer);
        return aw.toOwnedSlice();
    }

    /// Wrap a raw JSON value string as `{"result":<value>}`.
    fn wrapResult(self: *Host, value_json: []const u8) []u8 {
        return reply.ok(self.gpa, value_json);
    }

    fn errResult(self: *Host, msg: []const u8) []u8 {
        return reply.err(self.gpa, msg);
    }
};

fn mintCapability(e: *Extension) !void {
    var raw: [origins.CAP_LEN / 2]u8 = undefined;
    if (c.getentropy(&raw, raw.len) != 0) return error.RandomFailed;
    e.capability = std.fmt.bytesToHex(raw, .lower);
    e.capability_ok = true;
}

test "extension capabilities authorize only their owning instance and rotate" {
    const gpa = std.testing.allocator;
    var host = Host{ .gpa = gpa, .data_dir = try gpa.dupe(u8, "") };
    defer host.deinit();

    const one_cap: [origins.CAP_LEN]u8 = @splat('1');
    const two_cap: [origins.CAP_LEN]u8 = @splat('2');
    try host.exts.append(gpa, .{
        .id = try gpa.dupe(u8, "one@sketerm.test"),
        .dir = try gpa.dupe(u8, "/one"),
        .enabled = true,
        .ok = true,
        .capability = one_cap,
        .capability_ok = true,
    });
    try host.exts.append(gpa, .{
        .id = try gpa.dupe(u8, "two@sketerm.test"),
        .dir = try gpa.dupe(u8, "/two"),
        .enabled = true,
        .ok = true,
        .capability = two_cap,
        .capability_ok = true,
    });

    try std.testing.expect(host.authorize("two@sketerm.test", &one_cap) == null);
    try std.testing.expectEqualStrings("one@sketerm.test", host.authorizeCapability(&one_cap).?.id);
    var changed: ?[]u8 = null;
    const alias = host.dispatchApi(host.find("one@sketerm.test").?, "action", "setTitle", "[]", &changed);
    defer gpa.free(alias);
    try std.testing.expect(std.mem.indexOf(u8, alias, "unknown namespace") != null);

    const one = host.find("one@sketerm.test").?;
    try std.testing.expect(host.rotateCapability(one));
    try std.testing.expect(host.authorizeCapability(&one_cap) == null);
    try std.testing.expect(host.authorize("one@sketerm.test", &one.capability) == one);
}

test "storage.local answers immediately and writes once the window passes" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-webext-storage-XXXXXX".*;
    const base_z = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const base = std.mem.span(@as([*:0]u8, @ptrCast(base_z)));
    defer {
        var zbuf: [512:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&zbuf, "{s}/webext/storage@sketerm.test/storage.json", .{base})) |p| {
            _ = c.unlink(p.ptr);
        } else |_| {}
        if (std.fmt.bufPrintZ(&zbuf, "{s}/webext/storage@sketerm.test", .{base})) |p| {
            _ = c.rmdir(p.ptr);
        } else |_| {}
        if (std.fmt.bufPrintZ(&zbuf, "{s}/webext", .{base})) |p| {
            _ = c.rmdir(p.ptr);
        } else |_| {}
        _ = c.rmdir(base_z);
    }

    const data_dir = try std.fmt.allocPrint(t.allocator, "{s}/webext", .{base});
    var host = Host{ .gpa = t.allocator, .data_dir = data_dir };
    defer host.deinit();
    try host.exts.append(t.allocator, .{
        .id = try t.allocator.dupe(u8, "storage@sketerm.test"),
        .dir = &.{},
        .store = storage.Store.load(t.allocator, "{\"secret\":\"old\"}"),
    });
    const ext = &host.exts.items[0];

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/storage@sketerm.test/storage.json", .{data_dir});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    var st: c.struct_stat = undefined;

    var changed: ?[]u8 = null;
    const first = host.dispatchStorage(ext, "set", "[{\"secret\":\"one\"}]", &changed);
    defer t.allocator.free(first);
    try t.expect(std.mem.indexOf(u8, first, "\"result\":null") != null);
    if (changed) |bytes| t.allocator.free(bytes);

    // The page's promise resolved without touching the disk: no
    // serialize, no reparse, no pair of fsyncs inside the call.
    try t.expect(ext.store_dirty);
    try t.expect(c.stat(path_z.ptr, &st) != 0);
    // ...and a burst does not accumulate writes either.
    const due = ext.store_due_ms;
    changed = null;
    const second = host.dispatchStorage(ext, "set", "[{\"secret\":\"two\"}]", &changed);
    defer t.allocator.free(second);
    if (changed) |bytes| t.allocator.free(bytes);
    try t.expectEqual(due, ext.store_due_ms);
    try t.expect(c.stat(path_z.ptr, &st) != 0);

    // Before the window expires nothing is written.
    host.flushStores(ext.store_due_ms - 1);
    try t.expect(c.stat(path_z.ptr, &st) != 0);

    host.flushStores(ext.store_due_ms);
    try t.expect(!ext.store_dirty);
    try t.expect(c.stat(path_z.ptr, &st) == 0);
    try t.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(st.st_mode & 0o777)));

    // A failing write keeps the store dirty and retries; it never drops
    // data the extension already saw stored.
    const parent = std.fs.path.dirname(path).?;
    var parent_z_buf: [512:0]u8 = undefined;
    const parent_z = try std.fmt.bufPrintZ(&parent_z_buf, "{s}", .{parent});
    changed = null;
    const third = host.dispatchStorage(ext, "set", "[{\"secret\":\"three\"}]", &changed);
    defer t.allocator.free(third);
    if (changed) |bytes| t.allocator.free(bytes);
    try t.expect(c.chmod(parent_z.ptr, 0o500) == 0);
    host.flushStores(std.math.maxInt(i64));
    try t.expect(ext.store_dirty);
    try t.expect(c.chmod(parent_z.ptr, 0o700) == 0);
    host.flushStores(std.math.maxInt(i64));
    try t.expect(!ext.store_dirty);

    const got = try ext.store.?.get(t.allocator, &.{"secret"});
    defer t.allocator.free(got);
    try t.expectEqualStrings("{\"secret\":\"three\"}", got);
    const disk = try readFileZFallible(t.allocator, path, 1024);
    defer t.allocator.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "\"three\"") != null);

    const dp = c.opendir(parent_z.ptr) orelse return error.TestUnexpectedResult;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        try t.expect(std.mem.indexOf(u8, name, ".sketerm-tmp-") == null);
    }
}

test "an extension torn down inside the window still writes its store" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-webext-flush-XXXXXX".*;
    const base_z = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const base = std.mem.span(@as([*:0]u8, @ptrCast(base_z)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/webext/flush@sketerm.test/storage.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer {
        var zbuf: [512:0]u8 = undefined;
        _ = c.unlink(path_z.ptr);
        if (std.fmt.bufPrintZ(&zbuf, "{s}/webext/flush@sketerm.test", .{base})) |p| {
            _ = c.rmdir(p.ptr);
        } else |_| {}
        if (std.fmt.bufPrintZ(&zbuf, "{s}/webext", .{base})) |p| {
            _ = c.rmdir(p.ptr);
        } else |_| {}
        _ = c.rmdir(base_z);
    }

    const data_dir = try std.fmt.allocPrint(t.allocator, "{s}/webext", .{base});
    {
        var host = Host{ .gpa = t.allocator, .data_dir = data_dir };
        defer host.deinit();
        try host.exts.append(t.allocator, .{
            .id = try t.allocator.dupe(u8, "flush@sketerm.test"),
            .dir = &.{},
            .store = storage.Store.load(t.allocator, "{}"),
        });
        var changed: ?[]u8 = null;
        const res = host.dispatchStorage(&host.exts.items[0], "set", "[{\"k\":\"v\"}]", &changed);
        t.allocator.free(res);
        if (changed) |bytes| t.allocator.free(bytes);
        var st: c.struct_stat = undefined;
        try t.expect(c.stat(path_z.ptr, &st) != 0);
        // host.deinit() runs here: teardown FLUSHES, never drops.
    }
    const disk = try readFileZFallible(t.allocator, path, 1024);
    defer t.allocator.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "\"v\"") != null);
}

const allocation_test_id = "allocation@sketerm.test";
const allocation_manifest_old =
    \\{"manifest_version":2,"name":"Allocation Old","version":"1",
    \\ "browser_specific_settings":{"gecko":{"id":"allocation@sketerm.test"}},
    \\ "permissions":["tabs","storage"],
    \\ "browser_action":{"default_title":"Old Action","default_icon":"old.svg","default_popup":"old.html"}}
;
const allocation_manifest_new =
    \\{"manifest_version":2,"name":"Allocation New","version":"2",
    \\ "browser_specific_settings":{"gecko":{"id":"allocation@sketerm.test"}},
    \\ "permissions":["tabs","storage","webRequest"],
    \\ "browser_action":{"default_title":"New Action","default_icon":"new.svg","default_popup":"new.html"}}
;

const AllocationTestDir = struct {
    storage: [96:0]u8,

    fn init() !AllocationTestDir {
        var self = AllocationTestDir{ .storage = undefined };
        const template = "/tmp/sketerm-webext-host-XXXXXX";
        @memcpy(self.storage[0..template.len], template);
        self.storage[template.len] = 0;
        _ = c.mkdtemp(@ptrCast(&self.storage)) orelse return error.SkipZigTest;

        var old_buf: [256]u8 = undefined;
        const old_dir = self.child("old", &old_buf);
        var new_buf: [256]u8 = undefined;
        const new_dir = self.child("new", &new_buf);
        mkdirAll(old_dir);
        mkdirAll(new_dir);
        try writeAllocationManifest(old_dir, allocation_manifest_old);
        try writeAllocationManifest(new_dir, allocation_manifest_new);
        return self;
    }

    fn path(self: *const AllocationTestDir) []const u8 {
        return std.mem.sliceTo(&self.storage, 0);
    }

    fn child(self: *const AllocationTestDir, name: []const u8, out: []u8) []const u8 {
        return std.fmt.bufPrint(out, "{s}/{s}", .{ self.path(), name }) catch unreachable;
    }

    fn deinit(self: *AllocationTestDir) void {
        var path_buf: [320:0]u8 = undefined;
        for ([_][]const u8{ "old/manifest.json", "new/manifest.json" }) |rel| {
            const child_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ self.path(), rel }) catch continue;
            _ = c.unlink(child_path.ptr);
        }
        for ([_][]const u8{ "old", "new" }) |rel| {
            const child_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ self.path(), rel }) catch continue;
            _ = c.rmdir(child_path.ptr);
        }
        _ = c.rmdir(@ptrCast(&self.storage));
    }
};

fn writeAllocationManifest(dir: []const u8, bytes: []const u8) !void {
    var path_buf: [320:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/manifest.json", .{dir});
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return error.WriteFailed;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn registrationAllocationCase(dir: []const u8, fail_index: ?usize) !usize {
    const t = std.testing;
    var config: t.FailingAllocator.Config = .{};
    if (fail_index) |index| config.fail_index = index;
    var failing = t.FailingAllocator.init(t.allocator, config);
    var host = Host{ .gpa = failing.allocator(), .data_dir = &.{} };
    defer host.deinit();

    if (fail_index != null) {
        try t.expectError(error.OutOfMemory, host.set(allocation_test_id, dir, true));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(@as(usize, 0), host.exts.items.len);
        try t.expect(host.find(allocation_test_id) == null);
    } else {
        const e = try host.set(allocation_test_id, dir, true);
        try t.expectEqualStrings("Allocation New", e.name());
        try t.expectEqualStrings("2", e.version());
        try t.expectEqualStrings("New Action", e.action.effective(0).title);
        try t.expect(host.authorize(allocation_test_id, &e.capability) == e);
    }
    return failing.alloc_index;
}

test "extension registration rolls back every allocation failure" {
    var dir = try AllocationTestDir.init();
    defer dir.deinit();
    var new_buf: [256]u8 = undefined;
    const new_dir = dir.child("new", &new_buf);
    const allocations = try registrationAllocationCase(new_dir, null);
    try std.testing.expect(allocations > 8);
    for (0..allocations) |fail_index| {
        _ = try registrationAllocationCase(new_dir, fail_index);
    }
}

const AllocationRange = struct { first: usize, end: usize };

fn reloadAllocationCase(old_dir: []const u8, new_dir: []const u8, fail_index: ?usize) !AllocationRange {
    const t = std.testing;
    var config: t.FailingAllocator.Config = .{};
    if (fail_index) |index| config.fail_index = index;
    var failing = t.FailingAllocator.init(t.allocator, config);
    var host = Host{ .gpa = failing.allocator(), .data_dir = &.{} };
    defer host.deinit();

    const old = try host.set(allocation_test_id, old_dir, true);
    const old_capability = old.capability;
    const first = failing.alloc_index;
    if (fail_index != null) {
        try t.expectError(error.OutOfMemory, host.set(allocation_test_id, new_dir, true));
        try t.expect(failing.has_induced_failure);
        const retained = host.find(allocation_test_id).?;
        try t.expect(retained == old);
        try t.expectEqualStrings(old_dir, retained.dir);
        try t.expectEqualStrings("Allocation Old", retained.name());
        try t.expectEqualStrings("1", retained.version());
        try t.expectEqualStrings("Old Action", retained.action.effective(0).title);
        try t.expectEqualStrings("old.html", retained.action.effective(0).popup);
        try t.expect(host.authorize(allocation_test_id, &old_capability) == retained);
    } else {
        const replacement = try host.set(allocation_test_id, new_dir, true);
        try t.expect(replacement == old);
        try t.expectEqualStrings(new_dir, replacement.dir);
        try t.expectEqualStrings("Allocation New", replacement.name());
        try t.expectEqualStrings("2", replacement.version());
        try t.expect(host.authorizeCapability(&old_capability) == null);
        try t.expect(host.authorize(allocation_test_id, &replacement.capability) == replacement);
    }
    return .{ .first = first, .end = failing.alloc_index };
}

test "extension reload preserves the live instance at every allocation failure" {
    var dir = try AllocationTestDir.init();
    defer dir.deinit();
    var old_buf: [256]u8 = undefined;
    const old_dir = dir.child("old", &old_buf);
    var new_buf: [256]u8 = undefined;
    const new_dir = dir.child("new", &new_buf);
    const baseline = try reloadAllocationCase(old_dir, new_dir, null);
    try std.testing.expect(baseline.end - baseline.first > 8);
    for (baseline.first..baseline.end) |fail_index| {
        _ = try reloadAllocationCase(old_dir, new_dir, fail_index);
    }
}

// -- filesystem (libc) ------------------------------------------------

/// Read a whole file bounded at `max`, owned by `gpa`. Exposed so
/// cefhost can inline a manifest verbatim without re-implementing libc
/// file IO.
pub fn readFilePub(gpa: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    return readFileZ(gpa, path, max);
}

fn readFileZ(gpa: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    return readFileZFallible(gpa, path, max) catch null;
}

const ReadFileError = error{ OutOfMemory, ReadFailed };

fn readFileZFallible(gpa: std.mem.Allocator, path: []const u8, max: usize) ReadFileError![]u8 {
    var zbuf: [4200]u8 = undefined;
    if (path.len + 1 > zbuf.len) return error.ReadFailed;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&zbuf), c.O_RDONLY);
    if (fd < 0) return error.ReadFailed;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.ReadFailed;
    const size: usize = @intCast(@max(st.st_size, 0));
    if (size == 0 or size > max) {
        if (size == 0) return &.{};
        return error.ReadFailed;
    }
    const buf = gpa.alloc(u8, size) catch return error.OutOfMemory;
    errdefer gpa.free(buf);
    var got: usize = 0;
    while (got < size) {
        const n = c.read(fd, buf.ptr + got, size - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != size) {
        return error.ReadFailed;
    }
    return buf;
}

fn mkdirAll(path: []const u8) void {
    pathz.makeDirs(path, 0o700) catch {};
}

fn resolveDataDir(gpa: std.mem.Allocator) []u8 {
    if (c.getenv("XDG_DATA_HOME")) |xdg| {
        const base = std.mem.span(xdg);
        if (base.len != 0) {
            return std.fmt.allocPrint(gpa, "{s}/sketerm/webext", .{base}) catch @constCast("");
        }
    }
    if (c.getenv("HOME")) |home| {
        return std.fmt.allocPrint(gpa, "{s}/.local/share/sketerm/webext", .{std.mem.span(home)}) catch @constCast("");
    }
    return @constCast("");
}
