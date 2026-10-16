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
//!
//! Aliases: the one home of the alias rules. An alias is a slug
//! (`peeraddr.slugify`) kept with the address like the subject (persisted
//! in `META_EXT`), assigned once (a requested alias, else the first user
//! title the broker offers, else a legacy name's own slug) and never moved
//! by a later title. A live holder forces the next suffix; a gone holder's
//! alias is RESUMED: its mailbox and subject move to the new address
//! (`yieldBox`). Uniqueness across hosts is the hub's: a member assigns
//! from its last view of the network, and the hub answers a conflicting
//! newer claim with a `Grant` in its presence relay.
//!
//! Federation: a `Route` is one link to another host's broker (on the hub,
//! one per federated domain; on a member, the one uplink to the hub). Each
//! route has ONE outbound `Box` (`+<domain>`, `+` for the uplink) under the
//! same bounds, TTL and persistence as a mailbox. An item leaves it only
//! when the far broker answers `stored`, so a link that drops mid-flight
//! loses nothing; the far side recognises a redelivered id. Addresses are
//! rewritten only on the hub (`peeraddr.qualify`/`localize`).

const std = @import("std");
const c = @import("../c.zig").c;
const vocab = @import("../agent/vocab.zig");
const peeraddr = @import("../ipc/peeraddr.zig");
const ids = @import("../util/ids.zig");
const pathz = @import("../util/pathz.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const readfile = @import("../util/readfile.zig");

const peerwake = @import("peerwake.zig");
pub const PeerState = vocab.PeerState;
pub const PeerOutcome = vocab.PeerOutcome;
pub const RefuseReason = vocab.RefuseReason;
pub const PeerLink = vocab.PeerLink;
pub const PeerFederation = vocab.PeerFederation;
pub const PeerLinkDirection = vocab.PeerLinkDirection;

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
/// A registration's facts document longer than this (as JSON) is dropped.
pub const FACTS_MAX: usize = 4096;
/// Longest `model` / `last_notification` kept from a registration.
pub const PRESENCE_TEXT_MAX: usize = 128;
/// Longest subject (bytes of UTF-8) a peer may carry.
pub const SUBJECT_MAX: usize = 200;
/// A durable address's own state beside its mailbox: `<address>` + this
/// holds `AddressMeta`. It never ends in `FILE_EXT`, so `load` never
/// reads it as a mailbox, and an older broker ignores it.
pub const META_EXT = ".meta.json";
/// Ids of relayed items recently taken, so a redelivery after a lost
/// `stored` answer is not taken twice.
pub const SEEN_RING: usize = 256;
/// A sender waits this long (wall ms) for the far broker's answer to a
/// relayed send before it is told `queued` / `host_unreachable`.
pub const PENDING_MS: i64 = 5_000;
/// Outbound mailboxes are `<this><route>`, a name no peer address can have.
pub const ROUTE_PREFIX = "+";
/// Addresses one `peer_send` `to_list` may name (after duplicates collapse).
pub const PEER_TO_MAX: usize = 32;
/// An address with no live server whose session's hooks or status line
/// reported within this long (wall ms) reads `no_mcp`: the session runs,
/// its MCP server is down. Far above the 5 s status line refresh, so a
/// few missed runs never flip it; a session that ended without its
/// `SessionEnd` hook reads gone at most this long after.
pub const HOOK_FRESH_MS: i64 = 120_000;

// ---------------------------------------------------------------- wire

/// Who sent a message, stamped by the broker from the sender's registration.
pub const From = struct {
    address: []const u8 = "",
    host: []const u8 = "",
    cwd: []const u8 = "",
    app: []const u8 = "",
    pid: i32 = 0,
    /// The sender's alias when it sent, empty = none (or a broker that
    /// predates aliases).
    alias: []const u8 = "",
};

/// Why a subject is refused.
pub const SubjectError = error{ SubjectTooLong, SubjectNotText };

/// The one rule for a peer's subject: at most `SUBJECT_MAX` bytes of
/// UTF-8 with no control character (C0, DEL or C1); "" clears it.
pub fn checkSubject(text: []const u8) SubjectError!void {
    if (text.len > SUBJECT_MAX) return error.SubjectTooLong;
    const view = std.unicode.Utf8View.init(text) catch return error.SubjectNotText;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.SubjectNotText;
    }
}

/// The refusal every surface prints for `e`.
pub fn subjectRefusal(e: SubjectError) []const u8 {
    return switch (e) {
        error.SubjectTooLong => "the subject is longer than 200 bytes",
        error.SubjectNotText => "the subject must be UTF-8 text without control characters (no newlines or tabs)",
    };
}

/// What `<address>` + `META_EXT` holds.
pub const AddressMeta = struct {
    subject: []const u8 = "",
    alias: []const u8 = "",
    /// The address was offered its session's first title (`offerTitle`):
    /// later titles never set a default subject again.
    titled: bool = false,
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
    /// The session's known facts (`data/agents/facts.json` names to
    /// numbers), from its statusline; null = none reported. Not an object,
    /// or above `FACTS_MAX`, is dropped.
    facts: ?std.json.Value = null,
    /// The model the session reports (its statusline), empty = unknown.
    model: []const u8 = "",
    /// The latest notification type its hooks reported, empty = none.
    last_notification: []const u8 = "",
    /// What the session works on, set by its user (`sketerm peer
    /// subject`, through the server): null = unchanged, "" = clear it.
    /// The broker keeps it with the address, not with the connection, so
    /// a server that starts again under a durable name finds it there.
    subject: ?[]const u8 = null,
    /// This client reads slow mail: it holds a `quiet` delivery for the
    /// session's next turn instead of waking it, and parses the outcome
    /// `queued_slow` and the reasons `dormant`/`loop_limited`. A client
    /// without it gets every message as a wake and older words
    /// (`PeerOutcome.compat`).
    slow_mail: bool = false,
    /// The alias this client asks for (its slug is taken; welcome
    /// `peer_alias`): null = none asked, keep what the address holds. A
    /// live holder suffixes it, unless `alias_explicit` (the user's own
    /// `sketerm peer alias`), which is then refused (`SelfInfo.alias_refused`).
    alias: ?[]const u8 = null,
    alias_explicit: bool = false,
    /// Messages reach the session without its asking: a Claude Code
    /// channel, or a follower such as the opencode plugin's (welcome
    /// `peer_polls`). false = the session polls: mail waits for its next
    /// turn or `peer_read`. null = a server that predates it (unknown,
    /// never read as polling).
    armed: ?bool = null,
    /// The process that started this server (its MCP client), whose hooks
    /// report the session's presence (`HookPresence`); 0 = not given.
    client_pid: i32 = 0,
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
    /// The address's alias, empty = none.
    alias: []const u8 = "",
    /// An explicit alias request was refused: the live holder's address.
    alias_refused: []const u8 = "",
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
    /// Its server reported it cannot push messages into the session
    /// (`RegisterReq.armed` false): mail waits for its next turn or
    /// `peer_read`.
    polls: bool = false,
    /// No server of this address is live, but its session's hooks or status
    /// line reported within `HOOK_FRESH_MS`: the session runs, its MCP
    /// server is down (`state` stays `gone`; `last_seen_ms` is that report).
    no_mcp: bool = false,
    /// What the peer's registration reported (`RegisterReq`).
    facts: ?std.json.Value = null,
    model: []const u8 = "",
    last_notification: []const u8 = "",
    /// The user-set subject of the address, empty = none.
    subject: []const u8 = "",
    /// Federation: the host whose link this entry came over (empty = local).
    via_host: []const u8 = "",
    /// Federation: the state of the link it is reached through (null = local).
    link: ?PeerLink = null,
    /// The address's alias, empty = none (or a broker that predates them).
    alias: []const u8 = "",
};

/// One federated host as this broker sees it.
pub const HostInfo = struct {
    host: []const u8,
    link: PeerLink,
    /// Wall ms of the last word over its link; 0 = never.
    last_seen_ms: i64 = 0,
    /// Which side dials this host's link; null for a host reported over
    /// another link.
    direction: ?PeerLinkDirection = null,
};

/// `peer_list` body. `req` echoes `peer_list_req`; 0 = the answer to a
/// `peer_register`, which also carries `self`.
pub const ListReply = struct {
    req: u32 = 0,
    self: ?SelfInfo = null,
    peers: []const PeerInfo = &.{},
    /// Federated hosts and their links (empty without federation).
    hosts: []const HostInfo = &.{},
    federation: PeerFederation = .off,
};

/// `peer_send` body. `to_list` (welcome `peer_slow_mail`) sends ONE
/// message, one id, to each address, duplicates collapsed, at most
/// `PEER_TO_MAX`; `to` is then ignored.
pub const SendReq = struct {
    req: u32 = 0,
    to: []const u8 = "",
    text: []const u8 = "",
    reply_to: ?[]const u8 = null,
    /// Never wake the recipient: slow mail (welcome `peer_slow_mail`).
    quiet: bool = false,
    to_list: []const []const u8 = &.{},
};

/// What became of a message for one address of a `to_list`.
pub const RecipientResult = struct {
    to: []const u8,
    outcome: PeerOutcome,
    reason: ?RefuseReason = null,
    to_state: ?PeerState = null,
    /// The recipient polls (`PeerInfo.polls`): handed to its server, read
    /// only with its next turn or `peer_read`.
    to_polls: bool = false,
    /// The recipient has no live server but its session runs (`PeerInfo.no_mcp`).
    to_no_mcp: bool = false,
};

/// `peer_send_reply` body; `id` is empty when refused. A `to_list` send
/// answers in `results`, one per address in the list's order.
pub const SendReply = struct {
    req: u32 = 0,
    id: []const u8 = "",
    outcome: PeerOutcome = .refused,
    reason: ?RefuseReason = null,
    to_state: ?PeerState = null,
    to_polls: bool = false,
    to_no_mcp: bool = false,
    results: []const RecipientResult = &.{},
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
    /// The sender's presence at delivery: its registration's state, `gone`
    /// when its server is not live. Null from a broker that predates it.
    sender_state: ?PeerState = null,
    /// The recipient had no live server when it was sent.
    queued: bool = false,
    /// The sender's user-set subject at delivery, empty = none (or a
    /// broker that predates it).
    sender_subject: []const u8 = "",
    /// Slow mail: the server hands it with the session's next turn (or
    /// `peer_read`) and never wakes the session with it.
    quiet: bool = false,
};

/// `peer_event` body: what became of a message this connection sent.
pub const Event = struct {
    id: []const u8,
    outcome: PeerOutcome = .expired,
    reason: ?RefuseReason = null,
    to: []const u8 = "",
    /// How long it waited.
    queued_ms: i64 = 0,
    /// Slow mail, as `Deliver.quiet`: the owner is dormant.
    quiet: bool = false,
};

/// `peer_hub_hello` body.
pub const HubHello = struct {
    /// The hub's own host name: its peers are `<host>/name` on the member.
    host: []const u8 = "",
    /// The name the hub knows the member by (its `[domain.<name>]`).
    as: []const u8 = "",
    /// The hub reads slow mail and keys relays by (id, to) (welcome `peer_slow_mail`).
    slow_mail: bool = false,
};

/// `peer_member_hello` body.
pub const MemberHello = struct {
    /// The member's host: the hub's `[domain.<host>]` with `peer_link = inbound`.
    host: []const u8 = "",
    /// As `HubHello.slow_mail`, for the member.
    slow_mail: bool = false,
};

/// `peer_subject` body. On a broker connection `address` names the peer
/// (a live one or a durable address of this host); on a connection
/// attached to a session it is empty and the peer is the one whose
/// process runs in that session's tree.
pub const SubjectReq = struct {
    req: u32 = 0,
    address: []const u8 = "",
    /// Null = only ask; "" = clear it.
    subject: ?[]const u8 = null,
    /// On an attached session only: the title the user gave it in the
    /// viewer (pane or tab), the source of its peer's alias and default
    /// subject (`offerTitle`). Null = unchanged, "" = none.
    title: ?[]const u8 = null,
};

/// `peer_subject_reply` body, echoing `req`.
pub const SubjectReply = struct {
    req: u32 = 0,
    found: bool = false,
    address: []const u8 = "",
    subject: []const u8 = "",
    /// Why a set was refused (`subjectRefusal`).
    refused: ?[]const u8 = null,
};

/// `peer_hook_presence` body: a session's hook or status line found no
/// live server of its own and reports to the broker instead. The broker
/// matches `ancestry` (the reporting process's, nearest first) against the
/// client pid each gone address's last server registered with
/// (`RegisterReq.client_pid`), the rule the hook uses to find its servers
/// in the registry. No reply.
pub const HookPresence = struct {
    ancestry: []const i32 = &.{},
    /// The state the hook event means; null = no change (a status line).
    state: ?PeerState = null,
};

/// The peer running in a session's process tree, as the session's worker
/// tells its viewers (`session_meta` `peer`); empty address = none.
pub const SessionPeer = struct {
    address: []const u8 = "",
    subject: []const u8 = "",
};

/// What one `peer_hub_relay` / `peer_member_relay` carries.
pub const RelayKind = enum {
    /// The sender's peers (`peers`, and on the hub's side `hosts`).
    presence,
    /// One message; answered by `stored`.
    mail,
    /// What became of a message (`owner` sent it); answered by `stored`.
    event,
    /// The far broker took (or refused) item `id` of kind `of`.
    stored,
};

/// `peer_hub_relay` / `peer_member_relay` body; which fields are set
/// follows `kind`. No wall time crosses a link: every time travels as an
/// age on the sender's clock and is rebased on the receiver's (`RelayAge`),
/// so hosts with skewed clocks agree on ages and TTLs. `peers` and `hosts`
/// carry `last_seen_ms` as such an age.
pub const Relay = struct {
    kind: RelayKind,
    id: []const u8 = "",
    from: From = .{},
    to: []const u8 = "",
    /// `event`: the address the event is for.
    owner: []const u8 = "",
    /// `mail`: ms since it was sent, at the sending broker.
    age_ms: i64 = 0,
    text: []const u8 = "",
    reply_to: ?[]const u8 = null,
    outcome: PeerOutcome = .delivered,
    reason: ?RefuseReason = null,
    to_state: ?PeerState = null,
    /// `stored`: the recipient polls (`SendReply.to_polls`).
    to_polls: bool = false,
    /// `stored`: the recipient has no live server but its session runs.
    to_no_mcp: bool = false,
    /// `event`: how long the message waited (already a duration).
    queued_ms: i64 = 0,
    /// `stored`: whether `id` named a message or an event.
    of: Item.Kind = .message,
    peers: []const PeerInfo = &.{},
    hosts: []const HostInfo = &.{},
    /// `mail`: slow mail (`SendReq.quiet`); a far broker without
    /// `slow_mail` ignores it and wakes the recipient.
    quiet: bool = false,
    /// `presence` from the hub: aliases it decided for the receiving
    /// member's own peers (a newer claim that conflicted), addresses as
    /// the member names them. A member that predates aliases ignores it.
    grants: []const Grant = &.{},
};

/// The alias the hub decided for one peer of a member.
pub const Grant = struct {
    address: []const u8,
    alias: []const u8,
};

/// The one rule for times on a relay: an age out, a local time back in;
/// the link's transit time is ignored. A negative age is read as 0.
const RelayAge = struct {
    fn of(now: i64, at_ms: i64) i64 {
        return @max(0, now - at_ms);
    }

    fn at(now: i64, age_ms: i64) i64 {
        return now - @max(0, age_ms);
    }

    /// A `last_seen_ms` of 0 (never) travels as -1, so an age of 0 stays "just now".
    fn seenAgo(now: i64, seen_ms: i64) i64 {
        return if (seen_ms == 0) -1 else of(now, seen_ms);
    }

    fn seenAt(now: i64, ago_ms: i64) i64 {
        return if (ago_ms < 0) 0 else at(now, ago_ms);
    }
};

// --------------------------------------------------------------- store

