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
//! The same fingerprint match runs WITHIN a document, anchored to a
//! matched parent, so a page that rebuilds identical rows under fresh
//! DOM nodes keeps their ids instead of minting churn.
//!
//! ## Live tree vs consumed base
//!
//! `apply` folds EVERY walk (solicited or the MutationObserver's) into
//! the LIVE tree, so ids, engine-id routing and queries stay fresh —
//! but nothing is sent for a spontaneous walk. What the client has
//! actually SEEN is the separate `base` copy, advanced only by
//! `consume`: a snapshot request answers with ONE delta from the base
//! straight to the live tree, so churn that appeared and vanished in
//! between cancels out instead of being replayed revision by revision.
//! The replay is still available on request (`Mode.history`) from the
//! bounded per-revision `hist` buffer.

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

/// Bound on the stored per-revision replay; past it the oldest content
/// is already gone, so a marker says so instead of lying by omission.
const MAX_HISTORY = 64 * 1024;
pub const HISTORY_OVERFLOW = "... earlier changes dropped (history buffer full); ask for mode=full\n";

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
    /// Resolved link target (anchors only, absent otherwise). Not part
    /// of the fingerprint or the delta comparison: a href swap under
    /// identical text keeps the id, and hints/new-tab read the LIVE
    /// tree anyway.
    url: []const u8 = "",
    /// Bounded renderer-local token changed whenever an anchor's exact
    /// raw href changes, kept separate from the display URL clamp.
    guard: []const u8 = "",
};

/// A whole DOM walk; `doc` is the script's per-V8-context token, which
/// changes on every navigation and is how a new document is detected.
pub const InTree = struct {
    doc: u32 = 0,
    url: []const u8 = "",
    nodes: []const InNode = &.{},
};

pub const Kind = enum(u8) { full = 0, delta = 1 };

/// What a `consume` answers with. Mirrors `proto.SnapMode` values.
pub const Mode = enum(u8) { auto = 0, full = 1, history = 2 };

/// The result of consuming the view state; `text` is owned by the
/// caller.
pub const Update = struct {
    kind: Kind,
    doc_gen: u32,
    rev: u32,
    text: []u8,
    changes: usize,
    carried: usize,
};

/// One page-side reader entity before its engine-local id is rewritten
/// into this view's stable semantic identity space.
pub const InReaderEntity = struct {
    eid: u32,
    kind: []const u8 = "",
    text: []const u8 = "",
    url: []const u8 = "",
};

pub const InReader = struct {
    doc: u32,
    md: []const u8 = "",
    entities: []const InReaderEntity = &.{},
};

/// A revision-stamped reader result. Entity strings borrow from the
/// parsed page reply; only the entity slice is owned by the caller.
pub const ReaderResult = struct {
    doc_gen: u32,
    rev: u32,
    markdown: []const u8,
    entities: []ReaderEntity,
};

pub const ReaderEntity = struct {
    id: u32,
    guard: u64,
    kind: []const u8,
    text: []const u8,
    url: []const u8,
};

/// A node of the live tree.
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
    /// Resolved link target; empty for everything but anchors.
    url: []u8,
    guard: []u8,
};

