//! Standalone Sketerm Viewer window and shared daemon-backed image loader.

const std = @import("std");
const c = @import("../c.zig").c;
const model = @import("../viewer.zig");
const paths = @import("../filebrowser/paths.zig");
const decoder = @import("image_decoder.zig");
const image_canvas = @import("image_canvas.zig");
const hostmount = @import("hostmount.zig");
const fsdrive = @import("../ipc/fsdrive.zig");
const muxclient = @import("../mux/client.zig");
const Config = @import("../config.zig").Config;
const platform = @import("../util/platform.zig");
const castbox = @import("castbox.zig");
const Terminal = @import("../terminal.zig").Terminal;

pub const Variant = enum { preview, original, external_copy };
const PREVIEW_BYTES_MAX: usize = 2 << 20;
const ORIGINAL_BYTES_MAX: usize = 128 << 20;
const PREVIEW_PIXELS_MAX: usize = 4 * 1024 * 1024;
const ORIGINAL_PIXELS_MAX: usize = 64 * 1024 * 1024;
const ORIGINAL_ANIMATION_BYTES_MAX: usize = 256 << 20;
const LOAD_TIMEOUT_MS: i64 = 120_000;

pub const LoadResult = struct {
    variant: Variant,
    decoded: ?decoder.Decoded = null,
    source_bytes: usize = 0,
    message: [160]u8 = undefined,
    message_len: usize = 0,
    metadata: [1024]u8 = undefined,
    metadata_len: usize = 0,
    materialized: [4096:0]u8 = @splat(0),
    materialized_len: usize = 0,

    pub fn messageText(self: *const LoadResult) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn metadataText(self: *const LoadResult) []const u8 {
        return self.metadata[0..self.metadata_len];
    }

    fn setError(self: *LoadResult, err: anyerror) void {
        const text = @errorName(err);
        self.message_len = @min(text.len, self.message.len);
        @memcpy(self.message[0..self.message_len], text[0..self.message_len]);
    }

    fn deinit(self: *LoadResult) void {
        if (self.decoded) |*image| image.deinit(std.heap.c_allocator);
        if (self.materialized_len > 0) _ = c.unlink(&self.materialized);
    }
};

pub const LoadCallback = *const fn (?*anyopaque, *LoadResult) void;

/// Refcounted liveness fence shared by detached loader workers and a UI owner.
pub const LoadTarget = struct {
    mutex: c.pthread_mutex_t = undefined,
    refs: u32 = 1,
    alive: bool = true,
    generation: u64 = 0,
    active_fd: c_int = -1,
    active: bool = false,
    pending: ?*LoadWork = null,
    callback: LoadCallback,
    context: ?*anyopaque,

    pub fn create(callback: LoadCallback, context: ?*anyopaque) ?*LoadTarget {
        const allocator = std.heap.c_allocator;
        const self = allocator.create(LoadTarget) catch return null;
        self.* = .{ .callback = callback, .context = context };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) {
            allocator.destroy(self);
            return null;
        }
        return self;
    }

    fn lock(self: *LoadTarget) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }

    fn unlock(self: *LoadTarget) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn unref(self: *LoadTarget) void {
        self.lock();
        self.refs -= 1;
        const destroy = self.refs == 0;
        self.unlock();
        if (destroy) {
            _ = c.pthread_mutex_destroy(&self.mutex);
            std.heap.c_allocator.destroy(self);
        }
    }

    pub fn close(self: *LoadTarget) void {
        self.lock();
        self.alive = false;
        self.generation +%= 1;
        if (self.active_fd >= 0) _ = c.shutdown(self.active_fd, c.SHUT_RDWR);
        self.active_fd = -1;
        const pending = self.pending;
        self.pending = null;
        self.unlock();
        if (pending) |work| discardWork(work);
        self.unref();
    }

    pub fn cancel(self: *LoadTarget) void {
        self.lock();
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        if (self.active_fd >= 0) _ = c.shutdown(self.active_fd, c.SHUT_RDWR);
        self.active_fd = -1;
        const pending = self.pending;
        self.pending = null;
        self.unlock();
        if (pending) |work| discardWork(work);
    }

    fn registerFd(self: *LoadTarget, generation: u64, fd: c_int) bool {
        self.lock();
        defer self.unlock();
        if (!self.alive or self.generation != generation) return false;
        self.active_fd = fd;
        return true;
    }

    fn clearFd(self: *LoadTarget, generation: u64, fd: c_int) void {
        self.lock();
        if (self.generation == generation and self.active_fd == fd) self.active_fd = -1;
        self.unlock();
    }

    fn current(self: *LoadTarget, generation: u64) bool {
        self.lock();
        defer self.unlock();
        return self.alive and self.generation == generation;
    }

    pub fn start(self: *LoadTarget, spec: []const u8, variant: Variant) bool {
        const allocator = std.heap.c_allocator;
        const work = allocator.create(LoadWork) catch return false;
        work.* = .{
            .target = self,
            .generation = 0,
            .spec = allocator.dupe(u8, spec) catch {
                allocator.destroy(work);
                return false;
            },
            .variant = variant,
        };
        self.lock();
        if (!self.alive) {
            self.unlock();
            allocator.free(work.spec);
            allocator.destroy(work);
            return false;
        }
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        if (self.active_fd >= 0) _ = c.shutdown(self.active_fd, c.SHUT_RDWR);
        self.active_fd = -1;
        work.generation = self.generation;
        const superseded = self.pending;
        self.pending = null;
        self.refs += 1; // the queued/running work's reference
        if (self.active) {
            self.pending = work;
            self.unlock();
            if (superseded) |old| discardWork(old);
            return true;
        }
        self.active = true;
        const thread = std.Thread.spawn(.{}, loadThread, .{work}) catch {
            self.active = false;
            self.refs -= 1;
            self.unlock();
            allocator.free(work.spec);
            allocator.destroy(work);
            return false;
        };
        thread.detach();
        self.unlock();
        return true;
    }
};

const LoadWork = struct {
    target: *LoadTarget,
    generation: u64,
    spec: []u8,
    variant: Variant,
    result: LoadResult = undefined,
};

fn discardWork(work: *LoadWork) void {
    const target = work.target;
    std.heap.c_allocator.free(work.spec);
    std.heap.c_allocator.destroy(work);
    target.unref();
}

fn connectFs(host: ?[]const u8) !fsdrive.Fs {
    const allocator = std.heap.c_allocator;
    const conn = if (host) |remote| blk: {
        var config = Config.load(allocator);
        defer config.deinit();
        break :blk try muxclient.Conn.connectRemote(allocator, remote, config.udpRange());
    } else try muxclient.Conn.connectLocalAutostart(allocator);
    return fsdrive.Fs.initConn(allocator, conn);
}

fn readAll(fs: *fsdrive.Fs, path: []const u8, cap: usize) ![]u8 {
    const allocator = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const probe = try fs.read(path, 0, 0, &out);
    if (probe.size > cap) return error.SourceTooLarge;
    try out.ensureTotalCapacity(allocator, @intCast(probe.size));
    var offset: u64 = 0;
    while (offset < probe.size) {
        const before = out.items.len;
        const remaining = probe.size - offset;
        const requested: u32 = @intCast(@min(remaining, fsdrive.fsserve.MAX_READ));
        const info = try fs.read(path, offset, requested, &out);
        const received = out.items.len - before;
        if (received == 0) return error.ShortRead;
        offset += received;
        if (out.items.len > cap) return error.SourceTooLarge;
        if (info.eof) break;
    }
    if (offset != probe.size) return error.ShortRead;
    return out.toOwnedSlice(allocator);
}

const FetchPayload = struct {
    bytes: []u8,
    source_size: usize,
    metadata: [1024]u8 = undefined,
    metadata_len: usize = 0,
};

