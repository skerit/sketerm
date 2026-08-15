//! Declarative panel documents: the data layer behind the MCP "show
//! the user a UI" feature.
//!
//! The shape deliberately follows Google's A2UI protocol (v0.9.x):
//! a FLAT map of components keyed by id with id references between
//! them (LLMs patch flat maps far more reliably than deep trees), a
//! `root` id, a separate scalar `data` map, and styling by NAMED
//! class only. The agent sends declarative JSON, never code; the
//! component catalog here is the whole trusted vocabulary — there is
//! deliberately no raw-markup, no CSS-string and no script escape
//! hatch, and none may be added.
//!
//! Pure Zig + libc, NO GTK/GLib: registered in both test roots. The
//! GTK renderer (`view.zig`) consumes this model read-only.
//!
//! Image paths: components reference LOCAL files. A document is
//! persisted and re-opened later, and the authoring assistant is not
//! fully trusted, so paths are constrained structurally: absolute,
//! no `..` segment, no control bytes, bounded length. The renderer
//! only ever DECODES them as images (a bad or vanished path draws a
//! placeholder, it never errors the panel), so the residual exposure
//! is "display a user-readable file as pixels" — the same class of
//! access the assistant's own file tools already have. Callers that
//! scope panels to a session may additionally root-restrict paths;
//! that policy belongs to the MCP layer, not here.

const std = @import("std");

pub const events = @import("events.zig");

// ─── limits ─────────────────────────────────────────────────────

pub const MAX_COMPONENTS: usize = 512;
pub const MAX_CHILDREN: usize = 128;
pub const MAX_TEXT: usize = 4096;
pub const MAX_PATH: usize = 1024;
pub const MAX_ID: usize = events.MAX_ID; // 64
pub const MAX_OPTIONS: usize = 64;
/// Select options and button actions ride in fixed-size event
/// payloads and retain their original compact bound.
pub const MAX_OPTION: usize = events.MAX_SHORT_TEXT; // 128
pub const MAX_CLASSES: usize = 8;
pub const MAX_DATA_KEYS: usize = 64;
pub const MAX_DEPTH: usize = 32;
pub const MAX_PATCH_OPS: usize = 256;
pub const MAX_JSON_BYTES: usize = 1 << 20;
pub const MAX_SCENE_SIZE: i64 = 4096;
/// Coordinates are intentionally wider than the logical canvas so
/// partially off-scene placements remain useful without accepting
/// arbitrary JSON integer magnitudes.
pub const MAX_SCENE_COORD: i64 = 1 << 20;

/// The style vocabulary. Named classes only — each maps to a
/// pre-approved rendering (mostly Adwaita style classes); unknown
/// names are rejected at parse time so the caller gets feedback
/// instead of silence.
pub const CLASSES = [_][]const u8{
    "dim",  "accent",    "success", "warning", "error",
    "card", "monospace", "center",  "end",     "expand",
};

pub const Error = error{
    Malformed,
    UnknownComponent,
    BadId,
    BadRef,
    Cycle,
    TooBig,
    BadValue,
    NoRoot,
    OutOfMemory,
};

/// Human-readable detail for the last parse/patch failure, for the
/// MCP layer to hand back to the agent. Fixed buffer, no allocation.
pub const Diag = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn msg(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&self.buf, fmt, args) catch {
            self.len = self.buf.len;
            return;
        };
        self.len = out.len;
    }
};

fn diagSet(diag: ?*Diag, comptime fmt: []const u8, args: anytype) void {
    if (diag) |d| d.set(fmt, args);
}

// ─── catalog ────────────────────────────────────────────────────
//
// Deliberately small. What made the cut and why:
// - column/row/scene: flowing and fixed-position layout primitives.
// - heading/text: static content; heading levels map to Adwaita
//   title-1..4.
// - image + image_compare: static media and interactive comparison.
// - button/slider/select/text_input: compact interaction primitives.
// - progress/separator/spacer: cheap, high-value layout polish for
//   live dashboards.
// Dropped for now: checkbox (a two-option select covers it), table/list
// (a column of rows covers small sets; a virtualized table is later).

pub const Kind = enum {
    column,
    row,
    heading,
    text,
    image,
    image_compare,
    button,
    slider,
    select,
    progress,
    separator,
    spacer,
    scene,
    text_input,

    pub fn isContainer(self: Kind) bool {
        return self == .column or self == .row or self == .scene;
    }
};

pub const Side = struct {
    src: []u8,
    label: []u8, // may be empty
};

pub const Props = union(Kind) {
    column: Container,
    row: Container,
    heading: Heading,
    text: Text,
    image: Image,
    image_compare: ImageCompare,
    button: Button,
    slider: Slider,
    select: Select,
    progress: Progress,
    separator: void,
    spacer: Spacer,
    scene: Scene,
    text_input: TextInput,

    pub const Container = struct { children: [][]u8 };
    pub const Placement = struct {
        id: []u8,
        x: i32,
        y: i32,
        width: u16,
        height: u16,
    };
    pub const Scene = struct { width: u16, height: u16, children: []Placement };
    pub const Heading = struct { text: []u8, level: u8 }; // 1..4
    pub const Text = struct { text: []u8 };
    pub const Image = struct { src: []u8, caption: []u8 };
    pub const ImageCompare = struct { left: Side, right: Side };
    pub const Button = struct { text: []u8, action: []u8 };
    pub const Slider = struct { min: f64, max: f64, step: f64, value: f64 };
    pub const Select = struct { options: [][]u8, value: []u8 };
    pub const Progress = struct { value: f64, label: []u8, indeterminate: bool };
    pub const Spacer = struct { size: u16 }; // 0 = expand
    pub const TextInput = struct { value: []u8, placeholder: []u8, clear_on_submit: bool };
};

pub const Component = struct {
    props: Props,
    classes: [][]u8,

    pub fn kind(self: *const Component) Kind {
        return std.meta.activeTag(self.props);
    }
};

pub const DataValue = union(enum) {
    number: f64,
    boolean: bool,
    text: []u8,
};

// ─── validation helpers ─────────────────────────────────────────

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_ID) return false;
    switch (id[0]) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    }
    for (id) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

pub fn validClass(name: []const u8) bool {
    for (CLASSES) |cl| {
        if (std.mem.eql(u8, cl, name)) return true;
    }
    return false;
}