/// A node as the CLIENT last received it: just enough to diff against
/// and to describe a removal.
const BaseNode = struct {
    sid: u32,
    role: []u8,
    name: []u8,
    value: []u8,
    states: []u8,
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

    /// The tree as last CONSUMED (sent to the client); the diff base.
    base: std.ArrayList(BaseNode) = .empty,
    base_rev: u32 = 0,
    base_doc_gen: u32 = 0,
    base_ok: bool = false,
    /// Rendered per-revision deltas since the last consume, oldest
    /// first — today's replay, kept for `Mode.history`.
    hist: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) View {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *View) void {
        for (self.nodes.items) |*n| self.freeNode(n);
        self.nodes.deinit(self.gpa);
        for (self.base.items) |*b| self.freeBase(b);
        self.base.deinit(self.gpa);
        self.hist.deinit(self.gpa);
        if (self.url.len != 0) self.gpa.free(self.url);
        self.url = &.{};
    }

    /// Forget the current document without reusing its stable ids or
    /// document generation when the browser later produces a new one.
    pub fn invalidateDocument(self: *View) void {
        const next_sid = self.next_sid;
        const doc_gen = self.doc_gen;
        const gpa = self.gpa;
        self.deinit();
        self.* = init(gpa);
        self.next_sid = next_sid;
        self.doc_gen = doc_gen;
    }

    fn freeNode(self: *View, n: *Node) void {
        self.gpa.free(n.role);
        self.gpa.free(n.name);
        self.gpa.free(n.value);
        self.gpa.free(n.states);
        self.gpa.free(n.url);
        self.gpa.free(n.guard);
    }

    fn freeBase(self: *View, b: *BaseNode) void {
        self.gpa.free(b.role);
        self.gpa.free(b.name);
        self.gpa.free(b.value);
        self.gpa.free(b.states);
    }

    /// Engine-local id backing `sid`, for routing an action to the
    /// script; 0 when the id is not in the live tree. A truncation
    /// marker (role `more`) answers 0 too: no element exists behind
    /// it, so acting on one must refuse as "unknown id" rather than
    /// as a missing box.
    pub fn eidFor(self: *const View, sid: u32) u32 {
        for (self.nodes.items) |n| {
            if (n.sid == sid) return if (std.mem.eql(u8, n.role, "more")) 0 else n.eid;
        }
        return 0;
    }

    /// Role and name behind `sid`, so an action result can say WHAT it
    /// resolved to rather than only where it clicked. Slices borrow the
    /// live tree: use before the next apply.
    pub fn describe(self: *const View, sid: u32) ?struct { role: []const u8, name: []const u8 } {
        for (self.nodes.items) |n| {
            if (n.sid == sid) return .{ .role = n.role, .name = n.name };
        }
        return null;
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

    /// Rewrite a page-side reader reply into stable ids from the live
    /// shadow tree. A reply from any other document is stale and refused.
    pub fn readerResult(self: *const View, gpa: std.mem.Allocator, in: InReader) !ReaderResult {
        if (!self.has_tree or in.doc != self.doc_token) return error.StaleReaderDocument;
        var entities: std.ArrayList(ReaderEntity) = .empty;
        defer entities.deinit(gpa);
        try entities.ensureTotalCapacity(gpa, in.entities.len);
        for (in.entities) |entity| {
            const sid = self.sidFor(entity.eid);
            if (sid == 0) continue;
            entities.appendAssumeCapacity(.{
                .id = sid,
                .guard = self.actionGuard(sid),
                .kind = entity.kind,
                .text = entity.text,
                .url = entity.url,
            });
        }
        return .{
            .doc_gen = self.doc_gen,
            .rev = self.rev,
            .markdown = in.md,
            .entities = try gpa.dupe(ReaderEntity, entities.items),
        };
    }

    pub fn revisionMatches(self: *const View, doc_gen: u32, rev: u32) bool {
        return self.has_tree and self.doc_gen == doc_gen and self.rev == rev;
    }

    /// Action-sensitive identity for a stable id. Unlike the ordinary
    /// semantic fingerprint this includes a link's resolved target, so
    /// an href swap cannot pass a reader action guard.
    pub fn actionGuard(self: *const View, sid: u32) u64 {
        const nd = self.findSid(sid) orelse return 0;
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&nd.eid));
        h.update(nd.role);
        h.update(nd.name);
        h.update(nd.value);
        h.update(nd.url);
        h.update(nd.guard);
        return h.final();
    }

    /// Fold one walk into the LIVE tree. Nothing is rendered for the
    /// wire here: `consume` does that against the base on request. The
    /// per-revision delta is appended to the bounded `hist` buffer so
    /// `Mode.history` can still replay it.
    ///
    /// `rev` advances only when the walk actually changed something (or
    /// switched documents) — a re-walk of an unchanged page is free,
    /// which is also what lets a rev-polling idle wait settle.
    pub fn apply(self: *View, in: InTree) !void {
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
            // Fresh DOM nodes with old content: a re-render of the same
            // rows must keep their ids (anchored, so it cannot pair a
            // node into a different part of the page).
            if (self.has_tree) _ = try self.carryIntraDoc(arena, in.nodes, parents, fps, sids);
        } else if (self.has_tree) {
            carried = try self.carrySubtrees(arena, in.nodes, parents, fps, sids);
        }
        for (sids) |*s| {
            if (s.* != 0) continue;
            s.* = self.next_sid;
            self.next_sid += 1;
        }

        // Delta records, captured against the OLD live tree before it
        // goes.
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
        const from_rev = self.rev;
        if (changes != 0 or new_doc) self.rev += 1;
        if (new_doc) {
            self.doc_gen += 1;
            self.doc_token = in.doc;
        }
        const new_url = try self.gpa.dupe(u8, in.url);
        if (self.url.len != 0) self.gpa.free(self.url);
        self.url = new_url;

        // Swap the live tree in even when nothing changed: the walk may
        // carry fresh engine ids for identical content, and actions
        // route through them.
        const fresh = try self.buildNodes(in, sids, parents, depths, nkids, fps, n);
        for (self.nodes.items) |*old| self.freeNode(old);
        self.nodes.deinit(self.gpa);
        self.nodes = fresh;
        self.has_tree = true;

        if (changes == 0 and !new_doc) return;

        // Append this revision to the replay buffer. A navigation that
        // carried too little (or a delta as large as the tree) restates
        // the world, exactly as the old per-walk push did.
        var fold_full = false;
        if (new_doc and carried * carry_full_den < n * carry_full_num) {
            fold_full = true;
        } else if (n != 0 and changes >= n) {
            fold_full = true;
        }
        const text = if (fold_full)
            try self.renderFull()
        else
            try self.renderDelta(from_rev, in.nodes, sids, added.items, changed.items, removed.items, if (new_doc) carried else 0, carry_lo, carry_hi);
        defer self.gpa.free(text);
        if (fold_full) self.hist.clearRetainingCapacity();
        if (self.hist.items.len + text.len <= MAX_HISTORY) {
            try self.hist.appendSlice(self.gpa, text);
        } else if (!std.mem.endsWith(u8, self.hist.items, HISTORY_OVERFLOW)) {
            try self.hist.appendSlice(self.gpa, HISTORY_OVERFLOW);
        }
    }

    /// Render what the client is owed and advance the base to the live
    /// tree. `auto` is ONE coalesced delta base->live (never a replay of
    /// intermediate revisions); `history` is the stored replay;
    /// `full` — and any state where the client has never consumed this
    /// view — restates the whole tree.
    pub fn consume(self: *View, mode: Mode) !Update {
        var kind: Kind = .full;
        var text: ?[]u8 = null;
        errdefer if (text) |t| self.gpa.free(t);
        var changes: usize = self.nodes.items.len;
        var carried: usize = 0;

        if (mode != .full and self.base_ok) {
            switch (mode) {
                .history => {
                    kind = .delta;
                    text = if (self.hist.items.len != 0)
                        try self.gpa.dupe(u8, self.hist.items)
                    else
                        try std.fmt.allocPrint(self.gpa, "delta rev {d}->{d}\n", .{ self.base_rev, self.rev });
                    changes = 0;
                },
                else => {
                    const co = try self.renderCoalesced();
                    changes = co.changes;
                    carried = co.carried;
                    if (!co.full) {
                        kind = .delta;
                        text = co.text;
                    } else {
                        self.gpa.free(co.text);
                    }
                },
            }
        }
        const out = text orelse try self.renderFull();
        try self.commitBase();
        return .{
            .kind = kind,
            .doc_gen = self.doc_gen,
            .rev = self.rev,
            .text = out,
            .changes = changes,
            .carried = carried,
        };
    }

    /// Deep-copy the live tree into the base and drop the replay: the
    /// client is now up to date with everything before this point.
    fn commitBase(self: *View) !void {
        for (self.base.items) |*b| self.freeBase(b);
        self.base.clearRetainingCapacity();
        try self.base.ensureTotalCapacity(self.gpa, self.nodes.items.len);
        for (self.nodes.items) |nd| {
            const role = try self.gpa.dupe(u8, nd.role);
            errdefer self.gpa.free(role);
            const name = try self.gpa.dupe(u8, nd.name);
            errdefer self.gpa.free(name);
            const value = try self.gpa.dupe(u8, nd.value);
            errdefer self.gpa.free(value);
            const states = try self.gpa.dupe(u8, nd.states);
            self.base.appendAssumeCapacity(.{
                .sid = nd.sid,
                .role = role,
                .name = name,
                .value = value,
                .states = states,
            });
        }
        self.base_rev = self.rev;
        self.base_doc_gen = self.doc_gen;
        self.base_ok = true;
        self.hist.clearRetainingCapacity();
    }

    const Coalesced = struct { text: []u8, changes: usize, carried: usize, full: bool };

    /// One delta from the base straight to the live tree. Falls back to
    /// a full restatement (`full = true`, text still owned) when a
    /// document change carried too little or the delta would rival the
    /// tree itself.
    fn renderCoalesced(self: *View) !Coalesced {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var base_by_sid = std.AutoHashMap(u32, usize).init(arena);
        for (self.base.items, 0..) |b, i| try base_by_sid.put(b.sid, i);
        var live_sids = std.AutoHashMap(u32, void).init(arena);
        for (self.nodes.items) |nd| try live_sids.put(nd.sid, {});

        var adds: usize = 0;
        var mods: usize = 0;
        var gone: usize = 0;
        var shared: usize = 0;
        var carry_lo: u32 = 0;
        var carry_hi: u32 = 0;
        for (self.nodes.items) |nd| {
            const bi = base_by_sid.get(nd.sid) orelse {
                adds += 1;
                continue;
            };
            shared += 1;
            if (carry_lo == 0 or nd.sid < carry_lo) carry_lo = nd.sid;
            if (nd.sid > carry_hi) carry_hi = nd.sid;
            const b = self.base.items[bi];
            if (!std.mem.eql(u8, b.role, nd.role) or !std.mem.eql(u8, b.name, nd.name) or
                !std.mem.eql(u8, b.value, nd.value) or !std.mem.eql(u8, b.states, nd.states))
            {
                mods += 1;
            }
        }
        for (self.base.items) |b| {
            if (!live_sids.contains(b.sid)) gone += 1;
        }

        const n = self.nodes.items.len;
        const changes = adds + mods + gone;
        const doc_moved = self.doc_gen != self.base_doc_gen;
        if (doc_moved and shared * carry_full_den < n * carry_full_num)
            return .{ .text = try self.renderFull(), .changes = changes, .carried = shared, .full = true };
        if (n != 0 and changes >= n)
            return .{ .text = try self.renderFull(), .changes = changes, .carried = shared, .full = true };

        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        const w = &out.writer;
        try w.print("delta rev {d}->{d}\n", .{ self.base_rev, self.rev });
        if (doc_moved and shared != 0) {
            try w.print("carried [{d}..{d}] {d} nodes\n", .{ carry_lo, carry_hi, shared });
        }
        var last_parent: u32 = 0;
        for (self.nodes.items) |nd| {
            if (base_by_sid.contains(nd.sid)) continue;
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
        for (self.base.items) |b| {
            if (live_sids.contains(b.sid)) continue;
            try w.print("- [{d}] {s} \"{s}\"\n", .{ b.sid, b.role, b.name });
        }
        for (self.nodes.items) |nd| {
            const bi = base_by_sid.get(nd.sid) orelse continue;
            const b = self.base.items[bi];
            const d_role = !std.mem.eql(u8, b.role, nd.role);
            const d_name = !std.mem.eql(u8, b.name, nd.name);
            const d_value = !std.mem.eql(u8, b.value, nd.value);
            const d_states = !std.mem.eql(u8, b.states, nd.states);
            if (!d_role and !d_name and !d_value and !d_states) continue;
            try w.print("~ [{d}] {s} \"{s}\"", .{ nd.sid, nd.role, nd.name });
            if (d_role) try w.print(" role={s}", .{nd.role});
            if (d_name) try w.print(" name=\"{s}\"", .{nd.name});
            if (d_value) try w.print(" value=\"{s}\"", .{nd.value});
            if (d_states) try w.print(" states=({s})", .{nd.states});
            try w.writeByte('\n');
        }
        return .{
            .text = try self.gpa.dupe(u8, out.written()),
            .changes = changes,
            .carried = shared,
            .full = false,
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
                .url = try self.gpa.dupe(u8, nd.url),
                .guard = try self.gpa.dupe(u8, nd.guard),
            });
        }
        return out;
    }

    /// Index of the old (live) node carrying `sid`, or null.
    fn oldIndexOfSid(self: *const View, sid: u32) ?usize {
        for (self.nodes.items, 0..) |o, j| {
            if (o.sid == sid) return j;
        }
        return null;
    }

    /// Parent indices and child lists of the OLD live tree, in document
    /// order; shared by both carry passes.
    fn oldChildLists(self: *const View, arena: std.mem.Allocator) ![][]const usize {
        const m = self.nodes.items.len;
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
        return childLists(arena, m, old_parents, m);
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

        const new_kids = try childLists(arena, n, parents, n);
        const old_kids = try self.oldChildLists(arena);

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

    /// Carry stable ids onto re-rendered subtrees WITHIN a document: a
    /// walk node with a fresh engine id keeps its predecessor's id when
    /// an identical (same fingerprint) old subtree sat under the SAME
    /// matched parent and is not claimed by a surviving engine id.
    ///
    /// The parent anchor is the safety property: two look-alike nodes
    /// in different parts of the page can never swap ids, so an action
    /// routed through a carried id cannot land elsewhere. Look-alikes
    /// under one parent pair in document order, and equal fingerprints
    /// mean equal subtrees, so whichever pairing is chosen names the
    /// same content.
    fn carryIntraDoc(
        self: *View,
        arena: std.mem.Allocator,
        nodes: []const InNode,
        parents: []const usize,
        fps: []const u64,
        sids: []u32,
    ) !usize {
        const n = nodes.len;
        const m = self.nodes.items.len;
        if (m == 0) return 0;
        const used = try arena.alloc(bool, m);
        @memset(used, false);
        // An old node whose engine id survived is spoken for.
        for (self.nodes.items, 0..) |o, j| {
            for (sids) |s| {
                if (s != 0 and s == o.sid) {
                    used[j] = true;
                    break;
                }
            }
        }

        const new_kids = try childLists(arena, n, parents, n);
        const old_kids = try self.oldChildLists(arena);

        var carried: usize = 0;
        for (0..n) |i| {
            if (sids[i] != 0) continue;
            const pi = parents[i];
            if (pi >= n or sids[pi] == 0) continue; // anchor required
            const oj = self.oldIndexOfSid(sids[pi]) orelse continue;
            for (old_kids[oj]) |cand| {
                if (used[cand] or self.nodes.items[cand].fp != fps[i]) continue;
                carried += self.pair(i, cand, sids, used, new_kids, old_kids);
                break;
            }
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
    /// narrows what is rendered and deliberately does NOT advance the
    /// consumed base (the caller saw one subtree, not the page), so ids
    /// and later deltas keep meaning the same thing.
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

    /// The link-hints answer: every interactive node of the LIVE tree
    /// whose box intersects the `vw` x `vh` viewport, one per line in a
    /// fixed tab-separated format the GUI overlay parses:
    ///
    ///   hints <count> vw <vw> vh <vh>
    ///   <sid>\t<x>\t<y>\t<w>\t<h>\t<role>\t<url>\t<name>
    ///
    /// Rects are the walk's viewport-relative CSS px. `url`/`name` are
    /// page-authored (untrusted), so any byte that would break the
    /// line/field framing is flattened to a space. Reads the live tree
    /// only — the caller is responsible for having folded a FRESH walk
    /// first, because scrolling moves every rect without a single DOM
    /// mutation. Does not touch the consumed base.
    pub fn renderHints(self: *const View, vw: i32, vh: i32) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        const w = &out.writer;
        var n_hints: usize = 0;
        for (self.nodes.items) |nd| {
            if (hintableInViewport(nd, vw, vh)) n_hints += 1;
        }
        try w.print("hints {d} vw {d} vh {d}\n", .{ n_hints, vw, vh });
        for (self.nodes.items) |nd| {
            if (!hintableInViewport(nd, vw, vh)) continue;
            try w.print("{d}\t{d}\t{d}\t{d}\t{d}\t", .{ nd.sid, nd.x, nd.y, nd.w, nd.h });
            try writeSanitized(w, nd.role);
            try w.writeByte('\t');
            try writeSanitized(w, nd.url);
            try w.writeByte('\t');
            try writeSanitized(w, nd.name);
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

    /// Answer a `sem_query` from the LIVE tree — deliberately not a
    /// fresh DOM walk, so a query never costs a traversal. The live
    /// tree may be ahead of what the client has consumed; ids it names
    /// are stable and actionable either way.
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

/// Roles a hint label makes sense on: things a click or focus acts on.
/// A node with a link url qualifies regardless (role=link is derived,
/// but an explicit role attribute can shadow it).
fn hintableRole(role: []const u8) bool {
    const roles = [_][]const u8{
        "link",     "button",      "textbox",          "searchbox",
        "checkbox", "radio",       "combobox",         "listbox",
        "option",   "menuitem",    "menuitemcheckbox", "menuitemradio",
        "slider",   "spinbutton",  "switch",           "tab",
        "summary",  "colorpicker",
    };
    for (roles) |r| {
        if (std.mem.eql(u8, role, r)) return true;
    }
    return false;
}

fn hintableInViewport(nd: Node, vw: i32, vh: i32) bool {
    if (!hintableRole(nd.role) and nd.url.len == 0) return false;
    if (hasState(nd.states, "disabled")) return false;
    if (nd.w <= 0 or nd.h <= 0) return false;
    return nd.x < vw and nd.y < vh and nd.x + nd.w > 0 and nd.y + nd.h > 0;
}

/// Page-authored text into one TSV field: framing bytes become spaces.
fn writeSanitized(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        try w.writeByte(if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch);
    }
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

/// Fold a walk and consume in one step, the way a solicited snapshot
/// request behaves end to end.
fn applyConsume(v: *View, in: InTree, mode: Mode) !Update {
    try v.apply(in);
    return v.consume(mode);
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
    const up = try applyConsume(&v, tree(7, "http://x/", &nodes), .auto);
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

test "reader entities use live stable ids and carry an exact revision" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();
    try v.apply(tree(55, "https://example.test/article", &.{
        .{ .id = 1, .role = "document", .name = "Article" },
        .{ .id = 8, .parent = 1, .role = "heading", .name = "Heading" },
        .{ .id = 9, .parent = 1, .role = "link", .name = "Next", .url = "https://example.test/next" },
    }));
    const heading_sid = v.sidFor(8);
    const link_sid = v.sidFor(9);
    const result = try v.readerResult(gpa, .{
        .doc = 55,
        .md = "# Heading\n\n[Next](https://example.test/next)\n",
        .entities = &.{
            .{ .eid = 8, .kind = "heading", .text = "Heading" },
            .{ .eid = 9, .kind = "link", .text = "Next", .url = "https://example.test/next" },
            .{ .eid = 99, .kind = "link", .text = "not in the walk" },
        },
    });
    defer gpa.free(result.entities);
    try std.testing.expect(v.revisionMatches(result.doc_gen, result.rev));
    try std.testing.expectEqual(@as(usize, 2), result.entities.len);
    try std.testing.expectEqual(heading_sid, result.entities[0].id);
    try std.testing.expectEqual(link_sid, result.entities[1].id);
    try std.testing.expectEqual(v.actionGuard(link_sid), result.entities[1].guard);

    const rev = v.rev;
    try v.apply(tree(55, "https://example.test/article", &.{
        .{ .id = 1, .role = "document", .name = "Article" },
        .{ .id = 8, .parent = 1, .role = "heading", .name = "Changed" },
        .{ .id = 9, .parent = 1, .role = "link", .name = "Next", .url = "https://example.test/next" },
    }));
    try std.testing.expect(v.rev > rev);
    try std.testing.expect(!v.revisionMatches(result.doc_gen, result.rev));
    try std.testing.expectError(error.StaleReaderDocument, v.readerResult(gpa, .{ .doc = 99 }));
}

test "invalidating a document preserves id and document monotonicity" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();
    try v.apply(.{
        .doc = 1,
        .url = "https://old.test",
        .nodes = &.{.{ .id = 1, .parent = 0, .role = "document", .name = "old" }},
    });
    const old_sid = v.nodes.items[0].sid;
    const old_doc = v.doc_gen;
    v.invalidateDocument();
    try std.testing.expect(!v.has_tree);
    try v.apply(.{
        .doc = 2,
        .url = "https://new.test",
        .nodes = &.{.{ .id = 1, .parent = 0, .role = "document", .name = "new" }},
    });
    try std.testing.expect(v.nodes.items[0].sid > old_sid);
    try std.testing.expect(v.doc_gen > old_doc);
}

test "reader action guard notices a retargeted long link" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();
    const shown = "data:text/html,shared-display-url";
    try v.apply(tree(7, "data:", &.{
        .{ .id = 1, .role = "document" },
        .{ .id = 2, .parent = 1, .role = "link", .name = "Go", .url = shown, .guard = "#one" },
    }));
    const sid = v.sidFor(2);
    const before = v.actionGuard(sid);
    const rev = v.rev;
    try v.apply(tree(7, "data:", &.{
        .{ .id = 1, .role = "document" },
        .{ .id = 2, .parent = 1, .role = "link", .name = "Go", .url = shown, .guard = "#two" },
    }));
    try std.testing.expectEqual(rev, v.rev);
    try std.testing.expect(before != v.actionGuard(sid));
}

test "reader action guard notices an identical replacement element" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();
    try v.apply(tree(7, "data:", &.{
        .{ .id = 1, .role = "document" },
        .{ .id = 2, .parent = 1, .role = "button", .name = "Go" },
    }));
    const sid = v.sidFor(2);
    const before = v.actionGuard(sid);
    const rev = v.rev;
    try v.apply(tree(7, "data:", &.{
        .{ .id = 1, .role = "document" },
        .{ .id = 9, .parent = 1, .role = "button", .name = "Go" },
    }));
    try std.testing.expectEqual(sid, v.sidFor(9));
    try std.testing.expectEqual(rev, v.rev);
    try std.testing.expect(before != v.actionGuard(sid));
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
    var up = try applyConsume(&v, tree(7, "http://x/", &first), .auto);
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
    up = try applyConsume(&v, tree(7, "http://x/", &second), .auto);
    defer gpa.free(up.text);
    try std.testing.expectEqual(Kind.delta, up.kind);
    try std.testing.expectEqual(heading, v.sidFor(2));
    try std.testing.expectEqual(para, v.sidFor(3));
    try std.testing.expect(std.mem.indexOf(u8, up.text, "~ [") != null);
    try std.testing.expect(std.mem.indexOf(u8, up.text, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, up.text, "Hello") == null);

    // Dropping the paragraph and adding an UNRELATED one back must mint
    // a new id (different content, so no intra-document carry either).
    const third = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "Hello" },
    };
    const up3 = try applyConsume(&v, tree(7, "http://x/", &third), .auto);
    gpa.free(up3.text);
    const fourth = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "Hello" },
        .{ .id = 9, .parent = 1, .role = "paragraph", .name = "fresh words" },
    };
    const up4 = try applyConsume(&v, tree(7, "http://x/", &fourth), .auto);
    gpa.free(up4.text);
    try std.testing.expect(v.sidFor(9) != para);
    try std.testing.expectEqual(@as(u32, 0), v.eidFor(para));
}