fn fetchMetadata(fs: *fsdrive.Fs, resource: model.Resource, payload: *FetchPayload) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const dir = std.fs.path.dirname(resource.path) orelse "/";
    const names = [_][]const u8{std.fs.path.basename(resource.path)};
    const results = fs.mediaMeta(arena.allocator(), dir, &names, 15_000) catch return;
    if (results.len == 0) return;
    const interesting = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "media.format", .label = "Format" },
        .{ .key = "media.bit_depth", .label = "Bit depth" },
        .{ .key = "image.orientation", .label = "Orientation" },
        .{ .key = "exif.datetime_original", .label = "Captured" },
        .{ .key = "exif.make", .label = "Camera maker" },
        .{ .key = "exif.model", .label = "Camera" },
        .{ .key = "exif.lens", .label = "Lens" },
        .{ .key = "exif.exposure_time", .label = "Exposure" },
        .{ .key = "exif.f_number", .label = "Aperture" },
        .{ .key = "exif.iso", .label = "ISO" },
        .{ .key = "exif.focal_length", .label = "Focal length" },
    };
    var writer = std.Io.Writer.fixed(payload.metadata[0 .. payload.metadata.len - 1]);
    for (interesting) |field| {
        const value = results[0].get(field.key) orelse continue;
        if (writer.buffered().len > 0) writer.writeByte('\n') catch break;
        writer.print("{s}: {s}", .{ field.label, value }) catch break;
    }
    payload.metadata_len = writer.buffered().len;
    payload.metadata[payload.metadata_len] = 0;
}

fn fetch(work: *LoadWork) !FetchPayload {
    const spec = work.spec;
    const variant = work.variant;
    const resource = model.Resource.parse(spec);
    if (resource.host == null) {
        if (paths.isSketermMount(resource.path)) return error.SketermFusePathNotSupported;
        var path_buf: [4096:0]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{resource.path}) catch return error.PathTooLong;
        var real_buf: [4096:0]u8 = undefined;
        if (c.realpath(path_z.ptr, &real_buf)) |resolved| {
            if (paths.isSketermMount(std.mem.span(resolved))) return error.SketermFusePathNotSupported;
        }
    }
    var fs = try connectFs(resource.host);
    defer fs.deinit();
    if (!work.target.registerFd(work.generation, fs.conn.fd)) return error.Canceled;
    defer work.target.clearFd(work.generation, fs.conn.fd);
    var probe_bytes: std.ArrayList(u8) = .empty;
    defer probe_bytes.deinit(std.heap.c_allocator);
    const source = try fs.read(resource.path, 0, 0, &probe_bytes);
    if (source.size > ORIGINAL_BYTES_MAX) return error.SourceTooLarge;
    if (variant == .original or variant == .external_copy) {
        const bytes = try readAll(&fs, resource.path, ORIGINAL_BYTES_MAX);
        var payload = FetchPayload{ .source_size = bytes.len, .bytes = bytes };
        fetchMetadata(&fs, resource, &payload);
        return payload;
    }

    const job = try fs.startPreviewCodecs(resource.path, "png");
    var event = try fs.waitJobTerminal(job, LOAD_TIMEOUT_MS);
    defer event.deinit();
    if (!std.mem.eql(u8, event.ev, "done") or event.path.len == 0) return error.PreviewFailed;
    const bytes = readAll(&fs, event.path, PREVIEW_BYTES_MAX) catch |err| {
        if (!event.keep) fs.unlink(event.path) catch {};
        return err;
    };
    if (!event.keep) fs.unlink(event.path) catch {};
    var payload = FetchPayload{ .source_size = @intCast(source.size), .bytes = bytes };
    fetchMetadata(&fs, resource, &payload);
    return payload;
}

fn loadThread(first: *LoadWork) void {
    const allocator = std.heap.c_allocator;
    var work = first;
    while (true) {
        work.result = .{ .variant = work.variant };
        if (fetch(work)) |payload| {
            defer allocator.free(payload.bytes);
            work.result.source_bytes = payload.source_size;
            work.result.metadata_len = payload.metadata_len;
            @memcpy(work.result.metadata[0..payload.metadata_len], payload.metadata[0..payload.metadata_len]);
            work.result.metadata[payload.metadata_len] = 0;
            if (work.target.current(work.generation) and work.variant == .external_copy) {
                materializeOpenCopy(work, payload.bytes, &work.result) catch |err| work.result.setError(err);
            } else if (work.target.current(work.generation)) {
                const max_pixels = if (work.variant == .preview) PREVIEW_PIXELS_MAX else ORIGINAL_PIXELS_MAX;
                work.result.decoded = decoder.decodeBytes(allocator, payload.bytes, .{
                    .max_pixels = max_pixels,
                    .max_animation_bytes = if (work.variant == .preview) PREVIEW_PIXELS_MAX * 4 else ORIGINAL_ANIMATION_BYTES_MAX,
                    .max_frames = if (work.variant == .preview) 1 else 240,
                    .cancel_context = @ptrCast(work),
                    .should_cancel = &decodeStillCurrent,
                }) catch |err| blk: {
                    work.result.setError(err);
                    break :blk null;
                };
            } else work.result.setError(error.Canceled);
        } else |err| work.result.setError(err);
        allocator.free(work.spec);
        work.spec = &.{};

        const target = work.target;
        target.lock();
        const deliver = target.alive and target.generation == work.generation;
        const next = if (target.alive) target.pending else null;
        target.pending = null;
        if (next == null) target.active = false;
        target.unlock();

        if (deliver) {
            _ = c.g_idle_add(@ptrCast(&loadIdle), @ptrCast(work));
        } else {
            work.result.deinit();
            allocator.destroy(work);
            target.unref();
        }
        work = next orelse return;
    }
}

fn materializeOpenCopy(work: *LoadWork, bytes: []const u8, result: *LoadResult) !void {
    const resource = model.Resource.parse(work.spec);
    const cache = c.g_get_user_cache_dir() orelse return error.NoCacheDirectory;
    var dir_buf: [4096:0]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/sketerm/viewer-open", .{std.mem.span(cache)}) catch return error.PathTooLong;
    if (c.g_mkdir_with_parents(dir.ptr, 0o700) != 0) return error.CacheDirectoryFailed;
    var dir_stat: c.struct_stat = undefined;
    if (c.lstat(dir.ptr, &dir_stat) != 0 or dir_stat.st_uid != c.geteuid() or
        (dir_stat.st_mode & c.S_IFMT) != c.S_IFDIR)
        return error.UnsafeCacheDirectory;
    if ((dir_stat.st_mode & 0o777) != 0o700 and c.chmod(dir.ptr, @as(c.mode_t, 0o700)) != 0)
        return error.UnsafeCacheDirectory;
    sweepOpenCopies(dir);
    const name = resource.name();
    const safe_name = if (name.len > 0 and name.len < 512) name else "remote-image";
    const path = std.fmt.bufPrintZ(&result.materialized, "{s}/open-{d}-{d}-{s}", .{
        dir,
        c.getpid(),
        c.g_get_monotonic_time(),
        safe_name,
    }) catch return error.PathTooLong;
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenCopyFailed;
    var installed = false;
    defer {
        _ = c.close(fd);
        if (!installed) _ = c.unlink(path.ptr);
    }
    var at: usize = 0;
    while (at < bytes.len) {
        if (!work.target.current(work.generation)) return error.Canceled;
        const written = c.write(fd, bytes.ptr + at, bytes.len - at);
        if (written < 0 and std.posix.errno(written) == .INTR) continue;
        if (written <= 0) return error.OpenCopyFailed;
        at += @intCast(written);
    }
    installed = true;
    result.materialized_len = path.len;
}

fn sweepOpenCopies(directory: [:0]const u8) void {
    const dir = c.opendir(directory.ptr) orelse return;
    defer _ = c.closedir(dir);
    const now = c.time(null);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!std.mem.startsWith(u8, name, "open-")) continue;
        var path_buf: [4096:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ directory, name }) catch continue;
        var st: c.struct_stat = undefined;
        if (c.lstat(path.ptr, &st) != 0 or st.st_uid != c.geteuid() or (st.st_mode & c.S_IFMT) != c.S_IFREG) continue;
        const modified = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim.tv_sec else st.st_mtimespec.tv_sec;
        if (modified + 3600 < now) _ = c.unlink(path.ptr);
    }
}

fn decodeStillCurrent(user: ?*anyopaque) bool {
    const work: *LoadWork = @ptrCast(@alignCast(user.?));
    return !work.target.current(work.generation);
}

fn loadIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const work: *LoadWork = @ptrCast(@alignCast(user.?));
    const target = work.target;
    target.lock();
    const deliver = target.alive and target.generation == work.generation;
    const callback = target.callback;
    const context = target.context;
    target.unlock();
    if (deliver) callback(context, &work.result);
    work.result.deinit();
    std.heap.c_allocator.destroy(work);
    target.unref();
    return 0;
}

pub fn textureFromDecoded(image: *const decoder.Decoded) ?*c.GdkTexture {
    const frame = image.first();
    const bytes = c.g_bytes_new(frame.rgba.ptr, frame.rgba.len) orelse return null;
    defer c.g_bytes_unref(bytes);
    return @ptrCast(@alignCast(c.gdk_memory_texture_new(
        @intCast(frame.width),
        @intCast(frame.height),
        c.GDK_MEMORY_R8G8B8A8,
        bytes,
        @intCast(frame.width * 4),
    )));
}

