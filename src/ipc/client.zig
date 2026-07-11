//! `sketerm cli <cmd>` — blocking remote-control client. Runs before
//! GApplication ever starts (no display needed): builds one JSON
//! request line from argv, writes it to the socket, prints the JSON
//! response line to stdout. Exit 0 iff the response says ok.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const protocol = @import("protocol.zig");

const CLI_HELP =
    \\Usage: sketerm cli [--socket PATH] <command> [options]
    \\
    \\Commands:
    \\  list                              window/tab/pane tree as JSON
    \\  send-text [opts] <text...>        write text to a pane's PTY
    \\      --pane N    target pane (default: focused)
    \\      --paste     wrap in bracketed-paste markers if enabled
    \\  type-text [opts] <text...>        like send-text, but paced as
    \\                                    human keystrokes
    \\      --pane N    target pane (default: focused)
    \\      --enter     append Enter (CR) after the text
    \\      --delay MS  base inter-key delay  (default 60)
    \\      --jitter MS random extra delay    (default 90)
    \\  send-keys [--pane N] <chords...>  press named keys: "ctrl+c",
    \\                                    "enter", "up", "f5", "alt+x",
    \\                                    "shift+tab" — space-separated
    \\  get-text [--pane N] [--scrollback N] [--last-command]
    \\                                    read screen text back (JSON);
    \\                                    --scrollback dumps the ring too;
    \\                                    --last-command returns only the
    \\                                    last command's output + exit
    \\                                    (needs shell integration)
    \\  screen-info [--pane N]            cursor pos, size, alt-screen
    \\                                    flag, activity seq (JSON)
    \\  watch [--pane N] <regex>          block until a line matches the
    \\      --timeout SEC  give up (exit 3) pattern (GRegex/PCRE), print
    \\      --interval MS  poll rate (300)  it and exit 0; scans screen
    \\                                    + 100 scrollback lines
    \\  screenshot [--pane N] --out FILE  save a PNG of the pane as shown
    \\  record-start [--pane N] --out FILE.cast
    \\                                    record the pane's session as
    \\                                    asciicast v2 (daemon-side; a
    \\                                    remote session records to a
    \\                                    REMOTE path)
    \\  record-stop [--pane N]            stop the session recording
    \\  new-tab [--cwd DIR] [--title T]   open a shell tab
    \\  split [--pane N] [--dir h|v]      split a pane (h = side by side)
    \\  focus (--pane N | --tab N)        focus a pane or select a tab
    \\  close-pane [--pane N]             close a pane
    \\  set-title [--tab N | --pane N] <title>
    \\  set-tab-color [--tab N] <#RRGGBB|none>
    \\                                    colour swatch on the tab
    \\  action [--pane N] <name>          run a bindable action by its
    \\                                    keybind.* name (zoom_pane,
    \\                                    copy_mode, show_scrollback, …)
    \\
    \\Socket resolution: --socket, then $SKETERM_SOCKET (set inside
    \\every sketerm pane), then the single *.sock under
    \\$XDG_RUNTIME_DIR/sketerm/ if exactly one instance is running.
    \\$SKETERM_PANE_ID addresses the calling pane when --pane is given
    \\as "self".
    \\
;