test "a truncation marker has no engine id to act on" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const nodes = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "list", .name = "" },
        .{ .id = 3, .parent = 2, .role = "listitem", .name = "one" },
        .{ .id = 4, .parent = 2, .role = "more", .name = "\u{2026} and 50 more" },
    };
    const up = try applyConsume(&v, tree(7, "http://x/", &nodes), .auto);
    gpa.free(up.text);
    const item = v.sidFor(3);
    const marker = v.sidFor(4);
    try std.testing.expect(item != 0 and marker != 0);
    // The real item routes; the marker refuses as unknown, because no
    // element exists behind it (semantic.js keeps it out of byId too).
    try std.testing.expectEqual(@as(u32, 3), v.eidFor(item));
    try std.testing.expectEqual(@as(u32, 0), v.eidFor(marker));
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
    var up = try applyConsume(&v, tree(11, "http://x/1", &page1), .auto);
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
    up = try applyConsume(&v, tree(12, "http://x/2", &page2), .auto);
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
    var up = try applyConsume(&v, tree(11, "http://x/1", &page1), .auto);
    gpa.free(up.text);

    const page2 = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "article", .name = "Two" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "delta" },
        .{ .id = 3, .parent = 1, .role = "link", .name = "epsilon" },
        .{ .id = 4, .parent = 1, .role = "button", .name = "zeta" },
    };
    up = try applyConsume(&v, tree(12, "http://x/2", &page2), .auto);
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
    const up = try applyConsume(&v, tree(7, "http://x/", &clamped), .auto);
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
    const up2 = try applyConsume(&v, tree(7, "http://x/", &whole), .auto);
    defer gpa.free(up2.text);
    try std.testing.expectEqual(Kind.delta, up2.kind);
    try std.testing.expect(std.mem.indexOf(u8, up2.text, "chars, expand") == null);
    try std.testing.expect(std.mem.indexOf(u8, up2.text, "name=\"the beginning and the rest\"") != null);
}

