//! Previewing a REMOTE PDF on this computer when its host cannot.
//!
//! A host without pdftoppm cannot draw a PDF poster. A PDF up to
//! `LOCAL_RENDER_MAX_BYTES` is then fetched into a private staging
//! cache and the LOCAL daemon renders it with its ordinary preview job
//! (mux/jobs/preview.zig), so there is still one preview implementation;
//! a larger PDF is never fetched and keeps an error that names the limit.
//! The viewer (ui/viewer.zig) and the file browser's preview pane and row
//! thumbnails (ui/browser/preview.zig) share this policy and this cache.
//!
//! Staged copies are named by the remote file's identity (host, path,
//! size, mtime), so a revisit renders from the copy without fetching it
//! again and hits the local daemon's thumbnail cache, and are swept by
//! `util/dirsweep.zig` whenever a new copy is staged.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const dirsweep = @import("../util/dirsweep.zig");
const pathz = @import("../util/pathz.zig");
const fsjob = @import("../mux/fsjob.zig");
const fsserve = @import("../mux/fsserve.zig");

/// 2 MiB (2097152 bytes): the largest remote PDF fetched to render here.
pub const LOCAL_RENDER_MAX_BYTES: u64 = 2 << 20;

comptime {
    // The browser fetches the whole PDF with ONE daemon read.
    std.debug.assert(LOCAL_RENDER_MAX_BYTES <= fsserve.MAX_READ);
}

pub fn isPdfName(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".pdf");
}

/// What a host's welcome says about rendering PDFs.
pub const HostPdf = enum { unknown, renders, cannot };

/// @param reports_tools the host advertises `preview_tools`; without it `pdf_preview` means nothing.
pub fn hostPdf(reports_tools: bool, pdf_preview: bool) HostPdf {
    if (!reports_tools) return .unknown;
    return if (pdf_preview) .renders else .cannot;
}

/// Where a PDF preview is rendered: on its host, here, or nowhere.
pub const Route = enum { host, local, too_large };

/// The route before asking the host: one known to lack pdftoppm is not asked.
pub fn routeBefore(remote: bool, name: []const u8, host: HostPdf, size: u64) Route {
    if (!remote or !isPdfName(name) or host != .cannot) return .host;
    return bySize(size);
}

/// The route once the host's preview job failed with error `kind`.
/// @return null when the host's own error stands.
pub fn routeAfterFailure(remote: bool, name: []const u8, kind: []const u8, size: u64) ?Route {
    if (!remote or !isPdfName(name) or !std.mem.eql(u8, kind, fsjob.NO_GENERATOR_KIND)) return null;
    return bySize(size);
}

fn bySize(size: u64) Route {
    return if (size <= LOCAL_RENDER_MAX_BYTES) .local else .too_large;
}

/// The error for a PDF its host cannot render and that is too large to fetch.
pub fn tooLargeMessage(buf: []u8, host: []const u8, size: u64) []const u8 {
    const mib = @as(f64, @floatFromInt(size)) / (1 << 20);
    return std.fmt.bufPrint(buf, "pdftoppm is not installed on {s}, and this {d:.1} MiB PDF is over the 2 MiB limit for previewing it on this computer (PDF previews need poppler-utils)", .{ host, mib }) catch
        "pdftoppm is not installed on the host, and this PDF is over the 2 MiB limit for previewing it on this computer (PDF previews need poppler-utils)";
}

/// The error when this computer cannot render the PDF either.
pub fn neitherMessage(buf: []u8, host: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "pdftoppm is installed neither on {s} nor on this computer (PDF previews need poppler-utils)", .{host}) catch
        "pdftoppm is installed neither on the host nor on this computer (PDF previews need poppler-utils)";
}

/// Staged copies older than a day are swept, and at most this many kept
/// (each is at most 2 MiB).
const STAGE_MAX_AGE_SECS: i64 = 24 * 3600;
const STAGE_MAX_FILES: usize = 64;
const STAGE_SUFFIX = ".pdf";

/// `<cache_root>/sketerm/pdf-local/<md5 of the identity>.pdf`.
/// @param mtime_ms the remote file's mtime; any change names a new copy.
pub fn stagedPath(buf: []u8, cache_root: []const u8, host: []const u8, path: []const u8, size: u64, mtime_ms: i64) ?[]const u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    var num: [48]u8 = undefined;
    md5.update(host);
    md5.update("\x00");
    md5.update(path);
    md5.update(std.fmt.bufPrint(&num, "\x00{d}\x00{d}", .{ size, mtime_ms }) catch unreachable);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(buf, "{s}/sketerm/pdf-local/{s}" ++ STAGE_SUFFIX, .{ cache_root, &hex }) catch null;
}

