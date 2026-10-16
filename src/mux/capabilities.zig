//! The welcome's boolean capability flags: the one declaring table.
//!
//! A daemon advertises every flag in `Flag`; a client parses the same
//! set out of the welcome and keeps it in a `Set`. Old daemons lack
//! flags they predate, so a client must gate every gated frame on its
//! flag and keep a fallback for its absence -- each flag's doc says
//! what that fallback is. Adding a flag is one line here: the welcome,
//! the parse, the reset and the drift test all derive from the enum.

const std = @import("std");

/// Every welcome flag, in wire order. The tag IS the JSON key.
pub const Flag = enum {
    /// The daemon answers `udp_ticket_req` (connection-ticket
    /// brokering). Never ask an older daemon: its `.err` is
    /// misattributable on a multiplexed connection.
    udp_ticket,
    /// `cross_copy` honors `delete_src` (move) plus `dial_tries` and
    /// stamps dial failures `kind:"unreachable"`. Gates daemon-owned
    /// moves AND direct remote-to-remote coordination: an old daemon
    /// ignoring `delete_src` would silently turn a move into a copy.
    cross_move,
    /// `cross_copy` is idempotent by `client_token` and its terminal
    /// job survives until an explicit `job_ack`, so browser-owned
    /// intents outlive a view handoff.
    durable_copy,
    copy_no_replace,
    /// Cancellation and final installation are one durable election;
    /// canceled no-replace staging is recovered across helper and
    /// daemon restarts.
    durable_copy_v2,
    /// Additive JSON display fields plus guarded display-only
    /// destruction. Old daemons silently ignore unknown JSON members,
    /// so those requests must be gated on this flag.
    display_v2,
    /// `KillReq.origin_id` is enforced before name resolution. An
    /// older daemon would ignore the additive field and kill by name,
    /// so a fenced kill refuses without this flag.
    kill_origin_fence,
    /// The daemon answers `lsp_open`: it can spawn a language server
    /// near the files and bridge its stdio as a byte channel. Absent
    /// = degrade silently, exactly like a host with no server.
    lsp,
    /// Cast-playback sessions (`SpawnReq.cast_path` + `play_control`).
    /// An old daemon would spawn a login shell for the request and
    /// `.err` on the control frame, so both are gated.
    cast_playback,
    /// The daemon serves `web_op` (history, bookmarks, per-site
    /// settings stored on ITS host). Absent = no persistence.
    web_store,
    /// The daemon serves the `web_op` PROFILE ops: the headless
    /// browser-profile store's flock and id allocation live in the
    /// broker, so N MCP clients of one instance share one store.
    /// Absent = the client takes the store flock itself, i.e. the old
    /// single-owner behavior.
    web_profiles,
    /// The daemon serves `web_op engine_open`: the broker spawns and
    /// owns the instance's browser ENGINE (linger lifecycle) and
    /// answers with its socket path. Absent = the client spawns the
    /// helper itself.
    web_engine,
    /// The daemon answers `stream_open` (arbitrary-host TCP egress
    /// with remote DNS). Absent = never send it; an old daemon's
    /// generic `.err` cannot be matched to one of several pending
    /// CONNECTs.
    stream_open,
    /// The daemon answers `web_helper_open`: it spawns a browser
    /// helper on ITS host and bridges its socket as a byte channel.
    /// Absent = remote browsing on that host gets a described "daemon
    /// too old" error instead of a hang.
    web_helper,
    /// The daemon answers `web_helper_connect`: it bridges a helper
    /// already serving beside its socket, which is how a remote
    /// assistant's browser is watched.
    web_helper_connect,
    /// The daemon can put immutable session identity before the
    /// initial GUI snapshot when a panel-capable attach asks for it.
    attach_identity,
    /// The daemon answers `quit_idle` atomically: it exits only if it
    /// holds no session, worker or running job at the moment the
    /// frame is handled, else replies `ok:false`. Absent = the client
    /// falls back to probing `.list` + `job_list` and then sending the
    /// unconditional `.shutdown` (racy: a session started in between
    /// dies).
    quit_idle,
    /// `quit_idle` honors `{"handover":true}`: a broker whose session
    /// workers can all be adopted retires WITH its sessions, leaving the
    /// workers running for the next broker (daemon_adopt.zig). Absent =
    /// a busy daemon is never replaced (the field would be ignored and
    /// the request refused, so sending it is harmless but pointless).
    worker_handover,
    /// The daemon brain asks a viewer for the HOST clipboard when a
    /// forwarded app pastes (`paste_request` pipe unit, answered with
    /// clip_data / primary_data) and honors the viewer's `viewer_caps`.
    /// A viewer then answers pastes only on request. Absent = the old
    /// daemon never asks; the viewer keeps answering what its replica
    /// resolves itself.
    app_paste_request,
    /// `web_helper_connect` honors `instance`: the per-user daemon an SSH
    /// `--proxy` reaches bridges the helper of the NAMED MCP instance
    /// (`sketerm mcp --name <instance>`) living in `mcp-<instance>/`
    /// beside it. Absent = the daemon ignores the field and would look
    /// beside its OWN socket, so a client refuses instead of sending it.
    web_helper_instance,
    /// The `.list` reply carries `assistants`: THIS host's live MCP
    /// servers from its registry (`mcp_registry.Report`), each with its
    /// instance key and published agents, so a viewer can derive routes
    /// to watch them (`sshroute.watchSpec`). Absent = an older daemon,
    /// whose list says nothing about assistants: none are known there.
    assistants,
    /// Attach honors `view_only`: the session's process drops that
    /// client's input and resize and echoes `view_only` in
    /// `control_state`. The ECHO is the proof (an adopted older worker
    /// behind a new broker lacks it). Absent = the client withholds
    /// input itself and tells its user the daemon does not enforce it.
    view_only,
    /// The broker remembers why sessions ended (`tombstone_get`, answered
    /// by `tombstone_reply`: expired, exited with status or signal,
    /// closed). Absent = never ask; a gone session's reason is unknown.
    tombstones,
    /// The attached session's foreground process group can be queried
    /// and signalled (`fg_signal`, answered by `fg_signal_reply`). Absent
    /// = never ask; only the terminal's own interrupt characters (^C,
    /// ^\) reach a running command. A worker adopted from an older
    /// build may still leave it unanswered, so a client bounds the wait.
    fg_signal,
    /// The broker serves peer messaging (`peer_register`, `peer_list_req`,
    /// `peer_send`, `peer_ack`; it pushes `peer_deliver`/`peer_event`).
    /// Absent = never send them; peers on that daemon are unavailable and
    /// the MCP peer tools say so.
    peers,
    /// The broker takes part in peer federation: it accepts a hub's
    /// `peer_hub_hello` and then `peer_hub_relay` on that connection, and
    /// answers with `peer_member_relay`. Absent = a hub lists that host
    /// `unsupported` and refuses sends to it `federation_unavailable`.
    peer_federation,
    /// The broker keeps a user-set subject per peer: `peer_register`'s
    /// `subject`, `peer_subject` (answered by `peer_subject_reply`, or on
    /// an attached session by the `session_meta` `peer` push), and
    /// `subject` in `peer_list`/`peer_deliver`. Absent = never send them.
    peer_subject,
    /// The broker takes call-in members: a member's link says
    /// `peer_member_hello` and gets `peer_hub_hello` back on the same
    /// connection. Absent = a call-in member lists its hub `unsupported`.
    peer_callin,
    /// The broker judges whether a peer message may wake its recipient
    /// (`peer_send` `quiet`, dormancy, the loop cap; `peerwake.zig`) and
    /// hands the rest as slow mail (`peer_deliver`/`peer_event` `quiet`,
    /// outcome `queued_slow`), takes `peer_send` `to_list` (one message to
    /// several addresses, answered per recipient in `results`), and keys
    /// relayed mail by (id, to). Absent = never send `quiet` or `to_list`:
    /// every message wakes its recipient, as before.
    peer_slow_mail,
    /// The broker keeps an alias per peer address (`peermail` "Aliases"):
    /// `peer_register` `alias` (a requested one), `alias` in `peer_list`
    /// (`self` and every peer) and in a delivery's `from`, aliases taken
    /// as `peer_send` `to`, `peer_subject` `title` from an attached viewer,
    /// and `grants` in a hub's presence. Absent = a client registers its
    /// name as its address, as before, and sends no title.
    peer_alias,
    /// The broker keeps whether each peer's server can push messages into
    /// its session (`peer_register` `armed`) and reports the ones that
    /// cannot: `polls` in `peer_list`, `to_polls` in `peer_send_reply` and
    /// relays. Absent = nothing is known: no peer is marked.
    peer_polls,
    /// The broker takes `peer_hook_presence` from a session's hook or
    /// status line whose own server is gone, matched to the address by the
    /// client pid that server registered (`peer_register` `client_pid`),
    /// and lists that address `no_mcp` (`to_no_mcp` in `peer_send_reply`).
    /// Absent = never send it; such an address reads gone.
    peer_hook_presence,
    /// The broker keeps each live peer's note (what its own assistant says
    /// it is doing): `peer_subject` `note` sets it on a live address, and
    /// `note`/`note_ms` in `peer_list`, `sender_note` in `peer_deliver`
    /// and the federation presence carry it. Absent = never send it; the
    /// `peer_set_note` tool answers unavailable.
    peer_note,
    /// The broker beats on its federation links: it sends
    /// `peer_link_beat` every `peerhold.BEAT_MS` to a far side that says
    /// it takes them, takes them itself, and closes a link whose beating
    /// far side fell silent. Its hellos name its daemon (`instance`), and
    /// it refuses a second daemon of one host while the first holds the
    /// link (`.err` with `link_held`). Absent = never send the beat (an
    /// older daemon answers an unknown frame with `.err`); its links are
    /// live until the transport closes, as before.
    peer_link_beat,
};

