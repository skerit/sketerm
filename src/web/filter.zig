//! EasyList-subset network filter engine for the browser helper's
//! request interception (capability "intercept").
//!
//! Pure code: std only, no CEF, no GTK, no sockets — the same
//! portability rule as protocol.zig, so a future non-CEF helper reuses
//! it unchanged and both test roots compile it headless.
//!
//! Supported filter grammar (the network subset of EasyList):
//!   - `||host^...`  host-anchored rules (any subdomain of `host`)
//!   - plain substrings, `*` wildcards, `^` separator placeholders,
//!     `|` start/end anchors
//!   - `@@` exception rules
//!   - `$` options: resource types (script, image, stylesheet,
//!     subdocument, document, font, media, websocket, xmlhttprequest/
//!     xhr, ping, other, ~negations), `third-party`/`3p`/`1p`,
//!     `domain=a|~b`, `match-case` (accepted, ignored — matching is
//!     case-folded), `important` (accepted, no distinct precedence)
//!   - element hiding (cosmetic) rules: generic `##selector`,
//!     domain-scoped `a.com,~b.a.com##selector`, exceptions `#@#`.
//!     `cosmeticFor` compiles the set applicable to one host into a
//!     `display:none !important` stylesheet, ONE rule per selector so
//!     a selector the engine cannot parse invalidates only itself.
//!     Procedural/style cosmetics (`#?#`, `#$#`) are dropped and
//!     counted in `cos_dropped` — half-applying `:has()` chains or
//!     style injection would be wrong more often than useful.
//!   - comments (`!`, `[Adblock...`)
//! A rule carrying an UNSUPPORTED option is dropped whole: silently
//! ignoring the option would over-block (`$popup`, redirects, csp).
//!
//! Matching mirrors ABP/uBO semantics where they are load-bearing:
//! a rule with no type option applies to every request EXCEPT top-level
//! documents (blocking navigations needs an explicit `document`), and
//! "third-party" compares approximate registrable domains (last two
//! labels, plus a small built-in list of two-part public suffixes — no
//! PSL is shipped, and the approximation only misgroups exotic ccTLD
//! pairs).
//!
//! THREAD CONTRACT: an Engine is immutable after `finish` — the helper
//! matches from CEF's IO thread under a spinlock while the main thread
//! only ever swaps whole engines. Nothing here locks; the caller does.

const std = @import("std");
const urlhost = @import("urlhost.zig");

/// Engine-agnostic resource classes, aligned with the wire's
/// `NetResource` byte in protocol.zig.
pub const RType = enum(u8) {
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

    pub fn bit(self: RType) u16 {
        return @as(u16, 1) << @as(u4, @intCast(@intFromEnum(self)));
    }
};

const ALL_TYPES: u16 = 0x7ff;
/// Default applicability: everything but a top-level document.
const DEFAULT_TYPES: u16 = ALL_TYPES & ~RType.document.bit();

/// One request as the matcher sees it. `url` must be lower-cased by
/// the caller (rules are folded at parse time).
pub const Request = struct {
    url: []const u8,
    /// Host part of `url` (the caller usually has it already).
    host: []const u8,
    /// Host of the DOCUMENT that made the request ("" when unknown).
    doc_host: []const u8 = "",
    rtype: RType = .other,
};

const Party = enum(u2) { any, third, first };

/// One element-hiding rule. Selectors are stored VERBATIM (selector
/// text is case-sensitive), only the domain scope is folded.
const CosRule = struct {
    selector: []const u8,
    /// `#@#`: unhide `selector` on the scoped domains.
    exception: bool = false,
    /// Hosts (or their subdomains) the rule is limited to / excluded
    /// from. Both empty = generic (applies everywhere).
    dom_include: []const []const u8 = &.{},
    dom_exclude: []const []const u8 = &.{},
};

const Rule = struct {
    /// For host-anchored rules: the `||` host. Empty otherwise.
    anchor_host: []const u8 = "",
    /// Pattern after the host (host-anchored) or the whole pattern.
    pattern: []const u8 = "",
    exception: bool = false,
    anchor_start: bool = false,
    anchor_end: bool = false,
    types: u16 = DEFAULT_TYPES,
    party: Party = .any,
    /// From `domain=`: hosts (or their subdomains) the rule is limited
    /// to / excluded from. Both empty = applies everywhere.
    dom_include: []const []const u8 = &.{},
    dom_exclude: []const []const u8 = &.{},
};

