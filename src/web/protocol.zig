//! sketerm-web wire protocol v1: framing plus payload (de)serialization.
//!
//! THE compatibility surface between the GUI and a browser helper, and
//! deliberately engine-agnostic: no CEF type, id or enum may ever appear
//! here, so a future Servo/Ladybird helper can speak it unchanged. Rules
//! (same as src/mux/wire.zig, whose discipline this follows):
//!   - little-endian, length-prefixed frames and payloads
//!   - tag values are APPEND-ONLY; readers skip unknown frames
//!   - optional features are new frames gated by capabilities, never a
//!     version bump
//!
//! Pure code: std only, no CEF, no GTK, no sockets. Unit-tested headless
//! in both test roots.

const std = @import("std");

/// Protocol revision carried by `hello`/`hello_ack`.
pub const PROTO_VERSION: u32 = 1;

/// Capabilities a v1 helper advertises. Reserved-but-unimplemented
/// names live in docs/proposal-browser-protocol.md, not here.
pub const CAP_FRAMES_SHM = "frames-shm";
/// Frames delivered as dma-buf planes (`frame_dmabuf`) instead of a
/// memfd of pixels. Advertised only when the helper actually got a GPU
/// process; a client must keep handling `frame_damage` regardless,
/// because the engine falls back to software compositing on its own.
pub const CAP_FRAMES_DMABUF = "frames-dmabuf";
pub const CAP_INPUT = "input";
pub const CAP_NAVIGATION = "navigation";
pub const CAP_SEMANTIC = "semantic";
/// The helper accepts `view_create_url`: a view created directly AT a
/// url, so no blank document is ever minted for it. A client without
/// this capability keeps using `view_create` + `navigate`, which mints
/// two documents (about:blank, then the page) and lets a settle that
/// watches "some url loaded" answer for the blank one.
pub const CAP_VIEW_CREATE_URL = "view-create-url";
/// The helper accepts `view_discard`: a view whose browser is destroyed
/// outright while its ID and address survive, revived on the next
/// `view_show`, navigation or input. A client without this capability
/// keeps sending `view_hide`, which only stops the painting.
pub const CAP_DISCARD = "discard";
/// The helper accepts `devtools_show`: the engine's own inspector,
/// opened as ANOTHER windowless view the client presents like any
/// other. No remote debugging port is ever opened.
pub const CAP_DEVTOOLS = "devtools";
/// The helper accepts `print_pdf`: render a view to a PDF file at a
/// path IT can write (helper and client are the same machine in v1).
pub const CAP_PRINT_PDF = "print-pdf";
/// The helper accepts `input_paste` and `clipboard_read`, and answers
/// the latter with `ev_clipboard_text`.
///
/// The client owns the system clipboard and the helper owns insertion,
/// because a windowless browser's own `ui::Clipboard` is not backed by
/// the session selection in any configuration this product reaches, and
/// CEF's C API exposes no clipboard read or write to prime it with.
/// Without this the engine runs a real Paste against an empty clipboard
/// — which not only inserts nothing but REPLACES the selection, so
/// select-all then paste wipes the field.
///
/// Note what it puts on the wire: a `route on:<host>` connection carries
/// clipboard text to a REMOTE helper, the same reach the cookie-sync
/// block below documents for cookies.
pub const CAP_CLIPBOARD = "clipboard";
/// The helper accepts `find`/`find_stop` and answers with
/// `ev_find_result`.
pub const CAP_FIND = "find";
/// The helper accepts `set_zoom` (user zoom, on top of any DPR zoom).
pub const CAP_ZOOM = "zoom";
/// The helper suppresses the engine's own context menu and posts
/// `ev_context_menu` instead.
pub const CAP_CONTEXT_MENU = "context-menu";
/// The helper runs an in-process network filter engine and accepts the
/// 0x80-block interception frames. Blocking decisions NEVER round-trip
/// to the client — the client only configures, polls the bounded
/// request log, and receives coalesced per-view counters.
pub const CAP_INTERCEPT = "intercept";
/// The helper enforces per-view network POLICY (0x86 block): host
/// allow-lists, scheme/type masks, private-address refusal and budgets
/// (requests/bytes/navigations/deadline), decided inline in
/// `on_before_resource_load` before a request leaves the process. A
/// `net_policy_set` must arrive BEFORE the `view_create*` naming the
/// view (frame order is the guarantee; there is no ack) — a client on a
/// helper without this capability REFUSES a policied open rather than
/// opening an unpoliced view.
pub const CAP_NET_POLICY = "net-policy";
/// The helper can REALLY open a popup — a child browser that keeps its
/// `window.opener` relationship — instead of cancelling it and asking
/// the client to open an unrelated tab.
///
/// It exists because an opener is not cosmetic: OAuth and federated
/// sign-in deliver their result with `window.opener.postMessage`, so a
/// cancelled popup makes the whole flow throw at the last step. And the
/// cancel is visible earlier too — `window.open` evaluating to null is
/// what makes a page take its popup-blocked fallback and ask twice.
///
/// Blocking therefore has to become state the client PUSHES ahead of
/// time (`popup_policy_set`), never a round trip: `on_before_popup` is
/// synchronous and cannot wait for an answer. The default is BLOCK, so
/// a client that never pushes gets the old behaviour byte for byte.
pub const CAP_POPUP_OPEN = "popup-open";
/// The helper reports certificate errors as `ev_cert_error` and waits
/// for a `cert_decision` instead of failing the load. A client without
/// it sees only the generic `ev_load_error` an older helper produced,
/// which is exactly the pre-interstitial behaviour.
pub const CAP_TLS = "tls";
/// The helper hands permission prompts to the client (`ev_permission` /
/// `permission_decision`) instead of letting the engine's default
/// handling deny them.
pub const CAP_PERMISSIONS = "permissions";
/// The helper reports file downloads: an `ev_download_offer` HOLDS the
/// engine's target decision until a `download_decide` answers it, then
/// coalesced `ev_download_progress` frames follow, and a
/// `download_cancel` aborts a running one. A client without it never
/// sees a download at all (the engine cancels them without a handler),
/// which is the pre-downloads behaviour.
pub const CAP_DOWNLOADS = "downloads";
/// The helper accepts `download_start`: the client asks for a URL to be
/// downloaded THROUGH the view's own browser (its cookies, its session,
/// its route), and the resulting `ev_download_offer` carries the
/// client's `req` back so the answer can be routed to the caller that
/// asked. Without it a client can only observe downloads a page starts.
pub const CAP_DOWNLOAD_START = "download-start";
/// Helper-owned staging for downloads whose destination is on another host.
pub const CAP_DOWNLOAD_STAGING = "download-staging";
pub const CAP_DOWNLOAD_ERRORS = "download-errors";
/// The helper accepts `a11y_enable` and, for a view it was enabled on,
/// streams the engine's accessibility tree as `ev_a11y_tree` /
/// `ev_a11y_loc` / `ev_a11y_event` frames (the 0x70 block). Nothing is
/// streamed for a view that never asked: engine-side accessibility is
/// not free, and an unsolicited stream would break the backlog rule.
pub const CAP_A11Y = "a11y";
/// The helper additionally streams `ev_a11y_caret` for an a11y-enabled
/// view: the document's caret and selection endpoints, which the
/// read-only tree cannot express. A client without it projects no
/// `org.a11y.atspi.Text` caret and a braille display cannot follow the
/// cursor; nothing else degrades. Rides the same `a11y_enable` gate —
/// there is no separate enable, so an old CLIENT simply skips the tag.
pub const CAP_A11Y_CARET = "a11y-caret";
/// The helper accepts the 0xC0 user-content frames: `us_script_set`
/// (userscripts, raw source with a `==UserScript==` block, injected
/// per navigation by run-at) and `us_style_set` (per-site user CSS,
/// applied instantly to live matching views AND at every navigation).
/// Both are REPLACE-ALL sets, so a client re-sends the whole enabled
/// set after any edit and the helper holds no partial state. An older
/// helper skips the frames and pages simply get no user content.
pub const CAP_USERSCRIPTS = "userscripts";
/// The helper accepts `context_create`/`context_destroy`: per-tab
/// identity contexts (separate cookie jars / caches), each optionally
/// pointed at a proxy. A view's `context` field then selects one
/// (0 = the shared default context). A client without this capability
/// keeps sending `context = 0` and every view shares one jar.
pub const CAP_CONTEXTS = "contexts";
/// The helper creates proxied contexts transactionally and refuses a view
/// whose nonzero context does not exist, reporting `ev_view_create_failed`.
/// Egress clients require this in addition to `CAP_CONTEXTS`; an older helper
/// may otherwise resolve a failed or unknown context through the direct global
/// request context.
pub const CAP_CONTEXTS_FAIL_CLOSED = "contexts-fail-closed";
/// The helper accepts the 0xC8-block site-data frames: enumerate the
/// cookies a site can see (`cookies_req` -> `ev_cookies`), delete one
/// (`cookie_delete`), clear them all (`cookies_clear`), and clear the
/// origin's storage (`sitedata_clear`), each answered by
/// `ev_sitedata_done`. Everything is scoped to the VIEW, so the work
/// lands in that view's container/request context and never in the
/// shared jar. A client without this capability shows no cookie or
/// site-data section at all — there is nothing it could ask.
///
/// COOKIE VALUES NEVER CROSS THE WIRE. The enumeration carries names,
/// scopes, flags and the value's LENGTH, which is what a site-data
/// panel displays; shipping the values themselves would put every
/// session token of every open tab into the GUI's address space for a
/// panel that never renders them.
pub const CAP_SITEDATA = "sitedata";

/// The helper answers `flush_req` with `ev_flushed` after forcing every
/// persistent context's cookies/storage to disk, and flushes them on a
/// periodic cadence of its own while it lingers past its last client.
pub const CAP_FLUSH = "flush-store";

/// The helper reports `ev_scroll` and accepts `scroll_to` (0xC2 block),
/// which is what lets session restore put a page back where it was.
pub const CAP_SCROLL = "scroll";
/// The helper fetches subscribed filter lists itself (0xC4).
pub const CAP_FILTER_SUBSCRIBE = "filter-subscribe";

/// The helper accepts `frame_mode` and, in inline mode, delivers frames
/// as `frame_inline` pixel payloads ON the protocol socket itself — no
/// memfd, no dma-buf, no SCM_RIGHTS. This is the frame family a REMOTE
/// helper uses: the socket may be bridged over a mux connection where a
/// descriptor cannot travel. A client that needs inline frames and does
/// not see this capability must fail loudly (an old helper would keep
/// posting `frame_buffer` frames whose descriptors were silently eaten
/// by the bridge, i.e. a black pane forever).
pub const CAP_FRAMES_INLINE = "frames-inline";
/// The helper hosts MV2-flavor WebExtensions: it accepts the 0xB0-block
/// frames (`webext_set`/`webext_remove`/`webext_list_req`), loads an
/// unpacked extension directory, runs its background scripts in a hidden
/// off-screen page, injects its content scripts into matching pages
/// through a per-extension isolated bridge, and bridges the `browser.*`
/// promise API (runtime/storage/tabs/i18n). It reports each extension's
/// state as `ev_webext_state`. A client without this capability never
/// loads an extension and the helper hosts none.
pub const CAP_WEBEXT = "webext";

/// The helper accepts `webext_tabs` (0xB6): the client's whole tab list,
/// which is what makes `browser.tabs` and `sender.tab` real instead of
/// empty. Separate from `webext` because a client that hosts extensions
/// need not own a tab set at all (`webdrive` does not), and an extension
/// seeing NO tabs is honest where seeing invented ones is not.
pub const CAP_WEBEXT_TABS = "webext-tabs";

/// The helper accepts `sem_read_ids` and answers with
/// `sem_read_ids_result`: reader-mode markdown plus structured entities
/// whose stable ids belong to the same semantic space as `sem_act`.
/// `sem_act_guarded` additionally requires the document generation and
/// revision from that result, so stale reader output is refused instead
/// of being resolved against a later page. A client without this
/// capability keeps using the legacy `sem_read` / `sem_read_result` pair.
pub const CAP_READER_IDS = "reader-ids";
pub const CAP_REVIEW = "review";
/// The helper accepts `sem_request`, which wraps one existing semantic
/// request with a client-minted id, and answers with a correlated
/// `sem_result`. Existing semantic frame layouts remain unchanged.
pub const CAP_SEMANTIC_REQUEST_IDS = "semantic-request-ids";
/// The helper reports the enabled browser actions for the active page,
/// accepts trusted toolbar activations, and presents declared popups as
/// dedicated extension-page views (0xB7-0xB9).
pub const CAP_WEBEXT_ACTION = "webext-action";
/// The helper validates and quiesces an extension before the GUI swaps its
/// staged package, then returns a correlated result after loading the commit.
pub const CAP_WEBEXT_TRANSACTION = "webext-transaction";
/// The helper serves several concurrent clients on one socket: each
/// connection keeps its own view/context id namespace and its own
/// outbound queue, view-scoped events reach only the connection that
/// owns the view, and the engine exits when the LAST client leaves.
/// Without this capability the helper serves exactly one client and
/// exits when it disconnects.
pub const CAP_MULTI_CLIENT = "multi-client";
/// The helper presents every OSR view as a Wayland toplevel on the
/// session hub it was started against (`src/web/presenter.zig`), so an
/// attached viewer sees the assistant's pages and can drive them.
/// Advertised only when the presenter actually came up; a client never
/// infers it from `WAYLAND_DISPLAY` or session mode.
pub const CAP_PRESENTER = "presenter";
/// The environment variable that arms the presenter in a helper; only
/// a launcher that started the helper as a hub's client may set it.
pub const CAP_PRESENTER_ENV = "SKETERM_WEB_PRESENTER";

/// Cross-instance cookie SYNCHRONISATION (0xE0 block).
///
/// sketerm runs one helper process per network route, each with its
/// own profile directory and therefore its own cookie jar. A login
/// must nevertheless follow the user between routes, so one helper
/// OBSERVES its jar changing and the client fans the change out to the
/// others, which APPLY it.
///
/// This is the one block on this wire that carries cookie VALUES, and
/// it is a deliberate contrast with the 0xC8 `sitedata` block, which
/// never does: a site-data PANEL needs names and scopes, while a jar
/// REPLICA is worthless without the value. The value is why the
/// capability is separate and why nothing streams before
/// `cookie_sync_enable` — a client that does not synchronise jars
/// never has a cookie value cross its socket.
///
/// Three verbs plus one event: subscribe (`cookie_sync_enable` ->
/// `ev_cookie_change`), apply one cookie (`cookie_apply` ->
/// `ev_cookie_apply_done`), and seed a fresh instance from a running
/// one (`cookie_dump_req` -> paged `ev_cookie_dump`).
pub const CAP_COOKIE_SYNC = "cookie-sync";

/// Cross-connection view OBSERVATION (0xF0 block).
///
/// Under `multi-client` a view is owner-scoped: its events reach the
/// connection that created it and nobody else. This block lets another
/// connection of the SAME helper watch, and optionally drive, a view it
/// does not own — how a GUI shows an assistant's pages as ordinary
/// browser pages, as a second client of the assistant's own helper.
///
/// `observe_enable` turns on announcements: one `ev_observe_view` per
/// presentable page of every OTHER connection (url, title, geometry,
/// owner), then one per page created or destroyed from there on.
/// `observe_subscribe` names one announced view by its `target` (the
/// engine-global id the announcement carried) and an observer-minted
/// `view` id in the observer's own namespace; from the acknowledging
/// `ev_observe_state` onward the observer receives that view's frames
/// and events under ITS id, exactly as if it were the observer's own
/// view. Frames for an observed view are ALWAYS `frame_inline`, whatever
/// frame family the observer's own views use: nothing to share a memfd
/// or dma-buf with, and identical over a bridged remote helper.
///
/// An observer may send `frame_request`, `view_show`/`view_hide` (its
/// own pause; the owner's view keeps painting) and `view_destroy` (an
/// UNSUBSCRIBE, never a destroy) for its alias. Input, navigation, find
/// and scrolling need `control = 1`, asked at subscribe time or flipped
/// with `observe_control`; a read-only observer's input is DROPPED
/// helper-side. Everything else (resize, discard, zoom, contexts,
/// semantic, a11y, devtools, ...) is refused for an alias regardless:
/// geometry and identity belong to the owner. `observerAllows` is the
/// one home for that gate.
///
/// The owner never learns of observers. A view the owner destroys ends
/// every subscription with `ev_observe_state{state = ended}`; an
/// observer disconnecting leaves the owner's views untouched.
pub const CAP_OBSERVE = "observe";
/// The helper re-issues a main-frame load ONCE when it fails with
/// `ERR_NETWORK_CHANGED` (the local interface list changed under the
/// engine: a container starting, a VPN coming up) and reports that as
/// `ev_load_retry` instead of `ev_load_error`; the retried load's own
/// failure is reported as the ordinary error. Without this capability
/// every such blink is an `ev_load_error` the client has to retry
/// itself. `web/loadretry.zig` is the rule.
pub const CAP_LOAD_RETRY = "load-retry";

/// Per-connection id window under `multi-client`: connection k owns
/// client-minted view ids translated into globals by adding
/// `k * CONN_ID_WINDOW`, so two clients both minting id 1 never
/// collide. Client-minted ids must stay below the window; ids at or
/// above `ENGINE_VIEW_BASE` are engine-minted and pass through
/// untranslated. Wire-adjacent for the same reason MAX_POLICY_VIEWS
/// is: both sides size their refusals from it.
pub const CONN_ID_WINDOW: u32 = 0x0010_0000;

/// The context id space is PARTITIONED, not windowed: ids below this
/// line are persisted profile ids allocated by ONE store per engine
/// (the broker's, or the single flock holder's), so they form a SHARED
/// namespace — two connections publishing the same persisted id mean
/// the same identity context, which is exactly how two clients share a
/// named profile's live session. Ids at or above it are ephemeral,
/// minted client-locally and translated per connection like view ids.
/// `webprofiles.EPHEMERAL_BASE` derives from this constant; the jar
/// directory `profile-<name>-<id>` carries the persisted id verbatim,
/// which is why it must never be window-shifted.
pub const EPHEMERAL_CTX_BASE: u32 = 0x4000_0000;

/// Refuse to buffer a frame larger than this; a peer claiming more is
/// desynchronised, not ambitious.
pub const MAX_FRAME: u32 = 16 * 1024 * 1024;

/// Largest `sem_eval_result` JSON a helper will frame — `MAX_FRAME`
/// with room for the payload wrapper and the `sem_result` envelope. A
/// result past it is answered as an ERROR naming its size, never
/// dropped: an unframeable reply that is silently discarded costs the
/// caller its whole 120s deadline and reports nothing.
pub const MAX_EVAL_JSON: usize = MAX_FRAME - (1 << 20);

/// Ceiling on `SemEval.max_str`, the per-string serialization budget.
/// Well under `MAX_EVAL_JSON` so a single maximal string still frames
/// after JSON escaping.
pub const MAX_EVAL_STR: u32 = 4 * 1024 * 1024;

/// Frame tags, allocated in per-family blocks (see the spec's reserved
/// ranges). Non-exhaustive because an unknown tag must be a value, not
/// a decode failure.
pub const Tag = enum(u8) {
    hello = 0x01,
    hello_ack = 0x02,
    view_create = 0x10,
    view_destroy = 0x11,
    view_resize = 0x12,
    view_show = 0x13,
    view_hide = 0x14,
    view_max_fps = 0x15,
    view_create_url = 0x16,
    view_discard = 0x17,
    navigate = 0x18,
    nav_action = 0x19,
    input_pointer = 0x20,
    input_scroll = 0x21,
    input_key = 0x22,
    input_ime = 0x23,
    input_focus = 0x24,
    input_paste = 0x25,
    clipboard_read = 0x26,
    ev_clipboard_text = 0x27,
    frame_buffer = 0x30,
    frame_damage = 0x31,
    frame_release = 0x32,
    frame_request = 0x33,
    frame_dmabuf = 0x34,
    ev_load = 0x40,
    ev_load_error = 0x41,
    ev_title = 0x42,
    ev_favicon = 0x43,
    ev_nav_state = 0x44,
    ev_popup_request = 0x45,
    ev_cursor = 0x46,
    ev_console = 0x47,
    ev_crashed = 0x48,
    popup_policy_set = 0x49,
    ev_page_popup = 0x4A,
    ev_load_retry = 0x4B,
    find = 0x50,
    find_stop = 0x51,
    set_zoom = 0x52,
    ev_find_result = 0x53,
    ev_context_menu = 0x54,
    ev_cert_error = 0x55,
    cert_decision = 0x56,
    ev_permission = 0x57,
    permission_decision = 0x58,
    sem_snapshot_req = 0x60,
    sem_snapshot = 0x61,
    sem_act = 0x62,
    sem_act_result = 0x63,
    sem_expand = 0x64,
    sem_expand_result = 0x65,
    sem_query = 0x66,
    sem_query_result = 0x67,
    sem_read = 0x68,
    sem_read_result = 0x69,
    // Append-only continuation of the semantic family, capability
    // "reader-ids". 0x6A was deliberately left free when sem_eval was
    // placed in the 0xA0 debugging block.
    sem_read_ids = 0x6A,
    sem_read_ids_result = 0x6B,
    sem_act_guarded = 0x6C,
    sem_request = 0x6D,
    sem_result = 0x6E,
    a11y_enable = 0x70,
    ev_a11y_tree = 0x71,
    ev_a11y_loc = 0x72,
    ev_a11y_event = 0x73,
    ev_a11y_caret = 0x76,
    ev_download_offer = 0x78,
    download_decide = 0x79,
    ev_download_progress = 0x7A,
    download_cancel = 0x7B,
    download_start = 0x7C,
    intercept_set = 0x80,
    intercept_lists = 0x81,
    intercept_status_req = 0x82,
    intercept_status = 0x83,
    intercept_log_req = 0x84,
    intercept_log = 0x85,
    net_policy_set = 0x86,
    net_policy_req = 0x87,
    ev_net_policy = 0x88,
    net_log_req = 0x89,
    net_log = 0x8A,
    context_create = 0x90,
    context_destroy = 0x91,
    ev_view_create_failed = 0x92,
    sem_eval = 0xA0,
    sem_eval_result = 0xA1,
    devtools_show = 0xA2,
    ev_devtools_view = 0xA3,
    print_pdf = 0xA4,
    ev_print_pdf_done = 0xA5,
    webext_set = 0xB0,
    webext_remove = 0xB1,
    webext_list_req = 0xB2,
    ev_webext_state = 0xB3,
    webext_wreq_stats_req = 0xB4,
    ev_webext_wreq_stats = 0xB5,
    webext_tabs = 0xB6,
    ev_webext_actions = 0xB7,
    webext_action_activate = 0xB8,
    ev_webext_popup = 0xB9,
    ev_webext_open_popup = 0xBA,
    webext_open_popup_result = 0xBB,
    webext_install_prepare = 0xBC,
    ev_webext_install_prepared = 0xBD,
    webext_install_commit = 0xBE,
    ev_webext_install_committed = 0xBF,
    //
    // NOTE for anyone reading the 0xB4-0xBF reservation as originally
    // written: there is deliberately NO `webext_request` /
    // `webext_request_decision` pair on this wire. A blocking
    // webRequest decision is answered by the extension's BACKGROUND
    // PAGE, which is a hidden windowless browser INSIDE the helper —
    // the round trip is browser-process -> renderer -> back and never
    // leaves the process, so routing it out to the GUI and back would
    // add a socket hop, a GUI main-loop turn and a whole new "the
    // client died mid-decision" failure mode to the latency-critical
    // path. What DOES cross the wire is observability only: the client
    // asks for counters and gets them.
    us_script_set = 0xC0,
    us_style_set = 0xC1,
    ev_scroll = 0xC2,
    scroll_to = 0xC3,
    intercept_subscribe = 0xC4,
    ev_intercept_subscribe_done = 0xC5,
    cookies_req = 0xC8,
    ev_cookies = 0xC9,
    cookie_delete = 0xCA,
    cookies_clear = 0xCB,
    sitedata_clear = 0xCC,
    ev_sitedata_done = 0xCD,
    flush_req = 0xCE,
    ev_flushed = 0xCF,
    // 0xD0-0xD7: inline (in-band) frame family, capability
    // "frames-inline" — the historically reserved remote-helper block.
    frame_mode = 0xD0,
    frame_inline = 0xD1,
    // 0xE0-0xE7: cross-instance cookie synchronisation, capability
    // "cookie-sync". A fresh block rather than a 0xC8 continuation:
    // 0xC6/0xC7 are the only gaps left in the 0xC0 block and the
    // family needs six, and these frames carry cookie VALUES while
    // every 0xC8 frame deliberately does not.
    cookie_sync_enable = 0xE0,
    ev_cookie_change = 0xE1,
    cookie_apply = 0xE2,
    ev_cookie_apply_done = 0xE3,
    cookie_dump_req = 0xE4,
    ev_cookie_dump = 0xE5,
    // 0xF0-0xF7: cross-connection view observation, capability
    // "observe" (see CAP_OBSERVE).
    observe_enable = 0xF0,
    ev_observe_view = 0xF1,
    observe_subscribe = 0xF2,
    ev_observe_state = 0xF3,
    observe_control = 0xF4,
    _,

    /// Whether this build knows the frame; unknown tags are skipped.
    pub fn known(self: Tag) bool {
        return switch (self) {
            _ => false,
            else => true,
        };
    }
};