/// What the store hands its owner, synchronously.
pub const Out = union(enum) {
    deliver: Deliver,
    event: Event,
    /// The deferred answer to a relayed `peer_send` (`conn` sent it).
    reply: SendReply,
    /// One federation item for the link `conn`.
    relay: Relay,
    /// A persistence or drop notice for the log; `conn` is 0.
    warn: []const u8,
    /// The live peer on `conn` was given another alias: it is owed its
    /// own view again (an unsolicited `peer_list` req 0 carrying `self`).
    self_changed,
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
    /// An event in an outbound mailbox: the far-side address it is for.
    owner: []const u8 = "",
    /// A message: slow mail (`Deliver.quiet`), decided when it was routed.
    quiet: bool = false,

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
    /// Owned; the user-set subject, "" = none. Persisted beside a durable
    /// mailbox (`META_EXT`); a non-durable one lives as long as the box.
    subject: []u8 = &.{},
    /// Owned; the address's alias, "" = none. Kept like the subject.
    alias: []u8 = &.{},
    /// `AddressMeta.titled`.
    titled: bool = false,
    /// The client pid its last live server registered (`RegisterReq.client_pid`).
    client_pid: i32 = 0,
    /// Wall ms of the last hook report while no server was live; 0 = none.
    hook_ms: i64 = 0,

    /// Its session runs while its server is down (`PeerInfo.no_mcp`).
    fn noMcp(self: *const Box, now: i64) bool {
        return self.hook_ms > 0 and now - self.hook_ms <= HOOK_FRESH_MS;
    }

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

    /// An outbound (route) mailbox rather than a peer's.
    fn isRoute(self: *const Box) bool {
        return std.mem.startsWith(u8, self.address, ROUTE_PREFIX);
    }

    /// Item `id` of `kind` for recipient `to` (null: any recipient).
    fn findTo(self: *const Box, id: []const u8, kind: Item.Kind, to: ?[]const u8) ?usize {
        for (self.items.items, 0..) |s, i| {
            if (s.item.kind != kind or !std.mem.eql(u8, s.item.id, id)) continue;
            if (to) |x| if (!std.mem.eql(u8, s.item.to, x)) continue;
            return i;
        }
        return null;
    }

    /// A message `id` for a recipient other than `to`.
    fn findOther(self: *const Box, id: []const u8, to: []const u8) ?usize {
        for (self.items.items, 0..) |s, i| {
            if (s.item.kind == .message and std.mem.eql(u8, s.item.id, id) and !std.mem.eql(u8, s.item.to, to)) return i;
        }
        return null;
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
    /// Owned; "" = none (`RegisterReq.facts` re-serialized).
    facts_json: []const u8,
    model: []const u8,
    last_notification: []const u8,
    last_seen_ms: i64,
    /// It reads slow mail (`RegisterReq.slow_mail`).
    slow_mail: bool,
    /// Wall ms of its last activity (`peerwake.Recipient.active_ms`).
    active_ms: i64,
    /// Its reported context size (`peerwake.contextOf`).
    context_tokens: ?u64,
    /// Owned; the live holder that refused its last explicit alias
    /// request (`SelfInfo.alias_refused`), "" = none.
    alias_refused: []u8 = &.{},
    /// `RegisterReq.armed`: null = unknown.
    armed: ?bool = null,
    /// `RegisterReq.client_pid`.
    client_pid: i32 = 0,
};

/// An address that yielded to its alias's new holder (`yieldBox`): mail
/// still sent to it follows the alias.
const Moved = struct {
    addr_buf: [peeraddr.ADDRESS_MAX]u8 = undefined,
    addr_len: u16 = 0,
    alias_buf: [peeraddr.ALIAS_MAX]u8 = undefined,
    alias_len: u8 = 0,

    fn address(self: *const Moved) []const u8 {
        return self.addr_buf[0..self.addr_len];
    }

    fn alias(self: *const Moved) []const u8 {
        return self.alias_buf[0..self.alias_len];
    }
};

/// Yielded addresses remembered (`Moved`).
pub const MOVED_RING: usize = 64;

/// Who holds an alias, as this broker sees the network (`holderOf`).
const Holder = struct {
    /// As this side names it.
    address: []const u8,
    live: bool,
    /// Its mailbox here; null for a peer of another host.
    box: ?*Box = null,
    subject: []const u8 = "",
};

/// What an alias request may take (`chooseAlias`).
const Claim = enum {
    /// The first candidate no LIVE holder has: a gone holder's is resumed.
    resume_gone,
    /// The first candidate nobody holds (migration: nothing is merged).
    free_only,
    /// The base alone, resumed from a gone holder; null when live-held.
    explicit,
};

const Choice = struct {
    /// Borrowed from the caller's buffer.
    alias: []const u8,
    /// The gone holder whose alias is resumed.
    resumes: ?Holder = null,
};

const GoneName = struct {
    buf: [peeraddr.NAME_MAX]u8 = undefined,
    len: u8 = 0,

    fn name(self: *const GoneName) []const u8 {
        return self.buf[0..self.len];
    }
};

/// One link to another host's broker.
const Route = struct {
    /// The domain on a hub; "" = the uplink to the hub on a member.
    name: []u8,
    /// The far host as this side names it: the domain, or the host the
    /// hub announced (owned; "" until a hello).
    host: []u8,
    /// The live link connection; 0 = none.
    conn: u32 = 0,
    link: PeerLink = .down,
    /// Who dials it: config `peer_link` on a hub, the hello's side on a member.
    direction: PeerLinkDirection = .outbound,
    last_seen_ms: i64 = 0,
    box: *Box,
    /// The far side's last presence snapshot (addresses as this side
    /// names them), owned by `arena`.
    arena: std.heap.ArenaAllocator,
    peers: []PeerInfo = &.{},
    hosts: []HostInfo = &.{},
    /// The far broker reads slow mail and keys relays by (id, to) (its
    /// welcome or hello said `slow_mail`); learned anew on every link-up.
    far_slow: bool = false,
    /// Hub: aliases decided for this link's peers (`Grant`, addresses as
    /// the hub names them, owned), sent with each presence until the
    /// member reports them.
    grants: std.ArrayList(Grant) = .empty,

    fn isUplink(self: *const Route) bool {
        return self.name.len == 0;
    }
};

/// Who waits for a relayed item's `stored` answer.
const Waiter = union(enum) {
    /// A local `peer_send`: answered with `peer_send_reply`.
    client: struct { conn: u32, req: u32 },
    /// A link that relayed the item here: answered with `stored`.
    link: u32,
    /// One recipient of a local `to_list` send: the `Multi` of this serial.
    multi: u32,
    /// Nobody: mail a gone address forwarded to its alias's new holder
    /// (`yieldBox`); a refusal reaches its sender as an event.
    none,
};

/// A relayed item is identified by its id AND its recipient: one
/// `to_list` message is several items under one id. The seen ring keeps
/// the recipient as this key.
fn toKey(to: []const u8) u64 {
    return std.hash.Wyhash.hash(0, to);
}

const Pending = struct {
    id_buf: [ID_LEN]u8 = undefined,
    id_len: u8 = 0,
    /// The recipient as this side names it.
    to_buf: [peeraddr.ADDRESS_MAX]u8 = undefined,
    to_len: u16 = 0,
    waiter: Waiter,
    /// The route conn whose answer is awaited; it dropping answers early.
    route_conn: u32,
    deadline_ms: i64,

    fn id(self: *const Pending) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    fn to(self: *const Pending) []const u8 {
        return self.to_buf[0..self.to_len];
    }

    /// `to` null matches any recipient (an answer from a broker that
    /// predates (id, to) keys names none).
    fn matches(self: *const Pending, item_id: []const u8, item_to: ?[]const u8) bool {
        if (!std.mem.eql(u8, self.id(), item_id)) return false;
        return if (item_to) |x| std.mem.eql(u8, self.to(), x) else true;
    }
};

/// A local `to_list` send waiting for some recipients' far answers.
const Multi = struct {
    serial: u32,
    conn: u32,
    req: u32,
    id_buf: [ID_LEN]u8 = undefined,
    id_len: u8 = 0,
    arena: std.heap.ArenaAllocator,
    results: []RecipientResult,
    outstanding: usize,
};

/// A relayed item taken here, and the answer it got.
const Seen = struct {
    id_buf: [ID_LEN]u8 = undefined,
    id_len: u8 = 0,
    kind: Item.Kind = .message,
    to_key: u64 = 0,
    outcome: PeerOutcome = .delivered,
    reason: ?RefuseReason = null,
};

pub const Options = struct {
    /// Where durable mailboxes persist; null = memory only.
    dir: ?[]const u8 = null,
    /// This broker's host, stamped into `From.host` and every `PeerInfo`;
    /// on a hub also the host part of its peers' addresses elsewhere.
    host: []const u8 = "",
    /// Time-to-live of a queued item; 0 = never expires.
    ttl_ms: i64 = 0,
    /// This broker is the federation hub (config `peer_hub`).
    hub: bool = false,
    /// Hub only: the federated domains, one route each.
    domains: []const []const u8 = &.{},
    /// Hub only: those of `domains` whose member calls in (`peer_link = inbound`).
    inbound: []const []const u8 = &.{},
    /// The dormancy thresholds (rigs shorten the silence).
    wake: peerwake.Policy = .{},
    emit: Emit,
};

pub const Error = error{ NotRegistered, BadAddress, OutOfMemory, NoEntropy, TooManyRecipients };
/// A federation call on a connection that carries no link (or, for a hello,
/// on a hub).
pub const LinkError = Error || error{NotLinked};

pub const SendResult = struct {
    /// Borrowed from the caller's `id_buf`; empty when refused.
    id: []const u8 = "",
    outcome: PeerOutcome,
    reason: ?RefuseReason = null,
    to_state: ?PeerState = null,
    to_polls: bool = false,
    to_no_mcp: bool = false,
    /// The answer comes later as `Out.reply` (a relayed send whose link is up).
    deferred: bool = false,
};

/// One message to route: a local send, or mail a link relayed here.
const Msg = struct {
    /// Null = mint one.
    id: ?[]const u8 = null,
    from: From,
    to: []const u8,
    sent_ms: i64,
    text: []const u8,
    reply_to: ?[]const u8 = null,
    quiet: bool = false,
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
    hub: bool = false,
    routes: std.ArrayList(*Route) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    seen: [SEEN_RING]Seen = undefined,
    seen_len: usize = 0,
    seen_head: usize = 0,
    /// Member: the name the hub knows this host by (its hello's `as`).
    as_name: []u8 = &.{},
    /// A presence snapshot is owed to every live link.
    presence_dirty: bool = false,
    /// Bumped whenever a peer comes, goes or changes subject: the owner
    /// re-derives what depends on the set of live peers.
    roster_gen: u32 = 0,
    wake: peerwake.Policy = .{},
    limiter: peerwake.Limiter = .{},
    multis: std.ArrayList(*Multi) = .empty,
    next_multi: u32 = 0,
    moved: [MOVED_RING]Moved = undefined,
    moved_len: usize = 0,
    moved_head: usize = 0,

    pub fn init(allocator: std.mem.Allocator, opts: Options) error{OutOfMemory}!Store {
        const dir = if (opts.dir) |d| try allocator.dupe(u8, d) else null;
        errdefer if (dir) |d| allocator.free(d);
        const host = try allocator.dupe(u8, opts.host);
        errdefer allocator.free(host);
        var s: Store = .{
            .allocator = allocator,
            .dir = dir,
            .host = host,
            .ttl_ms = opts.ttl_ms,
            .emit = opts.emit,
            .hub = opts.hub,
            .wake = opts.wake,
        };
        if (opts.hub) for (opts.domains) |name| {
            const r = s.addRoute(name) catch |e| {
                s.deinit();
                return e;
            };
            for (opts.inbound) |in| {
                if (std.mem.eql(u8, in, name)) r.direction = .inbound;
            }
        };
        return s;
    }

    pub fn deinit(self: *Store) void {
        for (self.peers.items) |p| self.freePeer(p);
        self.peers.deinit(self.allocator);
        for (self.routes.items) |r| self.freeRoute(r);
        self.routes.deinit(self.allocator);
        for (self.boxes.items) |b| self.freeBox(b);
        self.boxes.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        for (self.multis.items) |m| freeMulti(self.allocator, m);
        self.multis.deinit(self.allocator);
        self.limiter.deinit(self.allocator);
        if (self.dir) |d| self.allocator.free(d);
        self.allocator.free(self.host);
        self.allocator.free(self.as_name);
    }

    // ------------------------------------------------------ registration

    /// Register (or update) connection `conn`. A durable name another live
    /// connection holds is NOT shared: this one gets a minted anon address
    /// and `name_taken`. Push its pending mail with `flush` afterwards, once
    /// the caller has answered the registration.
    /// AIDEV-NOTE: an empty address re-sent by the same connection (a
    /// presence update, `clientInfo`) keeps the anon address minted first;
    /// minting again would retire an address the client already reported.
    pub fn register(self: *Store, conn: u32, req: RegisterReq, now: i64) Error!void {
        // Empty = mint an anon address (never durable).
        const asked: ?peeraddr.Address = if (req.address.len == 0) null else peeraddr.Address.parse(req.address) catch return error.BadAddress;
        if (asked) |a| if (a.host != null) return error.BadAddress;
        if (self.peerIndex(conn)) |i| {
            const p = self.peers.items[i];
            if (std.mem.eql(u8, p.requested, req.address) and p.asked_durable == req.durable) {
                try self.updatePeer(p, req, now);
                if (req.subject) |sj| self.subjectFromRegistration(p.address, sj);
                if (req.alias) |want| try self.requestAlias(p, want, req.alias_explicit, now);
                self.presence_dirty = true;
                return;
            }
            // A changed address is a new registration on this connection.
            self.deregister(conn, now);
        }

        var anon_buf: [peeraddr.ANON_PREFIX.len + peeraddr.ANON_CHARS]u8 = undefined;
        var taken_buf: [peeraddr.ANON_PREFIX.len + peeraddr.ANON_CHARS]u8 = undefined;
        const requested = if (req.address.len == 0) try self.mintAnon(&anon_buf) else req.address;
        const durable = req.durable and if (asked) |a| !a.isAnon() else false;

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
        box.hook_ms = 0;
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
            .facts_json = &.{},
            .model = &.{},
            .last_notification = &.{},
            .pid = req.pid,
            .state = req.state,
            .last_seen_ms = now,
            .slow_mail = req.slow_mail,
            // A new server: its client started now, as far as we know.
            .active_ms = now,
            .context_tokens = null,
            .armed = req.armed,
            .client_pid = req.client_pid,
        };
        errdefer self.allocator.free(p.address);
        p.requested = try self.allocator.dupe(u8, req.address);
        errdefer self.allocator.free(p.requested);
        p.app = try self.allocator.dupe(u8, req.app);
        errdefer self.allocator.free(p.app);
        p.cwd = try self.allocator.dupe(u8, req.cwd);
        errdefer self.allocator.free(p.cwd);
        try self.setPresence(p, req);
        errdefer {
            self.allocator.free(p.facts_json);
            self.allocator.free(p.model);
            self.allocator.free(p.last_notification);
        }
        try self.peers.append(self.allocator, p);
        self.presence_dirty = true;
        self.roster_gen +%= 1;
        if (req.subject) |sj| self.subjectFromRegistration(p.address, sj);
        if (name_taken) return;
        if (req.alias) |want| return self.requestAlias(p, want, req.alias_explicit, now);
        // An older server's own name (or a migrated mailbox) asks for its slug.
        if (box.alias.len == 0 and !peeraddr.isReservedName(p.address)) try self.requestAlias(p, p.address, false, now);
    }

    /// The connection closed. A durable address keeps its mailbox for the
    /// next server; a non-durable one is forgotten, its unread messages
    /// end as `expired`/`not_durable_gone` events to their senders, and
    /// later sends to it are refused `not_durable_gone`.
    pub fn deregister(self: *Store, conn: u32, now: i64) void {
        const i = self.peerIndex(conn) orelse return;
        const p = self.peers.orderedRemove(i);
        defer self.freePeer(p);
        self.presence_dirty = true;
        self.roster_gen +%= 1;
        const bi = self.boxIndex(p.address) orelse return;
        const box = self.boxes.items[bi];
        box.last_seen_ms = now;
        box.client_pid = p.client_pid;
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

    // ------------------------------------------------------------- mail

    /// Accept one message from `conn`, stamping `from` and `sent_ms`; a
    /// `host/name` of another host goes to that host's route.
    /// @return error.NotRegistered when `conn` never registered.
    pub fn send(self: *Store, conn: u32, req: SendReq, now: i64, id_buf: *[ID_LEN]u8) Error!SendResult {
        const sender = self.peerOf(conn) orelse return error.NotRegistered;
        // Sending is activity: the session is in a turn.
        sender.active_ms = now;
        if (req.text.len > PEER_TEXT_MAX) return refused(.too_large);
        return self.route(self.msgFrom(sender, req, now, null), .{ .client = .{ .conn = conn, .req = req.req } }, now, id_buf);
    }

    /// What a `to_list` send answers now.
    pub const Many = struct {
        /// Borrowed from the caller's `id_buf`; empty when nothing was sent.
        id: []const u8 = "",
        /// One per distinct address, in list order; allocated in the
        /// caller's arena, `to` borrowed from the request.
        results: []RecipientResult = &.{},
        /// Some recipient waits for a far broker: the whole answer comes
        /// later as one `Out.reply`.
        deferred: bool = false,
    };

    /// One message from `conn` to every address of `req.to_list` under ONE
    /// id, each recipient judged on its own (`route`); duplicates collapse.
    /// @return error.TooManyRecipients above `PEER_TO_MAX` distinct addresses.
    pub fn sendMany(self: *Store, arena: std.mem.Allocator, conn: u32, req: SendReq, now: i64, id_buf: *[ID_LEN]u8) Error!Many {
        const sender = self.peerOf(conn) orelse return error.NotRegistered;
        // Sending is activity: the session is in a turn.
        sender.active_ms = now;
        var tos: std.ArrayList([]const u8) = .empty;
        for (req.to_list) |to| {
            if (contains(tos.items, to)) continue;
            if (tos.items.len == PEER_TO_MAX) return error.TooManyRecipients;
            try tos.append(arena, to);
        }
        const results = try arena.alloc(RecipientResult, tos.items.len);
        if (req.text.len > PEER_TEXT_MAX) {
            for (tos.items, results) |to, *r| r.* = .{ .to = to, .outcome = .refused, .reason = .too_large };
            return .{ .results = results };
        }
        const id = try mintId(id_buf);
        self.next_multi +%= 1;
        const serial = self.next_multi;
        var outstanding: usize = 0;
        var scratch: [ID_LEN]u8 = undefined;
        for (tos.items, results) |to, *r| {
            var one = req;
            one.to = to;
            const res = try self.route(self.msgFrom(sender, one, now, id), .{ .multi = serial }, now, &scratch);
            r.* = .{ .to = to, .outcome = res.outcome, .reason = res.reason, .to_state = res.to_state, .to_polls = res.to_polls, .to_no_mcp = res.to_no_mcp };
            outstanding += @intFromBool(res.deferred);
        }
        if (outstanding == 0) return .{ .id = id, .results = results };
        const m = try self.allocator.create(Multi);
        m.* = .{ .serial = serial, .conn = conn, .req = req.req, .arena = .init(self.allocator), .results = &.{}, .outstanding = outstanding };
        errdefer freeMulti(self.allocator, m);
        @memcpy(m.id_buf[0..id.len], id);
        m.id_len = @intCast(id.len);
        const a = m.arena.allocator();
        m.results = try a.alloc(RecipientResult, results.len);
        for (results, m.results) |r, *o| {
            o.* = r;
            o.to = try a.dupe(u8, r.to);
        }
        try self.multis.append(self.allocator, m);
        return .{ .id = id, .results = results, .deferred = true };
    }

    fn msgFrom(self: *const Store, sender: *const Peer, req: SendReq, now: i64, id: ?[]const u8) Msg {
        return .{
            .id = id,
            .from = .{ .address = sender.address, .host = self.host, .cwd = sender.cwd, .app = sender.app, .pid = sender.pid, .alias = self.aliasOf(sender.address) },
            .to = req.to,
            .sent_ms = now,
            .text = req.text,
            .reply_to = req.reply_to,
            .quiet = req.quiet,
        };
    }

    /// Route `msg` to a local mailbox or a route's outbound one; `to` may
    /// be an alias, bare or after this host's name (`resolve`). A live
    /// recipient of this host is woken or handed slow mail by
    /// `peerwake.judge`, here, where its presence is known.
    fn route(self: *Store, msg_in: Msg, waiter: Waiter, now: i64, id_buf: *[ID_LEN]u8) Error!SendResult {
        var msg = msg_in;
        msg.to = self.resolve(msg_in.to);
        var addr = peeraddr.Address.parse(msg.to) catch return refused(.unknown_address);
        if (addr.host) |h| {
            if (!self.isSelfHost(h)) return self.routeRemote(msg, h, waiter, now, id_buf);
            // This host by name: what follows is resolved like a bare
            // name (an alias here, or held on another host).
            msg.to = self.resolve(addr.name);
            addr = peeraddr.Address.parse(msg.to) catch return refused(.unknown_address);
            if (addr.host) |h2| if (!self.isSelfHost(h2)) return self.routeRemote(msg, h2, waiter, now, id_buf);
        }
        if (std.mem.eql(u8, addr.name, msg.from.address)) return refused(.self);

        const live = self.livePeer(addr.name);
        const box = if (live != null) self.boxOf(addr.name).? else blk: {
            if (self.goneHas(addr.name)) return refused(.not_durable_gone);
            const b = self.boxOf(addr.name) orelse return refused(.unknown_address);
            if (self.liveClaimant(addr.name)) return refused(.name_taken_ambiguous);
            break :blk b;
        };
        if (full(box, msg.text.len)) return refused(.mailbox_full);

        // A recipient that cannot hold slow mail is woken, as before.
        const verdict: peerwake.Verdict = if (live) |l| (if (l.slow_mail) peerwake.judge(self.wake, &self.limiter, self.allocator, msg.quiet, msg.from.address, addr.name, recipientOf(l), now) else .wake) else .wake;
        const slow = switch (verdict) {
            .wake => false,
            .slow => true,
        };
        const id = msg.id orelse try mintId(id_buf);
        const s = try self.newStored(.{
            .kind = .message,
            .id = id,
            .from = msg.from,
            .to = addr.name,
            .sent_ms = msg.sent_ms,
            .text = msg.text,
            .reply_to = msg.reply_to,
            .queued = live == null,
            // Mail waiting for a server keeps the sender's word.
            .quiet = if (live != null) slow else msg.quiet,
        });
        try self.appendItem(box, s);
        if (live) |l| {
            const polls = l.armed == false;
            if (self.push(l.conn, s, now)) {
                s.delivered_to = l.conn;
                return switch (verdict) {
                    .wake => .{ .id = id, .outcome = .delivered, .to_state = l.state, .to_polls = polls },
                    .slow => |why| .{ .id = id, .outcome = .queued_slow, .reason = why, .to_state = l.state, .to_polls = polls },
                };
            }
            return .{ .id = id, .outcome = .queued, .to_state = l.state, .to_polls = polls };
        }
        return .{ .id = id, .outcome = .queued, .to_state = .gone, .to_no_mcp = box.noMcp(now) };
    }

    /// `msg` for `host`: into its route's outbound mailbox, relayed now when
    /// the link is up (the answer then waits for the far broker's).
    fn routeRemote(self: *Store, msg: Msg, host: []const u8, waiter: Waiter, now: i64, id_buf: *[ID_LEN]u8) Error!SendResult {
        const r = self.routeTo(host) orelse return refused(if (self.hub) .unknown_address else .federation_unavailable);
        switch (r.link) {
            .unsupported => return refused(.federation_unavailable),
            .up, .down => {},
        }
        if (full(r.box, msg.text.len)) return refused(.mailbox_full);
        // A far broker that keys relays by id alone would take a second
        // recipient of one `to_list` message as a redelivery of the first.
        if (msg.id) |id| if (!r.far_slow and r.box.findOther(id, msg.to) != null) return refused(.federation_unavailable);
        const id = msg.id orelse try mintId(id_buf);
        const s = try self.newStored(.{
            .kind = .message,
            .id = id,
            .from = msg.from,
            .to = msg.to,
            .sent_ms = msg.sent_ms,
            .text = msg.text,
            .reply_to = msg.reply_to,
            .quiet = msg.quiet,
        });
        try self.appendItem(r.box, s);
        if (r.conn != 0 and self.relayItem(r, s, now)) {
            // Forwarded mail has nobody waiting: a far refusal becomes an
            // event to its sender (`takeStored`).
            if (waiter == .none) return .{ .id = id, .outcome = .queued };
            try self.addPending(id, msg.to, waiter, r.conn, now);
            return .{ .id = id, .outcome = .queued, .deferred = true };
        }
        return .{ .id = id, .outcome = .queued, .reason = .host_unreachable };
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
    /// when the sender is offline, relayed when the sender is remote) and a
    /// tombstone for its recipient (none for a route's outbound mail); an
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
                        const route_box = box.isRoute();
                        if (!route_box) box.addExpired(&s.item, now);
                        self.notifySender(&s.item, .{
                            .id = s.item.id,
                            .outcome = .expired,
                            .to = if (route_box) s.item.to else box.address,
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

    /// Every live peer, then every durable address with no live server,
    /// then every federated host's peers. Strings borrow the store; valid
    /// until its next mutation.
    pub fn list(self: *Store, arena: std.mem.Allocator, now: i64) error{OutOfMemory}![]PeerInfo {
        var out: std.ArrayList(PeerInfo) = .empty;
        try self.listLocal(arena, &out, now);
        for (self.routes.items) |r| for (r.peers) |p| {
            var e = p;
            e.link = linkOf(r, p.link);
            try out.append(arena, e);
        };
        return out.items;
    }

    fn listLocal(self: *Store, arena: std.mem.Allocator, out: *std.ArrayList(PeerInfo), now: i64) error{OutOfMemory}!void {
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
                .polls = p.armed == false,
                .facts = if (p.facts_json.len > 0) std.json.parseFromSliceLeaky(std.json.Value, arena, p.facts_json, .{}) catch null else null,
                .model = p.model,
                .last_notification = p.last_notification,
                .subject = if (box) |b| b.subject else "",
                .alias = if (box) |b| b.alias else "",
            });
        }
        for (self.boxes.items) |b| {
            if (!b.durable or b.isRoute() or self.livePeer(b.address) != null) continue;
            const no_mcp = b.noMcp(now);
            try out.append(arena, .{
                .address = b.address,
                .host = self.host,
                .state = .gone,
                .durable = true,
                .last_seen_ms = if (no_mcp) b.hook_ms else b.last_seen_ms,
                .pending = @intCast(b.items.items.len),
                .subject = b.subject,
                .alias = b.alias,
                .no_mcp = no_mcp,
            });
        }
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
            .alias = self.aliasOf(p.address),
            .alias_refused = p.alias_refused,
        };
    }

    /// The effective address of `conn`, if registered.
    pub fn addressOf(self: *Store, conn: u32) ?[]const u8 {
        return if (self.peerOf(conn)) |p| p.address else null;
    }

    /// The answer `conn` gets: in older words when its client predates
    /// slow mail (`RegisterReq.slow_mail`), which would not parse them.
    pub fn replyFor(self: *const Store, conn: u32, reply: SendReply) SendReply {
        const p = self.peerOf(conn) orelse return reply;
        if (p.slow_mail) return reply;
        var r = reply;
        r.outcome = r.outcome.compat();
        r.reason = if (r.reason) |why| why.compat() else null;
        r.results = &.{};
        return r;
    }

    /// Set (or with "" clear) the subject of `address`: a live peer of this
    /// host or a durable address (`knows`). A durable one persists it at once.
    /// @return error.UnknownAddress when it is neither.
    pub fn setSubject(self: *Store, address: []const u8, subject: []const u8) (SubjectError || error{ UnknownAddress, OutOfMemory })!void {
        try checkSubject(subject);
        if (!self.knows(address)) return error.UnknownAddress;
        const box = self.boxOf(address).?;
        if (std.mem.eql(u8, box.subject, subject)) return;
        const owned = try self.allocator.dupe(u8, subject);
        self.allocator.free(box.subject);
        box.subject = owned;
        self.presence_dirty = true;
        self.roster_gen +%= 1;
        self.writeMeta(box);
    }

    /// The subject of `address`, "" when none or unknown.
    pub fn subjectOf(self: *const Store, address: []const u8) []const u8 {
        return if (self.boxOf(address)) |b| b.subject else "";
    }

    /// `address` is a live peer of this host or a durable address here.
    pub fn knows(self: *const Store, address: []const u8) bool {
        const box = self.boxOf(address) orelse return false;
        return !box.isRoute() and (box.durable or self.livePeer(address) != null);
    }

    /// A session's hook or status line reported with no live server of its
    /// own (`HookPresence`): the durable address whose last server's client
    /// is the nearest process of `ancestry` reads `no_mcp` from now on, until
    /// `HOOK_FRESH_MS` without another report, a server registers it again,
    /// or `state` says the session ended (`gone`).
    /// @return the address it named, null when none matched.
    pub fn hookPresence(self: *Store, ancestry: []const i32, state: ?PeerState, now: i64) ?[]const u8 {
        for (ancestry) |pid| {
            if (pid <= 1) continue;
            for (self.boxes.items) |b| {
                if (b.client_pid != pid or !b.durable or b.isRoute() or self.livePeer(b.address) != null) continue;
                const was = b.noMcp(now);
                const ended = if (state) |s| s == .gone else false;
                b.hook_ms = if (ended) 0 else now;
                if (was != b.noMcp(now)) self.presence_dirty = true;
                return b.address;
            }
        }
        return null;
    }

    /// A registration carried a subject: one the rule refuses costs only
    /// the subject (the client checks first; this guards the broker).
    fn subjectFromRegistration(self: *Store, address: []const u8, subject: []const u8) void {
        self.setSubject(address, subject) catch |e| switch (e) {
            error.SubjectTooLong, error.SubjectNotText => self.warnf("peermail: {s}'s registration carried a refused subject: {s}", .{ address, subjectRefusal(@errorCast(e)) }),
            error.UnknownAddress, error.OutOfMemory => self.warnf("peermail: {s}'s subject was not kept", .{address}),
        };
    }

    // ---------------------------------------------------------- aliases

    /// The alias of `address` here, "" when none.
    pub fn aliasOf(self: *const Store, address: []const u8) []const u8 {
        return if (self.boxOf(address)) |b| b.alias else "";
    }

    /// The session the live peer `address` runs in carries the user title
    /// `title` (the owner derives it: `daemon_peers.sessionTitle`). Its
    /// first title becomes the address's alias when it has none and its
    /// subject when it has none, once (`titled`): a later title moves
    /// neither, and a subject the user cleared stays cleared.
    pub fn offerTitle(self: *Store, address: []const u8, title: []const u8, now: i64) error{OutOfMemory}!void {
        if (title.len == 0) return;
        const p = self.livePeer(address) orelse return;
        if (p.name_taken) return;
        const box = self.boxOf(address) orelse return;
        if (box.alias.len == 0) {
            var sb: [peeraddr.SLUG_MAX]u8 = undefined;
            var ab: [peeraddr.ALIAS_MAX]u8 = undefined;
            if (peeraddr.slugify(&sb, title)) |slug| {
                if (self.chooseAlias(&ab, slug, address, .resume_gone)) |ch| try self.giveAlias(box, ch, now);
            }
        }
        if (box.titled) return;
        box.titled = true;
        const subject = utf8Prefix(title, SUBJECT_MAX);
        if (box.subject.len == 0 and if (checkSubject(subject)) true else |_| false) {
            const owned = try self.allocator.dupe(u8, subject);
            self.allocator.free(box.subject);
            box.subject = owned;
            self.presence_dirty = true;
            self.roster_gen +%= 1;
        }
        self.writeMeta(box);
    }

    /// The address of this host that `name` names (an alias or an
    /// address); null when it names none.
    pub fn resolveLocal(self: *const Store, name: []const u8) ?[]const u8 {
        const r = self.resolve(name);
        return if (self.knows(r)) r else null;
    }

    /// What `to` names, as this side addresses it: a host-qualified
    /// address as it is; the holder of the exact alias `to` (a live one
    /// first); a known address; the holder of `to`'s slug (so `Zenit`
    /// finds `zenit`); where a yielded address's alias went (`Moved`);
    /// else `to` itself. May borrow the store until its next mutation.
    fn resolve(self: *const Store, to: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, to, '/') != null) return to;
        if (self.holderOf(to, null)) |h| return h.address;
        if (self.boxOf(to) != null or self.goneHas(to)) return to;
        var sb: [peeraddr.SLUG_MAX]u8 = undefined;
        if (peeraddr.slugify(&sb, to)) |slug| if (self.holderOf(slug, null)) |h| return h.address;
        if (self.movedAlias(to)) |al| if (self.holderOf(al, null)) |h| return h.address;
        return to;
    }

    /// The live peer `p` asks for the alias `want`. Explicit: exactly its
    /// slug, refused (`alias_refused`) when a live holder has it.
    fn requestAlias(self: *Store, p: *Peer, want: []const u8, explicit: bool, now: i64) error{OutOfMemory}!void {
        self.allocator.free(p.alias_refused);
        p.alias_refused = &.{};
        const box = self.boxOf(p.address) orelse return;
        var sb: [peeraddr.SLUG_MAX]u8 = undefined;
        const slug = if (explicit and peeraddr.validAlias(want)) want else peeraddr.slugify(&sb, want) orelse return;
        var ab: [peeraddr.ALIAS_MAX]u8 = undefined;
        const choice = self.chooseAlias(&ab, slug, p.address, if (explicit) .explicit else .resume_gone) orelse {
            if (self.holderOf(slug, p.address)) |h| p.alias_refused = try self.allocator.dupe(u8, h.address);
            return;
        };
        try self.giveAlias(box, choice, now);
    }

    /// Who holds `alias` other than `except` (null: anyone): a live holder
    /// first, local before remote; a gone one only when none is live. A
    /// peer behind a link that is down counts as it was last reported, so
    /// a session elsewhere keeps its alias through an outage.
    fn holderOf(self: *const Store, alias: []const u8, except: ?[]const u8) ?Holder {
        var gone: ?Holder = null;
        for (self.boxes.items) |b| {
            if (b.isRoute() or !std.mem.eql(u8, b.alias, alias)) continue;
            if (except) |x| if (std.mem.eql(u8, b.address, x)) continue;
            const h = Holder{ .address = b.address, .live = self.livePeer(b.address) != null, .box = b, .subject = b.subject };
            if (h.live) return h;
            if (gone == null) gone = h;
        }
        for (self.routes.items) |r| for (r.peers) |p| {
            if (!std.mem.eql(u8, p.alias, alias)) continue;
            if (except) |x| if (std.mem.eql(u8, p.address, x)) continue;
            const h = Holder{ .address = p.address, .live = p.live, .subject = p.subject };
            if (h.live) return h;
            if (gone == null) gone = h;
        };
        return gone;
    }

    /// The first of `base`, `base-1`, `base-2`, ... that `address` may take
    /// under `claim`; one it already holds counts as free.
    fn chooseAlias(self: *const Store, buf: *[peeraddr.ALIAS_MAX]u8, base: []const u8, address: []const u8, claim: Claim) ?Choice {
        var k: u32 = 0;
        while (k <= peeraddr.ALIAS_SUFFIX_MAX) : (k += 1) {
            const cand = peeraddr.aliasCandidate(buf, base, k);
            const h = self.holderOf(cand, address) orelse return .{ .alias = cand };
            switch (claim) {
                .resume_gone => if (!h.live) return .{ .alias = cand, .resumes = h },
                .free_only => {},
                .explicit => return if (h.live) null else .{ .alias = cand, .resumes = h },
            }
        }
        return null;
    }

    /// `box` takes `choice.alias`. A gone holder's mailbox here yields to
    /// it at once; a gone holder elsewhere lends its subject, and its own
    /// broker forwards its mail once it sees the alias held (`reconcile`).
    fn giveAlias(self: *Store, box: *Box, choice: Choice, now: i64) error{OutOfMemory}!void {
        if (!std.mem.eql(u8, box.alias, choice.alias)) {
            const owned = try self.allocator.dupe(u8, choice.alias);
            self.allocator.free(box.alias);
            box.alias = owned;
            self.writeMeta(box);
            self.presence_dirty = true;
            self.roster_gen +%= 1;
            if (self.livePeer(box.address)) |p| _ = self.emit.call(p.conn, .self_changed);
        }
        const h = choice.resumes orelse return;
        if (h.box) |old| return self.yieldBox(old, box.address, now);
        if (box.subject.len == 0 and h.subject.len > 0) self.subjectFromRegistration(box.address, h.subject);
    }

    /// The gone mailbox `old` gives its alias up to the holder `to_in` (as
    /// this side names it): its messages and events go there, by relay when
    /// `to_in` is on another host, and a local `to_in` without a subject
    /// takes `old`'s. `old` is then forgotten, files and all; mail still
    /// sent to its address follows the alias (`Moved`).
    fn yieldBox(self: *Store, old: *Box, to_in: []const u8, now: i64) void {
        var tb: [peeraddr.ADDRESS_MAX]u8 = undefined;
        const n = @min(to_in.len, tb.len);
        @memcpy(tb[0..n], to_in[0..n]);
        const to = tb[0..n];
        self.movedAdd(old.address, old.alias);
        const local: ?*Box = blk: {
            const a = peeraddr.Address.parse(to) catch break :blk null;
            if (a.host) |h| if (!self.isSelfHost(h)) break :blk null;
            break :blk self.boxOf(a.name);
        };
        var items = old.items;
        old.items = .empty;
        defer items.deinit(self.allocator);
        if (local) |nb| {
            if (nb.subject.len == 0 and old.subject.len > 0) self.subjectFromRegistration(nb.address, old.subject);
            for (items.items) |s| {
                if (s.item.kind == .message) s.item.to = s.arena.allocator().dupe(u8, nb.address) catch s.item.to;
                s.delivered_to = 0;
                self.appendItem(nb, s) catch {
                    self.warnf("peermail: {s} lost moving from {s}: out of memory", .{ s.item.id, old.address });
                    freeStored(self.allocator, s);
                };
            }
            if (self.livePeer(nb.address)) |p| self.flush(p.conn, now);
        } else for (items.items) |s| {
            defer freeStored(self.allocator, s);
            switch (s.item.kind) {
                .message => {
                    var idb: [ID_LEN]u8 = undefined;
                    const res = self.route(.{ .id = s.item.id, .from = s.item.from, .to = to, .sent_ms = s.item.sent_ms, .text = s.item.text, .reply_to = s.item.reply_to, .quiet = s.item.quiet }, .none, now, &idb) catch |e| {
                        self.warnf("peermail: {s} lost forwarding from {s}: {s}", .{ s.item.id, old.address, @errorName(e) });
                        continue;
                    };
                    if (res.outcome == .refused) self.notifySender(&s.item, .{ .id = s.item.id, .outcome = .refused, .reason = res.reason, .to = to, .queued_ms = now - s.item.sent_ms }, now);
                },
                .event => self.deliverEvent(to, .{ .id = s.item.id, .outcome = s.item.outcome, .reason = s.item.reason, .to = s.item.to, .queued_ms = s.item.queued_ms }, now),
            }
        }
        self.dropBox(old);
    }

    /// Every gone mailbox here whose alias a live holder elsewhere holds
    /// yields to it (a session that resumed the alias on another host, or
    /// a member's claim the hub kept).
    fn reconcile(self: *Store, now: i64) void {
        var i: usize = 0;
        while (i < self.boxes.items.len) {
            const b = self.boxes.items[i];
            i += 1;
            if (b.isRoute() or b.alias.len == 0 or self.livePeer(b.address) != null) continue;
            const h = self.holderOf(b.alias, b.address) orelse continue;
            if (!h.live) continue;
            self.yieldBox(b, h.address, now);
            i = 0;
        }
    }

    /// Forget the mailbox `box` and its files.
    fn dropBox(self: *Store, box: *Box) void {
        const i = self.boxIndex(box.address) orelse return;
        _ = self.boxes.orderedRemove(i);
        if (box.durable) {
            var pbuf: [4096]u8 = undefined;
            if (self.filePath(&pbuf, box.address)) |path| self.unlinkPath(path);
            if (self.metaPath(&pbuf, box.address)) |path| self.unlinkPath(path);
        }
        self.presence_dirty = true;
        self.roster_gen +%= 1;
        self.freeBox(box);
    }

    fn unlinkPath(self: *Store, path: []const u8) void {
        var z: [4096]u8 = undefined;
        const pz = pathz.pathZ(&z, path) catch return;
        if (c.unlink(pz) != 0 and std.c._errno().* != c.ENOENT) self.warnf("peermail: cannot remove {s}", .{path});
    }

    fn movedAdd(self: *Store, address: []const u8, alias: []const u8) void {
        var m = Moved{};
        const n = @min(address.len, m.addr_buf.len);
        @memcpy(m.addr_buf[0..n], address[0..n]);
        m.addr_len = @intCast(n);
        const k = @min(alias.len, m.alias_buf.len);
        @memcpy(m.alias_buf[0..k], alias[0..k]);
        m.alias_len = @intCast(k);
        if (self.moved_len < MOVED_RING) {
            self.moved[self.moved_len] = m;
            self.moved_len += 1;
        } else {
            self.moved[self.moved_head] = m;
            self.moved_head = (self.moved_head + 1) % MOVED_RING;
        }
    }

    /// The alias the yielded `address` moved with, newest first.
    fn movedAlias(self: *const Store, address: []const u8) ?[]const u8 {
        var k = self.moved_len;
        while (k > 0) {
            k -= 1;
            const m = &self.moved[(self.moved_head + k) % self.moved_len];
            if (std.mem.eql(u8, m.address(), address)) return m.alias();
        }
        return null;
    }

    /// Hub: judge the aliases link `r`'s member reported against everyone
    /// else's. A grant already decided overrides what the member still
    /// reports and goes once it reports it; a live peer whose alias another
    /// live holder already has (the newer claim) is granted the next one.
    fn judgeAliases(self: *Store, r: *Route) error{OutOfMemory}!void {
        const a = r.arena.allocator();
        var gi: usize = 0;
        while (gi < r.grants.items.len) {
            const g = r.grants.items[gi];
            const p: ?*PeerInfo = for (r.peers) |*pp| {
                if (std.mem.eql(u8, pp.address, g.address)) break pp;
            } else null;
            if (p == null or std.mem.eql(u8, p.?.alias, g.alias)) {
                freeGrant(self.allocator, r.grants.orderedRemove(gi));
                continue;
            }
            p.?.alias = try a.dupe(u8, g.alias);
            gi += 1;
        }
        for (r.peers) |*p| {
            if (!p.live or p.alias.len == 0) continue;
            const h = self.holderOf(p.alias, p.address) orelse continue;
            if (!h.live) continue;
            var ab: [peeraddr.ALIAS_MAX]u8 = undefined;
            const ch = self.chooseAlias(&ab, peeraddr.aliasBase(p.alias), p.address, .resume_gone) orelse continue;
            p.alias = try a.dupe(u8, ch.alias);
            try self.setGrant(r, p.address, p.alias);
        }
    }

    fn setGrant(self: *Store, r: *Route, address: []const u8, alias: []const u8) error{OutOfMemory}!void {
        const owned_alias = try self.allocator.dupe(u8, alias);
        errdefer self.allocator.free(owned_alias);
        for (r.grants.items) |*g| if (std.mem.eql(u8, g.address, address)) {
            self.allocator.free(g.alias);
            g.alias = owned_alias;
            return;
        };
        const owned_addr = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(owned_addr);
        try r.grants.append(self.allocator, .{ .address = owned_addr, .alias = owned_alias });
    }

    /// Member: the aliases the hub decided for this host's peers.
    fn applyGrants(self: *Store, grants: []const Grant, now: i64) void {
        for (grants) |g| {
            if (!peeraddr.validAlias(g.alias)) continue;
            const box = self.boxOf(g.address) orelse continue;
            if (box.isRoute() or std.mem.eql(u8, box.alias, g.alias)) continue;
            self.giveAlias(box, .{ .alias = g.alias }, now) catch self.warnf("peermail: out of memory taking the hub's alias {s} for {s}", .{ g.alias, g.address });
        }
    }

    /// Migration, once per mailbox: a durable address from before aliases
    /// (a name, not a minted `p-`/`n-`/`anon-` one) takes its own slug, or
    /// the next free suffix (nothing is merged), in address order.
    fn migrateLegacy(self: *Store) void {
        var legacy: std.ArrayList(*Box) = .empty;
        defer legacy.deinit(self.allocator);
        for (self.boxes.items) |b| {
            if (b.isRoute() or !b.durable or b.alias.len > 0 or peeraddr.isReservedName(b.address)) continue;
            legacy.append(self.allocator, b) catch return self.warnf("peermail: out of memory migrating mailboxes to aliases", .{});
        }
        std.mem.sort(*Box, legacy.items, {}, struct {
            fn lt(_: void, x: *Box, y: *Box) bool {
                return std.mem.lessThan(u8, x.address, y.address);
            }
        }.lt);
        for (legacy.items) |b| {
            var sb: [peeraddr.SLUG_MAX]u8 = undefined;
            var ab: [peeraddr.ALIAS_MAX]u8 = undefined;
            const slug = peeraddr.slugify(&sb, b.address) orelse continue;
            const ch = self.chooseAlias(&ab, slug, b.address, .free_only) orelse continue;
            b.alias = self.allocator.dupe(u8, ch.alias) catch return self.warnf("peermail: out of memory migrating mailboxes to aliases", .{});
            self.writeMeta(b);
        }
    }

    // ------------------------------------------------------- federation

    /// This broker's part in federation.
    pub fn federation(self: *const Store) PeerFederation {
        if (self.hub) return .hub;
        return if (self.uplink() != null) .member else .off;
    }

    /// Every federated host and its link: on a hub one per domain; on a
    /// member the hub (`host` empty until it said hello since this broker
    /// started) and then the hosts it reported, down while the uplink is.
    pub fn hostList(self: *Store, arena: std.mem.Allocator) error{OutOfMemory}![]HostInfo {
        var out: std.ArrayList(HostInfo) = .empty;
        for (self.routes.items) |r| {
            try out.append(arena, .{ .host = r.host, .link = r.link, .last_seen_ms = r.last_seen_ms, .direction = r.direction });
            for (r.hosts) |h| try out.append(arena, .{ .host = h.host, .link = linkOf(r, h.link), .last_seen_ms = h.last_seen_ms });
        }
        return out.items;
    }

    /// Hub: the link to `domain` came up as connection `conn`, its far
    /// broker reading slow mail when `far_slow`; its outbound mail is
    /// relayed at once.
    pub fn linkUp(self: *Store, domain: []const u8, conn: u32, far_slow: bool, now: i64) void {
        const r = self.routeNamed(domain) orelse return;
        r.far_slow = far_slow;
        self.attach(r, conn, now);
    }

    /// `domain`'s daemon predates federation (on a member: the hub it
    /// calls in to predates call-ins).
    pub fn linkUnsupported(self: *Store, domain: []const u8, now: i64) void {
        const r = (if (self.hub) self.routeNamed(domain) else (self.ensureUplink() catch null)) orelse return;
        if (r.conn != 0) self.detach(r, now);
        r.link = .unsupported;
        r.last_seen_ms = now;
        self.presence_dirty = true;
    }

    /// Member: a hub said hello on connection `conn`, which `direction`
    /// says who dialed. A newer hello replaces an older link.
    pub fn uplinkUp(self: *Store, conn: u32, hello: HubHello, direction: PeerLinkDirection, now: i64) LinkError!void {
        if (self.hub) return error.NotLinked;
        peeraddr.validHost(hello.host) catch return error.BadAddress;
        peeraddr.validHost(hello.as) catch return error.BadAddress;
        const r = try self.ensureUplink();
        const host = try self.allocator.dupe(u8, hello.host);
        errdefer self.allocator.free(host);
        const as = try self.allocator.dupe(u8, hello.as);
        self.allocator.free(r.host);
        r.host = host;
        self.allocator.free(self.as_name);
        self.as_name = as;
        if (r.conn != 0 and r.conn != conn) self.detach(r, now);
        self.touchFile(r.box);
        r.direction = direction;
        r.far_slow = hello.slow_mail;
        self.attach(r, conn, now);
    }

    /// Connection `conn` closed: a link it carried is down. Its peers stay
    /// listed with their last state; sends waiting on it learn `queued`.
    pub fn connGone(self: *Store, conn: u32, now: i64) void {
        const r = self.routeByConn(conn) orelse return;
        self.detach(r, now);
    }

    /// One relayed item from link `conn`.
    /// @return error.NotLinked when `conn` carries no link (no hello yet).
    pub fn relayIn(self: *Store, conn: u32, rl: Relay, now: i64) LinkError!void {
        const r = self.routeByConn(conn) orelse return error.NotLinked;
        r.last_seen_ms = now;
        switch (rl.kind) {
            .presence => try self.takePresence(r, rl, now),
            .mail => try self.takeMail(r, rl, now),
            .event => self.takeEvent(r, rl, now),
            .stored => self.takeStored(r, rl, now),
        }
    }

    /// Periodic federation work: sends whose far answer is overdue learn
    /// `queued`, a `no_mcp` past `HOOK_FRESH_MS` lapses, and each live link
    /// gets the presence snapshot it is owed.
    pub fn tick(self: *Store, now: i64) void {
        self.answerPending(.{ .overdue = now });
        for (self.boxes.items) |b| if (b.hook_ms > 0 and !b.noMcp(now)) {
            b.hook_ms = 0;
            self.presence_dirty = true;
        };
        if (!self.presence_dirty) return;
        self.presence_dirty = false;
        for (self.routes.items) |r| {
            if (r.conn != 0) self.sendPresence(r, now) catch self.warnf("peermail: out of memory relaying presence to {s}", .{r.host});
        }
    }

    fn attach(self: *Store, r: *Route, conn: u32, now: i64) void {
        r.conn = conn;
        r.link = .up;
        r.last_seen_ms = now;
        self.presence_dirty = true;
        for (r.box.items.items) |s| {
            if (s.delivered_to != conn) _ = self.relayItem(r, s, now);
        }
    }

    fn detach(self: *Store, r: *Route, now: i64) void {
        const old = r.conn;
        r.conn = 0;
        r.link = .down;
        r.last_seen_ms = now;
        self.presence_dirty = true;
        self.answerPending(.{ .route_conn = old });
    }

    fn takePresence(self: *Store, r: *Route, rl: Relay, now: i64) error{OutOfMemory}!void {
        _ = r.arena.reset(.free_all);
        r.peers = &.{};
        r.hosts = &.{};
        const a = r.arena.allocator();
        const via = try a.dupe(u8, r.host);
        const peers = try a.alloc(PeerInfo, @min(rl.peers.len, PRESENCE_PEERS_MAX));
        for (rl.peers[0..peers.len], peers) |p, *o| {
            var b: [peeraddr.ADDRESS_MAX]u8 = undefined;
            o.* = .{
                .address = try a.dupe(u8, self.inAddr(&b, r, p.address)),
                .host = try a.dupe(u8, p.host),
                .app = try a.dupe(u8, p.app),
                .cwd = try a.dupe(u8, p.cwd),
                .pid = p.pid,
                .state = p.state,
                .durable = p.durable,
                .live = p.live,
                .last_seen_ms = RelayAge.seenAt(now, p.last_seen_ms),
                .pending = p.pending,
                .name_taken = p.name_taken,
                .polls = p.polls,
                .no_mcp = p.no_mcp,
                .facts = if (p.facts) |f| try cloneJson(a, f) else null,
                .model = try a.dupe(u8, p.model),
                .last_notification = try a.dupe(u8, p.last_notification),
                .subject = try a.dupe(u8, p.subject),
                .alias = try a.dupe(u8, p.alias),
                .via_host = via,
                // A hub judges its own links; a member keeps the hub's view.
                .link = if (self.hub) null else p.link,
            };
        }
        r.peers = peers;
        if (!self.hub) {
            const hosts = try a.alloc(HostInfo, @min(rl.hosts.len, PRESENCE_PEERS_MAX));
            for (rl.hosts[0..hosts.len], hosts) |h, *o| o.* = .{ .host = try a.dupe(u8, h.host), .link = h.link, .last_seen_ms = RelayAge.seenAt(now, h.last_seen_ms) };
            r.hosts = hosts;
        }
        // The hub judges every claim against the network and passes every
        // host's peers on to the others; a member takes what it decided.
        if (self.hub) {
            try self.judgeAliases(r);
            self.presence_dirty = true;
        } else self.applyGrants(rl.grants, now);
        self.reconcile(now);
    }

    fn takeMail(self: *Store, r: *Route, rl: Relay, now: i64) Error!void {
        if (!validId(rl.id)) return self.warnf("peermail: relayed mail from {s} without a valid id dropped", .{r.host});
        var tb: [peeraddr.ADDRESS_MAX]u8 = undefined;
        const to = self.inAddr(&tb, r, rl.to);
        if (self.seenFind(rl.id, .message, to)) |sn| return self.answerStored(r, rl.id, .message, to, .{ .outcome = sn.outcome, .reason = sn.reason });
        // Still waiting for a third host's answer: answer this link instead.
        if (self.pendingIndex(rl.id, to)) |i| {
            self.pending.items[i].waiter = .{ .link = r.conn };
            return;
        }
        // A member speaks only for its own peers, and is handed only mail for them.
        const foreign = if (self.hub)
            std.mem.indexOfScalar(u8, rl.from.address, '/') != null
        else blk: {
            const addr = peeraddr.Address.parse(rl.to) catch break :blk false;
            break :blk if (addr.host) |h| !self.isSelfHost(h) else false;
        };
        if (foreign) return self.answerStored(r, rl.id, .message, to, .{ .outcome = .refused, .reason = .unknown_address });
        if (rl.text.len > PEER_TEXT_MAX) return self.answerStored(r, rl.id, .message, to, .{ .outcome = .refused, .reason = .too_large });
        var fb: [peeraddr.ADDRESS_MAX]u8 = undefined;
        var idb: [ID_LEN]u8 = undefined;
        const res = try self.route(.{
            .id = rl.id,
            .from = .{ .address = self.inAddr(&fb, r, rl.from.address), .host = rl.from.host, .cwd = rl.from.cwd, .app = rl.from.app, .pid = rl.from.pid, .alias = rl.from.alias },
            .to = to,
            .sent_ms = RelayAge.at(now, rl.age_ms),
            .text = rl.text,
            .reply_to = rl.reply_to,
            .quiet = rl.quiet,
        }, .{ .link = r.conn }, now, &idb);
        if (!res.deferred) self.answerStored(r, rl.id, .message, to, .{ .outcome = res.outcome, .reason = res.reason, .to_state = res.to_state, .to_polls = res.to_polls, .to_no_mcp = res.to_no_mcp });
    }

    fn takeEvent(self: *Store, r: *Route, rl: Relay, now: i64) void {
        if (!validId(rl.id)) return self.warnf("peermail: relayed event from {s} without a valid id dropped", .{r.host});
        var tb: [peeraddr.ADDRESS_MAX]u8 = undefined;
        const to = self.inAddr(&tb, r, rl.to);
        if (self.seenFind(rl.id, .event, to)) |sn| return self.answerStored(r, rl.id, .event, to, .{ .outcome = sn.outcome });
        var ob: [peeraddr.ADDRESS_MAX]u8 = undefined;
        const owner = self.inAddr(&ob, r, rl.owner);
        const local = if (peeraddr.Address.parse(owner)) |o| (if (o.host) |h| self.isSelfHost(h) else true) else |_| false;
        if (self.hub or local) {
            self.deliverEvent(owner, .{ .id = rl.id, .outcome = rl.outcome, .reason = rl.reason, .to = to, .queued_ms = rl.queued_ms }, now);
        } else self.warnf("peer event {s} for {s}, not a peer here, dropped", .{ rl.id, owner });
        self.answerStored(r, rl.id, .event, to, .{ .outcome = .delivered });
    }

    fn takeStored(self: *Store, r: *Route, rl: Relay, now: i64) void {
        const ans: Answer = .{ .outcome = rl.outcome, .reason = rl.reason, .to_state = rl.to_state, .to_polls = rl.to_polls, .to_no_mcp = rl.to_no_mcp };
        var tb: [peeraddr.ADDRESS_MAX]u8 = undefined;
        // A far broker that predates (id, to) keys names no recipient.
        const to: ?[]const u8 = if (rl.to.len > 0) self.inAddr(&tb, r, rl.to) else null;
        const i = r.box.findTo(rl.id, rl.of, to) orelse {
            // A duplicate answer, or one for an item that expired meanwhile.
            if (rl.of == .message) if (self.takePending(rl.id, to)) |p| self.answer(p, ans);
            return;
        };
        const s = r.box.items.orderedRemove(i);
        defer freeStored(self.allocator, s);
        self.compact(r.box);
        switch (rl.of) {
            .event => {},
            .message => if (self.takePending(rl.id, s.item.to)) |p| {
                self.answer(p, ans);
            } else if (rl.outcome == .refused) {
                // The sender was told `queued` already: the refusal is news.
                self.notifySender(&s.item, .{ .id = s.item.id, .outcome = .refused, .reason = rl.reason, .to = s.item.to, .queued_ms = now - s.item.sent_ms }, now);
            },
        }
    }

    fn sendPresence(self: *Store, r: *Route, now: i64) error{OutOfMemory}!void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var peers: std.ArrayList(PeerInfo) = .empty;
        try self.listLocal(a, &peers, now);
        var hosts: std.ArrayList(HostInfo) = .empty;
        if (self.hub) for (self.routes.items) |o| {
            if (o == r) continue;
            try hosts.append(a, .{ .host = o.name, .link = o.link, .last_seen_ms = RelayAge.seenAgo(now, o.last_seen_ms) });
            for (o.peers) |p| {
                var e = p;
                e.link = linkOf(o, null);
                try peers.append(a, e);
            }
        };
        for (peers.items) |*p| {
            var b: [peeraddr.ADDRESS_MAX]u8 = undefined;
            p.address = try a.dupe(u8, self.outAddr(&b, r, p.address));
            p.last_seen_ms = RelayAge.seenAgo(now, p.last_seen_ms);
        }
        const grants = try a.alloc(Grant, r.grants.items.len);
        for (r.grants.items, grants) |g, *o| {
            var b: [peeraddr.ADDRESS_MAX]u8 = undefined;
            o.* = .{ .address = try a.dupe(u8, self.outAddr(&b, r, g.address)), .alias = g.alias };
        }
        _ = self.emit.call(r.conn, .{ .relay = .{ .kind = .presence, .peers = peers.items, .hosts = hosts.items, .grants = grants } });
    }

    /// Relay one outbound item on `r`'s live link.
    fn relayItem(self: *Store, r: *Route, s: *Stored, now: i64) bool {
        const it = &s.item;
        var fb: [peeraddr.ADDRESS_MAX]u8 = undefined;
        var tb: [peeraddr.ADDRESS_MAX]u8 = undefined;
        const rl: Relay = switch (it.kind) {
            .message => .{
                .kind = .mail,
                .id = it.id,
                .from = .{ .address = self.outAddr(&fb, r, it.from.address), .host = it.from.host, .cwd = it.from.cwd, .app = it.from.app, .pid = it.from.pid, .alias = it.from.alias },
                .to = self.outAddr(&tb, r, it.to),
                .age_ms = RelayAge.of(now, it.sent_ms),
                .text = it.text,
                .reply_to = it.reply_to,
                .quiet = it.quiet,
            },
            .event => .{
                .kind = .event,
                .id = it.id,
                .owner = self.outAddr(&fb, r, it.owner),
                .to = self.outAddr(&tb, r, it.to),
                .outcome = it.outcome,
                .reason = it.reason,
                .queued_ms = it.queued_ms,
            },
        };
        if (!self.emit.call(r.conn, .{ .relay = rl })) return false;
        s.delivered_to = r.conn;
        return true;
    }

    /// Tell link `r` that item `id` for `to` (as this side names it) was
    /// taken here (or refused), and remember the answer for a redelivery.
    /// A far broker that predates slow mail is answered in older words.
    fn answerStored(self: *Store, r: *Route, id: []const u8, of: Item.Kind, to: []const u8, ans: Answer) void {
        self.seenAdd(id, of, to, ans);
        if (r.conn == 0) return;
        var tb: [peeraddr.ADDRESS_MAX]u8 = undefined;
        _ = self.emit.call(r.conn, .{ .relay = .{
            .kind = .stored,
            .id = id,
            .of = of,
            .to = self.outAddr(&tb, r, to),
            .outcome = if (r.far_slow) ans.outcome else ans.outcome.compat(),
            .reason = if (r.far_slow) ans.reason else if (ans.reason) |why| why.compat() else null,
            .to_state = ans.to_state,
            .to_polls = ans.to_polls,
            .to_no_mcp = ans.to_no_mcp,
        } });
    }

    fn answer(self: *Store, p: Pending, ans: Answer) void {
        switch (p.waiter) {
            .client => |w| _ = self.emit.call(w.conn, .{ .reply = self.replyFor(w.conn, .{ .req = w.req, .id = p.id(), .outcome = ans.outcome, .reason = ans.reason, .to_state = ans.to_state, .to_polls = ans.to_polls, .to_no_mcp = ans.to_no_mcp }) }),
            .link => |lc| if (self.routeByConn(lc)) |o| self.answerStored(o, p.id(), .message, p.to(), ans),
            .multi => |serial| self.answerMulti(serial, p.to(), ans),
            .none => {},
        }
    }

    /// One recipient of a `to_list` send was answered; the last answer
    /// sends the whole reply.
    fn answerMulti(self: *Store, serial: u32, to: []const u8, ans: Answer) void {
        const mi = for (self.multis.items, 0..) |m, k| {
            if (m.serial == serial) break k;
        } else return;
        const m = self.multis.items[mi];
        for (m.results) |*r| if (std.mem.eql(u8, r.to, to) and r.outcome == .queued and r.reason == null) {
            r.outcome = ans.outcome;
            r.reason = ans.reason;
            r.to_state = ans.to_state;
            r.to_polls = ans.to_polls;
            r.to_no_mcp = ans.to_no_mcp;
            m.outstanding -|= 1;
            break;
        };
        if (m.outstanding > 0) return;
        _ = self.multis.orderedRemove(mi);
        defer freeMulti(self.allocator, m);
        const first = if (m.results.len > 0) m.results[0] else RecipientResult{ .to = "", .outcome = .refused };
        _ = self.emit.call(m.conn, .{ .reply = self.replyFor(m.conn, .{ .req = m.req, .id = m.id_buf[0..m.id_len], .outcome = first.outcome, .reason = first.reason, .to_state = first.to_state, .to_polls = first.to_polls, .to_no_mcp = first.to_no_mcp, .results = m.results }) });
    }

    fn addPending(self: *Store, id: []const u8, to: []const u8, waiter: Waiter, route_conn: u32, now: i64) error{OutOfMemory}!void {
        var p = Pending{ .waiter = waiter, .route_conn = route_conn, .deadline_ms = now + PENDING_MS };
        const n = @min(id.len, ID_LEN);
        @memcpy(p.id_buf[0..n], id[0..n]);
        p.id_len = @intCast(n);
        const tn = @min(to.len, p.to_buf.len);
        @memcpy(p.to_buf[0..tn], to[0..tn]);
        p.to_len = @intCast(tn);
        try self.pending.append(self.allocator, p);
    }

    fn pendingIndex(self: *const Store, id: []const u8, to: ?[]const u8) ?usize {
        for (self.pending.items, 0..) |*p, i| if (p.matches(id, to)) return i;
        return null;
    }

    fn takePending(self: *Store, id: []const u8, to: ?[]const u8) ?Pending {
        const i = self.pendingIndex(id, to) orelse return null;
        return self.pending.orderedRemove(i);
    }

    const PendingDue = union(enum) {
        /// Waiting on this link, which dropped.
        route_conn: u32,
        /// Past the deadline at this wall time.
        overdue: i64,
    };

    /// Answer the matching waits `queued` / `host_unreachable`; their items
    /// stay in the outbound mailbox for the next link.
    fn answerPending(self: *Store, due: PendingDue) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const p = self.pending.items[i];
            const hit = switch (due) {
                .route_conn => |rc| p.route_conn == rc,
                .overdue => |now| now >= p.deadline_ms,
            };
            if (!hit) {
                i += 1;
                continue;
            }
            _ = self.pending.orderedRemove(i);
            self.answer(p, .{ .outcome = .queued, .reason = .host_unreachable });
        }
    }

    fn seenAdd(self: *Store, id: []const u8, kind: Item.Kind, to: []const u8, ans: Answer) void {
        var e = Seen{ .kind = kind, .to_key = toKey(to), .outcome = ans.outcome, .reason = ans.reason };
        const n = @min(id.len, ID_LEN);
        @memcpy(e.id_buf[0..n], id[0..n]);
        e.id_len = @intCast(n);
        if (self.seen_len < SEEN_RING) {
            self.seen[self.seen_len] = e;
            self.seen_len += 1;
        } else {
            self.seen[self.seen_head] = e;
            self.seen_head = (self.seen_head + 1) % SEEN_RING;
        }
    }

    fn seenFind(self: *const Store, id: []const u8, kind: Item.Kind, to: []const u8) ?Seen {
        const key = toKey(to);
        for (self.seen[0..self.seen_len]) |e| {
            if (e.kind == kind and e.to_key == key and std.mem.eql(u8, e.id_buf[0..e.id_len], id)) return e;
        }
        return null;
    }

    /// An address as the far side of `r` reads it (only a hub rewrites).
    fn outAddr(self: *const Store, buf: []u8, r: *const Route, addr: []const u8) []const u8 {
        if (!self.hub) return addr;
        return peeraddr.localize(buf, self.host, r.name, addr) catch addr;
    }

    /// An address from the far side of `r` as this side names it.
    fn inAddr(self: *const Store, buf: []u8, r: *const Route, addr: []const u8) []const u8 {
        if (!self.hub) return addr;
        return peeraddr.qualify(buf, r.name, addr) catch addr;
    }

    fn isSelfHost(self: *const Store, host: []const u8) bool {
        if (self.hub) return std.mem.eql(u8, host, self.host);
        return self.as_name.len > 0 and std.mem.eql(u8, host, self.as_name);
    }

    /// The route mail for `host` takes: its domain's on a hub, the uplink
    /// on a member.
    fn routeTo(self: *const Store, host: []const u8) ?*Route {
        return if (self.hub) self.routeNamed(host) else self.uplink();
    }

    fn routeNamed(self: *const Store, name: []const u8) ?*Route {
        for (self.routes.items) |r| if (!r.isUplink() and std.mem.eql(u8, r.name, name)) return r;
        return null;
    }

    fn uplink(self: *const Store) ?*Route {
        for (self.routes.items) |r| if (r.isUplink()) return r;
        return null;
    }

    fn routeByConn(self: *const Store, conn: u32) ?*Route {
        if (conn == 0) return null;
        for (self.routes.items) |r| if (r.conn == conn) return r;
        return null;
    }

    fn ensureUplink(self: *Store) error{OutOfMemory}!*Route {
        if (self.uplink()) |r| return r;
        return self.addRoute("");
    }

    fn addRoute(self: *Store, name: []const u8) error{OutOfMemory}!*Route {
        var key_buf: [ROUTE_PREFIX.len + peeraddr.HOST_MAX]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, ROUTE_PREFIX ++ "{s}", .{name}) catch return error.OutOfMemory;
        const box = try self.ensureBox(key, true);
        const r = try self.allocator.create(Route);
        errdefer self.allocator.destroy(r);
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        r.* = .{ .name = owned, .host = try self.allocator.dupe(u8, name), .box = box, .arena = .init(self.allocator) };
        errdefer self.allocator.free(r.host);
        try self.routes.append(self.allocator, r);
        return r;
    }

    fn freeRoute(self: *Store, r: *Route) void {
        r.arena.deinit();
        for (r.grants.items) |g| freeGrant(self.allocator, g);
        r.grants.deinit(self.allocator);
        self.allocator.free(r.name);
        self.allocator.free(r.host);
        self.allocator.destroy(r);
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
            if (std.mem.startsWith(u8, address, ROUTE_PREFIX)) {
                const name = address[ROUTE_PREFIX.len..];
                if (name.len > 0) peeraddr.validHost(name) catch {
                    self.warnf("peermail: ignoring {s}: not a route mailbox", .{fname});
                    continue;
                };
                self.loadFile(address);
                // A member stays one across restarts: its uplink mailbox
                // is the record that a hub said hello.
                if (name.len == 0 and !self.hub) _ = self.ensureUplink() catch self.warnf("peermail: out of memory loading {s}", .{fname});
                continue;
            }
            peeraddr.validName(address) catch {
                self.warnf("peermail: ignoring {s}: not a peer address", .{fname});
                continue;
            };
            self.loadFile(address);
        }
        self.migrateLegacy();
    }

    fn metaPath(self: *Store, buf: []u8, address: []const u8) ?[]const u8 {
        const dir = self.dir orelse return null;
        return std.fmt.bufPrint(buf, "{s}/{s}" ++ META_EXT, .{ dir, address }) catch null;
    }

    /// Persist a durable address's `AddressMeta`; nothing to keep removes the file.
    fn writeMeta(self: *Store, box: *Box) void {
        if (!box.durable or self.dir == null) return;
        var pbuf: [4096]u8 = undefined;
        const path = self.metaPath(&pbuf, box.address) orelse return;
        if (box.subject.len == 0 and box.alias.len == 0 and !box.titled) return self.unlinkPath(path);
        pathz.makeDirs(self.dir.?, 0o700) catch return self.warnf("peermail: cannot create {s}; the subject and alias of {s} are kept in memory only", .{ self.dir.?, box.address });
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(AddressMeta{ .subject = box.subject, .alias = box.alias, .titled = box.titled }, .{}, &aw.writer) catch return self.warnf("peermail: out of memory writing {s}", .{path});
        atomicwrite.writeFileExact(path, aw.written(), 0o600) catch |e| self.warnf("peermail: cannot write {s} ({s})", .{ path, @errorName(e) });
    }

    /// Read a durable address's `AddressMeta`; a missing file is none, and
    /// an unreadable one or a subject the rule refuses costs only itself.
    fn loadMeta(self: *Store, box: *Box) void {
        var pbuf: [4096]u8 = undefined;
        const path = self.metaPath(&pbuf, box.address) orelse return;
        const parsed = readfile.json(AddressMeta, self.allocator, path, 4096) orelse return;
        defer parsed.deinit();
        const m = parsed.value;
        box.titled = m.titled;
        if (m.alias.len > 0) {
            if (!peeraddr.validAlias(m.alias)) {
                self.warnf("peermail: {s}: the alias is not one, ignored", .{path});
            } else if (self.allocator.dupe(u8, m.alias)) |owned| {
                self.allocator.free(box.alias);
                box.alias = owned;
            } else |_| {}
        }
        checkSubject(m.subject) catch return self.warnf("peermail: {s}: the subject is refused, ignored", .{path});
        const owned = self.allocator.dupe(u8, m.subject) catch return;
        self.allocator.free(box.subject);
        box.subject = owned;
    }

    fn loadFile(self: *Store, address: []const u8) void {
        const box = self.ensureBox(address, true) catch return self.warnf("peermail: out of memory loading {s}", .{address});
        self.loadMeta(box);
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
            .message => blk: {
                const sp = self.senderPresence(it.from.address);
                break :blk self.emit.call(conn, .{ .deliver = .{
                    .id = it.id,
                    .from = it.from,
                    .to = it.to,
                    .sent_ms = it.sent_ms,
                    .text = it.text,
                    .reply_to = it.reply_to,
                    .age_ms = now - it.sent_ms,
                    .sender_live = sp.live,
                    .sender_state = sp.state,
                    .sender_subject = sp.subject,
                    .queued = it.queued,
                    .quiet = it.quiet,
                } });
            },
            .event => self.emit.call(conn, .{ .event = .{
                .id = it.id,
                .outcome = it.outcome,
                .reason = it.reason,
                .to = it.to,
                .queued_ms = it.queued_ms,
                // Events never count against the loop cap, but a dormant
                // owner is not woken by one either.
                .quiet = self.dormantConn(conn, now),
            } }),
        };
    }

    /// A local or federated peer's liveness and state, `gone` when unknown.
    fn senderPresence(self: *const Store, address: []const u8) struct { live: bool, state: PeerState, subject: []const u8 = "" } {
        const subject: []const u8 = if (self.boxOf(address)) |b| b.subject else "";
        if (self.livePeer(address)) |p| return .{ .live = true, .state = p.state, .subject = subject };
        for (self.routes.items) |r| for (r.peers) |p| {
            if (std.mem.eql(u8, p.address, address)) return .{ .live = p.live and linkOf(r, p.link) == .up, .state = p.state, .subject = p.subject };
        };
        return .{ .live = false, .state = .gone, .subject = subject };
    }

    /// The live peer on `conn` reads slow mail and is dormant now.
    fn dormantConn(self: *const Store, conn: u32, now: i64) bool {
        const p = self.peerOf(conn) orelse return false;
        return p.slow_mail and peerwake.dormant(self.wake, recipientOf(p), now);
    }

    fn notifySender(self: *Store, msg: *const Item, ev: Event, now: i64) void {
        self.deliverEvent(msg.from.address, ev, now);
    }

    /// Queue `ev` in `owner`'s own mailbox and push it when `owner` is live;
    /// an owner on another host gets it through that host's route; dropped
    /// with a warning when `owner` has no mailbox here.
    fn deliverEvent(self: *Store, owner: []const u8, ev: Event, now: i64) void {
        const addr = peeraddr.Address.parse(owner) catch
            return self.warnf("peer event {s} for {s}, not an address, dropped", .{ ev.id, owner });
        const remote: ?*Route = if (addr.host) |h| (if (self.isSelfHost(h)) null else self.routeTo(h) orelse
            return self.warnf("peer event {s} for {s}: no link to that host, dropped", .{ ev.id, owner })) else null;
        const box = if (remote) |r| r.box else self.boxOf(addr.name) orelse
            return self.warnf("peer event {s} ({s}) for gone sender {s} dropped", .{ ev.id, @tagName(ev.outcome), owner });
        // AIDEV-NOTE: events bypass the mailbox bounds: refusing one would
        // drop the only word the sender gets about its message.
        const s = self.newStored(.{
            .kind = .event,
            .id = ev.id,
            .to = ev.to,
            .owner = if (remote != null) owner else "",
            .sent_ms = now,
            .outcome = ev.outcome,
            .reason = ev.reason,
            .queued_ms = ev.queued_ms,
        }) catch return self.warnf("peer event {s} dropped: out of memory", .{ev.id});
        self.appendItem(box, s) catch {
            freeStored(self.allocator, s);
            return self.warnf("peer event {s} dropped: out of memory", .{ev.id});
        };
        if (remote) |r| {
            if (r.conn != 0) _ = self.relayItem(r, s, now);
        } else if (self.livePeer(box.address)) |p| {
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
            .alias = try a.dupe(u8, item.from.alias),
        };
        it.to = try a.dupe(u8, item.to);
        it.text = try a.dupe(u8, item.text);
        it.reply_to = if (item.reply_to) |r| try a.dupe(u8, r) else null;
        it.owner = try a.dupe(u8, item.owner);
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
        // A turn going on, starting or just ending is activity.
        if (peerwake.working(p.state) or peerwake.working(req.state)) p.active_ms = now;
        p.state = req.state;
        p.slow_mail = req.slow_mail;
        p.armed = req.armed;
        p.client_pid = req.client_pid;
        p.last_seen_ms = now;
        try self.setPresence(p, req);
    }

    /// Replace `p`'s presence facts with `req`'s; a facts document that is
    /// not an object or is too large is dropped, never refused.
    fn setPresence(self: *Store, p: *Peer, req: RegisterReq) error{OutOfMemory}!void {
        const facts: []u8 = if (req.facts) |f| blk: {
            if (f != .object) break :blk try self.allocator.alloc(u8, 0);
            const text = try std.json.Stringify.valueAlloc(self.allocator, f, .{});
            if (text.len > FACTS_MAX) {
                self.allocator.free(text);
                break :blk try self.allocator.alloc(u8, 0);
            }
            break :blk text;
        } else try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(facts);
        const model = try self.allocator.dupe(u8, req.model[0..@min(req.model.len, PRESENCE_TEXT_MAX)]);
        errdefer self.allocator.free(model);
        const note = try self.allocator.dupe(u8, req.last_notification[0..@min(req.last_notification.len, PRESENCE_TEXT_MAX)]);
        self.allocator.free(p.facts_json);
        self.allocator.free(p.model);
        self.allocator.free(p.last_notification);
        p.facts_json = facts;
        p.model = model;
        p.last_notification = note;
        p.context_tokens = peerwake.contextOf(req.facts);
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
        self.allocator.free(p.facts_json);
        self.allocator.free(p.model);
        self.allocator.free(p.last_notification);
        self.allocator.free(p.alias_refused);
        self.allocator.destroy(p);
    }

    fn freeBox(self: *Store, b: *Box) void {
        for (b.items.items) |s| freeStored(self.allocator, s);
        b.items.deinit(self.allocator);
        self.allocator.free(b.address);
        self.allocator.free(b.subject);
        self.allocator.free(b.alias);
        self.allocator.destroy(b);
    }
};