test "queries read the live tree" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const nodes = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "navigation", .name = "Site" },
        .{ .id = 3, .parent = 2, .role = "link", .name = "Documentation" },
        .{ .id = 4, .parent = 1, .role = "textbox", .name = "Name", .states = "focused" },
    };
    try v.apply(tree(7, "http://x/", &nodes));

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

test "renderHints lists visible interactive nodes with rects and urls" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const nodes = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "link", .name = "Docs", .url = "https://x/docs", .x = 10, .y = 20, .w = 60, .h = 16 },
        .{ .id = 3, .parent = 1, .role = "button", .name = "Go", .x = 10, .y = 40, .w = 40, .h = 20 },
        // Scrolled out below the viewport.
        .{ .id = 4, .parent = 1, .role = "link", .name = "Far", .url = "https://x/far", .x = 10, .y = 9000, .w = 60, .h = 16 },
        // Disabled control: no hint.
        .{ .id = 5, .parent = 1, .role = "button", .name = "Nope", .states = "disabled", .x = 10, .y = 60, .w = 40, .h = 20 },
        // Zero-size box: no hint.
        .{ .id = 6, .parent = 1, .role = "link", .name = "Ghost", .url = "https://x/g", .x = 10, .y = 80, .w = 0, .h = 0 },
        // Plain text: never hinted.
        .{ .id = 7, .parent = 1, .role = "paragraph", .name = "words", .x = 0, .y = 100, .w = 100, .h = 20 },
    };
    try v.apply(tree(7, "http://x/", &nodes));

    const text = try v.renderHints(800, 600);
    defer gpa.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "hints 2 vw 800 vh 600\n"));
    const link_sid = v.sidFor(2);
    const btn_sid = v.sidFor(3);
    var buf: [96]u8 = undefined;
    const link_line = try std.fmt.bufPrint(&buf, "{d}\t10\t20\t60\t16\tlink\thttps://x/docs\tDocs\n", .{link_sid});
    try std.testing.expect(std.mem.indexOf(u8, text, link_line) != null);
    var buf2: [96]u8 = undefined;
    const btn_line = try std.fmt.bufPrint(&buf2, "{d}\t10\t40\t40\t20\tbutton\t\tGo\n", .{btn_sid});
    try std.testing.expect(std.mem.indexOf(u8, text, btn_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Far") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Nope") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Ghost") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "words") == null);
}