/// Absolute, bounded, no `..` segment, no control bytes. See the
/// module doc for the threat model this is (and is not) meant for.
pub fn validImagePath(path: []const u8) bool {
    if (path.len == 0 or path.len > MAX_PATH) return false;
    if (path[0] != '/') return false;
    for (path) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

fn numOf(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

// ─── document ───────────────────────────────────────────────────

pub const Document = struct {
    allocator: std.mem.Allocator,
    title: []u8,
    root: []u8,
    components: std.StringHashMapUnmanaged(Component),
    data: std.StringHashMapUnmanaged(DataValue),
    /// Bumped on every successful applyPatch; a renderer or persister
    /// can cheaply detect "something changed since I last looked".
    revision: u64 = 0,

    // ---- lifecycle ---------------------------------------------------

    /// Parse and VALIDATE a full document. On any error the partial
    /// state is freed and `diag` (when given) explains the failure.
    pub fn parse(allocator: std.mem.Allocator, json_text: []const u8, diag: ?*Diag) Error!Document {
        if (json_text.len > MAX_JSON_BYTES) {
            diagSet(diag, "document exceeds {d} bytes", .{MAX_JSON_BYTES});
            return Error.TooBig;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{}) catch {
            diagSet(diag, "not valid JSON", .{});
            return Error.Malformed;
        };
        return build(allocator, value, diag);
    }

    fn build(allocator: std.mem.Allocator, value: std.json.Value, diag: ?*Diag) Error!Document {
        const obj = switch (value) {
            .object => |o| o,
            else => {
                diagSet(diag, "document must be a JSON object", .{});
                return Error.Malformed;
            },
        };
        if (obj.get("version")) |v| {
            const ver = numOf(v) orelse 0;
            if (ver != 1) {
                diagSet(diag, "unsupported document version (want 1)", .{});
                return Error.Malformed;
            }
        }
        var self = Document{
            .allocator = allocator,
            .title = &.{},
            .root = &.{},
            .components = .empty,
            .data = .empty,
        };
        errdefer self.deinit();

        const root_v = obj.get("root") orelse {
            diagSet(diag, "missing \"root\"", .{});
            return Error.NoRoot;
        };
        const root_s = switch (root_v) {
            .string => |s| s,
            else => {
                diagSet(diag, "\"root\" must be a string id", .{});
                return Error.NoRoot;
            },
        };
        if (!validId(root_s)) {
            diagSet(diag, "invalid root id \"{s}\"", .{root_s});
            return Error.BadId;
        }
        self.root = try dupe(allocator, root_s);

        if (obj.get("title")) |tv| {
            const ts = switch (tv) {
                .string => |s| s,
                else => {
                    diagSet(diag, "\"title\" must be a string", .{});
                    return Error.BadValue;
                },
            };
            if (ts.len > MAX_TEXT) return Error.TooBig;
            self.title = try dupe(allocator, ts);
        }

        const comps_v = obj.get("components") orelse {
            diagSet(diag, "missing \"components\"", .{});
            return Error.Malformed;
        };
        const comps = switch (comps_v) {
            .object => |o| o,
            else => {
                diagSet(diag, "\"components\" must be an object", .{});
                return Error.Malformed;
            },
        };
        if (comps.count() > MAX_COMPONENTS) {
            diagSet(diag, "more than {d} components", .{MAX_COMPONENTS});
            return Error.TooBig;
        }
        var cit = comps.iterator();
        while (cit.next()) |entry| {
            const id = entry.key_ptr.*;
            if (!validId(id)) {
                diagSet(diag, "invalid component id \"{s}\"", .{id});
                return Error.BadId;
            }
            const comp = try parseComponent(allocator, id, entry.value_ptr.*, diag);
            errdefer freeComponent(allocator, comp);
            const key = try dupe(allocator, id);
            errdefer allocator.free(key);
            self.components.put(allocator, key, comp) catch return Error.OutOfMemory;
        }

        if (obj.get("data")) |dv| {
            const dobj = switch (dv) {
                .object => |o| o,
                else => {
                    diagSet(diag, "\"data\" must be an object", .{});
                    return Error.Malformed;
                },
            };
            if (dobj.count() > MAX_DATA_KEYS) return Error.TooBig;
            var dit = dobj.iterator();
            while (dit.next()) |entry| {
                try self.putData(entry.key_ptr.*, entry.value_ptr.*, diag);
            }
        }

        try self.validate(diag);
        return self;
    }

    pub fn deinit(self: *Document) void {
        const a = self.allocator;
        if (self.title.len > 0) a.free(self.title);
        if (self.root.len > 0) a.free(self.root);
        var cit = self.components.iterator();
        while (cit.next()) |entry| {
            freeComponent(a, entry.value_ptr.*);
            a.free(entry.key_ptr.*);
        }
        self.components.deinit(a);
        var dit = self.data.iterator();
        while (dit.next()) |entry| {
            freeDataValue(a, entry.value_ptr.*);
            a.free(entry.key_ptr.*);
        }
        self.data.deinit(a);
        self.* = undefined;
    }

    // ---- queries -----------------------------------------------------

    pub fn get(self: *const Document, id: []const u8) ?*const Component {
        return self.components.getPtr(id);
    }

    pub fn kindOf(self: *const Document, id: []const u8) ?Kind {
        const comp = self.components.getPtr(id) orelse return null;
        return comp.kind();
    }

    // ---- data --------------------------------------------------------

    fn putData(self: *Document, key: []const u8, v: std.json.Value, diag: ?*Diag) Error!void {
        if (!validId(key)) {
            diagSet(diag, "invalid data key \"{s}\"", .{key});
            return Error.BadId;
        }
        const a = self.allocator;
        const dval: DataValue = switch (v) {
            .bool => |b| .{ .boolean = b },
            .integer, .float => .{ .number = numOf(v).? },
            .string => |s| blk: {
                if (s.len > MAX_TEXT) return Error.TooBig;
                break :blk .{ .text = try dupe(a, s) };
            },
            else => {
                diagSet(diag, "data \"{s}\": values must be scalar", .{key});
                return Error.BadValue;
            },
        };
        errdefer freeDataValue(a, dval);
        if (self.data.getPtr(key)) |existing| {
            freeDataValue(a, existing.*);
            existing.* = dval;
            return;
        }
        if (self.data.count() >= MAX_DATA_KEYS) return Error.TooBig;
        const kcopy = try dupe(a, key);
        errdefer a.free(kcopy);
        self.data.put(a, kcopy, dval) catch return Error.OutOfMemory;
    }

    fn removeData(self: *Document, key: []const u8) void {
        if (self.data.fetchRemove(key)) |kv| {
            freeDataValue(self.allocator, kv.value);
            self.allocator.free(kv.key);
        }
    }

    // ---- validation --------------------------------------------------

    /// Whole-document invariants: root exists, every child reference
    /// resolves, and the tree walked from root revisits no component
    /// (which covers both cycles and one component mounted twice).
    /// Components UNREACHABLE from root are legal — a patch may add a
    /// component in one op and attach it in a later one.
    pub fn validate(self: *const Document, diag: ?*Diag) Error!void {
        if (self.components.getPtr(self.root) == null) {
            diagSet(diag, "root \"{s}\" is not a component", .{self.root});
            return Error.NoRoot;
        }
        var cit = self.components.iterator();
        while (cit.next()) |entry| {
            switch (entry.value_ptr.props) {
                .column, .row => |cont| for (cont.children) |child| {
                    if (self.components.getPtr(child) == null) {
                        diagSet(diag, "\"{s}\" references missing child \"{s}\"", .{ entry.key_ptr.*, child });
                        return Error.BadRef;
                    }
                },
                .scene => |scene| for (scene.children) |placement| {
                    if (self.components.getPtr(placement.id) == null) {
                        diagSet(diag, "\"{s}\" references missing child \"{s}\"", .{ entry.key_ptr.*, placement.id });
                        return Error.BadRef;
                    }
                },
                else => {},
            }
        }
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        defer visited.deinit(self.allocator);
        try self.walk(&visited, self.root, 0, diag);
    }

    fn walk(
        self: *const Document,
        visited: *std.StringHashMapUnmanaged(void),
        id: []const u8,
        depth: usize,
        diag: ?*Diag,
    ) Error!void {
        if (depth > MAX_DEPTH) {
            diagSet(diag, "tree deeper than {d} at \"{s}\"", .{ MAX_DEPTH, id });
            return Error.Cycle;
        }
        if (visited.contains(id)) {
            diagSet(diag, "\"{s}\" is mounted more than once (cycle or duplicate reference)", .{id});
            return Error.Cycle;
        }
        visited.put(self.allocator, id, {}) catch return Error.OutOfMemory;
        const comp = self.components.getPtr(id) orelse return; // checked above
        switch (comp.props) {
            .column, .row => |cont| for (cont.children) |child| {
                try self.walk(visited, child, depth + 1, diag);
            },
            .scene => |scene| for (scene.children) |placement| {
                try self.walk(visited, placement.id, depth + 1, diag);
            },
            else => {},
        }
    }

    // ---- serialization -----------------------------------------------

    /// Canonical JSON: fixed field order, component and data keys
    /// sorted, every kind-relevant field present. parse(toJson(d))
    /// then toJson again yields byte-identical output, which is what
    /// the persisted-panel store and the round-trip tests lean on.
    pub fn toJson(self: *const Document, allocator: std.mem.Allocator) Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;
        self.write(allocator, w) catch return Error.OutOfMemory;
        return aw.toOwnedSlice() catch Error.OutOfMemory;
    }

    fn write(self: *const Document, allocator: std.mem.Allocator, w: *std.Io.Writer) !void {
        try w.writeAll("{\"version\":1,\"title\":");
        try jsonStr(w, self.title);
        try w.writeAll(",\"root\":");
        try jsonStr(w, self.root);

        try w.writeAll(",\"data\":{");
        {
            const keys = try sortedKeys(allocator, DataValue, &self.data);
            defer allocator.free(keys);
            for (keys, 0..) |key, i| {
                if (i > 0) try w.writeByte(',');
                try jsonStr(w, key);
                try w.writeByte(':');
                switch (self.data.get(key).?) {
                    .number => |n| try jsonNum(w, n),
                    .boolean => |b| try w.writeAll(if (b) "true" else "false"),
                    .text => |txt| try jsonStr(w, txt),
                }
            }
        }
        try w.writeAll("},\"components\":{");
        {
            const keys = try sortedKeys(allocator, Component, &self.components);
            defer allocator.free(keys);
            for (keys, 0..) |key, i| {
                if (i > 0) try w.writeByte(',');
                try jsonStr(w, key);
                try w.writeByte(':');
                try writeComponent(w, self.components.getPtr(key).?);
            }
        }
        try w.writeAll("}}");
    }

    // ---- patching ----------------------------------------------------

    /// Ids touched by a successful patch, for the renderer's
    /// incremental update. All slices owned; free with deinit().
    pub const Applied = struct {
        allocator: std.mem.Allocator,
        set: [][]u8 = &.{},
        removed: [][]u8 = &.{},
        data_keys: [][]u8 = &.{},
        root_changed: bool = false,
        title_changed: bool = false,

        pub fn deinit(self: *Applied) void {
            for (self.set) |s| self.allocator.free(s);
            if (self.set.len > 0) self.allocator.free(self.set);
            for (self.removed) |s| self.allocator.free(s);
            if (self.removed.len > 0) self.allocator.free(self.removed);
            for (self.data_keys) |s| self.allocator.free(s);
            if (self.data_keys.len > 0) self.allocator.free(self.data_keys);
            self.* = undefined;
        }
    };

    /// Apply a JSON patch — an ARRAY of ops:
    ///   {"op":"set","id":I,"component":{...}}   insert or replace
    ///   {"op":"remove","id":I}                  also detached from parents
    ///   {"op":"data","key":K,"value":scalar}    null value = delete key
    ///   {"op":"root","id":I}
    ///   {"op":"title","value":S}
    /// Transactional: ops are applied to a CLONE which replaces the
    /// document only after full re-validation, so a failing patch
    /// leaves the document exactly as it was.
    pub fn applyPatch(self: *Document, json_text: []const u8, diag: ?*Diag) Error!Applied {
        if (json_text.len > MAX_JSON_BYTES) return Error.TooBig;
        const a = self.allocator;
        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{}) catch {
            diagSet(diag, "patch is not valid JSON", .{});
            return Error.Malformed;
        };
        const ops = switch (value) {
            .array => |arr| arr.items,
            else => {
                diagSet(diag, "patch must be a JSON array of ops", .{});
                return Error.Malformed;
            },
        };
        if (ops.len > MAX_PATCH_OPS) {
            diagSet(diag, "more than {d} ops in one patch", .{MAX_PATCH_OPS});
            return Error.TooBig;
        }

        var next = try self.clone();
        errdefer next.deinit();

        var set_ids: std.ArrayList([]u8) = .empty;
        var removed_ids: std.ArrayList([]u8) = .empty;
        var data_keys: std.ArrayList([]u8) = .empty;
        var applied = Applied{ .allocator = a };
        errdefer {
            for (set_ids.items) |s| a.free(s);
            set_ids.deinit(a);
            for (removed_ids.items) |s| a.free(s);
            removed_ids.deinit(a);
            for (data_keys.items) |s| a.free(s);
            data_keys.deinit(a);
        }

        for (ops) |op_v| {
            const op_obj = switch (op_v) {
                .object => |o| o,
                else => {
                    diagSet(diag, "each op must be an object", .{});
                    return Error.Malformed;
                },
            };
            const op_name = strField(op_obj, "op") orelse {
                diagSet(diag, "op missing \"op\" field", .{});
                return Error.Malformed;
            };
            if (std.mem.eql(u8, op_name, "set")) {
                const id = strField(op_obj, "id") orelse return missingField(diag, "set", "id");
                if (!validId(id)) {
                    diagSet(diag, "invalid component id \"{s}\"", .{id});
                    return Error.BadId;
                }
                const comp_v = op_obj.get("component") orelse return missingField(diag, "set", "component");
                const comp = try parseComponent(a, id, comp_v, diag);
                {
                    errdefer freeComponent(a, comp);
                    if (next.components.getPtr(id)) |existing| {
                        freeComponent(a, existing.*);
                        existing.* = comp;
                    } else {
                        if (next.components.count() >= MAX_COMPONENTS) {
                            diagSet(diag, "more than {d} components", .{MAX_COMPONENTS});
                            return Error.TooBig;
                        }
                        const key = try dupe(a, id);
                        errdefer a.free(key);
                        next.components.put(a, key, comp) catch return Error.OutOfMemory;
                    }
                }
                try appendId(a, &set_ids, id);
            } else if (std.mem.eql(u8, op_name, "remove")) {
                const id = strField(op_obj, "id") orelse return missingField(diag, "remove", "id");
                if (std.mem.eql(u8, id, next.root)) {
                    diagSet(diag, "cannot remove the root (\"root\" op first)", .{});
                    return Error.BadRef;
                }
                const kv = next.components.fetchRemove(id) orelse {
                    diagSet(diag, "remove: no component \"{s}\"", .{id});
                    return Error.BadRef;
                };
                freeComponent(a, kv.value);
                a.free(kv.key);
                try next.detachFromParents(id);
                try appendId(a, &removed_ids, id);
            } else if (std.mem.eql(u8, op_name, "data")) {
                const key = strField(op_obj, "key") orelse return missingField(diag, "data", "key");
                const dv = op_obj.get("value") orelse std.json.Value.null;
                if (dv == .null) {
                    next.removeData(key);
                } else {
                    try next.putData(key, dv, diag);
                }
                try appendId(a, &data_keys, key);
            } else if (std.mem.eql(u8, op_name, "root")) {
                const id = strField(op_obj, "id") orelse return missingField(diag, "root", "id");
                if (!validId(id)) return Error.BadId;
                const copy = try dupe(a, id);
                if (next.root.len > 0) a.free(next.root);
                next.root = copy;
                applied.root_changed = true;
            } else if (std.mem.eql(u8, op_name, "title")) {
                const s = strField(op_obj, "value") orelse return missingField(diag, "title", "value");
                if (s.len > MAX_TEXT) return Error.TooBig;
                const copy = try dupe(a, s);
                if (next.title.len > 0) a.free(next.title);
                next.title = copy;
                applied.title_changed = true;
            } else {
                diagSet(diag, "unknown op \"{s}\"", .{op_name});
                return Error.Malformed;
            }
        }

        try next.validate(diag);

        applied.set = set_ids.toOwnedSlice(a) catch return Error.OutOfMemory;
        applied.removed = removed_ids.toOwnedSlice(a) catch return Error.OutOfMemory;
        applied.data_keys = data_keys.toOwnedSlice(a) catch return Error.OutOfMemory;

        next.revision = self.revision + 1;
        self.deinit();
        self.* = next;
        return applied;
    }

    /// Deep copy through the (tested) serialize/parse pair — the
    /// document is bounded and small, and this cannot drift from the
    /// canonical form.
    pub fn clone(self: *const Document) Error!Document {
        const bytes = try self.toJson(self.allocator);
        defer self.allocator.free(bytes);
        var copy = try parse(self.allocator, bytes, null);
        copy.revision = self.revision;
        return copy;
    }

    /// Strip `id` out of every container's children list. The slice
    /// is REBUILT, never shortened in place — the allocator must be
    /// handed back the exact slice it produced.
    fn detachFromParents(self: *Document, id: []const u8) Error!void {
        const a = self.allocator;
        var cit = self.components.iterator();
        while (cit.next()) |entry| {
            switch (entry.value_ptr.props) {
                .column, .row => |*cont| {
                    var matches: usize = 0;
                    for (cont.children) |ch| {
                        if (std.mem.eql(u8, ch, id)) matches += 1;
                    }
                    if (matches == 0) continue;
                    // Allocate BEFORE freeing anything so an OOM here
                    // leaves the component fully intact.
                    const kept = a.alloc([]u8, cont.children.len - matches) catch return Error.OutOfMemory;
                    var n: usize = 0;
                    for (cont.children) |ch| {
                        if (std.mem.eql(u8, ch, id)) {
                            a.free(ch);
                        } else {
                            kept[n] = ch;
                            n += 1;
                        }
                    }
                    a.free(cont.children);
                    cont.children = kept;
                },
                .scene => |*scene| {
                    var matches: usize = 0;
                    for (scene.children) |placement| {
                        if (std.mem.eql(u8, placement.id, id)) matches += 1;
                    }
                    if (matches == 0) continue;
                    const kept = a.alloc(Props.Placement, scene.children.len - matches) catch return Error.OutOfMemory;
                    var n: usize = 0;
                    for (scene.children) |placement| {
                        if (std.mem.eql(u8, placement.id, id)) {
                            a.free(placement.id);
                        } else {
                            kept[n] = placement;
                            n += 1;
                        }
                    }
                    a.free(scene.children);
                    scene.children = kept;
                },
                else => {},
            }
        }
    }
};

