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

    pub fn init(gpa: std.mem.Allocator) Host {
        return .{ .gpa = gpa, .data_dir = resolveDataDir(gpa) };
    }

    pub fn deinit(self: *Host) void {
        for (self.exts.items) |*e| self.freeExt(e);
        self.exts.deinit(self.gpa);
        self.gpa.free(self.data_dir);
    }

    fn freeExt(self: *Host, e: *Extension) void {
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

    fn reparse(self: *Host, e: *Extension) void {
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
        return self.errResult("unknown namespace");
    }

    fn dispatchStorage(self: *Host, e: *Extension, method: []const u8, args_json: []const u8, changed: *?[]u8) []u8 {
        const s = self.storeFor(e);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, args_json, .{}) catch
            return self.errResult("bad args");
        defer parsed.deinit();
        const args = if (parsed.value == .array) parsed.value.array.items else &[_]std.json.Value{};

        if (std.mem.eql(u8, method, "get")) {
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
        if (!std.mem.eql(u8, method, "getMessage")) return self.errResult("unknown i18n method");
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, args_json, .{}) catch
            return self.errResult("bad args");
        defer parsed.deinit();
        const args = if (parsed.value == .array) parsed.value.array.items else &[_]std.json.Value{};
        if (args.len == 0 or args[0] != .string) return self.gpa.dupe(u8, "{\"result\":\"\"}") catch self.errResult("oom");
        const key = args[0].string;
        const msg = self.lookupMessage(e, key) orelse return self.gpa.dupe(u8, "{\"result\":\"\"}") catch self.errResult("oom");
        defer self.gpa.free(msg);
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        aw.writer.writeAll("{\"result\":") catch return self.errResult("oom");
        std.json.Stringify.value(msg, .{}, &aw.writer) catch return self.errResult("oom");
        aw.writer.writeByte('}') catch return self.errResult("oom");
        return aw.toOwnedSlice() catch self.errResult("oom");
    }

    /// `_locales/<default_locale>/messages.json` -> the `message` field
    /// of `key`. Minimal: no substitutions, no locale negotiation.
    fn lookupMessage(self: *Host, e: *Extension, key: []const u8) ?[]u8 {
        const m = if (e.man) |*mm| mm else return null;
        const locale = m.default_locale orelse return null;
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
        return self.gpa.dupe(u8, msg.string) catch null;
    }

    /// Minimal `browser.tabs`: query returns an empty list here (the GUI
    /// owns the real tab set; a later wave forwards it over the wire),
    /// and get/sendMessage answer benignly. Kept so an extension that
    /// probes tabs does not throw.
    fn dispatchTabs(self: *Host, e: *Extension, method: []const u8, _: []const u8) []u8 {
        _ = e;
        if (std.mem.eql(u8, method, "query")) return self.gpa.dupe(u8, "{\"result\":[]}") catch self.errResult("oom");
        if (std.mem.eql(u8, method, "get")) return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
        if (std.mem.eql(u8, method, "sendMessage")) return self.gpa.dupe(u8, "{\"result\":null}") catch self.errResult("oom");
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