/// One bool per flag, keyed by wire name; the parsed form on the
/// client and the advertised form on the daemon.
pub const Set = std.enums.EnumFieldStruct(Flag, bool, false);

/// What a current daemon advertises: every flag it knows.
pub const all: Set = blk: {
    var s: Set = .{};
    for (@typeInfo(Set).@"struct".fields) |f| @field(s, f.name) = true;
    break :blk s;
};

/// `Base` with one bool per flag appended, so a welcome JSON stays
/// FLAT (old clients read top-level keys; nesting would hide every
/// flag from them).
pub fn WithFlags(comptime Base: type) type {
    const base = @typeInfo(Base).@"struct".fields;
    const flags = @typeInfo(Set).@"struct".fields;
    var names: [base.len + flags.len][:0]const u8 = undefined;
    var types: [base.len + flags.len]type = undefined;
    var attrs: [base.len + flags.len]std.builtin.Type.StructField.Attributes = undefined;
    for (base, 0..) |f, i| {
        names[i] = f.name;
        types[i] = f.type;
        attrs[i] = .{ .default_value_ptr = f.default_value_ptr, .@"comptime" = f.is_comptime, .@"align" = f.alignment };
    }
    for (flags, 0..) |f, i| {
        names[base.len + i] = f.name;
        types[base.len + i] = f.type;
        attrs[base.len + i] = .{ .default_value_ptr = f.default_value_ptr };
    }
    const final_names = names;
    const final_types = types;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

/// `base`'s fields followed by `flags`, as a `WithFlags(@TypeOf(base))`.
pub fn withFlags(base: anytype, flags: Set) WithFlags(@TypeOf(base)) {
    var out: WithFlags(@TypeOf(base)) = undefined;
    inline for (@typeInfo(@TypeOf(base)).@"struct".fields) |f| @field(out, f.name) = @field(base, f.name);
    inline for (@typeInfo(Set).@"struct".fields) |f| @field(out, f.name) = @field(flags, f.name);
    return out;
}

/// Parse the flags out of a welcome payload. Unknown keys are
/// skipped (a newer daemon), missing keys read false (an older one),
/// and a malformed value costs every flag, never the rest of the
/// welcome, which the caller parses separately.
pub fn parse(allocator: std.mem.Allocator, payload: []const u8) Set {
    const parsed = std.json.parseFromSlice(Set, allocator, payload, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    return parsed.value;
}

const t = std.testing;

test "every flag is advertised, parsed back and reset by the same table" {
    const Base = struct { proto: u32, version: []const u8 };
    const welcome = withFlags(Base{ .proto = 7, .version = "x" }, all);
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(welcome, .{}, &aw.writer);
    const json = aw.written();
    // Flat keys, every flag present and true, base fields intact.
    try t.expect(std.mem.indexOf(u8, json, "\"proto\":7") != null);
    inline for (@typeInfo(Flag).@"enum".fields) |f| {
        try t.expect(std.mem.indexOf(u8, json, "\"" ++ f.name ++ "\":true") != null);
    }
    const back = parse(t.allocator, json);
    inline for (@typeInfo(Set).@"struct".fields) |f| try t.expect(@field(back, f.name));
    // An old daemon's welcome (no flags) reads as none; a partial one
    // keeps only what it names; a malformed value yields none.
    const none = parse(t.allocator, "{\"proto\":5}");
    inline for (@typeInfo(Set).@"struct".fields) |f| try t.expect(!@field(none, f.name));
    const some = parse(t.allocator, "{\"proto\":6,\"lsp\":true,\"future_flag\":true}");
    try t.expect(some.lsp);
    try t.expect(!some.udp_ticket);
    const bad = parse(t.allocator, "{\"stream_open\":\"yes\",\"lsp\":true}");
    try t.expect(!bad.lsp);
    try t.expect(!bad.stream_open);
    // The reset value is the all-false set.
    const reset: Set = .{};
    inline for (@typeInfo(Set).@"struct".fields) |f| try t.expect(!@field(reset, f.name));
    try t.expectEqual(@typeInfo(Flag).@"enum".fields.len, @typeInfo(Set).@"struct".fields.len);
}
