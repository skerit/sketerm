//! Downloads (0x78 block, capabilities "downloads" + "download-start"),
//! split out of `cefhost.zig`: the held target decision, cancel, the
//! client-started download join, coalesced progress, and the engine's
//! download-handler callbacks. The `Host` methods are free functions
//! taking `*Host`, re-exported from `Host` under their old names.

const std = @import("std");
const c = @import("cbindings");
const cef = @import("cef");
const nowMs = @import("../../util/clock.zig").nowMs;
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const Dl = Host.Dl;
const Host = host_mod.Host;
const Utf8 = host_mod.Utf8;
const dl_start_wait_ms = host_mod.dl_start_wait_ms;
const release = host_mod.release;
const releaseArg = host_mod.releaseArg;
const setStr = host_mod.setStr;
const stagingFile = host_mod.stagingFile;
const userfreeInto = host_mod.userfreeInto;
const viewOf = host_mod.viewOf;

// -- downloads -----------------------------------------------------

pub fn findDl(self: *Host, view: u32, id: u32) ?*Dl {
    for (self.downloads.items) |*d| {
        if (d.id == id and d.view == view) return d;
    }
    return null;
}

/// The client answered an `ev_download_offer`. An id the helper no
/// longer holds is ignored (the download may already have failed or
/// its view may be gone).
pub fn downloadDecide(self: *Host, req: proto.DownloadDecide) void {
    const d = self.findDl(req.view, req.id) orelse return;
    if (req.path.len == 0) {
        self.cancelDl(d);
        return;
    }
    if (d.decided) return;
    var target = req.path;
    if (req.stage != 0) {
        const staged = stagingFile(&d.staging, "webdl") orelse {
            d.interrupt_reason = 1;
            self.cancelDl(d);
            return;
        };
        d.staging_len = staged.len;
        target = staged;
    }
    d.decided = true;
    d.dirty = true;
    if (d.before_cb) |cb| {
        d.before_cb = null;
        var path = std.mem.zeroes(cef.cef_string_t);
        setStr(target, &path);
        defer cef.cef_string_utf16_clear(&path);
        if (cb.cont) |f| f(cb, &path, 0);
        release(&cb.base);
    }
}

/// `download_cancel`, and the decide-with-empty-path shape of the
/// same intent. Idempotent; a download with no cancel handle yet is
/// aborted by the next `on_download_updated`.
pub fn cancelDl(self: *Host, d: *Dl) void {
    _ = self;
    if (d.terminal()) return;
    d.cancel_requested = true;
    // A held target decision must ALWAYS be run — dropping the
    // callback unanswered leaves Chromium's target determiner
    // waiting forever and the whole helper then hangs at shutdown
    // on its download manager (measured; stage 23 caught it). So a
    // cancel CONTINUES into a throwaway path first and cancels
    // right after; if the engine wins the race and completes
    // anyway, the throwaway is unlinked when the entry drops.
    if (d.before_cb) |cb| {
        d.before_cb = null;
        const p = std.fmt.bufPrint(
            d.trash[0 .. d.trash.len - 1],
            "/tmp/sketerm-webdl-cancel-{d}-{d}.part",
            .{ c.getpid(), d.id },
        ) catch "";
        d.trash_len = p.len;
        var path = std.mem.zeroes(cef.cef_string_t);
        setStr(p, &path);
        defer cef.cef_string_utf16_clear(&path);
        if (cb.cont) |f| f(cb, &path, 0);
        release(&cb.base);
    }
    if (d.item_cb) |cb| {
        d.item_cb = null;
        if (cb.cancel) |f| f(cb);
        release(&cb.base);
    }
}

pub fn downloadCancel(self: *Host, req: proto.DownloadCancel) void {
    const d = self.findDl(req.view, req.id) orelse return;
    self.cancelDl(d);
}

/// `download_start`: the client wants `url` fetched THROUGH this
/// view's browser, so the request carries that browser's cookies,
/// session and route. The engine mints an ordinary download, whose
/// offer is then tagged with the client's `req` (`dlPendingReq`) —
/// the target path stays the client's decision, exactly as for a
/// download a page started.
///
/// A start that cannot happen is ANSWERED (`id = 0`, `failed`),
/// never left to the caller's deadline.
pub fn downloadStart(self: *Host, req: proto.DownloadStart) void {
    const fail = proto.EvDownloadProgress{
        .view = req.view,
        .id = 0,
        .received = 0,
        .total = 0,
        .done = 0,
        .failed = 1,
        .req = req.req,
    };
    const v = self.find(req.view) orelse {
        self.post(fail);
        return;
    };
    const b = v.browser orelse {
        // A discarded view has no browser to download through, and
        // reviving one here would load a page nobody asked for.
        self.post(fail);
        return;
    };
    const gh = b.get_host orelse {
        self.post(fail);
        return;
    };
    const host: *cef.cef_browser_host_t = gh(b) orelse {
        self.post(fail);
        return;
    };
    defer release(&host.base);
    const start = host.start_download orelse {
        self.post(fail);
        return;
    };
    self.dl_pending.append(self.gpa, .{ .view = v.id, .req = req.req, .at_ms = nowMs() }) catch {
        self.post(fail);
        return;
    };
    var url = std.mem.zeroes(cef.cef_string_t);
    setStr(req.url, &url);
    defer cef.cef_string_utf16_clear(&url);
    start(host, &url);
}

