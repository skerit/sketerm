//! Per-type preview handlers: the built-in table plus the user's
//! rules, resolved by ONE lookup so images, documents, text and the
//! hex fallback all leave `resolve` through the same door.
//!
//! Config: $XDG_CONFIG_HOME/sketerm/previewers.conf, one rule per
//! line, in the emblems.conf spirit (`match = value`, `#` comments):
//!
//!   *.md              = text:head
//!   mime:image/*      = image:thumbnail
//!   *.zip             = text:host bsdtar -tf %f
//!   *.dot             = image:host dot -Tpng %f -o %o
//!
//! The value is `<output>:<producer>`. Output is `text` or `image`.
//! Producers are the built-ins (`thumbnail`, `head`, `hex`,
//! `metadata`, `cast`) or `host <command>`, which runs on the FILE's host as
//! a daemon job -- so a remote file is previewed where it lives and
//! only the result crosses the wire. A `text:host` command's STDOUT
//! is the preview; an `image:host` command must write its image to
//! `%o` (and is rejected at parse time if it never mentions it).
//!
//! First match wins, user rules before built-ins, so an earlier line
//! is the more specific one.

const std = @import("std");
const c = @import("../c.zig").c;
const cast_play = @import("../mux/cast_play.zig");
const desktop = @import("desktop.zig");
const globMatch = @import("../util/glob.zig").matchName;
const paths = @import("paths.zig");
const pathz = @import("../util/pathz.zig");
const profile = @import("../util/profile.zig");

pub const Output = enum { text, image };

/// Producers the browser implements itself, over verbs the daemon
/// already has (no per-handler daemon support).
pub const Builtin = enum {
    /// The daemon's `preview` job: a cached x-large thumbnail plus
    /// whatever metadata its generator reports.
    thumbnail,
    /// A bounded ranged read of the head of the file, shown as text
    /// when it reads as text and as a hex dump when it does not.
    head,
    /// The same ranged read, always as a hex dump.
    hex,
    /// No content fetch at all (directories).
    metadata,
    /// The same ranged read, rendered as asciicast header metadata
    /// (`renderCastMeta`) instead of the raw JSON.
    cast,
};

pub const Producer = union(enum) {
    builtin: Builtin,
    /// Shell command run on the file's host; `%f`/`%o` substituted.
    host_command: []const u8,
};

pub const Handler = struct {
    output: Output,
    producer: Producer,

    pub fn isHost(self: Handler) bool {
        return self.producer == .host_command;
    }
};

pub const Rule = struct {
    /// Name glob (empty for MIME rules).
    glob: []const u8 = "",
    /// MIME glob, e.g. "image/*" (empty for name rules).
    mime: []const u8 = "",
    handler: Handler,
};

pub const Rules = struct {
    arena: std.heap.ArenaAllocator,
    list: []const Rule = &.{},

    pub fn deinit(self: *Rules) void {
        self.arena.deinit();
    }
};

/// The handler for one entry. `mime` may be empty when the caller
/// could not guess one; MIME rules then simply do not match.
pub fn resolve(user: []const Rule, name: []const u8, mime: []const u8, is_dir: bool) Handler {
    if (is_dir) return .{ .output = .text, .producer = .{ .builtin = .metadata } };
    for (user) |rule| {
        if (matches(rule, name, mime)) return rule.handler;
    }
    return builtinFor(name);
}

fn matches(rule: Rule, name: []const u8, mime: []const u8) bool {
    if (rule.mime.len > 0) return mime.len > 0 and globMatch(rule.mime, mime);
    return rule.glob.len > 0 and globMatch(rule.glob, name);
}

/// The built-in tail of the chain, keyed on `paths.classify` (the
/// same oracle behind row thumbnails and the viewer's dispatch, so
/// the three cannot drift). Media goes to the daemon's generator, a
/// cast renders its header metadata, and everything else takes the
/// bounded head read — which is also what makes the hex view a
/// fallback for any type nobody wrote a handler for.
fn builtinFor(name: []const u8) Handler {
    return switch (paths.classify(name)) {
        .media => .{ .output = .image, .producer = .{ .builtin = .thumbnail } },
        .cast => .{ .output = .text, .producer = .{ .builtin = .cast } },
        .text => .{ .output = .text, .producer = .{ .builtin = .head } },
    };
}

