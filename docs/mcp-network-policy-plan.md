# Enforced network policy — implementation plan (2026-08-21)

Status: BINDING plan for the network-policy phase (implement after the
web-profiles phase lands). Source-verified 2026-08-21; anchors may
drift — find by content. Companion to docs/mcp-web-profiles-plan.md and
docs/mcp-structured-results.md.

## Verified ground truth

| Fact | Anchor |
|---|---|
| `filter.Engine` is an EasyList subset: `\|\|host^`, substrings, `$type/3p/domain=`, `@@` exceptions, `##` cosmetics. Immutable after build; main thread swaps whole engines, IO thread only reads, under a spinlock | src/web/filter.zig:38-40,110-148,400-467 |
| Resource-class vocabulary (`other document subdocument stylesheet script image font xhr media websocket ping`) — the ONE naming, mirrored on the wire | src/web/filter.zig:47-63, src/web/protocol.zig:1734-1747 |
| `hostWithin(host, base)` = host or subdomain; `registrable`/`sameSite` approximate eTLD+1 | filter.zig:530-563 |
| The one host extractor, with `filtering`/`site`/`prose` options; `filtering` returns "" for `data:`/`about:` | src/web/urlhost.zig:34-72 |
| The hook is `cef_resource_request_handler_t::on_before_resource_load` on the IO thread; verdict inline, `RV_CANCEL` returned. `chrome-extension`-origin loads exempted before matching | src/web/cefhost.zig:7719-7824, exemption 7747 |
| ONE static `cef_client_t` + ONE static `resource_request_handler` shared by every browser -> interception is per BROWSER, attributed by `cef_id` in the `g_int` slot table, NOT per request-context | cefhost.zig:9695-9707,9740, slot lookup 7774-7781 |
| Per-view state: `ISlot{enabled, blocked, total, dirty, next_seq, ring}`, 32 slots, 128-entry ring, 256-byte URL clip. Nothing allocates on the IO thread | cefhost.zig:7400-7440 |
| `blocking_enabled` = `g_int.global_enabled AND slot.enabled`. A per-view `intercept_set` for a view with no slot is SILENTLY DROPPED (existing bug to fix via find-or-create) | cefhost.zig:7782-7783, 2210-2228 |
| `rules_loaded` = rebuilt engine count, set by `interceptReload` (seed list + `$XDG_CONFIG_HOME/sketerm/filters/*.txt`) | cefhost.zig:7543-7603,7380-7396 |
| Slot registration at `spawnBrowserWith` right after `create_browser_sync` AND in `onAfterCreated`; idempotent per view id | cefhost.zig:1292, 10987, interceptRegister 7465-7484 |
| Status/size/duration from `on_resource_load_complete(response, status, received_content_length)` matched to the ring by `request->get_identifier()` | cefhost.zig:7957-7993, 7765-7766 |
| `on_resource_response` (headers) cannot pause or cancel | cefhost.zig:7826-7839, cef_resource_request_handler_capi.h:139-158 |
| `on_resource_redirect` gives a mutable `new_url` but NO cancel and NO return value; helper does not register it today | capi.h:121-137; cefhost.zig:9705-9707 |
| No `on_before_browse` anywhere — top-level navigations only visible as `RT_MAIN_FRAME` requests through `on_before_resource_load` (`rtypeOf`), then `ev_load`/`ev_load_error` | rtypeOf cefhost.zig:7673-7686; protocol.zig:209-210,865-880 |
| Wire block 0x80-0x85 = intercept_set/lists/status_req/status/log_req/log; 0x86-0x8F FREE (next used tag context_create = 0x90) | protocol.zig:254-260 |
| Protocol rules: little-endian, tags append-only, optional features = new frames gated by capabilities, never a version bump | protocol.zig:6-10 |
| `NetEntry`/`InterceptLog` decode positionally with no per-entry length — adding a field to `NetEntry` is a BREAKING change; must be a new frame | protocol.zig:1865-1923 |
| `netLogJson` is the ONE renderer both clients hand to web_network | protocol.zig:1930-1961 |
| Helper caps: one list `unconditional_caps`; frames route in `Server.dispatch` | src/web/server.zig:61-90,422-499 |
| Client side: `webdrive.setNetwork/reloadLists/networkStatus/networkLog`, `cap_intercept`, parked log reply, `View.net_*` | src/ipc/webdrive.zig:1146-1203,318,1538,189-201 |
| web_network MCP tool: enable/disable/toggle/status + paged log; `networkResult` writes facts + a text table | src/ipc/mcp_web.zig networkTool; table entry in mcp_tools.zig |
| Res/ErrCode conventions: two lanes, errRes(code,msg), every tool declares output_schema, the uniform error shape has NO room for extra facts | docs/mcp-structured-results.md |
| Real-CEF MCP smoke uses `file://` fixtures; the loopback-HTTP fixture pattern exists in the helper smoke (`WreqServer`, `UboServer`) | smoke_mcp.zig:1996-2012,2128-2140; smoke_web.zig:2793-2898,4061 |

