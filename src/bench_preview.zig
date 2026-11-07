//! Image preview transport benchmark: `zig build bench-preview -- <image>...`.
//!
//! Times the daemon's own preview stages (stb decode, box downscale,
//! stb PNG/JPEG encode, runtime-loaded JXL/WebP) per target bound, so a
//! preview-size or codec policy change is argued from numbers.

const std = @import("std");
const c = @import("c.zig").c;
const png = @import("util/png.zig");
const imagecodec = @import("util/imagecodec.zig");
const clock = @import("util/clock.zig");
const imagepolicy = @import("util/imagepolicy.zig");
const fsdrive = @import("ipc/fsdrive.zig");
const client = @import("mux/client.zig");
const lifetime = @import("util/lifetime.zig");

const bounds = [_]u32{ 512, 1024, 1536, 2048, 0 };

fn ms(start_ns: u64) f64 {
    return @as(f64, @floatFromInt(clock.nowNs() - start_ns)) / 1e6;
}

fn fileSize(path: [:0]const u8) u64 {
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) return 0;
    return @intCast(st.st_size);
}

fn row(label: []const u8, bytes: ?usize, took: f64) void {
    if (bytes) |n|
        std.debug.print("    {s:<16} {d:>10} B {d:>9.1} ms\n", .{ label, n, took })
    else
        std.debug.print("    {s:<16} {s:>10}   {d:>9.1} ms\n", .{ label, "-", took });
}

fn pngAt(allocator: std.mem.Allocator, rgba: []const u8, w: u32, h: u32, level: c_int) void {
    const saved = c.stbi_write_png_compression_level;
    defer c.stbi_write_png_compression_level = saved;
    c.stbi_write_png_compression_level = level;
    const t0 = clock.nowNs();
    const out = png.encodeRgba(allocator, rgba, w, h) catch return row("png", null, ms(t0));
    defer allocator.free(out);
    var label_buf: [24]u8 = undefined;
    row(std.fmt.bufPrint(&label_buf, "png level {d}", .{level}) catch "png", out.len, ms(t0));
}

fn jpegAt(allocator: std.mem.Allocator, rgba: []const u8, w: u32, h: u32, q: u8) void {
    const t0 = clock.nowNs();
    const out = png.encodeRgbaJpeg(allocator, rgba, w, h, q) catch return row("jpeg", null, ms(t0));
    defer allocator.free(out);
    var label_buf: [24]u8 = undefined;
    row(std.fmt.bufPrint(&label_buf, "jpeg q{d}", .{q}) catch "jpeg", out.len, ms(t0));
}

fn codecAt(allocator: std.mem.Allocator, rgba: []const u8, w: u32, h: u32, name: []const u8) void {
    const t0 = clock.nowNs();
    const out = imagecodec.encodePreferred(allocator, rgba, w, h, name, 64 << 20) catch return row(name, null, ms(t0));
    defer allocator.free(out.bytes);
    row(name, out.bytes.len, ms(t0));
}

fn benchFile(allocator: std.mem.Allocator, path: [:0]const u8) void {
    const size = fileSize(path);
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const t0 = clock.nowNs();
    const pixels = c.stbi_load(path.ptr, &width, &height, &channels, 4) orelse {
        std.debug.print("{s}: stb cannot decode\n", .{path});
        return;
    };
    defer c.stbi_image_free(pixels);
    const decode_ms = ms(t0);
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    const src = @as([*]const u8, @ptrCast(pixels))[0 .. @as(usize, w) * h * 4];
    std.debug.print("{s}\n  {d}x{d}, {d} B on disk, stb decode {d:.1} ms\n", .{ path, w, h, size, decode_ms });
    for (bounds) |bound| {
        const fit = imagepolicy.fitWithin(w, h, if (bound == 0) @max(w, h) else bound);
        const t1 = clock.nowNs();
        const scaled: ?[]u8 = if (fit.w != w or fit.h != h)
            png.downscaleRgba(allocator, src, w, h, fit.w, fit.h) catch null
        else
            null;
        defer if (scaled) |s| allocator.free(s);
        const scale_ms = ms(t1);
        const rgba = scaled orelse src;
        std.debug.print("  bound {d} -> {d}x{d} (downscale {d:.1} ms)\n", .{ bound, fit.w, fit.h, scale_ms });
        pngAt(allocator, rgba, fit.w, fit.h, 8);
        pngAt(allocator, rgba, fit.w, fit.h, 3);
        jpegAt(allocator, rgba, fit.w, fit.h, 85);
        jpegAt(allocator, rgba, fit.w, fit.h, 92);
        codecAt(allocator, rgba, fit.w, fit.h, "webp");
        codecAt(allocator, rgba, fit.w, fit.h, "jxl");
    }
}