const VIEWER_QDATA = "sketerm-viewer-window";

/// What the viewer window currently shows. `.image` routes to the
/// window-owned canvas/loader pipeline, which persists across items
/// (LoadTargets, canvas, session all live for the window's whole
/// life); `.cast` carries a per-item playback controller that is torn
/// down completely on every navigation (its ephemeral daemon session
/// dies with it).
pub const Content = union(enum) {
    image,
    cast: *castbox.CastPlayerBox,
};

/// Number of header controls that only make sense for images and hide
/// while a cast is showing.
const IMAGE_CONTROL_COUNT = 10;

pub const ViewerWindow = struct {
    allocator: std.mem.Allocator,
    window: *c.GtkWidget,
    batch: model.Batch,
    index: usize = 0,
    canvas: image_canvas.Canvas,
    session: image_canvas.Session = .{},
    target: *LoadTarget,
    open_target: *LoadTarget,
    status: *c.GtkLabel,
    position: *c.GtkLabel,
    zoom_label: *c.GtkLabel,
    original_button: *c.GtkWidget,
    play_button: *c.GtkWidget,
    metadata_label: *c.GtkLabel,
    prev_button: *c.GtkWidget,
    next_button: *c.GtkWidget,
    fullscreen: bool = false,
    content: Content = .image,
    /// Vertical box the cast surface + transport bar mount into;
    /// hidden (and empty) while an image is showing.
    cast_slot: *c.GtkWidget,
    /// Header controls hidden while a cast is showing.
    image_controls: [IMAGE_CONTROL_COUNT]*c.GtkWidget,
    /// Latest recording title (cast header / OSC title / basename).
    cast_title: [512]u8 = undefined,
    cast_title_len: usize = 0,
    pending_mount: ?*MountOpen = null,
    /// Image-canvas context menu. Borrowed: the click gesture on the
    /// canvas owns it and frees it when the canvas dies.
    canvas_menu: ?*CanvasMenu = null,

    pub fn open(allocator: std.mem.Allocator, app: ?*c.GtkApplication, batch: model.Batch) !*ViewerWindow {
        const self = try allocator.create(ViewerWindow);
        errdefer allocator.destroy(self);
        const window = c.adw_application_window_new(app) orelse return error.OutOfMemory;
        errdefer c.gtk_window_destroy(@ptrCast(window));
        c.gtk_window_set_title(@ptrCast(window), model.APP_NAME);
        c.gtk_window_set_default_size(@ptrCast(window), 1100, 760);

        const toolbar = c.adw_toolbar_view_new().?;
        const header = c.adw_header_bar_new().?;
        const open_button = c.gtk_button_new_from_icon_name("document-open-symbolic").?;
        c.gtk_widget_set_tooltip_text(open_button, "Open Image");
        const prev_button = c.gtk_button_new_from_icon_name("go-previous-symbolic").?;
        c.gtk_widget_set_tooltip_text(prev_button, "Previous Image (Left)");
        const next_button = c.gtk_button_new_from_icon_name("go-next-symbolic").?;
        c.gtk_widget_set_tooltip_text(next_button, "Next Image (Right)");
        c.adw_header_bar_pack_start(@ptrCast(header), open_button);
        c.adw_header_bar_pack_start(@ptrCast(header), prev_button);
        c.adw_header_bar_pack_start(@ptrCast(header), next_button);

        const zoom_out = c.gtk_button_new_from_icon_name("zoom-out-symbolic").?;
        const zoom_label = c.gtk_label_new("Fit").?;
        c.gtk_widget_add_css_class(zoom_label, "numeric");
        c.gtk_widget_set_size_request(zoom_label, 52, -1);
        const zoom_in = c.gtk_button_new_from_icon_name("zoom-in-symbolic").?;
        const fit_button = c.gtk_button_new_from_icon_name("zoom-fit-best-symbolic").?;
        c.gtk_widget_set_tooltip_text(fit_button, "Fit to Window (F)");
        const actual_button = c.gtk_button_new_from_icon_name("zoom-original-symbolic").?;
        c.gtk_widget_set_tooltip_text(actual_button, "Actual Size (0)");
        const fill_button = c.gtk_button_new_from_icon_name("view-fullscreen-symbolic").?;
        c.gtk_widget_set_tooltip_text(fill_button, "Fill Window (C)");
        const rotate_left = c.gtk_button_new_from_icon_name("object-rotate-left-symbolic").?;
        c.gtk_widget_set_tooltip_text(rotate_left, "Rotate View Left ([)");
        const rotate_right = c.gtk_button_new_from_icon_name("object-rotate-right-symbolic").?;
        c.gtk_widget_set_tooltip_text(rotate_right, "Rotate View Right (])");
        const play_button = c.gtk_button_new_from_icon_name("media-playback-pause-symbolic").?;
        c.gtk_widget_set_tooltip_text(play_button, "Pause or Resume Animation (Space)");
        c.gtk_widget_set_sensitive(play_button, 0);
        const fullscreen_button = c.gtk_button_new_from_icon_name("view-fullscreen-symbolic").?;
        c.gtk_widget_set_tooltip_text(fullscreen_button, "Fullscreen (F11)");
        const menu_button = c.gtk_menu_button_new().?;
        c.gtk_menu_button_set_icon_name(@ptrCast(menu_button), "open-menu-symbolic");
        c.gtk_widget_set_tooltip_text(menu_button, "Image Actions");
        const action_popover = c.gtk_popover_new().?;
        const action_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
        c.gtk_widget_set_margin_start(action_box, 6);
        c.gtk_widget_set_margin_end(action_box, 6);
        c.gtk_widget_set_margin_top(action_box, 6);
        c.gtk_widget_set_margin_bottom(action_box, 6);
        const metadata_label = c.gtk_label_new("Image metadata appears here after loading").?;
        c.gtk_label_set_xalign(@ptrCast(metadata_label), 0);
        c.gtk_label_set_wrap(@ptrCast(metadata_label), 1);
        c.gtk_label_set_selectable(@ptrCast(metadata_label), 1);
        c.gtk_widget_set_size_request(metadata_label, 280, -1);
        c.gtk_widget_set_margin_start(metadata_label, 8);
        c.gtk_widget_set_margin_end(metadata_label, 8);
        c.gtk_widget_set_margin_top(metadata_label, 4);
        c.gtk_widget_set_margin_bottom(metadata_label, 6);
        c.gtk_widget_add_css_class(metadata_label, "dim-label");
        c.gtk_box_append(@ptrCast(action_box), metadata_label);
        c.gtk_box_append(@ptrCast(action_box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL).?);
        const copy_button = actionButton(action_box, "Copy Image", "edit-copy-symbolic");
        const open_with_button = actionButton(action_box, "Open With...", "document-open-symbolic");
        const reveal_button = actionButton(action_box, "Show in Sketerm Files", "folder-open-symbolic");
        const reload_button = actionButton(action_box, "Reload", "view-refresh-symbolic");
        c.gtk_popover_set_child(@ptrCast(action_popover), action_box);
        c.gtk_menu_button_set_popover(@ptrCast(menu_button), action_popover);
        c.adw_header_bar_pack_end(@ptrCast(header), menu_button);
        c.adw_header_bar_pack_end(@ptrCast(header), fullscreen_button);
        c.adw_header_bar_pack_end(@ptrCast(header), play_button);
        c.adw_header_bar_pack_end(@ptrCast(header), rotate_right);
        c.adw_header_bar_pack_end(@ptrCast(header), rotate_left);
        c.adw_header_bar_pack_end(@ptrCast(header), actual_button);
        c.adw_header_bar_pack_end(@ptrCast(header), fill_button);
        c.adw_header_bar_pack_end(@ptrCast(header), fit_button);
        c.adw_header_bar_pack_end(@ptrCast(header), zoom_in);
        c.adw_header_bar_pack_end(@ptrCast(header), @ptrCast(@alignCast(zoom_label)));
        c.adw_header_bar_pack_end(@ptrCast(header), zoom_out);
        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), header);

        var canvas = image_canvas.Canvas.init();
        const content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        c.gtk_widget_set_vexpand(canvas.widget(), 1);
        c.gtk_box_append(@ptrCast(content), canvas.widget());
        const cast_slot = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        c.gtk_widget_set_vexpand(cast_slot, 1);
        c.gtk_widget_set_visible(cast_slot, 0);
        c.gtk_box_append(@ptrCast(content), cast_slot);
        const footer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10).?;
        c.gtk_widget_set_margin_start(footer, 12);
        c.gtk_widget_set_margin_end(footer, 12);
        c.gtk_widget_set_margin_top(footer, 6);
        c.gtk_widget_set_margin_bottom(footer, 8);
        const position = c.gtk_label_new("").?;
        c.gtk_widget_add_css_class(position, "dim-label");
        const status = c.gtk_label_new("Open an image to begin").?;
        c.gtk_label_set_ellipsize(@ptrCast(status), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_xalign(@ptrCast(status), 0);
        c.gtk_widget_set_hexpand(status, 1);
        const original = c.gtk_button_new_with_label("View full resolution").?;
        c.gtk_widget_set_visible(original, 0);
        c.gtk_box_append(@ptrCast(footer), position);
        c.gtk_box_append(@ptrCast(footer), status);
        c.gtk_box_append(@ptrCast(footer), original);
        c.gtk_box_append(@ptrCast(content), footer);
        c.adw_toolbar_view_set_content(@ptrCast(toolbar), content);
        c.adw_application_window_set_content(@ptrCast(window), toolbar);

        const target = LoadTarget.create(&onLoaded, @ptrCast(self)) orelse return error.OutOfMemory;
        errdefer target.close();
        const open_target = LoadTarget.create(&onOpenCopyLoaded, @ptrCast(self)) orelse return error.OutOfMemory;
        errdefer open_target.close();
        self.* = .{
            .allocator = allocator,
            .window = window,
            .batch = batch,
            .index = batch.initial_index,
            .canvas = canvas,
            .target = target,
            .open_target = open_target,
            .status = @ptrCast(@alignCast(status)),
            .position = @ptrCast(@alignCast(position)),
            .zoom_label = @ptrCast(@alignCast(zoom_label)),
            .original_button = original,
            .play_button = play_button,
            .metadata_label = @ptrCast(@alignCast(metadata_label)),
            .prev_button = prev_button,
            .next_button = next_button,
            .cast_slot = cast_slot,
            .image_controls = .{
                zoom_out,    @ptrCast(@alignCast(zoom_label)), zoom_in,     fit_button,
                fill_button, actual_button,                    rotate_left, rotate_right,
                play_button, menu_button,
            },
        };
        self.canvas.enableInput();
        self.canvas.on_zoom = &onCanvasZoom;
        self.canvas.zoom_ctx = @ptrCast(self);
        self.canvas.on_navigate = &onCanvasNavigate;
        self.canvas.navigate_ctx = @ptrCast(self);
        self.canvas.on_rotate = &onCanvasRotate;
        self.canvas.rotate_ctx = @ptrCast(self);
        try self.session.attach(allocator, &self.canvas);
        self.session.setPlaybackCallback(@ptrCast(self), &onSessionPlaybackChanged);

        c.g_object_set_data_full(@ptrCast(window), VIEWER_QDATA, @ptrCast(self), @ptrCast(&destroyViewer));
        // Cast content's surface timers and terminal sinks reach into
        // widgets; fence them the moment the window starts dying, not
        // at finalize (same contract as castview.zig).
        _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onWindowDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(open_button, "clicked", @ptrCast(&onOpenClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(prev_button, "clicked", @ptrCast(&onPrevious), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(next_button, "clicked", @ptrCast(&onNext), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(zoom_out, "clicked", @ptrCast(&onZoomOut), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(zoom_in, "clicked", @ptrCast(&onZoomIn), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(fit_button, "clicked", @ptrCast(&onFit), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(fill_button, "clicked", @ptrCast(&onFill), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(actual_button, "clicked", @ptrCast(&onActual), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(rotate_left, "clicked", @ptrCast(&onRotateLeft), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(rotate_right, "clicked", @ptrCast(&onRotateRight), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(play_button, "clicked", @ptrCast(&onPlayPause), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(fullscreen_button, "clicked", @ptrCast(&onFullscreen), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(original, "clicked", @ptrCast(&onOriginal), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(copy_button, "clicked", @ptrCast(&onCopy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(open_with_button, "clicked", @ptrCast(&onOpenWith), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(reveal_button, "clicked", @ptrCast(&onReveal), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(reload_button, "clicked", @ptrCast(&onReload), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        const keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(window, @ptrCast(keys));

        // Right-click / Menu key on the image itself. Every row
        // forwards to the header or hamburger button that already
        // implements it, so the menu adds no second copy of any
        // action and inherits each button's sensitivity.
        self.canvas_menu = try attachCanvasMenu(allocator, self.canvas.widget(), &.{
            .{ .row = .{ .label = "Copy Image", .icon = "edit-copy-symbolic", .source = copy_button } },
            .{ .row = .{ .label = "Open With…", .icon = "document-open-symbolic", .source = open_with_button } },
            .{ .row = .{ .label = "Show in Sketerm Files", .icon = "folder-open-symbolic", .source = reveal_button } },
            .{ .row = .{ .label = "Reload", .icon = "view-refresh-symbolic", .source = reload_button } },
            .separator,
            .{ .row = .{ .label = "Fit to Window", .icon = "zoom-fit-best-symbolic", .source = fit_button } },
            .{ .row = .{ .label = "Actual Size", .icon = "zoom-original-symbolic", .source = actual_button } },
            .{ .row = .{ .label = "Fill Window", .icon = "view-fullscreen-symbolic", .source = fill_button } },
            .{ .row = .{ .label = "Zoom In", .icon = "zoom-in-symbolic", .source = zoom_in } },
            .{ .row = .{ .label = "Zoom Out", .icon = "zoom-out-symbolic", .source = zoom_out } },
            .separator,
            .{ .row = .{ .label = "Rotate Left", .icon = "object-rotate-left-symbolic", .source = rotate_left } },
            .{ .row = .{ .label = "Rotate Right", .icon = "object-rotate-right-symbolic", .source = rotate_right } },
            .{ .row = .{ .label = "Pause / Resume Animation", .icon = "media-playback-pause-symbolic", .source = play_button } },
            .separator,
            .{ .row = .{ .label = "Previous Image", .icon = "go-previous-symbolic", .source = prev_button } },
            .{ .row = .{ .label = "Next Image", .icon = "go-next-symbolic", .source = next_button } },
            .{ .row = .{ .label = "View Full Resolution", .icon = "zoom-in-symbolic", .source = original } },
            .{ .row = .{ .label = "Fullscreen", .icon = "view-fullscreen-symbolic", .source = fullscreen_button } },
        });

        self.showCurrent();
        c.gtk_window_present(@ptrCast(window));
        return self;
    }

    fn destroyViewer(user: ?*anyopaque) callconv(.c) void {
        const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
        // Finalize path: the widget tree is already gone, so free the
        // controller without touching the cast_slot (onWindowDestroy
        // severed the timers/sinks when the window started dying).
        switch (self.content) {
            .cast => |box| box.destroy(),
            .image => {},
        }
        if (self.pending_mount) |pending| pending.viewer = null;
        self.pending_mount = null;
        self.open_target.close();
        self.target.close();
        self.session.deinit(self.allocator);
        self.batch.deinit();
        self.allocator.destroy(self);
    }

    fn current(self: *ViewerWindow) ?model.Resource {
        if (self.index >= self.batch.specs.len) return null;
        return model.Resource.parse(self.batch.specs[self.index]);
    }

    fn onWindowDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
        switch (self.content) {
            .cast => |box| box.severLive(),
            .image => {},
        }
    }

    /// Show or hide the image-mode chrome (canvas + header controls)
    /// against the cast slot.
    fn setContentMode(self: *ViewerWindow, image: bool) void {
        c.gtk_widget_set_visible(self.canvas.widget(), @intFromBool(image));
        c.gtk_widget_set_visible(self.cast_slot, @intFromBool(!image));
        for (self.image_controls) |w| c.gtk_widget_set_visible(w, @intFromBool(image));
        if (!image) c.gtk_widget_set_visible(self.original_button, 0);
    }

    /// Tear down the outgoing cast controller COMPLETELY: fence the
    /// timers/sinks, let the widgets die (removal from the slot is
    /// their last reference), then kill the ephemeral session and free
    /// the controller. Safe to call in any content mode.
    fn closeCast(self: *ViewerWindow) void {
        const box = switch (self.content) {
            .cast => |b| b,
            .image => return,
        };
        self.content = .image;
        box.severLive();
        c.gtk_box_remove(@ptrCast(self.cast_slot), box.surfaceWidget());
        c.gtk_box_remove(@ptrCast(self.cast_slot), box.barWidget());
        box.destroy();
        self.cast_title_len = 0;
        self.setContentMode(true);
    }

    fn showCast(self: *ViewerWindow, resource: model.Resource) void {
        // A still-running image load must not deliver into cast mode.
        self.target.cancel();
        c.gtk_label_set_text(self.metadata_label, "Asciicast terminal recording");
        c.gtk_label_set_text(self.status, "Loading recording...");
        const box = castbox.CastPlayerBox.create(self.allocator, resource.spec, "sketerm view", .{
            .ctx = @ptrCast(self),
            .on_title = &onCastTitle,
            .on_state = &onCastState,
        }) catch |err| {
            var buf: [256:0]u8 = undefined;
            const text = std.fmt.bufPrintZ(&buf, "Unable to play {s}: {s}", .{
                resource.name(), @errorName(err),
            }) catch "Unable to play the recording";
            c.gtk_label_set_text(self.status, text.ptr);
            return;
        };
        self.content = .{ .cast = box };
        c.gtk_widget_set_tooltip_text(box.scale, "Seek (,/. 5s, </> 30s)");
        c.gtk_box_append(@ptrCast(self.cast_slot), box.surfaceWidget());
        c.gtk_box_append(@ptrCast(self.cast_slot), box.barWidget());
        self.setContentMode(false);
    }

    fn showCurrent(self: *ViewerWindow) void {
        self.closeCast();
        self.session.clear();
        self.canvas.fit();
        c.gtk_widget_set_sensitive(self.play_button, 0);
        c.gtk_label_set_text(self.metadata_label, "Loading image metadata...");
        c.gtk_widget_set_visible(self.original_button, 0);
        const resource = self.current() orelse {
            c.gtk_label_set_text(self.status, "Open an image to begin");
            c.gtk_label_set_text(self.position, "");
            c.gtk_widget_set_sensitive(self.prev_button, 0);
            c.gtk_widget_set_sensitive(self.next_button, 0);
            self.canvas.setAccessible("Image viewer", "No image open", false);
            return;
        };
        var title: [512:0]u8 = undefined;
        const title_z = std.fmt.bufPrintZ(&title, "{s} - {s}", .{ resource.name(), model.APP_NAME }) catch model.APP_NAME;
        c.gtk_window_set_title(@ptrCast(self.window), title_z.ptr);
        var pos: [64:0]u8 = undefined;
        const pos_z = std.fmt.bufPrintZ(&pos, "{d} of {d}", .{ self.index + 1, self.batch.specs.len }) catch "";
        c.gtk_label_set_text(self.position, pos_z.ptr);
        c.gtk_widget_set_sensitive(self.prev_button, @intFromBool(self.index > 0));
        c.gtk_widget_set_sensitive(self.next_button, @intFromBool(self.index + 1 < self.batch.specs.len));
        // Route by classification BEFORE any image load starts.
        if (paths.isCastName(resource.name())) return self.showCast(resource);
        c.gtk_label_set_text(self.status, "Loading preview...");
        self.canvas.setAccessible(resource.name(), "Loading preview", true);
        if (!self.target.start(resource.spec, .preview)) c.gtk_label_set_text(self.status, "Could not start preview loader");
    }

    fn loadOriginal(self: *ViewerWindow) void {
        const resource = self.current() orelse return;
        c.gtk_widget_set_sensitive(self.original_button, 0);
        c.gtk_label_set_text(self.status, "Loading full resolution through the file service...");
        self.canvas.setAccessible(resource.name(), "Loading full resolution", true);
        if (!self.target.start(resource.spec, .original)) {
            c.gtk_widget_set_sensitive(self.original_button, 1);
            c.gtk_label_set_text(self.status, "Could not start full-resolution loader");
        }
    }

    fn move(self: *ViewerWindow, delta: isize) void {
        if (self.batch.specs.len == 0) return;
        const next = @as(isize, @intCast(self.index)) + delta;
        if (next < 0 or next >= @as(isize, @intCast(self.batch.specs.len))) return;
        self.index = @intCast(next);
        self.showCurrent();
    }

    fn replaceWithLocal(self: *ViewerWindow, path: []const u8) void {
        var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
        self.replaceWithSpec(paths.formatSpec(&buf, null, path));
    }

    /// Show a host-qualified spec as the whole batch. The viewer is
    /// remote-capable end to end (`showCurrent` dispatches on
    /// `resource.host`), so a picked `user@box:/path` needs no local
    /// copy up front.
    fn replaceWithSpec(self: *ViewerWindow, spec_in: []const u8) void {
        const loc = paths.parseSpec(spec_in);
        if (loc.host == null and paths.isSketermMount(loc.path)) {
            c.gtk_label_set_text(self.status, "Sketerm mount paths are refused; open the original host:/path resource instead");
            return;
        }
        const spec = self.allocator.dupe(u8, spec_in) catch return;
        const one = self.allocator.alloc([]u8, 1) catch {
            self.allocator.free(spec);
            return;
        };
        one[0] = spec;
        self.batch.deinit();
        self.batch = .{ .allocator = self.allocator, .specs = one };
        self.index = 0;
        self.showCurrent();
    }

    fn rotate(self: *ViewerWindow, delta: i8) void {
        self.session.rotate(delta);
        self.updateAccessibleState();
    }

    fn updatePlaybackButton(self: *ViewerWindow) void {
        const animated = self.session.animated();
        c.gtk_widget_set_sensitive(self.play_button, @intFromBool(animated));
        c.gtk_button_set_icon_name(@ptrCast(self.play_button), if (self.session.isPlaying())
            "media-playback-pause-symbolic"
        else
            "media-playback-start-symbolic");
    }

    fn updateAccessibleState(self: *ViewerWindow) void {
        const resource = self.current() orelse return;
        var detail: [256:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&detail, "Item {d} of {d}; rotation {d} degrees{s}", .{
            self.index + 1,
            self.batch.specs.len,
            self.session.rotationDegrees(),
            if (self.session.animated()) if (self.session.isPlaying()) "; animation playing" else "; animation paused" else "",
        }) catch "Image loaded";
        self.canvas.setAccessible(resource.name(), text, false);
    }
};

/// One image-canvas context-menu entry: either a separator, or a row
/// that MIRRORS an existing toolbar / hamburger button. Mirroring
/// rather than re-implementing is deliberate — the row activates the
/// source button, so the action, its handler and its sensitivity all
/// stay single-sourced.
pub const CanvasMenuItem = union(enum) {
    separator,
    row: struct {
        label: [*:0]const u8,
        icon: [*:0]const u8,
        source: *c.GtkWidget,
    },
};

const MAX_CANVAS_MENU_ROWS = 24;

/// Owns the canvas popover and the row→source mapping. Freed by the
/// click gesture's GDestroyNotify, which fires when the controller is
/// removed from the canvas — i.e. when the canvas widget dies.
const CanvasMenu = struct {
    allocator: std.mem.Allocator,
    host: *c.GtkWidget,
    popover: *c.GtkWidget,
    rows: [MAX_CANVAS_MENU_ROWS]?*c.GtkWidget = @splat(null),
    sources: [MAX_CANVAS_MENU_ROWS]?*c.GtkWidget = @splat(null),
    n: usize = 0,
};

/// Per-row signal context. Heap-allocated, so it carries its own
/// allocator and is released through `freeCanvasRow`.
const CanvasRowCtx = struct {
    allocator: std.mem.Allocator,
    menu: *CanvasMenu,
    source: *c.GtkWidget,
};

/// Give `host` a right-click (and Menu-key) context menu built from
/// `items`. Rows past MAX_CANVAS_MENU_ROWS are ignored rather than
/// overflowing; the compile-time assert keeps that from going unseen.
fn attachCanvasMenu(
    allocator: std.mem.Allocator,
    host: *c.GtkWidget,
    items: []const CanvasMenuItem,
) !*CanvasMenu {
    const popover = c.gtk_popover_new().?;
    c.gtk_widget_set_parent(popover, host);
    c.gtk_popover_set_has_arrow(@ptrCast(popover), 0);

    const menu = try allocator.create(CanvasMenu);
    errdefer allocator.destroy(menu);
    menu.* = .{ .allocator = allocator, .host = host, .popover = popover };

    const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
    for (items) |item| switch (item) {
        .separator => c.gtk_box_append(@ptrCast(list), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL).?),
        .row => |r| {
            if (menu.n >= MAX_CANVAS_MENU_ROWS) continue;
            const btn = actionButton(list, r.label, r.icon);
            const rctx = try allocator.create(CanvasRowCtx);
            rctx.* = .{ .allocator = allocator, .menu = menu, .source = r.source };
            _ = c.g_signal_connect_data(
                btn,
                "clicked",
                @ptrCast(&onCanvasRowClicked),
                @ptrCast(rctx),
                @ptrCast(&freeCanvasRow),
                c.G_CONNECT_DEFAULT,
            );
            menu.rows[menu.n] = btn;
            menu.sources[menu.n] = r.source;
            menu.n += 1;
        },
    };
    // Same GTK4 popover-sizing trap menu.zig documents: a bare box's
    // MINIMUM height is the whole list, and a popover whose minimum
    // does not fit the granted space is silently popped down.
    const scroller = c.gtk_scrolled_window_new().?;
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_propagate_natural_width(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), list);
    c.gtk_popover_set_child(@ptrCast(popover), scroller);

    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 3);
    _ = c.g_signal_connect_data(
        click,
        "pressed",
        @ptrCast(&onCanvasRightClick),
        @ptrCast(menu),
        @ptrCast(&freeCanvasMenu),
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(host, @ptrCast(click));
    // Dismissing without picking anything (Escape, click-away) must
    // not strand focus in the dead popover.
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&onCanvasMenuClosed), @ptrCast(menu), null, c.G_CONNECT_DEFAULT);
    return menu;
}

fn onCanvasMenuClosed(_: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
    const menu: *CanvasMenu = @ptrCast(@alignCast(user.?));
    const root = c.gtk_widget_get_root(menu.host) orelse return;
    const focus = c.gtk_root_get_focus(@ptrCast(root));
    // Only reclaim focus that is still inside the popover — a row
    // that opened a dialog has already moved it somewhere better.
    const inside = focus == null or
        focus == menu.popover or
        c.gtk_widget_is_ancestor(focus, menu.popover) != 0;
    if (inside) _ = c.gtk_widget_grab_focus(menu.host);
}

/// Refresh every row's sensitivity from its source button, then pop
/// up at (x, y). Reading the source each time is what keeps the menu
/// honest: "Next Image" greys out on the last image, "Pause" while no
/// animation is loaded, exactly as the toolbar does.
fn showCanvasMenu(menu: *CanvasMenu, x: f64, y: f64) void {
    for (menu.rows[0..menu.n], menu.sources[0..menu.n]) |maybe_row, maybe_src| {
        const row = maybe_row orelse continue;
        const src = maybe_src orelse continue;
        const usable = c.gtk_widget_get_sensitive(src) != 0 and c.gtk_widget_get_visible(src) != 0;
        c.gtk_widget_set_sensitive(row, @intFromBool(usable));
    }
    var rect = c.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(menu.popover), &rect);
    c.gtk_popover_popup(@ptrCast(menu.popover));
}

fn onCanvasRightClick(g: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const menu: *CanvasMenu = @ptrCast(@alignCast(user.?));
    // Claim before popup — an unclaimed RELEASE reads as a click
    // outside the fresh popover and dismisses it (see menu.zig).
    _ = c.gtk_gesture_set_state(@ptrCast(@alignCast(g)), c.GTK_EVENT_SEQUENCE_CLAIMED);
    showCanvasMenu(menu, x, y);
}

/// Keyboard path: the viewer's window-level key handler routes Menu /
/// Shift+F10 here. An image has no caret, so the popover is anchored
/// at the centre of the canvas.
fn showCanvasMenuCentred(menu: *CanvasMenu) void {
    const w: f64 = @floatFromInt(c.gtk_widget_get_width(menu.host));
    const h: f64 = @floatFromInt(c.gtk_widget_get_height(menu.host));
    showCanvasMenu(menu, w / 2.0, h / 2.0);
}

fn onCanvasRowClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const rctx: *CanvasRowCtx = @ptrCast(@alignCast(user.?));
    c.gtk_popover_popdown(@ptrCast(rctx.menu.popover));
    // Focus goes back to the canvas before the action runs, so a
    // dismissed menu never leaves the keyboard stranded in a dead
    // popover. An action that opens its own dialog takes focus after.
    _ = c.gtk_widget_grab_focus(rctx.menu.host);
    _ = c.gtk_widget_activate(rctx.source);
}

fn freeCanvasRow(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const rctx: *CanvasRowCtx = @ptrCast(@alignCast(u));
        rctx.allocator.destroy(rctx);
    }
}

fn freeCanvasMenu(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const menu: *CanvasMenu = @ptrCast(@alignCast(u));
        // A popover added with gtk_widget_set_parent must be
        // unparented before the host finalizes, or GTK warns about
        // leftover children (same rule as menu.zig's freeClickCtx).
        if (c.gtk_widget_get_parent(menu.popover) != null) c.gtk_widget_unparent(menu.popover);
        menu.allocator.destroy(menu);
    }
}

fn actionButton(box: *c.GtkWidget, label: [*:0]const u8, icon: [*:0]const u8) *c.GtkWidget {
    const button = c.gtk_button_new().?;
    c.gtk_button_set_has_frame(@ptrCast(button), 0);
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
    c.gtk_box_append(@ptrCast(row), c.gtk_image_new_from_icon_name(icon).?);
    const text = c.gtk_label_new(label).?;
    c.gtk_label_set_xalign(@ptrCast(text), 0);
    c.gtk_widget_set_hexpand(text, 1);
    c.gtk_box_append(@ptrCast(row), text);
    c.gtk_button_set_child(@ptrCast(button), row);
    c.gtk_box_append(@ptrCast(box), button);
    return button;
}

fn onLoaded(user: ?*anyopaque, result: *LoadResult) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    const image = if (result.decoded) |*decoded_image| decoded_image else {
        if (result.variant == .preview) {
            if (self.current()) |resource| {
                c.gtk_label_set_text(self.status, "Preview unavailable; loading the original image...");
                if (self.target.start(resource.spec, .original)) return;
            }
        }
        var message: [256:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&message, "Unable to load {s}: {s}", .{
            if (result.variant == .preview) "preview" else "full resolution",
            result.messageText(),
        }) catch "Unable to load image";
        c.gtk_label_set_text(self.status, text.ptr);
        if (self.current()) |resource| self.canvas.setAccessible(resource.name(), text, false);
        if (result.variant == .original) {
            c.gtk_widget_set_sensitive(self.original_button, 1);
            c.gtk_widget_set_visible(self.original_button, 1);
        }
        return;
    };
    self.session.setDecoded(self.allocator, image) catch {
        c.gtk_label_set_text(self.status, "Unable to create image textures");
        if (self.current()) |resource| self.canvas.setAccessible(resource.name(), "Unable to create image textures", false);
        return;
    };
    const first = image.first();
    self.updatePlaybackButton();
    if (result.metadata_len > 0)
        c.gtk_label_set_text(self.metadata_label, result.metadataText().ptr)
    else
        c.gtk_label_set_text(self.metadata_label, "No embedded image metadata");
    var status: [256:0]u8 = undefined;
    const backend = switch (image.backend) {
        .glycin => "Glycin",
        .gdk_pixbuf => "GdkPixbuf",
    };
    var size_buf: [48]u8 = undefined;
    const text = std.fmt.bufPrintZ(&status, "{s}  {d} x {d}  {s}  {s}{s}", .{
        if (result.variant == .preview) "Preview" else "Full resolution",
        first.width,
        first.height,
        backend,
        formatBytes(&size_buf, result.source_bytes),
        if (image.animated()) "  Animated" else "",
    }) catch "Image loaded";
    c.gtk_label_set_text(self.status, text.ptr);
    c.gtk_widget_set_visible(self.original_button, @intFromBool(result.variant == .preview));
    c.gtk_widget_set_sensitive(self.original_button, 1);
    self.updateAccessibleState();
    if (result.variant == .preview) {
        if (self.current()) |resource| {
            if (resource.host == null and mayAnimate(resource.name())) {
                c.gtk_widget_set_sensitive(self.original_button, 0);
                c.gtk_label_set_text(self.status, "Preview ready; loading animation and full resolution...");
                if (self.target.start(resource.spec, .original)) return;
                c.gtk_widget_set_sensitive(self.original_button, 1);
            }
        }
    }
}

fn onOpenCopyLoaded(user: ?*anyopaque, result: *LoadResult) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    if (result.materialized_len == 0) {
        var buf: [256:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "Could not prepare the remote image: {s}", .{result.messageText()}) catch
            "Could not prepare the remote image";
        c.gtk_label_set_text(self.status, text.ptr);
        return;
    }
    if (showAppChooserPath(self, result.materialized[0..result.materialized_len], true)) {
        result.materialized_len = 0;
        c.gtk_label_set_text(self.status, "Remote image ready for an external application");
    }
}

fn formatBytes(buf: []u8, bytes: usize) []const u8 {
    if (bytes >= 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MiB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024)}) catch "";
    if (bytes >= 1024) return std.fmt.bufPrint(buf, "{d:.1} KiB", .{@as(f64, @floatFromInt(bytes)) / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
}

fn mayAnimate(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".gif") or std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".apng") or std.ascii.eqlIgnoreCase(ext, ".webp") or
        std.ascii.eqlIgnoreCase(ext, ".avif") or std.ascii.eqlIgnoreCase(ext, ".jxl");
}

fn onCanvasZoom(user: ?*anyopaque, zoom: f64, mode: model.Viewport.Mode) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    if (mode == .fit) return c.gtk_label_set_text(self.zoom_label, "Fit");
    if (mode == .fill) return c.gtk_label_set_text(self.zoom_label, "Fill");
    var buf: [24:0]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "{d}%", .{@as(u32, @intFromFloat(@round(zoom * 100)))}) catch "";
    c.gtk_label_set_text(self.zoom_label, text.ptr);
}

fn onPrevious(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.move(-1);
}

fn onNext(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.move(1);
}

fn onZoomOut(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.canvas.zoomBy(1.0 / 1.2);
}

fn onZoomIn(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.canvas.zoomBy(1.2);
}

fn onFit(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.canvas.fit();
}

fn onFill(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.canvas.fill();
}

fn onActual(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.canvas.actual();
}

fn onOriginal(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.loadOriginal();
}

fn onRotateLeft(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.rotate(-1);
}

fn onRotateRight(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.rotate(1);
}

fn onPlayPause(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.session.togglePlayback();
}

fn onCastTitle(user: ?*anyopaque, name: []const u8) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    const n = @min(name.len, self.cast_title.len);
    @memcpy(self.cast_title[0..n], name[0..n]);
    self.cast_title_len = n;
    var buf: [600:0]u8 = undefined;
    const t = std.fmt.bufPrintZ(&buf, "{s} - {s}", .{ name, model.APP_NAME }) catch model.APP_NAME;
    c.gtk_window_set_title(@ptrCast(self.window), t.ptr);
}

/// Status line for casts: recording title + position/duration, where
/// images show dimensions.
fn onCastState(user: ?*anyopaque, st: Terminal.PlayState) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    const title = self.cast_title[0..self.cast_title_len];
    var buf: [700:0]u8 = undefined;
    const suffix: []const u8 = switch (st.kind) {
        .paused => "  Paused",
        .finished => "  Finished",
        .seeking => "  Seeking...",
        .playing => "",
    };
    const text = if (st.duration_ms) |d|
        std.fmt.bufPrintZ(&buf, "{s}  {d}:{d:0>2} / {d}:{d:0>2}{s}", .{
            title,
            st.position_ms / 60_000, (st.position_ms / 1000) % 60,
            d / 60_000,              (d / 1000) % 60,
            suffix,
        }) catch return
    else
        std.fmt.bufPrintZ(&buf, "{s}  {d}:{d:0>2} / --:--{s}", .{
            title, st.position_ms / 60_000, (st.position_ms / 1000) % 60, suffix,
        }) catch return;
    c.gtk_label_set_text(self.status, text.ptr);
}

fn onSessionPlaybackChanged(user: ?*anyopaque) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.updatePlaybackButton();
    self.updateAccessibleState();
}

