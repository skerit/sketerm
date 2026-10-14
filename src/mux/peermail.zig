//! The broker's peer mailboxes: who is registered on which connection,
//! what waits for whom, and what became of it. A pure state machine over
//! an injected wall clock (every call takes `now`) and an injected
//! `Emit` sink, so tests drive it without a daemon; `daemon_peers.zig`
//! is the thin wiring onto client connections.
//!
//! Every message enters its recipient's mailbox and leaves it only by
//! `ack` (or expiry). It is pushed at most once per connection
//! (`delivered_to`), so a server that reconnects gets everything it has
//! not acked again, under the same ids. A durable address's mailbox is
//! one `<dir>/<address>.jsonl` (append per item, rewritten on removal);
//! a non-durable one lives as long as its connection.
//!
//! The wire bodies of the `peer_*` frames are declared here too, beside
//! the state they describe (as `tombstones.zig` does).

const std = @import("std");
const c = @import("../c.zig").c;
const vocab = @import("../agent/vocab.zig");
const peeraddr = @import("../ipc/peeraddr.zig");
const ids = @import("../util/ids.zig");
const pathz = @import("../util/pathz.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const readfile = @import("../util/readfile.zig");

pub const PeerState = vocab.PeerState;
pub const PeerOutcome = vocab.PeerOutcome;
pub const RefuseReason = vocab.RefuseReason;

/// A message text above this many bytes is refused `too_large`.
pub const PEER_TEXT_MAX: usize = 64 * 1024;
/// A mailbox holding this many messages refuses more (`mailbox_full`).
pub const PEER_MAIL_MAX: usize = 256;
/// A mailbox holding this many text bytes refuses more (`mailbox_full`).
pub const PEER_MAIL_MAX_BYTES: usize = 1024 * 1024;
/// Expired ids remembered per recipient (`expired_while_away`).
pub const EXPIRED_RING: usize = 64;
/// Gone non-durable addresses remembered (`not_durable_gone`).
pub const GONE_RING: usize = 256;
/// Message ids are this prefix plus `ID_CHARS` alphabet characters.
pub const ID_PREFIX = "m-";
pub const ID_CHARS = 8;
pub const ID_LEN = ID_PREFIX.len + ID_CHARS;
/// A mailbox file larger than this is not loaded (JSON escaping of a
/// full mailbox stays well below it).
pub const FILE_MAX: usize = 16 * 1024 * 1024;
/// Mailbox files are named `<address>` plus this.
pub const FILE_EXT = ".jsonl";

// ---------------------------------------------------------------- wire

/// Who sent a message, stamped by the broker from the sender's registration.
pub const From = struct {
    address: []const u8 = "",
    host: []const u8 = "",
    cwd: []const u8 = "",
    app: []const u8 = "",
    pid: i32 = 0,
};

/// `peer_register` body; re-sent whenever a field changes.
pub const RegisterReq = struct {
    /// Empty = the broker mints an `anon-` address.
    address: []const u8 = "",
    durable: bool = false,
    app: []const u8 = "",
    cwd: []const u8 = "",
    pid: i32 = 0,
    state: PeerState = .unknown,
};

/// `peer_list_req` body.
pub const ListReq = struct {
    req: u32 = 0,
};

/// One id that expired in this address's mailbox before it was read.
pub const Expired = struct {
    id: []const u8,
    from: []const u8,
    sent_ms: i64,
    expired_ms: i64,
};

/// The registering connection's own view, carried by the unsolicited
/// `peer_list` (req 0) that answers every `peer_register`.
pub const SelfInfo = struct {
    address: []const u8,
    durable: bool,
    /// The requested name was held by another live server; `address` is
    /// a minted anon one instead.
    name_taken: bool = false,
    requested: []const u8 = "",
    /// 0 = mail never expires (or expires in under an hour: see `ttl_ms`).
    ttl_hours: u32 = 0,
    ttl_ms: i64 = 0,
    expired_while_away: []const Expired = &.{},
};

pub const PeerInfo = struct {
    address: []const u8,
    host: []const u8 = "",
    app: []const u8 = "",
    cwd: []const u8 = "",
    pid: i32 = 0,
    state: PeerState = .unknown,
    durable: bool = false,
    live: bool = false,
    last_seen_ms: i64 = 0,
    pending: u32 = 0,
    name_taken: bool = false,
};

/// `peer_list` body. `req` echoes `peer_list_req`; 0 = the answer to a
/// `peer_register`, which also carries `self`.
pub const ListReply = struct {
    req: u32 = 0,
    self: ?SelfInfo = null,
    peers: []const PeerInfo = &.{},
};

/// `peer_send` body.
pub const SendReq = struct {
    req: u32 = 0,
    to: []const u8 = "",
    text: []const u8 = "",
    reply_to: ?[]const u8 = null,
};

/// `peer_send_reply` body; `id` is empty when refused.
pub const SendReply = struct {
    req: u32 = 0,
    id: []const u8 = "",
    outcome: PeerOutcome = .refused,
    reason: ?RefuseReason = null,
    to_state: ?PeerState = null,
};

/// `peer_ack` body: ids the server has handed to its client.
pub const AckReq = struct {
    ids: []const []const u8 = &.{},
};

/// `peer_deliver` body: one message for the receiving connection.
pub const Deliver = struct {
    id: []const u8,
    from: From = .{},
    to: []const u8 = "",
    sent_ms: i64 = 0,
    text: []const u8 = "",
    reply_to: ?[]const u8 = null,
    /// Broker wall clock at delivery minus `sent_ms`.
    age_ms: i64 = 0,
    sender_live: bool = false,
    /// The recipient had no live server when it was sent.
    queued: bool = false,
};

/// `peer_event` body: what became of a message this connection sent.
pub const Event = struct {
    id: []const u8,
    outcome: PeerOutcome = .expired,
    reason: ?RefuseReason = null,
    to: []const u8 = "",
    /// How long it waited.
    queued_ms: i64 = 0,
};

// --------------------------------------------------------------- store

/// What the store hands its owner, synchronously.
pub const Out = union(enum) {
    deliver: Deliver,
    event: Event,
    /// A persistence or drop notice for the log; `conn` is 0.
    warn: []const u8,
};

/// The owner's sink. @return whether the item reached a live connection.
pub const Emit = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, conn: u32, out: Out) bool,

    fn call(self: Emit, conn: u32, out: Out) bool {
        return self.func(self.ctx, conn, out);
    }
};