pub const Engine = struct {
    /// Owns every rule string; freed as one block.
    arena_state: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    rules: std.ArrayList(Rule) = .empty,
    /// `||host` rules bucketed by their anchor host, so the hot path
    /// probes one map entry per label suffix of the request host
    /// instead of scanning every rule. Values index `rules`.
    by_host: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    /// Rules with no host anchor, scanned per request.
    generic: std.ArrayList(u32) = .empty,
    /// Parsed (kept) network rules.
    count: u32 = 0,
    /// Lines that looked like network rules but were dropped
    /// (unsupported option, empty pattern).
    dropped: u32 = 0,
    /// Element-hiding rules, scanned linearly per `cosmeticFor` call
    /// (once per navigation — EasyList-scale sets cost well under a
    /// millisecond, measured in the unit tests' worst case).
    cos_rules: std.ArrayList(CosRule) = .empty,
    /// Kept cosmetic rules (block + exception).
    cos_count: u32 = 0,
    /// Cosmetic lines this engine refuses: procedural (`#?#`) and
    /// style (`#$#`) rules, and empty selectors.
    cos_dropped: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Engine {
        return .{ .arena_state = std.heap.ArenaAllocator.init(gpa), .gpa = gpa };
    }

    pub fn deinit(self: *Engine) void {
        var it = self.by_host.valueIterator();
        while (it.next()) |list| list.deinit(self.gpa);
        self.by_host.deinit(self.gpa);
        self.generic.deinit(self.gpa);
        self.rules.deinit(self.gpa);
        self.cos_rules.deinit(self.gpa);
        self.arena_state.deinit();
    }

    /// Parse one filter list (one rule per line) into the engine.
    /// Unparseable lines are counted, never fatal — a user list must
    /// not take the whole engine down.
    pub fn addList(self: *Engine, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try self.addLine(line);
        }
    }

    fn addLine(self: *Engine, line: []const u8) !void {
        if (line[0] == '!' or line[0] == '[') return; // comment / header
        // Cosmetic rules: `[domains]##sel` / `[domains]#@#sel`; the
        // procedural (`#?#`) and style (`#$#`) dialects are refused.
        if (findCosMarker(line)) |m| {
            switch (m.kind) {
                .block => try self.addCosmetic(line[0..m.at], line[m.at + 2 ..], false),
                .exception => try self.addCosmetic(line[0..m.at], line[m.at + 3 ..], true),
                .unsupported => self.cos_dropped += 1,
            }
            return;
        }

        var rule = Rule{};
        var body = line;
        if (std.mem.startsWith(u8, body, "@@")) {
            rule.exception = true;
            body = body[2..];
        }

        // Options live after the LAST '$' (a URL pattern may contain
        // one); an unparseable option set drops the rule.
        if (std.mem.lastIndexOfScalar(u8, body, '$')) |dollar| {
            if (dollar + 1 < body.len and looksLikeOptions(body[dollar + 1 ..])) {
                if (!try self.parseOptions(&rule, body[dollar + 1 ..])) {
                    self.dropped += 1;
                    return;
                }
                body = body[0..dollar];
            }
        }
        if (body.len == 0) {
            self.dropped += 1;
            return;
        }

        if (std.mem.startsWith(u8, body, "||")) {
            body = body[2..];
            // Host = up to the first pattern metacharacter/separator.
            var host_end: usize = body.len;
            for (body, 0..) |ch, i| {
                if (ch == '/' or ch == '^' or ch == '*' or ch == '?' or ch == ':' or ch == '|') {
                    host_end = i;
                    break;
                }
            }
            if (host_end == 0) {
                self.dropped += 1;
                return;
            }
            rule.anchor_host = try self.lowerDup(body[0..host_end]);
            var pat = body[host_end..];
            if (pat.len > 0 and pat[pat.len - 1] == '|') {
                rule.anchor_end = true;
                pat = pat[0 .. pat.len - 1];
            }
            rule.pattern = try self.lowerDup(pat);
        } else {
            if (body.len > 0 and body[0] == '|') {
                rule.anchor_start = true;
                body = body[1..];
            }
            if (body.len > 0 and body[body.len - 1] == '|') {
                rule.anchor_end = true;
                body = body[0 .. body.len - 1];
            }
            // A bare "*" (or nothing) with options is a match-all rule;
            // keep it only when options constrain it, otherwise it is a
            // block-everything foot-gun from a malformed list.
            const meaningless = for (body) |ch| {
                if (ch != '*') break false;
            } else true;
            if (meaningless and rule.types == DEFAULT_TYPES and rule.party == .any and
                rule.dom_include.len == 0 and rule.dom_exclude.len == 0)
            {
                self.dropped += 1;
                return;
            }
            rule.pattern = try self.lowerDup(body);
        }

        const idx: u32 = @intCast(self.rules.items.len);
        try self.rules.append(self.gpa, rule);
        if (rule.anchor_host.len > 0) {
            const slot = try self.by_host.getOrPut(self.gpa, rule.anchor_host);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(self.gpa, idx);
        } else {
            try self.generic.append(self.gpa, idx);
        }
        self.count += 1;
    }

    fn lowerDup(self: *Engine, s: []const u8) ![]const u8 {
        const out = try self.arena_state.allocator().alloc(u8, s.len);
        for (s, out) |ch, *o| o.* = std.ascii.toLower(ch);
        return out;
    }

    /// True = options fully understood and applied; false = drop rule.
    fn parseOptions(self: *Engine, rule: *Rule, opts: []const u8) !bool {
        var include_mask: u16 = 0;
        var exclude_mask: u16 = 0;
        var it = std.mem.splitScalar(u8, opts, ',');
        while (it.next()) |raw| {
            var opt = raw;
            if (opt.len == 0) continue;
            var negated = false;
            if (opt[0] == '~') {
                negated = true;
                opt = opt[1..];
            }
            if (typeOf(opt)) |t| {
                if (negated) exclude_mask |= t.bit() else include_mask |= t.bit();
                continue;
            }
            const eql = std.ascii.eqlIgnoreCase;
            if (eql(opt, "third-party") or eql(opt, "3p")) {
                rule.party = if (negated) .first else .third;
                continue;
            }
            if (eql(opt, "first-party") or eql(opt, "1p")) {
                rule.party = if (negated) .third else .first;
                continue;
            }
            if (eql(opt, "match-case") or eql(opt, "important")) continue;
            if (std.ascii.startsWithIgnoreCase(opt, "domain=")) {
                if (negated) return false;
                try self.parseDomains(rule, opt["domain=".len..]);
                continue;
            }
            // csp=, redirect=, popup, removeparam, ... — refusing the
            // rule is safer than half-applying it.
            return false;
        }
        if (include_mask != 0) {
            rule.types = include_mask;
        } else if (exclude_mask != 0) {
            rule.types = ALL_TYPES & ~exclude_mask;
        }
        return true;
    }

    /// One cosmetic rule: `domains` is the comma-separated scope
    /// before the marker (may be empty = generic), `sel` the selector.
    fn addCosmetic(self: *Engine, domains: []const u8, sel: []const u8, exception: bool) !void {
        const selector = std.mem.trim(u8, sel, " \t");
        if (selector.len == 0) {
            self.cos_dropped += 1;
            return;
        }
        var rule = CosRule{
            .selector = try self.arena_state.allocator().dupe(u8, selector),
            .exception = exception,
        };
        if (domains.len > 0) {
            var inc: std.ArrayList([]const u8) = .empty;
            var exc: std.ArrayList([]const u8) = .empty;
            defer inc.deinit(self.gpa);
            defer exc.deinit(self.gpa);
            var it = std.mem.splitScalar(u8, domains, ',');
            while (it.next()) |raw| {
                const d = std.mem.trim(u8, raw, " \t");
                if (d.len == 0) continue;
                if (d[0] == '~') {
                    if (d.len > 1) try exc.append(self.gpa, try self.lowerDup(d[1..]));
                } else {
                    try inc.append(self.gpa, try self.lowerDup(d));
                }
            }
            const arena = self.arena_state.allocator();
            rule.dom_include = try arena.dupe([]const u8, inc.items);
            rule.dom_exclude = try arena.dupe([]const u8, exc.items);
        }
        try self.cos_rules.append(self.gpa, rule);
        self.cos_count += 1;
    }

    /// Does a cosmetic rule's domain scope cover `host`? A generic
    /// rule (no includes) covers every host, including the empty host
    /// of an authority-less url; excludes always win.
    fn cosApplies(r: *const CosRule, host: []const u8) bool {
        for (r.dom_exclude) |d| {
            if (hostWithin(host, d)) return false;
        }
        if (r.dom_include.len == 0) return true;
        for (r.dom_include) |d| {
            if (hostWithin(host, d)) return true;
        }
        return false;
    }

    /// Compile the element-hiding stylesheet for one (folded) host:
    /// every applicable selector minus those a matching `#@#` rule
    /// excepts, ONE `{display:none !important}` rule per selector so
    /// an invalid selector cannot take healthy siblings down with it.
    /// Empty result = nothing to hide. Caller frees. Main thread only
    /// (walks engine state the IO thread never touches).
    pub fn cosmeticFor(self: *const Engine, gpa: std.mem.Allocator, host: []const u8) ![]u8 {
        var excepted: std.StringHashMapUnmanaged(void) = .empty;
        defer excepted.deinit(gpa);
        for (self.cos_rules.items) |*r| {
            if (r.exception and cosApplies(r, host))
                try excepted.put(gpa, r.selector, {});
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.cos_rules.items) |*r| {
            if (r.exception or !cosApplies(r, host)) continue;
            if (excepted.contains(r.selector)) continue;
            try out.appendSlice(gpa, r.selector);
            try out.appendSlice(gpa, "{display:none !important}\n");
        }
        return out.toOwnedSlice(gpa);
    }

    fn parseDomains(self: *Engine, rule: *Rule, spec: []const u8) !void {
        var inc: std.ArrayList([]const u8) = .empty;
        var exc: std.ArrayList([]const u8) = .empty;
        defer inc.deinit(self.gpa);
        defer exc.deinit(self.gpa);
        var it = std.mem.splitScalar(u8, spec, '|');
        while (it.next()) |raw| {
            if (raw.len == 0) continue;
            if (raw[0] == '~') {
                if (raw.len > 1) try exc.append(self.gpa, try self.lowerDup(raw[1..]));
            } else {
                try inc.append(self.gpa, try self.lowerDup(raw));
            }
        }
        const arena = self.arena_state.allocator();
        rule.dom_include = try arena.dupe([]const u8, inc.items);
        rule.dom_exclude = try arena.dupe([]const u8, exc.items);
    }

    /// Should `req` be blocked? Exceptions are consulted only once a
    /// block rule matched, so the common (unmatched) case costs one
    /// pass.
    pub fn match(self: *const Engine, req: Request) bool {
        if (!self.matchKind(req, false)) return false;
        return !self.matchKind(req, true);
    }

    fn matchKind(self: *const Engine, req: Request, want_exception: bool) bool {
        // Host-anchored buckets: probe every label suffix of the host.
        var host = req.host;
        while (host.len > 0) {
            if (self.by_host.get(host)) |list| {
                for (list.items) |idx| {
                    const r = &self.rules.items[idx];
                    if (r.exception == want_exception and self.ruleMatches(r, req)) return true;
                }
            }
            const dot = std.mem.indexOfScalar(u8, host, '.') orelse break;
            host = host[dot + 1 ..];
        }
        for (self.generic.items) |idx| {
            const r = &self.rules.items[idx];
            if (r.exception == want_exception and self.ruleMatches(r, req)) return true;
        }
        return false;
    }

    fn ruleMatches(self: *const Engine, r: *const Rule, req: Request) bool {
        _ = self;
        if (r.types & req.rtype.bit() == 0) return false;
        if (r.party != .any) {
            const third = req.doc_host.len > 0 and !sameSite(req.host, req.doc_host);
            if (r.party == .third and !third) return false;
            if (r.party == .first and third) return false;
        }
        if (r.dom_include.len > 0 or r.dom_exclude.len > 0) {
            // domain= constrains by the DOCUMENT the request came from.
            const doc = if (req.doc_host.len > 0) req.doc_host else req.host;
            for (r.dom_exclude) |d| {
                if (hostWithin(doc, d)) return false;
            }
            if (r.dom_include.len > 0) {
                var ok = false;
                for (r.dom_include) |d| {
                    if (hostWithin(doc, d)) {
                        ok = true;
                        break;
                    }
                }
                if (!ok) return false;
            }
        }

        if (r.anchor_host.len > 0) {
            if (!hostWithin(req.host, r.anchor_host)) return false;
            const host_end = hostEndIn(req.url) orelse return false;
            if (r.pattern.len == 0) return true;
            return matchAt(req.url, host_end, r.pattern, r.anchor_end);
        }
        if (r.anchor_start) return matchAt(req.url, 0, r.pattern, r.anchor_end);
        if (r.pattern.len == 0) return true;
        // Substring search: try every position where the first literal
        // run could start.
        var pos: usize = 0;
        while (pos <= req.url.len) : (pos += 1) {
            if (matchAt(req.url, pos, r.pattern, r.anchor_end)) return true;
            if (pos == req.url.len) break;
        }
        return false;
    }
};

