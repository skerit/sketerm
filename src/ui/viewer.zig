//! Standalone Sketerm Viewer window and shared daemon-backed image loader.

const std = @import("std");
const c = @import("../c.zig").c;
const model = @import("../viewer.zig");
const paths = @import("../filebrowser/paths.zig");
const decoder = @import("image_decoder.zig");
const image_canvas = @import("image_canvas.zig");
const fsdrive = @import("../ipc/fsdrive.zig");
const muxclient = @import("../mux/client.zig");
const Config = @import("../config.zig").Config;

pub const Variant = enum { preview, original };
const PREVIEW_BYTES_MAX: usize = 2 << 20;
const ORIGINAL_BYTES_MAX: usize = 128 << 20;
const PREVIEW_PIXELS_MAX: usize = 4 * 1024 * 1024;
const ORIGINAL_PIXELS_MAX: usize = 64 * 1024 * 1024;
const LOAD_TIMEOUT_MS: i64 = 120_000;

pub const LoadResult = struct {
    variant: Variant,
    decoded: ?decoder.Decoded = null,
    source_bytes: usize = 0,
    message: [160]u8 = undefined,
    message_len: usize = 0,

    pub fn messageText(self: *const LoadResult) []const u8 {
        return self.message[0..self.message_len];
    }

    fn setError(self: *LoadResult, err: anyerror) void {
        const text = @errorName(err);
        self.message_len = @min(text.len, self.message.len);
        @memcpy(self.message[0..self.message_len], text[0..self.message_len]);
    }

    fn deinit(self: *LoadResult) void {
        if (self.decoded) |*image| image.deinit(std.heap.c_allocator);
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

fn fetch(work: *LoadWork) !struct { bytes: []u8, source_size: usize } {
    const spec = work.spec;
    const variant = work.variant;
    const resource = model.Resource.parse(spec);
    if (resource.host == null and paths.isSketermMount(resource.path))
        return error.SketermFusePathNotSupported;
    var fs = try connectFs(resource.host);
    defer fs.deinit();
    if (!work.target.registerFd(work.generation, fs.conn.fd)) return error.Canceled;
    defer work.target.clearFd(work.generation, fs.conn.fd);
    var probe_bytes: std.ArrayList(u8) = .empty;
    defer probe_bytes.deinit(std.heap.c_allocator);
    const source = try fs.read(resource.path, 0, 0, &probe_bytes);
    if (source.size > ORIGINAL_BYTES_MAX) return error.SourceTooLarge;
    if (variant == .original) {
        const bytes = try readAll(&fs, resource.path, ORIGINAL_BYTES_MAX);
        return .{ .source_size = bytes.len, .bytes = bytes };
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
    return .{ .source_size = bytes.len, .bytes = bytes };
}

fn loadThread(first: *LoadWork) void {
    const allocator = std.heap.c_allocator;
    var work = first;
    while (true) {
        work.result = .{ .variant = work.variant };
        if (fetch(work)) |payload| {
            defer allocator.free(payload.bytes);
            work.result.source_bytes = payload.source_size;
            if (work.target.current(work.generation)) {
                const max_pixels = if (work.variant == .preview) PREVIEW_PIXELS_MAX else ORIGINAL_PIXELS_MAX;
                work.result.decoded = decoder.decodeBytes(allocator, payload.bytes, max_pixels) catch |err| blk: {
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
    const bytes = c.g_bytes_new(image.rgba.ptr, image.rgba.len) orelse return null;
    defer c.g_bytes_unref(bytes);
    return @ptrCast(@alignCast(c.gdk_memory_texture_new(
        @intCast(image.width),
        @intCast(image.height),
        c.GDK_MEMORY_R8G8B8A8,
        bytes,
        @intCast(image.width * 4),
    )));
}

const VIEWER_QDATA = "sketerm-viewer-window";

pub const ViewerWindow = struct {
    allocator: std.mem.Allocator,
    window: *c.GtkWidget,
    batch: model.Batch,
    index: usize = 0,
    canvas: image_canvas.Canvas,
    session: image_canvas.Session = .{},
    target: *LoadTarget,
    status: *c.GtkLabel,
    position: *c.GtkLabel,
    zoom_label: *c.GtkLabel,
    original_button: *c.GtkWidget,
    prev_button: *c.GtkWidget,
    next_button: *c.GtkWidget,
    fullscreen: bool = false,

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
        const fullscreen_button = c.gtk_button_new_from_icon_name("view-fullscreen-symbolic").?;
        c.gtk_widget_set_tooltip_text(fullscreen_button, "Fullscreen (F11)");
        c.adw_header_bar_pack_end(@ptrCast(header), fullscreen_button);
        c.adw_header_bar_pack_end(@ptrCast(header), actual_button);
        c.adw_header_bar_pack_end(@ptrCast(header), fit_button);
        c.adw_header_bar_pack_end(@ptrCast(header), zoom_in);
        c.adw_header_bar_pack_end(@ptrCast(header), @ptrCast(@alignCast(zoom_label)));
        c.adw_header_bar_pack_end(@ptrCast(header), zoom_out);
        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), header);

        var canvas = image_canvas.Canvas.init();
        const content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        c.gtk_widget_set_vexpand(canvas.widget(), 1);
        c.gtk_box_append(@ptrCast(content), canvas.widget());
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
        self.* = .{
            .allocator = allocator,
            .window = window,
            .batch = batch,
            .index = batch.initial_index,
            .canvas = canvas,
            .target = target,
            .status = @ptrCast(@alignCast(status)),
            .position = @ptrCast(@alignCast(position)),
            .zoom_label = @ptrCast(@alignCast(zoom_label)),
            .original_button = original,
            .prev_button = prev_button,
            .next_button = next_button,
        };
        self.canvas.enableInput();
        self.canvas.on_zoom = &onCanvasZoom;
        self.canvas.zoom_ctx = @ptrCast(self);
        try self.session.attach(allocator, &self.canvas);

        c.g_object_set_data_full(@ptrCast(window), VIEWER_QDATA, @ptrCast(self), @ptrCast(&destroyViewer));
        _ = c.g_signal_connect_data(open_button, "clicked", @ptrCast(&onOpenClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(prev_button, "clicked", @ptrCast(&onPrevious), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(next_button, "clicked", @ptrCast(&onNext), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(zoom_out, "clicked", @ptrCast(&onZoomOut), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(zoom_in, "clicked", @ptrCast(&onZoomIn), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(fit_button, "clicked", @ptrCast(&onFit), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(actual_button, "clicked", @ptrCast(&onActual), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(fullscreen_button, "clicked", @ptrCast(&onFullscreen), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(original, "clicked", @ptrCast(&onOriginal), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        const keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(window, @ptrCast(keys));

        self.showCurrent();
        c.gtk_window_present(@ptrCast(window));
        return self;
    }

    fn destroyViewer(user: ?*anyopaque) callconv(.c) void {
        const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
        self.target.close();
        self.session.deinit(self.allocator);
        self.batch.deinit();
        self.allocator.destroy(self);
    }

    fn current(self: *ViewerWindow) ?model.Resource {
        if (self.index >= self.batch.specs.len) return null;
        return model.Resource.parse(self.batch.specs[self.index]);
    }

    fn showCurrent(self: *ViewerWindow) void {
        self.session.clear();
        self.canvas.fit();
        c.gtk_widget_set_visible(self.original_button, 0);
        const resource = self.current() orelse {
            c.gtk_label_set_text(self.status, "Open an image to begin");
            c.gtk_label_set_text(self.position, "");
            c.gtk_widget_set_sensitive(self.prev_button, 0);
            c.gtk_widget_set_sensitive(self.next_button, 0);
            return;
        };
        var title: [512:0]u8 = undefined;
        const title_z = std.fmt.bufPrintZ(&title, "{s} - {s}", .{ resource.name(), model.APP_NAME }) catch model.APP_NAME;
        c.gtk_window_set_title(@ptrCast(self.window), title_z.ptr);
        var pos: [64:0]u8 = undefined;
        const pos_z = std.fmt.bufPrintZ(&pos, "{d} of {d}", .{ self.index + 1, self.batch.specs.len }) catch "";
        c.gtk_label_set_text(self.position, pos_z.ptr);
        c.gtk_label_set_text(self.status, "Loading preview...");
        c.gtk_widget_set_sensitive(self.prev_button, @intFromBool(self.index > 0));
        c.gtk_widget_set_sensitive(self.next_button, @intFromBool(self.index + 1 < self.batch.specs.len));
        if (!self.target.start(resource.spec, .preview)) c.gtk_label_set_text(self.status, "Could not start preview loader");
    }

    fn loadOriginal(self: *ViewerWindow) void {
        const resource = self.current() orelse return;
        c.gtk_widget_set_sensitive(self.original_button, 0);
        c.gtk_label_set_text(self.status, "Loading full resolution through the file service...");
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
        if (paths.isSketermMount(path)) {
            c.gtk_label_set_text(self.status, "Sketerm mount paths are refused; open the original host:/path resource instead");
            return;
        }
        const spec = paths.formatSpecAlloc(self.allocator, null, path) catch return;
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
};

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
        if (result.variant == .original) {
            c.gtk_widget_set_sensitive(self.original_button, 1);
            c.gtk_widget_set_visible(self.original_button, 1);
        }
        return;
    };
    const texture = textureFromDecoded(image) orelse {
        c.gtk_label_set_text(self.status, "Unable to create image texture");
        return;
    };
    self.session.setTexture(texture);
    c.g_object_unref(@ptrCast(texture));
    var status: [256:0]u8 = undefined;
    const backend = switch (image.backend) {
        .glycin => "Glycin",
        .gdk_pixbuf => "GdkPixbuf",
    };
    const text = std.fmt.bufPrintZ(&status, "{s}  {d} x {d}  {s}", .{
        if (result.variant == .preview) "Preview" else "Full resolution",
        image.width,
        image.height,
        backend,
    }) catch "Image loaded";
    c.gtk_label_set_text(self.status, text.ptr);
    c.gtk_widget_set_visible(self.original_button, @intFromBool(result.variant == .preview));
    c.gtk_widget_set_sensitive(self.original_button, 1);
}

fn onCanvasZoom(user: ?*anyopaque, zoom: f64, fit: bool) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    if (fit) return c.gtk_label_set_text(self.zoom_label, "Fit");
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

fn onActual(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.canvas.actual();
}

fn onOriginal(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    self.loadOriginal();
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
    const dialog = c.gtk_file_dialog_new();
    c.gtk_file_dialog_set_title(dialog, "Open Image");
    _ = c.g_object_ref(@ptrCast(self.window));
    c.gtk_file_dialog_open(dialog, @ptrCast(self.window), null, @ptrCast(&onOpenDone), @ptrCast(self.window));
    c.g_object_unref(@ptrCast(dialog));
}

fn onOpenDone(source: *c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const window: *c.GtkWidget = @ptrCast(@alignCast(user.?));
    defer c.g_object_unref(@ptrCast(window));
    const dialog: *c.GtkFileDialog = @ptrCast(source);
    const file = c.gtk_file_dialog_open_finish(dialog, result, null) orelse return;
    defer c.g_object_unref(file);
    const raw = c.g_file_get_path(file) orelse return;
    defer c.g_free(raw);
    const data = c.g_object_get_data(@ptrCast(window), VIEWER_QDATA) orelse return;
    const self: *ViewerWindow = @ptrCast(@alignCast(data));
    self.replaceWithLocal(std.mem.span(@as([*:0]const u8, @ptrCast(raw))));
}

fn onKey(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, _: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *ViewerWindow = @ptrCast(@alignCast(user.?));
    switch (keyval) {
        c.GDK_KEY_Left => self.move(-1),
        c.GDK_KEY_Right => self.move(1),
        c.GDK_KEY_plus, c.GDK_KEY_equal, c.GDK_KEY_KP_Add => self.canvas.zoomBy(1.2),
        c.GDK_KEY_minus, c.GDK_KEY_KP_Subtract => self.canvas.zoomBy(1.0 / 1.2),
        c.GDK_KEY_0, c.GDK_KEY_KP_0 => self.canvas.actual(),
        c.GDK_KEY_f, c.GDK_KEY_F => self.canvas.fit(),
        c.GDK_KEY_F11 => toggleFullscreen(self),
        c.GDK_KEY_Escape => if (self.fullscreen) toggleFullscreen(self) else return 0,
        else => return 0,
    }
    return 1;
}
