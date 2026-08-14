//! Mux wire format: framing + Event (de)serialization.
//!
//! THE compatibility surface between sketerm-mux daemon and clients
//! (possibly different builds on different hosts). Rules:
//!   - little-endian, length-prefixed frames and payloads
//!   - frame tag values are append-only; readers skip unknown frames
//!   - the legacy event stream is frozen because events lack lengths
//!   - optional features use independent frames/capabilities, not a
//!     mandatory core-version bump
//!
//! Pure code, no GTK, no sockets — unit-tested headless.

const std = @import("std");
const Event = @import("../parser/event.zig").Event;

/// Version 2 adds the byte-channel frame envelope. Individual channel
/// kinds remain gated until the profile that defined their payload.
/// Version 3 adds the file-transfer frames (file_*):
/// the GUI streams a local file to the daemon, which writes it into
/// the session shell's working directory — so "upload to remote"
/// works over any transport (local/SSH/UDP) with no shell help.
/// Clients advertise their newest protocol and daemons only emit
/// features they implement. A client may accept older daemon versions
/// whose snapshots and channel state it can still decode.
/// Version 4 widens the snapshot frame header from [seq:u64] to
/// [seq:u64][app:u8], so an attaching client learns whether the
/// session is a forwarded GUI app (`sketerm app`) and can hold the
/// pane open on app exit instead of detaching to a shell.
/// Version 5 moves the Wayland compositor brain into the daemon:
/// wayland_native channels broadcast to every attached client
/// (passive replicas), viewers drive input via seat-intent pipe
/// units, and attach replays pool bytes + a state_sync unit so app
/// windows survive detach/reattach (durable GUI apps).
/// Version 6 extends the native-channel state_sync blob with complete
/// linux-dmabuf plane metadata. Daemons gate that state on the selected
/// profile while newer clients retain older state decoders.
pub const PROTO_VERSION: u32 = 6;
/// Protocol 1 shipped with three indistinguishable snapshot revisions, so a
/// current daemon cannot safely choose a snapshot for an unmodified v1 client.
pub const MIN_SERVER_PROTO: u32 = 2;
pub const NATIVE_STATE_PROTO_VERSION: u32 = 6;
pub const LEGACY_NATIVE_STATE_VERSION: u8 = 6;
pub const NATIVE_STATE_VERSION: u8 = 11;
/// State-sync version a replica needs to parse a session whose
/// compositor advertises modifier-backed dmabufs.
pub const DMABUF_MODIFIER_STATE_VERSION: u8 = 7;
/// ... and one advertising linux-dmabuf v4 feedback objects.
pub const DMABUF_FEEDBACK_STATE_VERSION: u8 = 8;
/// ... and one whose app used a core request added after v8
/// (wl_compositor/wl_shm/wl_data_device_manager release, wl_fixes,
/// wl_surface.get_release).
pub const CORE_BUMP_STATE_VERSION: u8 = 9;
/// ... and one whose app bound an xdg-foreign global (zxdg_exporter_v2
/// / zxdg_importer_v2 are absent from a v9 replica's tables).
pub const FOREIGN_STATE_VERSION: u8 = 10;
/// ... and one whose app bound xdg_wm_dialog_v1 (neither
/// xdg_wm_dialog_v1 nor xdg_dialog_v1 exists in a v10 replica's
/// tables, so the bind alone kills it). v11 also carries the
/// per-surface modality flag.
pub const DIALOG_STATE_VERSION: u8 = 11;
pub const WINSTREAM_PROTO_VERSION: u32 = 5;

/// Select the newest core profile both advertised ranges share, or zero.
pub fn negotiateProtocol(peer_min: u32, peer_max: u32) u32 {
    const selected = @min(peer_max, PROTO_VERSION);
    return if (selected >= @max(peer_min, MIN_SERVER_PROTO)) selected else 0;
}

