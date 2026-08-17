//! Remote panel image collection, resolution, and GUI-host cache storage.

const std = @import("std");
const c = @import("../../c.zig").c;
const build_options = @import("build_options");
const pathz = @import("../../util/pathz.zig");
const Doc = @import("doc.zig");
const canary = @import("canary.zig");

pub const MAX_ASSETS_PER_OPERATION: usize = 64;
pub const MAX_ASSET_BYTES: usize = 16 << 20;
pub const MAX_OPERATION_BYTES: usize = 64 << 20;
pub const MAX_CONCURRENT_READS: usize = 4;
pub const MAX_IMAGE_AXIS: u64 = 8192;
pub const MAX_IMAGE_PIXELS: u64 = 32 * 1024 * 1024;
/// Decoded panel images retained by the whole GUI process. Later images
/// render an explicit failure until a panel or replacement releases enough
/// residency. One budget, charged once per distinct decoded pixbuf: a
/// per-document budget on top of this only ever double-counted the same
/// bytes.
pub const MAX_PROCESS_PREPARED_PIXELS: u64 = 128 * 1024 * 1024;
pub const MAX_PROCESS_PREPARED_BYTES: u64 = 512 << 20;
pub const PROCESS_PREPARED_BUDGET_ERROR = "GUI panel images exceed the process-wide 128MP/512MiB prepared-image budget";
// Cache pruning and the atomic install are serialized. Keeping one job in
// flight also lets the main thread lease its result before the next prune.
pub const MAX_CONCURRENT_CACHE_WRITES: usize = 1;
pub const HYDRATION_DEADLINE_MS: i64 = 30_000;
pub const READ_CHUNK_BYTES: u32 = 256 << 10;

pub const CACHE_MAX_BYTES: u64 = 256 << 20;
pub const CACHE_MAX_BLOBS: usize = 2048;
pub const PARTIAL_STALE_SECS: i64 = 60 * 60;
const OWNER_BYTES: usize = 16;
const OWNER_HEX_LEN: usize = OWNER_BYTES * 2;
const OWNER_FILE = ".owner-v1";
const NAMESPACE_SCAN_MAX: usize = 512;
const NAMESPACE_PRUNE_MAX: usize = 32;

pub const CollectError = error{ TooMany, OutOfMemory };

pub const PreparedInfo = struct {
    pixels: u64 = 0,
    bytes: u64 = 0,
};

pub const DimensionsError = error{Dimensions};

pub const ProcessPreparedBudgetError = error{
    ProcessPixelBudget,
    ProcessByteBudget,
};

