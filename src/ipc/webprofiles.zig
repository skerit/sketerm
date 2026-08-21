//! The durable store behind headless browsing PROFILES: named,
//! persistent identity contexts the `web_*` MCP tools can open views
//! in, each with its own cookie jar and cache.
//!
//! ## Why a store at all
//!
//! The browser helper derives a persistent context's on-disk jar from
//! `{profile_dir}/contexts/{sanitized_name}-{id}` (src/web/cefhost.zig),
//! where `id` is the CLIENT-allocated `context_create.id`. The id is
//! therefore half the path: re-minting ids across MCP restarts would
//! silently hand a profile an EMPTY jar, so the ids have to be
//! persisted next to the jars they name — exactly what the GUI does for
//! its containers (src/mux/webstore.zig).
//!
//! CEF additionally requires a context's `cache_path` to be a child of
//! the helper's `root_cache_path`, so the jars cannot live anywhere but
//! under the helper's `--cache-dir`. That dir consequently moves off
//! the volatile MCP instance dir onto:
//!
//! ```
//! $XDG_STATE_HOME/sketerm/web-profiles/<instance-key>/
//! ├── lock            # flock'd for the engine's lifetime, holds the owner pid
//! ├── profiles.json   # {"v":1,"next_id":N,"profiles":[...]}
//! └── contexts/
//!     └── work-3/     # helper-created; our charset is a subset of its sanitizer's
//! ```
//!
//! `<instance-key>` is the MCP instance name (`--name work`) else
//! `anon`. It is deliberately NOT the GUI's own web cache: two CEF
//! processes must never share a `root_cache_path`.
//!
//! ## Exclusivity
//!
//! The root is process-exclusive (one CEF `root_cache_path`, one
//! owner), so `open` takes an flock on `<root>/lock` and REFUSES rather
//! than sharing. A refusal names the owning pid; the engine then keeps
//! its old volatile cache dir and answers every profile request with
//! that sentence. Named instances make the collision a non-issue.
//!
//! GTK-free and libc-only, like every other src/ipc module: it links
//! into both test roots.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const clock = @import("../util/clock.zig");

/// Longest profile name. The helper's own name buffer is 256 bytes and
/// its path buffer 1024; this plus the `open` path guard keeps both
/// inside their limits with room to spare.
pub const MAX_NAME: usize = 64;

/// Ephemeral (throwaway) context ids start here, so they can never
/// collide with a persisted one — a persisted id would otherwise be
/// able to grow into an id an in-memory jar already answers to.
pub const EPHEMERAL_BASE: u32 = 0x4000_0000;

/// Names reserved because they NAME the absence of a profile in the
/// tools' own vocabulary; accepting them would make `profile:"default"`
/// mean two different things.
const RESERVED = [_][]const u8{ "default", "none" };

/// `[a-z0-9_-]{1,64}`, not a reserved word. Deliberately narrower than
/// the helper's sanitizer: every accepted name survives it unchanged,
/// so the on-disk directory is always the name the caller typed.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME) return false;
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-';
        if (!ok) return false;
    }
    for (RESERVED) |r| {
        if (std.mem.eql(u8, name, r)) return false;
    }
    return true;
}

/// One persisted profile. `id` is what goes on the wire as
/// `context_create.id` AND into the jar path, so it never changes for a
/// live name — only `retire` drops it.
pub const Entry = struct {
    name: []u8,
    id: u32,
    created_ms: i64,
    last_used_ms: i64,
};

pub const OpenError = error{ NoStateDir, Locked, PathTooLong, Io, OutOfMemory };

/// Everything a live store can refuse. `BadName` is a caller bug (the
/// engine validates first); `Io` means the store is degraded and every
/// profile operation must fail closed.
pub const Error = error{ Io, BadName, OutOfMemory };

/// Longest `<root>` that still leaves the helper's 1024-byte path
/// buffer room for `/contexts/<name>-<id>`.
const PATH_BUDGET: usize = 1024;