/// Frame types. Append-only.
pub const FrameType = enum(u8) {
    // client → daemon
    hello = 1,
    attach = 2,
    spawn = 3,
    input = 4,
    resize = 5,
    detach = 6,
    list = 7,
    kill = 8,
    // client → daemon (continued; append-only)
    shutdown = 9,
    rename = 10,
    // File upload (client → daemon). A transfer is a JSON `file_open`
    // (name + size), a run of `file_data` chunks ([u32 xfer | bytes]),
    // then `file_close` ([u32 xfer]). The daemon answers each with a
    // JSON `file_reply` carrying cumulative-written for flow control.
    file_open = 11,
    file_data = 12,
    file_close = 13,
    // File download (client → daemon): JSON `file_get` ({xfer, path}).
    // The daemon answers `file_reply` "ready" (with size + basename),
    // streams `file_data` chunks the OTHER way (daemon → client), then
    // `file_reply` "done". `file_data` is thus bidirectional — the
    // receiver's context (upload vs download xfer) tells the directions
    // apart.
    file_get = 14,
    // Remote directory browse (client → daemon): JSON `file_list`
    // ({xfer, path}). The daemon answers `file_listing` (a JSON
    // directory listing) so the GUI can offer a remote file picker.
    file_list = 15,
    // Installed-app discovery (client → daemon): empty payload. The
    // daemon scans its own $XDG_DATA_DIRS/applications/*.desktop and
    // answers `app_listing`, so a client can offer a launcher for the
    // apps on the session's host (the remote, over SSH/UDP).
    app_list = 16,
    /// AT-SPI request for the attached app session. Empty payload (or
    /// {op:"tree"}) = tree walk; {op:"action"|"set_text"|"set_value",
    /// id, index?/text?/value?} performs the op on one node. Answered
    /// with app_a11y_tree ({tree}, {ok:true}, or {error}).
    app_a11y = 17,
    /// Start recording the ATTACHED session's raw PTY output as an
    /// asciicast v2 file on the daemon's host. JSON { path }.
    /// Answered with ok / err. Recording survives detach; a second
    /// rec_start replaces the previous recording.
    rec_start = 18,
    /// Stop the attached session's recording. Empty payload; ok/err.
    rec_stop = 19,
    /// Search the ATTACHED session's scrollback + live grid. JSON
    /// { pattern, max? } (case-insensitive substring). Answered with
    /// `search_hits`. Attach-scoped so it reaches the worker that
    /// owns the Screen in broker mode.
    search = 20,
    /// Open a TCP forward: JSON { port } — the daemon connects to
    /// 127.0.0.1:port ON ITS HOST and answers with a `chan_open`
    /// (kind tcp_forward) owned by the requesting client; raw bytes
    /// then flow as chan_data both ways. No attach required.
    forward_open = 21,
    /// Fetch lines from the ATTACHED session's indexed log ring
    /// (escape-free PTY output, one monotonically-increasing id per
    /// line). JSON { tail?, from_id?, id?, max_chars? }; answered
    /// with `log_data`. Attach-scoped so it reaches the worker that
    /// owns the Session in broker mode.
    log_get = 22,
    /// File-service control op (fsserve). JSON { req, op, ... } where
    /// op selects the verb (open_view/close_view/list/stat/read/
    /// mkdir/rename/delete/symlink) — extending the service is a new
    /// op string, not a new frame type. NOT attach-scoped: served by
    /// whichever process owns the client connection (the broker, in
    /// broker mode — fs clients never attach). Every op is answered
    /// by `fs_reply` frames echoing `req` (listings arrive as a chunk
    /// run, `more:true` until the last), reads additionally stream
    /// `fs_data`. A directory VIEW (open_view) stays subscribed:
    /// daemon-side inotify pushes `fs_delta` until close_view / the
    /// client disconnects. This is the phase-1 surface of the file
    /// browser (docs/filebrowser-roadmap.md).
    fs_op = 23,
    /// File write (fsserve), binary — the one fs verb whose payload
    /// is bulk bytes: [u32 req][u64 off][u8 flags][u16 path_len]
    /// [path][data]. flags bit0=create bit1=truncate bit2=append
    /// bit3=exclusive. Answered with `fs_reply` { req, written }.
    fs_write = 24,
    /// Controller-lease request for the ATTACHED session's Wayland
    /// seat: JSON { op } where op ∈ acquire|release|takeover.
    /// `acquire` only succeeds while nobody holds the lease;
    /// `takeover` evicts the current controller. Answered by a
    /// `control_state` broadcast (never an ok/err — the state IS the
    /// answer, and every viewer needs it anyway).
    control_req = 25,
    /// Mint a sibling UDP listener on the daemon's host, so a NEW
    /// client can reach this daemon over UDP without its own ssh
    /// bootstrap (connection-ticket brokering). JSON { range? }
    /// (optional "lo:hi" port pin, like --udp-port). Answered with
    /// `udp_ticket`. Only sent to daemons whose welcome advertises
    /// `udp_ticket:true` — older daemons would answer `.err`, which
    /// a multiplexed GUI connection could misattribute to another
    /// pending request.
    udp_ticket_req = 26,
    /// Ask an IDLE daemon (no sessions, no running jobs or transfers)
    /// to exit so the next connect autostarts the freshly deployed
    /// binary. JSON {}; answered `.ok` { ok, error? } — ok:false =
    /// busy, nothing happens. Only sent to daemons whose welcome
    /// advertises `quit_idle:true` AND a `build` differing from the
    /// client's own; older daemons never see the frame.
    quit_idle = 27,
    /// Spawn a language server NEAR THE FILES (on this daemon's host)
    /// and bridge its stdio as a byte channel. JSON { req, dir,
    /// servers: [{name, command, args, root_files}] } — an ordered
    /// candidate list from the CLIENT's config; the daemon picks the
    /// first whose command resolves on ITS PATH, resolves the workspace
    /// root by walking `dir` up for `root_files` markers on ITS
    /// filesystem (falling back to `dir`, same semantics as the local
    /// client), spawns it, and answers `chan_open` (kind lsp) +
    /// `lsp_reply`. Raw Content-Length-framed JSON-RPC then flows as
    /// chan_data both ways — the daemon never parses it. NOT
    /// attach-scoped (like fs_op): served by whichever process owns
    /// the client connection. Only sent to daemons whose welcome
    /// advertises `lsp:true`.
    lsp_open = 28,
    /// Debugger request against the ATTACHED session's own child (the
    /// daemon IS its parent, so it can grant a tracer what a caller in
    /// another process tree cannot get past Yama). JSON
    /// { op:"backtrace", timeout_ms? }. Answered with `app_debug_data`.
    /// Attach-scoped: served by the worker owning the session.
    app_debug = 29,
    /// Playback control for the ATTACHED cast-playback session. JSON
    /// { op, ms?, speed? } where op ∈ play|pause|restart|seek|speed
    /// (seek uses `ms`, speed uses `speed`, clamped to [0.1, 10]).
    /// Silently ignored for PTY sessions and by older daemons — only
    /// sent when the welcome advertises `cast_playback:true`. Answered
    /// by a `play_state` broadcast, never ok/err.
    play_control = 30,
    /// Correlated native-panel RPC request with [u64 id little-endian]
    /// [opaque JSON], rewritten to a daemon route id for one presenter.
    panel_request = 31,
    /// Web-store op (browsing history / bookmarks / per-site settings
    /// persisted on the DAEMON's host, so browsing state follows the
    /// host you attach to). JSON { req, op, ... } where op selects the
    /// verb (history_add/history_title/history_query/history_delete/
    /// history_clear/bookmark_add/bookmark_remove/bookmark_update/
    /// bookmark_list/site_get/site_set) — extending the store is a new
    /// op string, not a new frame type (the fs_op shape). NOT
    /// attach-scoped: served by whichever process owns the client
    /// connection. Answered by `web_reply` echoing `req`. Only sent to
    /// daemons whose welcome advertises `web_store:true` — an older
    /// daemon would answer `.err`, misattributable on a multiplexed
    /// connection.
    web_op = 32,
    /// Open a TCP stream to an ARBITRARY host:port FROM the daemon's
    /// host, with the hostname resolved at the daemon's end (remote
    /// DNS). JSON { req, host, port }. Answered with `stream_reply`
    /// echoing `req` and, on ok, a `chan_open` (kind tcp_forward) whose
    /// raw bytes flow as chan_data both ways — the egress primitive
    /// behind per-container "browse via server X". Unlike `forward_open`
    /// (loopback-only, port-only) this reaches any host the daemon can.
    /// Only sent to daemons whose welcome advertises `stream_open:true`.
    stream_open = 33,
    /// Spawn a `sketerm-webengine` browser helper ON the daemon's host
    /// and bridge its protocol socket as a byte channel — the remote
    /// browsing primitive: the helper renders where the daemon runs and
    /// its frames ride the mux wire in-band (the helper is launched
    /// with `--frames-inline`, so no descriptor ever needs to cross).
    /// JSON { req }. Answered with `web_helper_reply` echoing `req`
    /// and, on ok, preceded by a `chan_open` (kind web_helper) whose
    /// chan_data is the raw helper protocol byte stream, 1:1 with the
    /// requesting client. The helper DIES with the channel (client
    /// disconnect included), exactly like an lsp child. NOT
    /// attach-scoped: served by whichever process owns the client
    /// connection. Only sent to daemons whose welcome advertises
    /// `web_helper:true` — an old daemon would answer `.err`,
    /// misattributable on a multiplexed connection.
    web_helper_open = 34,
    // daemon → client
    welcome = 64,
    snapshot = 65,
    events = 66,
    exit = 67,
    gone = 68,
    ok = 69,
    err = 70,
    /// JSON status for an in-flight upload: { xfer, status, written,
    /// path?, message? }. status ∈ ready|progress|done|error.
    file_reply = 71,
    /// JSON directory listing answering `file_list`: { xfer, path,
    /// entries: [{name, dir, size}], error?, truncated? }.
    file_listing = 72,
    /// JSON app listing answering `app_list`: { apps: [{name, exec,
    /// icon, terminal}], truncated? }.
    app_listing = 73,
    /// JSON attach roster for the client's session, pushed whenever
    /// it changes: { total, guis, drivers } (drivers = headless MCP
    /// clients). Lets viewers show an "assistant is driving" badge.
    peer_info = 74,
    /// JSON AT-SPI tree answering app_a11y: { tree: <node> } or
    /// { error: "..." }. Node = { role, name, states, rect?, children? }.
    app_a11y_tree = 75,
    /// JSON answer to `search`: { hits: [{back, text}], total } —
    /// `back` = display lines up from the bottom of the live grid,
    /// `total` = matches found (hits capped at the request's max).
    search_hits = 76,
    /// JSON answer to `log_get`: { next_id, dropped, lines: [{id, t,
    /// text, truncated?, cut?, marker?}] }. `t` = epoch ms on the
    /// daemon's host; `truncated` = stored line was capped at ingest;
    /// `cut` = shortened to the request's max_chars in this reply.
    log_data = 77,
    /// Pushed to every attached client when the session's child emits
    /// the sketerm marker escape (OSC 5522 ; label): JSON { id, label,
    /// t } where `id` is the marker's log-ring line id. Viewers may
    /// stash a screenshot of the app's current frame against it.
    marker = 78,
    // Byte channels (both directions). Generic multiplexed streams
    // riding the mux connection — used to tunnel a session's app
    // protocol, so forwarded apps inherit whatever transport the
    // terminal uses (incl. roaming UDP). The daemon initiates with
    // chan_open; chan_data/chan_close flow both ways.
    chan_open = 80,
    chan_data = 81,
    chan_close = 82,
    /// Daemon → MCP client: native app-channel streaming toward this
    /// client is PAUSED (its outbound queue crossed the backlog cap).
    /// A replay of every native channel, rebuilt from the daemon's
    /// live mirrors and terminated by `native_sync`, follows once the
    /// client fully drains. Empty payload.
    native_gap = 83,
    /// Daemon → MCP client: the post-drain native replay is complete;
    /// the client's replicas now reflect the live mirrors. Empty.
    native_sync = 84,
    /// JSON answer to `fs_op`/`fs_write`, always echoing the request's
    /// `req` IN THE HEADER (the log_get nonce lesson: never match
    /// replies by arrival order). { req, ok, error?, ... } with
    /// op-specific fields: listings { path, entries, more, truncated }
    /// (chunk run — accumulate until more=false), stat { entry },
    /// read { size, eof } (closes the fs_data run), write { written }.
    fs_reply = 85,
    /// Pushed change on an open directory view: JSON { view, changes:
    /// [{op:"upsert", entry} | {op:"del", name}], gone?, resync? }.
    /// `gone` = the watched directory itself vanished (view is dead);
    /// `resync` = the kernel dropped events (queue overflow) — the
    /// client must re-list, deltas alone are no longer sufficient.
    /// Coalesced per poll tick; upserts are idempotent (an entry may
    /// arrive both in the initial listing and as a delta).
    fs_delta = 86,
    /// Bulk bytes answering an fs_op read: [u32 req][u64 off][data].
    /// A terminating `fs_reply` carries size/eof.
    fs_data = 87,
    /// Pushed job event (fs_op copy/delete_tree/hash/disk_usage verbs): JSON
    /// { job, ev:"progress"|"done"|"error", done, total, hash?,
    /// resumed_from?, message?, state? }. Durable jobs survive the
    /// requesting client; events flow to the owner while it lives and
    /// job_list serves any client afterwards. disk_usage adds
    /// streaming `usage` records with path/kind/size/allocated/items/
    /// errors/skipped/mtime_ms and remains ephemeral.
    fs_job = 88,
    /// Controller lease state for the client's session, pushed to
    /// EVERY attached client on every change (attach, release,
    /// takeover, controller death): JSON { controller, read_only,
    /// controller_label, viewers }. `controller` is "do I hold it" —
    /// each recipient gets its own view, so a viewer that asked for
    /// control and did not get it learns so without polling.
    control_state = 89,
    /// Daemon-authoritative metadata for the attached session. JSON
    /// `{cwd}` follows every snapshot so a newly attached GUI does not
    /// depend on having witnessed an earlier OSC 7 event.
    session_meta = 90,
    /// Answer to `udp_ticket_req`: JSON { ok, port?, key?, error? }.
    /// `key` is the rudp key as hex; the listener is single-use (the
    /// mosh-server model: one instance per connection) and retires
    /// itself when no client authenticates within its grace window.
    udp_ticket = 91,
    /// Answer to `lsp_open`, ALWAYS echoing the request's `req` (fs_op
    /// nonce discipline): JSON { req, ok, chan?, name?, root?, error? }.
    /// ok:false = no candidate server is installed on this host (or the
    /// spawn failed) — the client degrades silently, exactly like a
    /// missing local server. On ok:true a `chan_open` (kind lsp) for
    /// `chan` precedes this frame.
    lsp_reply = 92,
    /// JSON answer to `app_debug`: { ok, pid, tool, text, truncated?,
    /// timed_out? } or { error }. `text` is the debugger's raw output
    /// (thread backtraces); the request is served ASYNCHRONOUSLY — the
    /// debugger runs as a daemon subprocess whose pipe is polled like a
    /// file job, so a 10-second attach never stalls the poll loop.
    app_debug_data = 93,
    /// Playback state of a cast-playback session, pushed to every
    /// attached client on state changes and throttled (>=500ms apart)
    /// while playing: JSON { state:"playing"|"paused"|"seeking"|
    /// "finished", position_ms, duration_ms (null until EOF is known),
    /// speed, markers:[[ms,"label"],...] }. Sent once per attach.
    play_state = 94,
    /// Correlated native-panel RPC result accepted only from the selected
    /// presenter and restored to the requester's original caller id.
    panel_reply = 95,
    /// JSON answer to `web_op`, ALWAYS echoing the request's `req`
    /// (fs_op nonce discipline): { req, ok, error?, ... } with
    /// op-specific fields — history_query { hits:[{url,title,visits,
    /// last_ms,score}] }, bookmark_add { id }, bookmark_list
    /// { bookmarks:[{id,url,title,folder}] }, site_get { origin,
    /// site:{zoom_x100,popup,block,perms:[{name,decision}]}|null }.
    web_reply = 96,
    /// Answer to `stream_open`, ALWAYS echoing the request's `req`
    /// (fs_op nonce discipline): JSON { req, ok, chan?, error? }. On
    /// ok:true a `chan_open` (kind tcp_forward) for `chan` precedes this
    /// frame; ok:false carries the failure (bad request, DNS miss,
    /// connect refused) so a SOCKS bridge can answer its client.
    stream_reply = 97,
    /// Answer to `web_helper_open`, ALWAYS echoing the request's `req`
    /// (fs_op nonce discipline): JSON { req, ok, chan?, error? }. On
    /// ok:true a `chan_open` (kind web_helper) for `chan` precedes this
    /// frame; ok:false carries the failure ("sketerm-webengine is not
    /// installed on this host", spawn failure) so the GUI can show a
    /// described error instead of a hang.
    web_helper_reply = 98,
    _,
};