pub fn configPath(buf: []u8) ?[]const u8 {
    if (profile.getenv("XDG_CONFIG_HOME")) |xc|
        return std.fmt.bufPrint(buf, "{s}/sketerm/previewers.conf", .{xc}) catch null;
    if (profile.getenv("HOME")) |home|
        return std.fmt.bufPrint(buf, "{s}/.config/sketerm/previewers.conf", .{home}) catch null;
    return null;
}

/// Load the user rules; an absent or unreadable file means "built-ins
/// only", never an error the browser has to handle.
pub fn load(allocator: std.mem.Allocator) Rules {
    var rules = Rules{ .arena = std.heap.ArenaAllocator.init(allocator) };
    var path_buf: [4096]u8 = undefined;
    const path = configPath(&path_buf) orelse return rules;
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return rules;
    const fp = c.fopen(pz, "rb") orelse return rules;
    defer _ = c.fclose(fp);
    var bytes: [64 * 1024]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, fp);
    if (n == 0) return rules;
    rules.list = parse(rules.arena.allocator(), bytes[0..n]) catch &.{};
    return rules;
}

/// Parse the rules file. A malformed line is skipped, never fatal:
/// one typo must not disable every other handler.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ![]const Rule {
    var out: std.ArrayList(Rule) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // FIRST '=': a host command's arguments may contain more.
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const left = std.mem.trim(u8, line[0..eq], " \t");
        const right = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (left.len == 0 or right.len == 0) continue;
        const handler = parseHandler(arena, right) catch continue orelse continue;
        if (std.mem.startsWith(u8, left, "mime:")) {
            const mime = std.mem.trim(u8, left["mime:".len..], " \t");
            if (mime.len == 0) continue;
            try out.append(arena, .{ .mime = try arena.dupe(u8, mime), .handler = handler });
        } else {
            try out.append(arena, .{ .glob = try arena.dupe(u8, left), .handler = handler });
        }
    }
    return out.items;
}

/// `<output>:<producer>`; null for anything this version does not
/// understand (an unknown output, an unknown producer name, a host
/// rule with no command, or a producer the output cannot carry).
fn parseHandler(arena: std.mem.Allocator, spec: []const u8) !?Handler {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    const output: Output = if (std.mem.eql(u8, spec[0..colon], "text"))
        .text
    else if (std.mem.eql(u8, spec[0..colon], "image"))
        .image
    else
        return null;
    const rest = std.mem.trim(u8, spec[colon + 1 ..], " \t");
    if (rest.len == 0) return null;
    const word_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const word = rest[0..word_end];
    if (std.mem.eql(u8, word, "host")) {
        const cmd = std.mem.trim(u8, rest[word_end..], " \t");
        if (cmd.len == 0) return null;
        // An image command that never names its output file cannot
        // produce one; refusing here beats a handler that silently
        // yields nothing at every use.
        if (output == .image and std.mem.indexOf(u8, cmd, "%o") == null) return null;
        return .{ .output = output, .producer = .{ .host_command = try arena.dupe(u8, cmd) } };
    }
    const builtin = std.meta.stringToEnum(Builtin, word) orelse return null;
    const wants: Output = switch (builtin) {
        .thumbnail => .image,
        .head, .hex, .metadata, .cast => .text,
    };
    if (wants != output) return null;
    return .{ .output = output, .producer = .{ .builtin = builtin } };
}

/// Substitute a user command's field codes: `%f` is the file, `%o`
/// the output path, both single-quoted; `%%` is a literal percent and
/// any other code is dropped, as in a .desktop Exec line. A command
/// that never mentions `%f` gets the file appended.
pub fn substitute(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    file: []const u8,
    out_path: []const u8,
) ?[]u8 {
    return substituteAlloc(allocator, cmd, file, out_path) catch null;
}

