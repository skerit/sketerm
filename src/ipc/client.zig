//! `sketerm cli <cmd>` — blocking remote-control client. Runs before
//! GApplication ever starts (no display needed): builds one JSON
//! request line from argv, writes it to the socket, prints the JSON
//! response line to stdout. Exit 0 iff the response says ok.

const std = @import("std");
const c = @import("../c.zig").c;
const protocol = @import("protocol.zig");

const CLI_HELP =
    \\Usage: sketerm cli [--socket PATH] <command> [options]
    \\
    \\Commands:
    \\  list                              window/tab/pane tree as JSON
    \\  send-text [opts] <text...>        write text to a pane's PTY
    \\      --pane N    target pane (default: focused)
    \\      --paste     wrap in bracketed-paste markers if enabled
    \\  get-text [--pane N] [--scrollback N]
    \\                                    read screen text back (JSON);
    \\                                    --scrollback dumps the ring too
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
            _ = c.fputs(CLI_HELP, c.stdout);
            return 0;
        } else {
            _ = c.fprintf(c.stderr, "sketerm cli: unknown flag before command\n");
            return 2;
        }
    }
    if (i >= args.len) {
        _ = c.fputs(CLI_HELP, c.stdout);
        return 2;
    }
    const cmd = args[i];
    i += 1;

    var req: protocol.Request = .{ .cmd = cmd };
    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(allocator);

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--pane") and i + 1 < args.len) {
            i += 1;
            req.pane = parsePaneArg(args[i]) orelse {
                _ = c.fprintf(c.stderr, "sketerm cli: bad --pane value\n");
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--tab") and i + 1 < args.len) {
            i += 1;
            req.tab = std.fmt.parseInt(u32, args[i], 10) catch {
                _ = c.fprintf(c.stderr, "sketerm cli: bad --tab value\n");
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--scrollback") and i + 1 < args.len) {
            i += 1;
            req.scrollback = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--cwd") and i + 1 < args.len) {
            i += 1;
            req.cwd = args[i];
        } else if (std.mem.eql(u8, a, "--title") and i + 1 < args.len) {
            i += 1;
            req.title = args[i];
        } else if (std.mem.eql(u8, a, "--dir") and i + 1 < args.len) {
            i += 1;
            req.direction = args[i];
        } else if (std.mem.eql(u8, a, "--paste")) {
            req.paste = true;
        } else if (std.mem.eql(u8, a, "--help")) {
            _ = c.fputs(CLI_HELP, c.stdout);
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
        } else {
            req.data = joined;
        }
    }

    const sock_path = resolveSocket(allocator, socket_arg) orelse {
        _ = c.fprintf(c.stderr, "sketerm cli: no socket found (is sketerm running? use --socket or $SKETERM_SOCKET)\n");
        return 1;
    };

    return talk(allocator, sock_path, req);
}

/// "--pane self" resolves via $SKETERM_PANE_ID.
fn parsePaneArg(arg: []const u8) ?u32 {
    if (std.mem.eql(u8, arg, "self")) {
        const env = c.getenv("SKETERM_PANE_ID") orelse return null;
        return std.fmt.parseInt(u32, std.mem.span(env), 10) catch null;
    }
    return std.fmt.parseInt(u32, arg, 10) catch null;
}

pub fn resolveSocket(allocator: std.mem.Allocator, arg: ?[]const u8) ?[:0]u8 {
    if (arg) |a| return allocator.dupeZ(u8, a) catch null;
    if (c.getenv("SKETERM_SOCKET")) |env| {
        return allocator.dupeZ(u8, std.mem.span(env)) catch null;
    }
    // Exactly one running instance → unambiguous.
    const rt_raw = c.getenv("XDG_RUNTIME_DIR");
    const rt: []const u8 = if (rt_raw != null) std.mem.span(rt_raw) else "/tmp";
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
        if (found != null) {
            allocator.free(found.?);
            _ = c.fprintf(c.stderr, "sketerm cli: multiple instances; pass --socket\n");
            return null;
        }
        found = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir_z, name }, 0) catch return null;
    }
    return found;
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
        _ = c.fprintf(c.stderr, "sketerm cli: connect failed: %s\n", msg);
        if (gerr != null) c.g_error_free(gerr);
        return 1;
    }
    defer c.g_object_unref(conn);

    const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn));
    var written: c.gsize = 0;
    if (c.g_output_stream_write_all(out_stream, line.ptr, line.len, &written, null, &gerr) == 0) {
        if (gerr != null) c.g_error_free(gerr);
        _ = c.fprintf(c.stderr, "sketerm cli: write failed\n");
        return 1;
    }

    const din = c.g_data_input_stream_new(c.g_io_stream_get_input_stream(@ptrCast(conn)));
    defer c.g_object_unref(din);
    var rlen: c.gsize = 0;
    const resp = c.g_data_input_stream_read_line(din, &rlen, null, &gerr);
    if (resp == null) {
        if (gerr != null) c.g_error_free(gerr);
        _ = c.fprintf(c.stderr, "sketerm cli: no response\n");
        return 1;
    }
    defer c.g_free(resp);

    _ = c.fwrite(resp, 1, rlen, c.stdout);
    _ = c.fputc('\n', c.stdout);

    // Exit code mirrors the ok field.
    const Ok = struct { ok: bool = false };
    const parsed = std.json.parseFromSlice(Ok, allocator, resp[0..rlen], .{
        .ignore_unknown_fields = true,
    }) catch return 1;
    defer parsed.deinit();
    return if (parsed.value.ok) 0 else 1;
}
