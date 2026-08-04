//! OCR for app screenshots: libtesseract probed at runtime with
//! dlopen (the opuscodec.zig pattern), so text extraction works
//! wherever tesseract is installed without adding an ELF dependency.
//! Missing library or language data degrades to a described error,
//! never a build-time requirement.
//!
//! Gotcha: one TessBaseAPI is cached per process and re-inited only
//! when the language changes — Init3 reloads traineddata (~100 ms),
//! recognition itself is the cheap part.

const std = @import("std");

pub const Error = error{ Unavailable, InitFailed, RecognizeFailed, OutOfMemory };

pub const Word = struct {
    /// Allocated with the recognize() allocator.
    text: []u8,
    /// Box in the coordinate space of the image handed to recognize().
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// Tesseract confidence 0..100.
    conf: f64,
};

pub const Result = struct {
    /// Full recognized text (tesseract's UTF-8 output, trailing
    /// whitespace trimmed). Allocated with the recognize() allocator.
    text: []u8,
    words: []Word,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.words) |w| allocator.free(w.text);
        allocator.free(self.words);
    }
};

pub const Options = struct {
    /// Tesseract language code(s), e.g. "eng" or "eng+deu".
    lang: []const u8 = "eng",
    /// Page segmentation mode: 6 = uniform text block (dialogs),
    /// 11 = sparse text (scattered UI labels), 3 = full auto.
    psm: i32 = 6,
    /// Source resolution hint; upscaled game pixels are fine at 96.
    ppi: i32 = 96,
};

const Create = *const fn () callconv(.c) ?*anyopaque;
const Delete = *const fn (?*anyopaque) callconv(.c) void;
const Init3 = *const fn (?*anyopaque, ?[*:0]const u8, [*:0]const u8) callconv(.c) c_int;
const End = *const fn (?*anyopaque) callconv(.c) void;
const SetImage = *const fn (?*anyopaque, [*]const u8, c_int, c_int, c_int, c_int) callconv(.c) void;
const SetSourceResolution = *const fn (?*anyopaque, c_int) callconv(.c) void;
const SetPageSegMode = *const fn (?*anyopaque, c_int) callconv(.c) void;
const GetUTF8Text = *const fn (?*anyopaque) callconv(.c) ?[*:0]u8;
const GetTsvText = *const fn (?*anyopaque, c_int) callconv(.c) ?[*:0]u8;
const DeleteText = *const fn (?[*:0]u8) callconv(.c) void;

const Api = struct {
    create: Create,
    delete: Delete,
    init3: Init3,
    end: End,
    set_image: SetImage,
    set_resolution: SetSourceResolution,
    set_psm: SetPageSegMode,
    get_text: GetUTF8Text,
    get_tsv: GetTsvText,
    delete_text: DeleteText,
};

extern fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;

const RTLD_LAZY: c_int = 0x1;
var load_attempted = false;
var loaded_api: ?Api = null;

/// Live TessBaseAPI handle + the language it was inited for.
var tess: ?*anyopaque = null;
var tess_lang_buf: [64]u8 = undefined;
var tess_lang_len: usize = 0;

fn sym(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
    return @ptrCast(@alignCast(dlsym(handle, name) orelse return null));
}

fn loadApi() ?Api {
    const names = [_][*:0]const u8{
        "libtesseract.so.5",
        "libtesseract.so.4",
        "libtesseract.so",
        "libtesseract.5.dylib",
        "libtesseract.dylib",
    };
    const handle: ?*anyopaque = @import("platform.zig").dlopenAny(&names);
    const h = handle orelse return null;
    const api = Api{
        .create = sym(Create, h, "TessBaseAPICreate") orelse return bail(h),
        .delete = sym(Delete, h, "TessBaseAPIDelete") orelse return bail(h),
        .init3 = sym(Init3, h, "TessBaseAPIInit3") orelse return bail(h),
        .end = sym(End, h, "TessBaseAPIEnd") orelse return bail(h),
        .set_image = sym(SetImage, h, "TessBaseAPISetImage") orelse return bail(h),
        .set_resolution = sym(SetSourceResolution, h, "TessBaseAPISetSourceResolution") orelse return bail(h),
        .set_psm = sym(SetPageSegMode, h, "TessBaseAPISetPageSegMode") orelse return bail(h),
        .get_text = sym(GetUTF8Text, h, "TessBaseAPIGetUTF8Text") orelse return bail(h),
        .get_tsv = sym(GetTsvText, h, "TessBaseAPIGetTsvText") orelse return bail(h),
        .delete_text = sym(DeleteText, h, "TessDeleteText") orelse return bail(h),
    };
    return api;
}