/// The observer gate (capability "observe"): which client frames a
/// connection may send for a view it only OBSERVES. `control` is the
/// subscription's lease. Frames absent here are dropped for an alias,
/// whatever the lease — geometry, identity, discard, the semantic and
/// a11y families and the engine chrome all belong to the owner. The
/// observe family's own frames are not listed: `observe_subscribe`
/// mints the alias and `observe_control` addresses it directly.
pub fn observerAllows(tag: Tag, control: bool) bool {
    return switch (tag) {
        // Any observer: its own pacing, pause and unsubscribe.
        .frame_request, .frame_release, .view_show, .view_hide, .view_destroy => true,
        // A controlling observer drives the page as the owner would.
        .input_pointer,
        .input_scroll,
        .input_key,
        .input_ime,
        .input_paste,
        .input_focus,
        .clipboard_read,
        .navigate,
        .nav_action,
        .find,
        .find_stop,
        .scroll_to,
        => control,
        else => false,
    };
}

test "observerAllows: read-only observers pace and pause, control drives, geometry stays the owner's" {
    try std.testing.expect(observerAllows(.frame_request, false));
    try std.testing.expect(observerAllows(.view_destroy, false));
    try std.testing.expect(!observerAllows(.input_pointer, false));
    try std.testing.expect(!observerAllows(.navigate, false));
    try std.testing.expect(observerAllows(.input_pointer, true));
    try std.testing.expect(observerAllows(.input_key, true));
    try std.testing.expect(observerAllows(.navigate, true));
    try std.testing.expect(observerAllows(.find, true));
    // Never, whatever the lease.
    try std.testing.expect(!observerAllows(.view_resize, true));
    try std.testing.expect(!observerAllows(.view_discard, true));
    try std.testing.expect(!observerAllows(.set_zoom, true));
    try std.testing.expect(!observerAllows(.sem_snapshot_req, true));
    try std.testing.expect(!observerAllows(.a11y_enable, true));
    try std.testing.expect(!observerAllows(.devtools_show, true));
    try std.testing.expect(!observerAllows(.cert_decision, true));
}

/// `nav_action` action byte.
pub const NavAct = enum(u8) {
    back = 0,
    forward = 1,
    reload = 2,
    stop = 3,
    reload_no_cache = 4,
    _,
};

/// `input_pointer` kind byte.
pub const PointerKind = enum(u8) { move = 0, down = 1, up = 2, leave = 3, _ };

/// `input_key` kind byte.
pub const KeyKind = enum(u8) { down = 0, up = 1, _ };

/// `input_ime` kind byte.
pub const ImeKind = enum(u8) { compose = 0, commit = 1, cancel = 2, _ };

/// `ev_load` state byte.
pub const LoadState = enum(u8) { started = 0, committed = 1, finished = 2, failed = 3 };

/// `ev_popup_request` disposition byte.
pub const Disposition = enum(u8) { new_tab = 0, new_window = 1, popup = 2 };

/// `ev_cursor` cursor byte: a deliberately small CSS-cursor subset;
/// anything else resolves to `default`.
pub const Cursor = enum(u8) {
    default = 0,
    pointer = 1,
    text = 2,
    wait = 3,
    crosshair = 4,
    not_allowed = 5,
    grab = 6,
    grabbing = 7,
    ew_resize = 8,
    ns_resize = 9,
};

/// Modifier bits shared by every input frame.
pub const mod_shift: u32 = 1;
pub const mod_ctrl: u32 = 2;
pub const mod_alt: u32 = 4;
pub const mod_super: u32 = 8;
pub const mod_capslock: u32 = 16;
pub const mod_numlock: u32 = 32;

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

/// A u32-length payload, distinct from a `str` (u16) because a semantic
/// snapshot of a real page routinely exceeds 64KB. Wrapped in a struct
/// so the generic encoder can tell the two apart by field TYPE.
pub const Text = struct { s: []const u8 };

/// `sem_snapshot_req` mode byte (append-only values).
///
/// `auto` answers with ONE coalesced delta from the tree as the client
/// last CONSUMED it straight to the current tree — spontaneous
/// mutations are folded helper-side and never pushed, so intermediate
/// churn cancels out. `full` restates the whole tree. `history` opts
/// back into the per-revision replay of every fold since the last
/// consume (bounded helper-side), for debugging pages whose changes
/// appear and vanish between snapshots. `peek` folds a fresh walk and
/// answers with the revision ONLY — nothing is consumed, so a wait that
/// polls the page cannot silently eat the delta the client is owed.
pub const SnapMode = enum(u8) { auto = 0, full = 1, history = 2, peek = 3, _ };

/// `sem_snapshot_req` detail byte.
pub const SnapDetail = enum(u8) { minimal = 0, normal = 1, full_text = 2, _ };

/// `sem_snapshot` kind byte; mirrors `semantic.Kind`.
pub const SnapKind = enum(u8) { full = 0, delta = 1, _ };

/// `sem_act` action byte. `click` and `hover` are synthesized through
/// the ORDINARY input path at the element centre, never scripted, so
/// the page sees `isTrusted`.
pub const SemAct = enum(u8) {
    click = 0,
    focus = 1,
    set_value = 2,
    scroll_into_view = 3,
    hover = 4,
    _,
};

/// `sem_query` kind byte (append-only values).
///
/// `visible` is the link-hints request: `arg` is "<vw> <vh>" (logical
/// px), and unlike the other kinds the helper answers it AFTER a fresh
/// DOM walk — hint rects must reflect the current scroll position,
/// which mutation observation alone never sees. The reply payload is
/// the tab-separated format of `semantic.View.renderHints`; the walk
/// folds into the live tree and deliberately does NOT advance the
/// consumed base.
/// `within_text` (capability-free: an older helper answers an unknown
/// kind with the find_text arm, whose header a client can tell apart)
/// takes a JSON `{text, name, role}` argument and answers the
/// candidates named `name` under the smallest node whose subtree also
/// contains `text` — "the Edit button in the row that says 10.47.1.106".
pub const SemQuery = enum(u8) {
    find_text = 0,
    subtree = 1,
    focused = 2,
    visible = 3,
    within_text = 4,
    /// Every form control in the live tree (optionally under the node
    /// id in the argument) with its value and states: what Apply would
    /// submit, without a DOM script.
    form = 5,
    /// Bounded live DOM review; JSON options and JSON result, no snapshot base consumed.
    review = 6,
    _,

    /// The kinds a client may name in a request, read off this enum so
    /// a new kind is one edit here. `visible` is the hints walk and
    /// stays behind its own tool.
    pub fn fromName(name: []const u8) ?SemQuery {
        const qk = fromOperationName(name) orelse return null;
        return if (qk == .review) null else qk;
    }

    /// Internal review orchestration uses the query transport, not the public
    /// web_query vocabulary (whose results describe the cached semantic tree).
    pub fn fromOperationName(name: []const u8) ?SemQuery {
        const qk = std.meta.stringToEnum(SemQuery, name) orelse return null;
        return if (qk == .visible) null else qk;
    }
};

test "SemQuery.fromName reads the enum and withholds the hints walk" {
    try std.testing.expectEqual(SemQuery.find_text, SemQuery.fromName("find_text").?);
    try std.testing.expectEqual(SemQuery.within_text, SemQuery.fromName("within_text").?);
    try std.testing.expect(SemQuery.fromName("visible") == null);
    try std.testing.expect(SemQuery.fromName("bogus") == null);
}

// ---------------------------------------------------------------------
// Frame payload types. Field ORDER is the wire order; every type carries
// its tag. Slice fields borrow from the decoded payload buffer.
// ---------------------------------------------------------------------

pub const Hello = struct {
    pub const tag: Tag = .hello;
    proto: u32,
    client_name: []const u8,
};

pub const HelloAck = struct {
    pub const tag: Tag = .hello_ack;
    proto: u32,
    engine_name: []const u8,
    engine_version: []const u8,
    caps: []const []const u8,

    pub fn encodeTo(self: HelloAck, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.proto);
        try putStr(gpa, out, self.engine_name);
        try putStr(gpa, out, self.engine_version);
        try putU16(gpa, out, @intCast(self.caps.len));
        for (self.caps) |cap| try putStr(gpa, out, cap);
    }

    /// Caller owns the returned `caps` slice (the strings themselves
    /// still borrow from `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !HelloAck {
        var cur = Cur{ .buf = payload };
        const proto = try cur.readU32();
        const name = try cur.readStr();
        const ver = try cur.readStr();
        const n = try cur.readU16();
        const caps = try gpa.alloc([]const u8, n);
        errdefer gpa.free(caps);
        for (caps) |*cap| cap.* = try cur.readStr();
        return .{ .proto = proto, .engine_name = name, .engine_version = ver, .caps = caps };
    }
};

pub const ViewCreate = struct {
    pub const tag: Tag = .view_create;
    view: u32,
    w: u16,
    h: u16,
    scale_x1000: u16,
    context: u32,
};

/// `view_create` with the first url built in, gated by
/// `CAP_VIEW_CREATE_URL`.
///
/// It is a NEW frame rather than a url field on `ViewCreate` because the
/// wire is append-only: adding a field would change an existing frame's
/// layout, and an older peer would decode the next frame's bytes as
/// part of this one. The two frames are mutually exclusive per view —
/// send exactly one.
///
/// An empty `url` means the same as `view_create` (a blank document).
/// The point of the frame is that a NON-empty url produces exactly ONE
/// document: create-then-navigate always produced two (about:blank plus
/// the page), so a "did the load settle" test could be satisfied by the
/// blank one and hand back a snapshot of an empty page.
pub const ViewCreateUrl = struct {
    pub const tag: Tag = .view_create_url;
    view: u32,
    w: u16,
    h: u16,
    scale_x1000: u16,
    context: u32,
    url: []const u8,
};

pub const ViewDestroy = struct {
    pub const tag: Tag = .view_destroy;
    view: u32,
};

/// Destroy a view's BROWSER while keeping the view (capability
/// `discard`): the id, its logical geometry, its scale and its current
/// address survive, everything the engine held for it does not.
///
/// Distinct from `view_hide`, which only stops the painting: after this
/// the page is gone from memory entirely. The next `view_show`,
/// `navigate`, `nav_action` or input frame for the id recreates the
/// browser at the stored address, so a client sees nothing but a
/// reload. NAVIGATION HISTORY IS LOST — back/forward start empty again,
/// as does any unsubmitted form state, which is the price of the
/// memory and the reason this is a deliberate client decision rather
/// than something the helper does on its own.
///
/// Discarding a view that has no browser is a no-op, so a client may
/// send it twice.
pub const ViewDiscard = struct {
    pub const tag: Tag = .view_discard;
    view: u32,
};

pub const ViewResize = struct {
    pub const tag: Tag = .view_resize;
    view: u32,
    w: u16,
    h: u16,
    scale_x1000: u16,
};

pub const ViewShow = struct {
    pub const tag: Tag = .view_show;
    view: u32,
};

pub const ViewHide = struct {
    pub const tag: Tag = .view_hide;
    view: u32,
};

pub const Navigate = struct {
    pub const tag: Tag = .navigate;
    view: u32,
    url: []const u8,
};

pub const NavAction = struct {
    pub const tag: Tag = .nav_action;
    view: u32,
    action: u8,
};

pub const InputPointer = struct {
    pub const tag: Tag = .input_pointer;
    view: u32,
    kind: u8,
    x: i32,
    y: i32,
    button: u8,
    clicks: u8,
    mods: u32,
};

pub const InputScroll = struct {
    pub const tag: Tag = .input_scroll;
    view: u32,
    x: i32,
    y: i32,
    dx: i32,
    dy: i32,
    mods: u32,
};

pub const InputKey = struct {
    pub const tag: Tag = .input_key;
    view: u32,
    kind: u8,
    keyval: u32,
    keycode: u32,
    mods: u32,
    text: []const u8,
};

pub const InputIme = struct {
    pub const tag: Tag = .input_ime;
    view: u32,
    kind: u8,
    text: []const u8,
    cursor: i32,
};

pub const InputFocus = struct {
    pub const tag: Tag = .input_focus;
    view: u32,
    focused: u8,
};

/// `clipboard_read` mode byte (append-only values).
pub const ClipboardMode = enum(u8) { copy = 0, cut = 1, _ };

/// Insert clipboard text at the caret of `view`'s focused editable.
///
/// The CLIENT reads its own system clipboard and pushes the text; the
/// HELPER owns how it is inserted. That split is forced twice over: a
/// windowless browser's `ui::Clipboard` is not backed by the session
/// selection in any configuration this product can reach, and CEF's C
/// API exposes no clipboard read or write at all (`cef_frame_t`'s
/// cut/copy/paste are editor COMMANDS over that same empty clipboard).
/// `Text`, not `str`: `putStr` caps at 65535 and the client's `post`
/// swallows the overflow silently, so a large paste would vanish.
pub const InputPaste = struct {
    pub const tag: Tag = .input_paste;
    view: u32,
    text: Text,
};

/// Ask for `view`'s current selection text; answered by
/// `ev_clipboard_text` carrying the same `seq`. `mode = cut` also
/// deletes the selection helper-side, AFTER the answer is posted, so
/// copy-then-delete ordering cannot race a client round trip.
pub const ClipboardRead = struct {
    pub const tag: Tag = .clipboard_read;
    view: u32,
    seq: u32,
    mode: u8,
};

/// The answer to `clipboard_read`. `seq` echoes the request so a reply
/// that arrives after the user moved on is discardable.
pub const EvClipboardText = struct {
    pub const tag: Tag = .ev_clipboard_text;
    view: u32,
    seq: u32,
    text: Text,
};

pub const FrameBuffer = struct {
    pub const tag: Tag = .frame_buffer;
    view: u32,
    buf_id: u32,
    w: u16,
    h: u16,
    stride: u32,
};

/// Byte length of a frame with this geometry, or null when the helper
/// described one no consumer may map: a stride narrower than the row
/// makes any full-height walk read past the end of the mapping.
pub fn frameSize(w: u16, h: u16, stride: u32) ?usize {
    if (w == 0 or h == 0) return null;
    if (stride < @as(u32, w) * 4) return null;
    const size = @as(usize, stride) * @as(usize, h);
    if (size == 0) return null;
    return size;
}

test "frame geometry refuses a stride narrower than the row" {
    try std.testing.expectEqual(@as(?usize, 4096), frameSize(64, 16, 256));
    try std.testing.expect(frameSize(64, 16, 255) == null);
    try std.testing.expect(frameSize(0, 16, 256) == null);
    try std.testing.expect(frameSize(64, 0, 256) == null);
}

pub const FrameDamage = struct {
    pub const tag: Tag = .frame_damage;
    view: u32,
    buf_id: u32,
    gen: u32,
    rects: []const Rect,

    pub fn encodeTo(self: FrameDamage, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.buf_id);
        try putU32(gpa, out, self.gen);
        try putU16(gpa, out, @intCast(self.rects.len));
        for (self.rects) |r| {
            try putU16(gpa, out, r.x);
            try putU16(gpa, out, r.y);
            try putU16(gpa, out, r.w);
            try putU16(gpa, out, r.h);
        }
    }

    /// Caller owns the returned `rects` slice.
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !FrameDamage {
        var cur = Cur{ .buf = payload };
        const view = try cur.readU32();
        const buf_id = try cur.readU32();
        const gen = try cur.readU32();
        const n = try cur.readU16();
        const rects = try gpa.alloc(Rect, n);
        errdefer gpa.free(rects);
        for (rects) |*r| {
            r.x = try cur.readU16();
            r.y = try cur.readU16();
            r.w = try cur.readU16();
            r.h = try cur.readU16();
        }
        return .{ .view = view, .buf_id = buf_id, .gen = gen, .rects = rects };
    }
};

pub const FrameRelease = struct {
    pub const tag: Tag = .frame_release;
    view: u32,
    buf_id: u32,
};

/// Ask the engine to produce ONE frame ("external begin frame"). The
/// client's request rate IS the view's frame rate, so a client that
/// stops asking gets a still page — see the helper's watchdog, which
/// keeps a self-paced floor under exactly that case.
///
/// There is deliberately no per-request acknowledgement: whether a
/// request produced pixels is already observable as a `frame_damage`
/// for the view, and an ack frame would double the socket traffic of
/// the whole path to say something the client can count.
pub const FrameRequest = struct {
    pub const tag: Tag = .frame_request;
    view: u32,
    /// Reserved, must be 0. Room for future per-request hints (force a
    /// full repaint, "this one is a resize settle", …) without a tag.
    flags: u8,
};

/// Client -> helper: cap this view's frame production at `fps` (0 =
/// engine maximum). With the engine's own scheduler pacing paints —
/// the default since external begin frames measured a fixed ~30ms of
/// added input latency — this is how `browser_max_fps` and the display's
/// real refresh rate reach the engine (`set_windowless_frame_rate`).
pub const ViewMaxFps = struct {
    pub const tag: Tag = .view_max_fps;
    view: u32,
    fps: u16,
};

/// Max planes in a `frame_dmabuf`; matches CEF's
/// kAcceleratedPaintMaxPlanes and DRM's own limit.
pub const MAX_PLANES = 4;

/// One dma-buf plane: where it sits in the object its fd names.
pub const Plane = struct { stride: u32, offset: u32 };

/// A GPU frame: the planes of a dma-buf the engine just rendered into,
/// with one SCM_RIGHTS descriptor per plane attached to the frame.
///
/// `buf_id` identifies the underlying BUFFER, not the paint: the engine
/// renders into a small pool and cycles through it, so a client that
/// caches its imported texture per `buf_id` imports each pool member
/// once instead of once per frame. The descriptors are sent every time
/// anyway (a stateless sender is worth four `dup`s a frame); a client
/// that already has the buffer just closes them.
///
/// There are deliberately no damage rects: the import is zero-copy, so
/// there is nothing for the client to upload selectively. `gen` is the
/// same monotonic per-view paint counter `frame_damage` carries.
///
/// Buffer contents are NOT owned by the client: the engine writes into
/// the pool again as soon as it comes round, which is the same benign
/// tearing the memfd path documents.
pub const FrameDmabuf = struct {
    pub const tag: Tag = .frame_dmabuf;
    view: u32,
    buf_id: u32,
    gen: u32,
    /// PHYSICAL pixels, like `frame_buffer`'s w/h.
    w: u16,
    h: u16,
    /// DRM FourCC (`DRM_FORMAT_ARGB8888` and friends), not a CEF enum.
    fourcc: u32,
    /// DRM format modifier; 0 is LINEAR.
    modifier: u64,
    nplanes: u8,
    planes: [MAX_PLANES]Plane,

    pub fn encodeTo(self: FrameDmabuf, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.buf_id);
        try putU32(gpa, out, self.gen);
        try putU16(gpa, out, self.w);
        try putU16(gpa, out, self.h);
        try putU32(gpa, out, self.fourcc);
        try putU32(gpa, out, @truncate(self.modifier));
        try putU32(gpa, out, @truncate(self.modifier >> 32));
        try putU8(gpa, out, self.nplanes);
        for (self.planes[0..self.nplanes]) |p| {
            try putU32(gpa, out, p.stride);
            try putU32(gpa, out, p.offset);
        }
    }

    /// Not `decodeAlloc`: the plane count is bounded, so the frame
    /// decodes into a fixed array and needs no allocator.
    pub fn decodeFrom(payload: []const u8) !FrameDmabuf {
        var cur = Cur{ .buf = payload };
        var out: FrameDmabuf = .{
            .view = try cur.readU32(),
            .buf_id = try cur.readU32(),
            .gen = try cur.readU32(),
            .w = try cur.readU16(),
            .h = try cur.readU16(),
            .fourcc = try cur.readU32(),
            .modifier = 0,
            .nplanes = 0,
            .planes = @splat(.{ .stride = 0, .offset = 0 }),
        };
        const lo = try cur.readU32();
        const hi = try cur.readU32();
        out.modifier = @as(u64, lo) | (@as(u64, hi) << 32);
        const n = try cur.readU8();
        if (n == 0 or n > MAX_PLANES) return error.BadPlaneCount;
        out.nplanes = n;
        for (out.planes[0..n]) |*p| {
            p.stride = try cur.readU32();
            p.offset = try cur.readU32();
        }
        return out;
    }
};

/// Client -> helper: select the frame family (capability
/// "frames-inline"). mode 0 = shm/dma-buf (the default), 1 = inline.
/// Applies to every buffer allocated AFTER it lands, so a client that
/// wants inline frames sends it right after `hello`, before any view
/// exists. There is deliberately no per-view granularity: one client is
/// either descriptor-capable or it is not.
pub const FrameMode = struct {
    pub const tag: Tag = .frame_mode;
    mode: u8,
};

pub const frame_mode_shm: u8 = 0;
pub const frame_mode_inline: u8 = 1;

/// `InlineRect.enc`: raw BGRA rows (w*h*4 bytes), or a raw-deflate
/// stream of exactly those bytes (`wlhost/zpool.zig`, the same codec
/// pool updates on the native app pipe use). Append-only values.
pub const inline_enc_raw: u8 = 0;
pub const inline_enc_deflate: u8 = 1;

/// One damaged rect of an inline frame, pixels included. `data` borrows
/// from the decoded payload buffer.
pub const InlineRect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    enc: u8,
    data: []const u8,
};

/// Helper -> client, capability "frames-inline": damaged rects of a
/// paint, pixels carried IN-BAND (`Text`-sized: a full frame is far
/// beyond a `str`). w/h are the PHYSICAL surface size, rect coordinates
/// are physical too — the same contract as `frame_buffer`/`frame_damage`
/// with the memfd replaced by the payload. One paint may arrive as
/// SEVERAL frame_inline messages (large damage is banded so no single
/// frame approaches MAX_FRAME); each is self-contained and presentable
/// on receipt. `gen` is the same monotonic per-view paint counter the
/// other families carry.
pub const FrameInline = struct {
    pub const tag: Tag = .frame_inline;
    view: u32,
    gen: u32,
    w: u16,
    h: u16,
    rects: []const InlineRect,

    pub fn encodeTo(self: FrameInline, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.gen);
        try putU16(gpa, out, self.w);
        try putU16(gpa, out, self.h);
        try putU16(gpa, out, @intCast(self.rects.len));
        for (self.rects) |r| {
            try putU16(gpa, out, r.x);
            try putU16(gpa, out, r.y);
            try putU16(gpa, out, r.w);
            try putU16(gpa, out, r.h);
            try putU8(gpa, out, r.enc);
            try putText(gpa, out, .{ .s = r.data });
        }
    }

    /// Caller owns the returned `rects` slice; each rect's `data` still
    /// borrows from `payload`.
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !FrameInline {
        var cur = Cur{ .buf = payload };
        const view = try cur.readU32();
        const gen = try cur.readU32();
        const w = try cur.readU16();
        const h = try cur.readU16();
        const n = try cur.readU16();
        const rects = try gpa.alloc(InlineRect, n);
        errdefer gpa.free(rects);
        for (rects) |*r| {
            r.x = try cur.readU16();
            r.y = try cur.readU16();
            r.w = try cur.readU16();
            r.h = try cur.readU16();
            r.enc = try cur.readU8();
            r.data = (try cur.readText()).s;
        }
        return .{ .view = view, .gen = gen, .w = w, .h = h, .rects = rects };
    }
};

pub const EvLoad = struct {
    pub const tag: Tag = .ev_load;
    view: u32,
    state: u8,
    url: []const u8,
};

pub const EvLoadError = struct {
    pub const tag: Tag = .ev_load_error;
    view: u32,
    code: i32,
    url: []const u8,
    msg: []const u8,
};

/// Helper -> client, capability `load-retry`: the main-frame load of
/// `url` failed with `code` (`msg` its symbolic name) and the helper is
/// loading it again on its own. No `ev_load_error` is posted for the
/// failed attempt; the retried load then reports as any load does.
pub const EvLoadRetry = struct {
    pub const tag: Tag = .ev_load_retry;
    view: u32,
    code: i32,
    url: []const u8,
    msg: []const u8,
};

pub const EvTitle = struct {
    pub const tag: Tag = .ev_title;
    view: u32,
    title: []const u8,
};

pub const EvFavicon = struct {
    pub const tag: Tag = .ev_favicon;
    view: u32,
    url: []const u8,
};

pub const EvNavState = struct {
    pub const tag: Tag = .ev_nav_state;
    view: u32,
    can_back: u8,
    can_fwd: u8,
    loading: u8,
    url: []const u8,
};

/// A page asked for a popup. The helper never opens one: it cancels
/// and reports, so the client decides between a tab, a window and a
/// refusal.
///
/// `user_gesture` is an OPTIONAL TRAILING field — the one shape in
/// which this wire tolerates growing a frame, and only because the
/// decoder below treats a payload that ends early as "field absent"
/// instead of `error.Truncated`. It defaults to 1 (a gesture) when
/// absent, so a client with a popup policy keeps a pre-gesture helper's
/// popups working exactly as before rather than blocking all of them.
/// Nothing may be appended after it unless the same rule is kept, and
/// no EXISTING field may ever be widened or reordered.
pub const EvPopupRequest = struct {
    pub const tag: Tag = .ev_popup_request;
    view: u32,
    url: []const u8,
    disposition: u8,
    /// 1 when the page asked from inside a real user interaction.
    user_gesture: u8 = 1,

    pub fn encodeTo(self: EvPopupRequest, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putStr(gpa, out, self.url);
        try putU8(gpa, out, self.disposition);
        try putU8(gpa, out, self.user_gesture);
    }

    pub fn decodeFrom(payload: []const u8) !EvPopupRequest {
        var cur = Cur{ .buf = payload };
        return .{
            .view = try cur.readU32(),
            .url = try cur.readStr(),
            .disposition = try cur.readU8(),
            .user_gesture = cur.readU8() catch 1,
        };
    }
};