fn rmTree(path: []const u8) void {
    var z_buf: [4096]u8 = undefined;
    const zpath = pathz.pathZ(&z_buf, path) catch return;
    if (c.opendir(zpath)) |dir| {
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child_buf: [4096]u8 = undefined;
            const child = std.fmt.bufPrintZ(&child_buf, "{s}/{s}", .{ path, name }) catch continue;
            // unlinkat refuses a directory (EISDIR/EPERM): recurse, then
            // drop the emptied dir with AT_REMOVEDIR.
            if (c.unlinkat(c.AT_FDCWD, child.ptr, 0) != 0) {
                rmTree(child);
                _ = c.unlinkat(c.AT_FDCWD, child.ptr, c.AT_REMOVEDIR);
            }
        }
        _ = c.closedir(dir);
    }
    _ = c.rmdir(zpath);
}

/// Recursive removal for the sibling modules' test scratch dirs; the
/// production callers go through `Store.retire`.
pub fn rmTreeForTest(path: []const u8) void {
    rmTree(path);
}

/// `$XDG_STATE_HOME`, else `$HOME/.local/state`.
fn stateBase(buf: *[4096]u8) ?[]const u8 {
    if (c.getenv("XDG_STATE_HOME")) |sh| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(sh)));
        if (s.len > 0) return s;
    }
    if (c.getenv("HOME")) |home| {
        const h = std.mem.span(@as([*:0]const u8, @ptrCast(home)));
        if (h.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/.local/state", .{h}) catch null;
    }
    return null;
}

/// An instance name as a single path component. Anything outside
/// `[a-z0-9_-]` folds to `_`, so a name can never escape the store root.
fn instanceKey(instance: ?[]const u8, buf: *[MAX_NAME]u8) []const u8 {
    const raw = instance orelse return "anon";
    if (raw.len == 0) return "anon";
    var n: usize = 0;
    for (raw) |ch| {
        if (n >= buf.len) break;
        const lower = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        const ok = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or
            lower == '_' or lower == '-';
        buf[n] = if (ok) lower else '_';
        n += 1;
    }
    if (n == 0) return "anon";
    return buf[0..n];
}