const CosMarker = struct {
    at: usize,
    kind: enum { block, exception, unsupported },
};

/// Locate a cosmetic separator (`##`, `#@#`, `#?#`, `#$#`) whose
/// PREFIX is a plausible domain list — a bare `#` inside a network
/// rule's URL pattern must not reclassify the line.
fn findCosMarker(line: []const u8) ?CosMarker {
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] != '#') continue;
        const kind: @FieldType(CosMarker, "kind") = switch (line[i + 1]) {
            '#' => .block,
            '@', '?', '$' => blk: {
                if (i + 2 >= line.len or line[i + 2] != '#') continue;
                break :blk if (line[i + 1] == '@') .exception else .unsupported;
            },
            else => continue,
        };
        for (line[0..i]) |ch| {
            switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '.', '-', ',', '~', '*', '_', ' ', '\t' => {},
                else => return null, // URL-ish prefix: a network rule
            }
        }
        return .{ .at = i, .kind = kind };
    }
    return null;
}

fn typeOf(opt: []const u8) ?RType {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(opt, "script")) return .script;
    if (eql(opt, "image")) return .image;
    if (eql(opt, "stylesheet") or eql(opt, "css")) return .stylesheet;
    if (eql(opt, "subdocument") or eql(opt, "frame")) return .subdocument;
    if (eql(opt, "document") or eql(opt, "doc")) return .document;
    if (eql(opt, "font")) return .font;
    if (eql(opt, "media")) return .media;
    if (eql(opt, "websocket")) return .websocket;
    if (eql(opt, "xmlhttprequest") or eql(opt, "xhr")) return .xhr;
    if (eql(opt, "ping") or eql(opt, "beacon")) return .ping;
    if (eql(opt, "other")) return .other;
    return null;
}