fn freeStored(allocator: std.mem.Allocator, s: *Stored) void {
    s.arena.deinit();
    allocator.destroy(s);
}

fn freeMulti(allocator: std.mem.Allocator, m: *Multi) void {
    m.arena.deinit();
    allocator.destroy(m);
}

fn freeGrant(allocator: std.mem.Allocator, g: Grant) void {
    allocator.free(g.address);
    allocator.free(g.alias);
}

/// `text` cut to at most `max` bytes, never inside a UTF-8 sequence.
pub fn utf8Prefix(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var n = max;
    while (n > 0 and (text[n] & 0xc0) == 0x80) n -= 1;
    return text[0..n];
}

/// What `peerwake` judges of a live peer.
fn recipientOf(p: *const Peer) peerwake.Recipient {
    return .{ .state = p.state, .active_ms = p.active_ms, .context_tokens = p.context_tokens };
}

fn refused(reason: RefuseReason) SendResult {
    return .{ .outcome = .refused, .reason = reason };
}

/// What a far broker (or this one) answered about one relayed item.
const Answer = struct {
    outcome: PeerOutcome,
    reason: ?RefuseReason = null,
    to_state: ?PeerState = null,
    to_polls: bool = false,
    to_no_mcp: bool = false,
};

/// Peers taken from one presence snapshot at most (a bound, not a quota).
const PRESENCE_PEERS_MAX: usize = 1024;