/// Thread-safe aggregate used by prepared-image leases.
pub const ProcessPreparedBudget = struct {
    guard: std.atomic.Value(bool) = .init(false),
    pixels: u64 = 0,
    bytes: u64 = 0,
    max_pixels: u64,
    max_bytes: u64,

    pub fn init(max_pixels: u64, max_bytes: u64) ProcessPreparedBudget {
        return .{ .max_pixels = max_pixels, .max_bytes = max_bytes };
    }

    fn lock(self: *ProcessPreparedBudget) void {
        while (self.guard.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    fn unlock(self: *ProcessPreparedBudget) void {
        self.guard.store(false, .release);
    }

    pub fn reserve(self: *ProcessPreparedBudget, info: PreparedInfo) ProcessPreparedBudgetError!void {
        self.lock();
        defer self.unlock();
        const pixels = std.math.add(u64, self.pixels, info.pixels) catch return error.ProcessPixelBudget;
        const bytes = std.math.add(u64, self.bytes, info.bytes) catch return error.ProcessByteBudget;
        if (pixels > self.max_pixels) return error.ProcessPixelBudget;
        if (bytes > self.max_bytes) return error.ProcessByteBudget;
        self.pixels = pixels;
        self.bytes = bytes;
    }

    pub fn release(self: *ProcessPreparedBudget, info: PreparedInfo) void {
        self.lock();
        defer self.unlock();
        self.pixels -= info.pixels;
        self.bytes -= info.bytes;
    }

    /// Replace one live reservation without exposing its capacity in between.
    pub fn reconcile(
        self: *ProcessPreparedBudget,
        previous: PreparedInfo,
        actual: PreparedInfo,
    ) ProcessPreparedBudgetError!void {
        self.lock();
        defer self.unlock();
        const base_pixels = self.pixels - previous.pixels;
        const base_bytes = self.bytes - previous.bytes;
        const pixels = std.math.add(u64, base_pixels, actual.pixels) catch
            return error.ProcessPixelBudget;
        const bytes = std.math.add(u64, base_bytes, actual.bytes) catch
            return error.ProcessByteBudget;
        if (pixels > self.max_pixels) return error.ProcessPixelBudget;
        if (bytes > self.max_bytes) return error.ProcessByteBudget;
        self.pixels = pixels;
        self.bytes = bytes;
    }

    pub fn usage(self: *ProcessPreparedBudget) PreparedInfo {
        self.lock();
        defer self.unlock();
        return .{ .pixels = self.pixels, .bytes = self.bytes };
    }
};

var process_prepared_budget = ProcessPreparedBudget.init(
    MAX_PROCESS_PREPARED_PIXELS,
    MAX_PROCESS_PREPARED_BYTES,
);

/// A process charge acquired before decode and transferable to a pixbuf lease.
pub const ProcessPreparedReservation = struct {
    budget: *ProcessPreparedBudget,
    info: PreparedInfo,
    held: bool = true,

    pub fn reserve(info: PreparedInfo) ProcessPreparedBudgetError!ProcessPreparedReservation {
        return reserveWithBudget(&process_prepared_budget, info);
    }

    pub fn reserveWithBudget(
        budget: *ProcessPreparedBudget,
        info: PreparedInfo,
    ) ProcessPreparedBudgetError!ProcessPreparedReservation {
        try budget.reserve(info);
        return .{ .budget = budget, .info = info };
    }

    pub fn reconcile(
        self: *ProcessPreparedReservation,
        actual: PreparedInfo,
    ) ProcessPreparedBudgetError!void {
        if (!self.held) return;
        try self.budget.reconcile(self.info, actual);
        self.info = actual;
    }

    pub fn release(self: *ProcessPreparedReservation) void {
        if (!self.held) return;
        self.held = false;
        self.budget.release(self.info);
    }
};

pub fn processPreparedUsage() PreparedInfo {
    return process_prepared_budget.usage();
}

/// One charge and one GObject reference per distinct decoded pixbuf.
pub const PreparedLease = struct {
    pub const MAGIC: u32 = 0x504C5345; // "PLSE"
    /// Detector only (canary.zig): the retain/release refcount is what
    /// actually owns this allocation.
    magic: u32 = MAGIC,
    allocator: std.mem.Allocator,
    budget: *ProcessPreparedBudget,
    prepared: *anyopaque,
    info: PreparedInfo,
    refs: usize = 1,

    /// Adopt a decoded GObject and the process charge reserved before decode.
    pub fn adoptReserved(
        allocator: std.mem.Allocator,
        prepared: *anyopaque,
        reservation: *ProcessPreparedReservation,
    ) !*PreparedLease {
        const lease = try allocator.create(PreparedLease);
        lease.* = .{
            .allocator = allocator,
            .budget = reservation.budget,
            .prepared = prepared,
            .info = reservation.info,
        };
        reservation.held = false;
        return lease;
    }

    fn adoptWithBudget(
        allocator: std.mem.Allocator,
        budget: *ProcessPreparedBudget,
        prepared: *anyopaque,
        info: PreparedInfo,
    ) !*PreparedLease {
        const lease = try allocator.create(PreparedLease);
        errdefer allocator.destroy(lease);
        try budget.reserve(info);
        lease.* = .{
            .allocator = allocator,
            .budget = budget,
            .prepared = prepared,
            .info = info,
        };
        return lease;
    }

    /// Create a lease while leaving the caller's GObject reference intact.
    fn createRetained(allocator: std.mem.Allocator, prepared: *anyopaque, info: PreparedInfo) !*PreparedLease {
        const lease = try allocator.create(PreparedLease);
        errdefer allocator.destroy(lease);
        try process_prepared_budget.reserve(info);
        retainPrepared(prepared);
        lease.* = .{
            .allocator = allocator,
            .budget = &process_prepared_budget,
            .prepared = prepared,
            .info = info,
        };
        return lease;
    }

    pub fn retain(self: *PreparedLease) void {
        self.refs += 1;
    }

    pub fn release(self: *PreparedLease) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const allocator = self.allocator;
        // Lease releases run on the GUI thread; drop the GObject there before
        // making its measured residency available to another decode worker.
        releasePrepared(self.prepared);
        self.budget.release(self.info);
        canary.poison(self);
        allocator.destroy(self);
    }
};

pub fn preparedInfoForDimensions(width: u64, height: u64) DimensionsError!PreparedInfo {
    if (width == 0 or height == 0) return error.Dimensions;
    const pixels = std.math.mul(u64, width, height) catch return error.Dimensions;
    if (width > MAX_IMAGE_AXIS or height > MAX_IMAGE_AXIS or pixels > MAX_IMAGE_PIXELS)
        return error.Dimensions;
    const bytes = std.math.mul(u64, pixels, 4) catch return error.Dimensions;
    return .{ .pixels = pixels, .bytes = bytes };
}

pub const Paths = struct {
    allocator: std.mem.Allocator,
    items: [][]u8,

    pub fn deinit(self: *Paths) void {
        for (self.items) |path| self.allocator.free(path);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// Collect unique logical image paths in stable lexical order.
pub fn collectPaths(allocator: std.mem.Allocator, doc: *const Doc.Document) CollectError!Paths {
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |path| allocator.free(path);
        items.deinit(allocator);
    }

    var it = doc.components.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.props) {
        .image => |image| try appendUniquePath(allocator, &items, image.src),
        .image_compare => |compare| {
            try appendUniquePath(allocator, &items, compare.left.src);
            try appendUniquePath(allocator, &items, compare.right.src);
        },
        else => {},
    };
    std.mem.sort([]u8, items.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return .{
        .allocator = allocator,
        .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

/// Collect image paths from only the named components.
pub fn collectComponentPaths(
    allocator: std.mem.Allocator,
    doc: *const Doc.Document,
    ids: []const []u8,
) CollectError!Paths {
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |path| allocator.free(path);
        items.deinit(allocator);
    }
    for (ids) |id| {
        const component = doc.get(id) orelse continue;
        switch (component.props) {
            .image => |image| try appendUniquePath(allocator, &items, image.src),
            .image_compare => |compare| {
                try appendUniquePath(allocator, &items, compare.left.src);
                try appendUniquePath(allocator, &items, compare.right.src);
            },
            else => {},
        }
    }
    return .{
        .allocator = allocator,
        .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

pub fn containsPath(paths: *const Paths, path: []const u8) bool {
    for (paths.items) |candidate| if (std.mem.eql(u8, candidate, path)) return true;
    return false;
}

fn appendUniquePath(allocator: std.mem.Allocator, items: *std.ArrayList([]u8), path: []const u8) CollectError!void {
    for (items.items) |existing| if (std.mem.eql(u8, existing, path)) return;
    if (items.items.len >= MAX_ASSETS_PER_OPERATION) return error.TooMany;
    const owned = allocator.dupe(u8, path) catch return error.OutOfMemory;
    errdefer allocator.free(owned);
    items.append(allocator, owned) catch return error.OutOfMemory;
}

pub const Cache = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    /// Held locked for this GUI process's cache lifetime.
    owner_fd: c_int = -1,
    leases: std.ArrayList(Lease) = .empty,

    const Lease = struct {
        hash: [64]u8,
        refs: usize,
    };

    pub fn init(allocator: std.mem.Allocator) !Cache {
        const root = try cacheRoot(allocator);
        errdefer allocator.free(root);
        const owner_fd = try claimCacheNamespace(root, c.getpid());
        errdefer _ = c.close(owner_fd);
        if (std.fs.path.dirname(root)) |pid_dir| if (std.fs.path.dirname(pid_dir)) |parent|
            cleanupProcessNamespaces(parent, root);
        return .{
            .allocator = allocator,
            .root = root,
            .owner_fd = owner_fd,
        };
    }

    pub fn initAt(allocator: std.mem.Allocator, root: []const u8) !Cache {
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
        };
    }

    pub fn deinit(self: *Cache) void {
        self.leases.deinit(self.allocator);
        if (self.owner_fd >= 0) _ = c.close(self.owner_fd);
        self.allocator.free(self.root);
        self.* = undefined;
    }

    pub fn retain(self: *Cache, hash: []const u8) !void {
        if (hash.len != 64) return;
        for (self.leases.items) |*lease| {
            if (std.mem.eql(u8, &lease.hash, hash)) {
                lease.refs +|= 1;
                return;
            }
        }
        var key: [64]u8 = undefined;
        @memcpy(&key, hash);
        try self.leases.append(self.allocator, .{ .hash = key, .refs = 1 });
    }

    pub fn release(self: *Cache, hash: []const u8) void {
        for (self.leases.items, 0..) |*lease, i| {
            if (!std.mem.eql(u8, &lease.hash, hash)) continue;
            if (lease.refs > 1) {
                lease.refs -= 1;
            } else {
                _ = self.leases.swapRemove(i);
            }
            return;
        }
    }

    /// Snapshot hashes that a background pruner must not remove.
    pub fn protected(self: *const Cache, allocator: std.mem.Allocator) ![][64]u8 {
        const out = try allocator.alloc([64]u8, self.leases.items.len);
        for (self.leases.items, 0..) |lease, i| out[i] = lease.hash;
        return out;
    }

    pub fn refCount(self: *const Cache, hash: []const u8) usize {
        for (self.leases.items) |lease| if (std.mem.eql(u8, &lease.hash, hash)) return lease.refs;
        return 0;
    }
};

fn cacheRoot(allocator: std.mem.Allocator) ![]u8 {
    var owner_bytes: [OWNER_BYTES]u8 = undefined;
    if (c.getentropy(&owner_bytes, owner_bytes.len) != 0) return error.OwnerIdentityUnavailable;
    const owner = ownerHex(owner_bytes);
    if (getenv("XDG_CACHE_HOME")) |base|
        return processCacheRoot(allocator, base, c.getpid(), &owner);
    if (getenv("HOME")) |home|
        return std.fmt.allocPrint(allocator, "{s}/.cache/sketerm/panel-assets/{d}/{s}", .{ home, c.getpid(), owner });
    return std.fmt.allocPrint(allocator, "/tmp/sketerm-{d}/panel-assets/{d}/{s}", .{ c.getuid(), c.getpid(), owner });
}

fn processCacheRoot(allocator: std.mem.Allocator, base: []const u8, pid: c.pid_t, owner: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sketerm/panel-assets/{d}/{s}", .{ base, pid, owner });
}

fn ownerHex(bytes: [OWNER_BYTES]u8) [OWNER_HEX_LEN]u8 {
    var out: [OWNER_HEX_LEN]u8 = undefined;
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0x0f];
    }
    return out;
}

fn claimCacheNamespace(root: []const u8, pid: c.pid_t) !c_int {
    const owner = std.fs.path.basename(root);
    if (!validOwnerName(owner)) return error.InvalidOwnerIdentity;
    var marker_buf: [4096]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{s}/{s}", .{ root, OWNER_FILE });
    try pathz.makeParentDirs(marker);
    var root_buf: [4096]u8 = undefined;
    const root_z = try pathz.pathZ(&root_buf, root);
    _ = c.chmod(root_z, 0o700);
    var marker_z_buf: [4096]u8 = undefined;
    const marker_z = try pathz.pathZ(&marker_z_buf, marker);
    const fd = c.open(marker_z, c.O_RDWR | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OwnerClaimFailed;
    errdefer {
        _ = c.close(fd);
        rmTree(root);
    }
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.OwnerClaimFailed;
    var metadata_buf: [96]u8 = undefined;
    const metadata = try std.fmt.bufPrint(&metadata_buf, "v1 {d} {s}\n", .{ pid, owner });
    var off: usize = 0;
    while (off < metadata.len) {
        const n = c.write(fd, metadata.ptr + off, metadata.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return error.OwnerClaimFailed;
    }
    return fd;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    const bytes = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
    return if (bytes.len == 0) null else bytes;
}

pub const Resolution = struct {
    logical: []u8,
    local: ?[]u8 = null,
    hash: ?[64]u8 = null,
    /// Fully decoded remote image, prepared off the GTK thread.
    prepared: ?*anyopaque = null,
    prepared_lease: ?*PreparedLease = null,
    prepared_info: PreparedInfo = .{},
    bytes: u64 = 0,
    failure: ?[]u8 = null,
};

pub const Report = struct {
    path: []const u8,
    ok: bool,
    bytes: u64 = 0,
    sha256: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    cache: ?*Cache = null,
    entries: std.ArrayList(Resolution) = .empty,

    pub fn init(allocator: std.mem.Allocator, cache: ?*Cache) Resolver {
        return .{ .allocator = allocator, .cache = cache };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.entries.items) |entry| {
            if (entry.hash) |hash| if (self.cache) |cache| cache.release(&hash);
            if (entry.prepared_lease) |lease| lease.release();
            self.allocator.free(entry.logical);
            if (entry.local) |local_path| self.allocator.free(local_path);
            if (entry.failure) |message| self.allocator.free(message);
        }
        self.entries.deinit(self.allocator);
        const allocator = self.allocator;
        self.* = .{ .allocator = allocator };
    }

    pub fn addSuccess(self: *Resolver, logical: []const u8, local: []const u8, hash: [64]u8, bytes: u64) !void {
        return self.addSuccessPrepared(logical, local, hash, bytes, null, .{});
    }

    pub fn addSuccessPrepared(
        self: *Resolver,
        logical: []const u8,
        local: []const u8,
        hash: [64]u8,
        bytes: u64,
        prepared: ?*anyopaque,
        prepared_info: PreparedInfo,
    ) !void {
        if (prepared) |image| {
            const lease = try PreparedLease.createRetained(self.allocator, image, prepared_info);
            defer lease.release();
            return self.addSuccessLease(logical, local, hash, bytes, lease);
        }
        return self.addSuccessInner(logical, local, hash, bytes, null, prepared_info);
    }

    /// Add a mapping that shares an existing decoded-image lease.
    pub fn addSuccessLease(
        self: *Resolver,
        logical: []const u8,
        local: []const u8,
        hash: [64]u8,
        bytes: u64,
        lease: *PreparedLease,
    ) !void {
        return self.addSuccessInner(logical, local, hash, bytes, lease, lease.info);
    }

    fn addSuccessInner(
        self: *Resolver,
        logical: []const u8,
        local: []const u8,
        hash: [64]u8,
        bytes: u64,
        prepared_lease: ?*PreparedLease,
        prepared_info: PreparedInfo,
    ) !void {
        const logical_copy = try self.allocator.dupe(u8, logical);
        errdefer self.allocator.free(logical_copy);
        const local_copy = try self.allocator.dupe(u8, local);
        errdefer self.allocator.free(local_copy);
        if (self.cache) |cache| try cache.retain(&hash);
        errdefer if (self.cache) |cache| cache.release(&hash);
        if (prepared_lease) |lease| lease.retain();
        errdefer if (prepared_lease) |lease| lease.release();
        try self.entries.append(self.allocator, .{
            .logical = logical_copy,
            .local = local_copy,
            .hash = hash,
            .prepared = if (prepared_lease) |lease| lease.prepared else null,
            .prepared_lease = prepared_lease,
            .prepared_info = prepared_info,
            .bytes = bytes,
        });
    }

    pub fn addFailure(self: *Resolver, logical: []const u8, message: []const u8) !void {
        const logical_copy = try self.allocator.dupe(u8, logical);
        errdefer self.allocator.free(logical_copy);
        const failure_copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(failure_copy);
        try self.entries.append(self.allocator, .{
            .logical = logical_copy,
            .failure = failure_copy,
        });
    }

    pub fn get(self: *const Resolver, logical: []const u8) ?*const Resolution {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.logical, logical)) return entry;
        return null;
    }

    pub fn path(self: *const Resolver, logical: []const u8) ?[]const u8 {
        const entry = self.get(logical) orelse return logical;
        return entry.local;
    }

    fn failure(self: *const Resolver, logical: []const u8) ?[]const u8 {
        const entry = self.get(logical) orelse return null;
        return entry.failure;
    }

    /// Copy one mapping while taking independent lease/prepared-image refs.
    pub fn copyFrom(self: *Resolver, source: *const Resolver, logical: []const u8) !bool {
        const entry = source.get(logical) orelse return false;
        if (entry.local) |local| {
            const hash = entry.hash orelse return false;
            if (entry.prepared_lease) |lease|
                try self.addSuccessLease(entry.logical, local, hash, entry.bytes, lease)
            else
                try self.addSuccessPrepared(entry.logical, local, hash, entry.bytes, null, entry.prepared_info);
        } else {
            try self.addFailure(entry.logical, entry.failure orelse "panel asset is unavailable");
        }
        return true;
    }

    pub fn reports(self: *const Resolver, allocator: std.mem.Allocator) ![]Report {
        const out = try allocator.alloc(Report, self.entries.items.len);
        for (self.entries.items, 0..) |*entry, i| out[i] = .{
            .path = entry.logical,
            .ok = entry.local != null,
            .bytes = entry.bytes,
            .sha256 = if (entry.hash) |*hash| hash else null,
            .@"error" = entry.failure,
        };
        return out;
    }

    /// Move every mapping and lease from `source` into this resolver.
    pub fn replaceFrom(self: *Resolver, source: *Resolver) void {
        self.deinit();
        self.* = source.*;
        source.* = .{ .allocator = self.allocator };
    }
};