Gap: nothing today enforces anything BEFORE a request except EasyList
rules. Allow-lists, budgets, deadlines, redirect validation, address
classes, per-request block reasons are all new; the only enforcement
point without a round trip is `onBeforeResourceLoad`.

## Design

### D1 — One declaring home: src/web/netpolicy.zig (new, pure)

std-only (no CEF/GTK), compiled into the helper AND both test roots
(register in src/tests.zig + src/tests_core.zig). Owns the `Policy`
value + bounded parse/validate, the pure decision function, the
private/loopback literal classifier. NO new resource-type names — the
type mask is a u16 over `filter.RType` bits (filter.zig:60-67).

The REASON vocabulary lives in protocol.zig beside NetResource (it is a
wire byte and netLogJson renders its names); netpolicy imports it:

```zig
pub const NetReason = enum(u8) {
    none = 0,
    filter_list = 1,     // EasyList engine cancelled it (today's `blocked`)
    top_host = 2,        // top-level document host not in allow_top_hosts
    sub_host = 3,        // subresource host not in allow_sub_hosts
    resource_type = 4,   // block_types names this filter.RType
    private_address = 5, // literal loopback/private/link-local host
    scheme = 6,
    redirect_host = 7,   // redirect target failed the same host test
    request_cap = 8,
    byte_cap = 9,
    nav_cap = 10,
    deadline = 11,
    _,
};
```

```zig
pub const MAX_HOSTS = 64;
pub const Scheme = enum(u4) { http, https, ws, wss, file, data, blob, about };

/// Immutable after build; helper swaps whole policies under the g_int
/// spinlock exactly the way filter engines are swapped.
pub const Policy = struct {
    arena_state: std.heap.ArenaAllocator,
    serial: u32,
    allow_top: []const []const u8 = &.{},   // hostWithin semantics
    allow_sub: []const []const u8 = &.{},   // empty = allow_top only
    block_types: u16 = 0,                   // filter.RType bits
    allow_schemes: u16 = (1<<http)|(1<<https),
    allow_private: bool = false,
    max_requests: u32 = 0,                  // 0 = unbounded
    max_bytes: u64 = 0,
    max_navigations: u32 = 0,
    deadline_ms: u32 = 0,                   // from install time
};

/// Live accounting in the ISlot, mutated ONLY on the IO thread under
/// the existing g_int lock.
pub const Counters = struct {
    started_ms: i64 = 0,
    requests: u32 = 0, bytes: u64 = 0, navigations: u32 = 0,
    denied: [16]u32 = @splat(0),      // indexed by NetReason
    exhausted: proto.NetReason = .none,
};

pub const Req = struct { url: []const u8, host: []const u8, scheme: []const u8,
                         rtype: filter.RType, is_top: bool };

/// Pure: no allocation, no clock call inside (now_ms passed in).
pub fn decide(p: *const Policy, c: *const Counters, r: Req, now_ms: i64) proto.NetReason;
pub fn isPrivateHostLiteral(host: []const u8) bool;
```

decide order (first hit wins, cheapest first): exhausted != .none ->
that reason; deadline; scheme; private address; type mask; host
allow-list (is_top ? allow_top : allow_sub UNION allow_top); nav cap
(is_top only); request cap; byte cap. Budget hits LATCH `c.exhausted`.