/// Popup blocking, pushed AHEAD of the decision.
///
/// `on_before_popup` must answer synchronously, so the helper cannot
/// ask the client at decision time; the client instead keeps the
/// helper's copy of the policy current. `view == 0` sets the
/// connection default; any other value is that view's override, which
/// is how a per-site "allow popups here" reaches the engine.
/// Unset = BLOCK, so a client that never sends this is unchanged.
pub const PopupPolicySet = struct {
    pub const tag: Tag = .popup_policy_set;
    view: u32,
    mode: u8,
};

pub const popup_mode_block: u8 = 0;
pub const popup_mode_allow: u8 = 1;

pub const page_popup_opened: u8 = 1;
pub const page_popup_closed: u8 = 2;

/// A popup the engine really opened, keeping its opener relationship.
///
/// Deliberately has NO field named `view`: the id translation layer
/// keys on that name, and an engine-minted `view` would make it treat
/// the whole frame as untranslatable and skip `owner_view` — which IS
/// a client id and must be translated. `EvWebextPopup` is the shape
/// this copies.
///
/// `chromeless` reports that the page asked for a popup-shaped window
/// (`cef_popup_features_t.isPopup`), so the client can present it as
/// one instead of as a full-size tab.
pub const EvPagePopup = struct {
    pub const tag: Tag = .ev_page_popup;
    owner_view: u32,
    popup_view: u32,
    state: u8,
    disposition: u8,
    user_gesture: u8,
    chromeless: u8,
    w: u16,
    h: u16,
    url: []const u8,
    frame_name: []const u8,
};

pub const EvCursor = struct {
    pub const tag: Tag = .ev_cursor;
    view: u32,
    cursor: u8,
};

pub const EvConsole = struct {
    pub const tag: Tag = .ev_console;
    view: u32,
    level: u8,
    msg: []const u8,
};

pub const EvCrashed = struct {
    pub const tag: Tag = .ev_crashed;
    view: u32,
};

// -- find / zoom / context menu (0x50 block, caps "find"/"zoom"/
//    "context-menu") --------------------------------------------------

/// Find-in-page. `find_next = 0` starts a NEW search for `text`
/// (highlighting every match and selecting the first); `find_next = 1`
/// steps through the current search's matches in `forward` direction.
pub const Find = struct {
    pub const tag: Tag = .find;
    view: u32,
    forward: u8,
    match_case: u8,
    find_next: u8,
    text: []const u8,
};

/// End the search. `clear_selection = 1` also drops the highlight the
/// active match left behind.
pub const FindStop = struct {
    pub const tag: Tag = .find_stop;
    view: u32,
    clear_selection: u8,
};

/// USER zoom for a view, as the engine's log-scale zoom LEVEL x100:
/// factor = 1.2 ^ (level_x100 / 100), so +100 is one conventional
/// browser zoom step (120%) and 0 resets. Distinct from the DPR zoom
/// the helper applies internally in accelerated mode — the helper adds
/// the two, so the client only ever speaks user intent.
pub const SetZoom = struct {
    pub const tag: Tag = .set_zoom;
    view: u32,
    level_x100: i32,
};

/// Match count for the current search. Several non-final updates may
/// precede the `final = 1` one as the engine keeps counting.
pub const EvFindResult = struct {
    pub const tag: Tag = .ev_find_result;
    view: u32,
    /// Total matches found so far.
    count: i32,
    /// 1-based ordinal of the active match, 0 when there is none.
    active: i32,
    final: u8,
};

/// `ev_context_menu` flags bit: the hit test found a link, and
/// `link_url` carries it.
pub const ctx_flag_link: u8 = 1;
/// `ev_context_menu` flags bit: the hit test is an editable field.
pub const ctx_flag_editable: u8 = 2;
/// `ev_context_menu` flags bit: the hit test found an image, and
/// `src_url` carries its source.
pub const ctx_flag_image: u8 = 4;
/// `ev_context_menu` flags bit: text is selected, and
/// `selection_text` carries it.
pub const ctx_flag_selection: u8 = 8;

/// The page asked for a context menu (the engine's own menu is
/// suppressed). x/y are LOGICAL view coordinates, same space as
/// `input_pointer`.
///
/// `src_url` and `selection_text` are OPTIONAL TRAILING fields under
/// the same rule `EvPopupRequest.user_gesture` established: a payload
/// that ends early reads as "absent" (empty), existing fields are
/// never widened or reordered, and anything appended later must keep
/// the rule.
pub const EvContextMenu = struct {
    pub const tag: Tag = .ev_context_menu;
    view: u32,
    x: i32,
    y: i32,
    flags: u8,
    link_url: []const u8,
    /// Image/media source under the click (`ctx_flag_image`).
    src_url: []const u8 = "",
    /// Selected text at menu time (`ctx_flag_selection`), truncated
    /// by the helper to a sane length for a menu row.
    selection_text: []const u8 = "",

    pub fn encodeTo(self: EvContextMenu, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putI32(gpa, out, self.x);
        try putI32(gpa, out, self.y);
        try putU8(gpa, out, self.flags);
        try putStr(gpa, out, self.link_url);
        try putStr(gpa, out, self.src_url);
        try putStr(gpa, out, self.selection_text);
    }

    pub fn decodeFrom(payload: []const u8) !EvContextMenu {
        var cur = Cur{ .buf = payload };
        return .{
            .view = try cur.readU32(),
            .x = try cur.readI32(),
            .y = try cur.readI32(),
            .flags = try cur.readU8(),
            .link_url = try cur.readStr(),
            .src_url = cur.readStr() catch "",
            .selection_text = cur.readStr() catch "",
        };
    }
};

// -- TLS interstitials (capability "tls") -----------------------------

/// The engine refused a certificate and is HOLDING the request. Exactly
/// one `cert_decision` for the same view resolves it; until then the
/// load is neither committed nor failed, so a client that never answers
/// leaves the page hanging (view destruction cancels it helper-side).
///
/// `code` is the engine's own error number, the same space
/// `ev_load_error` uses, and `msg` its symbolic name. `fingerprint` is
/// the certificate's SHA-256 as lowercase hex, or empty when the engine
/// gave no certificate to hash — never trust it to be present.
pub const EvCertError = struct {
    pub const tag: Tag = .ev_cert_error;
    view: u32,
    code: i32,
    /// The url whose request is held.
    url: []const u8,
    /// Host of `url`, extracted helper-side so every client agrees on
    /// what the interstitial names.
    host: []const u8,
    msg: []const u8,
    subject: []const u8,
    issuer: []const u8,
    fingerprint: []const u8,
};

/// Answer to `ev_cert_error`. `proceed = 1` continues the request with
/// the certificate accepted FOR THIS REQUEST only — nothing is
/// remembered helper-side, deliberately: a persisted exception is a
/// stored security decision and belongs to whoever owns site settings,
/// not to a stateless render helper.
pub const CertDecision = struct {
    pub const tag: Tag = .cert_decision;
    view: u32,
    proceed: u8,
};

// -- permission prompts (capability "permissions") --------------------

/// Permission bits, deliberately OUR OWN numbering: an engine's
/// permission enum is not part of this wire. Anything the helper cannot
/// map lands in `perm_other`, which a client must still be able to name
/// and prompt for.
pub const perm_geolocation: u32 = 1 << 0;
pub const perm_notifications: u32 = 1 << 1;
pub const perm_camera: u32 = 1 << 2;
pub const perm_microphone: u32 = 1 << 3;
pub const perm_midi: u32 = 1 << 4;
pub const perm_clipboard: u32 = 1 << 5;
pub const perm_pointer_lock: u32 = 1 << 6;
pub const perm_idle_detection: u32 = 1 << 7;
pub const perm_storage_access: u32 = 1 << 8;
pub const perm_window_management: u32 = 1 << 9;
pub const perm_protected_media: u32 = 1 << 10;
pub const perm_local_fonts: u32 = 1 << 11;
pub const perm_file_system: u32 = 1 << 12;
pub const perm_downloads: u32 = 1 << 13;
pub const perm_sensors: u32 = 1 << 14;
pub const perm_vr: u32 = 1 << 15;
pub const perm_other: u32 = 1 << 31;

/// A page asked for a permission and the engine is HOLDING the request.
/// `prompt` identifies it for the matching `permission_decision`; ids
/// are unique per helper process, not per view.
pub const EvPermission = struct {
    pub const tag: Tag = .ev_permission;
    view: u32,
    prompt: u64,
    /// Origin as the engine reports it ("https://example.com").
    origin: []const u8,
    /// One or more `perm_*` bits; a single prompt can carry several
    /// (a call asking for camera AND microphone is one decision).
    types: u32,
};

/// Answer to `ev_permission`. An id the helper no longer holds — the
/// page navigated away, the view went — is ignored, so a client may
/// always answer late.
pub const PermissionDecision = struct {
    pub const tag: Tag = .permission_decision;
    view: u32,
    prompt: u64,
    allow: u8,
};

// -- downloads (0x78 block, capability "downloads") -------------------

/// The page started a download and the engine is HOLDING its target
/// decision. Exactly one `download_decide` for the same id resolves it;
/// until then the bytes may already be streaming into the engine's own
/// staging, but nothing lands anywhere the user can see. `id` is the
/// ENGINE's download id, unique per helper process. View destruction
/// (and `view_discard`) cancels every held or running download of the
/// view helper-side, so a client that never answers leaks nothing.
///
/// `total` is 0 when the server sent no length. `mime` may be empty.
///
/// `req` is the OPTIONAL TRAILING field (the `ev_popup_request` shape):
/// it echoes the `download_start.req` of the client request that asked
/// for this download, and is 0 for one the page started by itself. A
/// short payload from an older helper decodes as 0, which is exactly
/// "the page started it" — the only behaviour that helper had.
pub const EvDownloadOffer = struct {
    pub const tag: Tag = .ev_download_offer;
    view: u32,
    id: u32,
    total: u64,
    url: []const u8,
    /// Engine-suggested file name, never a path.
    name: []const u8,
    mime: []const u8,
    req: u32 = 0,

    pub fn decodeFrom(payload: []const u8) !EvDownloadOffer {
        var cur = Cur{ .buf = payload };
        var out: EvDownloadOffer = .{
            .view = try cur.readU32(),
            .id = try cur.readU32(),
            .total = try cur.readU64(),
            .url = try cur.readStr(),
            .name = try cur.readStr(),
            .mime = try cur.readStr(),
        };
        out.req = cur.readU32() catch 0;
        return out;
    }
};

/// Ask the view's browser to download `url` itself, so the fetch
/// carries that browser's cookies, session and route. The download then
/// follows the ordinary path — an `ev_download_offer` echoing `req`,
/// answered by a `download_decide` naming the target path — because the
/// client, not the engine, decides where bytes land.
///
/// `req` is client-minted and non-zero; the helper only echoes it.
pub const DownloadStart = struct {
    pub const tag: Tag = .download_start;
    view: u32,
    req: u32,
    url: []const u8,
};

/// Answer to `ev_download_offer`. A non-empty `path` continues the
/// download INTO that path (helper-side, same machine as the client in
/// v1; existing bytes there are overwritten). An empty `path` cancels
/// it. An id the helper no longer holds is ignored, so a client may
/// always answer late.
pub const DownloadDecide = struct {
    pub const tag: Tag = .download_decide;
    view: u32,
    id: u32,
    path: []const u8,
    /// Allocate a private helper-side staging file; progress reports its path.
    stage: u8 = 0,

    pub fn decodeFrom(payload: []const u8) !DownloadDecide {
        var cur = Cur{ .buf = payload };
        var out: DownloadDecide = .{ .view = try cur.readU32(), .id = try cur.readU32(), .path = try cur.readStr() };
        out.stage = cur.readU8() catch 0;
        return out;
    }
};

/// Coalesced progress for a decided download: at most one frame per
/// poll iteration per download, however often the engine updates.
/// Exactly one terminal frame (`done` or `failed`) ends every decided
/// download — including one the client cancelled, and one whose view
/// went away mid-flight.
/// `req` is the OPTIONAL TRAILING field: the `download_start.req` this
/// download answers, 0 for a page-initiated one. It also carries the
/// ONE shape a start can fail in before any download exists — `id = 0`,
/// `failed = 1`, `req` naming the request — so a client that asked for
/// a url gets an answer even when the view was gone by the time the
/// frame arrived, instead of waiting out its deadline for an offer that
/// can never come.
pub const EvDownloadProgress = struct {
    pub const tag: Tag = .ev_download_progress;
    view: u32,
    id: u32,
    received: u64,
    /// 0 while unknown; the engine may learn it mid-download.
    total: u64,
    done: u8,
    /// Canceled or interrupted. `done` and `failed` are exclusive.
    failed: u8,
    req: u32 = 0,
    path: []const u8 = "",
    interrupt_reason: i32 = 0,

    pub fn decodeFrom(payload: []const u8) !EvDownloadProgress {
        var cur = Cur{ .buf = payload };
        var out: EvDownloadProgress = .{
            .view = try cur.readU32(),
            .id = try cur.readU32(),
            .received = try cur.readU64(),
            .total = try cur.readU64(),
            .done = try cur.readU8(),
            .failed = try cur.readU8(),
        };
        out.req = cur.readU32() catch 0;
        out.path = cur.readStr() catch "";
        out.interrupt_reason = cur.readI32() catch 0;
        return out;
    }
};

/// Abort a running download. Unknown ids are ignored (the download may
/// have finished in flight).
pub const DownloadCancel = struct {
    pub const tag: Tag = .download_cancel;
    view: u32,
    id: u32,
};

// -- accessibility (0x70 block, capability "a11y") --------------------
//
// The engine's accessibility tree, streamed to the client so a
// PLATFORM projection (AT-SPI on Linux, NSAccessibility on macOS) can
// re-expose the page to a screen reader. Shape rules:
//
//   - Nothing flows until the client sends `a11y_enable` for a view;
//     engine-side accessibility costs real CPU and the stream would
//     otherwise violate the backlog rule.
//   - `ev_a11y_tree` is an INCREMENTAL update, mirroring how engines
//     produce them: a list of nodes that changed (with their full new
//     content and child lists), not a restatement of the whole tree.
//     The first update after enabling restates everything reachable.
//   - Node ids are engine-assigned, stable for the lifetime of a
//     document, and only unique WITHIN a view. Only the root frame's
//     tree is streamed in v1; child-frame (iframe) trees are dropped,
//     so a child id naming a node that never arrives must be treated
//     as an absent child, not an error.
//   - Roles are lowercase tokens: the WAI-ARIA role name where one
//     exists ("button", "heading", "link", "checkbox", ...), plus a
//     small documented extension set ("text" for a static text run,
//     "document" for the root, "generic" for a plain container).
//     Unknown roles must be presented as a generic node, not dropped.

/// Enable (1) or disable (0) accessibility streaming for a view.
/// Idempotent; disabling also stops the engine-side tree production.
pub const A11yEnable = struct {
    pub const tag: Tag = .a11y_enable;
    view: u32,
    enabled: u8,
};

/// One incremental tree update. `nodes` is a sequence of
/// `A11yNode`-encoded records (see `A11yNodeWriter`/`A11yNodeIter`).
/// `node_id_to_clear` names a node whose CHILDREN should be dropped
/// before applying the node list (0 = none); `root_id` is the current
/// root node id; `focus_id` the currently focused node (0 = none).
pub const EvA11yTree = struct {
    pub const tag: Tag = .ev_a11y_tree;
    view: u32,
    root_id: u32,
    node_id_to_clear: u32,
    focus_id: u32,
    nodes: Text,
};

/// Pure geometry deltas (scrolling, layout shifts): a sequence of
/// `A11yLoc` records (see `putA11yLoc`/`A11yLocIter`). Split from
/// `ev_a11y_tree` because scrolling produces them at frame rate and a
/// client that only mirrors structure may skip them cheaply.
pub const EvA11yLoc = struct {
    pub const tag: Tag = .ev_a11y_loc;
    view: u32,
    locs: Text,
};

/// A discrete accessibility event on one node. `event` is a lowercase
/// token from a deliberately small set ("focus", "load-complete");
/// helpers map their engine's vocabulary onto it and DROP what has no
/// mapping, so unknown tokens are new protocol, not engine leakage.
pub const EvA11yEvent = struct {
    pub const tag: Tag = .ev_a11y_event;
    view: u32,
    id: u32,
    event: []const u8,
};

/// The document's caret and selection, which the node tree cannot
/// express: a selection is a pair of (node, character offset) endpoints
/// that may straddle nodes, not a property of any one node.
///
/// `anchor_*` is where the selection STARTED and `focus_*` is where the
/// caret now is, matching the DOM's own vocabulary — so a collapsed
/// caret is `anchor == focus` and the caret offset a braille display
/// follows is always `focus_offset`. A backward selection (dragged
/// right-to-left) is therefore anchor > focus and NOT an error; a
/// consumer wanting an ordered range must sort the two. `focus_id == 0`
/// means the document has no caret at all (nothing focused, or focus is
/// on a node with no text).
///
/// Offsets are UTF-16 CODE UNITS into the node's text. That is not an
/// engine detail leaking: UTF-16 is the unit the DOM itself defines
/// text offsets in (`Selection`, `Range`, `textContent.length`), so
/// every engine produces it already and none has to be asked to
/// convert. Translating to the CHARACTER offsets a platform
/// accessibility API wants happens in the consumer that mirrors the
/// node TEXT, because that is the only place both numbers are known —
/// a producer would have to ship the text a second time just to count
/// it.
///
/// Consequence worth knowing: a caret may name a node whose text the
/// consumer has not received yet, so an offset is clamped and
/// converted at READ time and never trusted as an index.
pub const EvA11yCaret = struct {
    pub const tag: Tag = .ev_a11y_caret;
    view: u32,
    anchor_id: u32,
    anchor_offset: i32,
    focus_id: u32,
    focus_offset: i32,
};

/// `A11yNode.state` bits — OUR numbering, engine enums never cross the
/// wire. Append-only: a bit once assigned is never reused.
pub const ax_focusable: u64 = 1 << 0;
pub const ax_focused: u64 = 1 << 1;
pub const ax_disabled: u64 = 1 << 2;
pub const ax_editable: u64 = 1 << 3;
pub const ax_checked: u64 = 1 << 4;
pub const ax_checked_mixed: u64 = 1 << 5;
pub const ax_selected: u64 = 1 << 6;
pub const ax_expanded: u64 = 1 << 7;
pub const ax_collapsed: u64 = 1 << 8;
pub const ax_invisible: u64 = 1 << 9;
pub const ax_ignored: u64 = 1 << 10;
pub const ax_required: u64 = 1 << 11;
pub const ax_readonly: u64 = 1 << 12;
pub const ax_busy: u64 = 1 << 13;
pub const ax_modal: u64 = 1 << 14;
pub const ax_multiline: u64 = 1 << 15;
pub const ax_protected: u64 = 1 << 16;
pub const ax_hovered: u64 = 1 << 17;
pub const ax_default: u64 = 1 << 18;
pub const ax_visited: u64 = 1 << 19;
pub const ax_multiselectable: u64 = 1 << 20;
pub const ax_autofill_available: u64 = 1 << 21;

/// One node of an `ev_a11y_tree` payload as the decoder yields it.
/// Rect coordinates are CSS pixels RELATIVE to `offset_container`
/// (0 = the tree root / no container); child ids and attribute pairs
/// stay in their raw encoded form so decoding allocates nothing.
pub const A11yNode = struct {
    id: u32,
    state: u64,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    offset_container: u32,
    role: []const u8,
    name: []const u8,
    value: []const u8,
    description: []const u8,
    nchildren: u16,
    child_bytes: []const u8,
    nattrs: u16,
    attr_bytes: []const u8,

    pub fn childAt(self: *const A11yNode, i: usize) u32 {
        return std.mem.readInt(u32, self.child_bytes[i * 4 ..][0..4], .little);
    }

    pub fn attrs(self: *const A11yNode) A11yAttrIter {
        return .{ .cur = .{ .buf = self.attr_bytes }, .left = self.nattrs };
    }
};

pub const A11yAttr = struct { key: []const u8, value: []const u8 };

pub const A11yAttrIter = struct {
    cur: Cur,
    left: u16,

    pub fn next(self: *A11yAttrIter) !?A11yAttr {
        if (self.left == 0) return null;
        self.left -= 1;
        const k = try self.cur.readStr();
        const v = try self.cur.readStr();
        return .{ .key = k, .value = v };
    }
};

/// What a producer hands `A11yNodeWriter.put` — same fields as
/// `A11yNode`, with the lists as real slices.
pub const A11yNodeSpec = struct {
    id: u32,
    state: u64 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    offset_container: u32 = 0,
    role: []const u8 = "",
    name: []const u8 = "",
    value: []const u8 = "",
    description: []const u8 = "",
    children: []const u32 = &.{},
    attributes: []const A11yAttr = &.{},
};

/// Appends `A11yNode` records to a buffer that becomes an
/// `EvA11yTree.nodes` payload. Shared by the helper and the tests so
/// the encoding cannot fork.
pub const A11yNodeWriter = struct {
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    count: u32 = 0,

    pub fn put(self: *A11yNodeWriter, n: A11yNodeSpec) !void {
        if (n.children.len > std.math.maxInt(u16)) return error.TooManyChildren;
        if (n.attributes.len > std.math.maxInt(u16)) return error.TooManyAttrs;
        try putU32(self.gpa, self.buf, n.id);
        try putU64(self.gpa, self.buf, n.state);
        try putI32(self.gpa, self.buf, n.x);
        try putI32(self.gpa, self.buf, n.y);
        try putI32(self.gpa, self.buf, n.w);
        try putI32(self.gpa, self.buf, n.h);
        try putU32(self.gpa, self.buf, n.offset_container);
        try putStr(self.gpa, self.buf, n.role);
        try putStr(self.gpa, self.buf, n.name);
        try putStr(self.gpa, self.buf, n.value);
        try putStr(self.gpa, self.buf, n.description);
        try putU16(self.gpa, self.buf, @intCast(n.children.len));
        for (n.children) |id| try putU32(self.gpa, self.buf, id);
        try putU16(self.gpa, self.buf, @intCast(n.attributes.len));
        for (n.attributes) |a| {
            try putStr(self.gpa, self.buf, a.key);
            try putStr(self.gpa, self.buf, a.value);
        }
        self.count += 1;
    }
};

/// Walks an `EvA11yTree.nodes` payload. Slices borrow from the
/// payload; nothing allocates.
pub const A11yNodeIter = struct {
    cur: Cur,

    pub fn init(payload: []const u8) A11yNodeIter {
        return .{ .cur = .{ .buf = payload } };
    }

    pub fn next(self: *A11yNodeIter) !?A11yNode {
        if (self.cur.pos >= self.cur.buf.len) return null;
        var n: A11yNode = undefined;
        n.id = try self.cur.readU32();
        n.state = try self.cur.readU64();
        n.x = try self.cur.readI32();
        n.y = try self.cur.readI32();
        n.w = try self.cur.readI32();
        n.h = try self.cur.readI32();
        n.offset_container = try self.cur.readU32();
        n.role = try self.cur.readStr();
        n.name = try self.cur.readStr();
        n.value = try self.cur.readStr();
        n.description = try self.cur.readStr();
        n.nchildren = try self.cur.readU16();
        const cb = @as(usize, n.nchildren) * 4;
        if (self.cur.pos + cb > self.cur.buf.len) return error.Truncated;
        n.child_bytes = self.cur.buf[self.cur.pos..][0..cb];
        self.cur.pos += cb;
        n.nattrs = try self.cur.readU16();
        const attr_start = self.cur.pos;
        var i: u16 = 0;
        while (i < n.nattrs) : (i += 1) {
            _ = try self.cur.readStr();
            _ = try self.cur.readStr();
        }
        n.attr_bytes = self.cur.buf[attr_start..self.cur.pos];
        return n;
    }
};