/// chan_open payload kinds. Append-only — 1 (legacy waypipe bridge)
/// is retired and never emitted.
pub const ChannelKind = enum(u8) {
    /// Sketerm-native app pipe: chan_data carries wlhost/pipe.zig
    /// units (Wayland messages + shm pool side-band). The GUI
    /// compositor brain consumes it directly.
    wayland_native = 2,
    /// Window pixel stream (winstream/proto.zig units): remotes
    /// with no forwardable display protocol — macOS capture agent;
    /// the stub backend tests the pipeline anywhere.
    winstream = 3,
    /// Remote audio (mux/pulse.zig units): the daemon is the
    /// session's PulseAudio server; PCM streams toward the viewer,
    /// consumed/latency reports flow back as the playback clock.
    audio = 4,
    /// Raw TCP forward (answering `forward_open`): chan_data carries
    /// unframed socket bytes; 1:1 with the requesting client.
    tcp_forward = 5,
    /// Language-server stdio bridge (answering `lsp_open`): chan_data
    /// carries the server's raw Content-Length-framed JSON-RPC bytes;
    /// 1:1 with the requesting client, and the daemon-side child DIES
    /// with the channel (client disconnect included) — an LSP session
    /// cannot be re-attached mid-`initialize`, so a durable server
    /// process would only leak memory on the remote host.
    lsp = 6,
    /// Browser-helper protocol bridge (answering `web_helper_open`):
    /// chan_data carries the raw sketerm-web protocol byte stream of a
    /// `sketerm-webengine --frames-inline` spawned on the daemon's
    /// host; 1:1 with the requesting client, and the helper dies with
    /// the channel (the lsp lifecycle).
    web_helper = 7,
    _,
};