SSRF refusal, stated honestly: CEF exposes no resolved address on any
pre-request callback, so v1 refuses LITERAL 127.0.0.0/8, 0.0.0.0, 10/8,
172.16/12, 192.168/16, 169.254/16, ::1, fc00::/7, fe80::/10, plus
localhost, *.localhost, *.local, *.internal. A hostname RESOLVING to a
private address gets through — documented v1 limitation, mitigated by
the positive host allow-list. State it in the tool description and
src/web/CLAUDE.md.

### D2 — Where a policy is declared: web_open, one place

Policy must bind BEFORE the first request (the first request of a
headless view is issued inside create_browser_sync). So:
- web_open carries `policy` (object) — the ONE install point.
- web_policy_set can register a SESSION DEFAULT per profile name, which
  web_open applies when the call names that profile and passes no
  explicit policy. The default is in-memory on webdrive.Engine,
  deliberately NOT persisted in profiles.json (the corrupt-rebuild path
  would create a silent-loosening hole). web_policy reports
  durable:false and source:"call"|"profile_default".
- Live views: web_policy_set pane:N may only TIGHTEN (intersect host
  sets, min of budgets, union of block_types, allow_private only
  false-ward). Reply names each field tightened and each ignored as a
  loosening.

### D3 — Helper enforcement points

1. onBeforeResourceLoad (cefhost.zig:7719) — the only cancel point.
   Insert AFTER the filter verdict, BEFORE wreqConsider (precedence:
   native filter cancel -> policy cancel -> extension). On deny: bump
   denied[reason], latch exhausted for budget reasons, ring entry with
   blocked=true + reason, return RV_CANCEL. A denied RT_MAIN_FRAME
   request IS a cancelled navigation — CEF surfaces ERR_ABORTED and the
   existing onLoadError posts ev_load_error. No new nav-cancel
   machinery.
2. onResourceLoadComplete — add bytes accounting + latch .byte_cap.
   Byte enforcement is "stop at the first request after the cap is
   crossed", not a hard ceiling — say so in the schema description.
3. onResourceRedirect (NEW; register at cefhost.zig:9705-9707) —
   validate new_url with the same decide. It cannot cancel, so: log
   with redirect_host, latch a violation counter, and REWRITE new_url
   to `sketerm-blocked://policy/<reason>` (unregistered scheme -> load
   fails loudly with ERR_UNKNOWN_URL_SCHEME). Belt-and-braces: if CEF
   re-enters on_before_resource_load for the redirected request, the
   host test denies it anyway (see uncertainties).
4. Deadline, main thread half — new Host.flushNetPolicy() called next
   to flushInterceptStatus() (server.zig:376): for each slot past its
   deadline, stop_load on that browser and post one ev_net_policy.
5. Install path — Host.netPolicySet(req) must FIND-OR-CREATE the slot
   for req.view, and interceptRegister must adopt an existing slot's
   missing ring rather than early-returning (fixes the existing
   silent-drop bug at cefhost.zig:2221-2227).
6. Zero cost when absent — one `slot.pol == null` branch on the hot
   path.

### D4 — Wire additions (cap-gated, append-only)

```
CAP_NET_POLICY = "net-policy"     // beside CAP_INTERCEPT

0x86 net_policy_set   (c->h)  view, serial, flags u32 (allow_private, ...),
                              block_types u16, allow_schemes u16,
                              max_requests u32, max_bytes u64,
                              max_navigations u32, deadline_ms u32,
                              u16 n_top + strs, u16 n_sub + strs
                              // hand-written encodeTo/decodeAlloc like InterceptLists
0x87 net_policy_req   (c->h)  view
0x88 ev_net_policy    (h->c)  view, serial, active u8, exhausted u8(NetReason),
                              requests u32, bytes u64, navigations u32,
                              ms_left u32, denied[12] u32
0x89 net_log_req      (c->h)  view, since u32, max u16
0x8A net_log          (h->c)  view, next_seq u32, entries[] of NetEntry2
                              (= NetEntry + reason u8)
```

New log pair rather than growing NetEntry: InterceptLog decodes
positionally with no per-entry length; a trailing byte corrupts an
older peer. The old pair stays for the GUI face (src/ui/webface.zig:
1405-1412, untouched). netLogJson generalises to NetEntry2 plus a
NetEntry -> NetEntry2 lift (reason = blocked ? filter_list : none) —
still one renderer, one vocabulary.