/// One geometry delta of an `ev_a11y_loc` payload.
pub const A11yLoc = struct {
    id: u32,
    offset_container: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub fn putA11yLoc(gpa: std.mem.Allocator, out: *std.ArrayList(u8), l: A11yLoc) !void {
    try putU32(gpa, out, l.id);
    try putU32(gpa, out, l.offset_container);
    try putI32(gpa, out, l.x);
    try putI32(gpa, out, l.y);
    try putI32(gpa, out, l.w);
    try putI32(gpa, out, l.h);
}

pub const A11yLocIter = struct {
    cur: Cur,

    pub fn init(payload: []const u8) A11yLocIter {
        return .{ .cur = .{ .buf = payload } };
    }

    pub fn next(self: *A11yLocIter) !?A11yLoc {
        if (self.cur.pos >= self.cur.buf.len) return null;
        return .{
            .id = try self.cur.readU32(),
            .offset_container = try self.cur.readU32(),
            .x = try self.cur.readI32(),
            .y = try self.cur.readI32(),
            .w = try self.cur.readI32(),
            .h = try self.cur.readI32(),
        };
    }
};

// -- semantic layer (capability "semantic") ---------------------------

pub const SemSnapshotReq = struct {
    pub const tag: Tag = .sem_snapshot_req;
    view: u32,
    mode: u8,
    detail: u8,
    /// 0 = whole document, else the stable id of a subtree root.
    scope: u32,
};

pub const SemSnapshot = struct {
    pub const tag: Tag = .sem_snapshot;
    view: u32,
    doc_gen: u32,
    rev: u32,
    kind: u8,
    payload: Text,
};

pub const SemAction = struct {
    pub const tag: Tag = .sem_act;
    view: u32,
    id: u32,
    action: u8,
    arg: []const u8,
};

pub const SemActResult = struct {
    pub const tag: Tag = .sem_act_result;
    view: u32,
    id: u32,
    ok: u8,
    msg: []const u8,
};

pub const SemExpand = struct {
    pub const tag: Tag = .sem_expand;
    view: u32,
    id: u32,
    off: u32,
    len: u32,
};

pub const SemExpandResult = struct {
    pub const tag: Tag = .sem_expand_result;
    view: u32,
    id: u32,
    off: u32,
    text: []const u8,
};

pub const SemQueryReq = struct {
    pub const tag: Tag = .sem_query;
    view: u32,
    kind: u8,
    arg: []const u8,
};

pub const SemQueryResult = struct {
    pub const tag: Tag = .sem_query_result;
    view: u32,
    payload: Text,
};

pub const SemRead = struct {
    pub const tag: Tag = .sem_read;
    view: u32,
};

pub const SemReadResult = struct {
    pub const tag: Tag = .sem_read_result;
    view: u32,
    markdown: Text,
};

/// Rich reader request, gated by `CAP_READER_IDS`.
pub const SemReadIds = struct {
    pub const tag: Tag = .sem_read_ids;
    view: u32,
};

/// One reader entity. `id` is a stable semantic id; `kind` describes
/// how the entity is represented in the markdown without interpreting
/// page-authored text as protocol instructions.
pub const ReaderEntity = struct {
    id: u32,
    /// Helper-computed action identity (element/role/name/value/target).
    /// Clients round-trip it but do not interpret or display it.
    guard: u64,
    kind: []const u8,
    text: []const u8,
    url: []const u8,
};

/// Reader markdown plus entities from one exact semantic revision.
/// The entity strings borrow from the frame payload; only the returned
/// `entities` slice is allocated by `decodeAlloc`.
pub const SemReadIdsResult = struct {
    pub const tag: Tag = .sem_read_ids_result;
    view: u32,
    doc_gen: u32,
    rev: u32,
    markdown: Text,
    entities: []const ReaderEntity,

    pub fn encodeTo(self: SemReadIdsResult, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.doc_gen);
        try putU32(gpa, out, self.rev);
        try putText(gpa, out, self.markdown);
        if (self.entities.len > std.math.maxInt(u16)) return error.TooManyEntities;
        try putU16(gpa, out, @intCast(self.entities.len));
        for (self.entities) |entity| {
            try putU32(gpa, out, entity.id);
            try putU64(gpa, out, entity.guard);
            try putStr(gpa, out, entity.kind);
            try putStr(gpa, out, entity.text);
            try putStr(gpa, out, entity.url);
        }
    }

    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !SemReadIdsResult {
        var cur = Cur{ .buf = payload };
        const view = try cur.readU32();
        const doc_gen = try cur.readU32();
        const rev = try cur.readU32();
        const markdown = try cur.readText();
        const n = try cur.readU16();
        const entities = try gpa.alloc(ReaderEntity, n);
        errdefer gpa.free(entities);
        for (entities) |*entity| {
            entity.* = .{
                .id = try cur.readU32(),
                .guard = try cur.readU64(),
                .kind = try cur.readStr(),
                .text = try cur.readStr(),
                .url = try cur.readStr(),
            };
        }
        return .{
            .view = view,
            .doc_gen = doc_gen,
            .rev = rev,
            .markdown = markdown,
            .entities = entities,
        };
    }
};

/// `sem_act` with an exact reader-result revision guard. The result is
/// the existing `sem_act_result`; a stale guard answers `ok = 0`.
pub const SemActGuarded = struct {
    pub const tag: Tag = .sem_act_guarded;
    view: u32,
    doc_gen: u32,
    rev: u32,
    id: u32,
    guard: u64,
    action: u8,
    arg: []const u8,
};

/// Correlated wrapper around one existing client-to-helper semantic
/// payload, gated by `CAP_SEMANTIC_REQUEST_IDS`.
pub const SemRequest = struct {
    pub const tag: Tag = .sem_request;
    request: u32,
    kind: u8,
    payload: Text,
};

/// Correlated wrapper around one existing helper-to-client semantic
/// result payload.
pub const SemResult = struct {
    pub const tag: Tag = .sem_result;
    request: u32,
    kind: u8,
    payload: Text,
};

/// Encode `value` into `payload` and wrap it as a correlated
/// `sem_request`; the returned frame borrows `payload`'s bytes.
pub fn semRequestWrap(gpa: std.mem.Allocator, payload: *std.ArrayList(u8), request: u32, value: anytype) !SemRequest {
    try encodePayload(gpa, payload, value);
    return .{
        .request = request,
        .kind = @intFromEnum(@TypeOf(value).tag),
        .payload = .{ .s = payload.items },
    };
}

/// The wrapped result's inner payload as an ordinary frame (bytes
/// still borrow from the wrapper).
pub fn semResultUnwrap(result: SemResult) Frame {
    return .{ .tag = @enumFromInt(result.kind), .payload = result.payload.s };
}

// -- script evaluation (0xA0 block, capability "semantic") ------------

/// Evaluate `code` in the view's main frame. `flags` bit 0 = resolve a
/// returned promise before answering; `timeout_ms` bounds that wait
/// helper-side so a never-settling promise still produces one reply.
///
/// `max_str` is the OPTIONAL TRAILING field: how many characters of a
/// STRING inside the result the page-side serializer may emit before it
/// cuts (0 = the serializer's own default). It exists because that cut
/// used to be a silent 4000-character slice — a 40KB string came back
/// as 4046 bytes of perfectly valid JSON, so `total_chars`, `strict`
/// and `web_expand` all reported the CUT length as the whole length and
/// the rest was unreachable by any route. A cut is now MARKED
/// (`__kind:"string"` with `total_chars`) and its budget is the
/// caller's. A short payload from an older helper reads as 0.
pub const SemEval = struct {
    pub const tag: Tag = .sem_eval;
    view: u32,
    flags: u8,
    timeout_ms: u32,
    code: Text,
    max_str: u32 = 0,

    pub fn decodeFrom(payload: []const u8) !SemEval {
        var cur = Cur{ .buf = payload };
        var out: SemEval = .{
            .view = try cur.readU32(),
            .flags = try cur.readU8(),
            .timeout_ms = try cur.readU32(),
            .code = try cur.readText(),
        };
        out.max_str = cur.readU32() catch 0;
        return out;
    }
};

/// `flags` bit of `SemEval`: await a thenable result.
pub const eval_flag_await: u8 = 1;

/// `ok = 0` means the page threw (or the await timed out): `json` is
/// then `{"error":...,"stack":...}`. Otherwise `json` is the serialized
/// value, always valid JSON — never raw JS.
pub const SemEvalResult = struct {
    pub const tag: Tag = .sem_eval_result;
    view: u32,
    ok: u8,
    json: Text,
};

// -- request interception (0x80 block, capability "intercept") --------

/// Resource classes as the wire names them; mirrors `filter.RType`
/// (engine-agnostic — a Servo helper maps its own enum onto these).
pub const NetResource = enum(u8) {
    other = 0,
    document = 1,
    subdocument = 2,
    stylesheet = 3,
    script = 4,
    image = 5,
    font = 6,
    xhr = 7,
    media = 8,
    websocket = 9,
    ping = 10,
    _,
};

/// Enable/disable blocking. `view` 0 is the process-wide default; a
/// nonzero view carries the per-view (per-site, as the client sees it)
/// override. Effective = global AND per-view. The filter lists stay
/// loaded either way — disabling only stops the verdicts.
pub const InterceptSet = struct {
    pub const tag: Tag = .intercept_set;
    view: u32,
    enabled: u8,
};

/// Reload the filter set: the built-in seed list plus the helper's
/// `$XDG_CONFIG_HOME/sketerm/filters/*.txt` plus every path named
/// here (absolute paths, read helper-side). An empty list just
/// re-reads seed + config dir. No network fetching, by design.
pub const InterceptLists = struct {
    pub const tag: Tag = .intercept_lists;
    paths: []const []const u8,

    pub fn encodeTo(self: InterceptLists, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU16(gpa, out, @intCast(self.paths.len));
        for (self.paths) |p| try putStr(gpa, out, p);
    }

    /// Caller owns the returned `paths` slice (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !InterceptLists {
        var cur = Cur{ .buf = payload };
        const n = try cur.readU16();
        const paths = try gpa.alloc([]const u8, n);
        errdefer gpa.free(paths);
        for (paths) |*p| p.* = try cur.readStr();
        return .{ .paths = paths };
    }
};

/// Filter lists the client wants kept up to date.
///
/// REPLACE-ALL, like `us_script_set`: the helper reconciles its cache
/// directory against exactly this set, so dropping a subscription
/// removes its cached file too and no incremental protocol can
/// desynchronise. An empty list therefore means "subscribe to nothing",
/// and the helper makes no network request at all.
pub const InterceptSubscribe = struct {
    pub const tag: Tag = .intercept_subscribe;
    /// Refetch interval in hours; 0 keeps whatever is on disk forever.
    update_hours: u32,
    urls: []const []const u8,

    /// At most 65535 urls travel; a config with more is CLAMPED rather
    /// than wrapped. `@intCast` on an oversized length is silent
    /// truncation in ReleaseFast, which would send a short count and
    /// then a payload the reader walks off the end of.
    pub fn encodeTo(self: InterceptSubscribe, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        const n: u16 = @intCast(@min(self.urls.len, std.math.maxInt(u16)));
        try putU32(gpa, out, self.update_hours);
        try putU16(gpa, out, n);
        for (self.urls[0..n]) |u| try putStr(gpa, out, u);
    }

    /// Caller owns the returned `urls` slice (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !InterceptSubscribe {
        var cur = Cur{ .buf = payload };
        const hours = try cur.readU32();
        const n = try cur.readU16();
        const urls = try gpa.alloc([]const u8, n);
        errdefer gpa.free(urls);
        for (urls) |*u| u.* = try cur.readStr();
        return .{ .update_hours = hours, .urls = urls };
    }
};

/// Completion of one subscription reconcile batch. A reply is emitted
/// only after every fetch in that batch has completed and any accepted
/// files have been reloaded into the live filter engine.
pub const EvInterceptSubscribeDone = struct {
    pub const tag: Tag = .ev_intercept_subscribe_done;
    serial: u32,
    active: u16,
    fetched: u16,
    updated: u16,
    failed: u16,
    rules: u32,
};

pub const InterceptStatusReq = struct {
    pub const tag: Tag = .intercept_status_req;
    view: u32,
};

/// Per-view counters. Answered on `intercept_status_req` AND pushed
/// unsolicited when they change — coalesced helper-side (dirty flag,
/// one frame per poll iteration at most) so a busy page never streams
/// a frame per request. `rules` is the loaded-rule count (global).
pub const InterceptStatus = struct {
    pub const tag: Tag = .intercept_status;
    view: u32,
    enabled: u8,
    rules: u32,
    blocked: u32,
    total: u32,
};

/// Pull entries with seq > `since` from the view's bounded ring (the
/// MCP backlog rule: the log is polled, never streamed).
pub const InterceptLogReq = struct {
    pub const tag: Tag = .intercept_log_req;
    view: u32,
    since: u32,
    max: u16,
};

/// One observed request. `done` = the load finished and
/// `status`/`size`/`dur_ms` are real; a blocked entry is complete at
/// birth (it never touches the network). `size` is the received body
/// length, clamped.
pub const NetEntry = struct {
    seq: u32,
    blocked: u8,
    rtype: u8,
    done: u8,
    status: u16,
    dur_ms: u32,
    size: u32,
    method: []const u8,
    url: []const u8,
};

pub const InterceptLog = struct {
    pub const tag: Tag = .intercept_log;
    view: u32,
    /// One past the newest seq in the ring; the client's next `since`.
    next_seq: u32,
    entries: []const NetEntry,

    pub fn encodeTo(self: InterceptLog, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.next_seq);
        try putU16(gpa, out, @intCast(self.entries.len));
        for (self.entries) |e| try putNetEntry(gpa, out, e);
    }

    /// Caller owns the returned `entries` slice (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !InterceptLog {
        var cur = Cur{ .buf = payload };
        const view = try cur.readU32();
        const next_seq = try cur.readU32();
        const n = try cur.readU16();
        const entries = try gpa.alloc(NetEntry, n);
        errdefer gpa.free(entries);
        for (entries) |*e| e.* = try readNetEntry(&cur);
        return .{ .view = view, .next_seq = next_seq, .entries = entries };
    }
};

fn putNetEntry(gpa: std.mem.Allocator, out: *std.ArrayList(u8), e: NetEntry) !void {
    try putU32(gpa, out, e.seq);
    try putU8(gpa, out, e.blocked);
    try putU8(gpa, out, e.rtype);
    try putU8(gpa, out, e.done);
    try putU16(gpa, out, e.status);
    try putU32(gpa, out, e.dur_ms);
    try putU32(gpa, out, e.size);
    try putStr(gpa, out, e.method);
    try putStr(gpa, out, e.url);
}

fn readNetEntry(cur: *Cur) !NetEntry {
    var e: NetEntry = undefined;
    e.seq = try cur.readU32();
    e.blocked = try cur.readU8();
    e.rtype = try cur.readU8();
    e.done = try cur.readU8();
    e.status = try cur.readU16();
    e.dur_ms = try cur.readU32();
    e.size = try cur.readU32();
    e.method = try cur.readStr();
    e.url = try cur.readStr();
    return e;
}

/// Render log entries as one newline-free JSON object — the shared
/// presentation both clients (the GUI face's `web-network` command and
/// the headless webdrive) hand to the `web_network` MCP tool. Kept
/// here because both already depend on this module and a third copy of
/// the format is how the two would drift. Caller frees.
pub fn netLogJson(gpa: std.mem.Allocator, next_seq: u32, entries: []const NetEntry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"next_seq\":{d},\"entries\":[", .{next_seq});
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        // The legacy frame carries no reason byte; the only thing that
        // could block one of its entries is the filter engine.
        try writeNetEntryJson(w, e, if (e.blocked != 0) .filter_list else .none);
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

/// `netLogJson` over reason-carrying entries (the `net_log` frame).
pub fn netLogJson2(gpa: std.mem.Allocator, next_seq: u32, entries: []const NetEntry2) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"next_seq\":{d},\"entries\":[", .{next_seq});
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try writeNetEntryJson(w, e.entry, @enumFromInt(e.reason));
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

fn writeNetEntryJson(w: *std.Io.Writer, e: NetEntry, reason: NetReason) !void {
    const rt: NetResource = @enumFromInt(e.rtype);
    const rt_name = switch (rt) {
        .other, .document, .subdocument, .stylesheet, .script, .image, .font, .xhr, .media, .websocket, .ping => @tagName(rt),
        _ => "other",
    };
    try w.print("{{\"seq\":{d},\"blocked\":{s},\"type\":\"{s}\",\"method\":", .{
        e.seq,
        if (e.blocked != 0) "true" else "false",
        rt_name,
    });
    try std.json.Stringify.value(e.method, .{}, w);
    try w.writeAll(",\"url\":");
    try std.json.Stringify.value(e.url, .{}, w);
    if (e.blocked == 0) {
        if (e.done != 0) {
            try w.print(",\"status\":{d},\"duration_ms\":{d},\"size\":{d}", .{ e.status, e.dur_ms, e.size });
        } else {
            try w.writeAll(",\"pending\":true");
        }
    } else {
        try w.print(",\"reason\":\"{s}\"", .{reasonName(reason)});
    }
    try w.writeByte('}');
}

// -- per-view network policy (0x86 block, capability "net-policy") ----

/// Why a request was refused (or which budget latched). A wire byte AND
/// the name `web_network`/`web_policy` render — ONE vocabulary, so a
/// second naming cannot drift.
pub const NetReason = enum(u8) {
    none = 0,
    /// The EasyList-subset filter engine cancelled it (the pre-policy
    /// `blocked` flag's only meaning).
    filter_list = 1,
    top_host = 2,
    sub_host = 3,
    resource_type = 4,
    private_address = 5,
    scheme = 6,
    /// A server redirect's target failed the host test. Detected in the
    /// SAME pre-request gate: CEF re-enters `on_before_resource_load`
    /// for the redirected request with the request identifier UNCHANGED
    /// (measured on CEF 151), so a denied request whose id is already in
    /// the ring is a redirect hop.
    redirect_host = 7,
    request_cap = 8,
    byte_cap = 9,
    nav_cap = 10,
    deadline = 11,
    _,
};

/// Reasons a `denied` counter array carries, indexed by `NetReason`.
pub const NREASONS = 12;

pub fn reasonName(r: NetReason) []const u8 {
    return switch (r) {
        .none, .filter_list, .top_host, .sub_host, .resource_type, .private_address, .scheme, .redirect_host, .request_cap, .byte_cap, .nav_cap, .deadline => @tagName(r),
        _ => "unknown",
    };
}

/// Helper slots that can hold a policy (and a log ring). A client must
/// refuse a POLICIED open past this many concurrent views rather than
/// open an unpoliced one; an unpoliced view past it merely loses its
/// log, as before.
pub const MAX_POLICY_VIEWS = 32;

/// Install (or replace) the enforced policy for a view. Sent BEFORE the
/// `view_create*` naming the view — frame order on the one stream is
/// the guarantee it applies from the view's very first request; there
/// is no ack. `serial` stamps every `ev_net_policy` answering for it.
pub const NetPolicySet = struct {
    pub const tag: Tag = .net_policy_set;
    pub const flag_allow_private: u32 = 1;

    view: u32,
    serial: u32,
    flags: u32,
    /// `filter.RType`-indexed bit mask of resource classes to refuse.
    block_types: u16,
    /// `netpolicy.Scheme`-indexed bit mask of schemes to allow.
    allow_schemes: u16,
    max_requests: u32,
    max_bytes: u64,
    max_navigations: u32,
    deadline_ms: u32,
    allow_top: []const []const u8,
    allow_sub: []const []const u8,

    /// Host lists clamp at u16 (the client validates a far lower cap);
    /// a silent `@intCast` wrap would send a short count and a payload
    /// the reader walks off the end of.
    pub fn encodeTo(self: NetPolicySet, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.serial);
        try putU32(gpa, out, self.flags);
        try putU16(gpa, out, self.block_types);
        try putU16(gpa, out, self.allow_schemes);
        try putU32(gpa, out, self.max_requests);
        try putU64(gpa, out, self.max_bytes);
        try putU32(gpa, out, self.max_navigations);
        try putU32(gpa, out, self.deadline_ms);
        const nt: u16 = @intCast(@min(self.allow_top.len, std.math.maxInt(u16)));
        try putU16(gpa, out, nt);
        for (self.allow_top[0..nt]) |h| try putStr(gpa, out, h);
        const ns: u16 = @intCast(@min(self.allow_sub.len, std.math.maxInt(u16)));
        try putU16(gpa, out, ns);
        for (self.allow_sub[0..ns]) |h| try putStr(gpa, out, h);
    }

    /// Caller frees BOTH returned slices (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !NetPolicySet {
        var cur = Cur{ .buf = payload };
        var out: NetPolicySet = undefined;
        out.view = try cur.readU32();
        out.serial = try cur.readU32();
        out.flags = try cur.readU32();
        out.block_types = try cur.readU16();
        out.allow_schemes = try cur.readU16();
        out.max_requests = try cur.readU32();
        out.max_bytes = try cur.readU64();
        out.max_navigations = try cur.readU32();
        out.deadline_ms = try cur.readU32();
        const nt = try cur.readU16();
        const top = try gpa.alloc([]const u8, nt);
        errdefer gpa.free(top);
        for (top) |*h| h.* = try cur.readStr();
        const ns = try cur.readU16();
        const sub = try gpa.alloc([]const u8, ns);
        errdefer gpa.free(sub);
        for (sub) |*h| h.* = try cur.readStr();
        out.allow_top = top;
        out.allow_sub = sub;
        return out;
    }
};

/// Ask for one `ev_net_policy` for `view`.
pub const NetPolicyReq = struct {
    pub const tag: Tag = .net_policy_req;
    view: u32,
};

/// Per-view policy accounting. Answered on `net_policy_req` AND pushed
/// coalesced when it changes (at most one frame per view per poll
/// iteration, like `intercept_status`).
pub const EvNetPolicy = struct {
    pub const tag: Tag = .ev_net_policy;
    view: u32,
    serial: u32,
    active: u8,
    /// `NetReason` byte; nonzero once a budget latched.
    exhausted: u8,
    requests: u32,
    bytes: u64,
    navigations: u32,
    /// Milliseconds left of `deadline_ms`; 0 when none is set OR when
    /// it ran out (`exhausted` disambiguates).
    ms_left: u32,
    denied: [NREASONS]u32,

    pub fn encodeTo(self: EvNetPolicy, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.serial);
        try putU8(gpa, out, self.active);
        try putU8(gpa, out, self.exhausted);
        try putU32(gpa, out, self.requests);
        try putU64(gpa, out, self.bytes);
        try putU32(gpa, out, self.navigations);
        try putU32(gpa, out, self.ms_left);
        for (self.denied) |d| try putU32(gpa, out, d);
    }

    pub fn decodeFrom(payload: []const u8) !EvNetPolicy {
        var cur = Cur{ .buf = payload };
        var out: EvNetPolicy = undefined;
        out.view = try cur.readU32();
        out.serial = try cur.readU32();
        out.active = try cur.readU8();
        out.exhausted = try cur.readU8();
        out.requests = try cur.readU32();
        out.bytes = try cur.readU64();
        out.navigations = try cur.readU32();
        out.ms_left = try cur.readU32();
        for (&out.denied) |*d| d.* = try cur.readU32();
        return out;
    }
};

/// Pull reason-carrying log entries, exactly like `intercept_log_req`.
pub const NetLogReq = struct {
    pub const tag: Tag = .net_log_req;
    view: u32,
    since: u32,
    max: u16,
};

/// `NetEntry` plus the refusal reason. A NEW entry shape rather than a
/// grown `NetEntry`: `InterceptLog` decodes positionally with no
/// per-entry length, so a trailing byte there would corrupt an older
/// peer. The old pair stays for the GUI face.
pub const NetEntry2 = struct {
    entry: NetEntry,
    reason: u8,
};

pub const NetLog = struct {
    pub const tag: Tag = .net_log;
    view: u32,
    next_seq: u32,
    entries: []const NetEntry2,

    pub fn encodeTo(self: NetLog, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.next_seq);
        try putU16(gpa, out, @intCast(self.entries.len));
        for (self.entries) |e| {
            try putNetEntry(gpa, out, e.entry);
            try putU8(gpa, out, e.reason);
        }
    }

    /// Caller owns the returned `entries` slice (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !NetLog {
        var cur = Cur{ .buf = payload };
        const view = try cur.readU32();
        const next_seq = try cur.readU32();
        const n = try cur.readU16();
        const entries = try gpa.alloc(NetEntry2, n);
        errdefer gpa.free(entries);
        for (entries) |*e| {
            e.entry = try readNetEntry(&cur);
            e.reason = try cur.readU8();
        }
        return .{ .view = view, .next_seq = next_seq, .entries = entries };
    }
};

// -- devtools (0xA2 block, capability "devtools") ---------------------

/// Open the engine's inspector for `view`. The helper answers with
/// exactly one `ev_devtools_view`, whether or not it could open one.
///
/// The inspector is a NORMAL view: the helper creates it windowless,
/// gives it a view id of its own and paints, resizes, inputs and
/// destroys it through the frames every other view uses. There is
/// deliberately no debugging PORT anywhere in this design — nothing
/// listens on TCP, and the inspector is only reachable through this
/// socket.
///
/// `x`/`y` are LOGICAL coordinates in the SOURCE view to inspect
/// ("inspect element at"); both 0 means "just open it".
pub const DevToolsShow = struct {
    pub const tag: Tag = .devtools_show;
    view: u32,
    x: i32,
    y: i32,
};

/// The inspector view for `view`, or `devtools = 0` when there is no
/// view to present.
///
/// The id is allocated by the HELPER, not by the client, so it comes
/// from a range client-allocated ids never reach (see
/// `ENGINE_VIEW_BASE`). A client must treat it as an ordinary view
/// id from then on: resize it, show/hide it, and `view_destroy` it
/// when the surface presenting it goes away.
///
/// `reason` explains a zero, because the outcomes are not equivalent
/// and a client says different things about them. It is a short
/// machine-readable token, empty on success:
///   - `windowed` — the inspector IS open, in a window of the ENGINE's
///     own making, because the engine refused to render it off-screen.
///     Nothing was lost; there is simply no view to put in a pane.
///     (CEF 151 always answers this — see `Host.adoptBrowser`.)
///   - `no such view` / `no browser` / `unsupported` — nothing opened.
pub const EvDevToolsView = struct {
    pub const tag: Tag = .ev_devtools_view;
    view: u32,
    devtools: u32,
    reason: []const u8,
};

/// First view id a helper may mint ITSELF, for a view the client did
/// not ask for: an inspector, or a page popup the engine opened. Client
/// ids are allocated from 1 upwards, so the two ranges cannot collide
/// without a client opening two billion views first.
///
/// One range and one counter for both, because the property every
/// consumer actually depends on is "the helper minted this id, so do
/// not translate it" — not which feature minted it.
pub const ENGINE_VIEW_BASE: u32 = 0x4000_0000;