/// chan_open: u32 channel id + u8 kind.
pub fn encodeChanOpen(buf: *[5]u8, id: u32, kind: ChannelKind) []const u8 {
    std.mem.writeInt(u32, buf[0..4], id, .little);
    buf[4] = @intFromEnum(kind);
    return buf[0..5];
}

pub fn decodeChanOpen(payload: []const u8) ?struct { id: u32, kind: ChannelKind } {
    if (payload.len < 5) return null;
    return .{
        .id = std.mem.readInt(u32, payload[0..4], .little),
        .kind = @enumFromInt(payload[4]),
    };
}

/// chan_data: u32 channel id + raw bytes. chan_close: u32 id only.
pub fn putChanHeader(buf: *[4]u8, id: u32) []const u8 {
    std.mem.writeInt(u32, buf[0..4], id, .little);
    return buf[0..4];
}

pub fn decodeChanId(payload: []const u8) ?u32 {
    if (payload.len < 4) return null;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub const MAX_FRAME = 16 << 20; // images can be chunky; bound anyway

/// Independent capability version for panel RPC; it does not alter the
/// terminal snapshot/event profile selected by PROTO_VERSION.
pub const PANEL_RPC_VERSION: u8 = 1;

/// Lifetime-unique session incarnation identity as it appears on the wire:
/// 32 lowercase hex digits. Minting lives daemon-side (needs entropy);
/// validation lives here so stores and clients need no daemon import.
pub const SESSION_ORIGIN_ID_BYTES: usize = 16;
pub const SESSION_ORIGIN_ID_LEN: usize = SESSION_ORIGIN_ID_BYTES * 2;
pub const SessionOriginId = [SESSION_ORIGIN_ID_LEN]u8;

pub fn validSessionOriginId(id: []const u8) bool {
    if (id.len != SESSION_ORIGIN_ID_LEN) return false;
    for (id) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

test "session origin id validation accepts exactly 32 lowercase hex digits" {
    try std.testing.expect(validSessionOriginId("00000000000000000000000000000001"));
    try std.testing.expect(!validSessionOriginId("0000000000000000000000000000001")); // 31
    try std.testing.expect(!validSessionOriginId("0000000000000000000000000000000A")); // uppercase
    try std.testing.expect(!validSessionOriginId(""));
}
/// Panel documents can be 1 MiB and outer JSON escaping may expand them.
/// The envelope remains comfortably below MAX_FRAME, including its tag.
pub const PANEL_JSON_MAX: usize = 4 << 20;
pub const PANEL_ENVELOPE_HEADER: usize = @sizeOf(u64);
pub const PANEL_ENVELOPE_MAX: usize = PANEL_ENVELOPE_HEADER + PANEL_JSON_MAX;

comptime {
    if (PANEL_ENVELOPE_MAX + 1 >= MAX_FRAME)
        @compileError("panel envelope must remain below MAX_FRAME");
}

pub const PanelEnvelope = struct {
    id: u64,
    json: []const u8,
};

pub const PanelEnvelopeError = error{ Truncated, EmptyJson, TooLong };

/// Decode only the correlation id, including from an otherwise malformed or
/// oversized envelope so the daemon can fail its live route immediately.
pub fn decodePanelEnvelopeId(payload: []const u8) ?u64 {
    if (payload.len < PANEL_ENVELOPE_HEADER) return null;
    return std.mem.readInt(u64, payload[0..PANEL_ENVELOPE_HEADER], .little);
}

/// Validate and split a panel RPC envelope without interpreting its JSON.
pub fn decodePanelEnvelope(payload: []const u8) PanelEnvelopeError!PanelEnvelope {
    if (payload.len < PANEL_ENVELOPE_HEADER) return error.Truncated;
    const json = payload[PANEL_ENVELOPE_HEADER..];
    if (json.len == 0) return error.EmptyJson;
    if (json.len > PANEL_JSON_MAX) return error.TooLong;
    return .{
        .id = decodePanelEnvelopeId(payload).?,
        .json = json,
    };
}

/// Append one validated panel envelope to `out`.
pub fn appendPanelEnvelope(out: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u64, json: []const u8) !void {
    if (json.len == 0) return error.EmptyJson;
    if (json.len > PANEL_JSON_MAX) return error.TooLong;
    var header: [PANEL_ENVELOPE_HEADER]u8 = undefined;
    std.mem.writeInt(u64, &header, id, .little);
    try out.appendSlice(allocator, &header);
    try out.appendSlice(allocator, json);
}

/// Drop `consumed` leading bytes from a stream buffer, sliding the
/// unread tail down in place (capacity retained).
pub fn compactConsumed(list: *std.ArrayList(u8), consumed: usize) void {
    if (consumed == 0) return;
    const rem = list.items.len - consumed;
    std.mem.copyForwards(u8, list.items[0..rem], list.items[consumed..]);
    list.shrinkRetainingCapacity(rem);
}

/// Frozen legacy event schema: records have no length, so adding a tag
/// would desynchronize older readers; new optional data belongs in a mux
/// frame until a negotiated length-delimited event schema exists.
const EventTag = enum(u8) {
    print = 1,
    print_byte = 2,
    print_run = 3,
    execute = 4,
    csi = 5,
    esc_final = 6,
    osc = 7,
    apc = 8,
    dcs = 9,
    child_eof = 10,
    parse_error = 11,
    _,
};

pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    fn putInt(self: *Writer, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try self.buf.appendSlice(self.allocator, &tmp);
    }

    fn putBytes(self: *Writer, b: []const u8) !void {
        try self.putInt(u32, @intCast(b.len));
        try self.buf.appendSlice(self.allocator, b);
    }

    /// Serialize one Event. Legacy markers (`dcs_start`, `dcs_data`,
    /// `dcs_end`) are never produced by the current parser and are
    /// not representable on the wire.
    pub fn putEvent(self: *Writer, ev: Event) !void {
        switch (ev) {
            .print => |cp| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.print));
                try self.putInt(u32, cp);
            },
            .print_byte => |b| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.print_byte));
                try self.buf.append(self.allocator, b);
            },
            .print_run => |r| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.print_run));
                try self.buf.append(self.allocator, r.len);
                try self.buf.appendSlice(self.allocator, r.bytes[0..r.len]);
            },
            .execute => |b| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.execute));
                try self.buf.append(self.allocator, b);
            },
            .csi => |csi| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.csi));
                try self.buf.append(self.allocator, csi.n_params);
                for (csi.params[0..csi.n_params]) |p| try self.putInt(u16, p);
                try self.putInt(u16, csi.is_sub_bits);
                try self.buf.append(self.allocator, csi.n_intermediates);
                try self.buf.appendSlice(self.allocator, csi.intermediates[0..csi.n_intermediates]);
                try self.buf.append(self.allocator, csi.private);
                try self.buf.append(self.allocator, csi.final);
            },
            .esc_final => |e| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.esc_final));
                try self.buf.append(self.allocator, e.n_intermediates);
                try self.buf.appendSlice(self.allocator, e.intermediates[0..e.n_intermediates]);
                try self.buf.append(self.allocator, e.final);
            },
            .osc => |o| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.osc));
                try self.putBytes(o.bytes);
            },
            .apc => |o| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.apc));
                try self.putBytes(o.bytes);
            },
            .dcs => |d| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.dcs));
                try self.buf.append(self.allocator, d.proto.n_params);
                for (d.proto.params[0..d.proto.n_params]) |p| try self.putInt(u16, p);
                try self.buf.append(self.allocator, d.proto.n_intermediates);
                try self.buf.appendSlice(self.allocator, d.proto.intermediates[0..d.proto.n_intermediates]);
                try self.buf.append(self.allocator, d.proto.final);
                try self.putBytes(d.body);
            },
            .child_eof => |status| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.child_eof));
                try self.putInt(i32, status);
            },
            .parse_error => |pe| {
                try self.buf.append(self.allocator, @intFromEnum(EventTag.parse_error));
                try self.buf.append(self.allocator, @intFromEnum(pe.kind));
            },
            .dcs_start, .dcs_data, .dcs_end => return error.LegacyEventNotWireable,
        }
    }
};

