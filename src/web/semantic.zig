//! Semantic layer bookkeeping for the browser helper: the shadow tree,
//! stable protocol ids, delta computation and the agent-facing text
//! format of docs/proposal-browser-protocol.md.
//!
//! CEF-FREE by construction (std only), because the whole point of the
//! design is that an engine which can only produce FULL trees still
//! yields the same deltas: the injected script re-walks the DOM and
//! sends everything it sees, and every "what changed" answer is computed
//! here. A future Servo/Ladybird helper reuses this file untouched.
//!
//! Engine-local ids (`InNode.id`) belong to one document: the injected
//! script's WeakMap counter restarts whenever a fresh V8 context is
//! created. Stable ids are allocated here, never reused within a view,
//! and CARRIED across a navigation by bottom-up subtree fingerprinting.

const std = @import("std");

/// Detail levels a `sem_snapshot_req` may ask for; the injected script
/// clamps text to `nameClamp` and reports the pre-clamp length so the
/// truncation marker can be rendered here.
pub const detail_minimal: u8 = 0;
pub const detail_normal: u8 = 1;
pub const detail_full_text: u8 = 2;

/// Characters of a node name sent at each detail level.
pub fn nameClamp(detail: u8) u32 {
    return switch (detail) {
        detail_minimal => 40,
        detail_full_text => 4000,
        else => 160,
    };
}

/// A carry ratio below this after a navigation means the two documents
/// have little in common and a delta would be noise: send a full tree.
const carry_full_num = 1;
const carry_full_den = 4;

/// One node exactly as the injected script reports it; field names are
/// the JSON keys on the wire between helper and script.
pub const InNode = struct {
    id: u32,
    parent: u32 = 0,
    role: []const u8 = "",
    name: []const u8 = "",
    value: []const u8 = "",
    states: []const u8 = "",
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    /// Length of the untruncated name text, so truncation is visible.
    full: u32 = 0,
};

/// A whole DOM walk; `doc` is the script's per-V8-context token, which
/// changes on every navigation and is how a new document is detected.
pub const InTree = struct {
    doc: u32 = 0,
    url: []const u8 = "",
    nodes: []const InNode = &.{},
};

pub const Kind = enum(u8) { full = 0, delta = 1 };

/// The result of folding one walk into the shadow tree; `text` is owned
/// by the caller and `changes` is zero when nothing is worth sending.
pub const Update = struct {
    kind: Kind,
    doc_gen: u32,
    rev: u32,
    text: []u8,
    changes: usize,
    carried: usize,
};

/// A node as last sent to the client.
const Node = struct {
    sid: u32,
    eid: u32,
    parent_sid: u32,
    depth: u16,
    role: []u8,
    name: []u8,
    value: []u8,
    states: []u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    /// Untruncated name length and the number of characters actually
    /// sent — the per-node verbosity state the no-duplicates rule needs.
    full: u32,
    sent: u32,
    fp: u64,
    nchildren: u32,
};