test "renderHints flattens framing bytes in page-authored fields" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();
    const nodes = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "link", .name = "a\tb\nc", .url = "https://x/\ty", .x = 0, .y = 0, .w = 10, .h = 10 },
    };
    try v.apply(tree(7, "http://x/", &nodes));
    const text = try v.renderHints(100, 100);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "https://x/ y\ta b c\n") != null);
}

test "spontaneous churn coalesces to one empty delta; history keeps the replay" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const quiet = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "list", .name = "" },
        .{ .id = 3, .parent = 2, .role = "listitem", .name = "row one" },
        .{ .id = 4, .parent = 2, .role = "listitem", .name = "row two" },
    };
    var up = try applyConsume(&v, tree(7, "http://x/", &quiet), .auto);
    gpa.free(up.text);
    const rev0 = v.rev;

    // A popup appears (spontaneous fold, nothing consumed)...
    const with_popup = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "list", .name = "" },
        .{ .id = 3, .parent = 2, .role = "listitem", .name = "row one" },
        .{ .id = 4, .parent = 2, .role = "listitem", .name = "row two" },
        .{ .id = 5, .parent = 1, .role = "alert", .name = "Popup flash" },
    };
    try v.apply(tree(7, "http://x/", &with_popup));
    // ...and vanishes again.
    try v.apply(tree(7, "http://x/", &quiet));
    try std.testing.expect(v.rev > rev0);

    // The replay knows about the popup; the coalesced answer does not.
    const hist = try v.consume(.history);
    defer gpa.free(hist.text);
    try std.testing.expectEqual(Kind.delta, hist.kind);
    try std.testing.expect(std.mem.indexOf(u8, hist.text, "Popup flash") != null);
    try std.testing.expect(std.mem.count(u8, hist.text, "delta rev") >= 2);

    // Same churn again, consumed with the default mode: one delta,
    // nothing in it.
    try v.apply(tree(7, "http://x/", &with_popup));
    try v.apply(tree(7, "http://x/", &quiet));
    up = try v.consume(.auto);
    defer gpa.free(up.text);
    try std.testing.expectEqual(Kind.delta, up.kind);
    try std.testing.expect(std.mem.indexOf(u8, up.text, "Popup") == null);
    try std.testing.expect(std.mem.indexOf(u8, up.text, "+ [") == null);
    try std.testing.expect(std.mem.indexOf(u8, up.text, "- [") == null);
    try std.testing.expectEqual(@as(usize, 0), up.changes);
}