Fail closed: webdrive.openViewIn refuses (error.PolicyUnsupported)
before minting a view or writing a frame when the cap is absent — same
shape and same reason as ContextsUnsupported. ev_net_policy with a
stale serial is ignored.

### D5 — MCP surface

web_open gains `policy` (object):
- allow_hosts: array<string> — hosts (and subdomains) the TOP-LEVEL
  document may load from. Empty = the host of `url` only.
- allow_subresource_hosts: array<string> — extra hosts subresources may
  use. Empty = allow_hosts only.
- block_types: array<enum other|document|subdocument|stylesheet|script|
  image|font|xhr|media|websocket|ping>
- block_ads: boolean — also enforce the built-in EasyList-subset engine
  (same switch as web_network action:enable)
- allow_schemes: array<enum http|https|ws|wss|file|data|blob|about>,
  default http+https
- allow_private_addresses: boolean, default false (literal refusal; the
  resolves-to-private limitation is documented)
- max_requests, max_bytes, max_navigations, deadline_ms: integers
Description states: refused (nothing opened) if the helper lacks the
net-policy capability — no unpoliced fallback.
Output additions: policy_active (bool), policy_serial (int), policy
(echo of effective policy), policy_source ("call"|"profile_default"|
"none").

web_policy (browser group, ro) — report for a view or profile:
backend, view, policy_active, policy_serial, policy_source, policy,
requests, bytes, navigations, ms_left, exhausted (bool),
exhausted_reason (none|request_cap|byte_cap|nav_cap|deadline),
denied (object: refusals by reason), durable. Required: backend,
policy_active, exhausted, requests, bytes, navigations.

web_policy_set (rw) — {profile?, pane?, policy}; profile = session
default (durable:false); pane = tighten a live view, reply lists
tightened[] and ignored[].

web_network gains `reason` per request entry (enum of NetReason names)
plus policy_active/exhausted facts. Same tool, no second log surface.

