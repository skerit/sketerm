//! User content (capability "userscripts"), split out of `cefhost.zig`:
//! the userscript and userstyle sets, their per-navigation injection, and
//! the GM_* call bridge. The `Host` methods are free functions taking
//! `*Host`, re-exported from `Host` under their old names.

const std = @import("std");
const c = @import("cbindings");
const cef = @import("cef");
const filter = @import("../filter.zig");
const gmvalues = @import("../gmvalues.zig");
const proto = @import("../protocol.zig");
const userscript = @import("../userscript.zig");
const host_mod = @import("../cefhost.zig");
const Host = host_mod.Host;
const ScriptRec = Host.ScriptRec;
const StyleRec = Host.StyleRec;
const View = host_mod.View;
const cosmeticCss = host_mod.cosmeticCss;
const cosmeticEnabledFor = host_mod.cosmeticEnabledFor;
const gmXhrStart = host_mod.gmXhrStart;
const jsonStr = host_mod.jsonStr;
const key = Host.key;
const release = host_mod.release;
const runJs = host_mod.runJs;
const userfreeInto = host_mod.userfreeInto;

// -- user content (userscripts / userstyles) -----------------------

/// Replace the enabled userscript set. Sources whose
/// `==UserScript==` block is missing or unterminated are refused
/// (not a userscript); the rest take effect at the NEXT navigation
/// of any matching page.
pub fn usScriptSet(self: *Host, req: proto.UsScriptSet) void {
    if (self.us_script_arena) |*a| a.deinit();
    self.us_script_arena = std.heap.ArenaAllocator.init(self.gpa);
    const arena = self.us_script_arena.?.allocator();
    self.us_scripts.clearRetainingCapacity();
    for (req.scripts) |s| {
        const src = arena.dupe(u8, s.source.s) catch continue;
        const meta = (userscript.parseMeta(arena, src) catch continue) orelse continue;
        var rec: ScriptRec = .{ .id = s.id, .meta = meta, .source = src };
        var raw: [16]u8 = undefined;
        if (c.getentropy(&raw, raw.len) != 0) continue;
        rec.cap = std.fmt.bytesToHex(raw, .lower);
        _ = gmvalues.keyFor(meta.namespace, meta.name, &rec.key);
        self.us_scripts.append(self.gpa, rec) catch {};
    }
}

/// Replace the enabled userstyle set and apply it INSTANTLY to
/// every live view (including removing styles that are no longer
/// in the set); navigations re-inject from the stored set.
pub fn usStyleSet(self: *Host, req: proto.UsStyleSet) void {
    if (self.us_style_arena) |*a| a.deinit();
    self.us_style_arena = std.heap.ArenaAllocator.init(self.gpa);
    const arena = self.us_style_arena.?.allocator();
    self.us_styles.clearRetainingCapacity();
    for (req.styles) |s| {
        const host = arena.alloc(u8, s.host.len) catch continue;
        for (s.host, host) |ch, *o| o.* = std.ascii.toLower(ch);
        const css = arena.dupe(u8, s.css.s) catch continue;
        self.us_styles.append(self.gpa, .{ .id = s.id, .host = host, .css = css }) catch {};
    }
    for (self.views.items) |v| self.applyStylesNow(v);
}

pub fn styleMatches(st: *const StyleRec, host: []const u8) bool {
    if (st.host.len == 0) return true;
    return filter.hostWithin(host, st.host);
}

/// Swap a live document's userstyle elements for the current set.
/// Runs even when NOTHING matches: that is how a deleted style
/// disappears from the page it is on.
pub fn applyStylesNow(self: *Host, v: *View) void {
    if (v.discarded) return;
    const b = v.browser orelse return;
    const gf = b.get_main_frame orelse return;
    const frame: *cef.cef_frame_t = gf(b) orelse return;
    defer release(&frame.base);
    var fold_buf: [2048]u8 = undefined;
    const folded = filter.foldUrl(&fold_buf, v.url);
    const host = filter.hostOf(folded);

    var code: std.Io.Writer.Allocating = .init(self.gpa);
    defer code.deinit();
    const w = &code.writer;
    w.writeAll("(function(){var d=document;var o=d.querySelectorAll('style[data-sketerm-us]');" ++
        "for(var i=0;i<o.length;i++)o[i].remove();" ++
        "function A(t){var s=d.createElement('style');s.setAttribute('data-sketerm-us','');" ++
        "s.textContent=t;(d.head||d.documentElement).appendChild(s);}") catch return;
    for (self.us_styles.items) |*st| {
        if (!styleMatches(st, host)) continue;
        w.writeAll("A(") catch return;
        jsonStr(w, st.css) catch return;
        w.writeAll(");") catch return;
    }
    w.writeAll("})();") catch return;
    runJs(frame, code.written());
}