// -- print to PDF (0xA4 block, capability "print-pdf") ----------------

/// Render `view` to a PDF at `path`. The path is interpreted by the
/// HELPER, which is on the same machine as the client in v1; the
/// helper never creates directories and never overwrites anything the
/// engine's own writer would not.
pub const PrintPdf = struct {
    pub const tag: Tag = .print_pdf;
    view: u32,
    /// `print_flag_*` bits.
    flags: u8,
    /// `Paper` value; anything unknown means the engine default.
    paper: u8,
    path: []const u8,
};

/// `PrintPdf.flags` bits.
pub const print_flag_landscape: u8 = 1;
pub const print_flag_background: u8 = 2;

/// `PrintPdf.paper` presets, in the engine-agnostic terms every
/// engine has: a named sheet, not a driver's page-setup blob.
pub const Paper = enum(u8) { default = 0, a4 = 1, letter = 2, legal = 3, _ };

/// A sheet in INCHES — the unit both CDP's `Page.printToPDF` and
/// CEF's settings struct speak.
pub const PaperSize = struct { w: f64, h: f64 };

/// Paper size for a preset, or null for "let the engine decide".
pub fn paperInches(paper: u8) ?PaperSize {
    return switch (@as(Paper, @enumFromInt(paper))) {
        .a4 => .{ .w = 8.27, .h = 11.69 },
        .letter => .{ .w = 8.5, .h = 11.0 },
        .legal => .{ .w = 8.5, .h = 14.0 },
        else => null,
    };
}

/// The print finished (or failed). `path` echoes the request, so a
/// client with several prints in flight can tell them apart without
/// keeping a correlation id.
pub const EvPrintPdfDone = struct {
    pub const tag: Tag = .ev_print_pdf_done;
    view: u32,
    ok: u8,
    path: []const u8,
};

// -- scroll position (0xC2 block, capability "scroll") ----------------

/// Where the document is scrolled, straight from Chromium's own
/// `OnScrollOffsetChanged`. The units are whatever that callback
/// reports and they are never interpreted on the way through: the same
/// numbers go back out as `ScrollTo`, so a restore lands where the save
/// happened by construction rather than by our arithmetic agreeing with
/// the engine's.
pub const EvScroll = struct {
    pub const tag: Tag = .ev_scroll;
    view: u32,
    x: i32,
    y: i32,
};

/// Put a page back where it was. Applied after the load settles, since
/// a document still growing would clamp the offset to its current
/// height and land short.
pub const ScrollTo = struct {
    pub const tag: Tag = .scroll_to;
    view: u32,
    x: i32,
    y: i32,
};

// -- user content (0xC0 block, capability "userscripts") --------------

/// One userscript: RAW source including its `==UserScript==` block.
/// The HELPER parses the metadata (src/web/userscript.zig) — the wire
/// carries no digest of it, so parser fixes never need a wire change.
/// `id` is the client's stable identity for the script (store id).
pub const UsScript = struct {
    id: u32,
    source: Text,
};

/// Replace the COMPLETE set of enabled userscripts. The client sends
/// only enabled scripts; disabling one is re-sending the set without
/// it. Injection happens per navigation by each script's `@run-at`.
pub const UsScriptSet = struct {
    pub const tag: Tag = .us_script_set;
    scripts: []const UsScript,

    pub fn encodeTo(self: UsScriptSet, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU16(gpa, out, @intCast(self.scripts.len));
        for (self.scripts) |s| {
            try putU32(gpa, out, s.id);
            try putText(gpa, out, s.source);
        }
    }

    /// Caller owns the returned `scripts` slice (sources borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !UsScriptSet {
        var cur = Cur{ .buf = payload };
        const n = try cur.readU16();
        const scripts = try gpa.alloc(UsScript, n);
        errdefer gpa.free(scripts);
        for (scripts) |*s| {
            s.id = try cur.readU32();
            s.source = try cur.readText();
        }
        return .{ .scripts = scripts };
    }
};

/// One userstyle: user CSS scoped to `host` ("" = every page; a named
/// host also covers its subdomains). `id` is the client's identity.
pub const UsStyle = struct {
    id: u32,
    host: []const u8,
    css: Text,
};

/// Replace the COMPLETE set of enabled userstyles. Applied instantly
/// to live views whose current host matches, and injected again at
/// every navigation — a style is the user's own choice, so it is NOT
/// gated by the content-blocking shield.
pub const UsStyleSet = struct {
    pub const tag: Tag = .us_style_set;
    styles: []const UsStyle,

    pub fn encodeTo(self: UsStyleSet, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU16(gpa, out, @intCast(self.styles.len));
        for (self.styles) |s| {
            try putU32(gpa, out, s.id);
            try putStr(gpa, out, s.host);
            try putText(gpa, out, s.css);
        }
    }

    /// Caller owns the returned `styles` slice (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !UsStyleSet {
        var cur = Cur{ .buf = payload };
        const n = try cur.readU16();
        const styles = try gpa.alloc(UsStyle, n);
        errdefer gpa.free(styles);
        for (styles) |*s| {
            s.id = try cur.readU32();
            s.host = try cur.readStr();
            s.css = try cur.readText();
        }
        return .{ .styles = styles };
    }
};

// -- containers / identity contexts (0x90 block, capability "contexts") --

/// Create a per-tab identity context: its own cookie jar and cache,
/// optionally routed through `proxy`. A view created with a matching
/// `context` id then lives entirely inside it — cookies, storage and
/// egress are isolated from every other context.
///
/// `id` is CLIENT-allocated (like a view id) and must be nonzero;
/// context 0 is the shared default and is never created or destroyed.
/// Re-creating a live id is a no-op.
///
/// `ephemeral = 1` gives the context a throwaway cache directory wiped
/// when the context is destroyed (or the helper exits) — the "incognito"
/// shape. `ephemeral = 0` persists under the profile dir keyed by `name`,
/// so a named container's cookies survive a helper restart.
///
/// `proxy` is IGNORED by the helper since routes became whole helper
/// instances (`src/web/route.zig`): a route's proxy arrives as the
/// instance's `--proxy` argument and applies to every context, so a
/// per-context proxy could only re-route a container out of its
/// instance. The field stays on the wire for frame compatibility and
/// is always sent empty.
pub const ContextCreate = struct {
    pub const tag: Tag = .context_create;
    id: u32,
    ephemeral: u8,
    name: []const u8,
    proxy: []const u8,
};

/// Destroy a context and everything it held. Views still bound to it
/// keep their live browsers (CEF holds its own reference) but no new
/// view may name the id afterwards; an ephemeral context's cache dir is
/// wiped here. Destroying an unknown id is a no-op.
pub const ContextDestroy = struct {
    pub const tag: Tag = .context_destroy;
    id: u32,
};

/// A view was not created because its requested context was unavailable.
/// The helper keeps serving other views; retrying may recreate the context
/// first and then submit the same client-owned view id again.
pub const EvViewCreateFailed = struct {
    pub const tag: Tag = .ev_view_create_failed;
    view: u32,
    context: u32,
    reason: []const u8,
};

// -- cookies + site data (0xC8 block, capability "sitedata") ----------

/// Most cookies one `ev_cookies` carries. A site with more is not
/// mis-reported: `total` still counts every match, only `entries` is
/// truncated, and a panel that lists a couple of hundred rows has
/// already told the user everything a list can tell them.
pub const MAX_COOKIE_ENTRIES: usize = 200;

/// `CookieEntry.flags` bits.
pub const cookie_secure: u8 = 1;
pub const cookie_httponly: u8 = 2;
/// No expiry: the cookie dies with the session.
pub const cookie_session: u8 = 4;
/// The cookie is a DOMAIN cookie (stored with a leading dot, visible
/// to sub-domains) rather than a host cookie.
pub const cookie_domain_scoped: u8 = 8;

/// `CookieEntry.same_site` (append-only values, mirroring every
/// engine's SameSite attribute rather than any one engine's enum).
pub const SameSite = enum(u8) { unspecified = 0, none = 1, lax = 2, strict = 3, _ };

/// Ask for the cookies visible to `url` in this VIEW's cookie jar —
/// the container's jar when the view lives in one, the shared jar
/// otherwise. An empty `url` means the view's current address.
///
/// `req` is client-allocated and echoed back on `ev_cookies`, because
/// the answer is asynchronous (the engine visits its cookie store on
/// its own thread) and a panel may have moved on by the time it lands.
pub const CookiesReq = struct {
    pub const tag: Tag = .cookies_req;
    view: u32,
    req: u32,
    url: []const u8,
};

/// One cookie, WITHOUT its value (see `CAP_SITEDATA`).
pub const CookieEntry = struct {
    name: []const u8,
    domain: []const u8,
    path: []const u8,
    /// `cookie_*` bits.
    flags: u8,
    /// A `SameSite` value.
    same_site: u8,
    /// Expiry in milliseconds since the Unix epoch, 0 when
    /// `cookie_session` is set.
    expires_ms: u64,
    /// Byte length of the value that was NOT sent, so a panel can say
    /// how much is stored without ever holding it.
    value_len: u32,
};

pub const EvCookies = struct {
    pub const tag: Tag = .ev_cookies;
    view: u32,
    req: u32,
    /// 0 when the cookie store could not be reached at all, which is
    /// NOT the same as a site with no cookies.
    ok: u8,
    /// Every match, even the ones `entries` was truncated past.
    total: u32,
    entries: []const CookieEntry,

    pub fn encodeTo(self: EvCookies, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.view);
        try putU32(gpa, out, self.req);
        try putU8(gpa, out, self.ok);
        try putU32(gpa, out, self.total);
        try putU16(gpa, out, @intCast(self.entries.len));
        for (self.entries) |e| {
            try putStr(gpa, out, e.name);
            try putStr(gpa, out, e.domain);
            try putStr(gpa, out, e.path);
            try putU8(gpa, out, e.flags);
            try putU8(gpa, out, e.same_site);
            try putU64(gpa, out, e.expires_ms);
            try putU32(gpa, out, e.value_len);
        }
    }

    /// Caller owns the returned `entries` slice (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !EvCookies {
        var cur = Cur{ .buf = payload };
        const view = try cur.readU32();
        const req = try cur.readU32();
        const ok = try cur.readU8();
        const total = try cur.readU32();
        const n = try cur.readU16();
        const entries = try gpa.alloc(CookieEntry, n);
        errdefer gpa.free(entries);
        for (entries) |*e| {
            e.name = try cur.readStr();
            e.domain = try cur.readStr();
            e.path = try cur.readStr();
            e.flags = try cur.readU8();
            e.same_site = try cur.readU8();
            e.expires_ms = try cur.readU64();
            e.value_len = try cur.readU32();
        }
        return .{ .view = view, .req = req, .ok = ok, .total = total, .entries = entries };
    }
};

/// Delete every cookie visible to `url` whose name is exactly `name`.
/// Matching is by NAME, not by (name, domain, path): the panel row a
/// user clicks names one cookie as the page sees it, and two entries
/// sharing a name across scopes are one thing to delete as far as that
/// user is concerned.
pub const CookieDelete = struct {
    pub const tag: Tag = .cookie_delete;
    view: u32,
    req: u32,
    url: []const u8,
    name: []const u8,
};

/// Delete every cookie visible to `url`, host and domain cookies alike.
pub const CookiesClear = struct {
    pub const tag: Tag = .cookies_clear;
    view: u32,
    req: u32,
    url: []const u8,
};

/// `SitedataClear.what` bits. They are independent: a client asking
/// for storage alone keeps the cookies.
pub const sitedata_cookies: u32 = 1;
/// The origin's script-visible storage: localStorage, sessionStorage,
/// IndexedDB and the Cache Storage API.
pub const sitedata_storage: u32 = 2;
/// The request context's HTTP cache. NOT per-origin on any engine that
/// exposes only a whole-cache clear — see `EvSitedataDone.detail`.
pub const sitedata_cache: u32 = 4;

/// Clear site data for `url`'s origin in this view's context.
pub const SitedataClear = struct {
    pub const tag: Tag = .sitedata_clear;
    view: u32,
    req: u32,
    url: []const u8,
    what: u32,
};

/// `EvSitedataDone.kind`: which request this answers.
pub const SitedataKind = enum(u8) { cookie_delete = 0, cookies_clear = 1, sitedata_clear = 2, _ };

/// One answer for every mutating 0xC8-block frame. `removed` counts
/// cookies actually deleted (0 for a pure storage/cache clear).
///
/// `detail` is a short, machine-readable, comma-separated list of what
/// the helper could NOT do exactly as asked — empty when everything
/// was. The only value v1 produces is `cache-whole-context`, because
/// no engine here exposes a per-origin HTTP cache clear; a client
/// showing "site data cleared" is expected to read it.
pub const EvSitedataDone = struct {
    pub const tag: Tag = .ev_sitedata_done;
    view: u32,
    req: u32,
    ok: u8,
    /// A `SitedataKind` value.
    kind: u8,
    removed: u32,
    detail: []const u8,
};

/// Force every persistent context's cookie jar and storage to disk NOW
/// (capability "flush-store"). Chromium otherwise commits cookies on a
/// ~30s cadence and localStorage within ~15s, so a long-lived engine
/// that dies uncleanly loses that window; an explicit flush closes it
/// before an intentional reap or after a login worth keeping. Answered
/// by `ev_flushed` with the same token once the engine's flush
/// callbacks have all completed.
pub const FlushReq = struct {
    pub const tag: Tag = .flush_req;
    token: u32,
};

pub const EvFlushed = struct {
    pub const tag: Tag = .ev_flushed;
    token: u32,
};

// -- cross-instance cookie sync (0xE0 block, capability "cookie-sync")

/// Cookies one `ev_cookie_dump` page carries. The seed of a big jar is
/// PAGED rather than capped: a client keeps asking with the cursor the
/// previous page handed back until `more` is 0, so nothing is silently
/// missing and no single frame approaches `MAX_FRAME`.
pub const SYNC_DUMP_PAGE: usize = 128;

/// Byte budget for one page's cookie records. Reached before
/// `SYNC_DUMP_PAGE` when the jar holds large values, so a page is
/// bounded in BOTH dimensions; the cursor makes an early cut free.
pub const SYNC_DUMP_PAGE_BYTES: usize = 512 * 1024;

/// `SyncCookie.priority`. CEF counts -1/0/1, every other engine counts
/// something else; the wire counts up from zero like every other enum
/// here.
pub const CookiePriority = enum(u8) { low = 0, medium = 1, high = 2, _ };

/// Why a change was observed, so a client can tell a header-driven
/// write from one only the reconcile could see. Purely informational —
/// applying a change never depends on it.
pub const CookieCause = enum(u8) {
    /// A `Set-Cookie` response header, seen as it was saved.
    response_header = 0,
    /// The jar was found to differ from the last reconcile: a
    /// `document.cookie` / `CookieStore` write, or any other change no
    /// response header carried.
    reconcile = 1,
    _,
};

/// One cookie, WITH its value and every attribute needed to recreate
/// it byte-for-byte in another instance's jar (see `CAP_COOKIE_SYNC`
/// for why this block carries values and `CookieEntry` does not).
///
/// `creation_ms` / `last_access_ms` are carried because a faithful
/// replica keeps them, but they are NOT part of what makes a cookie
/// "changed": `last_access_ms` moves on every request the cookie is
/// sent with, so diffing on it would emit a change per page load
/// forever. `flags`/`same_site`/`priority`/`expires_ms`/`value` are.
pub const SyncCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    /// `cookie_*` bits, the same ones `CookieEntry.flags` uses.
    flags: u8,
    /// A `SameSite` value.
    same_site: u8,
    /// A `CookiePriority` value.
    priority: u8,
    /// Milliseconds since the Unix epoch; 0 when unknown.
    creation_ms: u64,
    last_access_ms: u64,
    /// 0 when `cookie_session` is set. A cookie whose expiry is in the
    /// PAST is a deletion, and `ev_cookie_change` says so in `removed`
    /// rather than making every client rediscover it.
    expires_ms: u64,

    fn encodeTo(self: SyncCookie, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putStr(gpa, out, self.name);
        try putStr(gpa, out, self.value);
        try putStr(gpa, out, self.domain);
        try putStr(gpa, out, self.path);
        try putU8(gpa, out, self.flags);
        try putU8(gpa, out, self.same_site);
        try putU8(gpa, out, self.priority);
        try putU64(gpa, out, self.creation_ms);
        try putU64(gpa, out, self.last_access_ms);
        try putU64(gpa, out, self.expires_ms);
    }

    fn readFrom(cur: *Cur) !SyncCookie {
        var ck: SyncCookie = undefined;
        ck.name = try cur.readStr();
        ck.value = try cur.readStr();
        ck.domain = try cur.readStr();
        ck.path = try cur.readStr();
        ck.flags = try cur.readU8();
        ck.same_site = try cur.readU8();
        ck.priority = try cur.readU8();
        ck.creation_ms = try cur.readU64();
        ck.last_access_ms = try cur.readU64();
        ck.expires_ms = try cur.readU64();
        return ck;
    }
};

/// Subscribe this CONNECTION to cookie-change events. Nothing streams
/// before it, for the same reason the a11y stream waits to be asked:
/// observing a jar costs a periodic full walk of it, and cookie values
/// must not cross a socket that never asked for them. Disabling stops
/// the stream and the walk again.
pub const CookieSyncEnable = struct {
    pub const tag: Tag = .cookie_sync_enable;
    enable: u8,
};

/// One observed jar change in the helper's own instance. `context` is
/// the identity context whose jar changed (0 = the shared jar). `url`
/// is the request url the write came with for a response header, and
/// a reconstructed `scheme://domain path` for a reconciled one — it is
/// what `cookie_apply` wants back as its own `url`.
pub const EvCookieChange = struct {
    pub const tag: Tag = .ev_cookie_change;
    context: u32,
    /// A `CookieCause` value.
    cause: u8,
    /// 1 when the cookie is GONE (deleted, or expired in the past).
    /// Its `cookie` fields still identify what to remove.
    removed: u8,
    url: []const u8,
    cookie: SyncCookie,

    pub fn encodeTo(self: EvCookieChange, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.context);
        try putU8(gpa, out, self.cause);
        try putU8(gpa, out, self.removed);
        try putStr(gpa, out, self.url);
        try self.cookie.encodeTo(gpa, out);
    }

    pub fn decodeFrom(payload: []const u8) !EvCookieChange {
        var cur = Cur{ .buf = payload };
        const context = try cur.readU32();
        const cause = try cur.readU8();
        const removed = try cur.readU8();
        const url = try cur.readStr();
        return .{
            .context = context,
            .cause = cause,
            .removed = removed,
            .url = url,
            .cookie = try SyncCookie.readFrom(&cur),
        };
    }
};

/// Write one cookie into `context`'s jar, or remove it when `remove`
/// is 1. Answered by `ev_cookie_apply_done` with the same `req`.
///
/// A cookie applied this way must NOT come back as an
/// `ev_cookie_change`, or two instances ping-pong forever. That is
/// structural in the helper, not a suppression window: the reconcile
/// emits on a DIFF against its shadow of the jar, and an apply updates
/// that shadow as part of writing the jar, so there is no diff left to
/// emit. Nothing here has to be timed.
pub const CookieApply = struct {
    pub const tag: Tag = .cookie_apply;
    req: u32,
    context: u32,
    remove: u8,
    url: []const u8,
    cookie: SyncCookie,

    pub fn encodeTo(self: CookieApply, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.req);
        try putU32(gpa, out, self.context);
        try putU8(gpa, out, self.remove);
        try putStr(gpa, out, self.url);
        try self.cookie.encodeTo(gpa, out);
    }

    pub fn decodeFrom(payload: []const u8) !CookieApply {
        var cur = Cur{ .buf = payload };
        const req = try cur.readU32();
        const context = try cur.readU32();
        const remove = try cur.readU8();
        const url = try cur.readStr();
        return .{
            .req = req,
            .context = context,
            .remove = remove,
            .url = url,
            .cookie = try SyncCookie.readFrom(&cur),
        };
    }
};

/// The correlated answer to one `cookie_apply`. `reason` is empty on
/// success and a short machine-readable token otherwise
/// (`no-context`, `bad-url`, `engine-refused`, `set-failed`) — a
/// silently dropped cookie is a login that does not follow the user,
/// so every apply is answered exactly once.
pub const EvCookieApplyDone = struct {
    pub const tag: Tag = .ev_cookie_apply_done;
    req: u32,
    context: u32,
    ok: u8,
    reason: []const u8,
};

/// Ask for a page of every cookie in `context`'s jar, so a helper that
/// just started can seed itself from a running one. `cursor` is 0 for
/// the first page and afterwards whatever the previous page's
/// `next_cursor` said.
pub const CookieDumpReq = struct {
    pub const tag: Tag = .cookie_dump_req;
    req: u32,
    context: u32,
    cursor: u32,
};

/// One page of a jar dump.
///
/// `total` counts the whole jar as this walk saw it, so a client can
/// show progress; it is not a promise that the jar held still. The
/// cursor is an INDEX into the engine's own visit order (longest path,
/// then earliest creation), so a cookie written between two pages can
/// shift the tail by one — a seed is a starting point that the change
/// stream then keeps current, never a transactional snapshot, and
/// saying so here is cheaper than a snapshot nothing can provide.
pub const EvCookieDump = struct {
    pub const tag: Tag = .ev_cookie_dump;
    req: u32,
    context: u32,
    /// 0 when the cookie store could not be reached at all.
    ok: u8,
    /// The cursor this page answers.
    cursor: u32,
    /// Pass this as the next request's `cursor` while `more` is 1.
    next_cursor: u32,
    more: u8,
    total: u32,
    cookies: []const SyncCookie,

    pub fn encodeTo(self: EvCookieDump, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try putU32(gpa, out, self.req);
        try putU32(gpa, out, self.context);
        try putU8(gpa, out, self.ok);
        try putU32(gpa, out, self.cursor);
        try putU32(gpa, out, self.next_cursor);
        try putU8(gpa, out, self.more);
        try putU32(gpa, out, self.total);
        try putU16(gpa, out, @intCast(self.cookies.len));
        for (self.cookies) |ck| try ck.encodeTo(gpa, out);
    }

    /// Caller owns the returned `cookies` slice (strings borrow from
    /// `payload`).
    pub fn decodeAlloc(payload: []const u8, gpa: std.mem.Allocator) !EvCookieDump {
        var cur = Cur{ .buf = payload };
        const req = try cur.readU32();
        const context = try cur.readU32();
        const ok = try cur.readU8();
        const cursor = try cur.readU32();
        const next_cursor = try cur.readU32();
        const more = try cur.readU8();
        const total = try cur.readU32();
        const n = try cur.readU16();
        const cookies = try gpa.alloc(SyncCookie, n);
        errdefer gpa.free(cookies);
        for (cookies) |*ck| ck.* = try SyncCookie.readFrom(&cur);
        return .{
            .req = req,
            .context = context,
            .ok = ok,
            .cursor = cursor,
            .next_cursor = next_cursor,
            .more = more,
            .total = total,
            .cookies = cookies,
        };
    }
};

// -- cross-connection observation (0xF0 block, capability "observe") --
//
// See CAP_OBSERVE for the model. `target` fields carry ENGINE-GLOBAL
// view ids verbatim (they name another connection's view, which no
// window arithmetic of the observer's could express); `view` fields
// are the observer's own alias ids and translate like every other
// view-naming field.

/// Client -> helper: start (1) or stop (0) announcing other
/// connections' pages. Starting replays every current one as
/// `ev_observe_view{state = present}`; stopping ends the announcements
/// only — live subscriptions are unaffected.
pub const ObserveEnable = struct {
    pub const tag: Tag = .observe_enable;
    enable: u8,
};

/// `ObserveView.state` values.
pub const observe_view_gone: u8 = 0;
pub const observe_view_present: u8 = 1;

/// Helper -> client: a page of another connection exists (`present`)
/// or was destroyed (`gone`). `owner` is the owning connection's id
/// (stable for its life, never reused), `opener` the target id of the
/// page that opened this one as a popup (0 otherwise), `w`/`h` the
/// LOGICAL size and `scale_x1000` the DPR the page is laid out at.
/// `url`/`title` are what the helper knows at that moment; a subscriber
/// receives every later change as `ev_nav_state`/`ev_title`.
pub const EvObserveView = struct {
    pub const tag: Tag = .ev_observe_view;
    target: u32,
    owner: u32,
    state: u8,
    opener: u32,
    w: u16,
    h: u16,
    scale_x1000: u16,
    url: []const u8,
    title: []const u8,
};

/// Client -> helper: observe `target` under the observer-minted alias
/// `view` (client namespace, like `view_create`'s id; it must not name
/// a view of the observer's own). `control = 1` asks to drive it.
/// Answered by exactly one `ev_observe_state`.
pub const ObserveSubscribe = struct {
    pub const tag: Tag = .observe_subscribe;
    view: u32,
    target: u32,
    control: u8,
};

/// Client -> helper: change the lease of an existing alias. Answered
/// by one `ev_observe_state` (`state = subscribed` with the new lease,
/// or `refused` for an unknown alias).
pub const ObserveControl = struct {
    pub const tag: Tag = .observe_control;
    view: u32,
    control: u8,
};

/// `EvObserveState.state` values.
pub const observe_refused: u8 = 0;
pub const observe_subscribed: u8 = 1;
/// The target was destroyed (or its owner left): the alias is gone
/// and nothing further arrives under it.
pub const observe_ended: u8 = 2;

