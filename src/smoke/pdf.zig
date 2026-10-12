//! Just enough PDF to judge what the browser helper printed, for the
//! smoke rigs (smoke-web's print stages, smoke-mcp's web_print_pdf): page
//! count, each page's MediaBox, whether a page's content shows text, and
//! whether a font program is embedded. Not a PDF reader: it assumes plain
//! (non object-stream) page objects, which is what the engine's writer
//! emits, and reports a file that does not parse that way as unparsed.
//! Libc only, so both dependency sets can import it.

const std = @import("std");
const c = @import("../c.zig").c;

/// Three 16:9 slides of 1920x1080 CSS px, separated by page breaks, under
/// the given `@page` rule, as a `data:` url.
pub fn deckHtml(comptime page_rule: []const u8) []const u8 {
    return "data:text/html,<html><head><title>Deck</title><style>" ++
        "@page{" ++ page_rule ++ "}html,body{margin:0;padding:0}" ++
        "section{width:1920px;height:1080px;overflow:hidden;break-after:page;font:120px sans-serif}" ++
        "section:last-child{break-after:auto}</style></head><body>" ++
        "<section>Slide One Alpha</section><section>Slide Two Bravo</section>" ++
        "<section>Slide Three Charlie</section></body></html>";
}

/// The deck that declares its own borderless sheet: printed with the CSS
/// page size, each section is one 1440x810pt page.
pub const deck_page = deckHtml("size:1920px 1080px;margin:0");

/// One page: its MediaBox size in points and whether its content stream
/// shows text (BT .. Tj/TJ .. ET) rather than only painting images.
pub const Page = struct { w: f64 = 0, h: f64 = 0, text: bool = false };

pub const Shape = struct {
    pages: [16]Page = @splat(.{}),
    count: usize = 0,
    /// Some font program is embedded (`/FontFile`, `/FontFile2`, `/FontFile3`).
    embedded_font: bool = false,

    pub fn slice(self: *const Shape) []const Page {
        return self.pages[0..self.count];
    }
};

pub const ReadError = error{ Missing, ShortRead, NotPdf, Unparsed, OutOfMemory };

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\n' or b == '\r' or b == '\t' or b == 0x0c or b == 0;
}

/// The `/MediaBox [x0 y0 x1 y1]` of one page object, as width and height.
fn mediaBox(obj: []const u8) ?[2]f64 {
    const at = std.mem.indexOf(u8, obj, "/MediaBox") orelse return null;
    const open = std.mem.indexOfScalarPos(u8, obj, at, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, obj, open, ']') orelse return null;
    var nums: [4]f64 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, obj[open + 1 .. close], " \r\n\t");
    while (it.next()) |tok| {
        if (n == 4) return null;
        nums[n] = std.fmt.parseFloat(f64, tok) catch return null;
        n += 1;
    }
    if (n != 4) return null;
    return .{ nums[2] - nums[0], nums[3] - nums[1] };
}

/// The body of indirect object `num`, from its `obj` keyword to `endobj`.
fn object(pdf: []const u8, num: u32) ?[]const u8 {
    var key_buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d} 0 obj", .{num}) catch return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, pdf, from, key)) |at| {
        from = at + key.len;
        // "12 0 obj" must not match inside "112 0 obj".
        if (at > 0 and !isSpace(pdf[at - 1])) continue;
        const end = std.mem.indexOfPos(u8, pdf, from, "endobj") orelse return null;
        return pdf[from..end];
    }
    return null;
}

/// Whether the content stream inside object `obj` shows text. A stream
/// that does not inflate counts as no text, never as a parse error.
fn streamShowsText(obj: []const u8) bool {
    const kw = std.mem.indexOf(u8, obj, "stream") orelse return false;
    var start = kw + "stream".len;
    if (start < obj.len and obj[start] == '\r') start += 1;
    if (start < obj.len and obj[start] == '\n') start += 1;
    const end = std.mem.lastIndexOf(u8, obj, "endstream") orelse return false;
    if (end < start) return false;
    const raw = obj[start..end];
    var plain: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer plain.deinit();
    const body: []const u8 = if (std.mem.indexOf(u8, obj[0..kw], "/FlateDecode") != null) blk: {
        var in: std.Io.Reader = .fixed(raw);
        var inflate: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
        _ = inflate.reader.streamRemaining(&plain.writer) catch return false;
        break :blk plain.written();
    } else raw;
    const bt = std.mem.indexOf(u8, body, "BT") orelse return false;
    const shows = std.mem.indexOfPos(u8, body, bt, "Tj") != null or std.mem.indexOfPos(u8, body, bt, "TJ") != null;
    return shows and std.mem.indexOfPos(u8, body, bt, "ET") != null;
}