/// One mailbox line; also the persisted form.
pub const Item = struct {
    kind: Kind = .message,
    id: []const u8 = "",
    from: From = .{},
    to: []const u8 = "",
    /// Message: when it was sent. Event: when it was raised. TTL counts from here.
    sent_ms: i64 = 0,
    text: []const u8 = "",
    reply_to: ?[]const u8 = null,
    queued: bool = false,
    outcome: PeerOutcome = .expired,
    reason: ?RefuseReason = null,
    queued_ms: i64 = 0,

    pub const Kind = enum { message, event };
};

const Stored = struct {
    arena: std.heap.ArenaAllocator,
    item: Item,
    /// The connection it was last pushed to; 0 = none.
    delivered_to: u32 = 0,
};

const ExpiredEntry = struct {
    id_buf: [ID_LEN]u8 = undefined,
    id_len: u8 = 0,
    from_buf: [peeraddr.ADDRESS_MAX]u8 = undefined,
    from_len: u16 = 0,
    sent_ms: i64 = 0,
    expired_ms: i64 = 0,
};

const Box = struct {
    address: []u8,
    durable: bool,
    items: std.ArrayList(*Stored) = .empty,
    expired: [EXPIRED_RING]ExpiredEntry = undefined,
    expired_len: usize = 0,
    expired_head: usize = 0,
    last_seen_ms: i64 = 0,

    fn messageCount(self: *const Box) usize {
        var n: usize = 0;
        for (self.items.items) |s| n += @intFromBool(s.item.kind == .message);
        return n;
    }

    fn textBytes(self: *const Box) usize {
        var n: usize = 0;
        for (self.items.items) |s| if (s.item.kind == .message) {
            n += s.item.text.len;
        };
        return n;
    }

    fn has(self: *const Box, id: []const u8) bool {
        for (self.items.items) |s| if (std.mem.eql(u8, s.item.id, id)) return true;
        return false;
    }

    fn addExpired(self: *Box, item: *const Item, now: i64) void {
        var e = ExpiredEntry{ .sent_ms = item.sent_ms, .expired_ms = now };
        const n = @min(item.id.len, e.id_buf.len);
        @memcpy(e.id_buf[0..n], item.id[0..n]);
        e.id_len = @intCast(n);
        const f = @min(item.from.address.len, e.from_buf.len);
        @memcpy(e.from_buf[0..f], item.from.address[0..f]);
        e.from_len = @intCast(f);
        if (self.expired_len < EXPIRED_RING) {
            self.expired[self.expired_len] = e;
            self.expired_len += 1;
        } else {
            self.expired[self.expired_head] = e;
            self.expired_head = (self.expired_head + 1) % EXPIRED_RING;
        }
    }
};

const Peer = struct {
    conn: u32,
    /// The effective address (the requested one, or a minted anon one).
    address: []const u8,
    requested: []const u8,
    name_taken: bool,
    durable: bool,
    /// What the registration asked for (`durable` is what it got).
    asked_durable: bool,
    app: []const u8,
    cwd: []const u8,
    pid: i32,
    state: PeerState,
    last_seen_ms: i64,
};