/// The link state an entry reached over `r` shows: the route's own when
/// it is not up, else what the far side reported (`reported`), else up.
fn linkOf(r: *const Route, reported: ?PeerLink) PeerLink {
    return switch (r.link) {
        .up => reported orelse .up,
        .down, .unsupported => r.link,
    };
}

fn full(box: *const Box, text_len: usize) bool {
    return box.messageCount() >= PEER_MAIL_MAX or box.textBytes() + text_len > PEER_MAIL_MAX_BYTES;
}

fn mintId(id_buf: *[ID_LEN]u8) Error![]const u8 {
    return ids.mint(id_buf, ID_PREFIX, ID_CHARS) catch |e| switch (e) {
        error.NoEntropy => return error.NoEntropy,
        error.NoSpaceLeft => unreachable,
    };
}

/// A relayed id: exactly what `mintId` makes.
fn validId(id: []const u8) bool {
    return id.len == ID_LEN and std.mem.startsWith(u8, id, ID_PREFIX);
}

fn cloneJson(a: std.mem.Allocator, v: std.json.Value) error{OutOfMemory}!std.json.Value {
    const text = std.json.Stringify.valueAlloc(a, v, .{}) catch return error.OutOfMemory;
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch error.OutOfMemory;
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
        queued_ms: i64 = 0,
        text: []const u8 = "",
        from: []const u8 = "",
        sender_state: ?PeerState = null,
        to_state: ?PeerState = null,
        req: u32 = 0,
        relay: ?RelayKind = null,
        sender_subject: []const u8 = "",
        from_alias: []const u8 = "",
        quiet: bool = false,
        results: []const RecipientResult = &.{},
        to_polls: bool = false,
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
            .deliver => |d| .{ .conn = conn, .kind = .deliver, .id = a.dupe(u8, d.id) catch "", .to = a.dupe(u8, d.to) catch "", .queued = d.queued, .age_ms = d.age_ms, .text = a.dupe(u8, d.text) catch "", .from = a.dupe(u8, d.from.address) catch "", .sender_state = d.sender_state, .sender_subject = a.dupe(u8, d.sender_subject) catch "", .quiet = d.quiet, .from_alias = a.dupe(u8, d.from.alias) catch "" },
            .event => |e| .{ .conn = conn, .kind = .event, .id = a.dupe(u8, e.id) catch "", .outcome = e.outcome, .reason = e.reason, .to = a.dupe(u8, e.to) catch "", .queued_ms = e.queued_ms, .quiet = e.quiet },
            .reply => |r| .{ .conn = conn, .kind = .reply, .id = a.dupe(u8, r.id) catch "", .outcome = r.outcome, .reason = r.reason, .to_state = r.to_state, .to_polls = r.to_polls, .req = r.req, .results = dupeResults(a, r.results) },
            .relay => |r| .{ .conn = conn, .kind = .relay, .id = a.dupe(u8, r.id) catch "", .relay = r.kind, .outcome = r.outcome, .reason = r.reason },
            .warn => |w| .{ .conn = conn, .kind = .warn, .text = a.dupe(u8, w) catch "" },
            .self_changed => .{ .conn = conn, .kind = .self_changed },
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

/// A current client: it reads slow mail.
fn regSlow(address: []const u8) RegisterReq {
    var r = reg(address, true);
    r.slow_mail = true;
    return r;
}

fn dupeResults(a: std.mem.Allocator, rs: []const RecipientResult) []const RecipientResult {
    const out = a.alloc(RecipientResult, rs.len) catch return &.{};
    for (rs, out) |r, *o| {
        o.* = r;
        o.to = a.dupe(u8, r.to) catch "";
    }
    return out;
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
    const peers = try s.list(arena.allocator(), 0);
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

test "a minted anon address survives its connection's re-registrations; an address never registered is unknown" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .emit = rec.emit() });
    defer s.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var idb: [ID_LEN]u8 = undefined;
    try s.register(1, reg("Zenit", true), 0);
    // 1. No address asked: the broker mints one, never durable.
    try s.register(2, reg("", false), 10);
    const first = (try s.selfInfo(a, 2)).?;
    const minted = try a.dupe(u8, first.address);
    try t.expect(std.mem.startsWith(u8, minted, peeraddr.ANON_PREFIX));
    try t.expect(!first.durable);
    // 2. The same connection registers again (clientInfo, then presence):
    // the address the client was told stays its address.
    try s.register(2, .{ .app = "claude-code", .pid = 42, .state = .working }, 20);
    try s.register(2, .{ .app = "claude-code", .pid = 42, .state = .idle, .model = "Opus" }, 30);
    try t.expectEqualStrings(minted, (try s.selfInfo(a, 2)).?.address);
    try t.expectEqual(@as(usize, 2), (try s.list(a, 0)).len);
    // 3. Mail to it, sent after those re-registrations, is delivered.
    const r = try sendText(&s, 1, minted, "to the anon peer", 40, &idb);
    try t.expectEqual(PeerOutcome.delivered, r.outcome);
    try t.expectEqual(@as(usize, 1), rec.count(2, .deliver));
    // 4. An anon address the broker never handed out is unknown, not gone.
    try t.expectEqual(@as(?RefuseReason, .unknown_address), (try sendText(&s, 1, "anon-never-minted", "x", 50, &idb)).reason);
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
    const emitted = rec.got.items.len;
    s.sweep(1100);
    try t.expectEqual(emitted, rec.got.items.len);
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
    const peers = try s.list(arena.allocator(), 0);
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