/// The `download_start` request an offer on `view` answers, taken
/// FIFO. CEF gives no way to correlate `start_download` with the
/// `DownloadItem` it produces — not even by url, which redirects
/// rewrite — so the order the engine offers them in is the only
/// join there is, and it is exact for the one case that matters
/// (a client asks, the very next offer on that view is the answer).
/// A page-initiated download racing an asked-for one can take the
/// tag; the cost is a mislabelled row, never a lost file.
pub fn dlPendingReq(self: *Host, view: u32) u32 {
    var i: usize = 0;
    while (i < self.dl_pending.items.len) {
        const p = self.dl_pending.items[i];
        if (p.view != view) {
            i += 1;
            continue;
        }
        _ = self.dl_pending.orderedRemove(i);
        return p.req;
    }
    return 0;
}

/// Answer every `download_start` whose offer never arrived (a url
/// the engine refused outright, a navigation instead of a
/// download): the caller asked a question and must get an answer.
pub fn expireDlPending(self: *Host, now: i64) void {
    var i: usize = 0;
    while (i < self.dl_pending.items.len) {
        const p = self.dl_pending.items[i];
        if (now - p.at_ms < dl_start_wait_ms) {
            i += 1;
            continue;
        }
        _ = self.dl_pending.orderedRemove(i);
        self.post(proto.EvDownloadProgress{
            .view = p.view,
            .id = 0,
            .received = 0,
            .total = 0,
            .done = 0,
            .failed = 1,
            .req = p.req,
        });
    }
}

/// Push a coalesced `ev_download_progress` for every download whose
/// counters moved, and retire terminal entries. Called once per
/// poll iteration, like `flushInterceptStatus`.
pub fn flushDownloadProgress(self: *Host) void {
    const now = nowMs();
    self.expireDlPending(now);
    var i: usize = 0;
    while (i < self.downloads.items.len) {
        const d = &self.downloads.items[i];
        // An offer nobody answered: cancel it ourselves rather than
        // hold the engine's target determiner for the life of the
        // helper (`download_hold_ms`). Exactly `download_cancel`'s
        // path: the entry stays until the ENGINE reports terminal,
        // because `cancelDl` continued the held callback into a
        // throwaway file the engine has yet to create, and retiring
        // the entry here would unlink that path before it exists
        // and drop the cancel request with it — the download then
        // ran to completion into /tmp under a fresh entry.
        if (d.offered and !d.decided and !d.cancel_requested and !d.terminal() and
            d.offered_ms != 0 and now - d.offered_ms > host_mod.download_hold_ms)
        {
            self.cancelDl(d);
        }
        if (d.dirty) {
            d.dirty = false;
            // Progress is only worth a frame once the client has a
            // row for it — but a TERMINAL state must reach an
            // offered download either way, or a client whose decide
            // raced the failure waits forever.
            if (d.offered and (d.decided or d.terminal())) self.post(proto.EvDownloadProgress{
                .view = d.view,
                .id = d.id,
                .received = d.received,
                .total = d.total,
                .done = if (d.done) 1 else 0,
                .failed = if (d.failed) 1 else 0,
                .req = d.req,
                .path = d.staging[0..d.staging_len],
                .interrupt_reason = d.interrupt_reason,
            });
        }
        if (d.terminal()) {
            var gone = self.downloads.swapRemove(i);
            gone.releaseCbs();
            gone.dropTrash();
            continue;
        }
        i += 1;
    }
}

/// Cancel and drop every download of `view`, posting the terminal
/// frame ourselves — the flush would otherwise never see entries
/// removed here. Called from `dropBrowser`.
pub fn dropDownloadsOf(self: *Host, view: u32) void {
    // Asked-for downloads whose offer will now never arrive: the
    // caller is waiting on an answer, so give it one.
    var pi: usize = 0;
    while (pi < self.dl_pending.items.len) {
        const p = self.dl_pending.items[pi];
        if (p.view != view) {
            pi += 1;
            continue;
        }
        _ = self.dl_pending.orderedRemove(pi);
        self.post(proto.EvDownloadProgress{
            .view = view,
            .id = 0,
            .received = 0,
            .total = 0,
            .done = 0,
            .failed = 1,
            .req = p.req,
        });
    }
    var i: usize = 0;
    while (i < self.downloads.items.len) {
        const d = &self.downloads.items[i];
        if (d.view != view) {
            i += 1;
            continue;
        }
        const was_terminal = d.terminal();
        const was_offered = d.offered;
        const was_decided = d.decided;
        self.cancelDl(d);
        var gone = self.downloads.swapRemove(i);
        gone.releaseCbs();
        gone.dropTrash();
        if (!was_terminal and was_offered and was_decided) self.post(proto.EvDownloadProgress{
            .view = view,
            .id = gone.id,
            .received = gone.received,
            .total = gone.total,
            .done = 0,
            .failed = 1,
            .req = gone.req,
        });
    }
}

