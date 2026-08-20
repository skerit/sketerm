# Headless web profiles + web_close — implementation plan (2026-08-21)

Status: BINDING plan for the profiles/lifecycle phase of the MCP
migration (implement after the structured-results waves land). Produced
from a source-verified design pass on 2026-08-21; line anchors were
checked against the tree that day and may drift — find by content.

## Verified ground truth

| Fact | Anchor |
|---|---|
| Headless helper already gets a cache dir: `--cache-dir <instance-dir>/web-cache` | src/ipc/webdrive.zig:503-504,558 |
| That dir is under `$XDG_RUNTIME_DIR/sketerm/mcp-tmp-<pid>` / `mcp-<name>` | src/ipc/mcp.zig:378-399, mcp.zig:806 |
| `--cache-dir` becomes `Server.profile_dir` -> `Host.profile_dir` | src/web/main.zig:155-171, src/web/server.zig:162-164,219, src/web/cefhost.zig:850 |
| A persistent context's jar is `{profile_dir}/contexts/{sanitized_name}-{id}`; ephemeral gets an empty `cache_path` = CEF in-memory store | cefhost.zig:1088-1101, cefhost.zig:8681-8694 |
| `sanitizeContextName` appends `-{id}` -> the client-allocated context id is half the on-disk path. Ids must be persisted, exactly like the GUI does | cefhost.zig:8690-8693, src/mux/webstore.zig:208-213, src/ui/webface.zig:1605-1616 |
| `settings.cache_path` (the global context) is never set — only `root_cache_path`. Context 0 is an in-memory jar today, in both GUI and headless: no cookie survives a helper restart | cefhost.zig:11940-11942 |
| `context_create` has no ack frame; the only negative signal is `ev_view_create_failed` (0x92), which requires CAP_CONTEXTS_FAIL_CLOSED or an old helper silently resolves through the global context | src/web/protocol.zig:99-110,2168-2210, src/web/server.zig:446-447, cefhost.zig:1065-1077 |
| webdrive ignores `ev_view_create_failed` (no case in `dispatch`) and tracks no contexts caps | webdrive.zig:1114-1146,1238-1240 |
| `openView` hardcodes `.context = 0` twice | webdrive.zig:658-691 (671, 680) |
| `closeView(id)` exists and already re-homes `current` | webdrive.zig:693-704 |
| GUI `web-list` reports no container/profile field | src/ui/remotectl.zig:932-969 |
| GUI `web-open` already accepts `container` (an existing GUI-side identity container) | remotectl.zig:992-1001 |
| The webdrive tests are pure bookkeeping (no fake helper); the scripted fake helper lives in the smoke binary | webdrive.zig:1305-1448, src/smoke_mcp.zig:2204-2300 |
| `fakeWebengine` advertises only `frames-shm, semantic, view-create-url` | smoke_mcp.zig:2249-2254 |
| Every src file must appear in BOTH test roots (script-enforced) | src/tests.zig, src/tests_core.zig, dist/test-test-roots.sh |

No change to `src/web/**` is required. The helper already implements
everything; the gap is entirely client-side (webdrive/mcp_web) plus a
durable root cache.

## Design decisions

**D1 — The durable part is the root cache dir; ids are persisted next to
it.** CEF requires a context's `cache_path` to be a child of
`root_cache_path`, so profile jars cannot live outside the helper's root
cache. The helper's `--cache-dir` moves from the volatile runtime dir to
a durable profile store root:

```
$XDG_STATE_HOME/sketerm/web-profiles/<instance-key>/
├── lock            # flock'd for the engine's lifetime, contains the owner pid
├── profiles.json   # {"v":1,"next_id":N,"profiles":[{"name","id","created_ms","last_used_ms"}]}
├── cef.log
└── contexts/
    └── work-3/     # helper-created; name is verbatim (our charset ⊂ sanitize's)
```

`<instance-key>` = the MCP instance name (`--name work` -> `work`) else
`anon`. It is NOT the GUI's `$XDG_STATE_HOME/sketerm/web-cache`
(src/web/main.zig:397): two CEF processes must never share a
`root_cache_path`.

**D2 — Context 0 semantics untouched.** The global context stays
in-memory, so "no `profile` argument" keeps today's behaviour byte for
byte: a shared, throwaway jar that dies with the helper.