/// Entry point from main.zig. `args` are argv entries after "cli".
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var socket_arg: ?[]const u8 = null;
    var i: usize = 0;

    // Global flags before the command word.
    while (i < args.len and std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--socket") and i + 1 < args.len) {
            i += 1;
            socket_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "--help")) {
            _ = c.fputs(CLI_HELP, platform.stdout());
            return 0;
        } else {
            _ = c.fprintf(platform.stderr(), "sketerm cli: unknown flag before command\n");
            return 2;
        }
    }
    if (i >= args.len) {
        _ = c.fputs(CLI_HELP, platform.stdout());
        return 2;
    }
    const cmd = args[i];
    i += 1;

    var req: protocol.Request = .{ .cmd = cmd };
    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(allocator);
    var type_delay: u32 = 60;
    var type_jitter: u32 = 90;
    var press_enter = false;
    var watch_timeout_ms: u64 = 0; // 0 = wait forever
    var watch_interval_ms: u32 = 300;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--pane") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "self")) {
                // Stable identity first (session name), pane id as a
                // fallback for an older GUI that can't resolve sessions.
                if (c.getenv("SKETERM_SESSION")) |env| req.session = std.mem.span(env);
                if (c.getenv("SKETERM_PANE_ID")) |env| req.pane = std.fmt.parseInt(u32, std.mem.span(env), 10) catch null;
                if (req.session == null and req.pane == null) {
                    _ = c.fprintf(platform.stderr(), "sketerm cli: --pane self but not inside a sketerm pane\n");
                    return 2;
                }
            } else {
                req.pane = parsePaneArg(args[i]) orelse {
                    _ = c.fprintf(platform.stderr(), "sketerm cli: bad --pane value\n");
                    return 2;
                };
            }
        } else if (std.mem.eql(u8, a, "--tab") and i + 1 < args.len) {
            i += 1;
            req.tab = std.fmt.parseInt(u32, args[i], 10) catch {
                _ = c.fprintf(platform.stderr(), "sketerm cli: bad --tab value\n");
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--scrollback") and i + 1 < args.len) {
            i += 1;
            req.scrollback = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--last-command")) {
            req.last_command = true;
        } else if (std.mem.eql(u8, a, "--regex") and i + 1 < args.len) {
            i += 1;
            req.data = args[i];
        } else if (std.mem.eql(u8, a, "--timeout") and i + 1 < args.len) {
            i += 1;
            watch_timeout_ms = (std.fmt.parseInt(u64, args[i], 10) catch 0) * 1000;
        } else if (std.mem.eql(u8, a, "--interval") and i + 1 < args.len) {
            i += 1;
            watch_interval_ms = std.fmt.parseInt(u32, args[i], 10) catch 300;
        } else if (std.mem.eql(u8, a, "--cwd") and i + 1 < args.len) {
            i += 1;
            req.cwd = args[i];
        } else if (std.mem.eql(u8, a, "--title") and i + 1 < args.len) {
            i += 1;
            req.title = args[i];
        } else if (std.mem.eql(u8, a, "--dir") and i + 1 < args.len) {
            i += 1;
            req.direction = args[i];
        } else if (std.mem.eql(u8, a, "--out") and i + 1 < args.len) {
            i += 1;
            req.data = args[i]; // screenshot output path
        } else if (std.mem.eql(u8, a, "--paste")) {
            req.paste = true;
        } else if (std.mem.eql(u8, a, "--delay") and i + 1 < args.len) {
            i += 1;
            type_delay = std.fmt.parseInt(u32, args[i], 10) catch 60;
        } else if (std.mem.eql(u8, a, "--jitter") and i + 1 < args.len) {
            i += 1;
            type_jitter = std.fmt.parseInt(u32, args[i], 10) catch 90;
        } else if (std.mem.eql(u8, a, "--enter")) {
            press_enter = true;
        } else if (std.mem.eql(u8, a, "--help")) {
            _ = c.fputs(CLI_HELP, platform.stdout());
            return 0;
        } else {
            text_parts.append(allocator, a) catch return 1;
        }
    }

    // Positional words become the payload (send-text data / title).
    if (text_parts.items.len > 0) {
        const joined = std.mem.join(allocator, " ", text_parts.items) catch return 1;
        // Leaked into the request; process exits right after.
        if (std.mem.eql(u8, cmd, "set-title")) {
            if (req.title == null) req.title = joined;
        } else if (press_enter and std.mem.eql(u8, cmd, "send-text")) {
            // type-text appends its CR below (paced); send-text gets
            // it here — previously --enter was silently dropped.
            req.data = std.fmt.allocPrint(allocator, "{s}\r", .{joined}) catch return 1;
        } else {
            req.data = joined;
        }
    }

    const sock_path = resolveSocket(allocator, socket_arg) orelse {
        _ = c.fprintf(platform.stderr(), "sketerm cli: no socket found (is sketerm running? use --socket or $SKETERM_SOCKET)\n");
        return 1;
    };

    if (std.mem.eql(u8, cmd, "watch")) {
        const pattern = req.data orelse {
            _ = c.fprintf(platform.stderr(), "sketerm cli: watch requires a pattern (--regex or positional)\n");
            allocator.free(sock_path);
            return 2;
        };
        return watchPane(allocator, sock_path, req.pane, req.session, pattern, watch_timeout_ms, watch_interval_ms);
    }

    if (std.mem.eql(u8, cmd, "type-text")) {
        const text_raw = req.data orelse {
            _ = c.fprintf(platform.stderr(), "sketerm cli: type-text requires text\n");
            allocator.free(sock_path);
            return 2;
        };
        const text = if (press_enter)
            std.fmt.allocPrint(allocator, "{s}\r", .{text_raw}) catch return 1
        else
            text_raw;
        return typeText(allocator, sock_path, req.pane, req.session, text, type_delay, type_jitter);
    }

    return talk(allocator, sock_path, req);
}