/// Helper -> client: the alias `view`'s subscription state. Sent once
/// per `observe_subscribe`/`observe_control`, again whenever the
/// target's geometry changes (so the observer can keep its
/// letterbox right), and finally as `ended`. `w`/`h`/`scale_x1000`
/// describe the TARGET's logical size and DPR; `reason` explains a
/// refusal or an ending in words.
pub const EvObserveState = struct {
    pub const tag: Tag = .ev_observe_state;
    view: u32,
    target: u32,
    state: u8,
    control: u8,
    w: u16,
    h: u16,
    scale_x1000: u16,
    reason: []const u8,
};

test "round-trip: observe frames" {
    try roundTrip(ObserveEnable, .{ .enable = 1 });
    try roundTrip(EvObserveView, .{
        .target = 0x0010_0003,
        .owner = 1,
        .state = observe_view_present,
        .opener = 0x0010_0001,
        .w = 1024,
        .h = 768,
        .scale_x1000 = 1500,
        .url = "https://example.com/",
        .title = "Example",
    });
    try roundTrip(ObserveSubscribe, .{ .view = 9, .target = 0x0010_0003, .control = 1 });
    try roundTrip(ObserveControl, .{ .view = 9, .control = 0 });
    try roundTrip(EvObserveState, .{
        .view = 9,
        .target = 0x0010_0003,
        .state = observe_ended,
        .control = 0,
        .w = 1024,
        .h = 768,
        .scale_x1000 = 1000,
        .reason = "the owner destroyed the view",
    });
}

test "observe tags occupy the 0xF0 block and leave 0xE6-0xEF free" {
    try std.testing.expectEqual(@as(u8, 0xF0), @intFromEnum(Tag.observe_enable));
    try std.testing.expectEqual(@as(u8, 0xF1), @intFromEnum(Tag.ev_observe_view));
    try std.testing.expectEqual(@as(u8, 0xF2), @intFromEnum(Tag.observe_subscribe));
    try std.testing.expectEqual(@as(u8, 0xF3), @intFromEnum(Tag.ev_observe_state));
    try std.testing.expectEqual(@as(u8, 0xF4), @intFromEnum(Tag.observe_control));
    try std.testing.expect(!@as(Tag, @enumFromInt(0xE6)).known());
    try std.testing.expect(!@as(Tag, @enumFromInt(0xEF)).known());
}

// -- WebExtensions (0xB0 block, capability "webext") ------------------
//
// The GUI owns the extension FILES (it installs an unpacked dir or an
// XPI it unpacks under `$XDG_DATA_HOME/sketerm/webext/<id>/`, lists them
// and removes them); the helper LOADS those directories, hosts the
// background page and content scripts, and persists per-extension
// storage. These frames carry the load/enable/remove commands and the
// state reports — everything else (content<->background messaging,
// storage round trips, the browser.* dispatch) stays entirely inside
// the helper, reusing its existing renderer<->browser bridge.

/// Load-and-enable, or disable, one extension. `dir` is the absolute
/// path of its unpacked directory (helper and client are the same
/// machine in v1); the helper parses `dir/manifest.json`, and on
/// `enabled = 1` spins up its background page and arms its content
/// scripts, on `enabled = 0` tears them down but keeps the record.
/// Sending it again with a changed `enabled` toggles in place.
pub const WebextSet = struct {
    pub const tag: Tag = .webext_set;
    /// Stable extension id (the GUI's, derived or from the manifest).
    id: []const u8,
    dir: []const u8,
    enabled: u8,
};

/// Unload an extension entirely: its background page and content
/// scripts go, and the helper forgets the id. The GUI deletes the files
/// separately; a `webext_remove` for an unknown id is a no-op.
pub const WebextRemove = struct {
    pub const tag: Tag = .webext_remove;
    id: []const u8,
};

/// Ask the helper to (re)report every loaded extension's state — one
/// `ev_webext_state` per extension. A client sends it after the
/// handshake to learn what a durable helper already had loaded.
pub const WebextListReq = struct {
    pub const tag: Tag = .webext_list_req;
};

/// One extension's state, pushed on every change and in answer to
/// `webext_list_req`. `ok = 0` means loading failed and `err` says why
/// (a bad manifest, a missing file); `enabled` reflects the last
/// `webext_set`. `name`/`version` come from the parsed manifest, empty
/// when it would not parse.
pub const EvWebextState = struct {
    pub const tag: Tag = .ev_webext_state;
    id: []const u8,
    name: []const u8,
    version: []const u8,
    enabled: u8,
    ok: u8,
    err: []const u8,
};

/// Validate a staged package without changing the live extension. On success
/// the helper quiesces the old instance before acknowledging the request.
pub const WebextInstallPrepare = struct {
    pub const tag: Tag = .webext_install_prepare;
    req: u32,
    id: []const u8,
    dir: []const u8,
    version: []const u8,
};

pub const EvWebextInstallPrepared = struct {
    pub const tag: Tag = .ev_webext_install_prepared;
    req: u32,
    id: []const u8,
    ok: u8,
    err: []const u8,
};

/// Load the live path after the GUI atomically installed the prepared tree.
pub const WebextInstallCommit = struct {
    pub const tag: Tag = .webext_install_commit;
    req: u32,
    id: []const u8,
    dir: []const u8,
    version: []const u8,
    enabled: u8,
};

pub const EvWebextInstallCommitted = struct {
    pub const tag: Tag = .ev_webext_install_committed;
    req: u32,
    id: []const u8,
    ok: u8,
    err: []const u8,
};

/// Ask for one `ev_webext_wreq_stats` per extension that has ever
/// registered a blocking-webRequest listener.
pub const WebextWreqStatsReq = struct {
    pub const tag: Tag = .webext_wreq_stats_req;
};

/// Blocking-webRequest counters for one extension. This is the ONLY
/// thing the held-request path sends to a client: the decision itself
/// never crosses this socket (see the Tag block's note).
///
/// `failed_open` is the number the operator should watch — every one of
/// them is a request that was HELD and then let through unfiltered
/// because the extension could not answer (timed out, background page
/// gone, extension removed mid-flight). A fail-open is a deliberate
/// policy, not an error: a broken extension must not be able to wedge
/// the browser.
pub const EvWebextWreqStats = struct {
    pub const tag: Tag = .ev_webext_wreq_stats;
    id: []const u8,
    /// Requests a RequestFilter matched (blocking or observational).
    matched: u32,
    /// Requests actually HELD waiting for a blocking decision.
    held: u32,
    cancelled: u32,
    redirected: u32,
    /// Held requests whose decision changed request headers.
    headers_modified: u32,
    /// `onHeadersReceived` decisions the engine could not apply — see
    /// the measured limitation in `src/web/CLAUDE.md`.
    headers_received_dropped: u32,
    timed_out: u32,
    failed_open: u32,
    /// Round-trip latency of the held decision, in MICROSECONDS,
    /// measured helper-side from the hold to its answer.
    us_p50: u32,
    us_p95: u32,
    us_max: u32,
    samples: u32,
};

/// The client's WHOLE tab list, replacing whatever the helper held.
///
/// REPLACE-ALL, like `us_script_set`, and for the same reason: the
/// helper DIFFS it to synthesise MV2's `onCreated`/`onUpdated`/
/// `onRemoved`/`onActivated`, so the events an extension sees are
/// derived from state rather than from a sequence a dropped frame could
/// desynchronise. Post it whenever the tab set changes.
///
/// The payload is a JSON array rather than a repeated binary record,
/// because this wire has no repeated-field encoding and adding one for a
/// frame sent a few times a minute would be the wrong trade. Each
/// element is
/// `{id, view, windowId, index, active, focusedWindow, url, title, loading}`;
/// `view` is the helper VIEW rendering that tab, or 0 for a tab that
/// shows no web view at all (a terminal tab), which is how
/// `sender.tab` is resolved.
pub const WebextTabs = struct {
    pub const tag: Tag = .webext_tabs;
    tabs_json: []const u8,
};

/// Replace-all action list for one active client view. `actions_json` is
/// an array of `{id,title,icon,badge,enabled,popup}` objects.
pub const EvWebextActions = struct {
    pub const tag: Tag = .ev_webext_actions;
    view: u32,
    actions_json: []const u8,
};

/// A trusted GTK toolbar click. The helper validates the extension and
/// active mirrored tab before opening its popup or firing onClicked.
pub const WebextActionActivate = struct {
    pub const tag: Tag = .webext_action_activate;
    view: u32,
    id: []const u8,
    popup_view: u32,
    w: u16,
    h: u16,
    scale_x1000: u16,
};

/// Popup lifecycle. `state` is `opened`, `closed` or `error`; `detail`
/// names the extension-page URL on open and the failure on error.
pub const EvWebextPopup = struct {
    pub const tag: Tag = .ev_webext_popup;
    owner_view: u32,
    popup_view: u32,
    state: u8,
    detail: []const u8,
};

/// An extension page called `browserAction.openPopup()`. The GUI owns
/// the native toolbar/popover and performs the same activation path as
/// a trusted toolbar click. `req` is helper-minted correlation; the
/// extension call remains pending until `webext_open_popup_result`.
pub const EvWebextOpenPopup = struct {
    pub const tag: Tag = .ev_webext_open_popup;
    view: u32,
    id: []const u8,
    req: u32,
};

/// The GUI attempted a programmatic popup request. `ok` means the
/// native toolbar created its popover and posted the ordinary trusted
/// activation; otherwise `detail` explains why no popup was created.
pub const WebextOpenPopupResult = struct {
    pub const tag: Tag = .webext_open_popup_result;
    view: u32,
    id: []const u8,
    req: u32,
    ok: u8,
    detail: []const u8,
};

pub const webext_popup_opened: u8 = 1;
pub const webext_popup_closed: u8 = 2;
pub const webext_popup_error: u8 = 3;

/// First client-minted extension popup id. Background pages start at
/// 0x50000000, so this range cannot alias helper-owned hidden views.
pub const WEBEXT_POPUP_VIEW_BASE: u32 = 0x6000_0000;

// ---------------------------------------------------------------------
// Primitive writers
// ---------------------------------------------------------------------

fn putU8(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u8) !void {
    try out.append(gpa, v);
}

fn putU16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
}

fn putU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

fn putU64(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u64) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, v)));
}

fn putI32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: i32) !void {
    try putU32(gpa, out, @bitCast(v));
}

fn putStr(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len > std.math.maxInt(u16)) return error.StringTooLong;
    try putU16(gpa, out, @intCast(s.len));
    try out.appendSlice(gpa, s);
}

fn putText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), t: Text) !void {
    if (t.s.len > MAX_FRAME) return error.FrameTooLarge;
    try putU32(gpa, out, @intCast(t.s.len));
    try out.appendSlice(gpa, t.s);
}

// ---------------------------------------------------------------------
// Primitive reader
// ---------------------------------------------------------------------

/// Payload cursor. Every accessor fails with `error.Truncated` rather
/// than reading past the frame, so a malformed peer cannot walk memory.
pub const Cur = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn readU8(self: *Cur) !u8 {
        if (self.pos + 1 > self.buf.len) return error.Truncated;
        defer self.pos += 1;
        return self.buf[self.pos];
    }

    pub fn readU16(self: *Cur) !u16 {
        if (self.pos + 2 > self.buf.len) return error.Truncated;
        defer self.pos += 2;
        return std.mem.readInt(u16, self.buf[self.pos..][0..2], .little);
    }

    pub fn readU32(self: *Cur) !u32 {
        if (self.pos + 4 > self.buf.len) return error.Truncated;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
    }

    pub fn readU64(self: *Cur) !u64 {
        if (self.pos + 8 > self.buf.len) return error.Truncated;
        defer self.pos += 8;
        return std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
    }

    pub fn readI32(self: *Cur) !i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readStr(self: *Cur) ![]const u8 {
        const n = try self.readU16();
        if (self.pos + n > self.buf.len) return error.Truncated;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }

    pub fn readText(self: *Cur) !Text {
        const n = try self.readU32();
        if (self.pos + n > self.buf.len) return error.Truncated;
        defer self.pos += n;
        return .{ .s = self.buf[self.pos..][0..n] };
    }
};

// ---------------------------------------------------------------------
// Generic frame (de)serialization
// ---------------------------------------------------------------------

/// Append one complete frame ([len:u32][tag:u8][payload]) for `value`.
pub fn encode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const T = @TypeOf(value);
    const start = out.items.len;
    try out.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    try putU8(gpa, out, @intFromEnum(T.tag));
    try encodePayload(gpa, out, value);
    const len = out.items.len - start - 4;
    if (len > MAX_FRAME) return error.FrameTooLarge;
    std.mem.writeInt(u32, out.items[start..][0..4], @intCast(len), .little);
}

/// Append only a value's payload, for append-only wrapper frames whose
/// inner tag is carried separately.
pub fn encodePayload(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const T = @TypeOf(value);
    if (@hasDecl(T, "encodeTo")) {
        try value.encodeTo(gpa, out);
    } else {
        inline for (std.meta.fields(T)) |f| {
            const v = @field(value, f.name);
            switch (f.type) {
                u8 => try putU8(gpa, out, v),
                u16 => try putU16(gpa, out, v),
                u32 => try putU32(gpa, out, v),
                u64 => try putU64(gpa, out, v),
                i32 => try putI32(gpa, out, v),
                []const u8 => try putStr(gpa, out, v),
                Text => try putText(gpa, out, v),
                else => @compileError("unsupported wire field type " ++ @typeName(f.type)),
            }
        }
    }
}

/// Decode a payload into `T`. String fields BORROW from `payload`.
/// Types with list fields provide `decodeAlloc` instead; a type with a
/// `decodeFrom` (a bounded array, or an optional trailing field) owns
/// its own reader and is routed to it, so callers never have to know
/// which shape a frame has.
pub fn decode(comptime T: type, payload: []const u8) !T {
    if (@hasDecl(T, "decodeAlloc")) @compileError(@typeName(T) ++ " needs decodeAlloc");
    if (@hasDecl(T, "decodeFrom")) return T.decodeFrom(payload);
    var cur = Cur{ .buf = payload };
    var out: T = undefined;
    inline for (std.meta.fields(T)) |f| {
        @field(out, f.name) = switch (f.type) {
            u8 => try cur.readU8(),
            u16 => try cur.readU16(),
            u32 => try cur.readU32(),
            u64 => try cur.readU64(),
            i32 => try cur.readI32(),
            []const u8 => try cur.readStr(),
            Text => try cur.readText(),
            else => @compileError("unsupported wire field type " ++ @typeName(f.type)),
        };
    }
    return out;
}

// ---------------------------------------------------------------------
// Stream framing
// ---------------------------------------------------------------------

pub const Frame = struct { tag: Tag, payload: []const u8 };

/// Length-prefix framer over an accumulated byte stream.
///
/// `next` returns null when the buffer holds no COMPLETE frame yet, and
/// silently drops frames whose tag this build does not know (the
/// append-only rule: a newer peer's extra frames must cost nothing).
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn next(self: *Reader) !?Frame {
        while (true) {
            if (self.pos + 4 > self.buf.len) return null;
            const len = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
            if (len == 0 or len > MAX_FRAME) return error.BadFrame;
            if (self.pos + 4 + len > self.buf.len) return null;
            const tag: Tag = @enumFromInt(self.buf[self.pos + 4]);
            const payload = self.buf[self.pos + 5 ..][0 .. len - 1];
            self.pos += 4 + len;
            if (!tag.known()) continue;
            return .{ .tag = tag, .payload = payload };
        }
    }

    /// Bytes consumed so far — what the caller may drop from its
    /// accumulation buffer.
    pub fn consumed(self: Reader) usize {
        return self.pos;
    }
};

// ---------------------------------------------------------------------
// Outbox
// ---------------------------------------------------------------------

/// One queued message: encoded frame bytes plus the descriptors to
/// attach with it (SCM_RIGHTS — one memfd for `frames-shm`, one per
/// plane for `frames-dmabuf`). Pure data: the fds are integers here and
/// sending them is the server's job.
pub const Message = struct {
    bytes: []u8,
    fds: [MAX_PLANES]i32 = @splat(-1),
    nfds: u8 = 0,

    pub fn one(bytes: []u8, fd: ?i32) Message {
        var m = Message{ .bytes = bytes };
        if (fd) |f| {
            m.fds[0] = f;
            m.nfds = 1;
        }
        return m;
    }

    /// The descriptors still attached, as a slice.
    pub fn fdSlice(self: *const Message) []const i32 {
        return self.fds[0..self.nfds];
    }
};

/// FIFO of messages awaiting transmission, with a partial-write cursor.
///
/// It owns the bytes and, until sent, the fd: `deinit` closes nothing,
/// so a caller that abandons an outbox with pending fds must drain them.
pub const Outbox = struct {
    gpa: std.mem.Allocator,
    queue: std.ArrayList(Message) = .empty,
    head: usize = 0,
    sent: usize = 0,
    /// Bytes of every queued-but-undelivered message, the wedged-client
    /// signal: frames cannot be dropped mid-protocol, so a reader that
    /// stopped consuming is cut off on this number instead.
    bytes: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Outbox {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Outbox) void {
        for (self.queue.items[self.head..]) |m| self.gpa.free(m.bytes);
        self.queue.deinit(self.gpa);
    }

    /// Queue `value` as a frame, optionally carrying `fd`.
    pub fn post(self: *Outbox, value: anytype, fd: ?i32) !void {
        return self.postFds(value, if (fd) |f| &[_]i32{f} else &.{});
    }

    /// Queue `value` carrying every descriptor in `fds` (SCM_RIGHTS
    /// takes them as one array, so they ride the same message).
    pub fn postFds(self: *Outbox, value: anytype, fds: []const i32) !void {
        if (fds.len > MAX_PLANES) return error.TooManyFds;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);
        try encode(self.gpa, &buf, value);
        var m = Message{ .bytes = try buf.toOwnedSlice(self.gpa), .nfds = @intCast(fds.len) };
        for (fds, 0..) |f, i| m.fds[i] = f;
        try self.queue.append(self.gpa, m);
        self.bytes += m.bytes.len;
    }

    pub fn empty(self: *const Outbox) bool {
        return self.head >= self.queue.items.len;
    }

    /// Messages still awaiting transmission — the backpressure signal
    /// for a producer whose frames pin descriptors.
    pub fn pending(self: *const Outbox) usize {
        return self.queue.items.len - self.head;
    }

    /// The unsent remainder of the front message, or null when drained.
    /// Descriptors ride the FIRST write only; a partial write must not
    /// send them twice.
    pub fn front(self: *const Outbox) ?Message {
        if (self.empty()) return null;
        const m = self.queue.items[self.head];
        var out = Message{ .bytes = m.bytes[self.sent..] };
        if (self.sent == 0) {
            out.fds = m.fds;
            out.nfds = m.nfds;
        }
        return out;
    }

    /// Record `n` bytes of the front message as written.
    pub fn advance(self: *Outbox, n: usize) void {
        if (self.empty()) return;
        const m = self.queue.items[self.head];
        self.sent += n;
        if (self.sent < m.bytes.len) return;
        self.bytes -= m.bytes.len;
        self.gpa.free(m.bytes);
        self.sent = 0;
        self.head += 1;
        if (self.empty()) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
        }
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

fn roundTrip(comptime T: type, value: T) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, value);

    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(T.tag, frame.tag);
    try std.testing.expectEqual(buf.items.len, r.consumed());
    const got = try decode(T, frame.payload);
    inline for (std.meta.fields(T)) |f| {
        if (f.type == []const u8) {
            try std.testing.expectEqualStrings(@field(value, f.name), @field(got, f.name));
        } else if (f.type == Text) {
            try std.testing.expectEqualStrings(@field(value, f.name).s, @field(got, f.name).s);
        } else {
            try std.testing.expectEqual(@field(value, f.name), @field(got, f.name));
        }
    }
}

test "round-trip: scalar and string frames" {
    try roundTrip(Hello, .{ .proto = 1, .client_name = "sketerm-gui" });
    try roundTrip(ViewCreate, .{ .view = 7, .w = 800, .h = 600, .scale_x1000 = 1000, .context = 0 });
    try roundTrip(ViewCreateUrl, .{
        .view = 7,
        .w = 800,
        .h = 600,
        .scale_x1000 = 1000,
        .context = 0,
        .url = "https://example.com/",
    });
    try roundTrip(ViewDestroy, .{ .view = 7 });
    try roundTrip(ViewDiscard, .{ .view = 7 });
    try roundTrip(ViewResize, .{ .view = 7, .w = 1024, .h = 768, .scale_x1000 = 1500 });
    try roundTrip(ViewShow, .{ .view = 7 });
    try roundTrip(ViewHide, .{ .view = 7 });
    try roundTrip(Navigate, .{ .view = 7, .url = "https://example.com/" });
    try roundTrip(NavAction, .{ .view = 7, .action = 2 });
    try roundTrip(InputPointer, .{
        .view = 7,
        .kind = 1,
        .x = -3,
        .y = 400,
        .button = 0,
        .clicks = 2,
        .mods = mod_ctrl | mod_shift,
    });
    try roundTrip(InputScroll, .{ .view = 7, .x = 10, .y = 20, .dx = 0, .dy = -120, .mods = 0 });
    try roundTrip(InputKey, .{
        .view = 7,
        .kind = 0,
        .keyval = 0xff0d,
        .keycode = 36,
        .mods = 0,
        .text = "",
    });
    try roundTrip(InputIme, .{ .view = 7, .kind = 1, .text = "ê", .cursor = 1 });
    // `Text`, not `str`: a paste is document-sized, and a `str`
    // overflow is swallowed silently by the client's `post`.
    try roundTrip(InputPaste, .{ .view = 7, .text = .{ .s = "hello\nworld" } });
    try roundTrip(ClipboardRead, .{ .view = 7, .seq = 3, .mode = 1 });
    try roundTrip(EvClipboardText, .{ .view = 7, .seq = 3, .text = .{ .s = "selected ê" } });
    try roundTrip(PopupPolicySet, .{ .view = 0, .mode = popup_mode_allow });
    try roundTrip(EvPagePopup, .{
        .owner_view = 7,
        .popup_view = ENGINE_VIEW_BASE + 2,
        .state = page_popup_opened,
        .disposition = 2,
        .user_gesture = 1,
        .chromeless = 1,
        .w = 400,
        .h = 500,
        .url = "https://accounts.example/oauth",
        .frame_name = "gischan1",
    });
    try roundTrip(InputFocus, .{ .view = 7, .focused = 1 });
    try roundTrip(FrameBuffer, .{ .view = 7, .buf_id = 3, .w = 800, .h = 600, .stride = 3200 });
    try roundTrip(FrameRelease, .{ .view = 7, .buf_id = 2 });
    try roundTrip(FrameRequest, .{ .view = 7, .flags = 0 });
    try roundTrip(ViewMaxFps, .{ .view = 7, .fps = 144 });
    try roundTrip(EvLoad, .{ .view = 7, .state = 2, .url = "about:blank" });
    try roundTrip(EvLoadError, .{ .view = 7, .code = -105, .url = "http://x/", .msg = "NAME_NOT_RESOLVED" });
    try roundTrip(EvLoadRetry, .{ .view = 7, .code = -21, .url = "http://x/", .msg = "ERR_NETWORK_CHANGED" });
    try roundTrip(EvTitle, .{ .view = 7, .title = "hello" });
    try roundTrip(EvFavicon, .{ .view = 7, .url = "http://x/favicon.ico" });
    try roundTrip(EvScroll, .{ .view = 3, .x = 0, .y = 1840 });
    try roundTrip(ScrollTo, .{ .view = 3, .x = 12, .y = -1 });
    try roundTrip(EvNavState, .{ .view = 7, .can_back = 1, .can_fwd = 0, .loading = 0, .url = "http://x/" });
    try roundTrip(EvPopupRequest, .{ .view = 7, .url = "http://x/p", .disposition = 0, .user_gesture = 1 });
    try roundTrip(EvPopupRequest, .{ .view = 7, .url = "http://x/p", .disposition = 2, .user_gesture = 0 });
    try roundTrip(EvCursor, .{ .view = 7, .cursor = 1 });
    try roundTrip(EvConsole, .{ .view = 7, .level = 2, .msg = "boom" });
    try roundTrip(EvCrashed, .{ .view = 7 });
    try roundTrip(Find, .{ .view = 7, .forward = 1, .match_case = 0, .find_next = 0, .text = "needle" });
    try roundTrip(FindStop, .{ .view = 7, .clear_selection = 1 });
    try roundTrip(SetZoom, .{ .view = 7, .level_x100 = -300 });
    try roundTrip(EvFindResult, .{ .view = 7, .count = 12, .active = 3, .final = 1 });
    try roundTrip(EvContextMenu, .{
        .view = 7,
        .x = 40,
        .y = 220,
        .flags = ctx_flag_link,
        .link_url = "https://example.com/a",
    });
    try roundTrip(EvContextMenu, .{
        .view = 7,
        .x = 40,
        .y = 220,
        .flags = ctx_flag_link | ctx_flag_image | ctx_flag_selection,
        .link_url = "https://example.com/a",
        .src_url = "https://example.com/a.png",
        .selection_text = "picked words",
    });
}

test "EvContextMenu: optional trailing fields absent reads as empty" {
    // A pre-extension helper's payload ends after link_url; the
    // decoder must answer "" for both trailing strings, never
    // error.Truncated (the optional-trailing-field rule).
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try putU32(gpa, &out, 7);
    try putI32(gpa, &out, 40);
    try putI32(gpa, &out, 220);
    try putU8(gpa, &out, ctx_flag_link);
    try putStr(gpa, &out, "https://example.com/a");
    const ev = try EvContextMenu.decodeFrom(out.items);
    try std.testing.expectEqualStrings("https://example.com/a", ev.link_url);
    try std.testing.expectEqualStrings("", ev.src_url);
    try std.testing.expectEqualStrings("", ev.selection_text);
}