**D3 — Two-process collision -> an flock at the store root, not per
profile.** The root cache is process-exclusive. If the lock cannot be
taken, the engine falls back to the old volatile `<dir>/web-cache` and
every profile request is refused with the owner pid named. Named
instances make this a non-issue; `anon` degrades honestly.

**D4 — Reset retires the id.** `web_profile_reset` sends
`context_destroy`, removes `contexts/<name>-<id>`, and drops the entry
so the next use mints a fresh id. Even a partially failed rm -rf can
then never resurface as "that profile's cookies", because the new jar
path is a new directory.

**D5 — Fail closed, in three places.** Refuse unless (a) both
CAP_CONTEXTS and CAP_CONTEXTS_FAIL_CLOSED are advertised, (b) the store
is open and writable, (c) no `ev_view_create_failed` arrived for the new
view. No shared-jar fallback, ever.

**D6 — `web_close` in GUI mode closes the pane** via the existing
`close-pane` control command (remotectl.zig:793-796) — the GUI handle IS
the pane id, and `close_pane` already grants exactly this authority. The
tool description states it is destructive and identical to close_pane.
(Page-granular close for multi-page web panes — webgroup.Group — is a
follow-up needing a new GUI verb.)

**D7 — `profile` is refused in GUI mode** (invalid_args, pointing at the
GUI's containers). The GUI's containers are user-visible, coloured,
named identities in webstore; minting one from an MCP call would
surprise the user. The plumbing (remotectl.zig:992-1001 `req.container`)
exists for a later opt-in.

**D8 — Two profile tools, not one.** `web_profiles` is ro,
`web_profile_reset` is rw; merging them would make a browser:ro policy
either withhold listing or expose deletion.

## Ordered implementation steps

### Step 1 — New GTK-free module `src/ipc/webprofiles.zig`

```zig
pub const MAX_NAME = 64;
pub const EPHEMERAL_BASE: u32 = 0x4000_0000; // persistent ids stay below

pub fn validName(name: []const u8) bool;      // [a-z0-9_-]{1,64}, not "default"/"none"

pub const Entry = struct { name: []u8, id: u32, created_ms: i64, last_used_ms: i64 };

pub const OpenError = error{ NoStateDir, Locked, PathTooLong, Io, OutOfMemory };

pub const Store = struct {
    gpa: std.mem.Allocator,
    root: []u8,              // .../web-profiles/<instance-key>
    lock_fd: c_int = -1,
    holder_pid: c.pid_t = 0, // filled on error.Locked
    entries: std.ArrayList(Entry) = .empty,
    next_id: u32 = 1,

    pub fn open(gpa: std.mem.Allocator, instance: ?[]const u8) OpenError!Store;
    pub fn deinit(self: *Store) void;                    // closes lock_fd
    pub fn ensure(self: *Store, name: []const u8) !u32;  // existing id, else mint + save
    pub fn find(self: *const Store, name: []const u8) ?Entry;
    pub fn touch(self: *Store, name: []const u8, now_ms: i64) void;
    pub fn retire(self: *Store, name: []const u8) !bool; // drop entry, save, rmtree jar
    pub fn jarPath(self: *const Store, buf: *[4096]u8, e: Entry) ![]const u8;
    pub fn sweepOrphans(self: *Store) void;              // contexts/* not in entries
};
```

- `open`: `pathz.makeDirs(root, 0o700)` (src/util/pathz.zig:28) -> open
  `<root>/lock` O_CREAT|O_CLOEXEC 0600 -> `c.flock(LOCK_EX|LOCK_NB)`; on
  EWOULDBLOCK read the pid stored in the file and return error.Locked.
  Pattern precedent: src/mux/xwayland.zig:284,310-323.
- Persist with `atomicwrite.writeFile` (src/util/atomicwrite.zig:111) —
  mode 0600, staged sibling + rename + parent sync.
- Corruption recovery: if profiles.json is missing/unparseable, rebuild
  entries by listing `contexts/` and splitting each `name-<digits>` dir;
  `next_id = max(id)+1`. Never mint an id an existing dir already uses
  (that would hand profile A profile B's cookies). If the listing itself
  fails, leave the store degraded -> all profile ops return io_failed.
- Path-length guard: `root.len + "/contexts/".len + MAX_NAME + 12 < 1024`
  (the path_buf in cefhost.zig:1095), else error.PathTooLong -> profiles
  refused with a described error.
- Include a local rmTree (~25 lines, opendir/unlinkat recursion) rather
  than importing src/mux/daemon.zig:882 — keeps webdrive's test-core
  link graph clean.
- Register in src/tests.zig AND src/tests_core.zig.

### Step 2 — `webdrive.Engine`: contexts, store, profile map

1. Caps (webdrive.zig:1116-1146, mirroring webface.zig:1214-1215):
   `cap_contexts: bool = false, cap_contexts_fail_closed: bool = false` —
   set in `.hello_ack`, cleared in `lost()` (webdrive.zig:455-475).
2. Helper generation: `helper_gen: u32 = 0`, `+%= 1` at the end of a
   successful startHelper (webdrive.zig:527-627), so
   republish-after-crash is derivable.
3. Store + live profile table on Engine (near webdrive.zig:253-271):
   ```zig
   store: ?webprofiles.Store = null,
   store_reason: []const u8 = "",   // static string when profiles unavailable
   live: std.ArrayList(LiveCtx) = .empty,
   next_eph: u32 = webprofiles.EPHEMERAL_BASE,

   const LiveCtx = struct {
       id: u32, name: []u8, ephemeral: bool,
       published_gen: u32 = 0, views: u32 = 0,
   };
   ```
4. `ensure()` (webdrive.zig:478-524): before the first startHelper, try
   `webprofiles.Store.open(gpa, instance)`. Success -> cache_z =
   store.root; failure -> keep the volatile `"{s}/web-cache"` and record
   store_reason ("another sketerm mcp process (pid N) owns the browser
   profile store; run this one with --name <x>" etc.). The instance name
   must be kept on Engine — extend init (webdrive.zig:273-283) to dupe
   it (it currently only builds client_name).
5. ProfileSpec + openViewIn replacing the hardcoded `.context = 0`:
   ```zig
   pub const ProfileSpec = union(enum) { default, named: []const u8, ephemeral };
   pub const ProfileError = error{
       ContextsUnsupported, StoreUnavailable, StoreLocked, InvalidName, StoreIo,
   };
   pub fn openViewIn(self: *Engine, url: []const u8, w: u16, h: u16,
                     spec: ProfileSpec) !*View;
   pub fn openView(...) { return self.openViewIn(url, w, h, .default); }
   ```
   openViewIn order (fail closed BEFORE any view is minted, so a refusal
   leaks nothing into the shared jar): ensure() -> if spec != .default:
   check cap_contexts and cap_contexts_fail_closed -> check store != null
   (named only) -> validName -> resolveContext(spec) -> only then
   create(View)/views.append/view_create{_url} with .context = ctx_id
   and ViewShow.
   resolveContext:
   - .named: store.ensure(name) -> id; find/create the LiveCtx; if
     published_gen != helper_gen, send(ContextCreate{ .id, .ephemeral=0,
     .name=name, .proxy="" }) and set published_gen = helper_gen;
     views += 1; store.touch.
   - .ephemeral: id = next_eph; next_eph += 1; send(ContextCreate{ .id,
     .ephemeral=1, .name="eph", .proxy="" }); views = 1.
   Frame ordering on one stream guarantees the helper handles
   context_create before view_create.
6. View gains (webdrive.zig:127-190): `context: u32 = 0`,
   `profile: ?[]u8 = null` (owned, freed in View.deinit),
   `ephemeral_ctx: bool = false`, `create_failed: ?[]u8 = null`.
7. `ev_view_create_failed` — new case in dispatch (webdrive.zig:1114):
   decode proto.EvViewCreateFailed, set v.create_failed. This is the
   ONLY creation-failure signal (context_create has no ack).
8. closeView (webdrive.zig:693-704): after the existing removal,
   releaseContext(v.context) — decrement LiveCtx.views; at 0 AND
   ephemeral, send(ContextDestroy{.id}) and remove the LiveCtx.
   Persistent contexts are kept published (a later web_open on the same
   profile must not pay a re-create) and are never destroyed at engine
   shutdown: deinit kills the helper, which is sufficient — racing the
   kill risks a half-flushed jar. deinit must additionally store.deinit()
   (drops the flock) after the helper is reaped.
9. Profile query API for the tools:
   ```zig
   pub const ProfileInfo = struct { name: []const u8, id: u32, views: u32, last_used_ms: i64, live: bool };
   pub fn profileList(self: *Engine, arena) ![]ProfileInfo;      // store ∪ live
   pub fn profileStorePath(self: *const Engine) ?[]const u8;
   pub fn profilesAvailable(self: *Engine) bool;                 // caps ∧ store
   pub fn profileUnavailableReason(self: *Engine) []const u8;
   pub fn resetProfile(self: *Engine, name: []const u8) !void;   // conflict if views>0
   ```
   resetProfile: refuse (error.InUse) if any live view has that profile
   -> send(ContextDestroy{id}) -> drop LiveCtx -> store.retire(name)
   (rmtree + save). Next use mints a new id (D4). profileList must not
   spawn the helper (same rule listViews follows at mcp_web.zig:290-292),
   so it reads the store and only reports caps if the engine is already
   .ready.

No-hang audit: every new path is send-only or pure store I/O. No new
recv. ev_view_create_failed is absorbed by the existing settle poll. The
watchdog fd (webdrive.zig:428) is unchanged.

### Step 3 — `src/ipc/mcp_web.zig`

1. View (mcp_web.zig:154-171) gains `profile: []const u8 = ""`,
   `profile_kind: []const u8 = "default"`, `create_failed: []const u8 = ""`;
   populated in listViews's .headless arm (mcp_web.zig:290-311); the
   .gui arm leaves them empty.
2. openView (mcp_web.zig:515-537) takes a spec: webdrive.ProfileSpec;
   the .gui arm returns .err when spec != .default: "a sketerm GUI is
   attached, so web_open drives the user's real tabs; named profiles are
   a headless-only feature (the GUI has its own identity containers).
   Run this MCP server without --shared/--socket for profiles."
   The .headless arm calls openViewIn and maps each ProfileError to a
   typed ErrCode: ContextsUnsupported/StoreLocked/StoreUnavailable ->
   .unavailable, InvalidName -> .invalid_args, StoreIo -> .io_failed.
3. web_open handler (mcp_web.zig:792-855):
   - parse profile / ephemeral; both set -> errRes(.invalid_args,
     "web_open takes either 'profile' (a named persistent identity) or
     ephemeral:true (a throwaway one), not both").
   - in the settle loop: if found.create_failed.len != 0,
     drv.headless.closeView(new_handle) and return errRes(.io_failed,
     "...the browser helper refused the identity context for profile 'x'
     (<reason>); nothing was opened and NO page was loaded in the shared
     cookie jar").
   - Res fields added: profile (field), profile_kind (field),
     context (fact).
4. web_tabs (mcp_web.zig:748-790): per view, profile + profile_kind in
   structuredContent; the text lane prints profile only when non-empty.
   GUI mode omits both (a later remotectl WebViewInfo.container addition
   can fill them).
5. New handlers, placed BEFORE the "everything below addresses an
   existing view" cut at mcp_web.zig:857 (web_close must resolve its own
   handle; web_profiles must work with zero views):
   - web_close: .headless -> findView else errRes(.not_found, ...);
     closeView; Res{ closed, remaining, current, profile_released }.
     .gui -> mcp.ipcParsed(.{ .cmd = "close-pane", .pane = handle })
     (remotectl.zig:793).
   - web_profiles: .gui -> errRes(.unavailable, ...); .headless ->
     profileList + store path + contexts_supported.
   - web_profile_reset: .gui -> .unavailable; error.InUse ->
     errRes(.conflict, "profile 'x' is in use by view(s) N; close them
     with web_close first").
6. capabilities (src/ipc/mcp.zig, capabilitiesTool): in the
   headless/session arms add web_profiles: bool + web_profile_store
   (path or the refusal reason). This is the discoverability half of
   fail-closed.

### Step 4 — Tool table entries (`src/ipc/mcp_tools.zig`)

Three new ToolDef entries (group = .browser) plus web_open additions.

web_open — added input properties:
```json
"profile": {"type":"string","description":"Named persistent browsing identity: its own cookie jar and cache, isolated from every other profile and from the default one. Cookies/logins survive this view, MCP restarts and helper crashes (SESSION cookies do not — they die with the browser process). [a-z0-9_-], max 64 chars. Headless only; refused with a GUI attached. Refused (nothing is opened) if the browser helper cannot provide an isolated context — there is no fallback to the shared jar."},
"ephemeral": {"type":"boolean","description":"Open in a FRESH throwaway identity (in-memory jar, incognito-shaped), destroyed with the view. Cannot be combined with 'profile'."}
```

web_open — output schema additions:
```json
{"profile":{"type":"string"},
 "profile_kind":{"type":"string","enum":["default","named","ephemeral"]},
 "context":{"type":"integer","description":"Engine identity-context id; 0 = the shared default jar"}}
```

web_close:
```json
{"name":"web_close",
 "description":"Close a web view. Headless: destroys the helper view and, if it was the last user of an ephemeral identity, that identity too (a named profile's storage is kept — use web_profile_reset to erase it). With a GUI attached this closes the user's PANE, exactly like close_pane, and is destructive. Omitting 'pane' closes the CURRENT view (web_tabs marks it).",
 "inputSchema":{"type":"object","properties":{"pane":{"type":"integer"},"view":{"type":"integer"}}},
 "outputSchema":{"type":"object","properties":{
   "closed":{"type":"integer"},"remaining":{"type":"integer"},
   "current":{"type":"integer","description":"View a later handle-less call now addresses; 0 = none left"},
   "profile":{"type":"string"},
   "profile_released":{"type":"boolean","description":"true when this was the last view of an ephemeral identity, which was destroyed with it"}},
  "required":["closed","remaining","current"]}}
```

web_profiles (ro):
```json
{"name":"web_profiles",
 "description":"List the named persistent browsing profiles this server can open web views in (web_open profile:\"name\"), where their storage lives, and how many views currently use each. Headless only.",
 "inputSchema":{"type":"object","properties":{}},
 "outputSchema":{"type":"object","properties":{
   "profiles":{"type":"array","items":{"type":"object","properties":{
     "name":{"type":"string"},"context":{"type":"integer"},
     "views":{"type":"integer"},"last_used_ms":{"type":"integer"},
     "live":{"type":"boolean","description":"published to the running browser helper"}},
     "required":["name","context","views"]}},
   "store":{"type":"string","description":"Directory the profiles' cookies and caches live in"},
   "contexts_supported":{"type":"boolean"},
   "unavailable_reason":{"type":"string"}},
  "required":["profiles","contexts_supported"]}}
```

web_profile_reset (rw):
```json
{"name":"web_profile_reset",
 "description":"Erase a named profile's storage: cookies, logins, cache. Irreversible. Refused while any web view is using the profile — close them with web_close first. The name stays usable; the next web_open with it starts from an empty, freshly allocated jar.",
 "inputSchema":{"type":"object","properties":{"profile":{"type":"string"}},"required":["profile"]},
 "outputSchema":{"type":"object","properties":{
   "profile":{"type":"string"},"deleted":{"type":"boolean"},
   "retired_context":{"type":"integer"}},
  "required":["profile","deleted"]}}
```

### Step 5 — Docs

- src/ipc/CLAUDE.md (MCP web tools paragraph): add the profile model —
  durable store root, ids persisted because the jar path embeds them,
  fail-closed on missing caps, the flock, and "context 0 is an in-memory
  jar in both modes: without a profile, nothing about a browsing session
  survives the helper".
- src/web/CLAUDE.md: one line under the cookies section noting the
  headless client now points --cache-dir at a durable store and relies
  on CAP_CONTEXTS_FAIL_CLOSED; no helper code changes.

## Edge cases (each needs a decided answer in code)

1. profile + ephemeral together -> invalid_args.
2. Reserved names "default", "none" -> invalid_args.
3. Helper lacks either contexts cap (old helper, fakeWebengine) ->
   refuse, no view minted.
4. Store locked by another MCP process -> refuse, naming the pid,
   suggesting --name.
5. profiles.json corrupt -> rebuild from contexts/ listing; never reuse
   an id an existing dir already owns; if the listing fails too, refuse
   (io_failed).
6. Path too long for cefhost's 1024-byte path_buf -> refuse at store
   open, described.
7. Helper crash mid-session: lost() clears views and caps; helper_gen
   bumps at next startHelper; the next openViewIn republishes
   context_create with the SAME persisted id -> same jar.
8. ev_view_create_failed -> view removed, typed error, refcount rolled
   back.
9. Ephemeral id space starts at 0x4000_0000, disjoint from persisted
   ids.
10. web_close of the current view -> closeView already re-homes current;
    the reply states the new one.
11. web_profile_reset while in use -> conflict, listing the view ids.
12. Orphan jar dirs (SIGKILL between rmtree and save) ->
    Store.sweepOrphans at open removes contexts/* with no entry.
13. MCP restart persistence: only the directory is durable. Chromium
    never persists session cookies — the web_open description says so.
14. --shared mode: no isolation dir, configureHeadless never called ->
    profiles report unavailable with that reason.
15. Privacy: store dirs are 0700; docs note Chromium's Linux cookie
    encryption may fall back to a fixed key — the profile store is not a
    secret store.

## Tests

webdrive.zig unit tests (append after :1448; add a pairEngine() helper
that socketpairs an Engine to .ready so emitted frames can be decoded —
the existing tests only inspect state):
1. validName table (accept/reject, length, reserved names).
2. Store: ensure("work") twice -> same id; close, reopen -> SAME id
   (persistence across MCP restarts).
3. Store: a second Store.open on the same root -> error.Locked with the
   first pid.
4. Store: corrupt profiles.json -> rebuilt from contexts/ listing,
   next_id past the highest existing dir.
5. retire("work") -> dir gone, entry gone, next ensure("work") returns a
   DIFFERENT id.
6. openViewIn(.named) with cap_contexts=false -> error,
   views.items.len == 0 and no frame written (fail closed).
7. Same with cap_contexts=true, cap_contexts_fail_closed=false -> still
   refused.
8. Happy path on the socketpair: frames arrive as context_create{id,
   ephemeral=0, name="work", proxy=""} THEN view_create_url{context=id}.
9. Two .ephemeral opens -> distinct ids >= EPHEMERAL_BASE, store
   untouched; closeView of the last one emits context_destroy; a named
   profile's close emits none.
10. ev_view_create_failed -> v.create_failed set; closeView rolls the
    refcount back to 0.
11. After lost() + a fresh handshake, the next named open re-emits
    context_create with the same id.
12. Extend the "current view is the last one touched" test with profile
    bookkeeping across closes.

mcp_web.zig unit tests: profile+ephemeral -> invalid_args; GUI driver +
profile -> the headless-only refusal; web_close of an unknown view ->
not_found; each result parses, has a non-empty {-free text lane, and
matches its declared output schema.

smoke_mcp.zig webStage (real CEF):
- web_open profile:"smoke" -> web_eval sets document.cookie (persistent
  expiry) -> assert the jar dir
  <state>/sketerm/web-profiles/<key>/contexts/smoke-<id> exists.
- web_close -> web_open profile:"smoke" again -> web_eval
  document.cookie contains the value (persistence).
- web_open with NO profile -> the cookie is absent (isolation).
- web_open ephemeral:true -> cookie absent; web_close -> web_tabs shows
  it gone.
- web_profile_reset while the view is open -> isError, "code":"conflict".
- web_close -> reset -> dir gone -> reopen -> cookie gone, and the jar
  dir has a NEW id suffix.
- web_profiles lists "smoke" with views:0 and the store path.
- Restart the whole MCP server between the write and the read (proves
  the durable path, not just one process's memory).

fakeWebengine lane (no CEF, smoke_mcp.zig:2204 / webSessionFakeStage) —
teach the fake to (i) advertise CAP_CONTEXTS/CAP_CONTEXTS_FAIL_CLOSED
under SKETERM_FAKE_WEB_CONTEXTS=1, (ii) append every
context_create/view_create_url to SKETERM_FAKE_WEB_FRAMES, (iii) answer
ev_view_create_failed under SKETERM_FAKE_WEB_CONTEXT_FAIL=1:
- (a) default fake (no caps) -> web_open profile:"x" is isError
  unavailable, and web_tabs reports ZERO views — the fail-closed
  regression guard.
- (b) caps on -> the dumped frames show context_create{ephemeral=0,
  name="x"} before a view_create_url carrying the same nonzero context;
  profiles.json holds that id; restart the MCP server and the SAME id is
  re-sent.
- (c) SKETERM_FAKE_WEB_CONTEXT_FAIL=1 -> web_open profile: errors and
  leaves no view.
- (d) two MCP servers on one instance key -> the second refuses with the
  lock message while its non-profile web_open still works.
- (e) web_close against the fake -> view gone from web_tabs, current
  re-homed.