/// Read a whole file over the daemon link. `probed` is the pre-policy
/// viewer's shape (a stat round trip first); otherwise the first chunk's
/// reply carries the size, as the viewer's readAll does now.
fn readAll(fs: *fsdrive.Fs, path: []const u8, cap: usize, probed: bool) ![]u8 {
    const allocator = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (probed) {
        const probe = try fs.read(path, 0, 0, &out);
        if (probe.size > cap) return error.SourceTooLarge;
    }
    while (true) {
        const before = out.items.len;
        const want: u32 = @intCast(@min(cap + 1 - before, fsdrive.fsserve.MAX_READ));
        const info = try fs.read(path, before, want, &out);
        if (out.items.len > cap) return error.SourceTooLarge;
        if (info.eof) break;
        if (out.items.len == before) return error.ShortRead;
    }
    return out.toOwnedSlice(allocator);
}

fn lap(label: []const u8, start_ns: *u64) void {
    const now = clock.nowNs();
    std.debug.print("    {s:<28} {d:>8.1} ms\n", .{ label, @as(f64, @floatFromInt(now - start_ns.*)) / 1e6 });
    start_ns.* = now;
}

/// One viewer image load over a real daemon link, stage by stage:
/// `old` is the pre-policy request (512 px PNG preview), `new` is the
/// sized/direct policy with every request a round trip of its own, and
/// `piped` is that policy as the viewer runs it now: job starts and the
/// metadata request share one round trip, sidecars are released unawaited.
fn e2e(host: []const u8, path: []const u8, mode: []const u8, bound: u32) !void {
    const allocator = std.heap.c_allocator;
    const total0 = clock.nowNs();
    var t = clock.nowNs();
    var fs = fsdrive.Fs.initConn(allocator, try client.Conn.connectRemote(allocator, host, .{}));
    defer fs.deinit();
    lap("connect", &t);
    const load0 = clock.nowNs();
    var probe_bytes: std.ArrayList(u8) = .empty;
    defer probe_bytes.deinit(allocator);
    const source = try fs.read(path, 0, 0, &probe_bytes);
    lap("stat probe", &t);
    var bytes: []u8 = undefined;
    var what: []const u8 = "preview";
    var first_ms: ?f64 = null;
    const piped = std.mem.eql(u8, mode, "piped");
    if (std.mem.eql(u8, mode, "old")) {
        bytes = try previewOver(&fs, path, "png", 0, true, &t);
    } else {
        const plan = imagepolicy.planLoad(.{
            .source_bytes = source.size,
            .client_decodes_original = true,
            .sized_previews = fs.conn.caps.preview_bound,
            .display_bound = bound,
            .remote = true,
        });
        const dirname = std.fs.path.dirname(path) orelse "/";
        const names = [_][]const u8{std.fs.path.basename(path)};
        switch (plan) {
            .original => {
                const meta: ?u32 = if (piped) try fs.mediaMetaSubmit(dirname, &names) else null;
                bytes = try readAll(&fs, path, 128 << 20, false);
                lap("read original", &t);
                what = "original";
                if (meta) |m| try pipedMeta(&fs, m, &t);
            },
            .preview => |p| if (piped) {
                const quick_req: ?u32 = if (p.quick_first) try fs.previewSubmit(path, p.codecs, imagepolicy.DEFAULT_BOUND) else null;
                const job_req = try fs.previewSubmit(path, p.codecs, p.bound);
                const meta = try fs.mediaMetaSubmit(dirname, &names);
                const quick: ?u64 = if (quick_req) |r| try fs.awaitJob(r) else null;
                const job = try fs.awaitJob(job_req);
                lap("job starts (one round trip)", &t);
                if (quick) |q| {
                    const quick_bytes = try sidecarOver(&fs, q, false, true, &t);
                    defer allocator.free(quick_bytes);
                    first_ms = @as(f64, @floatFromInt(clock.nowNs() - load0)) / 1e6;
                    std.debug.print("    quick preview {d} B shown at {d:.1} ms\n", .{ quick_bytes.len, first_ms.? });
                }
                bytes = try sidecarOver(&fs, job, false, true, &t);
                try pipedMeta(&fs, meta, &t);
            } else {
                // The viewer's order: both jobs at once, quick one shown first.
                const quick: ?u64 = if (p.quick_first) try fs.startPreviewSized(path, p.codecs, imagepolicy.DEFAULT_BOUND) else null;
                const job = try fs.startPreviewSized(path, p.codecs, p.bound);
                if (quick) |q| {
                    const quick_bytes = try sidecarOver(&fs, q, false, false, &t);
                    defer allocator.free(quick_bytes);
                    first_ms = @as(f64, @floatFromInt(clock.nowNs() - load0)) / 1e6;
                    std.debug.print("    quick preview {d} B shown at {d:.1} ms\n", .{ quick_bytes.len, first_ms.? });
                }
                bytes = try sidecarOver(&fs, job, false, false, &t);
            },
        }
    }
    defer allocator.free(bytes);
    if (!piped) {
        const dirname = std.fs.path.dirname(path) orelse "/";
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = fs.mediaMeta(arena.allocator(), dirname, &.{std.fs.path.basename(path)}, 15_000) catch {};
        lap("media metadata", &t);
    }
    const link_ms = @as(f64, @floatFromInt(clock.nowNs() - load0)) / 1e6;
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const px = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &ch, 4);
    if (px != null) c.stbi_image_free(px);
    lap("client decode (stb)", &t);
    std.debug.print("  {s}: {s} {d}x{d}, {d} B; first image {d:.1} ms, final over link {d:.1} ms, total {d:.1} ms\n", .{
        mode,                      what, w, h, bytes.len,
        first_ms orelse link_ms,   link_ms,
        @as(f64, @floatFromInt(clock.nowNs() - total0)) / 1e6,
    });
}