test "an intra-document re-render keeps ids and refreshes engine routing" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const before = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "list", .name = "" },
        .{ .id = 3, .parent = 2, .role = "listitem", .name = "row one" },
        .{ .id = 4, .parent = 2, .role = "listitem", .name = "row two" },
    };
    var up = try applyConsume(&v, tree(7, "http://x/", &before), .auto);
    gpa.free(up.text);
    const row1 = v.sidFor(3);
    const row2 = v.sidFor(4);

    // The page rebuilt the same rows: identical content, fresh engine
    // ids. The stable ids must survive and route to the NEW nodes.
    const rebuilt = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "list", .name = "" },
        .{ .id = 30, .parent = 2, .role = "listitem", .name = "row one" },
        .{ .id = 40, .parent = 2, .role = "listitem", .name = "row two" },
    };
    up = try applyConsume(&v, tree(7, "http://x/", &rebuilt), .auto);
    defer gpa.free(up.text);
    try std.testing.expectEqual(Kind.delta, up.kind);
    try std.testing.expectEqual(@as(usize, 0), up.changes);
    try std.testing.expectEqual(row1, v.sidFor(30));
    try std.testing.expectEqual(row2, v.sidFor(40));
    try std.testing.expectEqual(@as(u32, 30), v.eidFor(row1));
    try std.testing.expectEqual(@as(u32, 40), v.eidFor(row2));
}