fn onCanvasNavigate(user: ?*anyopaque, delta: isize) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.move(delta);
}

fn onCanvasRotate(user: ?*anyopaque, delta: i8) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.rotate(delta);
}

fn onCopy(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    const texture = self.session.currentTexture() orelse return;
    const clipboard = c.gtk_widget_get_clipboard(self.window) orelse return;
    c.gdk_clipboard_set_texture(clipboard, texture);
    c.gtk_label_set_text(self.status, "Image copied to clipboard");
}

fn onReload(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.showCurrent();
}

fn onOpenWith(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    const resource = self.current() orelse return;
    if (resource.host) |host| return openWithRemote(self, host, resource.path);
    showAppChooser(self, resource.path);
}

fn onReveal(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    revealCurrent(self);
}

fn onFullscreen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    toggleFullscreen(self);
}

fn toggleFullscreen(self: *ViewerWindow) void {
    self.fullscreen = !self.fullscreen;
    if (self.fullscreen)
        c.gtk_window_fullscreen(@ptrCast(self.window))
    else
        c.gtk_window_unfullscreen(@ptrCast(self.window));
}

fn onOpenClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    // The ref keeps the window (and the qdata that resolves back to
    // `self`) alive until the one-shot callback runs.
    _ = c.g_object_ref(@ptrCast(self.window));
    _ = @import("picker.zig").PickerWindow.open(
        self.allocator,
        @ptrCast(@alignCast(self.window)),
        .{
            .mode = .open_file,
            .title = "Open Image",
            .filters = &.{
                .{ .label = "Images", .patterns = &.{
                    "*.png",   "*.jpg",  "*.jpeg", "*.gif",  "*.webp",
                    "*.jxl",   "*.bmp",  "*.svg",  "*.ico",  "*.tif",
                    "*.tiff",  "*.avif", "*.heic", "*.heif",
                } },
                .{ .label = "Recordings", .patterns = &.{"*.cast"} },
            },
        },
        &onOpenDone,
        @ptrCast(self.window),
    ) catch {
        c.g_object_unref(@ptrCast(self.window));
        return;
    };
}

