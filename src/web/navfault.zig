//! What a client remembers about a navigation that did not simply
//! load: the helper's certificate verdict (`ev_cert_error`) and the last
//! main-frame failure (`ev_load_error`). Shared by the headless driver
//! (`ipc/webdrive.zig`) and the GUI face (`ui/webface.zig`) so both
//! report the same shape over `web-list` and the MCP tools, and so the
//! rule for when a record stops describing the view lives ONCE.
//!
//! Std-only; in both test roots.

const std = @import("std");
const proto = @import("protocol.zig");
const urlhost = @import("urlhost.zig");

pub const CertVerdict = enum {
    /// The helper is holding the request and a person has not answered
    /// yet (GUI interstitial). A headless client never reports this: it
    /// answers the hold itself.
    pending,
    accepted,
    refused,

    pub fn name(self: CertVerdict) []const u8 {
        return @tagName(self);
    }
};

/// One `ev_cert_error`, owned strings.
pub const CertRec = struct {
    verdict: CertVerdict,
    code: i32,
    url: []u8,
    host: []u8,
    msg: []u8,
    subject: []u8,
    issuer: []u8,
    fingerprint: []u8,

    pub fn init(gpa: std.mem.Allocator, ev: proto.EvCertError, verdict: CertVerdict) !CertRec {
        const url = try gpa.dupe(u8, ev.url);
        errdefer gpa.free(url);
        const host = try gpa.dupe(u8, ev.host);
        errdefer gpa.free(host);
        const msg = try gpa.dupe(u8, ev.msg);
        errdefer gpa.free(msg);
        const subject = try gpa.dupe(u8, ev.subject);
        errdefer gpa.free(subject);
        const issuer = try gpa.dupe(u8, ev.issuer);
        errdefer gpa.free(issuer);
        const fingerprint = try gpa.dupe(u8, ev.fingerprint);
        errdefer gpa.free(fingerprint);
        return .{
            .verdict = verdict,
            .code = ev.code,
            .url = url,
            .host = host,
            .msg = msg,
            .subject = subject,
            .issuer = issuer,
            .fingerprint = fingerprint,
        };
    }

    pub fn free(self: *CertRec, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        gpa.free(self.host);
        gpa.free(self.msg);
        gpa.free(self.subject);
        gpa.free(self.issuer);
        gpa.free(self.fingerprint);
    }

    /// The JSON shape; slices borrow the record.
    pub fn wire(self: *const CertRec) CertWire {
        return .{
            .state = self.verdict.name(),
            .code = self.code,
            .url = self.url,
            .host = self.host,
            .msg = self.msg,
            .subject = self.subject,
            .issuer = self.issuer,
            .fingerprint = self.fingerprint,
        };
    }
};

/// One `ev_load_error`, owned strings.
pub const LoadErrRec = struct {
    code: i32,
    url: []u8,
    msg: []u8,

    pub fn init(gpa: std.mem.Allocator, ev: proto.EvLoadError) !LoadErrRec {
        const url = try gpa.dupe(u8, ev.url);
        errdefer gpa.free(url);
        const msg = try gpa.dupe(u8, ev.msg);
        errdefer gpa.free(msg);
        return .{ .code = ev.code, .url = url, .msg = msg };
    }

    pub fn free(self: *LoadErrRec, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        gpa.free(self.msg);
    }

    pub fn wire(self: *const LoadErrRec) LoadErrWire {
        return .{ .code = self.code, .url = self.url, .msg = self.msg };
    }
};

/// The certificate verdict as it travels in `web-list` JSON and in the
/// MCP tool results; the same field names on both backends. `state` is
/// a `CertVerdict` name.
pub const CertWire = struct {
    state: []const u8 = "",
    code: i32 = 0,
    url: []const u8 = "",
    host: []const u8 = "",
    msg: []const u8 = "",
    subject: []const u8 = "",
    issuer: []const u8 = "",
    fingerprint: []const u8 = "",
};

pub const LoadErrWire = struct {
    code: i32 = 0,
    url: []const u8 = "",
    msg: []const u8 = "",
};

/// A new document is on its way: the previous failure no longer
/// describes the view, and a pending or refused certificate belonged to
/// the navigation that is being replaced. An ACCEPTED one is kept while
/// the new load is on the same host, because the page that arrives will
/// stand on it. `url` may be EMPTY: the helper's load-start event
/// carries the view's url as it knew it, which for a freshly created
/// view is nothing yet (the address-change callback fills it later),
/// and an unknown host must not read as a different one.
pub fn loadStarted(gpa: std.mem.Allocator, cert: *?CertRec, load_error: *?LoadErrRec, url: []const u8) void {
    if (load_error.*) |*old| {
        old.free(gpa);
        load_error.* = null;
    }
    if (cert.*) |*rec| {
        const host = urlhost.hostOf(url, urlhost.site);
        const keep = rec.verdict == .accepted and
            (host.len == 0 or std.ascii.eqlIgnoreCase(host, rec.host));
        if (!keep) {
            rec.free(gpa);
            cert.* = null;
        }
    }
}

/// A SHA-256 fingerprint as the helper reports it: 64 hex digits, any
/// case. Anything else cannot match a certificate and is refused at the
/// call rather than silently never matching.
pub fn validFingerprint(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

test "validFingerprint accepts 64 hex digits of any case and nothing else" {
    try std.testing.expect(validFingerprint("ab" ** 32));
    try std.testing.expect(validFingerprint("AB" ** 32));
    try std.testing.expect(!validFingerprint("ab" ** 31));
    try std.testing.expect(!validFingerprint("zz" ** 32));
    try std.testing.expect(!validFingerprint(""));
}

test "loadStarted drops failures and non-accepted verdicts, keeps an accepted one on its host" {
    const gpa = std.testing.allocator;
    const ev = proto.EvCertError{
        .view = 1,
        .code = -202,
        .url = "https://10.0.0.1/",
        .host = "10.0.0.1",
        .msg = "CERT_AUTHORITY_INVALID",
        .subject = "CN=x",
        .issuer = "CN=x",
        .fingerprint = "ab" ** 32,
    };
    var cert: ?CertRec = try CertRec.init(gpa, ev, .refused);
    var load_error: ?LoadErrRec = try LoadErrRec.init(gpa, .{ .view = 1, .code = -202, .url = "https://10.0.0.1/", .msg = "ERR" });
    loadStarted(gpa, &cert, &load_error, "https://10.0.0.1/login");
    try std.testing.expect(cert == null);
    try std.testing.expect(load_error == null);

    cert = try CertRec.init(gpa, ev, .accepted);
    loadStarted(gpa, &cert, &load_error, "HTTPS://10.0.0.1/login");
    try std.testing.expect(cert != null);
    try std.testing.expectEqualStrings("accepted", cert.?.wire().state);
    // A load-start with no url yet (fresh view) keeps it.
    loadStarted(gpa, &cert, &load_error, "");
    try std.testing.expect(cert != null);
    loadStarted(gpa, &cert, &load_error, "https://other.test/");
    try std.testing.expect(cert == null);

    cert = try CertRec.init(gpa, ev, .pending);
    loadStarted(gpa, &cert, &load_error, "https://10.0.0.1/");
    try std.testing.expect(cert == null);
}