const GoneName = struct {
    buf: [peeraddr.NAME_MAX]u8 = undefined,
    len: u8 = 0,

    fn name(self: *const GoneName) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Options = struct {
    /// Where durable mailboxes persist; null = memory only.
    dir: ?[]const u8 = null,
    /// This broker's host, stamped into `From.host` and every `PeerInfo`.
    host: []const u8 = "",
    /// Time-to-live of a queued item; 0 = never expires.
    ttl_ms: i64 = 0,
    emit: Emit,
};

pub const Error = error{ NotRegistered, BadAddress, OutOfMemory, NoEntropy };

pub const SendResult = struct {
    /// Borrowed from the caller's `id_buf`; empty when refused.
    id: []const u8 = "",
    outcome: PeerOutcome,
    reason: ?RefuseReason = null,
    to_state: ?PeerState = null,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    dir: ?[]u8,
    host: []u8,
    ttl_ms: i64,
    emit: Emit,
    peers: std.ArrayList(*Peer) = .empty,
    boxes: std.ArrayList(*Box) = .empty,
    gone: [GONE_RING]GoneName = undefined,
    gone_len: usize = 0,
    gone_head: usize = 0,

    pub fn init(allocator: std.mem.Allocator, opts: Options) error{OutOfMemory}!Store {
        const dir = if (opts.dir) |d| try allocator.dupe(u8, d) else null;
        errdefer if (dir) |d| allocator.free(d);
        return .{
            .allocator = allocator,
            .dir = dir,
            .host = try allocator.dupe(u8, opts.host),
            .ttl_ms = opts.ttl_ms,
            .emit = opts.emit,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.peers.items) |p| self.freePeer(p);
        self.peers.deinit(self.allocator);
        for (self.boxes.items) |b| self.freeBox(b);
        self.boxes.deinit(self.allocator);
        if (self.dir) |d| self.allocator.free(d);
        self.allocator.free(self.host);
    }

    // ------------------------------------------------------ registration

    /// Register (or update) connection `conn`. A durable name another live
    /// connection holds is NOT shared: this one gets a minted anon address
    /// and `name_taken`. Push its pending mail with `flush` afterwards, once
    /// the caller has answered the registration.
    pub fn register(self: *Store, conn: u32, req: RegisterReq, now: i64) Error!void {
        var anon_buf: [peeraddr.ANON_PREFIX.len + peeraddr.ANON_CHARS]u8 = undefined;
        var taken_buf: [peeraddr.ANON_PREFIX.len + peeraddr.ANON_CHARS]u8 = undefined;
        const requested = if (req.address.len == 0) try self.mintAnon(&anon_buf) else req.address;
        const addr = peeraddr.Address.parse(requested) catch return error.BadAddress;
        if (addr.host != null) return error.BadAddress;
        const durable = req.durable and !addr.isAnon();

        if (self.peerIndex(conn)) |i| {
            const p = self.peers.items[i];
            if (std.mem.eql(u8, p.requested, requested) and p.asked_durable == req.durable) {
                try self.updatePeer(p, req, now);
                return;
            }
            // A changed address is a new registration on this connection.
            self.deregister(conn, now);
        }

        var name_taken = false;
        var effective: []const u8 = requested;
        var eff_durable = durable;
        if (self.livePeer(requested) != null) {
            name_taken = true;
            effective = try self.mintAnon(&taken_buf);
            eff_durable = false;
        }
        const box = try self.ensureBox(effective, eff_durable);
        if (box.durable) {
            eff_durable = true;
            self.touchFile(box);
        }
        box.last_seen_ms = now;
        self.goneRemove(effective);

        const p = try self.allocator.create(Peer);
        errdefer self.allocator.destroy(p);
        p.* = .{
            .conn = conn,
            .address = try self.allocator.dupe(u8, effective),
            .requested = &.{},
            .name_taken = name_taken,
            .durable = eff_durable,
            .asked_durable = req.durable,
            .app = &.{},
            .cwd = &.{},
            .pid = req.pid,
            .state = req.state,
            .last_seen_ms = now,
        };
        errdefer self.allocator.free(p.address);
        p.requested = try self.allocator.dupe(u8, requested);
        errdefer self.allocator.free(p.requested);
        p.app = try self.allocator.dupe(u8, req.app);
        errdefer self.allocator.free(p.app);
        p.cwd = try self.allocator.dupe(u8, req.cwd);
        errdefer self.allocator.free(p.cwd);
        try self.peers.append(self.allocator, p);
    }

    /// The connection closed. A durable address keeps its mailbox for the
    /// next server; a non-durable one is forgotten, its unread messages
    /// end as `expired`/`not_durable_gone` events to their senders, and
    /// later sends to it are refused `not_durable_gone`.
    pub fn deregister(self: *Store, conn: u32, now: i64) void {
        const i = self.peerIndex(conn) orelse return;
        const p = self.peers.orderedRemove(i);
        defer self.freePeer(p);
        const bi = self.boxIndex(p.address) orelse return;
        const box = self.boxes.items[bi];
        box.last_seen_ms = now;
        if (box.durable) return;
        _ = self.boxes.orderedRemove(bi);
        defer self.freeBox(box);
        self.goneAdd(p.address);
        for (box.items.items) |s| switch (s.item.kind) {
            .message => self.notifySender(&s.item, .{
                .id = s.item.id,
                .outcome = .expired,
                .reason = .not_durable_gone,
                .to = p.address,
                .queued_ms = now - s.item.sent_ms,
            }, now),
            .event => self.warnf("peer event {s} for gone {s} dropped", .{ s.item.id, p.address }),
        };
    }

    /// Push everything in `conn`'s mailbox not yet pushed to `conn`, in order.
    pub fn flush(self: *Store, conn: u32, now: i64) void {
        const p = self.peerOf(conn) orelse return;
        const box = self.boxOf(p.address) orelse return;
        for (box.items.items) |s| {
            if (s.delivered_to == conn) continue;
            if (self.push(conn, s, now)) s.delivered_to = conn;
        }
    }

    // ------------------------------------------------------------- mail

    /// Accept one message from `conn`, stamping `from` and `sent_ms`.
    /// @return error.NotRegistered when `conn` never registered.
    pub fn send(self: *Store, conn: u32, req: SendReq, now: i64, id_buf: *[ID_LEN]u8) Error!SendResult {
        const sender = self.peerOf(conn) orelse return error.NotRegistered;
        if (req.text.len > PEER_TEXT_MAX) return refused(.too_large);
        const addr = peeraddr.Address.parse(req.to) catch return refused(.unknown_address);
        if (addr.host != null) return refused(.federation_unavailable);
        if (std.mem.eql(u8, addr.name, sender.address)) return refused(.self);

        const live = self.livePeer(addr.name);
        const box = if (live != null) self.boxOf(addr.name).? else blk: {
            if (self.goneHas(addr.name)) return refused(.not_durable_gone);
            const b = self.boxOf(addr.name) orelse return refused(.unknown_address);
            if (self.liveClaimant(addr.name)) return refused(.name_taken_ambiguous);
            break :blk b;
        };
        if (box.messageCount() >= PEER_MAIL_MAX or box.textBytes() + req.text.len > PEER_MAIL_MAX_BYTES)
            return refused(.mailbox_full);

        const id = ids.mint(id_buf, ID_PREFIX, ID_CHARS) catch |e| switch (e) {
            error.NoEntropy => return error.NoEntropy,
            error.NoSpaceLeft => unreachable,
        };
        const s = try self.newStored(.{
            .kind = .message,
            .id = id,
            .from = .{ .address = sender.address, .host = self.host, .cwd = sender.cwd, .app = sender.app, .pid = sender.pid },
            .to = addr.name,
            .sent_ms = now,
            .text = req.text,
            .reply_to = req.reply_to,
            .queued = live == null,
        });
        try self.appendItem(box, s);
        if (live) |l| {
            if (self.push(l.conn, s, now)) {
                s.delivered_to = l.conn;
                return .{ .id = id, .outcome = .delivered, .to_state = l.state };
            }
            return .{ .id = id, .outcome = .queued, .to_state = l.state };
        }
        return .{ .id = id, .outcome = .queued, .to_state = .gone };
    }

    /// `conn` handed these ids to its client: they leave its mailbox.
    /// Unknown ids are ignored (an ack is idempotent).
    /// @return how many items were removed.
    pub fn ack(self: *Store, conn: u32, acked: []const []const u8) usize {
        const p = self.peerOf(conn) orelse return 0;
        const box = self.boxOf(p.address) orelse return 0;
        var removed: usize = 0;
        var i: usize = 0;
        while (i < box.items.items.len) {
            const s = box.items.items[i];
            if (contains(acked, s.item.id)) {
                _ = box.items.orderedRemove(i);
                freeStored(self.allocator, s);
                removed += 1;
            } else i += 1;
        }
        if (removed > 0) self.compact(box);
        return removed;
    }

    /// Expire every item older than the TTL: a message becomes an
    /// `expired` event to its sender (queued in the sender's own mailbox
    /// when the sender is offline) and a tombstone for its recipient; an
    /// expired event is dropped with a warning.
    pub fn sweep(self: *Store, now: i64) void {
        if (self.ttl_ms <= 0) return;
        var bi: usize = 0;
        while (bi < self.boxes.items.len) : (bi += 1) {
            const box = self.boxes.items[bi];
            var changed = false;
            var i: usize = 0;
            while (i < box.items.items.len) {
                const s = box.items.items[i];
                if (now - s.item.sent_ms < self.ttl_ms) {
                    i += 1;
                    continue;
                }
                _ = box.items.orderedRemove(i);
                changed = true;
                switch (s.item.kind) {
                    .message => {
                        box.addExpired(&s.item, now);
                        self.notifySender(&s.item, .{
                            .id = s.item.id,
                            .outcome = .expired,
                            .to = box.address,
                            .queued_ms = now - s.item.sent_ms,
                        }, now);
                    },
                    .event => self.warnf("peer event {s} for {s} expired unread, dropped", .{ s.item.id, box.address }),
                }
                freeStored(self.allocator, s);
            }
            if (changed) self.compact(box);
        }
    }

    // ----------------------------------------------------------- views

    /// Every live peer, then every durable address with no live server.
    /// Strings borrow the store; valid until its next mutation.
    pub fn list(self: *Store, arena: std.mem.Allocator) error{OutOfMemory}![]PeerInfo {
        var out: std.ArrayList(PeerInfo) = .empty;
        for (self.peers.items) |p| {
            const box = self.boxOf(p.address);
            try out.append(arena, .{
                .address = p.address,
                .host = self.host,
                .app = p.app,
                .cwd = p.cwd,
                .pid = p.pid,
                .state = p.state,
                .durable = p.durable,
                .live = true,
                .last_seen_ms = p.last_seen_ms,
                .pending = if (box) |b| @intCast(b.items.items.len) else 0,
                .name_taken = p.name_taken,
            });
        }
        for (self.boxes.items) |b| {
            if (!b.durable or self.livePeer(b.address) != null) continue;
            try out.append(arena, .{
                .address = b.address,
                .host = self.host,
                .state = .gone,
                .durable = true,
                .last_seen_ms = b.last_seen_ms,
                .pending = @intCast(b.items.items.len),
            });
        }
        return out.items;
    }

    /// `conn`'s own registration view; null when it is not registered.
    pub fn selfInfo(self: *Store, arena: std.mem.Allocator, conn: u32) error{OutOfMemory}!?SelfInfo {
        const p = self.peerOf(conn) orelse return null;
        var expired: std.ArrayList(Expired) = .empty;
        if (self.boxOf(p.address)) |b| {
            for (0..b.expired_len) |k| {
                const e = &b.expired[(b.expired_head + k) % EXPIRED_RING];
                try expired.append(arena, .{
                    .id = try arena.dupe(u8, e.id_buf[0..e.id_len]),
                    .from = try arena.dupe(u8, e.from_buf[0..e.from_len]),
                    .sent_ms = e.sent_ms,
                    .expired_ms = e.expired_ms,
                });
            }
        }
        return .{
            .address = p.address,
            .durable = p.durable,
            .name_taken = p.name_taken,
            .requested = p.requested,
            .ttl_hours = @intCast(@min(@divTrunc(@max(self.ttl_ms, 0), 3_600_000), std.math.maxInt(u32))),
            .ttl_ms = self.ttl_ms,
            .expired_while_away = expired.items,
        };
    }

    /// The effective address of `conn`, if registered.
    pub fn addressOf(self: *Store, conn: u32) ?[]const u8 {
        return if (self.peerOf(conn)) |p| p.address else null;
    }

    // ------------------------------------------------------ persistence

    /// Load every durable mailbox under `dir`. A file that cannot be read
    /// or a line that does not parse costs that file or line, never the
    /// start: a warning is emitted and the rest loads.
    pub fn load(self: *Store) void {
        const dir = self.dir orelse return;
        var z: [4096]u8 = undefined;
        const dz = pathz.pathZ(&z, dir) catch return;
        const d = c.opendir(dz) orelse return;
        defer _ = c.closedir(d);
        while (c.readdir(d)) |de| {
            const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
            if (!std.mem.endsWith(u8, fname, FILE_EXT)) continue;
            const address = fname[0 .. fname.len - FILE_EXT.len];
            peeraddr.validName(address) catch {
                self.warnf("peermail: ignoring {s}: not a peer address", .{fname});
                continue;
            };
            self.loadFile(address);
        }
    }

    fn loadFile(self: *Store, address: []const u8) void {
        const box = self.ensureBox(address, true) catch return self.warnf("peermail: out of memory loading {s}", .{address});
        var pbuf: [4096]u8 = undefined;
        const path = self.filePath(&pbuf, address) orelse return;
        const bytes = readfile.cappedAlloc(self.allocator, path, FILE_MAX) catch |e| {
            return self.warnf("peermail: {s} unreadable ({s}); its mailbox starts empty", .{ path, @errorName(e) });
        };
        defer self.allocator.free(bytes);
        var bad: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const s = self.parseStored(line) catch {
                bad += 1;
                continue;
            };
            if (s.item.id.len == 0 or box.has(s.item.id)) {
                freeStored(self.allocator, s);
                bad += 1;
                continue;
            }
            box.items.append(self.allocator, s) catch {
                freeStored(self.allocator, s);
                bad += 1;
            };
        }
        if (bad > 0) self.warnf("peermail: {s}: {d} unreadable line(s) skipped", .{ path, bad });
    }

    fn parseStored(self: *Store, line: []const u8) !*Stored {
        const s = try self.allocator.create(Stored);
        s.* = .{ .arena = .init(self.allocator), .item = .{} };
        errdefer freeStored(self.allocator, s);
        s.item = try std.json.parseFromSliceLeaky(Item, s.arena.allocator(), line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        return s;
    }

    fn filePath(self: *Store, buf: []u8, address: []const u8) ?[]const u8 {
        const dir = self.dir orelse return null;
        return std.fmt.bufPrint(buf, "{s}/{s}" ++ FILE_EXT, .{ dir, address }) catch null;
    }

    /// Create a durable address's (empty) file, so the address is known
    /// after a broker restart even with no mail.
    fn touchFile(self: *Store, box: *Box) void {
        const dir = self.dir orelse return;
        var pbuf: [4096]u8 = undefined;
        const path = self.filePath(&pbuf, box.address) orelse return;
        pathz.makeDirs(dir, 0o700) catch return self.warnf("peermail: cannot create {s}", .{dir});
        var z: [4096]u8 = undefined;
        const pz = pathz.pathZ(&z, path) catch return;
        const fd = c.open(pz, c.O_WRONLY | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return self.warnf("peermail: cannot create {s}", .{path});
        _ = c.close(fd);
    }

    fn appendItem(self: *Store, box: *Box, s: *Stored) error{OutOfMemory}!void {
        try box.items.append(self.allocator, s);
        if (!box.durable) return;
        const dir = self.dir orelse return;
        var pbuf: [4096]u8 = undefined;
        const path = self.filePath(&pbuf, box.address) orelse return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(s.item, .{ .emit_null_optional_fields = false }, &aw.writer) catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;
        pathz.makeDirs(dir, 0o700) catch return self.warnf("peermail: cannot create {s}; {s} kept in memory only", .{ dir, s.item.id });
        var z: [4096]u8 = undefined;
        const pz = pathz.pathZ(&z, path) catch return;
        const fd = c.open(pz, c.O_WRONLY | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return self.warnf("peermail: cannot append to {s}; {s} kept in memory only", .{ path, s.item.id });
        defer _ = c.close(fd);
        var off: usize = 0;
        const data = aw.written();
        while (off < data.len) {
            const n = c.write(fd, data[off..].ptr, data.len - off);
            if (n <= 0) {
                if (n < 0 and std.c._errno().* == c.EINTR) continue;
                return self.warnf("peermail: short write to {s}", .{path});
            }
            off += @intCast(n);
        }
    }

    /// Rewrite a durable mailbox's file from memory.
    fn compact(self: *Store, box: *Box) void {
        if (!box.durable or self.dir == null) return;
        var pbuf: [4096]u8 = undefined;
        const path = self.filePath(&pbuf, box.address) orelse return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        for (box.items.items) |s| {
            std.json.Stringify.value(s.item, .{ .emit_null_optional_fields = false }, &aw.writer) catch return self.warnf("peermail: out of memory compacting {s}", .{path});
            aw.writer.writeByte('\n') catch return self.warnf("peermail: out of memory compacting {s}", .{path});
        }
        atomicwrite.writeFileExact(path, aw.written(), 0o600) catch |e| self.warnf("peermail: cannot rewrite {s} ({s})", .{ path, @errorName(e) });
    }

    // -------------------------------------------------------- internals

    fn push(self: *Store, conn: u32, s: *const Stored, now: i64) bool {
        const it = &s.item;
        return switch (it.kind) {
            .message => self.emit.call(conn, .{ .deliver = .{
                .id = it.id,
                .from = it.from,
                .to = it.to,
                .sent_ms = it.sent_ms,
                .text = it.text,
                .reply_to = it.reply_to,
                .age_ms = now - it.sent_ms,
                .sender_live = self.livePeer(it.from.address) != null,
                .queued = it.queued,
            } }),
            .event => self.emit.call(conn, .{ .event = .{
                .id = it.id,
                .outcome = it.outcome,
                .reason = it.reason,
                .to = it.to,
                .queued_ms = it.queued_ms,
            } }),
        };
    }

    /// Queue `ev` in the sender's own mailbox and push it when the sender
    /// is live; dropped with a warning when the sender has no mailbox.
    fn notifySender(self: *Store, msg: *const Item, ev: Event, now: i64) void {
        const box = self.boxOf(msg.from.address) orelse
            return self.warnf("peer event {s} ({s}) for gone sender {s} dropped", .{ ev.id, @tagName(ev.outcome), msg.from.address });
        // AIDEV-NOTE: events bypass the mailbox bounds: refusing one would
        // drop the only word the sender gets about its message.
        const s = self.newStored(.{
            .kind = .event,
            .id = ev.id,
            .to = ev.to,
            .sent_ms = now,
            .outcome = ev.outcome,
            .reason = ev.reason,
            .queued_ms = ev.queued_ms,
        }) catch return self.warnf("peer event {s} dropped: out of memory", .{ev.id});
        self.appendItem(box, s) catch {
            freeStored(self.allocator, s);
            return self.warnf("peer event {s} dropped: out of memory", .{ev.id});
        };
        if (self.livePeer(box.address)) |p| {
            if (self.push(p.conn, s, now)) s.delivered_to = p.conn;
        }
    }

    fn newStored(self: *Store, item: Item) error{OutOfMemory}!*Stored {
        const s = try self.allocator.create(Stored);
        s.* = .{ .arena = .init(self.allocator), .item = .{} };
        errdefer freeStored(self.allocator, s);
        const a = s.arena.allocator();
        var it = item;
        it.id = try a.dupe(u8, item.id);
        it.from = .{
            .address = try a.dupe(u8, item.from.address),
            .host = try a.dupe(u8, item.from.host),
            .cwd = try a.dupe(u8, item.from.cwd),
            .app = try a.dupe(u8, item.from.app),
            .pid = item.from.pid,
        };
        it.to = try a.dupe(u8, item.to);
        it.text = try a.dupe(u8, item.text);
        it.reply_to = if (item.reply_to) |r| try a.dupe(u8, r) else null;
        s.item = it;
        return s;
    }

    fn mintAnon(self: *Store, buf: *[peeraddr.ANON_PREFIX.len + peeraddr.ANON_CHARS]u8) Error![]const u8 {
        var tries: usize = 0;
        while (tries < 64) : (tries += 1) {
            const name = ids.mint(buf, peeraddr.ANON_PREFIX, peeraddr.ANON_CHARS) catch |e| switch (e) {
                error.NoEntropy => return error.NoEntropy,
                error.NoSpaceLeft => unreachable,
            };
            if (self.boxOf(name) == null and !self.goneHas(name)) return name;
        }
        return error.NoEntropy;
    }

    fn updatePeer(self: *Store, p: *Peer, req: RegisterReq, now: i64) error{OutOfMemory}!void {
        const app = try self.allocator.dupe(u8, req.app);
        errdefer self.allocator.free(app);
        const cwd = try self.allocator.dupe(u8, req.cwd);
        self.allocator.free(p.app);
        self.allocator.free(p.cwd);
        p.app = app;
        p.cwd = cwd;
        p.pid = req.pid;
        p.state = req.state;
        p.last_seen_ms = now;
    }

    fn ensureBox(self: *Store, address: []const u8, durable: bool) error{OutOfMemory}!*Box {
        if (self.boxOf(address)) |b| return b;
        const b = try self.allocator.create(Box);
        errdefer self.allocator.destroy(b);
        b.* = .{ .address = try self.allocator.dupe(u8, address), .durable = durable };
        errdefer self.allocator.free(b.address);
        try self.boxes.append(self.allocator, b);
        return b;
    }

    fn peerIndex(self: *const Store, conn: u32) ?usize {
        for (self.peers.items, 0..) |p, i| if (p.conn == conn) return i;
        return null;
    }

    fn peerOf(self: *const Store, conn: u32) ?*Peer {
        return if (self.peerIndex(conn)) |i| self.peers.items[i] else null;
    }

    fn livePeer(self: *const Store, address: []const u8) ?*Peer {
        for (self.peers.items) |p| if (std.mem.eql(u8, p.address, address)) return p;
        return null;
    }

    /// A live server that asked for `address` and was told it is taken.
    fn liveClaimant(self: *const Store, address: []const u8) bool {
        for (self.peers.items) |p| if (p.name_taken and std.mem.eql(u8, p.requested, address)) return true;
        return false;
    }

    fn boxIndex(self: *const Store, address: []const u8) ?usize {
        for (self.boxes.items, 0..) |b, i| if (std.mem.eql(u8, b.address, address)) return i;
        return null;
    }

    fn boxOf(self: *const Store, address: []const u8) ?*Box {
        return if (self.boxIndex(address)) |i| self.boxes.items[i] else null;
    }

    fn goneAdd(self: *Store, name: []const u8) void {
        var g = GoneName{};
        const n = @min(name.len, g.buf.len);
        @memcpy(g.buf[0..n], name[0..n]);
        g.len = @intCast(n);
        if (self.gone_len < GONE_RING) {
            self.gone[self.gone_len] = g;
            self.gone_len += 1;
        } else {
            self.gone[self.gone_head] = g;
            self.gone_head = (self.gone_head + 1) % GONE_RING;
        }
    }

    fn goneHas(self: *const Store, name: []const u8) bool {
        for (self.gone[0..self.gone_len]) |*g| if (g.len > 0 and std.mem.eql(u8, g.name(), name)) return true;
        return false;
    }

    fn goneRemove(self: *Store, name: []const u8) void {
        for (self.gone[0..self.gone_len]) |*g| if (std.mem.eql(u8, g.name(), name)) {
            g.len = 0;
        };
    }

    fn warnf(self: *Store, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
        _ = self.emit.call(0, .{ .warn = msg });
    }

    fn freePeer(self: *Store, p: *Peer) void {
        self.allocator.free(p.address);
        self.allocator.free(p.requested);
        self.allocator.free(p.app);
        self.allocator.free(p.cwd);
        self.allocator.destroy(p);
    }

    fn freeBox(self: *Store, b: *Box) void {
        for (b.items.items) |s| freeStored(self.allocator, s);
        b.items.deinit(self.allocator);
        self.allocator.free(b.address);
        self.allocator.destroy(b);
    }
};

fn freeStored(allocator: std.mem.Allocator, s: *Stored) void {
    s.arena.deinit();
    allocator.destroy(s);
}

fn refused(reason: RefuseReason) SendResult {
    return .{ .outcome = .refused, .reason = reason };
}

fn contains(list: []const []const u8, id: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

// --------------------------------------------------------------- tests

const t = std.testing;

/// Records every emitted item (strings copied) and which connections are live.
const Rec = struct {
    arena: std.heap.ArenaAllocator,
    got: std.ArrayList(Got) = .empty,
    dead: std.ArrayList(u32) = .empty,

    const Got = struct {
        conn: u32,
        kind: std.meta.Tag(Out),
        id: []const u8 = "",
        outcome: PeerOutcome = .delivered,
        reason: ?RefuseReason = null,
        to: []const u8 = "",
        queued: bool = false,
        age_ms: i64 = 0,
        text: []const u8 = "",
        from: []const u8 = "",
    };

    fn init() Rec {
        return .{ .arena = .init(t.allocator) };
    }

    fn deinit(self: *Rec) void {
        self.arena.deinit();
    }

    fn emit(self: *Rec) Emit {
        return .{ .ctx = self, .func = record };
    }

    fn record(ctx: *anyopaque, conn: u32, out: Out) bool {
        const self: *Rec = @ptrCast(@alignCast(ctx));
        const a = self.arena.allocator();
        for (self.dead.items) |d| if (d == conn) return false;
        const g: Got = switch (out) {
            .deliver => |d| .{ .conn = conn, .kind = .deliver, .id = a.dupe(u8, d.id) catch "", .to = a.dupe(u8, d.to) catch "", .queued = d.queued, .age_ms = d.age_ms, .text = a.dupe(u8, d.text) catch "", .from = a.dupe(u8, d.from.address) catch "" },
            .event => |e| .{ .conn = conn, .kind = .event, .id = a.dupe(u8, e.id) catch "", .outcome = e.outcome, .reason = e.reason, .to = a.dupe(u8, e.to) catch "" },
            .warn => |w| .{ .conn = conn, .kind = .warn, .text = a.dupe(u8, w) catch "" },
        };
        self.got.append(a, g) catch return false;
        return out != .warn;
    }

    fn count(self: *const Rec, conn: u32, kind: std.meta.Tag(Out)) usize {
        var n: usize = 0;
        for (self.got.items) |g| n += @intFromBool(g.conn == conn and g.kind == kind);
        return n;
    }

    fn last(self: *const Rec) Got {
        return self.got.items[self.got.items.len - 1];
    }
};

fn reg(address: []const u8, durable: bool) RegisterReq {
    return .{ .address = address, .durable = durable, .app = "claude-code", .cwd = "/w", .pid = 42, .state = .idle };
}

fn sendText(s: *Store, conn: u32, to: []const u8, text: []const u8, now: i64, id_buf: *[ID_LEN]u8) !SendResult {
    return s.send(conn, .{ .to = to, .text = text }, now, id_buf);
}

test "a live peer gets a message pushed once, then redelivered under the same id after reconnecting, until acked" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .host = "hohenheim", .emit = rec.emit() });
    defer s.deinit();
    // 1. Two peers register; a send between them is delivered and stamped.
    try s.register(1, reg("Zenit", true), 1000);
    try s.register(2, reg("Qq", true), 1000);
    var idb: [ID_LEN]u8 = undefined;
    const r = try sendText(&s, 1, "Qq", "hello", 2000, &idb);
    try t.expectEqual(PeerOutcome.delivered, r.outcome);
    try t.expectEqual(@as(?PeerState, .idle), r.to_state);
    try t.expect(std.mem.startsWith(u8, r.id, ID_PREFIX));
    try t.expectEqual(@as(usize, ID_LEN), r.id.len);
    const id = try t.allocator.dupe(u8, r.id);
    defer t.allocator.free(id);
    try t.expectEqual(@as(usize, 1), rec.count(2, .deliver));
    try t.expectEqualStrings("Zenit", rec.last().from);
    try t.expect(!rec.last().queued);
    // 2. A re-registration on the same connection (a field changed) and a
    // flush push nothing twice.
    try s.register(2, reg("Qq", true), 2500);
    s.flush(2, 2500);
    try t.expectEqual(@as(usize, 1), rec.count(2, .deliver));
    // 3. The server reconnects (new connection id): the unacked message
    // comes again with the same id.
    s.deregister(2, 3000);
    try s.register(3, reg("Qq", true), 4000);
    s.flush(3, 4000);
    try t.expectEqual(@as(usize, 1), rec.count(3, .deliver));
    try t.expectEqualStrings(id, rec.last().id);
    try t.expectEqual(@as(i64, 2000), rec.last().age_ms);
    // 4. Acked (twice: idempotent), it is gone for good.
    try t.expectEqual(@as(usize, 1), s.ack(3, &.{id}));
    try t.expectEqual(@as(usize, 0), s.ack(3, &.{id}));
    s.deregister(3, 5000);
    try s.register(4, reg("Qq", true), 6000);
    s.flush(4, 6000);
    try t.expectEqual(@as(usize, 0), rec.count(4, .deliver));
}

test "a durable offline address queues in FIFO order; unknown, self, too large and host addresses are refused" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .emit = rec.emit() });
    defer s.deinit();
    try s.register(1, reg("Zenit", true), 0);
    try s.register(2, reg("Qq", true), 0);
    s.deregister(2, 10);
    var idb: [ID_LEN]u8 = undefined;
    // 1. Offline durable: queued, state gone.
    for ([_][]const u8{ "one", "two", "three" }, 0..) |text, k| {
        const r = try sendText(&s, 1, "Qq", text, @intCast(100 + k), &idb);
        try t.expectEqual(PeerOutcome.queued, r.outcome);
        try t.expectEqual(@as(?PeerState, .gone), r.to_state);
    }
    // 2. Refusals, each with its reason and no id.
    const cases = [_]struct { to: []const u8, reason: RefuseReason }{
        .{ .to = "Nobody", .reason = .unknown_address },
        .{ .to = "Zenit", .reason = .self },
        .{ .to = "box/Qq", .reason = .federation_unavailable },
        .{ .to = "bad name", .reason = .unknown_address },
    };
    for (cases) |cs| {
        const r = try sendText(&s, 1, cs.to, "x", 200, &idb);
        try t.expectEqual(PeerOutcome.refused, r.outcome);
        try t.expectEqual(@as(?RefuseReason, cs.reason), r.reason);
        try t.expectEqualStrings("", r.id);
    }
    const big = try t.allocator.alloc(u8, PEER_TEXT_MAX + 1);
    defer t.allocator.free(big);
    @memset(big, 'a');
    try t.expectEqual(@as(?RefuseReason, .too_large), (try sendText(&s, 1, "Qq", big, 200, &idb)).reason);
    try t.expectEqual(PeerOutcome.queued, (try sendText(&s, 1, "Qq", big[0..PEER_TEXT_MAX], 201, &idb)).outcome);
    // 3. An unregistered connection cannot send.
    try t.expectError(error.NotRegistered, sendText(&s, 9, "Qq", "x", 0, &idb));
    // 4. The server comes back: everything arrives in send order, marked queued.
    try s.register(3, reg("Qq", true), 300);
    s.flush(3, 300);
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(t.allocator);
    for (rec.got.items) |g| if (g.conn == 3 and g.kind == .deliver) {
        try t.expect(g.queued);
        try texts.append(t.allocator, g.text[0..@min(g.text.len, 5)]);
    };
    try t.expectEqual(@as(usize, 4), texts.items.len);
    try t.expectEqualStrings("one", texts.items[0]);
    try t.expectEqualStrings("two", texts.items[1]);
    try t.expectEqualStrings("three", texts.items[2]);
    // 5. The list shows both, with pending counts.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const peers = try s.list(arena.allocator());
    try t.expectEqual(@as(usize, 2), peers.len);
    try t.expectEqual(@as(u32, 4), peers[1].pending);
}