fn onOpenDone(user: ?*anyopaque, result: ?@import("../filebrowser/picker.zig").Result) void {
    const window: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    defer c.g_object_unref(@ptrCast(window));
    const res = result orelse return;
    if (res.specs.len == 0) return;
    const data = c.g_object_get_data(@ptrCast(window), VIEWER_QDATA) orelse return;
    const self: *ViewerWindow = @ptrCast(@alignCast(data));
    // Remote picks are PASSED THROUGH: the viewer loads `host:/path`
    // resources natively (daemon-backed), so refusing them here would
    // remove a capability it already has.
    self.replaceWithSpec(res.specs[0]);
}

fn onKey(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    // Keyboard access to the canvas context menu. Handled here rather
    // than on the canvas because this controller runs in CAPTURE
    // phase on the window and would otherwise swallow the keys first.
    if (keyval == c.GDK_KEY_Menu or
        (keyval == c.GDK_KEY_F10 and (state & c.GDK_SHIFT_MASK) != 0))
    {
        if (self.content != .image) return 0; // the menu mirrors image controls
        const menu = self.canvas_menu orelse return 0;
        showCanvasMenuCentred(menu);
        return 1;
    }
    // Cast content: Left/Right stay batch navigation (consistency in
    // mixed batches — the STANDALONE play window seeks with arrows);
    // seeking is ,/. (5s) and </> (30s), Space toggles, R restarts.
    switch (self.content) {
        .cast => |box| {
            switch (keyval) {
                c.GDK_KEY_Left => self.move(-1),
                c.GDK_KEY_Right => self.move(1),
                c.GDK_KEY_space, c.GDK_KEY_KP_Space => box.togglePlay(),
                c.GDK_KEY_comma => box.seekRelative(-5_000),
                c.GDK_KEY_period => box.seekRelative(5_000),
                c.GDK_KEY_less => box.seekRelative(-30_000),
                c.GDK_KEY_greater => box.seekRelative(30_000),
                c.GDK_KEY_r, c.GDK_KEY_R => box.restart(),
                c.GDK_KEY_F11 => toggleFullscreen(self),
                c.GDK_KEY_Escape => if (self.fullscreen) toggleFullscreen(self) else return 0,
                else => return 0,
            }
            return 1;
        },
        .image => {},
    }
    switch (keyval) {
        c.GDK_KEY_Left => self.move(-1),
        c.GDK_KEY_Right => self.move(1),
        c.GDK_KEY_plus, c.GDK_KEY_equal, c.GDK_KEY_KP_Add => self.canvas.zoomBy(1.2),
        c.GDK_KEY_minus, c.GDK_KEY_KP_Subtract => self.canvas.zoomBy(1.0 / 1.2),
        c.GDK_KEY_0, c.GDK_KEY_KP_0 => self.canvas.actual(),
        c.GDK_KEY_f, c.GDK_KEY_F => self.canvas.fit(),
        c.GDK_KEY_c, c.GDK_KEY_C => self.canvas.fill(),
        c.GDK_KEY_bracketleft => self.rotate(-1),
        c.GDK_KEY_bracketright => self.rotate(1),
        c.GDK_KEY_space, c.GDK_KEY_KP_Space => if (self.session.animated()) {
            self.session.togglePlayback();
        } else return 0,
        c.GDK_KEY_r, c.GDK_KEY_R => self.showCurrent(),
        c.GDK_KEY_F11 => toggleFullscreen(self),
        c.GDK_KEY_Escape => if (self.fullscreen) toggleFullscreen(self) else return 0,
        else => return 0,
    }
    return 1;
}