test "subject: set by a registration, kept across re-registrations, a new server and a broker restart; cleared; refused" {
    var td = pathz.TempDir.make("peermail-subject") orelse return error.SkipZigTest;
    defer td.remove();
    var rec = Rec.init();
    defer rec.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var idb: [ID_LEN]u8 = undefined;
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        // 1. A registration carrying a subject sets it; the list shows it.
        var r = reg("Arcana", true);
        r.subject = "template links";
        try s.register(1, r, 0);
        try s.register(2, reg("bob", true), 0);
        const gen = s.roster_gen;
        try t.expectEqualStrings("template links", (listed(&s, a, "Arcana") orelse return error.TestUnexpectedResult).subject);
        // 2. A presence re-registration without one (null) keeps it.
        var upd = reg("Arcana", true);
        upd.state = .working;
        try s.register(1, upd, 10);
        try t.expectEqualStrings("template links", s.subjectOf("Arcana"));
        try t.expectEqual(gen, s.roster_gen);
        // 3. A message from Arcana carries it.
        _ = try sendText(&s, 1, "bob", "hi", 20, &idb);
        try t.expectEqualStrings("template links", rec.last().sender_subject);
        // 4. The server stops: the offline address keeps it; the next
        // server registers without one and finds it.
        s.deregister(1, 30);
        try t.expectEqualStrings("template links", (listed(&s, a, "Arcana") orelse return error.TestUnexpectedResult).subject);
        try s.register(3, reg("Arcana", true), 40);
        try t.expectEqualStrings("template links", (listed(&s, a, "Arcana") orelse return error.TestUnexpectedResult).subject);
        // 5. Refused subjects change nothing: too long, a control
        // character (C0 or C1), not UTF-8; an unknown address.
        try t.expectError(error.SubjectTooLong, s.setSubject("Arcana", "x" ** (SUBJECT_MAX + 1)));
        try t.expectError(error.SubjectNotText, s.setSubject("Arcana", "two\nlines"));
        try t.expectError(error.SubjectNotText, s.setSubject("Arcana", "\xc2\x85"));
        try t.expectError(error.SubjectNotText, s.setSubject("Arcana", "\xff"));
        try checkSubject("x" ** SUBJECT_MAX);
        try checkSubject("caf\u{e9} \u{1f600}");
        var bad = reg("Arcana", true);
        bad.subject = "tab\there";
        try s.register(3, bad, 45);
        try t.expectEqualStrings("template links", s.subjectOf("Arcana"));
        try t.expectError(error.UnknownAddress, s.setSubject("nobody", "x"));
        // 6. Set by address (the CLI's --name, a pane's peer), persisted.
        try s.setSubject("bob", "reviewing");
        try t.expect(s.roster_gen != gen);
    }
    // 7. A broker restart loads both from the state directory; an empty
    // subject clears one, file and all.
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        s.load();
        try t.expectEqualStrings("template links", s.subjectOf("Arcana"));
        try t.expectEqualStrings("reviewing", (listed(&s, a, "bob") orelse return error.TestUnexpectedResult).subject);
        try s.register(1, .{ .address = "Arcana", .durable = true, .subject = "" }, 50);
        try t.expectEqualStrings("", s.subjectOf("Arcana"));
    }
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        s.load();
        try t.expectEqualStrings("", s.subjectOf("Arcana"));
        try t.expectEqualStrings("reviewing", s.subjectOf("bob"));
    }
    // 8. A non-durable anon peer has one for its lifetime only.
    {
        var s = try Store.init(t.allocator, .{ .host = "h", .emit = rec.emit() });
        defer s.deinit();
        try s.register(1, .{ .subject = "scratch" }, 0);
        const anon = try a.dupe(u8, s.addressOf(1).?);
        try t.expectEqualStrings("scratch", s.subjectOf(anon));
        s.deregister(1, 10);
        try t.expectEqualStrings("", s.subjectOf(anon));
        try t.expectError(error.UnknownAddress, s.setSubject(anon, "x"));
    }
}