/// The builder proper. Error-returning so its `errdefer` actually runs;
/// as a `?[]u8` body each `catch return null` leaked the partial buffer.
fn substituteAlloc(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    file: []const u8,
    out_path: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var saw_file = false;
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] != '%' or i + 1 >= cmd.len) {
            try out.append(allocator, cmd[i]);
            continue;
        }
        i += 1;
        switch (cmd[i]) {
            'f' => {
                try desktop.appendQuoted(&out, allocator, file);
                saw_file = true;
            },
            'o' => try desktop.appendQuoted(&out, allocator, out_path),
            '%' => try out.append(allocator, '%'),
            else => {},
        }
    }
    if (!saw_file) {
        try out.append(allocator, ' ');
        try desktop.appendQuoted(&out, allocator, file);
    }
    return out.toOwnedSlice(allocator);
}

/// The shell line the host-command job runs: the substituted command
/// with its result landing in `out_path`, then that path printed so
/// the job reports it back and the browser knows what to read.
///
/// A text handler's stdout (and stderr, so a failure is visible
/// instead of blank) is redirected; an image handler writes `%o`
/// itself. The path is printed unconditionally: a command that
/// produced nothing simply leaves no file for the job to report.
pub fn hostScript(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    file: []const u8,
    out_path: []const u8,
    output: Output,
) ?[]u8 {
    const body = substitute(allocator, cmd, file, out_path) orelse return null;
    defer allocator.free(body);
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(allocator);
    desktop.appendQuoted(&quoted, allocator, out_path) catch return null;
    return switch (output) {
        .text => std.fmt.allocPrint(allocator, "{{ {s} ; }} > {s} 2>&1; printf '%s\\n' {s}", .{
            body, quoted.items, quoted.items,
        }) catch null,
        .image => std.fmt.allocPrint(allocator, "{s} >/dev/null 2>&1; printf '%s\\n' {s}", .{
            body, quoted.items,
        }) catch null,
    };
}

/// Append an untrusted header string with control bytes flattened to
/// spaces; an invalid-UTF-8 value is dropped whole rather than handed
/// to a GTK label.
fn appendSanitized(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, value: []const u8) ?void {
    if (!std.unicode.utf8ValidateSlice(value)) return;
    out.appendSlice(allocator, label) catch return null;
    for (value) |ch|
        out.append(allocator, if (ch < 0x20) ' ' else ch) catch return null;
}

/// Render the head bytes of an asciicast file as readable metadata:
/// version, terminal size, then whatever else the header carries.
/// @return null when the first line does not parse as an asciicast
/// header (or on allocation failure), so the caller falls back to the
/// plain text renderer.
pub fn renderCastMeta(allocator: std.mem.Allocator, bytes: []const u8) ?[]u8 {
    const line_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const line = std.mem.trimEnd(u8, bytes[0..line_end], "\r");
    if (line.len == 0) return null;
    var header = cast_play.parseHeader(allocator, line) catch return null;
    defer cast_play.freeHeader(allocator, &header);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [128]u8 = undefined;
    out.appendSlice(allocator, std.fmt.bufPrint(&buf, "Asciicast recording (v{d})\nTerminal: {d} x {d}", .{
        header.version, header.cols, header.rows,
    }) catch return null) catch return null;
    if (header.title) |title|
        appendSanitized(&out, allocator, "\nTitle: ", title) orelse return null;
    if (header.timestamp) |ts| {
        var t: c.time_t = std.math.cast(c.time_t, ts) orelse 0;
        var tm: c.struct_tm = undefined;
        if (t != 0 and c.localtime_r(&t, &tm) != null) {
            var tbuf: [64]u8 = undefined;
            const n = c.strftime(&tbuf, tbuf.len, "%Y-%m-%d %H:%M", &tm);
            if (n > 0) {
                out.appendSlice(allocator, "\nRecorded: ") catch return null;
                out.appendSlice(allocator, tbuf[0..n]) catch return null;
            }
        }
    }
    if (header.term_type) |tt|
        appendSanitized(&out, allocator, "\nTerm type: ", tt) orelse return null;
    if (header.idle_time_limit_ms) |ms|
        out.appendSlice(allocator, std.fmt.bufPrint(&buf, "\nIdle limit: {d}s", .{
            @as(f64, @floatFromInt(ms)) / 1000.0,
        }) catch return null) catch return null;
    if (header.theme.palette != null or header.theme.fg != null or header.theme.bg != null)
        out.appendSlice(allocator, "\nTheme: recorded") catch return null;
    return allocator.dupe(u8, out.items) catch null;
}