pub const ReadError = error{ Truncated, BadTag, TooLong, OutOfMemory };

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.bytes.len;
    }

    fn take(self: *Reader, n: usize) ReadError![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn getInt(self: *Reader, comptime T: type) ReadError!T {
        const s = try self.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    fn getByte(self: *Reader) ReadError!u8 {
        return (try self.take(1))[0];
    }

    /// Length-prefixed bytes; the returned slice is HEAP-OWNED by
    /// `allocator` (events transfer payload ownership, mirroring the
    /// parser's own allocation contract).
    fn getOwnedBytes(self: *Reader, allocator: std.mem.Allocator) ReadError![]u8 {
        const len = try self.getInt(u32);
        if (len > MAX_FRAME) return error.TooLong;
        const s = try self.take(len);
        return allocator.dupe(u8, s) catch return error.OutOfMemory;
    }

    /// Deserialize one Event. OSC/APC/DCS payloads are allocated from
    /// `allocator`; caller owns the Event (free via Event.deinit).
    pub fn getEvent(self: *Reader, allocator: std.mem.Allocator) ReadError!Event {
        const tag_byte = try self.getByte();
        const tag: EventTag = @enumFromInt(tag_byte); // non-exhaustive; switch `_` rejects
        switch (tag) {
            .print => return .{ .print = try self.getInt(u32) },
            .print_byte => return .{ .print_byte = try self.getByte() },
            .print_run => {
                var r: Event.PrintRun = .{};
                r.len = try self.getByte();
                if (r.len > r.bytes.len) return error.Truncated;
                @memcpy(r.bytes[0..r.len], try self.take(r.len));
                return .{ .print_run = r };
            },
            .execute => return .{ .execute = try self.getByte() },
            .csi => {
                var csi: Event.Csi = .{};
                csi.n_params = try self.getByte();
                if (csi.n_params > csi.params.len) return error.Truncated;
                for (0..csi.n_params) |i| csi.params[i] = try self.getInt(u16);
                csi.is_sub_bits = try self.getInt(u16);
                csi.n_intermediates = try self.getByte();
                if (csi.n_intermediates > csi.intermediates.len) return error.Truncated;
                @memcpy(csi.intermediates[0..csi.n_intermediates], try self.take(csi.n_intermediates));
                csi.private = try self.getByte();
                csi.final = try self.getByte();
                return .{ .csi = csi };
            },
            .esc_final => {
                var e: Event.EscFinal = .{};
                e.n_intermediates = try self.getByte();
                if (e.n_intermediates > e.intermediates.len) return error.Truncated;
                @memcpy(e.intermediates[0..e.n_intermediates], try self.take(e.n_intermediates));
                e.final = try self.getByte();
                return .{ .esc_final = e };
            },
            .osc => return .{ .osc = .{ .bytes = try self.getOwnedBytes(allocator) } },
            .apc => return .{ .apc = .{ .bytes = try self.getOwnedBytes(allocator) } },
            .dcs => {
                var proto: Event.Dcs = .{};
                proto.n_params = try self.getByte();
                if (proto.n_params > proto.params.len) return error.Truncated;
                for (0..proto.n_params) |i| proto.params[i] = try self.getInt(u16);
                proto.n_intermediates = try self.getByte();
                if (proto.n_intermediates > proto.intermediates.len) return error.Truncated;
                @memcpy(proto.intermediates[0..proto.n_intermediates], try self.take(proto.n_intermediates));
                proto.final = try self.getByte();
                const body = try self.getOwnedBytes(allocator);
                return .{ .dcs = .{ .proto = proto, .body = body } };
            },
            .child_eof => return .{ .child_eof = try self.getInt(i32) },
            .parse_error => {
                const kind = std.enums.fromInt(Event.ParseError.Kind, try self.getByte()) orelse return error.BadTag;
                return .{ .parse_error = .{ .kind = kind } };
            },
            _ => return error.BadTag,
        }
    }
};

/// Write one frame (type + payload) to a buffer: u32 len, u8 type,
/// payload. `len` covers type + payload.
pub fn appendFrame(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ftype: FrameType, payload: []const u8) !void {
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
    hdr[4] = @intFromEnum(ftype);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, payload);
}

/// Parsed frame view into the input buffer (payload not copied).
pub const Frame = struct {
    ftype: FrameType,
    payload: []const u8,
};

/// Try to split one frame off `bytes`. Returns null when incomplete.
/// On success, `consumed` is the total size to drop from the stream.
pub fn peelFrame(bytes: []const u8) error{ TooLong, Malformed }!?struct { frame: Frame, consumed: usize } {
    if (bytes.len < 5) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len == 0) return error.Malformed;
    if (len > MAX_FRAME) return error.TooLong;
    if (bytes.len < 4 + len) return null;
    return .{
        .frame = .{
            .ftype = @enumFromInt(bytes[4]),
            .payload = bytes[5 .. 4 + len],
        },
        .consumed = 4 + len,
    };
}

/// Progress of a PARTIALLY buffered frame: bytes the frame declares
/// vs bytes arrived. Null when the buffer is empty or holds a
/// complete frame — only useful for "stuck at N of M" diagnostics.
pub fn partialInfo(bytes: []const u8) ?struct { expected: usize, have: usize } {
    if (bytes.len == 0) return null;
    if (bytes.len < 5) return .{ .expected = 5, .have = bytes.len };
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (bytes.len >= 4 + @as(usize, len)) return null; // complete
    return .{ .expected = 4 + @as(usize, len), .have = bytes.len };
}

