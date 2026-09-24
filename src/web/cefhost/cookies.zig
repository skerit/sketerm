//! Cookies and site data (capability "sitedata") and cross-instance
//! cookie sync (capability "cookie-sync"), split out of `cefhost.zig`.
//! The `Host` methods live here as free functions taking `*Host` and are
//! re-exported from `Host` under their old names.

const std = @import("std");
const SpinLock = @import("../../util/spinlock.zig").SpinLock;
const c = @import("cbindings");
const cef = @import("cef");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const host_icpt = @import("intercept.zig");
const HeapRef = host_mod.HeapRef;
const Host = host_mod.Host;
const JobRef = host_mod.JobRef;
const Utf8 = host_mod.Utf8;
const View = host_mod.View;
const browserHost = host_mod.browserHost;
const jobVisit = host_mod.jobVisit;
const release = host_mod.release;
const releaseArg = host_mod.releaseArg;
const setStr = host_mod.setStr;
const userfreeInto = host_mod.userfreeInto;

// -- cookies + site data (capability "sitedata") -------------------

/// This view's request context, WITH a reference held.
///
/// The browser's own context is the authority (it is the one the
/// page's requests actually use), but a DISCARDED view has no
/// browser at all and still has cookies to show, so the container
/// it was created in answers for it — and view 0's shared jar is
/// the engine's global context.
pub fn requestContextFor(self: *Host, v: *View) ?*cef.cef_request_context_t {
    if (browserHost(v)) |bh| {
        defer release(&bh.base);
        if (bh.get_request_context) |get| {
            if (get(bh)) |rc| return rc;
        }
    }
    if (v.context != 0) {
        // Same rule as `contextForSpawn`: the global context is a
        // DIFFERENT cookie jar and a different cache, so answering a
        // container view from it would report and delete the wrong
        // site's data. No context is an honest failure.
        const rc = self.lookupContext(v.context) orelse return null;
        if (rc.base.base.add_ref) |add| add(&rc.base.base);
        return rc;
    }
    const global: ?*cef.cef_request_context_t = cef.cef_request_context_get_global_context();
    return global;
}

/// This view's cookie manager, WITH a reference held.
pub fn cookieManagerFor(self: *Host, v: *View) ?*cef.cef_cookie_manager_t {
    const rc = self.requestContextFor(v) orelse return null;
    defer release(&rc.base.base);
    const get = rc.get_cookie_manager orelse return null;
    const mgr: ?*cef.cef_cookie_manager_t = get(rc, null);
    return mgr;
}

/// Force every persistent jar to disk (`flush_req`, and the engine's
/// own periodic cadence with `conn == 0`). Chromium commits cookies
/// on a ~30s timer and `cef_shutdown` is otherwise the only forced
/// flush — a long-lived engine needs this to close the loss window.
/// The GLOBAL context is included: with a durable store root, its
/// shared jar is persistent too.
pub fn flushProfileStores(self: *Host, token: u32, conn: u32) void {
    var outstanding: u32 = 0;
    const global: ?*cef.cef_cookie_manager_t = cef.cef_cookie_manager_get_global_manager(null);
    if (global) |mgr| {
        defer release(&mgr.base);
        if (flushOne(mgr)) outstanding += 1;
    }
    for (self.contexts.items) |ctx| {
        if (ctx.ephemeral) continue;
        const get = ctx.rc.get_cookie_manager orelse continue;
        const mgr: *cef.cef_cookie_manager_t = get(ctx.rc, null) orelse continue;
        defer release(&mgr.base);
        if (flushOne(mgr)) outstanding += 1;
    }
    if (outstanding == 0) {
        // Nothing flushable IS completion; an unanswered flush_req
        // would read as a wedged engine.
        if (conn != 0) self.postFlushed(token, conn);
        return;
    }
    self.pending_flushes.append(self.gpa, .{ .token = token, .conn = conn, .outstanding = outstanding }) catch {
        // Cannot track the completions: answer now rather than
        // never. The flushes themselves are already running.
        if (conn != 0) self.postFlushed(token, conn);
    };
}

pub fn flushOne(mgr: *cef.cef_cookie_manager_t) bool {
    const fs = mgr.flush_store orelse return false;
    return fs(mgr, &host_mod.flush_callback) != 0;
}

/// One anonymous flush completion (see `pending_flushes`).
pub fn flushCompleted(self: *Host) void {
    if (self.pending_flushes.items.len == 0) return;
    const p = &self.pending_flushes.items[0];
    if (p.outstanding > 0) p.outstanding -= 1;
    if (p.outstanding == 0) {
        const done = self.pending_flushes.orderedRemove(0);
        if (done.conn != 0) self.postFlushed(done.token, done.conn);
    }
}

pub fn postFlushed(self: *Host, token: u32, conn: u32) void {
    const prev = self.dispatch_conn;
    self.dispatch_conn = conn;
    defer self.dispatch_conn = prev;
    self.post(proto.EvFlushed{ .token = token });
}

/// The url a 0xC8-block request is scoped to: what it named, or the
/// view's current address. Never guessed — an empty result means
/// "there is no site here yet" and the request is answered as a
/// failure rather than run against every site at once.
pub fn siteUrlOf(v: *View, asked: []const u8) []const u8 {
    return if (asked.len != 0) asked else v.url;
}

/// Enumerate the cookies visible to a site (metadata only).
pub fn cookiesReq(self: *Host, req: proto.CookiesReq) void {
    const v = self.find(req.view) orelse return self.postNoCookies(req.view, req.req);
    const url = siteUrlOf(v, req.url);
    if (url.len == 0) return self.postNoCookies(req.view, req.req);
    const mgr = self.cookieManagerFor(v) orelse return self.postNoCookies(req.view, req.req);
    defer release(&mgr.base);
    CookieJob.start(self.gpa, mgr, url, .{
        .view = req.view,
        .req = req.req,
        .mode = .list,
        .kind = .cookies_clear,
        .name = "",
        .detail = "",
    }) orelse self.postNoCookies(req.view, req.req);
}

pub fn postNoCookies(self: *Host, view: u32, req: u32) void {
    self.post(proto.EvCookies{ .view = view, .req = req, .ok = 0, .total = 0, .entries = &.{} });
}

pub fn cookieDelete(self: *Host, req: proto.CookieDelete) void {
    self.deleteCookies(req.view, req.req, req.url, req.name, .cookie_delete, "");
}

pub fn cookiesClear(self: *Host, req: proto.CookiesClear) void {
    self.deleteCookies(req.view, req.req, req.url, "", .cookies_clear, "");
}

/// Shared body of `cookie_delete` / `cookies_clear` and of the
/// cookie half of `sitedata_clear`. An empty `name` deletes every
/// cookie the site can see, host and domain cookies alike — which
/// is why the deletion runs through the VISITOR rather than
/// `delete_cookies(url, ...)`, whose url-only form deliberately
/// spares domain cookies.
pub fn deleteCookies(
    self: *Host,
    view: u32,
    req: u32,
    asked_url: []const u8,
    name: []const u8,
    kind: proto.SitedataKind,
    detail: []const u8,
) void {
    const v = self.find(view) orelse return self.postSiteFail(view, req, kind, detail);
    const url = siteUrlOf(v, asked_url);
    if (url.len == 0) return self.postSiteFail(view, req, kind, detail);
    const mgr = self.cookieManagerFor(v) orelse return self.postSiteFail(view, req, kind, detail);
    defer release(&mgr.base);
    CookieJob.start(self.gpa, mgr, url, .{
        .view = view,
        .req = req,
        .mode = if (name.len != 0) .delete_named else .delete_all,
        .kind = kind,
        .name = name,
        .detail = detail,
    }) orelse self.postSiteFail(view, req, kind, detail);
}

pub fn postSiteFail(self: *Host, view: u32, req: u32, kind: proto.SitedataKind, detail: []const u8) void {
    self.post(proto.EvSitedataDone{
        .view = view,
        .req = req,
        .ok = 0,
        .kind = @intFromEnum(kind),
        .removed = 0,
        .detail = detail,
    });
}