/// Parse a walk emitted by the injected script.
pub fn parseTree(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed(InTree) {
    return std.json.parseFromSlice(InTree, gpa, json, .{ .ignore_unknown_fields = true });
}

/// The shadow tree of one protocol view.
pub const View = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    doc_gen: u32 = 0,
    rev: u32 = 0,
    next_sid: u32 = 1,
    /// The script's context token for the document the shadow holds.
    doc_token: u32 = 0,
    url: []u8 = &.{},
    has_tree: bool = false,

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *View) void {
        for (self.nodes.items) |*n| self.freeNode(n);
        self.nodes.deinit(self.gpa);
        if (self.url.len != 0) self.gpa.free(self.url);
        self.url = &.{};
    }

    fn freeNode(self: *View, n: *Node) void {
        self.gpa.free(n.role);
        self.gpa.free(n.name);
        self.gpa.free(n.value);
        self.gpa.free(n.states);
    }

    /// Engine-local id backing `sid`, for routing an action to the
    /// script; 0 when the id is not in the tree as last sent.
    pub fn eidFor(self: *const View, sid: u32) u32 {
        for (self.nodes.items) |n| {
            if (n.sid == sid) return n.eid;
        }
        return 0;
    }

    /// Stable id of an engine-local id, or 0 when unseen.
    pub fn sidFor(self: *const View, eid: u32) u32 {
        for (self.nodes.items) |n| {
            if (n.eid == eid) return n.sid;
        }
        return 0;
    }

    pub fn count(self: *const View) usize {
        return self.nodes.items.len;
    }

    /// Fold one walk into the shadow tree and render what to send.
    ///
    /// `force_full` is the client's mode=1; a full tree is also sent
    /// when nothing was sent yet, when a navigation carried too little,
    /// or when the delta would have as many lines as the tree itself.
    pub fn apply(self: *View, in: InTree, force_full: bool) !Update {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const n = in.nodes.len;
        const new_doc = !self.has_tree or in.doc != self.doc_token;

        // Index the walk by engine-local id: parents are referenced by
        // id and, being a document-order walk, always precede children.
        var by_eid = std.AutoHashMap(u32, usize).init(arena);
        for (in.nodes, 0..) |nd, i| try by_eid.put(nd.id, i);

        const parents = try arena.alloc(usize, n); // n = no parent
        const depths = try arena.alloc(u16, n);
        const nkids = try arena.alloc(u32, n);
        @memset(nkids, 0);
        for (in.nodes, 0..) |nd, i| {
            const p = by_eid.get(nd.parent);
            if (p != null and p.? < i) {
                parents[i] = p.?;
                depths[i] = depths[p.?] +| 1;
                nkids[p.?] += 1;
            } else {
                parents[i] = n;
                depths[i] = 0;
            }
        }

        const fps = try arena.alloc(u64, n);
        try fingerprints(arena, in.nodes, parents, fps);

        // Stable-id assignment.
        const sids = try arena.alloc(u32, n);
        @memset(sids, 0);
        var carried: usize = 0;
        if (!new_doc) {
            for (in.nodes, 0..) |nd, i| sids[i] = self.sidFor(nd.id);
        } else if (self.has_tree) {
            carried = try self.carrySubtrees(arena, in.nodes, parents, fps, sids);
        }
        for (sids) |*s| {
            if (s.* != 0) continue;
            s.* = self.next_sid;
            self.next_sid += 1;
        }

        // Delta records, captured against the OLD shadow before it goes.
        var added: std.ArrayList(usize) = .empty; // index into in.nodes
        var changed: std.ArrayList(Change) = .empty;
        var removed: std.ArrayList(Gone) = .empty;
        var carry_lo: u32 = 0;
        var carry_hi: u32 = 0;

        for (in.nodes, 0..) |nd, i| {
            const old = self.findSid(sids[i]);
            if (old == null) {
                try added.append(arena, i);
                continue;
            }
            const o = old.?;
            if (new_doc) {
                if (carry_lo == 0 or sids[i] < carry_lo) carry_lo = sids[i];
                if (sids[i] > carry_hi) carry_hi = sids[i];
            }
            var ch = Change{ .index = i, .sid = sids[i] };
            ch.role = !std.mem.eql(u8, o.role, nd.role);
            ch.name = !std.mem.eql(u8, o.name, nd.name);
            ch.value = !std.mem.eql(u8, o.value, nd.value);
            ch.states = !std.mem.eql(u8, o.states, nd.states);
            if (ch.role or ch.name or ch.value or ch.states) try changed.append(arena, ch);
        }
        for (self.nodes.items) |o| {
            var still = false;
            for (sids) |s| {
                if (s == o.sid) {
                    still = true;
                    break;
                }
            }
            if (still) continue;
            try removed.append(arena, .{
                .sid = o.sid,
                .role = try arena.dupe(u8, o.role),
                .name = try arena.dupe(u8, o.name),
            });
        }

        const changes = added.items.len + changed.items.len + removed.items.len;
        var kind: Kind = .delta;
        if (force_full or !self.has_tree) {
            kind = .full;
        } else if (new_doc and carried * carry_full_den < n * carry_full_num) {
            kind = .full;
        } else if (n != 0 and changes >= n) {
            kind = .full;
        }

        const from_rev = self.rev;
        self.rev += 1;
        if (new_doc) {
            self.doc_gen += 1;
            self.doc_token = in.doc;
        }
        const new_url = try self.gpa.dupe(u8, in.url);
        if (self.url.len != 0) self.gpa.free(self.url);
        self.url = new_url;

        // Swap the shadow in; the render below reads the NEW tree for a
        // full snapshot and the arena-captured records for a delta.
        const fresh = try self.buildNodes(in, sids, parents, depths, nkids, fps, n);
        for (self.nodes.items) |*old| self.freeNode(old);
        self.nodes.deinit(self.gpa);
        self.nodes = fresh;
        self.has_tree = true;

        const text = if (kind == .full)
            try self.renderFull()
        else
            try self.renderDelta(from_rev, in.nodes, sids, added.items, changed.items, removed.items, if (new_doc) carried else 0, carry_lo, carry_hi);

        return .{
            .kind = kind,
            .doc_gen = self.doc_gen,
            .rev = self.rev,
            .text = text,
            .changes = changes,
            .carried = carried,
        };
    }

    fn findSid(self: *const View, sid: u32) ?Node {
        if (sid == 0) return null;
        for (self.nodes.items) |n| {
            if (n.sid == sid) return n;
        }
        return null;
    }

    fn buildNodes(
        self: *View,
        in: InTree,
        sids: []const u32,
        parents: []const usize,
        depths: []const u16,
        nkids: []const u32,
        fps: []const u64,
        n: usize,
    ) !std.ArrayList(Node) {
        var out: std.ArrayList(Node) = .empty;
        errdefer {
            for (out.items) |*x| self.freeNode(x);
            out.deinit(self.gpa);
        }
        try out.ensureTotalCapacity(self.gpa, n);
        for (in.nodes, 0..) |nd, i| {
            const sent: u32 = @intCast(nd.name.len);
            out.appendAssumeCapacity(.{
                .sid = sids[i],
                .eid = nd.id,
                .parent_sid = if (parents[i] < n) sids[parents[i]] else 0,
                .depth = depths[i],
                .role = try self.gpa.dupe(u8, nd.role),
                .name = try self.gpa.dupe(u8, nd.name),
                .value = try self.gpa.dupe(u8, nd.value),
                .states = try self.gpa.dupe(u8, nd.states),
                .x = nd.x,
                .y = nd.y,
                .w = nd.w,
                .h = nd.h,
                .full = @max(nd.full, sent),
                .sent = sent,
                .fp = fps[i],
                .nchildren = nkids[i],
            });
        }
        return out;
    }

    /// Carry stable ids onto identical subtrees of a NEW document.
    ///
    /// Matching is by fingerprint and top-down: the first (outermost)
    /// unused old node with the same fingerprint wins, and its children
    /// pair positionally — equal fingerprints mean equal subtrees, so
    /// the pairing cannot drift. Returns the number of nodes carried.
    fn carrySubtrees(
        self: *View,
        arena: std.mem.Allocator,
        nodes: []const InNode,
        parents: []const usize,
        fps: []const u64,
        sids: []u32,
    ) !usize {
        const n = nodes.len;
        const m = self.nodes.items.len;
        const used = try arena.alloc(bool, m);
        @memset(used, false);

        // Children lists on both sides, in document order.
        const new_kids = try childLists(arena, n, parents, n);
        const old_parents = try arena.alloc(usize, m);
        for (self.nodes.items, 0..) |o, i| {
            old_parents[i] = m;
            if (o.parent_sid == 0) continue;
            for (self.nodes.items, 0..) |p, j| {
                if (p.sid == o.parent_sid) {
                    old_parents[i] = j;
                    break;
                }
            }
        }
        const old_kids = try childLists(arena, m, old_parents, m);

        var carried: usize = 0;
        for (0..n) |i| {
            if (sids[i] != 0) continue;
            var match: ?usize = null;
            for (0..m) |j| {
                if (used[j] or self.nodes.items[j].fp != fps[i]) continue;
                match = j;
                break;
            }
            const j = match orelse continue;
            carried += self.pair(i, j, sids, used, new_kids, old_kids);
        }
        return carried;
    }

    fn pair(
        self: *View,
        i: usize,
        j: usize,
        sids: []u32,
        used: []bool,
        new_kids: []const []const usize,
        old_kids: []const []const usize,
    ) usize {
        sids[i] = self.nodes.items[j].sid;
        used[j] = true;
        var carried: usize = 1;
        const nk = new_kids[i];
        const ok = old_kids[j];
        const shared = @min(nk.len, ok.len);
        for (0..shared) |k| {
            carried += self.pair(nk[k], ok[k], sids, used, new_kids, old_kids);
        }
        return carried;
    }

    // -- rendering -----------------------------------------------------

    /// The full-tree text format: header plus one indented line per node.
    pub fn renderFull(self: *const View) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        const w = &out.writer;
        try w.print("doc {d} rev {d} url {s}\n", .{ self.doc_gen, self.rev, self.url });
        for (self.nodes.items) |nd| {
            try w.splatByteAll(' ', @as(usize, nd.depth) * 2);
            try writeNodeLine(w, nd);
            try w.writeByte('\n');
        }
        return self.gpa.dupe(u8, out.written());
    }

    /// A full snapshot restricted to one subtree.
    ///
    /// The shadow tree stays WHOLE either way — a scoped request only
    /// narrows what is rendered, so ids and later deltas keep meaning
    /// the same thing.
    pub fn renderScoped(self: *const View, root_sid: u32) ![]u8 {
        const root = self.findSid(root_sid) orelse return self.renderFull();
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        const w = &out.writer;
        try w.print("doc {d} rev {d} url {s} scope [{d}]\n", .{ self.doc_gen, self.rev, self.url, root_sid });
        for (self.nodes.items) |nd| {
            if (nd.sid != root_sid and !self.descends(nd, root_sid)) continue;
            try w.splatByteAll(' ', @as(usize, nd.depth -| root.depth) * 2);
            try writeNodeLine(w, nd);
            try w.writeByte('\n');
        }
        return self.gpa.dupe(u8, out.written());
    }

    fn renderDelta(
        self: *const View,
        from_rev: u32,
        nodes: []const InNode,
        sids: []const u32,
        added: []const usize,
        changed: []const Change,
        removed: []const Gone,
        carried: usize,
        carry_lo: u32,
        carry_hi: u32,
    ) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        const w = &out.writer;
        try w.print("delta rev {d}->{d}\n", .{ from_rev, self.rev });
        if (carried != 0) {
            try w.print("carried [{d}..{d}] {d} nodes\n", .{ carry_lo, carry_hi, carried });
        }
        var last_parent: u32 = 0;
        for (added) |i| {
            const nd = self.findSid(sids[i]) orelse continue;
            if (nd.parent_sid != 0 and nd.parent_sid != last_parent) {
                if (self.findSid(nd.parent_sid)) |p| {
                    try w.print("under [{d}] {s} \"{s}\"\n", .{ p.sid, p.role, p.name });
                }
                last_parent = nd.parent_sid;
            }
            try w.writeAll("+ ");
            try writeNodeLine(w, nd);
            try w.writeByte('\n');
        }
        for (removed) |g| {
            try w.print("- [{d}] {s} \"{s}\"\n", .{ g.sid, g.role, g.name });
        }
        for (changed) |ch| {
            const nd = nodes[ch.index];
            try w.print("~ [{d}] {s} \"{s}\"", .{ ch.sid, nd.role, nd.name });
            if (ch.role) try w.print(" role={s}", .{nd.role});
            if (ch.name) try w.print(" name=\"{s}\"", .{nd.name});
            if (ch.value) try w.print(" value=\"{s}\"", .{nd.value});
            if (ch.states) try w.print(" states=({s})", .{nd.states});
            try w.writeByte('\n');
        }
        return self.gpa.dupe(u8, out.written());
    }

    /// Answer a `sem_query` from the tree AS LAST SENT — deliberately
    /// not a fresh walk, so a query never costs a DOM traversal and
    /// never invents ids the client has not seen.
    pub fn query(self: *const View, kind: u8, arg: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        const w = &out.writer;
        if (!self.has_tree) {
            try w.writeAll("query no snapshot yet\n");
            return self.gpa.dupe(u8, out.written());
        }
        switch (kind) {
            1 => {
                const root_sid = std.fmt.parseInt(u32, std.mem.trim(u8, arg, " \t"), 10) catch 0;
                const root = self.findSid(root_sid) orelse {
                    try w.print("query subtree [{d}] unknown id\n", .{root_sid});
                    return self.gpa.dupe(u8, out.written());
                };
                try w.print("query subtree [{d}]\n", .{root_sid});
                var emitted: usize = 0;
                for (self.nodes.items) |nd| {
                    if (nd.sid != root_sid and !self.descends(nd, root_sid)) continue;
                    const rel = nd.depth -| root.depth;
                    try w.splatByteAll(' ', @as(usize, rel) * 2);
                    try writeNodeLine(w, nd);
                    try w.writeByte('\n');
                    emitted += 1;
                }
                if (emitted == 0) try w.writeAll("no nodes\n");
            },
            2 => {
                try w.writeAll("query focused\n");
                var found = false;
                for (self.nodes.items) |nd| {
                    if (!hasState(nd.states, "focused")) continue;
                    try writeNodeLine(w, nd);
                    try w.writeByte('\n');
                    found = true;
                }
                if (!found) try w.writeAll("no focused node\n");
            },
            else => {
                var hits: usize = 0;
                var body: std.Io.Writer.Allocating = .init(self.gpa);
                defer body.deinit();
                for (self.nodes.items) |nd| {
                    if (!containsFold(nd.name, arg) and !containsFold(nd.value, arg)) continue;
                    try writeNodeLine(&body.writer, nd);
                    try body.writer.writeByte('\n');
                    hits += 1;
                }
                try w.print("query find \"{s}\" {d} matches\n", .{ arg, hits });
                try w.writeAll(body.written());
            },
        }
        return self.gpa.dupe(u8, out.written());
    }

    fn descends(self: *const View, nd: Node, root_sid: u32) bool {
        var cur = nd.parent_sid;
        var guard: usize = 0;
        while (cur != 0 and guard < 512) : (guard += 1) {
            if (cur == root_sid) return true;
            const p = self.findSid(cur) orelse return false;
            cur = p.parent_sid;
        }
        return false;
    }
};