// ── tests ───────────────────────────────────────────────────────

fn roundtrip(allocator: std.mem.Allocator, ev: Event) !Event {
    var w = Writer.init(allocator);
    defer w.deinit();
    try w.putEvent(ev);
    var r = Reader.init(w.buf.items);
    const out = try r.getEvent(allocator);
    try std.testing.expect(r.atEnd());
    return out;
}

test "wire: simple events round-trip" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 0x1F600), (try roundtrip(a, .{ .print = 0x1F600 })).print);
    try std.testing.expectEqual(@as(u8, 'x'), (try roundtrip(a, .{ .print_byte = 'x' })).print_byte);
    try std.testing.expectEqual(@as(u8, 0x07), (try roundtrip(a, .{ .execute = 0x07 })).execute);
    try std.testing.expectEqual(@as(i32, 42), (try roundtrip(a, .{ .child_eof = 42 })).child_eof);

    var run: Event.PrintRun = .{};
    const txt = "hello world";
    @memcpy(run.bytes[0..txt.len], txt);
    run.len = txt.len;
    const out = try roundtrip(a, .{ .print_run = run });
    try std.testing.expectEqualStrings(txt, out.print_run.bytes[0..out.print_run.len]);
}

test "wire: csi round-trips params, sub-bits, intermediates, private" {
    const a = std.testing.allocator;
    var csi: Event.Csi = .{};
    csi.params = .{ 38, 2, 255, 128, 0 } ++ .{0} ** 11;
    csi.n_params = 5;
    csi.setSub(1, true);
    csi.setSub(2, true);
    csi.intermediates[0] = '$';
    csi.n_intermediates = 1;
    csi.private = '?';
    csi.final = 'm';
    const out = (try roundtrip(a, .{ .csi = csi })).csi;
    try std.testing.expectEqual(csi.n_params, out.n_params);
    try std.testing.expectEqualSlices(u16, csi.params[0..5], out.params[0..5]);
    try std.testing.expectEqual(csi.is_sub_bits, out.is_sub_bits);
    try std.testing.expectEqual(@as(u8, '$'), out.intermediates[0]);
    try std.testing.expectEqual(@as(u8, '?'), out.private);
    try std.testing.expectEqual(@as(u8, 'm'), out.final);
}

test "wire: owned payloads round-trip (osc / apc / dcs)" {
    const a = std.testing.allocator;

    const osc_src = try a.dupe(u8, "0;my title");
    defer a.free(osc_src);
    var osc_out = try roundtrip(a, .{ .osc = .{ .bytes = osc_src } });
    defer osc_out.deinit(a);
    try std.testing.expectEqualStrings("0;my title", osc_out.osc.bytes);

    const apc_src = try a.dupe(u8, "Gf=32,s=2,v=2;AAAA");
    defer a.free(apc_src);
    var apc_out = try roundtrip(a, .{ .apc = .{ .bytes = apc_src } });
    defer apc_out.deinit(a);
    try std.testing.expectEqualStrings("Gf=32,s=2,v=2;AAAA", apc_out.apc.bytes);

    var proto: Event.Dcs = .{};
    proto.params[0] = 1;
    proto.n_params = 1;
    proto.final = 'q';
    const body_src = try a.dupe(u8, "#0;2;0;0;0sixels");
    defer a.free(body_src);
    var dcs_out = try roundtrip(a, .{ .dcs = .{ .proto = proto, .body = body_src } });
    defer dcs_out.deinit(a);
    try std.testing.expectEqual(@as(u16, 1), dcs_out.dcs.proto.params[0]);
    try std.testing.expectEqual(@as(u8, 'q'), dcs_out.dcs.proto.final);
    try std.testing.expectEqualStrings("#0;2;0;0;0sixels", dcs_out.dcs.body);
}

test "wire: parse_error round-trips every kind" {
    const a = std.testing.allocator;
    for ([_]Event.ParseError.Kind{ .dcs_truncated, .osc_truncated, .apc_truncated }) |kind| {
        const out = try roundtrip(a, .{ .parse_error = .{ .kind = kind } });
        try std.testing.expectEqual(kind, out.parse_error.kind);
    }
    // Unknown kind byte is rejected, not panicked.
    var r = Reader.init(&[_]u8{ @intFromEnum(EventTag.parse_error), 99 });
    try std.testing.expectError(error.BadTag, r.getEvent(a));
}

test "wire: corrupt input errors, never panics" {
    const a = std.testing.allocator;
    // Unknown tag.
    var r1 = Reader.init(&[_]u8{255});
    try std.testing.expectError(error.BadTag, r1.getEvent(a));
    // Truncated CSI.
    var r2 = Reader.init(&[_]u8{ @intFromEnum(EventTag.csi), 5, 1, 0 });
    try std.testing.expectError(error.Truncated, r2.getEvent(a));
    // print_run with absurd length byte.
    var r3 = Reader.init(&[_]u8{ @intFromEnum(EventTag.print_run), 200 });
    try std.testing.expectError(error.Truncated, r3.getEvent(a));
    // OSC with length larger than buffer.
    var r4 = Reader.init(&[_]u8{ @intFromEnum(EventTag.osc), 0xFF, 0xFF, 0xFF, 0x7F });
    try std.testing.expectError(error.TooLong, r4.getEvent(a));
}

test "wire: frame peel handles partial + complete + unknown type" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendFrame(&out, a, .input, "ls\n");
    try appendFrame(&out, a, @enumFromInt(200), "future");

    // Partial: only half the first frame.
    try std.testing.expectEqual(@as(?@TypeOf((try peelFrame(out.items)).?), null), try peelFrame(out.items[0..3]));

    const p1 = (try peelFrame(out.items)).?;
    try std.testing.expectEqual(FrameType.input, p1.frame.ftype);
    try std.testing.expectEqualStrings("ls\n", p1.frame.payload);

    // Unknown frame type still peels cleanly (skippable by caller).
    const rest = out.items[p1.consumed..];
    const p2 = (try peelFrame(rest)).?;
    try std.testing.expectEqualStrings("future", p2.frame.payload);
    try std.testing.expectEqual(p1.consumed + p2.consumed, out.items.len);

    // Zero-length frame is malformed.
    const zero = [_]u8{ 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.Malformed, peelFrame(&zero));
}

test "wire: append-only frame and event values include panel RPC" {
    try std.testing.expectEqual(@as(u8, 30), @intFromEnum(FrameType.play_control));
    try std.testing.expectEqual(@as(u8, 31), @intFromEnum(FrameType.panel_request));
    try std.testing.expectEqual(@as(u8, 32), @intFromEnum(FrameType.web_op));
    try std.testing.expectEqual(@as(u8, 34), @intFromEnum(FrameType.web_helper_open));
    try std.testing.expectEqual(@as(u8, 98), @intFromEnum(FrameType.web_helper_reply));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(ChannelKind.web_helper));
    try std.testing.expectEqual(@as(u8, 64), @intFromEnum(FrameType.welcome));
    try std.testing.expectEqual(@as(u8, 94), @intFromEnum(FrameType.play_state));
    try std.testing.expectEqual(@as(u8, 95), @intFromEnum(FrameType.panel_reply));
    try std.testing.expectEqual(@as(u8, 96), @intFromEnum(FrameType.web_reply));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EventTag.print));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(EventTag.parse_error));
}

