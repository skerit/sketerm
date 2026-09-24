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

/// The flags of any struct that carries them by wire name (a parsed
/// welcome), copied out into a `Set`.
pub fn flagsOf(v: anytype) Set {
    var s: Set = .{};
    inline for (@typeInfo(Set).@"struct".fields) |f| @field(s, f.name) = @field(v, f.name);
    return s;
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
