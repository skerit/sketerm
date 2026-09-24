//! Held security decisions, split out of `cefhost.zig`: TLS certificate
//! interstitials (an error is HELD until the client answers; see
//! src/ipc/CLAUDE.md on why a dropped `ev_cert_error` is a hung load)
//! and permission / media-access prompts. The `Host` methods are free
//! functions taking `*Host`, re-exported from `Host` under their old names.

const std = @import("std");
const c = @import("cbindings");
const cef = @import("cef");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const Host = host_mod.Host;
const PendingPerm = host_mod.PendingPerm;
const Utf8 = host_mod.Utf8;
const View = host_mod.View;
const media_id_bit = host_mod.media_id_bit;
const release = host_mod.release;
const releaseArg = host_mod.releaseArg;
const viewOf = host_mod.viewOf;

// -- held security decisions ---------------------------------------

/// The client answered a `ev_cert_error`. A decision for a view with
/// nothing held is ignored: the request may already have been
/// cancelled by a navigation or by the view going away.
pub fn certDecision(self: *Host, req: proto.CertDecision) void {
    const v = self.find(req.view) orelse return;
    resolveCert(v, req.proceed != 0);
}

/// The client answered an `ev_permission`. An unknown prompt id is
/// ignored for the same reason.
pub fn permissionDecision(self: *Host, req: proto.PermissionDecision) void {
    const v = self.find(req.view) orelse return;
    for (&v.perms) |*p| {
        if (p.busy() and p.id == req.prompt) {
            resolvePerm(p, req.allow != 0);
            return;
        }
    }
}

// ---------------------------------------------------------------------
// TLS interstitials and permission prompts
// ---------------------------------------------------------------------

/// Answer a held certificate error and drop the reference. Idempotent:
/// a view with nothing held is left alone, so teardown may always call
/// it.
pub fn resolveCert(v: *View, proceed: bool) void {
    const cb = v.cert_cb orelse return;
    v.cert_cb = null;
    if (proceed) {
        if (cb.cont) |f| f(cb);
    } else {
        if (cb.cancel) |f| f(cb);
    }
    release(&cb.base);
}

/// Answer a held permission request and clear its slot. Idempotent for
/// the same reason as `resolveCert`; the two callback flavours differ
/// only here.
pub fn resolvePerm(p: *PendingPerm, allow: bool) void {
    if (!p.busy()) return;
    // TAKE the slot before continuing. `Continue()` can dismiss the
    // prompt REENTRANTLY — measured on macOS (the first platform where
    // the engine consults this handler at all): CEF 151 runs
    // `on_dismiss_permission_prompt` INSIDE the cont call, and a
    // dismiss that still finds this slot busy releases the callback,
    // after which the release below was a use-after-free (SIGSEGV at a
    // wild address, helper gone). With the slot already cleared the
    // reentrant dismiss finds nothing and this function owns the one
    // release.
    const prompt_cb = p.prompt_cb;
    const media_cb = p.media_cb;
    const media_bits = p.media_bits;
    p.* = .{};
    if (prompt_cb) |cb| {
        if (cb.cont) |f| f(cb, if (allow)
            cef.CEF_PERMISSION_RESULT_ACCEPT
        else
            cef.CEF_PERMISSION_RESULT_DENY);
        release(&cb.base);
    }
    if (media_cb) |cb| {
        // A media callback grants BITS, not a boolean: handing back the
        // ones asked for is an allow, handing back none is a deny.
        if (cb.cont) |f| f(cb, if (allow) media_bits else 0);
        release(&cb.base);
    }
}

/// Free slot for a new prompt on this view, or null when the view is
/// already holding as many as it may.
pub fn permSlot(v: *View) ?*PendingPerm {
    for (&v.perms) |*p| {
        if (!p.busy()) return p;
    }
    return null;
}

pub var next_media_id: u64 = 0;

/// The engine refused a certificate. The request is HELD and the client
/// decides; returning 0 instead would fail the load with the generic
/// error an interstitial exists to replace.
pub fn onCertificateError(
    _: [*c]cef.cef_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    cert_error: cef.cef_errorcode_t,
    request_url: [*c]const cef.cef_string_t,
    ssl_info: [*c]cef.cef_sslinfo_t,
    callback: [*c]cef.cef_callback_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(ssl_info);
    // A held interstitial keeps the callback's reference; `cert_cb`'s
    // answer path releases it.
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = host_mod.g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const cb: *cef.cef_callback_t = callback orelse return 0;
    // One interstitial per view: a second error cannot be shown and
    // must not be silently held, so it takes default handling (fail).
    if (v.cert_cb != null) return 0;

    var url = Utf8.init(request_url);
    defer url.free();

    var subject: [256]u8 = undefined;
    var issuer: [256]u8 = undefined;
    var fingerprint: [64]u8 = undefined;
    const cert = certDetails(ssl_info, &subject, &issuer, &fingerprint);

    v.cert_cb = cb;
    kept = true;
    host.post(proto.EvCertError{
        .view = v.id,
        .code = @intCast(cert_error),
        .url = url.slice(),
        .host = hostOfUrl(url.slice()),
        .msg = certErrorName(cert_error),
        .subject = cert.subject,
        .issuer = cert.issuer,
        .fingerprint = cert.fingerprint,
    });
    return 1;
}