test "wire: panel envelope is little-endian, opaque, and bounded" {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try appendPanelEnvelope(&bytes, a, 0x0807060504030201, "{\"document\":\"opaque\"}");
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, bytes.items[0..8]);
    const decoded = try decodePanelEnvelope(bytes.items);
    try std.testing.expectEqual(@as(u64, 0x0807060504030201), decoded.id);
    try std.testing.expectEqualStrings("{\"document\":\"opaque\"}", decoded.json);

    try std.testing.expectError(error.Truncated, decodePanelEnvelope("short"));
    try std.testing.expectEqual(@as(?u64, null), decodePanelEnvelopeId("short"));
    try std.testing.expectError(error.EmptyJson, decodePanelEnvelope(&([_]u8{0} ** 8)));
    const too_large = try a.alloc(u8, PANEL_ENVELOPE_MAX + 1);
    defer a.free(too_large);
    try std.testing.expectError(error.TooLong, decodePanelEnvelope(too_large));
    try std.testing.expectError(error.EmptyJson, appendPanelEnvelope(&bytes, a, 1, ""));
    try std.testing.expectError(error.TooLong, appendPanelEnvelope(&bytes, a, 1, too_large));
}

test "partialInfo reports expected-vs-buffered for a half frame" {
    const t2 = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t2.allocator);
    try appendFrame(&out, t2.allocator, .events, "hello world");
    // Complete frame → null.
    try t2.expectEqual(@as(?@TypeOf(partialInfo("").?), null), partialInfo(out.items));
    // Half a frame → declared total vs buffered so far.
    const half = out.items[0 .. out.items.len - 4];
    const p = partialInfo(half).?;
    try t2.expectEqual(out.items.len, p.expected);
    try t2.expectEqual(half.len, p.have);
    // Empty buffer → null.
    try t2.expectEqual(@as(?@TypeOf(p), null), partialInfo(""));
}

test "protocol negotiation selects the highest shared historical profile" {
    try std.testing.expectEqual(@as(u32, PROTO_VERSION), negotiateProtocol(1, PROTO_VERSION + 10));
    try std.testing.expectEqual(@as(u32, 5), negotiateProtocol(3, 5));
    try std.testing.expectEqual(@as(u32, 0), negotiateProtocol(PROTO_VERSION + 1, PROTO_VERSION + 10));
    try std.testing.expectEqual(@as(u32, 0), negotiateProtocol(1, 1));
    try std.testing.expectEqual(@as(u32, 0), negotiateProtocol(1, 0));
}

// ─── control payloads ───────────────────────────────────────────
//
// JSON payload schemas of the control frames (spawn/attach/kill/…).
// They live here rather than in daemon.zig because they are part of
// the compatibility surface: a client build encodes them against a
// daemon build it did not ship with. Fields are append-only with
// defaults, exactly like frame tags.

/// Virtual Wayland output mode defaults, shared by SpawnReq/SessionInfo
/// and the wlhost compositor (which re-exports them).
pub const DEFAULT_OUTPUT_WIDTH: u32 = 1920;
pub const DEFAULT_OUTPUT_HEIGHT: u32 = 1080;

pub const SpawnReq = struct {
    name: []const u8 = "",
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    /// Extra child environment, "KEY=VALUE" strings applied after the
    /// daemon's own exports (so they win).
    env: []const []const u8 = &.{},
    rows: u16 = 24,
    cols: u16 = 80,
    /// One-shot forwarded GUI app (`sketerm app -u`), not an
    /// interactive shell — listed differently by clients.
    app: bool = false,
    /// Force the window-stream backend for this session (the
    /// explicit form of SKETERM_WINSTREAM; what `sketerm app`
    /// toward capture-only remotes will set).
    winstream: bool = false,
    /// Run the session under a private XDG_RUNTIME_DIR with the shared
    /// D-Bus session bus dropped (`sketerm app -i`). Isolates
    /// single-instance apps so each forwarded copy renders on its own
    /// client instead of coalescing into the first one.
    isolated: bool = false,
    /// GPU rendering for this session (`sketerm app --gpu`): skip the
    /// LIBGL_ALWAYS_SOFTWARE force and announce linux-dmabuf on the
    /// session's compositor. LINEAR buffers use mmap; modifier-backed
    /// buffers use runtime-loaded EGL/GLES when available.
    gpu: bool = false,
    /// Skip this session's PulseAudio hub (`launch_app audio:"none"`):
    /// PULSE_SERVER stays unset, so clients fall back to their own
    /// null/dummy audio drivers instead of sketerm's sink.
    no_audio: bool = false,
    /// Capture the session's audio to WAV on the DAEMON's host
    /// (`launch_app audio_path`): path base — the first stream lands
    /// at "<base>.wav", later ones at "<base>-N.wav". The sink still
    /// paces/forwards normally; this only tees the PCM. "" = off.
    audio_capture: []const u8 = "",
    /// GUI pane id + IPC socket to export into the child env as
    /// SKETERM_PANE_ID / SKETERM_SOCKET so `sketerm cli --pane self` works
    /// from inside a daemon-backed pane. The GUI passes its own values; they
    /// reflect the spawning client (may go stale after a cross-GUI reattach —
    /// acceptable for the common case). 0 / "" = don't export.
    pane_id: u32 = 0,
    socket: []const u8 = "",
    /// Child TERM / COLORTERM. Empty → Pty.spawn defaults. The GUI passes its
    /// profile's term_env/color_term_env so a daemon-backed local pane gets
    /// the same environment an in-process pane would.
    term: []const u8 = "",
    color_term: []const u8 = "",
    /// xkb layout for forwarded-app keyboards (wlhost/keymaps.zig
    /// names; "" = us). Must match whoever drives the seat.
    kb_layout: []const u8 = "",
    /// Spawn argv[0] as a login shell (leading `-`).
    login_shell: bool = false,
    /// GUI-owned LOCAL session sharing the user's desktop: skip the
    /// wlhost Wayland hub so child GUI apps talk to the real desktop
    /// compositor directly (via `host_wayland_display`) instead of
    /// sketerm's embedded one. Remote/durable sessions leave this
    /// false and get the forwarding hub (which roams with the
    /// session). Only the local ephemeral pane factory sets it.
    local: bool = false,
    /// The GUI's own $WAYLAND_DISPLAY, applied to the child when
    /// `local` is set — the daemon's inherited value may be stale
    /// (it outlives the GUI that started it) or absent. Empty leaves
    /// the child to inherit the daemon's env (X11 / no Wayland).
    host_wayland_display: []const u8 = "",
    /// Auto shell-integration (OSC 7/133 without rc edits). All paths are on
    /// the daemon host; the GUI only fills this for the LOCAL daemon, where
    /// the integration scripts exist. null = off.
    shell_integration: ?SpawnShellIntegration = null,
    /// External display session (`sketerm-mux display create`): the
    /// child is a trivial keeper process (this daemon's own binary,
    /// `--keep`) that just blocks, so the session exists purely to own
    /// a Wayland/PulseAudio hub some OUTSIDE process renders into. The
    /// daemon builds the keeper argv itself — a client cannot know the
    /// daemon host's binary path, and a version mismatch would be a
    /// silent instant exit. Any argv the client sent is ignored.
    display: bool = false,
    /// Rootless X11 compatibility for an external display session.
    xwayland: bool = false,
    /// Fail session creation instead of degrading to Wayland-only when the
    /// optional Xwayland runtime is unavailable or cannot start.
    require_xwayland: bool = false,
    /// Virtual Wayland output mode in physical pixels. These are separate
    /// from the keeper PTY's rows/cols and do not force a window size.
    output_width: u32 = DEFAULT_OUTPUT_WIDTH,
    output_height: u32 = DEFAULT_OUTPUT_HEIGHT,
    /// Seconds with no attached viewer or external Wayland client after
    /// which the daemon kills this session. Counted from creation when it
    /// has never been occupied. 0 = live forever.
    ttl_secs: u32 = 0,
    /// Allow `app_debug` to take a backtrace of this session's child:
    /// the child relaxes Yama's ptrace restriction before exec, because
    /// the gdb the daemon spawns is the app's SIBLING and Yama's default
    /// scope only lets ancestors trace. Set by headless automation
    /// (appdrive/MCP `launch_app`), never by interactive panes.
    debuggable: bool = false,
    /// Asciicast playback session: replay this daemon-host file
    /// (absolute or ~-relative) instead of spawning a child. argv/
    /// cwd/env are ignored; the session has NO PTY, no child process
    /// and no Wayland/audio hubs, its size comes from the cast
    /// header, and client input/resize are rejected. "" = normal
    /// PTY session.
    cast_path: []const u8 = "",
};