test "federation: a peer's subject crosses the hub with its presence and its mail" {
    var net: Net = undefined;
    try net.init(null);
    defer net.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = reg("alice", true);
    r.subject = "relay work";
    try net.mem.register(1, r, 0);
    try net.hub.register(1, reg("Zenit", true), 0);
    try net.connect(100);
    try net.pump(100);
    // 1. The hub lists box/alice with her subject.
    try t.expectEqualStrings("relay work", (listed(&net.hub, a, "box/alice") orelse return error.TestUnexpectedResult).subject);
    // 2. Her mail delivered on the hub carries it.
    var idb: [ID_LEN]u8 = undefined;
    _ = try net.mem.send(1, .{ .to = "hub/Zenit", .text = "hi" }, 200, &idb);
    try net.pump(200);
    try t.expectEqualStrings("relay work", (lastOf(&net.hub_rec, 1, .deliver) orelse return error.TestUnexpectedResult).sender_subject);
    // 3. Cleared on her host: the next presence relay clears it on the hub.
    try net.mem.setSubject("alice", "");
    try net.pump(300);
    try t.expectEqualStrings("", (listed(&net.hub, a, "box/alice") orelse return error.TestUnexpectedResult).subject);
}

/// A current server in the pane session whose origin id starts `hex8`.
fn regPane(comptime hex8: []const u8) RegisterReq {
    return regSlow(peeraddr.PANE_PREFIX ++ hex8);
}

test "aliases: the first title is the alias and the default subject; a live holder forces a suffix; the same address keeps it" {
    var td = pathz.TempDir.make("peermail-alias") orelse return error.SkipZigTest;
    defer td.remove();
    var rec = Rec.init();
    defer rec.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var idb: [ID_LEN]u8 = undefined;
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        // 1. A pane peer offered its session's title (by the daemon, no GUI
        // involved): the slug is its alias, the title its subject.
        try s.register(1, regPane("00000001"), 0);
        try t.expectEqualStrings("", s.aliasOf("p-00000001"));
        try s.offerTitle("p-00000001", "Zenit", 0);
        try t.expectEqualStrings("zenit", s.aliasOf("p-00000001"));
        try t.expectEqualStrings("Zenit", s.subjectOf("p-00000001"));
        try t.expectEqualStrings("zenit", (try s.selfInfo(a, 1)).?.alias);
        try t.expectEqualStrings("zenit", (listed(&s, a, "p-00000001") orelse return error.TestUnexpectedResult).alias);
        // 2. A second LIVE session of the same title: zenit-1, then zenit-2.
        try s.register(2, regPane("00000002"), 0);
        try s.offerTitle("p-00000002", "zenit", 0);
        try t.expectEqualStrings("zenit-1", s.aliasOf("p-00000002"));
        try s.register(5, regPane("00000005"), 0);
        try s.offerTitle("p-00000005", "ZENIT!", 0);
        try t.expectEqualStrings("zenit-2", s.aliasOf("p-00000005"));
        // 3. A later title moves neither the alias nor the subject, and a
        // cleared subject stays cleared.
        try s.setSubject("p-00000001", "");
        try s.offerTitle("p-00000001", "Other", 10);
        try t.expectEqualStrings("zenit", s.aliasOf("p-00000001"));
        try t.expectEqualStrings("", s.subjectOf("p-00000001"));
        // 4. Mail by alias (its slug finds it too), stamped with the sender's alias.
        try t.expectEqual(PeerOutcome.delivered, (try sendText(&s, 2, "zenit", "hi", 20, &idb)).outcome);
        try t.expectEqualStrings("p-00000002", rec.last().from);
        try t.expectEqualStrings("zenit-1", rec.last().from_alias);
        try t.expectEqual(PeerOutcome.delivered, (try sendText(&s, 2, "Zenit", "hi", 21, &idb)).outcome);
        try t.expectEqualStrings("p-00000001", rec.last().to);
        try t.expectEqual(@as(?RefuseReason, .self), (try sendText(&s, 2, "zenit-1", "me", 22, &idb)).reason);
        // 5. The same address on a new connection (a reconnect, /mcp) keeps it.
        s.deregister(1, 30);
        try s.register(3, regPane("00000001"), 40);
        try s.offerTitle("p-00000001", "Zenit", 40);
        try t.expectEqualStrings("zenit", s.aliasOf("p-00000001"));
        try t.expectEqualStrings("zenit-1", s.aliasOf("p-00000002"));
        // 6. A title whose slug reads as an address gives no alias.
        try s.register(4, regPane("00000004"), 50);
        try s.offerTitle("p-00000004", "p-dead", 50);
        try t.expectEqualStrings("", s.aliasOf("p-00000004"));
    }
    // 7. A broker restart: the aliases and the titled mark come back.
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        s.load();
        try t.expectEqualStrings("zenit", s.aliasOf("p-00000001"));
        try t.expectEqualStrings("zenit-1", s.aliasOf("p-00000002"));
        try s.register(1, regPane("00000001"), 0);
        try s.offerTitle("p-00000001", "New title", 0);
        try t.expectEqualStrings("", s.subjectOf("p-00000001"));
        try t.expectEqualStrings("zenit", s.aliasOf("p-00000001"));
    }
}

test "aliases: an explicit request takes a gone holder's alias and is refused a live one's; a requested one is suffixed" {
    var rec = Rec.init();
    defer rec.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = try Store.init(t.allocator, .{ .host = "h", .emit = rec.emit() });
    defer s.deinit();
    try s.register(1, regPane("00000001"), 0);
    try s.offerTitle("p-00000001", "zenit", 0);
    // 1. Explicit, live-held: refused, naming the holder.
    var ask = regPane("00000002");
    ask.alias = "zenit";
    ask.alias_explicit = true;
    try s.register(2, ask, 0);
    const me = (try s.selfInfo(a, 2)).?;
    try t.expectEqualStrings("", me.alias);
    try t.expectEqualStrings("p-00000001", me.alias_refused);
    // 2. Requested (a --name): the next suffix.
    ask.alias_explicit = false;
    try s.register(2, ask, 1);
    try t.expectEqualStrings("zenit-1", s.aliasOf("p-00000002"));
    try t.expectEqualStrings("", (try s.selfInfo(a, 2)).?.alias_refused);
    // 3. The holder leaves: an explicit request resumes it and the peer is
    // told its own view again (`self_changed`).
    s.deregister(1, 2);
    ask.alias_explicit = true;
    const before = rec.count(2, .self_changed);
    try s.register(2, ask, 3);
    try t.expectEqualStrings("zenit", s.aliasOf("p-00000002"));
    try t.expect(rec.count(2, .self_changed) > before);
    try t.expect(!s.knows("p-00000001"));
}

test "aliases: a new session resumes a gone holder's alias with its mail and subject; its old address follows the alias" {
    var td = pathz.TempDir.make("peermail-resume") orelse return error.SkipZigTest;
    defer td.remove();
    var rec = Rec.init();
    defer rec.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var idb: [ID_LEN]u8 = undefined;
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        try s.register(1, regPane("00000001"), 0);
        try s.offerTitle("p-00000001", "Zenit", 0);
        try s.setSubject("p-00000001", "template links");
        try s.register(9, regPane("00000009"), 0);
        // 1. The session ends (a reboot): mail to its alias waits.
        s.deregister(1, 10);
        for ([_][]const u8{ "one", "two" }, 0..) |text, k| {
            const r = try sendText(&s, 9, "zenit", text, @intCast(20 + k), &idb);
            try t.expectEqual(PeerOutcome.queued, r.outcome);
        }
    }
    // 2. After a broker restart a NEW session titled Zenit resumes zenit
    // (not zenit-1): the mail and the subject move to its address.
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        s.load();
        try s.register(9, regPane("00000009"), 100);
        try s.register(2, regPane("00000002"), 100);
        try s.offerTitle("p-00000002", "Zenit", 100);
        try t.expectEqualStrings("zenit", s.aliasOf("p-00000002"));
        try t.expectEqualStrings("template links", s.subjectOf("p-00000002"));
        try t.expectEqual(@as(usize, 2), rec.count(2, .deliver));
        try t.expectEqualStrings("two", rec.last().text);
        try t.expect(rec.last().queued);
        try t.expect(!s.knows("p-00000001"));
        try t.expect(listed(&s, a, "p-00000001") == null);
        // 3. Mail still sent to the old address follows the alias.
        try t.expectEqual(PeerOutcome.delivered, (try sendText(&s, 9, "p-00000001", "late", 110, &idb)).outcome);
        try t.expectEqualStrings("p-00000002", rec.last().to);
        try t.expectEqual(@as(usize, 2), s.ack(2, &.{ (try a.dupe(u8, rec.got.items[rec.got.items.len - 2].id)), try a.dupe(u8, rec.last().id) }));
    }
    // 4. The old address's files are gone; the new one keeps what moved.
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        s.load();
        try t.expect(!s.knows("p-00000001"));
        try t.expectEqualStrings("zenit", s.aliasOf("p-00000002"));
        try t.expectEqual(@as(u32, 1), (listed(&s, a, "p-00000002") orelse return error.TestUnexpectedResult).pending);
    }
}

test "aliases: migration gives a named mailbox from before aliases its slug, which a session of that title resumes" {
    var td = pathz.TempDir.make("peermail-migrate") orelse return error.SkipZigTest;
    defer td.remove();
    var rec = Rec.init();
    defer rec.deinit();
    var pbuf: [4096]u8 = undefined;
    // An older broker's files: "Qq" with 1 pending and a subject, and "qq".
    const line = "{\"kind\":\"message\",\"id\":\"m-00000001\",\"from\":{\"address\":\"alice\"},\"to\":\"Qq\",\"sent_ms\":5,\"text\":\"for qq\",\"queued\":true}\n";
    try pathz.makeDirs(td.path(), 0o700);
    try atomicwrite.writeFileExact(try std.fmt.bufPrint(&pbuf, "{s}/Qq.jsonl", .{td.path()}), line, 0o600);
    try atomicwrite.writeFileExact(try std.fmt.bufPrint(&pbuf, "{s}/Qq.meta.json", .{td.path()}), "{\"subject\":\"Folio\"}", 0o600);
    try atomicwrite.writeFileExact(try std.fmt.bufPrint(&pbuf, "{s}/qq.jsonl", .{td.path()}), "", 0o600);
    {
        var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
        defer s.deinit();
        s.load();
        // 1. Each takes its slug, the later in address order a suffix: nothing merged.
        try t.expectEqualStrings("qq", s.aliasOf("Qq"));
        try t.expectEqualStrings("qq-1", s.aliasOf("qq"));
        try t.expectEqualStrings("Folio", s.subjectOf("Qq"));
    }
    var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "h", .emit = rec.emit() });
    defer s.deinit();
    s.load();
    // 2. One-way: the restart reads the aliases back.
    try t.expectEqualStrings("qq", s.aliasOf("Qq"));
    try t.expectEqualStrings("qq-1", s.aliasOf("qq"));
    // 3. A session titled "Qq" resumes qq and gets the mail and the subject.
    try s.register(1, regPane("00000001"), 100);
    try s.offerTitle("p-00000001", "Qq", 100);
    try t.expectEqualStrings("qq", s.aliasOf("p-00000001"));
    try t.expectEqualStrings("Folio", s.subjectOf("p-00000001"));
    try t.expectEqualStrings("for qq", rec.last().text);
    try t.expect(!s.knows("Qq"));
    // 4. An older server registering its name gets its slug the same way.
    try s.register(2, reg("Artefacts", true), 110);
    try t.expectEqualStrings("artefacts", s.aliasOf("Artefacts"));
}