/// Clear an origin's site data: cookies, script-visible storage,
/// and the HTTP cache, each independently selected by `what`.
///
/// TWO ENGINE LIMITS ARE REPORTED, NOT HIDDEN (see
/// `EvSitedataDone.detail`):
///   - `clear_http_cache` is the only cache verb the C API has and
///     it clears the WHOLE request context, so a shared-jar view
///     drops every site's cache. Reported as `cache-whole-context`.
///   - localStorage / sessionStorage / IndexedDB / Cache Storage
///     have no browser-process API at all; they are cleared by
///     running script IN the document, which only works while the
///     view is still ON that origin. A request for another origin's
///     storage is reported as `storage-skipped-origin` rather than
///     silently claiming success.
pub fn sitedataClear(self: *Host, req: proto.SitedataClear) void {
    var detail_buf: [96]u8 = undefined;
    var detail_len: usize = 0;
    const v = self.find(req.view) orelse
        return self.postSiteFail(req.view, req.req, .sitedata_clear, "");
    const url = siteUrlOf(v, req.url);
    if (url.len == 0) return self.postSiteFail(req.view, req.req, .sitedata_clear, "");

    if (req.what & proto.sitedata_storage != 0) {
        if (sameOrigin(url, v.url)) {
            self.clearPageStorage(v);
        } else {
            appendDetail(&detail_buf, &detail_len, "storage-skipped-origin");
        }
    }
    if (req.what & proto.sitedata_cache != 0) {
        if (self.requestContextFor(v)) |rc| {
            defer release(&rc.base.base);
            if (rc.clear_http_cache) |clear| clear(rc, null);
            appendDetail(&detail_buf, &detail_len, "cache-whole-context");
        } else {
            // A destroyed container has no cache left to reach, and
            // claiming success for work nothing performed is what
            // every other arm of this reply refuses to do.
            appendDetail(&detail_buf, &detail_len, "cache-context-gone");
        }
    }
    if (req.what & proto.sitedata_cookies != 0) {
        // The cookie visit is asynchronous and owns the reply, so
        // it carries the detail accumulated above.
        return self.deleteCookies(req.view, req.req, url, "", .sitedata_clear, detail_buf[0..detail_len]);
    }
    self.post(proto.EvSitedataDone{
        .view = req.view,
        .req = req.req,
        .ok = 1,
        .kind = @intFromEnum(proto.SitedataKind.sitedata_clear),
        .removed = 0,
        .detail = detail_buf[0..detail_len],
    });
}

// -- cross-instance cookie sync (capability "cookie-sync") --------

/// Subscribe or unsubscribe one connection. Idempotent both ways.
/// The IO-thread observer is armed by the FIRST subscriber and
/// disarmed by the last, so an unsubscribed helper is back to one
/// relaxed load per saved cookie.
pub fn cookieSyncEnable(self: *Host, conn: u32, enable: bool) void {
    var i: usize = 0;
    while (i < self.cookie_sync_conns.items.len) : (i += 1) {
        if (self.cookie_sync_conns.items[i] != conn) continue;
        if (!enable) _ = self.cookie_sync_conns.orderedRemove(i);
        self.cookieSyncArm();
        return;
    }
    if (enable) self.cookie_sync_conns.append(self.gpa, conn) catch {};
    self.cookieSyncArm();
}

/// Drop a dead connection's subscription (called from `dropConn`).
pub fn cookieSyncDropConn(self: *Host, conn: u32) void {
    self.cookieSyncEnable(conn, false);
}

pub fn cookieSyncArm(self: *Host) void {
    const on = self.cookie_sync_conns.items.len != 0;
    g_cksync.on.store(on, .release);
    if (on) return;
    // Nobody is listening: the shadow is stale the moment the walk
    // stops, so it is dropped rather than kept and trusted later.
    for (self.cookie_shadow.items) |*sh| sh.free(self.gpa);
    self.cookie_shadow.clearRetainingCapacity();
    self.cookie_shadow_seeded.clearRetainingCapacity();
    g_cksync.drain();
}

pub fn cookieSyncOn(self: *const Host) bool {
    return self.cookie_sync_conns.items.len != 0;
}

/// Post one cookie-sync frame to ONE connection, translating the
/// context id back into that connection's namespace. `Host.post`
/// cannot do this: it only rewrites ids on VIEW-routed frames, and
/// every frame in this block is viewless.
pub fn postSyncTo(self: *Host, conn: u32, value: anytype) void {
    const rt = self.router orelse {
        self.out.post(value, null) catch {};
        return;
    };
    const out = rt.route(rt.ctx, conn) orelse return;
    var v2 = value;
    // Persisted context ids are a shared namespace and cross
    // verbatim; only ephemeral ones are windowed per connection.
    if (v2.context >= proto.EPHEMERAL_CTX_BASE) v2.context -= conn * proto.CONN_ID_WINDOW;
    out.post(v2, null) catch {};
}

/// Fan one change out to every subscriber.
pub fn postSyncAll(self: *Host, value: anytype) void {
    if (self.router == null) {
        self.out.post(value, null) catch {};
        return;
    }
    for (self.cookie_sync_conns.items) |conn| self.postSyncTo(conn, value);
}

/// The cookie manager for a CONTEXT id, WITH a reference held.
/// Context 0 is the engine's global jar — which, with a durable
/// `--cache-dir`, is the per-route profile this whole block exists
/// to replicate.
pub fn cookieManagerForContext(self: *Host, id: u32) ?*cef.cef_cookie_manager_t {
    if (id == 0) return cef.cef_cookie_manager_get_global_manager(null);
    const rc = self.lookupContext(id) orelse return null;
    const get = rc.get_cookie_manager orelse return null;
    return get(rc, null);
}

/// Every context this helper synchronises: the shared jar plus each
/// live identity context.
pub fn cookieSyncContexts(self: *Host, buf: []u32) []u32 {
    var n: usize = 0;
    buf[n] = 0;
    n += 1;
    for (self.contexts.items) |ctx| {
        if (n >= buf.len) break;
        buf[n] = ctx.id;
        n += 1;
    }
    return buf[0..n];
}

/// One turn of the cookie-sync machinery, called from the server
/// loop: drain what the IO thread saw, then reconcile on cadence.
pub fn cookieSyncPump(self: *Host, now: i64) void {
    if (!self.cookieSyncOn()) return;
    self.drainSavedCookies();
    if (self.cookie_reconcile_busy != 0) return;
    if (now - self.cookie_reconcile_ms < cookieReconcileMs()) return;
    self.cookie_reconcile_ms = now;
    var ctx_buf: [64]u32 = undefined;
    const ctxs = self.cookieSyncContexts(&ctx_buf);
    for (ctxs) |id| {
        const mgr = self.cookieManagerForContext(id) orelse continue;
        defer release(&mgr.base);
        if (SyncVisitJob.start(self.gpa, mgr, .{
            .mode = .reconcile,
            .context = id,
            .conn = 0,
            .req = 0,
            .cursor = 0,
        })) |_| self.cookie_reconcile_busy += 1;
    }
}

/// MAIN THREAD. Fold everything `can_save_cookie` recorded into the
/// shadow and emit it. A response-header write is emitted from HERE
/// rather than waiting for the next reconcile so a login propagates
/// in milliseconds, and folding it into the shadow at the same time
/// is what stops the reconcile emitting it a second time.
pub fn drainSavedCookies(self: *Host) void {
    var rec: CkRec = undefined;
    while (g_cksync.take(&rec)) {
        // The IO thread could only record the VIEW; the context is
        // main-thread state.
        const context = if (rec.view_id == 0) 0 else blk: {
            const v = self.findAny(rec.view_id) orelse break :blk 0;
            break :blk v.context;
        };
        const ck = proto.SyncCookie{
            .name = rec.slice(&rec.name, rec.name_len),
            .value = rec.slice(&rec.value, rec.value_len),
            .domain = rec.slice(&rec.domain, rec.domain_len),
            .path = rec.slice(&rec.path, rec.path_len),
            .flags = rec.flags,
            .same_site = rec.same_site,
            .priority = rec.priority,
            .creation_ms = rec.creation_ms,
            .last_access_ms = rec.last_access_ms,
            .expires_ms = rec.expires_ms,
        };
        // A Set-Cookie whose expiry is already past IS a deletion;
        // saying so beats making every client rediscover it.
        const removed = ck.expires_ms != 0 and ck.expires_ms <= wallMsNow();
        self.noteCookie(context, ck, removed, .response_header, rec.slice(&rec.url, rec.url_len));
    }
}

/// Fold one observation into the shadow and emit it when it is
/// genuinely new. THE one place a change reaches the wire.
///
/// An identity with an apply in flight is skipped outright: the jar
/// and the shadow disagree until the engine's completion callback
/// lands, and emitting that disagreement is exactly the ping-pong
/// this block must not have.
pub fn noteCookie(
    self: *Host,
    context: u32,
    ck: proto.SyncCookie,
    removed: bool,
    cause: proto.CookieCause,
    url: []const u8,
) void {
    const idh = CookieShadow.identity(context, ck.domain, ck.path, ck.name);
    const sh = self.shadowFind(idh, context, ck.domain, ck.path, ck.name);
    const vh = CookieShadow.valueHash(ck);
    if (sh) |entry| {
        if (entry.pending) return;
        if (removed) {
            entry.free(self.gpa);
            self.shadowRemove(entry);
        } else {
            if (entry.hash == vh) return;
            entry.hash = vh;
            entry.seen = true;
        }
    } else {
        if (removed) return; // never seen it, nothing to forget
        const entry = self.shadowInsert(idh, context, ck) orelse return;
        entry.hash = vh;
    }
    self.postSyncAll(proto.EvCookieChange{
        .context = context,
        .cause = @intFromEnum(cause),
        .removed = if (removed) 1 else 0,
        .url = url,
        .cookie = ck,
    });
}