/// Inject the user content applicable to a newly-committed
/// document: cosmetic hiding (shield-gated — a disabled shield
/// injects NO cosmetic CSS), userstyles, and userscripts by
/// `@run-at`. MAIN FRAME ONLY.
///
/// LIMITATIONS (deliberate, verified by smoke-web): injection is
/// browser-side `execute_java_script` at load START, which lands
/// after the parser has begun — cosmetic hiding can flash briefly,
/// and `document-start` here means "at commit", not "before every
/// page script" (only the embedded semantic bridge gets that,
/// renderer-side). Scripts run wrapped in a closure in the page's
/// MAIN world — the C API exposes no isolated world on this path —
/// with a no-op `GM_info` and NO other GM_* API (`@grant` values
/// beyond `none` are recorded by the parser and provided nothing).
pub fn injectUserContent(self: *Host, v: *View, frame: *cef.cef_frame_t) void {
    var url_raw: [2048]u8 = undefined;
    const gu = frame.get_url orelse return;
    const url = userfreeInto(gu(frame), &url_raw);
    var fold_buf: [2048]u8 = undefined;
    const folded = filter.foldUrl(&fold_buf, url);
    const host = filter.hostOf(folded);

    var code: std.Io.Writer.Allocating = .init(self.gpa);
    defer code.deinit();
    const w = &code.writer;
    var any = false;
    w.writeAll("(function(){var d=document;" ++
        "function A(t,m){var s=d.createElement('style');s.setAttribute(m,'');" ++
        "s.textContent=t;(d.head||d.documentElement).appendChild(s);}") catch return;

    if (cosmeticEnabledFor(v.id)) {
        if (cosmeticCss(self.gpa, host)) |css| {
            defer self.gpa.free(css);
            any = true;
            w.writeAll("A(") catch return;
            jsonStr(w, css) catch return;
            w.writeAll(",'data-sketerm-cos');") catch return;
        }
    }
    for (self.us_styles.items) |*st| {
        if (!styleMatches(st, host)) continue;
        any = true;
        w.writeAll("A(") catch return;
        jsonStr(w, st.css) catch return;
        w.writeAll(",'data-sketerm-us');") catch return;
    }

    if (any) {
        w.writeAll("})();") catch return;
        runJs(frame, code.written());
    }
    for (self.us_scripts.items) |*sc| {
        if (!userscript.applies(&sc.meta, url)) continue;
        self.injectUserscript(v, frame, sc, host);
    }
}

/// One userscript into one document, CSP-SAFE: its source is spliced
/// into the command as the body of a function literal and handed to
/// the semantic slot (`us-run`), so no `eval`/`new Function` ever
/// runs — a page whose CSP forbids eval still gets its scripts (the
/// old `new Function` path silently ran nothing there). One
/// `execute_java_script` per script: a syntax error in one cannot
/// take the others down. The GM API is built in `semantic.js`
/// (`usRun`) and holds only what `@grant` asked for.
pub fn injectUserscript(self: *Host, v: *View, frame: *cef.cef_frame_t, sc: *const ScriptRec, page_host: []const u8) void {
    _ = page_host;
    if (!host_mod.sem_secret.ok) return;
    var code: std.Io.Writer.Allocating = .init(self.gpa);
    defer code.deinit();
    const w = &code.writer;
    const slot: []const u8 = &host_mod.sem_secret.slot;
    w.print("window[\"{s}\"]&&window[\"{s}\"]({{\"op\":\"us-run\",\"sid\":{d},\"cap\":\"{s}\",\"run\":\"{s}\",\"name\":", .{
        slot, slot, sc.id, &sc.cap,
        switch (sc.meta.run_at) {
            .document_start => "start",
            .document_end => "end",
            .document_idle => "idle",
        },
    }) catch return;
    jsonStr(w, sc.meta.name) catch return;
    w.writeAll(",\"grants\":[") catch return;
    for (sc.meta.grants, 0..) |g, i| {
        if (i != 0) w.writeByte(',') catch return;
        jsonStr(w, g) catch return;
    }
    w.writeAll("],\"info\":{\"scriptHandler\":\"sketerm\",\"version\":\"1\",\"script\":{\"name\":") catch return;
    jsonStr(w, sc.meta.name) catch return;
    w.writeAll(",\"namespace\":") catch return;
    jsonStr(w, sc.meta.namespace) catch return;
    w.writeAll(",\"version\":") catch return;
    jsonStr(w, sc.meta.version) catch return;
    w.writeAll(",\"description\":") catch return;
    jsonStr(w, sc.meta.description) catch return;
    w.writeAll(",\"runAt\":") catch return;
    jsonStr(w, switch (sc.meta.run_at) {
        .document_start => "document-start",
        .document_end => "document-end",
        .document_idle => "document-idle",
    }) catch return;
    w.writeAll(",\"grant\":[") catch return;
    for (sc.meta.grants, 0..) |g, i| {
        if (i != 0) w.writeByte(',') catch return;
        jsonStr(w, g) catch return;
    }
    w.writeAll("]}},\"values\":") catch return;
    const has_values = userscript.granted(&sc.meta, "GM_getValue") or userscript.granted(&sc.meta, "GM_listValues");
    if (has_values) {
        if (self.gm_values.get(&sc.key)) |st| {
            const bytes = st.serialize(self.gpa) catch return;
            defer self.gpa.free(bytes);
            w.writeAll(bytes) catch return;
        } else w.writeAll("{}") catch return;
    } else w.writeAll("{}") catch return;
    w.writeAll(",\"fn\":function(GM_info,GM_getValue,GM_setValue,GM_deleteValue,GM_listValues," ++
        "GM_addStyle,GM_xmlhttpRequest,GM,unsafeWindow){\n") catch return;
    w.writeAll(sc.source) catch return;
    w.writeAll("\n}},0)") catch return;
    _ = v;
    runJs(frame, code.written());
}