test "round-trip: tls and permission frames" {
    try roundTrip(EvCertError, .{
        .view = 7,
        .code = -202,
        .url = "https://self-signed.example/",
        .host = "self-signed.example",
        .msg = "CERT_AUTHORITY_INVALID",
        .subject = "self-signed.example",
        .issuer = "self-signed.example",
        .fingerprint = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    });
    try roundTrip(CertDecision, .{ .view = 7, .proceed = 1 });
    try roundTrip(EvPermission, .{
        .view = 7,
        .prompt = 0xdead_beef_0000_0001,
        .origin = "https://example.com",
        .types = perm_camera | perm_microphone,
    });
    try roundTrip(PermissionDecision, .{ .view = 7, .prompt = 0xdead_beef_0000_0001, .allow = 0 });
}

test "round-trip: download frames" {
    try roundTrip(DownloadDecide, .{ .view = 7, .id = 41, .path = "report.pdf", .stage = 1 });
    try roundTrip(EvDownloadProgress, .{ .view = 7, .id = 41, .received = 3, .total = 0, .done = 0, .failed = 1, .path = "/tmp/sketerm-webdl-test", .interrupt_reason = 3 });
    try roundTrip(EvDownloadOffer, .{
        .view = 7,
        .id = 41,
        .total = 5_000_000_000,
        .url = "https://example.com/big.iso",
        .name = "big.iso",
        .mime = "application/octet-stream",
    });
    try roundTrip(EvDownloadOffer, .{ .view = 7, .id = 42, .total = 0, .url = "data:,x", .name = "x", .mime = "" });
    try roundTrip(DownloadDecide, .{ .view = 7, .id = 41, .path = "/home/x/Downloads/big.iso" });
    try roundTrip(DownloadDecide, .{ .view = 7, .id = 41, .path = "" });
    try roundTrip(EvDownloadProgress, .{
        .view = 7,
        .id = 41,
        .received = 1_234_567_890_123,
        .total = 5_000_000_000_000,
        .done = 0,
        .failed = 0,
    });
    try roundTrip(EvDownloadProgress, .{ .view = 7, .id = 41, .received = 10, .total = 10, .done = 1, .failed = 0 });
    try roundTrip(EvDownloadProgress, .{ .view = 7, .id = 41, .received = 3, .total = 0, .done = 0, .failed = 1 });
    try roundTrip(DownloadCancel, .{ .view = 7, .id = 41 });
    try roundTrip(DownloadStart, .{ .view = 7, .req = 9, .url = "https://example.com/big.iso" });
    try roundTrip(EvDownloadOffer, .{
        .view = 7,
        .id = 43,
        .total = 12,
        .url = "https://example.com/asked-for.bin",
        .name = "asked-for.bin",
        .mime = "",
        .req = 9,
    });
}

// The download offer grows the same way `ev_popup_request` does: a
// helper that predates `download_start` sends six fields, and a client
// built with seven must read that as "the page started this one"
// (req = 0) rather than as a truncated frame it drops — dropping it is
// how a download ends up held forever with nothing on disk.
test "an ev_download_offer without the trailing req still decodes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    try putU32(gpa, &out, 7);
    try putU32(gpa, &out, 41);
    try putU64(gpa, &out, 0);
    try putStr(gpa, &out, "https://example.com/x.bin");
    try putStr(gpa, &out, "x.bin");
    try putStr(gpa, &out, "");
    const ev = try EvDownloadOffer.decodeFrom(out.items);
    try std.testing.expectEqual(@as(u32, 0), ev.req);
    try std.testing.expectEqualStrings("x.bin", ev.name);
}

test "legacy download decisions and progress default staging and errors" {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try putU32(a, &bytes, 7);
    try putU32(a, &bytes, 41);
    try putStr(a, &bytes, "/tmp/file.bin");
    const decision = try DownloadDecide.decodeFrom(bytes.items);
    try std.testing.expectEqual(@as(u8, 0), decision.stage);
    bytes.clearRetainingCapacity();
    try putU32(a, &bytes, 7);
    try putU32(a, &bytes, 41);
    try putU64(a, &bytes, 10);
    try putU64(a, &bytes, 10);
    try putU8(a, &bytes, 1);
    try putU8(a, &bytes, 0);
    const progress = try EvDownloadProgress.decodeFrom(bytes.items);
    try std.testing.expectEqual(@as(u32, 0), progress.req);
    try std.testing.expectEqualStrings("", progress.path);
    try std.testing.expectEqual(@as(i32, 0), progress.interrupt_reason);
}

test "a sem_eval without the trailing max_str decodes as the serializer default" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    try putU32(gpa, &out, 7);
    try putU8(gpa, &out, eval_flag_await);
    try putU32(gpa, &out, 5000);
    try putText(gpa, &out, .{ .s = "1+1" });
    const ev = try SemEval.decodeFrom(out.items);
    try std.testing.expectEqual(@as(u32, 0), ev.max_str);
    try std.testing.expectEqualStrings("1+1", ev.code.s);
    try roundTrip(SemEval, .{ .view = 7, .flags = 0, .timeout_ms = 5000, .code = .{ .s = "1+1" }, .max_str = 60_000 });
}

// The one growable frame on this wire: a helper that predates the
// gesture flag sends three fields, and a client built with four must
// read that as "a gesture" rather than as a truncated frame — the
// difference between an old helper behaving as it always did and one
// whose every popup is silently blocked.
test "an ev_popup_request without the trailing gesture byte still decodes" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    // Hand-built in the OLD layout: [view][url][disposition], no more.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try putU32(gpa, &body, 7);
    try putStr(gpa, &body, "http://x/p");
    try putU8(gpa, &body, 1);
    try putU32(gpa, &buf, @intCast(body.items.len + 1));
    try putU8(gpa, &buf, @intFromEnum(Tag.ev_popup_request));
    try buf.appendSlice(gpa, body.items);

    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    const got = try decode(EvPopupRequest, frame.payload);
    try std.testing.expectEqualStrings("http://x/p", got.url);
    try std.testing.expectEqual(@as(u8, 1), got.disposition);
    try std.testing.expectEqual(@as(u8, 1), got.user_gesture);
}

test "round-trip: container/context frames" {
    try roundTrip(ContextCreate, .{
        .id = 3,
        .ephemeral = 1,
        .name = "Work",
        .proxy = "socks5://127.0.0.1:19180",
    });
    try roundTrip(ContextCreate, .{ .id = 4, .ephemeral = 0, .name = "", .proxy = "" });
    try roundTrip(ContextDestroy, .{ .id = 3 });
    try roundTrip(EvViewCreateFailed, .{ .view = 7, .context = 3, .reason = "requested browser context does not exist" });
}

test "round-trip: webext frames" {
    try roundTrip(WebextSet, .{ .id = "abc123", .dir = "/home/x/.local/share/sketerm/webext/abc123", .enabled = 1 });
    try roundTrip(WebextSet, .{ .id = "abc123", .dir = "", .enabled = 0 });
    try roundTrip(WebextInstallPrepare, .{ .req = 7, .id = "abc123", .dir = "/tmp/.abc123.stage", .version = "2" });
    try roundTrip(EvWebextInstallPrepared, .{ .req = 7, .id = "abc123", .ok = 1, .err = "" });
    try roundTrip(WebextInstallCommit, .{ .req = 7, .id = "abc123", .dir = "/data/abc123", .version = "2", .enabled = 1 });
    try roundTrip(EvWebextInstallCommitted, .{ .req = 7, .id = "abc123", .ok = 0, .err = "refused" });
    try roundTrip(WebextRemove, .{ .id = "abc123" });
    try roundTrip(WebextListReq, .{});
    try roundTrip(EvWebextState, .{
        .id = "abc123",
        .name = "uBlock Origin",
        .version = "1.0",
        .enabled = 1,
        .ok = 1,
        .err = "",
    });
    try roundTrip(EvWebextState, .{ .id = "bad", .name = "", .version = "", .enabled = 0, .ok = 0, .err = "bad manifest" });
    try roundTrip(WebextTabs, .{ .tabs_json = "[]" });
    try roundTrip(WebextTabs, .{
        .tabs_json =
        \\[{"id":3,"view":1,"windowId":0,"index":0,"active":true,"focusedWindow":true,"url":"https://a.test/","title":"A","loading":false}]
        ,
    });
    try roundTrip(EvWebextActions, .{ .view = 7, .actions_json = "[{\"id\":\"ext\"}]" });
    try roundTrip(WebextActionActivate, .{
        .view = 7,
        .id = "ext",
        .popup_view = WEBEXT_POPUP_VIEW_BASE + 1,
        .w = 360,
        .h = 420,
        .scale_x1000 = 1500,
    });
    try roundTrip(EvWebextPopup, .{
        .owner_view = 7,
        .popup_view = WEBEXT_POPUP_VIEW_BASE + 1,
        .state = webext_popup_opened,
        .detail = "sketerm-extension://0123456789abcdef/popup.html",
    });
    try roundTrip(EvWebextOpenPopup, .{ .view = 7, .id = "action@example", .req = 19 });
    try roundTrip(WebextOpenPopupResult, .{ .view = 7, .id = "action@example", .req = 19, .ok = 1, .detail = "" });
    try roundTrip(WebextWreqStatsReq, .{});
    try roundTrip(EvWebextWreqStats, .{
        .id = "abc123",
        .matched = 900,
        .held = 120,
        .cancelled = 40,
        .redirected = 3,
        .headers_modified = 7,
        .headers_received_dropped = 2,
        .timed_out = 1,
        .failed_open = 1,
        .us_p50 = 640,
        .us_p95 = 1900,
        .us_max = 20_000,
        .samples = 120,
    });
}

test "round-trip: semantic layer frames" {
    try roundTrip(SemSnapshotReq, .{ .view = 7, .mode = 1, .detail = 2, .scope = 0 });
    try roundTrip(SemSnapshot, .{
        .view = 7,
        .doc_gen = 3,
        .rev = 12,
        .kind = @intFromEnum(SnapKind.delta),
        .payload = .{ .s = "delta rev 11->12\n~ [4] button \"Go\"\n" },
    });
    try roundTrip(SemAction, .{
        .view = 7,
        .id = 4,
        .action = @intFromEnum(SemAct.set_value),
        .arg = "hello",
    });
    try roundTrip(SemActResult, .{ .view = 7, .id = 4, .ok = 1, .msg = "click at 40,20" });
    try roundTrip(SemExpand, .{ .view = 7, .id = 4, .off = 160, .len = 4096 });
    try roundTrip(SemExpandResult, .{ .view = 7, .id = 4, .off = 160, .text = "the rest of it" });
    try roundTrip(SemQueryReq, .{ .view = 7, .kind = @intFromEnum(SemQuery.subtree), .arg = "4" });
    try roundTrip(SemQueryResult, .{ .view = 7, .payload = .{ .s = "query subtree [4]\n" } });
    try roundTrip(SemRead, .{ .view = 7 });
    try roundTrip(SemReadResult, .{ .view = 7, .markdown = .{ .s = "# Heading\n\ntext\n" } });
    try roundTrip(SemReadIds, .{ .view = 7 });
    const entities = [_]ReaderEntity{
        .{ .id = 4, .guard = 44, .kind = "heading", .text = "Heading", .url = "" },
        .{ .id = 9, .guard = 99, .kind = "link", .text = "Next", .url = "https://example.test/next" },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &buf, SemReadIdsResult{
        .view = 7,
        .doc_gen = 3,
        .rev = 12,
        .markdown = .{ .s = "# Heading\n\n[Next](https://example.test/next)\n" },
        .entities = &entities,
    });
    var reader = Reader.init(buf.items);
    const rich_frame = (try reader.next()).?;
    const rich = try SemReadIdsResult.decodeAlloc(rich_frame.payload, std.testing.allocator);
    defer std.testing.allocator.free(rich.entities);
    try std.testing.expectEqual(@as(u32, 3), rich.doc_gen);
    try std.testing.expectEqualStrings("# Heading\n\n[Next](https://example.test/next)\n", rich.markdown.s);
    try std.testing.expectEqual(@as(usize, 2), rich.entities.len);
    try std.testing.expectEqual(@as(u32, 9), rich.entities[1].id);
    try std.testing.expectEqual(@as(u64, 99), rich.entities[1].guard);
    try std.testing.expectEqualStrings("https://example.test/next", rich.entities[1].url);
    try roundTrip(SemActGuarded, .{
        .view = 7,
        .doc_gen = 3,
        .rev = 12,
        .id = 9,
        .guard = 99,
        .action = @intFromEnum(SemAct.click),
        .arg = "",
    });
    try roundTrip(SemRequest, .{
        .request = 41,
        .kind = @intFromEnum(Tag.sem_read_ids),
        .payload = .{ .s = "request bytes" },
    });
    try roundTrip(SemResult, .{
        .request = 41,
        .kind = @intFromEnum(Tag.sem_read_ids_result),
        .payload = .{ .s = "result bytes" },
    });
    try roundTrip(SemEval, .{
        .view = 7,
        .flags = eval_flag_await,
        .timeout_ms = 5000,
        .code = .{ .s = "document.title" },
    });
    try roundTrip(SemEvalResult, .{ .view = 7, .ok = 1, .json = .{ .s = "{\"value\":\"x\"}" } });
}

test "round-trip: a11y frames" {
    try roundTrip(A11yEnable, .{ .view = 7, .enabled = 1 });
    try roundTrip(EvA11yTree, .{
        .view = 7,
        .root_id = 1,
        .node_id_to_clear = 0,
        .focus_id = 4,
        .nodes = .{ .s = "" },
    });
    try roundTrip(EvA11yLoc, .{ .view = 7, .locs = .{ .s = "" } });
    try roundTrip(EvA11yEvent, .{ .view = 7, .id = 4, .event = "focus" });
    try roundTrip(EvA11yCaret, .{
        .view = 7,
        .anchor_id = 4,
        .anchor_offset = 2,
        .focus_id = 4,
        .focus_offset = 9,
    });
    // A BACKWARD selection: anchor past focus is legal, not an error,
    // so the signed fields must survive rather than clamp.
    try roundTrip(EvA11yCaret, .{
        .view = 7,
        .anchor_id = 9,
        .anchor_offset = 12,
        .focus_id = 4,
        .focus_offset = 0,
    });
}

test "a11y node list round-trips through writer and iterator" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var w = A11yNodeWriter{ .gpa = gpa, .buf = &buf };
    try w.put(.{
        .id = 1,
        .state = ax_busy,
        .x = 0,
        .y = 0,
        .w = 800,
        .h = 600,
        .role = "document",
        .name = "Example page",
        .children = &[_]u32{ 2, 3 },
    });
    try w.put(.{
        .id = 2,
        .state = 0,
        .x = 8,
        .y = 8,
        .w = 200,
        .h = 32,
        .offset_container = 1,
        .role = "heading",
        .name = "Hello",
        .attributes = &[_]A11yAttr{.{ .key = "level", .value = "1" }},
    });
    try w.put(.{
        .id = 3,
        .state = ax_focusable | ax_focused,
        .x = 8,
        .y = 48,
        .w = 80,
        .h = 24,
        .offset_container = 1,
        .role = "button",
        .name = "Go",
        .value = "",
        .description = "submits the form",
    });
    try std.testing.expectEqual(@as(u32, 3), w.count);

    var it = A11yNodeIter.init(buf.items);
    const n1 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 1), n1.id);
    try std.testing.expectEqualStrings("document", n1.role);
    try std.testing.expectEqual(@as(u16, 2), n1.nchildren);
    try std.testing.expectEqual(@as(u32, 2), n1.childAt(0));
    try std.testing.expectEqual(@as(u32, 3), n1.childAt(1));
    const n2 = (try it.next()).?;
    try std.testing.expectEqualStrings("heading", n2.role);
    try std.testing.expectEqualStrings("Hello", n2.name);
    var attrs = n2.attrs();
    const a = (try attrs.next()).?;
    try std.testing.expectEqualStrings("level", a.key);
    try std.testing.expectEqualStrings("1", a.value);
    try std.testing.expectEqual(@as(?A11yAttr, null), try attrs.next());
    const n3 = (try it.next()).?;
    try std.testing.expectEqual(ax_focusable | ax_focused, n3.state);
    try std.testing.expectEqualStrings("submits the form", n3.description);
    try std.testing.expectEqual(@as(u32, 1), n3.offset_container);
    try std.testing.expectEqual(@as(?A11yNode, null), try it.next());

    // A truncated payload is an error, never a read past the buffer.
    var short = A11yNodeIter.init(buf.items[0 .. buf.items.len - 3]);
    _ = try short.next();
    _ = try short.next();
    try std.testing.expectError(error.Truncated, short.next());
}

test "a11y location list round-trips" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try putA11yLoc(gpa, &buf, .{ .id = 4, .offset_container = 1, .x = -2, .y = 300, .w = 80, .h = 24 });
    try putA11yLoc(gpa, &buf, .{ .id = 5, .offset_container = 0, .x = 0, .y = 0, .w = 800, .h = 600 });
    var it = A11yLocIter.init(buf.items);
    const l1 = (try it.next()).?;
    try std.testing.expectEqual(@as(i32, -2), l1.x);
    try std.testing.expectEqual(@as(u32, 1), l1.offset_container);
    const l2 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 5), l2.id);
    try std.testing.expectEqual(@as(?A11yLoc, null), try it.next());
}

test "round-trip: interception frames" {
    try roundTrip(InterceptSet, .{ .view = 0, .enabled = 0 });
    try roundTrip(InterceptSet, .{ .view = 7, .enabled = 1 });
    try roundTrip(InterceptStatusReq, .{ .view = 7 });
    try roundTrip(InterceptStatus, .{ .view = 7, .enabled = 1, .rules = 1234, .blocked = 5, .total = 61 });
    try roundTrip(InterceptLogReq, .{ .view = 7, .since = 41, .max = 50 });
}

test "round-trip: intercept_lists path list" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const paths = [_][]const u8{ "/tmp/a.txt", "/home/x/.config/sketerm/filters/easylist.txt" };
    try encode(gpa, &buf, InterceptLists{ .paths = &paths });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.intercept_lists, frame.tag);
    const got = try InterceptLists.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.paths);
    try std.testing.expectEqual(@as(usize, 2), got.paths.len);
    try std.testing.expectEqualStrings(paths[1], got.paths[1]);
}

test "round-trip: intercept_subscribe url list" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const urls = [_][]const u8{
        "https://easylist.to/easylist/easylist.txt",
        "https://secure.fanboy.co.nz/fanboy-annoyance.txt",
    };
    try encode(gpa, &buf, InterceptSubscribe{ .update_hours = 6, .urls = &urls });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.intercept_subscribe, frame.tag);
    const got = try InterceptSubscribe.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.urls);
    try std.testing.expectEqual(@as(u32, 6), got.update_hours);
    try std.testing.expectEqual(@as(usize, 2), got.urls.len);
    try std.testing.expectEqualStrings(urls[0], got.urls[0]);
    try std.testing.expectEqualStrings(urls[1], got.urls[1]);

    // Subscribing to nothing is a legal, meaningful frame: it is how a
    // client says "stop, and drop the caches".
    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(gpa);
    try encode(gpa, &b2, InterceptSubscribe{ .update_hours = 0, .urls = &.{} });
    var r2 = Reader.init(b2.items);
    const f2 = (try r2.next()).?;
    const none = try InterceptSubscribe.decodeAlloc(f2.payload, gpa);
    defer gpa.free(none.urls);
    try std.testing.expectEqual(@as(usize, 0), none.urls.len);
    try roundTrip(EvInterceptSubscribeDone, .{
        .serial = 9,
        .active = 4,
        .fetched = 4,
        .updated = 1,
        .failed = 3,
        .rules = 27,
    });
    try std.testing.expectEqual(@as(u8, 0xC4), @intFromEnum(Tag.intercept_subscribe));
    try std.testing.expectEqual(@as(u8, 0xC5), @intFromEnum(Tag.ev_intercept_subscribe_done));
}

test "round-trip: user content sets (0xC0 block)" {
    const gpa = std.testing.allocator;
    // Tag values are append-only wire facts.
    try std.testing.expectEqual(@as(u8, 0xC0), @intFromEnum(Tag.us_script_set));
    try std.testing.expectEqual(@as(u8, 0xC1), @intFromEnum(Tag.us_style_set));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const scripts = [_]UsScript{
        .{ .id = 3, .source = .{ .s = "// ==UserScript==\n// @name a\n// ==/UserScript==\nx()" } },
        .{ .id = 9, .source = .{ .s = "" } },
    };
    try encode(gpa, &buf, UsScriptSet{ .scripts = &scripts });
    const styles = [_]UsStyle{
        .{ .id = 1, .host = "example.com", .css = .{ .s = "body{color:red}" } },
        .{ .id = 2, .host = "", .css = .{ .s = "*{}" } },
    };
    try encode(gpa, &buf, UsStyleSet{ .styles = &styles });

    var r = Reader.init(buf.items);
    const f1 = (try r.next()).?;
    try std.testing.expectEqual(Tag.us_script_set, f1.tag);
    const got_s = try UsScriptSet.decodeAlloc(f1.payload, gpa);
    defer gpa.free(got_s.scripts);
    try std.testing.expectEqual(@as(usize, 2), got_s.scripts.len);
    try std.testing.expectEqual(@as(u32, 3), got_s.scripts[0].id);
    try std.testing.expectEqualStrings(scripts[0].source.s, got_s.scripts[0].source.s);
    try std.testing.expectEqual(@as(usize, 0), got_s.scripts[1].source.s.len);

    const f2 = (try r.next()).?;
    try std.testing.expectEqual(Tag.us_style_set, f2.tag);
    const got_y = try UsStyleSet.decodeAlloc(f2.payload, gpa);
    defer gpa.free(got_y.styles);
    try std.testing.expectEqual(@as(usize, 2), got_y.styles.len);
    try std.testing.expectEqualStrings("example.com", got_y.styles[0].host);
    try std.testing.expectEqualStrings("body{color:red}", got_y.styles[0].css.s);
    try std.testing.expectEqualStrings("", got_y.styles[1].host);

    // Empty replace-all sets are valid frames (clear everything).
    buf.clearRetainingCapacity();
    try encode(gpa, &buf, UsScriptSet{ .scripts = &.{} });
    var r2 = Reader.init(buf.items);
    const f3 = (try r2.next()).?;
    const got_e = try UsScriptSet.decodeAlloc(f3.payload, gpa);
    defer gpa.free(got_e.scripts);
    try std.testing.expectEqual(@as(usize, 0), got_e.scripts.len);
}

test "round-trip: intercept_log entry list" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const entries = [_]NetEntry{
        .{ .seq = 40, .blocked = 1, .rtype = @intFromEnum(NetResource.image), .done = 1, .status = 0, .dur_ms = 0, .size = 0, .method = "GET", .url = "https://ads.example/px.gif" },
        .{ .seq = 41, .blocked = 0, .rtype = @intFromEnum(NetResource.script), .done = 1, .status = 200, .dur_ms = 12, .size = 4096, .method = "GET", .url = "https://site.example/app.js" },
    };
    try encode(gpa, &buf, InterceptLog{ .view = 7, .next_seq = 42, .entries = &entries });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.intercept_log, frame.tag);
    const got = try InterceptLog.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.entries);
    try std.testing.expectEqual(@as(u32, 42), got.next_seq);
    try std.testing.expectEqual(@as(usize, 2), got.entries.len);
    try std.testing.expectEqual(@as(u8, 1), got.entries[0].blocked);
    try std.testing.expectEqualStrings("https://site.example/app.js", got.entries[1].url);
    try std.testing.expectEqual(@as(u16, 200), got.entries[1].status);
}