const OnDisk = struct {
    v: u32 = 1,
    next_id: u32 = 1,
    profiles: []const DiskEntry = &.{},

    const DiskEntry = struct {
        name: []const u8,
        id: u32,
        created_ms: i64 = 0,
        last_used_ms: i64 = 0,
    };
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    /// `.../web-profiles/<instance-key>`; owned.
    root: []u8,
    lock_fd: c_int = -1,
    entries: std.ArrayList(Entry) = .empty,
    next_id: u32 = 1,
    /// The contexts/ listing could not be read after profiles.json was
    /// found unusable: minting an id could collide with a jar we cannot
    /// see, so every operation refuses instead.
    degraded: bool = false,

    /// Take the store root exclusively. `holder_pid`, when given, is
    /// filled with the owning pid on `error.Locked` — the sentence a
    /// caller shows is only useful if it can name who has it.
    ///
    /// DEVIATION from the plan's `holder_pid` field: a failed open
    /// returns no Store to read the field off, so it is an out param.
    pub fn open(gpa: std.mem.Allocator, instance: ?[]const u8, holder_pid: ?*c.pid_t) OpenError!Store {
        var base_buf: [4096]u8 = undefined;
        const base = stateBase(&base_buf) orelse return error.NoStateDir;
        var key_buf: [MAX_NAME]u8 = undefined;
        const key = instanceKey(instance, &key_buf);
        const root = std.fmt.allocPrint(gpa, "{s}/sketerm/web-profiles/{s}", .{ base, key }) catch
            return error.OutOfMemory;
        errdefer gpa.free(root);
        // The helper builds `{root}/contexts/{name}-{id}` into a
        // 1024-byte buffer; refuse loudly here rather than letting
        // contextCreate silently drop the cache path (which would fall
        // back to the SHARED jar — the exact thing profiles must never do).
        if (root.len + "/contexts/".len + MAX_NAME + 12 >= PATH_BUDGET) return error.PathTooLong;

        pathz.makeDirs(root, 0o700) catch |err| return switch (err) {
            error.PathTooLong => error.PathTooLong,
            error.MkdirFailed => error.Io,
        };
        var contexts_buf: [4096]u8 = undefined;
        const contexts = std.fmt.bufPrint(&contexts_buf, "{s}/contexts", .{root}) catch return error.PathTooLong;
        pathz.makeDirs(contexts, 0o700) catch return error.Io;

        var lock_buf: [4096:0]u8 = undefined;
        const lock_path = std.fmt.bufPrintZ(&lock_buf, "{s}/lock", .{root}) catch return error.PathTooLong;
        const fd = c.open(lock_path.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return error.Io;
        errdefer _ = c.close(fd);
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
            if (holder_pid) |out| out.* = readPid(fd);
            return error.Locked;
        }
        writePid(fd);

        var self = Store{ .gpa = gpa, .root = root, .lock_fd = fd };
        self.load();
        self.sweepOrphans();
        return self;
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |e| self.gpa.free(e.name);
        self.entries.deinit(self.gpa);
        self.entries = .empty;
        if (self.lock_fd >= 0) {
            // Closing the fd releases the flock; the pid text stays as
            // the breadcrumb a later refusal reads.
            _ = c.close(self.lock_fd);
            self.lock_fd = -1;
        }
        self.gpa.free(self.root);
        self.root = &.{};
    }

    fn readPid(fd: c_int) c.pid_t {
        var buf: [64]u8 = undefined;
        const n = c.pread(fd, &buf, buf.len, 0);
        if (n <= 0) return 0;
        const text = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n\x00");
        return std.fmt.parseInt(c.pid_t, text, 10) catch 0;
    }

    fn writePid(fd: c_int) void {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}\n", .{c.getpid()}) catch return;
        _ = c.ftruncate(fd, 0);
        _ = c.pwrite(fd, text.ptr, text.len, 0);
    }

    fn jsonPath(self: *const Store, buf: *[4096]u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/profiles.json", .{self.root}) catch null;
    }

    /// Absolute path of a profile's jar directory (the helper creates
    /// it; this is how the tools can report and erase it).
    pub fn jarPath(self: *const Store, buf: *[4096]u8, e: Entry) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/contexts/{s}-{d}", .{ self.root, e.name, e.id }) catch
            error.Io;
    }

    pub fn find(self: *const Store, name: []const u8) ?Entry {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// The id `name` must be opened with, minting and persisting one on
    /// first use.
    pub fn ensure(self: *Store, name: []const u8) Error!u32 {
        if (!validName(name)) return error.BadName;
        if (self.degraded) return error.Io;
        if (self.find(name)) |e| return e.id;
        const now = clock.nowMs();
        const owned = self.gpa.dupe(u8, name) catch return error.OutOfMemory;
        errdefer self.gpa.free(owned);
        const id = self.mintId();
        self.entries.append(self.gpa, .{
            .name = owned,
            .id = id,
            .created_ms = now,
            .last_used_ms = now,
        }) catch return error.OutOfMemory;
        self.save() catch |err| {
            // An id nobody can persist would be re-minted next boot and
            // point at a different jar: refuse now instead.
            const dropped = self.entries.pop().?;
            self.gpa.free(dropped.name);
            return err;
        };
        return id;
    }

    /// The next free id: past every live entry AND past every directory
    /// already sitting in contexts/, so a partially-recovered store can
    /// never hand profile A the jar profile B left behind.
    fn mintId(self: *Store) u32 {
        var id = self.next_id;
        while (true) {
            var taken = false;
            for (self.entries.items) |e| {
                if (e.id == id) taken = true;
            }
            if (!taken and !self.jarDirExistsForId(id)) break;
            id += 1;
        }
        self.next_id = id + 1;
        return id;
    }

    fn jarDirExistsForId(self: *const Store, id: u32) bool {
        var buf: [4096:0]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&buf, "{s}/contexts", .{self.root}) catch return false;
        const dir = c.opendir(dir_z.ptr) orelse return false;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            const split = splitJarDir(name) orelse continue;
            if (split.id == id) return true;
        }
        return false;
    }

    /// Note the profile was used; best-effort persistence (a failed
    /// write costs an accurate timestamp, never the profile).
    pub fn touch(self: *Store, name: []const u8, now_ms: i64) void {
        for (self.entries.items) |*e| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            e.last_used_ms = now_ms;
            self.save() catch {};
            return;
        }
    }

    /// Erase a profile: drop the entry (so the next use mints a FRESH
    /// id, hence a fresh directory — a half-failed rmtree can never
    /// resurface as "that profile's cookies") and remove its jar.
    /// @return false when the name was not known.
    pub fn retire(self: *Store, name: []const u8) Error!bool {
        if (self.degraded) return error.Io;
        for (self.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            var buf: [4096]u8 = undefined;
            const jar = self.jarPath(&buf, e) catch "";
            _ = self.entries.orderedRemove(i);
            // Save BEFORE the rmtree: a crash between the two leaves an
            // orphan dir, which sweepOrphans collects. The reverse order
            // would leave an entry pointing at nothing.
            const saved = self.save();
            if (jar.len > 0) rmTree(jar);
            self.gpa.free(e.name);
            try saved;
            return true;
        }
        return false;
    }

    pub fn list(self: *const Store) []const Entry {
        return self.entries.items;
    }

    /// Delete `contexts/*` directories no entry claims — the SIGKILL
    /// window between a retire's save and its rmtree.
    pub fn sweepOrphans(self: *Store) void {
        if (self.degraded) return;
        var buf: [4096:0]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&buf, "{s}/contexts", .{self.root}) catch return;
        const dir = c.opendir(dir_z.ptr) orelse return;
        // Collect first: unlinking while the DIR stream is open is
        // implementation-defined.
        var doomed: std.ArrayList([]u8) = .empty;
        defer {
            for (doomed.items) |p| self.gpa.free(p);
            doomed.deinit(self.gpa);
        }
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const split = splitJarDir(name) orelse continue;
            var claimed = false;
            for (self.entries.items) |e| {
                if (e.id == split.id and std.mem.eql(u8, e.name, split.name)) claimed = true;
            }
            if (claimed) continue;
            const path = std.fmt.allocPrint(self.gpa, "{s}/contexts/{s}", .{ self.root, name }) catch continue;
            doomed.append(self.gpa, path) catch {
                self.gpa.free(path);
                continue;
            };
        }
        _ = c.closedir(dir);
        for (doomed.items) |p| rmTree(p);
    }

    fn save(self: *Store) Error!void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.print("{{\"v\":1,\"next_id\":{d},\"profiles\":[", .{self.next_id}) catch return error.OutOfMemory;
        for (self.entries.items, 0..) |e, i| {
            if (i != 0) w.writeAll(",") catch return error.OutOfMemory;
            w.writeAll("{\"name\":") catch return error.OutOfMemory;
            std.json.Stringify.value(e.name, .{}, w) catch return error.OutOfMemory;
            w.print(",\"id\":{d},\"created_ms\":{d},\"last_used_ms\":{d}}}", .{
                e.id, e.created_ms, e.last_used_ms,
            }) catch return error.OutOfMemory;
        }
        w.writeAll("]}\n") catch return error.OutOfMemory;
        var path_buf: [4096]u8 = undefined;
        const path = self.jsonPath(&path_buf) orelse return error.Io;
        atomicwrite.writeFileExact(path, aw.written(), 0o600) catch return error.Io;
    }

    /// Read profiles.json; on anything unusable, rebuild from the
    /// directory listing rather than starting empty (starting empty
    /// would mint id 1 straight onto an existing jar).
    fn load(self: *Store) void {
        var path_buf: [4096]u8 = undefined;
        const path = self.jsonPath(&path_buf) orelse {
            self.degraded = true;
            return;
        };
        var z_buf: [4096:0]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&z_buf, "{s}", .{path}) catch {
            self.degraded = true;
            return;
        };
        const f = c.fopen(path_z.ptr, "rb") orelse return self.rebuild();
        defer _ = c.fclose(f);
        var raw: [256 * 1024]u8 = undefined;
        const n = c.fread(&raw, 1, raw.len, f);
        const parsed = std.json.parseFromSlice(OnDisk, self.gpa, raw[0..n], .{
            .ignore_unknown_fields = true,
        }) catch return self.rebuild();
        defer parsed.deinit();
        if (parsed.value.v != 1) return self.rebuild();
        var highest: u32 = 0;
        for (parsed.value.profiles) |p| {
            if (!validName(p.name) or p.id == 0 or p.id >= EPHEMERAL_BASE) continue;
            if (self.find(p.name) != null) continue;
            const owned = self.gpa.dupe(u8, p.name) catch continue;
            self.entries.append(self.gpa, .{
                .name = owned,
                .id = p.id,
                .created_ms = p.created_ms,
                .last_used_ms = p.last_used_ms,
            }) catch {
                self.gpa.free(owned);
                continue;
            };
            if (p.id > highest) highest = p.id;
        }
        self.next_id = @max(parsed.value.next_id, highest + 1);
        if (self.next_id == 0) self.next_id = 1;
    }

    /// Reconstruct the table from `contexts/<name>-<id>` directories.
    fn rebuild(self: *Store) void {
        for (self.entries.items) |e| self.gpa.free(e.name);
        self.entries.clearRetainingCapacity();
        var buf: [4096:0]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&buf, "{s}/contexts", .{self.root}) catch {
            self.degraded = true;
            return;
        };
        const dir = c.opendir(dir_z.ptr) orelse {
            // No listing AND no usable json: minting could collide with
            // a jar nobody can see. Refuse every profile op instead.
            self.degraded = true;
            return;
        };
        defer _ = c.closedir(dir);
        const now = clock.nowMs();
        var highest: u32 = 0;
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            const split = splitJarDir(name) orelse continue;
            if (split.id > highest) highest = split.id;
            if (self.find(split.name) != null) continue;
            const owned = self.gpa.dupe(u8, split.name) catch continue;
            self.entries.append(self.gpa, .{
                .name = owned,
                .id = split.id,
                .created_ms = now,
                .last_used_ms = now,
            }) catch {
                self.gpa.free(owned);
                continue;
            };
        }
        self.next_id = highest + 1;
        // Best effort: a rebuilt table that cannot be written is still
        // correct in memory, and the next rebuild reproduces it.
        self.save() catch {};
    }
};