/// Whether the tail of a `$` split is an option list rather than URL
/// text: option lists only ever use this small character set.
fn looksLikeOptions(s: []const u8) bool {
    for (s) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '~', '=', ',', '|', '.', '_' => {},
            else => return false,
        }
    }
    return true;
}

/// `host` equals `base` or is a subdomain of it.
pub fn hostWithin(host: []const u8, base: []const u8) bool {
    if (std.mem.eql(u8, host, base)) return true;
    if (host.len <= base.len) return false;
    return host[host.len - base.len - 1] == '.' and
        std.mem.endsWith(u8, host, base);
}

/// Two-part public suffixes the registrable-domain approximation must
/// know about, or every co.uk site becomes one site.
const two_part_suffixes = [_][]const u8{
    "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au",
    "co.jp", "ne.jp",  "or.jp", "com.br", "com.cn", "com.tw", "co.kr",
    "co.in", "co.za",  "com.mx", "com.ar", "com.tr", "co.nz",
};

/// Approximate eTLD+1: the last two labels, or three when the last two
/// are a known two-part public suffix.
fn registrable(host: []const u8) []const u8 {
    const last = std.mem.lastIndexOfScalar(u8, host, '.') orelse return host;
    const second = std.mem.lastIndexOfScalar(u8, host[0..last], '.') orelse return host;
    const last_two = host[second + 1 ..];
    for (two_part_suffixes) |suf| {
        if (std.mem.eql(u8, last_two, suf)) {
            const third = std.mem.lastIndexOfScalar(u8, host[0..second], '.') orelse return host;
            return host[third + 1 ..];
        }
    }
    return last_two;
}