test "intra-document carry cannot pair across different parents" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    // Two identical "Delete" buttons under two DIFFERENT rows.
    const before = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "listitem", .name = "invoice A" },
        .{ .id = 3, .parent = 2, .role = "button", .name = "Delete" },
        .{ .id = 4, .parent = 1, .role = "listitem", .name = "invoice B" },
        .{ .id = 5, .parent = 4, .role = "button", .name = "Delete" },
    };
    var up = try applyConsume(&v, tree(7, "http://x/", &before), .auto);
    gpa.free(up.text);
    const del_a = v.sidFor(3);
    const del_b = v.sidFor(5);

    // Row A is re-rendered (fresh engine ids); row B keeps its nodes.
    // A's Delete must keep A's id, never steal B's.
    const rebuilt = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 20, .parent = 1, .role = "listitem", .name = "invoice A" },
        .{ .id = 30, .parent = 20, .role = "button", .name = "Delete" },
        .{ .id = 4, .parent = 1, .role = "listitem", .name = "invoice B" },
        .{ .id = 5, .parent = 4, .role = "button", .name = "Delete" },
    };
    up = try applyConsume(&v, tree(7, "http://x/", &rebuilt), .auto);
    defer gpa.free(up.text);
    try std.testing.expectEqual(@as(usize, 0), up.changes);
    try std.testing.expectEqual(del_a, v.sidFor(30));
    try std.testing.expectEqual(del_b, v.sidFor(5));
    try std.testing.expectEqual(@as(u32, 30), v.eidFor(del_a));
    try std.testing.expectEqual(@as(u32, 5), v.eidFor(del_b));
}