test "resolve falls back to the head read and routes media to the generator" {
    const t = std.testing;
    const none: []const Rule = &.{};
    const bin = resolve(none, "a.out", "", false);
    try t.expectEqual(Output.text, bin.output);
    try t.expectEqual(Builtin.head, bin.producer.builtin);
    const img = resolve(none, "photo.JPG", "", false);
    try t.expectEqual(Output.image, img.output);
    try t.expectEqual(Builtin.thumbnail, img.producer.builtin);
    const pdf = resolve(none, "manual.pdf", "", false);
    try t.expectEqual(Builtin.thumbnail, pdf.producer.builtin);
    // A directory never fetches content.
    const dir = resolve(none, "src", "inode/directory", true);
    try t.expectEqual(Builtin.metadata, dir.producer.builtin);
    // A cast is neither a thumbnail nor raw JSON: it gets the header
    // metadata renderer over the same head read.
    const cast = resolve(none, "session.cast", "", false);
    try t.expectEqual(Output.text, cast.output);
    try t.expectEqual(Builtin.cast, cast.producer.builtin);
}

test "user rules may name the cast producer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rules = try parse(arena.allocator(), "*.rec = text:cast\n*.bad = image:cast\n");
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(Builtin.cast, rules[0].handler.producer.builtin);
}

test "renderCastMeta reads v2 and v3 headers and refuses non-casts" {
    const t = std.testing;
    const a = t.allocator;
    const v2 = renderCastMeta(a,
        \\{"version": 2, "width": 80, "height": 24, "title": "demo", "idle_time_limit": 2}
        \\[0.1, "o", "hi"]
        \\
    ).?;
    defer a.free(v2);
    try t.expectEqualStrings("Asciicast recording (v2)\nTerminal: 80 x 24\nTitle: demo\nIdle limit: 2s", v2);
    const v3 = renderCastMeta(a,
        \\{"version": 3, "term": {"cols": 100, "rows": 30, "type": "xterm-256color", "theme": {"fg": "#ffffff"}}}
        \\
    ).?;
    defer a.free(v3);
    try t.expectEqualStrings("Asciicast recording (v3)\nTerminal: 100 x 30\nTerm type: xterm-256color\nTheme: recorded", v3);
    // A recorded timestamp renders as a labelled local date.
    const stamped = renderCastMeta(a,
        \\{"version": 2, "width": 10, "height": 5, "timestamp": 1700000000}
        \\
    ).?;
    defer a.free(stamped);
    try t.expect(std.mem.indexOf(u8, stamped, "\nRecorded: 20") != null);
    // Control bytes in an untrusted title are flattened, never shown.
    const hostile = renderCastMeta(a,
        "{\"version\": 2, \"width\": 4, \"height\": 2, \"title\": \"a\\u001bb\"}\n",
    ).?;
    defer a.free(hostile);
    try t.expectEqualStrings("Asciicast recording (v2)\nTerminal: 4 x 2\nTitle: a b", hostile);
    // Anything that is not an asciicast header falls back to the
    // plain text renderer via null.
    try t.expect(renderCastMeta(a, "not json at all\n") == null);
    try t.expect(renderCastMeta(a, "{\"version\": 9}\n") == null);
    try t.expect(renderCastMeta(a, "") == null);
    try t.expect(renderCastMeta(a, "\n") == null);
}