fn bail(h: *anyopaque) ?Api {
    _ = dlclose(h);
    return null;
}

fn getApi() ?*const Api {
    if (!load_attempted) {
        load_attempted = true;
        loaded_api = loadApi();
    }
    return if (loaded_api) |*api| api else null;
}

/// Whether tesseract can be loaded on this machine (says nothing
/// about language data — Init may still fail without traineddata).
pub fn available() bool {
    return getApi() != null;
}

/// Cached-handle init: reuses the live TessBaseAPI when the language
/// matches, else re-inits (traineddata reload).
fn ensureInit(api: *const Api, lang: []const u8) Error!*anyopaque {
    if (lang.len == 0 or lang.len >= tess_lang_buf.len - 1) return Error.InitFailed;
    if (tess) |t| {
        if (std.mem.eql(u8, tess_lang_buf[0..tess_lang_len], lang)) return t;
        api.end(t);
        api.delete(t);
        tess = null;
    }
    const t = api.create() orelse return Error.InitFailed;
    var lang_z: [64]u8 = undefined;
    @memcpy(lang_z[0..lang.len], lang);
    lang_z[lang.len] = 0;
    if (api.init3(t, null, lang_z[0..lang.len :0]) != 0) {
        api.delete(t);
        return Error.InitFailed;
    }
    @memcpy(tess_lang_buf[0..lang.len], lang);
    tess_lang_len = lang.len;
    tess = t;
    return t;
}

/// One row of tesseract's TSV output (level 5 = word).
/// Columns: level page block par line word left top width height conf text.
pub const TsvWord = struct {
    left: u32,
    top: u32,
    width: u32,
    height: u32,
    conf: f64,
    text: []const u8,
};

/// Parse level-5 rows out of TSV text; `cb` receives each word.
/// Split out from recognize() so the parsing is testable without the
/// library. Malformed rows are skipped.
pub fn parseTsv(tsv: []const u8, ctx: anytype, cb: fn (@TypeOf(ctx), TsvWord) void) void {
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const level = cols.next() orelse continue;
        if (!std.mem.eql(u8, level, "5")) continue;
        var skip: usize = 0;
        while (skip < 5) : (skip += 1) _ = cols.next() orelse continue;
        const left = std.fmt.parseInt(u32, cols.next() orelse continue, 10) catch continue;
        const top = std.fmt.parseInt(u32, cols.next() orelse continue, 10) catch continue;
        const width = std.fmt.parseInt(u32, cols.next() orelse continue, 10) catch continue;
        const height = std.fmt.parseInt(u32, cols.next() orelse continue, 10) catch continue;
        const conf = std.fmt.parseFloat(f64, cols.next() orelse continue) catch continue;
        const text = std.mem.trimEnd(u8, cols.rest(), "\r");
        if (text.len == 0 or conf < 0) continue; // conf -1 = non-text row
        cb(ctx, .{ .left = left, .top = top, .width = width, .height = height, .conf = conf, .text = text });
    }
}