/// Compose worker-produced path updates with the resolver currently visible
/// for every image path still present in the latest document.
pub fn composeResolver(
    allocator: std.mem.Allocator,
    cache: ?*Cache,
    paths: []const []const u8,
    current: *const Resolver,
    updates: *const Resolver,
) !Resolver {
    var candidate = Resolver.init(allocator, cache);
    errdefer candidate.deinit();
    // Preserve the mounted document's untouched images before considering
    // worker updates. Concurrent direct refreshes cannot evict a healthy image
    // merely because their stale operation snapshots each had spare budget.
    for (paths) |path| {
        if (updates.get(path) != null) continue;
        _ = try candidate.copyFrom(current, path);
    }
    for (paths) |path| {
        if (updates.get(path) == null) continue;
        _ = try candidate.copyFrom(updates, path);
    }
    return candidate;
}

fn retainPrepared(prepared: *anyopaque) void {
    if (comptime build_options.glib) _ = c.g_object_ref(prepared);
}

fn releasePrepared(prepared: *anyopaque) void {
    if (comptime build_options.glib) c.g_object_unref(prepared);
}

pub const CacheLimits = struct {
    max_bytes: u64 = CACHE_MAX_BYTES,
    max_blobs: usize = CACHE_MAX_BLOBS,
    partial_stale_secs: i64 = PARTIAL_STALE_SECS,
};