test "aliases: the hub keeps an alias unique across hosts, and a session on another host resumes a gone one with its mail" {
    var net: Net = undefined;
    try net.init(null);
    defer net.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var idb: [ID_LEN]u8 = undefined;
    // 1. Unlinked, each host gives its own "zenit" session zenit (provisional).
    try net.hub.register(1, regPane("000000a1"), 0);
    try net.hub.offerTitle("p-000000a1", "zenit", 0);
    try net.mem.register(1, regPane("000000b1"), 0);
    try net.mem.offerTitle("p-000000b1", "zenit", 0);
    try t.expectEqualStrings("zenit", net.mem.aliasOf("p-000000b1"));
    // 2. Link-up: the hub keeps the alias it held and suffixes the member's
    // newer claim, which the member takes; both sides list both.
    try net.connect(100);
    try net.pump(100);
    try net.pump(110);
    try t.expectEqualStrings("zenit", net.hub.aliasOf("p-000000a1"));
    try t.expectEqualStrings("zenit-1", net.mem.aliasOf("p-000000b1"));
    try t.expectEqualStrings("zenit-1", (listed(&net.hub, a, "box/p-000000b1") orelse return error.TestUnexpectedResult).alias);
    try t.expectEqualStrings("zenit", (listed(&net.mem, a, "hub/p-000000a1") orelse return error.TestUnexpectedResult).alias);
    try t.expect(net.mem_rec.count(1, .self_changed) > 0);
    // 3. An alias needs no host: the member reaches the hub's zenit by it.
    _ = try net.mem.send(1, .{ .to = "zenit", .text = "hi hub" }, 200, &idb);
    try net.pump(200);
    const d = lastOf(&net.hub_rec, 1, .deliver) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("hi hub", d.text);
    try t.expectEqualStrings("box/p-000000b1", d.from);
    try t.expectEqualStrings("zenit-1", d.from_alias);
    // 4. A new member session of the same title, linked: zenit-2.
    try net.mem.register(2, regPane("000000b2"), 300);
    try net.mem.offerTitle("p-000000b2", "zenit", 300);
    try t.expectEqualStrings("zenit-2", net.mem.aliasOf("p-000000b2"));
    try net.pump(300);
    try t.expectEqualStrings("zenit-2", net.mem.aliasOf("p-000000b2"));
    // 5. The hub's zenit ends; mail to zenit waits for it there.
    try net.hub.register(2, regPane("000000a2"), 400);
    net.hub.deregister(1, 400);
    try net.pump(400);
    try t.expectEqual(PeerOutcome.queued, (try net.hub.send(2, .{ .to = "zenit", .text = "waiting" }, 410, &idb)).outcome);
    // 6. A new member session titled zenit resumes it across hosts: the
    // hub forwards the waiting mail to it and forgets the old address.
    try net.mem.register(3, regPane("000000b3"), 500);
    try net.mem.offerTitle("p-000000b3", "zenit", 500);
    try t.expectEqualStrings("zenit", net.mem.aliasOf("p-000000b3"));
    try net.pump(500);
    try net.pump(510);
    const fwd = lastOf(&net.mem_rec, 3, .deliver) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("waiting", fwd.text);
    try t.expect(!net.hub.knows("p-000000a1"));
    try t.expectEqualStrings("zenit", (listed(&net.hub, a, "box/p-000000b3") orelse return error.TestUnexpectedResult).alias);
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

test "presence: a re-registration's state, facts, model and notification reach peer_list and the sender's deliveries" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .host = "h", .emit = rec.emit() });
    defer s.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 1. Registered without presence: unknown, no facts.
    try s.register(1, .{ .address = "alice", .durable = true, .app = "claude-code" }, 1000);
    try s.register(2, reg("bob", true), 1000);
    var list = try s.list(a, 0);
    try t.expectEqual(PeerState.unknown, list[0].state);
    try t.expect(list[0].facts == null);
    // 2. A presence update arrives as a re-registration with the same
    // address: state, facts, model, notification and last_seen change.
    const facts = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_percent\":42,\"cost_usd\":1.5}", .{});
    try s.register(1, .{ .address = "alice", .durable = true, .app = "claude-code", .state = .working, .facts = facts, .model = "Opus", .last_notification = "permission_prompt" }, 2000);
    list = try s.list(a, 0);
    try t.expectEqual(PeerState.working, list[0].state);
    try t.expectEqual(@as(i64, 2000), list[0].last_seen_ms);
    try t.expectEqualStrings("Opus", list[0].model);
    try t.expectEqualStrings("permission_prompt", list[0].last_notification);
    try t.expectEqual(@as(i64, 42), list[0].facts.?.object.get("context_used_percent").?.integer);
    // 3. The list survives the wire (the broker stringifies, a client parses).
    const wire_text = try std.json.Stringify.valueAlloc(a, ListReply{ .req = 3, .peers = list }, .{});
    const back = try std.json.parseFromSliceLeaky(ListReply, a, wire_text, .{ .ignore_unknown_fields = true });
    try t.expectEqual(PeerState.working, back.peers[0].state);
    try t.expectEqual(@as(f64, 1.5), back.peers[0].facts.?.object.get("cost_usd").?.float);
    // 4. A message alice sends carries her state; once she is gone, a
    // queued one is delivered with `gone`.
    var idb: [ID_LEN]u8 = undefined;
    _ = try sendText(&s, 1, "bob", "hi", 2100, &idb);
    try t.expectEqual(@as(?PeerState, .working), rec.last().sender_state);
    s.deregister(2, 2200);
    _ = try sendText(&s, 1, "bob", "later", 2300, &idb);
    s.deregister(1, 2400);
    try s.register(3, reg("bob", true), 2500);
    s.flush(3, 2500);
    try t.expectEqual(@as(?PeerState, .gone), rec.last().sender_state);
    // 5. A facts document that is not an object is dropped, not refused.
    try s.register(4, .{ .address = "carol", .facts = .{ .integer = 7 } }, 3000);
    for (try s.list(a, 0)) |p| if (std.mem.eql(u8, p.address, "carol")) try t.expect(p.facts == null);
}

test "wake rules: quiet, a dormant recipient and the loop cap become slow mail; older clients read older words" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .host = "h", .emit = rec.emit() });
    defer s.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const big = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_tokens\":300000}", .{});
    const small = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_tokens\":299999}", .{});
    const MIN: i64 = 60_000;
    var alice = regSlow("alice");
    try s.register(1, alice, 0);
    var bob = regSlow("bob");
    try s.register(2, bob, 0);
    var idb: [ID_LEN]u8 = undefined;
    // 1. quiet: slow mail without a reason, the delivery marked quiet.
    const q = try s.send(1, .{ .to = "bob", .text = "fyi", .quiet = true }, 1000, &idb);
    try t.expectEqual(PeerOutcome.queued_slow, q.outcome);
    try t.expectEqual(@as(?RefuseReason, null), q.reason);
    try t.expect(rec.last().quiet);
    // 2. bob's turn ends at 2000 with 300k of context: 61 minutes later he
    // is dormant, 59 minutes later he is not.
    bob.state = .working;
    try s.register(2, bob, 1500);
    bob.state = .idle;
    bob.facts = big;
    try s.register(2, bob, 2000);
    const d = try sendText(&s, 1, "bob", "wake?", 2000 + 61 * MIN, &idb);
    try t.expectEqual(PeerOutcome.queued_slow, d.outcome);
    try t.expectEqual(@as(?RefuseReason, .dormant), d.reason);
    try t.expect(rec.last().quiet);
    try t.expectEqual(PeerOutcome.delivered, (try sendText(&s, 1, "bob", "x", 2000 + 59 * MIN, &idb)).outcome);
    try t.expect(!rec.last().quiet);
    // Under 300k he is always woken; working, never dormant.
    bob.facts = small;
    try s.register(2, bob, 2000 + 61 * MIN);
    try t.expectEqual(PeerOutcome.delivered, (try sendText(&s, 1, "bob", "x", 2000 + 61 * MIN, &idb)).outcome);
    bob.facts = big;
    bob.state = .working;
    try s.register(2, bob, 2000 + 120 * MIN);
    try t.expectEqual(PeerOutcome.delivered, (try sendText(&s, 1, "bob", "x", 2000 + 300 * MIN, &idb)).outcome);
    // 3. What became of a message is not a wake for a dormant sender either.
    try s.register(5, .{ .app = "x", .slow_mail = true }, 0);
    const anon = try a.dupe(u8, s.addressOf(5).?);
    _ = try sendText(&s, 1, anon, "bye", 3 * 60 * MIN, &idb);
    alice.facts = big;
    try s.register(1, alice, 3 * 60 * MIN);
    // Sending is activity: an hour after it she is dormant.
    s.deregister(5, 4 * 60 * MIN + 1);
    const ev = lastOf(&rec, 1, .event) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(?RefuseReason, .not_durable_gone), ev.reason);
    try t.expect(ev.quiet);
    // 4. The loop cap: carol wakes dave six times in ten minutes, the
    // seventh is slow mail.
    try s.register(3, regSlow("carol"), 0);
    try s.register(4, regSlow("dave"), 0);
    const base: i64 = 1_000_000_000;
    for (0..peerwake.LOOP_WAKES_MAX) |i| try t.expectEqual(PeerOutcome.delivered, (try sendText(&s, 3, "dave", "ping", base + @as(i64, @intCast(i)) * 1000, &idb)).outcome);
    const lim = try sendText(&s, 3, "dave", "ping", base + 7000, &idb);
    try t.expectEqual(PeerOutcome.queued_slow, lim.outcome);
    try t.expectEqual(@as(?RefuseReason, .loop_limited), lim.reason);
    // 5. A client that predates slow mail reads delivered, never a word it
    // cannot parse; a current one reads the real answer.
    try s.register(6, reg("old", true), 0);
    const word: SendReply = .{ .outcome = .queued_slow, .reason = .dormant, .results = &.{.{ .to = "x", .outcome = .queued_slow }} };
    const old = s.replyFor(6, word);
    try t.expectEqual(PeerOutcome.delivered, old.outcome);
    try t.expectEqual(@as(?RefuseReason, null), old.reason);
    try t.expectEqual(@as(usize, 0), old.results.len);
    try t.expectEqual(PeerOutcome.queued_slow, s.replyFor(3, word).outcome);
    // 6. A recipient whose server predates slow mail is woken, quiet or not.
    try s.register(7, reg("legacy", true), 0);
    try t.expectEqual(PeerOutcome.delivered, (try s.send(3, .{ .to = "legacy", .text = "q", .quiet = true }, base, &idb)).outcome);
    try t.expect(!rec.last().quiet);
    // 7. Quiet mail for an away durable address stays quiet when it returns.
    s.deregister(4, base + 8000);
    try t.expectEqual(PeerOutcome.queued, (try s.send(3, .{ .to = "dave", .text = "later", .quiet = true }, base + 9000, &idb)).outcome);
    try s.register(8, regSlow("dave"), base + 10_000);
    s.flush(8, base + 10_000);
    try t.expect((lastOf(&rec, 8, .deliver) orelse return error.TestUnexpectedResult).quiet);
}

test "to_list: one id, one outcome per recipient in list order; duplicates collapse, self is refused, the cap holds" {
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .host = "h", .emit = rec.emit() });
    defer s.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try s.register(1, regSlow("alice"), 0);
    try s.register(2, regSlow("bob"), 0);
    try s.register(3, regSlow("carol"), 0);
    s.deregister(3, 0);
    var idb: [ID_LEN]u8 = undefined;
    // 1. A live, an away, a duplicate, oneself and an unknown address.
    const m = try s.sendMany(a, 1, .{ .req = 4, .to_list = &.{ "bob", "carol", "bob", "alice", "nobody" }, .text = "all hands" }, 1000, &idb);
    try t.expect(!m.deferred);
    try t.expectEqual(@as(usize, 4), m.results.len);
    try t.expectEqualStrings("bob", m.results[0].to);
    try t.expectEqual(PeerOutcome.delivered, m.results[0].outcome);
    try t.expectEqual(PeerOutcome.queued, m.results[1].outcome);
    try t.expectEqual(@as(?RefuseReason, .self), m.results[2].reason);
    try t.expectEqual(@as(?RefuseReason, .unknown_address), m.results[3].reason);
    const id = try a.dupe(u8, m.id);
    // bob got it once, carol gets it on her return, both under the one id.
    try t.expectEqual(@as(usize, 1), rec.count(2, .deliver));
    try t.expectEqualStrings(id, (lastOf(&rec, 2, .deliver) orelse return error.TestUnexpectedResult).id);
    try s.register(5, regSlow("carol"), 2000);
    s.flush(5, 2000);
    try t.expectEqualStrings(id, (lastOf(&rec, 5, .deliver) orelse return error.TestUnexpectedResult).id);
    // 2. quiet holds for every recipient; a text too large refuses each.
    const q = try s.sendMany(a, 1, .{ .to_list = &.{ "bob", "carol" }, .text = "fyi", .quiet = true }, 3000, &idb);
    for (q.results) |r| try t.expectEqual(PeerOutcome.queued_slow, r.outcome);
    const huge = try a.alloc(u8, PEER_TEXT_MAX + 1);
    @memset(huge, 'x');
    const big = try s.sendMany(a, 1, .{ .to_list = &.{ "bob", "carol" }, .text = huge }, 3000, &idb);
    for (big.results) |r| try t.expectEqual(@as(?RefuseReason, .too_large), r.reason);
    // 3. Past the cap of distinct addresses, the whole send is refused;
    // duplicates do not count.
    const over = try a.alloc([]const u8, PEER_TO_MAX + 1);
    for (over, 0..) |*o, i| o.* = try std.fmt.allocPrint(a, "p{d}", .{i});
    try t.expectError(error.TooManyRecipients, s.sendMany(a, 1, .{ .to_list = over, .text = "x" }, 4000, &idb));
    for (over[PEER_TO_MAX..]) |*o| o.* = "p0";
    try t.expectEqual(PEER_TO_MAX, (try s.sendMany(a, 1, .{ .to_list = over, .text = "x" }, 4000, &idb)).results.len);
}

test "federation: one to_list message to two peers of one far host keeps one id; an older far broker takes only one" {
    for ([_]bool{ true, false }) |slow| {
        var net: Net = undefined;
        try net.init(null);
        defer net.deinit();
        net.slow = slow;
        var arena_state = std.heap.ArenaAllocator.init(t.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        try net.hub.register(1, regSlow("Zenit"), 0);
        try net.mem.register(1, regSlow("alice"), 0);
        try net.mem.register(2, regSlow("bob"), 0);
        try net.connect(100);
        try net.pump(100);
        var idb: [ID_LEN]u8 = undefined;
        const m = try net.hub.sendMany(a, 1, .{ .req = 9, .to_list = &.{ "box/alice", "box/bob" }, .text = "both" }, 200, &idb);
        try t.expect(m.deferred);
        const id = try a.dupe(u8, m.id);
        try net.pump(200);
        const rep = lastOf(&net.hub_rec, 1, .reply) orelse return error.TestUnexpectedResult;
        try t.expectEqual(@as(u32, 9), rep.req);
        try t.expectEqualStrings(id, rep.id);
        try t.expectEqual(@as(usize, 2), rep.results.len);
        try t.expectEqual(PeerOutcome.delivered, rep.results[0].outcome);
        try t.expectEqualStrings(id, (lastOf(&net.mem_rec, 1, .deliver) orelse return error.TestUnexpectedResult).id);
        if (slow) {
            // Two items under one id, each stored and answered on its own.
            try t.expectEqual(PeerOutcome.delivered, rep.results[1].outcome);
            try t.expectEqualStrings(id, (lastOf(&net.mem_rec, 2, .deliver) orelse return error.TestUnexpectedResult).id);
            try t.expectEqual(@as(usize, 0), net.hub.routeNamed("box").?.box.items.items.len);
        } else {
            // A far broker keying by id alone would take bob's as alice's again.
            try t.expectEqual(@as(?RefuseReason, .federation_unavailable), rep.results[1].reason);
            try t.expectEqual(@as(usize, 0), net.mem_rec.count(2, .deliver));
        }
    }
}

// ---------------------------------------------------------- federation

/// The hub's connection id for its link to `box`, and the member's id for
/// the hub's connection: arbitrary, distinct from the peers' ids. A
/// call-in swaps them: the dialing side holds the link-range id.
const HUB_LINK: u32 = 0x8000_0001;
const MEMBER_LINK: u32 = 50;

/// A hub and one member wired together through JSON (the relay bodies
/// round-trip as on the wire); `up` false drops what is sent. Every `now`
/// is the hub's clock; the member's runs `skew` ms ahead of it.
const Net = struct {
    hub_rec: Rec,
    mem_rec: Rec,
    hub: Store = undefined,
    mem: Store = undefined,
    up: bool = true,
    hub_link: u32 = HUB_LINK,
    mem_link: u32 = MEMBER_LINK,
    /// Who dialed, as the member sees it: the hub (inbound) unless a call-in.
    mem_direction: PeerLinkDirection = .inbound,
    queue: std.ArrayList(struct { to_hub: bool, json: []u8 }) = .empty,
    skew: i64 = 0,
    /// Each side announces slow mail (both current); false = both predate it.
    slow: bool = true,

    fn init(net: *Net, dir: ?[]const u8) !void {
        return net.initLink(dir, .outbound);
    }

    /// `link` is the hub's `peer_link` for `box`: inbound = box calls in.
    fn initLink(net: *Net, dir: ?[]const u8, link: PeerLinkDirection) !void {
        net.* = .{ .hub_rec = Rec.init(), .mem_rec = Rec.init() };
        const inbound: []const []const u8 = switch (link) {
            .outbound => &.{},
            .inbound => &.{"box"},
        };
        switch (link) {
            .outbound => {},
            .inbound => {
                net.hub_link = MEMBER_LINK;
                net.mem_link = HUB_LINK;
                net.mem_direction = .outbound;
            },
        }
        net.hub = try Store.init(t.allocator, .{ .host = "hub", .ttl_ms = 10_000, .hub = true, .domains = &.{"box"}, .inbound = inbound, .emit = .{ .ctx = net, .func = hubEmit } });
        net.mem = try Store.init(t.allocator, .{ .dir = dir, .host = "boxhost", .ttl_ms = 10_000, .emit = .{ .ctx = net, .func = memEmit } });
    }

    fn deinit(net: *Net) void {
        for (net.queue.items) |f| t.allocator.free(f.json);
        net.queue.deinit(t.allocator);
        net.hub.deinit();
        net.mem.deinit();
        net.hub_rec.deinit();
        net.mem_rec.deinit();
    }

    fn connect(net: *Net, now: i64) !void {
        net.up = true;
        try net.mem.uplinkUp(net.mem_link, .{ .host = "hub", .as = "box", .slow_mail = net.slow }, net.mem_direction, now + net.skew);
        net.hub.linkUp("box", net.hub_link, net.slow, now);
    }

    /// Both ends see the link drop; the next one gets new connection ids.
    fn cut(net: *Net, now: i64) void {
        net.up = false;
        net.hub.connGone(net.hub_link, now);
        net.mem.connGone(net.mem_link, now + net.skew);
        for (net.queue.items) |f| t.allocator.free(f.json);
        net.queue.clearRetainingCapacity();
        net.hub_link += 1;
        net.mem_link += 1;
    }

    fn send(net: *Net, to_hub: bool, r: Relay) bool {
        if (!net.up) return false;
        const json = std.json.Stringify.valueAlloc(t.allocator, r, .{ .emit_null_optional_fields = false }) catch return false;
        net.queue.append(t.allocator, .{ .to_hub = to_hub, .json = json }) catch {
            t.allocator.free(json);
            return false;
        };
        return true;
    }

    fn hubEmit(ctx: *anyopaque, conn: u32, out: Out) bool {
        const net: *Net = @ptrCast(@alignCast(ctx));
        if (out == .relay) return conn == net.hub_link and net.send(false, out.relay);
        return Rec.record(&net.hub_rec, conn, out);
    }

    fn memEmit(ctx: *anyopaque, conn: u32, out: Out) bool {
        const net: *Net = @ptrCast(@alignCast(ctx));
        if (out == .relay) return conn == net.mem_link and net.send(true, out.relay);
        return Rec.record(&net.mem_rec, conn, out);
    }

    /// Deliver everything in flight (and what it causes), both ways.
    fn pump(net: *Net, now: i64) !void {
        net.hub.tick(now);
        net.mem.tick(now + net.skew);
        while (net.queue.items.len > 0) {
            const f = net.queue.orderedRemove(0);
            defer t.allocator.free(f.json);
            const parsed = try std.json.parseFromSlice(Relay, t.allocator, f.json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (f.to_hub) try net.hub.relayIn(net.hub_link, parsed.value, now) else try net.mem.relayIn(net.mem_link, parsed.value, now + net.skew);
            net.hub.tick(now);
            net.mem.tick(now + net.skew);
        }
    }
};

fn listed(s: *Store, arena: std.mem.Allocator, address: []const u8) ?PeerInfo {
    for (s.list(arena, 0) catch return null) |p| if (std.mem.eql(u8, p.address, address)) return p;
    return null;
}

fn lastOf(rec: *const Rec, conn: u32, kind: std.meta.Tag(Out)) ?Rec.Got {
    var i = rec.got.items.len;
    while (i > 0) {
        i -= 1;
        const g = rec.got.items[i];
        if (g.conn == conn and g.kind == kind) return g;
    }
    return null;
}

test "federation: presence and mail cross the hub both ways under host-qualified addresses" {
    try exchangeOver(.outbound);
}

test "federation: a call-in link carries the same exchange; only the direction differs" {
    try exchangeOver(.inbound);
}

/// The hub-and-member exchange over a link the hub dials (`outbound`) or
/// the member calls in on (`inbound`).
fn exchangeOver(link: PeerLinkDirection) !void {
    var net: Net = undefined;
    try net.initLink(null, link);
    defer net.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try net.hub.register(1, reg("Zenit", true), 0);
    try net.mem.register(1, reg("alice", true), 0);
    // 1. Before any link: the member is not federated, the hub lists the
    // domain down with its configured direction.
    try t.expectEqual(PeerFederation.off, net.mem.federation());
    try t.expectEqual(PeerLink.down, (try net.hub.hostList(a))[0].link);
    try t.expectEqual(@as(?PeerLinkDirection, link), (try net.hub.hostList(a))[0].direction);
    // 2. The link comes up: each side lists the other's peer, qualified,
    // with the host it came through.
    try net.connect(100);
    try net.pump(100);
    try t.expectEqual(PeerFederation.member, net.mem.federation());
    try t.expectEqual(@as(?PeerLinkDirection, net.mem_direction), (try net.mem.hostList(a))[0].direction);
    const on_hub = listed(&net.hub, a, "box/alice") orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("box", on_hub.via_host);
    try t.expectEqual(@as(?PeerLink, .up), on_hub.link);
    try t.expectEqualStrings("boxhost", on_hub.host);
    const on_mem = listed(&net.mem, a, "hub/Zenit") orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("hub", on_mem.via_host);
    try t.expect(on_mem.live);
    try t.expect(listed(&net.mem, a, "box/alice") == null);
    // 3. alice -> hub/Zenit: the answer waits for the hub, which delivers it
    // from box/alice and answers `delivered`.
    var idb: [ID_LEN]u8 = undefined;
    const r1 = try net.mem.send(1, .{ .req = 7, .to = "hub/Zenit", .text = "hi from box" }, 200, &idb);
    try t.expect(r1.deferred);
    try net.pump(200);
    const d1 = lastOf(&net.hub_rec, 1, .deliver) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("box/alice", d1.from);
    try t.expectEqualStrings("hi from box", d1.text);
    try t.expectEqual(@as(?PeerState, .idle), d1.sender_state);
    const rep = lastOf(&net.mem_rec, 1, .reply) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 7), rep.req);
    try t.expectEqual(PeerOutcome.delivered, rep.outcome);
    try t.expectEqualStrings(r1.id, rep.id);
    // The member's outbound mailbox is empty once the hub stored it.
    try t.expectEqual(@as(usize, 0), net.mem.uplink().?.box.items.items.len);
    // 4. Zenit replies to the address it saw; alice gets it from hub/Zenit.
    const r2 = try net.hub.send(1, .{ .req = 8, .to = "box/alice", .text = "and back", .reply_to = d1.id }, 300, &idb);
    try t.expect(r2.deferred);
    try net.pump(300);
    const d2 = lastOf(&net.mem_rec, 1, .deliver) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("hub/Zenit", d2.from);
    try t.expectEqualStrings("and back", d2.text);
    try t.expectEqual(PeerOutcome.delivered, (lastOf(&net.hub_rec, 1, .reply) orelse return error.TestUnexpectedResult).outcome);
    // 5. The member's own host name in an address is local to it.
    try net.mem.register(2, reg("bob", true), 300);
    try t.expectEqual(PeerOutcome.delivered, (try net.mem.send(1, .{ .to = "box/bob", .text = "local" }, 300, &idb)).outcome);
}