fn missingField(diag: ?*Diag, op: []const u8, field: []const u8) Error {
    diagSet(diag, "{s} op missing \"{s}\"", .{ op, field });
    return Error.Malformed;
}

fn appendId(a: std.mem.Allocator, list: *std.ArrayList([]u8), id: []const u8) Error!void {
    const copy = try dupe(a, id);
    errdefer a.free(copy);
    list.append(a, copy) catch return Error.OutOfMemory;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn dupe(a: std.mem.Allocator, s: []const u8) Error![]u8 {
    return a.dupe(u8, s) catch Error.OutOfMemory;
}

fn sortedKeys(
    allocator: std.mem.Allocator,
    comptime V: type,
    map: *const std.StringHashMapUnmanaged(V),
) ![][]const u8 {
    var keys = try allocator.alloc([]const u8, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) keys[i] = entry.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return keys;
}

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(@as([]const u8, s), .{}, w);
}

fn jsonNum(w: *std.Io.Writer, n: f64) !void {
    try std.json.Stringify.value(n, .{}, w);
}

// ─── component parse / free / write ─────────────────────────────

fn parseComponent(
    a: std.mem.Allocator,
    id: []const u8,
    value: std.json.Value,
    diag: ?*Diag,
) Error!Component {
    const obj = switch (value) {
        .object => |o| o,
        else => {
            diagSet(diag, "component \"{s}\" must be an object", .{id});
            return Error.Malformed;
        },
    };
    const type_s = strField(obj, "type") orelse {
        diagSet(diag, "component \"{s}\" missing \"type\"", .{id});
        return Error.Malformed;
    };
    const kind = std.meta.stringToEnum(Kind, type_s) orelse {
        diagSet(diag, "\"{s}\": unknown component type \"{s}\"", .{ id, type_s });
        return Error.UnknownComponent;
    };

    var classes: std.ArrayList([]u8) = .empty;
    errdefer {
        for (classes.items) |cl| a.free(cl);
        classes.deinit(a);
    }
    if (obj.get("class")) |cv| {
        const arr = switch (cv) {
            .array => |x| x.items,
            else => {
                diagSet(diag, "\"{s}\": \"class\" must be an array of names", .{id});
                return Error.BadValue;
            },
        };
        if (arr.len > MAX_CLASSES) return Error.TooBig;
        for (arr) |cl_v| {
            const cl = switch (cl_v) {
                .string => |s| s,
                else => return Error.BadValue,
            };
            if (!validClass(cl)) {
                diagSet(diag, "\"{s}\": unknown class \"{s}\"", .{ id, cl });
                return Error.BadValue;
            }
            try appendId(a, &classes, cl);
        }
    }

    const props: Props = switch (kind) {
        .column, .row => blk: {
            var children: std.ArrayList([]u8) = .empty;
            errdefer {
                for (children.items) |ch| a.free(ch);
                children.deinit(a);
            }
            if (obj.get("children")) |chv| {
                const arr = switch (chv) {
                    .array => |x| x.items,
                    else => {
                        diagSet(diag, "\"{s}\": \"children\" must be an array of ids", .{id});
                        return Error.BadValue;
                    },
                };
                if (arr.len > MAX_CHILDREN) {
                    diagSet(diag, "\"{s}\": more than {d} children", .{ id, MAX_CHILDREN });
                    return Error.TooBig;
                }
                for (arr) |ch_v| {
                    const ch = switch (ch_v) {
                        .string => |s| s,
                        else => return Error.BadValue,
                    };
                    if (!validId(ch)) {
                        diagSet(diag, "\"{s}\": invalid child id \"{s}\"", .{ id, ch });
                        return Error.BadId;
                    }
                    try appendId(a, &children, ch);
                }
            }
            const cont = Props.Container{ .children = children.toOwnedSlice(a) catch return Error.OutOfMemory };
            break :blk if (kind == .column) .{ .column = cont } else .{ .row = cont };
        },
        .scene => blk: {
            const width = try sceneSize(obj, "width", id, diag);
            const height = try sceneSize(obj, "height", id, diag);
            const children_v = obj.get("children") orelse {
                diagSet(diag, "\"{s}\": scene needs \"children\"", .{id});
                return Error.Malformed;
            };
            const children_a = switch (children_v) {
                .array => |x| x.items,
                else => {
                    diagSet(diag, "\"{s}\": scene \"children\" must be an array of placements", .{id});
                    return Error.BadValue;
                },
            };
            if (children_a.len > MAX_CHILDREN) {
                diagSet(diag, "\"{s}\": more than {d} children", .{ id, MAX_CHILDREN });
                return Error.TooBig;
            }
            var placements: std.ArrayList(Props.Placement) = .empty;
            errdefer {
                for (placements.items) |placement| a.free(placement.id);
                placements.deinit(a);
            }
            for (children_a) |placement_v| {
                const placement = switch (placement_v) {
                    .object => |o| o,
                    else => {
                        diagSet(diag, "\"{s}\": each scene child must be a placement object", .{id});
                        return Error.BadValue;
                    },
                };
                const child_id = strField(placement, "id") orelse {
                    diagSet(diag, "\"{s}\": scene placement missing \"id\"", .{id});
                    return Error.Malformed;
                };
                if (!validId(child_id)) {
                    diagSet(diag, "\"{s}\": invalid child id \"{s}\"", .{ id, child_id });
                    return Error.BadId;
                }
                const owned_id = try dupe(a, child_id);
                errdefer a.free(owned_id);
                placements.append(a, .{
                    .id = owned_id,
                    .x = try sceneCoord(placement, "x", id, diag),
                    .y = try sceneCoord(placement, "y", id, diag),
                    .width = try sceneSize(placement, "width", id, diag),
                    .height = try sceneSize(placement, "height", id, diag),
                }) catch return Error.OutOfMemory;
            }
            break :blk .{ .scene = .{
                .width = width,
                .height = height,
                .children = placements.toOwnedSlice(a) catch return Error.OutOfMemory,
            } };
        },
        .heading => blk: {
            const text = try ownedText(a, obj, "text", id, diag);
            errdefer a.free(text);
            var level: u8 = 1;
            if (obj.get("level")) |lv| {
                const n = numOf(lv) orelse return Error.BadValue;
                if (n < 1 or n > 4) {
                    diagSet(diag, "\"{s}\": heading level must be 1..4", .{id});
                    return Error.BadValue;
                }
                level = @intFromFloat(n);
            }
            break :blk .{ .heading = .{ .text = text, .level = level } };
        },
        .text => .{ .text = .{ .text = try ownedText(a, obj, "text", id, diag) } },
        .image => blk: {
            const src = try ownedPath(a, obj, "src", id, diag);
            errdefer a.free(src);
            const caption = try ownedOptText(a, obj, "caption", id, diag);
            break :blk .{ .image = .{ .src = src, .caption = caption } };
        },
        .image_compare => blk: {
            const left = try parseSide(a, obj, "left", id, diag);
            errdefer {
                a.free(left.src);
                if (left.label.len > 0) a.free(left.label);
            }
            const right = try parseSide(a, obj, "right", id, diag);
            break :blk .{ .image_compare = .{ .left = left, .right = right } };
        },
        .button => blk: {
            const text = try ownedText(a, obj, "text", id, diag);
            errdefer a.free(text);
            const action = try ownedOptText(a, obj, "action", id, diag);
            errdefer a.free(action);
            if (action.len > MAX_OPTION) {
                diagSet(diag, "\"{s}\": action longer than {d}", .{ id, MAX_OPTION });
                return Error.TooBig;
            }
            break :blk .{ .button = .{ .text = text, .action = action } };
        },
        .slider => blk: {
            const min = if (obj.get("min")) |v| numOf(v) orelse return Error.BadValue else 0;
            const max = if (obj.get("max")) |v| numOf(v) orelse return Error.BadValue else 100;
            const step = if (obj.get("step")) |v| numOf(v) orelse return Error.BadValue else 1;
            var val = if (obj.get("value")) |v| numOf(v) orelse return Error.BadValue else min;
            if (!(min < max) or !(step > 0) or !std.math.isFinite(min) or !std.math.isFinite(max) or !std.math.isFinite(step)) {
                diagSet(diag, "\"{s}\": slider needs min < max and step > 0", .{id});
                return Error.BadValue;
            }
            if (!std.math.isFinite(val)) return Error.BadValue;
            val = std.math.clamp(val, min, max);
            break :blk .{ .slider = .{ .min = min, .max = max, .step = step, .value = val } };
        },
        .select => blk: {
            var options: std.ArrayList([]u8) = .empty;
            errdefer {
                for (options.items) |o| a.free(o);
                options.deinit(a);
            }
            const ov = obj.get("options") orelse {
                diagSet(diag, "\"{s}\": select needs \"options\"", .{id});
                return Error.Malformed;
            };
            const arr = switch (ov) {
                .array => |x| x.items,
                else => return Error.BadValue,
            };
            if (arr.len == 0 or arr.len > MAX_OPTIONS) {
                diagSet(diag, "\"{s}\": select needs 1..{d} options", .{ id, MAX_OPTIONS });
                return Error.BadValue;
            }
            for (arr) |o_v| {
                const o = switch (o_v) {
                    .string => |s| s,
                    else => return Error.BadValue,
                };
                if (o.len == 0 or o.len > MAX_OPTION) {
                    diagSet(diag, "\"{s}\": options must be 1..{d} chars", .{ id, MAX_OPTION });
                    return Error.BadValue;
                }
                try appendId(a, &options, o);
            }
            // The selected value must be one of the options; an absent
            // or unknown value falls back to the first option rather
            // than erroring, so a patch that swaps the option list
            // does not have to synchronize the value in the same op.
            var sel: []const u8 = options.items[0];
            if (strField(obj, "value")) |vs| {
                for (options.items) |o| {
                    if (std.mem.eql(u8, o, vs)) {
                        sel = o;
                        break;
                    }
                }
            }
            const sel_copy = try dupe(a, sel);
            errdefer a.free(sel_copy);
            break :blk .{ .select = .{
                .options = options.toOwnedSlice(a) catch return Error.OutOfMemory,
                .value = sel_copy,
            } };
        },
        .progress => blk: {
            var val: f64 = 0;
            if (obj.get("value")) |v| {
                val = numOf(v) orelse return Error.BadValue;
                if (!std.math.isFinite(val)) return Error.BadValue;
                val = std.math.clamp(val, 0, 1);
            }
            const indet = if (obj.get("indeterminate")) |v| switch (v) {
                .bool => |b| b,
                else => return Error.BadValue,
            } else false;
            const label = try ownedOptText(a, obj, "label", id, diag);
            break :blk .{ .progress = .{ .value = val, .label = label, .indeterminate = indet } };
        },
        .separator => .separator,
        .spacer => blk: {
            var size: u16 = 0;
            if (obj.get("size")) |v| {
                const n = numOf(v) orelse return Error.BadValue;
                if (n < 0 or n > 4096) return Error.BadValue;
                size = @intFromFloat(n);
            }
            break :blk .{ .spacer = .{ .size = size } };
        },
        .text_input => blk: {
            const input_value = try ownedOptUtf8Text(a, obj, "value", id, diag);
            errdefer a.free(input_value);
            const placeholder = try ownedOptUtf8Text(a, obj, "placeholder", id, diag);
            errdefer a.free(placeholder);
            const clear_on_submit = if (obj.get("clear_on_submit")) |v| switch (v) {
                .bool => |b| b,
                else => {
                    diagSet(diag, "\"{s}\": \"clear_on_submit\" must be a boolean", .{id});
                    return Error.BadValue;
                },
            } else false;
            break :blk .{ .text_input = .{
                .value = input_value,
                .placeholder = placeholder,
                .clear_on_submit = clear_on_submit,
            } };
        },
    };
    errdefer freeProps(a, props);

    return .{
        .props = props,
        .classes = classes.toOwnedSlice(a) catch return Error.OutOfMemory,
    };
}