test "a document the client never consumed answers full, not a delta" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    // The web_open field case: an about:blank tree is consumed, then
    // the real page arrives via spontaneous folds only.
    const blank = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "" },
    };
    var up = try applyConsume(&v, tree(1, "about:blank", &blank), .auto);
    gpa.free(up.text);

    const page = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Real" },
        .{ .id = 2, .parent = 1, .role = "heading", .name = "Welcome" },
        .{ .id = 3, .parent = 1, .role = "paragraph", .name = "body text" },
        .{ .id = 4, .parent = 1, .role = "button", .name = "Go" },
    };
    try v.apply(tree(2, "http://x/", &page));

    up = try v.consume(.auto);
    defer gpa.free(up.text);
    try std.testing.expectEqual(Kind.full, up.kind);
    try std.testing.expect(std.mem.indexOf(u8, up.text, "Welcome") != null);
}

test "a coalesced delta rivaling the tree restates it in full" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    const before = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "paragraph", .name = "one" },
        .{ .id = 3, .parent = 1, .role = "paragraph", .name = "two" },
    };
    var up = try applyConsume(&v, tree(7, "http://x/", &before), .auto);
    gpa.free(up.text);

    // Everything changed: a delta would repeat the whole tree.
    const after = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Other" },
        .{ .id = 2, .parent = 1, .role = "paragraph", .name = "three" },
        .{ .id = 3, .parent = 1, .role = "paragraph", .name = "four" },
    };
    up = try applyConsume(&v, tree(7, "http://x/", &after), .auto);
    defer gpa.free(up.text);
    try std.testing.expectEqual(Kind.full, up.kind);
}

test "the history buffer bounds itself with an overflow marker" {
    const gpa = std.testing.allocator;
    var v = View.init(gpa);
    defer v.deinit();

    var name_buf: [600]u8 = undefined;
    @memset(&name_buf, 'x');
    const first = [_]InNode{
        .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
        .{ .id = 2, .parent = 1, .role = "paragraph", .name = "seed" },
    };
    const up = try applyConsume(&v, tree(7, "http://x/", &first), .auto);
    gpa.free(up.text);

    // Each fold changes one long name; enough of them overflow 64KB.
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const nodes = [_]InNode{
            .{ .id = 1, .parent = 0, .role = "document", .name = "Demo" },
            .{ .id = 2, .parent = 1, .role = "paragraph", .name = name_buf[0 .. 590 - (i % 2)] },
        };
        try v.apply(tree(7, "http://x/", &nodes));
    }
    const hist = try v.consume(.history);
    defer gpa.free(hist.text);
    try std.testing.expect(std.mem.endsWith(u8, hist.text, HISTORY_OVERFLOW));
    try std.testing.expect(hist.text.len <= MAX_HISTORY + HISTORY_OVERFLOW.len);
}