test "federation: presence facts cross the link, and the far broker judges a dormant recipient" {
    var net: Net = undefined;
    try net.init(null);
    defer net.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const MIN: i64 = 60_000;
    try net.hub.register(1, regSlow("Zenit"), 0);
    var bob = regSlow("bob");
    bob.model = "Opus";
    bob.facts = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_tokens\":400000}", .{});
    try net.mem.register(1, bob, 0);
    try net.connect(100);
    try net.pump(100);
    // 1. The hub lists box/bob with the state, model and facts his own
    // broker holds, not as unknown.
    const on_hub = listed(&net.hub, a, "box/bob") orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerState.idle, on_hub.state);
    try t.expectEqualStrings("Opus", on_hub.model);
    try t.expectEqual(@as(i64, 400000), on_hub.facts.?.object.get("context_used_tokens").?.integer);
    // 2. Silent an hour with 400k of context: mail from the hub reaches him
    // as slow mail, judged where his presence lives.
    var idb: [ID_LEN]u8 = undefined;
    const r = try net.hub.send(1, .{ .req = 4, .to = "box/bob", .text = "later is fine" }, 61 * MIN, &idb);
    try t.expect(r.deferred);
    try net.pump(61 * MIN);
    const got = lastOf(&net.mem_rec, 1, .deliver) orelse return error.TestUnexpectedResult;
    try t.expect(got.quiet);
    const rep = lastOf(&net.hub_rec, 1, .reply) orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerOutcome.queued_slow, rep.outcome);
    try t.expectEqual(@as(?RefuseReason, .dormant), rep.reason);
}

test "federation: a dropped link queues host_unreachable and delivers once when it is back, across skewed clocks" {
    var net: Net = undefined;
    try net.init(null);
    defer net.deinit();
    // The member's clock is three hours ahead of the hub's: every time
    // below is right on the clock of the broker that reports it.
    const S: i64 = 3 * 3600_000;
    net.skew = S;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try net.hub.register(1, reg("Zenit", true), 50);
    try net.mem.register(1, reg("alice", true), S + 50);
    try net.connect(100);
    try net.pump(100);
    // 1. Relayed presence: each side reads the other's last_seen on its own clock.
    try t.expectEqual(@as(i64, 50), (listed(&net.hub, a, "box/alice") orelse return error.TestUnexpectedResult).last_seen_ms);
    try t.expectEqual(S + 50, (listed(&net.mem, a, "hub/Zenit") orelse return error.TestUnexpectedResult).last_seen_ms);
    // 2. The link drops: the remote peer stays listed, link down.
    net.cut(1000);
    try t.expectEqual(@as(?PeerLink, .down), (listed(&net.hub, a, "box/alice") orelse return error.TestUnexpectedResult).link);
    try t.expectEqual(@as(?PeerLink, .down), (listed(&net.mem, a, "hub/Zenit") orelse return error.TestUnexpectedResult).link);
    // 3. A send now is queued with the reason, answered at once.
    var idb: [ID_LEN]u8 = undefined;
    const r = try net.mem.send(1, .{ .to = "hub/Zenit", .text = "while down" }, S + 1100, &idb);
    try t.expectEqual(PeerOutcome.queued, r.outcome);
    try t.expectEqual(@as(?RefuseReason, .host_unreachable), r.reason);
    try t.expect(!r.deferred);
    // 4. Back up: delivered once, with its age on the member's clock; the
    // outbound box empties.
    try net.connect(3000);
    try net.pump(3000);
    try t.expectEqual(@as(usize, 1), net.hub_rec.count(1, .deliver));
    const d = lastOf(&net.hub_rec, 1, .deliver) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(i64, 1900), d.age_ms);
    try t.expectEqual(@as(usize, 0), net.mem.uplink().?.box.items.items.len);
    // 5. A redelivery of the same id (its `stored` answer lost) is
    // recognised: answered again, never delivered twice.
    const again = Relay{ .kind = .mail, .id = d.id, .from = .{ .address = "alice" }, .to = "hub/Zenit", .text = "while down", .age_ms = 2000 };
    try net.hub.relayIn(net.hub_link, again, 3100);
    try net.pump(3100);
    try t.expectEqual(@as(usize, 1), net.hub_rec.count(1, .deliver));
    // 6. Mail queued on the hub for an offline name expires a TTL after it
    // was sent on the hub's clock, and the event's wait crosses back as is.
    // (Zenit acks first, so only Qq's mail can expire.)
    try t.expectEqual(@as(usize, 1), net.hub.ack(1, &.{d.id}));
    try net.hub.register(2, reg("Qq", true), 3100);
    net.hub.deregister(2, 3100);
    _ = try net.mem.send(1, .{ .to = "hub/Qq", .text = "later" }, S + 3150, &idb);
    try net.pump(3150);
    net.hub.sweep(3150 + 10_000 - 1);
    try net.pump(3150 + 10_000 - 1);
    try t.expect(lastOf(&net.mem_rec, 1, .event) == null);
    net.hub.sweep(3150 + 10_000);
    try net.pump(3150 + 10_000);
    const ex = lastOf(&net.mem_rec, 1, .event) orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerOutcome.expired, ex.outcome);
    try t.expectEqualStrings("hub/Qq", ex.to);
    try t.expectEqual(@as(i64, 10_000), ex.queued_ms);
    // 7. A send in flight when the link drops is answered queued.
    const r3 = try net.mem.send(1, .{ .req = 4, .to = "hub/Zenit", .text = "in flight" }, S + 13_200, &idb);
    try t.expect(r3.deferred);
    net.cut(13_300);
    const rep = lastOf(&net.mem_rec, 1, .reply) orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerOutcome.queued, rep.outcome);
    try t.expectEqual(@as(?RefuseReason, .host_unreachable), rep.reason);
    try t.expectEqual(@as(usize, 1), net.mem.uplink().?.box.items.items.len);
}

test "federation: far refusals and expiry come back to the sender" {
    var net: Net = undefined;
    try net.init(null);
    defer net.deinit();
    try net.hub.register(1, reg("Zenit", true), 0);
    try net.mem.register(1, reg("alice", true), 0);
    try net.mem.register(2, reg("mike", true), 0);
    net.mem.deregister(2, 10);
    try net.connect(0);
    try net.pump(0);
    var idb: [ID_LEN]u8 = undefined;
    // 1. An unknown name on the far host: the far broker's refusal is the reply.
    _ = try net.hub.send(1, .{ .req = 1, .to = "box/Nobody", .text = "?" }, 100, &idb);
    try net.pump(100);
    const rep = lastOf(&net.hub_rec, 1, .reply) orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerOutcome.refused, rep.outcome);
    try t.expectEqual(@as(?RefuseReason, .unknown_address), rep.reason);
    // 2. Sent while the link is down, refused later: the sender gets an event.
    net.cut(200);
    _ = try net.hub.send(1, .{ .to = "box/Nobody", .text = "?" }, 300, &idb);
    try net.connect(400);
    try net.pump(400);
    const ev = lastOf(&net.hub_rec, 1, .event) orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerOutcome.refused, ev.outcome);
    try t.expectEqual(@as(?RefuseReason, .unknown_address), ev.reason);
    try t.expectEqualStrings("box/Nobody", ev.to);
    // 3. Queued for an offline durable name over there, it expires there;
    // the event crosses back, naming the recipient as the sender knows it.
    _ = try net.hub.send(1, .{ .req = 2, .to = "box/mike", .text = "later" }, 500, &idb);
    try net.pump(500);
    const q = lastOf(&net.hub_rec, 1, .reply) orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerOutcome.queued, q.outcome);
    try t.expectEqual(@as(?PeerState, .gone), q.to_state);
    net.mem.sweep(500 + 10_000);
    try net.pump(500 + 10_000);
    const ex = lastOf(&net.hub_rec, 1, .event) orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerOutcome.expired, ex.outcome);
    try t.expectEqualStrings("box/mike", ex.to);
    // 4. The hub's outbound mail expires too while the link is down.
    net.cut(20_000);
    _ = try net.hub.send(1, .{ .to = "box/alice", .text = "never" }, 20_000, &idb);
    net.hub.sweep(30_000);
    const ex2 = lastOf(&net.hub_rec, 1, .event) orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerOutcome.expired, ex2.outcome);
    try t.expectEqualStrings("box/alice", ex2.to);
}

test "federation: trust gate, unknown and unsupported hosts" {
    var net: Net = undefined;
    try net.init(null);
    defer net.deinit();
    try net.hub.register(1, reg("Zenit", true), 0);
    var idb: [ID_LEN]u8 = undefined;
    // 1. A relay on a connection that never said hello is refused, on
    // either side; a hub never becomes a member.
    const mail = Relay{ .kind = .mail, .id = "m-abcdefgh", .from = .{ .address = "x" }, .to = "Zenit", .text = "forged" };
    try t.expectError(error.NotLinked, net.mem.relayIn(77, mail, 0));
    try t.expectError(error.NotLinked, net.hub.relayIn(77, mail, 0));
    try t.expectError(error.NotLinked, net.hub.uplinkUp(77, .{ .host = "h", .as = "a" }, .inbound, 0));
    try t.expectEqual(@as(usize, 0), net.hub_rec.count(1, .deliver));
    // 2. A member speaks only for its own peers: a qualified `from` is refused.
    try net.connect(0);
    try net.pump(0);
    try net.hub.relayIn(net.hub_link, .{ .kind = .mail, .id = "m-abcdefgi", .from = .{ .address = "hub/Zenit" }, .to = "hub/Zenit", .text = "forged" }, 10);
    try t.expectEqual(@as(usize, 0), net.hub_rec.count(1, .deliver));
    // 3. An unknown host is refused on the hub; an old daemon's host is
    // listed unsupported and refused `federation_unavailable`.
    try t.expectEqual(@as(?RefuseReason, .unknown_address), (try net.hub.send(1, .{ .to = "nope/x", .text = "?" }, 20, &idb)).reason);
    net.hub.linkUnsupported("box", 30);
    try t.expectEqual(@as(?RefuseReason, .federation_unavailable), (try net.hub.send(1, .{ .to = "box/x", .text = "?" }, 40, &idb)).reason);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(PeerLink.unsupported, (try net.hub.hostList(arena.allocator()))[0].link);
}

test "federation: the outbound mailbox and membership survive a restart" {
    var td = pathz.TempDir.make("peerfed") orelse return error.SkipZigTest;
    defer td.remove();
    {
        var net: Net = undefined;
        try net.init(td.path());
        defer net.deinit();
        try net.mem.register(1, reg("alice", true), 0);
        try net.connect(0);
        net.cut(10);
        var idb: [ID_LEN]u8 = undefined;
        _ = try net.mem.send(1, .{ .to = "hub/Zenit", .text = "kept" }, 20, &idb);
    }
    var rec = Rec.init();
    defer rec.deinit();
    var s = try Store.init(t.allocator, .{ .dir = td.path(), .host = "boxhost", .emit = rec.emit() });
    defer s.deinit();
    s.load();
    try t.expectEqual(PeerFederation.member, s.federation());
    try t.expectEqual(@as(usize, 1), s.uplink().?.box.items.items.len);
    try t.expectEqualStrings("hub/Zenit", s.uplink().?.box.items.items[0].item.to);
    // A peer list never shows the outbound mailbox as a peer.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    for (try s.list(arena.allocator(), 0)) |p| try t.expect(!std.mem.startsWith(u8, p.address, ROUTE_PREFIX));
}

test "a polling recipient: its delivery and its list entry say so, across the hub too; an older server is unknown, never polling" {
    var net: Net = undefined;
    try net.init(null);
    defer net.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var zenit = regSlow("Zenit");
    zenit.armed = false;
    var qq = regSlow("Qq");
    qq.armed = true;
    try net.hub.register(1, zenit, 0);
    try net.hub.register(2, qq, 0);
    try net.hub.register(3, regSlow("Old"), 0);
    // 1. Delivered either way; only the unarmed recipient polls.
    var idb: [ID_LEN]u8 = undefined;
    const to_z = try net.hub.send(2, .{ .to = "Zenit", .text = "x" }, 10, &idb);
    try t.expectEqual(PeerOutcome.delivered, to_z.outcome);
    try t.expect(to_z.to_polls);
    try t.expect(!(try net.hub.send(1, .{ .to = "Qq", .text = "x" }, 10, &idb)).to_polls);
    try t.expect(!(try net.hub.send(1, .{ .to = "Old", .text = "x" }, 10, &idb)).to_polls);
    try t.expect((listed(&net.hub, a, "Zenit") orelse return error.TestUnexpectedResult).polls);
    try t.expect(!(listed(&net.hub, a, "Qq") orelse return error.TestUnexpectedResult).polls);
    try t.expect(!(listed(&net.hub, a, "Old") orelse return error.TestUnexpectedResult).polls);
    // 2. Its server arms (a follower attached): the mark goes, and comes back.
    zenit.armed = true;
    try net.hub.register(1, zenit, 20);
    try t.expect(!(listed(&net.hub, a, "Zenit") orelse return error.TestUnexpectedResult).polls);
    zenit.armed = false;
    try net.hub.register(1, zenit, 30);
    // 3. A to_list answers it per recipient.
    const many = try net.hub.sendMany(a, 2, .{ .to_list = &.{ "Zenit", "Old" }, .text = "both" }, 40, &idb);
    try t.expect(many.results[0].to_polls and !many.results[1].to_polls);
    // 4. Across the hub: the member's sender is told, and lists it so.
    try net.mem.register(1, regSlow("alice"), 50);
    try net.connect(50);
    try net.pump(50);
    try t.expect((listed(&net.mem, a, "hub/Zenit") orelse return error.TestUnexpectedResult).polls);
    try t.expect(!(listed(&net.mem, a, "hub/Qq") orelse return error.TestUnexpectedResult).polls);
    const far = try net.mem.send(1, .{ .req = 9, .to = "hub/Zenit", .text = "from afar" }, 60, &idb);
    try t.expect(far.deferred);
    try net.pump(60);
    const rep = lastOf(&net.mem_rec, 1, .reply) orelse return error.TestUnexpectedResult;
    try t.expectEqual(PeerOutcome.delivered, rep.outcome);
    try t.expect(rep.to_polls);
}

/// The local entry for `address` in a list taken at `now`.
fn listedAt(s: *Store, arena: std.mem.Allocator, address: []const u8, now: i64) ?PeerInfo {
    for (s.list(arena, now) catch return null) |p| if (std.mem.eql(u8, p.address, address)) return p;
    return null;
}

test "a session whose server is gone but whose hooks still report reads no_mcp, for HOOK_FRESH_MS, across the hub too" {
    var net: Net = undefined;
    try net.init(null);
    defer net.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = &net.hub;
    var zenit = regSlow("Zenit");
    zenit.client_pid = 4242;
    try s.register(1, zenit, 0);
    try s.register(2, regSlow("Qq"), 0);
    s.deregister(1, 100);
    // 1. Gone, and nothing reported yet.
    try t.expect(!(listedAt(s, a, "Zenit", 200) orelse return error.TestUnexpectedResult).no_mcp);
    // 2. A process under another client matches nothing; one under its
    // client (the nearest ancestor that started its server) names it.
    try t.expect(s.hookPresence(&.{ 999, 1 }, .working, 300) == null);
    try t.expectEqualStrings("Zenit", s.hookPresence(&.{ 5000, 4242, 1 }, .working, 300) orelse return error.TestUnexpectedResult);
    const p = listedAt(s, a, "Zenit", 400) orelse return error.TestUnexpectedResult;
    try t.expect(p.no_mcp and !p.live);
    try t.expectEqual(PeerState.gone, p.state);
    try t.expectEqual(@as(i64, 300), p.last_seen_ms);
    // 3. A message to it waits, and the sender is told why.
    var idb: [ID_LEN]u8 = undefined;
    const r = try s.send(2, .{ .to = "Zenit", .text = "x" }, 500, &idb);
    try t.expectEqual(PeerOutcome.queued, r.outcome);
    try t.expect(r.to_no_mcp);
    // 4. Across the hub, with its presence.
    try net.mem.register(1, regSlow("alice"), 500);
    try net.connect(500);
    try net.pump(500);
    try t.expect((listed(&net.mem, a, "hub/Zenit") orelse return error.TestUnexpectedResult).no_mcp);
    // 5. Stale past HOOK_FRESH_MS: gone again, and the members hear it.
    const late = 300 + HOOK_FRESH_MS + 1;
    try t.expect(!(listedAt(s, a, "Zenit", late) orelse return error.TestUnexpectedResult).no_mcp);
    try net.pump(late);
    try t.expect(!(listed(&net.mem, a, "hub/Zenit") orelse return error.TestUnexpectedResult).no_mcp);
    try t.expect(!(try s.send(2, .{ .to = "Zenit", .text = "y" }, late, &idb)).to_no_mcp);
    // 6. Its SessionEnd hook ends it at once.
    _ = s.hookPresence(&.{4242}, .working, late + 10);
    _ = s.hookPresence(&.{4242}, .gone, late + 20);
    try t.expect(!(listedAt(s, a, "Zenit", late + 30) orelse return error.TestUnexpectedResult).no_mcp);
    // 7. A server back at the address is simply live; hooks go to it.
    _ = s.hookPresence(&.{4242}, null, late + 40);
    try s.register(3, zenit, late + 50);
    const back = listedAt(s, a, "Zenit", late + 60) orelse return error.TestUnexpectedResult;
    try t.expect(back.live and !back.no_mcp);
    try t.expect(s.hookPresence(&.{4242}, .working, late + 70) == null);
}