fn parseSide(
    a: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    id: []const u8,
    diag: ?*Diag,
) Error!Side {
    const v = obj.get(key) orelse {
        diagSet(diag, "\"{s}\": image_compare needs \"{s}\"", .{ id, key });
        return Error.Malformed;
    };
    const side_obj = switch (v) {
        .object => |o| o,
        else => {
            diagSet(diag, "\"{s}\": \"{s}\" must be {{src, label?}}", .{ id, key });
            return Error.BadValue;
        },
    };
    const src = try ownedPath(a, side_obj, "src", id, diag);
    errdefer a.free(src);
    const label = try ownedOptText(a, side_obj, "label", id, diag);
    return .{ .src = src, .label = label };
}

fn ownedText(
    a: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    id: []const u8,
    diag: ?*Diag,
) Error![]u8 {
    const s = strField(obj, key) orelse {
        diagSet(diag, "\"{s}\": missing \"{s}\"", .{ id, key });
        return Error.Malformed;
    };
    if (s.len > MAX_TEXT) {
        diagSet(diag, "\"{s}\": \"{s}\" longer than {d}", .{ id, key, MAX_TEXT });
        return Error.TooBig;
    }
    return dupe(a, s);
}

/// Optional string field; absent yields "".
fn ownedOptText(
    a: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    id: []const u8,
    diag: ?*Diag,
) Error![]u8 {
    const v = obj.get(key) orelse return dupe(a, "");
    const s = switch (v) {
        .string => |x| x,
        else => {
            diagSet(diag, "\"{s}\": \"{s}\" must be a string", .{ id, key });
            return Error.BadValue;
        },
    };
    if (s.len > MAX_TEXT) return Error.TooBig;
    return dupe(a, s);
}