test "round-trip: cookie sync carries every attribute, values included" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const ck = SyncCookie{
        .name = "sid",
        .value = "s3cr3t-value",
        .domain = ".site.example",
        .path = "/app",
        .flags = cookie_secure | cookie_httponly | cookie_domain_scoped,
        .same_site = @intFromEnum(SameSite.strict),
        .priority = @intFromEnum(CookiePriority.high),
        .creation_ms = 1_700_000_000_000,
        .last_access_ms = 1_700_000_500_000,
        .expires_ms = 1_800_000_000_000,
    };

    try encode(gpa, &buf, EvCookieChange{
        .context = 0,
        .cause = @intFromEnum(CookieCause.response_header),
        .removed = 0,
        .url = "https://site.example/app/login",
        .cookie = ck,
    });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.ev_cookie_change, frame.tag);
    const got = try decode(EvCookieChange, frame.payload);
    try std.testing.expectEqualStrings("https://site.example/app/login", got.url);
    try std.testing.expectEqual(@as(u8, 0), got.removed);
    // Every attribute survives: a dropped HttpOnly or SameSite is a
    // security regression, a dropped expiry turns a persistent cookie
    // into a session one.
    try std.testing.expectEqualStrings("sid", got.cookie.name);
    try std.testing.expectEqualStrings("s3cr3t-value", got.cookie.value);
    try std.testing.expectEqualStrings(".site.example", got.cookie.domain);
    try std.testing.expectEqualStrings("/app", got.cookie.path);
    try std.testing.expect(got.cookie.flags & cookie_secure != 0);
    try std.testing.expect(got.cookie.flags & cookie_httponly != 0);
    try std.testing.expect(got.cookie.flags & cookie_domain_scoped != 0);
    try std.testing.expect(got.cookie.flags & cookie_session == 0);
    try std.testing.expectEqual(@intFromEnum(SameSite.strict), got.cookie.same_site);
    try std.testing.expectEqual(@intFromEnum(CookiePriority.high), got.cookie.priority);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000), got.cookie.creation_ms);
    try std.testing.expectEqual(@as(u64, 1_700_000_500_000), got.cookie.last_access_ms);
    try std.testing.expectEqual(@as(u64, 1_800_000_000_000), got.cookie.expires_ms);

    // The apply direction is the same record with a target context.
    buf.clearRetainingCapacity();
    try encode(gpa, &buf, CookieApply{
        .req = 91,
        .context = EPHEMERAL_CTX_BASE + 3,
        .remove = 1,
        .url = "https://site.example/app",
        .cookie = ck,
    });
    var r2 = Reader.init(buf.items);
    const f2 = (try r2.next()).?;
    const ap = try decode(CookieApply, f2.payload);
    try std.testing.expectEqual(@as(u32, 91), ap.req);
    try std.testing.expectEqual(EPHEMERAL_CTX_BASE + 3, ap.context);
    try std.testing.expectEqual(@as(u8, 1), ap.remove);
    try std.testing.expectEqualStrings("s3cr3t-value", ap.cookie.value);

    try roundTrip(CookieSyncEnable, .{ .enable = 1 });
    try roundTrip(CookieDumpReq, .{ .req = 4, .context = 0, .cursor = 128 });
    try roundTrip(EvCookieApplyDone, .{ .req = 91, .context = 0, .ok = 0, .reason = "engine-refused" });
    try roundTrip(EvCookieApplyDone, .{ .req = 92, .context = 0, .ok = 1, .reason = "" });
}

test "round-trip: cookie dump pages and reports its own bound" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const cookies = [_]SyncCookie{
        .{
            .name = "a",
            .value = "1",
            .domain = "site.example",
            .path = "/",
            .flags = 0,
            .same_site = @intFromEnum(SameSite.lax),
            .priority = @intFromEnum(CookiePriority.medium),
            .creation_ms = 7,
            .last_access_ms = 8,
            .expires_ms = 0,
        },
        .{
            .name = "b",
            .value = "",
            .domain = ".site.example",
            .path = "/x",
            .flags = cookie_session | cookie_domain_scoped,
            .same_site = @intFromEnum(SameSite.unspecified),
            .priority = @intFromEnum(CookiePriority.low),
            .creation_ms = 0,
            .last_access_ms = 0,
            .expires_ms = 0,
        },
    };
    try encode(gpa, &buf, EvCookieDump{
        .req = 5,
        .context = 0,
        .ok = 1,
        .cursor = 0,
        .next_cursor = 2,
        .more = 1,
        .total = 300,
        .cookies = &cookies,
    });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.ev_cookie_dump, frame.tag);
    const got = try EvCookieDump.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.cookies);
    try std.testing.expectEqual(@as(u32, 300), got.total);
    try std.testing.expectEqual(@as(u8, 1), got.more);
    try std.testing.expectEqual(@as(u32, 2), got.next_cursor);
    try std.testing.expectEqual(@as(usize, 2), got.cookies.len);
    try std.testing.expectEqualStrings("a", got.cookies[0].name);
    try std.testing.expectEqualStrings("", got.cookies[1].value);
    try std.testing.expect(got.cookies[1].flags & cookie_session != 0);

    // An empty final page is a valid frame: it is how a dump ENDS.
    buf.clearRetainingCapacity();
    try encode(gpa, &buf, EvCookieDump{
        .req = 5,
        .context = 0,
        .ok = 1,
        .cursor = 300,
        .next_cursor = 300,
        .more = 0,
        .total = 300,
        .cookies = &.{},
    });
    var r2 = Reader.init(buf.items);
    const f2 = (try r2.next()).?;
    const last = try EvCookieDump.decodeAlloc(f2.payload, gpa);
    defer gpa.free(last.cookies);
    try std.testing.expectEqual(@as(usize, 0), last.cookies.len);
    try std.testing.expectEqual(@as(u8, 0), last.more);
}

test "round-trip: site-data request frames" {
    try roundTrip(CookiesReq, .{ .view = 7, .req = 3, .url = "https://site.example/a" });
    // An empty url means "the view's current address".
    try roundTrip(CookiesReq, .{ .view = 7, .req = 4, .url = "" });
    try roundTrip(CookieDelete, .{ .view = 7, .req = 5, .url = "https://site.example/", .name = "sid" });
    try roundTrip(CookiesClear, .{ .view = 7, .req = 6, .url = "https://site.example/" });
    try roundTrip(SitedataClear, .{
        .view = 7,
        .req = 7,
        .url = "https://site.example/",
        .what = sitedata_cookies | sitedata_storage | sitedata_cache,
    });
    try roundTrip(EvSitedataDone, .{ .view = 7, .req = 7, .ok = 1, .kind = @intFromEnum(SitedataKind.sitedata_clear), .removed = 3, .detail = "cache-whole-context" });
    try roundTrip(EvSitedataDone, .{ .view = 7, .req = 5, .ok = 0, .kind = @intFromEnum(SitedataKind.cookie_delete), .removed = 0, .detail = "" });
    try roundTrip(FlushReq, .{ .token = 41 });
    try roundTrip(EvFlushed, .{ .token = 41 });
}

test "round-trip: ev_cookies entry list carries metadata, never values" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const entries = [_]CookieEntry{
        .{
            .name = "sid",
            .domain = "site.example",
            .path = "/",
            .flags = cookie_secure | cookie_httponly,
            .same_site = @intFromEnum(SameSite.lax),
            .expires_ms = 1_800_000_000_000,
            .value_len = 64,
        },
        .{
            .name = "theme",
            .domain = ".site.example",
            .path = "/app",
            .flags = cookie_session | cookie_domain_scoped,
            .same_site = @intFromEnum(SameSite.unspecified),
            .expires_ms = 0,
            .value_len = 4,
        },
    };
    // `total` is the whole match count, `entries` may be truncated.
    try encode(gpa, &buf, EvCookies{ .view = 7, .req = 9, .ok = 1, .total = 205, .entries = &entries });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.ev_cookies, frame.tag);
    const got = try EvCookies.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.entries);
    try std.testing.expectEqual(@as(u32, 9), got.req);
    try std.testing.expectEqual(@as(u8, 1), got.ok);
    try std.testing.expectEqual(@as(u32, 205), got.total);
    try std.testing.expectEqual(@as(usize, 2), got.entries.len);
    try std.testing.expectEqualStrings("sid", got.entries[0].name);
    try std.testing.expect(got.entries[0].flags & cookie_secure != 0);
    try std.testing.expect(got.entries[0].flags & cookie_session == 0);
    try std.testing.expectEqual(@as(u64, 1_800_000_000_000), got.entries[0].expires_ms);
    try std.testing.expectEqual(@as(u32, 64), got.entries[0].value_len);
    try std.testing.expectEqualStrings(".site.example", got.entries[1].domain);
    try std.testing.expect(got.entries[1].flags & cookie_session != 0);
    try std.testing.expectEqual(@as(u64, 0), got.entries[1].expires_ms);

    // No value field exists to leak: the encoded frame carries the
    // names and scopes and nothing that could be a token.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, buf.items, "SECRET"));

    // An empty answer is still an answer.
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(gpa);
    try encode(gpa, &buf2, EvCookies{ .view = 7, .req = 10, .ok = 1, .total = 0, .entries = &.{} });
    var r2 = Reader.init(buf2.items);
    const f2 = (try r2.next()).?;
    const got2 = try EvCookies.decodeAlloc(f2.payload, gpa);
    defer gpa.free(got2.entries);
    try std.testing.expectEqual(@as(usize, 0), got2.entries.len);
    try std.testing.expectEqual(@as(u32, 0), got2.total);
}

test "netLogJson is one newline-free JSON object" {
    const gpa = std.testing.allocator;
    const entries = [_]NetEntry{
        .{ .seq = 1, .blocked = 1, .rtype = @intFromEnum(NetResource.image), .done = 1, .status = 0, .dur_ms = 0, .size = 0, .method = "GET", .url = "https://ads.example/px.gif" },
        .{ .seq = 2, .blocked = 0, .rtype = @intFromEnum(NetResource.script), .done = 0, .status = 0, .dur_ms = 0, .size = 0, .method = "GET", .url = "https://site.example/a\njs" },
        .{ .seq = 3, .blocked = 0, .rtype = 99, .done = 1, .status = 404, .dur_ms = 7, .size = 11, .method = "POST", .url = "https://site.example/api" },
    };
    const json = try netLogJson(gpa, 4, &entries);
    defer gpa.free(json);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, json, '\n'));
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 4), obj.get("next_seq").?.integer);
    const arr = obj.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expect(arr[0].object.get("blocked").?.bool);
    try std.testing.expect(arr[1].object.get("pending").?.bool);
    // An unknown wire type byte renders as "other", not a crash.
    try std.testing.expectEqualStrings("other", arr[2].object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 404), arr[2].object.get("status").?.integer);
}

test "round-trip: net-policy frames" {
    const gpa = std.testing.allocator;

    // A full host-list round trip, at the wire's practical width.
    var names: [64][]const u8 = undefined;
    var name_bufs: [64][16]u8 = undefined;
    for (&names, 0..) |*n, i| n.* = try std.fmt.bufPrint(&name_bufs[i], "h{d}.example", .{i});
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, NetPolicySet{
        .view = 9,
        .serial = 3,
        .flags = NetPolicySet.flag_allow_private,
        .block_types = 1 << @intFromEnum(NetResource.image),
        .allow_schemes = 0b11,
        .max_requests = 500,
        .max_bytes = 10 << 20,
        .max_navigations = 4,
        .deadline_ms = 30_000,
        .allow_top = names[0..64],
        .allow_sub = names[0..2],
    });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.net_policy_set, frame.tag);
    const got = try NetPolicySet.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.allow_top);
    defer gpa.free(got.allow_sub);
    try std.testing.expectEqual(@as(usize, 64), got.allow_top.len);
    try std.testing.expectEqualStrings("h63.example", got.allow_top[63]);
    try std.testing.expectEqual(@as(usize, 2), got.allow_sub.len);
    try std.testing.expectEqual(@as(u64, 10 << 20), got.max_bytes);
    try std.testing.expect(got.flags & NetPolicySet.flag_allow_private != 0);

    try roundTrip(NetPolicyReq, .{ .view = 9 });
    try roundTrip(NetLogReq, .{ .view = 9, .since = 7, .max = 50 });

    var denied: [NREASONS]u32 = @splat(0);
    denied[@intFromEnum(NetReason.sub_host)] = 5;
    denied[@intFromEnum(NetReason.request_cap)] = 2;
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(gpa);
    try encode(gpa, &buf2, EvNetPolicy{
        .view = 9,
        .serial = 3,
        .active = 1,
        .exhausted = @intFromEnum(NetReason.request_cap),
        .requests = 500,
        .bytes = 123_456,
        .navigations = 2,
        .ms_left = 0,
        .denied = denied,
    });
    var r2 = Reader.init(buf2.items);
    const f2 = (try r2.next()).?;
    try std.testing.expectEqual(Tag.ev_net_policy, f2.tag);
    const ev = try decode(EvNetPolicy, f2.payload);
    try std.testing.expectEqual(@as(u32, 5), ev.denied[@intFromEnum(NetReason.sub_host)]);
    try std.testing.expectEqual(@intFromEnum(NetReason.request_cap), ev.exhausted);
    try std.testing.expectEqual(@as(u64, 123_456), ev.bytes);
}

test "round-trip: net_log carries the reason the old frame cannot" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const entries = [_]NetEntry2{
        .{ .entry = .{ .seq = 1, .blocked = 1, .rtype = @intFromEnum(NetResource.xhr), .done = 1, .status = 0, .dur_ms = 0, .size = 0, .method = "GET", .url = "https://other.example/x" }, .reason = @intFromEnum(NetReason.sub_host) },
        .{ .entry = .{ .seq = 2, .blocked = 0, .rtype = @intFromEnum(NetResource.document), .done = 1, .status = 200, .dur_ms = 9, .size = 512, .method = "GET", .url = "https://site.example/" }, .reason = @intFromEnum(NetReason.none) },
    };
    try encode(gpa, &buf, NetLog{ .view = 4, .next_seq = 3, .entries = &entries });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.net_log, frame.tag);
    const got = try NetLog.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.entries);
    try std.testing.expectEqual(@as(usize, 2), got.entries.len);
    try std.testing.expectEqual(@intFromEnum(NetReason.sub_host), got.entries[0].reason);
    try std.testing.expectEqualStrings("https://site.example/", got.entries[1].entry.url);

    // The one JSON renderer names the reason; a lifted legacy entry can
    // only ever say filter_list.
    const json = try netLogJson2(gpa, 3, &entries);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reason\":\"sub_host\"") != null);
    const legacy = [_]NetEntry{entries[0].entry};
    const lifted = try netLogJson(gpa, 2, &legacy);
    defer gpa.free(lifted);
    try std.testing.expect(std.mem.indexOf(u8, lifted, "\"reason\":\"filter_list\"") != null);
}

test "round-trip: devtools and print-to-pdf frames" {
    try roundTrip(DevToolsShow, .{ .view = 7, .x = 0, .y = 0 });
    try roundTrip(DevToolsShow, .{ .view = 7, .x = 120, .y = -4 });
    try roundTrip(EvDevToolsView, .{ .view = 7, .devtools = ENGINE_VIEW_BASE + 1, .reason = "" });
    try roundTrip(EvDevToolsView, .{ .view = 7, .devtools = 0, .reason = "windowed" });
    try roundTrip(PrintPdf, .{
        .view = 7,
        .flags = print_flag_landscape | print_flag_background,
        .paper = @intFromEnum(Paper.a4),
        .path = "/tmp/page.pdf",
    });
    try roundTrip(EvPrintPdfDone, .{ .view = 7, .ok = 1, .path = "/tmp/page.pdf" });
    try roundTrip(EvPrintPdfDone, .{ .view = 7, .ok = 0, .path = "" });
}

test "a helper-minted devtools id cannot collide with a client-minted one" {
    // Clients allocate from 1 upwards; the helper's range starts far
    // above anything a session reaches.
    try std.testing.expect(ENGINE_VIEW_BASE > 1_000_000);
    try std.testing.expectEqual(@as(?PaperSize, null), paperInches(@intFromEnum(Paper.default)));
    try std.testing.expectEqual(@as(f64, 8.27), paperInches(@intFromEnum(Paper.a4)).?.w);
    // An unknown preset from a newer client is the engine default, not
    // a decode failure.
    try std.testing.expectEqual(@as(?PaperSize, null), paperInches(200));
}

test "a text payload carries more than a str's u16 length" {
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 200_000);
    defer gpa.free(big);
    @memset(big, 'x');
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, SemSnapshot{
        .view = 1,
        .doc_gen = 1,
        .rev = 1,
        .kind = 0,
        .payload = .{ .s = big },
    });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    const got = try decode(SemSnapshot, frame.payload);
    try std.testing.expectEqual(big.len, got.payload.s.len);
}

test "round-trip: hello_ack capability list" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const caps = [_][]const u8{ CAP_FRAMES_SHM, CAP_INPUT, CAP_NAVIGATION };
    try encode(gpa, &buf, HelloAck{
        .proto = PROTO_VERSION,
        .engine_name = "cef",
        .engine_version = "151",
        .caps = &caps,
    });

    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.hello_ack, frame.tag);
    const got = try HelloAck.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.caps);
    try std.testing.expectEqual(PROTO_VERSION, got.proto);
    try std.testing.expectEqualStrings("cef", got.engine_name);
    try std.testing.expectEqualStrings("151", got.engine_version);
    try std.testing.expectEqual(@as(usize, 3), got.caps.len);
    try std.testing.expectEqualStrings(CAP_INPUT, got.caps[1]);
}

test "round-trip: frame_damage rect list" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const rects = [_]Rect{ .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .{ .x = 4, .y = 8, .w = 16, .h = 32 } };
    try encode(gpa, &buf, FrameDamage{ .view = 1, .buf_id = 5, .gen = 42, .rects = &rects });

    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    const got = try FrameDamage.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.rects);
    try std.testing.expectEqual(@as(u32, 42), got.gen);
    try std.testing.expectEqual(@as(usize, 2), got.rects.len);
    try std.testing.expectEqual(@as(u16, 32), got.rects[1].h);
}

test "reader skips unknown tags" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, EvTitle{ .view = 1, .title = "a" });
    // A frame from a newer peer: an unassigned tag in the a11y block.
    try buf.appendSlice(gpa, &[_]u8{ 3, 0, 0, 0, 0x77, 0xAA, 0xBB });
    try encode(gpa, &buf, EvCrashed{ .view = 2 });

    var r = Reader.init(buf.items);
    const first = (try r.next()).?;
    try std.testing.expectEqual(Tag.ev_title, first.tag);
    const second = (try r.next()).?;
    try std.testing.expectEqual(Tag.ev_crashed, second.tag);
    try std.testing.expectEqual(@as(u32, 2), (try decode(EvCrashed, second.payload)).view);
    try std.testing.expectEqual(@as(?Frame, null), try r.next());
    try std.testing.expectEqual(buf.items.len, r.consumed());
}

test "reader holds back partial frames" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, Navigate{ .view = 1, .url = "https://example.com/" });

    // Every prefix short of the whole frame yields nothing and consumes
    // nothing, so the caller keeps accumulating.
    var cut: usize = 0;
    while (cut < buf.items.len) : (cut += 1) {
        var r = Reader.init(buf.items[0..cut]);
        try std.testing.expectEqual(@as(?Frame, null), try r.next());
        try std.testing.expectEqual(@as(usize, 0), r.consumed());
    }
    var full = Reader.init(buf.items);
    try std.testing.expect((try full.next()) != null);
}

test "truncated payload is an error, not a read past the frame" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, Navigate{ .view = 1, .url = "https://example.com/" });
    // Claim a 4-byte payload for a frame that needs far more.
    var short: [9]u8 = undefined;
    std.mem.writeInt(u32, short[0..4], 5, .little);
    short[4] = @intFromEnum(Tag.navigate);
    @memcpy(short[5..9], buf.items[9..13]);
    var r = Reader.init(&short);
    const frame = (try r.next()).?;
    try std.testing.expectError(error.Truncated, decode(Navigate, frame.payload));

    var bad = Reader.init(&[_]u8{ 0, 0, 0, 0, 1 });
    try std.testing.expectError(error.BadFrame, bad.next());
}

test "outbox drains in order with partial writes" {
    const gpa = std.testing.allocator;
    var ob = Outbox.init(gpa);
    defer ob.deinit();
    try ob.post(EvTitle{ .view = 1, .title = "one" }, null);
    try ob.post(EvCrashed{ .view = 2 }, 7);
    try std.testing.expect(!ob.empty());

    const first = ob.front().?;
    try std.testing.expectEqual(@as(u8, 0), first.nfds);
    ob.advance(1);
    try std.testing.expectEqual(first.bytes.len - 1, ob.front().?.bytes.len);
    ob.advance(first.bytes.len - 1);

    const second = ob.front().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{7}, second.fdSlice());
    ob.advance(second.bytes.len);
    try std.testing.expect(ob.empty());
}

test "inline frame round-trips rects, encodings and pixel payloads" {
    const gpa = std.testing.allocator;
    try roundTrip(FrameMode, .{ .mode = frame_mode_inline });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const px_a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const px_b = [_]u8{ 0xAA, 0xBB };
    const rects = [_]InlineRect{
        .{ .x = 0, .y = 0, .w = 2, .h = 1, .enc = inline_enc_raw, .data = &px_a },
        .{ .x = 10, .y = 20, .w = 30, .h = 40, .enc = inline_enc_deflate, .data = &px_b },
    };
    try encode(gpa, &buf, FrameInline{ .view = 7, .gen = 99, .w = 640, .h = 480, .rects = &rects });
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.frame_inline, frame.tag);
    const got = try FrameInline.decodeAlloc(frame.payload, gpa);
    defer gpa.free(got.rects);
    try std.testing.expectEqual(@as(u32, 99), got.gen);
    try std.testing.expectEqual(@as(u16, 640), got.w);
    try std.testing.expectEqual(@as(usize, 2), got.rects.len);
    try std.testing.expectEqualSlices(u8, &px_a, got.rects[0].data);
    try std.testing.expectEqual(inline_enc_deflate, got.rects[1].enc);
    try std.testing.expectEqual(@as(u16, 40), got.rects[1].h);
    try std.testing.expectEqualSlices(u8, &px_b, got.rects[1].data);

    // Truncated rect list errors instead of reading past the frame.
    try std.testing.expectError(error.Truncated, FrameInline.decodeAlloc(frame.payload[0 .. frame.payload.len - 1], gpa));
}

test "reader ids extend the semantic family and leave 0xD0 reserved" {
    try std.testing.expectEqual(@as(u8, 0x68), @intFromEnum(Tag.sem_read));
    try std.testing.expectEqual(@as(u8, 0x69), @intFromEnum(Tag.sem_read_result));
    try std.testing.expectEqual(@as(u8, 0x6A), @intFromEnum(Tag.sem_read_ids));
    try std.testing.expectEqual(@as(u8, 0x6B), @intFromEnum(Tag.sem_read_ids_result));
    try std.testing.expectEqual(@as(u8, 0x6C), @intFromEnum(Tag.sem_act_guarded));
    try std.testing.expectEqual(@as(u8, 0x6D), @intFromEnum(Tag.sem_request));
    try std.testing.expectEqual(@as(u8, 0x6E), @intFromEnum(Tag.sem_result));
    try std.testing.expectEqual(@as(u8, 0xD0), @intFromEnum(Tag.frame_mode));
    try std.testing.expectEqual(@as(u8, 0xD1), @intFromEnum(Tag.frame_inline));
    for (0xD2..0xD8) |raw| {
        try std.testing.expect(!(@as(Tag, @enumFromInt(raw))).known());
    }
}

test "a correlated semantic request wraps and unwraps losslessly" {
    const gpa = std.testing.allocator;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    const wrapped = try semRequestWrap(gpa, &payload, 42, SemRead{ .view = 7 });
    try std.testing.expectEqual(@as(u32, 42), wrapped.request);
    try std.testing.expectEqual(@intFromEnum(Tag.sem_read), wrapped.kind);
    const frame = semResultUnwrap(.{ .request = 42, .kind = wrapped.kind, .payload = wrapped.payload });
    try std.testing.expectEqual(Tag.sem_read, frame.tag);
    const inner = try decode(SemRead, frame.payload);
    try std.testing.expectEqual(@as(u32, 7), inner.view);
}

test "a dma-buf frame round-trips its planes" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const sent = FrameDmabuf{
        .view = 3,
        .buf_id = 9,
        .gen = 1234,
        .w = 3840,
        .h = 2160,
        .fourcc = 0x34325241, // DRM_FORMAT_ARGB8888
        .modifier = 0x0100000000000005,
        .nplanes = 2,
        .planes = .{
            .{ .stride = 15360, .offset = 0 },
            .{ .stride = 7680, .offset = 33_177_600 },
            .{ .stride = 0, .offset = 0 },
            .{ .stride = 0, .offset = 0 },
        },
    };
    try encode(gpa, &buf, sent);
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectEqual(Tag.frame_dmabuf, frame.tag);
    const got = try FrameDmabuf.decodeFrom(frame.payload);
    try std.testing.expectEqual(sent.modifier, got.modifier);
    try std.testing.expectEqual(sent.fourcc, got.fourcc);
    try std.testing.expectEqual(@as(u8, 2), got.nplanes);
    try std.testing.expectEqual(@as(u32, 15360), got.planes[0].stride);
    try std.testing.expectEqual(@as(u32, 33_177_600), got.planes[1].offset);
    try std.testing.expectEqual(@as(u16, 2160), got.h);
}

test "a dma-buf frame with an impossible plane count is refused" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(gpa, &buf, FrameDmabuf{
        .view = 1,
        .buf_id = 1,
        .gen = 1,
        .w = 8,
        .h = 8,
        .fourcc = 0,
        .modifier = 0,
        .nplanes = 1,
        .planes = @splat(.{ .stride = 32, .offset = 0 }),
    });
    // The plane count sits right after the 8 modifier bytes.
    const n_off = 4 + 1 + 4 + 4 + 4 + 2 + 2 + 4 + 8;
    buf.items[n_off] = 7;
    var r = Reader.init(buf.items);
    const frame = (try r.next()).?;
    try std.testing.expectError(error.BadPlaneCount, FrameDmabuf.decodeFrom(frame.payload));
}

test "one message carries a descriptor per plane, and only on the first write" {
    const gpa = std.testing.allocator;
    var ob = Outbox.init(gpa);
    defer ob.deinit();
    try ob.postFds(EvCrashed{ .view = 1 }, &[_]i32{ 11, 12, 13 });
    const m = ob.front().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{ 11, 12, 13 }, m.fdSlice());
    ob.advance(2);
    try std.testing.expectEqual(@as(u8, 0), ob.front().?.nfds);
    ob.advance(m.bytes.len - 2);
    try std.testing.expect(ob.empty());
    try std.testing.expectError(error.TooManyFds, ob.postFds(EvCrashed{ .view = 1 }, &[_]i32{ 1, 2, 3, 4, 5 }));
}