const Change = struct {
    index: usize,
    sid: u32,
    role: bool = false,
    name: bool = false,
    value: bool = false,
    states: bool = false,
};

const Gone = struct { sid: u32, role: []u8, name: []u8 };

/// `[id] role "name" (states) value="..." {n children}`, with the
/// truncation marker when the script clamped the name.
fn writeNodeLine(w: *std.Io.Writer, nd: Node) !void {
    try w.print("[{d}] {s}", .{ nd.sid, nd.role });
    if (nd.name.len != 0 or nd.full > nd.sent) {
        if (nd.full > nd.sent) {
            try w.print(" \"{s}...\" (+{d} chars, expand [{d}])", .{ nd.name, nd.full - nd.sent, nd.sid });
        } else {
            try w.print(" \"{s}\"", .{nd.name});
        }
    }
    if (nd.states.len != 0) try w.print(" ({s})", .{nd.states});
    if (nd.value.len != 0) try w.print(" value=\"{s}\"", .{nd.value});
    if (nd.nchildren != 0) try w.print(" {{{d} children}}", .{nd.nchildren});
}

/// Bottom-up fingerprints: hash(role, name, value, child fingerprints).
/// A document-order walk lists children after their parent, so a
/// reverse pass sees every child before its parent.
fn fingerprints(arena: std.mem.Allocator, nodes: []const InNode, parents: []const usize, out: []u64) !void {
    const n = nodes.len;
    const kids = try arena.alloc(u64, n);
    @memset(kids, 0);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var h = std.hash.Wyhash.init(0);
        h.update(nodes[i].role);
        h.update(nodes[i].name);
        h.update(nodes[i].value);
        h.update(std.mem.asBytes(&kids[i]));
        out[i] = h.final();
        if (parents[i] < n) {
            // Order-sensitive fold: a reordered child list is a change.
            kids[parents[i]] = kids[parents[i]] *% 0x9e3779b97f4a7c15 ^ out[i];
        }
    }
}