fn ownedPath(
    a: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    id: []const u8,
    diag: ?*Diag,
) Error![]u8 {
    const s = strField(obj, key) orelse {
        diagSet(diag, "\"{s}\": missing \"{s}\"", .{ id, key });
        return Error.Malformed;
    };
    if (!validImagePath(s)) {
        diagSet(diag, "\"{s}\": \"{s}\" must be an absolute path without \"..\"", .{ id, key });
        return Error.BadValue;
    }
    return dupe(a, s);
}

fn ownedOptUtf8Text(
    a: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    id: []const u8,
    diag: ?*Diag,
) Error![]u8 {
    const text = try ownedOptText(a, obj, key, id, diag);
    errdefer a.free(text);
    if (!std.unicode.utf8ValidateSlice(text)) {
        diagSet(diag, "\"{s}\": \"{s}\" must be valid UTF-8", .{ id, key });
        return Error.BadValue;
    }
    return text;
}

fn requiredInteger(
    obj: std.json.ObjectMap,
    key: []const u8,
    id: []const u8,
    diag: ?*Diag,
) Error!i64 {
    const value = obj.get(key) orelse {
        diagSet(diag, "\"{s}\": missing integer \"{s}\"", .{ id, key });
        return Error.Malformed;
    };
    return switch (value) {
        .integer => |n| n,
        else => {
            diagSet(diag, "\"{s}\": \"{s}\" must be an integer", .{ id, key });
            return Error.BadValue;
        },
    };
}

fn sceneSize(obj: std.json.ObjectMap, key: []const u8, id: []const u8, diag: ?*Diag) Error!u16 {
    const value = try requiredInteger(obj, key, id, diag);
    if (value < 1 or value > MAX_SCENE_SIZE) {
        diagSet(diag, "\"{s}\": \"{s}\" must be 1..{d}", .{ id, key, MAX_SCENE_SIZE });
        return Error.BadValue;
    }
    return @intCast(value);
}

fn sceneCoord(obj: std.json.ObjectMap, key: []const u8, id: []const u8, diag: ?*Diag) Error!i32 {
    const value = try requiredInteger(obj, key, id, diag);
    if (value < -MAX_SCENE_COORD or value > MAX_SCENE_COORD) {
        diagSet(diag, "\"{s}\": \"{s}\" must be within -{d}..{d}", .{ id, key, MAX_SCENE_COORD, MAX_SCENE_COORD });
        return Error.BadValue;
    }
    return @intCast(value);
}