/// Poll a pane's text until a GRegex pattern matches a line; print
/// the matching line and exit 0. Exit 3 on timeout. Matching runs
/// against the visible screen + 100 scrollback lines each poll, so
/// pre-existing matches fire immediately (usually what you want:
/// "wait until ERROR appears — or tell me it already did").
fn watchPane(allocator: std.mem.Allocator, sock_path: [:0]u8, pane: ?u32, session: ?[]const u8, pattern: []const u8, timeout_ms: u64, interval_ms: u32) u8 {
    defer allocator.free(sock_path);

    const pat_z = allocator.dupeZ(u8, pattern) catch return 1;
    defer allocator.free(pat_z);
    var gerr: [*c]c.GError = null;
    const regex = c.g_regex_new(pat_z.ptr, 0, 0, &gerr) orelse {
        const msg: [*c]const u8 = if (gerr != null) gerr.*.message else "bad pattern";
        _ = c.fprintf(platform.stderr(), "sketerm cli: bad regex: %s\n", msg);
        if (gerr != null) c.g_error_free(gerr);
        return 2;
    };
    defer c.g_regex_unref(regex);

    const client = c.g_socket_client_new();
    defer c.g_object_unref(client);
    const addr = c.g_unix_socket_address_new(sock_path.ptr);
    defer c.g_object_unref(addr);
    const conn = c.g_socket_client_connect(client, @ptrCast(@alignCast(addr)), null, &gerr);
    if (conn == null) {
        const msg: [*c]const u8 = if (gerr != null) gerr.*.message else "unknown";
        _ = c.fprintf(platform.stderr(), "sketerm cli: connect failed: %s\n", msg);
        if (gerr != null) c.g_error_free(gerr);
        return 1;
    }
    defer c.g_object_unref(conn);
    const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn));
    const din = c.g_data_input_stream_new(c.g_io_stream_get_input_stream(@ptrCast(conn)));
    defer c.g_object_unref(din);

    const start_us = c.g_get_monotonic_time();
    while (true) {
        // One get-text request per poll on the persistent connection.
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const poll_req = protocol.Request{
            .cmd = "get-text",
            .pane = pane,
            .session = session,
            .scrollback = 100,
        };
        std.json.Stringify.value(poll_req, .{}, &aw.writer) catch return 1;
        aw.writer.writeAll("\n") catch return 1;
        const line = aw.written();
        var written: c.gsize = 0;
        if (c.g_output_stream_write_all(out_stream, line.ptr, line.len, &written, null, &gerr) == 0) {
            if (gerr != null) c.g_error_free(gerr);
            _ = c.fprintf(platform.stderr(), "sketerm cli: write failed\n");
            return 1;
        }
        var rlen: c.gsize = 0;
        const resp = c.g_data_input_stream_read_line(din, &rlen, null, &gerr);
        if (resp == null) {
            if (gerr != null) c.g_error_free(gerr);
            _ = c.fprintf(platform.stderr(), "sketerm cli: connection closed\n");
            return 1;
        }
        defer c.g_free(resp);

        const Reply = struct { ok: bool = false, text: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Reply, allocator, resp[0..rlen], .{
            .ignore_unknown_fields = true,
        }) catch return 1;
        defer parsed.deinit();
        if (!parsed.value.ok) {
            _ = c.fwrite(resp, 1, rlen, platform.stderr());
            _ = c.fputc('\n', platform.stderr());
            return 1;
        }

        var lines = std.mem.splitScalar(u8, parsed.value.text, '\n');
        while (lines.next()) |ln| {
            if (ln.len == 0) continue;
            const ln_z = allocator.dupeZ(u8, ln) catch return 1;
            defer allocator.free(ln_z);
            if (c.g_regex_match(regex, ln_z.ptr, 0, null) != 0) {
                _ = c.fwrite(ln.ptr, 1, ln.len, platform.stdout());
                _ = c.fputc('\n', platform.stdout());
                return 0;
            }
        }

        if (timeout_ms > 0) {
            const elapsed_ms: u64 = @intCast(@divTrunc(c.g_get_monotonic_time() - start_us, 1000));
            if (elapsed_ms >= timeout_ms) {
                _ = c.fprintf(platform.stderr(), "sketerm cli: watch timed out\n");
                return 3;
            }
        }
        c.g_usleep(@as(c.gulong, interval_ms) * 1000);
    }
}