/// First-party in the EasyList sense: same registrable domain.
fn sameSite(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, registrable(a), registrable(b));
}

/// Index just past the host part of `url`, or null when the url has no
/// authority (data:, about:).
fn hostEndIn(url: []const u8) ?usize {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    var i = sep + 3;
    // Skip credentials if any.
    if (std.mem.indexOfScalarPos(u8, url, i, '@')) |at| {
        const path = std.mem.indexOfAnyPos(u8, url, i, "/?#") orelse url.len;
        if (at < path) i = at + 1;
    }
    while (i < url.len) : (i += 1) {
        switch (url[i]) {
            '/', '?', '#', ':' => return i,
            else => {},
        }
    }
    return url.len;
}

/// Does a separator-class character (or end of url) satisfy `^`?
fn isSeparator(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '%' => false,
        else => true,
    };
}

/// Match `pat` against `url` anchored at `pos`. `*` spans anything,
/// `^` one separator (or the end of the url). `to_end` requires the
/// match to consume the url.
fn matchAt(url: []const u8, pos: usize, pat: []const u8, to_end: bool) bool {
    var u = pos;
    var p: usize = 0;
    // Backtracking state for the most recent '*'.
    var star_p: ?usize = null;
    var star_u: usize = 0;
    while (true) {
        if (p == pat.len) {
            if (!to_end or u == url.len) return true;
        } else switch (pat[p]) {
            '*' => {
                star_p = p;
                star_u = u;
                p += 1;
                continue;
            },
            '^' => {
                if (u == url.len) {
                    // `^` may match the end of the url; only the rest
                    // of the pattern being empty (or stars) can still
                    // succeed.
                    var rest = p + 1;
                    while (rest < pat.len and pat[rest] == '*') rest += 1;
                    if (rest == pat.len) return true;
                } else if (isSeparator(url[u])) {
                    p += 1;
                    u += 1;
                    continue;
                }
            },
            else => {
                if (u < url.len and url[u] == pat[p]) {
                    p += 1;
                    u += 1;
                    continue;
                }
            },
        }
        // Mismatch: backtrack into the last star, if any.
        const sp = star_p orelse return false;
        star_u += 1;
        if (star_u > url.len) return false;
        p = sp + 1;
        u = star_u;
    }
}