fn freeProps(a: std.mem.Allocator, props: Props) void {
    switch (props) {
        .column, .row => |cont| {
            for (cont.children) |ch| a.free(ch);
            if (cont.children.len > 0) a.free(cont.children);
        },
        .scene => |scene| {
            for (scene.children) |placement| a.free(placement.id);
            if (scene.children.len > 0) a.free(scene.children);
        },
        .heading => |h| a.free(h.text),
        .text => |txt| a.free(txt.text),
        .image => |img| {
            a.free(img.src);
            a.free(img.caption);
        },
        .image_compare => |ic| {
            a.free(ic.left.src);
            a.free(ic.left.label);
            a.free(ic.right.src);
            a.free(ic.right.label);
        },
        .button => |b| {
            a.free(b.text);
            a.free(b.action);
        },
        .slider => {},
        .select => |s| {
            for (s.options) |o| a.free(o);
            if (s.options.len > 0) a.free(s.options);
            a.free(s.value);
        },
        .progress => |p| a.free(p.label),
        .separator => {},
        .spacer => {},
        .text_input => |input| {
            a.free(input.value);
            a.free(input.placeholder);
        },
    }
}

fn freeDataValue(a: std.mem.Allocator, v: DataValue) void {
    switch (v) {
        .text => |s| a.free(s),
        else => {},
    }
}

pub fn freeComponent(a: std.mem.Allocator, comp: Component) void {
    freeProps(a, comp.props);
    for (comp.classes) |cl| a.free(cl);
    if (comp.classes.len > 0) a.free(comp.classes);
}