const APP_CHOOSER_FILE = "sketerm-viewer-app-file";

fn showAppChooser(self: *ViewerWindow, path: []const u8) void {
    _ = showAppChooserPath(self, path, false);
}

const ChooserCopy = struct {
    path: [:0]u8,
};

fn freeChooserCopy(user: ?*anyopaque) callconv(.c) void {
    const copy: *ChooserCopy = @ptrCast(@alignCast(user.?));
    _ = c.unlink(copy.path.ptr);
    std.heap.c_allocator.free(copy.path);
    std.heap.c_allocator.destroy(copy);
}

fn delayedChooserCopyCleanup(user: ?*anyopaque) callconv(.c) c.gboolean {
    freeChooserCopy(user);
    return 0;
}

fn showAppChooserPath(self: *ViewerWindow, path: []const u8, owned_copy: bool) bool {
    var path_buf: [4096:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
        c.gtk_label_set_text(self.status, "Path is too long for Open With");
        return false;
    };
    const file = c.g_file_new_for_path(path_z.ptr) orelse return false;
    const dialog = c.gtk_app_chooser_dialog_new(@ptrCast(self.window), c.GTK_DIALOG_MODAL, file) orelse {
        c.g_object_unref(file);
        return false;
    };
    _ = c.g_object_ref(file);
    c.g_object_set_data_full(@ptrCast(dialog), APP_CHOOSER_FILE, @ptrCast(file), @ptrCast(&c.g_object_unref));
    c.g_object_unref(file);
    if (owned_copy) {
        const allocator = std.heap.c_allocator;
        const copy = allocator.create(ChooserCopy) catch {
            c.gtk_window_destroy(@ptrCast(dialog));
            return false;
        };
        copy.* = .{ .path = allocator.dupeZ(u8, path) catch {
            allocator.destroy(copy);
            c.gtk_window_destroy(@ptrCast(dialog));
            return false;
        } };
        c.g_object_set_data_full(@ptrCast(dialog), "sketerm-viewer-open-copy", @ptrCast(copy), @ptrCast(&freeChooserCopy));
    }
    c.gtk_app_chooser_dialog_set_heading(@ptrCast(dialog), "Open image with another application");
    _ = c.g_signal_connect_data(dialog, "response", @ptrCast(&onAppChooserResponse), null, null, c.G_CONNECT_DEFAULT);
    c.gtk_window_present(@ptrCast(dialog));
    return true;
}

