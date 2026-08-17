//! `browser.storage.local` — a per-extension JSON object with
//! get/set/remove/clear and a change record, plus serialization to the
//! bytes the helper persists under the XDG data dir.
//!
//! Pure std + JSON, no CEF, no GTK, no filesystem: the store operates on
//! a JSON value tree and produces/consumes byte strings, so it is
//! unit-tested headless in both test roots. The helper owns the actual
//! file IO (a store is loaded from and saved to
//! `<data>/sketerm/webext/<id>/storage.json`).
//!
//! Values are arbitrary JSON, matching the web API: a page stores
//! numbers, strings, arrays and objects, and gets them back by key.

const std = @import("std");

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    /// The backing object; keys are strings, values arbitrary JSON.
    /// Unmanaged in this Zig, so `arena.allocator()` is threaded through
    /// every mutation.
    obj: std.json.ObjectMap = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    /// Load a store from previously-persisted bytes. Malformed or empty
    /// input yields an empty store rather than an error: a corrupt
    /// storage file must not brick an extension.
    pub fn load(gpa: std.mem.Allocator, bytes: []const u8) Store {
        return loadFallible(gpa, bytes) catch Store.init(gpa);
    }

    fn loadFallible(gpa: std.mem.Allocator, bytes: []const u8) !Store {
        var s = Store.init(gpa);
        errdefer s.deinit();
        const a = s.arena.allocator();
        if (bytes.len == 0) return s;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
        if (parsed != .object) return error.InvalidStorage;
        s.obj = parsed.object;
        return s;
    }

    /// Deep-copy the store so a disk-backed mutation can commit transactionally.
    pub fn clone(self: *Store, gpa: std.mem.Allocator) !Store {
        const bytes = try self.serialize(gpa);
        defer gpa.free(bytes);
        return loadFallible(gpa, bytes);
    }

    /// Serialize the whole store to a JSON object string, owned by
    /// `gpa`. This is what the helper writes to disk.
    pub fn serialize(self: *Store, gpa: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const val = std.json.Value{ .object = self.obj };
        try std.json.Stringify.value(val, .{}, &aw.writer);
        return aw.toOwnedSlice();
    }

    /// Answer a `get` for the given keys as a JSON object of the
    /// key/value pairs that exist. An empty `keys` returns EVERYTHING
    /// (the web API's `storage.local.get()` with no argument). Owned by
    /// `gpa`.
    pub fn get(self: *Store, gpa: std.mem.Allocator, keys: []const []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.writeByte('{');
        var first = true;
        if (keys.len == 0) {
            var it = self.obj.iterator();
            while (it.next()) |e| {
                try writePair(&aw.writer, &first, e.key_ptr.*, e.value_ptr.*);
            }
        } else {
            for (keys) |k| {
                if (self.obj.get(k)) |v| try writePair(&aw.writer, &first, k, v);
            }
        }
        try aw.writer.writeByte('}');
        return aw.toOwnedSlice();
    }

    /// Answer a `get` whose argument was an OBJECT: its keys are the
    /// wanted keys and its values are DEFAULTS for the ones not stored.
    ///
    /// This is the form every real extension uses on first run — uBO's
    /// whole settings bootstrap is one `get(µb.userSettings)` — and
    /// treating it as a bare key list (returning only stored keys) hands
    /// back `{}` on a fresh profile, so every default silently becomes
    /// `undefined` instead of the author's value.
    pub fn getWithDefaults(self: *Store, gpa: std.mem.Allocator, defaults: std.json.ObjectMap) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.writeByte('{');
        var first = true;
        var it = defaults.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const value = self.obj.get(key) orelse e.value_ptr.*;
            try writePair(&aw.writer, &first, key, value);
        }
        try aw.writer.writeByte('}');
        return aw.toOwnedSlice();
    }

    /// Apply a `set`: merge every key/value of the JSON object `patch`
    /// into the store. Returns a `changes` object describing what moved
    /// (`{key:{oldValue,newValue}}`), the payload `storage.onChanged`
    /// carries. Owned by `gpa`; empty object when nothing changed.
    pub fn set(self: *Store, gpa: std.mem.Allocator, patch_json: []const u8) ![]u8 {
        const a = self.arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, patch_json, .{}) catch
            return gpa.dupe(u8, "{}");
        if (parsed != .object) return gpa.dupe(u8, "{}");

        var changes = ChangeWriter.init(gpa);
        errdefer changes.deinit();
        var it = parsed.object.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const new_val = e.value_ptr.*;
            const old_val: ?std.json.Value = self.obj.get(key);
            if (old_val) |ov| {
                if (jsonEqual(ov, new_val)) continue;
            }
            // The key must be arena-owned (the parse used the arena, so
            // it already is; dupe defensively for keys that outlive it).
            const key_owned = try a.dupe(u8, key);
            try self.obj.put(a, key_owned, new_val);
            try changes.add(key, old_val, new_val);
        }
        return changes.finish();
    }

    /// Apply a `remove` of one or more keys. Returns the same
    /// `changes` shape (each removed key becomes `{oldValue}` with no
    /// `newValue`). Owned by `gpa`.
    pub fn remove(self: *Store, gpa: std.mem.Allocator, keys: []const []const u8) ![]u8 {
        var changes = ChangeWriter.init(gpa);
        errdefer changes.deinit();
        for (keys) |k| {
            if (self.obj.fetchOrderedRemove(k)) |kv| {
                try changes.add(k, kv.value, null);
            }
        }
        return changes.finish();
    }

    /// Clear the whole store; returns the `changes` for every key
    /// dropped. Owned by `gpa`.
    pub fn clear(self: *Store, gpa: std.mem.Allocator) ![]u8 {
        var changes = ChangeWriter.init(gpa);
        errdefer changes.deinit();
        var it = self.obj.iterator();
        while (it.next()) |e| {
            try changes.add(e.key_ptr.*, e.value_ptr.*, null);
        }
        self.obj.clearRetainingCapacity();
        return changes.finish();
    }
};