fn writeComponent(w: *std.Io.Writer, comp: *const Component) !void {
    try w.writeAll("{\"type\":");
    try jsonStr(w, @tagName(comp.kind()));
    switch (comp.props) {
        .column, .row => |cont| {
            try w.writeAll(",\"children\":[");
            for (cont.children, 0..) |ch, i| {
                if (i > 0) try w.writeByte(',');
                try jsonStr(w, ch);
            }
            try w.writeByte(']');
        },
        .scene => |scene| {
            try w.print(",\"width\":{d},\"height\":{d},\"children\":[", .{ scene.width, scene.height });
            for (scene.children, 0..) |placement, i| {
                if (i > 0) try w.writeByte(',');
                try w.writeAll("{\"id\":");
                try jsonStr(w, placement.id);
                try w.print(",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{
                    placement.x,
                    placement.y,
                    placement.width,
                    placement.height,
                });
            }
            try w.writeByte(']');
        },
        .heading => |h| {
            try w.writeAll(",\"text\":");
            try jsonStr(w, h.text);
            try w.print(",\"level\":{d}", .{h.level});
        },
        .text => |txt| {
            try w.writeAll(",\"text\":");
            try jsonStr(w, txt.text);
        },
        .image => |img| {
            try w.writeAll(",\"src\":");
            try jsonStr(w, img.src);
            try w.writeAll(",\"caption\":");
            try jsonStr(w, img.caption);
        },
        .image_compare => |ic| {
            try w.writeAll(",\"left\":{\"src\":");
            try jsonStr(w, ic.left.src);
            try w.writeAll(",\"label\":");
            try jsonStr(w, ic.left.label);
            try w.writeAll("},\"right\":{\"src\":");
            try jsonStr(w, ic.right.src);
            try w.writeAll(",\"label\":");
            try jsonStr(w, ic.right.label);
            try w.writeByte('}');
        },
        .button => |b| {
            try w.writeAll(",\"text\":");
            try jsonStr(w, b.text);
            try w.writeAll(",\"action\":");
            try jsonStr(w, b.action);
        },
        .slider => |s| {
            try w.writeAll(",\"min\":");
            try jsonNum(w, s.min);
            try w.writeAll(",\"max\":");
            try jsonNum(w, s.max);
            try w.writeAll(",\"step\":");
            try jsonNum(w, s.step);
            try w.writeAll(",\"value\":");
            try jsonNum(w, s.value);
        },
        .select => |s| {
            try w.writeAll(",\"options\":[");
            for (s.options, 0..) |o, i| {
                if (i > 0) try w.writeByte(',');
                try jsonStr(w, o);
            }
            try w.writeAll("],\"value\":");
            try jsonStr(w, s.value);
        },
        .progress => |p| {
            try w.writeAll(",\"value\":");
            try jsonNum(w, p.value);
            try w.writeAll(",\"label\":");
            try jsonStr(w, p.label);
            try w.writeAll(",\"indeterminate\":");
            try w.writeAll(if (p.indeterminate) "true" else "false");
        },
        .separator => {},
        .spacer => |sp| try w.print(",\"size\":{d}", .{sp.size}),
        .text_input => |input| {
            try w.writeAll(",\"value\":");
            try jsonStr(w, input.value);
            try w.writeAll(",\"placeholder\":");
            try jsonStr(w, input.placeholder);
            try w.writeAll(",\"clear_on_submit\":");
            try w.writeAll(if (input.clear_on_submit) "true" else "false");
        },
    }
    if (comp.classes.len > 0) {
        try w.writeAll(",\"class\":[");
        for (comp.classes, 0..) |cl, i| {
            if (i > 0) try w.writeByte(',');
            try jsonStr(w, cl);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

const FULL_DOC =
    \\{
    \\  "version": 1,
    \\  "title": "Epoch 41",
    \\  "root": "main",
    \\  "data": { "zoom": 1.5, "note": "warm", "ok": true },
    \\  "components": {
    \\    "main": {"type":"column","children":["h","cmp","ctrl","bar"],"class":["card"]},
    \\    "h": {"type":"heading","text":"Epoch 41 vs 40","level":2},
    \\    "cmp": {"type":"image_compare",
    \\      "left":{"src":"/tmp/e40.png","label":"epoch 40"},
    \\      "right":{"src":"/tmp/e41.png","label":"epoch 41"}},
    \\    "ctrl": {"type":"row","children":["ok_btn","bad_btn","thr","pick","sp","note"]},
    \\    "ok_btn": {"type":"button","text":"Better","action":"approve","class":["accent"]},
    \\    "bad_btn": {"type":"button","text":"Worse"},
    \\    "thr": {"type":"slider","min":0,"max":1,"step":0.05,"value":0.5},
    \\    "pick": {"type":"select","options":["epoch 40","epoch 41"],"value":"epoch 41"},
    \\    "sp": {"type":"spacer"},
    \\    "note": {"type":"text","text":"PSNR +0.4 dB","class":["dim"]},
    \\    "bar": {"type":"progress","value":0.41,"label":"epoch 41/100"}
    \\  }
    \\}
;

test "parse a full-catalog document" {
    var doc = try Document.parse(t.allocator, FULL_DOC, null);
    defer doc.deinit();
    try t.expectEqualStrings("main", doc.root);
    try t.expectEqualStrings("Epoch 41", doc.title);
    try t.expectEqual(@as(usize, 11), doc.components.count());
    try t.expectEqual(Kind.image_compare, doc.kindOf("cmp").?);
    const cmp = doc.get("cmp").?;
    try t.expectEqualStrings("/tmp/e40.png", cmp.props.image_compare.left.src);
    try t.expectEqualStrings("epoch 41", cmp.props.image_compare.right.label);
    const thr = doc.get("thr").?;
    try t.expectEqual(@as(f64, 0.05), thr.props.slider.step);
    const pick = doc.get("pick").?;
    try t.expectEqualStrings("epoch 41", pick.props.select.value);
    try t.expectEqual(@as(f64, 1.5), doc.data.get("zoom").?.number);
    try t.expectEqualStrings("warm", doc.data.get("note").?.text);
    try t.expect(doc.data.get("ok").?.boolean);
    const main = doc.get("main").?;
    try t.expectEqual(@as(usize, 4), main.props.column.children.len);
    try t.expectEqualStrings("card", main.classes[0]);
}

test "reject malformed and unknown-component documents" {
    var diag = Diag{};
    // Not JSON at all.
    try t.expectError(Error.Malformed, Document.parse(t.allocator, "not json", &diag));
    // Unknown component type, with a useful message.
    try t.expectError(Error.UnknownComponent, Document.parse(t.allocator,
        \\{"root":"r","components":{"r":{"type":"webview","url":"http://x"}}}
    , &diag));
    try t.expect(std.mem.indexOf(u8, diag.msg(), "webview") != null);
    // Missing root / root not a component.
    try t.expectError(Error.NoRoot, Document.parse(t.allocator,
        \\{"components":{"r":{"type":"text","text":"x"}}}
    , &diag));
    try t.expectError(Error.NoRoot, Document.parse(t.allocator,
        \\{"root":"missing","components":{"r":{"type":"text","text":"x"}}}
    , &diag));
    // Child reference to a component that does not exist.
    try t.expectError(Error.BadRef, Document.parse(t.allocator,
        \\{"root":"r","components":{"r":{"type":"column","children":["ghost"]}}}
    , &diag));
    // Bad ids.
    try t.expectError(Error.BadId, Document.parse(t.allocator,
        \\{"root":"a b","components":{"a b":{"type":"text","text":"x"}}}
    , &diag));
    // Unknown style class.
    try t.expectError(Error.BadValue, Document.parse(t.allocator,
        \\{"root":"r","components":{"r":{"type":"text","text":"x","class":["blink"]}}}
    , &diag));
    // Relative and traversing image paths.
    try t.expectError(Error.BadValue, Document.parse(t.allocator,
        \\{"root":"r","components":{"r":{"type":"image","src":"rel.png"}}}
    , &diag));
    try t.expectError(Error.BadValue, Document.parse(t.allocator,
        \\{"root":"r","components":{"r":{"type":"image","src":"/a/../etc/shadow"}}}
    , &diag));
    // Slider with an empty range.
    try t.expectError(Error.BadValue, Document.parse(t.allocator,
        \\{"root":"r","components":{"r":{"type":"slider","min":5,"max":5}}}
    , &diag));
    // Select with no options.
    try t.expectError(Error.BadValue, Document.parse(t.allocator,
        \\{"root":"r","components":{"r":{"type":"select","options":[]}}}
    , &diag));
}

test "cycles and duplicate mounts are rejected" {
    var diag = Diag{};
    // Self-cycle.
    try t.expectError(Error.Cycle, Document.parse(t.allocator,
        \\{"root":"r","components":{"r":{"type":"column","children":["r"]}}}
    , &diag));
    // Two-node cycle.
    try t.expectError(Error.Cycle, Document.parse(t.allocator,
        \\{"root":"a","components":{
        \\ "a":{"type":"column","children":["b"]},
        \\ "b":{"type":"row","children":["a"]}}}
    , &diag));
    // Same leaf mounted under two parents.
    try t.expectError(Error.Cycle, Document.parse(t.allocator,
        \\{"root":"a","components":{
        \\ "a":{"type":"column","children":["b","c"]},
        \\ "b":{"type":"row","children":["x"]},
        \\ "c":{"type":"row","children":["x"]},
        \\ "x":{"type":"text","text":"once"}}}
    , &diag));
    // Unreferenced (orphan) components are fine.
    var doc = try Document.parse(t.allocator,
        \\{"root":"r","components":{
        \\ "r":{"type":"text","text":"live"},
        \\ "orphan":{"type":"text","text":"staged"}}}
    , &diag);
    doc.deinit();
}

test "values are clamped and defaulted" {
    var doc = try Document.parse(t.allocator,
        \\{"root":"r","components":{
        \\ "r":{"type":"column","children":["p","s","sel"]},
        \\ "p":{"type":"progress","value":7.5},
        \\ "s":{"type":"slider","min":0,"max":10,"value":99},
        \\ "sel":{"type":"select","options":["a","b"],"value":"nope"}}}
    , null);
    defer doc.deinit();
    try t.expectEqual(@as(f64, 1), doc.get("p").?.props.progress.value);
    try t.expectEqual(@as(f64, 10), doc.get("s").?.props.slider.value);
    try t.expectEqualStrings("a", doc.get("sel").?.props.select.value);
}

test "JSON round-trip is canonical and lossless" {
    var doc = try Document.parse(t.allocator, FULL_DOC, null);
    defer doc.deinit();
    const once = try doc.toJson(t.allocator);
    defer t.allocator.free(once);
    var doc2 = try Document.parse(t.allocator, once, null);
    defer doc2.deinit();
    const twice = try doc2.toJson(t.allocator);
    defer t.allocator.free(twice);
    try t.expectEqualStrings(once, twice);
    // Spot-check that content actually survived, not just idempotence.
    try t.expectEqualStrings("Epoch 41", doc2.title);
    try t.expectEqual(@as(usize, 11), doc2.components.count());
    try t.expectEqualStrings("/tmp/e41.png", doc2.get("cmp").?.props.image_compare.right.src);
    try t.expectEqual(@as(f64, 1.5), doc2.data.get("zoom").?.number);
}

test "scene and text_input parse, default, and round-trip losslessly" {
    const source =
        \\{"root":"canvas","components":{
        \\ "canvas":{"type":"scene","width":640,"height":360,"children":[
        \\   {"id":"back","x":-24,"y":12,"width":320,"height":80},
        \\   {"id":"query","x":48,"y":120,"width":400,"height":48}]},
        \\ "back":{"type":"text","text":"background"},
        \\ "query":{"type":"text_input","value":"hello","placeholder":"Ask here","clear_on_submit":true},
        \\ "defaults":{"type":"text_input"}}}
    ;
    var doc = try Document.parse(t.allocator, source, null);
    defer doc.deinit();

    const scene = doc.get("canvas").?.props.scene;
    try t.expectEqual(@as(u16, 640), scene.width);
    try t.expectEqual(@as(u16, 360), scene.height);
    try t.expectEqual(@as(usize, 2), scene.children.len);
    try t.expectEqualStrings("back", scene.children[0].id);
    try t.expectEqual(@as(i32, -24), scene.children[0].x);
    try t.expectEqualStrings("query", scene.children[1].id);
    try t.expectEqual(@as(u16, 48), scene.children[1].height);

    const input = doc.get("query").?.props.text_input;
    try t.expectEqualStrings("hello", input.value);
    try t.expectEqualStrings("Ask here", input.placeholder);
    try t.expect(input.clear_on_submit);
    const defaults = doc.get("defaults").?.props.text_input;
    try t.expectEqualStrings("", defaults.value);
    try t.expectEqualStrings("", defaults.placeholder);
    try t.expect(!defaults.clear_on_submit);

    const once = try doc.toJson(t.allocator);
    defer t.allocator.free(once);
    var copy = try Document.parse(t.allocator, once, null);
    defer copy.deinit();
    const twice = try copy.toJson(t.allocator);
    defer t.allocator.free(twice);
    try t.expectEqualStrings(once, twice);
    try t.expectEqual(@as(i32, -24), copy.get("canvas").?.props.scene.children[0].x);
    try t.expect(copy.get("query").?.props.text_input.clear_on_submit);
}

test "scene dimensions, placements, and references are validated" {
    var diag = Diag{};
    for ([_][]const u8{
        \\{"root":"s","components":{"s":{"type":"scene","width":0,"height":1,"children":[]}}}
        ,
        \\{"root":"s","components":{"s":{"type":"scene","width":4097,"height":1,"children":[]}}}
        ,
        \\{"root":"s","components":{"s":{"type":"scene","width":1.5,"height":1,"children":[]}}}
        ,
        \\{"root":"s","components":{"s":{"type":"scene","width":1,"height":1,"children":[{"id":"x","x":1048577,"y":0,"width":1,"height":1}]},"x":{"type":"text","text":"x"}}}
        ,
        \\{"root":"s","components":{"s":{"type":"scene","width":1,"height":1,"children":[{"id":"x","x":0,"y":0,"width":0,"height":1}]},"x":{"type":"text","text":"x"}}}
        ,
    }) |bad| try t.expectError(Error.BadValue, Document.parse(t.allocator, bad, &diag));

    try t.expectError(Error.Malformed, Document.parse(t.allocator,
        \\{"root":"s","components":{"s":{"type":"scene","width":1,"height":1}}}
    , &diag));
    try t.expectError(Error.BadRef, Document.parse(t.allocator,
        \\{"root":"s","components":{"s":{"type":"scene","width":1,"height":1,"children":[{"id":"missing","x":0,"y":0,"width":1,"height":1}]}}}
    , &diag));
    try t.expectError(Error.Cycle, Document.parse(t.allocator,
        \\{"root":"s","components":{"s":{"type":"scene","width":1,"height":1,"children":[{"id":"s","x":0,"y":0,"width":1,"height":1}]}}}
    , &diag));
    try t.expectError(Error.Cycle, Document.parse(t.allocator,
        \\{"root":"s","components":{
        \\ "s":{"type":"scene","width":10,"height":10,"children":[{"id":"x","x":0,"y":0,"width":1,"height":1},{"id":"x","x":1,"y":1,"width":1,"height":1}]},
        \\ "x":{"type":"text","text":"once"}}}
    , &diag));
}

test "text_input accepts 4096 UTF-8 bytes and rejects larger fields" {
    const max_text = "x" ** MAX_TEXT;
    const too_long = "x" ** (MAX_TEXT + 1);
    const valid = try std.fmt.allocPrint(
        t.allocator,
        "{{\"root\":\"q\",\"components\":{{\"q\":{{\"type\":\"text_input\",\"value\":\"{s}\",\"placeholder\":\"{s}\"}}}}}}",
        .{ max_text, max_text },
    );
    defer t.allocator.free(valid);
    var doc = try Document.parse(t.allocator, valid, null);
    defer doc.deinit();
    try t.expectEqual(@as(usize, MAX_TEXT), doc.get("q").?.props.text_input.value.len);

    const invalid = try std.fmt.allocPrint(
        t.allocator,
        "{{\"root\":\"q\",\"components\":{{\"q\":{{\"type\":\"text_input\",\"value\":\"{s}\"}}}}}}",
        .{too_long},
    );
    defer t.allocator.free(invalid);
    try t.expectError(Error.TooBig, Document.parse(t.allocator, invalid, null));
    try t.expectEqual(@as(usize, 128), MAX_OPTION);
}

test "button actions retain their 128-byte bound" {
    const max_action = "a" ** MAX_OPTION;
    const accepted = try std.fmt.allocPrint(
        t.allocator,
        "{{\"root\":\"b\",\"components\":{{\"b\":{{\"type\":\"button\",\"text\":\"Go\",\"action\":\"{s}\"}}}}}}",
        .{max_action},
    );
    defer t.allocator.free(accepted);
    var doc = try Document.parse(t.allocator, accepted, null);
    defer doc.deinit();
    try t.expectEqualStrings(max_action, doc.get("b").?.props.button.action);

    const rejected = try std.fmt.allocPrint(
        t.allocator,
        "{{\"root\":\"b\",\"components\":{{\"b\":{{\"type\":\"button\",\"text\":\"Go\",\"action\":\"{s}x\"}}}}}}",
        .{max_action},
    );
    defer t.allocator.free(rejected);
    try t.expectError(Error.TooBig, Document.parse(t.allocator, rejected, null));
}

test "patch: set, attach, remove, data, title, root" {
    var doc = try Document.parse(t.allocator, FULL_DOC, null);
    defer doc.deinit();
    const rev0 = doc.revision;

    // Add a component and attach it in the same patch (order-independent
    // thanks to deferred validation), update the progress bar, retitle.
    var applied = try doc.applyPatch(
        \\[
        \\ {"op":"set","id":"note2","component":{"type":"text","text":"LPIPS -0.01"}},
        \\ {"op":"set","id":"main","component":
        \\   {"type":"column","children":["h","cmp","ctrl","bar","note2"],"class":["card"]}},
        \\ {"op":"set","id":"bar","component":{"type":"progress","value":0.42,"label":"epoch 42/100"}},
        \\ {"op":"title","value":"Epoch 42"},
        \\ {"op":"data","key":"zoom","value":2},
        \\ {"op":"data","key":"note","value":null}
        \\]
    , null);
    defer applied.deinit();
    try t.expectEqual(@as(usize, 3), applied.set.len);
    try t.expect(applied.title_changed);
    try t.expectEqual(rev0 + 1, doc.revision);
    try t.expectEqualStrings("Epoch 42", doc.title);
    try t.expectEqual(@as(f64, 0.42), doc.get("bar").?.props.progress.value);
    try t.expectEqual(@as(usize, 5), doc.get("main").?.props.column.children.len);
    try t.expectEqual(@as(f64, 2), doc.data.get("zoom").?.number);
    try t.expect(doc.data.get("note") == null);

    // Remove detaches from the parent automatically.
    var applied2 = try doc.applyPatch(
        \\[{"op":"remove","id":"note2"}]
    , null);
    defer applied2.deinit();
    try t.expectEqual(@as(usize, 1), applied2.removed.len);
    try t.expect(doc.get("note2") == null);
    try t.expectEqual(@as(usize, 4), doc.get("main").?.props.column.children.len);

    // Root swap to a staged component.
    var applied3 = try doc.applyPatch(
        \\[
        \\ {"op":"set","id":"empty","component":{"type":"column","children":[]}},
        \\ {"op":"root","id":"empty"}
        \\]
    , null);
    defer applied3.deinit();
    try t.expect(applied3.root_changed);
    try t.expectEqualStrings("empty", doc.root);
}

test "scene patches are transactional and removal detaches placements" {
    var doc = try Document.parse(t.allocator,
        \\{"root":"s","components":{
        \\ "s":{"type":"scene","width":100,"height":80,"children":[{"id":"a","x":0,"y":0,"width":20,"height":20},{"id":"b","x":20,"y":0,"width":20,"height":20}]},
        \\ "a":{"type":"text","text":"A"},
        \\ "b":{"type":"text_input","placeholder":"B"}}}
    , null);
    defer doc.deinit();

    var applied = try doc.applyPatch(
        \\[
        \\ {"op":"set","id":"s","component":{"type":"scene","width":120,"height":90,"children":[{"id":"b","x":-5,"y":7,"width":40,"height":30},{"id":"a","x":60,"y":7,"width":20,"height":20}]}},
        \\ {"op":"set","id":"b","component":{"type":"text_input","value":"ready","placeholder":"Type","clear_on_submit":true}}
        \\]
    , null);
    defer applied.deinit();
    try t.expectEqual(@as(usize, 2), applied.set.len);
    try t.expectEqualStrings("b", doc.get("s").?.props.scene.children[0].id);
    try t.expectEqual(@as(i32, -5), doc.get("s").?.props.scene.children[0].x);
    try t.expectEqualStrings("ready", doc.get("b").?.props.text_input.value);

    var removed = try doc.applyPatch("[{\"op\":\"remove\",\"id\":\"a\"}]", null);
    defer removed.deinit();
    try t.expectEqual(@as(usize, 1), doc.get("s").?.props.scene.children.len);
    try t.expectEqualStrings("b", doc.get("s").?.props.scene.children[0].id);

    const before = try doc.toJson(t.allocator);
    defer t.allocator.free(before);
    try t.expectError(Error.Cycle, doc.applyPatch(
        \\[{"op":"set","id":"s","component":{"type":"scene","width":120,"height":90,"children":[{"id":"b","x":0,"y":0,"width":10,"height":10},{"id":"b","x":10,"y":0,"width":10,"height":10}]}}]
    , null));
    const after = try doc.toJson(t.allocator);
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);
}

test "a failing patch rolls back completely" {
    var doc = try Document.parse(t.allocator, FULL_DOC, null);
    defer doc.deinit();
    const before = try doc.toJson(t.allocator);
    defer t.allocator.free(before);
    const rev0 = doc.revision;

    var diag = Diag{};
    // Second op is invalid (dangling child): the first op must not stick.
    try t.expectError(Error.BadRef, doc.applyPatch(
        \\[
        \\ {"op":"set","id":"h","component":{"type":"heading","text":"CHANGED","level":1}},
        \\ {"op":"set","id":"main","component":{"type":"column","children":["ghost"]}}
        \\]
    , &diag));
    try t.expect(std.mem.indexOf(u8, diag.msg(), "ghost") != null);
    // Removing the root is refused.
    try t.expectError(Error.BadRef, doc.applyPatch(
        \\[{"op":"remove","id":"main"}]
    , &diag));
    // Unknown op.
    try t.expectError(Error.Malformed, doc.applyPatch(
        \\[{"op":"transmogrify","id":"h"}]
    , &diag));

    try t.expectEqual(rev0, doc.revision);
    const after = try doc.toJson(t.allocator);
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);
}

test "id, class, and path validators" {
    try t.expect(validId("main"));
    try t.expect(validId("a-b.c_9"));
    try t.expect(!validId(""));
    try t.expect(!validId("-lead"));
    try t.expect(!validId(".lead"));
    try t.expect(!validId("has space"));
    try t.expect(!validId("x" ** 65));
    try t.expect(validClass("dim"));
    try t.expect(!validClass("blink"));
    try t.expect(validImagePath("/tmp/a.png"));
    try t.expect(!validImagePath("a.png"));
    try t.expect(!validImagePath("/a/../b.png"));
    try t.expect(!validImagePath("/a\nb.png"));
    try t.expect(!validImagePath(""));
}