pub fn shadowFind(
    self: *Host,
    idh: u64,
    context: u32,
    domain: []const u8,
    path: []const u8,
    name: []const u8,
) ?*CookieShadow {
    for (self.cookie_shadow.items) |*sh| {
        if (sh.id_hash != idh or sh.context != context) continue;
        // The hash is a PREFILTER, never the identity: a collision
        // would otherwise silently replicate the wrong cookie.
        if (!std.mem.eql(u8, CookieShadow.normDomain(sh.domain), CookieShadow.normDomain(domain))) continue;
        if (!std.mem.eql(u8, sh.path, path)) continue;
        if (!std.mem.eql(u8, sh.name, name)) continue;
        return sh;
    }
    return null;
}

pub fn shadowInsert(self: *Host, idh: u64, context: u32, ck: proto.SyncCookie) ?*CookieShadow {
    const entry = CookieShadow.init(self.gpa, idh, context, ck) orelse return null;
    self.cookie_shadow.append(self.gpa, entry) catch {
        var tmp = entry;
        tmp.free(self.gpa);
        return null;
    };
    return &self.cookie_shadow.items[self.cookie_shadow.items.len - 1];
}

pub fn shadowRemove(self: *Host, entry: *CookieShadow) void {
    const base = self.cookie_shadow.items.ptr;
    const idx = (@intFromPtr(entry) - @intFromPtr(base)) / @sizeOf(CookieShadow);
    _ = self.cookie_shadow.orderedRemove(idx);
}

/// Drop every shadow entry for a context (its jar went away with
/// it, so remembering its cookies would resurrect them).
pub fn cookieSyncForgetContext(self: *Host, context: u32) void {
    var i: usize = 0;
    while (i < self.cookie_shadow.items.len) {
        if (self.cookie_shadow.items[i].context != context) {
            i += 1;
            continue;
        }
        self.cookie_shadow.items[i].free(self.gpa);
        _ = self.cookie_shadow.orderedRemove(i);
    }
    var j: usize = 0;
    while (j < self.cookie_shadow_seeded.items.len) {
        if (self.cookie_shadow_seeded.items[j] == context) {
            _ = self.cookie_shadow_seeded.orderedRemove(j);
            continue;
        }
        j += 1;
    }
}

pub fn shadowSeeded(self: *Host, context: u32) bool {
    for (self.cookie_shadow_seeded.items) |id| {
        if (id == context) return true;
    }
    return false;
}

pub fn markShadowSeeded(self: *Host, context: u32) void {
    if (self.shadowSeeded(context)) return;
    self.cookie_shadow_seeded.append(self.gpa, context) catch {};
}

/// Write (or remove) one cookie in another instance's stead.
///
/// LOOP PREVENTION, structurally: the identity is marked pending
/// BEFORE the engine call and its shadow entry is settled to the
/// applied value in the completion callback. A reconcile between
/// the two skips the identity entirely, so neither ordering of the
/// two asynchronous events can produce a spurious change — and once
/// settled, the shadow already equals the jar, so the diff is empty.
pub fn cookieApply(self: *Host, req: proto.CookieApply) void {
    const conn = self.dispatch_conn;
    if (req.url.len == 0 or originSlice(req.url).len == 0)
        return self.postApplyDone(conn, req.req, req.context, false, "bad-url");
    const mgr = self.cookieManagerForContext(req.context) orelse
        return self.postApplyDone(conn, req.req, req.context, false, "no-context");
    defer release(&mgr.base);

    const idh = CookieShadow.identity(req.context, req.cookie.domain, req.cookie.path, req.cookie.name);
    var entry = self.shadowFind(idh, req.context, req.cookie.domain, req.cookie.path, req.cookie.name);
    if (entry == null and req.remove == 0) {
        entry = self.shadowInsert(idh, req.context, req.cookie);
    }
    if (entry) |e| {
        e.pending = true;
        e.pending_remove = req.remove != 0;
        e.pending_hash = CookieShadow.valueHash(req.cookie);
    }

    const started = if (req.remove != 0)
        CookieApplyJob.startDelete(self.gpa, mgr, req, conn, idh)
    else
        CookieApplyJob.startSet(self.gpa, mgr, req, conn, idh);
    if (started == null) {
        self.settleApply(idh, req.context, req.cookie, false);
        self.postApplyDone(conn, req.req, req.context, false, "engine-refused");
    }
}

/// Land an apply's outcome on the shadow and clear the pending
/// mark. Called from the engine's completion callback, and from the
/// refusal path above so a failed apply never leaves an identity
/// permanently skipped by the reconcile.
pub fn settleApply(self: *Host, idh: u64, context: u32, ck: proto.SyncCookie, ok: bool) void {
    const entry = self.shadowFind(idh, context, ck.domain, ck.path, ck.name) orelse return;
    if (!entry.pending) return;
    entry.pending = false;
    if (!ok) {
        // The jar is whatever it was; let the next reconcile decide.
        if (entry.hash == 0) {
            entry.free(self.gpa);
            self.shadowRemove(entry);
        }
        return;
    }
    if (entry.pending_remove) {
        entry.free(self.gpa);
        self.shadowRemove(entry);
        return;
    }
    entry.hash = entry.pending_hash;
    entry.adopt = true;
    entry.seen = true;
}

pub fn postApplyDone(self: *Host, conn: u32, req: u32, context: u32, ok: bool, reason: []const u8) void {
    self.postSyncTo(conn, proto.EvCookieApplyDone{
        .req = req,
        .context = context,
        .ok = if (ok) 1 else 0,
        .reason = reason,
    });
}

/// Seed a fresh instance: one PAGE of a context's whole jar.
pub fn cookieDump(self: *Host, req: proto.CookieDumpReq) void {
    const conn = self.dispatch_conn;
    const mgr = self.cookieManagerForContext(req.context) orelse
        return self.postDumpFail(conn, req);
    defer release(&mgr.base);
    if (SyncVisitJob.start(self.gpa, mgr, .{
        .mode = .dump,
        .context = req.context,
        .conn = conn,
        .req = req.req,
        .cursor = req.cursor,
    }) == null) self.postDumpFail(conn, req);
}

pub fn postDumpFail(self: *Host, conn: u32, req: proto.CookieDumpReq) void {
    self.postSyncTo(conn, proto.EvCookieDump{
        .req = req.req,
        .context = req.context,
        .ok = 0,
        .cursor = req.cursor,
        .next_cursor = req.cursor,
        .more = 0,
        .total = 0,
        .cookies = &.{},
    });
}

/// Everything an origin's own scripts can wipe. Guarded one by one:
/// a page served over a scheme where `localStorage` throws on ACCESS
/// (not on use) must still get its IndexedDB cleared.
pub const clear_storage_js =
    "(function(){" ++
    "try{localStorage.clear()}catch(e){}" ++
    "try{sessionStorage.clear()}catch(e){}" ++
    "try{if(indexedDB.databases)indexedDB.databases().then(function(l){" ++
    "l.forEach(function(d){try{indexedDB.deleteDatabase(d.name)}catch(e){}})})}catch(e){}" ++
    "try{if(window.caches)caches.keys().then(function(k){" ++
    "k.forEach(function(n){try{caches.delete(n)}catch(e){}})})}catch(e){}" ++
    "})();";

/// Scheme + authority of `url` ("https://host:8443"), empty when it has
/// no authority at all (about:, data:).
pub fn originSlice(url: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return url[0 .. sep + 3 + end];
}

pub fn sameOrigin(a: []const u8, b: []const u8) bool {
    const oa = originSlice(a);
    if (oa.len == 0) return false;
    return std.ascii.eqlIgnoreCase(oa, originSlice(b));
}

/// Append one comma-separated token to a bounded detail string,
/// dropping it rather than truncating into a token nobody can match.
pub fn appendDetail(buf: []u8, len: *usize, token: []const u8) void {
    const need = token.len + @as(usize, if (len.* == 0) 0 else 1);
    if (len.* + need > buf.len) return;
    if (len.* != 0) {
        buf[len.*] = ',';
        len.* += 1;
    }
    @memcpy(buf[len.*..][0..token.len], token);
    len.* += token.len;
}

/// Milliseconds since the Unix epoch for a CEF base time, which counts
/// MICROSECONDS since the Windows epoch (1601). A time at or before the
/// Unix epoch reads as 0, i.e. "no useful expiry".
pub fn baseTimeMs(bt: cef.cef_basetime_t) u64 {
    const win_to_unix_us: i64 = 11_644_473_600 * std.time.us_per_s;
    const unix_us = bt.val - win_to_unix_us;
    if (unix_us <= 0) return 0;
    return @intCast(@divTrunc(unix_us, 1000));
}