fn pipedMeta(fs: *fsdrive.Fs, req: u32, t: *u64) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    _ = fs.mediaMetaResults(arena.allocator(), try fs.awaitJob(req), 15_000) catch {};
    lap("media metadata (submitted early)", t);
}

fn previewOver(fs: *fsdrive.Fs, path: []const u8, codecs: []const u8, bound: u32, probed: bool, t: *u64) ![]u8 {
    const job = if (bound == 0) try fs.startPreviewCodecs(path, codecs) else try fs.startPreviewSized(path, codecs, bound);
    return sidecarOver(fs, job, probed, false, t);
}

fn sidecarOver(fs: *fsdrive.Fs, job: u64, probed: bool, unawaited: bool, t: *u64) ![]u8 {
    var event = try fs.waitJobTerminal(job, 120_000);
    defer event.deinit();
    if (!std.mem.eql(u8, event.ev, "done") or event.path.len == 0) return error.PreviewFailed;
    lap(if (event.keep) "preview job (host, cached)" else "preview job (host)", t);
    const bytes = try readAll(fs, event.path, 2 << 20, probed);
    lap("read preview", t);
    if (!event.keep) {
        if (unawaited) fs.unlinkNoWait(event.path) catch {} else fs.unlink(event.path) catch {};
    }
    lap("unlink sidecar", t);
    return bytes;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;
    const argv = init.args.vector;
    if (argv.len >= 5 and std.mem.eql(u8, std.mem.span(argv[1]), "--e2e")) {
        // Every daemon this load autostarts (through a fake ssh) retires with us.
        _ = lifetime.arm();
        const bound: u32 = if (argv.len > 5) try std.fmt.parseInt(u32, std.mem.span(argv[5]), 10) else 2048;
        return e2e(std.mem.span(argv[2]), std.mem.span(argv[3]), std.mem.span(argv[4]), bound);
    }
    if (argv.len < 2) {
        std.debug.print("usage: bench-preview <image>... | --e2e <host-spec> <remote path> old|new|piped [display bound]\n", .{});
        return;
    }
    std.debug.print("codecs loaded: \"{s}\"\n", .{imagecodec.capabilities()});
    for (argv[1..]) |arg| benchFile(allocator, std.mem.span(arg));
}