pub const StoreError = error{
    TooBig,
    Capacity,
    IoFailed,
    OutOfMemory,
};

pub const Stored = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    hash: [64]u8,
    bytes: u64,

    pub fn deinit(self: *Stored) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

const Blob = struct {
    path: []u8,
    hash: [64]u8,
    size: u64,
    mtime: i64,
};

/// Install bytes under their SHA-256 name after bounded cache pruning.
///
/// This is a recoverable cache: sources remain in panel documents and are
/// rehydrated on a miss. The cross-file prune/install sequence keeps its
/// specialized stage, but deliberately does not fsync cache data or entries.
pub fn store(
    allocator: std.mem.Allocator,
    root: []const u8,
    bytes: []const u8,
    protected: []const [64]u8,
    nonce: u64,
) StoreError!Stored {
    return storeWithOptions(allocator, root, bytes, protected, nonce, .{}, true);
}

fn storeWithOptions(
    allocator: std.mem.Allocator,
    root: []const u8,
    bytes: []const u8,
    protected: []const [64]u8,
    nonce: u64,
    limits: CacheLimits,
    commit: bool,
) StoreError!Stored {
    if (bytes.len > MAX_ASSET_BYTES) return error.TooBig;
    if (limits.max_blobs == 0 or @as(u64, @intCast(bytes.len)) > limits.max_bytes)
        return error.Capacity;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hash = digestHex(digest);
    const target = std.fmt.allocPrint(allocator, "{s}/{s}.blob", .{ root, &hash }) catch
        return error.OutOfMemory;
    errdefer allocator.free(target);

    pathz.makeParentDirs(target) catch return error.IoFailed;
    var root_buf: [4096]u8 = undefined;
    const root_z = pathz.pathZ(&root_buf, root) catch return error.IoFailed;
    if (c.mkdir(root_z, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST)
        return error.IoFailed;

    var target_buf: [4096]u8 = undefined;
    const target_z = pathz.pathZ(&target_buf, target) catch return error.IoFailed;
    var blobs: std.ArrayList(Blob) = .empty;
    defer {
        for (blobs.items) |blob| allocator.free(blob.path);
        blobs.deinit(allocator);
    }
    var total_bytes: u64 = 0;
    try scanCache(allocator, root, limits.partial_stale_secs, &blobs, &total_bytes);

    if (fileMatches(target_z, &hash, bytes.len)) {
        touch(target_z);
        return .{ .allocator = allocator, .path = target, .hash = hash, .bytes = bytes.len };
    }
    // A file under the right content name but with the wrong bytes is cache
    // corruption, never a hit. The staged rename below replaces it atomically.

    var existing_size: u64 = 0;
    var existing_count: usize = 0;
    for (blobs.items) |blob| {
        if (std.mem.eql(u8, &blob.hash, &hash)) {
            existing_size = blob.size;
            existing_count = 1;
            break;
        }
    }
    total_bytes -|= existing_size;
    var blob_count = blobs.items.len - existing_count;

    std.mem.sort(Blob, blobs.items, {}, struct {
        fn less(_: void, a: Blob, b: Blob) bool {
            if (a.mtime != b.mtime) return a.mtime < b.mtime;
            return std.mem.order(u8, &a.hash, &b.hash) == .lt;
        }
    }.less);

    const need: u64 = @intCast(bytes.len);
    for (blobs.items) |blob| {
        if (total_bytes +| need <= limits.max_bytes and blob_count < limits.max_blobs) break;
        if (std.mem.eql(u8, &blob.hash, &hash) or isProtected(&blob.hash, protected)) continue;
        var path_buf: [4096]u8 = undefined;
        if (pathz.pathZ(&path_buf, blob.path)) |z| {
            if (c.unlink(z) == 0) {
                total_bytes -|= blob.size;
                blob_count -|= 1;
            }
        } else |_| {}
    }
    if (total_bytes +| need > limits.max_bytes or blob_count >= limits.max_blobs)
        return error.Capacity;

    const stage = std.fmt.allocPrint(
        allocator,
        "{s}/.{s}.{d}.{d}.part",
        .{ root, &hash, c.getpid(), nonce },
    ) catch return error.OutOfMemory;
    defer allocator.free(stage);
    var stage_buf: [4096]u8 = undefined;
    const stage_z = pathz.pathZ(&stage_buf, stage) catch return error.IoFailed;
    _ = c.unlink(stage_z);
    const fd = c.open(stage_z, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.IoFailed;
    var closed = false;
    errdefer {
        if (!closed) _ = c.close(fd);
        _ = c.unlink(stage_z);
    }
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return error.IoFailed;
    }
    closed = true;
    if (c.close(fd) != 0) return error.IoFailed;
    if (!commit) return error.IoFailed;
    if (c.rename(stage_z, target_z) != 0) return error.IoFailed;
    return .{ .allocator = allocator, .path = target, .hash = hash, .bytes = bytes.len };
}

fn digestHex(digest: [std.crypto.hash.sha2.Sha256.digest_length]u8) [64]u8 {
    var out: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0x0f];
    }
    return out;
}

fn fileMatches(path: [*:0]const u8, expected: *const [64]u8, expected_size: usize) bool {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG or
        st.st_size < 0 or @as(u64, @intCast(st.st_size)) != expected_size)
        return false;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 << 10]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n > 0) {
            hasher.update(buf[0..@intCast(n)]);
            continue;
        }
        if (n == 0) break;
        if (std.posix.errno(n) == .INTR) continue;
        return false;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.mem.eql(u8, &digestHex(digest), expected);
}

fn touch(path: [*:0]const u8) void {
    _ = c.utimensat(c.AT_FDCWD, path, null, 0);
}

fn isProtected(hash: *const [64]u8, protected: []const [64]u8) bool {
    for (protected) |active| if (std.mem.eql(u8, hash, &active)) return true;
    return false;
}