/// One in-flight cookie visit.
///
/// REFCOUNTED FOR REAL, unlike every other client-side struct in this
/// file: `visit_url_cookies` takes ownership of the visitor reference
/// it is handed (CEF's CToCpp wrappers transfer, never add), calls
/// `visit` once per cookie on the UI thread — which under a
/// single-threaded message loop is THIS thread, inside `pump()` — and
/// releases when it is done. The final release is therefore both the
/// "visiting finished" signal and the free, so the answer is posted
/// from there and nowhere else. That also covers the failure path: a
/// manager that refuses the visit destroys the wrapper immediately and
/// the client still gets its (empty) reply.
pub const CookieJob = struct {
    /// FIRST FIELD: CEF is handed `&job.visitor` and hands the same
    /// pointer back as `self`.
    visitor: cef.cef_cookie_visitor_t,
    refs: std.atomic.Value(u32),
    gpa: std.mem.Allocator,
    view: u32,
    req: u32,
    mode: Mode,
    kind: proto.SitedataKind,
    /// Owned copy of the name `delete_named` matches.
    name: []u8,
    /// Owned copy of the detail tokens the reply must carry.
    detail: []u8,
    /// String bytes for every recorded cookie, referenced by OFFSET —
    /// the list grows, so a slice into it would dangle on the realloc.
    strings: std.ArrayList(u8) = .empty,
    recs: std.ArrayList(Rec) = .empty,
    /// Cookies seen, whether or not `recs` had room for them.
    total: u32 = 0,
    removed: u32 = 0,
    /// The manager accepted the visit. False means the cookie store
    /// could not be reached at all, which a client must be able to
    /// tell apart from a site with no cookies.
    accessible: bool = true,

    pub const Mode = enum { list, delete_named, delete_all };

    const Span = struct { off: u32, len: u32 };

    const Rec = struct {
        name: Span,
        domain: Span,
        path: Span,
        flags: u8,
        same_site: u8,
        expires_ms: u64,
        value_len: u32,
    };

    const Opts = struct {
        view: u32,
        req: u32,
        mode: Mode,
        kind: proto.SitedataKind,
        name: []const u8,
        detail: []const u8,
    };

    /// Hand a visitor to `mgr` for `url`. Null means nothing was
    /// started and the caller still owes the client a reply.
    pub fn start(
        gpa: std.mem.Allocator,
        mgr: *cef.cef_cookie_manager_t,
        url: []const u8,
        opts: Opts,
    ) ?void {
        const visit = mgr.visit_url_cookies orelse return null;
        const job = gpa.create(CookieJob) catch return null;
        const name = gpa.dupe(u8, opts.name) catch {
            gpa.destroy(job);
            return null;
        };
        const detail = gpa.dupe(u8, opts.detail) catch {
            gpa.free(name);
            gpa.destroy(job);
            return null;
        };
        job.* = .{
            .visitor = .{
                .base = JobRef.base(),
                .visit = jobVisit,
            },
            .refs = .init(1),
            .gpa = gpa,
            .view = opts.view,
            .req = opts.req,
            .mode = opts.mode,
            .kind = opts.kind,
            .name = name,
            .detail = detail,
        };

        var u = std.mem.zeroes(cef.cef_string_t);
        setStr(url, &u);
        defer cef.cef_string_utf16_clear(&u);
        // The call CONSUMES a reference (CEF's CToCpp wrappers take
        // ownership, they never add one) and may drop it before it even
        // returns, when the manager refuses. A second reference is held
        // across the call so the return value is still readable when
        // the answer is composed — releasing it here is then what
        // triggers `finish` in the ordinary case.
        job.refs.store(2, .release);
        if (visit(mgr, &u, 1, &job.visitor) == 0) job.accessible = false;
        _ = JobRef.release(&job.visitor.base);
        return {};
    }

    pub fn record(self: *CookieJob, cookie: *const cef.cef_cookie_t) void {
        if (self.recs.items.len >= proto.MAX_COOKIE_ENTRIES) return;
        var name = Utf8.init(&cookie.name);
        defer name.free();
        var domain = Utf8.init(&cookie.domain);
        defer domain.free();
        var path = Utf8.init(&cookie.path);
        defer path.free();
        var value = Utf8.init(&cookie.value);
        defer value.free();

        const n = self.intern(name.slice()) orelse return;
        const d = self.intern(domain.slice()) orelse return;
        const p = self.intern(path.slice()) orelse return;

        var flags: u8 = 0;
        if (cookie.secure != 0) flags |= proto.cookie_secure;
        if (cookie.httponly != 0) flags |= proto.cookie_httponly;
        if (cookie.has_expires == 0) flags |= proto.cookie_session;
        if (domain.slice().len != 0 and domain.slice()[0] == '.') flags |= proto.cookie_domain_scoped;

        self.recs.append(self.gpa, .{
            .name = n,
            .domain = d,
            .path = p,
            .flags = flags,
            .same_site = sameSiteOf(cookie.same_site),
            .expires_ms = if (cookie.has_expires != 0) baseTimeMs(cookie.expires) else 0,
            .value_len = @intCast(value.slice().len),
        }) catch {};
    }

    fn intern(self: *CookieJob, s: []const u8) ?Span {
        const off: u32 = @intCast(self.strings.items.len);
        self.strings.appendSlice(self.gpa, s) catch return null;
        return .{ .off = off, .len = @intCast(s.len) };
    }

    pub fn matches(self: *const CookieJob, cookie: *const cef.cef_cookie_t) bool {
        var name = Utf8.init(&cookie.name);
        defer name.free();
        return std.mem.eql(u8, name.slice(), self.name);
    }

    /// Post the answer. Runs from the LAST release, so the visit is
    /// over and every cookie has been seen.
    fn finish(self: *CookieJob) void {
        const host = host_mod.g_host orelse return;
        switch (self.mode) {
            .list => {
                const entries = self.gpa.alloc(proto.CookieEntry, self.recs.items.len) catch {
                    host.postNoCookies(self.view, self.req);
                    return;
                };
                defer self.gpa.free(entries);
                for (entries, self.recs.items) |*e, r| {
                    e.* = .{
                        .name = self.str(r.name),
                        .domain = self.str(r.domain),
                        .path = self.str(r.path),
                        .flags = r.flags,
                        .same_site = r.same_site,
                        .expires_ms = r.expires_ms,
                        .value_len = r.value_len,
                    };
                }
                host.post(proto.EvCookies{
                    .view = self.view,
                    .req = self.req,
                    .ok = if (self.accessible) 1 else 0,
                    .total = self.total,
                    .entries = entries,
                });
            },
            .delete_named, .delete_all => host.post(proto.EvSitedataDone{
                .view = self.view,
                .req = self.req,
                .ok = if (self.accessible) 1 else 0,
                .kind = @intFromEnum(self.kind),
                .removed = self.removed,
                .detail = self.detail,
            }),
        }
    }

    pub fn str(self: *const CookieJob, s: Span) []const u8 {
        return self.strings.items[s.off..][0..s.len];
    }

    /// The LAST release is both "the visit is over" and the free, so
    /// the answer is posted from here and from nowhere else.
    pub fn destroyOwned(self: *CookieJob) void {
        self.finish();
        const gpa = self.gpa;
        self.strings.deinit(gpa);
        self.recs.deinit(gpa);
        gpa.free(self.name);
        gpa.free(self.detail);
        gpa.destroy(self);
    }
};

// ---------------------------------------------------------------------
// Cross-instance cookie sync (capability "cookie-sync")
// ---------------------------------------------------------------------
//
// sketerm runs one helper per network route, each with its own profile
// and therefore its own jar. This block is what makes a login follow
// the user between them: OBSERVE one jar changing, hand the change to
// the client, APPLY what the client hands back.
//
// TWO OBSERVERS, BECAUSE ONE IS NOT ENOUGH — measured on CEF 151.3.16
// (smoke-web stage 41 is the standing proof, and reports both halves):
//
//   - `cef_cookie_access_filter_t::can_save_cookie` fires per
//     `Set-Cookie` RESPONSE HEADER, on the IO thread, with the parsed
//     cookie and the request. It is immediate and exact, and it is the
//     ONLY thing that sees a header write.
//   - It does NOT fire for `document.cookie`, nor for a `CookieStore`
//     write. Both bypass the network stack entirely — there is no
//     resource request to filter — so a script-set session cookie is
//     invisible to it. That is not a bug to work around but the shape
//     of the API: it filters cookie ACCESS BY REQUESTS.
//
// So the header filter is the fast path and a periodic full walk
// (`visit_all_cookies`, diffed against a shadow) is the complete one.
// The walk also covers deletion, which no header observer can see at
// all: a `document.cookie` expiry, a `CookieStore.delete`, and the
// engine's own eviction all reach the wire as a diff.
//
// The two feed ONE funnel (`Host.noteCookie`), which is also where
// loop prevention lives — see `Host.cookieApply`.