test "a full mailbox refuses rather than dropping older mail" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .emit = rec.emit() });
    defer s.deinit();
    try s.register(1, reg("a", true), 0);
    try s.register(2, reg("b", true), 0);
    var idb: [ID_LEN]u8 = undefined;
    for (0..PEER_MAIL_MAX) |_| try t.expect((try sendText(&s, 1, "b", "x", 0, &idb)).outcome == .delivered);
    try t.expectEqual(@as(?RefuseReason, .mailbox_full), (try sendText(&s, 1, "b", "x", 0, &idb)).reason);
    // Byte bound: a fresh mailbox fills at 1 MiB of text.
    try s.register(3, reg("c", true), 0);
    const chunk = try t.allocator.alloc(u8, PEER_TEXT_MAX);
    defer t.allocator.free(chunk);
    @memset(chunk, 'z');
    for (0..PEER_MAIL_MAX_BYTES / PEER_TEXT_MAX) |_| try t.expect((try sendText(&s, 1, "c", chunk, 0, &idb)).outcome == .delivered);
    try t.expectEqual(@as(?RefuseReason, .mailbox_full), (try sendText(&s, 1, "c", "x", 0, &idb)).reason);
}

test "a second claimant of a durable name gets an anon address; its owner offline makes sends ambiguous" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .emit = rec.emit() });
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try s.register(1, reg("Zenit", true), 0);
    try s.register(2, reg("Zenit", true), 0);
    const me = (try s.selfInfo(arena.allocator(), 2)).?;
    try t.expect(me.name_taken);
    try t.expect(!me.durable);
    try t.expect(peeraddr.isAnonName(me.address));
    try t.expectEqualStrings("Zenit", me.requested);
    try t.expect(!(try s.selfInfo(arena.allocator(), 1)).?.name_taken);
    // A sender reaches the owner while it is live.
    try s.register(3, reg("Qq", true), 0);
    var idb: [ID_LEN]u8 = undefined;
    try t.expectEqual(PeerOutcome.delivered, (try sendText(&s, 3, "Zenit", "x", 0, &idb)).outcome);
    // The owner leaves while the claimant lives: nothing is merged.
    s.deregister(1, 10);
    try t.expectEqual(@as(?RefuseReason, .name_taken_ambiguous), (try sendText(&s, 3, "Zenit", "x", 20, &idb)).reason);
    // The claimant leaves too: the durable mailbox queues again.
    s.deregister(2, 30);
    try t.expectEqual(PeerOutcome.queued, (try sendText(&s, 3, "Zenit", "x", 40, &idb)).outcome);
    // An empty address is minted, never durable.
    try s.register(4, .{ .address = "", .durable = true }, 50);
    const anon = (try s.selfInfo(arena.allocator(), 4)).?;
    try t.expect(peeraddr.isAnonName(anon.address));
    try t.expect(!anon.durable);
    try t.expectError(error.BadAddress, s.register(5, reg("host/x", true), 0));
    try t.expectError(error.BadAddress, s.register(5, reg("..", true), 0));
}