/// Children of every node, in document order.
fn childLists(arena: std.mem.Allocator, n: usize, parents: []const usize, none: usize) ![][]const usize {
    const counts = try arena.alloc(usize, n);
    @memset(counts, 0);
    for (parents[0..n]) |p| {
        if (p < none) counts[p] += 1;
    }
    const lists = try arena.alloc([]const usize, n);
    const store = try arena.alloc([]usize, n);
    for (0..n) |i| store[i] = try arena.alloc(usize, counts[i]);
    @memset(counts, 0);
    for (parents[0..n], 0..) |p, i| {
        if (p >= none) continue;
        store[p][counts[p]] = i;
        counts[p] += 1;
    }
    for (0..n) |i| lists[i] = store[i];
    return lists;
}

fn hasState(states: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, states, ',');
    while (it.next()) |s| {
        if (std.mem.eql(u8, std.mem.trim(u8, s, " "), want)) return true;
    }
    return false;
}

/// ASCII case-insensitive substring test; an empty needle matches.
fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= hay.len) : (i += 1) {
        for (needle, 0..) |ch, k| {
            if (std.ascii.toLower(hay[i + k]) != std.ascii.toLower(ch)) continue :outer;
        }
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

fn tree(doc: u32, url: []const u8, nodes: []const InNode) InTree {
    return .{ .doc = doc, .url = url, .nodes = nodes };
}

test "full snapshot renders the documented text format" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const nodes = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "Hello" },
        .{ .id = 3, .parent = 1, .role = "button", .name = "Go", .states = "focused" },
        .{ .id = 4, .parent = 1, .role = "textbox", .name = "Name", .value = "abc" },
    };
    const up = try v.apply(tree(7, "http://x/", &nodes), false);
    defer gpa.free(up.text);
    try std.testing.expectEqual(Kind.full, up.kind);
    try std.testing.expectEqualStrings(
        \\doc 1 rev 1 url http://x/
        \\[1] document "Demo" {3 children}
        \\  [2] heading "Hello"
        \\  [3] button "Go" (focused)
        \\  [4] textbox "Name" value="abc"
        \\
    , up.text);
}