fn onAppChooserResponse(dialog: *c.GtkDialog, response: c_int, _: ?*anyopaque) callconv(.c) void {
    if (response == c.GTK_RESPONSE_OK) {
        const app = c.gtk_app_chooser_get_app_info(@ptrCast(dialog));
        const file_any = c.g_object_get_data(@ptrCast(dialog), APP_CHOOSER_FILE);
        if (app != null and file_any != null) {
            var files: ?*c.GList = null;
            files = c.g_list_append(files, file_any);
            _ = c.g_app_info_launch(app, files, null, null);
            c.g_list_free(files);
            c.g_object_unref(app);
            if (c.g_object_steal_data(@ptrCast(dialog), "sketerm-viewer-open-copy")) |raw| {
                if (c.g_timeout_add_seconds(60, @ptrCast(&delayedChooserCopyCleanup), raw) == 0)
                    freeChooserCopy(raw);
            }
        }
    }
    c.gtk_window_destroy(@ptrCast(dialog));
}

const MountOpen = struct {
    viewer: ?*ViewerWindow,
    host: []u8,
    path: []u8,
};

fn openWithRemote(self: *ViewerWindow, host: []const u8, path: []const u8) void {
    if (self.pending_mount != null) {
        c.gtk_label_set_text(self.status, "An external application handoff is already being prepared");
        return;
    }
    const allocator = std.heap.c_allocator;
    const pending = allocator.create(MountOpen) catch return;
    pending.* = .{
        .viewer = self,
        .host = allocator.dupe(u8, host) catch {
            allocator.destroy(pending);
            return;
        },
        .path = allocator.dupe(u8, path) catch {
            allocator.free(pending.host);
            allocator.destroy(pending);
            return;
        },
    };
    self.pending_mount = pending;
    c.gtk_label_set_text(self.status, "Preparing the remote file for an external application...");
    hostmount.whenReady(allocator, host, @ptrCast(pending), &onOpenWithMountReady);
}