/// How often the reconcile walks each jar. Deliberately slow: it is
/// the completeness net under an immediate header path, not the
/// primary mechanism, and a walk of every jar is real UI-thread work.
/// `SKETERM_WEB_COOKIE_SYNC_MS` overrides it (smoke-web runs it fast).
pub const cookie_reconcile_default_ms: i64 = 3_000;

pub fn cookieReconcileMs() i64 {
    const v = c.getenv("SKETERM_WEB_COOKIE_SYNC_MS") orelse return cookie_reconcile_default_ms;
    const n = std.fmt.parseInt(i64, std.mem.span(v), 10) catch return cookie_reconcile_default_ms;
    return if (n <= 0) cookie_reconcile_default_ms else n;
}

/// Wall-clock milliseconds, for comparing against a cookie's expiry
/// (which is an absolute date, not a monotonic instant).
pub fn wallMsNow() u64 {
    const ms = @import("../../util/clock.zig").wallMs();
    return if (ms <= 0) 0 else @intCast(ms);
}

/// Last-known state of ONE cookie in ONE jar.
pub const CookieShadow = struct {
    context: u32,
    /// Prefilter over (context, domain, path, name); the strings below
    /// are the actual identity, always compared before a match counts.
    id_hash: u64,
    domain: []u8,
    path: []u8,
    name: []u8,
    /// `valueHash` of what the jar last held. Never includes creation
    /// or last-access: `last_access` moves on every request the cookie
    /// is sent with, and diffing on it would emit a change per page
    /// load forever.
    hash: u64 = 0,
    /// Marked by the current reconcile walk; an unmarked entry at the
    /// end of a walk is a cookie that left the jar.
    seen: bool = false,
    /// A `cookie_apply` is in flight for this identity. The jar and
    /// this entry disagree until the engine's completion callback
    /// lands, and emitting that disagreement is the ping-pong.
    pending: bool = false,
    pending_remove: bool = false,
    pending_hash: u64 = 0,
    /// An apply just settled on this identity: the NEXT reconcile that
    /// finds the jar disagreeing with `hash` adopts what the jar says
    /// WITHOUT emitting it. The engine normalises what it stores
    /// (a domain cookie gains its dot, an expiry past Chromium's
    /// 400-day cap is clamped), and reporting its normalisation back
    /// to the client as a change is a whole fan-out of frames saying
    /// nothing — 140 of them, measured, before this existed.
    adopt: bool = false,

    /// A cookie's domain WITHOUT its leading dot.
    ///
    /// MEASURED: `set_cookie` with a non-empty `domain` makes a DOMAIN
    /// cookie, which the jar then reports back with a leading dot —
    /// so an applied `site.example` reads back as `.site.example`. Key
    /// the shadow on the dotless form or every applied cookie looks
    /// like one identity leaving the jar and another arriving, which
    /// is a removal AND an add emitted for a cookie nothing changed.
    /// The dot itself is not lost: it travels as
    /// `cookie_domain_scoped` and is part of the VALUE hash.
    fn normDomain(domain: []const u8) []const u8 {
        return if (domain.len != 0 and domain[0] == '.') domain[1..] else domain;
    }

    fn identity(context: u32, domain: []const u8, path: []const u8, name: []const u8) u64 {
        var h = std.hash.Wyhash.init(0x0c00_c1e5);
        h.update(std.mem.asBytes(&context));
        h.update(normDomain(domain));
        h.update(&[_]u8{0});
        h.update(path);
        h.update(&[_]u8{0});
        h.update(name);
        return h.final();
    }

    fn valueHash(ck: proto.SyncCookie) u64 {
        var h = std.hash.Wyhash.init(0x5a17_ed_ba11);
        h.update(ck.value);
        h.update(&[_]u8{ ck.flags, ck.same_site, ck.priority });
        h.update(std.mem.asBytes(&ck.expires_ms));
        // Never zero: `settleApply` reads a zero hash as "this entry
        // was minted by the apply itself and never observed".
        const v = h.final();
        return if (v == 0) 1 else v;
    }

    pub fn init(gpa: std.mem.Allocator, idh: u64, context: u32, ck: proto.SyncCookie) ?CookieShadow {
        const d = gpa.dupe(u8, ck.domain) catch return null;
        const p = gpa.dupe(u8, ck.path) catch {
            gpa.free(d);
            return null;
        };
        const n = gpa.dupe(u8, ck.name) catch {
            gpa.free(d);
            gpa.free(p);
            return null;
        };
        return .{ .context = context, .id_hash = idh, .domain = d, .path = p, .name = n };
    }

    pub fn free(self: *CookieShadow, gpa: std.mem.Allocator) void {
        gpa.free(self.domain);
        gpa.free(self.path);
        gpa.free(self.name);
    }
};

/// Bytes a recorded cookie value may carry across the IO-thread
/// mailbox. RFC 6265 recommends 4096 per cookie including the name and
/// attributes, and Chromium enforces that; a longer one is DROPPED
/// from the mailbox rather than truncated, because half a session
/// token is a login that silently does not work. The reconcile — which
/// allocates and has no such cap — carries it instead.
pub const CK_VALUE_MAX = 4096;
pub const CK_NAME_MAX = 512;
pub const CK_URL_MAX = 1024;

/// One cookie the IO thread saw being saved. FIXED SIZE by design:
/// nothing allocates on CEF's IO thread here, exactly as the intercept
/// log and the webRequest hold table do not.
pub const CkRec = struct {
    used: bool = false,
    view_id: u32 = 0,
    name: [CK_NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    value: [CK_VALUE_MAX]u8 = undefined,
    value_len: usize = 0,
    domain: [CK_NAME_MAX]u8 = undefined,
    domain_len: usize = 0,
    path: [CK_NAME_MAX]u8 = undefined,
    path_len: usize = 0,
    url: [CK_URL_MAX]u8 = undefined,
    url_len: usize = 0,
    flags: u8 = 0,
    same_site: u8 = 0,
    priority: u8 = 0,
    creation_ms: u64 = 0,
    last_access_ms: u64 = 0,
    expires_ms: u64 = 0,

    pub fn slice(_: *const CkRec, buf: []const u8, len: usize) []const u8 {
        return buf[0..len];
    }
};

/// The IO thread -> main thread mailbox for saved cookies.
///
/// No wake pipe: unlike a HELD webRequest (a page that has stopped
/// loading until we answer), an observed cookie is not blocking
/// anything. The server pumps every 5ms with a view open, and paying
/// for a descriptor plus a write per Set-Cookie to shave that would be
/// spending real cost on a path that has no deadline.
pub const CookieObs = struct {
    lock: SpinLock = .{},
    /// Read WITHOUT the lock on the IO thread's fast path: with nobody
    /// subscribed, `can_save_cookie` is one relaxed load and a return.
    on: std.atomic.Value(bool) = .init(false),
    recs: [64]CkRec = @splat(.{}),
    /// Cookies the mailbox had no room for. They are not lost to the
    /// SYNC — the reconcile finds them — only to the fast path.
    dropped: u32 = 0,

    /// IO THREAD.
    pub fn put(self: *CookieObs, rec: *const CkRec) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.recs) |*r| {
            if (r.used) continue;
            r.* = rec.*;
            r.used = true;
            return;
        }
        self.dropped +%= 1;
    }

    /// MAIN THREAD. False when the mailbox is empty.
    fn take(self: *CookieObs, out: *CkRec) bool {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.recs) |*r| {
            if (!r.used) continue;
            out.* = r.*;
            r.used = false;
            return true;
        }
        return false;
    }

    fn drain(self: *CookieObs) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.recs) |*r| r.used = false;
        self.dropped = 0;
    }
};

pub var g_cksync: CookieObs = .{};

/// The one cookie access filter, handed out per resource request while
/// somebody is synchronising. A process-lifetime static like every
/// other handler here: it carries no per-request state.
pub var cookie_access_filter: cef.cef_cookie_access_filter_t = undefined;

/// IO THREAD. Never blocks a cookie and never alters one — this is an
/// OBSERVER. `can_send_cookie` is implemented purely so the interface
/// is complete; a filter that answered only half of it would be one
/// CEF version away from a surprise.
pub fn onCanSendCookie(
    _: [*c]cef.cef_cookie_access_filter_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    _: [*c]const cef.cef_cookie_t,
) callconv(.c) c_int {
    releaseArg(browser);
    releaseArg(frame);
    releaseArg(request);
    return 1;
}

