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

    fn name(self: *const Extension) []const u8 {
        return if (self.man) |*m| m.name else "";
    }
    fn version(self: *const Extension) []const u8 {
        return if (self.man) |*m| m.version else "";
    }
};

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
        for (self.exts.items) |*e| self.freeExt(e);
        self.exts.deinit(self.gpa);
        self.tabs.deinit(self.gpa);
        self.gpa.free(self.data_dir);
    }

    fn freeExt(self: *Host, e: *Extension) void {
        // ORDER IS THE SAFETY PROPERTY: the slot must leave the
        // published table before the registry it points at is freed, or
        // the engine's IO thread can read a dangling pointer.
        webrequest.unpublish(e.id);
        if (e.wreq) |r| {
            r.deinit(self.gpa);
            self.gpa.destroy(r);
            e.wreq = null;
        }
        self.gpa.free(e.id);
        self.gpa.free(e.dir);
        if (e.err.len != 0) self.gpa.free(e.err);
        if (e.man) |*m| m.deinit();
        if (e.store) |*s| s.deinit();
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
        var e = self.find(id) orelse blk: {
            try self.exts.append(self.gpa, .{
                .id = try self.gpa.dupe(u8, id),
                .dir = try self.gpa.dupe(u8, dir),
            });
            break :blk &self.exts.items[self.exts.items.len - 1];
        };
        // A changed dir re-points the record.
        if (!std.mem.eql(u8, e.dir, dir)) {
            self.gpa.free(e.dir);
            e.dir = try self.gpa.dupe(u8, dir);
        }
        e.enabled = enabled;
        self.reparse(e);
        return e;
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

    fn reparse(self: *Host, e: *Extension) void {
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
        if (e.err.len != 0) {
            self.gpa.free(e.err);
            e.err = &.{};
        }
        e.ok = false;
        var path_buf: [4096]u8 = undefined;
        const mpath = std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{e.dir}) catch {
            e.err = self.gpa.dupe(u8, "path too long") catch &.{};
            return;
        };
        const bytes = readFileZ(self.gpa, mpath, 4 * 1024 * 1024) orelse {
            e.err = self.gpa.dupe(u8, "manifest.json not readable") catch &.{};
            return;
        };
        defer self.gpa.free(bytes);
        const m = manifest.parse(self.gpa, bytes) catch |err| {
            e.err = std.fmt.allocPrint(self.gpa, "manifest parse: {s}", .{@errorName(err)}) catch &.{};
            return;
        };
        e.man = m;
        e.ok = true;
    }

    pub fn remove(self: *Host, id: []const u8) void {
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

    fn persist(self: *Host, e: *Extension) void {
        if (self.data_dir.len == 0) return;
        const s = self.storeFor(e);
        const bytes = s.serialize(self.gpa) catch return;
        defer self.gpa.free(bytes);
        var dir_buf: [4096]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ self.data_dir, e.id }) catch return;
        mkdirAll(dir);
        var path_buf: [4200]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/storage.json", .{dir}) catch return;
        writeFileZ(path, bytes);
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
            const lid: u32 = @intCast(@max(args[0].integer, 0));
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
        const lid: u32 = @intCast(@max(args[1].integer, 0));

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
        } else if (std.mem.eql(u8, method, "set")) {
            const patch = if (args.len > 0) self.valueToJson(args[0]) else self.gpa.dupe(u8, "{}") catch null;
            defer if (patch) |p| self.gpa.free(p);
            const ch = s.set(self.gpa, patch orelse "{}") catch return self.errResult("oom");
            if (!std.mem.eql(u8, ch, "{}")) {
                self.persist(e);
                changed.* = ch;
            } else self.gpa.free(ch);
            return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
        } else if (std.mem.eql(u8, method, "remove")) {
            const keys = self.keysFromArg(if (args.len > 0) args[0] else .null) catch return self.errResult("oom");
            defer self.gpa.free(keys);
            const ch = s.remove(self.gpa, keys) catch return self.errResult("oom");
            if (!std.mem.eql(u8, ch, "{}")) {
                self.persist(e);
                changed.* = ch;
            } else self.gpa.free(ch);
            return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
        } else if (std.mem.eql(u8, method, "clear")) {
            const ch = s.clear(self.gpa) catch return self.errResult("oom");
            if (!std.mem.eql(u8, ch, "{}")) {
                self.persist(e);
                changed.* = ch;
            } else self.gpa.free(ch);
            return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
        }
        return self.errResult("unknown storage method");
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
        if (std.mem.eql(u8, method, "getUILanguage")) {
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            aw.writer.writeAll("{\"result\":") catch return self.errResult("oom");
            std.json.Stringify.value(uiLanguage(), .{}, &aw.writer) catch return self.errResult("oom");
            aw.writer.writeByte('}') catch return self.errResult("oom");
            return aw.toOwnedSlice() catch self.errResult("oom");
        }
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
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        aw.writer.writeAll("{\"result\":") catch return self.errResult("oom");
        std.json.Stringify.value(msg, .{}, &aw.writer) catch return self.errResult("oom");
        aw.writer.writeByte('}') catch return self.errResult("oom");
        return aw.toOwnedSlice() catch self.errResult("oom");
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
            const tb = self.tabs.find(@intCast(@max(args[0].integer, 0))) orelse
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

    fn valueToJson(self: *Host, v: std.json.Value) ?[]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        std.json.Stringify.value(v, .{}, &aw.writer) catch return null;
        return aw.toOwnedSlice() catch null;
    }

    /// Wrap a raw JSON value string as `{"result":<value>}`.
    fn wrapResult(self: *Host, value_json: []const u8) []u8 {
        return std.fmt.allocPrint(self.gpa, "{{\"result\":{s}}}", .{value_json}) catch self.errResult("oom");
    }

    /// Every dispatch result is heap-owned so the caller frees uniformly;
    /// a 20-byte print cannot realistically OOM in ReleaseFast.
    fn errResult(self: *Host, msg: []const u8) []u8 {
        return std.fmt.allocPrint(self.gpa, "{{\"error\":\"{s}\"}}", .{msg}) catch unreachable;
    }
};

// -- filesystem (libc) ------------------------------------------------

/// Read a whole file bounded at `max`, owned by `gpa`. Exposed so
/// cefhost can inline a manifest verbatim without re-implementing libc
/// file IO.
pub fn readFilePub(gpa: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    return readFileZ(gpa, path, max);
}

fn readFileZ(gpa: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    var zbuf: [4200]u8 = undefined;
    if (path.len + 1 > zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&zbuf), c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return null;
    const size: usize = @intCast(@max(st.st_size, 0));
    if (size == 0 or size > max) {
        if (size == 0) return gpa.alloc(u8, 0) catch null;
        return null;
    }
    const buf = gpa.alloc(u8, size) catch return null;
    errdefer gpa.free(buf);
    var got: usize = 0;
    while (got < size) {
        const n = c.read(fd, buf.ptr + got, size - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != size) {
        gpa.free(buf);
        return null;
    }
    return buf;
}

fn writeFileZ(path: [*:0]const u8, bytes: []const u8) void {
    const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn mkdirAll(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len + 1 > buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and buf[i] != '/') continue;
        const save = buf[i];
        buf[i] = 0;
        _ = c.mkdir(@ptrCast(&buf), 0o700);
        buf[i] = save;
    }
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