fn writePair(w: *std.Io.Writer, first: *bool, key: []const u8, val: std.json.Value) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(key, .{}, w);
    try w.writeByte(':');
    try std.json.Stringify.value(val, .{}, w);
}

/// Builds the `{key:{oldValue,newValue}}` object `onChanged` carries.
const ChangeWriter = struct {
    aw: std.Io.Writer.Allocating,
    first: bool = true,

    fn init(gpa: std.mem.Allocator) ChangeWriter {
        var cw = ChangeWriter{ .aw = .init(gpa) };
        cw.aw.writer.writeByte('{') catch {};
        return cw;
    }
    fn deinit(self: *ChangeWriter) void {
        self.aw.deinit();
    }
    fn add(self: *ChangeWriter, key: []const u8, old: ?std.json.Value, new: ?std.json.Value) !void {
        const w = &self.aw.writer;
        if (!self.first) try w.writeByte(',');
        self.first = false;
        try std.json.Stringify.value(key, .{}, w);
        try w.writeAll(":{");
        var wrote = false;
        if (old) |ov| {
            try w.writeAll("\"oldValue\":");
            try std.json.Stringify.value(ov, .{}, w);
            wrote = true;
        }
        if (new) |nv| {
            if (wrote) try w.writeByte(',');
            try w.writeAll("\"newValue\":");
            try std.json.Stringify.value(nv, .{}, w);
        }
        try w.writeByte('}');
    }
    fn finish(self: *ChangeWriter) ![]u8 {
        try self.aw.writer.writeByte('}');
        return self.aw.toOwnedSlice();
    }
};

/// Structural JSON equality — enough to decide whether a `set` actually
/// changed a value (so onChanged does not fire for a no-op write).
fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .number_string => |x| b == .number_string and std.mem.eql(u8, x, b.number_string),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array or b.array.items.len != x.items.len) break :blk false;
            for (x.items, b.array.items) |ai, bi| {
                if (!jsonEqual(ai, bi)) break :blk false;
            }
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object or b.object.count() != x.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const bv = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(e.value_ptr.*, bv)) break :blk false;
            }
            break :blk true;
        },
    };
}

// ─── tests ──────────────────────────────────────────────────────────

const t = std.testing;

test "set/get round-trip with typed values" {
    const gpa = t.allocator;
    var s = Store.init(gpa);
    defer s.deinit();

    const ch = try s.set(gpa, "{\"count\":3,\"name\":\"hi\",\"nested\":{\"a\":[1,2]}}");
    defer gpa.free(ch);
    // First write of every key: newValue only, no oldValue.
    try t.expect(std.mem.indexOf(u8, ch, "\"newValue\":3") != null);
    try t.expect(std.mem.indexOf(u8, ch, "oldValue") == null);

    const got = try s.get(gpa, &.{"count"});
    defer gpa.free(got);
    try t.expectEqualStrings("{\"count\":3}", got);

    const all = try s.get(gpa, &.{});
    defer gpa.free(all);
    try t.expect(std.mem.indexOf(u8, all, "\"name\":\"hi\"") != null);
    try t.expect(std.mem.indexOf(u8, all, "\"nested\"") != null);
}

test "set reports old->new and skips no-op writes" {
    const gpa = t.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    {
        const ch = try s.set(gpa, "{\"k\":1}");
        gpa.free(ch);
    }
    {
        const ch = try s.set(gpa, "{\"k\":2}");
        defer gpa.free(ch);
        try t.expect(std.mem.indexOf(u8, ch, "\"oldValue\":1") != null);
        try t.expect(std.mem.indexOf(u8, ch, "\"newValue\":2") != null);
    }
    {
        // Writing the same value again changes nothing: empty changes.
        const ch = try s.set(gpa, "{\"k\":2}");
        defer gpa.free(ch);
        try t.expectEqualStrings("{}", ch);
    }
}