fn onOpenWithMountReady(user: ?*anyopaque, mounted: bool) void {
    const pending: *MountOpen = @ptrCast(@alignCast(user.?));
    defer {
        const allocator = std.heap.c_allocator;
        allocator.free(pending.host);
        allocator.free(pending.path);
        allocator.destroy(pending);
    }
    const self = pending.viewer orelse return;
    if (self.pending_mount == pending) self.pending_mount = null;
    if (!mounted) {
        startOpenCopy(self, pending.host, pending.path);
        return;
    }
    var path_buf: [8192]u8 = undefined;
    const local = hostmount.localPath(&path_buf, pending.host, pending.path) orelse {
        startOpenCopy(self, pending.host, pending.path);
        return;
    };
    showAppChooser(self, local);
}

fn startOpenCopy(self: *ViewerWindow, host: []const u8, path: []const u8) void {
    const spec = paths.formatSpecAlloc(self.allocator, host, path) catch return;
    defer self.allocator.free(spec);
    c.gtk_label_set_text(self.status, "Mount unavailable; downloading a temporary copy...");
    if (!self.open_target.start(spec, .external_copy))
        c.gtk_label_set_text(self.status, "Could not start the temporary-copy download");
}

fn revealCurrent(self: *ViewerWindow) void {
    const resource = self.current() orelse return;
    const parent = std.fs.path.dirname(resource.path) orelse "/";
    const parent_spec = paths.formatSpecAlloc(self.allocator, resource.host, parent) catch return;
    defer self.allocator.free(parent_spec);
    const reveal_arg = std.fmt.allocPrintSentinel(self.allocator, "--select={s}", .{resource.spec}, 0) catch return;
    defer self.allocator.free(reveal_arg);
    var exe_buf: [4096:0]u8 = undefined;
    const exe = platform.exePathZ(&exe_buf) orelse return;
    var sibling_buf: [4096:0]u8 = undefined;
    const sibling: ?[:0]const u8 = blk: {
        const slash = std.mem.lastIndexOfScalar(u8, exe, '/') orelse break :blk null;
        const candidate = std.fmt.bufPrintZ(&sibling_buf, "{s}/sketerm-files", .{exe[0..slash]}) catch break :blk null;
        if (c.access(candidate.ptr, c.X_OK) != 0) break :blk null;
        break :blk candidate;
    };
    const parent_z = self.allocator.dupeZ(u8, parent_spec) catch return;
    defer self.allocator.free(parent_z);
    var argv: [6]?[*:0]u8 = @splat(null);
    var at: usize = 0;
    argv[at] = @constCast(if (sibling) |bin| bin.ptr else exe.ptr);
    at += 1;
    if (sibling == null) {
        argv[at] = @constCast(@as([*:0]const u8, "files"));
        at += 1;
    }
    argv[at] = parent_z.ptr;
    at += 1;
    argv[at] = reveal_arg.ptr;
    at += 1;
    var gerr: [*c]c.GError = null;
    if (c.g_spawn_async(null, @ptrCast(&argv), null, @intCast(c.G_SPAWN_DEFAULT), null, null, null, &gerr) == 0) {
        if (gerr != null) c.g_error_free(gerr);
        c.gtk_label_set_text(self.status, "Could not open Sketerm Files");
    } else c.gtk_label_set_text(self.status, "Showing image in Sketerm Files");
}