fn scanCache(
    allocator: std.mem.Allocator,
    root: []const u8,
    partial_stale_secs: i64,
    blobs: *std.ArrayList(Blob),
    total_bytes: *u64,
) StoreError!void {
    var root_buf: [4096]u8 = undefined;
    const root_z = pathz.pathZ(&root_buf, root) catch return error.IoFailed;
    const dir = c.opendir(root_z) orelse return;
    defer _ = c.closedir(dir);
    const now = wallSecs();
    while (c.readdir(dir)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name }) catch
            return error.OutOfMemory;
        var full_buf: [4096]u8 = undefined;
        const full_z = pathz.pathZ(&full_buf, full) catch {
            allocator.free(full);
            continue;
        };
        var st: c.struct_stat = undefined;
        if (c.lstat(full_z, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) {
            allocator.free(full);
            continue;
        }
        const mtime = statMtimeSecs(st);
        if (std.mem.endsWith(u8, name, ".part")) {
            if (now - mtime >= partial_stale_secs) _ = c.unlink(full_z);
            allocator.free(full);
            continue;
        }
        if (!validBlobName(name)) {
            allocator.free(full);
            continue;
        }
        var hash: [64]u8 = undefined;
        @memcpy(&hash, name[0..64]);
        const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;
        blobs.append(allocator, .{
            .path = full,
            .hash = hash,
            .size = size,
            .mtime = mtime,
        }) catch {
            allocator.free(full);
            return error.OutOfMemory;
        };
        total_bytes.* +|= size;
    }
}

/// Remove complete cache namespaces whose owning GUI no longer holds its lock.
fn cleanupProcessNamespaces(parent: []const u8, current_root: []const u8) void {
    var parent_buf: [4096]u8 = undefined;
    const parent_z = pathz.pathZ(&parent_buf, parent) catch return;
    const namespaces = c.opendir(parent_z) orelse return;
    defer _ = c.closedir(namespaces);
    var scanned: usize = 0;
    var pruned: usize = 0;
    while (scanned < NAMESPACE_SCAN_MAX and pruned < NAMESPACE_PRUNE_MAX) {
        const pid_entry = c.readdir(namespaces) orelse break;
        const pid_name = std.mem.span(@as([*:0]const u8, @ptrCast(&pid_entry.*.d_name)));
        const pid = parsePidDir(pid_name) orelse continue;
        scanned += 1;
        var pid_path_buf: [4096:0]u8 = undefined;
        const pid_path = std.fmt.bufPrintZ(&pid_path_buf, "{s}/{s}", .{ parent, pid_name }) catch continue;
        var pid_stat: c.struct_stat = undefined;
        if (c.lstat(pid_path.ptr, &pid_stat) != 0 or (pid_stat.st_mode & c.S_IFMT) != c.S_IFDIR) continue;
        const pid_dir = c.opendir(pid_path.ptr) orelse continue;
        var legacy_files = false;
        while (scanned < NAMESPACE_SCAN_MAX and pruned < NAMESPACE_PRUNE_MAX) {
            const owner_entry = c.readdir(pid_dir) orelse break;
            const owner = std.mem.span(@as([*:0]const u8, @ptrCast(&owner_entry.*.d_name)));
            if (std.mem.eql(u8, owner, ".") or std.mem.eql(u8, owner, "..")) continue;
            scanned += 1;
            if (!validOwnerName(owner)) {
                if (validBlobName(owner) or std.mem.endsWith(u8, owner, ".part")) legacy_files = true;
                continue;
            }
            var owner_path_buf: [4096:0]u8 = undefined;
            const owner_path = std.fmt.bufPrintZ(&owner_path_buf, "{s}/{s}", .{ pid_path, owner }) catch continue;
            if (std.mem.eql(u8, std.mem.span(owner_path.ptr), current_root)) continue;
            var owner_stat: c.struct_stat = undefined;
            if (c.lstat(owner_path.ptr, &owner_stat) != 0 or (owner_stat.st_mode & c.S_IFMT) != c.S_IFDIR) continue;
            var marker_buf: [4096:0]u8 = undefined;
            const marker = std.fmt.bufPrintZ(&marker_buf, "{s}/{s}", .{ owner_path, OWNER_FILE }) catch continue;
            const fd = c.open(marker.ptr, c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW);
            if (fd < 0) continue;
            if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
                _ = c.close(fd);
                continue;
            }
            if (!ownerMarkerMatches(fd, pid, owner)) {
                _ = c.close(fd);
                continue;
            }
            rmTree(std.mem.span(owner_path.ptr));
            _ = c.close(fd);
            pruned += 1;
        }
        _ = c.closedir(pid_dir);
        // Numeric-only roots came from pre-owner builds. PID liveness is the
        // only safety signal available there, so a reused live PID is retained.
        if (legacy_files and pruned < NAMESPACE_PRUNE_MAX and !processExists(pid)) {
            cleanupLegacyNamespace(std.mem.span(pid_path.ptr));
            pruned += 1;
        }
        _ = c.rmdir(pid_path.ptr);
    }
}

fn validOwnerName(name: []const u8) bool {
    if (name.len != OWNER_HEX_LEN) return false;
    for (name) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn parsePidDir(name: []const u8) ?c.pid_t {
    if (name.len == 0) return null;
    for (name) |ch| if (ch < '0' or ch > '9') return null;
    const pid = std.fmt.parseInt(c.pid_t, name, 10) catch return null;
    return if (pid > 0) pid else null;
}

fn ownerMarkerMatches(fd: c_int, pid: c.pid_t, owner: []const u8) bool {
    if (c.lseek(fd, 0, c.SEEK_SET) < 0) return false;
    var got_buf: [96]u8 = undefined;
    const n = c.read(fd, &got_buf, got_buf.len);
    if (n <= 0) return false;
    var expected_buf: [96]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "v1 {d} {s}\n", .{ pid, owner }) catch return false;
    return std.mem.eql(u8, got_buf[0..@intCast(n)], expected);
}

fn processExists(pid: c.pid_t) bool {
    const rc = c.kill(pid, 0);
    return rc == 0 or std.posix.errno(rc) != .SRCH;
}

fn cleanupLegacyNamespace(path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const path_z = pathz.pathZ(&path_buf, path) catch return;
    const dir = c.opendir(path_z) orelse return;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!validBlobName(name) and !std.mem.endsWith(u8, name, ".part")) continue;
        var file_buf: [4096:0]u8 = undefined;
        const file = std.fmt.bufPrintZ(&file_buf, "{s}/{s}", .{ path, name }) catch continue;
        var st: c.struct_stat = undefined;
        if (c.lstat(file.ptr, &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFREG) _ = c.unlink(file.ptr);
    }
    _ = c.closedir(dir);
}

fn validBlobName(name: []const u8) bool {
    if (name.len != 64 + ".blob".len or !std.mem.endsWith(u8, name, ".blob")) return false;
    for (name[0..64]) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn statMtimeSecs(st: c.struct_stat) i64 {
    const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
    return @intCast(ts.tv_sec);
}

fn wallSecs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @intCast(ts.tv_sec);
}

fn rmTree(path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const z = pathz.pathZ(&path_buf, path) catch return;
    var st: c.struct_stat = undefined;
    if (c.lstat(z, &st) != 0) return;
    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
        const dir = c.opendir(z) orelse return;
        const allocator = std.heap.page_allocator;
        var children: std.ArrayList([]u8) = .empty;
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const child = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name }) catch continue;
            children.append(allocator, child) catch allocator.free(child);
        }
        _ = c.closedir(dir);
        for (children.items) |child| {
            rmTree(child);
            allocator.free(child);
        }
        children.deinit(allocator);
    }
    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) _ = c.rmdir(z) else _ = c.unlink(z);
}

/// Remove a cache test namespace recursively on a best-effort basis.
pub fn removeTreeBestEffort(path: []const u8) void {
    rmTree(path);
}