/// Recognize text in a tightly-packed RGBA image. Word boxes are in
/// the image's own pixel space (the caller undoes any upscale).
pub fn recognize(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    w: u32,
    h: u32,
    opts: Options,
) Error!Result {
    if (w == 0 or h == 0 or rgba.len < @as(usize, w) * h * 4) return Error.RecognizeFailed;
    const api = getApi() orelse return Error.Unavailable;
    const t = try ensureInit(api, opts.lang);
    api.set_psm(t, opts.psm);
    api.set_image(t, rgba.ptr, @intCast(w), @intCast(h), 4, @intCast(w * 4));
    api.set_resolution(t, opts.ppi);

    const raw = api.get_text(t) orelse return Error.RecognizeFailed;
    defer api.delete_text(raw);
    const text = allocator.dupe(u8, std.mem.trimEnd(u8, std.mem.span(raw), " \t\n")) catch
        return Error.OutOfMemory;
    errdefer allocator.free(text);

    var words: std.ArrayList(Word) = .empty;
    errdefer {
        for (words.items) |word| allocator.free(word.text);
        words.deinit(allocator);
    }
    const tsv = api.get_tsv(t, 0);
    if (tsv) |tv| {
        defer api.delete_text(tv);
        const Collect = struct {
            list: *std.ArrayList(Word),
            allocator: std.mem.Allocator,
            failed: *bool,
        };
        var failed = false;
        const collect = Collect{ .list = &words, .allocator = allocator, .failed = &failed };
        parseTsv(std.mem.span(tv), collect, struct {
            fn add(cx: Collect, tw: TsvWord) void {
                if (cx.failed.*) return;
                const copy = cx.allocator.dupe(u8, tw.text) catch {
                    cx.failed.* = true;
                    return;
                };
                cx.list.append(cx.allocator, .{
                    .text = copy,
                    .x = tw.left,
                    .y = tw.top,
                    .w = tw.width,
                    .h = tw.height,
                    .conf = tw.conf,
                }) catch {
                    cx.allocator.free(copy);
                    cx.failed.* = true;
                };
            }
        }.add);
        if (failed) return Error.OutOfMemory;
    }
    return .{
        .text = text,
        .words = words.toOwnedSlice(allocator) catch return Error.OutOfMemory,
    };
}

// ─── tests ──────────────────────────────────────────────────────

test "parseTsv extracts level-5 word rows and skips the rest" {
    const tsv =
        "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n" ++
        "1\t1\t0\t0\t0\t0\t0\t0\t640\t480\t-1\t\n" ++
        "5\t1\t1\t1\t1\t1\t100\t50\t80\t20\t96.5\tHello\n" ++
        "5\t1\t1\t1\t1\t2\t190\t50\t90\t20\t91.2\tworld\n" ++
        "5\t1\t1\t1\t2\t1\t100\t80\t40\t20\t-1\t \n" ++
        "5\t1\t1\t1\t2\t2\tBAD\t80\t40\t20\t50\toops\n";
    const Ctx = struct {
        var words: [8]TsvWord = undefined;
        var texts: [8][32]u8 = undefined;
        var n: usize = 0;
        fn add(_: void, tw: TsvWord) void {
            @memcpy(texts[n][0..tw.text.len], tw.text);
            words[n] = tw;
            words[n].text = texts[n][0..tw.text.len];
            n += 1;
        }
    };
    Ctx.n = 0;
    parseTsv(tsv, {}, Ctx.add);
    try std.testing.expectEqual(@as(usize, 2), Ctx.n);
    try std.testing.expectEqualStrings("Hello", Ctx.words[0].text);
    try std.testing.expectEqual(@as(u32, 100), Ctx.words[0].left);
    try std.testing.expectEqual(@as(u32, 50), Ctx.words[0].top);
    try std.testing.expectEqualStrings("world", Ctx.words[1].text);
    try std.testing.expect(Ctx.words[1].conf > 91.0);
}

test "recognize reads synthetic rendered text (skips without tesseract)" {
    if (!available()) return error.SkipZigTest;
    const a = std.testing.allocator;
    // 200x60 white image with "HI" drawn as fat black strokes.
    const W = 200;
    const H = 60;
    const img = try a.alloc(u8, W * H * 4);
    defer a.free(img);
    @memset(img, 255);
    const bar = struct {
        fn f(px: []u8, x0: usize, y0: usize, w_: usize, h_: usize) void {
            var y = y0;
            while (y < y0 + h_) : (y += 1) {
                var x = x0;
                while (x < x0 + w_) : (x += 1) {
                    const o = (y * W + x) * 4;
                    px[o] = 0;
                    px[o + 1] = 0;
                    px[o + 2] = 0;
                }
            }
        }
    }.f;
    // H: two verticals + crossbar; I: one vertical.
    bar(img, 40, 10, 8, 40);
    bar(img, 70, 10, 8, 40);
    bar(img, 40, 26, 38, 8);
    bar(img, 100, 10, 8, 40);
    var res = recognize(a, img, W, H, .{ .psm = 7 }) catch |err| switch (err) {
        Error.InitFailed => return error.SkipZigTest, // no traineddata
        else => return err,
    };
    defer res.deinit(a);
    // Blocky strokes OCR loosely; just require an H to have been seen.
    try std.testing.expect(std.mem.indexOfScalar(u8, res.text, 'H') != null);
}