test "a non-durable peer that leaves: its unread mail becomes events, later sends are refused" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .emit = rec.emit() });
    defer s.deinit();
    try s.register(1, reg("Zenit", true), 0);
    try s.register(2, reg("anon-k3f9", false), 0);
    var idb: [ID_LEN]u8 = undefined;
    const r = try sendText(&s, 1, "anon-k3f9", "hi", 100, &idb);
    try t.expectEqual(PeerOutcome.delivered, r.outcome);
    const id = try t.allocator.dupe(u8, r.id);
    defer t.allocator.free(id);
    s.deregister(2, 400);
    // 1. The sender is told, live, with the reason.
    const ev = rec.last();
    try t.expectEqual(std.meta.Tag(Out).event, ev.kind);
    try t.expectEqual(@as(u32, 1), ev.conn);
    try t.expectEqualStrings(id, ev.id);
    try t.expectEqual(PeerOutcome.expired, ev.outcome);
    try t.expectEqual(@as(?RefuseReason, .not_durable_gone), ev.reason);
    // 2. A later send is refused.
    try t.expectEqual(@as(?RefuseReason, .not_durable_gone), (try sendText(&s, 1, "anon-k3f9", "x", 500, &idb)).reason);
    // 3. The event sits in the sender's mailbox until acked.
    try t.expectEqual(@as(usize, 1), s.ack(1, &.{id}));
}