test "panel assets collect unique image paths and enforce the operation cap" {
    const testing = std.testing;
    const source =
        \\{"root":"root","components":{
        \\"root":{"type":"column","children":["a","b"]},
        \\"a":{"type":"image","src":"/remote/z.png"},
        \\"b":{"type":"image_compare","left":{"src":"/remote/a.png"},"right":{"src":"/remote/z.png"}}
        \\}}
    ;
    var doc = try Doc.Document.parse(testing.allocator, source, null);
    defer doc.deinit();
    var paths = try collectPaths(testing.allocator, &doc);
    defer paths.deinit();
    try testing.expectEqual(@as(usize, 2), paths.items.len);
    try testing.expectEqualStrings("/remote/a.png", paths.items[0]);
    try testing.expectEqualStrings("/remote/z.png", paths.items[1]);

    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |item| testing.allocator.free(item);
        list.deinit(testing.allocator);
    }
    for (0..MAX_ASSETS_PER_OPERATION) |i| {
        const path = try std.fmt.allocPrint(testing.allocator, "/remote/{d}.png", .{i});
        try list.append(testing.allocator, path);
    }
    try testing.expectError(
        error.TooMany,
        appendUniquePath(testing.allocator, &list, "/remote/overflow.png"),
    );
}

test "panel assets collect only paths from reset image components" {
    const source =
        \\{"root":"root","components":{
        \\"root":{"type":"column","children":["a","b"]},
        \\"a":{"type":"image","src":"/a.png"},
        \\"b":{"type":"image_compare","left":{"src":"/b.png"},"right":{"src":"/c.png"}}
        \\}}
    ;
    var doc = try Doc.Document.parse(std.testing.allocator, source, null);
    defer doc.deinit();
    var ids = [_][]u8{@constCast("b")};
    var paths = try collectComponentPaths(std.testing.allocator, &doc, &ids);
    defer paths.deinit();
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expect(containsPath(&paths, "/b.png"));
    try std.testing.expect(containsPath(&paths, "/c.png"));
    try std.testing.expect(!containsPath(&paths, "/a.png"));
}

test "panel resolver maps logical paths without changing document serialization" {
    const testing = std.testing;
    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sketerm-panel-assets-resolver-{d}", .{c.getpid()});
    rmTree(root);
    defer rmTree(root);
    var cache = try Cache.initAt(testing.allocator, root);
    defer cache.deinit();

    const source =
        \\{"root":"image","components":{"image":{"type":"image","src":"/remote/frame.png","caption":"remote"}}}
    ;
    var doc = try Doc.Document.parse(testing.allocator, source, null);
    defer doc.deinit();
    const before = try doc.toJson(testing.allocator);
    defer testing.allocator.free(before);

    const protected = try cache.protected(testing.allocator);
    defer testing.allocator.free(protected);
    var blob = try store(testing.allocator, root, "frame-one", protected, 1);
    defer blob.deinit();
    var resolver = Resolver.init(testing.allocator, &cache);
    defer resolver.deinit();
    try resolver.addSuccess("/remote/frame.png", blob.path, blob.hash, blob.bytes);
    try testing.expectEqualStrings(blob.path, resolver.path("/remote/frame.png").?);
    try testing.expectEqual(@as(usize, 1), cache.refCount(&blob.hash));

    const after = try doc.toJson(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expect(std.mem.indexOf(u8, after, blob.path) == null);
    try testing.expect(std.mem.indexOf(u8, after, "/remote/frame.png") != null);
}

test "panel cache verifies content, stages atomically, and refreshes a reused logical path" {
    const testing = std.testing;
    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sketerm-panel-assets-store-{d}", .{c.getpid()});
    rmTree(root);
    defer rmTree(root);

    var first = try storeWithOptions(testing.allocator, root, "red pixels", &.{}, 1, .{}, true);
    defer first.deinit();
    var same = try storeWithOptions(testing.allocator, root, "red pixels", &.{}, 2, .{}, true);
    defer same.deinit();
    try testing.expectEqualStrings(first.path, same.path);
    try testing.expectEqual(first.hash, same.hash);

    var second = try storeWithOptions(testing.allocator, root, "blue pixels", &.{}, 3, .{}, true);
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, first.path, second.path));
    try testing.expect(!std.mem.eql(u8, &first.hash, &second.hash));

    var cache = try Cache.initAt(testing.allocator, root);
    defer cache.deinit();
    var resolver = Resolver.init(testing.allocator, &cache);
    defer resolver.deinit();
    try resolver.addSuccess("/remote/same.png", first.path, first.hash, first.bytes);
    try testing.expectEqual(@as(usize, 1), cache.refCount(&first.hash));
    var refreshed = Resolver.init(testing.allocator, &cache);
    try refreshed.addSuccess("/remote/same.png", second.path, second.hash, second.bytes);
    try testing.expectEqual(@as(usize, 1), cache.refCount(&first.hash));
    try testing.expectEqual(@as(usize, 1), cache.refCount(&second.hash));
    resolver.replaceFrom(&refreshed);
    try testing.expectEqualStrings(second.path, resolver.path("/remote/same.png").?);
    try testing.expectEqual(@as(usize, 0), cache.refCount(&first.hash));
    try testing.expectEqual(@as(usize, 1), cache.refCount(&second.hash));

    const before_count = blk: {
        var count: usize = 0;
        var zbuf: [4096]u8 = undefined;
        const dir = c.opendir(try pathz.pathZ(&zbuf, root)) orelse break :blk count;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (validBlobName(name)) count += 1;
        }
        break :blk count;
    };
    try testing.expectError(
        error.IoFailed,
        storeWithOptions(testing.allocator, root, "never committed", &.{}, 4, .{}, false),
    );
    var after_count: usize = 0;
    var zbuf: [4096]u8 = undefined;
    const dir = c.opendir(try pathz.pathZ(&zbuf, root)) orelse return error.TestUnexpectedResult;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (validBlobName(name)) after_count += 1;
    }
    try testing.expectEqual(before_count, after_count);
}

test "panel cache bounds pruning and protects leased blobs" {
    const testing = std.testing;
    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sketerm-panel-assets-limit-{d}", .{c.getpid()});
    rmTree(root);
    defer rmTree(root);
    const limits = CacheLimits{ .max_bytes = 64, .max_blobs = 1, .partial_stale_secs = 0 };

    var first = try storeWithOptions(testing.allocator, root, "first", &.{}, 1, limits, true);
    defer first.deinit();
    try testing.expectError(
        error.Capacity,
        storeWithOptions(testing.allocator, root, "second", &.{first.hash}, 2, limits, true),
    );
    var second = try storeWithOptions(testing.allocator, root, "second", &.{}, 3, limits, true);
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, first.path, second.path));
    var first_buf: [4096]u8 = undefined;
    try testing.expect(c.access(try pathz.pathZ(&first_buf, first.path), c.F_OK) != 0);
    var second_buf: [4096]u8 = undefined;
    try testing.expect(c.access(try pathz.pathZ(&second_buf, second.path), c.R_OK) == 0);

    const stale = try std.fmt.allocPrint(testing.allocator, "{s}/.stale.part", .{root});
    defer testing.allocator.free(stale);
    var stale_buf: [4096]u8 = undefined;
    const stale_z = try pathz.pathZ(&stale_buf, stale);
    const fd = c.open(stale_z, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    try testing.expect(fd >= 0);
    _ = c.close(fd);
    var same = try storeWithOptions(testing.allocator, root, "second", &.{}, 4, limits, true);
    same.deinit();
    try testing.expect(c.access(stale_z, c.F_OK) != 0);

    const oversized = try testing.allocator.alloc(u8, MAX_ASSET_BYTES + 1);
    defer testing.allocator.free(oversized);
    try testing.expectError(error.TooBig, store(testing.allocator, root, oversized, &.{}, 5));
}