/// Stream one send-text request per keystroke over a single
/// connection, sleeping a randomized inter-key delay in between.
/// Pacing lives client-side so a Ctrl-C stops the "typing" cold.
fn typeText(allocator: std.mem.Allocator, sock_path: [:0]u8, pane: ?u32, session: ?[]const u8, text: []const u8, delay: u32, jitter: u32) u8 {
    defer allocator.free(sock_path);
    const humantype = @import("../util/humantype.zig");

    const client = c.g_socket_client_new();
    defer c.g_object_unref(client);
    const addr = c.g_unix_socket_address_new(sock_path.ptr);
    defer c.g_object_unref(addr);
    var gerr: [*c]c.GError = null;
    const conn = c.g_socket_client_connect(client, @ptrCast(@alignCast(addr)), null, &gerr);
    if (conn == null) {
        const msg: [*c]const u8 = if (gerr != null) gerr.*.message else "unknown";
        _ = c.fprintf(platform.stderr(), "sketerm cli: connect failed: %s\n", msg);
        if (gerr != null) c.g_error_free(gerr);
        return 1;
    }
    defer c.g_object_unref(conn);
    const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn));
    const din = c.g_data_input_stream_new(c.g_io_stream_get_input_stream(@ptrCast(conn)));
    defer c.g_object_unref(din);

    var seed: u64 = 0;
    {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        seed = @as(u64, @bitCast(@as(i64, ts.tv_nsec))) ^ (@as(u64, @bitCast(@as(i64, ts.tv_sec))) << 20);
    }
    var pacer = humantype.Pacer.init(delay, jitter, seed);
    var chunks = humantype.Chunks{ .text = text };
    var first = true;
    while (chunks.next()) |chunk| {
        if (!first) {
            const ms = pacer.delayMs(chunk);
            var ts: c.struct_timespec = .{
                .tv_sec = ms / 1000,
                .tv_nsec = @as(c_long, ms % 1000) * 1_000_000,
            };
            _ = c.nanosleep(&ts, null);
        }
        first = false;

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const line_req: protocol.Request = .{ .cmd = "send-text", .pane = pane, .session = session, .data = chunk };
        std.json.Stringify.value(line_req, .{}, &aw.writer) catch return 1;
        aw.writer.writeAll("\n") catch return 1;
        const line = aw.written();

        var written: c.gsize = 0;
        var werr: [*c]c.GError = null;
        if (c.g_output_stream_write_all(out_stream, line.ptr, line.len, &written, null, &werr) == 0) {
            if (werr != null) c.g_error_free(werr);
            _ = c.fprintf(platform.stderr(), "sketerm cli: write failed\n");
            return 1;
        }
        // One response line per request keeps us in lockstep — and
        // surfaces "no such pane" on the first keystroke, not never.
        var rlen: c.gsize = 0;
        var rerr: [*c]c.GError = null;
        const resp = c.g_data_input_stream_read_line(din, &rlen, null, &rerr);
        if (resp == null) {
            if (rerr != null) c.g_error_free(rerr);
            _ = c.fprintf(platform.stderr(), "sketerm cli: no response\n");
            return 1;
        }
        defer c.g_free(resp);
        if (std.mem.indexOf(u8, resp[0..rlen], "\"ok\":true") == null) {
            _ = c.fwrite(resp, 1, rlen, platform.stdout());
            _ = c.fputc('\n', platform.stdout());
            return 1;
        }
    }
    _ = c.fputs("{\"ok\":true}\n", platform.stdout());
    return 0;
}

/// Numeric "--pane N". ("self" is handled in the arg loop, where it
/// resolves to the stable session identity, not a pane number.)
fn parsePaneArg(arg: []const u8) ?u32 {
    return std.fmt.parseInt(u32, arg, 10) catch null;
}