/// Lower-case `src` into `buf`, truncating; the helper folds request
/// urls once before matching.
pub fn foldUrl(buf: []u8, src: []const u8) []const u8 {
    const n = @min(src.len, buf.len);
    for (src[0..n], buf[0..n]) |ch, *o| o.* = std.ascii.toLower(ch);
    return buf[0..n];
}

/// Host part of an already-folded url ("" when there is none).
pub fn hostOf(url: []const u8) []const u8 {
    return urlhost.hostOf(url, urlhost.filtering);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

fn testEngine(list: []const u8) !Engine {
    var e = Engine.init(std.testing.allocator);
    errdefer e.deinit();
    try e.addList(list);
    return e;
}

fn testReq(url: []const u8, doc_host: []const u8, rtype: RType) Request {
    return .{ .url = url, .host = hostOf(url), .doc_host = doc_host, .rtype = rtype };
}

test "comments, headers and cosmetic lines parse to zero NETWORK rules" {
    var e = try testEngine(
        \\[Adblock Plus 2.0]
        \\! a comment
        \\example.com##.ad-banner
        \\example.com#@#.ok
        \\example.com#?#div:has(.ad)
        \\
    );
    defer e.deinit();
    try std.testing.expectEqual(@as(u32, 0), e.count);
    // The `##`/`#@#` lines land in the cosmetic set instead.
    try std.testing.expectEqual(@as(u32, 2), e.cos_count);
    try std.testing.expectEqual(@as(u32, 1), e.cos_dropped);
}

test "cosmetic: generic and domain-scoped rules compile per host" {
    const t = std.testing;
    var e = try testEngine(
        \\##.ad-generic
        \\example.com##.site-ad
        \\example.com,other.net##.pair-ad
        \\~quiet.example##.loud
    );
    defer e.deinit();
    try t.expectEqual(@as(u32, 4), e.cos_count);

    const ex = try e.cosmeticFor(t.allocator, "www.example.com");
    defer t.allocator.free(ex);
    try t.expect(std.mem.indexOf(u8, ex, ".ad-generic{display:none !important}") != null);
    try t.expect(std.mem.indexOf(u8, ex, ".site-ad{display:none !important}") != null);
    try t.expect(std.mem.indexOf(u8, ex, ".pair-ad{") != null);
    try t.expect(std.mem.indexOf(u8, ex, ".loud{") != null);

    const oth = try e.cosmeticFor(t.allocator, "unrelated.test");
    defer t.allocator.free(oth);
    try t.expect(std.mem.indexOf(u8, oth, ".ad-generic{") != null);
    try t.expect(std.mem.indexOf(u8, oth, ".site-ad") == null);
    try t.expect(std.mem.indexOf(u8, oth, ".pair-ad") == null);

    // `~domain##sel` is generic MINUS the excluded domain.
    const quiet = try e.cosmeticFor(t.allocator, "sub.quiet.example");
    defer t.allocator.free(quiet);
    try t.expect(std.mem.indexOf(u8, quiet, ".loud") == null);

    // A host-less document (data: url) still gets the generic set.
    const bare = try e.cosmeticFor(t.allocator, "");
    defer t.allocator.free(bare);
    try t.expect(std.mem.indexOf(u8, bare, ".ad-generic{") != null);
    try t.expect(std.mem.indexOf(u8, bare, ".site-ad") == null);
}

test "cosmetic: #@# exceptions unhide per domain" {
    const t = std.testing;
    var e = try testEngine(
        \\##.promo
        \\news.example##.banner
        \\news.example#@#.promo
        \\#@#.everywhere-ok
        \\##.everywhere-ok
    );
    defer e.deinit();

    // On news.example the generic .promo is excepted, .banner applies.
    const news = try e.cosmeticFor(t.allocator, "news.example");
    defer t.allocator.free(news);
    try t.expect(std.mem.indexOf(u8, news, ".promo") == null);
    try t.expect(std.mem.indexOf(u8, news, ".banner{") != null);
    // A GENERIC exception blanks the selector everywhere.
    try t.expect(std.mem.indexOf(u8, news, ".everywhere-ok") == null);

    // Elsewhere .promo hides as usual.
    const oth = try e.cosmeticFor(t.allocator, "other.test");
    defer t.allocator.free(oth);
    try t.expect(std.mem.indexOf(u8, oth, ".promo{") != null);
    try t.expect(std.mem.indexOf(u8, oth, ".banner") == null);
}

test "cosmetic: procedural and style dialects are refused, counted" {
    const t = std.testing;
    var e = try testEngine(
        \\example.com#?#div:has(> .ad)
        \\example.com#$#body { background: none }
        \\example.com##
        \\##[href^="https://tracker."]
    );
    defer e.deinit();
    // #?# + #$# + empty selector = 3 refusals; the attribute selector
    // (URL-ish characters AFTER the marker) is kept.
    try t.expectEqual(@as(u32, 3), e.cos_dropped);
    try t.expectEqual(@as(u32, 1), e.cos_count);
    const css = try e.cosmeticFor(t.allocator, "example.com");
    defer t.allocator.free(css);
    try t.expect(std.mem.indexOf(u8, css, "[href^=\"https://tracker.\"]{display:none !important}") != null);
}

test "cosmetic: a network rule with a # in its pattern stays a network rule" {
    const t = std.testing;
    var e = try testEngine("/path##frag\n");
    defer e.deinit();
    // '/' before the marker is not a domain-list character.
    try t.expectEqual(@as(u32, 1), e.count);
    try t.expectEqual(@as(u32, 0), e.cos_count);
}

test "cosmetic: an empty engine hides nothing" {
    var e = Engine.init(std.testing.allocator);
    defer e.deinit();
    const css = try e.cosmeticFor(std.testing.allocator, "any.test");
    defer std.testing.allocator.free(css);
    try std.testing.expectEqual(@as(usize, 0), css.len);
}

test "host-anchored rule blocks the host and its subdomains only" {
    var e = try testEngine("||ads.example^\n");
    defer e.deinit();
    try std.testing.expect(e.match(testReq("http://ads.example/banner.png", "site.test", .image)));
    try std.testing.expect(e.match(testReq("https://sub.ads.example/x", "site.test", .script)));
    try std.testing.expect(e.match(testReq("https://ads.example:8080/x", "site.test", .script)));
    // Not a subdomain, just a suffix string.
    try std.testing.expect(!e.match(testReq("http://notads.example/banner.png", "site.test", .image)));
    try std.testing.expect(!e.match(testReq("http://ads.example.evil/banner.png", "site.test", .image)));
}

test "host anchor with a path pattern" {
    var e = try testEngine("||example.com/tracker/*\n");
    defer e.deinit();
    try std.testing.expect(e.match(testReq("https://example.com/tracker/pixel.gif", "a.test", .image)));
    try std.testing.expect(!e.match(testReq("https://example.com/content/pixel.gif", "a.test", .image)));
}

test "plain substring and wildcard rules" {
    var e = try testEngine(
        \\/ad_pixel.
        \\banner*install
    );
    defer e.deinit();
    try std.testing.expect(e.match(testReq("http://x.test/ad_pixel.gif", "", .image)));
    try std.testing.expect(!e.match(testReq("http://x.test/ad_pixels/no", "", .image)));
    try std.testing.expect(e.match(testReq("http://x.test/banner/big/install.js", "", .script)));
    try std.testing.expect(!e.match(testReq("http://x.test/install/banner.js", "", .script)));
}

test "start and end anchors" {
    var e = try testEngine(
        \\|http://track.
        \\.swf|
    );
    defer e.deinit();
    try std.testing.expect(e.match(testReq("http://track.test/x", "", .other)));
    try std.testing.expect(!e.match(testReq("http://a.test/http://track.", "", .other)));
    try std.testing.expect(e.match(testReq("http://a.test/movie.swf", "", .other)));
    try std.testing.expect(!e.match(testReq("http://a.test/movie.swf?x=1", "", .other)));
}

test "separator ^ matches separators and the end, not word chars" {
    var e = try testEngine("||example.com^ad^\n");
    defer e.deinit();
    try std.testing.expect(e.match(testReq("http://example.com/ad/1", "", .image)));
    try std.testing.expect(e.match(testReq("http://example.com/ad", "", .image)));
    try std.testing.expect(!e.match(testReq("http://example.com/admin", "", .image)));
}

test "type options include and negate" {
    var e = try testEngine(
        \\||scripts.test^$script
        \\||noimg.test^$~image
    );
    defer e.deinit();
    try std.testing.expect(e.match(testReq("http://scripts.test/a.js", "", .script)));
    try std.testing.expect(!e.match(testReq("http://scripts.test/a.png", "", .image)));
    try std.testing.expect(e.match(testReq("http://noimg.test/a.js", "", .script)));
    try std.testing.expect(!e.match(testReq("http://noimg.test/a.png", "", .image)));
}

test "a typeless rule does not block a top-level document" {
    var e = try testEngine(
        \\||blocked.test^
        \\||alsodoc.test^$document
    );
    defer e.deinit();
    try std.testing.expect(!e.match(testReq("http://blocked.test/", "", .document)));
    try std.testing.expect(e.match(testReq("http://blocked.test/x.js", "", .script)));
    try std.testing.expect(e.match(testReq("http://alsodoc.test/", "", .document)));
}

test "third-party and first-party options" {
    var e = try testEngine(
        \\||cdn.test^$third-party
        \\||self.test^$~third-party
    );
    defer e.deinit();
    // cdn.test embedded by another site: third-party, blocked.
    try std.testing.expect(e.match(testReq("http://cdn.test/x.js", "site.example", .script)));
    // cdn.test on its own pages (same registrable domain): first-party.
    try std.testing.expect(!e.match(testReq("http://cdn.test/x.js", "www.cdn.test", .script)));
    // ~third-party = first-party only.
    try std.testing.expect(e.match(testReq("http://self.test/x.js", "self.test", .script)));
    try std.testing.expect(!e.match(testReq("http://self.test/x.js", "other.example", .script)));
}

test "registrable-domain approximation groups subdomains and co.uk" {
    try std.testing.expect(sameSite("a.example.com", "b.example.com"));
    try std.testing.expect(!sameSite("one.com", "two.com"));
    try std.testing.expect(sameSite("shop.acme.co.uk", "www.acme.co.uk"));
    try std.testing.expect(!sameSite("acme.co.uk", "other.co.uk"));
}

test "domain= limits by document host, with exclusions" {
    var e = try testEngine("||wide.test^$domain=news.example|~sports.news.example\n");
    defer e.deinit();
    try std.testing.expect(e.match(testReq("http://wide.test/x.js", "news.example", .script)));
    try std.testing.expect(e.match(testReq("http://wide.test/x.js", "www.news.example", .script)));
    try std.testing.expect(!e.match(testReq("http://wide.test/x.js", "sports.news.example", .script)));
    try std.testing.expect(!e.match(testReq("http://wide.test/x.js", "other.example", .script)));
}

test "@@ exception overrides a block" {
    var e = try testEngine(
        \\||ads.test^
        \\@@||ads.test/allowed/*
    );
    defer e.deinit();
    try std.testing.expect(e.match(testReq("http://ads.test/banner.png", "", .image)));
    try std.testing.expect(!e.match(testReq("http://ads.test/allowed/banner.png", "", .image)));
}

test "unsupported options drop the whole rule" {
    var e = try testEngine(
        \\||popup.test^$popup
        \\||redir.test^$redirect=noopjs
        \\||csp.test^$csp=script-src
        \\||kept.test^$script,third-party
    );
    defer e.deinit();
    try std.testing.expectEqual(@as(u32, 1), e.count);
    try std.testing.expectEqual(@as(u32, 3), e.dropped);
    try std.testing.expect(!e.match(testReq("http://popup.test/x", "a.test", .other)));
    try std.testing.expect(e.match(testReq("http://kept.test/x.js", "a.test", .script)));
}

test "a bare match-all pattern without constraints is refused" {
    var e = try testEngine(
        \\*
        \\*$image,domain=only.test
    );
    defer e.deinit();
    try std.testing.expectEqual(@as(u32, 1), e.count);
    try std.testing.expect(!e.match(testReq("http://any.test/x.js", "other.test", .script)));
    try std.testing.expect(e.match(testReq("http://any.test/x.png", "only.test", .image)));
}

test "matching is case-insensitive via caller-side folding" {
    var e = try testEngine("||AdServer.Test^$Script\n");
    defer e.deinit();
    var buf: [256]u8 = undefined;
    const folded = foldUrl(&buf, "http://ADSERVER.test/A.JS");
    try std.testing.expect(e.match(.{ .url = folded, .host = hostOf(folded), .rtype = .script }));
}

test "hostOf and hostEndIn handle ports, credentials and no authority" {
    try std.testing.expectEqualStrings("example.com", hostOf("http://example.com/x"));
    try std.testing.expectEqualStrings("example.com", hostOf("http://user:pw@example.com:8080/x"));
    try std.testing.expectEqualStrings("", hostOf("data:text/html,hi"));
    try std.testing.expectEqual(@as(?usize, null), hostEndIn("about:blank"));
}

test "an empty engine blocks nothing" {
    var e = Engine.init(std.testing.allocator);
    defer e.deinit();
    try std.testing.expect(!e.match(testReq("http://ads.test/x.png", "a.test", .image)));
}