test "panel cache namespace is isolated by GUI process" {
    const a = std.testing.allocator;
    const first_owner = "11111111111111111111111111111111";
    const second_owner = "22222222222222222222222222222222";
    const first = try processCacheRoot(a, "/tmp/cache-home", 101, first_owner);
    defer a.free(first);
    const second = try processCacheRoot(a, "/tmp/cache-home", 202, second_owner);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqualStrings("/tmp/cache-home/sketerm/panel-assets/101/11111111111111111111111111111111", first);
    try std.testing.expectEqualStrings("/tmp/cache-home/sketerm/panel-assets/202/22222222222222222222222222222222", second);
}

test "panel cache removes dead owners and protects live PID-reuse namespaces" {
    const a = std.testing.allocator;
    var base_buf: [160]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/sketerm-panel-assets-siblings-{d}", .{c.getpid()});
    rmTree(base);
    defer rmTree(base);
    const pid = c.getpid();
    const dead_owner = "dddddddddddddddddddddddddddddddd";
    const live_owner = "11111111111111111111111111111111";
    const dead_root = try processCacheRoot(a, base, pid, dead_owner);
    defer a.free(dead_root);
    const live_root = try processCacheRoot(a, base, pid, live_owner);
    defer a.free(live_root);
    const parent = std.fs.path.dirname(std.fs.path.dirname(dead_root).?).?;

    const dead_lock = try claimCacheNamespace(dead_root, pid);
    const live_lock = try claimCacheNamespace(live_root, pid);
    defer _ = c.close(live_lock);

    const blob_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.blob";
    const dead_blob = try std.fmt.allocPrint(a, "{s}/{s}", .{ dead_root, blob_name });
    defer a.free(dead_blob);
    const live_blob = try std.fmt.allocPrint(a, "{s}/{s}", .{ live_root, blob_name });
    defer a.free(live_blob);
    for ([_][]const u8{ dead_blob, live_blob }) |path| {
        var path_buf: [4096]u8 = undefined;
        const fd = c.open(try pathz.pathZ(&path_buf, path), c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        try std.testing.expectEqual(@as(isize, 1), c.write(fd, "x", 1));
        _ = c.close(fd);
    }

    // The dead incarnation releases its lock. A new GUI with the SAME PID but
    // a different owner token remains locked and must not be touched.
    _ = c.close(dead_lock);
    cleanupProcessNamespaces(parent, "");
    var dead_buf: [4096]u8 = undefined;
    try std.testing.expect(c.access(try pathz.pathZ(&dead_buf, dead_root), c.F_OK) != 0);
    var live_buf: [4096]u8 = undefined;
    try std.testing.expect(c.access(try pathz.pathZ(&live_buf, live_blob), c.R_OK) == 0);
}

test "empty and canceled resolvers preserve transactional cache leases" {
    const a = std.testing.allocator;
    var cache = try Cache.initAt(a, "/tmp/sketerm-panel-assets-lease-transaction");
    defer cache.deinit();
    const first: [64]u8 = @splat('a');
    const second: [64]u8 = @splat('b');

    var live = Resolver.init(a, &cache);
    defer live.deinit();
    try live.addSuccess("/remote/old.png", "/cache/old", first, 1);
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&first));

    // A canceled operation drops only its candidate lease; the live resolver
    // and document remain paired.
    var candidate = Resolver.init(a, &cache);
    try candidate.addSuccess("/remote/new.png", "/cache/new", second, 1);
    candidate.deinit();
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&first));
    try std.testing.expectEqual(@as(usize, 0), cache.refCount(&second));

    const live_source =
        \\{"root":"img","components":{"img":{"type":"image","src":"/remote/old.png"}}}
    ;
    var live_doc = try Doc.Document.parse(a, live_source, null);
    defer live_doc.deinit();
    const before_cancel = try live_doc.toJson(a);
    defer a.free(before_cancel);
    var candidate_doc = try live_doc.clone();
    defer candidate_doc.deinit();
    var applied = try candidate_doc.applyPatch(
        \\[{"op":"set","id":"img","component":{"type":"image","src":"/remote/new.png"}}]
    , null);
    applied.deinit();
    // Dropping the hydrated candidate leaves both the mounted document and its
    // old lease untouched; only a successful visible commit may replace them.
    const after_cancel = try live_doc.toJson(a);
    defer a.free(after_cancel);
    try std.testing.expectEqualStrings(before_cancel, after_cancel);
    try std.testing.expect(std.mem.indexOf(u8, after_cancel, "/remote/old.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_cancel, "/cache/") == null);
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&first));

    // Committing a document with no images uses an explicit empty resolver,
    // releasing the old lease immediately rather than retaining stale assets.
    var empty = Resolver.init(a, &cache);
    live.replaceFrom(&empty);
    try std.testing.expectEqual(@as(usize, 0), cache.refCount(&first));
    try std.testing.expectEqual(@as(usize, 0), live.entries.items.len);
}

test "copying an untouched resolution preserves leases until atomic replacement" {
    const a = std.testing.allocator;
    var cache = try Cache.initAt(a, "/tmp/sketerm-panel-assets-copy-transaction");
    defer cache.deinit();
    const hash: [64]u8 = @splat('c');

    var live = Resolver.init(a, &cache);
    defer live.deinit();
    try live.addSuccess("/gone/source.png", "/cache/preserved", hash, 12);

    var candidate = Resolver.init(a, &cache);
    try std.testing.expect(try candidate.copyFrom(&live, "/gone/source.png"));
    try std.testing.expectEqual(@as(usize, 2), cache.refCount(&hash));
    live.replaceFrom(&candidate);
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&hash));
    try std.testing.expectEqualStrings("/cache/preserved", live.path("/gone/source.png").?);
}

test "title-only and selective image patches retain only untouched leases" {
    const a = std.testing.allocator;
    var cache = try Cache.initAt(a, "/tmp/sketerm-panel-assets-selective-transaction");
    defer cache.deinit();
    const first: [64]u8 = @splat('a');
    const second: [64]u8 = @splat('b');

    var live = Resolver.init(a, &cache);
    defer live.deinit();
    try live.addSuccess("/missing/untouched.png", "/cache/untouched", first, 10);
    try live.addSuccess("/changed.png", "/cache/old-changed", second, 20);

    // A title/text patch has no reset image components. Both mappings are
    // cloned without consulting either logical source path.
    var title_candidate = Resolver.init(a, &cache);
    try std.testing.expect(try title_candidate.copyFrom(&live, "/missing/untouched.png"));
    try std.testing.expect(try title_candidate.copyFrom(&live, "/changed.png"));
    live.replaceFrom(&title_candidate);
    try std.testing.expectEqualStrings("/cache/untouched", live.path("/missing/untouched.png").?);
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&first));
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&second));

    // Reset only the second image. The untouched prepared mapping survives;
    // the reset mapping can become a failure without releasing the first.
    var changed_candidate = Resolver.init(a, &cache);
    try std.testing.expect(try changed_candidate.copyFrom(&live, "/missing/untouched.png"));
    try changed_candidate.addFailure("/changed.png", "source disappeared after reset");
    live.replaceFrom(&changed_candidate);
    try std.testing.expectEqualStrings("/cache/untouched", live.path("/missing/untouched.png").?);
    try std.testing.expectEqualStrings("source disappeared after reset", live.failure("/changed.png").?);
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&first));
    try std.testing.expectEqual(@as(usize, 0), cache.refCount(&second));

    // Removing the failed image drops only that entry; the untouched lease is
    // still retained by the final candidate.
    var removed_candidate = Resolver.init(a, &cache);
    try std.testing.expect(try removed_candidate.copyFrom(&live, "/missing/untouched.png"));
    live.replaceFrom(&removed_candidate);
    try std.testing.expectEqual(@as(usize, 1), live.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&first));
}