// ---------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------

/// Every download may proceed as far as the TARGET decision — which is
/// then held for the client (`on_before_download`). Returning 0 here
/// would cancel silently, and the policy question belongs to the GUI.
pub fn onCanDownload(
    _: [*c]cef.cef_download_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_string_t,
) callconv(.c) c_int {
    releaseArg(browser);
    return 1;
}

/// The engine's download entry for `id`, minted on first sight — the
/// engine reports progress BEFORE `on_before_download`, so either
/// callback can be the first to see an id.
pub fn dlSlot(host: *Host, view: u32, id: u32) ?*Host.Dl {
    if (host.findDl(view, id)) |d| return d;
    host.downloads.append(host.gpa, .{ .id = id, .view = view }) catch return null;
    return &host.downloads.items[host.downloads.items.len - 1];
}

pub fn onBeforeDownload(
    _: [*c]cef.cef_download_handler_t,
    browser: [*c]cef.cef_browser_t,
    download_item: [*c]cef.cef_download_item_t,
    suggested_name: [*c]const cef.cef_string_t,
    callback: [*c]cef.cef_before_download_callback_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(download_item);
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = host_mod.g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const item: *cef.cef_download_item_t = download_item orelse return 0;
    const cb: *cef.cef_before_download_callback_t = callback orelse return 0;
    const id: u32 = if (item.get_id) |gid| gid(item) else return 0;
    const d = dlSlot(host, v.id, id) orelse return 0;
    if (d.cancel_requested or d.terminal()) return 0;

    if (item.get_total_bytes) |gt| {
        const t = gt(item);
        if (t > 0) d.total = @intCast(t);
    }
    d.before_cb = cb;
    kept = true;
    d.offered = true;
    d.offered_ms = nowMs();
    if (d.req == 0) d.req = host.dlPendingReq(v.id);

    var name = Utf8.init(suggested_name);
    defer name.free();
    var url_buf: [2048]u8 = undefined;
    const url = if (item.get_url) |gu| userfreeInto(gu(item), &url_buf) else "";
    var mime_buf: [256]u8 = undefined;
    const mime = if (item.get_mime_type) |gm| userfreeInto(gm(item), &mime_buf) else "";
    host.post(proto.EvDownloadOffer{
        .view = v.id,
        .id = id,
        .total = d.total,
        .url = url,
        .name = name.slice(),
        .mime = mime,
        .req = d.req,
    });
    return 1;
}

/// Progress, coalesced: the counters land in the entry and the flush in
/// the poll loop posts at most one frame per iteration. The latest
/// cancel handle is kept (releasing the previous one), which is what a
/// `download_cancel` or a dying view aborts through.
pub fn onDownloadUpdated(
    _: [*c]cef.cef_download_handler_t,
    browser: [*c]cef.cef_browser_t,
    download_item: [*c]cef.cef_download_item_t,
    callback: [*c]cef.cef_download_item_callback_t,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(download_item);
    // The entry keeps the callback's reference as its cancel handle;
    // every other exit returns it.
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = host_mod.g_host orelse return;
    const item: *cef.cef_download_item_t = download_item orelse return;
    const id: u32 = if (item.get_id) |gid| gid(item) else return;
    // By id first: the engine's id is process-unique, and a browser
    // mid-close can stop resolving to its view while its download's
    // entry (keyed under the real view) lives on.
    var found: ?*Host.Dl = null;
    for (host.downloads.items) |*e| {
        if (e.id == id) found = e;
    }
    const view_id: u32 = if (viewOf(browser)) |v| v.id else 0;
    const cb_arg: ?*cef.cef_download_item_callback_t = callback;
    const d = (found orelse dlSlot(host, view_id, id)) orelse return;

    if (item.get_received_bytes) |gr| {
        const r = gr(item);
        if (r >= 0) d.received = @intCast(r);
    }
    if (item.get_total_bytes) |gt| {
        const t = gt(item);
        if (t > 0) d.total = @intCast(t);
    }
    if (item.is_complete) |f| {
        if (f(item) != 0) d.done = true;
    }
    const canceled = if (item.is_canceled) |f| f(item) != 0 else false;
    const interrupted = if (item.is_interrupted) |f| f(item) != 0 else false;
    if ((canceled or interrupted) and !d.done) d.failed = true;
    if (interrupted) if (item.get_interrupt_reason) |f| {
        d.interrupt_reason = @intCast(f(item));
    };
    d.dirty = true;

    // One held cancel handle at a time; a terminal download needs none.
    if (d.item_cb) |old| {
        d.item_cb = null;
        release(&old.base);
    }
    if (cb_arg) |cb| {
        if (d.terminal()) {
            // Spent: the deferred release returns it.
        } else if (d.cancel_requested) {
            if (cb.cancel) |f| f(cb);
        } else {
            d.item_cb = cb;
            kept = true;
        }
    }
}