pub const SpawnShellIntegration = struct {
    kind: []const u8 = "", // "zsh" | "fish" | "bash"
    script: []const u8 = "",
    shim_dir: []const u8 = "",
};

pub const AttachReq = struct {
    name: []const u8 = "",
    /// Optional lifetime fence: current panel clients send the inherited ID so
    /// a reused name can never attach them to a replacement session.
    origin_id: []const u8 = "",
    /// Client self-identification for the peer roster: "gui", "cli",
    /// "mcp" (headless assistant driver) or "" (unknown).
    kind: []const u8 = "",
    /// Never drive the session's Wayland seat: this viewer stays out of
    /// the controller lease entirely (it neither acquires a free lease
    /// nor is eligible for the controller-death handover).
    read_only: bool = false,
    /// Force the controller lease on attach, evicting whoever holds it.
    /// Without this an attach only acquires a FREE lease.
    control: bool = false,
    /// Attach for correlated panel RPC only: no snapshot, terminal events,
    /// native channels, audio, controller lease, or viewer occupancy.
    panel_only: bool = false,
    /// Panel presenter/requester capability for this attachment. It is
    /// clamped to the independently negotiated hello capability.
    panel_rpc: u8 = 0,
    /// Request identity metadata before the initial snapshot. Honored only for
    /// panel-capable GUI attachments, preserving legacy snapshot-first order.
    identity_first: bool = false,
};

pub const KillReq = struct {
    name: []const u8 = "",
    /// Display CLI safety fence: never let `display destroy` kill a shell
    /// session that happens to share the requested name.
    require_display: bool = false,
    /// Optional identity fence used by display teardown. A name can be
    /// destroyed and reused between list/create and kill; never kill the
    /// replacement when either expected value no longer matches.
    expected_pid: i32 = 0,
    expected_wl_display: []const u8 = "",
};

/// `control_req` payload. Unknown ops are ignored (append-only).
pub const ControlReq = struct {
    op: []const u8 = "",
};

/// `log_get` request. Exactly one selector applies, in this order:
/// `id` (one line, full bytes) > `from_id` (up to 500 lines from that
/// id) > `tail` (last N lines). `max_chars` bounds each line in the
/// reply (0 = full stored bytes).
pub const LogGetReq = struct {
    tail: u32 = 100,
    from_id: u64 = 0,
    id: u64 = 0,
    max_chars: u32 = 300,
    /// Echoed in the reply header (when nonzero) so a client can match
    /// replies to requests — a reply buried behind a frame backlog can
    /// surface during a LATER request's wait.
    nonce: u64 = 0,
};

pub const RenameReq = struct {
    name: []const u8 = "",
    new_name: []const u8 = "",
};

/// Bounded per-stream audio identity reported by a session's internal
/// PulseAudio server (re-exported by pulse.zig, which fills it).
pub const AudioInfo = struct {
    application: []const u8 = "",
    binary: []const u8 = "",
    media: []const u8 = "",
    icon: []const u8 = "",
    pid: u32 = 0,
    running: bool = false,
};

pub const SessionInfo = struct {
    name: []const u8,
    /// Immutable spawn-time name retained as display/legacy metadata. It may
    /// remain an attach alias after `name` changes, but is not persistence
    /// identity because a later same-name session can reuse it.
    origin_name: []const u8 = "",
    /// Lifetime-unique immutable persistence identity. Added compatibly: old
    /// clients ignore it and old daemons omit it.
    origin_id: []const u8 = "",
    rows: u16,
    cols: u16,
    clients: u32,
    exited: bool,
    title: []const u8 = "",
    app: bool = false,
    /// Milliseconds since this session last produced output, computed on the
    /// daemon's own clock at list time (never a client-vs-daemon timestamp
    /// diff — a remote daemon's monotonic clock differs from the caller's).
    idle_ms: i64 = 0,
    /// Child's current working directory (from /proc, daemon-resolved). Empty
    /// if unavailable. Lets `list` show it and gives layout-save a cwd source
    /// for daemon-backed panes (which have no local pid).
    cwd: []const u8 = "",
    /// The session child's pid ON THE DAEMON'S HOST (0 = unknown). For a
    /// string-command spawn this is the wrapping `/bin/sh`, not the app.
    pid: i32 = 0,
    /// An uncorked audio stream is playing right now — how a viewer finds
    /// WHICH session is making sound without attaching to each in turn.
    audio: bool = false,
    /// Bounded per-stream identities reported by the session's internal
    /// PulseAudio server. Empty when an older daemon has only `audio`.
    audio_streams: []const AudioInfo = &.{},
    /// External display session (`display create`) — its child is the
    /// keeper, so the "terminal" is meaningless; what matters is the
    /// environment below.
    display: bool = false,
    xwayland: bool = false,
    x_display: []const u8 = "",
    xauthority: []const u8 = "",
    gpu: bool = false,
    output_width: u32 = DEFAULT_OUTPUT_WIDTH,
    output_height: u32 = DEFAULT_OUTPUT_HEIGHT,
    /// Absolute path of the session's Wayland display socket, its
    /// PULSE_SERVER value and its private runtime dir (empty = none).
    /// An external renderer needs these and must never guess them.
    wl_display: []const u8 = "",
    pulse_server: []const u8 = "",
    runtime_dir: []const u8 = "",
    /// No-viewer TTL in seconds (0 = none).
    ttl_secs: u32 = 0,
    /// Attached viewers, and a label for the one holding the controller
    /// lease ("" = nobody). The label is "<kind>#<client id>" — stable
    /// for the life of the connection, meaningless across daemons.
    viewers: u32 = 0,
    controller: []const u8 = "",
};