test "ids are stable across a delta and a removal never reuses one" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const first = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "Hello" },
        .{ .id = 3, .parent = 1, .role = "paragraph", .name = "before" },
    };
    var up = try v.apply(tree(7, "http://x/", &first), false);
    gpa.free(up.text);
    const heading = v.sidFor(2);
    const para = v.sidFor(3);
    try std.testing.expect(heading != 0 and para != 0);

    // A changed paragraph: same engine id, so the same stable id, and
    // the delta must mention nothing else.
    const second = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "Hello" },
        .{ .id = 3, .parent = 1, .role = "paragraph", .name = "after" },
    };
    up = try v.apply(tree(7, "http://x/", &second), false);
    defer gpa.free(up.text);
    try std.testing.expectEqual(Kind.delta, up.kind);
    try std.testing.expectEqual(heading, v.sidFor(2));
    try std.testing.expectEqual(para, v.sidFor(3));
    try std.testing.expect(std.mem.indexOf(u8, up.text, "~ [") != null);
    try std.testing.expect(std.mem.indexOf(u8, up.text, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, up.text, "Hello") == null);

    // Dropping the paragraph and adding one back must mint a new id.
    const third = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "Hello" },
    };
    const up3 = try v.apply(tree(7, "http://x/", &third), false);
    gpa.free(up3.text);
    const fourth = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "Hello" },
        .{ .id = 9, .parent = 1, .role = "paragraph", .name = "after" },
    };
    const up4 = try v.apply(tree(7, "http://x/", &fourth), false);
    gpa.free(up4.text);
    try std.testing.expect(v.sidFor(9) != para);
    try std.testing.expectEqual(@as(u32, 0), v.eidFor(para));
}