const JarDir = struct { name: []const u8, id: u32 };

/// Split a `contexts/` entry back into the (name, id) it was built
/// from. Anything that does not parse is not ours and is left alone.
fn splitJarDir(dir_name: []const u8) ?JarDir {
    const dash = std.mem.lastIndexOfScalar(u8, dir_name, '-') orelse return null;
    if (dash == 0 or dash + 1 >= dir_name.len) return null;
    const id = std.fmt.parseInt(u32, dir_name[dash + 1 ..], 10) catch return null;
    if (id == 0 or id >= EPHEMERAL_BASE) return null;
    const name = dir_name[0..dash];
    if (!validName(name)) return null;
    return .{ .name = name, .id = id };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// A scratch $XDG_STATE_HOME so a test never touches the developer's.
const ScratchState = struct {
    tmpl: [64]u8 = undefined,
    dir: []const u8 = "",
    saved: ?[]const u8 = null,
    saved_buf: [4096]u8 = undefined,

    fn init(self: *ScratchState) !void {
        @memcpy(self.tmpl[0.."/tmp/sketerm-webprofiles-XXXXXX".len], "/tmp/sketerm-webprofiles-XXXXXX");
        self.tmpl["/tmp/sketerm-webprofiles-XXXXXX".len] = 0;
        const made = c.mkdtemp(@ptrCast(&self.tmpl)) orelse return error.SkipZigTest;
        self.dir = std.mem.span(@as([*:0]u8, @ptrCast(made)));
        if (c.getenv("XDG_STATE_HOME")) |old| {
            const s = std.mem.span(@as([*:0]const u8, @ptrCast(old)));
            @memcpy(self.saved_buf[0..s.len], s);
            self.saved_buf[s.len] = 0;
            self.saved = self.saved_buf[0..s.len];
        }
        _ = c.setenv("XDG_STATE_HOME", @ptrCast(&self.tmpl), 1);
    }

    fn deinit(self: *ScratchState) void {
        if (self.saved) |_| {
            _ = c.setenv("XDG_STATE_HOME", @ptrCast(&self.saved_buf), 1);
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
        rmTree(self.dir);
    }
};

fn dirExists(path: []const u8) bool {
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return false;
    var st: c.struct_stat = undefined;
    return c.stat(p.ptr, &st) == 0 and (st.st_mode & c.S_IFDIR) != 0;
}

fn makeJar(store: *const Store, name: []const u8, id: u32) !void {
    var buf: [4096]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "{s}/contexts/{s}-{d}", .{ store.root, name, id });
    try pathz.makeDirs(p, 0o700);
}

test "validName accepts what the helper's sanitizer leaves untouched" {
    const t = std.testing;
    try t.expect(validName("work"));
    try t.expect(validName("work-2_a"));
    try t.expect(!validName(""));
    try t.expect(!validName("Work")); // uppercase would fold, changing the path
    try t.expect(!validName("a b"));
    try t.expect(!validName("../escape"));
    try t.expect(!validName("dots.are.out"));
    // Reserved: these NAME the absence of a profile in the tool vocabulary.
    try t.expect(!validName("default"));
    try t.expect(!validName("none"));
    const too_long = [_]u8{'a'} ** (MAX_NAME + 1);
    try t.expect(!validName(&too_long));
    try t.expect(validName(too_long[0..MAX_NAME]));
}

test "a profile's id survives the store being closed and reopened" {
    const gpa = std.testing.allocator;
    var scratch = ScratchState{};
    scratch.init() catch return error.SkipZigTest;
    defer scratch.deinit();

    var first = try Store.open(gpa, "unit", null);
    const id = try first.ensure("work");
    // The same name never mints twice: the id is half the jar path.
    try std.testing.expectEqual(id, try first.ensure("work"));
    const other = try first.ensure("shop");
    try std.testing.expect(other != id);
    first.touch("work", 1234);
    first.deinit();

    // A whole MCP restart: the ids come back, so the jars do too.
    var second = try Store.open(gpa, "unit", null);
    defer second.deinit();
    try std.testing.expectEqual(id, try second.ensure("work"));
    try std.testing.expectEqual(other, try second.ensure("shop"));
    try std.testing.expectEqual(@as(i64, 1234), second.find("work").?.last_used_ms);

    // And the jar path is the (name, id) pair, verbatim.
    var buf: [4096]u8 = undefined;
    const jar = try second.jarPath(&buf, second.find("work").?);
    try std.testing.expect(std.mem.endsWith(u8, jar, "/contexts/work-1"));

    try std.testing.expectError(error.BadName, second.ensure("default"));
}

test "a second store on the same root is refused, naming the owner" {
    const gpa = std.testing.allocator;
    var scratch = ScratchState{};
    scratch.init() catch return error.SkipZigTest;
    defer scratch.deinit();

    var first = try Store.open(gpa, "unit", null);
    defer first.deinit();
    var holder: c.pid_t = 0;
    try std.testing.expectError(error.Locked, Store.open(gpa, "unit", &holder));
    try std.testing.expectEqual(c.getpid(), holder);

    // A DIFFERENT instance key is a different root, so it is free.
    var other = try Store.open(gpa, "other", null);
    other.deinit();
}

test "a corrupt profiles.json is rebuilt from the jars on disk" {
    const gpa = std.testing.allocator;
    var scratch = ScratchState{};
    scratch.init() catch return error.SkipZigTest;
    defer scratch.deinit();

    var seed = try Store.open(gpa, "unit", null);
    _ = try seed.ensure("work");
    const shop_id = try seed.ensure("shop");
    try makeJar(&seed, "work", 1);
    try makeJar(&seed, "shop", shop_id);
    var json_buf: [4096]u8 = undefined;
    const json_path = try std.fmt.bufPrint(&json_buf, "{s}/profiles.json", .{seed.root});
    seed.deinit();
    try atomicwrite.writeFileExact(json_path, "{ this is not json", 0o600);

    var rebuilt = try Store.open(gpa, "unit", null);
    defer rebuilt.deinit();
    // Both jars are recovered with the ids their DIRECTORIES carry...
    try std.testing.expectEqual(@as(u32, 1), rebuilt.find("work").?.id);
    try std.testing.expectEqual(shop_id, rebuilt.find("shop").?.id);
    // ...and a new profile never lands on an id a directory already owns.
    const fresh = try rebuilt.ensure("news");
    try std.testing.expect(fresh > shop_id);
    // The rebuild must not have swept the jars it just recovered.
    var p: [4096]u8 = undefined;
    try std.testing.expect(dirExists(try rebuilt.jarPath(&p, rebuilt.find("work").?)));
}

test "retire erases the jar and the next use gets a brand-new one" {
    const gpa = std.testing.allocator;
    var scratch = ScratchState{};
    scratch.init() catch return error.SkipZigTest;
    defer scratch.deinit();

    var store = try Store.open(gpa, "unit", null);
    defer store.deinit();
    const id = try store.ensure("work");
    try makeJar(&store, "work", id);
    var buf: [4096]u8 = undefined;
    const jar = try gpa.dupe(u8, try store.jarPath(&buf, store.find("work").?));
    defer gpa.free(jar);
    try std.testing.expect(dirExists(jar));

    try std.testing.expect(try store.retire("work"));
    try std.testing.expect(!dirExists(jar));
    try std.testing.expect(store.find("work") == null);
    try std.testing.expect(!try store.retire("work"));

    // The name stays usable, but on a DIFFERENT id — so even a
    // half-failed rmtree can never resurface as this profile's cookies.
    const again = try store.ensure("work");
    try std.testing.expect(again != id);
}

test "orphan jars left by a crash are swept at open" {
    const gpa = std.testing.allocator;
    var scratch = ScratchState{};
    scratch.init() catch return error.SkipZigTest;
    defer scratch.deinit();

    var store = try Store.open(gpa, "unit", null);
    const kept = try store.ensure("work");
    try makeJar(&store, "work", kept);
    // The SIGKILL window: profiles.json already dropped "gone", its jar
    // did not go with it.
    try makeJar(&store, "gone", 99);
    var orphan_buf: [4096]u8 = undefined;
    const orphan = try gpa.dupe(u8, try std.fmt.bufPrint(&orphan_buf, "{s}/contexts/gone-99", .{store.root}));
    defer gpa.free(orphan);
    var kept_buf: [4096]u8 = undefined;
    const kept_path = try gpa.dupe(u8, try store.jarPath(&kept_buf, store.find("work").?));
    defer gpa.free(kept_path);
    store.deinit();

    var reopened = try Store.open(gpa, "unit", null);
    defer reopened.deinit();
    try std.testing.expect(!dirExists(orphan));
    try std.testing.expect(dirExists(kept_path));
}

test "splitJarDir only claims directories this store could have made" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 3), splitJarDir("work-3").?.id);
    try t.expectEqualStrings("work", splitJarDir("work-3").?.name);
    try t.expectEqualStrings("a-b", splitJarDir("a-b-7").?.name);
    try t.expect(splitJarDir("noid") == null);
    try t.expect(splitJarDir("-7") == null);
    try t.expect(splitJarDir("work-0") == null);
    try t.expect(splitJarDir("Work-3") == null);
    // Ephemeral ids never touch disk, so a dir claiming one is not ours.
    try t.expect(splitJarDir("work-1073741824") == null);
}