test "completed same-path refresh composes with a later non-image patch" {
    const a = std.testing.allocator;
    var cache = try Cache.initAt(a, "/tmp/sketerm-panel-assets-refresh-compose");
    defer cache.deinit();
    const old_hash: [64]u8 = @splat('a');
    const new_hash: [64]u8 = @splat('b');
    const other_hash: [64]u8 = @splat('c');

    var current = Resolver.init(a, &cache);
    defer current.deinit();
    try current.addSuccess("/same.png", "/cache/old", old_hash, 10);
    try current.addSuccess("/untouched.png", "/cache/untouched", other_hash, 20);

    // This is the result of the older same-logical-path refresh. A title/text
    // patch has already advanced the document but did not request any IO.
    {
        var updates = Resolver.init(a, &cache);
        defer updates.deinit();
        try updates.addSuccess("/same.png", "/cache/new", new_hash, 11);

        const paths = [_][]const u8{ "/same.png", "/untouched.png" };
        var composed = try composeResolver(a, &cache, &paths, &current, &updates);
        current.replaceFrom(&composed);
    }
    try std.testing.expectEqualStrings("/cache/new", current.path("/same.png").?);
    try std.testing.expectEqualStrings("/cache/untouched", current.path("/untouched.png").?);
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&new_hash));
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&other_hash));
    try std.testing.expectEqual(@as(usize, 0), cache.refCount(&old_hash));
}

test "process prepared budget is exact across many panels sharing and destruction" {
    const a = std.testing.allocator;
    var budget = ProcessPreparedBudget.init(MAX_PROCESS_PREPARED_PIXELS, MAX_PROCESS_PREPARED_BYTES);
    const max_image = PreparedInfo{ .pixels = MAX_IMAGE_PIXELS, .bytes = MAX_IMAGE_PIXELS * 4 };
    const panel_count = MAX_PROCESS_PREPARED_BYTES / max_image.bytes;
    try std.testing.expectEqual(@as(u64, 4), panel_count);

    const Fixture = struct {
        fn image(seed: usize) !*anyopaque {
            if (comptime build_options.glib) {
                const pixbuf = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 1, 1) orelse
                    return error.OutOfMemory;
                return @ptrCast(pixbuf);
            }
            return @ptrFromInt(seed + 1);
        }
    };

    var leases: [panel_count]*PreparedLease = undefined;
    for (&leases, 0..) |*slot, i| {
        const image = try Fixture.image(i);
        slot.* = PreparedLease.adoptWithBudget(a, &budget, image, max_image) catch |err| {
            releasePrepared(image);
            return err;
        };
    }
    try std.testing.expectEqual(
        PreparedInfo{ .pixels = MAX_PROCESS_PREPARED_PIXELS, .bytes = MAX_PROCESS_PREPARED_BYTES },
        budget.usage(),
    );

    const rejected = try Fixture.image(leases.len);
    defer releasePrepared(rejected);
    try std.testing.expectError(
        error.ProcessPixelBudget,
        PreparedLease.adoptWithBudget(a, &budget, rejected, max_image),
    );
    try std.testing.expectEqual(
        PreparedInfo{ .pixels = MAX_PROCESS_PREPARED_PIXELS, .bytes = MAX_PROCESS_PREPARED_BYTES },
        budget.usage(),
    );

    // A resolver candidate shares the same lease while replacing its source;
    // only the final reference changes process residency.
    leases[0].retain();
    leases[0].release();
    try std.testing.expectEqual(@as(u64, MAX_PROCESS_PREPARED_BYTES), budget.usage().bytes);
    leases[0].release();
    try std.testing.expectEqual(MAX_PROCESS_PREPARED_BYTES - max_image.bytes, budget.usage().bytes);

    const replacement_image = try Fixture.image(leases.len + 1);
    const replacement = PreparedLease.adoptWithBudget(a, &budget, replacement_image, max_image) catch |err| {
        releasePrepared(replacement_image);
        return err;
    };
    try std.testing.expectEqual(@as(u64, MAX_PROCESS_PREPARED_BYTES), budget.usage().bytes);
    replacement.release();
    for (leases[1..]) |lease| lease.release();
    try std.testing.expectEqual(PreparedInfo{}, budget.usage());
}

test "prepared lease keeps its budget charged through GObject finalization" {
    if (comptime build_options.glib) {
        var budget = ProcessPreparedBudget.init(16, 64);
        const info = PreparedInfo{ .pixels = 1, .bytes = 4 };
        const Probe = struct {
            budget: *ProcessPreparedBudget,
            expected: PreparedInfo,
            charged_at_finalize: bool = false,

            fn destroy(user: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(user.?));
                self.charged_at_finalize = self.budget.usage().pixels == self.expected.pixels and
                    self.budget.usage().bytes == self.expected.bytes;
            }
        };
        var probe = Probe{ .budget = &budget, .expected = info };
        const pixbuf = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 1, 1) orelse
            return error.OutOfMemory;
        c.g_object_set_data_full(
            @ptrCast(@alignCast(pixbuf)),
            "sketerm-budget-order",
            @ptrCast(&probe),
            @ptrCast(&Probe.destroy),
        );
        const lease = PreparedLease.adoptWithBudget(
            std.testing.allocator,
            &budget,
            @ptrCast(pixbuf),
            info,
        ) catch |err| {
            c.g_object_unref(@ptrCast(pixbuf));
            return err;
        };
        lease.release();
        try std.testing.expect(probe.charged_at_finalize);
        try std.testing.expectEqual(PreparedInfo{}, budget.usage());
    } else return error.SkipZigTest;
}

test "process reservations reconcile rowstride and release every failure path" {
    var budget = ProcessPreparedBudget.init(100, 1_000);
    var reservation = try ProcessPreparedReservation.reserveWithBudget(
        &budget,
        .{ .pixels = 40, .bytes = 160 },
    );
    try std.testing.expectEqual(PreparedInfo{ .pixels = 40, .bytes = 160 }, budget.usage());

    try reservation.reconcile(.{ .pixels = 40, .bytes = 176 });
    try std.testing.expectEqual(PreparedInfo{ .pixels = 40, .bytes = 176 }, budget.usage());
    try std.testing.expectError(
        error.ProcessByteBudget,
        reservation.reconcile(.{ .pixels = 40, .bytes = 1_001 }),
    );
    try std.testing.expectEqual(PreparedInfo{ .pixels = 40, .bytes = 176 }, budget.usage());

    reservation.release();
    reservation.release();
    try std.testing.expectEqual(PreparedInfo{}, budget.usage());
}