test "a navigation carries ids for an identical subtree" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    // A nav block plus one content node; the nav dominates, so the
    // overlap heuristic keeps the answer a delta.
    const page1 = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "One" },
        .{ .id = 2, .parent = 1, .role = "navigation", .name = "Site" },
        .{ .id = 3, .parent = 2, .role = "link", .name = "Home" },
        .{ .id = 4, .parent = 2, .role = "link", .name = "Docs" },
        .{ .id = 5, .parent = 2, .role = "link", .name = "About" },
        .{ .id = 6, .parent = 1, .role = "paragraph", .name = "page one" },
    };
    var up = try v.apply(tree(11, "http://x/1", &page1), false);
    gpa.free(up.text);
    const nav = v.sidFor(2);
    const home = v.sidFor(3);

    // Same nav block, fresh engine ids (new V8 context), new content.
    const page2 = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "One" },
        .{ .id = 2, .parent = 1, .role = "navigation", .name = "Site" },
        .{ .id = 3, .parent = 2, .role = "link", .name = "Home" },
        .{ .id = 4, .parent = 2, .role = "link", .name = "Docs" },
        .{ .id = 5, .parent = 2, .role = "link", .name = "About" },
        .{ .id = 6, .parent = 1, .role = "paragraph", .name = "page two" },
    };
    up = try v.apply(tree(12, "http://x/2", &page2), false);
    defer gpa.free(up.text);
    try std.testing.expectEqual(Kind.delta, up.kind);
    try std.testing.expectEqual(nav, v.sidFor(2));
    try std.testing.expectEqual(home, v.sidFor(3));
    try std.testing.expect(up.carried >= 4);
    try std.testing.expect(std.mem.indexOf(u8, up.text, "carried [") != null);
    try std.testing.expectEqual(@as(u32, 2), v.doc_gen);
}