test "TTL expiry: the recipient keeps a tombstone, an offline sender finds the event on its return" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .ttl_ms = 1000, .emit = rec.emit() });
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try s.register(1, reg("Zenit", true), 0);
    try s.register(2, reg("Qq", true), 0);
    s.deregister(2, 0);
    var idb: [ID_LEN]u8 = undefined;
    const r = try sendText(&s, 1, "Qq", "late", 100, &idb);
    try t.expectEqual(PeerOutcome.queued, r.outcome);
    const id = try t.allocator.dupe(u8, r.id);
    defer t.allocator.free(id);
    s.deregister(1, 200);
    // 1. Not yet due.
    s.sweep(1099);
    try t.expectEqual(@as(usize, 0), rec.count(0, .event));
    // 2. Due: nobody live to tell, so the event waits in Zenit's mailbox.
    s.sweep(1100);
    try t.expectEqual(@as(usize, 0), rec.got.items.len);
    // 3. Zenit comes back and gets the event.
    try s.register(3, reg("Zenit", true), 1200);
    s.flush(3, 1200);
    const ev = rec.last();
    try t.expectEqual(std.meta.Tag(Out).event, ev.kind);
    try t.expectEqualStrings(id, ev.id);
    try t.expectEqualStrings("Qq", ev.to);
    try t.expectEqual(@as(?RefuseReason, null), ev.reason);
    // 4. Qq comes back: nothing to deliver, the expired id is in its self view.
    try s.register(4, reg("Qq", true), 1300);
    s.flush(4, 1300);
    try t.expectEqual(@as(usize, 0), rec.count(4, .deliver));
    const me = (try s.selfInfo(arena.allocator(), 4)).?;
    try t.expectEqual(@as(usize, 1), me.expired_while_away.len);
    try t.expectEqualStrings(id, me.expired_while_away[0].id);
    try t.expectEqualStrings("Zenit", me.expired_while_away[0].from);
    // 5. An unacked event expires in turn and is dropped with a warning.
    s.deregister(3, 1300);
    s.sweep(1100 + 1000);
    try t.expectEqual(std.meta.Tag(Out).warn, rec.last().kind);
    // 6. TTL 0 never expires.
    var s0 = try Store.init(t.allocator, .{ .emit = rec.emit() });
    defer s0.deinit();
    try s0.register(1, reg("a", true), 0);
    try s0.register(2, reg("b", true), 0);
    s0.deregister(2, 0);
    _ = try sendText(&s0, 1, "b", "x", 0, &idb);
    s0.sweep(std.math.maxInt(i64) / 2);
    try s0.register(3, reg("b", true), 0);
    const before = rec.count(3, .deliver);
    s0.flush(3, 0);
    try t.expectEqual(before + 1, rec.count(3, .deliver));
}