pub const CertDetails = struct {
    subject: []const u8 = "",
    issuer: []const u8 = "",
    fingerprint: []const u8 = "",
};

/// Pull the display name of the subject and issuer plus the SHA-256 of
/// the DER out of an ssl_info, into caller-owned buffers. Every step is
/// optional: an engine that hands us no certificate still produces an
/// interstitial, just a less specific one.
pub fn certDetails(
    ssl_info: [*c]cef.cef_sslinfo_t,
    subject_buf: []u8,
    issuer_buf: []u8,
    fp_buf: *[64]u8,
) CertDetails {
    var out: CertDetails = .{};
    const info: *cef.cef_sslinfo_t = ssl_info orelse return out;
    const get_cert = info.get_x509_certificate orelse return out;
    const cert: *cef.cef_x509_certificate_t = get_cert(info) orelse return out;
    defer release(&cert.base);

    if (cert.get_subject) |gs| {
        const p: ?*cef.cef_x509_cert_principal_t = gs(cert);
        if (p) |principal| {
            defer release(&principal.base);
            out.subject = principalName(principal, subject_buf);
        }
    }
    if (cert.get_issuer) |gi| {
        const p: ?*cef.cef_x509_cert_principal_t = gi(cert);
        if (p) |principal| {
            defer release(&principal.base);
            out.issuer = principalName(principal, issuer_buf);
        }
    }
    if (cert.get_derencoded) |gd| {
        const b: ?*cef.cef_binary_value_t = gd(cert);
        if (b) |bin| {
            defer release(&bin.base);
            var der: [8192]u8 = undefined;
            const size = if (bin.get_size) |gsz| gsz(bin) else 0;
            const want = @min(size, der.len);
            const got = if (bin.get_data) |gdta| gdta(bin, &der, want, 0) else 0;
            if (got != 0 and got == size) {
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(der[0..got], &digest, .{});
                out.fingerprint = std.fmt.bufPrint(fp_buf, "{x}", .{&digest}) catch "";
            }
        }
    }
    return out;
}

pub fn principalName(p: *cef.cef_x509_cert_principal_t, buf: []u8) []const u8 {
    const gn = p.get_display_name orelse return "";
    const raw = gn(p);
    if (raw == null) return "";
    defer cef.cef_string_userfree_utf16_free(raw);
    var s = Utf8.init(raw);
    defer s.free();
    const src = s.slice();
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

/// Host component of `url`, for an interstitial that must name what the
/// user thought they were visiting. Not a parser: everything between
/// "//" and the next "/", minus any userinfo and port.
pub fn hostOfUrl(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "//") orelse return url;
    var rest = url[scheme_end + 2 ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        // An IPv6 literal keeps its colons; a port never follows "]".
        if (std.mem.indexOfScalar(u8, rest, ']') == null) rest = rest[0..colon];
    }
    return rest;
}

/// Symbolic name for the certificate errors an interstitial can show.
/// Anything else keeps its number, which the client prints anyway.
pub fn certErrorName(code: cef.cef_errorcode_t) []const u8 {
    return switch (code) {
        cef.ERR_CERT_COMMON_NAME_INVALID => "CERT_COMMON_NAME_INVALID",
        cef.ERR_CERT_DATE_INVALID => "CERT_DATE_INVALID",
        cef.ERR_CERT_AUTHORITY_INVALID => "CERT_AUTHORITY_INVALID",
        cef.ERR_CERT_CONTAINS_ERRORS => "CERT_CONTAINS_ERRORS",
        cef.ERR_CERT_NO_REVOCATION_MECHANISM => "CERT_NO_REVOCATION_MECHANISM",
        cef.ERR_CERT_UNABLE_TO_CHECK_REVOCATION => "CERT_UNABLE_TO_CHECK_REVOCATION",
        cef.ERR_CERT_REVOKED => "CERT_REVOKED",
        cef.ERR_CERT_INVALID => "CERT_INVALID",
        cef.ERR_CERT_WEAK_SIGNATURE_ALGORITHM => "CERT_WEAK_SIGNATURE_ALGORITHM",
        cef.ERR_CERT_NON_UNIQUE_NAME => "CERT_NON_UNIQUE_NAME",
        cef.ERR_CERT_WEAK_KEY => "CERT_WEAK_KEY",
        cef.ERR_CERT_NAME_CONSTRAINT_VIOLATION => "CERT_NAME_CONSTRAINT_VIOLATION",
        cef.ERR_CERT_VALIDITY_TOO_LONG => "CERT_VALIDITY_TOO_LONG",
        cef.ERR_CERTIFICATE_TRANSPARENCY_REQUIRED => "CERTIFICATE_TRANSPARENCY_REQUIRED",
        else => "CERT_ERROR",
    };
}