/// IO THREAD. Record one `Set-Cookie` and ALWAYS allow the save.
pub fn onCanSaveCookie(
    _: [*c]cef.cef_cookie_access_filter_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    response: [*c]cef.cef_response_t,
    cookie: [*c]const cef.cef_cookie_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    defer releaseArg(response);
    if (!g_cksync.on.load(.acquire)) return 1;
    const ck: *const cef.cef_cookie_t = cookie orelse return 1;

    var rec: CkRec = .{};
    var name = Utf8.init(&ck.name);
    defer name.free();
    var value = Utf8.init(&ck.value);
    defer value.free();
    var domain = Utf8.init(&ck.domain);
    defer domain.free();
    var path = Utf8.init(&ck.path);
    defer path.free();
    // A value past the mailbox's cap is left to the reconcile rather
    // than truncated: half a session token is worse than a late one.
    if (value.slice().len > CK_VALUE_MAX) return 1;
    if (!copyInto(&rec.name, &rec.name_len, name.slice())) return 1;
    if (!copyInto(&rec.value, &rec.value_len, value.slice())) return 1;
    if (!copyInto(&rec.domain, &rec.domain_len, domain.slice())) return 1;
    if (!copyInto(&rec.path, &rec.path_len, path.slice())) return 1;

    if (request != null) {
        const req: *cef.cef_request_t = @ptrCast(request);
        if (req.get_url) |gu| {
            var url_raw: [CK_URL_MAX]u8 = undefined;
            const u = userfreeInto(gu(req), &url_raw);
            _ = copyInto(&rec.url, &rec.url_len, u);
        }
    }
    // Resolving a browser to its CONTEXT is main-thread state; the view
    // id is all the IO thread may learn, exactly as in the intercept
    // path, and `drainSavedCookies` finishes the join.
    if (browser != null) {
        const b: *cef.cef_browser_t = @ptrCast(browser);
        if (b.get_identifier) |gi| {
            const cef_id = gi(b);
            host_icpt.g_int.acquire();
            defer host_icpt.g_int.release();
            if (host_icpt.g_int.slotByCef(cef_id)) |slot| rec.view_id = slot.view_id;
        }
    }

    rec.flags = 0;
    if (ck.secure != 0) rec.flags |= proto.cookie_secure;
    if (ck.httponly != 0) rec.flags |= proto.cookie_httponly;
    if (ck.has_expires == 0) rec.flags |= proto.cookie_session;
    if (rec.domain_len != 0 and rec.domain[0] == '.') rec.flags |= proto.cookie_domain_scoped;
    rec.same_site = sameSiteOf(ck.same_site);
    rec.priority = priorityOf(ck.priority);
    rec.creation_ms = baseTimeMs(ck.creation);
    rec.last_access_ms = baseTimeMs(ck.last_access);
    rec.expires_ms = if (ck.has_expires != 0) baseTimeMs(ck.expires) else 0;

    g_cksync.put(&rec);
    return 1;
}

pub fn copyInto(buf: []u8, len: *usize, src: []const u8) bool {
    if (src.len > buf.len) return false;
    @memcpy(buf[0..src.len], src);
    len.* = src.len;
    return true;
}

/// IO THREAD. Null while nobody synchronises, so an unsubscribed
/// helper never even constructs the filter path.
pub fn onGetCookieAccessFilter(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
) callconv(.c) [*c]cef.cef_cookie_access_filter_t {
    releaseArg(browser);
    releaseArg(frame);
    releaseArg(request);
    if (!g_cksync.on.load(.acquire)) return null;
    return &cookie_access_filter;
}

/// CEF's cookie priority (-1/0/1) -> the wire's (0/1/2). Comparisons
/// rather than a switch for `sameSiteOf`'s reason: translate-c gives
/// the enum type a different signedness from its constants.
pub fn priorityOf(v: cef.cef_cookie_priority_t) u8 {
    const T = cef.cef_cookie_priority_t;
    if (v == @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_LOW))) return @intFromEnum(proto.CookiePriority.low);
    if (v == @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_HIGH))) return @intFromEnum(proto.CookiePriority.high);
    return @intFromEnum(proto.CookiePriority.medium);
}

pub fn cefPriorityOf(v: u8) cef.cef_cookie_priority_t {
    const T = cef.cef_cookie_priority_t;
    return switch (@as(proto.CookiePriority, @enumFromInt(v))) {
        .low => @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_LOW)),
        .high => @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_HIGH)),
        else => @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_MEDIUM)),
    };
}

pub fn cefSameSiteOf(v: u8) cef.cef_cookie_same_site_t {
    const T = cef.cef_cookie_same_site_t;
    return switch (@as(proto.SameSite, @enumFromInt(v))) {
        .none => @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_NO_RESTRICTION)),
        .lax => @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_LAX_MODE)),
        .strict => @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_STRICT_MODE)),
        else => @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_UNSPECIFIED)),
    };
}

/// Unix epoch milliseconds -> a CEF base time (microseconds since the
/// Windows epoch). The exact inverse of `baseTimeMs`, so an expiry
/// survives a round trip through the wire and back into a jar.
pub fn msToBaseTime(ms: u64) cef.cef_basetime_t {
    const win_to_unix_us: i64 = 11_644_473_600 * std.time.us_per_s;
    var bt = std.mem.zeroes(cef.cef_basetime_t);
    bt.val = @as(i64, @intCast(ms)) * 1000 + win_to_unix_us;
    return bt;
}

/// Fill a `cef_cookie_t` from a wire record. The strings are OWNED by
/// the returned struct and must be cleared with `freeCefCookie`.
pub fn toCefCookie(ck: proto.SyncCookie) cef.cef_cookie_t {
    var out = std.mem.zeroes(cef.cef_cookie_t);
    out.size = @sizeOf(cef.cef_cookie_t);
    setStr(ck.name, &out.name);
    setStr(ck.value, &out.value);
    setStr(ck.domain, &out.domain);
    setStr(ck.path, &out.path);
    out.secure = if (ck.flags & proto.cookie_secure != 0) 1 else 0;
    out.httponly = if (ck.flags & proto.cookie_httponly != 0) 1 else 0;
    out.same_site = cefSameSiteOf(ck.same_site);
    out.priority = cefPriorityOf(ck.priority);
    if (ck.creation_ms != 0) out.creation = msToBaseTime(ck.creation_ms);
    if (ck.last_access_ms != 0) out.last_access = msToBaseTime(ck.last_access_ms);
    // A dropped expiry silently turns a persistent cookie into a
    // session cookie, which is the whole login gone at the next
    // restart; `has_expires` and `expires` travel together or not at
    // all.
    if (ck.expires_ms != 0 and ck.flags & proto.cookie_session == 0) {
        out.has_expires = 1;
        out.expires = msToBaseTime(ck.expires_ms);
    }
    return out;
}

pub fn freeCefCookie(ck: *cef.cef_cookie_t) void {
    cef.cef_string_utf16_clear(&ck.name);
    cef.cef_string_utf16_clear(&ck.value);
    cef.cef_string_utf16_clear(&ck.domain);
    cef.cef_string_utf16_clear(&ck.path);
}