/// A `GM_*` call from a userscript (`us-call`): the value store and
/// `GM_xmlhttpRequest`. Authorised by the script's capability.
pub fn usCall(self: *Host, v: *View, json: []const u8) void {
    const R = struct {
        sid: u32 = 0,
        cap: []const u8 = "",
        method: []const u8 = "",
        key: []const u8 = "",
        value: std.json.Value = .null,
        req: u32 = 0,
        url: []const u8 = "",
        xmethod: []const u8 = "GET",
        headers: std.json.Value = .null,
        data: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const r = parsed.value;
    const sc = for (self.us_scripts.items) |*s| {
        if (s.id == r.sid and std.mem.eql(u8, &s.cap, r.cap)) break s;
    } else return;
    if (std.mem.eql(u8, r.method, "setValue") or std.mem.eql(u8, r.method, "deleteValue")) {
        if (!userscript.granted(&sc.meta, if (r.method[0] == 's') "GM_setValue" else "GM_deleteValue")) return;
        const st = self.gm_values.get(&sc.key) orelse return;
        if (r.method[0] == 's') {
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            aw.writer.writeByte('{') catch return;
            jsonStr(&aw.writer, r.key) catch return;
            aw.writer.writeByte(':') catch return;
            std.json.Stringify.value(r.value, .{}, &aw.writer) catch return;
            aw.writer.writeByte('}') catch return;
            const ch = st.set(self.gpa, aw.written()) catch return;
            self.gpa.free(ch);
        } else {
            const ch = st.remove(self.gpa, &.{r.key}) catch return;
            self.gpa.free(ch);
        }
        self.gm_values.touch(&sc.key);
        return;
    }
    if (!std.mem.eql(u8, r.method, "xhr")) return;
    if (!userscript.granted(&sc.meta, "GM_xmlhttpRequest")) {
        self.usXhrReply(v, r.req, 0, "", "", "", r.url, "GM_xmlhttpRequest is not granted (@grant)");
        return;
    }
    var pf: [2048]u8 = undefined;
    var tf: [2048]u8 = undefined;
    const page_host = filter.hostOf(filter.foldUrl(&pf, v.url));
    const target_host = filter.hostOf(filter.foldUrl(&tf, r.url));
    const scheme_ok = std.mem.startsWith(u8, r.url, "http://") or std.mem.startsWith(u8, r.url, "https://");
    if (!scheme_ok or !userscript.connectAllowed(&sc.meta, page_host, target_host)) {
        var msg_buf: [300]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "blocked by @connect: {s} is not declared", .{target_host}) catch "blocked by @connect";
        self.usXhrReply(v, r.req, 0, "", "", "", r.url, msg);
        return;
    }
    if (!gmXhrStart(self, v, r.req, r.url, r.xmethod, r.headers, r.data)) {
        self.usXhrReply(v, r.req, 0, "", "", "", r.url, "the request could not be started");
    }
}

/// The answer to one `GM_xmlhttpRequest`, to the page's main frame.
pub fn usXhrReply(self: *Host, v: *View, req: u32, status: i32, status_text: []const u8, headers: []const u8, body: []const u8, final_url: []const u8, err: []const u8) void {
    var cmd: std.Io.Writer.Allocating = .init(self.gpa);
    defer cmd.deinit();
    const w = &cmd.writer;
    w.print("{{\"op\":\"us-xhr\",\"req\":{d},\"status\":{d},\"statusText\":", .{ req, status }) catch return;
    jsonStr(w, status_text) catch return;
    w.writeAll(",\"headers\":") catch return;
    jsonStr(w, headers) catch return;
    w.writeAll(",\"body\":") catch return;
    jsonStr(w, body) catch return;
    w.writeAll(",\"finalUrl\":") catch return;
    jsonStr(w, final_url) catch return;
    w.writeAll(",\"error\":") catch return;
    jsonStr(w, err) catch return;
    w.writeByte('}') catch return;
    self.sendScript(v, cmd.written());
}