test "durable mailboxes survive a restart: append, compaction on ack, unreadable lines skipped" {
    var td = pathz.TempDir.make("peermail") orelse return error.SkipZigTest;
    defer td.remove();
    var rec = Rec.init();
    defer rec.deinit();
    var idb: [ID_LEN]u8 = undefined;
    var first_id: [ID_LEN]u8 = undefined;
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        try s.register(1, reg("Zenit", true), 0);
        try s.register(2, reg("Qq", true), 0);
        try s.register(5, reg("Idle", true), 0);
        s.deregister(2, 0);
        const a = try s.send(1, .{ .to = "Qq", .text = "first \"quoted\"\nline", .reply_to = "m-00000000" }, 10, &idb);
        @memcpy(&first_id, a.id);
        _ = try sendText(&s, 1, "Qq", "second", 20, &idb);
        _ = try sendText(&s, 1, "Qq", "third", 30, &idb);
        // Ack one: the file is rewritten without it.
        try s.register(3, reg("Qq", true), 40);
        s.flush(3, 40);
        try t.expectEqual(@as(usize, 1), s.ack(3, &.{&first_id}));
    }
    // A corrupt line and a foreign file do not stop the load.
    {
        var pbuf: [256]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&pbuf, "{s}/Qq.jsonl", .{td.path()});
        const fd = c.open(p, c.O_WRONLY | c.O_APPEND);
        try t.expect(fd >= 0);
        _ = c.write(fd, "{not json\n", 10);
        _ = c.close(fd);
        const q = try std.fmt.bufPrintZ(&pbuf, "{s}/bad name.jsonl", .{td.path()});
        _ = c.close(c.open(q, c.O_WRONLY | c.O_CREAT, @as(c_uint, 0o600)));
    }
    var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
    defer s.deinit();
    const warns_before = rec.count(0, .warn);
    s.load();
    try t.expectEqual(warns_before + 2, rec.count(0, .warn));
    // Known after restart: Qq (mail), Idle (registered, no mail), Zenit.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const peers = try s.list(arena.allocator());
    try t.expectEqual(@as(usize, 3), peers.len);
    try s.register(7, reg("Zenit", true), 50);
    try t.expectEqual(PeerOutcome.queued, (try sendText(&s, 7, "Idle", "x", 50, &idb)).outcome);
    try s.register(8, reg("Qq", true), 100);
    s.flush(8, 100);
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(t.allocator);
    for (rec.got.items) |g| if (g.conn == 8 and g.kind == .deliver) try got.append(t.allocator, g.text);
    try t.expectEqual(@as(usize, 2), got.items.len);
    try t.expectEqualStrings("second", got.items[0]);
    try t.expectEqualStrings("third", got.items[1]);
}

test "the wire bodies round-trip their vocabulary by name" {
    const out = try std.json.Stringify.valueAlloc(t.allocator, SendReply{ .req = 3, .outcome = .refused, .reason = .mailbox_full }, .{ .emit_null_optional_fields = false });
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "\"reason\":\"mailbox_full\"") != null);
    const back = try std.json.parseFromSlice(SendReply, t.allocator, out, .{ .ignore_unknown_fields = true });
    defer back.deinit();
    try t.expectEqual(@as(?RefuseReason, .mailbox_full), back.value.reason);
    const lr = try std.json.Stringify.valueAlloc(t.allocator, ListReply{ .self = .{ .address = "Zenit", .durable = true, .ttl_hours = 6 } }, .{});
    defer t.allocator.free(lr);
    const lback = try std.json.parseFromSlice(ListReply, t.allocator, lr, .{ .ignore_unknown_fields = true });
    defer lback.deinit();
    try t.expectEqualStrings("Zenit", lback.value.self.?.address);
}