/// One `visit_all_cookies` walk: the periodic reconcile, or one page
/// of a client's jar dump. Same refcount rule as `CookieJob` and for
/// the same reason — the visit takes ownership of the reference, and
/// the LAST release is both "the walk is over" and the free, so the
/// answer is composed there and nowhere else.
pub const SyncVisitJob = struct {
    /// FIRST FIELD: CEF is handed `&job.visitor`.
    visitor: cef.cef_cookie_visitor_t,
    refs: std.atomic.Value(u32),
    gpa: std.mem.Allocator,
    mode: Mode,
    context: u32,
    /// Dump only: the connection to answer and its request id.
    conn: u32,
    req: u32,
    /// Dump only: the index this page starts at, and where it ended.
    cursor: u32,
    next_cursor: u32 = 0,
    /// Cookies the walk saw, whether or not this page carried them.
    total: u32 = 0,
    more: bool = false,
    accessible: bool = true,
    /// Owned copies of everything the answer needs; the visitor's
    /// `cef_cookie_t` is only valid for the duration of one call.
    strings: std.ArrayList(u8) = .empty,
    recs: std.ArrayList(Rec) = .empty,
    bytes: usize = 0,

    pub const Mode = enum { reconcile, dump };
    const Span = struct { off: u32, len: u32 };

    const Rec = struct {
        name: Span,
        value: Span,
        domain: Span,
        path: Span,
        flags: u8,
        same_site: u8,
        priority: u8,
        creation_ms: u64,
        last_access_ms: u64,
        expires_ms: u64,
    };

    const Opts = struct {
        mode: Mode,
        context: u32,
        conn: u32,
        req: u32,
        cursor: u32,
    };

    pub fn start(gpa: std.mem.Allocator, mgr: *cef.cef_cookie_manager_t, opts: Opts) ?void {
        const visit = mgr.visit_all_cookies orelse return null;
        const job = gpa.create(SyncVisitJob) catch return null;
        job.* = .{
            .visitor = .{ .base = SyncJobRef.base(), .visit = syncJobVisit },
            .refs = .init(2),
            .gpa = gpa,
            .mode = opts.mode,
            .context = opts.context,
            .conn = opts.conn,
            .req = opts.req,
            .cursor = opts.cursor,
            .next_cursor = opts.cursor,
        };
        // Two references for `CookieJob.start`'s reason: the call
        // CONSUMES one and may drop it before returning.
        if (visit(mgr, &job.visitor) == 0) job.accessible = false;
        _ = SyncJobRef.release(&job.visitor.base);
        return {};
    }

    pub fn record(self: *SyncVisitJob, cookie: *const cef.cef_cookie_t) void {
        var name = Utf8.init(&cookie.name);
        defer name.free();
        var value = Utf8.init(&cookie.value);
        defer value.free();
        var domain = Utf8.init(&cookie.domain);
        defer domain.free();
        var path = Utf8.init(&cookie.path);
        defer path.free();

        const n = self.intern(name.slice()) orelse return;
        const v = self.intern(value.slice()) orelse return;
        const d = self.intern(domain.slice()) orelse return;
        const p = self.intern(path.slice()) orelse return;

        var flags: u8 = 0;
        if (cookie.secure != 0) flags |= proto.cookie_secure;
        if (cookie.httponly != 0) flags |= proto.cookie_httponly;
        if (cookie.has_expires == 0) flags |= proto.cookie_session;
        if (domain.slice().len != 0 and domain.slice()[0] == '.') flags |= proto.cookie_domain_scoped;

        self.recs.append(self.gpa, .{
            .name = n,
            .value = v,
            .domain = d,
            .path = p,
            .flags = flags,
            .same_site = sameSiteOf(cookie.same_site),
            .priority = priorityOf(cookie.priority),
            .creation_ms = baseTimeMs(cookie.creation),
            .last_access_ms = baseTimeMs(cookie.last_access),
            .expires_ms = if (cookie.has_expires != 0) baseTimeMs(cookie.expires) else 0,
        }) catch {};
        self.bytes += name.slice().len + value.slice().len + domain.slice().len + path.slice().len + 40;
    }

    fn intern(self: *SyncVisitJob, s: []const u8) ?Span {
        const off: u32 = @intCast(self.strings.items.len);
        self.strings.appendSlice(self.gpa, s) catch return null;
        return .{ .off = off, .len = @intCast(s.len) };
    }

    pub fn str(self: *const SyncVisitJob, sp: Span) []const u8 {
        return self.strings.items[sp.off..][0..sp.len];
    }

    fn cookieAt(self: *const SyncVisitJob, r: Rec) proto.SyncCookie {
        return .{
            .name = self.str(r.name),
            .value = self.str(r.value),
            .domain = self.str(r.domain),
            .path = self.str(r.path),
            .flags = r.flags,
            .same_site = r.same_site,
            .priority = r.priority,
            .creation_ms = r.creation_ms,
            .last_access_ms = r.last_access_ms,
            .expires_ms = r.expires_ms,
        };
    }

    /// A synthetic url for a reconciled cookie: the scheme its `secure`
    /// flag implies, the domain without its leading dot, and its path.
    /// It is what a client hands back as `cookie_apply.url`, so it has
    /// to be a url the ENGINE will accept for that (domain, path).
    fn urlFor(r: Rec, self: *const SyncVisitJob, buf: []u8) []const u8 {
        const dom_raw = self.str(r.domain);
        const dom = if (dom_raw.len != 0 and dom_raw[0] == '.') dom_raw[1..] else dom_raw;
        const scheme = if (r.flags & proto.cookie_secure != 0) "https://" else "http://";
        const path = self.str(r.path);
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ scheme, dom, path }) catch "";
    }

    fn finish(self: *SyncVisitJob) void {
        const host = host_mod.g_host orelse return;
        switch (self.mode) {
            .reconcile => self.finishReconcile(host),
            .dump => self.finishDump(host),
        }
    }

    /// Diff the walk against the shadow: emit what is new or changed,
    /// then emit a removal for every shadow entry the walk did not see.
    ///
    /// THE FIRST WALK OF A CONTEXT IS SILENT. A helper that just
    /// subscribed would otherwise replay its entire existing jar as
    /// "changes", which is noise at best and, with two instances
    /// subscribing at once, a burst of mutual applies at worst. The
    /// seed path for a new instance is `cookie_dump_req`, which is
    /// explicit, paged and asked for.
    fn finishReconcile(self: *SyncVisitJob, host: *Host) void {
        if (host.cookie_reconcile_busy > 0) host.cookie_reconcile_busy -= 1;
        if (!self.accessible) return;
        if (!host.cookieSyncOn()) return;
        const seeding = !host.shadowSeeded(self.context);

        for (host.cookie_shadow.items) |*sh| {
            if (sh.context == self.context) sh.seen = false;
        }
        var url_buf: [1024]u8 = undefined;
        for (self.recs.items) |r| {
            const ck = self.cookieAt(r);
            const idh = CookieShadow.identity(self.context, ck.domain, ck.path, ck.name);
            if (host.shadowFind(idh, self.context, ck.domain, ck.path, ck.name)) |sh| {
                sh.seen = true;
                if (sh.pending) continue;
                const vh = CookieShadow.valueHash(ck);
                if (sh.hash == vh) {
                    sh.adopt = false;
                    continue;
                }
                sh.hash = vh;
                if (sh.adopt) {
                    // The engine's own normalisation of what we just
                    // applied, not news. Adopt it once and go quiet.
                    sh.adopt = false;
                    continue;
                }
                if (seeding) continue;
                host.postSyncAll(proto.EvCookieChange{
                    .context = self.context,
                    .cause = @intFromEnum(proto.CookieCause.reconcile),
                    .removed = 0,
                    .url = urlFor(r, self, &url_buf),
                    .cookie = ck,
                });
                continue;
            }
            const sh = host.shadowInsert(idh, self.context, ck) orelse continue;
            sh.hash = CookieShadow.valueHash(ck);
            sh.seen = true;
            if (seeding) continue;
            host.postSyncAll(proto.EvCookieChange{
                .context = self.context,
                .cause = @intFromEnum(proto.CookieCause.reconcile),
                .removed = 0,
                .url = urlFor(r, self, &url_buf),
                .cookie = ck,
            });
        }

        // Everything the walk did not see is gone from the jar. This is
        // the ONLY observer that can see a deletion at all: no response
        // header carries `document.cookie = "...; max-age=0"`.
        var i: usize = 0;
        while (i < host.cookie_shadow.items.len) {
            const sh = &host.cookie_shadow.items[i];
            if (sh.context != self.context or sh.seen or sh.pending) {
                i += 1;
                continue;
            }
            if (!seeding) {
                const scheme = "https://";
                const dom = if (sh.domain.len != 0 and sh.domain[0] == '.') sh.domain[1..] else sh.domain;
                const url = std.fmt.bufPrint(&url_buf, "{s}{s}{s}", .{ scheme, dom, sh.path }) catch "";
                host.postSyncAll(proto.EvCookieChange{
                    .context = self.context,
                    .cause = @intFromEnum(proto.CookieCause.reconcile),
                    .removed = 1,
                    .url = url,
                    .cookie = .{
                        .name = sh.name,
                        .value = "",
                        .domain = sh.domain,
                        .path = sh.path,
                        .flags = 0,
                        .same_site = 0,
                        .priority = @intFromEnum(proto.CookiePriority.medium),
                        .creation_ms = 0,
                        .last_access_ms = 0,
                        .expires_ms = 0,
                    },
                });
            }
            sh.free(host.gpa);
            _ = host.cookie_shadow.orderedRemove(i);
        }
        host.markShadowSeeded(self.context);
    }

    fn finishDump(self: *SyncVisitJob, host: *Host) void {
        const start_at: usize = self.cursor;
        var page: std.ArrayList(proto.SyncCookie) = .empty;
        defer page.deinit(self.gpa);
        var bytes: usize = 0;
        var idx: usize = start_at;
        var more = false;
        while (idx < self.recs.items.len) : (idx += 1) {
            if (page.items.len >= proto.SYNC_DUMP_PAGE or bytes >= proto.SYNC_DUMP_PAGE_BYTES) {
                more = true;
                break;
            }
            const r = self.recs.items[idx];
            const ck = self.cookieAt(r);
            page.append(self.gpa, ck) catch {
                more = true;
                break;
            };
            bytes += ck.name.len + ck.value.len + ck.domain.len + ck.path.len + 40;
        }
        host.postSyncTo(self.conn, proto.EvCookieDump{
            .req = self.req,
            .context = self.context,
            .ok = if (self.accessible) 1 else 0,
            .cursor = self.cursor,
            .next_cursor = @intCast(idx),
            .more = if (more) 1 else 0,
            .total = @intCast(self.recs.items.len),
            .cookies = page.items,
        });
    }

    pub fn destroyOwned(self: *SyncVisitJob) void {
        self.finish();
        const gpa = self.gpa;
        self.strings.deinit(gpa);
        self.recs.deinit(gpa);
        gpa.destroy(self);
    }
};