pub fn resolveSocket(allocator: std.mem.Allocator, arg: ?[]const u8) ?[:0]u8 {
    if (arg) |a| return allocator.dupeZ(u8, a) catch null;
    if (c.getenv("SKETERM_SOCKET")) |env| {
        return allocator.dupeZ(u8, std.mem.span(env)) catch null;
    }
    // Exactly one running instance → unambiguous.
    const rt = @import("../util/platform.zig").runtimeDir();
    const dir_z = std.fmt.allocPrintSentinel(allocator, "{s}/sketerm", .{rt}, 0) catch return null;
    defer allocator.free(dir_z);
    const dir = c.g_dir_open(dir_z.ptr, 0, null) orelse return null;
    defer c.g_dir_close(dir);
    var found: ?[:0]u8 = null;
    while (c.g_dir_read_name(dir)) |name_c| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_c)));
        if (!std.mem.endsWith(u8, name, ".sock")) continue;
        // The mux daemon's socket lives in the same dir; it speaks a
        // different protocol and must never match GUI discovery.
        if (std.mem.eql(u8, name, "mux.sock")) continue;
        const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir_z, name }, 0) catch return null;
        // A GUI crash (SIGSEGV) orphans its socket file — counting it
        // would wrongly trip "multiple instances". Only a socket with a
        // live listener is a real instance; reap the dead ones so the
        // directory self-heals after a crash.
        if (!socketAlive(path)) {
            _ = c.unlink(path.ptr);
            allocator.free(path);
            continue;
        }
        if (found != null) {
            allocator.free(found.?);
            allocator.free(path);
            _ = c.fprintf(platform.stderr(), "sketerm cli: multiple instances; pass --socket\n");
            return null;
        }
        found = path;
    }
    return found;
}

/// True when a Unix socket path has a listener accepting connections.
/// A stale file from a crashed instance refuses the connect.
pub fn socketAlive(path_z: [:0]const u8) bool {
    const client = c.g_socket_client_new();
    defer c.g_object_unref(client);
    const addr = c.g_unix_socket_address_new(path_z.ptr);
    defer c.g_object_unref(addr);
    var gerr: [*c]c.GError = null;
    const conn = c.g_socket_client_connect(client, @ptrCast(@alignCast(addr)), null, &gerr);
    if (gerr != null) c.g_error_free(gerr);
    if (conn == null) return false;
    c.g_object_unref(conn);
    return true;
}

fn talk(allocator: std.mem.Allocator, sock_path: [:0]u8, req: protocol.Request) u8 {
    defer allocator.free(sock_path);

    // Serialize the request as one line.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    std.json.Stringify.value(req, .{}, &aw.writer) catch return 1;
    aw.writer.writeAll("\n") catch return 1;
    const line = aw.written();

    const client = c.g_socket_client_new();
    defer c.g_object_unref(client);
    const addr = c.g_unix_socket_address_new(sock_path.ptr);
    defer c.g_object_unref(addr);

    var gerr: [*c]c.GError = null;
    const conn = c.g_socket_client_connect(client, @ptrCast(@alignCast(addr)), null, &gerr);
    if (conn == null) {
        const msg: [*c]const u8 = if (gerr != null) gerr.*.message else "unknown";
        _ = c.fprintf(platform.stderr(), "sketerm cli: connect failed: %s\n", msg);
        if (gerr != null) c.g_error_free(gerr);
        return 1;
    }
    defer c.g_object_unref(conn);

    const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn));
    var written: c.gsize = 0;
    if (c.g_output_stream_write_all(out_stream, line.ptr, line.len, &written, null, &gerr) == 0) {
        if (gerr != null) c.g_error_free(gerr);
        _ = c.fprintf(platform.stderr(), "sketerm cli: write failed\n");
        return 1;
    }

    const din = c.g_data_input_stream_new(c.g_io_stream_get_input_stream(@ptrCast(conn)));
    defer c.g_object_unref(din);
    var rlen: c.gsize = 0;
    const resp = c.g_data_input_stream_read_line(din, &rlen, null, &gerr);
    if (resp == null) {
        if (gerr != null) c.g_error_free(gerr);
        _ = c.fprintf(platform.stderr(), "sketerm cli: no response\n");
        return 1;
    }
    defer c.g_free(resp);

    _ = c.fwrite(resp, 1, rlen, platform.stdout());
    _ = c.fputc('\n', platform.stdout());

    // Exit code mirrors the ok field.
    const Ok = struct { ok: bool = false };
    const parsed = std.json.parseFromSlice(Ok, allocator, resp[0..rlen], .{
        .ignore_unknown_fields = true,
    }) catch return 1;
    defer parsed.deinit();
    return if (parsed.value.ok) 0 else 1;
}
