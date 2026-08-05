//! Live config reload driven by the file itself: a GFileMonitor on
//! config.conf, debounced, applying straight into the Window.
//!
//! Three things make this safe to run on every save rather than on a
//! keybind:
//!
//! - The apply does NOT persist (`ApplyOpts.persist = false`). The
//!   serialiser writes non-default keys only, so writing back would
//!   destroy the comments and ordering of the file being edited — and
//!   would feed our own write into the monitor forever.
//! - Every apply records the file's content hash, and an event whose
//!   content hashes the same is dropped. That is what makes the prefs
//!   dialog (which DOES persist, on every slider tick) invisible here.
//! - A rename-over — how editors actually save — leaves the monitor
//!   pointing at a vanished inode on some backends, so DELETED /
//!   RENAMED / MOVED_OUT re-arm the monitor before the reload runs.
//!
//! GUI-side by construction: `config.zig` compiles into `sketerm-mux`,
//! which links libc only and must never see GLib.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Config = @import("../config.zig").Config;
const winconfig = @import("winconfig.zig");
const Window = @import("window.zig").Window;

/// Quiet period after the last filesystem event before the config is
/// re-read. One save can deliver CREATED + CHANGED + CHANGES_DONE_HINT
/// (plus a RENAMED for the temp-file dance), and each apply rebuilds
/// every pane's atlas — doing that three times per save is visible.
const DEBOUNCE_MS: c_uint = 200;