test "a navigation with no overlap falls back to a full snapshot" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const page1 = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "One" },
        .{ .id = 2, .parent = 1, .role = "paragraph", .name = "alpha" },
        .{ .id = 3, .parent = 1, .role = "paragraph", .name = "beta" },
        .{ .id = 4, .parent = 1, .role = "paragraph", .name = "gamma" },
    };
    var up = try v.apply(tree(11, "http://x/1", &page1), false);
    gpa.free(up.text);

    const page2 = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "article", .name = "Two" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "delta" },
        .{ .id = 3, .parent = 1, .role = "link", .name = "epsilon" },
        .{ .id = 4, .parent = 1, .role = "button", .name = "zeta" },
    };
    up = try v.apply(tree(12, "http://x/2", &page2), false);
    defer gpa.free(up.text);
    try std.testing.expectEqual(Kind.full, up.kind);
    try std.testing.expect(std.mem.startsWith(u8, up.text, "doc 2 rev 2 url http://x/2"));
}

test "truncation bookkeeping survives a detail-level change" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const clamped = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "paragraph", .name = "the beginning", .full = 513 },
    };
    const up = try v.apply(tree(7, "http://x/", &clamped), false);
    defer gpa.free(up.text);
    const sid = v.sidFor(2);
    var marker: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&marker, "(+500 chars, expand [{d}])", .{sid});
    try std.testing.expect(std.mem.indexOf(u8, up.text, want) != null);

    // Re-sent at full-text detail: the marker goes and the delta says
    // the name changed, which is exactly the no-duplicates contract.
    const whole = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "paragraph", .name = "the beginning and the rest" },
    };
    const up2 = try v.apply(tree(7, "http://x/", &whole), false);
    defer gpa.free(up2.text);
    try std.testing.expectEqual(Kind.delta, up2.kind);
    try std.testing.expect(std.mem.indexOf(u8, up2.text, "chars, expand") == null);
    try std.testing.expect(std.mem.indexOf(u8, up2.text, "name=\"the beginning and the rest\"") != null);
}

test "queries read the tree as last sent" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const nodes = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "navigation", .name = "Site" },
        .{ .id = 3, .parent = 2, .role = "link", .name = "Documentation" },
        .{ .id = 4, .parent = 1, .role = "textbox", .name = "Name", .states = "focused" },
    };
    const up = try v.apply(tree(7, "http://x/", &nodes), false);
    gpa.free(up.text);

    const find = try v.query(0, "docum");
    defer gpa.free(find);
    try std.testing.expect(std.mem.startsWith(u8, find, "query find \"docum\" 1 matches"));
    try std.testing.expect(std.mem.indexOf(u8, find, "Documentation") != null);

    var buf: [16]u8 = undefined;
    const sub = try v.query(1, try std.fmt.bufPrint(&buf, "{d}", .{v.sidFor(2)}));
    defer gpa.free(sub);
    try std.testing.expect(std.mem.indexOf(u8, sub, "Documentation") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub, "textbox") == null);

    const focused = try v.query(2, "");
    defer gpa.free(focused);
    try std.testing.expect(std.mem.indexOf(u8, focused, "textbox \"Name\"") != null);
}

test "a walk parses from the injected script's JSON" {
    const gpa = std.testing.allocator;
    const json =
        \\{"doc":42,"url":"http://x/","nodes":[
        \\{"id":1,"parent":0,"role":"document","name":"Demo"},
        \\{"id":2,"parent":1,"role":"button","name":"Go","states":"disabled","x":4,"y":8,"w":40,"h":20}]}
    ;
    const parsed = try parseTree(gpa, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 42), parsed.value.doc);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.nodes.len);
    try std.testing.expectEqualStrings("disabled", parsed.value.nodes[1].states);
    try std.testing.expectEqual(@as(i32, 40), parsed.value.nodes[1].w);
}