Budget exhaustion, loud, two shapes:
- Traffic-causing tools (web_open, web_navigate, web_act, web_eval,
  web_wait for:"load") return errRes(.refused, "network policy
  exhausted for view N: max_requests 500 reached after 500 requests /
  3.1MB / 2 navigations; the page was not navigated. Open a new view
  with a fresh policy, or call web_policy for the full accounting.").
  The uniform error shape has no room for extra facts — numbers ride
  the sentence, web_policy is the machine-readable half.
- Read-only tools (web_read, web_snapshot, web_query, web_tabs,
  web_network, web_screenshot) keep working but every result carries
  policy_exhausted:true + policy_exhausted_reason as FACTS plus one
  text line.
- GUI mode: policy on web_open and both policy tools return
  errRes(.unavailable, ...) — same reasoning as profiles D7.

## Ordered implementation steps

Step 0 (FIRST — can invalidate step 3): measure on the pinned CEF
(151.3.16) whether on_before_resource_load fires again for a 302 to
another host. If yes, the redirect handler is belt-only; if no, the
new_url poison rewrite is the SOLE redirect defence and needs its own
smoke stage. Ship neither claim unmeasured. Also measure whether
`sketerm-blocked://` yields ERR_UNKNOWN_URL_SCHEME; fallback: rewrite
to `data:,` (top-level data: navigation is disallowed by Chromium).

Step 1 — protocol.zig: CAP_NET_POLICY; NetReason; tags 0x86-0x8A;
NetPolicySet (hand-written encode/decode modelled on InterceptLists
:1767-1781, with the @intCast clamp lesson from InterceptSubscribe
:1801-1806); NetPolicyReq; EvNetPolicy; NetEntry2/NetLogReq/NetLog;
netLogJson generalised; round-trip tests beside :3460.

Step 2 — netpolicy.zig (new): Policy, Counters, Req, build/free,
decide, isPrivateHostLiteral, typeMaskFromNames (export filter's name
table rather than restating it). Register in both test roots.

Step 3 — cefhost.zig: ISlot gains pol: ?*netpolicy.Policy, pc:
Counters, pol_dirty; Host.netPolicySet (find-or-create slot, build on
main thread, swap under lock, free old outside it — mirror
interceptReload :7587-7601); interceptRegister adopts existing slots
(allocate missing ring) instead of early-returning; onBeforeResourceLoad
gate between filter verdict and wreqConsider (:7817-7822), ring entry
gains reason; onResourceLoadComplete byte accounting + latch;
onResourceRedirect new callback registered at :9705;
Host.netPolicyStatus, Host.netLog (clone of interceptLog :2297 over
NetEntry2), Host.flushNetPolicy (deadline sweep + stop_load + coalesced
push); interceptUnregister/interceptDeinit free the policy.

Step 4 — server.zig: cap in unconditional_caps (:61-90); four dispatch
arms (:485-497); host.flushNetPolicy() next to flushInterceptStatus()
(:376).

Step 5 — webdrive.zig: cap_net_policy (set in .hello_ack :1538, cleared
in lost() :616); client Policy value + PolicyError{Unsupported,
InvalidHost, TooManyHosts, Loosening}; openViewIn takes ?Policy and
sends net_policy_set BEFORE view_create* (same ordering argument as
context_create), refusing before minting anything when the cap is
absent; View gains pol_* mirrors; dispatch arm for ev_net_policy;
netPolicyStatus/netLogV2 mirroring networkStatus/networkLog (:1158-1203)
— send + bounded pump, no new blocking recv; profile_policy:
StringHashMap(Policy) session defaults.

Step 6 — mcp_web.zig: parsePolicy(args) -> webdrive.Policy (typed
invalid_args for bad host/type/scheme); openView passes it; new
policyTool/policySetTool; the shared fact writer gains policy_exhausted
when set; a single policyGate(drv, view) helper called by the
traffic-causing tools returning the .refused result; headlessFail gains
the new error names; networkResult renders reason.

Step 7 — mcp_tools.zig: web_open input/output additions, two new
ToolDefs, web_network schema additions (these land ON TOP of the
profiles-phase table edits).

Step 8 — docs: src/web/CLAUDE.md (enforcement order filter -> policy ->
extension, the redirect/headers ceilings, the DNS-rebinding limitation,
byte-cap semantics); src/ipc/CLAUDE.md (policy model, fail-closed,
tighten-only, non-durable profile defaults).

## Edge cases (each needs a decided answer in code)

1. policy + GUI backend -> unavailable, naming web_network as the GUI
   equivalent.
2. Helper without CAP_NET_POLICY -> refuse, no view minted, no url
   loaded.
3. Empty allow_hosts WITH a url -> the url's host only. Empty
   allow_hosts with NO url -> invalid_args.
4. Host entry that is a bare IP literal ok; `*` refused outright;
   entries with `/`, `:port`, upper case -> normalise (fold) or refuse.
5. > MAX_HOSTS entries -> invalid_args naming the cap (never silent
   truncation).
6. Policy on a view discarded and revived: slot survives, policy and
   counters survive; counters deliberately do NOT reset — web_policy
   says so.
7. Helper crash -> lost() clears caps and views; re-web_open needs the
   policy again; web_policy on a dead view is not_found.
8. data:/about: have no host (urlhost.filtering returns "") — judged by
   SCHEME only; about:blank always allowed.
9. file:// fixtures have no host — `file` must be an explicit
   allow_schemes entry, default off.
10. Extension traffic (sketerm-extension://) exempt before the gate,
    like the filter engine.
11. Service-worker / cef_urlrequest traffic has no browser -> no slot ->
    currently UNPOLICED. Say so loudly in docs; per-context handler
    (cef_request_context_handler_t::get_resource_request_handler) is
    the follow-up.
12. Slot table full (>32 views, MAX_ISLOTS) -> a policied web_open must
    be REFUSED rather than opening unpoliced.
13. Redirect chain: count redirects toward max_navigations only for
    main-frame hops.
14. max_bytes crossed mid-response -> response completes; next request
    refused. Stated in the schema.
15. deadline_ms with the view idle -> the sweep latches and posts once;
    no busy loop.
16. Two web_opens sharing a profile default: independent counters per
    view — say so in web_policy.
17. web_policy_set loosening attempt -> .refused naming the fields
    (never isError:false "ignored").

## Test plan

netpolicy.zig unit tests (both roots, decision table, no CEF/sockets):
1. top-host allow/deny incl. subdomain, sibling-suffix
   (notads.example), evil.com.attacker.net shapes (mirror
   filter.zig:783-791, urlhost.zig:114-128).
2. sub list empty => top governs; non-empty => union.
3. type mask blocks image/media/font, never a document.
4. private-literal table incl. 172.16/172.32 boundary, [::1], [fe80::1],
   localhost, sub.localhost, x.local; negatives 172.15.x,
   10.example.com, notlocalhost.
5. scheme mask; data:/about:blank handling.
6. budgets latch: request/byte/nav/deadline each latch; every later
   decide returns the SAME reason.
7. deadline monotone against a clock that jumps backwards (the
   filtersub.isStale lesson, filtersub.zig:129-135).
8. decide never allocates and is order-stable.

protocol.zig: round-trip every new frame; NetPolicySet with 64 hosts;
netLogJson renders reason names and lifts a legacy NetEntry; oversized
host list clamps rather than wraps.

webdrive.zig (socketpair pairEngine harness):
9. cap false + policy => error, views.items.len == 0, no frame written.
10. Happy path frame order: net_policy_set{view=N} then
    view_create_url{view=N}.
11. ev_net_policy stale serial ignored; live serial updates View.
12. Tighten-only: loosening returns Loosening; tightening re-emits with
    a new serial.
13. Profile default applies to a later web_open on that profile only.

mcp_web.zig: parsePolicy rejects bad type/host/`*`; GUI + policy =>
unavailable; exhausted view => web_navigate refused while web_read
succeeds carrying policy_exhausted:true; every new result passes
mcp.expectToolResultShape.

fakeWebengine lane (teach the fake: SKETERM_FAKE_WEB_POLICY=1
advertises the cap, SKETERM_FAKE_WEB_FRAMES dumps frames,
SKETERM_FAKE_WEB_POLICY_EXHAUST=1 emits ev_net_policy exhausted):
14. no cap => web_open policy is isError/unavailable AND web_tabs
    reports zero views.
15. cap on => net_policy_set strictly before view_create_url, same view.
16. exhaustion => web_navigate refused with the budget named, web_read
    answers with policy_exhausted:true, web_policy reports counters.

Real-CEF smoke (add a loopback HTTP fixture to smoke_mcp.zig reusing
the WreqServer shape from smoke_web.zig:2793-2898; use
allow_private_addresses:true except stage 17):
17. default => http://127.0.0.1:P/pa refused BEFORE the socket is
    touched: assert the server hit counter stayed 0 (the blockme_hits
    pattern) — a page error alone is not proof.
18. Allow-listed top host + subresource on a second port/host => page
    loads, subresource refused, counter 0, web_network entry
    reason:"sub_host". Also assert the DOCUMENT request itself carries
    a policy verdict (a disallowed initial url is refused, not just its
    subresources).
19. block_types:["image"] => the <img> never reaches the server.
20. 302 to a disallowed host (/redir-offsite route) => target never
    hit, log entry reason:"redirect_host", web_navigate reports the
    failed load. THIS stage validates Step 0's finding.
21. max_requests:3 on a page with 10 subresources => server sees
    exactly 3 (plus the document), web_policy reports
    exhausted_reason:"request_cap", next web_navigate refused.
22. deadline_ms:1500 against a slow-drip route => latched deadline, one
    ev_net_policy, web_read still answers with the exhausted fact.
23. Helper started with the cap suppressed (env kill-switch like
    SKETERM_WEB_DISABLE_READER_IDS) => policied web_open refused, no
    view.

## Flagged uncertainties (verify, do not assume)

- Whether on_before_resource_load fires again for a server redirect in
  CEF 151/NetworkService (Step 0 measures; design correct either way
  but the PRIMARY defence differs).
- Whether sketerm-blocked:// produces ERR_UNKNOWN_URL_SCHEME rather
  than being normalised (measure; fallback `data:,`).
- Timing of the first main-frame request vs interceptRegister: comments
  assert onAfterCreated runs inside create_browser_sync; the
  find-or-create install makes the policy present before either. One
  smoke assertion (stage 18) covers it.
- profiles.json/policy interaction: do NOT persist; if durability is
  wanted later, the corrupt-rebuild path needs a "policy unknown =>
  refuse policied opens" flag first.