/// Every `/Type /Page` object in file order, with its MediaBox and whether
/// its `/Contents` stream(s) show text; null when the file does not parse
/// as plain page objects, so a writer change fails a rig loudly.
pub fn parse(pdf: []const u8) ?Shape {
    var shape: Shape = .{};
    shape.embedded_font = std.mem.indexOf(u8, pdf, "/FontFile") != null;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, pdf, at, "/Type")) |i| {
        at = i + "/Type".len;
        var j = at;
        while (j < pdf.len and isSpace(pdf[j])) j += 1;
        if (!std.mem.startsWith(u8, pdf[j..], "/Page")) continue;
        const after = j + "/Page".len;
        if (after < pdf.len and std.ascii.isAlphanumeric(pdf[after])) continue; // `/Pages`
        if (shape.count == shape.pages.len) return null;
        const obj_start = std.mem.lastIndexOf(u8, pdf[0..i], " obj") orelse return null;
        const obj_end = std.mem.indexOfPos(u8, pdf, i, "endobj") orelse return null;
        const obj = pdf[obj_start..obj_end];
        const box = mediaBox(obj) orelse return null;
        var page: Page = .{ .w = box[0], .h = box[1] };
        // `/Contents N 0 R` or `/Contents [N 0 R M 0 R]`.
        const ci = std.mem.indexOf(u8, obj, "/Contents") orelse return null;
        const rest = std.mem.trimStart(u8, obj[ci + "/Contents".len ..], " \r\n\t");
        const is_array = rest.len > 0 and rest[0] == '[';
        const list = if (is_array) rest[1 .. std.mem.indexOfScalar(u8, rest, ']') orelse return null] else rest;
        var refs = std.mem.tokenizeAny(u8, list, " \r\n\t");
        while (refs.next()) |tok| {
            const num = std.fmt.parseInt(u32, tok, 10) catch break;
            _ = refs.next() orelse break; // generation
            const r = refs.next() orelse break;
            if (!std.mem.startsWith(u8, r, "R")) break;
            const content = object(pdf, num) orelse return null;
            if (streamShowsText(content)) page.text = true;
            if (!is_array) break;
        }
        shape.pages[shape.count] = page;
        shape.count += 1;
    }
    return shape;
}

/// Read the PDF at `path` and parse its shape.
pub fn read(path: [*:0]const u8) ReadError!Shape {
    const f = c.fopen(path, "rb") orelse return error.Missing;
    defer _ = c.fclose(f);
    _ = c.fseek(f, 0, c.SEEK_END);
    const size: usize = @intCast(@max(c.ftell(f), 0));
    _ = c.fseek(f, 0, c.SEEK_SET);
    const buf = try std.heap.page_allocator.alloc(u8, size);
    defer std.heap.page_allocator.free(buf);
    if (c.fread(buf.ptr, 1, size, f) != size) return error.ShortRead;
    if (!std.mem.startsWith(u8, buf, "%PDF-")) return error.NotPdf;
    return parse(buf) orelse error.Unparsed;
}

/// What is wrong with a printed `deck_page` (CSS page size, no margins):
/// null when it is three 1440x810pt pages (1920x1080 CSS px at 72/96,
/// within 1pt) whose text is still text, with an embedded font.
pub fn deckProblem(shape: *const Shape) ?[]const u8 {
    if (shape.count != 3) return "the deck did not print as exactly 3 pages";
    for (shape.slice()) |p| {
        if (@abs(p.w - 1440) > 1 or @abs(p.h - 810) > 1) return "a page's MediaBox is not 1440 x 810 pt";
        if (!p.text) return "a page's text was not printed as text";
    }
    if (!shape.embedded_font) return "the PDF embeds no font program";
    return null;
}