test "parse reads globs, MIME rules and host commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = std.testing;
    const rules = try parse(arena.allocator(),
        \\# a comment
        \\*.md          = text:head
        \\mime:image/*  = image:thumbnail
        \\*.zip         = text:host bsdtar -tf %f
        \\*.dot         = image:host dot -Tpng %f -o %o
        \\
    );
    try t.expectEqual(@as(usize, 4), rules.len);
    try t.expectEqualStrings("*.md", rules[0].glob);
    try t.expectEqual(Builtin.head, rules[0].handler.producer.builtin);
    try t.expectEqualStrings("image/*", rules[1].mime);
    try t.expectEqualStrings("", rules[1].glob);
    try t.expectEqualStrings("bsdtar -tf %f", rules[2].handler.producer.host_command);
    try t.expectEqual(Output.text, rules[2].handler.output);
    try t.expectEqual(Output.image, rules[3].handler.output);
}

test "parse skips malformed lines, unknown keys and impossible combinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = std.testing;
    const rules = try parse(arena.allocator(),
        \\no equals sign here
        \\= text:head
        \\*.a =
        \\*.b = sound:head
        \\*.c = text:telepathy
        \\*.d = image:head
        \\*.e = text:thumbnail
        \\*.f = text:host
        \\*.g = image:host convert %f
        \\mime: = text:head
        \\*.ok = text:head
        \\
    );
    // Only the last line survives.
    try t.expectEqual(@as(usize, 1), rules.len);
    try t.expectEqualStrings("*.ok", rules[0].glob);
}

test "user rules win over built-ins and the first match wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = std.testing;
    const rules = try parse(arena.allocator(),
        \\*.png = text:hex
        \\* = text:head
        \\mime:image/* = image:thumbnail
        \\
    );
    // A user rule overrides the built-in image handler...
    const png = resolve(rules, "a.png", "image/png", false);
    try t.expectEqual(Builtin.hex, png.producer.builtin);
    // ...and the earlier catch-all shadows the later MIME rule.
    const jpg = resolve(rules, "a.jpg", "image/jpeg", false);
    try t.expectEqual(Builtin.head, jpg.producer.builtin);
    // A MIME rule needs a MIME: without one it cannot match.
    const only_mime = try parse(arena.allocator(), "mime:text/x-zig = text:hex\n");
    try t.expectEqual(Builtin.hex, resolve(only_mime, "x", "text/x-zig", false).producer.builtin);
    try t.expectEqual(Builtin.head, resolve(only_mime, "x", "", false).producer.builtin);
}

test "a value may contain further equals signs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = std.testing;
    const rules = try parse(arena.allocator(), "*.env = text:host grep -e KEY=1 %f\n");
    try t.expectEqual(@as(usize, 1), rules.len);
    try t.expectEqualStrings("grep -e KEY=1 %f", rules[0].handler.producer.host_command);
}

test "substitute quotes both field codes and appends a missing file" {
    const t = std.testing;
    const a = t.allocator;
    const one = substitute(a, "dot -Tpng %f -o %o", "/tmp/a b.dot", "/tmp/o.png").?;
    defer a.free(one);
    try t.expectEqualStrings("dot -Tpng '/tmp/a b.dot' -o '/tmp/o.png'", one);
    const two = substitute(a, "file", "/tmp/x'y", "/tmp/o").?;
    defer a.free(two);
    try t.expectEqualStrings("file '/tmp/x'\\''y'", two);
    const three = substitute(a, "echo 100%% %f", "/f", "/o").?;
    defer a.free(three);
    try t.expectEqualStrings("echo 100% '/f'", three);
}

test "hostScript redirects text output and only announces image output" {
    const t = std.testing;
    const a = t.allocator;
    const text = hostScript(a, "bsdtar -tf %f", "/tmp/a.zip", "/tmp/o.txt", .text).?;
    defer a.free(text);
    try t.expectEqualStrings(
        "{ bsdtar -tf '/tmp/a.zip' ; } > '/tmp/o.txt' 2>&1; printf '%s\\n' '/tmp/o.txt'",
        text,
    );
    const image = hostScript(a, "dot -Tpng %f -o %o", "/tmp/a.dot", "/tmp/o.png", .image).?;
    defer a.free(image);
    try t.expectEqualStrings(
        "dot -Tpng '/tmp/a.dot' -o '/tmp/o.png' >/dev/null 2>&1; printf '%s\\n' '/tmp/o.png'",
        image,
    );
}