/// Engine permission bits -> the wire's own bits. Anything unmapped
/// becomes `perm_other`, which the client still names and prompts for
/// rather than dropping.
pub fn permTypes(bits: u32) u32 {
    var out: u32 = 0;
    var rest = bits;
    const table = [_]struct { cef_bit: u32, wire: u32 }{
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_GEOLOCATION, .wire = proto.perm_geolocation },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_NOTIFICATIONS, .wire = proto.perm_notifications },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_CAMERA_STREAM, .wire = proto.perm_camera },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, .wire = proto.perm_camera },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_MIC_STREAM, .wire = proto.perm_microphone },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_MIDI_SYSEX, .wire = proto.perm_midi },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_CLIPBOARD, .wire = proto.perm_clipboard },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_POINTER_LOCK, .wire = proto.perm_pointer_lock },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_IDLE_DETECTION, .wire = proto.perm_idle_detection },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_STORAGE_ACCESS, .wire = proto.perm_storage_access },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, .wire = proto.perm_storage_access },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, .wire = proto.perm_window_management },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER, .wire = proto.perm_protected_media },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_LOCAL_FONTS, .wire = proto.perm_local_fonts },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, .wire = proto.perm_file_system },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, .wire = proto.perm_downloads },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_SENSORS, .wire = proto.perm_sensors },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_VR_SESSION, .wire = proto.perm_vr },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_AR_SESSION, .wire = proto.perm_vr },
    };
    for (table) |e| {
        if (rest & e.cef_bit != 0) {
            out |= e.wire;
            rest &= ~e.cef_bit;
        }
    }
    if (rest != 0) out |= proto.perm_other;
    return out;
}

pub fn onShowPermissionPrompt(
    _: [*c]cef.cef_permission_handler_t,
    browser: [*c]cef.cef_browser_t,
    prompt_id: u64,
    requesting_origin: [*c]const cef.cef_string_t,
    requested_permissions: u32,
    callback: [*c]cef.cef_permission_prompt_callback_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = host_mod.g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const cb: *cef.cef_permission_prompt_callback_t = callback orelse return 0;
    const slot = permSlot(v) orelse return 0;
    // A helper-minted media id could otherwise collide with an engine
    // one; the engine's own ids never carry the top bit.
    if (prompt_id & media_id_bit != 0) return 0;

    var origin = Utf8.init(requesting_origin);
    defer origin.free();
    slot.* = .{ .id = prompt_id, .prompt_cb = cb };
    kept = true;
    host.post(proto.EvPermission{
        .view = v.id,
        .prompt = prompt_id,
        .origin = origin.slice(),
        .types = permTypes(requested_permissions),
    });
    return 1;
}

/// Camera/microphone come through their OWN callback with no prompt id,
/// so one is minted here (see `PendingPerm`).
pub fn onRequestMediaAccess(
    _: [*c]cef.cef_permission_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    requesting_origin: [*c]const cef.cef_string_t,
    requested_permissions: u32,
    callback: [*c]cef.cef_media_access_callback_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = host_mod.g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const cb: *cef.cef_media_access_callback_t = callback orelse return 0;
    const slot = permSlot(v) orelse return 0;

    var types: u32 = 0;
    if (requested_permissions & (cef.CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE |
        cef.CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE) != 0) types |= proto.perm_microphone;
    if (requested_permissions & (cef.CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE |
        cef.CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE) != 0) types |= proto.perm_camera;
    if (types == 0) types = proto.perm_other;

    next_media_id +%= 1;
    const id = media_id_bit | next_media_id;
    var origin = Utf8.init(requesting_origin);
    defer origin.free();
    slot.* = .{ .id = id, .media_cb = cb, .media_bits = requested_permissions };
    kept = true;
    host.post(proto.EvPermission{
        .view = v.id,
        .prompt = id,
        .origin = origin.slice(),
        .types = types,
    });
    return 1;
}

/// The engine gave up on a prompt we were holding (navigation, browser
/// closing, or our own Continue). The slot is dropped WITHOUT calling
/// back: the callback is spent, and a late `permission_decision` for
/// this id then finds nothing, which is exactly how it must behave.
pub fn onDismissPermissionPrompt(
    _: [*c]cef.cef_permission_handler_t,
    browser: [*c]cef.cef_browser_t,
    prompt_id: u64,
    _: cef.cef_permission_request_result_t,
) callconv(.c) void {
    defer releaseArg(browser);
    const v = viewOf(browser) orelse return;
    for (&v.perms) |*p| {
        if (p.busy() and p.id == prompt_id) {
            if (p.prompt_cb) |cb| release(&cb.base);
            p.* = .{};
            return;
        }
    }
}