test "remove and clear produce oldValue-only changes" {
    const gpa = t.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    {
        const ch = try s.set(gpa, "{\"a\":1,\"b\":2}");
        gpa.free(ch);
    }
    {
        const ch = try s.remove(gpa, &.{"a"});
        defer gpa.free(ch);
        try t.expect(std.mem.indexOf(u8, ch, "\"oldValue\":1") != null);
        try t.expect(std.mem.indexOf(u8, ch, "newValue") == null);
    }
    const got = try s.get(gpa, &.{});
    defer gpa.free(got);
    try t.expectEqualStrings("{\"b\":2}", got);
    {
        const ch = try s.clear(gpa);
        defer gpa.free(ch);
        try t.expect(std.mem.indexOf(u8, ch, "\"oldValue\":2") != null);
    }
    const empty = try s.get(gpa, &.{});
    defer gpa.free(empty);
    try t.expectEqualStrings("{}", empty);
}

test "serialize and load survive a round trip (the restart case)" {
    const gpa = t.allocator;
    var s = Store.init(gpa);
    {
        const ch = try s.set(gpa, "{\"persisted\":true,\"n\":42}");
        gpa.free(ch);
    }
    const bytes = try s.serialize(gpa);
    defer gpa.free(bytes);
    s.deinit();

    // A fresh store loaded from the bytes must see the same values —
    // this is exactly the helper-restart path the smoke stage asserts.
    var s2 = Store.load(gpa, bytes);
    defer s2.deinit();
    const got = try s2.get(gpa, &.{"n"});
    defer gpa.free(got);
    try t.expectEqualStrings("{\"n\":42}", got);
    const p = try s2.get(gpa, &.{"persisted"});
    defer gpa.free(p);
    try t.expectEqualStrings("{\"persisted\":true}", p);
}

test "clone isolates a prospective persistence transaction" {
    const gpa = t.allocator;
    var original = Store.load(gpa, "{\"value\":1}");
    defer original.deinit();
    var candidate = try original.clone(gpa);
    defer candidate.deinit();
    const changed = try candidate.set(gpa, "{\"value\":2}");
    defer gpa.free(changed);

    const before = try original.get(gpa, &.{"value"});
    defer gpa.free(before);
    const after = try candidate.get(gpa, &.{"value"});
    defer gpa.free(after);
    try t.expectEqualStrings("{\"value\":1}", before);
    try t.expectEqualStrings("{\"value\":2}", after);
}

test "load tolerates corrupt bytes" {
    const gpa = t.allocator;
    var s = Store.load(gpa, "this is not json");
    defer s.deinit();
    const got = try s.get(gpa, &.{});
    defer gpa.free(got);
    try t.expectEqualStrings("{}", got);
}

test "getWithDefaults returns the author's defaults on a fresh store" {
    const gpa = t.allocator;
    var s = Store.load(gpa, "");
    defer s.deinit();
    var defaults = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"advancedUserEnabled":false,"blockingProfiles":"11-17 11-3 11-1","maxLogged":25}
    , .{});
    defer defaults.deinit();

    // THE first-run bug: read as a bare key list, this answers `{}`.
    const bare = try s.get(gpa, &.{ "advancedUserEnabled", "maxLogged" });
    defer gpa.free(bare);
    try t.expectEqualStrings("{}", bare);

    const got = try s.getWithDefaults(gpa, defaults.value.object);
    defer gpa.free(got);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, got, .{});
    defer parsed.deinit();
    try t.expectEqual(false, parsed.value.object.get("advancedUserEnabled").?.bool);
    try t.expectEqual(@as(i64, 25), parsed.value.object.get("maxLogged").?.integer);
    try t.expectEqualStrings("11-17 11-3 11-1", parsed.value.object.get("blockingProfiles").?.string);
}

test "getWithDefaults prefers a stored value over the default" {
    const gpa = t.allocator;
    var s = Store.load(gpa, "{\"maxLogged\":9,\"extra\":1}");
    defer s.deinit();
    var defaults = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"maxLogged":25,"unset":"fallback"}
    , .{});
    defer defaults.deinit();
    const got = try s.getWithDefaults(gpa, defaults.value.object);
    defer gpa.free(got);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, got, .{});
    defer parsed.deinit();
    try t.expectEqual(@as(i64, 9), parsed.value.object.get("maxLogged").?.integer);
    try t.expectEqualStrings("fallback", parsed.value.object.get("unset").?.string);
    // A key not asked for stays out of the answer.
    try t.expect(parsed.value.object.get("extra") == null);
}