pub const Watcher = struct {
    window: *Window,
    allocator: std.mem.Allocator,
    /// The watched file. Owned; NUL-terminated for libc + GIO.
    path: [:0]u8,
    monitor: ?*c.GFileMonitor = null,
    /// Pending debounce timer (0 = none).
    timer_id: c.guint = 0,
    /// Hash of the file content as of the last apply (or the last
    /// write we made ourselves). An event that resolves to the same
    /// content is our own echo, or a touch, and is dropped.
    last_hash: u64 = 0,
    have_hash: bool = false,

    /// Start watching `path` for `window`. Returns null when the
    /// monitor cannot be created (no GIO backend, unreadable parent);
    /// the app then simply has no auto-reload.
    pub fn start(window: *Window, path: []const u8) ?*Watcher {
        const allocator = window.allocator;
        const self = allocator.create(Watcher) catch return null;
        const owned = allocator.dupeZ(u8, path) catch {
            allocator.destroy(self);
            return null;
        };
        self.* = .{ .window = window, .allocator = allocator, .path = owned };
        // The inotify backend watches the file's DIRECTORY. Without it
        // the monitor attaches to nothing and a user whose config
        // directory does not exist yet would never see their first
        // config.conf. The app writes here anyway on any prefs change.
        @import("../util/pathz.zig").makeParentDirs(owned) catch {};
        if (!self.arm()) {
            allocator.free(owned);
            allocator.destroy(self);
            return null;
        }
        self.last_hash = hashFile(owned) orelse 0;
        self.have_hash = true;
        return self;
    }

    pub fn stop(self: *Watcher) void {
        if (self.timer_id != 0) {
            _ = c.g_source_remove(self.timer_id);
            self.timer_id = 0;
        }
        self.disarm();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn disarm(self: *Watcher) void {
        if (self.monitor) |m| {
            _ = c.g_signal_handlers_disconnect_matched(
                @ptrCast(m),
                @intCast(c.G_SIGNAL_MATCH_DATA),
                0,
                0,
                null,
                null,
                @ptrCast(self),
            );
            _ = c.g_file_monitor_cancel(m);
            c.g_object_unref(@ptrCast(m));
            self.monitor = null;
        }
    }

    /// (Re-)create the GFileMonitor. Idempotent: an existing monitor
    /// is cancelled first, which is what makes the rename-over path
    /// survivable.
    fn arm(self: *Watcher) bool {
        self.disarm();
        const file = c.g_file_new_for_path(self.path.ptr) orelse return false;
        defer c.g_object_unref(@ptrCast(file));
        var err: [*c]c.GError = null;
        // WATCH_MOVES reports a rename-over as RENAMED rather than as
        // an unrelated DELETE/CREATE pair.
        const mon = c.g_file_monitor_file(file, c.G_FILE_MONITOR_WATCH_MOVES, null, &err);
        if (mon == null) {
            if (err != null) {
                std.debug.print("sketerm: config watch failed: {s}\n", .{std.mem.span(err.*.message)});
                c.g_error_free(err);
            }
            return false;
        }
        self.monitor = mon;
        _ = c.g_signal_connect_data(
            @ptrCast(mon),
            "changed",
            @ptrCast(&onChanged),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        return true;
    }

    /// Coalesce this event into the pending reload.
    fn schedule(self: *Watcher) void {
        if (self.timer_id != 0) _ = c.g_source_remove(self.timer_id);
        self.timer_id = c.g_timeout_add(DEBOUNCE_MS, @ptrCast(&onTimeout), @ptrCast(self));
    }

    fn fire(self: *Watcher) void {
        self.timer_id = 0;
        // Switched off by the very config we last applied.
        if (!self.window.config.config_auto_reload) return;
        // A live prefs dialog edits its own copy and re-applies it on
        // the next row change; reloading under it would be undone
        // silently. Its own writes are already dropped by the hash
        // check — this is for a hand edit made while it is open.
        if (@import("prefs.zig").isOpen()) return;

        const hash = hashFile(self.path) orelse {
            // Gone (a rename that has not landed yet, or a delete).
            // The running config stays; the re-armed monitor picks up
            // whatever appears next.
            return;
        };
        if (hash == EMPTY_HASH) {
            // Almost always a truncate-in-progress that our debounce
            // caught mid-write. Refusing it costs a user who really
            // did empty the file one extra save.
            std.debug.print("sketerm: config file is empty, ignoring\n", .{});
            return;
        }
        if (self.have_hash and hash == self.last_hash) return;

        // loadFromPath, not loadWithOverride: a read that fails here
        // must leave the running config alone, where at startup it
        // would mean "no config file, use defaults".
        var new_cfg = Config.loadFromPath(self.allocator, self.path) catch |err| {
            std.debug.print(
                "sketerm: config not reloaded ({s}): {s}\n",
                .{ @errorName(err), self.path },
            );
            return;
        };
        defer new_cfg.deinit();
        self.last_hash = hash;
        self.have_hash = true;
        std.debug.print("sketerm: config reloaded ({s})\n", .{self.path});
        const window = self.window;
        // NOTHING may touch `self` past this call: a config that turns
        // `config_auto_reload` off makes the apply's `afterApply`
        // uninstall — and free — this very Watcher.
        window.applyConfigChangeOpts(&new_cfg, .{ .persist = false });
    }
};

/// Hash of the file's bytes, or null when it cannot be read. FNV-1a
/// over the whole file (they are kilobytes) — this is change
/// detection, not a security boundary.
fn hashFile(path: [:0]const u8) ?u64 {
    const fp = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var h = std.hash.Fnv1a_64.init();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    return h.final();
}

const EMPTY_HASH: u64 = blk: {
    var h = std.hash.Fnv1a_64.init();
    break :blk h.final();
};

fn onTimeout(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Watcher, user);
    self.fire();
    return 0; // one-shot
}

fn onChanged(
    _: *c.GFileMonitor,
    _: ?*c.GFile,
    _: ?*c.GFile,
    event: c.GFileMonitorEvent,
    user: ?*anyopaque,
) callconv(.c) void {
    const self = cast.userData(Watcher, user);
    switch (event) {
        c.G_FILE_MONITOR_EVENT_CHANGED,
        c.G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT,
        c.G_FILE_MONITOR_EVENT_CREATED,
        c.G_FILE_MONITOR_EVENT_ATTRIBUTE_CHANGED,
        c.G_FILE_MONITOR_EVENT_MOVED_IN,
        => self.schedule(),
        // The inode we were watching is gone. Editors save this way
        // (write temp, rename over), so without the re-arm the feature
        // works exactly once.
        c.G_FILE_MONITOR_EVENT_DELETED,
        c.G_FILE_MONITOR_EVENT_MOVED,
        c.G_FILE_MONITOR_EVENT_MOVED_OUT,
        c.G_FILE_MONITOR_EVENT_RENAMED,
        => {
            _ = self.arm();
            self.schedule();
        },
        else => {},
    }
}

/// Start (or don't) the watcher for a freshly built window.
pub fn install(window: *Window) void {
    if (!window.config.config_auto_reload) return;
    const path = winconfig.resolveActiveConfigPath(window.allocator) orelse return;
    defer window.allocator.free(path);
    window.config_watch = Watcher.start(window, path);
}

pub fn uninstall(window: *Window) void {
    if (window.config_watch) |w| {
        w.stop();
        window.config_watch = null;
    }
}

/// Start or stop the watcher after an apply that may have flipped
/// `config_auto_reload`.
pub fn afterApply(window: *Window) void {
    if (!window.config.config_auto_reload) {
        uninstall(window);
    } else if (window.config_watch == null) {
        install(window);
    }
}

/// Re-stamp the content hash right after WE wrote config.conf, so the
/// events that write generates are recognised as our own echo. Must be
/// called from every persisting path — including the shader sliders,
/// which write per tick and would otherwise rebuild every pane's atlas
/// once per tick through the watcher.
pub fn noteSelfWrite(window: *Window) void {
    const w = window.config_watch orelse return;
    w.last_hash = hashFile(w.path) orelse w.last_hash;
    w.have_hash = true;
}