pub const SyncJobRef = HeapRef(SyncVisitJob, "visitor");

pub fn syncJobVisit(
    self_: [*c]cef.cef_cookie_visitor_t,
    cookie: [*c]const cef.cef_cookie_t,
    _: c_int,
    _: c_int,
    delete_cookie: [*c]c_int,
) callconv(.c) c_int {
    if (self_ == null or cookie == null) return 0;
    const vis: *cef.cef_cookie_visitor_t = @ptrCast(self_);
    const job: *SyncVisitJob = @fieldParentPtr("visitor", vis);
    if (delete_cookie != null) delete_cookie.* = 0;
    job.total += 1;
    job.record(@ptrCast(cookie));
    return 1;
}

/// One `cookie_apply` in flight. Refcounted for `CookieJob`'s reason:
/// `set_cookie` / `delete_cookies` take ownership of the callback
/// reference and may drop it before returning.
///
/// The completion is what SETTLES the shadow, which is why the apply
/// carries the identity hash and a copy of the cookie's identity
/// strings rather than a pointer into the frame it came from.
pub const CookieApplyJob = struct {
    cb: Cb,
    refs: std.atomic.Value(u32),
    gpa: std.mem.Allocator,
    conn: u32,
    req: u32,
    context: u32,
    remove: bool,
    id_hash: u64,
    /// name / domain / path, concatenated; the spans below index it.
    ident: []u8,
    name_len: usize,
    domain_len: usize,
    path_len: usize,
    ok: bool = false,
    answered: bool = false,

    /// `set_cookie` and `delete_cookies` take DIFFERENT callback
    /// interfaces. They are laid out as a union of the two first
    /// fields so one job type serves both without a second struct;
    /// only the arm named by `remove` is ever handed to CEF.
    const Cb = extern union {
        set: cef.cef_set_cookie_callback_t,
        del: cef.cef_delete_cookies_callback_t,

        comptime {
            // `HeapRef.base` stamps `base.size = @sizeOf(Cb)` and the
            // ENGINE validates the size of the interface it was given.
            // The two callbacks are the same shape today (a base plus
            // one function pointer); if a CEF version ever changes one,
            // this fails to compile instead of handing the engine a
            // struct whose size is a lie.
            std.debug.assert(@sizeOf(cef.cef_set_cookie_callback_t) == @sizeOf(cef.cef_delete_cookies_callback_t));
        }
    };

    fn nameOf(self: *const CookieApplyJob) []const u8 {
        return self.ident[0..self.name_len];
    }
    fn domainOf(self: *const CookieApplyJob) []const u8 {
        return self.ident[self.name_len..][0..self.domain_len];
    }
    fn pathOf(self: *const CookieApplyJob) []const u8 {
        return self.ident[self.name_len + self.domain_len ..][0..self.path_len];
    }

    pub fn create(gpa: std.mem.Allocator, req: proto.CookieApply, conn: u32, idh: u64) ?*CookieApplyJob {
        const job = gpa.create(CookieApplyJob) catch return null;
        const total = req.cookie.name.len + req.cookie.domain.len + req.cookie.path.len;
        const ident = gpa.alloc(u8, total) catch {
            gpa.destroy(job);
            return null;
        };
        @memcpy(ident[0..req.cookie.name.len], req.cookie.name);
        @memcpy(ident[req.cookie.name.len..][0..req.cookie.domain.len], req.cookie.domain);
        @memcpy(ident[req.cookie.name.len + req.cookie.domain.len ..][0..req.cookie.path.len], req.cookie.path);
        job.* = .{
            .cb = undefined,
            .refs = .init(2),
            .gpa = gpa,
            .conn = conn,
            .req = req.req,
            .context = req.context,
            .remove = req.remove != 0,
            .id_hash = idh,
            .ident = ident,
            .name_len = req.cookie.name.len,
            .domain_len = req.cookie.domain.len,
            .path_len = req.cookie.path.len,
        };
        return job;
    }

    fn startSet(
        gpa: std.mem.Allocator,
        mgr: *cef.cef_cookie_manager_t,
        req: proto.CookieApply,
        conn: u32,
        idh: u64,
    ) ?void {
        const set = mgr.set_cookie orelse return null;
        const job = create(gpa, req, conn, idh) orelse return null;
        job.cb.set = .{ .base = ApplyRef.base(), .on_complete = onSetCookieComplete };

        var ck = toCefCookie(req.cookie);
        defer freeCefCookie(&ck);
        var u = std.mem.zeroes(cef.cef_string_t);
        setStr(req.url, &u);
        defer cef.cef_string_utf16_clear(&u);
        if (set(mgr, &u, &ck, @ptrCast(&job.cb.set)) == 0) {
            // The engine refused OUTRIGHT (a malformed url or a value
            // carrying a disallowed character). Its callback may never
            // run, so the second reference is what answers.
            job.ok = false;
        }
        _ = ApplyRef.release(@ptrCast(&job.cb.set.base));
        return {};
    }

    fn startDelete(
        gpa: std.mem.Allocator,
        mgr: *cef.cef_cookie_manager_t,
        req: proto.CookieApply,
        conn: u32,
        idh: u64,
    ) ?void {
        // NAMED deletion, not the url-only form: with both a url and a
        // name, CEF deletes host AND domain cookies matching both.
        // The url-only form deliberately spares domain cookies, which
        // is exactly how a logout fails to propagate.
        const del = mgr.delete_cookies orelse return null;
        const job = create(gpa, req, conn, idh) orelse return null;
        job.cb.del = .{ .base = ApplyRef.base(), .on_complete = onDeleteCookiesComplete };

        var u = std.mem.zeroes(cef.cef_string_t);
        setStr(req.url, &u);
        defer cef.cef_string_utf16_clear(&u);
        var n = std.mem.zeroes(cef.cef_string_t);
        setStr(req.cookie.name, &n);
        defer cef.cef_string_utf16_clear(&n);
        if (del(mgr, &u, &n, @ptrCast(&job.cb.del)) == 0) job.ok = false;
        _ = ApplyRef.release(@ptrCast(&job.cb.del.base));
        return {};
    }

    /// The LAST release: settle the shadow and answer. Both happen
    /// here and nowhere else, so every apply is answered exactly once
    /// on every path — the engine's callback, or its refusal.
    pub fn destroyOwned(self: *CookieApplyJob) void {
        if (host_mod.g_host) |host| {
            host.settleApply(self.id_hash, self.context, .{
                .name = self.nameOf(),
                .value = "",
                .domain = self.domainOf(),
                .path = self.pathOf(),
                .flags = 0,
                .same_site = 0,
                .priority = 0,
                .creation_ms = 0,
                .last_access_ms = 0,
                .expires_ms = 0,
            }, self.ok);
            host.postApplyDone(
                self.conn,
                self.req,
                self.context,
                self.ok,
                if (self.ok) "" else "set-failed",
            );
        }
        const gpa = self.gpa;
        gpa.free(self.ident);
        gpa.destroy(self);
    }
};

pub const ApplyRef = HeapRef(CookieApplyJob, "cb");

pub fn onSetCookieComplete(self_: [*c]cef.cef_set_cookie_callback_t, success: c_int) callconv(.c) void {
    if (self_ == null) return;
    const job: *CookieApplyJob = @fieldParentPtr("cb", @as(*CookieApplyJob.Cb, @ptrCast(@alignCast(self_))));
    job.ok = success != 0;
}

pub fn onDeleteCookiesComplete(self_: [*c]cef.cef_delete_cookies_callback_t, num_deleted: c_int) callconv(.c) void {
    if (self_ == null) return;
    const job: *CookieApplyJob = @fieldParentPtr("cb", @as(*CookieApplyJob.Cb, @ptrCast(@alignCast(self_))));
    // A logout that deleted nothing because the cookie was already
    // gone is a SUCCESS: the instances agree, which is the whole point.
    job.ok = num_deleted >= 0;
}

/// CEF's SameSite enum -> the wire's engine-agnostic one. Written as
/// comparisons rather than a switch because translate-c gives the enum
/// TYPE a different signedness from its CONSTANTS.
pub fn sameSiteOf(v: cef.cef_cookie_same_site_t) u8 {
    const T = cef.cef_cookie_same_site_t;
    if (v == @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_NO_RESTRICTION))) return @intFromEnum(proto.SameSite.none);
    if (v == @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_LAX_MODE))) return @intFromEnum(proto.SameSite.lax);
    if (v == @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_STRICT_MODE))) return @intFromEnum(proto.SameSite.strict);
    return @intFromEnum(proto.SameSite.unspecified);
}