/// A complete staged copy of `size` bytes is already at `path`.
pub fn isStaged(path: []const u8, size: u64) bool {
    var z: [4096:0]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return false;
    var st: c.struct_stat = undefined;
    if (c.stat(p, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) return false;
    return st.st_size >= 0 and @as(u64, @intCast(st.st_size)) == size;
}

pub const StageError = error{ PathTooLong, StageFailed };

/// Write `bytes` to the staged copy at `path` (from `stagedPath`), first
/// sweeping old copies. Blocking file IO: callers keep it off a busy loop
/// where they can, and the copy is at most 2 MiB.
pub fn stage(path: []const u8, bytes: []const u8) StageError!void {
    const dir = std.fs.path.dirname(path) orelse return error.StageFailed;
    pathz.makeDirs(dir, 0o700) catch |err| switch (err) {
        error.PathTooLong => return error.PathTooLong,
        error.MkdirFailed => return error.StageFailed,
    };
    var dz: [4096:0]u8 = undefined;
    const dirz = pathz.pathZ(&dz, dir) catch return error.PathTooLong;
    dirsweep.sweep(dirz, .{
        .suffix = STAGE_SUFFIX,
        .max_age_secs = STAGE_MAX_AGE_SECS,
        .max_files = STAGE_MAX_FILES,
        .trim_extra = STAGE_MAX_FILES / 4,
    });
    atomicwrite.writeCacheFile(path, bytes, 0o600) catch return error.StageFailed;
}

const t = std.testing;

test "routes: only a remote PDF its host cannot render leaves the host, and only up to 2 MiB" {
    const cap = LOCAL_RENDER_MAX_BYTES;
    try t.expectEqual(@as(u64, 2097152), cap);
    try t.expectEqual(Route.local, routeBefore(true, "a.pdf", .cannot, 1024));
    try t.expectEqual(Route.local, routeBefore(true, "A.PDF", .cannot, cap));
    try t.expectEqual(Route.too_large, routeBefore(true, "a.pdf", .cannot, cap + 1));
    // Asked as usual: a host that renders, an old one that never said,
    // a local file, and anything that is not a PDF.
    try t.expectEqual(Route.host, routeBefore(true, "a.pdf", .renders, 1024));
    try t.expectEqual(Route.host, routeBefore(true, "a.pdf", .unknown, 1024));
    try t.expectEqual(Route.host, routeBefore(false, "a.pdf", .cannot, 1024));
    try t.expectEqual(Route.host, routeBefore(true, "a.mkv", .cannot, 1024));
}

test "after a failure: only a missing generator on a remote PDF's host falls back" {
    const cap = LOCAL_RENDER_MAX_BYTES;
    try t.expectEqual(Route.local, routeAfterFailure(true, "a.pdf", fsjob.NO_GENERATOR_KIND, cap).?);
    try t.expectEqual(Route.too_large, routeAfterFailure(true, "a.pdf", fsjob.NO_GENERATOR_KIND, cap + 1).?);
    // A broken PDF, an unkinded error from an old daemon, a local file
    // and a missing ffmpeg for a video all keep the host's own error.
    try t.expect(routeAfterFailure(true, "a.pdf", "", 10) == null);
    try t.expect(routeAfterFailure(true, "a.pdf", "permanent", 10) == null);
    try t.expect(routeAfterFailure(false, "a.pdf", fsjob.NO_GENERATOR_KIND, 10) == null);
    try t.expect(routeAfterFailure(true, "a.mkv", fsjob.NO_GENERATOR_KIND, 10) == null);
}

test "hostPdf needs the capability before trusting the fact" {
    try t.expectEqual(HostPdf.unknown, hostPdf(false, false));
    try t.expectEqual(HostPdf.unknown, hostPdf(false, true));
    try t.expectEqual(HostPdf.cannot, hostPdf(true, false));
    try t.expectEqual(HostPdf.renders, hostPdf(true, true));
}

test "messages name the host, the size and the limit" {
    var buf: [320]u8 = undefined;
    const big = tooLargeMessage(&buf, "build-box", 3 << 20);
    try t.expect(std.mem.indexOf(u8, big, "build-box") != null);
    try t.expect(std.mem.indexOf(u8, big, "3.0 MiB") != null);
    try t.expect(std.mem.indexOf(u8, big, "2 MiB limit") != null);
    const neither = neitherMessage(&buf, "build-box");
    try t.expectEqualStrings("pdftoppm is installed neither on build-box nor on this computer (PDF previews need poppler-utils)", neither);
}

test "staged copies are named by identity and reused only when complete" {
    var td = pathz.TempDir.make("pdflocal") orelse return error.SkipZigTest;
    defer td.remove();
    const root = td.path();
    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    const a = stagedPath(&a_buf, root, "h", "/x/doc.pdf", 5, 1000).?;
    try t.expectEqualStrings(a, stagedPath(&b_buf, root, "h", "/x/doc.pdf", 5, 1000).?);
    try t.expect(std.mem.endsWith(u8, a, ".pdf"));
    try t.expect(std.mem.indexOf(u8, a, "/sketerm/pdf-local/") != null);
    // Any change of host, path, size or mtime names another copy.
    try t.expect(!std.mem.eql(u8, a, stagedPath(&b_buf, root, "g", "/x/doc.pdf", 5, 1000).?));
    try t.expect(!std.mem.eql(u8, a, stagedPath(&b_buf, root, "h", "/x/doc2.pdf", 5, 1000).?));
    try t.expect(!std.mem.eql(u8, a, stagedPath(&b_buf, root, "h", "/x/doc.pdf", 6, 1000).?));
    try t.expect(!std.mem.eql(u8, a, stagedPath(&b_buf, root, "h", "/x/doc.pdf", 5, 1001).?));

    try t.expect(!isStaged(a, 5));
    try stage(a, "%PDF-");
    try t.expect(isStaged(a, 5));
    // A copy of another size is not the file the identity names.
    try t.expect(!isStaged(a, 6));
}
